import CryptoKit
import XCTest
@testable import WatchthroughCore

final class YouTubeToolsTests: XCTestCase {
    func testReleaseRequiresOfficialBoundedAssetAndMatchingPublishedChecksums() throws {
        let digest = String(repeating: "a", count: 64)
        let data = try releaseJSON(digest: "sha256:" + digest)
        let release = try YouTubeTools.parseRelease(data)
        XCTAssertEqual(release.version, "2026.08.19")
        XCTAssertEqual(release.sha256, digest)
        XCTAssertNoThrow(try YouTubeTools.verifyChecksumList(Data("\(digest)  yt-dlp_macos\n".utf8), release: release))
        XCTAssertThrowsError(try YouTubeTools.verifyChecksumList(Data("\(digest)  yt-dlp\n".utf8), release: release))
        XCTAssertThrowsError(try YouTubeTools.verifyChecksumList(Data("\(digest)  yt-dlp_macos\n\(digest)  yt-dlp_macos\n".utf8), release: release))
        XCTAssertThrowsError(try YouTubeTools.parseRelease(releaseJSON(digest: "sha256:wrong")))
        XCTAssertThrowsError(try YouTubeTools.parseRelease(releaseJSON(digest: "sha256:" + digest,
            assetURL: "https://example.com/yt-dlp_macos")))
        XCTAssertThrowsError(try YouTubeTools.parseRelease(releaseJSON(digest: "sha256:" + digest, size: 1_000_000_000)))
        XCTAssertThrowsError(try YouTubeTools.parseRelease(releaseJSON(digest: "sha256:" + digest, prerelease: true)))
    }

    func testFailedUpdateCannotExecuteBadBytesOrReplaceWorkingVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try stagedTool(root: root, version: "2026.08.19")
        try YouTubeTools.activateDownloadedTool(staging: first.directory, release: first.release, root: root)
        let active = root.appendingPathComponent("active.json")
        let originalReceipt = try Data(contentsOf: active)
        let existing = try XCTUnwrap(YouTubeTools.managedDownloader(at: root))
        let originalBytes = try Data(contentsOf: existing.path)

