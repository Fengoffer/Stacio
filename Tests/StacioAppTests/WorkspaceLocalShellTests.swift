import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class WorkspaceLocalShellTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
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

    func testOpenLocalShellAddsTerminalPane() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        let runtimeID = try workspace.openLocalShell()

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is TerminalPaneViewController)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        let header = workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.\(runtimeID)")
        XCTAssertTrue(header?.isHidden ?? true)
    }

    func testActivateTerminalSelectsPaneForRuntimeID() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        let firstRuntimeID = try workspace.openLocalShell()
        _ = try workspace.openLocalShell()

        XCTAssertTrue(workspace.activateTerminal(runtimeID: firstRuntimeID, bringAppToFront: false))
        XCTAssertEqual((workspace.currentTerminalPane as? TerminalPaneViewController)?.runtimeID, firstRuntimeID)
    }

    func testWorkspaceUsesDocumentContentOnlyLayout() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()

        XCTAssertNotNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.content"))
        XCTAssertNotNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyPrompt"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.commandStrip"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.connectionBar"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.quickConnectTarget"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.commandActions"))
    }

    func testWorkspaceOnlyShowsCoreLaunchActionsInsideEmptyContent() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()

        let localShellButton = workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.localShell") as? NSButton
        let newSessionButton = workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.newSession") as? NSButton
        XCTAssertEqual(localShellButton?.title, "启动本地终端")
        XCTAssertEqual(newSessionButton?.title, "新增会话")
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.import"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.files"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.tunnels"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.multiExec"))
    }

    func testEmptyWorkspaceShowsUsefulQuickStartSurface() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()

        let emptyIcon = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyIcon") as? NSImageView
        )
        let prompt = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyPrompt") as? NSTextField
        )
        let subtitle = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptySubtitle") as? NSTextField
        )

        XCTAssertFalse(emptyIcon.isHidden)
        XCTAssertEqual(emptyIcon.symbolConfiguration, NSImage.SymbolConfiguration(pointSize: 34, weight: .regular))
        XCTAssertEqual(prompt.stringValue, "开始连接")
        XCTAssertEqual(prompt.font, .systemFont(ofSize: 18, weight: .semibold))
        XCTAssertEqual(subtitle.stringValue, "启动一个本地终端，新增会话，或从左侧打开已保存会话。")
        XCTAssertNotNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyQuickStart"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyAction.savedSessions"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyAction.localTerminal"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyAction.import"))
    }

    func testEmptyWorkspaceLocalTerminalActionOpensRealLocalShell() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        let localShellButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.localShell") as? NSButton
        )

        localShellButton.performClick(nil as Any?)

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertTrue(workspace.currentTerminalPane is TerminalPaneViewController)
        XCTAssertTrue(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyPrompt")?.isHidden ?? false)
    }

    func testEmptyWorkspaceNewSessionActionInvokesRealCallback() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        var newSessionRequestCount = 0
        workspace.onRequestNewSession = {
            newSessionRequestCount += 1
        }

        workspace.loadView()
        let newSessionButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.action.newSession") as? NSButton
        )

        newSessionButton.performClick(nil as Any?)

        XCTAssertEqual(newSessionRequestCount, 1)
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testDocumentContentShowsOnlyTerminalAfterOpeningLocalShell() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        let emptyPrompt = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyPrompt")
        )

        try workspace.openLocalShell()

        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.commandStrip"))
        XCTAssertTrue(emptyPrompt.isHidden)
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
    }

    func testTerminalTabsSitInWorkspaceTopStripAndStartFromLeft() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 840, height: 520)
        try workspace.openLocalShell()
        workspace.view.layoutSubtreeIfNeeded()

        let tabController = try XCTUnwrap(workspace.workspaceTabControllerForTesting)
        let tabControl = try XCTUnwrap(tabController.view.allSubviews(ofType: NSSegmentedControl.self).first)
        let terminalView = try XCTUnwrap(workspace.currentTerminalPane?.view)
        let tabControlFrame = tabControl.convert(tabControl.bounds, to: workspace.view)
        let terminalFrame = terminalView.convert(terminalView.bounds, to: workspace.view)

        XCTAssertEqual(tabController.tabStyle, .segmentedControlOnTop)
        XCTAssertLessThanOrEqual(tabControlFrame.minX, workspace.view.bounds.minX + 16)
        XCTAssertGreaterThan(tabControlFrame.minY, terminalFrame.maxY)
        XCTAssertLessThan(terminalFrame.maxY, workspace.view.bounds.maxY - 20)
        XCTAssertEqual(terminalFrame.minX, workspace.view.bounds.minX, accuracy: 1)
        XCTAssertEqual(terminalFrame.width, workspace.view.bounds.width, accuracy: 1)
    }

    func testTabStripPlusButtonAlwaysFollowsTabsAndOpensLocalShell() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 840, height: 520)
        workspace.view.layoutSubtreeIfNeeded()

        let emptyPlusButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.tabs.addLocalTerminal") as? NSSegmentedControl
        )
        XCTAssertTrue(emptyPlusButton.isHidden)
        XCTAssertEqual(emptyPlusButton.segmentCount, 1)
        XCTAssertEqual(emptyPlusButton.label(forSegment: 0), "+")
        XCTAssertEqual(emptyPlusButton.trackingMode, .momentary)
        XCTAssertGreaterThan(emptyPlusButton.frame.width, 0)

        try workspace.openLocalShell()
        workspace.view.layoutSubtreeIfNeeded()

        let tabControl = try XCTUnwrap(
            workspace.workspaceTabControllerForTesting?.view.allSubviews(ofType: NSSegmentedControl.self).first
        )
        let plusButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.tabs.addLocalTerminal") as? NSSegmentedControl
        )
        let tabFrame = tabControl.convert(tabControl.bounds, to: workspace.view)
        let plusFrame = plusButton.convert(plusButton.bounds, to: workspace.view)

        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertFalse(plusButton.isHidden)
        XCTAssertEqual(plusButton.segmentStyle, tabControl.segmentStyle)
        XCTAssertEqual(plusFrame.minX, tabFrame.maxX, accuracy: 8)
        XCTAssertEqual(plusFrame.midY, tabFrame.midY, accuracy: 2)
        XCTAssertEqual(plusFrame.height, tabFrame.height, accuracy: 4)

        XCTAssertTrue(plusButton.sendAction(plusButton.action, to: plusButton.target))

        XCTAssertEqual(workspace.openTerminalPaneCount, 2)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地", "本地"])
        XCTAssertTrue(workspace.currentTerminalPane is TerminalPaneViewController)
    }

    func testHoveredTabCloseButtonClosesThatRealTab() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { sink },
            autoStartTerminalProcesses: false
        )
        let window = NSWindow(contentViewController: workspace)
        defer { window.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 840, height: 520), display: false)

        let firstRuntime = try workspace.openLocalShell()
        _ = try workspace.openLocalShell()
        workspace.view.layoutSubtreeIfNeeded()

        let tabController = try XCTUnwrap(workspace.workspaceTabControllerForTesting)
        let tabControl = try XCTUnwrap(tabController.view.allSubviews(ofType: NSSegmentedControl.self).first)
        let closeButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.tabs.closeHoveredTab") as? NSButton
        )

        XCTAssertTrue(closeButton.isHidden)

        tabController.mouseMoved(with: mouseMovedEvent(overSegment: 0, in: tabControl, window: window))
        workspace.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(closeButton.isHidden)
        XCTAssertEqual(closeButton.accessibilityLabel(), "关闭选项卡")
        let closeFrame = closeButton.convert(closeButton.bounds, to: tabControl)
        XCTAssertGreaterThanOrEqual(closeFrame.minX, 4)
        XCTAssertLessThanOrEqual(closeFrame.minX, 8)
        XCTAssertLessThan(closeFrame.maxX, tabControl.width(forSegment: 0) / 2)

        closeButton.performClick(nil as Any?)

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertEqual(sink.closedRuntimeIDs, [firstRuntime])
    }

    func testHoveredTabCloseButtonStaysPinnedToHoveredTabLeadingEdgeWithLongTitles() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let window = NSWindow(contentViewController: workspace)
        defer { window.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 960, height: 520), display: false)

        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "172.16.10.250"
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "172.16.10.250"
        )
        try workspace.openLocalShell()
        workspace.view.layoutSubtreeIfNeeded()

        let tabController = try XCTUnwrap(workspace.workspaceTabControllerForTesting)
        let tabControl = try XCTUnwrap(tabController.view.allSubviews(ofType: NSSegmentedControl.self).first)
        let closeButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.tabs.closeHoveredTab") as? NSButton
        )

        tabController.mouseMoved(with: mouseMovedEvent(overDisplayedSegment: 1, in: tabControl, window: window))
        workspace.view.layoutSubtreeIfNeeded()

        let closeFrame = closeButton.convert(closeButton.bounds, to: tabControl)
        let segmentLeading = tabControl.width(forSegment: 0)
        let segmentWidth = tabControl.width(forSegment: 1)
        let title = tabControl.label(forSegment: 1) ?? ""
        let titleWidth = title.size(withAttributes: [.font: tabControl.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        let centeredTitleMinX = segmentLeading + max(0, (segmentWidth - titleWidth) / 2)

        XCTAssertEqual(closeFrame.minX, segmentLeading + 5, accuracy: 3)
        XCTAssertLessThanOrEqual(closeFrame.maxX + 4, centeredTitleMinX)
    }

    func testOpenRemoteShellAddsRemoteTerminalPane() {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let status = LiveShellStatus(
            runtimeId: "term_remote",
            status: "running",
            diagnostic: "running"
        )

        workspace.loadView()
        workspace.openRemoteShell(status: status, title: "deploy@example.com")

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is RemoteTerminalPaneViewController)
        XCTAssertEqual((workspace.currentTerminalPane as? RemoteTerminalPaneViewController)?.runtimeID, "term_remote")
        XCTAssertEqual(workspace.currentTerminalPane?.title, "deploy@example.com")
    }

    func testSSHRemoteShellUsesDefaultTabIconBeforeOSModeSwitch() throws {
        let suiteName = "StacioWorkspaceTabDefaultIconTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.sessionTabIconMode = .defaultIcon
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            remoteOSProbe: { _ in
                RemoteOperatingSystemInfo(
                    id: "ubuntu",
                    idLike: ["debian"],
                    name: "Ubuntu",
                    prettyName: "Ubuntu 22.04 LTS",
                    version: "22.04 LTS",
                    versionId: "22.04",
                    kernelName: "Linux",
                    kernelRelease: "5.15.0",
                    architecture: "x86_64"
                )
            },
            settingsStore: store
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_icon_default", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "example.com")
        )
        XCTAssertTrue(waitUntil { workspace.tabImageAccessibilityDescriptionForTesting(index: 0) == "SSH" })

        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "ssh-default")
        XCTAssertEqual(workspace.tabImageAccessibilityDescriptionForTesting(index: 0), "SSH")
    }

    func testSSHRemoteShellSwitchesToDetectedOperatingSystemTabIcon() throws {
        let suiteName = "StacioWorkspaceTabOSIconTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.sessionTabIconMode = .operatingSystem
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            remoteOSProbe: { _ in
                return RemoteOperatingSystemInfo(
                    id: "centos",
                    idLike: ["rhel", "fedora"],
                    name: "CentOS Linux",
                    prettyName: "CentOS Linux 7 (Core)",
                    version: "7 (Core)",
                    versionId: "7",
                    kernelName: "Linux",
                    kernelRelease: "3.10.0-1160.el7.x86_64",
                    architecture: "x86_64"
                )
            },
            settingsStore: store
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_icon_os", status: "running", diagnostic: "running"),
            title: "root@centos7.example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "centos7.example.com")
        )

        XCTAssertTrue(waitUntil { workspace.tabIconIdentifierForTesting(index: 0) == "centos" })
        XCTAssertEqual(workspace.tabImageAccessibilityDescriptionForTesting(index: 0), "CentOS Linux 7 (Core) 7")
    }

    func testChangingSessionTabIconModeRefreshesExistingSSHTabIcon() throws {
        let suiteName = "StacioWorkspaceTabIconModeRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.sessionTabIconMode = .defaultIcon
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            remoteOSProbe: { _ in
                RemoteOperatingSystemInfo(
                    id: "ubuntu",
                    idLike: ["debian"],
                    name: "Ubuntu",
                    prettyName: "Ubuntu 24.04 LTS",
                    version: "24.04 LTS",
                    versionId: "24.04",
                    kernelName: "Linux",
                    kernelRelease: "6.8.0",
                    architecture: "aarch64"
                )
            },
            settingsStore: store
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_icon_refresh", status: "running", diagnostic: "running"),
            title: "deploy@ubuntu.example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "ubuntu.example.com")
        )
        XCTAssertTrue(waitUntil { workspace.tabImageAccessibilityDescriptionForTesting(index: 0) == "SSH" })

        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "ssh-default")
        store.update { settings in
            settings.sessionTabIconMode = .operatingSystem
        }

        XCTAssertTrue(waitUntil { workspace.tabIconIdentifierForTesting(index: 0) == "ubuntu" })
        XCTAssertTrue(workspace.tabImageAccessibilityDescriptionForTesting(index: 0)?.contains("Ubuntu 24.04 LTS") ?? false)
    }

    func testOpenConnectingRemoteShellAddsPendingTerminalTabImmediately() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        let pane = workspace.openConnectingRemoteShell(
            title: "deploy@example.com",
            reconnecter: nil,
            connectionKind: .ssh,
            liveSessionContext: nil
        )

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(pane.runtimeID.hasPrefix("pending_"))
        XCTAssertTrue((workspace.currentTerminalPane as? RemoteTerminalPaneViewController) === pane)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["deploy@example.com"])
        XCTAssertEqual(pane.lifecycleState, .connecting)
        XCTAssertEqual(pane.lifecycleMessageForTesting, "正在连接...")
        XCTAssertEqual(pane.terminalOutputTranscript, "")
        XCTAssertFalse(pane.terminalOutputTranscript.contains("正在连接 deploy@example.com"))
    }

    func testOpenRemoteShellTracksLiveSessionContextForSelectedPane() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first.example.com",
            liveSessionContext: liveContext(host: "first.example.com")
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second.example.com",
            liveSessionContext: liveContext(host: "second.example.com")
        )

        XCTAssertEqual(workspace.currentRemoteTerminalLiveSessionContext?.config.host, "second.example.com")
        workspace.selectTabForTesting(0)
        XCTAssertEqual(workspace.currentRemoteTerminalLiveSessionContext?.config.host, "first.example.com")
    }

    func testOpenSSHRemoteShellShowsCurrentTabFloatingDeviceDashboardByDefault() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { context in
                RecordingWorkspaceDeviceMetricsProvider(hosts: [context.config.host])
            },
            startsDeviceMetricsPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_metrics", status: "running", diagnostic: "running"),
            title: "root@172.16.10.250",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "172.16.10.250")
        )

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is RemoteTerminalPaneViewController)
        XCTAssertNotNil(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_metrics"))
        XCTAssertEqual(workspace.currentDeviceMetricsDashboardTitleForTesting, "root@172.16.10.250")
        XCTAssertTrue(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertEqual(workspace.currentSplitPaneMinimumThicknessesForTesting, [0])
        XCTAssertEqual(workspace.currentTerminalReservedTrailingWidthForTesting, 0)
    }

    func testOpenSSHRemoteShellOverlaysFloatingDashboardWithoutShrinkingTerminal() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { context in
                RecordingWorkspaceDeviceMetricsProvider(hosts: [context.config.host])
            },
            startsDeviceMetricsPollingAutomatically: false
        )

        workspace.loadView()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_metrics", status: "running", diagnostic: "running"),
            title: "root@172.16.10.250",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "172.16.10.250")
        )
        workspace.view.layoutSubtreeIfNeeded()

        let terminalView = try XCTUnwrap((workspace.currentTerminalPane as? RemoteTerminalPaneViewController)?.view)
        let dashboardView = try XCTUnwrap(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_metrics"))

        XCTAssertEqual(terminalView.frame.width, workspace.view.bounds.width, accuracy: 1)
        XCTAssertEqual(dashboardView.frame.width, 360, accuracy: 1)
        XCTAssertGreaterThan(dashboardView.frame.minX, terminalView.frame.midX)
        XCTAssertTrue(dashboardView.frame.intersects(terminalView.frame))
        XCTAssertEqual(workspace.currentTerminalReservedTrailingWidthForTesting, 0)
    }

    func testFloatingDeviceDashboardHidesWhenWorkspaceHasNoInsetSafeWidth() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { context in
                RecordingWorkspaceDeviceMetricsProvider(hosts: [context.config.host])
            },
            startsDeviceMetricsPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_metrics_narrow", status: "running", diagnostic: "running"),
            title: "root@172.16.10.250",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "172.16.10.250")
        )
        let dashboardView = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_metrics_narrow")
        )
        let dashboardContainer = try XCTUnwrap(dashboardView.superview)
        dashboardContainer.bounds = NSRect(x: 0, y: 0, width: 16, height: 560)
        try XCTUnwrap(dashboardContainer.nextResponder as? NSViewController).viewDidLayout()

        let dashboardFrame = try XCTUnwrap(workspace.currentDeviceMetricsDashboardFrameForTesting)
        let containerBounds = try XCTUnwrap(workspace.currentDeviceMetricsDashboardContainerBoundsForTesting)

        XCTAssertEqual(containerBounds.width, 16, accuracy: 0.5)
        XCTAssertFalse(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertEqual(dashboardFrame, .zero)
        XCTAssertLessThanOrEqual(dashboardFrame.maxX, containerBounds.maxX)
        XCTAssertLessThanOrEqual(dashboardFrame.maxY, containerBounds.maxY)
    }

    func testFloatingDeviceDashboardHeightFitsContentInsteadOfFillingWorkspace() throws {
        let metricsSnapshot = DeviceMetricsDisplaySnapshot(
            cpuUsage: 0.22,
            memory: DeviceMemoryDisplayUsage(usedBytes: 7_100_000_000, totalBytes: 10_800_000_000),
            networks: [
                DeviceNetworkDisplayRate(interfaceName: "eth0", receiveBytesPerSecond: 3_000_000, transmitBytesPerSecond: 800_000)
            ],
            disks: [
                DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 38_000_000_000, totalBytes: 80_000_000_000),
                DeviceDiskDisplayUsage(mountPath: "/data", usedBytes: 120_000_000_000, totalBytes: 200_000_000_000)
            ]
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { _ in
                RecordingWorkspaceDeviceMetricsProvider(snapshot: metricsSnapshot)
            },
            startsDeviceMetricsPollingAutomatically: false
        )

        workspace.loadView()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 720)
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_metrics", status: "running", diagnostic: "running"),
            title: "root@172.16.10.250",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "172.16.10.250")
        )
        workspace.view.layoutSubtreeIfNeeded()

        workspace.refreshCurrentDeviceMetricsDashboardForTesting()
        workspace.view.layoutSubtreeIfNeeded()

        let dashboardFrame = try XCTUnwrap(workspace.currentDeviceMetricsDashboardFrameForTesting)
        let dashboardContainerBounds = try XCTUnwrap(workspace.currentDeviceMetricsDashboardContainerBoundsForTesting)
        XCTAssertEqual(dashboardFrame.width, 360, accuracy: 1)
        XCTAssertGreaterThan(dashboardFrame.height, 330)
        XCTAssertLessThan(dashboardFrame.height, dashboardContainerBounds.height - 160)
        XCTAssertEqual(dashboardFrame.maxY, dashboardContainerBounds.maxY - 16, accuracy: 1)
        let dashboardView = try XCTUnwrap(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_metrics"))
        let scrollView = try XCTUnwrap(dashboardView.firstSubview(withIdentifier: "Stacio.Metrics.scrollView") as? NSScrollView)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertEqual(workspace.currentTerminalReservedTrailingWidthForTesting, 0)
    }

    func testDeviceDashboardToggleOnlyAffectsCurrentSSHTab() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { context in
                RecordingWorkspaceDeviceMetricsProvider(hosts: [context.config.host])
            },
            startsDeviceMetricsPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first@example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "first.example.com")
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second@example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "second.example.com")
        )

        XCTAssertNotNil(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_second"))
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_first"))

        workspace.toggleDeviceMetricsDashboardVisibility()
        XCTAssertFalse(workspace.isDeviceMetricsDashboardEnabled)
        XCTAssertFalse(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertNil(workspace.currentDeviceMetricsDashboardTitleForTesting)

        workspace.selectTabForTesting(0)
        XCTAssertFalse(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertNil(workspace.currentDeviceMetricsDashboardTitleForTesting)

        workspace.toggleDeviceMetricsDashboardVisibility()
        XCTAssertTrue(workspace.isDeviceMetricsDashboardEnabled)
        XCTAssertTrue(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertEqual(workspace.currentDeviceMetricsDashboardTitleForTesting, "first@example.com")
    }

    func testDeviceMetricsAlertNotificationActivationSelectsDashboardSession() throws {
        let notifier = RecordingWorkspaceDeviceMetricsAlertNotifier()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { context in
                RecordingWorkspaceDeviceMetricsProvider(hosts: [context.config.host])
            },
            startsDeviceMetricsPollingAutomatically: false,
            deviceMetricsAlertNotifier: notifier
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first@example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "first.example.com")
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second@example.com",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "second.example.com")
        )

        XCTAssertEqual(workspace.currentDeviceMetricsDashboardTitleForTesting, "second@example.com")

        notifier.activate(runtimeID: "term_first")

        XCTAssertEqual(workspace.currentDeviceMetricsDashboardTitleForTesting, "first@example.com")
        XCTAssertTrue(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
    }

    func testDeviceDashboardIsHiddenForSplitAndMultiExecWorkspaces() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { context in
                RecordingWorkspaceDeviceMetricsProvider(hosts: [context.config.host])
            },
            startsDeviceMetricsPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "prod.example.com")
        )
        XCTAssertNotNil(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_ssh"))

        try workspace.splitCurrentTerminal()
        XCTAssertFalse(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertNil(workspace.currentDeviceMetricsDashboardTitleForTesting)
        XCTAssertEqual(workspace.currentTerminalReservedTrailingWidthForTesting, 0)

        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])

        XCTAssertTrue(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertNil(workspace.view.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.term_ssh"))
        XCTAssertNil(workspace.currentDeviceMetricsDashboardTitleForTesting)
    }

    func testSplitTerminalAddsPaneHeaderWithTerminalTitle() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        let firstRuntimeID = try workspace.openLocalShell()
        try workspace.splitCurrentTerminal()
        let secondRuntimeID = try XCTUnwrap((workspace.currentTerminalPane as? TerminalPaneViewController)?.runtimeID)
        workspace.view.layoutSubtreeIfNeeded()

        let firstHeader = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.\(firstRuntimeID)")
        )
        let secondHeader = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.\(secondRuntimeID)")
        )
        let firstTitle = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.title.\(firstRuntimeID)") as? NSTextField
        )
        let secondTitle = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.title.\(secondRuntimeID)") as? NSTextField
        )

        XCTAssertFalse(firstHeader.isHidden)
        XCTAssertFalse(secondHeader.isHidden)
        XCTAssertEqual(firstTitle.stringValue, "本地")
        XCTAssertEqual(secondTitle.stringValue, "本地")
    }

    func testWorkspaceChromeRefreshesResolvedColorsWhenAppearanceChanges() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        let firstRuntimeID = try workspace.openLocalShell()
        try workspace.splitCurrentTerminal()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 840, height: 520)
        workspace.view.layoutSubtreeIfNeeded()

        let header = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.\(firstRuntimeID)")
        )
        let title = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.title.\(firstRuntimeID)") as? NSTextField
        )
        let closeButton = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.tabs.closeHoveredTab") as? NSButton
        )

        workspace.view.appearance = NSAppearance(named: .darkAqua)
        workspace.refreshWorkspaceAppearanceForTesting()
        let darkHeaderColor = try XCTUnwrap(header.layer?.backgroundColor)
        let darkTitleColor = try XCTUnwrap(title.textColor)
        let darkCloseColor = try XCTUnwrap(closeButton.contentTintColor)

        workspace.view.appearance = NSAppearance(named: .aqua)
        workspace.refreshWorkspaceAppearanceForTesting()
        let lightHeaderColor = try XCTUnwrap(header.layer?.backgroundColor)
        let lightTitleColor = try XCTUnwrap(title.textColor)
        let lightCloseColor = try XCTUnwrap(closeButton.contentTintColor)

        XCTAssertNotEqual(darkHeaderColor, lightHeaderColor)
        XCTAssertEqual(
            lightHeaderColor,
            StacioDesignSystem.resolvedLayerColor(
                StacioDesignSystem.dynamicColor(.windowBackgroundColor, alpha: 0.96),
                for: header
            )
        )
        XCTAssertEqual(lightTitleColor, StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: workspace.view))
        XCTAssertEqual(lightCloseColor, StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: workspace.view))
        XCTAssertNotEqual(darkTitleColor, lightTitleColor)
        XCTAssertNotEqual(darkCloseColor, lightCloseColor)
    }

    func testCurrentRemoteFilesPaneProvidesItsOwnLiveContextAndDirectory() throws {
        let bridge = RecordingWorkspaceRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/var/log/app.log", size: 12, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        _ = try workspace.openRemoteFilesSession(
            context: liveContext(host: "files-one.example.com"),
            title: "第一台文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/var/log"
        )
        _ = try workspace.openRemoteFilesSession(
            context: liveContext(host: "files-two.example.com"),
            title: "第二台文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/app"
        )

        XCTAssertEqual(workspace.currentRemoteTerminalLiveSessionContext?.config.host, "files-two.example.com")
        XCTAssertEqual(workspace.currentRemoteTerminalDirectory, "/srv/app")

        workspace.selectTabForTesting(0)

        XCTAssertEqual(workspace.currentRemoteTerminalLiveSessionContext?.config.host, "files-one.example.com")
        XCTAssertEqual(workspace.currentRemoteTerminalDirectory, "/var/log")
    }

    func testOpenSSHRemoteShellDisplaysTruthfulStartupSummaryFromLiveContext() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running"),
            title: "FengLee@192.168.124.100",
            liveSessionContext: liveContext(host: "192.168.124.100")
        )

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.loadView()

        let transcript = pane.terminalOutputTranscript
        XCTAssertEqual(transcript, "")
    }

    func testOpenBrowserSessionAddsNativeBrowserPane() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        let runtimeID = try workspace.openBrowserSession(urlString: "https://example.com", title: "Docs")

        XCTAssertTrue(runtimeID.hasPrefix("browser_"))
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is BrowserPaneViewController)
        XCTAssertEqual(workspace.currentTerminalPane?.title, "Docs")
        XCTAssertEqual(workspace.tabLabelsForTesting, ["Docs"])
    }

    func testOpenBrowserSessionExposesChineseStateAndNavigationActionsWithoutNetwork() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        _ = try workspace.openBrowserSession(urlString: "example.com/docs", title: "Docs")

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? BrowserPaneViewController)
        XCTAssertEqual(pane.currentURLStringForTesting, "https://example.com/docs")
        XCTAssertEqual(pane.addressFieldValueForTesting, "https://example.com/docs")
        XCTAssertEqual(pane.statusTextForTesting, "准备载入：https://example.com/docs")
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("failed"))
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("error"))

        pane.loadAddressForTesting("apple.com/design")
        XCTAssertEqual(pane.currentURLStringForTesting, "https://apple.com/design")
        XCTAssertEqual(pane.addressFieldValueForTesting, "https://apple.com/design")
        XCTAssertEqual(pane.navigationActionsForTesting, ["load:https://apple.com/design"])

        pane.setLoadingStateForTesting(isLoading: true)
        XCTAssertEqual(pane.statusTextForTesting, "正在载入：https://apple.com/design")

        pane.showErrorForTesting("网络连接中断")
        XCTAssertEqual(pane.statusTextForTesting, "载入失败：网络连接中断")
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("fallback"))
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("failed"))

        pane.reloadPage()
        pane.goBackPage()
        pane.goForwardPage()
        XCTAssertEqual(pane.navigationActionsForTesting, ["load:https://apple.com/design", "reload", "back", "forward"])
        XCTAssertEqual(pane.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(pane.view.layer?.backgroundColor, StacioDesignSystem.theme.workspaceBackgroundColor.cgColor)
    }

    func testOpenBrowserSessionAcceptsLocalhostPortWithoutScheme() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        _ = try workspace.openBrowserSession(urlString: "localhost:3000", title: "Local App")

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? BrowserPaneViewController)
        XCTAssertEqual(pane.currentURLStringForTesting, "http://localhost:3000")
        XCTAssertEqual(pane.addressFieldValueForTesting, "http://localhost:3000")
    }

    func testBrowserAddressBarAcceptsHostPortWithoutScheme() throws {
        let pane = BrowserPaneViewController(
            runtimeID: "browser_test",
            url: try XCTUnwrap(URL(string: "https://example.com")),
            title: "Docs"
        )

        pane.loadView()
        pane.loadAddressForTesting("grafana.internal:3000/dashboard")

        XCTAssertEqual(pane.currentURLStringForTesting, "https://grafana.internal:3000/dashboard")
        XCTAssertEqual(pane.addressFieldValueForTesting, "https://grafana.internal:3000/dashboard")
        XCTAssertEqual(pane.navigationActionsForTesting, ["load:https://grafana.internal:3000/dashboard"])
    }

    func testBrowserPaneIgnoresNavigationCommandsAndCallbacksAfterRemoval() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        _ = try workspace.openBrowserSession(urlString: "https://example.com", title: "Docs")
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? BrowserPaneViewController)
        pane.loadAddressForTesting("grafana.internal:3000/dashboard")
        XCTAssertEqual(pane.navigationActionsForTesting, ["load:https://grafana.internal:3000/dashboard"])

        workspace.closeCurrentTerminal()
        pane.reloadPage()
        pane.goBackPage()
        pane.goForwardPage()
        pane.loadAddressForTesting("apple.com/design")
        pane.webView(pane.webView, didFinish: nil)
        pane.webView(pane.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))

        XCTAssertEqual(pane.navigationActionsForTesting, ["load:https://grafana.internal:3000/dashboard"])
        XCTAssertEqual(pane.currentURLStringForTesting, "https://grafana.internal:3000/dashboard")
        XCTAssertEqual(pane.statusTextForTesting, "正在载入：https://grafana.internal:3000/dashboard")
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testBrowserSessionRejectsNonHTTPURLSchemes() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()

        for urlString in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>"
        ] {
            XCTAssertThrowsError(try workspace.openBrowserSession(urlString: urlString, title: "Docs"))
        }
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testBrowserAddressBarRejectsNonHTTPURLSchemes() throws {
        let pane = BrowserPaneViewController(
            runtimeID: "browser_test",
            url: try XCTUnwrap(URL(string: "https://example.com")),
            title: "Docs"
        )

        pane.loadView()

        for urlString in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>"
        ] {
            pane.loadAddressForTesting(urlString)
            XCTAssertEqual(pane.currentURLStringForTesting, "https://example.com")
            XCTAssertEqual(pane.statusTextForTesting, "载入失败：地址无效")
            XCTAssertEqual(pane.navigationActionsForTesting, [])
        }
    }

    func testOpenFileSessionAddsNativeFilePane() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        let runtimeID = try workspace.openFileSession(path: NSTemporaryDirectory(), title: "临时文件")

        XCTAssertTrue(runtimeID.hasPrefix("file_"))
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is LocalFilePaneViewController)
        XCTAssertEqual(workspace.currentTerminalPane?.title, "临时文件")
        XCTAssertEqual(workspace.tabLabelsForTesting, ["临时文件"])
    }

    func testOpenFileSessionKeepsMissingPathInNativePaneWithChineseErrorState() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let missingPath = NSTemporaryDirectory() + "stacio-workspace-missing-\(UUID().uuidString)"

        workspace.loadView()
        let runtimeID = try workspace.openFileSession(path: missingPath, title: "缺失目录")

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? LocalFilePaneViewController)
        pane.loadView()

        XCTAssertTrue(runtimeID.hasPrefix("file_"))
        XCTAssertEqual(pane.currentPathForTesting, missingPath)
        XCTAssertEqual(pane.statusTextForTesting, "本地路径不存在：\(missingPath)")
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("invalid"))
    }

    func testLocalFilePaneShowsChineseErrorForMissingPathAndKeepsRefreshRevealOpenStateTestable() throws {
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stacio-missing-\(UUID().uuidString)", isDirectory: true)
        let pane = LocalFilePaneViewController(
            runtimeID: "file_missing",
            directoryURL: missingURL,
            title: "缺失目录"
        )

        pane.loadView()

        XCTAssertEqual(pane.statusTextForTesting, "本地路径不存在：\(missingURL.path)")
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("本地路径不存在"))
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("permission denied"))
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("no such file"))
        XCTAssertEqual(pane.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertFalse(pane.tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(pane.tableView.backgroundColor, .clear)

        pane.refreshDirectory()
        pane.revealCurrentPath()
        pane.openCurrentPath()

        XCTAssertEqual(pane.fileActionsForTesting, ["refresh", "reveal", "open"])
        XCTAssertEqual(pane.currentPathForTesting, missingURL.path)
    }

    func testLocalFilePaneShowsChineseErrorForUnreadablePath() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stacio-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tempRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempRoot.path)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let pane = LocalFilePaneViewController(
            runtimeID: "file_denied",
            directoryURL: tempRoot,
            title: "无权限目录"
        )

        pane.loadView()

        XCTAssertEqual(pane.statusTextForTesting, "没有权限读取本地路径：\(tempRoot.path)")
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("没有权限读取本地路径"))
        XCTAssertFalse(pane.statusTextForTesting.localizedCaseInsensitiveContains("permission denied"))
    }

    func testLocalFilePaneShowsHiddenItemsFoldersThenFilesWithMacIcons() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stacio-local-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try "secret\n".write(to: tempRoot.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(".config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let readmeURL = tempRoot.appendingPathComponent("README.md")
        let readmeModificationDate = Date(timeIntervalSince1970: 1_704_067_440)
        try "hello\n".write(to: readmeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: readmeModificationDate], ofItemAtPath: readmeURL.path)
        let pane = LocalFilePaneViewController(
            runtimeID: "file_sorted",
            directoryURL: tempRoot,
            title: "本地文件"
        )

        pane.loadView()

        XCTAssertEqual(pane.tableView.tableColumns.map(\.title), ["名称", "大小", "时间"])
        XCTAssertGreaterThanOrEqual(pane.tableView.rowHeight, 34)
        XCTAssertEqual(pane.tableView.viewText(atColumn: 0, row: 0), ".config")
        XCTAssertEqual(pane.tableView.viewText(atColumn: 0, row: 1), ".zprofile")
        XCTAssertEqual(pane.tableView.viewText(atColumn: 0, row: 2), "logs")
        XCTAssertEqual(pane.tableView.viewText(atColumn: 0, row: 3), "README.md")
        XCTAssertEqual(pane.tableView.viewText(atColumn: 1, row: 3), "0.01 KB")
        XCTAssertEqual(pane.tableView.viewText(atColumn: 2, row: 3), StacioFileDisplay.timeText(for: readmeModificationDate))
        XCTAssertEqual(pane.tableView.viewIconLabel(atColumn: 0, row: 0), "文件夹图标")
        XCTAssertEqual(pane.tableView.viewIconLabel(atColumn: 0, row: 3), "MD 文件图标")
        XCTAssertNotNil((pane.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.imageView?.image)
        XCTAssertGreaterThanOrEqual(pane.tableView.viewIconSize(atColumn: 0, row: 3)?.width ?? 0, 28)
    }

    func testOpenRemoteFilesSessionAddsSCPFilesPaneAndLoadsDirectory() throws {
        let bridge = RecordingWorkspaceRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "files.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:files"
        )

        workspace.loadView()
        let runtimeID = try workspace.openRemoteFilesSession(
            context: context,
            title: "文件服务器",
            bridge: bridge,
            transferScheduler: nil
        )

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteFilesPaneViewController)
        XCTAssertTrue(runtimeID.hasPrefix("scp_"))
        XCTAssertEqual(pane.runtimeID, runtimeID)
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertEqual(workspace.currentTerminalPane?.title, "文件服务器")
        XCTAssertEqual(workspace.tabLabelsForTesting, ["文件服务器"])
        XCTAssertEqual(bridge.liveHosts, ["files.example.com"])
        XCTAssertEqual(pane.visibleTextSnapshotForTesting, "文件\n/home/deploy\napp.log\n0.06 KB\n—\n—\n-")
    }

    func testClosingRemoteFilesSessionDisconnectsRuntimeScopedTransfers() throws {
        let bridge = RecordingWorkspaceRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let scheduler = RecordingWorkspaceSCPTransferScheduler()
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "files.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:files"
        )

        workspace.loadView()
        let runtimeID = try workspace.openRemoteFilesSession(
            context: context,
            title: "文件服务器",
            bridge: bridge,
            transferScheduler: scheduler
        )
        workspace.closeCurrentTerminal()

        XCTAssertEqual(scheduler.disconnectedRuntimeIDs, [runtimeID])
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testOpenFTPFilesSessionAddsFTPFilesPaneAndUsesFTPEngineLabel() throws {
        let bridge = RecordingWorkspaceRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/pub/readme.txt", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let context = FTPLiveSessionContext(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-password")
        )

        workspace.loadView()
        let runtimeID = try workspace.openFTPFilesSession(
            context: context,
            title: "FTP 文件",
            bridge: bridge
        )

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteFilesPaneViewController)
        XCTAssertTrue(runtimeID.hasPrefix("ftp_"))
        XCTAssertEqual(pane.runtimeID, runtimeID)
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertEqual(workspace.currentTerminalPane?.title, "FTP 文件")
        XCTAssertEqual(workspace.tabLabelsForTesting, ["FTP 文件"])
        XCTAssertEqual(bridge.ftpHosts, ["ftp.example.com"])
        XCTAssertEqual(pane.visibleTextSnapshotForTesting, "文件\n内置 FTP\n/pub\nreadme.txt\n0.06 KB\n—\n—\n-")
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("SFTP"))
    }

    func testClosingFTPFilesSessionDisconnectsRuntimeScopedTransfers() throws {
        let bridge = RecordingWorkspaceRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/pub/readme.txt", size: 64, linkTarget: nil)
        ])
        let scheduler = RecordingWorkspaceFTPTransferScheduler()
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let context = FTPLiveSessionContext(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-password")
        )

        workspace.loadView()
        let runtimeID = try workspace.openFTPFilesSession(
            context: context,
            title: "FTP 文件",
            bridge: bridge,
            ftpTransferScheduler: scheduler
        )
        workspace.closeCurrentTerminal()

        XCTAssertEqual(scheduler.disconnectedRuntimeIDs, [runtimeID])
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testOpenGraphicsSessionAddsNativeGraphicsDiagnosticPane() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "windows.example.com",
            port: 5900,
            adapterPath: nil,
            launchArguments: [],
            status: "缺少 Stacio 打包的 VNC 适配器"
        )

        workspace.loadView()
        let runtimeID = workspace.openGraphicsSession(
            title: "Windows 桌面",
            diagnostic: diagnostic
        )

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)
        XCTAssertTrue(runtimeID.hasPrefix("graphics_"))
        XCTAssertEqual(pane.runtimeID, runtimeID)
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertEqual(workspace.currentTerminalPane?.title, "Windows 桌面")
        XCTAssertEqual(workspace.tabLabelsForTesting, ["Windows 桌面"])
        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "vnc-default")
        XCTAssertEqual(workspace.tabImageAccessibilityDescriptionForTesting(index: 0), "VNC 远程桌面")
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("图形会话"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("内置 VNC 适配器"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("windows.example.com:5900"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("无法启动"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("运行状态"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("连接目标"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("适配器路径"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("缺少 Stacio 打包的 VNC 适配器"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("adapter"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("SFTP"))
        XCTAssertEqual(pane.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(pane.view.layer?.backgroundColor, StacioDesignSystem.theme.workspaceBackgroundColor.cgColor)

        pane.copyDiagnosticSummary()
        XCTAssertTrue(pane.copiedDiagnosticSummaryForTesting.contains("VNC"))
        XCTAssertTrue(pane.copiedDiagnosticSummaryForTesting.contains("windows.example.com:5900"))
    }

    func testOpenGraphicsSessionHostsEmbeddedGraphicsSurfaceAndRoutesInput() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let embeddedSession = RecordingWorkspaceEmbeddedGraphicsSession()
        let attachment = GraphicsRuntimeAttachment(
            runtimeID: "graphics_embedded_vnc",
            kind: .embeddedGraphics,
            session: embeddedSession
        )
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "windows.example.com",
            port: 5900,
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            launchArguments: ["windows.example.com:5900"],
            status: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
        )

        workspace.loadView()
        let runtimeID = workspace.openGraphicsSession(
            title: "Windows 桌面",
            diagnostic: diagnostic,
            runtimeID: "graphics_embedded_vnc",
            attachment: attachment
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)

        XCTAssertEqual(runtimeID, "graphics_embedded_vnc")
        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "vnc-default")
        XCTAssertEqual(workspace.tabImageAccessibilityDescriptionForTesting(index: 0), "VNC 远程桌面")
        XCTAssertTrue(pane.hasEmbeddedRenderSurfaceForTesting)
        XCTAssertFalse(pane.hasVisibleDiagnosticChromeForTesting)
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("图形会话"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("Stacio 图形标签页"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("外部客户端"))
        pane.view.setFrameSize(NSSize(width: 800, height: 600))
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.renderSurfaceFrameForTesting, pane.view.bounds)

        let pixels = Data([
            0x00, 0x00, 0xFF, 0xFF,
            0x00, 0xFF, 0x00, 0xFF
        ])
        embeddedSession.emit(
            GraphicsFrame(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelFormat: .bgra8Unorm,
                pixels: pixels
            )
        )

        XCTAssertEqual(pane.renderedFrameSizeForTesting, CGSize(width: 2, height: 1))
        XCTAssertTrue(pane.hasRenderedImageForTesting)
        embeddedSession.emitPointerPosition(x: 1, y: 0)
        XCTAssertEqual(
            pane.remotePointerPositionForTesting,
            CGPoint(x: try XCTUnwrap(pane.renderSurfaceFrameForTesting).midX, y: 0)
        )
        XCTAssertTrue(pane.isRemotePointerVisibleForTesting)
        embeddedSession.emitPointerVisibilityChanged(false)
        XCTAssertFalse(pane.isRemotePointerVisibleForTesting)
        embeddedSession.emitPointerBitmap(
            GraphicsPointerBitmap(
                width: 2,
                height: 1,
                hotspotX: 1,
                hotspotY: 0,
                rgbaPixels: Data([255, 0, 0, 255, 0, 255, 0, 128])
            )
        )
        XCTAssertTrue(pane.isRemotePointerVisibleForTesting)
        XCTAssertEqual(pane.remotePointerBitmapSizeForTesting, CGSize(width: 2, height: 1))
        XCTAssertEqual(pane.remotePointerAnchorPointForTesting, CGPoint(x: 0.5, y: 0))
        embeddedSession.emitPointerVisibilityChanged(true)
        XCTAssertTrue(pane.isRemotePointerVisibleForTesting)
        XCTAssertNil(pane.remotePointerBitmapSizeForTesting)
        XCTAssertNil(pane.remotePointerAnchorPointForTesting)

        pane.simulateEmbeddedGraphicsInputForTesting(.mouseMoved(x: 1, y: 0))

        XCTAssertTrue(embeddedSession.inputEvents.contains { event in
            if case .resize = event { return true }
            return false
        })
        XCTAssertEqual(embeddedSession.inputEvents.last, .mouseMoved(x: 1, y: 0))
    }

    func testEmbeddedGraphicsSurfaceAcceptsDroppedFilesAsGraphicsFileDropEvent() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let embeddedSession = RecordingWorkspaceEmbeddedGraphicsSession()
        let attachment = GraphicsRuntimeAttachment(
            runtimeID: "graphics_embedded_vnc_drop",
            kind: .embeddedGraphics,
            session: embeddedSession
        )
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "windows.example.com",
            port: 5900,
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            launchArguments: ["windows.example.com:5900"],
            status: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
        )

        workspace.loadView()
        _ = workspace.openGraphicsSession(
            title: "Windows 桌面",
            diagnostic: diagnostic,
            runtimeID: "graphics_embedded_vnc_drop",
            attachment: attachment
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)
        pane.view.setFrameSize(NSSize(width: 800, height: 600))
        pane.view.layoutSubtreeIfNeeded()
        let initialResize = try XCTUnwrap(embeddedSession.resizeEventsForTesting.first)

        pane.simulateEmbeddedFileDropForTesting(
            paths: ["/Users/mac/Desktop/report.txt"],
            at: NSPoint(x: 400, y: 300)
        )
        let renderFrame = try XCTUnwrap(pane.renderSurfaceFrameForTesting)

        XCTAssertEqual(
            embeddedSession.inputEvents.last,
            .fileDrop(
                paths: ["/Users/mac/Desktop/report.txt"],
                x: Int((400.0 / Double(renderFrame.width) * Double(initialResize.width)).rounded()),
                y: Int((300.0 / Double(renderFrame.height) * Double(initialResize.height)).rounded())
            )
        )
    }

    func testEmbeddedGraphicsSurfaceAcceptsDroppedFoldersAsGraphicsFileDropEvent() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let embeddedSession = RecordingWorkspaceEmbeddedGraphicsSession()
        let attachment = GraphicsRuntimeAttachment(
            runtimeID: "graphics_embedded_vnc_folder_drop",
            kind: .embeddedGraphics,
            session: embeddedSession
        )
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "windows.example.com",
            port: 5900,
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            launchArguments: ["windows.example.com:5900"],
            status: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
        )

        workspace.loadView()
        _ = workspace.openGraphicsSession(
            title: "Windows 桌面",
            diagnostic: diagnostic,
            runtimeID: "graphics_embedded_vnc_folder_drop",
            attachment: attachment
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)
        pane.view.setFrameSize(NSSize(width: 800, height: 600))
        pane.view.layoutSubtreeIfNeeded()
        let initialResize = try XCTUnwrap(embeddedSession.resizeEventsForTesting.first)

        pane.simulateEmbeddedFileDropForTesting(
            paths: ["/Users/mac/Desktop/Project"],
            at: NSPoint(x: 120, y: 90)
        )
        let renderFrame = try XCTUnwrap(pane.renderSurfaceFrameForTesting)

        XCTAssertEqual(
            embeddedSession.inputEvents.last,
            .fileDrop(
                paths: ["/Users/mac/Desktop/Project"],
                x: Int((120.0 / Double(renderFrame.width) * Double(initialResize.width)).rounded()),
                y: Int((90.0 / Double(renderFrame.height) * Double(initialResize.height)).rounded())
            )
        )
    }

    func testEmbeddedGraphicsSurfaceSendsInitialResizeBeforeFirstFrame() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }

        let resize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)
        XCTAssertEqual(resize.width, Int((800.0 * Double(resize.scalePercent) / 100.0).rounded()))
        XCTAssertEqual(resize.height, Int((600.0 * Double(resize.scalePercent) / 100.0).rounded()))
    }

    func testEmbeddedGraphicsSurfaceMapsFileDropBeforeFirstFrameUsingInitialResize() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        let initialResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)
        inputEvents.removeAll()

        surface.simulateFileDropForTesting(paths: ["/Users/mac/Desktop/report.txt"], at: NSPoint(x: 400, y: 300))

        XCTAssertEqual(
            inputEvents,
            [
                .fileDrop(
                    paths: ["/Users/mac/Desktop/report.txt"],
                    x: Int((400.0 / 800.0 * Double(initialResize.width)).rounded()),
                    y: Int((300.0 / 600.0 * Double(initialResize.height)).rounded())
                )
            ]
        )
    }

    func testEmbeddedGraphicsSurfaceDoesNotImmediatelyResizeProductionFirstFrameAgainToPaneBounds() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        let initialResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)

        surface.display(
            GraphicsFrame(
                width: 1440,
                height: 900,
                bytesPerRow: 5760,
                pixelFormat: .bgra8Unorm,
                pixels: Data(repeating: 0, count: 1440 * 900 * 4)
            )
        )

        XCTAssertEqual(inputEvents.recordedResizeEvents, [initialResize])

        surface.setFrameSize(NSSize(width: 700, height: 500))

        XCTAssertFalse(
            waitUntil(timeout: 0.2) {
                inputEvents.recordedResizeEvents.count > 1
            }
        )
    }

    func testEmbeddedGraphicsSurfaceKeepsProductionFirstFrameStableWithoutDynamicResize() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        let initialResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)

        surface.display(
            GraphicsFrame(
                width: 1440,
                height: 900,
                bytesPerRow: 5760,
                pixelFormat: .bgra8Unorm,
                pixels: Data(repeating: 0, count: 1440 * 900 * 4)
            )
        )

        XCTAssertEqual(inputEvents.recordedResizeEvents, [initialResize])
        surface.setFrameSize(NSSize(width: 700, height: 500))
        surface.setFrameSize(NSSize(width: 900, height: 700))

        XCTAssertFalse(
            waitUntil(timeout: 0.2) {
                inputEvents.recordedResizeEvents.count > 1
            }
        )
    }

    func testEmbeddedGraphicsSurfaceMapsFolderDropAfterResizeUsingLastResizeBeforeNextFrame() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        surface.display(
            GraphicsFrame(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelFormat: .bgra8Unorm,
                pixels: Data([
                    0x00, 0x00, 0xFF, 0xFF,
                    0x00, 0xFF, 0x00, 0xFF
                ])
            )
        )
        let firstResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)

        surface.setFrameSize(NSSize(width: 500, height: 300))

        XCTAssertTrue(
            waitUntil {
                inputEvents.recordedResizeEvents.count == 2
            }
        )
        let resize = try XCTUnwrap(inputEvents.recordedResizeEvents.last)
        XCTAssertNotEqual(resize, firstResize)
        inputEvents.removeAll()

        surface.simulateFileDropForTesting(
            paths: ["/Users/mac/Desktop/Project"],
            at: NSPoint(x: 250, y: 150)
        )

        XCTAssertEqual(
            inputEvents,
            [
                .fileDrop(
                    paths: ["/Users/mac/Desktop/Project"],
                    x: Int((250.0 / 500.0 * Double(resize.width)).rounded()),
                    y: Int((150.0 / 300.0 * Double(resize.height)).rounded())
                )
            ]
        )
    }

    func testEmbeddedGraphicsSurfaceSuppressesDuplicateResizeEvents() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }

        surface.display(
            GraphicsFrame(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelFormat: .bgra8Unorm,
                pixels: Data([
                    0x00, 0x00, 0xFF, 0xFF,
                    0x00, 0xFF, 0x00, 0xFF
                ])
            )
        )
        surface.setFrameSize(NSSize(width: 800, height: 600))
        let firstResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)

        surface.setFrameSize(NSSize(width: 800, height: 600))
        surface.setFrameSize(NSSize(width: 800, height: 600))

        XCTAssertEqual(inputEvents.recordedResizeEvents, [firstResize])

        surface.setFrameSize(NSSize(width: 801, height: 600))

        let expectedSecondWidth = Int((801.0 * Double(firstResize.scalePercent) / 100.0).rounded())
        let secondResize = RecordedGraphicsResizeEvent(
            width: expectedSecondWidth,
            height: firstResize.height,
            scalePercent: firstResize.scalePercent
        )
        let deadline = Date().addingTimeInterval(1)
        while inputEvents.recordedResizeEvents != [firstResize, secondResize],
              Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(inputEvents.recordedResizeEvents, [
            firstResize,
            secondResize
        ])
    }

    func testEmbeddedGraphicsSurfaceSendsInitialResizeWhenInputHandlerIsBoundLate() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []

        surface.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertTrue(inputEvents.recordedResizeEvents.isEmpty)

        surface.inputHandler = { inputEvents.append($0) }
        let resize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)
        XCTAssertEqual(resize.width, Int((800.0 * Double(resize.scalePercent) / 100.0).rounded()))
        XCTAssertEqual(resize.height, Int((600.0 * Double(resize.scalePercent) / 100.0).rounded()))
        inputEvents.removeAll()

        surface.display(
            GraphicsFrame(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelFormat: .bgra8Unorm,
                pixels: Data([
                    0x00, 0x00, 0xFF, 0xFF,
                    0x00, 0xFF, 0x00, 0xFF
                ])
            )
        )

        XCTAssertTrue(inputEvents.recordedResizeEvents.isEmpty)
    }

    func testEmbeddedGraphicsSurfaceSendsInitialResizeToReboundInputHandlerBeforeFirstFrame() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var firstSessionEvents: [GraphicsInputEvent] = []
        var secondSessionEvents: [GraphicsInputEvent] = []

        surface.inputHandler = { firstSessionEvents.append($0) }
        XCTAssertEqual(firstSessionEvents.recordedResizeEvents.count, 1)

        surface.inputHandler = { secondSessionEvents.append($0) }

        XCTAssertEqual(secondSessionEvents.recordedResizeEvents, firstSessionEvents.recordedResizeEvents)
    }

    func testEmbeddedGraphicsSurfaceCoalescesRapidResizeEventsToFinalSize() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }

        surface.display(
            GraphicsFrame(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelFormat: .bgra8Unorm,
                pixels: Data([
                    0x00, 0x00, 0xFF, 0xFF,
                    0x00, 0xFF, 0x00, 0xFF
                ])
            )
        )
        surface.setFrameSize(NSSize(width: 800, height: 600))
        let firstResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)

        surface.setFrameSize(NSSize(width: 810, height: 600))
        surface.setFrameSize(NSSize(width: 820, height: 600))

        XCTAssertEqual(inputEvents.recordedResizeEvents, [firstResize])

        let deadline = Date().addingTimeInterval(1)
        let expectedFinalWidth = Int((820.0 * Double(firstResize.scalePercent) / 100.0).rounded())
        let finalResize = RecordedGraphicsResizeEvent(
            width: expectedFinalWidth,
            height: firstResize.height,
            scalePercent: firstResize.scalePercent
        )
        while inputEvents.recordedResizeEvents != [firstResize, finalResize],
              Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(inputEvents.recordedResizeEvents, [firstResize, finalResize])
    }

    func testEmbeddedGraphicsSurfaceCancelsPendingResizeWhenViewReturnsToSentSize() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }

        surface.display(
            GraphicsFrame(
                width: 2,
                height: 1,
                bytesPerRow: 8,
                pixelFormat: .bgra8Unorm,
                pixels: Data([
                    0x00, 0x00, 0xFF, 0xFF,
                    0x00, 0xFF, 0x00, 0xFF
                ])
            )
        )
        surface.setFrameSize(NSSize(width: 800, height: 600))
        let firstResize = try XCTUnwrap(inputEvents.recordedResizeEvents.first)

        surface.setFrameSize(NSSize(width: 810, height: 600))
        surface.setFrameSize(NSSize(width: 800, height: 600))

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(inputEvents.recordedResizeEvents, [firstResize])
    }

    func testEmbeddedGraphicsSurfaceUsesBackingScaleForCrispRetinaRendering() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let expectedScale = try XCTUnwrap(NSScreen.main?.backingScaleFactor)

        XCTAssertEqual(surface.layer?.contentsScale, expectedScale)
    }

    func testEmbeddedGraphicsSurfaceUsesBackingScaleForRemotePointerRendering() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let expectedScale = try XCTUnwrap(NSScreen.main?.backingScaleFactor)

        surface.updateRemotePointerPosition(x: 10, y: 10)

        let pointerLayer = try XCTUnwrap(surface.layer?.sublayers?.last)
        XCTAssertEqual(pointerLayer.contentsScale, expectedScale)
    }

    func testEmbeddedGraphicsSurfaceTurnsCommandVIntoClipboardTextPaste() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        inputEvents.removeAll()
        surface.pasteboardStringProvider = { "hello from macOS" }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        surface.keyDown(with: event)

        XCTAssertEqual(inputEvents, [.clipboardTextPaste("hello from macOS")])
    }

    func testEmbeddedGraphicsSurfaceSuppressesCommandVKeyUpAfterClipboardTextPaste() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        inputEvents.removeAll()
        surface.pasteboardStringProvider = { "hello from macOS" }
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        surface.keyDown(with: keyDown)
        surface.keyUp(with: keyUp)

        XCTAssertEqual(inputEvents, [.clipboardTextPaste("hello from macOS")])
    }

    func testEmbeddedGraphicsSurfaceDoesNotSendPlainVWhenCommandVPasteboardIsEmpty() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        inputEvents.removeAll()
        surface.pasteboardStringProvider = { "" }
        let keyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        surface.keyDown(with: keyDown)
        surface.keyUp(with: keyUp)

        XCTAssertEqual(inputEvents, [])
    }

    func testEmbeddedGraphicsSurfaceSuppressesRepeatedCommandVWhileKeyIsHeld() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        inputEvents.removeAll()
        surface.pasteboardStringProvider = { "large clipboard payload" }
        let firstKeyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))
        let repeatedKeyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0.1,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: true,
            keyCode: 9
        ))
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0.2,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        surface.keyDown(with: firstKeyDown)
        surface.keyDown(with: repeatedKeyDown)
        surface.keyUp(with: keyUp)

        XCTAssertEqual(inputEvents, [.clipboardTextPaste("large clipboard payload")])
    }

    func testEmbeddedGraphicsSurfaceSendsModifierStateForRemoteShortcuts() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        inputEvents.removeAll()
        let controlDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 59
        ))
        let cDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let cUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let controlUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 59
        ))

        surface.flagsChanged(with: controlDown)
        surface.keyDown(with: cDown)
        surface.keyUp(with: cUp)
        surface.flagsChanged(with: controlUp)

        XCTAssertEqual(inputEvents, [
            .key(scancode: 0x1D, isExtended: false, isPressed: true),
            .key(scancode: 0x2E, isExtended: false, isPressed: true),
            .key(scancode: 0x2E, isExtended: false, isPressed: false),
            .key(scancode: 0x1D, isExtended: false, isPressed: false)
        ])
    }

    func testEmbeddedGraphicsSurfaceReleasesActiveModifiersWhenFocusLeavesSurface() throws {
        let surface = GraphicsRenderSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var inputEvents: [GraphicsInputEvent] = []
        surface.inputHandler = { inputEvents.append($0) }
        inputEvents.removeAll()
        let controlDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 59
        ))

        surface.flagsChanged(with: controlDown)
        XCTAssertTrue(surface.resignFirstResponder())

        XCTAssertEqual(inputEvents, [
            .key(scancode: 0x1D, isExtended: false, isPressed: true),
            .key(scancode: 0x1D, isExtended: false, isPressed: false)
        ])
    }

    func testClosingGraphicsSessionRunsRuntimeCloseHandler() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "desktop.example.com",
            port: 5900,
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            launchArguments: ["desktop.example.com:5900"],
            status: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
        )
        var closedRuntimeIDs: [String] = []

        workspace.loadView()
        let runtimeID = workspace.openGraphicsSession(
            title: "VNC 桌面",
            diagnostic: diagnostic,
            runtimeID: "graphics_vnc_close",
            onClose: { closedRuntimeIDs.append($0) }
        )
        workspace.closeCurrentTerminal()

        XCTAssertEqual(runtimeID, "graphics_vnc_close")
        XCTAssertEqual(closedRuntimeIDs, ["graphics_vnc_close"])
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testCloseAllTerminalsClosesGraphicsRuntime() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "windows.example.com",
            port: 5900,
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            launchArguments: ["windows.example.com:5900"],
            status: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
        )
        var closedRuntimeIDs: [String] = []

        workspace.loadView()
        workspace.openGraphicsSession(
            title: "Windows 桌面",
            diagnostic: diagnostic,
            runtimeID: "graphics_vnc_close_all",
            onClose: { closedRuntimeIDs.append($0) }
        )

        XCTAssertTrue(workspace.closeAllTerminals())
        XCTAssertEqual(closedRuntimeIDs, ["graphics_vnc_close_all"])
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testWorkspaceMultiExecTargetsExcludeBrowserAndFilePanes() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        try workspace.openLocalShell()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_prod", status: "running", diagnostic: "running"),
            title: "生产 API",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_telnet", status: "running", diagnostic: "running"),
            title: "Telnet 控制台",
            connectionKind: .telnet
        )
        _ = try workspace.openBrowserSession(urlString: "https://example.com", title: "文档")
        _ = try workspace.openFileSession(path: NSTemporaryDirectory(), title: "本地文件")

        let targets = workspace.multiExecTargets()
        let sentCount = workspace.broadcastInput("uptime\n", to: ["term_prod", ""])

        XCTAssertEqual(targets.map(\.id), ["term_prod", "term_serial"])
        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_prod", bytes: Array("uptime\n".utf8))
        ])
    }

    func testAgentTerminalSessionsListExecutableTerminalPanes() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        let localRuntimeID = try workspace.openLocalShell()
        let localPane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        localPane.hostCurrentDirectoryUpdate(source: localPane.terminalView, directory: "/Users/mac/project")
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        let sshPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        sshPane.hostCurrentDirectoryUpdate(source: sshPane.terminalView, directory: "/srv/app")
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_telnet", status: "running", diagnostic: "running"),
            title: "Telnet 控制台",
            connectionKind: .telnet
        )
        _ = try workspace.openBrowserSession(urlString: "https://example.com", title: "文档")

        let sessions = workspace.listAgentTerminalSessions()

        XCTAssertEqual(sessions.map(\.runtimeID), [localRuntimeID, "term_ssh", "term_serial", "term_telnet"])
        XCTAssertEqual(sessions.map(\.kind), ["local", "ssh", "serial", "telnet"])
        XCTAssertEqual(sessions.map(\.environment), ["development", "production", "development", "development"])
        XCTAssertEqual(sessions.map(\.isCurrent), [false, false, false, true])
        XCTAssertEqual(sessions.map(\.currentDirectory), ["/Users/mac/project", "/srv/app", "~", "~"])
        XCTAssertEqual(sessions.map(\.subtitle), ["local · /Users/mac/project", "ssh · /srv/app", "serial · ~", "telnet · ~"])
    }

    func testAgentTerminalSessionsPreferSavedSessionAutomationEnvironment() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_api", status: "running", diagnostic: "running"),
            title: "API",
            connectionKind: .ssh,
            liveSessionContext: liveContext(host: "api.example.com"),
            automationPolicy: SessionAutomationPolicy(environment: "production", aiExecutionPolicy: "commandCard")
        )

        let sessions = workspace.listAgentTerminalSessions()

        XCTAssertEqual(sessions.map(\.runtimeID), ["term_api"])
        XCTAssertEqual(sessions.map(\.environment), ["production"])
    }

    func testWorkspaceBuildsAITerminalContextForSelectedRuntimeID() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        let localRuntimeID = try workspace.openLocalShell()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            connectionKind: .ssh
        )

        let localContext = try XCTUnwrap(workspace.aiTerminalContext(runtimeID: localRuntimeID))
        let remoteContext = try XCTUnwrap(workspace.aiTerminalContext(runtimeID: "term_ssh"))

        XCTAssertEqual(localContext.runtimeID, localRuntimeID)
        XCTAssertEqual(localContext.title, L10n.Workspace.local)
        XCTAssertEqual(remoteContext.runtimeID, "term_ssh")
        XCTAssertEqual(remoteContext.title, "deploy@example.com")
    }

    func testAITerminalContextUsesRawTranscriptWhenRichDisplayHighlightingIsEnabled() throws {
        let suiteName = "StacioWorkspaceRawAIContext-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
            settings.terminalRichHighlightingEnabled = true
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "tokyo-night"
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            settingsStore: settingsStore
        )
        let raw = "ERROR status=1 192.168.8.10:8080 /var/log/app.log\n"

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ai_raw", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            reconnecter: nil,
            connectionKind: .ssh
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.feedRemoteOutput(Array(raw.utf8))

        let context = try XCTUnwrap(workspace.aiTerminalContext(runtimeID: "term_ai_raw"))
        XCTAssertEqual(context.recentTranscript, raw)
        XCTAssertFalse(context.recentTranscript.contains("\u{001B}["))
        XCTAssertFalse(context.recentTranscript.contains("\u{001B}]8;;"))
    }

    func testAIAssistantContextFallsBackToLastCommandTerminalWhenCurrentPaneIsNotTerminal() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ai_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        _ = try workspace.openBrowserSession(urlString: "https://example.com", title: "文档")

        XCTAssertTrue(workspace.currentTerminalPane is BrowserPaneViewController)
        let context = try XCTUnwrap(workspace.currentAITerminalContext())
        XCTAssertEqual(context.runtimeID, "term_ai_ssh")
        XCTAssertEqual(context.title, "生产 SSH")
    }

    func testMultiExecSessionRequiresAtLeastTwoSSHOrSerialTerminals() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        try workspace.openLocalShell()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_telnet", status: "running", diagnostic: "running"),
            title: "Telnet 控制台",
            connectionKind: .telnet
        )

        XCTAssertThrowsError(try workspace.startMultiExecSession(targetIDs: ["term_telnet"])) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "多执行需要至少两个已连接的 SSH 或串口终端。"
            )
        }
        XCTAssertFalse(workspace.isMultiExecSessionActiveForTesting)
    }

    func testStartingMultiExecSessionSplitsSelectedSSHAndSerialTerminals() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_telnet", status: "running", diagnostic: "running"),
            title: "Telnet 控制台",
            connectionKind: .telnet
        )

        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])

        XCTAssertTrue(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.currentSplitPaneRuntimeIDsForTesting, ["term_ssh", "term_serial"])
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .grid)
        XCTAssertEqual(workspace.currentGridSplitColumnCountForTesting, 2)
        XCTAssertEqual(workspace.currentGridSplitRowCountForTesting, 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["Telnet 控制台", "多执行 x2"])
        let sshHeader = try XCTUnwrap(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.term_ssh"))
        let serialHeader = try XCTUnwrap(workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.term_serial"))
        let sshTitle = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.title.term_ssh") as? NSTextField
        )
        let serialTitle = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.splitPaneHeader.title.term_serial") as? NSTextField
        )
        let sshPause = try XCTUnwrap(sshHeader.firstSubview(withIdentifier: "Stacio.Terminal.multiExecPause.term_ssh"))
        let serialPause = try XCTUnwrap(serialHeader.firstSubview(withIdentifier: "Stacio.Terminal.multiExecPause.term_serial"))
        let sshPauseFrame = sshPause.convert(sshPause.bounds, to: sshHeader)
        let serialPauseFrame = serialPause.convert(serialPause.bounds, to: serialHeader)
        let sshTitleFrame = sshTitle.convert(sshTitle.bounds, to: sshHeader)
        let serialTitleFrame = serialTitle.convert(serialTitle.bounds, to: serialHeader)

        XCTAssertEqual(sshTitle.stringValue, "生产 SSH")
        XCTAssertEqual(serialTitle.stringValue, "串口控制台")
        XCTAssertGreaterThan(sshPauseFrame.minX, sshTitleFrame.maxX)
        XCTAssertGreaterThan(serialPauseFrame.minX, serialTitleFrame.maxX)
    }

    func testStartingMultiExecSessionDefaultsFourTargetsToTwoByTwoGrid() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        for index in 1...4 {
            workspace.openRemoteShell(
                status: LiveShellStatus(runtimeId: "term_\(index)", status: "running", diagnostic: "running"),
                title: "终端 \(index)",
                connectionKind: index.isMultiple(of: 2) ? .serial : .ssh
            )
        }

        try workspace.startMultiExecSession(targetIDs: ["term_1", "term_2", "term_3", "term_4"])
        workspace.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.currentSplitPaneRuntimeIDsForTesting, ["term_1", "term_2", "term_3", "term_4"])
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .grid)
        XCTAssertEqual(workspace.currentGridSplitColumnCountForTesting, 2)
        XCTAssertEqual(workspace.currentGridSplitRowCountForTesting, 2)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["多执行 x4"])
    }

    func testMultiExecSessionSynchronizesUserInputAndPasteBetweenUnpausedTerminals() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])
        let sshPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_ssh"))
        let serialPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_serial"))

        sshPane.send(source: sshPane.terminalView, data: ArraySlice(Array("ls\n".utf8)))
        serialPane.send(source: serialPane.terminalView, data: ArraySlice(Array("pwd\n".utf8)))

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_ssh", bytes: Array("ls\n".utf8)),
            TerminalInputEvent(runtimeID: "term_serial", bytes: Array("ls\n".utf8)),
            TerminalInputEvent(runtimeID: "term_serial", bytes: Array("pwd\n".utf8)),
            TerminalInputEvent(runtimeID: "term_ssh", bytes: Array("pwd\n".utf8))
        ])
    }

    func testMultiExecSessionKeepsSynchronizingAfterRemoteRuntimeReattaches() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let reconnecter = RecordingWorkspaceRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_ssh_new", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            reconnecter: reconnecter,
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])
        let sshPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_ssh"))
        let serialPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_serial"))

        try sshPane.reconnectTerminal()
        sshPane.send(source: sshPane.terminalView, data: ArraySlice(Array("ls\n".utf8)))
        serialPane.send(source: serialPane.terminalView, data: ArraySlice(Array("pwd\n".utf8)))

        XCTAssertNil(workspace.remoteTerminalPaneForTesting(runtimeID: "term_ssh"))
        XCTAssertTrue(workspace.remoteTerminalPaneForTesting(runtimeID: "term_ssh_new") === sshPane)
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_ssh_new", bytes: Array("ls\n".utf8)),
            TerminalInputEvent(runtimeID: "term_serial", bytes: Array("ls\n".utf8)),
            TerminalInputEvent(runtimeID: "term_serial", bytes: Array("pwd\n".utf8)),
            TerminalInputEvent(runtimeID: "term_ssh_new", bytes: Array("pwd\n".utf8))
        ])
    }

    func testMultiExecSessionEndsWhenRuntimeReattachCollidesWithExistingTarget() throws {
        let reconnecter = RecordingWorkspaceRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            reconnecter: reconnecter,
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])
        let sshPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_ssh"))

        try sshPane.reconnectTerminal()

        XCTAssertFalse(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["生产 SSH x2"])
    }

    func testMultiExecPauseButtonIsolatesSourceAndTargetSynchronization() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])
        let sshPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_ssh"))
        let serialPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_serial"))

        workspace.setMultiExecPausedForTesting(runtimeID: "term_serial", paused: true)
        sshPane.send(source: sshPane.terminalView, data: ArraySlice(Array("date\n".utf8)))
        serialPane.send(source: serialPane.terminalView, data: ArraySlice(Array("whoami\n".utf8)))

        XCTAssertTrue(serialPane.isMultiExecPausedForTesting)
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_ssh", bytes: Array("date\n".utf8)),
            TerminalInputEvent(runtimeID: "term_serial", bytes: Array("whoami\n".utf8))
        ])
    }

    func testClosingMultiExecTabExitsMultiExecWithoutClosingUnderlyingTerminals() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])

        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertFalse(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.openTerminalPaneCount, 2)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["生产 SSH", "串口控制台"])
        XCTAssertEqual(workspace.multiExecTargets().map(\.id), ["term_ssh", "term_serial"])
        XCTAssertEqual(bridge.closedRuntimeIDs, [])
        XCTAssertEqual(sink.closedRuntimeIDs, [])
    }

    func testCloseCurrentTerminalInMultiExecClosesSelectedPane() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])

        workspace.closeCurrentTerminal()

        XCTAssertFalse(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["生产 SSH"])
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_serial"])
        XCTAssertEqual(sink.closedRuntimeIDs, ["term_serial"])
    }

    func testSplitCurrentTerminalAddsSecondPaneInSelectedTab() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        try workspace.openLocalShell()
        try workspace.splitCurrentTerminal()

        XCTAssertEqual(workspace.openTerminalPaneCount, 2)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地 x2"])
        XCTAssertTrue(workspace.currentTerminalPane is TerminalPaneViewController)
        XCTAssertEqual(workspace.currentSplitPaneMinimumThicknessesForTesting, [0, 0])
    }

    func testSplitLayoutModesApplyToAllPanesWithoutCappingPaneCount() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        try workspace.openLocalShell()
        for _ in 0..<4 {
            try workspace.splitCurrentTerminal()
        }

        workspace.setCurrentTerminalSplitLayout(.horizontal)

        XCTAssertEqual(workspace.openTerminalPaneCount, 5)
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .horizontal)
        XCTAssertEqual(workspace.currentSplitPaneRuntimeIDsForTesting.count, 5)

        workspace.setCurrentTerminalSplitLayout(.grid)
        workspace.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(workspace.openTerminalPaneCount, 5)
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .grid)
        XCTAssertEqual(workspace.currentGridSplitColumnCountForTesting, 3)
        XCTAssertEqual(workspace.currentGridSplitRowCountForTesting, 2)
    }

    func testCloseCurrentTerminalClosesSelectedSplitPane() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { sink },
            autoStartTerminalProcesses: false
        )
        let window = NSWindow(contentViewController: workspace)
        defer { window.close() }

        window.makeKeyAndOrderFront(nil)
        try workspace.openLocalShell()
        let firstPane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        try workspace.splitCurrentTerminal()
        let secondPane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(window.makeFirstResponder(firstPane.terminalView))
        workspace.closeCurrentTerminal()

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertIdentical(workspace.currentTerminalPane, secondPane)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertEqual(sink.closedRuntimeIDs, [firstPane.runtimeID])
    }

    func testCloseCurrentTerminalRemovesPaneAndTab() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )
        let status = LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")

        workspace.loadView()
        workspace.openRemoteShell(status: status, title: "deploy@example.com")
        workspace.closeCurrentTerminal()

        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
        XCTAssertNil(workspace.currentTerminalPane)
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_remote"])
        XCTAssertEqual(sink.closedRuntimeIDs, ["term_remote"])
    }

    func testCancelingRemoteTerminalCloseKeepsPaneAndRuntimeOpen() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )
        let status = LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        var closeRequests: [String] = []
        workspace.onRemoteTerminalClosed = { pane in
            closeRequests.append(pane.runtimeID)
            return false
        }

        workspace.loadView()
        workspace.openRemoteShell(status: status, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        workspace.closeCurrentTerminal()

        XCTAssertEqual(closeRequests, ["term_remote"])
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertIdentical(workspace.currentTerminalPane, pane)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["deploy@example.com"])
        XCTAssertTrue(bridge.closedRuntimeIDs.isEmpty)
        XCTAssertTrue(sink.closedRuntimeIDs.isEmpty)
    }

    func testWorkspaceRoutesFindCopyPasteToCurrentPane() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let defaults = UserDefaults(suiteName: "WorkspaceLocalShellTests.\(UUID().uuidString)")!
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalMultiLinePasteConfirmationEnabled = false
        }
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            settingsStore: settingsStore
        )
        let status = LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")

        workspace.loadView()
        workspace.openRemoteShell(status: status, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.feedRemoteOutput(Array("alpha beta gamma\r\n".utf8))
        XCTAssertTrue(workspace.findInCurrentTerminal("beta"))

        workspace.copyFromCurrentTerminal()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("whoami\n", forType: .string)
        workspace.pasteIntoCurrentTerminal()

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("whoami\n".utf8))
        ])
    }

    func testWorkspaceListsMultiExecTargetsAndBroadcastsToSelectedRemotePanes() {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API"
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_prod", status: "running", diagnostic: "running"),
            title: "生产 API"
        )

        let targets = workspace.multiExecTargets()
        let sentCount = workspace.broadcastInput("uptime\n", to: ["term_prod"])

        XCTAssertEqual(targets.map(\.id), ["term_dev", "term_prod"])
        XCTAssertEqual(targets.map(\.environment), ["development", "production"])
        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_prod", bytes: Array("uptime\n".utf8))
        ])
    }

    func testWorkspaceBroadcastSkipsDisconnectedRemoteTargetAfterSelection() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API"
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_prod", status: "running", diagnostic: "running"),
            title: "生产 API"
        )
        let targets = workspace.multiExecTargets()
        let prodPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_prod"))
        bridge.pollError = TerminalRuntimeError.RuntimeClosed(runtimeId: "term_prod")

        prodPane.pollRemoteOutputOnce()
        let sentCount = workspace.broadcastInput("uptime\n", to: targets.map(\.id).filter { $0 == "term_prod" })

        XCTAssertEqual(prodPane.lifecycleState, .disconnected)
        XCTAssertEqual(sentCount, 0)
        XCTAssertEqual(sink.userInputEvents, [])
    }

    func testWorkspaceTabContextMenuMatchesRequestedTopSessionActions() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()
        try workspace.openLocalShell()

        XCTAssertEqual(
            workspace.tabContextMenuTitlesForTesting(index: 0),
            [
                "重命名选项卡",
                "设置选项卡颜色",
                "复制选项卡",
                "关闭选项卡",
                "-",
                "关闭左侧所有选项卡",
                "关闭右侧所有选项卡",
                "关闭除此选项卡以外的所有选项卡",
                "关闭所有选项卡",
                "-",
                "分离选项卡",
                "全屏",
                "固定此选项卡",
                "-",
                "保存终端输出",
                "打印终端输出",
                "增加字体大小",
                "减小字体大小"
            ]
        )
    }

    func testWorkspaceTabContextMenuRenameColorPinAndCloseMutateRealTabs() throws {
        let presenter = RecordingWorkspaceTabOperationsPresenter()
        presenter.renameResponses = ["生产 SSH"]
        presenter.colorResponses = [NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)]
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            tabOperationsPresenter: presenter
        )

        workspace.loadView()
        try workspace.openLocalShell()
        try workspace.openBrowserSession(urlString: "https://example.com", title: "文档")
        try workspace.openFileSession(path: NSTemporaryDirectory(), title: "文件")

        try workspace.performTabContextActionForTesting(.rename, index: 1)
        try workspace.performTabContextActionForTesting(.setColor, index: 1)
        try workspace.performTabContextActionForTesting(.pin, index: 1)

        XCTAssertEqual(workspace.tabLabelsForTesting, ["生产 SSH", "本地", "文件"])
        XCTAssertEqual(workspace.pinnedTabLabelsForTesting, ["生产 SSH"])
        XCTAssertEqual(workspace.tabContextMenuTitlesForTesting(index: 0)[12], "取消固定选项卡")
        XCTAssertEqual(workspace.tabColorHexForTesting(index: 0), "#FF9400")
        XCTAssertEqual(presenter.renamePrompts, ["文档"])
        XCTAssertEqual(presenter.colorPromptTitles, ["生产 SSH"])

        try workspace.performTabContextActionForTesting(.pin, index: 0)

        XCTAssertEqual(workspace.pinnedTabLabelsForTesting, [])
        XCTAssertEqual(workspace.tabContextMenuTitlesForTesting(index: 0)[12], "固定此选项卡")

        try workspace.performTabContextActionForTesting(.pin, index: 0)
        try workspace.performTabContextActionForTesting(.closeTab, index: 0)

        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地", "文件"])
        XCTAssertEqual(workspace.pinnedTabLabelsForTesting, [])
    }

    func testWorkspaceTabContextMenuCloseLeftRightOthersAndAllCloseRealPanes() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { sink },
            autoStartTerminalProcesses: false
        )

        workspace.loadView()
        try workspace.openLocalShell()
        let firstRuntime = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController).runtimeID
        try workspace.openLocalShell()
        let secondRuntime = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController).runtimeID
        try workspace.openLocalShell()
        let thirdRuntime = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController).runtimeID

        try workspace.performTabContextActionForTesting(.closeTabsToLeft, index: 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地", "本地"])
        XCTAssertEqual(sink.closedRuntimeIDs, [firstRuntime])

        try workspace.openLocalShell()
        let fourthRuntime = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController).runtimeID
        try workspace.performTabContextActionForTesting(.closeTabsToRight, index: 0)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertEqual(sink.closedRuntimeIDs, [firstRuntime, thirdRuntime, fourthRuntime])

        try workspace.openLocalShell()
        let fifthRuntime = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController).runtimeID
        try workspace.openLocalShell()
        let sixthRuntime = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController).runtimeID
        try workspace.performTabContextActionForTesting(.closeOtherTabs, index: 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertEqual(sink.closedRuntimeIDs, [firstRuntime, thirdRuntime, fourthRuntime, secondRuntime, sixthRuntime])

        try workspace.performTabContextActionForTesting(.closeAllTabs, index: 0)
        XCTAssertEqual(workspace.tabLabelsForTesting, [])
        XCTAssertEqual(sink.closedRuntimeIDs, [firstRuntime, thirdRuntime, fourthRuntime, secondRuntime, sixthRuntime, fifthRuntime])
    }

    func testWorkspaceTabContextCloseAllClosesMultiExecPanesInsteadOfRestoringThem() throws {
        let sink = RecordingWorkspaceRemoteTerminalEventSink()
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "生产 SSH",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        try workspace.startMultiExecSession(targetIDs: ["term_ssh", "term_serial"])

        try workspace.performTabContextActionForTesting(.closeAllTabs, index: 0)

        XCTAssertFalse(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
        XCTAssertEqual(workspace.tabLabelsForTesting, [])
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_ssh", "term_serial"])
        XCTAssertEqual(sink.closedRuntimeIDs, ["term_ssh", "term_serial"])
    }

    func testWorkspaceTabContextMenuDuplicateDetachFullscreenAndFontActionsAreReal() throws {
        let suiteName = "StacioWorkspaceTabMenuSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let detacher = RecordingWorkspaceTabDetacher()
        let fullscreenToggler = RecordingWorkspaceFullscreenToggler()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore,
            tabDetacher: detacher,
            fullscreenToggler: fullscreenToggler
        )
        let window = NSWindow(contentViewController: workspace)
        defer { window.close() }

        window.makeKeyAndOrderFront(nil)
        try workspace.openLocalShell()
        try workspace.performTabContextActionForTesting(.duplicate, index: 0)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地", "本地"])
        XCTAssertEqual(workspace.openTerminalPaneCount, 2)

        try workspace.performTabContextActionForTesting(.toggleFullscreen, index: 0)
        XCTAssertEqual(fullscreenToggler.toggledWindowTitles, [window.title])

        try workspace.performTabContextActionForTesting(.increaseFontSize, index: 0)
        XCTAssertEqual(settingsStore.snapshot().terminalFontSize, 14)
        try workspace.performTabContextActionForTesting(.decreaseFontSize, index: 0)
        XCTAssertEqual(settingsStore.snapshot().terminalFontSize, 13)

        try workspace.performTabContextActionForTesting(.detach, index: 1)
        XCTAssertEqual(workspace.tabLabelsForTesting, ["本地"])
        XCTAssertEqual(detacher.detachedTitles, ["本地"])
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
    }

    func testWorkspaceDuplicatesSSHThroughBackgroundReconnecterWithoutBlockingMainActor() throws {
        let reconnecter = DelayedBackgroundWorkspaceReconnecter(
            status: LiveShellStatus(
                runtimeId: "term_duplicate_async",
                status: "running",
                diagnostic: "running"
            ),
            delay: 0.25
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_original", status: "running", diagnostic: "running"),
            title: "Production SSH",
            reconnecter: reconnecter,
            connectionKind: .ssh
        )

        let startedAt = Date()
        try workspace.performTabContextActionForTesting(.duplicate, index: 0)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.08)
        XCTAssertEqual(reconnecter.synchronousReconnectCount, 0)
        XCTAssertEqual(workspace.openTerminalPaneCount, 2)
        XCTAssertTrue(waitUntil {
            workspace.remoteTerminalPaneForTesting(runtimeID: "term_duplicate_async") != nil
        })
    }

    func testClosingPendingSSHDuplicateClosesLateConnectedRuntime() throws {
        let bridge = RecordingWorkspaceRemoteTerminalBridge()
        let reconnecter = DelayedBackgroundWorkspaceReconnecter(
            status: LiveShellStatus(
                runtimeId: "term_duplicate_orphan",
                status: "running",
                diagnostic: "running"
            ),
            delay: 0.1
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_original", status: "running", diagnostic: "running"),
            title: "Production SSH",
            reconnecter: reconnecter,
            connectionKind: .ssh
        )

        try workspace.performTabContextActionForTesting(.duplicate, index: 0)
        workspace.closeCurrentTerminal()

        XCTAssertTrue(waitUntil {
            bridge.closedRuntimeIDs.contains("term_duplicate_orphan")
        })
        XCTAssertNil(workspace.remoteTerminalPaneForTesting(runtimeID: "term_duplicate_orphan"))
    }

    func testWorkspaceTabContextMenuSaveAndPrintTerminalOutputUseTranscript() throws {
        let presenter = RecordingWorkspaceTabOperationsPresenter()
        let printer = RecordingWorkspaceTerminalOutputPrinter()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioTerminalOutput-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        presenter.outputDestinations = [temporaryURL]
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkspaceRemoteTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkspaceRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            tabOperationsPresenter: presenter,
            terminalOutputPrinter: printer
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_output", status: "running", diagnostic: "running"),
            title: "deploy@example.com"
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.feedRemoteOutput(Array("hello from ssh\n".utf8))

        try workspace.performTabContextActionForTesting(.saveTerminalOutput, index: 0)
        try workspace.performTabContextActionForTesting(.printTerminalOutput, index: 0)

        XCTAssertEqual(try String(contentsOf: temporaryURL, encoding: .utf8), "hello from ssh\n")
        XCTAssertEqual(presenter.savedOutputURLs, [temporaryURL])
        XCTAssertEqual(printer.printedOutputs, ["hello from ssh\n"])
        XCTAssertEqual(printer.printedTitles, ["deploy@example.com"])
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

    func allSubviews<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.allSubviews(ofType: type)
            if let typed = subview as? T {
                matches.insert(typed, at: 0)
            }
            return matches
        }
    }

    func subviews(withIdentifierPrefix prefix: String) -> [NSView] {
        var matches: [NSView] = []
        if accessibilityIdentifier().hasPrefix(prefix) {
            matches.append(self)
        }
        for subview in subviews {
            matches.append(contentsOf: subview.subviews(withIdentifierPrefix: prefix))
        }
        return matches
    }
}

