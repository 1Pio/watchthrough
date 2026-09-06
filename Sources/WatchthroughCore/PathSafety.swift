import Foundation

/// Narrow filesystem guards for the two places where watchthrough creates or
/// replaces directory trees. These checks intentionally reject symlinked write
/// roots instead of trying to infer whether a link is benign.
enum PathSafety {
    static func ensureStageDirectory(_ name: String, under analysis: URL) throws -> URL {
        guard ["visual", "transcript"].contains(name) else { throw WatchthroughFailure(.operation, "invalid stage directory") }
        let directory = analysis.appendingPathComponent(name, isDirectory: true)
        if let type = entryType(at: directory) {
            guard type == .typeDirectory, !isSymbolicLink(directory) else { throw WatchthroughFailure(.operation, "unsafe stage directory: \(name)") }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        return directory
    }

    static func preparationOutput(_ requested: URL, source: URL) throws -> URL {
        let requested = requested.standardizedFileURL
        if isSymbolicLink(requested) {
            throw WatchthroughFailure(.usage, "analysis output cannot be a symbolic link")
        }

        let output = canonicalProspectiveURL(requested)
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        if isSameOrDescendant(source, of: output)
            || isExistingAncestor(output, of: source) {
            throw WatchthroughFailure(
                .usage,
                "analysis output cannot equal or contain the source video"
            )
        }

        if let type = entryType(at: requested), type != .typeDirectory {
            throw WatchthroughFailure(.usage, "analysis output exists but is not a directory: \(requested.path)")
        }
        return output
    }

    static func ensureInspectionsDirectory(under analysis: URL) throws -> URL {
        let root = analysis.standardizedFileURL.resolvingSymlinksInPath()
        let inspections = root.appendingPathComponent("inspections", isDirectory: true)
        if let type = entryType(at: inspections) {
            guard type == .typeDirectory, !isSymbolicLink(inspections) else {
                throw unsafeInspectionsDirectory(inspections)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: inspections,
                    withIntermediateDirectories: false
                )
            } catch {
                // Another independent inspection may have won the first-use
                // race. Accept only the same real owned directory we would
                // have accepted above; links and other entry types still fail.
                guard entryType(at: inspections) == .typeDirectory,
                      !isSymbolicLink(inspections) else {
                    throw WatchthroughFailure(
                        .operation,
                        "could not create inspections directory: \(error.localizedDescription)"
                    )
                }
            }
        }

        let canonical = inspections.resolvingSymlinksInPath()
        guard sameLocation(canonical.deletingLastPathComponent(), root),
              entryType(at: canonical) == .typeDirectory else {
            throw unsafeInspectionsDirectory(inspections)
        }
        return canonical
    }

