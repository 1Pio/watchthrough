import Foundation

/// Deterministic, low-resolution visual change analysis.
///
/// The analyzer asks ffmpeg for a single RGB24 stream, then performs all scoring
/// locally. It deliberately reports evidence rather than claiming semantic scene
/// understanding: event IDs are a stable relevance ranking, with E0001 being the
/// strongest candidate.
public enum VisualAnalyzer {
    public static let defaultSampleLimit = 7_200
    public static let maximumScanFPS = 2.0

    /// Keeps scans bounded to at most `sampleLimit` frames and never exceeds 2 fps.
    public static func scanFPS(
        durationSeconds: Double,
        sampleLimit: Int = defaultSampleLimit
    ) throws -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw WatchthroughFailure(.operation, "Cannot scan media with a missing or non-positive duration.")
        }
        guard sampleLimit > 0 else {
            throw WatchthroughFailure(.usage, "Visual sample limit must be greater than zero.")
        }
        return min(maximumScanFPS, Double(sampleLimit) / durationSeconds)
    }

    /// Chooses a small, even RGB frame while retaining the source aspect ratio.
    public static func sampleDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumLongEdge: Int = 160
    ) throws -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw WatchthroughFailure(.operation, "Cannot scan media with invalid video dimensions.")
        }
        let boundedLongEdge = max(2, maximumLongEdge - maximumLongEdge % 2)
        let scale = min(1, Double(boundedLongEdge) / Double(max(sourceWidth, sourceHeight)))

        func even(_ value: Double) -> Int {
            let rounded = max(2, Int(value.rounded()))
            let lower = rounded - rounded % 2
            let upper = lower + 2
            return abs(Double(lower) - value) <= abs(Double(upper) - value) ? max(2, lower) : upper
        }

        return (even(Double(sourceWidth) * scale), even(Double(sourceHeight) * scale))
    }

    /// Runs one ffmpeg decode and returns the canonical event index model.
    public static func scan(
        source: URL,
        media: MediaInfo,
        sampleLimit: Int = defaultSampleLimit,
        ffmpegPath: String = "ffmpeg"
    ) throws -> EventIndex {
        let fps = try scanFPS(durationSeconds: media.durationSeconds, sampleLimit: sampleLimit)
        let size = try sampleDimensions(sourceWidth: media.width, sourceHeight: media.height)
        let fpsText = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), fps)
        let firstPTSText = String(
            format: "%.12g",
            locale: Locale(identifier: "en_US_POSIX"),
            media.firstPTS
        )
        let filter = "fps=fps=\(fpsText):start_time=\(firstPTSText),scale=\(size.width):\(size.height):flags=bilinear"
        let arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-copyts", "-i", source.path,
            "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", filter,
            "-frames:v", String(sampleLimit),
            "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1",
        ]

        let accumulator = VisualAccumulator(
            width: size.width,
            height: size.height,
            scanFPS: fps,
            timelineStartSeconds: media.firstPTS,
            timelineEndSeconds: media.lastPTS
        )
        try RawRGBDecoder.run(
            executable: ffmpegPath,
            arguments: arguments,
            bytesPerFrame: size.width * size.height * 3,
            consume: accumulator.consume
        )
        return try accumulator.finish()
    }

    /// Pure analysis entry point used by fixture tests and embedders.
    /// Each data value must be one complete RGB24 frame.
    public static func analyzeRGBFrames(
        _ frames: [Data],
        width: Int,
        height: Int,
        scanFPS: Double,
        durationSeconds: Double? = nil,
        startPTSSeconds: Double = 0
    ) throws -> EventIndex {
        guard width > 0, height > 0, scanFPS.isFinite, scanFPS > 0,
              startPTSSeconds.isFinite else {
            throw WatchthroughFailure(.usage, "RGB analysis requires positive dimensions and scan rate.")
        }
        let inferredDuration = frames.isEmpty ? 0 : Double(frames.count) / scanFPS
        let duration = durationSeconds ?? inferredDuration
        guard duration.isFinite, duration >= 0 else {
            throw WatchthroughFailure(.usage, "RGB analysis requires a finite, non-negative duration.")
        }
        let accumulator = VisualAccumulator(
            width: width,
            height: height,
            scanFPS: scanFPS,
            timelineStartSeconds: startPTSSeconds,
            timelineEndSeconds: startPTSSeconds + duration
        )
        for frame in frames {
            try accumulator.consume(frame)
        }
        return try accumulator.finish()
    }
}