private func liveContext(host: String) -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: host,
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:\(host)"
    )
}

private func mouseMovedEvent(overSegment index: Int, in control: NSSegmentedControl, window: NSWindow) -> NSEvent {
    let leading = (0..<index).reduce(CGFloat(0)) { partial, segment in
        partial + control.width(forSegment: segment)
    }
    let segmentWidth = max(1, control.width(forSegment: index))
    let controlPoint = NSPoint(x: leading + segmentWidth / 2, y: control.bounds.midY)
    let windowPoint = control.convert(controlPoint, to: nil)
    return NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowPoint,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
    )!
}

private func mouseMovedEvent(overDisplayedSegment index: Int, in control: NSSegmentedControl, window: NSWindow) -> NSEvent {
    let segmentWidth = control.bounds.width / CGFloat(max(1, control.segmentCount))
    let controlPoint = NSPoint(x: segmentWidth * CGFloat(index) + segmentWidth / 2, y: control.bounds.midY)
    let windowPoint = control.convert(controlPoint, to: nil)
    return NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowPoint,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
    )!
}

private final class RecordingWorkspaceRemoteTerminalEventSink: TerminalEventSink {
    private(set) var inputEvents: [TerminalInputEvent] = []
    private(set) var closedRuntimeIDs: [String] = []

