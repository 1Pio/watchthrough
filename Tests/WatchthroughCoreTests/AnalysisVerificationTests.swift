import Foundation
import XCTest
@testable import WatchthroughCore

final class AnalysisVerificationTests: XCTestCase {
    private var root: URL!
    private var analysis: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-verification-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        analysis = root.appendingPathComponent("analysis")
        source = root.appendingPathComponent("source.mp4")
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try Data("source identity fixture".utf8).write(to: source)
        let manifest = PreparationManifest(createdAt: ISO8601Clock.now(), completedAt: ISO8601Clock.now(),
            source: try SourceInspector.record(for: source),
            media: MediaInfo(durationSeconds: 2, width: 320, height: 180, hasAudio: false, frameCount: 0, firstPTS: 0, lastPTS: 2),
            config: PreparationConfig(transcriber: "none"), transcript: TranscriptSummary(available: false, state: "disabled"),
            visual: VisualSummary(), tools: [:], warnings: [])
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
    }

    func testVerificationCountsOrdinaryPacketsAndOverviewOnceWithoutMediaTools() throws {
        let overview = try writePacket("overview-11111111", selector: "overview")
        _ = try writePacket("range-22222222")
        var manifest = try XCTUnwrap(ManifestStore.read(from: analysis.appendingPathComponent("manifest.json")))
        manifest.visual.overviewPacketPath = relative(overview)
        manifest.visual.overviewFrames = 2
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
        let staging = analysis.appendingPathComponent("inspections/.watchthrough-range-33333333.tmp-00000000-1111-2222-3333-444444444444")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("unfinished packet".utf8).write(to: staging.appendingPathComponent("packet.json"))
        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "", 1)
        defer { if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") } }
        let ordinary = status(verify: false)
        XCTAssertEqual(ordinary.exit, .success)
        XCTAssertNil(ordinary.response.result.details["verified_inspection_packets"])
        let verified = status(verify: true)
        XCTAssertEqual(verified.exit, .success)
        XCTAssertEqual(verified.response.result.details["verified_inspection_packets"], "2")
        XCTAssertEqual(verified.response.result.details["frame_index_state"], "deferred")
        XCTAssertEqual(verified.response.result.details["events_state"], "deferred")
        XCTAssertTrue(verified.response.result.warnings.contains { $0.contains("Incomplete stage artifacts") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("visual").path))
    }

    func testVerificationOfMetadataOnlyAnalysisReportsZeroPacketsWithoutCreatingStages() throws {
        let result = status(verify: true)
        XCTAssertEqual(result.exit, .success)
        XCTAssertEqual(result.response.result.details["verified_inspection_packets"], "0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: analysis.path), ["manifest.json"])
    }

    func testPreviousReleasedManifestRemainsReadableAfterVersionBump() throws {
        let manifestURL = analysis.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(ManifestStore.read(from: manifestURL))
        manifest.toolVersion = "0.2.0"
        try ManifestStore.write(manifest, to: manifestURL)
        XCTAssertEqual(status(verify: true).exit, .success)
        XCTAssertEqual(status(verify: false).exit, .success)
    }

    func testVerificationFindsOrdinaryPacketChecksumCorruptionWhileFastStatusStaysShallow() throws {
        let url = try writePacket("range-1234abcd")
        let frame = url.deletingLastPathComponent().appendingPathComponent("frames/frame-o00000000.jpg")
        let original = try Data(contentsOf: frame)
        var altered = original
        altered[0] ^= 1
        try altered.write(to: frame)
        XCTAssertEqual(status(verify: false).exit, .success)
        let result = status(verify: true)
        XCTAssertEqual(result.exit, .operation)
        XCTAssertEqual(result.response.result.details["analysis_state"], "invalid")
        let warning = result.response.result.warnings.joined(separator: "\n")
        XCTAssertTrue(warning.contains(relative(url)))
        XCTAssertTrue(warning.contains("frames/frame-o00000000.jpg"))
        XCTAssertTrue(warning.contains("checksum mismatch"))
        XCTAssertEqual(try Data(contentsOf: frame), altered, "verification must preserve evidence rather than regenerate it")
    }

    func testVerificationReportsMissingPacketAndWrongSourceWithTheirOwnedPaths() throws {
        let url = try writePacket("range-1234abcd")
        let saved = root.appendingPathComponent("saved-packet.json")
        try FileManager.default.moveItem(at: url, to: saved)
        var result = status(verify: true)
        XCTAssertEqual(result.exit, .operation)
        XCTAssertTrue(result.response.result.warnings.joined().contains(relative(url)))
        var packet = try StableJSON.decode(InspectionPacket.self, from: saved)
        packet.sourcePath = root.appendingPathComponent("another-source.mp4").path
        try StableJSON.write(packet, to: url)
        result = status(verify: true)
        XCTAssertEqual(result.exit, .operation)
        XCTAssertTrue(result.response.result.warnings.joined().contains("packet source does not match"))
    }

    func testVerificationRejectsSymlinkedOwnedPacketDirectory() throws {
        let url = try writePacket("range-1234abcd")
        let packetRoot = url.deletingLastPathComponent()
        let preserved = root.appendingPathComponent("preserved-packet")
        try FileManager.default.moveItem(at: packetRoot, to: preserved)
        try FileManager.default.createSymbolicLink(at: packetRoot, withDestinationURL: preserved)
        let result = status(verify: true)
        XCTAssertEqual(result.exit, .operation)
        XCTAssertTrue(result.response.result.warnings.joined().contains(relative(url)))
        XCTAssertTrue(result.response.result.warnings.joined().contains("symbolic link"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.appendingPathComponent("packet.json").path))
    }

    func testCacheLookupValidatesOnlyMatchingPacketsAndSkipsCorruptMatches() throws {
        let unrelated = try writePacket("a-unrelated-11111111", fingerprint: "other-evidence")
        let unrelatedFrame = unrelated.deletingLastPathComponent().appendingPathComponent("frames/frame-o00000000.jpg")
        try Data(repeating: 0x5a, count: 8 * 1_024 * 1_024).write(to: unrelatedFrame)
        let damaged = try writePacket("b-damaged-22222222", fingerprint: "target-evidence")
        try Data("corrupt matching image".utf8).write(to: damaged.deletingLastPathComponent().appendingPathComponent("frames/frame-o00000000.jpg"))
        let valid = try writePacket("c-valid-33333333", fingerprint: "target-evidence")
        var validations: [URL] = []
        let found = try matchingInspectionPacket(fingerprint: "target-evidence", under: analysis.appendingPathComponent("inspections")) { url, root in
            validations.append(url)
            let packet = try StableJSON.decode(InspectionPacket.self, from: url)
            for (relative, checksum) in try XCTUnwrap(packet.artifactFingerprints) {
                guard try FileSHA256.hexDigest(of: root.appendingPathComponent(relative)) == checksum else {
                    throw WatchthroughFailure(.operation, "corrupt packet fixture")
                }
            }
            return packet
        }
        XCTAssertEqual(validations.map { $0.deletingLastPathComponent().lastPathComponent },
            [damaged, valid].map { $0.deletingLastPathComponent().lastPathComponent },
            "unrelated image bytes must never reach full validation")
        XCTAssertEqual(found?.root.lastPathComponent, valid.deletingLastPathComponent().lastPathComponent)
        XCTAssertEqual(found?.packet.evidenceFingerprint, "target-evidence")
        XCTAssertEqual(try Data(contentsOf: unrelatedFrame).count, 8 * 1_024 * 1_024)
    }

    func testCacheLookupNeverReusesMatchingPacketAfterValidationFailure() throws {
        _ = try writePacket("range-1234abcd", fingerprint: "target-evidence")
        var validations = 0
        let found = try matchingInspectionPacket(fingerprint: "target-evidence", under: analysis.appendingPathComponent("inspections")) { _, _ in
            validations += 1
            throw WatchthroughFailure(.operation, "generation checksum mismatch")
        }
        XCTAssertEqual(validations, 1)
        XCTAssertNil(found)
    }

    private func status(verify: Bool) -> StatusResponse {
        WatchthroughApplication().status(StatusOptions(analysis: analysis, verify: verify))
    }

    private func relative(_ url: URL) -> String {
        String(url.path.dropFirst(analysis.path.count + 1))
    }

    private func writePacket(_ name: String, selector: String = "0..1", fingerprint: String = "fixture-evidence") throws -> URL {
        let packetRoot = analysis.appendingPathComponent("inspections/" + name)
        var cells: [PacketCell] = []
        for index in 0...1 {
            let frame = String(format: "frames/frame-o%08d.jpg", index)
            let file = packetRoot.appendingPathComponent(frame)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("frame \(index)".utf8).write(to: file)
            cells.append(PacketCell(index: index, ordinal: nil, ptsSeconds: Double(index),
                intervalStartSeconds: index == 0 ? 0 : 0.5, intervalEndSeconds: index == 0 ? 0.5 : Double(1).nextUp,
                timestamp: CLIParser.formatTime(Double(index)), caption: "", framePath: frame, ordinalBasis: "timestamp-only"))
        }
        try Data("sheet fixture".utf8).write(to: packetRoot.appendingPathComponent("strip-01.png"))
        try Data("# Inspection\n".utf8).write(to: packetRoot.appendingPathComponent("packet.md"))
        var packet = InspectionPacket(selector: selector, sourcePath: source.path, rangeStartSeconds: 0, rangeEndSeconds: Double(1).nextUp,
            sampling: "every 1s", cellsPerSheet: 2, largestGapSeconds: 1, timingPrecision: .none,
            cells: cells, sheets: ["strip-01.png"], contentFingerprint: "fixture-content",
            evidenceFingerprint: fingerprint, maximumFrameWidth: 320)
        packet.artifactFingerprints = try Dictionary(uniqueKeysWithValues:
            (cells.map(\.framePath) + packet.sheets + ["packet.md"]).map { ($0, try FileSHA256.hexDigest(of: packetRoot.appendingPathComponent($0))) })
        let url = packetRoot.appendingPathComponent("packet.json")
        try StableJSON.write(packet, to: url)
        return url
    }
}
