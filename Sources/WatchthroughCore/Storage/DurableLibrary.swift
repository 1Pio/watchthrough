import CryptoKit
import Foundation

/// Durable, agent-authored knowledge snapshots. This module never summarizes
/// evidence or interprets a note as a claim of complete video coverage.
///
/// Both entry points acquire the normal sibling analysis lifetime lock themselves.
/// Callers must not hold that lock. Retention shares it with inspections, verifies
/// the inventory again before publication, and fails if an inspection changed it.
/// Cleanup takes it exclusively and uses the system Trash, never permanent removal.
public enum DurableLibrary {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/watchthrough/library", isDirectory: true)
    }

    public static func retain(
        analysis requestedAnalysis: URL,
        note: URL,
        library requestedLibrary: URL? = nil,
        includes: [String] = [],
        dossiers: [URL] = []
    ) throws -> CommandResult {
        let analysis = try analysisRoot(requestedAnalysis)
        let analysisLock = try lockAnalysis(analysis, exclusive: false)
        defer { analysisLock.unlock() }
        let manifest = try readManifest(analysis)
        let library = try libraryRoot(requestedLibrary ?? defaultDirectory, outside: analysis, create: true)
        let sourceDirectory = try ownedDirectory(manifest.source.sha256, under: library, create: true)
        let sourceLock = try lockLibrarySource(sourceDirectory)
        defer { sourceLock.unlock() }
        let snapshots = try ownedDirectory("snapshots", under: sourceDirectory, create: true)
        var index = try readIndex(sourceDirectory)

        let noteURL = try regularFile(note)
        guard noteURL.pathExtension.lowercased() == "md" else {
            throw failure("retention note must be an agent-authored Markdown (.md) file")
        }
        try enforceSmallFile(noteURL)
        let noteText = try String(contentsOf: noteURL, encoding: .utf8)
        guard noteText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            throw failure("retention note is empty or too short; supply a useful authored summary with coverage and evidence")
        }
        guard dossiers.count <= 32 else { throw failure("retain accepts at most 32 small source dossiers") }

        var copies: [(source: URL, destination: String, role: String, original: String)] = [
            (noteURL, "summary.md", "agent-authored summary; coverage is stated by its author", noteURL.path),
            (try file("manifest.json", under: analysis), "manifest.json", "source and preparation provenance", "manifest.json"),
        ]
        if manifest.transcript.available {
            guard let json = manifest.transcript.path, let text = manifest.transcript.textPath else {
                throw failure("available transcript has no canonical JSON/text paths; repair the analysis before retention")
            }
            copies.append((try file(json, under: analysis), "transcript/transcript.json", "canonical transcript JSON", json))
            copies.append((try file(text, under: analysis), "transcript/transcript.txt", "canonical full transcript text", text))
        }
        var includedBytes: Int64 = 0
        for relative in try expandedIncludes(normalizedIncludes(includes, analysis: analysis), analysis: analysis, source: manifest.source).sorted() {
            let input = try file(relative, under: analysis)
            guard relative.hasPrefix("visual/") || relative.hasPrefix("inspections/"),
                  ["jpg", "jpeg", "png", "webp", "json", "md"].contains(input.pathExtension.lowercased()) else {
                throw failure("--include expects an explicit visual image, index, or inspection packet file inside visual/ or inspections/")
            }
            let bytes = try size(of: input)
            includedBytes += bytes
            guard bytes <= 64 * 1_024 * 1_024, includedBytes <= 256 * 1_024 * 1_024 else {
                throw failure("selected evidence exceeds the 64 MiB per-file or 256 MiB total retention limit; select concise visual evidence")
            }
            copies.append((input, "evidence/" + relative, "selected visual evidence or packet dependency; viewing coverage is authored in the summary", relative))
        }
        for (index, dossier) in dossiers.enumerated() {
            let input = try regularFile(dossier)
            try enforceSmallFile(input)
            let suffix = input.pathExtension.lowercased()
            guard ["md", "txt", "json", "vtt", "srt", "csv", "html", "description"].contains(suffix) else {
                throw failure("source dossier must be a small text/metadata file: \(input.lastPathComponent)")
            }
            if suffix == "description", String(data: try Data(contentsOf: input), encoding: .utf8) == nil {
                throw failure("source .description dossier must contain UTF-8 text")
            }
            copies.append((input, String(format: "dossiers/%02d-", index + 1) + input.lastPathComponent,
                           "caller-supplied source context, untrusted; original provenance belongs in the authored summary", input.path))
        }
        let linkWarnings = try validateSummaryLinks(noteText, copiedPaths: Set(copies.map { $0.destination }), analysis: analysis)
        // Diagnose missing inputs and broken authored links before reading every
        // source/evidence byte for the durable integrity receipt.
        try verifySource(manifest.source, outside: analysis)
        let inventory = try inventoryOf(analysis)

        let snapshotID = ISO8601Clock.now().replacingOccurrences(of: ":", with: "-")
            + "-" + UUID().uuidString.lowercased()
        let destination = snapshots.appendingPathComponent(snapshotID, isDirectory: true)
        let staging = try ArtifactStaging.temporarySibling(for: destination)
        // A failed staging directory is intentionally left recoverable. Never use
        // permanent deletion as an implicit failure/cleanup path for user evidence.
        var retained: [RetainedFile] = []
        for copy in copies {
            let output = try prospectiveFile(copy.destination, under: staging)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: copy.source, to: output)
            let checksum = try FileSHA256.hexDigest(of: output)
            guard try checksum == FileSHA256.hexDigest(of: copy.source) else {
                throw failure("source evidence changed while being retained; retry retention")
            }
            retained.append(RetainedFile(path: copy.destination, sha256: checksum,
                                         sizeBytes: try size(of: output), role: copy.role, originalPath: copy.original))
        }
        guard try inventory == inventoryOf(analysis) else {
            throw failure("analysis changed during retention; wait for active inspections and retry")
        }
        let receipt = LibraryReceipt(snapshotID: snapshotID, createdAt: ISO8601Clock.now(),
                                     analysisPath: analysis.path, source: manifest.source,
                                     files: retained, analysisInventory: inventory)
        try StableJSON.write(receipt, to: staging.appendingPathComponent("receipt.json"))
        _ = try verifySnapshot(at: staging, expectedSource: manifest.source)
        try ArtifactStaging.promote(staging, to: destination)

        index.snapshots.append(LibraryIndexEntry(id: snapshotID, createdAt: receipt.createdAt,
                                               analysisPath: analysis.path, summary: "snapshots/\(snapshotID)/summary.md"))
        try StableJSON.write(index, to: sourceDirectory.appendingPathComponent("index.json"))
        var artifacts = [
            "library": library.path,
            "snapshot": destination.path,
            "summary": destination.appendingPathComponent("summary.md").path,
            "receipt": destination.appendingPathComponent("receipt.json").path,
            "index": sourceDirectory.appendingPathComponent("index.json").path,
        ]
        if manifest.transcript.available {
            artifacts["transcript"] = destination.appendingPathComponent("transcript/transcript.json").path
            artifacts["transcript_text"] = destination.appendingPathComponent("transcript/transcript.txt").path
        }
        return CommandResult(ok: true, command: "retain", analysis: analysis.path, artifacts: artifacts,
                             details: ["source_sha256": manifest.source.sha256, "retained_files": String(retained.count),
                     "snapshot_id": snapshotID, "coverage": "Authored in summary.md; not certified by the tool.",
                     "link_validation": "Standard inline Markdown links in evidence/, dossiers/, and transcript/; not a complete Markdown parser."],
           warnings: linkWarnings)
    }

    public static func cleanup(
        analysis requestedAnalysis: URL,
        library requestedLibrary: URL? = nil,
        apply: Bool = false,
        trash: ((URL) throws -> URL?)? = nil
    ) throws -> CommandResult {
        let analysis = try analysisRoot(requestedAnalysis)
        let analysisLock = try lockAnalysis(analysis, exclusive: true)
        defer { analysisLock.unlock() }
        let manifest = try readManifest(analysis)
        try verifySource(manifest.source, outside: analysis)
        try validateOwnedTree(analysis, manifest: manifest)
        let library = try libraryRoot(requestedLibrary ?? defaultDirectory, outside: analysis, create: false)
        let sourceDirectory = try ownedDirectory(manifest.source.sha256, under: library, create: false)
        let sourceLock = try lockLibrarySource(sourceDirectory)
        defer { sourceLock.unlock() }
        let snapshots = try ownedDirectory("snapshots", under: sourceDirectory, create: false)
        let currentInventory = try inventoryOf(analysis)
        let index = try readIndex(sourceDirectory)
        var verifiedSnapshot: URL?
        for entry in index.snapshots.reversed() where entry.analysisPath == analysis.path {
            do {
                let candidate = try ownedDirectory(entry.id, under: snapshots, create: false)
                let receipt = try verifySnapshot(at: candidate, expectedSource: manifest.source)
                guard receipt.analysisPath == analysis.path,
                      receipt.snapshotID == entry.id,
                      receipt.analysisInventory == currentInventory else { continue }
                // Older library versions did not validate generation receipts.
                // Recheck the live owners of selected images as well, including
                // single-image snapshots that do not contain a whole packet.
                let included = receipt.files.filter { $0.path.hasPrefix("evidence/") }
                    .map { String($0.path.dropFirst("evidence/".count)) }
                _ = try expandedIncludes(included, analysis: analysis, source: manifest.source)
                verifiedSnapshot = candidate
                break
            } catch {
                // A damaged newer snapshot does not invalidate an intact earlier
                // snapshot that contains exactly the current analysis inventory.
                continue
            }
        }
        guard let snapshot = verifiedSnapshot else {
            throw failure("cleanup requires an intact retained snapshot matching this analysis and its current artifacts; run retain again")
        }
        let bytes = currentInventory.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var artifacts = ["retained_snapshot": snapshot.path, "summary": snapshot.appendingPathComponent("summary.md").path,
                         "source_preserved": manifest.source.path]
        if manifest.transcript.available {
            artifacts["transcript"] = snapshot.appendingPathComponent("transcript/transcript.json").path
            artifacts["transcript_text"] = snapshot.appendingPathComponent("transcript/transcript.txt").path
        }
        if apply {
            // Revalidate immediately before handing the whole recognized directory
            // to Trash. Cooperative prepare/inspect writers remain excluded.
            try validateOwnedTree(analysis, manifest: manifest)
            guard try currentInventory == inventoryOf(analysis) else {
                throw failure("analysis changed before cleanup; no files were trashed")
            }
            if let trashed = try (trash ?? nativeTrash)(analysis) { artifacts["trash"] = trashed.path }
            guard entryType(analysis) == nil else {
                throw failure("the Trash operation returned without moving the analysis; its files remain in place")
            }
        }
        return CommandResult(ok: true, command: "cleanup", analysis: analysis.path, artifacts: artifacts,
                             details: ["mode": apply ? "trashed" : "dry-run", "bytes": String(bytes),
                                       "files": String(currentInventory.filter { $0.kind == "file" }.count),
                                       "next_action": apply ? "Source video and durable snapshot remain available." : "Run cleanup with --apply to move only this analysis to the system Trash."])
    }

    private static func nativeTrash(_ analysis: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: analysis, resultingItemURL: &resulting)
        return resulting as URL?
    }

    private static func analysisRoot(_ requested: URL) throws -> URL {
        guard entryType(requested.standardizedFileURL) != .typeSymbolicLink else {
            throw failure("analysis cannot be a symbolic link")
        }
        let root = requested.standardizedFileURL.resolvingSymlinksInPath()
        try PathSafety.validateExistingAnalysisRoot(root)
        return root
    }

    private static func readManifest(_ analysis: URL, retained: Bool = false) throws -> PreparationManifest {
        guard let manifest = try ManifestStore.read(from: file("manifest.json", under: analysis)),
              manifest.schema == WatchthroughVersion.manifestSchema, manifest.state == "complete",
              manifest.source.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw failure("retention/cleanup requires a complete supported analysis manifest and source identity")
        }
        try validateTranscript(manifest.transcript, under: analysis, retained: retained)
        return manifest
    }

    private static func validateTranscript(_ summary: TranscriptSummary, under root: URL, retained: Bool) throws {
        guard summary.available else { return }
        guard let originalJSON = summary.path, let originalText = summary.textPath else {
            throw failure("available transcript is missing its canonical JSON or clean text path")
        }
        let canonical = try Data(contentsOf: file(retained ? "transcript/transcript.json" : originalJSON, under: root))
        let text = try Data(contentsOf: file(retained ? "transcript/transcript.txt" : originalText, under: root))
        if let expected = summary.fingerprint, fingerprint("transcript", canonical) != expected {
            throw failure("canonical transcript no longer matches its preparation fingerprint; refresh transcription instead of editing generated artifacts")
        }
        if let expected = summary.textFingerprint, fingerprint("transcript-text", text) != expected {
            throw failure("clean transcript text no longer matches its preparation fingerprint; refresh transcription instead of editing generated artifacts")
        }
        if let expected = summary.textBytes, text.count != expected {
            throw failure("clean transcript text size no longer matches its preparation manifest")
        }
        let transcript = try StableJSON.decode(CanonicalTranscript.self, from: canonical)
        guard transcript.schema == WatchthroughVersion.transcriptSchema,
              transcript.provider == summary.provider,
              transcript.model == summary.model,
              transcript.language == summary.language,
              transcript.timingPrecision == summary.timingPrecision,
              summary.speakersAvailable == nil || summary.speakersAvailable == transcript.speakersAvailable else {
            throw failure("canonical transcript metadata does not match its preparation manifest")
        }
        guard text == TranscriptFiles.textData(transcript) else {
            throw failure("clean transcript text does not match the canonical transcript's readable projection; refresh transcription before retention or cleanup")
        }
    }

    private static func fingerprint(_ label: String, _ data: Data) -> String {
        label + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func lockAnalysis(_ analysis: URL, exclusive: Bool) throws -> ExclusiveFileLock {
        let path = analysis.deletingLastPathComponent().appendingPathComponent(".\(analysis.lastPathComponent).lock")
        try PathSafety.validateAnalysisLock(path, for: analysis)
        return try exclusive ? ExclusiveFileLock.acquire(at: path) : ExclusiveFileLock.acquireShared(at: path)
    }

    private static func lockLibrarySource(_ directory: URL) throws -> ExclusiveFileLock {
        let path = directory.appendingPathComponent(".library.lock")
        if let type = entryType(path), type != .typeRegular { throw failure("unsafe library lock") }
        return try ExclusiveFileLock.acquire(at: path)
    }

    private static func verifySource(_ source: SourceRecord, outside analysis: URL) throws {
        let url = try regularFile(URL(fileURLWithPath: source.path))
        guard !isWithin(url, analysis), !isWithin(analysis, url) else {
            throw failure("source video cannot be inside the analysis; cleanup must preserve the source")
        }
        guard try size(of: url) == source.sizeBytes,
              try FileSHA256.hexDigest(of: url) == source.sha256 else {
            throw failure("source video content no longer matches the analysis identity")
        }
    }

    private static func libraryRoot(_ requested: URL, outside analysis: URL, create: Bool) throws -> URL {
        guard entryType(requested.standardizedFileURL) != .typeSymbolicLink else {
            throw failure("durable library cannot be a symbolic link")
        }
        let root = requested.standardizedFileURL.resolvingSymlinksInPath()
        guard !isWithin(root, analysis), !isWithin(analysis, root) else {
            throw failure("durable library and analysis must be separate directories")
        }
        if entryType(root) == nil && create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard entryType(root) == .typeDirectory else { throw failure("durable library directory does not exist or is unsafe") }
        return root
    }

    private static func ownedDirectory(_ name: String, under root: URL, create: Bool) throws -> URL {
        let destination = try prospectiveFile(name, under: root)
        if entryType(destination) == nil && create {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard entryType(destination) == .typeDirectory else { throw failure("library directory is missing or unsafe: \(name)") }
        return destination
    }

    private static func readIndex(_ sourceDirectory: URL) throws -> LibraryIndex {
        let path = sourceDirectory.appendingPathComponent("index.json")
        guard entryType(path) != nil else { return LibraryIndex() }
        guard entryType(path) == .typeRegular else { throw failure("unsafe library index") }
        let index = try StableJSON.decode(LibraryIndex.self, from: path)
        guard index.schema == "watchthrough.library-index.v1" else { throw failure("unsupported library index") }
        return index
    }

    private static func validateOwnedTree(_ analysis: URL, manifest: PreparationManifest) throws {
        var layout = manifest
        // A deferred visual stage has no artifact yet. Substitute only its normal
        // name for the ownership checker; this does not assert it was computed.
        if layout.visual.frameIndexPath.isEmpty { layout.visual.frameIndexPath = "visual/frame-index.tsv" }
        if layout.visual.overviewPacketPath.isEmpty { layout.visual.overviewPacketPath = "visual/overview/packet.json" }
        if layout.visual.eventsPath.isEmpty { layout.visual.eventsPath = "visual/events.json" }
        try PathSafety.validateRefreshTree(at: analysis, manifest: layout)
    }

    private static func verifySnapshot(at root: URL, expectedSource: SourceRecord) throws -> LibraryReceipt {
        let receipt = try StableJSON.decode(LibraryReceipt.self, from: file("receipt.json", under: root))
        guard receipt.schema == "watchthrough.library-receipt.v1",
              receipt.source.sha256 == expectedSource.sha256,
              receipt.source.sizeBytes == expectedSource.sizeBytes,
              !receipt.files.isEmpty else { throw failure("retained receipt has an invalid source identity") }
        var seen = Set<String>()
        for retained in receipt.files {
            guard seen.insert(retained.path).inserted else { throw failure("retained receipt repeats an artifact path") }
            let url = try file(retained.path, under: root)
            guard try size(of: url) == retained.sizeBytes,
                  try FileSHA256.hexDigest(of: url) == retained.sha256 else {
                throw failure("retained artifact checksum mismatch: \(retained.path)")
            }
        }
        guard seen.contains("summary.md"), seen.contains("manifest.json") else {
            throw failure("retained snapshot is missing its summary or source manifest")
        }
        guard let originalManifest = receipt.analysisInventory.first(where: { $0.path == "manifest.json" }),
              let retainedManifest = receipt.files.first(where: { $0.path == "manifest.json" }),
              originalManifest.sha256 == retainedManifest.sha256,
              originalManifest.sizeBytes == retainedManifest.sizeBytes else {
            throw failure("retained source manifest does not match the recorded analysis")
        }
        let archived = try readManifest(root, retained: true)
        guard archived.source == receipt.source else { throw failure("retained manifest disagrees with receipt source") }
        _ = try validateSummaryLinks(String(contentsOf: file("summary.md", under: root), encoding: .utf8),
                                     copiedPaths: seen, analysis: URL(fileURLWithPath: receipt.analysisPath))
        let packetPaths = seen.filter {
            $0.hasPrefix("evidence/") && ($0.hasSuffix("/packet.json") || $0.hasSuffix("/packet.md"))
        }.map { String($0.dropFirst("evidence/".count)) }
        if !packetPaths.isEmpty {
            let dependencies = try expandedIncludes(packetPaths, analysis: root.appendingPathComponent("evidence"), source: receipt.source)
            guard dependencies.allSatisfy({ seen.contains("evidence/" + $0) }) else {
                throw failure("retained packet is missing recorded visual dependencies; retain the complete packet again")
            }
        }
        if archived.transcript.available {
            guard seen.contains("transcript/transcript.json"), seen.contains("transcript/transcript.txt"),
                  let originalJSON = archived.transcript.path, let originalText = archived.transcript.textPath else {
                throw failure("retained snapshot is missing its full canonical transcript")
            }
            for (original, archivedPath) in [(originalJSON, "transcript/transcript.json"), (originalText, "transcript/transcript.txt")] {
                guard let originalFile = receipt.analysisInventory.first(where: { $0.path == original }),
                      let archivedFile = receipt.files.first(where: { $0.path == archivedPath }),
                      originalFile.sha256 == archivedFile.sha256,
                      originalFile.sizeBytes == archivedFile.sizeBytes else {
                    throw failure("retained transcript does not match the recorded analysis")
                }
            }
        }
        let actualFiles = Set(try inventoryOf(root).filter { $0.kind == "file" }.map(\.path))
        guard actualFiles == seen.union(["receipt.json"]) else { throw failure("retained snapshot contains unrecorded artifacts") }
        return receipt
    }

    /// Returned absolute artifact paths enter the same relative ownership checks.
    private static func normalizedIncludes(_ requested: [String], analysis: URL) throws -> [String] {
        try requested.map { path in
            guard path.hasPrefix("/") else { return path }
            guard path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw failure("absolute --include paths cannot contain traversal components")
            }
            let input = URL(fileURLWithPath: path).standardizedFileURL
            let canonical = input.resolvingSymlinksInPath()
            guard isWithin(canonical, analysis), canonical.path != analysis.path,
                  let owner = identity(analysis) else {
                throw failure("absolute --include path must be an artifact inside this analysis: \(path)")
            }
            // Match the analysis by filesystem identity so platform parent
            // aliases such as /var still work; never accept a linked artifact.
            var current = input
            var components: [String] = []
            while true {
                guard entryType(current) != .typeSymbolicLink else {
                    throw failure("absolute --include paths cannot traverse symbolic links: \(path)")
                }
                if identity(current) == owner { break }
                guard current.path != "/" else { throw failure("absolute --include path escapes its analysis") }
                components.append(current.lastPathComponent)
                current = current.deletingLastPathComponent()
            }
            return components.reversed().joined(separator: "/")
        }
    }

    /// A canonical packet is the navigation unit. Preserve the relative layout so
    /// both packet.json and packet.md still open their frames/sheets after Trash.
    private static func expandedIncludes(_ requested: [String], analysis: URL, source: SourceRecord) throws -> Set<String> {
        var result = Set(requested)
        var expandedPacketRoots = Set<String>()
        var packets: [String: InspectionPacket] = [:]
        for relative in requested {
            let input = try file(relative, under: analysis)
            let isPacket = ["packet.json", "packet.md"].contains(input.lastPathComponent)
            let isImage = ["jpg", "jpeg", "png", "webp"].contains(input.pathExtension.lowercased())
            guard isPacket || isImage else { continue }
            guard relative.range(of: #"^(visual/overview|inspections/[a-z0-9][a-z0-9-]{0,41}-[0-9a-f]{8})/(packet\.(json|md)|frames/frame-[a-z0-9-]+\.jpg|strip-[0-9]{2,}\.(png|jpg))$"#,
                                 options: .regularExpression) != nil else {
                throw failure("selected visual evidence does not use a recognized watchthrough packet path")
            }
            let prefix = relative.split(separator: "/").prefix(2).joined(separator: "/") + "/"
            let packetRoot = analysis.appendingPathComponent(prefix)
            let packet: InspectionPacket
            if let cached = packets[prefix] {
                packet = cached
            } else {
                packet = try verifiedPacket(under: packetRoot, source: source)
                packets[prefix] = packet
            }
            if isImage {
                let selected = String(relative.dropFirst(prefix.count))
                guard Set(packet.cells.map(\.framePath) + packet.sheets).contains(selected) else {
                    throw failure("selected image is not referenced by its owning inspection packet")
                }
                continue
            }
            guard expandedPacketRoots.insert(prefix).inserted else { continue }
            result.insert(prefix + "packet.json")
            for cell in packet.cells {
                result.insert(prefix + cell.framePath)
            }
            for sheet in packet.sheets {
                result.insert(prefix + sheet)
            }
            if entryType(packetRoot.appendingPathComponent("packet.md")) != nil {
                _ = try file("packet.md", under: packetRoot)
                result.insert(prefix + "packet.md")
            }
        }
        return result
    }

    private static func verifiedPacket(under root: URL, source: SourceRecord) throws -> InspectionPacket {
        let packetURL = try file("packet.json", under: root)
        guard try size(of: packetURL) <= 64 * 1_024 * 1_024 else { throw failure("packet JSON exceeds the 64 MiB per-file limit") }
        let packet = try StableJSON.decode(InspectionPacket.self, from: packetURL)
        guard WatchthroughVersion.supportedPacketSchemas.contains(packet.schema), !packet.cells.isEmpty,
              URL(fileURLWithPath: packet.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: source.path).standardizedFileURL.resolvingSymlinksInPath().path else {
            throw failure("included packet has an unsupported schema, no visual cells, or a different source")
        }
        try InspectionPacketValidation.validateStructure(packet)
        for cell in packet.cells {
            guard cell.framePath.range(of: #"^frames/frame-[a-z0-9-]+\.jpg$"#, options: .regularExpression) != nil else {
                throw failure("included packet contains an unsafe or unrecognized frame reference")
            }
            _ = try file(cell.framePath, under: root)
        }
        for sheet in packet.sheets {
            guard sheet.range(of: #"^strip-[0-9]{2,}\.(png|jpg)$"#, options: .regularExpression) != nil else {
                throw failure("included packet contains an unsafe or unrecognized sheet reference")
            }
            _ = try file(sheet, under: root)
        }
        if let fingerprints = packet.artifactFingerprints {
            let expectedPaths = Set(packet.cells.map(\.framePath) + packet.sheets + ["packet.md"])
            guard Set(fingerprints.keys) == expectedPaths else {
                throw failure("included packet's generation checksum inventory is incomplete or inconsistent")
            }
            for relative in expectedPaths {
                guard try FileSHA256.hexDigest(of: file(relative, under: root)) == fingerprints[relative] else {
                    throw failure("included visual artifact no longer matches its generation checksum: \(relative); request a new inspection")
                }
            }
        } else if packet.schema == WatchthroughVersion.packetSchema {
            throw failure("included v2 packet is missing generation checksums; request a new inspection")
        }
        return packet
    }

    /// Deliberately narrow validation of ordinary inline Markdown links/images.
    /// Fenced and inline code are excluded. Reference links, HTML, and full
    /// Markdown syntax are not parsed or advertised as comprehensively checked.
    private static func validateSummaryLinks(_ text: String, copiedPaths: Set<String>, analysis: URL) throws -> [String] {
        var fence: String?
        var prose: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            prose.append(line.replacingOccurrences(of: #"`+[^`\n]*`+"#, with: "", options: .regularExpression))
        }
        let body = prose.joined(separator: "\n")
        let pattern = #"!?\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+\"[^\"\n]*\")?\s*\)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var warnings = Set<String>()
        for match in matches {
            let capture = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
            guard let range = Range(capture, in: body) else { continue }
            let raw = String(body[range])
            if raw.hasPrefix("#") { continue }
            if raw.hasPrefix("//") { continue }
            let withoutFragment = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
            let absolute: URL?
            if decoded.hasPrefix("/") {
                absolute = URL(fileURLWithPath: decoded)
            } else if raw.lowercased().hasPrefix("file:"), let url = URL(string: raw), url.isFileURL {
                absolute = url
            } else if decoded.hasPrefix("~/") {
                absolute = URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath)
            } else {
                absolute = nil
            }
            if let absolute {
                let local = absolute.standardizedFileURL.resolvingSymlinksInPath()
                if isWithin(local, analysis) {
                    let prefix = analysis.path.hasSuffix("/") ? analysis.path : analysis.path + "/"
                    let relative = local.path.hasPrefix(prefix) ? String(local.path.dropFirst(prefix.count)) : "<analysis-relative-path>"
                    throw failure("summary links to disposable analysis content: \(raw). Select its evidence and author a durable relative link such as evidence/\(relative), then retain again; the source note was not changed")
                }
                warnings.insert("Summary contains absolute local links outside the analysis; those files are not made portable by retention.")
                continue
            }
            if decoded.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil || decoded.hasPrefix("//") { continue }
            let relative = decoded.hasPrefix("./") ? String(decoded.dropFirst(2)) : decoded
            if relative.hasPrefix("visual/") || relative.hasPrefix("inspections/")
                || relative.hasPrefix(analysis.lastPathComponent + "/") {
                throw failure("summary uses a disposable analysis-relative link: \(relative). Select its evidence and use the retained evidence/ path in the authored note")
            }
            if ["evidence/", "dossiers/", "transcript/"].contains(where: relative.hasPrefix)
                || ["manifest.json", "summary.md"].contains(relative) {
                guard copiedPaths.contains(relative) else {
                    throw failure("summary references a file that will not be retained: \(relative). Supply its --include/--dossier input or correct the authored link")
                }
            } else {
                warnings.insert("Summary contains other relative links outside the checked evidence/, dossiers/, and transcript/ paths; review them for portability.")
            }
        }
        return warnings.sorted()
    }

    private static func inventoryOf(_ root: URL) throws -> [LibraryInventoryEntry] {
        var result: [LibraryInventoryEntry] = []
        func visit(_ directory: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = prefix + child.lastPathComponent
                switch entryType(child) {
                case .typeDirectory:
                    result.append(LibraryInventoryEntry(path: path, kind: "directory", sizeBytes: 0, sha256: nil))
                    try visit(child, prefix: path + "/")
                case .typeRegular:
                    result.append(LibraryInventoryEntry(path: path, kind: "file", sizeBytes: try size(of: child),
                                                        sha256: try FileSHA256.hexDigest(of: child)))
                default:
                    throw failure("refuse symbolic links or special files in evidence tree: \(path)")
                }
            }
        }
        try visit(root, prefix: "")
        return result.sorted { $0.path < $1.path }
    }

    private static func prospectiveFile(_ relative: String, under root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("artifact path must be relative and cannot escape its directory: \(relative)")
        }
        var candidate = root
        for part in parts {
            candidate.appendPathComponent(String(part))
            if entryType(candidate) == .typeSymbolicLink { throw failure("artifact paths cannot traverse symbolic links: \(relative)") }
        }
        guard isWithin(candidate, root), candidate != root else { throw failure("artifact path escapes its directory") }
        return candidate
    }

    private static func file(_ relative: String, under root: URL) throws -> URL {
        let url = try prospectiveFile(relative, under: root)
        guard entryType(url) == .typeRegular else { throw failure("artifact is missing or is not a regular file: \(relative)") }
        return url
    }

    private static func regularFile(_ requested: URL) throws -> URL {
        guard entryType(requested.standardizedFileURL) == .typeRegular else {
            throw failure("input must be an existing regular file, not a symbolic link: \(requested.path)")
        }
        return requested.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func enforceSmallFile(_ url: URL) throws {
        guard try size(of: url) <= 2 * 1_024 * 1_024 else { throw failure("summary/dossier exceeds the 2 MiB text-file limit") }
    }

    private static func size(of url: URL) throws -> Int64 {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber else { throw failure("cannot determine artifact size") }
        return size.int64Value
    }

    private static func entryType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private static func isWithin(_ candidate: URL, _ root: URL) -> Bool {
        if candidate.path == root.path || candidate.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") {
            return true
        }
        // APFS commonly ignores case. String prefixes alone miss an existing
        // ancestor accessed with different capitalization; filesystem identity
        // also protects the original video and library in that case.
        guard let expected = identity(root) else { return false }
        var ancestor = candidate
        while true {
            if identity(ancestor) == expected { return true }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path || ancestor.path == "/" { return false }
            ancestor = parent
        }
    }

    private static func identity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }

    private static func failure(_ message: String) -> WatchthroughFailure { WatchthroughFailure(.operation, message) }
}

private struct LibraryReceipt: Codable {
    var schema = "watchthrough.library-receipt.v1"
    var snapshotID: String
    var createdAt: String
    var analysisPath: String
    var source: SourceRecord
    var files: [RetainedFile]
    var analysisInventory: [LibraryInventoryEntry]
}

private struct RetainedFile: Codable {
    var path: String
    var sha256: String
    var sizeBytes: Int64
    var role: String
    var originalPath: String
}

private struct LibraryInventoryEntry: Codable, Equatable {
    var path: String
    var kind: String
    var sizeBytes: Int64
    var sha256: String?
}

private struct LibraryIndex: Codable {
    var schema = "watchthrough.library-index.v1"
    var snapshots: [LibraryIndexEntry] = []
}

private struct LibraryIndexEntry: Codable {
    var id: String
    var createdAt: String
    var analysisPath: String
    var summary: String
}
