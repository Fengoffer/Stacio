import AppKit
import StacioCoreBindings
import StacioAgentBridge
import UniformTypeIdentifiers

public enum TerminalSplitLayoutMode: Equatable {
    case single
    case vertical
    case horizontal
    case grid
}

public enum WorkspaceTerminalError: Error, LocalizedError {
    case noCurrentTerminal
    case multiExecRequiresMultipleTargets

    public var errorDescription: String? {
        switch self {
        case .noCurrentTerminal:
            return L10n.Workspace.terminalUnavailable
        case .multiExecRequiresMultipleTargets:
            return L10n.MultiExec.requiresMultipleTargets
        }
    }
}

private struct MultiExecInteractiveSession {
    var targetIDs: [String]
    var pausedIDs: Set<String>
}

public enum WorkspaceTabContextAction: Int, CaseIterable {
    case rename
    case setColor
    case duplicate
    case closeTab
    case closeTabsToLeft
    case closeTabsToRight
    case closeOtherTabs
    case closeAllTabs
    case detach
    case toggleFullscreen
    case pin
    case saveTerminalOutput
    case printTerminalOutput
    case increaseFontSize
    case decreaseFontSize
}

@MainActor
public protocol WorkspaceTabOperationsPresenting {
    func promptRenameTab(currentTitle: String, parentWindow: NSWindow?) -> String?
    func chooseTabColor(currentColor: NSColor, title: String, parentWindow: NSWindow?) -> NSColor?
    func chooseTerminalOutputDestination(suggestedName: String, parentWindow: NSWindow?) -> URL?
    func presentTerminalOutputSaved(destinationURL: URL, parentWindow: NSWindow?)
    func presentError(title: String, message: String, parentWindow: NSWindow?)
}

@MainActor
public protocol WorkspaceTerminalOutputPrinting {
    func printTerminalOutput(_ output: String, title: String, parentWindow: NSWindow?) throws
}

@MainActor
public protocol WorkspaceTabDetaching {
    func detachTab(
        contentViewController: NSViewController,
        title: String,
        parentWindow: NSWindow?
    ) throws -> NSWindowController
}

@MainActor
public protocol WorkspaceFullscreenToggling {
    func toggleFullScreen(window: NSWindow?)
}

@MainActor
public final class AppKitWorkspaceTabOperationsPresenter: WorkspaceTabOperationsPresenting {
    public init() {}

