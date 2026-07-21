import AppKit
import StacioAgentBridge
import StacioCoreBindings

public final class InspectorViewController: NSViewController {
    private static let headerTopMargin: CGFloat = 18
    private static let headerHorizontalMargin: CGFloat = 12
    private static let minimumHeaderAnchoredWidth: CGFloat = 160
    private static let maximumCompactToolbarTopInset: CGFloat = 16

    private final class CompressibleInspectorRootView: NSView {
        override var fittingSize: NSSize {
            let size = super.fittingSize
            return NSSize(width: 0, height: size.height)
        }
    }

    public struct RemoteFilesBinding {
        public let runtimeID: String
        public let context: TunnelLiveSessionContext
        public let remotePath: String

        public init(runtimeID: String, context: TunnelLiveSessionContext, remotePath: String) {
            self.runtimeID = runtimeID
            self.context = context
            self.remotePath = remotePath
        }
    }

    private enum Section: Int, CaseIterable {
        case files
        case tunnels
        case browser
        case logs
        case macros
        case commandHistory
        case ai

        var label: String {
            switch self {
            case .files: L10n.Inspector.files
            case .tunnels: L10n.Inspector.tunnels
            case .browser: L10n.Inspector.browser
            case .logs: L10n.Inspector.logs
            case .macros: L10n.Inspector.macros
            case .commandHistory: L10n.Inspector.commandHistory
            case .ai: L10n.AI.title
            }
        }
    }

    private enum EditorActionPresentation {
        case closed
        case expanded
        case collapsed
    }

