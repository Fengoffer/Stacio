import AppKit
import Foundation
import StacioCoreBindings

public enum SSHConnectionCoordinatorError: Error, Equatable {
    case missingPasswordSecret
    case missingPrivateKey(path: String)
    case hostKeyRejected
    case proxyJumpSessionNotFound(String)
}

public protocol SSHLiveConnecting {
    func probeHostKey(config: SshConnectionConfig) throws -> LiveSshHostKey
    func applyHostKeyDecision(
        databasePath: String,
        host: String,
        port: UInt16,
        hostKey: [UInt8],
        decision: HostKeyTrustDecision
    ) throws -> HostKeyVerification
    func connect(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> SshConnectionStatus
}

public protocol SSHCredentialResolving {
    func resolve(_ config: SshConnectionConfig) throws -> ResolvedSSHCredential
}

extension SSHCredentialResolver: SSHCredentialResolving {}

public protocol HostKeyConfirming {
    func confirm(_ confirmation: HostKeyConfirmation) throws -> HostKeyTrustDecision
}

public protocol PrivateKeyMaterialLoading {
    func loadPrivateKey(at path: String) throws -> String
}

public struct FilePrivateKeyMaterialLoader: PrivateKeyMaterialLoading {
    public init() {}

    public func loadPrivateKey(at path: String) throws -> String {
        try String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
    }
}

public final class CoreBridgeSSHLiveConnector: SSHLiveConnecting {
    public init() {}

    public func probeHostKey(config: SshConnectionConfig) throws -> LiveSshHostKey {
        try CoreBridge.probeLiveSSHHostKey(config: config)
    }

    public func applyHostKeyDecision(
        databasePath: String,
        host: String,
        port: UInt16,
        hostKey: [UInt8],
        decision: HostKeyTrustDecision
    ) throws -> HostKeyVerification {
        try CoreBridge.applyHostKeyDecisionInDatabase(
            databasePath: databasePath,
            host: host,
            port: port,
            hostKey: hostKey,
            decision: decision
        )
    }

    public func connect(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> SshConnectionStatus {
        try CoreBridge.connectLiveSSH(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256
        )
    }
}

public final class SSHConnectionCoordinator {
    private let connector: SSHLiveConnecting
    private let credentialResolver: SSHCredentialResolving
    private let hostKeyConfirmer: HostKeyConfirming
    private let privateKeyLoader: PrivateKeyMaterialLoading
    private let tunnelLiveSessionStore: TunnelLiveSessionStore?

    public init(
        connector: SSHLiveConnecting,
        credentialResolver: SSHCredentialResolving,
        hostKeyConfirmer: HostKeyConfirming,
        privateKeyLoader: PrivateKeyMaterialLoading = FilePrivateKeyMaterialLoader(),
        tunnelLiveSessionStore: TunnelLiveSessionStore? = nil
    ) {
        self.connector = connector
        self.credentialResolver = credentialResolver
        self.hostKeyConfirmer = hostKeyConfirmer
        self.privateKeyLoader = privateKeyLoader
        self.tunnelLiveSessionStore = tunnelLiveSessionStore
    }

    public func connect(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> SshConnectionStatus {
        let hostKey = try connector.probeHostKey(config: config)
        let verification = try verifyOrConfirmHostKey(
            config: config,
            databasePath: databasePath,
            hostKey: hostKey
        )

        guard verification == .trusted else {
            throw SSHConnectionCoordinatorError.hostKeyRejected
        }

        let credential = try credentialResolver.resolve(config)
        let secret = try makeAuthSecret(config: config, credential: credential)
        let status = try connector.connect(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: hostKey.fingerprintSha256
        )
        if status.connected {
            tunnelLiveSessionStore?.replace(
                with: TunnelLiveSessionContext(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: hostKey.fingerprintSha256
                )
            )
        }
        return status
    }

    public func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        try makeTunnelLiveSessionContext(
            config: config,
            databasePath: databasePath,
            proxyJumpSelection: .disabled
        )
    }

    public func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: (String) throws -> SessionRecord? = { _ in nil }
    ) throws -> TunnelLiveSessionContext {
        let hostKey = try connector.probeHostKey(config: config)
        let verification = try verifyOrConfirmHostKey(
            config: config,
            databasePath: databasePath,
            hostKey: hostKey
        )

        guard verification == .trusted else {
            throw SSHConnectionCoordinatorError.hostKeyRejected
        }

        let credential = try credentialResolver.resolve(config)
        let secret = try makeAuthSecret(config: config, credential: credential)
        let proxyJump = try makeProxyJumpRuntimeConfig(
            selection: proxyJumpSelection,
            targetFingerprintSHA256: hostKey.fingerprintSha256,
            databasePath: databasePath,
            sessionResolver: proxyJumpSessionResolver
        )
        return TunnelLiveSessionContext(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: hostKey.fingerprintSha256,
            proxyJump: proxyJump
        )
    }

