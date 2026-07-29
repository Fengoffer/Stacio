import StacioCoreBindings
import SQLite3
import XCTest
@testable import StacioApp

@MainActor
final class SavedSessionConnectionFlowTests: XCTestCase {
    func testConsoleSavedSessionDecodesStoredConfigAndStartsConsoleWithoutSerial() throws {
        let tempURL = savedConsoleTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let config = savedConsoleConfig(macOSPeripheralUUID: UUID().uuidString)
        let savedSession = try createSavedConsoleSession(databasePath: tempURL.path, config: config)
        let consoleStarter = SavedSessionRecordingConsoleStarter()
        let serialStarter = SavedSessionRecordingSerialStarter()
        let openRecorder = SavedSessionRecordingOpenRecorder()
        let workbench = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionStore: TunnelLiveSessionStore(),
            serialSessionStarter: serialStarter,
            consoleSessionStarter: consoleStarter,
            savedSessionOpenRecorder: openRecorder,
            databasePathProvider: { tempURL.path }
        )

        let status = try workbench.openSavedSession(savedSession)

        let normalizedConfig = try CoreBridge.parseConsoleSessionConfig(
            json: CoreBridge.serializeConsoleSessionConfig(config: config)
        )
        XCTAssertEqual(consoleStarter.openedConfigs, [normalizedConfig])
        XCTAssertEqual(consoleStarter.openedTitles, ["Core Switch Console"])
        XCTAssertEqual(status.runtimeId, "term_console_saved")
        XCTAssertEqual(status.status, "running")
        XCTAssertTrue(serialStarter.openedConfigs.isEmpty)
        XCTAssertEqual(openRecorder.openedSessionIDs, [savedSession.id])
    }

    func testConsoleSavedSessionRejectsMissingCurrentMacOSBinding() throws {
        let tempURL = savedConsoleTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let savedSession = try createSavedConsoleSession(
            databasePath: tempURL.path,
            config: savedConsoleConfig(macOSPeripheralUUID: nil)
        )
        let consoleStarter = SavedSessionRecordingConsoleStarter()
        let serialStarter = SavedSessionRecordingSerialStarter()
        let openRecorder = SavedSessionRecordingOpenRecorder()
        let workbench = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            serialSessionStarter: serialStarter,
            consoleSessionStarter: consoleStarter,
            savedSessionOpenRecorder: openRecorder,
            databasePathProvider: { tempURL.path }
        )

        XCTAssertThrowsError(try workbench.openSavedSession(savedSession)) { error in
            XCTAssertTrue(error.localizedDescription.contains("BLE_CONSOLE_CONFIG_INVALID"))
        }
        XCTAssertTrue(consoleStarter.openedConfigs.isEmpty)
        XCTAssertTrue(serialStarter.openedConfigs.isEmpty)
        XCTAssertTrue(openRecorder.openedSessionIDs.isEmpty)
    }

    func testConsoleSavedSessionRejectsUnknownSchemaVersion() throws {
        try assertSavedConsoleConfigRejected(
            #"{"kind":"console","schemaVersion":2,"transportPolicy":"prefer_ble","ble":{"deviceName":"NBEE_BLE_1103","profileID":"bterm-ffe1-split-v1","serviceUUID":"FFE1","txCharacteristicUUID":"FFE3","rxCharacteristicUUID":"FFE2","writeType":"without_response","platformBindings":{"macOSPeripheralUUID":"opaque-device-id","windowsDeviceID":null}},"sppFallback":null}"#
        )
    }

    func testConsoleSavedSessionRejectsInvalidStoredConfig() throws {
        try assertSavedConsoleConfigRejected(#"{"kind":"console","schemaVersion":1}"#)
    }

    func testConsoleSavedSessionRejectsMalformedJSON() throws {
        try assertSavedConsoleConfigRejected("{not-json")
    }

    func testPasswordSavedSessionResolvesKeychainSecretAndStartsEmbeddedLiveShell() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let credential = try KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        .saveCredential(
            kind: "password",
            label: "API password",
            account: "deploy@api.example.com",
            secret: "super-secret"
        )
        _ = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "api.example.com",
                port: 2222,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: credential.id,
                tags: ["prod"],
                configJson: nil
            )
        )
        let savedSession = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let harness = try makeWorkbenchHarness(
            databasePath: tempURL.path,
            keychainStore: keychainStore,
            privateKeys: [:],
            host: "api.example.com",
            port: 2222
        )

        let status = try harness.workbench.openSavedSession(savedSession)
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))

        XCTAssertTrue(status.runtimeId.hasPrefix("pending_"))
        XCTAssertEqual(harness.workspace.openedPanes.map(\.runtimeID), ["term_saved"])
        XCTAssertEqual(harness.liveShellStarter.startedConfigs.map(\.authMethod), [.password(credentialRef: credential.id)])
        XCTAssertEqual(harness.liveShellStarter.passwordSecrets, ["super-secret"])
        XCTAssertEqual(harness.workspace.openedTitles, ["API"])
        XCTAssertEqual(harness.connector.events, ["probe", "trust:reject"])
        XCTAssertNotNil(try CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first?.lastOpenedAt)
        XCTAssertFalse(String(describing: harness.contextStore).contains("super-secret"))
    }

    func testQuickConnectSavedPasswordSessionCanBeOpenedLaterThroughEmbeddedShell() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let quickStarter = RecordingQuickConnectSavedSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let credentialSaver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        let quickWorkbench = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: quickStarter,
            quickConnectPromptPresenter: RecordingQuickConnectSavedSessionPromptPresenter(
                request: QuickConnectRequest(
                    target: "deploy@api.example.com:2222",
                    authMode: .password,
                    temporarySecret: "super-secret",
                    saveAsSession: true,
                    sessionName: "API"
                )
            ),
            quickConnectCredentialSaver: credentialSaver,
            databasePathProvider: { tempURL.path }
        )

        quickWorkbench.loadWindow()
        _ = try quickWorkbench.quickConnectFromToolbar(nil)
        let savedSession = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let harness = try makeWorkbenchHarness(
            databasePath: tempURL.path,
            keychainStore: keychainStore,
            privateKeys: [:],
            host: "api.example.com",
            port: 2222
        )

        _ = try harness.workbench.openSavedSession(savedSession)
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))

        let credentialID = try XCTUnwrap(savedSession.credentialId)
        XCTAssertEqual(quickStarter.startedConfigs.map(\.authMethod), [.password(credentialRef: credentialID)])
        XCTAssertEqual(harness.liveShellStarter.startedConfigs.map(\.authMethod), [.password(credentialRef: credentialID)])
        XCTAssertEqual(harness.liveShellStarter.passwordSecrets, ["super-secret"])
        XCTAssertFalse(String(describing: savedSession).contains("super-secret"))
    }

    func testPrivateKeySavedSessionResolvesPassphraseAndStartsEmbeddedLiveShell() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let credential = try KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        .saveCredential(
            kind: "private_key_passphrase",
            label: "Key Host private key passphrase",
            account: "deploy@key.example.com",
            secret: "key-passphrase"
        )
        _ = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Key Host",
                protocol: "ssh",
                host: "key.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: "/keys/prod",
                credentialId: credential.id,
                tags: [],
                configJson: nil
            )
        )
        let savedSession = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let harness = try makeWorkbenchHarness(
            databasePath: tempURL.path,
            keychainStore: keychainStore,
            privateKeys: ["/keys/prod": "PRIVATE KEY"],
            host: "key.example.com",
            port: 22
        )

        _ = try harness.workbench.openSavedSession(savedSession)
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))

        XCTAssertEqual(
            harness.liveShellStarter.startedConfigs.map(\.authMethod),
            [.privateKey(keyPath: "/keys/prod", passphraseRef: credential.id)]
        )
        XCTAssertEqual(harness.liveShellStarter.privateKeySecrets.map(\.privateKeyPem), ["PRIVATE KEY"])
        XCTAssertEqual(harness.liveShellStarter.privateKeySecrets.map(\.passphrase), ["key-passphrase"])
        XCTAssertEqual(harness.workspace.openedTitles, ["Key Host"])
        XCTAssertFalse(String(describing: harness.contextStore).contains("key-passphrase"))
        XCTAssertFalse(String(describing: harness.contextStore).contains("PRIVATE KEY"))
    }

    func testSavedSessionOpensRealEmbeddedShellWithGatedSSHFixtureWhenConfigured() throws {
        guard let fixture = SavedSessionSSHFixture.fromEnvironment() else {
            throw XCTSkip("Set STACIO_SSH_FIXTURE_HOST, STACIO_SSH_FIXTURE_USERNAME, and password/private-key fixture env vars to run live SSH smoke test.")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let account = "\(fixture.username)@\(fixture.host)"
        let sessionDraft: SessionDraft
        switch fixture.auth {
        case let .password(password):
            let credential = try KeychainSessionSidebarCredentialSaver(
                databasePath: tempURL.path,
                keychainStore: keychainStore
            )
            .saveCredential(
                kind: "password",
                label: "Fixture password",
                account: account,
                secret: password
            )
            sessionDraft = SessionDraft(
                folderId: nil,
                name: "Fixture Password",
                protocol: "ssh",
                host: fixture.host,
                port: UInt32(fixture.port),
                username: fixture.username,
                privateKeyPath: nil,
                credentialId: credential.id,
                tags: ["fixture"],
                configJson: nil
            )
        case let .privateKey(_, passphrase):
            let credentialID: String?
            if let passphrase {
                let credential = try KeychainSessionSidebarCredentialSaver(
                    databasePath: tempURL.path,
                    keychainStore: keychainStore
                )
                .saveCredential(
                    kind: "private_key_passphrase",
                    label: "Fixture private key passphrase",
                    account: account,
                    secret: passphrase
                )
                credentialID = credential.id
            } else {
                credentialID = nil
            }
            sessionDraft = SessionDraft(
                folderId: nil,
                name: "Fixture Private Key",
                protocol: "ssh",
                host: fixture.host,
                port: UInt32(fixture.port),
                username: fixture.username,
                privateKeyPath: fixture.privateKeyPath,
                credentialId: credentialID,
                tags: ["fixture"],
                configJson: nil
            )
        }

        _ = try CoreBridge.createSessionRecord(databasePath: tempURL.path, draft: sessionDraft)
        let savedSession = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let contextStore = TunnelLiveSessionStore()
        let workspace = SavedSessionRecordingRemoteWorkspaceOpening()
        let sshCoordinator = SSHConnectionCoordinator(
            connector: CoreBridgeSSHLiveConnector(),
            credentialResolver: SSHCredentialResolver(store: keychainStore),
            hostKeyConfirmer: SavedSessionFixtureHostKeyConfirmer(),
            privateKeyLoader: SavedSessionInMemoryPrivateKeyLoader(keys: fixture.privateKeysByPath)
        )
        let remoteSessionStarter = RemoteSSHSessionCoordinator(
            contextBuilder: sshCoordinator,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { tempURL.path }
        )
        let workbench = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: remoteSessionStarter
        )

        _ = try workbench.openSavedSession(savedSession)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let runtimeID = try XCTUnwrap(workspace.openedPanes.first?.runtimeID)
        defer { _ = try? CoreBridge.closeLiveSSHShell(runtimeID: runtimeID) }
        let marker = "STACIO_SWIFT_SAVED_SESSION_OK"
        try CoreBridge.writeTerminalInput(
            runtimeID: runtimeID,
            bytes: Array("printf '\(marker)\\n'\nexit\n".utf8)
        )

        let output = try readLiveShellOutput(runtimeID: runtimeID, marker: marker)

        XCTAssertEqual(workspace.openedTitles, [savedSession.name])
        XCTAssertEqual(contextStore.current()?.config.host, fixture.host)
        XCTAssertTrue(output.contains(marker), "Fixture shell output did not contain marker: \(output)")
        XCTAssertFalse(String(describing: contextStore).contains(fixture.secretNeedle))
    }
}