    public func promptRenameTab(currentTitle: String, parentWindow: NSWindow?) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = currentTitle
        field.placeholderString = currentTitle

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.WorkspaceTabs.rename
        alert.informativeText = L10n.WorkspaceTabs.renameMessage
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.WorkspaceTabs.renameConfirm)
        alert.addButton(withTitle: L10n.Common.cancel)
        _ = parentWindow

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func chooseTabColor(currentColor: NSColor, title: String, parentWindow: NSWindow?) -> NSColor? {
        let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 120, height: 32))
        colorWell.color = currentColor

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.WorkspaceTabs.setColor
        alert.informativeText = L10n.WorkspaceTabs.colorMessage
        alert.accessoryView = colorWell
        alert.addButton(withTitle: L10n.WorkspaceTabs.colorConfirm)
        alert.addButton(withTitle: L10n.Common.cancel)
        _ = title
        _ = parentWindow

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return colorWell.color
    }

    public func chooseTerminalOutputDestination(suggestedName: String, parentWindow: NSWindow?) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        panel.title = L10n.WorkspaceTabs.saveTerminalOutput
        _ = parentWindow
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func presentTerminalOutputSaved(destinationURL: URL, parentWindow: NSWindow?) {
        presentInfo(
            title: L10n.WorkspaceTabs.saveOutputCompleteTitle,
            message: destinationURL.path,
            parentWindow: parentWindow
        )
    }

    public func presentError(title: String, message: String, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    private func presentInfo(title: String, message: String, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}

public struct AppKitWorkspaceTerminalOutputPrinter: WorkspaceTerminalOutputPrinting {
    public init() {}

    public func printTerminalOutput(_ output: String, title: String, parentWindow: NSWindow?) throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.string = output
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.jobDisposition = .spool
        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = title
        if let parentWindow {
            operation.runModal(for: parentWindow, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

@MainActor
public final class AppKitWorkspaceTabDetacher: WorkspaceTabDetaching {
    public init() {}

    public func detachTab(
        contentViewController: NSViewController,
        title: String,
        parentWindow: NSWindow?
    ) throws -> NSWindowController {
        let window = NSWindow(contentViewController: contentViewController)
        window.title = title
        window.setContentSize(NSSize(width: 920, height: 620))
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        let controller = NSWindowController(window: window)
        controller.showWindow(parentWindow)
        return controller
    }
}

public struct AppKitWorkspaceFullscreenToggler: WorkspaceFullscreenToggling {
    public init() {}

    public func toggleFullScreen(window: NSWindow?) {
        window?.toggleFullScreen(nil)
    }
}

public final class WorkspaceViewController: NSViewController {
    private let shellPathProvider: () -> String
    private let eventSinkFactory: () -> TerminalEventSink
    private let autoStartTerminalProcesses: Bool
    private let remoteTerminalEventSinkFactory: () -> TerminalEventSink
    private let remoteTerminalBridgeFactory: () -> RemoteTerminalBridging
    private let localTerminalProcessLauncherFactory: () -> LocalTerminalProcessLaunching
    private let startsRemoteTerminalPollingAutomatically: Bool
    private let deviceMetricsProviderFactory: (TunnelLiveSessionContext) -> DeviceMetricsProviding
    private let startsDeviceMetricsPollingAutomatically: Bool
    private let remoteOSProbe: @Sendable (TunnelLiveSessionContext) throws -> RemoteOperatingSystemInfo
    private let settingsStore: AppSettingsStore
    private let tabOperationsPresenter: WorkspaceTabOperationsPresenting
    private let terminalOutputPrinter: WorkspaceTerminalOutputPrinting
    private let tabDetacher: WorkspaceTabDetaching
    private let fullscreenToggler: WorkspaceFullscreenToggling
    private let commandHistoryStore: TerminalCommandHistoryStore
    private let commandCompletionNotifier: TerminalCommandCompletionNotificationDelivering
    private let deviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering
    private let tabViewController = WorkspaceTabViewController()
    private let emptyIconView = NSImageView()
    private let emptyPromptLabel = NSTextField(labelWithString: "连接到你的第一台主机")
    private let emptyPromptSubtitleLabel = NSTextField(labelWithString: "输入目标地址，或从左侧会话列表打开连接")
    private let emptyPromptPanel = NSView()
    private let emptyQuickStartStack = NSStackView()
    private let emptyLocalTerminalButton = WorkspaceViewController.makeEmptyActionButton(
        title: L10n.Workspace.startLocalTerminal,
        symbolName: "plus.circle.fill",
        identifier: "Stacio.Workspace.action.localShell"
    )
    private let emptyNewSessionButton = WorkspaceViewController.makeEmptyActionButton(
        title: L10n.Workspace.addSession,
        symbolName: "plus",
        identifier: "Stacio.Workspace.action.newSession"
    )
    private var emptyStateContentViews: [NSView] = []
    private var tabWorkspaces: [NSTabViewItem: TerminalSplitWorkspace] = [:]
    private var tabMetadata: [NSTabViewItem: WorkspaceTabMetadata] = [:]
    private var tabDuplicateHandlers: [NSTabViewItem: (String) throws -> Void] = [:]
    private var paneTabRestorations: [ObjectIdentifier: WorkspacePaneTabRestoration] = [:]
    private var detachedTabWindows: [NSWindowController] = []
    private var multiExecSession: MultiExecInteractiveSession?
    private var terminalSelectionNotificationGeneration: UInt64 = 0
    private var runtimeIDReattachments: [String: String] = [:]
    private var settingsObserver: NSObjectProtocol?
    private weak var lastCommandTerminalPane: NSViewController?
    private lazy var commandCompletionNotificationCoordinator = TerminalCommandCompletionNotificationCoordinator(
        settingsProvider: { [weak self] in
            self?.settingsStore.snapshot() ?? AppSettings()
        },
        activeTerminalProvider: { [weak self] runtimeID in
            self?.isForegroundActiveTerminal(runtimeID: runtimeID) ?? false
        },
        notifier: commandCompletionNotifier
    )
    public private(set) var isDeviceMetricsDashboardEnabled = true

    public var suppressEmptyPrompt = false {
        didSet {
            guard isViewLoaded else { return }
            updateEmptyState(animated: true)
        }
    }
    public private(set) var currentTerminalPane: NSViewController?
    public var onRequestNewSession: (() -> Void)?
    public var onRemoteTerminalDirectoryChanged: ((RemoteTerminalPaneViewController, String) -> Void)?
    public var onRemoteTerminalRuntimeReattached: ((RemoteTerminalPaneViewController, String, LiveShellStatus, TunnelLiveSessionContext?) -> Void)?
    public var onRemoteTerminalClosed: ((RemoteTerminalPaneViewController) -> Bool)?
    public var onRemoteTerminalUploadDroppedFiles: ((RemoteTerminalPaneViewController, String, [String]) -> Void)?
    public var onCurrentRemoteTerminalChanged: ((RemoteTerminalPaneViewController?) -> Void)?
    public var onCurrentRemoteTerminalAttached: ((RemoteTerminalPaneViewController) -> Void)?
    public var onCurrentTerminalChanged: (() -> Void)?
    public var onCommandHistoryChanged: (() -> Void)?
    public var onAIContextRequest: ((TerminalAIContextRequest) -> Void)?
    public var terminalMacroRecorder: TerminalMacroRecorder?

    public init(
        shellPathProvider: @escaping () -> String = WorkspaceViewController.defaultShellPath,
        eventSinkFactory: @escaping () -> TerminalEventSink = { CoreBridgeTerminalEventSink() },
        autoStartTerminalProcesses: Bool = true,
        remoteTerminalEventSinkFactory: @escaping () -> TerminalEventSink = { CoreBridgeTerminalEventSink() },
        remoteTerminalBridgeFactory: @escaping () -> RemoteTerminalBridging = { CoreBridgeRemoteTerminalBridge() },
        startsRemoteTerminalPollingAutomatically: Bool = true,
        deviceMetricsProviderFactory: @escaping (TunnelLiveSessionContext) -> DeviceMetricsProviding = { CoreBridgeDeviceMetricsProvider(context: $0) },
        startsDeviceMetricsPollingAutomatically: Bool = true,
        remoteOSProbe: @escaping @Sendable (TunnelLiveSessionContext) throws -> RemoteOperatingSystemInfo = { context in
            try CoreBridge.probeLiveRemoteOperatingSystem(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256
            )
        },
        settingsStore: AppSettingsStore = .shared,
        tabOperationsPresenter: WorkspaceTabOperationsPresenting? = nil,
        terminalOutputPrinter: WorkspaceTerminalOutputPrinting? = nil,
        tabDetacher: WorkspaceTabDetaching? = nil,
        fullscreenToggler: WorkspaceFullscreenToggling? = nil,
        commandHistoryStore: TerminalCommandHistoryStore = TerminalCommandHistoryStore(),
        commandCompletionNotifier: TerminalCommandCompletionNotificationDelivering? = nil,
        deviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering? = nil,
        localTerminalProcessLauncherFactory: @escaping () -> LocalTerminalProcessLaunching = {
            SwiftTermLocalTerminalProcessLauncher()
        }
    ) {
        self.shellPathProvider = shellPathProvider
        self.eventSinkFactory = eventSinkFactory
        self.autoStartTerminalProcesses = autoStartTerminalProcesses
        self.remoteTerminalEventSinkFactory = remoteTerminalEventSinkFactory
        self.remoteTerminalBridgeFactory = remoteTerminalBridgeFactory
        self.localTerminalProcessLauncherFactory = localTerminalProcessLauncherFactory
        self.startsRemoteTerminalPollingAutomatically = startsRemoteTerminalPollingAutomatically
        self.deviceMetricsProviderFactory = deviceMetricsProviderFactory
        self.startsDeviceMetricsPollingAutomatically = startsDeviceMetricsPollingAutomatically
        self.remoteOSProbe = remoteOSProbe
        self.settingsStore = settingsStore
        self.tabOperationsPresenter = tabOperationsPresenter ?? AppKitWorkspaceTabOperationsPresenter()
        self.terminalOutputPrinter = terminalOutputPrinter ?? AppKitWorkspaceTerminalOutputPrinter()
        self.tabDetacher = tabDetacher ?? AppKitWorkspaceTabDetacher()
        self.fullscreenToggler = fullscreenToggler ?? AppKitWorkspaceFullscreenToggler()
        self.commandHistoryStore = commandHistoryStore
        self.commandCompletionNotifier = commandCompletionNotifier ?? Self.defaultCommandCompletionNotifier()
        self.deviceMetricsAlertNotifier = deviceMetricsAlertNotifier ?? Self.defaultDeviceMetricsAlertNotifier()
        super.init(nibName: nil, bundle: nil)
        (self.commandCompletionNotifier as? UserNotificationTerminalCommandCompletionNotifier)?.setActivationHandler { [weak self] runtimeID in
            self?.activateTerminal(runtimeID: runtimeID, bringAppToFront: true)
        }
        (self.deviceMetricsAlertNotifier as? DeviceMetricsAlertNotificationActivating)?.setActivationHandler { [weak self] runtimeID in
            self?.activateTerminal(runtimeID: runtimeID, bringAppToFront: true)
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var openTerminalPaneCount: Int {
        tabWorkspaces.values.reduce(0) { $0 + $1.panes.count }
    }

    public override func loadView() {
        let container = StacioAppearanceRefreshView()
        container.onEffectiveAppearanceRefresh = { [weak self] in
            self?.refreshWorkspaceAppearance()
        }
        StacioDesignSystem.applyWorkspaceSurface(container)

        let contentContainer = NSView()
        contentContainer.setAccessibilityIdentifier("Stacio.Workspace.content")
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        addChild(tabViewController)
        tabViewController.didSelectItem = { [weak self] in
            self?.syncCurrentTerminalPaneWithSelectedTab()
        }
        tabViewController.addLocalTerminalHandler = { [weak self] in
            self?.openLocalShellFromTabStrip()
        }
        tabViewController.menuProvider = { [weak self] index in
            self?.makeContextMenu(forTabAt: index)
        }
        tabViewController.menuActionHandler = { [weak self] action, index in
            try self?.performTabContextAction(action, index: index)
        }
        tabViewController.closeHoveredTabHandler = { [weak self] index in
            try self?.performTabContextAction(.closeTab, index: index)
        }
        tabViewController.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(tabViewController.view)

        configureEmptyPromptPanel()
        contentContainer.addSubview(emptyPromptPanel)

        container.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tabViewController.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tabViewController.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            tabViewController.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tabViewController.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            emptyPromptPanel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            emptyPromptPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            emptyPromptPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            emptyPromptPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        view = container
        observeSettingsChanges()
        refreshWorkspaceAppearance()
        updateEmptyState(animated: false)
        refreshWorkspaceAppearance()
    }

    @discardableResult
    public func openLocalShell() throws -> String {
        let terminalPane = makeLocalTerminalPane()

        let item = makeTerminalTab(label: L10n.Workspace.local, firstPane: terminalPane)
        item.label = L10n.Workspace.local
        tabDuplicateHandlers[item] = { [weak self] title in
            try self?.openLocalShellForDuplicate(title: title)
        }
        select(item, currentPane: terminalPane)
        return terminalPane.runtimeID
    }

    public func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind
    ) {
        openRemoteShell(
            status: status,
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: nil
        )
    }

    public func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        automationPolicy: SessionAutomationPolicy
    ) {
        openRemoteShell(
            status: status,
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: nil,
            automationPolicy: automationPolicy
        )
    }

    public func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openRemoteShell(
            status: status,
            title: title,
            reconnecter: reconnecter,
            connectionKind: .ssh
        )
    }

    public func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting? = nil,
        connectionKind: RemoteTerminalConnectionKind = .ssh,
        liveSessionContext: TunnelLiveSessionContext? = nil,
        automationPolicy: SessionAutomationPolicy = .default
    ) {
        openRemoteShell(
            status: status,
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            automationPolicy: automationPolicy,
            manualIconID: nil
        )
    }

    public func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting? = nil,
        connectionKind: RemoteTerminalConnectionKind = .ssh,
        liveSessionContext: TunnelLiveSessionContext? = nil,
        automationPolicy: SessionAutomationPolicy = .default,
        manualIconID: String?
    ) {
        let terminalPane = RemoteTerminalPaneViewController(
            runtimeID: status.runtimeId,
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            eventSink: remoteTerminalEventSinkFactory(),
            bridge: remoteTerminalBridgeFactory(),
            reconnecter: reconnecter,
            settingsStore: settingsStore,
            automationPolicy: automationPolicy,
            startsPollingAutomatically: startsRemoteTerminalPollingAutomatically
        )
        configureRemoteTerminalPane(terminalPane)

        let deviceDashboard = makeDeviceMetricsDashboard(
            runtimeID: status.runtimeId,
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext
        )
        let item = makeTerminalTab(label: title, firstPane: terminalPane, deviceDashboard: deviceDashboard)
        item.label = title
        configureRemoteTabIcon(for: item, connectionKind: connectionKind, manualIconID: manualIconID)
        if let reconnecter {
            tabDuplicateHandlers[item] = { [weak self, weak reconnecter] duplicateTitle in
                guard let self, let reconnecter else {
                    throw WorkspaceTabActionError.unsupportedDuplicate
                }
                try self.duplicateRemoteShell(
                    title: duplicateTitle,
                    reconnecter: reconnecter,
                    connectionKind: connectionKind,
                    automationPolicy: automationPolicy,
                    manualIconID: manualIconID
                )
            }
        }
        detectRemoteOSIconIfNeeded(for: terminalPane, status: status, liveSessionContext: liveSessionContext)
        select(item, currentPane: terminalPane)
    }

    @discardableResult
    public func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteTerminalPaneViewController {
        openConnectingRemoteShell(
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            automationPolicy: .default
        )
    }

    @discardableResult
    public func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?,
        automationPolicy: SessionAutomationPolicy
    ) -> RemoteTerminalPaneViewController {
        openConnectingRemoteShell(
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            automationPolicy: automationPolicy,
            manualIconID: nil
        )
    }

    @discardableResult
    public func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?,
        automationPolicy: SessionAutomationPolicy,
        manualIconID: String?
    ) -> RemoteTerminalPaneViewController {
        let terminalPane = RemoteTerminalPaneViewController(
            runtimeID: "pending_\(UUID().uuidString.lowercased())",
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            eventSink: remoteTerminalEventSinkFactory(),
            bridge: remoteTerminalBridgeFactory(),
            reconnecter: reconnecter,
            settingsStore: settingsStore,
            automationPolicy: automationPolicy,
            startsPollingAutomatically: startsRemoteTerminalPollingAutomatically
        )
        configureRemoteTerminalPane(terminalPane)
        terminalPane.displayConnectionStarting()

        let item = makeTerminalTab(label: title, firstPane: terminalPane)
        item.label = title
        configureRemoteTabIcon(for: item, connectionKind: connectionKind, manualIconID: manualIconID)
        if let reconnecter {
            tabDuplicateHandlers[item] = { [weak self, weak reconnecter] duplicateTitle in
                guard let self, let reconnecter else {
                    throw WorkspaceTabActionError.unsupportedDuplicate
                }
                try self.duplicateRemoteShell(
                    title: duplicateTitle,
                    reconnecter: reconnecter,
                    connectionKind: connectionKind,
                    automationPolicy: automationPolicy,
                    manualIconID: manualIconID
                )
            }
        }
        select(item, currentPane: terminalPane)
        return terminalPane
    }

    private func duplicateRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting,
        connectionKind: RemoteTerminalConnectionKind,
        automationPolicy: SessionAutomationPolicy,
        manualIconID: String?
    ) throws {
        guard let backgroundReconnecter = reconnecter as? RemoteTerminalBackgroundReconnecting else {
            let status = try reconnecter.reconnectRemoteTerminal(title: title)
            openRemoteShell(
                status: status,
                title: title,
                reconnecter: reconnecter,
                connectionKind: connectionKind,
                liveSessionContext: reconnecter.liveSessionContext,
                automationPolicy: automationPolicy,
                manualIconID: manualIconID
            )
            return
        }

        let pane = openConnectingRemoteShell(
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: reconnecter.liveSessionContext,
            automationPolicy: automationPolicy,
            manualIconID: manualIconID
        )
        backgroundReconnecter.reconnectRemoteTerminalInBackground(
            title: title,
            automatically: false
        ) { [pane, weak reconnecter] result in
            guard pane.lifecycleState != .closed else {
                if case let .success(status) = result {
                    pane.discardUnattachedRuntime(status)
                }
                return
            }
            switch result {
            case let .success(status):
                pane.attachConnectedRuntime(
                    status: status,
                    liveSessionContext: reconnecter?.liveSessionContext,
                    automationPolicy: automationPolicy
                )
            case let .failure(error):
                pane.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
            }
        }
    }

    @discardableResult
    public func openBrowserSession(urlString: String, title: String) throws -> String {
        guard let url = normalizedBrowserURL(urlString) else {
            throw BrowserPaneError.invalidURL(urlString)
        }
        let runtimeID = "browser_\(UUID().uuidString.lowercased())"
        let browserPane = BrowserPaneViewController(runtimeID: runtimeID, url: url, title: title)

        let item = makeTerminalTab(label: title, firstPane: browserPane)
        item.label = title
        tabDuplicateHandlers[item] = { [weak self] duplicateTitle in
            _ = try self?.openBrowserSession(urlString: url.absoluteString, title: duplicateTitle)
        }
        select(item, currentPane: browserPane)
        return runtimeID
    }

    @discardableResult
    public func openFileSession(path: String, title: String) throws -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        let runtimeID = "file_\(UUID().uuidString.lowercased())"
        let filePane = LocalFilePaneViewController(
            runtimeID: runtimeID,
            directoryURL: URL(fileURLWithPath: expandedPath, isDirectory: true),
            title: title
        )

        let item = makeTerminalTab(label: title, firstPane: filePane)
        item.label = title
        tabDuplicateHandlers[item] = { [weak self, directoryURL = filePane.directoryURL] duplicateTitle in
            _ = try self?.openFileSession(path: directoryURL.path, title: duplicateTitle)
        }
        select(item, currentPane: filePane)
        return runtimeID
    }

    @discardableResult
    public func openRemoteFilesSession(
        context: TunnelLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling?,
        initialRemotePath: String = "~"
    ) throws -> String {
        let runtimeID = "scp_\(UUID().uuidString.lowercased())"
        let filesPane = RemoteFilesPaneViewController(
            runtimeID: runtimeID,
            context: context,
            title: title,
            bridge: bridge,
            transferScheduler: transferScheduler,
            initialRemotePath: initialRemotePath,
            remoteFilePathTerminalSender: { [weak self] path in
                _ = self?.sendTextToCurrentTerminal(path)
            }
        )
        _ = filesPane.view

        let item = makeTerminalTab(label: title, firstPane: filesPane)
        item.label = title
        tabDuplicateHandlers[item] = { [weak self, context, bridge, weak transferScheduler] duplicateTitle in
            _ = try self?.openRemoteFilesSession(
                context: context,
                title: duplicateTitle,
                bridge: bridge,
                transferScheduler: transferScheduler,
                initialRemotePath: initialRemotePath
            )
        }
        select(item, currentPane: filesPane)
        return runtimeID
    }

    @discardableResult
    public func openFTPFilesSession(
        context: FTPLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        ftpTransferScheduler: FTPTransferScheduling? = nil
    ) throws -> String {
        let runtimeID = "ftp_\(UUID().uuidString.lowercased())"
        let filesPane = RemoteFilesPaneViewController(
            runtimeID: runtimeID,
            ftpContext: context,
            title: title,
            bridge: bridge,
            ftpTransferScheduler: ftpTransferScheduler,
            remoteFilePathTerminalSender: { [weak self] path in
                _ = self?.sendTextToCurrentTerminal(path)
            }
        )
        _ = filesPane.view

        let item = makeTerminalTab(label: title, firstPane: filesPane)
        item.label = title
        tabDuplicateHandlers[item] = { [weak self, context, bridge, weak ftpTransferScheduler] duplicateTitle in
            _ = try self?.openFTPFilesSession(
                context: context,
                title: duplicateTitle,
                bridge: bridge,
                ftpTransferScheduler: ftpTransferScheduler
            )
        }
        select(item, currentPane: filesPane)
        return runtimeID
    }

    @discardableResult
    public func openGraphicsSession(
        title: String,
        diagnostic: GraphicsSessionDiagnostic,
        runtimeID providedRuntimeID: String? = nil,
        attachment: GraphicsRuntimeAttachment? = nil,
        onClose: ((String) -> Void)? = nil
    ) -> String {
        let runtimeID = providedRuntimeID ?? "graphics_\(UUID().uuidString.lowercased())"
        let graphicsPane = GraphicsSessionPaneViewController(
            runtimeID: runtimeID,
            title: title,
            diagnostic: diagnostic,
            attachment: attachment,
            onClose: onClose
        )

        let item = makeTerminalTab(label: title, firstPane: graphicsPane)
        item.label = title
        configureGraphicsTabIcon(for: item, protocolName: diagnostic.protocolName)
        tabDuplicateHandlers[item] = { [weak self, diagnostic, onClose] duplicateTitle in
            _ = self?.openGraphicsSession(
                title: duplicateTitle,
                diagnostic: diagnostic,
                onClose: onClose
            )
        }
        select(item, currentPane: graphicsPane)
        return runtimeID
    }

    public var currentTerminalTitle: String? {
        syncCurrentTerminalPaneWithFirstResponder()
        return currentTerminalPane.map { title(for: $0) }
    }

    public var currentRemoteTerminalLiveSessionContext: TunnelLiveSessionContext? {
        syncCurrentTerminalPaneWithFirstResponder()
        if let remoteTerminal = currentTerminalPane as? RemoteTerminalPaneViewController {
            return remoteTerminal.liveSessionContext
        }
        if let remoteFiles = currentTerminalPane as? RemoteFilesPaneViewController {
            return remoteFiles.context
        }
        return nil
    }

    public var currentPaneOwnsRemoteSessionContext: Bool {
        syncCurrentTerminalPaneWithFirstResponder()
        return currentTerminalPane is RemoteTerminalPaneViewController
            || currentTerminalPane is RemoteFilesPaneViewController
    }

    public var currentRemoteTerminalDirectory: String? {
        syncCurrentTerminalPaneWithFirstResponder()
        if let remoteTerminal = currentTerminalPane as? RemoteTerminalPaneViewController {
            return remoteTerminal.currentRemoteDirectory
        }
        if let remoteFiles = currentTerminalPane as? RemoteFilesPaneViewController {
            return remoteFiles.currentRemotePath
        }
        return nil
    }

    public var currentRemoteFilesBinding: InspectorViewController.RemoteFilesBinding? {
        syncCurrentTerminalPaneWithFirstResponder()
        guard let remoteTerminal = currentTerminalPane as? RemoteTerminalPaneViewController,
              let context = remoteTerminal.liveSessionContext
        else {
            return nil
        }
        return InspectorViewController.RemoteFilesBinding(
            runtimeID: remoteTerminal.runtimeID,
            context: context,
            remotePath: remoteTerminal.currentRemoteDirectory
        )
    }

    public var currentLocalTerminalDirectory: String? {
        syncCurrentTerminalPaneWithFirstResponder()
        guard let localTerminal = currentTerminalPane as? TerminalPaneViewController else {
            return nil
        }
        return localTerminal.currentLocalDirectory
    }

    public func aiTerminalContext(runtimeID: String?) -> AITerminalContext? {
        syncCurrentTerminalPaneWithFirstResponder()
        let terminalPane: AgentTerminalTarget?
        if let runtimeID, runtimeID.isEmpty == false {
            terminalPane = terminalPaneForRuntimeID(runtimeID)
        } else {
            terminalPane = currentTerminalPaneForAgent()
        }
        guard let terminalPane else { return nil }
        if let remoteTerminal = terminalPane as? RemoteTerminalPaneViewController {
            return AITerminalContext(
                runtimeID: remoteTerminal.runtimeID,
                title: remoteTerminal.terminalTitle,
                currentDirectory: remoteTerminal.currentRemoteDirectory,
                recentTranscript: remoteTerminal.terminalOutputTranscript
            )
        }
        if let localTerminal = terminalPane as? TerminalPaneViewController {
            return AITerminalContext(
                runtimeID: localTerminal.runtimeID,
                title: title(for: localTerminal),
                currentDirectory: localTerminal.currentLocalDirectory,
                recentTranscript: localTerminal.terminalOutputTranscript
            )
        }
        return nil
    }

    public func currentAITerminalContext() -> AITerminalContext? {
        aiTerminalContext(runtimeID: nil)
    }

    public func requestAIForCurrentTerminalForTesting(selectedText: String?) {
        guard let target = currentTerminalPaneForAgent() else {
            return
        }
        onAIContextRequest?(
            TerminalAIContextRequest(
                runtimeID: target.runtimeID,
                selectedText: selectedText
            )
        )
    }

    public var isCurrentPaneLocalTerminal: Bool {
        syncCurrentTerminalPaneWithFirstResponder()
        return currentTerminalPane is TerminalPaneViewController
    }

    public func splitCurrentTerminal() throws {
        guard let selectedItem = selectedTabViewItem,
              let workspace = tabWorkspaces[selectedItem],
              let sourcePane = workspace.selectedPane
        else {
            throw WorkspaceTerminalError.noCurrentTerminal
        }

        let pane: NSViewController
        if let remote = sourcePane as? RemoteTerminalPaneViewController {
            guard let reconnecter = remote.reconnecterForWorkspace else {
                throw WorkspaceTabActionError.unsupportedDuplicate
            }
            let status: LiveShellStatus
            if let background = reconnecter as? RemoteTerminalBackgroundReconnecting {
                status = LiveShellStatus(runtimeId: "pending_\(UUID().uuidString.lowercased())", status: "connecting", diagnostic: "connecting")
                let remotePane = RemoteTerminalPaneViewController(
                    runtimeID: status.runtimeId,
                    title: remote.terminalTitle,
                    connectionKind: remote.connectionKind,
                    liveSessionContext: reconnecter.liveSessionContext,
                    eventSink: remoteTerminalEventSinkFactory(),
                    bridge: remoteTerminalBridgeFactory(),
                    reconnecter: reconnecter,
                    settingsStore: settingsStore,
                    automationPolicy: remote.automationPolicy,
                    startsPollingAutomatically: startsRemoteTerminalPollingAutomatically
                )
                configureRemoteTerminalPane(remotePane)
                remotePane.displayConnectionStarting()
                installDirectSplitPane(
                    remotePane,
                    duplicating: sourcePane,
                    in: workspace,
                    tabItem: selectedItem
                )
                background.reconnectRemoteTerminalInBackground(title: remote.terminalTitle, automatically: false) { [remotePane] result in
                    guard remotePane.lifecycleState != .closed else {
                        if case let .success(connected) = result {
                            remotePane.discardUnattachedRuntime(connected)
                        }
                        return
                    }
                    switch result {
                    case let .success(connected):
                        remotePane.attachConnectedRuntime(status: connected, liveSessionContext: reconnecter.liveSessionContext, automationPolicy: remote.automationPolicy)
                    case let .failure(error):
                        remotePane.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
                    }
                }
                return
            }
            status = try reconnecter.reconnectRemoteTerminal(title: remote.terminalTitle)
            let remotePane = RemoteTerminalPaneViewController(
                runtimeID: status.runtimeId,
                title: remote.terminalTitle,
                connectionKind: remote.connectionKind,
                liveSessionContext: reconnecter.liveSessionContext,
                eventSink: remoteTerminalEventSinkFactory(),
                bridge: remoteTerminalBridgeFactory(),
                reconnecter: reconnecter,
                settingsStore: settingsStore,
                automationPolicy: remote.automationPolicy,
                startsPollingAutomatically: startsRemoteTerminalPollingAutomatically
            )
            configureRemoteTerminalPane(remotePane)
            pane = remotePane
        } else {
            pane = makeLocalTerminalPane()
        }
        installDirectSplitPane(
            pane,
            duplicating: sourcePane,
            in: workspace,
            tabItem: selectedItem
        )
    }

    private func installDirectSplitPane(
        _ pane: NSViewController,
        duplicating sourcePane: NSViewController,
        in workspace: TerminalSplitWorkspace,
        tabItem: NSTabViewItem
    ) {
        let sourceKey = ObjectIdentifier(sourcePane)
        let sourceRestoration: WorkspacePaneTabRestoration
        if let existing = paneTabRestorations[sourceKey] {
            sourceRestoration = existing
        } else {
            sourceRestoration = WorkspacePaneTabRestoration(
                label: workspace.baseLabel,
                metadata: tabMetadata[tabItem] ?? WorkspaceTabMetadata(),
                duplicateHandler: tabDuplicateHandlers[tabItem]
            )
            paneTabRestorations[sourceKey] = sourceRestoration
        }

        var duplicatedMetadata = sourceRestoration.metadata
        duplicatedMetadata.color = nil
        duplicatedMetadata.isPinned = false
        paneTabRestorations[ObjectIdentifier(pane)] = WorkspacePaneTabRestoration(
            label: title(for: pane),
            metadata: duplicatedMetadata,
            duplicateHandler: sourceRestoration.duplicateHandler
        )

        workspace.kind = .split
        workspace.addPane(pane)
        updateLabel(for: tabItem)
        currentTerminalPane = pane
        rememberCommandTerminalPane(pane)
        focusCurrentTerminalPane()
    }

    public func setCurrentTerminalSplitLayout(_ mode: TerminalSplitLayoutMode) {
        guard let workspace = currentSelectedWorkspace else { return }
        if mode != .single, workspace.panes.count == 1 {
            try? splitCurrentTerminal()
        }
        workspace.setLayoutMode(mode)
        currentTerminalPane = workspace.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
        focusCurrentTerminalPane()
    }

    public func closeCurrentTerminal() {
        syncCurrentTerminalPaneWithFirstResponder()
        guard let selectedItem = selectedTabViewItem,
              let workspace = tabWorkspaces[selectedItem],
              let currentTerminalPane,
              workspace.containsPane(currentTerminalPane)
        else { return }

        guard close(pane: currentTerminalPane) else {
            return
        }
        workspace.removePane(currentTerminalPane)

        if workspace.panes.isEmpty {
            tabWorkspaces.removeValue(forKey: selectedItem)
            tabMetadata.removeValue(forKey: selectedItem)
            tabDuplicateHandlers.removeValue(forKey: selectedItem)
            tabViewController.removeTabViewItem(selectedItem)
            self.currentTerminalPane = currentSelectedWorkspace?.selectedPane
            rememberCommandTerminalPane(self.currentTerminalPane)
            notifyCurrentRemoteTerminalChangedIfNeeded(self.currentTerminalPane)
            focusCurrentTerminalPane()
            updateEmptyState(animated: true)
            return
        }

        if workspace.baseLabel == L10n.MultiExec.title,
           let remainingPane = workspace.panes.first,
           workspace.panes.count == 1 {
            workspace.baseLabel = title(for: remainingPane)
        }
        updateLabel(for: selectedItem)
        self.currentTerminalPane = workspace.selectedPane
        rememberCommandTerminalPane(self.currentTerminalPane)
        notifyCurrentRemoteTerminalChangedIfNeeded(self.currentTerminalPane)
        focusCurrentTerminalPane()
    }

    @discardableResult
    public func findInCurrentTerminal(_ term: String) -> Bool {
        syncCurrentTerminalPaneWithFirstResponder()
        guard let terminal = currentTerminalPane as? TerminalCommandHandling else {
            return false
        }
        return terminal.find(term)
    }

    public func copyFromCurrentTerminal() {
        syncCurrentTerminalPaneWithFirstResponder()
        (currentTerminalPane as? TerminalCommandHandling)?.copySelection()
    }

    public func pasteIntoCurrentTerminal() {
        syncCurrentTerminalPaneWithFirstResponder()
        (currentTerminalPane as? TerminalCommandHandling)?.pasteClipboard()
    }

    public func showFindInCurrentTerminal() {
        syncCurrentTerminalPaneWithFirstResponder()
        (currentTerminalPane as? TerminalCommandHandling)?.showFind()
    }

    @discardableResult
    public func sendTextToCurrentTerminal(_ text: String) -> Bool {
        syncCurrentTerminalPaneWithFirstResponder()
        guard let terminal = (currentTerminalPane as? TerminalCommandHandling)
            ?? (lastCommandTerminalPane as? TerminalCommandHandling)
        else {
            return false
        }
        terminal.sendInput(Array(text.utf8))
        lastCommandTerminalPane = terminal as? NSViewController
        return true
    }

    public func currentTerminalMacroPlaybackTarget() -> TerminalMacroPlaybackTarget? {
        syncCurrentTerminalPaneWithFirstResponder()
        return (currentTerminalPane as? TerminalMacroPlaybackTarget)
            ?? (lastCommandTerminalPane as? TerminalMacroPlaybackTarget)
    }

    @discardableResult
    public func closeAllTerminals() -> Bool {
        for workspace in tabWorkspaces.values {
            for pane in workspace.panes {
                guard close(pane: pane) else {
                    return false
                }
            }
        }
        tabWorkspaces.removeAll()
        tabMetadata.removeAll()
        tabDuplicateHandlers.removeAll()
        paneTabRestorations.removeAll()
        lastCommandTerminalPane = nil
        for item in tabViewController.tabViewItems {
            tabViewController.removeTabViewItem(item)
        }
        currentTerminalPane = nil
        updateEmptyState(animated: true)
        return true
    }

    public func closeMultiExecSessionKeepingTerminals() {
        guard let session = multiExecSession,
              let multiExecItem = tabViewController.tabViewItems.first(where: { isMultiExecTab($0) }),
              let multiExecWorkspace = tabWorkspaces[multiExecItem]
        else { return }
        let panes = session.targetIDs.compactMap { runtimeID in
            terminalCommandPanes().first { self.runtimeID(for: $0) == runtimeID }
        }
        let reusablePanes = panes.filter { pane in
            (pane as? RemoteTerminalPaneViewController)?.lifecycleState != .closed
        }

        endMultiExecSession()
        for pane in reusablePanes {
            multiExecWorkspace.removePaneForTransfer(pane)
        }
        closeMultiExecTabWithoutClosingPanes(multiExecItem)

        for pane in reusablePanes {
            let item = restoreTerminalTab(for: pane)
            select(item, currentPane: pane)
        }
        updateEmptyState(animated: true)
    }

    public func multiExecTargets() -> [MultiExecTarget] {
        terminalCommandPanes().map { pane in
            let title = title(for: pane)
            return MultiExecTarget(
                id: runtimeID(for: pane),
                label: title,
                environment: environment(for: pane),
                enabled: true
            )
        }
    }

    @discardableResult
    public func broadcastInput(_ input: String, to targetIDs: [String]) -> Int {
        let selectedIDs = Set(targetIDs)
        let bytes = Array(input.utf8)
        var sent = 0
        for pane in terminalCommandPanes() where selectedIDs.contains(runtimeID(for: pane)) {
            if let remote = pane as? RemoteTerminalPaneViewController,
               remote.lifecycleState != .running {
                continue
            }
            guard let commandPane = pane as? TerminalCommandHandling else {
                continue
            }
            commandPane.sendInput(bytes)
            sent += 1
        }
        return sent
    }

    public func startMultiExecSession(targetIDs: [String]) throws {
        let selectedIDs = orderedUniqueIDs(targetIDs)
        let selectedSet = Set(selectedIDs)
        let selectedPanes = terminalCommandPanes()
            .filter { selectedSet.contains(runtimeID(for: $0)) }
            .sorted { lhs, rhs in
                selectedIDs.firstIndex(of: runtimeID(for: lhs)) ?? .max < selectedIDs.firstIndex(of: runtimeID(for: rhs)) ?? .max
            }
        guard selectedPanes.count >= 2 else {
            throw WorkspaceTerminalError.multiExecRequiresMultipleTargets
        }

        endMultiExecSession()
        removePanesFromWorkspaces(selectedPanes)

        let workspace = TerminalSplitWorkspace(
            baseLabel: L10n.MultiExec.title,
            firstPane: selectedPanes[0],
            titleProvider: { [weak self] pane in
                self?.title(for: pane) ?? pane.title ?? ""
            },
            identifierProvider: { [weak self] pane in
                self?.runtimeID(for: pane) ?? ""
            },
            isDeviceDashboardGloballyVisible: false,
            kind: .multiExec
        )
        for pane in selectedPanes.dropFirst() {
            workspace.addPane(pane)
        }
        workspace.setLayoutMode(.grid)
        let item = NSTabViewItem(viewController: workspace)
        item.label = L10n.MultiExec.title
        tabWorkspaces[item] = workspace
        tabMetadata[item] = WorkspaceTabMetadata()
        tabViewController.addTabViewItem(item)
        tabViewController.selectedTabViewItemIndex = tabViewController.tabViewItems.count - 1
        updateLabel(for: item)

        multiExecSession = MultiExecInteractiveSession(targetIDs: selectedPanes.map { runtimeID(for: $0) }, pausedIDs: [])
        for pane in selectedPanes { setMultiExecEnabled(pane, true) }
        currentTerminalPane = workspace.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
        updateEmptyState(animated: true)
        focusCurrentTerminalPane()
    }

    private func setMultiExecEnabled(_ pane: NSViewController, _ enabled: Bool) {
        if let remote = pane as? RemoteTerminalPaneViewController { remote.setMultiExecModeEnabled(enabled) }
    }

    public func currentSplitTargetIDs() -> [String] {
        guard let workspace = currentSelectedWorkspace, workspace.kind == .split else { return [] }
        return workspace.panes.map { runtimeID(for: $0) }
    }

    public func splitExistingTerminals(targetIDs: [String], layout: TerminalSplitLayoutMode) throws {
        let selectedIDs = orderedUniqueIDs(targetIDs)
        let selectedSet = Set(selectedIDs)
        let selectedPanes = terminalCommandPanes()
            .filter { selectedSet.contains(runtimeID(for: $0)) }
            .sorted { lhs, rhs in
                selectedIDs.firstIndex(of: runtimeID(for: lhs)) ?? .max < selectedIDs.firstIndex(of: runtimeID(for: rhs)) ?? .max
            }
        guard selectedPanes.count >= 2 else {
            throw WorkspaceTerminalError.multiExecRequiresMultipleTargets
        }
        removePanesFromWorkspaces(selectedPanes)
        let workspace = TerminalSplitWorkspace(
            baseLabel: "分屏",
            firstPane: selectedPanes[0],
            titleProvider: { [weak self] pane in self?.title(for: pane) ?? pane.title ?? "" },
            identifierProvider: { [weak self] pane in self?.runtimeID(for: pane) ?? "" },
            isDeviceDashboardGloballyVisible: false,
            kind: .split
        )
        for pane in selectedPanes.dropFirst() { workspace.addPane(pane) }
        workspace.setLayoutMode(layout)
        let item = NSTabViewItem(viewController: workspace)
        item.label = "分屏"
        tabWorkspaces[item] = workspace
        tabMetadata[item] = WorkspaceTabMetadata()
        tabViewController.addTabViewItem(item)
        tabViewController.selectedTabViewItemIndex = tabViewController.tabViewItems.count - 1
        updateLabel(for: item)
        currentTerminalPane = workspace.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
        updateEmptyState(animated: true)
        focusCurrentTerminalPane()
    }

    public func splitTargets() -> [MultiExecTarget] {
        terminalCommandPanes().map { pane in
            MultiExecTarget(id: runtimeID(for: pane), label: title(for: pane), environment: environment(for: pane), enabled: true)
        }
    }

    public func endMultiExecSession() {
        guard let session = multiExecSession else { return }
        multiExecSession = nil
        for id in session.targetIDs {
            remoteTerminalPane(for: id)?.setMultiExecModeEnabled(false)
        }
    }

    public func focusCurrentTerminalForKeyboardInput() {
        focusCurrentTerminalPane()
    }

    public func toggleDeviceMetricsDashboardVisibility() {
        isDeviceMetricsDashboardEnabled.toggle()
        updateDeviceMetricsDashboardVisibilityForAllWorkspaces()
    }

    public func selectTabForTesting(_ index: Int) {
        guard index >= 0, index < tabViewController.tabViewItems.count else {
            return
        }
        tabViewController.selectedTabViewItemIndex = index
        syncCurrentTerminalPaneWithSelectedTab()
    }

    public func tabContextMenuTitlesForTesting(index: Int) -> [String] {
        makeContextMenu(forTabAt: index)?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
    }

    public func performTabContextActionForTesting(_ action: WorkspaceTabContextAction, index: Int) throws {
        try performTabContextAction(action, index: index)
    }

    public func tabColorHexForTesting(index: Int) -> String? {
        guard let item = tabItem(at: index) else { return nil }
        return tabMetadata[item]?.color?.workspaceHexRGB
    }

    public var pinnedTabLabelsForTesting: [String] {
        tabViewController.tabViewItems
            .filter { tabMetadata[$0]?.isPinned == true }
            .map(\.label)
    }

    public var isMultiExecSessionActiveForTesting: Bool {
        multiExecSession != nil
    }

    public var currentSplitPaneRuntimeIDsForTesting: [String] {
        currentSelectedWorkspace?.panes.map { runtimeID(for: $0) } ?? []
    }

    public var currentSplitPaneMinimumThicknessesForTesting: [CGFloat] {
        currentSelectedWorkspace?.minimumThicknessesForTesting ?? []
    }

    public var currentTerminalSplitLayoutModeForTesting: TerminalSplitLayoutMode? {
        currentSelectedWorkspace?.layoutModeForTesting
    }

    public var currentGridSplitColumnCountForTesting: Int {
        currentSelectedWorkspace?.gridColumnCountForTesting ?? 0
    }

    public var currentGridSplitRowCountForTesting: Int {
        currentSelectedWorkspace?.gridRowCountForTesting ?? 0
    }

    public var currentDeviceMetricsDashboardTitleForTesting: String? {
        currentSelectedWorkspace?.trailingAccessoryTitle
    }

    public var isCurrentDeviceMetricsDashboardVisibleForTesting: Bool {
        currentSelectedWorkspace?.isDeviceDashboardVisibleForTesting ?? false
    }

    public var currentTerminalReservedTrailingWidthForTesting: CGFloat {
        currentSelectedWorkspace?.terminalReservedTrailingWidthForTesting ?? 0
    }

    public var currentDeviceMetricsDashboardFrameForTesting: NSRect? {
        currentSelectedWorkspace?.deviceDashboardFrameForTesting
    }

    public var currentDeviceMetricsDashboardContainerBoundsForTesting: NSRect? {
        currentSelectedWorkspace?.deviceDashboardContainerBoundsForTesting
    }

    public func refreshCurrentDeviceMetricsDashboardForTesting() {
        currentSelectedWorkspace?.refreshDeviceDashboardForTesting()
    }

    public func remoteTerminalPaneForTesting(runtimeID: String) -> RemoteTerminalPaneViewController? {
        remoteTerminalPane(for: runtimeID)
    }

    public func setMultiExecPausedForTesting(runtimeID: String, paused: Bool) {
        remoteTerminalPane(for: runtimeID)?.setMultiExecPaused(paused)
    }

    public func tabIconIdentifierForTesting(index: Int) -> String? {
        guard let item = tabItem(at: index) else { return nil }
        return resolvedTabIconDescriptor(for: item)?.identifier
    }

    public func tabImageAccessibilityDescriptionForTesting(index: Int) -> String? {
        guard let item = tabItem(at: index) else { return nil }
        return item.image?.accessibilityDescription
    }

    public func tabSegmentWidthForTesting(index: Int) -> CGFloat? {
        tabViewController.tabSegmentWidthForTesting(index: index)
    }

    public var currentAgentTerminalTarget: AgentTerminalTarget? {
        currentTerminalPaneForAgent()
    }

    public func agentTerminalTarget(runtimeID: String) -> AgentTerminalTarget? {
        terminalPaneForRuntimeID(runtimeID)
    }

    public func commandHistoryEntriesForCurrentTerminal() -> [TerminalCommandHistoryEntry] {
        syncCurrentTerminalPaneWithFirstResponder()
        return commandHistoryStore.entries(for: currentCommandHistoryRuntimeID())
    }

    public var commandHistoryEntriesForCurrentTerminalForTesting: [TerminalCommandHistoryEntry] {
        commandHistoryEntriesForCurrentTerminal()
    }

    public func refreshWorkspaceAppearanceForTesting() {
        refreshWorkspaceAppearance()
    }

    private var currentSelectedWorkspace: TerminalSplitWorkspace? {
        guard let item = selectedTabViewItem else { return nil }
        return tabWorkspaces[item]
    }

    private var selectedTabViewItem: NSTabViewItem? {
        let index = tabViewController.selectedTabViewItemIndex
        guard index >= 0, index < tabViewController.tabViewItems.count else {
            return nil
        }
        return tabViewController.tabViewItems[index]
    }

    private func tabItem(at index: Int) -> NSTabViewItem? {
        guard index >= 0, index < tabViewController.tabViewItems.count else {
            return nil
        }
        return tabViewController.tabViewItems[index]
    }

    private func tabItem(containing pane: NSViewController) -> NSTabViewItem? {
        tabWorkspaces.first { _, workspace in
            workspace.containsPane(pane)
        }?.key
    }

    private func refreshWorkspaceAppearance() {
        guard isViewLoaded else { return }
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        applyEffectiveAppearance(appearance, to: view)
        StacioDesignSystem.refreshDynamicLayerColors(in: view)
        tabViewController.stacioRefreshEffectiveAppearance()
        for workspace in tabWorkspaces.values {
            workspace.stacioRefreshEffectiveAppearance()
        }
    }

    private func applyEffectiveAppearance(_ appearance: NSAppearance, to root: NSView) {
        root.appearance = appearance
        for subview in root.subviews {
            applyEffectiveAppearance(appearance, to: subview)
        }
    }

    private func makeContextMenu(forTabAt index: Int) -> NSMenu? {
        guard let tabItem = tabItem(at: index) else { return nil }
        let menu = NSMenu(title: L10n.WorkspaceTabs.closeTab)
        for entry in WorkspaceTabMenuEntry.entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .action(let action, let title):
                let itemTitle = titleForTabContextAction(action, item: tabItem) ?? title
                let item = NSMenuItem(title: itemTitle, action: #selector(WorkspaceTabViewController.contextMenuItemSelected(_:)), keyEquivalent: "")
                item.target = tabViewController
                item.tag = action.rawValue
                item.representedObject = index
                menu.addItem(item)
            }
        }
        return menu
    }

    private func performTabContextAction(_ action: WorkspaceTabContextAction, index: Int) throws {
        guard let item = tabItem(at: index) else { return }

        do {
            switch action {
            case .rename:
                renameTab(item)
            case .setColor:
                setColorForTab(item)
            case .duplicate:
                try duplicateTab(item)
            case .closeTab:
                closeTab(item)
            case .closeTabsToLeft:
                closeTabs(leftOf: item)
            case .closeTabsToRight:
                closeTabs(rightOf: item)
            case .closeOtherTabs:
                closeOtherTabs(except: item)
            case .closeAllTabs:
                closeAllTabs()
            case .detach:
                try detachTab(item)
            case .toggleFullscreen:
                fullscreenToggler.toggleFullScreen(window: view.window)
            case .pin:
                pinTab(item)
            case .saveTerminalOutput:
                try saveTerminalOutput(for: item)
            case .printTerminalOutput:
                try printTerminalOutput(for: item)
            case .increaseFontSize:
                adjustTerminalFontSize(delta: 1)
            case .decreaseFontSize:
                adjustTerminalFontSize(delta: -1)
            }
        } catch {
            presentTabOperationError(error, action: action)
            throw error
        }
    }

    private func renameTab(_ item: NSTabViewItem) {
        guard let workspace = tabWorkspaces[item],
              let newTitle = tabOperationsPresenter.promptRenameTab(
                currentTitle: workspace.baseLabel,
                parentWindow: view.window
              )
        else { return }

        workspace.baseLabel = newTitle
        updateLabel(for: item)
    }

    private func setColorForTab(_ item: NSTabViewItem) {
        var metadata = tabMetadata[item] ?? WorkspaceTabMetadata()
        let currentColor = metadata.color ?? .controlAccentColor
        guard let color = tabOperationsPresenter.chooseTabColor(
            currentColor: currentColor,
            title: tabWorkspaces[item]?.baseLabel ?? item.label,
            parentWindow: view.window
        ) else { return }

        metadata.color = color
        tabMetadata[item] = metadata
        item.color = color
    }

    private func duplicateTab(_ item: NSTabViewItem) throws {
        guard let handler = tabDuplicateHandlers[item] else {
            throw WorkspaceTabActionError.unsupportedDuplicate
        }
        try handler(tabWorkspaces[item]?.baseLabel ?? item.label)
    }

    @discardableResult
    private func closeTab(_ item: NSTabViewItem) -> Bool {
        if isMultiExecTab(item) {
            closeMultiExecSessionKeepingTerminals()
            return true
        }
        if isSplitTab(item) {
            return closeSplitTabKeepingTerminals(item)
        }
        return closeTab(item, closePanes: true)
    }

    private func closeSplitTabKeepingTerminals(_ item: NSTabViewItem) -> Bool {
        guard let workspace = tabWorkspaces[item] else { return false }
        let panes = workspace.panes
        for pane in panes { workspace.removePaneForTransfer(pane) }
        tabWorkspaces.removeValue(forKey: item)
        tabMetadata.removeValue(forKey: item)
        tabDuplicateHandlers.removeValue(forKey: item)
        tabViewController.removeTabViewItem(item)
        for pane in panes {
            let newItem = restoreTerminalTab(for: pane)
            select(newItem, currentPane: pane)
        }
        updateEmptyState(animated: true)
        return true
    }

    private func closeTabs(leftOf item: NSTabViewItem) {
        guard let index = tabViewController.tabViewItems.firstIndex(of: item),
              index > 0
        else { return }
        closeTabs(tabViewController.tabViewItems[..<index].map { $0 })
    }

    private func closeTabs(rightOf item: NSTabViewItem) {
        guard let index = tabViewController.tabViewItems.firstIndex(of: item),
              index + 1 < tabViewController.tabViewItems.count
        else { return }
        closeTabs(tabViewController.tabViewItems[(index + 1)...].map { $0 })
    }

    private func closeOtherTabs(except item: NSTabViewItem) {
        closeTabs(tabViewController.tabViewItems.filter { $0 !== item })
    }

    private func closeAllTabs() {
        closeTabs(tabViewController.tabViewItems)
    }

    private func closeTabs(_ items: [NSTabViewItem]) {
        for item in items {
            let didClose: Bool
            if isMultiExecTab(item) || isSplitTab(item) {
                didClose = closeTab(item, closePanes: true)
            } else {
                didClose = closeTab(item)
            }
            guard didClose else {
                return
            }
        }
    }

    @discardableResult
    private func closeTab(_ item: NSTabViewItem, closePanes: Bool) -> Bool {
        if closePanes,
           let workspace = tabWorkspaces[item] {
            for pane in workspace.panes {
                guard close(pane: pane) else {
                    return false
                }
            }
        }
        tabWorkspaces.removeValue(forKey: item)
        tabMetadata.removeValue(forKey: item)
        tabDuplicateHandlers.removeValue(forKey: item)
        if tabViewController.tabViewItems.contains(item) {
            tabViewController.removeTabViewItem(item)
        }
        currentTerminalPane = currentSelectedWorkspace?.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
        updateEmptyState(animated: true)
        focusCurrentTerminalPane()
        return true
    }

    private func closeTab(containing pane: NSViewController) {
        guard let item = tabWorkspaces.first(where: { _, workspace in
            workspace.containsPane(pane)
        })?.key else { return }
        closeTab(item)
    }

    private func closeMultiExecTabWithoutClosingPanes(_ item: NSTabViewItem) {
        tabWorkspaces.removeValue(forKey: item)
        tabMetadata.removeValue(forKey: item)
        tabDuplicateHandlers.removeValue(forKey: item)
        tabViewController.removeTabViewItem(item)
        currentTerminalPane = currentSelectedWorkspace?.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
    }

    private func isMultiExecTab(_ item: NSTabViewItem) -> Bool {
        guard multiExecSession != nil,
              let workspace = tabWorkspaces[item],
              isMultiExecWorkspace(workspace)
        else { return false }
        return true
    }

    private func isMultiExecWorkspace(_ workspace: TerminalSplitWorkspace) -> Bool {
        workspace.kind == .multiExec
    }

    private func isSplitTab(_ item: NSTabViewItem) -> Bool {
        tabWorkspaces[item]?.kind == .split
    }

    private func detachTab(_ item: NSTabViewItem) throws {
        guard let workspace = tabWorkspaces[item],
              let index = tabViewController.tabViewItems.firstIndex(of: item)
        else {
            throw WorkspaceTabActionError.detachFailed
        }

        let title = workspace.baseLabel
        tabViewController.removeTabViewItem(item)
        do {
            let detachedWindow = try tabDetacher.detachTab(
                contentViewController: workspace,
                title: title,
                parentWindow: view.window
            )
            detachedTabWindows.append(detachedWindow)
            tabWorkspaces.removeValue(forKey: item)
            tabMetadata.removeValue(forKey: item)
            tabDuplicateHandlers.removeValue(forKey: item)
            currentTerminalPane = currentSelectedWorkspace?.selectedPane
            rememberCommandTerminalPane(currentTerminalPane)
            updateEmptyState(animated: true)
            focusCurrentTerminalPane()
        } catch {
            tabViewController.insertTabViewItem(item, at: min(index, tabViewController.tabViewItems.count))
            throw error
        }
    }

    private func pinTab(_ item: NSTabViewItem) {
        var metadata = tabMetadata[item] ?? WorkspaceTabMetadata()
        let shouldPin = !metadata.isPinned
        metadata.isPinned = shouldPin
        tabMetadata[item] = metadata

        guard shouldPin else { return }
        guard let index = tabViewController.tabViewItems.firstIndex(of: item),
              index > pinnedInsertionIndex(excluding: item)
        else { return }

        let selectedItem = selectedTabViewItem
        tabViewController.removeTabViewItem(item)
        tabViewController.insertTabViewItem(item, at: pinnedInsertionIndex(excluding: item))
        if let selectedItem,
           let selectedIndex = tabViewController.tabViewItems.firstIndex(of: selectedItem) {
            tabViewController.selectedTabViewItemIndex = selectedIndex
        }
    }

    private func pinnedInsertionIndex(excluding excludedItem: NSTabViewItem) -> Int {
        tabViewController.tabViewItems.filter {
            $0 !== excludedItem && tabMetadata[$0]?.isPinned == true
        }.count
    }

    private func titleForTabContextAction(_ action: WorkspaceTabContextAction, item: NSTabViewItem) -> String? {
        guard action == .pin else { return nil }
        return tabMetadata[item]?.isPinned == true ? L10n.WorkspaceTabs.unpin : L10n.WorkspaceTabs.pin
    }

    private func saveTerminalOutput(for item: NSTabViewItem) throws {
        let output = terminalOutput(for: item)
        guard !output.isEmpty else {
            throw WorkspaceTabActionError.noTerminalOutput
        }
        let suggestedName = safeOutputFileName(for: item)
        guard let destinationURL = tabOperationsPresenter.chooseTerminalOutputDestination(
            suggestedName: suggestedName,
            parentWindow: view.window
        ) else { return }
        try output.write(to: destinationURL, atomically: true, encoding: .utf8)
        tabOperationsPresenter.presentTerminalOutputSaved(destinationURL: destinationURL, parentWindow: view.window)
    }

    private func saveTerminalOutput(containing pane: NSViewController) {
        guard let item = tabWorkspaces.first(where: { _, workspace in
            workspace.containsPane(pane)
        })?.key else { return }
        do {
            try saveTerminalOutput(for: item)
        } catch {
            presentTabOperationError(error, action: .saveTerminalOutput)
        }
    }

    private func printTerminalOutput(for item: NSTabViewItem) throws {
        let output = terminalOutput(for: item)
        guard !output.isEmpty else {
            throw WorkspaceTabActionError.noTerminalOutput
        }
        try terminalOutputPrinter.printTerminalOutput(
            output,
            title: tabWorkspaces[item]?.baseLabel ?? item.label,
            parentWindow: view.window
        )
    }

    private func terminalOutput(for item: NSTabViewItem) -> String {
        guard let workspace = tabWorkspaces[item] else { return "" }
        return workspace.panes
            .compactMap { ($0 as? TerminalOutputTranscriptProviding)?.terminalOutputTranscript }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func adjustTerminalFontSize(delta: Double) {
        settingsStore.update { settings in
            settings.terminalFontSize += delta
        }
    }

    private func openLocalShellFromTabStrip() {
        do {
            try openLocalShell()
        } catch {
            tabOperationsPresenter.presentError(
                title: L10n.WorkspaceTabs.openLocalTerminalFailedTitle,
                message: RuntimeDiagnosticFormatter.userMessage(for: error),
                parentWindow: view.window
            )
        }
    }

    private func openLocalShellForDuplicate(title: String) throws {
        let terminalPane = makeLocalTerminalPane()
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.Workspace.local : title
        let item = makeTerminalTab(label: label, firstPane: terminalPane)
        tabDuplicateHandlers[item] = { [weak self] duplicateTitle in
            try self?.openLocalShellForDuplicate(title: duplicateTitle)
        }
        select(item, currentPane: terminalPane)
    }

    private func updateLabel(for item: NSTabViewItem) {
        guard let workspace = tabWorkspaces[item] else { return }
        item.label = workspace.panes.count == 1
            ? workspace.baseLabel
            : "\(workspace.baseLabel) x\(workspace.panes.count)"
    }

    private func updateDeviceMetricsDashboardVisibilityForAllWorkspaces() {
        for workspace in tabWorkspaces.values {
            workspace.setDeviceDashboardGloballyVisible(isDeviceMetricsDashboardEnabled)
        }
    }

    private func safeOutputFileName(for item: NSTabViewItem) -> String {
        let rawTitle = tabWorkspaces[item]?.baseLabel ?? item.label
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = rawTitle
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? L10n.WorkspaceTabs.saveOutputSuggestedName : cleaned
        return base.hasSuffix(".txt") ? base : "\(base).txt"
    }

    private func presentTabOperationError(_ error: Error, action: WorkspaceTabContextAction) {
        let title: String
        switch action {
        case .saveTerminalOutput:
            title = L10n.WorkspaceTabs.outputSaveFailedTitle
        case .printTerminalOutput:
            title = L10n.WorkspaceTabs.outputPrintFailedTitle
        default:
            title = L10n.WorkspaceTabs.operationFailedTitle
        }
        tabOperationsPresenter.presentError(
            title: title,
            message: RuntimeDiagnosticFormatter.userMessage(for: error),
            parentWindow: view.window
        )
    }

    private func makeLocalTerminalPane() -> TerminalPaneViewController {
        let shellPath = shellPathProvider()
        let runtime = CoreBridge.openLocalShellRuntime(shellPath: shellPath, cols: 80, rows: 24)
        let pane = TerminalPaneViewController(
            runtimeID: runtime.id,
            shellPath: shellPath,
            eventSink: eventSinkFactory(),
            settingsStore: settingsStore,
            processLauncher: localTerminalProcessLauncherFactory(),
            autoStartProcess: autoStartTerminalProcesses
        )
        configureAIContextMenu(for: pane)
        configureMultiExecInputHook(for: pane)
        configureCommandHistory(for: pane)
        pane.title = L10n.Workspace.local
        return pane
    }

    private func makeDeviceMetricsDashboard(
        runtimeID: String,
        title: String,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> DeviceMetricsDashboardViewController? {
        guard connectionKind == .ssh,
              let liveSessionContext
        else { return nil }

        return DeviceMetricsDashboardViewController(
            runtimeID: runtimeID,
            title: title,
            provider: deviceMetricsProviderFactory(liveSessionContext),
            startsPollingAutomatically: startsDeviceMetricsPollingAutomatically,
            settingsStore: settingsStore,
            alertCoordinator: DeviceMetricsAlertCoordinator(
                settingsProvider: { [weak self] in
                    self?.settingsStore.snapshot() ?? AppSettings()
                },
                notifier: deviceMetricsAlertNotifier
            )
        )
    }

    private func makeTerminalTab(
        label: String,
        firstPane: NSViewController,
        deviceDashboard: NSViewController? = nil
    ) -> NSTabViewItem {
        let workspace = TerminalSplitWorkspace(
            baseLabel: label,
            firstPane: firstPane,
            deviceDashboard: deviceDashboard,
            titleProvider: { [weak self] pane in
                self?.title(for: pane) ?? pane.title ?? ""
            },
            identifierProvider: { [weak self] pane in
                self?.runtimeID(for: pane) ?? ""
            },
            isDeviceDashboardGloballyVisible: isDeviceMetricsDashboardEnabled
        )
        let item = NSTabViewItem(viewController: workspace)
        item.label = label
        tabWorkspaces[item] = workspace
        tabMetadata[item] = WorkspaceTabMetadata()
        tabViewController.addTabViewItem(item)
        return item
    }

    private func select(_ item: NSTabViewItem, currentPane: NSViewController) {
        tabViewController.selectedTabViewItemIndex = tabViewController.tabViewItems.firstIndex(of: item)
            ?? max(0, tabViewController.tabViewItems.count - 1)
        tabWorkspaces[item]?.selectPane(currentPane)
        currentTerminalPane = currentPane
        rememberCommandTerminalPane(currentPane)
        notifyCurrentRemoteTerminalChangedIfNeeded(currentPane)
        updateEmptyState(animated: true)
        if currentPane.isViewLoaded {
            StacioDesignSystem.fadeIn(currentPane.view)
        }
        focusCurrentTerminalPane()
    }

    private func syncCurrentTerminalPaneWithSelectedTab() {
        currentTerminalPane = currentSelectedWorkspace?.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
        notifyCurrentRemoteTerminalChangedIfNeeded(currentTerminalPane)
        DispatchQueue.main.async { [weak self] in
            self?.focusCurrentTerminalPaneOnce()
        }
    }

    @discardableResult
    public func activateTerminal(runtimeID: String, bringAppToFront: Bool = true) -> Bool {
        let runtimeID = resolvedRuntimeID(runtimeID)
        guard let match = tabWorkspaces.first(where: { _, workspace in
            workspace.panes.contains { pane in
                pane is TerminalCommandHandling && self.runtimeID(for: pane) == runtimeID
            }
        }),
              let pane = match.value.panes.first(where: { pane in
                  pane is TerminalCommandHandling && self.runtimeID(for: pane) == runtimeID
              }),
              let selectedIndex = tabViewController.tabViewItems.firstIndex(of: match.key)
        else {
            return false
        }

        tabViewController.selectedTabViewItemIndex = selectedIndex
        match.value.selectPane(pane)
        currentTerminalPane = pane
        rememberCommandTerminalPane(pane)
        notifyCurrentRemoteTerminalChangedIfNeeded(pane)
        updateEmptyState(animated: true)
        if bringAppToFront {
            view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        focusCurrentTerminalPane()
        return true
    }

    private func recordRuntimeReattachment(oldRuntimeID: String, newRuntimeID: String) {
        guard oldRuntimeID != newRuntimeID else { return }
        let aliases = runtimeIDReattachments.compactMap { alias, targetRuntimeID in
            targetRuntimeID == oldRuntimeID ? alias : nil
        }
        runtimeIDReattachments[newRuntimeID] = nil
        for alias in aliases {
            runtimeIDReattachments[alias] = newRuntimeID
        }
        runtimeIDReattachments[oldRuntimeID] = newRuntimeID
    }

    private func resolvedRuntimeID(_ runtimeID: String) -> String {
        var resolved = runtimeID
        var visited = Set<String>()
        while visited.insert(resolved).inserted,
              let next = runtimeIDReattachments[resolved],
              next.isEmpty == false {
            resolved = next
        }
        return resolved
    }

    private func isForegroundActiveTerminal(runtimeID: String) -> Bool {
        guard NSApp.isActive,
              let window = view.window,
              window.isKeyWindow || window.isMainWindow,
              let currentTerminalPane,
              currentTerminalPane is TerminalCommandHandling
        else {
            return false
        }
        return self.runtimeID(for: currentTerminalPane) == runtimeID
    }

    private func notifyCurrentRemoteTerminalChangedIfNeeded(_ pane: NSViewController?) {
        onCurrentTerminalChanged?()
        terminalSelectionNotificationGeneration &+= 1
        let generation = terminalSelectionNotificationGeneration
        let remoteChanged = onCurrentRemoteTerminalChanged
        if pane is RemoteFilesPaneViewController {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.terminalSelectionNotificationGeneration == generation
            else { return }
            let selectedRemote = (pane as? RemoteTerminalPaneViewController).flatMap { remote in
                remote.lifecycleState == .running ? remote : nil
            }
            remoteChanged?(selectedRemote)
        }
    }

    private func syncCurrentTerminalPaneWithFirstResponder() {
        guard let workspace = currentSelectedWorkspace,
              let firstResponder = workspace.view.window?.firstResponder as? NSView,
              let pane = workspace.pane(containing: firstResponder)
        else {
            return
        }

        workspace.selectPane(pane)
        currentTerminalPane = pane
        rememberCommandTerminalPane(pane)
    }

    private func rememberCommandTerminalPane(_ pane: NSViewController?) {
        guard pane is TerminalCommandHandling else {
            return
        }
        lastCommandTerminalPane = pane
    }

    private func focusCurrentTerminalPane(attempt: Int = 0) {
        guard let pane = currentTerminalPane,
              let terminal = pane as? TerminalCommandHandling
        else { return }
        _ = currentSelectedWorkspace?.view
        _ = pane.view
        let focusView = terminal.keyboardFocusView
        if attempt > 0,
           let window = focusView.window,
           shouldPreserveExternalFirstResponder(in: window, focusView: focusView)
        {
            return
        }
        if focusView.acceptsFirstResponder,
           let window = focusView.window,
           window.firstResponder !== focusView {
            let accepted = window.makeFirstResponder(focusView)
            if !accepted, attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.focusCurrentTerminalPane(attempt: attempt + 1)
                }
            }
        } else if attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.focusCurrentTerminalPane(attempt: attempt + 1)
            }
        }
        DispatchQueue.main.async { [weak self, weak focusView] in
            guard let self,
                  self.currentTerminalPane as? TerminalCommandHandling === terminal,
                  let focusView
            else { return }

            guard focusView.acceptsFirstResponder else {
                if attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                        self?.focusCurrentTerminalPane(attempt: attempt + 1)
                    }
                }
                return
            }
            guard let window = focusView.window else {
                if attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                        self?.focusCurrentTerminalPane(attempt: attempt + 1)
                    }
                }
                return
            }

            if window.firstResponder === focusView {
                return
            }
            guard self.shouldPreserveExternalFirstResponder(in: window, focusView: focusView) == false else {
                return
            }
            window.makeFirstResponder(focusView)
            if window.firstResponder !== focusView, attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.focusCurrentTerminalPane(attempt: attempt + 1)
                }
            }
        }
    }

    private func shouldPreserveExternalFirstResponder(in window: NSWindow, focusView: NSView) -> Bool {
        guard let firstResponder = window.firstResponder as? NSView,
              firstResponder !== focusView,
              firstResponder !== window.contentView
        else {
            return false
        }
        if let workspaceView = currentSelectedWorkspace?.view,
           firstResponder === workspaceView || firstResponder.isDescendant(of: workspaceView)
        {
            return false
        }
        return firstResponder.acceptsFirstResponder
    }

    private func focusCurrentTerminalPaneOnce() {
        guard let pane = currentTerminalPane,
              let terminal = pane as? TerminalCommandHandling,
              let window = terminal.keyboardFocusView.window,
              terminal.keyboardFocusView.acceptsFirstResponder,
              window.firstResponder !== terminal.keyboardFocusView
        else { return }
        window.makeFirstResponder(terminal.keyboardFocusView)
    }

    @discardableResult
    private func close(pane: NSViewController) -> Bool {
        if let remote = pane as? RemoteTerminalPaneViewController,
           onRemoteTerminalClosed?(remote) == false {
            return false
        }
        let paneRuntimeID = runtimeID(for: pane)
        if multiExecSession?.targetIDs.contains(paneRuntimeID) == true {
            setMultiExecEnabled(pane, false)
            multiExecSession?.targetIDs.removeAll { $0 == paneRuntimeID }
            multiExecSession?.pausedIDs.remove(paneRuntimeID)
            if (multiExecSession?.targetIDs.count ?? 0) == 1,
               let remainingID = multiExecSession?.targetIDs.first,
               let remainingPane = terminalCommandPanes().first(where: { runtimeID(for: $0) == remainingID }) {
                setMultiExecEnabled(remainingPane, false)
            }
            if (multiExecSession?.targetIDs.count ?? 0) < 2 {
                endMultiExecSession()
            }
        }
        (pane as? TerminalCommandHandling)?.closeTerminal()
        (pane as? GraphicsSessionPaneViewController)?.closeGraphicsRuntime()
        (pane as? RemoteFilesPaneViewController)?.closeRemoteFilesRuntime()
        (pane as? BrowserPaneViewController)?.closeBrowserPane()
        paneTabRestorations.removeValue(forKey: ObjectIdentifier(pane))
        let runtimeAliasesToRemove = runtimeIDReattachments.compactMap { alias, targetRuntimeID in
            alias == paneRuntimeID || targetRuntimeID == paneRuntimeID ? alias : nil
        }
        for alias in runtimeAliasesToRemove {
            runtimeIDReattachments[alias] = nil
        }
        return true
    }

    private func updateEmptyState(animated: Bool) {
        let shouldShow = tabViewController.tabViewItems.isEmpty && !suppressEmptyPrompt
        emptyPromptPanel.isHidden = false
        emptyStateContentViews.forEach { $0.isHidden = !shouldShow }

        guard animated else {
            emptyPromptPanel.alphaValue = shouldShow ? 1 : 0
            emptyPromptPanel.isHidden = !shouldShow
            return
        }

        guard shouldShow else {
            emptyPromptPanel.isHidden = true
            emptyStateContentViews.forEach { $0.isHidden = true }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StacioDesignSystem.theme.fastAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                emptyPromptPanel.animator().alphaValue = 0
            } completionHandler: {
                self.emptyPromptPanel.isHidden = true
                self.emptyStateContentViews.forEach { $0.isHidden = true }
            }
            return
        }

        emptyPromptPanel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StacioDesignSystem.theme.standardAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            emptyPromptPanel.animator().alphaValue = 1
        } completionHandler: {
            self.emptyPromptPanel.isHidden = false
            self.emptyStateContentViews.forEach { $0.isHidden = false }
        }
    }

    private func configureEmptyPromptPanel() {
        emptyPromptPanel.translatesAutoresizingMaskIntoConstraints = false
        emptyPromptPanel.setAccessibilityIdentifier("Stacio.Workspace.emptyState")
        StacioDesignSystem.applyWorkspaceSurface(emptyPromptPanel)
        emptyPromptPanel.alphaValue = 1
        emptyPromptPanel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyPromptPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        emptyIconView.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: L10n.Workspace.start)
        emptyIconView.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        emptyIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        emptyIconView.setAccessibilityIdentifier("Stacio.Workspace.emptyIcon")
        emptyIconView.translatesAutoresizingMaskIntoConstraints = false

        emptyPromptLabel.stringValue = L10n.Workspace.start
        emptyPromptLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        emptyPromptLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        emptyPromptLabel.alignment = .center
        emptyPromptLabel.setAccessibilityIdentifier("Stacio.Workspace.emptyPrompt")
        emptyPromptLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyPromptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyPromptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        emptyPromptSubtitleLabel.stringValue = L10n.Workspace.startSubtitle
        emptyPromptSubtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyPromptSubtitleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyPromptSubtitleLabel.alignment = .center
        emptyPromptSubtitleLabel.maximumNumberOfLines = 2
        emptyPromptSubtitleLabel.setAccessibilityIdentifier("Stacio.Workspace.emptySubtitle")
        emptyPromptSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyPromptSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyPromptSubtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        emptyPromptPanel.addSubview(emptyIconView)
        emptyPromptPanel.addSubview(emptyPromptLabel)
        emptyPromptPanel.addSubview(emptyPromptSubtitleLabel)
        configureEmptyQuickStartStack()
        emptyPromptPanel.addSubview(emptyQuickStartStack)
        emptyStateContentViews = [
            emptyIconView,
            emptyPromptLabel,
            emptyPromptSubtitleLabel,
            emptyQuickStartStack
        ]

        NSLayoutConstraint.activate([
            emptyIconView.centerXAnchor.constraint(equalTo: emptyPromptPanel.centerXAnchor),
            emptyIconView.centerYAnchor.constraint(equalTo: emptyPromptPanel.centerYAnchor, constant: -42),
            emptyIconView.widthAnchor.constraint(equalToConstant: 52),
            emptyIconView.heightAnchor.constraint(equalToConstant: 52),

            emptyPromptLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyPromptPanel.leadingAnchor, constant: 44),
            emptyPromptLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyPromptPanel.trailingAnchor, constant: -44),
            emptyPromptLabel.centerXAnchor.constraint(equalTo: emptyPromptPanel.centerXAnchor),
            emptyPromptLabel.topAnchor.constraint(equalTo: emptyIconView.bottomAnchor, constant: 14),

            emptyPromptSubtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyPromptPanel.leadingAnchor, constant: 44),
            emptyPromptSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyPromptPanel.trailingAnchor, constant: -44),
            emptyPromptSubtitleLabel.centerXAnchor.constraint(equalTo: emptyPromptPanel.centerXAnchor),
            emptyPromptSubtitleLabel.topAnchor.constraint(equalTo: emptyPromptLabel.bottomAnchor, constant: 8),

            emptyQuickStartStack.centerXAnchor.constraint(equalTo: emptyPromptPanel.centerXAnchor),
            emptyQuickStartStack.topAnchor.constraint(equalTo: emptyPromptSubtitleLabel.bottomAnchor, constant: 18)
        ])
    }

    private func configureEmptyQuickStartStack() {
        emptyQuickStartStack.setAccessibilityIdentifier("Stacio.Workspace.emptyQuickStart")
        emptyQuickStartStack.orientation = .horizontal
        emptyQuickStartStack.alignment = .centerY
        emptyQuickStartStack.spacing = 10
        emptyQuickStartStack.translatesAutoresizingMaskIntoConstraints = false
        emptyQuickStartStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyQuickStartStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        emptyLocalTerminalButton.target = self
        emptyLocalTerminalButton.action = #selector(emptyLocalTerminalButtonPressed(_:))
        emptyNewSessionButton.target = self
        emptyNewSessionButton.action = #selector(emptyNewSessionButtonPressed(_:))
        emptyQuickStartStack.addArrangedSubview(emptyLocalTerminalButton)
        emptyQuickStartStack.addArrangedSubview(emptyNewSessionButton)
    }

    @objc private func emptyLocalTerminalButtonPressed(_ sender: Any?) {
        openLocalShellFromTabStrip()
    }

    @objc private func emptyNewSessionButtonPressed(_ sender: Any?) {
        onRequestNewSession?()
    }

    private static func makeEmptyActionButton(title: String, symbolName: String, identifier: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        let button = NSButton(title: title, image: image ?? NSImage(size: NSSize(width: 16, height: 16)), target: nil, action: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(button)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let minimumWidth = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 144)
        minimumWidth.priority = .dragThatCannotResizeWindow
        let height = button.heightAnchor.constraint(equalToConstant: 34)
        height.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([minimumWidth, height])
        return button
    }

    private func terminalPanes() -> [NSViewController] {
        tabViewController.tabViewItems.flatMap { item in
            tabWorkspaces[item]?.panes ?? []
        }
    }

    private func terminalCommandPanes() -> [NSViewController] {
        terminalPanes().filter { $0 is TerminalCommandHandling }
    }

    private func remoteTerminalPanes() -> [RemoteTerminalPaneViewController] {
        terminalPanes().compactMap { $0 as? RemoteTerminalPaneViewController }
    }

    private func eligibleMultiExecPanes() -> [RemoteTerminalPaneViewController] {
        remoteTerminalPanes().filter { pane in
            pane.lifecycleState == .running && (pane.connectionKind == .ssh || pane.connectionKind == .serial)
        }
    }

    private func remoteTerminalPane(for runtimeID: String) -> RemoteTerminalPaneViewController? {
        remoteTerminalPanes().first { $0.runtimeID == runtimeID }
    }

    private func currentTerminalPaneForAgent() -> AgentTerminalTarget? {
        if let currentTerminalPane = currentTerminalPane as? AgentTerminalTarget {
            return currentTerminalPane
        }
        if let lastCommandTerminalPane = lastCommandTerminalPane as? AgentTerminalTarget {
            return lastCommandTerminalPane
        }
        return terminalCommandPanes().compactMap { $0 as? AgentTerminalTarget }.first
    }

    private func terminalPaneForRuntimeID(_ runtimeID: String) -> AgentTerminalTarget? {
        terminalCommandPanes()
            .first { self.runtimeID(for: $0) == runtimeID } as? AgentTerminalTarget
    }

    private func currentCommandHistoryRuntimeID() -> String? {
        if let currentTerminalPane,
           currentTerminalPane is TerminalCommandHandling
        {
            return runtimeID(for: currentTerminalPane)
        }
        if let lastCommandTerminalPane {
            return runtimeID(for: lastCommandTerminalPane)
        }
        return nil
    }

    private func orderedUniqueIDs(_ targetIDs: [String]) -> [String] {
        var seen = Set<String>()
        return targetIDs.filter { seen.insert($0).inserted }
    }

    private func configureMultiExecInputHook(for pane: RemoteTerminalPaneViewController) {
        pane.onUserInput = { [weak self] source, bytes in
            self?.handleMultiExecUserInput(from: source, bytes: bytes) ?? false
        }
        pane.onMultiExecPauseChanged = { [weak self] source, paused in
            self?.setMultiExecPaused(source, paused: paused)
        }
    }

    private func configureAIContextMenu(for pane: TerminalPaneViewController) {
        pane.onAIContextRequest = { [weak self] request in
            self?.onAIContextRequest?(request)
        }
    }

    private func configureAIContextMenu(for pane: RemoteTerminalPaneViewController) {
        pane.onAIContextRequest = { [weak self] request in
            self?.onAIContextRequest?(request)
        }
    }

    private func configureCommandHistory(for pane: TerminalPaneViewController) {
        pane.onCommandSubmitted = { [weak self] pane, command in
            self?.recordCommandHistory(runtimeID: pane.runtimeID, command: command)
            self?.commandCompletionNotificationCoordinator.commandDidStart(
                runtimeID: pane.runtimeID,
                sessionTitle: self?.title(for: pane) ?? L10n.Workspace.local,
                command: command
            )
            self?.terminalMacroRecorder?.recordSubmittedCommand(command)
        }
        pane.onCommandFinished = { [weak self] pane in
            self?.commandCompletionNotificationCoordinator.commandDidFinish(
                runtimeID: pane.runtimeID,
                sessionTitle: self?.title(for: pane) ?? L10n.Workspace.local
            )
        }
    }

    private func configureCommandHistory(for pane: RemoteTerminalPaneViewController) {
        pane.onCommandSubmitted = { [weak self] pane, command in
            self?.recordCommandHistory(runtimeID: pane.runtimeID, command: command)
            self?.commandCompletionNotificationCoordinator.commandDidStart(
                runtimeID: pane.runtimeID,
                sessionTitle: self?.title(for: pane) ?? pane.terminalTitle,
                command: command
            )
            self?.terminalMacroRecorder?.recordSubmittedCommand(command)
        }
        pane.onCommandFinished = { [weak self] pane in
            self?.commandCompletionNotificationCoordinator.commandDidFinish(
                runtimeID: pane.runtimeID,
                sessionTitle: self?.title(for: pane) ?? pane.terminalTitle
            )
        }
    }

    private func configureMultiExecInputHook(for pane: TerminalPaneViewController) {
        pane.onUserInput = { [weak self] _, bytes in
            guard let self, let session = self.multiExecSession,
                  session.targetIDs.contains(pane.runtimeID) else { return false }
            pane.sendInput(bytes)
            for id in session.targetIDs where id != pane.runtimeID {
                self.terminalPaneForRuntimeID(id)?.sendInput(bytes)
            }
            return true
        }
    }

    private func configureRemoteTerminalPane(_ pane: RemoteTerminalPaneViewController) {
        configureMultiExecInputHook(for: pane)
        configureAIContextMenu(for: pane)
        configureCommandHistory(for: pane)
        pane.onRequestClose = { [weak self] pane in
            self?.closePaneFromPaneHeader(pane)
        }
        pane.onRequestSaveOutput = { [weak self] pane in
            self?.saveTerminalOutput(containing: pane)
        }
        pane.onRemoteDirectoryChanged = { [weak self] pane, directory in
            self?.handleRemoteTerminalDirectoryChanged(pane, directory: directory)
        }
        pane.onUploadDroppedFiles = { [weak self] remoteDirectory, localPaths in
            self?.onRemoteTerminalUploadDroppedFiles?(pane, remoteDirectory, localPaths)
        }
        pane.onRuntimeAttached = { [weak self] pane, status, liveSessionContext in
            self?.installDeviceDashboardIfNeeded(
                for: pane,
                status: status,
                liveSessionContext: liveSessionContext
            )
            self?.detectRemoteOSIconIfNeeded(
                for: pane,
                status: status,
                liveSessionContext: liveSessionContext
            )
            if self?.currentTerminalPane === pane {
                self?.onCurrentRemoteTerminalAttached?(pane)
            }
        }
        pane.onRuntimeReattached = { [weak self] pane, oldRuntimeID, status, liveSessionContext in
            self?.recordRuntimeReattachment(
                oldRuntimeID: oldRuntimeID,
                newRuntimeID: status.runtimeId
            )
            self?.updateMultiExecSessionRuntimeID(
                oldRuntimeID: oldRuntimeID,
                newRuntimeID: status.runtimeId
            )
            self?.commandHistoryStore.replaceRuntimeID(
                oldRuntimeID: oldRuntimeID,
                newRuntimeID: status.runtimeId
            )
            self?.onCommandHistoryChanged?()
            self?.onRemoteTerminalRuntimeReattached?(
                pane,
                oldRuntimeID,
                status,
                liveSessionContext
            )
        }
    }

    private func closePaneFromPaneHeader(_ pane: NSViewController) {
        guard let item = tabWorkspaces.first(where: { $0.value.containsPane(pane) })?.key,
              let workspace = tabWorkspaces[item],
              close(pane: pane)
        else { return }
        workspace.removePane(pane)
        if workspace.panes.isEmpty {
            tabWorkspaces.removeValue(forKey: item)
            tabMetadata.removeValue(forKey: item)
            tabDuplicateHandlers.removeValue(forKey: item)
            tabViewController.removeTabViewItem(item)
        } else {
            updateLabel(for: item)
        }
        currentTerminalPane = currentSelectedWorkspace?.selectedPane
        rememberCommandTerminalPane(currentTerminalPane)
        notifyCurrentRemoteTerminalChangedIfNeeded(currentTerminalPane)
        updateEmptyState(animated: true)
        focusCurrentTerminalPane()
    }

    private func recordCommandHistory(runtimeID: String, command: String) {
        guard commandHistoryStore.record(runtimeID: runtimeID, command: command) != nil else {
            return
        }
        onCommandHistoryChanged?()
    }

    private func observeSettingsChanges() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAllTabIcons()
        }
    }

    private func configureRemoteTabIcon(
        for item: NSTabViewItem,
        connectionKind: RemoteTerminalConnectionKind,
        manualIconID: String? = nil
    ) {
        guard connectionKind == .ssh else { return }
        var metadata = tabMetadata[item] ?? WorkspaceTabMetadata()
        metadata.defaultIcon = .sshDefault
        metadata.manualIcon = manualIconID.flatMap { SessionTabIconDescriptor.catalogIcon(id: $0) }
        metadata.connectionKind = connectionKind
        tabMetadata[item] = metadata
        applyTabIcon(for: item)
    }

    private func configureGraphicsTabIcon(for item: NSTabViewItem, protocolName: String) {
        var metadata = tabMetadata[item] ?? WorkspaceTabMetadata()
        metadata.defaultIcon = .graphicsProtocol(protocolName)
        tabMetadata[item] = metadata
        applyTabIcon(for: item)
    }

    private func detectRemoteOSIconIfNeeded(
        for pane: RemoteTerminalPaneViewController,
        status: LiveShellStatus,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        guard pane.connectionKind == .ssh,
              let liveSessionContext,
              let item = tabItem(containing: pane),
              tabMetadata[item]?.detectedOperatingSystemIcon == nil
        else { return }

        let runtimeID = status.runtimeId
        DispatchQueue.global(qos: .utility).async { [remoteOSProbe] in
            guard let info = try? remoteOSProbe(liveSessionContext) else { return }
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self,
                      let pane,
                      pane.runtimeID == runtimeID,
                      let item = self.tabItem(containing: pane)
                else { return }

                let fallbackDescriptor = SessionTabIconDescriptor.operatingSystem(info)
                let descriptor = SessionIconCatalog.iconID(for: info).flatMap {
                    SessionTabIconDescriptor.catalogIcon(
                        id: $0,
                        accessibilityLabel: fallbackDescriptor.accessibilityLabel
                    )
                } ?? fallbackDescriptor
                var metadata = self.tabMetadata[item] ?? WorkspaceTabMetadata()
                metadata.defaultIcon = metadata.defaultIcon ?? .sshDefault
                metadata.connectionKind = metadata.connectionKind ?? pane.connectionKind
                metadata.detectedOperatingSystemIcon = descriptor
                self.tabMetadata[item] = metadata
                self.applyTabIcon(for: item)
            }
        }
    }

    private func refreshAllTabIcons() {
        for item in tabViewController.tabViewItems {
            applyTabIcon(for: item)
        }
    }

    private func applyTabIcon(for item: NSTabViewItem) {
        guard let descriptor = resolvedTabIconDescriptor(for: item) else {
            item.image = nil
            item.toolTip = nil
            return
        }
        item.image = descriptor.image()
        item.toolTip = descriptor.accessibilityLabel
        tabViewController.invalidateTabSegmentWidths()
    }

    private func resolvedTabIconDescriptor(for item: NSTabViewItem) -> SessionTabIconDescriptor? {
        guard let metadata = tabMetadata[item] else { return nil }
        if let manualIcon = metadata.manualIcon {
            return manualIcon
        }
        switch settingsStore.snapshot().sessionTabIconMode {
        case .defaultIcon:
            return metadata.defaultIcon
        case .operatingSystem:
            return metadata.detectedOperatingSystemIcon ?? metadata.defaultIcon
        }
    }

    public func setManualSessionIcon(_ iconID: String?, runtimeID: String) {
        guard let pane = terminalPaneForRuntimeID(runtimeID) as? NSViewController,
              let item = tabItem(containing: pane)
        else { return }
        var metadata = tabMetadata[item] ?? WorkspaceTabMetadata()
        metadata.manualIcon = iconID.flatMap { SessionTabIconDescriptor.catalogIcon(id: $0) }
        tabMetadata[item] = metadata
        applyTabIcon(for: item)
    }

    private func handleRemoteTerminalDirectoryChanged(
        _ pane: RemoteTerminalPaneViewController,
        directory: String
    ) {
        onRemoteTerminalDirectoryChanged?(pane, directory)
    }

    private func installDeviceDashboardIfNeeded(
        for pane: RemoteTerminalPaneViewController,
        status: LiveShellStatus,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        guard let dashboard = makeDeviceMetricsDashboard(
            runtimeID: status.runtimeId,
            title: pane.terminalTitle,
            connectionKind: pane.connectionKind,
            liveSessionContext: liveSessionContext
        ),
              let workspace = tabWorkspaces.first(where: { _, workspace in
                  workspace.containsPane(pane)
              })?.value
        else { return }

        workspace.installDeviceDashboardIfAbsent(dashboard)
    }

    private func handleMultiExecUserInput(from source: RemoteTerminalPaneViewController, bytes: [UInt8]) -> Bool {
        guard let session = multiExecSession,
              session.targetIDs.contains(source.runtimeID)
        else { return false }

        source.sendInput(bytes)
        guard !session.pausedIDs.contains(source.runtimeID) else {
            return true
        }

        for targetID in session.targetIDs where targetID != source.runtimeID && !session.pausedIDs.contains(targetID) {
            terminalPaneForRuntimeID(targetID)?.sendInput(bytes)
        }
        return true
    }

    private func setMultiExecPaused(_ source: RemoteTerminalPaneViewController, paused: Bool) {
        guard var session = multiExecSession,
              session.targetIDs.contains(source.runtimeID)
        else { return }

        if paused {
            session.pausedIDs.insert(source.runtimeID)
        } else {
            session.pausedIDs.remove(source.runtimeID)
        }
        multiExecSession = session
    }

    private func updateMultiExecSessionRuntimeID(oldRuntimeID: String, newRuntimeID: String) {
        guard oldRuntimeID != newRuntimeID,
              var session = multiExecSession,
              session.targetIDs.contains(oldRuntimeID)
        else {
            return
        }

        let affectedRuntimeIDs = Set(session.targetIDs + [newRuntimeID])
        var seenTargetIDs = Set<String>()
        session.targetIDs = session.targetIDs.compactMap { targetID in
            let resolvedID = targetID == oldRuntimeID ? newRuntimeID : targetID
            return seenTargetIDs.insert(resolvedID).inserted ? resolvedID : nil
        }
        if session.pausedIDs.remove(oldRuntimeID) != nil {
            session.pausedIDs.insert(newRuntimeID)
        }
        guard session.targetIDs.count >= 2 else {
            endCollapsedMultiExecSession(affectedRuntimeIDs: affectedRuntimeIDs)
            return
        }
        multiExecSession = session
    }

    private func endCollapsedMultiExecSession(affectedRuntimeIDs: Set<String>) {
        multiExecSession = nil
        for pane in remoteTerminalPanes() where affectedRuntimeIDs.contains(pane.runtimeID) {
            pane.setMultiExecModeEnabled(false)
        }
        for item in tabViewController.tabViewItems {
            guard let workspace = tabWorkspaces[item],
                  isMultiExecWorkspace(workspace),
                  let firstPane = workspace.panes.first
            else {
                continue
            }
            workspace.kind = .standard
            workspace.baseLabel = title(for: firstPane)
            updateLabel(for: item)
        }
    }

    private func removePanesFromWorkspaces(_ selectedPanes: [NSViewController]) {
        let selectedPaneSet = Set(selectedPanes.map(ObjectIdentifier.init))
        let selectedItem = selectedTabViewItem

        for item in Array(tabViewController.tabViewItems) {
            guard let workspace = tabWorkspaces[item] else { continue }
            let panesToMove = workspace.panes.filter { selectedPaneSet.contains(ObjectIdentifier($0)) }
            if workspace.kind == .standard {
                for pane in panesToMove {
                    let key = ObjectIdentifier(pane)
                    if paneTabRestorations[key] == nil {
                        paneTabRestorations[key] = WorkspacePaneTabRestoration(
                            label: workspace.baseLabel,
                            metadata: tabMetadata[item] ?? WorkspaceTabMetadata(),
                            duplicateHandler: tabDuplicateHandlers[item]
                        )
                    }
                }
            }
            for pane in panesToMove {
                workspace.removePaneForTransfer(pane)
            }
            if workspace.panes.isEmpty {
                tabWorkspaces.removeValue(forKey: item)
                tabMetadata.removeValue(forKey: item)
                tabDuplicateHandlers.removeValue(forKey: item)
                tabViewController.removeTabViewItem(item)
            } else {
                updateLabel(for: item)
            }
        }

        if let selectedItem,
           let selectedIndex = tabViewController.tabViewItems.firstIndex(of: selectedItem) {
            tabViewController.selectedTabViewItemIndex = selectedIndex
        }
    }

    private func removePanesFromWorkspacesForMultiExec(_ selectedPanes: [RemoteTerminalPaneViewController]) {
        removePanesFromWorkspaces(selectedPanes)
    }

    private func restoreTerminalTab(for pane: NSViewController) -> NSTabViewItem {
        let restoration = paneTabRestorations.removeValue(forKey: ObjectIdentifier(pane))
        let label = restoration?.label ?? title(for: pane)
        let item = makeTerminalTab(label: label, firstPane: pane)
        item.label = label
        guard let restoration else { return item }

        tabMetadata[item] = restoration.metadata
        if let color = restoration.metadata.color {
            item.color = color
        }
        if let duplicateHandler = restoration.duplicateHandler {
            tabDuplicateHandlers[item] = duplicateHandler
        }
        applyTabIcon(for: item)
        if restoration.metadata.isPinned,
           let index = tabViewController.tabViewItems.firstIndex(of: item),
           index > pinnedInsertionIndex(excluding: item) {
            tabViewController.removeTabViewItem(item)
            tabViewController.insertTabViewItem(item, at: pinnedInsertionIndex(excluding: item))
        }
        return item
    }

    private func runtimeID(for pane: NSViewController) -> String {
        if let local = pane as? TerminalPaneViewController {
            return local.runtimeID
        }
        if let remote = pane as? RemoteTerminalPaneViewController {
            return remote.runtimeID
        }
        if let files = pane as? RemoteFilesPaneViewController {
            return files.runtimeID
        }
        if let browser = pane as? BrowserPaneViewController {
            return browser.runtimeID
        }
        if let files = pane as? LocalFilePaneViewController {
            return files.runtimeID
        }
        if let graphics = pane as? GraphicsSessionPaneViewController {
            return graphics.runtimeID
        }
        return ""
    }

    private func title(for pane: NSViewController) -> String {
        if let remote = pane as? RemoteTerminalPaneViewController {
            return remote.terminalTitle
        }
        if pane is TerminalPaneViewController {
            return L10n.Workspace.local
        }
        return pane.title ?? ""
    }

    private func environment(for title: String) -> String {
        let lowercased = title.lowercased()
        if lowercased.contains("prod") || title.contains("生产") {
            return "production"
        }
        return "development"
    }

    private func environment(for pane: NSViewController) -> String {
        if let remote = pane as? RemoteTerminalPaneViewController,
           remote.automationPolicy.environment != "development" {
            return remote.automationPolicy.environment
        }
        return environment(for: title(for: pane))
    }

    public static func defaultShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    private static func defaultCommandCompletionNotifier() -> TerminalCommandCompletionNotificationDelivering {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        guard processName != "xctest",
              processName.hasSuffix("xctest") == false
        else {
            return NoopTerminalCommandCompletionNotifier()
        }
        return UserNotificationTerminalCommandCompletionNotifier.shared
    }

    private static func defaultDeviceMetricsAlertNotifier() -> DeviceMetricsAlertNotificationDelivering {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        guard processName != "xctest",
              processName.hasSuffix("xctest") == false
        else {
            return NoopDeviceMetricsAlertNotifier()
        }
        return ActivatingDeviceMetricsAlertNotifier(delivery: UserNotificationDelivery.shared)
    }

    private func normalizedBrowserURL(_ value: String) -> URL? {
        BrowserURLNormalizer.normalizedURL(value)
    }
}

