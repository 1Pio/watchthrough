import Foundation

public struct PrepareOptions: Equatable, Sendable {
    public var source: URL
    public var output: URL?
    public var transcriber: String
    public var refresh: Bool
}

public struct InspectOptions: Equatable, Sendable {
    public var analysis: URL
    public var selector: InspectionSelector
    public var selectorText: String
    public var every: SamplingInterval?
    public var cells: Int
}

public struct StatusOptions: Equatable, Sendable {
    public var analysis: URL?
}

public enum CLICommand: Equatable, Sendable {
    case prepare(PrepareOptions)
    case inspect(InspectOptions)
    case status(StatusOptions)
    case help
    case version
}

public struct CLIInvocation: Equatable, Sendable {
    public var json: Bool
    public var command: CLICommand
}

public enum CLIParser {
    public static let help = """
    watchthrough \(WatchthroughVersion.current)

    Usage:
      watchthrough [--json] prepare VIDEO [--out ANALYSIS]
        [--transcriber auto|none|sidecar|macparakeet|scribe|command:NAME] [--refresh]
      watchthrough [--json] inspect ANALYSIS SELECTOR [--every DURATION|Nf] [--cells N]
      watchthrough [--json] status [ANALYSIS]

    Selectors:
      overview | events | event:E0042 | 12:30.250 | 12:30..12:45 | frame:18720

    The core accepts local video files only. For YouTube, acquire a local copy
    through references/youtube.md first.
    """

    public static func parse(_ rawArguments: [String]) throws -> CLIInvocation {
        var arguments = rawArguments
        let json = removeFlag("--json", from: &arguments)

        guard let first = arguments.first else {
            return CLIInvocation(json: json, command: .help)
        }
        arguments.removeFirst()

        if ["prepare", "inspect", "status"].contains(first),
           arguments.count == 1,
           (arguments[0] == "--help" || arguments[0] == "-h") {
            return CLIInvocation(json: json, command: .help)
        }

        switch first {
        case "help", "--help", "-h":
            guard arguments.isEmpty else {
                throw usage("help takes no arguments")
            }
            return CLIInvocation(json: json, command: .help)
        case "--version", "version":
            guard arguments.isEmpty else {
                throw usage("version takes no arguments")
            }
            return CLIInvocation(json: json, command: .version)
        case "prepare":
            return CLIInvocation(json: json, command: .prepare(try parsePrepare(arguments)))
        case "inspect":
            return CLIInvocation(json: json, command: .inspect(try parseInspect(arguments)))
        case "status":
            return CLIInvocation(json: json, command: .status(try parseStatus(arguments)))
        default:
            throw usage("unknown subcommand '\(first)'")
        }
    }

    private static func parsePrepare(_ raw: [String]) throws -> PrepareOptions {
        var arguments = raw
        let refresh = removeFlag("--refresh", from: &arguments)
        let output = try removeValue("--out", from: &arguments)
        let transcriber = try removeValue("--transcriber", from: &arguments) ?? "auto"

        guard arguments.count == 1 else {
            throw usage("prepare requires exactly one local VIDEO")
        }
        let input = arguments[0]
        if looksLikeURL(input) {
            throw usage("prepare accepts a local video, not a URL; use references/youtube.md to acquire it")
        }
        if transcriber != "auto",
           transcriber != "none",
           transcriber != "sidecar",
           transcriber != "macparakeet",
           transcriber != "scribe",
           !transcriber.hasPrefix("command:") {
            throw usage("unsupported transcriber '\(transcriber)'")
        }
        if transcriber.hasPrefix("command:") && transcriber.dropFirst("command:".count).isEmpty {
            throw usage("command transcriber requires a name, for example command:whisperkit")
        }

        return PrepareOptions(
            source: fileURL(input),
            output: output.map(fileURL),
            transcriber: transcriber,
            refresh: refresh
        )
    }

    private static func parseInspect(_ raw: [String]) throws -> InspectOptions {
        var arguments = raw
        let everyText = try removeValue("--every", from: &arguments)
        let cellsText = try removeValue("--cells", from: &arguments)
        guard arguments.count == 2 else {
            throw usage("inspect requires ANALYSIS and SELECTOR")
        }
        let cells = try cellsText.map(parseCells) ?? 15
        let selectorText = arguments[1]
        return InspectOptions(
            analysis: fileURL(arguments[0]),
            selector: try parseSelector(selectorText),
            selectorText: selectorText,
            every: try everyText.map(parseSampling),
            cells: cells
        )
    }

    private static func parseStatus(_ arguments: [String]) throws -> StatusOptions {
        guard arguments.count <= 1 else {
            throw usage("status accepts at most one ANALYSIS path")
        }
        return StatusOptions(analysis: arguments.first.map(fileURL))
    }

