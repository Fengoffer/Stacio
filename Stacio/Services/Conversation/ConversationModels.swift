import Foundation

// MARK: - 关闭枚举（规格 §8.1/8.2/8.3）

/// Attempt 阶段（关闭集合；终态以 AttemptOutcome 表达，本枚举含终态阶段便于投影）
public enum AttemptPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case preparing
    case waitingForCapacity
    case startingRuntime
    case streaming
    case toolProposed
    case awaitingApproval
    case executingTool
    case awaitingUser
    case pausing
    case paused
    case takeoverPending
    case stopping
    // 终态
    case completed
    case failed
    case cancelled
    case takenOver
    case interruptedByRelaunch
    /// 终端透传只证明 Composer 输入已写入受管 PTY；不代表第三方 Agent 任务完成。
    case passthroughInputDelivered

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .takenOver, .interruptedByRelaunch,
             .passthroughInputDelivered:
            return true
        default:
            return false
        }
    }
}

/// Attempt 终态 outcome（关闭集合）
public enum AttemptOutcome: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case completed
    case failed
    case cancelled
    case takenOver
    case interruptedByRelaunch
    /// 只表示输入投递完成，不授予 canonical answer 或任务完成语义。
    case passthroughInputDelivered
}

/// 终态 reasonCode（稳定 lowerCamel 标识，UI 显示中文标题；规格 §8.3 表）
public enum AttemptReasonCode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case completed
    case capacityWaitExpired
    case featureFlagDraining
    case executionTimeExpired
    case credentialRevoked
    case credentialUnavailable
    case configurationInvalid
    case catalogInvalid
    case targetChanged
    case containmentInvalid
    case authenticationFailed
    case modelUnavailable
    case runtimeStartFailed
    case providerRequestFailed
    case modelInvocationLimitReached
    case protocolError
    case toolExecutionFailed
    case terminalDisconnected
    case userInputWaitExpired
    case sensitiveInputRequired
    case stopFailed
    case takeoverTransferFailed
    case takenOver
    case interruptedByRelaunch
    case runtimeStateUnknown
    case cancelled
    case passthroughInputDelivered
}

/// 工作方式（硬权限语义，规格 §12.7）
public enum WorkMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case agent
    case plan
    case answerOnly
}

/// RuntimeAuthenticationSnapshot 四种 mode（关闭合同，空 generation 数组 ≠ noneVerified）
public enum RuntimeAuthenticationMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case stacioCredentialBindings
    case cliManagedAuthentication
    case combined
    case noneVerified
}

/// AgentRuntimeSelection 类型
public enum AgentRuntimeSelectionKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case nativeAPI
    case localAgent
}

/// Local Agent 执行 profile kind（由 profile 派生，不是可迁移身份）
public enum LocalAgentExecutionProfileKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case managed
    case terminalPassthrough
    case none
}

/// ToolProposal 状态（关闭集合）
public enum ToolProposalState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case queued
    case evaluating
    case awaitingApproval
    case executing
    case resolved
    case cancelled
}

/// Durable authority that moved a proposal into execution. This is projected
/// only from a validated approval event and survives event replay/outbox retry.
public enum ToolProposalApprovalSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case userApproved
    case policyAutoAllowed
}

/// Decision 种类与状态（关闭集合）
public enum DecisionKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case planApproval
    case operationApproval
    case userInput
    case secureInput
    case usageExtension
}

public enum DecisionState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case approved
    case denied
    case answered
    case skipped
    case expired
    case cancelled
}

/// QueuedInput 重校验状态（关闭集合）
public enum QueuedInputRevalidationState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case valid
    case needsRebind
    case needsSelection
    case blocked
}

/// 全局 Admission request/lease 状态（关闭集合）
public enum GlobalExecutionAdmissionRequestState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case queued
    case granted
    case cancelled
    case interrupted
}

public enum GlobalExecutionAdmissionLeaseState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case granted
    case active
    case releasing
    case released
    case orphanedRuntime
    case isolated
}

/// External Effect reconciliation 状态与证据强度
public enum ExternalEffectReconciliationState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case unknown
    case verifiedCompleted
    case verifiedFailed
    case isolated
}

public enum ReconciliationEvidenceStrength: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case none
    case structured
    case readOnly
    case userAttested
}

/// TerminalRuntimeLease 状态
public enum TerminalRuntimeLeaseState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case granted
    case active
    case releasing
    case released
    case orphaned
}

/// agentConversationV2 三态控制面（规格 §18.4）
public enum AgentConversationV2ControlState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case enabled
    case draining
    case disabled
}

public enum V2AdmissionGate: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case open
    case closed
}

public enum V2ControlPermitState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case issued
    case prepared
    case commitAuthorized
    case settling
    case settledCommitted
    case settledAborted
}

public enum V2ControlTargetJournalState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case prepared
    case committing
    case committed
    case aborting
    case aborted
    case reconciliationRequired
}

/// Credential generation 生命周期状态（关闭集合，权威在 CredentialLifecycleStore）
public enum CredentialGenerationLifecycleState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pendingActivation
    case active
    case retired
    case revoked
    case abandoned
}

public enum SecretAvailability: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case present
    case pendingDeletion
    case deleted
}

public enum CredentialSetupOperationState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case open
    case suspended
    case discardRequested
    case activating
    case completed
    case abandoned
}

public enum CredentialSetupPendingRetention: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ephemeralSetup
    case savedDraft
}