    var userInputEvents: [TerminalInputEvent] {
        inputEvents.filter { event in
            String(decoding: event.bytes, as: UTF8.self).contains("__stacio_report_cwd") == false
        }
    }

    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {
        inputEvents.append(TerminalInputEvent(runtimeID: runtimeID, bytes: bytes))
    }
    func terminalDidClose(runtimeID: String) throws {
        closedRuntimeIDs.append(runtimeID)
    }
}

private final class RecordingWorkspaceRemoteTerminalBridge: RemoteTerminalBridging {
    private(set) var closedRuntimeIDs: [String] = []
    var pollError: Error?

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        if let pollError {
            throw pollError
        }
        return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(runtimeId: runtimeID, bytes: Data(), droppedByteCount: 0)
    }

    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        TerminalRuntime(
            id: runtimeID,
            kind: "remote_ssh",
            shellPath: "",
            remoteHost: "example.com",
            remotePort: 22,
            username: "deploy",
            cols: 80,
            rows: 24,
            resizeRevision: 0,
            status: "running",
            outputPaused: paused
        )
    }

    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {}

    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        closedRuntimeIDs.append(runtimeID)
        return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
    }
}

private final class RecordingWorkspaceRemoteTerminalReconnecter: RemoteTerminalReconnecting {
    private let status: LiveShellStatus
    private(set) var liveSessionContext: TunnelLiveSessionContext?

