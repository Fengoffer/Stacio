import AppKit
import Network
import StacioAgentBridge
import StacioCoreBindings

private struct PendingAgentTaskContinuation {
    let question: String
    let goal: String
    let context: AITerminalContext
    let targetContexts: [AITerminalContext]
    let attachments: [AIAssistantAttachment]
    let completedSteps: [AgentTaskStepResult]
    let modelSelection: AIModelSelection
}

private struct PendingAgentPlanRequest {
    let question: String
    let context: AITerminalContext
    let targetContexts: [AITerminalContext]
    let attachments: [AIAssistantAttachment]
}

private struct InspectorComposerDraft {
    let text: String
    let attachments: [AIAssistantAttachment]
    let planModeEnabled: Bool
    let answerOnlyModeEnabled: Bool
    let goalModeEnabled: Bool
    let modelSelection: AIModelSelection?
}

private struct AgentTraceOwnershipKey: Hashable {
    let runtimeID: String
    let requestID: String
}

private struct TranscriptRenderFingerprint: Equatable {
    let id: UUID
    let role: String
    let displayText: String
    let attachments: [AITranscriptAttachment]
    let requestID: String?
    let isProcessEntry: Bool
    let processGroupID: UUID?
    let isCollapsed: Bool
    let executionCard: ExecutionCardPresentation?

    init(_ entry: AITranscriptEntry) {
        id = entry.id
        switch entry.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        case .command: role = "command"
        case .terminal: role = "terminal"
        case .plan: role = "plan"
        case .step: role = "step"
        }
        displayText = entry.displayText
        attachments = entry.attachments
        requestID = entry.requestID
        isProcessEntry = entry.isProcessEntry
        processGroupID = entry.processGroupID
        isCollapsed = entry.isCollapsed
        executionCard = entry.executionCard
    }
}