private final class VisualAccumulator {
    private let width: Int
    private let height: Int
    private let scanFPS: Double
    private let timelineStartSeconds: Double
    private let timelineEndSeconds: Double
    private let bytesPerFrame: Int
    private let anchorDistance: Int
    private let baselineWindow: Int

    private var history: [Data] = []
    private var rawHistory: [Double] = []
    private var samples: [VisualSample] = []

    init(
        width: Int,
        height: Int,
        scanFPS: Double,
        timelineStartSeconds: Double,
        timelineEndSeconds: Double
    ) {
        self.width = width
        self.height = height
        self.scanFPS = scanFPS
        self.timelineStartSeconds = timelineStartSeconds
        self.timelineEndSeconds = max(timelineStartSeconds, timelineEndSeconds)
        self.bytesPerFrame = width * height * 3
        self.anchorDistance = max(1, Int((scanFPS * 1.5).rounded()))
        self.baselineWindow = max(8, Int((scanFPS * 12).rounded()))
    }

    func consume(_ frame: Data) throws {
        guard frame.count == bytesPerFrame else {
            throw WatchthroughFailure(
                .operation,
                "ffmpeg returned a partial RGB frame (expected \(bytesPerFrame) bytes, received \(frame.count))."
            )
        }

        let pts = min(
            timelineEndSeconds,
            timelineStartSeconds + Double(samples.count) / scanFPS
        )
        guard let previous = history.last else {
            samples.append(VisualSample(
                ptsSeconds: pts,
                globalChange: 0,
                regionalChange: 0,
                outerChange: 0,
                colorShift: 0,
                adaptiveScore: 0,
                fired: false
            ))
            history.append(frame)
            return
        }

        let adjacent = FrameMetrics.measure(current: frame, reference: previous, width: width, height: height)
        let anchor = history.count >= anchorDistance
            ? history[history.count - anchorDistance]
            : history[0]
        let rolling = FrameMetrics.measure(current: frame, reference: anchor, width: width, height: height)
        let metrics = adjacent.merged(with: rolling, rollingWeight: 0.65)

        let weighted = (
            0.42 * metrics.global
                + 0.28 * metrics.regional
                + 0.15 * metrics.outer
                + 0.15 * metrics.color
        )
        let raw = max(
            weighted,
            metrics.global,
            0.76 * metrics.regional,
            0.70 * metrics.outer,
            0.82 * metrics.color
        )
        let recent = Array(rawHistory.suffix(baselineWindow))
        let median = Statistics.median(recent)
        let deviations = recent.map { abs($0 - median) }
        let mad = Statistics.median(deviations)
        let threshold = max(0.025, median + max(0.012, 4 * mad))
        let adaptive = raw / threshold

        // Absolute gates catch hard cuts. The adaptive gate catches localized
        // graphics and slower morphs while the robust baseline suppresses normal
        // continuous motion.
        let fired = raw >= 0.13
            || (metrics.regional >= 0.22 && metrics.global >= 0.012)
            || metrics.outer >= 0.20
            || metrics.color >= 0.14
            || (adaptive >= 1.50 && raw >= 0.035)

        samples.append(VisualSample(
            ptsSeconds: pts,
            globalChange: metrics.global,
            regionalChange: metrics.regional,
            outerChange: metrics.outer,
            colorShift: metrics.color,
            adaptiveScore: adaptive,
            fired: fired
        ))
        rawHistory.append(raw)
        history.append(frame)
        if history.count > anchorDistance + 1 {
            history.removeFirst(history.count - anchorDistance - 1)
        }
    }

    func finish() throws -> EventIndex {
        guard !samples.isEmpty else {
            throw WatchthroughFailure(.operation, "ffmpeg decoded no video frames.")
        }
        return EventIndex(
            scanFPS: scanFPS,
            sampleWidth: width,
            sampleHeight: height,
            samples: samples,
            events: EventBuilder.build(
                samples: samples,
                scanFPS: scanFPS,
                timelineStartSeconds: timelineStartSeconds,
                timelineEndSeconds: timelineEndSeconds
            )
        )
    }
}

