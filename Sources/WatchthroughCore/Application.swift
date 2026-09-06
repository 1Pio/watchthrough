import CryptoKit
import Foundation

public struct WatchthroughApplication {
    public init() {}

    public func run(arguments: [String]) throws -> WatchthroughExit {
        let invocation = try CLIParser.parse(arguments)
        switch invocation.command {
        case .help:
            if invocation.json {
                try emit(CommandResult(
                    ok: true,
                    command: "help",
                    details: ["help": CLIParser.help]
                ))
            } else {
                print(CLIParser.help)
            }
            return .success

        case .version:
            if invocation.json {
                try emit(CommandResult(
                    ok: true,
                    command: "version",
                    details: ["version": WatchthroughVersion.current]
                ))
            } else {
                print(WatchthroughVersion.current)
            }
            return .success

        case let .prepare(options):
            let response = try prepare(options)
            try present(response, asJSON: invocation.json)
            return .success

        case let .inspect(options):
            let response = try inspect(options)
            try present(response, asJSON: invocation.json)
            return .success

        case let .retain(options):
            let result = try DurableLibrary.retain(analysis: options.analysis, note: options.note, library: options.library,
                includes: options.includes, dossiers: options.dossiers)
            try present(ApplicationResponse(result: result, human: ["Retained video knowledge."] + result.artifacts.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }), asJSON: invocation.json)
            return .success
        case let .cleanup(options):
            let result = try DurableLibrary.cleanup(analysis: options.analysis, library: options.library, apply: options.apply)
            try present(ApplicationResponse(result: result, human: result.details.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" } + result.warnings), asJSON: invocation.json)
            return .success
        case let .status(options):
            let response = status(options)
            try present(response.response, asJSON: invocation.json)
            return response.exit
        }
    }
}

// MARK: - Preparation

private let metadataDurationFallbackWarning = "Source duration metadata was unavailable; decoded the source once to recover its duration. The persisted global frame index remains on demand."

private extension WatchthroughApplication {
    func prepare(_ options: PrepareOptions) throws -> ApplicationResponse {
        let source = try SourceInspector.validate(options.source)
        let destination = try PathSafety.preparationOutput(
            options.output ?? URL(fileURLWithPath: source.path + ".watchthrough", isDirectory: true), source: source)
        let lockURL = siblingLock(for: destination)
        try PathSafety.validateAnalysisLock(lockURL, for: destination)
        let lock = try ExclusiveFileLock.acquire(at: lockURL)
        defer { lock.unlock() }
        let exists = FileManager.default.fileExists(atPath: destination.path)
        var manifest: PreparationManifest
        let session = TranscriptSession()
        if exists {
            let loaded: AnalysisContext
            if options.refresh {
                var owner = try validatedRefreshOwner(at: destination, source: source)
                let current = try SourceInspector.record(for: source)
                guard current.sha256 == owner.source.sha256, current.sizeBytes == owner.source.sizeBytes else {
                    throw WatchthroughFailure(.operation, "refuse to refresh analysis because it is owned by different source content")
                }
                owner.source = current
                loaded = AnalysisContext(analysis: destination, source: source, manifest: owner)
            } else { loaded = try loadAnalysis(at: destination, verifyFullHash: false) }
            guard loaded.source == source else {
                throw WatchthroughFailure(.operation, "analysis is owned by another source; choose a deliberate separate --out path")
            }
            manifest = loaded.manifest
            if !options.refresh {
                guard manifest.config.transcriber == options.transcriber,
                      manifest.config.speakers == options.speakers else {
                    throw WatchthroughFailure(.operation, "transcriber configuration changed; use --refresh to request a new transcript stage")
                }
                // A warm call checks only the route that actually supplied the transcript.
                if manifest.transcript.available, manifest.transcript.provider == "sidecar" {
                    let current = try preparationConfig(transcriber: options.transcriber, source: source,
                        hasAudio: manifest.media.hasAudio, session: session, speakers: options.speakers)
                    guard current.transcriptInputFingerprint == manifest.config.transcriptInputFingerprint else {
                        throw WatchthroughFailure(.operation, "source-adjacent transcript changed; use --refresh to update the transcript stage")
                    }
                }
                if manifest.transcript.available || ["unavailable", "no_audio"].contains(manifest.transcript.state ?? "") || options.deferTranscript || options.transcriber == "none" {
                    return preparationResponse(manifest: manifest, analysis: destination, reused: true)
                }
            }
        } else {
            progress("Reading source metadata and content identity...")
            let record = try SourceInspector.record(for: source)
            let media = try MediaProbe.metadata(source, ffprobe: Tooling.require("ffprobe").path)
            let config = PreparationConfig(transcriber: options.transcriber, speakers: options.speakers, deferTranscript: options.deferTranscript)
            manifest = PreparationManifest(createdAt: ISO8601Clock.now(), completedAt: ISO8601Clock.now(),
                source: record, media: media, config: config,
                transcript: TranscriptSummary(available: false, state: options.transcriber == "none" ? "disabled" : "deferred"),
                visual: VisualSummary(), tools: ["watchthrough": WatchthroughVersion.current],
                warnings: media.frameCount > 0 ? [metadataDurationFallbackWarning] : [])
            let staging = try ArtifactStaging.temporarySibling(for: destination)
            try ManifestStore.write(manifest, to: staging.appendingPathComponent("manifest.json"))
            try verifySourceMetadata(source, stillMatches: record)
            try ArtifactStaging.promote(staging, to: destination)
        }
        if options.refresh {
            manifest.config = PreparationConfig(transcriber: options.transcriber, speakers: options.speakers, deferTranscript: options.deferTranscript)
            // Retain independently successful visual stages. Captioned packets have a content key.
            manifest.transcript = TranscriptSummary(available: false, state: options.transcriber == "none" ? "disabled" : "deferred")
            manifest.visual.overviewPacketPath = ""
            manifest.visual.overviewFrames = 0
            manifest.visual.largestOverviewGapSeconds = 0
            manifest.warnings = manifest.warnings.filter { $0 == metadataDurationFallbackWarning }
            manifest.completedAt = ISO8601Clock.now()
            try ManifestStore.write(manifest, to: destination.appendingPathComponent("manifest.json"))
        }
        if !options.deferTranscript && options.transcriber != "none" {
            try enrichTranscript(manifest: &manifest, analysis: destination, source: source, session: session)
        }
        return preparationResponse(manifest: manifest, analysis: destination, reused: exists && !options.refresh)
    }

