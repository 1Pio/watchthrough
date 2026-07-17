import Foundation

public struct ProbedMedia: Equatable, Sendable {
    public let info: MediaInfo
    public let frames: [FramePoint]

    public init(info: MediaInfo, frames: [FramePoint]) {
        self.info = info
        self.frames = frames
    }
}

public enum SourceInspector {
    /// Validates without modifying the source and returns its canonical local path.
    public static func validate(_ source: URL) throws -> URL {
        guard source.isFileURL else {
            throw WatchthroughFailure(.usage, "source must be a local file")
        }
        let canonical = source.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(forKeys: [
                .isRegularFileKey,
                .isReadableKey,
            ])
        } catch {
            throw WatchthroughFailure(.readiness, "source does not exist or cannot be inspected: \(canonical.path)")
        }
        guard values.isRegularFile == true else {
            throw WatchthroughFailure(.usage, "source is not a regular file: \(canonical.path)")
        }
        guard values.isReadable != false else {
            throw WatchthroughFailure(.readiness, "source is not readable: \(canonical.path)")
        }
        do {
            let handle = try FileHandle(forReadingFrom: canonical)
            try handle.close()
        } catch {
            throw WatchthroughFailure(.readiness, "source is not readable: \(canonical.path)")
        }
        return canonical
    }

    public static func record(for source: URL) throws -> SourceRecord {
        let canonical = try validate(source)
        let before = try canonical.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard let fileSize = before.fileSize, let modifiedAt = before.contentModificationDate else {
            throw WatchthroughFailure(.readiness, "could not read source metadata: \(canonical.path)")
        }
        let digest = try FileSHA256.hexDigest(of: canonical)
        let after = try canonical.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard after.fileSize == fileSize, after.contentModificationDate == modifiedAt else {
            throw WatchthroughFailure(.operation, "source changed while its identity was being recorded")
        }
        return SourceRecord(
            path: canonical.path,
            sha256: digest,
            sizeBytes: Int64(fileSize),
            modifiedAt: ISO8601Clock.string(from: modifiedAt)
        )
    }
}

public enum MediaProbe {
    /// Reads container metadata and a frame-accurate decoded index. `ffprobe`
    /// `best_effort_timestamp_time` is retained for every decoded video frame.
    public static func probe(_ source: URL, ffprobe: String = "ffprobe") throws -> ProbedMedia {
        let source = try SourceInspector.validate(source)
        let metadataOutput = try ProcessRunner.run(
            ffprobe,
            arguments: [
                "-v", "error",
                "-show_entries",
                "format=duration:stream=index,codec_type,codec_name,pix_fmt,width,height,avg_frame_rate,r_frame_rate,time_base,duration",
                "-of", "json",
                source.path,
            ]
        ).requireSuccess("ffprobe could not inspect media")

        let document: ProbeDocument
        do {
            document = try StableJSON.decode(ProbeDocument.self, from: metadataOutput.stdoutData)
        } catch {
            throw WatchthroughFailure(.operation, "ffprobe returned invalid media metadata: \(error.localizedDescription)")
        }
        guard let video = document.streams.first(where: { $0.codecType == "video" }) else {
            throw WatchthroughFailure(.usage, "source contains no video stream")
        }
        guard let width = video.width, let height = video.height, width > 0, height > 0 else {
            throw WatchthroughFailure(.operation, "video stream has invalid dimensions")
        }

        let frames = try decodedFrameIndex(for: source, ffprobe: ffprobe)
        guard let first = frames.first, let last = frames.last else {
            throw WatchthroughFailure(.operation, "ffprobe decoded no timestamped video frames")
        }
        for pair in zip(frames, frames.dropFirst()) where pair.1.ptsSeconds < pair.0.ptsSeconds {
            throw WatchthroughFailure(.operation, "decoded frame timestamps are not monotonic")
        }

        let positiveGaps = zip(frames, frames.dropFirst())
            .map { $1.ptsSeconds - $0.ptsSeconds }
            .filter { $0.isFinite && $0 > 0 }
        let tailGaps = Array(positiveGaps.suffix(30)).sorted()
        let estimatedTailDuration = tailGaps.isEmpty
            ? nil
            : tailGaps[tailGaps.count / 2]
        let decodedSpan = last.ptsSeconds - first.ptsSeconds
        let metadataDuration = firstFinitePositive([
            document.format?.duration.flatMap(Double.init),
            video.duration.flatMap(Double.init),
        ])
        let singleFrameFallback = metadataDuration.map { duration in
            first.ptsSeconds > 0 && duration > first.ptsSeconds
                ? duration - first.ptsSeconds
                : duration
        }
        let duration = estimatedTailDuration.map { decodedSpan + $0 }
            ?? singleFrameFallback
            ?? decodedSpan
        guard duration.isFinite, duration > 0 else {
            throw WatchthroughFailure(.operation, "video duration is unavailable")
        }

        let info = MediaInfo(
            durationSeconds: duration,
            width: width,
            height: height,
            codec: video.codecName,
            pixelFormat: video.pixelFormat,
            averageFrameRate: nonEmptyRate(video.averageFrameRate),
            realFrameRate: nonEmptyRate(video.realFrameRate),
            timeBase: video.timeBase,
            hasAudio: document.streams.contains { $0.codecType == "audio" },
            frameCount: frames.count,
            firstPTS: first.ptsSeconds,
            lastPTS: last.ptsSeconds
        )
        return ProbedMedia(info: info, frames: frames)
    }

