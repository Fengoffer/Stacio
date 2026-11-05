import Foundation

// MARK: - 纯会话状态（C2-3；规格 §8.1/§11）

/// Reducer 操作与 Actor 发布的不可变会话状态投影。
/// 不持有任何 I/O 句柄；时间戳一律由事件携带，reducer 不读取时钟。
public struct ConversationSessionState: Equatable, Sendable {
    public var session: ConversationSession
    public var activeTurn: ConversationTurn?
    /// 会话内已创建的 Decision（值对象；持久化由 V2 Repository 负责）
    public var decisions: [String: Decision]
    /// 已应用的最后 durable sequence
    public var lastAppliedSequence: Int

    public init(
        session: ConversationSession,
        activeTurn: ConversationTurn? = nil,
        decisions: [String: Decision] = [:],
        lastAppliedSequence: Int = 0
    ) {
        self.session = session
        self.activeTurn = activeTurn
        self.decisions = decisions
        self.lastAppliedSequence = lastAppliedSequence
    }

    public var activeAttempt: TurnAttempt? {
        guard let turn = activeTurn, let attemptID = turn.activeAttemptID else { return nil }
        return turn.attempts.first { $0.id == attemptID }
    }

    public var phase: AttemptPhase {
        activeAttempt?.phase ?? .preparing
    }

    public var workMode: WorkMode {
        activeAttempt?.workModeSnapshot ?? session.runtimeSelection.workMode
    }
}

// MARK: - 无效转换记录

public struct InvalidTransitionRecord: Equatable, Sendable {
    public var fromPhase: AttemptPhase?
    public var eventKind: ConversationEventKind
    public var reason: String

    public init(fromPhase: AttemptPhase?, eventKind: ConversationEventKind, reason: String) {
        self.fromPhase = fromPhase
        self.eventKind = eventKind
        self.reason = reason
    }
}

// MARK: - TentativeState

/// Reducer 的预演结果：新状态 + 无效转换记录。
/// 任何 `invalidTransitions` 非空都意味着该批次不应提交（Actor 必须丢弃整批预演）。
public struct TentativeState: Equatable, Sendable {
    public var state: ConversationSessionState
    public var invalidTransitions: [InvalidTransitionRecord]

    public init(state: ConversationSessionState, invalidTransitions: [InvalidTransitionRecord] = []) {
        self.state = state
        self.invalidTransitions = invalidTransitions
    }

    public var isValid: Bool { invalidTransitions.isEmpty }
}

// MARK: - 事件 payload 值类型（C2-3；durable 事件的少量结构化负载）

public struct AttemptTerminationPayload: Codable, Equatable, Sendable {
    public var outcome: AttemptOutcome
    public var reasonCode: AttemptReasonCode?

    public init(outcome: AttemptOutcome, reasonCode: AttemptReasonCode?) {
        self.outcome = outcome
        self.reasonCode = reasonCode
    }
}

public struct ModelInvocationStartedPayload: Codable, Equatable, Sendable {
    public var invocationID: String
    public var ordinal: Int
    public var contextSnapshotID: String
    public var contextDigest: String
    public var runtimeCapabilitySnapshot: String
    public var startedAt: Date

    public init(
        invocationID: String,
        ordinal: Int,
        contextSnapshotID: String,
        contextDigest: String,
        runtimeCapabilitySnapshot: String,
        startedAt: Date
    ) {
        self.invocationID = invocationID
        self.ordinal = ordinal
        self.contextSnapshotID = contextSnapshotID
        self.contextDigest = contextDigest
        self.runtimeCapabilitySnapshot = runtimeCapabilitySnapshot
        self.startedAt = startedAt
    }
}

public struct ModelInvocationCompletedPayload: Codable, Equatable, Sendable {
    public var invocationID: String
    public var endedAt: Date
    public var outcome: String
    /// Nil means the Runtime did not provide verifiable usage data.
    public var usage: [String: Int]?

    public init(
        invocationID: String,
        endedAt: Date,
        outcome: String,
        usage: [String: Int]? = nil
    ) {
        self.invocationID = invocationID
        self.endedAt = endedAt
        self.outcome = outcome
        self.usage = usage
    }
}

public struct ExecutionTimeExpiredPayload: Codable, Equatable, Sendable {
    public var expiredAt: Date
    public var effectiveSeconds: TimeInterval
    public var limitSeconds: TimeInterval

    public init(expiredAt: Date, effectiveSeconds: TimeInterval, limitSeconds: TimeInterval) {
        self.expiredAt = expiredAt
        self.effectiveSeconds = effectiveSeconds
        self.limitSeconds = limitSeconds
    }
}

/// Runtime 返回的工具建议在进入 Reducer 前的可重放载荷。
/// 命令本身是用户可见的非秘密操作描述；凭据、环境变量值和终端输出不进入该载荷。
public struct ConversationToolProposalPayload: Codable, Equatable, Sendable {
    public var proposalID: String
    public var invocationID: String
    public var batchID: String
    public var ordinal: Int
    public var toolID: String
    public var schemaRevision: Int
    public var command: String
    public var explanation: String
    public var risk: String
    public var targetRuntimeID: String
    public var targetRuntimeGeneration: UInt64?
    public var targetTitle: String

    public init(
        proposalID: String,
        invocationID: String,
        batchID: String,
        ordinal: Int,
        toolID: String = StacioBuiltinToolID.terminalCommand,
        schemaRevision: Int = 1,
        command: String,
        explanation: String,
        risk: String,
        targetRuntimeID: String,
        targetRuntimeGeneration: UInt64? = nil,
        targetTitle: String
    ) {
        self.proposalID = proposalID
        self.invocationID = invocationID
        self.batchID = batchID
        self.ordinal = ordinal
        self.toolID = toolID
        self.schemaRevision = schemaRevision
        self.command = command
        self.explanation = explanation
        self.risk = risk
        self.targetRuntimeID = targetRuntimeID
        self.targetRuntimeGeneration = targetRuntimeGeneration
        self.targetTitle = targetTitle
    }

    private enum CodingKeys: String, CodingKey {
        case proposalID
        case invocationID
        case batchID
        case ordinal
        case toolID
        case schemaRevision
        case command
        case explanation
        case risk
        case targetRuntimeID
        case targetRuntimeGeneration
        case targetTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposalID = try container.decode(String.self, forKey: .proposalID)
        invocationID = try container.decode(String.self, forKey: .invocationID)
        batchID = try container.decode(String.self, forKey: .batchID)
        ordinal = try container.decode(Int.self, forKey: .ordinal)
        toolID = try container.decodeIfPresent(String.self, forKey: .toolID)
            ?? StacioBuiltinToolID.terminalCommand
        schemaRevision = try container.decodeIfPresent(Int.self, forKey: .schemaRevision) ?? 1
        command = try container.decode(String.self, forKey: .command)
        explanation = try container.decode(String.self, forKey: .explanation)
        risk = try container.decode(String.self, forKey: .risk)
        targetRuntimeID = try container.decode(String.self, forKey: .targetRuntimeID)
        targetRuntimeGeneration = try container.decodeIfPresent(
            UInt64.self,
            forKey: .targetRuntimeGeneration
        )
        targetTitle = try container.decode(String.self, forKey: .targetTitle)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proposalID, forKey: .proposalID)
        try container.encode(invocationID, forKey: .invocationID)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(toolID, forKey: .toolID)
        try container.encode(schemaRevision, forKey: .schemaRevision)
        try container.encode(command, forKey: .command)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(risk, forKey: .risk)
        try container.encode(targetRuntimeID, forKey: .targetRuntimeID)
        try container.encodeIfPresent(targetRuntimeGeneration, forKey: .targetRuntimeGeneration)
        try container.encode(targetTitle, forKey: .targetTitle)
    }
}

public struct ConversationToolProposalBatchPayload: Codable, Equatable, Sendable {
    public var proposals: [ConversationToolProposalPayload]

    public init(proposals: [ConversationToolProposalPayload]) {
        self.proposals = proposals
    }
}

public struct ToolProposalActivationPayload: Codable, Equatable, Sendable {
    public var proposalID: String

    public init(proposalID: String) {
        self.proposalID = proposalID
    }
}

public struct ApprovalResolutionPayload: Codable, Equatable, Sendable {
    public var decisionID: String
    public var approved: Bool
    /// "user" / "workModeDenied" / 其他审计来源
    public var resolutionSource: String?

