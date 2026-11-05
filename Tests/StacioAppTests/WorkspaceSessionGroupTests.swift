import XCTest
@testable import StacioApp
import StacioCoreBindings

final class WorkspaceSessionGroupCodecTests: XCTestCase {
    func testWorkspaceGroupCodecRoundTripsOnlySessionReferencesAndPaths() throws {
        let definition = WorkspaceSessionGroupDefinition(
            kind: .sftp,
            layout: .grid,
            panes: [
                .localDirectory(path: "/Users/mac/Downloads"),
                .remoteSession(sessionID: "session-primary", path: "/srv/app"),
                .remoteSession(sessionID: "session-backup", path: "/srv/backup"),
                .localDirectory(path: "/Users/mac/Documents")
            ]
        )

        let json = try WorkspaceSessionGroupCodec.encode(definition)
        let restored = try WorkspaceSessionGroupCodec.decode(json)

        XCTAssertEqual(restored, definition)
        XCTAssertEqual(definition.sessionProtocol, "sftp-group")
        XCTAssertEqual(definition.displayName, "SFTP 分组")
        XCTAssertTrue(definition.shouldOfferSaveOnClose)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("secret"))
        XCTAssertTrue(json.contains("session-primary"))
    }

    func testWorkspaceGroupSaveOfferStartsAtFourPanes() {
        let threePanes = WorkspaceSessionGroupDefinition(
            kind: .terminalSplit,
            layout: .vertical,
            panes: (0..<3).map { .localTerminal(path: "/tmp/\($0)") }
        )
        let fourPanes = WorkspaceSessionGroupDefinition(
            kind: .terminalSplit,
            layout: .vertical,
            panes: (0..<4).map { .localTerminal(path: "/tmp/\($0)") }
        )

        XCTAssertFalse(threePanes.shouldOfferSaveOnClose)
        XCTAssertTrue(fourPanes.shouldOfferSaveOnClose)
    }

    func testWorkspaceGroupCodecRejectsTransientRemoteSessionReference() {
        let definition = WorkspaceSessionGroupDefinition(
            kind: .sftp,
            layout: .grid,
            panes: [
                .localDirectory(path: "/Users/mac/Downloads"),
                .localDirectory(path: "/Users/mac/Documents"),
                .remoteSession(sessionID: "saved-primary", path: "/srv/app"),
                .remoteSession(sessionID: "", path: "/srv/temporary")
            ]
        )

        XCTAssertThrowsError(try WorkspaceSessionGroupCodec.encode(definition)) { error in
            XCTAssertEqual(error as? WorkspaceSessionGroupCodecError, .unrestorablePane)
            XCTAssertEqual(
                error.localizedDescription,
                "分组中包含未保存的远端会话，请先将远端连接保存为会话后再保存分组。"
            )
        }
    }
}

@MainActor
final class WorkspaceSessionGroupCloseTests: XCTestCase {
    func testClosingFourPaneTerminalSplitOffersSaveAndPreservesCurrentCloseBehavior() throws {
        let presenter = RecordingWorkspaceGroupClosePresenter(
            decisions: [.save(name: "运维终端分组")]
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            workspaceGroupClosePresenter: presenter
        )
        workspace.loadView()
        let runtimeIDs = try (0..<4).map { _ in try workspace.openLocalShell() }
        try workspace.splitExistingTerminals(targetIDs: runtimeIDs, layout: .grid)
        var saved: [(String, WorkspaceSessionGroupDefinition)] = []
        workspace.onSaveWorkspaceSessionGroup = { name, definition in
            saved.append((name, definition))
        }

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertEqual(presenter.requests.map(\.definition.kind), [.terminalSplit])
        XCTAssertEqual(presenter.requests.map(\.definition.panes.count), [4])
        XCTAssertEqual(saved.map(\.0), ["运维终端分组"])
        XCTAssertEqual(saved.first?.1.layout, .grid)
        XCTAssertEqual(saved.first?.1.panes.map(\.kind), Array(repeating: .localTerminal, count: 4))
        XCTAssertEqual(workspace.openTerminalPaneCount, 4)
        XCTAssertEqual(workspaceGroupTabLabels(workspace).count, 4)
    }

    func testClosingThreePaneTerminalSplitDoesNotOfferGroupSave() throws {
        let presenter = RecordingWorkspaceGroupClosePresenter(
            decisions: [.save(name: "不应使用")]
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            workspaceGroupClosePresenter: presenter
        )
        workspace.loadView()
        let runtimeIDs = try (0..<3).map { _ in try workspace.openLocalShell() }
        try workspace.splitExistingTerminals(targetIDs: runtimeIDs, layout: .vertical)

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertTrue(presenter.requests.isEmpty)
        XCTAssertEqual(workspace.openTerminalPaneCount, 3)
    }

