import Foundation

struct YouTubeToolchain {
    var downloader: URL
    var downloaderVersion: String
    var javascriptName: String
    var javascript: URL
    var ffmpeg: URL
    var ffprobe: URL
    var downloaderArguments: [String] = []
}

/// Keep the changing extractor outside the Swift executable. Ordinary use never
/// installs code; the explicit update action verifies an official release before
/// promoting it, and leaves both the system installation and prior version alone.
enum YouTubeTools {
    static let minimumDownloaderVersion = "2026.08.19"
    static let releaseAPI = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

    struct Release: Equatable {
        var version: String
        var sha256: String
        var size: Int64
        var downloadURL: URL
        var checksumURL: URL
        var assetName: String = "yt-dlp_macos"
    }

    struct Receipt: Codable {
        var schema = "watchthrough.youtube-tool.v1"
        var version: String
        var sha256: String
        var sizeBytes: Int64
        var downloadedAt: String
        var upstreamRelease: String
        var assetName: String = "yt-dlp_macos"
    }

    struct Downloader {
        var path: URL
        var version: String
        var arguments: [String] = []
        var artifact: URL
        var assetName: String = "yt-dlp_macos"
    }

    static func resolve(update: Bool) throws -> YouTubeToolchain {
        let ffmpeg = try Tooling.require("ffmpeg")
        let ffprobe = try Tooling.require("ffprobe")
        let runtime = try javascriptRuntime()
        let downloader = try resolveDownloader(update: update)
        return YouTubeToolchain(downloader: downloader.path, downloaderVersion: downloader.version,
            javascriptName: runtime.name, javascript: runtime.path, ffmpeg: ffmpeg, ffprobe: ffprobe,
            downloaderArguments: downloader.arguments)
    }

    static func javascriptRuntime() throws -> (name: String, path: URL, version: String) {
        var rejected: [String] = []
        for (name, minimum) in [("deno", [2, 3, 0]), ("node", [22, 0, 0])] {
            guard let path = Tooling.find(name) else { continue }
            let version = try? Tooling.version(of: path.path, arguments: ["--version"], timeout: 5)
            if let version, let components = semanticVersion(version),
               !components.lexicographicallyPrecedes(minimum) {
                return (name, path, version)
            }
            rejected.append(name)
        }
        let detail = rejected.isEmpty ? "" : " Detected but unsupported: \(rejected.joined(separator: ", "))."
        throw WatchthroughFailure(.readiness,
            "YouTube acquisition needs Deno >=2.3.0 or Node >=22 on PATH.\(detail) Install a supported runtime, then retry the same acquire command.")
    }

    static func resolveDownloader(update: Bool = false) throws -> Downloader {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["WATCHTHROUGH_YT_DLP"], !override.isEmpty {
            guard !update else {
                throw WatchthroughFailure(.usage, "--update-downloader cannot be combined with WATCHTHROUGH_YT_DLP; clear the override to update the managed downloader")
            }
            guard override.hasPrefix("/") else {
                throw WatchthroughFailure(.usage, "WATCHTHROUGH_YT_DLP must be an absolute executable path")
            }
            return try validatedExecutable(URL(fileURLWithPath: override))
        }

        let root = try toolsDirectory()
        if update { try updateManaged(at: root) }
        if let managed = try managedDownloader(at: root) { return managed }
        if let installed = Tooling.find("yt-dlp") { return try validatedExecutable(installed) }
        throw WatchthroughFailure(.readiness,
            "YouTube downloader is missing. Retry acquire with --update-downloader to install a verified official copy for watchthrough, or install current yt-dlp with its matching EJS component.")
    }

