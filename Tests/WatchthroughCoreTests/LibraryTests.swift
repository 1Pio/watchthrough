import Foundation
import XCTest
@testable import WatchthroughCore

final class LibraryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var analysis: URL!
    private var library: URL!
    private var source: URL!
    private var note: URL!
    private let summary = "# Source study\n\nThe full transcript describes a red square moving right. At 00:01 I inspected the red square. Other frames were not inspected.\n"

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-library-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        analysis = temporaryDirectory.appendingPathComponent("source.watchthrough", isDirectory: true)
        library = temporaryDirectory.appendingPathComponent("library", isDirectory: true)
        source = temporaryDirectory.appendingPathComponent("source.mp4")
        note = temporaryDirectory.appendingPathComponent("study.md")
        try Data("source video fixture".utf8).write(to: source)
        try Data(summary.utf8).write(to: note)
        try writeAnalysis()
    }

    // Fixtures deliberately remain in the system temporary directory. Neither
    // tests nor production cleanup permanently delete evidence directories.

    func testRetainPreservesSummaryFullTranscriptSelectedVisualAndDossierInImmutableSnapshots() throws {
        let packetPath = try writePacket()
        let selected = String(packetPath.dropLast("packet.json".count)) + "frames/frame-o00000001.jpg"
        let dossier = temporaryDirectory.appendingPathComponent("description.json")
        try Data(#"{"url":"https://example.org/video","description":"creator supplied context"}"#.utf8).write(to: dossier)
        let first = try DurableLibrary.retain(analysis: analysis, note: note, library: library,
                                              includes: [selected], dossiers: [dossier])
        let snapshot = URL(fileURLWithPath: try XCTUnwrap(first.artifacts["snapshot"]))
        XCTAssertEqual(first.artifacts["transcript_text"], snapshot.appendingPathComponent("transcript/transcript.txt").path)
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("summary.md"), encoding: .utf8), summary)
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("transcript/transcript.txt")),
                       try Data(contentsOf: analysis.appendingPathComponent("transcript/transcript.txt")))
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("evidence/" + selected)), Data("frame 1".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("evidence/" + packetPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("dossiers/01-description.json").path))
        let receipt = try String(contentsOf: snapshot.appendingPathComponent("receipt.json"), encoding: .utf8)
        XCTAssertTrue(receipt.contains("caller-supplied source context"))
        XCTAssertTrue(receipt.contains(dossier.path))

        try Data((summary + "\nLater inspection adds context.\n").utf8).write(to: note)
        let second = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        XCTAssertNotEqual(first.artifacts["snapshot"], second.artifacts["snapshot"])
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("summary.md"), encoding: .utf8), summary)
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(second.artifacts["index"])))) as? [String: Any]
        XCTAssertEqual((index?["snapshots"] as? [[String: Any]])?.count, 2)
    }

    func testCleanupIsDryRunByDefaultAndOnlyAppliesTrashToAnalysisAfterVerification() throws {
        let retained = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        var trashCalls = 0
        let destination = temporaryDirectory.appendingPathComponent("simulated-system-trash", isDirectory: true)
        let moveToTrash: (URL) throws -> URL? = { candidate in
            trashCalls += 1
            XCTAssertEqual(candidate, self.analysis)
            try FileManager.default.moveItem(at: candidate, to: destination)
            return destination
        }
        let preview = try DurableLibrary.cleanup(analysis: analysis, library: library, trash: moveToTrash)
        XCTAssertEqual(preview.details["mode"], "dry-run")
        XCTAssertEqual(trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.path))
        let applied = try DurableLibrary.cleanup(analysis: analysis, library: library, apply: true, trash: moveToTrash)
        XCTAssertEqual(applied.details["mode"], "trashed")
        XCTAssertEqual(trashCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source video fixture")
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(applied.artifacts["transcript_text"]), encoding: .utf8),
                       "[untimed]\nThe red square moves to the right.\n")
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(retained.artifacts["summary"]), encoding: .utf8), summary)
    }

    func testCleanupRejectsDamagedRetainedTranscript() throws {
        let result = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        let snapshot = URL(fileURLWithPath: try XCTUnwrap(result.artifacts["snapshot"]))
        try Data("corrupted retained transcript".utf8).write(to: snapshot.appendingPathComponent("transcript/transcript.txt"))
        try assertCleanupRefused()
    }

    func testRetentionCannotBlessEditedTranscriptAndRequiresCoherentPreparationRefresh() throws {
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        try write(Data("An updated full transcript.\n".utf8), relative: "transcript/transcript.txt")
        try assertCleanupRefused()
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        // Model a successful preparation refresh: canonical JSON, its readable
        // projection, and the manifest generation fingerprints change together.
        try writeAnalysis(transcriptText: "An updated full transcript.")
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        XCTAssertEqual(try DurableLibrary.cleanup(analysis: analysis, library: library).details["mode"], "dry-run")
    }

    func testRetentionRejectsCanonicalJSONWithStaleGenerationFingerprint() throws {
        let path = analysis.appendingPathComponent("transcript/transcript.json")
        var transcript = try StableJSON.decode(CanonicalTranscript.self, from: path)
        transcript.text = "Altered generated canonical content."
        try TranscriptFiles.writeCanonical(transcript, to: path)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
    }

    func testRetentionRejectsCanonicalTextMismatchEvenWithMatchingIndependentFingerprints() throws {
        let path = analysis.appendingPathComponent("transcript/transcript.txt")
        try Data("[untimed]\nDifferent words absent from the canonical JSON.\n".utf8).write(to: path)
        var manifest = try XCTUnwrap(ManifestStore.read(from: analysis.appendingPathComponent("manifest.json")))
        manifest.transcript.textFingerprint = "transcript-text:\(try FileSHA256.hexDigest(of: path))"
        manifest.transcript.textBytes = try Data(contentsOf: path).count
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
    }

    func testLegacyTranscriptWithoutFingerprintsStillRequiresCanonicalReadableTextAgreement() throws {
        try writeAnalysis(fingerprinted: false)
        XCTAssertNoThrow(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        try write(Data("Changed legacy text without changing canonical JSON.\n".utf8), relative: "transcript/transcript.txt")
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        try assertCleanupRefused()
    }

    func testImmutableTranscriptRunPathsValidateAfterNormalizationIntoSnapshot() throws {
        let run = "transcript/run-00000000-1111-2222-3333-444444444444"
        try FileManager.default.createDirectory(at: analysis.appendingPathComponent(run), withIntermediateDirectories: true)
        for name in ["transcript.json", "transcript.txt"] {
            try FileManager.default.moveItem(at: analysis.appendingPathComponent("transcript/" + name),
                                             to: analysis.appendingPathComponent(run + "/" + name))
        }
        var manifest = try XCTUnwrap(ManifestStore.read(from: analysis.appendingPathComponent("manifest.json")))
        manifest.transcript.path = run + "/transcript.json"
        manifest.transcript.textPath = run + "/transcript.txt"
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
        XCTAssertNoThrow(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        XCTAssertNoThrow(try DurableLibrary.cleanup(analysis: analysis, library: library))
    }

    func testCleanupRejectsSourceChangeEvenWhenByteCountIsUnchanged() throws {
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        try Data("SOURCE video fixture".utf8).write(to: source)
        try assertCleanupRefused()
    }

    func testCleanupRefusesForeignFileEvenIfPresentWhenRetained() throws {
        try write(Data("Important user notes must stay safe.".utf8), relative: "personal-notes.md")
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        try assertCleanupRefused()
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("personal-notes.md").path))
    }

    func testRetentionRejectsTraversalAndSymlinkIncludesWithoutReadingExternalEvidence() throws {
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: ["../study.md"]))
        let link = analysis.appendingPathComponent("visual-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: note)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: ["visual-link"]))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), summary)
    }

    func testCleanupRejectsSymlinkAddedAfterRetentionAndKeepsTarget() throws {
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        try FileManager.default.createDirectory(at: analysis.appendingPathComponent("visual"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: analysis.appendingPathComponent("visual/linked-notes"), withDestinationURL: note)
        try assertCleanupRefused()
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), summary)
    }

    func testRetentionAndCleanupRejectSourceInsideAnalysis() throws {
        let inside = analysis.appendingPathComponent("source.mp4")
        try FileManager.default.copyItem(at: source, to: inside)
        var manifest = try XCTUnwrap(ManifestStore.read(from: analysis.appendingPathComponent("manifest.json")))
        manifest.source.path = inside.path
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        try assertCleanupRefused()
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testCleanupExcludesActiveInspectionReadersAndRetentionExcludesPreparationWriter() throws {
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        let lockURL = analysis.deletingLastPathComponent().appendingPathComponent(".\(analysis.lastPathComponent).lock")
        let reader = try ExclusiveFileLock.acquireShared(at: lockURL)
        try assertCleanupRefused()
        // Retention is another shared reader and is permitted when its inventory
        // stays unchanged throughout publication.
        XCTAssertNoThrow(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        reader.unlock()
        let writer = try ExclusiveFileLock.acquire(at: lockURL)
        defer { writer.unlock() }
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
    }

    func testCleanupCanUseIntactEarlierSnapshotIfNewerSnapshotWasDamaged() throws {
        let first = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        let second = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        try Data("bad".utf8).write(to: URL(fileURLWithPath: try XCTUnwrap(second.artifacts["summary"])))
        let cleanup = try DurableLibrary.cleanup(analysis: analysis, library: library)
        XCTAssertEqual(cleanup.artifacts["retained_snapshot"], first.artifacts["snapshot"])
    }

    func testVisualOnlyDeferredAnalysisCanBeRetainedAndCleanedUp() throws {
        let existing = analysis.appendingPathComponent("transcript")
        try FileManager.default.moveItem(at: existing, to: temporaryDirectory.appendingPathComponent("unused-transcript-fixture"))
        try writeAnalysis(transcriptAvailable: false)
        let result = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        let snapshot = URL(fileURLWithPath: try XCTUnwrap(result.artifacts["snapshot"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("transcript").path))
        XCTAssertNoThrow(try DurableLibrary.cleanup(analysis: analysis, library: library))
    }

    func testRetentionRejectsEmptySummaryAndLibraryInsideAnalysis() throws {
        try Data("  \n".utf8).write(to: note)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        try Data(summary.utf8).write(to: note)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note,
                                                       library: analysis.appendingPathComponent("library")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("library").path))
    }

    func testCleanupWithoutRetentionNeverCallsTrash() throws {
        try assertCleanupRefused()
    }

    func testCleanupDoesNotReportSuccessWhenTrashDidNotMoveTheDirectory() throws {
        _ = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        var calls = 0
        XCTAssertThrowsError(try DurableLibrary.cleanup(analysis: analysis, library: library, apply: true, trash: { _ in
            calls += 1
            return nil
        }))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.path))
    }

    func testSymlinkAnalysisAndLibraryRootsAreRejected() throws {
        let linkedAnalysis = temporaryDirectory.appendingPathComponent("linked-analysis")
        try FileManager.default.createSymbolicLink(at: linkedAnalysis, withDestinationURL: analysis)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: linkedAnalysis, note: note, library: library))
        let libraryTarget = temporaryDirectory.appendingPathComponent("library-target", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: libraryTarget)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
    }

    func testRetainingPacketAutomaticallyPreservesRelativeVisualDependenciesAfterCleanup() throws {
        let packetPath = try writePacket()
        let prefix = String(packetPath.dropLast("packet.json".count))
        let dossier = temporaryDirectory.appendingPathComponent("source.description")
        let description = "Creator description from https://example.org/video, retrieved for this source study."
        try Data(description.utf8).write(to: dossier)
        let linkedSummary = summary + "\n[Inspected packet](evidence/\(prefix)packet.md)\n"
            + "[Full transcript](transcript/transcript.txt)\n[Creator description](dossiers/01-source.description)\n"
        try Data(linkedSummary.utf8).write(to: note)
        let retained = try DurableLibrary.retain(analysis: analysis, note: note, library: library,
                                                 includes: [packetPath], dossiers: [dossier])
        let snapshot = URL(fileURLWithPath: try XCTUnwrap(retained.artifacts["snapshot"]))
        let trashed = temporaryDirectory.appendingPathComponent("packet-analysis-in-trash")
        _ = try DurableLibrary.cleanup(analysis: analysis, library: library, apply: true, trash: { candidate in
            try FileManager.default.moveItem(at: candidate, to: trashed)
            return trashed
        })
        let packetRoot = snapshot.appendingPathComponent("evidence/" + prefix)
        let packet = try StableJSON.decode(InspectionPacket.self, from: packetRoot.appendingPathComponent("packet.json"))
        for cell in packet.cells {
            XCTAssertEqual(try String(contentsOf: packetRoot.appendingPathComponent(cell.framePath), encoding: .utf8), "frame \(cell.index)")
        }
        for sheet in packet.sheets {
            XCTAssertEqual(try String(contentsOf: packetRoot.appendingPathComponent(sheet), encoding: .utf8), "strip fixture")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: packetRoot.appendingPathComponent("packet.md").path))
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("dossiers/01-source.description"), encoding: .utf8), description)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), linkedSummary)
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("summary.md"), encoding: .utf8), linkedSummary)
    }

    func testPacketIncludeRejectsEscapingReferencesAndDoesNotReadExternalFile() throws {
        let packetPath = try writePacket()
        let packetURL = analysis.appendingPathComponent(packetPath)
        var packet = try StableJSON.decode(InspectionPacket.self, from: packetURL)
        packet.cells[0].framePath = "../../../study.md"
        try StableJSON.write(packet, to: packetURL)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath]))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), summary)
    }

    func testPacketIncludeRejectsSymlinkedVisualDependency() throws {
        let packetPath = try writePacket()
        let frame = analysis.appendingPathComponent(String(packetPath.dropLast("packet.json".count)) + "frames/frame-o00000000.jpg")
        try FileManager.default.moveItem(at: frame, to: temporaryDirectory.appendingPathComponent("original-frame"))
        try FileManager.default.createSymbolicLink(at: frame, withDestinationURL: note)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath]))
    }

    func testPacketIncludeRejectsVisualBytesThatDisagreeWithGenerationChecksum() throws {
        let packetPath = try writePacket()
        let frame = String(packetPath.dropLast("packet.json".count)) + "frames/frame-o00000000.jpg"
        try write(Data("tampered generated image".utf8), relative: frame)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath]))
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [frame]))
    }

    func testPacketIncludeRejectsCorruptTimestampMetadataDespiteIntactImages() throws {
        let packetPath = try writePacket()
        let packetURL = analysis.appendingPathComponent(packetPath)
        var packet = try StableJSON.decode(InspectionPacket.self, from: packetURL)
        packet.cells[0].ptsSeconds = 0.75
        try StableJSON.write(packet, to: packetURL)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath]))
    }

    func testCleanupRechecksGenerationReceiptForOldSingleImageSnapshot() throws {
        let packetPath = try writePacket()
        let relative = String(packetPath.dropLast("packet.json".count)) + "frames/frame-o00000000.jpg"
        let retained = try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [relative])
        let snapshot = URL(fileURLWithPath: try XCTUnwrap(retained.artifacts["snapshot"]))
        let altered = Data("altered frame admitted by an older library version".utf8)
        try write(altered, relative: relative)
        try altered.write(to: snapshot.appendingPathComponent("evidence/" + relative))
        let digest = try FileSHA256.hexDigest(of: analysis.appendingPathComponent(relative))
        let receiptURL = snapshot.appendingPathComponent("receipt.json")
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        for (key, path) in [("files", "evidence/" + relative), ("analysisInventory", relative)] {
            var entries = try XCTUnwrap(receipt[key] as? [[String: Any]])
            let index = try XCTUnwrap(entries.firstIndex(where: { $0["path"] as? String == path }))
            entries[index]["sha256"] = digest
            entries[index]["sizeBytes"] = altered.count
            receipt[key] = entries
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
        try assertCleanupRefused()
    }

    func testPacketV2RequiresGenerationChecksumsWhileLegacyV1RemainsReadable() throws {
        let packetPath = try writePacket()
        let packetURL = analysis.appendingPathComponent(packetPath)
        var packet = try StableJSON.decode(InspectionPacket.self, from: packetURL)
        packet.artifactFingerprints = nil
        try StableJSON.write(packet, to: packetURL)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath]))
        packet.schema = "watchthrough.packet.v1"
        try StableJSON.write(packet, to: packetURL)
        XCTAssertNoThrow(try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath]))
    }

    func testCleanupRejectsLegacyPacketReceiptWhoseDependenciesWereNeverRetained() throws {
        let packetPath = try writePacket()
        let retained = try DurableLibrary.retain(analysis: analysis, note: note, library: library, includes: [packetPath])
        let snapshot = URL(fileURLWithPath: try XCTUnwrap(retained.artifacts["snapshot"]))
        let framePath = "evidence/" + String(packetPath.dropLast("packet.json".count)) + "frames/frame-o00000000.jpg"
        try FileManager.default.moveItem(at: snapshot.appendingPathComponent(framePath),
                                         to: temporaryDirectory.appendingPathComponent("frame-not-in-legacy-archive"))
        let receiptURL = snapshot.appendingPathComponent("receipt.json")
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        receipt["files"] = try XCTUnwrap(receipt["files"] as? [[String: Any]]).filter { $0["path"] as? String != framePath }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
        try assertCleanupRefused()
    }

    func testSummaryMissingDurableLinkIsRejectedBeforeSnapshotPublication() throws {
        try Data((summary + "\n[Missing inspected image](evidence/visual/overview/frames/frame-o00000999.jpg)\n").utf8).write(to: note)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        let sourceHash = try FileSHA256.hexDigest(of: source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent(sourceHash + "/snapshots").path), [])
    }

    func testSummaryAbsoluteAnalysisLinkIsRejectedAndSourceNoteIsUnchanged() throws {
        let authored = summary + "\n[Ephemeral transcript](<\(analysis.appendingPathComponent("transcript/transcript.txt").path)>)\n"
        try Data(authored.utf8).write(to: note)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), authored)
    }

    func testSummaryPreservedSourceLinkWarnsAndCodeExamplesAreNotTreatedAsLinks() throws {
        let authored = summary + "\n[Original source](<\(source.path)>)\n"
            + "Example: `[not a real link](evidence/not-selected.jpg)`.\n"
            + "```markdown\n[also an example](dossiers/not-selected.json)\n```\n"
            + "[Canonical transcript](./transcript/transcript.txt#speech)\n"
        try Data(authored.utf8).write(to: note)
        let result = try DurableLibrary.retain(analysis: analysis, note: note, library: library)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("absolute local links") }))
        XCTAssertNoThrow(try DurableLibrary.cleanup(analysis: analysis, library: library))
    }

    func testDescriptionDossierRejectsBinaryContent() throws {
        let dossier = temporaryDirectory.appendingPathComponent("source.description")
        try Data([0xff, 0xfe, 0xff]).write(to: dossier)
        XCTAssertThrowsError(try DurableLibrary.retain(analysis: analysis, note: note, library: library, dossiers: [dossier]))
    }

    @discardableResult
    private func writePacket() throws -> String {
        let prefix = "inspections/range-1234abcd/"
        var cells: [PacketCell] = []
        for index in 0...1 {
            let frame = String(format: "frames/frame-o%08d.jpg", index)
            try write(Data("frame \(index)".utf8), relative: prefix + frame)
            cells.append(PacketCell(index: index, ordinal: nil, ptsSeconds: Double(index), intervalStartSeconds: index == 0 ? 0 : 0.5,
                                    intervalEndSeconds: index == 0 ? 0.5 : Double(1).nextUp, timestamp: CLIParser.formatTime(Double(index)),
                                    caption: "Observed state \(index)", framePath: frame, ordinalBasis: "timestamp-only"))
        }
        try write(Data("strip fixture".utf8), relative: prefix + "strip-01.png")
        try write(Data("# Inspected range\n\n![Sheet](strip-01.png)\n[Frame](frames/frame-o00000000.jpg)\n".utf8), relative: prefix + "packet.md")
        var packet = InspectionPacket(selector: "00:00..00:01", sourcePath: source.path, rangeStartSeconds: 0, rangeEndSeconds: Double(1).nextUp,
                                      sampling: "every 1s", cellsPerSheet: 2, largestGapSeconds: 1, timingPrecision: .none,
                                      cells: cells, sheets: ["strip-01.png"], contentFingerprint: "fixture-content",
                                      evidenceFingerprint: "fixture-evidence", maximumFrameWidth: 320)
        packet.artifactFingerprints = try Dictionary(uniqueKeysWithValues:
            (cells.map(\.framePath) + packet.sheets + ["packet.md"]).map {
                ($0, try FileSHA256.hexDigest(of: analysis.appendingPathComponent(prefix + $0)))
            })
        try StableJSON.write(packet, to: analysis.appendingPathComponent(prefix + "packet.json"))
        return prefix + "packet.json"
    }

    private func assertCleanupRefused(file: StaticString = #filePath, line: UInt = #line) throws {
        var calls = 0
        XCTAssertThrowsError(try DurableLibrary.cleanup(analysis: analysis, library: library, apply: true, trash: { _ in
            calls += 1
            return nil
        }), file: file, line: line)
        XCTAssertEqual(calls, 0, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.path), file: file, line: line)
    }

    private func writeAnalysis(transcriptAvailable: Bool = true, transcriptText: String = "The red square moves to the right.",
                               fingerprinted: Bool = true) throws {
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        var transcriptSummary = TranscriptSummary(available: false)
        if transcriptAvailable {
            let transcript = CanonicalTranscript(provider: "fixture", timingPrecision: .none,
                                                  text: transcriptText)
            try StableJSON.write(transcript, to: analysis.appendingPathComponent("transcript/transcript.json"))
            try TranscriptFiles.writeText(transcript, to: analysis.appendingPathComponent("transcript/transcript.txt"))
            transcriptSummary = TranscriptSummary(available: true, provider: "fixture", timingPrecision: .none,
                                                   path: "transcript/transcript.json", textPath: "transcript/transcript.txt",
                                                   fingerprint: fingerprinted ? "transcript:\(try FileSHA256.hexDigest(of: analysis.appendingPathComponent("transcript/transcript.json")))" : nil,
                                                   textBytes: TranscriptFiles.textData(transcript).count,
                                                   textFingerprint: fingerprinted ? "transcript-text:\(try FileSHA256.hexDigest(of: analysis.appendingPathComponent("transcript/transcript.txt")))" : nil)
        }
        let manifest = PreparationManifest(createdAt: "2026-09-06T00:00:00Z", completedAt: "2026-09-06T00:00:01Z",
            source: SourceRecord(path: source.path, sha256: try FileSHA256.hexDigest(of: source),
                                 sizeBytes: Int64(try Data(contentsOf: source).count), modifiedAt: "2026-09-06T00:00:00Z"),
            media: MediaInfo(durationSeconds: 2, width: 320, height: 180, hasAudio: true, frameCount: 0, firstPTS: 0, lastPTS: 2),
            config: PreparationConfig(transcriber: transcriptAvailable ? "sidecar" : "none"),
            transcript: transcriptSummary,
            visual: VisualSummary(frameIndexPath: "", overviewPacketPath: "", eventsPath: "", overviewFrames: 0,
                                  largestOverviewGapSeconds: 0, eventCount: 0, scanFPS: 0), tools: [:], warnings: [])
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
    }

    private func write(_ data: Data, relative: String) throws {
        let output = analysis.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output)
    }
}
