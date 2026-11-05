import Foundation

// MARK: - 事件写入保证分档（规格 §8.3）

public enum ConversationEventWriteClass: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ephemeral        // 逐 token 增量，只用于当前进程投影，不逐条落盘
    case checkpoint       // 合并后的流式 Markdown/终端尾部检查点，可持久化
    case durable          // 用户输入/Turn/Attempt/Decision/Effect/终态，必须提交成功后才产生外部副作用
}

// MARK: - 事件 scope（session / turn / attempt）

public enum ConversationEventScope: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case session
    case turn
    case attempt
}

// MARK: - TerminalEventProviding（终态事件强制字段，规格 §8.3）

/// 所有 terminal 终态事件必须携带的字段；缺失即编译失败。
public protocol TerminalEventProviding {
    var attemptID: String { get }
    var phaseAtTermination: AttemptPhase { get }
    var reasonCode: AttemptReasonCode { get }
    var effectReconciliationState: String { get }
    var admissionSettlementID: String { get }
    var idempotencyKey: String { get }
}

// MARK: - durable 事件种类（规格 §8.3 清单；终端终态由 TerminalEventProviding 强制）

public enum ConversationEventKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    // 会话
    case sessionCreated
    case sessionBindingChanged
    case runtimeSelectionChanged
    case branchCreated
    case sessionMetadataChanged
    // 草稿与队列
    case draftChanged
    case queueAutoAdvanceChanged
    case queuedInputAdded
    case queuedInputEdited
    case queuedInputMoved
    case queuedInputRemoved
    // Turn/Attempt/Admission
    case turnSubmitted
    case admissionRequested
    case admissionGranted
    case admissionCancelled
    case admissionInterrupted
    case admissionWaitExpired
    case admissionOrphanedRuntime
    case admissionReleased
    case attemptStarted
    case attemptSupersedeRequested
    case attemptCompleted
    case attemptFailed
    case attemptCancelled
    case attemptTakenOver
    case attemptInterruptedByRelaunch
    case modelInvocationStarted
    case modelInvocationCompleted
    case runtimeStartRequested
    case runtimeStarted
    /// 终端透传输入已写入 PTY；不等同于 Local Agent 任务完成。
    case localAgentInputDelivered
    case executionTimeExpired
    case pauseRequested
    case pauseRejected
    case paused
    case resumeRequested
    case resumed
    // Regeneration / authority / answer-only
    case regenerationIntentQueued
    case regenerationIntentSuperseded
    case regenerationIntentMaterialized
    case executionAuthorityIssued
    case executionAuthorityRevoking
    case executionAuthorityRevoked
    case executionAuthoritySettled
    case answerOnlyLaunchCapabilityIssued
    case answerOnlyLaunchCapabilityLaunching
    case answerOnlyLaunchCapabilityActivated
    case answerOnlyLaunchCapabilityRevoking
    case answerOnlyLaunchCapabilitySettling
    case answerOnlyLaunchCapabilityOrphaned
    case answerOnlyLaunchCapabilitySettled
    case reasoningSummaryUpdated
    case planUpdated
    case usageUpdated
    case usageLimitReached
    case usageLimitExtended
    case canonicalWriteLeaseIssued
    case canonicalWriteLeaseSuperseded
    case canonicalWriteLeaseCancelled
    case finalAnswerDelta
    case finalAnswerCompleted
    case finalAnswerSuperseded
    // Tool / Decision / Approval
    case toolProposalQueued
    case toolProposalArbitrated
    case toolProposalActivated
    case toolProposed
    case toolProposalResolved
    case toolProposalCancelled
    case approvalNotRequired
    case approvalRequested
    case approvalResolved
    case planApproved
    case userInputRequested
    case sensitiveInputRequested
    case userInputResolved
    case decisionExpired
    // Effect / Lease / Reconciliation
    case effectCommandEnqueued
    case effectCommandDispatched
    case externalEffectStateUnknown
    case externalEffectReconciled
    case reconciliationLockCreated
    case reconciliationLockResolved
    case toolStarted
    case terminalLeaseChanged
    case secureInputLeaseChanged
    case credentialUseLeaseAcquired
    case credentialUseLeaseReleased
    case leaseIsolationConfirmed
    case terminalOutputCheckpointed
    case toolCompleted
    // Child / Artifact / Context / Memory
    case childTaskStarted
    case childTaskUpdated
    case childTaskCompleted
    case artifactProduced
    case contextSummarized
    case memoryProposed
    case memoryResolved
    // Snapshot / Compaction / 恢复
    case snapshotCreated
    case compactionCommitted
    case interruptRequested
    case stopping
    case takeoverRequested
    case takeoverDeclined
    case resumeAttemptCreated
    case localAgentProcessOrphaned
    case sequenceGapDetected
    case conversationCorrupted
}