public enum CredentialAttemptBindingState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case reserved
    case commitPending
    case committed
    case releasing
    case released
    case quarantined
}

public enum CredentialUseLeaseState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case requested
    case granted
    case releasing
    case released
    case denied
    case revoked
}

public enum CredentialUseLeaseOwner: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case attempt
    case setup
    case configurationAction
}

public enum ConfigurationVerificationRequestState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case prepared
    case inFlight
    case cancellationRequested
    case settledSucceeded
    case settledFailed
    case settledCancelled
    case stateUnknown

    public var isTerminal: Bool {
        switch self {
        case .settledSucceeded, .settledFailed, .settledCancelled, .stateUnknown:
            return true
        default:
            return false
        }
    }
}

public enum CredentialAccessMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case setupPending
    case activeConfiguration
    case none
}

/// RegenerationIntent 相关关闭枚举
public enum RegenerationIntentKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case answerOnly
    case rerunTask
}

public enum RegenerationIntentState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case waitingForPriorSettlement
    case materialized
    case superseded
    case cancelled
}

public enum RegenerationConfigurationMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case sameSnapshot
    case reviewedCurrent
}

public enum CanonicalFinalAnswerState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case none
    case available
    case regenerating
}

public enum AttemptExecutionAuthorityLeaseState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case active
    case revoking
    case revoked
    case settled
}

public enum AnswerOnlyLaunchCapabilityState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case issued
    case launching
    case active
    case revoking
    case settling
    case orphaned
    case settled
}

public enum AnswerOnlyLaunchKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case answerOnlyTurn
    case answerRegeneration
}

public enum LocalAgentSettingsProcessState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case prepared
    case starting
    case running
    case stopping
    case stateUnknown
    case completed
    case failed
    case cancelled
    case isolated

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .isolated:
            return true
        default:
            return false
        }
    }
}

public enum LocalAgentSettingsProcessSettlement: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pending
    case exited
    case isolated
    case unknown
}

// MARK: - 领域模型（规格 §8.1/8.2）

/// 会话稳定目标绑定（与临时 runtimeID 分离）
public struct TargetBinding: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var revision: Int
    public var digest: String
    public var connectionID: String
    public var connectionKind: String
    public var remoteIdentity: String
    public var hostKeyFingerprint: String?
    public var host: String
    public var user: String
    public var port: Int
    public var targetWorkingDirectory: String

    public init(
        id: String, revision: Int, digest: String, connectionID: String, connectionKind: String,
        remoteIdentity: String, hostKeyFingerprint: String?, host: String, user: String,
        port: Int, targetWorkingDirectory: String
    ) {
        self.id = id
        self.revision = revision
        self.digest = digest
        self.connectionID = connectionID
        self.connectionKind = connectionKind
        self.remoteIdentity = remoteIdentity
        self.hostKeyFingerprint = hostKeyFingerprint
        self.host = host
        self.user = user
        self.port = port
        self.targetWorkingDirectory = targetWorkingDirectory
    }
}

/// Runtime 选择（决定“由谁推理”）
public struct AgentRuntimeSelection: Codable, Equatable, Hashable, Sendable {
    public var kind: AgentRuntimeSelectionKind
    public var providerConfigurationID: String?
    public var codingPlanConfigurationID: String?
    public var localAgentConfigurationID: String?
    public var localAgentExecutionProfileID: String?
    public var localAgentExecutionProfileKind: LocalAgentExecutionProfileKind
    public var modelID: String?
    public var reasoningEffort: String?
    public var workMode: WorkMode
    public var revision: Int

    public init(
        kind: AgentRuntimeSelectionKind,
        providerConfigurationID: String? = nil,
        codingPlanConfigurationID: String? = nil,
        localAgentConfigurationID: String? = nil,
        localAgentExecutionProfileID: String? = nil,
        localAgentExecutionProfileKind: LocalAgentExecutionProfileKind = .none,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        workMode: WorkMode = .agent,
        revision: Int = 1
    ) {
        self.kind = kind
        self.providerConfigurationID = providerConfigurationID
        self.codingPlanConfigurationID = codingPlanConfigurationID
        self.localAgentConfigurationID = localAgentConfigurationID
        self.localAgentExecutionProfileID = localAgentExecutionProfileID
        self.localAgentExecutionProfileKind = localAgentExecutionProfileKind
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.workMode = workMode
        self.revision = revision
    }
}

/// 本地 Agent 进程工作目录（与 targetWorkingDirectory 分离，绝不混用）
public enum AgentProcessWorkingDirectoryMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case managedWorkspace
    case userSelectedLocalDirectory
    case askEveryTurn
}

public enum AgentProcessTargetMapping: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case none
    case verifiedLocalTarget
}

public struct AgentProcessWorkingDirectory: Codable, Equatable, Hashable, Sendable {
    public var mode: AgentProcessWorkingDirectoryMode
    public var localPathReference: String?
    public var revision: Int?
    public var digest: String?
    public var allowedFilesystemScope: [String]
    public var targetMapping: AgentProcessTargetMapping

    public init(
        mode: AgentProcessWorkingDirectoryMode,
        localPathReference: String? = nil,
        revision: Int? = nil,
        digest: String? = nil,
        allowedFilesystemScope: [String] = [],
        targetMapping: AgentProcessTargetMapping = .none
    ) {
        self.mode = mode
        self.localPathReference = localPathReference
        self.revision = revision
        self.digest = digest
        self.allowedFilesystemScope = allowedFilesystemScope
        self.targetMapping = targetMapping
    }
}

