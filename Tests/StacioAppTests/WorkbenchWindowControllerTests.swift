import AppKit
import StacioAgentBridge
import SwiftTerm
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class WorkbenchWindowControllerTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 3,
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

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(defaultWorkbenchFrameAutosaveName()))
        UserDefaults.standard.removeObject(
            forKey: workbenchSplitWidthDefaultsKeyForTesting(defaultWorkbenchFrameAutosaveName(), column: "sidebar")
        )
        UserDefaults.standard.removeObject(
            forKey: workbenchSplitWidthDefaultsKeyForTesting(defaultWorkbenchFrameAutosaveName(), column: "inspector")
        )
    }

    override func tearDown() {
        NSApplication.shared.windows
            .filter { $0.title == "Stacio" }
            .forEach { $0.close() }
        UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(defaultWorkbenchFrameAutosaveName()))
        UserDefaults.standard.removeObject(
            forKey: workbenchSplitWidthDefaultsKeyForTesting(defaultWorkbenchFrameAutosaveName(), column: "sidebar")
        )
        UserDefaults.standard.removeObject(
            forKey: workbenchSplitWidthDefaultsKeyForTesting(defaultWorkbenchFrameAutosaveName(), column: "inspector")
        )
        super.tearDown()
    }

    func testWorkbenchWindowHasNativeThreeColumnLayout() {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let splitController = controller.contentSplitViewController
        XCTAssertEqual(splitController.splitViewItems.count, 3)
        XCTAssertEqual(controller.window?.title, "Stacio")
        XCTAssertLessThanOrEqual(controller.window?.minSize.width ?? .greatestFiniteMagnitude, 1)
        XCTAssertLessThanOrEqual(controller.window?.minSize.height ?? .greatestFiniteMagnitude, 1)
    }

    func testWorkbenchInspectorIncludesAIAssistantPanel() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        _ = inspector.view
        XCTAssertTrue(inspector.sectionLabelsForTesting.contains(L10n.AI.title))
        guard let aiIndex = inspector.sectionLabelsForTesting.firstIndex(of: L10n.AI.title) else {
            return XCTFail("expected AI inspector section")
        }
        inspector.selectSectionForTesting(aiIndex)
        XCTAssertTrue(inspector.selectedContentViewControllerForTesting === inspector.aiAssistantViewController)
    }

    func testWorkbenchInspectorCommandHistoryFollowsCurrentTerminalAndPastesSelection() throws {
        let sink = RecordingWorkbenchTerminalEventSink()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first@example.com",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second@example.com",
            connectionKind: .ssh
        )
        let firstPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_first"))
        let secondPane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: "term_second"))
        firstPane.send(source: firstPane.terminalView, data: ArraySlice(Array("docker ps\n".utf8)))
        secondPane.send(source: secondPane.terminalView, data: ArraySlice(Array("uptime\n".utf8)))

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        _ = inspector.view
        inspector.selectCommandHistoryTab()
        XCTAssertEqual(inspector.commandHistoryViewController?.commandsForTesting, ["uptime"])

        workspace.selectTabForTesting(0)
        XCTAssertEqual(inspector.commandHistoryViewController?.commandsForTesting, ["docker ps"])

        inspector.commandHistoryViewController?.selectHistoryRowForTesting(0)
        inspector.commandHistoryViewController?.pasteSelectedCommandForTesting()

        XCTAssertEqual(sink.userInputEvents.suffix(1), [
            TerminalInputEvent(runtimeID: "term_first", bytes: Array("docker ps".utf8))
        ])
    }

    func testWorkbenchInspectorAIContextFollowsCurrentTerminalSelection() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first@example.com",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second@example.com",
            connectionKind: .ssh
        )
        controller.showAIAssistantFromToolbar(nil)

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(inspector.aiAssistantViewController?.contextTextForTesting.contains("second@example.com") == true)

        workspace.selectTabForTesting(0)

        XCTAssertTrue(inspector.aiAssistantViewController?.contextTextForTesting.contains("first@example.com") == true)
        XCTAssertFalse(inspector.aiAssistantViewController?.contextTextForTesting.contains("second@example.com") == true)
    }

    func testInspectorAISectionKeepsFullHeightAfterColumnFrameSync() throws {
        let inspector = InspectorViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 900))

        inspector.loadView()
        host.addSubview(inspector.view)
        inspector.view.frame = host.bounds
        inspector.view.autoresizingMask = [.width, .height]
        host.layoutSubtreeIfNeeded()

        let aiIndex = try XCTUnwrap(inspector.sectionLabelsForTesting.firstIndex(of: L10n.AI.title))
        inspector.selectSectionForTesting(aiIndex)
        inspector.synchronizeSelectedSectionLayoutAfterColumnResize(hostView: host)
        host.layoutSubtreeIfNeeded()

        let aiView = try XCTUnwrap(inspector.aiAssistantViewController?.view)
        let conversation = try XCTUnwrap(aiView.firstSubview(withIdentifier: "Stacio.AI.conversation"))
        let composer = try XCTUnwrap(aiView.firstSubview(withIdentifier: "Stacio.AI.composer"))

        XCTAssertGreaterThan(aiView.frame.height, 760)
        XCTAssertGreaterThan(conversation.frame.height, 560)
        XCTAssertEqual(composer.frame.minY, 14, accuracy: 1)
    }

    func testWorkbenchWindowKeepsWorkbenchContentOutOfAppKitContentSizeNegotiation() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertNil(window.contentViewController)
        XCTAssertTrue(controller.contentSplitViewController.view.isDescendant(of: try XCTUnwrap(window.contentView)))
    }

    func testWorkbenchWindowAllowsVerticalResizingForCompactDisplays() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertLessThanOrEqual(window.minSize.width, 1)
        XCTAssertLessThanOrEqual(window.minSize.height, 1)
        XCTAssertEqual(window.contentMinSize.width, 0, accuracy: 1)
        XCTAssertEqual(window.contentMinSize.height, 0, accuracy: 1)
        XCTAssertEqual(rootMinimumConstraintCount(in: window), 0)
        XCTAssertGreaterThan(window.maxSize.height, 10_000)
        let proposedSize = NSSize(width: 900, height: 235)
        let acceptedSize = controller.windowWillResize(
            window,
            to: proposedSize
        )
        XCTAssertEqual(acceptedSize.width, proposedSize.width, accuracy: 1)
        XCTAssertEqual(acceptedSize.height, proposedSize.height, accuracy: 1)
    }

    func testWorkbenchWindowCanShrinkAfterManualResizeWithoutPinnedContentConstraints() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let expandedFrame = NSRect(
            x: window.frame.minX,
            y: window.frame.minY - 320,
            width: window.frame.width + 420,
            height: window.frame.height + 320
        )

        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        _ = controller.windowWillResize(window, to: expandedFrame.size)
        window.setFrame(expandedFrame, display: false)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))

        XCTAssertEqual(rootMinimumConstraintCount(in: window), 0)

        let shrinkTarget = NSRect(
            x: expandedFrame.minX,
            y: expandedFrame.maxY - 430,
            width: 760,
            height: 430
        )
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let acceptedSize = controller.windowWillResize(window, to: shrinkTarget.size)
        window.setFrame(NSRect(origin: shrinkTarget.origin, size: acceptedSize), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))

        XCTAssertLessThan(window.frame.width, expandedFrame.width - 100)
        XCTAssertLessThan(window.frame.height, expandedFrame.height - 100)
        XCTAssertEqual(window.frame.width, shrinkTarget.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, shrinkTarget.height, accuracy: 1)
        XCTAssertEqual(rootMinimumConstraintCount(in: window), 0)
    }

    func testWorkbenchWindowKeepsSystemZoomResizeInsteadOfRestoringManagedFrame() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let zoomedFrame = NSRect(
            x: window.frame.minX - 80,
            y: window.frame.minY - 180,
            width: window.frame.width + 360,
            height: window.frame.height + 260
        )

        window.setFrame(zoomedFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))

        XCTAssertEqual(window.frame.width, zoomedFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, zoomedFrame.height, accuracy: 1)
    }

    func testWorkbenchWindowAcceptsSystemZoomTargetWithoutManagedRestore() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let startingFrame = NSRect(
            x: window.frame.minX + 80,
            y: window.frame.minY + 80,
            width: 1280,
            height: 680
        )
        window.setFrame(startingFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        let zoomTarget = NSRect(
            x: startingFrame.minX - 40,
            y: startingFrame.minY - 120,
            width: startingFrame.width + 280,
            height: startingFrame.height + 220
        )
        XCTAssertTrue(controller.windowShouldZoom(window, toFrame: zoomTarget))
        window.setFrame(zoomTarget, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(window.frame.width, zoomTarget.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, zoomTarget.height, accuracy: 1)
    }

    func testWorkbenchContentFillsWindowAfterManualVerticalResize() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let expandedFrame = NSRect(
            x: window.frame.minX,
            y: window.frame.minY - 360,
            width: window.frame.width + 420,
            height: window.frame.height + 360
        )

        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        window.setFrame(expandedFrame, display: false)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let contentBounds = try XCTUnwrap(window.contentView).bounds
        let splitFrame = controller.contentSplitViewController.view.frame
        XCTAssertEqual(splitFrame.origin.x, contentBounds.origin.x, accuracy: 1)
        XCTAssertEqual(splitFrame.origin.y, contentBounds.origin.y, accuracy: 1)
        XCTAssertEqual(splitFrame.width, contentBounds.width, accuracy: 1)
        XCTAssertEqual(splitFrame.height, contentBounds.height, accuracy: 1)

        let splitSubviews = controller.contentSplitViewController.splitView.arrangedSubviews
        XCTAssertGreaterThanOrEqual(splitSubviews.count, 2)
        for subview in splitSubviews where subview.isHidden == false {
            XCTAssertEqual(subview.frame.origin.y, contentBounds.origin.y, accuracy: 1)
            XCTAssertEqual(subview.frame.height, contentBounds.height, accuracy: 1)
        }
    }

    func testWorkbenchWindowStillAllowsVerticalResizingAfterOpeningSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "172.16.10.250",
                port: 22,
                username: "root",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let workbenchWindowCountBefore = NSApplication.shared.windows.filter { $0.title == "Stacio" }.count
        let frameBeforeStart = window.frame
        let minSizeBeforeStart = window.minSize
        let contentMinSizeBeforeStart = window.contentMinSize

        try controller.startRemoteSession(config: context.config, title: "root@172.16.10.250")
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))

        XCTAssertTrue(workspace.currentTerminalPane is RemoteTerminalPaneViewController)
        XCTAssertEqual(NSApplication.shared.windows.filter { $0.title == "Stacio" }.count, workbenchWindowCountBefore)
        XCTAssertIdentical(controller.window, window)
        XCTAssertEqual(window.minSize.width, minSizeBeforeStart.width, accuracy: 1)
        XCTAssertEqual(window.minSize.height, minSizeBeforeStart.height, accuracy: 1)
        XCTAssertEqual(window.contentMinSize.width, contentMinSizeBeforeStart.width, accuracy: 1)
        XCTAssertEqual(window.contentMinSize.height, contentMinSizeBeforeStart.height, accuracy: 1)
        XCTAssertEqual(window.frame.width, frameBeforeStart.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, frameBeforeStart.height, accuracy: 1)
        XCTAssertEqual(rootMinimumConstraintCount(in: window), 0)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertLessThanOrEqual(window.minSize.height, 1)
        XCTAssertGreaterThan(window.maxSize.height, 10_000)

        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let proposedSize = NSSize(width: 820, height: 420)
        let acceptedSize = controller.windowWillResize(
            window,
            to: proposedSize
        )
        XCTAssertEqual(acceptedSize.width, proposedSize.width, accuracy: 1)
        XCTAssertEqual(acceptedSize.height, proposedSize.height, accuracy: 1)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    }

    func testWorkbenchWindowActuallyShrinksVerticallyAfterOpeningSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "172.16.10.250",
                port: 22,
                username: "root",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let expandedFrameBeforeStart = NSRect(
            x: window.frame.minX,
            y: window.frame.maxY - 720,
            width: max(window.frame.width, 1120),
            height: 720
        )
        window.setFrame(expandedFrameBeforeStart, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        try controller.startRemoteSession(config: context.config, title: "root@172.16.10.250")
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        let frameBeforeResize = window.frame
        let targetHeight = max(window.minSize.height + 40, frameBeforeResize.height - 180)
        let targetWidth = max(window.minSize.width + 40, frameBeforeResize.width - 80)
        XCTAssertLessThan(targetHeight, frameBeforeResize.height)
        XCTAssertLessThan(targetWidth, frameBeforeResize.width)
        let proposedSize = NSSize(width: targetWidth, height: targetHeight)

        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let acceptedSize = controller.windowWillResize(window, to: proposedSize)
        let resizedFrame = NSRect(
            x: frameBeforeResize.minX,
            y: frameBeforeResize.maxY - acceptedSize.height,
            width: acceptedSize.width,
            height: acceptedSize.height
        )
        window.setFrame(resizedFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThan(window.frame.height, frameBeforeResize.height - 100)
        XCTAssertLessThan(window.frame.width, frameBeforeResize.width - 40)
        XCTAssertEqual(window.frame.width, acceptedSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, acceptedSize.height, accuracy: 1)
        XCTAssertEqual(rootMinimumConstraintCount(in: window), 0)
    }

    func testWorkbenchWindowAcceptsSystemZoomTargetAfterOpeningSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "172.16.10.250",
                port: 22,
                username: "root",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        let frameBeforeZoom = window.frame
        try controller.startRemoteSession(config: context.config, title: "root@172.16.10.250")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let zoomFrame = NSRect(
            x: window.frame.minX - 60,
            y: window.frame.minY - 120,
            width: window.frame.width + 240,
            height: window.frame.height + 220
        )

        XCTAssertTrue(controller.windowShouldZoom(window, toFrame: zoomFrame))
        window.setFrame(zoomFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(window.frame.width, zoomFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, zoomFrame.height, accuracy: 1)

        XCTAssertTrue(controller.windowShouldZoom(window, toFrame: frameBeforeZoom))
        window.setFrame(frameBeforeZoom, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(window.frame.width, frameBeforeZoom.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, frameBeforeZoom.height, accuracy: 1)
    }

    func testWorkbenchTitlebarDoubleClickZoomUsesVisibleDesktopAreaAfterOpeningSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "192.168.124.100",
                port: 22,
                username: "FengLee",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        try controller.startRemoteSession(config: context.config, title: "192.168.124.100")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let visibleFrame = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        let preZoomFrame = visibleFrame.insetBy(
            dx: min(80, visibleFrame.width * 0.08),
            dy: min(120, visibleFrame.height * 0.16)
        )
        window.setFrame(preZoomFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let acceptedPreZoomFrame = window.frame

        window.performZoom(nil)

        XCTAssertTrue(waitUntil { window.isZoomed })
        assertWindowFrame(window, equals: visibleFrame)
        let contentBounds = try XCTUnwrap(window.contentView).bounds
        XCTAssertEqual(controller.contentSplitViewController.view.frame.width, contentBounds.width, accuracy: 1)
        XCTAssertEqual(controller.contentSplitViewController.view.frame.height, contentBounds.height, accuracy: 1)

        window.performZoom(nil)

        XCTAssertTrue(waitUntil { window.isZoomed == false })
        assertWindowFrame(window, equals: acceptedPreZoomFrame)
    }

    func testWorkbenchContentFillsWindowAfterOpeningSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "172.16.10.250",
                port: 22,
                username: "root",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)

        _ = try controller.startRemoteSession(config: context.config, title: "root@172.16.10.250")
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))

        let contentBounds = try XCTUnwrap(window.contentView).bounds
        let splitFrame = controller.contentSplitViewController.view.frame
        XCTAssertEqual(splitFrame.origin.x, contentBounds.origin.x, accuracy: 1)
        XCTAssertEqual(splitFrame.origin.y, contentBounds.origin.y, accuracy: 1)
        XCTAssertEqual(splitFrame.width, contentBounds.width, accuracy: 1)
        XCTAssertEqual(splitFrame.height, contentBounds.height, accuracy: 1)

        let internalSplitFrame = controller.contentSplitViewController.splitView.frame
        XCTAssertEqual(internalSplitFrame.width, contentBounds.width, accuracy: 1)
        XCTAssertEqual(internalSplitFrame.height, contentBounds.height, accuracy: 1)

        let remotePane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertNotNil(window.contentView?.firstSubview(withIdentifier: "Stacio.Metrics.dashboard.\(remotePane.runtimeID)"))
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
    }

    func testWorkbenchWindowFrameStaysUserControlledAcrossSSHInspectorFilesTunnelsAndMetricsStates() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.FrameStability.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "172.16.10.250",
                port: 22,
                username: "root",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/root/app.log", size: 64, linkTarget: nil)
        ])
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            remoteSessionStarter: starter,
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 220, y: 240, width: 900, height: 430)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        try controller.startRemoteSession(config: context.config, title: "root@172.16.10.250")
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertWindowFrame(window, equals: userFrame)

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertWindowFrame(window, equals: userFrame)

        controller.showTunnelsFromToolbar(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertWindowFrame(window, equals: userFrame)

        controller.toggleDeviceDashboardFromToolbar(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertWindowFrame(window, equals: userFrame)
    }

    func testWorkbenchWindowClampsStaleShortManagedFrame() throws {
        let autosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.\(UUID().uuidString)")
        let defaultsKey = managedWorkbenchFrameDefaultsKey(autosaveName)
        UserDefaults.standard.set("283 677 1100 235 0 0 1800 1130 ", forKey: defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(),
            frameAutosaveName: autosaveName
        )

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        XCTAssertLessThanOrEqual(window.minSize.height, 1)
    }

    func testWorkbenchWindowClampsStaleOversizedManagedFrameToVisibleScreen() throws {
        let autosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.\(UUID().uuidString)")
        let defaultsKey = managedWorkbenchFrameDefaultsKey(autosaveName)
        UserDefaults.standard.set("0 0 5000 4000 0 0 1800 1130 ", forKey: defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(),
            frameAutosaveName: autosaveName
        )

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let visibleFrame = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame)
        XCTAssertLessThanOrEqual(window.frame.width, max(window.minSize.width, visibleFrame.width) + 1)
        XCTAssertLessThanOrEqual(window.frame.height, max(window.minSize.height, visibleFrame.height) + 1)
    }

    func testWorkbenchWindowRewritesOffscreenManagedFrameAfterClamping() throws {
        let autosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.\(UUID().uuidString)")
        let defaultsKey = managedWorkbenchFrameDefaultsKey(autosaveName)
        let visibleFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let staleFrame = NSRect(
            x: visibleFrame.maxX + 120,
            y: visibleFrame.maxY + 120,
            width: visibleFrame.width + 760,
            height: visibleFrame.height + 480
        )
        UserDefaults.standard.set(NSStringFromRect(staleFrame), forKey: defaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(),
            frameAutosaveName: autosaveName
        )

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let rewrittenFrame = NSRectFromString(try XCTUnwrap(UserDefaults.standard.string(forKey: defaultsKey)))
        XCTAssertFalse(rewrittenFrame.equalTo(staleFrame))
        assertWindowFrame(window, equals: rewrittenFrame)
    }

    func testWorkbenchWindowDefaultManagedFrameIgnoresLegacyNativeAutosave() throws {
        let legacyDefaultsKey = "NSWindow Frame Stacio.WorkbenchWindow"
        let legacyV2DefaultsKey = "NSWindow Frame Stacio.WorkbenchWindow.v2"
        UserDefaults.standard.set("283 677 1100 235 0 0 1800 1130 ", forKey: legacyDefaultsKey)
        UserDefaults.standard.set("283 677 1100 235 0 0 1800 1130 ", forKey: legacyV2DefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            UserDefaults.standard.removeObject(forKey: legacyV2DefaultsKey)
        }
        let controller = WorkbenchWindowController(workspaceViewController: WorkspaceViewController())

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyDefaultsKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyV2DefaultsKey))
    }

    func testWorkbenchWindowUsesFullSizeContentForUnifiedMacToolbar() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
    }

    func testWorkbenchWindowPersistsManagedFrameOnlyAfterUserResize() throws {
        let autosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.\(UUID().uuidString)")
        let defaultsKey = managedWorkbenchFrameDefaultsKey(autosaveName)
        defer {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(),
            frameAutosaveName: autosaveName
        )

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isRestorable)
        XCTAssertNil(UserDefaults.standard.object(forKey: defaultsKey))

        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let userFrame = NSRect(
            x: window.frame.minX,
            y: window.frame.maxY - 650,
            width: 1200,
            height: 650
        )
        window.setFrame(userFrame, display: false)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))

        let storedValue = try XCTUnwrap(UserDefaults.standard.string(forKey: defaultsKey))
        let storedFrame = NSRectFromString(storedValue)
        XCTAssertEqual(storedFrame.width, userFrame.width, accuracy: 1)
        XCTAssertEqual(storedFrame.height, userFrame.height, accuracy: 1)
    }

    func testWorkbenchWindowDoesNotFocusSidebarSearchOnLaunch() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        let searchField = try XCTUnwrap(
            window.contentView?.firstSubview(withIdentifier: "Stacio.Sidebar.search") as? NSSearchField
        )

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotIdentical(window.initialFirstResponder, searchField)
        XCTAssertNotEqual(searchField.currentEditor(), window.firstResponder)
    }

    func testWorkbenchSplitViewUsesFlushDocumentPaneSpacing() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let splitView = controller.contentSplitViewController.splitView
        let sidebarItem = controller.contentSplitViewController.splitViewItems[0]
        XCTAssertEqual(splitView.dividerStyle, .thin)
        XCTAssertLessThanOrEqual(splitView.dividerThickness, 8)
        XCTAssertEqual(sidebarItem.behavior, .default)
        XCTAssertTrue(sidebarItem.canCollapse)
        XCTAssertEqual(sidebarItem.minimumThickness, 220)
        XCTAssertEqual(sidebarItem.maximumThickness, 320)
        XCTAssertEqual(sidebarItem.preferredThicknessFraction, 0.20)
    }

    func testWorkbenchSidebarKeepsReadableDefaultWidthWithoutLockingWindowSize() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let sidebarView = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.first)
        XCTAssertFalse(sidebarView.isHidden)
        XCTAssertGreaterThanOrEqual(sidebarView.frame.width, 220)
        XCTAssertLessThanOrEqual(window.minSize.width, 1)
        XCTAssertLessThanOrEqual(window.minSize.height, 1)
        XCTAssertEqual(rootMinimumConstraintCount(in: window), 0)

        let proposedSize = NSSize(width: 520, height: 300)
        let acceptedSize = controller.windowWillResize(window, to: proposedSize)
        XCTAssertEqual(acceptedSize.width, proposedSize.width, accuracy: 1)
        XCTAssertEqual(acceptedSize.height, proposedSize.height, accuracy: 1)
    }

    func testWorkbenchSidebarStaysReadableAfterOpeningSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "192.168.124.100",
                port: 22,
                username: "FengLee",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let frameBeforeStart = window.frame

        try controller.startRemoteSession(config: context.config, title: "192.168.124.100")
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let sidebarView = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.first)
        XCTAssertFalse(sidebarView.isHidden)
        XCTAssertGreaterThanOrEqual(sidebarView.frame.width, 220)
        assertWindowFrame(window, equals: frameBeforeStart)
    }

    func testWorkbenchSidebarStaysReadableWhenInspectorOpensAndClosesAfterSSHSession() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            startsDeviceMetricsPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "192.168.124.100",
                port: 22,
                username: "FengLee",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingWorkbenchTunnelContextBuilder(context: context),
            liveShellStarter: HostRuntimeLiveShellStarter(),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-tests.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteSessionStarter: starter
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        try controller.startRemoteSession(config: context.config, title: "192.168.124.100")
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let frameAfterSessionStart = window.frame

        controller.toggleInspectorFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let sidebarView = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.first)
        XCTAssertFalse(sidebarView.isHidden)
        XCTAssertGreaterThanOrEqual(sidebarView.frame.width, 220)
        assertWindowFrame(window, equals: frameAfterSessionStart)

        controller.toggleInspectorFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThanOrEqual(sidebarView.frame.width, 220)
        assertWindowFrame(window, equals: frameAfterSessionStart)
    }

    func testWorkbenchInspectorOpensToCompactFilesWidthOnWideWindowWithoutChangingFrame() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 80, y: 120, width: 1600, height: 880)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspectorView = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.last)
        XCTAssertFalse(inspectorView.isHidden)
        XCTAssertGreaterThanOrEqual(inspectorView.frame.width, 300)
        XCTAssertLessThanOrEqual(inspectorView.frame.width, 420)
        XCTAssertLessThanOrEqual(controller.contentSplitViewController.splitViewItems[2].minimumThickness, 340)
        assertWindowFrame(window, equals: userFrame)
    }

    func testInspectorToolbarPanelsShareFilesDefaultWidth() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.SharedInspectorDefault.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 80, y: 120, width: 1600, height: 880)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let filesWidth = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.last).frame.width

        controller.showFilesFromToolbar(nil)
        controller.showTunnelsFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let tunnelsWidth = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.last).frame.width

        controller.showTunnelsFromToolbar(nil)
        controller.showAIAssistantFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let aiWidth = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.last).frame.width

        XCTAssertEqual(filesWidth, tunnelsWidth, accuracy: 3)
        XCTAssertEqual(filesWidth, aiWidth, accuracy: 3)
        XCTAssertLessThanOrEqual(filesWidth, 420)
        assertWindowFrame(window, equals: userFrame)
    }

    func testInspectorToolbarPanelsDoNotLoopWindowLayoutOnFullDisplayCycle() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.InspectorDisplayCycle.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 0, y: 62, width: 1_800, height: 1_068)
        window.setFrame(userFrame, display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        let acceptedUserFrame = window.frame

        controller.showFilesFromToolbar(nil)
        controller.showAIAssistantFromToolbar(nil)
        controller.showTunnelsFromToolbar(nil)
        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        let inspectorView = try XCTUnwrap(controller.contentSplitViewController.splitView.arrangedSubviews.last)
        XCTAssertFalse(inspectorView.isHidden)
        XCTAssertGreaterThan(inspectorView.frame.width, 0)
        assertWindowFrame(window, equals: acceptedUserFrame)
    }

    func testWorkbenchInspectorOpensToUsableWidthOnMediumWindowWithoutChangingFrame() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 80, y: 120, width: 1020, height: 760)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let splitView = controller.contentSplitViewController.splitView
        let inspectorView = try XCTUnwrap(splitView.arrangedSubviews.last)
        XCTAssertFalse(inspectorView.isHidden)
        XCTAssertGreaterThanOrEqual(inspectorView.frame.width, 300)
        XCTAssertLessThanOrEqual(inspectorView.frame.width, 360)

        controller.setInspectorDividerPositionForTesting(
            splitView.bounds.width - 460 - splitView.dividerThickness
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThanOrEqual(inspectorView.frame.width, 430)
        assertWindowFrame(window, equals: userFrame)
    }

    func testFilesInspectorCanBeManuallyNarrowedAfterOpeningAndAfterBeingWidenedWithoutResizingWindow() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let splitView = controller.contentSplitViewController.splitView
        let initialInspectorWidth = try XCTUnwrap(splitView.arrangedSubviews.last).frame.width
        XCTAssertLessThanOrEqual(initialInspectorWidth, 420)

        controller.setInspectorDividerPositionForTesting(
            splitView.bounds.width - max(initialInspectorWidth + 260, 640) - splitView.dividerThickness
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let widenedInspectorWidth = try XCTUnwrap(splitView.arrangedSubviews.last).frame.width
        XCTAssertGreaterThan(widenedInspectorWidth, initialInspectorWidth + 180)
        XCTAssertLessThanOrEqual(controller.contentSplitViewController.splitViewItems[2].minimumThickness, 340)

        controller.setInspectorDividerPositionForTesting(
            splitView.bounds.width - 460 - splitView.dividerThickness
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspectorView = try XCTUnwrap(splitView.arrangedSubviews.last)
        XCTAssertLessThanOrEqual(inspectorView.frame.width, 520)

        controller.setInspectorDividerPositionForTesting(
            splitView.bounds.width - 340 - splitView.dividerThickness
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThanOrEqual(inspectorView.frame.width, 520)
        assertWindowFrame(window, equals: userFrame)
    }

    func testInspectorDividerDragPathUpdatesPanelWidthBeforePinnedLayoutRefresh() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showAIAssistantFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let splitView = controller.contentSplitViewController.splitView
        let inspectorView = try XCTUnwrap(splitView.arrangedSubviews.last)
        XCTAssertLessThanOrEqual(inspectorView.frame.width, 420)

        let requestedInspectorWidth: CGFloat = 720
        let proposedPosition = splitView.bounds.width - requestedInspectorWidth - splitView.dividerThickness
        let constrainedPosition = controller.contentSplitViewController.splitView(
            splitView,
            constrainSplitPosition: proposedPosition,
            ofSubviewAt: 1
        )
        XCTAssertEqual(constrainedPosition, proposedPosition, accuracy: 1)

        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(inspectorView.frame.width, requestedInspectorWidth, accuracy: 3)
        assertWindowFrame(window, equals: userFrame)
    }

    func testPinnedSplitViewUsesWideDividerHitAreaForDragging() throws {
        let proposedRect = NSRect(x: 596, y: 0, width: 8, height: 600)

        let effectiveRect = StacioPinnedSplitViewController.expandedDividerEffectiveRect(
            proposedRect,
            isVertical: true
        )

        XCTAssertLessThanOrEqual(effectiveRect.minX, proposedRect.minX - 6)
        XCTAssertGreaterThanOrEqual(effectiveRect.maxX, proposedRect.maxX + 6)
        XCTAssertEqual(effectiveRect.minY, proposedRect.minY)
        XCTAssertEqual(effectiveRect.maxY, proposedRect.maxY)
    }

    func testPinnedSplitViewRefreshDoesNotScheduleLayoutWhenFrameAlreadyMatchesContainer() throws {
        let controller = StacioPinnedSplitViewController()
        _ = controller.view
        let container = try XCTUnwrap(controller.splitView.superview)
        container.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        controller.splitView.frame = container.bounds

        let didRefresh = controller.portDeskRefreshPinnedSplitViewLayout()

        XCTAssertFalse(didRefresh)
        XCTAssertEqual(controller.splitView.frame, container.bounds)
    }

    func testPinnedSplitViewRunsAfterLayoutCallbackOutsideSplitViewLayoutPass() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )
        controller.loadWindow()
        let splitController = controller.contentSplitViewController as? StacioPinnedSplitViewController
        let pinnedSplitController = try XCTUnwrap(splitController)
        let splitView = try XCTUnwrap(pinnedSplitController.splitView as? StacioPinnedSplitView)
        var callbackRanInsideLayout = false
        var callbackCount = 0
        pinnedSplitController.afterPinnedSplitViewLayout = { splitView in
            callbackCount += 1
            callbackRanInsideLayout = (splitView as? StacioPinnedSplitView)?.isPerformingLayoutPass == true
        }

        XCTAssertEqual(callbackCount, 0)
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()
        XCTAssertEqual(callbackCount, 0)

        XCTAssertTrue(waitUntil { callbackCount == 1 })
        XCTAssertFalse(callbackRanInsideLayout)
    }

    func testWorkbenchDoesNotInstallSeparateOverlayResizeHandleForInspectorDivider() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 40, y: 80, width: 1_640, height: 880), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(window.contentView?.firstSubview(withIdentifier: "Stacio.Workbench.inspectorResizeHandle"))

        controller.showTunnelsFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(window.contentView?.firstSubview(withIdentifier: "Stacio.Workbench.inspectorResizeHandle"))

        controller.showAIAssistantFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(window.contentView?.firstSubview(withIdentifier: "Stacio.Workbench.inspectorResizeHandle"))
    }

    func testFilesInspectorContentFillsInspectorColumnAfterPanelIsWidened() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let splitView = controller.contentSplitViewController.splitView
        controller.setInspectorDividerPositionForTesting(
            splitView.bounds.width - 760 - splitView.dividerThickness
        )
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspectorView = try XCTUnwrap(splitView.arrangedSubviews.last)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        let filesFrame = files.view.convert(files.view.bounds, to: inspectorView)
        let browserFrame = files.fileBrowserPaneViewForTesting.convert(
            files.fileBrowserPaneViewForTesting.bounds,
            to: inspectorView
        )

        XCTAssertEqual(filesFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(filesFrame.width, inspectorView.bounds.width, accuracy: 1)
        XCTAssertEqual(browserFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(browserFrame.width, inspectorView.bounds.width, accuracy: 1)
    }

    func testInspectorRestoresUserAdjustedWidthForAllToolbarPanels() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.SharedInspectorStored.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let firstController = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        firstController.showWindow(nil)
        defer { firstController.close() }
        let firstWindow = try XCTUnwrap(firstController.window)
        let userFrame = NSRect(x: 40, y: 80, width: 1_600, height: 860)
        firstWindow.setFrame(userFrame, display: false)
        firstController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: firstWindow))
        firstController.showFilesFromToolbar(nil)
        firstWindow.layoutIfNeeded()
        firstController.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let firstSplitView = firstController.contentSplitViewController.splitView
        firstController.setInspectorDividerPositionForTesting(
            firstSplitView.bounds.width - 460 - firstSplitView.dividerThickness
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let savedInspectorWidth = try XCTUnwrap(firstSplitView.arrangedSubviews.last).frame.width
        XCTAssertEqual(savedInspectorWidth, 460, accuracy: 3)
        firstController.saveSplitColumnWidthsForTesting()

        let secondController = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )
        secondController.showWindow(nil)
        defer { secondController.close() }
        let secondWindow = try XCTUnwrap(secondController.window)
        secondWindow.setFrame(userFrame, display: false)
        secondController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: secondWindow))

        secondController.showAIAssistantFromToolbar(nil)
        secondWindow.layoutIfNeeded()
        secondController.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let restoredInspectorWidth = try XCTUnwrap(secondController.contentSplitViewController.splitView.arrangedSubviews.last).frame.width
        XCTAssertEqual(restoredInspectorWidth, savedInspectorWidth, accuracy: 3)
        XCTAssertEqual(secondController.inspectorViewControllerForTesting?.selectedTabLabelForTesting, "AI")
    }

    func testWorkbenchInspectorDividerAllowsUserToWidenPanelWithoutResizingWindow() throws {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let splitView = controller.contentSplitViewController.splitView
        controller.setInspectorDividerPositionForTesting(
            splitView.bounds.width - 1_420 - splitView.dividerThickness
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspectorView = try XCTUnwrap(splitView.arrangedSubviews.last)
        XCTAssertGreaterThanOrEqual(inspectorView.frame.width, 1_380)
        assertWindowFrame(window, equals: userFrame)
    }

    func testClosingEmbeddedFilesEditorShrinksInspectorBackToFileBrowserWidth() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.FilesEditorClose.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        let fileURL = try makeTemporaryWorkbenchFile(name: "sshd_config", contents: "PermitRootLogin no\n")
        let splitView = controller.contentSplitViewController.splitView
        let workspaceView = splitView.arrangedSubviews[1]
        let inspectorView = splitView.arrangedSubviews[2]

        files.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let editingInspectorWidth = inspectorView.frame.width
        let editingWorkspaceWidth = workspaceView.frame.width
        let fileBrowserWidthWhileEditing = files.fileBrowserPaneViewForTesting
            .convert(files.fileBrowserPaneViewForTesting.bounds, to: inspector.view)
            .width

        XCTAssertGreaterThanOrEqual(editingInspectorWidth, 860)
        XCTAssertGreaterThanOrEqual(fileBrowserWidthWhileEditing, 240)

        XCTAssertTrue(files.closeEmbeddedEditorForTesting())
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let closedInspectorWidth = inspectorView.frame.width
        let closedWorkspaceWidth = workspaceView.frame.width
        let maximumCompactWidth = max(fileBrowserWidthWhileEditing + 240, 520)
        XCTAssertLessThanOrEqual(closedInspectorWidth, maximumCompactWidth)
        XCTAssertGreaterThan(closedWorkspaceWidth, editingWorkspaceWidth + 300)
        XCTAssertLessThan(closedInspectorWidth, editingInspectorWidth - 300)
        assertWindowFrame(window, equals: userFrame)
    }

    func testInspectorHidesSectionRowAndKeepsEditorActionsWithEditor() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.FilesEditorHeader.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        let fileURL = try makeTemporaryWorkbenchFile(name: "app.env", contents: "APP_ENV=production\n")

        files.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(inspector.sectionControlForTesting.enclosingScrollView)
        let editorActions = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Inspector.editorActions")
        )
        let inspectorHeader = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Inspector.header")
        )
        let editor = try XCTUnwrap(files.embeddedEditorViewControllerForTesting)
        let editorActionsFrame = editorActions.convert(editorActions.bounds, to: contentView)
        let inspectorHeaderFrame = inspectorHeader.convert(inspectorHeader.bounds, to: contentView)
        let editorFrame = editor.view.convert(editor.view.bounds, to: contentView)
        let browserFrame = files.fileBrowserPaneViewForTesting.convert(
            files.fileBrowserPaneViewForTesting.bounds,
            to: contentView
        )

        XCTAssertGreaterThanOrEqual(editorActionsFrame.minX, editorFrame.minX + 8)
        XCTAssertLessThanOrEqual(editorActionsFrame.maxX, editorFrame.maxX - 8)
        XCTAssertLessThanOrEqual(editorActionsFrame.maxX, browserFrame.minX)
        XCTAssertEqual(editorActionsFrame.midY, inspectorHeaderFrame.midY, accuracy: 2)
        XCTAssertFalse(inspectorHeader.isHidden)
        XCTAssertGreaterThanOrEqual(editorFrame.width, 360)
        XCTAssertGreaterThanOrEqual(browserFrame.width, 240)

        XCTAssertTrue(files.closeEmbeddedEditorForTesting())
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(editorActions.isHidden)
        XCTAssertTrue(inspectorHeader.isHidden)
        assertWindowFrame(window, equals: userFrame)
    }

    func testCollapsingEmbeddedFilesEditorKeepsFileBrowserSizeAndFloatsExpandButtonAtItsLeftEdge() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.FilesEditorCollapse.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        let fileURL = try makeTemporaryWorkbenchFile(name: "sshd_config", contents: "PermitRootLogin no\n")
        let splitView = controller.contentSplitViewController.splitView
        let workspaceView = splitView.arrangedSubviews[1]
        let inspectorView = splitView.arrangedSubviews[2]

        files.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let innerSplitView = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.editorSplit") as? NSSplitView
        )
        innerSplitView.setPosition(560, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let editingInspectorWidth = inspectorView.frame.width
        let editingWorkspaceWidth = workspaceView.frame.width
        let editingBrowserFrame = files.fileBrowserPaneViewForTesting
            .convert(files.fileBrowserPaneViewForTesting.bounds, to: window.contentView)

        XCTAssertGreaterThanOrEqual(editingInspectorWidth, 860)
        XCTAssertGreaterThanOrEqual(editingBrowserFrame.width, 320)

        files.collapseEmbeddedCapabilityForTesting()
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let collapsedBrowserFrame = files.fileBrowserPaneViewForTesting
            .convert(files.fileBrowserPaneViewForTesting.bounds, to: window.contentView)
        let expandButton = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.expandEmbeddedCapability") as? NSButton
        )
        let expandButtonFrame = expandButton.convert(expandButton.bounds, to: window.contentView)

        XCTAssertTrue(files.isEmbeddedCapabilityCollapsedForTesting)
        XCTAssertLessThan(inspectorView.frame.width, editingInspectorWidth - 300)
        XCTAssertGreaterThan(workspaceView.frame.width, editingWorkspaceWidth + 300)
        XCTAssertEqual(collapsedBrowserFrame.minX, editingBrowserFrame.minX, accuracy: 80)
        XCTAssertEqual(collapsedBrowserFrame.width, editingBrowserFrame.width, accuracy: 80)
        XCTAssertLessThanOrEqual(expandButtonFrame.minX, collapsedBrowserFrame.minX + 20)
        XCTAssertLessThanOrEqual(expandButtonFrame.maxX, collapsedBrowserFrame.minX + 56)

        expandButton.performClick(nil as Any?)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(files.isEmbeddedCapabilityCollapsedForTesting)
        XCTAssertGreaterThanOrEqual(inspectorView.frame.width, editingInspectorWidth - 80)
        XCTAssertLessThanOrEqual(workspaceView.frame.width, editingWorkspaceWidth + 80)
        XCTAssertEqual(files.embeddedEditorViewControllerForTesting?.activeFileNameForTesting, "sshd_config")
        assertWindowFrame(window, equals: userFrame)
    }

    func testReopeningEmbeddedFilesEditorAfterCloseRestoresWideResizableInspector() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.FilesEditorReopen.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )

        controller.showWindow(nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let userFrame = NSRect(x: 40, y: 80, width: 2_048, height: 900)
        window.setFrame(userFrame, display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.showFilesFromToolbar(nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        let firstURL = try makeTemporaryWorkbenchFile(name: "first.conf", contents: "enabled=true\n")
        let secondURL = try makeTemporaryWorkbenchFile(name: "second.conf", contents: "enabled=false\n")
        let splitView = controller.contentSplitViewController.splitView
        let inspectorView = splitView.arrangedSubviews[2]

        files.presentEmbeddedEditor(localURL: firstURL, saveHandler: nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let firstEditor = try XCTUnwrap(files.embeddedEditorViewControllerForTesting)
        let firstEditorWidth = firstEditor.view.convert(firstEditor.view.bounds, to: inspector.view).width
        XCTAssertGreaterThanOrEqual(firstEditorWidth, 680)
        XCTAssertTrue(files.closeEmbeddedEditorForTesting())
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertLessThan(inspectorView.frame.width, 560)

        files.presentEmbeddedEditor(localURL: secondURL, saveHandler: nil)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let reopenedEditor = try XCTUnwrap(files.embeddedEditorViewControllerForTesting)
        let reopenedEditorFrame = reopenedEditor.view.convert(reopenedEditor.view.bounds, to: inspector.view)
        let reopenedBrowserFrame = files.fileBrowserPaneViewForTesting.convert(
            files.fileBrowserPaneViewForTesting.bounds,
            to: inspector.view
        )
        XCTAssertGreaterThanOrEqual(inspectorView.frame.width, 860)
        XCTAssertGreaterThanOrEqual(reopenedEditorFrame.width, 680)
        XCTAssertGreaterThanOrEqual(reopenedBrowserFrame.width, 240)

        let innerSplitView = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.editorSplit") as? NSSplitView
        )
        innerSplitView.setPosition(1_000, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let draggedEditorFrame = reopenedEditor.view.convert(reopenedEditor.view.bounds, to: inspector.view)
        let draggedBrowserFrame = files.fileBrowserPaneViewForTesting.convert(
            files.fileBrowserPaneViewForTesting.bounds,
            to: inspector.view
        )
        XCTAssertGreaterThanOrEqual(draggedEditorFrame.width, reopenedEditorFrame.width)
        XCTAssertLessThanOrEqual(draggedBrowserFrame.width, 320)
        assertWindowFrame(window, equals: userFrame)
    }

    func testWorkbenchRestoresManuallyAdjustedSidebarAndInspectorWidths() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.SplitWidthTest.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }

        let firstController = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )
        firstController.showWindow(nil as Any?)
        defer { firstController.close() }
        let firstWindow = try XCTUnwrap(firstController.window)
        let userFrame = NSRect(x: 80, y: 120, width: 1680, height: 860)
        firstWindow.setFrame(userFrame, display: false)
        firstController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: firstWindow))
        firstController.showFilesFromToolbar(nil as Any?)
        firstWindow.layoutIfNeeded()
        firstController.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let firstSplitView = firstController.contentSplitViewController.splitView
        firstController.setInspectorDividerPositionForTesting(
            firstSplitView.bounds.width - 640 - firstSplitView.dividerThickness
        )
        firstSplitView.setPosition(300, ofDividerAt: 0)
        firstSplitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let savedSidebarWidth = firstSplitView.arrangedSubviews.first?.frame.width ?? 0
        let savedInspectorWidth = firstSplitView.arrangedSubviews.last?.frame.width ?? 0
        XCTAssertGreaterThan(savedSidebarWidth, 250)
        XCTAssertGreaterThan(savedInspectorWidth, 580)
        firstController.saveSplitColumnWidthsForTesting()

        let secondController = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )
        secondController.showWindow(nil as Any?)
        defer { secondController.close() }
        let secondWindow = try XCTUnwrap(secondController.window)
        secondWindow.setFrame(userFrame, display: false)
        secondController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: secondWindow))
        secondController.showFilesFromToolbar(nil as Any?)
        secondWindow.layoutIfNeeded()
        secondController.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let restoredSubviews = secondController.contentSplitViewController.splitView.arrangedSubviews
        XCTAssertEqual(restoredSubviews.first?.frame.width ?? 0, savedSidebarWidth, accuracy: 3)
        XCTAssertEqual(restoredSubviews.last?.frame.width ?? 0, savedInspectorWidth, accuracy: 3)
    }

    func testWorkbenchInspectorAllowsAndRestoresUserChosenExtremeWidth() throws {
        let frameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.FreeInspectorWidthTest.\(UUID().uuidString)")
        defer {
            UserDefaults.standard.removeObject(forKey: managedWorkbenchFrameDefaultsKey(frameAutosaveName))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "sidebar"))
            UserDefaults.standard.removeObject(forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector"))
        }

        let firstController = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )
        firstController.showWindow(nil as Any?)
        defer { firstController.close() }
        let firstWindow = try XCTUnwrap(firstController.window)
        let userFrame = NSRect(x: 80, y: 120, width: 2_400, height: 860)
        firstWindow.setFrame(userFrame, display: false)
        firstController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: firstWindow))
        firstController.showFilesFromToolbar(nil as Any?)
        firstWindow.layoutIfNeeded()
        firstController.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let realizedWindowFrame = firstWindow.frame

        let firstSplitView = firstController.contentSplitViewController.splitView
        let requestedInspectorWidth = min(1_900, max(0, firstSplitView.bounds.width - 500))
        XCTAssertGreaterThan(requestedInspectorWidth, 1_500)
        firstController.setInspectorDividerPositionForTesting(
            firstSplitView.bounds.width - requestedInspectorWidth - firstSplitView.dividerThickness
        )
        firstSplitView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let savedInspectorWidth = firstSplitView.arrangedSubviews.last?.frame.width ?? 0
        XCTAssertEqual(savedInspectorWidth, requestedInspectorWidth, accuracy: 3)
        firstController.saveSplitColumnWidthsForTesting()
        XCTAssertEqual(
            UserDefaults.standard.double(
                forKey: workbenchSplitWidthDefaultsKeyForTesting(frameAutosaveName, column: "inspector")
            ),
            Double(savedInspectorWidth),
            accuracy: 3
        )

        let secondController = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            frameAutosaveName: frameAutosaveName
        )
        secondController.showWindow(nil as Any?)
        defer { secondController.close() }
        let secondWindow = try XCTUnwrap(secondController.window)
        secondWindow.setFrame(realizedWindowFrame, display: false)
        secondController.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: secondWindow))
        secondController.showFilesFromToolbar(nil as Any?)
        secondWindow.layoutIfNeeded()
        secondController.contentSplitViewController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let secondSplitView = secondController.contentSplitViewController.splitView
        let restoredInspectorWidth = secondSplitView.arrangedSubviews.last?.frame.width ?? 0
        let restoredSidebarWidth = secondSplitView.arrangedSubviews.first?.frame.width ?? 0
        let maximumRestorableInspectorWidth = max(
            0,
            secondSplitView.bounds.width
                - restoredSidebarWidth
                - 248
                - secondSplitView.dividerThickness * 2
        )
        XCTAssertEqual(
            restoredInspectorWidth,
            min(savedInspectorWidth, maximumRestorableInspectorWidth),
            accuracy: 3
        )
    }

    func testSidebarToolbarItemTogglesSourceListPane() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[0].isCollapsed)

        controller.toggleSidebarFromToolbar(nil)

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[0].isCollapsed)

        controller.toggleSidebarFromToolbar(nil)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[0].isCollapsed)
    }

    func testSidebarToggleLivesAsFirstVisibleToolbarItemAndTogglesPane() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let toolbarItems = try XCTUnwrap(window.toolbar?.items)
        XCTAssertEqual(toolbarItems.first?.itemIdentifier.rawValue, "Stacio.Toolbar.sidebar")
        XCTAssertEqual(toolbarItems.dropFirst().first?.itemIdentifier, .flexibleSpace)

        let sidebarButton = try sidebarToolbarButton(in: controller)

        XCTAssertEqual(sidebarButton.toolTip, "显示或隐藏侧边栏")
        XCTAssertEqual(sidebarButton.action, #selector(WorkbenchWindowController.toggleSidebarFromToolbar(_:)))
        XCTAssertFalse(sidebarButton.isHidden)
        XCTAssertEqual(sidebarButton.alphaValue, 1)
        XCTAssertFalse(sidebarButton.isBordered)
        XCTAssertNotNil(sidebarButton.image)
        XCTAssertLessThanOrEqual(sidebarButton.frame.width, 26)
        XCTAssertLessThanOrEqual(sidebarButton.frame.height, 26)
        XCTAssertNil(sidebarButton.layer?.backgroundColor)
        XCTAssertEqual(sidebarButton.layer?.borderWidth, 0)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[0].isCollapsed)

        sidebarButton.performClick(nil as Any?)

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[0].isCollapsed)

        sidebarButton.performClick(nil as Any?)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[0].isCollapsed)
    }

    func testCollapsedSidebarTemporarilyExpandsWhilePointerHoversLeadingToggle() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let sidebarButton = try sidebarToolbarButton(in: controller)
        let sidebarItem = controller.contentSplitViewController.splitViewItems[0]

        sidebarButton.performClick(nil as Any?)
        XCTAssertTrue(sidebarItem.isCollapsed)

        sidebarButton.simulateTitlebarSidebarPointerExitedForTesting()
        sidebarButton.simulateTitlebarSidebarPointerEnteredForTesting()

        XCTAssertFalse(sidebarItem.isCollapsed)

        sidebarButton.simulateTitlebarSidebarPointerExitedForTesting()

        XCTAssertTrue(sidebarItem.isCollapsed)

        sidebarButton.simulateTitlebarSidebarPointerEnteredForTesting()
        sidebarButton.performClick(nil as Any?)
        sidebarButton.simulateTitlebarSidebarPointerExitedForTesting()

        XCTAssertFalse(sidebarItem.isCollapsed)
    }

    func testUpdatePromptToolbarButtonAppearsAfterSidebarAndTracksDownloadProgress() throws {
        let updateController = RecordingSparkleUpdateButtonController()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            sparkleUpdateController: updateController
        )

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let identifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        XCTAssertEqual(identifiers.prefix(3), [
            "Stacio.Toolbar.sidebar",
            "Stacio.Toolbar.updatePrompt",
            NSToolbarItem.Identifier.flexibleSpace.rawValue
        ])
        XCTAssertEqual(updateController.probeCount, 1)

        let updateButton = try updatePromptToolbarButton(in: controller)
        XCTAssertTrue(updateButton.isHidden)
        XCTAssertEqual(updateButton.attributedTitle.string, "")

        updateController.publish(.available(SparkleUpdatePromptInfo(version: "0.14.0", build: "50")))

        XCTAssertFalse(updateButton.isHidden)
        XCTAssertEqual(updateButton.attributedTitle.string, "更新")
        XCTAssertEqual(updateButton.action, #selector(WorkbenchWindowController.updatePromptButtonPressed(_:)))
        XCTAssertEqual(updateButton.accessibilityLabel(), "发现 Stacio 更新 0.14.0 Build 50")

        updateButton.performClick(nil as Any?)

        XCTAssertEqual(updateController.installCount, 1)

        updateController.publish(.downloading(progress: 0.42))

        XCTAssertEqual(updateButton.attributedTitle.string, "正在下载 42%")
        XCTAssertEqual(updateButton.accessibilityLabel(), "正在下载 Stacio 更新 42%")

        updateController.publish(.installing)

        XCTAssertEqual(updateButton.attributedTitle.string, "正在安装")
    }

    func testUpdatePromptToolbarButtonIsDisabledWhileUpdateIsInProgress() throws {
        let updateController = RecordingSparkleUpdateButtonController()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            sparkleUpdateController: updateController
        )

        controller.loadWindow()

        let updateButton = try updatePromptToolbarButton(in: controller)
        updateController.publish(.available(SparkleUpdatePromptInfo(version: "0.14.0", build: "50")))
        XCTAssertTrue(updateButton.isEnabled)

        updateController.publish(.downloading(progress: 0.42))
        XCTAssertFalse(updateButton.isEnabled)
        updateButton.performClick(nil as Any?)

        updateController.publish(.extracting(progress: 0.7))
        XCTAssertFalse(updateButton.isEnabled)
        updateButton.performClick(nil as Any?)

        updateController.publish(.installing)
        XCTAssertFalse(updateButton.isEnabled)
        updateButton.performClick(nil as Any?)

        XCTAssertEqual(updateController.installCount, 0)
    }

    func testShowWindowCreatesProgrammaticMainWindow() {
        let controller = WorkbenchWindowController()

        controller.showWindow(nil)
        defer { controller.close() }

        XCTAssertEqual(controller.window?.title, "Stacio")
        XCTAssertTrue(controller.window?.isVisible ?? false)
    }

    func testToolbarContainsCoreCommands() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        XCTAssertEqual(controller.window?.toolbar?.displayMode, .iconOnly)
        let items = controller.window?.toolbar?.items ?? []
        let identifiers = items.map { $0.itemIdentifier.rawValue }
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.sidebar"))
        XCTAssertFalse(identifiers.contains("Stacio.Toolbar.quickConnect"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.newSession"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.split"))
        XCTAssertFalse(identifiers.contains("Stacio.Toolbar.closeTerminal"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.panels"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.files"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.browser"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.tunnels"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.deviceDashboard"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.aiAssistant"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.inspector"))
        XCTAssertFalse(identifiers.contains("Stacio.Toolbar.importSessions"))
        XCTAssertTrue(identifiers.contains("Stacio.Toolbar.multiExec"))
        let commandItems = items.filter {
            $0.itemIdentifier != .flexibleSpace && $0.itemIdentifier != .space
        }
        XCTAssertEqual(commandItems.map(\.label), ["侧边栏", "新建会话", "多执行", "分屏", "文件", "浏览器", "隧道", "设备看板", "AI", "面板", "检查器"])
        XCTAssertEqual(
            commandItems.map(\.toolTip),
            ["显示或隐藏侧边栏", "新建会话", "批量同步输入到多个终端", "终端分屏布局", "文件", "浏览器", "隧道", "显示或隐藏当前 SSH 标签页设备看板", "AI 助手", "打开文件、浏览器、隧道、诊断、宏、历史命令、设备看板或 AI", "检查器"]
        )
        XCTAssertNil(items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.closeTerminal" })
        XCTAssertEqual(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.files" }?.action,
            #selector(WorkbenchWindowController.showFilesFromToolbar(_:))
        )
        XCTAssertEqual(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.browser" }?.action,
            #selector(WorkbenchWindowController.showBrowserFromToolbar(_:))
        )
        XCTAssertEqual(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.tunnels" }?.action,
            #selector(WorkbenchWindowController.showTunnelsFromToolbar(_:))
        )
        XCTAssertEqual(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.deviceDashboard" }?.action,
            #selector(WorkbenchWindowController.toggleDeviceDashboardFromToolbar(_:))
        )
        XCTAssertEqual(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.aiAssistant" }?.action,
            #selector(WorkbenchWindowController.showAIAssistantFromToolbar(_:))
        )
        let panelsItem = try XCTUnwrap(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.panels" } as? NSMenuToolbarItem
        )
        let panelsMenu = try XCTUnwrap(panelsItem.menu)
        let panelMenuItems = panelsMenu.items.filter { $0.isSeparatorItem == false }
        XCTAssertEqual(panelMenuItems.map(\.title), ["文件", "浏览器", "隧道", "设备看板", "诊断", "宏", "历史命令", "AI"])
        XCTAssertEqual(panelMenuItems.map(\.action), [
            #selector(WorkbenchWindowController.showFilesFromToolbar(_:)),
            #selector(WorkbenchWindowController.showBrowserFromToolbar(_:)),
            #selector(WorkbenchWindowController.showTunnelsFromToolbar(_:)),
            #selector(WorkbenchWindowController.toggleDeviceDashboardFromToolbar(_:)),
            #selector(WorkbenchWindowController.showDiagnosticsFromToolbar(_:)),
            #selector(WorkbenchWindowController.showTerminalMacrosFromToolbar(_:)),
            #selector(WorkbenchWindowController.showCommandHistoryFromToolbar(_:)),
            #selector(WorkbenchWindowController.showAIAssistantFromToolbar(_:))
        ])
        XCTAssertEqual(
            items.first { $0.itemIdentifier.rawValue == "Stacio.Toolbar.inspector" }?.action,
            #selector(WorkbenchWindowController.toggleInspectorFromToolbar(_:))
        )
    }

    func testToolbarDefaultItemsUseHIGStyleGroupingWithoutOverflowCommands() {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        XCTAssertEqual(controller.window?.toolbar?.autosavesConfiguration, true)
        let identifiers = controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        XCTAssertEqual(
            identifiers,
            [
                "Stacio.Toolbar.sidebar",
                NSToolbarItem.Identifier.flexibleSpace.rawValue,
                "Stacio.Toolbar.newSession",
                NSToolbarItem.Identifier.space.rawValue,
                "Stacio.Toolbar.multiExec",
                "Stacio.Toolbar.split",
                NSToolbarItem.Identifier.space.rawValue,
                "Stacio.Toolbar.files",
                "Stacio.Toolbar.browser",
                "Stacio.Toolbar.tunnels",
                "Stacio.Toolbar.deviceDashboard",
                "Stacio.Toolbar.aiAssistant",
                "Stacio.Toolbar.panels",
                NSToolbarItem.Identifier.space.rawValue,
                "Stacio.Toolbar.inspector"
            ]
        )
        XCTAssertFalse(identifiers.contains("Stacio.Toolbar.importSessions"))
        XCTAssertFalse(identifiers.contains("Stacio.Toolbar.closeTerminal"))
    }

    func testToolbarAllowsSecondaryCommandsWithoutShowingThemByDefault() {
        let controller = WorkbenchWindowController()
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Stacio.Toolbar.Test"))

        let allowed = controller.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue)

        XCTAssertTrue(allowed.contains("Stacio.Toolbar.sidebar"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.importSessions"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.split"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.panels"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.files"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.browser"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.tunnels"))
        XCTAssertFalse(allowed.contains("Stacio.Toolbar.closeTerminal"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.deviceDashboard"))
        XCTAssertTrue(allowed.contains("Stacio.Toolbar.aiAssistant"))
        XCTAssertFalse(allowed.contains("Stacio.Toolbar.quickConnect"))
        XCTAssertTrue(allowed.contains(NSToolbarItem.Identifier.space.rawValue))
    }

    func testDeviceDashboardToolbarTogglesCurrentWorkspaceDashboardWithoutOpeningInspector() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            deviceMetricsProviderFactory: { _ in RecordingWorkbenchDeviceMetricsProvider() },
            startsDeviceMetricsPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_metrics", status: "running", diagnostic: "running"),
            title: "root@172.16.10.250",
            connectionKind: .ssh,
            liveSessionContext: workbenchLiveContext()
        )

        XCTAssertTrue(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)

        controller.toggleDeviceDashboardFromToolbar(nil)
        XCTAssertFalse(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)

        controller.toggleDeviceDashboardFromToolbar(nil)
        XCTAssertTrue(workspace.isCurrentDeviceMetricsDashboardVisibleForTesting)
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
    }

    func testWorkbenchUsesAppleDocumentLayoutWithInspectorHiddenByDefault() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let splitController = controller.contentSplitViewController
        XCTAssertEqual(splitController.splitViewItems.count, 3)
        XCTAssertEqual(splitController.splitViewItems[0].minimumThickness, 220)
        XCTAssertEqual(splitController.splitViewItems[0].maximumThickness, 320)
        XCTAssertEqual(splitController.splitViewItems[1].minimumThickness, 0)
        XCTAssertEqual(splitController.splitViewItems[2].minimumThickness, 0)
        XCTAssertGreaterThanOrEqual(splitController.splitViewItems[2].maximumThickness, 1_500)
        XCTAssertTrue(splitController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(controller.window?.toolbar?.displayMode, .iconOnly)
        XCTAssertNil(
            controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Workspace.commandStrip")
        )
        XCTAssertNil(
            controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Workspace.commandActions")
        )
    }

    func testWorkbenchInspectorWidthFitsNativeSegmentedHeaderAndTables() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let inspector = controller.contentSplitViewController.splitViewItems[2]
        XCTAssertEqual(inspector.minimumThickness, 0)
        XCTAssertGreaterThanOrEqual(inspector.preferredThicknessFraction, 0.25)
    }

    func testTunnelsToolbarActionSelectsInspectorTunnelsTab() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        XCTAssertNotEqual(inspector.selectedTabLabelForTesting, "隧道")
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)

        controller.showTunnelsFromToolbar(nil)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "隧道")
    }

    func testTunnelsToolbarActionCollapsesInspectorWhenTunnelsAlreadySelected() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        controller.showTunnelsFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "隧道")

        controller.showTunnelsFromToolbar(nil)

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "隧道")
    }

    func testBrowserToolbarActionSelectsInspectorBrowserTab() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        XCTAssertNotEqual(inspector.selectedTabLabelForTesting, "浏览器")
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)

        controller.showBrowserFromToolbar(nil)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "浏览器")
    }

    func testBrowserToolbarActionCollapsesInspectorWhenBrowserAlreadySelected() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        controller.showBrowserFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "浏览器")

        controller.showBrowserFromToolbar(nil)

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "浏览器")
    }

    func testPanelsToolbarSecondaryActionsSelectInspectorSections() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        controller.showDiagnosticsFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "诊断")

        controller.showTerminalMacrosFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "宏")

        controller.showCommandHistoryFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "历史命令")
    }

    func testAIAssistantToolbarActionSelectsInspectorAIPanel() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let rootView = try XCTUnwrap(controller.window?.contentView)
        rootView.frame = NSRect(x: 0, y: 0, width: 1040, height: 720)
        rootView.layoutSubtreeIfNeeded()

        XCTAssertNotEqual(inspector.selectedTabLabelForTesting, "AI")
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertNil(rootView.firstSubview(withIdentifier: "Stacio.AI.overlay"))

        controller.showAIAssistantFromToolbar(nil)
        rootView.layoutSubtreeIfNeeded()

        XCTAssertNil(rootView.firstSubview(withIdentifier: "Stacio.AI.overlay"))
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "AI")
        XCTAssertTrue(inspector.selectedContentViewControllerForTesting === inspector.aiAssistantViewController)
    }

    func testAIAssistantToolbarActionCollapsesInspectorWhenAIAlreadySelected() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        controller.showAIAssistantFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "AI")

        controller.showAIAssistantFromToolbar(nil)

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "AI")
    }

    func testAIAssistantToolbarActionDoesNotCoverTerminalWithOverlay() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 760), display: false)
        controller.showAIAssistantFromToolbar(nil)
        window.layoutIfNeeded()

        XCTAssertNil(window.contentView?.firstSubview(withIdentifier: "Stacio.AI.overlay"))
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.selectedTabLabelForTesting, "AI")
    }

    func testAIAssistantSubmissionKeepsWorkbenchWindowFrameAfterDeferredInspectorLayout() throws {
        let suiteName = "StacioWorkbenchAIWindowFrame-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let provider = makeWorkbenchModelProvider(
            id: UUID(uuidString: "83000000-0000-0000-0000-000000000001")!,
            name: "Frame Test Provider",
            baseURL: "https://frame-test.example/v1",
            modelID: "frame-test-model"
        )
        try settingsStore.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [provider],
                defaultAIProviderID: provider.id
            )
        )
        let apiKeyStore = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )
        try apiKeyStore.saveAPIKey("frame-test-key", for: provider.id)
        let transport = RecordingWorkbenchAIAssistantHTTPTransport()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            settingsStore: settingsStore,
            aiAPIKeyStore: apiKeyStore,
            aiHTTPTransport: transport,
            frameAutosaveName: NSWindow.FrameAutosaveName(suiteName)
        )

        controller.showWindow(nil)
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        _ = try workspace.openLocalShell()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 40, y: 80, width: 1_800, height: 900), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        let expectedFrame = window.frame

        controller.showAIAssistantFromToolbar(nil)
        assertWindowFrame(window, equals: expectedFrame)
        let panel = try XCTUnwrap(
            controller.inspectorViewControllerForTesting?.aiAssistantViewController
        )
        panel.setQuestionForTesting("检查窗口尺寸")
        panel.performAskForTesting()
        assertWindowFrame(window, equals: expectedFrame)

        XCTAssertTrue(waitUntil { transport.streamRequests.count == 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertWindowFrame(window, equals: expectedFrame)
    }

    func testAIModelSelectionFlowsFromPanelSessionToSettingsBackedProvider() throws {
        let suiteName = "StacioWorkbenchAIModelSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let providerA = makeWorkbenchModelProvider(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            baseURL: "https://provider-a.example/v1",
            modelID: "shared"
        )
        let providerB = makeWorkbenchModelProvider(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            baseURL: "https://provider-b.example/v1",
            modelID: "shared"
        )
        try settingsStore.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let apiKeyStore = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )
        try apiKeyStore.saveAPIKey("key-a", for: providerA.id)
        try apiKeyStore.saveAPIKey("key-b", for: providerB.id)
        let transport = RecordingWorkbenchAIAssistantHTTPTransport()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            settingsStore: settingsStore,
            aiAPIKeyStore: apiKeyStore,
            aiHTTPTransport: transport
        )

        controller.loadWindow()
        _ = try workspace.openLocalShell()
        controller.showAIAssistantFromToolbar(nil)
        let panel = try XCTUnwrap(controller.inspectorViewControllerForTesting?.aiAssistantViewController)
        panel.selectComposerModelForTesting(
            AIModelSelection(providerID: providerB.id, modelID: "shared")
        )
        panel.setQuestionForTesting("检查状态")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { transport.streamRequests.count == 1 })
        let request = try XCTUnwrap(transport.streamRequests.first)
        XCTAssertEqual(request.url?.host, "provider-b.example")
        let requestBody = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(requestBody.contains(#""model":"shared""#))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-b")
        XCTAssertEqual(try settingsStore.loadAIProviderSettings().defaultAIProviderID, providerA.id)
    }

    func testAIModelSelectionSessionsAreIndependentAcrossWorkbenchPanels() throws {
        let suiteName = "StacioWorkbenchAIModelSelectionIsolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let providerA = makeWorkbenchModelProvider(
            id: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            baseURL: "https://provider-a.example/v1",
            modelID: "a-model"
        )
        let providerB = makeWorkbenchModelProvider(
            id: UUID(uuidString: "82000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            baseURL: "https://provider-b.example/v1",
            modelID: "b-model"
        )
        try settingsStore.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let apiKeyStore = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )
        try apiKeyStore.saveAPIKey("key-a", for: providerA.id)
        try apiKeyStore.saveAPIKey("key-b", for: providerB.id)
        let transportA = RecordingWorkbenchAIAssistantHTTPTransport()
        let transportB = RecordingWorkbenchAIAssistantHTTPTransport()
        let workspaceA = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let workspaceB = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let controllerA = WorkbenchWindowController(
            workspaceViewController: workspaceA,
            settingsStore: settingsStore,
            aiAPIKeyStore: apiKeyStore,
            aiHTTPTransport: transportA
        )
        let controllerB = WorkbenchWindowController(
            workspaceViewController: workspaceB,
            settingsStore: settingsStore,
            aiAPIKeyStore: apiKeyStore,
            aiHTTPTransport: transportB
        )

        controllerA.loadWindow()
        controllerB.loadWindow()
        _ = try workspaceA.openLocalShell()
        _ = try workspaceB.openLocalShell()
        controllerA.showAIAssistantFromToolbar(nil)
        controllerB.showAIAssistantFromToolbar(nil)
        let panelA = try XCTUnwrap(controllerA.inspectorViewControllerForTesting?.aiAssistantViewController)
        let panelB = try XCTUnwrap(controllerB.inspectorViewControllerForTesting?.aiAssistantViewController)
        panelA.selectComposerModelForTesting(
            AIModelSelection(providerID: providerA.id, modelID: "a-model")
        )
        panelB.selectComposerModelForTesting(
            AIModelSelection(providerID: providerB.id, modelID: "b-model")
        )

        panelA.setQuestionForTesting("检查 A")
        panelB.setQuestionForTesting("检查 B")
        panelA.performAskForTesting()
        panelB.performAskForTesting()

        XCTAssertTrue(waitUntil {
            transportA.streamRequests.count == 1 && transportB.streamRequests.count == 1
        })
        let requestA = try XCTUnwrap(transportA.streamRequests.first)
        let requestB = try XCTUnwrap(transportB.streamRequests.first)
        XCTAssertEqual(requestA.url?.host, "provider-a.example")
        XCTAssertEqual(requestB.url?.host, "provider-b.example")
        let bodyA = String(data: try XCTUnwrap(requestA.httpBody), encoding: .utf8) ?? ""
        let bodyB = String(data: try XCTUnwrap(requestB.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyA.contains(#""model":"a-model""#))
        XCTAssertTrue(bodyB.contains(#""model":"b-model""#))
        XCTAssertEqual(requestA.value(forHTTPHeaderField: "Authorization"), "Bearer key-a")
        XCTAssertEqual(requestB.value(forHTTPHeaderField: "Authorization"), "Bearer key-b")
        XCTAssertEqual(try settingsStore.loadAIProviderSettings().defaultAIProviderID, providerA.id)
    }

    func testTerminalAskAIContextRequestShowsAssistantInspector() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        _ = try workspace.openLocalShell()
        workspace.requestAIForCurrentTerminalForTesting(selectedText: "disk full")
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let questionField = try XCTUnwrap(
            inspector.aiAssistantViewController?.view.firstSubview(withIdentifier: "Stacio.AI.question") as? NSTextField
        )
        XCTAssertNil(controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.AI.overlay"))
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "AI")
        XCTAssertTrue(questionField.stringValue.contains("disk full"))
    }

    func testTerminalTraceDoesNotExposeOldTaskControlOpenRoute() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        _ = try workspace.openLocalShell()
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        pane.appendAgentTraceForTesting(
            requestID: "req-open-task",
            state: .running,
            message: "Codex 正在执行 uptime",
            redactedCommand: "uptime"
        )

        controller.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertNotNil(pane.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
        XCTAssertTrue(pane.agentTraceOverlayTextForTesting.contains("Codex 正在执行 uptime"))
        XCTAssertNil(pane.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-open-task"))
        XCTAssertNil(controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.AI.overlay"))
        XCTAssertNil(inspector.aiAssistantViewController?.view.firstSubview(withIdentifier: "Stacio.AI.taskWorkspace"))
        XCTAssertFalse(inspector.aiAssistantViewController?.taskControlTextForTesting.contains("req-open-task") ?? false)
        XCTAssertFalse(inspector.aiAssistantViewController?.taskControlTextForTesting.contains("Codex 正在执行 uptime") ?? false)
    }

    func testAgentBridgeHandlerUsesSettingsConfirmationPolicy() throws {
        let suiteName = "StacioWorkbenchAgentPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.agentConfirmationPolicy = .requireEveryCommand
        }
        let confirmer = RecordingWorkbenchAgentActionConfirmer(confirmed: false)
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            settingsStore: settingsStore,
            agentActionConfirmer: confirmer
        )

        controller.loadWindow()
        let runtimeID = try workspace.openLocalShell()
        let handler = controller.makeAgentBridgeRequestHandler()
        let request = AgentBridgeRequest(
            id: "settings-policy",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 42),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID(runtimeID),
                    command: "uptime",
                    follow: true
                )
            )
        )

        XCTAssertThrowsError(try handler.handleAgentBridgeRequest(request))
        XCTAssertEqual(confirmer.confirmations.count, 1)
        XCTAssertEqual(confirmer.confirmations[0].risk, .readOnly)
        XCTAssertEqual(confirmer.confirmations[0].targetTitle, L10n.Workspace.local)
    }

    func testAgentBridgeHandlerMigratesBackgroundPreferenceAndUsesCurrentTerminalForAllActors() throws {
        let suiteName = "StacioWorkbenchAgentExecutionModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("backgroundTask", forKey: "Stacio.Settings.agentExecutionMode")
        let settingsStore = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settingsStore.snapshot().agentExecutionMode, .visibleTerminal)
        XCTAssertEqual(defaults.string(forKey: "Stacio.Settings.agentExecutionMode"), "visibleTerminal")
        let launcher = RecordingWorkbenchLocalTerminalLauncher()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore,
            localTerminalProcessLauncherFactory: { launcher }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            settingsStore: settingsStore
        )

        controller.loadWindow()
        let runtimeID = try workspace.openLocalShell()
        let handler = controller.makeAgentBridgeRequestHandler()
        let requests = [
            ("assistant-current-terminal", AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil), "uptime"),
            ("local-agent-current-terminal", AgentActor(kind: .externalCLI, name: "codex", processID: 42), "whoami")
        ]
        var results: [[AgentTraceEvent]] = []
        for (requestID, actor, command) in requests {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                TerminalOutputBroadcastHub.shared.publishOutput(
                    runtimeID: runtimeID,
                    bytes: Array("command completed\n".utf8)
                )
            }
            results.append(try handler.handleAgentBridgeRequest(
                AgentBridgeRequest(
                    id: requestID,
                    actor: actor,
                    action: .runCommand(
                        AgentRunCommandRequest(
                            target: .runtimeID(runtimeID),
                            command: command,
                            follow: true
                        )
                    )
                )
            ))
        }

        XCTAssertEqual(
            launcher.sentInput.map { String(decoding: $0, as: UTF8.self) },
            [
                "{ uptime\n}; printf '\\033]777;stacio-agent-done=assistant-current-terminal\\007'\n",
                "{ whoami\n}; printf '\\033]777;stacio-agent-done=local-agent-current-terminal\\007'\n"
            ]
        )
        XCTAssertTrue(results.allSatisfy { events in
            events.last?.state == .completed
                && events.last?.metadata?["executionMode"] == "visibleTerminal"
                && events.last?.metadata?["sourceRuntimeID"] == runtimeID
        })
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        XCTAssertEqual(pane.runtimeID, runtimeID)
        XCTAssertFalse(pane.agentTraceSnapshotForTesting.contains("独立任务"))
    }

    func testAgentBridgeCommandKeepsExistingRemoteRuntimeConnected() throws {
        let suiteName = "StacioWorkbenchRemoteAgentRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("backgroundTask", forKey: "Stacio.Settings.agentExecutionMode")
        let settingsStore = AppSettingsStore(defaults: defaults)
        let eventSink = RecordingWorkbenchTerminalEventSink()
        let bridge = RecordingWorkbenchRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { eventSink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false,
            settingsStore: settingsStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            settingsStore: settingsStore
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_existing", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: workbenchLiveContext(host: "example.com")
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            TerminalOutputBroadcastHub.shared.publishOutput(
                runtimeID: "term_existing",
                bytes: Array("/srv/app\n".utf8)
            )
        }

        let events = try controller.makeAgentBridgeRequestHandler().handleAgentBridgeRequest(
            AgentBridgeRequest(
                id: "remote-current-terminal",
                actor: AgentActor(kind: .externalCLI, name: "claude", processID: 43),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_existing"),
                        command: "pwd",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(pane.runtimeID, "term_existing")
        XCTAssertEqual(eventSink.userInputEvents.map(\.runtimeID), ["term_existing"])
        XCTAssertEqual(
            eventSink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) },
            ["{ pwd\n}; printf '\\033]777;stacio-agent-done=remote-current-terminal\\007'\n"]
        )
        XCTAssertTrue(bridge.closedRuntimeIDs.isEmpty)
        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["executionMode"], "visibleTerminal")
        XCTAssertEqual(events.last?.metadata?["sourceRuntimeID"], "term_existing")
    }

    func testWorkbenchInspectorFilesUsesSettingsDirectoryFollowDefault() throws {
        let suiteName = "StacioWorkbenchFilesSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.filesDirectoryFollowDefault = false
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            settingsStore: settingsStore
        )

        controller.loadWindow()

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        _ = files.view
        XCTAssertFalse(files.isDirectoryFollowEnabled)
    }

    func testFilesToolbarEnablesDirectoryFollowForRemoteBindingEvenWhenDefaultOff() throws {
        let suiteName = "StacioWorkbenchFilesToolbarFollowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.filesDirectoryFollowDefault = false
        }
        let context = workbenchLiveContext(host: "example.com")
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            settingsStore: settingsStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            settingsStore: settingsStore
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        let files = try XCTUnwrap(controller.inspectorViewControllerForTesting?.filesViewController)

        XCTAssertTrue(files.isDirectoryFollowEnabled)
        pane.sendInput(Array("cd /srv/app\n".utf8))

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && files.currentRemotePath == "/srv/app"
        })
    }

    func testFilesToolbarActionSelectsInspectorFilesTab() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertNil(controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Workspace.commandStrip"))

        controller.showTunnelsFromToolbar(nil)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "隧道")
        controller.contentSplitViewController.splitViewItems[2].isCollapsed = true

        controller.showFilesFromToolbar(nil)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "文件")
        XCTAssertNil(controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Workspace.commandStrip"))
    }

    func testFilesToolbarActionCollapsesInspectorWhenFilesAlreadySelected() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        controller.showTunnelsFromToolbar(nil)
        controller.showFilesFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "文件")

        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "文件")
    }

    func testInspectorPanelToolbarActionsSwitchPanelsWithoutCollapsing() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)

        controller.showTunnelsFromToolbar(nil)
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "隧道")

        controller.showFilesFromToolbar(nil)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "文件")
    }

    func testNewSessionToolbarItemOpensSessionSettingsFlow() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()
        let item = try XCTUnwrap(
            controller.window?.toolbar?.items.first {
                $0.itemIdentifier.rawValue == "Stacio.Toolbar.newSession"
            }
        )

        XCTAssertEqual(item.action, #selector(WorkbenchWindowController.performNewSessionFromToolbar(_:)))
    }

    func testNewSessionToolbarActionOpensLocalShell() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        try controller.openLocalShellFromToolbar(nil)

        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is TerminalPaneViewController)
    }

    func testOpeningLocalShellFocusesTerminalViewForKeyboardInput() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.showWindow(nil)
        defer { controller.close() }
        try workspace.openLocalShell()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        XCTAssertIdentical(controller.window?.firstResponder, pane.terminalView)
    }

    func testOpeningRemoteShellFocusesTerminalViewForKeyboardInput() throws {
        let workspace = WorkspaceViewController(
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.showWindow(nil)
        defer { controller.close() }
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "生产 API"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertIdentical(controller.window?.firstResponder, pane.terminalView)
    }

    func testSplitToolbarItemOffersTerminalLayoutModesWithoutStartingMultiExecSelection() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let selector = RecordingMultiExecSessionSelector(
            selection: MultiExecSessionSelection(targetIDs: ["term_one", "term_two"])
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecSessionSelector: selector
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_one", status: "running", diagnostic: "running"),
            title: "生产一",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_two", status: "running", diagnostic: "running"),
            title: "生产二",
            connectionKind: .ssh
        )
        let item = try XCTUnwrap(
            controller.toolbar(
                try XCTUnwrap(controller.window?.toolbar),
                itemForItemIdentifier: NSToolbarItem.Identifier("Stacio.Toolbar.split"),
                willBeInsertedIntoToolbar: false
            )
        )

        XCTAssertEqual(item.action, #selector(WorkbenchWindowController.performSplitTerminalFromToolbar(_:)))
        XCTAssertEqual(
            (item as? NSMenuToolbarItem)?.menu.items.map(\.title),
            ["单终端模式", "垂直分屏", "水平分屏", "网格分屏"]
        )

        controller.performSplitTerminalFromToolbar(nil)

        XCTAssertEqual(selector.presentedTargets.map(\.id), ["term_one", "term_two"])
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .vertical)
    }

    func testSplitToolbarCreatesSecondPaneBeforeApplyingVerticalLayout() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)
        controller.loadWindow()
        try workspace.openLocalShell()

        controller.performVerticalSplitTerminalFromToolbar(nil)

        XCTAssertEqual(workspace.openTerminalPaneCount, 2)
        XCTAssertEqual(workspace.currentTerminalSplitLayoutModeForTesting, .vertical)
        XCTAssertFalse(workspace.isMultiExecSessionActiveForTesting)
    }

    func testMultiExecToolbarItemStartsInteractiveSelection() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let selector = RecordingMultiExecSessionSelector(
            selection: MultiExecSessionSelection(targetIDs: ["term_one", "term_two"])
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecSessionSelector: selector
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_one", status: "running", diagnostic: "running"),
            title: "生产一",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_two", status: "running", diagnostic: "running"),
            title: "生产二",
            connectionKind: .serial
        )
        let item = try XCTUnwrap(
            controller.window?.toolbar?.items.first {
                $0.itemIdentifier.rawValue == "Stacio.Toolbar.multiExec"
            }
        )

        XCTAssertEqual(item.action, #selector(WorkbenchWindowController.performMultiExecFromToolbar(_:)))
        XCTAssertEqual(item.toolTip, "批量同步输入到多个终端")
        XCTAssertEqual(item.image?.accessibilityDescription, "批量多执行")

        controller.performMultiExecFromToolbar(nil)

        XCTAssertEqual(selector.presentedTargets.map(\.id), ["term_one", "term_two"])
        XCTAssertEqual(workspace.currentSplitPaneRuntimeIDsForTesting, ["term_one", "term_two"])
    }

    func testSplittingTerminalFocusesNewPaneForKeyboardInput() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.showWindow(nil)
        defer { controller.close() }
        try workspace.openLocalShell()
        try workspace.splitCurrentTerminal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        XCTAssertIdentical(controller.window?.firstResponder, pane.terminalView)
    }

    func testWorkbenchCloseCurrentTerminalRequiresConfirmationFromMenu() {
        let sink = RecordingWorkbenchTerminalEventSink()
        let bridge = RecordingWorkbenchRemoteTerminalBridge()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { bridge },
            startsRemoteTerminalPollingAutomatically: false
        )
        let confirmation = RecordingTerminalCloseConfirmation(shouldClose: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            terminalCloseConfirmation: confirmation
        )

        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "生产 API"
        )
        controller.loadWindow()
        controller.closeCurrentTerminalFromMenu(nil)
        confirmation.shouldClose = true
        controller.closeCurrentTerminalFromMenu(nil)

        XCTAssertEqual(confirmation.requestedTitles, ["生产 API", "生产 API"])
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_remote"])
        XCTAssertEqual(sink.closedRuntimeIDs, ["term_remote"])
    }

    func testWorkbenchSkipsTerminalCloseConfirmationWhenDisabledInSettings() throws {
        let suiteName = "StacioCloseConfirmationSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalCloseConfirmationEnabled = false
        }
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            settingsStore: settingsStore
        )
        let confirmation = RecordingTerminalCloseConfirmation(shouldClose: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            terminalCloseConfirmation: confirmation,
            settingsStore: settingsStore
        )

        controller.loadWindow()
        try workspace.openLocalShell()
        controller.closeCurrentTerminalFromMenu(nil)

        XCTAssertEqual(confirmation.requestedTitles, [])
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
    }

    func testWorkbenchInjectsTunnelLiveSessionContextIntoInspector() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let liveBridge = RecordingWorkbenchLiveTunnelBridge()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionContextProvider: { context },
            tunnelLiveBridge: liveBridge
        )

        controller.loadWindow()
        let inspector = controller.contentSplitViewController
            .splitViewItems[2]
            .viewController as? InspectorViewController
        let status = try inspector?.tunnelsViewControllerForTesting.startForTesting(
            profile: TunnelProfile(
                id: "tun_workbench_context",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 18080,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        )

        XCTAssertEqual(status?.state, .running)
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_workbench_context"])
    }

    func testWorkbenchDefaultTunnelContextProviderReadsSharedStore() throws {
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(
            with: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test"
            )
        )
        let liveBridge = RecordingWorkbenchLiveTunnelBridge()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionStore: contextStore,
            tunnelLiveBridge: liveBridge
        )

        controller.loadWindow()
        let inspector = controller.contentSplitViewController
            .splitViewItems[2]
            .viewController as? InspectorViewController
        let status = try inspector?.tunnelsViewControllerForTesting.startForTesting(
            profile: TunnelProfile(
                id: "tun_workbench_store",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 18080,
                remoteHost: "db.internal",
                remotePort: 5432
            )
        )

        XCTAssertEqual(status?.state, .running)
        XCTAssertEqual(liveBridge.startedProfiles.map(\.id), ["tun_workbench_store"])
    }

    func testWorkbenchReportsRunningTunnelCountForApplicationTerminationProtection() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "edge.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:tunnel"
        )
        let liveBridge = RecordingWorkbenchLiveTunnelBridge()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionContextProvider: { context },
            tunnelLiveBridge: liveBridge
        )

        controller.loadWindow()
        let inspector = controller.contentSplitViewController
            .splitViewItems[2]
            .viewController as? InspectorViewController

        XCTAssertEqual(controller.runningTunnelCount, 0)

        let status = try inspector?.tunnelsViewControllerForTesting.startForTesting(
            profile: TunnelProfile(
                id: "tun_quit_guard",
                kind: .local,
                localHost: "127.0.0.1",
                localPort: 19090,
                remoteHost: "127.0.0.1",
                remotePort: 9090
            )
        )

        XCTAssertEqual(status?.state, .running)
        XCTAssertEqual(controller.runningTunnelCount, 1)
    }

    func testWorkbenchStartRemoteSessionDelegatesToSessionStarter() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        let status = try controller.startRemoteSession(config: config, title: "deploy@example.com")

        XCTAssertEqual(status.runtimeId, "term_live")
        XCTAssertEqual(starter.startedConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(starter.startedTitles, ["deploy@example.com"])
    }

    func testWorkbenchStartRemoteSessionKeepsInspectorHiddenUntilFilesToolbarRequested() throws {
        let contextStore = TunnelLiveSessionStore()
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running"),
            onStart: {
                contextStore.replace(with: context)
            }
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            remoteSessionStarter: starter
        )

        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        try controller.startRemoteSession(config: context.config, title: "deploy@example.com")

        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(filesBridge.liveHosts, [])
        XCTAssertEqual(filesBridge.liveRemotePaths, [])
        XCTAssertEqual(inspector.filesViewController?.entryCount, 0)

        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(waitUntil {
            filesBridge.liveHosts == ["example.com"]
                && inspector.filesViewController?.entryCount == 1
        })
        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertEqual(inspector.selectedTabLabelForTesting, "文件")
        XCTAssertEqual(filesBridge.liveHosts, ["example.com"])
        XCTAssertEqual(filesBridge.liveRemotePaths, ["~"])
        XCTAssertEqual(inspector.filesViewController?.entryCount, 1)
    }

    func testFilesToolbarLoadsDirectoryFromSelectedRemoteTerminalContext() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let shellStarter = HostRuntimeLiveShellStarter()
        let remoteStarter = RemoteSSHSessionCoordinator(
            contextBuilder: HostMappedTunnelContextBuilder(),
            liveShellStarter: shellStarter,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/stacio-test.sqlite" }
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/selected.log", size: 64, linkTarget: nil)
        ])
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            remoteSessionStarter: remoteStarter
        )

        controller.loadWindow()
        try controller.startRemoteSession(
            config: workbenchSSHConfig(host: "first.example.com"),
            title: "first.example.com"
        )
        try controller.startRemoteSession(
            config: workbenchSSHConfig(host: "second.example.com"),
            title: "second.example.com"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        XCTAssertEqual(workspace.currentRemoteTerminalLiveSessionContext?.config.host, "second.example.com")
        workspace.selectTabForTesting(0)
        let selectedPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        selectedPane.hostCurrentDirectoryUpdate(source: selectedPane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(waitUntil {
            filesBridge.liveHosts == ["first.example.com"]
                && controller.inspectorViewControllerForTesting?.filesViewController?.entryCount == 1
        })
        XCTAssertEqual(filesBridge.liveHosts, ["first.example.com"])
        XCTAssertEqual(filesBridge.liveRemotePaths, ["/srv/app"])
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.entryCount, 1)
    }

    func testRemoteTerminalDroppedFinderFilesCreateUploadTransferTask() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioWorkbenchTerminalDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("release.tar.gz")
        try Data(repeating: 1, count: 64).write(to: localFile)
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let context = workbenchLiveContext(host: "drop.example.com")
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteFilesBridge: RecordingWorkbenchRemoteFilesBridge(entries: []),
            transferHistoryStore: NoOpSCPTransferHistoryStore()
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_drop", status: "running", diagnostic: "running"),
            title: "drop.example.com",
            liveSessionContext: context
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/releases")

        pane.performDropLocalFilesForTesting([localFile.path])

        let queue = try XCTUnwrap(controller.inspectorViewControllerForTesting?.transferQueueViewController)
        XCTAssertTrue(waitUntil {
            queue.snapshotForTesting.rows.contains {
                $0.sourcePath == localFile.path
            }
        })
        let row = try XCTUnwrap(queue.snapshotForTesting.rows.first { $0.sourcePath == localFile.path })
        XCTAssertEqual(row.direction, .upload)
        XCTAssertEqual(row.sourcePath, localFile.path)
        XCTAssertEqual(row.destinationPath, "/srv/releases/release.tar.gz")
        XCTAssertTrue(["queued", "running", "failed"].contains(row.rawStatus))
    }

    func testClosingBoundRemoteTerminalDisconnectsInspectorFilesConnection() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = workbenchLiveContext(host: "shared.example.com")
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/root/open.log", size: 64, linkTarget: nil)
        ])
        let confirmation = RecordingTerminalCloseConfirmation(shouldClose: true)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            terminalCloseConfirmation: confirmation
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_files_owner", status: "running", diagnostic: "running"),
            title: "shared.example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let files = try XCTUnwrap(inspector.filesViewController)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths == ["~"] && files.entryCount == 1 })

        controller.closeCurrentTerminalFromMenu(nil)
        inspector.filesCoordinatorForTesting.refreshCurrentLiveDirectory(remotePath: "/var/log")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(filesBridge.liveRemotePaths, ["~"])
        XCTAssertEqual(files.entryCount, 0)
        XCTAssertTrue(files.visibleTextSnapshot.contains("文件连接已断开"))
    }

    func testInspectorFilesDoNotReuseCachedRowsAcrossRemoteTabsOnSameHost() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let firstContext = workbenchLiveContext(
            host: "same.example.com",
            expectedFingerprintSHA256: "SHA256:first-tab"
        )
        let secondContext = workbenchLiveContext(
            host: "same.example.com",
            expectedFingerprintSHA256: "SHA256:second-tab"
        )
        let filesBridge = RuntimeScopedWorkbenchRemoteFilesBridge(entriesByFingerprint: [
            "SHA256:first-tab": [
                RemoteFileEntry(kind: .file, path: "/home/root/first.log", size: 64, linkTarget: nil)
            ],
            "SHA256:second-tab": [
                RemoteFileEntry(kind: .file, path: "/home/root/second.log", size: 64, linkTarget: nil)
            ]
        ])
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: TunnelLiveSessionStore(),
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_same_host_first", status: "running", diagnostic: "running"),
            title: "same.example.com",
            liveSessionContext: firstContext
        )
        controller.showFilesFromToolbar(nil)
        let files = try XCTUnwrap(controller.inspectorViewControllerForTesting?.filesViewController)
        XCTAssertTrue(waitUntil { files.containsRemoteEntry(named: "first.log") })

        filesBridge.delayNextRequest()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_same_host_second", status: "running", diagnostic: "running"),
            title: "same.example.com",
            liveSessionContext: secondContext
        )
        XCTAssertTrue(filesBridge.waitUntilDelayedRequestStarted())

        XCTAssertFalse(files.containsRemoteEntry(named: "first.log"))
        filesBridge.releaseDelayedRequest()
        XCTAssertTrue(waitUntil { files.containsRemoteEntry(named: "second.log") })
        XCTAssertEqual(filesBridge.expectedFingerprints, ["SHA256:first-tab", "SHA256:second-tab"])
    }

    func testFileContextMenuSendsSelectedRemotePathToCurrentTerminal() throws {
        let sink = RecordingWorkbenchTerminalEventSink()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let contextStore = TunnelLiveSessionStore()
        let context = workbenchLiveContext(host: "files.example.com")
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil)
        ])
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_files", status: "running", diagnostic: "running"),
            title: "files.example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let files = try XCTUnwrap(controller.inspectorViewControllerForTesting?.filesViewController)
        XCTAssertTrue(waitUntil { files.entryCount == 1 })

        files.performContextMenuActionForTesting(title: "将文件路径复制到终端", row: 0)

        XCTAssertEqual(
            sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) },
            ["/srv/app/logs"]
        )
    }

    func testFilesToolbarOpensLocalFileTabAtSelectedLocalTerminalDirectory() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false
        )
        let controller = WorkbenchWindowController(workspaceViewController: workspace)
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-local-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)

        controller.loadWindow()
        try workspace.openLocalShell()
        let localPane = try XCTUnwrap(workspace.currentTerminalPane as? TerminalPaneViewController)
        localPane.hostCurrentDirectoryUpdate(source: localPane.terminalView, directory: localDirectory.path)

        controller.showFilesFromToolbar(nil)

        let filesPane = try XCTUnwrap(workspace.currentTerminalPane as? LocalFilePaneViewController)
        XCTAssertEqual(filesPane.currentPathForTesting, localDirectory.path)
        XCTAssertEqual(workspace.tabLabelsForWorkbenchTesting, ["本地", "本地文件"])
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.selectedTabLabelForTesting, "文件")
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.entryCount, 0)
    }

    func testFilesToolbarShowsChineseErrorWhenNoCurrentSSHContextExists() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        controller.showFilesFromToolbar(nil)

        let snapshot = try XCTUnwrap(
            controller.inspectorViewControllerForTesting?.filesViewController?.visibleTextSnapshot
        )
        XCTAssertTrue(snapshot.contains("无法加载远端目录"))
        XCTAssertTrue(snapshot.contains("当前没有可用的 SSH 文件上下文"))
        XCTAssertFalse(snapshot.localizedCaseInsensitiveContains("missing_live_session_context"))
    }

    func testWorkbenchOpenSavedSessionUsesEmbeddedRemoteSessionStarter() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_saved",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 2222,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_saved")
        XCTAssertEqual(starter.startedConfigs.map(\.host), ["api.example.com"])
        XCTAssertEqual(starter.startedConfigs.map(\.port), [2222])
        XCTAssertEqual(starter.startedConfigs.map(\.username), ["deploy"])
        XCTAssertEqual(starter.startedConfigs.map(\.authMethod), [.agent])
        XCTAssertEqual(starter.startedTitles, ["API Server"])
    }

    func testWorkbenchOpenSavedSSHSessionShowsConnectingBannerBeforeBackgroundRuntimeCompletes() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            startsRemoteTerminalPollingAutomatically: false
        )
        let liveShellStarter = DelayedWorkbenchLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_saved_delayed", status: "running", diagnostic: "running"),
            delay: 0.2
        )
        let remoteSessionStarter = RemoteSSHSessionCoordinator(
            contextBuilder: HostMappedTunnelContextBuilder(),
            liveShellStarter: liveShellStarter,
            contextStore: TunnelLiveSessionStore(),
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: remoteSessionStarter
        )
        let session = SessionRecord(
            id: "session_saved_pending",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 2222,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("pending_"))
        XCTAssertEqual(status.status, "connecting")
        let pane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: status.runtimeId))
        XCTAssertEqual(pane.lifecycleState, .connecting)
        XCTAssertEqual(pane.lifecycleMessageForTesting, L10n.TerminalLifecycle.connecting)
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains("os error 65"))
        XCTAssertFalse(pane.terminalDisplaySnapshotForTesting.contains("SSH 无法到达主机"))
        XCTAssertTrue(waitUntil { pane.lifecycleState == .running })
        XCTAssertEqual(pane.runtimeID, "term_saved_delayed")
    }

    func testWorkbenchOpenSavedSSHSessionAppliesManualIconBeforeAndAfterConnect() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Ubuntu API",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: #"{"sessionIconID":"ubuntu"}"#
            )
        )
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            startsRemoteTerminalPollingAutomatically: false
        )
        let liveShellStarter = DelayedWorkbenchLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_saved_icon", status: "running", diagnostic: "running"),
            delay: 0.1
        )
        let remoteSessionStarter = RemoteSSHSessionCoordinator(
            contextBuilder: HostMappedTunnelContextBuilder(),
            liveShellStarter: liveShellStarter,
            contextStore: TunnelLiveSessionStore(),
            workspace: workspace,
            databasePathProvider: { tempURL.path }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: remoteSessionStarter,
            databasePathProvider: { tempURL.path }
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("pending_"))
        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "ubuntu")
        XCTAssertTrue(waitUntil {
            workspace.remoteTerminalPaneForTesting(runtimeID: "term_saved_icon")?.lifecycleState == .running
        })
        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "ubuntu")
    }

    func testWorkbenchOpenSavedSSHSessionInitialFailureShowsCurrentFailure() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            startsRemoteTerminalPollingAutomatically: false
        )
        let liveShellStarter = FailingWorkbenchLiveShellStarter(
            error: SshRuntimeError.Transport(message: "SSH 无法到达主机 (os error 65)")
        )
        let remoteSessionStarter = RemoteSSHSessionCoordinator(
            contextBuilder: HostMappedTunnelContextBuilder(),
            liveShellStarter: liveShellStarter,
            contextStore: TunnelLiveSessionStore(),
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: remoteSessionStarter
        )
        let session = SessionRecord(
            id: "session_saved_initial_failure",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 2222,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        let pane = try XCTUnwrap(workspace.remoteTerminalPaneForTesting(runtimeID: status.runtimeId))
        XCTAssertTrue(waitUntil { liveShellStarter.startedConfigs.count == 1 })
        XCTAssertTrue(waitUntil { pane.lifecycleState == .disconnected })
        XCTAssertEqual(pane.lifecycleMessageForTesting, "连接失败：无法到达主机")
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains("os error 65"))
        XCTAssertFalse(pane.terminalDisplaySnapshotForTesting.contains("SSH 无法到达主机"))
    }

    func testFailingWorkbenchLiveShellStarterRecordsStartsAcrossConcurrentReads() throws {
        let starter = FailingWorkbenchLiveShellStarter(error: TestWorkbenchError.failed)
        let config = SshConnectionConfig(
            host: "api.example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let iterationCount = 2_000
        let queue = DispatchQueue(
            label: "Stacio.Tests.FailingWorkbenchLiveShellStarter",
            attributes: .concurrent
        )
        let group = DispatchGroup()

        group.enter()
        queue.async {
            for _ in 0..<iterationCount {
                _ = try? starter.startLiveSSHShellRuntime(
                    config: config,
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test",
                    cols: 120,
                    rows: 36
                )
            }
            group.leave()
        }
        group.enter()
        queue.async {
            for _ in 0..<iterationCount {
                _ = starter.startedConfigs.count
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(starter.startedConfigs.count, iterationCount)
    }

    func testWorkbenchOpenSavedSSHSessionPassesSavedAutomationPolicyToStarter() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Production API",
                protocol: "ssh",
                host: "api.example.com",
                port: 2222,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["prod"],
                configJson: #"{"environment":"production","aiExecutionPolicy":"commandCard"}"#
            )
        )
        let starter = RecordingAutomationRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_policy", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            databasePathProvider: { tempURL.path }
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_saved_policy")
        XCTAssertEqual(starter.startedConfigs.map(\.host), ["api.example.com"])
        XCTAssertEqual(starter.startedTitles, ["Production API"])
        XCTAssertEqual(
            starter.automationPolicies,
            [SessionAutomationPolicy(environment: "production", aiExecutionPolicy: "commandCard")]
        )
    }

    func testWorkbenchOpenSavedSSHSessionPassesSavedStartupPlanToStarter() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Production API",
                protocol: "ssh",
                host: "api.example.com",
                port: 2222,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["prod"],
                configJson: #"{"environment":"production","aiExecutionPolicy":"commandCard","startupCommand":"cd /srv/app && docker compose ps","environmentVariables":["APP_ENV=prod","STACIO_TRACE=1"]}"#
            )
        )
        let starter = RecordingAutomationRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_startup", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            databasePathProvider: { tempURL.path }
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_saved_startup")
        XCTAssertEqual(
            starter.automationPolicies,
            [
                SessionAutomationPolicy(
                    environment: "production",
                    aiExecutionPolicy: "commandCard",
                    startupCommand: "cd /srv/app && docker compose ps",
                    environmentVariables: ["APP_ENV=prod", "STACIO_TRACE=1"]
                )
            ]
        )
    }

    func testWorkbenchOpenSavedSSHSessionPassesPostConnectScriptToStarter() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Production API",
                protocol: "ssh",
                host: "api.example.com",
                port: 2222,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["prod"],
                configJson: #"{"postConnectScript":"cd /srv/app\nsource .env"}"#
            )
        )
        let starter = RecordingAutomationRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_on_connect", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            databasePathProvider: { tempURL.path }
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_saved_on_connect")
        XCTAssertEqual(
            starter.automationPolicies,
            [SessionAutomationPolicy(postConnectScript: "cd /srv/app\nsource .env")]
        )
    }

    func testWorkbenchOpenSavedSSHSessionUsesSavedConnectTimeout() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Slow Bastion",
                protocol: "ssh",
                host: "bastion.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: ["ops"],
                configJson: #"{"connectTimeoutMs":45000}"#
            )
        )
        let starter = RecordingAutomationRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_timeout", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            databasePathProvider: { tempURL.path }
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_saved_timeout")
        XCTAssertEqual(starter.startedConfigs.map(\.connectTimeoutMs), [45_000])
    }

    func testWorkbenchOpenSavedSSHSessionDefaultsToFastConnectTimeout() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: nil
            )
        )
        let starter = RecordingAutomationRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_fast_timeout", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            databasePathProvider: { tempURL.path }
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_saved_fast_timeout")
        XCTAssertEqual(starter.startedConfigs.map(\.connectTimeoutMs), [SSHConnectionDefaults.fastConnectTimeoutMs])
    }

    func testWorkbenchOpenSavedSessionUsesPrivateKeyPathWhenPresent() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_key", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_saved_key",
            folderId: nil,
            name: "Key Host",
            protocol: "ssh",
            host: "key.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: "passphrase-ref",
            tags: [],
            lastOpenedAt: nil
        )

        _ = try controller.openSavedSession(session)

        XCTAssertEqual(
            starter.startedConfigs.map(\.authMethod),
            [.privateKey(keyPath: "~/.ssh/prod", passphraseRef: "passphrase-ref")]
        )
    }

    func testWorkbenchOpenSavedSessionUsesPasswordCredentialWhenPresentWithoutPrivateKey() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_password", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_saved_password",
            folderId: nil,
            name: "Password Host",
            protocol: "ssh",
            host: "password.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: "password-ref",
            tags: [],
            lastOpenedAt: nil
        )

        _ = try controller.openSavedSession(session)

        XCTAssertEqual(starter.startedConfigs.map(\.authMethod), [.password(credentialRef: "password-ref")])
    }

    func testWorkbenchOpenSavedSSHSessionRepromptsMissingCredentialAndRetries() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let oldCredential = try CoreBridge.saveCredentialRecord(
            databasePath: tempURL.path,
            draft: CredentialDraft(
                kind: "password",
                label: "API password",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: oldCredential.id,
                tags: [],
                configJson: nil
            )
        )
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let credentialSaver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        let prompt = RecordingSavedSessionCredentialPromptPresenter(secret: "new-password")
        let starter = OneTimeFailingRemoteSessionStarter(
            error: KeychainCredentialError.notFound,
            status: LiveShellStatus(runtimeId: "term_repaired", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            savedSessionCredentialPromptPresenter: prompt,
            savedSessionCredentialSaver: credentialSaver,
            databasePathProvider: { tempURL.path }
        )

        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_repaired")
        XCTAssertEqual(prompt.requests.map(\.kind), [.password])
        XCTAssertEqual(prompt.requests.map(\.account), ["deploy@api.example.com"])
        XCTAssertEqual(starter.startedConfigs.map(\.authMethod).count, 2)
        XCTAssertEqual(starter.startedConfigs.first?.authMethod, .password(credentialRef: oldCredential.id))
        let updatedSession = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let replacementCredentialID = try XCTUnwrap(updatedSession.credentialId)
        XCTAssertNotEqual(replacementCredentialID, oldCredential.id)
        XCTAssertEqual(starter.startedConfigs.last?.authMethod, .password(credentialRef: replacementCredentialID))
        XCTAssertEqual(
            try keychainStore.readSecret(id: replacementCredentialID, account: "deploy@api.example.com"),
            "new-password"
        )
    }

    func testWorkbenchOpenSavedSSHSessionCancelingMissingCredentialPromptStopsRetry() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let oldCredential = try CoreBridge.saveCredentialRecord(
            databasePath: tempURL.path,
            draft: CredentialDraft(
                kind: "password",
                label: "API password",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: oldCredential.id,
                tags: [],
                configJson: nil
            )
        )
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let credentialSaver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        let prompt = RecordingSavedSessionCredentialPromptPresenter(secret: nil)
        let starter = OneTimeFailingRemoteSessionStarter(
            error: KeychainCredentialError.notFound,
            status: LiveShellStatus(runtimeId: "term_repaired", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            savedSessionCredentialPromptPresenter: prompt,
            savedSessionCredentialSaver: credentialSaver,
            databasePathProvider: { tempURL.path }
        )

        XCTAssertThrowsError(try controller.openSavedSession(session)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(prompt.requests.map(\.account), ["deploy@api.example.com"])
        XCTAssertEqual(starter.startedConfigs.map(\.authMethod), [.password(credentialRef: oldCredential.id)])
        XCTAssertEqual(try CoreBridge.listCredentialRecords(databasePath: tempURL.path).map(\.id), [oldCredential.id])
        XCTAssertEqual(
            try CoreBridge.listAllSessionRecords(databasePath: tempURL.path).map(\.credentialId),
            [oldCredential.id]
        )
    }

    func testWorkbenchOpenSavedSessionWithoutUsernameOrPasswordKeepsHostOnlyTitleAndNoPasswordAuth() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_host_only", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_saved_host_only",
            folderId: nil,
            name: "",
            protocol: "ssh",
            host: "host-only.example.com",
            port: 22,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        _ = try controller.openSavedSession(session)

        XCTAssertEqual(starter.startedConfigs.map(\.authMethod), [.agent])
        XCTAssertEqual(starter.startedTitles, ["host-only.example.com"])
    }

    func testWorkbenchOpenSavedRDPSessionIsRejectedWithoutStartingSSHOrGraphicsRuntime() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let graphicsRuntime = RecordingGraphicsRuntimeManager(
            status: GraphicsRuntimeStatus(
                runtimeID: "graphics_wrong",
                status: "running",
                diagnostic: "unexpected graphics runtime"
            )
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            graphicsRuntimeManager: graphicsRuntime,
            graphicsAdapterPathProvider: { "/Applications/Stacio.app/Contents/Adapters/\($0)" }
        )
        let session = SessionRecord(
            id: "session_rdp",
            folderId: nil,
            name: "Windows Host",
            protocol: "rdp",
            host: "windows.example.com",
            port: 3389,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()

        XCTAssertThrowsError(try controller.openSavedSession(session)) { error in
            XCTAssertEqual(error as? WorkbenchSessionOpenError, .protocolRuntimeUnavailable("rdp"))
        }

        XCTAssertNil(workspace.currentTerminalPane)
        XCTAssertTrue(graphicsRuntime.requests.isEmpty)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedVNCSessionStartsPackagedAdapterRuntime() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let graphicsRuntime = RecordingGraphicsRuntimeManager(
            status: GraphicsRuntimeStatus(
                runtimeID: "graphics_vnc_test",
                status: "running",
                diagnostic: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
            )
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            graphicsRuntimeManager: graphicsRuntime,
            graphicsAdapterPathProvider: { _ in "/Applications/Stacio.app/Contents/Adapters/vnc" }
        )
        let session = SessionRecord(
            id: "session_vnc",
            folderId: nil,
            name: "VNC 桌面",
            protocol: "vnc",
            host: "desktop.example.com",
            port: 5900,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)
        XCTAssertEqual(status.runtimeId, "graphics_vnc_test")
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。")
        XCTAssertEqual(pane.runtimeID, "graphics_vnc_test")
        XCTAssertEqual(graphicsRuntime.requests.map(\.protocolName), ["VNC"])
        XCTAssertEqual(graphicsRuntime.requests.map(\.adapterPath), ["/Applications/Stacio.app/Contents/Adapters/vnc"])
        XCTAssertEqual(graphicsRuntime.requests.map(\.arguments), [["desktop.example.com:5900"]])
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("正在建立图形连接"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("尚未建立图形连接"))
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedVNCSessionPassesSavedPasswordToPackagedAdapterWithoutLeakingIt() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let graphicsRuntime = RecordingGraphicsRuntimeManager(
            status: GraphicsRuntimeStatus(
                runtimeID: "graphics_vnc_password",
                status: "running",
                diagnostic: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
            )
        )
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        try keychainStore.save(
            KeychainCredential(
                id: "vnc-password-ref",
                account: "admin@desktop.example.com",
                secret: "vnc-secret"
            )
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            graphicsCredentialStore: keychainStore,
            graphicsRuntimeManager: graphicsRuntime,
            graphicsAdapterPathProvider: { _ in "/Applications/Stacio.app/Contents/Adapters/vnc" }
        )
        let session = SessionRecord(
            id: "session_vnc_password",
            folderId: nil,
            name: "VNC 桌面",
            protocol: "vnc",
            host: "desktop.example.com",
            port: 5900,
            username: "admin",
            privateKeyPath: nil,
            credentialId: "vnc-password-ref",
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)
        XCTAssertEqual(status.runtimeId, "graphics_vnc_password")
        XCTAssertEqual(graphicsRuntime.requests.map(\.arguments), [[
            "--password",
            "vnc-secret",
            "desktop.example.com:5900"
        ]])
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("<redacted>"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("vnc-secret"))
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedVNCSessionPromptsForMissingPasswordBeforeLaunchingAdapter() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let oldCredential = try CoreBridge.saveCredentialRecord(
            databasePath: tempURL.path,
            draft: CredentialDraft(
                kind: "password",
                label: "VNC password",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "admin@desktop.example.com"
            )
        )
        let staleCredentialSession = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "VNC 桌面",
                protocol: "vnc",
                host: "desktop.example.com",
                port: 5900,
                username: "admin",
                privateKeyPath: nil,
                credentialId: oldCredential.id,
                tags: [],
                configJson: nil
            )
        )
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let credentialSaver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        let prompt = RecordingSavedSessionCredentialPromptPresenter(secret: "prompted-vnc-secret")
        let graphicsRuntime = RecordingGraphicsRuntimeManager(
            status: GraphicsRuntimeStatus(
                runtimeID: "graphics_vnc_prompted",
                status: "running",
                diagnostic: "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。"
            )
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: RecordingRemoteSessionStarter(
                status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
            ),
            savedSessionCredentialPromptPresenter: prompt,
            savedSessionCredentialSaver: credentialSaver,
            graphicsCredentialStore: keychainStore,
            databasePathProvider: { tempURL.path },
            graphicsRuntimeManager: graphicsRuntime,
            graphicsAdapterPathProvider: { _ in "/Applications/Stacio.app/Contents/Adapters/vnc" }
        )

        let status = try controller.openSavedSession(staleCredentialSession)

        XCTAssertEqual(status.runtimeId, "graphics_vnc_prompted")
        XCTAssertEqual(prompt.requests.map(\.protocolName), ["VNC"])
        XCTAssertEqual(prompt.requests.map(\.account), ["admin@desktop.example.com"])
        let updatedSession = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let credentialID = try XCTUnwrap(updatedSession.credentialId)
        XCTAssertNotEqual(credentialID, oldCredential.id)
        XCTAssertEqual(
            try keychainStore.readSecret(id: credentialID, account: "admin@desktop.example.com"),
            "prompted-vnc-secret"
        )
        let arguments = try XCTUnwrap(graphicsRuntime.requests.first?.arguments)
        XCTAssertEqual(Array(arguments.suffix(3)), ["--password", "prompted-vnc-secret", "desktop.example.com:5900"])
    }

    func testWorkbenchOpenSavedVNCSessionWithInvalidEndpointShowsEndpointDiagnostic() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let graphicsRuntime = RecordingGraphicsRuntimeManager(
            status: GraphicsRuntimeStatus(
                runtimeID: "graphics_should_not_start",
                status: "running",
                diagnostic: "should not start"
            )
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            graphicsRuntimeManager: graphicsRuntime,
            graphicsAdapterPathProvider: { _ in "/Applications/Stacio.app/Contents/Adapters/vnc" }
        )
        let session = SessionRecord(
            id: "session_vnc_invalid",
            folderId: nil,
            name: "VNC 桌面",
            protocol: "vnc",
            host: "",
            port: 5900,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? GraphicsSessionPaneViewController)
        XCTAssertEqual(status.status, "diagnostic")
        XCTAssertEqual(status.diagnostic, "图形会话端点无效")
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("图形会话端点无效"))
        XCTAssertTrue(graphicsRuntime.requests.isEmpty)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedTelnetSessionUsesEmbeddedTelnetStarter() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let telnetStarter = RecordingTelnetSessionStarter(
            status: LiveShellStatus(runtimeId: "term_telnet", status: "running", diagnostic: "telnet")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            telnetSessionStarter: telnetStarter,
            plaintextProtocolSessionConfirmation: RecordingPlaintextProtocolSessionConfirmation(shouldOpen: true)
        )
        let session = SessionRecord(
            id: "session_telnet",
            folderId: nil,
            name: "交换机",
            protocol: "telnet",
            host: "switch.example.com",
            port: 23,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_telnet")
        XCTAssertEqual(telnetStarter.configs.map(\.host), ["switch.example.com"])
        XCTAssertEqual(telnetStarter.configs.map(\.port), [23])
        XCTAssertEqual(telnetStarter.configs.map(\.username), ["admin"])
        XCTAssertEqual(telnetStarter.titles, ["交换机"])
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedTelnetSessionCancelingPlaintextWarningDoesNotStartOrMarkOpened() {
        let telnetStarter = RecordingTelnetSessionStarter(
            status: LiveShellStatus(runtimeId: "term_telnet", status: "running", diagnostic: "telnet")
        )
        let recentRecorder = RecordingSavedSessionOpenRecorder()
        let confirmation = RecordingPlaintextProtocolSessionConfirmation(shouldOpen: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            telnetSessionStarter: telnetStarter,
            plaintextProtocolSessionConfirmation: confirmation,
            savedSessionOpenRecorder: recentRecorder,
            databasePathProvider: { "/tmp/stacio-test.sqlite" }
        )
        let session = SessionRecord(
            id: "session_telnet_plaintext",
            folderId: nil,
            name: "交换机",
            protocol: "telnet",
            host: "switch.example.com",
            port: 23,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        XCTAssertThrowsError(try controller.openSavedSession(session)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(confirmation.requestedProtocols, ["Telnet"])
        XCTAssertTrue(confirmation.requestedMessages.first?.contains("Telnet 不加密") ?? false)
        XCTAssertTrue(confirmation.requestedMessages.first?.contains("受信任网络") ?? false)
        XCTAssertTrue(telnetStarter.configs.isEmpty)
        XCTAssertTrue(recentRecorder.requests.isEmpty)
    }

    func testWorkbenchOpenSavedSerialSessionUsesEmbeddedSerialStarter() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let serialStarter = RecordingSerialSessionStarter(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "serial")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter,
            serialSessionStarter: serialStarter
        )
        let session = SessionRecord(
            id: "session_serial",
            folderId: nil,
            name: "串口控制台",
            protocol: "serial",
            host: "/dev/cu.usbserial-001",
            port: 9_600,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_serial")
        XCTAssertEqual(serialStarter.configs.map(\.devicePath), ["/dev/cu.usbserial-001"])
        XCTAssertEqual(serialStarter.configs.map(\.baudRate), [9_600])
        XCTAssertEqual(serialStarter.titles, ["串口控制台"])
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedSerialSessionPrefersProtocolConfigJSON() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "高速串口",
                protocol: "serial",
                host: "/dev/cu.usbserial-002",
                port: 115_200,
                username: nil,
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: #"{"kind":"serial","devicePath":"/ignored","baudRate":1,"dataBits":7,"stopBits":2,"parity":"even","flowControl":"rtscts"}"#
            )
        )
        let serialStarter = RecordingSerialSessionStarter(
            status: LiveShellStatus(runtimeId: "term_serial_json", status: "running", diagnostic: "serial")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            serialSessionStarter: serialStarter,
            databasePathProvider: { tempURL.path }
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_serial_json")
        XCTAssertEqual(serialStarter.configs.map(\.devicePath), ["/dev/cu.usbserial-002"])
        XCTAssertEqual(serialStarter.configs.map(\.baudRate), [115_200])
        XCTAssertEqual(serialStarter.configs.map(\.dataBits), [7])
        XCTAssertEqual(serialStarter.configs.map(\.stopBits), [2])
        XCTAssertEqual(serialStarter.configs.map(\.parity), ["even"])
        XCTAssertEqual(serialStarter.configs.map(\.flowControl), ["rtscts"])
    }

    func testWorkbenchOpenSavedSerialSessionAllowsProtocolConfigWithoutBaudRate() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "蓝牙 Console",
                protocol: "serial",
                host: "/dev/cu.Stacio-Bluetooth",
                port: 0,
                username: nil,
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: #"{"kind":"serial","devicePath":"/dev/cu.Stacio-Bluetooth","dataBits":8,"stopBits":1,"parity":"none","flowControl":"none"}"#
            )
        )
        let serialStarter = RecordingSerialSessionStarter(
            status: LiveShellStatus(runtimeId: "term_serial_auto_baud", status: "running", diagnostic: "serial")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            serialSessionStarter: serialStarter,
            databasePathProvider: { tempURL.path }
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertEqual(status.runtimeId, "term_serial_auto_baud")
        XCTAssertEqual(serialStarter.configs.map(\.devicePath), ["/dev/cu.Stacio-Bluetooth"])
        XCTAssertEqual(serialStarter.configs.map(\.baudRate), [0])
        XCTAssertEqual(serialStarter.configs.map(\.dataBits), [8])
        XCTAssertEqual(serialStarter.configs.map(\.flowControl), ["none"])
    }

    func testWorkbenchOpenSavedShellSessionUsesLocalTerminalRuntime() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_shell",
            folderId: nil,
            name: "本地 Shell",
            protocol: "shell",
            host: "localhost",
            port: 1,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("term_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "本地 Shell 已打开")
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is TerminalPaneViewController)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedBrowserSessionUsesEmbeddedWebView() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_browser",
            folderId: nil,
            name: "Docs",
            protocol: "browser",
            host: "https://example.com",
            port: 443,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("browser_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "内置浏览器已打开")
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is BrowserPaneViewController)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedFileSessionUsesNativeFilePane() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteSessionStarter: starter
        )
        let session = SessionRecord(
            id: "session_file",
            folderId: nil,
            name: "下载目录",
            protocol: "file",
            host: NSTemporaryDirectory(),
            port: 1,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("file_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "本地文件面板已打开")
        XCTAssertEqual(workspace.openTerminalPaneCount, 1)
        XCTAssertTrue(workspace.currentTerminalPane is LocalFilePaneViewController)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedSCPSessionUsesEmbeddedFilesPane() throws {
        let contextBuilder = RecordingWorkbenchTunnelContextBuilder(
            context: TunnelLiveSessionContext(
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
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/release.tgz", size: 512, linkTarget: nil)
        ])
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteFilesBridge: filesBridge,
            remoteSessionStarter: starter,
            savedSessionContextBuilder: contextBuilder,
            databasePathProvider: { "/tmp/stacio-scp.sqlite" }
        )
        let session = SessionRecord(
            id: "session_scp",
            folderId: nil,
            name: "制品目录",
            protocol: "scp",
            host: "files.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("scp_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "文件面板已打开")
        XCTAssertEqual(contextBuilder.configs.map(\.host), ["files.example.com"])
        XCTAssertEqual(contextBuilder.configs.map(\.authMethod), [.agent])
        XCTAssertEqual(contextBuilder.databasePaths, ["/tmp/stacio-scp.sqlite"])
        XCTAssertEqual(filesBridge.liveHosts, ["files.example.com"])
        XCTAssertTrue(workspace.currentTerminalPane is RemoteFilesPaneViewController)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedFTPSessionUsesEmbeddedFTPFilesPane() throws {
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/pub/readme.txt", size: 64, linkTarget: nil)
        ])
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_wrong", status: "running", diagnostic: "running")
        )
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        try keychainStore.save(
            KeychainCredential(
                id: "cred_ftp",
                account: "deploy@ftp.example.com",
                secret: "ftp-password"
            )
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteFilesBridge: filesBridge,
            remoteSessionStarter: starter,
            ftpCredentialResolver: FTPCredentialResolver(store: keychainStore),
            plaintextProtocolSessionConfirmation: RecordingPlaintextProtocolSessionConfirmation(shouldOpen: true)
        )
        let session = SessionRecord(
            id: "session_ftp",
            folderId: nil,
            name: "FTP 文件",
            protocol: "ftp",
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: "cred_ftp",
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        let status = try controller.openSavedSession(session)

        XCTAssertTrue(status.runtimeId.hasPrefix("ftp_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "内置 FTP 文件面板已打开")
        XCTAssertEqual(filesBridge.ftpHosts, ["ftp.example.com"])
        XCTAssertEqual(filesBridge.ftpUsernames, ["deploy"])
        XCTAssertEqual(filesBridge.ftpSecrets, ["ftp-password"])
        XCTAssertTrue(workspace.currentTerminalPane is RemoteFilesPaneViewController)
        XCTAssertTrue(starter.startedConfigs.isEmpty)
    }

    func testWorkbenchOpenSavedFTPSessionCancelingPlaintextWarningDoesNotOpenFilesOrMarkOpened() {
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/pub/readme.txt", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let recentRecorder = RecordingSavedSessionOpenRecorder()
        let confirmation = RecordingPlaintextProtocolSessionConfirmation(shouldOpen: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            remoteFilesBridge: filesBridge,
            plaintextProtocolSessionConfirmation: confirmation,
            savedSessionOpenRecorder: recentRecorder,
            databasePathProvider: { "/tmp/stacio-test.sqlite" }
        )
        let session = SessionRecord(
            id: "session_ftp_plaintext",
            folderId: nil,
            name: "FTP 文件",
            protocol: "ftp",
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: "cred_ftp",
            tags: [],
            lastOpenedAt: nil
        )

        XCTAssertThrowsError(try controller.openSavedSession(session)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(confirmation.requestedProtocols, ["FTP"])
        XCTAssertTrue(confirmation.requestedMessages.first?.contains("FTP 不加密") ?? false)
        XCTAssertTrue(confirmation.requestedMessages.first?.contains("受信任网络") ?? false)
        XCTAssertEqual(workspace.openTerminalPaneCount, 0)
        XCTAssertTrue(filesBridge.ftpHosts.isEmpty)
        XCTAssertTrue(recentRecorder.requests.isEmpty)
    }

    func testWorkbenchOpenSavedSessionMarksOpenedAfterSuccessfulStart() throws {
        var events: [String] = []
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_saved_recent", status: "running", diagnostic: "running"),
            onStart: { events.append("start") }
        )
        let recentRecorder = RecordingSavedSessionOpenRecorder(onMark: { events.append("mark") })
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            savedSessionOpenRecorder: recentRecorder,
            databasePathProvider: { "/tmp/stacio-test.sqlite" }
        )
        let session = SessionRecord(
            id: "session_recent",
            folderId: nil,
            name: "Recent Host",
            protocol: "ssh",
            host: "recent.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        _ = try controller.openSavedSession(session)

        XCTAssertEqual(events, ["start", "mark"])
        XCTAssertEqual(recentRecorder.requests.map(\.databasePath), ["/tmp/stacio-test.sqlite"])
        XCTAssertEqual(recentRecorder.requests.map(\.id), ["session_recent"])
    }

    func testWorkbenchOpenSavedSessionDoesNotMarkOpenedWhenStartFails() {
        let starter = RecordingRemoteSessionStarter(error: TestWorkbenchError.failed)
        let recentRecorder = RecordingSavedSessionOpenRecorder()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            savedSessionOpenRecorder: recentRecorder,
            databasePathProvider: { "/tmp/stacio-test.sqlite" }
        )
        let session = SessionRecord(
            id: "session_recent",
            folderId: nil,
            name: "Recent Host",
            protocol: "ssh",
            host: "recent.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        XCTAssertThrowsError(try controller.openSavedSession(session))
        XCTAssertTrue(recentRecorder.requests.isEmpty)
    }

    func testQuickConnectToolbarPromptsAndStartsRemoteSession() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(target: "deploy@example.com:2200")
            )
        )

        controller.loadWindow()
        let status = try controller.quickConnectFromToolbar(nil)

        XCTAssertEqual(status?.runtimeId, "term_quick")
        XCTAssertEqual(starter.startedConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(starter.startedConfigs.map(\.port), [2200])
        XCTAssertEqual(starter.startedConfigs.map(\.connectTimeoutMs), [SSHConnectionDefaults.fastConnectTimeoutMs])
        XCTAssertEqual(starter.startedTitles, ["deploy@example.com"])
    }

    func testToolbarQuickConnectUsesWorkbenchQuickConnectFlow() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(target: "deploy@example.com")
            )
        )

        controller.loadWindow()
        controller.performQuickConnectFromToolbar(nil)

        XCTAssertEqual(starter.startedConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(starter.startedTitles, ["deploy@example.com"])
    }

    func testToolbarQuickConnectPresentsConnectionError() throws {
        let errorPresenter = RecordingQuickConnectErrorPresenter()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: RecordingRemoteSessionStarter(error: TestWorkbenchError.failed),
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(target: "deploy@example.com")
            ),
            quickConnectErrorPresenter: errorPresenter
        )

        controller.loadWindow()
        controller.performQuickConnectFromToolbar(nil)

        XCTAssertEqual(errorPresenter.presentedErrors.count, 1)
    }

    func testWorkspaceDoesNotExposeInlineQuickConnectControlsInDocumentLayout() throws {
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_inline", status: "running", diagnostic: "running")
        )
        let prompt = RecordingQuickConnectPromptPresenter(request: nil)
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            quickConnectPromptPresenter: prompt
        )

        controller.loadWindow()

        XCTAssertNil(controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Workspace.quickConnectTarget"))
        XCTAssertNil(controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Workspace.quickConnectButton"))
        XCTAssertEqual(prompt.callCount, 0)
        XCTAssertEqual(starter.startedConfigs.map(\.host), [])
        XCTAssertEqual(starter.startedTitles, [])
    }

    func testTerminalTabsRenderInSeparateRowBelowToolbar() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(workspaceViewController: workspace)

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        try workspace.openLocalShell()
        window.contentView?.layoutSubtreeIfNeeded()

        let contentView = try XCTUnwrap(window.contentView)
        let tabControl = try XCTUnwrap(contentView.allSubviews(ofType: NSSegmentedControl.self).first)
        let terminalView = try XCTUnwrap(workspace.currentTerminalPane?.view)
        let contentLayoutFrame = contentView.convert(window.contentLayoutRect, from: nil)
        let tabFrame = tabControl.convert(tabControl.bounds, to: contentView)
        let terminalFrame = terminalView.convert(terminalView.bounds, to: contentView)

        XCTAssertLessThanOrEqual(tabFrame.maxY, contentLayoutFrame.maxY - 1)
        XCTAssertGreaterThan(tabFrame.minY, terminalFrame.maxY)
        XCTAssertGreaterThanOrEqual(tabFrame.minX, terminalFrame.minX)
        XCTAssertLessThanOrEqual(tabFrame.minX, terminalFrame.minX + 16)
    }

    func testInspectorContentUsesCompactToolbarInsetWhenRevealedResizedAndSwitched() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        controller.showTunnelsFromToolbar(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        try assertInspectorUsesCompactToolbarInset(in: window)

        let splitView = controller.contentSplitViewController.splitView
        controller.setInspectorDividerPositionForTesting(splitView.bounds.width - 260 - splitView.dividerThickness)
        window.contentView?.layoutSubtreeIfNeeded()
        try assertInspectorUsesCompactToolbarInset(in: window)

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let browserIndex = try XCTUnwrap(inspector.sectionLabelsForTesting.firstIndex(of: L10n.Inspector.browser))
        inspector.selectSectionForTesting(browserIndex)
        window.contentView?.layoutSubtreeIfNeeded()

        try assertInspectorUsesCompactToolbarInset(in: window)

        let diagnosticsIndex = try XCTUnwrap(inspector.sectionLabelsForTesting.firstIndex(of: L10n.Inspector.logs))
        inspector.selectSectionForTesting(diagnosticsIndex)
        window.contentView?.layoutSubtreeIfNeeded()

        try assertInspectorUsesCompactToolbarInset(in: window)
    }

    func testInspectorHeaderUsesBaseTopMarginWhenWindowHasNoToolbar() throws {
        let inspector = InspectorViewController()
        inspector.view.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        inspector.view.layoutSubtreeIfNeeded()

        try assertInspectorHeaderTopConstraint(in: inspector.view, expectedToolbarInset: 0)
    }

    func testFilesInspectorTitleStartsNearToolbarOnInitialWindowDisplay() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.showFilesFromToolbar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        let toolbarInset = try windowToolbarTopInset(in: window)
        XCTAssertGreaterThan(toolbarInset, 0)
        try assertInspectorUsesCompactToolbarInset(in: window)

        let contentView = try XCTUnwrap(window.contentView)
        let filesTitle = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Files.title"),
            "Files title should be visible after opening the inspector files panel"
        )
        let titleFrame = filesTitle.convert(filesTitle.bounds, to: contentView)
        let titleTopGap = contentView.bounds.maxY - titleFrame.maxY
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertLessThan(
            titleTopGap,
            toolbarInset + 24,
            "Files title should not be pushed down by the full toolbar content-layout inset plus the file panel's own padding"
        )
        XCTAssertLessThanOrEqual(
            titleTopGap,
            inspector.maximumCompactToolbarTopInsetForTesting + 36,
            "Files title should start close to the toolbar with only the compact inspector margin"
        )
    }

    func testInspectorBrowserAndTunnelsKeepComfortableInternalTopPadding() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.showBrowserFromToolbar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        let contentView = try XCTUnwrap(window.contentView)
        let inspectorContent = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Inspector.content")
        )
        let inspectorContentFrame = inspectorContent.convert(inspectorContent.bounds, to: contentView)
        let browserAddress = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Browser.address"),
            "Browser address field should be visible after opening the browser inspector panel"
        )
        let browserAddressFrame = browserAddress.convert(browserAddress.bounds, to: contentView)
        XCTAssertGreaterThanOrEqual(
            inspectorContentFrame.maxY - browserAddressFrame.maxY,
            16,
            "Browser toolbar controls should not sit flush against the inspector content top"
        )

        controller.showTunnelsFromToolbar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        let tunnelsTitle = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Tunnels.title"),
            "Tunnels title should be visible after opening the tunnels inspector panel"
        )
        let tunnelsTitleFrame = tunnelsTitle.convert(tunnelsTitle.bounds, to: contentView)
        XCTAssertGreaterThanOrEqual(
            inspectorContentFrame.maxY - tunnelsTitleFrame.maxY,
            16,
            "Tunnels header should not sit flush against the inspector content top"
        )
    }

    func testInspectorSectionSwitcherIsHiddenWhenInspectorIsNarrowButSectionsRemainSelectable() throws {
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false)
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.showTunnelsFromToolbar(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        let splitView = controller.contentSplitViewController.splitView
        controller.setInspectorDividerPositionForTesting(splitView.bounds.width - 180 - splitView.dividerThickness)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let sectionControl = inspector.sectionControlForTesting
        XCTAssertNil(sectionControl.enclosingScrollView)

        for index in inspector.sectionLabelsForTesting.indices {
            inspector.selectSectionForTesting(index)
            XCTAssertEqual(inspector.selectedSectionIndexForTesting, index)
            XCTAssertEqual(sectionControl.selectedSegment, index)
        }
    }

    func testQuickConnectToolbarActionPresentsConnectionError() {
        let errorPresenter = RecordingQuickConnectErrorPresenter()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: RecordingRemoteSessionStarter(error: TestWorkbenchError.failed),
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(target: "deploy@example.com")
            ),
            quickConnectErrorPresenter: errorPresenter
        )

        controller.loadWindow()
        controller.performQuickConnectFromToolbar(nil)

        XCTAssertEqual(errorPresenter.presentedErrors.count, 1)
    }

    func testSidebarImportPresentsOuterSetupError() throws {
        let errorPresenter = RecordingSessionImportErrorPresenter()
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            sessionImportErrorPresenter: errorPresenter,
            databasePathProvider: { throw TestWorkbenchError.failed }
        )

        controller.loadWindow()
        controller.performImportFromToolbar(nil)

        XCTAssertEqual(errorPresenter.presentedErrors.count, 1)
    }

    func testWorkbenchInjectsLiveSessionContextIntoInspectorFilesCoordinator() throws {
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(
            with: TunnelLiveSessionContext(
                config: SshConnectionConfig(
                    host: "example.com",
                    port: 22,
                    username: "deploy",
                    authMethod: .agent,
                    connectTimeoutMs: 10_000
                ),
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test"
            )
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        let inspector = controller.contentSplitViewController
            .splitViewItems[2]
            .viewController as? InspectorViewController
        let entries = try inspector?.filesCoordinatorForTesting.loadCurrentLiveDirectory(remotePath: "/home/deploy")

        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(filesBridge.liveHosts, ["example.com"])
    }

    func testWorkbenchInspectorFilesFollowCurrentRemoteTerminalDirectoryWhenEnabled() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.contentSplitViewController
            .splitViewItems[2]
            .viewController as? InspectorViewController)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)

        pane.sendInput(Array("cd /srv/app\n".utf8))

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && inspector.filesViewController?.currentRemotePath == "/srv/app"
        })
        XCTAssertEqual(filesBridge.liveRemotePaths.last, "/srv/app")
        XCTAssertEqual(inspector.filesViewController?.currentRemotePath, "/srv/app")

        inspector.filesViewController?.setDirectoryFollowEnabled(false)
        pane.sendInput(Array("cd /var/log\n".utf8))

        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/var/log"))
        XCTAssertEqual(inspector.filesViewController?.currentRemotePath, "/srv/app")
    }

    func testTerminalDroppedUploadRefreshesBoundInspectorFilesListAfterCompletion() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("release.tar.gz")
        try Data(repeating: 1, count: 48).write(to: localFile)
        let uploadedEntry = RemoteFileEntry(
            kind: .file,
            path: "/srv/app/release.tar.gz",
            size: 48,
            linkTarget: nil
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [])
        let scpBridge = WorkbenchImmediateSCPTransferBridge { _ in
            filesBridge.replaceEntries([uploadedEntry])
        }
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            transferQueueCoordinatorFactory: { transferQueue in
                TransferQueueCoordinator(
                    bridge: scpBridge,
                    historyStore: NoOpSCPTransferHistoryStore(),
                    queueViewController: transferQueue
                )
            }
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        let initialDirectoryRequest = expectation(description: "files requests followed terminal directory")
        filesBridge.observeNextLiveRemoteDirectoryRequest(matching: "/srv/app") {
            initialDirectoryRequest.fulfill()
        }
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")
        XCTAssertEqual(inspector.filesViewController?.currentRemotePath, "/srv/app")
        wait(for: [initialDirectoryRequest], timeout: 3)

        let uploadDirectoryRefresh = expectation(description: "files refreshes after terminal drop upload")
        filesBridge.observeNextLiveRemoteDirectoryRequest(matching: "/srv/app") {
            uploadDirectoryRefresh.fulfill()
        }
        pane.performDropLocalFilesForTesting([localFile.path])

        wait(for: [uploadDirectoryRefresh], timeout: 3)
        XCTAssertTrue(waitUntil {
            inspector.filesViewController?.containsRemoteEntry(named: "release.tar.gz") == true
        })
        XCTAssertEqual(scpBridge.destinationPaths, ["/srv/app/release.tar.gz"])
        XCTAssertTrue(inspector.filesViewController?.visibleTextSnapshot.contains("release.tar.gz") == true)
    }

    func testWorkbenchInspectorFilesShowsFollowedDirectoryBeforeSlowListingCompletes() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = SlowFollowWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })

        filesBridge.delayNextRequest()
        pane.sendInput(Array("cd /srv/app\n".utf8))

        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })
        XCTAssertEqual(inspector.filesViewController?.currentRemotePath, "/srv/app")

        filesBridge.releaseDelayedRequest()
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })
    }

    func testWorkbenchInspectorFilesCoalescesRapidTerminalDirectoryChangesToLatestPath() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })

        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/one")
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/two")
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/latest")

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/latest"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/srv/latest"
        })
        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/srv/one"))
        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/srv/two"))
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath, "/srv/latest")
    }

    func testWorkbenchInspectorFilesFollowPromptDirectoryAfterTabCompletedRemoteCd() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "fengstor.example.com",
                port: 22,
                username: "FengLee",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/FengLee/.bashrc", size: 128, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "FengLee@FengStor",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil as Any?)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })

        pane.send(source: pane.terminalView, data: ArraySlice(Array("cd /\n".utf8)))
        pane.send(source: pane.terminalView, data: ArraySlice(Array("cd /ho".utf8)))
        pane.send(source: pane.terminalView, data: ArraySlice([9]))
        pane.send(source: pane.terminalView, data: ArraySlice(Array("\n".utf8)))
        pane.feedRemoteOutput(Array("FengLee@FengStor:/home$ ".utf8))
        pane.send(source: pane.terminalView, data: ArraySlice(Array("cd Feng".utf8)))
        pane.send(source: pane.terminalView, data: ArraySlice([9]))
        pane.send(source: pane.terminalView, data: ArraySlice(Array("\n".utf8)))
        pane.feedRemoteOutput(Array("FengLee@FengStor:~$ ".utf8))

        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.count >= 2 })
        XCTAssertEqual(filesBridge.liveRemotePaths.suffix(2), ["~", "~"])
        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/"))
        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/home"))
        XCTAssertTrue(waitUntil {
            controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/home/FengLee"
        })
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath, "/home/FengLee")
    }

    func testWorkbenchInspectorFilesFollowAnolisPromptFallbackWhenOSC7IsUnavailable() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "anolis8.example.com",
                port: 22,
                username: "root",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:anolis"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/opt/服务/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_anolis", status: "running", diagnostic: "running"),
            title: "root@anolis8",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil as Any?)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)

        pane.feedRemoteOutput(Array("\u{1B}]0;root@anolis8:/opt/服务\u{07}\u{1B}[01;32m[root@anolis8 /opt/服务]\u{1B}[00m# ".utf8))
        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/opt/服务"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/opt/服务"
        })

        pane.feedRemoteOutput(Array("\r\n[root@anolis8 ~/release]# ".utf8))
        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "~/release"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "~/release"
        })
        XCTAssertEqual(filesBridge.liveRemotePaths.suffix(2), ["/opt/服务", "~/release"])
    }

    func testWorkbenchInspectorFilesKeepsFollowedDirectoryWhenReloadingFilesSection() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)

        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })
        pane.sendInput(Array("cd /srv/app\n".utf8))
        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && inspector.filesViewController?.currentRemotePath == "/srv/app"
        })

        inspector.selectSectionForTesting(1)
        inspector.selectSectionForTesting(0)

        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.count >= 3 })
        XCTAssertEqual(filesBridge.liveRemotePaths.suffix(2), ["/srv/app", "/srv/app"])
        XCTAssertEqual(inspector.filesViewController?.currentRemotePath, "/srv/app")
    }

    func testWorkbenchInspectorFilesKeepsFollowingAfterSwitchingThroughAIAssistant() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })

        controller.showAIAssistantFromToolbar(nil)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && inspector.filesViewController?.currentRemotePath == "/srv/app"
        })

        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/var/log")

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/var/log"
                && inspector.filesViewController?.currentRemotePath == "/var/log"
        })
    }

    func testWorkbenchInspectorFilesRebindsHiddenFollowStateWhenTerminalTabChanges() throws {
        let firstContext = TunnelLiveSessionContext(
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
        let secondContext = TunnelLiveSessionContext(
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
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: firstContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/second/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first@example.com",
            liveSessionContext: firstContext
        )
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })

        inspector.selectAIAssistantTab()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second@example.com",
            liveSessionContext: secondContext
        )
        let secondPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        secondPane.hostCurrentDirectoryUpdate(source: secondPane.terminalView, directory: "/srv/second")

        inspector.selectFilesTabForTesting()

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/second"
                && inspector.filesViewController?.currentRemotePath == "/srv/second"
        })
        XCTAssertTrue(inspector.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_second",
                context: secondContext,
                remotePath: "/srv/second"
            )
        ))
    }

    func testFilesToolbarKeepsRemoteDirectoryAfterAIAssistantTakesKeyboardFocus() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")

        controller.showAIAssistantFromToolbar(nil)
        let questionField = try XCTUnwrap(
            controller.inspectorViewControllerForTesting?
                .aiAssistantViewController?
                .view
                .firstSubview(withIdentifier: "Stacio.AI.question") as? NSTextField
        )
        controller.window?.makeFirstResponder(questionField)

        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/srv/app"
        })
        XCTAssertTrue(controller.inspectorViewControllerForTesting?.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_remote",
                context: context,
                remotePath: "/srv/app"
            )
        ) == true)
    }

    func testFilesToolbarKeepsRemoteDirectoryAfterRemoteBrowserTakesKeyboardFocus() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            tunnelLiveBridge: RecordingWorkbenchLiveTunnelBridge(),
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        inspector.selectBrowserTab()
        let addressField = try XCTUnwrap(
            inspector.remoteBrowserViewController?
                .browserPaneViewControllerForTesting?
                .view
                .firstSubview(withIdentifier: "Stacio.Browser.address") as? NSTextField
        )
        controller.window?.makeFirstResponder(addressField)

        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && inspector.filesViewController?.currentRemotePath == "/srv/app"
        })
        XCTAssertTrue(inspector.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_remote",
                context: context,
                remotePath: "/srv/app"
            )
        ))
    }

    func testFilesToolbarKeepsRemoteDirectoryAfterLocalAgentTakesKeyboardFocus() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let localAgentLauncher = RecordingWorkbenchLocalAgentProcessLauncher()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge,
            aiLocalAgentToolResolver: WorkbenchStaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"]),
            aiLocalAgentProcessLauncherFactory: { localAgentLauncher }
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")

        controller.showAIAssistantFromToolbar(nil)
        let panel = try XCTUnwrap(controller.inspectorViewControllerForTesting?.aiAssistantViewController)
        workspace.focusCurrentTerminalForKeyboardInput()
        panel.startLocalAgentForTesting(.codex)
        let localAgentTerminal = try XCTUnwrap(panel.view.allSubviews(ofType: StacioLocalAgentTerminalView.self).first)

        XCTAssertTrue(waitUntil {
            controller.window?.firstResponder === localAgentTerminal
        })
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertIdentical(controller.window?.firstResponder, localAgentTerminal)
        XCTAssertTrue(localAgentTerminal.responds(to: #selector(NSText.paste(_:))))

        XCTAssertTrue(controller.window?.makeFirstResponder(pane.terminalView) == true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        panel.view.layoutSubtreeIfNeeded()
        let hitPoint = panel.view.convert(
            NSPoint(x: localAgentTerminal.bounds.midX, y: localAgentTerminal.bounds.midY),
            from: localAgentTerminal
        )
        _ = panel.view.hitTest(hitPoint)
        XCTAssertIdentical(controller.window?.firstResponder, localAgentTerminal)

        controller.showFilesFromToolbar(nil)

        XCTAssertEqual(localAgentLauncher.startedExecutable, "/tools/codex")
        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/srv/app"
        })
        XCTAssertTrue(controller.inspectorViewControllerForTesting?.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_remote",
                context: context,
                remotePath: "/srv/app"
            )
        ) == true)
    }

    func testWorkbenchInspectorFilesKeepsTerminalDirectoryChangesWhileInspectorIsHidden() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        controller.showFilesFromToolbar(nil as Any?)
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "~" })

        controller.showFilesFromToolbar(nil as Any?)
        XCTAssertTrue(controller.contentSplitViewController.splitViewItems[2].isCollapsed)

        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil as Any?)

        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath, "/srv/app")
    }

    func testFilesToolbarReloadsSameTerminalWhenCurrentDirectoryChanged() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/")
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/" })

        inspector.filesViewController?.setDirectoryFollowEnabled(false)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)

        XCTAssertFalse(controller.contentSplitViewController.splitViewItems[2].isCollapsed)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })
        XCTAssertEqual(inspector.filesViewController?.currentRemotePath, "/srv/app")
    }

    func testWorkbenchInspectorFilesFollowPushdPopdAndChainedDirectoryCommands() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            liveSessionContext: context
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)

        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })

        pane.sendInput(Array("pushd ../logs; cd releases\n".utf8))
        pane.sendInput(Array("popd\n".utf8))

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(filesBridge.liveRemotePaths, ["/srv/app"])
        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/srv/logs"))
        XCTAssertFalse(filesBridge.liveRemotePaths.contains("/srv/logs/releases"))
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath, "/srv/app")
    }

    func testWorkbenchInspectorFilesKeepsFollowingBoundRuntimeWhenCurrentPaneIsTemporarilyDifferent() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let reconnecter = RecordingWorkbenchRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_remote_split", status: "running", diagnostic: "running"),
            liveSessionContext: context
        )
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            reconnecter: reconnecter,
            liveSessionContext: context
        )
        let boundPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        boundPane.hostCurrentDirectoryUpdate(source: boundPane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })

        try workspace.splitCurrentTerminal()
        XCTAssertFalse(workspace.currentTerminalPane === boundPane)

        boundPane.sendInput(Array("cd /srv/releases\n".utf8))

        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/releases"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/srv/releases"
        })
        XCTAssertEqual(filesBridge.liveRemotePaths.last, "/srv/releases")
        XCTAssertEqual(controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath, "/srv/releases")
    }

    func testWorkbenchInspectorFilesRebindsToSelectedConnectedSSHTab() throws {
        let firstContext = TunnelLiveSessionContext(
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
        let secondContext = TunnelLiveSessionContext(
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
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: firstContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/current/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first",
            liveSessionContext: firstContext
        )
        let firstPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        firstPane.hostCurrentDirectoryUpdate(source: firstPane.terminalView, directory: "/srv/first")
        controller.showFilesFromToolbar(nil)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/first" })

        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second",
            liveSessionContext: secondContext
        )
        let secondPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        secondPane.hostCurrentDirectoryUpdate(source: secondPane.terminalView, directory: "/srv/second")

        XCTAssertTrue(waitUntil {
            filesBridge.liveHosts.last == "second.example.com"
                && filesBridge.liveRemotePaths.last == "/srv/second"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/srv/second"
        })
        XCTAssertTrue(controller.inspectorViewControllerForTesting?.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_second",
                context: secondContext,
                remotePath: "/srv/second"
            )
        ) == true)
    }

    func testWorkbenchInspectorFilesBindsUninitializedPanelWhenSwitchingToSSHTab() throws {
        let firstContext = TunnelLiveSessionContext(
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
        let secondContext = TunnelLiveSessionContext(
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
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: firstContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/second/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )

        workspace.loadView()
        try workspace.openLocalShell()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first",
            liveSessionContext: firstContext
        )
        let firstPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        firstPane.hostCurrentDirectoryUpdate(source: firstPane.terminalView, directory: "/srv/first")
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second",
            liveSessionContext: secondContext
        )
        let secondPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        secondPane.hostCurrentDirectoryUpdate(source: secondPane.terminalView, directory: "/srv/second")

        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )
        controller.loadWindow()
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(inspector.isFilesTabBound(to: nil))
        XCTAssertEqual(filesBridge.liveRemotePaths, [])

        workspace.selectTabForTesting(2)

        XCTAssertTrue(waitUntil {
            filesBridge.liveHosts.last == "second.example.com"
                && filesBridge.liveRemotePaths.last == "/srv/second"
                && inspector.filesViewController?.currentRemotePath == "/srv/second"
                && inspector.filesViewController?.entryCount == 1
        })
        XCTAssertTrue(inspector.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_second",
                context: secondContext,
                remotePath: "/srv/second"
            )
        ))
    }

    func testWorkbenchInspectorFilesUnbindsWhenSelectingLocalTerminalTab() throws {
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "remote.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:remote"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: context)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        try workspace.openLocalShell()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "remote",
            liveSessionContext: context
        )
        let remotePane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        remotePane.hostCurrentDirectoryUpdate(source: remotePane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)
        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/app"
                && controller.inspectorViewControllerForTesting?.filesViewController?.entryCount == 1
        })

        workspace.selectTabForTesting(0)

        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(waitUntil {
            inspector.isFilesTabBound(to: nil)
                && inspector.filesViewController?.entryCount == 0
        })
        XCTAssertTrue(inspector.filesViewController?.visibleTextSnapshot.contains("请选择一个已连接的远程终端") == true)
        XCTAssertEqual(filesBridge.liveRemotePaths, ["/srv/app"])
    }

    func testWorkbenchInspectorFilesRebindsToSelectedSSHWhenDirectoryFollowDisabled() throws {
        let firstContext = TunnelLiveSessionContext(
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
        let secondContext = TunnelLiveSessionContext(
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
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: firstContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/current/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_first", status: "running", diagnostic: "running"),
            title: "first",
            liveSessionContext: firstContext
        )
        let firstPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        firstPane.hostCurrentDirectoryUpdate(source: firstPane.terminalView, directory: "/srv/first")
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_second", status: "running", diagnostic: "running"),
            title: "second",
            liveSessionContext: secondContext
        )
        let secondPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        secondPane.hostCurrentDirectoryUpdate(source: secondPane.terminalView, directory: "/srv/second")
        workspace.selectTabForTesting(0)
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/first" })

        inspector.filesViewController?.setDirectoryFollowEnabled(false)
        workspace.selectTabForTesting(1)

        XCTAssertTrue(waitUntil {
            filesBridge.liveHosts.last == "second.example.com"
                && filesBridge.liveRemotePaths.last == "/srv/second"
                && inspector.filesViewController?.currentRemotePath == "/srv/second"
        })
        XCTAssertFalse(inspector.filesViewController?.isDirectoryFollowEnabled ?? true)
        XCTAssertTrue(inspector.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_second",
                context: secondContext,
                remotePath: "/srv/second"
            )
        ))
    }

    func testWorkbenchSelectingRemoteFilesTabKeepsItsOwnFilesSessionState() throws {
        let terminalContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "terminal.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:terminal"
        )
        let filesContext = TunnelLiveSessionContext(
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
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: terminalContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/files/release.tgz", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            title: "terminal",
            liveSessionContext: terminalContext
        )
        let terminalPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        terminalPane.hostCurrentDirectoryUpdate(source: terminalPane.terminalView, directory: "/srv/terminal")
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/terminal" })

        try workspace.openRemoteFilesSession(
            context: filesContext,
            title: "files",
            bridge: filesBridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/files"
        )

        XCTAssertTrue(waitUntil {
            workspace.currentTerminalPane is RemoteFilesPaneViewController
                && filesBridge.liveHosts.last == "files.example.com"
                && filesBridge.liveRemotePaths.last == "/srv/files"
        })
        XCTAssertTrue(workspace.currentTerminalPane is RemoteFilesPaneViewController)
        XCTAssertTrue(inspector.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_remote",
                context: terminalContext,
                remotePath: "/srv/terminal"
            )
        ))
    }

    func testWorkbenchInspectorFilesRebindsAfterPendingRemoteTerminalConnects() throws {
        let oldContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "old.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:old"
        )
        let newContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "new.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:new"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: oldContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/new/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_old", status: "running", diagnostic: "running"),
            title: "old",
            liveSessionContext: oldContext
        )
        let oldPane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        oldPane.hostCurrentDirectoryUpdate(source: oldPane.terminalView, directory: "/srv/old")
        controller.showFilesFromToolbar(nil)
        let inspector = try XCTUnwrap(controller.inspectorViewControllerForTesting)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/old" })

        workspace.closeCurrentTerminal()
        XCTAssertTrue(waitUntil {
            inspector.filesViewController?.visibleTextSnapshot.contains("文件连接已断开") == true
        })

        let pendingPane = workspace.openConnectingRemoteShell(
            title: "new",
            reconnecter: nil,
            connectionKind: .ssh,
            liveSessionContext: nil
        )
        pendingPane.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_new", status: "running", diagnostic: "running"),
            liveSessionContext: newContext
        )
        pendingPane.hostCurrentDirectoryUpdate(source: pendingPane.terminalView, directory: "/srv/new")

        XCTAssertTrue(waitUntil {
            filesBridge.liveHosts.last == "new.example.com"
                && filesBridge.liveRemotePaths.last == "/srv/new"
                && inspector.filesViewController?.currentRemotePath == "/srv/new"
                && inspector.filesViewController?.entryCount == 1
        })
        XCTAssertTrue(inspector.isFilesTabBound(
            to: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_new",
                context: newContext,
                remotePath: "/srv/new"
            )
        ))
        XCTAssertFalse(inspector.filesViewController?.visibleTextSnapshot.contains("文件连接已断开") == true)
    }

    func testWorkbenchInspectorFilesKeepsFollowingRemoteDirectoryAfterTerminalReconnect() throws {
        let oldContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:old"
        )
        let newContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:new"
        )
        let contextStore = TunnelLiveSessionStore()
        contextStore.replace(with: oldContext)
        let filesBridge = RecordingWorkbenchRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        let reconnecter = RecordingWorkbenchRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_new", status: "running", diagnostic: "running"),
            liveSessionContext: newContext
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            tunnelLiveSessionStore: contextStore,
            remoteFilesBridge: filesBridge
        )

        controller.loadWindow()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_old", status: "running", diagnostic: "running"),
            title: "deploy@example.com",
            reconnecter: reconnecter,
            liveSessionContext: oldContext
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        pane.hostCurrentDirectoryUpdate(source: pane.terminalView, directory: "/srv/app")
        controller.showFilesFromToolbar(nil)
        XCTAssertTrue(waitUntil { filesBridge.liveRemotePaths.last == "/srv/app" })

        try pane.reconnectTerminal()
        pane.sendInput(Array("cd /srv/releases\n".utf8))

        XCTAssertEqual(pane.runtimeID, "term_new")
        XCTAssertEqual(reconnecter.reconnectedTitles, ["deploy@example.com"])
        XCTAssertTrue(waitUntil {
            filesBridge.liveRemotePaths.last == "/srv/releases"
                && controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath == "/srv/releases"
        })
        XCTAssertEqual(
            controller.inspectorViewControllerForTesting?.filesViewController?.currentRemotePath,
            "/srv/releases"
        )
    }

    func testWorkbenchMultiExecPromptsPreparesAndBroadcastsToSelectedTargets() throws {
        let sink = RecordingWorkbenchTerminalEventSink()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
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
        let prompt = RecordingMultiExecPromptPresenter(
            request: MultiExecPromptRequest(
                input: "uptime\n",
                targetIDs: ["term_prod"],
                productionConfirmed: true
            )
        )
        let bridge = RecordingMultiExecBridge()
        let auditRecorder = RecordingMultiExecAuditRecorder()
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecPromptPresenter: prompt,
            multiExecBridge: bridge,
            multiExecAuditRecorder: auditRecorder,
            databasePathProvider: { "/tmp/stacio-multiexec-audit-test.sqlite" }
        )

        controller.loadWindow()
        let result = try controller.multiExecFromToolbar(nil)

        XCTAssertEqual(result?.targetCount, 1)
        XCTAssertEqual(result?.sentCount, 1)
        XCTAssertEqual(result?.failedCount, 0)
        XCTAssertEqual(result?.executed, true)
        XCTAssertEqual(prompt.presentedTargets.map(\.id), ["term_dev", "term_prod"])
        XCTAssertEqual(bridge.requests.map(\.productionConfirmed), [true])
        XCTAssertEqual(bridge.requests.first?.targets.map(\.id), ["term_prod"])
        XCTAssertEqual(auditRecorder.requests.map(\.databasePath), ["/tmp/stacio-multiexec-audit-test.sqlite"])
        XCTAssertEqual(auditRecorder.requests.map(\.event), [result])
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_prod", bytes: Array("uptime\n".utf8))
        ])
    }

    func testWorkbenchMultiExecToolbarStartsInteractiveSplitSelection() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API",
            connectionKind: .ssh
        )
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running"),
            title: "串口控制台",
            connectionKind: .serial
        )
        let selector = RecordingMultiExecSessionSelector(
            selection: MultiExecSessionSelection(targetIDs: ["term_dev", "term_serial"])
        )
        let prompt = RecordingMultiExecPromptPresenter(
            request: MultiExecPromptRequest(
                input: "should-not-run\n",
                targetIDs: ["term_dev"],
                productionConfirmed: false
            )
        )
        let bridge = RecordingMultiExecBridge()
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecPromptPresenter: prompt,
            multiExecSessionSelector: selector,
            multiExecBridge: bridge
        )

        controller.loadWindow()
        try controller.startMultiExecFromToolbar(nil)

        XCTAssertEqual(selector.presentedTargets.map(\.id), ["term_dev", "term_serial"])
        XCTAssertEqual(prompt.presentedTargets, [])
        XCTAssertTrue(bridge.requests.isEmpty)
        XCTAssertTrue(workspace.isMultiExecSessionActiveForTesting)
        XCTAssertEqual(workspace.currentSplitPaneRuntimeIDsForTesting, ["term_dev", "term_serial"])
    }

    func testWorkbenchMultiExecToolbarPresentsChineseErrorWhenSelectionIsInvalid() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API",
            connectionKind: .ssh
        )
        let selector = RecordingMultiExecSessionSelector(
            selection: MultiExecSessionSelection(targetIDs: ["term_dev"])
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecSessionSelector: selector
        )

        controller.loadWindow()

        XCTAssertThrowsError(try controller.startMultiExecFromToolbar(nil))
        XCTAssertEqual(selector.presentedTargets.map(\.id), [])
        XCTAssertEqual(selector.presentedErrorMessages, ["多执行需要至少两个可用终端。"])
    }

    func testWorkbenchMultiExecAuditCountsMissingSelectedTargetsAsFailed() throws {
        let sink = RecordingWorkbenchTerminalEventSink()
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API"
        )
        let prompt = RecordingMultiExecPromptPresenter(
            request: MultiExecPromptRequest(
                input: "uptime\n",
                targetIDs: ["term_dev", "missing_runtime"],
                productionConfirmed: false
            )
        )
        let bridge = RecordingMultiExecBridge()
        let auditRecorder = RecordingMultiExecAuditRecorder()
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecPromptPresenter: prompt,
            multiExecBridge: bridge,
            multiExecAuditRecorder: auditRecorder,
            databasePathProvider: { "/tmp/stacio-multiexec-audit-missing.sqlite" }
        )

        controller.loadWindow()
        let result = try controller.multiExecFromToolbar(nil)

        XCTAssertEqual(result?.targetCount, 2)
        XCTAssertEqual(result?.sentCount, 1)
        XCTAssertEqual(result?.failedCount, 1)
        XCTAssertEqual(bridge.requests.first?.targets.map(\.id), ["term_dev", "missing_runtime"])
        XCTAssertEqual(auditRecorder.requests.map(\.event), [result])
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_dev", bytes: Array("uptime\n".utf8))
        ])
    }

    func testWorkbenchMultiExecShowsBroadcastStateAndBlocksWindowCloseDuringExecution() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API"
        )
        let prompt = RecordingMultiExecPromptPresenter(
            request: MultiExecPromptRequest(
                input: "uptime\n",
                targetIDs: ["term_dev"],
                productionConfirmed: false
            )
        )
        let bridge = RecordingMultiExecBridge()
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecPromptPresenter: prompt,
            multiExecBridge: bridge,
            multiExecAuditRecorder: RecordingMultiExecAuditRecorder(),
            databasePathProvider: { "/tmp/stacio-multiexec-visible-state.sqlite" }
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        bridge.onPrepare = { [weak controller, weak window] in
            XCTAssertEqual(window?.title, "Stacio - 正在广播")
            guard let window else {
                XCTFail("Expected workbench window during MultiExec broadcast")
                return
            }
            XCTAssertEqual(controller?.windowShouldClose(window), false)
        }

        _ = try controller.multiExecFromToolbar(nil)

        XCTAssertEqual(window.title, "Stacio")
        XCTAssertEqual(controller.windowShouldClose(window), true)
    }

    func testWorkbenchMultiExecRestoresBroadcastStateWhenPrepareFails() throws {
        let workspace = WorkspaceViewController(
            shellPathProvider: { "/bin/zsh" },
            eventSinkFactory: { CoreBridgeTerminalEventSink() },
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { RecordingWorkbenchTerminalEventSink() },
            remoteTerminalBridgeFactory: { RecordingWorkbenchRemoteTerminalBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_dev", status: "running", diagnostic: "running"),
            title: "开发 API"
        )
        let prompt = RecordingMultiExecPromptPresenter(
            request: MultiExecPromptRequest(
                input: "uptime\n",
                targetIDs: ["term_dev"],
                productionConfirmed: false
            )
        )
        let bridge = RecordingMultiExecBridge()
        bridge.prepareError = TestWorkbenchError.failed
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            multiExecPromptPresenter: prompt,
            multiExecBridge: bridge,
            multiExecAuditRecorder: RecordingMultiExecAuditRecorder(),
            databasePathProvider: { "/tmp/stacio-multiexec-prepare-failure.sqlite" }
        )

        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        bridge.onPrepare = { [weak controller, weak window] in
            XCTAssertEqual(window?.title, "Stacio - 正在广播")
            guard let window else {
                XCTFail("Expected workbench window during MultiExec broadcast")
                return
            }
            XCTAssertEqual(controller?.windowShouldClose(window), false)
        }

        XCTAssertThrowsError(try controller.multiExecFromToolbar(nil))
        XCTAssertEqual(window.title, "Stacio")
        XCTAssertEqual(controller.windowShouldClose(window), true)
    }

    func testQuickConnectSavesSessionAfterSuccessfulConnection() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick_saved", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(
                    target: "deploy@example.com:2200",
                    saveAsSession: true,
                    sessionName: "API 快速连接"
                )
            ),
            databasePathProvider: { tempURL.path }
        )
        controller.loadWindow()
        let sidebar = try XCTUnwrap(
            controller.contentSplitViewController
                .splitViewItems[0]
                .viewController as? SessionSidebarViewController
        )

        _ = try controller.quickConnectFromToolbar(nil)

        let sessions = try CoreBridge.listAllSessionRecords(databasePath: tempURL.path)
        XCTAssertEqual(sessions.map(\.name), ["API 快速连接"])
        XCTAssertEqual(sessions.map(\.host), ["example.com"])
        XCTAssertEqual(sessions.map(\.port), [2200])
        XCTAssertEqual(sessions.map(\.username), ["deploy"])
        XCTAssertEqual(sessions.map(\.credentialId), [nil])
        XCTAssertEqual(sidebar.sessionOutlineTextSnapshot, "API 快速连接\ndeploy@example.com:2200")
    }

    func testQuickConnectDoesNotSaveSessionWhenConnectionFails() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: RecordingRemoteSessionStarter(error: TestWorkbenchError.failed),
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(
                    target: "deploy@example.com",
                    saveAsSession: true,
                    sessionName: "失败连接"
                )
            ),
            databasePathProvider: { tempURL.path }
        )

        controller.loadWindow()

        XCTAssertThrowsError(try controller.quickConnectFromToolbar(nil))
        XCTAssertEqual(try CoreBridge.listAllSessionRecords(databasePath: tempURL.path), [])
    }

    func testQuickConnectSavesPasswordCredentialToKeychainBeforeStartingAndCreatesSavedSessionReference() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick_password", status: "running", diagnostic: "running")
        )
        let credentialSaver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(
                    target: "deploy@example.com",
                    authMode: .password,
                    temporarySecret: "super-secret",
                    saveAsSession: true,
                    sessionName: "API 密码"
                )
            ),
            quickConnectCredentialSaver: credentialSaver,
            databasePathProvider: { tempURL.path }
        )

        controller.loadWindow()
        _ = try controller.quickConnectFromToolbar(nil)

        let session = try XCTUnwrap(CoreBridge.listAllSessionRecords(databasePath: tempURL.path).first)
        let credentialID = try XCTUnwrap(session.credentialId)
        XCTAssertEqual(starter.startedConfigs.map(\.authMethod), [.password(credentialRef: credentialID)])
        XCTAssertEqual(try keychainStore.readSecret(id: credentialID, account: "deploy@example.com"), "super-secret")
        XCTAssertFalse(String(describing: session).contains("super-secret"))
    }

    func testQuickConnectPasswordWithoutSavingSessionCleansTemporaryCredentialAfterSuccessfulStart() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        let credentialSaver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )
        let starter = RecordingRemoteSessionStarter(
            status: LiveShellStatus(runtimeId: "term_quick_password", status: "running", diagnostic: "running")
        )
        let controller = WorkbenchWindowController(
            workspaceViewController: WorkspaceViewController(autoStartTerminalProcesses: false),
            remoteSessionStarter: starter,
            quickConnectPromptPresenter: RecordingQuickConnectPromptPresenter(
                request: QuickConnectRequest(
                    target: "deploy@example.com",
                    authMode: .password,
                    temporarySecret: "super-secret",
                    saveAsSession: false
                )
            ),
            quickConnectCredentialSaver: credentialSaver,
            databasePathProvider: { tempURL.path }
        )

        controller.loadWindow()
        _ = try controller.quickConnectFromToolbar(nil)

        XCTAssertEqual(try CoreBridge.listAllSessionRecords(databasePath: tempURL.path), [])
        XCTAssertEqual(try CoreBridge.listCredentialRecords(databasePath: tempURL.path), [])
        XCTAssertEqual(starter.startedConfigs.map(\.authMethod).count, 1)
    }
}

