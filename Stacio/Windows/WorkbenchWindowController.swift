import AppKit
import StacioCoreBindings

public final class SidebarToggleTitlebarButton: NSButton {
    public var onPointerEntered: (() -> Void)?
    public var onPointerExited: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerExited?()
    }

    public func simulateTitlebarSidebarPointerEnteredForTesting() {
        onPointerEntered?()
    }

    public func simulateTitlebarSidebarPointerExitedForTesting() {
        onPointerExited?()
    }
}

public final class UpdatePromptTitlebarButton: NSButton {
    private var currentTitle = ""

    public func update(state: SparkleUpdateButtonState) {
        currentTitle = state.title
        toolTip = state.accessibilityLabel
        setAccessibilityLabel(state.accessibilityLabel)
        isHidden = state.isVisible == false
        let titleColor: NSColor
        let backgroundColor: NSColor
        switch state {
        case .failed:
            titleColor = .white
            backgroundColor = StacioDesignSystem.theme.dangerColor
        case .installing, .extracting, .downloading:
            titleColor = .white
            backgroundColor = StacioDesignSystem.theme.warningColor
        case .available:
            titleColor = .white
            backgroundColor = .controlAccentColor
        case .hidden:
            titleColor = .clear
            backgroundColor = .clear
        }
        attributedTitle = NSAttributedString(
            string: currentTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: titleColor
            ]
        )
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = backgroundColor.cgColor
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize {
        guard currentTitle.isEmpty == false else {
            return NSSize(width: 0, height: 24)
        }
        let width = ceil((currentTitle as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width) + 20
        return NSSize(width: max(48, width), height: 24)
    }
}

private final class WorkbenchRootView: NSView, StacioEffectiveAppearanceRefreshHandling {
    override var fittingSize: NSSize {
        bounds.size
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(constrainedContentSize(newSize))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stacioRefreshEffectiveAppearance()
    }

    func stacioRefreshEffectiveAppearance() {
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
    }

    private func constrainedContentSize(_ proposedSize: NSSize) -> NSSize {
        guard let window,
              window.contentView === self
        else {
            return proposedSize
        }

        let maximumWidth = window.contentRect(forFrameRect: window.frame).width
        return NSSize(width: min(proposedSize.width, maximumWidth), height: proposedSize.height)
    }
}

public protocol SavedSessionOpenRecording {
    @discardableResult
    func markSessionRecordOpened(databasePath: String, id: String) throws -> SessionRecord
}

extension WorkbenchWindowController: RunningTunnelReporting {
    public var runningTunnelCount: Int {
        guard let inspectorViewController else {
            return 0
        }
        _ = inspectorViewController.view
        return inspectorViewController.tunnelsViewController?.runningTunnelCount ?? 0
    }
}

@MainActor
public protocol AgentBridgeHandlerProviding {
    func makeAgentBridgeRequestHandler() -> AgentBridgeRequestHandling
}

extension WorkbenchWindowController: AgentBridgeHandlerProviding {
    public func makeAgentBridgeRequestHandler() -> AgentBridgeRequestHandling {
        makeAgentExecutionCoordinator(parentWindow: window)
    }
}

public struct CoreBridgeSavedSessionOpenRecorder: SavedSessionOpenRecording {
    public init() {}

    @discardableResult
    public func markSessionRecordOpened(databasePath: String, id: String) throws -> SessionRecord {
        try CoreBridge.markSessionRecordOpened(databasePath: databasePath, id: id)
    }
}

public protocol PlaintextProtocolSessionConfirming {
    @MainActor
    func confirmPlaintextProtocolSession(
        protocolName: String,
        message: String,
        parentWindow: NSWindow?
    ) -> Bool
}

public struct AppKitPlaintextProtocolSessionConfirmation: PlaintextProtocolSessionConfirming {
    public init() {}

    public func confirmPlaintextProtocolSession(
        protocolName: String,
        message: String,
        parentWindow: NSWindow?
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.Workbench.plaintextProtocolWarningTitle
        alert.informativeText = message
        alert.addButton(withTitle: L10n.Workbench.plaintextProtocolWarningContinue)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}

public enum WorkbenchSessionOpenError: Error, Equatable, LocalizedError {
    case protocolRuntimeUnavailable(String)
    case invalidSavedSessionPort(String, UInt32)
    case savedSessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .protocolRuntimeUnavailable(let sessionProtocol):
            return "当前 Stacio 尚未接入 \(sessionProtocol) 会话运行时。"
        case .invalidSavedSessionPort(let sessionProtocol, let port):
            return "\(sessionProtocol) 会话端口无效：\(port)。"
        case .savedSessionNotFound:
            return "找不到该保存会话。"
        }
    }
}

private struct SavedSerialSessionConfig: Decodable {
    let kind: String
    let devicePath: String
    let baudRate: UInt32?
    let dataBits: UInt8?
    let stopBits: UInt8?
    let parity: String?
    let flowControl: String?
    let backspaceMode: String?
}

@MainActor
private final class WorkbenchLicensedFeatureMenuDelegate: NSObject, NSMenuDelegate {
    weak var controller: WorkbenchWindowController?

    func menuWillOpen(_ menu: NSMenu) {
        controller?.refreshLicensedFeatureMenu(menu)
    }
}

