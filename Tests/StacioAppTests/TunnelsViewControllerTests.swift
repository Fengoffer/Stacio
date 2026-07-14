import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class TunnelsViewControllerTests: XCTestCase {
    func testTunnelsPanelRendersNativeRowsAndEmbeddedEngineSummary() {
        let controller = TunnelsViewController()
        controller.loadView()

        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            ),
            TunnelProfile(
                id: "tun_dynamic",
                kind: .dynamic,
                localHost: "127.0.0.1",
                localPort: 1080,
                remoteHost: "socks",
                remotePort: 1080
            )
        ])

        XCTAssertEqual(controller.tunnelCount, 2)
        XCTAssertEqual(controller.tableView.numberOfRows, 2)
        XCTAssertNotNil(controller.tableView.enclosingScrollView)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["类型", "本地", "远端", "状态", "详情"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "本地")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "127.0.0.1:15432")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "db.internal:5432")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 1), "由 SOCKS 客户端指定")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "已停止")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 1), "就绪")
        XCTAssertEqual(controller.tunnelTrafficTextsForTesting, ["—", "—"])
        XCTAssertEqual(controller.tunnelStatusIndicatorStyleNamesForTesting, ["stopped", "stopped"])
        XCTAssertEqual(controller.engineSummaryText, "内置 SSH 隧道")
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("system ssh"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("OpenSSH"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testEmptyTunnelsPanelUsesAccessibleNativeInspectorState() {
        let controller = TunnelsViewController()
        controller.loadView()

        XCTAssertEqual(controller.tunnelCount, 0)
        XCTAssertEqual(controller.tableView.accessibilityIdentifier(), "Stacio.Tunnels.table")
        XCTAssertEqual(controller.tableView.accessibilityLabel(), "SSH 隧道")
        XCTAssertTrue(controller.visibleTextSnapshot.contains("暂无隧道"))
    }

    func testTunnelsControllerLoadsPersistedProfilesFromStore() {
        let store = RecordingTunnelProfileStore(profiles: [
            TunnelProfile(
                id: "tun_persisted",
                kind: .remote,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "0.0.0.0",
                remotePort: 19000
            )
        ])
        let controller = TunnelsViewController(profileStore: store)

        controller.loadView()

        XCTAssertEqual(store.events, ["list"])
        XCTAssertEqual(controller.tunnelCount, 1)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "远端")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "0.0.0.0:19000")
    }

    func testTunnelProfileManagementButtonsExposeNativeIconActions() {
        let controller = TunnelsViewController()

        controller.loadView()

        XCTAssertEqual(controller.tunnelManagementActionLabels, ["新建隧道", "编辑隧道", "删除隧道"])
        XCTAssertEqual(controller.tunnelManagementActionEnabledStates, [true, false, false])
    }

    func testTunnelsInspectorTableFitsNarrowPanelWithoutNestedHorizontalScrolling() {
        let controller = TunnelsViewController()
        controller.loadView()

        let scrollView = controller.tableView.enclosingScrollView
        let totalColumnWidth = controller.tableView.tableColumns.reduce(CGFloat(0)) { partialResult, column in
            partialResult + column.width
        }

        XCTAssertEqual(scrollView?.hasHorizontalScroller, false)
        XCTAssertLessThanOrEqual(totalColumnWidth, 318)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.card"))
        XCTAssertFalse(controller.tableView.usesAlternatingRowBackgroundColors)
    }

    func testAddTunnelButtonPresentsQuickAddPopoverWithoutOpeningFullEditor() {
        let store = RecordingTunnelProfileStore()
        let editor = RecordingTunnelProfileEditor()
        let controller = TunnelsViewController(profileStore: store, profileEditor: editor)
        controller.loadView()

        controller.performTunnelManagementActionForTesting("新建隧道")

        XCTAssertEqual(editor.events, [])
        XCTAssertEqual(store.events, ["list"])
        XCTAssertEqual(store.profiles.map(\.id), [])
        XCTAssertEqual(controller.quickAddPopoverAccessibilityIdentifierForTesting, "Stacio.Tunnels.quickAddPopover")
    }

    func testQuickAddTunnelProfileCreatesStartsAndRefreshesRows() {
        let store = RecordingTunnelProfileStore()
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = TunnelsViewController(runtimeBridge: bridge, profileStore: store)
        controller.loadView()

        controller.presentQuickAddTunnelPopoverForTesting()
        controller.performQuickAddTunnelForTesting(
            kind: .local,
            localPort: "18080",
            target: "app.internal:8080",
            remark: "API"
        )

        XCTAssertEqual(store.events, ["list", "save:tun_api", "list"])
        XCTAssertEqual(store.profiles.map(\.id), ["tun_api"])
        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["tun_api"])
        XCTAssertEqual(bridge.startedProfiles.map(\.localPort), [18080])
        XCTAssertEqual(bridge.startedProfiles.map(\.remoteHost), ["app.internal"])
        XCTAssertEqual(bridge.startedProfiles.map(\.remotePort), [8080])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(controller.tunnelTrafficTextsForTesting, ["—"])
        XCTAssertEqual(controller.tunnelStatusIndicatorStyleNamesForTesting, ["running"])
    }

    func testQuickAddDynamicTunnelIgnoresTargetAndStartsSocksForward() {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()

        controller.performQuickAddTunnelForTesting(
            kind: .dynamic,
            localPort: "1080",
            target: "",
            remark: "SOCKS"
        )

        XCTAssertEqual(bridge.startedProfiles.map(\.kind), [.dynamic])
        XCTAssertEqual(bridge.startedProfiles.map(\.localHost), ["127.0.0.1"])
        XCTAssertEqual(bridge.startedProfiles.map(\.localPort), [1080])
        XCTAssertEqual(bridge.startedProfiles.map(\.remoteHost), ["socks"])
        XCTAssertEqual(bridge.startedProfiles.map(\.remotePort), [1080])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "动态")
    }

    func testEditTunnelProfileOffersOnlySSHandSCPSessionsAsEndpointSources() {
        let profile = TunnelProfile(
            id: "tun_edit_endpoint_sources",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "app.internal",
            remotePort: 8080
        )
        let sessionStore = RecordingTunnelEndpointSessionStore(
            rootSessions: [
                savedSession(id: "session_ssh", name: "生产 SSH", protocol: "ssh", host: "jump.example.com", port: 22),
                savedSession(id: "session_telnet", name: "老路由", protocol: "telnet", host: "router.example.com", port: 23),
                savedSession(id: "session_scp", name: "文件入口", protocol: "scp", host: "files.example.com", port: 2222),
                savedSession(id: "session_ftp", name: "FTP", protocol: "ftp", host: "ftp.example.com", port: 21)
            ]
        )
        let editor = RecordingTunnelProfileEditor(editedProfile: profile)
        let controller = TunnelsViewController(
            profileStore: RecordingTunnelProfileStore(profiles: [profile]),
            profileEditor: editor,
            endpointSessionStore: sessionStore
        )
        controller.loadView()

        controller.selectTunnelRowsForTesting(IndexSet(integer: 0))
        controller.performTunnelManagementActionForTesting("编辑隧道")

        XCTAssertEqual(sessionStore.events, ["folders", "sessions:nil"])
        XCTAssertEqual(editor.events, ["edit:tun_edit_endpoint_sources:1"])
        XCTAssertEqual(editor.endpointSessionTitles, [["生产 SSH - ops@jump.example.com:22", "文件入口 - ops@files.example.com:2222"]])
    }

    func testEditTunnelProfilePersistsSelectedEndpointSessionReference() {
        let profile = TunnelProfile(
            id: "tun_edit_endpoint",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "jump.example.com",
            remotePort: 22
        )
        let store = RecordingTunnelProfileStore(profiles: [profile])
        let editor = RecordingTunnelProfileEditor(
            editedProfile: profile,
            endpointSessionID: "session_ssh"
        )
        let controller = TunnelsViewController(profileStore: store, profileEditor: editor)
        controller.loadView()

        controller.selectTunnelRowsForTesting(IndexSet(integer: 0))
        controller.performTunnelManagementActionForTesting("编辑隧道")

        XCTAssertEqual(store.records.map(\.profile.id), ["tun_edit_endpoint"])
        XCTAssertEqual(store.records.map(\.endpointSessionId), ["session_ssh"])
    }

    func testTunnelProfileEditorSheetUsesWideNativeGridLayout() throws {
        let controller = TunnelProfileEditorViewController(
            existingRecord: nil,
            existingProfiles: [],
            endpointSessions: [
                try XCTUnwrap(TunnelEndpointSession(session: savedSession(
                    id: "session_ssh",
                    name: "生产 SSH",
                    protocol: "ssh",
                    host: "jump.example.com",
                    port: 22
                )))
            ]
        )
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.Tunnels.editorSheet")
        XCTAssertNil(controller.view.firstSubview(ofType: NSImageView.self))

        let grid = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.editorGrid") as? NSGridView)
        let localHostField = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.localHost") as? NSTextField)
        let remoteHostField = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.remoteHost") as? NSTextField)
        let saveButton = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.save") as? NSButton)
        let cancelButton = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.cancel") as? NSButton)

        XCTAssertGreaterThanOrEqual(controller.view.frame.width, 540)
        XCTAssertGreaterThanOrEqual(grid.frame.width, 500)
        XCTAssertGreaterThanOrEqual(localHostField.frame.width, 340)
        XCTAssertEqual(localHostField.frame.width, remoteHostField.frame.width, accuracy: 1)
        let cancelFrame = controller.view.convert(cancelButton.bounds, from: cancelButton)
        let saveFrame = controller.view.convert(saveButton.bounds, from: saveButton)
        XCTAssertGreaterThan(saveFrame.midX, cancelFrame.midX)
        XCTAssertGreaterThanOrEqual(saveFrame.minY, 16)
        XCTAssertLessThanOrEqual(saveFrame.maxX, controller.view.bounds.maxX - 16)
    }

    func testDynamicTunnelProfileEditorHidesRemoteTargetAndWarnsForNonLocalBind() throws {
        let controller = TunnelProfileEditorViewController(
            existingRecord: TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_dynamic_editor",
                    kind: .dynamic,
                    localHost: "127.0.0.1",
                    localPort: 1080,
                    remoteHost: "",
                    remotePort: 1
                ),
                sessionId: nil,
                endpointSessionId: nil
            ),
            existingProfiles: [],
            endpointSessions: [
                try XCTUnwrap(TunnelEndpointSession(session: savedSession(
                    id: "session_ssh",
                    name: "生产 SSH",
                    protocol: "ssh",
                    host: "jump.example.com",
                    port: 22
                )))
            ]
        )
        controller.loadView()

        let remoteHostField = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.remoteHost") as? NSTextField)
        let remotePortField = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.remotePort") as? NSTextField)
        let endpointPopup = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.endpointSession") as? NSPopUpButton)
        let localHostField = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.localHost") as? NSTextField)
        let bindWarningLabel = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Tunnels.bindWarning") as? NSTextField)

        XCTAssertTrue(remoteHostField.isHidden)
        XCTAssertTrue(remotePortField.isHidden)
        XCTAssertFalse(endpointPopup.isEnabled)
        XCTAssertTrue(bindWarningLabel.isHidden)

        localHostField.stringValue = "0.0.0.0"
        _ = localHostField.target?.perform(localHostField.action, with: localHostField)

        XCTAssertFalse(bindWarningLabel.isHidden)
        XCTAssertTrue(bindWarningLabel.stringValue.contains("SOCKS5 代理可能暴露给局域网"))
    }

    func testTunnelEndpointSessionAppliesSavedSessionEndpointWithoutSecrets() throws {
        let session = savedSession(
            id: "session_ssh",
            name: "堡垒机",
            protocol: "ssh",
            host: "jump.example.com",
            port: 2222,
            credentialID: "secret-ref-password"
        )
        let endpoint = try XCTUnwrap(TunnelEndpointSession(session: session))
        let profile = endpoint.applyEndpoint(
            to: TunnelProfile(
                id: "tun_from_session",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 18080,
                remoteHost: "old.example.com",
                remotePort: 8080
            )
        )

        XCTAssertEqual(profile.remoteHost, "jump.example.com")
        XCTAssertEqual(profile.remotePort, 2222)
        XCTAssertFalse(String(describing: profile).contains("secret-ref-password"))
    }

    func testEditSelectedTunnelProfileSavesReplacementAndRefreshesRows() {
        let existing = TunnelProfile(
            id: "tun_edit",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "app.internal",
            remotePort: 8080
        )
        let edited = TunnelProfile(
            id: "tun_edit",
            kind: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1080,
            remoteHost: "socks",
            remotePort: 1080
        )
        let store = RecordingTunnelProfileStore(profiles: [existing])
        let editor = RecordingTunnelProfileEditor(editedProfile: edited)
        let controller = TunnelsViewController(profileStore: store, profileEditor: editor)
        controller.loadView()

        controller.selectTunnelRowsForTesting(IndexSet(integer: 0))
        controller.performTunnelManagementActionForTesting("编辑隧道")

        XCTAssertEqual(editor.events, ["edit:tun_edit:1"])
        XCTAssertEqual(store.events, ["list", "save:tun_edit", "list"])
        XCTAssertEqual(store.profiles.map(\.kind), [.dynamic])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "动态")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "127.0.0.1:1080")
    }

    func testDeleteSelectedTunnelProfileRemovesPersistedProfileAndRefreshesRows() {
        let first = TunnelProfile(
            id: "tun_keep",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "app.internal",
            remotePort: 8080
        )
        let second = TunnelProfile(
            id: "tun_delete",
            kind: .remote,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "0.0.0.0",
            remotePort: 19000
        )
        let store = RecordingTunnelProfileStore(profiles: [first, second])
        let confirmation = RecordingTunnelProfileDeletionConfirmation(shouldDelete: true)
        let controller = TunnelsViewController(
            profileStore: store,
            deletionConfirmation: confirmation
        )
        controller.loadView()

        controller.selectTunnelRowsForTesting(IndexSet(integer: 1))
        controller.performTunnelManagementActionForTesting("删除隧道")

        XCTAssertEqual(confirmation.events, ["delete:tun_delete"])
        XCTAssertEqual(store.events, ["list", "delete:tun_delete", "list"])
        XCTAssertEqual(controller.tunnelCount, 1)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "app.internal:8080")
    }

    func testDeletingRunningTunnelStopsRuntimeBeforeRemovingProfile() {
        let bridge = RecordingTunnelRuntimeBridge()
        let confirmation = RecordingTunnelProfileDeletionConfirmation(shouldDelete: true)
        let controller = TunnelsViewController(
            runtimeBridge: bridge,
            deletionConfirmation: confirmation
        )
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_delete_running",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.internal",
            remotePort: 5432
        )
        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)

        controller.selectTunnelRowsForTesting(IndexSet(integer: 0))
        controller.performTunnelManagementActionForTesting("删除隧道")

        XCTAssertEqual(confirmation.events, ["delete:tun_delete_running"])
        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["tun_delete_running"])
        XCTAssertEqual(bridge.stoppedStates, [.running])
        XCTAssertEqual(controller.tunnelCount, 0)
        XCTAssertEqual(controller.tableView.numberOfRows, 0)
    }

    func testDeletingRunningTunnelRejectsMismatchedStopStatusWithoutRemovingProfile() {
        let profile = TunnelProfile(
            id: "tun_delete_running_mismatch",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.internal",
            remotePort: 5432
        )
        let store = RecordingTunnelProfileStore(profiles: [profile])
        let bridge = RecordingTunnelRuntimeBridge(
            stopStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_old",
                    state: .stopped,
                    message: "stale stop"
                )
            ]
        )
        let confirmation = RecordingTunnelProfileDeletionConfirmation(shouldDelete: true)
        let controller = TunnelsViewController(
            runtimeBridge: bridge,
            profileStore: store,
            deletionConfirmation: confirmation
        )
        controller.loadView()

        controller.performTunnelActionForTesting(at: 0)
        controller.selectTunnelRowsForTesting(IndexSet(integer: 0))
        controller.performTunnelManagementActionForTesting("删除隧道")

        XCTAssertEqual(confirmation.events, ["delete:tun_delete_running_mismatch"])
        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["tun_delete_running_mismatch"])
        XCTAssertEqual(store.events, ["list"])
        XCTAssertEqual(store.profiles.map(\.id), ["tun_delete_running_mismatch"])
        XCTAssertEqual(controller.tunnelCount, 1)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "隧道状态不匹配：tun_old")
    }

    func testTunnelActionsStartAndStopThroughBridge() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_local",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)
        controller.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["tun_local"])
        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["tun_local"])
        XCTAssertEqual(bridge.stoppedStates, [.running])
        XCTAssertEqual(controller.tunnelActionLabels, ["启动"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "已停止")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "已停止")
    }

    func testTunnelStatusIndicatorTracksRuntimeStateAndTraffic() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            startStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .starting,
                    message: "starting"
                )
            ],
            polledStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .running,
                    message: "running accepted=1 active=1 client_to_remote_bytes=1258291 remote_to_client_bytes=3565158"
                ),
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .failed,
                    message: "SSH 隧道失败"
                )
            ]
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        XCTAssertEqual(controller.tunnelStatusIndicatorStyleNamesForTesting, ["stopped"])

        controller.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "启动中")
        XCTAssertEqual(controller.tunnelStatusIndicatorStyleNamesForTesting, ["connecting"])

        controller.pollTunnelsForTesting()

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(controller.tunnelTrafficTextsForTesting, ["↑ 1.2 MB  ↓ 3.4 MB"])
        XCTAssertEqual(controller.tunnelStatusIndicatorStyleNamesForTesting, ["running"])

        controller.pollTunnelsForTesting()

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tunnelStatusIndicatorStyleNamesForTesting, ["failed"])
    }

    func testTunnelProfileReloadPreservesRunningRuntimeStateForActiveProfile() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_reload_running",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)
        controller.setTunnelProfiles([profile])

        XCTAssertEqual(controller.runningTunnelCount, 1)
        XCTAssertEqual(controller.tunnelActionLabels, ["停止"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "运行中")
    }

    func testTunnelProfileReloadDropsRunningRuntimeStateWhenActiveProfileConfigurationChanges() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_reload_changed",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.internal",
            remotePort: 5432
        )
        let changedProfile = TunnelProfile(
            id: "tun_reload_changed",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 16432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)
        controller.setTunnelProfiles([changedProfile])

        XCTAssertEqual(controller.runningTunnelCount, 0)
        XCTAssertEqual(controller.tunnelActionLabels, ["启动"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "127.0.0.1:16432")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "已停止")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "就绪")
    }

    func testRunningTunnelPollRefreshesLiveStatusAndStopsPollingAfterFailure() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            polledStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .running,
                    message: "running accepted=1 active=1 client_to_remote_bytes=12 remote_to_client_bytes=8"
                ),
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .failed,
                    message: "SSH 隧道失败"
                )
            ]
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        controller.performTunnelActionForTesting(at: 0)
        controller.pollTunnelsForTesting()

        XCTAssertEqual(bridge.polledProfileIDs, ["tun_local"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(
            controller.tableView.viewText(atColumn: 4, row: 0),
            "运行中，接入 1，活跃 1，上行 12 字节，下行 8 字节"
        )

        controller.pollTunnelsForTesting()
        controller.pollTunnelsForTesting()

        XCTAssertEqual(bridge.polledProfileIDs, ["tun_local", "tun_local"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "SSH 隧道失败")
    }

    func testRunningTunnelPollSchedulesAutomaticReconnectAfterDisconnect() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            polledStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .starting,
                    message: "reconnecting attempt=1 max_attempts=10 last_error=SSH 隧道失败"
                )
            ]
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        controller.performTunnelActionForTesting(at: 0)
        controller.pollTunnelsForTesting()

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "启动中")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "重连中…（第1次）")

        XCTAssertTrue(waitForTunnelTestCondition {
            bridge.startedProfiles.map(\.id) == ["tun_local", "tun_local"] &&
                controller.tableView.viewText(atColumn: 3, row: 0) == "运行中" &&
                controller.tableView.viewText(atColumn: 4, row: 0) == "运行中"
        })

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["tun_local", "tun_local"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "运行中")
    }

    func testManualTunnelStopCancelsPendingAutomaticReconnect() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            polledStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .starting,
                    message: "reconnecting attempt=1 max_attempts=10 last_error=SSH 隧道失败"
                )
            ]
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        controller.performTunnelActionForTesting(at: 0)
        controller.pollTunnelsForTesting()
        controller.performTunnelActionForTesting(at: 0)

        XCTAssertFalse(waitForTunnelTestCondition(timeout: 0.15) {
            bridge.startedProfiles.count > 1
        })

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["tun_local"])
        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["tun_local"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "已停止")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "已停止")
    }

    func testAutomaticTunnelReconnectStopsAfterConfiguredMaximumAttempts() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            startErrors: [
                nil,
                TunnelRuntimeBridgeError(message: "first reconnect failed")
            ],
            polledStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_local",
                    state: .starting,
                    message: "reconnecting attempt=1 max_attempts=1 last_error=SSH 隧道失败"
                )
            ]
        )
        let controller = TunnelsViewController(
            runtimeBridge: bridge,
            maxAutomaticReconnectAttempts: 1
        )
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        controller.performTunnelActionForTesting(at: 0)
        controller.pollTunnelsForTesting()
        XCTAssertTrue(waitForTunnelTestCondition {
            bridge.startedProfiles.map(\.id) == ["tun_local", "tun_local"] &&
                controller.tableView.viewText(atColumn: 3, row: 0) == "失败" &&
                controller.tableView.viewText(atColumn: 4, row: 0) == "已断开，自动重连超过 1 次。"
        })

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["tun_local", "tun_local"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "已断开，自动重连超过 1 次。")
        XCTAssertEqual(controller.tunnelActionLabels, ["启动"])
    }

    func testRunningTunnelPollIgnoresStaleStatusForDifferentProfile() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            polledStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_old",
                    state: .failed,
                    message: "旧隧道失败不应覆盖当前隧道"
                )
            ]
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        controller.performTunnelActionForTesting(at: 0)
        controller.pollTunnelsForTesting()

        XCTAssertEqual(bridge.polledProfileIDs, ["tun_local"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "运行中")
        XCTAssertEqual(controller.tunnelActionLabels, ["停止"])
    }

    func testTunnelStartRejectsMismatchedProfileStatus() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            startStatuses: [
                TunnelRuntimeStatus(
                    profileId: "tun_old",
                    state: .running,
                    message: "stale runtime should not attach"
                )
            ]
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfiles([
            TunnelProfile(
                id: "tun_local",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        ])

        controller.performTunnelActionForTesting(at: 0)
        controller.pollTunnelsForTesting()

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["tun_local"])
        XCTAssertEqual(bridge.polledProfileIDs, [])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "隧道状态不匹配：tun_old")
        XCTAssertEqual(controller.tunnelActionLabels, ["启动"])
    }

    func testTunnelContextMenuCopiesSSHForwardCommands() throws {
        let sessionStore = RecordingTunnelEndpointSessionStore(
            rootSessions: [
                savedSession(id: "session_ssh", name: "生产 SSH", protocol: "ssh", host: "jump.example.com", port: 22)
            ]
        )
        let controller = TunnelsViewController(endpointSessionStore: sessionStore)
        controller.loadView()
        controller.setTunnelProfileRecords([
            TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_local",
                    kind: .local,
                    localHost: "127.0.0.1",
                    localPort: 18080,
                    remoteHost: "app.internal",
                    remotePort: 8080
                ),
                sessionId: nil,
                endpointSessionId: "session_ssh"
            ),
            TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_dynamic",
                    kind: .dynamic,
                    localHost: "127.0.0.1",
                    localPort: 1080,
                    remoteHost: "socks",
                    remotePort: 1080
                ),
                sessionId: nil,
                endpointSessionId: nil
            ),
            TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_remote",
                    kind: .remote,
                    localHost: "127.0.0.1",
                    localPort: 15432,
                    remoteHost: "0.0.0.0",
                    remotePort: 19000
                ),
                sessionId: nil,
                endpointSessionId: "session_ssh"
            )
        ])

        XCTAssertEqual(controller.tunnelContextMenuTitlesForTesting(row: 0), ["复制SSH 隧道命令"])

        NSPasteboard.general.clearContents()
        controller.performTunnelContextMenuActionForTesting(row: 0, title: "复制SSH 隧道命令")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ssh -L 18080:app.internal:8080 ops@jump.example.com")

        NSPasteboard.general.clearContents()
        controller.performTunnelContextMenuActionForTesting(row: 1, title: "复制SSH 隧道命令")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ssh -D 1080 user@host")

        NSPasteboard.general.clearContents()
        controller.performTunnelContextMenuActionForTesting(row: 2, title: "复制SSH 隧道命令")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ssh -R 19000:127.0.0.1:15432 ops@jump.example.com")
    }

    func testTunnelStartFailureShowsRedactedDiagnostic() {
        let bridge = RecordingTunnelRuntimeBridge(startError: TunnelRuntimeBridgeError(message: "credential secret-ref failed at /Users/me/.ssh/id_ed25519"))
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_fail",
            kind: .remote,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "app.internal",
            remotePort: 8080
        )

        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "[已隐藏凭据] 失败位置 [已隐藏路径]")
        XCTAssertFalse(controller.visibleTextSnapshot.contains("secret-ref"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("/Users/me/.ssh/id_ed25519"))
    }

    func testTunnelStartFailureRedactsBearerCredentialValues() {
        let bridge = RecordingTunnelRuntimeBridge(
            startError: TunnelRuntimeBridgeError(message: "Authentication failed Authorization: Bearer sk-live-1234567890")
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_bearer_fail",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(
            controller.tableView.viewText(atColumn: 4, row: 0),
            "认证失败 Authorization: Bearer [已隐藏凭据]"
        )
        XCTAssertFalse(controller.visibleTextSnapshot.contains("sk-live-1234567890"))
    }

    func testDefaultTunnelBridgeRequiresLiveSessionContextBeforeStart() {
        let bridge = CoreBridgeTunnelRuntimeBridge()
        let profile = TunnelProfile(
            id: "tun_no_context",
            kind: .remote,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "app.internal",
            remotePort: 8080
        )

        let status = try? bridge.start(profile: profile)

        XCTAssertEqual(status?.profileId, "tun_no_context")
        XCTAssertEqual(status?.state, .failed)
        XCTAssertEqual(status?.message, "missing_live_session_context")
    }

    func testTunnelStartWithoutCurrentSSHContextShowsActionableChineseDiagnostic() {
        let bridge = CoreBridgeTunnelRuntimeBridge(liveBridge: RecordingLiveTunnelCoreBridge())
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        let profile = TunnelProfile(
            id: "tun_no_context_ui",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        controller.setTunnelProfiles([profile])
        controller.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(
            controller.tableView.viewText(atColumn: 4, row: 0),
            "需要先打开一个 SSH 或 SCP 会话，再启动隧道。"
        )
        XCTAssertFalse(controller.visibleTextSnapshot.contains("missing_live_session_context"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testCoreTunnelBridgeStartsLiveRuntimeWhenSessionContextIsAvailable() throws {
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let context = TunnelLiveSessionContext(
            config: sshConfig(),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let bridge = CoreBridgeTunnelRuntimeBridge(
            liveSessionContextProvider: { context },
            liveBridge: liveBridge
        )
        let profile = TunnelProfile(
            id: "tun_live_context",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        let status = try bridge.start(profile: profile)

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_live_context"])
        XCTAssertEqual(liveBridge.startedConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(liveBridge.expectedFingerprints, ["SHA256:test"])
    }

    func testCoreTunnelBridgeBuildsLiveContextFromSavedEndpointSessionWhenCurrentContextIsMissing() throws {
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let contextBuilder = RecordingEndpointTunnelContextBuilder(
            context: TunnelLiveSessionContext(
                config: sshConfig(),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:endpoint"
            )
        )
        let resolver = RecordingTunnelEndpointSessionResolver(
            sessions: [
                savedSession(
                    id: "session_scp",
                    name: "文件入口",
                    protocol: "scp",
                    host: "jump.example.com",
                    port: 2222,
                    credentialID: "password-ref"
                )
            ]
        )
        let bridge = CoreBridgeTunnelRuntimeBridge(
            liveBridge: liveBridge,
            endpointSessionResolver: resolver,
            endpointContextBuilder: contextBuilder,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let record = TunnelProfileRecord(
            profile: TunnelProfile(
                id: "tun_endpoint",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 18080,
                remoteHost: "db.internal",
                remotePort: 5432
            ),
            sessionId: nil,
            endpointSessionId: "session_scp"
        )

        let status = try bridge.start(record: record)

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(resolver.resolvedSessionIDs, ["session_scp"])
        XCTAssertEqual(contextBuilder.configs.map(\.host), ["jump.example.com"])
        XCTAssertEqual(contextBuilder.configs.map(\.port), [2222])
        XCTAssertEqual(contextBuilder.configs.map(\.username), ["ops"])
        XCTAssertEqual(contextBuilder.configs.map(\.authMethod), [.privateKey(keyPath: "/Users/me/.ssh/id_ed25519", passphraseRef: "password-ref")])
        XCTAssertEqual(contextBuilder.databasePaths, ["/tmp/Stacio-test.sqlite"])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_endpoint"])
        XCTAssertEqual(liveBridge.startedConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(liveBridge.expectedFingerprints, ["SHA256:endpoint"])
    }

    func testTunnelStartWithMissingSavedEndpointSessionShowsChineseDiagnostic() {
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let resolver = RecordingTunnelEndpointSessionResolver(sessions: [])
        let bridge = CoreBridgeTunnelRuntimeBridge(
            liveBridge: liveBridge,
            endpointSessionResolver: resolver,
            endpointContextBuilder: RecordingEndpointTunnelContextBuilder(),
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let controller = TunnelsViewController(runtimeBridge: bridge)
        controller.loadView()
        controller.setTunnelProfileRecords([
            TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_missing_endpoint",
                    kind: .local,
                    localHost: "127.0.0.1",
                    localPort: 18080,
                    remoteHost: "db.internal",
                    remotePort: 5432
                ),
                sessionId: nil,
                endpointSessionId: "missing-session"
            )
        ])

        controller.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 0), "找不到隧道绑定的 SSH/SCP 会话，请重新选择会话端点。")
        XCTAssertFalse(controller.visibleTextSnapshot.contains("missing-session"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("secret"))
    }

    func testCoreTunnelBridgeStartsDynamicSocksRuntimeWithLiveSessionContext() throws {
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let context = TunnelLiveSessionContext(
            config: sshConfig(),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let bridge = CoreBridgeTunnelRuntimeBridge(
            liveSessionContextProvider: { context },
            liveBridge: liveBridge
        )
        let profile = TunnelProfile(
            id: "tun_dynamic_context",
            kind: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1080,
            remoteHost: "socks",
            remotePort: 1080
        )

        let status = try bridge.start(profile: profile)

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_dynamic_context"])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.kind), [.dynamic])
    }

    func testCoreTunnelBridgeStartsRemoteForwardRuntimeWithLiveSessionContext() throws {
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let context = TunnelLiveSessionContext(
            config: sshConfig(),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let bridge = CoreBridgeTunnelRuntimeBridge(
            liveSessionContextProvider: { context },
            liveBridge: liveBridge
        )
        let profile = TunnelProfile(
            id: "tun_remote_context",
            kind: .remote,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "0.0.0.0",
            remotePort: 19000
        )

        let status = try bridge.start(profile: profile)

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_remote_context"])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.kind), [.remote])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.localPort), [15432])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.remotePort), [19000])
    }

    func testRemoteNetworkBrowserStartsDynamicTunnelAndUsesSocksProxy() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 18080 },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()

        XCTAssertEqual(bridge.startedProfiles.map(\.kind), [.dynamic])
        XCTAssertEqual(bridge.startedProfiles.map(\.localHost), ["127.0.0.1"])
        XCTAssertEqual(bridge.startedProfiles.map(\.localPort), [18080])
        XCTAssertEqual(bridge.startedProfiles.map(\.remoteHost), ["socks"])
        XCTAssertEqual(controller.browserPaneViewControllerForTesting?.proxyConfigurationCountForTesting, 1)
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("127.0.0.1:18080"))
    }

    func testRemoteNetworkBrowserStopsDynamicTunnelOnCleanup() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 18080 },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()
        controller.stopRemoteBrowserProxy()
        controller.stopRemoteBrowserProxy()

        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["remote_browser_18080"])
        XCTAssertEqual(bridge.stoppedStates, [.running])
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("已停止"))
    }

    func testRemoteNetworkBrowserKeepsProxyHandleWhenStopFailsSoCleanupCanRetry() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            stopErrors: [
                TunnelRuntimeBridgeError(message: "temporary close failure"),
                nil
            ]
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 18080 },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()
        controller.stopRemoteBrowserProxy()
        controller.stopRemoteBrowserProxy()

        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["remote_browser_18080", "remote_browser_18080"])
        XCTAssertEqual(bridge.stoppedStates, [.running, .running])
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("已停止"))
    }

    func testRemoteNetworkBrowserKeepsProxyHandleWhenStopReturnsMismatchedStatusSoCleanupCanRetry() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            stopStatuses: [
                TunnelRuntimeStatus(
                    profileId: "remote_browser_old",
                    state: .stopped,
                    message: "stale stopped"
                ),
                TunnelRuntimeStatus(
                    profileId: "remote_browser_18080",
                    state: .stopped,
                    message: "stopped"
                )
            ]
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 18080 },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()
        controller.stopRemoteBrowserProxy()
        controller.stopRemoteBrowserProxy()

        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["remote_browser_18080", "remote_browser_18080"])
        XCTAssertEqual(bridge.stoppedStates, [.running, .running])
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("已停止"))
    }

    func testRemoteNetworkBrowserStopsExistingProxyBeforeReloadingView() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        var ports: [UInt16] = [18080, 18081]
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { ports.removeFirst() },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()
        controller.loadView()

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["remote_browser_18080", "remote_browser_18081"])
        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["remote_browser_18080"])
        XCTAssertEqual(bridge.stoppedStates, [.running])
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("127.0.0.1:18081"))
    }

    func testRemoteNetworkBrowserRetiresOldBrowserPaneWhenReloadingView() throws {
        let bridge = RecordingTunnelRuntimeBridge()
        var ports: [UInt16] = [18080, 18081]
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { ports.removeFirst() },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()
        let oldBrowser = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        oldBrowser.loadAddressForTesting("grafana.internal:3000/dashboard")
        XCTAssertEqual(oldBrowser.navigationActionsForTesting, ["load:https://grafana.internal:3000/dashboard"])

        controller.loadView()
        oldBrowser.reloadPage()
        oldBrowser.goBackPage()
        oldBrowser.goForwardPage()
        oldBrowser.loadAddressForTesting("apple.com/design")
        oldBrowser.webView(oldBrowser.webView, didFinish: nil)
        oldBrowser.webView(oldBrowser.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))

        XCTAssertEqual(oldBrowser.navigationActionsForTesting, ["load:https://grafana.internal:3000/dashboard"])
        XCTAssertEqual(oldBrowser.currentURLStringForTesting, "https://grafana.internal:3000/dashboard")
        XCTAssertEqual(oldBrowser.statusTextForTesting, "正在载入：https://grafana.internal:3000/dashboard")
        XCTAssertFalse(controller.browserPaneViewControllerForTesting === oldBrowser)
    }

    func testRemoteNetworkBrowserDoesNotLoadInitialURLWhenProxyStartFails() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            startError: TunnelRuntimeBridgeError(message: "proxy unavailable")
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 18080 },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()

        let browser = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        XCTAssertEqual(browser.proxyConfigurationCountForTesting, 0)
        XCTAssertNil(browser.webView.url)
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("启动失败"))
    }

    func testRemoteNetworkBrowserRejectsMismatchedProxyStartStatusWithoutLoadingInitialURL() throws {
        let bridge = RecordingTunnelRuntimeBridge(
            startStatuses: [
                TunnelRuntimeStatus(
                    profileId: "remote_browser_old",
                    state: .running,
                    message: "stale running"
                )
            ]
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 18080 },
            initialURL: try XCTUnwrap(URL(string: "http://app.internal"))
        )

        controller.loadView()
        controller.stopRemoteBrowserProxy()

        let browser = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["remote_browser_18080"])
        XCTAssertEqual(browser.proxyConfigurationCountForTesting, 0)
        XCTAssertNil(browser.webView.url)
        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), [])
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("状态不匹配"))
        XCTAssertTrue(controller.tunnelStatusTextForTesting.contains("remote_browser_old"))
    }

    func testInspectorTunnelsTabHostsTunnelsController() {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())
        controller.loadView()
        controller.selectTunnelsTab()

        XCTAssertNotNil(controller.tunnelsViewController)
        XCTAssertEqual(controller.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        XCTAssertEqual(controller.selectedTabLabel, "隧道")
        XCTAssertTrue(controller.selectedContentViewControllerForTesting === controller.tunnelsViewController)
    }

    func testInspectorBrowserTabHostsRemoteNetworkBrowserController() {
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            remoteBrowserRuntimeBridge: bridge,
            remoteBrowserLocalPortProvider: { 18081 }
        )
        controller.loadView()
        controller.selectBrowserTab()

        XCTAssertNotNil(controller.remoteBrowserViewController)
        XCTAssertEqual(controller.selectedTabLabel, "浏览器")
        XCTAssertTrue(controller.selectedContentViewControllerForTesting === controller.remoteBrowserViewController)
        XCTAssertEqual(bridge.startedProfiles.map(\.kind), [.dynamic])
        XCTAssertEqual(bridge.startedProfiles.map(\.localPort), [18081])
    }

    func testInspectorBrowserProxyReloadsWhenCurrentTerminalContextChanges() throws {
        var currentContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "first.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:first"
        )
        let liveBridge = RecordingLiveTunnelCoreBridge()
        var ports: [UInt16] = [18083, 18084]
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { currentContext },
            tunnelLiveBridge: liveBridge,
            remoteBrowserLocalPortProvider: { ports.removeFirst() }
        )
        controller.loadView()
        controller.selectBrowserTab()

        currentContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "second.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:second"
        )
        controller.refreshCurrentTerminalContextPanels()

        XCTAssertEqual(liveBridge.startedConfigs.map(\.host), ["first.example.com", "second.example.com"])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["remote_browser_18083", "remote_browser_18084"])
        XCTAssertEqual(liveBridge.expectedFingerprints, ["SHA256:first", "SHA256:second"])
    }

    func testDisconnectingRuntimeStopsRemoteBrowserProxyTunnel() throws {
        let context = TunnelLiveSessionContext(
            config: sshConfig(),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:runtime"
        )
        let bridge = RecordingTunnelRuntimeBridge()
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            remoteBrowserRuntimeBridge: bridge,
            remoteBrowserLocalPortProvider: { 18082 },
            remoteFilesBridge: NoOpRemoteFilesBridge()
        )
        let binding = InspectorViewController.RemoteFilesBinding(
            runtimeID: "runtime-target",
            context: context,
            remotePath: "/srv/app"
        )
        controller.loadView()
        try controller.selectFilesTabAndLoadCurrentDirectory(binding: binding)
        controller.selectBrowserTab()

        XCTAssertEqual(bridge.startedProfiles.map(\.id), ["remote_browser_18082"])

        XCTAssertTrue(controller.disconnectFilesBindingIfNeeded(runtimeID: "runtime-target"))

        XCTAssertEqual(bridge.stoppedProfiles.map(\.id), ["remote_browser_18082"])
        XCTAssertEqual(bridge.stoppedStates, [.running])
        XCTAssertTrue(controller.remoteBrowserViewController?.tunnelStatusTextForTesting.contains("已停止") == true)
    }

    func testInspectorPassesTunnelLiveSessionContextProviderToTunnelsController() throws {
        let context = TunnelLiveSessionContext(
            config: sshConfig(),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            tunnelLiveBridge: liveBridge
        )
        controller.loadView()

        let status = try controller.tunnelsViewControllerForTesting.startForTesting(
            profile: TunnelProfile(
                id: "tun_context_from_inspector",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 18080,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        )

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_context_from_inspector"])
    }

    func testInspectorTunnelsRuntimeStartsFromInjectedEndpointSessionWhenNoCurrentContextExists() throws {
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let contextBuilder = RecordingEndpointTunnelContextBuilder(
            context: TunnelLiveSessionContext(
                config: sshConfig(),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:endpoint"
            )
        )
        let resolver = RecordingTunnelEndpointSessionResolver(
            sessions: [
                savedSession(
                    id: "session_scp",
                    name: "文件入口",
                    protocol: "scp",
                    host: "jump.example.com",
                    port: 2222,
                    credentialID: "password-ref"
                )
            ]
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelProfileStore: RecordingTunnelProfileStore(),
            tunnelLiveBridge: liveBridge,
            tunnelEndpointSessionResolver: resolver,
            tunnelEndpointContextBuilder: contextBuilder,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        controller.loadView()
        controller.selectTunnelsTab()
        controller.tunnelsViewControllerForTesting.setTunnelProfileRecords([
            TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_endpoint_from_inspector",
                    kind: .local,
                    localHost: "127.0.0.1",
                    localPort: 18080,
                    remoteHost: "db.internal",
                    remotePort: 5432
                ),
                sessionId: nil,
                endpointSessionId: "session_scp"
            )
        ])

        controller.tunnelsViewControllerForTesting.performTunnelActionForTesting(at: 0)

        XCTAssertEqual(controller.tunnelsViewControllerForTesting.tableView.viewText(atColumn: 3, row: 0), "运行中")
        XCTAssertEqual(resolver.resolvedSessionIDs, ["session_scp"])
        XCTAssertEqual(contextBuilder.configs.map(\.host), ["jump.example.com"])
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_endpoint_from_inspector"])
        XCTAssertEqual(liveBridge.expectedFingerprints, ["SHA256:endpoint"])
    }

    func testSavedTunnelEndpointInheritsPersistedConnectTimeout() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let endpointSession = try CoreBridge.createSessionRecord(
            databasePath: databaseURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Tunnel endpoint",
                protocol: "ssh",
                host: "jump.example.com",
                port: 2222,
                username: "ops",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: #"{"connectTimeoutMs":45000}"#
            )
        )
        let liveBridge = RecordingLiveTunnelCoreBridge()
        let contextBuilder = RecordingEndpointTunnelContextBuilder()
        let runtimeBridge = CoreBridgeTunnelRuntimeBridge(
            liveBridge: liveBridge,
            endpointSessionResolver: RecordingTunnelEndpointSessionResolver(sessions: [endpointSession]),
            endpointContextBuilder: contextBuilder,
            databasePathProvider: { databaseURL.path }
        )

        _ = try runtimeBridge.start(
            record: TunnelProfileRecord(
                profile: TunnelProfile(
                    id: "tun_saved_timeout",
                    kind: .local,
                    localHost: "127.0.0.1",
                    localPort: 18080,
                    remoteHost: "db.internal",
                    remotePort: 5432
                ),
                sessionId: nil,
                endpointSessionId: endpointSession.id
            )
        )

        XCTAssertEqual(contextBuilder.configs.map(\.connectTimeoutMs), [45_000])
    }
}