private func workbenchSSHConfig(host: String) -> SshConnectionConfig {
    SshConnectionConfig(
        host: host,
        port: 22,
        username: "deploy",
        authMethod: .agent,
        connectTimeoutMs: 10_000
    )
}

private func makeTemporaryWorkbenchFile(name: String, contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StacioWorkbenchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(name)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

private func managedWorkbenchFrameDefaultsKey(_ name: NSWindow.FrameAutosaveName) -> String {
    "NSWindow Frame \(name)"
}

private func workbenchSplitWidthDefaultsKeyForTesting(
    _ frameAutosaveName: NSWindow.FrameAutosaveName,
    column: String
) -> String {
    "Stacio.WorkbenchSplit.\(column)Width.\(frameAutosaveName)"
}

private func defaultWorkbenchFrameAutosaveName() -> NSWindow.FrameAutosaveName {
    NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.v4")
}

private func makeWorkbenchModelProvider(
    id: UUID,
    name: String,
    baseURL: String,
    modelID: String
) -> AIProviderConfiguration {
    AIProviderConfiguration(
        id: id,
        profile: .openAICompatible,
        displayName: name,
        baseURL: baseURL,
        models: [
            AIProviderModelConfiguration(
                id: modelID,
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: true
            )
        ],
        defaultModelID: modelID,
        compatibilityProtocol: .chatCompletions,
        maxRetryCount: 1,
        requestTimeoutSeconds: 45,
        userAgent: "Stacio",
        isEnabled: true,
        lastVerifiedAt: nil,
        lastModelSyncAt: nil
    )
}

private final class RecordingWorkbenchAIAssistantHTTPTransport: AIAssistantHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStreamRequests: [URLRequest] = []

    var streamRequests: [URLRequest] {
        lock.withLock { recordedStreamRequests }
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        throw AIAssistantProviderError.streamUnsupported
    }

    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        lock.withLock {
            recordedStreamRequests.append(request)
        }

        let payload = try JSONSerialization.data(withJSONObject: [
            "choices": [
                [
                    "delta": [
                        "content": #"{"message":"ok","commands":[]}"#
                    ]
                ]
            ]
        ])
        var event = Data("data: ".utf8)
        event.append(payload)
        event.append(Data("\n\ndata: [DONE]\n\n".utf8))
        onChunk(event)
        return HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }
}

