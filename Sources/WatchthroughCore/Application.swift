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

        case let .status(options):
            let response = status(options)
            try present(response.response, asJSON: invocation.json)
            return response.exit
        }
    }
}

// MARK: - Preparation

private extension WatchthroughApplication {
    func prepare(_ options: PrepareOptions) throws -> ApplicationResponse {
        let source = try SourceInspector.validate(options.source)
        let destination = try PathSafety.preparationOutput(
            options.output ?? URL(fileURLWithPath: source.path + ".watchthrough", isDirectory: true),
            source: source
        )

        let lockURL = siblingLock(for: destination)
        try PathSafety.validateAnalysisLock(lockURL, for: destination)
        let lock = try ExclusiveFileLock.acquire(at: lockURL)
        defer { lock.unlock() }

        let manifestURL = destination.appendingPathComponent("manifest.json")
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        let refreshOwner = destinationExists && options.refresh
            ? try validatedRefreshOwner(at: destination, source: source)
            : nil

        progress("Recording source identity...")
        let sourceRecord = try SourceInspector.record(for: source)
        let config = try preparationConfig(
            transcriber: options.transcriber,
            source: source
        )

        if let refreshOwner,
           (refreshOwner.source.sha256 != sourceRecord.sha256
            || refreshOwner.source.sizeBytes != sourceRecord.sizeBytes) {
            throw WatchthroughFailure(
                .operation,
                "refuse to refresh analysis because it is owned by different source content"
            )
        }

        if destinationExists, !options.refresh {
            if let manifest = try ManifestStore.reusable(
                at: manifestURL,
                matching: sourceRecord,
                config: config,
                artifactRoot: destination
            ), manifest.source.path == source.path {
                return preparationResponse(manifest: manifest, analysis: destination, reused: true)
            }
            throw WatchthroughFailure(
                .operation,
                "analysis output already exists but does not match this source and configuration; choose another --out path, or use --refresh only for a complete analysis owned by this source"
            )
        }

        let staging = try ArtifactStaging.temporarySibling(for: destination)
        do {
            _ = try buildAnalysis(
                source: source,
                sourceRecord: sourceRecord,
                config: config,
                staging: staging
            )
            guard let validated = try ManifestStore.reusable(
                at: staging.appendingPathComponent("manifest.json"),
                matching: sourceRecord,
                config: config,
                artifactRoot: staging
            ) else {
                throw WatchthroughFailure(.operation, "completed analysis failed its reuse validation")
            }

            if destinationExists {
                try ArtifactStaging.replace(staging, at: destination) { candidate in
                    guard try ManifestStore.reusable(
                        at: candidate.appendingPathComponent("manifest.json"),
                        matching: sourceRecord,
                        config: config,
                        artifactRoot: candidate
                    ) != nil else {
                        throw WatchthroughFailure(.operation, "refreshed analysis failed validation")
                    }
                }
            } else {
                try ArtifactStaging.promote(staging, to: destination)
            }
            return preparationResponse(manifest: validated, analysis: destination, reused: false)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func buildAnalysis(
        source: URL,
        sourceRecord: SourceRecord,
        config: PreparationConfig,
        staging: URL
    ) throws -> PreparationManifest {
        let startedAt = ISO8601Clock.now()
        let ffmpeg = try Tooling.require("ffmpeg")
        let ffprobe = try Tooling.require("ffprobe")
        progress("Indexing decoded frames...")
        let probed = try MediaProbe.probe(source, ffprobe: ffprobe.path)

        let frameIndexPath = "visual/frame-index.tsv"
        try FrameIndexTSV.write(
            probed.frames,
            to: staging.appendingPathComponent(frameIndexPath)
        )

        var tools: [String: String] = [
            "watchthrough": WatchthroughVersion.current,
            "ffmpeg": toolVersion(ffmpeg.path, arguments: ["-version"]),
            "ffprobe": toolVersion(ffprobe.path, arguments: ["-version"]),
        ]
        progress("Resolving transcript (\(config.transcriber))...")
        let transcript = try prepareTranscript(
            requested: config.transcriber,
            source: source,
            media: probed.info,
            staging: staging,
            ffmpeg: ffmpeg.path,
            tools: &tools
        )

        progress("Scanning for visual changes...")
        let events = try VisualAnalyzer.scan(
            source: source,
            media: probed.info,
            sampleLimit: config.visualSampleLimit,
            ffmpegPath: ffmpeg.path
        )
        let eventsPath = "visual/events.json"
        try StableJSON.write(events, to: staging.appendingPathComponent(eventsPath))

        progress("Building broad visual overview...")
        let overviewCount = min(90, max(12, Int(ceil(probed.info.durationSeconds / 20)) + 1))
        let overviewFrames = try FrameSelector.overview(maxCount: overviewCount, in: probed.frames)
        let overviewDirectory = staging
            .appendingPathComponent("visual", isDirectory: true)
            .appendingPathComponent("overview", isDirectory: true)
        _ = try buildPacket(
            source: source,
            frameIndex: probed.frames,
            directory: overviewDirectory,
            selector: "overview",
            selected: overviewFrames,
            rangeStart: probed.info.firstPTS,
            rangeEnd: probed.info.lastPTS.nextUp,
            sampling: "uniform overview (target \(overviewCount))",
            cellsPerSheet: 15,
            transcript: transcript.transcript,
            warnings: transcript.transcript == nil
                ? ["No timed transcript was available for overview captions."]
                : [],
            maximumFrameWidth: 1_440,
            ffmpeg: ffmpeg.path
        )

        progress("Finalizing analysis...")
        try verifySourceMetadata(source, stillMatches: sourceRecord)

        let overviewPacketPath = "visual/overview/packet.json"
        let visualSummary = VisualSummary(
            frameIndexPath: frameIndexPath,
            overviewPacketPath: overviewPacketPath,
            eventsPath: eventsPath,
            overviewFrames: overviewFrames.count,
            largestOverviewGapSeconds: FrameSelector.largestGap(in: overviewFrames),
            eventCount: events.events.count,
            scanFPS: events.scanFPS
        )
        let warnings = unique(transcript.warnings + (events.events.isEmpty
            ? ["The visual scan found no visual-change candidates; the uniform overview remains available."]
            : []))
        let manifest = PreparationManifest(
            createdAt: startedAt,
            completedAt: ISO8601Clock.now(),
            source: sourceRecord,
            media: probed.info,
            config: config,
            transcript: transcript.summary,
            visual: visualSummary,
            tools: tools,
            warnings: warnings
        )
        try ManifestStore.write(manifest, to: staging.appendingPathComponent("manifest.json"))
        return manifest
    }

    func prepareTranscript(
        requested: String,
        source: URL,
        media: MediaInfo,
        staging: URL,
        ffmpeg: String,
        tools: inout [String: String]
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
                    warnings: sidecar.transcript.warnings
                )
            }
            throw WatchthroughFailure(.readiness, "no supported source-adjacent transcript sidecar was found")
        }

