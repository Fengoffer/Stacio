import AppKit
import Network
import StacioAgentBridge
import StacioCoreBindings

private struct PendingAgentTaskContinuation {
    let question: String
    let goal: String
    let context: AITerminalContext
    let attachments: [AIAssistantAttachment]
    let completedSteps: [AgentTaskStepResult]
    let modelSelection: AIModelSelection
}

private struct AgentTraceOwnershipKey: Hashable {
    let runtimeID: String
    let requestID: String
}

private enum AIAssistantSurfaceMode: Int {
    case assistant = 0
    case localAgent = 1
}

public final class AIAssistantPanelViewController: NSViewController, NSTextFieldDelegate {
    private static let defaultMessagePreferredWidth: CGFloat = 260
    private static let compactComposerHeight: CGFloat = 124
    private static let contextComposerHeight: CGFloat = 132
    private static let attachmentComposerHeight: CGFloat = 188
    private static let maxAttachmentBytes = 4 * 1024 * 1024
    private static let maxAttachmentTextPreviewCharacters = 8_000
    private static let taskHistoryDisplayLimit = 3
    private static let taskHistoryScanLimit = 24
    private static let unconfiguredProviderMessage = "请先在设置中配置供应商模型"

    public var onCollapse: (() -> Void)?

    private let coordinator: AIAssistantCoordinator
    private let contextProvider: (String?) -> AITerminalContext?
    private let terminalSessionProvider: () -> [AgentTerminalSessionSummary]
    private let settingsStore: AppSettingsStore
    private let modelSelectionSession: AIModelSelectionSession
    private let agentTaskLoopLimits: AgentTaskLoopLimits
    private let taskRecorder: AgentTaskRecording?
    private let taskLister: AgentTaskListing?
    private let conversationHistoryStore: AIAssistantConversationHistoryStoring?
    private let attachmentPicker: () -> [URL]
    private let internalBrowserOpener: (URL) -> Void
    private let externalBrowserOpener: (URL) -> Void
    public var currentRemoteFileAttachmentProvider: (() throws -> AIAssistantAttachment)?
    public var currentRemoteFileAttachmentAvailabilityProvider: (() -> Bool)?
    private let localAgentToolResolver: LocalAgentToolResolving
    private let localAgentProcessLauncherFactory: () -> LocalTerminalProcessLaunching
    private let conversationContainer = NSView()
    private let headerContainer = NSView()
    private let headerIconView = NSImageView()
    private let headerTitleLabel = NSTextField(labelWithString: L10n.AI.assistant)
    private let headerStatusDot = NSView()
    private let headerStatusLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let targetButton = NSButton(title: L10n.AI.targetPicker, target: nil, action: nil)
    private let collapseButton = NSButton(title: L10n.AI.collapse, target: nil, action: nil)
    private let conversationPopUpButton = NSPopUpButton()
    private let newConversationButton = NSButton()
    private let conversationControlsStack = NSStackView()
    private let conversationControlsLabel = NSTextField(labelWithString: "排查会话")
    private let questionField = NSTextField()
    private let composer = AIComposerDropPasteView()
    private let composerAttachmentStack = NSStackView()
    private let composerContextLabel = NSTextField(labelWithString: "")
    private let composerToolbar = NSStackView()
    private let composerAddButton = NSButton()
    private let contextUsageRing = AIContextUsageRingView()
    private let composerPermissionButton = NSButton()
    private let composerModelButton = NSButton()
    private let askButton = NSButton(title: L10n.AI.ask, target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: L10n.AI.noTerminal)
    private let surfaceModeSegmentedControl = NSSegmentedControl(
        labels: ["排查助手", "本地 Agent"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let transcriptScrollView = NSScrollView()
    private let transcriptDocumentView = AIAssistantFlippedView()
    private let transcriptContentStack = AIAssistantFlippedStackView()
    private let transcriptBottomSpacer = NSView()
    private let localAgentContainer = NSStackView()
    private let localAgentHeaderStack = NSStackView()
    private let localAgentTitleLabel = NSTextField(labelWithString: "本地 Agent")
    private let localAgentPopUpButton = NSPopUpButton()
    private let localAgentStatusLabel = NSTextField(labelWithString: "选择本地 Agent，启动原生会话。")
    private let localAgentTerminalHost = NSView()
    private let transcriptStack = NSStackView()
    private let planWorkspaceContainer = NSStackView()
    private let planWorkspaceHeaderLabel = NSTextField(labelWithString: "")
    private let planWorkspaceBodyLabel = NSTextField(labelWithString: "")
    private let planWorkspaceControlsStack = NSStackView()
    private let planWorkspaceConfirmButton = NSButton(title: "确认执行", target: nil, action: nil)
    private let planWorkspaceEditButton = NSButton(title: "编辑计划", target: nil, action: nil)
    private let planWorkspaceCancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let taskControlContainer = NSStackView()
    private let taskControlLabel = NSTextField(labelWithString: "")
    private let taskControlButtonsStack = NSStackView()
    private let taskPauseButton = NSButton(title: L10n.AI.pauseTask, target: nil, action: nil)
    private let taskCancelButton = NSButton(title: L10n.AI.cancelTask, target: nil, action: nil)
    private let taskTakeOverButton = NSButton(title: L10n.AI.takeOverTask, target: nil, action: nil)
    private let taskConfirmCompleteButton = NSButton(title: L10n.AI.confirmTaskComplete, target: nil, action: nil)
    private let taskContinueButton = NSButton(title: L10n.AI.continueTask, target: nil, action: nil)
    private let taskControlDismissButton = NSButton(title: L10n.AI.dismissTaskControl, target: nil, action: nil)
    private let taskHistoryContainer = NSStackView()
    private let taskHistoryHeaderLabel = NSTextField(labelWithString: L10n.AI.recentTasks)
    private let taskHistoryBodyLabel = NSTextField(labelWithString: "")
    private let taskHistoryButtonsStack = NSStackView()
    private let commandCardsStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var commandCards: [AICommandCardView] = []
    private var transcriptEntries: [AITranscriptEntry] = []
    private var traceEventsByRequestID: [String: [AgentTraceEvent]] = [:]
    private var traceActorKindsByRequest: [AgentTraceOwnershipKey: AgentActorKind] = [:]
    private var traceRuntimeTitlesByRequestID: [String: String] = [:]
    private var activeOrchestrator: AgentTaskOrchestrator?
    private var activeAutonomousTask: Task<Void, Never>?
    private var activeAutonomousRunID: UUID?
    private var activeProcessGroupID: UUID?
    private var processGroupTimings: [UUID: AIProcessGroupTiming] = [:]
    private var manualProcessGroupIDsByRequestID: [String: UUID] = [:]
    private var activeAskID: UUID?
    private var activeAskCancellation: AIAssistantRequestCancelling?
    private var activeStreamingAssistantIndex: Int?
    private var pendingTaskContinuation: PendingAgentTaskContinuation?
    private var currentAgentPlan: AgentTaskPlan?
    private var planWorkspaceText = ""
    private var activeTaskRequestID: String?
    private var taskControlRequestIDsByRequestID: [String: [String]] = [:]
    private var taskControlStatusesByRequestID: [String: String] = [:]
    private var taskControlText = ""
    private var taskHistoryText = ""
    private var recentTaskRecords: [AgentTaskSessionRecord] = []
    private var currentProposalTaskRequestID: String?
    private var loadedConversationHistoryRuntimeID: String?
    private var activeConversationIDs: [String: String] = [:]
    private var pendingAssistantConclusionsByRequestID: [String: String] = [:]
    private var terminalBlocksByRequestID: [String: String] = [:]
    private var collapsedTraceRequestIDs: Set<String> = []
    private var appendedTraceEntryKeys: Set<String> = []
    private var appendedVirtualTerminalEntryKeys: Set<String> = []
    private var appendedExecutionResultRequestIDs: Set<String> = []
    private var traceObserver: NSObjectProtocol?
    private var terminalTaskControlObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var composerAddPickerPopover: NSPopover?
    private var composerAddPickerViewController: AIComposerAddPickerViewController?
    private var composerModelPickerPopover: NSPopover?
    private var composerModelPickerViewController: AIComposerModelPickerViewController?
    private var composerPermissionPickerPopover: NSPopover?
    private var composerPermissionPickerViewController: AIComposerPermissionPickerViewController?
    private var composerPreviewWindow: NSWindow?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var conversationBottomToCommandCardsConstraint: NSLayoutConstraint?
    private var conversationBottomToComposerConstraint: NSLayoutConstraint?
    private var conversationBottomToContainerConstraint: NSLayoutConstraint?
    private var commandCardsCollapsedHeightConstraint: NSLayoutConstraint?
    private var questionTopWithoutAttachmentsConstraint: NSLayoutConstraint?
    private var questionTopWithAttachmentsConstraint: NSLayoutConstraint?
    private var selectedRuntimeID: String?
    private var selectedRuntimeIDs: [String] = []
    private var surfaceMode: AIAssistantSurfaceMode = .assistant
    private var activeLocalAgentTool: LocalAgentTool?
    private var localAgentSessionsByTool: [LocalAgentTool: LocalAgentSessionViewController] = [:]
    private var composerAttachments: [AIAssistantAttachment] = []
    private var modelSelectionBeforeTask: AIModelSelection?
    private var capturedTaskModelSelection: AIModelSelection?
    private var planModeEnabled = false
    private var goalModeEnabled = false
    private var contextUsageFraction: Double = 0
    private var contextUsageLabel = "上下文 0%"
    private var isAsking = false
    private var isExecuting = false
    private var lastAppliedTranscriptTextWidth: CGFloat?

    public init(
        coordinator: AIAssistantCoordinator,
        contextProvider: @escaping (String?) -> AITerminalContext?,
        terminalSessionProvider: @escaping () -> [AgentTerminalSessionSummary] = { [] },
        settingsStore: AppSettingsStore = .shared,
        modelSelectionSession: AIModelSelectionSession = AIModelSelectionSession(),
        agentTaskLoopLimits: AgentTaskLoopLimits = AgentTaskLoopLimits(),
        taskRecorder: AgentTaskRecording? = nil,
        taskLister: AgentTaskListing? = nil,
        conversationHistoryStore: AIAssistantConversationHistoryStoring? = nil,
        attachmentPicker: (() -> [URL])? = nil,
        internalBrowserOpener: @escaping (URL) -> Void = { _ in },
        externalBrowserOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        currentRemoteFileAttachmentProvider: (() throws -> AIAssistantAttachment)? = nil,
        currentRemoteFileAttachmentAvailabilityProvider: (() -> Bool)? = nil,
        localAgentToolResolver: LocalAgentToolResolving = LocalAgentToolResolver(),
        localAgentProcessLauncherFactory: @escaping () -> LocalTerminalProcessLaunching = {
            SwiftTermLocalTerminalProcessLauncher()
        }
    ) {
        self.coordinator = coordinator
        self.contextProvider = contextProvider
        self.terminalSessionProvider = terminalSessionProvider
        self.settingsStore = settingsStore
        self.modelSelectionSession = modelSelectionSession
        self.agentTaskLoopLimits = agentTaskLoopLimits
        self.taskRecorder = taskRecorder
        self.taskLister = taskLister
        self.conversationHistoryStore = conversationHistoryStore
        self.attachmentPicker = attachmentPicker ?? Self.pickAttachmentURLs
        self.internalBrowserOpener = internalBrowserOpener
        self.externalBrowserOpener = externalBrowserOpener
        self.currentRemoteFileAttachmentProvider = currentRemoteFileAttachmentProvider
        self.currentRemoteFileAttachmentAvailabilityProvider = currentRemoteFileAttachmentAvailabilityProvider
        self.localAgentToolResolver = localAgentToolResolver
        self.localAgentProcessLauncherFactory = localAgentProcessLauncherFactory
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(
        coordinator: AIAssistantCoordinator,
        contextProvider: @escaping () -> AITerminalContext?
    ) {
        self.init(
            coordinator: coordinator,
            contextProvider: { _ in contextProvider() },
            terminalSessionProvider: { [] }
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let traceObserver {
            NotificationCenter.default.removeObserver(traceObserver)
        }
        if let terminalTaskControlObserver {
            NotificationCenter.default.removeObserver(terminalTaskControlObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    public override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        StacioDesignSystem.applyInspectorSurface(container)
        container.layer?.cornerRadius = 18
        container.layer?.cornerCurve = .continuous

        questionField.placeholderString = L10n.AI.placeholder
        questionField.target = self
        questionField.action = #selector(askButtonPressed(_:))
        questionField.delegate = self
        questionField.setAccessibilityIdentifier("Stacio.AI.question")
        questionField.translatesAutoresizingMaskIntoConstraints = false
        questionField.isBordered = false
        questionField.isBezeled = false
        questionField.drawsBackground = false
        questionField.focusRingType = .none
        questionField.font = .systemFont(ofSize: 14)
        composerAttachmentStack.orientation = .horizontal
        composerAttachmentStack.spacing = 8
        composerAttachmentStack.alignment = .top
        composerAttachmentStack.distribution = .fill
        composerAttachmentStack.translatesAutoresizingMaskIntoConstraints = false
        composerAttachmentStack.setAccessibilityIdentifier("Stacio.AI.composer.attachments")
        composerAttachmentStack.isHidden = true
        composerContextLabel.font = .systemFont(ofSize: 11, weight: .medium)
        composerContextLabel.textColor = .secondaryLabelColor
        composerContextLabel.lineBreakMode = .byTruncatingMiddle
        composerContextLabel.translatesAutoresizingMaskIntoConstraints = false
        composerContextLabel.setAccessibilityIdentifier("Stacio.AI.composer.context")
        composerContextLabel.isHidden = true
        composerToolbar.orientation = .horizontal
        composerToolbar.spacing = 8
        composerToolbar.alignment = .centerY
        composerToolbar.distribution = .fill
        composerToolbar.translatesAutoresizingMaskIntoConstraints = false
        composerToolbar.setAccessibilityIdentifier("Stacio.AI.composer.toolbar")
        composerAddButton.target = self
        composerAddButton.action = #selector(composerAddButtonPressed(_:))
        composerAddButton.setAccessibilityIdentifier("Stacio.AI.composer.add")
        composerAddButton.translatesAutoresizingMaskIntoConstraints = false
        configureComposerIconButton(composerAddButton, symbolName: "plus", accessibilityLabel: "添加上下文")
        contextUsageRing.translatesAutoresizingMaskIntoConstraints = false
        contextUsageRing.setAccessibilityIdentifier("Stacio.AI.composer.contextUsage")
        contextUsageRing.setContentHuggingPriority(.required, for: .horizontal)
        contextUsageRing.setContentCompressionResistancePriority(.required, for: .horizontal)
        composerPermissionButton.target = self
        composerPermissionButton.action = #selector(composerPermissionButtonPressed(_:))
        composerPermissionButton.setAccessibilityIdentifier("Stacio.AI.composer.permission")
        composerPermissionButton.translatesAutoresizingMaskIntoConstraints = false
        configureComposerPillButton(composerPermissionButton, symbolName: "shield", title: "")
        composerModelButton.target = self
        composerModelButton.action = #selector(composerModelButtonPressed(_:))
        composerModelButton.setAccessibilityIdentifier("Stacio.AI.composer.model")
        composerModelButton.translatesAutoresizingMaskIntoConstraints = false
        configureComposerPillButton(composerModelButton, symbolName: nil, title: "")
        composerModelButton.cell?.lineBreakMode = .byTruncatingMiddle
        composerModelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        askButton.target = self
        askButton.action = #selector(askButtonPressed(_:))
        askButton.setAccessibilityIdentifier("Stacio.AI.ask")
        askButton.translatesAutoresizingMaskIntoConstraints = false
        configureIconButton(askButton, symbolName: "arrow.up", accessibilityLabel: L10n.AI.ask, emphasized: true)
        targetButton.target = self
        targetButton.action = #selector(targetButtonPressed(_:))
        targetButton.setAccessibilityIdentifier("Stacio.AI.targetPicker")
        targetButton.translatesAutoresizingMaskIntoConstraints = false
        configureComposerPillButton(targetButton, symbolName: nil, title: L10n.AI.targetPicker)
        collapseButton.target = self
        collapseButton.action = #selector(collapseButtonPressed(_:))
        collapseButton.setAccessibilityIdentifier("Stacio.AI.collapse")
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        configureIconButton(collapseButton, symbolName: "chevron.down", accessibilityLabel: L10n.AI.collapse)
        conversationPopUpButton.target = self
        conversationPopUpButton.action = #selector(conversationSelectionChanged(_:))
        conversationPopUpButton.setAccessibilityIdentifier("Stacio.AI.conversationPicker")
        conversationPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        newConversationButton.target = self
        newConversationButton.action = #selector(newConversationButtonPressed(_:))
        newConversationButton.setAccessibilityIdentifier("Stacio.AI.newConversation")
        newConversationButton.translatesAutoresizingMaskIntoConstraints = false
        configureIconButton(newConversationButton, symbolName: "plus", accessibilityLabel: "新建排查会话")
        conversationControlsStack.orientation = .horizontal
        conversationControlsStack.alignment = .centerY
        conversationControlsStack.spacing = 6
        conversationControlsStack.translatesAutoresizingMaskIntoConstraints = false
        conversationControlsStack.setAccessibilityIdentifier("Stacio.AI.conversationControls")
        conversationControlsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        conversationControlsLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        let conversationControlsSpacer = NSView()
        conversationControlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        conversationControlsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [
            conversationControlsLabel,
            conversationControlsSpacer,
            conversationPopUpButton,
            newConversationButton
        ].forEach(conversationControlsStack.addArrangedSubview)

        conversationContainer.setAccessibilityIdentifier("Stacio.AI.conversation")
        conversationContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.setAccessibilityIdentifier("Stacio.AI.header")
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.wantsLayer = true
        headerContainer.layer?.cornerRadius = 12
        headerContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            headerContainer,
            color: StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.76)
        )
        StacioDesignSystem.setLayerBorderColor(
            headerContainer,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.32)
        )
        headerContainer.layer?.borderWidth = 1
        headerIconView.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: L10n.AI.assistant)
        headerIconView.contentTintColor = StacioDesignSystem.theme.accentColor
        headerIconView.imageScaling = .scaleProportionallyDown
        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        headerTitleLabel.setAccessibilityIdentifier("Stacio.AI.header.title")
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerStatusDot.translatesAutoresizingMaskIntoConstraints = false
        headerStatusDot.wantsLayer = true
        headerStatusDot.layer?.cornerRadius = 4
        headerStatusDot.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(headerStatusDot, color: StacioDesignSystem.theme.successColor)
        headerStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        headerStatusLabel.lineBreakMode = .byTruncatingMiddle
        headerStatusLabel.setAccessibilityIdentifier("Stacio.AI.header.status")
        headerStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.font = .systemFont(ofSize: 11, weight: .medium)
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.preferredMaxLayoutWidth = Self.defaultMessagePreferredWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.cell?.wraps = true
        messageLabel.cell?.usesSingleLineMode = false
        messageLabel.lineBreakMode = .byCharWrapping
        surfaceModeSegmentedControl.target = self
        surfaceModeSegmentedControl.action = #selector(surfaceModeChanged(_:))
        surfaceModeSegmentedControl.segmentStyle = .rounded
        surfaceModeSegmentedControl.controlSize = .small
        surfaceModeSegmentedControl.selectedSegment = surfaceMode.rawValue
        surfaceModeSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        surfaceModeSegmentedControl.setAccessibilityIdentifier("Stacio.AI.surfaceMode")
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.hasHorizontalScroller = false
        transcriptScrollView.autohidesScrollers = true
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        transcriptScrollView.setAccessibilityIdentifier("Stacio.AI.transcriptScroll")
        transcriptDocumentView.translatesAutoresizingMaskIntoConstraints = false
        transcriptContentStack.orientation = .vertical
        transcriptContentStack.spacing = 8
        transcriptContentStack.alignment = .leading
        transcriptContentStack.distribution = .fill
        transcriptContentStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptBottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        transcriptBottomSpacer.setAccessibilityIdentifier("Stacio.AI.transcript.bottomSpacer")
        transcriptBottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        transcriptBottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        localAgentContainer.orientation = .vertical
        localAgentContainer.spacing = 8
        localAgentContainer.alignment = .leading
        localAgentContainer.distribution = .fill
        localAgentContainer.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        localAgentContainer.translatesAutoresizingMaskIntoConstraints = false
        localAgentContainer.setAccessibilityIdentifier("Stacio.AI.localAgent")
        localAgentHeaderStack.orientation = .horizontal
        localAgentHeaderStack.spacing = 8
        localAgentHeaderStack.alignment = .centerY
        localAgentHeaderStack.distribution = .fill
        localAgentHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        localAgentHeaderStack.setAccessibilityIdentifier("Stacio.AI.localAgent.header")
        localAgentTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        localAgentTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        localAgentTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        localAgentPopUpButton.target = self
        localAgentPopUpButton.action = #selector(localAgentSelectionChanged(_:))
        localAgentPopUpButton.controlSize = .small
        localAgentPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        localAgentPopUpButton.setAccessibilityIdentifier("Stacio.AI.localAgent.selector")
        localAgentPopUpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        localAgentPopUpButton.setContentHuggingPriority(.required, for: .horizontal)
        reloadLocalAgentSelector()
        localAgentStatusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        localAgentStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        localAgentStatusLabel.lineBreakMode = .byTruncatingMiddle
        localAgentStatusLabel.maximumNumberOfLines = 2
        localAgentStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        localAgentStatusLabel.setAccessibilityIdentifier("Stacio.AI.localAgent.status")
        localAgentTerminalHost.translatesAutoresizingMaskIntoConstraints = false
        localAgentTerminalHost.setAccessibilityIdentifier("Stacio.AI.localAgent.terminalHost")
        localAgentTerminalHost.wantsLayer = true
        localAgentTerminalHost.layer?.cornerRadius = 8
        localAgentTerminalHost.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(localAgentTerminalHost, color: .black)
        localAgentTerminalHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        localAgentTerminalHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        localAgentTerminalHost.isHidden = true
        transcriptStack.orientation = .vertical
        transcriptStack.spacing = 8
        transcriptStack.alignment = .leading
        transcriptStack.distribution = .fill
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.setAccessibilityIdentifier("Stacio.AI.transcript")
        planWorkspaceContainer.orientation = .vertical
        planWorkspaceContainer.spacing = 7
        planWorkspaceContainer.alignment = .leading
        planWorkspaceContainer.distribution = .fill
        planWorkspaceContainer.translatesAutoresizingMaskIntoConstraints = false
        planWorkspaceContainer.setAccessibilityIdentifier("Stacio.AI.planWorkspace")
        planWorkspaceContainer.isHidden = true
        planWorkspaceContainer.wantsLayer = true
        planWorkspaceContainer.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        planWorkspaceContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            planWorkspaceContainer,
            color: StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.86)
        )
        StacioDesignSystem.setLayerBorderColor(
            planWorkspaceContainer,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.34)
        )
        planWorkspaceContainer.layer?.borderWidth = 1
        configureTaskControlLabel(planWorkspaceHeaderLabel, weight: .semibold, color: StacioDesignSystem.theme.primaryTextColor)
        configureTaskControlLabel(planWorkspaceBodyLabel, weight: .regular, color: StacioDesignSystem.theme.secondaryTextColor)
        planWorkspaceControlsStack.orientation = .horizontal
        planWorkspaceControlsStack.spacing = 6
        planWorkspaceControlsStack.alignment = .centerY
        planWorkspaceControlsStack.distribution = .fill
        planWorkspaceControlsStack.translatesAutoresizingMaskIntoConstraints = false
        planWorkspaceControlsStack.setAccessibilityIdentifier("Stacio.AI.planWorkspace.controls")
        configureTaskControlButton(planWorkspaceConfirmButton, action: #selector(planConfirmPressed(_:)))
        configureTaskControlButton(planWorkspaceEditButton, action: #selector(planEditPressed(_:)))
        configureTaskControlButton(planWorkspaceCancelButton, action: #selector(planCancelPressed(_:)))
        taskControlContainer.orientation = .vertical
        taskControlContainer.spacing = 6
        taskControlContainer.alignment = .leading
        taskControlContainer.distribution = .fill
        taskControlContainer.translatesAutoresizingMaskIntoConstraints = false
        taskControlContainer.setAccessibilityIdentifier("Stacio.AI.taskControl")
        taskControlContainer.isHidden = true
        taskControlContainer.wantsLayer = true
        taskControlContainer.layer?.cornerRadius = 10
        taskControlContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            taskControlContainer,
            color: StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.86)
        )
        StacioDesignSystem.setLayerBorderColor(
            taskControlContainer,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.34)
        )
        taskControlContainer.layer?.borderWidth = 1
        configureTaskControlLabel(taskControlLabel, weight: .regular, color: StacioDesignSystem.theme.secondaryTextColor)
        taskControlButtonsStack.orientation = .horizontal
        taskControlButtonsStack.spacing = 6
        taskControlButtonsStack.alignment = .centerY
        taskControlButtonsStack.distribution = .fill
        taskControlButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        taskControlButtonsStack.setAccessibilityIdentifier("Stacio.AI.taskControl.controls")
        configureTaskControlButton(taskPauseButton, action: #selector(taskPausePressed(_:)))
        configureTaskControlButton(taskCancelButton, action: #selector(taskCancelPressed(_:)))
        configureTaskControlButton(taskTakeOverButton, action: #selector(taskTakeOverPressed(_:)))
        configureTaskControlButton(taskConfirmCompleteButton, action: #selector(taskConfirmCompletePressed(_:)))
        configureTaskControlButton(taskContinueButton, action: #selector(taskContinuePressed(_:)))
        taskContinueButton.setAccessibilityIdentifier("Stacio.AI.taskControl.continue")
        taskContinueButton.isHidden = true
        configureTaskControlButton(taskControlDismissButton, action: #selector(taskControlDismissPressed(_:)))
        taskHistoryContainer.orientation = .vertical
        taskHistoryContainer.spacing = 5
        taskHistoryContainer.alignment = .leading
        taskHistoryContainer.distribution = .fill
        taskHistoryContainer.translatesAutoresizingMaskIntoConstraints = false
        taskHistoryContainer.setAccessibilityIdentifier("Stacio.AI.taskHistory")
        taskHistoryContainer.isHidden = true
        taskHistoryContainer.wantsLayer = true
        taskHistoryContainer.layer?.cornerRadius = 8
        taskHistoryContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            taskHistoryContainer,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.44)
        )
        configureTaskControlLabel(taskHistoryHeaderLabel, weight: .semibold, color: .labelColor)
        configureTaskControlLabel(taskHistoryBodyLabel, weight: .regular, color: .secondaryLabelColor)
        taskHistoryButtonsStack.orientation = .vertical
        taskHistoryButtonsStack.spacing = 4
        taskHistoryButtonsStack.alignment = .leading
        taskHistoryButtonsStack.distribution = .fill
        taskHistoryButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        taskHistoryButtonsStack.setAccessibilityIdentifier("Stacio.AI.taskHistory.buttons")
        taskHistoryButtonsStack.isHidden = true
        commandCardsStack.orientation = .vertical
        commandCardsStack.spacing = 8
        commandCardsStack.alignment = .leading
        commandCardsStack.distribution = .fill
        commandCardsStack.translatesAutoresizingMaskIntoConstraints = false
        commandCardsStack.setAccessibilityIdentifier("Stacio.AI.commandCards")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byCharWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = Self.defaultMessagePreferredWidth
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.cell?.wraps = true
        statusLabel.cell?.usesSingleLineMode = false
        configureHorizontalContainment()
        updateQuestionControlState()
        setCommandProposals([])

        composer.onPasteAttachments = { [weak self] pasteboard in
            self?.addComposerAttachments(from: pasteboard) ?? false
        }
        composer.onDropAttachments = { [weak self] pasteboard in
            self?.addComposerAttachments(from: pasteboard) ?? false
        }
        composer.setAccessibilityIdentifier("Stacio.AI.composer")
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.setContentHuggingPriority(.required, for: .vertical)
        composer.setContentCompressionResistancePriority(.required, for: .vertical)
        composer.wantsLayer = true
        composer.layer?.cornerRadius = 20
        composer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            composer,
            color: NSColor.textBackgroundColor.withAlphaComponent(0.95)
        )
        composer.layer?.borderWidth = 1
        StacioDesignSystem.setLayerBorderColor(
            composer,
            color: NSColor.separatorColor.withAlphaComponent(0.35)
        )

        conversationContainer.addSubview(headerContainer)
        headerContainer.addSubview(headerIconView)
        headerContainer.addSubview(headerTitleLabel)
        headerContainer.addSubview(headerStatusDot)
        headerContainer.addSubview(headerStatusLabel)
        headerContainer.addSubview(targetButton)
        headerContainer.addSubview(collapseButton)
        conversationContainer.addSubview(surfaceModeSegmentedControl)
        conversationContainer.addSubview(conversationControlsStack)
        conversationContainer.addSubview(contextLabel)
        conversationContainer.addSubview(transcriptScrollView)
        conversationContainer.addSubview(localAgentContainer)
        transcriptDocumentView.addSubview(transcriptContentStack)
        transcriptScrollView.documentView = transcriptDocumentView
        [planWorkspaceHeaderLabel, planWorkspaceBodyLabel].forEach { view in
            planWorkspaceContainer.addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: planWorkspaceContainer.leadingAnchor, constant: 12).isActive = true
            view.trailingAnchor.constraint(equalTo: planWorkspaceContainer.trailingAnchor, constant: -12).isActive = true
        }
        [
            planWorkspaceConfirmButton,
            planWorkspaceEditButton,
            planWorkspaceCancelButton
        ].forEach(planWorkspaceControlsStack.addArrangedSubview)
        planWorkspaceContainer.addArrangedSubview(planWorkspaceControlsStack)
        planWorkspaceControlsStack.leadingAnchor.constraint(equalTo: planWorkspaceContainer.leadingAnchor, constant: 12).isActive = true
        planWorkspaceControlsStack.trailingAnchor.constraint(equalTo: planWorkspaceContainer.trailingAnchor, constant: -12).isActive = true
        taskControlContainer.addArrangedSubview(taskControlLabel)
        taskControlLabel.leadingAnchor.constraint(equalTo: taskControlContainer.leadingAnchor, constant: 12).isActive = true
        taskControlLabel.trailingAnchor.constraint(equalTo: taskControlContainer.trailingAnchor, constant: -12).isActive = true
        [
            taskPauseButton,
            taskCancelButton,
            taskTakeOverButton,
            taskConfirmCompleteButton,
            taskContinueButton,
            taskControlDismissButton
        ].forEach(taskControlButtonsStack.addArrangedSubview)
        taskControlContainer.addArrangedSubview(taskControlButtonsStack)
        taskControlButtonsStack.leadingAnchor.constraint(equalTo: taskControlContainer.leadingAnchor, constant: 12).isActive = true
        taskControlButtonsStack.trailingAnchor.constraint(equalTo: taskControlContainer.trailingAnchor, constant: -12).isActive = true
        [taskHistoryHeaderLabel, taskHistoryBodyLabel, taskHistoryButtonsStack].forEach { view in
            taskHistoryContainer.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: taskHistoryContainer.widthAnchor).isActive = true
        }
        let localAgentHeaderSpacer = NSView()
        localAgentHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        localAgentHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        localAgentHeaderSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [
            localAgentTitleLabel,
            localAgentHeaderSpacer,
            localAgentPopUpButton
        ].forEach(localAgentHeaderStack.addArrangedSubview)
        localAgentContainer.addArrangedSubview(localAgentHeaderStack)
        localAgentContainer.addArrangedSubview(localAgentStatusLabel)
        localAgentContainer.addArrangedSubview(localAgentTerminalHost)
        [
            localAgentHeaderStack,
            localAgentStatusLabel,
            localAgentTerminalHost
        ].forEach { view in
            view.widthAnchor.constraint(equalTo: localAgentContainer.widthAnchor).isActive = true
        }
        [
            messageLabel,
            planWorkspaceContainer,
            taskControlContainer,
            taskHistoryContainer,
            transcriptStack,
            statusLabel
        ].forEach { view in
            transcriptContentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: transcriptContentStack.widthAnchor).isActive = true
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        transcriptContentStack.addArrangedSubview(transcriptBottomSpacer)
        transcriptBottomSpacer.widthAnchor.constraint(equalTo: transcriptContentStack.widthAnchor).isActive = true

        let composerSpacer = NSView()
        composerSpacer.translatesAutoresizingMaskIntoConstraints = false
        composerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [
            composerAddButton,
            composerPermissionButton,
            composerSpacer,
            composerModelButton,
            contextUsageRing,
            askButton
        ].forEach(composerToolbar.addArrangedSubview)

        composer.addSubview(questionField)
        composer.addSubview(composerAttachmentStack)
        composer.addSubview(composerContextLabel)
        composer.addSubview(composerToolbar)

        container.addSubview(conversationContainer)
        container.addSubview(commandCardsStack)
        container.addSubview(composer)

        let questionMinimumWidth = questionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        questionMinimumWidth.priority = .defaultLow
        let transcriptMinimumHeight = transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 132)
        transcriptMinimumHeight.priority = .defaultHigh
        questionTopWithoutAttachmentsConstraint = questionField.topAnchor.constraint(
            equalTo: composer.topAnchor,
            constant: 12
        )
        questionTopWithAttachmentsConstraint = questionField.topAnchor.constraint(
            equalTo: composerAttachmentStack.bottomAnchor,
            constant: 10
        )
        questionTopWithoutAttachmentsConstraint?.isActive = true
        conversationBottomToCommandCardsConstraint = conversationContainer.bottomAnchor.constraint(
            equalTo: commandCardsStack.topAnchor,
            constant: -12
        )
        conversationBottomToComposerConstraint = conversationContainer.bottomAnchor.constraint(
            equalTo: composer.topAnchor,
            constant: -12
        )
        conversationBottomToContainerConstraint = conversationContainer.bottomAnchor.constraint(
            equalTo: container.bottomAnchor,
            constant: -14
        )
        composerHeightConstraint = composer.heightAnchor.constraint(equalToConstant: Self.compactComposerHeight)
        commandCardsCollapsedHeightConstraint = commandCardsStack.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            composer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            composer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            composerHeightConstraint!,

