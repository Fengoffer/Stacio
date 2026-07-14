import XCTest
@testable import StacioApp
import StacioCoreBindings

final class SSHConnectionCoordinatorTests: XCTestCase {
    func testUnknownHostTrustsBeforeResolvingCredentialAndConnecting() throws {
        let connector = RecordingSSHLiveConnector(
            probeResult: liveHostKey(raw: "host-key"),
            trustResults: [
                .unknown(fingerprint: CoreBridge.fingerprintHostKey(Array("host-key".utf8))),
                .trusted
            ],
            connectStatus: connectedStatus()
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
        )
        let confirmer = RecordingHostKeyConfirming(decision: .trustAndSave)
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: confirmer,
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:])
        )

        let status = try coordinator.connect(
            config: passwordConfig(),
            databasePath: "/tmp/Stacio-test.sqlite"
        )

        XCTAssertTrue(status.connected)
        XCTAssertEqual(connector.events, [
            "probe:example.com:22",
            "trust:example.com:22:reject",
            "trust:example.com:22:trustAndSave",
            "connect"
        ])
        XCTAssertEqual(credentialResolver.resolveCount, 1)
        XCTAssertEqual(confirmer.confirmations.count, 1)
        XCTAssertFalse(String(describing: connector.lastSecret).contains("super-secret"))
    }

    func testSuccessfulConnectStoresTunnelLiveSessionContextForTunnels() throws {
        let connector = RecordingSSHLiveConnector(
            probeResult: liveHostKey(raw: "host-key"),
            trustResults: [.trusted],
            connectStatus: connectedStatus()
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
        )
        let contextStore = TunnelLiveSessionStore()
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: RecordingHostKeyConfirming(decision: .reject),
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:]),
            tunnelLiveSessionStore: contextStore
        )

        let status = try coordinator.connect(
            config: passwordConfig(),
            databasePath: "/tmp/Stacio-test.sqlite"
        )

        XCTAssertTrue(status.connected)
        XCTAssertEqual(contextStore.current()?.config.host, "example.com")
        XCTAssertEqual(contextStore.current()?.expectedFingerprintSHA256, liveHostKey(raw: "host-key").fingerprintSha256)
        XCTAssertFalse(String(describing: contextStore).contains("super-secret"))
    }

    func testChangedHostKeyRejectsBeforeCredentialResolution() throws {
        let connector = RecordingSSHLiveConnector(
            probeResult: liveHostKey(raw: "new-key"),
            trustResults: [.unknown(fingerprint: CoreBridge.fingerprintHostKey(Array("new-key".utf8)))],
            trustError: SshRuntimeError.HostKeyChanged,
            connectStatus: connectedStatus()
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
        )
        let confirmer = RecordingHostKeyConfirming(decision: .reject)
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: confirmer,
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:])
        )

        XCTAssertThrowsError(
            try coordinator.connect(config: passwordConfig(), databasePath: "/tmp/Stacio-test.sqlite")
        )
        XCTAssertEqual(credentialResolver.resolveCount, 0)
        XCTAssertEqual(connector.events, [
            "probe:example.com:22",
            "trust:example.com:22:reject"
        ])
    }

    func testChangedHostKeyCanBeTrustedAndReplacedBeforeConnecting() throws {
        let connector = RecordingSSHLiveConnector(
            probeResult: liveHostKey(raw: "new-key"),
            trustResults: [.trusted],
            trustErrors: [SshRuntimeError.HostKeyChanged, nil],
            connectStatus: connectedStatus()
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
        )
        let confirmer = RecordingHostKeyConfirming(decision: .trustAndSave)
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: confirmer,
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:])
        )

        let status = try coordinator.connect(
            config: passwordConfig(),
            databasePath: "/tmp/Stacio-test.sqlite"
        )

        XCTAssertTrue(status.connected)
        XCTAssertEqual(connector.events, [
            "probe:example.com:22",
            "trust:example.com:22:reject",
            "trust:example.com:22:trustAndSave",
            "connect"
        ])
        XCTAssertEqual(confirmer.confirmations.count, 1)
        XCTAssertEqual(confirmer.confirmations.first?.reason, .changed(previousFingerprintSHA256: ""))
        XCTAssertEqual(credentialResolver.resolveCount, 1)
    }

    func testPrivateKeyAuthLoadsKeyMaterialWithoutSystemCommand() throws {
        let connector = RecordingSSHLiveConnector(
            probeResult: liveHostKey(raw: "host-key"),
            trustResults: [.trusted],
            connectStatus: connectedStatus(authMethod: "private_key")
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .privateKeyPassphrase, primarySecret: "key-passphrase")
        )
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: RecordingHostKeyConfirming(decision: .reject),
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: ["/Users/me/.ssh/id_ed25519": "PRIVATE KEY"])
        )

        let status = try coordinator.connect(
            config: privateKeyConfig(),
            databasePath: "/tmp/Stacio-test.sqlite"
        )

        XCTAssertEqual(status.authMethod, "private_key")
        XCTAssertEqual(connector.lastSecretKind, .privateKey)
        XCTAssertFalse(String(describing: connector.lastSecret).contains("PRIVATE KEY"))
        XCTAssertFalse(connector.events.joined(separator: " ").contains("ssh "))
    }

    func testBuildTunnelLiveSessionContextReusesHostKeyAndResolvedCredential() throws {
        let connector = RecordingSSHLiveConnector(
            probeResult: liveHostKey(raw: "host-key"),
            trustResults: [.trusted],
            connectStatus: connectedStatus()
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
        )
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: RecordingHostKeyConfirming(decision: .reject),
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:])
        )

        let context = try coordinator.makeTunnelLiveSessionContext(
            config: passwordConfig(),
            databasePath: "/tmp/Stacio-test.sqlite"
        )

        XCTAssertEqual(context.config.host, "example.com")
        XCTAssertEqual(context.expectedFingerprintSHA256, liveHostKey(raw: "host-key").fingerprintSha256)
        XCTAssertEqual(credentialResolver.resolveCount, 1)
        XCTAssertEqual(connector.events, [
            "probe:example.com:22",
            "trust:example.com:22:reject"
        ])
        XCTAssertFalse(String(describing: context.secret).contains("super-secret"))
    }

    func testBuildTunnelLiveSessionContextConfirmsProxyJumpHostKeySeparately() throws {
        let targetKey = liveHostKey(host: "example.com", port: 22, raw: "target-key")
        let jumpKey = liveHostKey(host: "bastion.example.com", port: 2222, raw: "jump-key")
        let connector = RecordingSSHLiveConnector(
            probeResults: [targetKey, jumpKey],
            trustResults: [.trusted, .trusted],
            connectStatus: connectedStatus()
        )
        let credentialResolver = RecordingSSHCredentialResolving(
            credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
        )
        let coordinator = SSHConnectionCoordinator(
            connector: connector,
            credentialResolver: credentialResolver,
            hostKeyConfirmer: RecordingHostKeyConfirming(decision: .reject),
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:])
        )

        let context = try coordinator.makeTunnelLiveSessionContext(
            config: passwordConfig(),
            databasePath: "/tmp/Stacio-test.sqlite",
            proxyJumpSelection: .manual(
                ManualSSHProxyJumpConfig(
                    host: "bastion.example.com",
                    port: 2222,
                    username: "ops",
                    credentialID: "jump-password-ref",
                    privateKeyPath: nil
                )
            )
        )

        let proxyJump = try XCTUnwrap(context.proxyJump)
        XCTAssertEqual(proxyJump.jumpConfig.host, "bastion.example.com")
        XCTAssertEqual(proxyJump.jumpExpectedFingerprintSha256, jumpKey.fingerprintSha256)
        XCTAssertEqual(proxyJump.targetExpectedFingerprintSha256, targetKey.fingerprintSha256)
        XCTAssertEqual(connector.events, [
            "probe:example.com:22",
            "trust:example.com:22:reject",
            "probe:bastion.example.com:2222",
            "trust:bastion.example.com:2222:reject"
        ])
        XCTAssertEqual(credentialResolver.resolveCount, 2)
    }

    func testSavedSessionProxyJumpInheritsPersistedConnectTimeout() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let jumpSession = try CoreBridge.createSessionRecord(
            databasePath: databaseURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Bastion",
                protocol: "ssh",
                host: "bastion.example.com",
                port: 2222,
                username: "ops",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: #"{"connectTimeoutMs":45000}"#
            )
        )
        let targetKey = liveHostKey(host: "example.com", port: 22, raw: "target-key")
        let jumpKey = liveHostKey(host: "bastion.example.com", port: 2222, raw: "jump-key")
        let coordinator = SSHConnectionCoordinator(
            connector: RecordingSSHLiveConnector(
                probeResults: [targetKey, jumpKey],
                trustResults: [.trusted, .trusted],
                connectStatus: connectedStatus()
            ),
            credentialResolver: RecordingSSHCredentialResolving(
                credential: ResolvedSSHCredential(kind: .password, primarySecret: "super-secret")
            ),
            hostKeyConfirmer: RecordingHostKeyConfirming(decision: .reject),
            privateKeyLoader: InMemoryPrivateKeyLoader(keys: [:])
        )

        let context = try coordinator.makeTunnelLiveSessionContext(
            config: passwordConfig(),
            databasePath: databaseURL.path,
            proxyJumpSelection: .session(id: jumpSession.id),
            proxyJumpSessionResolver: { id in id == jumpSession.id ? jumpSession : nil }
        )

        XCTAssertEqual(context.proxyJump?.jumpConfig.connectTimeoutMs, 45_000)
    }
}

