import Foundation
import WatchthroughCore

ProcessSignalRelay.install()

let arguments = Array(CommandLine.arguments.dropFirst())
let jsonRequested = arguments.contains("--json")

do {
    let code = try WatchthroughApplication().run(arguments: arguments)
    exit(code.rawValue)
} catch let failure as WatchthroughFailure {
    reportFailure(
        command: commandName(in: arguments),
        message: failure.message,
        json: jsonRequested,
        exit: failure.category
    )
    exit(failure.category.rawValue)
} catch {
    reportFailure(
        command: commandName(in: arguments),
        message: error.localizedDescription,
        json: jsonRequested,
        exit: .operation
    )
    exit(WatchthroughExit.operation.rawValue)
}

private func reportFailure(
    command: String,
    message: String,
    json: Bool,
    exit: WatchthroughExit
) {
    let redacted = redact(message)
    if json {
        let concise = redacted.components(separatedBy: "\n\n").first ?? redacted
        let result = CommandResult(
            ok: false,
            command: command,
            details: ["exit_code": String(exit.rawValue)],
            warnings: [concise]
        )
        if let data = try? StableJSON.encode(result) {
            FileHandle.standardOutput.write(data)
            return
        }
        let fallback = "{\"schema\":\"watchthrough.result.v1\",\"ok\":false,\"command\":\"unknown\",\"artifacts\":{},\"details\":{\"exit_code\":\"4\"},\"warnings\":[\"result encoding failed\"]}\n"
        FileHandle.standardOutput.write(Data(fallback.utf8))
    } else {
        FileHandle.standardError.write(Data(("watchthrough: \(redacted)\n").utf8))
    }
}

private func commandName(in arguments: [String]) -> String {
    let known = Set(["prepare", "inspect", "status", "help", "version", "--version"])
    guard let value = arguments.first(where: { known.contains($0) }) else { return "unknown" }
    return value == "--version" ? "version" : value
}

private func redact(_ message: String) -> String {
    guard let secret = ProcessInfo.processInfo.environment[WatchthroughCredentials.elevenLabsEnvironmentKey],
          !secret.isEmpty else { return message }
    return message.replacingOccurrences(of: secret, with: "<redacted>")
}
