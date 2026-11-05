import AppKit
import StacioCoreBindings

private struct WorkbenchUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private enum InspectorConversationAssemblyError: Error {
    case hostUnavailable
    case toolCatalogUnavailable
    case terminalToolUnavailable
}

public final class SidebarToggleTitlebarButton: NSButton {
    public var onPointerEntered: (() -> Void)?
    public var onPointerExited: (() -> Void)?
    var iconOnlyWidthConstraint: NSLayoutConstraint?
    var iconOnlyHeightConstraint: NSLayoutConstraint?
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

private final class WorkbenchRootView: NSView, StacioEffectiveAppearanceRefreshHandling {
    override var fittingSize: NSSize {
        // spec: fix-workbench-window-resize — flag=true 时使用默认 fittingSize，
        // 让 AppKit 正确计算 zoom 的 standardFrame/userFrame 切换；
        // flag=false 时保留修复前的 bounds.size 覆写（回滚通道）
        if WorkbenchWindowController.workbenchResizeFixEnabled {
            return super.fittingSize
        }
        return bounds.size
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameSize(_ newSize: NSSize) {
        // spec: fix-workbench-window-resize — flag=true 时移除 constrainedContentSize 钳制，
        // 让 contentView 自由适配 window resize（原先的钳制在 window.frame 未更新时
        // 会把 contentView 锁回旧尺寸，导致初始状态无法拖大窗口）；
        // flag=false 时保留修复前行为（回滚通道）
        if WorkbenchWindowController.workbenchResizeFixEnabled {
            super.setFrameSize(newSize)
        } else {
            super.setFrameSize(constrainedContentSize(newSize))
        }
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
    case protocolRemoved(String, replacement: String)
    case invalidSavedSessionPort(String, UInt32)
    case savedSessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .protocolRuntimeUnavailable(let sessionProtocol):
            return "当前 Stacio 尚未接入 \(sessionProtocol) 会话运行时。"
        case let .protocolRemoved(sessionProtocol, replacement):
            return "\(sessionProtocol) 会话已从 Stacio 移除，请改用 \(replacement) 新建安全文件传输会话。"
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
        controller?.refreshPanelMenuAvailability(menu)
    }
}

struct RemoteZshInstallPromptState {
    private var flowsInProgress: Set<String> = []
    private var promptedFlows: Set<String> = []

    mutating func beginFlow(_ flowKey: String) -> Bool {
        guard promptedFlows.contains(flowKey) == false else { return false }
        return flowsInProgress.insert(flowKey).inserted
    }

    mutating func beginPrompt(_ flowKey: String) -> Bool {
        guard flowsInProgress.contains(flowKey) else { return false }
        return promptedFlows.insert(flowKey).inserted
    }

    mutating func finishFlow(_ flowKey: String) {
        flowsInProgress.remove(flowKey)
    }

    func containsFlow(_ flowKey: String) -> Bool {
        flowsInProgress.contains(flowKey)
    }
}

@MainActor
public final class WorkbenchWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private struct RememberedSSHInspectorState {
        let wasExpanded: Bool
        let selection: InspectorViewController.SelectionSnapshot
    }

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
    /// Oh My Zsh 自动应用协调器：监听设置变更，部署到本机 + 所有远程 SSH 会话。
    private let ohMyZshAutoApplier = OhMyZshAutoApplier()
    private var ohMyZshAutoApplierStarted = false
    private var remoteZshInstallPromptState = RemoteZshInstallPromptState()
    private var remoteZshInstallPollTokens: [String: UUID] = [:]
    private var telnetSessionStarter: TelnetSessionStarting?
    private var systemAppearanceObserver: NSObjectProtocol?
    private var licenseAuthorizationObserver: NSObjectProtocol?
    private var shortcutStoreObserver: NSObjectProtocol?
    private let licensedFeatureMenuDelegate = WorkbenchLicensedFeatureMenuDelegate()
    private var serialSessionStarter: SerialSessionStarting?
    private var consoleSessionStarter: ConsoleSessionStarting?
    private var savedSessionContextBuilder: TunnelLiveSessionContextBuilding?
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
    private let savedSessionAuthenticationPromptPresenter: SavedSessionAuthenticationPrompting
    private let savedSessionPasswordSavingConfirmation: SavedSessionPasswordSavingConfirming
    private let savedSessionCredentialSaver: SessionSidebarCredentialSaving?
    private let quickConnectCredentialSaver: (SessionSidebarCredentialSaving & SessionSidebarCredentialCleaning)?
    private let fileTransferRemoteSessionDraftProvider: ((String, NSWindow?) -> SessionDraft?)?
    private let graphicsCredentialStore: KeychainCredentialStore
    private let telnetCredentialStore: KeychainCredentialStore
    private let aiAPIKeyStore: AIApiKeyStoring
    private let aiHTTPTransport: AIAssistantHTTPTransport
    private let aiConversationRuntimeFactoryOverride: InspectorConversationRuntimeFactory?
    private let aiConversationCatalogLoader: ConversationSessionCatalogLoadOperation
    private let aiLocalAgentToolResolver: LocalAgentToolResolving
    private let aiLocalAgentProcessLauncherFactory: () -> LocalTerminalProcessLaunching
    private let aiLocalAgentRuntimeLaunchAuthorizerProvider: () -> LocalAgentRuntimeLaunchAuthorizing?
    private let databasePathProvider: () throws -> String
    private let transferHistoryStore: SCPTransferHistoryStoring?
    private let transferQueueCoordinatorFactory: ((TransferQueueViewController) -> TransferQueueCoordinator)?
    private var fileTransferQueueViewController: TransferQueueViewController?
    private var fileTransferQueueCoordinator: TransferQueueCoordinator?
    private let settingsStore: AppSettingsStore
    private let assistantSettingsValueStoreProvider: @MainActor () -> AssistantSettingsValueStore?
    private let agentActionConfirmer: AgentActionConfirming
    private let graphicsAdapterPathProvider: (String) -> String?
    private let graphicsRuntimeManager: GraphicsRuntimeManaging
    private let rdpSessionFormPresenter: @MainActor (
        NSWindow,
        RDPSessionFormPrefill,
        @escaping (RDPSessionFormResult?) -> Void
    ) -> Void
    private lazy var graphicsFileUploadCoordinator = GraphicsFileUploadCoordinator()
    private let sparkleUpdateController: SparkleUpdateButtonControlling?
    private let frameAutosaveName: NSWindow.FrameAutosaveName
    private let remoteEditorPresentationStore: any RemoteEditorPresentationStoring
    private let remoteEditorScreenProvider: any RemoteEditorScreenProviding
    private let remoteEditorCloseConfirmer: any RemoteTextEditorCloseConfirming
    public private(set) var centerContainerViewController: WorkbenchCenterContainerViewController?
    public private(set) var remoteEditorPresentationCoordinator: RemoteEditorPresentationCoordinator?
    private weak var sidebarSplitViewItem: NSSplitViewItem?
    private weak var inspectorSplitViewItem: NSSplitViewItem?
    private var toolbarCustomizationWindowController: WorkbenchToolbarCustomizationWindowController?
    private var assistantQuickSettingsWindowController: AssistantQuickSettingsWindowController?
    private var workbenchContentWidthStayConstraint: NSLayoutConstraint?
    private var workbenchContentHeightStayConstraint: NSLayoutConstraint?
    private var isSystemZoomingWindow = false
    /// 运行时即时回滚开关：false 时恢复修复前的 live-resize 行为（spec: fix-workbench-window-resize）
    fileprivate static let workbenchResizeFixEnabled = true
    private var agentExecutionCoordinator: AgentExecutionCoordinator?
    private var splitResizeObserver: NSObjectProtocol?
    private var isMultiExecBroadcasting = false
    private var closePendingAIAssistantShutdown = false
    private var isUserLiveResizingWindow = false
    private var isRestoringWindowFrame = false
    private var didFinishInitialWindowPlacement = false
    private var didApplyInitialSplitColumnWidths = false
    private var programmaticSplitLayoutDepth = 0
    private var splitWidthPersistenceSuppressionDepth = 0
    private var splitPositionOverrideDepth = 0
    private var pendingInspectorWidth: CGFloat?
    private var pendingSidebarWidth: CGFloat?
    private var preservedInspectorWidthDuringSidebarMove: CGFloat?
    private var isPendingInspectorWidthRepairScheduled = false
    private var lastInspectorSessionProtocol: WorkspaceSessionProtocol = .noSession
    private var rememberedSSHInspectorState: RememberedSSHInspectorState?
    private var interactiveSplitResizeWorkItem: DispatchWorkItem?
    private var splitWidthPersistenceWorkItem: DispatchWorkItem?
    private var isInteractiveSplitResizeActive = false
    var pendingApplicationTerminationCompletion: ((Bool) -> Void)?
    private var allowNextWindowClose = false
    private var isWindowClosePending = false
    private var allowsUserSplitWidthPersistence = false
    private var isSidebarTemporarilyExpanded = false
    private var pendingProgrammaticWindowFrameRestore: NSRect?
    private var rootContentViewController: NSViewController?
    private let minimumReadableSidebarWidth: CGFloat = 220
    private let minimumWorkspaceWidthWhenOpeningInspector: CGFloat = 248
    private let defaultInspectorPanelWidth: CGFloat = 320
    private let unrestrictedInspectorPanelWidth: CGFloat = 100_000
    private let splitResizeSettleInterval: TimeInterval = 0.08

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
    }

