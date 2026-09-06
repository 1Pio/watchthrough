import Foundation
import XCTest
@testable import WatchthroughCore

final class AcquisitionTests: XCTestCase {
    private var root: URL!
    private var tools: YouTubeToolchain!
    private var request: [String: Any]!
    private var ffmpeg: URL!

    override func setUpWithError() throws {
        guard let ffmpeg = Tooling.find("ffmpeg"), let ffprobe = Tooling.find("ffprobe"),
              let python = Tooling.find("python3") else { throw XCTSkip("FFmpeg, FFprobe and Python are needed") }
        self.ffmpeg = ffmpeg
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-acquire-tests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let downloader = root.appendingPathComponent("fake-downloader")
        let script = """
        #!\(python.path)
        import json, pathlib, shutil, sys
        root = pathlib.Path(__file__).parent
        options = json.loads((root / 'request.json').read_text())
        with (root / 'calls.jsonl').open('a') as calls:
            calls.write(json.dumps({'argv':sys.argv[1:], 'cwd':str(pathlib.Path.cwd())}) + '\\n')
        call_count = len((root / 'calls.jsonl').read_text().splitlines())
        destination = pathlib.Path.cwd() / 'source.mkv'
        partial = pathlib.Path.cwd() / 'source.fv.webm.part'
        if options.get('mode') == 'fail-once' and call_count == 1:
            partial.write_bytes(b'owned partial transfer')
            (pathlib.Path.cwd() / 'source.fv.webm.part-Frag3.part').write_bytes(b'partially transferred fragment')
            (pathlib.Path.cwd() / 'source.fv.webm.ytdl').write_text('{"downloader":{"current_fragment":{"index":2}}}')
            print('ERROR: HTTP Error 403: Forbidden https://signed.invalid/?secret=DO-NOT-PERSIST', file=sys.stderr)
            sys.exit(1)
        if partial.exists():
            (root / 'resume-observed').write_text(str(partial))
        if options.get('mode') != 'missing':
            if options.get('mode') == 'symlink':
                destination.symlink_to(root / 'fixture.mkv')
            else:
                shutil.copyfile(root / 'fixture.mkv', destination)
        metadata = options['metadata']
        metadata['filepath'] = str(destination) if options.get('mode') != 'escape' else str(root / 'fixture.mkv')
        # Real yt-dlp emits forced progress on stdout even with --print.
        print('watchthrough-progress:1048576:2097152:524288:2')
        print('[download] unrelated output https://signed.invalid/?secret=DO-NOT-PERSIST')
        print('watchthrough-metadata:' + json.dumps(metadata))
        if options.get('mode') == 'multiple':
            print('watchthrough-metadata:' + json.dumps(metadata))
        """
        try Data(script.utf8).write(to: downloader)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloader.path)
        tools = YouTubeToolchain(downloader: downloader, downloaderVersion: "2026.08.19", javascriptName: "node",
            javascript: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: ffmpeg, ffprobe: ffprobe)
        request = ["metadata": [
            "id": "_6jZlnRsXXQ", "_type": "video", "title": "A source title", "channel": "Channel", "channel_id": "UCfixture",
            "uploader": "Creator", "upload_date": "20260819", "duration": 4.0, "description": "The complete creator description.\nhttps://example.com/resource",
            "is_live": false, "live_status": "not_live", "format_id": "v+a", "url": "https://signed.invalid/?secret=DO-NOT-PERSIST",
            "http_headers": ["Cookie": "DO-NOT-PERSIST"], "formats": [["url": "https://signed.invalid/?secret=DO-NOT-PERSIST"]],
            "requested_formats": [
                ["format_id": "v", "ext": "webm", "vcodec": "ffv1", "acodec": "none", "width": 256, "height": 144, "fps": 25.0,
                 "protocol": "https", "url": "https://signed.invalid/?secret=DO-NOT-PERSIST"],
                ["format_id": "a", "ext": "m4a", "vcodec": "none", "acodec": "flac", "language": "en", "protocol": "https"],
            ], "chapters": [["start_time": 0.0, "end_time": 4.0, "title": "Whole video"]]
        ]]
        try writeRequest()
    }

    // Fixtures remain in the system temporary directory. Tests do not permanently
    // delete media or user-owned acquisition paths.

    func testCanonicalURLAcceptsOnlyOneYouTubeVideo() throws {
        for url in ["https://youtu.be/_6jZlnRsXXQ?t=10", "https://www.youtube.com/watch?v=_6jZlnRsXXQ&list=ignored", "https://m.youtube.com/shorts/_6jZlnRsXXQ", "https://www.youtube-nocookie.com/embed/_6jZlnRsXXQ"] {
            let value = try YouTubeAcquisition.canonicalVideo(url)
            XCTAssertEqual(value.id, "_6jZlnRsXXQ")
            XCTAssertEqual(value.url, "https://www.youtube.com/watch?v=_6jZlnRsXXQ")
        }
        for url in ["https://youtube.com.evil.invalid/watch?v=_6jZlnRsXXQ", "file:///etc/passwd", "https://youtube.com/playlist?list=xx", "https://youtube.com/watch?v=_6jZlnRsXXQ&v=zzzzzzzzzzz", "https://name:secret@youtube.com/watch?v=_6jZlnRsXXQ", "https://youtube.com/watch?v=bad", "https://youtube.com:444/watch?v=_6jZlnRsXXQ"] {
            XCTAssertThrowsError(try YouTubeAcquisition.canonicalVideo(url), url)
        }
    }

    func testAcquisitionValidatesMediaKeepsUsefulProvenanceAndReusesWithoutTools() throws {
        try makeFixture()
        let result = try acquire()
        XCTAssertEqual(result.command, "acquire")
        XCTAssertEqual(result.reused, false)
        XCTAssertEqual(result.details["nativeFPS"], "25.0")
        XCTAssertEqual(result.details["audioLanguage"], "en")
        XCTAssertEqual(result.artifacts["source"], bundle.appendingPathComponent("download/source.mkv").path)
        let contextData = try Data(contentsOf: bundle.appendingPathComponent("source.context.json"))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: contextData) as? [String: Any])
        XCTAssertEqual(context["title"] as? String, "A source title")
        XCTAssertEqual(context["channel"] as? String, "Channel")
        XCTAssertEqual((context["selectedFormats"] as? [[String: Any]])?.count, 2)
        let description = try String(contentsOf: bundle.appendingPathComponent("source.description"))
        XCTAssertTrue(description.contains("https://example.com/resource"))
        for path in ["acquisition.json", "source.context.json", "source.description"] {
            XCTAssertFalse(try String(contentsOf: bundle.appendingPathComponent(path)).contains("DO-NOT-PERSIST"))
        }
        let call = try calls().first!
        let argv = try XCTUnwrap(call["argv"] as? [String])
        XCTAssertEqual(argument("--format-sort", in: argv), "res,fps,lang,proto")
        XCTAssertEqual(argument("--format", in: argv), "bv[height<=1080]+ba/b[height<=1080]")
        XCTAssertEqual(argument("--js-runtimes", in: argv), "node:/usr/bin/false")
        for flag in ["--format-sort-force", "--abort-on-unavailable-fragments", "--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-playlist", "--continue", "--no-overwrites"] { XCTAssertTrue(argv.contains(flag), flag) }
        XCTAssertEqual(argument("--print", in: argv), "after_move:watchthrough-metadata:%()j")
        XCTAssertFalse(argv.contains("--cookies-from-browser"))
        var unavailable = tools!
        unavailable.downloader = root.appendingPathComponent("missing-downloader")
        unavailable.ffmpeg = root.appendingPathComponent("missing-ffmpeg")
        unavailable.ffprobe = root.appendingPathComponent("missing-ffprobe")
        let reused = try YouTubeAcquisition.acquire(options, tools: unavailable)
        XCTAssertEqual(reused.reused, true)
        XCTAssertEqual(try calls().count, 1)
    }

    func testFailedDownloadPreservesOwnedPartAndResumesSameDirectory() throws {
        try makeFixture()
        request["mode"] = "fail-once"
        try writeRequest()
        XCTAssertThrowsError(try acquire()) { error in
            XCTAssertTrue(String(describing: error).contains("403"))
            XCTAssertFalse(String(describing: error).contains("DO-NOT-PERSIST"))
        }
        let partial = bundle.appendingPathComponent("download/source.fv.webm.part")
        XCTAssertEqual(try String(contentsOf: partial), "owned partial transfer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("download/source.fv.webm.part-Frag3.part").path))
        let failedReceipt = try receipt()
        XCTAssertEqual(failedReceipt["state"] as? String, "incomplete")
        XCTAssertEqual(failedReceipt["lastFailure"] as? String, "upstream-forbidden")
        XCTAssertNil(failedReceipt["source"])
        XCTAssertEqual(try acquire().reused, false)
        XCTAssertEqual(URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("resume-observed"))).standardizedFileURL.resolvingSymlinksInPath(), partial.standardizedFileURL.resolvingSymlinksInPath())
        let calls = try calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["cwd"] as? String, calls[1]["cwd"] as? String)
        XCTAssertEqual(try receipt()["attempts"] as? Int, 2)
    }

    func testDifferentVideoOrConfigurationCannotReuseOrOverwriteBundle() throws {
        try makeFixture()
        _ = try acquire()
        var changed = options
        changed.height = 720
        XCTAssertThrowsError(try YouTubeAcquisition.acquire(changed, tools: tools))
        changed = options
        changed.url = "https://youtu.be/abcdefghijk"
        XCTAssertThrowsError(try YouTubeAcquisition.acquire(changed, tools: tools))
        XCTAssertEqual(try calls().count, 1)
        XCTAssertEqual(try receipt()["state"] as? String, "ready")
    }

    func testUnownedFilesAndSymlinkedOutputsAreRefusedBeforeToolStartup() throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let unrelated = bundle.appendingPathComponent("notes.txt")
        try Data("do not alter".utf8).write(to: unrelated)
        XCTAssertThrowsError(try acquire())
        XCTAssertEqual(try String(contentsOf: unrelated), "do not alter")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: bundle)
        var linkedOptions = options
        linkedOptions.output = linked
        XCTAssertThrowsError(try YouTubeAcquisition.acquire(linkedOptions, tools: tools))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    }

    func testUnrelatedNotesAndDefaultPreparedAnalysisDoNotPreventWarmReuse() throws {
        try makeFixture()
        _ = try acquire()
        let unrelated = bundle.appendingPathComponent("download/notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        try Data("Authored source note".utf8).write(to: bundle.appendingPathComponent("source-note.md"))
        let source = bundle.appendingPathComponent("download/source.mkv")
        XCTAssertEqual(try WatchthroughApplication().run(arguments: ["--json", "prepare", source.path, "--defer-transcript"]), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + ".watchthrough/manifest.json"))
        var unavailable = tools!
        unavailable.downloader = root.appendingPathComponent("missing-downloader")
        XCTAssertEqual(try YouTubeAcquisition.acquire(options, tools: unavailable).reused, true)
        XCTAssertEqual(try calls().count, 1)
        XCTAssertEqual(try String(contentsOf: unrelated), "keep me")
    }

    func testContextTamperingAndMissingDescriptionPreventWarmReuse() throws {
        try makeFixture()
        _ = try acquire()
        let context = bundle.appendingPathComponent("source.context.json")
        let original = try Data(contentsOf: context)
        try Data("{}".utf8).write(to: context)
        XCTAssertThrowsError(try acquire())
        try original.write(to: context)
        try FileManager.default.moveItem(at: bundle.appendingPathComponent("source.description"), to: root.appendingPathComponent("saved-description"))
        XCTAssertThrowsError(try acquire())
        XCTAssertEqual(try calls().count, 1)
    }

    func testChangedSourceBytesPreventWarmReuseButTouchPreservesIdentity() throws {
        try makeFixture()
        _ = try acquire()
        let source = bundle.appendingPathComponent("download/source.mkv")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: source.path)
        XCTAssertEqual(try acquire().reused, true)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()
        XCTAssertThrowsError(try acquire())
        XCTAssertEqual(try calls().count, 1)
    }

    func testFalseSuccessWithMissingMediaNeverMarksReady() throws {
        request["mode"] = "missing"
        try writeRequest()
        XCTAssertThrowsError(try acquire())
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
        XCTAssertNil(try receipt()["source"])
    }

    func testMultipleCompletedMetadataRecordsNeverMarkOneBundleReady() throws {
        try makeFixture()
        request["mode"] = "multiple"
        try writeRequest()
        XCTAssertThrowsError(try acquire()) { error in
            XCTAssertTrue(String(describing: error).contains("multiple completed videos"))
        }
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
        XCTAssertNil(try receipt()["source"])
    }

    func testFalseSuccessWithWrongNativeFrameRateNeverMarksReady() throws {
        try makeFixture(fps: 30)
        XCTAssertThrowsError(try acquire()) { error in XCTAssertTrue(String(describing: error).contains("frame-rate")) }
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
    }

    func testFalseSuccessWithMissingAudioNeverMarksReady() throws {
        try makeFixture(audio: false)
        XCTAssertThrowsError(try acquire()) { error in XCTAssertTrue(String(describing: error).contains("audio")) }
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
    }

    func testTruncatedContainerWithPlausibleHeaderCannotBecomeReady() throws {
        try makeFixture(duration: 8)
        var metadata = request["metadata"] as! [String: Any]
        metadata["duration"] = 8.0
        request["metadata"] = metadata
        try writeRequest()
        let fixture = root.appendingPathComponent("fixture.mkv")
        let data = try Data(contentsOf: fixture)
        try data.prefix(data.count / 2).write(to: fixture)
        XCTAssertThrowsError(try acquire())
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
        XCTAssertNil(try receipt()["source"])
    }

    func testFinalPathEscapeAndDownloaderCreatedSymlinkAreRejected() throws {
        try makeFixture()
        request["mode"] = "escape"
        try writeRequest()
        XCTAssertThrowsError(try acquire()) { error in XCTAssertTrue(String(describing: error).contains("unexpected final media path")) }
        var other = options
        other.output = root.appendingPathComponent("second-bundle")
        request["mode"] = "symlink"
        try writeRequest()
        XCTAssertThrowsError(try YouTubeAcquisition.acquire(other, tools: tools)) { error in XCTAssertTrue(String(describing: error).contains("unsafe")) }
    }

    func testLiveMetadataIsRejectedEvenWhenDownloaderExitsSuccessfully() throws {
        try makeFixture()
        var metadata = request["metadata"] as! [String: Any]
        metadata["is_live"] = true
        request["metadata"] = metadata
        try writeRequest()
        XCTAssertThrowsError(try acquire())
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
    }

    func testUnknownHLSAudioCodecStillRequiresAndValidatesAudio() throws {
        try makeFixture()
        var metadata = request["metadata"] as! [String: Any]
        var formats = metadata["requested_formats"] as! [[String: Any]]
        formats[1]["acodec"] = NSNull()
        formats[1]["protocol"] = "m3u8_native"
        formats[1]["format_id"] = "233"
        metadata["requested_formats"] = formats
        request["metadata"] = metadata
        try writeRequest()
        let result = try acquire()
        XCTAssertEqual(result.details["audioCodec"], "flac")
        XCTAssertEqual(result.details["audioLanguage"], "en")
        XCTAssertTrue(result.warnings.contains { $0.contains("did not report the selected audio codec") })
    }

    func testUnknownHLSAudioCodecCannotHideMissingAudio() throws {
        try makeFixture(audio: false)
        var metadata = request["metadata"] as! [String: Any]
        var formats = metadata["requested_formats"] as! [[String: Any]]
        formats[1]["acodec"] = NSNull()
        formats[1]["protocol"] = "m3u8_native"
        metadata["requested_formats"] = formats
        request["metadata"] = metadata
        try writeRequest()
        XCTAssertThrowsError(try acquire()) { error in XCTAssertTrue(String(describing: error).contains("audio")) }
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
    }

    func testKnownAudioCodecMismatchIsRejected() throws {
        try makeFixture()
        var metadata = request["metadata"] as! [String: Any]
        var formats = metadata["requested_formats"] as! [[String: Any]]
        formats[1]["acodec"] = "opus"
        metadata["requested_formats"] = formats
        request["metadata"] = metadata
        try writeRequest()
        XCTAssertThrowsError(try acquire()) { error in XCTAssertTrue(String(describing: error).contains("audio")) }
        XCTAssertEqual(try receipt()["state"] as? String, "incomplete")
    }

    func testExplicitUpdateIsHonoredOnWarmSourceButNormalReuseSkipsResolver() throws {
        try makeFixture()
        _ = try acquire()
        var resolutionCount = 0
        let resolve = { () throws -> YouTubeToolchain in
            resolutionCount += 1
            return self.tools
        }
        XCTAssertEqual(try YouTubeAcquisition.acquire(options, resolveTools: resolve).reused, true)
        XCTAssertEqual(resolutionCount, 0)
        var updating = options
        updating.updateDownloader = true
        XCTAssertEqual(try YouTubeAcquisition.acquire(updating, resolveTools: resolve).reused, true)
        XCTAssertEqual(resolutionCount, 1)
        XCTAssertEqual(try calls().count, 1)
    }

    func testAnotherAcquisitionOwnerPreventsDownloaderStartup() throws {
        let lock = try ExclusiveFileLock.acquire(at: root.appendingPathComponent(".bundle.acquire.lock"))
        defer { lock.unlock() }
        XCTAssertThrowsError(try acquire())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    }

    private var bundle: URL { root.appendingPathComponent("bundle", isDirectory: true) }
    private var options: AcquireOptions { AcquireOptions(url: "https://youtu.be/_6jZlnRsXXQ?t=10", output: bundle) }
    private func acquire() throws -> CommandResult { try YouTubeAcquisition.acquire(options, tools: tools) }
    private func writeRequest() throws { try JSONSerialization.data(withJSONObject: request!).write(to: root.appendingPathComponent("request.json")) }
    private func receipt() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("acquisition.json"))) as? [String: Any]) }
    private func calls() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("calls.jsonl")).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    private func argument(_ flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }
    private func makeFixture(duration: Int = 4, fps: Int = 25, audio: Bool = true) throws {
        var arguments = ["-v", "error", "-nostdin", "-threads", "2", "-filter_threads", "1",
            "-f", "lavfi", "-i", "testsrc2=size=256x144:rate=\(fps):duration=\(duration)"]
        if audio { arguments += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(duration)"] }
        arguments += ["-c:v", "ffv1", "-threads", "2"]
        if audio { arguments += ["-c:a", "flac"] }
        arguments += [root.appendingPathComponent("fixture.mkv").path]
        _ = try ProcessRunner.run(ffmpeg.path, arguments: arguments, timeout: 30).requireSuccess("could not create acquisition fixture")
    }
}