            composerAddButton.widthAnchor.constraint(equalToConstant: 32),
            composerAddButton.heightAnchor.constraint(equalToConstant: 32),
            contextUsageRing.widthAnchor.constraint(equalToConstant: 16),
            contextUsageRing.heightAnchor.constraint(equalToConstant: 16),
            composerPermissionButton.heightAnchor.constraint(equalToConstant: 28),
            composerModelButton.heightAnchor.constraint(equalToConstant: 28),
            composerModelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            askButton.widthAnchor.constraint(equalToConstant: 32),
            askButton.heightAnchor.constraint(equalToConstant: 32),
            localAgentPopUpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            localAgentPopUpButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            localAgentTerminalHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),

            composerAttachmentStack.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 16),
            composerAttachmentStack.trailingAnchor.constraint(lessThanOrEqualTo: composer.trailingAnchor, constant: -16),
            composerAttachmentStack.topAnchor.constraint(equalTo: composer.topAnchor, constant: 12),
            composerAttachmentStack.heightAnchor.constraint(equalToConstant: 54),

            questionField.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 16),
            questionField.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -16),
            questionField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            questionMinimumWidth,

            composerContextLabel.leadingAnchor.constraint(equalTo: questionField.leadingAnchor),
            composerContextLabel.trailingAnchor.constraint(equalTo: questionField.trailingAnchor),
            composerContextLabel.topAnchor.constraint(equalTo: questionField.bottomAnchor, constant: 2),

            composerToolbar.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            composerToolbar.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            composerToolbar.topAnchor.constraint(greaterThanOrEqualTo: composerContextLabel.bottomAnchor, constant: 6),
            composerToolbar.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -12),
            composerToolbar.heightAnchor.constraint(equalToConstant: 32),

            commandCardsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            commandCardsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            commandCardsStack.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
            commandCardsCollapsedHeightConstraint!,

            conversationContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            conversationContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            conversationContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),

            headerContainer.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: conversationContainer.topAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 66),

            headerIconView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            headerIconView.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 10),
            headerIconView.widthAnchor.constraint(equalToConstant: 18),
            headerIconView.heightAnchor.constraint(equalToConstant: 18),

            headerTitleLabel.leadingAnchor.constraint(equalTo: headerIconView.trailingAnchor, constant: 8),
            headerTitleLabel.centerYAnchor.constraint(equalTo: headerIconView.centerYAnchor),
            headerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: targetButton.leadingAnchor, constant: -10),

            headerStatusDot.leadingAnchor.constraint(equalTo: headerTitleLabel.leadingAnchor),
            headerStatusDot.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 9),
            headerStatusDot.widthAnchor.constraint(equalToConstant: 8),
            headerStatusDot.heightAnchor.constraint(equalToConstant: 8),

            headerStatusLabel.leadingAnchor.constraint(equalTo: headerStatusDot.trailingAnchor, constant: 6),
            headerStatusLabel.centerYAnchor.constraint(equalTo: headerStatusDot.centerYAnchor),
            headerStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerContainer.trailingAnchor, constant: -12),

            targetButton.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -6),
            targetButton.centerYAnchor.constraint(equalTo: headerTitleLabel.centerYAnchor),
            targetButton.heightAnchor.constraint(equalToConstant: 28),
            targetButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            targetButton.widthAnchor.constraint(lessThanOrEqualToConstant: 148),

            conversationPopUpButton.widthAnchor.constraint(equalToConstant: 108),
            conversationPopUpButton.heightAnchor.constraint(equalToConstant: 24),

            newConversationButton.widthAnchor.constraint(equalToConstant: 24),
            newConversationButton.heightAnchor.constraint(equalToConstant: 24),

            collapseButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -10),
            collapseButton.centerYAnchor.constraint(equalTo: headerTitleLabel.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 28),
            collapseButton.heightAnchor.constraint(equalToConstant: 28),

            contextLabel.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor, constant: 4),
            contextLabel.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor, constant: -4),
            conversationControlsStack.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            conversationControlsStack.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            conversationControlsStack.topAnchor.constraint(equalTo: surfaceModeSegmentedControl.bottomAnchor, constant: 8),
            conversationControlsStack.heightAnchor.constraint(equalToConstant: 26),

            contextLabel.topAnchor.constraint(equalTo: conversationControlsStack.bottomAnchor, constant: 8),

            surfaceModeSegmentedControl.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            surfaceModeSegmentedControl.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            surfaceModeSegmentedControl.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 8),
            surfaceModeSegmentedControl.heightAnchor.constraint(equalToConstant: 26),

            transcriptScrollView.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            transcriptScrollView.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            transcriptScrollView.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 8),
            transcriptScrollView.bottomAnchor.constraint(equalTo: conversationContainer.bottomAnchor),
            transcriptMinimumHeight,

            localAgentContainer.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            localAgentContainer.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            localAgentContainer.topAnchor.constraint(equalTo: surfaceModeSegmentedControl.bottomAnchor, constant: 8),
            localAgentContainer.bottomAnchor.constraint(equalTo: conversationContainer.bottomAnchor),

            transcriptDocumentView.leadingAnchor.constraint(equalTo: transcriptScrollView.contentView.leadingAnchor),
            transcriptDocumentView.trailingAnchor.constraint(equalTo: transcriptScrollView.contentView.trailingAnchor),
            transcriptDocumentView.topAnchor.constraint(equalTo: transcriptScrollView.contentView.topAnchor),
            transcriptDocumentView.widthAnchor.constraint(equalTo: transcriptScrollView.contentView.widthAnchor),
            transcriptDocumentView.heightAnchor.constraint(greaterThanOrEqualTo: transcriptScrollView.contentView.heightAnchor),

            transcriptContentStack.leadingAnchor.constraint(equalTo: transcriptDocumentView.leadingAnchor),
            transcriptContentStack.trailingAnchor.constraint(equalTo: transcriptDocumentView.trailingAnchor),
            transcriptContentStack.topAnchor.constraint(equalTo: transcriptDocumentView.topAnchor),
            transcriptContentStack.bottomAnchor.constraint(equalTo: transcriptDocumentView.bottomAnchor)
        ])

        view = container
        observeTerminalTraceNotifications()
        observeSettingsChanges()
        reconcileTemporaryModelSelection()
        refreshForCurrentContext()
        refreshComposerControls()
        updateSurfaceMode()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateSurfaceModeSegmentWidths()
        let textWidth = max(80, transcriptContentStack.bounds.width)
        guard lastAppliedTranscriptTextWidth.map({ abs($0 - textWidth) > 0.5 }) ?? true else {
            return
        }
        lastAppliedTranscriptTextWidth = textWidth
        messageLabel.preferredMaxLayoutWidth = textWidth
        statusLabel.preferredMaxLayoutWidth = textWidth
        taskControlLabel.preferredMaxLayoutWidth = textWidth
        planWorkspaceHeaderLabel.preferredMaxLayoutWidth = textWidth
        planWorkspaceBodyLabel.preferredMaxLayoutWidth = textWidth
        taskHistoryHeaderLabel.preferredMaxLayoutWidth = textWidth
        taskHistoryBodyLabel.preferredMaxLayoutWidth = textWidth
        for case let bubble as AITranscriptBubbleView in transcriptStack.arrangedSubviews {
            bubble.preferredTextWidth = textWidth
        }
    }

    private func updateSurfaceModeSegmentWidths() {
        let segmentCount = surfaceModeSegmentedControl.segmentCount
        let controlWidth = surfaceModeSegmentedControl.bounds.width
        guard segmentCount > 0, controlWidth > 0 else {
            return
        }

        let segmentWidth = controlWidth / CGFloat(segmentCount)
        var changed = false
        for index in 0..<segmentCount
        where abs(surfaceModeSegmentedControl.width(forSegment: index) - segmentWidth) > 0.5 {
            surfaceModeSegmentedControl.setWidth(segmentWidth, forSegment: index)
            changed = true
        }
        if changed {
            surfaceModeSegmentedControl.needsDisplay = true
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        updateQuestionControlState()
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            collapseButtonPressed(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            askButtonPressed(nil)
            return true
        }
        return false
    }

    public func refreshForCurrentContext() {
        let context = refreshContextSummary()
        loadConversationHistory(for: context)
        if context != nil, messageLabel.stringValue == L10n.AI.noTerminal {
            messageLabel.stringValue = L10n.AI.ready
        }
        loadRecentTaskHistory(for: context)
        refreshLocalAgentBridgeTargets()
    }

    public func followCurrentTerminalContext() {
        selectedRuntimeID = nil
        selectedRuntimeIDs = []
        refreshForCurrentContext()
    }

    public func focusQuestionField() {
        view.window?.makeFirstResponder(questionField)
    }

    public func prefillQuestion(_ text: String) {
        questionField.stringValue = text
        updateQuestionControlState()
    }

    @objc
    private func surfaceModeChanged(_ sender: NSSegmentedControl) {
        guard let nextMode = AIAssistantSurfaceMode(rawValue: sender.selectedSegment) else {
            sender.selectedSegment = surfaceMode.rawValue
            return
        }
        surfaceMode = nextMode
        updateSurfaceMode()
        if nextMode == .localAgent, activeLocalAgentTool == nil {
            startLocalAgentSession(defaultLocalAgentTool())
        }
    }

    private func updateSurfaceMode() {
        surfaceModeSegmentedControl.selectedSegment = surfaceMode.rawValue
        let showsLocalAgent = surfaceMode == .localAgent
        conversationControlsStack.isHidden = showsLocalAgent
        contextLabel.isHidden = showsLocalAgent
        transcriptScrollView.isHidden = showsLocalAgent
        localAgentContainer.isHidden = showsLocalAgent == false
        composer.isHidden = showsLocalAgent
        contextUsageRing.isHidden = showsLocalAgent
        updateConversationBottomLayout()
        updateQuestionControlState()
        if showsLocalAgent {
            focusActiveLocalAgentTerminal()
        }
    }

    private func updateConversationBottomLayout() {
        let showsLocalAgent = surfaceMode == .localAgent
        let showsCommandCards = showsLocalAgent == false && commandCards.isEmpty == false
        commandCardsStack.isHidden = showsCommandCards == false
        commandCardsCollapsedHeightConstraint?.isActive = showsCommandCards == false
        conversationBottomToCommandCardsConstraint?.isActive = showsCommandCards
        conversationBottomToComposerConstraint?.isActive = showsLocalAgent == false && showsCommandCards == false
        conversationBottomToContainerConstraint?.isActive = showsLocalAgent
        if isViewLoaded {
            view.needsLayout = true
        }
    }

    private func startLocalAgentSession(_ tool: LocalAgentTool) {
        surfaceMode = .localAgent
        updateSurfaceMode()
        activeLocalAgentTool = tool
        selectLocalAgentToolInMenu(tool)
        let session = localAgentSessionsByTool[tool] ?? makeLocalAgentSession(for: tool)
        if localAgentSessionsByTool[tool] == nil {
            localAgentSessionsByTool[tool] = session
            addChild(session)
            localAgentTerminalHost.addSubview(session.view)
            session.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                session.view.leadingAnchor.constraint(equalTo: localAgentTerminalHost.leadingAnchor),
                session.view.trailingAnchor.constraint(equalTo: localAgentTerminalHost.trailingAnchor),
                session.view.topAnchor.constraint(equalTo: localAgentTerminalHost.topAnchor),
                session.view.bottomAnchor.constraint(equalTo: localAgentTerminalHost.bottomAnchor)
            ])
        }
        localAgentSessionsByTool.values.forEach { child in
            child.view.isHidden = child.tool != tool
        }
        localAgentTerminalHost.isHidden = false
        updateLocalAgentStatus(session.launchState, tool: tool)
        session.startIfNeeded()
        focusActiveLocalAgentTerminal()
    }

    private func focusActiveLocalAgentTerminal() {
        guard surfaceMode == .localAgent,
              let terminalView = activeLocalAgentSession?.terminalView
        else {
            return
        }

        focusLocalAgentTerminal(terminalView)
        DispatchQueue.main.async { [weak self, weak terminalView] in
            guard let self,
                  let terminalView,
                  self.surfaceMode == .localAgent,
                  self.activeLocalAgentSession?.terminalView === terminalView
            else {
                return
            }
            self.focusLocalAgentTerminal(terminalView)
        }
    }

    private func focusLocalAgentTerminal(_ terminalView: StacioLocalAgentTerminalView) {
        guard let window = terminalView.window,
              window.firstResponder !== terminalView
        else {
            return
        }
        window.makeFirstResponder(terminalView)
    }

    @objc
    private func localAgentSelectionChanged(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem,
              selectedItem.isEnabled,
              let rawValue = selectedItem.representedObject as? String,
              let tool = LocalAgentTool(rawValue: rawValue)
        else {
            selectLocalAgentToolInMenu(activeLocalAgentTool ?? defaultLocalAgentTool())
            return
        }
        startLocalAgentSession(tool)
    }

    private func reloadLocalAgentSelector() {
        localAgentPopUpButton.removeAllItems()
        for tool in LocalAgentTool.allCases {
            let isInstalled = localAgentToolResolver.executablePath(for: tool) != nil
            let title = isInstalled ? tool.displayName : "\(tool.displayName)（未检测到）"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = tool.rawValue
            item.isEnabled = isInstalled
            localAgentPopUpButton.menu?.addItem(item)
        }
        selectLocalAgentToolInMenu(activeLocalAgentTool ?? defaultLocalAgentTool())
    }

    private func defaultLocalAgentTool() -> LocalAgentTool {
        LocalAgentTool.allCases.first { localAgentToolResolver.executablePath(for: $0) != nil } ?? .codex
    }

    private func selectLocalAgentToolInMenu(_ tool: LocalAgentTool) {
        guard let index = localAgentPopUpButton.itemArray.firstIndex(where: { item in
            (item.representedObject as? String) == tool.rawValue
        }) else {
            return
        }
        localAgentPopUpButton.selectItem(at: index)
    }

    private var activeLocalAgentSession: LocalAgentSessionViewController? {
        guard let activeLocalAgentTool else {
            return nil
        }
        return localAgentSessionsByTool[activeLocalAgentTool]
    }

    private func makeLocalAgentSession(for tool: LocalAgentTool) -> LocalAgentSessionViewController {
        let session = LocalAgentSessionViewController(
            tool: tool,
            resolver: localAgentToolResolver,
            processLauncher: localAgentProcessLauncherFactory(),
            settingsStore: settingsStore,
            currentDirectoryProvider: { [weak self] in
                self?.resolvedTargetContext()?.currentDirectory
            },
            bridgeContextProvider: { [weak self] in
                self?.makeLocalAgentBridgeContext()
            }
        )
        session.onStatusChange = { [weak self, weak session] state in
            guard let self,
                  session?.tool == self.activeLocalAgentTool
            else {
                return
            }
            self.updateLocalAgentStatus(state, tool: tool)
        }
        return session
    }

    private func updateLocalAgentStatus(_ state: LocalAgentSessionLaunchState, tool: LocalAgentTool) {
        switch state {
        case .idle:
            localAgentStatusLabel.stringValue = "准备启动 \(tool.displayName) 原生会话。"
        case .missingExecutable:
            localAgentStatusLabel.stringValue = "未找到 \(tool.displayName) 本地命令；请安装后重试。"
        case .running(let executable):
            localAgentStatusLabel.stringValue = localAgentRunningStatus(
                tool: tool,
                executable: executable
            )
        case .terminated(let exitCode):
            if let exitCode {
                localAgentStatusLabel.stringValue = "\(tool.displayName) 会话已退出 · code \(exitCode)"
            } else {
                localAgentStatusLabel.stringValue = "\(tool.displayName) 会话已退出。"
            }
        }
    }

    private func makeLocalAgentBridgeContext() -> LocalAgentBridgeContext? {
        guard let cliPath = LocalAgentBridgeToolInstaller.defaultCLIExecutablePath(),
              let socketPath = try? StacioPaths.agentBridgeSocketPath().path
        else {
            return nil
        }
        let contexts = resolvedTargetContexts()
        let context = contexts.first
        return LocalAgentBridgeContext(
            socketPath: socketPath,
            targetRuntimeID: context?.runtimeID,
            targetRuntimeIDs: contexts.map(\.runtimeID),
            targetTitle: contexts.map(\.title).joined(separator: "、"),
            remoteCurrentDirectory: context?.currentDirectory,
            cliExecutablePath: cliPath,
            toolsDirectory: LocalAgentBridgeToolInstaller.defaultToolsDirectory()
        )
    }

    private func refreshLocalAgentBridgeTargets() {
        localAgentSessionsByTool.values.forEach { $0.refreshBridgeContext() }
        guard let activeLocalAgentTool,
              let session = localAgentSessionsByTool[activeLocalAgentTool]
        else {
            return
        }
        updateLocalAgentStatus(session.launchState, tool: activeLocalAgentTool)
    }

    private func localAgentRunningStatus(tool: LocalAgentTool, executable: String) -> String {
        guard let session = activeLocalAgentSession else {
            return "\(tool.displayName) 原生会话已启动 · \(executable)"
        }
        if let error = session.bridgeInstallError {
            return "\(tool.displayName) 原生会话已启动 · \(executable)\n远程桥未连接：\(error)"
        }
        guard let bridge = session.activeBridgeContext else {
            return "\(tool.displayName) 原生会话已启动 · \(executable)\n远程桥未连接：未找到 Stacio CLI helper。"
        }
        let target = bridge.targetTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetText = target?.isEmpty == false ? target! : "当前 Stacio 终端"
        return "\(tool.displayName) 原生会话已启动 · \(executable)\n远程桥：\(targetText) · stacio-remote \"命令\""
    }

    @objc
    private func askButtonPressed(_ sender: Any?) {
        if hasActiveAIActivity {
            stopCurrentAIRequest()
            return
        }
        let question = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.isEmpty == false else {
            messageLabel.stringValue = L10n.AI.emptyQuestion
            statusLabel.stringValue = ""
            setCommandProposals([])
            updateQuestionControlState()
            return
        }
        guard surfaceMode != .assistant || hasConfiguredAssistantModel else {
            messageLabel.stringValue = Self.unconfiguredProviderMessage
            statusLabel.stringValue = ""
            setCommandProposals([])
            updateQuestionControlState()
            return
        }
        guard let context = refreshContextSummary() else {
            messageLabel.stringValue = L10n.AI.noTerminal
            statusLabel.stringValue = ""
            setCommandProposals([])
            return
        }
        finishActiveProcessGroup(collapse: true)
        let isReplacingPendingTaskContinuation = pendingTaskContinuation != nil
        clearPendingTaskContinuation()
        if isReplacingPendingTaskContinuation {
            endTaskModelSelectionCapture()
        }
        let requestConversationHistory = assistantConversationContext()
        questionField.stringValue = ""
        questionField.currentEditor()?.string = ""
        isAsking = true
        refreshHeaderStatus(context: context)
        statusLabel.stringValue = L10n.AI.thinking
        appendTranscript(.user, question)
        messageLabel.stringValue = ""
        setCommandProposals([])
        updateQuestionControlState()

        let requestQuestion = composerAugmentedQuestion(for: question)
        let requestAttachments = composerAttachments
        activeStreamingAssistantIndex = nil
        if planModeEnabled {
            startPlanMode(
                question: question,
                requestQuestion: requestQuestion,
                context: context,
                conversationHistory: requestConversationHistory,
                attachments: requestAttachments
            )
            return
        }
        if goalModeEnabled {
            startAutonomousGoal(
                question: question,
                requestQuestion: requestQuestion,
                context: context,
                conversationHistory: requestConversationHistory,
                attachments: requestAttachments
            )
            return
        }
        let askID = UUID()
        activeAskID = askID
        activeAskCancellation = coordinator.askInBackground(
            question: requestQuestion,
            context: context,
            conversationHistory: requestConversationHistory,
            attachments: requestAttachments,
            progress: { [weak self] message in
                self?.appendAssistantProgress(message)
            },
            stream: { [weak self] delta in
                self?.appendAssistantStreamingDelta(delta)
            }
        ) { [weak self] result in
            guard let self else { return }
            guard self.activeAskID == askID else { return }
            self.isAsking = false
            self.activeAskID = nil
            self.activeAskCancellation = nil
            self.refreshHeaderStatus(context: context)
            self.updateQuestionControlState()
            switch result {
                case .success(let response):
                self.clearComposerSendOptions()
                if self.settingsStore.snapshot().aiAutoRunProposedCommands,
                   response.commandProposals.isEmpty == false {
                    self.messageLabel.stringValue = ""
                    self.startStepwiseAutoRun(
                        question: question,
                        goal: requestQuestion,
                        context: context,
                        attachments: requestAttachments,
                        initialResponse: response,
                        introduction: "我会先执行第一步，拿到真实输出后再决定下一步。"
                    )
                } else {
                    self.recordTaskHistory(
                        question: question,
                        context: context,
                        response: response
                    )
                    self.messageLabel.stringValue = ""
                    self.finalizeAssistantStreamingText(response.message, persistHistory: true)
                    self.setCommandProposals(response.commandProposals)
                    self.statusLabel.stringValue = ""
                }
            case .failure(let error):
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                self.messageLabel.stringValue = message
                if (error as? AIAssistantProviderError) == .cancelled {
                    self.appendSystemTranscript("已停止，上一条 AI 回复可能是不完整的部分内容。")
                } else {
                    self.appendSystemTranscript("请求失败：\(message)")
                }
                self.setCommandProposals([])
                self.statusLabel.stringValue = ""
                self.activeStreamingAssistantIndex = nil
            }
            self.updateQuestionControlState()
        }
        updateQuestionControlState()
    }

    private func assistantConversationContext() -> [AIAssistantConversationMessage] {
        transcriptEntries.compactMap { entry in
            switch entry.role {
            case .user:
                return AIAssistantConversationMessage(role: .user, content: entry.text)
            case .assistant:
                return AIAssistantConversationMessage(role: .assistant, content: entry.text)
            case .system, .command, .terminal, .plan, .step:
                return nil
            }
        }
    }

    @objc
    private func stopButtonPressed(_ sender: Any?) {
        stopCurrentAIRequest()
    }

    private func stopCurrentAIRequest() {
        activeAskCancellation?.cancel()
        activeAskCancellation = nil
        activeAskID = nil
        activeOrchestrator?.cancel()
        activeOrchestrator = nil
        if let activeTaskRequestID,
           let event = performTaskControl(for: activeTaskRequestID, action: coordinator.cancelTask).first {
            taskControlStatusesByRequestID[activeTaskRequestID] = controlStatusText(forCancelEvent: event)
            renderTaskControls(for: activeTaskRequestID)
        }
        activeAutonomousTask?.cancel()
        activeAutonomousTask = nil
        invalidateActiveAutonomousRun()
        isAsking = false
        isExecuting = false
        activeStreamingAssistantIndex = nil
        endTaskModelSelectionCapture()
        statusLabel.stringValue = "已停止。"
        appendSystemTranscript("已停止，上一条 AI 回复可能是不完整的部分内容。")
        refreshHeaderStatusForCurrentContext()
        updateQuestionControlState()
    }

    private func startPlanMode(
        question: String,
        requestQuestion: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment]
    ) {
        beginTaskModelSelectionCapture()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: agentTaskLoopLimits,
            targetContextsProvider: { [weak self] in self?.resolvedTargetContexts() ?? [] }
        )
        activeOrchestrator = orchestrator
        activeAutonomousTask?.cancel()
        let runID = beginAutonomousRun()
        activeAutonomousTask = Task { [weak self, orchestrator, runID] in
            do {
                let plan = try await orchestrator.makePlan(
                    goal: requestQuestion,
                    context: context,
                    conversationHistory: conversationHistory,
                    attachments: attachments
                )
                guard Task.isCancelled == false else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.isAsking = false
                self.activeOrchestrator = nil
                self.activeAutonomousTask = nil
                self.currentAgentPlan = plan
                self.renderPlanWorkspace(plan)
                self.appendTranscript(.plan, planTranscriptText(for: plan))
                self.messageLabel.stringValue = ""
                self.statusLabel.stringValue = "计划已生成，等待确认执行。"
                self.refreshHeaderStatus(context: context)
                self.updateQuestionControlState()
                self.recordTaskHistory(
                    question: question,
                    context: context,
                    response: AIAssistantResponse(
                        message: plan.summary,
                        commandProposals: plan.steps.map {
                            AgentCommandProposal(command: $0.command, explanation: $0.intent, risk: $0.risk)
                        }
                    )
                )
            } catch {
                guard Task.isCancelled == false, !(error is CancellationError) else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.isAsking = false
                self.activeOrchestrator = nil
                self.activeAutonomousTask = nil
                self.endTaskModelSelectionCapture()
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                self.messageLabel.stringValue = message
                self.appendSystemTranscript("计划生成失败：\(message)")
                self.statusLabel.stringValue = ""
                self.refreshHeaderStatus(context: context)
                self.updateQuestionControlState()
                self.invalidateActiveAutonomousRun()
            }
        }
    }

    private func startAutonomousGoal(
        question: String,
        requestQuestion: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment]
    ) {
        beginTaskModelSelectionCapture()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: agentTaskLoopLimits,
            targetContextsProvider: { [weak self] in self?.resolvedTargetContexts() ?? [] }
        )
        activeOrchestrator = orchestrator
        activeAutonomousTask?.cancel()
        let runID = beginAutonomousRun()
        isAsking = false
        isExecuting = true
        refreshHeaderStatus(context: context)
        appendSystemTranscript("我开始自主推进这个目标。", isProcessEntry: true)
        activeAutonomousTask = Task { [weak self, orchestrator, runID] in
            do {
                let result = try await orchestrator.run(
                    goal: requestQuestion,
                    context: context,
                    contextProvider: { [weak self] in
                        self?.contextProvider(context.runtimeID) ?? context
                    },
                    conversationHistory: conversationHistory,
                    attachments: attachments,
                    onUpdate: { [weak self] update in
                        guard let self, self.isActiveAutonomousRun(runID) else { return }
                        self.handleAgentTaskUpdate(update, runtimeTitle: context.title)
                    }
                )
                guard Task.isCancelled == false else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.finishAgentTaskRun(
                    result,
                    question: question,
                    goal: requestQuestion,
                    context: context,
                    attachments: attachments
                )
            } catch {
                guard Task.isCancelled == false, !(error is CancellationError) else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.isExecuting = false
                self.activeAutonomousTask = nil
                self.clearPendingTaskContinuation()
                self.endTaskModelSelectionCapture()
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                self.messageLabel.stringValue = message
                self.appendSystemTranscript("自主执行失败：\(message)")
                self.statusLabel.stringValue = ""
                self.refreshHeaderStatus(context: context)
                self.updateQuestionControlState()
                self.invalidateActiveAutonomousRun()
            }
        }
    }

    private func startStepwiseAutoRun(
        question: String,
        goal: String,
        context: AITerminalContext,
        attachments: [AIAssistantAttachment],
        initialResponse: AIAssistantResponse,
        introduction: String
    ) {
        beginTaskModelSelectionCapture()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: agentTaskLoopLimits,
            targetContextsProvider: { [weak self] in self?.resolvedTargetContexts() ?? [] }
        )
        activeOrchestrator = orchestrator
        activeAutonomousTask?.cancel()
        let runID = beginAutonomousRun()
        isAsking = false
        isExecuting = true
        setCommandProposals([])
        statusLabel.stringValue = "AI 正在分步执行。"
        refreshHeaderStatus(context: context)
        updateQuestionControlState()
        appendSystemTranscript(introduction, isProcessEntry: true)
        activeAutonomousTask = Task { [weak self, orchestrator, runID] in
            do {
                let result = try await orchestrator.run(
                    goal: goal,
                    context: context,
                    contextProvider: { [weak self] in
                        self?.contextProvider(context.runtimeID) ?? context
                    },
                    attachments: attachments,
                    initialResponse: initialResponse,
                    onUpdate: { [weak self] update in
                        guard let self, self.isActiveAutonomousRun(runID) else { return }
                        self.handleAgentTaskUpdate(update, runtimeTitle: context.title)
                    }
                )
                guard Task.isCancelled == false else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.finishAgentTaskRun(
                    result,
                    question: question,
                    goal: goal,
                    context: context,
                    attachments: attachments
                )
            } catch {
                guard Task.isCancelled == false, !(error is CancellationError) else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.isExecuting = false
                self.activeOrchestrator = nil
                self.activeAutonomousTask = nil
                self.clearPendingTaskContinuation()
                self.endTaskModelSelectionCapture()
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                self.messageLabel.stringValue = message
                self.appendSystemTranscript("自动分步执行失败：\(message)")
                self.statusLabel.stringValue = ""
                self.refreshHeaderStatus(context: context)
                self.updateQuestionControlState()
                self.invalidateActiveAutonomousRun()
            }
        }
    }

    private func finishAgentTaskRun(
        _ result: AgentTaskRunResult,
        question: String,
        goal: String,
        context: AITerminalContext,
        attachments: [AIAssistantAttachment]
    ) {
        activeAutonomousTask = nil
        isExecuting = result.state == .running
        refreshHeaderStatus(context: context)
        updateQuestionControlState()
        recordTaskHistory(
            question: question,
            context: context,
            response: AIAssistantResponse(message: result.summary, commandProposals: []),
            stateOverride: taskSessionState(for: result.state)
        )
        if result.stopReason == .stepLimitReached {
            isExecuting = false
            activeOrchestrator = nil
            guard let capturedTaskModelSelection else {
                clearPendingTaskContinuation()
                messageLabel.stringValue = Self.unconfiguredProviderMessage
                appendSystemTranscript(Self.unconfiguredProviderMessage)
                refreshHeaderStatus(context: context)
                updateQuestionControlState()
                return
            }
            pendingTaskContinuation = PendingAgentTaskContinuation(
                question: question,
                goal: goal,
                context: context,
                attachments: attachments,
                completedSteps: result.steps,
                modelSelection: capturedTaskModelSelection
            )
            renderStepLimitContinuation(summary: result.summary)
            refreshHeaderStatus(context: context)
            updateQuestionControlState()
            return
        }
        clearPendingTaskContinuation()
        if result.state != .running {
            activeOrchestrator = nil
            activeAutonomousRunID = nil
            clearComposerSendOptions()
            endTaskModelSelectionCapture()
            finishActiveProcessGroup(collapse: true)
        }
        appendAgentTaskFinalTranscript(result)
    }

    private func appendAgentTaskFinalTranscript(_ result: AgentTaskRunResult) {
        let text = agentTaskFinalTranscriptText(for: result)
        switch result.state {
        case .completed:
            appendTranscript(.assistant, text)
        case .paused, .cancelled, .takenOver, .failed:
            appendSystemTranscript(text)
        case .idle, .planning, .awaitingUser:
            if result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                appendSystemTranscript(text)
            }
        case .running:
            break
        }
    }

    private func agentTaskFinalTranscriptText(for result: AgentTaskRunResult) -> String {
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.state == .failed,
           let failedStep = result.steps.last(where: { $0.state == .failed }) {
            let detail = oneLineAgentObservation(failedStep.observation)
            if detail.isEmpty == false {
                return "执行失败：\(detail)"
            }
        }
        return summary.isEmpty ? fallbackAgentTaskFinalText(for: result.state) : summary
    }

    private func oneLineAgentObservation(_ observation: String) -> String {
        let collapsed = observation
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
        guard collapsed.isEmpty == false else { return "" }
        if collapsed.count > 220 {
            let end = collapsed.index(collapsed.startIndex, offsetBy: 220)
            return "\(collapsed[..<end])..."
        }
        return collapsed
    }

    private func fallbackAgentTaskFinalText(for state: AgentTaskRunState) -> String {
        switch state {
        case .completed:
            return "任务已完成。"
        case .paused:
            return "任务已暂停。"
        case .cancelled:
            return "任务已取消。"
        case .takenOver:
            return "任务已切换为人工接管。"
        case .failed:
            return "任务执行失败。"
        case .idle, .planning, .awaitingUser, .running:
            return "任务已停止。"
        }
    }

    private func renderStepLimitContinuation(summary: String) {
        activeTaskRequestID = nil
        taskPauseButton.isEnabled = false
        taskCancelButton.isEnabled = false
        taskTakeOverButton.isEnabled = false
        taskConfirmCompleteButton.isEnabled = false
        taskContinueButton.isHidden = false
        taskContinueButton.isEnabled = true
        taskControlDismissButton.isEnabled = true
        let text = [
            summary,
            "点击“\(L10n.AI.continueTask)”会沿用已有步骤历史和最后一次真实输出，再放行 \(agentTaskLoopLimits.maxSteps) 步。"
        ].joined(separator: "\n")
        taskControlLabel.stringValue = text
        taskControlText = text
        taskControlContainer.isHidden = false
    }

    private func clearPendingTaskContinuation() {
        pendingTaskContinuation = nil
        taskContinueButton.isEnabled = false
        taskContinueButton.isHidden = true
    }

    private func beginAutonomousRun() -> UUID {
        let runID = UUID()
        activeAutonomousRunID = runID
        if activeProcessGroupID == nil {
            let processGroupID = UUID()
            activeProcessGroupID = processGroupID
            processGroupTimings[processGroupID] = AIProcessGroupTiming(startedAt: Date())
        }
        return runID
    }

    private func invalidateActiveAutonomousRun() {
        activeAutonomousRunID = nil
        finishActiveProcessGroup(collapse: true)
    }

    private func isActiveAutonomousRun(_ runID: UUID) -> Bool {
        activeAutonomousRunID == runID
    }

    private func handleAgentTaskUpdate(_ update: AgentTaskUpdate, runtimeTitle: String) {
        switch update.kind {
        case .thinking:
            statusLabel.stringValue = update.message
            if isCoordinatorProgressMessage(update.message) == false {
                finalizeAssistantStreamingText(
                    update.message,
                    persistHistory: true,
                    isProcessEntry: true
                )
            }
        case .thinkingDelta:
            appendAssistantStreamingDelta(update.message, isProcessEntry: true)
        case .plan:
            if let plan = update.plan {
                renderPlanWorkspace(plan)
                appendTranscript(.plan, planTranscriptText(for: plan))
            }
        case .step:
            if let step = update.step {
                appendTranscript(.step, stepTranscriptText(for: step), requestID: step.requestID)
            } else {
                appendTranscript(.step, update.message)
            }
        case .trace:
            if let traceEvent = update.traceEvent {
                appendTraceEvent(traceEvent, runtimeTitle: runtimeTitle, allEvents: nil)
                updateStatusFromTrace(traceEvent)
            }
        case .limitReached:
            messageLabel.stringValue = ""
            statusLabel.stringValue = update.message
            isExecuting = false
            activeOrchestrator = nil
            refreshHeaderStatusForCurrentContext()
            appendSystemTranscript(update.message)
        case .completed, .paused, .cancelled, .takenOver, .failed:
            if let result = update.result {
                if result.state == .completed {
                    discardActiveStreamingProcessDraft()
                }
                messageLabel.stringValue = ""
                statusLabel.stringValue = result.state == .completed ? "" : result.summary
                isExecuting = false
                if result.state != .running {
                    activeOrchestrator = nil
                }
                refreshHeaderStatusForCurrentContext()
                collapseActiveProcessEntries()
            } else {
                appendSystemTranscript(update.message)
            }
        }
    }

    private func isCoordinatorProgressMessage(_ message: String) -> Bool {
        switch message {
        case "正在准备终端上下文", "AI 正在生成回复", "AI 已返回结果":
            return true
        default:
            return false
        }
    }

    private func renderPlanWorkspace(_ plan: AgentTaskPlan) {
        currentAgentPlan = plan
        let body = plan.steps.enumerated().map { index, step in
            "\(index + 1). \(step.command)\n   意图：\(step.intent)\n   风险：\(label(for: step.risk))"
        }.joined(separator: "\n")
        planWorkspaceHeaderLabel.stringValue = "计划 · 等待确认"
        planWorkspaceBodyLabel.stringValue = body.isEmpty ? "暂无可执行命令。确认前不会写入终端。" : body
        planWorkspaceText = [
            planWorkspaceHeaderLabel.stringValue,
            plan.summary,
            planWorkspaceBodyLabel.stringValue,
            "控件：确认执行 · 编辑计划 · 取消"
        ].joined(separator: "\n")
        planWorkspaceContainer.isHidden = false
        planWorkspaceConfirmButton.isEnabled = plan.steps.isEmpty == false
        planWorkspaceEditButton.isEnabled = plan.steps.isEmpty == false
        planWorkspaceCancelButton.isEnabled = true
    }

    private func planTranscriptText(for plan: AgentTaskPlan) -> String {
        let lines = plan.steps.enumerated().map { index, step in
            "\(index + 1). \(step.command) · \(step.intent) · \(label(for: step.risk))"
        }
        return (["计划：\(plan.summary)"] + lines + ["确认执行 / 编辑计划 / 取消"]).joined(separator: "\n")
    }

    private func stepTranscriptText(for step: AgentTaskStepResult) -> String {
        [
            "步骤 \(step.requestID) · \(step.state.rawValue)",
            "命令：\(step.command)",
            "意图：\(step.intent)",
            "观察：\(step.observation)"
        ].joined(separator: "\n")
    }

    private func recordTaskHistory(
        question: String,
        context: AITerminalContext,
        response: AIAssistantResponse,
        stateOverride: AgentTaskSessionState? = nil
    ) {
        currentProposalTaskRequestID = nil
        guard let taskRecorder else { return }
        let state = stateOverride ?? (response.commandProposals.isEmpty ? .completed : .awaitingUser)
        let task = AgentTaskSession(
            targetRuntimeID: context.runtimeID,
            targetTitle: context.title,
            state: state,
            proposals: response.commandProposals
        )
        do {
            let requestID = UUID().uuidString
            let record = try taskRecorder.recordAgentTaskSession(
                task,
                requestID: requestID,
                userPrompt: question,
                assistantMessage: response.message
            )
            if response.commandProposals.isEmpty == false {
                currentProposalTaskRequestID = record.requestId
            }
            loadRecentTaskHistory(for: context)
        } catch {
            appendTranscript(
                .assistant,
                "任务历史没有保存成功：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
            )
        }
    }

    private func taskSessionState(for state: AgentTaskRunState) -> AgentTaskSessionState {
        switch state {
        case .completed:
            return .completed
        case .running, .planning:
            return .running
        case .paused, .awaitingUser:
            return .awaitingUser
        case .cancelled:
            return .cancelled
        case .takenOver, .failed:
            return .failed
        case .idle:
            return .idle
        }
    }

    private func loadRecentTaskHistory(for context: AITerminalContext?) {
        guard let context else {
            clearRecentTaskHistory()
            return
        }
        guard let taskLister else {
            clearRecentTaskHistory()
            return
        }
        do {
            let records = try taskLister.listAgentTaskSessions(limit: UInt32(Self.taskHistoryScanLimit))
                .filter { record in
                    record.targetRuntimeId == context.runtimeID
                        && record.actorKind == AgentActorKind.builtInAI.rawValue
                }
                .prefix(Self.taskHistoryDisplayLimit)
            guard records.isEmpty == false else {
                clearRecentTaskHistory()
                return
            }
            recentTaskRecords = Array(records)
            let body = records.map(taskHistoryLine(for:)).joined(separator: "\n")
            taskHistoryBodyLabel.stringValue = body
            taskHistoryText = "\(L10n.AI.recentTasks)\n\(body)"
            renderTaskHistoryButtons(Array(records))
            taskHistoryContainer.isHidden = false
        } catch {
            clearRecentTaskHistory()
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            taskHistoryBodyLabel.stringValue = message
            taskHistoryText = "\(L10n.AI.recentTasks)\n\(message)"
            taskHistoryContainer.isHidden = false
        }
    }

    private func clearRecentTaskHistory() {
        recentTaskRecords = []
        renderTaskHistoryButtons([])
        taskHistoryBodyLabel.stringValue = ""
        taskHistoryContainer.isHidden = true
        taskHistoryText = ""
    }

    private func loadConversationHistory(for context: AITerminalContext?) {
        guard let conversationHistoryStore else { return }
        guard let context else {
            loadedConversationHistoryRuntimeID = nil
            transcriptEntries = []
            renderTranscriptEntries()
            return
        }
        let historyScopeID = context.historyScopeID
        let threads = (try? conversationHistoryStore.listConversationThreads(runtimeID: historyScopeID)) ?? []
        let activeID = activeConversationIDs[historyScopeID] ?? threads.first?.id ?? "legacy"
        activeConversationIDs[historyScopeID] = activeID
        refreshConversationPicker(threads: threads, activeID: activeID)
        let storageID = CoreBridgeAIAssistantConversationHistoryStore.threadStorageID(
            runtimeID: historyScopeID,
            threadID: activeID
        )
        guard loadedConversationHistoryRuntimeID != storageID else {
            return
        }
        loadedConversationHistoryRuntimeID = storageID
        do {
            processGroupTimings = [:]
            transcriptEntries = restoredTranscriptEntries(
                from: try conversationHistoryStore.listConversationHistory(runtimeID: storageID),
                runtimeID: context.runtimeID
            )
            if transcriptEntries.isEmpty == false {
                messageLabel.isHidden = true
            }
            renderTranscriptEntries()
        } catch {
            transcriptEntries = []
            renderTranscriptEntries()
        }
    }

    private func refreshConversationPicker(
        threads: [AIAssistantConversationThreadSummary],
        activeID: String
    ) {
        conversationPopUpButton.removeAllItems()
        let visibleThreads = threads.isEmpty
            ? [AIAssistantConversationThreadSummary(id: activeID, title: "新排查会话", latestMessageAt: "")]
            : threads
        for (index, thread) in visibleThreads.enumerated() {
            conversationPopUpButton.addItem(withTitle: thread.title.isEmpty ? "排查会话 \(index + 1)" : thread.title)
            conversationPopUpButton.lastItem?.representedObject = thread.id
        }
        if let index = visibleThreads.firstIndex(where: { $0.id == activeID }) {
            conversationPopUpButton.selectItem(at: index)
        }
    }

    @objc private func newConversationButtonPressed(_ sender: Any?) {
        guard let historyScopeID = resolvedTargetContext()?.historyScopeID else { return }
        activeConversationIDs[historyScopeID] = UUID().uuidString.lowercased()
        loadedConversationHistoryRuntimeID = nil
        activeStreamingAssistantIndex = nil
        transcriptEntries = []
        processGroupTimings = [:]
        messageLabel.isHidden = false
        loadConversationHistory(for: resolvedTargetContext())
    }

    @objc private func conversationSelectionChanged(_ sender: Any?) {
        guard let historyScopeID = resolvedTargetContext()?.historyScopeID,
              let threadID = conversationPopUpButton.selectedItem?.representedObject as? String
        else { return }
        activeConversationIDs[historyScopeID] = threadID
        loadedConversationHistoryRuntimeID = nil
        loadConversationHistory(for: resolvedTargetContext())
    }

    private func transcriptEntry(for record: AIConversationHistoryItemRecord) -> AITranscriptEntry? {
        let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else { return nil }
        let role = AITranscriptRole(historyRole: AIConversationHistoryRole.fromStoredRawValue(record.role))
        return AITranscriptEntry(
            role: role,
            text: content,
            requestID: record.requestId,
            isProcessEntry: role.isProcessRole,
            isCollapsed: role.isProcessRole,
            createdAt: ISO8601DateFormatter().date(from: record.createdAt) ?? Date()
        )
    }

    private func restoredTranscriptEntries(
        from records: [AIConversationHistoryItemRecord],
        runtimeID: String
    ) -> [AITranscriptEntry] {
        let entries = normalizedLegacyProcessEntries(
            deduplicatingAssistantConclusions(records.compactMap(transcriptEntry(for:)))
        )
        var restored: [AITranscriptEntry] = []
        var index = entries.startIndex
        while index < entries.endIndex {
            guard entries[index].isProcessEntry else {
                restored.append(entries[index])
                index += 1
                continue
            }

            let groupStart = index
            while index < entries.endIndex, entries[index].isProcessEntry {
                index += 1
            }
            let groupEntries = Array(entries[groupStart..<index])
            let requestIDs = Set(groupEntries.compactMap(\.requestID))
            let ownershipByRequestID = Dictionary(uniqueKeysWithValues: requestIDs.map { requestID in
                (requestID, isBuiltInProcessRequest(runtimeID: runtimeID, requestID: requestID))
            })
            let hasOwnedProcess = ownershipByRequestID.values.contains(true)
            let restoredGroupEntries = groupEntries.filter { entry in
                guard let requestID = entry.requestID else {
                    switch entry.role {
                    case .step, .plan:
                        return true
                    case .assistant:
                        return hasOwnedProcess
                    case .user, .system, .command, .terminal:
                        return false
                    }
                }
                return ownershipByRequestID[requestID] == true
            }
            guard restoredGroupEntries.isEmpty == false else {
                continue
            }

            let processGroupID = UUID()
            processGroupTimings[processGroupID] = AIProcessGroupTiming(
                startedAt: restoredGroupEntries[0].createdAt,
                completedAt: restoredGroupEntries[restoredGroupEntries.count - 1].createdAt
            )
            for restoredEntry in restoredGroupEntries {
                var entry = restoredEntry
                entry.processGroupID = processGroupID
                restored.append(entry)
            }
        }
        return restored
    }

    private func deduplicatingAssistantConclusions(
        _ entries: [AITranscriptEntry]
    ) -> [AITranscriptEntry] {
        var retained = Array(repeating: true, count: entries.count)
        var turnStart = entries.startIndex
        while turnStart < entries.endIndex {
            let turnEnd = entries[(turnStart + 1)...].firstIndex(where: { $0.role == .user })
                ?? entries.endIndex
            var lastAssistantIndexByText: [String: Int] = [:]
            for index in turnStart..<turnEnd where entries[index].role == .assistant {
                if let previousIndex = lastAssistantIndexByText[entries[index].text] {
                    retained[previousIndex] = false
                }
                lastAssistantIndexByText[entries[index].text] = index
            }
            turnStart = turnEnd
        }
        return entries.indices.compactMap { retained[$0] ? entries[$0] : nil }
    }

    private func normalizedLegacyProcessEntries(
        _ entries: [AITranscriptEntry]
    ) -> [AITranscriptEntry] {
        var normalized = entries
        var turnStart = normalized.startIndex
        while turnStart < normalized.endIndex {
            let turnEnd = normalized[(turnStart + 1)...].firstIndex(where: { $0.role == .user })
                ?? normalized.endIndex
            let turnRange = turnStart..<turnEnd
            let containsProcess = turnRange.contains { normalized[$0].isProcessEntry }
            let assistantIndices = turnRange.filter { normalized[$0].role == .assistant }
            if containsProcess, assistantIndices.count > 1 {
                for index in assistantIndices.dropLast() {
                    normalized[index].isProcessEntry = true
                    normalized[index].isCollapsed = true
                }
            }
            turnStart = turnEnd
        }
        return normalized
    }

    private func isBuiltInProcessRequest(runtimeID: String, requestID: String) -> Bool {
        guard let taskLister else { return requestID.hasPrefix("agent-step-") }
        guard let records = try? taskLister.listAgentTaskSessions(requestID: requestID) else {
            return requestID.hasPrefix("agent-step-")
        }
        guard records.isEmpty == false else {
            return requestID.hasPrefix("agent-step-")
        }
        let currentRuntimeRecords = records.filter { $0.targetRuntimeId == runtimeID }
        guard currentRuntimeRecords.isEmpty == false else {
            return false
        }
        let actorKinds = Set(
            currentRuntimeRecords.map(\.actorKind)
        )
        guard actorKinds.count == 1 else {
            return false
        }
        return actorKinds.first == AgentActorKind.builtInAI.rawValue
    }

    private func taskHistoryLine(for record: AgentTaskSessionRecord) -> String {
        let command = record.proposals.first?.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandText = command?.isEmpty == false ? command! : "无命令"
        return "\(record.targetTitle) · \(record.state) · \(commandText)"
    }

    private func renderTaskHistoryButtons(_ records: [AgentTaskSessionRecord]) {
        taskHistoryButtonsStack.arrangedSubviews.forEach { view in
            taskHistoryButtonsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        taskHistoryButtonsStack.isHidden = true
    }

    @objc
    private func targetButtonPressed(_ sender: Any?) {
        let picker = AITargetPickerViewController(
            sessions: terminalSessionProvider(),
            allowsMultipleSelection: true,
            initiallySelectedRuntimeIDs: selectedRuntimeIDs
        )
        picker.onSelectRuntimeID = { [weak self] runtimeID in
            self?.selectedRuntimeID = runtimeID
            self?.selectedRuntimeIDs = [runtimeID]
            self?.refreshForCurrentContext()
            self?.dismiss(picker)
        }
        picker.onConfirmRuntimeIDs = { [weak self] runtimeIDs in
            guard let self else { return }
            let normalized = runtimeIDs.filter { $0.isEmpty == false }
            guard normalized.isEmpty == false else { return }
            self.selectedRuntimeIDs = normalized
            self.selectedRuntimeID = normalized.first
            self.refreshForCurrentContext()
            self.dismiss(picker)
        }
        present(
            picker,
            asPopoverRelativeTo: targetButton.bounds,
            of: targetButton,
            preferredEdge: .maxY,
            behavior: .transient
        )
    }

    @objc
    private func collapseButtonPressed(_ sender: Any?) {
        onCollapse?()
    }

    @objc
    private func taskPausePressed(_ sender: Any?) {
        if let activeOrchestrator {
            let hasActiveStep = activeTaskRequestID != nil
            activeOrchestrator.pause()
            self.activeOrchestrator = nil
            invalidateActiveAutonomousRun()
            if hasActiveStep == false {
                activeAutonomousTask?.cancel()
                activeAutonomousTask = nil
            }
            isAsking = false
            isExecuting = false
            endTaskModelSelectionCapture()
            statusLabel.stringValue = "自主执行已暂停。"
            appendSystemTranscript("自主执行已暂停。")
            if let activeTaskRequestID {
                renderTaskControls(for: activeTaskRequestID)
            }
            refreshHeaderStatusForCurrentContext()
            updateQuestionControlState()
            return
        }
        guard let activeTaskRequestID else { return }
        if let event = performTaskControl(for: activeTaskRequestID, action: coordinator.pauseTask).first {
            updateStatusFromTrace(event)
            taskControlStatusesByRequestID[activeTaskRequestID] = "AI 后续自动动作已暂停，当前命令仍以目标终端输出为准。"
            renderTaskControls(for: activeTaskRequestID)
            return
        }
        let message = "任务 \(activeTaskRequestID) 已请求暂停；已写入终端的命令仍以终端输出为准。"
        taskControlStatusesByRequestID[activeTaskRequestID] = "已请求暂停，已写入终端的命令仍以终端输出为准。"
        renderTaskControls(for: activeTaskRequestID)
        statusLabel.stringValue = message
        appendSystemTranscript(message)
    }

    @objc
    private func taskCancelPressed(_ sender: Any?) {
        if let activeOrchestrator {
            let hasActiveStep = activeTaskRequestID != nil
            activeOrchestrator.cancel()
            self.activeOrchestrator = nil
            invalidateActiveAutonomousRun()
            if hasActiveStep == false {
                activeAutonomousTask?.cancel()
                activeAutonomousTask = nil
            }
            isAsking = false
            isExecuting = false
            endTaskModelSelectionCapture()
            statusLabel.stringValue = "自主执行已取消。"
            appendSystemTranscript("自主执行已取消。")
            if let activeTaskRequestID {
                renderTaskControls(for: activeTaskRequestID)
            }
            refreshHeaderStatusForCurrentContext()
            updateQuestionControlState()
            return
        }
        guard let activeTaskRequestID else { return }
        if let event = performTaskControl(for: activeTaskRequestID, action: coordinator.cancelTask).first {
            updateStatusFromTrace(event)
            taskControlStatusesByRequestID[activeTaskRequestID] = controlStatusText(forCancelEvent: event)
            renderTaskControls(for: activeTaskRequestID)
            return
        }
        let message = "任务 \(activeTaskRequestID) 已请求取消；未找到活动控制句柄，请在目标终端确认状态。"
        taskControlStatusesByRequestID[activeTaskRequestID] = "已请求取消，未找到活动控制句柄，请在目标终端确认状态。"
        renderTaskControls(for: activeTaskRequestID)
        statusLabel.stringValue = message
        appendSystemTranscript(message)
    }

    private func controlStatusText(forCancelEvent event: AgentTraceEvent) -> String {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty == false {
            return message
        }
        if event.metadata?["executionMode"] == "visibleTerminal" {
            return "已向可见终端发送中断，输出仍以目标终端为准。"
        }
        if event.metadata?["executionMode"] == "backgroundTask" {
            return "AI 独立任务已取消。"
        }
        return "已请求取消，请在目标终端确认状态。"
    }

    @objc
    private func taskTakeOverPressed(_ sender: Any?) {
        if let activeOrchestrator {
            activeOrchestrator.takeOver()
            self.activeOrchestrator = nil
            invalidateActiveAutonomousRun()
            isExecuting = false
            endTaskModelSelectionCapture()
            statusLabel.stringValue = "自主执行已切换为人工接管。"
            appendSystemTranscript("自主执行已切换为人工接管。")
            if let activeTaskRequestID {
                renderTaskControls(for: activeTaskRequestID)
            }
            refreshHeaderStatusForCurrentContext()
            return
        }
        guard let activeTaskRequestID else { return }
        if let event = performTaskControl(for: activeTaskRequestID, action: coordinator.takeOverTask).first {
            updateStatusFromTrace(event)
            taskControlStatusesByRequestID[activeTaskRequestID] = controlStatusText(forTakeOverEvent: event)
            renderTaskControls(for: activeTaskRequestID)
            return
        }
        let message = "任务 \(activeTaskRequestID) 已切换为人工接管，请在目标终端继续操作。"
        taskControlStatusesByRequestID[activeTaskRequestID] = "已人工接管，请在目标终端继续操作。"
        renderTaskControls(for: activeTaskRequestID)
        statusLabel.stringValue = message
        appendSystemTranscript(message)
    }

    private func controlStatusText(forTakeOverEvent event: AgentTraceEvent) -> String {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty == false {
            return message
        }
        if event.metadata?["executionMode"] == "visibleTerminal" {
            return "可见终端已切换为人工接管，后续输出仍以目标终端为准。"
        }
        if event.metadata?["executionMode"] == "backgroundTask" {
            return "任务已切换为人工接管，AI 不再继续自动执行。"
        }
        return "已切换为人工接管，请在目标终端继续操作。"
    }

    @objc
    private func taskConfirmCompletePressed(_ sender: Any?) {
        guard let activeTaskRequestID else { return }
        if let event = coordinator.confirmTaskComplete(requestID: activeTaskRequestID) {
            appendTraceEvent(
                event,
                runtimeTitle: traceRuntimeTitlesByRequestID[activeTaskRequestID],
                allEvents: nil
            )
        }
        taskControlStatusesByRequestID[activeTaskRequestID] =
            "已确认本步结束；AI 不会再把后续混入输出归入本步结果。"
        isExecuting = false
        activeOrchestrator = nil
        endTaskModelSelectionCapture()
        statusLabel.stringValue = "已确认本步结束。"
        appendSystemTranscript("已确认本步结束。")
        renderTaskControls(for: activeTaskRequestID)
        refreshHeaderStatusForCurrentContext()
        updateCommandButtonState()
    }

    @objc
    private func taskContinuePressed(_ sender: Any?) {
        guard let continuation = pendingTaskContinuation else { return }
        restoreCapturedTaskModelSelection(continuation.modelSelection)
        clearPendingTaskContinuation()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: agentTaskLoopLimits,
            targetContextsProvider: { [weak self] in self?.resolvedTargetContexts() ?? [] }
        )
        activeOrchestrator = orchestrator
        activeAutonomousTask?.cancel()
        let runID = beginAutonomousRun()
        isExecuting = true
        statusLabel.stringValue = "已继续，自主执行再放行 \(agentTaskLoopLimits.maxSteps) 步。"
        taskControlLabel.stringValue = statusLabel.stringValue
        taskControlText = statusLabel.stringValue
        taskControlContainer.isHidden = false
        taskControlDismissButton.isEnabled = true
        refreshHeaderStatus(context: continuation.context)
        updateQuestionControlState()
        appendSystemTranscript(statusLabel.stringValue)
        activeAutonomousTask = Task { [weak self, orchestrator, runID] in
            do {
                let result = try await orchestrator.run(
                    goal: continuation.goal,
                    context: continuation.context,
                    contextProvider: { [weak self] in
                        self?.contextProvider(continuation.context.runtimeID) ?? continuation.context
                    },
                    attachments: continuation.attachments,
                    continuingFrom: continuation.completedSteps,
                    onUpdate: { [weak self] update in
                        guard let self, self.isActiveAutonomousRun(runID) else { return }
                        self.handleAgentTaskUpdate(update, runtimeTitle: continuation.context.title)
                    }
                )
                guard Task.isCancelled == false else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.finishAgentTaskRun(
                    result,
                    question: continuation.question,
                    goal: continuation.goal,
                    context: continuation.context,
                    attachments: continuation.attachments
                )
            } catch {
                guard Task.isCancelled == false, !(error is CancellationError) else { return }
                guard let self, self.isActiveAutonomousRun(runID) else { return }
                self.isExecuting = false
                self.activeOrchestrator = nil
                self.activeAutonomousTask = nil
                self.clearPendingTaskContinuation()
                self.endTaskModelSelectionCapture()
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                self.messageLabel.stringValue = message
                self.appendSystemTranscript("继续执行失败：\(message)")
                self.statusLabel.stringValue = ""
                self.refreshHeaderStatus(context: continuation.context)
                self.updateQuestionControlState()
                self.invalidateActiveAutonomousRun()
            }
        }
    }

    @objc
    private func taskControlDismissPressed(_ sender: Any?) {
        clearPendingTaskContinuation()
        endTaskModelSelectionCapture()
        activeTaskRequestID = nil
        taskControlText = ""
        taskControlContainer.isHidden = true
        taskPauseButton.isEnabled = false
        taskCancelButton.isEnabled = false
        taskTakeOverButton.isEnabled = false
        taskConfirmCompleteButton.isEnabled = false
        taskContinueButton.isEnabled = false
        taskControlDismissButton.isEnabled = false
    }

    @objc
    private func planConfirmPressed(_ sender: Any?) {
        guard let plan = currentAgentPlan else { return }
        guard let context = refreshContextSummary() else {
            messageLabel.stringValue = L10n.AI.noTerminal
            statusLabel.stringValue = ""
            return
        }
        planWorkspaceContainer.isHidden = true
        planWorkspaceConfirmButton.isEnabled = false
        planWorkspaceEditButton.isEnabled = false
        planWorkspaceCancelButton.isEnabled = false
        appendSystemTranscript("计划已确认，我开始按顺序执行。")
        setCommandProposals([])
        currentProposalTaskRequestID = nil
        currentAgentPlan = nil
        let initialResponse = AIAssistantResponse(
            message: plan.summary,
            commandProposals: plan.steps.map {
                AgentCommandProposal(command: $0.command, explanation: $0.intent, risk: $0.risk)
            }
        )
        startStepwiseAutoRun(
            question: plan.goal,
            goal: plan.goal,
            context: context,
            attachments: [],
            initialResponse: initialResponse,
            introduction: "计划已确认。我先执行第一步，拿到真实输出后再决定下一步。"
        )
    }

    @objc
    private func planEditPressed(_ sender: Any?) {
        guard let plan = currentAgentPlan else { return }
        questionField.stringValue = plan.steps.map(\.command).joined(separator: " && ")
        appendSystemTranscript("已把计划命令放回输入框，你可以编辑后重新发送。")
        updateQuestionControlState()
    }

    @objc
    private func planCancelPressed(_ sender: Any?) {
        currentAgentPlan = nil
        planWorkspaceText = ""
        planWorkspaceContainer.isHidden = true
        planWorkspaceConfirmButton.isEnabled = false
        planWorkspaceEditButton.isEnabled = false
        planWorkspaceCancelButton.isEnabled = false
        appendSystemTranscript("计划已取消，未写入终端。")
        statusLabel.stringValue = ""
        endTaskModelSelectionCapture()
        invalidateActiveAutonomousRun()
    }

    @discardableResult
    private func runCommand(
        _ command: String,
        from card: AICommandCardView?,
        announcePreparation: Bool = true
    ) -> AgentTraceEvent? {
        guard command.isEmpty == false, let context = refreshContextSummary() else {
            statusLabel.stringValue = L10n.AI.noTerminal
            return nil
        }
        let contexts = resolvedTargetContexts()
        let requestID = currentProposalTaskRequestID ?? UUID().uuidString
        currentProposalTaskRequestID = nil
        finishActiveProcessGroup(collapse: true)
        let processGroupID = UUID()
        activeProcessGroupID = processGroupID
        processGroupTimings[processGroupID] = AIProcessGroupTiming(startedAt: Date())
        manualProcessGroupIDsByRequestID[requestID] = processGroupID
        isExecuting = true
        refreshHeaderStatus(context: context)
        statusLabel.stringValue = L10n.AI.executing
        if announcePreparation {
            appendSystemTranscript("准备把命令交给目标终端。", isProcessEntry: true)
        }
        updateCommandButtonState()
        defer {
            isExecuting = false
            refreshHeaderStatusForCurrentContext()
            updateCommandButtonState()
        }
        do {
            var streamedEvents: [AgentTraceEvent] = []
            let events = try coordinator.executeProposedCommand(
                command,
                contexts: contexts.isEmpty ? [context] : contexts,
                requestID: requestID,
                emit: { [weak self] event in
                    guard let self else { return }
                    streamedEvents.append(event)
                    self.appendTraceEvent(event, runtimeTitle: context.title, allEvents: nil)
                    self.updateStatusFromTrace(event)
                }
            )
            registerTaskControlRequestIDs(events)
            if let eventRequestID = events.first?.requestID,
               eventRequestID != requestID,
               let pendingConclusion = pendingAssistantConclusionsByRequestID.removeValue(forKey: requestID) {
                pendingAssistantConclusionsByRequestID[eventRequestID] = pendingConclusion
                if let finalEvent = events.last(where: { $0.requestID == eventRequestID && isTerminalTraceState($0.state) }) {
                    appendPendingAssistantConclusionIfReady(for: finalEvent)
                }
            }
            if streamedEvents.isEmpty {
                appendTraceEvents(events, runtimeTitle: context.title)
            }
            if let terminalEvent = terminalExecutionEvent(from: events) {
                switch terminalEvent.state {
                case .failed:
                    card?.updateState(.failed)
                    statusLabel.stringValue = terminalEvent.message
                    appendSystemTranscript("执行失败：\(terminalEvent.message)")
                    setFailedRetryCommand(command)
                    return terminalEvent
                case .cancelled:
                    card?.updateState(.failed)
                    statusLabel.stringValue = terminalEvent.message
                    appendSystemTranscript(terminalEvent.message)
                    setFailedRetryCommand(command)
                    return terminalEvent
                case .paused, .takenOver:
                    card?.updateState(.running)
                    statusLabel.stringValue = terminalEvent.message
                    appendSystemTranscript(terminalEvent.message)
                default:
                    card?.updateState(.running)
                    statusLabel.stringValue = statusText(forTerminalExecutionEvent: terminalEvent)
                }
            } else {
                card?.updateState(.running)
                statusLabel.stringValue = L10n.AI.sentToTerminal
            }
            setCommandProposals([])
            return terminalExecutionEvent(from: events)
        } catch {
            finishManualProcessGroupIfNeeded(for: requestID)
            card?.updateState(.failed)
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            statusLabel.stringValue = message
            appendSystemTranscript("执行失败：\(message)")
            setFailedRetryCommand(command)
            return nil
        }
    }

    private func setFailedRetryCommand(_ command: String) {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.isEmpty == false else {
            setCommandProposals([])
            return
        }
        setCommandProposals([
            AgentCommandProposal(
                command: trimmedCommand,
                explanation: "执行失败，可编辑后重新运行。",
                risk: AgentActionClassifier.risk(forCommand: trimmedCommand),
                state: .proposed
            )
        ])
    }

    private func statusText(forTerminalExecutionEvent event: AgentTraceEvent) -> String {
        if event.metadata?["executionMode"] == "backgroundTask"
            || event.message.contains("独立任务") {
            return event.message
        }
        return L10n.AI.sentToTerminal
    }

    private func terminalExecutionEvent(from events: [AgentTraceEvent]) -> AgentTraceEvent? {
        events.last { event in
            switch event.state {
            case .running, .waitingForOutput, .paused, .completed, .failed, .cancelled, .takenOver:
                return true
            case .queued, .awaitingApproval, .approved, .typing:
                return false
            }
        }
    }

    private func appendAssistantProgress(_ message: String) {
        let humanText: String
        switch message {
        case "正在准备终端上下文":
            humanText = "我正在整理当前终端里的关键信息。"
        case "AI 正在生成回复":
            humanText = "我正在组织回复。"
        case "AI 已返回结果":
            humanText = "我拿到结果了。"
        default:
            humanText = message
        }
        statusLabel.stringValue = humanText
    }

    private func setCommandProposals(_ proposals: [AgentCommandProposal]) {
        commandCards.forEach { card in
            commandCardsStack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        commandCards = proposals.map { proposal in
            let card = AICommandCardView(proposal: proposal)
            let settings = settingsStore.snapshot()
            card.commandHighlightLevel = settings.terminalHighlightLevel
            card.commandHighlightTheme = TerminalAppearanceApplier.highlightTheme(for: settings)
            card.richCommandHighlightingEnabled = settings.terminalRichHighlightingEnabled
            card.onRun = { [weak self, weak card] command in
                self?.persistCommandCardHistory(
                    command: command,
                    risk: AgentActionClassifier.risk(forCommand: command),
                    stateText: "已执行"
                )
                self?.runCommand(command, from: card)
            }
            card.onSkip = { [weak self] command, risk in
                let message = self?.skippedCommandStatus(command: command, risk: risk) ?? L10n.AI.skippedCommand
                self?.statusLabel.stringValue = message
                self?.persistCommandCardHistory(command: command, risk: risk, stateText: "已跳过")
                self?.appendSystemTranscript(message)
                self?.updateCommandButtonState()
            }
            card.onCopy = { command in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            commandCardsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: commandCardsStack.widthAnchor).isActive = true
            persistCommandCardHistory(
                command: proposal.command,
                risk: proposal.risk,
                stateText: stateText(forCommandProposal: proposal),
                explanation: proposal.explanation
            )
            return card
        }
        updateConversationBottomLayout()
        updateCommandButtonState()
    }

    private func stateText(forCommandProposal proposal: AgentCommandProposal) -> String {
        switch proposal.state {
        case .proposed:
            return "待确认"
        case .skipped:
            return "已跳过"
        case .running:
            return "已执行"
        case .completed:
            return "已完成"
        case .failed:
            return "执行失败"
        }
    }

    private func persistCommandCardHistory(
        command: String,
        risk: AgentActionRisk,
        stateText: String,
        explanation: String? = nil
    ) {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.isEmpty == false else { return }
        var lines = [
            "命令卡片 · \(stateText)",
            "风险：\(label(for: risk))"
        ]
        if let explanation,
           explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("说明：\(explanation.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append("$ \(trimmedCommand)")
        persistConversationHistory(
            role: .command,
            content: lines.joined(separator: "\n"),
            requestID: currentProposalTaskRequestID
        )
    }

    private func skippedCommandStatus(command: String, risk: AgentActionRisk) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.isEmpty == false else {
            return L10n.AI.skippedCommand
        }
        return "已跳过命令：\(trimmedCommand) · 风险：\(label(for: risk)) · 未写入终端"
    }

    private func observeSettingsChanges() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let settings = self.settingsStore.snapshot()
            let theme = TerminalAppearanceApplier.highlightTheme(for: settings)
            self.commandCards.forEach {
                $0.commandHighlightLevel = settings.terminalHighlightLevel
                $0.commandHighlightTheme = theme
                $0.richCommandHighlightingEnabled = settings.terminalRichHighlightingEnabled
            }
            self.reconcileTemporaryModelSelection()
            _ = self.refreshContextSummary()
            self.refreshComposerControls()
            self.refreshComposerModelPicker()
        }
    }

    private func refreshContextSummary() -> AITerminalContext? {
        guard let context = resolvedTargetContext() else {
            contextLabel.stringValue = L10n.AI.noTerminal
            updateTargetButtonTitle(nil)
            refreshHeaderStatus(context: nil)
            refreshContextUsageRing(for: nil)
            return nil
        }
        let directory = context.currentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = aiModeSummary()
        if let directory, directory.isEmpty == false {
            contextLabel.stringValue = "当前终端：\(context.title) · \(directory) · \(mode)"
        } else {
            contextLabel.stringValue = "当前终端：\(context.title) · \(mode)"
        }
        updateTargetButtonTitle(context.title)
        refreshHeaderStatus(context: context)
        refreshContextUsageRing(for: context)
        return context
    }

    private func resolvedTargetContext() -> AITerminalContext? {
        resolvedTargetContexts().first
    }

    private func resolvedTargetContexts() -> [AITerminalContext] {
        let ids = selectedRuntimeIDs.isEmpty
            ? selectedRuntimeID.map { [$0] } ?? []
            : selectedRuntimeIDs
        if ids.isEmpty {
            return contextProvider(nil).map { [$0] } ?? []
        }
        var seen = Set<String>()
        let contexts = ids.compactMap { contextProvider($0) }.filter {
            seen.insert($0.runtimeID).inserted
        }
        if contexts.isEmpty {
            selectedRuntimeID = nil
            selectedRuntimeIDs = []
            return contextProvider(nil).map { [$0] } ?? []
        }
        selectedRuntimeIDs = contexts.map(\.runtimeID)
        selectedRuntimeID = selectedRuntimeIDs.first
        return contexts
    }

    private func updateTargetButtonTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmed?.isEmpty == false ? trimmed! : L10n.AI.targetPicker
        let selectionCount = selectedRuntimeIDs.count
        targetButton.title = selectionCount > 1 ? "\(selectionCount) 个终端" : displayTitle
        targetButton.image = nil
        if selectionCount > 1 {
            targetButton.toolTip = selectedRuntimeIDs
                .compactMap { contextProvider($0)?.title }
                .joined(separator: "、")
        } else {
            targetButton.toolTip = displayTitle == L10n.AI.targetPicker
                ? L10n.AI.targetPicker
                : "\(L10n.AI.currentTarget)：\(displayTitle)"
        }
        targetButton.setAccessibilityLabel(targetButton.toolTip)
    }

    private func refreshHeaderStatus(context: AITerminalContext?) {
        if isExecuting {
            headerStatusLabel.stringValue = "执行中"
            StacioDesignSystem.setLayerBackgroundColor(headerStatusDot, color: StacioDesignSystem.theme.accentColor)
        } else if isAsking {
            headerStatusLabel.stringValue = "思考中"
            StacioDesignSystem.setLayerBackgroundColor(headerStatusDot, color: StacioDesignSystem.theme.warningColor)
        } else if context != nil {
            headerStatusLabel.stringValue = "就绪"
            StacioDesignSystem.setLayerBackgroundColor(headerStatusDot, color: StacioDesignSystem.theme.successColor)
        } else {
            headerStatusLabel.stringValue = "未选择终端"
            StacioDesignSystem.setLayerBackgroundColor(headerStatusDot, color: StacioDesignSystem.theme.secondaryTextColor)
        }
    }

    private func refreshHeaderStatusForCurrentContext() {
        refreshHeaderStatus(context: resolvedTargetContext())
    }

    private func aiModeSummary() -> String {
        let resolved = resolvedComposerModel()
        guard let selection = resolved.selection else {
            return "\(L10n.AI.modelMode)：\(resolved.providerTitle)"
        }
        return "\(L10n.AI.modelMode)：\(resolved.providerTitle) · \(selection.modelID)"
    }

    private func composerAugmentedQuestion(for question: String) -> String {
        var contextLines: [String] = []
        if planModeEnabled {
            contextLines.append("计划模式：请像 Codex Plan 模式一样，先拆解步骤、标注风险和验证路径；除非用户要求执行，否则优先给出计划。")
        }
        if goalModeEnabled {
            contextLines.append("追求目标：请像 Codex 目标模式一样围绕当前目标持续推进，记录假设、下一步和完成标准。")
        }
        if composerAttachments.isEmpty == false {
            contextLines.append("附件上下文：")
            contextLines.append(contentsOf: composerAttachments.enumerated().map { index, attachment in
                "\(index + 1). \(attachment.promptSummary)"
            })
        }
        guard contextLines.isEmpty == false else {
            return question
        }
        return ([question, ""] + contextLines).joined(separator: "\n")
    }

    private func refreshComposerControls() {
        composerPermissionButton.title = permissionTitle(for: settingsStore.snapshot().agentConfirmationPolicy)
        composerPermissionButton.toolTip = "修改 AI 命令审批权限"
        composerPermissionButton.setAccessibilityLabel(composerPermissionButton.title)
        composerModelButton.title = currentModelTitle()
        composerModelButton.toolTip = hasConfiguredAssistantModel
            ? composerModelButton.title
            : Self.unconfiguredProviderMessage
        composerModelButton.setAccessibilityLabel(composerModelButton.title)
        refreshContextUsageRing()
        renderComposerAttachments()
        let context = composerContextItems()
        composerContextLabel.stringValue = context.joined(separator: " · ")
        composerContextLabel.isHidden = context.isEmpty
        updateComposerHeight()
        updateQuestionControlState()
    }

    private func composerContextItems() -> [String] {
        var items: [String] = []
        if planModeEnabled {
            items.append("计划模式")
        }
        if goalModeEnabled {
            items.append("追求目标")
        }
        return items
    }

    private func renderComposerAttachments() {
        composerAttachmentStack.arrangedSubviews.forEach { view in
            composerAttachmentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        composerAttachmentStack.isHidden = composerAttachments.isEmpty
        questionTopWithoutAttachmentsConstraint?.isActive = composerAttachments.isEmpty
        questionTopWithAttachmentsConstraint?.isActive = composerAttachments.isEmpty == false
        for (index, attachment) in composerAttachments.enumerated() {
            let card = AIComposerAttachmentCardView(attachment: attachment, index: index)
            card.onDelete = { [weak self] index in
                self?.removeComposerAttachment(at: index)
            }
            card.onPreview = { [weak self] index in
                self?.previewComposerAttachment(at: index)
            }
            composerAttachmentStack.addArrangedSubview(card)
            card.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
    }

    private func updateComposerHeight() {
        if composerAttachments.isEmpty == false {
            composerHeightConstraint?.constant = Self.attachmentComposerHeight
        } else if composerContextItems().isEmpty == false {
            composerHeightConstraint?.constant = Self.contextComposerHeight
        } else {
            composerHeightConstraint?.constant = Self.compactComposerHeight
        }
        view.needsLayout = true
    }

    private func removeComposerAttachment(at index: Int) {
        guard composerAttachments.indices.contains(index) else { return }
        composerAttachments.remove(at: index)
        refreshComposerControls()
    }

    private func previewComposerAttachment(at index: Int) {
        guard composerAttachments.indices.contains(index) else { return }
        showComposerAttachmentPreview(composerAttachments[index])
    }

    private func showComposerAttachmentPreview(_ attachment: AIAssistantAttachment) {
        composerPreviewWindow?.close()
        let preview = AIComposerAttachmentPreviewView(attachment: attachment)
        let hosting = NSViewController()
        hosting.view = preview
        let window = NSWindow(contentViewController: hosting)
        window.title = attachment.filename
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 880, height: 620))
        window.center()
        composerPreviewWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func currentModelTitle() -> String {
        let resolved = resolvedComposerModel()
        guard let selection = resolved.selection else {
            return resolved.providerTitle
        }
        return "\(resolved.providerTitle) · \(selection.modelID) \(reasoningTitle(for: resolved.model?.capabilities.effectiveReasoningEffort ?? .minimal))"
    }

    private func reasoningTitle(for effort: AIReasoningEffortPreference) -> String {
        switch effort {
        case .minimal:
            return "低"
        case .low:
            return "中"
        case .medium:
            return "高"
        case .high:
            return "超高"
        }
    }

    private func reasoningEffortItems(
        for model: AIProviderModelConfiguration?
    ) -> [(title: String, effort: AIReasoningEffortPreference)] {
        let efforts = model?.capabilities.supportedReasoningEfforts
            ?? AIReasoningEffortPreference.allCases
        return efforts.map { (reasoningTitle(for: $0), $0) }
    }

    private func permissionTitle(for policy: AgentConfirmationPolicyPreference) -> String {
        switch policy {
        case .allowAllWithoutPrompt:
            return "完全访问"
        case .allowLowRiskWithoutPrompt:
            return "低风险自动"
        case .allowReadOnlyWithoutPrompt:
            return "只读自动"
        case .requireEveryCommand:
            return "每条确认"
        }
    }

    private func composerModelGroups() -> [AIComposerModelPickerGroup] {
        normalizedProviderEnvelope().aiProviders.compactMap { provider in
            guard provider.isEnabled, provider.profile.usesModelInterface else {
                return nil
            }
            let selections = provider.models.compactMap { model -> AIModelSelection? in
                let modelID = AppSettings.normalizedAIModelName(model.id)
                guard model.isEnabled, modelID.isEmpty == false else {
                    return nil
                }
                return AIModelSelection(providerID: provider.id, modelID: modelID)
            }
            guard selections.isEmpty == false else {
                return nil
            }
            return AIComposerModelPickerGroup(
                providerID: provider.id,
                providerTitle: provider.displayName,
                models: selections
            )
        }
    }

    private func normalizedProviderEnvelope() -> AIProviderSettingsEnvelope {
        AIProviderSettingsNormalizer.normalized(settingsStore.snapshot().aiProviderSettings)
    }

    private func resolvedComposerModel() -> (
        selection: AIModelSelection?,
        providerTitle: String,
        model: AIProviderModelConfiguration?
    ) {
        let envelope = normalizedProviderEnvelope()
        switch AIProviderRuntimeResolver.resolve(
            envelope: envelope,
            requestedSelection: modelSelectionSession.snapshot()
        ) {
        case let .external(provider, modelID):
            return (
                AIModelSelection(providerID: provider.id, modelID: modelID),
                provider.displayName,
                provider.models.first(where: { $0.id == modelID })
            )
        case let .unconfigured(provider):
            return (nil, "\(provider.displayName) · 未配置模型", nil)
        }
    }

    private var hasConfiguredAssistantModel: Bool {
        switch AIProviderRuntimeResolver.resolve(
            envelope: normalizedProviderEnvelope(),
            requestedSelection: modelSelectionSession.snapshot()
        ) {
        case .external:
            return true
        case .unconfigured:
            return false
        }
    }

    private func reconcileTemporaryModelSelection() {
        guard let selection = modelSelectionSession.snapshot() else {
            return
        }
        if selection.providerID == BuiltInAIProvider.stacioRulesID {
            modelSelectionSession.select(nil)
            return
        }
        let normalizedModelID = AppSettings.normalizedAIModelName(selection.modelID)
        let envelope = normalizedProviderEnvelope()
        guard normalizedModelID.isEmpty == false,
              let provider = envelope.aiProviders.first(where: { $0.id == selection.providerID }),
              provider.isEnabled,
              provider.profile.usesModelInterface,
              provider.models.contains(where: { $0.isEnabled && $0.id == normalizedModelID })
        else {
            modelSelectionSession.select(nil)
            return
        }
        let normalizedSelection = AIModelSelection(
            providerID: selection.providerID,
            modelID: normalizedModelID
        )
        if normalizedSelection != selection {
            modelSelectionSession.select(normalizedSelection)
        }
    }

    private func beginTaskModelSelectionCapture() {
        if let capturedTaskModelSelection {
            modelSelectionSession.select(capturedTaskModelSelection)
            updateQuestionControlState()
            return
        }
        let resolved = resolvedComposerModel()
        guard let captured = resolved.selection else {
            return
        }
        modelSelectionBeforeTask = modelSelectionSession.snapshot()
        capturedTaskModelSelection = captured
        modelSelectionSession.select(captured)
        refreshComposerControls()
        updateQuestionControlState()
    }

    private func restoreCapturedTaskModelSelection(_ selection: AIModelSelection) {
        capturedTaskModelSelection = selection
        modelSelectionSession.select(selection)
        refreshComposerControls()
        updateQuestionControlState()
    }

    private func endTaskModelSelectionCapture() {
        guard capturedTaskModelSelection != nil else {
            return
        }
        let previousSelection = modelSelectionBeforeTask
        capturedTaskModelSelection = nil
        modelSelectionBeforeTask = nil
        modelSelectionSession.select(previousSelection)
        reconcileTemporaryModelSelection()
        refreshComposerControls()
        updateQuestionControlState()
    }

    private func composerAddMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeComposerMenuItem(title: "添加照片和文件", action: #selector(addFilesContextPressed(_:)), representedObject: "files"))
        let currentFileItem = makeComposerMenuItem(
            title: "附加当前文件",
            action: #selector(addCurrentRemoteFileContextPressed(_:)),
            representedObject: "current-file"
        )
        currentFileItem.isEnabled = currentRemoteFileAttachmentAvailable()
        menu.addItem(currentFileItem)
        menu.addItem(.separator())
        menu.addItem(makeComposerToggleMenuItem(title: "计划模式", action: #selector(togglePlanModePressed(_:)), state: planModeEnabled))
        menu.addItem(makeComposerToggleMenuItem(title: "追求目标", action: #selector(toggleGoalModePressed(_:)), state: goalModeEnabled))
        return menu
    }

    private func composerModelMenu() -> NSMenu {
        let menu = NSMenu()
        let resolved = resolvedComposerModel()
        if let model = resolved.model {
            let currentEffort = model.capabilities.effectiveReasoningEffort
            for (title, effort) in reasoningEffortItems(for: model) {
                let item = makeComposerMenuItem(
                    title: title,
                    action: #selector(selectComposerReasoningPressed(_:)),
                    representedObject: effort.rawValue
                )
                item.state = effort == currentEffort ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let currentSelection = modelSelectionSession.snapshot()
        let followGlobalDefault = makeComposerMenuItem(
            title: "跟随全局默认",
            action: #selector(selectComposerModelPressed(_:)),
            representedObject: NSNull()
        )
        followGlobalDefault.state = currentSelection == nil ? .on : .off
        followGlobalDefault.toolTip = "使用设置中的默认供应商和模型"
        menu.addItem(followGlobalDefault)

        let groups = composerModelGroups()
        guard groups.isEmpty == false else {
            return menu
        }
        menu.addItem(.separator())
        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 {
                menu.addItem(.separator())
            }
            let heading = NSMenuItem(title: group.providerTitle, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            heading.representedObject = group.providerID
            menu.addItem(heading)
            for selection in group.models {
                let item = makeComposerMenuItem(
                    title: selection.modelID,
                    action: #selector(selectComposerModelPressed(_:)),
                    representedObject: selection
                )
                item.indentationLevel = 1
                item.state = selection == currentSelection ? .on : .off
                item.toolTip = "\(group.providerTitle) · \(selection.modelID)"
                menu.addItem(item)
            }
        }
        return menu
    }

    private func composerPermissionMenu() -> NSMenu {
        let menu = NSMenu()
        let current = settingsStore.snapshot().agentConfirmationPolicy
        for (title, policy) in composerPermissionItems() {
            let item = makeComposerMenuItem(
                title: title,
                action: #selector(selectComposerPermissionPressed(_:)),
                representedObject: policy.rawValue
            )
            item.state = policy == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func composerPermissionItems() -> [(title: String, policy: AgentConfirmationPolicyPreference)] {
        [
            ("完全访问", .allowAllWithoutPrompt),
            ("低风险自动", .allowLowRiskWithoutPrompt),
            ("只读自动", .allowReadOnlyWithoutPrompt),
            ("每条确认", .requireEveryCommand)
        ]
    }

    private func makeComposerMenuItem(
        title: String,
        action: Selector,
        representedObject: Any?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }

    private func makeComposerToggleMenuItem(
        title: String,
        action: Selector,
        state: Bool
    ) -> NSMenuItem {
        let item = makeComposerMenuItem(title: title, action: action, representedObject: title)
        item.state = state ? .on : .off
        return item
    }

    private func popUpComposerMenu(_ menu: NSMenu, from button: NSButton) {
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: button)
    }

    @objc
    private func composerAddButtonPressed(_ sender: NSButton) {
        showComposerAddPicker(from: sender)
    }

    @objc
    private func composerModelButtonPressed(_ sender: NSButton) {
        showComposerModelPicker(from: sender)
    }

    @objc
    private func composerPermissionButtonPressed(_ sender: NSButton) {
        showComposerPermissionPicker(from: sender)
    }

    @objc
    private func addFilesContextPressed(_ sender: NSMenuItem) {
        addSelectedComposerAttachments()
    }

    @objc
    private func addCurrentRemoteFileContextPressed(_ sender: NSMenuItem) {
        addCurrentRemoteFileContext()
    }

    @objc
    private func togglePlanModePressed(_ sender: NSMenuItem) {
        planModeEnabled.toggle()
        refreshComposerControls()
    }

    @objc
    private func toggleGoalModePressed(_ sender: NSMenuItem) {
        goalModeEnabled.toggle()
        refreshComposerControls()
    }

    @objc
    private func selectComposerModelPressed(_ sender: NSMenuItem) {
        if sender.representedObject is NSNull {
            selectComposerModel(nil)
            return
        }
        guard let selection = sender.representedObject as? AIModelSelection else {
            return
        }
        selectComposerModel(selection)
    }

    @objc
    private func selectComposerReasoningPressed(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let effort = AIReasoningEffortPreference(rawValue: rawValue)
        else {
            return
        }
        selectComposerReasoning(effort)
    }

    @objc
    private func selectComposerPermissionPressed(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let policy = AgentConfirmationPolicyPreference(rawValue: rawValue)
        else {
            return
        }
        selectComposerPermission(policy)
    }

    private func addSelectedComposerAttachments() {
        let urls = attachmentPicker()
        guard urls.isEmpty == false else { return }
        addComposerAttachmentURLs(urls)
    }

    private func addCurrentRemoteFileContext() {
        guard let currentRemoteFileAttachmentProvider else {
            statusLabel.stringValue = AIAssistantRemoteFileAttachmentError.unsupportedProtocol.userMessage
            return
        }
        do {
            let attachment = try currentRemoteFileAttachmentProvider()
            appendComposerAttachments([attachment])
            statusLabel.stringValue = "已附加当前文件：\(attachment.filename)"
        } catch let error as AIAssistantRemoteFileAttachmentError {
            statusLabel.stringValue = error.userMessage
        } catch {
            statusLabel.stringValue = "当前文件无法作为 AI 上下文"
        }
    }

    private func addComposerAttachmentURLs(_ urls: [URL]) {
        var added: [AIAssistantAttachment] = []
        var failed: [String] = []
        for url in urls {
            do {
                let attachment = try makeComposerAttachment(from: url)
                if composerAttachments.contains(where: { $0.filename == attachment.filename }) == false {
                    composerAttachments.append(attachment)
                    added.append(attachment)
                }
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        refreshComposerControls()
        if added.isEmpty == false {
            statusLabel.stringValue = "已添加附件：\(added.map(\.filename).joined(separator: "、"))"
        } else if failed.isEmpty == false {
            statusLabel.stringValue = "附件读取失败：\(failed.joined(separator: "、"))"
        }
    }

    private func addComposerAttachments(from pasteboard: NSPasteboard) -> Bool {
        var handled = false
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        if urls.isEmpty == false {
            addComposerAttachmentURLs(urls)
            handled = true
        }
        guard handled == false else {
            return true
        }
        let imageItems = imageAttachments(from: pasteboard)
        if imageItems.isEmpty == false {
            appendComposerAttachments(imageItems)
            statusLabel.stringValue = "已添加粘贴图片：\(imageItems.map(\.filename).joined(separator: "、"))"
            handled = true
        }
        return handled
    }

    private func appendComposerAttachments(_ attachments: [AIAssistantAttachment]) {
        var added: [AIAssistantAttachment] = []
        for attachment in attachments {
            if composerAttachments.contains(where: { $0.filename == attachment.filename }) == false {
                composerAttachments.append(attachment)
                added.append(attachment)
            }
        }
        if added.isEmpty == false {
            refreshComposerControls()
        }
    }

    private func imageAttachments(from pasteboard: NSPasteboard) -> [AIAssistantAttachment] {
        var attachments: [AIAssistantAttachment] = []
        if let image = NSImage(pasteboard: pasteboard),
           let data = Self.pngData(from: image),
           data.isEmpty == false {
            attachments.append(
                AIAssistantAttachment(
                    filename: "pasted-image-\(Self.attachmentTimestamp()).png",
                    mimeType: "image/png",
                    byteCount: data.count,
                    base64Data: data.count <= Self.maxAttachmentBytes ? data.base64EncodedString() : nil
                )
            )
        }
        return attachments
    }

    private func makeComposerAttachment(from url: URL) throws -> AIAssistantAttachment {
        let data = try Data(contentsOf: url)
        let mimeType = Self.mimeType(for: url)
        let isImage = mimeType.lowercased().hasPrefix("image/")
        let base64Data = isImage && data.count <= Self.maxAttachmentBytes
            ? data.base64EncodedString()
            : nil
        let textPreview = isImage ? nil : Self.textPreview(from: data)
        return AIAssistantAttachment(
            filename: url.lastPathComponent,
            mimeType: mimeType,
            byteCount: data.count,
            base64Data: base64Data,
            textPreview: textPreview,
            localFileURL: url
        )
    }

    private func clearComposerSendOptions() {
        guard composerAttachments.isEmpty == false || planModeEnabled || goalModeEnabled else {
            return
        }
        composerAttachments = []
        planModeEnabled = false
        goalModeEnabled = false
        refreshComposerControls()
    }

    private func showComposerAddPicker(from button: NSButton) {
        let picker = makeComposerAddPicker()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = picker
        popover.contentSize = picker.preferredContentSize
        composerAddPickerViewController = picker
        composerAddPickerPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func makeComposerAddPicker() -> AIComposerAddPickerViewController {
        let picker = AIComposerAddPickerViewController(
            planModeEnabled: planModeEnabled,
            goalModeEnabled: goalModeEnabled,
            currentFileEnabled: currentRemoteFileAttachmentAvailable()
        )
        picker.onAddFiles = { [weak self] in
            self?.addSelectedComposerAttachments()
        }
        picker.onAddCurrentFile = { [weak self] in
            self?.addCurrentRemoteFileContext()
        }
        picker.onTogglePlan = { [weak self] in
            self?.planModeEnabled.toggle()
            self?.refreshComposerControls()
            self?.refreshComposerAddPicker()
        }
        picker.onToggleGoal = { [weak self] in
            self?.goalModeEnabled.toggle()
            self?.refreshComposerControls()
            self?.refreshComposerAddPicker()
        }
        return picker
    }

    private func refreshComposerAddPicker() {
        composerAddPickerViewController?.update(
            planModeEnabled: planModeEnabled,
            goalModeEnabled: goalModeEnabled,
            currentFileEnabled: currentRemoteFileAttachmentAvailable()
        )
    }

    private func currentRemoteFileAttachmentAvailable() -> Bool {
        guard currentRemoteFileAttachmentProvider != nil else {
            return false
        }
        return currentRemoteFileAttachmentAvailabilityProvider?() ?? true
    }

    private func selectComposerModel(_ selection: AIModelSelection?) {
        guard hasActiveAIActivity == false, capturedTaskModelSelection == nil else {
            return
        }
        let effectiveSelection = selection?.providerID == BuiltInAIProvider.stacioRulesID
            ? nil
            : selection
        modelSelectionSession.select(effectiveSelection)
        refreshComposerControls()
        _ = refreshContextSummary()
    }

    private func selectComposerPermission(_ policy: AgentConfirmationPolicyPreference) {
        settingsStore.update { settings in
            settings.agentConfirmationPolicy = policy
        }
        refreshComposerControls()
        refreshComposerPermissionPicker()
    }

    private func selectComposerReasoning(_ effort: AIReasoningEffortPreference) {
        let resolved = resolvedComposerModel()
        guard let selection = resolved.selection,
              let model = resolved.model,
              model.capabilities.supportedReasoningEfforts?.contains(effort) ?? true
        else {
            return
        }
        do {
            try AIProviderConfigurationCoordinator.withSharedTransaction {
                var envelope = try settingsStore.loadAIProviderSettings()
                guard let providerIndex = envelope.aiProviders.firstIndex(where: {
                    $0.id == selection.providerID
                }),
                      let modelIndex = envelope.aiProviders[providerIndex].models.firstIndex(where: {
                          $0.id == selection.modelID
                      })
                else {
                    return
                }
                envelope.aiProviders[providerIndex].models[modelIndex].capabilities.reasoningEffort = effort
                envelope.aiProviders[providerIndex].models[modelIndex].capabilities.reasoningEffortSource = .manual
                try settingsStore.saveAIProviderSettings(envelope)
            }
        } catch {
            statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
        refreshComposerControls()
        _ = refreshContextSummary()
    }

    private func showComposerModelPicker(from button: NSButton) {
        let picker = makeComposerModelPicker()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = picker
        popover.contentSize = picker.preferredContentSize
        composerModelPickerViewController = picker
        composerModelPickerPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func showComposerPermissionPicker(from button: NSButton) {
        let picker = makeComposerPermissionPicker()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = picker
        popover.contentSize = picker.preferredContentSize
        composerPermissionPickerViewController = picker
        composerPermissionPickerPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func refreshComposerPermissionPicker() {
        composerPermissionPickerViewController?.update(state: composerPermissionPickerState())
    }

    private func makeComposerPermissionPicker() -> AIComposerPermissionPickerViewController {
        let picker = AIComposerPermissionPickerViewController(state: composerPermissionPickerState())
        picker.onSelectPolicy = { [weak self] policy in
            self?.selectComposerPermission(policy)
            self?.composerPermissionPickerPopover?.performClose(nil)
        }
        return picker
    }

    private func composerPermissionPickerState() -> AIComposerPermissionPickerState {
        AIComposerPermissionPickerState(
            currentPolicy: settingsStore.snapshot().agentConfirmationPolicy,
            items: composerPermissionItems()
        )
    }

    private func refreshComposerModelPicker() {
        guard let picker = composerModelPickerViewController else { return }
        picker.update(state: composerModelPickerState())
        composerModelPickerPopover?.contentSize = picker.preferredContentSize
    }

    private func makeComposerModelPicker() -> AIComposerModelPickerViewController {
        let picker = AIComposerModelPickerViewController(state: composerModelPickerState())
        picker.onSelectModel = { [weak self] selection in
            self?.selectComposerModel(selection)
            self?.refreshComposerModelPicker()
        }
        picker.onSelectReasoning = { [weak self] effort in
            self?.selectComposerReasoning(effort)
            self?.refreshComposerModelPicker()
        }
        return picker
    }

    private func composerModelPickerState() -> AIComposerModelPickerState {
        refreshContextUsageRing()
        let resolved = resolvedComposerModel()
        let temporarySelection = modelSelectionSession.snapshot()
        return AIComposerModelPickerState(
            providerTitle: resolved.providerTitle,
            currentSelection: temporarySelection,
            specialOptions: [
                AIComposerModelPickerSpecialOption(
                    title: "跟随全局默认",
                    selection: nil,
                    toolTip: "使用设置中的默认供应商和模型",
                    accessibilityIdentifier: "Stacio.AI.composer.modelPicker.option.globalDefault"
                )
            ],
            groups: composerModelGroups(),
            reasoningItems: resolved.model.map { reasoningEffortItems(for: $0) } ?? [],
            currentReasoning: resolved.model?.capabilities.effectiveReasoningEffort ?? .minimal,
            contextFraction: contextUsageFraction,
            contextLabel: contextUsageLabel
        )
    }

    private func refreshContextUsageRing(for context: AITerminalContext?) {
        let usage = currentContextUsage(for: context)
        contextUsageFraction = usage.fraction
        contextUsageLabel = usage.label
        contextUsageRing.fraction = usage.fraction
        contextUsageRing.toolTip = usage.label
        contextUsageRing.setAccessibilityLabel(usage.label)
        contextUsageRing.isHidden = surfaceMode == .localAgent
    }

    private func refreshContextUsageRing() {
        refreshContextUsageRing(for: resolvedTargetContext())
    }

    private func currentContextUsage(for context: AITerminalContext?) -> (fraction: Double, label: String) {
        let settings = settingsStore.snapshot()
        let selection = modelSelectionSession.snapshot()
        let limit = max(
            AIAssistantCoordinator.effectiveContextCharacterLimit(
                settings: settings,
                requestedSelection: selection
            ),
            1
        )
        guard let context else {
            return (0, "上下文 0%")
        }
        let effectiveTranscript = AIAssistantCoordinator.effectiveRecentTranscript(
            for: context,
            settings: settings,
            requestedSelection: selection
        )
        let used = effectiveTranscript.count
        let fraction = min(max(Double(used) / Double(limit), 0), 1)
        let percent = Int((fraction * 100).rounded())
        let label = context.recentTranscript.count > used
            ? "上下文 \(percent)% · 已自动压缩"
            : "上下文 \(percent)%"
        return (fraction, label)
    }

    private static func pickAttachmentURLs() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择发送给 AI 的照片或文件"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    private static func mimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "txt", "log":
            return "text/plain"
        case "md", "markdown":
            return "text/markdown"
        case "json":
            return "application/json"
        case "csv":
            return "text/csv"
        case "xml":
            return "application/xml"
        case "html", "htm":
            return "text/html"
        case "yaml", "yml":
            return "application/yaml"
        case "swift":
            return "text/x-swift"
        case "sh", "bash", "zsh":
            return "text/x-shellscript"
        case "py":
            return "text/x-python"
        case "js":
            return "text/javascript"
        case "ts":
            return "text/typescript"
        case "css":
            return "text/css"
        default:
            return "application/octet-stream"
        }
    }

    private static func textPreview(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            return nil
        }
        let cleaned = text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else {
            return nil
        }
        return String(cleaned.prefix(maxAttachmentTextPreviewCharacters))
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func attachmentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func appendTraceEvents(_ events: [AgentTraceEvent], runtimeTitle: String? = nil) {
        for event in events {
            appendTraceEvent(event, runtimeTitle: runtimeTitle, allEvents: events)
        }
    }

    private func observeTerminalTraceNotifications() {
        if traceObserver == nil {
            traceObserver = NotificationCenter.default.addObserver(
                forName: TerminalAgentTraceNotification.didAppend,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleTerminalTraceNotification(notification)
            }
        }
        if terminalTaskControlObserver == nil {
            terminalTaskControlObserver = NotificationCenter.default.addObserver(
                forName: TerminalAgentTaskControlNotification.didRequest,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleTerminalTaskControlNotification(notification)
            }
        }
    }

    private func handleTerminalTraceNotification(_ notification: Notification) {
        guard let payload = TerminalAgentTraceNotification.payload(from: notification),
              shouldDisplayTrace(forRuntimeID: payload.runtimeID)
        else {
            return
        }
        let actorKind = payload.event.metadata?["actorKind"].flatMap(AgentActorKind.init(rawValue:))
        if let actorKind {
            traceActorKindsByRequest[
                AgentTraceOwnershipKey(runtimeID: payload.runtimeID, requestID: payload.event.requestID)
            ] = actorKind
        }
        guard actorKind == .builtInAI else { return }
        appendTraceEvent(payload.event, runtimeTitle: payload.title, allEvents: nil)
        updateStatusFromTrace(payload.event)
    }

    private func handleTerminalTaskControlNotification(_ notification: Notification) {
        guard let payload = TerminalAgentTaskControlNotification.payload(from: notification) else {
            return
        }
        let ownershipKey = AgentTraceOwnershipKey(
            runtimeID: payload.runtimeID,
            requestID: payload.requestID
        )
        guard shouldDisplayTrace(forRuntimeID: payload.runtimeID),
              traceActorKindsByRequest[ownershipKey] == .builtInAI
        else {
            performTerminalTaskControlWithoutTranscript(payload)
            return
        }
        activeTaskRequestID = payload.requestID
        switch payload.action {
        case .pause:
            taskPausePressed(nil)
        case .cancel:
            taskCancelPressed(nil)
        case .takeOver:
            taskTakeOverPressed(nil)
        case .confirmComplete:
            taskConfirmCompletePressed(nil)
        }
    }

    private func performTerminalTaskControlWithoutTranscript(
        _ payload: (
            runtimeID: String,
            requestID: String,
            action: TerminalAgentTaskControlAction
        )
    ) {
        switch payload.action {
        case .pause:
            _ = coordinator.pauseTask(requestID: payload.requestID)
        case .cancel:
            _ = coordinator.cancelTask(requestID: payload.requestID)
        case .takeOver:
            _ = coordinator.takeOverTask(requestID: payload.requestID)
        case .confirmComplete:
            _ = coordinator.confirmTaskComplete(requestID: payload.requestID)
        }
    }

    private func shouldDisplayTrace(forRuntimeID runtimeID: String) -> Bool {
        if selectedRuntimeIDs.isEmpty == false {
            return selectedRuntimeIDs.contains(runtimeID)
        }
        if let selectedRuntimeID {
            return selectedRuntimeID == runtimeID
        }
        return contextProvider(nil)?.runtimeID == runtimeID
    }

    private func registerTaskControlRequestIDs(_ events: [AgentTraceEvent]) {
        let requestIDs = Array(Set(events.map(\.requestID))).sorted()
        guard requestIDs.isEmpty == false else { return }
        for requestID in requestIDs {
            taskControlRequestIDsByRequestID[requestID] = requestIDs
        }
    }

    private func taskControlRequestIDs(for requestID: String) -> [String] {
        taskControlRequestIDsByRequestID[requestID] ?? [requestID]
    }

    private func performTaskControl(
        for requestID: String,
        action: (String) -> AgentTraceEvent?
    ) -> [AgentTraceEvent] {
        taskControlRequestIDs(for: requestID).compactMap { targetRequestID in
            guard let event = action(targetRequestID) else { return nil }
            appendTraceEvent(
                event,
                runtimeTitle: traceRuntimeTitlesByRequestID[targetRequestID],
                allEvents: nil
            )
            updateStatusFromTrace(event)
            return event
        }
    }

    private func appendTraceEvent(
        _ event: AgentTraceEvent,
        runtimeTitle: String?,
        allEvents: [AgentTraceEvent]?
    ) {
        let key = traceEntryKey(for: event)
        guard appendedTraceEntryKeys.insert(key).inserted else {
            return
        }
        var events = traceEventsByRequestID[event.requestID] ?? []
        if events.contains(event) == false {
            events.append(event)
            if events.count > 20 {
                events.removeFirst(events.count - 20)
            }
            traceEventsByRequestID[event.requestID] = events
        }
        if let runtimeTitle, runtimeTitle.isEmpty == false {
            traceRuntimeTitlesByRequestID[event.requestID] = runtimeTitle
        }
        appendVirtualTerminalTranscript(for: event, runtimeTitle: runtimeTitle)
        renderTaskControls(for: event.requestID)
        if isTerminalTraceState(event.state) {
            collapseProcessEntries(for: event.requestID)
            finishManualProcessGroupIfNeeded(for: event.requestID)
        }
        appendPendingAssistantConclusionIfReady(for: event)
    }

    private func appendVirtualTerminalTranscript(for event: AgentTraceEvent, runtimeTitle: String?) {
        let target = runtimeTitle
            ?? event.metadata?["targetTitle"]
            ?? traceRuntimeTitlesByRequestID[event.requestID]
        let command = event.redactedCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch event.state {
        case .running, .waitingForOutput:
            if let summary = terminalOutputSummary(for: event) {
                upsertTerminalBlock(
                    requestID: event.requestID,
                    target: target,
                    command: command,
                    output: summary,
                    persistHistory: false
                )
                return
            }
            upsertTerminalBlock(
                requestID: event.requestID,
                target: target,
                command: command,
                output: "",
                persistHistory: false
            )
        case .completed:
            let summary = terminalOutputSummary(for: event)
                ?? completedOutputFallback(for: event)
            guard let summary else { return }
            upsertTerminalBlock(
                requestID: event.requestID,
                target: target,
                command: command,
                output: summary,
                persistHistory: true
            )
        case .failed:
            guard appendedExecutionResultRequestIDs.insert(event.requestID).inserted else { return }
            appendSystemTranscript(
                "本次执行失败：\(event.message)",
                isProcessEntry: activeProcessGroupID != nil
            )
        case .queued, .awaitingApproval, .approved, .typing, .paused, .cancelled, .takenOver:
            return
        }
    }

    private func upsertTerminalBlock(
        requestID: String,
        target: String?,
        command: String?,
        output: String,
        persistHistory: Bool
    ) {
        let block = terminalBlockText(target: target, command: command, output: output)
        terminalBlocksByRequestID[requestID] = block
        if let index = transcriptEntries.firstIndex(where: { $0.role == .terminal && $0.requestID == requestID }) {
            transcriptEntries[index].text = block
            if persistHistory {
                persistConversationHistory(role: .terminal, content: block, requestID: requestID)
            }
            renderTranscriptEntries()
        } else {
            appendTranscript(.terminal, block, requestID: requestID, persistHistory: persistHistory)
        }
    }

    private func terminalBlockText(target: String?, command: String?, output: String) -> String {
        var lines = ["终端 · \(target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? target! : "当前会话")"]
        if let command,
           command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("$ \(command)")
        }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty == false {
            lines.append(trimmedOutput)
        }
        return lines.joined(separator: "\n")
    }

    private func completedOutputFallback(for event: AgentTraceEvent) -> String? {
        let prefixes = [
            "AI 独立任务已完成：",
            "本次命令已完成："
        ]
        for prefix in prefixes where event.message.hasPrefix(prefix) {
            let output = String(event.message.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty == false {
                return output
            }
        }
        return nil
    }

    private func terminalOutputSummary(for event: AgentTraceEvent) -> String? {
        if let summary = event.metadata?["terminalOutputSummary"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           summary.isEmpty == false {
            return summary
        }
        let prefixes = [
            "AI 独立任务已完成：",
            "AI 独立任务输出："
        ]
        for prefix in prefixes where event.message.hasPrefix(prefix) {
            let summary = String(event.message.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty == false {
                return summary
            }
        }
        return nil
    }

    private func isTerminalTraceState(_ state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .paused, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            return false
        }
    }

    private func storePendingAssistantConclusion(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if let requestID = currentProposalTaskRequestID {
            pendingAssistantConclusionsByRequestID[requestID] = trimmed
        } else {
            appendTranscript(.assistant, trimmed)
        }
    }

    private func appendPendingAssistantConclusionIfReady(for event: AgentTraceEvent) {
        guard isTerminalTraceState(event.state),
              let conclusion = pendingAssistantConclusionsByRequestID.removeValue(forKey: event.requestID)
        else {
            return
        }
        messageLabel.stringValue = ""
        appendTranscript(.assistant, conclusion)
        statusLabel.stringValue = ""
    }

    private func traceEntryKey(for event: AgentTraceEvent) -> String {
        let metadataKey = event.metadata?
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{1E}") ?? ""
        return [
            event.requestID,
            event.state.rawValue,
            event.message,
            event.redactedCommand ?? "",
            metadataKey
        ].joined(separator: "\u{1F}")
    }

    private func updateStatusFromTrace(_ event: AgentTraceEvent) {
        switch event.state {
        case .completed:
            statusLabel.stringValue = event.message
            isExecuting = false
            updateCommandButtonState()
            refreshHeaderStatusForCurrentContext()
        case .failed:
            statusLabel.stringValue = event.message
            isExecuting = false
            updateCommandButtonState()
            refreshHeaderStatusForCurrentContext()
        case .cancelled:
            statusLabel.stringValue = event.message
            isExecuting = false
            updateCommandButtonState()
            refreshHeaderStatusForCurrentContext()
        case .paused, .takenOver:
            statusLabel.stringValue = event.message
            isExecuting = false
            updateCommandButtonState()
            refreshHeaderStatusForCurrentContext()
        case .running, .waitingForOutput:
            statusLabel.stringValue = event.message
            isExecuting = true
            refreshHeaderStatusForCurrentContext()
        case .queued, .awaitingApproval, .approved, .typing:
            break
        }
    }

    private func label(for risk: AgentActionRisk) -> String {
        switch risk {
        case .readOnly: return L10n.AI.commandRiskReadOnly
        case .write: return L10n.AI.commandRiskWrite
        case .network: return L10n.AI.commandRiskNetwork
        case .destructive: return L10n.AI.commandRiskDestructive
        }
    }

    private func renderTaskControls(for requestID: String) {
        let events = traceEventsByRequestID[requestID] ?? []
        guard events.isEmpty == false else {
            taskControlContainer.isHidden = true
            taskControlText = ""
            activeTaskRequestID = nil
            return
        }
        activeTaskRequestID = requestID
        let controlStatus = taskControlStatusesByRequestID[requestID]
        updateTaskControls(for: events)
        let text = taskControlText(for: events, controlStatus: controlStatus)
        taskControlLabel.stringValue = text
        taskControlText = text
        taskControlContainer.isHidden = pendingTaskContinuation == nil
    }

    private func taskControlText(for events: [AgentTraceEvent], controlStatus: String?) -> String {
        if let controlStatus,
           controlStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return controlStatus
        }
        guard let latestState = events.last?.state else { return "" }
        switch latestState {
        case .running:
            return "命令已交给目标终端。必要时可以暂停、取消、接管或确认完成。"
        case .waitingForOutput:
            return "命令仍在等待输出。长驻或交互命令可以由你手动停止后点“\(L10n.AI.confirmTaskComplete)”。"
        case .paused:
            return "AI 后续自动动作已暂停，当前命令仍以目标终端输出为准。"
        case .cancelled:
            return events.last?.message ?? "任务已取消。"
        case .takenOver:
            return events.last?.message ?? "已切换为人工接管。"
        case .queued, .awaitingApproval, .approved, .typing, .completed, .failed:
            return ""
        }
    }

    private func updateTaskControls(for events: [AgentTraceEvent]) {
        let latestState = events.last?.state
        let isActive: Bool
        if isExecuting == false && activeOrchestrator == nil {
            isActive = false
        } else {
            switch latestState {
            case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
                isActive = true
            case .completed, .failed, .cancelled, .paused, .takenOver, nil:
                isActive = false
            }
        }
        taskPauseButton.isEnabled = isActive
        taskCancelButton.isEnabled = isActive
        taskTakeOverButton.isEnabled = isActive
        taskConfirmCompleteButton.isEnabled = isActive && latestState == .waitingForOutput
        taskContinueButton.isHidden = true
        taskContinueButton.isEnabled = false
        taskControlDismissButton.isEnabled = latestState != nil
    }

    private func appendTranscript(
        _ role: AITranscriptRole,
        _ text: String,
        requestID: String? = nil,
        persistHistory: Bool = true,
        isProcessEntry: Bool? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let processEntry = isProcessEntry ?? role.isProcessRole
        let entry = AITranscriptEntry(
            role: role,
            text: trimmed,
            requestID: requestID,
            isProcessEntry: processEntry,
            processGroupID: processEntry ? activeProcessGroupID : nil,
            isCollapsed: false
        )
        transcriptEntries.append(entry)
        messageLabel.isHidden = true
        if persistHistory,
           let historyRole = role.persistedHistoryRole {
            persistConversationHistory(role: historyRole, content: trimmed, requestID: requestID)
        }
        renderTranscriptEntries()
    }

    private func appendSystemTranscript(
        _ text: String,
        isProcessEntry: Bool = false
    ) {
        appendTranscript(
            .system,
            text,
            persistHistory: false,
            isProcessEntry: isProcessEntry
        )
    }

    private func appendAssistantStreamingDelta(
        _ delta: String,
        isProcessEntry: Bool = false
    ) {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDelta.isEmpty == false || delta.isEmpty == false else { return }
        if let index = activeStreamingAssistantIndex,
           transcriptEntries.indices.contains(index),
           transcriptEntries[index].role == .assistant {
            transcriptEntries[index].text += delta
            transcriptEntries[index].isProcessEntry = transcriptEntries[index].isProcessEntry || isProcessEntry
            if isProcessEntry {
                transcriptEntries[index].processGroupID = activeProcessGroupID
            }
        } else {
            let entry = AITranscriptEntry(
                role: .assistant,
                text: delta,
                requestID: nil,
                isProcessEntry: isProcessEntry,
                processGroupID: isProcessEntry ? activeProcessGroupID : nil
            )
            transcriptEntries.append(entry)
            activeStreamingAssistantIndex = transcriptEntries.count - 1
            messageLabel.isHidden = true
        }
        renderTranscriptEntries()
    }

    @discardableResult
    private func collapseActiveProcessEntries() -> Bool {
        guard let activeProcessGroupID else { return false }
        var didChange = false
        for index in transcriptEntries.indices where transcriptEntries[index].processGroupID == activeProcessGroupID {
            guard transcriptEntries[index].isProcessEntry,
                  transcriptEntries[index].isCollapsed == false
            else { continue }
            transcriptEntries[index].isCollapsed = true
            didChange = true
        }
        if didChange {
            renderTranscriptEntries()
        }
        return didChange
    }

    private func discardActiveStreamingProcessDraft() {
        guard let index = activeStreamingAssistantIndex,
              transcriptEntries.indices.contains(index),
              transcriptEntries[index].role == .assistant,
              transcriptEntries[index].isProcessEntry
        else {
            activeStreamingAssistantIndex = nil
            return
        }
        transcriptEntries.remove(at: index)
        activeStreamingAssistantIndex = nil
        renderTranscriptEntries()
    }

    private func finishActiveProcessGroup(collapse: Bool) {
        var didCompleteGroup = false
        if let activeProcessGroupID {
            processGroupTimings[activeProcessGroupID]?.completedAt = Date()
            didCompleteGroup = true
        }
        let didCollapseEntries = collapse ? collapseActiveProcessEntries() : false
        if didCompleteGroup && didCollapseEntries == false {
            renderTranscriptEntries()
        }
        activeProcessGroupID = nil
    }

    private func finishManualProcessGroupIfNeeded(for requestID: String) {
        guard let processGroupID = manualProcessGroupIDsByRequestID.removeValue(forKey: requestID) else {
            return
        }
        processGroupTimings[processGroupID]?.completedAt = Date()
        for index in transcriptEntries.indices where transcriptEntries[index].processGroupID == processGroupID {
            guard transcriptEntries[index].isProcessEntry else { continue }
            transcriptEntries[index].isCollapsed = true
        }
        if activeProcessGroupID == processGroupID {
            activeProcessGroupID = nil
        }
        renderTranscriptEntries()
    }

    private func collapseProcessEntries(for requestID: String) {
        var didChange = false
        for index in transcriptEntries.indices where transcriptEntries[index].requestID == requestID {
            guard transcriptEntries[index].isProcessEntry,
                  transcriptEntries[index].isCollapsed == false
            else { continue }
            transcriptEntries[index].isCollapsed = true
            didChange = true
        }
        if didChange {
            renderTranscriptEntries()
        }
    }

    private func finalizeAssistantStreamingText(
        _ text: String,
        persistHistory: Bool,
        isProcessEntry: Bool = false
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            activeStreamingAssistantIndex = nil
            return
        }
        if let index = activeStreamingAssistantIndex,
           transcriptEntries.indices.contains(index),
           transcriptEntries[index].role == .assistant {
            transcriptEntries[index].text = trimmed
            transcriptEntries[index].isProcessEntry = transcriptEntries[index].isProcessEntry || isProcessEntry
            if isProcessEntry {
                transcriptEntries[index].processGroupID = activeProcessGroupID
            }
            if persistHistory {
                persistConversationHistory(
                    role: isProcessEntry ? .step : .assistant,
                    content: trimmed,
                    requestID: nil
                )
            }
            renderTranscriptEntries()
        } else {
            appendTranscript(
                .assistant,
                trimmed,
                persistHistory: persistHistory && isProcessEntry == false,
                isProcessEntry: isProcessEntry
            )
            if persistHistory && isProcessEntry {
                persistConversationHistory(role: .step, content: trimmed, requestID: nil)
            }
        }
        activeStreamingAssistantIndex = nil
    }

    private func persistConversationHistory(
        role: AIConversationHistoryRole,
        content: String,
        requestID: String?
    ) {
        guard let conversationHistoryStore,
              let context = resolvedTargetContext()
        else {
            return
        }
        do {
            _ = try conversationHistoryStore.appendConversationHistoryItem(
                runtimeID: CoreBridgeAIAssistantConversationHistoryStore.threadStorageID(
                    runtimeID: context.historyScopeID,
                    threadID: activeConversationIDs[context.historyScopeID] ?? "legacy"
                ),
                role: role,
                content: content,
                requestID: requestID
            )
            loadedConversationHistoryRuntimeID = nil
        } catch {
            return
        }
    }

    private func renderTranscriptEntries() {
        transcriptStack.arrangedSubviews.forEach { view in
            transcriptStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var renderedProcessGroupIDs: Set<UUID> = []
        for entry in transcriptEntries {
            if entry.isProcessEntry, let processGroupID = entry.processGroupID {
                guard renderedProcessGroupIDs.insert(processGroupID).inserted else { continue }
                let groupedEntries = transcriptEntries.filter {
                    $0.isProcessEntry && $0.processGroupID == processGroupID
                }
                let timing = processGroupTimings[processGroupID]
                let processView = AITranscriptProcessGroupView(
                    entries: groupedEntries,
                    elapsedText: processGroupElapsedText(timing: timing, entries: groupedEntries),
                    onToggle: { [weak self] in
                        self?.toggleProcessGroup(processGroupID)
                    }
                )
                transcriptStack.addArrangedSubview(processView)
                processView.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
                continue
            }
            let bubble = makeTranscriptBubble(for: entry)
            transcriptStack.addArrangedSubview(bubble)
            bubble.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
        }
        scrollTranscriptToBottom()
    }

    private func toggleProcessGroup(_ processGroupID: UUID) {
        let matchingIndices = transcriptEntries.indices.filter {
            transcriptEntries[$0].isProcessEntry
                && transcriptEntries[$0].processGroupID == processGroupID
        }
        guard matchingIndices.isEmpty == false else { return }
        let shouldExpand = matchingIndices.allSatisfy { transcriptEntries[$0].isCollapsed }
        matchingIndices.forEach { transcriptEntries[$0].isCollapsed = !shouldExpand }
        renderTranscriptEntries()
    }

    private func processGroupElapsedText(
        timing: AIProcessGroupTiming?,
        entries: [AITranscriptEntry]
    ) -> String {
        let startedAt = timing?.startedAt ?? entries.map(\.createdAt).min() ?? Date()
        let endedAt = timing?.completedAt
        let elapsed = max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
        let totalSeconds = Int(elapsed.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let duration = minutes > 0 ? "\(minutes)分 \(seconds)秒" : "\(seconds)秒"
        return endedAt == nil ? "处理中 \(duration)" : "已处理 \(duration)"
    }

    private func makeTranscriptBubble(for entry: AITranscriptEntry) -> AITranscriptBubbleView {
        let bubble = AITranscriptBubbleView(
            entry: entry,
            onOpenLink: { [weak self] url in self?.openAssistantLink(url) },
            onToggle: { [weak self] in self?.toggleTranscriptEntry(entry) }
        )
        bubble.preferredTextWidth = max(80, conversationContainer.bounds.width)
        return bubble
    }

    private func openAssistantLink(_ url: URL) {
        switch AIAssistantLinkRouter.destination(for: url) {
        case .stacioBrowser:
            internalBrowserOpener(url)
        case .systemBrowser:
            externalBrowserOpener(url)
        }
    }

    private func toggleTranscriptEntry(_ entry: AITranscriptEntry) {
        guard let index = transcriptEntries.firstIndex(where: {
            $0.role == entry.role
                && $0.requestID == entry.requestID
                && $0.text == entry.text
                && $0.isProcessEntry == entry.isProcessEntry
        }) else { return }
        transcriptEntries[index].isCollapsed.toggle()
        renderTranscriptEntries()
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        emphasized: Bool = false
    ) {
        button.title = ""
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.wantsLayer = true
        button.layer?.cornerRadius = emphasized ? 16 : 7
        button.layer?.cornerCurve = .continuous
        let background = emphasized
            ? NSColor.controlAccentColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.86)
        StacioDesignSystem.setLayerBackgroundColor(button, color: background)
        button.contentTintColor = emphasized ? .white : .labelColor
    }

    private func configureComposerIconButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String
    ) {
        button.title = ""
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.76)
        )
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureComposerPillButton(
        _ button: NSButton,
        symbolName: String?,
        title: String
    ) {
        button.title = title
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = symbolName.map {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)
        } ?? nil
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 13
        button.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.58)
        )
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureTaskControlLabel(
        _ label: NSTextField,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.font = .systemFont(ofSize: 11, weight: weight)
        label.textColor = color
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureTaskControlButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.isEnabled = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    private func configureHorizontalContainment() {
        [
            conversationContainer,
            headerContainer,
            headerIconView,
            headerTitleLabel,
            headerStatusLabel,
            contextLabel,
            targetButton,
            surfaceModeSegmentedControl,
            messageLabel,
            localAgentContainer,
            localAgentHeaderStack,
            localAgentTitleLabel,
            localAgentPopUpButton,
            localAgentStatusLabel,
            localAgentTerminalHost,
            planWorkspaceContainer,
            planWorkspaceHeaderLabel,
            planWorkspaceBodyLabel,
            planWorkspaceControlsStack,
            planWorkspaceConfirmButton,
            planWorkspaceEditButton,
            planWorkspaceCancelButton,
            transcriptStack,
            taskControlContainer,
            taskControlLabel,
            taskControlButtonsStack,
            taskPauseButton,
            taskCancelButton,
            taskTakeOverButton,
            taskConfirmCompleteButton,
            taskContinueButton,
            taskControlDismissButton,
            taskHistoryContainer,
            taskHistoryHeaderLabel,
            taskHistoryBodyLabel,
            taskHistoryButtonsStack,
            commandCardsStack,
            composerAttachmentStack,
            composerContextLabel,
            composerToolbar,
            composerPermissionButton,
            composerModelButton,
            transcriptScrollView,
            transcriptContentStack,
            statusLabel,
            questionField
        ].forEach { view in
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
    }

    private func updateQuestionControlState() {
        let hasQuestion = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let canSubmit = surfaceMode != .assistant || hasConfiguredAssistantModel
        let isActive = hasActiveAIActivity
        askButton.isEnabled = isActive || (hasQuestion && canSubmit)
        askButton.image = NSImage(
            systemSymbolName: isActive ? "stop.fill" : "arrow.up",
            accessibilityDescription: isActive ? "停止当前 AI 请求" : L10n.AI.ask
        )
        askButton.setAccessibilityLabel(isActive ? "停止当前 AI 请求" : L10n.AI.ask)
        askButton.toolTip = isActive ? "停止当前 AI 请求" : L10n.AI.ask
        composerModelButton.isEnabled = hasActiveAIActivity == false && capturedTaskModelSelection == nil
    }

    private var hasActiveAIActivity: Bool {
        isAsking
            || isExecuting
            || activeAskCancellation != nil
            || activeOrchestrator != nil
            || activeAutonomousTask != nil
    }

    private func updateCommandButtonState() {
        commandCards.forEach { card in
            if card.proposal.state == .proposed {
                card.updateState(.proposed)
            }
        }
    }

    var askButtonEnabledForTesting: Bool {
        askButton.isEnabled
    }

    var executeButtonEnabledForTesting: Bool {
        commandCards.first != nil && isExecuting == false
    }

    var messageTextForTesting: String {
        messageLabel.stringValue
    }

    var statusTextForTesting: String {
        statusLabel.stringValue
    }

    var questionTextForTesting: String {
        questionField.stringValue
    }

    var transcriptTextForTesting: String {
        transcriptEntries.map(\.displayText).joined(separator: "\n")
    }

    var rawTranscriptTextForTesting: String {
        transcriptEntries.map(\.text).joined(separator: "\n")
    }

    var collapsedProcessEntryCountForTesting: Int {
        transcriptEntries.filter { $0.isProcessEntry && $0.isCollapsed }.count
    }

    var processGroupCountForTesting: Int {
        Set(transcriptEntries.compactMap { $0.isProcessEntry ? $0.processGroupID : nil }).count
    }

    var processGroupSummaryTextsForTesting: [String] {
        transcriptStack.arrangedSubviews.compactMap { view in
            (view as? AITranscriptProcessGroupView)?.summaryTextForTesting
        }
    }

    var processGroupDetailAttributedStringsForTesting: [NSAttributedString] {
        transcriptStack.arrangedSubviews.compactMap { view in
            (view as? AITranscriptProcessGroupView)?.detailAttributedStringForTesting
        }
    }

    var collapsedThinkingEntryCountForTesting: Int {
        transcriptEntries.filter { $0.role == .assistant && $0.isProcessEntry && $0.isCollapsed }.count
    }

    func expandFirstCollapsedProcessForTesting() {
        guard let index = transcriptEntries.firstIndex(where: { $0.isProcessEntry && $0.isCollapsed }) else {
            return
        }
        transcriptEntries[index].isCollapsed = false
        renderTranscriptEntries()
    }

    func expandAllProcessEntriesForTesting() {
        var didChange = false
        for index in transcriptEntries.indices where transcriptEntries[index].isProcessEntry {
            if transcriptEntries[index].isCollapsed {
                transcriptEntries[index].isCollapsed = false
                didChange = true
            }
        }
        if didChange {
            renderTranscriptEntries()
        }
    }

    var assistantTranscriptTextForTesting: String {
        transcriptEntries
            .filter { $0.role == .assistant }
            .map(\.displayText)
            .joined(separator: "\n")
    }

    var assistantAttributedStringsForTesting: [NSAttributedString] {
        transcriptStack.arrangedSubviews.compactMap { view in
            guard let bubble = view as? AITranscriptBubbleView,
                  bubble.isAssistantForTesting
            else {
                return nil
            }
            return bubble.attributedStringForTesting
        }
    }

    var assistantConclusionTextsForTesting: [String] {
        transcriptEntries
            .filter { $0.role == .assistant && $0.isProcessEntry == false }
            .map(\.text)
    }

    var systemTranscriptTextForTesting: String {
        transcriptEntries
            .filter { $0.role == .system }
            .map(\.displayText)
            .joined(separator: "\n")
    }

    var taskControlTextForTesting: String {
        taskControlText
    }

    var planTimelineTextForTesting: String {
        planWorkspaceText
    }

    var planConfirmEnabledForTesting: Bool {
        planWorkspaceConfirmButton.isEnabled
    }

    var planCancelEnabledForTesting: Bool {
        planWorkspaceCancelButton.isEnabled
    }

    func performPlanConfirmForTesting() {
        planConfirmPressed(nil)
    }

    var taskHistoryTextForTesting: String {
        taskHistoryText
    }

    var transcriptContentOrderForTesting: [String] {
        transcriptContentStack.arrangedSubviews.map { view in
            if view === messageLabel {
                return "message"
            }
            if view === planWorkspaceContainer {
                return "planWorkspace"
            }
            if view === taskControlContainer {
                return "taskControl"
            }
            if view === taskHistoryContainer {
                return "taskHistory"
            }
            if view === transcriptStack {
                return "transcript"
            }
            if view === statusLabel {
                return "status"
            }
            return "unknown"
        }
    }

    var composerAddMenuTitlesForTesting: [String] {
        composerAddMenu().items
            .filter { $0.isSeparatorItem == false }
            .map(\.title)
    }

    var localAgentToolTitlesForTesting: [String] {
        localAgentPopUpButton.itemArray.map(\.title)
    }

    var surfaceModeTitlesForTesting: [String] {
        (0..<surfaceModeSegmentedControl.segmentCount).map { index in
            surfaceModeSegmentedControl.label(forSegment: index) ?? ""
        }
    }

    var surfaceModeControlWidthForTesting: CGFloat {
        surfaceModeSegmentedControl.bounds.width
    }

    var surfaceModeSegmentWidthsForTesting: [CGFloat] {
        (0..<surfaceModeSegmentedControl.segmentCount).map {
            surfaceModeSegmentedControl.width(forSegment: $0)
        }
    }

    var activeSurfaceModeTitleForTesting: String {
        surfaceModeSegmentedControl.label(forSegment: surfaceModeSegmentedControl.selectedSegment) ?? ""
    }

    var localAgentStatusTextForTesting: String {
        localAgentStatusLabel.stringValue
    }

    var localAgentTerminalHostHiddenForTesting: Bool {
        localAgentTerminalHost.isHidden
    }

    var localAgentWorkspaceHiddenForTesting: Bool {
        localAgentContainer.isHidden
    }

    var assistantTranscriptHiddenForTesting: Bool {
        transcriptScrollView.isHidden
    }

    var composerHiddenForTesting: Bool {
        composer.isHidden
    }

    var commandCardsHiddenForTesting: Bool {
        commandCardsStack.isHidden
    }

    var taskHistoryHiddenForTesting: Bool {
        taskHistoryContainer.isHidden
    }

    func switchSurfaceModeForTesting(_ mode: String) {
        guard let index = surfaceModeTitlesForTesting.firstIndex(of: mode) else {
            return
        }
        surfaceModeSegmentedControl.selectedSegment = index
        surfaceModeChanged(surfaceModeSegmentedControl)
    }

    func startLocalAgentForTesting(_ tool: LocalAgentTool) {
        startLocalAgentSession(tool)
    }

    var composerAddPickerTitlesForTesting: [String] {
        makeComposerAddPicker().actionTitlesForTesting
    }

    var composerAddPickerPreferredSizeForTesting: NSSize {
        makeComposerAddPicker().preferredSizeForTesting
    }

    var composerAddPickerButtonHeightsForTesting: [CGFloat] {
        makeComposerAddPicker().actionButtonHeightsForTesting
    }

    var composerAddPickerCurrentFileEnabledForTesting: Bool {
        makeComposerAddPicker().currentFileEnabledForTesting
    }

    var composerModelTitleForTesting: String {
        composerModelButton.title
    }

    var composerModelPickerModelTitlesForTesting: [String] {
        makeComposerModelPicker().modelTitlesForTesting
    }

    var composerModelPickerGroupTitlesForTesting: [String] {
        makeComposerModelPicker().groupTitlesForTesting
    }

    var composerModelPickerSelectionsForTesting: [AIModelSelection] {
        makeComposerModelPicker().selectionsForTesting
    }

    var composerModelPickerReasoningTitlesForTesting: [String] {
        makeComposerModelPicker().reasoningTitlesForTesting
    }

    var composerModelPickerContextTextForTesting: String {
        makeComposerModelPicker().contextTextForTesting
    }

    var composerModelPickerPreferredSizeForTesting: NSSize {
        makeComposerModelPicker().preferredSizeForTesting
    }

    var composerModelMenuReasoningTitlesForTesting: [String] {
        composerModelMenu().items
            .prefix { $0.isSeparatorItem == false }
            .map(\.title)
    }

    var composerModelMenuModelTitlesForTesting: [String] {
        composerModelMenu().items.compactMap { item in
            (item.representedObject as? AIModelSelection)?.modelID
        }
    }

    var composerPermissionTitleForTesting: String {
        composerPermissionButton.title
    }

    var composerPermissionPickerTitlesForTesting: [String] {
        makeComposerPermissionPicker().policyTitlesForTesting
    }

    var composerPermissionPickerPreferredSizeForTesting: NSSize {
        makeComposerPermissionPicker().preferredSizeForTesting
    }

    var composerPermissionPickerButtonHeightsForTesting: [CGFloat] {
        makeComposerPermissionPicker().buttonHeightsForTesting
    }

    var composerContextTextForTesting: String {
        composerContextLabel.stringValue
    }

    var composerAttachmentCardCountForTesting: Int {
        composerAttachmentStack.arrangedSubviews.count
    }

    var composerAttachmentCardTitlesForTesting: [String] {
        composerAttachments.map(\.filename)
    }

    var composerAttachmentStackHiddenForTesting: Bool {
        composerAttachmentStack.isHidden
    }

    var composerPreviewWindowTitleForTesting: String? {
        composerPreviewWindow?.title
    }

    var contextUsageFractionForTesting: Double {
        refreshContextUsageRing()
        return contextUsageFraction
    }

    var contextUsageTextForTesting: String {
        refreshContextUsageRing()
        return contextUsageLabel
    }

    var taskPauseEnabledForTesting: Bool {
        taskPauseButton.isEnabled
    }

    var taskCancelEnabledForTesting: Bool {
        taskCancelButton.isEnabled
    }

    var generalStopEnabledForTesting: Bool {
        hasActiveAIActivity && askButton.isEnabled
    }

    var primaryActionAccessibilityLabelForTesting: String? {
        askButton.accessibilityLabel()
    }

    var taskTakeOverEnabledForTesting: Bool {
        taskTakeOverButton.isEnabled
    }

    var taskConfirmCompleteEnabledForTesting: Bool {
        taskConfirmCompleteButton.isEnabled
    }

    func performTaskConfirmCompleteForTesting() {
        taskConfirmCompletePressed(nil)
    }

    var messageLabelFrameForTesting: NSRect {
        messageLabel.frame
    }

    var messageLabelAlignmentRectForTesting: NSRect {
        messageLabel.alignmentRect(forFrame: messageLabel.frame)
    }

    var conversationContainerFrameForTesting: NSRect {
        conversationContainer.frame
    }

    var commandCardsStackFrameForTesting: NSRect {
        commandCardsStack.frame
    }

    var proposedCommandForTesting: String? {
        commandCards.first?.editedCommand
    }

    var contextTextForTesting: String {
        contextLabel.stringValue
    }

    var targetTitleForTesting: String {
        targetButton.title
    }

    var commandCardCountForTesting: Int {
        commandCards.count
    }

    func commandCardTextForTesting(at index: Int) -> String {
        guard commandCards.indices.contains(index) else {
            return ""
        }
        return commandCards[index].textForTesting
    }

    func selectTargetRuntimeForTesting(_ runtimeID: String) {
        selectedRuntimeID = runtimeID
        selectedRuntimeIDs = [runtimeID]
        refreshForCurrentContext()
    }

    func selectTargetRuntimesForTesting(_ runtimeIDs: [String]) {
        selectedRuntimeIDs = runtimeIDs
        selectedRuntimeID = runtimeIDs.first
        refreshForCurrentContext()
    }

    func selectComposerModelForTesting(_ selection: AIModelSelection?) {
        selectComposerModel(selection)
    }

    func selectComposerModelForTesting(_ model: String) {
        guard let selection = composerModelGroups()
            .flatMap(\.models)
            .first(where: { $0.modelID == model })
        else {
            return
        }
        selectComposerModel(selection)
    }

    func selectComposerPermissionForTesting(_ policy: AgentConfirmationPolicyPreference) {
        selectComposerPermission(policy)
    }

    func selectComposerReasoningForTesting(_ effort: AIReasoningEffortPreference) {
        selectComposerReasoning(effort)
    }

    func addFilesContextForTesting() {
        addSelectedComposerAttachments()
    }

    func addCurrentRemoteFileContextForTesting() {
        addCurrentRemoteFileContext()
    }

    func removeComposerAttachmentForTesting(at index: Int) {
        removeComposerAttachment(at: index)
    }

    func previewComposerAttachmentForTesting(at index: Int) {
        previewComposerAttachment(at: index)
    }

    @discardableResult
    func addComposerPasteboardForTesting(_ pasteboard: NSPasteboard) -> Bool {
        addComposerAttachments(from: pasteboard)
    }

    func togglePlanModeForTesting() {
        togglePlanModePressed(NSMenuItem())
    }

    func toggleGoalModeForTesting() {
        toggleGoalModePressed(NSMenuItem())
    }

    func editCommandCardForTesting(at index: Int, command: String) {
        guard commandCards.indices.contains(index) else {
            return
        }
        commandCards[index].setCommandForTesting(command)
    }

    func runCommandCardForTesting(at index: Int) {
        guard commandCards.indices.contains(index) else {
            return
        }
        commandCards[index].performRunForTesting()
    }

    func skipCommandCardForTesting(at index: Int) {
        guard commandCards.indices.contains(index) else {
            return
        }
        commandCards[index].performSkipForTesting()
    }

    func copyCommandCardForTesting(at index: Int) {
        guard commandCards.indices.contains(index) else {
            return
        }
        commandCards[index].performCopyForTesting()
    }

    func performTaskPauseForTesting() {
        taskPausePressed(nil)
    }

    func performTaskCancelForTesting() {
        taskCancelPressed(nil)
    }

    func performTaskTakeOverForTesting() {
        taskTakeOverPressed(nil)
    }

    func performGeneralStopForTesting() {
        stopButtonPressed(nil)
    }

    func performTaskControlDismissForTesting() {
        taskControlDismissPressed(nil)
    }

    func performCollapseForTesting() {
        collapseButtonPressed(nil)
    }

    func setQuestionForTesting(_ question: String) {
        prefillQuestion(question)
    }

    func performAskForTesting() {
        askButtonPressed(nil)
    }

    func createNewConversationForTesting() {
        newConversationButtonPressed(nil)
    }

    var conversationPickerTitlesForTesting: [String] {
        conversationPopUpButton.itemArray.map(\.title)
    }

    func submitQuestionFromFieldForTesting() {
        questionField.sendAction(questionField.action, to: questionField.target)
    }

    func performExecuteForTesting() {
        runCommandCardForTesting(at: 0)
    }

    func resetAssistantAttributedStringsForTesting() {
        for case let bubble as AITranscriptBubbleView in transcriptStack.arrangedSubviews {
            bubble.resetAssistantAttributedStringForTesting()
        }
    }

    private func scrollTranscriptToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            let contentHeight = self.transcriptDocumentView.bounds.height
            let visibleHeight = self.transcriptScrollView.contentView.bounds.height
            let y = max(0, contentHeight - visibleHeight)
            self.transcriptScrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            self.transcriptScrollView.reflectScrolledClipView(self.transcriptScrollView.contentView)
        }
    }
}

private final class AIAssistantFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class AIAssistantFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private struct AIProcessGroupTiming {
    let startedAt: Date
    var completedAt: Date?
}

private final class AITranscriptProcessGroupView: NSView {
    private let entries: [AITranscriptEntry]
    private let elapsedText: String
    private let onToggle: () -> Void
    private let disclosureButton = NSButton()
    private let detailLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    init(
        entries: [AITranscriptEntry],
        elapsedText: String,
        onToggle: @escaping () -> Void
    ) {
        self.entries = entries
        self.elapsedText = elapsedText
        self.onToggle = onToggle
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private var isCollapsed: Bool {
        entries.isEmpty == false && entries.allSatisfy(\.isCollapsed)
    }

    var summaryTextForTesting: String {
        disclosureButton.title
    }

    var detailAttributedStringForTesting: NSAttributedString {
        detailLabel.attributedStringValue
    }

    private func configure() {
        setAccessibilityIdentifier("Stacio.AI.transcript.processGroup")
        translatesAutoresizingMaskIntoConstraints = false

        disclosureButton.title = elapsedText
        disclosureButton.font = .systemFont(ofSize: 12, weight: .medium)
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: isCollapsed ? "展开处理过程" : "折叠处理过程"
        )
        disclosureButton.imagePosition = .imageTrailing
        disclosureButton.imageScaling = .scaleProportionallyDown
        disclosureButton.alignment = .left
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.target = self
        disclosureButton.action = #selector(togglePressed(_:))
        disclosureButton.toolTip = isCollapsed ? "展开思考和执行过程" : "折叠思考和执行过程"
        disclosureButton.setAccessibilityIdentifier("Stacio.AI.transcript.processDisclosure")
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        let detailMarkdown = entries.map(\.text).joined(separator: "\n\n")
        detailLabel.attributedStringValue = AIAssistantMarkdownRenderer.attributedString(
            from: detailMarkdown,
            baseFont: .systemFont(ofSize: 11),
            textColor: .secondaryLabelColor
        )
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.cell?.wraps = true
        detailLabel.cell?.usesSingleLineMode = false
        detailLabel.isSelectable = true
        detailLabel.isHidden = isCollapsed
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureButton)
        addSubview(detailLabel)
        addSubview(separator)
        let detailTop = detailLabel.topAnchor.constraint(equalTo: disclosureButton.bottomAnchor, constant: 8)
        detailTop.priority = isCollapsed ? .defaultLow : .required
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosureButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            disclosureButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailTop,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(
                equalTo: isCollapsed ? disclosureButton.bottomAnchor : detailLabel.bottomAnchor,
                constant: 8
            ),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @objc private func togglePressed(_ sender: Any?) {
        onToggle()
    }
}

enum AIAssistantLinkDestination: Equatable {
    case stacioBrowser
    case systemBrowser
}

enum AIAssistantLinkRouter {
    static func destination(for url: URL) -> AIAssistantLinkDestination {
        guard let host = url.host?.lowercased() else {
            return .systemBrowser
        }
        if host == "localhost" || IPv4Address(host) != nil || IPv6Address(host) != nil {
            return .stacioBrowser
        }
        return .systemBrowser
    }
}

private final class AITranscriptLinkLabel: NSTextField {
    var onOpenLink: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAsLabel()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAsLabel()
    }

    private func configureAsLabel() {
        isEditable = false
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
    }

    override func mouseDown(with event: NSEvent) {
        guard let url = link(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onOpenLink?(url)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        var containsLink = false
        attributedStringValue.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributedStringValue.length)
        ) { value, _, stop in
            if value != nil {
                containsLink = true
                stop.pointee = true
            }
        }
        guard containsLink else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func link(at point: NSPoint) -> URL? {
        guard attributedStringValue.length > 0 else { return nil }
        let textRect = cell?.drawingRect(forBounds: bounds) ?? bounds
        guard textRect.contains(point) else { return nil }
        let storage = NSTextStorage(attributedString: attributedStringValue)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: textRect.size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let localPoint = NSPoint(
            x: point.x - textRect.minX,
            y: isFlipped ? point.y - textRect.minY : textRect.maxY - point.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: localPoint, in: container)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
            .insetBy(dx: -2, dy: -2).contains(localPoint)
        else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let value = attributedStringValue.attribute(.link, at: characterIndex, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}

private final class AITranscriptBubbleView: NSView {
    private let entry: AITranscriptEntry
    private let onToggle: () -> Void
    private let bubbleView = NSView()
    private let label = AITranscriptLinkLabel(frame: .zero)
    private let disclosureButton = NSButton()
    private var renderedAssistantString: NSAttributedString?
    private var bubbleWidthConstraint: NSLayoutConstraint?
    private var lastAppliedBubbleWidth: CGFloat?
    private var lastAppliedLabelWidth: CGFloat?

    var preferredTextWidth: CGFloat = 240 {
        didSet {
            guard abs(preferredTextWidth - oldValue) > 0.5 else { return }
            updatePreferredWidth()
        }
    }

    init(
        entry: AITranscriptEntry,
        onOpenLink: @escaping (URL) -> Void = { _ in },
        onToggle: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.onToggle = onToggle
        super.init(frame: .zero)
        label.onOpenLink = onOpenLink
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isAssistantForTesting: Bool {
        entry.role == .assistant
    }

    var attributedStringForTesting: NSAttributedString {
        label.attributedStringValue
    }

    override func layout() {
        restoreAssistantFormattingIfNeeded()
        super.layout()
        updatePreferredWidth()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        restoreAssistantFormattingIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreAssistantFormattingIfNeeded()
    }

    private func configure() {
        setAccessibilityIdentifier(entry.bubbleAccessibilityIdentifier)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.wantsLayer = true
        bubbleView.layer?.cornerRadius = entry.bubbleCornerRadius
        bubbleView.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(bubbleView, color: entry.bubbleColor)
        StacioDesignSystem.setLayerBorderColor(bubbleView, color: entry.borderColor)
        bubbleView.layer?.borderWidth = entry.borderColor == nil ? 0 : 1

        label.stringValue = entry.displayText
        label.isSelectable = true
        label.allowsEditingTextAttributes = false
        label.setAccessibilityIdentifier(entry.textAccessibilityIdentifier)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.font = entry.font
        label.textColor = entry.textColor
        if entry.role == .assistant {
            let renderedString = AIAssistantMarkdownRenderer.attributedString(
                from: entry.displayText,
                baseFont: entry.font,
                textColor: entry.textColor
            )
            renderedAssistantString = renderedString
            label.attributedStringValue = renderedString
        }
        label.preferredMaxLayoutWidth = preferredTextWidth
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(bubbleView)
        bubbleView.addSubview(label)
        if entry.isProcessEntry {
            disclosureButton.title = ""
            disclosureButton.isBordered = false
            disclosureButton.image = NSImage(
                systemSymbolName: entry.isCollapsed ? "chevron.right" : "chevron.down",
                accessibilityDescription: entry.isCollapsed ? "展开过程" : "折叠过程"
            )
            disclosureButton.imageScaling = .scaleProportionallyDown
            disclosureButton.target = self
            disclosureButton.action = #selector(togglePressed(_:))
            disclosureButton.toolTip = entry.isCollapsed ? "展开思考和执行过程" : "折叠思考和执行过程"
            disclosureButton.setAccessibilityIdentifier("Stacio.AI.transcript.processDisclosure")
            disclosureButton.translatesAutoresizingMaskIntoConstraints = false
            bubbleView.addSubview(disclosureButton)
        }

        bubbleWidthConstraint = bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: preferredTextWidth)
        bubbleWidthConstraint?.isActive = true

        var constraints: [NSLayoutConstraint] = [
            bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: entry.verticalInset),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -entry.verticalInset),
            label.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: entry.horizontalPadding),
            label.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: entry.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -entry.verticalPadding)
        ]
        if entry.isProcessEntry {
            constraints += [
                disclosureButton.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -8),
                disclosureButton.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 7),
                disclosureButton.widthAnchor.constraint(equalToConstant: 18),
                disclosureButton.heightAnchor.constraint(equalToConstant: 18),
                label.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor, constant: -6)
            ]
        } else {
            constraints.append(
                label.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -entry.horizontalPadding)
            )
        }

        switch entry.role {
        case .user:
            constraints += [
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44)
            ]
        case .assistant:
            constraints += [
                bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)
            ]
        case .system:
            constraints += [
                bubbleView.centerXAnchor.constraint(equalTo: centerXAnchor),
                bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
                bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
            ]
        case .command, .terminal, .plan, .step:
            constraints += [
                bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func togglePressed(_ sender: Any?) {
        onToggle()
    }

    func resetAssistantAttributedStringForTesting() {
        guard let renderedAssistantString else { return }
        label.stringValue = renderedAssistantString.string
    }

    private func restoreAssistantFormattingIfNeeded() {
        guard let renderedAssistantString,
              label.attributedStringValue.isEqual(to: renderedAssistantString) == false
        else {
            return
        }
        label.attributedStringValue = renderedAssistantString
    }

    private func updatePreferredWidth() {
        let width = max(80, preferredTextWidth)
        let maxBubbleWidth: CGFloat
        switch entry.role {
        case .user:
            maxBubbleWidth = min(width * 0.86, 420)
        case .assistant:
            maxBubbleWidth = width
        case .system:
            maxBubbleWidth = min(width * 0.78, 360)
        case .command, .terminal, .plan, .step:
            maxBubbleWidth = width
        }
        let disclosureWidth: CGFloat = entry.isProcessEntry ? 28 : 0
        let labelWidth = max(40, maxBubbleWidth - entry.horizontalPadding * 2 - disclosureWidth)
        if lastAppliedBubbleWidth.map({ abs($0 - maxBubbleWidth) > 0.5 }) ?? true {
            bubbleWidthConstraint?.constant = maxBubbleWidth
            lastAppliedBubbleWidth = maxBubbleWidth
        }
        if lastAppliedLabelWidth.map({ abs($0 - labelWidth) > 0.5 }) ?? true {
            label.preferredMaxLayoutWidth = labelWidth
            lastAppliedLabelWidth = labelWidth
        }
    }
}

private final class AIComposerDropPasteView: NSView {
    var onPasteAttachments: ((NSPasteboard) -> Bool)?
    var onDropAttachments: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
        if isPaste, onPasteAttachments?(NSPasteboard.general) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropAttachments?(sender.draggingPasteboard) ?? false
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            || NSImage(pasteboard: pasteboard) != nil
    }
}

