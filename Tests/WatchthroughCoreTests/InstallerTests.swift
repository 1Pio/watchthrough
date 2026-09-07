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
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: cleanHome.appendingPathComponent(".agents/skills/watchthrough").path
            ),
            repository.appendingPathComponent("skill").path
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cleanHome.appendingPathComponent(".agents/skills/watchthrough/SKILL.md").path
        ))

        let collisionHome = temporaryDirectory.appendingPathComponent("collision-home", isDirectory: true)
        let skillCollision = collisionHome.appendingPathComponent(".agents/skills/watchthrough", isDirectory: true)
        try FileManager.default.createDirectory(at: skillCollision, withIntermediateDirectories: true)
        XCTAssertNotEqual(try runInstaller(home: collisionHome), 0)

        let command = collisionHome.appendingPathComponent(".local/bin/watchthrough")
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.path))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: command.path))
    }

    func testSameCheckoutLegacySkillLinkMigratesIdempotently() throws {
        let home = temporaryDirectory.appendingPathComponent("legacy-home", isDirectory: true)
        let command = home.appendingPathComponent(".local/bin/watchthrough")
        let skill = home.appendingPathComponent(".agents/skills/watchthrough")
        let binary = repository.appendingPathComponent("dist/macos-arm64/watchthrough")
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: command, withDestinationURL: binary)
        try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: repository)

        XCTAssertEqual(try runInstaller(home: home), 0)
        XCTAssertEqual(try runInstaller(home: home), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), binary.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skill.path),
            repository.appendingPathComponent("skill").path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: skill.deletingLastPathComponent().path),
            ["watchthrough"], "successful migration leaves no temporary link")
    }

    func testUnrelatedSkillLinkRefusesBeforeCreatingCommand() throws {
        let home = temporaryDirectory.appendingPathComponent("foreign-skill-home", isDirectory: true)
        let skill = home.appendingPathComponent(".agents/skills/watchthrough")
        let unrelated = temporaryDirectory.appendingPathComponent("other-checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: unrelated)

        XCTAssertNotEqual(try runInstaller(home: home), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skill.path), unrelated.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/bin").path),
            "all collisions must be checked before creating installation directories or links")
    }

    func testCommandCollisionCannotPartiallyMigrateLegacySkill() throws {
        let home = temporaryDirectory.appendingPathComponent("foreign-command-home", isDirectory: true)
        let command = home.appendingPathComponent(".local/bin/watchthrough")
        let skill = home.appendingPathComponent(".agents/skills/watchthrough")
        let unrelated = temporaryDirectory.appendingPathComponent("user-command")
        try Data("preserve user command".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: command, withDestinationURL: unrelated)
        try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: repository)

        XCTAssertNotEqual(try runInstaller(home: home), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), unrelated.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skill.path), repository.path)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve user command".utf8))
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
