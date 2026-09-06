import Foundation
import Darwin

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
        let beforeNanoseconds = try modificationNanoseconds(canonical)
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
        guard after.fileSize == fileSize, after.contentModificationDate == modifiedAt,
              try modificationNanoseconds(canonical) == beforeNanoseconds else {
            throw WatchthroughFailure(.operation, "source changed while its identity was being recorded")
        }
        return SourceRecord(
            path: canonical.path,
            sha256: digest,
            sizeBytes: Int64(fileSize),
            modifiedAt: ISO8601Clock.string(from: modifiedAt),
            modifiedAtNanoseconds: beforeNanoseconds
        )
    }

    public static func metadataMatches(_ source: URL, record: SourceRecord) throws -> Bool {
        let canonical = try validate(source)
        let values = try canonical.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard Int64(values.fileSize ?? -1) == record.sizeBytes else { return false }
        if let nanoseconds = record.modifiedAtNanoseconds {
            return try modificationNanoseconds(canonical) == nanoseconds
        }
        guard let modified = values.contentModificationDate else { return false }
        return ISO8601Clock.string(from: modified) == record.modifiedAt
    }

    private static func modificationNanoseconds(_ source: URL) throws -> String {
        var information = stat()
        guard source.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw WatchthroughFailure(.readiness, "could not stat source metadata")
        }
        return "\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec)"
    }

}

public enum MediaProbe {
    /// Container/stream metadata normally needs no decoded index. Live-muxed
    /// files can omit duration; only that case falls back to a full decoded probe
    /// and returns a nonzero frameCount so the caller can report the extra work.
    /// With frameCount zero, `lastPTS` is nominal, not decoded frame evidence.
    public static func metadata(_ source: URL, ffprobe: String = "ffprobe") throws -> MediaInfo {
        let source = try SourceInspector.validate(source)
        let output = try ProcessRunner.run(ffprobe, arguments: [
            "-v", "error", "-threads", String(MediaResourcePolicy.threads), "-show_entries",
            "format=duration,start_time,format_name:stream=codec_type,codec_name,pix_fmt,width,height,sample_aspect_ratio,avg_frame_rate,r_frame_rate,time_base,duration,start_time:stream_side_data=rotation",
            "-of", "json", source.path,
        ], timeout: 30).requireSuccess("ffprobe could not inspect media metadata")
        let document = try StableJSON.decode(ProbeDocument.self, from: output.stdoutData)
        guard let video = document.streams.first(where: { $0.codecType == "video" }),
              let codedWidth = video.width, let codedHeight = video.height,
              codedWidth > 0, codedHeight > 0 else {
            throw WatchthroughFailure(.usage, "source contains no usable video stream")
        }
        let first = video.startTime.flatMap(Double.init)
            ?? document.format?.startTime.flatMap(Double.init) ?? 0
        let containerDuration = document.format?.duration.flatMap(Double.init)
        // Container duration can include a nonzero start timestamp. Prefer the
        // stream's actual duration whenever the container provides it.
        let fallback = containerDuration.map { duration in
            // Matroska's Segment Duration is measured from timestamp zero;
            // FFmpeg exposes this unchanged even for a nonzero first frame.
            // Other demuxers (for example MPEG-TS) report elapsed duration.
            let matroska = document.format?.formatName?.split(separator: ",").contains("matroska") == true
            return matroska ? duration - first : duration
        }
        guard first.isFinite else {
            throw WatchthroughFailure(.operation, "video start timestamp is invalid")
        }
        guard let duration = firstFinitePositive([video.duration.flatMap(Double.init), fallback]) else {
            // Preserve support for valid local live-muxed Matroska/WebM files.
            // They carry frame timestamps but no container or stream duration.
            // The legacy full probe derives the span and final frame duration.
            return try probe(source, ffprobe: ffprobe).info
        }
        let geometry = displayGeometry(video, width: codedWidth, height: codedHeight)
        return MediaInfo(
            durationSeconds: duration,
            width: geometry.width,
            height: geometry.height,
            codec: video.codecName,
            pixelFormat: video.pixelFormat,
            averageFrameRate: nonEmptyRate(video.averageFrameRate),
            realFrameRate: nonEmptyRate(video.realFrameRate),
            timeBase: video.timeBase,
            hasAudio: document.streams.contains { $0.codecType == "audio" },
            frameCount: 0,
            firstPTS: first,
            lastPTS: first + duration,
            audioStartPTS: document.streams.first(where: { $0.codecType == "audio" })?.startTime.flatMap(Double.init)
                ?? document.format?.startTime.flatMap(Double.init),
            containerStartPTS: document.format?.startTime.flatMap(Double.init)
        )
    }