    /// Each enrichment commits its own manifest update. A later failed stage
    /// cannot discard metadata, a transcript, or other successful evidence.
    func enrichTranscript(manifest: inout PreparationManifest, analysis: URL, source: URL, session: TranscriptSession) throws {
        if manifest.transcript.available { return }
        let requested = manifest.config.transcriber == "none" ? "auto" : manifest.config.transcriber
        if !manifest.media.hasAudio && requested != "sidecar" {
            if requested == "auto", (try? TranscriptSidecar.discover(for: source)) == nil {
                manifest.transcript = TranscriptSummary(available: false, state: "no_audio")
                manifest.warnings = unique(manifest.warnings + ["Source has no audio stream; speech recognition was skipped. Explicit sidecars remain supported."])
                try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
                return
            } else if requested == "macparakeet" || requested == "scribe" {
                throw WatchthroughFailure(.operation, "selected speech transcriber requires an audio stream; use a sidecar for visual-only media")
            }
        }
        let config = try preparationConfig(transcriber: requested, source: source, hasAudio: manifest.media.hasAudio, session: session,
            speakers: manifest.config.speakers)
        let stageName = "run-" + UUID().uuidString.lowercased()
        let transcriptRoot = try PathSafety.ensureStageDirectory("transcript", under: analysis)
        let destination = transcriptRoot.appendingPathComponent(stageName, isDirectory: true)
        let staging = try ArtifactStaging.temporarySibling(for: destination)
        progress("Resolving transcript (\(requested))...")
        var tools = manifest.tools
        let result: TranscriptPreparation
        do {
            result = try prepareTranscript(requested: requested, source: source, media: manifest.media,
                staging: staging, ffmpeg: Tooling.find("ffmpeg")?.path ?? "ffmpeg", tools: &tools,
                session: session, speakers: manifest.config.speakers)
        } catch {
            manifest.transcript.state = "failed"
            manifest.warnings = unique(manifest.warnings + ["Transcript stage failed; metadata and previous visual stages remain reusable. \(errorMessage(error))"])
            try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
            throw error
        }
        try verifySourceMetadata(source, stillMatches: manifest.source)
        var summary = result.summary
        try ArtifactStaging.promote(staging, to: destination)
        if summary.available {
            let prefix = "transcript/\(stageName)/"
            summary.path = summary.path.map { prefix + $0 }
            summary.textPath = summary.textPath.map { prefix + $0 }
            summary.rawPath = summary.rawPath.map { prefix + $0 }
            summary.state = "ready"
        } else {
            summary.state = "unavailable"
        }
        manifest.config.transcriptInputFingerprint = config.transcriptInputFingerprint
        manifest.config.transcriber = requested
        manifest.transcript = summary
        manifest.tools = tools
        manifest.warnings = unique(manifest.warnings.filter { $0 == metadataDurationFallbackWarning } + result.warnings + (result.transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? ["Transcript provider returned an empty_result; this is not evidence that the source contains no speech."] : []))
        manifest.completedAt = ISO8601Clock.now()
        manifest.visual.overviewPacketPath = ""
        manifest.visual.overviewFrames = 0
        manifest.visual.largestOverviewGapSeconds = 0
        try ManifestStore.write(manifest, to: analysis.appendingPathComponent("manifest.json"))
    }

    func prepareTranscript(
        requested: String,
        source: URL,
        media: MediaInfo,
        staging: URL,
        ffmpeg: String,
        tools: inout [String: String],
        session: TranscriptSession,
        speakers: Bool
    ) throws -> TranscriptPreparation {
        if requested == "none" {
            return .unavailable(warnings: [])
        }

        if requested == "sidecar" {
            if let sidecar = try TranscriptSidecar.discover(for: source) {
                return try persistTranscript(
                    sidecar.transcript,
                    raw: try Data(contentsOf: sidecar.url),
                    rawExtension: safeExtension(sidecar.url.pathExtension),
                    under: staging,
                    warnings: sidecar.transcript.warnings,
                    timelineOrigin: "container-start"
                )
            }
            throw WatchthroughFailure(.readiness, "no supported source-adjacent transcript sidecar was found")
        }

        if requested == "macparakeet" {
            let capability = session.macParakeet()
            if capability.available {
                if let version = capability.version {
                    tools["macparakeet"] = version
                } else if let executable = capability.executable {
                    tools["macparakeet"] = executable
                }
                let run = try MacParakeetTranscriber.transcribe(input: source, capability: capability, speakers: speakers)
                return try persistTranscript(
                    run.transcript,
                    raw: run.rawResponse,
                    rawExtension: "json",
                    under: staging,
                    warnings: run.transcript.warnings
                )
            }
            throw WatchthroughFailure(.readiness, "macparakeet-cli is not available or capability-compatible")
        }

        if requested == "auto" {
            var fallbackWarnings: [String] = []

            do {
                if let sidecar = try TranscriptSidecar.discover(for: source) {
                    return try persistTranscript(
                        sidecar.transcript,
                        raw: try Data(contentsOf: sidecar.url),
                        rawExtension: safeExtension(sidecar.url.pathExtension),
                        under: staging,
                        warnings: fallbackWarnings + sidecar.transcript.warnings,
                        timelineOrigin: "container-start"
                    )
                }
            } catch {
                fallbackWarnings.append(autoTranscriptFailure("sidecar", error))
            }

            if !media.hasAudio {
                return .unavailable(warnings: fallbackWarnings + ["Source has no audio stream; local speech recognition was skipped."])
            }

            let capability = session.macParakeet()
            if capability.available {
                do {
                    if let version = capability.version {
                        tools["macparakeet"] = version
                    } else if let executable = capability.executable {
                        tools["macparakeet"] = executable
                    }
                    let run = try MacParakeetTranscriber.transcribe(input: source, capability: capability, speakers: speakers)
                    return try persistTranscript(
                        run.transcript,
                        raw: run.rawResponse,
                        rawExtension: "json",
                        under: staging,
                        warnings: fallbackWarnings + run.transcript.warnings
                    )
                } catch {
                    fallbackWarnings.append(autoTranscriptFailure("MacParakeet", error))
                }
            }

            do {
                if try configuredAdapter(named: "default") {
                    var result = try runNamedAdapter(
                        name: "default",
                        source: source,
                        staging: staging,
                        tools: &tools
                    )
                    result.warnings = unique(fallbackWarnings + result.warnings)
                    return result
                }
            } catch {
                fallbackWarnings.append(autoTranscriptFailure("default command adapter", error))
            }

            return .unavailable(warnings: fallbackWarnings + [
                "No local transcript sidecar, compatible MacParakeet CLI, or default command adapter was available; preparation is visual-only."
            ])
        }

        if requested.hasPrefix("command:") {
            let name = String(requested.dropFirst("command:".count))
            return try runNamedAdapter(
                name: name,
                source: source,
                staging: staging,
                tools: &tools
            )
        }

        if requested == "scribe" {
            guard media.hasAudio else {
                throw WatchthroughFailure(.operation, "Scribe was selected but the source has no audio stream")
            }
            let transcriptDirectory = staging
            try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
            let audio = transcriptDirectory.appendingPathComponent(".scribe-audio.flac")
            defer { try? FileManager.default.removeItem(at: audio) }
            try ProcessRunner.run(
                ffmpeg,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                ] + MediaResourcePolicy.decoderArguments + MediaResourcePolicy.filterArguments + [
                    "-i", source.path,
                    "-map", "0:a:0", "-vn", "-sn", "-dn",
                    "-ac", "1", "-ar", "16000", "-c:a", "flac", "-compression_level", "5",
                ] + MediaResourcePolicy.encoderArguments + [audio.path,
                ]
            ).requireSuccess("ffmpeg could not extract speech audio for Scribe")
            let run = try ElevenLabsScribeV2.transcribe(audio: audio, options: ElevenLabsOptions(diarize: speakers))
            tools["elevenlabs"] = "scribe_v2"
            return try persistTranscript(
                run.transcript,
                raw: run.rawResponse,
                rawExtension: "json",
                under: staging,
                warnings: run.transcript.warnings
            )
        }

        throw WatchthroughFailure(.usage, "unsupported transcriber '\(requested)'")
    }

    func runNamedAdapter(
        name: String,
        source: URL,
        staging: URL,
        tools: inout [String: String]
    ) throws -> TranscriptPreparation {
        let directory = staging
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let adapterOutput = directory.appendingPathComponent(".adapter-output.json")
        defer { try? FileManager.default.removeItem(at: adapterOutput) }
        let run = try NamedTranscriptAdapter.transcribe(name: name, input: source, output: adapterOutput)
        tools["transcript-adapter"] = name
        return try persistTranscript(
            run.transcript,
            raw: run.rawResponse,
            rawExtension: "json",
            under: staging,
            warnings: run.transcript.warnings,
            timelineOrigin: "container-start"
        )
    }