private func rootMinimumConstraintCount(in window: NSWindow) -> Int {
    guard let contentView = window.contentView else { return 0 }
    return contentView.constraints.filter { constraint in
        constraint.relation == .greaterThanOrEqual
            && constraint.secondItem == nil
            && (constraint.firstItem as? NSView) === contentView
            && (constraint.firstAttribute == .width || constraint.firstAttribute == .height)
    }.count
}

private func assertInspectorUsesCompactToolbarInset(
    in window: NSWindow,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let contentView = try XCTUnwrap(window.contentView, file: file, line: line)
    let inspectorRoot = try XCTUnwrap(
        contentView.firstSubview(withIdentifier: "Stacio.Inspector.surface"),
        file: file,
        line: line
    )
    let inspectorContent = try XCTUnwrap(
        contentView.firstSubview(withIdentifier: "Stacio.Inspector.content"),
        file: file,
        line: line
    )
    let toolbarInset = try windowToolbarTopInset(in: window, file: file, line: line)
    let maximumCompactInset = InspectorViewController().maximumCompactToolbarTopInsetForTesting
    let expectedInset = min(max(0, toolbarInset), maximumCompactInset)
    let topConstraint = try XCTUnwrap(
        inspectorRoot.constraints.first { constraint in
            (constraint.firstItem as? NSView) === inspectorContent
                && constraint.firstAttribute == .top
                && constraint.secondItem === inspectorRoot
                && constraint.secondAttribute == .top
        },
        file: file,
        line: line
    )
    XCTAssertEqual(
        topConstraint.constant,
        expectedInset + 18,
        accuracy: 1,
        "Inspector content should cap the toolbar inset so hidden headers do not leave a large blank region",
        file: file,
        line: line
    )
}