// MARK: - canonical envelope（规格 §7/§8.3）

public struct ConversationEventEnvelope: Codable, Equatable, Hashable, Sendable {
    public var eventID: String
    public var conversationID: String
    public var scope: ConversationEventScope
    public var turnID: String?
    public var attemptID: String?
    public var candidateSequence: Int
    public var source: String
    public var timestamp: Date
    public var kind: ConversationEventKind
    public var writeClass: ConversationEventWriteClass
    public var payloadHash: String
    public var visibility: String
    public var payload: Data

    public init(
        eventID: String, conversationID: String, scope: ConversationEventScope,
        turnID: String? = nil, attemptID: String? = nil, candidateSequence: Int,
        source: String, timestamp: Date, kind: ConversationEventKind,
        writeClass: ConversationEventWriteClass, payloadHash: String,
        visibility: String = "session", payload: Data
    ) {
        self.eventID = eventID
        self.conversationID = conversationID
        self.scope = scope
        self.turnID = turnID
        self.attemptID = attemptID
        self.candidateSequence = candidateSequence
        self.source = source
        self.timestamp = timestamp
        self.kind = kind
        self.writeClass = writeClass
        self.payloadHash = payloadHash
        self.visibility = visibility
        self.payload = payload
    }
}

/// Actor 提交前的 EventDraft（携带预期序列，供 Reducer/持久层校验）
public struct EventDraft: Sendable {
    public var envelope: ConversationEventEnvelope
    public var expectedLastSequence: Int

    public init(envelope: ConversationEventEnvelope, expectedLastSequence: Int) {
        self.envelope = envelope
        self.expectedLastSequence = expectedLastSequence
    }
}

// MARK: - Durable draft and queued-input payloads

/// First durable event for a V2 conversation. The complete session descriptor
/// is encrypted with the event payload so replay never depends on whichever
/// terminal happens to be focused after an app relaunch.
public struct ConversationSessionCreatedPayload: Codable, Equatable, Sendable {
    public let session: ConversationSession

    public init(session: ConversationSession) {
        self.session = session
    }
}

/// Compare-and-swap metadata update. Titles, pin state and archive state remain
/// encrypted and are never copied into the plaintext SQLite session index.
public struct ConversationSessionMetadataChangedPayload: Codable, Equatable, Sendable {
    public let expectedRevision: Int
    public let title: String
    public let pinned: Bool
    public let archivedAt: Date?

    public init(expectedRevision: Int, title: String, pinned: Bool, archivedAt: Date?) {
        self.expectedRevision = expectedRevision
        self.title = title
        self.pinned = pinned
        self.archivedAt = archivedAt
    }
}

/// `turnSubmitted` 的可选结构化载荷。
///
/// 旧版本只把用户文本写入事件 payload，因此解码时必须保留 UTF-8 fallback。
/// 新版本在同一个 durable 事件中冻结本轮的 Runtime、工作方式、目标和终端模式，
/// 这样队列提升、重启 replay 和外部执行都不会读取之后被用户修改的 Composer 状态。
public struct TurnSubmittedPayload: Codable, Equatable, Sendable {
    public let text: String
    public let runtimeSelection: AgentRuntimeSelection?
    public let targetBinding: TargetBinding?
    public let targetRuntimeGeneration: UInt64?
    public let terminalMode: String?
    public let ordinal: Int?
    public let runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot?
    public let configurationRevisionDigest: String?
    public let agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory?
    public let runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot?
    public let toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot?
    public let toolCapabilitySnapshot: ToolCapabilitySnapshot?