    public static func decodedFrameIndex(
        for source: URL,
        ffprobe: String = "ffprobe"
    ) throws -> [FramePoint] {
        let source = try SourceInspector.validate(source)
        let output = try ProcessRunner.run(
            ffprobe,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_frames",
                "-show_entries", "frame=best_effort_timestamp_time",
                "-of", "json",
                source.path,
            ]
        ).requireSuccess("ffprobe could not build the decoded frame index")

        let document: FrameDocument
        do {
            document = try StableJSON.decode(FrameDocument.self, from: output.stdoutData)
        } catch {
            throw WatchthroughFailure(.operation, "ffprobe returned an invalid frame index: \(error.localizedDescription)")
        }

        return try document.frames.enumerated().map { ordinal, frame in
            guard let text = frame.bestEffortTimestampTime,
                  let pts = Double(text), pts.isFinite else {
                throw WatchthroughFailure(
                    .operation,
                    "decoded frame \(ordinal) has no usable best-effort timestamp"
                )
            }
            return FramePoint(ordinal: ordinal, ptsSeconds: pts)
        }
    }

    private static func firstFinitePositive(_ candidates: [Double?]) -> Double? {
        candidates.compactMap { candidate in
            guard let candidate, candidate.isFinite, candidate > 0 else { return nil }
            return candidate
        }.first
    }

    private static func nonEmptyRate(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "0/0" else { return nil }
        return value
    }
}

private struct ProbeDocument: Decodable {
    let streams: [ProbeStream]
    let format: ProbeFormat?
}

private struct ProbeStream: Decodable {
    let codecType: String?
    let codecName: String?
    let pixelFormat: String?
    let width: Int?
    let height: Int?
    let averageFrameRate: String?
    let realFrameRate: String?
    let timeBase: String?
    let duration: String?

    private enum CodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case codecName = "codec_name"
        case pixelFormat = "pix_fmt"
        case width
        case height
        case averageFrameRate = "avg_frame_rate"
        case realFrameRate = "r_frame_rate"
        case timeBase = "time_base"
        case duration
    }
}

private struct ProbeFormat: Decodable {
    let duration: String?
}

private struct FrameDocument: Decodable {
    let frames: [TimestampFrame]
}

private struct TimestampFrame: Decodable {
    let bestEffortTimestampTime: String?

    private enum CodingKeys: String, CodingKey {
        case bestEffortTimestampTime = "best_effort_timestamp_time"
    }
}