private func assertInspectorHeaderTopConstraint(
    in window: NSWindow,
    expectedToolbarInset: CGFloat? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let contentView = try XCTUnwrap(window.contentView, file: file, line: line)
    let header = try XCTUnwrap(
        contentView.firstSubview(withIdentifier: "Stacio.Inspector.header"),
        file: file,
        line: line
    )
    let inspectorRoot = try XCTUnwrap(header.superview, file: file, line: line)
    try assertInspectorHeaderTopConstraint(
        in: inspectorRoot,
        expectedToolbarInset: expectedToolbarInset ?? 0,
        file: file,
        line: line
    )
}

private func assertInspectorHeaderTopConstraint(
    in inspectorRoot: NSView,
    expectedToolbarInset: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let header = try XCTUnwrap(
        inspectorRoot.firstSubview(withIdentifier: "Stacio.Inspector.header"),
        file: file,
        line: line
    )
    let topConstraint = try XCTUnwrap(
        inspectorRoot.constraints.first { constraint in
            (constraint.firstItem as? NSView) === header
                && constraint.firstAttribute == .top
        },
        file: file,
        line: line
    )

    XCTAssertTrue(
        topConstraint.secondItem === inspectorRoot,
        "Inspector header top constraint should use the compact root inset instead of the full window safe area",
        file: file,
        line: line
    )
    let expectedCompactInset = min(
        max(0, expectedToolbarInset),
        InspectorViewController().maximumCompactToolbarTopInsetForTesting
    )
    XCTAssertEqual(
        topConstraint.constant,
        expectedCompactInset + 18,
        accuracy: 1,
        "Inspector header should keep only the compact toolbar inset plus the base margin",
        file: file,
        line: line
    )
}