@MainActor
private extension SavedSessionConnectionFlowTests {
    func assertSavedConsoleConfigRejected(
        _ invalidConfigJSON: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let tempURL = savedConsoleTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let savedSession = try createSavedConsoleSession(
            databasePath: tempURL.path,
            config: savedConsoleConfig(macOSPeripheralUUID: UUID().uuidString)
        )
        try overwriteSavedConsoleConfigJSON(
            invalidConfigJSON,
            sessionID: savedSession.id,
            databasePath: tempURL.path
        )
        let consoleStarter = SavedSessionRecordingConsoleStarter()
        let serialStarter = SavedSessionRecordingSerialStarter()
        let openRecorder = SavedSessionRecordingOpenRecorder()
        let workbench = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            serialSessionStarter: serialStarter,
            consoleSessionStarter: consoleStarter,
            savedSessionOpenRecorder: openRecorder,
            databasePathProvider: { tempURL.path }
        )

        XCTAssertThrowsError(try workbench.openSavedSession(savedSession), file: file, line: line) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("BLE_CONSOLE_CONFIG_INVALID"),
                "Unexpected error: \(error)",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(consoleStarter.openedConfigs.isEmpty, file: file, line: line)
        XCTAssertTrue(serialStarter.openedConfigs.isEmpty, file: file, line: line)
        XCTAssertTrue(openRecorder.openedSessionIDs.isEmpty, file: file, line: line)
    }
}