private final class RecordingTunnelProfileStore: TunnelProfileStoring {
    var profiles: [TunnelProfile]
    var records: [TunnelProfileRecord]
    var events: [String] = []

    init(profiles: [TunnelProfile] = []) {
        self.profiles = profiles
        self.records = profiles.map { profile in
            TunnelProfileRecord(profile: profile, sessionId: nil, endpointSessionId: nil)
        }
    }

    func listProfiles() throws -> [TunnelProfile] {
        events.append("list")
        return profiles
    }

    func listProfileRecords() throws -> [TunnelProfileRecord] {
        events.append("list")
        return records
    }

    func saveProfile(_ profile: TunnelProfile) throws {
        events.append("save:\(profile.id)")
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        let record = TunnelProfileRecord(profile: profile, sessionId: nil, endpointSessionId: nil)
        if let index = records.firstIndex(where: { $0.profile.id == profile.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    func saveProfileRecord(_ record: TunnelProfileRecord) throws {
        events.append("save:\(record.profile.id)")
        if let index = records.firstIndex(where: { $0.profile.id == record.profile.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        if let index = profiles.firstIndex(where: { $0.id == record.profile.id }) {
            profiles[index] = record.profile
        } else {
            profiles.append(record.profile)
        }
    }

    func deleteProfile(id: String) throws {
        events.append("delete:\(id)")
        profiles.removeAll { $0.id == id }
        records.removeAll { $0.profile.id == id }
    }
}

private final class RecordingTunnelEndpointSessionStore: TunnelEndpointSessionStoring {
    var events: [String] = []
    private let folders: [SessionFolder]
    private let rootSessions: [SessionRecord]
    private let sessionsByFolderID: [String: [SessionRecord]]

    init(
        folders: [SessionFolder] = [],
        rootSessions: [SessionRecord] = [],
        sessionsByFolderID: [String: [SessionRecord]] = [:]
    ) {
        self.folders = folders
        self.rootSessions = rootSessions
        self.sessionsByFolderID = sessionsByFolderID
    }

    func listFolders() throws -> [SessionFolder] {
        events.append("folders")
        return folders
    }

    func listSessions(folderID: String?) throws -> [SessionRecord] {
        events.append("sessions:\(folderID ?? "nil")")
        if let folderID {
            return sessionsByFolderID[folderID] ?? []
        }
        return rootSessions
    }
}

private final class RecordingTunnelProfileEditor: TunnelProfileEditing {
    var events: [String] = []
    var endpointSessionIDs: [[String]] = []
    var endpointSessionTitles: [[String]] = []
    private let createdProfile: TunnelProfile?
    private let editedProfile: TunnelProfile?
    private let endpointSessionID: String?

    init(
        createdProfile: TunnelProfile? = nil,
        editedProfile: TunnelProfile? = nil,
        endpointSessionID: String? = nil
    ) {
        self.createdProfile = createdProfile
        self.editedProfile = editedProfile
        self.endpointSessionID = endpointSessionID
    }

    func makeTunnelProfile(
        existingRecord: TunnelProfileRecord?,
        existingProfiles: [TunnelProfile],
        endpointSessions: [TunnelEndpointSession],
        parentWindow: NSWindow?
    ) -> TunnelProfileEditResult? {
        endpointSessionIDs.append(endpointSessions.map(\.id))
        endpointSessionTitles.append(endpointSessions.map(\.title))
        if let existingRecord {
            events.append("edit:\(existingRecord.profile.id):\(existingProfiles.count)")
            return editedProfile.map { TunnelProfileEditResult(profile: $0, endpointSessionID: endpointSessionID) }
        }
        events.append("create:\(existingProfiles.count)")
        return createdProfile.map { TunnelProfileEditResult(profile: $0, endpointSessionID: endpointSessionID) }
    }
}

private final class RecordingTunnelProfileDeletionConfirmation: TunnelProfileDeletionConfirming {
    var events: [String] = []
    private let shouldDelete: Bool

    init(shouldDelete: Bool) {
        self.shouldDelete = shouldDelete
    }

    func shouldDeleteTunnelProfiles(_ profiles: [TunnelProfile], parentWindow: NSWindow?) -> Bool {
        events.append("delete:\(profiles.map(\.id).joined(separator: ","))")
        return shouldDelete
    }
}

private final class RecordingTunnelRuntimeBridge: TunnelRuntimeBridging {
    var startedProfiles: [TunnelProfile] = []
    var stoppedProfiles: [TunnelProfile] = []
    var stoppedStates: [TunnelState] = []
    var polledProfileIDs: [String] = []
    private let startError: Error?
    private var startErrors: [Error?]
    private var startStatuses: [TunnelRuntimeStatus]
    private var stopErrors: [Error?]
    private var stopStatuses: [TunnelRuntimeStatus]
    private var polledStatuses: [TunnelRuntimeStatus]

    init(
        startError: Error? = nil,
        startErrors: [Error?] = [],
        startStatuses: [TunnelRuntimeStatus] = [],
        stopErrors: [Error?] = [],
        stopStatuses: [TunnelRuntimeStatus] = [],
        polledStatuses: [TunnelRuntimeStatus] = []
    ) {
        self.startError = startError
        self.startErrors = startErrors
        self.startStatuses = startStatuses
        self.stopErrors = stopErrors
        self.stopStatuses = stopStatuses
        self.polledStatuses = polledStatuses
    }

    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        if let startError {
            throw startError
        }
        startedProfiles.append(profile)
        if !startErrors.isEmpty, let error = startErrors.removeFirst() {
            throw error
        }
        if !startStatuses.isEmpty {
            return startStatuses.removeFirst()
        }
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        stoppedProfiles.append(profile)
        stoppedStates.append(state)
        if !stopErrors.isEmpty, let error = stopErrors.removeFirst() {
            throw error
        }
        if !stopStatuses.isEmpty {
            return stopStatuses.removeFirst()
        }
        return TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped")
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        polledProfileIDs.append(profileID)
        if !polledStatuses.isEmpty {
            return polledStatuses.removeFirst()
        }
        return TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }
}

private struct NoOpRemoteFilesBridge: RemoteFilesBridging {
    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        []
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        []
    }

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

private struct TunnelRuntimeBridgeError: Error {
    let message: String
}

private final class RecordingLiveTunnelCoreBridge: LiveTunnelCoreBridging {
    var startedConfigs: [SshConnectionConfig] = []
    var startedProfiles: [TunnelProfile] = []
    var expectedFingerprints: [String] = []

    func checkLocalPortAvailable(_ profile: TunnelProfile) throws {}

    func startLiveLocalTunnelRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        startedConfigs.append(config)
        startedProfiles.append(profile)
        expectedFingerprints.append(expectedFingerprintSHA256)
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func closeLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .stopped, message: "stopped")
    }

    func pollLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stopTunnelRuntime(state: TunnelState) throws -> TunnelState {
        .stopped
    }
}

private final class RecordingTunnelEndpointSessionResolver: TunnelEndpointSessionResolving {
    var resolvedSessionIDs: [String] = []
    private let sessions: [SessionRecord]

    init(sessions: [SessionRecord]) {
        self.sessions = sessions
    }

    func resolveEndpointSession(id: String) throws -> SessionRecord {
        resolvedSessionIDs.append(id)
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw TunnelEndpointSessionResolutionError.missingSession
        }
        return session
    }
}

private final class RecordingEndpointTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    var configs: [SshConnectionConfig] = []
    var databasePaths: [String] = []
    private let context: TunnelLiveSessionContext