private final class AIComposerAttachmentCardView: NSView {
    var onDelete: ((Int) -> Void)?
    var onPreview: ((Int) -> Void)?

    private let attachment: AIAssistantAttachment
    private let index: Int
    private let previewButton = NSButton()
    private let deleteButton = NSButton()

    init(attachment: AIAssistantAttachment, index: Int) {
        self.attachment = attachment
        self.index = index
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        if attachment.isImage {
            StacioDesignSystem.setLayerBackgroundColor(self, color: .clear)
            setupImageCard()
        } else {
            StacioDesignSystem.setLayerBackgroundColor(
                self,
                color: NSColor.controlBackgroundColor.withAlphaComponent(0.62)
            )
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            setupFileCard()
        }
        setupDeleteButton()
    }

    private func setupImageCard() {
        previewButton.title = ""
        previewButton.isBordered = false
        previewButton.image = attachment.previewImage ?? NSImage(systemSymbolName: "photo", accessibilityDescription: attachment.filename)
        previewButton.imageScaling = .scaleAxesIndependently
        previewButton.target = self
        previewButton.action = #selector(previewPressed(_:))
        previewButton.toolTip = attachment.filename
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.wantsLayer = true
        previewButton.layer?.cornerRadius = 9
        previewButton.layer?.cornerCurve = .continuous
        previewButton.layer?.masksToBounds = true
        previewButton.setAccessibilityIdentifier("Stacio.AI.composer.attachment.\(index)")
        addSubview(previewButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 54),
            previewButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewButton.topAnchor.constraint(equalTo: topAnchor),
            previewButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupFileCard() {
        previewButton.title = ""
        previewButton.isBordered = false
        previewButton.target = self
        previewButton.action = #selector(previewPressed(_:))
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.setAccessibilityIdentifier("Stacio.AI.composer.attachment.\(index)")
        addSubview(previewButton)

        let iconBox = NSView()
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 9
        iconBox.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            iconBox,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        )
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: attachment.filename)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        iconBox.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: attachment.filename)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let typeLabel = NSTextField(labelWithString: attachment.displayKind)
        typeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.translatesAutoresizingMaskIntoConstraints = false

        [iconBox, titleLabel, typeLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 210),
            previewButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewButton.topAnchor.constraint(equalTo: topAnchor),
            previewButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 36),
            iconBox.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            typeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            typeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            typeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])
    }

    private func setupDeleteButton() {
        deleteButton.title = ""
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除附件")
        deleteButton.imageScaling = .scaleProportionallyDown
        deleteButton.contentTintColor = .labelColor
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed(_:))
        deleteButton.toolTip = "删除附件"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = 12
        deleteButton.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            deleteButton,
            color: NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        )
        deleteButton.setAccessibilityIdentifier("Stacio.AI.composer.attachment.delete.\(index)")
        addSubview(deleteButton)
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),
            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: -3),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3)
        ])
    }

    @objc
    private func deletePressed(_ sender: NSButton) {
        onDelete?(index)
    }

    @objc
    private func previewPressed(_ sender: NSButton) {
        onPreview?(index)
    }
}