/// 全局执行 Admission request/lease（唯一 Scheduler 写入）
public struct GlobalExecutionAdmissionRequest: Codable, Equatable, Hashable, Sendable {
    public var requestID: String
    public var sessionID: String
    public var turnID: String
    public var attemptID: String
    public var schedulerGeneration: Int
    public var queueOrdinal: Int
    public var enqueuedAt: Date
    public var state: GlobalExecutionAdmissionRequestState
    public var grantedLeaseID: String?
    public var resolvedAt: Date?
    public var resolutionReason: String?

    public init(
        requestID: String, sessionID: String, turnID: String, attemptID: String,
        schedulerGeneration: Int, queueOrdinal: Int, enqueuedAt: Date,
        state: GlobalExecutionAdmissionRequestState, grantedLeaseID: String? = nil,
        resolvedAt: Date? = nil, resolutionReason: String? = nil
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.turnID = turnID
        self.attemptID = attemptID
        self.schedulerGeneration = schedulerGeneration
        self.queueOrdinal = queueOrdinal
        self.enqueuedAt = enqueuedAt
        self.state = state
        self.grantedLeaseID = grantedLeaseID
        self.resolvedAt = resolvedAt
        self.resolutionReason = resolutionReason
    }
}

public struct GlobalExecutionAdmissionLease: Codable, Equatable, Hashable, Sendable {
    public var leaseID: String
    public var requestID: String
    public var sessionID: String
    public var turnID: String
    public var attemptID: String
    public var schedulerGeneration: Int
    public var acquiredAt: Date
    public var lastObservedAt: Date?
    public var releasedAt: Date?
    public var state: GlobalExecutionAdmissionLeaseState
    public var releaseReason: String?
    public var settlementID: String
    public var isolationEvidenceID: String?
    public var capacityReleasedAt: Date?

    public init(
        leaseID: String, requestID: String, sessionID: String, turnID: String, attemptID: String,
        schedulerGeneration: Int, acquiredAt: Date, lastObservedAt: Date? = nil,
        releasedAt: Date? = nil, state: GlobalExecutionAdmissionLeaseState,
        releaseReason: String? = nil, settlementID: String,
        isolationEvidenceID: String? = nil, capacityReleasedAt: Date? = nil
    ) {
        self.leaseID = leaseID
        self.requestID = requestID
        self.sessionID = sessionID
        self.turnID = turnID
        self.attemptID = attemptID
        self.schedulerGeneration = schedulerGeneration
        self.acquiredAt = acquiredAt
        self.lastObservedAt = lastObservedAt
        self.releasedAt = releasedAt
        self.state = state
        self.releaseReason = releaseReason
        self.settlementID = settlementID
        self.isolationEvidenceID = isolationEvidenceID
        self.capacityReleasedAt = capacityReleasedAt
    }
}

/// 已脱离 Runtime 但状态未知的外部 effect 冲突锁
public struct ExternalEffectReconciliationRecord: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var effectID: String
    public var attemptID: String
    public var targetBindingDigest: String
    public var resourceScope: [String]
    public var operationClass: String
    public var operationDigest: String
    public var terminalExecutionID: String?
    public var state: ExternalEffectReconciliationState
    public var blocksOperationClasses: [String]
    public var conflictKey: String
    public var lockOwnerID: String?
    public var evidenceReferences: [String]
    public var evidenceStrength: ReconciliationEvidenceStrength
    public var createdAt: Date
    public var reconciledAt: Date?
    public var resolutionReason: String?
    public var lockReleasedAt: Date?

    public init(
        id: String, effectID: String, attemptID: String, targetBindingDigest: String,
        resourceScope: [String], operationClass: String, operationDigest: String,
        terminalExecutionID: String? = nil, state: ExternalEffectReconciliationState,
        blocksOperationClasses: [String], conflictKey: String, lockOwnerID: String? = nil,
        evidenceReferences: [String], evidenceStrength: ReconciliationEvidenceStrength,
        createdAt: Date, reconciledAt: Date? = nil, resolutionReason: String? = nil,
        lockReleasedAt: Date? = nil
    ) {
        self.id = id
        self.effectID = effectID
        self.attemptID = attemptID
        self.targetBindingDigest = targetBindingDigest
        self.resourceScope = resourceScope
        self.operationClass = operationClass
        self.operationDigest = operationDigest
        self.terminalExecutionID = terminalExecutionID
        self.state = state
        self.blocksOperationClasses = blocksOperationClasses
        self.conflictKey = conflictKey
        self.lockOwnerID = lockOwnerID
        self.evidenceReferences = evidenceReferences
        self.evidenceStrength = evidenceStrength
        self.createdAt = createdAt
        self.reconciledAt = reconciledAt
        self.resolutionReason = resolutionReason
        self.lockReleasedAt = lockReleasedAt
    }
}

/// 终端运行时租约（带代次，与 TargetBinding 分离）
public struct TerminalRuntimeLease: Codable, Equatable, Hashable, Sendable {
    public var leaseID: String
    public var targetBindingID: String
    public var targetBindingDigest: String
    public var runtimeID: String
    public var terminalKind: String
    public var writerOwner: String
    public var leaseGeneration: Int
    public var reconnectGeneration: Int
    public var acquiredAt: Date
    public var expiresAt: Date?
    public var state: TerminalRuntimeLeaseState
    public var executionID: String?