    func testCancelingGroupSaveKeepsTerminalWorkspaceOpen() throws {
        let presenter = RecordingWorkspaceGroupClosePresenter(decisions: [.cancel])
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            workspaceGroupClosePresenter: presenter
        )
        workspace.loadView()
        let runtimeIDs = try (0..<4).map { _ in try workspace.openLocalShell() }
        try workspace.startMultiExecSession(targetIDs: runtimeIDs)

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertEqual(presenter.requests.map(\.definition.kind), [.terminalMultiExec])
        XCTAssertEqual(workspace.openTerminalPaneCount, 4)
        XCTAssertEqual(workspaceGroupTabLabels(workspace), [L10n.MultiExec.title + " x4"])
        XCTAssertTrue(workspace.isMultiExecSessionActiveForTesting)
    }

    func testWorkbenchCloseSaveCreatesIndependentGroupSessionRecord() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioWorkspaceGroup-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let presenter = RecordingWorkspaceGroupClosePresenter(
            decisions: [.save(name: "日常运维终端")]
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            workspaceGroupClosePresenter: presenter
        )
        let workbench = WorkbenchWindowController(
            workspaceViewController: workspace,
            databasePathProvider: { databaseURL.path }
        )
        workbench.loadWindow()
        let runtimeIDs = try (0..<4).map { _ in try workspace.openLocalShell() }
        try workspace.splitExistingTerminals(targetIDs: runtimeIDs, layout: .grid)

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        let groups = try CoreBridge.listAllSessionRecords(databasePath: databaseURL.path)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.name, "日常运维终端")
        XCTAssertEqual(group.protocol, "terminal-group")
        XCTAssertNil(group.folderId)
        let configJSON = try XCTUnwrap(
            CoreBridge.getSessionConfigJSON(databasePath: databaseURL.path, id: group.id)
        )
        XCTAssertEqual(try WorkspaceSessionGroupCodec.decode(configJSON).panes.count, 4)
    }

    func testWorkbenchOpensSavedLocalTerminalGroupWithDirectoriesAndGridLayout() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioWorkspaceRestore-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let directories = ["/tmp/ops-a", "/tmp/ops-b", "/tmp/ops-c", "/tmp/ops-d"]
        let definition = WorkspaceSessionGroupDefinition(
            kind: .terminalSplit,
            layout: .grid,
            panes: directories.map { .localTerminal(path: $0) }
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let workbench = WorkbenchWindowController(
            workspaceViewController: workspace,
            databasePathProvider: { databaseURL.path }
        )
        workbench.loadWindow()
        let group = try workbench.saveWorkspaceSessionGroup(
            name: "本地运维工作区",
            definition: definition
        )

        let status = try workbench.openSavedSession(group)

        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(workspace.openTerminalPaneCount, 4)
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .grid)
        XCTAssertEqual(workspace.currentTerminalDirectoriesForTesting.compactMap { $0 }, directories)
        XCTAssertEqual(workspaceGroupTabLabels(workspace), ["本地运维工作区 x4"])
    }

    func testClosingFourPaneSCPAndSFTPWorkspacesSavesCurrentLayoutInsideOneTab() throws {
        for protocolName in ["SCP", "SFTP"] {
            let presenter = RecordingWorkspaceGroupClosePresenter(
                decisions: [.save(name: "\(protocolName) 发布工作区")]
            )
            let workspace = WorkspaceViewController(
                autoStartTerminalProcesses: false,
                workspaceGroupClosePresenter: presenter
            )
            workspace.loadView()
            let bridge = WorkspaceGroupRemoteFilesBridge()
            let context = workspaceGroupLiveContext(host: "primary.example.com")
            if protocolName == "SFTP" {
                _ = try workspace.openSFTPFilesSession(
                    context: context,
                    title: "发布文件",
                    bridge: bridge,
                    initialRemotePath: "/srv/app"
                )
            } else {
                _ = try workspace.openRemoteFilesSession(
                    context: context,
                    title: "发布文件",
                    bridge: bridge,
                    transferScheduler: nil,
                    initialRemotePath: "/srv/app"
                )
            }
            let filesPane = try XCTUnwrap(
                workspace.currentTerminalPane as? RemoteFilesPaneViewController
            )
            filesPane.markPrimaryFileTransferRemoteDevice(sessionID: "primary-session")
            let browser = try XCTUnwrap(filesPane.independentTransferBrowserForTesting)
            let localDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("StacioWorkspaceGroup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: localDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: localDirectory) }
            _ = browser.addLocalDirectoryPane(localDirectory)
            let remoteBridge: RemoteFilesBridging = protocolName == "SFTP"
                ? SFTPRemoteFilesBridgeAdapter(base: bridge)
                : bridge
            _ = browser.addRemotePane(
                runtimeID: "\(protocolName.lowercased())_backup_runtime",
                context: workspaceGroupLiveContext(host: "backup.example.com"),
                title: "备份服务器",
                bridge: remoteBridge,
                transferScheduler: nil,
                remoteProtocolName: protocolName,
                initialRemotePath: "/srv/backup",
                initialLoadPresentation: .immediate,
                sourceRuntimeID: "saved:backup-session"
            )
            browser.restoreWorkspace(
                additionalLocalDirectoryPaths: [],
                layout: .grid
            )
            var saved: [(String, WorkspaceSessionGroupDefinition)] = []
            workspace.onSaveWorkspaceSessionGroup = { name, definition in
                saved.append((name, definition))
            }

            try workspace.performTabContextActionForTesting(.closeTab, index: 0)

            let expectedKind: WorkspaceSessionGroupKind = protocolName == "SFTP" ? .sftp : .scp
            XCTAssertEqual(presenter.requests.map(\.definition.kind), [expectedKind])
            XCTAssertEqual(saved.map(\.0), ["\(protocolName) 发布工作区"])
            XCTAssertEqual(saved.first?.1.layout, .grid)
            XCTAssertEqual(saved.first?.1.panes.map(\.kind), [
                .localDirectory,
                .localDirectory,
                .remoteSession,
                .remoteSession
            ])
            XCTAssertEqual(
                saved.first?.1.panes.compactMap(\.sessionID),
                ["primary-session", "backup-session"]
            )
            XCTAssertTrue(workspaceGroupTabLabels(workspace).isEmpty)
        }
    }

    func testClosingFileWorkspaceWithTransientRemoteDoesNotPersistInvalidGroup() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioTransientWorkspaceGroup-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let closePresenter = RecordingWorkspaceGroupClosePresenter(
            decisions: [.save(name: "临时文件工作区")]
        )
        let errorPresenter = RecordingWorkspaceGroupErrorPresenter()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            tabOperationsPresenter: errorPresenter,
            workspaceGroupClosePresenter: closePresenter
        )
        let workbench = WorkbenchWindowController(
            workspaceViewController: workspace,
            databasePathProvider: { databaseURL.path }
        )
        workbench.loadWindow()
        let bridge = WorkspaceGroupRemoteFilesBridge()
        _ = try workspace.openSFTPFilesSession(
            context: workspaceGroupLiveContext(host: "primary.example.com"),
            title: "发布文件",
            bridge: bridge,
            initialRemotePath: "/srv/app"
        )
        let filesPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteFilesPaneViewController)
        filesPane.markPrimaryFileTransferRemoteDevice(sessionID: "saved-primary")
        let browser = try XCTUnwrap(filesPane.independentTransferBrowserForTesting)
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioTransientWorkspaceLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        _ = browser.addLocalDirectoryPane(localDirectory)
        _ = browser.addRemotePane(
            runtimeID: "sftp_transient_remote",
            context: workspaceGroupLiveContext(host: "temporary.example.com"),
            title: "临时远端",
            bridge: SFTPRemoteFilesBridgeAdapter(base: bridge),
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "/srv/temporary",
            initialLoadPresentation: .immediate
        )

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertEqual(closePresenter.requests.map(\.definition.kind), [.sftp])
        XCTAssertEqual(workspaceGroupTabLabels(workspace), ["发布文件"])
        XCTAssertTrue(try CoreBridge.listAllSessionRecords(databasePath: databaseURL.path).isEmpty)
        XCTAssertEqual(errorPresenter.errors.map(\.title), ["无法保存分组会话"])
        XCTAssertEqual(
            errorPresenter.errors.map(\.message),
            ["分组中包含未保存的远端会话，请先将远端连接保存为会话后再保存分组。"]
        )
    }

    func testWorkbenchRestoresSavedRemoteTerminalGroupAndRetainsMemberSessionIDs() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteTerminalGroup-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let sessions = try (0..<4).map { index in
            try CoreBridge.createSessionRecord(
                databasePath: databaseURL.path,
                draft: SessionDraft(
                    folderId: nil,
                    name: "运维主机 \(index + 1)",
                    protocol: "ssh",
                    host: "node-\(index + 1).example.com",
                    port: 22,
                    username: "ops",
                    privateKeyPath: nil,
                    credentialId: nil,
                    tags: [],
                    configJson: nil
                )
            )
        }
        let definition = WorkspaceSessionGroupDefinition(
            kind: .terminalSplit,
            layout: .horizontal,
            panes: sessions.map { .terminalSession(sessionID: $0.id) }
        )
        let presenter = RecordingWorkspaceGroupClosePresenter(decisions: [.cancel])
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false,
            workspaceGroupClosePresenter: presenter
        )
        let starter = WorkspaceGroupRemoteSessionStarter(workspace: workspace)
        let workbench = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            databasePathProvider: { databaseURL.path }
        )
        workbench.loadWindow()
        let group = try workbench.saveWorkspaceSessionGroup(
            name: "四机巡检",
            definition: definition
        )

        let status = try workbench.openSavedSession(group)

        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(starter.startedHosts, sessions.map(\.host))
        XCTAssertEqual(workspace.openTerminalPaneCount, 4)
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .horizontal)
        XCTAssertEqual(workspaceGroupTabLabels(workspace), ["四机巡检 x4"])

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertTrue(
            presenter.requests.isEmpty,
            "未修改的已保存分组再次关闭时不应重复询问是否另存"
        )
        XCTAssertEqual(workspaceGroupTabLabels(workspace).count, 4)
        XCTAssertFalse(workspaceGroupTabLabels(workspace).contains("四机巡检 x4"))
    }
}

