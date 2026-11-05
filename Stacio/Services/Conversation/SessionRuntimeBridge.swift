import CryptoKit
import Foundation
import StacioAgentBridge

public struct PendingToolDecisionPresentation: Equatable, Sendable {
    public let proposalID: String
    public let decisionID: String
    public let command: String
    public let explanation: String
    public let risk: String
    public let targetTitle: String
    public let targetWorkingDirectory: String
    public let executionDestination: String
    public let targetBindingDigest: String
    public let targetRuntimeGeneration: UInt64?
    public let immutableSummary: String
    public let deadline: Date?
    public let index: Int
    public let total: Int
    public let isActionable: Bool
    public let statusMessage: String?

    public init(
        proposalID: String,
        decisionID: String,
        command: String,
        explanation: String,
        risk: String,
        targetTitle: String,
        targetWorkingDirectory: String = "未验证",
        executionDestination: String = "未验证",
        targetBindingDigest: String = "未验证",
        targetRuntimeGeneration: UInt64? = nil,
        immutableSummary: String = "未验证",
        deadline: Date? = nil,
        index: Int,
        total: Int,
        isActionable: Bool = true,
        statusMessage: String? = nil
    ) {
        self.proposalID = proposalID
        self.decisionID = decisionID
        self.command = command
        self.explanation = explanation
        self.risk = risk
        self.targetTitle = targetTitle
        self.targetWorkingDirectory = targetWorkingDirectory
        self.executionDestination = executionDestination
        self.targetBindingDigest = targetBindingDigest
        self.targetRuntimeGeneration = targetRuntimeGeneration
        self.immutableSummary = immutableSummary
        self.deadline = deadline
        self.index = index
        self.total = total
        self.isActionable = isActionable
        self.statusMessage = statusMessage
    }
}

/// Composer、持久化状态机与 Native Runtime 之间的单会话编排器。
/// 所有 UI 状态在主线程维护；加密与 Rust/SQLite 提交通过 ConversationSessionActor 异步串行执行。
@MainActor
public final class SessionRuntimeBridge {
    public enum AccessMode: Equatable, Sendable {
        case interactive
        case readOnlyHistory
    }

    public enum SendResult: Equatable {
        case accepted(turnID: String)
        case queued(position: Int)
        case rejected(reason: SendRejection)
    }

    public enum SendRejection: Equatable {
        case empty
        case readOnly
        case draining
        case storageUnavailable
        case providerUnavailable
        case runtimeUnavailable
        case settingsUnavailable
        case targetUnavailable
        case executionChoiceRequired
        case alreadyRunning
    }

    public enum ToolDecisionResult: Equatable {
        case accepted
        case rejected(reason: String)
    }

    public var onTimelineUpdate: (([TimelineSourceEntry]) -> Void)? {
        didSet { renderTimeline() }
    }

    public var onRuntimeUnavailable: ((String) -> Void)? {
        didSet {
            if let lastUserFacingError {
                onRuntimeUnavailable?(lastUserFacingError)
            }
        }
    }

    /// `forceRefresh` is true only when a UI-originated mutation did not
    /// commit. Consumers must then discard any optimistic cell/control state
    /// and render this durable projection again.
    public var onQueueUpdate: (([QueuedInput], Bool, Bool) -> Void)? {
        didSet { publishComposerState() }
    }

    public var onDraftRestored: ((String) -> Void)? {
        didSet {
            if let draft = latestState.session.draft {
                onDraftRestored?(draft)
            }
        }
    }

    public var onRunPhaseUpdate: ((ComposerRunPhase) -> Void)? {
        didSet { onRunPhaseUpdate?(composerRunPhase) }
    }

    public var onToolDecisionUpdate: ((PendingToolDecisionPresentation?) -> Void)? {
        didSet { publishToolDecision() }
    }

    /// 下一轮会话选择变化时的轻量 UI 投影。当前 Attempt 的快照不会被之后的选择改写。
    public var onSelectionUpdate: ((TurnWorkMode, TurnExecutionChoice) -> Void)? {
        didSet {
            onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
        }
    }

    public var onRuntimeSelectionUpdate: ((AgentRuntimeSelection) -> Void)? {
        didSet { onRuntimeSelectionUpdate?(latestState.session.runtimeSelection) }
    }

    public var onTargetUpdate: ((String) -> Void)? {
        didSet { onTargetUpdate?(currentTargetIdentity) }
    }

    public var onSessionMetadataUpdate: ((ConversationSession) -> Void)? {
        didSet { onSessionMetadataUpdate?(latestState.session) }
    }

    public var storageError: ConversationStorageError? {
        didSet {
            guard let storageError else { return }
            sessionBlocked = true
            reportError("\(storageError.summary)。\(storageError.recoveryHint)")
        }
    }

    private struct ActiveTurn {
        let turnID: String
        let attemptID: String
        let userRequest: String
        let generation: UInt64
        let workMode: TurnWorkMode
        let executionChoice: TurnExecutionChoice
        let targetRuntimeID: String?
        let targetRuntimeGeneration: UInt64?
        let targetBinding: TargetBinding
        let providerBinding: ProviderRuntimeBinding?
        let runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot?
        let toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot?
        let toolCapabilitySnapshot: ToolCapabilitySnapshot?
        var admissionRequest: GlobalExecutionAdmissionRequest? = nil
        var admissionLease: GlobalExecutionAdmissionLease? = nil
        var accumulatedAnswer: String
        var pendingCheckpoint: String
        var settling: Bool
    }

    private final class PendingLocalAgentDelivery {
        let generation: UInt64
        let configurationID: String
        let executionProfileID: String
        let configurationDigest: String
        let configuration: LocalAgentPassthroughConfiguration
        let processWorkingDirectory: AgentProcessWorkingDirectory
        let draftToken: UInt64?
        let text: String
        let deliver: @MainActor () -> LocalAgentInputSendResult
        var immediateResult: SendResult?

        init(
            generation: UInt64,
            configurationID: String,
            executionProfileID: String,
            configurationDigest: String,
            configuration: LocalAgentPassthroughConfiguration,
            processWorkingDirectory: AgentProcessWorkingDirectory,
            draftToken: UInt64?,
            text: String,
            deliver: @escaping @MainActor () -> LocalAgentInputSendResult
        ) {
            self.generation = generation
            self.configurationID = configurationID
            self.executionProfileID = executionProfileID
            self.configurationDigest = configurationDigest
            self.configuration = configuration
            self.processWorkingDirectory = processWorkingDirectory
            self.draftToken = draftToken
            self.text = text
            self.deliver = deliver
        }
    }

    private enum ArchivedTurnStatus: Equatable {
        case progress(String)
        case recovery(String)
    }

    private struct ArchivedTurn: Equatable {
        let turnID: String
        let attemptID: String
        let userRequest: String
        let finalAnswer: String
        let status: ArchivedTurnStatus?
        let toolEntries: [TimelineSourceEntry]
    }

    private struct DraftSpec {
        let kind: ConversationEventKind
        let payload: Data
        let scope: ConversationEventScope
        let source: String

        init(
            _ kind: ConversationEventKind,
            payload: Data = Data(),
            scope: ConversationEventScope = .attempt,
            source: String = "runtime"
        ) {
            self.kind = kind
            self.payload = payload
            self.scope = scope
            self.source = source
        }
    }

    private struct ToolExecutionEventPayload: Codable {
        let proposalID: String
        let requestID: String
        let state: String
        let summary: String
    }

    private struct SubmissionBatch {
        let specs: [DraftSpec]
        let turnID: String?
        let attemptID: String?

        init(specs: [DraftSpec], turnID: String? = nil, attemptID: String? = nil) {
            self.specs = specs
            self.turnID = turnID
            self.attemptID = attemptID
        }
    }

    private enum ReplayError: Error {
        case invalidSequence
        case invalidTransition
    }

    private struct ReplayResult {
        let state: ConversationSessionState
        let archivedTurns: [ArchivedTurn]
        let sentHistory: [String]
        let turnCount: Int
        let proposalPayloads: [String: ConversationToolProposalPayload]
        let traceEventsByProposalID: [String: [AgentTraceEvent]]
        let queuePreferencePersisted: Bool
    }

    private struct OutboxRecoveryDisposition {
        var requiresReconciliation = false
    }

    private struct RecoveredToolResolutionEvidence {
        let attemptID: String
        let resolution: ToolProposalResolutionPayload
        let terminalState: AgentTraceState
    }

    private let actor: ConversationSessionActor
    private let sessionID: String
    private let replayBaseState: ConversationSessionState
    private let accessMode: AccessMode
    private let persistsSessionCreationEvent: Bool
    private let terminalContextProvider: () -> AITerminalContext?
    private let targetContextResolver: ((String?) -> AITerminalContext?)?
    private let settingsProvider: () -> AppSettings
    private let terminalAutomationPolicyProvider: (String?) -> SessionAutomationPolicy?
    private let executionCoordinator: AgentCommandStreamingExecuting?
    private let executionModeSnapshotHandler: ((TurnExecutionChoice) -> Void)?
    private let runtimeSettingsProvider: () throws -> AssistantRuntimeSettingsSnapshot
    /// The V2 control plane is authoritative for admitting *new* work. It is
    /// deliberately checked at submission boundaries instead of being copied
    /// once when the Inspector shell is assembled, so a transition to draining
    /// cannot race a queued Composer action into a new Attempt.
    private let submissionGate: () -> Bool
    private let monotonicNowProvider: () -> TimeInterval
    private let toolCatalog: StacioToolCatalog?
    private let providerResolver: () -> (
        provider: AIAssistantStreamingProviding,
        configuration: ProviderRuntimeConfiguration
    )?
    private let providerConfigurationResolver: ((String) -> (
        provider: AIAssistantStreamingProviding,
        configuration: ProviderRuntimeConfiguration
    )?)?
    private let providerSelectionResolver: ((String, String?) -> (
        provider: AIAssistantStreamingProviding,
        configuration: ProviderRuntimeConfiguration
    )?)?
    private let admissionCoordinator: AgentExecutionAdmissionCoordinating
    private var provider: AIAssistantStreamingProviding?
    private var providerConfig: ProviderRuntimeConfiguration?
    private var queuedProviderBindings: [String: ProviderRuntimeBinding] = [:]
    private var runtime: NativeStreamingRuntime?
    private var structuredLocalAgentRuntime: StructuredLocalAgentRuntime?
    private var activeStructuredLocalAgentConfiguration: LocalAgentPassthroughConfiguration?
    private var stateObserverToken: UUID?

    private var latestState: ConversationSessionState
    private var activeTurn: ActiveTurn?
    private var ownedRuntimeAttemptID: String?
    private var archivedTurns: [ArchivedTurn] = []
    private var currentGeneration: UInt64 = 0
    private var turnOrdinal = 0
    private var flushWorkItem: DispatchWorkItem?
    private var draftSaveWorkItem: DispatchWorkItem?
    private var checkpointCommitTask: Task<ConversationSessionActor.SubmitOutcome, Never>?
    private var approvalDeadlineTask: Task<Void, Never>?
    private var scheduledApprovalDecisionID: String?
    private var effectiveExecutionDeadlineTask: Task<Void, Never>?
    private var admissionWaitTask: Task<Void, Never>?
    private var pendingLocalAgentDelivery: PendingLocalAgentDelivery?
    private var effectiveExecutionSegmentStartedAt: TimeInterval?
    private var effectiveExecutionElapsed: TimeInterval = 0
    private var pendingSubmissionOperations: [() async -> Void] = []
    private var isDrainingSubmissionOperations = false
    private var sessionBlocked = false {
        didSet {
            guard sessionBlocked != oldValue else { return }
            // A protection transition is itself an authorization change. Any
            // approval card already on screen must lose its actions
            // immediately, and Composer/queue controls must re-read the
            // durable projection instead of remaining optimistically enabled.
            publishComposerState(forceQueueRefresh: true)
            publishToolDecision()
        }
    }
    private var acceptsNewSubmissions: Bool
    private var restoreInProgress: Bool
    private var restoreTaskRunning = false
    private var pendingDraftDuringRestore: String?
    private var draftMutationGeneration: UInt64 = 0
    private var localDraftText: String
    private var queuePromotionInputID: String?
    private var lastUserFacingError: String?
    private var proposalPayloads: [String: ConversationToolProposalPayload] = [:]
    /// Maps a Codex app-server request to the durable Stacio proposal that is
    /// waiting for approval/execution. The mapping is intentionally in-memory;
    /// the durable proposal remains the source of truth after a restart.
    private var structuredToolCallsByProposalID: [String: StructuredLocalAgentToolCall] = [:]
    private var traceEventsByProposalID: [String: [AgentTraceEvent]] = [:]
    /// A coordinator may deliver the same terminal trace through both its
    /// streaming callback and its returned event array.  Keep one settlement
    /// gate per request so the duplicate cannot enqueue a second durable batch.
    private var terminalTraceRequestIDs = Set<String>()
    private var activeExecutionRequestID: String?
    private var activeExecutionProposalID: String?
    private var activeToolDispatch: ConversationOutboxDispatchRecord?
    private var activeToolDispatchHandedOff = false
    private var activeToolStopRequested = false
    private var activeToolSettlementOutcome: ConversationOutboxSettlementOutcome?
    private var scheduledToolStartProposalID: String?
    private var scheduledToolResumeProposalID: String?
    private var currentRuntimeContext: AITerminalContext?
    private(set) var selectedWorkMode: TurnWorkMode
    private(set) var selectedExecutionChoice: TurnExecutionChoice
    private(set) var selectedTargetRuntimeID: String?
    private var selectedTargetIdentityFallback: String?
    private var toolObservations: [String] = []
    private var lastToolResponseMessage: String?
    private var toolRound = 0
    /// Commands that already completed successfully in the current turn.
    /// Providers may repeat the last read-only command while deciding whether
    /// enough evidence was collected; replaying it only adds latency.
    private var completedToolCommandDigests = Set<String>()
    private var queuePreferencePersisted = false

    public private(set) var sentHistory: [String] = []

    private var hasDurableActiveTurn: Bool {
        latestState.activeAttempt.map { $0.phase.isTerminal == false } ?? false
    }