    static func toolsDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["WATCHTHROUGH_TOOLS_DIR"], !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw WatchthroughFailure(.usage, "WATCHTHROUGH_TOOLS_DIR must be an absolute directory")
            }
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/watchthrough/tools/youtube", isDirectory: true)
    }

    static func managedDownloader(at root: URL) throws -> Downloader? {
        if PathSafety.entryType(at: root) != nil { try requireDirectory(root) }
        let active = root.appendingPathComponent("active.json")
        guard PathSafety.entryType(at: active) != nil else { return nil }
        try requireRegular(active)
        let receipt = try StableJSON.decode(Receipt.self, from: active)
        try validateReceipt(receipt)
        let directory = packageDirectory(in: root, version: receipt.version,
            assetName: receipt.assetName, sha256: receipt.sha256)
        return try verifiedTool(in: directory, receipt: receipt)
    }

    private static func verifiedTool(in directory: URL, receipt: Receipt) throws -> Downloader {
        try requireDirectory(directory)
        let executable = directory.appendingPathComponent("yt-dlp")
        try requireRegular(executable)
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == receipt.sizeBytes,
              try FileSHA256.hexDigest(of: executable) == receipt.sha256 else {
            throw WatchthroughFailure(.readiness,
                "Managed YouTube downloader failed integrity verification; retry acquire with --update-downloader or select a verified WATCHTHROUGH_YT_DLP override")
        }
        let validated = try validatedExecutable(executable, assetName: receipt.assetName)
        guard validated.version == receipt.version else {
            throw WatchthroughFailure(.readiness, "Managed YouTube downloader version does not match its receipt")
        }
        return validated
    }

    static func parseRelease(_ data: Data, assetName: String = "yt-dlp_macos") throws -> Release {
        struct Asset: Decodable { var name: String; var size: Int64; var digest: String?; var browser_download_url: String }
        struct Response: Decodable { var tag_name: String; var draft: Bool; var prerelease: Bool; var assets: [Asset] }
        let response = try StableJSON.decode(Response.self, from: data)
        guard !response.draft, !response.prerelease, validReleaseVersion(response.tag_name),
              response.tag_name.compare(minimumDownloaderVersion, options: .numeric) != .orderedAscending else {
            throw WatchthroughFailure(.readiness, "Official downloader release metadata does not identify a supported stable release")
        }
        guard ["yt-dlp", "yt-dlp_macos"].contains(assetName) else {
            throw WatchthroughFailure(.readiness, "Unsupported official downloader package")
        }
        let matches = response.assets.filter { $0.name == assetName }
        guard matches.count == 1, let asset = matches.first,
              (1...134_217_728).contains(asset.size),
              let digest = asset.digest, digest.hasPrefix("sha256:"), validDigest(String(digest.dropFirst(7))) else {
            throw WatchthroughFailure(.readiness, "Official downloader release is missing an unambiguous macOS asset and SHA256 digest")
        }
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(response.tag_name)/"
        guard asset.browser_download_url == base + assetName else {
            throw WatchthroughFailure(.readiness, "Downloader asset URL is outside the expected official release")
        }
        return Release(version: response.tag_name, sha256: String(digest.dropFirst(7)), size: asset.size,
            downloadURL: URL(string: base + assetName)!, checksumURL: URL(string: base + "SHA2-256SUMS")!, assetName: assetName)
    }

    static func verifyChecksumList(_ data: Data, release: Release) throws {
        let entries = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == Substring(release.assetName) || fields[1] == Substring("*" + release.assetName) else { return nil }
            return String(fields[0])
        }
        guard entries == [release.sha256] else {
            throw WatchthroughFailure(.readiness, "Official downloader checksums do not match the release API's SHA256 digest")
        }
    }

    private static func updateManaged(at root: URL) throws {
        if PathSafety.entryType(at: root) == nil {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(root)
        let lockURL = root.appendingPathComponent("update.lock")
        if PathSafety.entryType(at: lockURL) != nil { try requireRegular(lockURL) }
        let lock = try ExclusiveFileLock.acquire(at: lockURL)
        defer { lock.unlock() }
        let active = root.appendingPathComponent("active.json")
        if PathSafety.entryType(at: active) != nil { try requireRegular(active) }

        progress("Checking the official YouTube downloader release...")
        // The official zipimport package is ~3 MiB and avoids PyInstaller's
        // one-file semaphore startup, which restricted execution hosts can deny.
        // Reuse an existing compatible Python; never provision a Python environment.
        let assetName = pythonRuntime() == nil ? "yt-dlp_macos" : "yt-dlp"
        let release = try parseRelease(fetch(URL(string: releaseAPI)!, maximumBytes: 1_048_576), assetName: assetName)
        try verifyChecksumList(fetch(release.checksumURL, maximumBytes: 65_536), release: release)

        if let existing = try? managedDownloader(at: root), existing.version == release.version,
           existing.assetName == release.assetName,
           (try? FileSHA256.hexDigest(of: existing.artifact)) == release.sha256 { return }
        if let existing = try? managedDownloader(at: root),
           existing.version.compare(release.version, options: .numeric) == .orderedDescending {
            throw WatchthroughFailure(.readiness, "Refusing to downgrade a newer managed YouTube downloader")
        }

        let destination = packageDirectory(in: root, version: release.version,
            assetName: release.assetName, sha256: release.sha256)
        if PathSafety.entryType(at: destination) != nil {
            // A process can finish promotion and die before switching active.json.
            // Adopt only the exact verified release, never an arbitrary directory.
            let receiptURL = destination.appendingPathComponent("receipt.json")
            if PathSafety.entryType(at: receiptURL) == .typeRegular,
               let receipt = try? StableJSON.decode(Receipt.self, from: receiptURL),
               receipt.version == release.version, receipt.sha256 == release.sha256,
               receipt.assetName == release.assetName,
               receipt.sizeBytes == release.size, (try? validateReceipt(receipt)) != nil,
               (try? verifiedTool(in: destination, receipt: receipt)) != nil {
                try StableJSON.write(receipt, to: active)
                return
            }
            // A damaged owned copy can be repaired by the explicit update. Keep
            // it in place until the replacement has passed every check.
            try validateOwnedPackageDirectory(destination, release: release)
        }
        let staging = root.appendingPathComponent(".download-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let executable = staging.appendingPathComponent("yt-dlp")
        progress("Downloading official yt-dlp \(release.version) (\(release.size / 1_048_576) MiB)...")
        do {
            try download(release.downloadURL, to: executable, maximumBytes: release.size)
            try activateDownloadedTool(staging: staging, release: release, root: root)
        } catch {
            throw WatchthroughFailure(.readiness,
                "Downloader update failed; the prior active version was preserved. \(error) Staged files, if any, remain at \(staging.path).")
        }
    }

    static func activateDownloadedTool(staging: URL, release: Release, root: URL,
        publishActive: (Receipt, URL) throws -> Void = { try StableJSON.write($0, to: $1) }) throws {
        try requireDirectory(root)
        try requireDirectory(staging)
        guard staging.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              validReleaseVersion(release.version), validDigest(release.sha256),
              ["yt-dlp", "yt-dlp_macos"].contains(release.assetName) else {
            throw WatchthroughFailure(.readiness, "Downloader staging identity is unsafe")
        }
        let executable = staging.appendingPathComponent("yt-dlp")
        try requireRegular(executable)
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == release.size,
              try FileSHA256.hexDigest(of: executable) == release.sha256 else {
            throw WatchthroughFailure(.readiness, "Downloaded YouTube tool failed its official size/SHA256 checks; it was not executed")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let checked = try validatedExecutable(executable, assetName: release.assetName)
        guard checked.version == release.version else {
            throw WatchthroughFailure(.readiness, "Downloaded tool did not report its expected release version")
        }
        let active = root.appendingPathComponent("active.json")
        if PathSafety.entryType(at: active) != nil { try requireRegular(active) }
        let receipt = Receipt(version: release.version, sha256: release.sha256, sizeBytes: release.size,
            downloadedAt: ISO8601Clock.now(), upstreamRelease: "https://github.com/yt-dlp/yt-dlp/releases/tag/\(release.version)", assetName: release.assetName)
        try StableJSON.write(receipt, to: staging.appendingPathComponent("receipt.json"))
        // An asset switch or republished release must not replace the bytes
        // referenced by active.json before its atomic publication succeeds.
        let destination = packageDirectory(in: root, version: release.version,
            assetName: release.assetName, sha256: release.sha256)
        if PathSafety.entryType(at: destination) != nil {
            try validateOwnedPackageDirectory(destination, release: release)
            if (try? verifiedTool(in: destination, receipt: receipt)) != nil {
                // Keep a healthy immutable package in place, including across
                // interrupted retries of the same exact update.
                try publishActive(receipt, active)
                return
            }
            let preserved = root.appendingPathComponent(destination.lastPathComponent + ".replaced-\(UUID().uuidString.lowercased())")
            try FileManager.default.moveItem(at: destination, to: preserved)
            progress("Preserved the replaced downloader at \(preserved.path)")
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        try publishActive(receipt, active)
    }

    private static func packageDirectory(in root: URL, version: String, assetName: String, sha256: String) -> URL {
        root.appendingPathComponent("yt-dlp-\(version)-\(assetName)-\(sha256)", isDirectory: true)
    }

    private static func validateOwnedPackageDirectory(_ directory: URL, release: Release) throws {
        try requireDirectory(directory)
        let receiptURL = directory.appendingPathComponent("receipt.json")
        try requireRegular(receiptURL)
        let receipt = try StableJSON.decode(Receipt.self, from: receiptURL)
        try validateReceipt(receipt)
        guard receipt.version == release.version, receipt.assetName == release.assetName,
              receipt.sha256 == release.sha256, receipt.sizeBytes == release.size else {
            throw WatchthroughFailure(.readiness, "Existing downloader directory has a different owner; no files were replaced")
        }
    }

    private static func validatedExecutable(_ path: URL, assetName: String = "yt-dlp_macos") throws -> Downloader {
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
            throw WatchthroughFailure(.readiness, "YouTube downloader is not executable: \(path.path)")
        }
        var executable = path
        var prefix: [String] = []
        if assetName == "yt-dlp" {
            guard let python = pythonRuntime() else {
                throw WatchthroughFailure(.readiness, "The managed zipimport downloader needs existing CPython >=3.10; restore that runtime or use --update-downloader to select the standalone package")
            }
            executable = python
            prefix = ["-I", path.path]
        }
        let version = try Tooling.version(of: executable.path, arguments: prefix + ["--ignore-config", "--no-plugin-dirs", "--version"], timeout: 15)
        guard validReleaseVersion(version),
              version.compare(minimumDownloaderVersion, options: .numeric) != .orderedAscending else {
            throw WatchthroughFailure(.readiness,
                "YouTube downloader \(version) predates the tested client fixes (\(minimumDownloaderVersion)). Retry acquire with --update-downloader, or update your explicit downloader and its matching EJS component.")
        }
        return Downloader(path: executable, version: version, arguments: prefix, artifact: path, assetName: assetName)
    }

    static func pythonRuntime() -> URL? {
        for name in ["python3", "python3.14", "python3.13", "python3.12", "python3.11", "python3.10"] {
            guard let path = Tooling.find(name),
                  let version = try? Tooling.version(of: path.path, arguments: ["-I", "-c",
                    "import sys; print(sys.implementation.name + ' ' + '.'.join(map(str, sys.version_info[:3])))"], timeout: 5),
                  version.hasPrefix("cpython "), let parts = semanticVersion(version),
                  !parts.lexicographicallyPrecedes([3, 10, 0]) else { continue }
            return path
        }
        return nil
    }

    private static func fetch(_ url: URL, maximumBytes: Int64) throws -> Data {
        try ProcessRunner.run("/usr/bin/curl", arguments: curlArguments(url, maximumBytes: maximumBytes), timeout: 45)
            .requireSuccess("could not fetch official downloader metadata").stdoutData
    }

    private static func download(_ url: URL, to destination: URL, maximumBytes: Int64) throws {
        _ = try ProcessRunner.run("/usr/bin/curl",
            arguments: curlArguments(url, maximumBytes: maximumBytes) + ["--max-time", "180", "--output", destination.path], timeout: 185)
            .requireSuccess("could not download official YouTube tool")
    }

    private static func curlArguments(_ url: URL, maximumBytes: Int64) -> [String] {
        ["--disable", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
         "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "40",
         "--max-filesize", String(maximumBytes), "--user-agent", "watchthrough/\(WatchthroughVersion.current)", url.absoluteString]
    }

    private static func validateReceipt(_ receipt: Receipt) throws {
        guard receipt.schema == "watchthrough.youtube-tool.v1", validReleaseVersion(receipt.version),
              ["yt-dlp", "yt-dlp_macos"].contains(receipt.assetName),
              validDigest(receipt.sha256), (1...134_217_728).contains(receipt.sizeBytes),
              receipt.upstreamRelease == "https://github.com/yt-dlp/yt-dlp/releases/tag/\(receipt.version)" else {
            throw WatchthroughFailure(.readiness, "Managed YouTube downloader receipt is invalid")
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        guard PathSafety.entryType(at: url) == .typeDirectory, !PathSafety.isSymbolicLink(url) else {
            throw WatchthroughFailure(.readiness, "YouTube tools directory is missing or unsafe: \(url.path)")
        }
    }

    private static func requireRegular(_ url: URL) throws {
        guard PathSafety.entryType(at: url) == .typeRegular, !PathSafety.isSymbolicLink(url) else {
            throw WatchthroughFailure(.readiness, "YouTube tool file is missing or unsafe: \(url.path)")
        }
    }

    private static func validReleaseVersion(_ version: String) -> Bool {
        version.range(of: #"^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func semanticVersion(_ text: String) -> [Int]? {
        guard let range = text.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    private static func progress(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
