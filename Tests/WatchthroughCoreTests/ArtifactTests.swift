import Foundation
import XCTest
@testable import WatchthroughCore

final class ArtifactTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testExclusiveLockAndValidatedAtomicDirectoryRefresh() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("analysis.lock")
        let first = try ExclusiveFileLock.acquire(at: lockURL)
        defer { first.unlock() }
        XCTAssertThrowsError(try ExclusiveFileLock.acquire(at: lockURL))

        let destination = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("marker.txt"))

        let staging = try ArtifactStaging.temporarySibling(for: destination)
        XCTAssertTrue(staging.lastPathComponent.hasPrefix(".watchthrough-analysis.tmp-"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("marker.txt"))
        try ArtifactStaging.replace(staging, at: destination) { candidate in
            let marker = candidate.appendingPathComponent("marker.txt")
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "new")
        }

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("marker.txt"), encoding: .utf8),
            "new"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testSharedAnalysisReadersExcludeWriterButNotEachOther() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("shared-analysis.lock")
        let firstReader = try ExclusiveFileLock.acquireShared(at: lockURL)
        let secondReader = try ExclusiveFileLock.acquireShared(at: lockURL)
        XCTAssertThrowsError(try ExclusiveFileLock.acquire(at: lockURL))

        firstReader.unlock()
        secondReader.unlock()

        let writer = try ExclusiveFileLock.acquire(at: lockURL)
        defer { writer.unlock() }
        XCTAssertThrowsError(try ExclusiveFileLock.acquireShared(at: lockURL))
    }

    func testLegacyPreparationConfigDecodesForSafeRefreshOwnershipCheck() throws {
        let legacy = Data(#"{"transcriber":"auto"}"#.utf8)
        let config = try StableJSON.decode(PreparationConfig.self, from: legacy)

        XCTAssertEqual(config.transcriber, "auto")
        XCTAssertEqual(config.transcriptInputFingerprint, "unspecified")
        XCTAssertEqual(config.visualSampleLimit, 7_200)
    }

    func testPreparationReuseRequiresEveryOverviewFrameReferencedByPacket() throws {
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        let overview = analysis
            .appendingPathComponent("visual", isDirectory: true)
            .appendingPathComponent("overview", isDirectory: true)
        let framesDirectory = overview.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        let frameIndex = [
            FramePoint(ordinal: 0, ptsSeconds: 5),
            FramePoint(ordinal: 1, ptsSeconds: 6),
        ]
        try FrameIndexTSV.write(
            frameIndex,
            to: analysis.appendingPathComponent("visual/frame-index.tsv")
        )

        let firstFrame = framesDirectory.appendingPathComponent("frame-o00000000.jpg")
        let lastFrame = framesDirectory.appendingPathComponent("frame-o00000001.jpg")
        try Data("first-frame".utf8).write(to: firstFrame)
        try Data("last-frame".utf8).write(to: lastFrame)
        try Data("strip".utf8).write(to: overview.appendingPathComponent("strip-01.png"))

        let cells = frameIndex.enumerated().map { index, frame in
            PacketCell(
                index: index,
                ordinal: frame.ordinal,
                ptsSeconds: frame.ptsSeconds,
                intervalStartSeconds: frame.ptsSeconds,
                intervalEndSeconds: frame.ptsSeconds.nextUp,
                timestamp: index == 0 ? "00:05" : "00:06",
                caption: "",
                framePath: String(format: "frames/frame-o%08d.jpg", frame.ordinal)
            )
        }
        let packet = InspectionPacket(
            selector: "overview",
            sourcePath: "/fixture/video.mp4",
            rangeStartSeconds: 5,
            rangeEndSeconds: 6.nextUp,
            sampling: "uniform overview (target 2)",
            cellsPerSheet: 15,
            largestGapSeconds: 1,
            timingPrecision: .none,
            cells: cells,
            sheets: ["strip-01.png"]
        )
        try StableJSON.write(packet, to: overview.appendingPathComponent("packet.json"))
        try PacketMarkdown.write(packet, to: overview.appendingPathComponent("packet.md"))

        let events = EventIndex(
            scanFPS: 2,
            sampleWidth: 160,
            sampleHeight: 90,
            samples: [VisualSample(
                ptsSeconds: 5,
                globalChange: 0,
                regionalChange: 0,
                outerChange: 0,
                colorShift: 0,
                adaptiveScore: 0,
                fired: false
            )],
            events: []
        )
        try StableJSON.write(events, to: analysis.appendingPathComponent("visual/events.json"))

        let source = SourceRecord(
            path: packet.sourcePath,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1_024,
            modifiedAt: "2026-07-17T00:00:00Z"
        )
        let config = PreparationConfig(transcriber: "none", transcriptInputFingerprint: "none")
        let manifest = PreparationManifest(
            createdAt: "2026-07-17T00:00:00Z",
            completedAt: "2026-07-17T00:00:01Z",
            source: source,
            media: MediaInfo(
                durationSeconds: 1,
                width: 1_920,
                height: 1_080,
                hasAudio: false,
                frameCount: 2,
                firstPTS: 5,
                lastPTS: 6
            ),
            config: config,
            transcript: TranscriptSummary(available: false),
            visual: VisualSummary(
                frameIndexPath: "visual/frame-index.tsv",
                overviewPacketPath: "visual/overview/packet.json",
                eventsPath: "visual/events.json",
                overviewFrames: 2,
                largestOverviewGapSeconds: 1,
                eventCount: 0,
                scanFPS: 2
            ),
            tools: ["watchthrough": WatchthroughVersion.current],
            warnings: []
        )
        let manifestURL = analysis.appendingPathComponent("manifest.json")
        try ManifestStore.write(manifest, to: manifestURL)

        XCTAssertNotNil(try ManifestStore.reusable(
            at: manifestURL,
            matching: source,
            config: config,
            artifactRoot: analysis
        ))

        try FileManager.default.removeItem(at: lastFrame)

        XCTAssertNil(try ManifestStore.reusable(
            at: manifestURL,
            matching: source,
            config: config,
            artifactRoot: analysis
        ))
    }
}