    public init(decisionID: String, approved: Bool, resolutionSource: String?) {
        self.decisionID = decisionID
        self.approved = approved
        self.resolutionSource = resolutionSource
    }
}

public struct ApprovalRequestedPayload: Codable, Equatable, Sendable {
    public var decisionID: String
    public var proposalID: String
    public var requestDigest: String
    public var createdAt: Date
    public var deadline: Date
    public var allowedResolutionSchema: String

    public init(
        decisionID: String,
        proposalID: String,
        requestDigest: String,
        createdAt: Date,
        deadline: Date,
        allowedResolutionSchema: String = "operationApproval/v1"
    ) {
        self.decisionID = decisionID
        self.proposalID = proposalID
        self.requestDigest = requestDigest
        self.createdAt = createdAt
        self.deadline = deadline
        self.allowedResolutionSchema = allowedResolutionSchema
    }
}

public struct ApprovalNotRequiredPayload: Codable, Equatable, Sendable {
    public var proposalID: String
    public var requestDigest: String
    public var policySnapshotDigest: String
    public var targetBindingDigest: String
    public var targetRuntimeGeneration: UInt64?
    public var reason: String
    public var risk: String
    public var createdAt: Date

    public init(
        proposalID: String,
        requestDigest: String,
        policySnapshotDigest: String,
        targetBindingDigest: String,
        targetRuntimeGeneration: UInt64?,
        reason: String,
        risk: String,
        createdAt: Date = Date()
    ) {
        self.proposalID = proposalID
        self.requestDigest = requestDigest
        self.policySnapshotDigest = policySnapshotDigest
        self.targetBindingDigest = targetBindingDigest
        self.targetRuntimeGeneration = targetRuntimeGeneration
        self.reason = reason
        self.risk = risk
        self.createdAt = createdAt
    }
}

public struct DecisionExpiredPayload: Codable, Equatable, Sendable {
    public var decisionID: String

    public init(decisionID: String) {
        self.decisionID = decisionID
    }
}

public struct ToolProposalResolutionPayload: Codable, Equatable, Sendable {
    public var proposalID: String
    public var result: String?
    public var error: String?

    public init(proposalID: String, result: String? = nil, error: String? = nil) {
        self.proposalID = proposalID
        self.result = result
        self.error = error
    }
}

public struct UserInputResolutionPayload: Codable, Equatable, Sendable {
    public var decisionID: String
    public var nonSensitiveResponse: String?

    public init(decisionID: String, nonSensitiveResponse: String? = nil) {
        self.decisionID = decisionID
        self.nonSensitiveResponse = nonSensitiveResponse
    }
}

public enum EventPayloadCodec {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Attempt phase transition table（规格 §11 + V2 扩展）

public enum PhaseTransitionTable {
    /// 终态判定（与 `AttemptPhase.isTerminal` 一致，供 reducer 复用）
    public static func isTerminal(_ phase: AttemptPhase) -> Bool {
        phase.isTerminal
    }

    /// 计算 (phase, event, workMode) 的合法目标 phase。
    /// 返回 nil 表示非法边（reducer 必须拒绝）。
    public static func destination(
        from phase: AttemptPhase?,
        event: ConversationEventKind,
        workMode: WorkMode
    ) -> AttemptPhase? {
        guard let phase else {
            // 尚无 Attempt：只有 turnSubmitted 会创建 Attempt 进入 preparing
            return event == .turnSubmitted ? .preparing : nil
        }
        if phase.isTerminal {
            // 终态 Attempt 不再接受任何转移；新 Attempt 由 attemptStarted 创建
            return event == .attemptStarted ? .preparing : nil
        }

        let candidate: AttemptPhase?
        switch (phase, event) {
        // 提交与排队
        case (.preparing, .admissionRequested):
            candidate = .waitingForCapacity
        case (.waitingForCapacity, .admissionRequested):
            candidate = .waitingForCapacity
        case (.waitingForCapacity, .admissionGranted):
            candidate = .startingRuntime
        case (.waitingForCapacity, .admissionCancelled):
            candidate = .cancelled
        case (.waitingForCapacity, .admissionWaitExpired):
            candidate = .failed
        case (.waitingForCapacity, .attemptFailed):
            candidate = .failed
        // 启动
        case (.startingRuntime, .runtimeStartRequested):
            candidate = .startingRuntime
        case (.startingRuntime, .runtimeStarted):
            candidate = .streaming
        case (.startingRuntime, .attemptFailed):
            candidate = .failed
        // 流式
        case (.streaming, .modelInvocationStarted), (.streaming, .modelInvocationCompleted):
            candidate = .streaming
        case (.streaming, .toolProposed):
            candidate = .toolProposed
        case (.streaming, .toolProposalActivated):
            candidate = .toolProposed
        case (.streaming, .userInputRequested), (.streaming, .sensitiveInputRequested):
            candidate = .awaitingUser
        case (.streaming, .pauseRequested):
            candidate = .pausing
        case (.streaming, .childTaskStarted):
            candidate = .streaming
        // 工具提案
        case (.toolProposed, .approvalNotRequired):
            candidate = .executingTool
        case (.toolProposed, .approvalRequested):
            candidate = .awaitingApproval
        case (.toolProposed, .toolProposalCancelled):
            candidate = .streaming
        // 审批
        case (.awaitingApproval, .approvalResolved):
            candidate = nil // 由 reducer 依据 approved 分支处理（见下）
        case (.awaitingApproval, .decisionExpired):
            candidate = .streaming
        // 工具执行
        case (.executingTool, .toolProposalResolved), (.executingTool, .toolProposalCancelled):
            candidate = .streaming
        case (.executingTool, .userInputRequested), (.executingTool, .sensitiveInputRequested):
            candidate = .awaitingUser
        case (.executingTool, .takeoverRequested):
            candidate = .takeoverPending
        case (.executingTool, .pauseRequested):
            candidate = .pausing
        // 用户输入
        case (.awaitingUser, .userInputResolved):
            candidate = .streaming
        // 暂停
        case (.pausing, .paused):
            candidate = .paused
        case (.paused, .resumeRequested):
            candidate = .streaming
        // 接管
        case (.takeoverPending, .takeoverDeclined):
            candidate = .streaming
        case (.takeoverPending, .attemptTakenOver):
            candidate = .takenOver
        // 停止
        case (_, .interruptRequested), (_, .stopping):
            candidate = phase == .stopping ? nil : .stopping
        case (.stopping, .modelInvocationCompleted):
            candidate = .stopping
        case (.stopping, .attemptCancelled):
            candidate = .cancelled
        // 完成
        case (.streaming, .attemptCompleted):
            candidate = .completed
        case (.streaming, .localAgentInputDelivered):
            candidate = .passthroughInputDelivered
        // 失败（Stopping 之后只能 Cancelled；paused/pausing 之外的非终态均可失败）
        case (_, .attemptFailed):
            candidate = phase == .stopping ? nil : .failed
        case (.streaming, .executionTimeExpired):
            candidate = .failed
        case (.executingTool, .executionTimeExpired):
            candidate = .failed
        // 中断重启
        case (_, .attemptInterruptedByRelaunch):
            candidate = .interruptedByRelaunch
        default:
            candidate = nil
        }

        guard let candidate else {
            return nil
        }

        // answer-only 裁剪（规格 §12.7 / C2-3）：Tool/Approval/Execution/SecureInput/
        // ChildTask/Pause/Takeover 在 answer-only 下不可达——先按事件级裁剪（即使目标 phase
        // 合法也不允许进入），再按目标 phase 双保险。
        if workMode == .answerOnly {
            switch event {
            case .toolProposed, .toolProposalActivated, .approvalRequested, .approvalNotRequired,
                 .toolProposalResolved, .toolProposalCancelled,
                 .userInputRequested, .sensitiveInputRequested, .userInputResolved,
                 .pauseRequested, .paused, .resumeRequested,
                 .takeoverRequested, .takeoverDeclined, .childTaskStarted:
                return nil
            default:
                break
            }
            switch candidate {
            case .toolProposed, .awaitingApproval, .executingTool, .awaitingUser,
                 .pausing, .paused, .takeoverPending:
                return nil
            default:
                break
            }
        }
        return candidate
    }
}

// MARK: - 纯 ConversationReducer

public enum ConversationReducer {
    /// 纯函数：(State, EventDraft) -> (TentativeState, [EffectCommand])
    ///
    /// 不执行任何网络/DB/Keychain/时钟/随机 I/O；所有时间取自事件信封；
    /// 所有 effect 以值返回，由 Actor 派发。
    public static func reduce(
        state: ConversationSessionState,
        draft: EventDraft
    ) -> (TentativeState, [EffectCommand]) {
        let kind = draft.envelope.kind
        let sequence = draft.envelope.candidateSequence

        // 1) 序列校验：候选必须 == expectedLast + 1；缺口/乱序交由持久层 buffering，
        //    reducer 拒绝投影（Actor 不会提交）。
        guard sequence == draft.expectedLastSequence + 1 else {
            let record = InvalidTransitionRecord(
                fromPhase: state.phase,
                eventKind: kind,
                reason: "sequence gap: expected \(draft.expectedLastSequence + 1), got \(sequence)"
            )
            return (TentativeState(state: state, invalidTransitions: [record]), [])
        }

        var newState = state
        var effects: [EffectCommand] = []
        var invalid: [InvalidTransitionRecord] = []

        apply(
            kind: kind, payload: draft.envelope.payload,
            turnID: draft.envelope.turnID, attemptID: draft.envelope.attemptID,
            timestamp: draft.envelope.timestamp,
            state: &newState, effects: &effects, invalid: &invalid
        )
        guard invalid.isEmpty else {
            // A rejected draft is an atomic no-op. Returning any partially
            // projected state (including an advanced sequence) makes direct
            // reducer callers and replay diagnostics observe data that the
            // Actor will never commit.
            return (TentativeState(state: state, invalidTransitions: invalid), [])
        }
        newState.session.updatedAt = draft.envelope.timestamp
        newState.lastAppliedSequence = sequence

        return (TentativeState(state: newState, invalidTransitions: invalid), effects)
    }