    public init(
        leaseID: String, targetBindingID: String, targetBindingDigest: String, runtimeID: String,
        terminalKind: String, writerOwner: String, leaseGeneration: Int, reconnectGeneration: Int,
        acquiredAt: Date, expiresAt: Date? = nil, state: TerminalRuntimeLeaseState,
        executionID: String? = nil
    ) {
        self.leaseID = leaseID
        self.targetBindingID = targetBindingID
        self.targetBindingDigest = targetBindingDigest
        self.runtimeID = runtimeID
        self.terminalKind = terminalKind
        self.writerOwner = writerOwner
        self.leaseGeneration = leaseGeneration
        self.reconnectGeneration = reconnectGeneration
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.state = state
        self.executionID = executionID
    }
}

/// RuntimeAuthenticationSnapshot（四种 mode 的完整认证事实）
public struct RuntimeAuthenticationSnapshot: Codable, Equatable, Hashable, Sendable {
    public var mode: RuntimeAuthenticationMode
    public var configurationID: String?
    public var configurationRevision: Int?
    public var catalogSetRevision: String?
    public var descriptorRevision: String?
    public var normalizedModelOrigin: String?
    public var networkPolicyDigest: String?
    public var verificationFingerprint: String
    public var generationIDsByRole: [String: String]
    public var credentialAttemptBindingIDs: [String]
    public var cliAuthenticationScopeDigest: String?
    public var cliLoginIdentityDigest: String?
    public var authenticationEvidenceRevision: String?
    public var noCredentialProofDigest: String?
    public var permitsNoCredentialEvidenceRevision: String?
    public var createdAt: Date
    public var digest: String

    public init(
        mode: RuntimeAuthenticationMode, configurationID: String? = nil,
        configurationRevision: Int? = nil, catalogSetRevision: String? = nil,
        descriptorRevision: String? = nil, normalizedModelOrigin: String? = nil,
        networkPolicyDigest: String? = nil, verificationFingerprint: String,
        generationIDsByRole: [String: String] = [:], credentialAttemptBindingIDs: [String] = [],
        cliAuthenticationScopeDigest: String? = nil, cliLoginIdentityDigest: String? = nil,
        authenticationEvidenceRevision: String? = nil, noCredentialProofDigest: String? = nil,
        permitsNoCredentialEvidenceRevision: String? = nil, createdAt: Date, digest: String
    ) {
        self.mode = mode
        self.configurationID = configurationID
        self.configurationRevision = configurationRevision
        self.catalogSetRevision = catalogSetRevision
        self.descriptorRevision = descriptorRevision
        self.normalizedModelOrigin = normalizedModelOrigin
        self.networkPolicyDigest = networkPolicyDigest
        self.verificationFingerprint = verificationFingerprint
        self.generationIDsByRole = generationIDsByRole
        self.credentialAttemptBindingIDs = credentialAttemptBindingIDs
        self.cliAuthenticationScopeDigest = cliAuthenticationScopeDigest
        self.cliLoginIdentityDigest = cliLoginIdentityDigest
        self.authenticationEvidenceRevision = authenticationEvidenceRevision
        self.noCredentialProofDigest = noCredentialProofDigest
        self.permitsNoCredentialEvidenceRevision = permitsNoCredentialEvidenceRevision
        self.createdAt = createdAt
        self.digest = digest
    }
}

/// QueuedInput 与其冻结上下文快照
public enum QueuedInputContextSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case explicitUserChoice
    case sessionDefault
}

public struct QueuedInputContextSnapshot: Codable, Equatable, Hashable, Sendable {
    public var targetBindingSnapshot: TargetBinding
    public var targetRuntimeGeneration: UInt64?
    public var targetWorkingDirectory: String
    public var targetDigest: String
    public var runtimeSelectionSnapshot: AgentRuntimeSelection
    public var providerConfigurationID: String?
    public var codingPlanConfigurationID: String?
    public var modelID: String?
    public var runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot
    public var authenticationDigest: String
    public var configurationRevisionDigest: String
    public var workMode: WorkMode
    public var terminalMode: String?
    public var agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory?
    public var policyRevision: String?
    public var toolCatalogRevision: String?
    public var instructionDigest: String?
    public var runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot?
    public var toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot?
    public var capturedAt: Date
    public var source: QueuedInputContextSource

    public init(
        targetBindingSnapshot: TargetBinding, targetWorkingDirectory: String, targetDigest: String,
        targetRuntimeGeneration: UInt64? = nil,
        runtimeSelectionSnapshot: AgentRuntimeSelection, providerConfigurationID: String? = nil,
        codingPlanConfigurationID: String? = nil, modelID: String? = nil,
        runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot, authenticationDigest: String,
        configurationRevisionDigest: String, workMode: WorkMode, terminalMode: String? = nil,
        agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory? = nil,
        policyRevision: String? = nil, toolCatalogRevision: String? = nil,
        instructionDigest: String? = nil,
        runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot? = nil,
        toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot? = nil,
        capturedAt: Date, source: QueuedInputContextSource
    ) {
        self.targetBindingSnapshot = targetBindingSnapshot
        self.targetRuntimeGeneration = targetRuntimeGeneration
        self.targetWorkingDirectory = targetWorkingDirectory
        self.targetDigest = targetDigest
        self.runtimeSelectionSnapshot = runtimeSelectionSnapshot
        self.providerConfigurationID = providerConfigurationID
        self.codingPlanConfigurationID = codingPlanConfigurationID
        self.modelID = modelID
        self.runtimeAuthenticationSnapshot = runtimeAuthenticationSnapshot
        self.authenticationDigest = authenticationDigest
        self.configurationRevisionDigest = configurationRevisionDigest
        self.workMode = workMode
        self.terminalMode = terminalMode
        self.agentProcessWorkingDirectorySnapshot = agentProcessWorkingDirectorySnapshot
        self.policyRevision = policyRevision
        self.toolCatalogRevision = toolCatalogRevision
        self.instructionDigest = instructionDigest
        self.runtimeSettingsSnapshot = runtimeSettingsSnapshot
        self.toolAuthorizationPolicySnapshot = toolAuthorizationPolicySnapshot
        self.capturedAt = capturedAt
        self.source = source
    }
}