private final class AIComposerAttachmentPreviewView: NSView {
    private let attachment: AIAssistantAttachment

    init(attachment: AIAssistantAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 620))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(self, color: NSColor.windowBackgroundColor)
        if attachment.isImage, let image = attachment.previewImage {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
                imageView.topAnchor.constraint(equalTo: topAnchor, constant: 54),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28)
            ])
        } else {
            let scrollView = NSScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            let text = NSTextView()
            text.isEditable = false
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.textColor = .labelColor
            text.string = attachment.textPreview ?? attachment.promptSummary
            scrollView.documentView = text
            addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
                scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 72),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28)
            ])
        }

        let title = NSTextField(labelWithString: attachment.filename)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 24)
        ])
    }
}

private extension AIAssistantAttachment {
    var previewImage: NSImage? {
        if let localFileURL,
           let image = NSImage(contentsOf: localFileURL) {
            return image
        }
        guard let base64Data,
              let data = Data(base64Encoded: base64Data)
        else {
            return nil
        }
        return NSImage(data: data)
    }

    var displayKind: String {
        let ext = (filename as NSString).pathExtension
        if ext.isEmpty == false {
            return ext.uppercased()
        }
        return mimeType
    }
}

private final class AIComposerAddPickerViewController: NSViewController {
    var onAddFiles: (() -> Void)?
    var onAddCurrentFile: (() -> Void)?
    var onTogglePlan: (() -> Void)?
    var onToggleGoal: (() -> Void)?

