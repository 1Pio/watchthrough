import Darwin
import Foundation
import XCTest
@testable import WatchthroughCore

final class ProcessRunnerTests: XCTestCase {
    func testPreservesDescriptorsExplicitlyMarkedForChildInheritance() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-inherited-fd-\(UUID().uuidString)")
        var descriptor = Darwin.open(destination.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            try? FileManager.default.removeItem(at: destination)
        }

        let descriptorFlags = fcntl(descriptor, F_GETFD)
        XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
        XCTAssertEqual(fcntl(descriptor, F_SETFD, descriptorFlags & ~FD_CLOEXEC), 0)

        let output = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "printf inherited >&$WATCHTHROUGH_INHERITED_FD"],
            environment: ["WATCHTHROUGH_INHERITED_FD": String(descriptor)]
        ).requireSuccess()
        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertEqual(Darwin.close(descriptor), 0)
        descriptor = -1
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "inherited")
    }

    func testDefaultEnvironmentKeepsCredentialsOutButMergesExplicitOverrides() throws {
        let credentialName = "ELEVENLABS_API_KEY"
        let fixtureSecret = "fixture-secret-must-not-cross-process-boundary"
        let previousValue = getenv(credentialName).map { String(cString: $0) }
        XCTAssertEqual(setenv(credentialName, fixtureSecret, 1), 0)
        defer {
            if let previousValue {
                setenv(credentialName, previousValue, 1)
            } else {
                unsetenv(credentialName)
            }
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment[credentialName], fixtureSecret)

        let output = try ProcessRunner.run(
            "/usr/bin/env",
            environment: ["WATCHTHROUGH_EXPLICIT_OVERRIDE": "present"]
        ).requireSuccess()
        let environment = Dictionary(uniqueKeysWithValues: output.stdout
            .split(whereSeparator: \Character.isNewline)
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            })

        XCTAssertNil(environment[credentialName])
        XCTAssertEqual(environment["WATCHTHROUGH_EXPLICIT_OVERRIDE"], "present")
        XCTAssertNotNil(environment["PATH"])
        XCTAssertNotNil(environment["HOME"])
        XCTAssertNotNil(environment["TMPDIR"])
    }

    func testTimeoutTerminatesDescendantsWithoutWaitingForInheritedPipes() throws {
        let started = Date()
        let output = try ProcessRunner.run(
            "/bin/sh",
            arguments: [
                "-c",
                "(trap '' TERM; sleep 6) & descendant=$!; printf '%s\\n' \"$descendant\"; wait",
            ],
            timeout: 0.1
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(elapsed, 3.5, "timeout waited for a descendant-held pipe to close")

        let pid = try XCTUnwrap(pid_t(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let cleanupDeadline = Date().addingTimeInterval(0.5)
        while Darwin.kill(pid, 0) == 0, Date() < cleanupDeadline {
            usleep(10_000)
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "timed-out descendant was left running")
        XCTAssertEqual(errno, ESRCH)
    }

    func testNormalExitDoesNotWaitForDescendantHeldPipe() throws {
        let started = Date()
        let output = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "(sleep 2) & printf finished; kill -TERM $$"],
            timeout: 5
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.stdout, "finished")
        XCTAssertLessThan(elapsed, 1, "normal exit waited for a descendant-held pipe")
    }

    func testCancellationRelayTerminatesRegisteredProcessGroup() throws {
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-relay-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let completed = expectation(description: "ProcessRunner returned after relayed termination")

        DispatchQueue.global().async {
            _ = try? ProcessRunner.run(
                "/bin/sh",
                arguments: [
                    "-c",
                    "printf ready > \"$WATCHTHROUGH_RELAY_READY\"; while :; do sleep 1; done",
                ],
                environment: ["WATCHTHROUGH_RELAY_READY": ready.path],
                timeout: 30
            )
            completed.fulfill()
        }

        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        let groups = ProcessSignalRelay.cancelActiveProcessGroups(signal: SIGKILL)
        XCTAssertEqual(groups.count, 1)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(Darwin.kill(-groups[0], 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