    private func makeProxyJumpRuntimeConfig(
        selection: SSHProxyJumpSelection,
        targetFingerprintSHA256: String,
        databasePath: String,
        sessionResolver: (String) throws -> SessionRecord?
    ) throws -> SshProxyJumpRuntimeConfig? {
        let jumpConfig: SshConnectionConfig
        switch selection {
        case .disabled:
            return nil
        case let .session(id):
            guard let session = try sessionResolver(id) else {
                throw SSHConnectionCoordinatorError.proxyJumpSessionNotFound(id)
            }
            let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id)
            jumpConfig = SSHProxyJumpConfigCodec.sshConfig(
                for: session,
                connectTimeoutMs: SSHConnectionDefaults.connectTimeoutMs(fromConfigJSON: configJSON)
            )
        case let .manual(manual):
            jumpConfig = try SSHProxyJumpConfigCodec.sshConfig(for: manual)
        }

        let jumpHostKey = try connector.probeHostKey(config: jumpConfig)
        let jumpVerification = try verifyOrConfirmHostKey(
            config: jumpConfig,
            databasePath: databasePath,
            hostKey: jumpHostKey
        )
        guard jumpVerification == .trusted else {
            throw SSHConnectionCoordinatorError.hostKeyRejected
        }
        let jumpCredential = try credentialResolver.resolve(jumpConfig)
        let jumpSecret = try makeAuthSecret(config: jumpConfig, credential: jumpCredential)
        return SshProxyJumpRuntimeConfig(
            jumpConfig: jumpConfig,
            jumpSecret: jumpSecret,
            jumpExpectedFingerprintSha256: jumpHostKey.fingerprintSha256,
            targetExpectedFingerprintSha256: targetFingerprintSHA256
        )
    }

    private func verifyOrConfirmHostKey(
        config: SshConnectionConfig,
        databasePath: String,
        hostKey: LiveSshHostKey
    ) throws -> HostKeyVerification {
        do {
            let verification = try connector.applyHostKeyDecision(
                databasePath: databasePath,
                host: config.host,
                port: config.port,
                hostKey: Array(hostKey.rawKey),
                decision: .reject
            )
            if case .unknown = verification {
                return try confirmAndApplyHostKeyDecision(
                    config: config,
                    databasePath: databasePath,
                    hostKey: hostKey,
                    reason: .unknown
                )
            }
            return verification
        } catch SshRuntimeError.UnknownHostKey {
            return try confirmAndApplyHostKeyDecision(
                config: config,
                databasePath: databasePath,
                hostKey: hostKey,
                reason: .unknown
            )
        } catch SshRuntimeError.HostKeyChanged {
            return try confirmAndApplyHostKeyDecision(
                config: config,
                databasePath: databasePath,
                hostKey: hostKey,
                reason: .changed(previousFingerprintSHA256: "")
            )
        }
    }

    private func confirmAndApplyHostKeyDecision(
        config: SshConnectionConfig,
        databasePath: String,
        hostKey: LiveSshHostKey,
        reason: HostKeyConfirmationReason
    ) throws -> HostKeyVerification {
        let decision = try hostKeyConfirmer.confirm(
            HostKeyConfirmation(
                host: config.host,
                port: config.port,
                fingerprintSHA256: hostKey.fingerprintSha256,
                reason: reason
            )
        )
        guard decision != .reject else {
            throw SSHConnectionCoordinatorError.hostKeyRejected
        }
        return try connector.applyHostKeyDecision(
            databasePath: databasePath,
            host: config.host,
            port: config.port,
            hostKey: Array(hostKey.rawKey),
            decision: decision
        )
    }

    private func makeAuthSecret(
        config: SshConnectionConfig,
        credential: ResolvedSSHCredential
    ) throws -> SshAuthSecret {
        switch config.authMethod {
        case .password:
            guard let secret = credential.primarySecret else {
                throw SSHConnectionCoordinatorError.missingPasswordSecret
            }
            return .password(value: secret)
        case let .privateKey(keyPath, _):
            return .privateKey(
                privateKeyPem: try privateKeyLoader.loadPrivateKey(at: keyPath),
                passphrase: credential.primarySecret
            )
        case .agent:
            return .agent
        }
    }
}