public struct QueuedInput: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var revision: Int
    public var position: Int
    public var text: String
    public var attachmentReferences: [String]
    public var contextSelection: String?
    public var contextSnapshot: QueuedInputContextSnapshot
    public var revalidationState: QueuedInputRevalidationState
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, sessionID: String, revision: Int, position: Int, text: String,
        attachmentReferences: [String] = [], contextSelection: String? = nil,
        contextSnapshot: QueuedInputContextSnapshot,
        revalidationState: QueuedInputRevalidationState = .valid,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.revision = revision
        self.position = position
        self.text = text
        self.attachmentReferences = attachmentReferences
        self.contextSelection = contextSelection
        self.contextSnapshot = contextSnapshot
        self.revalidationState = revalidationState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 规范最终答案与其 write lease（CAS 合同）
public struct CanonicalFinalAnswer: Codable, Equatable, Hashable, Sendable {
    public var attemptID: String
    public var revision: Int
    public var markdownSourceDigest: String
    public var state: CanonicalFinalAnswerState
    public var createdAt: Date
    public var completedAt: Date?
    public var lastKnownGood: Bool
}

public enum CanonicalFinalAnswerWriteLeaseState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case active
    case consumed
    case superseded
    case cancelled
}

public struct CanonicalFinalAnswerWriteLease: Codable, Equatable, Hashable, Sendable {
    public var leaseID: String
    public var turnID: String
    public var attemptID: String
    public var regenerationOrdinal: Int
    public var expectedCanonicalRevision: Int
    public var issuedAt: Date
    public var state: CanonicalFinalAnswerWriteLeaseState
    public var supersededByLeaseID: String?
    public var resolvedAt: Date?
}

/// RegenerationIntent（只 materialize 最后一个 durable intent）
public struct RegenerationIntent: Codable, Equatable, Hashable, Sendable {
    public var intentID: String
    public var turnID: String
    public var ordinal: Int
    public var requestedAt: Date
    public var kind: RegenerationIntentKind
    public var state: RegenerationIntentState
    public var sourceAttemptID: String
    public var expectedCanonicalRevision: Int
    public var configurationMode: RegenerationConfigurationMode
    public var configurationRevisionDigest: String?
    public var materializedAttemptID: String?
    public var supersededByIntentID: String?
}

/// AttemptExecutionAuthorityLease（effect-capable 唯一 authority）
public struct AttemptExecutionAuthorityLease: Codable, Equatable, Hashable, Sendable {
    public var authorityID: String
    public var turnID: String
    public var attemptID: String
    public var generation: Int
    public var state: AttemptExecutionAuthorityLeaseState
    public var allowedEffectClasses: [String]
    public var issuedAt: Date
    public var revokedAt: Date?
    public var settledAt: Date?
    public var revocationReason: String?
    public var supersededByIntentID: String?
}

/// AnswerOnlyRuntimeLaunchCapability（零 Target/workspace/terminal/effect）
public struct AnswerOnlyRuntimeLaunchCapability: Codable, Equatable, Hashable, Sendable {
    public var capabilityID: String
    public var turnID: String
    public var attemptID: String
    public var localAgentConfigurationID: String
    public var admissionLeaseID: String
    public var launchKind: AnswerOnlyLaunchKind
    public var state: AnswerOnlyLaunchCapabilityState
    public var executableIdentityDigest: String
    public var executionProfileID: String
    public var containmentRevision: String
    public var processGeneration: Int
    public var cliAuthenticationScopeDigest: String
    public var allowedModelOrigins: [String]
    public var networkPolicyDigest: String
    public var readOnlyInputChannelDigest: String
    public var privateEphemeralScratchReference: String?
    public var scratchDeletionFence: String?
    public var targetBindingAccess: String
    public var projectWorkspaceAccess: String
    public var terminalAccess: String
    public var effectBrokerAccess: String
    public var childProcessPolicy: String
    public var persistentWritePolicy: String
    public var launchJournalID: String
    public var issuedAt: Date
    public var activatedAt: Date?
    public var revokedAt: Date?
    public var settledAt: Date?
    public var settlementOutcome: String?
    public var settlementEvidenceID: String?
    public var failureCode: String?
}

/// TurnAttempt（核心工作单元）
public enum AttemptPurpose: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case initial
    case answerRegeneration
    case retrySameConfig
    case retryNewConfig
    case takeoverRecovery
    case crashRecovery
}

public struct ModelInvocation: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var attemptID: String
    public var ordinal: Int
    public var childTaskID: String?
    public var providerRequestAttemptIDs: [String]
    public var localAgentSessionID: String?
    public var contextSnapshotID: String
    public var contextDigest: String
    public var runtimeCapabilitySnapshot: String
    public var startedAt: Date
    public var endedAt: Date?
    public var usage: [String: Int]?
    public var outcome: String?
}