    // MARK: - 事件应用

    private static func apply(
        kind: ConversationEventKind,
        payload: Data,
        turnID: String?,
        attemptID: String?,
        timestamp: Date,
        state: inout ConversationSessionState,
        effects: inout [EffectCommand],
        invalid: inout [InvalidTransitionRecord]
    ) {
        switch kind {
        // 会话级
        case .sessionCreated:
            // Empty payloads are retained for backwards compatibility with the
            // phase-2 event fixtures. Production V2 sessions persist the full,
            // encrypted descriptor in their first event.
            guard payload.isEmpty == false else { break }
            guard state.lastAppliedSequence == 0,
                  let decoded = EventPayloadCodec.decode(
                    ConversationSessionCreatedPayload.self,
                    from: payload
                  ),
                  decoded.session.id == state.session.id
            else {
                reject(state: state, kind: kind, reason: "invalid session creation payload", invalid: &invalid)
                return
            }
            state.session = decoded.session

        case .sessionBindingChanged, .branchCreated:
            break

        case .sessionMetadataChanged:
            guard let decoded = EventPayloadCodec.decode(
                ConversationSessionMetadataChangedPayload.self,
                from: payload
            ) else {
                reject(state: state, kind: kind, reason: "invalid session metadata payload", invalid: &invalid)
                return
            }
            let title = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let revision = state.session.metadataRevision ?? 0
            guard decoded.expectedRevision == revision,
                  title.isEmpty == false,
                  title.count <= 160,
                  decoded.archivedAt.map({ $0 <= timestamp }) ?? true
            else {
                reject(state: state, kind: kind, reason: "session metadata conflict", invalid: &invalid)
                return
            }
            state.session.title = title
            state.session.isPinned = decoded.pinned
            state.session.archivedAt = decoded.archivedAt
            state.session.metadataRevision = revision + 1

        case .draftChanged:
            state.session.draft = String(data: payload, encoding: .utf8)

        case .queueAutoAdvanceChanged:
            guard let decoded = EventPayloadCodec.decode(QueueAutoAdvanceChangedPayload.self, from: payload) else {
                reject(state: state, kind: kind, reason: "invalid queue auto-advance payload", invalid: &invalid)
                return
            }
            state.session.queueAutoAdvancePaused = decoded.paused

        case .queuedInputAdded:
            guard let decoded = EventPayloadCodec.decode(QueuedInputAddedPayload.self, from: payload),
                  decoded.input.sessionID == state.session.id,
                  state.session.queuedInputs.contains(where: { $0.id == decoded.input.id }) == false
            else {
                reject(state: state, kind: kind, reason: "invalid or duplicate queued input", invalid: &invalid)
                return
            }
            let destination = min(
                max(decoded.input.position, 0),
                state.session.queuedInputs.count
            )
            state.session.queuedInputs.insert(decoded.input, at: destination)
            reindexQueuedInputPositions(&state.session.queuedInputs)

        case .queuedInputEdited:
            guard let decoded = EventPayloadCodec.decode(QueuedInputEditedPayload.self, from: payload),
                  let index = state.session.queuedInputs.firstIndex(where: { $0.id == decoded.input.id }),
                  state.session.queuedInputs[index].revision == decoded.expectedRevision,
                  decoded.input.revision == decoded.expectedRevision + 1,
                  decoded.input.sessionID == state.session.id
            else {
                reject(state: state, kind: kind, reason: "queued input edit conflict", invalid: &invalid)
                return
            }
            state.session.queuedInputs[index] = decoded.input
            reindexQueuedInputPositions(&state.session.queuedInputs)

        case .queuedInputMoved:
            guard let decoded = EventPayloadCodec.decode(QueuedInputMovedPayload.self, from: payload),
                  let index = state.session.queuedInputs.firstIndex(where: { $0.id == decoded.inputID }),
                  state.session.queuedInputs[index].revision == decoded.expectedRevision,
                  state.session.queuedInputs.isEmpty == false
            else {
                reject(state: state, kind: kind, reason: "queued input move conflict", invalid: &invalid)
                return
            }
            var moved = state.session.queuedInputs.remove(at: index)
            moved.revision += 1
            let destination = min(max(decoded.destination, 0), state.session.queuedInputs.count)
            state.session.queuedInputs.insert(moved, at: destination)
            reindexQueuedInputPositions(&state.session.queuedInputs)

        case .queuedInputRemoved:
            guard let decoded = EventPayloadCodec.decode(QueuedInputRemovedPayload.self, from: payload),
                  let index = state.session.queuedInputs.firstIndex(where: { $0.id == decoded.inputID }),
                  state.session.queuedInputs[index].revision == decoded.expectedRevision
            else {
                reject(state: state, kind: kind, reason: "queued input removal conflict", invalid: &invalid)
                return
            }
            state.session.queuedInputs.remove(at: index)
            reindexQueuedInputPositions(&state.session.queuedInputs)

        case .runtimeSelectionChanged:
            guard state.activeAttempt?.phase.isTerminal != false,
                  state.session.queuedInputs.isEmpty,
                  let decoded = EventPayloadCodec.decode(
                    RuntimeSelectionChangedPayload.self,
                    from: payload
                  ),
                  validRuntimeSelection(decoded.selection),
                  decoded.selection.revision == state.session.runtimeSelection.revision + 1
            else {
                reject(state: state, kind: kind, reason: "invalid next-turn runtime selection", invalid: &invalid)
                return
            }
            state.session.runtimeSelection = decoded.selection

        // Turn 提交：创建 Turn + 首个 Attempt(preparing)
        case .turnSubmitted:
            // P0-4：允许在无活动 Turn 或活动 Turn 已终态时创建新 Turn。
            if let active = state.activeTurn, active.phase.isTerminal == false {
                reject(state: state, kind: kind, reason: "active turn already running", invalid: &invalid)
                return
            }
            let submitted = EventPayloadCodec.decode(TurnSubmittedPayload.self, from: payload)
            // P0-4：使用 envelope.turnID（而非硬编码 "t-1"），确保每轮唯一。
            let resolvedTurnID = turnID ?? "t-\(state.session.id)"
            // P0-4：使用 envelope.attemptID（而非硬编码 "a-1"），确保与后续事件一致。
            let resolvedAttemptID = attemptID ?? "a-1"
            let selection = submitted?.runtimeSelection ?? state.session.runtimeSelection
            let targetBinding = submitted?.targetBinding ?? state.session.targetBinding
            let terminalMode = submitted?.terminalMode
            let previousOrdinal = state.activeTurn?.ordinal ?? 0
            let resolvedOrdinal = submitted?.ordinal ?? (previousOrdinal + 1)
            guard resolvedOrdinal > previousOrdinal else {
                reject(state: state, kind: kind, reason: "turn ordinal must increase", invalid: &invalid)
                return
            }
            let request = submitted?.text
                ?? String(data: payload, encoding: .utf8)
                ?? ""
            // Structured V2 submissions enforce a non-empty request. Legacy event
            // streams may contain an empty payload because older reducers did not
            // persist the user text; those records must remain replayable.
            guard submitted == nil
                    || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                reject(state: state, kind: kind, reason: "empty turn request", invalid: &invalid)
                return
            }
            guard submitted == nil || validRuntimeSelection(selection) else {
                reject(state: state, kind: kind, reason: "invalid turn runtime selection", invalid: &invalid)
                return
            }
            if state.session.title == "新会话",
               state.session.metadataRevision ?? 0 == 0,
               submitted?.runtimeSettingsSnapshot?.localAutoTitleEnabled != false {
                let title = localAutoTitle(for: request)
                if title.isEmpty == false {
                    state.session.title = title
                    state.session.metadataRevision = 1
                }
            }
            // A turn snapshot is authoritative for the attempt. Updating the session
            // projection as well makes the selected target/runtime visible after replay.
            state.session.runtimeSelection = selection
            state.session.targetBinding = targetBinding
            let attempt = freshAttempt(
                turnID: resolvedTurnID,
                workMode: selection.workMode,
                runtimeSnapshot: selection.modelID
                    ?? selection.providerConfigurationID
                    ?? selection.codingPlanConfigurationID
                    ?? selection.localAgentConfigurationID
                    ?? selection.kind.rawValue,
                targetBindingSnapshot: targetBinding,
                targetRuntimeGeneration: submitted?.targetRuntimeGeneration,
                terminalModeSnapshot: terminalMode,
                agentProcessWorkingDirectorySnapshot: submitted?.agentProcessWorkingDirectorySnapshot,
                localAgentExecutionProfileSnapshot: selection.localAgentExecutionProfileID,
                runtimeAuthenticationSnapshot: submitted?.runtimeAuthenticationSnapshot,
                configurationRevisionDigest: submitted?.configurationRevisionDigest,
                policySnapshot: (try? submitted?.runtimeSettingsSnapshot?.encoded()) ?? "",
                toolAuthorizationPolicySnapshot: submitted?.toolAuthorizationPolicySnapshot,
                toolCapabilitySnapshot: (try? submitted?.toolCapabilitySnapshot?.encoded())
                    ?? (try? submitted?.runtimeSettingsSnapshot?.encodedValues(
                        for: ["assistant.tools.enabledToolIDs"]
                    ))
                    ?? "",
                toolCatalogRevision: submitted?.toolCapabilitySnapshot.map {
                    String($0.catalogRevision)
                },
                instructionSnapshot: submitted?.runtimeSettingsSnapshot?.globalInstructions ?? "",
                instructionDigest: submitted?.runtimeSettingsSnapshot?.instructionDigest,
                usageBudgetSnapshot: try? submitted?.runtimeSettingsSnapshot?.encodedValues(for: [
                    "assistant.usage.maxModelInvocations",
                    "assistant.usage.tokenWarningThreshold",
                    "assistant.usage.hardTokenLimit",
                    "assistant.usage.costWarning",
                    "assistant.usage.hardCostLimit"
                ]),
                id: resolvedAttemptID
            )
            let turn = ConversationTurn(
                id: resolvedTurnID, sessionID: state.session.id, ordinal: resolvedOrdinal,
                userRequest: request,
                phase: .preparing, attempts: [attempt], activeAttemptID: attempt.id,
                timing: [:], usage: [:]
            )
            state.session.activeTurnID = resolvedTurnID
            state.activeTurn = turn
            effects.append(.requestAdmission(sessionID: state.session.id, turnID: resolvedTurnID, attemptID: attempt.id))

        // Retry / 恢复：从终态创建新 Attempt（从 preparing 开始，不消费旧 proposal/decision/child）
        case .attemptStarted:
            guard let turn = state.activeTurn, turn.activeAttemptID != nil else {
                reject(state: state, kind: kind, reason: "no prior attempt to retry", invalid: &invalid)
                return
            }
            let newAttemptOrdinal = turn.attempts.count + 1
            let previousAttempt = turn.attempts.last
            // P0-4：attemptStarted 是 Retry，新 Attempt ID 由 ordinal 派生（不沿用 envelope.attemptID）
            let newAttempt = freshAttempt(
                turnID: turn.id,
                workMode: previousAttempt?.workModeSnapshot ?? state.workMode,
                runtimeSnapshot: previousAttempt?.runtimeSnapshot
                    ?? state.session.runtimeSelection.modelID
                    ?? state.session.runtimeSelection.providerConfigurationID
                    ?? state.session.runtimeSelection.codingPlanConfigurationID
                    ?? state.session.runtimeSelection.localAgentConfigurationID
                    ?? state.session.runtimeSelection.kind.rawValue,
                targetBindingSnapshot: previousAttempt?.targetBindingSnapshot
                    ?? state.session.targetBinding,
                targetRuntimeGeneration: previousAttempt?.targetRuntimeGeneration,
                terminalModeSnapshot: previousAttempt?.terminalModeSnapshot,
                agentProcessWorkingDirectorySnapshot: previousAttempt?.agentProcessWorkingDirectorySnapshot,
                localAgentExecutionProfileSnapshot: previousAttempt?.localAgentExecutionProfileSnapshot,
                runtimeAuthenticationSnapshot: previousAttempt?.runtimeAuthenticationSnapshot,
                configurationRevisionDigest: previousAttempt?.configurationRevisionDigest,
                policySnapshot: previousAttempt?.policySnapshot ?? "",
                toolAuthorizationPolicySnapshot: previousAttempt?.toolAuthorizationPolicySnapshot,
                toolCapabilitySnapshot: previousAttempt?.toolCapabilitySnapshot ?? "",
                toolCatalogRevision: previousAttempt?.toolCatalogRevision,
                instructionSnapshot: previousAttempt?.instructionSnapshot ?? "",
                instructionDigest: previousAttempt?.instructionDigest,
                usageBudgetSnapshot: previousAttempt?.usageBudgetSnapshot,
                pricingCatalogRevision: previousAttempt?.pricingCatalogRevision,
                purpose: .retrySameConfig,
                ordinal: newAttemptOrdinal,
                id: "a-\(newAttemptOrdinal)"
            )
            var newTurn = turn
            newTurn.attempts.append(newAttempt)
            newTurn.activeAttemptID = newAttempt.id
            newTurn.phase = .preparing
            state.activeTurn = newTurn
            effects.append(.requestAdmission(sessionID: state.session.id, turnID: turn.id, attemptID: newAttempt.id))

        // Attempt 状态机事件
        case .admissionRequested, .admissionGranted, .admissionCancelled, .admissionWaitExpired,
             .runtimeStartRequested, .runtimeStarted,
             .modelInvocationStarted, .modelInvocationCompleted,
             .toolProposed, .toolProposalActivated, .approvalNotRequired, .approvalRequested,
             .toolProposalResolved, .toolProposalCancelled,
             .userInputRequested, .sensitiveInputRequested, .userInputResolved,
             .pauseRequested, .paused, .resumeRequested,
             .takeoverRequested, .takeoverDeclined,
             .interruptRequested, .stopping, .executionTimeExpired,
             .childTaskStarted, .attemptInterruptedByRelaunch:
            applyAttemptTransition(kind: kind, payload: payload, state: &state, effects: &effects, invalid: &invalid)

        case .approvalResolved:
            applyApprovalResolution(kind: kind, payload: payload, state: &state, effects: &effects, invalid: &invalid)

        case .decisionExpired:
            applyDecisionExpired(kind: kind, payload: payload, state: &state, effects: &effects, invalid: &invalid)

        case .attemptCompleted, .attemptFailed, .attemptCancelled, .attemptTakenOver,
             .localAgentInputDelivered:
            applyAttemptTermination(kind: kind, payload: payload, state: &state, effects: &effects, invalid: &invalid)

        // 流式内容累积（规格 §8.3 finalAnswerDelta/reasoningSummaryUpdated；纯字符串拼接，无 I/O）
        case .finalAnswerDelta:
            accumulateFinalAnswerDelta(payload: payload, state: &state, invalid: &invalid)

        case .finalAnswerCompleted:
            commitCanonicalFinalAnswer(payload: payload, state: &state, invalid: &invalid)

        case .reasoningSummaryUpdated:
            accumulateReasoningSummary(payload: payload, state: &state, invalid: &invalid)

        case .finalAnswerSuperseded:
            // 重新生成：迟到完成不改 canonical；清除当前 partialAnswer 投影（保留历史在事件流）
            mutateAttempt(state: &state, attemptID: state.activeAttempt?.id ?? "") { current in
                current.partialAnswer = nil
            }

        default:
            // 未在本阶段建模的事件（regeneration/effect/artifact/compaction 等）：
            // 保持状态，只推进序列（C2-6/C2-9/C2-10 逐步细化）。
            break
        }
    }

