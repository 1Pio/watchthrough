import CryptoKit
import Darwin
import Dispatch
import Foundation

public struct ProcessOutput: Sendable {
    public let stdoutData: Data
    public let stderrData: Data
    public let exitCode: Int32
    public let timedOut: Bool

    public init(stdoutData: Data, stderrData: Data, exitCode: Int32, timedOut: Bool) {
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut }

    @discardableResult
    public func requireSuccess(_ context: String? = nil) throws -> ProcessOutput {
        guard succeeded else {
            let prefix = context.map { "\($0): " } ?? ""
            let reason: String
            if timedOut {
                reason = "timed out"
            } else {
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty ? fallback : detail
                reason = message.isEmpty ? "exited with status \(exitCode)" : message
            }
            throw WatchthroughFailure(.operation, prefix + reason.prefix(4_000))
        }
        return self
    }
}

public enum ProcessSignalRelay {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeProcessGroups = Set<pid_t>()
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    private static let queue = DispatchQueue(label: "watchthrough.signal-relay")

    /// Install once in the CLI process. Child groups remain independently
    /// killable for timeout handling, while terminal cancellation is relayed
    /// before this process exits.
    public static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard sources.isEmpty else { return }

        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: queue
            )
            source.setEventHandler {
                let groups = snapshotProcessGroups()
                for group in groups {
                    _ = Darwin.kill(-group, signalNumber)
                }
                if !groups.isEmpty {
                    usleep(150_000)
                    for group in groups where Darwin.kill(-group, 0) == 0 || errno == EPERM {
                        _ = Darwin.kill(-group, SIGKILL)
                    }
                }
                Darwin._exit(128 + signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }

    fileprivate static func spawnAndRegister(
        _ operation: () -> (status: Int32, processIdentifier: pid_t)
    ) -> (status: Int32, processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        let result = operation()
        if result.status == 0 {
            activeProcessGroups.insert(result.processIdentifier)
        }
        return result
    }

    fileprivate static func unregister(_ processIdentifier: pid_t) {
        lock.lock()
        activeProcessGroups.remove(processIdentifier)
        lock.unlock()
    }

    @discardableResult
    static func cancelActiveProcessGroups(signal signalNumber: Int32) -> [pid_t] {
        let groups = snapshotProcessGroups()
        for group in groups {
            _ = Darwin.kill(-group, signalNumber)
        }
        return groups
    }

    private static func snapshotProcessGroups() -> [pid_t] {
        lock.lock()
        let groups = Array(activeProcessGroups)
        lock.unlock()
        return groups
    }
}

