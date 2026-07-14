import Foundation
import StacioCoreBindings

public enum QuickConnectAuthMode: Equatable {
    case agent
    case password
    case privateKey

    fileprivate var storageValue: String {
        switch self {
        case .agent:
            return "agent"
        case .password:
            return "password"
        case .privateKey:
            return "privateKey"
        }
    }

    fileprivate static func storageValue(_ value: String) -> QuickConnectAuthMode {
        switch value {
        case "password":
            return .password
        case "privateKey":
            return .privateKey
        default:
            return .agent
        }
    }
}

public struct QuickConnectRequest: CustomStringConvertible, Equatable {
    public let target: String
    public let authMode: QuickConnectAuthMode
    public let privateKeyPath: String?
    public let credentialID: String?
    public let temporarySecret: String?
    public let saveAsSession: Bool
    public let sessionName: String?
    public let configJSON: String?

    public init(
        target: String,
        authMode: QuickConnectAuthMode = .agent,
        privateKeyPath: String? = nil,
        credentialID: String? = nil,
        temporarySecret: String? = nil,
        saveAsSession: Bool = false,
        sessionName: String? = nil,
        configJSON: String? = nil
    ) {
        self.target = target
        self.authMode = authMode
        self.privateKeyPath = privateKeyPath
        self.credentialID = credentialID
        self.temporarySecret = temporarySecret
        self.saveAsSession = saveAsSession
        self.sessionName = sessionName
        self.configJSON = configJSON
    }

    public var description: String {
        "QuickConnectRequest(target: \(target), authMode: \(authMode), privateKeyPath: \(privateKeyPath ?? "nil"), credentialID: \(credentialID ?? "nil"), temporarySecret: \(temporarySecret == nil ? "nil" : "[redacted]"), saveAsSession: \(saveAsSession), sessionName: \(sessionName ?? "nil"), configJSON: \(configJSON == nil ? "nil" : "[set]"))"
    }

    public func withCredentialID(_ credentialID: String?) -> QuickConnectRequest {
        QuickConnectRequest(
            target: target,
            authMode: authMode,
            privateKeyPath: privateKeyPath,
            credentialID: credentialID,
            temporarySecret: temporarySecret,
            saveAsSession: saveAsSession,
            sessionName: sessionName,
            configJSON: configJSON
        )
    }
}

public struct QuickConnectParsedSSHCommand: Equatable {
    public let rawCommand: String
    public let request: QuickConnectRequest
    public let username: String?
    public let host: String
    public let port: UInt16
    public let fingerprint: String

    public var displayTarget: String {
        if let username, !username.isEmpty {
            return "\(username)@\(host)"
        }
        return host
    }
}

public enum QuickConnectSSHCommandParser {
    public static func parse(_ text: String) -> QuickConnectParsedSSHCommand? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false,
              let tokens = shellTokens(raw),
              tokens.first == "ssh"
        else {
            return nil
        }

        var index = 1
        var usernameFromOption: String?
        var port: UInt16 = 22
        var privateKeyPath: String?
        var destination: String?
        var optionParsingEnabled = true

        while index < tokens.count {
            let token = tokens[index]
            if optionParsingEnabled, token == "--" {
                optionParsingEnabled = false
                index += 1
                continue
            }
            if optionParsingEnabled, token.hasPrefix("-"), token != "-" {
                let consumed = consumeSSHOption(
                    tokens: tokens,
                    index: index,
                    username: &usernameFromOption,
                    port: &port,
                    privateKeyPath: &privateKeyPath
                )
                index += consumed
                continue
            }
            if destination == nil {
                destination = token
            }
            index += 1
        }

        guard let destination,
              let endpoint = parseDestination(destination, usernameOverride: usernameFromOption),
              endpoint.host.isEmpty == false
        else {
            return nil
        }