    func persistTranscript(
        _ transcript: CanonicalTranscript,
        raw: Data,
        rawExtension: String,
        under staging: URL,
        warnings: [String],
        timelineOrigin: String = "audio-stream-start"
    ) throws -> TranscriptPreparation {
        let canonicalPath = "transcript.json"
        let textPath = "transcript.txt"
        let rawPath = "raw-provider-response.\(rawExtension)"
        try TranscriptFiles.writeCanonical(transcript, to: staging.appendingPathComponent(canonicalPath))
        try TranscriptFiles.writeText(transcript, to: staging.appendingPathComponent(textPath))
        try TranscriptFiles.preserveRawResponse(raw, at: staging.appendingPathComponent(rawPath))
        let textData = try Data(contentsOf: staging.appendingPathComponent(textPath))
        return TranscriptPreparation(
            transcript: transcript,
            summary: TranscriptSummary(
                available: true,
                provider: transcript.provider,
                model: transcript.model,
                language: transcript.language,
                timingPrecision: transcript.timingPrecision,
                speakersAvailable: transcript.speakersAvailable,
                path: canonicalPath,
                textPath: textPath,
                rawPath: rawPath,
                state: "ready",
                fingerprint: digestFingerprint(label: "transcript", data: try StableJSON.encode(transcript)),
                textBytes: textData.count,
                textFingerprint: digestFingerprint(label: "transcript-text", data: textData),
                timelineOrigin: timelineOrigin,
                approximateTokens: Int(ceil(Double(textData.count) / 4))
            ),
            warnings: unique(warnings + transcript.warnings)
        )
    }

    func preparationConfig(transcriber: String, source: URL, hasAudio: Bool, session: TranscriptSession, speakers: Bool) throws -> PreparationConfig {
        let fingerprint: String
        switch transcriber {
        case "none": fingerprint = "none"
        case "scribe": fingerprint = "elevenlabs:scribe_v2"
        case "sidecar", "auto":
            if let sidecar = try? TranscriptSidecar.discover(for: source) {
                fingerprint = try fileFingerprint(label: "sidecar", url: sidecar.url)
            } else if transcriber == "sidecar" {
                fingerprint = "sidecar:missing"
            } else if !hasAudio {
                fingerprint = "no-audio"
            } else {
                let capability = session.macParakeet()
                if capability.available {
                    fingerprint = macParakeetFingerprint(capability)
                } else if let definition = try? configuredAdapterDefinition(named: "default") {
                    fingerprint = try adapterFingerprint(name: "default", definition: definition)
                } else { fingerprint = "local-transcript-unavailable" }
            }
        case "macparakeet": fingerprint = macParakeetFingerprint(session.macParakeet())
        default:
            let name = String(transcriber.dropFirst("command:".count))
            if let definition = try configuredAdapterDefinition(named: name) {
                fingerprint = try adapterFingerprint(name: name, definition: definition)
            } else { fingerprint = "command:\(name):missing" }
        }
        return PreparationConfig(transcriber: transcriber,
            transcriptInputFingerprint: digestFingerprint(label: "transcript-input", data: Data("\(fingerprint)|speakers:\(speakers)".utf8)), speakers: speakers)
    }

    func configuredAdapter(named name: String) throws -> Bool {
        try configuredAdapterDefinition(named: name) != nil
    }

    func configuredAdapterDefinition(
        named name: String
    ) throws -> NamedTranscriptAdapterDefinition? {
        let url = NamedTranscriptAdapter.configURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try StableJSON.decode(WatchthroughUserConfig.self, from: url).transcribers[name]
        } catch {
            throw WatchthroughFailure(.readiness, "transcript adapter config is invalid: \(error.localizedDescription)")
        }
    }

    func fileFingerprint(label: String, url: URL) throws -> String {
        "\(label):\(try FileSHA256.hexDigest(of: url))"
    }

    func adapterFingerprint(
        name: String,
        definition: NamedTranscriptAdapterDefinition
    ) throws -> String {
        var identity = try StableJSON.encode(definition)
        if let executableName = definition.argv.first,
           let executable = Tooling.find(executableName) {
            identity.append(Data("|executable:\(try FileSHA256.hexDigest(of: executable))".utf8))
        } else {
            identity.append(Data("|executable:missing".utf8))
        }
        return digestFingerprint(label: "command:\(name)", data: identity)
    }

    func macParakeetFingerprint(
        _ capability: MacParakeetCapability? = nil
    ) -> String {
        let capability = capability ?? MacParakeetTranscriber.probe()
        let description = [
            capability.available ? "available" : "unavailable",
            capability.version ?? "unknown-version",
            capability.supportsSpeakerDetection ? "speaker-detection" : "no-speaker-detection",
            capability.speakerModelsCached ? "speaker-models-cached" : "speaker-models-not-cached",
            "engine:parakeet",
        ].joined(separator: "|")
        return digestFingerprint(label: "macparakeet", data: Data(description.utf8))
    }

    func digestFingerprint(label: String, data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(label):\(digest)"
    }

    func preparationResponse(manifest: PreparationManifest, analysis: URL, reused: Bool) -> ApplicationResponse {
        let artifacts = analysisArtifacts(manifest: manifest, analysis: analysis)
        var details = stageDetails(manifest)
        details["next_inspect"] = "watchthrough --json inspect \(shellQuoted(analysis.path)) overview"
        if manifest.transcript.available {
            details["next_transcript"] = "Read artifacts.transcript_text; approximate token count is only a routing estimate."
        } else if manifest.transcript.state == "no_audio" {
            details["next_transcript"] = "Source has no audio. Continue visual inspection with details.next_inspect."
        } else {
            details["next_transcript"] = "watchthrough --json inspect \(shellQuoted(analysis.path)) transcript"
        }
        let result = CommandResult(ok: true, command: "prepare", analysis: analysis.path, reused: reused,
            artifacts: artifacts, details: details, warnings: manifest.warnings)
        return ApplicationResponse(result: result, human: [
            "\(reused ? "Reused" : "Prepared") analysis: \(analysis.path)",
            "Transcript: \(details["transcript_state"] ?? "unavailable") (\(details["transcript_provider"] ?? "none"))",
            "Next: \(details["next_inspect"]!)",
        ] + manifest.warnings.map { "Warning: \($0)" })
    }
}

// MARK: - Inspection

private extension WatchthroughApplication {
    func inspect(_ options: InspectOptions) throws -> ApplicationResponse {
        let analysis = options.analysis.standardizedFileURL.resolvingSymlinksInPath()
        try PathSafety.validateExistingAnalysisRoot(analysis)
        let lockURL = siblingLock(for: analysis)
        try PathSafety.validateAnalysisLock(lockURL, for: analysis)
        // One lifetime writer serializes enrichment, refresh and packet promotion.
        let lock = try ExclusiveFileLock.acquire(at: lockURL)
        defer { lock.unlock() }
        var context = try loadAnalysis(at: analysis, verifyFullHash: false)
        switch options.selector {
        case .transcript:
            guard options.every == nil else { throw WatchthroughFailure(.usage, "transcript has no visual --every sampling") }
            let reused = context.manifest.transcript.available
            try enrichTranscript(manifest: &context.manifest, analysis: analysis, source: context.source, session: TranscriptSession())
            _ = try readTranscript(context.manifest, under: analysis)
            var response = preparationResponse(manifest: context.manifest, analysis: analysis, reused: reused)
            response.result.command = "inspect"
            response.result.details["selector"] = "transcript"
            return response
        case .events:
            guard options.every == nil else { throw WatchthroughFailure(.usage, "events is an index; --every applies to a temporal packet") }
            let reused = !context.manifest.visual.eventsPath.isEmpty
            let index = try ensureEvents(context: &context)
            let path = try requiredArtifact(context.manifest.visual.eventsPath, under: analysis)
            return ApplicationResponse(result: CommandResult(ok: true, command: "inspect", analysis: analysis.path,
                reused: reused, artifacts: ["events": path.path], details: [
                    "selector": "events", "visual_change_candidates": String(index.events.count),
                    "suggested_selectors": index.events.prefix(10).map { "event:\($0.id)" }.joined(separator: ","),
                    "coverage": "Full-duration low-resolution change scan; candidates are routing hints, not visual observations."
                ]), human: ["Visual-change candidates: \(index.events.count)", "Index: \(path.path)"])
        case .time, .frame:
            guard options.every == nil else { throw WatchthroughFailure(.usage, "--every applies to a range or event") }
        case .overview:
            guard options.every == nil else { throw WatchthroughFailure(.usage, "overview uses --samples; --every applies to a range or event") }
        case .event, .range: break
        }
        return try generateInspection(options, context: &context)
    }

