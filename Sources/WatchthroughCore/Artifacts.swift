import Darwin
import Foundation

public enum FrameIndexTSV {
    public static let header = "ordinal\tpts_seconds"

    public static func write(_ frames: [FramePoint], to url: URL) throws {
        try validate(frames)
        var text = header + "\n"
        for frame in frames {
            text += String(
                format: "%d\t%.9f\n",
                locale: Locale(identifier: "en_US_POSIX"),
                frame.ordinal,
                frame.ptsSeconds
            )
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> [FramePoint] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw WatchthroughFailure(.operation, "cannot read frame index: \(url.path)")
        }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first == Substring(header) else {
            throw WatchthroughFailure(.operation, "frame index has an invalid TSV header")
        }
        var frames: [FramePoint] = []
        frames.reserveCapacity(max(0, lines.count - 1))
        for (offset, line) in lines.dropFirst().enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let ordinal = Int(fields[0]),
                  let pts = Double(fields[1]),
                  pts.isFinite else {
                throw WatchthroughFailure(.operation, "invalid frame index row \(offset + 2)")
            }
            frames.append(FramePoint(ordinal: ordinal, ptsSeconds: pts))
        }
        try validate(frames)
        return frames
    }

    private static func validate(_ frames: [FramePoint]) throws {
        guard !frames.isEmpty else {
            throw WatchthroughFailure(.operation, "frame index is empty")
        }
        for (expected, frame) in frames.enumerated() {
            guard frame.ordinal == expected, frame.ptsSeconds.isFinite else {
                throw WatchthroughFailure(.operation, "frame index ordinals are not contiguous")
            }
            if expected > 0, frame.ptsSeconds < frames[expected - 1].ptsSeconds {
                throw WatchthroughFailure(.operation, "frame index timestamps are not monotonic")
            }
        }
    }
}

public enum FrameSelector {
    public static func nearest(to seconds: Double, in frames: [FramePoint]) -> FramePoint? {
        frames.min {
            let lhs = abs($0.ptsSeconds - seconds)
            let rhs = abs($1.ptsSeconds - seconds)
            return lhs == rhs ? $0.ordinal < $1.ordinal : lhs < rhs
        }
    }

    public static func atOrdinal(_ ordinal: Int, in frames: [FramePoint]) -> FramePoint? {
        guard ordinal >= 0 else { return nil }
        if frames.indices.contains(ordinal), frames[ordinal].ordinal == ordinal {
            return frames[ordinal]
        }
        return frames.first { $0.ordinal == ordinal }
    }

    public static func everySeconds(
        _ interval: Double,
        in frames: [FramePoint],
        range: ClosedRange<Double>? = nil,
        maximumCount: Int? = nil
    ) throws -> [FramePoint] {
        guard interval.isFinite, interval > 0 else {
            throw WatchthroughFailure(.usage, "time sampling interval must be greater than zero")
        }
        let candidates = bounded(frames, to: range)
        guard let first = candidates.first, let last = candidates.last else { return [] }
        if let maximumCount {
            guard maximumCount > 0 else {
                throw WatchthroughFailure(.usage, "maximum selection count must be greater than zero")
            }
            let estimatedIntervals = ceil((last.ptsSeconds - first.ptsSeconds) / interval)
            guard estimatedIntervals.isFinite,
                  estimatedIntervals < Double(maximumCount) else {
                throw WatchthroughFailure(
                    .usage,
                    "inspection would extract more than \(maximumCount) frames; use a coarser --every interval or split the range"
                )
            }
            let upperBound = Int(estimatedIntervals) + 1
            guard upperBound <= maximumCount else {
                throw WatchthroughFailure(
                    .usage,
                    "inspection would extract about \(upperBound) frames; use a coarser --every interval or split the range (maximum \(maximumCount))"
                )
            }
        }

        var selected: [FramePoint] = [first]
        var target = first.ptsSeconds + interval
        while target < last.ptsSeconds {
            let point = candidates[nearestIndex(
                to: target,
                in: candidates,
                allowed: 0...(candidates.count - 1)
            )]
            if point.ordinal != selected.last?.ordinal {
                selected.append(point)
            }
            target += interval
        }
        if selected.last?.ordinal != last.ordinal { selected.append(last) }
        return selected
    }