    private let stack = NSStackView()
    private let addFilesButton = NSButton()
    private let addCurrentFileButton = NSButton()
    private let planButton = NSButton()
    private let goalButton = NSButton()
    private var planModeEnabled: Bool
    private var goalModeEnabled: Bool
    private var currentFileEnabled: Bool
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 4
    private static let inset: CGFloat = 10

    init(planModeEnabled: Bool, goalModeEnabled: Bool, currentFileEnabled: Bool) {
        self.planModeEnabled = planModeEnabled
        self.goalModeEnabled = goalModeEnabled
        self.currentFileEnabled = currentFileEnabled
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 172, height: 132)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)

        stack.orientation = .vertical
        stack.spacing = Self.rowSpacing
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(
            addFilesButton,
            title: "添加照片和文件",
            symbolName: "paperclip",
            action: #selector(addFilesPressed(_:))
        )
        configureActionButton(
            addCurrentFileButton,
            title: "附加当前文件",
            symbolName: "doc.text.magnifyingglass",
            action: #selector(addCurrentFilePressed(_:))
        )
        configureActionButton(
            planButton,
            title: "计划模式",
            symbolName: "list.bullet.rectangle",
            action: #selector(planPressed(_:))
        )
        configureActionButton(
            goalButton,
            title: "追求目标",
            symbolName: "scope",
            action: #selector(goalPressed(_:))
        )

        [addFilesButton, addCurrentFileButton, planButton, goalButton].forEach { button in
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -Self.inset)
        ])

        view = container
        update(
            planModeEnabled: planModeEnabled,
            goalModeEnabled: goalModeEnabled,
            currentFileEnabled: currentFileEnabled
        )
    }

    func update(planModeEnabled: Bool, goalModeEnabled: Bool, currentFileEnabled: Bool) {
        self.planModeEnabled = planModeEnabled
        self.goalModeEnabled = goalModeEnabled
        self.currentFileEnabled = currentFileEnabled
        guard isViewLoaded else { return }
        addCurrentFileButton.isEnabled = currentFileEnabled
        addCurrentFileButton.contentTintColor = currentFileEnabled ? .labelColor : .disabledControlTextColor
        updateToggleButton(planButton, isOn: planModeEnabled)
        updateToggleButton(goalButton, isOn: goalModeEnabled)
    }

    private func configureActionButton(
        _ button: NSButton,
        title: String,
        symbolName: String,
        action: Selector
    ) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.cornerCurve = .continuous
        button.contentTintColor = .labelColor
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.56)
        )
    }

    private func updateToggleButton(_ button: NSButton, isOn: Bool) {
        button.state = isOn ? .on : .off
        button.contentTintColor = isOn ? .controlAccentColor : .labelColor
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: isOn
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
        )
    }

    @objc
    private func addFilesPressed(_ sender: NSButton) {
        onAddFiles?()
    }

    @objc
    private func addCurrentFilePressed(_ sender: NSButton) {
        onAddCurrentFile?()
    }

    @objc
    private func planPressed(_ sender: NSButton) {
        onTogglePlan?()
    }

    @objc
    private func goalPressed(_ sender: NSButton) {
        onToggleGoal?()
    }

    var actionTitlesForTesting: [String] {
        loadViewIfNeeded()
        return [addFilesButton.title, addCurrentFileButton.title, planButton.title, goalButton.title]
    }

    var currentFileEnabledForTesting: Bool {
        loadViewIfNeeded()
        return addCurrentFileButton.isEnabled
    }

    var preferredSizeForTesting: NSSize {
        preferredContentSize
    }

    var actionButtonHeightsForTesting: [CGFloat] {
        loadViewIfNeeded()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.layoutSubtreeIfNeeded()
        return [addFilesButton.frame.height, planButton.frame.height, goalButton.frame.height]
    }
}