    private static func localAutoTitle(for request: String) -> String {
        let oneLine = request
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return String(oneLine.prefix(48))
    }

    // MARK: - Attempt 转移

    private static func applyAttemptTransition(
        kind: ConversationEventKind,
        payload: Data,
        state: inout ConversationSessionState,
        effects: inout [EffectCommand],
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = state.activeAttempt else {
            reject(state: state, kind: kind, reason: "no active attempt", invalid: &invalid)
            return
        }
        guard let destination = PhaseTransitionTable.destination(
            from: attempt.phase, event: kind, workMode: state.workMode
        ) else {
            reject(state: state, kind: kind, reason: "illegal edge from \(attempt.phase.rawValue)", invalid: &invalid)
            return
        }

        mutateAttempt(state: &state, attemptID: attempt.id) { current in
            current.phase = destination
            if destination == .failed {
                current.outcome = .failed
                current.error = failureReasonCode(for: kind)?.rawValue
                if let resolved = EventPayloadCodec.decode(
                    AdmissionResolvedPayload.self,
                    from: payload
                ) {
                    current.endedAt = resolved.resolvedAt
                }
            } else if kind == .admissionCancelled {
                current.outcome = .cancelled
                current.error = AttemptReasonCode.cancelled.rawValue
                current.endedAt = EventPayloadCodec.decode(
                    AdmissionResolvedPayload.self,
                    from: payload
                )?.resolvedAt
            } else if destination == .interruptedByRelaunch {
                current.outcome = .interruptedByRelaunch
                current.error = AttemptReasonCode.interruptedByRelaunch.rawValue
            }
        }

        switch kind {
        case .admissionRequested:
            if payload.isEmpty == false {
                guard let requested = EventPayloadCodec.decode(
                    AdmissionRequestedPayload.self,
                    from: payload
                ), requested.attemptID == attempt.id,
                   requested.requestID.isEmpty == false,
                   requested.schedulerGeneration > 0,
                   requested.queueOrdinal > 0,
                   requested.waitTimeoutSeconds >= 0 else {
                    reject(state: state, kind: kind, reason: "invalid admission request payload", invalid: &invalid)
                    return
                }
            }
        case .admissionGranted:
            if payload.isEmpty == false {
                guard let granted = EventPayloadCodec.decode(
                    AdmissionGrantedPayload.self,
                    from: payload
                ), granted.attemptID == attempt.id,
                   granted.requestID.isEmpty == false,
                   granted.leaseID.isEmpty == false,
                   granted.schedulerGeneration > 0,
                   granted.settlementID.isEmpty == false else {
                    reject(state: state, kind: kind, reason: "invalid admission grant payload", invalid: &invalid)
                    return
                }
            }
            effects.append(.startRuntime(attemptID: attempt.id))
        case .admissionCancelled:
            effects.append(.finalizeAttempt(
                attemptID: attempt.id,
                outcome: .cancelled,
                reasonCode: .cancelled
            ))
        case .modelInvocationStarted:
            appendModelInvocation(
                payload: payload,
                state: &state,
                attemptID: attempt.id,
                invalid: &invalid
            )
        case .modelInvocationCompleted:
            completeModelInvocation(
                payload: payload,
                state: &state,
                attemptID: attempt.id,
                invalid: &invalid
            )
        case .admissionWaitExpired:
            effects.append(.finalizeAttempt(attemptID: attempt.id, outcome: .failed, reasonCode: .capacityWaitExpired))
        case .executionTimeExpired:
            if payload.isEmpty == false {
                guard let expired = EventPayloadCodec.decode(ExecutionTimeExpiredPayload.self, from: payload),
                      expired.effectiveSeconds >= 0,
                      expired.limitSeconds >= 0,
                      expired.effectiveSeconds >= expired.limitSeconds
                else {
                    reject(state: state, kind: kind, reason: "invalid execution time expiry payload", invalid: &invalid)
                    return
                }
                mutateAttempt(state: &state, attemptID: attempt.id) { current in
                    current.endedAt = expired.expiredAt
                }
            }
            effects.append(.finalizeAttempt(attemptID: attempt.id, outcome: .failed, reasonCode: .executionTimeExpired))
        case .toolProposed:
            appendToolProposals(payload: payload, state: &state, attemptID: attempt.id)
        case .toolProposalActivated:
            activateToolProposal(payload: payload, state: &state, attemptID: attempt.id, invalid: &invalid)
        case .approvalNotRequired:
            guard let authorization = EventPayloadCodec.decode(
                ApprovalNotRequiredPayload.self,
                from: payload
            ),
                  authorization.proposalID == attempt.activeToolProposalID,
                  authorization.policySnapshotDigest.isEmpty == false,
                  authorization.targetBindingDigest.isEmpty == false,
                  authorization.reason.isEmpty == false,
                  authorization.risk.isEmpty == false,
                  let policySnapshot = attempt.toolAuthorizationPolicySnapshot,
                  policySnapshot.evaluationInputs != nil,
                  authorization.policySnapshotDigest == policySnapshot.digest,
                  let proposal = attempt.toolProposalQueue.first(where: {
                      $0.id == authorization.proposalID
                  }),
                  proposal.operationDigest == authorization.requestDigest,
                  attempt.targetBindingSnapshot?.digest == authorization.targetBindingDigest,
                  attempt.targetRuntimeGeneration == authorization.targetRuntimeGeneration,
                  let policyInputs = policySnapshot.evaluationInputs,
                  {
                      let evaluation = AgentActionPolicyEvaluator.evaluate(
                          policy: policyInputs.policy,
                          commandPolicy: policyInputs.commandPolicy,
                          command: proposal.immutableOperation,
                          automationPolicy: policyInputs.automationPolicy
                      )
                      return evaluation.requirement == .allowedWithoutConfirmation
                          && evaluation.risk.rawValue == authorization.risk
                  }()
            else {
                reject(
                    state: state,
                    kind: kind,
                    reason: "invalid approval-not-required evidence",
                    invalid: &invalid
                )
                return
            }
            let proposalID = attempt.activeToolProposalID
            resolveActiveProposal(
                state: &state,
                attemptID: attempt.id,
                to: .executing,
                approvalSource: .policyAutoAllowed
            )
            if let proposalID {
                effects.append(.executeTool(attemptID: attempt.id, proposalID: proposalID))
            }
        case .approvalRequested:
            guard appendApprovalDecision(
                payload: payload,
                state: &state,
                attemptID: attempt.id,
                invalid: &invalid
            ) else { return }
            resolveActiveProposal(state: &state, attemptID: attempt.id, to: .awaitingApproval)
        case .sensitiveInputRequested:
            appendDecision(state: &state, kind: .secureInput, attemptID: attempt.id, resumePhase: .awaitingUser)
        case .userInputRequested:
            appendDecision(state: &state, kind: .userInput, attemptID: attempt.id, resumePhase: .awaitingUser)
        case .userInputResolved:
            if let resolution = EventPayloadCodec.decode(UserInputResolutionPayload.self, from: payload) {
                settleDecision(state: &state, decisionID: resolution.decisionID, to: .answered, source: "user")
            }
        case .toolProposalResolved:
            settleActiveProposal(payload: payload, state: &state, attemptID: attempt.id, target: .resolved)
        case .toolProposalCancelled:
            settleActiveProposal(payload: payload, state: &state, attemptID: attempt.id, target: .cancelled)
        default:
            break
        }
    }