private final class TerminalSplitPaneContainerViewController: NSViewController, StacioEffectiveAppearanceRefreshHandling {
    let pane: NSViewController
    var accessoryProvider: (() -> NSView?)?

    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let accessoryContainer = NSView()
    private var currentAccessory: NSView?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var installedConstraints: [NSLayoutConstraint] = []
    private var paneIdentifier = ""
    private var isHeaderVisible = true

    init(pane: NSViewController, title: String, paneIdentifier: String) {
        self.pane = pane
        self.paneIdentifier = paneIdentifier
        super.init(nibName: nil, bundle: nil)
        titleLabel.stringValue = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = StacioAppearanceRefreshView()
        StacioDesignSystem.setLayerBackgroundColor(container, color: .textBackgroundColor)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(
            headerView,
            color: StacioDesignSystem.dynamicColor(.windowBackgroundColor, alpha: 0.96)
        )
        headerView.isHidden = !isHeaderVisible
        headerView.setAccessibilityIdentifier("Stacio.Workspace.splitPaneHeader.\(paneIdentifier)")

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("Stacio.Workspace.splitPaneHeader.title.\(paneIdentifier)")

        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.setContentHuggingPriority(.required, for: .horizontal)
        accessoryContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerView)
        container.addSubview(pane.view)
        headerView.addSubview(titleLabel)
        headerView.addSubview(accessoryContainer)