    init(status: LiveShellStatus, liveSessionContext: TunnelLiveSessionContext? = nil) {
        self.status = status
        self.liveSessionContext = liveSessionContext
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        status
    }
}

private final class DelayedBackgroundWorkspaceReconnecter: RemoteTerminalBackgroundReconnecting {
    private let status: LiveShellStatus
    private let delay: TimeInterval
    private(set) var synchronousReconnectCount = 0
    private(set) var liveSessionContext: TunnelLiveSessionContext?

    init(
        status: LiveShellStatus,
        delay: TimeInterval,
        liveSessionContext: TunnelLiveSessionContext? = nil
    ) {
        self.status = status
        self.delay = delay
        self.liveSessionContext = liveSessionContext
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        synchronousReconnectCount += 1
        Thread.sleep(forTimeInterval: delay)
        return status
    }

    func reconnectRemoteTerminalInBackground(
        title: String,
        automatically: Bool,
        completion: @escaping @MainActor (Result<LiveShellStatus, Error>) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [status] in
            completion(.success(status))
        }
    }
}

private final class RecordingWorkspaceRemoteFilesBridge: RemoteFilesBridging {
    private let entries: [RemoteFileEntry]
    private(set) var liveHosts: [String] = []
    private(set) var ftpHosts: [String] = []