    /// admissionWaitExpired / executionTimeExpired 等隐式失败事件的稳定 reasonCode。
    private static func failureReasonCode(for kind: ConversationEventKind) -> AttemptReasonCode? {
        switch kind {
        case .admissionWaitExpired: return .capacityWaitExpired
        case .executionTimeExpired: return .executionTimeExpired
        default: return nil
        }
    }

    // MARK: - 审批 / 过期 / 终态

    private static func applyApprovalResolution(
        kind: ConversationEventKind,
        payload: Data,
        state: inout ConversationSessionState,
        effects: inout [EffectCommand],
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = state.activeAttempt else {
            reject(state: state, kind: kind, reason: "no active attempt", invalid: &invalid)
            return
        }
        guard let resolution = EventPayloadCodec.decode(ApprovalResolutionPayload.self, from: payload) else {
            reject(state: state, kind: kind, reason: "malformed approvalResolved payload", invalid: &invalid)
            return
        }
        guard let decision = state.decisions[resolution.decisionID],
              decision.attemptID == attempt.id,
              decision.kind == .operationApproval,
              decision.state == .pending,
              decision.proposalID == attempt.activeToolProposalID,
              attempt.pendingDecisionIDs.contains(resolution.decisionID)
        else {
            reject(state: state, kind: kind, reason: "approval decision does not match active proposal", invalid: &invalid)
            return
        }

        if attempt.phase == .awaitingApproval {
            let approved = resolution.approved
            if approved, resolution.resolutionSource != "user" {
                reject(
                    state: state,
                    kind: kind,
                    reason: "approved operation must have a user resolution source",
                    invalid: &invalid
                )
                return
            }
            let source = resolution.resolutionSource ?? "user"
            // workModeDenied：只结算 decision，Attempt 回到 streaming（非终态），不伪造终态 reasonCode。
            let destination: AttemptPhase = approved ? .executingTool : .streaming
            mutateAttempt(state: &state, attemptID: attempt.id) { current in
                current.phase = destination
                if !approved {
                    current.error = nil
                }
            }
            settleDecision(state: &state, decisionID: resolution.decisionID, to: approved ? .approved : .denied, source: source)
            if approved {
                resolveActiveProposal(
                    state: &state,
                    attemptID: attempt.id,
                    to: .executing,
                    approvalSource: .userApproved
                )
            } else {
                resolveActiveProposal(state: &state, attemptID: attempt.id, to: .cancelled)
            }
            effects.append(.resolveDecision(decisionID: resolution.decisionID, outcome: approved ? .approved : .denied, source: source))
            if approved, let proposalID = attempt.activeToolProposalID {
                effects.append(.executeTool(attemptID: attempt.id, proposalID: proposalID))
            }
        } else {
            reject(state: state, kind: kind, reason: "approvalResolved outside awaitingApproval", invalid: &invalid)
        }
    }