    public static func everyFrames(
        _ interval: Int,
        in frames: [FramePoint],
        range: ClosedRange<Double>? = nil,
        maximumCount: Int? = nil
    ) throws -> [FramePoint] {
        guard interval > 0 else {
            throw WatchthroughFailure(.usage, "frame sampling interval must be greater than zero")
        }
        let candidates = bounded(frames, to: range)
        guard let last = candidates.last else { return [] }
        if let maximumCount {
            guard maximumCount > 0 else {
                throw WatchthroughFailure(.usage, "maximum selection count must be greater than zero")
            }
            let upperBound = Int(ceil(Double(max(0, candidates.count - 1)) / Double(interval))) + 1
            guard upperBound <= maximumCount else {
                throw WatchthroughFailure(
                    .usage,
                    "inspection would extract about \(upperBound) frames; use a coarser --every interval or split the range (maximum \(maximumCount))"
                )
            }
        }
        var selected = stride(from: 0, to: candidates.count, by: interval).map { candidates[$0] }
        if selected.last?.ordinal != last.ordinal { selected.append(last) }
        return selected
    }

    /// Produces broad, time-balanced coverage while always retaining the first
    /// and true last decoded frame in the selected range.
    public static func overview(
        maxCount: Int,
        in frames: [FramePoint],
        range: ClosedRange<Double>? = nil
    ) throws -> [FramePoint] {
        guard maxCount > 0 else {
            throw WatchthroughFailure(.usage, "overview frame count must be greater than zero")
        }
        let candidates = bounded(frames, to: range)
        guard candidates.count > maxCount else { return candidates }
        guard maxCount >= 2 else {
            throw WatchthroughFailure(.usage, "overview needs at least two frames to retain both endpoints")
        }

        var selectedIndices = [0]
        selectedIndices.reserveCapacity(maxCount)
        for position in 1..<(maxCount - 1) {
            let target = candidates[0].ptsSeconds
                + (candidates[candidates.count - 1].ptsSeconds - candidates[0].ptsSeconds)
                * Double(position) / Double(maxCount - 1)
            let remaining = maxCount - position - 1
            let lower = selectedIndices[selectedIndices.count - 1] + 1
            let upper = candidates.count - remaining - 1
            selectedIndices.append(nearestIndex(to: target, in: candidates, allowed: lower...upper))
        }
        selectedIndices.append(candidates.count - 1)
        return selectedIndices.map { candidates[$0] }
    }

    public static func largestGap(in frames: [FramePoint]) -> Double {
        zip(frames, frames.dropFirst())
            .map { max(0, $1.ptsSeconds - $0.ptsSeconds) }
            .max() ?? 0
    }

    private static func bounded(
        _ frames: [FramePoint],
        to range: ClosedRange<Double>?
    ) -> [FramePoint] {
        let sorted = frames.sorted {
            $0.ptsSeconds == $1.ptsSeconds
                ? $0.ordinal < $1.ordinal
                : $0.ptsSeconds < $1.ptsSeconds
        }
        guard let range else { return sorted }
        return sorted.filter { range.contains($0.ptsSeconds) }
    }

    private static func nearestIndex(
        to target: Double,
        in frames: [FramePoint],
        allowed: ClosedRange<Int>
    ) -> Int {
        var low = allowed.lowerBound
        var high = allowed.upperBound
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].ptsSeconds < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let after = low
        let before = max(allowed.lowerBound, after - 1)
        let beforeDistance = abs(frames[before].ptsSeconds - target)
        let afterDistance = abs(frames[after].ptsSeconds - target)
        return beforeDistance <= afterDistance ? before : after
    }
}

/// An advisory process lock. The kernel releases it on normal exit, crash, or
/// interruption, so no stale-lock cleanup policy is needed.
public final class ExclusiveFileLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquire(at url: URL, timeout: TimeInterval = 0) throws -> ExclusiveFileLock {
        try acquire(at: url, operation: LOCK_EX, timeout: timeout)
    }

    /// Shares an analysis lifetime lock with other readers while excluding a
    /// concurrent prepare or refresh. Per-inspection writes retain their own
    /// exclusive locks.
    public static func acquireShared(at url: URL, timeout: TimeInterval = 0) throws -> ExclusiveFileLock {
        try acquire(at: url, operation: LOCK_SH, timeout: timeout)
    }

    private static func acquire(
        at url: URL,
        operation: Int32,
        timeout: TimeInterval
    ) throws -> ExclusiveFileLock {
        guard timeout >= 0 else {
            throw WatchthroughFailure(.usage, "lock timeout cannot be negative")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchthroughFailure(.operation, "cannot open analysis lock: \(posixMessage())")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, operation | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                Darwin.close(descriptor)
                throw WatchthroughFailure(.operation, "cannot acquire analysis lock: \(posixMessage(code))")
            }
            guard timeout > 0, Date() < deadline else {
                Darwin.close(descriptor)
                let activity = operation == LOCK_SH ? "written" : "read or written"
                throw WatchthroughFailure(.operation, "analysis is already being \(activity) by another process")
            }
            usleep(100_000)
        }
        return ExclusiveFileLock(descriptor: descriptor)
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}