private func windowToolbarTopInset(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
    let contentView = try XCTUnwrap(window.contentView, file: file, line: line)
    let contentLayoutFrame = contentView.convert(window.contentLayoutRect, from: nil)
    return max(0, contentView.bounds.maxY - contentLayoutFrame.maxY)
}

private func inspectorSafeAreaTopInset(containing view: NSView) -> CGFloat {
    var current: NSView? = view
    while let candidate = current {
        if candidate.accessibilityIdentifier() == "Stacio.Inspector.surface" {
            return candidate.safeAreaInsets.top
        }
        current = candidate.superview
    }
    return 0
}

private func assertWindowFrame(
    _ window: NSWindow,
    equals expected: NSRect,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(window.frame.origin.x, expected.origin.x, accuracy: 1, file: file, line: line)
    XCTAssertEqual(window.frame.origin.y, expected.origin.y, accuracy: 1, file: file, line: line)
    XCTAssertEqual(window.frame.width, expected.width, accuracy: 1, file: file, line: line)
    XCTAssertEqual(window.frame.height, expected.height, accuracy: 1, file: file, line: line)
}

private func sidebarToolbarButton(in controller: WorkbenchWindowController) throws -> SidebarToggleTitlebarButton {
    let window = try XCTUnwrap(controller.window)
    return try XCTUnwrap(
        window.toolbar?.items
            .compactMap { $0.view?.firstSubview(withIdentifier: "Stacio.Toolbar.sidebarToggle") as? SidebarToggleTitlebarButton }
            .first
    )
}