    private static func applyDecisionExpired(
        kind: ConversationEventKind,
        payload: Data,
        state: inout ConversationSessionState,
        effects: inout [EffectCommand],
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = state.activeAttempt else {
            reject(state: state, kind: kind, reason: "no active attempt", invalid: &invalid)
            return
        }
        guard let expired = EventPayloadCodec.decode(DecisionExpiredPayload.self, from: payload) else {
            reject(state: state, kind: kind, reason: "malformed decisionExpired payload", invalid: &invalid)
            return
        }
        guard attempt.phase == .awaitingApproval else {
            reject(state: state, kind: kind, reason: "decisionExpired outside awaitingApproval", invalid: &invalid)
            return
        }
        guard let decision = state.decisions[expired.decisionID],
              decision.attemptID == attempt.id,
              decision.kind == .operationApproval,
              decision.state == .pending,
              decision.proposalID == attempt.activeToolProposalID,
              attempt.pendingDecisionIDs.contains(expired.decisionID)
        else {
            reject(state: state, kind: kind, reason: "expired decision does not match active proposal", invalid: &invalid)
            return
        }
        // approvalExpired 不是 Attempt 终态：回到 streaming，Attempt 无 outcome。
        mutateAttempt(state: &state, attemptID: attempt.id) { current in
            current.phase = .streaming
        }
        settleDecision(state: &state, decisionID: expired.decisionID, to: .expired, source: "approvalExpired")
        resolveActiveProposal(state: &state, attemptID: attempt.id, to: .resolved)
        effects.append(.resolveDecision(decisionID: expired.decisionID, outcome: .expired, source: "approvalExpired"))
    }

    private static func applyAttemptTermination(
        kind: ConversationEventKind,
        payload: Data,
        state: inout ConversationSessionState,
        effects: inout [EffectCommand],
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = state.activeAttempt else {
            reject(state: state, kind: kind, reason: "no active attempt", invalid: &invalid)
            return
        }

        switch kind {
        case .localAgentInputDelivered:
            guard attempt.phase == .streaming,
                  let delivered = EventPayloadCodec.decode(
                    LocalAgentInputDeliveredPayload.self,
                    from: payload
                  ),
                  delivered.attemptID == attempt.id,
                  delivered.phaseAtTermination == .streaming,
                  delivered.reasonCode == .passthroughInputDelivered,
                  delivered.effectReconciliationState == "settled",
                  delivered.admissionSettlementID.isEmpty == false,
                  delivered.idempotencyKey.isEmpty == false,
                  delivered.deliveryID.isEmpty == false,
                  delivered.byteCount > 0,
                  delivered.configurationRevisionDigest.isEmpty == false,
                  delivered.configurationRevisionDigest == attempt.configurationRevisionDigest
            else {
                reject(state: state, kind: kind, reason: "malformed localAgentInputDelivered", invalid: &invalid)
                return
            }
            mutateAttempt(state: &state, attemptID: attempt.id) { current in
                current.phase = .passthroughInputDelivered
                current.outcome = .passthroughInputDelivered
            }
            effects.append(.finalizeAttempt(
                attemptID: attempt.id,
                outcome: .passthroughInputDelivered,
                reasonCode: .passthroughInputDelivered
            ))

        case .attemptCancelled:
            guard attempt.phase == .stopping else {
                reject(state: state, kind: kind, reason: "attemptCancelled only from stopping", invalid: &invalid)
                return
            }
            mutateAttempt(state: &state, attemptID: attempt.id) { current in
                current.phase = .cancelled
                current.outcome = .cancelled
                current.endedAt = current.endedAt
                current.toolProposalQueue = ToolProposalArbitrator.cancelPending(current.toolProposalQueue)
                current.activeToolProposalID = nil
            }
            for decisionID in attempt.pendingDecisionIDs {
                settleDecision(state: &state, decisionID: decisionID, to: .cancelled, source: "stop")
            }
            effects.append(.finalizeAttempt(attemptID: attempt.id, outcome: .cancelled, reasonCode: .cancelled))

        case .attemptTakenOver:
            guard attempt.phase == .takeoverPending else {
                reject(state: state, kind: kind, reason: "attemptTakenOver only from takeoverPending", invalid: &invalid)
                return
            }
            mutateAttempt(state: &state, attemptID: attempt.id) { current in
                current.phase = .takenOver
                current.outcome = .takenOver
            }
            effects.append(.finalizeAttempt(attemptID: attempt.id, outcome: .takenOver, reasonCode: .takenOver))

        case .attemptFailed:
            let termination = EventPayloadCodec.decode(AttemptTerminationPayload.self, from: payload)
            guard let destination = PhaseTransitionTable.destination(
                from: attempt.phase, event: kind, workMode: state.workMode
            ) else {
                reject(state: state, kind: kind, reason: "illegal failed edge from \(attempt.phase.rawValue)", invalid: &invalid)
                return
            }
            let reasonCode = termination?.reasonCode ?? .runtimeStateUnknown
            mutateAttempt(state: &state, attemptID: attempt.id) { current in
                current.phase = destination
                current.outcome = .failed
                current.error = termination?.reasonCode?.rawValue
            }
            effects.append(.finalizeAttempt(attemptID: attempt.id, outcome: .failed, reasonCode: reasonCode))

        case .attemptCompleted:
            guard attempt.phase == .streaming else {
                reject(state: state, kind: kind, reason: "attemptCompleted only from streaming", invalid: &invalid)
                return
            }
            let termination = EventPayloadCodec.decode(AttemptTerminationPayload.self, from: payload)
            mutateAttempt(state: &state, attemptID: attempt.id) { current in
                current.phase = .completed
                current.outcome = .completed
            }
            effects.append(.finalizeAttempt(
                attemptID: attempt.id,
                outcome: .completed,
                reasonCode: termination?.reasonCode ?? .completed
            ))
            // P0-4：终态归档——清除 activeTurn，允许下一轮 turnSubmitted 创建新 Turn

        default:
            break
        }
    }