    init(entries: [RemoteFileEntry]) {
        self.entries = entries
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        liveHosts.append(config.host)
        return entries
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

    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        ftpHosts.append(config.host)
        return entries
    }
}

private final class RecordingWorkspaceTabOperationsPresenter: WorkspaceTabOperationsPresenting {
    var renameResponses: [String?] = []
    var colorResponses: [NSColor?] = []
    var outputDestinations: [URL?] = []
    private(set) var renamePrompts: [String] = []
    private(set) var colorPromptTitles: [String] = []
    private(set) var outputDestinationTitles: [String] = []
    private(set) var savedOutputURLs: [URL] = []
    private(set) var errors: [(title: String, message: String)] = []

    func promptRenameTab(currentTitle: String, parentWindow: NSWindow?) -> String? {
        renamePrompts.append(currentTitle)
        return renameResponses.isEmpty ? nil : renameResponses.removeFirst() ?? nil
    }

    func chooseTabColor(currentColor: NSColor, title: String, parentWindow: NSWindow?) -> NSColor? {
        colorPromptTitles.append(title)
        return colorResponses.isEmpty ? nil : colorResponses.removeFirst() ?? nil
    }

    func chooseTerminalOutputDestination(suggestedName: String, parentWindow: NSWindow?) -> URL? {
        outputDestinationTitles.append(suggestedName)
        return outputDestinations.isEmpty ? nil : outputDestinations.removeFirst() ?? nil
    }