private func savedConsoleTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

private func createSavedConsoleSession(
    databasePath: String,
    config: ConsoleSessionConfig
) throws -> SessionRecord {
    try CoreBridge.createSessionRecord(
        databasePath: databasePath,
        draft: SessionDraft(
            folderId: nil,
            name: "Core Switch Console",
            protocol: "console",
            host: "NBEE_BLE_1103 (BLE)",
            port: 0,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["network"],
            configJson: try CoreBridge.serializeConsoleSessionConfig(config: config)
        )
    )
}

private func savedConsoleConfig(macOSPeripheralUUID: String?) -> ConsoleSessionConfig {
    ConsoleSessionConfig(
        kind: "console",
        schemaVersion: 1,
        transportPolicy: "prefer_ble",
        ble: ConsoleBleConfig(
            deviceName: "NBEE_BLE_1103",
            profileId: "bterm-ffe1-split-v1",
            serviceUuid: "FFE1",
            txCharacteristicUuid: "FFE3",
            rxCharacteristicUuid: "FFE2",
            writeType: "without_response",
            platformBindings: ConsolePlatformBindings(
                macOsPeripheralUuid: macOSPeripheralUUID,
                windowsDeviceId: nil
            )
        ),
        sppFallback: nil
    )
}

private func overwriteSavedConsoleConfigJSON(
    _ configJSON: String,
    sessionID: String,
    databasePath: String
) throws {
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var database: OpaquePointer?
    guard sqlite3_open(databasePath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "SavedSessionConnectionFlowTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "UPDATE sessions SET config_json = ?1 WHERE id = ?2",
        -1,
        &statement,
        nil
    ) == SQLITE_OK,
    let statement else {
        throw NSError(domain: "SavedSessionConnectionFlowTests.SQLite", code: 2)
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, configJSON, -1, sqliteTransient)
    sqlite3_bind_text(statement, 2, sessionID, -1, sqliteTransient)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "SavedSessionConnectionFlowTests.SQLite", code: 3)
    }
}