        let headerHeight = headerView.heightAnchor.constraint(equalToConstant: isHeaderVisible ? 28 : 0)
        headerHeightConstraint = headerHeight
        let constraints = [
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: container.topAnchor),
            headerHeight,

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryContainer.leadingAnchor, constant: -8),

            accessoryContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            accessoryContainer.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            accessoryContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            accessoryContainer.heightAnchor.constraint(equalToConstant: 22),

            pane.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            pane.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        installedConstraints = constraints
        NSLayoutConstraint.activate(constraints)

        view = container
        stacioRefreshEffectiveAppearance()
        refreshAccessory()
        stacioRefreshEffectiveAppearance()
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func updatePaneIdentifier(_ identifier: String) {
        paneIdentifier = identifier
        guard isViewLoaded else { return }
        headerView.setAccessibilityIdentifier("Stacio.Workspace.splitPaneHeader.\(identifier)")
        titleLabel.setAccessibilityIdentifier("Stacio.Workspace.splitPaneHeader.title.\(identifier)")
    }

    func setHeaderVisible(_ visible: Bool) {
        isHeaderVisible = visible
        guard isViewLoaded else { return }
        headerView.isHidden = !visible
        headerHeightConstraint?.constant = visible ? 28 : 0
    }

    func refreshAccessory() {
        guard isViewLoaded else { return }
        currentAccessory?.removeFromSuperview()
        currentAccessory = nil
        guard let accessory = accessoryProvider?() else { return }

        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            accessory.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
            accessory.centerYAnchor.constraint(equalTo: accessoryContainer.centerYAnchor),
            accessory.widthAnchor.constraint(equalToConstant: 24),
            accessory.heightAnchor.constraint(equalToConstant: 22)
        ])
        currentAccessory = accessory
    }

    func stacioRefreshEffectiveAppearance() {
        guard isViewLoaded else { return }
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        view.appearance = appearance
        headerView.appearance = appearance
        titleLabel.appearance = appearance
        accessoryContainer.appearance = appearance
        StacioDesignSystem.refreshDynamicLayerColors(in: view)
        titleLabel.textColor = StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: appearance)
        if let button = currentAccessory as? NSButton {
            button.appearance = appearance
            button.contentTintColor = StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: appearance)
        }
        if let handler = pane.view as? StacioEffectiveAppearanceRefreshHandling {
            handler.stacioRefreshEffectiveAppearance()
        } else {
            pane.view.appearance = appearance
            StacioDesignSystem.refreshDynamicLayerColors(in: pane.view)
        }
        headerView.needsDisplay = true
        view.needsDisplay = true
    }

    func detachPane() {
        NSLayoutConstraint.deactivate(installedConstraints)
        installedConstraints = []
        pane.view.removeFromSuperview()
        if pane.parent === self {
            pane.removeFromParent()
        }
        currentAccessory?.removeFromSuperview()
        currentAccessory = nil
    }
}