        if requested == "macparakeet" {
            let capability = MacParakeetTranscriber.probe()
            if capability.available {
                if let version = capability.version {
                    tools["macparakeet"] = version
                } else if let executable = capability.executable {
                    tools["macparakeet"] = executable
                }
                let run = try MacParakeetTranscriber.transcribe(input: source)
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
                        warnings: fallbackWarnings + sidecar.transcript.warnings
                    )
                }
            } catch {
                fallbackWarnings.append(autoTranscriptFailure("sidecar", error))
            }

            let capability = MacParakeetTranscriber.probe()
            if capability.available {
                do {
                    if let version = capability.version {
                        tools["macparakeet"] = version
                    } else if let executable = capability.executable {
                        tools["macparakeet"] = executable
                    }
                    let run = try MacParakeetTranscriber.transcribe(input: source)
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
            let transcriptDirectory = staging.appendingPathComponent("transcript", isDirectory: true)
            try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
            let audio = transcriptDirectory.appendingPathComponent(".scribe-audio.flac")
            defer { try? FileManager.default.removeItem(at: audio) }
            try ProcessRunner.run(
                ffmpeg,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                    "-i", source.path,
                    "-map", "0:a:0", "-vn", "-sn", "-dn",
                    "-ac", "1", "-ar", "16000", "-c:a", "flac", "-compression_level", "5",
                    audio.path,
                ]
            ).requireSuccess("ffmpeg could not extract speech audio for Scribe")
            let run = try ElevenLabsScribeV2.transcribe(audio: audio)
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
        let directory = staging.appendingPathComponent("transcript", isDirectory: true)
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
            warnings: run.transcript.warnings
        )
    }

    func persistTranscript(
        _ transcript: CanonicalTranscript,
        raw: Data,
        rawExtension: String,
        under staging: URL,
        warnings: [String]
    ) throws -> TranscriptPreparation {
        let canonicalPath = "transcript/transcript.json"
        let textPath = "transcript/transcript.txt"
        let rawPath = "transcript/raw-provider-response.\(rawExtension)"
        try TranscriptFiles.writeCanonical(transcript, to: staging.appendingPathComponent(canonicalPath))
        try TranscriptFiles.writeText(transcript, to: staging.appendingPathComponent(textPath))
        try TranscriptFiles.preserveRawResponse(raw, at: staging.appendingPathComponent(rawPath))
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
                rawPath: rawPath
            ),
            warnings: unique(warnings + transcript.warnings)
        )
    }

    func preparationConfig(
        transcriber: String,
        source: URL
    ) throws -> PreparationConfig {
        let fingerprint: String
        switch transcriber {
        case "none":
            fingerprint = "none"
        case "scribe":
            fingerprint = "elevenlabs:scribe_v2"
        case "sidecar":
            if let sidecar = try TranscriptSidecar.discover(for: source) {
                fingerprint = try fileFingerprint(label: "sidecar", url: sidecar.url)
            } else {
                fingerprint = "sidecar:missing"
            }
        case "macparakeet":
            fingerprint = macParakeetFingerprint()
        case "auto":
            fingerprint = autoTranscriptFingerprint(source: source)
        default:
            if transcriber.hasPrefix("command:") {
                let name = String(transcriber.dropFirst("command:".count))
                if let definition = try configuredAdapterDefinition(named: name) {
                    fingerprint = try adapterFingerprint(name: name, definition: definition)
                } else {
                    fingerprint = "command:\(name):missing"
                }
            } else {
                fingerprint = "unsupported"
            }
        }
        let runtimeFingerprint = try requiredRuntimeFingerprint()
        let combined = digestFingerprint(
            label: "preparation",
            data: Data("\(fingerprint)|\(runtimeFingerprint)".utf8)
        )
        return PreparationConfig(
            transcriber: transcriber,
            transcriptInputFingerprint: combined
        )
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

    func autoTranscriptFingerprint(source: URL) -> String {
        var identities = TranscriptSidecar.existingCandidateURLs(for: source).map { url in
            (try? fileFingerprint(label: "sidecar:\(url.lastPathComponent)", url: url))
                ?? "sidecar:\(url.lastPathComponent):unreadable"
        }
        identities.append(macParakeetFingerprint())

        let config = NamedTranscriptAdapter.configURL()
        if FileManager.default.fileExists(atPath: config.path) {
            identities.append(
                (try? fileFingerprint(label: "adapter-config", url: config))
                    ?? "adapter-config:unreadable"
            )
            if let definition = try? configuredAdapterDefinition(named: "default"),
               let identity = try? adapterFingerprint(name: "default", definition: definition) {
                identities.append(identity)
            }
        }
        if identities.isEmpty { identities.append("visual-only") }
        return digestFingerprint(
            label: "auto-transcript-routes",
            data: Data(identities.joined(separator: "|").utf8)
        )
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

    func requiredRuntimeFingerprint() throws -> String {
        var versions: [String] = []
        for name in ["ffmpeg", "ffprobe"] {
            let executable = try Tooling.require(name)
            let version = try Tooling.version(of: executable.path, arguments: ["-version"])
            versions.append("\(name):\(version)")
        }
        return digestFingerprint(label: "media-tools", data: Data(versions.joined(separator: "|").utf8))
    }

    func digestFingerprint(label: String, data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(label):\(digest)"
    }

    func preparationResponse(
        manifest: PreparationManifest,
        analysis: URL,
        reused: Bool
    ) -> ApplicationResponse {
        var artifacts: [String: String] = [
            "manifest": analysis.appendingPathComponent("manifest.json").path,
            "overview": resolveRelative(manifest.visual.overviewPacketPath, under: analysis)?.path ?? "",
            "events": resolveRelative(manifest.visual.eventsPath, under: analysis)?.path ?? "",
            "frame_index": resolveRelative(manifest.visual.frameIndexPath, under: analysis)?.path ?? "",
        ]
        if let transcriptPath = manifest.transcript.path,
           let absolute = resolveRelative(transcriptPath, under: analysis) {
            artifacts["transcript"] = absolute.path
        }
        if let textPath = manifest.transcript.textPath,
           let absolute = resolveRelative(textPath, under: analysis) {
            artifacts["transcript_text"] = absolute.path
        }
        artifacts = artifacts.filter { !$0.value.isEmpty }
        let provider = manifest.transcript.provider ?? "unavailable"
        let result = CommandResult(
            ok: true,
            command: "prepare",
            analysis: analysis.path,
            reused: reused,
            artifacts: artifacts,
            details: [
                "transcript_provider": provider,
                "timing_precision": manifest.transcript.timingPrecision.rawValue,
                "visual_change_candidates": String(manifest.visual.eventCount),
                "overview_frames": String(manifest.visual.overviewFrames),
            ],
            warnings: manifest.warnings
        )
        var human = [
            reused ? "Reused analysis: \(analysis.path)" : "Prepared analysis: \(analysis.path)",
            "Transcript: \(provider) (\(manifest.transcript.timingPrecision.rawValue) timing)",
            "Overview: \(artifacts["overview"] ?? "unavailable")",
            "Visual-change candidates: \(manifest.visual.eventCount)",
        ]
        human += manifest.warnings.map { "Warning: \($0)" }
        human.append("Next: watchthrough inspect \(shellQuoted(analysis.path)) overview")
        human.append("      watchthrough inspect \(shellQuoted(analysis.path)) events")
        return ApplicationResponse(result: result, human: human)
    }
}

// MARK: - Inspection

private extension WatchthroughApplication {
    func inspect(_ options: InspectOptions) throws -> ApplicationResponse {
        let analysis = options.analysis.standardizedFileURL.resolvingSymlinksInPath()
        try PathSafety.validateExistingAnalysisRoot(analysis)
        let analysisLockURL = siblingLock(for: analysis)
        try PathSafety.validateAnalysisLock(analysisLockURL, for: analysis)
        let analysisLock = try ExclusiveFileLock.acquireShared(at: analysisLockURL)
        defer { analysisLock.unlock() }
        let context = try loadAnalysis(at: analysis, verifyFullHash: false)

        switch options.selector {
        case .overview:
            guard options.every == nil, options.cells == 15 else {
                throw WatchthroughFailure(.usage, "overview is prebuilt; --every and --cells apply only to generated temporal packets")
            }
            let packetURL = try requiredArtifact(context.manifest.visual.overviewPacketPath, under: analysis)
            let packet = try loadPacket(at: packetURL, root: packetURL.deletingLastPathComponent())
            var artifacts: [String: String] = ["packet": packetURL.path]
            let markdown = packetURL.deletingLastPathComponent().appendingPathComponent("packet.md")
            if nonemptyFile(markdown) { artifacts["markdown"] = markdown.path }
            for (index, sheet) in packet.sheets.enumerated() {
                if let url = resolveRelative(sheet, under: packetURL.deletingLastPathComponent()) {
                    artifacts["sheet_\(index + 1)"] = url.path
                }
            }
            return ApplicationResponse(
                result: CommandResult(
                    ok: true,
                    command: "inspect",
                    analysis: analysis.path,
                    reused: true,
                    artifacts: artifacts,
                    details: [
                        "selector": "overview",
                        "frames": String(packet.cells.count),
                        "largest_gap_seconds": decimal(packet.largestGapSeconds),
                    ],
                    warnings: packet.warnings
                ),
                human: [
                    "Overview packet: \(packetURL.path)",
                    "Frames: \(packet.cells.count), largest gap: \(decimal(packet.largestGapSeconds))s",
                ] + packet.warnings.map { "Warning: \($0)" }
            )

        case .events:
            guard options.every == nil, options.cells == 15 else {
                throw WatchthroughFailure(.usage, "events is an index; --every and --cells apply only to generated temporal packets")
            }
            let eventsURL = try requiredArtifact(context.manifest.visual.eventsPath, under: analysis)
            let events = try decodeEvents(at: eventsURL)
            let suggestions = events.events.prefix(10).map { "event:\($0.id)" }.joined(separator: ",")
            return ApplicationResponse(
                result: CommandResult(
                    ok: true,
                    command: "inspect",
                    analysis: analysis.path,
                    reused: true,
                    artifacts: ["events": eventsURL.path],
                    details: [
                        "selector": "events",
                        "visual_change_candidates": String(events.events.count),
                        "suggested_selectors": suggestions,
                    ]
                ),
                human: [
                    "Visual-change candidates: \(events.events.count)",
                    "Index: \(eventsURL.path)",
                    suggestions.isEmpty ? "No event selectors are available." : "Try: \(suggestions)",
                ]
            )

        case .time, .frame:
            guard options.every == nil else {
                throw WatchthroughFailure(.usage, "--every applies to range and event inspections, not a single frame")
            }
            return try generateInspection(options, context: context)

        case .event, .range:
            return try generateInspection(options, context: context)
        }
    }

    func generateInspection(
        _ options: InspectOptions,
        context: AnalysisContext
    ) throws -> ApplicationResponse {
        let frames = context.frames
        guard let firstFrame = frames.first, let lastFrame = frames.last else {
            throw WatchthroughFailure(.operation, "analysis frame index is empty")
        }

        var selected: [FramePoint]
        var rangeStart: Double
        var rangeEnd: Double
        var sampling: String
        var samplingIdentityKey: String

        switch options.selector {
        case let .event(id):
            let eventsURL = try requiredArtifact(context.manifest.visual.eventsPath, under: context.analysis)
            let events = try decodeEvents(at: eventsURL)
            guard let event = events.events.first(where: { $0.id == id }) else {
                throw WatchthroughFailure(.usage, "visual-change candidate '\(id)' does not exist")
            }
            rangeStart = max(firstFrame.ptsSeconds, event.startSeconds - 1)
            rangeEnd = min(lastFrame.ptsSeconds, event.endSeconds + 1)
            let interval = options.every ?? .seconds(0.5)
            selected = try selectFrames(interval: interval, frames: frames, range: rangeStart...max(rangeStart, rangeEnd))
            sampling = samplingDescription(interval)
            samplingIdentityKey = samplingIdentity(interval)

        case let .range(requestedStart, requestedEnd):
            rangeStart = max(firstFrame.ptsSeconds, requestedStart)
            rangeEnd = min(lastFrame.ptsSeconds, requestedEnd)
            guard rangeEnd >= rangeStart else {
                throw WatchthroughFailure(.usage, "inspection range does not overlap the decoded video timeline")
            }
            let interval = options.every ?? .seconds(max(0.5, (rangeEnd - rangeStart) / 59))
            selected = try selectFrames(interval: interval, frames: frames, range: rangeStart...rangeEnd)
            sampling = samplingDescription(interval)
            samplingIdentityKey = samplingIdentity(interval)

        case let .time(seconds):
            guard seconds >= firstFrame.ptsSeconds, seconds <= lastFrame.ptsSeconds,
                  let frame = FrameSelector.nearest(to: seconds, in: frames) else {
                throw WatchthroughFailure(.usage, "timestamp is outside the decoded video timeline")
            }
            selected = [frame]
            rangeStart = max(firstFrame.ptsSeconds, frame.ptsSeconds - 2)
            rangeEnd = min(lastFrame.ptsSeconds, frame.ptsSeconds + 2)
            sampling = "single resolved frame"
            samplingIdentityKey = "single-resolved-frame"

        case let .frame(ordinal):
            guard let frame = FrameSelector.atOrdinal(ordinal, in: frames) else {
                throw WatchthroughFailure(.usage, "decoded frame ordinal \(ordinal) is outside 0...\(max(0, frames.count - 1))")
            }
            selected = [frame]
            rangeStart = max(firstFrame.ptsSeconds, frame.ptsSeconds - 2)
            rangeEnd = min(lastFrame.ptsSeconds, frame.ptsSeconds + 2)
            sampling = "single decoded frame"
            samplingIdentityKey = "single-decoded-frame"

        case .overview, .events:
            throw WatchthroughFailure(.operation, "internal selector routing error")
        }

        if selected.isEmpty,
           let nearest = FrameSelector.nearest(to: (rangeStart + rangeEnd) / 2, in: frames) {
            selected = [nearest]
        }
        guard !selected.isEmpty else {
            throw WatchthroughFailure(.operation, "inspection resolved to no decoded frames")
        }
        guard selected.count <= 300 else {
            throw WatchthroughFailure(
                .usage,
                "inspection would extract \(selected.count) frames; use a coarser --every interval or split the range (maximum 300)"
            )
        }

        let identity = inspectionIdentity(
            selector: options.selectorText,
            sampling: samplingIdentityKey,
            cells: options.cells
        )
        let inspections = try PathSafety.ensureInspectionsDirectory(under: context.analysis)
        let destination = try PathSafety.inspectionDestination(named: identity, under: inspections)
        let lockURL = siblingLock(for: destination)
        try PathSafety.validateInspectionLock(lockURL, under: inspections)
        let lock = try ExclusiveFileLock.acquire(at: lockURL)
        defer { lock.unlock() }

        let existingPacketURL = destination.appendingPathComponent("packet.json")
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                let packet = try loadPacket(at: existingPacketURL, root: destination)
                guard packet.selector == options.selectorText,
                      packet.sampling == sampling,
                      packet.cellsPerSheet == options.cells,
                      packet.sourcePath == context.source.path,
                      packet.timingPrecision == (context.transcript?.timingPrecision ?? .none),
                      nearlyEqual(packet.rangeStartSeconds, rangeStart),
                      nearlyEqual(packet.rangeEndSeconds, max(rangeEnd, rangeStart.nextUp)),
                      nearlyEqual(packet.largestGapSeconds, FrameSelector.largestGap(in: selected)),
                      packet.cells.count == selected.count,
                      zip(packet.cells, selected).enumerated().allSatisfy({ offset, pair in
                          pair.0.index == offset
                              && pair.0.ordinal == pair.1.ordinal
                              && nearlyEqual(pair.0.ptsSeconds, pair.1.ptsSeconds)
                      }) else {
                    throw WatchthroughFailure(.operation, "inspection identity collision")
                }
                return inspectionResponse(
                    packet: packet,
                    packetURL: existingPacketURL,
                    analysis: context.analysis,
                    reused: true
                )
            } catch {
                throw WatchthroughFailure(
                    .operation,
                    "an existing inspection folder is incomplete or invalid: \(destination.path); move it aside before retrying"
                )
            }
        }

        let staging = try ArtifactStaging.temporarySibling(for: destination)
        do {
            progress("Extracting \(selected.count) inspection frames...")
            let packet = try buildPacket(
                source: context.source,
                frameIndex: context.frames,
                directory: staging,
                selector: options.selectorText,
                selected: selected,
                rangeStart: rangeStart,
                rangeEnd: max(rangeEnd, rangeStart.nextUp),
                sampling: sampling,
                cellsPerSheet: options.cells,
                transcript: context.transcript,
                warnings: context.transcript == nil
                    ? ["No timed transcript was available for frame captions."]
                    : [],
                maximumFrameWidth: 1_920,
                ffmpeg: try Tooling.require("ffmpeg").path
            )
            _ = try loadPacket(at: staging.appendingPathComponent("packet.json"), root: staging)
            try ArtifactStaging.promote(staging, to: destination)
            return inspectionResponse(
                packet: packet,
                packetURL: destination.appendingPathComponent("packet.json"),
                analysis: context.analysis,
                reused: false
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func selectFrames(
        interval: SamplingInterval,
        frames: [FramePoint],
        range: ClosedRange<Double>
    ) throws -> [FramePoint] {
        switch interval {
        case let .seconds(seconds):
            return try FrameSelector.everySeconds(
                seconds,
                in: frames,
                range: range,
                maximumCount: 300
            )
        case let .frames(count):
            return try FrameSelector.everyFrames(
                count,
                in: frames,
                range: range,
                maximumCount: 300
            )
        }
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
                    "timing_precision": packet.timingPrecision.rawValue,
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
    func buildPacket(
        source: URL,
        frameIndex: [FramePoint],
        directory: URL,
        selector: String,
        selected: [FramePoint],
        rangeStart: Double,
        rangeEnd: Double,
        sampling: String,
        cellsPerSheet: Int,
        transcript: CanonicalTranscript?,
        warnings: [String],
        maximumFrameWidth: Int,
        ffmpeg: String
    ) throws -> InspectionPacket {
        guard !selected.isEmpty else {
            throw WatchthroughFailure(.operation, "cannot build an empty inspection packet")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let extracted = try FrameExtractor.extract(
            source: source,
            selectedFrames: selected,
            frameIndex: frameIndex,
            destinationDirectory: framesDirectory,
            maximumWidth: maximumFrameWidth,
            ffmpegPath: ffmpeg
        )
        let extractedByOrdinal = Dictionary(uniqueKeysWithValues: extracted.map { ($0.ordinal, $0.url) })

        let ordered = selected.sorted {
            $0.ptsSeconds == $1.ptsSeconds ? $0.ordinal < $1.ordinal : $0.ptsSeconds < $1.ptsSeconds
        }
        var cells: [PacketCell] = []
        var packetWarnings = warnings
        cells.reserveCapacity(ordered.count)
        for index in ordered.indices {
            let point = ordered[index]
            guard let image = extractedByOrdinal[point.ordinal] else {
                throw WatchthroughFailure(.operation, "extracted frame mapping is incomplete")
            }
            let intervalStart = index == ordered.startIndex
                ? min(rangeStart, point.ptsSeconds)
                : (ordered[index - 1].ptsSeconds + point.ptsSeconds) / 2
            let intervalEnd = index == ordered.index(before: ordered.endIndex)
                ? max(rangeEnd, point.ptsSeconds.nextUp)
                : (point.ptsSeconds + ordered[index + 1].ptsSeconds) / 2
            cells.append(PacketCell(
                index: index,
                ordinal: point.ordinal,
                ptsSeconds: point.ptsSeconds,
                intervalStartSeconds: intervalStart,
                intervalEndSeconds: intervalEnd,
                timestamp: CLIParser.formatTime(point.ptsSeconds),
                caption: "",
                framePath: "frames/\(image.lastPathComponent)"
            ))
        }
        if let transcript {
            let aligned = TranscriptTimeline.alignedToDecodedPTS(
                transcript,
                firstPTS: frameIndex.first?.ptsSeconds ?? 0
            )
            cells = TranscriptCaptions.assign(aligned, to: cells)
            packetWarnings = unique(packetWarnings + aligned.warnings)
        }

        var packet = InspectionPacket(
            selector: selector,
            sourcePath: source.path,
            rangeStartSeconds: rangeStart,
            rangeEndSeconds: rangeEnd,
            sampling: sampling,
            cellsPerSheet: cellsPerSheet,
            largestGapSeconds: FrameSelector.largestGap(in: ordered),
            timingPrecision: transcript?.timingPrecision ?? .none,
            cells: cells,
            sheets: [],
            warnings: unique(packetWarnings)
        )
        if cells.count > 1 {
            let sheets = try StripRenderer.render(
                cells: cells,
                framesBaseURL: directory,
                destinationDirectory: directory,
                basename: "strip",
                options: StripRenderOptions(maximumCellsPerSheet: cellsPerSheet)
            )
            packet.sheets = sheets.map(\.lastPathComponent)
        }
        try StableJSON.write(packet, to: directory.appendingPathComponent("packet.json"))
        try PacketMarkdown.write(packet, to: directory.appendingPathComponent("packet.md"))
        return packet
    }
}

// MARK: - Status

private extension WatchthroughApplication {
    func status(_ options: StatusOptions) -> StatusResponse {
        var details: [String: String] = [
            "version": WatchthroughVersion.current,
            "platform": platformDescription(),
            "config_path": NamedTranscriptAdapter.configURL().path,
            "dotenv_path": WatchthroughCredentials.dotEnvURL().path,
        ]
        var warnings: [String] = []
        var artifacts: [String: String] = [:]
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

        do {
            if let credential = try WatchthroughCredentials.elevenLabsAPIKey() {
                details["elevenlabs_credential"] = "configured via \(credential.origin.rawValue)"
            } else {
                details["elevenlabs_credential"] = "not configured (optional)"
            }
        } catch {
            details["elevenlabs_credential"] = "unreadable"
            warnings.append("Could not inspect the optional ElevenLabs credential source: \(errorMessage(error))")
        }
        let dotenvURL = WatchthroughCredentials.dotEnvURL()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: dotenvURL.path),
           let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            warnings.append("\(dotenvURL.path) is readable beyond its owner; use chmod 600 or macOS Keychain.")
        }

        if let requestedAnalysis = options.analysis {
            let analysis = requestedAnalysis.standardizedFileURL.resolvingSymlinksInPath()
            artifacts["manifest"] = analysis.appendingPathComponent("manifest.json").path
            details["analysis"] = analysis.path
            do {
                try PathSafety.validateExistingAnalysisRoot(analysis)
                let prepareLock = siblingLock(for: analysis)
                try PathSafety.validateAnalysisLock(prepareLock, for: analysis)
                details["preparation_lock"] = lockActivity(at: prepareLock)
                let analysisLock = try ExclusiveFileLock.acquireShared(at: prepareLock)
                defer { analysisLock.unlock() }

                let context = try loadAnalysis(at: analysis, verifyFullHash: true)
                details["analysis_state"] = "complete and reusable"
                details["source_sha256"] = context.manifest.source.sha256
                details["decoded_frames"] = String(context.frames.count)
                details["transcript_provider"] = context.manifest.transcript.provider ?? "unavailable"
                details["timing_precision"] = context.manifest.transcript.timingPrecision.rawValue
                details["transcript_language"] = context.manifest.transcript.language ?? "unknown"
                details["speakers_available"] = context.manifest.transcript.speakersAvailable.map { String($0) } ?? "unknown"
                details["overview_frames"] = String(context.manifest.visual.overviewFrames)
                details["visual_change_candidates"] = String(context.manifest.visual.eventCount)

                let overviewURL = try requiredArtifact(context.manifest.visual.overviewPacketPath, under: analysis)
                let overview = try loadPacket(at: overviewURL, root: overviewURL.deletingLastPathComponent())
                guard overview.cells.count == context.manifest.visual.overviewFrames,
                      overview.cells.first?.ordinal == context.frames.first?.ordinal,
                      overview.cells.last?.ordinal == context.frames.last?.ordinal else {
                    throw WatchthroughFailure(.operation, "overview coverage does not match the manifest and decoded endpoints")
                }
                artifacts["overview"] = overviewURL.path

                let eventsURL = try requiredArtifact(context.manifest.visual.eventsPath, under: analysis)
                let events = try decodeEvents(at: eventsURL)
                guard events.events.count == context.manifest.visual.eventCount else {
                    throw WatchthroughFailure(.operation, "visual-change candidate count does not match the manifest")
                }
                artifacts["events"] = eventsURL.path
                artifacts["frame_index"] = try requiredArtifact(
                    context.manifest.visual.frameIndexPath,
                    under: analysis
                ).path
                if let transcriptPath = context.manifest.transcript.path {
                    artifacts["transcript"] = try requiredArtifact(transcriptPath, under: analysis).path
                }
                if let textPath = context.manifest.transcript.textPath {
                    artifacts["transcript_text"] = try requiredArtifact(textPath, under: analysis).path
                }

                let temporary = incompleteTemporaryArtifacts(around: analysis)
                details["incomplete_temporary_artifacts"] = temporary.isEmpty
                    ? "none"
                    : temporary.joined(separator: ",")
                if !temporary.isEmpty {
                    warnings.append("Incomplete tool-owned temporary artifacts exist; inspect them before deciding whether to remove them.")
                }
            } catch {
                details["analysis_state"] = "invalid"
                warnings.append(errorMessage(error))
                if exit == .success { exit = .operation }
            }
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
        ]
        if options.analysis != nil {
            human.append("Analysis: \(details["analysis_state"] ?? "invalid")")
        }
        human += warnings.map { "Warning: \($0)" }
        return StatusResponse(response: ApplicationResponse(result: result, human: human), exit: exit)
    }
}

// MARK: - Analysis loading and validation

private extension WatchthroughApplication {
    func loadAnalysis(at analysis: URL, verifyFullHash: Bool) throws -> AnalysisContext {
        guard let values = try? analysis.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            throw WatchthroughFailure(.usage, "analysis folder does not exist: \(analysis.path)")
        }
        let manifestURL = analysis.appendingPathComponent("manifest.json")
        guard let manifest = try ManifestStore.read(from: manifestURL),
              manifest.schema == WatchthroughVersion.manifestSchema,
              manifest.toolVersion == WatchthroughVersion.current,
              manifest.state == "complete" else {
            throw WatchthroughFailure(.operation, "analysis manifest is missing, incomplete, or incompatible")
        }
        let source = try SourceInspector.validate(URL(fileURLWithPath: manifest.source.path))
        if verifyFullHash {
            let current = try SourceInspector.record(for: source)
            guard current.sha256 == manifest.source.sha256,
                  current.sizeBytes == manifest.source.sizeBytes else {
                throw WatchthroughFailure(.operation, "analysis source identity no longer matches the current file")
            }
        } else {
            try verifySourceMetadata(source, stillMatches: manifest.source)
        }

        let frameIndexURL = try requiredArtifact(manifest.visual.frameIndexPath, under: analysis)
        let frames = try FrameIndexTSV.read(from: frameIndexURL)
        guard frames.count == manifest.media.frameCount,
              frames.first?.ordinal == 0,
              frames.last?.ordinal == manifest.media.frameCount - 1,
              nearlyEqual(frames.first?.ptsSeconds, manifest.media.firstPTS),
              nearlyEqual(frames.last?.ptsSeconds, manifest.media.lastPTS) else {
            throw WatchthroughFailure(.operation, "decoded frame index does not match the manifest")
        }

        var transcript: CanonicalTranscript?
        if manifest.transcript.available {
            guard let path = manifest.transcript.path else {
                throw WatchthroughFailure(.operation, "manifest marks a transcript available without a path")
            }
            let transcriptURL = try requiredArtifact(path, under: analysis)
            let decoded = try StableJSON.decode(CanonicalTranscript.self, from: transcriptURL)
            guard decoded.schema == WatchthroughVersion.transcriptSchema,
                  decoded.provider == manifest.transcript.provider,
                  decoded.model == manifest.transcript.model,
                  decoded.language == manifest.transcript.language,
                  manifest.transcript.speakersAvailable == nil
                    || decoded.speakersAvailable == manifest.transcript.speakersAvailable,
                  decoded.timingPrecision == manifest.transcript.timingPrecision else {
                throw WatchthroughFailure(.operation, "canonical transcript does not match its manifest summary")
            }
            transcript = decoded
            guard let textPath = manifest.transcript.textPath else {
                throw WatchthroughFailure(.operation, "manifest omits the canonical transcript text path")
            }
            _ = try requiredArtifact(textPath, under: analysis)
            if let raw = manifest.transcript.rawPath {
                _ = try requiredArtifact(raw, under: analysis)
            }
        }
        return AnalysisContext(
            analysis: analysis,
            source: source,
            manifest: manifest,
            frames: frames,
            transcript: transcript
        )
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
        guard packet.schema == WatchthroughVersion.packetSchema, !packet.cells.isEmpty else {
            throw WatchthroughFailure(.operation, "inspection packet has an unsupported schema or no frames")
        }
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

private struct ApplicationResponse {
    var result: CommandResult
    var human: [String]
}

private struct StatusResponse {
    var response: ApplicationResponse
    var exit: WatchthroughExit
}

private struct AnalysisContext {
    var analysis: URL
    var source: URL
    var manifest: PreparationManifest
    var frames: [FramePoint]
    var transcript: CanonicalTranscript?
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
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let size = values.fileSize,
           let modified = values.contentModificationDate,
           Int64(size) == record.sizeBytes,
           ISO8601Clock.string(from: modified) == record.modifiedAt {
            return
        }

        let current = try SourceInspector.record(for: source)
        guard current.sizeBytes == record.sizeBytes,
              current.sha256 == record.sha256 else {
            throw WatchthroughFailure(.operation, "source changed after the analysis identity was recorded")
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
                  manifest.toolVersion == WatchthroughVersion.current,
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

    func lockActivity(at url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "not active" }
        do {
            let lock = try ExclusiveFileLock.acquire(at: url)
            lock.unlock()
            return "not active"
        } catch let failure as WatchthroughFailure where failure.message.contains("already being") {
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
        let inspections = analysis.appendingPathComponent("inspections", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: inspections.path) {
            found += names.filter { $0.hasPrefix(".watchthrough-") && $0.contains(".tmp-") }
                .map { "inspections/\($0)" }
        }
        return found.sorted()
    }

    func toolVersion(_ executable: String, arguments: [String]) -> String {
        (try? Tooling.version(of: executable, arguments: arguments)) ?? "available (version unavailable)"
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