    func ensureEvents(context: inout AnalysisContext) throws -> EventIndex {
        if !context.manifest.visual.eventsPath.isEmpty {
            return try decodeEvents(at: requiredArtifact(context.manifest.visual.eventsPath, under: context.analysis))
        }
        let visual = try PathSafety.ensureStageDirectory("visual", under: context.analysis)
        let destination = visual.appendingPathComponent("events.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WatchthroughFailure(.operation, "unreferenced visual/events.json exists; preserve it and investigate before retrying")
        }
        progress("Scanning visual changes on request...")
        let events = try VisualAnalyzer.scan(source: context.source, media: context.manifest.media,
            sampleLimit: context.manifest.config.visualSampleLimit, ffmpegPath: Tooling.require("ffmpeg").path)
        try verifySourceMetadata(context.source, stillMatches: context.manifest.source)
        try StableJSON.write(events, to: destination)
        context.manifest.visual.eventsPath = "visual/events.json"
        context.manifest.visual.eventCount = events.events.count
        context.manifest.visual.scanFPS = events.scanFPS
        try ManifestStore.write(context.manifest, to: context.analysis.appendingPathComponent("manifest.json"))
        return events
    }

    func ensureFrameIndex(context: inout AnalysisContext) throws -> [FramePoint] {
        if !context.manifest.visual.frameIndexPath.isEmpty {
            return try FrameIndexTSV.read(from: requiredArtifact(context.manifest.visual.frameIndexPath, under: context.analysis))
        }
        let visual = try PathSafety.ensureStageDirectory("visual", under: context.analysis)
        let destination = visual.appendingPathComponent("frame-index.tsv")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WatchthroughFailure(.operation, "unreferenced frame index exists; preserve it and investigate before retrying")
        }
        progress("Indexing all decoded frames for an explicit global frame ordinal...")
        let probed = try MediaProbe.probe(context.source, ffprobe: Tooling.require("ffprobe").path)
        try verifySourceMetadata(context.source, stillMatches: context.manifest.source)
        try FrameIndexTSV.write(probed.frames, to: destination)
        context.manifest.visual.frameIndexPath = "visual/frame-index.tsv"
        context.manifest.media.frameCount = probed.frames.count
        context.manifest.visual.indexedFirstPTS = probed.frames.first?.ptsSeconds
        context.manifest.visual.indexedLastPTS = probed.frames.last?.ptsSeconds
        // Keep the metadata timeline invariant. An exact tail is established by each packet's receipt.
        try ManifestStore.write(context.manifest, to: context.analysis.appendingPathComponent("manifest.json"))
        return probed.frames
    }

    func generateInspection(_ options: InspectOptions, context: inout AnalysisContext) throws -> ApplicationResponse {
        let media = context.manifest.media
        var rangeStart = media.firstPTS
        var rangeEnd = media.lastPTS
        var interval: SamplingInterval?
        var sampling: String
        var identitySampling: String
        switch options.selector {
        case .overview:
            sampling = "uniform overview (target \(options.samples)); decoded first and tail"
            identitySampling = "overview:\(options.samples)"
        case let .range(start, end):
            rangeStart = max(media.firstPTS, start)
            rangeEnd = min(media.lastPTS, end)
            guard rangeEnd >= rangeStart else { throw WatchthroughFailure(.usage, "inspection range does not overlap the video timeline") }
            interval = options.every ?? .seconds(max(0.5, (rangeEnd - rangeStart) / 59))
            sampling = samplingDescription(interval!)
            identitySampling = samplingIdentity(interval!)
        case let .event(id):
            let events = try ensureEvents(context: &context)
            guard let event = events.events.first(where: { $0.id == id }) else { throw WatchthroughFailure(.usage, "visual-change candidate '\(id)' does not exist") }
            rangeStart = max(media.firstPTS, event.startSeconds - 1)
            rangeEnd = min(media.lastPTS, event.endSeconds + 1)
            interval = options.every ?? .seconds(0.5)
            sampling = samplingDescription(interval!)
            identitySampling = samplingIdentity(interval!)
        case let .time(seconds):
            guard seconds >= media.firstPTS && seconds <= media.lastPTS else { throw WatchthroughFailure(.usage, "timestamp is outside the video timeline") }
            rangeStart = max(media.firstPTS, seconds - 2)
            rangeEnd = min(media.lastPTS, seconds + 2)
            sampling = "single decoded timestamp receipt"
            identitySampling = "timestamp"
        case .frame:
            sampling = "single globally indexed decoded frame"
            identitySampling = "global-frame"
        case .events, .transcript: throw WatchthroughFailure(.operation, "internal selector routing error")
        }
        let transcriptFingerprint = context.manifest.transcript.fingerprint
            ?? (context.manifest.transcript.path.flatMap { resolveRelative($0, under: context.analysis) }
                .flatMap { try? FileSHA256.hexDigest(of: $0) } ?? "no-transcript")
        let evidenceKey = "decoded-receipt-v2|\(context.manifest.source.sha256)|\(options.selectorText)|\(identitySampling)|width:\(options.width)"
        let contentKey = "packet-render-v2|generation:\(context.manifest.completedAt)|\(transcriptFingerprint)|width:\(options.width)|format:\(options.sheetFormat.rawValue)"
        let identity = inspectionIdentity(selector: options.selectorText, sampling: identitySampling + "|" + contentKey, cells: options.cells)
        let inspections = try PathSafety.ensureInspectionsDirectory(under: context.analysis)
        let destination = try PathSafety.inspectionDestination(named: identity, under: inspections)
        let packetURL = destination.appendingPathComponent("packet.json")
        if FileManager.default.fileExists(atPath: destination.path) {
            let packet = try loadPacket(at: packetURL, root: destination)
            guard packet.selector == options.selectorText, packet.contentFingerprint == contentKey,
                  packet.sourcePath == context.source.path, packet.cellsPerSheet == options.cells,
                  packet.maximumFrameWidth == options.width else { throw WatchthroughFailure(.operation, "inspection cache identity does not match its packet") }
            return inspectionResponse(packet: packet, packetURL: packetURL, analysis: context.analysis, reused: true)
        }
        let staging = try ArtifactStaging.temporarySibling(for: destination)
        let framesDirectory = staging.appendingPathComponent("frames", isDirectory: true)
        let ffmpeg = Tooling.find("ffmpeg")?.path ?? "ffmpeg"
        var evidence: [PacketEvidenceFrame]
        progress("Decoding only requested visual evidence...")
        if let cached = try reusableEvidence(fingerprint: evidenceKey, under: inspections, destination: framesDirectory) {
            evidence = cached
            if case .frame = options.selector, let point = evidence.first {
                rangeStart = max(media.firstPTS, point.pts - 2)
                rangeEnd = max(point.pts.nextUp, min(media.lastPTS, point.pts + 2))
            }
        } else if case let .frame(ordinal) = options.selector {
            let frames = try ensureFrameIndex(context: &context)
            guard let selected = FrameSelector.atOrdinal(ordinal, in: frames) else { throw WatchthroughFailure(.usage, "decoded frame ordinal \(ordinal) is outside 0...\(max(0, frames.count - 1))") }
            rangeStart = max(media.firstPTS, selected.ptsSeconds - 2)
            rangeEnd = max(selected.ptsSeconds.nextUp, min(media.lastPTS, selected.ptsSeconds + 2))
            let globalFrames = frames
            let extracted = try FrameExtractor.extract(source: context.source, selectedFrames: [selected], frameIndex: globalFrames,
                destinationDirectory: framesDirectory, maximumWidth: options.width, ffmpegPath: ffmpeg, media: media)
            evidence = extracted.map { PacketEvidenceFrame(pts: selected.ptsSeconds, url: $0.url, ordinal: selected.ordinal, localOrdinal: nil) }
        } else if case .overview = options.selector {
            let count = options.samples
            let tail = try TemporalExtractor.tail(source: context.source, media: media, destinationDirectory: framesDirectory,
                maximumWidth: options.width, ffmpegPath: ffmpeg, ffprobePath: Tooling.require("ffprobe").path)
            let times = (0..<(count - 1)).map { media.firstPTS + (tail.ptsSeconds - media.firstPTS) * Double($0) / Double(count - 1) }
            let extracted = try TemporalExtractor.extract(source: context.source, media: media, times: times,
                destinationDirectory: framesDirectory, maximumWidth: options.width, ffmpegPath: ffmpeg)
            var temporal: [TemporalFrame] = []
            for frame in extracted + [tail] where !temporal.contains(where: { nearlyEqual($0.ptsSeconds, frame.ptsSeconds) }) { temporal.append(frame) }
            evidence = temporal.map { PacketEvidenceFrame(pts: $0.ptsSeconds, url: $0.url, ordinal: nil, localOrdinal: $0.localOrdinal) }
        } else if case let .time(seconds) = options.selector {
            evidence = try TemporalExtractor.extract(source: context.source, media: media, times: [seconds],
                destinationDirectory: framesDirectory, maximumWidth: options.width, ffmpegPath: ffmpeg)
                .map { PacketEvidenceFrame(pts: $0.ptsSeconds, url: $0.url, ordinal: nil, localOrdinal: $0.localOrdinal) }
        } else {
            evidence = try TemporalExtractor.extract(source: context.source, media: media, range: rangeStart...rangeEnd, every: interval!,
                destinationDirectory: framesDirectory, maximumWidth: options.width, maximumFrames: 300, ffmpegPath: ffmpeg)
                .map { PacketEvidenceFrame(pts: $0.ptsSeconds, url: $0.url, ordinal: nil, localOrdinal: $0.localOrdinal) }
        }
        evidence.sort { $0.pts < $1.pts }
        let transcript = try readTranscript(context.manifest, under: context.analysis)
        let transcriptOrigin = context.manifest.transcript.timelineOrigin == "container-start"
            ? (media.containerStartPTS ?? media.firstPTS) : (media.audioStartPTS ?? media.firstPTS)
        let packet = try buildPacket(source: context.source, directory: staging, selector: options.selectorText,
            evidence: evidence, rangeStart: rangeStart, rangeEnd: rangeEnd, sampling: sampling,
            cellsPerSheet: options.cells, transcript: transcript, transcriptOrigin: transcriptOrigin,
            maximumFrameWidth: options.width, format: options.sheetFormat, contentKey: contentKey, evidenceKey: evidenceKey)
        try verifySourceMetadata(context.source, stillMatches: context.manifest.source)
        _ = try loadPacket(at: staging.appendingPathComponent("packet.json"), root: staging)
        try ArtifactStaging.promote(staging, to: destination)
        if case .overview = options.selector {
            context.manifest.visual.overviewPacketPath = "inspections/\(identity)/packet.json"
            context.manifest.visual.overviewFrames = packet.cells.count
            context.manifest.visual.largestOverviewGapSeconds = packet.largestGapSeconds
            try ManifestStore.write(context.manifest, to: context.analysis.appendingPathComponent("manifest.json"))
        }
        return inspectionResponse(packet: packet, packetURL: packetURL, analysis: context.analysis, reused: false)
    }

    func reusableEvidence(fingerprint: String, under inspections: URL, destination: URL) throws -> [PacketEvidenceFrame]? {
        let entries = try FileManager.default.contentsOfDirectory(at: inspections, includingPropertiesForKeys: [.isDirectoryKey]).sorted { $0.path < $1.path }
        for root in entries where !root.lastPathComponent.hasPrefix(".") {
            guard let packet = try? loadPacket(at: root.appendingPathComponent("packet.json"), root: root),
                  packet.evidenceFingerprint == fingerprint, packet.artifactFingerprints != nil else { continue }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var evidence: [PacketEvidenceFrame] = []
            for cell in packet.cells {
                let original = try requiredArtifact(cell.framePath, under: root)
                let copy = destination.appendingPathComponent(original.lastPathComponent)
                try FileManager.default.copyItem(at: original, to: copy)
                evidence.append(PacketEvidenceFrame(pts: cell.ptsSeconds, url: copy, ordinal: cell.ordinal, localOrdinal: cell.localOrdinal))
            }
            progress("Reusing decoded frame evidence; rendering the requested layout...")
            return evidence
        }
        return nil
    }

    func inspectionResponse(
        packet: InspectionPacket,
        packetURL: URL,
        analysis: URL,
        reused: Bool
    ) -> ApplicationResponse {
        let root = packetURL.deletingLastPathComponent()
        var artifacts: [String: String] = [
            "packet": packetURL.path,
            "markdown": root.appendingPathComponent("packet.md").path,
        ]
        for (index, sheet) in packet.sheets.enumerated() {
            if let url = resolveRelative(sheet, under: root) {
                artifacts["sheet_\(index + 1)"] = url.path
            }
        }
        if packet.cells.count == 1,
           let frame = resolveRelative(packet.cells[0].framePath, under: root) {
            artifacts["frame"] = frame.path
        }
        return ApplicationResponse(
            result: CommandResult(
                ok: true,
                command: "inspect",
                analysis: analysis.path,
                reused: reused,
                artifacts: artifacts,
                details: [
                    "selector": packet.selector,
                    "frames": String(packet.cells.count),
                    "sampling": packet.sampling,
                    "range_start_seconds": decimal(packet.rangeStartSeconds),
                    "range_end_seconds": decimal(packet.rangeEndSeconds),
                    "timing_precision": packet.timingPrecision.rawValue,
                    "timing_precision_scope": "transcript",
                    "largest_gap_seconds": decimal(packet.largestGapSeconds),
                ],
                warnings: packet.warnings
            ),
            human: [
                reused ? "Reused inspection: \(packetURL.path)" : "Created inspection: \(packetURL.path)",
                "Frames: \(packet.cells.count), sampling: \(packet.sampling)",
            ] + packet.warnings.map { "Warning: \($0)" }
        )
    }
}