    func presentTerminalOutputSaved(destinationURL: URL, parentWindow: NSWindow?) {
        savedOutputURLs.append(destinationURL)
    }

    func presentError(title: String, message: String, parentWindow: NSWindow?) {
        errors.append((title, message))
    }
}

private final class RecordingWorkspaceTerminalOutputPrinter: WorkspaceTerminalOutputPrinting {
    private(set) var printedOutputs: [String] = []
    private(set) var printedTitles: [String] = []

    func printTerminalOutput(_ output: String, title: String, parentWindow: NSWindow?) throws {
        printedOutputs.append(output)
        printedTitles.append(title)
    }
}

private final class RecordingWorkspaceSCPTransferScheduler: SCPTransferScheduling {
    private(set) var disconnectedRuntimeIDs: [String] = []

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {}

    func disconnectTransfers(runtimeID: String) -> [String] {
        disconnectedRuntimeIDs.append(runtimeID)
        return []
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}
}

private final class RecordingWorkspaceFTPTransferScheduler: FTPTransferScheduling {
    private(set) var disconnectedRuntimeIDs: [String] = []

    func scheduleLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {}

    func disconnectTransfers(runtimeID: String) -> [String] {
        disconnectedRuntimeIDs.append(runtimeID)
        return []
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}
}