    static func inspectionDestination(named name: String, under inspections: URL) throws -> URL {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw WatchthroughFailure(.operation, "generated inspection identity is unsafe")
        }
        let root = inspections.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(name, isDirectory: true)
        guard destination.deletingLastPathComponent() == root else {
            throw WatchthroughFailure(.operation, "generated inspection path escapes its analysis")
        }
        if let type = entryType(at: destination) {
            guard type == .typeDirectory,
                  !isSymbolicLink(destination),
                  sameLocation(
                    destination.resolvingSymlinksInPath().deletingLastPathComponent(),
                    root
                  ) else {
                throw WatchthroughFailure(.operation, "existing inspection path is unsafe: \(destination.path)")
            }
        }
        return destination
    }

    static func validateInspectionLock(_ lock: URL, under inspections: URL) throws {
        let root = inspections.standardizedFileURL.resolvingSymlinksInPath()
        let lock = lock.standardizedFileURL
        guard lock.deletingLastPathComponent() == root else {
            throw WatchthroughFailure(.operation, "inspection lock path escapes its analysis")
        }
        if let type = entryType(at: lock), type != .typeRegular {
            throw WatchthroughFailure(.operation, "inspection lock path is unsafe: \(lock.path)")
        }
    }

    static func validateAnalysisLock(_ lock: URL, for analysis: URL) throws {
        let expectedParent = analysis.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let lock = lock.standardizedFileURL
        guard sameLocation(
            lock.deletingLastPathComponent().resolvingSymlinksInPath(),
            expectedParent
        ) else {
            throw WatchthroughFailure(.operation, "analysis lock path escapes its output")
        }
        if let type = entryType(at: lock), type != .typeRegular {
            throw WatchthroughFailure(.operation, "analysis lock path is unsafe: \(lock.path)")
        }
    }

    /// Read commands must not create parent folders or lock files merely
    /// because an analysis argument was mistyped. This is deliberately a
    /// shallow check; full manifest and artifact validation still happens
    /// after the shared lifetime lock is held.
    static func validateExistingAnalysisRoot(_ analysis: URL) throws {
        let root = analysis.standardizedFileURL.resolvingSymlinksInPath()
        guard entryType(at: root) == .typeDirectory else {
            throw WatchthroughFailure(.usage, "analysis folder does not exist: \(analysis.path)")
        }
        let manifest = root.appendingPathComponent("manifest.json")
        guard entryType(at: manifest) == .typeRegular,
              sameLocation(manifest.deletingLastPathComponent(), root) else {
            throw WatchthroughFailure(.operation, "analysis manifest is missing or unsafe")
        }
    }

    static func isRegularOwnedFile(_ url: URL) -> Bool {
        entryType(at: url.standardizedFileURL) == .typeRegular
    }

    /// Refresh replaces a complete directory tree. Refuse it if that would
    /// remove anything not produced by this manifest version and the packet
    /// naming contract. Missing recognized artifacts are allowed so refresh
    /// can repair a damaged but still identifiable analysis.
    static func validateRefreshTree(
        at analysis: URL,
        manifest: PreparationManifest
    ) throws {
        guard ["", "visual/frame-index.tsv"].contains(manifest.visual.frameIndexPath),
              manifest.visual.overviewPacketPath.isEmpty || manifest.visual.overviewPacketPath == "visual/overview/packet.json"
                || matches(manifest.visual.overviewPacketPath, #"^inspections/[a-z0-9][a-z0-9-]{0,41}-[0-9a-f]{8}/packet\.json$"#),
              ["", "visual/events.json"].contains(manifest.visual.eventsPath) else {
            throw unrecognizedRefreshEntry("manifest contains an incompatible artifact layout")
        }

        let rawPath = manifest.transcript.rawPath
        if manifest.transcript.available {
            let prefix = #"^transcript/(run-[0-9a-f-]{36}/)?"#
            guard manifest.transcript.path.map({ matches($0, prefix + #"transcript\.json$"#) }) == true,
                  manifest.transcript.textPath == nil || manifest.transcript.textPath.map({ matches($0, prefix + #"transcript\.txt$"#) }) == true,
                  rawPath == nil || matches(rawPath!, prefix + #"raw-provider-response\.[a-z0-9]+$"#) else {
                throw unrecognizedRefreshEntry("manifest contains an incompatible transcript layout")
            }
        } else if manifest.transcript.path != nil
            || manifest.transcript.textPath != nil
            || rawPath != nil {
            throw unrecognizedRefreshEntry("manifest contains an inconsistent transcript layout")
        }

        let root = analysis.standardizedFileURL.resolvingSymlinksInPath()
        try validateRefreshEntries(
            in: root,
            relativeDirectory: "",
            transcriptAvailable: manifest.transcript.available,
            rawTranscriptPath: rawPath
        )
    }

    private static func canonicalProspectiveURL(_ url: URL) -> URL {
        if entryType(at: url) != nil {
            return url.resolvingSymlinksInPath()
        }
        return url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
            .standardizedFileURL
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        if candidate.path == root.path { return true }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return candidate.path.hasPrefix(prefix)
    }

    /// Canonical paths are normally sufficient, while filesystem identities
    /// also cover case-insensitive aliases of an existing ancestor.
    private static func isExistingAncestor(_ possibleAncestor: URL, of source: URL) -> Bool {
        guard let expected = fileIdentity(at: possibleAncestor) else { return false }
        var candidate = source
        while true {
            if fileIdentity(at: candidate) == expected { return true }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { return false }
            candidate = parent
        }
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        if let left = fileIdentity(at: lhs), let right = fileIdentity(at: rhs) {
            return left == right
        }
        return lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func entryType(at url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.type] as? FileAttributeType
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        entryType(at: url) == .typeSymbolicLink
    }

    private static func validateRefreshEntries(
        in directory: URL,
        relativeDirectory: String,
        transcriptAvailable: Bool,
        rawTranscriptPath: String?
    ) throws {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw WatchthroughFailure(
                .operation,
                "refuse to refresh analysis whose contents cannot be verified: \(error.localizedDescription)"
            )
        }

        for child in children {
            guard let type = entryType(at: child) else {
                throw unrecognizedRefreshEntry(child.path)
            }
            let relative = relativeDirectory.isEmpty
                ? child.lastPathComponent
                : relativeDirectory + "/" + child.lastPathComponent
            guard isRecognizedRefreshEntry(
                relative,
                type: type,
                transcriptAvailable: transcriptAvailable,
                rawTranscriptPath: rawTranscriptPath
            ) else {
                throw unrecognizedRefreshEntry(relative)
            }
            if type == .typeDirectory {
                try validateRefreshEntries(
                    in: child,
                    relativeDirectory: relative,
                    transcriptAvailable: transcriptAvailable,
                    rawTranscriptPath: rawTranscriptPath
                )
            }
        }
    }

    private static func isRecognizedRefreshEntry(
        _ path: String,
        type: FileAttributeType,
        transcriptAvailable: Bool,
        rawTranscriptPath: String?
    ) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts == ["manifest.json"] { return type == .typeRegular }
        if parts == ["visual"] { return type == .typeDirectory }
        if parts == ["visual", "frame-index.tsv"] || parts == ["visual", "events.json"] {
            return type == .typeRegular
        }
        if parts == ["visual", "overview"] { return type == .typeDirectory }
        if parts == ["visual", "overview", "frames"] { return type == .typeDirectory }
        if parts == ["visual", "overview", "packet.json"]
            || parts == ["visual", "overview", "packet.md"] {
            return type == .typeRegular
        }
        if parts.count == 3, parts[0] == "visual", parts[1] == "overview" {
            return type == .typeRegular && matches(parts[2], #"^strip-[0-9]{2,}\.(png|jpg)$"#)
        }
        if parts.count == 4,
           parts[0] == "visual", parts[1] == "overview", parts[2] == "frames" {
            return type == .typeRegular && matches(parts[3], #"^frame-[a-z0-9-]+\.jpg$"#)
        }
        if parts == ["transcript"] { return type == .typeDirectory }
        if parts.count >= 2, parts[0] == "transcript",
           matches(parts[1], #"^run-[0-9a-f-]{36}$"#) || matches(parts[1], #"^\.watchthrough-run-[0-9a-f-]{36}\.tmp-[0-9a-f-]{36}$"#) {
            if parts.count == 2 { return type == .typeDirectory }
            return parts.count == 3 && type == .typeRegular &&
                (parts[2] == "transcript.json" || parts[2] == "transcript.txt" || parts[2] == ".adapter-output.json" || parts[2] == ".scribe-audio.flac" || matches(parts[2], #"^raw-provider-response\.[a-z0-9]+$"#))
        }
        if parts == ["transcript", "transcript.json"]
            || parts == ["transcript", "transcript.txt"] {
            return type == .typeRegular
        }
        if parts.count == 2, parts[0] == "transcript" {
            return type == .typeRegular && (path == rawTranscriptPath || matches(parts[1], #"^raw-provider-response\.[a-z0-9]+$"#))
        }
        if parts == ["inspections"] { return type == .typeDirectory }
        if parts.count == 2, parts[0] == "inspections" {
            let name = parts[1]
            if type == .typeDirectory { return isInspectionIdentity(name) }
            guard type == .typeRegular,
                  name.first == ".",
                  name.hasSuffix(".lock") else { return false }
            let identity = String(name.dropFirst().dropLast(".lock".count))
            return isInspectionIdentity(identity)
        }
        if parts.count == 3,
           parts[0] == "inspections", parts[2] == "frames" {
            return type == .typeDirectory && isInspectionIdentity(parts[1])
        }
        if parts.count == 3, parts[0] == "inspections" {
            let identity = parts[1]
            let name = parts[2]
            guard type == .typeRegular, isInspectionIdentity(identity) else { return false }
            return name == "packet.json"
                || name == "packet.md"
                || matches(name, #"^strip-[0-9]{2,}\.(png|jpg)$"#)
        }
        if parts.count == 4,
           parts[0] == "inspections", parts[2] == "frames" {
            return type == .typeRegular
                && isInspectionIdentity(parts[1])
                && matches(parts[3], #"^frame-[a-z0-9-]+\.jpg$"#)
        }
        return false
    }

    private static func isInspectionIdentity(_ value: String) -> Bool {
        matches(value, #"^[a-z0-9][a-z0-9-]{0,41}-[0-9a-f]{8}$"#)
            || matches(value, #"^\.watchthrough-[a-z0-9][a-z0-9-]{0,41}-[0-9a-f]{8}\.tmp-[0-9a-f-]{36}$"#)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func unrecognizedRefreshEntry(_ path: String) -> WatchthroughFailure {
        WatchthroughFailure(
            .operation,
            "refuse to refresh because the analysis contains an unrecognized entry: \(path)"
        )
    }

    private static func unsafeInspectionsDirectory(_ url: URL) -> WatchthroughFailure {
        WatchthroughFailure(
            .operation,
            "unsafe inspections directory; expected an owned directory inside the analysis: \(url.path)"
        )
    }

    private struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
    }
}