// MARK: - Packet construction

private extension WatchthroughApplication {
    func buildPacket(source: URL, directory: URL, selector: String, evidence: [PacketEvidenceFrame],
                     rangeStart: Double, rangeEnd: Double, sampling: String, cellsPerSheet: Int,
                     transcript: CanonicalTranscript?, transcriptOrigin: Double, maximumFrameWidth: Int,
                     format: StripImageFormat, contentKey: String, evidenceKey: String) throws -> InspectionPacket {
        guard !evidence.isEmpty else { throw WatchthroughFailure(.operation, "inspection resolved to no decoded frames") }
        var cells: [PacketCell] = []
        for (index, point) in evidence.enumerated() {
            let start = index == 0 ? min(rangeStart, point.pts) : (evidence[index - 1].pts + point.pts) / 2
            let end = index == evidence.count - 1 ? max(rangeEnd, point.pts.nextUp) : (point.pts + evidence[index + 1].pts) / 2
            cells.append(PacketCell(index: index, ordinal: point.ordinal, ptsSeconds: point.pts,
                intervalStartSeconds: start, intervalEndSeconds: end, timestamp: CLIParser.formatTime(point.pts),
                caption: "", framePath: "frames/\(point.url.lastPathComponent)",
                ordinalBasis: point.ordinal != nil ? "decoded-global" : (point.localOrdinal != nil ? "decoded-local-range" : "timestamp-only"),
                localOrdinal: point.localOrdinal))
        }
        var warnings: [String] = []
        if let transcript {
            let aligned = TranscriptTimeline.alignedToDecodedPTS(transcript, firstPTS: transcriptOrigin)
            cells = TranscriptCaptions.assign(aligned, to: cells)
            warnings += aligned.warnings
        } else {
            warnings.append("No transcript captions attached; inspect transcript when speech evidence is needed.")
        }
        let gaps = zip(evidence, evidence.dropFirst()).map { max(0, $1.pts - $0.pts) }
        var packet = InspectionPacket(selector: selector, sourcePath: source.path,
            rangeStartSeconds: min(rangeStart, evidence.first!.pts), rangeEndSeconds: max(rangeEnd, evidence.last!.pts.nextUp),
            sampling: sampling, cellsPerSheet: cellsPerSheet, largestGapSeconds: gaps.max() ?? 0,
            timingPrecision: transcript?.timingPrecision ?? .none, cells: cells, sheets: [], warnings: unique(warnings),
            contentFingerprint: contentKey, evidenceFingerprint: evidenceKey, maximumFrameWidth: maximumFrameWidth)
        if cells.count > 1 {
            let sheets = try StripRenderer.render(cells: cells, framesBaseURL: directory, destinationDirectory: directory,
                basename: "strip", options: StripRenderOptions(maximumCellsPerSheet: cellsPerSheet, format: format))
            packet.sheets = sheets.map(\.lastPathComponent)
        }
        try PacketMarkdown.write(packet, to: directory.appendingPathComponent("packet.md"))
        var fingerprints: [String: String] = [:]
        for relative in Set(packet.cells.map(\.framePath) + packet.sheets + ["packet.md"]) {
            fingerprints[relative] = try FileSHA256.hexDigest(of: requiredArtifact(relative, under: directory))
        }
        packet.artifactFingerprints = fingerprints
        try StableJSON.write(packet, to: directory.appendingPathComponent("packet.json"))
        return packet
    }
}