@MainActor
private final class SavedSessionRecordingConsoleStarter: ConsoleSessionStarting {
    private(set) var openedConfigs: [ConsoleSessionConfig] = []
    private(set) var openedTitles: [String] = []

    func openSessionTab(config: ConsoleSessionConfig, title: String) throws -> TerminalRuntime {
        openedConfigs.append(config)
        openedTitles.append(title)
        return TerminalRuntime(
            id: "term_console_saved",
            kind: "ble_console",
            shellPath: "",
            remoteHost: nil,
            remotePort: nil,
            username: nil,
            cols: 80,
            rows: 24,
            resizeRevision: 0,
            status: "running",
            outputPaused: false
        )
    }
}

@MainActor
private final class SavedSessionRecordingSerialStarter: SerialSessionStarting {
    private(set) var openedConfigs: [SerialConnectionConfig] = []

    func start(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus {
        openedConfigs.append(config)
        return LiveShellStatus(runtimeId: "term_serial_unexpected", status: "running", diagnostic: "running")
    }
}

private final class SavedSessionRecordingOpenRecorder: SavedSessionOpenRecording {
    private(set) var openedSessionIDs: [String] = []

    func markSessionRecordOpened(databasePath: String, id: String) throws -> SessionRecord {
        openedSessionIDs.append(id)
        return SessionRecord(
            id: id,
            folderId: nil,
            name: "",
            protocol: "console",
            host: "",
            port: 0,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: "now"
        )
    }
}

@MainActor
private struct SavedSessionWorkbenchHarness {
    let workbench: WorkbenchWindowController
    let connector: SavedSessionRecordingSSHLiveConnector
    let liveShellStarter: SavedSessionRecordingLiveShellStarter
    let contextStore: TunnelLiveSessionStore
    let workspace: SavedSessionRecordingRemoteWorkspaceOpening
}

@MainActor
private func makeWorkbenchHarness(
    databasePath: String,
    keychainStore: KeychainCredentialStore,
    privateKeys: [String: String],
    host: String,
    port: UInt16
) throws -> SavedSessionWorkbenchHarness {
    let connector = SavedSessionRecordingSSHLiveConnector(
        probeResult: savedSessionLiveHostKey(host: host, port: port),
        trustResults: [.trusted]
    )
    let contextStore = TunnelLiveSessionStore()
    let workspace = SavedSessionRecordingRemoteWorkspaceOpening()
    let liveShellStarter = SavedSessionRecordingLiveShellStarter()
    let sshCoordinator = SSHConnectionCoordinator(
        connector: connector,
        credentialResolver: SSHCredentialResolver(store: keychainStore),
        hostKeyConfirmer: SavedSessionRecordingHostKeyConfirming(),
        privateKeyLoader: SavedSessionInMemoryPrivateKeyLoader(keys: privateKeys)
    )
    let remoteSessionStarter = RemoteSSHSessionCoordinator(
        contextBuilder: sshCoordinator,
        liveShellStarter: liveShellStarter,
        contextStore: contextStore,
        workspace: workspace,
        databasePathProvider: { databasePath }
    )
    let workbench = WorkbenchWindowController(
        workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
        tunnelLiveSessionStore: contextStore,
        remoteSessionStarter: remoteSessionStarter,
        databasePathProvider: { databasePath }
    )
    return SavedSessionWorkbenchHarness(
        workbench: workbench,
        connector: connector,
        liveShellStarter: liveShellStarter,
        contextStore: contextStore,
        workspace: workspace
    )
}

private final class SavedSessionRecordingSSHLiveConnector: SSHLiveConnecting {
    var events: [String] = []
    private let probeResult: LiveSshHostKey
    private var trustResults: [HostKeyVerification]