@MainActor
public final class WorkbenchWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private static let defaultFrameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.v4")
    private static let legacyFrameAutosaveKeys = [
        "NSWindow Frame Stacio.WorkbenchWindow",
        "NSWindow Frame Stacio.WorkbenchWindow.v2",
        "NSWindow Frame Stacio.WorkbenchWindow.v3",
        "Stacio Managed Window Frame Stacio.WorkbenchWindow",
        "Stacio Managed Window Frame Stacio.WorkbenchWindow.v2",
        "Stacio Managed Window Frame Stacio.WorkbenchWindow.v3"
    ]

    private static func isRemoteHomeAliasPath(_ path: String) -> Bool {
        path == "~" || path.hasPrefix("~/")
    }

    public private(set) var contentSplitViewController = NSSplitViewController()
    public let workspaceViewController: WorkspaceViewController
    public let tunnelLiveSessionStore: TunnelLiveSessionStore
    private let tunnelLiveSessionContextProvider: () -> TunnelLiveSessionContext?
    private let tunnelLiveBridge: LiveTunnelCoreBridging
    private let remoteFilesBridge: RemoteFilesBridging
    private let licenseAccess: any LicenseFeatureAccessProviding
    private var remoteSessionStarter: RemoteSSHSessionStarting?
    private var telnetSessionStarter: TelnetSessionStarting?
    private var systemAppearanceObserver: NSObjectProtocol?
    private var licenseAuthorizationObserver: NSObjectProtocol?
    private let licensedFeatureMenuDelegate = WorkbenchLicensedFeatureMenuDelegate()
    private var serialSessionStarter: SerialSessionStarting?
    private var savedSessionContextBuilder: TunnelLiveSessionContextBuilding?
    private var ftpCredentialResolver: FTPCredentialResolving?
    private let quickConnectPromptPresenter: QuickConnectPromptPresenting
    private let quickConnectErrorPresenter: QuickConnectErrorPresenting
    private let multiExecPromptPresenter: MultiExecPromptPresenting
    private let multiExecSessionSelector: MultiExecSessionSelecting
    private let multiExecBridge: MultiExecPreparing
    private let multiExecAuditRecorder: MultiExecAuditRecording
    private let terminalCloseConfirmation: TerminalCloseConfirming
    private let plaintextProtocolSessionConfirmation: PlaintextProtocolSessionConfirming
    private var quickConnectCoordinator: QuickConnectCoordinator?
    private var sessionImportCoordinator: SessionImportCoordinating?
    private let sessionImportErrorPresenter: SessionImportErrorPresenting
    private weak var sessionSidebarViewController: SessionSidebarViewController?
    private var inspectorViewController: InspectorViewController?
    private let savedSessionOpenRecorder: SavedSessionOpenRecording
    private let savedSessionCredentialPromptPresenter: SavedSessionCredentialPrompting
    private let savedSessionCredentialSaver: SessionSidebarCredentialSaving?
    private let quickConnectCredentialSaver: (SessionSidebarCredentialSaving & SessionSidebarCredentialCleaning)?
    private let graphicsCredentialStore: KeychainCredentialStore
    private let aiAPIKeyStore: AIApiKeyStoring
    private let aiHTTPTransport: AIAssistantHTTPTransport
    private let aiLocalAgentToolResolver: LocalAgentToolResolving
    private let aiLocalAgentProcessLauncherFactory: () -> LocalTerminalProcessLaunching
    private let databasePathProvider: () throws -> String
    private let transferHistoryStore: SCPTransferHistoryStoring?
    private let transferQueueCoordinatorFactory: ((TransferQueueViewController) -> TransferQueueCoordinator)?
    private let settingsStore: AppSettingsStore
    private let agentActionConfirmer: AgentActionConfirming
    private let graphicsAdapterPathProvider: (String) -> String?
    private let graphicsRuntimeManager: GraphicsRuntimeManaging
    private let sparkleUpdateController: SparkleUpdateButtonControlling?
    private let frameAutosaveName: NSWindow.FrameAutosaveName
    private weak var sidebarSplitViewItem: NSSplitViewItem?
    private weak var inspectorSplitViewItem: NSSplitViewItem?
    private weak var updatePromptToolbarItem: NSToolbarItem?
    private weak var updatePromptButton: UpdatePromptTitlebarButton?
    private var updatePromptWidthConstraint: NSLayoutConstraint?
    private var workbenchContentWidthStayConstraint: NSLayoutConstraint?
    private var workbenchContentHeightStayConstraint: NSLayoutConstraint?
    private var isSystemZoomingWindow = false
    private var aiAssistantOverlayViewController: AIAssistantPanelViewController?
    private var agentExecutionCoordinator: AgentExecutionCoordinator?
    private var splitResizeObserver: NSObjectProtocol?
    private var isMultiExecBroadcasting = false
    private var isUserLiveResizingWindow = false
    private var isRestoringWindowFrame = false
    private var didFinishInitialWindowPlacement = false
    private var didApplyInitialSplitColumnWidths = false
    private var programmaticSplitLayoutDepth = 0
    private var splitWidthPersistenceSuppressionDepth = 0
    private var splitPositionOverrideDepth = 0
    private var pendingInspectorWidth: CGFloat?
    private var preservedInspectorWidthDuringSidebarMove: CGFloat?
    private var isPendingInspectorWidthRepairScheduled = false
    private var allowsUserSplitWidthPersistence = false
    private var isSidebarTemporarilyExpanded = false
    private var pendingProgrammaticWindowFrameRestore: NSRect?
    private var rootContentViewController: NSViewController?
    private let minimumReadableSidebarWidth: CGFloat = 220
    private let minimumWorkspaceWidthWhenOpeningInspector: CGFloat = 248
    private let defaultInspectorPanelWidth: CGFloat = 320
    private let minimumInspectorWidthBeforeDeferredUncollapse: CGFloat = 420
    private let preferredFilesCapabilityInspectorWidth: CGFloat = 960
    private let unrestrictedInspectorPanelWidth: CGFloat = 100_000

    private enum ToolbarItem {
        static let sidebar = NSToolbarItem.Identifier("Stacio.Toolbar.sidebar")
        static let quickConnect = NSToolbarItem.Identifier("Stacio.Toolbar.quickConnect")
        static let newSession = NSToolbarItem.Identifier("Stacio.Toolbar.newSession")
        static let importSessions = NSToolbarItem.Identifier("Stacio.Toolbar.importSessions")
        static let split = NSToolbarItem.Identifier("Stacio.Toolbar.split")
        static let closeTerminal = NSToolbarItem.Identifier("Stacio.Toolbar.closeTerminal")
        static let multiExec = NSToolbarItem.Identifier("Stacio.Toolbar.multiExec")
        static let panels = NSToolbarItem.Identifier("Stacio.Toolbar.panels")
        static let files = NSToolbarItem.Identifier("Stacio.Toolbar.files")
        static let browser = NSToolbarItem.Identifier("Stacio.Toolbar.browser")
        static let tunnels = NSToolbarItem.Identifier("Stacio.Toolbar.tunnels")
        static let deviceDashboard = NSToolbarItem.Identifier("Stacio.Toolbar.deviceDashboard")
        static let aiAssistant = NSToolbarItem.Identifier("Stacio.Toolbar.aiAssistant")
        static let inspector = NSToolbarItem.Identifier("Stacio.Toolbar.inspector")
        static let updatePrompt = NSToolbarItem.Identifier("Stacio.Toolbar.updatePrompt")
    }

    public convenience init() {
        self.init(workspaceViewController: WorkspaceViewController())
    }

    public convenience init(
        workspaceViewController: WorkspaceViewController,
        tunnelLiveSessionStore: TunnelLiveSessionStore,
        tunnelLiveBridge: LiveTunnelCoreBridging = CoreLiveTunnelBridge()
    ) {
        self.init(
            workspaceViewController: workspaceViewController,
            tunnelLiveSessionStore: tunnelLiveSessionStore,
            tunnelLiveSessionContextProvider: { tunnelLiveSessionStore.current() },
            tunnelLiveBridge: tunnelLiveBridge
        )
    }

    public init(
        workspaceViewController: WorkspaceViewController,
        tunnelLiveSessionStore: TunnelLiveSessionStore = TunnelLiveSessionStore(),
        tunnelLiveSessionContextProvider: (() -> TunnelLiveSessionContext?)? = nil,
        tunnelLiveBridge: LiveTunnelCoreBridging = CoreLiveTunnelBridge(),
        remoteFilesBridge: RemoteFilesBridging = CoreBridgeRemoteFilesBridge(),
        licenseAccess: any LicenseFeatureAccessProviding = UnrestrictedLicenseFeatureAccessProvider(),
        remoteSessionStarter: RemoteSSHSessionStarting? = nil,
        telnetSessionStarter: TelnetSessionStarting? = nil,
        serialSessionStarter: SerialSessionStarting? = nil,
        savedSessionContextBuilder: TunnelLiveSessionContextBuilding? = nil,
        ftpCredentialResolver: FTPCredentialResolving? = nil,
        quickConnectPromptPresenter: QuickConnectPromptPresenting = AppKitQuickConnectPromptPresenter(),
        quickConnectErrorPresenter: QuickConnectErrorPresenting? = nil,
        multiExecPromptPresenter: MultiExecPromptPresenting = AppKitMultiExecPromptPresenter(),
        multiExecSessionSelector: MultiExecSessionSelecting = AppKitMultiExecSessionSelector(),
        multiExecBridge: MultiExecPreparing = CoreBridgeMultiExecBridge(),
        multiExecAuditRecorder: MultiExecAuditRecording = CoreBridgeMultiExecAuditRecorder(),
        terminalCloseConfirmation: TerminalCloseConfirming = AppKitTerminalCloseConfirmation(),
        plaintextProtocolSessionConfirmation: PlaintextProtocolSessionConfirming = AppKitPlaintextProtocolSessionConfirmation(),
        settingsStore: AppSettingsStore = .shared,
        agentActionConfirmer: AgentActionConfirming? = nil,
        sessionImportCoordinator: SessionImportCoordinating? = nil,
        sessionImportErrorPresenter: SessionImportErrorPresenting? = nil,
        savedSessionOpenRecorder: SavedSessionOpenRecording = CoreBridgeSavedSessionOpenRecorder(),
        savedSessionCredentialPromptPresenter: SavedSessionCredentialPrompting? = nil,
        savedSessionCredentialSaver: SessionSidebarCredentialSaving? = nil,
        quickConnectCredentialSaver: (SessionSidebarCredentialSaving & SessionSidebarCredentialCleaning)? = nil,
        graphicsCredentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        aiAPIKeyStore: AIApiKeyStoring = KeychainAIApiKeyStore(),
        aiHTTPTransport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(),
        aiLocalAgentToolResolver: LocalAgentToolResolving = LocalAgentToolResolver(),
        aiLocalAgentProcessLauncherFactory: @escaping () -> LocalTerminalProcessLaunching = {
            SwiftTermLocalTerminalProcessLauncher()
        },
        databasePathProvider: @escaping () throws -> String = { try StacioPaths().databaseURL.path },
        transferHistoryStore: SCPTransferHistoryStoring? = nil,
        transferQueueCoordinatorFactory: ((TransferQueueViewController) -> TransferQueueCoordinator)? = nil,
        graphicsRuntimeManager: GraphicsRuntimeManaging = DefaultGraphicsRuntimeManager(),
        sparkleUpdateController: SparkleUpdateButtonControlling? = nil,
        graphicsAdapterPathProvider: @escaping (String) -> String? = { protocolName in
            let adapterURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Adapters", isDirectory: true)
                .appendingPathComponent(protocolName.lowercased(), isDirectory: false)
            return FileManager.default.isExecutableFile(atPath: adapterURL.path) ? adapterURL.path : nil
        },
        frameAutosaveName: NSWindow.FrameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.v4")
    ) {
        self.workspaceViewController = workspaceViewController
        self.tunnelLiveSessionStore = tunnelLiveSessionStore
        self.tunnelLiveSessionContextProvider = tunnelLiveSessionContextProvider
            ?? { [weak workspaceViewController, tunnelLiveSessionStore] in
                if let workspaceViewController {
                    if let context = workspaceViewController.currentRemoteTerminalLiveSessionContext {
                        return context
                    }
                    if workspaceViewController.currentPaneOwnsRemoteSessionContext {
                        return nil
                    }
                }
                return tunnelLiveSessionStore.current()
            }
        self.tunnelLiveBridge = tunnelLiveBridge
        self.remoteFilesBridge = remoteFilesBridge
        self.licenseAccess = licenseAccess
        self.remoteSessionStarter = remoteSessionStarter
        self.telnetSessionStarter = telnetSessionStarter
        self.serialSessionStarter = serialSessionStarter
        self.savedSessionContextBuilder = savedSessionContextBuilder
        self.ftpCredentialResolver = ftpCredentialResolver
        self.quickConnectPromptPresenter = quickConnectPromptPresenter
        self.quickConnectErrorPresenter = quickConnectErrorPresenter ?? AppKitQuickConnectErrorPresenter()
        self.multiExecPromptPresenter = multiExecPromptPresenter
        self.multiExecSessionSelector = multiExecSessionSelector
        self.multiExecBridge = multiExecBridge
        self.multiExecAuditRecorder = multiExecAuditRecorder
        self.terminalCloseConfirmation = terminalCloseConfirmation
        self.plaintextProtocolSessionConfirmation = plaintextProtocolSessionConfirmation
        self.sessionImportCoordinator = sessionImportCoordinator
        self.sessionImportErrorPresenter = sessionImportErrorPresenter ?? AppKitSessionImportErrorPresenter()
        self.savedSessionOpenRecorder = savedSessionOpenRecorder
        self.savedSessionCredentialPromptPresenter = savedSessionCredentialPromptPresenter
            ?? AppKitSavedSessionCredentialPromptPresenter()
        self.savedSessionCredentialSaver = savedSessionCredentialSaver
        self.quickConnectCredentialSaver = quickConnectCredentialSaver
        self.graphicsCredentialStore = graphicsCredentialStore
        self.aiAPIKeyStore = aiAPIKeyStore
        self.aiHTTPTransport = aiHTTPTransport
        self.aiLocalAgentToolResolver = aiLocalAgentToolResolver
        self.aiLocalAgentProcessLauncherFactory = aiLocalAgentProcessLauncherFactory
        self.databasePathProvider = databasePathProvider
        self.transferHistoryStore = transferHistoryStore
        self.transferQueueCoordinatorFactory = transferQueueCoordinatorFactory
        self.settingsStore = settingsStore
        self.agentActionConfirmer = agentActionConfirmer ?? AppKitAgentActionConfirmer()
        self.graphicsRuntimeManager = graphicsRuntimeManager
        self.sparkleUpdateController = sparkleUpdateController
        self.graphicsAdapterPathProvider = graphicsAdapterPathProvider
        self.frameAutosaveName = frameAutosaveName
        super.init(window: nil)
        licensedFeatureMenuDelegate.controller = self
        licenseAuthorizationObserver = NotificationCenter.default.addObserver(
            forName: .stacioLicenseAuthorizationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLicensedToolbarItems()
            }
        }
        workspaceViewController.onRequestNewSession = { [weak self] in
            self?.performNewSessionFromToolbar(nil)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let splitResizeObserver {
            NotificationCenter.default.removeObserver(splitResizeObserver)
        }
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
        }
        if let licenseAuthorizationObserver {
            NotificationCenter.default.removeObserver(licenseAuthorizationObserver)
        }
    }

    public override func showWindow(_ sender: Any?) {
        if window == nil {
            loadWindow()
        }
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window
            else { return }
            self.updateInspectorToolbarTopInset(in: window)
            self.layoutWorkbenchContent(in: window)
            self.allowsUserSplitWidthPersistence = true
            if self.workspaceViewController.currentTerminalPane == nil {
                window.makeFirstResponder(window.contentView)
            } else {
                self.workspaceViewController.focusCurrentTerminalForKeyboardInput()
            }
        }
    }

    public override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stacio"
        window.minSize = NSSize(width: 1, height: 1)
        window.contentMinSize = NSSize(width: 0, height: 0)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.isRestorable = false
        removeLegacyAutosavedFramesIfNeeded()
        StacioDesignSystem.applyWindowChrome(window)
        window.delegate = self
        if restoreWorkbenchWindowFrame(window) == false {
            window.center()
        }
        let toolbar = makeToolbar()
        window.toolbar = toolbar
        toolbar.displayMode = .iconOnly

        contentSplitViewController = makeSplitViewController()
        let rootController = NSViewController()
        let rootView = WorkbenchRootView(
            frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        )
        window.contentView = rootView
        installWorkbenchContentSizeStayConstraints(on: rootView)
        StacioDesignSystem.applyRootSurface(rootView)

        let splitView = contentSplitViewController.view
        contentSplitViewController.portDeskPinSplitViewToContainerEdges()
        splitView.frame = rootView.bounds
        splitView.autoresizingMask = [.width, .height]
        rootView.addSubview(splitView)
        rootController.addChild(contentSplitViewController)
        rootController.view = rootView
        rootContentViewController = rootController

        window.initialFirstResponder = rootView
        didFinishInitialWindowPlacement = true
        allowsUserSplitWidthPersistence = false
        self.window = window
        installSystemAppearanceObserverIfNeeded()
        bindUpdatePromptControllerIfNeeded()
        sparkleUpdateController?.probeForAvailableUpdate()
        refreshWorkbenchAppearance()
        refreshLicensedToolbarItems()
        updateInspectorToolbarTopInset(in: window)
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if let preservedFrame = pendingProgrammaticWindowFrameRestore,
           isRestoringWindowFrame == false,
           isUserLiveResizingWindow == false
        {
            return preservedFrame.size
        }
        if isUserLiveResizingWindow {
            updateWorkbenchContentSizeStayConstraints(forFrameSize: frameSize, in: sender)
        }
        return frameSize
    }

    public func windowWillStartLiveResize(_ notification: Notification) {
        pendingProgrammaticWindowFrameRestore = nil
        isUserLiveResizingWindow = true
    }

    public func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        prepareWorkbenchContentSizeForSystemResize(toFrameSize: newFrame.size, in: window)
        updateWorkbenchContentSizeStayConstraints(forFrameSize: newFrame.size, in: window)
        return true
    }

    public func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return newFrame
        }

        let standardFrame = clampedRestoredWindowFrame(visibleFrame, for: window, limitsSizeToVisibleFrame: true)
        prepareWorkbenchContentSizeForSystemResize(toFrameSize: standardFrame.size, in: window)
        updateWorkbenchContentSizeStayConstraints(forFrameSize: standardFrame.size, in: window)
        return standardFrame
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        isUserLiveResizingWindow = false
        if let window = notification.object as? NSWindow {
            layoutWorkbenchContent(in: window)
            saveWorkbenchWindowFrame(window)
        }
    }

    public func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isRestoringWindowFrame == false,
              isUserLiveResizingWindow == false
        else { return }

        saveWorkbenchWindowFrame(window)
    }

    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isRestoringWindowFrame == false
        else { return }

        updateWorkbenchContentSizeStayConstraints(forFrameSize: window.frame.size, in: window)
        layoutWorkbenchContent(in: window)
        finishWorkbenchSystemResizeIfNeeded()
    }

    private func removeLegacyAutosavedFramesIfNeeded() {
        guard frameAutosaveName == Self.defaultFrameAutosaveName else { return }

        let defaults = UserDefaults.standard
        for key in Self.legacyFrameAutosaveKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private var frameDefaultsKey: String {
        "NSWindow Frame \(frameAutosaveName)"
    }

    private func restoreWorkbenchWindowFrame(_ window: NSWindow) -> Bool {
        guard let storedFrame = workbenchWindowFrameFromDefaults() else {
            return false
        }

        let frame = clampedRestoredWindowFrame(storedFrame, for: window, limitsSizeToVisibleFrame: true)
        isRestoringWindowFrame = true
        window.setFrame(frame, display: false)
        isRestoringWindowFrame = false
        if frame.equalTo(storedFrame) == false {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameDefaultsKey)
        }
        layoutWorkbenchContent(in: window)
        return true
    }

    private func workbenchWindowFrameFromDefaults() -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: frameDefaultsKey) else {
            return nil
        }

        let frame = NSRectFromString(value)
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0
        else {
            UserDefaults.standard.removeObject(forKey: frameDefaultsKey)
            return nil
        }

        return frame
    }

    private func saveWorkbenchWindowFrame(_ window: NSWindow?) {
        guard let window,
              didFinishInitialWindowPlacement,
              isRestoringWindowFrame == false
        else { return }

        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameDefaultsKey)
    }

    private func layoutWorkbenchContent(in window: NSWindow?) {
        guard let window,
              let contentView = window.contentView
        else { return }

        updateInspectorToolbarTopInset(in: window)
        let bounds = contentView.bounds
        contentSplitViewController.view.frame = bounds
        contentSplitViewController.portDeskRefreshPinnedSplitViewLayout()
        contentSplitViewController.view.layoutSubtreeIfNeeded()
        applyInitialSplitColumnWidthsIfNeeded(in: window)
    }

    private func installWorkbenchContentSizeStayConstraints(on contentView: NSView) {
        let widthConstraint = contentView.widthAnchor.constraint(
            equalToConstant: contentView.bounds.width
        )
        widthConstraint.priority = NSLayoutConstraint.Priority(999)
        widthConstraint.identifier = "Stacio.Workbench.contentWidthStay"
        let heightConstraint = contentView.heightAnchor.constraint(
            equalToConstant: contentView.bounds.height
        )
        heightConstraint.priority = NSLayoutConstraint.Priority(999)
        heightConstraint.identifier = "Stacio.Workbench.contentHeightStay"
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        workbenchContentWidthStayConstraint = widthConstraint
        workbenchContentHeightStayConstraint = heightConstraint
    }

    private func updateWorkbenchContentSizeStayConstraints(
        forFrameSize frameSize: NSSize,
        in window: NSWindow
    ) {
        let contentSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize)
        ).size
        workbenchContentWidthStayConstraint?.constant = max(1, contentSize.width)
        workbenchContentHeightStayConstraint?.constant = max(1, contentSize.height)
    }

    private func prepareWorkbenchContentSizeForSystemResize(
        toFrameSize frameSize: NSSize,
        in window: NSWindow
    ) {
        guard isUserLiveResizingWindow == false else { return }
        isSystemZoomingWindow = true
        workbenchContentWidthStayConstraint?.priority = .defaultLow
        workbenchContentHeightStayConstraint?.priority = .defaultLow
        updateWorkbenchContentSizeStayConstraints(forFrameSize: frameSize, in: window)
    }

    private func finishWorkbenchSystemResizeIfNeeded() {
        guard isSystemZoomingWindow else { return }
        workbenchContentWidthStayConstraint?.priority = NSLayoutConstraint.Priority(999)
        workbenchContentHeightStayConstraint?.priority = NSLayoutConstraint.Priority(999)
        isSystemZoomingWindow = false
    }

    private func applyInitialSplitColumnWidthsIfNeeded(in window: NSWindow?) {
        guard didApplyInitialSplitColumnWidths == false,
              let window,
              let contentView = window.contentView,
        contentSplitViewController.splitViewItems.count >= 2
        else { return }

        let availableWidth = contentView.bounds.width
        guard availableWidth >= 640 else { return }

        let sidebarWidth = storedSplitWidth(column: "sidebar")
            .map { clampedSidebarWidth($0, availableWidth: availableWidth) }
            ?? min(260, max(minimumReadableSidebarWidth, availableWidth * 0.20))
        let splitView = contentSplitViewController.splitView
        performProgrammaticSplitLayout {
            splitView.setPosition(
                sidebarWidth,
                ofDividerAt: 0
            )
            splitView.layoutSubtreeIfNeeded()
        }
        didApplyInitialSplitColumnWidths = true
    }

    private func toolbarTopInset(in window: NSWindow?) -> CGFloat {
        guard let window,
              let contentView = window.contentView
        else {
            return 0
        }

        let contentLayoutFrame = contentView.convert(window.contentLayoutRect, from: nil)
        return max(0, contentView.bounds.maxY - contentLayoutFrame.maxY)
    }

    private func updateInspectorToolbarTopInset(in window: NSWindow?) {
        inspectorViewController?.setToolbarTopInset(toolbarTopInset(in: window))
    }

    private func shouldRefreshRemoteFilesDirectory(remotePath: String) -> Bool {
        inspectorSplitViewItem?.isCollapsed == false || Self.isRemoteHomeAliasPath(remotePath) == false
    }

    private func keepSidebarReadableWithoutResizingWindow() {
        let windowFrame = programmaticWindowFrameForLayout()
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        guard contentSplitViewController.splitViewItems.count >= 2 else { return }

        let splitView = contentSplitViewController.splitView
        let subviews = splitView.arrangedSubviews
        guard let sidebarView = subviews.first,
              sidebarView.isHidden == false,
              splitView.bounds.width >= minimumReadableSidebarWidth + 320,
              sidebarView.frame.width < minimumReadableSidebarWidth
        else { return }

        performProgrammaticSplitLayout {
            splitView.setPosition(minimumReadableSidebarWidth, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }
    }

    private func restoreStoredSidebarWidthIfNeeded(in splitView: NSSplitView) {
        guard let storedSidebarWidth = storedSplitWidth(column: "sidebar"),
              splitView.arrangedSubviews.count >= 3
        else { return }

        let targetSidebarWidth = clampedSidebarWidth(
            storedSidebarWidth,
            availableWidth: splitView.bounds.width
        )
        let sidebarView = splitView.arrangedSubviews[0]
        guard sidebarView.isHidden == false,
              abs(sidebarView.frame.width - targetSidebarWidth) > 1
        else { return }

        performProgrammaticSplitLayout {
            splitView.setPosition(targetSidebarWidth, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }
    }

    private func constrainWorkbenchSplitPosition(
        _ splitView: NSSplitView,
        proposedPosition: CGFloat,
        dividerIndex: Int
    ) -> CGFloat {
        guard splitView === contentSplitViewController.splitView,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else {
            return proposedPosition
        }

        let dividerThickness = splitView.dividerThickness
        if dividerIndex == 0 {
            preserveInspectorWidthWhileMovingSidebar(
                in: splitView,
                proposedSidebarWidth: proposedPosition,
                dividerThickness: dividerThickness
            )
            return proposedPosition
        }

        guard dividerIndex == 1 else {
            return proposedPosition
        }

        let subviews = splitView.arrangedSubviews
        let sidebarWidth = subviews.first?.isHidden == false ? subviews.first?.frame.width ?? 0 : 0
        let lowerBound = sidebarWidth + dividerThickness
        let upperBound = max(lowerBound, splitView.bounds.width - dividerThickness)
        if let preservedInspectorWidthDuringSidebarMove {
            let targetWidth = clampedInspectorWidth(
                preservedInspectorWidthDuringSidebarMove,
                splitWidth: splitView.bounds.width
            )
            let preservingPosition = splitView.bounds.width - targetWidth - dividerThickness
            let constrainedPosition = min(max(preservingPosition, lowerBound), upperBound)
            pendingInspectorWidth = max(0, splitView.bounds.width - constrainedPosition - dividerThickness)
            updatePreferredInspectorFraction(pendingInspectorWidth ?? 0, splitWidth: splitView.bounds.width)
            return constrainedPosition
        }
        let constrainedPosition = min(max(proposedPosition, lowerBound), upperBound)
        if splitPositionOverrideDepth == 0 {
            pendingInspectorWidth = max(0, splitView.bounds.width - constrainedPosition - dividerThickness)
            updatePreferredInspectorFraction(pendingInspectorWidth ?? 0, splitWidth: splitView.bounds.width)
            applyWorkbenchSplitFrames(
                forDividerOnePosition: constrainedPosition,
                in: splitView,
                pinsInspectorWidthDuringLayout: true
            )
            saveSplitColumnWidthsIfNeeded()
        }
        return constrainedPosition
    }

    private func preserveInspectorWidthWhileMovingSidebar(
        in splitView: NSSplitView,
        proposedSidebarWidth: CGFloat,
        dividerThickness: CGFloat
    ) {
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              splitView.bounds.width > 0
        else { return }

        let currentInspectorWidth = subviews[2].frame.width
        let candidateInspectorWidth = max(
            preservedInspectorWidthDuringSidebarMove ?? 0,
            pendingInspectorWidth ?? 0,
            currentInspectorWidth
        )
        guard candidateInspectorWidth > 0 else { return }

        let maximumPreservableInspectorWidth = splitView.bounds.width
            - proposedSidebarWidth
            - dividerThickness * 2
        let inspectorWidth = min(max(candidateInspectorWidth, 0), max(0, maximumPreservableInspectorWidth))
        guard inspectorWidth > 0 else { return }

        pendingInspectorWidth = inspectorWidth
        updatePreferredInspectorFraction(inspectorWidth, splitWidth: splitView.bounds.width)
    }

    private func prepareWorkbenchSplitPosition(
        _ splitView: NSSplitView,
        position: CGFloat,
        dividerIndex: Int
    ) {
        guard splitView === contentSplitViewController.splitView,
              splitPositionOverrideDepth == 0,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        if dividerIndex == 0 {
            let subviews = splitView.arrangedSubviews
            guard subviews.count >= 3,
                  subviews[2].isHidden == false
            else { return }

            let inspectorWidth = subviews[2].frame.width
            if inspectorWidth > 0 {
                preservedInspectorWidthDuringSidebarMove = inspectorWidth
                pendingInspectorWidth = inspectorWidth
            }
            return
        }

        guard dividerIndex == 1 else { return }

        inspectorSplitViewItem?.minimumThickness = 0
    }

    private func finishWorkbenchSplitPosition(
        _ splitView: NSSplitView,
        position: CGFloat,
        dividerIndex: Int
    ) {
        guard splitPositionOverrideDepth == 0,
              splitView === contentSplitViewController.splitView,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        if dividerIndex == 0 {
            if let preservedInspectorWidthDuringSidebarMove {
                pendingInspectorWidth = preservedInspectorWidthDuringSidebarMove
            }
            applyPendingInspectorWidthIfNeeded()
            preservedInspectorWidthDuringSidebarMove = nil
            saveSplitColumnWidthsIfNeeded()
            return
        }

        guard dividerIndex == 1 else { return }

        let constrainedPosition = constrainWorkbenchSplitPosition(
            splitView,
            proposedPosition: position,
            dividerIndex: dividerIndex
        )
        pendingInspectorWidth = max(0, splitView.bounds.width - constrainedPosition - splitView.dividerThickness)
        applyWorkbenchSplitFrames(
            forDividerOnePosition: constrainedPosition,
            in: splitView,
            pinsInspectorWidthDuringLayout: true
        )
    }

    private func applyDefaultInspectorWidthIfNeeded(
        force: Bool = false,
        preferredDefaultWidth: CGFloat? = nil
    ) {
        let windowFrame = programmaticWindowFrameForLayout()
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        guard contentSplitViewController.splitViewItems.count >= 3,
              let inspectorSplitViewItem,
              inspectorSplitViewItem.isCollapsed == false
        else { return }

        let splitView = contentSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              let inspectorView = subviews.last,
              inspectorView.isHidden == false
        else { return }

        let storedInspectorWidth = storedSplitWidth(column: "inspector")
        let storedSidebarWidth = storedSplitWidth(column: "sidebar")
        let pinnedSidebarWidth = storedSidebarWidth
            .map { clampedSidebarWidth($0, availableWidth: splitView.bounds.width) }
            ?? currentSidebarWidthForInspectorSizing(splitWidth: splitView.bounds.width)
        let maximumInspectorWidth = max(
            0,
            splitView.bounds.width
                - pinnedSidebarWidth
                - minimumWorkspaceWidthWhenOpeningInspector
                - splitView.dividerThickness * 2
        )
        let configuredDefaultWidth = defaultInspectorWidth(
            for: splitView.bounds.width,
            preferredWidth: preferredDefaultWidth ?? defaultInspectorPanelWidth
        )
        let defaultWidth = min(
            pendingDefaultInspectorWidth(
                splitWidth: splitView.bounds.width,
                fallback: configuredDefaultWidth
            ),
            maximumInspectorWidth
        )
        // A width captured during the current layout session represents the
        // user's active panel state (including an expanded files editor). It
        // must win over a stale persisted width from an earlier, narrower
        // panel state. Use persisted width only for a fresh layout without a
        // pending runtime width.
        let requestedWidth: CGFloat
        if let pendingInspectorWidth,
           pendingInspectorWidth > 0
        {
            requestedWidth = clampedInspectorWidth(
                pendingInspectorWidth,
                splitWidth: splitView.bounds.width
            )
        } else {
            requestedWidth = targetInspectorWidth(
                storedWidth: storedInspectorWidth,
                defaultWidth: defaultWidth,
                splitWidth: splitView.bounds.width
            )
        }
        let targetWidth = min(requestedWidth, maximumInspectorWidth)
        guard targetWidth > 0 else {
            inspectorSplitViewItem.holdingPriority = .defaultHigh
            return
        }

        inspectorSplitViewItem.holdingPriority = .defaultLow
        guard
              storedInspectorWidth != nil
              || force
              || pendingInspectorWidth == nil
              || inspectorView.frame.width < targetWidth * 0.75
        else { return }

        updatePreferredInspectorFraction(targetWidth, splitWidth: splitView.bounds.width)
        pendingInspectorWidth = targetWidth
        performProgrammaticSplitLayout {
            applyInspectorWidth(
                targetWidth,
                in: splitView,
                preservingWindowFrame: windowFrame,
                pinsInspectorWidthDuringLayout: true,
                pinnedSidebarWidth: pinnedSidebarWidth
            )
            if let storedSidebarWidth {
                splitView.setPosition(
                    clampedSidebarWidth(storedSidebarWidth, availableWidth: splitView.bounds.width),
                    ofDividerAt: 0
                )
            }
            splitView.layoutSubtreeIfNeeded()
        }
        inspectorSplitViewItem.holdingPriority = .defaultHigh
        restoreStoredSidebarWidthIfNeeded(in: splitView)
    }

    private func defaultInspectorWidth(for splitWidth: CGFloat, preferredWidth: CGFloat) -> CGFloat {
        let availableWidth = splitWidth
            - currentSidebarWidthForInspectorSizing(splitWidth: splitWidth)
            - minimumWorkspaceWidthWhenOpeningInspector
            - contentSplitViewController.splitView.dividerThickness * 2
        guard availableWidth > 0 else {
            return 0
        }
        return min(preferredWidth, availableWidth)
    }

    private func pendingDefaultInspectorWidth(splitWidth: CGFloat, fallback: CGFloat) -> CGFloat {
        guard let pendingInspectorWidth else {
            return fallback
        }
        let clampedPendingWidth = clampedInspectorWidth(pendingInspectorWidth, splitWidth: splitWidth)
        return clampedPendingWidth > 0 ? clampedPendingWidth : fallback
    }

    private func clampedSidebarWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximum = min(sidebarSplitViewItem?.maximumThickness ?? 320, max(minimumReadableSidebarWidth, availableWidth - 320))
        return min(max(width, minimumReadableSidebarWidth), maximum)
    }

    private func clampedInspectorWidth(_ width: CGFloat, splitWidth: CGFloat) -> CGFloat {
        let availableWidth = splitWidth
            - currentSidebarWidthForInspectorSizing(splitWidth: splitWidth)
            - contentSplitViewController.splitView.dividerThickness * 2
        guard availableWidth > 0 else {
            return 0
        }
        return min(max(width, 0), availableWidth)
    }

    private func currentSidebarWidthForInspectorSizing(splitWidth: CGFloat) -> CGFloat {
        let splitView = contentSplitViewController.splitView
        let subviews = splitView.arrangedSubviews
        if let sidebarView = subviews.first,
           sidebarView.isHidden == false,
           sidebarView.frame.width > 0
        {
            let maximumSidebarWidth = sidebarSplitViewItem?.maximumThickness ?? 320
            return min(max(sidebarView.frame.width, minimumReadableSidebarWidth), maximumSidebarWidth)
        }
        return min(minimumReadableSidebarWidth, splitWidth)
    }

    private func targetInspectorWidth(
        storedWidth: CGFloat?,
        defaultWidth: CGFloat,
        splitWidth: CGFloat
    ) -> CGFloat {
        guard let storedWidth else {
            return defaultWidth
        }

        let clampedStoredWidth = clampedInspectorWidth(storedWidth, splitWidth: splitWidth)
        guard clampedStoredWidth > 0 else {
            return defaultWidth
        }

        return clampedStoredWidth
    }

    private func updatePreferredInspectorFraction(_ width: CGFloat, splitWidth: CGFloat) {
        guard splitWidth > 0,
              width > 0
        else { return }

        inspectorSplitViewItem?.preferredThicknessFraction = min(max(width / splitWidth, 0.1), 0.9)
    }

    private func compactInspectorMinimumThickness(for splitView: NSSplitView) -> CGFloat {
        0
    }

    private func applyInspectorWidth(
        _ width: CGFloat,
        in splitView: NSSplitView,
        preservingWindowFrame preservedWindowFrame: NSRect? = nil,
        pinsInspectorWidthDuringLayout: Bool = true,
        pinnedSidebarWidth: CGFloat? = nil
    ) {
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              width > 0
        else { return }

        let dividerThickness = splitView.dividerThickness
        let dividerPosition = splitView.bounds.width - width - dividerThickness
        pendingInspectorWidth = width
        applyWorkbenchSplitFrames(
            forDividerOnePosition: dividerPosition,
            in: splitView,
            preservingWindowFrame: preservedWindowFrame,
            pinsInspectorWidthDuringLayout: pinsInspectorWidthDuringLayout,
            pinnedSidebarWidth: pinnedSidebarWidth
        )
    }

    private func applyWorkbenchSplitFrames(
        forDividerOnePosition dividerPosition: CGFloat,
        in splitView: NSSplitView,
        preservingWindowFrame preservedWindowFrame: NSRect? = nil,
        pinsInspectorWidthDuringLayout: Bool = true,
        pinnedSidebarWidth: CGFloat? = nil
    ) {
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              splitView.bounds.width > 0,
              splitView.bounds.height > 0
        else { return }

        splitPositionOverrideDepth += 1
        defer { splitPositionOverrideDepth -= 1 }

        let boundedDividerPosition = constrainWorkbenchSplitPosition(
            splitView,
            proposedPosition: dividerPosition,
            dividerIndex: 1
        )
        let dividerThickness = splitView.dividerThickness
        let targetInspectorWidth = max(0, splitView.bounds.width - boundedDividerPosition - dividerThickness)
        let previousMinimumThickness = inspectorSplitViewItem?.minimumThickness
        let previousMaximumThickness = inspectorSplitViewItem?.maximumThickness
        let previousHoldingPriority = inspectorSplitViewItem?.holdingPriority
        if pinsInspectorWidthDuringLayout {
            inspectorSplitViewItem?.minimumThickness = targetInspectorWidth
            inspectorSplitViewItem?.maximumThickness = targetInspectorWidth
        }
        inspectorSplitViewItem?.holdingPriority = .defaultLow
        splitView.setPosition(boundedDividerPosition, ofDividerAt: 1)
        if pinsInspectorWidthDuringLayout {
            applyPinnedWorkbenchSplitFrames(
                targetInspectorWidth: targetInspectorWidth,
                in: splitView,
                targetSidebarWidth: pinnedSidebarWidth
            )
        }
        splitView.layoutSubtreeIfNeeded()
        if pinsInspectorWidthDuringLayout {
            applyPinnedWorkbenchSplitFrames(
                targetInspectorWidth: targetInspectorWidth,
                in: splitView,
                targetSidebarWidth: pinnedSidebarWidth
            )
        }
        if pinsInspectorWidthDuringLayout, let previousMinimumThickness {
            inspectorSplitViewItem?.minimumThickness = previousMinimumThickness
        }
        if pinsInspectorWidthDuringLayout, let previousMaximumThickness {
            inspectorSplitViewItem?.maximumThickness = previousMaximumThickness
        }
        if let previousHoldingPriority {
            inspectorSplitViewItem?.holdingPriority = previousHoldingPriority
        }
        let workspaceView = subviews[1]
        let inspectorView = subviews[2]
        inspectorViewController?.synchronizeSelectedSectionLayoutAfterColumnResize(hostView: inspectorView)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyPendingInspectorWidthIfNeeded()
            self.synchronizeInspectorContentFrameAfterSplitLayout()
            self.restoreProgrammaticFrameIfNeeded(preservedWindowFrame)
        }
        let workspaceWidth = workspaceView.frame.width
        let inspectorWidth = inspectorView.frame.width
        let preferredInspectorWidth = pinsInspectorWidthDuringLayout ? targetInspectorWidth : inspectorWidth
        pendingInspectorWidth = preferredInspectorWidth
        updatePreferredInspectorFraction(preferredInspectorWidth, splitWidth: splitView.bounds.width)
        if splitView.bounds.width > 0 {
            contentSplitViewController.splitViewItems[1].preferredThicknessFraction = workspaceWidth / splitView.bounds.width
        }
    }

    private func applyPinnedWorkbenchSplitFrames(
        targetInspectorWidth: CGFloat,
        in splitView: NSSplitView,
        targetSidebarWidth: CGFloat? = nil
    ) {
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              splitView.bounds.width > 0,
              splitView.bounds.height > 0
        else { return }

        let dividerThickness = splitView.dividerThickness
        let sidebarView = subviews[0]
        let workspaceView = subviews[1]
        let inspectorView = subviews[2]
        let sidebarWidth = sidebarView.isHidden ? 0 : (targetSidebarWidth ?? sidebarView.frame.width)
        let inspectorWidth = min(
            max(targetInspectorWidth, 0),
            max(0, splitView.bounds.width - sidebarWidth - dividerThickness * 2)
        )
        let workspaceWidth = max(
            0,
            splitView.bounds.width - sidebarWidth - inspectorWidth - dividerThickness * 2
        )
        sidebarView.frame = NSRect(
            x: 0,
            y: 0,
            width: sidebarWidth,
            height: splitView.bounds.height
        )
        workspaceView.frame = NSRect(
            x: sidebarWidth + dividerThickness,
            y: 0,
            width: workspaceWidth,
            height: splitView.bounds.height
        )
        inspectorView.frame = NSRect(
            x: sidebarWidth + dividerThickness + workspaceWidth + dividerThickness,
            y: 0,
            width: inspectorWidth,
            height: splitView.bounds.height
        )
    }

    public func setInspectorDividerPositionForTesting(_ position: CGFloat) {
        let splitView = contentSplitViewController.splitView
        pendingInspectorWidth = max(0, splitView.bounds.width - position - splitView.dividerThickness)
        applyWorkbenchSplitFrames(
            forDividerOnePosition: position,
            in: splitView,
            preservingWindowFrame: window?.frame,
            pinsInspectorWidthDuringLayout: true
        )
    }

    private func applyPendingInspectorWidthIfNeeded() {
        guard let pendingInspectorWidth,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        let windowFrame = programmaticWindowFrameForLayout()
        let splitView = contentSplitViewController.splitView
        if let pinnedSplitView = splitView as? StacioPinnedSplitView,
           pinnedSplitView.isPerformingLayoutPass
        {
            schedulePendingInspectorWidthRepair()
            return
        }
        guard splitPositionOverrideDepth == 0,
              let inspectorView = splitView.arrangedSubviews.last
        else { return }

        guard abs(inspectorView.frame.width - pendingInspectorWidth) > 1 else {
            inspectorViewController?.synchronizeSelectedSectionLayoutAfterColumnResize(hostView: inspectorView)
            return
        }

        let dividerPosition = splitView.bounds.width - pendingInspectorWidth - splitView.dividerThickness
        applyWorkbenchSplitFrames(
            forDividerOnePosition: dividerPosition,
            in: splitView,
            preservingWindowFrame: windowFrame,
            pinsInspectorWidthDuringLayout: true
        )
    }

    private func schedulePendingInspectorWidthRepair() {
        guard isPendingInspectorWidthRepairScheduled == false else { return }

        isPendingInspectorWidthRepairScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.isPendingInspectorWidthRepairScheduled = false
            self.applyPendingInspectorWidthIfNeeded()
        }
    }

    private func synchronizeInspectorContentColumnLayout() {
        guard contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        let splitView = contentSplitViewController.splitView
        guard splitView.arrangedSubviews.count >= 3 else { return }

        updateInspectorToolbarTopInset(in: window)
        inspectorViewController?.synchronizeSelectedSectionLayoutAfterColumnResize(
            hostView: splitView.arrangedSubviews[2]
        )
    }

    private func synchronizeInspectorContentFrameAfterSplitLayout() {
        guard contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        let splitView = contentSplitViewController.splitView
        guard splitView.arrangedSubviews.count >= 3 else { return }

        updateInspectorToolbarTopInset(in: window)
        inspectorViewController?.synchronizeSelectedSectionFrameAfterSplitLayout(
            hostView: splitView.arrangedSubviews[2]
        )
    }

    private func restoreInspectorWidthAfterFilesCapabilityClosed(fileBrowserWidth: CGFloat) {
        let windowFrame = window?.frame
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        guard contentSplitViewController.splitViewItems.count >= 3,
              let inspectorSplitViewItem,
              inspectorSplitViewItem.isCollapsed == false
        else { return }

        let splitView = contentSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              subviews[2].isHidden == false
        else { return }

        let targetWidth = clampedInspectorWidth(
            max(fileBrowserWidth, defaultInspectorPanelWidth),
            splitWidth: splitView.bounds.width
        )
        guard targetWidth > 0 else { return }

        let storedSidebarWidth = storedSplitWidth(column: "sidebar")
        let pinnedSidebarWidth = storedSidebarWidth.map {
            clampedSidebarWidth($0, availableWidth: splitView.bounds.width)
        }
        inspectorSplitViewItem.holdingPriority = .defaultLow
        updatePreferredInspectorFraction(targetWidth, splitWidth: splitView.bounds.width)
        pendingInspectorWidth = targetWidth
        performProgrammaticSplitLayout {
            if let storedSidebarWidth {
                splitView.setPosition(
                    pinnedSidebarWidth ?? clampedSidebarWidth(storedSidebarWidth, availableWidth: splitView.bounds.width),
                    ofDividerAt: 0
                )
            }
            applyInspectorWidth(
                targetWidth,
                in: splitView,
                preservingWindowFrame: windowFrame,
                pinsInspectorWidthDuringLayout: true,
                pinnedSidebarWidth: pinnedSidebarWidth
            )
            splitView.layoutSubtreeIfNeeded()
        }
        inspectorSplitViewItem.holdingPriority = .defaultHigh
        keepSidebarReadableWithoutResizingWindow()
    }

    private func prepareInspectorWidthForFilesCapabilityOpen(
        restoringCollapsedInspector: Bool = false
    ) {
        let windowFrame = window?.frame
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        guard contentSplitViewController.splitViewItems.count >= 3,
              let inspectorSplitViewItem,
              inspectorSplitViewItem.isCollapsed == false
        else { return }

        let splitView = contentSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3,
              subviews[2].isHidden == false
        else { return }

        let targetWidth: CGFloat
        if restoringCollapsedInspector,
           let pendingInspectorWidth,
           pendingInspectorWidth > 0
        {
            targetWidth = clampedInspectorWidth(
                pendingInspectorWidth,
                splitWidth: splitView.bounds.width
            )
        } else {
            let defaultWidth = defaultInspectorWidth(
                for: splitView.bounds.width,
                preferredWidth: defaultInspectorPanelWidth
            )
            let storedWidth = storedSplitWidth(column: "inspector") ?? 0
            targetWidth = clampedInspectorWidth(
                max(defaultWidth, storedWidth, preferredFilesCapabilityInspectorWidth),
                splitWidth: splitView.bounds.width
            )
        }
        guard targetWidth > 0 else { return }

        let storedSidebarWidth = storedSplitWidth(column: "sidebar")
        let pinnedSidebarWidth = storedSidebarWidth.map {
            clampedSidebarWidth($0, availableWidth: splitView.bounds.width)
        }
        inspectorSplitViewItem.holdingPriority = .defaultLow
        updatePreferredInspectorFraction(targetWidth, splitWidth: splitView.bounds.width)
        pendingInspectorWidth = targetWidth
        performProgrammaticSplitLayout {
            if let storedSidebarWidth {
                splitView.setPosition(
                    pinnedSidebarWidth ?? clampedSidebarWidth(storedSidebarWidth, availableWidth: splitView.bounds.width),
                    ofDividerAt: 0
                )
            }
            applyInspectorWidth(
                targetWidth,
                in: splitView,
                preservingWindowFrame: windowFrame,
                pinsInspectorWidthDuringLayout: true,
                pinnedSidebarWidth: pinnedSidebarWidth
            )
            splitView.layoutSubtreeIfNeeded()
        }
        inspectorSplitViewItem.holdingPriority = .defaultHigh
        keepSidebarReadableWithoutResizingWindow()
    }

    private var isApplyingProgrammaticSplitLayout: Bool {
        programmaticSplitLayoutDepth > 0
    }

    private func performProgrammaticSplitLayout(_ body: () -> Void) {
        programmaticSplitLayoutDepth += 1
        splitWidthPersistenceSuppressionDepth += 1
        defer {
            programmaticSplitLayoutDepth -= 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.splitWidthPersistenceSuppressionDepth = max(0, self.splitWidthPersistenceSuppressionDepth - 1)
            }
        }
        body()
    }

    private func storedSplitWidth(column: String) -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: splitWidthDefaultsKey(column: column))
        guard value.isFinite, value > 0 else {
            return nil
        }
        return CGFloat(value)
    }

    private func saveSplitWidth(_ width: CGFloat, column: String) {
        guard width.isFinite, width > 0 else { return }
        UserDefaults.standard.set(Double(width), forKey: splitWidthDefaultsKey(column: column))
    }

    private func splitWidthDefaultsKey(column: String) -> String {
        "Stacio.WorkbenchSplit.\(column)Width.\(frameAutosaveName)"
    }

    public func saveSplitColumnWidthsForTesting() {
        saveSplitColumnWidthsIfNeeded(force: true)
    }

    private func saveSplitColumnWidthsIfNeeded(force: Bool = false) {
        guard isApplyingProgrammaticSplitLayout == false,
              (force || splitWidthPersistenceSuppressionDepth == 0),
              (force || allowsUserSplitWidthPersistence),
              didFinishInitialWindowPlacement,
              contentSplitViewController.splitViewItems.count >= 3
        else { return }

        let splitView = contentSplitViewController.splitView
        let subviews = splitView.arrangedSubviews
        guard subviews.count >= 3 else { return }

        let sidebarView = subviews[0]
        if sidebarView.isHidden == false,
           contentSplitViewController.splitViewItems[0].isCollapsed == false
        {
            saveSplitWidth(sidebarView.frame.width, column: "sidebar")
        }

        let inspectorView = subviews[2]
        if inspectorView.isHidden == false,
           contentSplitViewController.splitViewItems[2].isCollapsed == false
        {
            saveSplitWidth(inspectorView.frame.width, column: "inspector")
        }
    }

    private func restoreProgrammaticFrameIfNeeded(_ frame: NSRect?) {
        guard let frame,
              let window,
              isRestoringWindowFrame == false,
              isUserLiveResizingWindow == false,
              window.frame.equalTo(frame) == false
        else { return }

        isRestoringWindowFrame = true
        updateWorkbenchContentSizeStayConstraints(forFrameSize: frame.size, in: window)
        window.setFrame(frame, display: false)
        isRestoringWindowFrame = false
    }

    private func programmaticWindowFrameForLayout() -> NSRect? {
        pendingProgrammaticWindowFrameRestore ?? window?.frame
    }

    private func preserveProgrammaticWindowFrame(_ frame: NSRect?) {
        guard let frame else { return }

        pendingProgrammaticWindowFrameRestore = frame
        DispatchQueue.main.async { [weak self] in
            self?.restoreProgrammaticFrameIfNeeded(frame)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self,
                  self.pendingProgrammaticWindowFrameRestore?.equalTo(frame) == true
            else { return }

            self.restoreProgrammaticFrameIfNeeded(frame)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.pendingProgrammaticWindowFrameRestore?.equalTo(frame) == true
            else { return }

            self.restoreProgrammaticFrameIfNeeded(frame)
            self.pendingProgrammaticWindowFrameRestore = nil
        }
    }

    private func scheduleSidebarReadabilityRepair(preserving frame: NSRect? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.keepSidebarReadableWithoutResizingWindow()
            self?.restoreProgrammaticFrameIfNeeded(frame)
        }
    }

    private func scheduleInspectorReadabilityRepair(
        preserving frame: NSRect? = nil,
        preferredDefaultWidth: CGFloat? = nil,
        force: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let preferredDefaultWidth,
               let pendingInspectorWidth,
               pendingInspectorWidth > preferredDefaultWidth
            {
                applyPendingInspectorWidthIfNeeded()
                restoreProgrammaticFrameIfNeeded(frame)
                return
            }
            applyDefaultInspectorWidthIfNeeded(
                force: force,
                preferredDefaultWidth: preferredDefaultWidth
            )
            applyPendingInspectorWidthIfNeeded()
            restoreProgrammaticFrameIfNeeded(frame)
        }
    }

    private func clampedRestoredWindowFrame(
        _ proposedFrame: NSRect,
        for window: NSWindow,
        limitsSizeToVisibleFrame: Bool = false
    ) -> NSRect {
        let minimumSize = window.minSize
        var frame = proposedFrame
        let previousMaxY = frame.maxY

        frame.size.width = max(frame.width, minimumSize.width)
        if frame.height < minimumSize.height {
            frame.size.height = minimumSize.height
            frame.origin.y = previousMaxY - minimumSize.height
        }

        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            if limitsSizeToVisibleFrame {
                let maximumWidth = max(minimumSize.width, visibleFrame.width)
                let maximumHeight = max(minimumSize.height, visibleFrame.height)
                if frame.width > maximumWidth {
                    frame.size.width = maximumWidth
                }
                if frame.height > maximumHeight {
                    frame.size.height = maximumHeight
                }
            }
            if frame.maxX > visibleFrame.maxX {
                frame.origin.x = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
            }
            if frame.minX < visibleFrame.minX {
                frame.origin.x = visibleFrame.minX
            }
            if frame.maxY > visibleFrame.maxY {
                frame.origin.y = visibleFrame.maxY - frame.height
            }
            if frame.minY < visibleFrame.minY {
                frame.origin.y = visibleFrame.minY
            }
        }

        return frame
    }

    private static func defaultTransferCompletionNotificationPresenter() -> TransferCompletionNotificationPresenting {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        guard processName != "xctest",
              processName.hasSuffix("xctest") == false
        else {
            return NoopTransferCompletionNotificationPresenter()
        }
        return TransferCompletionNotificationPresenter.shared
    }

    private func makeSplitViewController() -> NSSplitViewController {
        let split = StacioPinnedSplitViewController(usesPositionHookSplitView: true)
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split.splitView,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.saveSplitColumnWidthsIfNeeded()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.saveSplitColumnWidthsIfNeeded()
                }
            }
        }
        split.afterPinnedLayout = { [weak self] in
            self?.keepSidebarReadableWithoutResizingWindow()
        }
        split.afterPinnedSplitViewLayout = { [weak self] _ in
            self?.schedulePendingInspectorWidthRepair()
        }
        split.constrainPinnedSplitPosition = { [weak self] splitView, proposedPosition, dividerIndex in
            self?.constrainWorkbenchSplitPosition(
                splitView,
                proposedPosition: proposedPosition,
                dividerIndex: dividerIndex
            ) ?? proposedPosition
        }
        split.beforePinnedSetPosition = { [weak self] splitView, position, dividerIndex in
            self?.prepareWorkbenchSplitPosition(
                splitView,
                position: position,
                dividerIndex: dividerIndex
            )
        }
        split.afterPinnedSetPosition = { [weak self] splitView, position, dividerIndex in
            self?.finishWorkbenchSplitPosition(
                splitView,
                position: position,
                dividerIndex: dividerIndex
            )
        }
        let credentialManager = makeDefaultSessionSidebarCredentialManager()

        var sidebarController: SessionSidebarViewController!
        sidebarController = SessionSidebarViewController(
            sessionStore: makeDefaultSessionSidebarStore(),
            onOpenSession: { [weak self] session in
                do {
                    _ = try self?.openSavedSession(session)
                } catch is CancellationError {
                }
            },
            sessionEditor: makeDefaultSessionSidebarSessionEditor(credentialSaver: credentialManager),
            credentialCleaner: credentialManager,
            onDeleteSessionHistory: { [weak self] sessionID in
                try? self?.makeAIConversationHistoryStore()?.deleteConversationHistory(
                    runtimeID: "session:\(sessionID)"
                )
            },
            settingsStore: settingsStore,
            licenseAccess: licenseAccess
        )
        _ = sidebarController.view
        let readableSidebarWidth = sidebarController.view.widthAnchor.constraint(
            greaterThanOrEqualToConstant: minimumReadableSidebarWidth
        )
        readableSidebarWidth.identifier = "Stacio.Workbench.sidebarReadableWidth"
        readableSidebarWidth.priority = .dragThatCannotResizeWindow
        readableSidebarWidth.isActive = true
        sidebarController.view.setContentCompressionResistancePriority(
            .dragThatCannotResizeWindow,
            for: .horizontal
        )
        sessionSidebarViewController = sidebarController
        let sidebar = NSSplitViewItem(viewController: sidebarController)
        sidebar.canCollapse = true
        sidebar.minimumThickness = minimumReadableSidebarWidth
        sidebar.maximumThickness = 320
        sidebar.preferredThicknessFraction = 0.20
        sidebar.holdingPriority = .defaultLow
        sidebarSplitViewItem = sidebar

        let workspace = NSSplitViewItem(viewController: workspaceViewController)
        workspace.minimumThickness = 0
        workspace.preferredThicknessFraction = 0.57
        workspace.holdingPriority = .defaultLow
        workspaceViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceViewController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let terminalMacroStore = makeTerminalMacroStore()
        let terminalMacroRecorder = terminalMacroStore.map { TerminalMacroRecorder(store: $0) }
        let terminalMacroPlaybackCoordinator = TerminalMacroPlaybackCoordinator()
        terminalMacroPlaybackCoordinator.onPlaybackStateChanged = { [weak workspaceViewController] isPlaying in
            workspaceViewController?.terminalMacroRecorder?.isCaptureSuppressed = isPlaying
        }
        workspaceViewController.terminalMacroRecorder = terminalMacroRecorder

        let inspectorController = InspectorViewController(
            transferHistoryStore: transferHistoryStore,
            aiAssistantViewController: makeAIAssistantPanelViewController(),
            tunnelLiveSessionContextProvider: tunnelLiveSessionContextProvider,
            remoteFilePathTerminalSender: { [weak workspaceViewController] path in
                _ = workspaceViewController?.sendTextToCurrentTerminal(path)
            },
            filesEmbeddedCapabilityOpenHandler: { [weak self] in
                self?.prepareInspectorWidthForFilesCapabilityOpen()
            },
            filesEmbeddedCapabilityCloseHandler: { [weak self] fileBrowserWidth in
                self?.restoreInspectorWidthAfterFilesCapabilityClosed(fileBrowserWidth: fileBrowserWidth)
            },
            tunnelLiveBridge: tunnelLiveBridge,
            remoteFilesBridge: remoteFilesBridge,
            commandHistoryProvider: { [weak workspaceViewController] in
                workspaceViewController?.commandHistoryEntriesForCurrentTerminal() ?? []
            },
            commandHistoryPasteHandler: { [weak workspaceViewController] command in
                _ = workspaceViewController?.sendTextToCurrentTerminal(command)
            },
            terminalMacroProvider: {
                (try? terminalMacroStore?.listMacros()) ?? []
            },
            terminalMacroStartHandler: { [weak self] in
                guard let terminalMacroRecorder else {
                    self?.presentTerminalMacroStorageUnavailable()
                    return false
                }
                terminalMacroRecorder.startRecording()
                return true
            },
            terminalMacroStopHandler: { [weak self] name in
                guard let terminalMacroRecorder else {
                    self?.presentTerminalMacroStorageUnavailable()
                    return
                }
                do {
                    let saved = try terminalMacroRecorder.stopRecording(name: name)
                    if saved == nil {
                        self?.presentTerminalMacroMessage(
                            title: L10n.TerminalMacro.noCommandsTitle,
                            message: L10n.TerminalMacro.noCommandsMessage,
                            style: .informational
                        )
                    }
                } catch {
                    self?.presentTerminalMacroError(error)
                }
            },
            terminalMacroPlayHandler: { [weak self, weak workspaceViewController] macro in
                _ = terminalMacroPlaybackCoordinator.play(
                    macro: macro,
                    target: workspaceViewController?.currentTerminalMacroPlaybackTarget(),
                    parentWindow: self?.window
                )
            },
            terminalMacroRenameHandler: { [weak self] macro, name in
                do {
                    _ = try terminalMacroStore?.renameMacro(id: macro.id, name: name)
                } catch {
                    self?.presentTerminalMacroError(error)
                }
            },
            terminalMacroDeleteHandler: { [weak self] macro in
                do {
                    try terminalMacroStore?.deleteMacro(id: macro.id)
                } catch {
                    self?.presentTerminalMacroError(error)
                }
            },
            settingsStore: settingsStore,
            licenseAccess: licenseAccess,
            transferCompletionNotificationPresenter: Self.defaultTransferCompletionNotificationPresenter(),
            transferQueueCoordinatorFactory: transferQueueCoordinatorFactory
        )
        _ = inspectorController.view
        workspaceViewController.onRemoteTerminalDirectoryChanged = { [weak inspectorController] pane, directory in
            inspectorController?.followRemoteTerminalDirectoryIfEnabled(
                runtimeID: pane.runtimeID,
                remotePath: directory
            )
        }
        workspaceViewController.onRemoteTerminalUploadDroppedFiles = { [weak self] pane, remoteDirectory, localPaths in
            self?.scheduleTerminalDroppedUploads(
                pane: pane,
                remoteDirectory: remoteDirectory,
                localPaths: localPaths
            )
        }
        workspaceViewController.onRemoteTerminalRuntimeReattached = { [weak inspectorController] pane, oldRuntimeID, _, liveSessionContext in
            inspectorController?.reattachFilesBindingIfNeeded(
                oldRuntimeID: oldRuntimeID,
                runtimeID: pane.runtimeID,
                context: liveSessionContext ?? pane.liveSessionContext,
                remotePath: pane.currentRemoteDirectory
            )
        }
        workspaceViewController.onRemoteTerminalClosed = { [weak inspectorController] pane in
            let canClose = inspectorController?.disconnectFilesBindingIfNeeded(runtimeID: pane.runtimeID) ?? true
            if canClose {
                inspectorController?.dismissTransferNotifications(runtimeID: pane.runtimeID)
            }
            return canClose
        }
        workspaceViewController.onCurrentRemoteTerminalAttached = { [weak self, weak inspectorController] pane in
            guard let context = pane.liveSessionContext else {
                return
            }
            inspectorController?.rebindFilesToCurrentRemoteTerminalIfFollowing(
                binding: InspectorViewController.RemoteFilesBinding(
                    runtimeID: pane.runtimeID,
                    context: context,
                    remotePath: pane.currentRemoteDirectory
                ),
                refreshDirectory: self?.shouldRefreshRemoteFilesDirectory(
                    remotePath: pane.currentRemoteDirectory
                ) == true
            )
            inspectorController?.refreshCurrentTerminalContextPanels()
        }
        workspaceViewController.onCurrentRemoteTerminalChanged = { [weak self, weak inspectorController] pane in
            guard let pane,
                  let context = pane.liveSessionContext else {
                inspectorController?.unbindFilesFromCurrentTerminalSelection()
                return
            }
            inspectorController?.rebindFilesToCurrentRemoteTerminalIfFollowing(
                binding: InspectorViewController.RemoteFilesBinding(
                    runtimeID: pane.runtimeID,
                    context: context,
                    remotePath: pane.currentRemoteDirectory
                ),
                refreshDirectory: self?.shouldRefreshRemoteFilesDirectory(
                    remotePath: pane.currentRemoteDirectory
                ) == true
            )
        }
        workspaceViewController.onCurrentTerminalChanged = { [weak inspectorController] in
            inspectorController?.refreshCurrentTerminalContextPanels()
        }
        workspaceViewController.onCommandHistoryChanged = { [weak inspectorController] in
            inspectorController?.reloadCommandHistory()
        }
        workspaceViewController.onAIContextRequest = { [weak self] request in
            self?.showAIAssistantInspector(prefilling: request.selectedText)
        }
        inspectorController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inspectorController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inspectorViewController = inspectorController
        let inspector = NSSplitViewItem(viewController: inspectorController)
        inspector.minimumThickness = 0
        inspector.maximumThickness = unrestrictedInspectorPanelWidth
        inspector.preferredThicknessFraction = 0.27
        inspector.holdingPriority = .defaultHigh
        inspector.isCollapsed = true
        inspectorSplitViewItem = inspector

        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(workspace)
        split.addSplitViewItem(inspector)
        return split
    }

    private func makeTerminalMacroStore() -> TerminalMacroStoring? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return CoreBridgeTerminalMacroStore(databasePath: databasePath)
    }

    private func presentTerminalMacroStorageUnavailable() {
        presentTerminalMacroMessage(
            title: L10n.TerminalMacro.storageUnavailableTitle,
            message: L10n.TerminalMacro.storageUnavailableMessage,
            style: .warning
        )
    }

    private func presentTerminalMacroError(_ error: Error) {
        presentTerminalMacroMessage(
            title: L10n.TerminalMacro.title,
            message: RuntimeDiagnosticFormatter.userMessage(for: error),
            style: .warning
        )
    }

    private func presentTerminalMacroMessage(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: L10n.Common.ok)
        _ = alert.runModal()
    }

    private func makeAIAssistantPanelViewController() -> AIAssistantPanelViewController {
        let modelSelectionSession = AIModelSelectionSession()
        return AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: SettingsBackedAIAssistantProvider(
                    settingsStore: settingsStore,
                    apiKeyStore: aiAPIKeyStore,
                    transport: aiHTTPTransport,
                    selectionSession: modelSelectionSession
                ),
                executionCoordinator: makeAgentExecutionCoordinator(parentWindow: window),
                settingsStore: settingsStore,
                modelSelectionSession: modelSelectionSession
            ),
            contextProvider: { [weak workspaceViewController] runtimeID in
                workspaceViewController?.aiTerminalContext(runtimeID: runtimeID)
            },
            terminalSessionProvider: { [weak workspaceViewController] in
                workspaceViewController?.listAgentTerminalSessions() ?? []
            },
            settingsStore: settingsStore,
            modelSelectionSession: modelSelectionSession,
            taskRecorder: makeAgentTaskStore(),
            taskLister: makeAgentTaskStore(),
            conversationHistoryStore: makeAIConversationHistoryStore(),
            internalBrowserOpener: { [weak workspaceViewController] url in
                _ = try? workspaceViewController?.openBrowserSession(
                    urlString: url.absoluteString,
                    title: url.host ?? url.absoluteString
                )
            },
            localAgentToolResolver: aiLocalAgentToolResolver,
            localAgentProcessLauncherFactory: aiLocalAgentProcessLauncherFactory
        )
    }

    private func ensureAIAssistantOverlayViewController() -> AIAssistantPanelViewController? {
        if let aiAssistantOverlayViewController {
            return aiAssistantOverlayViewController
        }
        guard let rootController = rootContentViewController else {
            return nil
        }

        let panel = makeAIAssistantPanelViewController()
        panel.onCollapse = { [weak self] in
            self?.hideAIAssistantOverlay()
        }
        let panelView = panel.view
        panelView.setAccessibilityIdentifier("Stacio.AI.overlay")
        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.isHidden = true
        panelView.wantsLayer = true
        panelView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        panelView.layer?.shadowOpacity = 1
        panelView.layer?.shadowRadius = 18
        panelView.layer?.shadowOffset = NSSize(width: 0, height: -4)

        rootController.addChild(panel)
        rootController.view.addSubview(panelView)

        let minimumWidth = panelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 560)
        minimumWidth.priority = .defaultLow
        let preferredWidth = panelView.widthAnchor.constraint(equalToConstant: 840)
        preferredWidth.priority = .defaultHigh
        let maximumWidth = panelView.widthAnchor.constraint(lessThanOrEqualToConstant: 920)
        maximumWidth.priority = .required
        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: rootController.view.centerXAnchor),
            panelView.bottomAnchor.constraint(equalTo: rootController.view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            preferredWidth,
            maximumWidth,
            panelView.widthAnchor.constraint(lessThanOrEqualTo: rootController.view.widthAnchor, constant: -64),
            minimumWidth,
            panelView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            panelView.heightAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])

        aiAssistantOverlayViewController = panel
        return panel
    }

    private func showAIAssistantOverlay() {
        guard let panel = ensureAIAssistantOverlayViewController() else {
            return
        }
        panel.refreshForCurrentContext()
        panel.view.isHidden = false
        panel.view.superview?.layoutSubtreeIfNeeded()
        StacioDesignSystem.fadeIn(panel.view)
        panel.focusQuestionField()
    }

    private func showAIAssistantOverlay(prefilling text: String?) {
        showAIAssistantOverlay()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            aiAssistantOverlayViewController?.prefillQuestion("解释这段终端输出：\n\(trimmed)")
        }
    }

    private func hideAIAssistantOverlay() {
        guard let panel = aiAssistantOverlayViewController else {
            return
        }
        panel.view.isHidden = true
    }

    private func showAIAssistantInspector(prefilling text: String? = nil) {
        guard let inspectorSplitViewItem,
              let inspectorViewController
        else {
            return
        }
        let preservedWindowFrame = window?.frame
        defer {
            restoreProgrammaticFrameIfNeeded(preservedWindowFrame)
        }
        performProgrammaticSplitLayout {
            inspectorSplitViewItem.isCollapsed = false
        }
        applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        inspectorViewController.selectAIAssistantTab()
        scheduleInspectorReadabilityRepair(
            preserving: preservedWindowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        keepSidebarReadableWithoutResizingWindow()
        scheduleSidebarReadabilityRepair(preserving: preservedWindowFrame)
        inspectorViewController.aiAssistantViewController?.refreshForCurrentContext()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            inspectorViewController.aiAssistantViewController?.prefillQuestion("解释这段终端输出：\n\(trimmed)")
        }
        inspectorViewController.aiAssistantViewController?.focusQuestionField()
    }

    private func makeAgentExecutionCoordinator(parentWindow: NSWindow?) -> AgentExecutionCoordinator {
        if let agentExecutionCoordinator {
            return agentExecutionCoordinator
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: workspaceViewController,
            authorizer: SettingsBackedAgentActionAuthorizer(
                settingsStore: settingsStore,
                confirmer: agentActionConfirmer,
                parentWindow: parentWindow
            ),
            auditRecorder: makeAgentActionAuditStore(),
            sessionLister: workspaceViewController,
            executionMode: .visibleTerminal
        )
        agentExecutionCoordinator = coordinator
        return coordinator
    }

    private func makeAgentActionAuditStore() -> AgentActionAuditRecording? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return CoreBridgeAgentActionAuditStore(databasePath: databasePath)
    }

    private func makeAgentTaskStore() -> AgentTaskStoring? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return CoreBridgeAgentTaskStore(databasePath: databasePath)
    }

    private func makeAIConversationHistoryStore() -> CoreBridgeAIAssistantConversationHistoryStore? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return CoreBridgeAIAssistantConversationHistoryStore(databasePath: databasePath)
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Stacio.Toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        for identifier in toolbarDefaultItemIdentifiers(toolbar) {
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
        }

        return toolbar
    }

    private func makeSidebarToolbarToggleButton() -> SidebarToggleTitlebarButton {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: L10n.Workbench.sidebar
        )?.withSymbolConfiguration(symbolConfiguration)
        let button = SidebarToggleTitlebarButton(
            image: image ?? NSImage(),
            target: self,
            action: #selector(toggleSidebarFromToolbar(_:))
        )
        button.setButtonType(.momentaryChange)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = nil
        button.layer?.borderColor = nil
        button.layer?.borderWidth = 0
        button.contentTintColor = StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: button)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = L10n.Workbench.toggleSidebar
        button.setAccessibilityLabel(L10n.Workbench.toggleSidebar)
        button.setAccessibilityIdentifier("Stacio.Toolbar.sidebarToggle")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        button.onPointerEntered = { [weak self] in
            self?.temporarilyRevealSidebarFromTitlebarHover()
        }
        button.onPointerExited = { [weak self] in
            self?.hideTemporarilyRevealedSidebarFromTitlebarHover()
        }
        return button
    }

    private func makeUpdatePromptToolbarButton() -> UpdatePromptTitlebarButton {
        let button = UpdatePromptTitlebarButton(title: "", target: self, action: #selector(updatePromptButtonPressed(_:)))
        button.setButtonType(.momentaryChange)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .noImage
        button.setAccessibilityIdentifier("Stacio.Toolbar.updatePrompt")
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.identifier = "Stacio.Toolbar.updatePromptWidth"
        updatePromptWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            widthConstraint,
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        updatePromptButton = button
        refreshUpdatePromptButton(sparkleUpdateController?.buttonState ?? .hidden)
        return button
    }

    private func bindUpdatePromptControllerIfNeeded() {
        guard let sparkleUpdateController else {
            return
        }
        sparkleUpdateController.onButtonStateChanged = { [weak self] state in
            self?.refreshUpdatePromptButton(state)
        }
        refreshUpdatePromptButton(sparkleUpdateController.buttonState)
    }

    private func refreshUpdatePromptButton(_ state: SparkleUpdateButtonState) {
        sessionSidebarViewController?.updateUpdateStatus(state)
        guard let button = updatePromptButton else {
            return
        }
        button.update(state: state)
        switch state {
        case .available, .failed:
            button.isEnabled = true
        case .hidden, .downloading, .extracting, .installing:
            button.isEnabled = false
        }
        let size = state.isVisible ? button.intrinsicContentSize : .zero
        updatePromptWidthConstraint?.constant = size.width
        updatePromptToolbarItem?.view?.frame = NSRect(origin: .zero, size: size)
        window?.toolbar?.validateVisibleItems()
    }

    private func installSystemAppearanceObserverIfNeeded() {
        guard systemAppearanceObserver == nil else { return }
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWorkbenchAppearanceRefresh()
            }
        }
    }

    private func scheduleWorkbenchAppearanceRefresh() {
        let delays: [TimeInterval] = [0, 0.02, 0.12, 0.35]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshWorkbenchAppearance()
            }
        }
    }

    private func refreshWorkbenchAppearance() {
        guard let window else { return }
        StacioDesignSystem.refreshWindowDynamicColors(window)
        refreshToolbarAppearance()
        updateInspectorToolbarTopInset(in: window)
        window.contentView?.needsDisplay = true
    }

    private func refreshToolbarAppearance() {
        guard let toolbar = window?.toolbar else { return }
        toolbar.validateVisibleItems()
        for item in toolbar.visibleItems ?? toolbar.items {
            if item.itemIdentifier == ToolbarItem.updatePrompt {
                continue
            }
            if let button = item.view as? NSButton {
                button.contentTintColor = StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: button)
                button.needsDisplay = true
            }
        }
    }

    private func makeSplitTerminalToolbarMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.Workbench.split)
        menu.addItem(splitTerminalMenuItem(
            title: L10n.Workbench.splitSingleTerminal,
            symbolName: "rectangle",
            action: #selector(performSingleTerminalLayoutFromToolbar(_:))
        ))
        menu.addItem(splitTerminalMenuItem(
            title: L10n.Workbench.splitVertical,
            symbolName: "rectangle.split.2x1",
            action: #selector(performVerticalSplitTerminalFromToolbar(_:))
        ))
        menu.addItem(splitTerminalMenuItem(
            title: L10n.Workbench.splitHorizontal,
            symbolName: "rectangle.split.1x2",
            action: #selector(performHorizontalSplitTerminalFromToolbar(_:))
        ))
        menu.addItem(splitTerminalMenuItem(
            title: L10n.Workbench.splitGrid,
            symbolName: "rectangle.split.2x2",
            action: #selector(performGridSplitTerminalFromToolbar(_:))
        ))
        return menu
    }

    private func makeSessionImportMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.Import.title)
        menu.autoenablesItems = false
        menu.delegate = SessionImportMenuAvailabilityDelegate.shared
        for source in AppKitSessionImportSourcePicker.supportedSources {
            let item = NSMenuItem(
                title: source.name,
                action: #selector(performImportSourceFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = source.type.rawValue
            item.image = SessionImportSourceIconCatalog.image(for: source)
            SessionImportSourceAvailability.configure(item, for: source)
            menu.addItem(item)
        }
        return menu
    }

    private func splitTerminalMenuItem(
        title: String,
        symbolName: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        return item
    }

    private func makePanelsToolbarMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.Workbench.panels)
        menu.autoenablesItems = false
        menu.delegate = licensedFeatureMenuDelegate
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Inspector.files,
            symbolName: "folder",
            action: #selector(showFilesFromToolbar(_:))
        ))
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Inspector.browser,
            symbolName: "safari",
            action: #selector(showBrowserFromToolbar(_:))
        ))
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Workbench.tunnels,
            symbolName: "point.topleft.down.curvedto.point.bottomright.up",
            action: #selector(showTunnelsFromToolbar(_:))
        ))
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Workbench.deviceDashboard,
            symbolName: "gauge.with.dots.needle.67percent",
            action: #selector(toggleDeviceDashboardFromToolbar(_:)),
            fallbackSymbolName: "speedometer"
        ))
        menu.addItem(.separator())
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Inspector.logs,
            symbolName: "waveform.path.ecg",
            action: #selector(showDiagnosticsFromToolbar(_:)),
            fallbackSymbolName: "stethoscope"
        ))
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Inspector.macros,
            symbolName: "command.square",
            action: #selector(showTerminalMacrosFromToolbar(_:)),
            fallbackSymbolName: "command"
        ))
        menu.addItem(panelToolbarMenuItem(
            title: L10n.Inspector.commandHistory,
            symbolName: "clock.arrow.circlepath",
            action: #selector(showCommandHistoryFromToolbar(_:)),
            fallbackSymbolName: "clock"
        ))
        menu.addItem(.separator())
        menu.addItem(panelToolbarMenuItem(
            title: L10n.AI.title,
            symbolName: "sparkles",
            action: #selector(showAIAssistantFromToolbar(_:)),
            fallbackSymbolName: "wand.and.stars"
        ))
        return menu
    }

    private func panelToolbarMenuItem(
        title: String,
        symbolName: String,
        action: Selector,
        fallbackSymbolName: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            ?? fallbackSymbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        if let feature = licensedFeature(for: action) {
            configureLicenseAvailability(item, feature: feature)
        }
        return item
    }

    private func licensedFeature(for action: Selector?) -> StacioLicensedFeature? {
        switch action {
        case #selector(performMultiExecFromToolbar(_:)): .multiExec
        case #selector(showTunnelsFromToolbar(_:)): .sshTunnel
        case #selector(toggleDeviceDashboardFromToolbar(_:)): .advancedMetrics
        case #selector(showAIAssistantFromToolbar(_:)): .aiAgent
        default: nil
        }
    }

    private func configureLicenseAvailability(_ item: NSMenuItem, feature: StacioLicensedFeature) {
        item.isEnabled = licenseAccess.isEnabled(feature)
        item.toolTip = item.isEnabled ? nil : L10n.Import.licenseUnavailableTooltip
    }

    fileprivate func refreshLicensedFeatureMenu(_ menu: NSMenu) {
        for item in menu.items {
            guard let feature = licensedFeature(for: item.action) else { continue }
            configureLicenseAvailability(item, feature: feature)
        }
    }

    private func isLicensed(_ feature: StacioLicensedFeature) -> Bool {
        licenseAccess.isEnabled(feature)
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [ToolbarItem.sidebar]
        identifiers.append(contentsOf: [
            .flexibleSpace,
            ToolbarItem.newSession,
            ToolbarItem.importSessions,
            .space,
            ToolbarItem.multiExec,
            ToolbarItem.split,
            .space,
            ToolbarItem.files,
            ToolbarItem.browser,
            ToolbarItem.tunnels,
            ToolbarItem.deviceDashboard,
            ToolbarItem.aiAssistant,
            ToolbarItem.panels,
            .space,
            ToolbarItem.inspector
        ])
        return identifiers
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [
            ToolbarItem.importSessions
        ]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == ToolbarItem.split {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.label = L10n.Workbench.split
            item.paletteLabel = L10n.Workbench.split
            item.toolTip = L10n.Workbench.splitTerminal
            item.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: L10n.Workbench.splitTerminal)
                ?? NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: L10n.Workbench.splitTerminal)
            item.action = #selector(performSplitTerminalFromToolbar(_:))
            item.menu = makeSplitTerminalToolbarMenu()
            item.showsIndicator = true
            return item
        }
        if itemIdentifier == ToolbarItem.importSessions {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.label = L10n.Workbench.importSessions
            item.paletteLabel = L10n.Workbench.importSessions
            item.toolTip = L10n.Workbench.importSessionsTooltip
            item.image = NSImage(
                systemSymbolName: "rectangle.stack.badge.plus",
                accessibilityDescription: L10n.Workbench.importSessionsAccessibilityDescription
            )
            item.menu = makeSessionImportMenu()
            item.showsIndicator = false
            return item
        }
        if itemIdentifier == ToolbarItem.panels {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.label = L10n.Workbench.panels
            item.paletteLabel = L10n.Workbench.panels
            item.toolTip = L10n.Workbench.panelsTooltip
            item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: L10n.Workbench.panels)
                ?? NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: L10n.Workbench.panels)
            item.menu = makePanelsToolbarMenu()
            item.showsIndicator = true
            return item
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self

        switch itemIdentifier {
        case ToolbarItem.sidebar:
            item.label = L10n.Workbench.sidebar
            item.paletteLabel = L10n.Workbench.sidebar
            item.toolTip = L10n.Workbench.toggleSidebar
            item.view = makeSidebarToolbarToggleButton()
        case ToolbarItem.updatePrompt:
            item.label = "更新"
            item.paletteLabel = "更新"
            item.toolTip = "Stacio 更新"
            item.view = makeUpdatePromptToolbarButton()
            updatePromptToolbarItem = item
        case ToolbarItem.quickConnect:
            item.label = L10n.Workbench.quickConnect
            item.paletteLabel = L10n.Workbench.quickConnect
            item.toolTip = L10n.Workbench.quickConnect
            item.image = NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: L10n.Workbench.quickConnect)
            item.action = #selector(performQuickConnectFromToolbar(_:))
        case ToolbarItem.newSession:
            item.label = L10n.Workbench.newSession
            item.paletteLabel = L10n.Workbench.newSession
            item.toolTip = L10n.Workbench.newSession
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.Workbench.newSession)
            item.action = #selector(performNewSessionFromToolbar(_:))
        case ToolbarItem.importSessions:
            item.label = L10n.Workbench.importSessions
            item.paletteLabel = L10n.Workbench.importSessions
            item.toolTip = L10n.Workbench.importSessionsTooltip
            item.image = NSImage(
                systemSymbolName: "rectangle.stack.badge.plus",
                accessibilityDescription: L10n.Workbench.importSessionsAccessibilityDescription
            )
            item.action = #selector(performImportFromToolbar(_:))
        case ToolbarItem.closeTerminal:
            item.label = L10n.Workbench.close
            item.paletteLabel = L10n.Workbench.close
            item.toolTip = L10n.Workbench.closeCurrentTerminal
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: L10n.Workbench.closeCurrentTerminal)
            item.action = #selector(closeCurrentTerminalFromToolbar(_:))
        case ToolbarItem.multiExec:
            item.label = L10n.Workbench.multiExec
            item.paletteLabel = L10n.Workbench.multiExec
            item.toolTip = L10n.Workbench.multiExecTooltip
            item.image = NSImage(
                systemSymbolName: "arrow.triangle.branch",
                accessibilityDescription: L10n.Workbench.multiExecAccessibilityDescription
            ) ?? NSImage(
                systemSymbolName: "point.3.connected.trianglepath.dotted",
                accessibilityDescription: L10n.Workbench.multiExecAccessibilityDescription
            )
            item.action = #selector(performMultiExecFromToolbar(_:))
        case ToolbarItem.files:
            item.label = L10n.Inspector.files
            item.paletteLabel = L10n.Inspector.files
            item.toolTip = L10n.Inspector.files
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: L10n.Inspector.files)
            item.action = #selector(showFilesFromToolbar(_:))
        case ToolbarItem.browser:
            item.label = L10n.Inspector.browser
            item.paletteLabel = L10n.Inspector.browser
            item.toolTip = L10n.Inspector.browser
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: L10n.Inspector.browser)
            item.action = #selector(showBrowserFromToolbar(_:))
        case ToolbarItem.tunnels:
            item.label = L10n.Workbench.tunnels
            item.paletteLabel = L10n.Workbench.tunnels
            item.toolTip = L10n.Workbench.tunnels
            item.image = NSImage(systemSymbolName: "point.topleft.down.curvedto.point.bottomright.up", accessibilityDescription: L10n.Workbench.tunnels)
            item.action = #selector(showTunnelsFromToolbar(_:))
        case ToolbarItem.deviceDashboard:
            item.label = L10n.Workbench.deviceDashboard
            item.paletteLabel = L10n.Workbench.deviceDashboard
            item.toolTip = L10n.Workbench.toggleDeviceDashboard
            item.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: L10n.Workbench.deviceDashboard
            ) ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: L10n.Workbench.deviceDashboard)
            item.action = #selector(toggleDeviceDashboardFromToolbar(_:))
        case ToolbarItem.aiAssistant:
            item.label = L10n.AI.title
            item.paletteLabel = L10n.AI.assistant
            item.toolTip = L10n.AI.assistant
            item.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: L10n.AI.assistant
            ) ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: L10n.AI.assistant)
            item.action = #selector(showAIAssistantFromToolbar(_:))
        case ToolbarItem.inspector:
            item.label = L10n.Workbench.inspector
            item.paletteLabel = L10n.Workbench.inspector
            item.toolTip = L10n.Workbench.inspector
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: L10n.Workbench.inspector)
            item.action = #selector(toggleInspectorFromToolbar(_:))
        default:
            return nil
        }

        return item
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let feature: StacioLicensedFeature?
        switch item.itemIdentifier {
        case ToolbarItem.multiExec: feature = .multiExec
        case ToolbarItem.tunnels: feature = .sshTunnel
        case ToolbarItem.deviceDashboard: feature = .advancedMetrics
        case ToolbarItem.aiAssistant: feature = .aiAgent
        default: feature = nil
        }
        guard let feature else { return true }
        let enabled = isLicensed(feature)
        item.toolTip = enabled ? licensedToolbarDefaultToolTip(for: item.itemIdentifier) : L10n.Import.licenseUnavailableTooltip
        return enabled
    }

    private func refreshLicensedToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            guard licensedToolbarDefaultToolTip(for: item.itemIdentifier) != nil else { continue }
            item.isEnabled = validateToolbarItem(item)
        }
        toolbar.validateVisibleItems()
    }

    private func licensedToolbarDefaultToolTip(for identifier: NSToolbarItem.Identifier) -> String? {
        switch identifier {
        case ToolbarItem.multiExec: L10n.Workbench.multiExecTooltip
        case ToolbarItem.tunnels: L10n.Workbench.tunnels
        case ToolbarItem.deviceDashboard: L10n.Workbench.toggleDeviceDashboard
        case ToolbarItem.aiAssistant: L10n.AI.assistant
        default: nil
        }
    }

    @objc
    public func openLocalShellFromToolbar(_ sender: Any?) throws {
        try workspaceViewController.openLocalShell()
    }

    @objc
    public func updatePromptButtonPressed(_ sender: Any?) {
        sparkleUpdateController?.installAvailableUpdateFromPrompt()
    }

    @objc
    public func performNewSessionFromToolbar(_ sender: Any?) {
        sessionSidebarViewController?.createSession()
    }

    @objc
    public func performImportFromToolbar(_ sender: Any?) {
        guard let sessionSidebarViewController else {
            return
        }
        performImportFromSidebar(sessionSidebarViewController)
    }

    @objc
    public func performImportSourceFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let rawValue = item.representedObject as? String,
              let sourceType = SessionImportSourceType(rawValue: rawValue),
              let sessionSidebarViewController
        else { return }
        performImportFromSidebar(sessionSidebarViewController, sourceType: sourceType)
    }

    @objc
    public func performSplitTerminalFromToolbar(_ sender: Any?) {
        performVerticalSplitTerminalFromToolbar(sender)
    }

    @objc
    public func performSingleTerminalLayoutFromToolbar(_ sender: Any?) {
        workspaceViewController.setCurrentTerminalSplitLayout(.single)
    }

    @objc
    public func performVerticalSplitTerminalFromToolbar(_ sender: Any?) {
        performExistingTerminalSplit(layout: .vertical)
    }

    @objc
    public func performHorizontalSplitTerminalFromToolbar(_ sender: Any?) {
        performExistingTerminalSplit(layout: .horizontal)
    }

    @objc
    public func performGridSplitTerminalFromToolbar(_ sender: Any?) {
        performExistingTerminalSplit(layout: .grid)
    }

    private func performExistingTerminalSplit(layout: TerminalSplitLayoutMode) {
        let targets = workspaceViewController.splitTargets()
        if targets.count < 2 {
            guard (try? workspaceViewController.splitCurrentTerminal()) != nil else { return }
            workspaceViewController.setCurrentTerminalSplitLayout(layout)
            return
        }
        guard let selection = multiExecSessionSelector.selectMultiExecTargets(targets: targets, parentWindow: window) else {
            return
        }
        _ = try? workspaceViewController.splitExistingTerminals(targetIDs: selection.targetIDs, layout: layout)
    }

    @objc
    public func closeCurrentTerminalFromToolbar(_ sender: Any?) {
        closeCurrentTerminalFromMenu(sender)
    }

    @objc
    public func showFilesFromToolbar(_ sender: Any?) {
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        let currentRemoteFilesBinding = workspaceViewController.currentRemoteFilesBinding
        let shouldCollapseFilesInspector = currentRemoteFilesBinding == nil
            || inspectorViewController?.isFilesTabBound(to: currentRemoteFilesBinding) == true
        if shouldCollapseFilesInspector,
           collapseInspectorIfShowingCurrentSection(L10n.Inspector.files, preserving: windowFrame)
        {
            return
        }
        if workspaceViewController.isCurrentPaneLocalTerminal {
            let localPath = workspaceViewController.currentLocalTerminalDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            _ = try? workspaceViewController.openFileSession(path: localPath, title: L10n.Workspace.localFiles)
            return
        }
        let hasExpandedFilesCapability = inspectorViewController?.filesViewController?
            .isEmbeddedCapabilityExpandedForInspectorControls == true
        let wasInspectorCollapsed = inspectorSplitViewItem?.isCollapsed == true
        revealInspector()
        if hasExpandedFilesCapability {
            prepareInspectorWidthForFilesCapabilityOpen(
                restoringCollapsedInspector: wasInspectorCollapsed
            )
        } else {
            applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        }
        keepSidebarReadableWithoutResizingWindow()
        do {
            if let binding = currentRemoteFilesBinding {
                _ = try inspectorViewController?.selectFilesTabAndLoadCurrentDirectory(binding: binding)
            } else {
                let remotePath = workspaceViewController.currentRemoteTerminalDirectory ?? "~"
                _ = try inspectorViewController?.selectFilesTabAndLoadCurrentDirectory(remotePath: remotePath)
            }
        } catch {
            inspectorViewController?.showFilesInitialLoadError(error)
        }
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: hasExpandedFilesCapability
                ? preferredFilesCapabilityInspectorWidth
                : defaultInspectorPanelWidth,
            force: hasExpandedFilesCapability == false
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func showTunnelsFromToolbar(_ sender: Any?) {
        guard isLicensed(.sshTunnel) else { return }
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.tunnels, preserving: windowFrame) {
            return
        }
        revealInspector()
        applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        inspectorViewController?.selectTunnelsTab()
        keepSidebarReadableWithoutResizingWindow()
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func showBrowserFromToolbar(_ sender: Any?) {
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.browser, preserving: windowFrame) {
            return
        }
        revealInspector()
        applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        inspectorViewController?.selectBrowserTab()
        keepSidebarReadableWithoutResizingWindow()
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func showDiagnosticsFromToolbar(_ sender: Any?) {
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.logs, preserving: windowFrame) {
            return
        }
        revealInspector()
        applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        inspectorViewController?.selectDiagnosticsTab()
        keepSidebarReadableWithoutResizingWindow()
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func showTerminalMacrosFromToolbar(_ sender: Any?) {
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.macros, preserving: windowFrame) {
            return
        }
        revealInspector()
        applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        inspectorViewController?.reloadTerminalMacros()
        inspectorViewController?.selectTerminalMacrosTab()
        keepSidebarReadableWithoutResizingWindow()
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func showCommandHistoryFromToolbar(_ sender: Any?) {
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.commandHistory, preserving: windowFrame) {
            return
        }
        revealInspector()
        applyDefaultInspectorWidthIfNeeded(force: true, preferredDefaultWidth: defaultInspectorPanelWidth)
        inspectorViewController?.selectCommandHistoryTab()
        keepSidebarReadableWithoutResizingWindow()
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func toggleDeviceDashboardFromToolbar(_ sender: Any?) {
        guard isLicensed(.advancedMetrics) else { return }
        preserveProgrammaticWindowFrame(window?.frame)
        workspaceViewController.toggleDeviceMetricsDashboardVisibility()
    }

    @objc
    public func toggleDeviceDashboardFromMenu(_ sender: Any?) {
        toggleDeviceDashboardFromToolbar(sender)
    }

    @objc
    public func showAIAssistantFromToolbar(_ sender: Any?) {
        guard isLicensed(.aiAgent) else { return }
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.AI.title, preserving: windowFrame) {
            return
        }
        showAIAssistantInspector()
    }

    @objc
    public func toggleInspectorFromToolbar(_ sender: Any?) {
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        guard let inspectorSplitViewItem else {
            return
        }
        let willRevealInspector = inspectorSplitViewItem.isCollapsed
        if willRevealInspector {
            revealInspector()
            if inspectorViewController?.filesViewController?.isEmbeddedCapabilityExpandedForInspectorControls == true {
                prepareInspectorWidthForFilesCapabilityOpen(restoringCollapsedInspector: true)
            } else {
                applyDefaultInspectorWidthIfNeeded()
            }
            scheduleInspectorReadabilityRepair(preserving: windowFrame)
        } else {
            if let inspectorWidth = currentInspectorPanelWidth() {
                pendingInspectorWidth = inspectorWidth
            }
            performProgrammaticSplitLayout {
                inspectorSplitViewItem.isCollapsed = true
            }
        }
        keepSidebarReadableWithoutResizingWindow()
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func toggleSidebarFromToolbar(_ sender: Any?) {
        guard !contentSplitViewController.splitViewItems.isEmpty else {
            return
        }
        let sidebar = contentSplitViewController.splitViewItems[0]
        if isSidebarTemporarilyExpanded {
            isSidebarTemporarilyExpanded = false
            sidebar.isCollapsed = false
            return
        }
        sidebar.isCollapsed.toggle()
    }

    private func temporarilyRevealSidebarFromTitlebarHover() {
        guard !contentSplitViewController.splitViewItems.isEmpty else {
            return
        }
        let sidebar = contentSplitViewController.splitViewItems[0]
        guard sidebar.isCollapsed else {
            return
        }
        isSidebarTemporarilyExpanded = true
        sidebar.isCollapsed = false
    }

    private func hideTemporarilyRevealedSidebarFromTitlebarHover() {
        guard !contentSplitViewController.splitViewItems.isEmpty,
              isSidebarTemporarilyExpanded
        else { return }
        isSidebarTemporarilyExpanded = false
        contentSplitViewController.splitViewItems[0].isCollapsed = true
    }

    public func closeCurrentTerminalFromMenu(_ sender: Any?) {
        guard let title = workspaceViewController.currentTerminalTitle else {
            return
        }
        if settingsStore.snapshot().terminalCloseConfirmationEnabled {
            guard terminalCloseConfirmation.confirmCloseTerminal(title: title, parentWindow: window) else {
                return
            }
        }
        workspaceViewController.closeCurrentTerminal()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isMultiExecBroadcasting
    }

    public func startMultiExecFromToolbar(_ sender: Any?) throws {
        guard isLicensed(.multiExec) else {
            throw LicensedFeatureAccessError.licenseRequired(.multiExec)
        }
        let targets = workspaceViewController.multiExecTargets()
        guard targets.count >= 2 else {
            let error = WorkspaceTerminalError.multiExecRequiresMultipleTargets
            multiExecSessionSelector.presentMultiExecError(error, parentWindow: window)
            throw error
        }
        let currentSplitIDs = workspaceViewController.currentSplitTargetIDs()
        let selectedIDs: [String]
        if currentSplitIDs.count >= 2 {
            selectedIDs = currentSplitIDs
        } else if let selection = multiExecSessionSelector.selectMultiExecTargets(
            targets: targets,
            parentWindow: window
        ) {
            selectedIDs = selection.targetIDs
        } else { return }

        do {
            try workspaceViewController.startMultiExecSession(targetIDs: selectedIDs)
        } catch {
            multiExecSessionSelector.presentMultiExecError(error, parentWindow: window)
            throw error
        }
    }

    @discardableResult
    public func multiExecFromToolbar(_ sender: Any?) throws -> BroadcastAuditEvent? {
        let targets = workspaceViewController.multiExecTargets()
        guard let request = multiExecPromptPresenter.promptMultiExec(targets: targets, parentWindow: window) else {
            return nil
        }

        let selectedTargets = selectedMultiExecTargets(
            requestedIDs: request.targetIDs,
            availableTargets: targets
        )
        isMultiExecBroadcasting = true
        window?.title = L10n.MultiExec.broadcastingWindowTitle
        defer {
            isMultiExecBroadcasting = false
            window?.title = "Stacio"
        }
        let preparedAudit = try multiExecBridge.prepareBroadcastInput(
            targets: selectedTargets,
            input: request.input,
            productionConfirmed: request.productionConfirmed
        )
        let sentCount = workspaceViewController.broadcastInput(request.input, to: request.targetIDs)
        let executedAudit = multiExecBridge.markBroadcastExecuted(
            preparedAudit,
            sentCount: UInt32(sentCount)
        )
        if let databasePath = try? databasePathProvider() {
            _ = try? multiExecAuditRecorder.recordBroadcastAuditEvent(
                databasePath: databasePath,
                event: executedAudit
            )
        }
        return executedAudit
    }

    private func selectedMultiExecTargets(
        requestedIDs: [String],
        availableTargets: [MultiExecTarget]
    ) -> [MultiExecTarget] {
        let availableByID = Dictionary(uniqueKeysWithValues: availableTargets.map { ($0.id, $0) })
        var seenIDs = Set<String>()
        return requestedIDs.compactMap { id in
            guard seenIDs.insert(id).inserted else { return nil }
            if let target = availableByID[id] {
                return target
            }
            return MultiExecTarget(
                id: id,
                label: id,
                environment: "development",
                enabled: true
            )
        }
    }

    @objc
    public func performMultiExecFromToolbar(_ sender: Any?) {
        _ = try? startMultiExecFromToolbar(sender)
    }

    @discardableResult
    public func startRemoteSession(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        let status = try resolvedRemoteSessionStarter().openSessionTab(config: config, title: title)
        keepSidebarReadableWithoutResizingWindow()
        scheduleSidebarReadabilityRepair()
        return status
    }

    @discardableResult
    private func startRemoteSession(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> LiveShellStatus {
        try startRemoteSession(
            config: config,
            title: title,
            automationPolicy: automationPolicy,
            proxyJumpSelection: .disabled,
            proxyJumpSessionResolver: { _ in nil }
        )
    }

    @discardableResult
    private func startRemoteSession(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?,
        credentialRecovery: (@MainActor () -> SshConnectionConfig?)? = nil
    ) throws -> LiveShellStatus {
        if proxyJumpSelection != .disabled,
           isLicensed(.proxyJump) == false {
            throw LicensedFeatureAccessError.licenseRequired(.proxyJump)
        }
        let starter = try resolvedRemoteSessionStarter()
        let status: LiveShellStatus
        if let coordinator = starter as? RemoteSSHSessionCoordinator {
            status = try coordinator.openSessionTab(
                config: config,
                title: title,
                automationPolicy: automationPolicy,
                proxyJumpSelection: proxyJumpSelection,
                proxyJumpSessionResolver: proxyJumpSessionResolver,
                credentialRecovery: credentialRecovery
            )
        } else if let proxyJumpStarter = starter as? RemoteSSHSessionProxyJumpStarting {
            status = try proxyJumpStarter.openSessionTab(
                config: config,
                title: title,
                automationPolicy: automationPolicy,
                proxyJumpSelection: proxyJumpSelection,
                proxyJumpSessionResolver: proxyJumpSessionResolver
            )
        } else if let automationStarter = starter as? RemoteSSHSessionAutomationStarting {
            status = try automationStarter.openSessionTab(
                config: config,
                title: title,
                automationPolicy: automationPolicy
            )
        } else {
            status = try starter.openSessionTab(config: config, title: title)
        }
        keepSidebarReadableWithoutResizingWindow()
        scheduleSidebarReadabilityRepair()
        return status
    }

    @discardableResult
    public func quickConnectFromToolbar(_ sender: Any?) throws -> LiveShellStatus? {
        guard let request = quickConnectPromptPresenter.promptQuickConnect(parentWindow: window) else {
            return nil
        }
        return try connectQuickConnectRequest(request)
    }

    @discardableResult
    private func connectQuickConnectRequest(_ request: QuickConnectRequest) throws -> LiveShellStatus {
        let prepared = try prepareQuickConnectRequest(request)
        do {
            let status = try resolvedQuickConnectCoordinator().connect(prepared.request)
            try saveQuickConnectSessionIfNeeded(prepared.request)
            if !prepared.request.saveAsSession {
                try? cleanupPreparedQuickConnectCredential(prepared)
            }
            sessionSidebarViewController?.reloadSessions()
            return status
        } catch {
            try? cleanupPreparedQuickConnectCredential(prepared)
            throw error
        }
    }

    @objc
    public func performQuickConnectFromToolbar(_ sender: Any?) {
        do {
            _ = try quickConnectFromToolbar(sender)
        } catch {
            quickConnectErrorPresenter.presentQuickConnectError(error, parentWindow: window)
        }
    }

    @discardableResult
    public func importSessionsFromSidebar(_ sidebar: SessionSidebarViewController) throws -> ImportApplyResult? {
        let result = try resolvedSessionImportCoordinator().runImport(parentWindow: window)
        if result?.report.importedCount ?? 0 > 0 {
            sidebar.reloadSessions()
        }
        return result
    }

    @discardableResult
    public func importSessionsFromSidebar(
        _ sidebar: SessionSidebarViewController,
        sourceType: SessionImportSourceType
    ) throws -> ImportApplyResult? {
        let result = try resolvedSessionImportCoordinator().runImport(
            sourceType: sourceType,
            parentWindow: window
        )
        if result?.report.importedCount ?? 0 > 0 {
            sidebar.reloadSessions()
        }
        return result
    }

    public func performImportFromSidebar(_ sidebar: SessionSidebarViewController) {
        do {
            _ = try importSessionsFromSidebar(sidebar)
        } catch {
            sessionImportErrorPresenter.presentSessionImportError(error, parentWindow: window)
        }
    }

    public func performImportFromSidebar(
        _ sidebar: SessionSidebarViewController,
        sourceType: SessionImportSourceType
    ) {
        do {
            _ = try importSessionsFromSidebar(sidebar, sourceType: sourceType)
        } catch {
            sessionImportErrorPresenter.presentSessionImportError(error, parentWindow: window)
        }
    }

    public func openBastionHostConnection(_ request: BastionHostDeepLinkRequest) {
        do {
            try LicenseBastionHostFeatureAuthorizer().authorizeBastionHostAccess()
            guard confirmBastionHostConnection(request) else { return }
            try UserDefaultsBastionHostRequestReplayProtector().consume(request)

            var metadata: [String: Any] = [
                "bastionVendor": request.vendor,
                "bastionRequestId": request.requestID
            ]
            if let value = request.targetHost { metadata["bastionTargetHost"] = value }
            if let value = request.targetPort { metadata["bastionTargetPort"] = value }
            if let value = request.targetUsername { metadata["bastionTargetUsername"] = value }
            if let value = request.assetID { metadata["bastionAssetId"] = value }
            if let value = request.accountID { metadata["bastionAccountId"] = value }
            let configJSON = try String(
                data: JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
                encoding: .utf8
            )
            let target = "\(request.gatewayUsername)@\(request.gatewayHost):\(request.gatewayPort)"
            _ = try connectQuickConnectRequest(
                QuickConnectRequest(
                    target: target,
                    authMode: .agent,
                    saveAsSession: false,
                    sessionName: "\(request.vendor) · \(request.targetHost ?? request.gatewayHost)",
                    configJSON: configJSON
                )
            )
        } catch {
            quickConnectErrorPresenter.presentQuickConnectError(error, parentWindow: window)
        }
    }

    private func confirmBastionHostConnection(_ request: BastionHostDeepLinkRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "允许堡垒机调起 Stacio？"
        let target = request.targetHost ?? request.assetID ?? "未提供目标资产"
        alert.informativeText = "来源：\(request.vendor)\n堡垒机：\(request.gatewayHost):\(request.gatewayPort)\n目标：\(target)\n账号：\(request.gatewayUsername)"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    public func openSavedSession(_ session: SessionRecord) throws -> LiveShellStatus {
        let status = try openSavedSession(session, allowMissingCredentialRepair: true)
        workspaceViewController.setAIHistoryScopeID(
            "session:\(session.id)",
            runtimeID: status.runtimeId
        )
        return status
    }

    @discardableResult
    private func openSavedSession(
        _ session: SessionRecord,
        allowMissingCredentialRepair: Bool
    ) throws -> LiveShellStatus {
        do {
            return try openSavedSessionWithoutCredentialRepair(session)
        } catch {
            guard allowMissingCredentialRepair,
                  isMissingSavedCredentialError(error),
                  let repairedSession = try repairMissingSavedSessionCredentialIfPossible(for: session)
            else {
                throw error
            }
            return try openSavedSession(repairedSession, allowMissingCredentialRepair: false)
        }
    }

    @discardableResult
    private func openSavedSessionWithoutCredentialRepair(_ session: SessionRecord) throws -> LiveShellStatus {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProtocol == "shell" {
            let runtimeID = try workspaceViewController.openLocalShell()
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.localShellOpened)
        }
        if normalizedProtocol == "browser" {
            let title = session.name.isEmpty ? session.host : session.name
            let runtimeID = try workspaceViewController.openBrowserSession(urlString: session.host, title: title)
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.browserOpened)
        }
        if normalizedProtocol == "file" {
            let title = session.name.isEmpty ? session.host : session.name
            let runtimeID = try workspaceViewController.openFileSession(path: session.host, title: title)
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.localFilePaneOpened)
        }
        if normalizedProtocol == "scp" {
            let config = try savedSessionSSHConfig(for: session)
            let context = try resolvedSavedSessionContextBuilder().makeTunnelLiveSessionContext(
                config: config,
                databasePath: databasePathProvider()
            )
            tunnelLiveSessionStore.replace(with: context)
            let title = session.name.isEmpty ? "\(config.username)@\(config.host)" : session.name
            let runtimeID = try workspaceViewController.openRemoteFilesSession(
                context: context,
                title: title,
                bridge: remoteFilesBridge,
                transferScheduler: currentTransferScheduler()
            )
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.scpFilePaneOpened)
        }
        if normalizedProtocol == "ftp" {
            try confirmPlaintextProtocolSession(protocolName: "FTP")
            let context = try resolvedFTPCredentialResolver().resolve(session: session)
            let title = savedSessionTitle(for: session, username: context.config.username)
            let runtimeID = try workspaceViewController.openFTPFilesSession(
                context: context,
                title: title,
                bridge: remoteFilesBridge,
                ftpTransferScheduler: currentFTPTransferScheduler()
            )
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.ftpFilePaneOpened)
        }
        if normalizedProtocol == "telnet" {
            try confirmPlaintextProtocolSession(protocolName: "Telnet")
            let config = TelnetConnectionConfig(
                host: session.host,
                port: try networkPort(for: session),
                username: session.username,
                connectTimeoutMs: 10_000
            )
            let title = savedSessionTitle(for: session, username: session.username)
            let status = try resolvedTelnetSessionStarter().start(config: config, title: title)
            markSavedSessionOpened(session)
            return status
        }
        if normalizedProtocol == "serial" {
            let config = try savedSessionSerialConfig(for: session)
            let title = session.name.isEmpty ? config.devicePath : session.name
            let status = try resolvedSerialSessionStarter().openSessionTab(config: config, title: title)
            markSavedSessionOpened(session)
            return status
        }
        if normalizedProtocol == "vnc" {
            let protocolName = normalizedProtocol.uppercased()
            let adapterPath = graphicsAdapterPathProvider(normalizedProtocol)
            let config = GraphicsAdapterConfig(
                adapterPath: adapterPath,
                host: session.host,
                port: try networkPort(for: session),
                username: session.username
            )
            let launchConfig: GraphicsLaunchConfig?
            let diagnosticStatus: String
            do {
                launchConfig = try CoreBridge.buildVNCLaunchConfig(config)
                diagnosticStatus = L10n.Graphics.diagnosticOnly(protocolName)
            } catch {
                launchConfig = nil
                diagnosticStatus = graphicsConfigDiagnostic(error, protocolName: protocolName)
            }
            let title = session.name.isEmpty ? session.host : session.name
            if let launchConfig {
                let runtimeArguments = try graphicsRuntimeArguments(
                    for: normalizedProtocol,
                    session: session,
                    launchArguments: launchConfig.arguments
                )
                let runtimeStatus = try graphicsRuntimeManager.start(
                    request: GraphicsRuntimeStartRequest(
                        protocolName: protocolName,
                        adapterPath: launchConfig.adapterPath,
                        arguments: runtimeArguments,
                        host: session.host,
                        port: try networkPort(for: session)
                    )
                )
                let diagnostic = GraphicsSessionDiagnostic(
                    protocolName: protocolName,
                    host: session.host,
                    port: try networkPort(for: session),
                    adapterPath: launchConfig.adapterPath,
                    launchArguments: redactedGraphicsLaunchArguments(runtimeArguments),
                    status: runtimeStatus.diagnostic,
                    presentation: runtimeStatus.presentation
                )
                let runtimeID = workspaceViewController.openGraphicsSession(
                    title: title,
                    diagnostic: diagnostic,
                    runtimeID: runtimeStatus.runtimeID,
                    attachment: runtimeStatus.attachment,
                    onClose: { [graphicsRuntimeManager] runtimeID in
                        _ = graphicsRuntimeManager.stop(runtimeID: runtimeID)
                    }
                )
                markSavedSessionOpened(session)
                return LiveShellStatus(
                    runtimeId: runtimeID,
                    status: runtimeStatus.status,
                    diagnostic: runtimeStatus.diagnostic
                )
            }
            let diagnostic = GraphicsSessionDiagnostic(
                protocolName: protocolName,
                host: session.host,
                port: try networkPort(for: session),
                adapterPath: launchConfig?.adapterPath ?? adapterPath,
                launchArguments: launchConfig?.arguments ?? [],
                status: diagnosticStatus
            )
            let runtimeID = workspaceViewController.openGraphicsSession(
                title: title,
                diagnostic: diagnostic
            )
            markSavedSessionOpened(session)
            return LiveShellStatus(
                runtimeId: runtimeID,
                status: "diagnostic",
                diagnostic: diagnosticStatus
            )
        }
        guard normalizedProtocol == "ssh" else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(session.protocol)
        }
        let config = try savedSessionSSHConfig(for: session)
        let proxyJumpSelection = savedSessionProxyJumpSelection(for: session)
        let manualIconID = savedSessionIconID(for: session)
        let databasePath = try databasePathProvider()
        let title = savedSessionTitle(for: session, username: session.username)
        let status = try startRemoteSession(
            config: config,
            title: title,
            automationPolicy: savedSessionAutomationPolicy(for: session),
            proxyJumpSelection: proxyJumpSelection,
            proxyJumpSessionResolver: { id in
                try CoreBridge.listAllSessionRecords(databasePath: databasePath).first(where: { $0.id == id })
            },
            credentialRecovery: { [weak self] in
                self?.recoverSavedSessionPasswordAfterAuthenticationFailure(for: session)
            }
        )
        workspaceViewController.setManualSessionIcon(manualIconID, runtimeID: status.runtimeId)
        markSavedSessionOpened(session)
        return status
    }

    public func openSavedSession(id: String) {
        do {
            let databasePath = try databasePathProvider()
            guard let session = try CoreBridge.listAllSessionRecords(databasePath: databasePath)
                .first(where: { $0.id == id })
            else {
                throw WorkbenchSessionOpenError.savedSessionNotFound(id)
            }
            _ = try openSavedSession(session)
        } catch is CancellationError {
        } catch {
            AppKitSessionSidebarErrorPresenter().present(error, context: .openSession, parentWindow: window)
        }
    }

    private func markSavedSessionOpened(_ session: SessionRecord) {
        if let databasePath = try? databasePathProvider() {
            _ = try? savedSessionOpenRecorder.markSessionRecordOpened(
                databasePath: databasePath,
                id: session.id
            )
        }
    }

    private func isMissingSavedCredentialError(_ error: Error) -> Bool {
        (error as? KeychainCredentialError) == .notFound
    }

    private func repairMissingSavedSessionCredentialIfPossible(for session: SessionRecord) throws -> SessionRecord? {
        guard let request = savedSessionCredentialPromptRequest(for: session) else {
            return nil
        }
        guard let secret = savedSessionCredentialPromptPresenter.promptForSavedSessionCredential(
            request,
            parentWindow: window
        ) else {
            throw CancellationError()
        }

        let databasePath = try databasePathProvider()
        let credentialSaver = resolvedSavedSessionCredentialSaver(databasePath: databasePath)
        let credential = try credentialSaver.saveCredential(
            kind: request.kind.storageKind,
            label: request.label,
            account: request.account,
            secret: secret
        )
        let updatedSession = try CoreBridge.updateSessionRecord(
            databasePath: databasePath,
            id: session.id,
            update: SessionUpdate(
                name: nil,
                protocol: nil,
                folderId: nil,
                host: nil,
                port: nil,
                username: nil,
                privateKeyPath: nil,
                credentialId: credential.id,
                tags: nil,
                configJson: nil
            )
        )
        try? (credentialSaver as? SessionSidebarCredentialCleaning)?.cleanupReplacedCredential(
            previousCredentialID: session.credentialId,
            replacementCredentialID: credential.id
        )
        return updatedSession
    }

    private func recoverSavedSessionPasswordAfterAuthenticationFailure(
        for session: SessionRecord
    ) -> SshConnectionConfig? {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedProtocol == "ssh" || normalizedProtocol == "scp" else {
            return nil
        }

        let displayName = optionalTrimmed(session.name) ?? session.host
        let username = optionalTrimmed(session.username) ?? NSUserName()
        let request = SavedSessionCredentialPromptRequest(
            sessionID: session.id,
            sessionName: displayName,
            protocolName: normalizedProtocol.uppercased(),
            host: session.host,
            account: "\(username)@\(session.host)",
            kind: .password,
            label: savedSessionCredentialLabel(displayName: displayName, kind: .password)
        )
        guard let secret = savedSessionCredentialPromptPresenter.promptForSavedSessionCredential(
            request,
            parentWindow: window
        ), let databasePath = try? databasePathProvider() else {
            return nil
        }

        do {
            let credentialSaver = resolvedSavedSessionCredentialSaver(databasePath: databasePath)
            let credential = try credentialSaver.saveCredential(
                kind: SavedSessionCredentialKind.password.storageKind,
                label: request.label,
                account: request.account,
                secret: secret
            )
            let updatedSession = try CoreBridge.updateSessionRecord(
                databasePath: databasePath,
                id: session.id,
                update: SessionUpdate(
                    name: nil,
                    protocol: nil,
                    folderId: nil,
                    host: nil,
                    port: nil,
                    username: nil,
                    privateKeyPath: session.privateKeyPath == nil ? nil : "",
                    credentialId: credential.id,
                    tags: nil,
                    configJson: nil
                )
            )
            try? (credentialSaver as? SessionSidebarCredentialCleaning)?.cleanupReplacedCredential(
                previousCredentialID: session.credentialId,
                replacementCredentialID: credential.id
            )
            return try savedSessionSSHConfig(for: updatedSession)
        } catch {
            return nil
        }
    }

    private func savedSessionCredentialPromptRequest(
        for session: SessionRecord
    ) -> SavedSessionCredentialPromptRequest? {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayName = optionalTrimmed(session.name) ?? session.host
        switch normalizedProtocol {
        case "ssh", "scp":
            guard optionalTrimmed(session.credentialId) != nil else {
                return nil
            }
            let username = optionalTrimmed(session.username) ?? NSUserName()
            let account = "\(username)@\(session.host)"
            let kind: SavedSessionCredentialKind = optionalTrimmed(session.privateKeyPath) == nil
                ? .password
                : .privateKeyPassphrase
            return SavedSessionCredentialPromptRequest(
                sessionID: session.id,
                sessionName: displayName,
                protocolName: normalizedProtocol.uppercased(),
                host: session.host,
                account: account,
                kind: kind,
                label: savedSessionCredentialLabel(displayName: displayName, kind: kind)
            )
        case "ftp":
            let username = optionalTrimmed(session.username) ?? "anonymous"
            guard username != "anonymous" else {
                return nil
            }
            return SavedSessionCredentialPromptRequest(
                sessionID: session.id,
                sessionName: displayName,
                protocolName: "FTP",
                host: session.host,
                account: "\(username)@\(session.host)",
                kind: .password,
                label: savedSessionCredentialLabel(displayName: displayName, kind: .password)
            )
        case "vnc":
            let username = graphicsUsername(for: session)
            return SavedSessionCredentialPromptRequest(
                sessionID: session.id,
                sessionName: displayName,
                protocolName: normalizedProtocol.uppercased(),
                host: session.host,
                account: "\(username)@\(session.host)",
                kind: .password,
                label: savedSessionCredentialLabel(displayName: displayName, kind: .password)
            )
        default:
            return nil
        }
    }

    private func savedSessionCredentialLabel(
        displayName: String,
        kind: SavedSessionCredentialKind
    ) -> String {
        switch kind {
        case .password:
            return "\(displayName) password"
        case .privateKeyPassphrase:
            return "\(displayName) private key passphrase"
        }
    }

    private func resolvedSavedSessionCredentialSaver(
        databasePath: String
    ) -> SessionSidebarCredentialSaving {
        savedSessionCredentialSaver ?? KeychainSessionSidebarCredentialSaver(databasePath: databasePath)
    }

    private func graphicsConfigDiagnostic(_ error: Error, protocolName: String) -> String {
        guard let graphicsError = error as? GraphicsConfigError else {
            return L10n.Graphics.missingAdapter(protocolName)
        }
        switch graphicsError {
        case .AdapterMissing:
            return L10n.Graphics.missingAdapter(protocolName)
        case .InvalidEndpoint:
            return L10n.Graphics.invalidEndpoint
        }
    }

    private func graphicsRuntimeArguments(
        for normalizedProtocol: String,
        session: SessionRecord,
        launchArguments: [String]
    ) throws -> [String] {
        guard normalizedProtocol == "vnc",
              optionalTrimmed(session.credentialId) != nil
        else {
            return launchArguments
        }
        let password = try savedSessionGraphicsPassword(for: session)
        return argumentsByAddingPassword(password, toGraphicsArguments: launchArguments)
    }

    private func savedSessionGraphicsPassword(for session: SessionRecord) throws -> String {
        guard let credentialID = optionalTrimmed(session.credentialId) else {
            throw KeychainCredentialError.notFound
        }
        return try graphicsCredentialStore.readSecret(
            id: credentialID,
            account: "\(graphicsUsername(for: session))@\(session.host)"
        )
    }

    private func graphicsUsername(for session: SessionRecord) -> String {
        optionalTrimmed(session.username) ?? NSUserName()
    }

    private func argumentsByAddingPassword(_ password: String, toGraphicsArguments arguments: [String]) -> [String] {
        var runtimeArguments = arguments
        let insertionIndex = runtimeArguments.lastIndex(where: { !$0.hasPrefix("-") }) ?? runtimeArguments.endIndex
        runtimeArguments.insert(contentsOf: ["--password", password], at: insertionIndex)
        return runtimeArguments
    }

    private func redactedGraphicsLaunchArguments(_ arguments: [String]) -> [String] {
        var redacted: [String] = []
        var shouldRedactNext = false
        for argument in arguments {
            if shouldRedactNext {
                redacted.append("<redacted>")
                shouldRedactNext = false
                continue
            }
            redacted.append(argument)
            if argument == "--password" || argument == "-p" || argument == "--gw-pass" {
                shouldRedactNext = true
            }
        }
        return redacted
    }

    private func resolvedRemoteSessionStarter() throws -> RemoteSSHSessionStarting {
        if let remoteSessionStarter {
            return remoteSessionStarter
        }
        let starter = try makeDefaultRemoteSessionStarter()
        remoteSessionStarter = starter
        return starter
    }

    private func resolvedSavedSessionContextBuilder() throws -> TunnelLiveSessionContextBuilding {
        if let savedSessionContextBuilder {
            return savedSessionContextBuilder
        }
        let builder = try makeDefaultSavedSessionContextBuilder()
        savedSessionContextBuilder = builder
        return builder
    }

    private func resolvedTelnetSessionStarter() -> TelnetSessionStarting {
        if let telnetSessionStarter {
            return telnetSessionStarter
        }
        let starter = TelnetSessionCoordinator(workspace: workspaceViewController)
        telnetSessionStarter = starter
        return starter
    }

    private func resolvedSerialSessionStarter() -> SerialSessionStarting {
        if let serialSessionStarter {
            return serialSessionStarter
        }
        let starter = SerialSessionCoordinator(workspace: workspaceViewController)
        serialSessionStarter = starter
        return starter
    }

    private func resolvedFTPCredentialResolver() -> FTPCredentialResolving {
        if let ftpCredentialResolver {
            return ftpCredentialResolver
        }
        let resolver = FTPCredentialResolver(store: KeychainCredentialStore())
        ftpCredentialResolver = resolver
        return resolver
    }

    private func resolvedQuickConnectCoordinator() throws -> QuickConnectCoordinator {
        if let quickConnectCoordinator {
            return quickConnectCoordinator
        }
        let coordinator = try QuickConnectCoordinator(remoteSessionStarter: resolvedRemoteSessionStarter())
        quickConnectCoordinator = coordinator
        return coordinator
    }

    private func resolvedSessionImportCoordinator() throws -> SessionImportCoordinating {
        if let sessionImportCoordinator {
            return sessionImportCoordinator
        }
        let coordinator = SessionImportCoordinator(
            databasePath: try databasePathProvider(),
            bastionHostAuthorizer: LicenseBastionHostFeatureAuthorizer(accessProvider: licenseAccess),
            licensedFeatureAuthorizer: LicenseFeatureAuthorizer(accessProvider: licenseAccess)
        )
        sessionImportCoordinator = coordinator
        return coordinator
    }

    private func revealInspector() {
        guard let inspectorSplitViewItem,
              inspectorSplitViewItem.isCollapsed
        else { return }

        layoutWorkbenchContent(in: window)
        let splitView = contentSplitViewController.splitView
        guard splitView.bounds.width > 0 else { return }
        let defaultWidth = defaultInspectorWidth(
            for: splitView.bounds.width,
            preferredWidth: defaultInspectorPanelWidth
        )
        let restoredSidebarWidth = storedSplitWidth(column: "sidebar")
            .map { clampedSidebarWidth($0, availableWidth: splitView.bounds.width) }
            ?? currentSidebarWidthForInspectorSizing(splitWidth: splitView.bounds.width)
        let maximumInitialWidth = max(
            0,
            splitView.bounds.width
                - restoredSidebarWidth
                - minimumWorkspaceWidthWhenOpeningInspector
                - splitView.dividerThickness * 2
        )
        let initialWidth = min(
            pendingInspectorWidth ?? storedSplitWidth(column: "inspector") ?? defaultWidth,
            maximumInitialWidth
        )
        let needsTemporaryWidthCap = initialWidth > 0
            && maximumInitialWidth < minimumInspectorWidthBeforeDeferredUncollapse
        let contentSize = window?.contentView?.bounds.size
        let previousMinimumThickness = inspectorSplitViewItem.minimumThickness
        let previousMaximumThickness = inspectorSplitViewItem.maximumThickness
        performProgrammaticSplitLayout {
            inspectorSplitViewItem.holdingPriority = .defaultLow
            if needsTemporaryWidthCap {
                inspectorSplitViewItem.maximumThickness = initialWidth
                inspectorSplitViewItem.preferredThicknessFraction = initialWidth / splitView.bounds.width
                pendingInspectorWidth = initialWidth
            }
            inspectorSplitViewItem.isCollapsed = false
        }
        guard needsTemporaryWidthCap else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let inspectorSplitViewItem = self.inspectorSplitViewItem
            else { return }

            inspectorSplitViewItem.minimumThickness = previousMinimumThickness
            inspectorSplitViewItem.maximumThickness = previousMaximumThickness
        }
        if let contentSize,
           let contentView = window?.contentView,
           contentView.bounds.size != contentSize
        {
            contentView.setFrameSize(contentSize)
            contentView.layoutSubtreeIfNeeded()
            let targetBounds = NSRect(origin: .zero, size: contentSize)
            let containerView = contentSplitViewController.view
            containerView.frame = targetBounds
            containerView.bounds = targetBounds
            containerView.needsLayout = true
            containerView.layoutSubtreeIfNeeded()
        }
    }

    private func collapseInspectorIfShowingCurrentSection(_ sectionLabel: String, preserving windowFrame: NSRect?) -> Bool {
        guard let inspectorSplitViewItem,
              inspectorSplitViewItem.isCollapsed == false,
              inspectorViewController?.selectedTabLabel == sectionLabel
        else {
            return false
        }

        if let inspectorWidth = currentInspectorPanelWidth() {
            pendingInspectorWidth = inspectorWidth
        }
        performProgrammaticSplitLayout {
            inspectorSplitViewItem.isCollapsed = true
        }
        keepSidebarReadableWithoutResizingWindow()
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
        return true
    }

    private func currentInspectorPanelWidth() -> CGFloat? {
        guard contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return nil }

        let subviews = contentSplitViewController.splitView.arrangedSubviews
        guard subviews.count >= 3,
              subviews[2].isHidden == false,
              subviews[2].frame.width > 0
        else { return nil }

        return subviews[2].frame.width
    }

    private func makeDefaultRemoteSessionStarter() throws -> RemoteSSHSessionStarting {
        let paths = try StacioPaths()
        let sshCoordinator = try makeDefaultSSHConnectionCoordinator()
        return RemoteSSHSessionCoordinator(
            contextBuilder: sshCoordinator,
            contextStore: tunnelLiveSessionStore,
            workspace: workspaceViewController,
            databasePathProvider: { paths.databaseURL.path },
            appLog: StacioLogStore.shared
        )
    }

    private func makeDefaultSavedSessionContextBuilder() throws -> TunnelLiveSessionContextBuilding {
        try makeDefaultSSHConnectionCoordinator()
    }

    private func makeDefaultSSHConnectionCoordinator() throws -> SSHConnectionCoordinator {
        SSHConnectionCoordinator(
            connector: CoreBridgeSSHLiveConnector(),
            credentialResolver: SSHCredentialResolver(store: KeychainCredentialStore()),
            hostKeyConfirmer: AppKitHostKeyConfirmer(),
            tunnelLiveSessionStore: tunnelLiveSessionStore
        )
    }

    private func makeDefaultSessionSidebarStore() -> SessionSidebarStoring? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return CoreBridgeSessionSidebarStore(databasePath: databasePath)
    }

    private func makeDefaultSessionSidebarCredentialManager() -> KeychainSessionSidebarCredentialSaver? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return KeychainSessionSidebarCredentialSaver(databasePath: databasePath)
    }

    private func makeDefaultSessionSidebarSessionEditor(
        credentialSaver: SessionSidebarCredentialSaving?
    ) -> SessionSidebarSessionEditing? {
        return AppKitSessionSidebarSessionEditor(
            credentialSaver: credentialSaver,
            licenseAccess: licenseAccess,
            sessionConfigJSONProvider: { [databasePathProvider] session in
                guard let databasePath = try? databasePathProvider() else {
                    return nil
                }
                return try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id)
            }
        )
    }

    private func savedSessionAuthMethod(for session: SessionRecord) -> SshAuthMethod {
        let credentialID = session.credentialId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let privateKeyPath = session.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !privateKeyPath.isEmpty {
            return .privateKey(
                keyPath: privateKeyPath,
                passphraseRef: credentialID.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        if let credentialID, !credentialID.isEmpty {
            return .password(credentialRef: credentialID)
        }
        return .agent
    }

    private func savedSessionSSHConfig(for session: SessionRecord) throws -> SshConnectionConfig {
        let automationPolicy = savedSessionAutomationPolicy(for: session)
        return SshConnectionConfig(
            host: session.host,
            port: try networkPort(for: session),
            username: session.username ?? NSUserName(),
            authMethod: savedSessionAuthMethod(for: session),
            connectTimeoutMs: automationPolicy.connectTimeoutMs ?? SSHConnectionDefaults.fastConnectTimeoutMs
        )
    }

    private func savedSessionAutomationPolicy(for session: SessionRecord) -> SessionAutomationPolicy {
        guard let databasePath = try? databasePathProvider(),
              let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id)
        else {
            return .default
        }
        return SessionAutomationPolicy.fromConfigJSON(configJSON)
    }

    private func savedSessionIconID(for session: SessionRecord) -> String? {
        guard let databasePath = try? databasePathProvider(),
              let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id)
        else { return nil }
        return SessionIconConfigCodec.iconID(from: configJSON)
    }

    private func savedSessionProxyJumpSelection(for session: SessionRecord) -> SSHProxyJumpSelection {
        guard let databasePath = try? databasePathProvider(),
              let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id)
        else {
            return .disabled
        }
        return SSHProxyJumpConfigCodec.selection(from: configJSON)
    }

    private func savedSessionSerialConfig(for session: SessionRecord) throws -> SerialConnectionConfig {
        if let databasePath = try? databasePathProvider(),
           let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id),
           let data = configJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SavedSerialSessionConfig.self, from: data),
           decoded.kind == "serial" {
            return SerialConnectionConfig(
                devicePath: decoded.devicePath,
                baudRate: decoded.baudRate ?? session.port,
                dataBits: decoded.dataBits ?? 8,
                stopBits: decoded.stopBits ?? 1,
                parity: decoded.parity ?? "none",
                flowControl: decoded.flowControl ?? "none",
                backspaceMode: decoded.backspaceMode ?? "del"
            )
        }

        return SerialConnectionConfig(
            devicePath: session.host,
            baudRate: session.port,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )
    }

    private func networkPort(for session: SessionRecord) throws -> UInt16 {
        guard session.port > 0, session.port <= UInt32(UInt16.max) else {
            throw WorkbenchSessionOpenError.invalidSavedSessionPort(session.protocol, session.port)
        }
        return UInt16(session.port)
    }

    private func savedSessionTitle(for session: SessionRecord, username: String?) -> String {
        if !session.name.isEmpty {
            return session.name
        }
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedUsername.isEmpty {
            return "\(trimmedUsername)@\(session.host)"
        }
        return session.host
    }

    private func confirmPlaintextProtocolSession(protocolName: String) throws {
        let message = L10n.Workbench.plaintextProtocolWarningMessage(protocolName: protocolName)
        guard plaintextProtocolSessionConfirmation.confirmPlaintextProtocolSession(
            protocolName: protocolName,
            message: message,
            parentWindow: window
        ) else {
            throw CancellationError()
        }
    }

    private func currentTransferScheduler() -> SCPTransferScheduling? {
        guard let inspectorViewController else {
            return nil
        }
        _ = inspectorViewController.view
        return inspectorViewController.transferQueueCoordinator
    }

    private func currentFTPTransferScheduler() -> FTPTransferScheduling? {
        guard let inspectorViewController else {
            return nil
        }
        _ = inspectorViewController.view
        return inspectorViewController.transferQueueCoordinator
    }

    private func scheduleTerminalDroppedUploads(
        pane: RemoteTerminalPaneViewController,
        remoteDirectory: String,
        localPaths: [String]
    ) {
        if inspectorViewController?.scheduleDroppedUploadsForBoundRemoteFiles(
            runtimeID: pane.runtimeID,
            remoteDirectory: remoteDirectory,
            localPaths: localPaths
        ) == true {
            return
        }

        guard let context = pane.liveSessionContext,
              let transferScheduler = currentTransferScheduler()
        else {
            return
        }

        let filesViewController = FilesViewController(settingsStore: settingsStore)
        _ = filesViewController.view
        let coordinator = FilesCoordinator(
            bridge: remoteFilesBridge,
            filesViewController: filesViewController
        )
        coordinator.scheduleDroppedUploads(
            localPaths: localPaths,
            remoteDirectory: remoteDirectory,
            runtimeID: pane.runtimeID,
            context: context,
            transferScheduler: transferScheduler
        )
    }

    private struct PreparedQuickConnectRequest {
        let request: QuickConnectRequest
        let createdCredentialID: String?
    }

    private func prepareQuickConnectRequest(_ request: QuickConnectRequest) throws -> PreparedQuickConnectRequest {
        guard let secret = request.temporarySecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty,
              request.authMode != .agent
        else {
            return PreparedQuickConnectRequest(request: request, createdCredentialID: nil)
        }

        guard let credentialSaver = resolvedQuickConnectCredentialSaver() else {
            throw QuickConnectError.credentialStorageUnavailable
        }
        let target = try CoreBridge.parseQuickConnect(request.target)
        let username = target.username ?? NSUserName()
        let sessionName = quickConnectSessionName(for: request, username: username, host: target.host)
        let kind: String
        let label: String
        switch request.authMode {
        case .agent:
            return PreparedQuickConnectRequest(request: request, createdCredentialID: nil)
        case .password:
            kind = "password"
            label = "\(sessionName) password"
        case .privateKey:
            kind = "private_key_passphrase"
            label = "\(sessionName) private key passphrase"
        }
        let credential = try credentialSaver.saveCredential(
            kind: kind,
            label: label,
            account: "\(username)@\(target.host)",
            secret: secret
        )
        return PreparedQuickConnectRequest(
            request: request.withCredentialID(credential.id),
            createdCredentialID: credential.id
        )
    }

    private func saveQuickConnectSessionIfNeeded(_ request: QuickConnectRequest) throws {
        guard request.saveAsSession else {
            return
        }
        let databasePath = try databasePathProvider()
        let target = try CoreBridge.parseQuickConnect(request.target)
        let username = target.username ?? NSUserName()
        _ = try CoreBridge.createSessionRecord(
            databasePath: databasePath,
            draft: SessionDraft(
                folderId: nil,
                name: quickConnectSessionName(for: request, username: username, host: target.host),
                protocol: "ssh",
                host: target.host,
                port: UInt32(target.port),
                username: username,
                privateKeyPath: request.authMode == .privateKey ? optionalTrimmed(request.privateKeyPath) : nil,
                credentialId: optionalTrimmed(request.credentialID),
                tags: [],
                configJson: nil
            )
        )
    }

    private func cleanupPreparedQuickConnectCredential(_ prepared: PreparedQuickConnectRequest) throws {
        guard let createdCredentialID = prepared.createdCredentialID else {
            return
        }
        try resolvedQuickConnectCredentialSaver()?.cleanupReplacedCredential(
            previousCredentialID: createdCredentialID,
            replacementCredentialID: nil
        )
    }

    private func resolvedQuickConnectCredentialSaver() -> (SessionSidebarCredentialSaving & SessionSidebarCredentialCleaning)? {
        if let quickConnectCredentialSaver {
            return quickConnectCredentialSaver
        }
        return makeDefaultSessionSidebarCredentialManager()
    }

    private func quickConnectSessionName(
        for request: QuickConnectRequest,
        username: String,
        host: String
    ) -> String {
        optionalTrimmed(request.sessionName) ?? "\(username)@\(host)"
    }

    private func optionalTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