    public init(
        text: String,
        runtimeSelection: AgentRuntimeSelection? = nil,
        targetBinding: TargetBinding? = nil,
        targetRuntimeGeneration: UInt64? = nil,
        terminalMode: String? = nil,
        ordinal: Int? = nil,
        runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot? = nil,
        configurationRevisionDigest: String? = nil,
        agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory? = nil,
        runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot? = nil,
        toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot? = nil,
        toolCapabilitySnapshot: ToolCapabilitySnapshot? = nil
    ) {
        self.text = text
        self.runtimeSelection = runtimeSelection
        self.targetBinding = targetBinding
        self.targetRuntimeGeneration = targetRuntimeGeneration
        self.terminalMode = terminalMode
        self.ordinal = ordinal
        self.runtimeAuthenticationSnapshot = runtimeAuthenticationSnapshot
        self.configurationRevisionDigest = configurationRevisionDigest
        self.agentProcessWorkingDirectorySnapshot = agentProcessWorkingDirectorySnapshot
        self.runtimeSettingsSnapshot = runtimeSettingsSnapshot
        self.toolAuthorizationPolicySnapshot = toolAuthorizationPolicySnapshot
        self.toolCapabilitySnapshot = toolCapabilitySnapshot
    }
}

/// Session 级 Runtime 选择。切换只影响下一轮，活动 Attempt 继续使用自己的快照。
public struct RuntimeSelectionChangedPayload: Codable, Equatable, Sendable {
    public let selection: AgentRuntimeSelection

    public init(selection: AgentRuntimeSelection) {
        self.selection = selection
    }
}

/// PTY 投递终态的最小、非敏感证据。用户正文已经由 `turnSubmitted` 加密保存，
/// 此事件不重复正文，也不采集 PTY 输出。
public struct LocalAgentInputDeliveredPayload: Codable, Equatable, Sendable, TerminalEventProviding {
    public let attemptID: String
    public let phaseAtTermination: AttemptPhase
    public let reasonCode: AttemptReasonCode
    public let effectReconciliationState: String
    public let admissionSettlementID: String
    public let idempotencyKey: String
    public let deliveryID: String
    public let byteCount: Int
    public let configurationRevisionDigest: String

    public init(
        attemptID: String,
        admissionSettlementID: String,
        idempotencyKey: String,
        deliveryID: String,
        byteCount: Int,
        configurationRevisionDigest: String
    ) {
        self.attemptID = attemptID
        self.phaseAtTermination = .streaming
        self.reasonCode = .passthroughInputDelivered
        self.effectReconciliationState = "settled"
        self.admissionSettlementID = admissionSettlementID
        self.idempotencyKey = idempotencyKey
        self.deliveryID = deliveryID
        self.byteCount = byteCount
        self.configurationRevisionDigest = configurationRevisionDigest
    }
}

public struct QueueAutoAdvanceChangedPayload: Codable, Equatable, Sendable {
    public let paused: Bool

    public init(paused: Bool) {
        self.paused = paused
    }
}

public struct QueuedInputAddedPayload: Codable, Equatable {
    public let input: QueuedInput

    public init(input: QueuedInput) {
        self.input = input
    }
}

public struct QueuedInputEditedPayload: Codable, Equatable {
    public let expectedRevision: Int
    public let input: QueuedInput

    public init(expectedRevision: Int, input: QueuedInput) {
        self.expectedRevision = expectedRevision
        self.input = input
    }
}

public struct QueuedInputMovedPayload: Codable, Equatable, Sendable {
    public let inputID: String
    public let expectedRevision: Int
    public let destination: Int

    public init(inputID: String, expectedRevision: Int, destination: Int) {
        self.inputID = inputID
        self.expectedRevision = expectedRevision
        self.destination = destination
    }
}