        let marker = root.appendingPathComponent("must-not-execute")
        let next = try stagedTool(root: root, version: "2026.08.20", marker: marker)
        var wrongDigest = next.release
        wrongDigest.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try YouTubeTools.activateDownloadedTool(staging: next.directory, release: wrongDigest, root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: active), originalReceipt)
        XCTAssertEqual(try Data(contentsOf: existing.path), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.directory.path), "failed update remains inspectable")
    }

    func testOfficialZipPackageRunsThroughExistingIsolatedPythonAndSurvivesPromotion() throws {
        let python = try XCTUnwrap(YouTubeTools.pythonRuntime(), "release verification requires existing CPython >=3.10")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let next = try stagedZipTool(root: root, python: python)
        let digest = next.release.sha256
        let release = next.release
        XCTAssertNoThrow(try YouTubeTools.verifyChecksumList(Data("\(digest)  yt-dlp\n".utf8), release: release))
        XCTAssertThrowsError(try YouTubeTools.verifyChecksumList(Data("\(digest)  yt-dlp_macos\n".utf8), release: release))
        try YouTubeTools.activateDownloadedTool(staging: next.directory, release: release, root: root)
        let resolved = try XCTUnwrap(YouTubeTools.managedDownloader(at: root))
        XCTAssertEqual(resolved.path, python)
        XCTAssertEqual(resolved.assetName, "yt-dlp")
        XCTAssertEqual(resolved.arguments, ["-I", resolved.artifact.path])
        XCTAssertEqual(try FileSHA256.hexDigest(of: resolved.artifact), digest)
        let result = try ProcessRunner.run(resolved.path.path,
            arguments: resolved.arguments + ["--ignore-config", "--no-plugin-dirs", "https://www.youtube.com/watch?v=_6jZlnRsXXQ"])
            .requireSuccess("execute promoted zipimport tool")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "--ignore-config|--no-plugin-dirs|https://www.youtube.com/watch?v=_6jZlnRsXXQ")
    }

    func testFailedActivePublicationDuringSameReleaseAssetSwitchKeepsPriorToolUsable() throws {
        let python = try XCTUnwrap(YouTubeTools.pythonRuntime(), "release verification requires existing CPython >=3.10")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try stagedTool(root: root, version: "2026.08.19")
        try YouTubeTools.activateDownloadedTool(staging: first.directory, release: first.release, root: root)
        let old = try XCTUnwrap(YouTubeTools.managedDownloader(at: root))
        let active = root.appendingPathComponent("active.json")
        let originalReceipt = try Data(contentsOf: active)
        let next = try stagedZipTool(root: root, python: python)

        XCTAssertThrowsError(try YouTubeTools.activateDownloadedTool(staging: next.directory,
            release: next.release, root: root, publishActive: { _, _ in
                XCTAssertEqual(try YouTubeTools.managedDownloader(at: root)?.artifact, old.artifact)
                throw CocoaError(.fileWriteUnknown)
            }))
        XCTAssertEqual(try Data(contentsOf: active), originalReceipt)
        XCTAssertEqual(try YouTubeTools.managedDownloader(at: root)?.artifact, old.artifact)
        XCTAssertEqual(try FileSHA256.hexDigest(of: old.artifact), first.release.sha256)
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("yt-dlp-") }
        XCTAssertEqual(packages.count, 2)
        let promoted = try XCTUnwrap(packages.first { $0.lastPathComponent != old.artifact.deletingLastPathComponent().lastPathComponent })
        let promotedArtifact = promoted.appendingPathComponent("yt-dlp")
        XCTAssertEqual(try FileSHA256.hexDigest(of: promotedArtifact), next.release.sha256)

        // A repeated update adopts the valid immutable package without moving
        // its directory, while keeping the previous asset available.
        let retry = root.appendingPathComponent(".download-retry")
        try FileManager.default.createDirectory(at: retry, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: promotedArtifact, to: retry.appendingPathComponent("yt-dlp"))
        try YouTubeTools.activateDownloadedTool(staging: retry, release: next.release, root: root)
        let current = try XCTUnwrap(YouTubeTools.managedDownloader(at: root))
        XCTAssertEqual(current.assetName, "yt-dlp")
        XCTAssertEqual(current.artifact.deletingLastPathComponent().lastPathComponent, promoted.lastPathComponent)
        XCTAssertEqual(try FileSHA256.hexDigest(of: old.artifact), first.release.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retry.path), "redundant verified staging remains inspectable")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("yt-dlp-") }.count, 2)
    }

    func testVerifiedUpdatePromotesNewVersionAndRetainsPreviousExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try stagedTool(root: root, version: "2026.08.19")
        try YouTubeTools.activateDownloadedTool(staging: first.directory, release: first.release, root: root)
        let old = try XCTUnwrap(YouTubeTools.managedDownloader(at: root))
        let oldHash = try FileSHA256.hexDigest(of: old.path)

        let next = try stagedTool(root: root, version: "2026.08.20")
        try YouTubeTools.activateDownloadedTool(staging: next.directory, release: next.release, root: root)
        let current = try XCTUnwrap(YouTubeTools.managedDownloader(at: root))
        XCTAssertEqual(current.version, "2026.08.20")
        XCTAssertEqual(current.path.lastPathComponent, "yt-dlp")
        XCTAssertEqual(try FileSHA256.hexDigest(of: old.path), oldHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.directory.path))
    }

    func testManagedDownloaderRejectsMutationBeforeExecutingIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try stagedTool(root: root, version: "2026.08.19")
        try YouTubeTools.activateDownloadedTool(staging: first.directory, release: first.release, root: root)
        let installed = try XCTUnwrap(YouTubeTools.managedDownloader(at: root)).path
        let marker = root.appendingPathComponent("must-not-execute")
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".utf8).write(to: installed)
        XCTAssertThrowsError(try YouTubeTools.managedDownloader(at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testManagedPointerSymlinkIsNotFollowed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("user-data.json")
        try Data("preserve".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("active.json"), withDestinationURL: destination)
        XCTAssertThrowsError(try YouTubeTools.managedDownloader(at: root))
        XCTAssertEqual(try String(contentsOf: destination), "preserve")
    }

    func testSameReleaseRepairPreservesCorruptCopyWithoutExecutingIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try stagedTool(root: root, version: "2026.08.19")
        try YouTubeTools.activateDownloadedTool(staging: first.directory, release: first.release, root: root)
        let installed = try XCTUnwrap(YouTubeTools.managedDownloader(at: root)).path
        let marker = root.appendingPathComponent("must-not-execute")
        let corruptBytes = Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".utf8)
        try corruptBytes.write(to: installed)

        let replacement = try stagedTool(root: root, version: "2026.08.19")
        try YouTubeTools.activateDownloadedTool(staging: replacement.directory, release: replacement.release, root: root)
        XCTAssertEqual(try YouTubeTools.managedDownloader(at: root)?.version, "2026.08.19")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(installed.deletingLastPathComponent().lastPathComponent + ".replaced-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first).appendingPathComponent("yt-dlp")), corruptBytes)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stagedTool(root: URL, version: String, marker: URL? = nil) throws -> (directory: URL, release: YouTubeTools.Release) {
        let directory = root.appendingPathComponent(".download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let touch = marker.map { "/usr/bin/touch '\($0.path)'\n" } ?? ""
        let data = Data("#!/bin/sh\n\(touch)printf '%s\\n' '\(version)'\n".utf8)
        try data.write(to: directory.appendingPathComponent("yt-dlp"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/"
        return (directory, YouTubeTools.Release(version: version, sha256: digest, size: Int64(data.count),
            downloadURL: URL(string: base + "yt-dlp_macos")!, checksumURL: URL(string: base + "SHA2-256SUMS")!))
    }

    private func stagedZipTool(root: URL, python: URL) throws -> (directory: URL, release: YouTubeTools.Release) {
        let directory = root.appendingPathComponent(".download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let archive = directory.appendingPathComponent("yt-dlp")
        _ = try ProcessRunner.run(python.path, arguments: ["-I", "-c", """
        import sys, zipfile
        with zipfile.ZipFile(sys.argv[1], 'w') as archive:
            archive.writestr('__main__.py', "import sys; assert sys.flags.isolated; print('2026.08.19' if '--version' in sys.argv else '|'.join(sys.argv[1:]))")
        """, archive.path]).requireSuccess("create zipimport fixture")
        let digest = try FileSHA256.hexDigest(of: archive)
        let size = Int64(try Data(contentsOf: archive).count)
        let release = try YouTubeTools.parseRelease(releaseJSON(digest: "sha256:" + digest,
            assetURL: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp",
            size: size, assetName: "yt-dlp"), assetName: "yt-dlp")
        return (directory, release)
    }

    private func releaseJSON(digest: String, assetURL: String = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos",
        size: Int64 = 37_146_048, prerelease: Bool = false, assetName: String = "yt-dlp_macos") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": "2026.08.19", "draft": false, "prerelease": prerelease,
            "assets": [["name": assetName, "size": size, "digest": digest, "browser_download_url": assetURL]]])
    }
}