// MARK: - Status

extension WatchthroughApplication {
    func status(_ options: StatusOptions) -> StatusResponse {
        if options.analysis != nil { return analysisStatus(options) }
        var details: [String: String] = [
            "version": WatchthroughVersion.current,
            "platform": platformDescription(),
            "config_path": NamedTranscriptAdapter.configURL().path,
            "dotenv_path": WatchthroughCredentials.dotEnvURL().path,
            "library_directory": DurableLibrary.defaultDirectory.path,
        ]
        var warnings: [String] = []
        let artifacts: [String: String] = [:]
        var exit = WatchthroughExit.success

        for tool in ["ffmpeg", "ffprobe"] {
            if let executable = Tooling.find(tool) {
                details[tool] = toolVersion(executable.path, arguments: ["-version"])
                details["\(tool)_path"] = executable.path
            } else {
                details[tool] = "missing"
                warnings.append("Required tool '\(tool)' was not found on PATH.")
                exit = .readiness
            }
        }

        let macParakeet = MacParakeetTranscriber.probe()
        details["macparakeet"] = macParakeet.available ? "available" : "unavailable"
        if let executable = macParakeet.executable { details["macparakeet_path"] = executable }
        if let version = macParakeet.version { details["macparakeet_version"] = version }
        details["macparakeet_speaker_detection"] = macParakeet.supportsSpeakerDetection ? "supported" : "not detected"

        let configURL = NamedTranscriptAdapter.configURL()
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let config = try StableJSON.decode(WatchthroughUserConfig.self, from: configURL)
                details["named_adapters"] = config.transcribers.keys.sorted().joined(separator: ",")
            } catch {
                details["named_adapters"] = "invalid config"
                warnings.append("Transcript adapter config is invalid: \(error.localizedDescription)")
            }
        } else {
            details["named_adapters"] = "none"
        }

        details["elevenlabs_credential"] = "not probed; resolved only for explicit Scribe transcription"

        if let ytDLP = Tooling.find("yt-dlp") {
            details["yt_dlp"] = toolVersion(ytDLP.path, arguments: ["--version"])
            details["yt_dlp_path"] = ytDLP.path
        } else {
            details["yt_dlp"] = "not detected (optional)"
        }
        if let runtime = detectedYouTubeJavaScriptRuntime() {
            details["youtube_js_runtime"] = runtime.version
            details["youtube_js_runtime_path"] = runtime.path
        } else {
            details["youtube_js_runtime"] = "not detected (optional)"
        }

        warnings = unique(warnings)
        let result = CommandResult(
            ok: exit == .success,
            command: "status",
            analysis: options.analysis?.standardizedFileURL.path,
            artifacts: artifacts,
            details: details,
            warnings: warnings
        )
        var human = [
            "watchthrough \(WatchthroughVersion.current) on \(details["platform"] ?? "unknown platform")",
            "FFmpeg: \(details["ffmpeg"] ?? "missing")",
            "FFprobe: \(details["ffprobe"] ?? "missing")",
            "MacParakeet: \(details["macparakeet"] ?? "unavailable")",
            "Named adapters: \(details["named_adapters"] ?? "none")",
            "ElevenLabs: \(details["elevenlabs_credential"] ?? "not configured (optional)")",
            "YouTube tools: yt-dlp \(details["yt_dlp"] ?? "not detected (optional)"), JavaScript \(details["youtube_js_runtime"] ?? "not detected (optional)")",
        ]
        if options.analysis != nil {
            human.append("Analysis: \(details["analysis_state"] ?? "invalid")")
        }
        human += warnings.map { "Warning: \($0)" }
        return StatusResponse(response: ApplicationResponse(result: result, human: human), exit: exit)
    }
    func analysisStatus(_ options: StatusOptions) -> StatusResponse {
        let analysis = options.analysis!.standardizedFileURL.resolvingSymlinksInPath()
        var details: [String: String] = ["version": WatchthroughVersion.current, "analysis": analysis.path]
        var artifacts: [String: String] = [:]
        var warnings: [String] = []
        var exit = WatchthroughExit.success
        do {
            let lockURL = siblingLock(for: analysis)
            try PathSafety.validateAnalysisLock(lockURL, for: analysis)
            let activity = preparationLockActivity(at: lockURL)
            let temporary = incompleteTemporaryArtifacts(around: analysis)
            details["preparation_lock"] = activity
            details["incomplete_temporary_artifacts"] = temporary.isEmpty ? "none" : temporary.joined(separator: ",")
            if activity == "active" {
                details["analysis_state"] = "preparing"
                warnings.append("An analysis stage is active; poll its existing process.")
                exit = .operation
            } else if !FileManager.default.fileExists(atPath: analysis.path) {
                details["analysis_state"] = activity != "not active" ? "invalid" : (temporary.isEmpty ? "missing" : "incomplete")
                exit = .operation
            } else {
                try PathSafety.validateExistingAnalysisRoot(analysis)
                let lock = try ExclusiveFileLock.acquireShared(at: lockURL)
                defer { lock.unlock() }
                let context = try loadAnalysis(at: analysis, verifyFullHash: options.verify)
                details.merge(stageDetails(context.manifest)) { _, new in new }
                details["analysis_state"] = "complete and reusable"
                details["source_sha256"] = context.manifest.source.sha256
                details["validation"] = options.verify ? "full source SHA256 and referenced artifact contents" : "source size and high precision modification time; referenced artifact existence"
                artifacts = analysisArtifacts(manifest: context.manifest, analysis: analysis)
                warnings += context.manifest.warnings
                if !temporary.isEmpty { warnings.append("Incomplete stage artifacts are preserved for recovery.") }
            }
        } catch let failure as WatchthroughFailure where failure.message.contains("already being written") {
            details["analysis_state"] = "preparing"
            details["preparation_lock"] = "active"
            exit = .operation
        } catch {
            details["analysis_state"] = "invalid"
            warnings.append(errorMessage(error))
            exit = .operation
        }
        return StatusResponse(response: ApplicationResponse(result: CommandResult(ok: exit == .success, command: "status",
            analysis: analysis.path, artifacts: artifacts, details: details, warnings: unique(warnings)),
            human: ["Analysis: \(details["analysis_state"] ?? "invalid")"] + warnings), exit: exit)
    }

    func analysisArtifacts(manifest: PreparationManifest, analysis: URL) -> [String: String] {
        var result = ["manifest": analysis.appendingPathComponent("manifest.json").path]
        let paths: [String: String?] = ["transcript": manifest.transcript.path, "transcript_text": manifest.transcript.textPath,
            "overview": manifest.visual.overviewPacketPath, "events": manifest.visual.eventsPath, "frame_index": manifest.visual.frameIndexPath]
        for (key, path) in paths {
            if let path, let url = resolveRelative(path, under: analysis) { result[key] = url.path }
        }
        return result
    }

    func stageDetails(_ manifest: PreparationManifest) -> [String: String] {
        var details: [String: String] = [
            "metadata_state": "ready",
            "transcript_state": manifest.transcript.available ? "ready" : (manifest.transcript.state ?? "unavailable"),
            "transcript_provider": manifest.transcript.provider ?? "unavailable",
            "timing_precision": manifest.transcript.timingPrecision.rawValue,
            "timing_precision_scope": "transcript",
            "overview_state": manifest.visual.overviewPacketPath.isEmpty ? "deferred" : "ready",
            "events_state": manifest.visual.eventsPath.isEmpty ? "deferred" : "ready",
            "frame_index_state": manifest.visual.frameIndexPath.isEmpty ? "deferred" : "ready",
            "duration_seconds": decimal(manifest.media.durationSeconds),
            "decoded_frames": manifest.visual.frameIndexPath.isEmpty ? "not indexed" : String(manifest.media.frameCount),
            "overview_frames": String(manifest.visual.overviewFrames),
            "visual_change_candidates": String(manifest.visual.eventCount),
            "library_directory": DurableLibrary.defaultDirectory.path,
        ]
        if let bytes = manifest.transcript.textBytes { details["transcript_text_bytes"] = String(bytes) }
        if let tokens = manifest.transcript.approximateTokens { details["transcript_approximate_tokens"] = String(tokens) }
        return details
    }


}