        let target = targetString(username: endpoint.username, host: endpoint.host, port: port)
        return QuickConnectParsedSSHCommand(
            rawCommand: raw,
            request: QuickConnectRequest(
                target: target,
                authMode: optionalTrimmed(privateKeyPath) == nil ? .agent : .privateKey,
                privateKeyPath: privateKeyPath
            ),
            username: endpoint.username,
            host: endpoint.host,
            port: port,
            fingerprint: normalizedFingerprint(for: raw)
        )
    }

    private static func consumeSSHOption(
        tokens: [String],
        index: Int,
        username: inout String?,
        port: inout UInt16,
        privateKeyPath: inout String?
    ) -> Int {
        let token = tokens[index]
        if token == "-p" {
            if index + 1 < tokens.count,
               let parsed = UInt16(tokens[index + 1]) {
                port = parsed
            }
            return 2
        }
        if token.hasPrefix("-p"), token.count > 2,
           let parsed = UInt16(String(token.dropFirst(2))) {
            port = parsed
            return 1
        }
        if token == "-l" {
            if index + 1 < tokens.count {
                username = optionalTrimmed(tokens[index + 1])
            }
            return 2
        }
        if token.hasPrefix("-l"), token.count > 2 {
            username = optionalTrimmed(String(token.dropFirst(2)))
            return 1
        }
        if token == "-i" {
            if index + 1 < tokens.count {
                privateKeyPath = optionalTrimmed(tokens[index + 1])
            }
            return 2
        }
        if token.hasPrefix("-i"), token.count > 2 {
            privateKeyPath = optionalTrimmed(String(token.dropFirst(2)))
            return 1
        }
        if optionRequiresValue(token),
           index + 1 < tokens.count {
            return 2
        }
        return 1
    }

    private static func optionRequiresValue(_ token: String) -> Bool {
        guard token.hasPrefix("-") else {
            return false
        }
        let optionsWithValues: Set<Character> = [
            "b", "c", "D", "E", "e", "F", "I", "J", "L",
            "m", "O", "o", "Q", "R", "S", "W", "w"
        ]
        let compact = token.dropFirst()
        return compact.count == 1 && compact.first.map(optionsWithValues.contains) == true
    }

    private static func parseDestination(
        _ destination: String,
        usernameOverride: String?
    ) -> (username: String?, host: String)? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.contains("/") == false,
              trimmed.contains("=") == false
        else {
            return nil
        }
        let parts = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard parts[0].isEmpty == false, parts[1].isEmpty == false else {
                return nil
            }
            return (usernameOverride ?? parts[0], parts[1])
        }
        return (usernameOverride, trimmed)
    }

    private static func targetString(username: String?, host: String, port: UInt16) -> String {
        let userPrefix = username.flatMap(optionalTrimmed).map { "\($0)@" } ?? ""
        return "\(userPrefix)\(host):\(port)"
    }

    private static func shellTokens(_ input: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false

        for character in input {
            if escaping {
                token.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if token.isEmpty == false {
                    tokens.append(token)
                    token.removeAll()
                }
                continue
            }
            token.append(character)
        }

        guard quote == nil, escaping == false else {
            return nil
        }
        if token.isEmpty == false {
            tokens.append(token)
        }
        return tokens
    }

    private static func normalizedFingerprint(for raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func optionalTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public final class QuickConnectPromptPrefillStore {
    public static let defaultKey = "Stacio.quickConnect.pendingPrefill.v1"

    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = QuickConnectPromptPrefillStore.defaultKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func save(_ request: QuickConnectRequest) {
        guard let data = try? encoder.encode(StoredQuickConnectRequest(request: request)) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }

    public func consume() -> QuickConnectRequest? {
        guard let data = userDefaults.data(forKey: key),
              let stored = try? decoder.decode(StoredQuickConnectRequest.self, from: data)
        else {
            return nil
        }
        userDefaults.removeObject(forKey: key)
        return stored.request()
    }
}

public final class QuickConnectClipboardDismissalStore {
    public static let defaultKey = "Stacio.quickConnect.dismissedClipboardSSH.v1"

    private let userDefaults: UserDefaults
    private let key: String

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = QuickConnectClipboardDismissalStore.defaultKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func isDismissed(fingerprint: String) -> Bool {
        dismissedFingerprints().contains(fingerprint)
    }

    public func dismiss(fingerprint: String) {
        var fingerprints = dismissedFingerprints()
        fingerprints.insert(fingerprint)
        userDefaults.set(Array(Array(fingerprints).suffix(80)), forKey: key)
    }

    private func dismissedFingerprints() -> Set<String> {
        Set(userDefaults.stringArray(forKey: key) ?? [])
    }
}

private struct StoredQuickConnectRequest: Codable {
    let target: String
    let authMode: String
    let privateKeyPath: String?
    let credentialID: String?
    let saveAsSession: Bool
    let sessionName: String?
    let configJSON: String?

    init(request: QuickConnectRequest) {
        target = request.target
        authMode = request.authMode.storageValue
        privateKeyPath = request.privateKeyPath
        credentialID = request.credentialID
        saveAsSession = request.saveAsSession
        sessionName = request.sessionName
        configJSON = request.configJSON
    }

    func request() -> QuickConnectRequest {
        QuickConnectRequest(
            target: target,
            authMode: QuickConnectAuthMode.storageValue(authMode),
            privateKeyPath: privateKeyPath,
            credentialID: credentialID,
            temporarySecret: nil,
            saveAsSession: saveAsSession,
            sessionName: sessionName,
            configJSON: configJSON
        )
    }
}

public enum QuickConnectError: Error, Equatable, LocalizedError {
    case missingCredentialReference
    case missingPrivateKeyPath
    case credentialStorageUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingCredentialReference:
            return L10n.QuickConnect.missingCredentialReference
        case .missingPrivateKeyPath:
            return L10n.QuickConnect.missingPrivateKeyPath
        case .credentialStorageUnavailable:
            return L10n.SessionErrors.credentialStorageUnavailable
        }
    }
}

