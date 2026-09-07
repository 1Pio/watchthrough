import Foundation

/// A decoded image with its observed presentation timestamp. Timestamp-based
/// inspection does not invent a global frame ordinal from an average FPS.
public struct TemporalFrame: Equatable, Sendable {
    public var ptsSeconds: Double
    public var url: URL
    public var localOrdinal: Int?

    public init(ptsSeconds: Double, url: URL, localOrdinal: Int? = nil) {
        self.ptsSeconds = ptsSeconds
        self.url = url
        self.localOrdinal = localOrdinal
    }
}

/// Sparse requests seek serially. Dense ranges decode once, starting at the
/// requested time, and retain actual PTS receipts from FFmpeg's showinfo filter.
public enum TemporalExtractor {
    public static func extract(
        source: URL,
        media: MediaInfo,
        times: [Double],
        destinationDirectory: URL,
        maximumWidth: Int? = 1_920,
        ffmpegPath: String = "ffmpeg"
    ) throws -> [TemporalFrame] {
        guard times.count <= 300, times.allSatisfy({ $0.isFinite }) else {
            throw WatchthroughFailure(.usage, "timestamp inspection requires at most 300 finite times")
        }
        let sorted = Array(Set(times)).sorted()
        let shortSpan = sorted.first.flatMap { first in sorted.last.map { $0 - first <= 30 } } ?? false
        var groups: [[Double]] = []
        for time in sorted {
            if let last = groups.last?.last, shortSpan || time - last <= 2 {
                groups[groups.count - 1].append(time)
            } else {
                groups.append([time])
            }
        }
        var result: [TemporalFrame] = []
        for group in groups {
            let first = group[0]
            let last = group[group.count - 1]
            // One frame can satisfy multiple nearby times. Use the preceding
            // selected PTS to avoid duplicates while preserving real timestamps.
            // Measured 18s/24s overviews favor a single decode. For longer spans,
            // a 2s gap threshold avoids decoding all intervening footage.
            let selection = group.map { time in
                let target = number(time - epsilon)
                return "gte(t\\,\(target))*(isnan(prev_selected_t)+lt(prev_selected_t\\,\(target)))"
            }.joined(separator: "+")
            let frames = try decode(
                source: source, media: media, start: first, end: last + 60,
                selection: selection, maximumFrames: group.count,
                destinationDirectory: destinationDirectory, maximumWidth: maximumWidth,
                ffmpegPath: ffmpegPath, localStride: nil
            )
            guard let final = frames.last, final.ptsSeconds >= last - epsilon else {
                throw WatchthroughFailure(.operation, "no decoded frame exists at or after \(number(last)); use a nearby range or the decoded tail")
            }
            result.append(contentsOf: frames)
        }
        return result
    }