    /// Reads container metadata and a frame-accurate decoded index. `ffprobe`
    /// `best_effort_timestamp_time` is retained for every decoded video frame.
    public static func probe(_ source: URL, ffprobe: String = "ffprobe") throws -> ProbedMedia {
        let source = try SourceInspector.validate(source)
        let metadataOutput = try ProcessRunner.run(
            ffprobe,
            arguments: [
                "-v", "error",
                "-threads", String(MediaResourcePolicy.threads),
                "-show_entries",
                "format=duration,start_time:stream=index,codec_type,codec_name,pix_fmt,width,height,sample_aspect_ratio,avg_frame_rate,r_frame_rate,time_base,duration,start_time:stream_side_data=rotation",
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

        let tailFrames = frames.suffix(31)
        let positiveGaps = zip(tailFrames, tailFrames.dropFirst())
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

        let geometry = displayGeometry(video, width: width, height: height)
        let info = MediaInfo(
            durationSeconds: duration,
            width: geometry.width,
            height: geometry.height,
            codec: video.codecName,
            pixelFormat: video.pixelFormat,
            averageFrameRate: nonEmptyRate(video.averageFrameRate),
            realFrameRate: nonEmptyRate(video.realFrameRate),
            timeBase: video.timeBase,
            hasAudio: document.streams.contains { $0.codecType == "audio" },
            frameCount: frames.count,
            firstPTS: first.ptsSeconds,
            lastPTS: last.ptsSeconds,
            audioStartPTS: document.streams.first(where: { $0.codecType == "audio" })?.startTime.flatMap(Double.init)
                ?? document.format?.startTime.flatMap(Double.init),
            containerStartPTS: document.format?.startTime.flatMap(Double.init)
        )
        return ProbedMedia(info: info, frames: frames)
    }

    public static func decodedFrameIndex(
        for source: URL,
        ffprobe: String = "ffprobe"
    ) throws -> [FramePoint] {
        let source = try SourceInspector.validate(source)
        let collector = FrameIndexCollector()
        try ProcessRunner.run(
            ffprobe,
            arguments: [
                "-v", "error",
                "-threads", String(MediaResourcePolicy.threads),
                "-select_streams", "v:0",
                "-show_frames",
                "-show_entries", "frame=best_effort_timestamp_time",
                "-of", "compact=p=1:nk=0",
                source.path,
            ],
            stdoutConsumer: collector.consume
        ).requireSuccess("ffprobe could not build the decoded frame index")
        return try collector.finish()
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

    private static func displayGeometry(_ video: ProbeStream, width: Int, height: Int) -> (width: Int, height: Int) {
        let parts = video.sampleAspectRatio?.split(separator: ":").compactMap { Double($0) } ?? []
        let ratio = parts.count == 2 && parts[0].isFinite && parts[1].isFinite && parts[0] > 0 && parts[1] > 0
            ? parts[0] / parts[1] : 1
        // Expand the compressed display axis instead of discarding source pixels.
        let displayWidth = Int((Double(width) * max(1, ratio)).rounded())
        let displayHeight = Int((Double(height) * max(1, 1 / ratio)).rounded())
        let rotation = video.sideDataList?.compactMap(\.rotation).first ?? 0
        let swapped = abs(Int((rotation / 90).rounded())) % 2 == 1
        return swapped ? (displayHeight, displayWidth) : (displayWidth, displayHeight)
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
    let sampleAspectRatio: String?
    let averageFrameRate: String?
    let realFrameRate: String?
    let timeBase: String?
    let duration: String?
    let startTime: String?
    let sideDataList: [ProbeSideData]?

    private enum CodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case codecName = "codec_name"
        case pixelFormat = "pix_fmt"
        case width
        case height
        case sampleAspectRatio = "sample_aspect_ratio"
        case averageFrameRate = "avg_frame_rate"
        case realFrameRate = "r_frame_rate"
        case timeBase = "time_base"
        case duration
        case startTime = "start_time"
        case sideDataList = "side_data_list"
    }
}

private struct ProbeFormat: Decodable {
    let duration: String?
    let startTime: String?
    let formatName: String?

    enum CodingKeys: String, CodingKey {
        case duration
        case startTime = "start_time"
        case formatName = "format_name"
    }
}

private struct ProbeSideData: Decodable {
    let rotation: Double?
}

/// Stream the explicit index instead of retaining FFprobe's complete JSON text
/// and a second decoded document alongside the final FramePoint array.
final class FrameIndexCollector {
    private var pending = Data()
    private var frames: [FramePoint] = []

    func consume(_ data: Data) throws {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            try line(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        guard pending.count <= 1_048_576 else {
            throw WatchthroughFailure(.operation, "ffprobe returned an oversized frame-index record")
        }
    }

    func finish() throws -> [FramePoint] {
        if !pending.isEmpty {
            try line(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        return frames
    }

    private func line(_ value: String) throws {
        guard !value.isEmpty else { return }
        guard value.hasPrefix("frame|") else {
            throw WatchthroughFailure(.operation, "ffprobe returned an unexpected frame-index record")
        }
        let key = "best_effort_timestamp_time="
        guard let field = value.split(separator: "|").first(where: { $0.hasPrefix(key) }),
              let pts = Double(field.dropFirst(key.count)), pts.isFinite else {
            throw WatchthroughFailure(.operation, "decoded frame \(frames.count) has no usable best-effort timestamp")
        }
        guard frames.last.map({ pts >= $0.ptsSeconds }) ?? true else {
            throw WatchthroughFailure(.operation, "decoded frame timestamps are not monotonic")
        }
        frames.append(FramePoint(ordinal: frames.count, ptsSeconds: pts))
    }
}