private final class RecordingWorkspaceTabDetacher: WorkspaceTabDetaching {
    private(set) var detachedTitles: [String] = []
    private var retainedControllers: [NSWindowController] = []

    func detachTab(contentViewController: NSViewController, title: String, parentWindow: NSWindow?) throws -> NSWindowController {
        detachedTitles.append(title)
        let controller = NSWindowController(window: NSWindow(contentViewController: contentViewController))
        controller.window?.title = title
        retainedControllers.append(controller)
        return controller
    }
}

private final class RecordingWorkspaceFullscreenToggler: WorkspaceFullscreenToggling {
    private(set) var toggledWindowTitles: [String] = []

    func toggleFullScreen(window: NSWindow?) {
        toggledWindowTitles.append(window?.title ?? "")
    }
}

private final class RecordingWorkspaceDeviceMetricsProvider: DeviceMetricsProviding {
    private let snapshot: DeviceMetricsDisplaySnapshot

    init(hosts: [String]) {
        self.snapshot = DeviceMetricsDisplaySnapshot(
            cpuUsage: 0,
            memory: DeviceMemoryDisplayUsage(usedBytes: 0, totalBytes: 1),
            networks: hosts.map {
                DeviceNetworkDisplayRate(interfaceName: $0, receiveBytesPerSecond: 0, transmitBytesPerSecond: 0)
            },
            disks: []
        )
    }