private struct FrameMetrics {
    var global: Double
    var regional: Double
    var outer: Double
    var color: Double

    func merged(with other: FrameMetrics, rollingWeight: Double) -> FrameMetrics {
        FrameMetrics(
            global: max(global, other.global * rollingWeight),
            regional: max(regional, other.regional * rollingWeight),
            outer: max(outer, other.outer * rollingWeight),
            color: max(color, other.color * rollingWeight)
        )
    }

    static func measure(current: Data, reference: Data, width: Int, height: Int) -> FrameMetrics {
        let gridColumns = 4
        let gridRows = 4
        var globalDifference: Int64 = 0
        var outerDifference: Int64 = 0
        var outerPixels: Int64 = 0
        var cellDifference = [Int64](repeating: 0, count: gridColumns * gridRows)
        var cellPixels = [Int64](repeating: 0, count: gridColumns * gridRows)
        var currentRGB = [Int64](repeating: 0, count: 3)
        var referenceRGB = [Int64](repeating: 0, count: 3)

        current.withUnsafeBytes { currentRaw in
            reference.withUnsafeBytes { referenceRaw in
                let currentBytes = currentRaw.bindMemory(to: UInt8.self)
                let referenceBytes = referenceRaw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = (y * width + x) * 3
                        let cr = Int(currentBytes[offset])
                        let cg = Int(currentBytes[offset + 1])
                        let cb = Int(currentBytes[offset + 2])
                        let rr = Int(referenceBytes[offset])
                        let rg = Int(referenceBytes[offset + 1])
                        let rb = Int(referenceBytes[offset + 2])
                        let currentLuma = (77 * cr + 150 * cg + 29 * cb) >> 8
                        let referenceLuma = (77 * rr + 150 * rg + 29 * rb) >> 8
                        let difference = Int64(abs(currentLuma - referenceLuma))

                        globalDifference += difference
                        let column = min(gridColumns - 1, x * gridColumns / width)
                        let row = min(gridRows - 1, y * gridRows / height)
                        let cell = row * gridColumns + column
                        cellDifference[cell] += difference
                        cellPixels[cell] += 1

                        let borderX = max(1, width / 6)
                        let borderY = max(1, height / 6)
                        if x < borderX || x >= width - borderX || y < borderY || y >= height - borderY {
                            outerDifference += difference
                            outerPixels += 1
                        }

                        currentRGB[0] += Int64(cr)
                        currentRGB[1] += Int64(cg)
                        currentRGB[2] += Int64(cb)
                        referenceRGB[0] += Int64(rr)
                        referenceRGB[1] += Int64(rg)
                        referenceRGB[2] += Int64(rb)
                    }
                }
            }
        }

        let pixels = Double(width * height)
        let global = Double(globalDifference) / (pixels * 255)
        let cellScores = zip(cellDifference, cellPixels).map { difference, count in
            count == 0 ? 0 : Double(difference) / (Double(count) * 255)
        }.sorted(by: >)
        let leadingCells = cellScores.prefix(3)
        let regional = leadingCells.isEmpty
            ? 0
            : leadingCells.reduce(0, +) / Double(leadingCells.count)
        let outer = outerPixels == 0 ? 0 : Double(outerDifference) / (Double(outerPixels) * 255)

        var squaredColorDifference = 0.0
        for channel in 0..<3 {
            let currentMean = Double(currentRGB[channel]) / pixels
            let referenceMean = Double(referenceRGB[channel]) / pixels
            squaredColorDifference += pow(currentMean - referenceMean, 2)
        }
        let color = sqrt(squaredColorDifference) / (sqrt(3) * 255)
        return FrameMetrics(global: global, regional: regional, outer: outer, color: color)
    }
}

private enum Statistics {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }
}

private enum EventBuilder {
    private struct Candidate {
        var indices: [Int]
        var startSeconds: Double
        var endSeconds: Double
        var peakSeconds: Double
        var peakScore: Double
        var peakMetric: String
    }