public struct ToolProposal: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var invocationID: String
    public var batchID: String
    public var sourceChildTaskID: String?
    public var ordinal: Int
    public var arbitrationOrdinal: Int
    public var sourceToolCallID: String
    public var immutableOperation: String
    public var operationDigest: String
    public var state: ToolProposalState
    public var approvalSource: ToolProposalApprovalSource? = nil
    public var decisionID: String?
    public var effectID: String?
    public var terminalExecutionID: String?
    public var result: String?
    public var error: String?
}

public struct ChildTask: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var attemptID: String
    public var parentChildTaskID: String?
    public var runtimeTaskID: String
    public var title: String
    public var state: String
    public var sourceOrdinal: Int
    public var capabilitySnapshot: String
    public var startedAt: Date
    public var endedAt: Date?
    public var usage: [String: Int]?
    public var childTaskIDs: [String]
    public var invocationIDs: [String]
    public var proposalIDs: [String]
    public var outcome: String?
    public var error: String?
}

public struct Decision: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var attemptID: String
    public var proposalID: String?
    public var requestID: String?
    public var kind: DecisionKind
    public var state: DecisionState
    public var requestDigest: String
    public var resumePhase: AttemptPhase?
    public var createdAt: Date
    public var deadline: Date?
    public var allowedResolutionSchema: String?
    public var nonSensitiveResponse: String?
    public var resolvedAt: Date?
    public var resolutionSource: String?
    public var resolutionDigest: String?
}

public struct TurnAttempt: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var turnID: String
    public var ordinal: Int
    public var phase: AttemptPhase
    public var outcome: AttemptOutcome?
    public var purpose: AttemptPurpose
    public var runtimeSnapshot: String
    public var workModeSnapshot: WorkMode
    public var planApprovalState: String?
    public var policySnapshot: String
    public var toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot?
    public var toolCapabilitySnapshot: String
    public var toolCatalogRevision: String?
    public var instructionSnapshot: String
    public var instructionDigest: String?
    public var usageBudgetSnapshot: String?
    public var pricingCatalogRevision: String?
    public var targetBindingSnapshot: TargetBinding?
    public var targetRuntimeGeneration: UInt64?
    public var terminalModeSnapshot: String?
    public var agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory?
    public var localAgentExecutionProfileSnapshot: String?
    public var executionAdmissionLeaseID: String?
    public var runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot?
    public var runtimeAuthenticationDigest: String?
    public var credentialGenerationIDs: [String]
    public var credentialAttemptBindingIDs: [String]
    public var executionAuthorityLeaseID: String?
    public var answerOnlyRuntimeLaunchCapabilityID: String?
    public var configurationRevisionDigest: String?
    public var modelInvocations: [ModelInvocation]
    public var childTasks: [ChildTask]
    public var toolProposalQueue: [ToolProposal]
    public var activeToolProposalID: String?
    public var nextArbitrationOrdinal: Int
    public var pendingDecisionIDs: [String]
    public var resumePhase: AttemptPhase?
    public var takeoverReturnPhase: AttemptPhase?
    public var startedAt: Date
    public var endedAt: Date?
    public var partialAnswer: String?
    /// 可公开的推理摘要（仅 Runtime 提供的安全 summary，非隐藏思维链；规格 §13.2）。
    public var reasoningSummary: String?
    public var error: String?
    public var terminalExecutionIDs: [String]
    public var canonicalWriteLeaseID: String?

    public init(
        id: String, turnID: String, ordinal: Int, phase: AttemptPhase, outcome: AttemptOutcome? = nil,
        purpose: AttemptPurpose, runtimeSnapshot: String, workModeSnapshot: WorkMode,
        planApprovalState: String? = nil, policySnapshot: String,
        toolAuthorizationPolicySnapshot: AgentToolAuthorizationPolicySnapshot? = nil,
        toolCapabilitySnapshot: String,
        toolCatalogRevision: String? = nil, instructionSnapshot: String, instructionDigest: String? = nil,
        usageBudgetSnapshot: String? = nil, pricingCatalogRevision: String? = nil,
        targetBindingSnapshot: TargetBinding? = nil, terminalModeSnapshot: String? = nil,
        targetRuntimeGeneration: UInt64? = nil,
        agentProcessWorkingDirectorySnapshot: AgentProcessWorkingDirectory? = nil,
        localAgentExecutionProfileSnapshot: String? = nil, executionAdmissionLeaseID: String? = nil,
        runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot? = nil,
        runtimeAuthenticationDigest: String? = nil, credentialGenerationIDs: [String] = [],
        credentialAttemptBindingIDs: [String] = [], executionAuthorityLeaseID: String? = nil,
        answerOnlyRuntimeLaunchCapabilityID: String? = nil, configurationRevisionDigest: String? = nil,
        modelInvocations: [ModelInvocation] = [], childTasks: [ChildTask] = [],
        toolProposalQueue: [ToolProposal] = [], activeToolProposalID: String? = nil,
        nextArbitrationOrdinal: Int = 0, pendingDecisionIDs: [String] = [],
        resumePhase: AttemptPhase? = nil, takeoverReturnPhase: AttemptPhase? = nil,
        startedAt: Date, endedAt: Date? = nil, partialAnswer: String? = nil,
        reasoningSummary: String? = nil, error: String? = nil,
        terminalExecutionIDs: [String] = [], canonicalWriteLeaseID: String? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.ordinal = ordinal
        self.phase = phase
        self.outcome = outcome
        self.purpose = purpose
        self.runtimeSnapshot = runtimeSnapshot
        self.workModeSnapshot = workModeSnapshot
        self.planApprovalState = planApprovalState
        self.policySnapshot = policySnapshot
        self.toolAuthorizationPolicySnapshot = toolAuthorizationPolicySnapshot
        self.toolCapabilitySnapshot = toolCapabilitySnapshot
        self.toolCatalogRevision = toolCatalogRevision
        self.instructionSnapshot = instructionSnapshot
        self.instructionDigest = instructionDigest
        self.usageBudgetSnapshot = usageBudgetSnapshot
        self.pricingCatalogRevision = pricingCatalogRevision
        self.targetBindingSnapshot = targetBindingSnapshot
        self.targetRuntimeGeneration = targetRuntimeGeneration
        self.terminalModeSnapshot = terminalModeSnapshot
        self.agentProcessWorkingDirectorySnapshot = agentProcessWorkingDirectorySnapshot
        self.localAgentExecutionProfileSnapshot = localAgentExecutionProfileSnapshot
        self.executionAdmissionLeaseID = executionAdmissionLeaseID
        self.runtimeAuthenticationSnapshot = runtimeAuthenticationSnapshot
        self.runtimeAuthenticationDigest = runtimeAuthenticationDigest
        self.credentialGenerationIDs = credentialGenerationIDs
        self.credentialAttemptBindingIDs = credentialAttemptBindingIDs
        self.executionAuthorityLeaseID = executionAuthorityLeaseID
        self.answerOnlyRuntimeLaunchCapabilityID = answerOnlyRuntimeLaunchCapabilityID
        self.configurationRevisionDigest = configurationRevisionDigest
        self.modelInvocations = modelInvocations
        self.childTasks = childTasks
        self.toolProposalQueue = toolProposalQueue
        self.activeToolProposalID = activeToolProposalID
        self.nextArbitrationOrdinal = nextArbitrationOrdinal
        self.pendingDecisionIDs = pendingDecisionIDs
        self.resumePhase = resumePhase
        self.takeoverReturnPhase = takeoverReturnPhase
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.partialAnswer = partialAnswer
        self.reasoningSummary = reasoningSummary
        self.error = error
        self.terminalExecutionIDs = terminalExecutionIDs
        self.canonicalWriteLeaseID = canonicalWriteLeaseID
    }
}