public enum ArtifactStaging {
    public static func temporarySibling(for destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let name = ".watchthrough-\(destination.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        let staging = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    /// Promotes a complete sibling directory in one filesystem move. Existing
    /// results are never overwritten implicitly.
    public static func promote(_ staging: URL, to destination: URL) throws {
        try validateSiblings(staging, destination)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WatchthroughFailure(.operation, "analysis destination already exists: \(destination.path)")
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            throw WatchthroughFailure(.operation, "could not promote completed analysis: \(error.localizedDescription)")
        }
    }

    /// Refresh is deliberately separate from normal promotion. The caller must
    /// fully validate the staged result before the existing analysis is replaced.
    /// Foundation performs the sibling replacement as one coordinated operation.
    public static func replace(
        _ staging: URL,
        at destination: URL,
        afterValidating validate: (URL) throws -> Void
    ) throws {
        try validateSiblings(staging, destination)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw WatchthroughFailure(.operation, "analysis to refresh does not exist: \(destination.path)")
        }
        try validate(staging)
        do {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } catch {
            throw WatchthroughFailure(.operation, "could not replace refreshed analysis: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public static func withDirectory<T>(
        for destination: URL,
        _ body: (URL) throws -> T
    ) throws -> T {
        let staging = try temporarySibling(for: destination)
        do {
            let result = try body(staging)
            try promote(staging, to: destination)
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func validateSiblings(_ staging: URL, _ destination: URL) throws {
        let sourceParent = staging.deletingLastPathComponent().standardizedFileURL
        let destinationParent = destination.deletingLastPathComponent().standardizedFileURL
        guard sourceParent == destinationParent else {
            throw WatchthroughFailure(.operation, "staging and destination must be siblings")
        }
        let values = try? staging.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw WatchthroughFailure(.operation, "staging result is not a directory")
        }
    }
}

public enum ManifestStore {
    public static func read(from url: URL) throws -> PreparationManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try StableJSON.decode(PreparationManifest.self, from: url)
        } catch {
            throw WatchthroughFailure(.operation, "analysis manifest is invalid: \(error.localizedDescription)")
        }
    }

    public static func write(_ manifest: PreparationManifest, to url: URL) throws {
        try StableJSON.write(manifest, to: url)
    }

    /// Returns a complete manifest only when its source, configuration, schema,
    /// tool version, and referenced local artifacts still match.
    public static func reusable(
        at manifestURL: URL,
        matching source: SourceRecord,
        config: PreparationConfig,
        artifactRoot: URL
    ) throws -> PreparationManifest? {
        do {
            guard let manifest = try read(from: manifestURL) else { return nil }
            guard manifest.schema == WatchthroughVersion.manifestSchema,
                  manifest.toolVersion == WatchthroughVersion.current,
                  manifest.state == "complete",
                  manifest.source.sha256 == source.sha256,
                  manifest.source.sizeBytes == source.sizeBytes,
                  manifest.config == config,
                  try artifactsAreReusable(manifest, under: artifactRoot) else {
                return nil
            }
            return manifest
        } catch {
            // Reuse is an opportunistic fast path. Any malformed, stale, unsafe,
            // or unreadable artifact must make it ineligible rather than turning
            // a validation detail into a partially trusted analysis.
            return nil
        }
    }