private protocol TerminalCommandHandling: AnyObject {
    var keyboardFocusView: NSView { get }
    @discardableResult
    func find(_ term: String) -> Bool
    func copySelection()
    func pasteClipboard()
    func showFind()
    func closeTerminal()
    func sendInput(_ bytes: [UInt8])
}

private protocol TerminalOutputTranscriptProviding {
    var terminalOutputTranscript: String { get }
}

extension TerminalPaneViewController: TerminalCommandHandling {}
extension RemoteTerminalPaneViewController: TerminalCommandHandling {}
extension TerminalPaneViewController: TerminalOutputTranscriptProviding {}
extension RemoteTerminalPaneViewController: TerminalOutputTranscriptProviding {}

extension WorkspaceViewController: AgentTerminalSessionListing {
    public func listAgentTerminalSessions() -> [AgentTerminalSessionSummary] {
        syncCurrentTerminalPaneWithFirstResponder()
        let currentID = currentTerminalPaneForAgent()?.runtimeID
        return terminalCommandPanes().map { pane in
            let title = title(for: pane)
            let directory: String?
            if let remote = pane as? RemoteTerminalPaneViewController {
                directory = remote.currentRemoteDirectory
            } else if let local = pane as? TerminalPaneViewController {
                directory = local.currentLocalDirectory
            } else {
                directory = nil
            }
            let kind = agentTerminalKind(for: pane)
            let subtitle = [kind, directory].compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }.joined(separator: " · ")
            return AgentTerminalSessionSummary(
                runtimeID: runtimeID(for: pane),
                title: title,
                kind: kind,
                environment: environment(for: pane),
                isCurrent: runtimeID(for: pane) == currentID,
                currentDirectory: directory,
                subtitle: subtitle.isEmpty ? nil : subtitle
            )
        }
    }

    private func agentTerminalKind(for pane: NSViewController) -> String {
        if pane is TerminalPaneViewController {
            return "local"
        }
        if let remote = pane as? RemoteTerminalPaneViewController {
            switch remote.connectionKind {
            case .ssh:
                return "ssh"
            case .telnet:
                return "telnet"
            case .serial:
                return "serial"
            }
        }
        return "terminal"
    }
}