private enum CapturedSecretKind: Equatable {
    case password
    case privateKey
    case agent
}

private final class RecordingSSHLiveConnector: SSHLiveConnecting {
    var events: [String] = []
    var lastSecret: SshAuthSecret?
    var lastSecretKind: CapturedSecretKind?
    private var probeResults: [LiveSshHostKey]
    private var trustResults: [HostKeyVerification]
    private let trustError: Error?
    private var trustErrors: [Error?]
    private let connectStatus: SshConnectionStatus

    init(
        probeResult: LiveSshHostKey,
        trustResults: [HostKeyVerification],
        trustError: Error? = nil,
        trustErrors: [Error?] = [],
        connectStatus: SshConnectionStatus
    ) {
        self.probeResults = [probeResult]
        self.trustResults = trustResults
        self.trustError = trustError
        self.trustErrors = trustErrors
        self.connectStatus = connectStatus
    }

    init(
        probeResults: [LiveSshHostKey],
        trustResults: [HostKeyVerification],
        trustError: Error? = nil,
        trustErrors: [Error?] = [],
        connectStatus: SshConnectionStatus
    ) {
        self.probeResults = probeResults
        self.trustResults = trustResults
        self.trustError = trustError
        self.trustErrors = trustErrors
        self.connectStatus = connectStatus
    }