private struct AIComposerPermissionPickerState {
    let currentPolicy: AgentConfirmationPolicyPreference
    let items: [(title: String, policy: AgentConfirmationPolicyPreference)]
}

private final class AIComposerPermissionPickerViewController: NSViewController {
    var onSelectPolicy: ((AgentConfirmationPolicyPreference) -> Void)?

    private let stack = NSStackView()
    private var buttons: [AIComposerPermissionButton] = []
    private var state: AIComposerPermissionPickerState
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 4
    private static let inset: CGFloat = 10

    init(state: AIComposerPermissionPickerState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 168, height: 144)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)

        stack.orientation = .vertical
        stack.spacing = Self.rowSpacing
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("Stacio.AI.composer.permissionPicker")
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -Self.inset)
        ])

        view = container
        update(state: state)
    }

    func update(state: AIComposerPermissionPickerState) {
        self.state = state
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons = state.items.map { item in
            let button = AIComposerPermissionButton(
                title: item.title,
                target: self,
                action: #selector(policyPressed(_:))
            )
            button.policy = item.policy
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.image = item.policy == state.currentPolicy
                ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前权限")
                : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选权限")
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = item.policy == state.currentPolicy
                ? .controlAccentColor
                : .secondaryLabelColor
            button.toolTip = item.title
            button.setAccessibilityIdentifier("Stacio.AI.composer.permissionPicker.\(item.policy.rawValue)")
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.cornerCurve = .continuous
            StacioDesignSystem.setLayerBackgroundColor(
                button,
                color: item.policy == state.currentPolicy
                    ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
            )
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            return button
        }
    }

    @objc
    private func policyPressed(_ sender: AIComposerPermissionButton) {
        onSelectPolicy?(sender.policy)
    }

    var policyTitlesForTesting: [String] {
        loadViewIfNeeded()
        return buttons.map(\.title)
    }

    var preferredSizeForTesting: NSSize {
        preferredContentSize
    }

    var buttonHeightsForTesting: [CGFloat] {
        loadViewIfNeeded()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.layoutSubtreeIfNeeded()
        return buttons.map(\.frame.height)
    }
}