    private static func artifactsAreReusable(
        _ manifest: PreparationManifest,
        under artifactRoot: URL
    ) throws -> Bool {
        guard manifest.media.durationSeconds.isFinite,
              manifest.media.durationSeconds > 0,
              manifest.media.width > 0,
              manifest.media.height > 0,
              manifest.media.firstPTS.isFinite,
              manifest.media.lastPTS.isFinite,
              manifest.media.lastPTS >= manifest.media.firstPTS,
              let frameIndexURL = artifactURL(
                  relativePath: manifest.visual.frameIndexPath,
                  under: artifactRoot
              ),
              let overviewPacketURL = artifactURL(
                  relativePath: manifest.visual.overviewPacketPath,
                  under: artifactRoot
              ),
              let eventsURL = artifactURL(
                  relativePath: manifest.visual.eventsPath,
                  under: artifactRoot
              ) else {
            return false
        }

        let frames = try FrameIndexTSV.read(from: frameIndexURL)
        guard frames.count == manifest.media.frameCount,
              frames.first?.ordinal == 0,
              frames.last?.ordinal == manifest.media.frameCount - 1,
              nearlyEqual(frames.first?.ptsSeconds, manifest.media.firstPTS),
              nearlyEqual(frames.last?.ptsSeconds, manifest.media.lastPTS) else {
            return false
        }

        let packet = try StableJSON.decode(InspectionPacket.self, from: overviewPacketURL)
        guard overviewIsReusable(
            packet,
            packetRoot: overviewPacketURL.deletingLastPathComponent(),
            manifest: manifest,
            frames: frames
        ) else {
            return false
        }

        let events = try StableJSON.decode(EventIndex.self, from: eventsURL)
        guard eventsAreReusable(
            events,
            matching: manifest.visual,
            media: manifest.media
        ) else {
            return false
        }

        if manifest.transcript.available {
            guard let relativePath = manifest.transcript.path,
                  let textPath = manifest.transcript.textPath,
                  let transcriptURL = artifactURL(relativePath: relativePath, under: artifactRoot) else {
                return false
            }
            guard artifactURL(relativePath: textPath, under: artifactRoot) != nil else { return false }
            let transcript = try StableJSON.decode(CanonicalTranscript.self, from: transcriptURL)
            guard transcriptIsReusable(transcript, matching: manifest.transcript) else {
                return false
            }
            if let rawPath = manifest.transcript.rawPath,
               artifactURL(relativePath: rawPath, under: artifactRoot) == nil {
                return false
            }
        } else if manifest.transcript.path != nil
            || manifest.transcript.textPath != nil
            || manifest.transcript.rawPath != nil
            || manifest.transcript.provider != nil
            || manifest.transcript.model != nil
            || manifest.transcript.language != nil
            || manifest.transcript.speakersAvailable != nil
            || manifest.transcript.timingPrecision != .none {
            return false
        }

        return true
    }

    private static func overviewIsReusable(
        _ packet: InspectionPacket,
        packetRoot: URL,
        manifest: PreparationManifest,
        frames: [FramePoint]
    ) -> Bool {
        guard packet.schema == WatchthroughVersion.packetSchema,
              packet.selector == "overview",
              packet.sourcePath == manifest.source.path,
              packet.cells.count == manifest.visual.overviewFrames,
              packet.cells.first?.ordinal == frames.first?.ordinal,
              packet.cells.last?.ordinal == frames.last?.ordinal,
              packet.timingPrecision == (manifest.transcript.available
                  ? manifest.transcript.timingPrecision
                  : .none),
              (1...StripRenderOptions.hardMaximumCells).contains(packet.cellsPerSheet),
              packet.largestGapSeconds.isFinite,
              nearlyEqual(
                  packet.largestGapSeconds,
                  FrameSelector.largestGap(in: packet.cells.map {
                      FramePoint(ordinal: $0.ordinal, ptsSeconds: $0.ptsSeconds)
                  })
              ),
              nearlyEqual(packet.largestGapSeconds, manifest.visual.largestOverviewGapSeconds),
              artifactURL(relativePath: "packet.md", under: packetRoot) != nil else {
            return false
        }

        let expectedSheetCount = packet.cells.count > 1
            ? Int(ceil(Double(packet.cells.count) / Double(packet.cellsPerSheet)))
            : 0
        guard packet.sheets.count == expectedSheetCount else { return false }

        var framePaths = Set<String>()
        for (index, cell) in packet.cells.enumerated() {
            guard cell.index == index,
                  cell.ordinal >= 0,
                  cell.ordinal < frames.count,
                  cell.ptsSeconds.isFinite,
                  cell.intervalStartSeconds.isFinite,
                  cell.intervalEndSeconds.isFinite,
                  cell.intervalStartSeconds <= cell.ptsSeconds,
                  cell.intervalEndSeconds >= cell.ptsSeconds,
                  nearlyEqual(cell.ptsSeconds, frames[cell.ordinal].ptsSeconds),
                  framePaths.insert(cell.framePath).inserted,
                  artifactURL(relativePath: cell.framePath, under: packetRoot) != nil else {
                return false
            }
            if index > 0 {
                let prior = packet.cells[index - 1]
                guard prior.ordinal < cell.ordinal,
                      prior.ptsSeconds <= cell.ptsSeconds else {
                    return false
                }
            }
        }

        var sheetPaths = Set<String>()
        return packet.sheets.allSatisfy { path in
            sheetPaths.insert(path).inserted
                && artifactURL(relativePath: path, under: packetRoot) != nil
        }
    }