@MainActor
public final class QuickConnectCoordinator {
    private let remoteSessionStarter: RemoteSSHSessionStarting
    private let defaultUsernameProvider: () -> String
    private let connectTimeoutMs: UInt32

    public init(
        remoteSessionStarter: RemoteSSHSessionStarting,
        defaultUsernameProvider: @escaping () -> String = NSUserName,
        connectTimeoutMs: UInt32 = SSHConnectionDefaults.fastConnectTimeoutMs
    ) {
        self.remoteSessionStarter = remoteSessionStarter
        self.defaultUsernameProvider = defaultUsernameProvider
        self.connectTimeoutMs = connectTimeoutMs
    }

    @discardableResult
    public func connect(_ request: QuickConnectRequest) throws -> LiveShellStatus {
        let target = try CoreBridge.parseQuickConnect(request.target)
        let username = target.username ?? defaultUsernameProvider()
        let config = SshConnectionConfig(
            host: target.host,
            port: target.port,
            username: username,
            authMethod: try authMethod(for: request),
            connectTimeoutMs: connectTimeoutMs
        )
        return try remoteSessionStarter.openSessionTab(
            config: config,
            title: "\(username)@\(target.host)"
        )
    }

    @discardableResult
    public func connect(_ input: String) throws -> LiveShellStatus {
        try connect(QuickConnectRequest(target: input))
    }

    private func authMethod(for request: QuickConnectRequest) throws -> SshAuthMethod {
        switch request.authMode {
        case .agent:
            return .agent
        case .password:
            guard let credentialID = optionalTrimmed(request.credentialID) else {
                throw QuickConnectError.missingCredentialReference
            }
            return .password(credentialRef: credentialID)
        case .privateKey:
            guard let privateKeyPath = optionalTrimmed(request.privateKeyPath) else {
                throw QuickConnectError.missingPrivateKeyPath
            }
            return .privateKey(
                keyPath: privateKeyPath,
                passphraseRef: optionalTrimmed(request.credentialID)
            )
        }
    }

    private func optionalTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