// MARK: - Analysis loading and validation

private extension WatchthroughApplication {
    func loadAnalysis(at analysis: URL, verifyFullHash: Bool) throws -> AnalysisContext {
        try PathSafety.validateExistingAnalysisRoot(analysis)
        guard let manifest = try ManifestStore.read(from: analysis.appendingPathComponent("manifest.json")),
              manifest.schema == WatchthroughVersion.manifestSchema,
              [WatchthroughVersion.current, "0.1.0"].contains(manifest.toolVersion), manifest.state == "complete" else {
            throw WatchthroughFailure(.operation, "analysis manifest is missing, incomplete, or incompatible")
        }
        guard manifest.media.durationSeconds.isFinite, manifest.media.durationSeconds > 0,
              manifest.media.width > 0, manifest.media.height > 0,
              manifest.media.firstPTS.isFinite, manifest.media.lastPTS.isFinite, manifest.media.lastPTS >= manifest.media.firstPTS else {
            throw WatchthroughFailure(.operation, "analysis media metadata is invalid")
        }
        let source = try SourceInspector.validate(URL(fileURLWithPath: manifest.source.path))
        if verifyFullHash {
            let current = try SourceInspector.record(for: source)
            guard current.sha256 == manifest.source.sha256 && current.sizeBytes == manifest.source.sizeBytes else {
                throw WatchthroughFailure(.operation, "analysis source identity no longer matches the current file")
            }
        } else { try verifySourceMetadata(source, stillMatches: manifest.source) }
        for path in [manifest.visual.frameIndexPath, manifest.visual.overviewPacketPath, manifest.visual.eventsPath] where !path.isEmpty {
            _ = try requiredArtifact(path, under: analysis)
        }
        if manifest.transcript.available {
            guard let path = manifest.transcript.path, let text = manifest.transcript.textPath else {
                throw WatchthroughFailure(.operation, "manifest marks transcript ready without canonical and clean text paths")
            }
            _ = try requiredArtifact(path, under: analysis)
            // A valid silent transcript may have a zero-byte clean text file.
            guard let textURL = resolveRelative(text, under: analysis), PathSafety.isRegularOwnedFile(textURL) else {
                throw WatchthroughFailure(.operation, "canonical transcript text is missing or unsafe")
            }
            if let raw = manifest.transcript.rawPath { _ = try requiredArtifact(raw, under: analysis) }
        }
        if verifyFullHash {
            _ = try readTranscript(manifest, under: analysis)
            if !manifest.visual.frameIndexPath.isEmpty {
                let frames = try FrameIndexTSV.read(from: requiredArtifact(manifest.visual.frameIndexPath, under: analysis))
                guard frames.count == manifest.media.frameCount,
                      nearlyEqual(frames.first?.ptsSeconds, manifest.visual.indexedFirstPTS ?? manifest.media.firstPTS),
                      nearlyEqual(frames.last?.ptsSeconds, manifest.visual.indexedLastPTS ?? manifest.media.lastPTS) else {
                    throw WatchthroughFailure(.operation, "frame index count or decoded endpoints do not match manifest")
                }
            }
            if !manifest.visual.overviewPacketPath.isEmpty {
                let url = try requiredArtifact(manifest.visual.overviewPacketPath, under: analysis)
                let packet = try loadPacket(at: url, root: url.deletingLastPathComponent())
                guard packet.cells.count == manifest.visual.overviewFrames else { throw WatchthroughFailure(.operation, "overview count does not match manifest") }
            }
            if !manifest.visual.eventsPath.isEmpty {
                let events = try decodeEvents(at: requiredArtifact(manifest.visual.eventsPath, under: analysis))
                guard events.events.count == manifest.visual.eventCount else { throw WatchthroughFailure(.operation, "event count does not match manifest") }
            }
        }
        return AnalysisContext(analysis: analysis, source: source, manifest: manifest)
    }

    func readTranscript(_ manifest: PreparationManifest, under analysis: URL) throws -> CanonicalTranscript? {
        guard manifest.transcript.available, let relative = manifest.transcript.path else { return nil }
        let url = try requiredArtifact(relative, under: analysis)
        let data = try Data(contentsOf: url)
        if let expected = manifest.transcript.fingerprint,
           digestFingerprint(label: "transcript", data: data) != expected {
            throw WatchthroughFailure(.operation, "canonical transcript content no longer matches its fingerprint")
        }
        if let textPath = manifest.transcript.textPath, let expected = manifest.transcript.textFingerprint {
            let textURL = try requiredArtifact(textPath, under: analysis)
            guard digestFingerprint(label: "transcript-text", data: try Data(contentsOf: textURL)) == expected else {
                throw WatchthroughFailure(.operation, "clean transcript text no longer matches its fingerprint")
            }
        }
        let transcript = try StableJSON.decode(CanonicalTranscript.self, from: data)
        guard transcript.schema == WatchthroughVersion.transcriptSchema,
              transcript.provider == manifest.transcript.provider,
              transcript.timingPrecision == manifest.transcript.timingPrecision else {
            throw WatchthroughFailure(.operation, "canonical transcript does not match its manifest summary")
        }
        return transcript
    }

    func loadPacket(at url: URL, root: URL) throws -> InspectionPacket {
        guard nonemptyFile(url) else {
            throw WatchthroughFailure(.operation, "inspection packet is missing: \(url.path)")
        }
        let packet: InspectionPacket
        do {
            packet = try StableJSON.decode(InspectionPacket.self, from: url)
        } catch {
            throw WatchthroughFailure(.operation, "inspection packet is invalid: \(error.localizedDescription)")
        }
        guard WatchthroughVersion.supportedPacketSchemas.contains(packet.schema), !packet.cells.isEmpty else {
            throw WatchthroughFailure(.operation, "inspection packet has an unsupported schema or no frames")
        }
        try InspectionPacketValidation.validateStructure(packet)
        guard nonemptyFile(root.appendingPathComponent("packet.md")) else {
            throw WatchthroughFailure(.operation, "inspection packet Markdown is missing")
        }
        for cell in packet.cells {
            guard let frame = resolveRelative(cell.framePath, under: root), nonemptyFile(frame) else {
                throw WatchthroughFailure(.operation, "inspection packet references a missing or unsafe frame")
            }
        }
        for sheet in packet.sheets {
            guard let image = resolveRelative(sheet, under: root), nonemptyFile(image) else {
                throw WatchthroughFailure(.operation, "inspection packet references a missing or unsafe strip")
            }
        }
        if let fingerprints = packet.artifactFingerprints {
            let expectedPaths = Set(packet.cells.map(\.framePath) + packet.sheets + ["packet.md"])
            guard Set(fingerprints.keys) == expectedPaths else {
                throw WatchthroughFailure(.operation, "inspection artifact checksum inventory is incomplete or inconsistent")
            }
            for relative in expectedPaths {
                let artifact = try requiredArtifact(relative, under: root)
                guard try FileSHA256.hexDigest(of: artifact) == fingerprints[relative] else {
                    throw WatchthroughFailure(.operation, "inspection artifact checksum mismatch: \(relative)")
                }
            }
        } else if packet.schema == WatchthroughVersion.packetSchema {
            throw WatchthroughFailure(.operation, "inspection artifact checksums are missing from this generated packet; preserve it and request a new packet layout")
        }
        return packet
    }