public struct QueuedInputRemovedPayload: Codable, Equatable, Sendable {
    public let inputID: String
    public let expectedRevision: Int

    public init(inputID: String, expectedRevision: Int) {
        self.inputID = inputID
        self.expectedRevision = expectedRevision
    }
}

/// Stable scheduler identity carried by admission lifecycle events. These
/// values are non-sensitive and let replay/diagnostics correlate the session
/// event stream with the global durable scheduler without guessing IDs.
public struct AdmissionRequestedPayload: Codable, Equatable, Sendable {
    public let requestID: String
    public let attemptID: String
    public let schedulerGeneration: Int
    public let queueOrdinal: Int
    public let enqueuedAt: Date
    public let waitTimeoutSeconds: TimeInterval

    public init(
        requestID: String,
        attemptID: String,
        schedulerGeneration: Int,
        queueOrdinal: Int,
        enqueuedAt: Date,
        waitTimeoutSeconds: TimeInterval
    ) {
        self.requestID = requestID
        self.attemptID = attemptID
        self.schedulerGeneration = schedulerGeneration
        self.queueOrdinal = queueOrdinal
        self.enqueuedAt = enqueuedAt
        self.waitTimeoutSeconds = waitTimeoutSeconds
    }
}

public struct AdmissionGrantedPayload: Codable, Equatable, Sendable {
    public let requestID: String
    public let leaseID: String
    public let attemptID: String
    public let schedulerGeneration: Int
    public let settlementID: String
    public let acquiredAt: Date

    public init(lease: GlobalExecutionAdmissionLease) {
        requestID = lease.requestID
        leaseID = lease.leaseID
        attemptID = lease.attemptID
        schedulerGeneration = lease.schedulerGeneration
        settlementID = lease.settlementID
        acquiredAt = lease.acquiredAt
    }
}

public struct AdmissionResolvedPayload: Codable, Equatable, Sendable {
    public let requestID: String
    public let leaseID: String?
    public let attemptID: String
    public let schedulerGeneration: Int
    public let resolvedAt: Date
    public let reason: String

    public init(
        requestID: String,
        leaseID: String?,
        attemptID: String,
        schedulerGeneration: Int,
        resolvedAt: Date,
        reason: String
    ) {
        self.requestID = requestID
        self.leaseID = leaseID
        self.attemptID = attemptID
        self.schedulerGeneration = schedulerGeneration
        self.resolvedAt = resolvedAt
        self.reason = reason
    }
}

// MARK: - 事件应用规则（规格 §8.3）

public enum EventApplicationOutcome: Equatable {
    case applied
    case duplicateIgnored
    case futureBuffered(gapFrom: Int, gapTo: Int)
    case corrupted(reason: String)
}

public enum ConversationEventApplicator {
    /// 根据 lastApplied 与持久层事件应用规则判定结果。
    /// - 相同 eventID 重复投递 → 幂等忽略
    /// - sequence == lastApplied+1 → 应用
    /// - sequence > lastApplied+1 → 有界 future buffer（补齐缺口前不投影后续状态）
    /// - 同 sequence 但不同 eventID/hash → conversationCorrupted（只读隔离）
    public static func apply(
        envelope: ConversationEventEnvelope,
        lastApplied: Int,
        existingEventIDAtSequence: String?,
        existingPayloadHashAtSequence: String?
    ) -> EventApplicationOutcome {
        if let existingID = existingEventIDAtSequence {
            if existingID == envelope.eventID,
               existingPayloadHashAtSequence == envelope.payloadHash {
                return .duplicateIgnored
            }
            return .corrupted(reason: "same sequence with different event/hash")
        }
        if envelope.candidateSequence == lastApplied + 1 {
            return .applied
        }
        if envelope.candidateSequence > lastApplied + 1 {
            return .futureBuffered(gapFrom: lastApplied + 1, gapTo: envelope.candidateSequence - 1)
        }
        return .corrupted(reason: "sequence already consumed or out of order")
    }
}
