import Foundation

/// The stable acquisition boundary owns local state and evidence. Extraction,
/// challenge solving, transport retries and copy-only remuxing stay in yt-dlp.
public enum YouTubeAcquisition {
    static let formatSort = "res,fps,lang,proto"
    private static let policyVersion = "youtube-native-v1"
    private static let sourcePath = "download/source.mkv"

    public static func acquire(_ options: AcquireOptions) throws -> CommandResult {
        try acquire(options, resolveTools: { try YouTubeTools.resolve(update: options.updateDownloader) })
    }

    static func acquire(_ options: AcquireOptions, tools: YouTubeToolchain) throws -> CommandResult {
        try acquire(options, resolveTools: { tools })
    }

    static func canonicalVideo(_ input: String) throws -> (id: String, url: String) {
        guard let parts = URLComponents(string: input),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else {
            throw WatchthroughFailure(.usage, "acquire needs a public YouTube video URL")
        }
        let path = parts.path.split(separator: "/").map(String.init)
        var id: String?
        if ["youtu.be", "www.youtu.be"].contains(host), path.count == 1 {
            id = path[0]
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if path == ["watch"] {
                let values = (parts.queryItems ?? []).filter { $0.name == "v" }
                if values.count == 1 { id = values[0].value }
            } else if path.count == 2, ["shorts", "embed", "live"].contains(path[0]) {
                id = path[1]
            }
        } else if ["youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host),
                  path.count == 2, path[0] == "embed" {
            id = path[1]
        }
        guard let id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            throw WatchthroughFailure(.usage, "acquire needs one YouTube video, not a playlist, channel, or another host")
        }
        return (id, "https://www.youtube.com/watch?v=\(id)")
    }

