import Foundation
import StacioCoreBindings

public enum SSHProxyJumpConfigError: Error, Equatable {
    case referencedSessionNotFound(String)
    case invalidManualHost
    case invalidManualPort
    case invalidManualUsername
}

public enum SSHProxyJumpSelection: Equatable, Sendable {
    case disabled
    case session(id: String)
    case manual(ManualSSHProxyJumpConfig)
}

public struct ManualSSHProxyJumpConfig: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let credentialID: String?
    public let privateKeyPath: String?
    public let connectTimeoutMs: UInt32?

    public init(
        host: String,
        port: UInt16,
        username: String,
        credentialID: String?,
        privateKeyPath: String?,
        connectTimeoutMs: UInt32? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credentialID = credentialID
        self.privateKeyPath = privateKeyPath
        self.connectTimeoutMs = connectTimeoutMs
    }
}

struct SSHProxyJumpSessionConfig: Codable, Equatable {
    let mode: String?
    let sessionId: String?
    let host: String?
    let port: UInt16?
    let username: String?
    let credentialId: String?
    let privateKeyPath: String?
    let connectTimeoutMs: UInt32?
}

enum SSHProxyJumpConfigCodec {
    static func selection(from configJSON: String?) -> SSHProxyJumpSelection {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxyObject = object["proxyJump"] as? [String: Any],
              let proxyData = try? JSONSerialization.data(withJSONObject: proxyObject),
              let decoded = try? JSONDecoder().decode(SSHProxyJumpSessionConfig.self, from: proxyData)
        else {
            return .disabled
        }

        switch decoded.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "session":
            guard let id = optionalTrimmed(decoded.sessionId) else {
                return .disabled
            }
            return .session(id: id)
        case "manual":
            guard let host = optionalTrimmed(decoded.host),
                  let username = optionalTrimmed(decoded.username),
                  let port = decoded.port,
                  port > 0
            else {
                return .disabled
            }
            return .manual(
                ManualSSHProxyJumpConfig(
                    host: host,
                    port: port,
                    username: username,
                    credentialID: optionalTrimmed(decoded.credentialId),
                    privateKeyPath: optionalTrimmed(decoded.privateKeyPath),
                    connectTimeoutMs: decoded.connectTimeoutMs
                )
            )
        default:
            return .disabled
        }
    }

    static func proxyObject(from selection: SSHProxyJumpSelection) -> [String: Any]? {
        switch selection {
        case .disabled:
            return nil
        case let .session(id):
            guard let id = optionalTrimmed(id) else {
                return nil
            }
            return [
                "mode": "session",
                "sessionId": id
            ]
        case let .manual(config):
            var object: [String: Any] = [
                "mode": "manual",
                "host": config.host,
                "port": Int(config.port),
                "username": config.username
            ]
            if let credentialID = optionalTrimmed(config.credentialID) {
                object["credentialId"] = credentialID
            }
            if let privateKeyPath = optionalTrimmed(config.privateKeyPath) {
                object["privateKeyPath"] = privateKeyPath
            }
            if let connectTimeoutMs = config.connectTimeoutMs {
                object["connectTimeoutMs"] = Int(connectTimeoutMs)
            }
            return object
        }
    }

    static func config(
        for selection: SSHProxyJumpSelection,
        sessionResolver: (String) throws -> SessionRecord?
    ) throws -> SshConnectionConfig? {
        switch selection {
        case .disabled:
            return nil
        case let .session(id):
            guard let session = try sessionResolver(id) else {
                throw SSHProxyJumpConfigError.referencedSessionNotFound(id)
            }
            return sshConfig(for: session, connectTimeoutMs: nil)
        case let .manual(manual):
            return try sshConfig(for: manual)
        }
    }

    static func sshConfig(for session: SessionRecord, connectTimeoutMs: UInt32?) -> SshConnectionConfig {
        SshConnectionConfig(
            host: session.host,
            port: UInt16(clamping: session.port),
            username: optionalTrimmed(session.username) ?? NSUserName(),
            authMethod: authMethod(
                credentialID: optionalTrimmed(session.credentialId),
                privateKeyPath: optionalTrimmed(session.privateKeyPath)
            ),
            connectTimeoutMs: connectTimeoutMs ?? SSHConnectionDefaults.fastConnectTimeoutMs
        )
    }

    static func sshConfig(for manual: ManualSSHProxyJumpConfig) throws -> SshConnectionConfig {
        guard optionalTrimmed(manual.host) != nil else {
            throw SSHProxyJumpConfigError.invalidManualHost
        }
        guard manual.port > 0 else {
            throw SSHProxyJumpConfigError.invalidManualPort
        }
        guard optionalTrimmed(manual.username) != nil else {
            throw SSHProxyJumpConfigError.invalidManualUsername
        }
        return SshConnectionConfig(
            host: manual.host,
            port: manual.port,
            username: manual.username,
            authMethod: authMethod(
                credentialID: optionalTrimmed(manual.credentialID),
                privateKeyPath: optionalTrimmed(manual.privateKeyPath)
            ),
            connectTimeoutMs: manual.connectTimeoutMs ?? SSHConnectionDefaults.fastConnectTimeoutMs
        )
    }

    private static func authMethod(credentialID: String?, privateKeyPath: String?) -> SshAuthMethod {
        if let privateKeyPath {
            return .privateKey(keyPath: privateKeyPath, passphraseRef: credentialID)
        }
        if let credentialID {
            return .password(credentialRef: credentialID)
        }
        return .agent
    }

    private static func optionalTrimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