    private static let toolbarIdentifier = NSToolbar.Identifier("Stacio.Toolbar")
    private static let toolbarAutosaveDefaultsKey = "NSToolbar Configuration Stacio.Toolbar"
    private static let toolbarShowsLabelsDefaultsKey = "Stacio.Toolbar.showsLabels"
    private static let legacyUpdatePromptToolbarIdentifier = "Stacio.Toolbar.updatePrompt"

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
        consoleSessionStarter: ConsoleSessionStarting? = nil,
        savedSessionContextBuilder: TunnelLiveSessionContextBuilding? = nil,
        quickConnectPromptPresenter: QuickConnectPromptPresenting = AppKitQuickConnectPromptPresenter(),
        quickConnectErrorPresenter: QuickConnectErrorPresenting? = nil,
        multiExecPromptPresenter: MultiExecPromptPresenting = AppKitMultiExecPromptPresenter(),
        multiExecSessionSelector: MultiExecSessionSelecting = AppKitMultiExecSessionSelector(),
        multiExecBridge: MultiExecPreparing = CoreBridgeMultiExecBridge(),
        multiExecAuditRecorder: MultiExecAuditRecording = CoreBridgeMultiExecAuditRecorder(),
        terminalCloseConfirmation: TerminalCloseConfirming = AppKitTerminalCloseConfirmation(),
        plaintextProtocolSessionConfirmation: PlaintextProtocolSessionConfirming = AppKitPlaintextProtocolSessionConfirmation(),
        settingsStore: AppSettingsStore = .shared,
        assistantSettingsValueStoreProvider: @escaping @MainActor () -> AssistantSettingsValueStore? = {
            AssistantSettingsLiveStore.sharedIfAvailable()
        },
        agentActionConfirmer: AgentActionConfirming? = nil,
        sessionImportCoordinator: SessionImportCoordinating? = nil,
        sessionImportErrorPresenter: SessionImportErrorPresenting? = nil,
        savedSessionOpenRecorder: SavedSessionOpenRecording = CoreBridgeSavedSessionOpenRecorder(),
        savedSessionCredentialPromptPresenter: SavedSessionCredentialPrompting? = nil,
        savedSessionAuthenticationPromptPresenter: SavedSessionAuthenticationPrompting? = nil,
        savedSessionPasswordSavingConfirmation: SavedSessionPasswordSavingConfirming? = nil,
        savedSessionCredentialSaver: SessionSidebarCredentialSaving? = nil,
        quickConnectCredentialSaver: (SessionSidebarCredentialSaving & SessionSidebarCredentialCleaning)? = nil,
        fileTransferRemoteSessionDraftProvider: ((String, NSWindow?) -> SessionDraft?)? = nil,
        graphicsCredentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        telnetCredentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        aiAPIKeyStore: AIApiKeyStoring = KeychainAIApiKeyStore(),
        aiHTTPTransport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(),
        aiConversationRuntimeFactoryOverride: InspectorConversationRuntimeFactory? = nil,
        aiConversationCatalogLoader: @escaping ConversationSessionCatalogLoadOperation = {
            try ConversationSessionCatalogLoader().load()
        },
        aiLocalAgentToolResolver: LocalAgentToolResolving = LocalAgentToolResolver.production(),
        aiLocalAgentProcessLauncherFactory: @escaping () -> LocalTerminalProcessLaunching = {
            SwiftTermLocalTerminalProcessLauncher()
        },
        aiLocalAgentRuntimeLaunchAuthorizerProvider: @escaping () -> LocalAgentRuntimeLaunchAuthorizing? = {
            LocalAgentRuntimeLaunchCoordinator.sharedIfAvailable()
        },
        databasePathProvider: @escaping () throws -> String = { try StacioPaths().databaseURL.path },
        transferHistoryStore: SCPTransferHistoryStoring? = nil,
        transferQueueCoordinatorFactory: ((TransferQueueViewController) -> TransferQueueCoordinator)? = nil,
        graphicsRuntimeManager: GraphicsRuntimeManaging = DefaultGraphicsRuntimeManager(),
        rdpSessionFormPresenter: @escaping @MainActor (
            NSWindow,
            RDPSessionFormPrefill,
            @escaping (RDPSessionFormResult?) -> Void
        ) -> Void = { window, prefill, completion in
            RDPSessionFormViewController.present(
                on: window,
                prefill: prefill,
                completionHandler: completion
            )
        },
        sparkleUpdateController: SparkleUpdateButtonControlling? = nil,
        graphicsAdapterPathProvider: @escaping (String) -> String? = { protocolName in
            let adapterURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Adapters", isDirectory: true)
                .appendingPathComponent(protocolName.lowercased(), isDirectory: false)
            return FileManager.default.isExecutableFile(atPath: adapterURL.path) ? adapterURL.path : nil
        },
        frameAutosaveName: NSWindow.FrameAutosaveName = NSWindow.FrameAutosaveName("Stacio.WorkbenchWindow.v4"),
        remoteEditorPresentationStore: (any RemoteEditorPresentationStoring)? = nil,
        remoteEditorScreenProvider: (any RemoteEditorScreenProviding)? = nil,
        remoteEditorCloseConfirmer: (any RemoteTextEditorCloseConfirming)? = nil
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
        self.consoleSessionStarter = consoleSessionStarter
        self.savedSessionContextBuilder = savedSessionContextBuilder
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
        self.savedSessionAuthenticationPromptPresenter = savedSessionAuthenticationPromptPresenter
            ?? AppKitSavedSessionAuthenticationPromptPresenter()
        self.savedSessionPasswordSavingConfirmation = savedSessionPasswordSavingConfirmation
            ?? AppKitSavedSessionPasswordSavingConfirmation()
        self.savedSessionCredentialSaver = savedSessionCredentialSaver
        self.quickConnectCredentialSaver = quickConnectCredentialSaver
        self.fileTransferRemoteSessionDraftProvider = fileTransferRemoteSessionDraftProvider
        self.graphicsCredentialStore = graphicsCredentialStore
        self.telnetCredentialStore = telnetCredentialStore
        self.aiAPIKeyStore = aiAPIKeyStore
        self.aiHTTPTransport = aiHTTPTransport
        self.aiConversationRuntimeFactoryOverride = aiConversationRuntimeFactoryOverride
        self.aiConversationCatalogLoader = aiConversationCatalogLoader
        self.aiLocalAgentToolResolver = aiLocalAgentToolResolver
        self.aiLocalAgentProcessLauncherFactory = aiLocalAgentProcessLauncherFactory
        self.aiLocalAgentRuntimeLaunchAuthorizerProvider = aiLocalAgentRuntimeLaunchAuthorizerProvider
        self.databasePathProvider = databasePathProvider
        self.transferHistoryStore = transferHistoryStore
        self.transferQueueCoordinatorFactory = transferQueueCoordinatorFactory
        self.settingsStore = settingsStore
        self.assistantSettingsValueStoreProvider = assistantSettingsValueStoreProvider
        self.agentActionConfirmer = agentActionConfirmer ?? AppKitAgentActionConfirmer()
        self.graphicsRuntimeManager = graphicsRuntimeManager
        self.rdpSessionFormPresenter = rdpSessionFormPresenter
        self.sparkleUpdateController = sparkleUpdateController
        self.graphicsAdapterPathProvider = graphicsAdapterPathProvider
        self.frameAutosaveName = frameAutosaveName
        self.remoteEditorPresentationStore = remoteEditorPresentationStore
            ?? UserDefaultsRemoteEditorPresentationStore(
                defaults: .standard,
                frameAutosaveName: frameAutosaveName
            )
        self.remoteEditorScreenProvider = remoteEditorScreenProvider
            ?? AppKitRemoteEditorScreenProvider()
        self.remoteEditorCloseConfirmer = remoteEditorCloseConfirmer
            ?? AppKitRemoteTextEditorCloseConfirmer()
        super.init(window: nil)
        licensedFeatureMenuDelegate.controller = self
        licenseAuthorizationObserver = NotificationCenter.default.addObserver(
            forName: .stacioLicenseAuthorizationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.remoteEditorPresentationCoordinator?.refreshLicenseState()
                self?.refreshToolbarItemAvailability()
            }
        }
        shortcutStoreObserver = NotificationCenter.default.addObserver(
            forName: StacioShortcutStore.didChangeNotification,
            object: StacioShortcutStore.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshToolbarShortcutTooltips()
            }
        }
        workspaceViewController.onRequestNewSession = { [weak self] in
            self?.performNewSessionFromToolbar(nil)
        }
        workspaceViewController.fileTransferRemoteDeviceOptionsProvider = { [weak self] in
            self?.fileTransferRemoteDeviceOptions() ?? []
        }
        workspaceViewController.onRequestConnectFileTransferRemoteDevice = { [weak self] filesPane, sessionID in
            self?.connectFileTransferRemoteDevice(sessionID: sessionID, to: filesPane)
        }
        workspaceViewController.onRequestCreateFileTransferRemoteDevice = { [weak self] filesPane, protocolName in
            self?.createFileTransferRemoteDevice(protocolName: protocolName, in: filesPane)
        }
        workspaceViewController.onSaveWorkspaceSessionGroup = { [weak self] name, definition in
            guard let self else {
                throw WorkspaceSessionGroupSaveError.persistenceUnavailable
            }
            _ = try self.saveWorkspaceSessionGroup(name: name, definition: definition)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        interactiveSplitResizeWorkItem?.cancel()
        splitWidthPersistenceWorkItem?.cancel()
        if let splitResizeObserver {
            NotificationCenter.default.removeObserver(splitResizeObserver)
        }
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
        }
        if let licenseAuthorizationObserver {
            NotificationCenter.default.removeObserver(licenseAuthorizationObserver)
        }
        if let shortcutStoreObserver {
            NotificationCenter.default.removeObserver(shortcutStoreObserver)
        }
    }

    public override func showWindow(_ sender: Any?) {
        if window == nil {
            loadWindow()
        }
        super.showWindow(sender)
        configureOhMyZshAutoApplierIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window
            else { return }
            self.updateInspectorToolbarTopInset(in: window)
            self.layoutWorkbenchContent(in: window)
            self.restoreStoredSidebarWidthIfNeeded(
                in: self.contentSplitViewController.splitView
            )
            self.allowsUserSplitWidthPersistence = true
            if self.workspaceViewController.currentTerminalPane == nil {
                window.makeFirstResponder(window.contentView)
            } else {
                self.workspaceViewController.focusCurrentTerminalForKeyboardInput()
            }
        }
    }

    /// 一次性注入 Oh My Zsh 自动应用回调并启动监听。
    /// remoteApplyHandler 枚举所有运行中的 SSH 会话并部署/移除；localTerminalPanesProvider 提供本地终端供重载。
    private func configureOhMyZshAutoApplierIfNeeded() {
        guard ohMyZshAutoApplierStarted == false else { return }
        ohMyZshAutoApplierStarted = true
        ohMyZshAutoApplier.localTerminalPanesProvider = { [weak self] in
            self?.workspaceViewController.localTerminalPanes() ?? []
        }
        ohMyZshAutoApplier.remoteApplyHandler = { [weak self] settings, lease, completion in
            guard let self else {
                completion(.failure(CocoaError(.userCancelled)))
                return
            }
            // This closure is MainActor-isolated. Capture only pure connection values before
            // leaving AppKit; never enumerate tabs or panes from the deployment queue.
            let targets = self.workspaceViewController.runningSSHTerminalPanes().map(\.context)
            guard targets.isEmpty == false else {
                completion(.success(()))
                return
            }
            let resourceURL = lease?.directoryURL
            if settings.ohmyzshEnabled, resourceURL == nil {
                completion(.failure(OhMyZshResourceError.integrityValidationFailed))
                return
            }
            let settingsBox = WorkbenchUncheckedSendable(value: settings)
            DispatchQueue.global(qos: .userInitiated).async {
                let settings = settingsBox.value
                var firstError: Error?
                var failures: [(context: TunnelLiveSessionContext, error: Error)] = []
                for target in targets {
                    // Enabled deployments must consume the exact verified lease snapshot.
                    let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: resourceURL)
                    do {
                        if settings.ohmyzshEnabled {
                            try deployer.deploy(
                                config: target.config,
                                secret: target.secret,
                                expectedFingerprintSHA256: target.expectedFingerprintSHA256,
                                global: settings
                            )
                        } else {
                            try deployer.remove(
                                config: target.config,
                                secret: target.secret,
                                expectedFingerprintSHA256: target.expectedFingerprintSHA256
                            )
                        }
                    } catch {
                        if firstError == nil { firstError = error }
                        failures.append((target, error))
                    }
                }
                Task { @MainActor in
                    if let firstError {
                        let liveTargets = self.workspaceViewController.runningSSHTerminalPanes()
                        for failure in failures
                            where failure.error as? RemoteOhMyZshDeployerError == .zshNotAvailable {
                            let failureKey = self.remoteZshInstallFlowKey(failure.context)
                            if let liveTarget = liveTargets.first(where: {
                                self.remoteZshInstallFlowKey($0.context) == failureKey
                            }) {
                                self.handleRemoteOhMyZshApplyFailure(
                                    failure.error,
                                    context: liveTarget.context,
                                    pane: liveTarget.pane
                                )
                            }
                        }
                        completion(.failure(firstError))
                    } else {
                        if settings.ohmyzshEnabled {
                            self.workspaceViewController.runningSSHTerminalPanes().forEach {
                                $0.pane.reloadOhMyZshShellSafely()
                            }
                        }
                        completion(.success(()))
                    }
                }
            }
        }
        ohMyZshAutoApplier.onApplyFinished = { result in
            guard case let .failure(error) = result else { return }
            StacioLogStore.shared.append(
                level: .error,
                category: "OhMyZsh",
                message: "automatic_apply_failed: \(error.localizedDescription)"
            )
        }
        ohMyZshAutoApplier.start()
    }

    @MainActor
    private func handleRemoteOhMyZshApplyFailure(
        _ error: Error,
        context: TunnelLiveSessionContext,
        pane: RemoteTerminalPaneViewController
    ) {
        StacioLogStore.shared.append(
            level: .error,
            category: "OhMyZsh",
            message: "remote_auto_apply_failed: \(error.localizedDescription)"
        )
        guard error as? RemoteOhMyZshDeployerError == .zshNotAvailable else {
            OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                host: context.config.host,
                message: error.localizedDescription
            )
            return
        }

        let flowKey = remoteZshInstallFlowKey(context)
        guard remoteZshInstallPromptState.beginFlow(flowKey) else { return }
        let contextBox = WorkbenchUncheckedSendable(value: context)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak pane] in
            let context = contextBox.value
            let result = Result {
                try RemoteZshInstaller().detectPlan(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256
                )
            }
            Task { @MainActor [weak self, weak pane] in
                guard let self else { return }
                guard let pane else {
                    self.finishRemoteZshInstallFlow(flowKey)
                    return
                }
                switch result {
                case let .success(plan?):
                    self.presentRemoteZshInstallationConfirmation(
                        plan: plan,
                        flowKey: flowKey,
                        context: context,
                        pane: pane
                    )
                case .success(nil):
                    self.finishRemoteZshInstallFlow(flowKey)
                    OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                        host: context.config.host,
                        message: RemoteZshInstallerError.unsupportedPackageManager.localizedDescription
                    )
                case let .failure(detectionError):
                    self.finishRemoteZshInstallFlow(flowKey)
                    OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                        host: context.config.host,
                        message: detectionError.localizedDescription
                    )
                }
            }
        }
    }

    @MainActor
    private func presentRemoteZshInstallationConfirmation(
        plan: RemoteZshInstallationPlan,
        flowKey: String,
        context: TunnelLiveSessionContext,
        pane: RemoteTerminalPaneViewController
    ) {
        guard remoteZshInstallPromptState.containsFlow(flowKey) else { return }
        guard plan.authorization != .unavailable else {
            finishRemoteZshInstallFlow(flowKey)
            OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                host: context.config.host,
                message: RemoteZshInstallerError.authorizationUnavailable.localizedDescription
            )
            return
        }

        if let window, window.attachedSheet != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak pane] in
                guard let self else { return }
                guard let pane else {
                    self.finishRemoteZshInstallFlow(flowKey)
                    return
                }
                self.presentRemoteZshInstallationConfirmation(
                    plan: plan,
                    flowKey: flowKey,
                    context: context,
                    pane: pane
                )
            }
            return
        }

        guard remoteZshInstallPromptState.beginPrompt(flowKey) else {
            finishRemoteZshInstallFlow(flowKey)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Workbench.remoteZshInstallTitle(host: context.config.host)
        alert.informativeText = L10n.Workbench.remoteZshInstallMessage(
            system: plan.packageManager.displayName,
            requiresInteractiveAuthorization: plan.requiresInteractiveAuthorization
        )
        alert.accessoryView = remoteZshInstallCommandPreview(plan.terminalCommand)
        alert.addButton(withTitle: L10n.Workbench.remoteZshInstallConfirm)
        alert.addButton(withTitle: L10n.Common.cancel)

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self, weak pane] response in
            guard let self else { return }
            guard let pane else {
                self.finishRemoteZshInstallFlow(flowKey)
                return
            }
            guard response == .alertFirstButtonReturn else {
                self.finishRemoteZshInstallFlow(flowKey)
                return
            }
            let markerPath = "/tmp/stacio-zsh-install-\(UUID().uuidString.lowercased()).ready"
            let command = "\(plan.terminalCommand) && printf 'ready\\n' > \(markerPath)"
            let sent = pane.sendAgentInput(Array((command + "\n").utf8))
            guard sent else {
                self.finishRemoteZshInstallFlow(flowKey)
                OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                    host: context.config.host,
                    message: "当前 SSH 终端不可输入，未发送 zsh 安装命令。"
                )
                return
            }
            self.pollRemoteZshInstallation(
                flowKey: flowKey,
                context: context,
                pane: pane,
                markerPath: markerPath,
                remainingAttempts: 60
            )
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    @MainActor
    private func remoteZshInstallCommandPreview(_ command: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 52))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 6

        let label = NSTextField(wrappingLabelWithString: command)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 7),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -7)
        ])
        return container
    }

    @MainActor
    private func pollRemoteZshInstallation(
        flowKey: String,
        context: TunnelLiveSessionContext,
        pane: RemoteTerminalPaneViewController,
        markerPath: String,
        remainingAttempts: Int,
        token: UUID? = nil
    ) {
        let pollToken = token ?? UUID()
        remoteZshInstallPollTokens[flowKey] = pollToken
        let contextBox = WorkbenchUncheckedSendable(value: context)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self, weak pane] in
            let context = contextBox.value
            let isAvailable = (try? RemoteZshInstaller().consumeSuccessfulInstallationMarker(
                markerPath,
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256
            )) == true
            Task { @MainActor [weak self, weak pane] in
                guard let self,
                      self.remoteZshInstallPollTokens[flowKey] == pollToken else {
                    return
                }
                guard let pane else {
                    self.finishRemoteZshInstallFlow(flowKey)
                    return
                }
                if isAvailable {
                    self.retryRemoteOhMyZshDeployment(
                        flowKey: flowKey,
                        context: context,
                        pane: pane
                    )
                } else if remainingAttempts > 1 {
                    self.pollRemoteZshInstallation(
                        flowKey: flowKey,
                        context: context,
                        pane: pane,
                        markerPath: markerPath,
                        remainingAttempts: remainingAttempts - 1,
                        token: pollToken
                    )
                } else {
                    self.finishRemoteZshInstallFlow(flowKey)
                    OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                        host: context.config.host,
                        message: L10n.Workbench.remoteZshInstallTimeout
                    )
                }
            }
        }
    }

    @MainActor
    private func retryRemoteOhMyZshDeployment(
        flowKey: String,
        context: TunnelLiveSessionContext,
        pane: RemoteTerminalPaneViewController
    ) {
        remoteZshInstallPollTokens[flowKey] = nil
        ohMyZshAutoApplier.autoApplyRemoteSession(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256
        ) { [weak self, weak pane] result in
            guard let self else { return }
            self.finishRemoteZshInstallFlow(flowKey)
            switch result {
            case .success:
                _ = pane?.reloadOhMyZshShellSafely()
            case let .failure(error):
                StacioLogStore.shared.append(
                    level: .error,
                    category: "OhMyZsh",
                    message: "remote_apply_after_zsh_install_failed: \(error.localizedDescription)"
                )
                OhMyZshNotificationPresenter.postRemoteDeploymentFailed(
                    host: context.config.host,
                    message: error.localizedDescription
                )
            }
        }
    }

    @MainActor
    private func finishRemoteZshInstallFlow(_ flowKey: String) {
        remoteZshInstallPromptState.finishFlow(flowKey)
        remoteZshInstallPollTokens[flowKey] = nil
    }

    private func remoteZshInstallFlowKey(_ context: TunnelLiveSessionContext) -> String {
        "\(context.config.username)@\(context.config.host):\(context.config.port)"
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
        // Attaching a toolbar lets AppKit restore its saved configuration,
        // which can overwrite displayMode. Re-apply the persisted app choice
        // after attachment so every native toolbar item uses the same mode.
        scheduleToolbarDisplayModeReapply(for: toolbar)

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
        bindUpdateStatusControllerIfNeeded()
        sparkleUpdateController?.probeForAvailableUpdate()
        refreshWorkbenchAppearance()
        refreshToolbarItemAvailability()
        layoutWorkbenchContent(in: window)
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
            // === SPEC: fix-workbench-window-resize ===
            // 不再升回 999，stay 约束保持 .defaultLow，避免阻挡后续 resize
            if Self.workbenchResizeFixEnabled {
                updateWorkbenchContentSizeStayConstraints(forFrameSize: window.frame.size, in: window)
            }
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
        restoreStoredSidebarWidthIfNeeded(in: contentSplitViewController.splitView)
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
        centerContainerViewController?.synchronizeEditorLayout()
    }

    private func prepareWorkbenchForDockedEditor(targetWidth: CGFloat) {
        guard targetWidth.isFinite,
              targetWidth > 0,
              let window,
              let centerContainerViewController
        else {
            return
        }
        guard let visibleFrame = remoteEditorScreenProvider.descriptor(containing: window)?.visibleFrame
            ?? (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }

        _ = centerContainerViewController.view
        layoutWorkbenchContent(in: window)

        let requiredCenterWidth = WorkbenchCenterContainerViewController.minimumReadableWorkspaceWidth
            + centerContainerViewController.editorSidecarDividerThickness
            + targetWidth
        let missingWidth = max(0, requiredCenterWidth - centerContainerViewController.view.bounds.width)
        let growth = min(missingWidth, max(0, visibleFrame.width - window.frame.width))
        guard growth > 0 else {
            centerContainerViewController.synchronizeEditorLayout()
            return
        }

        let splitView = contentSplitViewController.splitView
        splitView.layoutSubtreeIfNeeded()
        let subviews = splitView.arrangedSubviews
        let sidebarWidth = subviews.first?.isHidden == false ? subviews.first?.frame.width : nil
        let inspectorWidth = currentInspectorPanelWidth()
        var frame = window.frame
        frame.size.width += growth
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        )

        pendingProgrammaticWindowFrameRestore = nil
        performProgrammaticSplitLayout {
            isRestoringWindowFrame = true
            updateWorkbenchContentSizeStayConstraints(forFrameSize: frame.size, in: window)
            window.setFrame(frame, display: true)
            isRestoringWindowFrame = false
            layoutWorkbenchContent(in: window)

            let expandedSplitView = contentSplitViewController.splitView
            splitPositionOverrideDepth += 1
            defer { splitPositionOverrideDepth -= 1 }
            if let sidebarWidth, sidebarWidth > 0 {
                expandedSplitView.setPosition(sidebarWidth, ofDividerAt: 0)
            }
            if let inspectorWidth, inspectorWidth > 0 {
                let dividerPosition = expandedSplitView.bounds.width
                    - inspectorWidth
                    - expandedSplitView.dividerThickness
                expandedSplitView.setPosition(dividerPosition, ofDividerAt: 1)
                applyPinnedWorkbenchSplitFrames(
                    targetInspectorWidth: inspectorWidth,
                    in: expandedSplitView,
                    targetSidebarWidth: sidebarWidth
                )
            }
            expandedSplitView.layoutSubtreeIfNeeded()
            centerContainerViewController.synchronizeEditorLayout()
        }
        saveWorkbenchWindowFrame(window)
    }

    private func installWorkbenchContentSizeStayConstraints(on contentView: NSView) {
        let widthConstraint = contentView.widthAnchor.constraint(
            equalToConstant: contentView.bounds.width
        )
        // spec: fix-workbench-window-resize — 默认 .defaultLow，避免阻挡窗口 live resize
        widthConstraint.priority = Self.workbenchResizeFixEnabled ? .defaultLow : NSLayoutConstraint.Priority(999)
        widthConstraint.identifier = "Stacio.Workbench.contentWidthStay"
        let heightConstraint = contentView.heightAnchor.constraint(
            equalToConstant: contentView.bounds.height
        )
        heightConstraint.priority = Self.workbenchResizeFixEnabled ? .defaultLow : NSLayoutConstraint.Priority(999)
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
        // spec: fix-workbench-window-resize — flag=true 时保持 .defaultLow 不升回（与 live resize 一致）；
        // flag=false 时恢复修复前行为（升回 999）
        if Self.workbenchResizeFixEnabled == false {
            workbenchContentWidthStayConstraint?.priority = NSLayoutConstraint.Priority(999)
            workbenchContentHeightStayConstraint?.priority = NSLayoutConstraint.Priority(999)
        }
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
        let nativeInset = max(0, contentView.bounds.maxY - contentLayoutFrame.maxY)
        let labelsVisible = window.toolbar?.displayMode == .iconAndLabel
        // During a toolbar-style transition AppKit can report the previous
        // contentLayoutRect for one or more run-loop passes. Use a stable
        // mode-specific inset for the inspector instead of letting that stale
        // value keep the panel at its old height. Preserve unusually tall
        // native clearance when labels are visible, while capping compact
        // mode so stale label clearance cannot leak into the panel.
        if labelsVisible {
            return max(48, nativeInset)
        }
        return min(16, nativeInset)
    }

    private func updateInspectorToolbarTopInset(in window: NSWindow?) {
        let labelsVisible = window?.toolbar?.displayMode == .iconAndLabel
        inspectorViewController?.setToolbarTopInset(
            toolbarTopInset(in: window),
            allowingExtendedClearance: labelsVisible
        )
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

    private func isInteractiveSplitPositionChange(in splitView: NSSplitView? = nil) -> Bool {
        if let pinnedSplitView = splitView as? StacioPinnedSplitView {
            return pinnedSplitView.isTrackingUserDividerDrag
        }
        guard let event = NSApp.currentEvent else {
            return false
        }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            return (NSEvent.pressedMouseButtons & 1) != 0
        default:
            return false
        }
    }

    private func scheduleInteractiveSplitResizeRepair() {
        isInteractiveSplitResizeActive = true
        interactiveSplitResizeWorkItem?.cancel()
        interactiveSplitResizeWorkItem = nil
        if let splitView = contentSplitViewController.splitView as? StacioPinnedSplitView,
           splitView.isTrackingUserDividerDrag
        {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.interactiveSplitResizeWorkItem = nil
            self.isInteractiveSplitResizeActive = false
            self.applyPendingInspectorWidthIfNeeded()
            self.synchronizeInspectorContentFrameAfterSplitLayout()
            self.preservedInspectorWidthDuringSidebarMove = nil
            self.saveSplitColumnWidthsIfNeeded()
        }
        interactiveSplitResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + splitResizeSettleInterval, execute: workItem)
    }

    private func userDividerDragStateDidChange(_ isDragging: Bool) {
        if isDragging {
            // Release the captured width while the pointer is moving so AppKit
            // can track the divider freely. It is restored on mouse-up below.
            sidebarSplitViewItem?.holdingPriority = .defaultLow
            sidebarSplitViewItem?.minimumThickness = minimumReadableSidebarWidth
            sidebarSplitViewItem?.maximumThickness = 320
            interactiveSplitResizeWorkItem?.cancel()
            interactiveSplitResizeWorkItem = nil
            splitWidthPersistenceWorkItem?.cancel()
            splitWidthPersistenceWorkItem = nil
            isInteractiveSplitResizeActive = true
            inspectorViewController?.setInteractiveColumnResizeActive(true)
            return
        }

        interactiveSplitResizeWorkItem?.cancel()
        interactiveSplitResizeWorkItem = nil
        splitWidthPersistenceWorkItem?.cancel()
        splitWidthPersistenceWorkItem = nil
        isInteractiveSplitResizeActive = false
        applyPendingInspectorWidthIfNeeded()
        synchronizeInspectorContentFrameAfterSplitLayout()
        inspectorSplitViewItem?.holdingPriority = .defaultHigh
        preservedInspectorWidthDuringSidebarMove = nil
        saveSplitColumnWidthsIfNeeded()
        if let pendingSidebarWidth {
            applyPinnedSidebarWidth(pendingSidebarWidth, in: contentSplitViewController.splitView)
        } else {
            restoreStoredSidebarWidthIfNeeded(in: contentSplitViewController.splitView)
        }
        inspectorViewController?.setInteractiveColumnResizeActive(false)
    }

    private func scheduleSplitWidthPersistence() {
        guard allowsUserSplitWidthPersistence else { return }
        splitWidthPersistenceWorkItem?.cancel()
        splitWidthPersistenceWorkItem = nil
        if let splitView = contentSplitViewController.splitView as? StacioPinnedSplitView,
           splitView.isTrackingUserDividerDrag
        {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.splitWidthPersistenceWorkItem = nil
            self.saveSplitColumnWidthsIfNeeded()
        }
        splitWidthPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + splitResizeSettleInterval, execute: workItem)
    }

    private func restoreStoredSidebarWidthIfNeeded(in splitView: NSSplitView) {
        guard isInteractiveSplitResizeActive == false,
              isInteractiveSplitPositionChange(in: splitView) == false
        else { return }
        guard let storedSidebarWidth = storedSplitWidth(column: "sidebar"),
              splitView.arrangedSubviews.count >= 3
        else { return }

        let targetSidebarWidth = clampedSidebarWidth(
            storedSidebarWidth,
            availableWidth: splitView.bounds.width
        )
        let sidebarView = splitView.arrangedSubviews[0]
        guard sidebarView.isHidden == false else { return }
        let isPinnedToTarget = abs((sidebarSplitViewItem?.minimumThickness ?? 0) - targetSidebarWidth) <= 1
            && abs((sidebarSplitViewItem?.maximumThickness ?? 0) - targetSidebarWidth) <= 1
        guard abs(sidebarView.frame.width - targetSidebarWidth) > 1 || isPinnedToTarget == false else { return }

        applyPinnedSidebarWidth(targetSidebarWidth, in: splitView)
    }

    private func applyPinnedSidebarWidth(_ targetWidth: CGFloat, in splitView: NSSplitView) {
        guard let sidebarSplitViewItem,
              splitView.arrangedSubviews.count >= 3
        else { return }

        sidebarSplitViewItem.holdingPriority = .defaultLow
        sidebarSplitViewItem.minimumThickness = targetWidth
        sidebarSplitViewItem.maximumThickness = targetWidth
        updatePreferredSidebarFraction(targetWidth, splitWidth: splitView.bounds.width)
        performProgrammaticSplitLayout {
            splitView.setPosition(targetWidth, ofDividerAt: 0)
            applyPinnedWorkbenchSplitFrames(
                targetInspectorWidth: contentSplitViewController.splitViewItems[2].isCollapsed
                    ? 0
                    : (pendingInspectorWidth ?? splitView.arrangedSubviews[2].frame.width),
                in: splitView,
                targetSidebarWidth: targetWidth
            )
            splitView.layoutSubtreeIfNeeded()
        }
    }

    private func constrainWorkbenchSplitPosition(
        _ splitView: NSSplitView,
        proposedPosition: CGFloat,
        dividerIndex: Int
    ) -> CGFloat {
        guard splitView === contentSplitViewController.splitView,
              contentSplitViewController.splitViewItems.count >= 2
        else {
            return proposedPosition
        }

        let dividerThickness = splitView.dividerThickness
        if dividerIndex == 0 {
            // AppKit can route divider tracking through its private divider
            // view instead of StacioPinnedSplitView.mouseDown. In that path
            // this constraint callback is the first reliable signal that a
            // real pointer drag has started, so release the persisted pin here.
            if isInteractiveSplitPositionChange(in: splitView) {
                sidebarSplitViewItem?.holdingPriority = .defaultLow
                sidebarSplitViewItem?.minimumThickness = minimumReadableSidebarWidth
                sidebarSplitViewItem?.maximumThickness = 320
                if isInteractiveSplitResizeActive == false {
                    isInteractiveSplitResizeActive = true
                    inspectorViewController?.setInteractiveColumnResizeActive(true)
                }
            }
            let constrainedSidebarWidth = clampedSidebarWidth(
                proposedPosition,
                availableWidth: splitView.bounds.width,
                reservedTrailingWidth: reservedTrailingWidthForSidebarDrag(in: splitView)
            )
            updatePreferredSidebarFraction(
                constrainedSidebarWidth,
                splitWidth: splitView.bounds.width
            )
            guard contentSplitViewController.splitViewItems.count >= 3,
                  contentSplitViewController.splitViewItems[2].isCollapsed == false
            else {
                return constrainedSidebarWidth
            }
            preserveInspectorWidthWhileMovingSidebar(
                in: splitView,
                proposedSidebarWidth: constrainedSidebarWidth,
                dividerThickness: dividerThickness
            )
            return constrainedSidebarWidth
        }

        guard dividerIndex == 1,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else {
            return proposedPosition
        }

        let isDragging = isInteractiveSplitResizeActive
            || isInteractiveSplitPositionChange(in: splitView)
        if isDragging {
            inspectorSplitViewItem?.holdingPriority = .defaultLow
            inspectorSplitViewItem?.minimumThickness = 0
        }
        let subviews = splitView.arrangedSubviews
        let sidebarIsVisible = subviews.first?.isHidden == false
        let sidebarWidth = sidebarIsVisible ? subviews.first?.frame.width ?? 0 : 0
        let leadingDividerThickness = sidebarIsVisible ? dividerThickness : 0
        let lowerBound = sidebarWidth + leadingDividerThickness
        let upperBound = max(lowerBound, splitView.bounds.width - dividerThickness)
        if let preservedInspectorWidthDuringSidebarMove {
            let targetWidth = clampedInspectorWidth(
                preservedInspectorWidthDuringSidebarMove,
                splitWidth: splitView.bounds.width
            )
            let maximumPreservableInspectorWidth = maximumInspectorWidthPreservingWorkspace(
                in: splitView,
                sidebarWidth: sidebarWidth
            )
            let boundedTargetWidth = min(targetWidth, maximumPreservableInspectorWidth)
            let preservingPosition = splitView.bounds.width - boundedTargetWidth - dividerThickness
            let constrainedPosition = min(max(preservingPosition, lowerBound), upperBound)
            pendingInspectorWidth = max(0, splitView.bounds.width - constrainedPosition - dividerThickness)
            updatePreferredInspectorFraction(pendingInspectorWidth ?? 0, splitWidth: splitView.bounds.width)
            return constrainedPosition
        }
        let constrainedPosition = min(max(proposedPosition, lowerBound), upperBound)
        if splitPositionOverrideDepth == 0 {
            pendingInspectorWidth = max(0, splitView.bounds.width - constrainedPosition - dividerThickness)
            if isInteractiveSplitPositionChange(in: splitView) {
                scheduleInteractiveSplitResizeRepair()
            } else {
                updatePreferredInspectorFraction(pendingInspectorWidth ?? 0, splitWidth: splitView.bounds.width)
                applyWorkbenchSplitFrames(
                    forDividerOnePosition: constrainedPosition,
                    in: splitView,
                    pinsInspectorWidthDuringLayout: true
                )
                saveSplitColumnWidthsIfNeeded()
            }
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

        let maximumPreservableInspectorWidth = maximumInspectorWidthPreservingWorkspace(
            in: splitView,
            sidebarWidth: proposedSidebarWidth
        )
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
              isApplyingProgrammaticSplitLayout == false,
              splitPositionOverrideDepth == 0,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        if dividerIndex == 0 {
            sidebarSplitViewItem?.holdingPriority = .defaultLow
            sidebarSplitViewItem?.minimumThickness = minimumReadableSidebarWidth
            sidebarSplitViewItem?.maximumThickness = 320
            let subviews = splitView.arrangedSubviews
            guard subviews.count >= 3,
                  subviews[2].isHidden == false
            else { return }

            let inspectorWidth = subviews[2].frame.width
            if inspectorWidth > 0 {
                preservedInspectorWidthDuringSidebarMove = inspectorWidth
                pendingInspectorWidth = inspectorWidth
            }
            // A previously pinned inspector width must not prevent the sidebar
            // drag from preserving the minimum readable workspace.
            inspectorSplitViewItem?.minimumThickness = 0
            return
        }

        guard dividerIndex == 1 else { return }

        inspectorSplitViewItem?.holdingPriority = .defaultLow
        inspectorSplitViewItem?.minimumThickness = 0
    }

    private func finishWorkbenchSplitPosition(
        _ splitView: NSSplitView,
        position: CGFloat,
        dividerIndex: Int
    ) {
        guard isApplyingProgrammaticSplitLayout == false,
              splitPositionOverrideDepth == 0,
              splitView === contentSplitViewController.splitView,
              contentSplitViewController.splitViewItems.count >= 2
        else { return }

        if dividerIndex == 0 {
            let targetSidebarWidth = clampedSidebarWidth(
                position,
                availableWidth: splitView.bounds.width
            )
            updatePreferredSidebarFraction(targetSidebarWidth, splitWidth: splitView.bounds.width)
            if let preservedInspectorWidthDuringSidebarMove {
                pendingInspectorWidth = min(
                    max(0, preservedInspectorWidthDuringSidebarMove),
                    maximumInspectorWidthPreservingWorkspace(
                        in: splitView,
                        sidebarWidth: targetSidebarWidth
                    )
                )
            }
            pendingSidebarWidth = targetSidebarWidth
            saveSplitWidth(targetSidebarWidth, column: "sidebar")
            if isInteractiveSplitResizeActive || isInteractiveSplitPositionChange(in: splitView) {
                if let pendingInspectorWidth, pendingInspectorWidth > 0 {
                    inspectorSplitViewItem?.minimumThickness = 0
                    inspectorSplitViewItem?.maximumThickness = pendingInspectorWidth
                }
                applyPinnedWorkbenchSplitFrames(
                    targetInspectorWidth: pendingInspectorWidth ?? 0,
                    in: splitView,
                    targetSidebarWidth: targetSidebarWidth
                )
                scheduleInteractiveSplitResizeRepair()
                return
            }
            if let pendingInspectorWidth, pendingInspectorWidth > 0 {
                let inspectorDividerPosition = splitView.bounds.width
                    - pendingInspectorWidth
                    - splitView.dividerThickness
                applyWorkbenchSplitFrames(
                    forDividerOnePosition: inspectorDividerPosition,
                    in: splitView,
                    preservingWindowFrame: window?.frame,
                    pinsInspectorWidthDuringLayout: true,
                    pinnedSidebarWidth: targetSidebarWidth
                )
            } else {
                performProgrammaticSplitLayout {
                    splitView.setPosition(targetSidebarWidth, ofDividerAt: 0)
                    splitView.layoutSubtreeIfNeeded()
                }
            }
            preservedInspectorWidthDuringSidebarMove = nil
            applyPinnedSidebarWidth(targetSidebarWidth, in: splitView)
            saveSplitColumnWidthsIfNeeded()
            return
        }

        guard dividerIndex == 1,
              contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false
        else { return }

        if isInteractiveSplitResizeActive || isInteractiveSplitPositionChange(in: splitView) {
            applyInteractiveInspectorDividerFrames(
                forDividerOnePosition: position,
                in: splitView
            )
            scheduleInteractiveSplitResizeRepair()
            inspectorSplitViewItem?.holdingPriority = .defaultHigh
            return
        }

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
        inspectorSplitViewItem?.holdingPriority = .defaultHigh
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
        let sidebarIsVisible = splitView.arrangedSubviews.first?.isHidden == false
            && contentSplitViewController.splitViewItems.first?.isCollapsed == false
        let pinnedSidebarWidth = sidebarIsVisible
            ? storedSidebarWidth
                .map { clampedSidebarWidth($0, availableWidth: splitView.bounds.width) }
                ?? currentSidebarWidthForInspectorSizing(splitWidth: splitView.bounds.width)
            : 0
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
            if sidebarIsVisible, let storedSidebarWidth {
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

    private func clampedSidebarWidth(
        _ width: CGFloat,
        availableWidth: CGFloat,
        reservedTrailingWidth: CGFloat = 320
    ) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        let readableMinimum = min(minimumReadableSidebarWidth, availableWidth)
        let maximum = min(
            sidebarSplitViewItem?.maximumThickness ?? 320,
            max(readableMinimum, availableWidth - max(0, reservedTrailingWidth))
        )
        return min(max(width, readableMinimum), maximum)
    }

    private func reservedTrailingWidthForSidebarDrag(in splitView: NSSplitView) -> CGFloat {
        let dividerThickness = splitView.dividerThickness
        guard contentSplitViewController.splitViewItems.count >= 3,
              contentSplitViewController.splitViewItems[2].isCollapsed == false,
              let inspectorView = splitView.arrangedSubviews.dropFirst(2).first,
              inspectorView.isHidden == false,
              inspectorView.frame.width > 0
        else {
            return 320
        }
        return (preservedInspectorWidthDuringSidebarMove ?? pendingInspectorWidth ?? inspectorView.frame.width)
            + minimumWorkspaceWidthWhenOpeningInspector
            + dividerThickness * 2
    }

    private func maximumInspectorWidthPreservingWorkspace(
        in splitView: NSSplitView,
        sidebarWidth: CGFloat
    ) -> CGFloat {
        max(
            0,
            splitView.bounds.width
                - max(0, sidebarWidth)
                - splitView.dividerThickness * 2
                - minimumWorkspaceWidthWhenOpeningInspector
        )
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
        if contentSplitViewController.splitViewItems.first?.isCollapsed == true {
            return 0
        }
        if let sidebarView = subviews.first, sidebarView.isHidden {
            return 0
        }
        if let sidebarView = subviews.first, sidebarView.frame.width > 0
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

    private func updatePreferredSidebarFraction(_ width: CGFloat, splitWidth: CGFloat) {
        guard splitWidth > 0,
              width > 0,
              sidebarSplitViewItem?.isCollapsed == false
        else { return }
        sidebarSplitViewItem?.preferredThicknessFraction = min(max(width / splitWidth, 0.1), 0.9)
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
        let leadingDividerThickness = sidebarView.isHidden ? 0 : dividerThickness
        let inspectorWidth = min(
            max(targetInspectorWidth, 0),
            max(0, splitView.bounds.width - sidebarWidth - leadingDividerThickness - dividerThickness)
        )
        let workspaceWidth = max(
            0,
            splitView.bounds.width
                - sidebarWidth
                - inspectorWidth
                - leadingDividerThickness
                - dividerThickness
        )
        sidebarView.frame = NSRect(
            x: 0,
            y: 0,
            width: sidebarWidth,
            height: splitView.bounds.height
        )
        workspaceView.frame = NSRect(
            x: sidebarWidth + leadingDividerThickness,
            y: 0,
            width: workspaceWidth,
            height: splitView.bounds.height
        )
        inspectorView.frame = NSRect(
            x: sidebarWidth + leadingDividerThickness + workspaceWidth + dividerThickness,
            y: 0,
            width: inspectorWidth,
            height: splitView.bounds.height
        )
    }

    private func applyInteractiveInspectorDividerFrames(
        forDividerOnePosition dividerPosition: CGFloat,
        in splitView: NSSplitView
    ) {
        guard splitView.arrangedSubviews.count >= 3 else { return }
        let sidebarView = splitView.arrangedSubviews[0]
        let workspaceView = splitView.arrangedSubviews[1]
        let inspectorView = splitView.arrangedSubviews[2]
        let dividerThickness = splitView.dividerThickness
        let requestedWidth = max(
            0,
            splitView.bounds.width - dividerPosition - dividerThickness
        )
        let sidebarWidth = sidebarView.isHidden ? 0 : sidebarView.frame.width
        let leadingDividerThickness = sidebarView.isHidden ? 0 : dividerThickness
        let availableWidth = max(
            0,
            splitView.bounds.width - sidebarWidth - leadingDividerThickness - dividerThickness
        )
        let targetWidth = min(requestedWidth, availableWidth)
        pendingInspectorWidth = targetWidth
        applyPinnedWorkbenchSplitFrames(targetInspectorWidth: targetWidth, in: splitView)

        [workspaceView, inspectorView].forEach { columnView in
            guard columnView.bounds.size != columnView.frame.size else { return }
            columnView.bounds = NSRect(origin: columnView.bounds.origin, size: columnView.frame.size)
        }
        inspectorViewController?.synchronizeSelectedSectionFrameAfterSplitLayout(hostView: inspectorView)
        inspectorViewController?.aiAssistantViewController?.refreshLayoutDuringInspectorInteractiveResize()
        workspaceView.needsLayout = true
        workspaceView.needsDisplay = true
        inspectorView.needsDisplay = true
        splitView.needsDisplay = true
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

    var hasPendingInteractiveSplitResizeRepairForTesting: Bool {
        interactiveSplitResizeWorkItem != nil
    }

    var hasPendingSplitWidthPersistenceForTesting: Bool {
        splitWidthPersistenceWorkItem != nil
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
        if isInteractiveSplitResizeActive {
            scheduleInteractiveSplitResizeRepair()
            return
        }
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
            saveSplitWidth(pendingSidebarWidth ?? sidebarView.frame.width, column: "sidebar")
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
                    self?.handleSplitViewDidResizeSubviews(split.splitView)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleSplitViewDidResizeSubviews(split.splitView)
                }
            }
        }
        split.afterPinnedLayout = { [weak self] in
            guard let self else { return }
            self.keepSidebarReadableWithoutResizingWindow()
            self.restoreStoredSidebarWidthIfNeeded(in: self.contentSplitViewController.splitView)
        }
        split.afterPinnedSplitViewLayout = { [weak self] _ in
            self?.schedulePendingInspectorWidthRepair()
        }
        split.pinnedUserDividerDragStateDidChange = { [weak self] isDragging in
            self?.userDividerDragStateDidChange(isDragging)
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
            onConnectSession: { [weak self] session, transientPassword in
                do {
                    _ = try self?.openSavedSession(session, transientPassword: transientPassword)
                } catch is CancellationError {
                } catch {
                    AppKitSessionSidebarErrorPresenter().present(error, context: .openSession, parentWindow: self?.window)
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

        let centerController = WorkbenchCenterContainerViewController(
            workspaceViewController: workspaceViewController,
            presentationStore: remoteEditorPresentationStore
        )
        let presentation = RemoteEditorPresentationCoordinator(
            dockHost: centerController,
            presentationStore: remoteEditorPresentationStore,
            screenProvider: remoteEditorScreenProvider,
            licenseAccess: licenseAccess,
            authorizer: LicenseFeatureAuthorizer(accessProvider: licenseAccess),
            closeConfirmer: remoteEditorCloseConfirmer
        )
        presentation.onWillPresentDockedEditor = { [weak self] targetWidth in
            self?.prepareWorkbenchForDockedEditor(targetWidth: targetWidth)
        }
        centerContainerViewController = centerController
        remoteEditorPresentationCoordinator = presentation

        let center = NSSplitViewItem(viewController: centerController)
        center.minimumThickness = 0
        center.preferredThicknessFraction = 0.57
        center.holdingPriority = .defaultLow
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
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            aiAssistantViewController: makeAIAssistantPanelViewController(),
            workspaceSessionProtocolProvider: { [weak workspaceViewController] in
                workspaceViewController?.currentSessionProtocol ?? .noSession
            },
            tunnelLiveSessionContextProvider: tunnelLiveSessionContextProvider,
            remoteFilePathTerminalSender: { [weak workspaceViewController] path in
                _ = workspaceViewController?.sendTextToCurrentTerminal(path)
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
            transferQueueCoordinatorFactory: transferQueueCoordinatorFactory,
            remoteEditorPresentation: presentation
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
        // SSH 连接建立后：若已启用 Oh My Zsh 且资源就绪，自动部署到该主机（结果不阻塞连接流程）。
        workspaceViewController.onRemoteTerminalRuntimeAttached = { [weak self] pane, _, liveSessionContext in
            guard let self,
                  let context = liveSessionContext ?? pane.liveSessionContext else {
                return
            }
            self.ohMyZshAutoApplier.autoApplyRemoteSession(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256
            ) { [weak self, weak pane] result in
                switch result {
                case .success:
                    if self?.settingsStore.snapshot().ohmyzshEnabled == true {
                        pane?.reloadOhMyZshShellSafely()
                    }
                case let .failure(error):
                    if let self, let pane {
                        self.handleRemoteOhMyZshApplyFailure(
                            error,
                            context: context,
                            pane: pane
                        )
                    }
                }
            }
        }
        workspaceViewController.onRemoteTerminalCloseRequested = { [weak inspectorController] pane, completion in
            guard let inspectorController else {
                completion(.ready)
                return .ready
            }
            return inspectorController.disconnectFilesBindingIfNeeded(runtimeID: pane.runtimeID) { resolution in
                if resolution == .ready {
                    inspectorController.dismissTransferNotifications(runtimeID: pane.runtimeID)
                }
                completion(resolution)
            }
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
                inspectorController?.refreshCurrentTerminalContextPanels()
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
            // Remote-terminal selection changes can arrive without the
            // generic current-terminal callback. Rebind every context-aware
            // Inspector surface, including the per-tab AI runtime.
            inspectorController?.refreshCurrentTerminalContextPanels()
        }
        workspaceViewController.onCurrentTerminalChanged = { [weak self, weak inspectorController] in
            self?.synchronizeInspectorVisibilityForCurrentSession()
            inspectorController?.refreshWorkspaceCapabilities()
            inspectorController?.refreshCurrentTerminalContextPanels()
            self?.refreshToolbarItemAvailability()
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
        split.addSplitViewItem(center)
        split.addSplitViewItem(inspector)
        return split
    }

    private func handleSplitViewDidResizeSubviews(_ splitView: NSSplitView) {
        guard splitView === contentSplitViewController.splitView else { return }

        // AppKit's divider tracker can resize the arranged subviews directly
        // without going through StacioPinnedSplitView.setPosition. Mirror
        // that path here so the inspector content follows the divider during
        // the drag instead of waiting for the mouse-up repair pass.
        let isDragging = isInteractiveSplitResizeActive
            || isInteractiveSplitPositionChange(in: splitView)
        if isDragging,
           splitView.arrangedSubviews.count >= 3,
           contentSplitViewController.splitViewItems[2].isCollapsed == false
        {
            let dividerPosition = splitView.arrangedSubviews[1].frame.maxX
            if dividerPosition.isFinite, dividerPosition > 0 {
                applyInteractiveInspectorDividerFrames(
                    forDividerOnePosition: dividerPosition,
                    in: splitView
                )
            }
        }

        scheduleSplitWidthPersistence()
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
        let assistantSettingsValueStore = assistantSettingsValueStoreProvider()
        let assistantSettingsProvider: () -> AssistantRuntimeSettingsSnapshot? = {
            guard let assistantSettingsValueStore else { return nil }
            return try? AssistantRuntimeSettingsSnapshot.resolve(from: assistantSettingsValueStore)
        }
        let productionRuntimeFactory: InspectorConversationRuntimeFactory = { [weak self, weak workspaceViewController] sessionID, terminalContext, modelSelection in
            guard let self else {
                throw InspectorConversationAssemblyError.hostUnavailable
            }
            let paths = try StacioPaths()
            let controlPath = paths.applicationSupportDirectory
                .appendingPathComponent("agent-control.sqlite3").path
            let controlState = try AgentConversationV2ControlCoordinator(
                databasePath: controlPath
            ).controlState()
            let accessMode: SessionRuntimeBridge.AccessMode = controlState == .enabled
                ? .interactive
                : .readOnlyHistory
            let runtimeSettings = try AssistantRuntimeSettingsSnapshot.resolve(
                from: assistantSettingsValueStore
            )
            guard let catalog = BundledRuntimeCatalog.shared.toolCatalog else {
                throw InspectorConversationAssemblyError.toolCatalogUnavailable
            }
            let terminalTools = catalog.tools.filter {
                $0.toolID == StacioBuiltinToolID.terminalCommand
            }
            guard terminalTools.count == 1 else {
                throw InspectorConversationAssemblyError.terminalToolUnavailable
            }
            let filteredCatalog = StacioToolCatalog(
                revision: catalog.revision,
                tools: terminalTools
            )
            let storage = try ConversationV2StorageFactory.makeStorageBundle(
                conversationID: sessionID,
                paths: paths
            )
            var initialState = ConversationV2StorageFactory.makeInitialSessionState(
                sessionID: sessionID,
                queueAutoAdvanceEnabled: runtimeSettings.queueAutoAdvanceEnabled,
                defaultWorkMode: runtimeSettings.defaultWorkMode,
                defaultReasoningEffort: runtimeSettings.defaultReasoningEffort.rawValue,
                memoryScope: terminalContext.historyScopeID,
                initialTargetContext: terminalContext
            )
            let selectedProviderID = modelSelection?.providerID.uuidString
                ?? runtimeSettings.defaultRuntimeConfigurationID
            let selectedModelID = modelSelection?.modelID
            let resolved = LegacyProviderConfigurationAdapter.resolveActiveProvider(
                settingsStore: self.settingsStore,
                keyStore: self.aiAPIKeyStore,
                transport: self.aiHTTPTransport,
                preferredConfigurationID: selectedProviderID,
                preferredModelID: selectedModelID,
                defaultReasoningEffort: runtimeSettings.defaultReasoningEffort
            )
            if let resolved {
                initialState.session.runtimeSelection = AgentRuntimeSelection(
                    kind: .nativeAPI,
                    providerConfigurationID: resolved.configuration.runtimeConfigurationKind == .provider
                        ? resolved.configuration.effectiveConfigurationID : nil,
                    codingPlanConfigurationID: resolved.configuration.runtimeConfigurationKind == .codingPlan
                        ? resolved.configuration.effectiveConfigurationID : nil,
                    modelID: resolved.configuration.model,
                    reasoningEffort: runtimeSettings.defaultReasoningEffort.rawValue,
                    workMode: runtimeSettings.defaultWorkMode
                )
            } else if let selectedProviderID {
                // Preserve an explicit stale selection so `send` fails closed.
                // An unavailable model must never turn into the global default.
                initialState.session.runtimeSelection = AgentRuntimeSelection(
                    kind: .nativeAPI,
                    providerConfigurationID: selectedProviderID,
                    modelID: selectedModelID,
                    reasoningEffort: runtimeSettings.defaultReasoningEffort.rawValue,
                    workMode: runtimeSettings.defaultWorkMode
                )
            }
            let actor = ConversationActorRegistry.shared.actor(
                for: sessionID,
                store: storage.repository,
                sealing: storage.sealing,
                initialState: initialState
            )
            let executionChoice = TurnExecutionChoice(
                rawValue: runtimeSettings.defaultTerminalMode
            ) ?? .realTerminal
            let executionModeState = InspectorConversationExecutionModeState(
                choice: executionChoice
            )
            let executionCoordinator = AgentExecutionCoordinator(
                terminalResolver: self.workspaceViewController,
                authorizer: ConversationBridgeApprovedAgentActionAuthorizer(
                    settingsStore: self.settingsStore
                ),
                auditRecorder: self.makeAgentActionAuditStore(),
                sessionLister: self.workspaceViewController,
                executionMode: .visibleTerminal,
                executionModeResolver: { executionModeState.mode }
            )
            let admissionScheduler = try ConversationV2StorageFactory.makeAdmissionScheduler(
                repository: storage.repository,
                paths: paths,
                capacity: runtimeSettings.maxParallelAttempts
            )
            let submissionGate: () -> Bool = {
                do {
                    let coordinator = try AgentConversationV2ControlCoordinator(
                        databasePath: controlPath
                    )
                    return try coordinator.admissionGateAllowsNewExecution() == .open
                } catch {
                    // Control-plane failures must fail closed for new work. An
                    // already running Attempt continues through its own
                    // settlement path and is intentionally not gated here.
                    return false
                }
            }
            let bridge = SessionRuntimeBridge(
                actor: actor,
                sessionID: sessionID,
                initialState: initialState,
                provider: resolved?.provider,
                providerConfig: resolved?.configuration,
                executionCoordinator: executionCoordinator,
                terminalContextProvider: { [weak workspaceViewController] in
                    workspaceViewController?.aiTerminalContext(runtimeID: terminalContext.runtimeID)
                },
                targetContextResolver: { [weak workspaceViewController] runtimeID in
                    workspaceViewController?.aiTerminalContext(runtimeID: runtimeID)
                },
                executionModeSnapshotHandler: { choice in
                    executionModeState.applyFrozenTurnChoice(choice)
                },
                runtimeSettingsProvider: {
                    try AssistantRuntimeSettingsSnapshot.resolve(from: assistantSettingsValueStore)
                },
                submissionGate: submissionGate,
                admissionCoordinator: admissionScheduler,
                toolCatalog: filteredCatalog,
                providerResolver: {
                    LegacyProviderConfigurationAdapter.resolveActiveProvider(
                        settingsStore: self.settingsStore,
                        keyStore: self.aiAPIKeyStore,
                        transport: self.aiHTTPTransport,
                        defaultReasoningEffort: runtimeSettings.defaultReasoningEffort
                    )
                },
                providerConfigurationResolver: { configurationID in
                    LegacyProviderConfigurationAdapter.resolveActiveProvider(
                        settingsStore: self.settingsStore,
                        keyStore: self.aiAPIKeyStore,
                        transport: self.aiHTTPTransport,
                        preferredConfigurationID: configurationID,
                        defaultReasoningEffort: runtimeSettings.defaultReasoningEffort
                    )
                },
                providerSelectionResolver: { configurationID, modelID in
                    LegacyProviderConfigurationAdapter.resolveActiveProvider(
                        settingsStore: self.settingsStore,
                        keyStore: self.aiAPIKeyStore,
                        transport: self.aiHTTPTransport,
                        preferredConfigurationID: configurationID,
                        preferredModelID: modelID,
                        defaultReasoningEffort: runtimeSettings.defaultReasoningEffort
                    )
                },
                settingsProvider: { self.settingsStore.snapshot() },
                terminalAutomationPolicyProvider: { [weak workspaceViewController] runtimeID in
                    guard let runtimeID else { return nil }
                    return try? workspaceViewController?
                        .resolveTerminalTarget(.runtimeID(runtimeID))
                        .agentAutomationPolicy
                },
                initialTargetContext: terminalContext,
                initialExecutionChoice: executionChoice,
                restorePending: true,
                accessMode: accessMode,
                persistsSessionCreationEvent: true
            )
            return InspectorConversationRuntime(
                sessionID: sessionID,
                bridge: bridge,
                repository: storage.repository,
                initialExecutionChoice: executionChoice,
                executionModeState: executionModeState
            )
        }
        let runtimeFactory = aiConversationRuntimeFactoryOverride ?? productionRuntimeFactory
        let executionCoordinator = makeAgentExecutionCoordinator(parentWindow: window)
        return AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: SettingsBackedAIAssistantProvider(
                    settingsStore: settingsStore,
                    apiKeyStore: aiAPIKeyStore,
                    transport: aiHTTPTransport,
                    selectionSession: modelSelectionSession
                ),
                executionCoordinator: executionCoordinator,
                settingsStore: settingsStore,
                modelSelectionSession: modelSelectionSession,
                assistantSettingsProvider: assistantSettingsProvider
            ),
            contextProvider: { [weak workspaceViewController] runtimeID in
                workspaceViewController?.aiTerminalContext(runtimeID: runtimeID)
            },
            terminalSessionProvider: { [weak workspaceViewController] in
                workspaceViewController?.listAgentTerminalSessions() ?? []
            },
            settingsStore: settingsStore,
            modelSelectionSession: modelSelectionSession,
            assistantSettingsProvider: assistantSettingsProvider,
            taskRecorder: makeAgentTaskStore(),
            taskLister: makeAgentTaskStore(),
            conversationHistoryStore: nil,
            internalBrowserOpener: { [weak workspaceViewController] url in
                _ = try? workspaceViewController?.openBrowserSession(
                    urlString: url.absoluteString,
                    title: url.host ?? url.absoluteString
                )
            },
            terminalActivator: { [weak workspaceViewController] runtimeID in
                workspaceViewController?.activateTerminal(runtimeID: runtimeID) ?? false
            },
            conversationRuntimeFactory: runtimeFactory,
            conversationCatalogLoader: aiConversationCatalogLoader,
            localAgentToolResolver: aiLocalAgentToolResolver,
            localAgentProcessLauncherFactory: aiLocalAgentProcessLauncherFactory,
            localAgentRuntimeLaunchAuthorizerProvider: aiLocalAgentRuntimeLaunchAuthorizerProvider
        )
    }

    private func showAssistantQuickSettings() {
        if let controller = assistantQuickSettingsWindowController {
            controller.reload()
            controller.showWindow(self)
            controller.window?.makeKeyAndOrderFront(self)
            return
        }
        guard let valueStore = assistantSettingsValueStoreProvider(),
              let mutationCoordinator = try? AssistantSettingsMutationCoordinator.live(valueStore: valueStore)
        else {
            let alert = NSAlert()
            alert.messageText = "无法打开排查助手设置"
            alert.informativeText = "设置存储暂不可用，请稍后重试。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.Common.ok)
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        let controller = AssistantQuickSettingsWindowController(
            valueStore: valueStore,
            mutationCoordinator: mutationCoordinator
        )
        assistantQuickSettingsWindowController = controller
        controller.showWindow(self)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(self)
    }

    private func showAIAssistantInspector(prefilling text: String? = nil) {
        guard allowsWorkspaceCapability(.ai) else { return }
        guard let inspectorViewController else {
            return
        }
        let preservedWindowFrame = window?.frame
        defer {
            restoreProgrammaticFrameIfNeeded(preservedWindowFrame)
        }
        let didRevealInspector = revealInspectorForPanelSelection()
        inspectorViewController.selectAIAssistantTab()
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: preservedWindowFrame)
        inspectorViewController.aiAssistantViewController?.refreshForCurrentContext()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            inspectorViewController.aiAssistantViewController?.prefillQuestion("解释这段终端输出：\n\(trimmed)")
        }
        inspectorViewController.aiAssistantViewController?.focusQuestionField()
    }

    private func makeAgentExecutionCoordinator(
        parentWindow: NSWindow?,
        executionModeResolver: (() -> AgentExecutionMode)? = nil
    ) -> AgentExecutionCoordinator {
        if executionModeResolver == nil, let agentExecutionCoordinator {
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
            executionMode: .visibleTerminal,
            executionModeResolver: executionModeResolver
        )
        if executionModeResolver == nil {
            agentExecutionCoordinator = coordinator
        }
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
        migrateLegacyToolbarConfigurationIfNeeded()
        let toolbar = WorkbenchCustomizationRoutingToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.sizeMode = toolbarShowsLabels() ? .regular : .small
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.customizationHandler = { [weak self, weak toolbar] _ in
            guard let self, let toolbar else { return }
            self.presentToolbarCustomization(for: toolbar)
        }

        for identifier in toolbarDefaultItemIdentifiers(toolbar) {
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
        }

        applyToolbarDisplayMode(
            toolbarShowsLabels() ? .iconAndLabel : .iconOnly,
            to: toolbar
        )

        return toolbar
    }

    private func presentToolbarCustomization(for toolbar: NSToolbar) {
        guard let window else { return }
        if let existing = toolbarCustomizationWindowController {
            existing.beginSheet(for: window)
            return
        }

        let descriptors = toolbarCustomizationDescriptors(for: toolbar)
        let currentIdentifiers = toolbar.items.map(\.itemIdentifier)
        let defaultIdentifiers = toolbarDefaultItemIdentifiers(toolbar)
        let customizationController = WorkbenchToolbarCustomizationWindowController(
            descriptors: descriptors,
            currentIdentifiers: currentIdentifiers,
            defaultIdentifiers: defaultIdentifiers,
            // NSToolbar may restore its display mode from the AppKit autosave
            // payload after the window is attached. The app preference is the
            // source of truth so the customization sheet always reflects the
            // user's last choice.
            showsLabels: toolbarShowsLabels(),
            onApply: { [weak self, weak toolbar] identifiers, showsLabels in
                guard let self, let toolbar else { return }
                self.applyToolbarCustomization(identifiers, to: toolbar)
                self.applyToolbarDisplayMode(showsLabels ? .iconAndLabel : .iconOnly, to: toolbar)
                self.scheduleToolbarDisplayModeReapply(for: toolbar)
            }
        )
        customizationController.onDismiss = { [weak self, weak customizationController] in
            guard let self,
                  self.toolbarCustomizationWindowController === customizationController
            else { return }
            self.toolbarCustomizationWindowController = nil
        }
        toolbarCustomizationWindowController = customizationController
        customizationController.beginSheet(for: window)
    }

    private func toolbarCustomizationDescriptors(
        for toolbar: NSToolbar
    ) -> [WorkbenchToolbarCustomizationDescriptor] {
        toolbarAllowedItemIdentifiers(toolbar).compactMap { identifier in
            if identifier == .flexibleSpace {
                return WorkbenchToolbarCustomizationDescriptor(
                    identifier: identifier,
                    label: L10n.Workbench.toolbarCustomizationFlexibleSpace,
                    image: NSImage(
                        systemSymbolName: "arrow.left.and.right",
                        accessibilityDescription: L10n.Workbench.toolbarCustomizationFlexibleSpace
                    ) ?? NSImage(),
                    allowsDuplicates: true
                )
            }
            if identifier == .space {
                return WorkbenchToolbarCustomizationDescriptor(
                    identifier: identifier,
                    label: L10n.Workbench.toolbarCustomizationSpace,
                    image: NSImage(
                        systemSymbolName: "rectangle.compress.vertical",
                        accessibilityDescription: L10n.Workbench.toolbarCustomizationSpace
                    ) ?? NSImage(),
                    allowsDuplicates: true
                )
            }
            guard let item = self.toolbar(
                      toolbar,
                      itemForItemIdentifier: identifier,
                      willBeInsertedIntoToolbar: false
                  )
            else { return nil }
            let image = item.image ?? (item.view as? NSButton)?.image ?? NSImage(
                systemSymbolName: "square.dashed",
                accessibilityDescription: item.paletteLabel
            ) ?? NSImage()
            return WorkbenchToolbarCustomizationDescriptor(
                identifier: identifier,
                label: item.paletteLabel.isEmpty ? item.label : item.paletteLabel,
                image: image,
                allowsDuplicates: false
            )
        }
    }

    private func applyToolbarCustomization(
        _ managedIdentifiers: [NSToolbarItem.Identifier],
        to toolbar: NSToolbar
    ) {
        let identifiers = managedIdentifiers.filter {
            $0.rawValue != Self.legacyUpdatePromptToolbarIdentifier
        }

        if #available(macOS 15.0, *) {
            toolbar.itemIdentifiers = identifiers
        } else {
            for index in toolbar.items.indices.reversed() {
                toolbar.removeItem(at: index)
            }
            for identifier in identifiers {
                toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
            }
        }
        persistToolbarItemIdentifiers(identifiers)
        refreshToolbarItemAvailability()
    }

    private func toolbarShowsLabels() -> Bool {
        UserDefaults.standard.bool(forKey: Self.toolbarShowsLabelsDefaultsKey)
    }

    private func applyToolbarDisplayMode(
        _ displayMode: NSToolbar.DisplayMode,
        to toolbar: NSToolbar,
        persistsPreference: Bool = true
    ) {
        let showsLabels = displayMode == .iconAndLabel
        // Switch to the regular toolbar style while labels are visible. The
        // inspector receives an explicit content clearance below because
        // unified titlebars do not grow enough for the label baseline.
        window?.toolbarStyle = showsLabels ? .unified : .unifiedCompact
        toolbar.sizeMode = showsLabels ? .regular : .small
        toolbar.displayMode = displayMode
        for item in toolbar.items {
            guard let button = sidebarToolbarButton(in: item.view) else { continue }
            // NSToolbar renders the item's label below custom views in
            // `.iconAndLabel` mode. Keep the custom button icon-only so it
            // cannot render a second copy of the sidebar label.
            button.title = ""
            button.imagePosition = .imageOnly
            button.controlSize = showsLabels ? .regular : .small
            button.alignment = .center
            button.iconOnlyWidthConstraint?.isActive = !showsLabels
            button.iconOnlyHeightConstraint?.isActive = !showsLabels
            button.invalidateIntrinsicContentSize()
        }
        if persistsPreference {
            UserDefaults.standard.set(showsLabels, forKey: Self.toolbarShowsLabelsDefaultsKey)
        }
        toolbar.validateVisibleItems()
        updateInspectorToolbarTopInset(in: window)
        // Changing NSToolbar's display mode does not always invalidate the
        // full-size content view immediately. Force the workbench and
        // inspector to consume the new top inset now instead of waiting for a
        // later panel click or focus change to trigger layout.
        if let window {
            relayoutToolbarDependentContent(in: window)
        }
    }

    private func relayoutToolbarDependentContent(in window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        layoutWorkbenchContent(in: window)
        contentSplitViewController.view.layoutSubtreeIfNeeded()
        inspectorViewController?.view.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Re-apply the display mode after AppKit has restored the toolbar from
    /// its autosave payload or rebuilt items after customization. Both events
    /// can silently reset `displayMode` to `.iconOnly`; doing this on the next
    /// run-loop turns the preference into an invariant for the live toolbar.
    private func scheduleToolbarDisplayModeReapply(for toolbar: NSToolbar) {
        let delays: [TimeInterval] = [0, 0.02, 0.12, 0.35]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak toolbar] in
                guard let self, let toolbar else { return }
                self.applyToolbarDisplayMode(
                    self.toolbarShowsLabels() ? .iconAndLabel : .iconOnly,
                    to: toolbar,
                    persistsPreference: false
                )
                if let window = self.window,
                   window.toolbar === toolbar
                {
                    // AppKit updates contentLayoutRect after the toolbar
                    // style/display mode change reaches the next layout pass.
                    // Run the dependent layout once more in that pass so an
                    // open inspector moves without requiring a click.
                    DispatchQueue.main.async { [weak self, weak window] in
                        guard let self, let window else { return }
                        self.relayoutToolbarDependentContent(in: window)
                    }
                }
            }
        }
    }

    private func sidebarToolbarButton(in view: NSView?) -> SidebarToggleTitlebarButton? {
        guard let view else { return nil }
        if let button = view as? SidebarToggleTitlebarButton {
            return button
        }
        for subview in view.subviews {
            if let button = sidebarToolbarButton(in: subview) {
                return button
            }
        }
        return nil
    }

    private func migrateLegacyToolbarConfigurationIfNeeded() {
        let defaults = UserDefaults.standard
        guard var configuration = defaults.dictionary(forKey: Self.toolbarAutosaveDefaultsKey),
              let identifiers = configuration["TB Item Identifiers"] as? [String]
        else { return }
        let migratedIdentifiers = identifiers.filter {
            $0 != Self.legacyUpdatePromptToolbarIdentifier
        }
        guard migratedIdentifiers != identifiers else { return }
        configuration["TB Item Identifiers"] = migratedIdentifiers
        defaults.set(configuration, forKey: Self.toolbarAutosaveDefaultsKey)
    }

    private func persistToolbarItemIdentifiers(_ identifiers: [NSToolbarItem.Identifier]) {
        let defaults = UserDefaults.standard
        var configuration = defaults.dictionary(forKey: Self.toolbarAutosaveDefaultsKey) ?? [:]
        configuration["TB Item Identifiers"] = identifiers.map(\.rawValue)
        defaults.set(configuration, forKey: Self.toolbarAutosaveDefaultsKey)
    }

    private func makeSidebarToolbarToggleButton() -> SidebarToggleTitlebarButton {
        // Match the native toolbar symbols instead of using the smaller
        // compact-button glyph that made the sidebar look out of scale.
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
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
        button.controlSize = toolbarShowsLabels() ? .regular : .small
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = nil
        button.layer?.borderColor = nil
        button.layer?.borderWidth = 0
        button.contentTintColor = StacioDesignSystem.resolvedColor(.secondaryLabelColor, for: button)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = toolbarTooltip(for: ToolbarItem.sidebar)
        button.setAccessibilityLabel(L10n.Workbench.toggleSidebar)
        button.setAccessibilityIdentifier("Stacio.Toolbar.sidebarToggle")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        button.iconOnlyWidthConstraint = button.widthAnchor.constraint(equalToConstant: 24)
        button.iconOnlyHeightConstraint = button.heightAnchor.constraint(equalToConstant: 24)
        let showsLabels = toolbarShowsLabels()
        // The surrounding NSToolbar owns the label; the custom view only
        // supplies the icon and action in both display modes.
        button.title = ""
        button.imagePosition = .imageOnly
        button.iconOnlyWidthConstraint?.isActive = !showsLabels
        button.iconOnlyHeightConstraint?.isActive = !showsLabels
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.onPointerEntered = { [weak self] in
            self?.temporarilyRevealSidebarFromTitlebarHover()
        }
        button.onPointerExited = { [weak self] in
            self?.hideTemporarilyRevealedSidebarFromTitlebarHover()
        }
        return button
    }

    private func bindUpdateStatusControllerIfNeeded() {
        guard let sparkleUpdateController else {
            return
        }
        sessionSidebarViewController?.onUpdateStatusClicked = { [weak self] in
            self?.sparkleUpdateController?.installAvailableUpdateFromPrompt()
        }
        sparkleUpdateController.onButtonStateChanged = { [weak self] state in
            self?.refreshUpdateStatus(state)
        }
        refreshUpdateStatus(sparkleUpdateController.buttonState)
    }

    private func refreshUpdateStatus(_ state: SparkleUpdateButtonState) {
        sessionSidebarViewController?.updateUpdateStatus(state)
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
        if let shortcut = shortcutAction(for: action) {
            applyShortcut(shortcut, to: item)
        }
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
        if let shortcut = shortcutAction(for: action) {
            applyShortcut(shortcut, to: item)
        }
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            ?? fallbackSymbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        configurePanelMenuAvailability(item)
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

    private func workspaceCapability(for action: Selector?) -> WorkspaceCapability? {
        switch action {
        case #selector(showFilesFromToolbar(_:)): .files
        case #selector(showBrowserFromToolbar(_:)): .browser
        case #selector(showTunnelsFromToolbar(_:)): .tunnels
        case #selector(toggleDeviceDashboardFromToolbar(_:)): .deviceDashboard
        case #selector(showDiagnosticsFromToolbar(_:)): .diagnostics
        case #selector(showAIAssistantFromToolbar(_:)): .ai
        default: nil
        }
    }

    public func allowsWorkspaceCapability(_ capability: WorkspaceCapability) -> Bool {
        WorkspaceCapabilityPolicy.allows(
            capability,
            for: workspaceViewController.currentSessionProtocol
        )
    }

    private func configurePanelMenuAvailability(_ item: NSMenuItem) {
        if let capability = workspaceCapability(for: item.action),
           allowsWorkspaceCapability(capability) == false
        {
            item.isEnabled = false
            item.toolTip = L10n.Workbench.sshSessionRequiredTooltip
            return
        }
        if let feature = licensedFeature(for: item.action), isLicensed(feature) == false {
            item.isEnabled = false
            item.toolTip = L10n.Import.licenseUnavailableTooltip
            return
        }
        item.isEnabled = true
        if let shortcut = shortcutAction(for: item.action) {
            applyShortcut(shortcut, to: item)
        } else {
            item.toolTip = nil
        }
    }

    fileprivate func refreshPanelMenuAvailability(_ menu: NSMenu) {
        for item in menu.items {
            configurePanelMenuAvailability(item)
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
        var seen = Set<NSToolbarItem.Identifier>()
        return toolbarDefaultItemIdentifiers(toolbar).filter {
            seen.insert($0).inserted
        }
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
            item.toolTip = toolbarTooltip(for: itemIdentifier)
            item.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: L10n.Workbench.splitTerminal)
                ?? NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: L10n.Workbench.splitTerminal)
            item.action = #selector(performSplitTerminalFromToolbar(_:))
            item.menu = makeSplitTerminalToolbarMenu()
            item.showsIndicator = true
            item.view?.toolTip = item.toolTip
            return item
        }
        if itemIdentifier == ToolbarItem.importSessions {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.label = L10n.Workbench.importSessions
            item.paletteLabel = L10n.Workbench.importSessions
            item.toolTip = toolbarTooltip(for: itemIdentifier)
            item.image = NSImage(
                systemSymbolName: "rectangle.stack.badge.plus",
                accessibilityDescription: L10n.Workbench.importSessionsAccessibilityDescription
            )
            item.menu = makeSessionImportMenu()
            item.showsIndicator = false
            item.view?.toolTip = item.toolTip
            return item
        }
        if itemIdentifier == ToolbarItem.panels {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.label = L10n.Workbench.panels
            item.paletteLabel = L10n.Workbench.panels
            item.toolTip = toolbarTooltip(for: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: L10n.Workbench.panels)
                ?? NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: L10n.Workbench.panels)
            item.menu = makePanelsToolbarMenu()
            item.showsIndicator = true
            item.view?.toolTip = item.toolTip
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

        item.toolTip = toolbarTooltip(for: itemIdentifier) ?? item.toolTip
        item.view?.toolTip = item.toolTip
        return item
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if let capability = workspaceCapability(for: item.action),
           allowsWorkspaceCapability(capability) == false
        {
            item.toolTip = L10n.Workbench.sshSessionRequiredTooltip
            item.view?.toolTip = item.toolTip
            return false
        }
        let feature: StacioLicensedFeature?
        switch item.itemIdentifier {
        case ToolbarItem.multiExec: feature = .multiExec
        case ToolbarItem.tunnels: feature = .sshTunnel
        case ToolbarItem.deviceDashboard: feature = .advancedMetrics
        case ToolbarItem.aiAssistant: feature = .aiAgent
        default: feature = nil
        }
        guard let feature else {
            item.toolTip = toolbarTooltip(for: item.itemIdentifier)
            item.view?.toolTip = item.toolTip
            return true
        }
        let enabled = isLicensed(feature)
        item.toolTip = enabled ? toolbarTooltip(for: item.itemIdentifier) : L10n.Import.licenseUnavailableTooltip
        item.view?.toolTip = item.toolTip
        return enabled
    }

    private func refreshToolbarItemAvailability() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            guard toolbarTooltip(for: item.itemIdentifier) != nil else { continue }
            item.isEnabled = validateToolbarItem(item)
        }
        toolbar.validateVisibleItems()
    }

    private func toolbarDefaultToolTip(for identifier: NSToolbarItem.Identifier) -> String? {
        switch identifier {
        case ToolbarItem.sidebar: L10n.Workbench.toggleSidebar
        case ToolbarItem.newSession: L10n.Workbench.newSession
        case ToolbarItem.importSessions: L10n.Workbench.importSessionsTooltip
        case ToolbarItem.split: L10n.Workbench.splitTerminal
        case ToolbarItem.multiExec: L10n.Workbench.multiExecTooltip
        case ToolbarItem.panels: L10n.Workbench.panelsTooltip
        case ToolbarItem.files: L10n.Inspector.files
        case ToolbarItem.browser: L10n.Inspector.browser
        case ToolbarItem.tunnels: L10n.Workbench.tunnels
        case ToolbarItem.deviceDashboard: L10n.Workbench.toggleDeviceDashboard
        case ToolbarItem.aiAssistant: L10n.AI.assistant
        case ToolbarItem.inspector: L10n.Workbench.inspector
        default: nil
        }
    }

    private func shortcutAction(for selector: Selector?) -> StacioShortcutAction? {
        switch selector {
        case #selector(performSingleTerminalLayoutFromToolbar(_:)): .splitSingle
        case #selector(performVerticalSplitTerminalFromToolbar(_:)): .splitVertical
        case #selector(performHorizontalSplitTerminalFromToolbar(_:)): .splitHorizontal
        case #selector(performGridSplitTerminalFromToolbar(_:)): .splitGrid
        case #selector(showFilesFromToolbar(_:)): .showFiles
        case #selector(showBrowserFromToolbar(_:)): .showBrowser
        case #selector(showTunnelsFromToolbar(_:)): .showTunnels
        case #selector(toggleDeviceDashboardFromToolbar(_:)): .toggleDeviceDashboard
        case #selector(showDiagnosticsFromToolbar(_:)): .showDiagnostics
        case #selector(showTerminalMacrosFromToolbar(_:)): .showMacros
        case #selector(showCommandHistoryFromToolbar(_:)): .showCommandHistory
        case #selector(showAIAssistantFromToolbar(_:)): .showAIAssistant
        default: nil
        }
    }

    private func toolbarShortcutActions(for identifier: NSToolbarItem.Identifier) -> [StacioShortcutAction] {
        switch identifier {
        case ToolbarItem.sidebar: [.toggleSidebar]
        case ToolbarItem.newSession: [.newSession]
        case ToolbarItem.split: [.splitSingle, .splitVertical, .splitHorizontal, .splitGrid]
        case ToolbarItem.multiExec: [.multiExec]
        case ToolbarItem.files: [.showFiles]
        case ToolbarItem.browser: [.showBrowser]
        case ToolbarItem.tunnels: [.showTunnels]
        case ToolbarItem.deviceDashboard: [.toggleDeviceDashboard]
        case ToolbarItem.aiAssistant: [.showAIAssistant]
        case ToolbarItem.panels: [.showFiles, .showBrowser, .showTunnels, .toggleDeviceDashboard, .showDiagnostics, .showMacros, .showCommandHistory, .showAIAssistant]
        default: []
        }
    }

    private func toolbarTooltip(for identifier: NSToolbarItem.Identifier) -> String? {
        guard let title = toolbarDefaultToolTip(for: identifier) else { return nil }
        let shortcuts = toolbarShortcutActions(for: identifier)
            .map { StacioShortcutStore.shared.binding(for: $0) }
            .filter { $0.key.isEmpty == false }
            .map(\.displayString)
        guard shortcuts.isEmpty == false else { return title }
        return "\(title)\n快捷键：\(shortcuts.joined(separator: " / "))"
    }

    private func applyShortcut(_ action: StacioShortcutAction, to item: NSMenuItem) {
        let binding = StacioShortcutStore.shared.binding(for: action)
        item.keyEquivalent = binding.menuKeyEquivalent
        item.keyEquivalentModifierMask = binding.modifiers
        if item.isEnabled {
            item.toolTip = "\(action.title)\n快捷键：\(binding.displayString)"
        }
    }

    private func refreshToolbarShortcutTooltips() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            let tooltip = toolbarTooltip(for: item.itemIdentifier)
            item.toolTip = tooltip
            item.view?.toolTip = tooltip
            if let menuToolbarItem = item as? NSMenuToolbarItem {
                for menuItem in menuToolbarItem.menu.items {
                    if let shortcut = shortcutAction(for: menuItem.action) {
                        applyShortcut(shortcut, to: menuItem)
                    }
                }
            }
        }
        toolbar.validateVisibleItems()
    }

    @objc
    public func openLocalShellFromToolbar(_ sender: Any?) throws {
        try workspaceViewController.openLocalShell()
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
        let targetChoices = workspaceViewController.splitTargetChoices()
        if targetChoices.count < 2 {
            guard (try? workspaceViewController.splitCurrentTerminal()) != nil else { return }
            workspaceViewController.setCurrentTerminalSplitLayout(layout)
            return
        }
        guard let selection = multiExecSessionSelector.selectMultiExecTargets(
            targetChoices: targetChoices,
            parentWindow: window
        ) else {
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
        guard allowsWorkspaceCapability(.files) else { return }
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
        let didRevealInspector = revealInspectorForPanelSelection()
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
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: windowFrame)
    }

    @objc
    public func showTunnelsFromToolbar(_ sender: Any?) {
        guard allowsWorkspaceCapability(.tunnels) else { return }
        guard isLicensed(.sshTunnel) else { return }
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.tunnels, preserving: windowFrame) {
            return
        }
        let didRevealInspector = revealInspectorForPanelSelection()
        inspectorViewController?.selectTunnelsTab()
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: windowFrame)
    }

    @objc
    public func showBrowserFromToolbar(_ sender: Any?) {
        guard allowsWorkspaceCapability(.browser) else { return }
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.browser, preserving: windowFrame) {
            return
        }
        let didRevealInspector = revealInspectorForPanelSelection()
        inspectorViewController?.selectBrowserTab()
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: windowFrame)
    }

    @objc
    public func showDiagnosticsFromToolbar(_ sender: Any?) {
        guard allowsWorkspaceCapability(.diagnostics) else { return }
        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }
        if collapseInspectorIfShowingCurrentSection(L10n.Inspector.logs, preserving: windowFrame) {
            return
        }
        let didRevealInspector = revealInspectorForPanelSelection()
        inspectorViewController?.selectDiagnosticsTab()
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: windowFrame)
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
        let didRevealInspector = revealInspectorForPanelSelection()
        inspectorViewController?.reloadTerminalMacros()
        inspectorViewController?.selectTerminalMacrosTab()
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: windowFrame)
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
        let didRevealInspector = revealInspectorForPanelSelection()
        inspectorViewController?.selectCommandHistoryTab()
        finishInspectorPanelRevealIfNeeded(didRevealInspector, preserving: windowFrame)
    }

    @objc
    public func toggleDeviceDashboardFromToolbar(_ sender: Any?) {
        guard allowsWorkspaceCapability(.deviceDashboard) else { return }
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
        guard allowsWorkspaceCapability(.ai) else { return }
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
            applyDefaultInspectorWidthIfNeeded()
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
        layoutWorkbenchContent(in: window)
        centerContainerViewController?.synchronizeEditorLayout()
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    @objc
    public func toggleSidebarFromToolbar(_ sender: Any?) {
        guard !contentSplitViewController.splitViewItems.isEmpty else {
            return
        }
        let sidebar = contentSplitViewController.splitViewItems[0]
        var targetCollapsed = sidebar.isCollapsed
        performProgrammaticSplitLayout {
            if isSidebarTemporarilyExpanded {
                isSidebarTemporarilyExpanded = false
                sidebar.isCollapsed = false
                targetCollapsed = false
            } else {
                targetCollapsed = !sidebar.isCollapsed
                sidebar.isCollapsed = targetCollapsed
            }
        }
        layoutWorkbenchContent(in: window)
        sidebar.isCollapsed = targetCollapsed
        centerContainerViewController?.synchronizeEditorLayout()
    }

    private func temporarilyRevealSidebarFromTitlebarHover() {
        guard !contentSplitViewController.splitViewItems.isEmpty else {
            return
        }
        let sidebar = contentSplitViewController.splitViewItems[0]
        guard sidebar.isCollapsed else {
            return
        }
        performProgrammaticSplitLayout {
            isSidebarTemporarilyExpanded = true
            sidebar.isCollapsed = false
        }
    }

    private func hideTemporarilyRevealedSidebarFromTitlebarHover() {
        guard !contentSplitViewController.splitViewItems.isEmpty,
              isSidebarTemporarilyExpanded
        else { return }
        isSidebarTemporarilyExpanded = false
        performProgrammaticSplitLayout {
            contentSplitViewController.splitViewItems[0].isCollapsed = true
        }
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

    var requiresAIAssistantHostClosure: Bool {
        inspectorViewController?.aiAssistantViewController?.requiresHostClosureSettlement == true
    }

    @discardableResult
    func prepareAIAssistantForHostClosure() async -> Bool {
        guard let assistant = inspectorViewController?.aiAssistantViewController else {
            return true
        }
        return await assistant.prepareForHostClosureAsync()
    }

    private func beginAIAssistantShutdownForWindowClose() {
        guard closePendingAIAssistantShutdown == false else { return }
        closePendingAIAssistantShutdown = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await self.prepareAIAssistantForHostClosure()
            self.closePendingAIAssistantShutdown = false
            guard ready else { return }
            self.window?.performClose(nil)
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isMultiExecBroadcasting else { return false }
        if requiresAIAssistantHostClosure {
            beginAIAssistantShutdownForWindowClose()
            return false
        }
        if allowNextWindowClose {
            allowNextWindowClose = false
            return true
        }
        guard isWindowClosePending == false else { return false }
        isWindowClosePending = true
        let disposition = remoteEditorPresentationCoordinator?.requestClose(
            parentWindow: sender,
            completion: { [weak self, weak sender] resolution in
                guard let self else { return }
                self.isWindowClosePending = false
                guard resolution == .ready else { return }
                guard self.workspaceViewController.closeAllTerminals() else { return }
                self.allowNextWindowClose = true
                sender?.performClose(nil)
            }
        ) ?? .ready
        switch disposition {
        case .ready:
            isWindowClosePending = false
            return workspaceViewController.closeAllTerminals()
        case .cancelled:
            isWindowClosePending = false
            return false
        case .pending:
            return false
        }
    }

    public func startMultiExecFromToolbar(_ sender: Any?) throws {
        guard isLicensed(.multiExec) else {
            throw LicensedFeatureAccessError.licenseRequired(.multiExec)
        }
        let targetChoices = workspaceViewController.multiExecTargetChoices()
        guard targetChoices.count >= 2 else {
            let error = WorkspaceTerminalError.multiExecRequiresMultipleTargets
            multiExecSessionSelector.presentMultiExecError(error, parentWindow: window)
            throw error
        }
        let currentSplitIDs = workspaceViewController.currentSplitTargetIDs()
        let selectedIDs: [String]
        if currentSplitIDs.count >= 2 {
            selectedIDs = currentSplitIDs
        } else if let selection = multiExecSessionSelector.selectMultiExecTargets(
            targetChoices: targetChoices,
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
        let targetChoices = workspaceViewController.multiExecTargetChoices()
        let targets = targetChoices.map(\.target)
        guard let request = multiExecPromptPresenter.promptMultiExec(
            targetChoices: targetChoices,
            parentWindow: window
        ) else {
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

    private func fileTransferRemoteDeviceOptions() -> [FileTransferRemoteDeviceOption] {
        do {
            let databasePath = try databasePathProvider()
            return try CoreBridge.listAllSessionRecords(databasePath: databasePath)
                .compactMap { session -> FileTransferRemoteDeviceOption? in
                    let configJSON = try CoreBridge.getSessionConfigJSON(
                        databasePath: databasePath,
                        id: session.id
                    )
                    return Self.makeFileTransferRemoteDeviceOption(
                        session: session,
                        configJSON: configJSON
                    )
                }
                .sorted {
                    $0.menuTitle.localizedCaseInsensitiveCompare($1.menuTitle) == .orderedAscending
                }
        } catch {
            return []
        }
    }

    private static func makeFileTransferRemoteDeviceOption(
        session: SessionRecord,
        configJSON: String?
    ) -> FileTransferRemoteDeviceOption? {
        let normalizedProtocol = session.protocol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedProtocol == "scp" || normalizedProtocol == "sftp" else {
            return nil
        }
        let summary = BastionSessionDisplaySummaryCodec.summary(
            protocolName: session.protocol,
            gatewayHost: session.host,
            gatewayPort: session.port,
            gatewayUsername: session.username,
            configJSON: configJSON
        )
        let title = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileTransferRemoteDeviceOption(
            sessionID: session.id,
            title: title.isEmpty ? summary.primaryTarget : title,
            protocolName: normalizedProtocol.uppercased(),
            endpoint: summary.displayText
        )
    }

    static func fileTransferRemoteDeviceOptionForTesting(
        session: SessionRecord,
        configJSON: String?
    ) -> FileTransferRemoteDeviceOption? {
        makeFileTransferRemoteDeviceOption(session: session, configJSON: configJSON)
    }

    private func connectFileTransferRemoteDevice(
        sessionID: String,
        to filesPane: RemoteFilesPaneViewController
    ) {
        do {
            let databasePath = try databasePathProvider()
            guard let session = try CoreBridge.listAllSessionRecords(databasePath: databasePath)
                .first(where: { $0.id == sessionID })
            else {
                throw WorkbenchSessionOpenError.savedSessionNotFound(sessionID)
            }
            let selectedProtocol = session.protocol
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let workspaceProtocol = filesPane.fileTransferProtocolName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard selectedProtocol == workspaceProtocol else {
                throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(session.protocol.uppercased())
            }
            let configuration = try fileTransferRemotePaneConfiguration(
                for: session,
                databasePath: databasePath,
                initialRemotePath: "~"
            )
            guard filesPane.attachFileTransferRemoteDevice(configuration) != nil else {
                throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(session.protocol.uppercased())
            }
            markSavedSessionOpened(session)
        } catch {
            quickConnectErrorPresenter.presentQuickConnectError(error, parentWindow: window)
        }
    }

    private func createFileTransferRemoteDevice(
        protocolName: String,
        in filesPane: RemoteFilesPaneViewController
    ) {
        let normalizedProtocol = protocolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let workspaceProtocol = filesPane.fileTransferProtocolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard (normalizedProtocol == "scp" || normalizedProtocol == "sftp"),
              normalizedProtocol == workspaceProtocol
        else {
            quickConnectErrorPresenter.presentQuickConnectError(
                WorkbenchSessionOpenError.protocolRuntimeUnavailable(protocolName.uppercased()),
                parentWindow: window
            )
            return
        }

        let transientDraft: (draft: SessionDraft, cleanup: (() -> Void)?)?
        if let fileTransferRemoteSessionDraftProvider,
           let draft = fileTransferRemoteSessionDraftProvider(normalizedProtocol.uppercased(), window) {
            transientDraft = (draft, nil)
        } else if fileTransferRemoteSessionDraftProvider != nil {
            transientDraft = nil
        } else {
            transientDraft = promptTransientFileTransferSessionDraft(protocolName: normalizedProtocol)
        }
        guard let transientDraft else { return }

        do {
            guard transientDraft.draft.protocol
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalizedProtocol
            else {
                throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(
                    transientDraft.draft.protocol.uppercased()
                )
            }
            let databasePath = try databasePathProvider()
            let configuration = try fileTransferRemotePaneConfiguration(
                for: transientDraft.draft,
                databasePath: databasePath,
                onRuntimeClosed: transientDraft.cleanup
            )
            guard filesPane.attachFileTransferRemoteDevice(configuration) != nil else {
                throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(protocolName.uppercased())
            }
        } catch {
            transientDraft.cleanup?()
            quickConnectErrorPresenter.presentQuickConnectError(error, parentWindow: window)
        }
    }

    private func promptTransientFileTransferSessionDraft(
        protocolName: String
    ) -> (draft: SessionDraft, cleanup: (() -> Void)?)? {
        guard let sessionProtocol = SessionSettingsProtocol(storageKey: protocolName),
              sessionProtocol == .scp || sessionProtocol == .sftp
        else { return nil }
        let credentialManager = resolvedQuickConnectCredentialSaver()
        let controller = SessionSettingsWindowController(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(credentialSaver: credentialManager),
            errorPresenter: AppKitSessionSidebarErrorPresenter(),
            licenseAccess: licenseAccess,
            initialProtocol: sessionProtocol,
            selectableProtocols: [sessionProtocol],
            parentWindowProvider: { [weak self] in self?.window }
        )
        guard let draft = controller.runModal(parentWindow: window) else { return nil }

        let cleanup: (() -> Void)?
        if let credentialID = optionalTrimmed(draft.credentialId),
           let credentialManager {
            cleanup = {
                try? credentialManager.cleanupReplacedCredential(
                    previousCredentialID: credentialID,
                    replacementCredentialID: nil
                )
            }
        } else {
            cleanup = nil
        }
        return (draft, cleanup)
    }

    func saveWorkspaceSessionGroup(
        name: String,
        definition: WorkspaceSessionGroupDefinition
    ) throws -> SessionRecord {
        let databasePath = try databasePathProvider()
        let configJSON = try WorkspaceSessionGroupCodec.encode(definition)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = try CoreBridge.createSessionRecord(
            databasePath: databasePath,
            draft: SessionDraft(
                folderId: nil,
                name: trimmedName.isEmpty ? definition.displayName : trimmedName,
                protocol: definition.sessionProtocol,
                host: definition.paneCountDescription,
                port: 0,
                username: nil,
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: configJSON
            )
        )
        sessionSidebarViewController?.reloadSessions()
        return record
    }

    private func fileTransferRemotePaneConfiguration(
        for session: SessionRecord,
        databasePath: String,
        initialRemotePath: String
    ) throws -> FileTransferRemotePaneConfiguration {
        let normalizedProtocol = session.protocol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedProtocol == "scp" || normalizedProtocol == "sftp" else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(session.protocol)
        }
        let config = try savedSessionSSHConfig(for: session)
        let context = try resolvedSavedSessionContextBuilder().makeTunnelLiveSessionContext(
            config: config,
            databasePath: databasePath
        )
        let title = session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(config.username)@\(config.host)"
            : session.name
        let paneBridge: RemoteFilesBridging
        let paneScheduler: SCPTransferScheduling?
        if normalizedProtocol == "sftp" {
            paneBridge = SFTPRemoteFilesBridgeAdapter(base: remoteFilesBridge)
            paneScheduler = SFTPTransferSchedulerAdapter(
                scheduler: currentFileTransferSFTPScheduler()
            )
        } else {
            paneBridge = remoteFilesBridge
            paneScheduler = currentFileTransferScheduler()
        }
        return FileTransferRemotePaneConfiguration(
            sourceRuntimeID: "saved:\(session.id)",
            context: context,
            title: title,
            bridge: paneBridge,
            transferScheduler: paneScheduler,
            remoteProtocolName: normalizedProtocol.uppercased(),
            initialRemotePath: initialRemotePath,
            remoteFilePathTerminalSender: { [weak workspace = workspaceViewController] path in
                _ = workspace?.sendTextToCurrentTerminal(path)
            }
        )
    }

    private func fileTransferRemotePaneConfiguration(
        for draft: SessionDraft,
        databasePath: String,
        onRuntimeClosed: (() -> Void)?
    ) throws -> FileTransferRemotePaneConfiguration {
        let normalizedProtocol = draft.protocol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedProtocol == "scp" || normalizedProtocol == "sftp" else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(draft.protocol)
        }
        guard draft.port > 0, draft.port <= UInt32(UInt16.max) else {
            throw WorkbenchSessionOpenError.invalidSavedSessionPort(draft.protocol, draft.port)
        }
        let credentialID = optionalTrimmed(draft.credentialId)
        let authMethod: SshAuthMethod
        if let privateKeyPath = optionalTrimmed(draft.privateKeyPath) {
            authMethod = .privateKey(keyPath: privateKeyPath, passphraseRef: credentialID)
        } else if let credentialID {
            authMethod = .password(credentialRef: credentialID)
        } else {
            authMethod = .agent
        }
        let automationPolicy = SessionAutomationPolicy.fromConfigJSON(draft.configJson)
        let config = SshConnectionConfig(
            host: draft.host,
            port: UInt16(draft.port),
            username: optionalTrimmed(draft.username) ?? NSUserName(),
            authMethod: authMethod,
            connectTimeoutMs: automationPolicy.connectTimeoutMs ?? SSHConnectionDefaults.fastConnectTimeoutMs
        )
        let context = try resolvedSavedSessionContextBuilder().makeTunnelLiveSessionContext(
            config: config,
            databasePath: databasePath
        )
        let title = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(config.username)@\(config.host)"
            : draft.name
        let paneBridge: RemoteFilesBridging
        let paneScheduler: SCPTransferScheduling?
        if normalizedProtocol == "sftp" {
            paneBridge = SFTPRemoteFilesBridgeAdapter(base: remoteFilesBridge)
            paneScheduler = SFTPTransferSchedulerAdapter(
                scheduler: currentFileTransferSFTPScheduler()
            )
        } else {
            paneBridge = remoteFilesBridge
            paneScheduler = currentFileTransferScheduler()
        }
        return FileTransferRemotePaneConfiguration(
            sourceRuntimeID: "transient:\(normalizedProtocol)_\(UUID().uuidString.lowercased())",
            context: context,
            title: title,
            bridge: paneBridge,
            transferScheduler: paneScheduler,
            remoteProtocolName: normalizedProtocol.uppercased(),
            initialRemotePath: "~",
            remoteFilePathTerminalSender: { [weak workspace = workspaceViewController] path in
                _ = workspace?.sendTextToCurrentTerminal(path)
            },
            onRuntimeClosed: onRuntimeClosed
        )
    }

    private func openWorkspaceSessionGroup(_ session: SessionRecord) throws -> LiveShellStatus {
        let databasePath = try databasePathProvider()
        guard let configJSON = try CoreBridge.getSessionConfigJSON(
            databasePath: databasePath,
            id: session.id
        ) else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        let definition = try WorkspaceSessionGroupCodec.decode(configJSON)
        guard definition.sessionProtocol.caseInsensitiveCompare(session.protocol) == .orderedSame else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        let sessions = try CoreBridge.listAllSessionRecords(databasePath: databasePath)
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let status: LiveShellStatus
        switch definition.kind {
        case .scp, .sftp:
            status = try openFileTransferWorkspaceGroup(
                session: session,
                definition: definition,
                sessionsByID: sessionsByID,
                databasePath: databasePath
            )
        case .terminalSplit, .terminalMultiExec:
            status = try openTerminalWorkspaceGroup(
                session: session,
                definition: definition,
                sessionsByID: sessionsByID
            )
        }
        workspaceViewController.markCurrentWorkspaceSessionGroupRestored(definition)
        markSavedSessionOpened(session)
        return status
    }

    private func openFileTransferWorkspaceGroup(
        session: SessionRecord,
        definition: WorkspaceSessionGroupDefinition,
        sessionsByID: [String: SessionRecord],
        databasePath: String
    ) throws -> LiveShellStatus {
        let remoteDefinitions = definition.panes.filter { $0.kind == .remoteSession }
        guard let primaryDefinition = remoteDefinitions.first,
              let primarySessionID = primaryDefinition.sessionID,
              let primarySession = sessionsByID[primarySessionID]
        else {
            throw WorkspaceSessionGroupCodecError.unrestorablePane
        }
        let expectedProtocol = definition.kind == .sftp ? "sftp" : "scp"
        try validateFileTransferGroupMember(primarySession, expectedProtocol: expectedProtocol)
        let primaryConfig = try savedSessionSSHConfig(for: primarySession)
        let primaryContext = try resolvedSavedSessionContextBuilder().makeTunnelLiveSessionContext(
            config: primaryConfig,
            databasePath: databasePath
        )
        tunnelLiveSessionStore.replace(with: primaryContext)
        let primaryTitle = primarySession.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(primaryConfig.username)@\(primaryConfig.host)"
            : primarySession.name
        let localPaths = definition.panes.compactMap { pane in
            pane.kind == .localDirectory ? pane.path : nil
        }
        let primaryLocalPath = localPaths.first ?? FileManager.default.homeDirectoryForCurrentUser.path
        let runtimeID: String
        if definition.kind == .sftp {
            runtimeID = try workspaceViewController.openSFTPFilesSession(
                context: primaryContext,
                title: session.name.isEmpty ? primaryTitle : session.name,
                bridge: remoteFilesBridge,
                sftpTransferScheduler: currentFileTransferSFTPScheduler(),
                initialRemotePath: primaryDefinition.path ?? "~",
                initialLocalDirectory: primaryLocalPath
            )
        } else {
            runtimeID = try workspaceViewController.openRemoteFilesSession(
                context: primaryContext,
                title: session.name.isEmpty ? primaryTitle : session.name,
                bridge: remoteFilesBridge,
                transferScheduler: currentFileTransferScheduler(),
                initialRemotePath: primaryDefinition.path ?? "~",
                initialLocalDirectory: primaryLocalPath
            )
        }
        guard let filesPane = workspaceViewController.currentTerminalPane as? RemoteFilesPaneViewController else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        filesPane.markPrimaryFileTransferRemoteDevice(sessionID: primarySession.id)
        for paneDefinition in remoteDefinitions.dropFirst() {
            guard let sessionID = paneDefinition.sessionID,
                  let member = sessionsByID[sessionID]
            else {
                throw WorkbenchSessionOpenError.savedSessionNotFound(paneDefinition.sessionID ?? "")
            }
            try validateFileTransferGroupMember(member)
            let configuration = try fileTransferRemotePaneConfiguration(
                for: member,
                databasePath: databasePath,
                initialRemotePath: paneDefinition.path ?? "~"
            )
            guard filesPane.attachFileTransferRemoteDevice(configuration) != nil else {
                throw WorkspaceSessionGroupCodecError.invalidConfiguration
            }
        }
        filesPane.restoreFileTransferWorkspace(
            additionalLocalDirectoryPaths: Array(localPaths.dropFirst()),
            layout: definition.layout == .grid ? .grid : .columns
        )
        return LiveShellStatus(
            runtimeId: runtimeID,
            status: "running",
            diagnostic: "已恢复 \(definition.displayName)"
        )
    }

    private func validateFileTransferGroupMember(
        _ session: SessionRecord,
        expectedProtocol: String? = nil
    ) throws {
        let memberProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard memberProtocol == "scp" || memberProtocol == "sftp" else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(session.protocol)
        }
        guard let expectedProtocol else { return }
        guard memberProtocol == expectedProtocol else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(
                "\(session.protocol)（分组需要 \(expectedProtocol.uppercased())）"
            )
        }
    }

    private func openTerminalWorkspaceGroup(
        session: SessionRecord,
        definition: WorkspaceSessionGroupDefinition,
        sessionsByID: [String: SessionRecord]
    ) throws -> LiveShellStatus {
        var runtimeIDs: [String] = []
        for pane in definition.panes {
            switch pane.kind {
            case .localTerminal:
                runtimeIDs.append(try workspaceViewController.openLocalShell(initialDirectory: pane.path))
            case .terminalSession:
                guard let sessionID = pane.sessionID,
                      let member = sessionsByID[sessionID]
                else {
                    throw WorkbenchSessionOpenError.savedSessionNotFound(pane.sessionID ?? "")
                }
                let memberProtocol = member.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard ["ssh", "telnet", "serial"].contains(memberProtocol) else {
                    throw WorkbenchSessionOpenError.protocolRuntimeUnavailable(member.protocol)
                }
                runtimeIDs.append(try openSavedSession(member).runtimeId)
            case .localDirectory, .remoteSession:
                throw WorkspaceSessionGroupCodecError.invalidConfiguration
            }
        }
        guard runtimeIDs.count >= 2 else {
            throw WorkspaceSessionGroupCodecError.invalidConfiguration
        }
        let layout = terminalSplitLayout(for: definition.layout)
        let groupTitle = session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? definition.displayName
            : session.name
        if definition.kind == .terminalMultiExec {
            try workspaceViewController.startMultiExecSession(targetIDs: runtimeIDs, title: groupTitle)
            workspaceViewController.setCurrentTerminalSplitLayout(layout)
        } else {
            try workspaceViewController.splitExistingTerminals(
                targetIDs: runtimeIDs,
                layout: layout,
                title: groupTitle
            )
        }
        return LiveShellStatus(
            runtimeId: runtimeIDs[0],
            status: "running",
            diagnostic: "已恢复 \(definition.displayName)"
        )
    }

    private func terminalSplitLayout(
        for layout: WorkspaceSessionGroupLayout
    ) -> TerminalSplitLayoutMode {
        switch layout {
        case .horizontal:
            return .horizontal
        case .grid:
            return .grid
        case .columns, .vertical:
            return .vertical
        }
    }

    @discardableResult
    public func openSavedSession(_ session: SessionRecord) throws -> LiveShellStatus {
        if WorkspaceSessionGroupKind(sessionProtocol: session.protocol) != nil {
            return try openWorkspaceSessionGroup(session)
        }
        return try openSavedSession(session, transientPassword: nil)
    }

    @discardableResult
    private func openSavedSession(
        _ session: SessionRecord,
        transientPassword: String?
    ) throws -> LiveShellStatus {
        let status = try connectSavedSession(session, transientPassword: transientPassword)
        workspaceViewController.setAIHistoryScopeID(
            "session:\(session.id)",
            runtimeID: status.runtimeId
        )
        workspaceViewController.setSavedSessionID(session.id, runtimeID: status.runtimeId)
        return status
    }

    private struct PreparedSavedSessionAuthentication {
        let session: SessionRecord
        let password: String?
    }

    @discardableResult
    private func connectSavedSession(
        _ session: SessionRecord,
        transientPassword: String?
    ) throws -> LiveShellStatus {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProtocol == "ssh" {
            do {
                return try openSavedSSHSession(session, transientPassword: transientPassword)
            } catch {
                guard isMissingSavedCredentialError(error),
                      let repairedSession = try repairMissingSavedSessionCredentialIfPossible(for: session)
                else {
                    throw error
                }
                return try openSavedSSHSession(repairedSession, transientPassword: nil)
            }
        }
        if normalizedProtocol == "telnet" {
            try confirmPlaintextProtocolSession(protocolName: "Telnet")
        }
        let prepared = try prepareSavedSessionAuthentication(session, transientPassword: transientPassword)
        var preparedSession = prepared.session
        guard let password = prepared.password else {
            return try openSavedSession(preparedSession, allowMissingCredentialRepair: true)
        }
        if normalizedProtocol == "scp", optionalTrimmed(preparedSession.privateKeyPath) != nil {
            let ref = TransientSSHCredentialStore.shared.store(password: password)
            do {
                return try openSavedSession(
                    sessionReplacingCredentialID(preparedSession, credentialID: ref),
                    allowMissingCredentialRepair: true
                )
            } catch {
                TransientSSHCredentialStore.shared.discardPassword(for: ref)
                throw error
            }
        }
        if ["scp", "ftp", "telnet", "vnc", "rdp"].contains(normalizedProtocol) {
            preparedSession = try prepareSavedPasswordSessionForConnection(preparedSession, password: password)
            do {
                return try openSavedSession(preparedSession, allowMissingCredentialRepair: true)
            } catch {
                if let credentialID = preparedSession.credentialId,
                   credentialID != session.credentialId {
                    TransientSSHCredentialStore.shared.discardPassword(for: credentialID)
                }
                throw error
            }
        }
        return try openSavedSession(preparedSession, allowMissingCredentialRepair: true)
    }

    private func prepareSavedSessionAuthentication(
        _ session: SessionRecord,
        transientPassword: String?
    ) throws -> PreparedSavedSessionAuthentication {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["scp", "ftp", "telnet", "vnc", "rdp"].contains(normalizedProtocol) else {
            return PreparedSavedSessionAuthentication(session: session, password: optionalTrimmed(transientPassword))
        }
        let hasUsername = optionalTrimmed(session.username) != nil
        let hasPassword = optionalTrimmed(transientPassword) != nil || optionalTrimmed(session.credentialId) != nil
        guard !hasUsername || (!hasPassword && normalizedProtocol == "telnet") else {
            return PreparedSavedSessionAuthentication(session: session, password: optionalTrimmed(transientPassword))
        }
        guard let input = savedSessionAuthenticationPromptPresenter.promptForSavedSessionAuthentication(
            host: session.host,
            initialUsername: session.username,
            parentWindow: window
        ) else {
            throw CancellationError()
        }
        let updated = sessionReplacingUsername(session, username: input.username)
        return PreparedSavedSessionAuthentication(
            session: updated,
            password: optionalTrimmed(transientPassword) ?? optionalTrimmed(input.password)
        )
    }

    @discardableResult
    private func openSavedSSHSession(
        _ originalSession: SessionRecord,
        transientPassword: String?
    ) throws -> LiveShellStatus {
        var session = originalSession
        var suppliedPassword = optionalTrimmed(transientPassword)
        if optionalTrimmed(session.username) == nil
            || (suppliedPassword == nil
                && optionalTrimmed(session.credentialId) == nil
                && !savedSessionUsesAgentAuthentication(session)) {
            guard let input = savedSessionAuthenticationPromptPresenter.promptForSavedSessionAuthentication(
                host: session.host,
                initialUsername: session.username,
                parentWindow: window
            ) else {
                throw CancellationError()
            }
            session = sessionReplacingUsername(session, username: input.username)
            suppliedPassword = suppliedPassword ?? optionalTrimmed(input.password)
        }
        var config = try savedSessionSSHConfig(for: session)
        var transientCredentialRef: String?
        if let password = suppliedPassword {
            if let privateKeyPath = optionalTrimmed(session.privateKeyPath) {
                let ref = TransientSSHCredentialStore.shared.store(password: password)
                transientCredentialRef = ref
                config.authMethod = .privateKey(keyPath: privateKeyPath, passphraseRef: ref)
            } else if savedSessionPasswordSavingConfirmation.shouldSavePassword(
                forHost: session.host,
                username: config.username,
                parentWindow: window
            ) {
                let databasePath = try databasePathProvider()
                let credential = try resolvedSavedSessionCredentialSaver(databasePath: databasePath).saveCredential(
                    kind: "password",
                    label: savedSessionCredentialLabel(displayName: session.name.isEmpty ? session.host : session.name, kind: .password),
                    account: "\(config.username)@\(session.host)",
                    secret: password
                )
                session = try CoreBridge.updateSessionRecord(
                    databasePath: databasePath,
                    id: session.id,
                    update: SessionUpdate(name: nil, protocol: nil, folderId: nil, host: nil, port: nil,
                                          username: nil, privateKeyPath: nil, credentialId: credential.id, tags: nil, configJson: nil)
                )
                config = try savedSessionSSHConfig(for: session)
            } else {
                let ref = TransientSSHCredentialStore.shared.store(password: password)
                transientCredentialRef = ref
                config.authMethod = .password(credentialRef: ref)
            }
        }
        let databasePath = try databasePathProvider()
        do {
            let status = try startRemoteSession(
                config: config,
                title: savedSessionTitle(for: session, username: session.username),
                automationPolicy: savedSessionAutomationPolicy(for: session),
                proxyJumpSelection: savedSessionProxyJumpSelection(for: session),
                proxyJumpSessionResolver: { id in
                    try CoreBridge.listAllSessionRecords(databasePath: databasePath).first(where: { $0.id == id })
                },
                credentialRecovery: { [weak self] in
                    self?.recoverSavedSessionPasswordAfterAuthenticationFailure(for: session)
                }
            )
            workspaceViewController.setManualSessionIcon(savedSessionIconID(for: session), runtimeID: status.runtimeId)
            markSavedSessionOpened(session)
            return status
        } catch {
            if let transientCredentialRef {
                TransientSSHCredentialStore.shared.discardPassword(for: transientCredentialRef)
            }
            throw error
        }
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
                transferScheduler: currentFileTransferScheduler()
            )
            (workspaceViewController.currentTerminalPane as? RemoteFilesPaneViewController)?
                .markPrimaryFileTransferRemoteDevice(sessionID: session.id)
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.scpFilePaneOpened)
        }
        if normalizedProtocol == "sftp" {
            let config = try savedSessionSSHConfig(for: session)
            let context = try resolvedSavedSessionContextBuilder().makeTunnelLiveSessionContext(
                config: config,
                databasePath: databasePathProvider()
            )
            tunnelLiveSessionStore.replace(with: context)
            let title = session.name.isEmpty ? "\(config.username)@\(config.host)" : session.name
            let runtimeID = try workspaceViewController.openSFTPFilesSession(
                context: context,
                title: title,
                bridge: remoteFilesBridge,
                sftpTransferScheduler: currentFileTransferSFTPScheduler()
            )
            (workspaceViewController.currentTerminalPane as? RemoteFilesPaneViewController)?
                .markPrimaryFileTransferRemoteDevice(sessionID: session.id)
            markSavedSessionOpened(session)
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: L10n.Workbench.sftpFilePaneOpened)
        }
        if normalizedProtocol == "ftp" {
            throw WorkbenchSessionOpenError.protocolRemoved("FTP", replacement: "SFTP")
        }
        if normalizedProtocol == "telnet" {
            let config = try savedSessionTelnetConfig(for: session)
            let title = savedSessionTitle(for: session, username: session.username)
            let status = try resolvedTelnetSessionStarter().openSessionTab(config: config, title: title)
            workspaceViewController.setManualSessionIcon(savedSessionIconID(for: session), runtimeID: status.runtimeId)
            markSavedSessionOpened(session)
            return status
        }
        if normalizedProtocol == "console" {
            guard let configJSON = try CoreBridge.getSessionConfigJSON(
                databasePath: databasePathProvider(),
                id: session.id
            ) else {
                throw BLEConsoleErrorCode.configInvalid
            }
            let config: ConsoleSessionConfig
            do {
                config = try CoreBridge.parseConsoleSessionConfig(json: configJSON)
            } catch {
                throw BLEConsoleErrorCode.configInvalid
            }
            guard optionalTrimmed(config.ble.platformBindings.macOsPeripheralUuid) != nil else {
                throw BLEConsoleErrorCode.configInvalid
            }
            let title = session.name.isEmpty ? config.ble.deviceName : session.name
            let runtime = try resolvedConsoleSessionStarter().openSessionTab(config: config, title: title)
            markSavedSessionOpened(session)
            return LiveShellStatus(
                runtimeId: runtime.id,
                status: runtime.status,
                diagnostic: runtime.status
            )
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
                let port = try networkPort(for: session)
                let runtimeArguments = try graphicsRuntimeArguments(
                    for: normalizedProtocol,
                    session: session,
                    launchArguments: launchConfig.arguments
                )
                // 密码通过环境变量传递，避免命令行参数被 ps 读取
                var environment: [String: String] = [:]
                if normalizedProtocol == "vnc" && optionalTrimmed(session.credentialId) != nil {
                    let password = try savedSessionGraphicsPassword(for: session)
                    environment["STACIO_VNC_PASSWORD"] = password
                }
                let request = GraphicsRuntimeStartRequest(
                    protocolName: protocolName,
                    adapterPath: launchConfig.adapterPath,
                    arguments: runtimeArguments,
                    host: session.host,
                    port: port,
                    environment: environment
                )
                let redactedArguments = redactedGraphicsLaunchArguments(runtimeArguments)
                let pane = workspaceViewController.openConnectingGraphicsSession(
                    title: title,
                    protocolName: protocolName,
                    host: session.host,
                    port: port
                )
                pane.fileUploadHandler = { [weak self] localPaths, completion in
                    guard let self else {
                        completion(.failure(GraphicsFileUploadError.unavailable))
                        return
                    }
                    let targets = self.workspaceViewController.activeSSHUploadTargets(
                        matchingHost: session.host
                    )
                    let target: GraphicsSSHUploadTarget
                    do {
                        target = try GraphicsFileUploadCoordinator.selectTarget(from: targets)
                    } catch {
                        completion(.failure(error))
                        return
                    }
                    self.graphicsFileUploadCoordinator.upload(
                        localPaths: localPaths,
                        target: target,
                        transferScheduler: self.currentFileTransferScheduler(),
                        isTargetActive: { [weak self] in
                            self?.workspaceViewController.isSSHUploadTargetActive(target) == true
                        },
                        completion: completion
                    )
                }
                configureGraphicsRuntimeStart(
                    pane: pane,
                    request: request,
                    redactedArguments: redactedArguments
                )
                markSavedSessionOpened(session)
                return LiveShellStatus(
                    runtimeId: pane.runtimeID,
                    status: "connecting",
                    diagnostic: L10n.TerminalLifecycle.connecting
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
        if normalizedProtocol == "rdp" {
            let protocolName = normalizedProtocol.uppercased()
            // Embedded IronRDP client runs in-process; no external adapter
            // binary is required, so we do not gate on adapterPathProvider.
            let adapterPath = graphicsAdapterPathProvider(normalizedProtocol) ?? ""
            let title = session.name.isEmpty ? session.host : session.name
            let port = try networkPort(for: session)
            let pane = workspaceViewController.openConnectingGraphicsSession(
                title: title,
                protocolName: protocolName,
                host: session.host,
                port: port
            )
            let sessionHost = session.host
            let prefill = savedRDPSessionFormPrefill(for: session)
            DispatchQueue.main.async { [weak pane, weak self] in
                guard let self, let pane, let window = self.window else { return }
                self.rdpSessionFormPresenter(window, prefill) { [weak pane, weak self] result in
                    guard let self, let pane else { return }
                    guard let result else {
                        self.workspaceViewController.cancelConnectingGraphicsSession(pane)
                        return
                    }
                    let launchArgs = ["--host", sessionHost, "--port", String(port)] + result.makeAdapterArguments()
                    let request = GraphicsRuntimeStartRequest(
                        protocolName: protocolName,
                        adapterPath: adapterPath,
                        arguments: launchArgs,
                        host: sessionHost,
                        port: port,
                        environment: [:]
                    )
                    let redactedArgs = self.redactedGraphicsLaunchArguments(launchArgs)
                    self.configureGraphicsRuntimeStart(
                        pane: pane,
                        request: request,
                        redactedArguments: redactedArgs
                    )
                    self.markSavedSessionOpened(session)
                }
            }
            return LiveShellStatus(
                runtimeId: pane.runtimeID,
                status: "connecting",
                diagnostic: L10n.TerminalLifecycle.connecting
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
        guard normalizedProtocol == "ssh" || normalizedProtocol == "sftp" || normalizedProtocol == "scp" else {
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
        case "ssh", "sftp", "scp":
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

    private func configureGraphicsRuntimeStart(
        pane: GraphicsSessionPaneViewController,
        request: GraphicsRuntimeStartRequest,
        redactedArguments: [String]
    ) {
        pane.setRetryAction { [weak self, weak pane, request, redactedArguments] in
            guard let self, let pane else { return }
            self.startGraphicsRuntime(
                pane: pane,
                request: request,
                redactedArguments: redactedArguments,
                previousRuntimeID: pane.runtimeID
            )
        }
        startGraphicsRuntime(
            pane: pane,
            request: request,
            redactedArguments: redactedArguments,
            previousRuntimeID: nil
        )
    }

    private func startGraphicsRuntime(
        pane: GraphicsSessionPaneViewController,
        request: GraphicsRuntimeStartRequest,
        redactedArguments: [String],
        previousRuntimeID: String?
    ) {
        let managerBox = WorkbenchUncheckedSendable(value: graphicsRuntimeManager)
        let requestBox = WorkbenchUncheckedSendable(value: request)
        DispatchQueue.global(qos: .userInitiated).async { [weak pane] in
            if let previousRuntimeID {
                _ = managerBox.value.stop(runtimeID: previousRuntimeID)
            }
            let result = Result {
                try managerBox.value.start(request: requestBox.value)
            }
            DispatchQueue.main.async {
                let request = requestBox.value
                guard let pane else {
                    if case let .success(runtimeStatus) = result {
                        _ = managerBox.value.stop(runtimeID: runtimeStatus.runtimeID)
                    }
                    return
                }
                switch result {
                case let .success(runtimeStatus):
                    let diagnostic = GraphicsSessionDiagnostic(
                        protocolName: request.protocolName,
                        host: request.host,
                        port: request.port,
                        adapterPath: request.adapterPath,
                        launchArguments: redactedArguments,
                        status: runtimeStatus.diagnostic,
                        presentation: runtimeStatus.presentation
                    )
                    guard runtimeStatus.status == "running" else {
                        _ = managerBox.value.stop(runtimeID: runtimeStatus.runtimeID)
                        pane.displayConnectionFailure(diagnostic)
                        return
                    }
                    pane.attachRuntime(
                        runtimeID: runtimeStatus.runtimeID,
                        diagnostic: diagnostic,
                        attachment: runtimeStatus.attachment,
                        onClose: { runtimeID in
                            _ = managerBox.value.stop(runtimeID: runtimeID)
                        }
                    )
                case let .failure(error):
                    pane.displayConnectionFailure(
                        GraphicsSessionDiagnostic(
                            protocolName: request.protocolName,
                            host: request.host,
                            port: request.port,
                            adapterPath: request.adapterPath,
                            launchArguments: redactedArguments,
                            status: RuntimeDiagnosticFormatter.userMessage(for: error)
                        )
                    )
                }
            }
        }
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
        // 密码不再通过 --password 命令行参数传递（避免通过 ps 泄漏），
        // 改为通过环境变量 STACIO_VNC_PASSWORD 传递（见调用方构造 GraphicsRuntimeStartRequest）
        return launchArguments
    }

    private func savedSessionGraphicsPassword(for session: SessionRecord) throws -> String {
        guard let credentialID = optionalTrimmed(session.credentialId) else {
            throw KeychainCredentialError.notFound
        }
        if let password = TransientSSHCredentialStore.shared.takePassword(for: credentialID) {
            return password
        }
        return try graphicsCredentialStore.readSecret(
            id: credentialID,
            account: "\(graphicsUsername(for: session))@\(session.host)"
        )
    }

    private func savedSessionTelnetPassword(for session: SessionRecord) throws -> String? {
        guard let credentialID = optionalTrimmed(session.credentialId) else {
            return nil
        }
        return try TransientSSHCredentialStore.shared.takePassword(for: credentialID)
            ?? telnetCredentialStore.readSecret(
                id: credentialID,
                account: "\(optionalTrimmed(session.username) ?? NSUserName())@\(session.host)"
            )
    }

    private func savedSessionTelnetConfig(for session: SessionRecord) throws -> TelnetConnectionConfig {
        TelnetConnectionConfig(
            host: session.host,
            port: try networkPort(for: session),
            username: optionalTrimmed(session.username),
            password: try savedSessionTelnetPassword(for: session),
            connectTimeoutMs: 10_000
        )
    }

    private func prepareSavedPasswordSessionForConnection(
        _ session: SessionRecord,
        password: String
    ) throws -> SessionRecord {
        let username = optionalTrimmed(session.username) ?? NSUserName()
        if savedSessionPasswordSavingConfirmation.shouldSavePassword(
            forHost: session.host,
            username: username,
            parentWindow: window
        ) {
            let databasePath = try databasePathProvider()
            let credential = try resolvedSavedSessionCredentialSaver(databasePath: databasePath).saveCredential(
                kind: "password",
                label: savedSessionCredentialLabel(displayName: session.name.isEmpty ? session.host : session.name, kind: .password),
                account: "\(username)@\(session.host)",
                secret: password
            )
            return try CoreBridge.updateSessionRecord(
                databasePath: databasePath,
                id: session.id,
                update: SessionUpdate(name: nil, protocol: nil, folderId: nil, host: nil, port: nil,
                                      username: nil, privateKeyPath: nil, credentialId: credential.id, tags: nil, configJson: nil)
            )
        }
        let ref = TransientSSHCredentialStore.shared.store(password: password)
        return sessionReplacingCredentialID(session, credentialID: ref)
    }

    private func sessionReplacingCredentialID(_ session: SessionRecord, credentialID: String) -> SessionRecord {
        SessionRecord(
            id: session.id,
            folderId: session.folderId,
            name: session.name,
            protocol: session.protocol,
            host: session.host,
            port: session.port,
            username: session.username,
            privateKeyPath: session.privateKeyPath,
            credentialId: credentialID,
            tags: session.tags,
            lastOpenedAt: session.lastOpenedAt
        )
    }

    private func sessionReplacingUsername(_ session: SessionRecord, username: String) -> SessionRecord {
        SessionRecord(
            id: session.id,
            folderId: session.folderId,
            name: session.name,
            protocol: session.protocol,
            host: session.host,
            port: session.port,
            username: username,
            privateKeyPath: session.privateKeyPath,
            credentialId: session.credentialId,
            tags: session.tags,
            lastOpenedAt: session.lastOpenedAt
        )
    }

    private func savedSessionUsesAgentAuthentication(_ session: SessionRecord) -> Bool {
        guard let databasePath = try? databasePathProvider(),
              let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id),
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return optionalTrimmed(session.credentialId) == nil
        }
        return object["authMode"] as? String != "password"
    }

    private func graphicsUsername(for session: SessionRecord) -> String {
        optionalTrimmed(session.username) ?? NSUserName()
    }

    private func savedRDPSessionFormPrefill(for session: SessionRecord) -> RDPSessionFormPrefill {
        guard let databasePath = try? databasePathProvider(),
              let configJSON = try? CoreBridge.getSessionConfigJSON(
                  databasePath: databasePath,
                  id: session.id
              )
        else {
            return RDPSessionFormPrefill(user: session.username ?? "")
        }
        return RDPSessionFormPrefill(
            user: session.username ?? "",
            configJSON: configJSON
        )
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
            if argument == "--password" || argument == "--gw-pass" {
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

    private func resolvedConsoleSessionStarter() -> ConsoleSessionStarting {
        if let consoleSessionStarter {
            return consoleSessionStarter
        }
        let starter = ConsoleSessionCoordinator(workspace: workspaceViewController)
        consoleSessionStarter = starter
        return starter
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
        let sidebarIsVisible = splitView.arrangedSubviews.first?.isHidden == false
            && contentSplitViewController.splitViewItems.first?.isCollapsed == false
        let restoredSidebarWidth = sidebarIsVisible
            ? storedSplitWidth(column: "sidebar")
                .map { clampedSidebarWidth($0, availableWidth: splitView.bounds.width) }
                ?? currentSidebarWidthForInspectorSizing(splitWidth: splitView.bounds.width)
            : 0
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
        let shouldPinInitialWidth = initialWidth > 0
        let contentSize = window?.contentView?.bounds.size
        let previousMinimumThickness = inspectorSplitViewItem.minimumThickness
        let previousMaximumThickness = inspectorSplitViewItem.maximumThickness
        performProgrammaticSplitLayout {
            inspectorSplitViewItem.holdingPriority = .defaultLow
            if shouldPinInitialWidth {
                inspectorSplitViewItem.minimumThickness = initialWidth
                inspectorSplitViewItem.maximumThickness = initialWidth
                inspectorSplitViewItem.preferredThicknessFraction = initialWidth / splitView.bounds.width
                pendingInspectorWidth = initialWidth
            }
            inspectorSplitViewItem.isCollapsed = false
        }
        guard shouldPinInitialWidth else { return }

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

    private func revealInspectorForPanelSelection() -> Bool {
        guard let inspectorSplitViewItem else { return false }
        let wasCollapsed = inspectorSplitViewItem.isCollapsed
        if wasCollapsed {
            revealInspector()
        }
        return wasCollapsed
    }

    private func finishInspectorPanelRevealIfNeeded(
        _ didRevealInspector: Bool,
        preserving windowFrame: NSRect?
    ) {
        guard didRevealInspector else { return }
        applyDefaultInspectorWidthIfNeeded(
            force: true,
            preferredDefaultWidth: defaultInspectorPanelWidth
        )
        keepSidebarReadableWithoutResizingWindow()
        scheduleInspectorReadabilityRepair(
            preserving: windowFrame,
            preferredDefaultWidth: defaultInspectorPanelWidth,
            force: true
        )
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
    }

    private func synchronizeInspectorVisibilityForCurrentSession() {
        let currentProtocol = workspaceViewController.currentSessionProtocol
        let previousProtocol = lastInspectorSessionProtocol
        lastInspectorSessionProtocol = currentProtocol

        guard let inspectorSplitViewItem,
              let inspectorViewController
        else {
            return
        }

        if Self.automaticallyCollapsesInspector(for: currentProtocol) {
            if previousProtocol == .ssh {
                rememberedSSHInspectorState = RememberedSSHInspectorState(
                    wasExpanded: inspectorSplitViewItem.isCollapsed == false,
                    selection: inspectorViewController.selectionSnapshot
                )
            }
            setInspectorExpandedForSessionSwitch(false)
            return
        }

        guard currentProtocol == .ssh,
              let rememberedSSHInspectorState
        else {
            return
        }

        self.rememberedSSHInspectorState = nil
        inspectorViewController.restoreSelection(rememberedSSHInspectorState.selection)
        setInspectorExpandedForSessionSwitch(rememberedSSHInspectorState.wasExpanded)
    }

    private static func automaticallyCollapsesInspector(
        for sessionProtocol: WorkspaceSessionProtocol
    ) -> Bool {
        switch sessionProtocol {
        case .scp, .sftp, .vnc, .serial, .console, .telnet, .unsupportedRemote, .noSession:
            return true
        case .ssh, .local, .browser, .unmanaged:
            return false
        }
    }

    private func setInspectorExpandedForSessionSwitch(_ expanded: Bool) {
        guard let inspectorSplitViewItem,
              inspectorSplitViewItem.isCollapsed == expanded
        else {
            return
        }

        let windowFrame = window?.frame
        preserveProgrammaticWindowFrame(windowFrame)
        defer {
            restoreProgrammaticFrameIfNeeded(windowFrame)
        }

        if expanded {
            revealInspector()
            applyDefaultInspectorWidthIfNeeded()
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
        layoutWorkbenchContent(in: window)
        centerContainerViewController?.synchronizeEditorLayout()
        scheduleSidebarReadabilityRepair(preserving: windowFrame)
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
        layoutWorkbenchContent(in: window)
        centerContainerViewController?.synchronizeEditorLayout()
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

    private func currentInspectorTransferScheduler() -> SCPTransferScheduling? {
        guard let inspectorViewController else {
            return nil
        }
        _ = inspectorViewController.view
        return inspectorViewController.transferQueueCoordinator
    }

    private func currentFileTransferQueueCoordinator() -> TransferQueueCoordinator {
        if let fileTransferQueueCoordinator {
            return fileTransferQueueCoordinator
        }

        let queueViewController = TransferQueueViewController()
        _ = queueViewController.view
        let coordinator: TransferQueueCoordinator
        if let transferQueueCoordinatorFactory {
            coordinator = transferQueueCoordinatorFactory(queueViewController)
        } else if let transferHistoryStore {
            coordinator = TransferQueueCoordinator(
                historyStore: transferHistoryStore,
                completionNotificationPresenter: Self.defaultTransferCompletionNotificationPresenter(),
                queueViewController: queueViewController
            )
            try? coordinator.restoreHistory()
        } else if let paths = try? StacioPaths() {
            coordinator = TransferQueueCoordinator(
                historyStore: CoreBridgeSCPTransferHistoryStore(databasePath: paths.databaseURL.path),
                completionNotificationPresenter: Self.defaultTransferCompletionNotificationPresenter(),
                queueViewController: queueViewController
            )
            try? coordinator.restoreHistory()
        } else {
            coordinator = TransferQueueCoordinator(
                completionNotificationPresenter: Self.defaultTransferCompletionNotificationPresenter(),
                queueViewController: queueViewController
            )
        }
        fileTransferQueueViewController = queueViewController
        fileTransferQueueCoordinator = coordinator
        return coordinator
    }

    private func currentFileTransferScheduler() -> SCPTransferScheduling {
        currentFileTransferQueueCoordinator()
    }

    private func currentFileTransferSFTPScheduler() -> SFTPTransferScheduling {
        currentFileTransferQueueCoordinator()
    }

    var fileTransferQueueCoordinatorForTesting: TransferQueueCoordinator {
        currentFileTransferQueueCoordinator()
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
              let transferScheduler = currentInspectorTransferScheduler()
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