    public static func extract(
        source: URL,
        media: MediaInfo,
        range: ClosedRange<Double>,
        every: SamplingInterval,
        destinationDirectory: URL,
        maximumWidth: Int? = 1_920,
        maximumFrames: Int = 300,
        ffmpegPath: String = "ffmpeg"
    ) throws -> [TemporalFrame] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              maximumFrames > 0, maximumFrames <= 300 else {
            throw WatchthroughFailure(.usage, "inspection needs a finite range and a 1...300 frame limit")
        }
        let sampling: String
        let stride: Int?
        switch every {
        case let .seconds(seconds):
            guard seconds.isFinite, seconds > 0 else {
                throw WatchthroughFailure(.usage, "sampling interval must be positive")
            }
            sampling = "(isnan(prev_selected_t)+gte(t-prev_selected_t\\,\(number(seconds - epsilon))))"
            stride = nil
        case let .frames(count):
            guard count > 0 else { throw WatchthroughFailure(.usage, "frame stride must be positive") }
            sampling = "not(mod(n\\,\(count)))"
            stride = count
        }
        let selection = "between(t\\,\(number(range.lowerBound - epsilon))\\,\(number(range.upperBound + epsilon)))*\(sampling)"
        let frames = try decode(
            source: source, media: media, start: range.lowerBound, end: range.upperBound,
            selection: selection, maximumFrames: maximumFrames + 1,
            destinationDirectory: destinationDirectory, maximumWidth: maximumWidth,
            ffmpegPath: ffmpegPath, localStride: stride
        )
        guard frames.count <= maximumFrames else {
            throw WatchthroughFailure(.usage, "inspection exceeds \(maximumFrames) frames; split the range or increase the sampling interval")
        }
        guard !frames.isEmpty else { throw WatchthroughFailure(.operation, "no decoded frame overlaps the requested range") }
        return frames
    }

    /// Decode only the final demuxing window to locate the real tail. ffprobe's
    /// bounded read may seek to an earlier keyframe, but never indexes the full
    /// source intentionally. A bad container duration triggers bounded retries.
    public static func tail(
        source: URL,
        media: MediaInfo,
        destinationDirectory: URL,
        maximumWidth: Int? = 1_920,
        ffmpegPath: String = "ffmpeg",
        ffprobePath: String = "ffprobe"
    ) throws -> TemporalFrame {
        for window in [2.0, 8.0, 30.0] {
            let start = max(media.firstPTS, media.lastPTS - window)
            let output = try ProcessRunner.run(ffprobePath, arguments: [
                "-v", "error", "-threads", String(MediaResourcePolicy.threads),
                "-select_streams", "v:0", "-read_intervals", "\(number(start))%",
                "-show_frames", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", source.path,
            ], timeout: 60).requireSuccess("could not locate the decoded video tail")
            let document = try StableJSON.decode(TailDocument.self, from: output.stdoutData)
            if let time = document.frames.last?.bestEffortTimestampTime.flatMap(Double.init), time.isFinite {
                return try extract(
                    source: source, media: media, times: [time],
                    destinationDirectory: destinationDirectory, maximumWidth: maximumWidth,
                    ffmpegPath: ffmpegPath
                )[0]
            }
            if start == media.firstPTS { break }
        }
        throw WatchthroughFailure(.operation, "container duration did not locate a decoded tail within 30 seconds; build the exact frame index")
    }

    /// Exact PTS selection for a supplied global index. Unlike subtracting an
    /// assumed seek ordinal, this verifies every emitted image's actual PTS.
    static func exact(
        source: URL, media: MediaInfo, points: [FramePoint],
        destinationDirectory: URL, maximumWidth: Int?, ffmpegPath: String
    ) throws -> [TemporalFrame] {
        guard let first = points.first, let last = points.last else { return [] }
        let selection = points.map {
            "between(t\\,\(number($0.ptsSeconds - epsilon))\\,\(number($0.ptsSeconds + epsilon)))"
        }.joined(separator: "+")
        let frames = try decode(
            source: source, media: media, start: first.ptsSeconds, end: last.ptsSeconds,
            selection: selection, maximumFrames: points.count,
            destinationDirectory: destinationDirectory, maximumWidth: maximumWidth,
            ffmpegPath: ffmpegPath, localStride: nil
        )
        guard frames.count == points.count,
              zip(frames, points).allSatisfy({ abs($0.ptsSeconds - $1.ptsSeconds) <= epsilon }) else {
            throw WatchthroughFailure(.operation, "decoded PTS receipts do not match the requested global frame index")
        }
        return frames
    }

    private static let epsilon = 0.000_001
    private static func number(_ value: Double) -> String {
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func decode(
        source: URL, media: MediaInfo, start: Double, end: Double,
        selection: String, maximumFrames: Int, destinationDirectory: URL,
        maximumWidth: Int?, ffmpegPath: String, localStride: Int?
    ) throws -> [TemporalFrame] {
        _ = try SourceInspector.validate(source)
        guard start.isFinite, end.isFinite, end >= start, maximumFrames > 0 else {
            throw WatchthroughFailure(.usage, "invalid temporal extraction bounds")
        }
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let token = UUID().uuidString.lowercased()
        let pattern = destinationDirectory.appendingPathComponent("frame-\(token)-%06d.jpg")
        var arguments = ["-hide_banner", "-loglevel", "info", "-nostats", "-nostdin", "-copyts"]
            + MediaResourcePolicy.filterArguments + MediaResourcePolicy.decoderArguments
        // FFmpeg's accurate-seek path expects an offset from the container's
        // start, even with copyts. -seek_timestamp plus copyts double-offsets
        // nonzero Matroska starts on FFmpeg 8.1 (covered by integration tests).
        let seek = max(0, start - (media.containerStartPTS ?? media.firstPTS) - 2 * epsilon)
        if seek > epsilon {
            arguments += ["-ss", number(seek)]
        }
        arguments += ["-t", number(max(1, end - start + 1)), "-i", source.path,
                      "-map", "0:v:0", "-an", "-sn", "-dn"]
        // Gate before sampling so n=0 belongs to the first frame in the range,
        // including when a demuxer lands earlier or audio precedes the video.
        var filter = "select=gte(t\\,\(number(start - epsilon))),select=\(selection)"
        if let maximumWidth {
            guard maximumWidth >= 2, maximumWidth <= 8_192 else {
                throw WatchthroughFailure(.usage, "maximum image dimension must be 2...8192")
            }
            filter += ",\(FrameImageGeometry.scaleFilter(maximumDimension: maximumWidth))"
        }
        // Capture original PTS first. JPEG files have no playback timeline;
        // their internal encoder clock must be strictly increasing even when
        // distinct source frames legitimately have equal presentation times.
        filter += ",showinfo=checksum=0,setpts=N"
        arguments += ["-vf", filter] + MediaResourcePolicy.encoderArguments + [
            // Passthrough alone still lets the encoder quantize timestamps to
            // guessed input FPS. A 24->60fps VFR stream then produces duplicate
            // encoder PTS and dropped/failed JPEGs. Keep the filter time base.
            "-fps_mode", "passthrough", "-enc_time_base:v", "filter",
            "-q:v", "2", "-start_number", "0",
            "-frames:v", String(maximumFrames), pattern.path,
        ]
        let output = try ProcessRunner.run(ffmpegPath, arguments: arguments, timeout: max(60, (end - start + 1) * 4))
            .requireSuccess("bounded frame extraction failed")
        let receipts = try FramePTSReceipts.parse(output.stderr)
        var frames: [TemporalFrame] = []
        for (index, receipt) in receipts.enumerated() {
            let url = destinationDirectory.appendingPathComponent(String(format: "frame-%@-%06d.jpg", token, index))
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            frames.append(TemporalFrame(ptsSeconds: receipt, url: url, localOrdinal: localStride.map { index * $0 }))
        }
        if frames.isEmpty, !receipts.isEmpty {
            throw WatchthroughFailure(.operation, "decoded timestamp receipts have no matching frame images")
        }
        return frames
    }
}

