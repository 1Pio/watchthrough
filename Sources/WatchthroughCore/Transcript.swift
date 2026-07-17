import CoreFoundation
import Foundation

public struct TranscriptRun: Sendable {
    public var transcript: CanonicalTranscript
    public var rawResponse: Data

    public init(transcript: CanonicalTranscript, rawResponse: Data) {
        self.transcript = transcript
        self.rawResponse = rawResponse
    }
}

public struct DiscoveredTranscript: Sendable {
    public var url: URL
    public var transcript: CanonicalTranscript

    public init(url: URL, transcript: CanonicalTranscript) {
        self.url = url
        self.transcript = transcript
    }
}

public enum TranscriptFiles {
    public static func writeCanonical(_ transcript: CanonicalTranscript, to url: URL) throws {
        try StableJSON.write(transcript, to: url)
    }

    public static func writeText(_ transcript: CanonicalTranscript, to url: URL) throws {
        try ensureParent(of: url)
        try Data((transcript.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
            .write(to: url, options: .atomic)
    }

    public static func preserveRawResponse(_ data: Data, at url: URL) throws {
        try ensureParent(of: url)
        try data.write(to: url, options: .atomic)
    }

    private static func ensureParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - Sidecars

public enum TranscriptSidecar {
    public static func existingCandidateURLs(for mediaURL: URL) -> [URL] {
        candidateDefinitions(for: mediaURL)
            .map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Looks only beside the media. Specific canonical names win over generic
    /// basename sidecars, followed by WebVTT and SRT captions.
    public static func discover(for mediaURL: URL) throws -> DiscoveredTranscript? {
        for (url, authoritative) in candidateDefinitions(for: mediaURL)
            where FileManager.default.fileExists(atPath: url.path) {
            do {
                return DiscoveredTranscript(url: url, transcript: try load(url))
            } catch where !authoritative {
                continue // A same-basename JSON file may be unrelated media metadata.
            }
        }
        return nil
    }

    private static func candidateDefinitions(for mediaURL: URL) -> [(url: URL, authoritative: Bool)] {
        let directory = mediaURL.deletingLastPathComponent()
        let stem = mediaURL.deletingPathExtension().lastPathComponent
        return [
            (directory.appendingPathComponent("\(stem).watchthrough.json"), true),
            (directory.appendingPathComponent("\(stem).transcript.json"), true),
            (directory.appendingPathComponent("\(stem).json"), false),
            (directory.appendingPathComponent("\(stem).vtt"), true),
            (directory.appendingPathComponent("\(stem).srt"), true),
        ]
    }

    public static func load(_ url: URL) throws -> CanonicalTranscript {
        switch url.pathExtension.lowercased() {
        case "json":
            let data = try Data(contentsOf: url)
            let decoded = try StableJSON.decode(CanonicalTranscript.self, from: data)
            guard decoded.schema == WatchthroughVersion.transcriptSchema else {
                throw WatchthroughFailure(.operation, "Unsupported transcript schema in \(url.lastPathComponent).")
            }
            return honestCanonical(decoded)
        case "srt", "vtt":
            return try loadCaptions(url)
        default:
            throw WatchthroughFailure(.operation, "Unsupported transcript sidecar: \(url.lastPathComponent)")
        }
    }

    private static func loadCaptions(_ url: URL) throws -> CanonicalTranscript {
        let source = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if url.pathExtension.lowercased() == "vtt",
           let timed = wordTimedVTT(source) {
            return timed
        }
        let blocks = source.components(separatedBy: "\n\n")
        var segments: [TranscriptSegment] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = captionTime(String(timing[0])),
                  let endToken = timing[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let end = captionTime(String(endToken)),
                  end >= start else { continue }
            let text = lines.dropFirst(timingIndex + 1)
                .joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let decodedText = decodeEntities(text)
            guard !decodedText.isEmpty else { continue }
            segments.append(TranscriptSegment(
                id: String(format: "s%06d", segments.count + 1),
                text: decodedText,
                startSeconds: start,
                endSeconds: end,
                timingSource: url.pathExtension.lowercased()
            ))
        }

        guard !segments.isEmpty else {
            throw WatchthroughFailure(.operation, "No timed caption cues were found in \(url.lastPathComponent).")
        }
        return CanonicalTranscript(
            provider: "sidecar",
            model: url.pathExtension.lowercased(),
            timingPrecision: .segment,
            text: segments.map(\.text).joined(separator: "\n"),
            segments: segments
        )
    }

    private static func wordTimedVTT(_ source: String) -> CanonicalTranscript? {
        var pieces: [TimedCaptionPiece] = []
        var segments: [TranscriptSegment] = []
        var hasSubstantiveSegmentOnlyCue = false
        for block in source.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let cueStart = captionTime(String(timing[0])),
                  let endToken = timing[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let cueEnd = captionTime(String(endToken)),
                  cueEnd >= cueStart else { continue }

            let contentLines = Array(lines.dropFirst(timingIndex + 1))
            let timedLines = contentLines.compactMap { line -> [TimedCaptionPiece]? in
                let result = timedPieces(in: line, cueStart: cueStart, cueEnd: cueEnd)
                return result.isEmpty ? nil : result
            }
            if !timedLines.isEmpty {
                for linePieces in timedLines {
                    pieces.append(contentsOf: linePieces)
                    segments.append(TranscriptSegment(
                        id: "",
                        text: renderPieces(linePieces.map(\.text)),
                        startSeconds: linePieces.first?.start,
                        endSeconds: linePieces.last?.end,
                        timingSource: "vtt-inline"
                    ))
                }
            } else if cueEnd - cueStart > 0.05 {
                let text = decodeEntities(
                    contentLines.joined(separator: "\n")
                        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                )
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                guard !text.isEmpty else { continue }
                hasSubstantiveSegmentOnlyCue = true
                segments.append(TranscriptSegment(
                    id: "",
                    text: text,
                    startSeconds: cueStart,
                    endSeconds: cueEnd,
                    timingSource: "vtt"
                ))
            }
        }
        guard !pieces.isEmpty else { return nil }

        pieces.sort {
            $0.start == $1.start
                ? ($0.end == $1.end ? $0.text < $1.text : $0.end < $1.end)
                : $0.start < $1.start
        }
        var seen = Set<String>()
        pieces = pieces.filter { piece in
            let key = String(
                format: "%.6f|%@",
                locale: Locale(identifier: "en_US_POSIX"),
                piece.start,
                piece.text.lowercased()
            )
            return seen.insert(key).inserted
        }
        let words = pieces.enumerated().map { index, piece in
            TranscriptWord(
                id: String(format: "w%07d", index + 1),
                text: piece.text,
                startSeconds: piece.start,
                endSeconds: piece.end
            )
        }
        for index in segments.indices {
            segments[index].id = String(format: "s%06d", index + 1)
        }
        let language = source.components(separatedBy: .newlines)
            .first { $0.lowercased().hasPrefix("language:") }
            .map { String($0.dropFirst("language:".count)).trimmingCharacters(in: .whitespaces) }
        if hasSubstantiveSegmentOnlyCue {
            return CanonicalTranscript(
                provider: "sidecar",
                model: "vtt",
                language: language,
                timingPrecision: .segment,
                text: segments.map(\.text).joined(separator: "\n"),
                segments: segments,
                warnings: ["Mixed WebVTT timing was preserved at segment precision because not every substantive cue had inline word timestamps."]
            )
        }
        return CanonicalTranscript(
            provider: "sidecar",
            model: "vtt",
            language: language,
            timingPrecision: .word,
            text: renderTokens(words),
            words: words,
            segments: segments
        )
    }

    private static func timedPieces(
        in line: String,
        cueStart: Double,
        cueEnd: Double
    ) -> [TimedCaptionPiece] {
        guard let expression = try? NSRegularExpression(pattern: #"<([^>]+)>"#) else {
            return []
        }
        let source = line as NSString
        let matches = expression.matches(
            in: line,
            range: NSRange(location: 0, length: source.length)
        )
        var output: [TimedCaptionPiece] = []
        var cursor = 0
        var currentStart = cueStart
        var buffer = ""
        var sawTimestamp = false

        func flush(at end: Double) {
            let text = decodeEntities(buffer)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !text.isEmpty, end >= currentStart {
                output.append(TimedCaptionPiece(
                    text: text,
                    start: currentStart,
                    end: max(currentStart, min(cueEnd, end))
                ))
            }
            buffer = ""
        }

        for match in matches {
            if match.range.location > cursor {
                buffer += source.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            }
            let tag = source.substring(
                with: NSRange(location: match.range.location + 1, length: match.range.length - 2)
            )
            if let timestamp = captionTime(tag),
               timestamp >= cueStart,
               timestamp <= cueEnd + 0.1 {
                flush(at: timestamp)
                currentStart = max(cueStart, min(cueEnd, timestamp))
                sawTimestamp = true
            }
            cursor = match.range.location + match.range.length
        }
        guard sawTimestamp else { return [] }
        if cursor < source.length {
            buffer += source.substring(
                with: NSRange(location: cursor, length: source.length - cursor)
            )
        }
        flush(at: cueEnd)
        return output
    }

    private static func decodeEntities(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return (CFXMLCreateStringByUnescapingEntities(nil, text as CFString, nil) as String?) ?? text
    }

    private static func captionTime(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), let seconds = Double(fields.last!), seconds >= 0 else {
            return nil
        }
        if fields.count == 2,
           let minutes = Double(fields[0]), minutes >= 0 {
            return minutes * 60 + seconds
        }
        guard let hours = Double(fields[0]), hours >= 0,
              let minutes = Double(fields[1]), minutes >= 0 else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private struct TimedCaptionPiece {
        var text: String
        var start: Double
        var end: Double
    }
}

// MARK: - MacParakeet

public struct MacParakeetCapability: Equatable, Sendable {
    public var available: Bool
    public var executable: String?
    public var version: String?
    public var supportsSpeakerDetection: Bool
    public var speakerModelsCached: Bool

    public init(
        available: Bool,
        executable: String? = nil,
        version: String? = nil,
        supportsSpeakerDetection: Bool = false,
        speakerModelsCached: Bool = false
    ) {
        self.available = available
        self.executable = executable
        self.version = version
        self.supportsSpeakerDetection = supportsSpeakerDetection
        self.speakerModelsCached = speakerModelsCached
    }
}

public enum MacParakeetTranscriber {
    public static func probe(executable name: String = "macparakeet-cli") -> MacParakeetCapability {
        guard let executable = Tooling.find(name) else { return MacParakeetCapability(available: false) }
        let privacyEnvironment = ["MACPARAKEET_TELEMETRY": "0", "DO_NOT_TRACK": "1"]
        do {
            let help = try ProcessRunner.run(
                "/usr/bin/env",
                arguments: isolatedInvocation(
                    executable: executable.path,
                    arguments: ["transcribe", "--help"],
                    additions: privacyEnvironment
                ),
                timeout: 5
            )
            let helpText = help.stdout + help.stderr
            let health = try ProcessRunner.run(
                "/usr/bin/env",
                arguments: isolatedInvocation(
                    executable: executable.path,
                    arguments: ["health", "--json"],
                    additions: privacyEnvironment
                ),
                timeout: 10
            )
            let healthDocument = try StableJSON.decode(
                MacParakeetHealth.self,
                from: health.stdoutData
            )
            let versionOutput = try? ProcessRunner.run(
                "/usr/bin/env",
                arguments: isolatedInvocation(
                    executable: executable.path,
                    arguments: ["--version"],
                    additions: privacyEnvironment
                ),
                timeout: 5
            )
            let version = versionOutput.flatMap { output in
                let text = output.stdout.isEmpty ? output.stderr : output.stdout
                return text.split(whereSeparator: \Character.isNewline).first.map(String.init)
            }
            let supportsSpeakerDetection = helpText.contains("--speaker-detection")
            return MacParakeetCapability(
                available: help.exitCode == 0
                    && health.exitCode == 0
                    && healthDocument.speechStack.speechModelCached
                    && supportsSpeakerDetection,
                executable: executable.path,
                version: version,
                supportsSpeakerDetection: supportsSpeakerDetection,
                speakerModelsCached: healthDocument.speechStack.speakerModelsCached
            )
        } catch {
            return MacParakeetCapability(available: false, executable: executable.path)
        }
    }

    private struct MacParakeetHealth: Decodable {
        struct SpeechStack: Decodable {
            var speechModelCached: Bool
            var speakerModelsCached: Bool
        }

        var speechStack: SpeechStack
    }

    public static func transcribe(
        input: URL,
        speakerDetection: Bool = true,
        executable name: String = "macparakeet-cli",
        rawResponseURL: URL? = nil,
        timeout: TimeInterval = 7_200
    ) throws -> TranscriptRun {
        guard input.isFileURL, FileManager.default.fileExists(atPath: input.path) else {
            throw WatchthroughFailure(.usage, "MacParakeet requires an existing local media file.")
        }
        let capability = probe(executable: name)
        guard capability.available, let executable = capability.executable else {
            throw WatchthroughFailure(.readiness, "macparakeet-cli is not available.")
        }

        let operationDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("watchthrough-macparakeet-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: operationDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: operationDirectory) }
        let privateDatabase = operationDirectory.appendingPathComponent("history.sqlite")

        var arguments = [
            "transcribe", input.path,
            "--format", "json",
            "--mode", "raw",
            "--engine", "parakeet",
            "--database", privateDatabase.path,
            "--no-history",
        ]
        let enableSpeakerDetection = speakerDetection && capability.speakerModelsCached
        arguments += ["--speaker-detection", enableSpeakerDetection ? "on" : "off"]
        let output = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: isolatedInvocation(
                executable: executable,
                arguments: arguments,
                additions: ["MACPARAKEET_TELEMETRY": "0", "DO_NOT_TRACK": "1"]
            ),
            timeout: timeout
        )
        try output.requireSuccess("MacParakeet transcription failed")
        if let rawResponseURL {
            try TranscriptFiles.preserveRawResponse(output.stdoutData, at: rawResponseURL)
        }
        var transcript = try TranscriptNormalizer.macParakeet(output.stdoutData)
        if speakerDetection && !capability.speakerModelsCached {
            transcript.warnings.append(
                "Speaker detection was disabled because its local models were not already cached."
            )
        }
        return TranscriptRun(
            transcript: transcript,
            rawResponse: output.stdoutData
        )
    }
}

// MARK: - Named command adapter

public struct NamedTranscriptAdapterDefinition: Codable, Equatable, Sendable {
    public var argv: [String]

    public init(argv: [String]) { self.argv = argv }
}

public struct WatchthroughUserConfig: Codable, Equatable, Sendable {
    public var transcribers: [String: NamedTranscriptAdapterDefinition]

    public init(transcribers: [String: NamedTranscriptAdapterDefinition] = [:]) {
        self.transcribers = transcribers
    }
}

public enum NamedTranscriptAdapter {
    public static func configURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("watchthrough", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// The configured argv must contain `{input}` and `{output}`. The first item
    /// is executed directly; no shell parsing, expansion, or interpolation occurs.
    public static func transcribe(
        name: String,
        input: URL,
        output: URL,
        configURL: URL = configURL(),
        timeout: TimeInterval = 7_200
    ) throws -> TranscriptRun {
        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw WatchthroughFailure(.readiness, "Could not read transcript adapter config at \(configURL.path).")
        }
        let config = try StableJSON.decode(WatchthroughUserConfig.self, from: configData)
        guard let definition = config.transcribers[name] else {
            throw WatchthroughFailure(.readiness, "Transcript adapter '\(name)' is not configured.")
        }
        guard !definition.argv.isEmpty,
              definition.argv.contains(where: { $0.contains("{input}") }),
              definition.argv.contains(where: { $0.contains("{output}") }) else {
            throw WatchthroughFailure(
                .readiness,
                "Transcript adapter '\(name)' must define a non-empty argv with {input} and {output}."
            )
        }
        let expanded = definition.argv.map {
            $0.replacingOccurrences(of: "{input}", with: input.path)
                .replacingOccurrences(of: "{output}", with: output.path)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: isolatedInvocation(executable: expanded[0], arguments: Array(expanded.dropFirst())),
            timeout: timeout
        )
        guard process.succeeded else {
            let reason = process.timedOut ? "timed out" : "exited with status \(process.exitCode)"
            throw WatchthroughFailure(.operation, "Transcript adapter '\(name)' \(reason).")
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw WatchthroughFailure(.operation, "Transcript adapter '\(name)' did not create its {output} file.")
        }
        let raw = try Data(contentsOf: output)
        let transcript = honestCanonical(try StableJSON.decode(CanonicalTranscript.self, from: raw))
        guard transcript.schema == WatchthroughVersion.transcriptSchema else {
            throw WatchthroughFailure(.operation, "Transcript adapter '\(name)' returned an unsupported schema.")
        }
        return TranscriptRun(transcript: transcript, rawResponse: raw)
    }
}

// MARK: - ElevenLabs Scribe v2

public struct ElevenLabsOptions: Equatable, Sendable {
    public var languageCode: String?
    public var diarize: Bool
    public var tagAudioEvents: Bool

    public init(languageCode: String? = nil, diarize: Bool = true, tagAudioEvents: Bool = true) {
        self.languageCode = languageCode
        self.diarize = diarize
        self.tagAudioEvents = tagAudioEvents
    }
}

public enum ElevenLabsScribeV2 {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// Uploads the caller-supplied audio derivative as-is. Media extraction and
    /// provider size limits stay outside this adapter.
    public static func transcribe(
        audio input: URL,
        options: ElevenLabsOptions = ElevenLabsOptions(),
        credential: SecretCredential? = nil,
        rawResponseURL: URL? = nil,
        endpoint: URL = endpoint,
        timeout: TimeInterval = 3_600,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        session: URLSession = .shared
    ) throws -> TranscriptRun {
        guard input.isFileURL, FileManager.default.fileExists(atPath: input.path) else {
            throw WatchthroughFailure(.usage, "ElevenLabs Scribe requires an existing local audio file.")
        }
        guard timeout > 0 else {
            throw WatchthroughFailure(.usage, "ElevenLabs request timeout must be greater than zero.")
        }
        guard let credential = try credential ?? WatchthroughCredentials.elevenLabsAPIKey() else {
            throw WatchthroughFailure(
                .readiness,
                "ElevenLabs API key not found in the environment, macOS Keychain, or ~/.config/watchthrough/.env."
            )
        }

        let boundary = "watchthrough-\(UUID().uuidString)"
        let bodyURL = temporaryDirectory.appendingPathComponent("watchthrough-scribe-\(UUID().uuidString).multipart")
        try writeMultipartBody(audio: input, options: options, boundary: boundary, to: bodyURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.value, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let box = URLSessionResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
            box.set(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            task.cancel()
            throw WatchthroughFailure(.operation, "ElevenLabs Scribe request timed out.")
        }
        let result = box.get()
        if let error = result.error {
            throw WatchthroughFailure(.operation, "ElevenLabs Scribe request failed: \(error.localizedDescription)")
        }
        guard let response = result.response as? HTTPURLResponse, let data = result.data else {
            throw WatchthroughFailure(.operation, "ElevenLabs Scribe returned no HTTP response.")
        }
        if let rawResponseURL {
            try TranscriptFiles.preserveRawResponse(data, at: rawResponseURL)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw WatchthroughFailure(.operation, "ElevenLabs Scribe returned HTTP \(response.statusCode).")
        }
        return TranscriptRun(transcript: try TranscriptNormalizer.elevenLabs(data), rawResponse: data)
    }

    private static func writeMultipartBody(
        audio: URL,
        options: ElevenLabsOptions,
        boundary: String,
        to output: URL
    ) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        guard FileManager.default.createFile(
            atPath: output.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WatchthroughFailure(.operation, "Could not create the temporary Scribe request body.")
        }

        let destination = try FileHandle(forWritingTo: output)
        let source = try FileHandle(forReadingFrom: audio)
        defer {
            try? destination.close()
            try? source.close()
        }

        func write(_ value: String) throws {
            try destination.write(contentsOf: Data(value.utf8))
        }
        func field(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write("\(value)\r\n")
        }
        try field("model_id", "scribe_v2")
        try field("timestamps_granularity", "word")
        try field("diarize", options.diarize ? "true" : "false")
        try field("tag_audio_events", options.tagAudioEvents ? "true" : "false")
        if let languageCode = options.languageCode, !languageCode.isEmpty {
            try field("language_code", languageCode)
        }
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFilename(for: audio))\"\r\n")
        try write("Content-Type: \(mimeType(for: audio))\r\n\r\n")
        while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
            try destination.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        try destination.synchronize()
        completed = true
    }

    private static func uploadFilename(for url: URL) -> String {
        let suffix = url.pathExtension.lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return suffix.isEmpty ? "audio" : "audio.\(suffix)"
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "flac": return "audio/flac"
        case "ogg", "oga": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Normalization

public enum TranscriptNormalizer {
    public static func macParakeet(_ data: Data) throws -> CanonicalTranscript {
        let recovered = try macParakeetJSONObject(data)
        let root = recovered.root
        if (root["ok"] as? Bool) == false {
            throw WatchthroughFailure(.operation, "MacParakeet reported a transcription error.")
        }
        let payload = dictionary(root["transcription"]) ?? dictionary(root["result"]) ?? root
        let rawWords = array(payload["wordTimestamps"]) ?? array(payload["words"]) ?? []
        let words = rawWords.enumerated().compactMap { index, value -> TranscriptWord? in
            guard let item = dictionary(value),
                  let text = string(item["word"]) ?? string(item["text"]),
                  let start = millisecondsOrSeconds(item, milliseconds: ["startMs", "startMilliseconds"], seconds: ["start", "startSeconds"]),
                  let end = millisecondsOrSeconds(item, milliseconds: ["endMs", "endMilliseconds"], seconds: ["end", "endSeconds"]),
                  valid(start, end) else { return nil }
            return TranscriptWord(
                id: String(format: "w%07d", index + 1),
                text: text,
                startSeconds: start,
                endSeconds: end,
                speaker: string(item["speakerId"]) ?? string(item["speaker"]),
                confidence: number(item["confidence"]),
                type: tokenType(item["type"])
            )
        }
        let segments = normalizedSegments(payload["segments"], timingSource: "macparakeet")
        let text = string(payload["text"])
            ?? string(payload["rawTranscript"])
            ?? string(payload["cleanTranscript"])
            ?? string(payload["transcript"])
            ?? renderTokens(words)
        return honestCanonical(CanonicalTranscript(
            provider: "macparakeet",
            model: string(payload["engine"]) ?? string(payload["model"]),
            language: string(payload["languageCode"]) ?? string(payload["language"]),
            timingPrecision: !words.isEmpty ? .word : (!segments.isEmpty ? .segment : .none),
            speakersAvailable: words.contains { $0.speaker != nil } || segments.contains { $0.speaker != nil },
            text: text,
            words: words,
            segments: segments,
            warnings: (recovered.discardedPrefixBytes > 0
                ? [
                    "MacParakeet diagnostic prefix (\(recovered.discardedPrefixBytes) bytes) was discarded for JSON normalization; raw stdout was preserved unchanged."
                ]
                : []) + (words.isEmpty
                    ? ["MacParakeet response contained no usable word timestamps."]
                    : [])
        ))
    }

    public static func elevenLabs(_ data: Data) throws -> CanonicalTranscript {
        let root = try jsonObject(data)
        let rawWords = array(root["words"]) ?? []
        let words = rawWords.enumerated().compactMap { index, value -> TranscriptWord? in
            guard let item = dictionary(value),
                  let text = string(item["text"]),
                  let start = number(item["start"]),
                  let end = number(item["end"]),
                  valid(start, end) else { return nil }
            return TranscriptWord(
                id: String(format: "w%07d", index + 1),
                text: text,
                startSeconds: start,
                endSeconds: end,
                speaker: string(item["speaker_id"]) ?? string(item["speaker"]),
                confidence: number(item["confidence"]),
                providerScore: number(item["logprob"]),
                providerScoreKind: number(item["logprob"]) == nil ? nil : "logprob",
                type: tokenType(item["type"])
            )
        }
        let segments = normalizedSegments(root["segments"], timingSource: "elevenlabs")
        let text = string(root["text"]) ?? renderTokens(words)
        return honestCanonical(CanonicalTranscript(
            provider: "elevenlabs",
            model: "scribe_v2",
            language: string(root["language_code"]),
            timingPrecision: !words.isEmpty ? .word : (!segments.isEmpty ? .segment : .none),
            speakersAvailable: words.contains { $0.speaker != nil } || segments.contains { $0.speaker != nil },
            text: text,
            words: words,
            segments: segments,
            warnings: words.isEmpty ? ["Scribe v2 response contained no usable word timestamps."] : []
        ))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WatchthroughFailure(.operation, "Transcript provider returned invalid JSON.")
        }
        return root
    }

    /// Some CoreML runtimes write diagnostics to stdout before the CLI's JSON.
    /// Accept only a complete trailing JSON object, while the caller retains the
    /// original stdout bytes as the provider response.
    private static func macParakeetJSONObject(
        _ data: Data
    ) throws -> (root: [String: Any], discardedPrefixBytes: Int) {
        if let root = try? jsonObject(data) {
            return (root, 0)
        }

        for index in data.indices where data[index] == 0x7B {
            guard index > data.startIndex else { continue }
            let candidate = Data(data[index...])
            if let root = try? jsonObject(candidate) {
                return (root, data.distance(from: data.startIndex, to: index))
            }
        }
        throw WatchthroughFailure(
            .operation,
            "MacParakeet stdout did not contain a valid JSON response."
        )
    }

    private static func normalizedSegments(_ value: Any?, timingSource: String) -> [TranscriptSegment] {
        (array(value) ?? []).enumerated().compactMap { index, value in
            guard let item = dictionary(value), let text = string(item["text"]), !text.isEmpty else { return nil }
            let start = number(item["start"]) ?? number(item["startSeconds"])
            let end = number(item["end"]) ?? number(item["endSeconds"])
            return TranscriptSegment(
                id: String(format: "s%06d", index + 1),
                text: text,
                startSeconds: start,
                endSeconds: end,
                speaker: string(item["speaker_id"]) ?? string(item["speakerId"]) ?? string(item["speaker"]),
                timingSource: timingSource
            )
        }
    }
}

// MARK: - Packet captions

public enum TranscriptCaptions {
    /// Assigns each timed word, or each timed segment when words are unavailable,
    /// to at most one frame interval using its midpoint and half-open intervals.
    public static func assign(_ transcript: CanonicalTranscript, to cells: [PacketCell]) -> [PacketCell] {
        guard !cells.isEmpty else { return cells }
        var output = cells
        var buckets = Array(repeating: [String](), count: cells.count)

        if transcript.timingPrecision == .word {
            for word in transcript.words {
                guard let index = bestCell(start: word.startSeconds, end: word.endSeconds, cells: cells) else { continue }
                buckets[index].append(word.text)
            }
        } else if transcript.timingPrecision == .segment {
            for segment in transcript.segments {
                guard let start = segment.startSeconds, let end = segment.endSeconds,
                      let index = bestCell(start: start, end: end, cells: cells) else { continue }
                buckets[index].append(segment.text)
            }
        }

        for index in output.indices {
            output[index].caption = renderPieces(buckets[index])
        }
        return output
    }

    private static func bestCell(start: Double, end: Double, cells: [PacketCell]) -> Int? {
        guard valid(start, end) else { return nil }
        let point = (start + end) / 2
        return cells.firstIndex { cell in
            point >= cell.intervalStartSeconds && point < cell.intervalEndSeconds
        }
    }
}

public enum TranscriptTimeline {
    /// Provider and sidecar timestamps are media-relative. Preparation maps
    /// them onto the decoded presentation timeline exactly once.
    public static func alignedToDecodedPTS(
        _ transcript: CanonicalTranscript,
        firstPTS: Double
    ) -> CanonicalTranscript {
        guard firstPTS.isFinite,
              abs(firstPTS) > 0.000_000_5,
              transcript.timingPrecision != .none else {
            return transcript
        }

        var result = transcript
        result.words = result.words.map { word in
            var shifted = word
            shifted.startSeconds += firstPTS
            shifted.endSeconds += firstPTS
            return shifted
        }
        result.segments = result.segments.map { segment in
            var shifted = segment
            shifted.startSeconds = segment.startSeconds.map { $0 + firstPTS }
            shifted.endSeconds = segment.endSeconds.map { $0 + firstPTS }
            return shifted
        }
        let offset = String(
            format: "%+.6gs",
            locale: Locale(identifier: "en_US_POSIX"),
            firstPTS
        )
        result.warnings.append(
            "Transcript timestamps were shifted by \(offset) to align media-relative provider time with decoded presentation timestamps."
        )
        return honestCanonical(result)
    }
}

// MARK: - Private helpers

private func honestCanonical(_ transcript: CanonicalTranscript) -> CanonicalTranscript {
    var result = transcript
    let allWordsAreTimed = !result.words.isEmpty && result.words.allSatisfy {
        valid($0.startSeconds, $0.endSeconds)
    }
    if allWordsAreTimed {
        result.timingPrecision = .word
    } else if !result.segments.isEmpty,
              result.segments.allSatisfy({ segment in
                  guard let start = segment.startSeconds, let end = segment.endSeconds else { return false }
                  return valid(start, end)
              }) {
        result.timingPrecision = .segment
    } else {
        result.timingPrecision = .none
    }
    result.speakersAvailable = result.words.contains { $0.speaker != nil }
        || result.segments.contains { $0.speaker != nil }
    return result
}

private func valid(_ start: Double, _ end: Double) -> Bool {
    start.isFinite && end.isFinite && end >= start
}

private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
private func array(_ value: Any?) -> [Any]? { value as? [Any] }

private func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func millisecondsOrSeconds(
    _ item: [String: Any],
    milliseconds: [String],
    seconds: [String]
) -> Double? {
    for key in milliseconds {
        if let value = number(item[key]) { return value / 1_000 }
    }
    for key in seconds {
        if let value = number(item[key]) { return value }
    }
    return nil
}

private func tokenType(_ value: Any?) -> TranscriptTokenType {
    switch string(value)?.lowercased() {
    case "spacing", "space": return .spacing
    case "audio_event", "audioevent": return .audioEvent
    default: return .word
    }
}

private func renderTokens(_ words: [TranscriptWord]) -> String {
    renderPieces(words.map(\.text))
}

private func renderPieces(_ pieces: [String]) -> String {
    var output = ""
    let punctuation = CharacterSet(charactersIn: ".,!?;:%)]}»”’")
    for piece in pieces where !piece.isEmpty {
        if output.isEmpty || output.last?.isWhitespace == true || piece.first?.isWhitespace == true {
            output += piece
        } else if let scalar = piece.unicodeScalars.first, punctuation.contains(scalar) {
            output += piece
        } else {
            output += " " + piece
        }
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `env -i` keeps provider processes from inheriting unrelated credentials.
/// Only the filesystem/runtime values they require are forwarded.
private func isolatedInvocation(
    executable: String,
    arguments: [String],
    additions: [String: String] = [:]
) -> [String] {
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
        "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
        "PATH": inherited["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": inherited["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
        "LANG": inherited["LANG"] ?? "en_US.UTF-8",
        "LC_ALL": inherited["LC_ALL"] ?? "C",
    ]
    if let xdgConfig = inherited["XDG_CONFIG_HOME"] {
        environment["XDG_CONFIG_HOME"] = xdgConfig
    }
    environment.merge(additions) { _, addition in addition }
    let assignments = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
    return ["-i"] + assignments + [executable] + arguments
}

private final class URLSessionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Data?, URLResponse?, Error?) = (nil, nil, nil)

    func set(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        value = (data, response, error)
        lock.unlock()
    }

    func get() -> (data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (value.0, value.1, value.2)
    }
}