    func probeHostKey(config: SshConnectionConfig) throws -> LiveSshHostKey {
        events.append("probe:\(config.host):\(config.port)")
        return probeResults.removeFirst()
    }

    func applyHostKeyDecision(
        databasePath: String,
        host: String,
        port: UInt16,
        hostKey: [UInt8],
        decision: HostKeyTrustDecision
    ) throws -> HostKeyVerification {
        events.append("trust:\(host):\(port):\(decision.eventName)")
        if !trustErrors.isEmpty {
            if let error = trustErrors.removeFirst() {
                throw error
            }
            return trustResults.removeFirst()
        }
        if let trustError { throw trustError }
        return trustResults.removeFirst()
    }

    func connect(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> SshConnectionStatus {
        events.append("connect")
        lastSecret = secret
        switch secret {
        case .password:
            lastSecretKind = .password
        case .privateKey:
            lastSecretKind = .privateKey
        case .agent:
            lastSecretKind = .agent
        }
        XCTAssertFalse(expectedFingerprintSHA256.isEmpty)
        return connectStatus
    }
}

private final class RecordingSSHCredentialResolving: SSHCredentialResolving {
    var resolveCount = 0
    private let credential: ResolvedSSHCredential

    init(credential: ResolvedSSHCredential) {
        self.credential = credential
    }

    func resolve(_ config: SshConnectionConfig) throws -> ResolvedSSHCredential {
        resolveCount += 1
        return credential
    }
}

private final class RecordingHostKeyConfirming: HostKeyConfirming {
    var confirmations: [HostKeyConfirmation] = []
    private let decision: HostKeyTrustDecision

    init(decision: HostKeyTrustDecision) {
        self.decision = decision
    }

    func confirm(_ confirmation: HostKeyConfirmation) throws -> HostKeyTrustDecision {
        confirmations.append(confirmation)
        return decision
    }
}

private struct InMemoryPrivateKeyLoader: PrivateKeyMaterialLoading {
    let keys: [String: String]

    func loadPrivateKey(at path: String) throws -> String {
        guard let value = keys[path] else {
            throw SSHConnectionCoordinatorError.missingPrivateKey(path: path)
        }
        return value
    }
}

private extension HostKeyTrustDecision {
    var eventName: String {
        switch self {
        case .trustOnce:
            "trustOnce"
        case .trustAndSave:
            "trustAndSave"
        case .reject:
            "reject"
        }
    }
}

private func liveHostKey(host: String = "example.com", port: UInt16 = 22, raw: String) -> LiveSshHostKey {
    let bytes = Array(raw.utf8)
    return LiveSshHostKey(
        host: host,
        port: port,
        keyType: "ssh-ed25519",
        fingerprintSha256: CoreBridge.fingerprintHostKey(bytes),
        rawKey: Data(bytes),
        keyLen: UInt64(bytes.count)
    )
}

private func passwordConfig() -> SshConnectionConfig {
    SshConnectionConfig(
        host: "example.com",
        port: 22,
        username: "deploy",
        authMethod: .password(credentialRef: "password-ref"),
        connectTimeoutMs: 10_000
    )
}

private func privateKeyConfig() -> SshConnectionConfig {
    SshConnectionConfig(
        host: "example.com",
        port: 22,
        username: "deploy",
        authMethod: .privateKey(keyPath: "/Users/me/.ssh/id_ed25519", passphraseRef: "passphrase-ref"),
        connectTimeoutMs: 10_000
    )
}

private func connectedStatus(authMethod: String = "password") -> SshConnectionStatus {
    SshConnectionStatus(
        connected: true,
        host: "example.com",
        port: 22,
        username: "deploy",
        authMethod: authMethod,
        diagnostic: "connected"
    )
}