    private static func validRuntimeSelection(_ selection: AgentRuntimeSelection) -> Bool {
        switch selection.kind {
        case .nativeAPI:
            let providerSelected = selection.providerConfigurationID?.isEmpty == false
            let planSelected = selection.codingPlanConfigurationID?.isEmpty == false
            return !(providerSelected && planSelected)
                && selection.localAgentConfigurationID == nil
                && selection.localAgentExecutionProfileID == nil
                && selection.localAgentExecutionProfileKind == .none
        case .localAgent:
            return selection.providerConfigurationID == nil
                && selection.codingPlanConfigurationID == nil
                && selection.modelID == nil
                && selection.localAgentConfigurationID?.isEmpty == false
                && selection.localAgentExecutionProfileID?.isEmpty == false
                && selection.localAgentExecutionProfileKind != .none
                && (selection.localAgentExecutionProfileKind != .terminalPassthrough
                    || selection.workMode == .agent)
        }
    }


    // MARK: - 流式内容累积

    /// `finalAnswerDelta`：将 payload(utf8) 追加到 `activeAttempt.partialAnswer`（纯字符串拼接，无 I/O）。
    /// 无活动 Attempt 时记录非法转换（不伪造 Attempt）。
    private static func accumulateFinalAnswerDelta(
        payload: Data,
        state: inout ConversationSessionState,
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = mutableAttempt(
            for: .finalAnswerDelta,
            state: state,
            invalid: &invalid
        ) else {
            return
        }
        let delta = String(data: payload, encoding: .utf8) ?? ""
        mutateAttempt(state: &state, attemptID: attempt.id) { current in
            current.partialAnswer = (current.partialAnswer ?? "") + delta
        }
    }

    private static func mutableAttempt(
        for eventKind: ConversationEventKind,
        state: ConversationSessionState,
        invalid: inout [InvalidTransitionRecord]
    ) -> TurnAttempt? {
        guard let attempt = state.activeAttempt else {
            invalid.append(InvalidTransitionRecord(
                fromPhase: state.phase,
                eventKind: eventKind,
                reason: "\(eventKind.rawValue) without active attempt"
            ))
            return nil
        }
        guard attempt.phase.isTerminal == false else {
            invalid.append(InvalidTransitionRecord(
                fromPhase: attempt.phase,
                eventKind: eventKind,
                reason: "\(eventKind.rawValue) after terminal attempt"
            ))
            return nil
        }
        return attempt
    }

    /// `finalAnswerCompleted` 是 canonical answer 的唯一提交点：用完整 payload 覆盖 checkpoint 累积，
    /// 并同时推进 Turn 的 canonical revision/owner。终态仍由后续 `attemptCompleted` 原子提交。
    private static func commitCanonicalFinalAnswer(
        payload: Data,
        state: inout ConversationSessionState,
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = mutableAttempt(
            for: .finalAnswerCompleted,
            state: state,
            invalid: &invalid
        ) else {
            return
        }
        guard let answer = String(data: payload, encoding: .utf8) else {
            invalid.append(InvalidTransitionRecord(
                fromPhase: state.phase,
                eventKind: .finalAnswerCompleted,
                reason: "finalAnswerCompleted payload is not UTF-8"
            ))
            return
        }
        guard var turn = state.activeTurn,
              let index = turn.attempts.firstIndex(where: { $0.id == attempt.id })
        else {
            invalid.append(InvalidTransitionRecord(
                fromPhase: state.phase,
                eventKind: .finalAnswerCompleted,
                reason: "canonical attempt is missing from active turn"
            ))
            return
        }
        turn.attempts[index].partialAnswer = answer
        turn.canonicalFinalAnswerAttemptID = attempt.id
        turn.canonicalFinalAnswerRevision += 1
        turn.finalAnswerState = .available
        state.activeTurn = turn
    }

    /// `reasoningSummaryUpdated`：累积可公开推理摘要到 attempt 的 `reasoningSummary` 字段
    /// （仅 Runtime 提供的安全 summary，非隐藏思维链；纯字符串拼接，无 I/O）。
    private static func accumulateReasoningSummary(
        payload: Data,
        state: inout ConversationSessionState,
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let attempt = mutableAttempt(
            for: .reasoningSummaryUpdated,
            state: state,
            invalid: &invalid
        ) else {
            return
        }
        let summary = String(data: payload, encoding: .utf8) ?? ""
        mutateAttempt(state: &state, attemptID: attempt.id) { current in
            current.reasoningSummary = (current.reasoningSummary ?? "") + summary
        }
    }

    // MARK: - 状态变更辅助

    private static func reject(
        state: ConversationSessionState,
        kind: ConversationEventKind,
        reason: String,
        invalid: inout [InvalidTransitionRecord]
    ) {
        invalid.append(InvalidTransitionRecord(fromPhase: state.phase, eventKind: kind, reason: reason))
    }

    private static func mutateAttempt(
        state: inout ConversationSessionState,
        attemptID: String,
        mutate: (inout TurnAttempt) -> Void
    ) {
        guard var turn = state.activeTurn else { return }
        guard let index = turn.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        mutate(&turn.attempts[index])
        turn.phase = turn.attempts[index].phase
        state.activeTurn = turn
    }

    private static func reindexQueuedInputPositions(_ inputs: inout [QueuedInput]) {
        for index in inputs.indices {
            inputs[index].position = index
        }
    }

    private static func freshAttempt(
        turnID: String,
        workMode: WorkMode,
        runtimeSnapshot: String = "",
        targetBindingSnapshot: TargetBinding? = nil,
        targetRuntimeGeneration: UInt64? = nil,
        terminalModeSnapshot: String? = nil,
        agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory? = nil,
        localAgentExecutionProfileSnapshot: String? = nil,
        runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot? = nil,
        configurationRevisionDigest: String? = nil,
        policySnapshot: String = "",
        toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot? = nil,
        toolCapabilitySnapshot: String = "",
        toolCatalogRevision: String? = nil,
        instructionSnapshot: String = "",
        instructionDigest: String? = nil,
        usageBudgetSnapshot: String? = nil,
        pricingCatalogRevision: String? = nil,
        purpose: AttemptPurpose = .initial,
        ordinal: Int = 1,
        id: String = "a-1"
    ) -> TurnAttempt {
        TurnAttempt(
            id: id,
            turnID: turnID,
            ordinal: ordinal,
            phase: .preparing,
            purpose: purpose,
            runtimeSnapshot: runtimeSnapshot,
            workModeSnapshot: workMode,
            policySnapshot: policySnapshot,
            toolAuthorizationPolicySnapshot: toolAuthorizationPolicySnapshot,
            toolCapabilitySnapshot: toolCapabilitySnapshot,
            toolCatalogRevision: toolCatalogRevision,
            instructionSnapshot: instructionSnapshot,
            instructionDigest: instructionDigest,
            usageBudgetSnapshot: usageBudgetSnapshot,
            pricingCatalogRevision: pricingCatalogRevision,
            targetBindingSnapshot: targetBindingSnapshot,
            terminalModeSnapshot: terminalModeSnapshot,
            targetRuntimeGeneration: targetRuntimeGeneration,
            agentProcessWorkingDirectorySnapshot: agentProcessWorkingDirectorySnapshot,
            localAgentExecutionProfileSnapshot: localAgentExecutionProfileSnapshot,
            runtimeAuthenticationSnapshot: runtimeAuthenticationSnapshot,
            runtimeAuthenticationDigest: runtimeAuthenticationSnapshot?.digest,
            configurationRevisionDigest: configurationRevisionDigest,
            startedAt: Date(timeIntervalSince1970: 0) // 时间由事件携带；此处占位，持久层回填
        )
    }