/// ConversationTurn
public struct ConversationTurn: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var ordinal: Int
    public var userRequest: String
    public var phase: AttemptPhase
    public var attempts: [TurnAttempt]
    public var activeAttemptID: String?
    public var pendingRegenerationIntent: RegenerationIntent?
    public var canonicalFinalAnswerAttemptID: String?
    public var canonicalFinalAnswerRevision: Int
    public var activeCanonicalWriteLeaseID: String?
    public var nextRegenerationOrdinal: Int
    public var finalAnswerState: CanonicalFinalAnswerState
    public var artifacts: [String]
    public var terminalState: String?
    public var timing: [String: Date]?
    public var usage: [String: Int]?

    public init(
        id: String, sessionID: String, ordinal: Int, userRequest: String, phase: AttemptPhase,
        attempts: [TurnAttempt] = [], activeAttemptID: String? = nil,
        pendingRegenerationIntent: RegenerationIntent? = nil,
        canonicalFinalAnswerAttemptID: String? = nil, canonicalFinalAnswerRevision: Int = 0,
        activeCanonicalWriteLeaseID: String? = nil, nextRegenerationOrdinal: Int = 0,
        finalAnswerState: CanonicalFinalAnswerState = .none, artifacts: [String] = [],
        terminalState: String? = nil, timing: [String: Date]? = nil, usage: [String: Int]? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.userRequest = userRequest
        self.phase = phase
        self.attempts = attempts
        self.activeAttemptID = activeAttemptID
        self.pendingRegenerationIntent = pendingRegenerationIntent
        self.canonicalFinalAnswerAttemptID = canonicalFinalAnswerAttemptID
        self.canonicalFinalAnswerRevision = canonicalFinalAnswerRevision
        self.activeCanonicalWriteLeaseID = activeCanonicalWriteLeaseID
        self.nextRegenerationOrdinal = nextRegenerationOrdinal
        self.finalAnswerState = finalAnswerState
        self.artifacts = artifacts
        self.terminalState = terminalState
        self.timing = timing
        self.usage = usage
    }
}