@MainActor
private func workspaceGroupTabLabels(_ workspace: WorkspaceViewController) -> [String] {
    let mirror = Mirror(reflecting: workspace)
    let tabController = mirror.children.first { $0.label == "tabViewController" }?.value as? NSTabViewController
    return tabController?.tabViewItems.map(\.label) ?? []
}

@MainActor
private final class RecordingWorkspaceGroupClosePresenter: WorkspaceSessionGroupClosePresenting {
    struct Request {
        let definition: WorkspaceSessionGroupDefinition
        let suggestedName: String
    }

    var decisions: [WorkspaceSessionGroupCloseDecision]
    private(set) var requests: [Request] = []

    init(decisions: [WorkspaceSessionGroupCloseDecision]) {
        self.decisions = decisions
    }

    func decisionForClosingGroup(
        definition: WorkspaceSessionGroupDefinition,
        suggestedName: String,
        parentWindow: NSWindow?
    ) -> WorkspaceSessionGroupCloseDecision {
        requests.append(Request(definition: definition, suggestedName: suggestedName))
        return decisions.isEmpty ? .discard : decisions.removeFirst()
    }
}

@MainActor
private final class RecordingWorkspaceGroupErrorPresenter: WorkspaceTabOperationsPresenting {
    private(set) var errors: [(title: String, message: String)] = []