private final class AIComposerPermissionButton: NSButton {
    var policy: AgentConfirmationPolicyPreference = .requireEveryCommand
}

private struct AIComposerModelPickerGroup {
    let providerID: UUID
    let providerTitle: String
    let models: [AIModelSelection]
}

private struct AIComposerModelPickerSpecialOption {
    let title: String
    let selection: AIModelSelection?
    let toolTip: String
    let accessibilityIdentifier: String
}

private struct AIComposerModelPickerState {
    let providerTitle: String
    let currentSelection: AIModelSelection?
    let specialOptions: [AIComposerModelPickerSpecialOption]
    let groups: [AIComposerModelPickerGroup]
    let reasoningItems: [(title: String, effort: AIReasoningEffortPreference)]
    let currentReasoning: AIReasoningEffortPreference
    let contextFraction: Double
    let contextLabel: String
}

private final class AIComposerModelPickerViewController: NSViewController {
    private static let width: CGFloat = 360
    private static let verticalPadding: CGFloat = 32
    private static let headerHeight: CGFloat = 62
    private static let rootSpacingTotal: CGFloat = 56
    private static let sectionLabelHeight: CGFloat = 14
    private static let modelRowHeight: CGFloat = 30
    private static let modelRowSpacing: CGFloat = 6
    private static let reasoningHeight: CGFloat = 30
    private static let minimumHeight: CGFloat = 246
    private static let maximumHeight: CGFloat = 350
    private static let maximumModelListHeight: CGFloat = 144