public enum ProcessRunner {
    /// Executes one program directly. Arguments are never interpreted by a shell.
    /// `inheritEnvironment` carries only a small runtime allowlist; credentials
    /// and unrelated parent configuration are never inherited implicitly.
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment overrides: [String: String]? = nil,
        inheritEnvironment: Bool = true,
        timeout: TimeInterval? = nil
    ) throws -> ProcessOutput {
        if let timeout, !timeout.isFinite || timeout <= 0 {
            throw WatchthroughFailure(.usage, "process timeout must be greater than zero")
        }

        let executableURL = try resolveExecutable(executable)
        let inherited = inheritEnvironment
            ? constrainedEnvironment()
            : [:]
        let environment = inherited.merging(overrides ?? [:]) { _, override in override }
        try validateInvocation(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        )
        let child = try SpawnedProcess.launch(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment
        )
        defer { ProcessSignalRelay.unregister(child.processIdentifier) }

        var stdout = CapturedPipe(readDescriptor: child.standardOutput)
        var stderr = CapturedPipe(readDescriptor: child.standardError)
        var waitStatus: Int32 = 0
        var childExited = false
        var completed = false
        defer {
            stdout.close()
            stderr.close()
            if !completed {
                signalProcessGroup(child.processIdentifier, signal: SIGKILL)
                reap(child.processIdentifier, status: &waitStatus)
            }
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let timeoutAt = timeout.map { startedAt + $0 }
        var terminationSentAt: TimeInterval?
        var forceKillSentAt: TimeInterval?
        var timedOut = false

        while true {
            try stdout.drain()
            try stderr.drain()
            if !childExited {
                childExited = try reapIfExited(child.processIdentifier, status: &waitStatus)
            }

            if childExited, !timedOut {
                // The direct child has finished, so all of its output is already
                // in the kernel pipes. Drain it once more and do not wait for an
                // unrelated descendant that inherited a pipe descriptor.
                try stdout.drain()
                try stderr.drain()
                break
            }

            if childExited, !stdout.isOpen, !stderr.isOpen {
                break
            }

            let now = ProcessInfo.processInfo.systemUptime
            if !timedOut, let timeoutAt, now >= timeoutAt {
                timedOut = true
                terminationSentAt = now
                signalProcessGroup(child.processIdentifier, signal: SIGTERM)
            }
            if let terminationSentAt,
               forceKillSentAt == nil,
               now >= terminationSentAt + 2 {
                forceKillSentAt = now
                signalProcessGroup(child.processIdentifier, signal: SIGKILL)
            }

            if timedOut, childExited {
                if !processGroupExists(child.processIdentifier)
                    || forceKillSentAt.map({ now >= $0 + 0.1 }) == true {
                    try stdout.drain()
                    try stderr.drain()
                    break
                }
            }

            let pollMilliseconds = pollDelay(
                now: now,
                timeoutAt: timedOut ? nil : timeoutAt,
                terminationSentAt: terminationSentAt,
                forceKillSentAt: forceKillSentAt
            )
            try poll([stdout.descriptor, stderr.descriptor].compactMap { $0 }, milliseconds: pollMilliseconds)
        }

        if !childExited {
            reap(child.processIdentifier, status: &waitStatus)
        }
        completed = true
        return ProcessOutput(
            stdoutData: stdout.data,
            stderrData: stderr.data,
            exitCode: terminationStatus(from: waitStatus),
            timedOut: timedOut
        )
    }

    private static func validateInvocation(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws {
        let strings = [executableURL.path] + arguments + (currentDirectory.map { [$0.path] } ?? [])
        guard strings.allSatisfy({ !$0.contains("\0") }) else {
            throw WatchthroughFailure(.usage, "process arguments cannot contain null bytes")
        }
        guard environment?.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }) != false else {
            throw WatchthroughFailure(.usage, "process environment contains an invalid name or value")
        }
        if let currentDirectory {
            var isDirectory = ObjCBool(false)
            guard currentDirectory.isFileURL,
                  FileManager.default.fileExists(atPath: currentDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw WatchthroughFailure(.readiness, "process working directory is unavailable")
            }
        }
    }

    static func constrainedEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment: [String: String] = [
            "HOME": parent["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": parent["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": parent["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": parent["LC_ALL"] ?? "C",
        ]
        if let xdgConfig = parent["XDG_CONFIG_HOME"] {
            environment["XDG_CONFIG_HOME"] = xdgConfig
        }
        return environment
    }

    private static func reapIfExited(_ processIdentifier: pid_t, status: inout Int32) throws -> Bool {
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            throw WatchthroughFailure(.operation, "could not wait for child process: \(systemError(errno))")
        }
    }

    private static func reap(_ processIdentifier: pid_t, status: inout Int32) {
        while waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
    }

    private static func signalProcessGroup(_ processIdentifier: pid_t, signal: Int32) {
        _ = Darwin.kill(-processIdentifier, signal)
    }

    private static func processGroupExists(_ processIdentifier: pid_t) -> Bool {
        Darwin.kill(-processIdentifier, 0) == 0 || errno == EPERM
    }

    private static func pollDelay(
        now: TimeInterval,
        timeoutAt: TimeInterval?,
        terminationSentAt: TimeInterval?,
        forceKillSentAt: TimeInterval?
    ) -> Int32 {
        let nextDeadline: TimeInterval?
        if let forceKillSentAt {
            nextDeadline = forceKillSentAt + 0.1
        } else if let terminationSentAt {
            nextDeadline = terminationSentAt + 2
        } else {
            nextDeadline = timeoutAt
        }
        // A descendant may inherit an output pipe after the direct child exits.
        // Wake periodically so waitpid can observe that exit without waiting for
        // the inherited descriptor to close.
        guard let nextDeadline else { return 50 }
        let remaining = max(0, nextDeadline - now)
        return Int32(min(remaining * 1_000, 50).rounded(.up))
    }

    private static func poll(_ descriptors: [Int32], milliseconds: Int32) throws {
        guard !descriptors.isEmpty else {
            if milliseconds < 0 {
                usleep(10_000)
            } else if milliseconds > 0 {
                usleep(useconds_t(min(Int64(milliseconds) * 1_000, Int64(useconds_t.max))))
            }
            return
        }
        var entries = descriptors.map {
            pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        }
        let result = Darwin.poll(&entries, nfds_t(entries.count), milliseconds)
        guard result >= 0 || errno == EINTR else {
            throw WatchthroughFailure(.operation, "could not read child process output: \(systemError(errno))")
        }
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7F
        return signal == 0 ? (waitStatus >> 8) & 0xFF : signal
    }

    fileprivate static func systemError(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func resolveExecutable(_ executable: String) throws -> URL {
        guard !executable.isEmpty else {
            throw WatchthroughFailure(.readiness, "empty executable name")
        }
        if executable.contains("/") {
            let expanded = NSString(string: executable).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw WatchthroughFailure(.readiness, "executable is missing or not executable: \(url.path)")
            }
            return url
        }
        return try Tooling.require(executable)
    }
}

