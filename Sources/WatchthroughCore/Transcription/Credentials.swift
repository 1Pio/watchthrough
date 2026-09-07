import Foundation
import Security

public enum CredentialOrigin: String, Sendable {
    case environment
    case keychain
    case dotEnv = "dotenv"
}

/// A credential that is deliberately unprintable. Provider code in this module can
/// read `value`, while diagnostics can safely report only `origin`.
public struct SecretCredential: @unchecked Sendable, CustomStringConvertible {
    public let origin: CredentialOrigin
    let value: String

    init(value: String, origin: CredentialOrigin) {
        self.value = value
        self.origin = origin
    }

    public var description: String { "<redacted:\(origin.rawValue)>" }
}

public enum WatchthroughCredentials {
    public static let elevenLabsEnvironmentKey = "ELEVENLABS_API_KEY"
    public static let elevenLabsKeychainService = "watchthrough"
    public static let elevenLabsKeychainAccount = "ELEVENLABS_API_KEY"

    public static func dotEnvURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("watchthrough", isDirectory: true)
            .appendingPathComponent(".env", isDirectory: false)
    }

    /// Resolves in a fixed, auditable order: process environment, macOS Keychain,
    /// then `~/.config/watchthrough/.env`. No working-directory `.env` is read.
    public static func elevenLabsAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> SecretCredential? {
        if let value = nonEmpty(environment[elevenLabsEnvironmentKey]) {
            return SecretCredential(value: value, origin: .environment)
        }

        if let value = try keychainValue(
            service: elevenLabsKeychainService,
            account: elevenLabsKeychainAccount
        ) {
            return SecretCredential(value: value, origin: .keychain)
        }

        let url = dotEnvURL(homeDirectory: homeDirectory)
        if let value = try dotEnvValue(named: elevenLabsEnvironmentKey, at: url) {
            return SecretCredential(value: value, origin: .dotEnv)
        }
        return nil
    }

    static func dotEnvValue(named name: String, at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let contents = try String(contentsOf: url, encoding: .utf8)

        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }

            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            return nonEmpty(value)
        }
        return nil
    }

    static func keychainValue(service: String, account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecNotAvailable
            || status == errSecMissingEntitlement
            || status == errSecParam {
            return nil
        }
        guard status == errSecSuccess else {
            throw WatchthroughFailure(
                .readiness,
                "Could not read the ElevenLabs credential from macOS Keychain (status \(status))."
            )
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              let value = nonEmpty(value) else {
            throw WatchthroughFailure(.readiness, "The ElevenLabs Keychain item is not valid UTF-8.")
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