    private let sectionControl = NSSegmentedControl(labels: Section.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
    private let editorCloseButton = InspectorViewController.makeHeaderButton(
        symbolName: "xmark.circle",
        accessibilityDescription: "关闭编辑器",
        identifier: "Stacio.Inspector.editorClose"
    )
    private let editorCollapseButton = InspectorViewController.makeHeaderButton(
        symbolName: "rectangle.compress.vertical",
        accessibilityDescription: "收起编辑器",
        identifier: "Stacio.Inspector.editorCollapse"
    )
    private let editorBackupButton = InspectorViewController.makeHeaderButton(
        symbolName: "externaldrive.badge.plus",
        accessibilityDescription: "备份当前编辑文件",
        identifier: "Stacio.Inspector.editorBackup"
    )
    private let editorAskAIButton = InspectorViewController.makeHeaderButton(
        symbolName: "sparkles",
        accessibilityDescription: "发送当前文件给 AI",
        identifier: "Stacio.Inspector.editorAskAI"
    )
    private let editorRestoreButton = InspectorViewController.makeHeaderButton(
        symbolName: "clock.arrow.circlepath",
        accessibilityDescription: "恢复备份文件",
        identifier: "Stacio.Inspector.editorRestore"
    )
    private let contentContainer = NSView()
    private var editorActionRow: NSStackView?
    private var editorActionLeadingConstraint: NSLayoutConstraint?
    private var editorActionTrailingConstraint: NSLayoutConstraint?
    private var headerTopConstraint: NSLayoutConstraint?
    private weak var headerStackView: NSStackView?
    private var contentContainerTopToRootConstraint: NSLayoutConstraint?
    private var contentContainerTopToHeaderConstraint: NSLayoutConstraint?
    private var pendingToolbarTopInset: CGFloat = 0
    private let transferHistoryStore: SCPTransferHistoryStoring?
    private let tunnelProfileStore: TunnelProfileStoring?
    private let tunnelLiveSessionContextProvider: () -> TunnelLiveSessionContext?
    private let remoteFilePathTerminalSender: (String) -> Void
    private let filesEmbeddedCapabilityOpenHandler: () -> Void
    private let filesEmbeddedCapabilityCloseHandler: (CGFloat) -> Void
    private let tunnelLiveBridge: LiveTunnelCoreBridging
    private let remoteBrowserRuntimeBridge: TunnelRuntimeBridging?
    private let remoteBrowserLocalPortProvider: () -> UInt16
    private let remoteFilesBridge: RemoteFilesBridging
    private let commandHistoryProvider: () -> [TerminalCommandHistoryEntry]
    private let commandHistoryPasteHandler: (String) -> Void
    private let terminalMacroProvider: () -> [TerminalMacroRecord]
    private let terminalMacroStartHandler: () -> Bool
    private let terminalMacroStopHandler: (String) -> Void
    private let terminalMacroPlayHandler: (TerminalMacroRecord) -> Void
    private let terminalMacroRenameHandler: (TerminalMacroRecord, String) -> Void
    private let terminalMacroDeleteHandler: (TerminalMacroRecord) -> Void
    private let tunnelEndpointSessionResolver: TunnelEndpointSessionResolving?
    private let tunnelEndpointContextBuilder: TunnelLiveSessionContextBuilding?
    private let databasePathProvider: () throws -> String
    private let settingsStore: AppSettingsStore
    private let transferCompletionNotificationPresenter: TransferCompletionNotificationPresenting
    private let transferQueueCoordinatorFactory: ((TransferQueueViewController) -> TransferQueueCoordinator)?
    private let multiExecAuditStore: MultiExecAuditListing?
    private let agentAuditStore: AgentActionAuditListing?
    private let importReportStore: ImportReportListing?
    private var sectionViews: [Section: NSView] = [:]
    private var sectionViewControllers: [Section: NSViewController] = [:]
    private var currentSection: Section = .files
    private var didFinishInitialSectionSetup = false
    private var isSynchronizingSelectedSectionLayout = false
    private var isHeaderHorizontalLayoutSynchronizationScheduled = false
    public private(set) var filesViewController: FilesViewController?
    private var filesCoordinator: FilesCoordinator?
    private var remoteFilesBinding: RemoteFilesBinding?
    private var isRemoteFilesBindingDisconnected = false
    private var pendingDirectoryFollowWorkItem: DispatchWorkItem?
    private var lastRequestedRemoteFilesPath: String?
    private let directoryFollowDebounceInterval: TimeInterval = 0.08
    public private(set) var transferQueueViewController: TransferQueueViewController?
    public private(set) var transferQueueCoordinator: TransferQueueCoordinator?
    public private(set) var tunnelsViewController: TunnelsViewController?
    public private(set) var remoteBrowserViewController: RemoteNetworkBrowserViewController?
    public private(set) var diagnosticsViewController: DiagnosticsViewController?
    public private(set) var deviceMetricsViewController: DeviceMetricsDashboardViewController?
    public private(set) var terminalMacroViewController: TerminalMacroViewController?
    public private(set) var commandHistoryViewController: CommandHistoryViewController?
    public private(set) var aiAssistantViewController: AIAssistantPanelViewController?

    public init(
        transferHistoryStore: SCPTransferHistoryStoring? = nil,
        tunnelProfileStore: TunnelProfileStoring? = nil,
        multiExecAuditStore: MultiExecAuditListing? = nil,
        agentAuditStore: AgentActionAuditListing? = nil,
        importReportStore: ImportReportListing? = nil,
        aiAssistantViewController: AIAssistantPanelViewController? = nil,
        tunnelLiveSessionContextProvider: @escaping () -> TunnelLiveSessionContext? = { nil },
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in },
        filesEmbeddedCapabilityOpenHandler: @escaping () -> Void = {},
        filesEmbeddedCapabilityCloseHandler: @escaping (CGFloat) -> Void = { _ in },
        tunnelLiveBridge: LiveTunnelCoreBridging = CoreLiveTunnelBridge(),
        remoteBrowserRuntimeBridge: TunnelRuntimeBridging? = nil,
        remoteBrowserLocalPortProvider: @escaping () -> UInt16 = RemoteNetworkBrowserViewController.availableLoopbackPortForInspector,
        remoteFilesBridge: RemoteFilesBridging = CoreBridgeRemoteFilesBridge(),
        commandHistoryProvider: @escaping () -> [TerminalCommandHistoryEntry] = { [] },
        commandHistoryPasteHandler: @escaping (String) -> Void = { _ in },
        terminalMacroProvider: @escaping () -> [TerminalMacroRecord] = { [] },
        terminalMacroStartHandler: @escaping () -> Bool = { false },
        terminalMacroStopHandler: @escaping (String) -> Void = { _ in },
        terminalMacroPlayHandler: @escaping (TerminalMacroRecord) -> Void = { _ in },
        terminalMacroRenameHandler: @escaping (TerminalMacroRecord, String) -> Void = { _, _ in },
        terminalMacroDeleteHandler: @escaping (TerminalMacroRecord) -> Void = { _ in },
        tunnelEndpointSessionResolver: TunnelEndpointSessionResolving? = nil,
        tunnelEndpointContextBuilder: TunnelLiveSessionContextBuilding? = nil,
        databasePathProvider: @escaping () throws -> String = { try StacioPaths().databaseURL.path },
        settingsStore: AppSettingsStore = .shared,
        transferCompletionNotificationPresenter: TransferCompletionNotificationPresenting? = nil,
        transferQueueCoordinatorFactory: ((TransferQueueViewController) -> TransferQueueCoordinator)? = nil
    ) {
        self.transferHistoryStore = transferHistoryStore
        self.tunnelProfileStore = tunnelProfileStore
        self.multiExecAuditStore = multiExecAuditStore
        self.agentAuditStore = agentAuditStore
        self.importReportStore = importReportStore
        self.aiAssistantViewController = aiAssistantViewController
        self.tunnelLiveSessionContextProvider = tunnelLiveSessionContextProvider
        self.remoteFilePathTerminalSender = remoteFilePathTerminalSender
        self.filesEmbeddedCapabilityOpenHandler = filesEmbeddedCapabilityOpenHandler
        self.filesEmbeddedCapabilityCloseHandler = filesEmbeddedCapabilityCloseHandler
        self.tunnelLiveBridge = tunnelLiveBridge
        self.remoteBrowserRuntimeBridge = remoteBrowserRuntimeBridge
        self.remoteBrowserLocalPortProvider = remoteBrowserLocalPortProvider
        self.remoteFilesBridge = remoteFilesBridge
        self.commandHistoryProvider = commandHistoryProvider
        self.commandHistoryPasteHandler = commandHistoryPasteHandler
        self.terminalMacroProvider = terminalMacroProvider
        self.terminalMacroStartHandler = terminalMacroStartHandler
        self.terminalMacroStopHandler = terminalMacroStopHandler
        self.terminalMacroPlayHandler = terminalMacroPlayHandler
        self.terminalMacroRenameHandler = terminalMacroRenameHandler
        self.terminalMacroDeleteHandler = terminalMacroDeleteHandler
        self.tunnelEndpointSessionResolver = tunnelEndpointSessionResolver
        self.tunnelEndpointContextBuilder = tunnelEndpointContextBuilder
        self.databasePathProvider = databasePathProvider
        self.settingsStore = settingsStore
        self.transferCompletionNotificationPresenter = transferCompletionNotificationPresenter
            ?? NoopTransferCompletionNotificationPresenter()
        self.transferQueueCoordinatorFactory = transferQueueCoordinatorFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = CompressibleInspectorRootView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        StacioDesignSystem.applyInspectorSurface(container)
        container.additionalSafeAreaInsets = NSEdgeInsets(top: pendingToolbarTopInset, left: 0, bottom: 0, right: 0)

        sectionControl.selectedSegment = currentSection.rawValue
        sectionControl.target = self
        sectionControl.action = #selector(sectionControlChanged(_:))
        sectionControl.translatesAutoresizingMaskIntoConstraints = true
        sectionControl.autoresizingMask = []
        sectionControl.segmentDistribution = .fit
        sectionControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        sectionControl.setContentHuggingPriority(.required, for: .horizontal)
        StacioDesignSystem.styleSegmentedControl(sectionControl)
        for section in Section.allCases {
            sectionControl.setWidth(Self.measuredSegmentWidth(for: section.label), forSegment: section.rawValue)
        }
        sectionControl.frame = NSRect(origin: .zero, size: sectionControlDocumentSize())

        editorCloseButton.target = self
        editorCloseButton.action = #selector(editorCloseButtonPressed(_:))
        editorCollapseButton.target = self
        editorCollapseButton.action = #selector(editorCollapseButtonPressed(_:))
        editorBackupButton.target = self
        editorBackupButton.action = #selector(editorBackupButtonPressed(_:))
        editorAskAIButton.target = self
        editorAskAIButton.action = #selector(editorAskAIButtonPressed(_:))
        editorRestoreButton.target = self
        editorRestoreButton.action = #selector(editorRestoreButtonPressed(_:))

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setAccessibilityIdentifier("Stacio.Inspector.content")
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let files = FilesViewController(settingsStore: settingsStore)
        let transferQueue = TransferQueueViewController()
        let diagnostics = DiagnosticsViewController(
            auditStore: multiExecAuditStore ?? makeDefaultMultiExecAuditStore(),
            agentAuditStore: agentAuditStore ?? makeDefaultAgentActionAuditStore(),
            importReportStore: importReportStore ?? makeDefaultImportReportStore(),
            settingsStore: settingsStore
        )
        filesViewController = files
        files.onSendPathToTerminal = { [remoteFilePathTerminalSender] path in
            remoteFilePathTerminalSender(path)
        }
        files.onAIQuestionRequested = { [weak self] question in
            self?.showAIAssistantForFileQuestion(question)
        }
        files.onEmbeddedCapabilityWillOpen = { [weak self, filesEmbeddedCapabilityOpenHandler] in
            filesEmbeddedCapabilityOpenHandler()
            self?.updateEditorActionControls(.expanded)
            self?.synchronizeHeaderHorizontalLayout()
        }
        files.onEmbeddedCapabilityClosed = { [weak self, filesEmbeddedCapabilityCloseHandler] fileBrowserWidth in
            filesEmbeddedCapabilityCloseHandler(fileBrowserWidth)
            self?.updateEditorActionControls()
            self?.synchronizeHeaderHorizontalLayout()
        }
        files.onFileBrowserPaneFrameChanged = { [weak self] in
            self?.scheduleHeaderHorizontalLayoutSynchronization()
        }
        transferQueueViewController = transferQueue
        diagnosticsViewController = diagnostics
        deviceMetricsViewController = nil
        transferQueueCoordinator = makeTransferQueueCoordinator(for: transferQueue)
        files.onTransferStatusAction = { [weak self] action, jobID in
            switch action {
            case .retry:
                if self?.transferQueueCoordinator?.retryFailedTransfer(jobID: jobID) != true {
                    self?.transferQueueCoordinator?.onRetryRequested?(jobID)
                }
            case .pause:
                _ = self?.transferQueueCoordinator?.pauseTransfer(jobID: jobID)
            case .resume:
                _ = self?.transferQueueCoordinator?.resumeTransfer(jobID: jobID)
            case .restart:
                _ = self?.transferQueueCoordinator?.restartTransfer(jobID: jobID)
            case .stop:
                _ = self?.transferQueueCoordinator?.stopTransfer(jobID: jobID)
            }
        }
        transferQueueCoordinator?.onSnapshotChanged = { [weak files] snapshot in
            files?.setTransferStatusSnapshot(snapshot)
        }

        filesCoordinator = FilesCoordinator(
            bridge: remoteFilesBridge,
            filesViewController: files,
            liveSessionContextProvider: { [weak self, tunnelLiveSessionContextProvider] in
                guard self?.isRemoteFilesBindingDisconnected != true else {
                    return nil
                }
                return self?.remoteFilesBinding?.context ?? tunnelLiveSessionContextProvider()
            },
            liveSessionRuntimeIDProvider: { [weak self] in
                self?.remoteFilesBinding?.runtimeID
            },
            transferScheduler: transferQueueCoordinator,
            remoteEditSessionIDProvider: { [weak self] in
                self?.remoteFilesBinding?.runtimeID ?? "inspector"
            }
        )

        let tunnels = TunnelsViewController(
            runtimeBridge: CoreBridgeTunnelRuntimeBridge(
                liveSessionContextProvider: tunnelLiveSessionContextProvider,
                liveBridge: tunnelLiveBridge,
                endpointSessionResolver: tunnelEndpointSessionResolver ?? makeDefaultTunnelEndpointSessionResolver(),
                endpointContextBuilder: tunnelEndpointContextBuilder ?? makeDefaultTunnelEndpointContextBuilder(),
                databasePathProvider: databasePathProvider
            ),
            profileStore: tunnelProfileStore ?? makeDefaultTunnelProfileStore()
        )
        tunnelsViewController = tunnels

        let remoteBrowserBridge = remoteBrowserRuntimeBridge ?? CoreBridgeTunnelRuntimeBridge(
            liveSessionContextProvider: tunnelLiveSessionContextProvider,
            liveBridge: tunnelLiveBridge,
            endpointSessionResolver: tunnelEndpointSessionResolver ?? makeDefaultTunnelEndpointSessionResolver(),
            endpointContextBuilder: tunnelEndpointContextBuilder ?? makeDefaultTunnelEndpointContextBuilder(),
            databasePathProvider: databasePathProvider
        )
        let remoteBrowser = RemoteNetworkBrowserViewController(
            runtimeBridge: remoteBrowserBridge,
            localPortProvider: remoteBrowserLocalPortProvider
        )
        remoteBrowserViewController = remoteBrowser

        let aiAssistant = aiAssistantViewController ?? makeDefaultAIAssistantViewController()
        aiAssistantViewController = aiAssistant
        aiAssistant.currentRemoteFileAttachmentProvider = { [weak self] in
            guard let filesCoordinator = self?.filesCoordinator else {
                throw AIAssistantRemoteFileAttachmentError.unsupportedProtocol
            }
            return try filesCoordinator.makeSelectedRemoteFileAIContextAttachment()
        }
        aiAssistant.currentRemoteFileAttachmentAvailabilityProvider = { [weak self] in
            self?.filesCoordinator?.canAttachSelectedRemoteFileAsAIContext() ?? false
        }
        let commandHistory = CommandHistoryViewController()
        commandHistory.setEntries(commandHistoryProvider())
        commandHistory.onPasteCommand = { [commandHistoryPasteHandler] command in
            commandHistoryPasteHandler(command)
        }
        commandHistoryViewController = commandHistory
        let terminalMacros = TerminalMacroViewController()
        terminalMacros.onRefreshMacros = { [terminalMacroProvider] in
            terminalMacroProvider()
        }
        terminalMacros.onStartRecording = { [terminalMacroStartHandler] in
            terminalMacroStartHandler()
        }
        terminalMacros.onStopRecording = { [terminalMacroStopHandler] name in
            terminalMacroStopHandler(name)
        }
        terminalMacros.onPlayMacro = { [terminalMacroPlayHandler] macro in
            terminalMacroPlayHandler(macro)
        }
        terminalMacros.onRenameMacro = { [terminalMacroRenameHandler] macro, name in
            terminalMacroRenameHandler(macro, name)
        }
        terminalMacros.onDeleteMacro = { [terminalMacroDeleteHandler] macro in
            terminalMacroDeleteHandler(macro)
        }
        terminalMacroViewController = terminalMacros

        sectionViewControllers = [
            .files: files,
            .tunnels: tunnels,
            .browser: remoteBrowser,
            .logs: diagnostics,
            .macros: terminalMacros,
            .commandHistory: commandHistory,
            .ai: aiAssistant
        ]

        for controller in sectionViewControllers.values {
            addChild(controller)
        }

        let editorActionRow = NSStackView(views: [
            editorCloseButton,
            editorCollapseButton,
            editorBackupButton,
            editorAskAIButton,
            editorRestoreButton,
            NSView()
        ])
        editorActionRow.setAccessibilityIdentifier("Stacio.Inspector.editorActions")
        editorActionRow.orientation = .horizontal
        editorActionRow.alignment = .centerY
        editorActionRow.spacing = 6
        editorActionRow.translatesAutoresizingMaskIntoConstraints = false
        self.editorActionRow = editorActionRow
        editorActionRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editorActionRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRowContainer = NSView()
        headerRowContainer.translatesAutoresizingMaskIntoConstraints = false
        headerRowContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerRowContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRowContainer.addSubview(editorActionRow)

        let topBar = NSStackView(views: [headerRowContainer])
        topBar.setAccessibilityIdentifier("Stacio.Inspector.header")
        topBar.orientation = .vertical
        topBar.alignment = .width
        topBar.spacing = 10
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStackView = topBar

        container.addSubview(topBar)
        container.addSubview(contentContainer)

        let editorActionLeadingConstraint = editorActionRow.leadingAnchor.constraint(
            equalTo: headerRowContainer.leadingAnchor
        )
        let editorActionTrailingConstraint = editorActionRow.trailingAnchor.constraint(
            equalTo: headerRowContainer.trailingAnchor
        )
        let compactTopInset = Self.headerTopMargin + pendingToolbarTopInset
        let headerTopConstraint = topBar.topAnchor.constraint(
            equalTo: container.topAnchor,
            constant: compactTopInset
        )
        let contentContainerTopToRootConstraint = contentContainer.topAnchor.constraint(
            equalTo: container.topAnchor,
            constant: compactTopInset
        )
        let contentContainerTopToHeaderConstraint = contentContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8)
        self.editorActionLeadingConstraint = editorActionLeadingConstraint
        self.editorActionTrailingConstraint = editorActionTrailingConstraint
        self.headerTopConstraint = headerTopConstraint
        self.contentContainerTopToRootConstraint = contentContainerTopToRootConstraint
        self.contentContainerTopToHeaderConstraint = contentContainerTopToHeaderConstraint

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.headerHorizontalMargin),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.headerHorizontalMargin),
            headerTopConstraint,

            editorActionLeadingConstraint,
            editorActionTrailingConstraint,
            editorActionRow.topAnchor.constraint(equalTo: headerRowContainer.topAnchor),
            editorActionRow.bottomAnchor.constraint(equalTo: headerRowContainer.bottomAnchor),

            contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentContainerTopToRootConstraint,
            contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        switchToSection(.files)
        updateEditorActionControls(.closed)
        didFinishInitialSectionSetup = true
        view = container
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        synchronizeSectionControlDocumentSize()
        synchronizeSelectedSectionLayout()
        if synchronizeHeaderHorizontalLayout() {
            view.needsLayout = true
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        synchronizeSectionControlDocumentSize()
    }

    public func setToolbarTopInset(_ toolbarTopInset: CGFloat) {
        let clampedToolbarTopInset = min(max(0, toolbarTopInset), Self.maximumCompactToolbarTopInset)
        guard abs(pendingToolbarTopInset - clampedToolbarTopInset) > 0.5 else {
            return
        }
        pendingToolbarTopInset = clampedToolbarTopInset
        applyToolbarTopInsetIfNeeded()
    }

    public func synchronizeSelectedSectionLayoutAfterColumnResize(hostView: NSView? = nil) {
        synchronizeSectionControlDocumentSize()
        if let hostView,
           view.superview === hostView
        {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            if view.frame != hostView.bounds {
                view.frame = hostView.bounds
            }
        }
        hostView?.needsLayout = true
        view.needsLayout = true
        contentContainer.needsLayout = true
        sectionViews[currentSection]?.needsLayout = true
        layoutContentContainerFrameManuallyIfNeeded()
        if let childView = sectionViews[currentSection] {
            childView.translatesAutoresizingMaskIntoConstraints = true
            childView.autoresizingMask = [.width, .height]
            childView.frame = contentContainer.bounds
        }
        synchronizeSelectedSectionLayout()
        if currentSection == .files {
            filesViewController?.synchronizeInspectorColumnLayout()
        }
        if synchronizeHeaderHorizontalLayout() {
            view.layoutSubtreeIfNeeded()
        }
    }

    public func synchronizeSelectedSectionFrameAfterSplitLayout(hostView: NSView) {
        guard view.superview === hostView else { return }

        synchronizeSectionControlDocumentSize()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        if view.frame != hostView.bounds {
            view.frame = hostView.bounds
        }
        layoutContentContainerFrameManuallyIfNeeded()
        guard let childView = sectionViews[currentSection] else { return }

        childView.translatesAutoresizingMaskIntoConstraints = true
        childView.autoresizingMask = [.width, .height]
        if childView.frame != contentContainer.bounds {
            childView.frame = contentContainer.bounds
        }
        if currentSection == .files {
            filesViewController?.synchronizeInspectorColumnFrameOnly()
        }
        if synchronizeHeaderHorizontalLayout() {
            view.layoutSubtreeIfNeeded()
        }
    }

    public var selectedTabLabel: String? {
        currentSection.label
    }

    public var sectionLabelsForTesting: [String] {
        Section.allCases.map(\.label)
    }

    public var selectedSectionIndexForTesting: Int {
        currentSection.rawValue
    }

    public var sectionControlForTesting: NSSegmentedControl {
        sectionControl
    }

    var maximumCompactToolbarTopInsetForTesting: CGFloat {
        Self.maximumCompactToolbarTopInset
    }

    var effectiveToolbarTopInsetForTesting: CGFloat {
        pendingToolbarTopInset
    }

    public var selectedContentViewControllerForTesting: NSViewController? {
        sectionViewControllers[currentSection]
    }

    public func selectSectionForTesting(_ index: Int) {
        guard let section = Section(rawValue: index) else {
            return
        }
        switchToSection(section)
    }

    public func selectFilesTabForTesting() {
        switchToSection(.files)
    }

    public func selectTunnelsTab() {
        switchToSection(.tunnels)
    }

    public func selectDiagnosticsTab() {
        switchToSection(.logs)
    }

    public func selectBrowserTab() {
        switchToSection(.browser)
    }

    public func selectAIAssistantTab() {
        switchToSection(.ai)
    }

    public func selectCommandHistoryTab() {
        switchToSection(.commandHistory)
    }

    public func selectTerminalMacrosTab() {
        switchToSection(.macros)
    }

    public func selectMetricsTab() {
        switchToSection(.files)
    }

    public func isFilesTabBound(to binding: RemoteFilesBinding?) -> Bool {
        guard let binding else {
            return remoteFilesBinding == nil
        }
        guard let remoteFilesBinding else {
            return false
        }
        return remoteFilesBinding.runtimeID == binding.runtimeID
            && remoteFilesBinding.context.expectedFingerprintSHA256 == binding.context.expectedFingerprintSHA256
            && remoteFilesBinding.remotePath == binding.remotePath
    }

    @discardableResult
    public func selectFilesTabAndLoadCurrentDirectory(remotePath: String = "~") throws -> [RemoteFileEntry] {
        cancelPendingDirectoryFollow()
        remoteFilesBinding = nil
        isRemoteFilesBindingDisconnected = false
        lastRequestedRemoteFilesPath = remotePath
        switchToSection(.files)
        guard let filesCoordinator else {
            return []
        }
        filesCoordinator.refreshCurrentLiveDirectory(remotePath: remotePath)
        return []
    }

    @discardableResult
    public func selectFilesTabAndLoadCurrentDirectory(binding: RemoteFilesBinding) throws -> [RemoteFileEntry] {
        cancelPendingDirectoryFollow()
        remoteFilesBinding = binding
        isRemoteFilesBindingDisconnected = false
        lastRequestedRemoteFilesPath = binding.remotePath
        switchToSection(.files)
        filesViewController?.setDirectoryFollowEnabled(true)
        guard let filesCoordinator else {
            return []
        }
        filesCoordinator.disconnectCurrentLiveDirectory(message: "正在切换文件连接...")
        filesCoordinator.refreshCurrentLiveDirectory(remotePath: binding.remotePath)
        return []
    }

    public func showFilesInitialLoadError(_ error: Error) {
        switchToSection(.files)
        filesCoordinator?.showInitialLoadError(error)
    }

    @discardableResult
    public func disconnectFilesBindingIfNeeded(runtimeID: String) -> Bool {
        guard remoteFilesBinding?.runtimeID == runtimeID else {
            _ = transferQueueCoordinator?.disconnectTransfers(runtimeID: runtimeID)
            return true
        }
        guard filesViewController?.closeEmbeddedEditorIfNeeded() != false else {
            return false
        }
        do {
            try filesCoordinator?.cleanupRemoteEdits(runtimeID: runtimeID)
        } catch {
            StacioLogStore.shared.append(
                level: .warning,
                category: "RemoteEditCache",
                message: "Failed to clear remote edit cache for closed runtime \(runtimeID): \(error)",
                sensitiveValues: [runtimeID]
            )
        }
        _ = transferQueueCoordinator?.disconnectTransfers(runtimeID: runtimeID)
        cancelPendingDirectoryFollow()
        remoteFilesBinding = nil
        isRemoteFilesBindingDisconnected = true
        lastRequestedRemoteFilesPath = nil
        filesCoordinator?.disconnectCurrentLiveDirectory(message: "文件连接已断开。请选择一个已连接的远程终端后重新打开文件。")
        remoteBrowserViewController?.stopRemoteBrowserProxy()
        return true
    }

    public func dismissTransferNotifications(runtimeID: String) {
        if let transferQueueCoordinator {
            transferQueueCoordinator.dismissTransferNotifications(runtimeID: runtimeID)
        } else {
            transferCompletionNotificationPresenter.dismiss(runtimeID: runtimeID)
        }
    }

    public func reattachFilesBindingIfNeeded(
        oldRuntimeID: String,
        runtimeID: String,
        context: TunnelLiveSessionContext?,
        remotePath: String
    ) {
        transferQueueCoordinator?.reattachTransfers(
            oldRuntimeID: oldRuntimeID,
            runtimeID: runtimeID
        )
        guard let binding = remoteFilesBinding,
              binding.runtimeID == oldRuntimeID
        else {
            return
        }
        cancelPendingDirectoryFollow()
        remoteFilesBinding = RemoteFilesBinding(
            runtimeID: runtimeID,
            context: context ?? binding.context,
            remotePath: remotePath
        )
        isRemoteFilesBindingDisconnected = false
    }

    public func unbindFilesFromCurrentTerminalSelection() {
        guard remoteFilesBinding != nil || isRemoteFilesBindingDisconnected == false,
              let filesCoordinator
        else {
            return
        }
        if currentSection == .files,
           filesViewController?.closeEmbeddedEditorIfNeeded() == false
        {
            return
        }

        cancelPendingDirectoryFollow()
        filesCoordinator.invalidatePendingDirectoryRefresh()
        remoteFilesBinding = nil
        isRemoteFilesBindingDisconnected = true
        lastRequestedRemoteFilesPath = nil
        filesCoordinator.disconnectCurrentLiveDirectory(message: "请选择一个已连接的远程终端。")
    }

    public func rebindFilesToCurrentRemoteTerminalIfFollowing(
        binding: RemoteFilesBinding,
        refreshDirectory: Bool = true
    ) {
        guard let filesViewController,
              let filesCoordinator
        else {
            return
        }
        let wasUnbound = remoteFilesBinding == nil
        guard remoteFilesBinding?.runtimeID != binding.runtimeID
            || remoteFilesBinding?.remotePath != binding.remotePath
            || remoteFilesBinding?.context.expectedFingerprintSHA256 != binding.context.expectedFingerprintSHA256
        else {
            return
        }

        cancelPendingDirectoryFollow()
        filesCoordinator.invalidatePendingDirectoryRefresh()
        remoteFilesBinding = binding
        isRemoteFilesBindingDisconnected = false
        filesViewController.setCurrentRemotePath(binding.remotePath)
        guard refreshDirectory else {
            lastRequestedRemoteFilesPath = nil
            return
        }
        guard currentSection == .files else {
            lastRequestedRemoteFilesPath = nil
            return
        }
        guard wasUnbound == false || Self.isRemoteHomeAliasPath(binding.remotePath) == false else {
            lastRequestedRemoteFilesPath = nil
            return
        }
        lastRequestedRemoteFilesPath = binding.remotePath
        filesCoordinator.disconnectCurrentLiveDirectory(message: "正在切换文件连接...")
        filesCoordinator.refreshCurrentLiveDirectory(remotePath: binding.remotePath)
    }

    public func reloadCommandHistory() {
        commandHistoryViewController?.setEntries(commandHistoryProvider())
    }

    public func refreshCurrentTerminalContextPanels() {
        reloadCommandHistory()
        aiAssistantViewController?.followCurrentTerminalContext()
        remoteBrowserViewController?.reloadForCurrentRemoteContext()
    }

    public func reloadTerminalMacros() {
        terminalMacroViewController?.setMacros(terminalMacroProvider())
    }

    public func setTerminalMacroRecording(_ isRecording: Bool) {
        terminalMacroViewController?.setRecording(isRecording)
    }

    public func followRemoteTerminalDirectoryIfEnabled(runtimeID: String, remotePath: String) {
        guard let binding = remoteFilesBinding,
              binding.runtimeID == runtimeID
        else {
            return
        }
        guard let filesViewController,
              filesViewController.isDirectoryFollowEnabled
        else {
            cancelPendingDirectoryFollow()
            return
        }
        let displayedRemotePath = filesViewController.currentRemotePath
        let shouldRequestDirectoryRefresh =
            lastRequestedRemoteFilesPath != remotePath || Self.isRemoteHomeAliasPath(remotePath)
        remoteFilesBinding = RemoteFilesBinding(
            runtimeID: binding.runtimeID,
            context: binding.context,
            remotePath: remotePath
        )
        if currentSection == .files {
            filesViewController.setCurrentRemotePath(remotePath)
        }
        if shouldRequestDirectoryRefresh {
            filesCoordinator?.invalidatePendingDirectoryRefresh()
        }
        guard shouldRequestDirectoryRefresh else {
            cancelPendingDirectoryFollow()
            return
        }
        guard currentSection == .files,
              filesCoordinator != nil
        else {
            cancelPendingDirectoryFollow()
            return
        }

        scheduleDirectoryFollow(runtimeID: runtimeID, remotePath: remotePath, restorePathOnFailure: displayedRemotePath)
    }

    @discardableResult
    public func scheduleDroppedUploadsForBoundRemoteFiles(
        runtimeID: String,
        remoteDirectory: String,
        localPaths: [String]
    ) -> Bool {
        guard let binding = remoteFilesBinding,
              binding.runtimeID == runtimeID,
              isRemoteFilesBindingDisconnected == false,
              let filesCoordinator,
              let transferQueueCoordinator,
              localPaths.isEmpty == false
        else {
            return false
        }
        filesCoordinator.scheduleDroppedUploads(
            localPaths: localPaths,
            remoteDirectory: remoteDirectory,
            runtimeID: runtimeID,
            context: binding.context,
            transferScheduler: transferQueueCoordinator
        )
        return true
    }

    private static func isRemoteHomeAliasPath(_ path: String) -> Bool {
        path == "~" || path.hasPrefix("~/")
    }

    private func scheduleDirectoryFollow(runtimeID: String, remotePath: String, restorePathOnFailure: String) {
        pendingDirectoryFollowWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performScheduledDirectoryFollow(
                runtimeID: runtimeID,
                remotePath: remotePath,
                restorePathOnFailure: restorePathOnFailure
            )
        }
        pendingDirectoryFollowWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(directoryFollowDebounceInterval * 1_000)),
            execute: workItem
        )
    }

    private func performScheduledDirectoryFollow(
        runtimeID: String,
        remotePath: String,
        restorePathOnFailure: String
    ) {
        if pendingDirectoryFollowWorkItem?.isCancelled == true {
            return
        }
        pendingDirectoryFollowWorkItem = nil
        guard let binding = remoteFilesBinding,
              binding.runtimeID == runtimeID,
              binding.remotePath == remotePath,
              let filesViewController,
              filesViewController.isDirectoryFollowEnabled,
              currentSection == .files,
              let filesCoordinator
        else {
            return
        }

        filesCoordinator.refreshCurrentLiveDirectory(
            remotePath: remotePath,
            presentation: .backgroundFollow
        ) { [weak self] normalizedPath in
            guard let self,
                  self.remoteFilesBinding?.runtimeID == runtimeID
            else {
                return
            }
            self.lastRequestedRemoteFilesPath = normalizedPath
            self.remoteFilesBinding = RemoteFilesBinding(
                runtimeID: runtimeID,
                context: binding.context,
                remotePath: normalizedPath
            )
        } onFailure: { [weak self] _, _ in
            guard let self,
                  self.remoteFilesBinding?.runtimeID == runtimeID,
                  self.remoteFilesBinding?.remotePath == remotePath
            else {
                return
            }
            self.filesViewController?.setCurrentRemotePath(restorePathOnFailure)
            self.remoteFilesBinding = RemoteFilesBinding(
                runtimeID: runtimeID,
                context: binding.context,
                remotePath: restorePathOnFailure
            )
        }
    }

    private func cancelPendingDirectoryFollow() {
        pendingDirectoryFollowWorkItem?.cancel()
        pendingDirectoryFollowWorkItem = nil
    }

    @objc private func sectionControlChanged(_ sender: NSSegmentedControl) {
        guard let section = Section(rawValue: sender.selectedSegment) else {
            return
        }
        switchToSection(section)
    }

    @objc private func editorCloseButtonPressed(_ sender: Any?) {
        _ = filesViewController?.closeEmbeddedEditorIfNeeded()
        updateEditorActionControls()
    }

    @objc private func editorCollapseButtonPressed(_ sender: Any?) {
        if filesViewController?.isEmbeddedCapabilityCollapsedForInspectorControls == true {
            filesViewController?.expandEmbeddedCapability()
        } else {
            filesViewController?.collapseEmbeddedCapability()
        }
        updateEditorActionControls()
    }

    @objc private func editorBackupButtonPressed(_ sender: Any?) {
        filesCoordinator?.performBackupFromInspector()
    }

    @objc private func editorAskAIButtonPressed(_ sender: Any?) {
        filesViewController?.requestAIForEmbeddedEditor()
    }

    @objc private func editorRestoreButtonPressed(_ sender: Any?) {
        filesCoordinator?.performRestoreFromInspector()
    }

    private func showAIAssistantForFileQuestion(_ question: String) {
        selectAIAssistantTab()
        aiAssistantViewController?.refreshForCurrentContext()
        aiAssistantViewController?.prefillQuestion(question)
        aiAssistantViewController?.focusQuestionField()
    }

    private func updateEditorActionControls(_ presentation: EditorActionPresentation? = nil) {
        let resolvedPresentation: EditorActionPresentation
        if let presentation {
            resolvedPresentation = presentation
        } else if filesViewController?.hasEmbeddedCapabilityForInspectorControls != true {
            resolvedPresentation = .closed
        } else if filesViewController?.isEmbeddedCapabilityCollapsedForInspectorControls == true {
            resolvedPresentation = .collapsed
        } else {
            resolvedPresentation = .expanded
        }

        switch resolvedPresentation {
        case .closed:
            editorActionRow?.isHidden = true
            configureEditorCollapseButtonForCollapsedState(false)
        case .expanded:
            editorActionRow?.isHidden = false
            editorCloseButton.isHidden = false
            editorCollapseButton.isHidden = false
            editorBackupButton.isHidden = false
            editorAskAIButton.isHidden = false
            editorRestoreButton.isHidden = false
            configureEditorCollapseButtonForCollapsedState(false)
        case .collapsed:
            editorActionRow?.isHidden = false
            editorCloseButton.isHidden = true
            editorCollapseButton.isHidden = false
            editorBackupButton.isHidden = true
            editorAskAIButton.isHidden = true
            editorRestoreButton.isHidden = true
            configureEditorCollapseButtonForCollapsedState(true)
        }
        updateContentContainerTopConstraint(for: currentSection)
    }

    private func configureEditorCollapseButtonForCollapsedState(_ collapsed: Bool) {
        let symbolName = collapsed ? "arrow.up.left.and.arrow.down.right" : "rectangle.compress.vertical"
        let description = collapsed ? "展开编辑器" : "收起编辑器"
        editorCollapseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            ?? NSImage(size: NSSize(width: 14, height: 14))
        editorCollapseButton.toolTip = description
        editorCollapseButton.setAccessibilityLabel(description)
    }

    private func switchToSection(_ section: Section) {
        guard currentSection != section || contentContainer.subviews.isEmpty else {
            return
        }
        if currentSection == .files,
           section != .files,
           filesViewController?.closeEmbeddedEditorIfNeeded() == false
        {
            sectionControl.selectedSegment = currentSection.rawValue
            return
        }

        currentSection = section
        sectionControl.selectedSegment = section.rawValue
        updateContentContainerTopConstraint(for: section)

        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }

        guard let controller = sectionViewControllers[section] else {
            return
        }

        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = true
        childView.autoresizingMask = [.width, .height]
        childView.frame = contentContainer.bounds
        contentContainer.addSubview(childView)
        sectionViews[section] = childView
        loadCurrentFilesDirectoryIfNeeded(for: section)
        loadDiagnosticsActivityIfNeeded(for: section)
        loadCommandHistoryIfNeeded(for: section)
        synchronizeHeaderHorizontalLayout()
    }

    private func updateContentContainerTopConstraint(for section: Section) {
        _ = section
        let shouldShowEditorHeader = editorActionRow?.isHidden == false
        headerStackView?.isHidden = shouldShowEditorHeader == false
        contentContainerTopToHeaderConstraint?.isActive = shouldShowEditorHeader
        contentContainerTopToRootConstraint?.isActive = shouldShowEditorHeader == false
    }

    private func synchronizeSelectedSectionLayout() {
        guard isSynchronizingSelectedSectionLayout == false else { return }
        isSynchronizingSelectedSectionLayout = true
        defer { isSynchronizingSelectedSectionLayout = false }

        synchronizeSectionControlDocumentSize()
        layoutContentContainerFrameManuallyIfNeeded()
        guard let childView = sectionViews[currentSection],
              childView.superview === contentContainer,
              contentContainer.bounds.width > 0,
              contentContainer.bounds.height > 0
        else { return }

        if framesDiffer(childView.frame, contentContainer.bounds) {
            childView.frame = contentContainer.bounds
            childView.needsLayout = true
        }
    }

    private func framesDiffer(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) > 0.5
            || abs(lhs.minY - rhs.minY) > 0.5
            || abs(lhs.width - rhs.width) > 0.5
            || abs(lhs.height - rhs.height) > 0.5
    }

    private func scheduleHeaderHorizontalLayoutSynchronization() {
        guard isHeaderHorizontalLayoutSynchronizationScheduled == false else { return }
        isHeaderHorizontalLayoutSynchronizationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHeaderHorizontalLayoutSynchronizationScheduled = false
            if self.synchronizeHeaderHorizontalLayout() {
                self.view.needsLayout = true
            }
        }
    }

    @discardableResult
    private func synchronizeHeaderHorizontalLayout() -> Bool {
        guard isViewLoaded,
              let editorActionLeadingConstraint,
              let editorActionTrailingConstraint
        else {
            return false
        }

        var editorLeadingInset: CGFloat = 0
        var editorTrailingInset: CGFloat = 0
        if currentSection == .files,
           let filesViewController
        {
            if let editorFrame = filesViewController.embeddedCapabilityFrameForInspectorHeader(in: view) {
                let anchoredLeadingInset = max(0, editorFrame.minX - view.bounds.minX)
                let anchoredTrailingInset = max(0, view.bounds.maxX - editorFrame.maxX)
                if view.bounds.width - anchoredLeadingInset - anchoredTrailingInset >= Self.minimumHeaderAnchoredWidth {
                    editorLeadingInset = anchoredLeadingInset
                    editorTrailingInset = anchoredTrailingInset
                }
            }
        }

        var changed = false
        if abs(editorActionLeadingConstraint.constant - editorLeadingInset) > 0.5 {
            editorActionLeadingConstraint.constant = editorLeadingInset
            changed = true
        }
        let editorTrailingConstant = -editorTrailingInset
        if abs(editorActionTrailingConstraint.constant - editorTrailingConstant) > 0.5 {
            editorActionTrailingConstraint.constant = editorTrailingConstant
            changed = true
        }
        if changed {
            view.needsLayout = true
        }
        return changed
    }

    private func applyToolbarTopInsetIfNeeded() {
        guard isViewLoaded else { return }

        let nextTopConstant = Self.headerTopMargin + pendingToolbarTopInset
        if abs((headerTopConstraint?.constant ?? 0) - nextTopConstant) > 0.5 {
            headerTopConstraint?.constant = nextTopConstant
        }
        if abs((contentContainerTopToRootConstraint?.constant ?? 0) - nextTopConstant) > 0.5 {
            contentContainerTopToRootConstraint?.constant = nextTopConstant
        }
        if view.additionalSafeAreaInsets.top != 0 {
            view.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        view.needsLayout = true
        contentContainer.needsLayout = true
        layoutContentContainerFrameManuallyIfNeeded()
    }

    private func synchronizeSectionControlDocumentSize() {
        let targetDocumentFrame = NSRect(origin: .zero, size: sectionControlDocumentSize())
        if sectionControl.frame != targetDocumentFrame {
            sectionControl.frame = targetDocumentFrame
        }
    }

    private func sectionControlSize() -> NSSize {
        let fittingSize = sectionControl.fittingSize
        let assignedWidth = (0..<sectionControl.segmentCount).reduce(CGFloat(0)) { partial, index in
            partial + max(0, sectionControl.width(forSegment: index))
        }
        return NSSize(
            width: max(ceil(fittingSize.width), ceil(assignedWidth)),
            height: ceil(fittingSize.height)
        )
    }

    private func sectionControlDocumentSize() -> NSSize {
        sectionControlSize()
    }

    private static func measuredSegmentWidth(for label: String) -> CGFloat {
        let measuringControl = NSSegmentedControl(
            labels: [label],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        measuringControl.segmentDistribution = .fit
        StacioDesignSystem.styleSegmentedControl(measuringControl)
        measuringControl.sizeToFit()
        let font = measuringControl.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let measuredTextWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return ceil(max(measuringControl.fittingSize.width, measuredTextWidth + 28))
    }

    private func layoutContentContainerFrameManuallyIfNeeded() {
        guard view.bounds.width > 0,
              view.bounds.height > 0
        else { return }

        let contentTopY: CGFloat
        if editorActionRow?.isHidden == false,
           let headerStackView
        {
            let headerFrame = headerStackView.convert(headerStackView.bounds, to: view)
            contentTopY = headerFrame.minY - 8
        } else {
            contentTopY = view.bounds.maxY - pendingToolbarTopInset - Self.headerTopMargin
        }
        let contentHeight = max(0, min(view.bounds.height, contentTopY))
        let targetFrame = NSRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: contentHeight
        )
        if contentContainer.frame != targetFrame {
            contentContainer.frame = targetFrame
        }
    }

    private func loadCurrentFilesDirectoryIfNeeded(for section: Section) {
        guard section == .files,
              didFinishInitialSectionSetup,
              let filesCoordinator,
              remoteFilesBinding != nil || tunnelLiveSessionContextProvider() != nil
        else { return }

        filesCoordinator.refreshCurrentLiveDirectory(remotePath: remoteFilesBinding?.remotePath ?? "~")
    }

    private func loadDiagnosticsActivityIfNeeded(for section: Section) {
        guard section == .logs,
              didFinishInitialSectionSetup
        else { return }

        diagnosticsViewController?.loadRecentActivityIfNeeded()
    }

    private func loadCommandHistoryIfNeeded(for section: Section) {
        guard section == .commandHistory else { return }
        reloadCommandHistory()
    }

    private func makeDefaultTunnelProfileStore() -> TunnelProfileStoring? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return CoreBridgeTunnelProfileStore(databasePath: databasePath)
    }

    private func makeDefaultTunnelEndpointSessionResolver() -> TunnelEndpointSessionResolving? {
        guard let databasePath = try? databasePathProvider() else {
            return nil
        }
        return StoredTunnelEndpointSessionResolver(
            store: CoreBridgeSessionSidebarStore(databasePath: databasePath)
        )
    }

    private func makeDefaultTunnelEndpointContextBuilder() -> TunnelLiveSessionContextBuilding? {
        SSHConnectionCoordinator(
            connector: CoreBridgeSSHLiveConnector(),
            credentialResolver: SSHCredentialResolver(store: KeychainCredentialStore()),
            hostKeyConfirmer: AppKitHostKeyConfirmer()
        )
    }

    private func makeDefaultMultiExecAuditStore() -> MultiExecAuditListing? {
        guard let paths = try? StacioPaths() else {
            return nil
        }
        return CoreBridgeMultiExecAuditStore(databasePath: paths.databaseURL.path)
    }

    private func makeDefaultImportReportStore() -> ImportReportListing? {
        guard let paths = try? StacioPaths() else {
            return nil
        }
        return CoreBridgeImportReportStore(databasePath: paths.databaseURL.path)
    }

    private func makeDefaultAgentActionAuditStore() -> AgentActionAuditListing? {
        guard let paths = try? StacioPaths() else {
            return nil
        }
        return CoreBridgeAgentActionAuditStore(databasePath: paths.databaseURL.path)
    }

    private func makeTransferQueueCoordinator(
        for transferQueue: TransferQueueViewController
    ) -> TransferQueueCoordinator {
        if let transferQueueCoordinatorFactory {
            return transferQueueCoordinatorFactory(transferQueue)
        }
        if let transferHistoryStore {
            let coordinator = TransferQueueCoordinator(
                historyStore: transferHistoryStore,
                completionNotificationPresenter: transferCompletionNotificationPresenter,
                queueViewController: transferQueue
            )
            try? coordinator.restoreHistory()
            return coordinator
        }

        do {
            let paths = try StacioPaths()
            let coordinator = TransferQueueCoordinator(
                historyStore: CoreBridgeSCPTransferHistoryStore(databasePath: paths.databaseURL.path),
                completionNotificationPresenter: transferCompletionNotificationPresenter,
                queueViewController: transferQueue
            )
            try? coordinator.restoreHistory()
            return coordinator
        } catch {
            return TransferQueueCoordinator(
                completionNotificationPresenter: transferCompletionNotificationPresenter,
                queueViewController: transferQueue
            )
        }
    }

    private func makeDefaultAIAssistantViewController() -> AIAssistantPanelViewController {
        AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: UnavailableAgentCommandExecutor()
            ),
            contextProvider: { nil }
        )
    }

    private static func makeHeaderButton(
        symbolName: String,
        accessibilityDescription: String,
        identifier: String
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(size: NSSize(width: 14, height: 14))
        let button = NSButton(title: "", image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityDescription
        button.setAccessibilityLabel(accessibilityDescription)
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        return button
    }
}

@MainActor
private struct UnavailableAgentCommandExecutor: AgentCommandExecuting {
    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        throw AgentExecutionError.terminalNotFound
    }
}
