import Foundation
import StacioCoreBindings

public extension RemoteFileEntry {
    init(kind: RemoteFileKind, path: String, size: UInt64, linkTarget: String?) {
        self.init(kind: kind, path: path, size: size, modifiedTime: nil, linkTarget: linkTarget)
    }

    init(kind: RemoteFileKind, path: String, size: UInt64, modifiedTime: String?, linkTarget: String?) {
        self.init(
            kind: kind,
            path: path,
            size: size,
            modifiedTime: modifiedTime,
            linkTarget: linkTarget,
            owner: nil,
            permissions: nil
        )
    }
}

/// 一次性远程命令执行结果（stdout/stderr 分离 + 退出码），Rust `RemoteCommandOutcome` 的 Swift 别名。
/// 供 `RemoteOhMyZshDeployer` 等远程执行场景使用；不因非零退出码抛错，由调用方检查 `exitCode`。
public typealias RemoteCommandResult = StacioCoreBindings.RemoteCommandOutcome

public enum CoreBridge {
    public static func health() throws -> CoreHealth {
        StacioCoreBindings.health()
    }

    public static func openLocalShellRuntime(shellPath: String, cols: UInt32, rows: UInt32) -> TerminalRuntime {
        StacioCoreBindings.openLocalShellRuntime(shellPath: shellPath, cols: cols, rows: rows)
    }

    public static func openExternalTerminalRuntime(
        kind: String,
        endpoint: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> TerminalRuntime {
        try StacioCoreBindings.openExternalTerminalRuntime(
            kind: kind,
            endpoint: endpoint,
            cols: cols,
            rows: rows
        )
    }

    public static func parseConsoleSessionConfig(json: String) throws -> ConsoleSessionConfig {
        try StacioCoreBindings.parseConsoleSessionConfig(json: json)
    }

    public static func serializeConsoleSessionConfig(config: ConsoleSessionConfig) throws -> String {
        try StacioCoreBindings.serializeConsoleSessionConfig(config: config)
    }

    public static func matchBLEConsoleProfile(
        services: [ConsoleServiceMetadata]
    ) -> ConsoleProfileMatch? {
        StacioCoreBindings.matchBleConsoleProfile(services: services)
    }

    public static func consoleTransportPolicy(
        platform: ConsolePlatform,
        windowsPort: String?
    ) -> ConsoleTransportDecision {
        StacioCoreBindings.consoleTransportPolicy(platform: platform, windowsPort: windowsPort)
    }

    public static func openRemoteSSHRuntime(
        host: String,
        port: UInt16,
        username: String,
        cols: UInt32,
        rows: UInt32
    ) -> TerminalRuntime {
        StacioCoreBindings.openRemoteSshRuntime(
            host: host,
            port: port,
            username: username,
            cols: cols,
            rows: rows
        )
    }

    public static func recordTerminalResize(runtimeID: String, cols: UInt32, rows: UInt32) throws -> TerminalRuntime {
        try StacioCoreBindings.recordTerminalResize(runtimeId: runtimeID, cols: cols, rows: rows)
    }

    public static func recordTerminalOutput(runtimeID: String, bytes: [UInt8]) throws {
        try StacioCoreBindings.recordTerminalOutput(runtimeId: runtimeID, bytes: Data(bytes))
    }

    public static func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {
        try StacioCoreBindings.writeTerminalInput(runtimeId: runtimeID, bytes: Data(bytes))
    }

    public static func takeTerminalInputBatch(runtimeID: String) throws -> TerminalInputBatch {
        try StacioCoreBindings.takeTerminalInputBatch(runtimeId: runtimeID)
    }

    public static func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        try StacioCoreBindings.takeTerminalOutputBatch(runtimeId: runtimeID)
    }