    private static func appendToolProposals(
        payload: Data,
        state: inout ConversationSessionState,
        attemptID: String
    ) {
        let decoded = EventPayloadCodec.decode(ConversationToolProposalBatchPayload.self, from: payload)
        let fallbackOrdinal = (state.activeAttempt?.nextArbitrationOrdinal ?? 0) + 1
        let source = decoded?.proposals ?? [ConversationToolProposalPayload(
            proposalID: "tc-\(fallbackOrdinal)",
            invocationID: "inv-1",
            batchID: "batch-1",
            ordinal: fallbackOrdinal,
            command: String(data: payload, encoding: .utf8) ?? "",
            explanation: "AI 建议执行此命令。",
            risk: "readOnly",
            targetRuntimeID: state.session.targetBinding.connectionID,
            targetTitle: state.session.targetBinding.remoteIdentity
        )]
        guard source.isEmpty == false else { return }
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            for item in source {
                guard item.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      current.toolProposalQueue.contains(where: { $0.id == item.proposalID }) == false
                else { continue }
                let proposal = ToolProposal(
                    id: item.proposalID,
                    invocationID: item.invocationID,
                    batchID: item.batchID,
                    sourceChildTaskID: nil,
                    ordinal: item.ordinal,
                    arbitrationOrdinal: current.nextArbitrationOrdinal + 1,
                    sourceToolCallID: item.proposalID,
                    immutableOperation: item.command,
                    operationDigest: operationDigest(item.command),
                    state: .queued,
                    decisionID: nil,
                    effectID: nil,
                    terminalExecutionID: nil,
                    result: nil,
                    error: nil
                )
                current.toolProposalQueue.append(proposal)
                current.nextArbitrationOrdinal += 1
            }
            if current.activeToolProposalID == nil {
                current.activeToolProposalID = current.toolProposalQueue.first(where: { $0.state == .queued })?.id
            }
        }
    }

    private static func activateToolProposal(
        payload: Data,
        state: inout ConversationSessionState,
        attemptID: String,
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let activation = EventPayloadCodec.decode(ToolProposalActivationPayload.self, from: payload),
              let attempt = state.activeAttempt,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == activation.proposalID }),
              proposal.state == .queued
        else {
            reject(state: state, kind: .toolProposalActivated, reason: "queued tool proposal is missing", invalid: &invalid)
            return
        }
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            current.activeToolProposalID = activation.proposalID
        }
    }

    private static func resolveActiveProposal(
        state: inout ConversationSessionState,
        attemptID: String,
        to target: ToolProposalState,
        approvalSource: ToolProposalApprovalSource? = nil
    ) {
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            guard let proposalID = current.activeToolProposalID,
                  let index = current.toolProposalQueue.firstIndex(where: { $0.id == proposalID })
            else { return }
            current.toolProposalQueue[index].state = target
            if let approvalSource {
                current.toolProposalQueue[index].approvalSource = approvalSource
            }
            if target == .resolved || target == .cancelled {
                current.activeToolProposalID = nil
            }
        }
    }

    private static func settleActiveProposal(
        payload: Data,
        state: inout ConversationSessionState,
        attemptID: String,
        target: ToolProposalState
    ) {
        let resolution = EventPayloadCodec.decode(ToolProposalResolutionPayload.self, from: payload)
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            let proposalID = resolution?.proposalID ?? current.activeToolProposalID
            guard let proposalID,
                  let index = current.toolProposalQueue.firstIndex(where: { $0.id == proposalID })
            else { return }
            current.toolProposalQueue[index].state = target
            current.toolProposalQueue[index].result = resolution?.result
            current.toolProposalQueue[index].error = resolution?.error
            if current.activeToolProposalID == proposalID {
                current.activeToolProposalID = nil
            }
        }
    }

    private static func operationDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func appendModelInvocation(
        payload: Data,
        state: inout ConversationSessionState,
        attemptID: String,
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let started = EventPayloadCodec.decode(ModelInvocationStartedPayload.self, from: payload),
              started.invocationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              started.contextSnapshotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              started.contextDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              started.runtimeCapabilitySnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let current = state.activeAttempt,
              current.id == attemptID,
              current.modelInvocations.contains(where: { $0.id == started.invocationID }) == false,
              current.modelInvocations.contains(where: { $0.endedAt == nil }) == false,
              started.ordinal == current.modelInvocations.count + 1
        else {
            reject(
                state: state,
                kind: .modelInvocationStarted,
                reason: "invalid or duplicate model invocation start",
                invalid: &invalid
            )
            return
        }
        let invocation = ModelInvocation(
            id: started.invocationID,
            attemptID: attemptID,
            ordinal: started.ordinal,
            childTaskID: nil,
            providerRequestAttemptIDs: [],
            localAgentSessionID: nil,
            contextSnapshotID: started.contextSnapshotID,
            contextDigest: started.contextDigest,
            runtimeCapabilitySnapshot: started.runtimeCapabilitySnapshot,
            startedAt: started.startedAt,
            endedAt: nil,
            usage: nil,
            outcome: nil
        )
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            current.modelInvocations.append(invocation)
        }
    }

    private static func completeModelInvocation(
        payload: Data,
        state: inout ConversationSessionState,
        attemptID: String,
        invalid: inout [InvalidTransitionRecord]
    ) {
        guard let completed = EventPayloadCodec.decode(ModelInvocationCompletedPayload.self, from: payload),
              completed.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let current = state.activeAttempt,
              current.id == attemptID,
              let index = current.modelInvocations.firstIndex(where: { $0.id == completed.invocationID }),
              current.modelInvocations[index].endedAt == nil,
              completed.endedAt >= current.modelInvocations[index].startedAt
        else {
            reject(
                state: state,
                kind: .modelInvocationCompleted,
                reason: "invalid model invocation completion",
                invalid: &invalid
            )
            return
        }
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            current.modelInvocations[index].endedAt = completed.endedAt
            current.modelInvocations[index].usage = completed.usage
            current.modelInvocations[index].outcome = completed.outcome
        }
    }

    private static func appendDecision(
        state: inout ConversationSessionState,
        kind: DecisionKind,
        attemptID: String,
        proposalID: String? = nil,
        resumePhase: AttemptPhase,
        decisionID: String? = nil,
        requestDigest: String = "",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        deadline: Date? = nil,
        allowedResolutionSchema: String? = nil
    ) {
        let decision = Decision(
            id: decisionID ?? "d-\(state.decisions.count + 1)",
            attemptID: attemptID,
            proposalID: proposalID,
            requestID: nil,
            kind: kind,
            state: .pending,
            requestDigest: requestDigest,
            resumePhase: resumePhase,
            createdAt: createdAt,
            deadline: deadline,
            allowedResolutionSchema: allowedResolutionSchema,
            nonSensitiveResponse: nil,
            resolvedAt: nil,
            resolutionSource: nil,
            resolutionDigest: nil
        )
        state.decisions[decision.id] = decision
        mutateAttempt(state: &state, attemptID: attemptID) { current in
            current.pendingDecisionIDs.append(decision.id)
            if let proposalID,
               let index = current.toolProposalQueue.firstIndex(where: { $0.id == proposalID }) {
                current.toolProposalQueue[index].decisionID = decision.id
            }
        }
    }

    @discardableResult
    private static func appendApprovalDecision(
        payload: Data,
        state: inout ConversationSessionState,
        attemptID: String,
        invalid: inout [InvalidTransitionRecord]
    ) -> Bool {
        guard payload.isEmpty == false else {
            appendDecision(
                state: &state,
                kind: .operationApproval,
                attemptID: attemptID,
                proposalID: state.activeAttempt?.activeToolProposalID,
                resumePhase: .executingTool
            )
            return true
        }
        guard let request = EventPayloadCodec.decode(ApprovalRequestedPayload.self, from: payload),
              request.decisionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              request.proposalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              request.requestDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              request.allowedResolutionSchema == "operationApproval/v1",
              request.deadline >= request.createdAt,
              state.decisions[request.decisionID] == nil,
              let attempt = state.activeAttempt,
              attempt.id == attemptID,
              attempt.activeToolProposalID == request.proposalID,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == request.proposalID }),
              proposal.operationDigest == request.requestDigest
        else {
            reject(
                state: state,
                kind: .approvalRequested,
                reason: "invalid approval request payload",
                invalid: &invalid
            )
            return false
        }
        appendDecision(
            state: &state,
            kind: .operationApproval,
            attemptID: attemptID,
            proposalID: request.proposalID,
            resumePhase: .executingTool,
            decisionID: request.decisionID,
            requestDigest: request.requestDigest,
            createdAt: request.createdAt,
            deadline: request.deadline,
            allowedResolutionSchema: request.allowedResolutionSchema
        )
        return true
    }

    private static func settleDecision(
        state: inout ConversationSessionState,
        decisionID: String,
        to outcome: DecisionState,
        source: String
    ) {
        guard var decision = state.decisions[decisionID] else { return }
        decision.state = outcome
        decision.resolutionSource = source
        decision.resolvedAt = Date(timeIntervalSince1970: 0)
        state.decisions[decisionID] = decision
        if let attemptID = state.activeAttempt?.id {
            mutateAttempt(state: &state, attemptID: attemptID) { current in
                current.pendingDecisionIDs.removeAll { $0 == decisionID }
            }
        }
    }
}