enum FrameImageGeometry {
    /// JPEG viewers use square pixels. Expand anamorphic display dimensions,
    /// then fit both axes into the requested limit. Using explicit DAR-aware
    /// dimensions avoids depending on the newer scale reset_sar option.
    static func scaleFilter(maximumDimension: Int) -> String {
        let edge = max(2, maximumDimension - maximumDimension % 2)
        let sar = "if(gt(sar,0),sar,1)"
        let aspect = "(iw/ih*\(sar))"
        let width = "min(\(edge),max(iw,iw*\(sar)))"
        let height = "min(\(edge),max(ih,ih/\(sar)))"
        return "scale=w='max(2,trunc(min(\(width),\(height)*\(aspect))/2)*2)':h='max(2,round(ow/\(aspect)/2)*2)':flags=lanczos,setsar=1"
    }
}

/// Integer PTS plus the filter's actual time base avoids showinfo's rounded
/// pts_time display value. Internal visibility allows small receipt unit tests.
enum FramePTSReceipts {
    static func parse(_ text: String) throws -> [Double] {
        let timeBase = try NSRegularExpression(pattern: #"config in time_base:\s*(-?\d+)/(\d+)"#)
        let point = try NSRegularExpression(pattern: #"\bn:\s*\d+\s+pts:\s*(-?\d+)\s+pts_time:"#)
        var scale: Double?
        var result: [Double] = []
        for line in text.components(separatedBy: .newlines) where line.contains("showinfo") {
            let value = line as NSString
            let range = NSRange(location: 0, length: value.length)
            if let match = timeBase.firstMatch(in: line, range: range),
               let numerator = Double(value.substring(with: match.range(at: 1))),
               let denominator = Double(value.substring(with: match.range(at: 2))), denominator > 0 {
                scale = numerator / denominator
            } else if let match = point.firstMatch(in: line, range: range),
                      let pts = Double(value.substring(with: match.range(at: 1))) {
                guard let scale, scale.isFinite, scale > 0 else {
                    throw WatchthroughFailure(.operation, "decoded frame receipt has no valid time base")
                }
                result.append(pts * scale)
            }
        }
        guard zip(result, result.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw WatchthroughFailure(.operation, "decoded frame receipts are not monotonic")
        }
        return result
    }
}

private struct TailDocument: Decodable {
    let frames: [TailFrame]
}
private struct TailFrame: Decodable {
    let bestEffortTimestampTime: String?
    enum CodingKeys: String, CodingKey { case bestEffortTimestampTime = "best_effort_timestamp_time" }
}