    static func build(
        samples: [VisualSample],
        scanFPS: Double,
        timelineStartSeconds: Double,
        timelineEndSeconds: Double
    ) -> [VisualEvent] {
        let fired = samples.indices.filter { samples[$0].fired }
        guard !fired.isEmpty else { return [] }

        let interval = 1 / scanFPS
        let joinWindow = max(0.75, 2.1 * interval)
        var groups: [[Int]] = []
        for index in fired {
            if let lastIndex = groups.last?.last,
               samples[index].ptsSeconds - samples[lastIndex].ptsSeconds <= joinWindow {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }

        var candidates = groups.map { indices -> Candidate in
            let peakIndex = indices.max { lhs, rhs in
                let left = samples[lhs]
                let right = samples[rhs]
                if left.adaptiveScore == right.adaptiveScore {
                    return left.ptsSeconds > right.ptsSeconds
                }
                return left.adaptiveScore < right.adaptiveScore
            } ?? indices[0]
            let peak = samples[peakIndex]
            let namedMetrics: [(String, Double)] = [
                ("global", peak.globalChange),
                ("regional", peak.regionalChange),
                ("outer", peak.outerChange),
                ("color", peak.colorShift),
            ]
            let peakMetric = namedMetrics.max { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
            }?.0 ?? "global"
            return Candidate(
                indices: indices,
                startSeconds: max(
                    timelineStartSeconds,
                    samples[indices[0]].ptsSeconds - interval / 2
                ),
                endSeconds: min(
                    timelineEndSeconds,
                    samples[indices[indices.count - 1]].ptsSeconds + interval / 2
                ),
                peakSeconds: peak.ptsSeconds,
                peakScore: peak.adaptiveScore,
                peakMetric: peakMetric
            )
        }

        // Relevance-first output makes event IDs useful to agents. Time is a
        // deterministic tiebreaker, so equal-score runs remain stable.
        candidates.sort {
            if $0.peakScore != $1.peakScore { return $0.peakScore > $1.peakScore }
            if $0.peakSeconds != $1.peakSeconds { return $0.peakSeconds < $1.peakSeconds }
            return $0.startSeconds < $1.startSeconds
        }
        return candidates.enumerated().map { offset, candidate in
            VisualEvent(
                id: String(format: "E%04d", offset + 1),
                startSeconds: candidate.startSeconds,
                endSeconds: candidate.endSeconds,
                peakSeconds: candidate.peakSeconds,
                peakScore: candidate.peakScore,
                peakMetric: candidate.peakMetric,
                sampleCount: candidate.indices.count
            )
        }
    }
}

private enum RawRGBDecoder {
    static func run(
        executable: String,
        arguments: [String],
        bytesPerFrame: Int,
        consume: (Data) throws -> Void
    ) throws {
        let process = Process()
        process.executableURL = try Tooling.require(executable)
        process.arguments = arguments
        process.environment = ProcessRunner.constrainedEnvironment()
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw WatchthroughFailure(.readiness, "Could not start ffmpeg at \(executable): \(error.localizedDescription)")
        }
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()

        let errorSlot = LockedData()
        let errorReader = DispatchGroup()
        errorReader.enter()
        DispatchQueue.global(qos: .utility).async {
            errorSlot.set(errors.fileHandleForReading.readDataToEndOfFile())
            errorReader.leave()
        }

        var pending = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: max(bytesPerFrame, 64 * 1_024)),
                  !chunk.isEmpty {
                pending.append(chunk)
                while pending.count >= bytesPerFrame {
                    let frame = pending.prefix(bytesPerFrame)
                    try consume(Data(frame))
                    pending.removeFirst(bytesPerFrame)
                }
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            errorReader.wait()
            throw error
        }

        process.waitUntilExit()
        errorReader.wait()
        let errorData = errorSlot.value
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WatchthroughFailure(.operation, "ffmpeg visual scan failed\(message.map { ": \($0)" } ?? ".")")
        }
        guard pending.isEmpty else {
            throw WatchthroughFailure(.operation, "ffmpeg ended with an incomplete RGB frame.")
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Data) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

