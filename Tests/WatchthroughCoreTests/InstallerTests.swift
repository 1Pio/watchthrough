import Foundation
import XCTest

final class InstallerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testInstallIsIdempotentAndPreflightsAllCollisions() throws {
        let cleanHome = temporaryDirectory.appendingPathComponent("clean-home", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanHome, withIntermediateDirectories: false)
        XCTAssertEqual(try runInstaller(home: cleanHome), 0)
        XCTAssertEqual(try runInstaller(home: cleanHome), 0)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: cleanHome.appendingPathComponent(".local/bin/watchthrough").path
            ),
            repository.appendingPathComponent("dist/macos-arm64/watchthrough").path
        )

        let collisionHome = temporaryDirectory.appendingPathComponent("collision-home", isDirectory: true)
        let skillCollision = collisionHome.appendingPathComponent(".agents/skills/watchthrough", isDirectory: true)
        try FileManager.default.createDirectory(at: skillCollision, withIntermediateDirectories: true)
        XCTAssertNotEqual(try runInstaller(home: collisionHome), 0)

        let command = collisionHome.appendingPathComponent(".local/bin/watchthrough")
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.path))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: command.path))
    }

    private func runInstaller(home: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repository.appendingPathComponent("install.sh").path]
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) {
            _, override in override
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