    init(probeResult: LiveSshHostKey, trustResults: [HostKeyVerification]) {
        self.probeResult = probeResult
        self.trustResults = trustResults
    }

    func probeHostKey(config: SshConnectionConfig) throws -> LiveSshHostKey {
        events.append("probe")
        return probeResult
    }

    func applyHostKeyDecision(
        databasePath: String,
        host: String,
        port: UInt16,
        hostKey: [UInt8],
        decision: HostKeyTrustDecision
    ) throws -> HostKeyVerification {
        events.append("trust:\(decision.savedSessionEventName)")
        return trustResults.removeFirst()
    }

    func connect(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> SshConnectionStatus {
        XCTFail("RemoteSSHSessionCoordinator should start the embedded live shell runtime directly")
        return SshConnectionStatus(
            connected: false,
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: "unused",
            diagnostic: "unused"
        )
    }
}

private final class SavedSessionRecordingLiveShellStarter: LiveShellStarting {
    struct PrivateKeySecret {
        let privateKeyPem: String
        let passphrase: String?
    }

    var startedConfigs: [SshConnectionConfig] = []
    var passwordSecrets: [String] = []
    var privateKeySecrets: [PrivateKeySecret] = []

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        startedConfigs.append(config)
        switch secret {
        case let .password(value):
            passwordSecrets.append(value)
        case let .privateKey(privateKeyPem, passphrase):
            privateKeySecrets.append(PrivateKeySecret(privateKeyPem: privateKeyPem, passphrase: passphrase))
        case .agent:
            break
        }
        return LiveShellStatus(runtimeId: "term_saved", status: "running", diagnostic: "running")
    }
}

private final class SavedSessionRecordingRemoteWorkspaceOpening: RemoteWorkspaceOpening {
    var openedTitles: [String] = []
    var openedPanes: [RemoteTerminalPaneViewController] = []

    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteTerminalPaneViewController {
        openedTitles.append(title)
        let pane = RemoteTerminalPaneViewController(
            runtimeID: "pending_saved_session",
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            eventSink: SavedSessionNoopTerminalEventSink(),
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        pane.displayConnectionStarting()
        openedPanes.append(pane)
        return pane
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openedTitles.append(title)
    }
}

private final class SavedSessionNoopTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

private struct RecordingQuickConnectSavedSessionPromptPresenter: QuickConnectPromptPresenting {
    let request: QuickConnectRequest?