    init(
        context: TunnelLiveSessionContext = TunnelLiveSessionContext(
            config: sshConfig(),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
    ) {
        self.context = context
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        configs.append(config)
        databasePaths.append(databasePath)
        return context
    }
}

private func sshConfig() -> SshConnectionConfig {
    SshConnectionConfig(
        host: "example.com",
        port: 22,
        username: "deploy",
        authMethod: .agent,
        connectTimeoutMs: 10_000
    )
}

private func savedSession(
    id: String,
    name: String,
    protocol sessionProtocol: String,
    host: String,
    port: UInt32,
    credentialID: String? = nil
) -> SessionRecord {
    SessionRecord(
        id: id,
        folderId: nil,
        name: name,
        protocol: sessionProtocol,
        host: host,
        port: port,
        username: "ops",
        privateKeyPath: "/Users/me/.ssh/id_ed25519",
        credentialId: credentialID,
        tags: [],
        lastOpenedAt: nil
    )
}

private extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }

        return nil
    }

    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }

        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }

        return nil
    }
}

private extension InspectorViewController {
    var tunnelsViewControllerForTesting: TunnelsViewController {
        tunnelsViewController!
    }
}

@MainActor
private func waitForTunnelTestCondition(
    timeout: TimeInterval = 1,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

private extension TunnelsViewController {
    func startForTesting(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        let mirror = Mirror(reflecting: self)
        guard let bridge = mirror.children.first(where: { $0.label == "runtimeBridge" })?.value as? TunnelRuntimeBridging else {
            XCTFail("missing runtimeBridge")
            return TunnelRuntimeStatus(profileId: profile.id, state: .failed, message: "missing_bridge")
        }
        return try bridge.start(profile: profile)
    }

    func pollTunnelsForTesting() {
        pollActiveTunnels()
    }
}