public final class AIAssistantPanelViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private static let defaultMessagePreferredWidth: CGFloat = 260
    private static let panelHorizontalInset: CGFloat = 14
    private static let minimumQuestionHeight: CGFloat = 48
    private static let maximumQuestionHeight: CGFloat = 112
    private static let compactComposerHeight: CGFloat = 124
    private static let contextComposerHeight: CGFloat = 132
    private static let attachmentComposerHeight: CGFloat = 188
    private static let maxAttachmentBytes = 4 * 1024 * 1024
    private static let maxAttachmentTextPreviewCharacters = 8_000
    private static let taskHistoryDisplayLimit = 3
    private static let taskHistoryScanLimit = 24
    private static let boundedTerminalHistoryCharacterLimit = 8_000
    private static let auditedTerminalHistoryCharacterLimit = 32_000
    private static let unconfiguredProviderMessage = "请先在设置中配置供应商模型"
    private static let primarySendLabel = "发送排查问题"
    private static let primaryStopLabel = "停止当前排查任务"
    private static let primaryActionSize: CGFloat = 34
    private static let compactDecisionCardMinimumHeight: CGFloat = 148
    private static let compactDecisionCardMaximumHeight: CGFloat = 212

    public var onCollapse: (() -> Void)?

    private let coordinator: AIAssistantCoordinator
    private let contextProvider: (String?) -> AITerminalContext?
    private let terminalSessionProvider: () -> [AgentTerminalSessionSummary]
    private let settingsStore: AppSettingsStore
    private let modelSelectionSession: AIModelSelectionSession
    private let initialComposerModelSelection: AIModelSelection?
    private let fallbackAgentTaskLoopLimits: AgentTaskLoopLimits
    private let assistantSettingsProvider: () -> AssistantRuntimeSettingsSnapshot?
    private let taskRecorder: AgentTaskRecording?
    private let taskLister: AgentTaskListing?
    private let conversationHistoryStore: AIAssistantConversationHistoryStoring?
    private let attachmentPicker: () -> [URL]
    private let internalBrowserOpener: (URL) -> Void
    private let externalBrowserOpener: (URL) -> Void
    private let terminalActivator: (String) -> Bool
    private let conversationRuntimeFactory: InspectorConversationRuntimeFactory?
    private let conversationCatalogLoader: ConversationSessionCatalogLoadOperation
    private let localAgentToolResolver: LocalAgentToolResolving
    private let localAgentProcessLauncherFactory: () -> LocalTerminalProcessLaunching
    private let localAgentRuntimeLaunchAuthorizerProvider: () -> LocalAgentRuntimeLaunchAuthorizing?
    private let localAgentSettingsOpener: () -> Void
    public var currentRemoteFileAttachmentProvider: (() throws -> AIAssistantAttachment)?
    public var currentRemoteFileAttachmentAvailabilityProvider: (() -> Bool)?
    private let conversationContainer = NSView()
    private let headerContainer = NSView()
    private let headerSeparator = NSBox()
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
    private let questionField = AgentComposerTextView()
    private let questionScrollView = NSScrollView()
    private let questionPlaceholderLabel = NSTextField(labelWithString: L10n.AI.placeholder)
    private let composer = AIComposerDropPasteView()
    private let composerAttachmentStack = NSStackView()
    private let composerContextLabel = NSTextField(labelWithString: "")
    private let composerToolbar = NSStackView()
    private let composerAddButton = NSButton()
    private let contextUsageRing = AIContextUsageRingView()
    private let composerPermissionButton = NSButton()
    private let composerModelButton = NSButton()
    private let askButton = AIComposerPrimaryActionButton(
        title: L10n.AI.ask,
        target: nil,
        action: nil
    )
    private let messageLabel = NSTextField(labelWithString: L10n.AI.noTerminal)
    private let transcriptScrollView = NSScrollView()
    private let transcriptDocumentView = AIAssistantFlippedView()
    private let transcriptContentStack = AIAssistantFlippedStackView()
    private let transcriptBottomSpacer = NSView()
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
    private let sensitiveInputContainer = NSStackView()
    private let sensitiveInputLabel = NSTextField(labelWithString: "")
    private let sensitiveInputField = NSSecureTextField()
    private let sensitiveInputSubmitButton = NSButton()
    private let taskHistoryContainer = NSStackView()
    private let taskHistoryHeaderLabel = NSTextField(labelWithString: L10n.AI.recentTasks)
    private let taskHistoryBodyLabel = NSTextField(labelWithString: "")
    private let taskHistoryButtonsStack = NSStackView()
    private let commandCardsStack = NSStackView()
    private let pendingInputQueueView = PendingInputQueueView()
    private let toolDecisionViewController = ToolDecisionViewController()
    private let statusLabel = NSTextField(labelWithString: "")
    private var commandCards: [AICommandCardView] = []
    private var transcriptEntries: [AITranscriptEntry] = []
    private var transcriptViewsByEntryID: [UUID: AITranscriptBubbleView] = [:]
    private var transcriptProcessGroupViewsByID: [UUID: AITranscriptProcessGroupView] = [:]
    private var lastNonProcessTranscriptFingerprint: [TranscriptRenderFingerprint]?
    private var transcriptWidthConstraintsByViewID: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var pendingTranscriptScrollWorkItem: DispatchWorkItem?
    private var streamingTranscriptRenderTimer: Timer?
    private var sensitiveInputRefreshTimer: Timer?
    private var traceEventsByRequestID: [String: [AgentTraceEvent]] = [:]
    private var traceActorKindsByRequest: [AgentTraceOwnershipKey: AgentActorKind] = [:]
    private var traceRuntimeTitlesByRequestID: [String: String] = [:]
    private var activeOrchestrator: AgentTaskOrchestrator?
    private var activeAutonomousTask: Task<Void, Never>?
    private var activeManualCommandTask: Task<Void, Never>?
    private var activeManualCommandRunID: UUID?
    private var activeManualCommandRequestID: String?
    private var activeAutonomousRunID: UUID?
    private var activeProcessGroupID: UUID?
    private var processGroupTimings: [UUID: AIProcessGroupTiming] = [:]
    private var manualProcessGroupIDsByRequestID: [String: UUID] = [:]
    private var activeAskID: UUID?
    private var activeAskCancellation: AIAssistantRequestCancelling?
    private var activeStreamingAssistantIndex: Int?
    private var pendingTaskContinuation: PendingAgentTaskContinuation?
    private var currentAgentPlan: AgentTaskPlan?
    private var pendingAgentPlanRequest: PendingAgentPlanRequest?
    private var planWorkspaceText = ""
    private var activeTaskRequestID: String?
    private var taskControlRequestIDsByRequestID: [String: [String]] = [:]
    private var taskControlStatusesByRequestID: [String: String] = [:]
    private var assistantOwnedTaskRequestIDs: Set<String> = []
    private var retiredAssistantTaskRequestIDs: Set<String> = []
    private var terminalRecordingScopesByRequestID: [String: String] = [:]
    private var taskControlText = ""
    private var sensitiveInputPrompt: AgentSensitiveInputPrompt?
    private var taskHistoryText = ""
    private var recentTaskRecords: [AgentTaskSessionRecord] = []
    private var currentProposalTaskRequestID: String?
    private var loadedConversationHistoryRuntimeID: String?
    private var conversationHistoryWriteStorageID: String?
    private var activeConversationIDs: [String: String] = [:]
    private var composerDraftsByStorageID: [String: InspectorComposerDraft] = [:]
    private var activeComposerDraftStorageID: String?
    private var shouldFollowCurrentTerminalAfterActivity = false
    private var pendingAssistantConclusionsByRequestID: [String: String] = [:]
    private var terminalBlocksByRequestID: [String: String] = [:]
    private var collapsedTraceRequestIDs: Set<String> = []
    private var appendedTraceEntryKeys: Set<String> = []
    private var appendedVirtualTerminalEntryKeys: Set<String> = []
    private var appendedExecutionResultRequestIDs: Set<String> = []
    private var traceObserver: NSObjectProtocol?
    private var terminalTaskControlObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var assistantSettingsObserver: NSObjectProtocol?
    private var composerAddPickerPopover: NSPopover?
    private var composerAddPickerViewController: AIComposerAddPickerViewController?
    private var composerModelPickerPopover: NSPopover?
    private var composerModelPickerViewController: AIComposerModelPickerViewController?
    private var composerPermissionPickerPopover: NSPopover?
    private var composerPermissionPickerViewController: AIComposerPermissionPickerViewController?
    private var composerPreviewWindow: NSWindow?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var questionHeightConstraint: NSLayoutConstraint?
    private var transcriptMinimumHeightConstraint: NSLayoutConstraint?
    private var conversationBottomToCommandCardsConstraint: NSLayoutConstraint?
    private var conversationBottomToComposerConstraint: NSLayoutConstraint?
    private var conversationBottomToContainerConstraint: NSLayoutConstraint?
    private var commandCardsCollapsedHeightConstraint: NSLayoutConstraint?
    private var questionTopWithoutAttachmentsConstraint: NSLayoutConstraint?
    private var questionTopWithAttachmentsConstraint: NSLayoutConstraint?
    private var decisionCardMinimumHeightConstraint: NSLayoutConstraint?
    private var decisionCardHeightProposalID: String?
    private var decisionCardHeightForPresentation: CGFloat?
    private var selectedRuntimeID: String?
    private var selectedRuntimeIDs: [String] = []
    private var composerAttachments: [AIAssistantAttachment] = []
    private var modelSelectionBeforeTask: AIModelSelection?
    private var capturedTaskModelSelection: AIModelSelection?
    private var planModeEnabled = false
    private var answerOnlyModeEnabled = false
    private var goalModeEnabled = false
    private var contextUsageFraction: Double = 0
    private var contextUsageLabel = "上下文 0%"
    private var isAsking = false
    private var isExecuting = false
    private var lastAppliedTranscriptTextWidth: CGFloat?
    private var isInspectorInteractiveResizeActive = false
    private var conversationRuntime: InspectorConversationRuntime?
    private var localAgentTerminalBlockViewController: LocalAgentTerminalBlockViewController?
    private var conversationRuntimeLoadTask: Task<Void, Never>?
    private var conversationRuntimeRestoreInFlight = false
    private var conversationRunPhase: ComposerRunPhase = .idle
    private var conversationSubmissionInFlight = false
    private var conversationSubmissionID: UUID?
    /// Compatibility-only local CLI selection. Verified Local Agent profiles
    /// remain owned by the durable V2 bridge; this value is intentionally not
    /// persisted as a V2 Runtime selection.
    private var legacyLocalAgentTool: LocalAgentTool?
    private var conversationRuntimeSelectionInFlight = false
    private var conversationRuntimeSelectionID: UUID?
    private var pendingConversationPrefill: String?
    private var pendingConversationComposerNotice: String?
    private var conversationContextRefreshPending = false
    private var selectedExecutionChoice: TurnExecutionChoice = .realTerminal
    private var v2ProjectedEntryIDs: [String: UUID] = [:]
    private var v2ExpandedExecutionProposalIDs: Set<String> = []
    private var conversationCatalogEntries: [ConversationSessionCatalogEntry] = []
    private var conversationContextGeneration: UInt64 = 0
    private var primaryActionSymbolName = "arrow.up"
    private var conversationStopRequested = false

    public init(
        coordinator: AIAssistantCoordinator,
        contextProvider: @escaping (String?) -> AITerminalContext?,
        terminalSessionProvider: @escaping () -> [AgentTerminalSessionSummary] = { [] },
        settingsStore: AppSettingsStore = .shared,
        modelSelectionSession: AIModelSelectionSession = AIModelSelectionSession(),
        agentTaskLoopLimits: AgentTaskLoopLimits = AgentTaskLoopLimits(),
        assistantSettingsProvider: @escaping () -> AssistantRuntimeSettingsSnapshot? = { nil },
        taskRecorder: AgentTaskRecording? = nil,
        taskLister: AgentTaskListing? = nil,
        conversationHistoryStore: AIAssistantConversationHistoryStoring? = nil,
        attachmentPicker: (() -> [URL])? = nil,
        internalBrowserOpener: @escaping (URL) -> Void = { _ in },
        externalBrowserOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        terminalActivator: @escaping (String) -> Bool = { _ in false },
        conversationRuntimeFactory: InspectorConversationRuntimeFactory? = nil,
        conversationCatalogLoader: @escaping ConversationSessionCatalogLoadOperation = {
            try ConversationSessionCatalogLoader().load()
        },
        currentRemoteFileAttachmentProvider: (() throws -> AIAssistantAttachment)? = nil,
        currentRemoteFileAttachmentAvailabilityProvider: (() -> Bool)? = nil,
        localAgentToolResolver: LocalAgentToolResolving = LocalAgentToolResolver.production(),
        localAgentProcessLauncherFactory: @escaping () -> LocalTerminalProcessLaunching = {
            SwiftTermLocalTerminalProcessLauncher()
        },
        localAgentRuntimeLaunchAuthorizerProvider: @escaping () -> LocalAgentRuntimeLaunchAuthorizing? = {
            LocalAgentRuntimeLaunchCoordinator.sharedIfAvailable()
        },
        localAgentSettingsOpener: @escaping () -> Void = {
            _ = NSApp.sendAction(
                #selector(AppDelegate.showSettingsWindow(_:)),
                to: nil,
                from: nil
            )
        }
    ) {
        self.coordinator = coordinator
        self.contextProvider = contextProvider
        self.terminalSessionProvider = terminalSessionProvider
        self.settingsStore = settingsStore
        self.modelSelectionSession = modelSelectionSession
        initialComposerModelSelection = Self.normalizedTemporaryModelSelection(
            modelSelectionSession.snapshot(),
            envelope: AIProviderSettingsNormalizer.normalized(
                settingsStore.snapshot().aiProviderSettings
            )
        )
        fallbackAgentTaskLoopLimits = agentTaskLoopLimits
        self.assistantSettingsProvider = assistantSettingsProvider
        self.taskRecorder = taskRecorder
        self.taskLister = taskLister
        self.conversationHistoryStore = conversationHistoryStore
        self.attachmentPicker = attachmentPicker ?? Self.pickAttachmentURLs
        self.internalBrowserOpener = internalBrowserOpener
        self.externalBrowserOpener = externalBrowserOpener
        self.terminalActivator = terminalActivator
        self.conversationRuntimeFactory = conversationRuntimeFactory
        self.conversationCatalogLoader = conversationCatalogLoader
        self.currentRemoteFileAttachmentProvider = currentRemoteFileAttachmentProvider
        self.currentRemoteFileAttachmentAvailabilityProvider = currentRemoteFileAttachmentAvailabilityProvider
        self.localAgentToolResolver = localAgentToolResolver
        self.localAgentProcessLauncherFactory = localAgentProcessLauncherFactory
        self.localAgentRuntimeLaunchAuthorizerProvider = localAgentRuntimeLaunchAuthorizerProvider
        self.localAgentSettingsOpener = localAgentSettingsOpener
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
        conversationRuntimeLoadTask?.cancel()
        activeManualCommandTask?.cancel()
        streamingTranscriptRenderTimer?.invalidate()
        sensitiveInputRefreshTimer?.invalidate()
        pendingTranscriptScrollWorkItem?.cancel()
        if let traceObserver {
            NotificationCenter.default.removeObserver(traceObserver)
        }
        if let terminalTaskControlObserver {
            NotificationCenter.default.removeObserver(terminalTaskControlObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let assistantSettingsObserver {
            NotificationCenter.default.removeObserver(assistantSettingsObserver)
        }
    }

    public override func loadView() {
        let container = StacioAppearanceRefreshView()
        container.wantsLayer = true
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        StacioDesignSystem.applyInspectorSurface(container)
        container.layer?.cornerRadius = 0

        questionField.delegate = self
        questionField.setAccessibilityIdentifier("Stacio.AI.question")
        questionField.font = .systemFont(ofSize: 14)
        questionField.textColor = StacioDesignSystem.theme.primaryTextColor
        questionField.backgroundColor = .clear
        questionField.drawsBackground = false
        questionField.textContainerInset = NSSize(width: 3, height: 7)
        questionField.isVerticallyResizable = true
        questionField.isHorizontallyResizable = false
        questionField.autoresizingMask = [.width]
        questionField.minSize = .zero
        questionField.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        questionField.textContainer?.widthTracksTextView = true
        questionField.isAutomaticQuoteSubstitutionEnabled = false
        questionField.isAutomaticDashSubstitutionEnabled = false
        questionField.isAutomaticTextReplacementEnabled = false
        questionField.onSend = { [weak self] in self?.composerSendRequested() }
        questionField.onQueue = { [weak self] in self?.queueComposerInput() }
        questionField.onStop = { [weak self] in self?.stopButtonPressed(nil) }
        questionField.onEscape = { [weak self] in self?.dismissComposerTransientUI() }
        questionField.historyProvider = { [weak self] in self?.sentQuestionHistory() ?? [] }

        questionScrollView.translatesAutoresizingMaskIntoConstraints = false
        questionScrollView.drawsBackground = false
        questionScrollView.borderType = .noBorder
        questionScrollView.hasVerticalScroller = true
        questionScrollView.hasHorizontalScroller = false
        questionScrollView.autohidesScrollers = true
        questionScrollView.setAccessibilityIdentifier("Stacio.AI.questionScroll")
        questionScrollView.documentView = questionField

        questionPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        questionPlaceholderLabel.font = .systemFont(ofSize: 14)
        questionPlaceholderLabel.textColor = .placeholderTextColor
        questionPlaceholderLabel.setAccessibilityElement(false)
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
        configureComposerIconButton(
            composerAddButton,
            symbolName: conversationRuntimeFactory == nil ? "plus" : "slider.horizontal.3",
            accessibilityLabel: conversationRuntimeFactory == nil ? "添加上下文" : "选择工作方式"
        )
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
        configurePrimaryActionButton()
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
        StacioDesignSystem.setLayerBackgroundColor(headerContainer, color: .clear)
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
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
        sensitiveInputContainer.orientation = .vertical
        sensitiveInputContainer.spacing = 8
        sensitiveInputContainer.alignment = .leading
        sensitiveInputContainer.distribution = .fill
        sensitiveInputContainer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        sensitiveInputContainer.translatesAutoresizingMaskIntoConstraints = false
        sensitiveInputContainer.setAccessibilityIdentifier("Stacio.AI.sensitiveInput")
        sensitiveInputContainer.isHidden = true
        sensitiveInputContainer.wantsLayer = true
        sensitiveInputContainer.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        sensitiveInputContainer.layer?.cornerCurve = .continuous
        sensitiveInputContainer.layer?.borderWidth = 1
        StacioDesignSystem.setLayerBackgroundColor(
            sensitiveInputContainer,
            color: StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.92)
        )
        StacioDesignSystem.setLayerBorderColor(
            sensitiveInputContainer,
            color: StacioDesignSystem.theme.warningColor.withAlphaComponent(0.42)
        )
        sensitiveInputLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sensitiveInputLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        sensitiveInputLabel.maximumNumberOfLines = 2
        sensitiveInputLabel.lineBreakMode = .byWordWrapping
        sensitiveInputLabel.cell?.wraps = true
        sensitiveInputLabel.cell?.usesSingleLineMode = false
        sensitiveInputLabel.translatesAutoresizingMaskIntoConstraints = false
        sensitiveInputField.placeholderString = "输入密码（不会发送给 AI）"
        sensitiveInputField.font = .systemFont(ofSize: 13)
        sensitiveInputField.focusRingType = .default
        sensitiveInputField.target = self
        sensitiveInputField.action = #selector(sensitiveInputSubmitPressed(_:))
        sensitiveInputField.setAccessibilityIdentifier("Stacio.AI.sensitiveInput.field")
        sensitiveInputField.setAccessibilityLabel("终端密码安全输入")
        sensitiveInputField.translatesAutoresizingMaskIntoConstraints = false
        sensitiveInputSubmitButton.target = self
        sensitiveInputSubmitButton.action = #selector(sensitiveInputSubmitPressed(_:))
        sensitiveInputSubmitButton.setAccessibilityIdentifier("Stacio.AI.sensitiveInput.submit")
        sensitiveInputSubmitButton.translatesAutoresizingMaskIntoConstraints = false
        configureIconButton(
            sensitiveInputSubmitButton,
            symbolName: "arrow.up",
            accessibilityLabel: "仅发送给终端",
            emphasized: true
        )
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
        pendingInputQueueView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        toolDecisionViewController.loadViewIfNeeded()
        toolDecisionViewController.setCompactPresentation(true)
        toolDecisionViewController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        configureConversationRuntimeControls()
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
        composer.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        composer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(composer, color: .clear)
        composer.layer?.borderWidth = 1
        StacioDesignSystem.setLayerBorderColor(
            composer,
            color: StacioDesignSystem.dynamicColor(.separatorColor, alpha: 0.35)
        )

        conversationContainer.addSubview(headerContainer)
        headerContainer.addSubview(headerIconView)
        headerContainer.addSubview(headerTitleLabel)
        headerContainer.addSubview(headerStatusDot)
        headerContainer.addSubview(headerStatusLabel)
        headerContainer.addSubview(targetButton)
        headerContainer.addSubview(collapseButton)
        headerContainer.addSubview(headerSeparator)
        conversationContainer.addSubview(conversationControlsStack)
        conversationContainer.addSubview(contextLabel)
        conversationContainer.addSubview(transcriptScrollView)
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
        let sensitiveInputControlsStack = NSStackView()
        sensitiveInputControlsStack.orientation = .horizontal
        sensitiveInputControlsStack.spacing = 8
        sensitiveInputControlsStack.alignment = .centerY
        sensitiveInputControlsStack.distribution = .fill
        sensitiveInputControlsStack.translatesAutoresizingMaskIntoConstraints = false
        sensitiveInputControlsStack.addArrangedSubview(sensitiveInputField)
        sensitiveInputControlsStack.addArrangedSubview(sensitiveInputSubmitButton)
        sensitiveInputContainer.addArrangedSubview(sensitiveInputLabel)
        sensitiveInputContainer.addArrangedSubview(sensitiveInputControlsStack)
        sensitiveInputLabel.widthAnchor.constraint(
            equalTo: sensitiveInputContainer.widthAnchor,
            constant: -24
        ).isActive = true
        sensitiveInputControlsStack.widthAnchor.constraint(
            equalTo: sensitiveInputContainer.widthAnchor,
            constant: -24
        ).isActive = true
        sensitiveInputField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        sensitiveInputSubmitButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        sensitiveInputSubmitButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        [taskHistoryHeaderLabel, taskHistoryBodyLabel, taskHistoryButtonsStack].forEach { view in
            taskHistoryContainer.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: taskHistoryContainer.widthAnchor).isActive = true
        }
        [
            messageLabel,
            planWorkspaceContainer,
            taskControlContainer,
            taskHistoryContainer,
            transcriptStack,
            toolDecisionViewController.view,
            pendingInputQueueView,
            statusLabel,
            sensitiveInputContainer
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
        let composerToolbarViews: [NSView] = [
            composerAddButton,
            composerPermissionButton,
            composerSpacer,
            composerModelButton,
            contextUsageRing,
            askButton
        ]
        composerToolbarViews.forEach(composerToolbar.addArrangedSubview)

        let composerSurface = GlassCapabilityAdapter.makeInteractiveSurface(
            fallbackMaterial: .popover,
            cornerRadius: StacioDesignSystem.theme.panelCornerRadius
        )
        composerSurface.translatesAutoresizingMaskIntoConstraints = false
        composerSurface.setAccessibilityElement(false)
        composer.addSubview(composerSurface)
        composer.addSubview(questionScrollView)
        composer.addSubview(questionPlaceholderLabel)
        composer.addSubview(composerAttachmentStack)
        composer.addSubview(composerContextLabel)
        composer.addSubview(composerToolbar)

        container.addSubview(conversationContainer)
        container.addSubview(commandCardsStack)
        container.addSubview(composer)

        let questionMinimumWidth = questionScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        questionMinimumWidth.priority = .defaultLow
        let transcriptMinimumHeight = transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 132)
        transcriptMinimumHeight.priority = .defaultHigh
        transcriptMinimumHeightConstraint = transcriptMinimumHeight
        questionTopWithoutAttachmentsConstraint = questionScrollView.topAnchor.constraint(
            equalTo: composer.topAnchor,
            constant: 12
        )
        questionTopWithAttachmentsConstraint = questionScrollView.topAnchor.constraint(
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
        questionHeightConstraint = questionScrollView.heightAnchor.constraint(
            equalToConstant: Self.minimumQuestionHeight
        )
        commandCardsCollapsedHeightConstraint = commandCardsStack.heightAnchor.constraint(equalToConstant: 0)
        decisionCardMinimumHeightConstraint = toolDecisionViewController.view.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.compactDecisionCardMinimumHeight
        )
        decisionCardMinimumHeightConstraint?.priority = .required
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.panelHorizontalInset),
            composer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.panelHorizontalInset),
            composer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            composerHeightConstraint!,

            composerSurface.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            composerSurface.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            composerSurface.topAnchor.constraint(equalTo: composer.topAnchor),
            composerSurface.bottomAnchor.constraint(equalTo: composer.bottomAnchor),

            composerAddButton.widthAnchor.constraint(equalToConstant: 32),
            composerAddButton.heightAnchor.constraint(equalToConstant: 32),
            contextUsageRing.widthAnchor.constraint(equalToConstant: 16),
            contextUsageRing.heightAnchor.constraint(equalToConstant: 16),
            composerPermissionButton.heightAnchor.constraint(equalToConstant: 28),
            composerModelButton.heightAnchor.constraint(equalToConstant: 28),
            composerModelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            askButton.widthAnchor.constraint(equalToConstant: Self.primaryActionSize),
            askButton.heightAnchor.constraint(equalToConstant: Self.primaryActionSize),
            composerAttachmentStack.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 16),
            composerAttachmentStack.trailingAnchor.constraint(lessThanOrEqualTo: composer.trailingAnchor, constant: -16),
            composerAttachmentStack.topAnchor.constraint(equalTo: composer.topAnchor, constant: 12),
            composerAttachmentStack.heightAnchor.constraint(equalToConstant: 54),

            questionScrollView.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 13),
            questionScrollView.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -13),
            questionHeightConstraint!,
            questionMinimumWidth,

            questionPlaceholderLabel.leadingAnchor.constraint(equalTo: questionScrollView.leadingAnchor, constant: 8),
            questionPlaceholderLabel.topAnchor.constraint(equalTo: questionScrollView.topAnchor, constant: 8),
            questionPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: questionScrollView.trailingAnchor, constant: -8),

            composerContextLabel.leadingAnchor.constraint(equalTo: questionScrollView.leadingAnchor, constant: 3),
            composerContextLabel.trailingAnchor.constraint(equalTo: questionScrollView.trailingAnchor, constant: -3),
            composerContextLabel.topAnchor.constraint(equalTo: questionScrollView.bottomAnchor, constant: 2),

            composerToolbar.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            composerToolbar.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            composerToolbar.topAnchor.constraint(greaterThanOrEqualTo: composerContextLabel.bottomAnchor, constant: 6),
            composerToolbar.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -12),
            composerToolbar.heightAnchor.constraint(equalToConstant: Self.primaryActionSize),

            commandCardsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.panelHorizontalInset),
            commandCardsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.panelHorizontalInset),
            commandCardsStack.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
            commandCardsCollapsedHeightConstraint!,

            toolDecisionViewController.view.heightAnchor.constraint(
                lessThanOrEqualToConstant: Self.compactDecisionCardMaximumHeight
            ),
            pendingInputQueueView.heightAnchor.constraint(lessThanOrEqualToConstant: 178),

            conversationContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.panelHorizontalInset),
            conversationContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.panelHorizontalInset),
            conversationContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),

            headerContainer.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: conversationContainer.topAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 54),

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

            headerSeparator.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),

            contextLabel.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor, constant: 4),
            contextLabel.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor, constant: -4),
            conversationControlsStack.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            conversationControlsStack.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            conversationControlsStack.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 10),
            conversationControlsStack.heightAnchor.constraint(equalToConstant: 26),

            contextLabel.topAnchor.constraint(equalTo: conversationControlsStack.bottomAnchor, constant: 8),

            transcriptScrollView.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            transcriptScrollView.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            transcriptScrollView.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 8),
            transcriptScrollView.bottomAnchor.constraint(equalTo: conversationContainer.bottomAnchor),
            transcriptMinimumHeight,

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
        observeAssistantSettingsChanges()
        refreshAssistantComposerSettings()
        reconcileTemporaryModelSelection()
        refreshForCurrentContext()
        refreshComposerControls()
        updateConversationBottomLayout()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateQuestionDocumentFrame()
        updateLayoutForCurrentWidth()
        // Resizing the Inspector changes the scroll viewport without changing
        // the conversation state. Keep a visible approval decision anchored to
        // the latest queue/card instead of allowing old content to drift into
        // the Composer area.
        if toolDecisionViewController.view.isHidden == false {
            // The transcript viewport is only final after Auto Layout has run.
            // Recompute the compact card height here so short Inspectors keep
            // the approval actions visible instead of clipping the card tail.
            updateDecisionCardHeight(showsDecision: true)
            applyTranscriptScrollPosition(forceLayout: false)
        }
    }

    func setInspectorInteractiveResizeActive(_ isActive: Bool) {
        guard isInspectorInteractiveResizeActive != isActive else { return }
        isInspectorInteractiveResizeActive = isActive
        guard isActive == false, isViewLoaded else { return }
        view.needsLayout = true
    }

    func refreshLayoutDuringInspectorInteractiveResize() {
        guard isViewLoaded,
              let hostView = view.superview,
              view.isHidden == false
        else { return }
        let targetBounds = hostView.bounds
        guard targetBounds.width > 0, targetBounds.height > 0 else { return }
        if view.frame != targetBounds {
            view.frame = targetBounds
        }
        if view.bounds.size != targetBounds.size {
            view.bounds = NSRect(origin: view.bounds.origin, size: targetBounds.size)
        }
        view.needsLayout = true
        view.needsDisplay = true
        conversationContainer.needsLayout = true
        composer.needsLayout = true
        transcriptScrollView.needsLayout = true
        transcriptDocumentView.needsLayout = true
        transcriptContentStack.needsLayout = true
        let contentWidth = max(80, targetBounds.width - Self.panelHorizontalInset * 2)
        applyTranscriptTextWidth(contentWidth)
    }

    private func updateLayoutForCurrentWidth() {
        let interactiveHostWidth = isInspectorInteractiveResizeActive
            ? view.superview.map { $0.bounds.width - Self.panelHorizontalInset * 2 }
            : nil
        let textWidth = max(
            80,
            interactiveHostWidth ?? conversationContainer.bounds.width
        )
        applyTranscriptTextWidth(textWidth)
    }

    private func applyTranscriptTextWidth(_ textWidth: CGFloat) {
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

    public func textDidChange(_ notification: Notification) {
        questionPlaceholderLabel.isHidden = questionField.string.isEmpty == false
        if conversationRuntimeFactory != nil,
           conversationContextRefreshPending || shouldFollowCurrentTerminalAfterActivity {
            pendingConversationPrefill = questionField.string
        } else if let bridge = conversationRuntime?.bridge {
            bridge.updateDraft(questionField.string)
        } else if conversationRuntimeFactory != nil {
            pendingConversationPrefill = questionField.string
        } else {
            saveActiveComposerDraft()
        }
        updateQuestionDocumentFrame()
        updateQuestionControlState()
    }

    public func refreshForCurrentContext() {
        if conversationRuntimeFactory != nil {
            if conversationContextTransitionBlocked {
                conversationContextRefreshPending = true
                return
            }
            refreshConversationRuntimeForCurrentContext()
            return
        }
        saveActiveComposerDraft()
        let context = refreshContextSummary()
        loadConversationHistory(for: context)
        if context != nil, messageLabel.stringValue == L10n.AI.noTerminal {
            messageLabel.stringValue = L10n.AI.ready
        }
        loadRecentTaskHistory(for: context)
        reconcileSensitiveInputPresentation()
    }

    public func followCurrentTerminalContext() {
        if conversationRuntimeFactory != nil,
           conversationContextTransitionBlocked {
            shouldFollowCurrentTerminalAfterActivity = true
            return
        }
        guard hasActiveAIActivity == false,
              conversationSubmissionInFlight == false else {
            shouldFollowCurrentTerminalAfterActivity = true
            return
        }
        selectedRuntimeID = nil
        selectedRuntimeIDs = []
        refreshForCurrentContext()
    }

    var requiresHostClosureSettlement: Bool {
        conversationSubmissionInFlight
            || conversationRuntime?.bridge.requiresHostClosureSettlement == true
            || localAgentTerminalBlockViewController?.requiresHostClosureTermination == true
            || hasActiveAIActivity
    }

    @discardableResult
    func prepareForHostClosure() -> Bool {
        guard conversationSubmissionInFlight == false else { return false }
        if conversationRuntime?.bridge.requiresHostClosureSettlement == true {
            return false
        }
        if localAgentTerminalBlockViewController?.requiresHostClosureTermination == true {
            localAgentTerminalBlockViewController?.terminateForHostClosure()
            return localAgentTerminalBlockViewController?.requiresHostClosureTermination == false
        }
        guard hasActiveAIActivity else { return true }
        stopCurrentAIRequest()
        return hasActiveAIActivity == false
    }

    @discardableResult
    func prepareForHostClosureAsync() async -> Bool {
        guard conversationSubmissionInFlight == false else { return false }
        guard let bridge = conversationRuntime?.bridge else {
            return prepareForHostClosure()
        }
        if bridge.requiresHostClosureSettlement {
            await bridge.stop()
        }
        guard bridge.requiresHostClosureSettlement == false else { return false }
        if localAgentTerminalBlockViewController?.requiresHostClosureTermination == true {
            localAgentTerminalBlockViewController?.terminateForHostClosure()
            for _ in 0..<200 {
                if localAgentTerminalBlockViewController?.requiresHostClosureTermination != true {
                    return true
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return false
        }
        return true
    }

    public func focusQuestionField() {
        view.window?.makeFirstResponder(questionField)
    }

    public func prefillQuestion(_ text: String) {
        if conversationRuntimeFactory != nil {
            pendingConversationComposerNotice = nil
        }
        questionField.string = text
        questionField.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        questionPlaceholderLabel.isHidden = text.isEmpty == false
        if conversationRuntimeFactory != nil {
            if conversationRunPhase == .preparing
                || conversationRuntime == nil
                || conversationContextRefreshPending
                || shouldFollowCurrentTerminalAfterActivity {
                pendingConversationPrefill = text
            } else {
                pendingConversationPrefill = nil
                conversationRuntime?.bridge.updateDraft(text)
            }
        }
        updateQuestionDocumentFrame()
        updateQuestionControlState()
    }

    public func prefillQuestion(
        _ text: String,
        attachments: [AIAssistantAttachment]
    ) {
        prefillQuestion(text)
        guard conversationRuntimeFactory == nil else {
            composerAttachments = []
            refreshComposerControls()
            if attachments.isEmpty == false {
                presentConversationAttachmentUnsupported(
                    "问题已填入，但当前排查助手尚未安全接入文件附件，文件内容未附加。请粘贴必要的脱敏文本。"
                )
            }
            return
        }
        composerAttachments = attachments
        refreshComposerControls()
    }

    private func updateConversationBottomLayout() {
        let usesV2Runtime = conversationRuntimeFactory != nil
        // The card itself is the source of truth for its layout reservation.
        // Do not couple its minimum height to the factory reference: a late
        // runtime teardown or settings refresh must not let a visible approval
        // card collapse into the Composer area.
        let showsDecision = toolDecisionViewController.view.isHidden == false
        // Keep the approval decision prominent in the narrow Inspector. The
        // queued-input list expands again once the decision card is gone.
        pendingInputQueueView.setCompactPresentation(showsDecision)
        // Keep a flexible tail in the transcript document. It reserves the
        // gap above the fixed Composer while the approval card and queue stay
        // inside the scrollable transcript surface.
        transcriptBottomSpacer.isHidden = false
        let showsCommandCards = usesV2Runtime == false && commandCards.isEmpty == false
        decisionCardMinimumHeightConstraint?.isActive = showsDecision
        updateDecisionCardHeight(showsDecision: showsDecision)
        transcriptMinimumHeightConstraint?.constant = 132
        transcriptMinimumHeightConstraint?.priority = .defaultHigh
        commandCardsStack.isHidden = showsCommandCards == false
        commandCardsCollapsedHeightConstraint?.isActive = usesV2Runtime == false && showsCommandCards == false
        conversationBottomToCommandCardsConstraint?.isActive = showsCommandCards
        conversationBottomToComposerConstraint?.isActive = showsCommandCards == false
        conversationBottomToContainerConstraint?.isActive = false
        if isViewLoaded {
            view.needsLayout = true
            // Approval and queue views are inline transcript content. Resolve
            // their first geometry pass synchronously so a newly presented
            // card cannot spend one frame at the Composer edge while AppKit
            // defers the document/clip layout.
            view.layoutSubtreeIfNeeded()
            if showsDecision {
                applyTranscriptScrollPosition(forceLayout: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.toolDecisionViewController.view.isHidden == false
                    else { return }
                    self.scrollTranscriptToBottom()
                }
            }
        }
    }

    private func updateDecisionCardHeight(showsDecision: Bool) {
        guard showsDecision else {
            decisionCardHeightProposalID = nil
            decisionCardHeightForPresentation = nil
            toolDecisionViewController.setCompactHeight(nil)
            return
        }

        let proposalID = toolDecisionViewController.currentProposalID
        if decisionCardHeightProposalID != proposalID {
            decisionCardHeightProposalID = proposalID
            decisionCardHeightForPresentation = nil
        }

        // The outer transcript is the scrolling surface. Keep the approval
        // actions inside the visible slice and let the command/details
        // viewport scroll when the Inspector is short.
        let queueHeight = max(34, pendingInputQueueView.fittingSize.height)
        // NSScrollView.bounds can describe the document coordinate space while
        // it is being relaid out. The clip view is the stable visible viewport.
        let visibleTranscriptHeight = transcriptScrollView.contentView.bounds.height
        let availableHeight = visibleTranscriptHeight
            - queueHeight
            - transcriptContentStack.spacing
        let targetHeight = min(
            Self.compactDecisionCardMaximumHeight,
            max(Self.compactDecisionCardMinimumHeight, availableHeight)
        )
        // A relayout can briefly report the document height instead of the
        // visible clip height. Once a card has been compressed for a short
        // Inspector, never grow it again during that presentation; otherwise
        // the transient document measurement can put the card back under the
        // Composer. A new proposal resets this latch above.
        let stableTargetHeight = min(
            targetHeight,
            decisionCardHeightForPresentation ?? targetHeight
        )
        let heightChanged = decisionCardHeightForPresentation == nil
            || abs((decisionCardHeightForPresentation ?? 0) - stableTargetHeight) > 0.5
        decisionCardHeightForPresentation = stableTargetHeight
        toolDecisionViewController.setCompactHeight(stableTargetHeight)
        if heightChanged {
            // The height constraint changes the transcript document on the
            // next layout pass. Re-anchor after that pass so the queued row
            // cannot remain under the Composer for one frame.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.toolDecisionViewController.view.isHidden == false
                else { return }
                self.scrollTranscriptToBottom()
            }
        }
    }

    private func clearConversationDecisionCard() {
        toolDecisionViewController.apply(nil)
        updateConversationBottomLayout()
    }

    private func configureConversationRuntimeControls() {
        toolDecisionViewController.apply(nil)
        pendingInputQueueView.apply(items: [], autoAdvancePaused: false)

        pendingInputQueueView.onEdit = { [weak self] itemID, text in
            guard let bridge = self?.conversationRuntime?.bridge else { return }
            Task { @MainActor in _ = await bridge.editQueuedInput(id: itemID, text: text) }
        }
        pendingInputQueueView.onRemove = { [weak self] itemID in
            guard let bridge = self?.conversationRuntime?.bridge else { return }
            Task { @MainActor in _ = await bridge.removeQueuedInput(id: itemID) }
        }
        pendingInputQueueView.onMove = { [weak self] itemID, destination in
            guard let bridge = self?.conversationRuntime?.bridge else { return }
            Task { @MainActor in _ = await bridge.moveQueuedInput(id: itemID, to: destination) }
        }
        pendingInputQueueView.onSetNext = { [weak self] itemID in
            guard let bridge = self?.conversationRuntime?.bridge else { return }
            Task { @MainActor in _ = await bridge.setNextQueuedInput(id: itemID) }
        }
        pendingInputQueueView.onPullBack = { [weak self] itemID in
            guard let self, let bridge = self.conversationRuntime?.bridge else { return }
            let expectedDraft = self.questionField.string
            Task { @MainActor [weak self] in
                guard let self,
                      let text = await bridge.pullQueuedInputToComposer(
                        id: itemID,
                        expectedDraft: expectedDraft
                      )
                else { return }
                self.applyConversationDraft(text)
            }
        }
        pendingInputQueueView.onRebind = { [weak self] itemID, choice in
            guard let bridge = self?.conversationRuntime?.bridge else { return }
            Task { @MainActor in
                _ = await bridge.resolveQueuedInputRebind(id: itemID, choice: choice)
            }
        }
        pendingInputQueueView.onAutoAdvanceChanged = { [weak self] paused in
            guard let bridge = self?.conversationRuntime?.bridge else { return }
            Task { @MainActor in _ = await bridge.setQueueAutoAdvancePaused(paused) }
        }
        pendingInputQueueView.rebindSummaryProvider = { [weak self] input in
            self?.conversationRuntime?.bridge.queuedInputRebindSummary(for: input)
                ?? "上下文需要重新确认"
        }
        toolDecisionViewController.onResolve = { [weak self] proposalID, approved in
            guard let self else { return }
            let generation = self.conversationContextGeneration
            guard let runtime = self.conversationRuntime,
                  self.toolDecisionViewController.currentProposalID == proposalID
            else {
                // The card can outlive its Runtime while a terminal/context is
                // being rebound. Never leave its buttons latched in resolving.
                if self.toolDecisionViewController.currentProposalID == proposalID {
                    self.clearConversationDecisionCard()
                }
                return
            }
            let bridge = runtime.bridge
            Task { @MainActor [weak self, weak runtime, weak bridge] in
                guard let self,
                      let runtime,
                      let bridge,
                      self.conversationContextGeneration == generation,
                      self.conversationRuntime === runtime,
                      runtime.bridge === bridge,
                      self.toolDecisionViewController.currentProposalID == proposalID
                else { return }
                let result = await bridge.resolveToolDecision(
                    proposalID: proposalID,
                    approved: approved
                )
                guard self.conversationContextGeneration == generation,
                      self.conversationRuntime === runtime,
                      runtime.bridge === bridge,
                      self.toolDecisionViewController.currentProposalID == proposalID
                else { return }
                if case .rejected(let reason) = result {
                    _ = self.toolDecisionViewController.setResolving(
                        false,
                        forProposalID: proposalID,
                        error: reason
                    )
                }
            }
        }
    }

    private func bindConversationRuntime(_ runtime: InspectorConversationRuntime) {
        let bridge = runtime.bridge
        bridge.onTimelineUpdate = { [weak self, weak runtime] entries in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.applyConversationTimeline(entries)
        }
        bridge.onQueueUpdate = { [weak self, weak runtime] items, paused, forceRefresh in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.pendingInputQueueView.apply(
                items: items,
                autoAdvancePaused: paused,
                forceRefresh: forceRefresh
            )
            self.updateConversationBottomLayout()
            if items.isEmpty {
                DispatchQueue.main.async { [weak self, weak runtime] in
                    guard let self, let runtime, self.conversationRuntime === runtime else { return }
                    self.resumeDeferredConversationContextChangeIfPossible()
                }
            }
        }
        bridge.onDraftRestored = { [weak self, weak runtime] text in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            guard self.pendingConversationPrefill == nil else { return }
            self.applyConversationDraft(text)
        }
        bridge.onRunPhaseUpdate = { [weak self, weak runtime] phase in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.applyConversationRunPhase(phase)
            self.refreshHeaderStatusForCurrentContext()
            self.refreshComposerModelPicker()
            self.updateQuestionControlState()
            if phase == .idle {
                DispatchQueue.main.async { [weak self, weak runtime] in
                    guard let self, let runtime, self.conversationRuntime === runtime else { return }
                    self.resumeDeferredConversationContextChangeIfPossible()
                }
            }
        }
        bridge.onToolDecisionUpdate = { [weak self, weak runtime] decision in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.toolDecisionViewController.apply(decision)
            self.updateConversationBottomLayout()
        }
        bridge.onSelectionUpdate = { [weak self, weak runtime] mode, choice in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.planModeEnabled = mode == .planFirst
            self.answerOnlyModeEnabled = mode == .answerOnly
            self.goalModeEnabled = false
            self.selectedExecutionChoice = choice
            self.refreshComposerControls()
            self.updateQuestionControlState()
        }
        bridge.onRuntimeSelectionUpdate = { [weak self, weak runtime] selection in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.synchronizeLocalAgentPresentation(with: selection)
            if selection.kind == .nativeAPI,
               let configurationID = selection.providerConfigurationID
                    ?? selection.codingPlanConfigurationID,
               let providerID = UUID(uuidString: configurationID),
               let modelID = selection.modelID,
               modelID.isEmpty == false {
                self.modelSelectionSession.select(
                    AIModelSelection(providerID: providerID, modelID: modelID)
                )
            }
            self.refreshComposerControls()
            self.refreshComposerModelPicker()
        }
        bridge.onRuntimeUnavailable = { [weak self, weak runtime] message in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            self.messageLabel.stringValue = message
            self.messageLabel.isHidden = false
            self.statusLabel.stringValue = ""
            self.updateQuestionControlState()
        }
        bridge.onTargetUpdate = { [weak self, weak runtime] _ in
            guard let self, let runtime, self.conversationRuntime === runtime else { return }
            _ = self.refreshContextSummary()
        }
        questionField.historyProvider = { [weak self, weak runtime] in
            guard let self, let runtime, self.conversationRuntime === runtime else {
                return self?.sentQuestionHistory() ?? []
            }
            return self.composerQuestionHistory(with: runtime.bridge.sentHistory)
        }
        planModeEnabled = bridge.selectedWorkMode == .planFirst
        answerOnlyModeEnabled = bridge.selectedWorkMode == .answerOnly
        goalModeEnabled = false
        selectedExecutionChoice = bridge.selectedExecutionChoice
        synchronizeLocalAgentPresentation(with: bridge.currentRuntimeSelection)
        refreshComposerControls()
    }

    private var configuredLocalAgentConfigurations: [LocalAgentPassthroughConfiguration] {
        LocalAgentTool.allCases.compactMap {
            localAgentToolResolver.passthroughConfiguration(for: $0)
        }.filter(\.isReadyForTerminalPassthrough)
    }

    private var compatibleLocalAgentTools: [LocalAgentTool] {
        let verifiedTools = Set(configuredLocalAgentConfigurations.map(\.tool))
        return LocalAgentTool.allCases.filter { tool in
            verifiedTools.contains(tool) == false
                && localAgentToolResolver.legacyExecutablePath(for: tool) != nil
        }
    }

    private func localAgentConfiguration(
        matching selection: AgentRuntimeSelection
    ) -> LocalAgentPassthroughConfiguration? {
        guard selection.kind == .localAgent,
              let configurationID = selection.localAgentConfigurationID
        else { return nil }
        return configuredLocalAgentConfigurations.first {
            $0.configurationID == configurationID
                && $0.executionProfileID == selection.localAgentExecutionProfileID
        }
    }

    private func ensureLocalAgentTerminalBlock() -> LocalAgentTerminalBlockViewController {
        if let localAgentTerminalBlockViewController {
            return localAgentTerminalBlockViewController
        }
        let block = LocalAgentTerminalBlockViewController(
            resolver: localAgentToolResolver,
            processLauncherFactory: localAgentProcessLauncherFactory,
            settingsStore: settingsStore,
            currentDirectoryProvider: { [weak self] in
                self?.resolvedTargetContext()?.currentDirectory
            },
            bridgeContextProvider: { [weak self] in
                self?.makeLocalAgentBridgeContext()
            },
            runtimeLaunchAuthorizer: localAgentRuntimeLaunchAuthorizerProvider()
        )
        block.loadViewIfNeeded()
        block.view.isHidden = true
        block.onStateChange = { [weak self, weak block] _ in
            guard let self, let block,
                  self.localAgentTerminalBlockViewController === block else { return }
            self.settleConversationStopLatchIfPossible()
            self.refreshComposerControls()
            self.refreshComposerModelPicker()
            self.updateQuestionControlState()
            self.transcriptContentStack.invalidateIntrinsicContentSize()
            self.view.needsLayout = true
            self.resumeDeferredConversationContextChangeIfPossible()
        }
        addChild(block)
        let insertionIndex = transcriptContentStack.arrangedSubviews.firstIndex {
            $0 === transcriptBottomSpacer
        } ?? transcriptContentStack.arrangedSubviews.count
        transcriptContentStack.insertArrangedSubview(block.view, at: insertionIndex)
        block.view.widthAnchor.constraint(equalTo: transcriptContentStack.widthAnchor).isActive = true
        block.view.setContentHuggingPriority(.required, for: .vertical)
        localAgentTerminalBlockViewController = block
        return block
    }

    private func synchronizeLocalAgentPresentation(with selection: AgentRuntimeSelection) {
        guard selection.kind == .localAgent else {
            legacyLocalAgentTool = nil
            _ = localAgentTerminalBlockViewController?.deactivateIfStopped()
            return
        }
        legacyLocalAgentTool = nil
        guard let configuration = localAgentConfiguration(matching: selection) else {
            let block = ensureLocalAgentTerminalBlock()
            block.view.isHidden = false
            block.showNotice("所选 Local Agent 配置已失效，请在设置中重新检测并确认。")
            return
        }
        if configuration.isReadyForStructuredRuntime {
            // Managed Codex/Claude output belongs to the transcript. If a
            // previous compatibility session left a terminal block behind,
            // release it when stopped so the Inspector keeps its original
            // single-column conversation layout.
            if let block = localAgentTerminalBlockViewController {
                _ = block.deactivateIfStopped()
                block.view.isHidden = true
            }
            return
        }
        let block = ensureLocalAgentTerminalBlock()
        _ = block.select(configuration: configuration)
        block.refreshBridgeContext()
    }

    private func makeLocalAgentBridgeContext() -> LocalAgentBridgeContext? {
        guard let cliPath = LocalAgentBridgeToolInstaller.defaultCLIExecutablePath(),
              let socketPath = try? StacioPaths.agentBridgeSocketPath().path
        else { return nil }
        let contexts = resolvedTargetContexts()
        let primary = contexts.first
        return LocalAgentBridgeContext(
            socketPath: socketPath,
            targetRuntimeID: primary?.runtimeID,
            targetRuntimeIDs: contexts.map(\.runtimeID),
            targetRuntimeGenerations: Dictionary(
                uniqueKeysWithValues: contexts.map { ($0.runtimeID, $0.connectionGeneration) }
            ),
            targetTitle: contexts.map(\.title).joined(separator: "、"),
            remoteCurrentDirectory: primary?.currentDirectory,
            cliExecutablePath: cliPath,
            toolsDirectory: LocalAgentBridgeToolInstaller.defaultToolsDirectory()
        )
    }

    private func applyConversationRunPhase(_ phase: ComposerRunPhase) {
        conversationRunPhase = phase
        settleConversationStopLatchIfPossible()
        isAsking = phase != .idle && phase != .editingQueuedItem && phase != .takenOver
        isExecuting = phase == .executingTool
    }

    private func settleConversationStopLatchIfPossible() {
        guard conversationStopRequested,
              conversationSubmissionInFlight == false,
              conversationRunPhase == .idle,
              conversationRuntime?.bridge.isIdle != false,
              localAgentTerminalBlockViewController?.state.preventsRuntimeChange != true
        else { return }
        conversationStopRequested = false
    }

    private func applyConversationDraft(_ text: String) {
        questionField.string = text
        questionField.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        questionPlaceholderLabel.isHidden = text.isEmpty == false
        updateQuestionDocumentFrame()
        updateQuestionControlState()
    }

    private func applyConversationTimeline(_ entries: [TimelineSourceEntry]) {
        var counts: [String: Int] = [:]
        let projected: [AITranscriptEntry] = entries.map { source in
            let projection = transcriptProjection(for: source)
            let ordinal = counts[projection.kind, default: 0]
            counts[projection.kind] = ordinal + 1
            let stableKey = "\(projection.kind):\(ordinal)"
            let entryID = v2ProjectedEntryIDs[stableKey] ?? UUID()
            v2ProjectedEntryIDs[stableKey] = entryID
            return AITranscriptEntry(
                id: entryID,
                role: projection.role,
                text: projection.text,
                requestID: projection.requestID,
                isProcessEntry: false,
                executionCard: {
                    if case .executionCard(let card) = source { return card }
                    return nil
                }()
            )
        }
        let activeKeys = Set(counts.flatMap { kind, count in
            (0..<count).map { "\(kind):\($0)" }
        })
        v2ProjectedEntryIDs = v2ProjectedEntryIDs.filter { activeKeys.contains($0.key) }
        activeStreamingAssistantIndex = nil
        transcriptEntries = projected
        messageLabel.isHidden = projected.isEmpty == false
        renderTranscriptEntries()
    }

    private func transcriptProjection(
        for source: TimelineSourceEntry
    ) -> (kind: String, role: AITranscriptRole, text: String, requestID: String?) {
        switch source {
        case .userMessage(let text):
            return ("user", .user, text, nil)
        case .finalAnswer(let text):
            return ("answer", .assistant, text, nil)
        case .reasoningSummary(let text):
            return ("reasoning", .step, text, nil)
        case .planProgress(let text):
            return ("progress", .step, text, nil)
        case .toolCall(let command, let result):
            return ("tool", .command, [command, result].compactMap { $0 }.joined(separator: "\n"), nil)
        case .commandApproval(let text):
            return ("approval", .command, text, nil)
        case .executionCard(let card):
            let details = [
                card.redactedCommand,
                "目标：\(card.target)",
                "工作目录：\(card.workingDirectory)",
                "执行位置：\(card.isRealTerminal ? "真实终端" : "后台虚拟终端")",
                card.status.isEmpty ? nil : "状态：\(card.status)",
                card.exitCode.map { "退出码：\($0)" },
                card.terminalArtifact?.liveTail
            ].compactMap { $0 }.joined(separator: "\n")
            let identity = card.proposalID.isEmpty ? "execution" : "execution:\(card.proposalID)"
            return (identity, .terminal, details, card.terminalArtifact?.requestID)
        case .terminalBlock(let text):
            return ("terminal", .terminal, text, nil)
        case .userInputRequest(let secure):
            return ("input", .system, secure ? "等待敏感输入" : "等待用户输入", nil)
        case .capacityWait:
            return ("capacity", .system, "正在等待全局执行容量", nil)
        case .pauseCheckpoint(let text):
            return ("pause", .system, text, nil)
        case .errorRecovery(let text):
            return ("error", .system, text, nil)
        case .childTaskGroup(let text):
            return ("child", .step, text, nil)
        case .artifact(let text):
            return ("artifact", .terminal, text, nil)
        }
    }

    private func composerSendRequested() {
        guard conversationRuntimeFactory != nil else {
            askButtonPressed(nil)
            return
        }
        guard let bridge = conversationRuntime?.bridge else {
            presentConversationRuntimeUnavailable()
            return
        }
        // The visual primary action becomes Stop while a Turn is active, but a
        // keyboard Send keeps Send semantics; the bridge durably queues it.
        submitConversationComposer(using: bridge, explicitlyQueued: false)
    }

    @objc
    private func askButtonPressed(_ sender: Any?) {
        if primaryActionShowsStop {
            stopButtonPressed(sender)
            return
        }
        if conversationRuntimeFactory != nil {
            guard let bridge = conversationRuntime?.bridge else {
                presentConversationRuntimeUnavailable()
                return
            }
            submitConversationComposer(using: bridge, explicitlyQueued: false)
            return
        }
        if hasActiveAIActivity {
            stopCurrentAIRequest()
            return
        }
        let question = questionField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.isEmpty == false else {
            messageLabel.stringValue = L10n.AI.emptyQuestion
            statusLabel.stringValue = ""
            setCommandProposals([])
            updateQuestionControlState()
            return
        }
        guard hasConfiguredAssistantModel else {
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
        let requestTargetContexts = capturedTargetContexts(primary: context)
        finishActiveProcessGroup(collapse: true)
        let isReplacingPendingTaskContinuation = pendingTaskContinuation != nil
        clearPendingTaskContinuation()
        if isReplacingPendingTaskContinuation {
            endTaskModelSelectionCapture()
        }
        let requestConversationHistory = assistantConversationContext()
        let requestQuestion = composerAugmentedQuestion(for: question)
        let requestAttachments = composerAttachments
        let requestAutoRunProposedCommands = settingsStore.snapshot().aiAutoRunProposedCommands
        conversationHistoryWriteStorageID = conversationHistoryStorageID(for: context)
        discardActiveComposerDraft()
        questionField.string = ""
        questionPlaceholderLabel.isHidden = false
        isAsking = true
        refreshHeaderStatus(context: context)
        statusLabel.stringValue = L10n.AI.thinking
        appendTranscript(
            .user,
            question,
            conversationContent: userConversationContent(
                question: question,
                attachments: requestAttachments
            ),
            attachments: requestAttachments
        )
        clearComposerAttachmentsAfterSend()
        messageLabel.stringValue = ""
        setCommandProposals([])
        updateQuestionControlState()

        activeStreamingAssistantIndex = nil
        if planModeEnabled {
            startPlanMode(
                question: question,
                requestQuestion: requestQuestion,
                context: context,
                targetContexts: requestTargetContexts,
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
                targetContexts: requestTargetContexts,
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
            workMode: .agent,
            progress: { [weak self] message in
                self?.handleAssistantProgress(message, askID: askID)
            },
            stream: { [weak self] delta in
                self?.handleAssistantStreamingDelta(delta, askID: askID)
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
                if requestAutoRunProposedCommands,
                   response.commandProposals.isEmpty == false {
                    self.messageLabel.stringValue = ""
                    self.startStepwiseAutoRun(
                        question: question,
                        goal: requestQuestion,
                        context: context,
                        targetContexts: requestTargetContexts,
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

    private func handleAssistantProgress(_ message: String, askID: UUID) {
        guard activeAskID == askID, isAsking else { return }
        appendAssistantProgress(message)
    }

    private func handleAssistantStreamingDelta(_ delta: String, askID: UUID) {
        guard activeAskID == askID, isAsking else { return }
        appendAssistantStreamingDelta(delta)
    }

    private func assistantConversationContext() -> [AIAssistantConversationMessage] {
        transcriptEntries.compactMap { entry in
            switch entry.role {
            case .user:
                return AIAssistantConversationMessage(
                    role: .user,
                    content: entry.conversationContent ?? entry.text
                )
            case .assistant:
                return AIAssistantConversationMessage(role: .assistant, content: entry.text)
            case .system, .command, .terminal, .plan, .step:
                return nil
            }
        }
    }

    private func userConversationContent(
        question: String,
        attachments: [AIAssistantAttachment]
    ) -> String {
        guard attachments.isEmpty == false else { return question }
        let attachmentContext = attachments.enumerated().map { index, attachment in
            "\(index + 1). \(attachment.promptSummary)"
        }
        return ([question, "附件上下文："] + attachmentContext).joined(separator: "\n")
    }

    @objc
    private func stopButtonPressed(_ sender: Any?) {
        if conversationRuntimeFactory != nil {
            guard let bridge = conversationRuntime?.bridge else {
                presentConversationRuntimeUnavailable()
                return
            }
            guard primaryActionShowsStop,
                  conversationStopRequested == false,
                  conversationRunPhase != .stopping else { return }
            conversationStopRequested = true
            updateQuestionControlState()
            // The durable bridge selection can change while an older local PTY
            // is still terminating. Stop the actual block, regardless of which
            // Runtime the selector currently displays.
            let localAgentTerminal = localAgentTerminalBlockViewController
            // Stop the visible PTY immediately. If a durable submission is still
            // crossing its commit boundary, its delivery closure observes the
            // latched stop intent and cannot launch the process again.
            if localAgentTerminal?.state.isRunning == true
                || localAgentTerminal?.state.isTerminating == true {
                localAgentTerminal?.stop()
            }
            // A send may still be crossing the durable submit boundary. Keep
            // the primary control in its stop state and defer the bridge stop
            // until that submission has settled.
            guard conversationSubmissionInFlight == false else { return }
            let requestedGeneration = conversationContextGeneration
            Task { @MainActor [weak self, weak localAgentTerminal, bridge] in
                await bridge.stop()
                guard let self else { return }
                if localAgentTerminal?.state.isRunning == true
                    || localAgentTerminal?.state.isTerminating == true {
                    localAgentTerminal?.stop()
                }
                guard self.conversationContextGeneration == requestedGeneration,
                      self.conversationRuntime?.bridge === bridge else {
                    // The stop belonged to a Runtime that was replaced while
                    // the durable boundary was settling. Do not carry its
                    // latch into the new Inspector context.
                    if self.conversationSubmissionInFlight == false {
                        self.conversationStopRequested = false
                        self.updateQuestionControlState()
                    }
                    return
                }
                self.settleConversationStopLatchIfPossible()
                self.updateQuestionControlState()
            }
            return
        }
        stopCurrentAIRequest()
    }

    private func queueComposerInput() {
        if conversationRuntimeFactory != nil {
            guard let bridge = conversationRuntime?.bridge else {
                presentConversationRuntimeUnavailable()
                return
            }
            submitConversationComposer(using: bridge, explicitlyQueued: true)
            return
        }
        askButtonPressed(nil)
    }

    private func submitConversationComposer(
        using bridge: SessionRuntimeBridge,
        explicitlyQueued: Bool
    ) {
        // Stop is a latched user intent. A Return/Option-Return arriving while
        // the stop request is crossing the bridge must never add another turn
        // or clear that latch before the current task settles.
        guard conversationSubmissionInFlight == false,
              conversationStopRequested == false,
              conversationRunPhase != .stopping else {
            updateQuestionControlState()
            return
        }
        let submittedDraft = questionField.string
        let displayText = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayText.isEmpty == false else {
            messageLabel.stringValue = L10n.AI.emptyQuestion
            messageLabel.isHidden = false
            updateQuestionControlState()
            return
        }
        var localAgentDelivery: (
            configuration: LocalAgentPassthroughConfiguration,
            preparedDirectory: LocalAgentPreparedWorkingDirectory,
            terminal: LocalAgentTerminalBlockViewController
        )?
        var legacyLocalAgentDelivery: (
            tool: LocalAgentTool,
            terminal: LocalAgentTerminalBlockViewController
        )?
        if let legacyLocalAgentTool {
            guard explicitlyQueued == false else {
                messageLabel.stringValue = "本地 CLI 兼容模式不支持排队；请停止当前终端后再发送。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
            let terminal = ensureLocalAgentTerminalBlock()
            guard terminal.selectLegacy(tool: legacyLocalAgentTool) else {
                messageLabel.stringValue = "本地 CLI 已不可用，请重新选择 Runtime 或在设置中完成配置。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
            legacyLocalAgentDelivery = (legacyLocalAgentTool, terminal)
        } else if bridge.currentRuntimeSelection.kind == .localAgent {
            guard explicitlyQueued == false else {
                messageLabel.stringValue = "Local Agent 终端透传不支持排队；请等待本次投递完成后发送。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
            guard let configuration = localAgentConfiguration(
                matching: bridge.currentRuntimeSelection
            ) else {
                messageLabel.stringValue = "所选 Local Agent 配置已失效，请在设置中重新检测并确认。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
            let terminal = ensureLocalAgentTerminalBlock()
            guard terminal.select(configuration: configuration) else {
                messageLabel.stringValue = "Local Agent 终端无法使用当前配置，请在设置中重新检测并确认。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
            if configuration.isReadyForStructuredRuntime {
                terminal.view.isHidden = true
            }
            switch terminal.prepareWorkingDirectoryForNextInput(configuration: configuration) {
            case .ready(let preparedDirectory):
                localAgentDelivery = (configuration, preparedDirectory, terminal)
            case .cancelled:
                messageLabel.stringValue = "已取消选择 Local Agent 工作目录，本次输入未发送。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            case .unavailable:
                messageLabel.stringValue = "Local Agent 工作目录不可用，本次输入未发送。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            case .changeRequiresRestart:
                messageLabel.stringValue = "Local Agent 已绑定其他工作目录，请先停止终端会话再发送。"
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
        } else {
            guard hasConfiguredAssistantModel else {
                messageLabel.stringValue = Self.unconfiguredProviderMessage
                messageLabel.isHidden = false
                updateQuestionControlState()
                return
            }
        }
        guard composerAttachments.isEmpty else {
            messageLabel.stringValue = "当前排查助手暂不支持附件，请移除附件后发送。"
            messageLabel.isHidden = false
            statusLabel.stringValue = ""
            updateQuestionControlState()
            return
        }
        let submittedText = displayText
        let submittedMode = currentTurnWorkMode
        let submittedContextGeneration = conversationContextGeneration
        let submissionID = UUID()
        dismissComposerTransientUI()
        conversationSubmissionInFlight = true
        conversationSubmissionID = submissionID
        pendingConversationComposerNotice = nil
        updateQuestionControlState()
        Task { @MainActor [weak self, bridge] in
            if let legacyLocalAgentDelivery {
                guard let self,
                      self.conversationSubmissionID == submissionID else { return }
                guard self.conversationStopRequested == false else {
                    self.conversationSubmissionInFlight = false
                    self.conversationSubmissionID = nil
                    self.settleConversationStopLatchIfPossible()
                    self.refreshComposerControls()
                    self.updateQuestionControlState()
                    self.resumeDeferredConversationContextChangeIfPossible()
                    return
                }
                let directResult = legacyLocalAgentDelivery.terminal.send(submittedText)
                guard self.conversationSubmissionID == submissionID else { return }
                self.conversationSubmissionInFlight = false
                self.conversationSubmissionID = nil
                if self.conversationStopRequested,
                   legacyLocalAgentDelivery.terminal.state.preventsRuntimeChange {
                    legacyLocalAgentDelivery.terminal.stop()
                }
                switch directResult {
                case .accepted:
                    // The CLI has accepted the bytes even if the user changed
                    // the draft or switched context while the MainActor task
                    // was waiting to run. Record the accepted request first so
                    // the transcript and audit history never lose an input
                    // that actually reached the local agent. Only mutate the
                    // current draft when it is still the submitted draft.
                    self.appendTranscript(.user, submittedText, persistHistory: true)
                    self.appendSystemTranscript(
                        "已发送到 \(legacyLocalAgentDelivery.tool.displayName) 本地 CLI；后续输出请查看终端块。"
                    )
                    let canClearCurrentDraft =
                        self.conversationContextGeneration == submittedContextGeneration
                        && self.legacyLocalAgentTool == legacyLocalAgentDelivery.tool
                        && self.questionField.string == submittedDraft
                    if canClearCurrentDraft {
                        self.questionField.string = ""
                        self.questionPlaceholderLabel.isHidden = false
                        self.composerAttachments = []
                    }
                    self.statusLabel.stringValue = ""
                case .sensitiveInputRequired:
                    self.messageLabel.stringValue = "终端正在等待敏感输入，请直接在终端中输入。"
                    self.messageLabel.isHidden = false
                case .missingExecutable, .configurationChanged, .launchBlocked,
                     .workingDirectorySelectionCancelled, .workingDirectoryUnavailable,
                     .workingDirectoryChangeRequiresRestart, .terminating, .notRunning:
                    self.messageLabel.stringValue = "本地 CLI 未能接收输入，请查看终端块状态后重试。"
                    self.messageLabel.isHidden = false
                }
                self.refreshComposerControls()
                self.updateQuestionDocumentFrame()
                self.settleConversationStopLatchIfPossible()
                self.updateQuestionControlState()
                self.resumeDeferredConversationContextChangeIfPossible()
                return
            }
            let result: SessionRuntimeBridge.SendResult
            if let localAgentDelivery {
                result = await bridge.sendToLocalAgent(
                    text: submittedText,
                    configuration: localAgentDelivery.configuration,
                    workingDirectoryReference: localAgentDelivery.preparedDirectory.localPathReference,
                    deliver: { [weak self, weak terminal = localAgentDelivery.terminal] in
                        guard let self, let terminal else { return .notRunning }
                        let selection = bridge.currentRuntimeSelection
                        // Local delivery may happen long after sendToLocalAgent
                        // returned .accepted while the global scheduler waited
                        // for capacity. Do not tie this external effect to the
                        // short-lived UI submission transaction.
                        guard self.conversationContextGeneration == submittedContextGeneration,
                              self.conversationRuntime?.bridge === bridge,
                              self.localAgentTerminalBlockViewController === terminal,
                              selection.kind == .localAgent,
                              selection.localAgentConfigurationID
                                == localAgentDelivery.configuration.configurationID,
                              selection.localAgentExecutionProfileID
                                == localAgentDelivery.configuration.executionProfileID,
                              self.conversationStopRequested == false else {
                            return .terminating
                        }
                        return terminal.send(
                            submittedText,
                            preparedWorkingDirectory: localAgentDelivery.preparedDirectory
                        )
                    }
                )
            } else {
                result = explicitlyQueued
                    ? await bridge.queue(text: submittedText)
                    : await bridge.send(text: submittedText)
            }
            guard let self,
                  self.conversationSubmissionID == submissionID else { return }
            self.conversationSubmissionInFlight = false
            self.conversationSubmissionID = nil
            let runtimeStillActive = self.conversationContextGeneration == submittedContextGeneration
                && self.conversationRuntime?.bridge === bridge
            switch result {
            case .accepted, .queued:
                if runtimeStillActive,
                   self.questionField.string == submittedDraft {
                    self.questionField.string = ""
                    self.questionPlaceholderLabel.isHidden = false
                    self.composerAttachments = []
                    if self.currentTurnWorkMode == submittedMode {
                        self.planModeEnabled = false
                        self.answerOnlyModeEnabled = false
                        self.goalModeEnabled = false
                        bridge.setWorkMode(.agent)
                    }
                    self.refreshComposerControls()
                    self.statusLabel.stringValue = ""
                }
            case .rejected(let reason):
                if runtimeStillActive {
                    self.messageLabel.stringValue = self.userMessage(for: reason)
                    self.messageLabel.isHidden = false
                }
            }
            if self.conversationStopRequested,
               runtimeStillActive {
                if localAgentDelivery?.terminal.state.isRunning == true {
                    localAgentDelivery?.terminal.stop()
                }
                await bridge.stop()
            }
            self.settleConversationStopLatchIfPossible()
            self.updateQuestionDocumentFrame()
            self.updateQuestionControlState()
            self.resumeDeferredConversationContextChangeIfPossible()
        }
    }

    private func presentConversationRuntimeUnavailable() {
        messageLabel.stringValue = conversationRunPhase == .preparing
            ? "排查会话正在初始化，请稍后重试。"
            : "排查会话运行时不可用，本次输入未发送。"
        messageLabel.isHidden = false
        statusLabel.stringValue = ""
        updateQuestionControlState()
    }

    private func userMessage(for rejection: SessionRuntimeBridge.SendRejection) -> String {
        switch rejection {
        case .empty: return L10n.AI.emptyQuestion
        case .readOnly: return "该排查会话为只读历史，不能发送新消息。"
        case .draining: return "排查助手正在停止接收新任务。"
        case .storageUnavailable: return "会话记录无法安全保存，本次输入未发送。"
        case .providerUnavailable: return Self.unconfiguredProviderMessage
        case .runtimeUnavailable: return "排查运行时不可用，本次输入未发送。"
        case .settingsUnavailable: return "无法读取排查助手设置，本次输入未发送。"
        case .targetUnavailable: return "所选终端已关闭或重连，请重新选择目标。"
        case .executionChoiceRequired: return "请先选择真实终端或后台虚拟终端。"
        case .alreadyRunning: return "当前状态暂不能提交，请等待停止或恢复完成。"
        }
    }

    @objc
    private func selectExecutionDestinationPressed(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let choice = TurnExecutionChoice(rawValue: rawValue)
        else { return }
        selectExecutionChoice(choice)
    }

    private func selectExecutionChoice(_ choice: TurnExecutionChoice) {
        guard conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false,
              choice != .ask else { return }
        selectedExecutionChoice = choice
        conversationRuntime?.updateExecutionChoice(choice)
        refreshComposerControls()
    }

    private var executionDestinationTitle: String {
        switch selectedExecutionChoice {
        case .ask:
            return "选择执行位置"
        case .realTerminal:
            return "真实终端"
        case .backgroundVirtualTerminal:
            return "后台虚拟终端"
        }
    }

    private func stopCurrentAIRequest() {
        let askCancellation = activeAskCancellation
        let hadActiveAsk = activeAskID != nil || askCancellation != nil
        let orchestrator = activeOrchestrator
        let autonomousTask = activeAutonomousTask
        let manualCommandTask = activeManualCommandTask
        let requestIDToCancel: String?
        if let activeManualCommandRequestID {
            requestIDToCancel = activeManualCommandRequestID
        } else if hadActiveAsk {
            requestIDToCancel = nil
        } else if isExecuting || orchestrator != nil || autonomousTask != nil {
            requestIDToCancel = activeTaskRequestID
        } else {
            requestIDToCancel = nil
        }

        // Invalidate callback ownership before cancellation can synchronously
        // deliver completion or trace events.
        activeAskCancellation = nil
        activeAskID = nil
        activeOrchestrator = nil
        activeAutonomousTask = nil
        activeManualCommandTask = nil
        activeManualCommandRunID = nil
        activeManualCommandRequestID = nil
        activeAutonomousRunID = nil
        isAsking = false
        isExecuting = false

        askCancellation?.cancel()
        orchestrator?.cancel()
        autonomousTask?.cancel()
        manualCommandTask?.cancel()
        retireAssistantTaskRequestsForStop(primaryRequestID: requestIDToCancel)
        if orchestrator == nil,
           let requestIDToCancel,
           let event = performTaskControl(for: requestIDToCancel, action: coordinator.cancelTask).first {
            taskControlStatusesByRequestID[requestIDToCancel] = controlStatusText(forCancelEvent: event)
            renderTaskControls(for: requestIDToCancel)
        }
        if let requestIDToCancel {
            assistantOwnedTaskRequestIDs.remove(requestIDToCancel)
            renderTaskControls(for: requestIDToCancel)
        }
        invalidateActiveAutonomousRun()
        activeStreamingAssistantIndex = nil
        endTaskModelSelectionCapture()
        statusLabel.stringValue = "已停止。"
        appendSystemTranscript("已停止，上一条 AI 回复可能是不完整的部分内容。")
        refreshHeaderStatusForCurrentContext()
        updateQuestionControlState()
    }

    private func retireAssistantTaskRequestsForStop(primaryRequestID: String?) {
        guard let primaryRequestID else { return }
        var requestIDs = Set(taskControlRequestIDs(for: primaryRequestID))
        requestIDs.insert(primaryRequestID)
        guard requestIDs.isEmpty == false else { return }
        if retiredAssistantTaskRequestIDs.count >= 256 {
            retiredAssistantTaskRequestIDs.removeAll(keepingCapacity: true)
        }
        retiredAssistantTaskRequestIDs.formUnion(requestIDs)
        assistantOwnedTaskRequestIDs.subtract(requestIDs)
        for requestID in requestIDs {
            terminalRecordingScopesByRequestID.removeValue(forKey: requestID)
        }
    }

    private func startPlanMode(
        question: String,
        requestQuestion: String,
        context: AITerminalContext,
        targetContexts: [AITerminalContext],
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment]
    ) {
        beginTaskModelSelectionCapture()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: currentAgentTaskLoopLimits(),
            targetContextsProvider: { targetContexts }
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
                self.pendingAgentPlanRequest = PendingAgentPlanRequest(
                    question: question,
                    context: context,
                    targetContexts: targetContexts,
                    attachments: attachments
                )
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
                self.pendingAgentPlanRequest = nil
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
        targetContexts: [AITerminalContext],
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment]
    ) {
        beginTaskModelSelectionCapture()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: currentAgentTaskLoopLimits(),
            targetContextsProvider: { targetContexts }
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
                    contextProvider: { context },
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
                    targetContexts: targetContexts,
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
        targetContexts: [AITerminalContext],
        attachments: [AIAssistantAttachment],
        initialResponse: AIAssistantResponse,
        introduction: String
    ) {
        beginTaskModelSelectionCapture()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: currentAgentTaskLoopLimits(),
            targetContextsProvider: { targetContexts }
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
                    contextProvider: { context },
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
                    targetContexts: targetContexts,
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
        targetContexts: [AITerminalContext],
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
        if result.stopReason == .stepLimitReached
            || result.stopReason == .modelInvocationLimitReached {
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
                targetContexts: targetContexts,
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
            "点击“\(L10n.AI.continueTask)”会沿用已有步骤历史和最后一次真实输出，再按当前边界继续排查。"
        ].joined(separator: "\n")
        taskControlLabel.stringValue = text
        taskControlText = text
        taskControlContainer.isHidden = false
    }

    private func clearPendingTaskContinuation() {
        pendingTaskContinuation = nil
        taskContinueButton.isEnabled = false
        taskContinueButton.isHidden = true
        taskControlContainer.isHidden = true
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
                captureTerminalRecordingScopeIfNeeded(for: traceEvent.requestID)
                assistantOwnedTaskRequestIDs.insert(traceEvent.requestID)
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
        guard hasActiveAIActivity == false || conversationHistoryWriteStorageID == nil else {
            return
        }
        guard let context else {
            loadedConversationHistoryRuntimeID = nil
            conversationHistoryWriteStorageID = nil
            transcriptEntries = []
            renderTranscriptEntries()
            restoreComposerDraft(for: nil)
            return
        }
        let historyScopeID = context.historyScopeID
        let threads = (try? conversationHistoryStore?.listConversationThreads(runtimeID: historyScopeID)) ?? []
        let shouldRestoreLastConversation = assistantSettingsProvider()?.restoreLastConversationEnabled ?? true
        let activeID: String
        if let selectedID = activeConversationIDs[historyScopeID] {
            activeID = selectedID
        } else if shouldRestoreLastConversation {
            activeID = threads.first?.id ?? "legacy"
        } else {
            activeID = UUID().uuidString.lowercased()
        }
        activeConversationIDs[historyScopeID] = activeID
        refreshConversationPicker(threads: threads, activeID: activeID)
        let storageID = conversationHistoryStorageID(for: context, threadID: activeID)
        restoreComposerDraft(for: storageID)
        guard loadedConversationHistoryRuntimeID != storageID else {
            conversationHistoryWriteStorageID = storageID
            return
        }
        guard let conversationHistoryStore else {
            loadedConversationHistoryRuntimeID = storageID
            conversationHistoryWriteStorageID = storageID
            transcriptEntries = []
            renderTranscriptEntries()
            return
        }
        do {
            processGroupTimings = [:]
            transcriptEntries = restoredTranscriptEntries(
                from: try conversationHistoryStore.listConversationHistory(runtimeID: storageID),
                runtimeID: context.runtimeID
            )
            loadedConversationHistoryRuntimeID = storageID
            conversationHistoryWriteStorageID = storageID
            if transcriptEntries.isEmpty == false {
                messageLabel.isHidden = true
            }
            renderTranscriptEntries()
        } catch {
            loadedConversationHistoryRuntimeID = nil
            conversationHistoryWriteStorageID = nil
            transcriptEntries = []
            renderTranscriptEntries()
        }
    }

    private func refreshConversationRuntimeForCurrentContext() {
        conversationContextRefreshPending = false
        conversationRuntimeRestoreInFlight = true
        conversationRuntimeSelectionID = nil
        conversationRuntimeSelectionInFlight = false
        // An idle Runtime from the previous context must not remain actionable
        // while the replacement is loading. Otherwise a menu action can commit
        // to the old session and its completion will correctly fail identity
        // checks but leave the new Inspector controls frozen.
        clearConversationDecisionCard()
        conversationRuntime = nil
        conversationContextGeneration &+= 1
        let generation = conversationContextGeneration
        conversationRuntimeLoadTask?.cancel()
        conversationRuntimeLoadTask = nil
        guard let context = refreshContextSummary() else {
            conversationRuntimeRestoreInFlight = false
            clearConversationDecisionCard()
            conversationRuntime = nil
            conversationCatalogEntries = []
            transcriptEntries = []
            v2ProjectedEntryIDs = [:]
            renderTranscriptEntries()
            refreshConversationPicker(threads: [], activeID: "")
            messageLabel.stringValue = pendingConversationComposerNotice ?? L10n.AI.noTerminal
            messageLabel.isHidden = false
            updateQuestionControlState()
            return
        }

        messageLabel.stringValue = pendingConversationComposerNotice ?? "正在恢复排查会话…"
        messageLabel.isHidden = false
        applyConversationRunPhase(.preparing)
        updateQuestionControlState()
        conversationRuntimeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let entries: [ConversationSessionCatalogEntry]
            do {
                entries = try await self.conversationCatalogLoader()
            } catch {
                guard generation == self.conversationContextGeneration else { return }
                self.conversationRuntimeRestoreInFlight = false
                self.clearConversationDecisionCard()
                self.conversationRuntime = nil
                self.applyConversationRunPhase(.idle)
                self.messageLabel.stringValue = self.pendingConversationComposerNotice
                    ?? "V2 会话目录无法读取，本次输入已禁用。"
                self.messageLabel.isHidden = false
                self.updateQuestionControlState()
                return
            }
            guard Task.isCancelled == false,
                  generation == self.conversationContextGeneration
            else { return }
            self.conversationCatalogEntries = entries.filter {
                $0.session.memoryScope == context.historyScopeID
                    && $0.session.archivedAt == nil
            }
            let requestedID = self.activeConversationIDs[context.historyScopeID]
            let restoreLast = self.assistantSettingsProvider()?.restoreLastConversationEnabled ?? true
            let selectedID: String
            if let requestedID,
               self.conversationCatalogEntries.contains(where: { $0.session.id == requestedID }) {
                selectedID = requestedID
            } else if restoreLast,
                      let latest = self.conversationCatalogEntries
                        .filter({ $0.isCorrupted == false })
                        .max(by: { $0.updatedAt < $1.updatedAt }) {
                selectedID = latest.session.id
            } else {
                selectedID = UUID().uuidString.lowercased()
            }
            self.activeConversationIDs[context.historyScopeID] = selectedID
            self.refreshV2ConversationPicker(activeID: selectedID)
            self.loadConversationRuntime(
                sessionID: selectedID,
                context: context,
                generation: generation
            )
        }
    }

    private func loadConversationRuntime(
        sessionID: String,
        context: AITerminalContext,
        generation: UInt64
    ) {
        guard generation == conversationContextGeneration,
              let factory = conversationRuntimeFactory
        else { return }
        let selection = modelSelectionSession.snapshot()
        do {
            let runtime = try factory(sessionID, context, selection)
            guard generation == conversationContextGeneration else { return }
            conversationRuntime = runtime
            conversationHistoryWriteStorageID = nil
            loadedConversationHistoryRuntimeID = nil
            composerDraftsByStorageID = [:]
            activeComposerDraftStorageID = nil
            bindConversationRuntime(runtime)
            conversationRuntimeLoadTask = Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime else { return }
                let restored = await runtime.bridge.restoreFromRepository(runtime.repository)
                guard Task.isCancelled == false,
                      generation == self.conversationContextGeneration,
                      self.conversationRuntime === runtime
                else { return }
                self.conversationRuntimeRestoreInFlight = false
                if restored == false,
                   let failure = runtime.bridge.currentUserFacingError {
                    self.applyConversationRunPhase(.idle)
                    self.messageLabel.stringValue = self.pendingConversationComposerNotice ?? failure
                    self.messageLabel.isHidden = false
                    self.updateQuestionControlState()
                    return
                }
                if let pendingPrefill = self.pendingConversationPrefill {
                    self.pendingConversationPrefill = nil
                    self.applyConversationDraft(pendingPrefill)
                    runtime.bridge.updateDraft(pendingPrefill)
                }
                // The Bridge owns recovery semantics. In particular,
                // interruptedByRelaunch and passthroughInputDelivered retain a
                // terminal Attempt for history but have no Runtime to stop.
                self.applyConversationRunPhase(runtime.bridge.currentRunPhase)
                if let notice = self.pendingConversationComposerNotice {
                    self.messageLabel.stringValue = notice
                    self.messageLabel.isHidden = false
                } else {
                    self.messageLabel.isHidden = self.transcriptEntries.isEmpty == false
                }
                if self.transcriptEntries.isEmpty,
                   self.pendingConversationComposerNotice == nil {
                    self.messageLabel.stringValue = L10n.AI.ready
                }
                self.updateQuestionControlState()
            }
        } catch {
            conversationRuntimeRestoreInFlight = false
            clearConversationDecisionCard()
            conversationRuntime = nil
            applyConversationRunPhase(.idle)
            transcriptEntries = []
            v2ProjectedEntryIDs = [:]
            renderTranscriptEntries()
            messageLabel.stringValue = pendingConversationComposerNotice
                ?? "排查会话无法安全初始化，本次输入已禁用。"
            messageLabel.isHidden = false
            updateQuestionControlState()
        }
    }

    private func refreshV2ConversationPicker(activeID: String) {
        conversationPopUpButton.removeAllItems()
        var entries = conversationCatalogEntries.sorted { $0.updatedAt > $1.updatedAt }
        if entries.contains(where: { $0.session.id == activeID }) == false {
            var transient = ConversationV2StorageFactory.makeInitialSessionState(
                sessionID: activeID
            ).session
            transient.title = "新排查会话"
            entries.insert(ConversationSessionCatalogEntry(
                session: transient,
                latestAttemptPhase: nil,
                updatedAt: transient.updatedAt,
                isCorrupted: false
            ), at: 0)
        }
        for (index, entry) in entries.enumerated() {
            let title = entry.isCorrupted
                ? "会话不可用"
                : (entry.session.title.isEmpty ? "排查会话 \(index + 1)" : entry.session.title)
            conversationPopUpButton.addItem(withTitle: title)
            conversationPopUpButton.lastItem?.representedObject = entry.session.id
            conversationPopUpButton.lastItem?.isEnabled = entry.isCorrupted == false
        }
        if let index = entries.firstIndex(where: { $0.session.id == activeID }) {
            conversationPopUpButton.selectItem(at: index)
        }
    }

    private func refreshConversationPicker(
        threads: [AIAssistantConversationThreadSummary],
        activeID: String
    ) {
        conversationPopUpButton.removeAllItems()
        let visibleThreads = threads.contains(where: { $0.id == activeID })
            ? threads
            : [AIAssistantConversationThreadSummary(
                id: activeID,
                title: "新排查会话",
                latestMessageAt: ""
            )] + threads
        for (index, thread) in visibleThreads.enumerated() {
            conversationPopUpButton.addItem(withTitle: thread.title.isEmpty ? "排查会话 \(index + 1)" : thread.title)
            conversationPopUpButton.lastItem?.representedObject = thread.id
        }
        if let index = visibleThreads.firstIndex(where: { $0.id == activeID }) {
            conversationPopUpButton.selectItem(at: index)
        }
    }

    @objc private func newConversationButtonPressed(_ sender: Any?) {
        if conversationRuntimeFactory != nil {
            guard conversationContextTransitionBlocked == false,
                  let context = resolvedTargetContext()
            else { return }
            activeConversationIDs[context.historyScopeID] = UUID().uuidString.lowercased()
            refreshConversationRuntimeForCurrentContext()
            return
        }
        guard hasActiveAIActivity == false else { return }
        guard let historyScopeID = resolvedTargetContext()?.historyScopeID else { return }
        saveActiveComposerDraft()
        cancelPendingStreamingTranscriptRender()
        activeConversationIDs[historyScopeID] = UUID().uuidString.lowercased()
        loadedConversationHistoryRuntimeID = nil
        activeStreamingAssistantIndex = nil
        transcriptEntries = []
        processGroupTimings = [:]
        messageLabel.isHidden = false
        loadConversationHistory(for: resolvedTargetContext())
    }

    @objc private func conversationSelectionChanged(_ sender: Any?) {
        if conversationRuntimeFactory != nil {
            guard conversationContextTransitionBlocked == false,
                  let context = resolvedTargetContext(),
                  let sessionID = conversationPopUpButton.selectedItem?.representedObject as? String
            else { return }
            activeConversationIDs[context.historyScopeID] = sessionID
            refreshConversationRuntimeForCurrentContext()
            return
        }
        guard hasActiveAIActivity == false else { return }
        guard let historyScopeID = resolvedTargetContext()?.historyScopeID,
              let threadID = conversationPopUpButton.selectedItem?.representedObject as? String
        else { return }
        saveActiveComposerDraft()
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
        guard hasActiveAIActivity == false,
              conversationSubmissionInFlight == false,
              conversationRuntimeFactory == nil || conversationContextTransitionBlocked == false
        else { return }
        let picker = AITargetPickerViewController(
            sessions: terminalSessionProvider(),
            allowsMultipleSelection: conversationRuntimeFactory == nil,
            initiallySelectedRuntimeIDs: selectedRuntimeIDs
        )
        picker.onSelectRuntimeID = { [weak self] runtimeID in
            guard let self,
                  self.conversationSubmissionInFlight == false,
                  self.conversationRuntimeFactory == nil
                    || self.conversationContextTransitionBlocked == false
            else { return }
            self.selectedRuntimeID = runtimeID
            self.selectedRuntimeIDs = [runtimeID]
            self.refreshForCurrentContext()
            self.dismiss(picker)
        }
        picker.onConfirmRuntimeIDs = { [weak self] runtimeIDs in
            guard let self,
                  self.conversationSubmissionInFlight == false,
                  self.conversationRuntimeFactory == nil
                    || self.conversationContextTransitionBlocked == false
            else { return }
            let normalized = runtimeIDs.filter { $0.isEmpty == false }
            guard normalized.isEmpty == false else { return }
            self.selectedRuntimeIDs = self.conversationRuntimeFactory == nil
                ? normalized
                : [normalized[0]]
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
        sensitiveInputField.stringValue = ""
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
        let limits = currentAgentTaskLoopLimits()
        let orchestrator = AgentTaskOrchestrator(
            coordinator: coordinator,
            limits: limits,
            targetContextsProvider: { continuation.targetContexts }
        )
        activeOrchestrator = orchestrator
        activeAutonomousTask?.cancel()
        let runID = beginAutonomousRun()
        isExecuting = true
        statusLabel.stringValue = "已继续，最多再执行 \(limits.maxSteps) 个命令步骤。"
        refreshHeaderStatus(context: continuation.context)
        updateQuestionControlState()
        appendSystemTranscript(statusLabel.stringValue)
        activeAutonomousTask = Task { [weak self, orchestrator, runID] in
            do {
                let result = try await orchestrator.run(
                    goal: continuation.goal,
                    context: continuation.context,
                    contextProvider: { continuation.context },
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
                    targetContexts: continuation.targetContexts,
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
        guard let plan = currentAgentPlan,
              let request = pendingAgentPlanRequest
        else { return }
        let context = request.context
        planWorkspaceContainer.isHidden = true
        planWorkspaceConfirmButton.isEnabled = false
        planWorkspaceEditButton.isEnabled = false
        planWorkspaceCancelButton.isEnabled = false
        appendSystemTranscript("计划已确认，我开始按顺序执行。")
        setCommandProposals([])
        currentProposalTaskRequestID = nil
        currentAgentPlan = nil
        pendingAgentPlanRequest = nil
        let initialResponse = AIAssistantResponse(
            message: plan.summary,
            commandProposals: plan.steps.map {
                AgentCommandProposal(command: $0.command, explanation: $0.intent, risk: $0.risk)
            }
        )
        startStepwiseAutoRun(
            question: request.question,
            goal: plan.goal,
            context: context,
            targetContexts: request.targetContexts,
            attachments: request.attachments,
            initialResponse: initialResponse,
            introduction: "计划已确认。我先执行第一步，拿到真实输出后再决定下一步。"
        )
    }

    @objc
    private func planEditPressed(_ sender: Any?) {
        guard let plan = currentAgentPlan else { return }
        prefillQuestion(plan.steps.map(\.command).joined(separator: " && "))
        pendingAgentPlanRequest = nil
        appendSystemTranscript("已把计划命令放回输入框，你可以编辑后重新发送。")
        updateQuestionControlState()
    }

    @objc
    private func planCancelPressed(_ sender: Any?) {
        currentAgentPlan = nil
        pendingAgentPlanRequest = nil
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

    private func runCommand(
        _ command: String,
        from card: AICommandCardView?,
        announcePreparation: Bool = true
    ) {
        guard activeManualCommandRunID == nil else {
            statusLabel.stringValue = "当前命令仍在运行，请先停止或接管后再执行下一条命令。"
            return
        }
        guard command.isEmpty == false, let context = refreshContextSummary() else {
            statusLabel.stringValue = L10n.AI.noTerminal
            return
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
        let runID = UUID()
        activeManualCommandRunID = runID
        activeManualCommandRequestID = requestID
        activeTaskRequestID = requestID
        captureTerminalRecordingScopeIfNeeded(for: requestID)
        assistantOwnedTaskRequestIDs.insert(requestID)
        let coordinator = coordinator
        activeManualCommandTask = Task { [weak self, weak card] in
            defer {
                if let self, self.activeManualCommandRunID == runID {
                    self.activeManualCommandTask = nil
                    self.activeManualCommandRunID = nil
                    self.activeManualCommandRequestID = nil
                    self.isExecuting = false
                    self.refreshHeaderStatusForCurrentContext()
                    self.updateCommandButtonState()
                }
            }
            do {
                var streamedEvents: [AgentTraceEvent] = []
                let events = try await coordinator.executeProposedCommandAsync(
                    command,
                    contexts: contexts.isEmpty ? [context] : contexts,
                    requestID: requestID,
                    emit: { [weak self] event in
                        guard let self,
                              self.activeManualCommandRunID == runID,
                              Task.isCancelled == false
                        else { return }
                        self.assistantOwnedTaskRequestIDs.insert(event.requestID)
                        streamedEvents.append(event)
                        self.appendTraceEvent(event, runtimeTitle: context.title, allEvents: nil)
                        self.updateStatusFromTrace(event)
                    }
                )
                try Task.checkCancellation()
                guard let self, self.activeManualCommandRunID == runID else { return }
                self.registerTaskControlRequestIDs(events)
                if let eventRequestID = events.first?.requestID,
                   eventRequestID != requestID,
                   let pendingConclusion = self.pendingAssistantConclusionsByRequestID.removeValue(forKey: requestID) {
                    self.pendingAssistantConclusionsByRequestID[eventRequestID] = pendingConclusion
                    if let finalEvent = events.last(where: {
                        $0.requestID == eventRequestID && self.isTerminalTraceState($0.state)
                    }) {
                        self.appendPendingAssistantConclusionIfReady(for: finalEvent)
                    }
                }
                if streamedEvents.isEmpty {
                    self.appendTraceEvents(events, runtimeTitle: context.title)
                }
                if let terminalEvent = self.terminalExecutionEvent(from: events) {
                    switch terminalEvent.state {
                    case .failed:
                        card?.updateState(.failed)
                        self.statusLabel.stringValue = terminalEvent.message
                        self.appendSystemTranscript("执行失败：\(terminalEvent.message)")
                        self.setFailedRetryCommand(command)
                        return
                    case .cancelled:
                        card?.updateState(.failed)
                        self.statusLabel.stringValue = terminalEvent.message
                        self.appendSystemTranscript(terminalEvent.message)
                        self.setFailedRetryCommand(command)
                        return
                    case .paused, .takenOver:
                        card?.updateState(.running)
                        self.statusLabel.stringValue = terminalEvent.message
                        self.appendSystemTranscript(terminalEvent.message)
                    default:
                        card?.updateState(.running)
                        self.statusLabel.stringValue = self.statusText(forTerminalExecutionEvent: terminalEvent)
                    }
                } else {
                    card?.updateState(.running)
                    self.statusLabel.stringValue = L10n.AI.sentToTerminal
                }
                self.setCommandProposals([])
            } catch {
                guard Task.isCancelled == false, !(error is CancellationError) else { return }
                guard let self, self.activeManualCommandRunID == runID else { return }
                self.finishManualProcessGroupIfNeeded(for: requestID)
                card?.updateState(.failed)
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                self.statusLabel.stringValue = message
                self.appendSystemTranscript("执行失败：\(message)")
                self.setFailedRetryCommand(command)
            }
        }
    }

    private func cancelActiveManualCommandTask() {
        activeManualCommandRunID = nil
        activeManualCommandRequestID = nil
        activeManualCommandTask?.cancel()
        activeManualCommandTask = nil
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

    private func observeAssistantSettingsChanges() {
        guard assistantSettingsObserver == nil else { return }
        assistantSettingsObserver = NotificationCenter.default.addObserver(
            forName: .stacioAssistantSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAssistantComposerSettings()
        }
    }

    private func refreshAssistantComposerSettings() {
        let sendKeyMode = assistantSettingsProvider()?.sendKeyMode
        questionField.sendKeyMode = sendKeyMode == "commandReturn"
            ? .commandReturnSends
            : .returnSends
    }

    private func currentAgentTaskLoopLimits() -> AgentTaskLoopLimits {
        guard let settings = assistantSettingsProvider() else {
            return fallbackAgentTaskLoopLimits
        }
        return AgentTaskLoopLimits(
            maxSteps: settings.maxToolSteps,
            maxDuration: TimeInterval(settings.maxEffectiveMinutes) * 60,
            maxModelInvocations: settings.maxModelInvocations
        )
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

    private func capturedTargetContexts(primary: AITerminalContext) -> [AITerminalContext] {
        var contexts = resolvedTargetContexts()
        if let index = contexts.firstIndex(where: { $0.runtimeID == primary.runtimeID }) {
            contexts[index] = primary
        } else {
            contexts.insert(primary, at: 0)
        }
        var seen = Set<String>()
        return contexts.filter { seen.insert($0.runtimeID).inserted }
    }

    private func resolvedTargetContexts() -> [AITerminalContext] {
        let ids: [String]
        if conversationRuntimeFactory != nil,
           let runtimeID = conversationRuntime?.bridge.currentTargetRuntimeID {
            ids = [runtimeID]
        } else {
            ids = selectedRuntimeIDs.isEmpty
                ? selectedRuntimeID.map { [$0] } ?? []
                : selectedRuntimeIDs
        }
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
        guard conversationRuntimeFactory == nil else { return question }
        var contextLines: [String] = []
        if planModeEnabled {
            contextLines.append("排查计划模式：先按运维依赖关系拆解检查或部署步骤，标注每步风险、预期证据和验证路径；用户确认前只输出计划，不执行命令。")
        }
        if goalModeEnabled {
            contextLines.append("持续排查模式：只围绕当前运维故障或应用部署目标逐步推进；每一步都依据真实终端证据选择下一步，并以可验证的完成标准结束。")
        }
        guard contextLines.isEmpty == false else {
            return question
        }
        return ([question, ""] + contextLines).joined(separator: "\n")
    }

    private func refreshComposerControls() {
        if conversationRuntimeFactory != nil {
            let summary = "工作方式：\(currentTurnWorkMode.displayName) · \(executionDestinationTitle)"
            composerAddButton.toolTip = summary
            composerAddButton.setAccessibilityLabel(summary)
        }
        composerPermissionButton.title = permissionTitle(for: settingsStore.snapshot().agentConfirmationPolicy)
        composerPermissionButton.toolTip = "修改 AI 命令审批权限"
        composerPermissionButton.setAccessibilityLabel(composerPermissionButton.title)
        composerModelButton.title = currentModelTitle()
        composerModelButton.toolTip = hasConfiguredConversationRuntime
            ? composerModelButton.title
            : Self.unconfiguredProviderMessage
        composerModelButton.setAccessibilityLabel(composerModelButton.title)
        renderComposerAttachments()
        let context = composerContextItems()
        composerContextLabel.stringValue = context.joined(separator: " · ")
        composerContextLabel.isHidden = context.isEmpty
        updateComposerHeight()
        updateQuestionControlState()
    }

    private func composerContextItems() -> [String] {
        if conversationRuntimeFactory != nil {
            return [currentTurnWorkMode.displayName, executionDestinationTitle]
        }
        var items: [String] = []
        if planModeEnabled {
            items.append("计划模式")
        }
        if answerOnlyModeEnabled {
            items.append("仅回答")
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
        let questionHeight = questionHeightConstraint?.constant ?? Self.minimumQuestionHeight
        let expandedQuestionHeight = max(0, questionHeight - Self.minimumQuestionHeight)
        let baseHeight: CGFloat
        if composerAttachments.isEmpty == false {
            baseHeight = Self.attachmentComposerHeight
        } else if composerContextItems().isEmpty == false {
            baseHeight = Self.contextComposerHeight
        } else {
            baseHeight = Self.compactComposerHeight
        }
        let targetHeight = baseHeight + expandedQuestionHeight
        if abs((composerHeightConstraint?.constant ?? 0) - targetHeight) > 0.5 {
            composerHeightConstraint?.constant = targetHeight
            view.needsLayout = true
        }
    }

    private func updateQuestionDocumentFrame() {
        let viewportWidth = floor(questionScrollView.contentView.bounds.width)
        guard viewportWidth > 1,
              let textContainer = questionField.textContainer,
              let layoutManager = questionField.layoutManager
        else {
            updateComposerHeight()
            return
        }

        if abs(questionField.frame.width - viewportWidth) > 0.5 {
            questionField.frame.size.width = viewportWidth
        }
        textContainer.containerSize = NSSize(
            width: viewportWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = true
        layoutManager.ensureLayout(for: textContainer)

        let font = questionField.font ?? .systemFont(ofSize: 14)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let textWidth = max(
            1,
            viewportWidth
                - questionField.textContainerInset.width * 2
                - textContainer.lineFragmentPadding * 2
        )
        let attributedText = NSMutableAttributedString(attributedString: questionField.attributedString())
        if attributedText.length > 0 {
            attributedText.addAttribute(
                .font,
                value: font,
                range: NSRange(location: 0, length: attributedText.length)
            )
        }
        let measuredTextHeight = attributedText.boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let usedTextHeight = max(
            lineHeight,
            ceil(layoutManager.usedRect(for: textContainer).height),
            ceil(measuredTextHeight)
        )
        let documentHeight = usedTextHeight + questionField.textContainerInset.height * 2
        let targetViewportHeight = min(
            Self.maximumQuestionHeight,
            max(Self.minimumQuestionHeight, ceil(documentHeight))
        )
        if abs((questionHeightConstraint?.constant ?? 0) - targetViewportHeight) > 0.5 {
            questionHeightConstraint?.constant = targetViewportHeight
        }

        let targetDocumentHeight = max(targetViewportHeight, ceil(documentHeight))
        if abs(questionField.frame.height - targetDocumentHeight) > 0.5 {
            questionField.frame.size.height = targetDocumentHeight
        }
        updateComposerHeight()
    }

    private func dismissComposerTransientUI() {
        let popovers = [
            composerPermissionPickerPopover,
            composerModelPickerPopover,
            composerAddPickerPopover
        ]
        if let visiblePopover = popovers.compactMap({ $0 }).first(where: \ .isShown) {
            visiblePopover.performClose(nil)
            return
        }
        guard composerPreviewWindow?.isVisible == true else { return }
        composerPreviewWindow?.performClose(nil)
        composerPreviewWindow = nil
    }

    private func sentQuestionHistory() -> [String] {
        transcriptEntries.compactMap { entry in
            guard entry.role == .user else { return nil }
            let question = entry.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return question.isEmpty ? nil : question
        }
    }

    /// The Inspector transcript is the durable, user-visible history. A V2
    /// bridge can also contain a just-committed request before its projection
    /// reaches the legacy stack, so append only bridge entries that are not
    /// already represented, preserving repeated questions with a small
    /// multiset count instead of collapsing legitimate duplicates.
    private func composerQuestionHistory(with bridgeHistory: [String]) -> [String] {
        var history = sentQuestionHistory()
        var remainingCounts: [String: Int] = [:]
        for question in history {
            remainingCounts[question, default: 0] += 1
        }
        for question in bridgeHistory {
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if let count = remainingCounts[trimmed], count > 0 {
                remainingCounts[trimmed] = count - 1
            } else {
                history.append(trimmed)
            }
        }
        return history
    }

    private func saveActiveComposerDraft() {
        guard let storageID = activeComposerDraftStorageID else { return }
        let draft = InspectorComposerDraft(
            text: questionField.string,
            attachments: composerAttachments,
            planModeEnabled: planModeEnabled,
            answerOnlyModeEnabled: answerOnlyModeEnabled,
            goalModeEnabled: goalModeEnabled,
            modelSelection: modelSelectionSession.snapshot()
        )
        if draft.text.isEmpty,
           draft.attachments.isEmpty,
           draft.planModeEnabled == false,
           draft.answerOnlyModeEnabled == false,
           draft.goalModeEnabled == false,
           draft.modelSelection == initialComposerModelSelection {
            composerDraftsByStorageID[storageID] = nil
        } else {
            composerDraftsByStorageID[storageID] = draft
        }
    }

    private func restoreComposerDraft(for storageID: String?) {
        activeComposerDraftStorageID = storageID
        let draft = storageID.flatMap { composerDraftsByStorageID[$0] }
        questionField.string = draft?.text ?? ""
        questionField.setSelectedRange(NSRange(location: (questionField.string as NSString).length, length: 0))
        composerAttachments = draft?.attachments ?? []
        planModeEnabled = draft?.planModeEnabled ?? false
        answerOnlyModeEnabled = draft?.answerOnlyModeEnabled ?? false
        goalModeEnabled = draft?.goalModeEnabled ?? false
        if let draft {
            modelSelectionSession.select(draft.modelSelection)
        } else {
            modelSelectionSession.select(initialComposerModelSelection)
        }
        reconcileTemporaryModelSelection()
        questionPlaceholderLabel.isHidden = questionField.string.isEmpty == false
        updateQuestionDocumentFrame()
        refreshComposerControls()
    }

    private func discardActiveComposerDraft() {
        guard let storageID = activeComposerDraftStorageID else { return }
        composerDraftsByStorageID[storageID] = nil
    }

    private func removeComposerAttachment(at index: Int) {
        guard composerAttachments.indices.contains(index) else { return }
        composerAttachments.remove(at: index)
        saveActiveComposerDraft()
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
        if let legacyLocalAgentTool {
            return "Local Agent · \(legacyLocalAgentTool.displayName)"
        }
        if conversationRuntimeFactory != nil,
           let bridge = conversationRuntime?.bridge,
           bridge.currentRuntimeSelection.kind == .localAgent {
            return localAgentConfiguration(matching: bridge.currentRuntimeSelection).map {
                "Local Agent · \($0.displayName)"
            } ?? "Local Agent · 配置不可用"
        }
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
            guard provider.profile.usesModelInterface,
                  AIProviderRuntimeEligibility.isConfigurationRunnable(provider)
            else {
                return nil
            }
            let selections = provider.models.compactMap { model -> AIModelSelection? in
                let modelID = AppSettings.normalizedAIModelName(model.id)
                guard modelID.isEmpty == false,
                      AIProviderRuntimeEligibility.isModelRunnable(model, in: provider)
                else {
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
        let requestedSelection = modelSelectionSession.snapshot()
        switch AIProviderRuntimeResolver.resolve(
            envelope: envelope,
            requestedSelection: requestedSelection
        ) {
        case let .external(provider, modelID):
            return (
                AIModelSelection(providerID: provider.id, modelID: modelID),
                provider.displayName,
                provider.models.first(where: { $0.id == modelID })
            )
        case let .unconfigured(provider):
            if requestedSelection != nil {
                let title = provider.map { "\($0.displayName) · 所选模型不可用" }
                    ?? "所选模型不可用"
                return (nil, title, nil)
            }
            let title = provider.map { "\($0.displayName) · 未配置模型" } ?? "未选择供应商"
            return (nil, title, nil)
        case let .credentialOriginConfirmationRequired(provider, _):
            return (nil, "\(provider.displayName) · 需确认 API Key 目标", nil)
        }
    }

    private var hasConfiguredAssistantModel: Bool {
        switch AIProviderRuntimeResolver.resolve(
            envelope: normalizedProviderEnvelope(),
            requestedSelection: modelSelectionSession.snapshot()
        ) {
        case .external:
            return true
        case .unconfigured, .credentialOriginConfirmationRequired:
            return false
        }
    }

    private var hasConfiguredConversationRuntime: Bool {
        guard conversationRuntimeFactory != nil,
              let selection = conversationRuntime?.bridge.currentRuntimeSelection
        else {
            if let legacyLocalAgentTool,
               localAgentToolResolver.legacyExecutablePath(for: legacyLocalAgentTool) != nil {
                return true
            }
            return hasConfiguredAssistantModel
        }
        if let legacyLocalAgentTool,
           localAgentToolResolver.legacyExecutablePath(for: legacyLocalAgentTool) != nil {
            return true
        }
        if selection.kind == .localAgent {
            return localAgentConfiguration(matching: selection) != nil
        }
        return hasConfiguredAssistantModel
    }

    private func reconcileTemporaryModelSelection() {
        let envelope = normalizedProviderEnvelope()
        let currentSelection = modelSelectionSession.snapshot()
        let normalizedSelection = Self.normalizedTemporaryModelSelection(
            currentSelection,
            envelope: envelope
        )
        if normalizedSelection != currentSelection {
            modelSelectionSession.select(normalizedSelection)
        }
    }

    private static func normalizedTemporaryModelSelection(
        _ selection: AIModelSelection?,
        envelope: AIProviderSettingsEnvelope
    ) -> AIModelSelection? {
        guard let selection,
              selection.providerID != BuiltInAIProvider.stacioRulesID
        else {
            return nil
        }
        let normalizedModelID = AppSettings.normalizedAIModelName(selection.modelID)
        // Keep an explicit selection even when its provider or model becomes
        // unavailable. The resolver will block submission and the picker can
        // show the stale identity, so a settings change never turns into an
        // implicit switch to the global default.
        guard normalizedModelID.isEmpty == false else { return selection }
        return AIModelSelection(
            providerID: selection.providerID,
            modelID: normalizedModelID
        )
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
        if conversationRuntimeFactory == nil {
            menu.addItem(makeComposerToggleMenuItem(title: "追求目标", action: #selector(toggleGoalModePressed(_:)), state: goalModeEnabled))
        }
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
            title: conversationRuntimeFactory == nil ? "跟随全局默认" : "使用全局默认",
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
        guard conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false else { return }
        if conversationRuntimeFactory != nil {
            popUpComposerMenu(composerWorkModeMenu(), from: sender)
            return
        }
        showComposerAddPicker(from: sender)
    }

    private func composerWorkModeMenu() -> NSMenu {
        let menu = NSMenu()
        let selectedMode = currentTurnWorkMode
        for mode in TurnWorkMode.allCases {
            let item = makeComposerMenuItem(
                title: mode.displayName,
                action: #selector(selectComposerWorkModePressed(_:)),
                representedObject: mode.rawValue
            )
            item.state = mode == selectedMode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let executionChoices: [(String, TurnExecutionChoice)] = [
            ("真实终端", .realTerminal),
            ("后台虚拟终端", .backgroundVirtualTerminal)
        ]
        for (title, choice) in executionChoices {
            let item = makeComposerMenuItem(
                title: title,
                action: #selector(selectExecutionDestinationPressed(_:)),
                representedObject: choice.rawValue
            )
            item.state = choice == selectedExecutionChoice ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private var currentTurnWorkMode: TurnWorkMode {
        if answerOnlyModeEnabled { return .answerOnly }
        if planModeEnabled { return .planFirst }
        return .agent
    }

    @objc
    private func selectComposerWorkModePressed(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = TurnWorkMode(rawValue: rawValue)
        else { return }
        selectComposerWorkMode(mode)
    }

    private func selectComposerWorkMode(_ mode: TurnWorkMode) {
        guard conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false else { return }
        planModeEnabled = mode == .planFirst
        answerOnlyModeEnabled = mode == .answerOnly
        goalModeEnabled = false
        conversationRuntime?.bridge.setWorkMode(mode)
        saveActiveComposerDraft()
        refreshComposerControls()
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
        guard conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false else { return }
        planModeEnabled.toggle()
        answerOnlyModeEnabled = false
        conversationRuntime?.bridge.setWorkMode(planModeEnabled ? .planFirst : .agent)
        saveActiveComposerDraft()
        refreshComposerControls()
    }

    @objc
    private func toggleGoalModePressed(_ sender: NSMenuItem) {
        guard conversationRuntimeFactory == nil else {
            goalModeEnabled = false
            refreshComposerControls()
            return
        }
        goalModeEnabled.toggle()
        saveActiveComposerDraft()
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
        guard conversationRuntimeFactory == nil else {
            presentConversationAttachmentUnsupported()
            return
        }
        let urls = attachmentPicker()
        guard urls.isEmpty == false else { return }
        addComposerAttachmentURLs(urls)
    }

    private func addCurrentRemoteFileContext() {
        guard conversationRuntimeFactory == nil else {
            presentConversationAttachmentUnsupported()
            return
        }
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
        guard conversationRuntimeFactory == nil else {
            presentConversationAttachmentUnsupported()
            return
        }
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
        if added.isEmpty == false {
            saveActiveComposerDraft()
        }
        refreshComposerControls()
        if added.isEmpty == false {
            statusLabel.stringValue = "已添加附件：\(added.map(\.filename).joined(separator: "、"))"
        } else if failed.isEmpty == false {
            statusLabel.stringValue = "附件读取失败：\(failed.joined(separator: "、"))"
        }
    }

    private func addComposerAttachments(from pasteboard: NSPasteboard) -> Bool {
        if conversationRuntimeFactory != nil {
            let containsAttachment = pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: nil
            ) || NSImage(pasteboard: pasteboard) != nil
            if containsAttachment {
                presentConversationAttachmentUnsupported()
            }
            return containsAttachment
        }
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

    private func presentConversationAttachmentUnsupported(
        _ message: String = "当前排查助手暂不支持附件，请直接描述问题或粘贴必要的脱敏文本。"
    ) {
        pendingConversationComposerNotice = message
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        statusLabel.stringValue = ""
        updateQuestionControlState()
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
            saveActiveComposerDraft()
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
        guard composerAttachments.isEmpty == false
                || planModeEnabled
                || answerOnlyModeEnabled
                || goalModeEnabled
        else {
            return
        }
        composerAttachments = []
        planModeEnabled = false
        answerOnlyModeEnabled = false
        goalModeEnabled = false
        refreshComposerControls()
    }

    private func clearComposerAttachmentsAfterSend() {
        guard composerAttachments.isEmpty == false else { return }
        composerAttachments = []
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
            currentFileEnabled: currentRemoteFileAttachmentAvailable(),
            showsAttachments: conversationRuntimeFactory == nil,
            showsGoalMode: conversationRuntimeFactory == nil
        )
        if conversationRuntimeFactory == nil {
            picker.onAddFiles = { [weak self] in
                self?.addSelectedComposerAttachments()
            }
            picker.onAddCurrentFile = { [weak self] in
                self?.addCurrentRemoteFileContext()
            }
        }
        picker.onTogglePlan = { [weak self] in
            guard let self,
                  self.conversationSubmissionInFlight == false,
                  self.conversationRuntimeSelectionInFlight == false else { return }
            self.planModeEnabled.toggle()
            self.answerOnlyModeEnabled = false
            self.conversationRuntime?.bridge.setWorkMode(
                self.planModeEnabled ? .planFirst : .agent
            )
            self.saveActiveComposerDraft()
            self.refreshComposerControls()
            self.refreshComposerAddPicker()
        }
        if conversationRuntimeFactory == nil {
            picker.onToggleGoal = { [weak self] in
                self?.goalModeEnabled.toggle()
                self?.saveActiveComposerDraft()
                self?.refreshComposerControls()
                self?.refreshComposerAddPicker()
            }
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
        let effectiveSelection = selection?.providerID == BuiltInAIProvider.stacioRulesID
            ? nil
            : selection
        guard conversationRuntimeFactory != nil else {
            guard hasActiveAIActivity == false,
                  conversationSubmissionInFlight == false,
                  capturedTaskModelSelection == nil else {
                return
            }
            modelSelectionSession.select(effectiveSelection)
            saveActiveComposerDraft()
            refreshComposerControls()
            _ = refreshContextSummary()
            return
        }
        guard conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false else { return }
        let durableSelection: AIModelSelection
        if let effectiveSelection {
            durableSelection = effectiveSelection
        } else {
            switch AIProviderRuntimeResolver.resolve(
                envelope: normalizedProviderEnvelope(),
                requestedSelection: nil
            ) {
            case let .external(provider, modelID):
                durableSelection = AIModelSelection(
                    providerID: provider.id,
                    modelID: modelID
                )
            case .unconfigured, .credentialOriginConfirmationRequired:
                messageLabel.stringValue = Self.unconfiguredProviderMessage
                messageLabel.isHidden = false
                statusLabel.stringValue = ""
                refreshComposerControls()
                refreshComposerModelPicker()
                updateQuestionControlState()
                return
            }
        }
        guard let bridge = conversationRuntime?.bridge else {
            presentConversationRuntimeUnavailable()
            refreshComposerControls()
            refreshComposerModelPicker()
            return
        }
        guard bridge.allowsAlternateRuntimeSelection else {
            messageLabel.stringValue = bridge.queuedCount > 0
                ? "请先处理当前会话的待发送队列，再切换供应商或模型。"
                : "当前会话状态不允许切换供应商或模型。"
            messageLabel.isHidden = false
            updateQuestionControlState()
            return
        }
        if localAgentTerminalBlockViewController?.state.preventsRuntimeChange == true {
            messageLabel.stringValue = "请先停止当前 Local Agent 终端会话，再切换供应商或模型。"
            messageLabel.isHidden = false
            updateQuestionControlState()
            return
        }

        let runtime = conversationRuntime
        let generation = conversationContextGeneration
        let selectionID = UUID()
        conversationRuntimeSelectionID = selectionID
        conversationRuntimeSelectionInFlight = true
        messageLabel.stringValue = "正在切换供应商和模型…"
        messageLabel.isHidden = false
        updateQuestionControlState()
        Task { @MainActor [weak self, weak runtime, weak bridge] in
            guard let self, let runtime, let bridge else { return }
            let switched = await bridge.selectNativeRuntime(
                preferredConfigurationID: durableSelection.providerID.uuidString,
                preferredModelID: durableSelection.modelID
            )
            guard self.conversationRuntimeSelectionID == selectionID else { return }
            guard self.conversationContextGeneration == generation,
                  self.conversationRuntime === runtime,
                  runtime.bridge === bridge
            else {
                self.conversationRuntimeSelectionID = nil
                self.conversationRuntimeSelectionInFlight = false
                self.refreshComposerControls()
                self.refreshComposerModelPicker()
                self.updateQuestionControlState()
                return
            }
            self.conversationRuntimeSelectionID = nil
            self.conversationRuntimeSelectionInFlight = false
            if switched {
                self.legacyLocalAgentTool = nil
                _ = self.localAgentTerminalBlockViewController?.deactivateIfStopped()
                self.applyModelSelectionFromConversationRuntime(bridge.currentRuntimeSelection)
                self.messageLabel.stringValue = ""
                self.messageLabel.isHidden = self.transcriptEntries.isEmpty == false
                self.statusLabel.stringValue = "已切换到所选供应商和模型。"
            } else {
                self.messageLabel.stringValue = "所选供应商或模型当前不可用，已保留原选择；请重新选择或检查供应商配置。"
                self.messageLabel.isHidden = false
                self.statusLabel.stringValue = ""
            }
            self.refreshComposerControls()
            self.refreshComposerModelPicker()
            _ = self.refreshContextSummary()
            self.updateQuestionControlState()
            self.resumeDeferredConversationContextChangeIfPossible()
        }
        return
    }

    private func selectLocalAgentRuntime(
        _ configuration: LocalAgentPassthroughConfiguration
    ) {
        guard conversationRuntimeFactory != nil,
              conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false,
              let runtime = conversationRuntime
        else { return }
        let bridge = runtime.bridge
        guard bridge.allowsAlternateRuntimeSelection else {
            messageLabel.stringValue = bridge.queuedCount > 0
                ? "请先处理当前会话的待发送队列，再切换到 Local Agent。"
                : "当前会话状态不允许切换 Runtime。"
            messageLabel.isHidden = false
            updateQuestionControlState()
            return
        }
        // Establish the selection transaction before the terminal block publishes
        // `.hidden`/`.ready`. Those state callbacks may resume a deferred context
        // refresh; without this guard the refresh can replace `runtime` midway
        // through the durable Runtime switch and silently restore Native.
        let generation = conversationContextGeneration
        let selectionID = UUID()
        conversationRuntimeSelectionID = selectionID
        conversationRuntimeSelectionInFlight = true
        let terminal = ensureLocalAgentTerminalBlock()
        let previousLegacyLocalAgentTool = legacyLocalAgentTool
        guard terminal.select(configuration: configuration) else {
            conversationRuntimeSelectionID = nil
            conversationRuntimeSelectionInFlight = false
            messageLabel.stringValue = "Local Agent 配置不可用，或当前终端会话仍在运行。"
            messageLabel.isHidden = false
            updateQuestionControlState()
            resumeDeferredConversationContextChangeIfPossible()
            return
        }
        if configuration.isReadyForStructuredRuntime {
            terminal.view.isHidden = true
        }

        messageLabel.stringValue = "正在切换到 \(configuration.displayName)…"
        messageLabel.isHidden = false
        updateQuestionControlState()
        Task { @MainActor [weak self, weak runtime, weak bridge, weak terminal] in
            guard let self, let runtime, let bridge, let terminal else { return }
            let switched = await bridge.selectLocalAgentRuntime(configuration: configuration)
            guard self.conversationRuntimeSelectionID == selectionID else { return }
            guard self.conversationContextGeneration == generation,
                  self.conversationRuntime === runtime,
                  runtime.bridge === bridge,
                  self.localAgentTerminalBlockViewController === terminal
            else {
                self.conversationRuntimeSelectionID = nil
                self.conversationRuntimeSelectionInFlight = false
                self.refreshComposerControls()
                self.refreshComposerModelPicker()
                self.updateQuestionControlState()
                return
            }
            self.conversationRuntimeSelectionID = nil
            self.conversationRuntimeSelectionInFlight = false
            if switched {
                self.legacyLocalAgentTool = nil
                self.planModeEnabled = false
                self.answerOnlyModeEnabled = false
                self.goalModeEnabled = false
                self.synchronizeLocalAgentPresentation(with: bridge.currentRuntimeSelection)
                self.messageLabel.stringValue = ""
                self.messageLabel.isHidden = self.transcriptEntries.isEmpty == false
                self.statusLabel.stringValue = configuration.isReadyForStructuredRuntime
                    ? "已切换到 \(configuration.displayName)。"
                    : "已切换到 \(configuration.displayName) 本地终端。"
            } else {
                let restoredLegacySelection = previousLegacyLocalAgentTool.map {
                    terminal.selectLegacy(tool: $0)
                } ?? false
                self.legacyLocalAgentTool = restoredLegacySelection
                    ? previousLegacyLocalAgentTool
                    : nil
                if restoredLegacySelection == false {
                    self.synchronizeLocalAgentPresentation(with: bridge.currentRuntimeSelection)
                }
                self.messageLabel.stringValue = restoredLegacySelection
                    ? "Local Agent Runtime 切换失败，已保留原兼容 CLI 选择。"
                    : "Local Agent Runtime 切换失败，已恢复原 Runtime。"
                self.messageLabel.isHidden = false
                self.statusLabel.stringValue = ""
            }
            self.refreshComposerControls()
            self.refreshComposerModelPicker()
            self.updateQuestionControlState()
            self.resumeDeferredConversationContextChangeIfPossible()
        }
    }

    private func selectLegacyLocalAgentRuntime(_ tool: LocalAgentTool) {
        guard conversationRuntimeFactory != nil,
              conversationSubmissionInFlight == false,
              conversationRuntimeSelectionInFlight == false,
              conversationRuntimeRestoreInFlight == false,
              conversationStopRequested == false,
              conversationRunPhase == .idle,
              let bridge = conversationRuntime?.bridge,
              bridge.isSessionUsable,
              bridge.allowsAlternateRuntimeSelection,
              localAgentTerminalBlockViewController?.state.preventsRuntimeChange != true
        else { return }
        guard compatibleLocalAgentTools.contains(tool) else {
            messageLabel.stringValue = "该本地 CLI 已不可用，或已有需要在设置中处理的 V2 配置。"
            messageLabel.isHidden = false
            refreshComposerModelPicker()
            updateQuestionControlState()
            return
        }
        let terminal = ensureLocalAgentTerminalBlock()
        guard terminal.selectLegacy(tool: tool) else {
            messageLabel.stringValue = "未找到可用的 \(tool.displayName) 本地命令，请先安装或在设置中完成配置。"
            messageLabel.isHidden = false
            updateQuestionControlState()
            return
        }
        legacyLocalAgentTool = tool
        planModeEnabled = false
        answerOnlyModeEnabled = false
        goalModeEnabled = false
        messageLabel.stringValue = "已切换到 \(tool.displayName) 本地 CLI 兼容模式。"
        messageLabel.isHidden = false
        statusLabel.stringValue = "兼容模式仅使用受管终端，不写入 V2 Runtime 配置。"
        refreshComposerControls()
        refreshComposerModelPicker()
        updateQuestionControlState()
    }

    private func selectComposerPermission(_ policy: AgentConfirmationPolicyPreference) {
        guard conversationRuntimeFactory == nil
            || (conversationSubmissionInFlight == false
                && conversationRuntimeSelectionInFlight == false) else {
            return
        }
        settingsStore.update { settings in
            settings.agentConfirmationPolicy = policy
        }
        refreshComposerControls()
        refreshComposerPermissionPicker()
    }

    private func selectComposerReasoning(_ effort: AIReasoningEffortPreference) {
        guard conversationRuntimeFactory == nil
            || (conversationSubmissionInFlight == false
                && conversationRuntimeSelectionInFlight == false) else {
            return
        }
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
        picker.onSelectLocalAgent = { [weak self] configuration in
            self?.selectLocalAgentRuntime(configuration)
            self?.refreshComposerModelPicker()
        }
        picker.onSelectLegacyLocalAgent = { [weak self] tool in
            self?.dismissComposerTransientUI()
            self?.selectLegacyLocalAgentRuntime(tool)
            self?.refreshComposerModelPicker()
        }
        picker.onOpenLocalAgentSettings = { [weak self] in
            guard let self else { return }
            self.dismissComposerTransientUI()
            self.localAgentSettingsOpener()
        }
        return picker
    }

    private func composerModelPickerState() -> AIComposerModelPickerState {
        refreshContextUsageRing()
        let resolved = resolvedComposerModel()
        let temporarySelection = modelSelectionSession.snapshot()
        let runtimeSelection = conversationRuntime?.bridge.currentRuntimeSelection
        let isLocalAgent = runtimeSelection?.kind == .localAgent
            || legacyLocalAgentTool != nil
        let runtimeSelectionEnabled: Bool
        if conversationRuntimeFactory == nil {
            runtimeSelectionEnabled = hasActiveAIActivity == false
                && conversationSubmissionInFlight == false
                && capturedTaskModelSelection == nil
        } else {
            runtimeSelectionEnabled = conversationRuntimeRestoreInFlight == false
                && conversationSubmissionInFlight == false
                && conversationRuntimeSelectionInFlight == false
                && conversationStopRequested == false
                && conversationRunPhase == .idle
                && (conversationRuntime?.bridge.allowsAlternateRuntimeSelection ?? false)
                && localAgentTerminalBlockViewController?.state.preventsRuntimeChange != true
        }
        return AIComposerModelPickerState(
            providerTitle: isLocalAgent ? currentModelTitle() : resolved.providerTitle,
            currentSelection: temporarySelection,
            currentRuntimeSelection: runtimeSelection,
            currentLegacyLocalAgentTool: legacyLocalAgentTool,
            specialOptions: [
                AIComposerModelPickerSpecialOption(
                    title: conversationRuntimeFactory == nil ? "跟随全局默认" : "使用全局默认",
                    selection: nil,
                    toolTip: "使用设置中的默认供应商和模型",
                    accessibilityIdentifier: "Stacio.AI.composer.modelPicker.option.globalDefault"
                )
            ],
            groups: composerModelGroups(),
            localAgentOptions: conversationRuntimeFactory == nil
                ? []
                : configuredLocalAgentConfigurations.map {
                    AIComposerLocalAgentPickerOption(configuration: $0)
                },
            legacyLocalAgentOptions: conversationRuntimeFactory == nil
                ? []
                : compatibleLocalAgentTools.map {
                    AIComposerLegacyLocalAgentPickerOption(tool: $0)
                },
            localAgentSettingsActionTitle: conversationRuntimeFactory == nil
                ? nil
                : (configuredLocalAgentConfigurations.isEmpty
                    ? "配置本地 Coding Agent…"
                    : "管理本地 Coding Agent…"),
            reasoningItems: isLocalAgent
                ? []
                : (resolved.model.map { reasoningEffortItems(for: $0) } ?? []),
            currentReasoning: resolved.model?.capabilities.effectiveReasoningEffort ?? .minimal,
            contextFraction: contextUsageFraction,
            contextLabel: contextUsageLabel,
            runtimeSelectionEnabled: runtimeSelectionEnabled
        )
    }

    private func refreshContextUsageRing(for context: AITerminalContext?) {
        let usage = currentContextUsage(for: context)
        contextUsageFraction = usage.fraction
        contextUsageLabel = usage.label
        contextUsageRing.fraction = usage.fraction
        contextUsageRing.toolTip = usage.label
        contextUsageRing.setAccessibilityLabel(usage.label)
        contextUsageRing.isHidden = false
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
        let resolvedContext = context ?? AITerminalContext(
            runtimeID: "context-preview",
            title: "",
            currentDirectory: nil,
            recentTranscript: ""
        )
        let conversationHistory = assistantConversationContext()
        let preparedRequest = AIAssistantCoordinator.preparedRequest(
            question: questionField.string,
            context: resolvedContext,
            conversationHistory: conversationHistory,
            attachments: composerAttachments,
            settings: settings,
            requestedSelection: selection
        )
        let used = AIAssistantCoordinator.dynamicContextCharacterCount(in: preparedRequest)
        let fraction = min(max(Double(used) / Double(limit), 0), 1)
        let percent = Int((fraction * 100).rounded())
        let unboundedUsed = questionField.string.count
            + conversationHistory.reduce(0) { $0 + $1.content.count }
            + composerAttachments.reduce(0) { $0 + $1.promptSummary.count }
            + (settings.aiIncludeRecentTerminalTranscript ? resolvedContext.recentTranscript.count : 0)
        let label = unboundedUsed > used
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
              retiredAssistantTaskRequestIDs.contains(payload.event.requestID) == false,
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
        captureTerminalRecordingScopeIfNeeded(for: payload.event.requestID)
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
        if retiredAssistantTaskRequestIDs.contains(payload.requestID) {
            performTerminalTaskControlWithoutTranscript(payload)
            return
        }
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
        refreshSensitiveInputPresentation(for: event)
        let key = traceEntryKey(for: event)
        guard appendedTraceEntryKeys.insert(key).inserted else {
            return
        }
        let storedEvent = eventWithoutTerminalHistoryOutput(event)
        var events = traceEventsByRequestID[event.requestID] ?? []
        if events.contains(storedEvent) == false {
            events.append(storedEvent)
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
            terminalRecordingScopesByRequestID.removeValue(forKey: event.requestID)
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
                persistHistory: true,
                completedEvent: event
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
        persistHistory: Bool,
        completedEvent: AgentTraceEvent? = nil
    ) {
        let block = terminalBlockText(target: target, command: command, output: output)
        terminalBlocksByRequestID[requestID] = block
        if let index = transcriptEntries.firstIndex(where: { $0.role == .terminal && $0.requestID == requestID }) {
            transcriptEntries[index].text = block
            if persistHistory {
                persistTerminalHistory(
                    requestID: requestID,
                    target: target,
                    command: command,
                    output: output,
                    completedEvent: completedEvent
                )
            }
            renderTranscriptEntries()
        } else {
            appendTranscript(.terminal, block, requestID: requestID, persistHistory: false)
            if persistHistory {
                persistTerminalHistory(
                    requestID: requestID,
                    target: target,
                    command: command,
                    output: output,
                    completedEvent: completedEvent
                )
            }
        }
    }

    private func persistTerminalHistory(
        requestID: String,
        target: String?,
        command: String?,
        output: String,
        completedEvent: AgentTraceEvent?
    ) {
        guard let output = terminalHistoryOutput(
            output,
            requestID: requestID,
            completedEvent: completedEvent
        ) else {
            return
        }
        persistConversationHistory(
            role: .terminal,
            content: terminalBlockText(target: target, command: command, output: output),
            requestID: requestID
        )
    }

    private func terminalHistoryOutput(
        _ output: String,
        requestID: String,
        completedEvent: AgentTraceEvent?
    ) -> String? {
        let scope = terminalRecordingScopesByRequestID[requestID]
            ?? assistantSettingsProvider()?.terminalRecordingScope
            ?? "bounded"
        switch scope {
        case "none":
            return nil
        case "fullWhenAudited":
            let audited = completedEvent?.metadata?["terminalOutputAudited"] == "true"
            let source = audited
                ? (completedEvent?.metadata?["terminalHistoryOutput"] ?? output)
                : output
            let redacted = AgentProtocolRedaction.redactPreservingLineBreaks(source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.boundedTerminalHistoryText(
                redacted,
                characterLimit: audited
                    ? Self.auditedTerminalHistoryCharacterLimit
                    : Self.boundedTerminalHistoryCharacterLimit
            )
        default:
            let redacted = AgentProtocolRedaction.redactPreservingLineBreaks(output)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.boundedTerminalHistoryText(
                redacted,
                characterLimit: Self.boundedTerminalHistoryCharacterLimit
            )
        }
    }

    private func captureTerminalRecordingScopeIfNeeded(for requestID: String) {
        guard terminalRecordingScopesByRequestID[requestID] == nil else { return }
        terminalRecordingScopesByRequestID[requestID] =
            assistantSettingsProvider()?.terminalRecordingScope ?? "bounded"
    }

    private func eventWithoutTerminalHistoryOutput(_ event: AgentTraceEvent) -> AgentTraceEvent {
        guard var metadata = event.metadata,
              metadata.removeValue(forKey: "terminalHistoryOutput") != nil
        else { return event }
        return AgentTraceEvent(
            requestID: event.requestID,
            state: event.state,
            message: event.message,
            redactedCommand: event.redactedCommand,
            metadata: metadata
        )
    }

    private static func boundedTerminalHistoryText(
        _ text: String,
        characterLimit: Int
    ) -> String {
        guard text.count > characterLimit else { return text }
        let headCount = characterLimit / 2
        let tailCount = characterLimit - headCount
        return String(text.prefix(headCount))
            + "\n... 已省略部分终端输出 ...\n"
            + String(text.suffix(tailCount))
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
            .filter { $0.key != "terminalHistoryOutput" }
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
        let latestState = events.last?.state
        let isActiveState: Bool
        switch latestState {
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            isActiveState = true
        case .completed, .failed, .cancelled, .paused, .takenOver, nil:
            isActiveState = false
        }
        taskControlContainer.isHidden = pendingTaskContinuation == nil
            && (assistantOwnedTaskRequestIDs.contains(requestID) == false
                || isActiveState == false
                || text.isEmpty)
        if isActiveState == false {
            assistantOwnedTaskRequestIDs.remove(requestID)
        }
    }

    private func taskControlText(for events: [AgentTraceEvent], controlStatus: String?) -> String {
        if let controlStatus,
           controlStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return controlStatus
        }
        guard let latestState = events.last?.state else { return "" }
        let isBackgroundTask = events.last?.metadata?["executionMode"] == "backgroundTask"
        switch latestState {
        case .running:
            if isBackgroundTask {
                return "独立任务正在运行。必要时可以取消或接管。"
            }
            return "命令已交给目标终端。必要时可以暂停、取消、接管或确认完成。"
        case .waitingForOutput:
            if isBackgroundTask {
                return "独立任务仍在等待输出。可以继续等待、取消或接管。"
            }
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
        let isBackgroundTask = events.last?.metadata?["executionMode"] == "backgroundTask"
        let isActive: Bool
        switch latestState {
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            isActive = true
        case .completed, .failed, .cancelled, .paused, .takenOver, nil:
            isActive = false
        }
        taskPauseButton.isHidden = isBackgroundTask
        taskPauseButton.isEnabled = isActive && isBackgroundTask == false
        taskCancelButton.isEnabled = isActive
        taskTakeOverButton.isEnabled = isActive
        taskConfirmCompleteButton.isHidden = isBackgroundTask
        taskConfirmCompleteButton.isEnabled = isActive
            && latestState == .waitingForOutput
            && isBackgroundTask == false
        taskContinueButton.isHidden = true
        taskContinueButton.isEnabled = false
        taskControlDismissButton.isEnabled = latestState != nil
    }

    private func appendTranscript(
        _ role: AITranscriptRole,
        _ text: String,
        conversationContent: String? = nil,
        attachments: [AIAssistantAttachment] = [],
        requestID: String? = nil,
        persistHistory: Bool = true,
        isProcessEntry: Bool? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        flushPendingStreamingTranscriptRender()
        let processEntry = isProcessEntry ?? role.isProcessRole
        let entry = AITranscriptEntry(
            role: role,
            text: trimmed,
            conversationContent: conversationContent,
            attachments: attachments.map(AITranscriptAttachment.init),
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
        if appendTranscriptViewIncrementally(for: entry) == false {
            renderTranscriptEntries()
        } else if transcriptEntries.contains(where: { $0.isProcessEntry }) == false {
            lastNonProcessTranscriptFingerprint = transcriptEntries.map(TranscriptRenderFingerprint.init)
            scheduleTranscriptScrollToBottom()
        }
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
        var createdEntry = false
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
            createdEntry = true
        }
        if createdEntry {
            if appendTranscriptViewIncrementally(for: transcriptEntries[transcriptEntries.count - 1]) == false {
                renderTranscriptEntries()
            } else if transcriptEntries.contains(where: { $0.isProcessEntry }) == false {
                lastNonProcessTranscriptFingerprint = transcriptEntries.map(TranscriptRenderFingerprint.init)
                scheduleTranscriptScrollToBottom()
            }
        } else {
            schedulePendingStreamingTranscriptRender()
        }
    }

    @discardableResult
    private func appendTranscriptViewIncrementally(for entry: AITranscriptEntry) -> Bool {
        guard entry.isProcessEntry == false,
              transcriptEntries.dropLast().contains(where: { $0.isProcessEntry }) == false
        else { return false }
        let bubble = makeTranscriptBubble(for: entry)
        transcriptViewsByEntryID[entry.id] = bubble
        transcriptStack.addArrangedSubview(bubble)
        let widthConstraint = bubble.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor)
        widthConstraint.isActive = true
        transcriptWidthConstraintsByViewID[ObjectIdentifier(bubble)] = widthConstraint
        return true
    }

    private func schedulePendingStreamingTranscriptRender() {
        guard streamingTranscriptRenderTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.streamingTranscriptRenderTimer = nil
            self.renderActiveStreamingTranscriptEntry()
        }
        streamingTranscriptRenderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPendingStreamingTranscriptRender() {
        streamingTranscriptRenderTimer?.invalidate()
        streamingTranscriptRenderTimer = nil
    }

    private func flushPendingStreamingTranscriptRender() {
        cancelPendingStreamingTranscriptRender()
        renderActiveStreamingTranscriptEntry()
    }

    private func renderActiveStreamingTranscriptEntry() {
        guard let index = activeStreamingAssistantIndex,
              transcriptEntries.indices.contains(index)
        else {
            return
        }
        let entry = transcriptEntries[index]
        if entry.isProcessEntry, let processGroupID = entry.processGroupID {
            guard let processView = transcriptProcessGroupViewsByID[processGroupID] else {
                renderTranscriptEntries()
                return
            }
            let groupedEntries = transcriptEntries.filter {
                $0.isProcessEntry && $0.processGroupID == processGroupID
            }
            processView.update(
                entries: groupedEntries,
                elapsedText: processGroupElapsedText(
                    timing: processGroupTimings[processGroupID],
                    entries: groupedEntries
                )
            )
        } else {
            guard let bubble = transcriptViewsByEntryID[entry.id],
                  bubble.update(entry: entry)
            else {
                renderTranscriptEntries()
                return
            }
        }
        scrollTranscriptToBottom()
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
            cancelPendingStreamingTranscriptRender()
            activeStreamingAssistantIndex = nil
            return
        }
        cancelPendingStreamingTranscriptRender()
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
        let fallback = activeStreamingAssistantIndex
            .flatMap { index in
                guard transcriptEntries.indices.contains(index),
                      transcriptEntries[index].role == .assistant
                else { return nil }
                return transcriptEntries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
        let canonicalText = trimmed.isEmpty ? fallback : trimmed
        guard canonicalText.isEmpty == false else {
            flushPendingStreamingTranscriptRender()
            activeStreamingAssistantIndex = nil
            return
        }
        if let index = activeStreamingAssistantIndex,
           transcriptEntries.indices.contains(index),
           transcriptEntries[index].role == .assistant {
            transcriptEntries[index].text = canonicalText
            transcriptEntries[index].isProcessEntry = transcriptEntries[index].isProcessEntry || isProcessEntry
            if isProcessEntry {
                transcriptEntries[index].processGroupID = activeProcessGroupID
            }
            if persistHistory {
                persistConversationHistory(
                    role: isProcessEntry ? .step : .assistant,
                    content: canonicalText,
                    requestID: nil
                )
            }
            flushPendingStreamingTranscriptRender()
        } else {
            appendTranscript(
                .assistant,
                canonicalText,
                persistHistory: persistHistory && isProcessEntry == false,
                isProcessEntry: isProcessEntry
            )
            if persistHistory && isProcessEntry {
                persistConversationHistory(role: .step, content: canonicalText, requestID: nil)
            }
        }
        activeStreamingAssistantIndex = nil
    }

    private func persistConversationHistory(
        role: AIConversationHistoryRole,
        content: String,
        requestID: String?
    ) {
        guard let conversationHistoryStore else {
            return
        }
        let storageID: String
        if let conversationHistoryWriteStorageID {
            storageID = conversationHistoryWriteStorageID
        } else if let context = resolvedTargetContext() {
            storageID = conversationHistoryStorageID(for: context)
            conversationHistoryWriteStorageID = storageID
        } else {
            return
        }
        do {
            _ = try conversationHistoryStore.appendConversationHistoryItem(
                runtimeID: storageID,
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
        cancelPendingStreamingTranscriptRender()

        let hasProcessEntries = transcriptEntries.contains(where: { $0.isProcessEntry })
        let fingerprint = transcriptEntries.map(TranscriptRenderFingerprint.init)
        if hasProcessEntries == false {
            if lastNonProcessTranscriptFingerprint == fingerprint {
                return
            }
            lastNonProcessTranscriptFingerprint = fingerprint
        } else {
            lastNonProcessTranscriptFingerprint = nil
        }

        var processEntriesByGroupID: [UUID: [AITranscriptEntry]] = [:]
        for entry in transcriptEntries where entry.isProcessEntry {
            guard let processGroupID = entry.processGroupID else { continue }
            processEntriesByGroupID[processGroupID, default: []].append(entry)
        }

        var desiredViews: [NSView] = []
        var desiredEntryIDs: Set<UUID> = []
        var desiredProcessGroupIDs: Set<UUID> = []
        var renderedProcessGroupIDs: Set<UUID> = []
        for entry in transcriptEntries {
            if entry.isProcessEntry, let processGroupID = entry.processGroupID {
                guard renderedProcessGroupIDs.insert(processGroupID).inserted else { continue }
                let groupedEntries = processEntriesByGroupID[processGroupID] ?? []
                let timing = processGroupTimings[processGroupID]
                let elapsedText = processGroupElapsedText(timing: timing, entries: groupedEntries)
                desiredProcessGroupIDs.insert(processGroupID)
                let processView: AITranscriptProcessGroupView
                if let existingView = transcriptProcessGroupViewsByID[processGroupID] {
                    existingView.update(entries: groupedEntries, elapsedText: elapsedText)
                    processView = existingView
                } else {
                    processView = AITranscriptProcessGroupView(
                        entries: groupedEntries,
                        elapsedText: elapsedText,
                        onToggle: { [weak self] in
                            self?.toggleProcessGroup(processGroupID)
                        }
                    )
                    transcriptProcessGroupViewsByID[processGroupID] = processView
                }
                desiredViews.append(processView)
                continue
            }

            desiredEntryIDs.insert(entry.id)
            let bubble: AITranscriptBubbleView
            if let existingBubble = transcriptViewsByEntryID[entry.id],
               existingBubble.update(entry: entry) {
                bubble = existingBubble
            } else {
                if let existingBubble = transcriptViewsByEntryID.removeValue(forKey: entry.id) {
                    removeTranscriptView(existingBubble)
                }
                bubble = makeTranscriptBubble(for: entry)
                transcriptViewsByEntryID[entry.id] = bubble
            }
            desiredViews.append(bubble)
        }

        for entryID in Array(transcriptViewsByEntryID.keys) where desiredEntryIDs.contains(entryID) == false {
            guard let view = transcriptViewsByEntryID.removeValue(forKey: entryID) else { continue }
            removeTranscriptView(view)
        }
        for processGroupID in Array(transcriptProcessGroupViewsByID.keys)
        where desiredProcessGroupIDs.contains(processGroupID) == false {
            guard let view = transcriptProcessGroupViewsByID.removeValue(forKey: processGroupID) else { continue }
            removeTranscriptView(view)
        }

        reconcileTranscriptViews(desiredViews)
        scrollTranscriptToBottom()
    }

    private func reconcileTranscriptViews(_ desiredViews: [NSView]) {
        let desiredViewIDs = Set(desiredViews.map(ObjectIdentifier.init))
        let existingViews = transcriptStack.arrangedSubviews
        for view in existingViews
        where desiredViewIDs.contains(ObjectIdentifier(view)) == false {
            removeTranscriptView(view)
        }

        var arrangedViews = transcriptStack.arrangedSubviews
        for (index, view) in desiredViews.enumerated() {
            if arrangedViews.indices.contains(index), arrangedViews[index] === view {
                continue
            }

            if let currentIndex = arrangedViews.firstIndex(where: { $0 === view }) {
                transcriptStack.removeArrangedSubview(view)
                transcriptStack.insertArrangedSubview(view, at: index)
                arrangedViews.remove(at: currentIndex)
                arrangedViews.insert(view, at: index)
                continue
            }

            transcriptStack.insertArrangedSubview(view, at: index)
            arrangedViews.insert(view, at: index)
            let widthConstraint = view.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor)
            widthConstraint.isActive = true
            transcriptWidthConstraintsByViewID[ObjectIdentifier(view)] = widthConstraint
        }
    }

    private func removeTranscriptView(_ view: NSView) {
        if transcriptStack.arrangedSubviews.contains(where: { $0 === view }) {
            transcriptStack.removeArrangedSubview(view)
        }
        if let widthConstraint = transcriptWidthConstraintsByViewID.removeValue(forKey: ObjectIdentifier(view)) {
            widthConstraint.isActive = false
        }
        view.removeFromSuperview()
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
            onToggle: { [weak self] in self?.toggleTranscriptEntry(id: entry.id) },
            executionExpanded: entry.executionCard.map {
                v2ExpandedExecutionProposalIDs.contains($0.proposalID)
            } ?? false,
            onOpenTerminal: { [weak self] runtimeID in
                self?.openConversationExecutionTerminal(runtimeID: runtimeID)
            },
            onCancelExecution: { [weak self] requestID in
                self?.cancelConversationExecution(requestID: requestID)
            },
            onSaveRedactedLog: { [weak self] artifact in
                self?.saveConversationRedactedLog(artifact)
            },
            onExecutionExpandedChange: { [weak self] expanded in
                guard let proposalID = entry.executionCard?.proposalID else { return }
                self?.setConversationExecutionExpanded(expanded, proposalID: proposalID)
            }
        )
        bubble.preferredTextWidth = max(80, conversationContainer.bounds.width)
        return bubble
    }

    private func setConversationExecutionExpanded(_ expanded: Bool, proposalID: String) {
        guard proposalID.isEmpty == false else { return }
        if expanded {
            v2ExpandedExecutionProposalIDs.insert(proposalID)
        } else {
            v2ExpandedExecutionProposalIDs.remove(proposalID)
        }
        transcriptStack.needsLayout = true
        transcriptDocumentView.needsLayout = true
    }

    private func openConversationExecutionTerminal(runtimeID: String) {
        guard terminalActivator(runtimeID) else {
            messageLabel.stringValue = "执行终端已关闭或不可用。"
            messageLabel.isHidden = false
            return
        }
        messageLabel.isHidden = true
    }

    private func cancelConversationExecution(requestID: String) {
        guard let bridge = conversationRuntime?.bridge else {
            presentConversationRuntimeUnavailable()
            return
        }
        Task { @MainActor [weak self, weak bridge] in
            guard let self, let bridge else { return }
            let cancelled = await bridge.cancelExecution(requestID: requestID)
            guard cancelled == false else { return }
            self.messageLabel.stringValue = "该终端执行已经结束或无法取消。"
            self.messageLabel.isHidden = false
        }
    }

    private func saveConversationRedactedLog(_ artifact: TerminalArtifactPresentation) {
        let log = artifact.redactedLog.trimmingCharacters(in: .whitespacesAndNewlines)
        guard log.isEmpty == false else {
            messageLabel.stringValue = "当前执行没有可保存的脱敏日志。"
            messageLabel.isHidden = false
            return
        }
        let savePanel = NSSavePanel()
        savePanel.title = "保存脱敏终端日志"
        savePanel.prompt = "保存"
        savePanel.canCreateDirectories = true
        let requestSuffix = artifact.requestID?
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") ?? "execution"
        savePanel.nameFieldStringValue = "stacio-\(requestSuffix).log"
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try Data((log + "\n").utf8).write(to: url, options: .atomic)
                self?.statusLabel.stringValue = "脱敏日志已保存"
            } catch {
                self?.messageLabel.stringValue = "脱敏日志保存失败：\(error.localizedDescription)"
                self?.messageLabel.isHidden = false
            }
        }
        if let window = view.window {
            savePanel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(savePanel.runModal())
        }
    }

    private func openAssistantLink(_ url: URL) {
        switch AIAssistantLinkRouter.destination(for: url) {
        case .stacioBrowser:
            internalBrowserOpener(url)
        case .systemBrowser:
            externalBrowserOpener(url)
        }
    }

    private func toggleTranscriptEntry(id: UUID) {
        guard let index = transcriptEntries.firstIndex(where: { $0.id == id }) else { return }
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
            : StacioDesignSystem.dynamicColor(.controlBackgroundColor, alpha: 0.86)
        StacioDesignSystem.setLayerBackgroundColor(button, color: background)
        button.contentTintColor = emphasized ? .white : .labelColor
    }

    private func configurePrimaryActionButton() {
        configureIconButton(
            askButton,
            symbolName: primaryActionSymbolName,
            accessibilityLabel: Self.primarySendLabel,
            emphasized: true
        )
        askButton.layer?.cornerRadius = Self.primaryActionSize / 2
        askButton.setContentHuggingPriority(.required, for: .horizontal)
        askButton.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            color: StacioDesignSystem.dynamicColor(.controlBackgroundColor, alpha: 0.76)
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
            color: StacioDesignSystem.dynamicColor(.controlBackgroundColor, alpha: 0.58)
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
            messageLabel,
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
            sensitiveInputContainer,
            sensitiveInputLabel,
            sensitiveInputField,
            sensitiveInputSubmitButton,
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
            questionScrollView,
            questionField
        ].forEach { view in
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
    }

    private func updateQuestionControlState() {
        let hasQuestion = questionField.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let canSubmit = hasConfiguredConversationRuntime
        if conversationRuntimeFactory != nil {
            let hasRuntime = conversationRuntime != nil
            let showsStop = primaryActionShowsStop
            let localAgentState = localAgentTerminalBlockViewController?.state
            let frozenControlsEnabled = hasRuntime
                && conversationContextTransitionBlocked == false
            let canSend = hasRuntime
                && conversationRuntimeRestoreInFlight == false
                && (conversationRuntime?.bridge.isSessionUsable ?? false)
                && conversationSubmissionInFlight == false
                && conversationRuntimeSelectionInFlight == false
                && AgentComposerRunStateMachine.sendAvailable(phase: conversationRunPhase)
            let stopEnabled = hasRuntime
                && conversationRuntimeRestoreInFlight == false
                && conversationStopRequested == false
                && conversationRunPhase != .stopping
                && (conversationRuntime?.bridge.isSessionUsable ?? false)
                && localAgentState?.isTerminating != true
            askButton.isEnabled = showsStop ? stopEnabled : (hasQuestion && canSubmit && canSend)
            primaryActionSymbolName = showsStop ? "stop.fill" : "arrow.up"
            askButton.image = NSImage(
                systemSymbolName: primaryActionSymbolName,
                accessibilityDescription: showsStop ? Self.primaryStopLabel : Self.primarySendLabel
            )
            askButton.setAccessibilityLabel(showsStop ? Self.primaryStopLabel : Self.primarySendLabel)
            askButton.toolTip = showsStop
                ? (conversationStopRequested || conversationRunPhase == .stopping ? "正在停止" : Self.primaryStopLabel)
                : Self.primarySendLabel
            conversationPopUpButton.isEnabled = frozenControlsEnabled
                && conversationContextTransitionBlocked == false
            newConversationButton.isEnabled = frozenControlsEnabled
                && conversationContextTransitionBlocked == false
            targetButton.isEnabled = frozenControlsEnabled
                && conversationContextTransitionBlocked == false
            composerAddButton.isEnabled = frozenControlsEnabled
                && conversationRuntimeSelectionInFlight == false
            composerModelButton.isEnabled = conversationRunPhase == .idle
                && conversationRuntimeRestoreInFlight == false
                && conversationSubmissionInFlight == false
                && conversationRuntimeSelectionInFlight == false
                && (conversationRuntime?.bridge.allowsAlternateRuntimeSelection ?? false)
                && (localAgentTerminalBlockViewController?.state.preventsRuntimeChange ?? false) == false
            composerPermissionButton.isHidden = true
            refreshContextUsageRing()
            return
        }
        let isActive = hasActiveAIActivity
        askButton.isEnabled = isActive || (hasQuestion && canSubmit)
        primaryActionSymbolName = isActive ? "stop.fill" : "arrow.up"
        askButton.image = NSImage(
            systemSymbolName: primaryActionSymbolName,
            accessibilityDescription: isActive ? Self.primaryStopLabel : Self.primarySendLabel
        )
        askButton.setAccessibilityLabel(isActive ? Self.primaryStopLabel : Self.primarySendLabel)
        askButton.toolTip = isActive ? Self.primaryStopLabel : Self.primarySendLabel
        conversationPopUpButton.isEnabled = isActive == false
        newConversationButton.isEnabled = isActive == false
        targetButton.isEnabled = isActive == false
        composerModelButton.isEnabled = hasActiveAIActivity == false && capturedTaskModelSelection == nil
        refreshContextUsageRing()
        applyDeferredCurrentTerminalFollowIfPossible()
    }

    private func conversationHistoryStorageID(
        for context: AITerminalContext,
        threadID: String? = nil
    ) -> String {
        let historyScopeID = context.historyScopeID
        return CoreBridgeAIAssistantConversationHistoryStore.threadStorageID(
            runtimeID: historyScopeID,
            threadID: threadID ?? activeConversationIDs[historyScopeID] ?? "legacy"
        )
    }

    private func applyDeferredCurrentTerminalFollowIfPossible() {
        guard shouldFollowCurrentTerminalAfterActivity,
              hasActiveAIActivity == false,
              conversationContextTransitionBlocked == false
        else {
            return
        }
        shouldFollowCurrentTerminalAfterActivity = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.hasActiveAIActivity == false,
                  self.conversationContextTransitionBlocked == false else {
                self.shouldFollowCurrentTerminalAfterActivity = true
                return
            }
            self.selectedRuntimeID = nil
            self.selectedRuntimeIDs = []
            self.conversationHistoryWriteStorageID = nil
            self.refreshForCurrentContext()
        }
    }

    private func resumeDeferredConversationContextChangeIfPossible() {
        guard conversationContextTransitionBlocked == false else { return }
        if shouldFollowCurrentTerminalAfterActivity {
            applyDeferredCurrentTerminalFollowIfPossible()
            return
        }
        guard conversationContextRefreshPending else { return }
        conversationContextRefreshPending = false
        refreshConversationRuntimeForCurrentContext()
    }

    private var conversationContextTransitionBlocked: Bool {
        conversationRuntimeRestoreInFlight
            || conversationSubmissionInFlight
            || conversationRuntimeSelectionInFlight
            || conversationRunPhase != .idle
            || conversationRuntime?.bridge.isIdle == false
            || (conversationRuntime?.bridge.queuedCount ?? 0) > 0
            || localAgentTerminalBlockViewController?.state.preventsRuntimeChange == true
    }

    private func applyModelSelectionFromConversationRuntime(
        _ selection: AgentRuntimeSelection
    ) {
        guard selection.kind == .nativeAPI,
              let configurationID = selection.providerConfigurationID
                ?? selection.codingPlanConfigurationID,
              let providerID = UUID(uuidString: configurationID),
              let modelID = selection.modelID,
              modelID.isEmpty == false
        else { return }
        modelSelectionSession.select(
            AIModelSelection(providerID: providerID, modelID: modelID)
        )
    }

    private func refreshSensitiveInputPresentation(for event: AgentTraceEvent) {
        guard let runtimeID = event.metadata?["sourceRuntimeID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              runtimeID.isEmpty == false
        else { return }

        let metadataContainsSensitiveState = event.metadata?["sensitiveInputRequired"] != nil
        let sensitiveInputRequired = event.metadata?["sensitiveInputRequired"] == "true"
        if sensitiveInputRequired,
           shouldDisplayTrace(forRuntimeID: runtimeID),
           let prompt = coordinator.sensitiveInputPrompt(runtimeID: runtimeID) {
            presentSensitiveInput(prompt)
            return
        }

        if sensitiveInputPrompt?.runtimeID == runtimeID,
           (metadataContainsSensitiveState || isTerminalTraceState(event.state)) {
            clearSensitiveInputPresentation()
        }
    }

    private func presentSensitiveInput(_ prompt: AgentSensitiveInputPrompt) {
        let shouldRevealInput = sensitiveInputContainer.isHidden
            || sensitiveInputPrompt != prompt
        if sensitiveInputPrompt != prompt {
            sensitiveInputField.stringValue = ""
        }
        sensitiveInputPrompt = prompt
        let title = prompt.targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = title.isEmpty ? "当前终端" : title
        sensitiveInputLabel.stringValue = "\(target) 正在等待密码。内容只发送到终端，不会加入 AI 对话或历史。"
        sensitiveInputContainer.isHidden = false
        startSensitiveInputRefreshTimerIfNeeded()
        if shouldRevealInput {
            scrollTranscriptToBottom()
        }
    }

    private func reconcileSensitiveInputPresentation() {
        let visibleRuntimeIDs = resolvedTargetContexts().map(\.runtimeID)
        var candidateRuntimeIDs = visibleRuntimeIDs
        if let sensitiveInputRuntimeID = sensitiveInputPrompt?.runtimeID,
           let currentIndex = candidateRuntimeIDs.firstIndex(of: sensitiveInputRuntimeID),
           currentIndex != candidateRuntimeIDs.startIndex {
            candidateRuntimeIDs.remove(at: currentIndex)
            candidateRuntimeIDs.insert(sensitiveInputRuntimeID, at: 0)
        }
        for runtimeID in candidateRuntimeIDs {
            if let prompt = coordinator.sensitiveInputPrompt(runtimeID: runtimeID) {
                presentSensitiveInput(prompt)
                return
            }
        }
        clearSensitiveInputPresentation()
    }

    private func startSensitiveInputRefreshTimerIfNeeded() {
        guard sensitiveInputRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reconcileSensitiveInputPresentation()
        }
        sensitiveInputRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func clearSensitiveInputPresentation() {
        sensitiveInputField.stringValue = ""
        sensitiveInputContainer.isHidden = true
        sensitiveInputPrompt = nil
        sensitiveInputRefreshTimer?.invalidate()
        sensitiveInputRefreshTimer = nil
    }

    @objc
    private func sensitiveInputSubmitPressed(_ sender: Any?) {
        guard let prompt = sensitiveInputPrompt else {
            clearSensitiveInputPresentation()
            return
        }
        var bytes = Array(sensitiveInputField.stringValue.utf8)
        sensitiveInputField.stringValue = ""
        guard bytes.isEmpty == false else { return }
        bytes.append(13)
        let didSubmit = coordinator.submitSensitiveInput(bytes, prompt: prompt)
        for index in bytes.indices {
            bytes[index] = 0
        }
        if didSubmit {
            clearSensitiveInputPresentation()
        } else {
            reconcileSensitiveInputPresentation()
        }
    }

    private var hasActiveAIActivity: Bool {
        isAsking
            || isExecuting
            || activeAskCancellation != nil
            || activeOrchestrator != nil
            || activeAutonomousTask != nil
            || activeManualCommandTask != nil
    }

    private var primaryActionShowsStop: Bool {
        if conversationRuntimeFactory != nil {
            guard conversationRuntime != nil else { return false }
            return conversationSubmissionInFlight
                || conversationStopRequested
                || conversationRunPhase.showsStop
                || localAgentTerminalBlockViewController?.state.preventsRuntimeChange == true
        }
        return hasActiveAIActivity
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

    var conversationRuntimeReadyForTesting: Bool {
        conversationRuntime?.bridge.isSessionUsable == true
            && conversationRuntime?.bridge.isRestoring == false
            && conversationRuntimeRestoreInFlight == false
            && conversationRunPhase != .preparing
            && conversationSubmissionInFlight == false
            && conversationRuntimeSelectionInFlight == false
    }

    var conversationStateForTesting: String {
        "submission=\(conversationSubmissionInFlight), selection=\(conversationRuntimeSelectionInFlight), restoring=\(conversationRuntimeRestoreInFlight), phase=\(conversationRunPhase), active=\(hasActiveAIActivity), v2=\(conversationRuntimeFactory != nil), generation=\(conversationContextGeneration), session=\(conversationRuntime?.sessionID ?? "none"), refreshPending=\(conversationContextRefreshPending), followPending=\(shouldFollowCurrentTerminalAfterActivity), message=\(messageLabel.stringValue), runtimeError=\(conversationRuntime?.bridge.currentUserFacingError ?? "none")"
    }

    var conversationRuntimeSelectionForTesting: AgentRuntimeSelection? {
        conversationRuntime?.bridge.currentRuntimeSelection
    }

    var localAgentRuntimeOptionTitlesForTesting: [String] {
        configuredLocalAgentConfigurations.map { "Local Agent · \($0.displayName)" }
    }

    var legacyLocalAgentRuntimeOptionTitlesForTesting: [String] {
        compatibleLocalAgentTools.map { "\($0.displayName) · 兼容本地 CLI" }
    }

    var localAgentTerminalStateForTesting: LocalAgentTerminalBlockState? {
        localAgentTerminalBlockViewController?.state
    }

    @discardableResult
    func selectLocalAgentRuntimeForTesting(_ tool: LocalAgentTool) -> Bool {
        guard let configuration = configuredLocalAgentConfigurations.first(where: {
            $0.tool == tool
        }) else { return false }
        selectLocalAgentRuntime(configuration)
        return conversationRuntimeSelectionInFlight
    }

    @discardableResult
    func selectLegacyLocalAgentRuntimeForTesting(_ tool: LocalAgentTool) -> Bool {
        guard compatibleLocalAgentTools.contains(tool) else { return false }
        selectLegacyLocalAgentRuntime(tool)
        return legacyLocalAgentTool == tool
    }

    var conversationRuntimeIdleForTesting: Bool {
        conversationRuntime?.bridge.isIdle == true
            && conversationSubmissionInFlight == false
            && conversationRuntimeSelectionInFlight == false
            && localAgentTerminalBlockViewController?.state.preventsRuntimeChange != true
    }

    var conversationQueuedCountForTesting: Int {
        conversationRuntime?.bridge.queuedCount ?? 0
    }

    var conversationTurnBindingControlsFrozenForTesting: Bool {
        conversationPopUpButton.isEnabled == false
            && newConversationButton.isEnabled == false
            && targetButton.isEnabled == false
            && composerAddButton.isEnabled == false
            && composerModelButton.isEnabled == false
    }

    var conversationSelectedWorkModeForTesting: TurnWorkMode? {
        conversationRuntime?.bridge.selectedWorkMode
    }

    var conversationSwitchingEnabledForTesting: Bool {
        conversationPopUpButton.isEnabled && newConversationButton.isEnabled
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
        questionField.string
    }

    var questionViewportHeightForTesting: CGFloat {
        questionHeightConstraint?.constant ?? 0
    }

    var composerHeightForTesting: CGFloat {
        composerHeightConstraint?.constant ?? 0
    }

    var sendKeyModeForTesting: SendKeyMode {
        questionField.sendKeyMode
    }

    var agentTaskLoopLimitsForTesting: AgentTaskLoopLimits {
        currentAgentTaskLoopLimits()
    }

    var sentQuestionHistoryForTesting: [String] {
        sentQuestionHistory()
    }

    var transcriptTextForTesting: String {
        transcriptEntries.map(\.displayText).joined(separator: "\n")
    }

    var appliedTranscriptTextWidthForTesting: CGFloat? {
        lastAppliedTranscriptTextWidth
    }

    func setInspectorInteractiveResizeActiveForTesting(_ isActive: Bool) {
        setInspectorInteractiveResizeActive(isActive)
    }

    @discardableResult
    func loadTranscriptEntriesForPerformanceTesting(count: Int) -> TimeInterval {
        activeStreamingAssistantIndex = nil
        transcriptEntries = (0..<count).map { index in
            AITranscriptEntry(
                role: .assistant,
                text: "### Check \(index)\n- Result remains available\n`status --index \(index)`",
                requestID: "perf-\(index)"
            )
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        renderTranscriptEntries()
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    @discardableResult
    func appendTranscriptEntryForPerformanceTesting(_ text: String) -> TimeInterval {
        let startedAt = CFAbsoluteTimeGetCurrent()
        appendTranscript(.assistant, text, persistHistory: false)
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    @discardableResult
    func rerenderTranscriptForPerformanceTesting() -> TimeInterval {
        let startedAt = CFAbsoluteTimeGetCurrent()
        renderTranscriptEntries()
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    @discardableResult
    func appendAssistantStreamingDeltasForPerformanceTesting(count: Int) -> TimeInterval {
        cancelPendingStreamingTranscriptRender()
        activeStreamingAssistantIndex = nil
        let startedAt = CFAbsoluteTimeGetCurrent()
        for _ in 0..<count {
            appendAssistantStreamingDelta("x")
        }
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    func flushStreamingTranscriptRenderForTesting() {
        flushPendingStreamingTranscriptRender()
    }

    func removeTranscriptEntryForTesting(at index: Int) {
        guard transcriptEntries.indices.contains(index) else { return }
        cancelPendingStreamingTranscriptRender()
        activeStreamingAssistantIndex = nil
        transcriptEntries.remove(at: index)
        renderTranscriptEntries()
    }

    var hasPendingStreamingTranscriptRenderForTesting: Bool {
        streamingTranscriptRenderTimer != nil
    }

    var transcriptCachedEntryViewCountForTesting: Int {
        transcriptViewsByEntryID.count
    }

    var lastRenderedAssistantTextForTesting: String? {
        transcriptStack.arrangedSubviews.reversed().compactMap { view in
            guard let bubble = view as? AITranscriptBubbleView,
                  bubble.isAssistantForTesting
            else {
                return nil
            }
            return bubble.attributedStringForTesting.string
        }.first
    }

    var transcriptViewObjectIdentifiersForTesting: [ObjectIdentifier] {
        transcriptStack.arrangedSubviews.map(ObjectIdentifier.init)
    }

    var transcriptActiveWidthConstraintCountForTesting: Int {
        let arrangedViewIDs = Set(transcriptStack.arrangedSubviews.map(ObjectIdentifier.init))
        return transcriptStack.constraints.filter { constraint in
            guard constraint.isActive,
                  constraint.firstAttribute == .width,
                  constraint.secondAttribute == .width,
                  let firstView = constraint.firstItem as? NSView,
                  let secondView = constraint.secondItem as? NSView
            else {
                return false
            }
            return (firstView === transcriptStack && arrangedViewIDs.contains(ObjectIdentifier(secondView)))
                || (secondView === transcriptStack && arrangedViewIDs.contains(ObjectIdentifier(firstView)))
        }.count
    }

    var rawTranscriptTextForTesting: String {
        transcriptEntries.map(\.text).joined(separator: "\n")
    }

    var terminalRecordingScopeCountForTesting: Int {
        terminalRecordingScopesByRequestID.count
    }

    func traceMetadataValuesForTesting(key: String) -> [String] {
        traceEventsByRequestID.values
            .flatMap { $0 }
            .compactMap { $0.metadata?[key] }
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

    var manualCommandRunningForTesting: Bool {
        activeManualCommandRunID != nil
    }

    var visibleTaskControlTitlesForTesting: [String] {
        [
            taskPauseButton,
            taskCancelButton,
            taskTakeOverButton,
            taskConfirmCompleteButton
        ]
        .filter { $0.isHidden == false }
        .map(\.title)
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
            if view === sensitiveInputContainer {
                return "sensitiveInput"
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

    var surfaceModeTitlesForTesting: [String] {
        ["排查助手"]
    }

    var surfaceModeControlWidthForTesting: CGFloat {
        0
    }

    var surfaceModeSegmentWidthsForTesting: [CGFloat] {
        []
    }

    var activeSurfaceModeTitleForTesting: String {
        "排查助手"
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

    var sensitiveInputVisibleForTesting: Bool {
        sensitiveInputContainer.isHidden == false
    }

    var sensitiveInputUsesSecureTextFieldForTesting: Bool {
        sensitiveInputField.cell is NSSecureTextFieldCell
    }

    var sensitiveInputValueForTesting: String {
        sensitiveInputField.stringValue
    }

    func setSensitiveInputForTesting(_ value: String) {
        sensitiveInputField.stringValue = value
    }

    func submitSensitiveInputForTesting() {
        sensitiveInputSubmitPressed(nil)
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

    var composerWorkModeMenuTitlesForTesting: [String] {
        composerWorkModeMenu().items
            .filter { $0.isSeparatorItem == false }
            .map(\.title)
    }

    var composerWorkModeMenuCheckedTitlesForTesting: [String] {
        composerWorkModeMenu().items
            .filter { $0.isSeparatorItem == false && $0.state == .on }
            .map(\.title)
    }

    var composerWorkModeAccessibilityLabelForTesting: String? {
        composerAddButton.accessibilityLabel()
    }

    func selectComposerWorkModeForTesting(_ mode: TurnWorkMode) {
        selectComposerWorkMode(mode)
    }

    var conversationSelectedExecutionChoiceForTesting: TurnExecutionChoice? {
        conversationRuntime?.bridge.selectedExecutionChoice
    }

    func selectComposerExecutionChoiceForTesting(_ choice: TurnExecutionChoice) {
        selectExecutionChoice(choice)
    }

    func setConversationRunPhaseForTesting(_ phase: ComposerRunPhase) {
        applyConversationRunPhase(phase)
        updateQuestionControlState()
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

    var composerModelPickerShowsReasoningForTesting: Bool {
        makeComposerModelPicker().showsReasoningForTesting
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

    var transcriptAttachmentCardTitlesForTesting: [String] {
        transcriptEntries.flatMap { entry in
            transcriptViewsByEntryID[entry.id]?.attachmentTitlesForTesting ?? []
        }
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
        primaryActionShowsStop && askButton.isEnabled
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

    var composerFrameForTesting: NSRect {
        composer.convert(composer.bounds, to: view)
    }

    var primaryActionFrameForTesting: NSRect {
        askButton.convert(askButton.bounds, to: view)
    }

    var primaryActionCornerRadiusForTesting: CGFloat {
        askButton.layer?.cornerRadius ?? 0
    }

    var primaryActionSymbolNameForTesting: String {
        primaryActionSymbolName
    }

    var decisionCardFrameForTesting: NSRect {
        toolDecisionViewController.view.convert(
            toolDecisionViewController.view.bounds,
            to: view
        )
    }

    var decisionCardDetailsFrameForTesting: NSRect {
        toolDecisionViewController.detailsScrollFrameForTesting(in: view)
    }

    var decisionCardDetailsDocumentFrameForTesting: NSRect {
        toolDecisionViewController.detailsDocumentFrameForTesting(in: view)
    }

    var decisionCardCommandFrameForTesting: NSRect {
        toolDecisionViewController.commandFrameForTesting(in: view)
    }

    var decisionCardApprovalButtonFrameForTesting: NSRect {
        toolDecisionViewController.approvalButtonFrameForTesting(in: view)
    }

    var decisionCardDenialButtonFrameForTesting: NSRect {
        toolDecisionViewController.denialButtonFrameForTesting(in: view)
    }

    func applyToolDecisionForTesting(_ decision: PendingToolDecisionPresentation?) {
        toolDecisionViewController.apply(decision)
        updateConversationBottomLayout()
        view.needsLayout = true
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
        guard conversationSubmissionInFlight == false,
              conversationRuntimeFactory == nil || conversationContextTransitionBlocked == false
        else { return }
        selectedRuntimeID = runtimeID
        selectedRuntimeIDs = [runtimeID]
        refreshForCurrentContext()
    }

    func selectTargetRuntimesForTesting(_ runtimeIDs: [String]) {
        guard conversationSubmissionInFlight == false,
              conversationRuntimeFactory == nil || conversationContextTransitionBlocked == false
        else { return }
        selectedRuntimeIDs = runtimeIDs
        selectedRuntimeID = runtimeIDs.first
        refreshForCurrentContext()
    }

    func selectComposerModelForTesting(_ selection: AIModelSelection?) {
        selectComposerModel(selection)
    }

    func stopConversationForTesting() async {
        await conversationRuntime?.bridge.stop()
    }

    func setConversationQueueAutoAdvancePausedForTesting(
        _ paused: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard let bridge = conversationRuntime?.bridge else {
            completion(false)
            return
        }
        Task { @MainActor in
            completion(await bridge.setQueueAutoAdvancePaused(paused))
        }
    }

    func removeFirstQueuedConversationInputForTesting(
        completion: @escaping (Bool) -> Void
    ) {
        guard let bridge = conversationRuntime?.bridge,
              let input = bridge.queuedInputs.first else {
            completion(false)
            return
        }
        Task { @MainActor in
            completion(await bridge.removeQueuedInput(id: input.id))
        }
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

    func postTerminalTraceForTesting(
        runtimeID: String,
        title: String,
        event: AgentTraceEvent
    ) {
        TerminalAgentTraceNotification.post(runtimeID: runtimeID, title: title, event: event)
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
        questionField.onSend?()
    }

    func queueQuestionForTesting() {
        queueComposerInput()
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
        pendingTranscriptScrollWorkItem?.cancel()
        pendingTranscriptScrollWorkItem = nil
        applyTranscriptScrollPosition(forceLayout: true)
        DispatchQueue.main.async { [weak self] in
            self?.applyTranscriptScrollPosition(forceLayout: true)
        }
    }

    private func scheduleTranscriptScrollToBottom() {
        guard pendingTranscriptScrollWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTranscriptScrollWorkItem = nil
            self.applyTranscriptScrollPosition(forceLayout: true)
        }
        pendingTranscriptScrollWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func applyTranscriptScrollPosition(forceLayout: Bool) {
        if forceLayout {
            view.layoutSubtreeIfNeeded()
            transcriptDocumentView.layoutSubtreeIfNeeded()
        }
        let contentHeight = transcriptDocumentView.bounds.height
        let visibleHeight = transcriptScrollView.contentView.bounds.height
        guard contentHeight > 0, visibleHeight > 0 else { return }
        let y = max(0, contentHeight - visibleHeight)
        let clipView = transcriptScrollView.contentView
        guard abs(clipView.bounds.origin.y - y) > 0.5 else { return }
        // AppKit can defer `scroll(to:)` while an approval card is changing
        // its intrinsic height. Set the clip origin synchronously as well so
        // the final layout pass cannot leave the queue at the Composer edge.
        let targetOrigin = NSPoint(x: clipView.bounds.origin.x, y: y)
        clipView.setBoundsOrigin(targetOrigin)
        clipView.scroll(to: targetOrigin)
        transcriptScrollView.reflectScrolledClipView(clipView)
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
    private var entries: [AITranscriptEntry]
    private var elapsedText: String
    private let onToggle: () -> Void
    private let disclosureButton = NSButton()
    private let detailLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private var renderedDetailMarkdown = ""
    private var detailTopConstraint: NSLayoutConstraint?
    private var separatorTopToDisclosureConstraint: NSLayoutConstraint?
    private var separatorTopToDetailConstraint: NSLayoutConstraint?
    private var lastAppliedCollapsedState: Bool?

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

    func update(entries: [AITranscriptEntry], elapsedText: String) {
        self.entries = entries
        self.elapsedText = elapsedText
        updateDetailContentIfNeeded()
        updatePresentation()
    }

    private func configure() {
        setAccessibilityIdentifier("Stacio.AI.transcript.processGroup")
        translatesAutoresizingMaskIntoConstraints = false

        disclosureButton.font = .systemFont(ofSize: 12, weight: .medium)
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.imagePosition = .imageTrailing
        disclosureButton.imageScaling = .scaleProportionallyDown
        disclosureButton.alignment = .left
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.target = self
        disclosureButton.action = #selector(togglePressed(_:))
        disclosureButton.setAccessibilityIdentifier("Stacio.AI.transcript.processDisclosure")
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.cell?.wraps = true
        detailLabel.cell?.usesSingleLineMode = false
        detailLabel.isSelectable = true
        detailLabel.allowsEditingTextAttributes = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureButton)
        addSubview(detailLabel)
        addSubview(separator)
        let detailTop = detailLabel.topAnchor.constraint(equalTo: disclosureButton.bottomAnchor, constant: 8)
        let separatorTopToDisclosure = separator.topAnchor.constraint(
            equalTo: disclosureButton.bottomAnchor,
            constant: 8
        )
        let separatorTopToDetail = separator.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8)
        detailTopConstraint = detailTop
        separatorTopToDisclosureConstraint = separatorTopToDisclosure
        separatorTopToDetailConstraint = separatorTopToDetail
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosureButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            disclosureButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailTop,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorTopToDisclosure,
            separatorTopToDetail,
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        updateDetailContentIfNeeded()
        updatePresentation()
    }

    private func updateDetailContentIfNeeded() {
        let detailMarkdown = entries.map(\.text).joined(separator: "\n\n")
        guard detailMarkdown != renderedDetailMarkdown else { return }
        renderedDetailMarkdown = detailMarkdown
        detailLabel.attributedStringValue = AIAssistantMarkdownRenderer.attributedString(
            from: detailMarkdown,
            baseFont: .systemFont(ofSize: 11),
            textColor: .secondaryLabelColor
        )
        detailLabel.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updatePresentation() {
        let collapsed = isCollapsed
        if disclosureButton.title != elapsedText {
            disclosureButton.title = elapsedText
        }
        guard lastAppliedCollapsedState != collapsed else { return }
        lastAppliedCollapsedState = collapsed
        disclosureButton.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: collapsed ? "展开处理过程" : "折叠处理过程"
        )
        disclosureButton.toolTip = collapsed ? "展开思考和执行过程" : "折叠思考和执行过程"
        detailLabel.isHidden = collapsed
        detailTopConstraint?.priority = collapsed ? .defaultLow : .required
        separatorTopToDisclosureConstraint?.priority = collapsed ? .required : .defaultLow
        separatorTopToDetailConstraint?.priority = collapsed ? .defaultLow : .required
        needsLayout = true
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
    private var entry: AITranscriptEntry
    private let onToggle: () -> Void
    private let bubbleView = NSView()
    private let label = AITranscriptLinkLabel(frame: .zero)
    private let attachmentStack = NSStackView()
    private let disclosureButton = NSButton()
    private var executionCardView: ExecutionCardView?
    private var executionExpanded: Bool
    private let onOpenTerminal: (String) -> Void
    private let onCancelExecution: (String) -> Void
    private let onSaveRedactedLog: (TerminalArtifactPresentation) -> Void
    private let onExecutionExpandedChange: (Bool) -> Void
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
        onToggle: @escaping () -> Void = {},
        executionExpanded: Bool = false,
        onOpenTerminal: @escaping (String) -> Void = { _ in },
        onCancelExecution: @escaping (String) -> Void = { _ in },
        onSaveRedactedLog: @escaping (TerminalArtifactPresentation) -> Void = { _ in },
        onExecutionExpandedChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.entry = entry
        self.onToggle = onToggle
        self.executionExpanded = executionExpanded
        self.onOpenTerminal = onOpenTerminal
        self.onCancelExecution = onCancelExecution
        self.onSaveRedactedLog = onSaveRedactedLog
        self.onExecutionExpandedChange = onExecutionExpandedChange
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

    var attachmentTitlesForTesting: [String] {
        attachmentStack.arrangedSubviews.compactMap {
            ($0 as? AITranscriptAttachmentCardView)?.titleForTesting
        }
    }

    var executionCardForTesting: ExecutionCardView? { executionCardView }

    @discardableResult
    func update(entry newEntry: AITranscriptEntry) -> Bool {
        guard entry.role == newEntry.role,
              entry.isProcessEntry == newEntry.isProcessEntry,
              entry.attachments == newEntry.attachments,
              (entry.executionCard == nil) == (newEntry.executionCard == nil)
        else {
            return false
        }

        let displayTextChanged = entry.displayText != newEntry.displayText
        entry = newEntry
        if let presentation = newEntry.executionCard {
            executionCardView?.apply(presentation, expanded: executionExpanded)
            invalidateIntrinsicContentSize()
            needsLayout = true
            return true
        }
        setAccessibilityIdentifier(entry.bubbleAccessibilityIdentifier)
        bubbleView.layer?.cornerRadius = entry.bubbleCornerRadius
        StacioDesignSystem.setLayerBackgroundColor(bubbleView, color: entry.bubbleColor)
        StacioDesignSystem.setLayerBorderColor(bubbleView, color: entry.borderColor)
        bubbleView.layer?.borderWidth = entry.borderColor == nil ? 0 : 1
        label.setAccessibilityIdentifier(entry.textAccessibilityIdentifier)
        label.font = entry.font
        label.textColor = entry.textColor

        if displayTextChanged {
            if entry.role == .assistant {
                let renderedString = AIAssistantMarkdownRenderer.attributedString(
                    from: entry.displayText,
                    baseFont: entry.font,
                    textColor: entry.textColor
                )
                renderedAssistantString = renderedString
                label.attributedStringValue = renderedString
            } else {
                renderedAssistantString = nil
                label.stringValue = entry.displayText
            }
            label.invalidateIntrinsicContentSize()
            bubbleView.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
        }
        updateDisclosureButton()
        updatePreferredWidth()
        needsLayout = true
        return true
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
        label.allowsEditingTextAttributes = true
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
        if let presentation = entry.executionCard {
            let card = ExecutionCardView()
            executionCardView = card
            card.onOpenTerminal = onOpenTerminal
            card.onCancel = onCancelExecution
            card.onSaveRedactedLog = onSaveRedactedLog
            card.onExpandedChange = { [weak self] expanded in
                guard let self else { return }
                self.executionExpanded = expanded
                self.invalidateIntrinsicContentSize()
                self.bubbleView.invalidateIntrinsicContentSize()
                self.needsLayout = true
                self.onExecutionExpandedChange(expanded)
            }
            bubbleView.addSubview(card)
            bubbleWidthConstraint = bubbleView.widthAnchor.constraint(
                lessThanOrEqualToConstant: preferredTextWidth
            )
            bubbleWidthConstraint?.isActive = true
            NSLayoutConstraint.activate([
                bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: entry.verticalInset),
                bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -entry.verticalInset),
                bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
                card.topAnchor.constraint(equalTo: bubbleView.topAnchor),
                card.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor)
            ])
            card.apply(presentation, expanded: executionExpanded)
            return
        }
        bubbleView.addSubview(label)
        if entry.attachments.isEmpty == false {
            attachmentStack.orientation = .vertical
            attachmentStack.spacing = 6
            attachmentStack.alignment = .leading
            attachmentStack.distribution = .fill
            attachmentStack.translatesAutoresizingMaskIntoConstraints = false
            attachmentStack.setAccessibilityIdentifier("Stacio.AI.transcript.attachments")
            bubbleView.addSubview(attachmentStack)
            for (index, attachment) in entry.attachments.enumerated() {
                let card = AITranscriptAttachmentCardView(attachment: attachment, index: index)
                attachmentStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: attachmentStack.widthAnchor).isActive = true
                card.heightAnchor.constraint(equalToConstant: 50).isActive = true
            }
        }
        if entry.isProcessEntry {
            disclosureButton.title = ""
            disclosureButton.isBordered = false
            disclosureButton.imageScaling = .scaleProportionallyDown
            disclosureButton.target = self
            disclosureButton.action = #selector(togglePressed(_:))
            disclosureButton.setAccessibilityIdentifier("Stacio.AI.transcript.processDisclosure")
            disclosureButton.translatesAutoresizingMaskIntoConstraints = false
            updateDisclosureButton()
            bubbleView.addSubview(disclosureButton)
        }

        bubbleWidthConstraint = bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: preferredTextWidth)
        bubbleWidthConstraint?.isActive = true

        var constraints: [NSLayoutConstraint] = [
            bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: entry.verticalInset),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -entry.verticalInset),
            label.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: entry.horizontalPadding),
            label.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -entry.verticalPadding)
        ]
        if entry.attachments.isEmpty {
            constraints.append(
                label.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: entry.verticalPadding)
            )
        } else {
            constraints += [
                attachmentStack.leadingAnchor.constraint(
                    equalTo: bubbleView.leadingAnchor,
                    constant: entry.horizontalPadding
                ),
                attachmentStack.trailingAnchor.constraint(
                    equalTo: bubbleView.trailingAnchor,
                    constant: -entry.horizontalPadding
                ),
                attachmentStack.topAnchor.constraint(
                    equalTo: bubbleView.topAnchor,
                    constant: entry.verticalPadding
                ),
                label.topAnchor.constraint(equalTo: attachmentStack.bottomAnchor, constant: 8)
            ]
        }
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

    private func updateDisclosureButton() {
        guard entry.isProcessEntry else { return }
        disclosureButton.image = NSImage(
            systemSymbolName: entry.isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: entry.isCollapsed ? "展开过程" : "折叠过程"
        )
        disclosureButton.toolTip = entry.isCollapsed ? "展开思考和执行过程" : "折叠思考和执行过程"
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

private final class AITranscriptAttachmentCardView: NSView {
    private let attachment: AITranscriptAttachment

    init(attachment: AITranscriptAttachment, index: Int) {
        self.attachment = attachment
        super.init(frame: .zero)
        configure(index: index)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var titleForTesting: String {
        attachment.filename
    }

    private func configure(index: Int) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        StacioDesignSystem.setLayerBackgroundColor(self, color: NSColor.white.withAlphaComponent(0.13))
        StacioDesignSystem.setLayerBorderColor(self, color: NSColor.white.withAlphaComponent(0.18))
        setAccessibilityIdentifier("Stacio.AI.transcript.attachment.\(index)")
        setAccessibilityLabel("附件：\(attachment.filename)，\(attachment.metadataText)")

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: attachment.isImage ? "photo" : "doc.text",
            accessibilityDescription: attachment.filename
        )
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: attachment.filename)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let metadata = NSTextField(labelWithString: attachment.metadataText)
        metadata.font = .systemFont(ofSize: 10, weight: .medium)
        metadata.textColor = NSColor.white.withAlphaComponent(0.72)
        metadata.lineBreakMode = .byTruncatingTail
        metadata.translatesAutoresizingMaskIntoConstraints = false

        [icon, title, metadata].forEach(addSubview)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
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
    private let showsAttachments: Bool
    private let showsGoalMode: Bool
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 4
    private static let inset: CGFloat = 10

    init(
        planModeEnabled: Bool,
        goalModeEnabled: Bool,
        currentFileEnabled: Bool,
        showsAttachments: Bool = true,
        showsGoalMode: Bool = true
    ) {
        self.planModeEnabled = planModeEnabled
        self.goalModeEnabled = goalModeEnabled
        self.currentFileEnabled = currentFileEnabled
        self.showsAttachments = showsAttachments
        self.showsGoalMode = showsGoalMode
        super.init(nibName: nil, bundle: nil)
        let visibleRowCount = (showsAttachments ? 2 : 0) + 1 + (showsGoalMode ? 1 : 0)
        let contentInset = showsAttachments && showsGoalMode ? CGFloat(4) : Self.inset
        let height = contentInset * 2
            + CGFloat(visibleRowCount) * Self.rowHeight
            + CGFloat(max(0, visibleRowCount - 1)) * Self.rowSpacing
        preferredContentSize = NSSize(width: 172, height: height)
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

        var visibleButtons: [NSButton] = []
        if showsAttachments {
            visibleButtons.append(contentsOf: [addFilesButton, addCurrentFileButton])
        }
        visibleButtons.append(planButton)
        if showsGoalMode {
            visibleButtons.append(goalButton)
        }
        visibleButtons.forEach { button in
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        container.addSubview(stack)

        let contentInset = showsAttachments && showsGoalMode ? CGFloat(4) : Self.inset
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: contentInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -contentInset)
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
        if showsGoalMode {
            updateToggleButton(goalButton, isOn: goalModeEnabled)
        }
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
        var titles: [String] = []
        if showsAttachments {
            titles.append(contentsOf: [addFilesButton.title, addCurrentFileButton.title])
        }
        titles.append(planButton.title)
        if showsGoalMode { titles.append(goalButton.title) }
        return titles
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
        var buttons: [NSButton] = []
        if showsAttachments {
            buttons.append(contentsOf: [addFilesButton, addCurrentFileButton])
        }
        buttons.append(planButton)
        if showsGoalMode { buttons.append(goalButton) }
        return buttons.map(\.frame.height)
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

private final class AIComposerPrimaryActionButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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

private struct AIComposerLocalAgentPickerOption {
    let configuration: LocalAgentPassthroughConfiguration
}

private struct AIComposerLegacyLocalAgentPickerOption {
    let tool: LocalAgentTool
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
    let currentRuntimeSelection: AgentRuntimeSelection?
    let currentLegacyLocalAgentTool: LocalAgentTool?
    let specialOptions: [AIComposerModelPickerSpecialOption]
    let groups: [AIComposerModelPickerGroup]
    let localAgentOptions: [AIComposerLocalAgentPickerOption]
    let legacyLocalAgentOptions: [AIComposerLegacyLocalAgentPickerOption]
    let localAgentSettingsActionTitle: String?
    let reasoningItems: [(title: String, effort: AIReasoningEffortPreference)]
    let currentReasoning: AIReasoningEffortPreference
    let contextFraction: Double
    let contextLabel: String
    let runtimeSelectionEnabled: Bool
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
    var onSelectLocalAgent: ((LocalAgentPassthroughConfiguration) -> Void)?
    var onSelectLegacyLocalAgent: ((LocalAgentTool) -> Void)?
    var onOpenLocalAgentSettings: (() -> Void)?
    var onSelectReasoning: ((AIReasoningEffortPreference) -> Void)?

    private let rootStack = NSStackView()
    private let providerLabel = NSTextField(labelWithString: "")
    private let contextRing = AIContextUsageRingView()
    private let contextPercentLabel = NSTextField(labelWithString: "")
    private let contextCaptionLabel = NSTextField(labelWithString: "上下文")
    private let modelsScrollView = NSScrollView()
    private let modelsDocumentView = AIAssistantFlippedView()
    private let modelsStack = NSStackView()
    private let reasoningHeader = NSTextField(labelWithString: "推理强度")
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

        reasoningHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        reasoningHeader.textColor = .secondaryLabelColor
        reasoningHeader.translatesAutoresizingMaskIntoConstraints = false
        reasoningHeader.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.reasoningHeader")
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
        let showsReasoning = Self.showsReasoningSection(for: state)
        reasoningHeader.isHidden = showsReasoning == false
        reasoningControl.isHidden = showsReasoning == false
    }

    private func renderModels() {
        modelsStack.arrangedSubviews.forEach { view in
            modelsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if state.specialOptions.isEmpty,
           state.groups.isEmpty,
           state.localAgentOptions.isEmpty,
           state.localAgentSettingsActionTitle == nil {
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
            button.isEnabled = state.runtimeSelectionEnabled
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.cell?.lineBreakMode = .byTruncatingMiddle
            let isCurrent = state.currentRuntimeSelection?.kind != .localAgent
                && option.selection == state.currentSelection
            button.image = isCurrent
                ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前模型")
                : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选模型")
            button.imagePosition = .imageLeading
            button.contentTintColor = isCurrent
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
                color: isCurrent
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
                button.isEnabled = state.runtimeSelectionEnabled
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                let isCurrent = state.currentRuntimeSelection?.kind != .localAgent
                    && selection == state.currentSelection
                button.image = isCurrent
                    ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前模型")
                    : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选模型")
                button.imagePosition = .imageLeading
                button.contentTintColor = isCurrent
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
                    color: isCurrent
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
        }
        if state.localAgentOptions.isEmpty == false
            || state.legacyLocalAgentOptions.isEmpty == false
            || state.localAgentSettingsActionTitle != nil {
            let heading = makeSectionLabel("本地 Coding Agent")
            heading.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.localAgents")
            modelsStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
            for option in state.localAgentOptions {
                let configuration = option.configuration
                let button = AIComposerLocalAgentButton(
                    title: configuration.displayName,
                    target: self,
                    action: #selector(localAgentPressed(_:))
                )
                button.configuration = configuration
                button.isEnabled = state.runtimeSelectionEnabled
                let isCurrent = state.currentRuntimeSelection?.kind == .localAgent
                    && state.currentRuntimeSelection?.localAgentConfigurationID == configuration.configurationID
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                let isStructured = configuration.isReadyForStructuredRuntime
                button.image = NSImage(
                    systemSymbolName: isCurrent
                        ? "checkmark.circle.fill"
                        : (isStructured ? "sparkles" : "terminal"),
                    accessibilityDescription: isCurrent
                        ? "当前 Runtime"
                        : (isStructured ? "结构化本地 Agent Runtime" : "本地终端 Runtime")
                )
                button.imagePosition = .imageLeading
                button.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
                button.toolTip = isStructured
                    ? "\(configuration.displayName) · 结构化会话"
                    : "\(configuration.displayName) · 本地终端透传"
                button.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.localAgent.\(configuration.tool.rawValue)"
                )
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    button,
                    color: isCurrent
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
            for option in state.legacyLocalAgentOptions {
                let tool = option.tool
                let button = AIComposerLocalAgentButton(
                    title: "\(tool.displayName) · 兼容本地 CLI",
                    target: self,
                    action: #selector(legacyLocalAgentPressed(_:))
                )
                button.legacyTool = tool
                button.isEnabled = state.runtimeSelectionEnabled
                let isCurrent = state.currentRuntimeSelection?.kind != .localAgent
                    && state.currentLegacyLocalAgentTool == tool
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                button.image = NSImage(
                    systemSymbolName: isCurrent ? "checkmark.circle.fill" : "terminal",
                    accessibilityDescription: isCurrent ? "当前兼容 Runtime" : "兼容本地终端 Runtime"
                )
                button.imagePosition = .imageLeading
                button.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
                button.toolTip = "\(tool.displayName) · 兼容本地 CLI，仅使用受管 PTY"
                button.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.legacyLocalAgent.\(tool.rawValue)"
                )
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    button,
                    color: isCurrent
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
            if let title = state.localAgentSettingsActionTitle {
                let settingsButton = NSButton(
                    title: title,
                    target: self,
                    action: #selector(openLocalAgentSettings)
                )
                settingsButton.bezelStyle = .regularSquare
                settingsButton.isBordered = false
                settingsButton.alignment = .left
                settingsButton.font = .systemFont(ofSize: 12, weight: .medium)
                settingsButton.image = NSImage(
                    systemSymbolName: "gearshape",
                    accessibilityDescription: title
                )
                settingsButton.imagePosition = .imageLeading
                settingsButton.contentTintColor = .secondaryLabelColor
                settingsButton.toolTip = "在设置 > AI > 本地 Agent 中检测、登录并启用 CLI"
                settingsButton.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.localAgent.settings"
                )
                settingsButton.translatesAutoresizingMaskIntoConstraints = false
                settingsButton.wantsLayer = true
                settingsButton.layer?.cornerRadius = StacioDesignSystem.theme.controlCornerRadius
                settingsButton.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    settingsButton,
                    color: NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(settingsButton)
                settingsButton.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                settingsButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
        reasoningControl.isEnabled = state.runtimeSelectionEnabled
    }

    private static func preferredSize(for state: AIComposerModelPickerState) -> NSSize {
        let reasoningSectionHeight = showsReasoningSection(for: state)
            ? sectionLabelHeight + reasoningHeight
            : CGFloat(0)
        let height = verticalPadding
            + headerHeight
            + rootSpacingTotal
            + sectionLabelHeight
            + modelListHeight(for: state)
            + reasoningSectionHeight
        return NSSize(width: width, height: min(max(height, minimumHeight), maximumHeight))
    }

    private static func showsReasoningSection(for state: AIComposerModelPickerState) -> Bool {
        state.currentRuntimeSelection?.kind != .localAgent
            && state.currentLegacyLocalAgentTool == nil
            && state.reasoningItems.isEmpty == false
    }

    private static func modelListHeight(for state: AIComposerModelPickerState) -> CGFloat {
        guard state.specialOptions.isEmpty == false
                || state.groups.isEmpty == false
                || state.localAgentOptions.isEmpty == false
                || state.legacyLocalAgentOptions.isEmpty == false
                || state.localAgentSettingsActionTitle != nil else {
            return modelRowHeight
        }
        let modelCount = state.specialOptions.count
            + state.groups.reduce(0) { $0 + $1.models.count }
            + state.localAgentOptions.count
            + state.legacyLocalAgentOptions.count
            + (state.localAgentSettingsActionTitle == nil ? 0 : 1)
        let headingCount = state.groups.count
            + ((state.localAgentOptions.isEmpty
                && state.legacyLocalAgentOptions.isEmpty
                && state.localAgentSettingsActionTitle == nil) ? 0 : 1)
        let rowCount = modelCount + headingCount
        let spacing = CGFloat(max(rowCount - 1, 0)) * modelRowSpacing
        let headingsHeight = CGFloat(headingCount) * sectionLabelHeight
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
    private func localAgentPressed(_ sender: AIComposerLocalAgentButton) {
        guard let configuration = sender.configuration else { return }
        onSelectLocalAgent?(configuration)
    }

    @objc
    private func legacyLocalAgentPressed(_ sender: AIComposerLocalAgentButton) {
        guard let tool = sender.legacyTool else { return }
        onSelectLegacyLocalAgent?(tool)
    }

    @objc
    private func openLocalAgentSettings() {
        onOpenLocalAgentSettings?()
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
        return state.specialOptions.map(\.title)
            + state.groups.flatMap { $0.models.map(\.modelID) }
            + state.localAgentOptions.map { $0.configuration.displayName }
            + state.legacyLocalAgentOptions.map { "\($0.tool.displayName) · 兼容本地 CLI" }
            + [state.localAgentSettingsActionTitle].compactMap { $0 }
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

    var showsReasoningForTesting: Bool {
        loadViewIfNeeded()
        update(state: state)
        return reasoningHeader.isHidden == false && reasoningControl.isHidden == false
    }
}

private final class AIComposerLocalAgentButton: NSButton {
    var configuration: LocalAgentPassthroughConfiguration?
    var legacyTool: LocalAgentTool?
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

private struct AITranscriptAttachment: Equatable {
    let filename: String
    let displayKind: String
    let byteCount: Int
    let isImage: Bool

    init(_ attachment: AIAssistantAttachment) {
        filename = attachment.filename
        displayKind = attachment.displayKind
        byteCount = attachment.byteCount
        isImage = attachment.isImage
    }

    var metadataText: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(displayKind) · \(size)"
    }
}

private struct AITranscriptEntry {
    let id: UUID
    let role: AITranscriptRole
    var text: String
    var conversationContent: String? = nil
    var attachments: [AITranscriptAttachment] = []
    let requestID: String?
    var isProcessEntry: Bool = false
    var processGroupID: UUID? = nil
    var isCollapsed: Bool = false
    var createdAt: Date = Date()
    var executionCard: ExecutionCardPresentation? = nil

    init(
        id: UUID = UUID(),
        role: AITranscriptRole,
        text: String,
        conversationContent: String? = nil,
        attachments: [AITranscriptAttachment] = [],
        requestID: String?,
        isProcessEntry: Bool = false,
        processGroupID: UUID? = nil,
        isCollapsed: Bool = false,
        createdAt: Date = Date(),
        executionCard: ExecutionCardPresentation? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.conversationContent = conversationContent
        self.attachments = attachments
        self.requestID = requestID
        self.isProcessEntry = isProcessEntry
        self.processGroupID = processGroupID
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
        self.executionCard = executionCard
    }

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
            return StacioDesignSystem.theme.primaryTextColor
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
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.48)
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
        case .user:
            return StacioDesignSystem.theme.accentColor.withAlphaComponent(0.32)
        case .assistant, .system:
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
        case .user:
            return StacioDesignSystem.theme.panelCornerRadius
        case .assistant, .system:
            return 0
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
