import Darwin
import Foundation
import XCTest
@testable import WatchthroughCore

final class PipelineTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var analysis: URL!

    override func setUpWithError() throws {
        guard let ffmpeg = Tooling.find("ffmpeg"), Tooling.find("ffprobe") != nil else { throw XCTSkip("media tools required") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.mkv")
        analysis = root.appendingPathComponent("analysis")
        _ = try ProcessRunner.run(ffmpeg.path, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-f", "lavfi", "-i", "testsrc2=size=128x72:rate=12:duration=2", "-threads", "1", "-c:v", "ffv1", source.path])
            .requireSuccess("fixture generation failed")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDefaultNoAudioPrepareIsMetadataOnlyAndWarmStatusNeedsNoTools() throws {
        let prepared = try runJSON(["prepare", source.path, "--out", analysis.path])
        XCTAssertEqual(prepared.details["next_transcript"], "Source has no audio. Continue visual inspection with details.next_inspect.")
        XCTAssertEqual(prepared.details["timing_precision"], "none")
        XCTAssertEqual(prepared.details["timing_precision_scope"], "transcript")
        let manifest = try readManifest()
        XCTAssertEqual(manifest.transcript.state, "no_audio")
        XCTAssertEqual(manifest.media.frameCount, 0)
        XCTAssertTrue(manifest.visual.frameIndexPath.isEmpty)
        XCTAssertTrue(manifest.visual.eventsPath.isEmpty)
        XCTAssertTrue(manifest.visual.overviewPacketPath.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: analysis.path), ["manifest.json"])
        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "", 1)
        defer { restorePath(oldPath) }
        XCTAssertEqual(try run(["prepare", source.path, "--out", analysis.path]), .success)
        let status = WatchthroughApplication().status(StatusOptions(analysis: analysis))
        XCTAssertEqual(status.exit, .success)
        XCTAssertNil(status.response.result.details["ffmpeg"])
        XCTAssertNil(status.response.result.details["elevenlabs_credential"])
        XCTAssertEqual(status.response.result.details["frame_index_state"], "deferred")
        XCTAssertEqual(status.response.result.details["timing_precision_scope"], "transcript")
    }

    func testDeferredTranscriptOnDemandAndCaptionInvalidationReusesVisualEvidence() throws {
        let sidecar = source.deletingPathExtension().appendingPathExtension("vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:02.000\nFirst caption.\n".utf8).write(to: sidecar)
        _ = try run(["prepare", source.path, "--out", analysis.path, "--defer-transcript"])
        XCTAssertEqual(try readManifest().transcript.state, "deferred")
        _ = try run(["inspect", analysis.path, "0..1", "--every", "500ms"])
        let first = try packets()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].timingPrecision, .none)
        _ = try run(["inspect", analysis.path, "transcript"])
        let manifest = try readManifest()
        XCTAssertEqual(manifest.transcript.state, "ready")
        XCTAssertGreaterThan(manifest.transcript.approximateTokens ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent(manifest.transcript.textPath!).path))
        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "", 1)
        defer { restorePath(oldPath) }
        _ = try run(["inspect", analysis.path, "0..1", "--every", "500ms"])
        let all = try packets()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.cells.contains { $0.caption.contains("First caption") } })
        XCTAssertEqual(Set(all.compactMap(\.evidenceFingerprint)).count, 1)
        XCTAssertEqual(Set(all.compactMap(\.contentFingerprint)).count, 2)
        XCTAssertTrue(try readManifest().visual.frameIndexPath.isEmpty)
    }

    func testMissingDurationDecodeWarningSurvivesTranscriptPreparationAndRefresh() throws {
        let ffmpeg = try XCTUnwrap(Tooling.find("ffmpeg"))
        source = root.appendingPathComponent("live-muxed.mkv")
        _ = try ProcessRunner.run(ffmpeg.path, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-f", "lavfi", "-i", "testsrc2=size=128x72:rate=12:duration=2", "-threads", "1", "-c:v", "libx264",
            "-preset", "ultrafast", "-live", "1", source.path]).requireSuccess("fixture generation failed")
        let prepared = try runJSON(["prepare", source.path, "--out", analysis.path])
        let warning = try XCTUnwrap(prepared.warnings.first { $0.contains("duration metadata was unavailable") })
        XCTAssertTrue(warning.contains("decoded the source once"))
        XCTAssertTrue(warning.contains("global frame index remains on demand"))
        XCTAssertEqual(try readManifest().transcript.state, "no_audio")
        XCTAssertEqual(try readManifest().media.frameCount, 24)
        XCTAssertTrue(try readManifest().visual.frameIndexPath.isEmpty)
        let sidecar = source.deletingPathExtension().appendingPathExtension("vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:02.000\nVisual caption.\n".utf8).write(to: sidecar)
        let refreshed = try runJSON(["prepare", source.path, "--out", analysis.path, "--refresh"])
        XCTAssertTrue(refreshed.warnings.contains(warning))
        XCTAssertEqual(try readManifest().transcript.state, "ready")
        XCTAssertTrue(try readManifest().visual.frameIndexPath.isEmpty)
        XCTAssertTrue(WatchthroughApplication().status(StatusOptions(analysis: analysis)).response.result.warnings.contains(warning))
    }

    func testLayoutReflowUsesExistingImagesWithoutMediaTools() throws {
        _ = try run(["prepare", source.path, "--out", analysis.path, "--transcriber", "none"])
        _ = try run(["inspect", analysis.path, "0..1", "--every", "250ms"])
        let first = try packets()[0]
        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "", 1)
        defer { restorePath(oldPath) }
        _ = try run(["inspect", analysis.path, "0..1", "--every", "250ms", "--cells", "3", "--sheet-format", "png"])
        let all = try packets()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.compactMap(\.evidenceFingerprint)).count, 1)
        XCTAssertTrue(all.contains { $0.sheets.allSatisfy { $0.hasSuffix(".png") } })
        XCTAssertTrue(all.allSatisfy { $0.cells.map(\.ptsSeconds) == first.cells.map(\.ptsSeconds) })
    }

    func testTranscriptFailureKeepsPreparedMetadataAndCanResumeSameAnalysis() throws {
        XCTAssertThrowsError(try run(["prepare", source.path, "--out", analysis.path, "--transcriber", "sidecar"]))
        XCTAssertEqual(try readManifest().transcript.state, "failed")
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis)).exit, .success)
        let sidecar = source.deletingPathExtension().appendingPathExtension("vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:02.000\nRecovered transcript.\n".utf8).write(to: sidecar)
        _ = try run(["inspect", analysis.path, "transcript"])
        XCTAssertEqual(try readManifest().transcript.state, "ready")
    }

    func testFrameOrdinalIsOnlyPresentAfterExplicitFullIndexRequest() throws {
        _ = try run(["prepare", source.path, "--out", analysis.path, "--transcriber", "none"])
        _ = try run(["inspect", analysis.path, "0..0.5", "--every", "2f"])
        let local = try packets()[0]
        XCTAssertTrue(local.cells.allSatisfy { $0.ordinal == nil && $0.ordinalBasis == "decoded-local-range" })
        XCTAssertEqual(local.cells.compactMap(\.localOrdinal), [0, 2, 4, 6])
        XCTAssertTrue(try readManifest().visual.frameIndexPath.isEmpty)
        _ = try run(["inspect", analysis.path, "frame:4"])
        XCTAssertFalse(try readManifest().visual.frameIndexPath.isEmpty)
        XCTAssertTrue(try packets().contains { $0.cells.count == 1 && $0.cells[0].ordinal == 4 })
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis, verify: true)).exit, .success)
    }

    func testOverviewIsLazyBoundedAndIncludesTrueEndpoints() throws {
        _ = try run(["prepare", source.path, "--out", analysis.path, "--transcriber", "none"])
        let inspected = try runJSON(["inspect", analysis.path, "overview"])
        XCTAssertEqual(inspected.details["timing_precision"], "none")
        XCTAssertEqual(inspected.details["timing_precision_scope"], "transcript")
        let manifest = try readManifest()
        let packet = try StableJSON.decode(InspectionPacket.self, from: analysis.appendingPathComponent(manifest.visual.overviewPacketPath))
        XCTAssertLessThanOrEqual(packet.cells.count, 12)
        XCTAssertEqual(packet.cells.first!.ptsSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(packet.cells.last!.ptsSeconds, 23.0 / 12, accuracy: 0.001)
        XCTAssertEqual(packet.maximumFrameWidth, 720)
        XCTAssertTrue(manifest.visual.frameIndexPath.isEmpty)
        XCTAssertTrue(manifest.visual.eventsPath.isEmpty)
        XCTAssertTrue(packet.cells.allSatisfy { $0.ordinal == nil })
    }

    func testChangedSidecarRequiresRefreshAndOldArtifactsRemain() throws {
        let sidecar = source.deletingPathExtension().appendingPathExtension("vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:02.000\nBefore.\n".utf8).write(to: sidecar)
        _ = try run(["prepare", source.path, "--out", analysis.path])
        let previous = try XCTUnwrap(readManifest().transcript.path)
        try Data("WEBVTT\n\n00:00.000 --> 00:02.000\nAfter.\n".utf8).write(to: sidecar)
        XCTAssertThrowsError(try run(["prepare", source.path, "--out", analysis.path]))
        _ = try run(["prepare", source.path, "--out", analysis.path, "--refresh"])
        XCTAssertNotEqual(try readManifest().transcript.path!, previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent(previous).path))
    }

    func testCleanTranscriptSameSizeCorruptionIsRejectedWhenRequestedOrVerified() throws {
        let sidecar = source.deletingPathExtension().appendingPathExtension("vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:02.000\nFirst caption.\n".utf8).write(to: sidecar)
        _ = try run(["prepare", source.path, "--out", analysis.path])
        let manifest = try readManifest()
        let clean = analysis.appendingPathComponent(try XCTUnwrap(manifest.transcript.textPath))
        let original = try String(contentsOf: clean, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "First", with: "Wrong")
        XCTAssertEqual(original.utf8.count, changed.utf8.count)
        try Data(changed.utf8).write(to: clean)
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis)).exit, .success)
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis, verify: true)).exit, .operation)
        XCTAssertThrowsError(try run(["inspect", analysis.path, "transcript"]))
    }

    func testDelayedAudioDoesNotShiftMediaTimedSidecarAgain() throws {
        let ffmpeg = try XCTUnwrap(Tooling.find("ffmpeg"))
        source = root.appendingPathComponent("delayed.mkv")
        _ = try ProcessRunner.run(ffmpeg.path, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-f", "lavfi", "-i", "testsrc2=size=128x72:rate=12:duration=2", "-itsoffset", "0.5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1.5", "-threads", "1", "-c:v", "ffv1", "-c:a", "pcm_s16le", source.path])
            .requireSuccess("delayed audio fixture generation failed")
        let sidecar = source.deletingPathExtension().appendingPathExtension("vtt")
        try Data("WEBVTT\n\n00:00.500 --> 00:00.600\nCorrect cue.\n".utf8).write(to: sidecar)
        _ = try run(["prepare", source.path, "--out", analysis.path])
        let manifest = try readManifest()
        XCTAssertEqual(try XCTUnwrap(manifest.media.audioStartPTS), 0.5, accuracy: 0.001)
        XCTAssertEqual(manifest.transcript.timelineOrigin, "container-start")
        _ = try run(["inspect", analysis.path, "0..1", "--every", "250ms"])
        let captioned = try packets()[0].cells.filter { $0.caption.contains("Correct cue") }
        XCTAssertEqual(captioned.count, 1)
        XCTAssertEqual(try XCTUnwrap(captioned.first).ptsSeconds, 0.5, accuracy: 0.001)
    }

    func testSameSizeCachedImageCorruptionIsRejectedAndReflowRegeneratesSafely() throws {
        _ = try run(["prepare", source.path, "--out", analysis.path, "--transcriber", "none"])
        _ = try run(["inspect", analysis.path, "overview"])
        let before = try readManifest()
        let packetURL = analysis.appendingPathComponent(before.visual.overviewPacketPath)
        let packet = try StableJSON.decode(InspectionPacket.self, from: packetURL)
        let first = try XCTUnwrap(packet.cells.first)
        let imageURL = packetURL.deletingLastPathComponent().appendingPathComponent(first.framePath)
        let original = try Data(contentsOf: imageURL)
        var corrupted = original
        corrupted[corrupted.count / 2] ^= 1
        XCTAssertEqual(corrupted.count, original.count)
        try corrupted.write(to: imageURL)
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis)).exit, .success)
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis, verify: true)).exit, .operation)
        XCTAssertThrowsError(try run(["inspect", analysis.path, "overview"])) { error in
            XCTAssertTrue((error as? WatchthroughFailure)?.message.contains("checksum mismatch") == true)
        }
        _ = try run(["inspect", analysis.path, "overview", "--cells", "3"])
        let after = try readManifest()
        XCTAssertNotEqual(after.visual.overviewPacketPath, before.visual.overviewPacketPath)
        let replacementURL = analysis.appendingPathComponent(after.visual.overviewPacketPath)
        let replacement = try StableJSON.decode(InspectionPacket.self, from: replacementURL)
        let replacementImage = replacementURL.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(replacement.cells.first).framePath)
        XCTAssertEqual(try Data(contentsOf: replacementImage), original)
        XCTAssertEqual(try Data(contentsOf: imageURL), corrupted, "regeneration must not overwrite existing user-owned cache files")
        XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis, verify: true)).exit, .success)
    }

    func testCachedPacketStructureRejectsChangedLabelsDespiteUnchangedImageChecksums() throws {
        _ = try run(["prepare", source.path, "--out", analysis.path, "--transcriber", "none"])
        _ = try run(["inspect", analysis.path, "overview"])
        let manifest = try readManifest()
        let packetURL = analysis.appendingPathComponent(manifest.visual.overviewPacketPath)
        let originalData = try Data(contentsOf: packetURL)
        let original = try StableJSON.decode(InspectionPacket.self, from: originalData)
        let mutations: [(String, (inout InspectionPacket) -> Void)] = [
            ("PTS outside interval", { $0.cells[0].ptsSeconds = $0.rangeEndSeconds + 1 }),
            ("nonsequential index", { $0.cells[0].index = 99 }),
            ("duplicate frame path", { $0.cells[1].framePath = $0.cells[0].framePath }),
            ("false global ordinal basis", { $0.cells[0].ordinalBasis = "decoded-global" }),
            ("wrong largest gap", { $0.largestGapSeconds += 1 }),
            ("missing sheet", { $0.sheets = [] }),
            ("wrong caption interval", { $0.cells[1].intervalStartSeconds += 0.01 }),
            ("wrong displayed timestamp", { $0.cells[0].timestamp = "00:01.000" }),
        ]
        for (label, mutate) in mutations {
            var changed = original
            mutate(&changed)
            XCTAssertEqual(changed.artifactFingerprints, original.artifactFingerprints)
            try StableJSON.write(changed, to: packetURL)
            XCTAssertThrowsError(try run(["inspect", analysis.path, "overview"]), label) { error in
                XCTAssertTrue((error as? WatchthroughFailure)?.message.contains("packet structure is invalid") == true, label)
            }
            XCTAssertEqual(WatchthroughApplication().status(StatusOptions(analysis: analysis, verify: true)).exit, .operation, label)
            try originalData.write(to: packetURL, options: .atomic)
        }
        // Reflow must not copy images with altered receipt labels into a fresh packet.
        var changed = original
        changed.cells[0].index = 99
        try StableJSON.write(changed, to: packetURL)
        _ = try run(["inspect", analysis.path, "overview", "--cells", "3"])
        let replacement = try readManifest()
        XCTAssertNotEqual(replacement.visual.overviewPacketPath, manifest.visual.overviewPacketPath)
        let recovered = try StableJSON.decode(InspectionPacket.self, from: analysis.appendingPathComponent(replacement.visual.overviewPacketPath))
        XCTAssertEqual(recovered.cells.map(\.index), Array(recovered.cells.indices))
        XCTAssertEqual(recovered.cells.map(\.ptsSeconds), original.cells.map(\.ptsSeconds))
        _ = try run(["inspect", analysis.path, "frame:4"])
        let packetRoots = try FileManager.default.contentsOfDirectory(at: analysis.appendingPathComponent("inspections"), includingPropertiesForKeys: nil)
        for root in packetRoots where !root.lastPathComponent.hasPrefix(".") {
            let url = root.appendingPathComponent("packet.json")
            var packet = try StableJSON.decode(InspectionPacket.self, from: url)
            guard packet.selector == "frame:4" else { continue }
            packet.cells[0].ordinal = 5
            try StableJSON.write(packet, to: url)
            XCTAssertThrowsError(try run(["inspect", analysis.path, "frame:4"])) { error in
                XCTAssertTrue((error as? WatchthroughFailure)?.message.contains("global ordinal disagrees with frame selector") == true)
            }
        }
    }

    private func run(_ args: [String]) throws -> WatchthroughExit { try WatchthroughApplication().run(arguments: ["--json"] + args) }
    private func runJSON(_ args: [String]) throws -> CommandResult {
        let output = root.appendingPathComponent("result-\(UUID().uuidString).json")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw XCTSkip("stdout capture unavailable") }
        defer { fflush(stdout); _ = dup2(saved, STDOUT_FILENO); close(saved) }
        XCTAssertGreaterThanOrEqual(dup2(handle.fileDescriptor, STDOUT_FILENO), 0)
        XCTAssertEqual(try run(args), .success)
        fflush(stdout)
        return try StableJSON.decode(CommandResult.self, from: output)
    }
    private func readManifest() throws -> PreparationManifest { try XCTUnwrap(ManifestStore.read(from: analysis.appendingPathComponent("manifest.json"))) }
    private func packets() throws -> [InspectionPacket] {
        let directory = analysis.appendingPathComponent("inspections")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { try StableJSON.decode(InspectionPacket.self, from: $0.appendingPathComponent("packet.json")) }
    }
    private func restorePath(_ previous: String?) { if let previous { setenv("PATH", previous, 1) } else { unsetenv("PATH") } }
}