    func decodeEvents(at url: URL) throws -> EventIndex {
        do {
            let events = try StableJSON.decode(EventIndex.self, from: url)
            guard events.schema == "watchthrough.events.v1" else {
                throw WatchthroughFailure(.operation, "visual event index has an unsupported schema")
            }
            return events
        } catch let failure as WatchthroughFailure {
            throw failure
        } catch {
            throw WatchthroughFailure(.operation, "visual event index is invalid: \(error.localizedDescription)")
        }
    }
}

// MARK: - Small helpers

struct ApplicationResponse {
    var result: CommandResult
    var human: [String]
}

struct StatusResponse {
    var response: ApplicationResponse
    var exit: WatchthroughExit
}

private struct AnalysisContext {
    var analysis: URL
    var source: URL
    var manifest: PreparationManifest
}

private struct PacketEvidenceFrame {
    var pts: Double
    var url: URL
    var ordinal: Int?
    var localOrdinal: Int?
}

private final class TranscriptSession {
    private var capability: MacParakeetCapability?
    func macParakeet() -> MacParakeetCapability {
        if let capability { return capability }
        let result = MacParakeetTranscriber.probe()
        capability = result
        return result
    }
}

private struct TranscriptPreparation {
    var transcript: CanonicalTranscript?
    var summary: TranscriptSummary
    var warnings: [String]

    static func unavailable(warnings: [String]) -> TranscriptPreparation {
        TranscriptPreparation(
            transcript: nil,
            summary: TranscriptSummary(available: false),
            warnings: warnings
        )
    }
}

private extension WatchthroughApplication {
    func progress(_ message: String) {
        FileHandle.standardError.write(Data(("watchthrough: \(message)\n").utf8))
    }

    func present(_ response: ApplicationResponse, asJSON: Bool) throws {
        if asJSON {
            try emit(response.result)
        } else {
            print(response.human.joined(separator: "\n"))
        }
    }

    func emit(_ result: CommandResult) throws {
        do {
            FileHandle.standardOutput.write(try StableJSON.encode(result))
        } catch {
            throw WatchthroughFailure(.operation, "could not encode command result: \(error.localizedDescription)")
        }
    }

    func requiredArtifact(_ relativePath: String, under root: URL) throws -> URL {
        guard let url = resolveRelative(relativePath, under: root), nonemptyFile(url) else {
            throw WatchthroughFailure(.operation, "analysis references a missing or unsafe artifact: \(relativePath)")
        }
        return url
    }

    func verifySourceMetadata(_ source: URL, stillMatches record: SourceRecord) throws {
        guard try SourceInspector.metadataMatches(source, record: record) else {
            throw WatchthroughFailure(.operation, "source metadata changed after analysis preparation; use status --verify for a full content check, then prepare --refresh if needed")
        }
    }

    func validatedRefreshOwner(at destination: URL, source: URL) throws -> PreparationManifest {
        let refusal = WatchthroughFailure(
            .operation,
            "refuse to refresh an unrelated, incomplete, or incompatible analysis directory"
        )
        do {
            let manifestURL = destination.appendingPathComponent("manifest.json")
            guard PathSafety.isRegularOwnedFile(manifestURL),
                  let manifest = try ManifestStore.read(from: manifestURL),
                  manifest.schema == WatchthroughVersion.manifestSchema,
                  [WatchthroughVersion.current, "0.1.0"].contains(manifest.toolVersion),
                  manifest.state == "complete",
                  URL(fileURLWithPath: manifest.source.path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath() == source else {
                throw refusal
            }
            try PathSafety.validateRefreshTree(at: destination, manifest: manifest)
            return manifest
        } catch {
            if let failure = error as? WatchthroughFailure,
               failure.message.contains("unrecognized entry") {
                throw failure
            }
            throw refusal
        }
    }

    func inspectionIdentity(selector: String, sampling: String, cells: Int) -> String {
        let canonical = "\(WatchthroughVersion.packetSchema)|\(selector)|\(sampling)|\(cells)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        let slugScalars = selector.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let slug = String(slugScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(42)
        return "\(slug.isEmpty ? "inspection" : String(slug))-\(digest)"
    }

    func samplingDescription(_ interval: SamplingInterval) -> String {
        switch interval {
        case let .seconds(value): return "every \(decimal(value))s"
        case let .frames(value): return "every \(value) decoded frames"
        }
    }

    func samplingIdentity(_ interval: SamplingInterval) -> String {
        switch interval {
        case let .seconds(value):
            return "seconds-bits:\(String(value.bitPattern, radix: 16))"
        case let .frames(value):
            return "frames:\(value)"
        }
    }

    func siblingLock(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).lock")
    }

    func preparationLockActivity(at url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "not active" }
        do {
            let lock = try ExclusiveFileLock.acquireShared(at: url)
            lock.unlock()
            return "not active"
        } catch let failure as WatchthroughFailure where failure.message.contains("already being written") {
            return "active"
        } catch {
            return "unknown"
        }
    }

    func incompleteTemporaryArtifacts(around analysis: URL) -> [String] {
        var found: [String] = []
        let parent = analysis.deletingLastPathComponent()
        let siblingPrefix = ".watchthrough-\(analysis.lastPathComponent).tmp-"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            found += names.filter { $0.hasPrefix(siblingPrefix) }
        }
        for directory in ["inspections", "transcript"] {
            let url = analysis.appendingPathComponent(directory, isDirectory: true)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                found += names.filter { $0.hasPrefix(".watchthrough-") && $0.contains(".tmp-") }
                    .map { "\(directory)/\($0)" }
            }
        }
        return found.sorted()
    }

    func toolVersion(_ executable: String, arguments: [String]) -> String {
        (try? Tooling.version(of: executable, arguments: arguments)) ?? "available (version unavailable)"
    }

    func detectedYouTubeJavaScriptRuntime() -> (name: String, path: String, version: String)? {
        for name in ["deno", "node", "qjs"] {
            guard let executable = Tooling.find(name) else { continue }
            let rawVersion = toolVersion(executable.path, arguments: ["--version"])
            let displayVersion = rawVersion.lowercased().hasPrefix(name)
                ? rawVersion
                : "\(name) \(rawVersion)"
            return (
                name,
                executable.path,
                displayVersion
            )
        }
        return nil
    }

    func platformDescription() -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown architecture"
        #endif
        return "\(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)"
    }

    func safeExtension(_ raw: String) -> String {
        let value = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return value.isEmpty ? "json" : value
    }

    func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

private func resolveRelative(_ relativePath: String, under root: URL) -> URL? {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = canonicalRoot
        .appendingPathComponent(relativePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
    guard candidate.path.hasPrefix(prefix) else { return nil }
    return candidate
}

private func nonemptyFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
        return false
    }
    return values.isRegularFile == true && (values.fileSize ?? 0) > 0
}

private func nearlyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) <= tolerance
}

private func decimal(_ value: Double) -> String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

private func errorMessage(_ error: Error) -> String {
    if let failure = error as? WatchthroughFailure { return failure.message }
    return error.localizedDescription
}

private func autoTranscriptFailure(_ route: String, _ error: Error) -> String {
    let firstLine = errorMessage(error)
        .components(separatedBy: .newlines)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "unknown failure"
    let concise = String(firstLine.prefix(240))
    return "Automatic \(route) transcription failed; trying the next local route. \(concise)"
}