extension WorkspaceViewController: AgentTerminalResolving {
    public func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        switch target {
        case .currentTerminal:
            guard let pane = currentAgentTerminalTarget else {
                throw AgentExecutionError.terminalNotFound
            }
            return pane
        case .runtimeID(let runtimeID):
            guard let pane = agentTerminalTarget(runtimeID: runtimeID) else {
                throw AgentExecutionError.terminalNotFound
            }
            return pane
        case .sessionID:
            throw AgentExecutionError.terminalNotFound
        }
    }
}

private enum WorkspaceTabActionError: Error, LocalizedError {
    case unsupportedDuplicate
    case noTerminalOutput
    case detachFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedDuplicate:
            return L10n.WorkspaceTabs.duplicateUnsupported
        case .noTerminalOutput:
            return L10n.WorkspaceTabs.noTerminalOutput
        case .detachFailed:
            return L10n.WorkspaceTabs.detachFailed
        }
    }
}

private struct WorkspaceTabMetadata {
    var color: NSColor?
    var isPinned = false
    var defaultIcon: SessionTabIconDescriptor?
    var manualIcon: SessionTabIconDescriptor?
    var detectedOperatingSystemIcon: SessionTabIconDescriptor?
    var connectionKind: RemoteTerminalConnectionKind?
}