    public static func parseSelector(_ value: String) throws -> InspectionSelector {
        switch value {
        case "overview": return .overview
        case "events": return .events
        default: break
        }
        if value.hasPrefix("event:") {
            let id = String(value.dropFirst("event:".count)).uppercased()
            guard id.range(of: #"^E[0-9]{4}$"#, options: .regularExpression) != nil else {
                throw usage("event selector must look like event:E0042")
            }
            return .event(id)
        }
        if value.hasPrefix("frame:") {
            let raw = value.dropFirst("frame:".count)
            guard let ordinal = Int(raw), ordinal >= 0 else {
                throw usage("frame selector requires a non-negative decoded ordinal")
            }
            return .frame(ordinal)
        }
        let rangeParts = value.components(separatedBy: "..")
        if rangeParts.count == 2 {
            let start = try parseTime(rangeParts[0])
            let end = try parseTime(rangeParts[1])
            guard end > start else {
                throw usage("range end must be after its start")
            }
            return .range(start, end)
        }
        if rangeParts.count > 2 {
            throw usage("invalid range selector '\(value)'")
        }
        return .time(try parseTime(value))
    }

    public static func parseSampling(_ value: String) throws -> SamplingInterval {
        let normalized = value.lowercased()
        if normalized.hasSuffix("f") {
            guard let count = Int(normalized.dropLast()), count > 0 else {
                throw usage("frame interval must be a positive value such as 10f")
            }
            return .frames(count)
        }
        let seconds = try parseDuration(value)
        guard seconds > 0 else {
            throw usage("sampling interval must be positive")
        }
        return .seconds(seconds)
    }

    public static func parseDuration(_ value: String) throws -> Double {
        let normalized = value.lowercased()
        if normalized.hasSuffix("ms") {
            guard let milliseconds = Double(normalized.dropLast(2)), milliseconds > 0 else {
                throw usage("invalid millisecond duration '\(value)'")
            }
            return milliseconds / 1_000
        }
        if normalized.hasSuffix("s") {
            guard let seconds = Double(normalized.dropLast()), seconds > 0 else {
                throw usage("invalid second duration '\(value)'")
            }
            return seconds
        }
        return try parseTime(value)
    }

    public static func parseTime(_ value: String) throws -> Double {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw usage("empty time value")
        }
        let sign: Double
        if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        } else if text.hasPrefix("+") {
            sign = 1
            text.removeFirst()
        } else {
            sign = 1
        }
        guard !text.isEmpty else { throw usage("cannot parse time '\(value)'") }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else {
            throw usage("cannot parse time '\(value)'")
        }
        guard let last = Double(pieces.last!), last >= 0 else {
            throw usage("cannot parse time '\(value)'")
        }
        var total = last
        if pieces.count >= 2 {
            guard let minutes = Int(pieces[pieces.count - 2]), minutes >= 0 else {
                throw usage("cannot parse time '\(value)'")
            }
            if pieces.count == 3 && minutes >= 60 {
                throw usage("minutes must be below 60 in HH:MM:SS")
            }
            total += Double(minutes * 60)
        }
        if pieces.count == 3 {
            guard let hours = Int(pieces[0]), hours >= 0, last < 60 else {
                throw usage("cannot parse time '\(value)'")
            }
            total += Double(hours * 3_600)
        } else if pieces.count == 2 && last >= 60 {
            throw usage("seconds must be below 60 in MM:SS")
        }
        guard total.isFinite else {
            throw usage("cannot parse time '\(value)'")
        }
        return sign * total
    }

    public static func formatTime(_ seconds: Double, milliseconds: Bool = true) -> String {
        guard seconds.isFinite else { return "invalid" }
        let sign = seconds < 0 ? "-" : ""
        if milliseconds {
            let total = Int64((abs(seconds) * 1_000).rounded())
            let hours = total / 3_600_000
            let minutes = total % 3_600_000 / 60_000
            let wholeSeconds = total % 60_000 / 1_000
            let fraction = total % 1_000
            if hours > 0 {
                return String(format: "%@%02lld:%02lld:%02lld.%03lld", sign, hours, minutes, wholeSeconds, fraction)
            }
            return String(format: "%@%02lld:%02lld.%03lld", sign, minutes, wholeSeconds, fraction)
        }
        let total = Int64(abs(seconds).rounded())
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let wholeSeconds = total % 60
        if hours > 0 {
            return String(format: "%@%02lld:%02lld:%02lld", sign, hours, minutes, wholeSeconds)
        }
        return String(format: "%@%02lld:%02lld", sign, minutes, wholeSeconds)
    }

    public static func balancedPageSizes(total: Int, maximum: Int) -> [Int] {
        StripRenderer.balancedPageSizes(itemCount: total, maximumPerPage: maximum)
    }

    private static func parseCells(_ value: String) throws -> Int {
        guard let cells = Int(value), (1...20).contains(cells) else {
            throw usage("--cells must be between 1 and 20")
        }
        return cells
    }

    private static func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
        var found = false
        arguments.removeAll {
            if $0 == flag {
                found = true
                return true
            }
            return false
        }
        return found
    }

    private static func removeValue(_ flag: String, from arguments: inout [String]) throws -> String? {
        let matches = arguments.indices.filter { arguments[$0] == flag }
        guard matches.count <= 1 else {
            throw usage("\(flag) may only be provided once")
        }
        guard let index = matches.first else { return nil }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw usage("\(flag) requires a value")
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
        return value
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func fileURL(_ value: String) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func usage(_ message: String) -> WatchthroughFailure {
        WatchthroughFailure(.usage, "\(message)\n\n\(help)")
    }
}