private func updatePromptToolbarButton(in controller: WorkbenchWindowController) throws -> UpdatePromptTitlebarButton {
    let window = try XCTUnwrap(controller.window)
    return try XCTUnwrap(
        window.toolbar?.items
            .compactMap { $0.view?.firstSubview(withIdentifier: "Stacio.Toolbar.updatePrompt") as? UpdatePromptTitlebarButton }
            .first
    )
}

private final class RecordingSparkleUpdateButtonController: SparkleUpdateButtonControlling {
    var buttonState: SparkleUpdateButtonState = .hidden
    var onButtonStateChanged: ((SparkleUpdateButtonState) -> Void)?
    var probeCount = 0
    var installCount = 0
    var senderDescriptions: [String] = []

    func checkForUpdates(_ sender: Any?) {
        senderDescriptions.append((sender as? NSObject)?.description ?? "<nil>")
        installAvailableUpdateFromPrompt()
    }

    func probeForAvailableUpdate() {
        probeCount += 1
    }

    func installAvailableUpdateFromPrompt() {
        installCount += 1
    }

    func publish(_ state: SparkleUpdateButtonState) {
        buttonState = state
        onButtonStateChanged?(state)
    }
}

private final class RecordingRemoteSessionStarter: RemoteSSHSessionStarting {
    var startedConfigs: [SshConnectionConfig] = []
    var startedTitles: [String] = []
    private let status: LiveShellStatus?
    private let error: Error?
    private let onStart: () -> Void