    public var isIdle: Bool { activeTurn == nil && hasDurableActiveTurn == false }
    public var isRestoring: Bool { restoreInProgress }
    public var isSessionUsable: Bool {
        accessMode == .interactive
            && restoreInProgress == false
            && storageError == nil
            && sessionBlocked == false
    }
    /// A nil error after a false restore identifies a valid, empty repository.
    /// Presentation may use this distinction but must never infer a retry.
    public var currentUserFacingError: String? { lastUserFacingError }
    public var isReadOnlyHistory: Bool { accessMode == .readOnlyHistory }
    public var isEmptyTransientSession: Bool {
        latestState.lastAppliedSequence == 0
            && isIdle
            && storageError == nil
            && sessionBlocked == false
            && latestState.session.queuedInputs.isEmpty
            && localDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var acceptsNewTurns: Bool {
        acceptsNewSubmissions
            && isSessionUsable
            && submissionGateAllowsNewTurns()
    }
    public var requiresHostClosureSettlement: Bool {
        accessMode == .interactive && (restoreInProgress || isIdle == false)
    }
    public var allowsAlternateRuntimeSelection: Bool {
        acceptsNewSubmissions
            && activeTurn == nil
            && hasDurableActiveTurn == false
            && restoreInProgress == false
            && sessionBlocked == false
            && latestState.session.queuedInputs.isEmpty
    }
    public var queuedCount: Int { latestState.session.queuedInputs.count }
    public var currentSessionTitle: String { latestState.session.title }
    public var currentSession: ConversationSession { latestState.session }
    public var currentAttemptPhase: AttemptPhase? { latestState.activeAttempt?.phase }
    /// Authoritative Composer projection. Hosts must not infer this from an
    /// Attempt phase because recovery terminal states intentionally have no
    /// active Runtime even though they retain the last Attempt for history.
    public var currentRunPhase: ComposerRunPhase { composerRunPhase }
    public var isSessionPinned: Bool { latestState.session.isPinned == true }
    public var isSessionArchived: Bool { latestState.session.archivedAt != nil }
    public var sessionUpdatedAt: Date { latestState.session.updatedAt }
    public var queuedInputs: [QueuedInput] {
        latestState.session.queuedInputs.sorted { $0.position < $1.position }
    }
    public var queueAutoAdvancePaused: Bool { latestState.session.queueAutoAdvancePaused ?? false }
    public var currentDraft: String { localDraftText }
    public var currentTargetIdentity: String {
        if let currentRuntimeContext {
            return currentRuntimeContext.title
        }
        if let selectedTargetRuntimeID {
            if let context = resolveTerminalContext(runtimeID: selectedTargetRuntimeID) {
                return context.title
            }
            let identity = selectedTargetIdentityFallback
                ?? latestState.session.targetBinding.remoteIdentity
            return "\(identity) · 不可用"
        }
        return latestState.session.targetBinding.remoteIdentity
    }
    public var currentTargetRuntimeID: String? { selectedTargetRuntimeID }
    public var currentRuntimeIdentity: String {
        if latestState.session.runtimeSelection.kind == .localAgent {
            let identity = latestState.session.runtimeSelection.localAgentConfigurationID
                ?? "未选择配置"
            return "Local Agent · \(identity)"
        }
        return providerConfig.map {
            let source = $0.runtimeConfigurationKind == .codingPlan ? "Coding Plan" : "Native"
            return "\(source) · \($0.model)"
        } ?? "Native · 未配置"
    }

    public var currentRuntimeSelection: AgentRuntimeSelection {
        latestState.session.runtimeSelection
    }

    public init(
        actor: ConversationSessionActor,
        sessionID: String,
        initialState: ConversationSessionState,
        provider: AIAssistantStreamingProviding? = nil,
        providerConfig: ProviderRuntimeConfiguration? = nil,
        executionCoordinator: AgentCommandStreamingExecuting? = nil,
        terminalContextProvider: @escaping () -> AITerminalContext? = { nil },
        targetContextResolver: ((String?) -> AITerminalContext?)? = nil,
        executionModeSnapshotHandler: ((TurnExecutionChoice) -> Void)? = nil,
        runtimeSettingsProvider: @escaping () throws -> AssistantRuntimeSettingsSnapshot = {
            try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
        },
        submissionGate: @escaping () -> Bool = { true },
        admissionCoordinator: AgentExecutionAdmissionCoordinating? = nil,
        monotonicNowProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        toolCatalog: StacioToolCatalog? = BundledRuntimeCatalog.shared.toolCatalog,
        providerResolver: @escaping () -> (
            provider: AIAssistantStreamingProviding,
            configuration: ProviderRuntimeConfiguration
        )? = {
            LegacyProviderConfigurationAdapter.resolveActiveProvider()
        },
        providerConfigurationResolver: ((String) -> (
            provider: AIAssistantStreamingProviding,
            configuration: ProviderRuntimeConfiguration
        )?)? = nil,
        providerSelectionResolver: ((String, String?) -> (
            provider: AIAssistantStreamingProviding,
            configuration: ProviderRuntimeConfiguration
        )?)? = nil,
        settingsProvider: @escaping () -> AppSettings = { AppSettings() },
        terminalAutomationPolicyProvider: @escaping (String?) -> SessionAutomationPolicy? = { _ in
            SessionAutomationPolicy(
                environment: "development",
                aiExecutionPolicy: "requireEveryCommand"
            )
        },
        initialTargetContext: AITerminalContext? = nil,
        initialExecutionChoice: TurnExecutionChoice = .realTerminal,
        restorePending: Bool = false,
        accessMode: AccessMode = .interactive,
        persistsSessionCreationEvent: Bool = false
    ) {
        self.actor = actor
        self.sessionID = sessionID
        self.latestState = initialState
        self.replayBaseState = initialState
        self.accessMode = accessMode
        self.persistsSessionCreationEvent = persistsSessionCreationEvent
        self.provider = provider
        self.providerConfig = providerConfig
        self.executionCoordinator = executionCoordinator
        self.terminalContextProvider = terminalContextProvider
        self.targetContextResolver = targetContextResolver
        self.executionModeSnapshotHandler = executionModeSnapshotHandler
        self.runtimeSettingsProvider = runtimeSettingsProvider
        self.submissionGate = submissionGate
        self.monotonicNowProvider = monotonicNowProvider
        self.toolCatalog = toolCatalog
        self.providerResolver = providerResolver
        self.providerConfigurationResolver = providerConfigurationResolver
        self.providerSelectionResolver = providerSelectionResolver
        self.admissionCoordinator = admissionCoordinator ?? ProductionAgentExecutionScheduler()
        self.settingsProvider = settingsProvider
        self.terminalAutomationPolicyProvider = terminalAutomationPolicyProvider
        self.restoreInProgress = restorePending
        self.localDraftText = initialState.session.draft ?? ""
        self.acceptsNewSubmissions = accessMode == .interactive
        self.selectedWorkMode = Self.turnWorkMode(for: initialState.session.runtimeSelection.workMode)
        self.selectedExecutionChoice = initialExecutionChoice
        let initialRuntimeID = initialState.session.targetBinding.connectionID
        if initialRuntimeID == "local" || initialRuntimeID.isEmpty {
            self.selectedTargetRuntimeID = initialTargetContext?.runtimeID
            self.selectedTargetIdentityFallback = initialTargetContext?.title
        } else {
            self.selectedTargetRuntimeID = initialRuntimeID
            self.selectedTargetIdentityFallback = initialState.session.targetBinding.remoteIdentity
        }
        self.stateObserverToken = actor.addStateObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleStateChange(state)
            }
        }
    }

    deinit {
        admissionWaitTask?.cancel()
        if let lease = activeTurn?.admissionLease {
            let coordinator = admissionCoordinator
            Task { _ = try? await coordinator.release(lease) }
        } else if let requestID = activeTurn?.admissionRequest?.requestID {
            let coordinator = admissionCoordinator
            Task { _ = try? await coordinator.cancel(requestID: requestID) }
        }
        if let attemptID = ownedRuntimeAttemptID {
            actor.releaseRuntimeOwnership(attemptID: attemptID, owner: self)
        }
        if let stateObserverToken {
            actor.removeStateObserver(stateObserverToken)
        }
        flushWorkItem?.cancel()
        draftSaveWorkItem?.cancel()
        checkpointCommitTask?.cancel()
        approvalDeadlineTask?.cancel()
        effectiveExecutionDeadlineTask?.cancel()
    }

    // MARK: - Next-turn Composer selection

    /// Apply the UI-side drain fence to an already assembled interactive shell.
    /// Existing Runtime/tool settlement remains available, but no new Turn or
    /// queued-input promotion may cross this bridge afterwards.
    public func suspendNewSubmissions() {
        guard accessMode == .interactive else { return }
        acceptsNewSubmissions = false
        publishComposerState()
    }

    /// The process-local fence covers host shutdown. The control-plane gate
    /// covers cross-window/process drain transitions. A failed read is treated
    /// as closed: accepting a new turn without proving authorization would be
    /// worse than asking the user to retry after the control store recovers.
    private func submissionGateAllowsNewTurns() -> Bool {
        guard accessMode == .interactive else { return false }
        return submissionGate()
    }

    /// These controls describe the next submission. Once a turn is committed, its
    /// snapshot remains immutable even if the user changes the controls while it runs.
    public func setWorkMode(_ mode: TurnWorkMode) {
        guard acceptsNewSubmissions, restoreInProgress == false else { return }
        selectedWorkMode = mode
        onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
    }

    public func setExecutionChoice(_ choice: TurnExecutionChoice) {
        guard acceptsNewSubmissions, restoreInProgress == false else { return }
        selectedExecutionChoice = choice
        onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
    }

    @discardableResult
    public func renameSession(to proposedTitle: String) async -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accessMode == .interactive,
              restoreInProgress == false,
              title.isEmpty == false,
              title.count <= 160 else { return false }
        return await commitSessionMetadata(
            title: title,
            pinned: isSessionPinned,
            archivedAt: latestState.session.archivedAt
        )
    }

    @discardableResult
    public func setSessionPinned(_ pinned: Bool) async -> Bool {
        guard accessMode == .interactive, restoreInProgress == false else { return false }
        return await commitSessionMetadata(
            title: latestState.session.title,
            pinned: pinned,
            archivedAt: latestState.session.archivedAt
        )
    }

    @discardableResult
    public func setSessionArchived(_ archived: Bool) async -> Bool {
        guard accessMode == .interactive,
              restoreInProgress == false,
              isIdle else {
            reportError("请先停止当前任务，再归档会话。")
            return false
        }
        return await commitSessionMetadata(
            title: latestState.session.title,
            pinned: isSessionPinned,
            archivedAt: archived ? Date() : nil
        )
    }

    private func commitSessionMetadata(
        title: String,
        pinned: Bool,
        archivedAt: Date?
    ) async -> Bool {
        let payload = ConversationSessionMetadataChangedPayload(
            expectedRevision: latestState.session.metadataRevision ?? 0,
            title: title,
            pinned: pinned,
            archivedAt: archivedAt
        )
        let encoded = EventPayloadCodec.encode(payload) ?? Data()
        guard encoded.isEmpty == false else {
            reportError("无法保存会话信息。")
            return false
        }
        switch await submitBatch([
            DraftSpec(.sessionMetadataChanged, payload: encoded, scope: .session, source: "user")
        ]) {
        case .committed(let state):
            latestState = state
            onSessionMetadataUpdate?(state.session)
            return true
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "保存会话信息")
            return false
        }
    }

    /// Runtime 菜单是 durable session state，不是 ViewController 内存偏好。
    /// 提交成功后调用方才可更新选中项。
    @discardableResult
    public func selectNativeRuntime(
        preferredConfigurationID: String? = nil,
        preferredModelID: String? = nil
    ) async -> Bool {
        guard allowsAlternateRuntimeSelection else { return false }

        let configurationID = preferredConfigurationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = preferredModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitConfiguration = configurationID?.isEmpty == false
        let hasExplicitModel = modelID?.isEmpty == false

        // Resolve a candidate without mutating the active binding. The durable
        // Runtime selection and its in-memory provider must change atomically:
        // a failed menu choice leaves the previously committed route usable.
        // A parameterless switch means "use the Native binding already assembled
        // for this session"; restored Local Agent sessions rely on that behavior.
        let candidate: ProviderRuntimeBinding?
        if hasExplicitConfiguration {
            let resolved: (
                provider: AIAssistantStreamingProviding,
                configuration: ProviderRuntimeConfiguration
            )?
            if let providerSelectionResolver, let configurationID {
                resolved = providerSelectionResolver(
                    configurationID,
                    hasExplicitModel ? modelID : nil
                )
            } else if let providerConfigurationResolver, let configurationID,
                      let fallback = providerConfigurationResolver(configurationID),
                      hasExplicitModel == false || fallback.configuration.model == modelID {
                resolved = fallback
            } else {
                resolved = nil
            }
            candidate = resolved.map {
                ProviderRuntimeBinding(provider: $0.provider, configuration: $0.configuration)
            }
        } else if hasExplicitModel {
            reportError("所选模型缺少供应商配置，未切换 Runtime。")
            return false
        } else if let provider, let providerConfig {
            candidate = ProviderRuntimeBinding(provider: provider, configuration: providerConfig)
        } else {
            candidate = providerResolver().map {
                ProviderRuntimeBinding(provider: $0.provider, configuration: $0.configuration)
            }
        }

        guard let candidate else {
            reportError("未配置有效供应商。请在设置中添加 API Key 并启用一个模型。")
            return false
        }
        let candidateConfig = candidate.configuration
        if let configurationID, configurationID.isEmpty == false,
           candidateConfig.effectiveConfigurationID != configurationID,
           candidateConfig.legacyConfigurationIDs.contains(configurationID) == false {
            reportError("所选供应商已变化，未切换 Runtime。")
            return false
        }
        if let modelID, modelID.isEmpty == false,
           candidateConfig.model != modelID {
            reportError("所选模型不可用，未切换 Runtime。")
            return false
        }
        var selection = nativeRuntimeSelection(
            revision: latestState.session.runtimeSelection.revision,
            configuration: candidateConfig
        )
        if selection == latestState.session.runtimeSelection {
            provider = candidate.provider
            providerConfig = candidateConfig
            lastUserFacingError = nil
            publishComposerState()
            renderTimeline()
            return true
        }
        selection.revision = latestState.session.runtimeSelection.revision + 1
        return await commitRuntimeSelection(selection, providerBinding: candidate)
    }

    @discardableResult
    public func selectLocalAgentRuntime(
        configuration: LocalAgentPassthroughConfiguration
    ) async -> Bool {
        guard configuration.isReadyForTerminalPassthrough else {
            reportError("Local Agent 配置未通过验证，未切换 Runtime。")
            return false
        }
        var selection = AgentRuntimeSelection(
            kind: .localAgent,
            providerConfigurationID: nil,
            codingPlanConfigurationID: nil,
            localAgentConfigurationID: configuration.configurationID,
            localAgentExecutionProfileID: configuration.executionProfileID,
            localAgentExecutionProfileKind: configuration.isReadyForStructuredRuntime
                ? .managed
                : .terminalPassthrough,
            modelID: nil,
            reasoningEffort: nil,
            workMode: .agent,
            revision: latestState.session.runtimeSelection.revision
        )
        if selection == latestState.session.runtimeSelection { return true }
        selection.revision = latestState.session.runtimeSelection.revision + 1
        return await commitRuntimeSelection(selection)
    }

    private func commitRuntimeSelection(
        _ selection: AgentRuntimeSelection,
        providerBinding: ProviderRuntimeBinding? = nil
    ) async -> Bool {
        guard allowsAlternateRuntimeSelection else { return false }
        let payload = RuntimeSelectionChangedPayload(selection: selection)
        switch await submitBatch([
            DraftSpec(
                .runtimeSelectionChanged,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                scope: .session,
                source: "user"
            )
        ], turnID: nil, attemptID: nil) {
        case .committed(let state):
            latestState = state
            if let providerBinding {
                provider = providerBinding.provider
                providerConfig = providerBinding.configuration
                lastUserFacingError = nil
            }
            selectedWorkMode = Self.turnWorkMode(for: selection.workMode)
            if selection.kind == .localAgent {
                selectedExecutionChoice = .realTerminal
            }
            onRuntimeSelectionUpdate?(selection)
            onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
            publishComposerState()
            renderTimeline()
            return true
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "保存 Runtime 选择")
            return false
        }
    }

    /// Bind future turns to a concrete terminal runtime. A resolver is required in
    /// production so a stale/unknown runtime ID cannot silently fall back to the
    /// currently focused terminal.
    @discardableResult
    public func setTargetRuntimeID(_ runtimeID: String?) -> Bool {
        guard acceptsNewSubmissions, restoreInProgress == false else { return false }
        let normalized = runtimeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = normalized?.isEmpty == true ? nil : normalized
        var resolvedContext: AITerminalContext?
        if let candidate {
            resolvedContext = resolveTerminalContext(runtimeID: candidate)
            if targetContextResolver != nil, resolvedContext == nil {
                return false
            }
        }
        selectedTargetRuntimeID = candidate
        selectedTargetIdentityFallback = candidate == nil
            ? nil
            : (resolvedContext?.title ?? selectedTargetIdentityFallback)
        onTargetUpdate?(currentTargetIdentity)
        return true
    }

    /// Reprojects target availability without changing the stable selection.
    /// A disappeared runtime stays selected and renders as unavailable.
    public func refreshTargetAvailability() {
        onTargetUpdate?(currentTargetIdentity)
    }

    public func resolveProvider(
        preferredConfigurationID: String? = nil,
        preferredModelID: String? = nil
    ) {
        guard accessMode == .interactive else { return }
        let resolved: (
            provider: AIAssistantStreamingProviding,
            configuration: ProviderRuntimeConfiguration
        )?
        if let preferredConfigurationID {
            if let providerSelectionResolver {
                resolved = providerSelectionResolver(
                    preferredConfigurationID,
                    preferredModelID
                )
            } else if let candidate = providerConfigurationResolver?(preferredConfigurationID),
                      preferredModelID == nil || candidate.configuration.model == preferredModelID {
                // Older injectors can continue resolving a configuration. If a
                // model is explicit, validate the returned binding instead of
                // accepting its provider default.
                resolved = candidate
            } else {
                resolved = nil
            }
        } else if preferredModelID == nil {
            resolved = providerResolver()
        } else {
            resolved = nil
        }
        guard let resolved else {
            provider = nil
            providerConfig = nil
            reportError("未配置有效供应商。请在设置中添加 API Key 并启用一个模型。")
            return
        }
        provider = resolved.provider
        providerConfig = resolved.configuration
        publishComposerState()
        if storageError == nil {
            lastUserFacingError = nil
            renderTimeline()
        }
    }

    private func resolveProviderForCurrentSelection() {
        let selection = latestState.session.runtimeSelection
        let preferredConfigurationID = selection.kind == .nativeAPI
            ? (selection.providerConfigurationID ?? selection.codingPlanConfigurationID)
            : nil
        resolveProvider(
            preferredConfigurationID: preferredConfigurationID,
            preferredModelID: selection.kind == .nativeAPI ? selection.modelID : nil
        )
    }

    public func setProvider(
        _ provider: AIAssistantStreamingProviding,
        config: ProviderRuntimeConfiguration
    ) {
        guard accessMode == .interactive else { return }
        self.provider = provider
        self.providerConfig = config
        publishComposerState()
        if storageError == nil {
            lastUserFacingError = nil
            renderTimeline()
        }
    }

    // MARK: - Restore

    /// 从认证事件流恢复。读取与解密在后台执行；任何损坏都会阻断会话，绝不跳过记录。
    @discardableResult
    public func restoreFromRepository(_ repository: ConversationRepositoryV2) async -> Bool {
        guard restoreTaskRunning == false else { return false }
        // A second restore must never replace a live Runtime or an in-flight
        // turn with an older replay projection.
        guard activeTurn == nil,
              runtime == nil,
              structuredLocalAgentRuntime == nil
        else { return false }
        restoreTaskRunning = true
        restoreInProgress = true
        defer {
            restoreTaskRunning = false
            restoreInProgress = false
            let pendingDraft = pendingDraftDuringRestore
            pendingDraftDuringRestore = nil
            publishComposerState()
            onRuntimeSelectionUpdate?(latestState.session.runtimeSelection)
            onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
            onTargetUpdate?(currentTargetIdentity)
            publishToolDecision()
            renderTimeline()
            if let pendingDraft {
                updateDraft(pendingDraft)
            }
        }
        do {
            try Task.checkCancellation()
            let envelopes = try await Task.detached(priority: .userInitiated) {
                try repository.loadEvents()
            }.value
            try Task.checkCancellation()
            guard envelopes.isEmpty == false else {
                renderTimeline()
                return false
            }

            let replayed = try replay(envelopes: envelopes)

            // Establish/reuse the process-wide scheduler generation before
            // deciding whether an active Attempt may be recovered. Rows left
            // by a previous process are classified atomically here; an
            // orphaned lease remains capacity-occupying until explicit,
            // evidence-backed reconciliation.
            var admissionState: SchedulerState?
            if accessMode == .interactive {
                admissionState = try await admissionCoordinator.prepareForRestore()
            }

            // The registry can share one Actor across windows. Never roll a
            // newer in-memory projection back to a stale repository read.
            if let actorState = actor.latestPublishedState {
                if actorState.lastAppliedSequence > replayed.state.lastAppliedSequence {
                    latestState = actorState
                    publishComposerState()
                    publishToolDecision()
                    renderTimeline()
                    reportError("会话已由另一个窗口更新，请重新打开会话后继续。")
                    return false
                }
                if actorState.lastAppliedSequence == replayed.state.lastAppliedSequence,
                   actorState != replayed.state {
                    throw ReplayError.invalidTransition
                }
            }

            latestState = replayed.state
            alignProviderWithRestoredRuntimeSelection(replayed.state.session.runtimeSelection)
            if pendingDraftDuringRestore == nil {
                localDraftText = replayed.state.session.draft ?? ""
            }
            archivedTurns = replayed.archivedTurns
            sentHistory = replayed.sentHistory
            turnOrdinal = replayed.turnCount
            proposalPayloads = replayed.proposalPayloads
            traceEventsByProposalID = replayed.traceEventsByProposalID
            queuePreferencePersisted = replayed.queuePreferencePersisted
            terminalTraceRequestIDs.removeAll()
            queuedProviderBindings.removeAll()
            checkpointCommitTask = nil
            flushWorkItem?.cancel()
            flushWorkItem = nil
            activeTurn = nil
            runtime = nil
            structuredLocalAgentRuntime = nil
            activeStructuredLocalAgentConfiguration = nil
            structuredToolCallsByProposalID.removeAll()
            selectedWorkMode = Self.turnWorkMode(for: replayed.state.session.runtimeSelection.workMode)
            if let restoredMode = replayed.state.activeAttempt?.terminalModeSnapshot {
                selectedExecutionChoice = Self.turnExecutionChoice(for: restoredMode)
            }
            let restoredRuntimeID = replayed.state.session.targetBinding.connectionID
            selectedTargetRuntimeID = restoredRuntimeID == "local" || restoredRuntimeID.isEmpty
                ? nil : restoredRuntimeID
            selectedTargetIdentityFallback = selectedTargetRuntimeID == nil
                ? nil : replayed.state.session.targetBinding.remoteIdentity
            if accessMode == .readOnlyHistory {
                publishComposerState()
                publishToolDecision()
                onTargetUpdate?(currentTargetIdentity)
                renderTimeline()
                return true
            }
            if let attempt = replayed.state.activeAttempt,
               attempt.phase.isTerminal == false,
               claimRuntimeOwnership(attemptID: attempt.id) == false {
                // Another live window owns this process-local Runtime. This
                // bridge remains an interactive observer and may still queue,
                // stop, or approve through the shared Actor, but it must not
                // reconcile outbox records or mark the Attempt as relaunched.
                publishComposerState()
                onRuntimeSelectionUpdate?(replayed.state.session.runtimeSelection)
                onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
                onTargetUpdate?(currentTargetIdentity)
                onDraftRestored?(localDraftText)
                publishToolDecision()
                renderTimeline()
                return true
            }
            switch actor.restoreState(replayed.state) {
            case .applied, .alreadyCurrent:
                break
            case .rejectedNewerState:
                if let attemptID = ownedRuntimeAttemptID {
                    releaseRuntimeOwnership(attemptID: attemptID)
                }
                if let current = actor.latestPublishedState {
                    latestState = current
                }
                reportError("会话已由另一个窗口更新，请重新打开会话后继续。")
                return false
            case .rejectedDivergentState:
                throw ReplayError.invalidTransition
            }
            publishComposerState()
            onRuntimeSelectionUpdate?(replayed.state.session.runtimeSelection)
            onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
            onTargetUpdate?(currentTargetIdentity)
            onDraftRestored?(localDraftText)
            var outboxRecovery = try await reconcileOutboxAfterReplay(
                envelopes: envelopes,
                state: replayed.state
            )
            if let attempt = replayed.state.activeAttempt,
               admissionState?.activeLeases.contains(where: {
                   $0.sessionID == sessionID
                       && $0.attemptID == attempt.id
                       && $0.state == .orphanedRuntime
               }) == true {
                // The old process may have crossed an external runtime
                // boundary. Do not infer that it stopped merely because this
                // App instance restarted.
                outboxRecovery.requiresReconciliation = true
            }
            try Task.checkCancellation()

            if let turn = replayed.state.activeTurn,
               let attempt = replayed.state.activeAttempt,
               attempt.phase.isTerminal == false {
                currentGeneration &+= 1
                resetEffectiveExecutionTimer()
                let restoredProviderBinding = providerBinding(
                    matching: attempt,
                    selection: replayed.state.session.runtimeSelection
                )
                activeTurn = ActiveTurn(
                    turnID: turn.id,
                    attemptID: attempt.id,
                    userRequest: turn.userRequest,
                    generation: currentGeneration,
                    workMode: Self.turnWorkMode(for: attempt.workModeSnapshot),
                    executionChoice: Self.turnExecutionChoice(for: attempt.terminalModeSnapshot),
                    targetRuntimeID: attempt.targetBindingSnapshot?.connectionID,
                    targetRuntimeGeneration: attempt.targetRuntimeGeneration,
                    targetBinding: attempt.targetBindingSnapshot ?? replayed.state.session.targetBinding,
                    providerBinding: restoredProviderBinding,
                    runtimeSettingsSnapshot: Self.decodeRuntimeSettingsSnapshot(
                        attempt.policySnapshot
                    ),
                    toolAuthorizationPolicySnapshot: attempt.toolAuthorizationPolicySnapshot,
                    toolCapabilitySnapshot: Self.decodeToolCapabilitySnapshot(
                        attempt.toolCapabilitySnapshot
                    ),
                    accumulatedAnswer: attempt.partialAnswer ?? "",
                    pendingCheckpoint: "",
                    settling: false
                )
                executionModeSnapshotHandler?(Self.turnExecutionChoice(for: attempt.terminalModeSnapshot))
                if outboxRecovery.requiresReconciliation {
                    await interruptRestoredAttempt(
                        turn: turn,
                        attempt: attempt,
                        statusMessage: "上次工具或运行时的外部结果未知，已停止自动重试"
                    )
                    sessionBlocked = true
                    reportError("检测到未结算的外部操作。系统没有自动重跑命令，请先完成对账。")
                    return false
                }
                // An approval is bound to the concrete App process and terminal
                // lease that displayed it. A numeric generation can repeat after
                // relaunch, so an old pending decision must never become executable
                // in the new process. Persist the interruption; the authenticated
                // proposal remains available as a copyable, read-only card.
                if attempt.phase == .awaitingApproval {
                    await interruptRestoredAttempt(
                        turn: turn,
                        attempt: attempt,
                        statusMessage: "待审批建议因 App 重新启动而失效，未执行任何命令"
                    )
                    publishComposerState()
                    publishToolDecision()
                    renderTimeline()
                    return sessionBlocked == false
                }
                await interruptRestoredAttempt(
                    turn: turn,
                    attempt: attempt,
                    statusMessage: "上次运行因 App 重新启动而中断"
                )
            }
            if outboxRecovery.requiresReconciliation {
                sessionBlocked = true
                reportError("检测到未结算的外部操作。系统没有自动重跑命令，请先完成对账。")
                return false
            }
            renderTimeline()
            return sessionBlocked == false
        } catch is CancellationError {
            if activeTurn == nil, let attemptID = ownedRuntimeAttemptID {
                releaseRuntimeOwnership(attemptID: attemptID)
            }
            return false
        } catch {
            if activeTurn == nil, let attemptID = ownedRuntimeAttemptID {
                releaseRuntimeOwnership(attemptID: attemptID)
            }
            storageError = ConversationStorageError(
                summary: "V2 会话记录无法验证",
                recoveryHint: "会话已进入只读保护，原始记录不会被覆盖。"
            )
            return false
        }
    }

    private func alignProviderWithRestoredRuntimeSelection(
        _ selection: AgentRuntimeSelection
    ) {
        guard accessMode == .interactive else { return }
        guard selection.kind == .nativeAPI else {
            provider = nil
            providerConfig = nil
            return
        }
        let selectedConfigurationID = selection.providerConfigurationID
            ?? selection.codingPlanConfigurationID
        guard let selectedConfigurationID else {
            if provider == nil || providerConfig == nil {
                resolveProvider()
            }
            return
        }
        if let providerConfig,
           (providerConfig.effectiveConfigurationID == selectedConfigurationID
            || providerConfig.legacyConfigurationIDs.contains(selectedConfigurationID)),
           selection.modelID == nil || providerConfig.model == selection.modelID {
            return
        }
        provider = nil
        providerConfig = nil
        resolveProvider(
            preferredConfigurationID: selectedConfigurationID,
            preferredModelID: selection.modelID
        )
    }

    private func interruptRestoredAttempt(
        turn: ConversationTurn,
        attempt: TurnAttempt,
        statusMessage: String
    ) async {
        var specs = [DraftSpec(.attemptInterruptedByRelaunch)]
        if latestState.session.queuedInputs.isEmpty == false {
            let pause = QueueAutoAdvanceChangedPayload(paused: true)
            specs.append(DraftSpec(
                .queueAutoAdvanceChanged,
                payload: EventPayloadCodec.encode(pause) ?? Data(),
                scope: .session,
                source: "recovery"
            ))
        }
        switch await submitBatch(specs, turnID: turn.id, attemptID: attempt.id) {
        case .committed(let state):
            latestState = state
            let archivedAttempt = state.activeAttempt ?? attempt
            archivedTurns.append(ArchivedTurn(
                turnID: turn.id,
                attemptID: attempt.id,
                userRequest: turn.userRequest,
                finalAnswer: attempt.partialAnswer ?? "",
                status: .recovery(statusMessage),
                toolEntries: toolTimelineEntries(for: archivedAttempt)
            ))
            releaseRuntimeOwnership(attemptID: attempt.id)
            activeTurn = nil
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "恢复中断状态")
        }
    }

    private func reconcileOutboxAfterReplay(
        envelopes: [ConversationEventEnvelope],
        state: ConversationSessionState
    ) async throws -> OutboxRecoveryDisposition {
        var terminalCommandsByAttemptID: [String: EffectCommand] = [:]
        for envelope in envelopes {
            guard let attemptID = envelope.attemptID else { continue }
            let expected: EffectCommand?
            switch envelope.kind {
            case .attemptCompleted:
                let termination = EventPayloadCodec.decode(AttemptTerminationPayload.self, from: envelope.payload)
                guard termination?.outcome == nil || termination?.outcome == .completed else {
                    throw ReplayError.invalidTransition
                }
                expected = .finalizeAttempt(
                    attemptID: attemptID,
                    outcome: .completed,
                    reasonCode: termination?.reasonCode ?? .completed
                )
            case .attemptFailed:
                let termination = EventPayloadCodec.decode(AttemptTerminationPayload.self, from: envelope.payload)
                guard termination?.outcome == nil || termination?.outcome == .failed else {
                    throw ReplayError.invalidTransition
                }
                expected = .finalizeAttempt(
                    attemptID: attemptID,
                    outcome: .failed,
                    reasonCode: termination?.reasonCode ?? .runtimeStateUnknown
                )
            case .attemptCancelled:
                expected = .finalizeAttempt(
                    attemptID: attemptID,
                    outcome: .cancelled,
                    reasonCode: .cancelled
                )
            case .attemptTakenOver:
                expected = .finalizeAttempt(
                    attemptID: attemptID,
                    outcome: .takenOver,
                    reasonCode: .takenOver
                )
            case .localAgentInputDelivered:
                guard let delivered = EventPayloadCodec.decode(
                    LocalAgentInputDeliveredPayload.self,
                    from: envelope.payload
                ), delivered.attemptID == attemptID else {
                    throw ReplayError.invalidTransition
                }
                expected = .finalizeAttempt(
                    attemptID: attemptID,
                    outcome: .passthroughInputDelivered,
                    reasonCode: .passthroughInputDelivered
                )
            default:
                expected = nil
            }
            guard let expected else { continue }
            if let previous = terminalCommandsByAttemptID[attemptID], previous != expected {
                throw ReplayError.invalidTransition
            }
            terminalCommandsByAttemptID[attemptID] = expected
        }
        var terminalToolStates: [String: (attemptID: String, state: AgentTraceState)] = [:]
        for envelope in envelopes where envelope.kind == .toolCompleted {
            guard let attemptID = envelope.attemptID,
                  let payload = EventPayloadCodec.decode(
                    ToolExecutionEventPayload.self,
                    from: envelope.payload
                  ),
                  let terminalState = AgentTraceState(rawValue: payload.state),
                  Self.isTerminalTraceState(terminalState)
            else {
                throw ReplayError.invalidTransition
            }
            if let previous = terminalToolStates[payload.proposalID],
               previous.attemptID != attemptID || previous.state != terminalState {
                throw ReplayError.invalidTransition
            }
            terminalToolStates[payload.proposalID] = (attemptID, terminalState)
        }

        var toolResolutions: [String: RecoveredToolResolutionEvidence] = [:]
        for envelope in envelopes where envelope.kind == .toolProposalResolved {
            guard let attemptID = envelope.attemptID,
                  let payload = EventPayloadCodec.decode(
                ToolProposalResolutionPayload.self,
                from: envelope.payload
            ),
                  let terminal = terminalToolStates[payload.proposalID],
                  terminal.attemptID == attemptID
            else {
                throw ReplayError.invalidTransition
            }
            let evidence = RecoveredToolResolutionEvidence(
                attemptID: attemptID,
                resolution: payload,
                terminalState: terminal.state
            )
            if let previous = toolResolutions[payload.proposalID],
               previous.attemptID != evidence.attemptID
                || previous.resolution != evidence.resolution
                || previous.terminalState != evidence.terminalState {
                // Two different durable results for one immutable proposal
                // cannot be reconciled safely after relaunch.
                throw ReplayError.invalidTransition
            }
            toolResolutions[payload.proposalID] = evidence
        }

        var disposition = OutboxRecoveryDisposition()
        for record in try await actor.loadUnsettledOutbox() {
            guard let command = record.command else {
                disposition.requiresReconciliation = true
                continue
            }
            switch command {
            case .requestAdmission:
                try await settleRecoveredInternalEffect(record)

            case let .resolveDecision(decisionID, outcome, _):
                guard state.decisions[decisionID]?.state == outcome else {
                    try await isolateRecoveredEffect(record, reason: "decision projection does not prove settlement")
                    disposition.requiresReconciliation = true
                    continue
                }
                try await settleRecoveredInternalEffect(record)

            case let .finalizeAttempt(attemptID, outcome, reasonCode):
                let command = EffectCommand.finalizeAttempt(
                    attemptID: attemptID,
                    outcome: outcome,
                    reasonCode: reasonCode
                )
                guard terminalCommandsByAttemptID[attemptID] == command else {
                    try await isolateRecoveredEffect(
                        record,
                        reason: "attempt terminal evidence does not match finalize command"
                    )
                    disposition.requiresReconciliation = true
                    continue
                }
                try await settleRecoveredInternalEffect(record)

            case let .executeTool(attemptID, proposalID):
                if let evidence = toolResolutions[proposalID] {
                    guard record.state == .dispatching,
                          evidence.attemptID == attemptID,
                          let outcome = Self.recoveredToolSettlementOutcome(evidence)
                    else {
                        try await isolateRecoveredEffect(
                            record,
                            reason: "tool result does not prove a matching claimed dispatch"
                        )
                        disposition.requiresReconciliation = true
                        continue
                    }
                    try await settleRecoveredDispatch(
                        record,
                        outcome: outcome
                    )
                } else if record.state == .pending,
                          state.activeAttempt?.id == attemptID,
                          state.activeAttempt?.activeToolProposalID == proposalID,
                          state.activeAttempt?.phase == .executingTool {
                    // A pending tool has no durable terminal evidence. Even if
                    // it was never claimed locally, relaunch cannot prove that
                    // an external side effect did not cross the crash boundary.
                    try await isolateRecoveredEffect(
                        record,
                        reason: "tool dispatch has no durable terminal evidence"
                    )
                    disposition.requiresReconciliation = true
                } else {
                    try await isolateRecoveredEffect(
                        record,
                        reason: "tool dispatch has no durable terminal evidence"
                    )
                    disposition.requiresReconciliation = true
                }

            case let .startRuntime(attemptID), let .requestAnswerOnlyLaunch(attemptID):
                if record.state == .pending,
                   state.activeAttempt?.id == attemptID,
                   state.activeAttempt?.phase == .streaming,
                   state.session.runtimeSelection.kind == .nativeAPI {
                    // §15.2: relaunch never retries a Provider request. A
                    // pending outbox row is still an external boundary whose
                    // non-execution cannot be proven from the local process.
                    try await isolateRecoveredEffect(
                        record,
                        reason: "runtime launch may have crossed the process crash boundary"
                    )
                    disposition.requiresReconciliation = true
                } else {
                    try await isolateRecoveredEffect(
                        record,
                        reason: "runtime dispatch may have crossed the process crash boundary"
                    )
                    disposition.requiresReconciliation = true
                }
            }
        }
        return disposition
    }

    private static func recoveredToolSettlementOutcome(
        _ evidence: RecoveredToolResolutionEvidence
    ) -> ConversationOutboxSettlementOutcome? {
        switch evidence.terminalState {
        case .completed where evidence.resolution.error == nil:
            return .completed
        case .failed where evidence.resolution.error != nil:
            return .failed
        case .cancelled where evidence.resolution.error != nil:
            return .cancelled
        case .takenOver where evidence.resolution.error != nil:
            return .cancelled
        default:
            return nil
        }
    }

    private func settleRecoveredInternalEffect(
        _ record: ConversationOutboxDispatchRecord
    ) async throws {
        switch record.state {
        case .pending:
            guard let command = record.command,
                  let claimed = try await actor.claimOutboxEffect(
                    effectID: record.effectID,
                    dispatchToken: "recovery-\(UUID().uuidString)",
                    dispatchedAt: Self.outboxTimestamp()
                  ),
                  claimed.command == command else {
                throw ConversationOutboxStoreError.invalidCommandPayload(record.effectID)
            }
            try await settleRecoveredDispatch(claimed, outcome: .acknowledged)
        case .dispatching:
            try await settleRecoveredDispatch(record, outcome: .acknowledged)
        case .reconciliationRequired:
            throw ConversationOutboxStoreError.invalidDispatchState(record.state.rawValue)
        case .settled:
            break
        }
    }

    private func settleRecoveredDispatch(
        _ record: ConversationOutboxDispatchRecord,
        outcome: ConversationOutboxSettlementOutcome
    ) async throws {
        guard let token = record.dispatchToken,
              try await actor.settleOutbox(
                itemID: record.itemID,
                dispatchToken: token,
                outcome: outcome,
                settledAt: Self.outboxTimestamp()
              ) else {
            throw ConversationOutboxStoreError.invalidDispatchState(record.state.rawValue)
        }
    }

    private func isolateRecoveredEffect(
        _ record: ConversationOutboxDispatchRecord,
        reason: String
    ) async throws {
        if record.state == .reconciliationRequired { return }
        guard try await actor.requireOutboxReconciliation(
            itemID: record.itemID,
            reason: reason
        ) else {
            throw ConversationOutboxStoreError.invalidDispatchState(record.state.rawValue)
        }
    }

    private func replay(envelopes: [ConversationEventEnvelope]) throws -> ReplayResult {
        var state = replayBaseState
        var archives: [ArchivedTurn] = []
        var history: [String] = []
        var turnCount = 0
        var replayedProposalPayloads: [String: ConversationToolProposalPayload] = [:]
        var replayedTraces: [String: [AgentTraceEvent]] = [:]
        var queuePreferencePersisted = false

        for envelope in envelopes {
            guard envelope.candidateSequence == state.lastAppliedSequence + 1 else {
                throw ReplayError.invalidSequence
            }
            let draft = EventDraft(envelope: envelope, expectedLastSequence: state.lastAppliedSequence)
            let tentative = ConversationReducer.reduce(state: state, draft: draft).0
            guard tentative.isValid else {
                throw ReplayError.invalidTransition
            }
            state = tentative.state

            if envelope.kind == .queueAutoAdvanceChanged {
                queuePreferencePersisted = true
            }

            if envelope.kind == .toolProposed {
                guard let batch = EventPayloadCodec.decode(
                    ConversationToolProposalBatchPayload.self,
                    from: envelope.payload
                ) else {
                    throw ReplayError.invalidTransition
                }
                for payload in batch.proposals {
                    guard payload.proposalID.isEmpty == false,
                          replayedProposalPayloads[payload.proposalID] == nil
                    else {
                        // A proposal ID is immutable for the whole session;
                        // even an identical second payload is a protocol
                        // replay, not a new executable operation.
                        throw ReplayError.invalidTransition
                    }
                    replayedProposalPayloads[payload.proposalID] = payload
                }
            }

            if envelope.kind == .toolStarted || envelope.kind == .toolCompleted {
                guard let payload = EventPayloadCodec.decode(
                    ToolExecutionEventPayload.self,
                    from: envelope.payload
                ),
                let state = AgentTraceState(rawValue: payload.state),
                payload.proposalID.isEmpty == false,
                payload.requestID.isEmpty == false
                else {
                    throw ReplayError.invalidTransition
                }
                let proposalID = payload.proposalID
                let trace = AgentTraceEvent(
                    requestID: payload.requestID,
                    state: state,
                    message: Self.redactedExecutionText(payload.summary),
                    redactedCommand: replayedProposalPayloads[proposalID].map {
                        Self.redactedExecutionText($0.command)
                    },
                    metadata: nil
                )
                replayedTraces[proposalID, default: []].append(trace)
            }

            if envelope.kind == .turnSubmitted {
                let submitted = EventPayloadCodec.decode(
                    TurnSubmittedPayload.self,
                    from: envelope.payload
                )
                let ordinal = submitted?.ordinal ?? state.activeTurn?.ordinal ?? (turnCount + 1)
                turnCount = max(turnCount, ordinal)
                if let turn = state.activeTurn {
                    history.append(turn.userRequest)
                }
            }
            if [.attemptCompleted, .attemptFailed, .attemptCancelled, .attemptTakenOver,
                .localAgentInputDelivered,
                .attemptInterruptedByRelaunch].contains(envelope.kind),
               let turn = state.activeTurn,
               let attempt = state.activeAttempt {
                archives.append(ArchivedTurn(
                    turnID: turn.id,
                    attemptID: attempt.id,
                    userRequest: turn.userRequest,
                    finalAnswer: attempt.partialAnswer ?? "",
                    status: archivedStatus(for: attempt),
                    toolEntries: toolTimelineEntries(
                        for: attempt,
                        proposalPayloads: replayedProposalPayloads,
                        traceEventsByProposalID: replayedTraces,
                        targetIdentity: state.session.targetBinding.remoteIdentity
                    )
                ))
            }
        }
        return ReplayResult(
            state: state,
            archivedTurns: archives,
            sentHistory: history,
            turnCount: turnCount,
            proposalPayloads: replayedProposalPayloads,
            traceEventsByProposalID: replayedTraces,
            queuePreferencePersisted: queuePreferencePersisted
        )
    }

    // MARK: - Send

    public func send(text: String) async -> SendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .rejected(reason: .empty)
        }
        guard accessMode == .interactive else {
            return .rejected(reason: .readOnly)
        }
        guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else {
            return .rejected(reason: .draining)
        }
        guard storageError == nil, sessionBlocked == false else {
            return .rejected(reason: .storageUnavailable)
        }
        guard restoreInProgress == false else {
            return .rejected(reason: .alreadyRunning)
        }
        guard submissionsBlockedByStop == false else {
            return .rejected(reason: .alreadyRunning)
        }
        guard latestState.session.runtimeSelection.kind == .nativeAPI else {
            return .rejected(reason: .runtimeUnavailable)
        }
        guard selectedExecutionChoice != .ask else {
            reportError("请先为本轮选择真实终端或后台虚拟终端。")
            return .rejected(reason: .executionChoiceRequired)
        }
        guard activeTurn == nil, hasDurableActiveTurn == false else {
            guard let runtimeSettingsSnapshot = captureRuntimeSettingsSnapshot() else {
                return .rejected(reason: .settingsUnavailable)
            }
            return await enqueue(
                text: trimmed,
                runtimeSettingsSnapshot: runtimeSettingsSnapshot
            )
        }
        return await beginTurn(userRequest: trimmed)
    }

    /// Terminal passthrough has an honest, separate transaction boundary:
    /// durable Turn + frozen configuration + claimed outbox first, PTY write second,
    /// then a delivery terminal event. PTY output never enters canonical answer state.
    func sendToLocalAgent(
        text: String,
        configuration: LocalAgentPassthroughConfiguration,
        workingDirectoryReference: String? = nil,
        deliver: @escaping @MainActor () -> LocalAgentInputSendResult
    ) async -> SendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .rejected(reason: .empty) }
        guard accessMode == .interactive else { return .rejected(reason: .readOnly) }
        guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else {
            return .rejected(reason: .draining)
        }
        guard storageError == nil, sessionBlocked == false else {
            return .rejected(reason: .storageUnavailable)
        }
        guard restoreInProgress == false,
              activeTurn == nil,
              hasDurableActiveTurn == false
        else { return .rejected(reason: .alreadyRunning) }
        guard configuration.isReadyForTerminalPassthrough else {
            reportError("Local Agent 配置未通过验证，输入未发送。")
            return .rejected(reason: .runtimeUnavailable)
        }

        var selection = latestState.session.runtimeSelection
        guard selection.kind == .localAgent,
              selection.localAgentConfigurationID == configuration.configurationID,
              selection.localAgentExecutionProfileID == configuration.executionProfileID,
              selection.workMode == .agent
        else {
            reportError("Local Agent Runtime 选择与当前配置不一致，输入未发送。")
            return .rejected(reason: .runtimeUnavailable)
        }

        let expectedProfileKind: LocalAgentExecutionProfileKind =
            configuration.isReadyForStructuredRuntime ? .managed : .terminalPassthrough
        if selection.localAgentExecutionProfileKind != expectedProfileKind {
            // Claude managed-jsonl records were written before the structured
            // tool channel was available. Preserve their sealed record, but
            // migrate the next-turn selection to the verified PTY transport
            // before creating a new Attempt. Any other mismatch remains fail
            // closed rather than silently changing the execution contract.
            guard isRetiredClaudeManagedSelection(selection, configuration: configuration) else {
                reportError("Local Agent Runtime 选择与当前配置不一致，输入未发送。")
                return .rejected(reason: .runtimeUnavailable)
            }
            var normalizedSelection = selection
            normalizedSelection.localAgentExecutionProfileKind = .terminalPassthrough
            normalizedSelection.revision = selection.revision + 1
            guard await commitRuntimeSelection(normalizedSelection),
                  latestState.session.runtimeSelection == normalizedSelection
            else {
                reportError("旧版 Claude Runtime 选择迁移失败，输入未发送。")
                return .rejected(reason: .runtimeUnavailable)
            }
            selection = normalizedSelection
        }
        guard selection.localAgentExecutionProfileKind == expectedProfileKind else {
            reportError("Local Agent Runtime 选择与当前配置不一致，输入未发送。")
            return .rejected(reason: .runtimeUnavailable)
        }

        let context = resolveTerminalContext(runtimeID: selectedTargetRuntimeID)
        if configuration.isReadyForStructuredRuntime == false,
           selectedTargetRuntimeID != nil,
           context == nil {
            reportError("所选终端已关闭或不可用。请重新选择执行目标后再发送。")
            return .rejected(reason: .targetUnavailable)
        }
        let targetBinding = makeTargetBinding(context: context)
        let targetRuntimeID = context?.runtimeID ?? selectedTargetRuntimeID
        let targetRuntimeGeneration = context?.connectionGeneration
        let configurationDigest = localAgentConfigurationDigest(configuration)
        let authentication = makeLocalAgentAuthenticationSnapshot(
            configuration,
            configurationDigest: configurationDigest,
            capturedAt: Date()
        )
        guard case .success(.localAgent(let routedID)) = RuntimeRouter.route(
            session: configuredSession(for: selection),
            authentication: authentication
        ), routedID == configuration.configurationID else {
            reportError("Local Agent 登录或验证证据已失效，输入未发送。")
            return .rejected(reason: .runtimeUnavailable)
        }

        guard let processWorkingDirectory = makeAgentProcessWorkingDirectory(
            configuration,
            configurationDigest: configurationDigest,
            workingDirectoryReference: workingDirectoryReference
        ) else {
            reportError("Local Agent 工作目录未通过验证，输入未发送。")
            return .rejected(reason: .runtimeUnavailable)
        }
        guard let runtimeSettingsSnapshot = captureRuntimeSettingsSnapshot() else {
            return .rejected(reason: .settingsUnavailable)
        }
        let draftToken = prepareDraftForSubmission(trimmed)
        turnOrdinal = max(turnOrdinal, latestState.activeTurn?.ordinal ?? 0)
        turnOrdinal += 1
        currentGeneration &+= 1
        resetEffectiveExecutionTimer()
        let turnID = "turn-\(turnOrdinal)"
        let attemptID = "attempt-\(turnOrdinal)"
        let generation = currentGeneration
        activeTurn = ActiveTurn(
            turnID: turnID,
            attemptID: attemptID,
            userRequest: trimmed,
            generation: generation,
            workMode: .agent,
            executionChoice: .realTerminal,
            targetRuntimeID: targetRuntimeID,
            targetRuntimeGeneration: targetRuntimeGeneration,
            targetBinding: targetBinding,
            providerBinding: nil,
            runtimeSettingsSnapshot: runtimeSettingsSnapshot,
            toolAuthorizationPolicySnapshot: nil,
            toolCapabilitySnapshot: nil,
            accumulatedAnswer: "",
            pendingCheckpoint: "",
            settling: false
        )
        proposalPayloads.removeAll()
        structuredToolCallsByProposalID.removeAll()
        traceEventsByProposalID.removeAll()
        activeExecutionRequestID = nil
        activeExecutionProposalID = nil
        terminalTraceRequestIDs.removeAll()
        activeToolDispatch = nil
        activeToolDispatchHandedOff = false
        activeToolStopRequested = false
        activeToolSettlementOutcome = nil
        toolObservations.removeAll()
        lastToolResponseMessage = nil
        toolRound = 0
        completedToolCommandDigests.removeAll()
        pendingLocalAgentDelivery = nil
        lastUserFacingError = nil

        let outcome = await submitOptionalBatch { [self] in
            guard acceptsNewSubmissions,
                  submissionGateAllowsNewTurns(),
                  activeTurn?.turnID == turnID,
                  latestState.session.runtimeSelection == selection
            else { return nil }
            var specs: [DraftSpec] = []
            if queuePreferencePersisted == false {
                specs.append(DraftSpec(
                    .queueAutoAdvanceChanged,
                    payload: EventPayloadCodec.encode(
                        QueueAutoAdvanceChangedPayload(paused: queueAutoAdvancePaused)
                    ) ?? Data(),
                    scope: .session,
                    source: "session-default"
                ))
            }
            let submitted = TurnSubmittedPayload(
                text: trimmed,
                runtimeSelection: selection,
                targetBinding: targetBinding,
                targetRuntimeGeneration: targetRuntimeGeneration,
                terminalMode: (configuration.isReadyForStructuredRuntime
                    ? LocalAgentExecutionProfileKind.managed
                    : .terminalPassthrough).rawValue,
                ordinal: turnOrdinal,
                runtimeAuthenticationSnapshot: authentication,
                configurationRevisionDigest: configurationDigest,
                agentProcessWorkingDirectorySnapshot: processWorkingDirectory,
                runtimeSettingsSnapshot: runtimeSettingsSnapshot
            )
            specs.append(contentsOf: [
                DraftSpec(.draftChanged, payload: Data(), scope: .session, source: "user"),
                DraftSpec(
                    .turnSubmitted,
                    payload: EventPayloadCodec.encode(submitted) ?? Data(trimmed.utf8),
                    scope: .turn,
                    source: "user"
                ),
                DraftSpec(.admissionRequested, source: "scheduler-intent")
            ])
            return SubmissionBatch(specs: specs, turnID: turnID, attemptID: attemptID)
        }
        guard let outcome else {
            activeTurn = nil
            completeDraftSubmission(draftToken, text: trimmed, committed: false)
            return .rejected(reason: .alreadyRunning)
        }
        guard case .committed(let committedState) = outcome else {
            if case .rejected(let reason) = outcome {
                activeTurn = nil
                completeDraftSubmission(draftToken, text: trimmed, committed: false)
                blockAfterSubmissionFailure(reason, context: "启动 Local Agent 会话")
            }
            return .rejected(reason: .storageUnavailable)
        }

        latestState = committedState
        completeDraftSubmission(draftToken, text: trimmed, committed: true)
        guard claimRuntimeOwnership(attemptID: attemptID) else {
            activeTurn = nil
            blockForOutboxFailure("Local Agent Attempt 已由另一个窗口接管，未执行终端透传。")
            return .accepted(turnID: turnID)
        }
        queuePreferencePersisted = true
        sentHistory.append(trimmed)
        publishComposerState()
        renderTimeline()

        let admissionCommand = EffectCommand.requestAdmission(
            sessionID: sessionID,
            turnID: turnID,
            attemptID: attemptID
        )
        guard let admissionDispatch = await claimCommittedEffect(
            admissionCommand,
            context: "请求 Local Agent 全局执行容量"
        ) else {
            releaseRuntimeOwnership(attemptID: attemptID)
            // The durable Turn already owns this input. Reporting it as unsent
            // would leave the Composer text visible and invite a duplicate Turn.
            return .accepted(turnID: turnID)
        }
        let pendingDelivery = PendingLocalAgentDelivery(
            generation: generation,
            configurationID: configuration.configurationID,
            executionProfileID: configuration.executionProfileID,
            configurationDigest: configurationDigest,
            configuration: configuration,
            processWorkingDirectory: processWorkingDirectory,
            draftToken: draftToken,
            text: trimmed,
            deliver: deliver
        )
        pendingLocalAgentDelivery = pendingDelivery
        await enqueueExecutionAdmission(
            turnID: turnID,
            attemptID: attemptID,
            generation: generation,
            dispatch: admissionDispatch
        )
        return pendingDelivery.immediateResult ?? .accepted(turnID: turnID)
    }

    public func queue(text: String) async -> SendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .rejected(reason: .empty) }
        guard accessMode == .interactive else { return .rejected(reason: .readOnly) }
        guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else {
            return .rejected(reason: .draining)
        }
        guard storageError == nil, sessionBlocked == false else {
            return .rejected(reason: .storageUnavailable)
        }
        guard restoreInProgress == false else {
            return .rejected(reason: .alreadyRunning)
        }
        guard submissionsBlockedByStop == false else {
            return .rejected(reason: .alreadyRunning)
        }
        guard latestState.session.runtimeSelection.kind == .nativeAPI else {
            return .rejected(reason: .runtimeUnavailable)
        }
        guard selectedExecutionChoice != .ask else {
            reportError("请先为待发送消息选择真实终端或后台虚拟终端。")
            return .rejected(reason: .executionChoiceRequired)
        }
        guard let runtimeSettingsSnapshot = captureRuntimeSettingsSnapshot() else {
            return .rejected(reason: .settingsUnavailable)
        }
        if provider == nil || providerConfig == nil {
            resolveProviderForCurrentSelection()
        }
        guard provider != nil, providerConfig != nil else {
            reportError("未配置有效供应商。请先在设置中完成供应商与模型配置。")
            return .rejected(reason: .providerUnavailable)
        }
        return await enqueue(text: trimmed, runtimeSettingsSnapshot: runtimeSettingsSnapshot)
    }

    private func enqueue(
        text: String,
        runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot,
        retryCount: Int = 0
    ) async -> SendResult {
        guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else {
            return .rejected(reason: .draining)
        }
        guard submissionsBlockedByStop == false else {
            return .rejected(reason: .alreadyRunning)
        }
        guard let provider, let providerConfig else {
            return .rejected(reason: .providerUnavailable)
        }
        guard selectedExecutionChoice != .ask else {
            reportError("请先为待发送消息选择真实终端或后台虚拟终端。")
            return .rejected(reason: .executionChoiceRequired)
        }
        let frozenBinding = ProviderRuntimeBinding(
            provider: provider,
            configuration: providerConfig
        )
        let draftToken = prepareDraftForSubmission(text)
        var queuedInput: QueuedInput?
        let outcome = await submitOptionalBatch { [self] in
            guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else { return nil }
            // Position is projection-dependent. Build it only after this
            // operation reaches the submission FIFO so concurrent enqueue
            // calls cannot capture the same stale queue length and reverse.
            let queued = makeQueuedInput(
                text: text,
                runtimeSettingsSnapshot: runtimeSettingsSnapshot
            )
            queuedInput = queued
            let payload = QueuedInputAddedPayload(input: queued)
            let active = activeTurn
            return SubmissionBatch(
                specs: [
                    DraftSpec(
                        .queuedInputAdded,
                        payload: EventPayloadCodec.encode(payload) ?? Data(),
                        scope: .session,
                        source: "user"
                    ),
                    DraftSpec(.draftChanged, payload: Data(), scope: .session, source: "user")
                ],
                turnID: active?.turnID,
                attemptID: active?.attemptID
            )
        }

        guard let outcome else {
            completeDraftSubmission(draftToken, text: text, committed: false)
            return .rejected(reason: .draining)
        }
        switch outcome {
        case .committed(let state):
            latestState = state
            completeDraftSubmission(draftToken, text: text, committed: true)
            guard let queued = queuedInput else {
                blockForOutboxFailure("待发送消息已提交，但本地队列身份丢失。会话已暂停，请重新打开后继续。")
                return .queued(position: state.session.queuedInputs.count)
            }
            queuedProviderBindings[queued.id] = frozenBinding
            resetAskEveryTurnSelectionIfNeeded(
                frozenChoice: Self.turnExecutionChoice(for: queued.contextSnapshot.terminalMode),
                settings: runtimeSettingsSnapshot
            )
            publishComposerState()
            renderTimeline()
            return .queued(position: state.session.queuedInputs.count)
        case .rejected(let reason):
            if retryCount < 1, Self.isRetryableConcurrentProjectionRejection(reason) {
                // 另一个窗口可能刚提交了 checkpoint/queue 事件。刷新 durable
                // projection 后重建队列快照，但不能取消当前本地 Runtime。
                refreshProjectionAfterConcurrentWrite()
                return await enqueue(
                    text: text,
                    runtimeSettingsSnapshot: runtimeSettingsSnapshot,
                    retryCount: retryCount + 1
                )
            }
            completeDraftSubmission(draftToken, text: text, committed: false)
            blockAfterSubmissionFailure(reason, context: "保存待发送消息")
            return .rejected(reason: .storageUnavailable)
        }
    }

    private func beginTurn(userRequest: String, consuming queuedInput: QueuedInput? = nil) async -> SendResult {
        guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else {
            return .rejected(reason: .draining)
        }
        guard restoreInProgress == false,
              activeTurn == nil,
              hasDurableActiveTurn == false,
              submissionsBlockedByStop == false
        else { return .rejected(reason: .alreadyRunning) }
        let runtimeSelection: AgentRuntimeSelection
        let workMode: TurnWorkMode
        let executionChoice: TurnExecutionChoice
        let targetBinding: TargetBinding
        let targetRuntimeID: String?
        let targetRuntimeGeneration: UInt64?
        let providerBinding: ProviderRuntimeBinding
        let runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot
        let configurationRevisionDigest: String
        let runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot
        let queuedToolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot?
        if let queuedInput {
            let contextSnapshot = queuedInput.contextSnapshot
            guard let frozenSettings = contextSnapshot.runtimeSettingsSnapshot else {
                await markQueuedInputNeedsRebind(
                    queuedInput,
                    reason: "待发送消息缺少入队时的运行设置快照。队列已暂停，请重新绑定当前上下文。"
                )
                return .rejected(reason: .settingsUnavailable)
            }
            runtimeSettingsSnapshot = frozenSettings
            runtimeSelection = contextSnapshot.runtimeSelectionSnapshot
            workMode = Self.turnWorkMode(for: contextSnapshot.workMode)
            executionChoice = Self.turnExecutionChoice(for: contextSnapshot.terminalMode)
            guard executionChoice != .ask else {
                await markQueuedInputNeedsRebind(
                    queuedInput,
                    reason: "该待发送消息尚未选择执行终端，请拉回输入框后重新选择。"
                )
                return .rejected(reason: .executionChoiceRequired)
            }
            targetBinding = contextSnapshot.targetBindingSnapshot
            targetRuntimeID = contextSnapshot.targetBindingSnapshot.connectionID
            targetRuntimeGeneration = contextSnapshot.targetRuntimeGeneration
            if targetBinding.connectionKind == "terminal",
               targetContextResolver != nil,
               terminalContext(
                    resolveTerminalContext(runtimeID: targetRuntimeID),
                    matches: contextSnapshot
               ) == false {
                await markQueuedInputNeedsRebind(
                    queuedInput,
                    reason: "待发送消息绑定的终端已关闭或重连。队列已暂停，请拉回输入框并重新选择目标。"
                )
                return .rejected(reason: .targetUnavailable)
            }
            guard let frozenBinding = queuedProviderBindings[queuedInput.id]
                ?? currentProviderBinding(matching: contextSnapshot)
            else {
                await markQueuedInputNeedsRebind(
                    queuedInput,
                    reason: "待发送消息绑定的供应商、模型或凭证已变化。队列已暂停，请拉回输入框并确认新配置。"
                )
                return .rejected(reason: .providerUnavailable)
            }
            providerBinding = frozenBinding
            runtimeAuthenticationSnapshot = contextSnapshot.runtimeAuthenticationSnapshot
            configurationRevisionDigest = contextSnapshot.configurationRevisionDigest
            queuedToolAuthorizationPolicySnapshot = contextSnapshot.toolAuthorizationPolicySnapshot
        } else {
            guard selectedExecutionChoice != .ask else {
                reportError("请先为本轮选择真实终端或后台虚拟终端。")
                return .rejected(reason: .executionChoiceRequired)
            }
            guard let currentSettings = captureRuntimeSettingsSnapshot() else {
                return .rejected(reason: .settingsUnavailable)
            }
            runtimeSettingsSnapshot = currentSettings
            if provider == nil || providerConfig == nil {
                resolveProviderForCurrentSelection()
            }
            runtimeSelection = runtimeSelectionForNextTurn(settings: currentSettings)
            workMode = selectedWorkMode
            executionChoice = selectedExecutionChoice
            var context = resolveTerminalContext(runtimeID: selectedTargetRuntimeID)
            if let selectedTargetRuntimeID,
               context?.isConnected != true,
               let currentContext = resolveTerminalContext(runtimeID: nil),
               currentContext.isConnected,
               shouldRebindTarget(
                   selectedRuntimeID: selectedTargetRuntimeID,
                   currentContext: currentContext
               ) {
                // A remote pane replaces its temporary pending_* identity with
                // the live shell runtime ID after SSH establishment. Refresh
                // the binding at the start of a new turn so a visible,
                // connected terminal is not rejected solely because the
                // previous turn captured the pre-connect identity.
                self.selectedTargetRuntimeID = currentContext.runtimeID
                self.selectedTargetIdentityFallback = currentContext.title
                self.onTargetUpdate?(self.currentTargetIdentity)
                context = currentContext
            }
            if selectedTargetRuntimeID != nil,
               context?.isConnected != true {
                reportError("所选终端已关闭或不可用。请重新选择执行目标后再发送。")
                return .rejected(reason: .targetUnavailable)
            }
            targetBinding = makeTargetBinding(context: context)
            targetRuntimeID = context?.runtimeID ?? selectedTargetRuntimeID
            targetRuntimeGeneration = context?.connectionGeneration
            guard let provider, let providerConfig else {
                return .rejected(reason: .providerUnavailable)
            }
            providerBinding = ProviderRuntimeBinding(
                provider: provider,
                configuration: providerConfig
            )
            let snapshots = makeProviderSnapshots(
                selection: runtimeSelection,
                configuration: providerConfig,
                capturedAt: Date()
            )
            runtimeAuthenticationSnapshot = snapshots.authentication
            configurationRevisionDigest = snapshots.configurationDigest
            queuedToolAuthorizationPolicySnapshot = nil
        }

        guard validateRuntimeRoute(
            selection: runtimeSelection,
            authentication: runtimeAuthenticationSnapshot,
            configuration: providerBinding.configuration,
            configurationRevisionDigest: configurationRevisionDigest
        ) else {
            // Route/authentication failures are terminal for this explicit
            // selection. Do not create a durable turn or call the provider.
            return .rejected(reason: .providerUnavailable)
        }

        let toolCapabilitySnapshot: ToolCapabilitySnapshot?
        let toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot?
        if workMode == .agent {
            guard let toolCatalog else {
                reportError("Stacio Tool Catalog 无法验证。为避免未声明工具执行，本次输入未发送。")
                return .rejected(reason: .runtimeUnavailable)
            }
            let declaredToolIDs = Set(toolCatalog.tools.map(\.toolID))
            toolCapabilitySnapshot = ToolCapabilitySnapshot(
                catalogRevision: toolCatalog.revision,
                enabledToolIDs: Array(
                    Set(runtimeSettingsSnapshot.enabledToolIDs).intersection(declaredToolIDs)
                ).sorted(),
                targetBindingDigest: targetBinding.digest
            )
            if let queuedInput {
                guard let snapshot = queuedToolAuthorizationPolicySnapshot,
                      snapshot.isBoundTo(
                        runtimeID: targetBinding.connectionID,
                        runtimeGeneration: targetRuntimeGeneration,
                        targetBindingDigest: targetBinding.digest
                      ) else {
                    await markQueuedInputNeedsRebind(
                        queuedInput,
                        reason: "待发送消息缺少可验证的审批策略快照。队列已暂停，请重新绑定当前目标。"
                    )
                    return .rejected(reason: .settingsUnavailable)
                }
                toolAuthorizationPolicySnapshot = snapshot
            } else {
                guard let snapshot = captureToolAuthorizationPolicySnapshot(
                    targetBinding: targetBinding,
                    targetRuntimeGeneration: targetRuntimeGeneration
                ) else {
                    reportError("无法验证当前终端的审批策略，本次输入未发送。")
                    return .rejected(reason: .settingsUnavailable)
                }
                toolAuthorizationPolicySnapshot = snapshot
            }
        } else {
            toolCapabilitySnapshot = nil
            toolAuthorizationPolicySnapshot = nil
        }

        let draftToken = queuedInput == nil ? prepareDraftForSubmission(userRequest) : nil

        turnOrdinal = max(turnOrdinal, latestState.activeTurn?.ordinal ?? 0)
        turnOrdinal += 1
        currentGeneration &+= 1
        resetEffectiveExecutionTimer()
        let turnID = "turn-\(turnOrdinal)"
        let attemptID = "attempt-\(turnOrdinal)"
        let generation = currentGeneration
        activeTurn = ActiveTurn(
            turnID: turnID,
            attemptID: attemptID,
            userRequest: userRequest,
            generation: generation,
            workMode: workMode,
            executionChoice: executionChoice,
            targetRuntimeID: targetRuntimeID,
            targetRuntimeGeneration: targetRuntimeGeneration,
            targetBinding: targetBinding,
            providerBinding: providerBinding,
            runtimeSettingsSnapshot: runtimeSettingsSnapshot,
            toolAuthorizationPolicySnapshot: toolAuthorizationPolicySnapshot,
            toolCapabilitySnapshot: toolCapabilitySnapshot,
            accumulatedAnswer: "",
            pendingCheckpoint: "",
            settling: false
        )
        proposalPayloads.removeAll()
        traceEventsByProposalID.removeAll()
        activeExecutionRequestID = nil
        activeExecutionProposalID = nil
        terminalTraceRequestIDs.removeAll()
        activeToolDispatch = nil
        activeToolDispatchHandedOff = false
        activeToolStopRequested = false
        activeToolSettlementOutcome = nil
        toolObservations.removeAll()
        lastToolResponseMessage = nil
        toolRound = 0
        completedToolCommandDigests.removeAll()
        pendingLocalAgentDelivery = nil
        lastUserFacingError = nil

        // 队列消费、Turn/Attempt 创建与 Runtime 启动事实必须在一个事务中提交。
        let outcome = await submitOptionalBatch { [self] in
            guard acceptsNewSubmissions, submissionGateAllowsNewTurns() else { return nil }
            var specs: [DraftSpec] = []
            if queuePreferencePersisted == false {
                let preference = QueueAutoAdvanceChangedPayload(paused: queueAutoAdvancePaused)
                specs.append(DraftSpec(
                    .queueAutoAdvanceChanged,
                    payload: EventPayloadCodec.encode(preference) ?? Data(),
                    scope: .session,
                    source: "session-default"
                ))
            }
            if let queuedInput {
                guard let current = latestState.session.queuedInputs.first(where: { $0.id == queuedInput.id }) else {
                    return nil
                }
                let removal = QueuedInputRemovedPayload(
                    inputID: current.id,
                    expectedRevision: current.revision
                )
                specs.append(DraftSpec(
                    .queuedInputRemoved,
                    payload: EventPayloadCodec.encode(removal) ?? Data(),
                    scope: .session,
                    source: "queue"
                ))
            }
            let submitted = TurnSubmittedPayload(
                text: userRequest,
                runtimeSelection: runtimeSelection,
                targetBinding: targetBinding,
                targetRuntimeGeneration: targetRuntimeGeneration,
                terminalMode: executionChoice.rawValue,
                ordinal: turnOrdinal,
                runtimeAuthenticationSnapshot: runtimeAuthenticationSnapshot,
                configurationRevisionDigest: configurationRevisionDigest,
                runtimeSettingsSnapshot: runtimeSettingsSnapshot,
                toolAuthorizationPolicySnapshot: toolAuthorizationPolicySnapshot,
                toolCapabilitySnapshot: toolCapabilitySnapshot
            )
            specs.append(contentsOf: [
                DraftSpec(.draftChanged, payload: Data(), scope: .session, source: "user"),
                DraftSpec(
                    .turnSubmitted,
                    payload: EventPayloadCodec.encode(submitted) ?? Data(userRequest.utf8),
                    scope: .turn,
                    source: "user"
                ),
                DraftSpec(.admissionRequested, source: "scheduler-intent")
            ])
            return SubmissionBatch(specs: specs, turnID: turnID, attemptID: attemptID)
        }

        guard let outcome else {
            activeTurn = nil
            completeDraftSubmission(draftToken, text: userRequest, committed: false)
            return .rejected(reason: acceptsNewSubmissions ? .alreadyRunning : .draining)
        }

        switch outcome {
        case .committed(let state):
            latestState = state
            completeDraftSubmission(draftToken, text: userRequest, committed: true)
            guard claimRuntimeOwnership(attemptID: attemptID) else {
                activeTurn = nil
                blockForOutboxFailure("模型 Attempt 已由另一个窗口接管，未启动重复请求。")
                return .accepted(turnID: turnID)
            }
            queuePreferencePersisted = true
            if let queuedInput {
                queuedProviderBindings.removeValue(forKey: queuedInput.id)
            }
            resetAskEveryTurnSelectionIfNeeded(
                frozenChoice: executionChoice,
                settings: runtimeSettingsSnapshot
            )
            executionModeSnapshotHandler?(executionChoice)
            let admissionCommand = EffectCommand.requestAdmission(
                sessionID: sessionID,
                turnID: turnID,
                attemptID: attemptID
            )
            guard let admissionDispatch = await claimCommittedEffect(
                admissionCommand,
                context: "请求全局执行容量"
            ) else {
                releaseRuntimeOwnership(attemptID: attemptID)
                activeTurn = nil
                // The Turn and its original input are durable even when effect
                // dispatch cannot proceed. Keep the Composer from duplicating it.
                return .accepted(turnID: turnID)
            }
            sentHistory.append(userRequest)
            publishComposerState()
            renderTimeline()
            await enqueueExecutionAdmission(
                turnID: turnID,
                attemptID: attemptID,
                generation: generation,
                dispatch: admissionDispatch
            )
            return .accepted(turnID: turnID)
        case .rejected(let reason):
            activeTurn = nil
            let refreshedConcurrentState = refreshFromActorAfterConcurrentWrite()
            if Self.isConcurrentTurnSubmissionRejection(reason),
               (refreshedConcurrentState || hasDurableActiveTurn) {
                return await enqueue(
                    text: userRequest,
                    runtimeSettingsSnapshot: runtimeSettingsSnapshot
                )
            }
            completeDraftSubmission(draftToken, text: userRequest, committed: false)
            blockAfterSubmissionFailure(reason, context: "启动会话")
            return .rejected(reason: .storageUnavailable)
        }
    }

    private func enqueueExecutionAdmission(
        turnID: String,
        attemptID: String,
        generation: UInt64,
        dispatch: ConversationOutboxDispatchRecord
    ) async {
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.turnID == turnID,
              turn.attemptID == attemptID,
              turn.settling == false
        else {
            _ = await settleClaimedEffect(
                dispatch,
                outcome: .cancelled,
                context: "取消已失效的执行排队"
            )
            return
        }
        let config = SchedulerConfig(
            capacity: turn.runtimeSettingsSnapshot?.maxParallelAttempts ?? 2,
            waitTimeout: TimeInterval(
                (turn.runtimeSettingsSnapshot?.capacityWaitMinutes ?? 30) * 60
            )
        )
        let request: GlobalExecutionAdmissionRequest
        do {
            request = try await admissionCoordinator.enqueue(
                sessionID: sessionID,
                turnID: turnID,
                attemptID: attemptID,
                config: config
            )
        } catch {
            _ = await settleClaimedEffect(
                dispatch,
                outcome: .failed,
                context: "记录执行排队失败"
            )
            beginFailure(
                reasonCode: .runtimeStartFailed,
                summary: "全局执行调度器不可用，模型请求未启动。",
                generation: generation
            )
            return
        }

        guard generation == currentGeneration,
              var current = activeTurn,
              current.turnID == turnID,
              current.attemptID == attemptID,
              current.settling == false
        else {
            _ = try? await admissionCoordinator.cancel(requestID: request.requestID)
            _ = await settleClaimedEffect(
                dispatch,
                outcome: .cancelled,
                context: "取消已停止的执行排队"
            )
            return
        }
        current.admissionRequest = request
        activeTurn = current

        let payload = AdmissionRequestedPayload(
            requestID: request.requestID,
            attemptID: attemptID,
            schedulerGeneration: request.schedulerGeneration,
            queueOrdinal: request.queueOrdinal,
            enqueuedAt: request.enqueuedAt,
            waitTimeoutSeconds: config.waitTimeout
        )
        switch await submitBatch([
            DraftSpec(
                .admissionRequested,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                source: "scheduler"
            )
        ], turnID: turnID, attemptID: attemptID) {
        case .committed(let state):
            latestState = state
        case .rejected(let reason):
            _ = try? await admissionCoordinator.cancel(requestID: request.requestID)
            _ = await settleClaimedEffect(
                dispatch,
                outcome: .failed,
                context: "保存执行排队身份"
            )
            blockAfterSubmissionFailure(reason, context: "保存执行排队身份")
            return
        }

        guard await settleClaimedEffect(
            dispatch,
            outcome: .acknowledged,
            context: "记录全局执行排队"
        ) else {
            _ = try? await admissionCoordinator.cancel(requestID: request.requestID)
            return
        }
        publishComposerState()
        renderTimeline()

        if let resolution = await admissionCoordinator.resolutionIfAvailable(
            requestID: request.requestID
        ) {
            await handleAdmissionResolution(
                resolution,
                request: request,
                generation: generation
            )
            return
        }

        admissionWaitTask?.cancel()
        let coordinator = admissionCoordinator
        admissionWaitTask = Task { @MainActor [weak self] in
            let resolution = await coordinator.waitForResolution(requestID: request.requestID)
            guard Task.isCancelled == false else { return }
            await self?.handleAdmissionResolution(
                resolution,
                request: request,
                generation: generation
            )
        }
    }

    private func handleAdmissionResolution(
        _ resolution: AgentExecutionAdmissionResolution,
        request: GlobalExecutionAdmissionRequest,
        generation: UInt64
    ) async {
        admissionWaitTask = nil
        switch resolution {
        case .granted(let lease):
            guard generation == currentGeneration,
                  let turn = activeTurn,
                  turn.generation == generation,
                  turn.admissionRequest?.requestID == request.requestID,
                  turn.settling == false
            else {
                _ = try? await admissionCoordinator.release(lease)
                return
            }
            await startRuntimeAfterAdmission(lease: lease, generation: generation)

        case .expired:
            await settleAdmissionWaitExpired(request: request, generation: generation)

        case .cancelled:
            await settleAdmissionCancelled(request: request, generation: generation)

        case .failed:
            beginFailure(
                reasonCode: .runtimeStartFailed,
                summary: "全局执行调度器无法确认容量状态，模型请求未启动。",
                generation: generation
            )
        }
    }

    private func startRuntimeAfterAdmission(
        lease: GlobalExecutionAdmissionLease,
        generation: UInt64
    ) async {
        guard generation == currentGeneration,
              var turn = activeTurn,
              turn.generation == generation,
              turn.attemptID == lease.attemptID,
              turn.admissionRequest?.requestID == lease.requestID,
              turn.settling == false
        else {
            _ = try? await admissionCoordinator.release(lease)
            return
        }
        turn.admissionLease = lease
        activeTurn = turn

        let grantPayload = AdmissionGrantedPayload(lease: lease)
        switch await submitBatch([
            DraftSpec(
                .admissionGranted,
                payload: EventPayloadCodec.encode(grantPayload) ?? Data(),
                source: "scheduler"
            )
        ], turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
        case .rejected(let reason):
            _ = try? await admissionCoordinator.release(lease)
            blockAfterSubmissionFailure(reason, context: "记录执行容量许可")
            return
        }

        if latestState.session.runtimeSelection.kind == .localAgent {
            await startLocalAgentAfterAdmission(lease: lease, generation: generation)
            return
        }

        guard let runtimeDispatch = await claimCommittedEffect(
            .startRuntime(attemptID: turn.attemptID),
            context: "启动模型运行时"
        ) else {
            _ = try? await admissionCoordinator.release(lease)
            return
        }

        do {
            try await admissionCoordinator.activate(lease)
        } catch {
            _ = try? await admissionCoordinator.release(lease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "激活执行容量许可"
            )
            beginFailure(
                reasonCode: .runtimeStartFailed,
                summary: "执行容量许可无法激活，模型请求未启动。",
                generation: generation
            )
            return
        }
        guard generation == currentGeneration,
              var activatedTurn = activeTurn,
              activatedTurn.generation == generation,
              activatedTurn.settling == false
        else {
            _ = try? await admissionCoordinator.release(lease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .cancelled,
                context: "取消已停止的模型运行时"
            )
            return
        }
        var activeLease = lease
        activeLease.state = .active
        activeLease.lastObservedAt = Date()
        activatedTurn.admissionLease = activeLease
        activeTurn = activatedTurn

        switch await submitBatch([
            DraftSpec(.runtimeStarted, source: "scheduler")
        ], turnID: activatedTurn.turnID, attemptID: activatedTurn.attemptID) {
        case .committed(let state):
            latestState = state
        case .rejected(let reason):
            _ = try? await admissionCoordinator.release(activeLease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "保存模型运行时启动"
            )
            blockAfterSubmissionFailure(reason, context: "保存模型运行时启动")
            return
        }

        // The durable runtimeStarted event crosses an await boundary. A
        // concurrent Stop, storage protection transition, or Runtime switch
        // must be observed before an external provider is started.
        guard generation == currentGeneration,
              let currentTurn = activeTurn,
              currentTurn.turnID == activatedTurn.turnID,
              currentTurn.attemptID == activatedTurn.attemptID,
              currentTurn.generation == generation,
              currentTurn.settling == false,
              storageError == nil,
              sessionBlocked == false,
              latestState.session.runtimeSelection.kind == .nativeAPI
        else {
            _ = try? await admissionCoordinator.release(activeLease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .cancelled,
                context: "取消受保护或已停止的模型运行时"
            )
            return
        }

        let didStartRuntime = await startStreaming(
            userQuestion: activatedTurn.userRequest,
            generation: generation,
            turnID: activatedTurn.turnID,
            attemptID: activatedTurn.attemptID
        )
        guard await settleClaimedEffect(
            runtimeDispatch,
            outcome: didStartRuntime ? .acknowledged : .cancelled,
            context: "记录模型运行时启动"
        ) else {
            return
        }
    }

    private func startLocalAgentAfterAdmission(
        lease: GlobalExecutionAdmissionLease,
        generation: UInt64
    ) async {
        guard generation == currentGeneration,
              var turn = activeTurn,
              turn.generation == generation,
              turn.attemptID == lease.attemptID,
              turn.admissionLease?.leaseID == lease.leaseID,
              turn.settling == false,
              let pending = pendingLocalAgentDelivery,
              pending.generation == generation
        else {
            _ = try? await admissionCoordinator.release(lease)
            return
        }

        guard let runtimeDispatch = await claimCommittedEffect(
            .startRuntime(attemptID: turn.attemptID),
            context: "启动 Local Agent 终端透传"
        ) else {
            _ = try? await admissionCoordinator.release(lease)
            pending.immediateResult = .accepted(turnID: turn.turnID)
            return
        }

        do {
            try await admissionCoordinator.activate(lease)
        } catch {
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "激活 Local Agent 执行容量许可"
            )
            pending.immediateResult = .accepted(turnID: turn.turnID)
            beginFailure(
                reasonCode: .runtimeStartFailed,
                summary: "执行容量许可无法激活，Local Agent 输入未投递。",
                generation: generation
            )
            return
        }
        guard generation == currentGeneration,
              var activatedTurn = activeTurn,
              activatedTurn.generation == generation,
              activatedTurn.settling == false
        else {
            _ = try? await admissionCoordinator.release(lease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .cancelled,
                context: "取消已停止的 Local Agent 终端透传"
            )
            return
        }
        var activeLease = lease
        activeLease.state = .active
        activeLease.lastObservedAt = Date()
        activatedTurn.admissionLease = activeLease
        activeTurn = activatedTurn
        turn = activatedTurn

        switch await submitBatch([
            DraftSpec(.runtimeStarted, source: "local-agent-runtime")
        ], turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
        case .rejected(let reason):
            _ = try? await admissionCoordinator.release(activeLease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "保存 Local Agent 运行时启动"
            )
            pending.immediateResult = .accepted(turnID: turn.turnID)
            blockAfterSubmissionFailure(reason, context: "保存 Local Agent 运行时启动")
            return
        }

        // `runtimeStarted` crosses an await boundary. A Stop from another
        // Inspector, a protection transition, or a Runtime change may have
        // happened while that durable fact was being committed. PTY input is
        // externally visible, so it must be the last operation and must not
        // rely on the checks made before the commit.
        guard generation == currentGeneration,
              let currentTurn = activeTurn,
              currentTurn.turnID == turn.turnID,
              currentTurn.attemptID == turn.attemptID,
              currentTurn.generation == generation,
              currentTurn.settling == false,
              currentTurn.admissionLease?.leaseID == activeLease.leaseID,
              pendingLocalAgentDelivery === pending,
              storageError == nil,
              sessionBlocked == false
        else {
            _ = try? await admissionCoordinator.release(activeLease)
            _ = await settleClaimedEffect(
                runtimeDispatch,
                outcome: .cancelled,
                context: "取消已停止或受保护的 Local Agent 终端透传"
            )
            // A durable Turn already owns this draft. Reporting it as unsent
            // would allow a duplicate after a concurrent Stop or recovery.
            pending.immediateResult = .accepted(turnID: turn.turnID)
            return
        }
        turn = currentTurn

        let selection = latestState.session.runtimeSelection
        guard selection.kind == .localAgent,
              selection.localAgentConfigurationID == pending.configurationID,
              selection.localAgentExecutionProfileID == pending.executionProfileID,
              selection.localAgentExecutionProfileKind == (pending.configuration.isReadyForStructuredRuntime
                ? .managed
                : .terminalPassthrough)
        else {
            _ = try? await admissionCoordinator.release(activeLease)
            guard await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "记录已变化的 Local Agent Runtime"
            ) else {
                restoreConsumedDraft(pending.draftToken, text: pending.text)
                pending.immediateResult = .rejected(reason: .storageUnavailable)
                return
            }
            pending.immediateResult = .rejected(reason: .runtimeUnavailable)
            restoreConsumedDraft(pending.draftToken, text: pending.text)
            beginFailure(
                reasonCode: .configurationInvalid,
                summary: "提交后 Local Agent Runtime 已变化，输入未投递。请重新确认 Runtime 后重试。",
                generation: generation
            )
            return
        }

        if pending.configuration.isReadyForStructuredRuntime {
            // Structured runtimes own the turn until they emit a protocol
            // terminal event. The PTY delivery event below would incorrectly
            // finalize the Attempt immediately, so it is intentionally skipped
            // for Codex app-server and Claude stream-json.
            guard await admitStructuredLocalAgentInvocation(
                userQuestion: pending.text,
                configuration: pending.configuration,
                generation: generation,
                turnID: turn.turnID,
                attemptID: turn.attemptID
            ) else {
                _ = try? await admissionCoordinator.release(activeLease)
                _ = await settleClaimedEffect(
                    runtimeDispatch,
                    outcome: .failed,
                    context: "记录 Local Agent 模型调用失败"
                )
                pending.immediateResult = .accepted(turnID: turn.turnID)
                return
            }
            pending.immediateResult = .accepted(turnID: turn.turnID)
            guard await settleClaimedEffect(
                runtimeDispatch,
                outcome: .acknowledged,
                context: "记录 Local Agent 结构化运行时启动"
            ) else {
                // The durable dispatch is no longer ours to retry after a
                // failed settlement. Release the scheduler lease so a
                // protected session cannot strand global capacity.
                _ = try? await admissionCoordinator.release(activeLease)
                return
            }

            // Both invocation admission and outbox settlement suspend. A
            // concurrent Stop, storage protection transition, or selection
            // change can therefore invalidate this launch after the earlier
            // checks. Never start an external provider unless the same turn,
            // attempt, lease, pending delivery, and generation still own the
            // authority immediately before Process creation.
            guard generation == currentGeneration,
                  let currentTurn = activeTurn,
                  currentTurn.turnID == turn.turnID,
                  currentTurn.attemptID == turn.attemptID,
                  currentTurn.generation == generation,
                  currentTurn.settling == false,
                  currentTurn.admissionLease?.leaseID == activeLease.leaseID,
                  pendingLocalAgentDelivery === pending,
                  latestState.activeAttempt?.id == turn.attemptID,
                  latestState.activeAttempt?.phase == .streaming,
                  latestState.phase == .streaming,
                  latestState.session.runtimeSelection.kind == .localAgent,
                  latestState.session.runtimeSelection.localAgentConfigurationID == pending.configurationID,
                  latestState.session.runtimeSelection.localAgentExecutionProfileID == pending.executionProfileID,
                  latestState.session.runtimeSelection.localAgentExecutionProfileKind == .managed,
                  storageError == nil,
                  sessionBlocked == false
            else {
                _ = try? await admissionCoordinator.release(activeLease)
                // The durable Turn already owns this draft. Do not report it
                // as unsent and allow the Composer to duplicate it after a
                // concurrent Stop or recovery transition.
                pending.immediateResult = .accepted(turnID: turn.turnID)
                return
            }

            let structuredRuntime = StructuredLocalAgentRuntime(
                configuration: pending.configuration,
                workingDirectory: pending.processWorkingDirectory
            )
            structuredLocalAgentRuntime = structuredRuntime
            activeStructuredLocalAgentConfiguration = pending.configuration
            resumeEffectiveExecutionTimer(generation: generation)
            structuredRuntime.start(
                prompt: structuredLocalAgentPrompt(pending.text),
                onEvent: { [weak self] event in
                    self?.handleStructuredLocalAgentEvent(
                        event,
                        generation: generation,
                        turnID: turn.turnID,
                        attemptID: turn.attemptID
                    )
                }
            )
            return
        }

        let frozenRuntimeID = currentTurn.targetRuntimeID
            ?? latestState.activeAttempt?.targetBindingSnapshot?.connectionID
        let resolvedContext = resolveTerminalContext(runtimeID: frozenRuntimeID)
        if currentTurn.targetBinding.connectionKind == "terminal",
           targetContextResolver != nil,
           (terminalContext(
                resolvedContext,
                matchesRuntimeID: frozenRuntimeID,
                generation: currentTurn.targetRuntimeGeneration
           ) == false
            || resolvedContext.map { makeTargetBinding(context: $0).digest }
                != currentTurn.targetBinding.digest) {
            _ = try? await admissionCoordinator.release(activeLease)
            guard await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "记录 Local Agent 执行目标已失效"
            ) else {
                restoreConsumedDraft(pending.draftToken, text: pending.text)
                pending.immediateResult = .rejected(reason: .storageUnavailable)
                return
            }
            pending.immediateResult = .rejected(reason: .targetUnavailable)
            restoreConsumedDraft(pending.draftToken, text: pending.text)
            beginFailure(
                reasonCode: .configurationInvalid,
                summary: "提交后执行目标已关闭、重连或工作目录已变化，Local Agent 输入未投递。请重新选择终端后重试。",
                generation: generation
            )
            return
        }

        let deliveryResult = pending.deliver()
        guard deliveryResult == .accepted else {
            guard await settleClaimedEffect(
                runtimeDispatch,
                outcome: .failed,
                context: "记录 Local Agent 输入未投递"
            ) else {
                restoreConsumedDraft(pending.draftToken, text: pending.text)
                pending.immediateResult = .rejected(reason: .storageUnavailable)
                return
            }
            pending.immediateResult = .rejected(reason: .runtimeUnavailable)
            await settleLocalAgentDeliveryFailure(
                turnID: turn.turnID,
                attemptID: turn.attemptID,
                result: deliveryResult
            )
            restoreConsumedDraft(pending.draftToken, text: pending.text)
            return
        }

        // The PTY write is externally visible. A later persistence failure is
        // reconciled fail-closed and must never be reported as an unsent input.
        pending.immediateResult = .accepted(turnID: turn.turnID)
        guard await settleClaimedEffect(
            runtimeDispatch,
            outcome: .acknowledged,
            context: "记录 Local Agent PTY 投递"
        ) else { return }

        let delivered = LocalAgentInputDeliveredPayload(
            attemptID: turn.attemptID,
            admissionSettlementID: lease.settlementID,
            idempotencyKey: runtimeDispatch.idempotencyKey,
            deliveryID: "delivery-\(UUID().uuidString.lowercased())",
            byteCount: Data(
                (pending.text.hasSuffix("\n") ? pending.text : pending.text + "\n").utf8
            ).count,
            configurationRevisionDigest: pending.configurationDigest
        )
        switch await submitBatch([
            DraftSpec(
                .localAgentInputDelivered,
                payload: EventPayloadCodec.encode(delivered) ?? Data(),
                source: "local-agent-runtime"
            )
        ], turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: turn.attemptID,
                    outcome: .passthroughInputDelivered,
                    reasonCode: .passthroughInputDelivered
                ),
                context: "结算 Local Agent 输入投递"
            ) else { return }
            archive(
                turn: turn,
                finalAnswer: "",
                status: .progress("输入已发送到 Local Agent 终端；任务状态请查看终端块。")
            )
            await finishTurn(turn, shouldAutoAdvance: false)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录 Local Agent 输入投递")
        }
    }

    private func settleAdmissionWaitExpired(
        request: GlobalExecutionAdmissionRequest,
        generation: UInt64
    ) async {
        guard let turn = beginSettlement(generation: generation) else { return }
        let payload = AdmissionResolvedPayload(
            requestID: request.requestID,
            leaseID: nil,
            attemptID: request.attemptID,
            schedulerGeneration: request.schedulerGeneration,
            resolvedAt: Date(),
            reason: "capacityWaitExpired"
        )
        switch await submitBatch([
            DraftSpec(
                .admissionWaitExpired,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                source: "scheduler"
            )
        ], turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: turn.attemptID,
                    outcome: .failed,
                    reasonCode: .capacityWaitExpired
                ),
                context: "结算容量等待超时"
            ) else { return }
            let summary = "等待全局执行容量超时，未启动模型请求。"
            archive(turn: turn, finalAnswer: "", status: .recovery(summary))
            onRuntimeUnavailable?(summary)
            await finishTurn(turn, shouldAutoAdvance: false)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录容量等待超时")
        }
    }

    private func settleAdmissionCancelled(
        request: GlobalExecutionAdmissionRequest,
        generation: UInt64
    ) async {
        guard let turn = beginSettlement(generation: generation) else { return }
        let payload = AdmissionResolvedPayload(
            requestID: request.requestID,
            leaseID: turn.admissionLease?.leaseID,
            attemptID: request.attemptID,
            schedulerGeneration: request.schedulerGeneration,
            resolvedAt: Date(),
            reason: "cancelled"
        )
        switch await submitBatch([
            DraftSpec(
                .admissionCancelled,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                source: "scheduler"
            )
        ], turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: turn.attemptID,
                    outcome: .cancelled,
                    reasonCode: .cancelled
                ),
                context: "结算已取消的容量等待"
            ) else { return }
            archive(turn: turn, finalAnswer: "", status: .progress("已取消等待"))
            await finishTurn(turn, shouldAutoAdvance: false)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录容量等待取消")
        }
    }

    // MARK: - Draft and pending-input queue

    public func updateDraft(_ text: String) {
        guard accessMode == .interactive else { return }
        localDraftText = text
        draftMutationGeneration &+= 1
        let generation = draftMutationGeneration
        draftSaveWorkItem?.cancel()
        draftSaveWorkItem = nil
        if restoreInProgress {
            pendingDraftDuringRestore = text
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                await self?.persistDraft(text, generation: generation)
            }
        }
        draftSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposerDraftPersistence.debounceInterval,
            execute: workItem
        )
    }

    public func editQueuedInput(id: String, text: String) async -> Bool {
        guard acceptsNewSubmissions else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        return await submitQueueMutation({ [self] in
            guard let current = latestState.session.queuedInputs.first(where: { $0.id == id }) else {
                return nil
            }
            var edited = current
            edited.text = trimmed
            edited.revision += 1
            edited.updatedAt = Date()
            let payload = QueuedInputEditedPayload(expectedRevision: current.revision, input: edited)
            return DraftSpec(
                .queuedInputEdited,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                scope: .session,
                source: "user"
            )
        },
            failureContext: "编辑待发送消息"
        )
    }

    public func queuedInputRebindSummary(for input: QueuedInput) -> String {
        guard input.revalidationState != .valid else { return "" }
        let frozen = input.contextSnapshot
        var changes: [String] = []

        if frozen.targetBindingSnapshot.connectionKind == "terminal",
           targetContextResolver != nil {
            if let liveContext = resolveTerminalContext(
                runtimeID: frozen.targetBindingSnapshot.connectionID
            ) {
                if makeTargetBinding(context: liveContext).digest != frozen.targetDigest {
                    changes.append("原目标身份或工作目录已变化")
                } else if liveContext.connectionGeneration != frozen.targetRuntimeGeneration {
                    changes.append("原终端连接已重连")
                }
            } else {
                changes.append("原目标已关闭")
            }
        }
        if currentProviderBinding(matching: frozen) == nil {
            changes.append("供应商、模型或凭证已变化")
        }
        if frozen.runtimeSettingsSnapshot == nil {
            changes.append("缺少入队时的运行设置快照")
        }
        if frozen.workMode == .agent,
           frozenToolAuthorizationPolicyIsValid(frozen) == false {
            changes.append("缺少可验证的终端审批策略快照")
        }
        if Self.workMode(for: selectedWorkMode) != frozen.workMode {
            changes.append("工作方式已变化")
        }
        if selectedExecutionChoice.rawValue != frozen.terminalMode {
            changes.append("执行终端已变化")
        }
        return changes.isEmpty ? "上下文需要重新确认" : changes.joined(separator: "；")
    }

    public func resolveQueuedInputRebind(
        id: String,
        choice: QueueRebindChoice
    ) async -> Bool {
        guard acceptsNewSubmissions else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        var replacementBinding: ProviderRuntimeBinding?
        var validationError: String?
        let committed = await submitQueueMutation({ [self] in
            validationError = nil
            replacementBinding = nil
            guard let current = latestState.session.queuedInputs.first(where: { $0.id == id }),
                  current.revalidationState != .valid
            else { return nil }

            let selectedSnapshot: QueuedInputContextSnapshot
            switch choice {
            case .sendWithOriginalContext:
                let frozen = current.contextSnapshot
                guard frozen.runtimeSettingsSnapshot != nil else {
                    validationError = "原上下文缺少入队时的运行设置快照，无法直接发送。请绑定到当前会话上下文。"
                    return nil
                }
                guard frozen.workMode != .agent
                    || frozenToolAuthorizationPolicyIsValid(frozen)
                else {
                    validationError = "原上下文缺少可验证的终端审批策略快照，无法直接发送。请绑定到当前会话上下文。"
                    return nil
                }
                if frozen.targetBindingSnapshot.connectionKind == "terminal",
                   targetContextResolver != nil {
                    guard let liveContext = resolveTerminalContext(
                        runtimeID: frozen.targetBindingSnapshot.connectionID
                    ), terminalContext(liveContext, matches: frozen) else {
                        validationError = "原目标已关闭、重连或工作目录已变化，无法按原上下文发送。请选择当前目标重新绑定。"
                        return nil
                    }
                }
                guard let binding = currentProviderBinding(matching: frozen) else {
                    validationError = "原供应商、模型或凭证已不可用，请绑定到当前会话上下文。"
                    return nil
                }
                selectedSnapshot = frozen
                replacementBinding = binding

            case .bindToCurrentSessionContext:
                let context = resolveTerminalContext(runtimeID: selectedTargetRuntimeID)
                guard selectedTargetRuntimeID == nil || context != nil else {
                    validationError = "当前选择的终端已关闭，请先选择可用目标。"
                    return nil
                }
                guard let provider, let providerConfig else {
                    validationError = "当前没有可用的供应商与模型配置。"
                    return nil
                }
                guard let runtimeSettingsSnapshot = captureRuntimeSettingsSnapshot() else {
                    validationError = "无法读取排查助手设置，待发送消息未重新绑定。"
                    return nil
                }
                let candidate = makeQueuedInput(
                    text: current.text,
                    runtimeSettingsSnapshot: runtimeSettingsSnapshot
                )
                selectedSnapshot = candidate.contextSnapshot
                replacementBinding = ProviderRuntimeBinding(
                    provider: provider,
                    configuration: providerConfig
                )
            }

            let (rebound, _) = QueuedInputRevalidator.rebind(
                input: current,
                to: selectedSnapshot,
                source: .explicitUserChoice,
                now: Date()
            )
            let payload = QueuedInputEditedPayload(
                expectedRevision: current.revision,
                input: rebound
            )
            return DraftSpec(
                .queuedInputEdited,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                scope: .session,
                source: "user-rebind"
            )
        }, failureContext: "重新绑定待发送消息")

        if committed, let replacementBinding {
            queuedProviderBindings[id] = replacementBinding
        } else if let validationError {
            reportError(validationError)
        }
        return committed
    }

    public func moveQueuedInput(id: String, to destination: Int) async -> Bool {
        guard acceptsNewSubmissions else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        return await submitQueueMutation({ [self] in
            guard let current = latestState.session.queuedInputs.first(where: { $0.id == id }) else {
                return nil
            }
            let payload = QueuedInputMovedPayload(
                inputID: id,
                expectedRevision: current.revision,
                destination: destination
            )
            return DraftSpec(
                .queuedInputMoved,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                scope: .session,
                source: "user"
            )
        },
            failureContext: "调整待发送顺序"
        )
    }

    public func setNextQueuedInput(id: String) async -> Bool {
        await moveQueuedInput(id: id, to: 0)
    }

    public func removeQueuedInput(id: String) async -> Bool {
        guard acceptsNewSubmissions else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        let removed = await submitQueueMutation({ [self] in
            guard let current = latestState.session.queuedInputs.first(where: { $0.id == id }) else {
                return nil
            }
            let payload = QueuedInputRemovedPayload(inputID: id, expectedRevision: current.revision)
            return DraftSpec(
                .queuedInputRemoved,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                scope: .session,
                source: "user"
            )
        },
            failureContext: "删除待发送消息"
        )
        if removed {
            queuedProviderBindings.removeValue(forKey: id)
        }
        return removed
    }

    public func pullQueuedInputToComposer(id: String) async -> String? {
        await pullQueuedInputToComposer(id: id, expectedDraft: localDraftText)
    }

    public func pullQueuedInputToComposer(
        id: String,
        expectedDraft: String
    ) async -> String? {
        guard acceptsNewSubmissions else {
            publishComposerState(forceQueueRefresh: true)
            return nil
        }
        guard expectedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              localDraftText == expectedDraft else {
            reportError("输入框已有未发送内容，待发送消息未被拉回。")
            publishComposerState(forceQueueRefresh: true)
            return nil
        }
        var pulledInput: QueuedInput?
        let committed = await submitQueueMutationBatch({ [self] in
            guard localDraftText == expectedDraft,
                  let current = latestState.session.queuedInputs.first(where: { $0.id == id })
            else { return nil }
            pulledInput = current
            let removal = QueuedInputRemovedPayload(
                inputID: current.id,
                expectedRevision: current.revision
            )
            return [
                DraftSpec(
                    .queuedInputRemoved,
                    payload: EventPayloadCodec.encode(removal) ?? Data(),
                    scope: .session,
                    source: "user"
                ),
                DraftSpec(
                    .draftChanged,
                    payload: Data(current.text.utf8),
                    scope: .session,
                    source: "user"
                )
            ]
        }, failureContext: "拉回待发送消息")
        guard committed, let pulledInput else { return nil }
        queuedProviderBindings.removeValue(forKey: pulledInput.id)
        draftMutationGeneration &+= 1
        draftSaveWorkItem?.cancel()
        draftSaveWorkItem = nil
        localDraftText = pulledInput.text
        return pulledInput.text
    }

    public func setQueueAutoAdvancePaused(_ paused: Bool) async -> Bool {
        guard acceptsNewSubmissions else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        let payload = QueueAutoAdvanceChangedPayload(paused: paused)
        let committed = await submitQueueMutation({
            DraftSpec(
                .queueAutoAdvanceChanged,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                scope: .session,
                source: "user"
            )
        },
            failureContext: paused ? "暂停队列自动衔接" : "恢复队列自动衔接"
        )
        if committed, paused == false {
            await promoteQueueIfIdle()
        }
        if committed {
            queuePreferencePersisted = true
        }
        return committed
    }

    private func persistDraft(_ text: String, generation: UInt64) async {
        guard generation == draftMutationGeneration,
              localDraftText == text else { return }
        draftSaveWorkItem = nil
        if restoreInProgress {
            pendingDraftDuringRestore = text
            return
        }
        guard storageError == nil, sessionBlocked == false,
              latestState.session.draft != text
        else { return }
        let active = activeTurn
        let specs = [
            DraftSpec(.draftChanged, payload: Data(text.utf8), scope: .session, source: "user")
        ]
        switch await submitBatch(specs, turnID: active?.turnID, attemptID: active?.attemptID) {
        case .committed(let state):
            latestState = state
        case .rejected(.sequenceGap), .rejected(.conflict):
            if let refreshed = actor.latestPublishedState,
               refreshed.lastAppliedSequence > latestState.lastAppliedSequence {
                latestState = refreshed
                if generation == draftMutationGeneration,
                   localDraftText == text {
                    updateDraft(text)
                }
            }
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "保存输入草稿")
        }
    }

    private func prepareDraftForSubmission(_ text: String) -> UInt64? {
        guard localDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
            == text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        draftMutationGeneration &+= 1
        draftSaveWorkItem?.cancel()
        draftSaveWorkItem = nil
        return draftMutationGeneration
    }

    private func completeDraftSubmission(
        _ token: UInt64?,
        text: String,
        committed: Bool
    ) {
        guard let token,
              token == draftMutationGeneration,
              localDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
                == text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        if committed {
            localDraftText = ""
            pendingDraftDuringRestore = nil
        } else {
            updateDraft(localDraftText)
        }
    }

    private func restoreConsumedDraft(_ token: UInt64?, text: String) {
        guard let token,
              token == draftMutationGeneration,
              localDraftText.isEmpty else { return }
        updateDraft(text)
    }

    private func submitQueueMutation(
        _ buildSpec: @escaping () -> DraftSpec?,
        failureContext: String,
        retryCount: Int = 0
    ) async -> Bool {
        await submitQueueMutationBatch(
            { buildSpec().map { [$0] } },
            failureContext: failureContext,
            retryCount: retryCount
        )
    }

    private func submitQueueMutationBatch(
        _ buildSpecs: @escaping () -> [DraftSpec]?,
        failureContext: String,
        retryCount: Int = 0
    ) async -> Bool {
        guard storageError == nil,
              sessionBlocked == false,
              restoreInProgress == false
        else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        let outcome = await submitOptionalBatch { [self] in
            guard let specs = buildSpecs() else { return nil }
            let active = activeTurn
            return SubmissionBatch(
                specs: specs,
                turnID: active?.turnID,
                attemptID: active?.attemptID
            )
        }
        guard let outcome else {
            publishComposerState(forceQueueRefresh: true)
            return false
        }
        switch outcome {
        case .committed(let state):
            latestState = state
            publishComposerState()
            renderTimeline()
            return true
        case .rejected(let reason):
            if retryCount < 1, Self.isRetryableConcurrentProjectionRejection(reason) {
                refreshProjectionAfterConcurrentWrite()
                return await submitQueueMutationBatch(
                    buildSpecs,
                    failureContext: failureContext,
                    retryCount: retryCount + 1
                )
            }
            blockAfterSubmissionFailure(reason, context: failureContext)
            publishComposerState(forceQueueRefresh: true)
            return false
        }
    }

    private func makeQueuedInput(
        text: String,
        runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot
    ) -> QueuedInput {
        let now = Date()
        let selection = runtimeSelectionForNextTurn(settings: runtimeSettingsSnapshot)
        let terminalContext = resolveTerminalContext(runtimeID: selectedTargetRuntimeID)
        let targetBinding = makeTargetBinding(context: terminalContext)
        let configuration = providerConfig
        let snapshots = configuration.map {
            makeProviderSnapshots(selection: selection, configuration: $0, capturedAt: now)
        }
        let configurationDigest = snapshots?.configurationDigest ?? ""
        let authentication = snapshots?.authentication ?? RuntimeAuthenticationSnapshot(
            mode: .noneVerified,
            configurationID: selection.providerConfigurationID
                ?? selection.codingPlanConfigurationID,
            configurationRevision: selection.revision,
            normalizedModelOrigin: nil,
            verificationFingerprint: "",
            createdAt: now,
            digest: ""
        )
        let toolAuthorizationPolicySnapshot = Self.workMode(for: selectedWorkMode) == .agent
            ? captureToolAuthorizationPolicySnapshot(
                targetBinding: targetBinding,
                targetRuntimeGeneration: terminalContext?.connectionGeneration
            )
            : nil
        let contextSnapshot = QueuedInputContextSnapshot(
            targetBindingSnapshot: targetBinding,
            targetWorkingDirectory: targetBinding.targetWorkingDirectory,
            targetDigest: targetBinding.digest,
            targetRuntimeGeneration: terminalContext?.connectionGeneration,
            runtimeSelectionSnapshot: selection,
            providerConfigurationID: selection.providerConfigurationID,
            codingPlanConfigurationID: selection.codingPlanConfigurationID,
            modelID: configuration?.model ?? selection.modelID,
            runtimeAuthenticationSnapshot: authentication,
            authenticationDigest: authentication.digest,
            configurationRevisionDigest: configurationDigest,
            workMode: Self.workMode(for: selectedWorkMode),
            terminalMode: selectedExecutionChoice.rawValue,
            policyRevision: "assistant-settings-\(runtimeSettingsSnapshot.registryRevision)",
            instructionDigest: runtimeSettingsSnapshot.instructionDigest,
            runtimeSettingsSnapshot: runtimeSettingsSnapshot,
            toolAuthorizationPolicySnapshot: toolAuthorizationPolicySnapshot,
            capturedAt: now,
            source: .sessionDefault
        )
        return QueuedInput(
            id: "queued-\(UUID().uuidString)",
            sessionID: sessionID,
            revision: 1,
            position: latestState.session.queuedInputs.count,
            text: text,
            contextSnapshot: contextSnapshot,
            createdAt: now,
            updatedAt: now
        )
    }

    private func captureRuntimeSettingsSnapshot() -> AssistantRuntimeSettingsSnapshot? {
        do {
            return try runtimeSettingsProvider()
        } catch {
            reportError("排查助手设置无法读取。为避免使用错误的执行策略，本次输入未发送。")
            return nil
        }
    }

    private func captureToolAuthorizationPolicySnapshot(
        targetBinding: TargetBinding,
        targetRuntimeGeneration: UInt64?
    ) -> AgentToolAuthorizationPolicySnapshot? {
        guard targetBinding.connectionID.isEmpty == false,
              let automationPolicy = terminalAutomationPolicyProvider(
                targetBinding.connectionID
              ) else { return nil }
        let settings = settingsProvider()
        return AgentToolAuthorizationPolicySnapshot(
            globalPolicy: settings.agentConfirmationPolicy.authorizationPolicy,
            commandPolicy: AgentCommandPatternPolicy(
                allowPatterns: settings.agentCommandAllowPatterns,
                denyPatterns: settings.agentCommandDenyPatterns
            ),
            automationPolicy: automationPolicy,
            targetRuntimeID: targetBinding.connectionID,
            targetRuntimeGeneration: targetRuntimeGeneration,
            targetBindingDigest: targetBinding.digest
        )
    }

    private func frozenToolAuthorizationPolicyIsValid(
        _ snapshot: QueuedInputContextSnapshot
    ) -> Bool {
        guard let policy = snapshot.toolAuthorizationPolicySnapshot else { return false }
        return policy.isBoundTo(
            runtimeID: snapshot.targetBindingSnapshot.connectionID,
            runtimeGeneration: snapshot.targetRuntimeGeneration,
            targetBindingDigest: snapshot.targetBindingSnapshot.digest
        )
    }

    private static func decodeRuntimeSettingsSnapshot(
        _ encoded: String
    ) -> AssistantRuntimeSettingsSnapshot? {
        guard encoded.isEmpty == false else { return nil }
        return try? JSONDecoder().decode(
            AssistantRuntimeSettingsSnapshot.self,
            from: Data(encoded.utf8)
        )
    }

    private static func decodeToolCapabilitySnapshot(
        _ encoded: String
    ) -> ToolCapabilitySnapshot? {
        guard encoded.isEmpty == false else { return nil }
        return try? JSONDecoder().decode(
            ToolCapabilitySnapshot.self,
            from: Data(encoded.utf8)
        )
    }

    private func markQueuedInputNeedsRebind(_ input: QueuedInput, reason: String) async {
        guard let current = latestState.session.queuedInputs.first(where: { $0.id == input.id }) else {
            reportError(reason)
            return
        }
        var edited = current
        edited.revision += 1
        edited.revalidationState = .needsRebind
        edited.updatedAt = Date()
        let editPayload = QueuedInputEditedPayload(
            expectedRevision: current.revision,
            input: edited
        )
        let pausePayload = QueueAutoAdvanceChangedPayload(paused: true)
        switch await submitBatch([
            DraftSpec(
                .queuedInputEdited,
                payload: EventPayloadCodec.encode(editPayload) ?? Data(),
                scope: .session,
                source: "runtime"
            ),
            DraftSpec(
                .queueAutoAdvanceChanged,
                payload: EventPayloadCodec.encode(pausePayload) ?? Data(),
                scope: .session,
                source: "runtime"
            )
        ]) {
        case .committed(let state):
            latestState = state
            publishComposerState()
            reportError(reason)
        case .rejected(let rejection):
            blockAfterSubmissionFailure(rejection, context: "暂停失效目标的待发送消息")
        }
    }

    // MARK: - Runtime

    private func startStreaming(
        userQuestion: String,
        generation: UInt64,
        turnID: String,
        attemptID: String,
        conversationHistory suppliedHistory: [AIAssistantConversationMessage]? = nil
    ) async -> Bool {
        // Admission/outbox work awaits the repository and can interleave with
        // Stop. Revalidate ownership immediately before creating any external
        // provider side effect; a cancelled or superseded turn must not send a
        // request whose callbacks would merely be discarded later.
        guard generation == currentGeneration,
              let activeTurn,
              activeTurn.generation == generation,
              activeTurn.turnID == turnID,
              activeTurn.attemptID == attemptID,
              activeTurn.settling == false
        else { return false }
        guard let providerBinding = activeTurn.providerBinding else {
            beginFailure(
                reasonCode: .configurationInvalid,
                summary: "未配置有效供应商",
                generation: generation
            )
            return false
        }
        guard let attempt = latestState.activeAttempt,
              let authentication = attempt.runtimeAuthenticationSnapshot,
              let configurationRevisionDigest = attempt.configurationRevisionDigest,
              validateRuntimeRoute(
                  selection: latestState.session.runtimeSelection,
                  authentication: authentication,
                  configuration: providerBinding.configuration,
                  configurationRevisionDigest: configurationRevisionDigest
              ) else {
            beginFailure(
                reasonCode: .authenticationFailed,
                summary: "Runtime 认证快照无法验证，模型请求未启动。请重新确认供应商配置。",
                generation: generation
            )
            return false
        }
        let frozenRuntimeID = activeTurn.targetRuntimeID
            ?? latestState.activeAttempt?.targetBindingSnapshot?.connectionID
        let resolvedContext = resolveTerminalContext(runtimeID: frozenRuntimeID)
        let frozenBinding = activeTurn.targetBinding
        if frozenBinding.connectionKind == "terminal",
           targetContextResolver != nil,
           terminalContext(
                resolvedContext,
                matchesRuntimeID: frozenRuntimeID,
                generation: activeTurn.targetRuntimeGeneration
           ) == false {
            beginFailure(
                reasonCode: .configurationInvalid,
                summary: "提交后执行目标已关闭或重连，模型请求未启动。请重新选择终端后重试。",
                generation: generation
            )
            return false
        }
        let context = resolvedContext ?? fallbackTerminalContext()
        currentRuntimeContext = context
        var history: [AIAssistantConversationMessage]
        if let suppliedHistory {
            history = suppliedHistory
        } else {
            history = []
            for archived in archivedTurns {
                history.append(AIAssistantConversationMessage(role: .user, content: archived.userRequest))
                if archived.finalAnswer.isEmpty == false {
                    history.append(AIAssistantConversationMessage(role: .assistant, content: archived.finalAnswer))
                }
            }
        }

        guard await admitModelInvocation(
            userQuestion: userQuestion,
            conversationHistory: history,
            generation: generation,
            turnID: turnID,
            attemptID: attemptID,
            configuration: providerBinding.configuration
        ), generation == currentGeneration,
           let currentTurn = self.activeTurn,
           currentTurn.generation == generation,
           currentTurn.settling == false
        else { return false }

        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: sessionID,
            turnID: turnID,
            attemptID: attemptID,
            targetBindingDigest: frozenBinding.digest,
            targetWorkingDirectory: context.currentDirectory,
            workMode: Self.workMode(for: currentTurn.workMode)
        )
        let runtime = NativeStreamingRuntime(
            provider: providerBinding.provider,
            configuration: providerBinding.configuration,
            request: request,
            terminalContext: context,
            settings: settingsProvider(),
            assistantSettings: currentTurn.runtimeSettingsSnapshot,
            allowedToolIDs: currentTurn.toolCapabilitySnapshot?.enabledToolIDs
        )
        self.runtime = runtime

        resumeEffectiveExecutionTimer(generation: generation)
        runtime.stream(
            userQuestion: userQuestion,
            conversationHistory: history,
            onDelta: { [weak self] delta in
                self?.accumulateDelta(delta, generation: generation)
            },
            onResponse: { [weak self] response in
                self?.pauseEffectiveExecutionTimer(generation: generation)
                self?.handleRuntimeResponse(response, generation: generation)
            },
            onError: { [weak self] failure in
                self?.pauseEffectiveExecutionTimer(generation: generation)
                self?.beginFailure(
                    reasonCode: failure.reasonCode,
                    summary: failure.summary,
                    generation: generation
                )
            },
            onCancelled: { [weak self] in
                self?.pauseEffectiveExecutionTimer(generation: generation)
                self?.beginCancellation(generation: generation, cancelRuntime: false)
            }
        )
        return true
    }

    private func admitModelInvocation(
        userQuestion: String,
        conversationHistory: [AIAssistantConversationMessage],
        generation: UInt64,
        turnID: String,
        attemptID: String,
        configuration: ProviderRuntimeConfiguration
    ) async -> Bool {
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.turnID == turnID,
              turn.attemptID == attemptID,
              turn.settling == false,
              let attempt = latestState.activeAttempt,
              attempt.id == attemptID,
              attempt.phase == .streaming
        else { return false }

        // A pending invocation can only be reused by the same durable runtime
        // dispatch during recovery. Creating another record would double count
        // one logical request and could bypass the frozen limit.
        if attempt.modelInvocations.contains(where: { $0.endedAt == nil }) {
            return true
        }

        let maximum = max(0, turn.runtimeSettingsSnapshot?.maxModelInvocations ?? 40)
        guard attempt.modelInvocations.count < maximum else {
            beginFailure(
                reasonCode: .modelInvocationLimitReached,
                summary: "模型调用次数已达到本轮上限（\(maximum)），未发起新的请求。",
                generation: generation
            )
            return false
        }

        let ordinal = attempt.modelInvocations.count + 1
        let invocationID = "model-\(attemptID)-\(ordinal)"
        let contextMaterial = ([
            userQuestion,
            turn.targetBinding.digest,
            configuration.effectiveConfigurationID,
            configuration.model,
            String(configuration.configurationRevision)
        ] + conversationHistory.map { "\($0.role.rawValue):\($0.content)" })
            .joined(separator: "\n")
        let payload = ModelInvocationStartedPayload(
            invocationID: invocationID,
            ordinal: ordinal,
            contextSnapshotID: "context-\(invocationID)",
            contextDigest: Self.sha256Digest(contextMaterial),
            runtimeCapabilitySnapshot: [
                configuration.runtimeConfigurationKind.rawValue,
                configuration.effectiveConfigurationID,
                configuration.model,
                "revision:\(configuration.configurationRevision)"
            ].joined(separator: "|"),
            startedAt: Date()
        )
        switch await submitBatch(
            [DraftSpec(
                .modelInvocationStarted,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                source: "runtime"
            )],
            turnID: turnID,
            attemptID: attemptID
        ) {
        case .committed(let state):
            latestState = state
            return true
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录模型调用")
            return false
        }
    }

    private func admitStructuredLocalAgentInvocation(
        userQuestion: String,
        configuration: LocalAgentPassthroughConfiguration,
        generation: UInt64,
        turnID: String,
        attemptID: String
    ) async -> Bool {
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.turnID == turnID,
              turn.attemptID == attemptID,
              turn.settling == false,
              let attempt = latestState.activeAttempt,
              attempt.id == attemptID,
              attempt.phase == .streaming,
              storageError == nil,
              sessionBlocked == false
        else { return false }

        if attempt.modelInvocations.contains(where: { $0.endedAt == nil }) {
            return true
        }
        let maximum = max(0, turn.runtimeSettingsSnapshot?.maxModelInvocations ?? 40)
        guard attempt.modelInvocations.count < maximum else {
            beginFailure(
                reasonCode: .modelInvocationLimitReached,
                summary: "Local Agent 模型调用次数已达到本轮上限（\(maximum)）。",
                generation: generation
            )
            return false
        }
        let ordinal = attempt.modelInvocations.count + 1
        let invocationID = "model-\(attemptID)-\(ordinal)"
        let contextMaterial = [
            userQuestion,
            turn.targetBinding.digest,
            configuration.configurationID,
            configuration.executionProfileID,
            configuration.structuredProtocol?.rawValue ?? "terminal-passthrough",
            "revision:\(configuration.configurationRevision)"
        ].joined(separator: "\n")
        let payload = ModelInvocationStartedPayload(
            invocationID: invocationID,
            ordinal: ordinal,
            contextSnapshotID: "context-\(invocationID)",
            contextDigest: Self.sha256Digest(contextMaterial),
            runtimeCapabilitySnapshot: [
                "local-agent",
                configuration.tool.rawValue,
                configuration.configurationID,
                configuration.executionProfileID,
                configuration.structuredProtocol?.rawValue ?? ""
            ].joined(separator: "|"),
            startedAt: Date()
        )
        switch await submitBatch(
            [DraftSpec(
                .modelInvocationStarted,
                payload: EventPayloadCodec.encode(payload) ?? Data(),
                source: "local-agent-runtime"
            )],
            turnID: turnID,
            attemptID: attemptID
        ) {
        case .committed(let state):
            latestState = state
            return true
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录 Local Agent 模型调用")
            return false
        }
    }

    private func modelInvocationCompletionSpec(
        attemptID: String,
        outcome: String
    ) -> DraftSpec? {
        guard let invocation = latestState.activeAttempt?.modelInvocations.last(where: {
            $0.attemptID == attemptID && $0.endedAt == nil
        }) else { return nil }
        let payload = ModelInvocationCompletedPayload(
            invocationID: invocation.id,
            endedAt: Date(),
            outcome: outcome,
            usage: nil
        )
        return DraftSpec(
            .modelInvocationCompleted,
            payload: EventPayloadCodec.encode(payload) ?? Data(),
            source: "runtime"
        )
    }

    private func resetEffectiveExecutionTimer() {
        effectiveExecutionDeadlineTask?.cancel()
        effectiveExecutionDeadlineTask = nil
        effectiveExecutionSegmentStartedAt = nil
        effectiveExecutionElapsed = 0
    }

    private func resumeEffectiveExecutionTimer(generation: UInt64) {
        guard effectiveExecutionSegmentStartedAt == nil,
              generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.settling == false
        else { return }

        let limit = TimeInterval(max(0, turn.runtimeSettingsSnapshot?.maxEffectiveMinutes ?? 30) * 60)
        let remaining = max(0, limit - effectiveExecutionElapsed)
        effectiveExecutionSegmentStartedAt = monotonicNowProvider()
        effectiveExecutionDeadlineTask?.cancel()
        effectiveExecutionDeadlineTask = Task { @MainActor [weak self] in
            if remaining > 0 {
                let nanoseconds = UInt64(min(remaining, 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            } else {
                await Task.yield()
            }
            guard Task.isCancelled == false else { return }
            await self?.expireEffectiveExecution(generation: generation, limitSeconds: limit)
        }
    }

    @discardableResult
    private func pauseEffectiveExecutionTimer(generation expectedGeneration: UInt64? = nil) -> TimeInterval {
        if let expectedGeneration,
           (expectedGeneration != currentGeneration || activeTurn?.generation != expectedGeneration) {
            return effectiveExecutionElapsed
        }
        if let startedAt = effectiveExecutionSegmentStartedAt {
            effectiveExecutionElapsed += max(0, monotonicNowProvider() - startedAt)
            effectiveExecutionSegmentStartedAt = nil
        }
        effectiveExecutionDeadlineTask?.cancel()
        effectiveExecutionDeadlineTask = nil
        return effectiveExecutionElapsed
    }

    private func expireEffectiveExecution(
        generation: UInt64,
        limitSeconds: TimeInterval
    ) async {
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.settling == false,
              effectiveExecutionSegmentStartedAt != nil
        else { return }

        let measured = pauseEffectiveExecutionTimer(generation: generation)
        let effectiveSeconds = max(measured, limitSeconds)
        if activeToolDispatch != nil {
            activeToolStopRequested = true
            guard let evidence = cancelActiveExecution(),
                  Self.isTerminalTraceState(evidence.state),
                  await settleToolForStop(turn: turn, evidence: evidence)
            else {
                await requireActiveToolReconciliation(
                    reason: "有效执行时间到期，但终端协调器未返回可验证的取消终态"
                )
                return
            }
        }

        guard let settlingTurn = beginSettlement(generation: generation) else { return }
        cancelPendingStructuredToolCalls(reason: "有效执行时间已用尽，工具请求未执行。")
        runtime?.cancel()
        runtime = nil
        structuredLocalAgentRuntime?.cancel()
        structuredLocalAgentRuntime = nil
        activeStructuredLocalAgentConfiguration = nil
        guard await awaitCheckpointCommitIfNeeded() else { return }

        var specs: [DraftSpec] = []
        if let completion = modelInvocationCompletionSpec(
            attemptID: settlingTurn.attemptID,
            outcome: "expired"
        ) {
            specs.append(completion)
        }
        if settlingTurn.pendingCheckpoint.isEmpty == false {
            specs.append(DraftSpec(
                .finalAnswerDelta,
                payload: Data(settlingTurn.pendingCheckpoint.utf8)
            ))
        }
        let expired = ExecutionTimeExpiredPayload(
            expiredAt: Date(),
            effectiveSeconds: effectiveSeconds,
            limitSeconds: limitSeconds
        )
        specs.append(DraftSpec(
            .executionTimeExpired,
            payload: EventPayloadCodec.encode(expired) ?? Data(),
            source: "effective-time-limit"
        ))
        appendQueuePauseIfNeeded(to: &specs, source: "effective-time-limit")

        switch await submitBatch(
            specs,
            turnID: settlingTurn.turnID,
            attemptID: settlingTurn.attemptID
        ) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: settlingTurn.attemptID,
                    outcome: .failed,
                    reasonCode: .executionTimeExpired
                ),
                context: "结算有效执行时间到期"
            ) else { return }
            let summary = "本轮有效执行时间已达到上限，模型和终端操作均已停止。"
            archive(
                turn: settlingTurn,
                finalAnswer: settlingTurn.accumulatedAnswer,
                status: .recovery(summary)
            )
            onRuntimeUnavailable?(summary)
            await finishTurn(settlingTurn, shouldAutoAdvance: false)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录有效执行时间到期")
        }
    }

    private func runtimeSelectionForNextTurn(
        settings: AssistantRuntimeSettingsSnapshot? = nil
    ) -> AgentRuntimeSelection {
        let previous = latestState.session.runtimeSelection
        if previous.kind == .localAgent {
            var selection = previous
            selection.workMode = .agent
            return selection
        }
        var selection = nativeRuntimeSelection(
            revision: previous.revision,
            reasoningEffort: settings?.defaultReasoningEffort
        )
        if selection != previous {
            selection.revision = previous.revision + 1
        }
        return selection
    }

    private func nativeRuntimeSelection(
        revision: Int,
        reasoningEffort: AIReasoningEffortPreference? = nil,
        configuration: ProviderRuntimeConfiguration? = nil
    ) -> AgentRuntimeSelection {
        let previous = latestState.session.runtimeSelection
        let effectiveConfiguration = configuration ?? providerConfig
        let configurationID = effectiveConfiguration?.effectiveConfigurationID
        let isCodingPlan = effectiveConfiguration?.runtimeConfigurationKind == .codingPlan
        return AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: isCodingPlan ? nil : configurationID,
            codingPlanConfigurationID: isCodingPlan ? configurationID : nil,
            localAgentConfigurationID: nil,
            localAgentExecutionProfileID: nil,
            localAgentExecutionProfileKind: .none,
            modelID: effectiveConfiguration?.model,
            reasoningEffort: reasoningEffort?.rawValue
                ?? (previous.kind == .nativeAPI ? previous.reasoningEffort : nil),
            workMode: Self.workMode(for: selectedWorkMode),
            revision: revision
        )
    }

    private func currentProviderBinding(
        matching snapshot: QueuedInputContextSnapshot
    ) -> ProviderRuntimeBinding? {
        guard let provider, let providerConfig else { return nil }
        guard snapshot.authenticationDigest == snapshot.runtimeAuthenticationSnapshot.digest,
              validateRuntimeRoute(
                  selection: snapshot.runtimeSelectionSnapshot,
                  authentication: snapshot.runtimeAuthenticationSnapshot,
                  configuration: providerConfig,
                  configurationRevisionDigest: snapshot.configurationRevisionDigest,
                  reportFailure: false
              )
        else { return nil }
        return ProviderRuntimeBinding(provider: provider, configuration: providerConfig)
    }

    private func providerBinding(
        matching attempt: TurnAttempt,
        selection: AgentRuntimeSelection
    ) -> ProviderRuntimeBinding? {
        guard selection.kind == .nativeAPI,
              let provider,
              let providerConfig,
              let expectedConfigurationDigest = attempt.configurationRevisionDigest,
              let expectedAuthenticationDigest = attempt.runtimeAuthenticationDigest,
              let authentication = attempt.runtimeAuthenticationSnapshot,
              authentication.digest == expectedAuthenticationDigest,
              validateRuntimeRoute(
                  selection: selection,
                  authentication: authentication,
                  configuration: providerConfig,
                  configurationRevisionDigest: expectedConfigurationDigest,
                  reportFailure: false
              )
        else { return nil }
        return ProviderRuntimeBinding(provider: provider, configuration: providerConfig)
    }

    /// Re-run the explicit router and authenticate the frozen configuration
    /// before any provider request. This is deliberately checked both when a
    /// turn is committed and immediately before streaming: credentials or the
    /// selected configuration may change while admission/outbox work is in
    /// flight. A failure never triggers an alternate runtime.
    private func validateRuntimeRoute(
        selection: AgentRuntimeSelection,
        authentication: RuntimeAuthenticationSnapshot,
        configuration: ProviderRuntimeConfiguration,
        configurationRevisionDigest: String,
        reportFailure: Bool = true
    ) -> Bool {
        let hasExplicitConfigurationID = configuration.configurationID?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let persistedSelectionID = selection.providerConfigurationID
            ?? selection.codingPlanConfigurationID
        let identifierlessLegacyIdentity = selection.providerConfigurationID == nil
            && selection.codingPlanConfigurationID == nil
            && hasExplicitConfigurationID == false
            && authentication.configurationID == nil
        let derivedLegacyIdentity = hasExplicitConfigurationID == false
            && persistedSelectionID.map(configuration.legacyConfigurationIDs.contains) == true
            && authentication.configurationID == persistedSelectionID
        let legacyIdentity = identifierlessLegacyIdentity || derivedLegacyIdentity
        let routedSelection = normalizedRoutingSelection(
            selection,
            configuration: configuration
        )
        let selectedID = routedSelection.providerConfigurationID
            ?? routedSelection.codingPlanConfigurationID
        let expectedID = configuration.effectiveConfigurationID
        let validConfigurationKind: Bool
        switch routedSelection.codingPlanConfigurationID != nil {
        case true:
            validConfigurationKind = configuration.runtimeConfigurationKind == .codingPlan
        case false:
            validConfigurationKind = configuration.runtimeConfigurationKind == .provider
        }
        let currentConfigurationDigest = Self.providerConfigurationDigest(
            selection: routedSelection,
            configuration: configuration
        )
        let legacyConfigurationDigest = Self.legacyProviderConfigurationDigest(
            selection: selection,
            configuration: configuration
        )
        let digestMatches = configurationRevisionDigest == currentConfigurationDigest
            || configurationRevisionDigest == legacyConfigurationDigest
        let currentAuthenticationDigest = Self.providerAuthenticationDigest(
            configuration,
            selection: routedSelection
        )
        let legacyAuthenticationDigest = Self.providerAuthenticationDigest(
            configuration,
            selection: selection
        )
        let authDigestMatches = authentication.digest == currentAuthenticationDigest
            || (legacyIdentity && authentication.digest == legacyAuthenticationDigest)
        let authFingerprintMatches = authentication.verificationFingerprint == configurationRevisionDigest
        let credentialEvidenceMatches: Bool
        if configuration.hasCredential,
           let credentialGenerationID = configuration.credentialGenerationID {
            credentialEvidenceMatches = authentication.mode == .stacioCredentialBindings
                && authentication.generationIDsByRole == ["apiKey": credentialGenerationID]
                && authentication.noCredentialProofDigest == nil
                && authentication.permitsNoCredentialEvidenceRevision == nil
        } else {
            credentialEvidenceMatches = authentication.mode == .noneVerified
                && authentication.generationIDsByRole.isEmpty
                && authentication.credentialAttemptBindingIDs.isEmpty
        }
        let identityMatches = selectedID == expectedID
            && (authentication.configurationID == expectedID || legacyIdentity)
        var authenticationForRoute = authentication
        if legacyIdentity {
            authenticationForRoute.configurationID = expectedID
        }
        let routerResult = RuntimeRouter.route(
            session: configuredSession(for: routedSelection),
            authentication: authenticationForRoute
        )
        let routeValid: Bool
        switch routerResult {
        case .success(.native(let providerID)):
            routeValid = validConfigurationKind
                && providerID == expectedID
                && routedSelection.providerConfigurationID == expectedID
        case .success(.codingPlan(let codingPlanID)):
            routeValid = validConfigurationKind
                && codingPlanID == expectedID
                && routedSelection.codingPlanConfigurationID == expectedID
        case .success(.localAgent):
            routeValid = false
        case .failure:
            routeValid = false
        }
        guard validConfigurationKind,
              digestMatches,
              authDigestMatches,
              authFingerprintMatches,
              credentialEvidenceMatches,
              identityMatches,
              routeValid,
              configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            if reportFailure {
                let reason: String
                switch routerResult {
                case .failure(.credentialUnavailable):
                    reason = "供应商凭据不可用"
                case .failure(.authenticationNeedsVerification):
                    reason = "供应商认证需要重新验证"
                case .failure:
                    reason = "Runtime 选择或配置不匹配"
                case .success:
                    reason = "Runtime 配置摘要不匹配"
                }
                reportError("\(reason)，未启动模型请求。请在设置中重新验证供应商配置。")
            }
            return false
        }
        return true
    }

    private func normalizedRoutingSelection(
        _ selection: AgentRuntimeSelection,
        configuration: ProviderRuntimeConfiguration
    ) -> AgentRuntimeSelection {
        guard selection.kind == .nativeAPI else { return selection }
        let selectedID = selection.providerConfigurationID
            ?? selection.codingPlanConfigurationID
        let missingIdentity = selectedID == nil
        let usesLegacyDerivedIdentity = configuration.configurationID?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && selectedID.map(configuration.legacyConfigurationIDs.contains) == true
        guard missingIdentity || usesLegacyDerivedIdentity else { return selection }
        var normalized = selection
        normalized.providerConfigurationID = nil
        normalized.codingPlanConfigurationID = nil
        if configuration.runtimeConfigurationKind == .codingPlan {
            normalized.codingPlanConfigurationID = configuration.effectiveConfigurationID
        } else {
            normalized.providerConfigurationID = configuration.effectiveConfigurationID
        }
        return normalized
    }

    private func configuredSession(for selection: AgentRuntimeSelection) -> ConversationSession {
        var session = latestState.session
        session.runtimeSelection = selection
        return session
    }

    private func isRetiredClaudeManagedSelection(
        _ selection: AgentRuntimeSelection,
        configuration: LocalAgentPassthroughConfiguration
    ) -> Bool {
        configuration.tool == .claude
            && configuration.structuredProtocol == .jsonl
            && configuration.isReadyForStructuredRuntime == false
            && selection.localAgentExecutionProfileKind == .managed
    }

    private func localAgentConfigurationDigest(
        _ configuration: LocalAgentPassthroughConfiguration
    ) -> String {
        Self.sha256Digest([
            configuration.configurationID,
            String(configuration.configurationRevision),
            configuration.catalogID,
            String(configuration.catalogSetRevision),
            String(configuration.descriptorRevision),
            configuration.executableIdentityDigest,
            configuration.executionProfileID,
            String(configuration.executionProfileRevision),
            configuration.structuredProtocol?.rawValue ?? "pty",
            configuration.authenticationEvidenceRevision,
            configuration.environmentDigest,
            configuration.workingDirectoryMode.rawValue,
            configuration.workingDirectoryReference ?? "",
            String(configuration.lastVerifiedAt.timeIntervalSince1970)
        ])
    }

    private func makeLocalAgentAuthenticationSnapshot(
        _ configuration: LocalAgentPassthroughConfiguration,
        configurationDigest: String,
        capturedAt: Date
    ) -> RuntimeAuthenticationSnapshot {
        let digest = Self.sha256Digest([
            configuration.configurationID,
            configurationDigest,
            configuration.authenticationEvidenceRevision,
            configuration.cliAuthenticationScopeDigest,
            configuration.cliLoginIdentityDigest
        ])
        return RuntimeAuthenticationSnapshot(
            mode: .cliManagedAuthentication,
            configurationID: configuration.configurationID,
            configurationRevision: configuration.configurationRevision,
            catalogSetRevision: String(configuration.catalogSetRevision),
            descriptorRevision: String(configuration.descriptorRevision),
            verificationFingerprint: configurationDigest,
            cliAuthenticationScopeDigest: configuration.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: configuration.cliLoginIdentityDigest,
            authenticationEvidenceRevision: configuration.authenticationEvidenceRevision,
            createdAt: capturedAt,
            digest: digest
        )
    }

    private func makeAgentProcessWorkingDirectory(
        _ configuration: LocalAgentPassthroughConfiguration,
        configurationDigest: String,
        workingDirectoryReference: String?
    ) -> AgentProcessWorkingDirectory? {
        let reference: String?
        switch configuration.workingDirectoryMode {
        case .managedWorkspace:
            guard configuration.workingDirectoryReference == nil,
                  workingDirectoryReference == nil else { return nil }
            // A structured Local Agent must never inherit the App's process
            // cwd. Scope it to the same per-session workspace used by the PTY
            // bridge so relative paths, AGENTS instructions, and the Codex
            // read-only sandbox all resolve against the troubleshooting turn.
            guard let managed = LocalAgentBridgeToolInstaller
                .sessionWorkspaceDirectory(for: sessionID)
            else { return nil }
            reference = managed
        case .userSelectedLocalDirectory:
            guard let stored = configuration.workingDirectoryReference,
                  workingDirectoryReference == nil || workingDirectoryReference == stored,
                  LocalAgentWorkingDirectoryValidator.canonicalExistingDirectory(stored) != nil
            else { return nil }
            reference = stored
        case .askEveryTurn:
            guard configuration.workingDirectoryReference == nil,
                  let selected = workingDirectoryReference,
                  LocalAgentWorkingDirectoryValidator.canonicalExistingDirectory(selected) != nil
            else { return nil }
            reference = selected
        }
        return AgentProcessWorkingDirectory(
            mode: configuration.workingDirectoryMode,
            localPathReference: reference,
            revision: configuration.configurationRevision,
            digest: Self.sha256Digest([
                configurationDigest,
                configuration.workingDirectoryMode.rawValue,
                reference ?? ""
            ]),
            allowedFilesystemScope: reference.map { [$0] } ?? [],
            targetMapping: .none
        )
    }

    private func makeProviderSnapshots(
        selection: AgentRuntimeSelection,
        configuration: ProviderRuntimeConfiguration,
        capturedAt: Date
    ) -> (authentication: RuntimeAuthenticationSnapshot, configurationDigest: String) {
        let configurationDigest = Self.providerConfigurationDigest(
            selection: selection,
            configuration: configuration
        )
        let authenticationDigest = Self.providerAuthenticationDigest(
            configuration,
            selection: selection
        )
        let hasCredential = configuration.hasCredential
        let normalizedOrigin = WebsiteActionResolver.normalizedOrigin(url: configuration.baseURL)
        let noCredentialProof = hasCredential == false
            && AIEndpointSecurityPolicy.isLoopbackHost(configuration.baseURL.host)
            ? Self.sha256Digest(["loopback-no-credential", normalizedOrigin ?? ""])
            : nil
        let authentication = RuntimeAuthenticationSnapshot(
            mode: hasCredential ? .stacioCredentialBindings : .noneVerified,
            configurationID: configuration.effectiveConfigurationID,
            configurationRevision: configuration.configurationRevision,
            normalizedModelOrigin: normalizedOrigin,
            verificationFingerprint: configurationDigest,
            generationIDsByRole: hasCredential
                ? ["apiKey": configuration.credentialGenerationID ?? ""]
                : [:],
            noCredentialProofDigest: noCredentialProof,
            permitsNoCredentialEvidenceRevision: noCredentialProof == nil
                ? nil
                : "loopback-policy-v1",
            createdAt: capturedAt,
            digest: authenticationDigest
        )
        return (authentication, configurationDigest)
    }

    nonisolated static func providerConfigurationDigest(
        selection: AgentRuntimeSelection,
        configuration: ProviderRuntimeConfiguration
    ) -> String {
        let explicitConfigurationID = configuration.configurationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = explicitConfigurationID?.isEmpty == false
            ? explicitConfigurationID!
            : (selection.providerConfigurationID
                ?? selection.codingPlanConfigurationID
                ?? "")
        return sha256Digest([
            identity,
            String(configuration.configurationRevision),
            configuration.runtimeConfigurationKind.rawValue,
            ProviderRuntimeConfiguration.normalizedEndpointIdentity(configuration.baseURL),
            configuration.model,
            String(configuration.requestTimeoutSeconds),
            configuration.userAgent
        ])
    }

    /// Digest format persisted before the API path was included. Validation
    /// accepts it for replay only; all newly written snapshots use the current
    /// path-aware digest above.
    nonisolated static func legacyProviderConfigurationDigest(
        selection: AgentRuntimeSelection,
        configuration: ProviderRuntimeConfiguration
    ) -> String {
        let explicitConfigurationID = configuration.configurationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = explicitConfigurationID?.isEmpty == false
            ? explicitConfigurationID!
            : (selection.providerConfigurationID
                ?? selection.codingPlanConfigurationID
                ?? "")
        return sha256Digest([
            identity,
            String(configuration.configurationRevision),
            configuration.runtimeConfigurationKind.rawValue,
            WebsiteActionResolver.normalizedOrigin(url: configuration.baseURL) ?? "",
            configuration.model,
            String(configuration.requestTimeoutSeconds),
            configuration.userAgent
        ])
    }

    nonisolated static func providerAuthenticationDigest(
        _ configuration: ProviderRuntimeConfiguration,
        selection: AgentRuntimeSelection? = nil
    ) -> String {
        let explicitConfigurationID = configuration.configurationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = explicitConfigurationID?.isEmpty == false
            ? explicitConfigurationID!
            : (selection?.providerConfigurationID
                ?? selection?.codingPlanConfigurationID
                ?? "")
        return sha256Digest([
            identity,
            configuration.credentialGenerationID ?? "<no-credential>"
        ])
    }

    nonisolated private static func sha256Digest(_ components: [String]) -> String {
        let data = Data(components.joined(separator: "\u{1F}").utf8)
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resolveTerminalContext(runtimeID: String?) -> AITerminalContext? {
        if let targetContextResolver {
            return targetContextResolver(runtimeID)
        }
        let context = terminalContextProvider()
        guard let runtimeID else { return context }
        return context?.runtimeID == runtimeID ? context : nil
    }

    private func shouldRebindTarget(
        selectedRuntimeID: String,
        currentContext: AITerminalContext
    ) -> Bool {
        if selectedRuntimeID == currentContext.runtimeID {
            return true
        }
        if selectedRuntimeID.hasPrefix("pending_") {
            return true
        }
        let expectedIdentity = selectedTargetIdentityFallback?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIdentity = currentContext.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return expectedIdentity?.isEmpty == false
            && currentIdentity.isEmpty == false
            && expectedIdentity == currentIdentity
    }

    private func terminalContext(
        _ context: AITerminalContext?,
        matches snapshot: QueuedInputContextSnapshot
    ) -> Bool {
        terminalContext(
            context,
            matchesRuntimeID: snapshot.targetBindingSnapshot.connectionID,
            generation: snapshot.targetRuntimeGeneration
        ) && context.map { makeTargetBinding(context: $0).digest == snapshot.targetDigest } == true
    }

    private func terminalContext(
        _ context: AITerminalContext?,
        matchesRuntimeID runtimeID: String?,
        generation: UInt64?
    ) -> Bool {
        guard let context,
              let runtimeID,
              let generation,
              context.isConnected,
              context.runtimeID == runtimeID,
              context.connectionGeneration == generation
        else { return false }
        return true
    }

    private func makeTargetBinding(context: AITerminalContext?) -> TargetBinding {
        guard let context else { return latestState.session.targetBinding }
        return Self.makeTargetBinding(
            context: context,
            previous: latestState.session.targetBinding
        )
    }

    static func makeTargetBinding(
        context: AITerminalContext,
        previous: TargetBinding
    ) -> TargetBinding {
        let digest = Self.stableDigest([
            context.historyScopeID,
            context.title,
            context.currentDirectory ?? ""
        ].joined(separator: "|"))
        let isSameTarget = previous.digest == digest
        return TargetBinding(
            id: "target-\(Self.stableDigest(context.historyScopeID))",
            revision: isSameTarget ? previous.revision : previous.revision + 1,
            digest: digest,
            connectionID: context.runtimeID,
            connectionKind: context.runtimeID == "local" ? "local" : "terminal",
            remoteIdentity: context.title,
            hostKeyFingerprint: nil,
            host: context.title,
            user: "",
            port: 0,
            targetWorkingDirectory: context.currentDirectory
                ?? previous.targetWorkingDirectory
        )
    }

    private static func workMode(for mode: TurnWorkMode) -> WorkMode {
        switch mode {
        case .agent: return .agent
        case .planFirst: return .plan
        case .answerOnly: return .answerOnly
        }
    }

    private static func turnWorkMode(for mode: WorkMode) -> TurnWorkMode {
        switch mode {
        case .agent: return .agent
        case .plan: return .planFirst
        case .answerOnly: return .answerOnly
        }
    }

    private static func turnExecutionChoice(for rawValue: String?) -> TurnExecutionChoice {
        rawValue.flatMap(TurnExecutionChoice.init(rawValue:)) ?? .realTerminal
    }

    private func resetAskEveryTurnSelectionIfNeeded(
        frozenChoice: TurnExecutionChoice,
        settings: AssistantRuntimeSettingsSnapshot
    ) {
        guard settings.defaultTerminalMode == TurnExecutionChoice.ask.rawValue,
              selectedExecutionChoice == frozenChoice
        else { return }
        selectedExecutionChoice = .ask
        onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
    }

    private func fallbackTerminalContext() -> AITerminalContext {
        let target = latestState.session.targetBinding
        return AITerminalContext(
            runtimeID: target.connectionID,
            historyScopeID: sessionID,
            title: target.remoteIdentity,
            currentDirectory: target.targetWorkingDirectory,
            recentTranscript: ""
        )
    }

    private func handleRuntimeResponse(_ response: AIAssistantResponse, generation: UInt64) {
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.settling == false
        else { return }

        // A model turn may contain several suggestions, but only the first
        // command is actionable.  The next command must be chosen after the
        // terminal result is observed; pre-queueing the rest leaves stale
        // approval cards waiting behind a command whose completion was not
        // established yet.
        let proposals = response.commandProposals.filter {
            $0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.prefix(1)
        guard proposals.isEmpty == false,
              latestState.workMode == .agent
        else {
            beginCompletion(fullMessage: response.message, generation: generation)
            return
        }

        Task { @MainActor [weak self] in
            await self?.stageToolProposals(
                Array(proposals),
                responseMessage: response.message,
                generation: generation
            )
        }
    }

    private func stageToolProposals(
        _ proposals: [AgentCommandProposal],
        responseMessage: String,
        generation: UInt64,
        structuredToolCall: StructuredLocalAgentToolCall? = nil
    ) async {
        let maximumToolRounds = activeTurn?.runtimeSettingsSnapshot?.maxToolSteps ?? 40
        guard toolRound < maximumToolRounds else {
            beginFailure(
                reasonCode: .protocolError,
                summary: "工具调用轮次超过安全上限",
                generation: generation
            )
            return
        }
        guard await flushAllPendingCheckpoints(generation: generation),
              let turn = activeTurn,
              turn.generation == generation,
              turn.settling == false
        else { return }
        guard let toolCatalog,
              let capabilitySnapshot = turn.toolCapabilitySnapshot else {
            beginFailure(
                reasonCode: .catalogInvalid,
                summary: "本轮没有可验证的工具目录快照，已拒绝 Runtime 工具建议",
                generation: generation
            )
            return
        }

        var seenIDs = Set<String>()
        let context: AITerminalContext
        if let currentRuntimeContext,
           currentRuntimeContext.runtimeID == turn.targetBinding.connectionID {
            context = currentRuntimeContext
        } else {
            context = resolveTerminalContext(runtimeID: turn.targetBinding.connectionID)
                ?? fallbackTerminalContext()
        }
        guard let invocationID = latestState.activeAttempt?.modelInvocations.last(where: {
            $0.attemptID == turn.attemptID && $0.endedAt == nil
        })?.id else {
            beginFailure(
                reasonCode: .protocolError,
                summary: "模型响应缺少可验证的调用记录，已停止处理工具建议。",
                generation: generation
            )
            return
        }
        let batchID = "batch-\(invocationID)"
        var payloads: [ConversationToolProposalPayload] = []
        for (index, proposal) in proposals.enumerated() {
            let proposalID = proposal.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolID = proposal.toolID.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = proposal.command.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = proposal.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard proposalID.isEmpty == false, seenIDs.insert(proposalID).inserted else {
                beginFailure(
                    reasonCode: .protocolError,
                    summary: "Provider 返回了无效或重复的工具调用标识",
                    generation: generation
                )
                return
            }
            let admission = ToolProposalAdmissionGate.evaluate(
                toolID: toolID,
                schemaRevision: proposal.schemaRevision,
                inputByteCount: command.utf8.count + explanation.utf8.count,
                targetBindingKind: turn.targetBinding.connectionKind,
                targetBindingDigest: turn.targetBinding.digest,
                snapshot: capabilitySnapshot,
                catalog: toolCatalog
            )
            guard case .available = admission else {
                beginFailure(
                    reasonCode: Self.isToolCatalogFailure(admission) ? .catalogInvalid : .protocolError,
                    summary: Self.toolProposalAdmissionFailureSummary(admission),
                    generation: generation
                )
                return
            }
            let classifiedRisk = AgentActionClassifier.risk(forCommand: command)
            payloads.append(ConversationToolProposalPayload(
                proposalID: proposalID,
                invocationID: invocationID,
                batchID: batchID,
                ordinal: index + 1,
                toolID: toolID,
                schemaRevision: proposal.schemaRevision,
                command: command,
                explanation: explanation,
                risk: classifiedRisk.rawValue,
                targetRuntimeID: context.runtimeID,
                targetRuntimeGeneration: turn.targetRuntimeGeneration,
                targetTitle: context.title
            ))
        }
        guard payloads.isEmpty == false else {
            beginCompletion(fullMessage: responseMessage, generation: generation)
            return
        }
        let duplicatePayloads = payloads.filter {
            completedToolCommandDigests.contains(Self.toolCommandDigest($0.command))
        }
        if duplicatePayloads.isEmpty == false {
            let command = duplicatePayloads[0].command
            appendToolObservation(
                "命令已在本轮成功执行过，已跳过重复执行：\(Self.redactedExecutionText(command))"
            )
            let completion = [
                responseMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                "检测到模型重复请求同一命令，已阻止再次执行；请直接基于上方已有终端结果给出结论。"
            ].filter { $0.isEmpty == false }.joined(separator: "\n\n")
            beginCompletion(fullMessage: completion, generation: generation)
            return
        }
        guard payloads.allSatisfy({ proposalPayloads[$0.proposalID] == nil }) else {
            beginFailure(
                reasonCode: .protocolError,
                summary: "Provider 重用了当前会话中的工具调用标识，已拒绝覆盖原始命令",
                generation: generation
            )
            return
        }

        let batch = ConversationToolProposalBatchPayload(proposals: payloads)
        let policyDisposition = toolAuthorizationDisposition(
            for: payloads[0],
            turn: turn
        )
        var specs: [DraftSpec] = []
        if let completion = modelInvocationCompletionSpec(
            attemptID: turn.attemptID,
            outcome: "completed"
        ) {
            specs.append(completion)
        }
        specs.append(DraftSpec(
            .toolProposed,
            payload: EventPayloadCodec.encode(batch) ?? Data(),
            source: "provider"
        ))
        switch policyDisposition {
        case .automatic(let evidence):
            specs.append(DraftSpec(
                .approvalNotRequired,
                payload: EventPayloadCodec.encode(evidence) ?? Data(),
                source: "policy"
            ))
        case .requiresApproval:
            let approval = makeApprovalRequestPayload(
                proposalID: payloads[0].proposalID,
                operation: payloads[0].command,
                turn: turn
            )
            specs.append(DraftSpec(
                .approvalRequested,
                payload: EventPayloadCodec.encode(approval) ?? Data(),
                source: "runtime"
            ))
        case .denied(let reason):
            let resolution = ToolProposalResolutionPayload(
                proposalID: payloads[0].proposalID,
                error: "本地策略阻止执行：\(reason)"
            )
            specs.append(DraftSpec(
                .toolProposalCancelled,
                payload: EventPayloadCodec.encode(resolution) ?? Data(),
                source: "policy"
            ))
        }
        switch await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            payloads.forEach { proposalPayloads[$0.proposalID] = $0 }
            if let structuredToolCall {
                structuredToolCallsByProposalID[payloads[0].proposalID] = structuredToolCall
            }
            lastToolResponseMessage = responseMessage
            toolRound += 1
            if structuredToolCall == nil {
                runtime = nil
            }
            if case .requiresApproval = policyDisposition {
                scheduleApprovalDeadlineIfNeeded()
            }
            publishComposerState()
            publishToolDecision()
            renderTimeline()
            switch policyDisposition {
            case .automatic:
                scheduleApprovedToolExecution(proposalID: payloads[0].proposalID)
            case .requiresApproval:
                break
            case .denied(let reason):
                appendToolObservation(
                    "工具建议 \(payloads[0].proposalID) 已被本地策略阻止：\(reason)"
                )
                if let structuredToolCall {
                    respondToStructuredToolCall(
                        structuredToolCall,
                        success: false,
                        text: "本地策略阻止执行：\(reason)"
                    )
                    structuredToolCallsByProposalID.removeValue(forKey: payloads[0].proposalID)
                } else {
                    scheduleProviderResume(after: payloads[0].proposalID)
                }
            }
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "保存工具建议")
        }
    }

    private enum ToolAuthorizationDisposition {
        case automatic(ApprovalNotRequiredPayload)
        case requiresApproval
        case denied(String)
    }

    private func toolAuthorizationDisposition(
        for proposal: ConversationToolProposalPayload,
        turn: ActiveTurn
    ) -> ToolAuthorizationDisposition {
        guard let snapshot = turn.toolAuthorizationPolicySnapshot,
              snapshot.isBoundTo(
                runtimeID: proposal.targetRuntimeID,
                runtimeGeneration: proposal.targetRuntimeGeneration,
                targetBindingDigest: turn.targetBinding.digest
              ),
              let inputs = snapshot.evaluationInputs
        else {
            return .requiresApproval
        }
        guard proposal.targetRuntimeGeneration != nil,
              targetContextResolver != nil,
              let currentContext = resolveTerminalContext(runtimeID: proposal.targetRuntimeID),
              currentContext.isConnected,
              currentContext.runtimeID == proposal.targetRuntimeID,
              currentContext.connectionGeneration == proposal.targetRuntimeGeneration,
              makeTargetBinding(context: currentContext).digest == turn.targetBinding.digest,
              let currentAutomationPolicy = terminalAutomationPolicyProvider(
                proposal.targetRuntimeID
              ) else {
            return .requiresApproval
        }
        let frozenEvaluation = AgentActionPolicyEvaluator.evaluate(
            policy: inputs.policy,
            commandPolicy: inputs.commandPolicy,
            command: proposal.command,
            automationPolicy: inputs.automationPolicy
        )
        let currentSettings = settingsProvider()
        let currentEvaluation = AgentActionPolicyEvaluator.evaluate(
            policy: currentSettings.agentConfirmationPolicy.authorizationPolicy,
            commandPolicy: AgentCommandPatternPolicy(
                allowPatterns: currentSettings.agentCommandAllowPatterns,
                denyPatterns: currentSettings.agentCommandDenyPatterns
            ),
            command: proposal.command,
            automationPolicy: currentAutomationPolicy
        )
        if frozenEvaluation.requirement == .denied {
            return .denied(frozenEvaluation.reason)
        }
        if currentEvaluation.requirement == .denied {
            return .denied(currentEvaluation.reason)
        }
        if frozenEvaluation.requirement == .requiresConfirmation
            || currentEvaluation.requirement == .requiresConfirmation {
            return .requiresApproval
        }
        switch frozenEvaluation.requirement {
        case .denied:
            return .denied(frozenEvaluation.reason)
        case .requiresConfirmation:
            return .requiresApproval
        case .allowedWithoutConfirmation:
            return .automatic(ApprovalNotRequiredPayload(
                proposalID: proposal.proposalID,
                requestDigest: Self.stableDigest(proposal.command),
                policySnapshotDigest: snapshot.digest,
                targetBindingDigest: turn.targetBinding.digest,
                targetRuntimeGeneration: turn.targetRuntimeGeneration,
                reason: frozenEvaluation.reason,
                risk: frozenEvaluation.risk.rawValue
            ))
        }
    }

    private func makeApprovalRequestPayload(
        proposalID: String,
        operation: String,
        turn: ActiveTurn
    ) -> ApprovalRequestedPayload {
        let createdAt = Date()
        let minutes = max(0, turn.runtimeSettingsSnapshot?.approvalDeadlineMinutes ?? 10)
        return ApprovalRequestedPayload(
            decisionID: "decision-\(Self.stableDigest("\(turn.attemptID)|\(proposalID)"))",
            proposalID: proposalID,
            requestDigest: Self.stableDigest(operation),
            createdAt: createdAt,
            deadline: createdAt.addingTimeInterval(TimeInterval(minutes) * 60)
        )
    }

    private static func isToolCatalogFailure(_ outcome: ToolProposalAdmissionOutcome) -> Bool {
        if case .catalogRevisionMismatch = outcome { return true }
        return false
    }

    private static func toolProposalAdmissionFailureSummary(
        _ outcome: ToolProposalAdmissionOutcome
    ) -> String {
        switch outcome {
        case .available:
            return "工具可用"
        case .catalogRevisionMismatch(let snapshot, let catalog):
            return "工具目录版本已变化（本轮 \(snapshot)，当前 \(catalog)），已拒绝执行"
        case .undeclaredTool(let toolID):
            return "Runtime 提出了未声明工具 \(toolID)，已拒绝执行"
        case .schemaRevisionMissing(let toolID):
            return "Runtime 工具 \(toolID) 缺少 schema revision，已拒绝执行"
        case .schemaRevisionMismatch(let toolID, let declared, let catalog):
            return "Runtime 工具 \(toolID) schema 不匹配（声明 \(declared)，目录 \(catalog)）"
        case .toolDisabled(let toolID):
            return "工具 \(toolID) 未在本轮冻结白名单中启用，已拒绝执行"
        case .targetBindingMismatch:
            return "工具建议的目标绑定与本轮冻结目标不一致，已拒绝执行"
        case .targetBindingUnsupported(let toolID, let kind):
            return "工具 \(toolID) 不适用于目标类型 \(kind)，已拒绝执行"
        case .inputTooLarge(let toolID, let maximum, let actual):
            return "工具 \(toolID) 输入超过目录上限（\(actual)/\(maximum) bytes）"
        }
    }

    private func flushAllPendingCheckpoints(generation: UInt64) async -> Bool {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard await awaitCheckpointCommitIfNeeded() else { return false }
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.pendingCheckpoint.isEmpty == false
        else { return generation == currentGeneration }
        await flushPendingCheckpoint(generation: generation)
        return sessionBlocked == false && generation == currentGeneration
    }

    // MARK: - Streaming checkpoint

    private func structuredLocalAgentPrompt(_ text: String) -> String {
        let history = archivedTurns.suffix(12).flatMap { archived -> [String] in
            var messages = ["User: \(archived.userRequest)"]
            if archived.finalAnswer.isEmpty == false {
                messages.append("Assistant: \(archived.finalAnswer)")
            }
            return messages
        }
        let instructions = """
        You are Stacio's troubleshooting assistant. Work on the selected terminal target only. When a command is needed, use the stacio_terminal dynamic tools: get_context is read-only and execute_command proposes a command for user approval. Do not claim that a command ran until the tool result is returned. Keep the final answer concise and operational.
        """
        guard history.isEmpty == false else {
            return [instructions, "User: \(text)", "Assistant:"].joined(separator: "\n\n")
        }
        return ([instructions] + history + ["User: \(text)", "Assistant:"]).joined(separator: "\n\n")
    }

    private func handleStructuredLocalAgentEvent(
        _ event: StructuredLocalAgentRuntimeEvent,
        generation: UInt64,
        turnID: String,
        attemptID: String
    ) {
        // A provider request must always receive a response when it carries
        // an id, even if the session is simultaneously entering protection or
        // settling. The runtime answers approval-like requests fail-closed and
        // returns an explicit protocol error for unsupported methods.
        if case .serverRequest(let request) = event {
            guard generation == currentGeneration else { return }
            structuredLocalAgentRuntime?.respondToServerRequest(request)
            return
        }
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.turnID == turnID,
              turn.attemptID == attemptID,
              turn.settling == false,
              storageError == nil,
              sessionBlocked == false
        else { return }

        switch event {
        case .serverRequest:
            // Handled before the turn-state guard so the provider always gets
            // an explicit response for id-bearing requests.
            return

        case .textDelta(let delta):
            accumulateDelta(delta, generation: generation)

        case .reasoningDelta(let delta):
            guard delta.isEmpty == false else { return }
            let capturedTurnID = turnID
            let capturedAttemptID = attemptID
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.currentGeneration,
                      let current = self.activeTurn,
                      current.turnID == capturedTurnID,
                      current.attemptID == capturedAttemptID,
                      current.settling == false
                else { return }
                switch await self.submitBatch(
                    [DraftSpec(.reasoningSummaryUpdated, payload: Data(delta.utf8))],
                    turnID: capturedTurnID,
                    attemptID: capturedAttemptID
                ) {
                case .committed(let state):
                    self.latestState = state
                    self.renderTimeline()
                case .rejected(let reason):
                    self.blockAfterSubmissionFailure(reason, context: "保存 Local Agent 推理摘要")
                }
            }

        case .toolCall(let call):
            Task { @MainActor [weak self] in
                await self?.handleStructuredLocalAgentToolCall(
                    call,
                    generation: generation,
                    turnID: turnID,
                    attemptID: attemptID
                )
            }

        case .completed(let fullMessage):
            pauseEffectiveExecutionTimer(generation: generation)
            beginCompletion(fullMessage: fullMessage, generation: generation)

        case .failed(let failure):
            pauseEffectiveExecutionTimer(generation: generation)
            beginFailure(
                reasonCode: failure.reasonCode,
                summary: failure.summary,
                generation: generation
            )

        case .cancelled:
            pauseEffectiveExecutionTimer(generation: generation)
            beginCancellation(generation: generation, cancelRuntime: false)
        }
    }

    private func handleStructuredLocalAgentToolCall(
        _ call: StructuredLocalAgentToolCall,
        generation: UInt64,
        turnID: String,
        attemptID: String
    ) async {
        guard generation == currentGeneration,
              let turn = activeTurn,
              turn.generation == generation,
              turn.turnID == turnID,
              turn.attemptID == attemptID,
              turn.settling == false,
              latestState.phase == .streaming,
              storageError == nil,
              sessionBlocked == false,
              structuredLocalAgentRuntime != nil,
              call.threadID != nil,
              call.turnID == turnID
        else { return }

        let namespace = call.namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard namespace == "stacio_terminal" else {
            respondToStructuredToolCall(
                call,
                success: false,
                text: "不支持的 Stacio 工具命名空间：\(call.namespace)"
            )
            return
        }

        switch call.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "get_context":
            // The frozen turn target, rather than the Inspector's currently
            // focused context, is authoritative when several terminals exist.
            let context = resolveTerminalContext(runtimeID: turn.targetBinding.connectionID)
                ?? (currentRuntimeContext?.runtimeID == turn.targetBinding.connectionID
                    ? currentRuntimeContext
                    : nil)
                ?? fallbackTerminalContext()
            let directory = context.currentDirectory ?? "未提供"
            let status = context.isConnected ? "connected" : "disconnected"
            let summary = [
                "target=\(context.title)",
                "runtime_id=\(context.runtimeID)",
                "status=\(status)",
                "working_directory=\(directory)",
                "connection_generation=\(context.connectionGeneration)"
            ].joined(separator: "\n")
            respondToStructuredToolCall(call, success: true, text: summary)

        case "execute_command":
            guard let data = call.argumentsJSON.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                respondToStructuredToolCall(call, success: false, text: "工具参数不是有效 JSON。")
                return
            }
            let command = (arguments["command"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = (arguments["reason"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedTarget = (arguments["targetTerminalSessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetRuntimeID = requestedTarget?.isEmpty == false
                ? requestedTarget!
                : turn.targetBinding.connectionID
            guard command.isEmpty == false else {
                respondToStructuredToolCall(call, success: false, text: "execute_command 缺少 command。")
                return
            }
            guard targetRuntimeID == turn.targetBinding.connectionID else {
                respondToStructuredToolCall(call, success: false, text: "工具请求的终端目标与当前会话目标不一致。")
                return
            }
            guard let configuration = activeStructuredLocalAgentConfiguration
                    ?? pendingLocalAgentDelivery?.configuration,
                  await admitStructuredLocalAgentInvocation(
                userQuestion: turn.userRequest,
                configuration: configuration,
                generation: generation,
                turnID: turnID,
                attemptID: attemptID
            ) else {
                respondToStructuredToolCall(call, success: false, text: "无法为工具请求建立可审计的模型调用记录。")
                return
            }
            let callKey = [call.threadID, call.turnID, call.callID]
                .compactMap { $0 }
                .joined(separator: ":")
            let proposalID = "structured-\(Self.stableDigest(callKey))"
            guard structuredToolCallsByProposalID.values.contains(where: { stored in
                stored.callID == call.callID
                    && stored.threadID == call.threadID
                    && stored.turnID == call.turnID
            }) == false,
                  proposalPayloads[proposalID] == nil
            else {
                respondToStructuredToolCall(call, success: false, text: "重复的工具请求已被忽略。")
                return
            }
            let proposal = AgentCommandProposal(
                id: proposalID,
                command: command,
                explanation: reason.isEmpty ? "由 Local Agent 提议执行此排查命令。" : reason
            )
            await stageToolProposals(
                [proposal],
                responseMessage: "",
                generation: generation,
                structuredToolCall: call
            )

        default:
            respondToStructuredToolCall(
                call,
                success: false,
                text: "不支持的 Stacio 工具：\(call.tool)"
            )
        }
    }

    private var activeStructuredConfiguration: LocalAgentPassthroughConfiguration? {
        activeStructuredLocalAgentConfiguration ?? pendingLocalAgentDelivery?.configuration
    }

    private func respondToStructuredToolCall(
        _ call: StructuredLocalAgentToolCall,
        success: Bool,
        text: String
    ) {
        structuredLocalAgentRuntime?.respondToToolCall(
            call,
            success: success,
            text: String(Self.redactedExecutionText(text).prefix(8_192))
        )
    }

    private func accumulateDelta(_ delta: String, generation: UInt64) {
        guard delta.isEmpty == false,
              generation == currentGeneration,
              var turn = activeTurn,
              turn.generation == generation,
              turn.settling == false
        else { return }
        turn.accumulatedAnswer += delta
        turn.pendingCheckpoint += delta
        activeTurn = turn
        scheduleCheckpoint(generation: generation)
    }

    /// 真正的 throttle：首个 token 安排 33ms 后提交，后续 token 只进入同一批，不重置计时器。
    private func scheduleCheckpoint(generation: UInt64) {
        guard flushWorkItem == nil, checkpointCommitTask == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flushPendingCheckpoint(generation: generation)
            }
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: item)
    }

    private func flushPendingCheckpoint(generation: UInt64) async {
        flushWorkItem = nil
        guard generation == currentGeneration,
              var turn = activeTurn,
              turn.generation == generation,
              turn.settling == false,
              turn.pendingCheckpoint.isEmpty == false
        else { return }

        let chunk = turn.pendingCheckpoint
        turn.pendingCheckpoint = ""
        activeTurn = turn
        renderTimeline()

        let specs = [
            DraftSpec(.finalAnswerDelta, payload: Data(chunk.utf8))
        ]
        let task = Task { @MainActor [self] in
            await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID)
        }
        checkpointCommitTask = task
        let outcome = await task.value
        checkpointCommitTask = nil

        switch outcome {
        case .committed(let state):
            latestState = state
            if generation == currentGeneration,
               let activeTurn,
               activeTurn.pendingCheckpoint.isEmpty == false,
               activeTurn.settling == false {
                scheduleCheckpoint(generation: generation)
            }
        case .rejected(let reason):
            abortRuntimeForPersistenceFailure(reason, context: "保存流式回答")
        }
    }

    private func awaitCheckpointCommitIfNeeded() async -> Bool {
        guard let task = checkpointCommitTask else { return true }
        switch await task.value {
        case .committed(let state):
            latestState = state
            checkpointCommitTask = nil
            return true
        case .rejected(let reason):
            checkpointCommitTask = nil
            blockAfterSubmissionFailure(reason, context: "保存流式回答")
            return false
        }
    }

    // MARK: - Tool approval and execution

    public var pendingToolDecision: PendingToolDecisionPresentation? {
        makePendingToolDecision()
    }

    @discardableResult
    public func resolveToolDecision(
        proposalID: String,
        approved: Bool
    ) async -> ToolDecisionResult {
        await resolveToolDecision(
            proposalID: proposalID,
            approved: approved,
            retryCount: 0
        )
    }

    /// Resolves one durable approval. A decision card can be visible in more
    /// than one Inspector window, so the local projection may be one event
    /// behind by the time the user clicks it. A sequence/conflict rejection is
    /// therefore a recoverable stale-window race, not a storage failure.
    private func resolveToolDecision(
        proposalID: String,
        approved: Bool,
        retryCount: Int
    ) async -> ToolDecisionResult {
        guard accessMode == .interactive else {
            return .rejected(reason: "V2 历史为只读，不能处理工具建议")
        }
        guard storageError == nil, sessionBlocked == false else {
            publishToolDecision()
            return .rejected(reason: "会话已进入只读保护，不能处理或执行工具建议")
        }
        if latestState.activeAttempt?.phase == .interruptedByRelaunch,
           latestState.activeAttempt?.activeToolProposalID == proposalID {
            return .rejected(reason: "App 重启后该审批已失效，请基于当前连接重新生成建议")
        }
        guard let durableTurn = latestState.activeTurn,
              let attempt = latestState.activeAttempt,
              attempt.phase.isTerminal == false,
              attempt.phase == .awaitingApproval,
              attempt.activeToolProposalID == proposalID,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == proposalID }),
              let decisionID = proposal.decisionID,
              latestState.decisions[decisionID]?.state == .pending
        else {
            return .rejected(reason: "该工具建议已失效或不再等待审批")
        }

        let resolution = ApprovalResolutionPayload(
            decisionID: decisionID,
            approved: approved,
            resolutionSource: "user"
        )
        switch await submitBatch(
            [DraftSpec(
                .approvalResolved,
                payload: EventPayloadCodec.encode(resolution) ?? Data(),
                source: "user"
            )],
            turnID: durableTurn.id,
            attemptID: attempt.id
        ) {
        case .committed(let state):
            latestState = state
            cancelApprovalDeadline(decisionID: decisionID)
            publishComposerState()
            publishToolDecision()
            renderTimeline()
            guard await acknowledgeCommittedEffect(
                .resolveDecision(
                    decisionID: decisionID,
                    outcome: approved ? .approved : .denied,
                    source: "user"
                ),
                context: "结算工具审批"
            ) else {
                return .rejected(reason: "审批 effect 结算失败")
            }
            // 审批可以从共享同一 Actor 的任意窗口提交；只有仍持有本地
            // ActiveTurn/Runtime 的窗口负责 claim effect 并继续运行。
            if activeTurn?.attemptID == attempt.id {
                if approved {
                    scheduleApprovedToolExecution(proposalID: proposalID)
                } else {
                    appendToolObservation("工具建议 \(proposalID) 已由用户拒绝，未执行任何命令。")
                if let structuredCall = structuredToolCallsByProposalID.removeValue(forKey: proposalID) {
                    respondToStructuredToolCall(
                        structuredCall,
                        success: false,
                        text: "用户拒绝了该命令，未执行任何操作。"
                    )
                } else if structuredLocalAgentRuntime == nil {
                    scheduleProviderResume(after: proposalID)
                }
                }
            }
            return .accepted
        case .rejected(let reason):
            if Self.isRetryableConcurrentProjectionRejection(reason) {
                let refreshed = refreshProjectionAfterConcurrentWrite()
                let stillPending = hasPendingToolDecision(proposalID: proposalID)
                if retryCount < 1, refreshed, stillPending {
                    return await resolveToolDecision(
                        proposalID: proposalID,
                        approved: approved,
                        retryCount: retryCount + 1
                    )
                }
                // Another window may have settled this exact proposal. Keep
                // this bridge usable and let the refreshed projection drive the
                // card; never permanently block the session for a stale click.
                return .rejected(
                    reason: stillPending
                        ? "会话刚刚被另一个窗口更新，请重试审批"
                        : "该工具建议已由另一个窗口处理"
                )
            }
            blockAfterSubmissionFailure(reason, context: "保存工具审批")
            return .rejected(reason: "审批状态保存失败")
        }
    }

    private func hasPendingToolDecision(proposalID: String) -> Bool {
        guard let attempt = latestState.activeAttempt,
              attempt.phase == .awaitingApproval,
              attempt.activeToolProposalID == proposalID,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == proposalID }),
              let decisionID = proposal.decisionID
        else {
            return false
        }
        return latestState.decisions[decisionID]?.state == .pending
    }

    private func scheduleApprovalDeadlineIfNeeded() {
        guard accessMode == .interactive,
              let turn = latestState.activeTurn,
              let attempt = latestState.activeAttempt,
              attempt.phase == .awaitingApproval,
              let proposalID = attempt.activeToolProposalID,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == proposalID }),
              let decisionID = proposal.decisionID,
              let decision = latestState.decisions[decisionID],
              decision.state == .pending,
              let deadline = decision.deadline
        else {
            cancelApprovalDeadline()
            return
        }
        if scheduledApprovalDecisionID == decisionID, approvalDeadlineTask != nil {
            return
        }

        cancelApprovalDeadline()
        scheduledApprovalDecisionID = decisionID
        let delay = max(0, deadline.timeIntervalSinceNow)
        approvalDeadlineTask = Task { @MainActor [weak self] in
            if delay > 0 {
                let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            } else {
                await Task.yield()
            }
            guard Task.isCancelled == false else { return }
            await self?.expireApprovalDecision(
                decisionID: decisionID,
                proposalID: proposalID,
                turnID: turn.id,
                attemptID: attempt.id,
                deadline: deadline
            )
        }
    }

    private func cancelApprovalDeadline(decisionID: String? = nil) {
        if let decisionID,
           scheduledApprovalDecisionID != decisionID {
            return
        }
        approvalDeadlineTask?.cancel()
        approvalDeadlineTask = nil
        scheduledApprovalDecisionID = nil
    }

    private func expireApprovalDecision(
        decisionID: String,
        proposalID: String,
        turnID: String,
        attemptID: String,
        deadline: Date
    ) async {
        guard scheduledApprovalDecisionID == decisionID,
              Date() >= deadline,
              latestState.activeTurn?.id == turnID,
              let attempt = latestState.activeAttempt,
              attempt.id == attemptID,
              attempt.phase == .awaitingApproval,
              attempt.activeToolProposalID == proposalID,
              latestState.decisions[decisionID]?.state == .pending
        else {
            if scheduledApprovalDecisionID == decisionID {
                cancelApprovalDeadline(decisionID: decisionID)
                scheduleApprovalDeadlineIfNeeded()
            }
            return
        }

        let expired = DecisionExpiredPayload(decisionID: decisionID)
        switch await submitBatch(
            [DraftSpec(
                .decisionExpired,
                payload: EventPayloadCodec.encode(expired) ?? Data(),
                source: "deadline"
            )],
            turnID: turnID,
            attemptID: attemptID
        ) {
        case .committed(let state):
            latestState = state
            cancelApprovalDeadline(decisionID: decisionID)
            publishComposerState()
            publishToolDecision()
            renderTimeline()
            guard await acknowledgeCommittedEffect(
                .resolveDecision(
                    decisionID: decisionID,
                    outcome: .expired,
                    source: "approvalExpired"
                ),
                context: "结算已过期审批"
            ) else { return }
            if activeTurn?.attemptID == attemptID {
                appendToolObservation("工具建议 \(proposalID) 的审批已过期，未执行任何命令。")
                if let structuredCall = structuredToolCallsByProposalID.removeValue(forKey: proposalID) {
                    respondToStructuredToolCall(
                        structuredCall,
                        success: false,
                        text: "审批已过期，未执行任何操作。"
                    )
                } else if structuredLocalAgentRuntime == nil {
                    scheduleProviderResume(after: proposalID)
                }
            }
        case .rejected(let reason):
            if Self.isRetryableConcurrentProjectionRejection(reason) {
                refreshProjectionAfterConcurrentWrite()
                scheduleApprovalDeadlineIfNeeded()
            } else {
                blockAfterSubmissionFailure(reason, context: "保存审批过期状态")
            }
        }
    }

    private func startApprovedToolExecution(proposalID: String) async {
        guard storageError == nil,
              sessionBlocked == false,
              let turn = activeTurn,
              turn.settling == false,
              latestState.phase == .executingTool,
              let payload = proposalPayloads[proposalID],
              let proposal = latestState.activeAttempt?.toolProposalQueue.first(where: { $0.id == proposalID }),
              payload.command == proposal.immutableOperation,
              payload.targetRuntimeID == turn.targetBinding.connectionID
        else { return }

        let approvalEvidence: AgentCommandApprovalEvidence
        switch proposal.approvalSource {
        case .userApproved:
            approvalEvidence = .userApproved
        case .policyAutoAllowed:
            approvalEvidence = .policyAutoAllowed
        case nil:
            blockForOutboxFailure("工具建议缺少可重放的审批来源，已阻止终端执行")
            return
        }

        let expectedCommand = EffectCommand.executeTool(
            attemptID: turn.attemptID,
            proposalID: proposalID
        )
        guard let dispatch = await claimCommittedEffect(
            expectedCommand,
            context: "派发终端工具"
        ) else { return }

        // Claiming the durable effect yields the MainActor. Stop may finish
        // cancelling this generation while the store is granting execution
        // ownership, so revalidate the complete authority snapshot before
        // publishing local dispatch state or touching the terminal.
        guard storageError == nil,
              sessionBlocked == false,
              let currentTurn = activeTurn,
              currentTurn.turnID == turn.turnID,
              currentTurn.attemptID == turn.attemptID,
              currentTurn.generation == turn.generation,
              currentTurn.generation == currentGeneration,
              currentTurn.settling == false,
              latestState.activeTurn?.id == turn.turnID,
              let currentAttempt = latestState.activeAttempt,
              currentAttempt.id == turn.attemptID,
              latestState.phase == .executingTool,
              currentAttempt.phase == .executingTool,
              currentAttempt.activeToolProposalID == proposalID,
              currentAttempt.toolProposalQueue.first(where: { $0.id == proposalID })?.state == .executing
        else {
            _ = await settleClaimedEffect(
                dispatch,
                outcome: .cancelled,
                context: "取消已停止的终端工具"
            )
            return
        }
        activeToolDispatch = dispatch
        activeToolDispatchHandedOff = false
        activeToolStopRequested = false
        activeToolSettlementOutcome = nil

        let requestID = "v2-\(Self.stableDigest(dispatch.effectID))"
        activeExecutionRequestID = requestID
        activeExecutionProposalID = proposalID
        traceEventsByProposalID[proposalID] = []
        if let targetValidationError = toolExecutionTargetValidationError(
            payload: payload,
            frozenBinding: turn.targetBinding
        ) {
            // The approval is bound to the exact target snapshot shown to the
            // user. A reused runtime ID is not enough to authorize execution
            // after the terminal identity or working directory has changed.
            await settleToolExecution(
                proposalID: proposalID,
                requestID: requestID,
                result: nil,
                error: targetValidationError
            )
            return
        }

        let startedPayload = ToolExecutionEventPayload(
            proposalID: proposalID,
            requestID: requestID,
            state: AgentTraceState.running.rawValue,
            summary: "工具执行已交给终端协调器"
        )
        switch await submitBatch(
            [DraftSpec(
                .toolStarted,
                payload: EventPayloadCodec.encode(startedPayload) ?? Data(),
                source: "agent-execution"
            )],
            turnID: turn.turnID,
            attemptID: turn.attemptID
        ) {
        case .committed(let state):
            latestState = state
        case .rejected(let reason):
            _ = await settleClaimedEffect(
                dispatch,
                outcome: .cancelled,
                context: "取消未启动的终端工具"
            )
            clearActiveToolExecutionTracking(for: dispatch)
            blockAfterSubmissionFailure(reason, context: "记录工具启动")
            return
        }

        guard storageError == nil,
              sessionBlocked == false,
              let currentTurn = activeTurn,
              currentTurn.turnID == turn.turnID,
              currentTurn.attemptID == turn.attemptID,
              currentTurn.generation == turn.generation,
              currentTurn.generation == currentGeneration,
              currentTurn.settling == false,
              latestState.activeTurn?.id == turn.turnID,
              let currentAttempt = latestState.activeAttempt,
              currentAttempt.id == turn.attemptID,
              currentAttempt.phase == .executingTool,
              currentAttempt.activeToolProposalID == proposalID,
              currentAttempt.toolProposalQueue.first(where: { $0.id == proposalID })?.state == .executing,
              activeToolDispatch?.itemID == dispatch.itemID,
              activeToolStopRequested == false
        else {
            // No terminal call has happened yet, so a lost authority snapshot
            // can be cancelled deterministically. A concurrent stop already
            // owns the durable tool-result path and must keep that ownership.
            if activeToolStopRequested == false {
                let settled = await settleClaimedEffect(
                    dispatch,
                    outcome: .cancelled,
                    context: "取消失去执行权的终端工具"
                )
                if settled {
                    clearActiveToolExecutionTracking(for: dispatch)
                }
            }
            return
        }
        renderTimeline()

        // Set the request identity before checking the coordinator. A missing
        // coordinator is a deterministic local failure and must still settle
        // the claimed outbox item through the durable tool-result path.
        guard let executionCoordinator else {
            await settleToolExecution(
                proposalID: proposalID,
                requestID: requestID,
                result: nil,
                error: "当前工作台无法访问终端执行协调器"
            )
            return
        }

        activeToolDispatchHandedOff = true
        let request = AgentBridgeRequest(
            id: requestID,
            actor: AgentActor(kind: .builtInAI, name: "Stacio 排查助手", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(payload.targetRuntimeID),
                command: payload.command,
                follow: true,
                expectedRuntimeGeneration: payload.targetRuntimeGeneration,
                approvalEvidence: approvalEvidence
            ))
        )
        do {
            resumeEffectiveExecutionTimer(generation: turn.generation)
            let returned: [AgentTraceEvent]
            if let asyncExecutionCoordinator = executionCoordinator as? AgentCommandAsyncStreamingExecuting {
                returned = try await asyncExecutionCoordinator.runCommandAsync(request) { [weak self] event in
                    self?.handleExecutionTrace(event, proposalID: proposalID)
                }
            } else {
                returned = try executionCoordinator.runCommand(request) { [weak self] event in
                    self?.handleExecutionTrace(event, proposalID: proposalID)
                }
            }
            for event in returned where traceEventsByProposalID[proposalID]?.contains(event) != true {
                handleExecutionTrace(event, proposalID: proposalID)
            }
        } catch {
            pauseEffectiveExecutionTimer(generation: turn.generation)
            if await settleKnownExecutionFailure(
                error,
                proposalID: proposalID,
                requestID: requestID
            ) {
                return
            }
            await requireActiveToolReconciliation(
                reason: "终端协调器返回错误，无法证明命令是否已启动：\(error.localizedDescription)"
            )
        }
    }

    /// A coordinator may emit a terminal event and then throw the matching
    /// control-flow error (for example, user denial). That terminal evidence
    /// must settle the durable outbox before the generic unknown-result fence
    /// can freeze the turn. Errors that are defined to occur before any write
    /// are also deterministic local failures.
    private func settleKnownExecutionFailure(
        _ error: Error,
        proposalID: String,
        requestID: String
    ) async -> Bool {
        if let terminalEvent = traceEventsByProposalID[proposalID]?.last(where: {
            $0.requestID == requestID && Self.isTerminalTraceState($0.state)
        }) {
            await settleToolExecution(
                proposalID: proposalID,
                requestID: requestID,
                result: terminalEvent.state == .completed
                    ? (terminalEvent.metadata?["terminalHistoryOutput"]
                        ?? terminalEvent.metadata?["terminalOutputSummary"]
                        ?? terminalEvent.message)
                    : nil,
                error: terminalEvent.state == .completed ? nil : terminalEvent.message
            )
            return true
        }

        guard let executionError = error as? AgentExecutionError else { return false }
        switch executionError {
        case .unsupportedAction, .terminalNotFound, .denied,
             .backgroundTaskUnavailable, .capabilityRejected,
             .terminalRuntimeLeaseChanged, .terminalInputRejected:
            await settleToolExecution(
                proposalID: proposalID,
                requestID: requestID,
                result: nil,
                error: RuntimeDiagnosticFormatter.userMessage(for: executionError)
            )
            return true
        case .requestAlreadyActive:
            // The stable request ID may refer to a command that crossed an
            // earlier dispatch boundary. Only reconciliation can resolve it.
            return false
        }
    }

    private func toolExecutionTargetValidationError(
        payload: ConversationToolProposalPayload,
        frozenBinding: TargetBinding
    ) -> String? {
        guard let toolCatalog,
              let capabilitySnapshot = activeTurn?.toolCapabilitySnapshot else {
            return "本轮工具目录快照不可验证，命令未执行。"
        }
        let admission = ToolProposalAdmissionGate.evaluate(
            toolID: payload.toolID,
            schemaRevision: payload.schemaRevision,
            inputByteCount: payload.command.utf8.count + payload.explanation.utf8.count,
            targetBindingKind: frozenBinding.connectionKind,
            targetBindingDigest: frozenBinding.digest,
            snapshot: capabilitySnapshot,
            catalog: toolCatalog
        )
        guard case .available = admission else {
            return Self.toolProposalAdmissionFailureSummary(admission)
        }
        guard let expectedGeneration = payload.targetRuntimeGeneration else {
            return "该审批缺少终端连接代次，命令未执行。请基于当前连接重新请求。"
        }
        // Without an ID-addressable resolver there is no stronger live target
        // evidence than the immutable proposal snapshot. Production assembly
        // supplies this resolver for every terminal exposed to the assistant.
        // A missing resolver may preserve legacy read-only projections, but it
        // must never authorize a durable V2 command.
        guard targetContextResolver != nil else {
            return "当前工作台无法验证审批绑定的终端连接，命令未执行。请重新打开排查助手后再试。"
        }
        guard let currentContext = resolveTerminalContext(runtimeID: payload.targetRuntimeID) else {
            return "批准后执行目标已关闭或不可用，命令未执行。请重新选择目标并再次请求。"
        }
        guard currentContext.runtimeID == payload.targetRuntimeID else {
            return "批准后执行目标的运行时身份已变化，命令未执行。请重新选择目标并再次请求。"
        }
        guard currentContext.isConnected,
              currentContext.connectionGeneration == expectedGeneration
        else {
            return "批准后目标终端已断开或重连，命令未执行。请基于当前连接重新请求。"
        }
        let currentBinding = makeTargetBinding(context: currentContext)
        guard currentBinding.digest == frozenBinding.digest else {
            return "批准后执行目标的身份或工作目录已变化，命令未执行。请基于当前目标重新请求。"
        }
        return nil
    }

    private func scheduleApprovedToolExecution(proposalID: String) {
        guard scheduledToolStartProposalID == nil,
              activeToolDispatch == nil,
              activeExecutionRequestID == nil,
              activeTurn?.settling == false
        else { return }
        scheduledToolStartProposalID = proposalID
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startApprovedToolExecution(proposalID: proposalID)
            if self.scheduledToolStartProposalID == proposalID {
                self.scheduledToolStartProposalID = nil
            }
        }
    }

    private func scheduleProviderResume(after proposalID: String) {
        guard scheduledToolResumeProposalID == nil,
              runtime == nil,
              activeTurn?.settling == false
        else { return }
        scheduledToolResumeProposalID = proposalID
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activateNextToolProposalOrResume()
            if self.scheduledToolResumeProposalID == proposalID {
                self.scheduledToolResumeProposalID = nil
            }
        }
    }

    private func handleExecutionTrace(_ event: AgentTraceEvent, proposalID: String) {
        var event = Self.sanitizedExecutionTrace(event)
        guard let turn = activeTurn,
              activeExecutionProposalID == proposalID,
              activeExecutionRequestID == event.requestID,
              turn.settling == false
        else { return }
        if event.state == .completed {
            let candidate = event.metadata?["terminalHistoryOutput"]
                ?? event.metadata?["terminalOutputSummary"]
                ?? event.message
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var metadata = event.metadata ?? [:]
                metadata["terminalOutputSummary"] = "命令已完成，但终端没有返回文本输出。"
                event = AgentTraceEvent(
                    requestID: event.requestID,
                    state: event.state,
                    message: event.message,
                    redactedCommand: event.redactedCommand,
                    metadata: metadata
                )
            }
        }
        if traceEventsByProposalID[proposalID]?.contains(event) != true {
            traceEventsByProposalID[proposalID, default: []].append(event)
        }
        renderTimeline()

        guard Self.isTerminalTraceState(event.state) else { return }
        pauseEffectiveExecutionTimer(generation: turn.generation)
        // Terminal traces are authoritative for this request. Ignore a
        // duplicate terminal callback before it can schedule a second
        // settlement task (the coordinator can emit via callback and return).
        guard terminalTraceRequestIDs.insert(event.requestID).inserted else { return }
        var result: String?
        if event.state == .completed {
            let candidate = event.metadata?["terminalHistoryOutput"]
                ?? event.metadata?["terminalOutputSummary"]
                ?? event.message
            result = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "命令已完成，但终端没有返回文本输出。"
                : candidate
        }
        let error = event.state == .completed ? nil : event.message
        Task { @MainActor [weak self] in
            await self?.settleToolExecution(
                proposalID: proposalID,
                requestID: event.requestID,
                result: result,
                error: error
            )
        }
    }

    private func settleToolExecution(
        proposalID: String,
        requestID: String,
        result: String?,
        error: String?
    ) async {
        guard let turn = activeTurn,
              turn.settling == false,
              latestState.phase == .executingTool,
              latestState.activeAttempt?.activeToolProposalID == proposalID,
              activeExecutionRequestID == requestID,
              let dispatch = activeToolDispatch
        else { return }

        let preferredOutcome: ConversationOutboxSettlementOutcome = error == nil ? .completed : .failed
        if activeToolSettlementOutcome == nil {
            activeToolSettlementOutcome = preferredOutcome
        }
        let settlementOutcome = activeToolSettlementOutcome ?? preferredOutcome

        let redactedResult = result.map(Self.redactedExecutionText)
        let result = redactedResult.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let redactedError = error.map(Self.redactedExecutionText)
        let error = redactedError.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let summary = result ?? error ?? "工具执行已结束"
        let completedPayload = ToolExecutionEventPayload(
            proposalID: proposalID,
            requestID: requestID,
            state: error == nil ? AgentTraceState.completed.rawValue : AgentTraceState.failed.rawValue,
            summary: String(summary.prefix(4_096))
        )
        let resolution = ToolProposalResolutionPayload(
            proposalID: proposalID,
            result: result.map { String($0.prefix(4_096)) },
            error: error.map { String($0.prefix(4_096)) }
        )
        let specs = [
            DraftSpec(
                .toolCompleted,
                payload: EventPayloadCodec.encode(completedPayload) ?? Data(),
                source: "agent-execution"
            ),
            DraftSpec(
                .toolProposalResolved,
                payload: EventPayloadCodec.encode(resolution) ?? Data(),
                source: "agent-execution"
            )
        ]
        switch await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await settleClaimedEffect(
                    dispatch,
                    outcome: settlementOutcome,
                    context: "结算终端工具结果"
                  ) else {
                return
            }
            clearActiveToolExecutionTracking(for: dispatch)
            if error == nil, let payload = proposalPayloads[proposalID] {
                completedToolCommandDigests.insert(Self.toolCommandDigest(payload.command))
            }
            if let result {
                appendToolObservation("工具 \(proposalID) 已完成：\(String(result.prefix(4_096)))")
            } else if let error {
                appendToolObservation("工具 \(proposalID) 未完成：\(String(error.prefix(4_096)))")
            } else {
                appendToolObservation("工具 \(proposalID) 已完成，但终端没有返回文本输出。")
            }
            publishComposerState()
            renderTimeline()
            if let structuredCall = structuredToolCallsByProposalID.removeValue(forKey: proposalID) {
                // A structured Runtime remains suspended while the command is
                // reviewed and executed. The tool proposal closes the model
                // invocation that produced it; open the next invocation
                // before returning the result so the continued answer is
                // represented in the durable audit trail as well.
                let resumedInvocation: Bool
                if let configuration = activeStructuredConfiguration {
                    resumedInvocation = await admitStructuredLocalAgentInvocation(
                        userQuestion: turn.userRequest,
                        configuration: configuration,
                        generation: turn.generation,
                        turnID: turn.turnID,
                        attemptID: turn.attemptID
                    )
                } else {
                    resumedInvocation = false
                }
                respondToStructuredToolCall(
                    structuredCall,
                    success: error == nil && resumedInvocation,
                    text: resumedInvocation
                        ? (result ?? error ?? "工具执行已结束")
                        : "工具结果已保存，但无法安全继续模型调用。"
                )
                return
            }
            await activateNextToolProposalOrResume()
        case .rejected(let reason):
            // A duplicate terminal task can reach the FIFO after the first
            // task has already committed the resolution. Treat that durable
            // state as an idempotent success; only an unresolved rejection
            // remains a genuine persistence fault.
            if latestState.activeAttempt?.toolProposalQueue.first(where: { $0.id == proposalID })?.state == .resolved
                || latestState.activeAttempt?.activeToolProposalID != proposalID
                || latestState.phase != .executingTool {
                return
            }
            terminalTraceRequestIDs.remove(requestID)
            blockAfterSubmissionFailure(reason, context: "保存工具执行结果")
        }
    }

    private func activateNextToolProposalOrResume() async {
        guard let turn = activeTurn,
              turn.settling == false,
              latestState.phase == .streaming
        else { return }
        if let next = latestState.activeAttempt?.toolProposalQueue.first(where: { $0.state == .queued }) {
            let activation = ToolProposalActivationPayload(proposalID: next.id)
            guard let payload = proposalPayloads[next.id] else {
                beginFailure(
                    reasonCode: .protocolError,
                    summary: "排队工具建议缺少不可变载荷，已停止执行",
                    generation: turn.generation
                )
                return
            }
            let policyDisposition = toolAuthorizationDisposition(for: payload, turn: turn)
            var specs = [DraftSpec(
                .toolProposalActivated,
                payload: EventPayloadCodec.encode(activation) ?? Data(),
                source: "runtime"
            )]
            switch policyDisposition {
            case .automatic(let evidence):
                specs.append(DraftSpec(
                    .approvalNotRequired,
                    payload: EventPayloadCodec.encode(evidence) ?? Data(),
                    source: "policy"
                ))
            case .requiresApproval:
                let approval = makeApprovalRequestPayload(
                    proposalID: next.id,
                    operation: next.immutableOperation,
                    turn: turn
                )
                specs.append(DraftSpec(
                    .approvalRequested,
                    payload: EventPayloadCodec.encode(approval) ?? Data(),
                    source: "runtime"
                ))
            case .denied(let reason):
                let resolution = ToolProposalResolutionPayload(
                    proposalID: next.id,
                    error: "本地策略阻止执行：\(reason)"
                )
                specs.append(DraftSpec(
                    .toolProposalCancelled,
                    payload: EventPayloadCodec.encode(resolution) ?? Data(),
                    source: "policy"
                ))
            }
            switch await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID) {
            case .committed(let state):
                latestState = state
                switch policyDisposition {
                case .automatic:
                    scheduleApprovedToolExecution(proposalID: next.id)
                case .requiresApproval:
                    scheduleApprovalDeadlineIfNeeded()
                case .denied(let reason):
                    appendToolObservation("工具建议 \(next.id) 已被本地策略阻止：\(reason)")
                    scheduleProviderResume(after: next.id)
                }
                publishComposerState()
                publishToolDecision()
                renderTimeline()
            case .rejected(let reason):
                blockAfterSubmissionFailure(reason, context: "激活下一条工具建议")
            }
            return
        }
        await resumeProviderAfterTools()
    }

    private func resumeProviderAfterTools() async {
        guard let turn = activeTurn,
              turn.settling == false,
              latestState.phase == .streaming
        else { return }

        var history: [AIAssistantConversationMessage] = []
        for archived in archivedTurns {
            history.append(AIAssistantConversationMessage(role: .user, content: archived.userRequest))
            if archived.finalAnswer.isEmpty == false {
                history.append(AIAssistantConversationMessage(role: .assistant, content: archived.finalAnswer))
            }
        }
        history.append(AIAssistantConversationMessage(role: .user, content: turn.userRequest))
        if let lastToolResponseMessage,
           lastToolResponseMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            history.append(AIAssistantConversationMessage(role: .assistant, content: lastToolResponseMessage))
        }
        let observations = toolObservations.joined(separator: "\n")
        let continuationQuestion = [
            "继续处理同一用户请求。以下是经权限与审计链执行后的工具状态摘要：",
            observations.isEmpty ? "没有可用工具结果。" : observations,
            "工具结果已经返回。若这些事实足以回答原问题（尤其是单条只读查询），必须直接给出最终结论，不要为了确认结果再次执行相同命令。",
            "只有缺少关键事实时才提出一条新的、不同的命令；不要重复本轮已经成功执行过的命令。"
        ].joined(separator: "\n")
        _ = await startStreaming(
            userQuestion: continuationQuestion,
            generation: turn.generation,
            turnID: turn.turnID,
            attemptID: turn.attemptID,
            conversationHistory: history
        )
    }

    private func appendToolObservation(_ value: String) {
        toolObservations.append(String(value.prefix(4_096)))
        if toolObservations.count > 16 {
            toolObservations.removeFirst(toolObservations.count - 16)
        }
    }

    private static func isTerminalTraceState(_ state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running,
             .waitingForOutput, .paused:
            return false
        }
    }

    // MARK: - Terminal settlement

    public func stop() async {
        guard accessMode == .interactive else { return }
        await stop(retryCount: 0)
    }

    @discardableResult
    public func cancelExecution(requestID: String) async -> Bool {
        guard accessMode == .interactive,
              requestID == activeExecutionRequestID,
              activeToolDispatch != nil else { return false }
        await stop(retryCount: 0)
        return activeToolDispatch == nil && activeExecutionRequestID == nil
    }

    private func stop(retryCount: Int) async {
        guard restoreInProgress == false,
              sessionBlocked == false else { return }
        guard let turn = activeTurn else {
            guard let durableTurn = latestState.activeTurn,
                  let durableAttempt = latestState.activeAttempt,
                  durableAttempt.phase.isTerminal == false,
                  durableAttempt.phase != .stopping else { return }
            switch await submitBatch(
                [DraftSpec(.interruptRequested, source: "user")],
                turnID: durableTurn.id,
                attemptID: durableAttempt.id
            ) {
            case .committed(let state):
                latestState = state
                publishComposerState()
                renderTimeline()
            case .rejected(let reason):
                if retryCount < 1, Self.isRetryableConcurrentProjectionRejection(reason) {
                    refreshProjectionAfterConcurrentWrite()
                    await stop(retryCount: retryCount + 1)
                    return
                }
                blockAfterSubmissionFailure(reason, context: "从另一个窗口停止运行")
            }
            return
        }
        guard turn.settling == false else { return }
        if latestState.phase == .waitingForCapacity,
           let request = turn.admissionRequest {
            do {
                _ = try await admissionCoordinator.cancel(requestID: request.requestID)
            } catch {
                reportError("无法取消全局执行排队。尚未启动模型请求，请稍后重试停止。")
                return
            }
            await settleAdmissionCancelled(request: request, generation: turn.generation)
            return
        }
        if activeToolDispatch != nil {
            activeToolStopRequested = true
            let cancellationEvidence: AgentTraceEvent?
            if activeToolDispatchHandedOff {
                cancellationEvidence = cancelActiveExecution()
            } else {
                cancellationEvidence = activeExecutionRequestID.map { requestID in
                    AgentTraceEvent(
                        requestID: requestID,
                        state: .cancelled,
                        message: "用户已在终端命令投递前停止本步。",
                        redactedCommand: nil,
                        metadata: ["cancellationBoundary": "beforeExternalDispatch"]
                    )
                }
            }
            if let cancellationEvidence, Self.isTerminalTraceState(cancellationEvidence.state) {
                guard await settleToolForStop(turn: turn, evidence: cancellationEvidence) else {
                    return
                }
            } else {
                await requireActiveToolReconciliation(
                    reason: "停止请求已发送，但终端协调器未返回可验证的终态",
                    freezeTurn: false
                )
                return
            }
        }
        guard let settlingTurn = beginSettlement(generation: turn.generation) else { return }
        runtime?.cancel()
        structuredLocalAgentRuntime?.cancel()
        await settleCancellation(turn: settlingTurn)
    }

    private func settleToolForStop(turn: ActiveTurn, evidence: AgentTraceEvent) async -> Bool {
        guard let dispatch = activeToolDispatch,
              let command = dispatch.command,
              case let .executeTool(_, proposalID) = command
        else { return false }
        let completed = evidence.state == .completed
        let preferredOutcome: ConversationOutboxSettlementOutcome = completed ? .completed : .cancelled
        if activeToolSettlementOutcome == nil {
            activeToolSettlementOutcome = preferredOutcome
        }
        let settlementOutcome = activeToolSettlementOutcome ?? preferredOutcome
        let evidence = Self.sanitizedExecutionTrace(evidence)
        let summary = Self.redactedExecutionText(
            evidence.metadata?["terminalOutputSummary"] ?? evidence.message
        )
        let eventPayload = ToolExecutionEventPayload(
            proposalID: proposalID,
            requestID: evidence.requestID,
            state: evidence.state.rawValue,
            summary: String(summary.prefix(4_096))
        )
        let resolution = ToolProposalResolutionPayload(
            proposalID: proposalID,
            result: completed ? String(summary.prefix(4_096)) : nil,
            error: completed ? nil : String(summary.prefix(4_096))
        )
        switch await submitBatch([
            DraftSpec(
                .toolCompleted,
                payload: EventPayloadCodec.encode(eventPayload) ?? Data(),
                source: "agent-execution"
            ),
            DraftSpec(
                .toolProposalResolved,
                payload: EventPayloadCodec.encode(resolution) ?? Data(),
                source: "agent-execution"
            )
        ], turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await settleClaimedEffect(
                    dispatch,
                    outcome: settlementOutcome,
                    context: "结算停止中的终端工具"
                  ) else { return false }
            clearActiveToolExecutionTracking(for: dispatch)
            return true
        case .rejected(let reason):
            if let proposal = latestState.activeAttempt?.toolProposalQueue.first(where: { $0.id == proposalID }),
               proposal.state == .resolved || proposal.state == .cancelled {
                guard await settleClaimedEffect(
                    dispatch,
                    outcome: settlementOutcome,
                    context: "幂等结算停止中的终端工具"
                ) else { return false }
                clearActiveToolExecutionTracking(for: dispatch)
                return true
            }
            await requireActiveToolReconciliation(
                reason: "终端已返回取消结果，但持久化结果失败：\(reason)",
                freezeTurn: false
            )
            return false
        }
    }

    private func beginCompletion(fullMessage: String, generation: UInt64) {
        guard let turn = beginSettlement(generation: generation) else { return }
        Task { @MainActor [weak self] in
            await self?.settleCompletion(turn: turn, fullMessage: fullMessage)
        }
    }

    private func settleCompletion(turn: ActiveTurn, fullMessage: String) async {
        guard await awaitCheckpointCommitIfNeeded() else { return }
        let canonical = fullMessage.isEmpty ? turn.accumulatedAnswer : fullMessage
        let termination = AttemptTerminationPayload(outcome: .completed, reasonCode: .completed)
        var specs: [DraftSpec] = []
        if let completion = modelInvocationCompletionSpec(
            attemptID: turn.attemptID,
            outcome: "completed"
        ) {
            specs.append(completion)
        }
        specs.append(contentsOf: [
            DraftSpec(.finalAnswerCompleted, payload: Data(canonical.utf8)),
            DraftSpec(.attemptCompleted, payload: EventPayloadCodec.encode(termination) ?? Data())
        ])

        switch await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: turn.attemptID,
                    outcome: .completed,
                    reasonCode: .completed
                ),
                context: "结算已完成会话"
            ) else { return }
            archive(turn: turn, finalAnswer: canonical, status: nil)
            await finishTurn(turn, shouldAutoAdvance: true)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "完成回答")
        }
    }

    private func beginFailure(
        reasonCode: AttemptReasonCode,
        summary: String,
        generation: UInt64
    ) {
        guard let turn = beginSettlement(generation: generation) else { return }
        Task { @MainActor [weak self] in
            await self?.settleFailure(turn: turn, reasonCode: reasonCode, summary: summary)
        }
    }

    private func settleLocalAgentDeliveryFailure(
        turnID: String,
        attemptID: String,
        result: LocalAgentInputSendResult
    ) async {
        let reasonCode: AttemptReasonCode
        let summary: String
        switch result {
        case .accepted:
            return
        case .missingExecutable(let name):
            reasonCode = .runtimeStartFailed
            summary = "找不到 \(name) 本地命令；输入未投递。"
        case .configurationChanged:
            reasonCode = .configurationInvalid
            summary = "Local Agent executable 或验证证据已变化；输入未投递。"
        case .launchBlocked(let reason):
            reasonCode = .runtimeStateUnknown
            summary = reason
        case .workingDirectorySelectionCancelled:
            reasonCode = .cancelled
            summary = "已取消选择 Local Agent 工作目录；输入未投递。"
        case .workingDirectoryUnavailable:
            reasonCode = .configurationInvalid
            summary = "Local Agent 工作目录不可用；输入未投递。"
        case .workingDirectoryChangeRequiresRestart:
            reasonCode = .configurationInvalid
            summary = "Local Agent 已绑定其他工作目录；请停止后重试。"
        case .terminating:
            reasonCode = .cancelled
            summary = "Local Agent 终端正在停止；输入未投递。"
        case .sensitiveInputRequired:
            reasonCode = .sensitiveInputRequired
            summary = "终端正在等待敏感输入；Composer 内容未投递，请直接在终端中输入。"
        case .notRunning:
            reasonCode = .runtimeStartFailed
            summary = "Local Agent 终端未能启动；输入未投递。"
        }
        let termination = AttemptTerminationPayload(outcome: .failed, reasonCode: reasonCode)
        switch await submitBatch([
            DraftSpec(
                .attemptFailed,
                payload: EventPayloadCodec.encode(termination) ?? Data(),
                source: "local-agent-runtime"
            )
        ], turnID: turnID, attemptID: attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: attemptID,
                    outcome: .failed,
                    reasonCode: reasonCode
                ),
                context: "结算 Local Agent 输入未投递"
            ) else { return }
            if let turn = activeTurn, turn.turnID == turnID {
                archive(turn: turn, finalAnswer: "", status: .recovery(summary))
                await finishTurn(turn, shouldAutoAdvance: false)
            }
            reportError(summary)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录 Local Agent 输入未投递")
        }
    }

    private func settleFailure(
        turn: ActiveTurn,
        reasonCode: AttemptReasonCode,
        summary: String
    ) async {
        guard await awaitCheckpointCommitIfNeeded() else { return }
        var specs: [DraftSpec] = []
        if let completion = modelInvocationCompletionSpec(
            attemptID: turn.attemptID,
            outcome: "failed"
        ) {
            specs.append(completion)
        }
        if turn.pendingCheckpoint.isEmpty == false {
            specs.append(DraftSpec(.finalAnswerDelta, payload: Data(turn.pendingCheckpoint.utf8)))
        }
        let termination = AttemptTerminationPayload(outcome: .failed, reasonCode: reasonCode)
        specs.append(DraftSpec(
            .attemptFailed,
            payload: EventPayloadCodec.encode(termination) ?? Data()
        ))
        appendQueuePauseIfNeeded(to: &specs, source: "runtime")

        switch await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: turn.attemptID,
                    outcome: .failed,
                    reasonCode: reasonCode
                ),
                context: "结算失败会话"
            ) else { return }
            archive(
                turn: turn,
                finalAnswer: turn.accumulatedAnswer,
                status: .recovery("失败：\(summary)")
            )
            onRuntimeUnavailable?(summary)
            await finishTurn(turn, shouldAutoAdvance: false)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "记录运行失败")
        }
    }

    private func beginCancellation(generation: UInt64, cancelRuntime: Bool) {
        guard let turn = beginSettlement(generation: generation) else { return }
        cancelPendingStructuredToolCalls(reason: "本轮已停止，工具请求未执行。")
        if cancelRuntime {
            runtime?.cancel()
            structuredLocalAgentRuntime?.cancel()
        }
        Task { @MainActor [weak self] in
            await self?.settleCancellation(turn: turn)
        }
    }

    private func settleCancellation(turn: ActiveTurn) async {
        guard await awaitCheckpointCommitIfNeeded() else { return }
        var specs: [DraftSpec] = []
        if let completion = modelInvocationCompletionSpec(
            attemptID: turn.attemptID,
            outcome: "cancelled"
        ) {
            specs.append(completion)
        }
        if turn.pendingCheckpoint.isEmpty == false {
            specs.append(DraftSpec(.finalAnswerDelta, payload: Data(turn.pendingCheckpoint.utf8)))
        }
        let termination = AttemptTerminationPayload(outcome: .cancelled, reasonCode: .cancelled)
        if latestState.phase != .stopping {
            specs.append(DraftSpec(.interruptRequested))
        }
        specs.append(DraftSpec(
            .attemptCancelled,
            payload: EventPayloadCodec.encode(termination) ?? Data()
        ))
        appendQueuePauseIfNeeded(to: &specs, source: "user")

        switch await submitBatch(specs, turnID: turn.turnID, attemptID: turn.attemptID) {
        case .committed(let state):
            latestState = state
            guard await acknowledgeCommittedEffect(
                .finalizeAttempt(
                    attemptID: turn.attemptID,
                    outcome: .cancelled,
                    reasonCode: .cancelled
                ),
                context: "结算已停止会话"
            ) else { return }
            archive(
                turn: turn,
                finalAnswer: turn.accumulatedAnswer,
                status: .progress("已停止")
            )
            await finishTurn(turn, shouldAutoAdvance: false)
        case .rejected(let reason):
            blockAfterSubmissionFailure(reason, context: "停止运行")
        }
    }

    private func beginSettlement(generation: UInt64) -> ActiveTurn? {
        guard generation == currentGeneration,
              var turn = activeTurn,
              turn.generation == generation,
              turn.settling == false
        else { return nil }
        turn.settling = true
        activeTurn = turn
        admissionWaitTask?.cancel()
        admissionWaitTask = nil
        pauseEffectiveExecutionTimer(generation: generation)
        currentGeneration &+= 1
        cancelApprovalDeadline()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        return turn
    }

    private func appendQueuePauseIfNeeded(to specs: inout [DraftSpec], source: String) {
        let pause = QueueAutoAdvanceChangedPayload(paused: true)
        specs.append(DraftSpec(
            .queueAutoAdvanceChanged,
            payload: EventPayloadCodec.encode(pause) ?? Data(),
            scope: .session,
            source: source
        ))
    }

    private func claimRuntimeOwnership(attemptID: String) -> Bool {
        guard actor.claimRuntimeOwnership(attemptID: attemptID, owner: self) else {
            return false
        }
        ownedRuntimeAttemptID = attemptID
        return true
    }

    private func releaseRuntimeOwnership(attemptID: String) {
        actor.releaseRuntimeOwnership(attemptID: attemptID, owner: self)
        if ownedRuntimeAttemptID == attemptID {
            ownedRuntimeAttemptID = nil
        }
    }

    private func finishTurn(_ turn: ActiveTurn, shouldAutoAdvance: Bool) async {
        guard activeTurn?.turnID == turn.turnID else { return }
        var releaseFailed = false
        if let lease = turn.admissionLease {
            do {
                _ = try await admissionCoordinator.release(lease)
                let payload = AdmissionResolvedPayload(
                    requestID: lease.requestID,
                    leaseID: lease.leaseID,
                    attemptID: lease.attemptID,
                    schedulerGeneration: lease.schedulerGeneration,
                    resolvedAt: Date(),
                    reason: "attemptSettled"
                )
                switch await submitBatch([
                    DraftSpec(
                        .admissionReleased,
                        payload: EventPayloadCodec.encode(payload) ?? Data(),
                        source: "scheduler"
                    )
                ], turnID: turn.turnID, attemptID: turn.attemptID) {
                case .committed(let state):
                    latestState = state
                case .rejected(let reason):
                    blockAfterSubmissionFailure(reason, context: "记录执行容量释放")
                    releaseFailed = true
                }
            } catch {
                sessionBlocked = true
                reportError("执行已结束，但全局容量许可无法安全释放。请重新启动后完成运行状态对账。")
                releaseFailed = true
            }
        } else if let requestID = turn.admissionRequest?.requestID {
            do {
                _ = try await admissionCoordinator.cancel(requestID: requestID)
            } catch {
                sessionBlocked = true
                reportError("执行已结束，但排队请求无法安全取消。请重新启动后完成运行状态对账。")
                releaseFailed = true
            }
        }
        releaseRuntimeOwnership(attemptID: turn.attemptID)
        cancelPendingStructuredToolCalls(reason: "本轮 Local Agent 已结束，工具请求未执行。")
        activeTurn = nil
        runtime = nil
        structuredLocalAgentRuntime = nil
        activeStructuredLocalAgentConfiguration = nil
        admissionWaitTask?.cancel()
        admissionWaitTask = nil
        if pendingLocalAgentDelivery?.generation == turn.generation {
            pendingLocalAgentDelivery = nil
        }
        cancelApprovalDeadline()
        resetEffectiveExecutionTimer()
        activeExecutionRequestID = nil
        activeExecutionProposalID = nil
        activeToolDispatch = nil
        activeToolDispatchHandedOff = false
        activeToolStopRequested = false
        activeToolSettlementOutcome = nil
        scheduledToolStartProposalID = nil
        scheduledToolResumeProposalID = nil
        currentRuntimeContext = nil
        lastUserFacingError = nil
        // The completed turn owns the execution mode that was committed with
        // its snapshot. Composer changes made while it was running belong to
        // the next turn and must not rewrite the finished turn's mode sink.
        executionModeSnapshotHandler?(turn.executionChoice)
        proposalPayloads.removeAll()
        traceEventsByProposalID.removeAll()
        terminalTraceRequestIDs.removeAll()
        toolObservations.removeAll()
        lastToolResponseMessage = nil
        toolRound = 0
        completedToolCommandDigests.removeAll()
        publishComposerState()
        publishToolDecision()
        onTargetUpdate?(currentTargetIdentity)
        renderTimeline()
        guard shouldAutoAdvance, releaseFailed == false, sessionBlocked == false else { return }
        Task { @MainActor [weak self] in
            await self?.promoteQueueIfIdle()
        }
    }

    private func cancelPendingStructuredToolCalls(reason: String) {
        let calls = Array(structuredToolCallsByProposalID.values)
        structuredToolCallsByProposalID.removeAll()
        for call in calls {
            respondToStructuredToolCall(call, success: false, text: reason)
        }
    }

    private func archive(
        turn: ActiveTurn,
        finalAnswer: String,
        status: ArchivedTurnStatus?
    ) {
        archivedTurns.append(ArchivedTurn(
            turnID: turn.turnID,
            attemptID: turn.attemptID,
            userRequest: turn.userRequest,
            finalAnswer: finalAnswer,
            status: status,
            toolEntries: latestState.activeAttempt.map { toolTimelineEntries(for: $0) } ?? []
        ))
    }

    private func promoteQueueIfIdle() async {
        guard acceptsNewSubmissions,
              submissionGateAllowsNewTurns(),
              queuePromotionInputID == nil,
              activeTurn == nil,
              hasDurableActiveTurn == false,
              sessionBlocked == false,
              queueAutoAdvancePaused == false,
              let next = latestState.session.queuedInputs.sorted(by: { $0.position < $1.position }).first,
              QueuedInputRevalidator.promotionGate(for: next) == .valid
        else { return }
        queuePromotionInputID = next.id
        defer {
            if queuePromotionInputID == next.id {
                queuePromotionInputID = nil
            }
        }
        _ = await beginTurn(userRequest: next.text, consuming: next)
    }

    private var submissionsBlockedByStop: Bool {
        latestState.phase == .stopping
            || activeTurn?.settling == true
            || activeToolStopRequested
    }

    // MARK: - Durable effect dispatch

    private func claimCommittedEffect(
        _ command: EffectCommand,
        context: String
    ) async -> ConversationOutboxDispatchRecord? {
        let effectID = ConversationEffectOutboxFactory.stableEffectID(for: command)
        let dispatchToken = "dispatch-\(UUID().uuidString)"
        do {
            guard let record = try await actor.claimOutboxEffect(
                effectID: effectID,
                dispatchToken: dispatchToken,
                dispatchedAt: Self.outboxTimestamp()
            ) else {
                let unresolved = try await actor.loadUnsettledOutbox().first {
                    $0.effectID == effectID
                }
                if let unresolved,
                   unresolved.state == .dispatching || unresolved.state == .reconciliationRequired {
                    _ = try? await actor.requireOutboxReconciliation(
                        itemID: unresolved.itemID,
                        reason: "duplicate or unknown dispatch observed while \(context)"
                    )
                }
                blockForOutboxFailure("Effect 无法取得唯一执行权（\(context)）")
                return nil
            }
            guard record.command == command else {
                _ = try? await actor.requireOutboxReconciliation(
                    itemID: record.itemID,
                    reason: "durable command payload does not match expected effect"
                )
                blockForOutboxFailure("Effect 持久化内容不一致（\(context)）")
                return nil
            }
            return record
        } catch {
            blockForOutboxFailure("Effect claim 失败（\(context)）：\(error.localizedDescription)")
            return nil
        }
    }

    private func acknowledgeCommittedEffect(
        _ command: EffectCommand,
        context: String
    ) async -> Bool {
        guard let dispatch = await claimCommittedEffect(command, context: context) else {
            return false
        }
        return await settleClaimedEffect(
            dispatch,
            outcome: .acknowledged,
            context: context
        )
    }

    private func settleClaimedEffect(
        _ dispatch: ConversationOutboxDispatchRecord,
        outcome: ConversationOutboxSettlementOutcome,
        context: String
    ) async -> Bool {
        guard let token = dispatch.dispatchToken else {
            blockForOutboxFailure("Effect 缺少 dispatch token（\(context)）")
            return false
        }
        do {
            let settled = try await actor.settleOutbox(
                itemID: dispatch.itemID,
                dispatchToken: token,
                outcome: outcome,
                settledAt: Self.outboxTimestamp()
            )
            guard settled else {
                blockForOutboxFailure("Effect 结算被拒绝（\(context)）")
                return false
            }
            return true
        } catch {
            blockForOutboxFailure("Effect 结算失败（\(context)）：\(error.localizedDescription)")
            return false
        }
    }

    private func clearActiveToolExecutionTracking(
        for dispatch: ConversationOutboxDispatchRecord? = nil
    ) {
        if let dispatch, activeToolDispatch?.itemID != dispatch.itemID {
            return
        }
        activeToolDispatch = nil
        activeToolDispatchHandedOff = false
        activeToolStopRequested = false
        activeToolSettlementOutcome = nil
        activeExecutionRequestID = nil
        activeExecutionProposalID = nil
    }

    private func requireActiveToolReconciliation(
        reason: String,
        freezeTurn: Bool = true
    ) async {
        pauseEffectiveExecutionTimer()
        if let dispatch = activeToolDispatch {
            _ = try? await actor.requireOutboxReconciliation(
                itemID: dispatch.itemID,
                reason: reason
            )
        }
        activeExecutionRequestID = nil
        activeExecutionProposalID = nil
        sessionBlocked = true
        if freezeTurn, var turn = activeTurn {
            turn.settling = true
            activeTurn = turn
        }
        reportError("工具执行结果未知，已停止自动操作并等待对账。\(reason)")
    }

    private func blockForOutboxFailure(_ summary: String) {
        sessionBlocked = true
        pauseEffectiveExecutionTimer()
        cancelPendingStructuredToolCalls(reason: "会话无法可靠保存工具结果，工具请求未执行。")
        runtime?.cancel()
        runtime = nil
        structuredLocalAgentRuntime?.cancel()
        structuredLocalAgentRuntime = nil
        activeStructuredLocalAgentConfiguration = nil
        reportError(summary)
    }

    private static func outboxTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Submission helpers

    /// MainActor methods can interleave while awaiting the session Actor. Event batches must therefore
    /// be built only when they reach this FIFO, after every earlier commit has refreshed `latestState`.
    private func withSerializedSubmission<Result>(
        _ operation: @escaping () async -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            pendingSubmissionOperations.append {
                let result = await operation()
                continuation.resume(returning: result)
            }
            guard isDrainingSubmissionOperations == false else { return }
            isDrainingSubmissionOperations = true
            Task { @MainActor [self] in
                await drainSubmissionOperations()
            }
        }
    }

    private func drainSubmissionOperations() async {
        while pendingSubmissionOperations.isEmpty == false {
            let operation = pendingSubmissionOperations.removeFirst()
            await operation()
        }
        isDrainingSubmissionOperations = false
    }

    private func submitBatch(
        _ specs: [DraftSpec],
        turnID: String? = nil,
        attemptID: String? = nil
    ) async -> ConversationSessionActor.SubmitOutcome {
        await submitBatch {
            SubmissionBatch(specs: specs, turnID: turnID, attemptID: attemptID)
        }
    }

    private func submitBatch(
        _ build: @escaping () -> SubmissionBatch
    ) async -> ConversationSessionActor.SubmitOutcome {
        await withSerializedSubmission { [self] in
            let batch = build()
            let outcome = await actor.submit(
                makeDrafts(batch.specs, turnID: batch.turnID, attemptID: batch.attemptID)
            )
            if case .committed(let state) = outcome {
                latestState = state
            }
            return outcome
        }
    }

    private func submitOptionalBatch(
        _ build: @escaping () -> SubmissionBatch?
    ) async -> ConversationSessionActor.SubmitOutcome? {
        await withSerializedSubmission { [self] in
            guard let batch = build() else { return nil }
            let outcome = await actor.submit(
                makeDrafts(batch.specs, turnID: batch.turnID, attemptID: batch.attemptID)
            )
            if case .committed(let state) = outcome {
                latestState = state
            }
            return outcome
        }
    }

    private func makeDrafts(
        _ specs: [DraftSpec],
        turnID: String? = nil,
        attemptID: String? = nil
    ) -> [EventDraft] {
        var effectiveSpecs = specs
        if persistsSessionCreationEvent,
           latestState.lastAppliedSequence == 0,
           specs.first?.kind != .sessionCreated {
            let payload = EventPayloadCodec.encode(
                ConversationSessionCreatedPayload(session: latestState.session)
            ) ?? Data()
            effectiveSpecs.insert(
                DraftSpec(.sessionCreated, payload: payload, scope: .session, source: "system"),
                at: 0
            )
        }
        var expected = latestState.lastAppliedSequence
        return effectiveSpecs.map { spec in
            let sequence = expected + 1
            let envelope = ConversationEventEnvelope(
                eventID: "ev-\(sessionID)-\(sequence)-\(UUID().uuidString)",
                conversationID: sessionID,
                scope: spec.scope,
                turnID: spec.scope == .session ? nil : turnID,
                attemptID: spec.scope == .session ? nil : attemptID,
                candidateSequence: sequence,
                source: spec.source,
                timestamp: Date(),
                kind: spec.kind,
                writeClass: writeClass(for: spec.kind),
                payloadHash: Self.payloadHash(
                    kind: spec.kind,
                    sequence: sequence,
                    payload: spec.payload
                ),
                payload: spec.payload
            )
            defer { expected = sequence }
            return EventDraft(envelope: envelope, expectedLastSequence: expected)
        }
    }

    private func writeClass(for kind: ConversationEventKind) -> ConversationEventWriteClass {
        switch kind {
        case .finalAnswerDelta, .reasoningSummaryUpdated:
            return .checkpoint
        default:
            return .durable
        }
    }

    private static func payloadHash(
        kind: ConversationEventKind,
        sequence: Int,
        payload: Data
    ) -> String {
        var hash: UInt64 = 5381
        for byte in "\(kind.rawValue)|\(sequence)|".utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        for byte in payload {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func toolCommandDigest(_ command: String) -> String {
        stableDigest(command.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func redactedExecutionText(_ value: String) -> String {
        AgentProtocolRedaction.redactPreservingLineBreaks(value)
    }

    private static func riskDisplayTitle(_ value: String) -> String {
        switch value {
        case AgentActionRisk.readOnly.rawValue: return "只读"
        case AgentActionRisk.write.rawValue: return "写入"
        case AgentActionRisk.network.rawValue: return "网络操作"
        case AgentActionRisk.destructive.rawValue: return "破坏性操作"
        default: return "需确认"
        }
    }

    private static func sanitizedExecutionTrace(_ event: AgentTraceEvent) -> AgentTraceEvent {
        var metadata = event.metadata
        if let output = metadata?["terminalOutputSummary"] {
            metadata?["terminalOutputSummary"] = redactedExecutionText(output)
        }
        if let historyOutput = metadata?["terminalHistoryOutput"] {
            metadata?["terminalHistoryOutput"] = redactedExecutionText(historyOutput)
        }
        return AgentTraceEvent(
            requestID: event.requestID,
            state: event.state,
            message: redactedExecutionText(event.message),
            redactedCommand: event.redactedCommand.map(redactedExecutionText),
            metadata: metadata
        )
    }

    private static func sha256Digest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func abortRuntimeForPersistenceFailure(
        _ reason: ConversationSessionActor.SubmitRejection,
        context: String
    ) {
        markActiveToolForReconciliation(reason: "会话持久化失败，终端执行结果无法可靠结算")
        pauseEffectiveExecutionTimer()
        cancelActiveExecution()
        cancelPendingStructuredToolCalls(reason: "会话状态保存失败，工具请求未执行。")
        runtime?.cancel()
        structuredLocalAgentRuntime?.cancel()
        currentGeneration &+= 1
        flushWorkItem?.cancel()
        flushWorkItem = nil
        blockAfterSubmissionFailure(reason, context: context)
    }

    private func blockAfterSubmissionFailure(
        _ reason: ConversationSessionActor.SubmitRejection,
        context: String
    ) {
        sessionBlocked = true
        markActiveToolForReconciliation(reason: "会话状态提交失败，终端执行结果需要对账")
        cancelActiveExecution()
        cancelPendingStructuredToolCalls(reason: "会话状态保存失败，工具请求未执行。")
        runtime?.cancel()
        runtime = nil
        structuredLocalAgentRuntime?.cancel()
        structuredLocalAgentRuntime = nil
        activeStructuredLocalAgentConfiguration = nil
        if let attemptID = ownedRuntimeAttemptID {
            releaseRuntimeOwnership(attemptID: attemptID)
        }
        activeTurn = nil
        let summary: String
        switch reason {
        case .sealingFailed:
            summary = "加密验证失败（\(context)）"
        case .sequenceGap:
            summary = "会话事件序列不连续（\(context)）"
        case .invalidTransition(let reason):
            summary = "会话状态不一致（\(context)）：\(reason)"
        case .storageFailure:
            summary = "会话存储失败（\(context)）"
        case .conflict:
            summary = "会话被另一个窗口更新，需要重新加载（\(context)）"
        }
        reportError(summary)
    }

    @discardableResult
    private func refreshFromActorAfterConcurrentWrite() -> Bool {
        guard let refreshed = actor.latestPublishedState,
              refreshed.lastAppliedSequence > latestState.lastAppliedSequence else {
            return false
        }
        cancelPendingStructuredToolCalls(reason: "会话已被另一个窗口更新，工具请求未执行。")
        runtime?.cancel()
        runtime = nil
        structuredLocalAgentRuntime?.cancel()
        structuredLocalAgentRuntime = nil
        activeStructuredLocalAgentConfiguration = nil
        currentGeneration &+= 1
        if let attemptID = ownedRuntimeAttemptID {
            releaseRuntimeOwnership(attemptID: attemptID)
        }
        activeTurn = nil
        latestState = refreshed
        turnOrdinal = max(turnOrdinal, refreshed.activeTurn?.ordinal ?? 0)
        publishComposerState()
        publishToolDecision()
        onTargetUpdate?(currentTargetIdentity)
        onSessionMetadataUpdate?(refreshed.session)
        renderTimeline()
        return true
    }

    /// Queue/draft mutations may legitimately race a streaming checkpoint. They
    /// need the newer durable projection, but must preserve the owner bridge's
    /// active Runtime and generation.
    @discardableResult
    private func refreshProjectionAfterConcurrentWrite() -> Bool {
        guard let refreshed = actor.latestPublishedState,
              refreshed.lastAppliedSequence > latestState.lastAppliedSequence else {
            return false
        }
        // Apply the same transition side effects as the async Actor observer.
        // The observer callback is dispatched to the MainActor and can arrive
        // after this refresh; assigning `latestState` and publishing manually
        // here would make that callback look stale and skip important actions
        // such as resuming the owner Runtime after another window resolves an
        // approval.
        handleStateChange(refreshed, allowEqualSequence: true)
        return true
    }

    nonisolated private static func isConcurrentTurnSubmissionRejection(
        _ reason: ConversationSessionActor.SubmitRejection
    ) -> Bool {
        switch reason {
        case .sequenceGap, .conflict:
            return true
        case .invalidTransition(let detail):
            return detail.contains("active turn already running")
        case .sealingFailed, .storageFailure:
            return false
        }
    }

    nonisolated private static func isRetryableConcurrentProjectionRejection(
        _ reason: ConversationSessionActor.SubmitRejection
    ) -> Bool {
        switch reason {
        case .sequenceGap, .conflict:
            return true
        case .invalidTransition, .sealingFailed, .storageFailure:
            return false
        }
    }

    @discardableResult
    private func cancelActiveExecution() -> AgentTraceEvent? {
        guard let requestID = activeExecutionRequestID else { return nil }
        let event = (executionCoordinator as? AgentTaskControlling)?
            .cancelTask(requestID: requestID)
            .map(Self.sanitizedExecutionTrace)
        if let event,
           let proposalID = activeExecutionProposalID,
           traceEventsByProposalID[proposalID]?.contains(event) != true {
            traceEventsByProposalID[proposalID, default: []].append(event)
        }
        activeExecutionRequestID = nil
        activeExecutionProposalID = nil
        return event
    }

    private func markActiveToolForReconciliation(reason: String) {
        guard let dispatch = activeToolDispatch else { return }
        Task { [actor] in
            _ = try? await actor.requireOutboxReconciliation(
                itemID: dispatch.itemID,
                reason: reason
            )
        }
    }

    private func reportError(_ summary: String) {
        lastUserFacingError = summary
        onRuntimeUnavailable?(summary)
        renderTimeline()
    }

    // MARK: - Timeline projection

    private func handleStateChange(
        _ state: ConversationSessionState,
        allowEqualSequence: Bool = false
    ) {
        // Every meaningful projection change advances the authenticated event
        // sequence. Ignore equal-sequence callbacks (which can be queued
        // before a restore) so a stale observer cannot roll back or retrigger
        // an effect after recovery.
        let sequenceAdvanced = state.lastAppliedSequence > latestState.lastAppliedSequence
        let isExplicitConcurrentRefresh = allowEqualSequence
            && state.lastAppliedSequence == latestState.lastAppliedSequence
        guard sequenceAdvanced || isExplicitConcurrentRefresh else { return }
        let previousState = latestState
        latestState = state
        turnOrdinal = max(turnOrdinal, state.activeTurn?.ordinal ?? 0)
        if let turn = activeTurn,
           turn.settling == false,
           state.activeAttempt?.id == turn.attemptID {
            if state.phase == .stopping {
                beginCancellation(generation: turn.generation, cancelRuntime: true)
            } else if state.phase == .executingTool,
                      let proposalID = state.activeAttempt?.activeToolProposalID {
                scheduleApprovedToolExecution(proposalID: proposalID)
            } else if previousState.phase == .awaitingApproval,
                      state.phase == .streaming,
                      let proposalID = previousState.activeAttempt?.activeToolProposalID {
                let decisionID = previousState.activeAttempt?.toolProposalQueue
                    .first(where: { $0.id == proposalID })?.decisionID
                if decisionID.flatMap({ state.decisions[$0]?.state }) == .expired {
                    appendToolObservation("工具建议 \(proposalID) 的审批已过期，未执行任何命令。")
                } else {
                    appendToolObservation("工具建议 \(proposalID) 已由用户拒绝，未执行任何命令。")
                }
                if let structuredCall = structuredToolCallsByProposalID.removeValue(forKey: proposalID) {
                    respondToStructuredToolCall(
                        structuredCall,
                        success: false,
                        text: "该工具审批已结束，未执行任何操作。"
                    )
                } else if structuredLocalAgentRuntime == nil {
                    scheduleProviderResume(after: proposalID)
                }
            } else if state.phase.isTerminal {
                cancelPendingStructuredToolCalls(reason: "本轮 Local Agent 已结束，工具请求未执行。")
                runtime?.cancel()
                runtime = nil
                structuredLocalAgentRuntime?.cancel()
                structuredLocalAgentRuntime = nil
                activeStructuredLocalAgentConfiguration = nil
                resetEffectiveExecutionTimer()
                currentGeneration &+= 1
                releaseRuntimeOwnership(attemptID: turn.attemptID)
                activeTurn = nil
            }
        }
        if state.phase == .awaitingApproval {
            scheduleApprovalDeadlineIfNeeded()
        } else {
            cancelApprovalDeadline()
        }
        publishComposerState()
        if previousState.session.runtimeSelection != state.session.runtimeSelection {
            selectedWorkMode = Self.turnWorkMode(for: state.session.runtimeSelection.workMode)
            onRuntimeSelectionUpdate?(state.session.runtimeSelection)
            onSelectionUpdate?(selectedWorkMode, selectedExecutionChoice)
        }
        publishToolDecision()
        onTargetUpdate?(currentTargetIdentity)
        if previousState.session.title != state.session.title
            || previousState.session.isPinned != state.session.isPinned
            || previousState.session.archivedAt != state.session.archivedAt {
            onSessionMetadataUpdate?(state.session)
        }
        renderTimeline()
    }

    private var composerRunPhase: ComposerRunPhase {
        guard activeTurn != nil || hasDurableActiveTurn else { return .idle }
        switch latestState.phase {
        case .preparing: return .preparing
        case .waitingForCapacity: return .waitingForCapacity
        case .startingRuntime: return .startingRuntime
        case .streaming: return .streaming
        case .toolProposed: return .toolProposed
        case .awaitingApproval: return .awaitingApproval
        case .executingTool: return .executingTool
        case .awaitingUser: return .awaitingUser
        case .pausing: return .pausing
        case .paused: return .paused
        case .takeoverPending: return .takeoverPending
        case .stopping: return .stopping
        case .takenOver: return .takenOver
        case .completed, .failed, .cancelled, .interruptedByRelaunch,
             .passthroughInputDelivered: return .idle
        }
    }

    private func publishComposerState(forceQueueRefresh: Bool = false) {
        let queue = latestState.session.queuedInputs.sorted { $0.position < $1.position }
        onQueueUpdate?(queue, queueAutoAdvancePaused, forceQueueRefresh)
        onRunPhaseUpdate?(composerRunPhase)
    }

    private func publishToolDecision() {
        onToolDecisionUpdate?(makePendingToolDecision())
    }

    private func makePendingToolDecision() -> PendingToolDecisionPresentation? {
        guard accessMode == .interactive else { return nil }
        guard let attempt = latestState.activeAttempt,
              attempt.phase == .awaitingApproval || attempt.phase == .interruptedByRelaunch,
              let proposalID = attempt.activeToolProposalID,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == proposalID }),
              proposal.state == .awaitingApproval,
              let decisionID = proposal.decisionID,
              let decision = latestState.decisions[decisionID],
              decision.state == .pending
        else { return nil }
        let payload = proposalPayloads[proposalID]
        let batch = attempt.toolProposalQueue.filter { $0.batchID == proposal.batchID }
        let index = (batch.firstIndex(where: { $0.id == proposalID }) ?? 0) + 1
        let targetBinding = attempt.targetBindingSnapshot
            ?? activeTurn?.targetBinding
            ?? latestState.session.targetBinding
        let executionChoice = activeTurn?.executionChoice
            ?? Self.turnExecutionChoice(for: attempt.terminalModeSnapshot)
        let protectionMessage: String?
        if storageError != nil || sessionBlocked {
            protectionMessage = "会话已进入只读保护，不能批准或执行命令。请重新打开会话完成恢复或对账。"
        } else if attempt.phase == .interruptedByRelaunch {
            protectionMessage = "App 重启后该审批已失效。请基于当前连接重新生成建议。"
        } else {
            protectionMessage = nil
        }
        let isActionable = attempt.phase == .awaitingApproval
            && protectionMessage == nil
        let command = payload?.command ?? proposal.immutableOperation
        let executionDestination: String
        switch executionChoice {
        case .backgroundVirtualTerminal:
            executionDestination = "后台虚拟终端"
        case .realTerminal:
            executionDestination = "真实终端"
        case .ask:
            executionDestination = "未选择执行终端"
        }
        let summaryToolID = payload?.toolID ?? "<unverified-tool>"
        let summarySchemaRevision = payload.map { String($0.schemaRevision) }
            ?? "<unverified-schema>"
        let immutableSummary = Self.sha256Digest([
            proposalID,
            summaryToolID,
            summarySchemaRevision,
            command,
            targetBinding.digest,
            targetBinding.targetWorkingDirectory,
            payload?.targetRuntimeGeneration.map(String.init) ?? "<unverified-generation>",
            executionChoice.rawValue
        ])
        return PendingToolDecisionPresentation(
            proposalID: proposalID,
            decisionID: decisionID,
            command: command,
            explanation: payload?.explanation ?? "AI 建议执行此命令。",
            risk: payload?.risk ?? AgentActionClassifier.risk(forCommand: proposal.immutableOperation).rawValue,
            targetTitle: payload?.targetTitle ?? latestState.session.targetBinding.remoteIdentity,
            targetWorkingDirectory: targetBinding.targetWorkingDirectory,
            executionDestination: executionDestination,
            targetBindingDigest: targetBinding.digest,
            targetRuntimeGeneration: payload?.targetRuntimeGeneration,
            immutableSummary: immutableSummary,
            deadline: decision.deadline,
            index: index,
            total: max(1, batch.count),
            isActionable: isActionable,
            statusMessage: protectionMessage
        )
    }

    private func toolTimelineEntries(for attempt: TurnAttempt) -> [TimelineSourceEntry] {
        toolTimelineEntries(
            for: attempt,
            proposalPayloads: proposalPayloads,
            traceEventsByProposalID: traceEventsByProposalID,
            targetIdentity: currentTargetIdentity
        )
    }

    private func toolTimelineEntries(
        for attempt: TurnAttempt,
        proposalPayloads: [String: ConversationToolProposalPayload],
        traceEventsByProposalID: [String: [AgentTraceEvent]],
        targetIdentity: String
    ) -> [TimelineSourceEntry] {
        var entries: [TimelineSourceEntry] = []
        for proposal in attempt.toolProposalQueue.sorted(by: { $0.arbitrationOrdinal < $1.arbitrationOrdinal }) {
            let payload = proposalPayloads[proposal.id]
            let command = payload?.command ?? proposal.immutableOperation
            let explanation = payload?.explanation ?? ""
            let risk = payload?.risk ?? AgentActionClassifier.risk(forCommand: command).rawValue
            let status: String
            switch proposal.state {
            case .queued: status = "排队"
            case .evaluating: status = "评估中"
            case .awaitingApproval:
                status = attempt.phase == .interruptedByRelaunch ? "重启后已失效" : "等待批准"
            case .executing: status = "执行中"
            case .resolved: status = proposal.error == nil ? "已完成" : "未完成"
            case .cancelled: status = "未执行"
            }
            let traces = traceEventsByProposalID[proposal.id] ?? []
            let latestTrace = traces.last
            let redactedCommand = Self.redactedExecutionText(
                latestTrace?.redactedCommand ?? command
            )
            let executionMode = latestTrace?.metadata?["executionMode"]
            let isRealTerminal: Bool
            switch executionMode {
            case "visibleTerminal":
                isRealTerminal = true
            case "backgroundTask":
                isRealTerminal = false
            default:
                // Historical events did not persist trace metadata. The frozen
                // Turn snapshot can label the destination, but cannot authorize
                // reopening a potentially reused runtime ID.
                isRealTerminal = attempt.terminalModeSnapshot
                    == TurnExecutionChoice.realTerminal.rawValue
            }
            let terminalSummary = traces.reversed().compactMap { trace in
                trace.metadata?["terminalOutputSummary"]
            }.first
            let hasExecutionEvidence = traces.isEmpty == false
                || proposal.state == .executing
                || proposal.state == .resolved
            if hasExecutionEvidence {
                let traceState = latestTrace?.state
                let isTerminal = traceState.map(Self.isTerminalTraceState) ?? false
                let completionBasis = latestTrace?.metadata?["completionReason"]
                    ?? latestTrace?.metadata?["completionConfidence"]
                    ?? (isTerminal ? traceState?.rawValue : nil)
                    ?? ""
                let runtimeID = latestTrace?.metadata?["sourceRuntimeID"]
                    ?? payload?.targetRuntimeID
                let liveTail = [terminalSummary, latestTrace?.message]
                    .compactMap { $0 }
                    .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                    ?? (proposal.state == .resolved ? "命令已完成，但终端没有返回文本输出。" : nil)
                let redactedLog = traces.map { trace in
                    let line = trace.metadata?["terminalOutputSummary"] ?? trace.message
                    return "[\(trace.state.rawValue)] \(AgentProtocolRedaction.redactPreservingLineBreaks(line))"
                }.joined(separator: "\n")
                let artifact = TerminalArtifactPresentation(
                    requestID: latestTrace?.requestID,
                    runtimeID: runtimeID,
                    liveTail: liveTail.map(AgentProtocolRedaction.redactPreservingLineBreaks),
                    exitCode: latestTrace?.metadata?["exitCode"].flatMap(Int.init),
                    durationSeconds: latestTrace?.metadata?["durationSeconds"].flatMap(Int.init),
                    completionBasis: completionBasis,
                    hasTerminalState: isTerminal,
                    stateLabel: status,
                    isRealTerminal: isRealTerminal,
                    canOpenTerminal: executionMode == "visibleTerminal" && runtimeID != nil,
                    canCancel: accessMode == .interactive
                        && sessionBlocked == false
                        && proposal.state == .executing
                        && latestTrace?.requestID == activeExecutionRequestID
                        && activeToolDispatch != nil,
                    canSaveRedactedLog: redactedLog.isEmpty == false,
                    redactedLog: redactedLog
                )
                entries.append(.executionCard(ExecutionCardPresentation(
                    proposalID: proposal.id,
                    target: payload?.targetTitle ?? targetIdentity,
                    targetRuntimeID: runtimeID,
                    workingDirectory: attempt.targetBindingSnapshot?.targetWorkingDirectory ?? "未验证",
                    redactedCommand: redactedCommand,
                    riskAndApproval: "风险：\(Self.riskDisplayTitle(risk)) · 已批准",
                    isRealTerminal: isRealTerminal,
                    exitCode: artifact.exitCode,
                    durationSeconds: artifact.durationSeconds,
                    completionBasis: completionBasis,
                    status: status,
                    terminalArtifact: artifact,
                    holdsTransferableHandle: executionMode == "visibleTerminal"
                        && latestTrace?.requestID == activeExecutionRequestID
                        && (latestTrace?.state == .running
                            || latestTrace?.state == .waitingForOutput)
                )))
                continue
            }

            var summary = "\(redactedCommand)\n风险：\(risk) · \(status)"
            if explanation.isEmpty == false {
                summary += "\n\(explanation)"
            }
            // While approval is pending, the interactive DecisionCard is the
            // single representation of this proposal. Once it resolves, the
            // timeline replaces the card with the durable tool/result row.
            if proposal.state != .awaitingApproval {
                entries.append(.toolCall(summary, result: proposal.result ?? proposal.error))
            }
        }
        return entries
    }

    private func renderTimeline() {
        guard let onTimelineUpdate else { return }
        var entries: [TimelineSourceEntry] = []
        for archived in archivedTurns {
            entries.append(.userMessage(archived.userRequest))
            entries.append(contentsOf: archived.toolEntries)
            if archived.finalAnswer.isEmpty == false {
                entries.append(.finalAnswer(archived.finalAnswer))
            }
            if let status = archived.status {
                switch status {
                case .progress(let message):
                    entries.append(.planProgress(message))
                case .recovery(let message):
                    entries.append(.errorRecovery(message))
                }
            }
        }

        if accessMode == .readOnlyHistory,
           let turn = latestState.activeTurn,
           let attempt = latestState.activeAttempt,
           attempt.phase.isTerminal == false {
            entries.append(.userMessage(turn.userRequest))
            if let reasoning = attempt.reasoningSummary, reasoning.isEmpty == false {
                entries.append(.reasoningSummary(reasoning))
            }
            entries.append(contentsOf: toolTimelineEntries(for: attempt))
            if let answer = attempt.partialAnswer, answer.isEmpty == false {
                entries.append(.finalAnswer(answer))
            }
            entries.append(.planProgress(
                "未完成的 V2 任务 · \(readOnlyPhaseLabel(attempt.phase))"
            ))
        }

        if let activeTurn {
            entries.append(.userMessage(activeTurn.userRequest))
            if let reasoning = latestState.activeAttempt?.reasoningSummary,
               reasoning.isEmpty == false {
                entries.append(.reasoningSummary(reasoning))
            }
            if let attempt = latestState.activeAttempt {
                entries.append(contentsOf: toolTimelineEntries(for: attempt))
            }
            if activeTurn.accumulatedAnswer.isEmpty == false {
                entries.append(.finalAnswer(activeTurn.accumulatedAnswer))
            }
            let phase = latestState.phase
            if activeTurn.settling {
                entries.append(.planProgress("正在保存状态…"))
            } else if phase == .streaming || phase == .startingRuntime {
                entries.append(.planProgress("执行中…"))
            }
        }
        if latestState.session.queuedInputs.isEmpty == false {
            entries.append(.planProgress("待发送 \(latestState.session.queuedInputs.count) 条"))
        }
        if restoreInProgress {
            entries.append(.planProgress("正在恢复会话…"))
        }
        if let lastUserFacingError {
            entries.append(.errorRecovery(lastUserFacingError))
        }
        if accessMode == .readOnlyHistory,
           restoreInProgress == false,
           entries.isEmpty {
            entries.append(.planProgress("暂无 V2 会话记录"))
        }
        onTimelineUpdate(entries)
    }

    private func readOnlyPhaseLabel(_ phase: AttemptPhase) -> String {
        switch phase {
        case .preparing: return "准备中"
        case .waitingForCapacity: return "等待容量"
        case .startingRuntime: return "正在启动 Runtime"
        case .streaming: return "执行中"
        case .toolProposed: return "正在整理工具建议"
        case .awaitingApproval: return "等待批准"
        case .executingTool: return "执行工具中"
        case .awaitingUser: return "等待输入"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .takeoverPending: return "等待接管"
        case .stopping: return "正在停止"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        case .interruptedByRelaunch: return "已中断"
        case .takenOver: return "已转交"
        case .passthroughInputDelivered: return "输入已投递到 Local Agent 终端"
        }
    }

    private func archivedStatus(for attempt: TurnAttempt) -> ArchivedTurnStatus? {
        switch attempt.phase {
        case .failed:
            return .recovery("失败：\(attempt.error ?? AttemptReasonCode.runtimeStateUnknown.rawValue)")
        case .cancelled:
            return .progress("已停止")
        case .interruptedByRelaunch:
            return .recovery("上次运行因 App 重新启动而中断")
        case .takenOver:
            return .progress("已转交")
        case .passthroughInputDelivered:
            return .progress("输入已发送到 Local Agent 终端；任务状态请查看终端块。")
        default:
            return nil
        }
    }
}