    public static func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        try StacioCoreBindings.setTerminalOutputPaused(runtimeId: runtimeID, paused: paused)
    }

    public static func closeTerminalRuntime(runtimeID: String) throws -> TerminalRuntime {
        try StacioCoreBindings.closeTerminalRuntime(runtimeId: runtimeID)
    }

    public static func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try StacioCoreBindings.pollLiveSshShell(runtimeId: runtimeID)
    }

    public static func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {
        try StacioCoreBindings.setLiveShellKeepaliveInterval(runtimeId: runtimeID, seconds: seconds)
    }

    public static func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try StacioCoreBindings.closeLiveSshShell(runtimeId: runtimeID)
    }

    public static func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try StacioCoreBindings.startLiveSshShellRuntime(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            cols: cols,
            rows: rows
        )
    }

    public static func startLiveSSHShellRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try StacioCoreBindings.startLiveSshShellRuntimeWithProxyJump(
            config: config,
            secret: secret,
            proxyJump: proxyJump,
            cols: cols,
            rows: rows
        )
    }

    public static func probeLiveSSHHostKeyViaProxyJump(
        config: SshConnectionConfig,
        proxyJump: SshProxyJumpRuntimeConfig
    ) throws -> LiveSshHostKey {
        try StacioCoreBindings.probeLiveSshHostKeyViaProxyJump(
            config: config,
            proxyJump: proxyJump
        )
    }

    public static func startLiveTelnetShellRuntime(
        config: TelnetConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try StacioCoreBindings.startLiveTelnetShellRuntime(
            config: config,
            cols: cols,
            rows: rows
        )
    }

    public static func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try StacioCoreBindings.startLiveSerialShellRuntime(
            config: config,
            cols: cols,
            rows: rows
        )
    }

    public static func parseQuickConnect(_ input: String) throws -> QuickConnectTarget {
        try StacioCoreBindings.parseQuickConnect(input: input)
    }

    public static func previewCSVImport(
        _ input: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        try StacioCoreBindings.previewCsvImport(
            input: input,
            existingSessionNames: existingSessionNames
        )
    }

    public static func previewLegacyIniImport(
        _ input: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        try StacioCoreBindings.previewLegacyIniImport(
            input: input,
            existingSessionNames: existingSessionNames
        )
    }

    public static func previewStacioJSONImport(
        _ input: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        try StacioCoreBindings.previewStacioJsonImport(
            input: input,
            existingSessionNames: existingSessionNames
        )
    }

    public static func createSessionFolder(
        databasePath: String,
        parentID: String?,
        name: String
    ) throws -> SessionFolder {
        try StacioCoreBindings.createSessionFolder(
            databasePath: databasePath,
            parentId: parentID,
            name: name
        )
    }

    public static func renameSessionFolder(
        databasePath: String,
        id: String,
        name: String
    ) throws -> SessionFolder {
        try StacioCoreBindings.renameSessionFolder(
            databasePath: databasePath,
            id: id,
            name: name
        )
    }

    public static func deleteSessionFolder(databasePath: String, id: String) throws {
        try StacioCoreBindings.deleteSessionFolder(databasePath: databasePath, id: id)
    }

    public static func listSessionFolders(databasePath: String) throws -> [SessionFolder] {
        try StacioCoreBindings.listSessionFolders(databasePath: databasePath)
    }

    public static func listSessionSidebarOrder(databasePath: String) throws -> [SessionSidebarOrderItem] {
        try StacioCoreBindings.listSessionSidebarOrder(databasePath: databasePath)
    }

    public static func loadSessionSidebarSnapshot(databasePath: String) throws -> SessionSidebarSnapshot {
        try StacioCoreBindings.loadSessionSidebarSnapshot(databasePath: databasePath)
    }

    public static func saveCredentialRecord(
        databasePath: String,
        draft: CredentialDraft
    ) throws -> CredentialRecord {
        try StacioCoreBindings.saveCredentialRecord(databasePath: databasePath, draft: draft)
    }

    public static func listCredentialRecords(databasePath: String) throws -> [CredentialRecord] {
        try StacioCoreBindings.listCredentialRecords(databasePath: databasePath)
    }

    public static func deleteCredentialRecord(databasePath: String, id: String) throws {
        try StacioCoreBindings.deleteCredentialRecord(databasePath: databasePath, id: id)
    }

    public static func createSessionRecord(
        databasePath: String,
        draft: SessionDraft
    ) throws -> SessionRecord {
        try StacioCoreBindings.createSessionRecord(databasePath: databasePath, draft: draft)
    }

    public static func updateSessionRecord(
        databasePath: String,
        id: String,
        update: SessionUpdate
    ) throws -> SessionRecord {
        try StacioCoreBindings.updateSessionRecord(
            databasePath: databasePath,
            id: id,
            update: update
        )
    }

    public static func duplicateSessionRecord(
        databasePath: String,
        id: String,
        targetFolderID: String?
    ) throws -> SessionRecord {
        try StacioCoreBindings.duplicateSessionRecord(
            databasePath: databasePath,
            id: id,
            targetFolderId: targetFolderID
        )
    }

    public static func moveSessionRecord(
        databasePath: String,
        id: String,
        targetFolderID: String?
    ) throws -> SessionRecord {
        try StacioCoreBindings.moveSessionRecord(
            databasePath: databasePath,
            id: id,
            targetFolderId: targetFolderID
        )
    }

    public static func placeSessionSidebarItem(
        databasePath: String,
        kind: String,
        id: String,
        targetFolderID: String?,
        targetIndex: UInt32
    ) throws {
        _ = try StacioCoreBindings.placeSessionSidebarItem(
            databasePath: databasePath,
            kind: kind,
            id: id,
            targetParentId: targetFolderID,
            targetIndex: targetIndex
        )
    }

    public static func exportSessionsJSON(databasePath: String) throws -> String {
        try StacioCoreBindings.exportSessionsJson(databasePath: databasePath)
    }

    public static func exportSessionFolderJSON(databasePath: String, folderID: String) throws -> String {
        try StacioCoreBindings.exportSessionFolderJson(databasePath: databasePath, folderId: folderID)
    }

    public static func deleteSessionRecord(databasePath: String, id: String) throws {
        try StacioCoreBindings.deleteSessionRecord(databasePath: databasePath, id: id)
    }

    public static func listSessionRecords(
        databasePath: String,
        folderID: String?
    ) throws -> [SessionRecord] {
        try StacioCoreBindings.listSessionRecords(databasePath: databasePath, folderId: folderID)
    }

    public static func listAllSessionRecords(databasePath: String) throws -> [SessionRecord] {
        try StacioCoreBindings.listAllSessionRecords(databasePath: databasePath)
    }

    public static func getSessionConfigJSON(databasePath: String, id: String) throws -> String? {
        try StacioCoreBindings.getSessionConfigJson(databasePath: databasePath, id: id)
    }

    public static func markSessionRecordOpened(
        databasePath: String,
        id: String
    ) throws -> SessionRecord {
        try StacioCoreBindings.markSessionRecordOpened(databasePath: databasePath, id: id)
    }

    public static func applySessionImport(
        databasePath: String,
        sourceType: String,
        sourceName: String,
        preview: ImportPreview
    ) throws -> ImportApplyResult {
        try StacioCoreBindings.applySessionImport(
            databasePath: databasePath,
            sourceType: sourceType,
            sourceName: sourceName,
            preview: preview
        )
    }

    public static func listImportReports(databasePath: String) throws -> [ImportReport] {
        try StacioCoreBindings.listImportReports(databasePath: databasePath)
    }

    public static func validateSSHConfig(_ config: SshConnectionConfig) throws {
        try StacioCoreBindings.validateSshConfig(config: config)
    }

    public static func diagnoseSSHConfig(_ config: SshConnectionConfig) throws -> SshConnectionStatus {
        try StacioCoreBindings.diagnoseSshConfig(config: config)
    }

    public static func fingerprintHostKey(_ hostKey: [UInt8]) -> String {
        StacioCoreBindings.fingerprintHostKey(hostKey: Data(hostKey))
    }

    public static func verifyKnownHost(
        host: String,
        port: UInt16,
        hostKey: [UInt8],
        knownHosts: [HostKeyRecord]
    ) throws -> HostKeyVerification {
        try StacioCoreBindings.verifyKnownHost(
            host: host,
            port: port,
            hostKey: Data(hostKey),
            knownHosts: knownHosts
        )
    }

    public static func hostKeyTrustDecisionLabel(_ decision: HostKeyTrustDecision) -> String {
        StacioCoreBindings.hostKeyTrustDecisionLabel(decision: decision)
    }

    public static func applyHostKeyDecisionInDatabase(
        databasePath: String,
        host: String,
        port: UInt16,
        hostKey: [UInt8],
        decision: HostKeyTrustDecision
    ) throws -> HostKeyVerification {
        try StacioCoreBindings.applyHostKeyDecisionInDatabase(
            databasePath: databasePath,
            host: host,
            port: port,
            hostKey: Data(hostKey),
            decision: decision
        )
    }

    public static func probeLiveSSHHostKey(config: SshConnectionConfig) throws -> LiveSshHostKey {
        try StacioCoreBindings.probeLiveSshHostKey(config: config)
    }

    public static func connectLiveSSH(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> SshConnectionStatus {
        try StacioCoreBindings.connectLiveSsh(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256
        )
    }

    public static func probeLiveDeviceMetrics(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> DeviceMetricsSnapshot {
        try StacioCoreBindings.probeLiveDeviceMetrics(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256
        )
    }

    public static func probeLiveRemoteOperatingSystem(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> RemoteOperatingSystemInfo {
        try StacioCoreBindings.probeLiveRemoteOperatingSystem(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256
        )
    }

    public static func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        try StacioCoreBindings.parseRemoteListing(input: input)
    }

    public static func validateFTPConfig(_ config: FtpConnectionConfig) throws {
        try StacioCoreBindings.validateFtpConfig(config: config)
    }

    public static func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        try StacioCoreBindings.listLiveRemoteDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public static func listLiveSFTPDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        try StacioCoreBindings.listLiveSftpDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public static func searchLiveRemoteFiles(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        keyword: String,
        depth: UInt32
    ) throws -> [RemoteFileEntry] {
        try StacioCoreBindings.searchLiveRemoteFiles(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            keyword: keyword,
            depth: depth
        )
    }

    public static func searchLiveSFTPFiles(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        keyword: String,
        depth: UInt32
    ) throws -> [RemoteFileEntry] {
        try StacioCoreBindings.searchLiveSftpFiles(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            keyword: keyword,
            depth: depth
        )
    }

    public static func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        try StacioCoreBindings.listLiveFtpDirectory(
            config: config,
            secret: secret,
            remotePath: remotePath
        )
    }

    public static func createLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws {
        try StacioCoreBindings.createLiveFtpDirectory(
            config: config,
            secret: secret,
            remotePath: remotePath
        )
    }

    public static func renameLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        try StacioCoreBindings.renameLiveFtpPath(
            config: config,
            secret: secret,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public static func deleteLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String,
        recursive: Bool
    ) throws {
        try StacioCoreBindings.deleteLiveFtpPath(
            config: config,
            secret: secret,
            remotePath: remotePath,
            recursive: recursive
        )
    }

    public static func copyLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        try StacioCoreBindings.copyLiveFtpPath(
            config: config,
            secret: secret,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public static func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {
        try StacioCoreBindings.createLiveRemoteDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public static func createLiveRemoteFileExclusive(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {
        try StacioCoreBindings.createLiveRemoteFileExclusive(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public static func createLiveSFTPDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {
        try StacioCoreBindings.createLiveSftpDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public static func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try StacioCoreBindings.renameLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public static func renameLiveSFTPPath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try StacioCoreBindings.renameLiveSftpPath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public static func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        try StacioCoreBindings.deleteLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            recursive: recursive
        )
    }

    // MARK: - V2 会话库（P3-6）

    public static func conversationV2Open(path: String) throws -> UInt64 {
        try StacioCoreBindings.conversationV2Open(path: path)
    }

    public static func conversationV2Close(handle: UInt64) {
        StacioCoreBindings.conversationV2Close(handle: handle)
    }

    public static func conversationV2Commit(handle: UInt64, request: StacioCoreBindings.CommitRequest) throws -> StacioCoreBindings.CommitOutcome {
        try StacioCoreBindings.conversationV2Commit(handle: handle, request: request)
    }

    public static func conversationV2LastApplied(handle: UInt64, conversationId: String) throws -> Int64 {
        try StacioCoreBindings.conversationV2LastApplied(handle: handle, conversationId: conversationId)
    }

    /// P0-5：按 sequence 升序加载会话全部事件（重启恢复/replay）。
    public static func conversationV2LoadEvents(handle: UInt64, conversationId: String) throws -> [StacioCoreBindings.LoadedEventRecord] {
        try StacioCoreBindings.conversationV2LoadEvents(handle: handle, conversationId: conversationId)
    }

    public static func conversationV2ListSessions(
        handle: UInt64
    ) throws -> [StacioCoreBindings.LoadedConversationSessionRecord] {
        try StacioCoreBindings.conversationV2ListSessions(handle: handle)
    }

    public static func conversationV2LoadUnsettledOutbox(
        handle: UInt64,
        conversationId: String
    ) throws -> [StacioCoreBindings.LoadedOutboxRecord] {
        try StacioCoreBindings.conversationV2LoadUnsettledOutbox(
            handle: handle,
            conversationId: conversationId
        )
    }

    public static func conversationV2ClaimOutboxEffect(
        handle: UInt64,
        conversationId: String,
        effectId: String,
        dispatchToken: String,
        dispatchedAt: String
    ) throws -> StacioCoreBindings.LoadedOutboxRecord? {
        try StacioCoreBindings.conversationV2ClaimOutboxEffect(
            handle: handle,
            conversationId: conversationId,
            effectId: effectId,
            dispatchToken: dispatchToken,
            dispatchedAt: dispatchedAt
        )
    }

    public static func conversationV2SettleOutbox(
        handle: UInt64,
        conversationId: String,
        itemId: String,
        dispatchToken: String,
        outcome: String,
        settledAt: String
    ) throws -> Bool {
        try StacioCoreBindings.conversationV2SettleOutbox(
            handle: handle,
            conversationId: conversationId,
            itemId: itemId,
            dispatchToken: dispatchToken,
            outcome: outcome,
            settledAt: settledAt
        )
    }

    public static func conversationV2RequireOutboxReconciliation(
        handle: UInt64,
        conversationId: String,
        itemId: String,
        reason: String
    ) throws -> Bool {
        try StacioCoreBindings.conversationV2RequireOutboxReconciliation(
            handle: handle,
            conversationId: conversationId,
            itemId: itemId,
            reason: reason
        )
    }

    public static func conversationV2AdmissionBeginGeneration(handle: UInt64) throws -> Int64 {
        try StacioCoreBindings.conversationV2AdmissionBeginGeneration(handle: handle)
    }

    public static func conversationV2AdmissionLoadState(
        handle: UInt64
    ) throws -> StacioCoreBindings.AdmissionStateRecord {
        try StacioCoreBindings.conversationV2AdmissionLoadState(handle: handle)
    }

    public static func conversationV2AdmissionEnqueue(
        handle: UInt64,
        requestId: String,
        conversationId: String,
        turnId: String,
        attemptId: String,
        schedulerGeneration: Int64,
        nowSeconds: Double
    ) throws -> StacioCoreBindings.AdmissionRequestRecord {
        try StacioCoreBindings.conversationV2AdmissionEnqueue(
            handle: handle,
            requestId: requestId,
            conversationId: conversationId,
            turnId: turnId,
            attemptId: attemptId,
            schedulerGeneration: schedulerGeneration,
            nowSeconds: nowSeconds
        )
    }

    public static func conversationV2AdmissionGrant(
        handle: UInt64,
        requestId: String,
        attemptId: String,
        schedulerGeneration: Int64,
        nowSeconds: Double
    ) throws -> StacioCoreBindings.AdmissionLeaseRecord {
        try StacioCoreBindings.conversationV2AdmissionGrant(
            handle: handle,
            requestId: requestId,
            attemptId: attemptId,
            schedulerGeneration: schedulerGeneration,
            nowSeconds: nowSeconds
        )
    }

    public static func conversationV2AdmissionActivate(
        handle: UInt64,
        leaseId: String,
        schedulerGeneration: Int64
    ) throws {
        try StacioCoreBindings.conversationV2AdmissionActivate(
            handle: handle,
            leaseId: leaseId,
            schedulerGeneration: schedulerGeneration
        )
    }

    public static func conversationV2AdmissionCancelRequest(
        handle: UInt64,
        requestId: String,
        schedulerGeneration: Int64
    ) throws -> Bool {
        try StacioCoreBindings.conversationV2AdmissionCancelRequest(
            handle: handle,
            requestId: requestId,
            schedulerGeneration: schedulerGeneration
        )
    }

    public static func conversationV2AdmissionExpireRequest(
        handle: UInt64,
        requestId: String,
        schedulerGeneration: Int64
    ) throws -> Bool {
        try StacioCoreBindings.conversationV2AdmissionExpireRequest(
            handle: handle,
            requestId: requestId,
            schedulerGeneration: schedulerGeneration
        )
    }

    public static func conversationV2AdmissionRelease(
        handle: UInt64,
        leaseId: String,
        schedulerGeneration: Int64,
        nowSeconds: Double
    ) throws -> Bool {
        try StacioCoreBindings.conversationV2AdmissionRelease(
            handle: handle,
            leaseId: leaseId,
            schedulerGeneration: schedulerGeneration,
            nowSeconds: nowSeconds
        )
    }

    // MARK: - V2 控制面（P3-9）

    public static func controlOpen(path: String) throws -> UInt64 {
        try StacioCoreBindings.controlOpen(path: path)
    }

    public static func controlClose(handle: UInt64) {
        StacioCoreBindings.controlClose(handle: handle)
    }

    public static func controlState(handle: UInt64) throws -> String {
        try StacioCoreBindings.controlState(handle: handle)
    }

    public static func controlTransition(handle: UInt64, to: String, expectedGeneration: Int64, transitionId: String) throws {
        try StacioCoreBindings.controlTransition(
            handle: handle, to: to, expectedGeneration: expectedGeneration, transitionId: transitionId
        )
    }

    public static func controlAuthorizationAllowed(handle: UInt64) throws -> Bool {
        try StacioCoreBindings.controlAuthorizationAllowed(handle: handle)
    }

    public static func controlCreatePermit(handle: UInt64, permitId: String, generation: Int64, participants: [String]) throws {
        try StacioCoreBindings.controlCreatePermit(
            handle: handle, permitId: permitId, generation: generation, participants: participants
        )
    }

    public static func controlPermitState(handle: UInt64, permitId: String) throws -> String {
        try StacioCoreBindings.controlPermitState(handle: handle, permitId: permitId)
    }

    public static func controlPreparePermit(handle: UInt64, permitId: String) throws {
        try StacioCoreBindings.controlPreparePermit(handle: handle, permitId: permitId)
    }

    public static func controlAuthorizePermitCommit(handle: UInt64, permitId: String) throws {
        try StacioCoreBindings.controlAuthorizePermitCommit(handle: handle, permitId: permitId)
    }

    public static func controlSettlePermit(handle: UInt64, permitId: String, settlement: String, proof: String) throws {
        try StacioCoreBindings.controlSettlePermit(
            handle: handle, permitId: permitId, settlement: settlement, proof: proof
        )
    }

    public static func controlExpirePermit(handle: UInt64, permitId: String, withTargetProof: Bool) throws {
        try StacioCoreBindings.controlExpirePermit(handle: handle, permitId: permitId, withTargetProof: withTargetProof)
    }

    public static func controlJournalParticipants(handle: UInt64, permitId: String) throws -> [String] {
        try StacioCoreBindings.controlJournalParticipants(handle: handle, permitId: permitId)
    }

    public static func controlMarkJournal(handle: UInt64, permitId: String, participant: String, state: String) throws {
        try StacioCoreBindings.controlMarkJournal(handle: handle, permitId: permitId, participant: participant, state: state)
    }

    // MARK: - External Effect reconciliation（P3-9）

    public static func reconciliationOpen(path: String) throws -> UInt64 {
        try StacioCoreBindings.reconciliationOpen(path: path)
    }

    public static func reconciliationClose(handle: UInt64) {
        StacioCoreBindings.reconciliationClose(handle: handle)
    }

    public static func reconciliationConflictKey(targetDigest: String, resourceScope: String, operationClass: String) -> String {
        StacioCoreBindings.reconciliationConflictKey(
            targetDigest: targetDigest, resourceScope: resourceScope, operationClass: operationClass
        )
    }

    public static func reconciliationCreateRecord(handle: UInt64, effectId: String, conflictKey: String, state: String) throws {
        try StacioCoreBindings.reconciliationCreateRecord(handle: handle, effectId: effectId, conflictKey: conflictKey, state: state)
    }

    public static func reconciliationCreateRecordWithStrength(
        handle: UInt64, effectId: String, conflictKey: String, state: String, evidenceStrength: String
    ) throws {
        try StacioCoreBindings.reconciliationCreateRecordWithStrength(
            handle: handle, effectId: effectId, conflictKey: conflictKey, state: state, evidenceStrength: evidenceStrength
        )
    }

    public static func reconciliationLockReleased(handle: UInt64, conflictKey: String) throws -> Bool {
        try StacioCoreBindings.reconciliationLockReleased(handle: handle, conflictKey: conflictKey)
    }

    public static func reconciliationLockOwner(handle: UInt64, conflictKey: String) throws -> String {
        try StacioCoreBindings.reconciliationLockOwner(handle: handle, conflictKey: conflictKey)
    }

    public static func reconciliationHoldsGlobalAdmission(handle: UInt64, conflictKey: String) throws -> Bool {
        try StacioCoreBindings.reconciliationHoldsGlobalAdmission(handle: handle, conflictKey: conflictKey)
    }

    public static func reconciliationEvidenceStrength(handle: UInt64, effectId: String) throws -> String {
        try StacioCoreBindings.reconciliationEvidenceStrength(handle: handle, effectId: effectId)
    }

    public static func reconciliationSettleRecord(handle: UInt64, effectId: String, settlement: String) throws {
        try StacioCoreBindings.reconciliationSettleRecord(handle: handle, effectId: effectId, settlement: settlement)
    }

    // MARK: - AssistantSettingsStore（P3-11，独立设置域存储）

    public static func settingsOpen(path: String) throws -> UInt64 {
        try StacioCoreBindings.settingsOpen(path: path)
    }

    public static func settingsClose(handle: UInt64) {
        StacioCoreBindings.settingsClose(handle: handle)
    }

    public static func settingsUpsert(
        handle: UInt64, key: String, expectedRevision: Int64?, valueDigest: String,
        scope: String, migrationKey: String
    ) throws {
        try StacioCoreBindings.settingsUpsert(
            handle: handle, key: key, expectedRevision: expectedRevision, valueDigest: valueDigest,
            scope: scope, migrationKey: migrationKey
        )
    }

    public static func settingsValue(handle: UInt64, key: String) throws -> StacioCoreBindings.SettingValueSnapshot? {
        try StacioCoreBindings.settingsValue(handle: handle, key: key)
    }

    public static func settingsMetadata(handle: UInt64, key: String) throws -> StacioCoreBindings.SettingMetadataSnapshot? {
        try StacioCoreBindings.settingsMetadata(handle: handle, key: key)
    }

    public static func settingsKeys(handle: UInt64) throws -> [String] {
        try StacioCoreBindings.settingsKeys(handle: handle)
    }

    public static func settingsAppendEvent(handle: UInt64, eventId: String, operationId: String, kind: String) throws -> Int64 {
        try StacioCoreBindings.settingsAppendEvent(handle: handle, eventId: eventId, operationId: operationId, kind: kind)
    }

    public static func settingsNextSequence(handle: UInt64) throws -> Int64 {
        try StacioCoreBindings.settingsNextSequence(handle: handle)
    }

    public static func settingsEvents(handle: UInt64, operationId: String) throws -> [String] {
        try StacioCoreBindings.settingsEvents(handle: handle, operationId: operationId)
    }

    // MARK: - Configuration Store（P3-12，独立 Configuration Store）

    public static func configurationOpen(path: String) throws -> UInt64 {
        try StacioCoreBindings.configurationOpen(path: path)
    }

    public static func configurationClose(handle: UInt64) {
        StacioCoreBindings.configurationClose(handle: handle)
    }

    public static func configurationUpsert(
        handle: UInt64, configurationId: String, expectedRevision: Int64?,
        valueDigest: String, credentialReference: String
    ) throws {
        try StacioCoreBindings.configurationUpsert(
            handle: handle, configurationId: configurationId, expectedRevision: expectedRevision,
            valueDigest: valueDigest, credentialReference: credentialReference
        )
    }

    public static func configurationCommitVerified(
        handle: UInt64, configurationId: String, expectedRevision: Int64?,
        valueDigest: String, credentialReference: String, operationId: String, eventId: String
    ) throws -> Int64 {
        try StacioCoreBindings.configurationCommitVerified(
            handle: handle, configurationId: configurationId, expectedRevision: expectedRevision,
            valueDigest: valueDigest, credentialReference: credentialReference,
            operationId: operationId, eventId: eventId
        )
    }

    public static func configurationDelete(
        handle: UInt64, configurationId: String, expectedRevision: Int64,
        tombstoneDigest: String, operationId: String, eventId: String
    ) throws -> Int64 {
        try StacioCoreBindings.configurationDelete(
            handle: handle, configurationId: configurationId, expectedRevision: expectedRevision,
            tombstoneDigest: tombstoneDigest, operationId: operationId, eventId: eventId
        )
    }

    public static func configurationSnapshot(
        handle: UInt64, configurationId: String
    ) throws -> StacioCoreBindings.ConfigurationSnapshotRecord? {
        try StacioCoreBindings.configurationSnapshot(handle: handle, configurationId: configurationId)
    }

    public static func configurationTransitionState(handle: UInt64, configurationId: String, to: String) throws {
        try StacioCoreBindings.configurationTransitionState(handle: handle, configurationId: configurationId, to: to)
    }

    public static func configurationAppendEvent(
        handle: UInt64, eventId: String, configurationId: String, operationId: String, kind: String
    ) throws -> Int64 {
        try StacioCoreBindings.configurationAppendEvent(
            handle: handle, eventId: eventId, configurationId: configurationId,
            operationId: operationId, kind: kind
        )
    }

    public static func configurationEvents(handle: UInt64, configurationId: String) throws -> [String] {
        try StacioCoreBindings.configurationEvents(handle: handle, configurationId: configurationId)
    }

    public static func configurationEventsByOperation(handle: UInt64, operationId: String) throws -> [String] {
        try StacioCoreBindings.configurationEventsByOperation(handle: handle, operationId: operationId)
    }

    /// 执行一次性远程命令，返回 stdout/stderr 分离结果与退出码（不因非零退出码抛错）。
    public static func runLiveRemoteCommand(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        command: String,
        standardInput: String? = nil
    ) throws -> RemoteCommandResult {
        if let standardInput {
            return try StacioCoreBindings.runLiveRemoteCommandWithInput(
                config: config, secret: secret,
                expectedFingerprintSha256: expectedFingerprintSHA256,
                command: command, input: standardInput
            )
        }
        return try StacioCoreBindings.runLiveRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            command: command
        )
    }

    public static func deleteLiveSFTPPath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        try StacioCoreBindings.deleteLiveSftpPath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            recursive: recursive
        )
    }

    public static func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {
        try StacioCoreBindings.chmodLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            mode: mode
        )
    }

    public static func chmodLiveSFTPPath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {
        try StacioCoreBindings.chmodLiveSftpPath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            mode: mode
        )
    }

    public static func copyLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try StacioCoreBindings.copyLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public static func copyLiveSFTPPath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try StacioCoreBindings.copyLiveSftpPath(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public static func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        try StacioCoreBindings.readLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            offset: offset,
            length: length
        )
    }

    public static func readLiveSFTPFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        try StacioCoreBindings.readLiveSftpFile(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            offset: offset,
            length: length
        )
    }

    public static func openLiveRemoteFileReadSession(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> String {
        try StacioCoreBindings.openLiveRemoteFileReadSession(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256
        )
    }

    public static func openLiveSFTPFileReadSession(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> String {
        try StacioCoreBindings.openLiveSftpFileReadSession(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256
        )
    }

    public static func readLiveRemoteFileSession(
        sessionID: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        try StacioCoreBindings.readLiveRemoteFileSession(
            sessionId: sessionID,
            remotePath: remotePath,
            offset: offset,
            length: length
        )
    }

    public static func closeLiveRemoteFileReadSession(sessionID: String) throws {
        try StacioCoreBindings.closeLiveRemoteFileReadSession(sessionId: sessionID)
    }

    public static func writeLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        try StacioCoreBindings.writeLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            contents: contents
        )
    }

    public static func writeLiveSFTPFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        try StacioCoreBindings.writeLiveSftpFile(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            remotePath: remotePath,
            contents: contents
        )
    }

    public static func resolveSCPConflictPath(
        destinationPath: String,
        policy: ScpConflictPolicy
    ) -> String? {
        StacioCoreBindings.resolveScpConflictPath(
            destinationPath: destinationPath,
            policy: policy
        )
    }

    public static func simulateSCPTransfer(_ job: ScpTransferJob) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.simulateScpTransfer(job: job)
    }

    public static func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.runLiveScpTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            job: job
        )
    }

    public static func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.runLiveSftpTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            job: job
        )
    }

    public static func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.runLiveSftpTransferWithResume(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions
        )
    }

    public static func runLiveRemoteToRemoteTransfer(
        sourceConfig: SshConnectionConfig,
        sourceSecret: SshAuthSecret,
        sourceExpectedFingerprintSHA256: String,
        destinationConfig: SshConnectionConfig,
        destinationSecret: SshAuthSecret,
        destinationExpectedFingerprintSHA256: String,
        request: RemoteToRemoteTransferRequest
    ) throws -> RemoteToRemoteTransferReport {
        try StacioCoreBindings.runLiveRemoteToRemoteTransfer(
            sourceConfig: sourceConfig,
            sourceSecret: sourceSecret,
            sourceExpectedFingerprintSha256: sourceExpectedFingerprintSHA256,
            destinationConfig: destinationConfig,
            destinationSecret: destinationSecret,
            destinationExpectedFingerprintSha256: destinationExpectedFingerprintSHA256,
            request: request
        )
    }

    public static func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.runLiveScpTransferWithResume(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions
        )
    }

    public static func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.runLiveFtpTransfer(
            config: config,
            secret: secret,
            job: job
        )
    }

    public static func cancelLiveSCPTransfer(jobID: String) throws -> Bool {
        try StacioCoreBindings.cancelLiveScpTransfer(jobId: jobID)
    }

    public static func cancelLiveFTPTransfer(jobID: String) throws -> Bool {
        try StacioCoreBindings.cancelLiveFtpTransfer(jobId: jobID)
    }

    public static func takeLiveSCPTransferProgressBatch(jobID: String) throws -> [ScpTransferProgress] {
        try StacioCoreBindings.takeLiveScpTransferProgressBatch(jobId: jobID)
    }

    public static func recordSCPTransferJob(
        databasePath: String,
        sessionID: String?,
        job: ScpTransferJob,
        status: String,
        bytesDone: UInt64
    ) throws {
        try StacioCoreBindings.recordScpTransferJob(
            databasePath: databasePath,
            sessionId: sessionID,
            job: job,
            status: status,
            bytesDone: bytesDone
        )
    }

    public static func appendSCPTransferProgress(
        databasePath: String,
        progress: ScpTransferProgress
    ) throws -> ScpTransferEventRecord {
        try StacioCoreBindings.appendScpTransferProgress(
            databasePath: databasePath,
            progress: progress
        )
    }

    public static func appendSCPTransferProgress(
        databasePath: String,
        progress: ScpTransferProgress,
        message: String
    ) throws -> ScpTransferEventRecord {
        try StacioCoreBindings.appendScpTransferProgressWithMessage(
            databasePath: databasePath,
            progress: progress,
            message: message
        )
    }

    public static func listSCPTransferJobs(
        databasePath: String
    ) throws -> [ScpTransferJobRecord] {
        try StacioCoreBindings.listScpTransferJobs(databasePath: databasePath)
    }

    public static func listSCPTransferEvents(
        databasePath: String,
        jobID: String
    ) throws -> [ScpTransferEventRecord] {
        try StacioCoreBindings.listScpTransferEvents(
            databasePath: databasePath,
            jobId: jobID
        )
    }

    public static func clearFinishedSCPTransferJobs(databasePath: String) throws -> UInt32 {
        try StacioCoreBindings.clearFinishedScpTransferJobs(databasePath: databasePath)
    }

    public static func deleteFinishedSCPTransferJob(
        databasePath: String,
        jobID: String
    ) throws -> Bool {
        try StacioCoreBindings.deleteFinishedScpTransferJob(
            databasePath: databasePath,
            jobId: jobID
        )
    }

    public static func validateTunnelProfile(_ profile: TunnelProfile) throws {
        try StacioCoreBindings.validateTunnelProfile(profile: profile)
    }

    public static func checkTunnelLocalPortAvailable(_ profile: TunnelProfile) throws {
        try StacioCoreBindings.checkTunnelLocalPortAvailable(profile: profile)
    }

    public static func saveTunnelProfile(
        databasePath: String,
        sessionID: String?,
        profile: TunnelProfile
    ) throws {
        try StacioCoreBindings.saveTunnelProfile(
            databasePath: databasePath,
            sessionId: sessionID,
            profile: profile
        )
    }

    public static func saveTunnelProfileRecord(
        databasePath: String,
        record: TunnelProfileRecord
    ) throws {
        try StacioCoreBindings.saveTunnelProfileRecord(
            databasePath: databasePath,
            record: record
        )
    }

    public static func listTunnelProfiles(
        databasePath: String,
        sessionID: String?
    ) throws -> [TunnelProfile] {
        try StacioCoreBindings.listTunnelProfiles(
            databasePath: databasePath,
            sessionId: sessionID
        )
    }

    public static func listTunnelProfileRecords(
        databasePath: String,
        sessionID: String?
    ) throws -> [TunnelProfileRecord] {
        try StacioCoreBindings.listTunnelProfileRecords(
            databasePath: databasePath,
            sessionId: sessionID
        )
    }

    public static func deleteTunnelProfile(
        databasePath: String,
        profileID: String
    ) throws {
        try StacioCoreBindings.deleteTunnelProfile(
            databasePath: databasePath,
            profileId: profileID
        )
    }

    public static func startMockTunnel(
        profile: TunnelProfile,
        outcome: MockTunnelOutcome
    ) throws -> TunnelRuntimeStatus {
        try StacioCoreBindings.startMockTunnel(profile: profile, outcome: outcome)
    }

    public static func startLiveLocalTunnelRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        try StacioCoreBindings.startLiveLocalTunnelRuntime(
            config: config,
            secret: secret,
            expectedFingerprintSha256: expectedFingerprintSHA256,
            profile: profile
        )
    }

    public static func startLiveLocalTunnelRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        try StacioCoreBindings.startLiveLocalTunnelRuntimeWithProxyJump(
            config: config,
            secret: secret,
            proxyJump: proxyJump,
            profile: profile
        )
    }

    public static func pollLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus {
        try StacioCoreBindings.pollLiveTunnelRuntime(profileId: profileID)
    }

    public static func closeLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus {
        try StacioCoreBindings.closeLiveTunnelRuntime(profileId: profileID)
    }

    public static func stopTunnelRuntime(state: TunnelState) throws -> TunnelState {
        try StacioCoreBindings.stopTunnelRuntime(state: state)
    }

    public static func buildDiagnosticBundle(
        sessionID: String,
        tunnelID: String?,
        entries: [DiagnosticEntry]
    ) -> DiagnosticBundle {
        StacioCoreBindings.buildDiagnosticBundle(
            sessionId: sessionID,
            tunnelId: tunnelID,
            entries: entries
        )
    }

    public static func prepareBroadcastInput(
        targets: [MultiExecTarget],
        input: String,
        productionConfirmed: Bool
    ) throws -> BroadcastAuditEvent {
        try StacioCoreBindings.prepareBroadcastInput(
            targets: targets,
            input: input,
            productionConfirmed: productionConfirmed
        )
    }

    public static func markBroadcastExecuted(
        _ event: BroadcastAuditEvent,
        sentCount: UInt32
    ) -> BroadcastAuditEvent {
        StacioCoreBindings.markBroadcastExecuted(event: event, sentCount: sentCount)
    }

    public static func recordBroadcastAuditEvent(
        databasePath: String,
        event: BroadcastAuditEvent
    ) throws -> BroadcastAuditRecord {
        try StacioCoreBindings.recordBroadcastAuditEvent(databasePath: databasePath, event: event)
    }

    public static func listBroadcastAuditRecords(
        databasePath: String,
        limit: UInt32
    ) throws -> [BroadcastAuditRecord] {
        try StacioCoreBindings.listBroadcastAuditRecords(databasePath: databasePath, limit: limit)
    }

    public static func recordAgentActionEvent(
        databasePath: String,
        event: AgentActionAuditEvent
    ) throws -> AgentActionAuditRecord {
        try StacioCoreBindings.recordAgentActionEvent(databasePath: databasePath, event: event)
    }

    public static func listAgentActionEvents(
        databasePath: String,
        limit: UInt32
    ) throws -> [AgentActionAuditRecord] {
        try StacioCoreBindings.listAgentActionEvents(databasePath: databasePath, limit: limit)
    }

    public static func recordAgentTaskSession(
        databasePath: String,
        session: AgentTaskSessionDraft,
        proposals: [AgentTaskProposalDraft]
    ) throws -> AgentTaskSessionRecord {
        try StacioCoreBindings.recordAgentTaskSession(
            databasePath: databasePath,
            session: session,
            proposals: proposals
        )
    }

    public static func listAgentTaskSessions(
        databasePath: String,
        limit: UInt32
    ) throws -> [AgentTaskSessionRecord] {
        try StacioCoreBindings.listAgentTaskSessions(databasePath: databasePath, limit: limit)
    }

    public static func listAgentTaskSessions(
        databasePath: String,
        requestID: String
    ) throws -> [AgentTaskSessionRecord] {
        try StacioCoreBindings.listAgentTaskSessionsByRequestId(
            databasePath: databasePath,
            requestId: requestID
        )
    }

    public static func appendAIConversationHistoryItem(
        databasePath: String,
        item: AIConversationHistoryItemDraft
    ) throws -> AIConversationHistoryItemRecord {
        try StacioCoreBindings.appendAiConversationHistoryItem(databasePath: databasePath, item: item)
    }

    public static func listAIConversationHistory(
        databasePath: String,
        runtimeID: String
    ) throws -> [AIConversationHistoryItemRecord] {
        try StacioCoreBindings.listAiConversationHistory(databasePath: databasePath, runtimeId: runtimeID)
    }

    public static func clearAIConversationHistory(databasePath: String) throws {
        try StacioCoreBindings.clearAiConversationHistory(databasePath: databasePath)
    }

    public static func createTerminalMacro(
        databasePath: String,
        name: String,
        steps: [MacroStep]
    ) throws -> TerminalMacroRecord {
        try StacioCoreBindings.createTerminalMacro(
            databasePath: databasePath,
            name: name,
            steps: steps
        )
    }

    public static func listTerminalMacros(databasePath: String) throws -> [TerminalMacroRecord] {
        try StacioCoreBindings.listTerminalMacros(databasePath: databasePath)
    }

    public static func updateTerminalMacro(
        databasePath: String,
        macroID: String,
        name: String,
        steps: [MacroStep]
    ) throws -> TerminalMacroRecord {
        try StacioCoreBindings.updateTerminalMacro(
            databasePath: databasePath,
            macroId: macroID,
            name: name,
            steps: steps
        )
    }

    public static func renameTerminalMacro(
        databasePath: String,
        macroID: String,
        name: String
    ) throws -> TerminalMacroRecord {
        try StacioCoreBindings.renameTerminalMacro(
            databasePath: databasePath,
            macroId: macroID,
            name: name
        )
    }

    public static func deleteTerminalMacro(databasePath: String, macroID: String) throws {
        try StacioCoreBindings.deleteTerminalMacro(databasePath: databasePath, macroId: macroID)
    }

    public static func serializeMacroRecording(_ recording: MacroRecording) throws -> String {
        try StacioCoreBindings.serializeMacroRecording(recording: recording)
    }

    public static func playbackMacroSteps(_ recording: MacroRecording) -> [MacroStep] {
        StacioCoreBindings.playbackMacroSteps(recording: recording)
    }

    public static func x11ForwardingArguments(enableX11: Bool, trusted: Bool) -> [String] {
        StacioCoreBindings.x11ForwardingArguments(enableX11: enableX11, trusted: trusted)
    }

    public static func diagnoseX11(_ input: X11ProbeInput) -> GraphicsDiagnostic {
        StacioCoreBindings.diagnoseX11(input: input)
    }

    public static func buildVNCLaunchConfig(
        _ config: GraphicsAdapterConfig
    ) throws -> GraphicsLaunchConfig {
        try StacioCoreBindings.buildVncLaunchConfig(config: config)
    }
}