    init(
        status: LiveShellStatus,
        onStart: @escaping () -> Void = {}
    ) {
        self.status = status
        self.error = nil
        self.onStart = onStart
    }

    init(error: Error) {
        self.status = nil
        self.error = error
        self.onStart = {}
    }

    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        startedConfigs.append(config)
        startedTitles.append(title)
        onStart()
        if let error {
            throw error
        }
        return status!
    }
}

private final class RecordingAutomationRemoteSessionStarter: RemoteSSHSessionAutomationStarting {
    var startedConfigs: [SshConnectionConfig] = []
    var startedTitles: [String] = []
    var automationPolicies: [SessionAutomationPolicy] = []
    private let status: LiveShellStatus

    init(status: LiveShellStatus) {
        self.status = status
    }

    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        try start(config: config, title: title, automationPolicy: .default)
    }

    func start(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> LiveShellStatus {
        startedConfigs.append(config)
        startedTitles.append(title)
        automationPolicies.append(automationPolicy)
        return status
    }
}

private final class OneTimeFailingRemoteSessionStarter: RemoteSSHSessionStarting {
    var startedConfigs: [SshConnectionConfig] = []
    var startedTitles: [String] = []
    private let error: Error
    private let status: LiveShellStatus
    private var shouldFail = true

    init(error: Error, status: LiveShellStatus) {
        self.error = error
        self.status = status
    }

    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        startedConfigs.append(config)
        startedTitles.append(title)
        if shouldFail {
            shouldFail = false
            throw error
        }
        return status
    }
}