    static func arguments(url: String, height: Int, tools: YouTubeToolchain) -> [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-remote-components",
         "--no-js-runtimes", "--js-runtimes", "\(tools.javascriptName):\(tools.javascript.path)",
         "--no-playlist", "--no-wait-for-video", "--no-mark-watched", "--no-live-from-start",
         "--match-filters", "!is_live & live_status !=? is_live & live_status !=? is_upcoming",
         "--format", selector(height), "--format-sort-force", "--format-sort", formatSort,
         "--merge-output-format", "mkv", "--remux-video", "mkv", "--ffmpeg-location", tools.ffmpeg.path,
         "--concurrent-fragments", "1", "--retries", "3", "--fragment-retries", "3",
         "--extractor-retries", "2", "--file-access-retries", "2", "--socket-timeout", "20",
         "--abort-on-unavailable-fragments", "--continue", "--no-overwrites", "--no-cache-dir",
         "--no-write-info-json", "--no-write-comments", "--no-write-subs", "--no-write-auto-subs",
         "--no-write-thumbnail", "--no-write-description", "--print", "after_move:watchthrough-metadata:%()j", "--no-simulate",
         "--newline", "--progress", "--progress-delta", "1",
         "--progress-template", "download:watchthrough-progress:%(progress.downloaded_bytes)s:%(progress.total_bytes,progress.total_bytes_estimate)s:%(progress.speed)s:%(progress.eta)s",
         "--output", "source.%(ext)s", "--", url]
    }

    private static func selector(_ height: Int) -> String { "bv[height<=\(height)]+ba/b[height<=\(height)]" }

    static func acquire(_ options: AcquireOptions, resolveTools: () throws -> YouTubeToolchain) throws -> CommandResult {
        let started = ProcessInfo.processInfo.systemUptime
        let video = try canonicalVideo(options.url)
        guard (144...4320).contains(options.height) else {
            throw WatchthroughFailure(.usage, "acquisition height must be between 144 and 4320")
        }
        let root = try outputRoot(options.output)
        let lockURL = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).acquire.lock")
        try PathSafety.validateAnalysisLock(lockURL, for: root)
        let lock = try ExclusiveFileLock.acquire(at: lockURL)
        defer { lock.unlock() }
        let configuration = Configuration(height: options.height, format: selector(options.height), sort: formatSort,
            container: "mkv", policy: policyVersion)
        let receiptURL = root.appendingPathComponent("acquisition.json")
        var receipt: Receipt
        if PathSafety.entryType(at: root) != nil {
            try requireDirectory(root)
            if PathSafety.entryType(at: receiptURL) != nil {
                try requireRegular(receiptURL)
                guard let existing = try? StableJSON.decode(Receipt.self, from: receiptURL),
                      existing.schema == "watchthrough.acquisition.v1",
                      ["incomplete", "ready"].contains(existing.state), existing.attempts >= 0,
                      existing.videoID == video.id, existing.canonicalURL == video.url,
                      existing.configuration == configuration else {
                    throw WatchthroughFailure(.usage, "acquisition bundle belongs to a different video/configuration or has an invalid receipt; choose a new output directory")
                }
                receipt = existing
                if receipt.state == "ready" {
                    try verifyReady(&receipt, root: root)
                    if options.updateDownloader { _ = try resolveTools() }
                    try StableJSON.write(receipt, to: receiptURL)
                    return result(receipt, root: root, reused: true, seconds: elapsed(started))
                }
            } else {
                guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
                    throw WatchthroughFailure(.usage, "acquisition output is nonempty and has no owned receipt; choose an empty output directory")
                }
                receipt = Receipt(videoID: video.id, canonicalURL: video.url, configuration: configuration)
                try StableJSON.write(receipt, to: receiptURL)
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            receipt = Receipt(videoID: video.id, canonicalURL: video.url, configuration: configuration)
            try StableJSON.write(receipt, to: receiptURL)
        }
        let download = root.appendingPathComponent("download", isDirectory: true)
        if PathSafety.entryType(at: download) == nil {
            try FileManager.default.createDirectory(at: download, withIntermediateDirectories: false)
        }
        try validateEntries(root)
        let tools = try resolveTools()
        receipt.attempts += 1
        receipt.updatedAt = ISO8601Clock.now()
        receipt.lastFailure = nil
        receipt.downloaderVersion = tools.downloaderVersion
        receipt.javascriptRuntime = tools.javascriptName
        try StableJSON.write(receipt, to: receiptURL)
        let capture = DownloaderCapture()
        progress("Acquiring YouTube \(video.id), at most \(options.height)p; partial transfers resume in the same bundle...")
        let downloadStarted = ProcessInfo.processInfo.systemUptime
        var downloaderSucceeded = false
        do {
            let output = try ProcessRunner.run(tools.downloader.path,
                arguments: tools.downloaderArguments + arguments(url: video.url, height: options.height, tools: tools),
                currentDirectory: download, timeout: 14_400,
                stdoutConsumer: { try capture.stdout($0) }, stderrConsumer: { capture.stderr($0) })
            try capture.finish()
            guard output.succeeded else {
                throw WatchthroughFailure(.operation, capture.failure(timedOut: output.timedOut))
            }
            downloaderSucceeded = true
            try validateEntries(root)
            let metadata = try selectedMetadata(capture.metadata, expectedID: video.id, root: root, height: options.height)
            let source = root.appendingPathComponent(sourcePath)
            try requireRegular(source)
            progress("Validating the downloaded streams and final media packets...")
            let validationStarted = ProcessInfo.processInfo.systemUptime
            let media = try validateMedia(source, metadata: metadata, ffprobe: tools.ffprobe)
            let sourceRecord = try SourceInspector.record(for: source)
            let context = Context(videoID: video.id, canonicalURL: video.url, title: metadata.title,
                channel: metadata.channel, channelID: metadata.channelID, uploader: metadata.uploader,
                uploadDate: metadata.uploadDate, durationSeconds: metadata.duration, chapters: metadata.chapters,
                selectedFormats: metadata.formats, media: media, downloaderVersion: tools.downloaderVersion)
            let contextURL = root.appendingPathComponent("source.context.json")
            let descriptionURL = root.appendingPathComponent("source.description")
            try StableJSON.write(context, to: contextURL)
            try Data((metadata.description + "\n").utf8).write(to: descriptionURL, options: .atomic)
            receipt.source = sourceRecord
            receipt.context = try artifact(contextURL)
            receipt.description = try artifact(descriptionURL)
            receipt.selectedFormats = metadata.formats
            receipt.media = media
            receipt.downloadSeconds = validationStarted - downloadStarted
            receipt.validationSeconds = elapsed(validationStarted)
            receipt.state = "ready"
            receipt.updatedAt = ISO8601Clock.now()
            try validateEntries(root)
            try StableJSON.write(receipt, to: receiptURL)
            return result(receipt, root: root, reused: false, seconds: elapsed(started))
        } catch {
            receipt.state = "incomplete"
            receipt.updatedAt = ISO8601Clock.now()
            // Persist only our bounded diagnostic category, never extractor stderr
            // or raw metadata containing signed delivery URLs and request headers.
            receipt.lastFailure = downloaderSucceeded ? "local-media-validation" : (capture.category ?? "downloader-failed")
            try? StableJSON.write(receipt, to: receiptURL)
            if let failure = error as? WatchthroughFailure { throw failure }
            throw WatchthroughFailure(.operation,
                "Acquisition did not complete. Owned files remain in \(root.path); retry the same command to resume, or inspect the bundle if local validation keeps failing.")
        }
    }

    private static func outputRoot(_ requested: URL) throws -> URL {
        guard requested.isFileURL else { throw WatchthroughFailure(.usage, "acquisition output must be a local directory") }
        let requested = requested.standardizedFileURL
        guard !PathSafety.isSymbolicLink(requested) else {
            throw WatchthroughFailure(.usage, "acquisition output cannot be a symbolic link")
        }
        let root = requested.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(requested.lastPathComponent, isDirectory: true).standardizedFileURL
        guard root.path != "/", !root.lastPathComponent.isEmpty else {
            throw WatchthroughFailure(.usage, "acquisition needs a dedicated output directory")
        }
        if PathSafety.entryType(at: root) != nil { try requireDirectory(root) }
        return root
    }

    private static func validateEntries(_ root: URL) throws {
        try requireDirectory(root)
        for name in ["acquisition.json", "source.context.json", "source.description"] {
            let entry = root.appendingPathComponent(name)
            if PathSafety.entryType(at: entry) != nil { try requireRegular(entry) }
        }
        let download = root.appendingPathComponent("download", isDirectory: true)
        if PathSafety.entryType(at: download) == nil { return }
        try requireDirectory(download)
        for media in try FileManager.default.contentsOfDirectory(at: download, includingPropertiesForKeys: nil) {
            let name = media.lastPathComponent
            let isDownload = name.range(of:
                #"^source(?:\.f[A-Za-z0-9_-]+)?(?:\.temp)?\.(?:mkv|mp4|webm|m4a|m4v|opus|ogg|aac|ts)(?:\.part(?:-Frag[0-9]+(?:\.part)?)?|\.ytdl)?$"#,
                options: .regularExpression) != nil
            if isDownload { try requireRegular(media) }
            // Downstream prepare creates source.mkv.watchthrough beside the
            // source. User notes and unrelated siblings are outside acquisition's
            // write set; neither walk them nor make their presence an error.
            else if name.hasPrefix("source."), !name.hasPrefix("source.mkv.watchthrough") {
                throw WatchthroughFailure(.operation, "acquisition bundle contains an unrecognized source download entry: \(name)")
            }
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        guard PathSafety.entryType(at: url) == .typeDirectory, !PathSafety.isSymbolicLink(url) else {
            throw WatchthroughFailure(.operation, "unsafe acquisition directory: \(url.path)")
        }
    }

    private static func requireRegular(_ url: URL) throws {
        guard PathSafety.entryType(at: url) == .typeRegular, !PathSafety.isSymbolicLink(url) else {
            throw WatchthroughFailure(.operation, "acquisition file is missing or unsafe: \(url.path)")
        }
    }

    private static func artifact(_ url: URL) throws -> Artifact {
        try requireRegular(url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        return Artifact(sha256: try FileSHA256.hexDigest(of: url), sizeBytes: size)
    }

    private static func verifyReady(_ receipt: inout Receipt, root: URL) throws {
        try requireDirectory(root.appendingPathComponent("download", isDirectory: true))
        let sourceURL = root.appendingPathComponent(sourcePath)
        guard let source = receipt.source, source.path == sourceURL.path, source.sizeBytes > 0,
              source.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let context = receipt.context, let description = receipt.description,
              let media = receipt.media, media.width > 0, media.height > 0,
              media.height <= receipt.configuration.height, media.fps > 0,
              !receipt.selectedFormats.isEmpty else {
            throw WatchthroughFailure(.operation, "completed acquisition has an invalid media receipt")
        }
        try requireRegular(sourceURL)
        guard try artifact(root.appendingPathComponent("source.context.json")) == context,
              try artifact(root.appendingPathComponent("source.description")) == description,
              let document = try? StableJSON.decode(Context.self, from: root.appendingPathComponent("source.context.json")),
              document.schema == "watchthrough.source-context.v1", document.videoID == receipt.videoID,
              document.canonicalURL == receipt.canonicalURL, document.selectedFormats == receipt.selectedFormats,
              document.media == media else {
            throw WatchthroughFailure(.operation, "completed acquisition context or description failed integrity verification")
        }
        if try !SourceInspector.metadataMatches(sourceURL, record: source) {
            let current = try SourceInspector.record(for: sourceURL)
            guard current.sha256 == source.sha256, current.sizeBytes == source.sizeBytes else {
                throw WatchthroughFailure(.operation, "completed acquisition source changed; preserve this bundle and acquire into a new output directory")
            }
            receipt.source = current
        }
    }

    private static func selectedMetadata(_ data: Data, expectedID: String, root: URL, height: Int) throws -> Metadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? String == expectedID,
              object["_type"] as? String == nil || object["_type"] as? String == "video",
              object["is_live"] as? Bool != true,
              !["is_live", "is_upcoming"].contains(object["live_status"] as? String ?? ""),
              let duration = number(object["duration"]), duration > 0, duration.isFinite,
              let finalPath = object["filepath"] as? String else {
            throw WatchthroughFailure(.operation, "downloader did not return one completed non-live video with usable metadata")
        }
        let finalURL = URL(fileURLWithPath: finalPath, relativeTo: root.appendingPathComponent("download", isDirectory: true)).standardizedFileURL
        guard finalURL.path == root.appendingPathComponent(sourcePath).path else {
            throw WatchthroughFailure(.operation, "downloader reported an unexpected final media path")
        }
        let selected = object["requested_formats"] as? [[String: Any]] ?? [object]
        let formats = selected.map { item in
            SelectedFormat(id: string(item["format_id"], limit: 120) ?? "unknown",
                ext: string(item["ext"], limit: 30),
                hasVideo: item["vcodec"] as? String != "none" && (item["vcodec"] as? String != nil || integer(item["width"]) != nil),
                hasAudio: item["acodec"] as? String != "none" && (item["acodec"] as? String != nil || item["vcodec"] as? String == "none" || selected.count == 1),
                videoCodec: codecField(item["vcodec"]),
                audioCodec: codecField(item["acodec"]), width: integer(item["width"]),
                height: integer(item["height"]), fps: number(item["fps"]),
                language: string(item["language"], limit: 80), protocolName: string(item["protocol"], limit: 80))
        }
        guard let video = formats.first(where: { $0.hasVideo }),
              let width = video.width, width > 0, let selectedHeight = video.height,
              selectedHeight > 0, selectedHeight <= height, let fps = video.fps, fps > 0, fps.isFinite else {
            throw WatchthroughFailure(.operation, "selected video lacks valid dimensions or native frame-rate metadata")
        }
        let chapters = (object["chapters"] as? [[String: Any]] ?? []).prefix(10_000).compactMap { item -> Chapter? in
            guard let start = number(item["start_time"]), let end = number(item["end_time"]),
                  start >= 0, end > start, end <= duration + 2 else { return nil }
            return Chapter(startSeconds: start, endSeconds: end, title: string(item["title"], limit: 1_000) ?? "")
        }
        return Metadata(title: string(object["title"], limit: 4_000) ?? "", channel: string(object["channel"], limit: 1_000),
            channelID: string(object["channel_id"], limit: 200), uploader: string(object["uploader"], limit: 1_000),
            uploadDate: string(object["upload_date"], limit: 20), duration: duration,
            description: string(object["description"], limit: 1_048_576) ?? "", chapters: chapters, formats: formats)
    }

    private static func validateMedia(_ source: URL, metadata: Metadata, ffprobe: URL) throws -> ValidatedMedia {
        var probeData = Data()
        var probeReportedErrors = false
        let tailStart = max(0, metadata.duration - 3)
        let output = try ProcessRunner.run(ffprobe.path, arguments: [
            "-v", "error", "-threads", String(MediaResourcePolicy.threads),
            "-read_intervals", "\(tailStart)%", "-show_entries",
            "format=format_name,duration,start_time:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate:packet=stream_index,pts_time,dts_time,duration_time",
            "-of", "json", source.path,
        ], timeout: 60, stdoutConsumer: { data in
            guard probeData.count + data.count <= 16_777_216 else {
                throw WatchthroughFailure(.operation, "local media tail validation exceeded its bounded output")
            }
            probeData.append(data)
        }, stderrConsumer: { data in
            if !data.allSatisfy({ [9, 10, 13, 32].contains($0) }) { probeReportedErrors = true }
        })
        guard output.succeeded, !probeReportedErrors,
              let object = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any],
              let format = object["format"] as? [String: Any],
              (format["format_name"] as? String)?.split(separator: ",").contains("matroska") == true,
              let duration = number(format["duration"]), duration > 0,
              let streams = object["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let width = integer(video["width"]), let height = integer(video["height"]),
              let videoCodec = video["codec_name"] as? String,
              let videoIndex = integer(video["index"]),
              let expected = metadata.formats.first(where: { $0.hasVideo }),
              let expectedFPS = expected.fps,
              let fps = rational(video["avg_frame_rate"]) ?? rational(video["r_frame_rate"]),
              width == expected.width, height == expected.height,
              abs(fps - expectedFPS) <= max(0.02, expectedFPS * 0.001),
              (expected.videoCodec == nil || canonicalCodec(expected.videoCodec) == videoCodec) else {
            throw WatchthroughFailure(.operation, "downloaded media failed local container, video codec, dimensions, or native frame-rate validation; preserve this bundle for inspection")
        }
        let tolerance = max(1.25, 3 / fps)
        guard abs(duration - metadata.duration) <= tolerance, abs(number(format["start_time"]) ?? 0) <= 2 else {
            throw WatchthroughFailure(.operation, "downloaded media duration does not match the completed video's metadata")
        }
        let audio = streams.first(where: { $0["codec_type"] as? String == "audio" })
        let expectedAudio = metadata.formats.first(where: { $0.hasAudio })
        if let expectedAudio {
            guard let audio, let codec = audio["codec_name"] as? String,
                  (expectedAudio.audioCodec == nil || canonicalCodec(expectedAudio.audioCodec) == codec) else {
                throw WatchthroughFailure(.operation, "downloaded media is missing the selected audio stream or has the wrong codec")
            }
        } else if audio != nil {
            throw WatchthroughFailure(.operation, "downloaded audio does not match selected format metadata")
        }
        var tails: [Int: Double] = [:]
        for packet in object["packets"] as? [[String: Any]] ?? [] {
            guard let index = integer(packet["stream_index"]),
                  let pts = number(packet["pts_time"]) ?? number(packet["dts_time"]) else { continue }
            tails[index] = max(tails[index] ?? -.infinity, pts + (number(packet["duration_time"]) ?? 0))
        }
        guard let videoTail = tails[videoIndex], videoTail >= metadata.duration - tolerance,
              videoTail <= duration + tolerance else {
            throw WatchthroughFailure(.operation, "downloaded video lacks packets covering its declared end; the acquisition remains incomplete")
        }
        var audioTail: Double?
        if let audio, let index = integer(audio["index"]) {
            audioTail = tails[index]
            guard let audioTail, audioTail >= metadata.duration - tolerance, audioTail <= duration + tolerance else {
                throw WatchthroughFailure(.operation, "downloaded audio lacks packets covering its declared end; the acquisition remains incomplete")
            }
        }
        return ValidatedMedia(width: width, height: height, fps: fps, durationSeconds: duration,
            videoCodec: videoCodec, audioCodec: audio?["codec_name"] as? String,
            videoTailSeconds: videoTail, audioTailSeconds: audioTail)
    }

    private static func canonicalCodec(_ codec: String?) -> String? {
        guard let codec else { return nil }
        let base = String(codec.split(separator: ".").first ?? "")
        switch base {
        case "avc1", "avc3": return "h264"
        case "av01": return "av1"
        case "vp09": return "vp9"
        case "hev1", "hvc1": return "hevc"
        case "mp4a": return "aac"
        default: return base
        }
    }

    private static func codecField(_ value: Any?) -> String? {
        guard let text = string(value, limit: 120), text != "none", !text.isEmpty else { return nil }
        return text
    }

    private static func string(_ value: Any?, limit: Int) -> String? {
        (value as? String).map { String($0.prefix(limit)) }
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber { result = number.doubleValue }
        else if let text = value as? String { result = Double(text) }
        else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number >= -2_147_483_648, number <= 2_147_483_647 else { return nil }
        return Int(number)
    }

    private static func rational(_ value: Any?) -> Double? {
        guard let text = value as? String else { return number(value) }
        let parts = text.split(separator: "/")
        if parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0, top > 0 {
            return top / bottom
        }
        return Double(text).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
    }

    private static func result(_ receipt: Receipt, root: URL, reused: Bool, seconds: Double) -> CommandResult {
        let media = receipt.media!
        var details = ["videoId": receipt.videoID, "url": receipt.canonicalURL,
            "formatIds": receipt.selectedFormats.map(\.id).joined(separator: "+"),
            "videoCodec": media.videoCodec, "audioCodec": media.audioCodec ?? "none",
            "nativeFPS": String(media.fps), "width": String(media.width), "height": String(media.height),
            "durationSeconds": String(media.durationSeconds), "downloaderVersion": receipt.downloaderVersion ?? "unknown",
            "elapsedSeconds": String(format: "%.3f", seconds)]
        if let language = receipt.selectedFormats.first(where: { $0.hasAudio })?.language { details["audioLanguage"] = language }
        if !reused {
            details["downloadSeconds"] = String(format: "%.3f", receipt.downloadSeconds ?? 0)
            details["validationSeconds"] = String(format: "%.3f", receipt.validationSeconds ?? 0)
        }
        var warnings: [String] = []
        if receipt.selectedFormats.contains(where: { $0.hasAudio && $0.audioCodec == nil }) {
            warnings.append("Upstream did not report the selected audio codec; local validation identified \(media.audioCodec ?? "unknown").")
        }
        if receipt.selectedFormats.contains(where: { $0.hasVideo && $0.videoCodec == nil }) {
            warnings.append("Upstream did not report the selected video codec; local validation identified \(media.videoCodec).")
        }
        return CommandResult(ok: true, command: "acquire", reused: reused,
            artifacts: ["bundle": root.path, "source": root.appendingPathComponent(sourcePath).path,
                "acquisition": root.appendingPathComponent("acquisition.json").path,
                "context": root.appendingPathComponent("source.context.json").path,
                "description": root.appendingPathComponent("source.description").path], details: details, warnings: warnings)
    }

    private static func elapsed(_ start: Double) -> Double { ProcessInfo.processInfo.systemUptime - start }
    private static func progress(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    private struct Configuration: Codable, Equatable {
        var height: Int; var format: String; var sort: String; var container: String; var policy: String
    }
    private struct Artifact: Codable, Equatable { var sha256: String; var sizeBytes: Int64 }
    private struct Receipt: Codable {
        var schema = "watchthrough.acquisition.v1"
        var state = "incomplete"
        var videoID: String
        var canonicalURL: String
        var configuration: Configuration
        var createdAt = ISO8601Clock.now()
        var updatedAt = ISO8601Clock.now()
        var attempts = 0
        var source: SourceRecord?
        var context: Artifact?
        var description: Artifact?
        var selectedFormats: [SelectedFormat] = []
        var media: ValidatedMedia?
        var downloaderVersion: String?
        var javascriptRuntime: String?
        var lastFailure: String?
        var downloadSeconds: Double?
        var validationSeconds: Double?
    }
    private struct SelectedFormat: Codable, Equatable {
        var id: String; var ext: String?; var hasVideo: Bool; var hasAudio: Bool; var videoCodec: String?; var audioCodec: String?
        var width: Int?; var height: Int?; var fps: Double?; var language: String?; var protocolName: String?
    }
    private struct Chapter: Codable { var startSeconds: Double; var endSeconds: Double; var title: String }
    private struct Metadata {
        var title: String; var channel: String?; var channelID: String?; var uploader: String?; var uploadDate: String?
        var duration: Double; var description: String; var chapters: [Chapter]; var formats: [SelectedFormat]
    }
    private struct ValidatedMedia: Codable, Equatable {
        var width: Int; var height: Int; var fps: Double; var durationSeconds: Double
        var videoCodec: String; var audioCodec: String?; var videoTailSeconds: Double; var audioTailSeconds: Double?
    }
    private struct Context: Codable {
        var schema = "watchthrough.source-context.v1"
        var videoID: String; var canonicalURL: String; var title: String; var channel: String?; var channelID: String?
        var uploader: String?; var uploadDate: String?; var durationSeconds: Double; var chapters: [Chapter]
        var selectedFormats: [SelectedFormat]; var media: ValidatedMedia; var downloaderVersion: String
    }

    private final class DownloaderCapture {
        var metadata = Data()
        private var stdoutLine = Data()
        private var stderrLine = Data()
        private var droppingLongLine = false
        var category: String?

        func stdout(_ data: Data) throws {
            var start = data.startIndex
            for newline in data.indices where data[newline] == 10 {
                try appendStdout(data[start..<newline])
                try consumeStdoutLine()
                start = data.index(after: newline)
            }
            try appendStdout(data[start...])
        }
        private func appendStdout(_ data: Data.SubSequence) throws {
            guard stdoutLine.count + data.count <= 67_108_864 else {
                throw WatchthroughFailure(.operation, "downloader output line exceeded the 64 MiB safety bound")
            }
            stdoutLine.append(data)
        }
        private func consumeStdoutLine() throws {
            defer { stdoutLine.removeAll(keepingCapacity: true) }
            let prefix = Data("watchthrough-metadata:".utf8)
            if stdoutLine.starts(with: prefix) {
                guard stdoutLine.count > prefix.count else {
                    throw WatchthroughFailure(.operation, "downloader returned an empty completed-video record")
                }
                guard metadata.isEmpty else {
                    throw WatchthroughFailure(.operation, "downloader returned multiple completed videos")
                }
                metadata = Data(stdoutLine.dropFirst(prefix.count))
            } else if stdoutLine.starts(with: Data("watchthrough-progress:".utf8)) {
                consumeLine(stdoutLine)
            }
        }
        func stderr(_ data: Data) {
            for byte in data {
                if byte == 10 || byte == 13 {
                    if !droppingLongLine { consumeLine(stderrLine) }
                    stderrLine.removeAll(keepingCapacity: true)
                    droppingLongLine = false
                } else if !droppingLongLine {
                    if stderrLine.count < 65_536 { stderrLine.append(byte) }
                    else { stderrLine.removeAll(keepingCapacity: true); droppingLongLine = true }
                }
            }
        }
        func finish() throws {
            if !stdoutLine.isEmpty { try consumeStdoutLine() }
            if !droppingLongLine { consumeLine(stderrLine) }
            stderrLine.removeAll()
        }
        private func consumeLine(_ data: Data) {
            let line = String(decoding: data, as: UTF8.self)
            if line.hasPrefix("watchthrough-progress:") {
                let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 5, let downloaded = Double(fields[1]), downloaded.isFinite, downloaded >= 0 else { return }
                var message = String(format: "Downloaded %.1f MiB", downloaded / 1_048_576)
                if let total = Double(fields[2]), total.isFinite, total > 0 {
                    message += String(format: " / %.1f MiB (%.0f%%)", total / 1_048_576, min(100, downloaded * 100 / total))
                }
                if let speed = Double(fields[3]), speed.isFinite, speed > 0 { message += String(format: ", %.1f MiB/s", speed / 1_048_576) }
                if let eta = Double(fields[4]), eta.isFinite, eta >= 0 { message += String(format: ", %.0fs remaining", eta) }
                progress(message)
                return
            }
            let lower = line.lowercased()
            if lower.contains("sign in") || lower.contains("login") || lower.contains("private video") || lower.contains("members-only") {
                category = "authentication-required"
            } else if lower.contains("403") { category = "upstream-forbidden" }
            else if lower.contains("requested format") { category = "format-unavailable" }
            else if lower.contains("javascript") || lower.contains("challenge") || lower.contains("ejs") { category = "javascript-challenge" }
            else if lower.contains("fragment") && (lower.contains("error") || lower.contains("unavailable")) { category = "fragment-unavailable" }
            else if lower.contains("live") && (lower.contains("filter") || lower.contains("upcoming")) { category = "live-video" }
            else if lower.contains("timed out") || lower.contains("network") { category = "network" }
        }
        func failure(timedOut: Bool) -> String {
            let prefix = "Acquisition did not complete; partial files remain for the same command to resume. "
            if timedOut { return prefix + "The bounded transfer time expired." }
            switch category {
            case "authentication-required": return prefix + "This video requires authentication; acquire accepts public videos without cookies."
            case "upstream-forbidden": return prefix + "YouTube refused the transfer (403). Retry with --update-downloader to use the current official client fixes."
            case "format-unavailable": return prefix + "No current format met the resolution/audio selection; retry or select a different --height."
            case "javascript-challenge": return prefix + "YouTube's JavaScript challenge failed. Retry with --update-downloader and a supported Deno or Node runtime."
            case "fragment-unavailable": return prefix + "A required media fragment was unavailable; incomplete streams are never accepted."
            case "live-video": return prefix + "Live or upcoming videos are not supported."
            case "network": return prefix + "Network retries were exhausted."
            default: return prefix + "The downloader failed. Check connectivity and video availability, then retry; use --update-downloader for current upstream fixes."
            }
        }
    }
}