    var onSelectModel: ((AIModelSelection?) -> Void)?
    var onSelectReasoning: ((AIReasoningEffortPreference) -> Void)?

    private let rootStack = NSStackView()
    private let providerLabel = NSTextField(labelWithString: "")
    private let contextRing = AIContextUsageRingView()
    private let contextPercentLabel = NSTextField(labelWithString: "")
    private let contextCaptionLabel = NSTextField(labelWithString: "上下文")
    private let modelsScrollView = NSScrollView()
    private let modelsDocumentView = AIAssistantFlippedView()
    private let modelsStack = NSStackView()
    private let reasoningControl = NSSegmentedControl()
    private var modelsScrollHeightConstraint: NSLayoutConstraint?
    private var state: AIComposerModelPickerState

    init(state: AIComposerModelPickerState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSize(for: state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)

        rootStack.orientation = .vertical
        rootStack.spacing = 14
        rootStack.alignment = .leading
        rootStack.distribution = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 14
        headerStack.alignment = .top
        headerStack.distribution = .fill
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let ringContainer = NSView()
        ringContainer.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.wantsLayer = true
        ringContainer.layer?.cornerRadius = 28
        ringContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            ringContainer,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.74)
        )

        contextRing.translatesAutoresizingMaskIntoConstraints = false
        contextPercentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        contextPercentLabel.textColor = .labelColor
        contextPercentLabel.alignment = .center
        contextPercentLabel.translatesAutoresizingMaskIntoConstraints = false
        contextCaptionLabel.font = .systemFont(ofSize: 10, weight: .medium)
        contextCaptionLabel.textColor = .secondaryLabelColor
        contextCaptionLabel.alignment = .center
        contextCaptionLabel.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.addSubview(contextRing)
        ringContainer.addSubview(contextPercentLabel)
        ringContainer.addSubview(contextCaptionLabel)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 3
        titleStack.alignment = .leading
        titleStack.distribution = .fill
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: "选择模型")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.title")
        providerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        providerLabel.textColor = .secondaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingMiddle
        providerLabel.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.provider")
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(providerLabel)

        headerStack.addArrangedSubview(ringContainer)
        headerStack.addArrangedSubview(titleStack)
        titleStack.widthAnchor.constraint(equalTo: headerStack.widthAnchor, constant: -76).isActive = true

        let modelsHeader = makeSectionLabel("模型")
        modelsScrollView.translatesAutoresizingMaskIntoConstraints = false
        modelsScrollView.drawsBackground = false
        modelsScrollView.borderType = .noBorder
        modelsScrollView.hasVerticalScroller = true
        modelsScrollView.autohidesScrollers = true
        modelsScrollView.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.models")

        modelsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        modelsStack.orientation = .vertical
        modelsStack.spacing = 6
        modelsStack.alignment = .leading
        modelsStack.distribution = .fill
        modelsStack.translatesAutoresizingMaskIntoConstraints = false
        modelsStack.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.modelRows")
        modelsDocumentView.addSubview(modelsStack)
        modelsScrollView.documentView = modelsDocumentView

        let reasoningHeader = makeSectionLabel("推理强度")
        reasoningControl.target = self
        reasoningControl.action = #selector(reasoningChanged(_:))
        reasoningControl.segmentStyle = .texturedRounded
        reasoningControl.translatesAutoresizingMaskIntoConstraints = false
        reasoningControl.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.reasoning")

        [
            headerStack,
            modelsHeader,
            modelsScrollView,
            reasoningHeader,
            reasoningControl
        ].forEach { view in
            rootStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
        container.addSubview(rootStack)

        let modelsScrollHeightConstraint = modelsScrollView.heightAnchor.constraint(
            equalToConstant: Self.modelListHeight(for: state)
        )
        self.modelsScrollHeightConstraint = modelsScrollHeightConstraint

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),

            ringContainer.widthAnchor.constraint(equalToConstant: 62),
            ringContainer.heightAnchor.constraint(equalToConstant: 62),
            contextRing.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            contextRing.centerYAnchor.constraint(equalTo: ringContainer.centerYAnchor, constant: -4),
            contextRing.widthAnchor.constraint(equalToConstant: 42),
            contextRing.heightAnchor.constraint(equalToConstant: 42),
            contextPercentLabel.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            contextPercentLabel.centerYAnchor.constraint(equalTo: contextRing.centerYAnchor),
            contextCaptionLabel.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            contextCaptionLabel.bottomAnchor.constraint(equalTo: ringContainer.bottomAnchor, constant: -8),
            modelsDocumentView.leadingAnchor.constraint(equalTo: modelsScrollView.contentView.leadingAnchor),
            modelsDocumentView.trailingAnchor.constraint(equalTo: modelsScrollView.contentView.trailingAnchor),
            modelsDocumentView.topAnchor.constraint(equalTo: modelsScrollView.contentView.topAnchor),
            modelsDocumentView.widthAnchor.constraint(equalTo: modelsScrollView.contentView.widthAnchor),
            modelsStack.leadingAnchor.constraint(equalTo: modelsDocumentView.leadingAnchor),
            modelsStack.trailingAnchor.constraint(equalTo: modelsDocumentView.trailingAnchor),
            modelsStack.topAnchor.constraint(equalTo: modelsDocumentView.topAnchor),
            modelsStack.bottomAnchor.constraint(equalTo: modelsDocumentView.bottomAnchor),
            modelsScrollHeightConstraint,
            reasoningControl.heightAnchor.constraint(equalToConstant: 30)
        ])

        view = container
        update(state: state)
    }

    func update(state: AIComposerModelPickerState) {
        self.state = state
        preferredContentSize = Self.preferredSize(for: state)
        guard isViewLoaded else { return }
        providerLabel.stringValue = state.providerTitle
        contextRing.fraction = state.contextFraction
        contextRing.toolTip = state.contextLabel
        contextRing.setAccessibilityLabel(state.contextLabel)
        contextPercentLabel.stringValue = contextPercentText(for: state.contextFraction)
        renderModels()
        modelsScrollHeightConstraint?.constant = Self.modelListHeight(for: state)
        renderReasoning()
    }

    private func renderModels() {
        modelsStack.arrangedSubviews.forEach { view in
            modelsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if state.specialOptions.isEmpty, state.groups.isEmpty {
            let empty = NSTextField(labelWithString: "还没有可选模型")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            modelsStack.addArrangedSubview(empty)
            return
        }
        for option in state.specialOptions {
            let button = AIComposerModelButton(
                title: option.title,
                target: self,
                action: #selector(modelPressed(_:))
            )
            button.selection = option.selection
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.image = option.selection == state.currentSelection
                ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前模型")
                : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选模型")
            button.imagePosition = .imageLeading
            button.contentTintColor = option.selection == state.currentSelection
                ? .controlAccentColor
                : .secondaryLabelColor
            button.toolTip = option.toolTip
            button.setAccessibilityIdentifier(option.accessibilityIdentifier)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.cornerCurve = .continuous
            StacioDesignSystem.setLayerBackgroundColor(
                button,
                color: option.selection == state.currentSelection
                    ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
            )
            modelsStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        for group in state.groups {
            let heading = makeSectionLabel(group.providerTitle)
            heading.setAccessibilityIdentifier(
                "Stacio.AI.composer.modelPicker.provider.\(group.providerID.uuidString.lowercased())"
            )
            heading.toolTip = group.providerTitle
            modelsStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true

            for selection in group.models {
                let button = AIComposerModelButton(
                    title: selection.modelID,
                    target: self,
                    action: #selector(modelPressed(_:))
                )
                button.selection = selection
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                button.image = selection == state.currentSelection
                    ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前模型")
                    : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选模型")
                button.imagePosition = .imageLeading
                button.contentTintColor = selection == state.currentSelection
                    ? .controlAccentColor
                    : .secondaryLabelColor
                button.toolTip = "\(group.providerTitle) · \(selection.modelID)"
                button.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.model.\(selection.providerID.uuidString.lowercased()).\(selection.modelID)"
                )
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    button,
                    color: selection == state.currentSelection
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
        }
    }

    private func renderReasoning() {
        reasoningControl.segmentCount = state.reasoningItems.count
        for (index, item) in state.reasoningItems.enumerated() {
            reasoningControl.setLabel(item.title, forSegment: index)
            reasoningControl.setWidth(0, forSegment: index)
            reasoningControl.setEnabled(true, forSegment: index)
            reasoningControl.setToolTip("\(item.title)推理强度", forSegment: index)
        }
        reasoningControl.selectedSegment = state.reasoningItems.firstIndex {
            $0.effort == state.currentReasoning
        } ?? -1
    }

    private static func preferredSize(for state: AIComposerModelPickerState) -> NSSize {
        let height = verticalPadding
            + headerHeight
            + rootSpacingTotal
            + sectionLabelHeight * 2
            + modelListHeight(for: state)
            + reasoningHeight
        return NSSize(width: width, height: min(max(height, minimumHeight), maximumHeight))
    }

    private static func modelListHeight(for state: AIComposerModelPickerState) -> CGFloat {
        guard state.specialOptions.isEmpty == false || state.groups.isEmpty == false else {
            return modelRowHeight
        }
        let modelCount = state.specialOptions.count + state.groups.reduce(0) { $0 + $1.models.count }
        let rowCount = modelCount + state.groups.count
        let spacing = CGFloat(max(rowCount - 1, 0)) * modelRowSpacing
        let headingsHeight = CGFloat(state.groups.count) * sectionLabelHeight
        let modelsHeight = CGFloat(modelCount) * modelRowHeight
        return min(max(headingsHeight + modelsHeight + spacing, modelRowHeight), maximumModelListHeight)
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func contextPercentText(for fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    @objc
    private func modelPressed(_ sender: AIComposerModelButton) {
        onSelectModel?(sender.selection)
    }

    @objc
    private func reasoningChanged(_ sender: NSSegmentedControl) {
        guard state.reasoningItems.indices.contains(sender.selectedSegment) else {
            return
        }
        onSelectReasoning?(state.reasoningItems[sender.selectedSegment].effort)
    }

    var modelTitlesForTesting: [String] {
        update(state: state)
        return state.specialOptions.map(\.title) + state.groups.flatMap { $0.models.map(\.modelID) }
    }

    var groupTitlesForTesting: [String] {
        update(state: state)
        return state.groups.map(\.providerTitle)
    }

    var selectionsForTesting: [AIModelSelection] {
        update(state: state)
        return state.groups.flatMap(\.models)
    }

    var reasoningTitlesForTesting: [String] {
        update(state: state)
        return state.reasoningItems.map(\.title)
    }

    var contextTextForTesting: String {
        loadViewIfNeeded()
        update(state: state)
        return contextPercentLabel.stringValue
    }

    var preferredSizeForTesting: NSSize {
        preferredContentSize
    }
}

private final class AIComposerModelButton: NSButton {
    var selection: AIModelSelection?
}

private final class AIContextUsageRingView: NSView {
    var fraction: Double = 0 {
        didSet {
            fraction = min(max(fraction, 0), 1)
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size = min(bounds.width, bounds.height)
        guard size > 4 else { return }
        let rect = NSRect(
            x: bounds.midX - size / 2 + 2,
            y: bounds.midY - size / 2 + 2,
            width: size - 4,
            height: size - 4
        )
        let lineWidth: CGFloat = 3
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        track.stroke()

        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(clamped * 360),
            clockwise: true
        )
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

enum AIAssistantMarkdownRenderer {
    static func attributedString(
        from markdown: String,
        baseFont: NSFont = .systemFont(ofSize: 12),
        textColor: NSColor = StacioDesignSystem.theme.primaryTextColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 5
        let codeParagraph = NSMutableParagraphStyle()
        codeParagraph.lineSpacing = 2
        codeParagraph.paragraphSpacing = 6
        var isInCodeBlock = false
        let rawLines = markdown.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < rawLines.count {
            let rawLine = rawLines[lineIndex]
            lineIndex += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInCodeBlock.toggle()
                continue
            }
            if isInCodeBlock {
                append(
                    rawLine + "\n",
                    to: result,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: max(11, baseFont.pointSize - 1), weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.55),
                        .paragraphStyle: codeParagraph
                    ]
                )
                continue
            }
            if lineIndex < rawLines.count,
               isTableSeparator(rawLines[lineIndex]),
               tableCells(rawLine).count >= 2
            {
                let rowsStartIndex = lineIndex + 1
                var rows = [tableCells(rawLine)]
                lineIndex = rowsStartIndex
                while lineIndex < rawLines.count {
                    let cells = tableCells(rawLines[lineIndex])
                    guard cells.count >= 2 else { break }
                    rows.append(cells)
                    lineIndex += 1
                }
                appendTable(
                    rows,
                    to: result,
                    baseFont: baseFont,
                    textColor: textColor
                )
                continue
            }
            let lineStyle = styledLine(rawLine, baseFont: baseFont)
            let line = inlineMarkdown(lineStyle.text, baseFont: lineStyle.font, textColor: textColor)
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: lineStyle.font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]))
        }
        if result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private static func appendTable(
        _ rows: [[String]],
        to result: NSMutableAttributedString,
        baseFont: NSFont,
        textColor: NSColor
    ) {
        guard let columnCount = rows.map(\.count).max(), columnCount > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        for (rowIndex, cells) in rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setContentWidth(
                    100 / CGFloat(columnCount),
                    type: .percentageValueType
                )
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.65))
                if rowIndex == 0 {
                    block.backgroundColor = StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.7)
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 2
                paragraph.paragraphSpacing = 0
                paragraph.textBlocks = [block]
                let font = NSFont.systemFont(
                    ofSize: max(11, baseFont.pointSize - 1),
                    weight: rowIndex == 0 ? .semibold : .regular
                )
                let cellText = columnIndex < cells.count ? cells[columnIndex] : ""
                let renderedCell = inlineMarkdown(cellText, baseFont: font, textColor: textColor)
                renderedCell.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: renderedCell.length)
                )
                result.append(renderedCell)
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraph
                ]))
            }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }
        return trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private static func styledLine(_ line: String, baseFont: NSFont) -> (text: String, font: NSFont) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            return (String(trimmed.dropFirst(4)), .systemFont(ofSize: baseFont.pointSize + 1, weight: .semibold))
        }
        if trimmed.hasPrefix("## ") {
            return (String(trimmed.dropFirst(3)), .systemFont(ofSize: baseFont.pointSize + 2, weight: .semibold))
        }
        if trimmed.hasPrefix("# ") {
            return (String(trimmed.dropFirst(2)), .systemFont(ofSize: baseFont.pointSize + 3, weight: .semibold))
        }
        return (line, baseFont)
    }

    private static func inlineMarkdown(
        _ line: String,
        baseFont: NSFont,
        textColor: NSColor
    ) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        var index = line.startIndex
        var plainBuffer = ""

        func flushPlain() {
            guard plainBuffer.isEmpty == false else { return }
            output.append(linkedPlainText(plainBuffer, baseFont: baseFont, textColor: textColor))
            plainBuffer = ""
        }

        while index < line.endIndex {
            if line[index] == "[",
               let labelEnd = line[line.index(after: index)...].firstIndex(of: "]"),
               line.index(after: labelEnd) < line.endIndex,
               line[line.index(after: labelEnd)] == "(",
               let urlEnd = line[line.index(labelEnd, offsetBy: 2)...].firstIndex(of: ")"),
               urlEnd > line.index(labelEnd, offsetBy: 2)
            {
                let urlStart = line.index(labelEnd, offsetBy: 2)
                let title = String(line[line.index(after: index)..<labelEnd])
                let rawURL = String(line[urlStart..<urlEnd])
                if let url = URL(string: rawURL), url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
                    flushPlain()
                    append(
                        title,
                        to: output,
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: NSColor.linkColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .link: url
                        ]
                    )
                    index = line.index(after: urlEnd)
                    continue
                }
            }
            if line[index...].hasPrefix("**"),
               let end = line[line.index(index, offsetBy: 2)...].range(of: "**") {
                flushPlain()
                let contentStart = line.index(index, offsetBy: 2)
                let content = String(line[contentStart..<end.lowerBound])
                append(
                    content,
                    to: output,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                        .foregroundColor: textColor
                    ]
                )
                index = end.upperBound
                continue
            }
            if line[index] == "`",
               let end = line[line.index(after: index)...].firstIndex(of: "`") {
                flushPlain()
                let contentStart = line.index(after: index)
                let content = String(line[contentStart..<end])
                append(
                    content,
                    to: output,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: max(11, baseFont.pointSize - 1), weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.55)
                    ]
                )
                index = line.index(after: end)
                continue
            }
            plainBuffer.append(line[index])
            index = line.index(after: index)
        }
        flushPlain()
        return output
    }

    private static func linkedPlainText(
        _ text: String,
        baseFont: NSFont,
        textColor: NSColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: textColor]
        )
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return output
        }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        for match in detector.matches(in: text, range: fullRange) {
            guard let url = match.url,
                  url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
            else { continue }
            output.addAttributes(
                [
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: match.range
            )
        }
        return output
    }

    private static func append(
        _ string: String,
        to output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        output.append(NSAttributedString(string: string, attributes: attributes))
    }
}

private enum AITranscriptRole {
    case user
    case assistant
    case system
    case command
    case terminal
    case plan
    case step

    var isProcessRole: Bool {
        switch self {
        case .command, .terminal, .plan, .step:
            return true
        case .user, .assistant, .system:
            return false
        }
    }

    init(historyRole: AIConversationHistoryRole) {
        switch historyRole {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .command:
            self = .command
        case .terminal:
            self = .terminal
        case .plan:
            self = .plan
        case .step:
            self = .step
        }
    }

    var historyRole: AIConversationHistoryRole {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .system:
            return .assistant
        case .command:
            return .command
        case .terminal:
            return .terminal
        case .plan:
            return .plan
        case .step:
            return .step
        }
    }

    var persistedHistoryRole: AIConversationHistoryRole? {
        switch self {
        case .system:
            return nil
        default:
            return historyRole
        }
    }
}

private struct AITranscriptEntry {
    let role: AITranscriptRole
    var text: String
    let requestID: String?
    var isProcessEntry: Bool = false
    var processGroupID: UUID? = nil
    var isCollapsed: Bool = false
    var createdAt: Date = Date()

    var displayText: String {
        guard isCollapsed else { return text }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        return "\(firstLine) · 已折叠，点击展开"
    }

    var font: NSFont {
        switch role {
        case .user:
            return .systemFont(ofSize: 12, weight: .semibold)
        case .assistant:
            return .systemFont(ofSize: 12)
        case .system:
            return .systemFont(ofSize: 11, weight: .medium)
        case .command:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .terminal:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .plan:
            return .systemFont(ofSize: 12, weight: .medium)
        case .step:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
    }

    var textColor: NSColor {
        switch role {
        case .user:
            return .white
        case .assistant:
            return StacioDesignSystem.theme.primaryTextColor
        case .system:
            return StacioDesignSystem.theme.secondaryTextColor
        case .command:
            return StacioDesignSystem.theme.primaryTextColor
        case .terminal:
            return StacioDesignSystem.theme.primaryTextColor
        case .plan:
            return StacioDesignSystem.theme.primaryTextColor
        case .step:
            return StacioDesignSystem.theme.secondaryTextColor
        }
    }

    var bubbleAccessibilityIdentifier: String {
        switch role {
        case .user:
            return "Stacio.AI.transcript.userBubble"
        case .assistant:
            return "Stacio.AI.transcript.assistantBubble"
        case .system:
            return "Stacio.AI.transcript.systemBubble"
        case .command:
            return "Stacio.AI.transcript.commandBubble"
        case .terminal:
            return "Stacio.AI.transcript.terminalBubble"
        case .plan:
            return "Stacio.AI.transcript.planBubble"
        case .step:
            return "Stacio.AI.transcript.stepBubble"
        }
    }

    var textAccessibilityIdentifier: String {
        switch role {
        case .user:
            return "Stacio.AI.transcript.userText"
        case .assistant:
            return "Stacio.AI.transcript.assistantText"
        case .system:
            return "Stacio.AI.transcript.systemText"
        case .command:
            return "Stacio.AI.transcript.commandText"
        case .terminal:
            return "Stacio.AI.transcript.terminalText"
        case .plan:
            return "Stacio.AI.transcript.planText"
        case .step:
            return "Stacio.AI.transcript.stepText"
        }
    }

    var bubbleColor: NSColor {
        switch role {
        case .user:
            return StacioDesignSystem.theme.accentColor
        case .assistant:
            return .clear
        case .system:
            return .clear
        case .command:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.34)
        case .terminal:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.36)
        case .plan:
            return StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.72)
        case .step:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.28)
        }
    }

    var borderColor: NSColor? {
        switch role {
        case .user, .assistant, .system:
            return nil
        case .command, .terminal:
            return StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.2)
        case .plan:
            return StacioDesignSystem.theme.accentColor.withAlphaComponent(0.28)
        case .step:
            return StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.18)
        }
    }

    var bubbleCornerRadius: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return StacioDesignSystem.theme.panelCornerRadius
        case .user, .assistant, .system:
            return StacioDesignSystem.theme.panelCornerRadius
        }
    }

    var horizontalPadding: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return 12
        case .user:
            return 13
        case .assistant:
            return 0
        case .system:
            return 8
        }
    }

    var verticalPadding: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return 10
        case .user:
            return 10
        case .assistant:
            return 8
        case .system:
            return 4
        }
    }

    var verticalInset: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return 2
        case .user, .assistant:
            return 1
        case .system:
            return 1
        }
    }
}