private struct WorkspacePaneTabRestoration {
    let label: String
    let metadata: WorkspaceTabMetadata
    let duplicateHandler: ((String) throws -> Void)?
}

private enum TerminalWorkspaceKind {
    case standard
    case split
    case multiExec
}

private enum WorkspaceTabMenuEntry {
    case action(WorkspaceTabContextAction, String)
    case separator

    static let entries: [WorkspaceTabMenuEntry] = [
        .action(.rename, L10n.WorkspaceTabs.rename),
        .action(.setColor, L10n.WorkspaceTabs.setColor),
        .action(.duplicate, L10n.WorkspaceTabs.duplicate),
        .action(.closeTab, L10n.WorkspaceTabs.closeTab),
        .separator,
        .action(.closeTabsToLeft, L10n.WorkspaceTabs.closeTabsToLeft),
        .action(.closeTabsToRight, L10n.WorkspaceTabs.closeTabsToRight),
        .action(.closeOtherTabs, L10n.WorkspaceTabs.closeOtherTabs),
        .action(.closeAllTabs, L10n.WorkspaceTabs.closeAllTabs),
        .separator,
        .action(.detach, L10n.WorkspaceTabs.detach),
        .action(.toggleFullscreen, L10n.WorkspaceTabs.fullscreen),
        .action(.pin, L10n.WorkspaceTabs.pin),
        .separator,
        .action(.saveTerminalOutput, L10n.WorkspaceTabs.saveTerminalOutput),
        .action(.printTerminalOutput, L10n.WorkspaceTabs.printTerminalOutput),
        .action(.increaseFontSize, L10n.WorkspaceTabs.increaseFontSize),
        .action(.decreaseFontSize, L10n.WorkspaceTabs.decreaseFontSize)
    ]
}

private extension NSColor {
    var workspaceHexRGB: String? {
        guard let color = usingColorSpace(.sRGB) else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

private final class WorkspaceTabViewController: NSTabViewController, NSMenuDelegate, StacioEffectiveAppearanceRefreshHandling {
    private static let tabControlLeadingInset: CGFloat = 8
    private static let addButtonSpacing: CGFloat = 0
    private static let addButtonWidth: CGFloat = 34
    private static let addButtonFallbackHeight: CGFloat = 24
    private static let closeButtonSize: CGFloat = 16
    private static let closeButtonLeadingInset: CGFloat = 5
    private static let minimumTabSegmentWidth: CGFloat = 76
    private static let tabTitleCloseProtectionWidth: CGFloat = 54

    var didSelectItem: (() -> Void)?
    var addLocalTerminalHandler: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    var menuActionHandler: ((WorkspaceTabContextAction, Int) throws -> Void)?
    var closeHoveredTabHandler: ((Int) throws -> Void)?
    private lazy var addLocalTerminalButton: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["+"],
            trackingMode: .momentary,
            target: self,
            action: #selector(addLocalTerminalButtonClicked(_:))
        )
        control.segmentStyle = .texturedRounded
        control.controlSize = .small
        control.font = .systemFont(ofSize: 13, weight: .semibold)
        control.setWidth(Self.addButtonWidth, forSegment: 0)
        control.setToolTip(L10n.Menu.newLocalTerminal, forSegment: 0)
        control.setAccessibilityLabel(L10n.Menu.newLocalTerminal)
        control.setAccessibilityIdentifier("Stacio.Workspace.tabs.addLocalTerminal")
        control.isHidden = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.addButtonWidth,
            height: Self.addButtonFallbackHeight
        )
        return control
    }()
    private lazy var closeHoveredTabButton: NSButton = {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: L10n.WorkspaceTabs.closeTab
            ) ?? NSImage(),
            target: self,
            action: #selector(closeHoveredTabButtonClicked(_:))
        )
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        button.toolTip = L10n.WorkspaceTabs.closeTab
        button.setAccessibilityLabel(L10n.WorkspaceTabs.closeTab)
        button.setAccessibilityIdentifier("Stacio.Workspace.tabs.closeHoveredTab")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu(title: L10n.WorkspaceTabs.closeTab)
        menu.delegate = self
        return menu
    }()
    private var rightClickedTabIndex: Int?
    private var hoveredTabIndex: Int?
    private weak var constrainedTabControl: NSSegmentedControl?
    private var tabHoverTrackingArea: NSTrackingArea?
    private var tabControlLeadingConstraint: NSLayoutConstraint?
    private var addButtonConstraints: [NSLayoutConstraint] = []
    private var closeButtonConstraints: [NSLayoutConstraint] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .segmentedControlOnTop
        tabView.menu = contextMenu
        StacioDesignSystem.setLayerBackgroundColor(view, color: .windowBackgroundColor)
        view.addSubview(addLocalTerminalButton)
        view.addSubview(closeHoveredTabButton)
        installAddButtonConstraintsIfNeeded()
        installCloseButtonConstraintsIfNeeded()
        stacioRefreshEffectiveAppearance()
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        installTabControlLeadingConstraintIfNeeded()
        updateTabSegmentWidthsIfNeeded()
        installAddButtonConstraintsIfNeeded()
        installCloseButtonConstraintsIfNeeded()
        updateTabHoverTrackingArea()
        refreshTabControlAppearance()
    }

    func stacioRefreshEffectiveAppearance() {
        guard isViewLoaded else { return }
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        view.appearance = appearance
        tabView.appearance = appearance
        addLocalTerminalButton.appearance = appearance
        closeHoveredTabButton.appearance = appearance
        closeHoveredTabButton.contentTintColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.secondaryTextColor,
            for: appearance
        )
        StacioDesignSystem.refreshDynamicLayerColors(in: view)
        refreshTabControlAppearance()
    }

    override var selectedTabViewItemIndex: Int {
        didSet {
            guard oldValue != selectedTabViewItemIndex else { return }
            didSelectItem?()
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        didSelectItem?()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        menu.removeAllItems()
        let index: Int
        if let event = NSApp.currentEvent {
            index = tabIndex(for: event.locationInWindow)
        } else {
            index = selectedTabViewItemIndex
        }
        guard index >= 0,
              let builtMenu = menuProvider?(index)
        else { return }
        rightClickedTabIndex = index
        while builtMenu.items.isEmpty == false {
            let item = builtMenu.items[0]
            builtMenu.removeItem(at: 0)
            menu.addItem(item)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let index = tabIndex(for: event.locationInWindow)
        guard index >= 0,
              let menu = menuProvider?(index)
        else {
            super.rightMouseDown(with: event)
            return
        }
        rightClickedTabIndex = index
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredTab(for: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoveredTab(for: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideHoveredTabCloseButton()
    }

    @objc
    func contextMenuItemSelected(_ sender: NSMenuItem) {
        let index = (sender.representedObject as? Int) ?? rightClickedTabIndex ?? selectedTabViewItemIndex
        guard let action = WorkspaceTabContextAction(rawValue: sender.tag) else { return }
        try? menuActionHandler?(action, index)
    }

    @objc
    private func addLocalTerminalButtonClicked(_ sender: NSSegmentedControl) {
        addLocalTerminalHandler?()
    }

    @objc
    private func closeHoveredTabButtonClicked(_ sender: NSButton) {
        guard let index = hoveredTabIndex,
              index >= 0,
              index < tabViewItems.count
        else { return }

        try? closeHoveredTabHandler?(index)
        hideHoveredTabCloseButton()
    }

    private func tabIndex(for windowPoint: NSPoint) -> Int {
        let items = tabViewItems
        guard items.isEmpty == false else { return -1 }
        if let tabControl = tabSegmentedControl {
            let point = tabControl.convert(windowPoint, from: nil)
            guard tabControl.bounds.contains(point) else {
                return selectedTabViewItemIndex
            }
            return segmentIndex(atX: point.x, in: tabControl, itemCount: items.count)
        }
        guard let tabBarView = tabView.superview else {
            return selectedTabViewItemIndex
        }
        let point = tabBarView.convert(windowPoint, from: nil)
        let tabAreaHeight: CGFloat = 32
        guard point.y >= tabBarView.bounds.height - tabAreaHeight else {
            return selectedTabViewItemIndex
        }
        let itemWidth = max(1, tabBarView.bounds.width / CGFloat(items.count))
        let rawIndex = Int(point.x / itemWidth)
        return min(max(rawIndex, 0), items.count - 1)
    }

    private func updateHoveredTab(for windowPoint: NSPoint) {
        guard let tabControl = tabSegmentedControl,
              tabViewItems.isEmpty == false
        else {
            hideHoveredTabCloseButton()
            return
        }
        updateTabSegmentWidthsIfNeeded()

        let point = tabControl.convert(windowPoint, from: nil)
        guard tabControl.bounds.contains(point) else {
            let buttonPoint = closeHoveredTabButton.convert(windowPoint, from: nil)
            if closeHoveredTabButton.bounds.contains(buttonPoint) == false {
                hideHoveredTabCloseButton()
            }
            return
        }

        hoveredTabIndex = segmentIndex(atX: point.x, in: tabControl, itemCount: tabViewItems.count)
        installCloseButtonConstraintsIfNeeded()
        closeHoveredTabButton.isHidden = false
    }

    private func hideHoveredTabCloseButton() {
        hoveredTabIndex = nil
        closeHoveredTabButton.isHidden = true
    }

    private func installTabControlLeadingConstraintIfNeeded() {
        guard let tabControl = tabSegmentedControl,
              constrainedTabControl !== tabControl
        else { return }

        tabControlLeadingConstraint?.isActive = false
        removeSystemHorizontalPositioningConstraints(for: tabControl)
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        let leadingConstraint = tabControl.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: Self.tabControlLeadingInset
        )
        leadingConstraint.identifier = "Stacio.Workspace.tabs.leading"
        leadingConstraint.isActive = true
        tabControlLeadingConstraint = leadingConstraint
        constrainedTabControl = tabControl
        installAddButtonConstraintsIfNeeded()
    }

    private func updateTabSegmentWidthsIfNeeded() {
        guard let tabControl = tabSegmentedControl else { return }

        let font = tabControl.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for index in 0..<min(tabViewItems.count, tabControl.segmentCount) {
            let title = tabViewItems[index].label
            let titleWidth = title.size(withAttributes: [.font: font]).width
            let imageWidth: CGFloat = tabViewItems[index].image == nil ? 0 : 24
            let width = max(
                Self.minimumTabSegmentWidth,
                ceil(titleWidth + Self.tabTitleCloseProtectionWidth + imageWidth)
            )
            if abs(tabControl.width(forSegment: index) - width) > 0.5 {
                tabControl.setWidth(width, forSegment: index)
            }
        }
    }

    func invalidateTabSegmentWidths() {
        updateTabSegmentWidthsIfNeeded()
        installAddButtonConstraintsIfNeeded()
        installCloseButtonConstraintsIfNeeded()
    }

    private func refreshTabControlAppearance() {
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        tabSegmentedControl?.appearance = appearance
        addLocalTerminalButton.appearance = appearance
        closeHoveredTabButton.appearance = appearance
        closeHoveredTabButton.contentTintColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.secondaryTextColor,
            for: appearance
        )
    }

    func tabSegmentWidthForTesting(index: Int) -> CGFloat? {
        guard let tabControl = tabSegmentedControl,
              index >= 0,
              index < tabControl.segmentCount
        else { return nil }
        updateTabSegmentWidthsIfNeeded()
        return tabControl.width(forSegment: index)
    }

    private func installAddButtonConstraintsIfNeeded() {
        guard addLocalTerminalButton.superview === view else { return }
        addLocalTerminalButton.isHidden = tabViewItems.isEmpty

        NSLayoutConstraint.deactivate(addButtonConstraints)
        addButtonConstraints.removeAll()

        addButtonConstraints.append(contentsOf: [
            addLocalTerminalButton.widthAnchor.constraint(equalToConstant: Self.addButtonWidth)
        ])

        if let tabControl = tabSegmentedControl {
            addLocalTerminalButton.segmentStyle = tabControl.segmentStyle
            addButtonConstraints.append(contentsOf: [
                addLocalTerminalButton.leadingAnchor.constraint(
                    equalTo: tabControl.trailingAnchor,
                    constant: Self.addButtonSpacing
                ),
                addLocalTerminalButton.heightAnchor.constraint(equalTo: tabControl.heightAnchor),
                addLocalTerminalButton.centerYAnchor.constraint(equalTo: tabControl.centerYAnchor),
                addLocalTerminalButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8)
            ])
        } else {
            addButtonConstraints.append(contentsOf: [
                addLocalTerminalButton.leadingAnchor.constraint(
                    equalTo: view.leadingAnchor,
                    constant: Self.tabControlLeadingInset
                ),
                addLocalTerminalButton.heightAnchor.constraint(equalToConstant: Self.addButtonFallbackHeight),
                addLocalTerminalButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                addLocalTerminalButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8)
            ])
        }

        NSLayoutConstraint.activate(addButtonConstraints)
    }

    private func updateTabHoverTrackingArea() {
        if let tabHoverTrackingArea {
            view.removeTrackingArea(tabHoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        tabHoverTrackingArea = area
    }

    private func installCloseButtonConstraintsIfNeeded() {
        guard closeHoveredTabButton.superview === view else { return }

        NSLayoutConstraint.deactivate(closeButtonConstraints)
        closeButtonConstraints.removeAll()

        closeButtonConstraints.append(contentsOf: [
            closeHoveredTabButton.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
            closeHoveredTabButton.heightAnchor.constraint(equalToConstant: Self.closeButtonSize)
        ])

        guard let tabControl = tabSegmentedControl,
              let index = hoveredTabIndex,
              index >= 0,
              index < min(tabViewItems.count, tabControl.segmentCount)
        else {
            closeButtonConstraints.append(contentsOf: [
                closeHoveredTabButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                closeHoveredTabButton.topAnchor.constraint(equalTo: view.topAnchor)
            ])
            NSLayoutConstraint.activate(closeButtonConstraints)
            return
        }

        closeButtonConstraints.append(contentsOf: [
            closeHoveredTabButton.leadingAnchor.constraint(
                equalTo: tabControl.leadingAnchor,
                constant: segmentLeadingOffset(for: index, in: tabControl) + Self.closeButtonLeadingInset
            ),
            closeHoveredTabButton.centerYAnchor.constraint(equalTo: tabControl.centerYAnchor)
        ])
        NSLayoutConstraint.activate(closeButtonConstraints)
    }

    private func removeSystemHorizontalPositioningConstraints(for tabControl: NSSegmentedControl) {
        let horizontalAttributes: Set<NSLayoutConstraint.Attribute> = [
            .left,
            .leading,
            .right,
            .trailing,
            .centerX
        ]
        var container = tabControl.superview
        while let current = container {
            let constraints = current.constraints.filter { constraint in
                constraint.constrains(
                    tabControl,
                    usingAnyOf: horizontalAttributes
                )
            }
            NSLayoutConstraint.deactivate(constraints)
            if current === view {
                break
            }
            container = current.superview
        }
    }

    private func segmentIndex(atX x: CGFloat, in tabControl: NSSegmentedControl, itemCount: Int) -> Int {
        var leading: CGFloat = 0
        let segmentCount = min(itemCount, tabControl.segmentCount)
        for index in 0..<segmentCount {
            let width = segmentWidth(for: index, in: tabControl, segmentCount: segmentCount)
            if x >= leading && x < leading + width {
                return index
            }
            leading += width
        }
        return selectedTabViewItemIndex
    }

    private func segmentLeadingOffset(for targetIndex: Int, in tabControl: NSSegmentedControl) -> CGFloat {
        let segmentCount = min(tabViewItems.count, tabControl.segmentCount)
        guard targetIndex >= 0,
              targetIndex < segmentCount
        else { return 0 }

        guard targetIndex > 0 else { return 0 }

        return (0..<targetIndex).reduce(CGFloat(0)) { partial, index in
            partial + segmentWidth(for: index, in: tabControl, segmentCount: segmentCount)
        }
    }

    private func segmentWidth(for index: Int, in tabControl: NSSegmentedControl, segmentCount: Int) -> CGFloat {
        let explicitWidth = tabControl.width(forSegment: index)
        if explicitWidth > 1 {
            return explicitWidth
        }
        return max(1, tabControl.bounds.width / CGFloat(max(1, segmentCount)))
    }

    private var tabSegmentedControl: NSSegmentedControl? {
        firstSubview(of: NSSegmentedControl.self, in: view) { [weak self] control in
            guard let self else { return true }
            return control !== self.addLocalTerminalButton
        }
    }

    private func firstSubview<T: NSView>(
        of type: T.Type,
        in root: NSView,
        matching predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = root as? T {
            if predicate(match) {
                return match
            }
        }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview, matching: predicate) {
                return match
            }
        }
        return nil
    }
}