private final class RecordingSavedSessionCredentialPromptPresenter: SavedSessionCredentialPrompting {
    private(set) var requests: [SavedSessionCredentialPromptRequest] = []
    private let secret: String?

    init(secret: String?) {
        self.secret = secret
    }

    func promptForSavedSessionCredential(
        _ request: SavedSessionCredentialPromptRequest,
        parentWindow: NSWindow?
    ) -> String? {
        requests.append(request)
        return secret
    }
}

private struct HostMappedTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:\(config.host)"
        )
    }
}

private final class HostRuntimeLiveShellStarter: LiveShellStarting {
    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        LiveShellStatus(
            runtimeId: "term_\(config.host.replacingOccurrences(of: ".", with: "_"))",
            status: "running",
            diagnostic: "running"
        )
    }
}

private final class DelayedWorkbenchLiveShellStarter: LiveShellStarting {
    private let status: LiveShellStatus
    private let delay: TimeInterval

    init(status: LiveShellStatus, delay: TimeInterval) {
        self.status = status
        self.delay = delay
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        Thread.sleep(forTimeInterval: delay)
        return status
    }
}

private final class FailingWorkbenchLiveShellStarter: LiveShellStarting, @unchecked Sendable {
    private let error: Error
    private let lock = NSLock()
    private var recordedStartedConfigs: [SshConnectionConfig] = []

    var startedConfigs: [SshConnectionConfig] {
        lock.withLock { recordedStartedConfigs }
    }

    init(error: Error) {
        self.error = error
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        lock.withLock {
            recordedStartedConfigs.append(config)
        }
        throw error
    }
}

private final class RecordingTelnetSessionStarter: TelnetSessionStarting {
    private let status: LiveShellStatus
    private(set) var configs: [TelnetConnectionConfig] = []
    private(set) var titles: [String] = []

    init(status: LiveShellStatus) {
        self.status = status
    }

    func start(config: TelnetConnectionConfig, title: String) throws -> LiveShellStatus {
        configs.append(config)
        titles.append(title)
        return status
    }
}

private final class RecordingSerialSessionStarter: SerialSessionStarting {
    private let status: LiveShellStatus
    private(set) var configs: [SerialConnectionConfig] = []
    private(set) var titles: [String] = []

    init(status: LiveShellStatus) {
        self.status = status
    }

    func start(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus {
        configs.append(config)
        titles.append(title)
        return status
    }
}

private final class RecordingGraphicsRuntimeManager: GraphicsRuntimeManaging {
    private let status: GraphicsRuntimeStatus
    private(set) var requests: [GraphicsRuntimeStartRequest] = []
    private(set) var stoppedRuntimeIDs: [String] = []

    init(status: GraphicsRuntimeStatus) {
        self.status = status
    }

    func start(request: GraphicsRuntimeStartRequest) throws -> GraphicsRuntimeStatus {
        requests.append(request)
        return status
    }

    func stop(runtimeID: String) -> GraphicsRuntimeStatus {
        stoppedRuntimeIDs.append(runtimeID)
        return GraphicsRuntimeStatus(
            runtimeID: runtimeID,
            status: "closed",
            diagnostic: "closed"
        )
    }
}

private final class RecordingWorkbenchEmbeddedGraphicsSession: EmbeddedGraphicsSession {
    var onFrame: ((GraphicsFrame) -> Void)?
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?
    private(set) var inputEvents: [GraphicsInputEvent] = []

    func start() throws {}

    func stop() {}

    func sendInput(_ event: GraphicsInputEvent) {
        inputEvents.append(event)
    }
}

private final class RecordingSavedSessionOpenRecorder: SavedSessionOpenRecording {
    var requests: [(databasePath: String, id: String)] = []
    private let onMark: () -> Void

    init(onMark: @escaping () -> Void = {}) {
        self.onMark = onMark
    }

    func markSessionRecordOpened(databasePath: String, id: String) throws -> SessionRecord {
        requests.append((databasePath: databasePath, id: id))
        onMark()
        return SessionRecord(
            id: id,
            folderId: nil,
            name: "Recent Host",
            protocol: "ssh",
            host: "recent.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: "2026-05-28T00:00:00Z"
        )
    }
}

private final class RecordingWorkbenchTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    private let context: TunnelLiveSessionContext
    private(set) var configs: [SshConnectionConfig] = []
    private(set) var databasePaths: [String] = []

    init(context: TunnelLiveSessionContext) {
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

private enum TestWorkbenchError: Error {
    case failed
}

private final class RecordingQuickConnectPromptPresenter: QuickConnectPromptPresenting {
    let request: QuickConnectRequest?
    private(set) var callCount = 0

    init(request: QuickConnectRequest?) {
        self.request = request
    }

    func promptQuickConnect(parentWindow: NSWindow?) -> QuickConnectRequest? {
        callCount += 1
        return request
    }
}

private final class RecordingQuickConnectErrorPresenter: QuickConnectErrorPresenting {
    var presentedErrors: [Error] = []

    func presentQuickConnectError(_ error: Error, parentWindow: NSWindow?) {
        presentedErrors.append(error)
    }
}

private final class RecordingSessionImportErrorPresenter: SessionImportErrorPresenting {
    var presentedErrors: [Error] = []

    func presentSessionImportError(_ error: Error, parentWindow: NSWindow?) {
        presentedErrors.append(error)
    }
}

private final class RecordingMultiExecPromptPresenter: MultiExecPromptPresenting {
    var presentedTargets: [MultiExecTarget] = []
    private let request: MultiExecPromptRequest?

    init(request: MultiExecPromptRequest?) {
        self.request = request
    }

    func promptMultiExec(targets: [MultiExecTarget], parentWindow: NSWindow?) -> MultiExecPromptRequest? {
        presentedTargets = targets
        return request
    }
}

private final class RecordingMultiExecSessionSelector: MultiExecSessionSelecting {
    var presentedTargets: [MultiExecTarget] = []
    var presentedErrorMessages: [String] = []
    private let selection: MultiExecSessionSelection?

    init(selection: MultiExecSessionSelection?) {
        self.selection = selection
    }

    func selectMultiExecTargets(targets: [MultiExecTarget], parentWindow: NSWindow?) -> MultiExecSessionSelection? {
        presentedTargets = targets
        return selection
    }

    func presentMultiExecError(_ error: Error, parentWindow: NSWindow?) {
        presentedErrorMessages.append((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}

private final class RecordingMultiExecBridge: MultiExecPreparing {
    struct Request {
        let targets: [MultiExecTarget]
        let input: String
        let productionConfirmed: Bool
    }

    var requests: [Request] = []
    var onPrepare: (() -> Void)?
    var prepareError: Error?

    func prepareBroadcastInput(
        targets: [MultiExecTarget],
        input: String,
        productionConfirmed: Bool
    ) throws -> BroadcastAuditEvent {
        onPrepare?()
        if let prepareError {
            throw prepareError
        }
        requests.append(
            Request(
                targets: targets,
                input: input,
                productionConfirmed: productionConfirmed
            )
        )
        return BroadcastAuditEvent(
            targetCount: UInt32(targets.count),
            sentCount: 0,
            failedCount: 0,
            redactedInput: input,
            executed: false
        )
    }

    func markBroadcastExecuted(
        _ event: BroadcastAuditEvent,
        sentCount: UInt32
    ) -> BroadcastAuditEvent {
        BroadcastAuditEvent(
            targetCount: event.targetCount,
            sentCount: sentCount,
            failedCount: event.targetCount - sentCount,
            redactedInput: event.redactedInput,
            executed: true
        )
    }
}

private final class RecordingMultiExecAuditRecorder: MultiExecAuditRecording {
    struct Request: Equatable {
        let databasePath: String
        let event: BroadcastAuditEvent
    }

    var requests: [Request] = []

    func recordBroadcastAuditEvent(
        databasePath: String,
        event: BroadcastAuditEvent
    ) throws -> BroadcastAuditRecord {
        requests.append(Request(databasePath: databasePath, event: event))
        return BroadcastAuditRecord(
            id: "audit_1",
            traceId: "trace_1",
            targetCount: event.targetCount,
            sentCount: event.sentCount,
            failedCount: event.failedCount,
            redactedInput: event.redactedInput,
            executed: event.executed,
            createdAt: "2026-05-29T00:00:00Z"
        )
    }
}

private final class RecordingTerminalCloseConfirmation: TerminalCloseConfirming {
    var shouldClose: Bool
    private(set) var requestedTitles: [String] = []

    init(shouldClose: Bool) {
        self.shouldClose = shouldClose
    }

    func confirmCloseTerminal(title: String, parentWindow: NSWindow?) -> Bool {
        requestedTitles.append(title)
        return shouldClose
    }
}

private final class RecordingPlaintextProtocolSessionConfirmation: PlaintextProtocolSessionConfirming {
    var shouldOpen: Bool
    private(set) var requestedProtocols: [String] = []
    private(set) var requestedMessages: [String] = []

    init(shouldOpen: Bool) {
        self.shouldOpen = shouldOpen
    }

    func confirmPlaintextProtocolSession(protocolName: String, message: String, parentWindow: NSWindow?) -> Bool {
        requestedProtocols.append(protocolName)
        requestedMessages.append(message)
        return shouldOpen
    }
}

private final class RecordingWorkbenchTerminalEventSink: TerminalEventSink {
    var inputEvents: [TerminalInputEvent] = []
    var closedRuntimeIDs: [String] = []

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

private final class RecordingWorkbenchLocalTerminalLauncher: LocalTerminalProcessLaunching {
    private(set) var sentInput: [[UInt8]] = []

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool {
        false
    }

    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {}

    func terminate(_ terminalView: LocalProcessTerminalView) {}

    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {
        sentInput.append(bytes)
    }
}

private struct WorkbenchStaticLocalAgentToolResolver: LocalAgentToolResolving {
    let paths: [LocalAgentTool: String]

    func executablePath(for tool: LocalAgentTool) -> String? {
        paths[tool]
    }
}

private final class RecordingWorkbenchLocalAgentProcessLauncher: LocalTerminalProcessLaunching {
    private(set) var startedExecutable: String?
    private(set) var startedArgs: [String]?
    private(set) var startedEnvironment: [String]?
    private(set) var startedExecName: String?
    private(set) var startedCurrentDirectory: String?
    private(set) var startCount = 0
    private(set) var terminated = false
    var running = false

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool {
        running
    }

    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        startCount += 1
        startedExecutable = executable
        startedArgs = args
        startedEnvironment = environment
        startedExecName = execName
        startedCurrentDirectory = currentDirectory
        running = true
    }

    func terminate(_ terminalView: LocalProcessTerminalView) {
        terminated = true
        running = false
    }

    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {}
}

private final class RecordingWorkbenchRemoteTerminalBridge: RemoteTerminalBridging {
    var closedRuntimeIDs: [String] = []

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
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

private final class RecordingWorkbenchRemoteTerminalReconnecter: RemoteTerminalReconnecting {
    private let status: LiveShellStatus
    private(set) var liveSessionContext: TunnelLiveSessionContext?
    private(set) var reconnectedTitles: [String] = []

    init(status: LiveShellStatus, liveSessionContext: TunnelLiveSessionContext? = nil) {
        self.status = status
        self.liveSessionContext = liveSessionContext
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        reconnectedTitles.append(title)
        return status
    }
}

private final class RecordingWorkbenchDeviceMetricsProvider: DeviceMetricsProviding {
    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        completion(.success(DeviceMetricsDisplaySnapshot(
            cpuUsage: 0.12,
            memory: DeviceMemoryDisplayUsage(usedBytes: 1024, totalBytes: 4096),
            networks: [],
            disks: []
        )))
    }
}

private final class RecordingWorkbenchLiveTunnelBridge: LiveTunnelCoreBridging {
    var startedProfiles: [TunnelProfile] = []

    func checkLocalPortAvailable(_ profile: TunnelProfile) throws {}

    func startLiveLocalTunnelRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        startedProfiles.append(profile)
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

private final class RecordingWorkbenchRemoteFilesBridge: RemoteFilesBridging {
    private let recordingQueue = DispatchQueue(label: "Stacio.Tests.RecordingWorkbenchRemoteFilesBridge")
    private var recordedLiveHosts: [String] = []
    private var recordedLiveRemotePaths: [String] = []
    private var recordedExpectedFingerprints: [String] = []
    private var recordedFTPHosts: [String] = []
    private var recordedFTPUsernames: [String] = []
    private var recordedFTPSecrets: [String] = []
    private var recordedEntries: [RemoteFileEntry]
    private var nextLiveRemoteDirectoryRequestObserver: (path: String, handler: () -> Void)?

    init(entries: [RemoteFileEntry]) {
        self.recordedEntries = entries
    }

    func replaceEntries(_ entries: [RemoteFileEntry]) {
        recordingQueue.sync {
            recordedEntries = entries
        }
    }

    var liveHosts: [String] {
        recordingQueue.sync { recordedLiveHosts }
    }

    var liveRemotePaths: [String] {
        recordingQueue.sync { recordedLiveRemotePaths }
    }

    var expectedFingerprints: [String] {
        recordingQueue.sync { recordedExpectedFingerprints }
    }

    var ftpHosts: [String] {
        recordingQueue.sync { recordedFTPHosts }
    }

    var ftpUsernames: [String] {
        recordingQueue.sync { recordedFTPUsernames }
    }

    var ftpSecrets: [String] {
        recordingQueue.sync { recordedFTPSecrets }
    }

    func observeNextLiveRemoteDirectoryRequest(
        matching path: String,
        handler: @escaping () -> Void
    ) {
        recordingQueue.sync {
            nextLiveRemoteDirectoryRequestObserver = (path, handler)
        }
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        recordingQueue.sync { recordedEntries }
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        let result = recordingQueue.sync { () -> ([RemoteFileEntry], (() -> Void)?) in
            recordedLiveHosts.append(config.host)
            recordedLiveRemotePaths.append(remotePath)
            recordedExpectedFingerprints.append(expectedFingerprintSHA256)
            let observer: (() -> Void)?
            if nextLiveRemoteDirectoryRequestObserver?.path == remotePath {
                observer = nextLiveRemoteDirectoryRequestObserver?.handler
                nextLiveRemoteDirectoryRequestObserver = nil
            } else {
                observer = nil
            }
            return (recordedEntries, observer)
        }
        result.1?()
        return result.0
    }

    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        recordingQueue.sync {
            recordedFTPHosts.append(config.host)
            recordedFTPUsernames.append(config.username)
            switch secret {
            case .password(let value):
                recordedFTPSecrets.append(value)
            case .anonymous:
                recordedFTPSecrets.append("anonymous")
            }
            return recordedEntries
        }
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

private final class RuntimeScopedWorkbenchRemoteFilesBridge: RemoteFilesBridging {
    private let lock = NSLock()
    private let entriesByFingerprint: [String: [RemoteFileEntry]]
    private var shouldDelayNextRequest = false
    private let delayedRequestStarted = DispatchSemaphore(value: 0)
    private let delayedRequestRelease = DispatchSemaphore(value: 0)
    private(set) var expectedFingerprints: [String] = []

    init(entriesByFingerprint: [String: [RemoteFileEntry]]) {
        self.entriesByFingerprint = entriesByFingerprint
    }

    func delayNextRequest() {
        lock.lock()
        shouldDelayNextRequest = true
        lock.unlock()
    }

    func waitUntilDelayedRequestStarted(timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if delayedRequestStarted.wait(timeout: .now()) == .success {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return delayedRequestStarted.wait(timeout: .now()) == .success
    }

    func releaseDelayedRequest() {
        delayedRequestRelease.signal()
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        []
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        let shouldDelay: Bool = lock.withLock {
            expectedFingerprints.append(expectedFingerprintSHA256)
            let shouldDelay = shouldDelayNextRequest
            shouldDelayNextRequest = false
            return shouldDelay
        }
        if shouldDelay {
            delayedRequestStarted.signal()
            _ = delayedRequestRelease.wait(timeout: .now() + 1)
        }
        return entriesByFingerprint[expectedFingerprintSHA256] ?? []
    }

    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
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

private final class WorkbenchImmediateSCPTransferBridge: SCPTransferBridging {
    private let recordingQueue = DispatchQueue(label: "Stacio.Tests.WorkbenchImmediateSCPTransferBridge")
    private var recordedDestinationPaths: [String] = []
    private let onTransfer: (ScpTransferJob) -> Void

    init(onTransfer: @escaping (ScpTransferJob) -> Void = { _ in }) {
        self.onTransfer = onTransfer
    }

    var destinationPaths: [String] {
        recordingQueue.sync { recordedDestinationPaths }
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        recordingQueue.sync {
            recordedDestinationPaths.append(job.destinationPath)
        }
        onTransfer(job)
        return [
            ScpTransferProgress(
                jobId: job.id,
                bytesDone: job.bytesTotal,
                bytesTotal: job.bytesTotal,
                status: "completed"
            )
        ]
    }
}

private final class SlowFollowWorkbenchRemoteFilesBridge: RemoteFilesBridging {
    private let recordingQueue = DispatchQueue(label: "Stacio.Tests.SlowFollowWorkbenchRemoteFilesBridge")
    private var recordedLiveRemotePaths: [String] = []
    private var shouldDelayNextRequest = false
    private let delayedRequestStarted = DispatchSemaphore(value: 0)
    private let delayedRequestRelease = DispatchSemaphore(value: 0)
    private let entries: [RemoteFileEntry]

    init(entries: [RemoteFileEntry]) {
        self.entries = entries
    }

    var liveRemotePaths: [String] {
        recordingQueue.sync { recordedLiveRemotePaths }
    }

    func delayNextRequest() {
        recordingQueue.sync {
            shouldDelayNextRequest = true
        }
    }

    func releaseDelayedRequest() {
        delayedRequestRelease.signal()
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
        let shouldDelay = recordingQueue.sync { () -> Bool in
            recordedLiveRemotePaths.append(remotePath)
            let value = shouldDelayNextRequest
            shouldDelayNextRequest = false
            return value
        }
        if shouldDelay {
            delayedRequestStarted.signal()
            _ = delayedRequestRelease.wait(timeout: .now() + 1)
        }
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
}

private extension InspectorViewController {
    var tunnelsViewControllerForTesting: TunnelsViewController {
        tunnelsViewController!
    }

    var selectedTabLabelForTesting: String? {
        selectedTabLabel
    }

    var filesCoordinatorForTesting: FilesCoordinator {
        let mirror = Mirror(reflecting: self)
        return mirror.children.first { $0.label == "filesCoordinator" }?.value as! FilesCoordinator
    }
}

private extension WorkbenchWindowController {
    var inspectorViewControllerForTesting: InspectorViewController? {
        contentSplitViewController
            .splitViewItems
            .compactMap { $0.viewController as? InspectorViewController }
            .first
    }
}

private extension WorkspaceViewController {
    var tabLabelsForWorkbenchTesting: [String] {
        let mirror = Mirror(reflecting: self)
        let tabController = mirror.children.first { $0.label == "tabViewController" }?.value as? NSTabViewController
        return tabController?.tabViewItems.map(\.label) ?? []
    }
}

private func workbenchLiveContext(
    host: String = "172.16.10.250",
    expectedFingerprintSHA256: String? = nil
) -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: host,
            port: 22,
            username: "root",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: expectedFingerprintSHA256 ?? "SHA256:\(host)"
    )
}

private extension TunnelsViewController {
    func startForTesting(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        setTunnelProfiles([profile])
        performTunnelActionForTesting(at: 0)
        return TunnelRuntimeStatus(
            profileId: profile.id,
            state: runningTunnelCount == 1 ? .running : .failed,
            message: ""
        )
    }
}

@MainActor
private final class RecordingWorkbenchAgentActionConfirmer: AgentActionConfirming {
    private let confirmed: Bool
    private(set) var confirmations: [AgentActionConfirmation] = []

    init(confirmed: Bool) {
        self.confirmed = confirmed
    }

    func confirmAgentAction(_ confirmation: AgentActionConfirmation, parentWindow: NSWindow?) -> Bool {
        confirmations.append(confirmation)
        return confirmed
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

    func nearestSuperview<T: NSView>(ofType type: T.Type) -> T? {
        var candidate = superview
        while let current = candidate {
            if let typed = current as? T {
                return typed
            }
            candidate = current.superview
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
}