/// ConversationSession（每会话单写入）
public struct ConversationSession: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var schemaVersion: Int
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var branchOrigin: BranchOrigin?
    public var targetBinding: TargetBinding
    public var runtimeSelection: AgentRuntimeSelection
    public var activeAdmissionRequestID: String?
    public var activeAdmissionLeaseID: String?
    public var activeTerminalLeaseID: String?
    public var externalEffectReconciliationIDs: [String]
    public var activeTurnID: String?
    public var queuedInputs: [QueuedInput]
    public var queueAutoAdvancePaused: Bool?
    public var draft: String?
    public var attachmentReferences: [String]
    public var scrollAnchor: String?
    public var memoryScope: String?
    /// Optional for backwards-compatible decoding of pre-metadata V2 events.
    public var isPinned: Bool?
    public var archivedAt: Date?
    public var metadataRevision: Int?

    public init(
        id: String, schemaVersion: Int = 1, title: String, createdAt: Date, updatedAt: Date,
        branchOrigin: BranchOrigin? = nil, targetBinding: TargetBinding,
        runtimeSelection: AgentRuntimeSelection, activeAdmissionRequestID: String? = nil,
        activeAdmissionLeaseID: String? = nil, activeTerminalLeaseID: String? = nil,
        externalEffectReconciliationIDs: [String] = [], activeTurnID: String? = nil,
        queuedInputs: [QueuedInput] = [], queueAutoAdvancePaused: Bool? = nil, draft: String? = nil,
        attachmentReferences: [String] = [], scrollAnchor: String? = nil,
        memoryScope: String? = nil, isPinned: Bool? = nil, archivedAt: Date? = nil,
        metadataRevision: Int? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.branchOrigin = branchOrigin
        self.targetBinding = targetBinding
        self.runtimeSelection = runtimeSelection
        self.activeAdmissionRequestID = activeAdmissionRequestID
        self.activeAdmissionLeaseID = activeAdmissionLeaseID
        self.activeTerminalLeaseID = activeTerminalLeaseID
        self.externalEffectReconciliationIDs = externalEffectReconciliationIDs
        self.activeTurnID = activeTurnID
        self.queuedInputs = queuedInputs
        self.queueAutoAdvancePaused = queueAutoAdvancePaused
        self.draft = draft
        self.attachmentReferences = attachmentReferences
        self.scrollAnchor = scrollAnchor
        self.memoryScope = memoryScope
        self.isPinned = isPinned
        self.archivedAt = archivedAt
        self.metadataRevision = metadataRevision
    }
}

/// BranchOrigin（可审计 lineage；子分支依赖自包含 BranchBaseContextSnapshot）
public struct BranchOrigin: Codable, Equatable, Hashable, Sendable {
    public var parentConversationID: String
    public var forkedFromTurnID: String
    public var forkedFromAttemptID: String?
    public var forkedAtSequence: Int
    public var sourceUserMessageID: String
    public var sourceRevision: Int
    public var branchBaseContextSnapshotID: String
    public var branchBaseDigest: String
    public var createdAt: Date
}

// MARK: - RuntimeCapabilities（规格 §8.5）

public struct RuntimeCapabilities: Codable, Equatable, Hashable, Sendable {
    public var streaming: Bool
    public var toolCalling: Bool
    public var availableToolIDs: [String]
    public var toolCatalogRevision: String?
    public var structuredApproval: Bool
    public var requestUserInput: Bool
    public var sensitiveInput: Bool
    public var steering: Bool
    public var checkpointPause: Bool
    public var sessionResume: Bool
    public var imageInput: Bool
    public var reasoningEffort: Bool
    public var subagents: Bool
    public var terminalTakeover: Bool
    public var structuredEvents: Bool
    public var managedExecution: Bool
    public var launchCapabilityBinding: Bool
    public var answerRegeneration: Bool
    public var answerOnlyRuntimeLaunch: Bool
    public var answerOnlyContainmentRevision: String?
    public var workModeEnforcement: Bool
    public var allowedWorkModes: [WorkMode]
    public var phaseContainmentRevisionsByMode: [String: String]
    public var contextUsageReporting: Bool
    public var usageReporting: Bool

    public init(
        streaming: Bool = false, toolCalling: Bool = false, availableToolIDs: [String] = [],
        toolCatalogRevision: String? = nil, structuredApproval: Bool = false,
        requestUserInput: Bool = false, sensitiveInput: Bool = false, steering: Bool = false,
        checkpointPause: Bool = false, sessionResume: Bool = false, imageInput: Bool = false,
        reasoningEffort: Bool = false, subagents: Bool = false, terminalTakeover: Bool = false,
        structuredEvents: Bool = false, managedExecution: Bool = false,
        launchCapabilityBinding: Bool = false, answerRegeneration: Bool = false,
        answerOnlyRuntimeLaunch: Bool = false, answerOnlyContainmentRevision: String? = nil,
        workModeEnforcement: Bool = false, allowedWorkModes: [WorkMode] = [],
        phaseContainmentRevisionsByMode: [String: String] = [:],
        contextUsageReporting: Bool = false, usageReporting: Bool = false
    ) {
        self.streaming = streaming
        self.toolCalling = toolCalling
        self.availableToolIDs = availableToolIDs
        self.toolCatalogRevision = toolCatalogRevision
        self.structuredApproval = structuredApproval
        self.requestUserInput = requestUserInput
        self.sensitiveInput = sensitiveInput
        self.steering = steering
        self.checkpointPause = checkpointPause
        self.sessionResume = sessionResume
        self.imageInput = imageInput
        self.reasoningEffort = reasoningEffort
        self.subagents = subagents
        self.terminalTakeover = terminalTakeover
        self.structuredEvents = structuredEvents
        self.managedExecution = managedExecution
        self.launchCapabilityBinding = launchCapabilityBinding
        self.answerRegeneration = answerRegeneration
        self.answerOnlyRuntimeLaunch = answerOnlyRuntimeLaunch
        self.answerOnlyContainmentRevision = answerOnlyContainmentRevision
        self.workModeEnforcement = workModeEnforcement
        self.allowedWorkModes = allowedWorkModes
        self.phaseContainmentRevisionsByMode = phaseContainmentRevisionsByMode
        self.contextUsageReporting = contextUsageReporting
        self.usageReporting = usageReporting
    }
}