private extension NSLayoutConstraint {
    func constrains(_ view: NSView, usingAnyOf attributes: Set<NSLayoutConstraint.Attribute>) -> Bool {
        let firstMatches = (firstItem as? NSView) === view && attributes.contains(firstAttribute)
        let secondMatches = (secondItem as? NSView) === view && attributes.contains(secondAttribute)
        return firstMatches || secondMatches
    }
}

private final class TerminalSplitWorkspace: NSViewController, StacioEffectiveAppearanceRefreshHandling {
    private static let dashboardPreferredWidth: CGFloat = 360
    private static let dashboardTrailingInset: CGFloat = 16
    private static let dashboardVerticalInset: CGFloat = 16
    private static let dashboardMinimumHeight: CGFloat = 180
    private static let dashboardMaximumHeightRatio: CGFloat = 0.78
    var baseLabel: String {
        didSet {
            refreshPaneHeaders()
        }
    }
    var kind: TerminalWorkspaceKind
    private(set) var panes: [NSViewController]
    private let titleProvider: (NSViewController) -> String
    private let identifierProvider: (NSViewController) -> String
    private let splitViewController = StacioPinnedSplitViewController()
    private let gridContainer = NSView()
    private var deviceDashboard: NSViewController?
    private weak var selectedPaneReference: NSViewController?
    private var isDeviceDashboardGloballyVisible: Bool
    private var layoutMode: TerminalSplitLayoutMode = .vertical
    private var gridColumnCount = 0
    private var gridRowCount = 0
    private var paneContainers: [ObjectIdentifier: TerminalSplitPaneContainerViewController] = [:]

    init(
        baseLabel: String,
        firstPane: NSViewController,
        deviceDashboard: NSViewController? = nil,
        titleProvider: @escaping (NSViewController) -> String,
        identifierProvider: @escaping (NSViewController) -> String,
        isDeviceDashboardGloballyVisible: Bool = true,
        kind: TerminalWorkspaceKind = .standard
    ) {
        self.baseLabel = baseLabel
        self.kind = kind
        self.panes = [firstPane]
        self.titleProvider = titleProvider
        self.identifierProvider = identifierProvider
        self.deviceDashboard = deviceDashboard
        self.isDeviceDashboardGloballyVisible = isDeviceDashboardGloballyVisible
        super.init(nibName: nil, bundle: nil)
        self.selectedPaneReference = firstPane
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var selectedPane: NSViewController? {
        if let selectedPaneReference,
           containsPane(selectedPaneReference) {
            return selectedPaneReference
        }
        return panes.last
    }

    var trailingAccessoryTitle: String? {
        shouldShowDeviceDashboard ? deviceDashboard?.title : nil
    }

    var minimumThicknessesForTesting: [CGFloat] {
        splitViewController.splitViewItems.map(\.minimumThickness)
    }

    var layoutModeForTesting: TerminalSplitLayoutMode {
        layoutMode
    }

    var gridColumnCountForTesting: Int {
        gridColumnCount
    }

    var gridRowCountForTesting: Int {
        gridRowCount
    }

    var isDeviceDashboardVisibleForTesting: Bool {
        guard let deviceDashboard,
              deviceDashboard.isViewLoaded
        else { return false }
        return !deviceDashboard.view.isHidden
    }

    var terminalReservedTrailingWidthForTesting: CGFloat {
        0
    }

    var deviceDashboardFrameForTesting: NSRect? {
        guard let deviceDashboard,
              deviceDashboard.isViewLoaded
        else { return nil }
        return deviceDashboard.view.frame
    }

    var deviceDashboardContainerBoundsForTesting: NSRect? {
        guard deviceDashboard != nil,
              isViewLoaded
        else { return nil }
        return view.bounds
    }

    func refreshDeviceDashboardForTesting() {
        (deviceDashboard as? DeviceMetricsDashboardViewController)?.refreshMetricsForTesting()
        layoutTerminalWorkspace()
    }

    func stacioRefreshEffectiveAppearance() {
        guard isViewLoaded else { return }
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        view.appearance = appearance
        splitViewController.view.appearance = appearance
        gridContainer.appearance = appearance
        StacioDesignSystem.refreshDynamicLayerColors(in: view)
        for container in paneContainers.values {
            container.stacioRefreshEffectiveAppearance()
        }
        if let deviceDashboard {
            deviceDashboard.view.appearance = appearance
            StacioDesignSystem.refreshDynamicLayerColors(in: deviceDashboard.view)
            if let handler = deviceDashboard.view as? StacioEffectiveAppearanceRefreshHandling {
                handler.stacioRefreshEffectiveAppearance()
            }
        }
    }

    override func loadView() {
        let container = NSView()

        splitViewController.splitView.isVertical = true
        addChild(splitViewController)
        splitViewController.view.frame = container.bounds
        splitViewController.view.autoresizingMask = []
        container.addSubview(splitViewController.view)

        gridContainer.frame = container.bounds
        gridContainer.autoresizingMask = []
        gridContainer.isHidden = true
        container.addSubview(gridContainer, positioned: .below, relativeTo: splitViewController.view)

        rebuildPaneLayout()
        addDeviceDashboardIfNeeded(to: container)
        splitViewController.portDeskPinSplitViewToContainerEdges()

        view = container
        refreshDeviceDashboardVisibility()
        stacioRefreshEffectiveAppearance()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutTerminalWorkspace()
    }

    func addPane(_ pane: NSViewController) {
        panes.append(pane)
        selectedPaneReference = pane
        if isViewLoaded {
            installPaneForCurrentLayout(pane)
            refreshPaneHeaders()
            applySinglePaneCollapseIfNeeded()
            refreshDeviceDashboardVisibility()
            layoutTerminalWorkspace()
        }
    }

    func removePane(_ pane: NSViewController) {
        removePane(pane, removeFromParent: true)
    }

    func removePaneForTransfer(_ pane: NSViewController) {
        removePane(pane, removeFromParent: false)
    }

    private func removePane(_ pane: NSViewController, removeFromParent: Bool) {
        let removedSelectedPane = selectedPaneReference === pane
        panes.removeAll { $0 === pane }
        detachPaneFromCurrentLayout(pane)
        if removeFromParent,
           pane.parent != nil {
            pane.removeFromParent()
        }
        if removedSelectedPane {
            selectedPaneReference = panes.last
        }
        if let container = paneContainers.removeValue(forKey: ObjectIdentifier(pane)) {
            container.detachPane()
        }
        refreshPaneHeaders()
        refreshDeviceDashboardVisibility()
    }

    func selectPane(_ pane: NSViewController) {
        guard containsPane(pane) else { return }
        selectedPaneReference = pane
        applySinglePaneCollapseIfNeeded()
        layoutTerminalWorkspace()
    }

    func setDeviceDashboardGloballyVisible(_ visible: Bool) {
        isDeviceDashboardGloballyVisible = visible
        refreshDeviceDashboardVisibility()
    }

    func installDeviceDashboardIfAbsent(_ dashboard: NSViewController) {
        guard deviceDashboard == nil else { return }
        deviceDashboard = dashboard
        if isViewLoaded {
            addDeviceDashboardIfNeeded(to: view)
            refreshDeviceDashboardVisibility()
            layoutTerminalWorkspace()
        }
    }

    func refreshDeviceDashboardVisibility() {
        guard isViewLoaded else { return }
        let shouldShow = shouldShowDeviceDashboard
        deviceDashboard?.view.isHidden = !shouldShow
        updateTerminalReserveConstraints()
    }

    func containsPane(_ pane: NSViewController) -> Bool {
        panes.contains { $0 === pane }
    }

    func pane(containing view: NSView) -> NSViewController? {
        panes.first { pane in
            if pane.isViewLoaded && (view === pane.view || view.isDescendant(of: pane.view)) {
                return true
            }
            guard let container = paneContainers[ObjectIdentifier(pane)],
                  container.isViewLoaded
            else {
                return false
            }
            return view === container.view || view.isDescendant(of: container.view)
        }
    }

    func setLayoutMode(_ mode: TerminalSplitLayoutMode) {
        guard layoutMode != mode else {
            applySinglePaneCollapseIfNeeded()
            layoutTerminalWorkspace()
            return
        }
        layoutMode = mode
        if isViewLoaded {
            rebuildPaneLayout()
            refreshDeviceDashboardVisibility()
            layoutTerminalWorkspace()
        }
    }

    private func rebuildPaneLayout() {
        for item in splitViewController.splitViewItems {
            splitViewController.removeSplitViewItem(item)
        }
        for pane in panes {
            detachPaneFromGrid(pane)
            detachPaneFromSplit(pane)
            installPaneForCurrentLayout(pane)
        }
        applySinglePaneCollapseIfNeeded()
    }

    private func installPaneForCurrentLayout(_ pane: NSViewController) {
        switch layoutMode {
        case .grid:
            addGridPane(pane)
        case .single, .vertical, .horizontal:
            addSplitItem(for: pane)
        }
    }

    private func detachPaneFromCurrentLayout(_ pane: NSViewController) {
        detachPaneFromSplit(pane)
        detachPaneFromGrid(pane)
    }

    private func addSplitItem(for pane: NSViewController) {
        let container = containerController(for: pane)
        guard splitViewController.splitViewItems.contains(where: { $0.viewController === container }) == false else {
            return
        }
        detachPaneFromGrid(pane)
        let item = NSSplitViewItem(viewController: container)
        item.minimumThickness = 0
        item.preferredThicknessFraction = 1.0 / CGFloat(max(panes.count, 1))
        splitViewController.addSplitViewItem(item)
    }

    private func addGridPane(_ pane: NSViewController) {
        let container = containerController(for: pane)
        guard container.view.superview !== gridContainer else { return }
        detachPaneFromSplit(pane)
        if container.parent !== self {
            addChild(container)
        }
        container.view.translatesAutoresizingMaskIntoConstraints = true
        container.view.autoresizingMask = []
        gridContainer.addSubview(container.view)
    }

    private func detachPaneFromGrid(_ pane: NSViewController) {
        guard let container = paneContainers[ObjectIdentifier(pane)] else { return }
        if container.view.superview === gridContainer {
            container.view.removeFromSuperview()
        }
        if container.parent === self {
            container.removeFromParent()
        }
    }

    private func applySinglePaneCollapseIfNeeded() {
        let selectedPane = selectedPane
        for item in splitViewController.splitViewItems {
            let itemPane = pane(forContainer: item.viewController)
            item.isCollapsed = layoutMode == .single && itemPane !== selectedPane
        }
    }

    private func detachPaneFromSplit(_ pane: NSViewController) {
        guard let container = paneContainers[ObjectIdentifier(pane)],
              let item = splitViewController.splitViewItems.first(where: { $0.viewController === container })
        else { return }
        splitViewController.removeSplitViewItem(item)
    }

    private func containerController(for pane: NSViewController) -> TerminalSplitPaneContainerViewController {
        let key = ObjectIdentifier(pane)
        if let existing = paneContainers[key] {
            existing.updateTitle(titleProvider(pane))
            existing.updatePaneIdentifier(identifierProvider(pane))
            existing.setHeaderVisible(shouldShowPaneHeaders)
            existing.refreshAccessory()
            return existing
        }

        let container = TerminalSplitPaneContainerViewController(
            pane: pane,
            title: titleProvider(pane),
            paneIdentifier: identifierProvider(pane)
        )
        container.setHeaderVisible(shouldShowPaneHeaders)
        if let remote = pane as? RemoteTerminalPaneViewController {
            container.accessoryProvider = { [weak remote] in
                guard let remote,
                      remote.isMultiExecModeEnabled
                else { return nil }
                return remote.makeMultiExecPauseButton()
            }
            remote.onMultiExecPresentationChanged = { [weak container] _ in
                container?.refreshAccessory()
            }
            container.refreshAccessory()
        }
        paneContainers[key] = container
        return container
    }

    private func pane(forContainer viewController: NSViewController) -> NSViewController? {
        guard let container = viewController as? TerminalSplitPaneContainerViewController else {
            return viewController
        }
        return container.pane
    }

    private var shouldShowPaneHeaders: Bool {
        panes.count > 1 || kind == .multiExec
    }

    private func refreshPaneHeaders() {
        guard isViewLoaded else { return }
        for pane in panes {
            let container = containerController(for: pane)
            container.updateTitle(titleProvider(pane))
            container.updatePaneIdentifier(identifierProvider(pane))
            container.setHeaderVisible(shouldShowPaneHeaders)
            container.refreshAccessory()
        }
    }

    private var shouldShowDeviceDashboard: Bool {
        isDeviceDashboardGloballyVisible && deviceDashboard != nil && panes.count == 1 && kind != .multiExec
    }

    private func addDeviceDashboardIfNeeded(to container: NSView) {
        guard let deviceDashboard
        else { return }

        addChild(deviceDashboard)
        if let metricsDashboard = deviceDashboard as? DeviceMetricsDashboardViewController {
            metricsDashboard.metricsDidUpdate = { [weak self] in
                self?.layoutTerminalWorkspace()
            }
        }
        deviceDashboard.view.translatesAutoresizingMaskIntoConstraints = true
        deviceDashboard.view.autoresizingMask = []
        container.addSubview(deviceDashboard.view, positioned: .above, relativeTo: splitViewController.view)
    }

    private func updateTerminalReserveConstraints() {
        layoutTerminalWorkspace()
    }

    private func layoutTerminalWorkspace() {
        guard isViewLoaded else { return }

        let bounds = view.bounds
        switch layoutMode {
        case .single, .vertical, .horizontal:
            splitViewController.view.isHidden = false
            gridContainer.isHidden = true
            splitViewController.splitView.isVertical = layoutMode != .horizontal
            if splitViewController.view.frame != bounds {
                splitViewController.view.frame = bounds
            }
            applySinglePaneCollapseIfNeeded()
            if splitViewController.splitViewItems.count > 1 {
                let fraction = 1.0 / CGFloat(splitViewController.splitViewItems.count)
                let splitView = splitViewController.splitView
                let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
                let dividerTotal = splitView.dividerThickness * CGFloat(splitViewController.splitViewItems.count - 1)
                let equalExtent = max(0, (totalExtent - dividerTotal) * fraction)
                for item in splitViewController.splitViewItems {
                    item.preferredThicknessFraction = fraction
                    if equalExtent > 0 {
                        item.minimumThickness = equalExtent
                        item.maximumThickness = equalExtent
                    }
                }
            } else if let item = splitViewController.splitViewItems.first {
                item.minimumThickness = 0
                item.maximumThickness = 100_000
                item.preferredThicknessFraction = 1
            }
            splitViewController.portDeskRefreshPinnedSplitViewLayout()
            gridColumnCount = 0
            gridRowCount = 0
        case .grid:
            splitViewController.view.isHidden = true
            gridContainer.isHidden = false
            if gridContainer.frame != bounds {
                gridContainer.frame = bounds
            }
            layoutGridPanes(in: bounds)
        }

        guard let dashboardView = deviceDashboard?.view else { return }
        guard shouldShowDeviceDashboard else { return }
        let availableWidth = bounds.width - Self.dashboardTrailingInset * 2
        let availableHeight = bounds.height - Self.dashboardVerticalInset * 2
        guard availableWidth > 0, availableHeight > 0 else {
            dashboardView.isHidden = true
            dashboardView.frame = .zero
            return
        }
        dashboardView.isHidden = false
        let dashboardWidth = min(
            Self.dashboardPreferredWidth,
            availableWidth
        )
        let fittingHeight = (deviceDashboard as? DeviceMetricsDashboardViewController)?
            .preferredFloatingHeight(width: dashboardWidth)
            ?? dashboardView.fittingSize.height
        let floatingMaximumHeight = max(
            Self.dashboardMinimumHeight,
            floor(availableHeight * Self.dashboardMaximumHeightRatio)
        )
        let dashboardHeight = min(
            availableHeight,
            floatingMaximumHeight,
            max(Self.dashboardMinimumHeight, fittingHeight)
        )
        dashboardView.frame = NSRect(
            x: max(Self.dashboardTrailingInset, bounds.maxX - Self.dashboardTrailingInset - dashboardWidth),
            y: max(Self.dashboardVerticalInset, bounds.maxY - Self.dashboardVerticalInset - dashboardHeight),
            width: dashboardWidth,
            height: dashboardHeight
        )
    }


    private func layoutGridPanes(in bounds: NSRect) {
        let paneCount = panes.count
        guard paneCount > 0 else {
            gridColumnCount = 0
            gridRowCount = 0
            return
        }

        let columns = max(1, Int(ceil(sqrt(Double(paneCount)))))
        let rows = max(1, Int(ceil(Double(paneCount) / Double(columns))))
        gridColumnCount = columns
        gridRowCount = rows

        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        for (index, pane) in panes.enumerated() {
            guard let container = paneContainers[ObjectIdentifier(pane)],
                  container.view.superview === gridContainer
            else { continue }
            let row = index / columns
            let column = index % columns
            container.view.frame = NSRect(
                x: CGFloat(column) * cellWidth,
                y: bounds.height - CGFloat(row + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
        }
    }
}