    init(snapshot: DeviceMetricsDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        completion(.success(snapshot))
    }
}

private final class RecordingWorkspaceDeviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering, DeviceMetricsAlertNotificationActivating {
    private var activationHandler: (String) -> Void = { _ in }
    private(set) var payloads: [DeviceMetricsAlertNotificationPayload] = []

    func deliver(_ payload: DeviceMetricsAlertNotificationPayload) {
        payloads.append(payload)
    }

    func setActivationHandler(_ handler: @escaping (String) -> Void) {
        activationHandler = handler
    }

    func activate(runtimeID: String) {
        activationHandler(runtimeID)
    }
}

private struct RecordedGraphicsResizeEvent: Equatable {
    let width: Int
    let height: Int
    let scalePercent: Int
}

private extension Array where Element == GraphicsInputEvent {
    var recordedResizeEvents: [RecordedGraphicsResizeEvent] {
        compactMap { event in
            guard case .resize(let width, let height, let scaleFactor) = event else {
                return nil
            }
            return RecordedGraphicsResizeEvent(
                width: width,
                height: height,
                scalePercent: Int((scaleFactor * 100).rounded())
            )
        }
    }
}

private final class RecordingWorkspaceEmbeddedGraphicsSession: EmbeddedGraphicsSession {
    var onFrame: ((GraphicsFrame) -> Void)?
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?
    private(set) var inputEvents: [GraphicsInputEvent] = []
    var resizeEventsForTesting: [RecordedGraphicsResizeEvent] {
        inputEvents.recordedResizeEvents
    }

    func start() throws {}

    func stop() {}

    func sendInput(_ event: GraphicsInputEvent) {
        inputEvents.append(event)
    }

    func emit(_ frame: GraphicsFrame) {
        onFrame?(frame)
    }

    func emitPointerPosition(x: Int, y: Int) {
        onPointerPosition?(x, y)
    }

    func emitPointerVisibilityChanged(_ isVisible: Bool) {
        onPointerVisibilityChanged?(isVisible)
    }

    func emitPointerBitmap(_ bitmap: GraphicsPointerBitmap) {
        onPointerBitmap?(bitmap)
    }
}

private extension WorkspaceViewController {
    var workspaceTabControllerForTesting: NSTabViewController? {
        let mirror = Mirror(reflecting: self)
        return mirror.children.first { $0.label == "tabViewController" }?.value as? NSTabViewController
    }

    var tabLabelsForTesting: [String] {
        workspaceTabControllerForTesting?.tabViewItems.map(\.label) ?? []
    }
}

private extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }

    func viewIconLabel(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.imageView?.accessibilityLabel()
    }

    func viewIconSize(atColumn column: Int, row: Int) -> NSSize? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.imageView?.image?.size
    }
}