    @MainActor
    func promptQuickConnect(parentWindow: NSWindow?) -> QuickConnectRequest? {
        request
    }
}

private final class RecordingQuickConnectSavedSessionStarter: RemoteSSHSessionStarting {
    var startedConfigs: [SshConnectionConfig] = []
    var startedTitles: [String] = []
    private let status: LiveShellStatus

    init(status: LiveShellStatus) {
        self.status = status
    }

    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        startedConfigs.append(config)
        startedTitles.append(title)
        return status
    }
}

private final class SavedSessionRecordingHostKeyConfirming: HostKeyConfirming {
    func confirm(_ confirmation: HostKeyConfirmation) throws -> HostKeyTrustDecision {
        XCTFail("trusted host should not ask for confirmation")
        return .reject
    }
}

private final class SavedSessionFixtureHostKeyConfirmer: HostKeyConfirming {
    func confirm(_ confirmation: HostKeyConfirmation) throws -> HostKeyTrustDecision {
        .trustAndSave
    }
}

private struct SavedSessionInMemoryPrivateKeyLoader: PrivateKeyMaterialLoading {
    let keys: [String: String]

    func loadPrivateKey(at path: String) throws -> String {
        guard let value = keys[path] else {
            throw SSHConnectionCoordinatorError.missingPrivateKey(path: path)
        }
        return value
    }
}

private enum SavedSessionSSHFixtureAuth {
    case password(String)
    case privateKey(privateKeyPem: String, passphrase: String?)
}

private struct SavedSessionSSHFixture {
    static let privateKeyPath = "fixture-memory-key"

    let host: String
    let port: UInt16
    let username: String
    let auth: SavedSessionSSHFixtureAuth

    var privateKeyPath: String {
        Self.privateKeyPath
    }

    var privateKeysByPath: [String: String] {
        switch auth {
        case .password:
            return [:]
        case let .privateKey(privateKeyPem, _):
            return [privateKeyPath: privateKeyPem]
        }
    }

    var secretNeedle: String {
        switch auth {
        case let .password(password):
            return password
        case let .privateKey(privateKeyPem, passphrase):
            return passphrase ?? privateKeyPem
        }
    }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SavedSessionSSHFixture? {
        guard let host = environment["STACIO_SSH_FIXTURE_HOST"],
              let username = environment["STACIO_SSH_FIXTURE_USERNAME"]
        else {
            return nil
        }
        let port = environment["STACIO_SSH_FIXTURE_PORT"].flatMap(UInt16.init) ?? 22
        if let password = environment["STACIO_SSH_FIXTURE_PASSWORD"] {
            return SavedSessionSSHFixture(
                host: host,
                port: port,
                username: username,
                auth: .password(password)
            )
        }
        guard let privateKey = environment["STACIO_SSH_FIXTURE_PRIVATE_KEY"] else {
            return nil
        }
        return SavedSessionSSHFixture(
            host: host,
            port: port,
            username: username,
            auth: .privateKey(
                privateKeyPem: privateKey,
                passphrase: environment["STACIO_SSH_FIXTURE_PRIVATE_KEY_PASSPHRASE"]
            )
        )
    }
}

private func readLiveShellOutput(runtimeID: String, marker: String, timeout: TimeInterval = 5) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var output = Data()
    while Date() < deadline {
        let batch = try CoreBridge.takeTerminalOutputBatch(runtimeID: runtimeID)
        output.append(batch.bytes)
        let text = String(decoding: output, as: UTF8.self)
        if text.contains(marker) {
            return text
        }
        _ = try? CoreBridge.pollLiveSSHShell(runtimeID: runtimeID)
        Thread.sleep(forTimeInterval: 0.05)
    }
    return String(decoding: output, as: UTF8.self)
}

private extension HostKeyTrustDecision {
    var savedSessionEventName: String {
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

private func savedSessionLiveHostKey(host: String, port: UInt16) -> LiveSshHostKey {
    let bytes = Array("\(host):\(port)".utf8)
    return LiveSshHostKey(
        host: host,
        port: port,
        keyType: "ssh-ed25519",
        fingerprintSha256: CoreBridge.fingerprintHostKey(bytes),
        rawKey: Data(bytes),
        keyLen: UInt64(bytes.count)
    )
}