public struct ExtractedFrame: Equatable, Sendable {
    public var ordinal: Int
    public var url: URL

    public init(ordinal: Int, url: URL) {
        self.ordinal = ordinal
        self.url = url
    }
}

/// Exact ordinal extraction through a single ffmpeg invocation.
public enum FrameExtractor {
    public static func extract(
        source: URL,
        selectedFrames: [FramePoint],
        frameIndex: [FramePoint],
        destinationDirectory: URL,
        maximumWidth: Int? = 1_920,
        ffmpegPath: String = "ffmpeg"
    ) throws -> [ExtractedFrame] {
        let selected = Dictionary(
            selectedFrames.map { ($0.ordinal, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.ordinal < $1.ordinal }
        guard !selected.isEmpty else { return [] }
        guard !frameIndex.isEmpty,
              frameIndex.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
              selected.allSatisfy({ point in
                  frameIndex.indices.contains(point.ordinal)
                      && frameIndex[point.ordinal] == point
              }) else {
            throw WatchthroughFailure(.usage, "Selected frames must belong to the supplied decoded frame index.")
        }

        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let operationDirectory = destinationDirectory.appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: operationDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: operationDirectory) }

        let firstTarget = selected[0]
        let leadThreshold = firstTarget.ptsSeconds - 1
        let anchorOrdinal = lowerBoundPTS(leadThreshold, in: frameIndex)
        let seekPTS: Double
        if anchorOrdinal == 0 {
            seekPTS = frameIndex[0].ptsSeconds
        } else {
            seekPTS = (frameIndex[anchorOrdinal - 1].ptsSeconds + frameIndex[anchorOrdinal].ptsSeconds) / 2
        }
        let seekSeconds = max(0, seekPTS - frameIndex[0].ptsSeconds)
        let selection = selected
            .map { "eq(n\\,\($0.ordinal - anchorOrdinal))" }
            .joined(separator: "+")
        var filter = "select=\(selection)"
        if let maximumWidth {
            let evenWidth = max(2, maximumWidth - maximumWidth % 2)
            filter += ",scale=min(\(evenWidth)\\,iw):-2:flags=lanczos"
        }
        let outputPattern = operationDirectory.appendingPathComponent("frame-%06d.jpg").path
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-copyts",
        ]
        if seekSeconds > 0.000_000_5 {
            arguments += [
                "-ss",
                String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), seekSeconds),
            ]
        }
        arguments += [
            "-i", source.path,
            "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", filter,
            "-fps_mode", "vfr", "-q:v", "2", "-start_number", "0",
            "-frames:v", String(selected.count),
            outputPattern,
        ]
        try SimpleProcess.run(executable: ffmpegPath, arguments: arguments, purpose: "frame extraction")

        var result: [ExtractedFrame] = []
        let planned = selected.enumerated().map { sequence, point in
            (
                ordinal: point.ordinal,
                temporary: operationDirectory.appendingPathComponent(String(format: "frame-%06d.jpg", sequence)),
                target: destinationDirectory.appendingPathComponent(String(format: "frame-o%08d.jpg", point.ordinal))
            )
        }
        for item in planned {
            guard FileManager.default.fileExists(atPath: item.temporary.path) else {
                throw WatchthroughFailure(
                    .operation,
                    "ffmpeg extracted fewer frames than requested. Ordinal \(item.ordinal) may be outside the video."
                )
            }
            guard !FileManager.default.fileExists(atPath: item.target.path) else {
                throw WatchthroughFailure(.operation, "Refusing to overwrite existing frame at \(item.target.path).")
            }
        }

        for item in planned {
            try FileManager.default.moveItem(at: item.temporary, to: item.target)
            result.append(ExtractedFrame(ordinal: item.ordinal, url: item.target))
        }
        return result
    }

    private static func lowerBoundPTS(_ target: Double, in frames: [FramePoint]) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].ptsSeconds < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return min(low, frames.count - 1)
    }
}

private enum SimpleProcess {
    static func run(executable: String, arguments: [String], purpose: String) throws {
        try ProcessRunner.run(executable, arguments: arguments)
            .requireSuccess("ffmpeg \(purpose) failed")
    }
}