    func promptRenameTab(currentTitle: String, parentWindow: NSWindow?) -> String? { nil }

    func chooseTabColor(currentColor: NSColor, title: String, parentWindow: NSWindow?) -> NSColor? { nil }

    func chooseTerminalOutputDestination(suggestedName: String, parentWindow: NSWindow?) -> URL? { nil }

    func presentTerminalOutputSaved(destinationURL: URL, parentWindow: NSWindow?) {}

    func presentError(title: String, message: String, parentWindow: NSWindow?) {
        errors.append((title, message))
    }
}

@MainActor
private final class WorkspaceGroupRemoteSessionStarter: RemoteSSHSessionStarting {
    private weak var workspace: WorkspaceViewController?
    private(set) var startedHosts: [String] = []

    init(workspace: WorkspaceViewController) {
        self.workspace = workspace
    }

    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        startedHosts.append(config.host)
        let status = LiveShellStatus(
            runtimeId: "term_workspace_group_\(startedHosts.count)",
            status: "running",
            diagnostic: "running"
        )
        workspace?.openRemoteShell(status: status, title: title, connectionKind: .ssh)
        return status
    }
}

private final class WorkspaceGroupRemoteFilesBridge: RemoteFilesBridging {
    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] { [] }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] { [] }

    func listLiveSFTPDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] { [] }

    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] { [] }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private func workspaceGroupLiveContext(host: String) -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: host,
            port: 22,
            username: "ops",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:workspace-group"
    )
}