public enum Tooling {
    public static func find(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let path = NSString(string: name).expandingTildeInPath
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
            let url = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    public static func require(_ name: String) throws -> URL {
        guard let url = find(name) else {
            throw WatchthroughFailure(.readiness, "required tool '\(name)' was not found on PATH")
        }
        return url
    }

    public static func version(
        of executable: String,
        arguments: [String],
        timeout: TimeInterval = 10
    ) throws -> String {
        let output = try ProcessRunner.run(executable, arguments: arguments, timeout: timeout)
            .requireSuccess("could not read \(executable) version")
        let text = output.stdout.isEmpty ? output.stderr : output.stdout
        guard let firstLine = text.split(whereSeparator: \Character.isNewline).first else {
            throw WatchthroughFailure(.readiness, "\(executable) returned an empty version response")
        }
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum FileSHA256 {
    public static func hexDigest(of url: URL, chunkSize: Int = 1_048_576) throws -> String {
        guard chunkSize > 0 else {
            throw WatchthroughFailure(.usage, "hash chunk size must be greater than zero")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WatchthroughFailure(.readiness, "cannot read source for hashing: \(url.path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum StableJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decode(type, from: Data(contentsOf: url))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(value).write(to: url, options: .atomic)
    }
}

public enum ISO8601Clock {
    public static func now() -> String { string(from: Date()) }

    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct SpawnedProcess {
    let processIdentifier: pid_t
    let standardOutput: Int32
    let standardError: Int32

    static func launch(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]
    ) throws -> Self {
        var ownedDescriptors: [Int32] = []
        var ownsAllDescriptors = true
        defer {
            if ownsAllDescriptors {
                ownedDescriptors.forEach { Darwin.close($0) }
            }
        }
        let standardOutput = try makePipe(ownedDescriptors: &ownedDescriptors)
        let standardError = try makePipe(ownedDescriptors: &ownedDescriptors)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try requireSuccess(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try requireSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try requireSuccess(posix_spawn_file_actions_adddup2(&actions, standardOutput[1], STDOUT_FILENO))
        try requireSuccess(posix_spawn_file_actions_adddup2(&actions, standardError[1], STDERR_FILENO))
        for descriptor in ownedDescriptors {
            try requireSuccess(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        if let currentDirectory {
            let result = currentDirectory.path.withCString { path in
                if #available(macOS 26.0, *) {
                    posix_spawn_file_actions_addchdir(&actions, path)
                } else {
                    posix_spawn_file_actions_addchdir_np(&actions, path)
                }
            }
            try requireSuccess(result)
        }

        try requireSuccess(posix_spawnattr_setpgroup(&attributes, 0))
        // CoreML-backed local tools rely on system descriptors inherited across
        // spawn. Closing unknown descriptors by default causes those tools to be
        // killed before model execution; our own pipes are closed explicitly.
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try requireSuccess(posix_spawnattr_setflags(&attributes, flags))

        let argv = [executableURL.path] + arguments
        let envp = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        let spawn = try withMutableCStrings(argv) { argumentPointers in
            try withMutableCStrings(envp) { environmentPointers in
                ProcessSignalRelay.spawnAndRegister {
                    var processIdentifier: pid_t = 0
                    let status = executableURL.path.withCString { executablePath in
                        posix_spawn(
                            &processIdentifier,
                            executablePath,
                            &actions,
                            &attributes,
                            argumentPointers,
                            environmentPointers
                        )
                    }
                    return (status, processIdentifier)
                }
            }
        }
        guard spawn.status == 0 else {
            throw WatchthroughFailure(
                .readiness,
                "could not start \(executableURL.lastPathComponent): \(ProcessRunner.systemError(spawn.status))"
            )
        }
        let processIdentifier = spawn.processIdentifier

        Darwin.close(standardOutput[1])
        Darwin.close(standardError[1])
        ownsAllDescriptors = false
        return Self(
            processIdentifier: processIdentifier,
            standardOutput: standardOutput[0],
            standardError: standardError[0]
        )
    }

    private static func makePipe(ownedDescriptors: inout [Int32]) throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw WatchthroughFailure(.operation, "could not create process pipe: \(ProcessRunner.systemError(errno))")
        }
        ownedDescriptors.append(contentsOf: descriptors)
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                throw WatchthroughFailure(.operation, "could not configure process pipe: \(ProcessRunner.systemError(errno))")
            }
        }
        let statusFlags = fcntl(descriptors[0], F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptors[0], F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw WatchthroughFailure(.operation, "could not configure process pipe: \(ProcessRunner.systemError(errno))")
        }
        return descriptors
    }

    private static func requireSuccess(_ result: Int32) throws {
        guard result == 0 else {
            throw WatchthroughFailure(.operation, "could not configure child process: \(ProcessRunner.systemError(result))")
        }
    }

    private static func withMutableCStrings<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for case let pointer? in pointers {
                free(pointer)
            }
        }
        pointers.reserveCapacity(values.count + 1)
        for value in values {
            guard let pointer = strdup(value) else {
                throw WatchthroughFailure(.operation, "could not allocate child process arguments")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private struct CapturedPipe {
    private(set) var descriptor: Int32?
    private(set) var data = Data()

    init(readDescriptor: Int32) {
        descriptor = readDescriptor
    }

    var isOpen: Bool { descriptor != nil }

    mutating func drain() throws {
        guard let descriptor else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }
            if count == 0 {
                close()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw WatchthroughFailure(.operation, "could not read child process output: \(ProcessRunner.systemError(errno))")
        }
    }

    mutating func close() {
        guard let descriptor else { return }
        Darwin.close(descriptor)
        self.descriptor = nil
    }
}
