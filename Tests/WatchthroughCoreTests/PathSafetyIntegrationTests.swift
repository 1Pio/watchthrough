import Foundation
import XCTest
@testable import WatchthroughCore

final class PathSafetyIntegrationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var ffmpeg: URL!

    override func setUpWithError() throws {
        guard let foundFFmpeg = Tooling.find("ffmpeg"), Tooling.find("ffprobe") != nil else {
            throw XCTSkip("FFmpeg and FFprobe are required for path-safety integration tests")
        }
        ffmpeg = foundFFmpeg
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-path-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testPrepareRefusesOutputThatContainsSource() throws {
        let output = temporaryDirectory.appendingPathComponent("unsafe-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let source = output.appendingPathComponent("source.mkv")
        try makeVideo(at: source)

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", output.path,
            "--transcriber", "none",
            "--refresh",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .usage)
            XCTAssertTrue(failure?.message.contains("contain the source") == true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPrepareRefusesSymlinkedOutputRoot() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let target = temporaryDirectory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let output = temporaryDirectory.appendingPathComponent("linked-output", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", output.path,
            "--transcriber", "none",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .usage)
            XCTAssertTrue(failure?.message.contains("symbolic link") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testReadCommandsDoNotCreateAnythingForMissingAnalysisPath() throws {
        let missingParent = temporaryDirectory.appendingPathComponent("mistyped", isDirectory: true)
        let missing = missingParent.appendingPathComponent("analysis", isDirectory: true)

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "inspect", missing.path, "overview",
        ]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))

        XCTAssertEqual(
            try WatchthroughApplication().run(arguments: ["status", missing.path]),
            .operation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))
    }

    func testRefreshRefusesUnownedDestinationWithoutReplacingIt() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let output = temporaryDirectory.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: sentinel)

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", output.path,
            "--transcriber", "none",
            "--refresh",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .operation)
            XCTAssertTrue(failure?.message.contains("refuse to refresh") == true)
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unrelated")
    }

    func testGeneratedInspectionRefusesSymlinkedInspectionsDirectory() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])

        let external = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: analysis.appendingPathComponent("inspections", isDirectory: true),
            withDestinationURL: external
        )

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "inspect", analysis.path, "00:00.100",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .operation)
            XCTAssertTrue(failure?.message.contains("unsafe inspections directory") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testGeneratedInspectionRefusesSymlinkedIdentityDirectory() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])
        _ = try WatchthroughApplication().run(arguments: [
            "inspect", analysis.path, "00:00.100",
        ])

        let inspections = analysis.appendingPathComponent("inspections", isDirectory: true)
        let identity = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: inspections,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        )
        try FileManager.default.moveItem(
            at: identity,
            to: temporaryDirectory.appendingPathComponent("held-inspection", isDirectory: true)
        )
        let external = temporaryDirectory.appendingPathComponent("external-identity", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: identity, withDestinationURL: external)

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "inspect", analysis.path, "00:00.100",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .operation)
            XCTAssertTrue(failure?.message.contains("existing inspection path is unsafe") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testRefreshRefusesUnrecognizedNestedEntryWithoutDeletingIt() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])
        let personalNote = analysis.appendingPathComponent("visual/overview/personal-note.md")
        try Data("keep this".utf8).write(to: personalNote)

        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
            "--refresh",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .operation)
            XCTAssertTrue(failure?.message.contains("unrecognized entry") == true)
        }
        XCTAssertEqual(try String(contentsOf: personalNote, encoding: .utf8), "keep this")
    }

    func testRefreshRepairsMissingRecognizedArtifact() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])

        let packetURL = analysis.appendingPathComponent("visual/overview/packet.json")
        let packet = try StableJSON.decode(InspectionPacket.self, from: packetURL)
        let missing = analysis
            .appendingPathComponent("visual/overview", isDirectory: true)
            .appendingPathComponent(try XCTUnwrap(packet.cells.first).framePath)
        try FileManager.default.moveItem(
            at: missing,
            to: temporaryDirectory.appendingPathComponent("held-frame.jpg")
        )

        XCTAssertEqual(
            try WatchthroughApplication().run(arguments: [
                "prepare", source.path,
                "--out", analysis.path,
                "--transcriber", "none",
                "--refresh",
            ]),
            .success
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.path))
    }

    func testFirstConcurrentInspectionsCanShareDirectoryCreation() throws {
        let analysis = temporaryDirectory.appendingPathComponent("analysis-root", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: false)
        let resultLock = NSLock()
        var errors: [Error] = []
        var paths: [String] = []

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let result = try PathSafety.ensureInspectionsDirectory(under: analysis)
                resultLock.lock()
                paths.append(result.path)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                errors.append(error)
                resultLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "unexpected directory-creation errors: \(errors)")
        XCTAssertEqual(Set(paths).count, 1)
        XCTAssertEqual(paths.count, 16)
    }

    func testAnalysisWriterLockExcludesInspectionRead() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])

        let writer = try ExclusiveFileLock.acquire(
            at: temporaryDirectory.appendingPathComponent(".analysis.lock")
        )
        defer { writer.unlock() }
        XCTAssertThrowsError(try WatchthroughApplication().run(arguments: [
            "inspect", analysis.path, "overview",
        ])) { error in
            let failure = error as? WatchthroughFailure
            XCTAssertEqual(failure?.category, .operation)
            XCTAssertTrue(failure?.message.contains("already being written") == true)
        }
    }

    func testInspectFallsBackToContentIdentityAfterSourceTimestampChanges() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: source.path
        )

        XCTAssertEqual(
            try WatchthroughApplication().run(arguments: [
                "inspect", analysis.path, "overview",
            ]),
            .success
        )
    }

    func testDistinctExactSamplingIntervalsNeverShareAnInspectionIdentity() throws {
        let source = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideo(at: source)
        let analysis = temporaryDirectory.appendingPathComponent("analysis", isDirectory: true)
        _ = try WatchthroughApplication().run(arguments: [
            "prepare", source.path,
            "--out", analysis.path,
            "--transcriber", "none",
        ])

        for interval in ["0.5001s", "0.5004s"] {
            _ = try WatchthroughApplication().run(arguments: [
                "inspect", analysis.path, "00:00..00:00.5",
                "--every", interval,
            ])
        }
        let inspections = analysis.appendingPathComponent("inspections", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(
            at: inspections,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        XCTAssertEqual(directories.count, 2)
    }

    private func makeVideo(at destination: URL) throws {
        _ = try ProcessRunner.run(
            ffmpeg.path,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "color=c=blue:s=96x54:r=4:d=0.5",
                "-c:v", "ffv1", destination.path,
            ],
            timeout: 30
        ).requireSuccess("could not generate path-safety fixture")
    }
}