    private static func eventsAreReusable(
        _ index: EventIndex,
        matching summary: VisualSummary,
        media: MediaInfo
    ) -> Bool {
        guard index.schema == "watchthrough.events.v1",
              index.scanFPS.isFinite,
              index.scanFPS > 0,
              nearlyEqual(index.scanFPS, summary.scanFPS),
              index.sampleWidth > 0,
              index.sampleHeight > 0,
              !index.samples.isEmpty,
              index.events.count == summary.eventCount else {
            return false
        }

        for (offset, sample) in index.samples.enumerated() {
            let metrics = [
                sample.globalChange,
                sample.regionalChange,
                sample.outerChange,
                sample.colorShift,
                sample.adaptiveScore,
            ]
            let expectedPTS = min(
                media.lastPTS,
                media.firstPTS + Double(offset) / index.scanFPS
            )
            guard sample.ptsSeconds.isFinite,
                  metrics.allSatisfy({ $0.isFinite }),
                  metrics.allSatisfy({ $0 >= 0 }),
                  nearlyEqual(sample.ptsSeconds, expectedPTS) else {
                return false
            }
        }

        var eventIDs = Set<String>()
        for (offset, event) in index.events.enumerated() {
            guard event.id == String(format: "E%04d", offset + 1),
                  eventIDs.insert(event.id).inserted,
                  event.startSeconds.isFinite,
                  event.endSeconds.isFinite,
                  event.peakSeconds.isFinite,
                  event.peakScore.isFinite,
                  event.startSeconds >= media.firstPTS - 0.000_001,
                  event.endSeconds <= media.lastPTS + 0.000_001,
                  event.startSeconds <= event.peakSeconds,
                  event.peakSeconds <= event.endSeconds,
                  event.peakScore >= 0,
                  event.sampleCount > 0,
                  !event.peakMetric.isEmpty else {
                return false
            }
        }
        return true
    }

    private static func transcriptIsReusable(
        _ transcript: CanonicalTranscript,
        matching summary: TranscriptSummary
    ) -> Bool {
        guard transcript.schema == WatchthroughVersion.transcriptSchema,
              !transcript.provider.isEmpty,
              transcript.provider == summary.provider,
              transcript.model == summary.model,
              transcript.language == summary.language,
              summary.speakersAvailable == nil
                || transcript.speakersAvailable == summary.speakersAvailable,
              transcript.timingPrecision == summary.timingPrecision else {
            return false
        }

        var wordIDs = Set<String>()
        for word in transcript.words {
            guard !word.id.isEmpty,
                  wordIDs.insert(word.id).inserted,
                  word.startSeconds.isFinite,
                  word.endSeconds.isFinite,
                  word.endSeconds >= word.startSeconds,
                  word.confidence?.isFinite != false,
                  word.providerScore?.isFinite != false,
                  word.providerScore == nil || word.providerScoreKind?.isEmpty == false else {
                return false
            }
        }

        var segmentIDs = Set<String>()
        for segment in transcript.segments {
            guard !segment.id.isEmpty,
                  segmentIDs.insert(segment.id).inserted,
                  !segment.timingSource.isEmpty else {
                return false
            }
            if let start = segment.startSeconds,
               !start.isFinite {
                return false
            }
            if let end = segment.endSeconds,
               !end.isFinite {
                return false
            }
            if let start = segment.startSeconds,
               let end = segment.endSeconds,
               end < start {
                return false
            }
        }

        switch transcript.timingPrecision {
        case .word:
            return !transcript.words.isEmpty
        case .segment:
            return transcript.words.isEmpty
                && !transcript.segments.isEmpty
                && transcript.segments.allSatisfy {
                    $0.startSeconds != nil && $0.endSeconds != nil
                }
        case .none:
            return transcript.words.isEmpty
        }
    }

    private static func artifactURL(relativePath: String, under root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return nil
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0 ? candidate : nil
    }

    private static func nearlyEqual(
        _ lhs: Double?,
        _ rhs: Double,
        tolerance: Double = 0.000_001
    ) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= tolerance
    }
}

private func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
}
