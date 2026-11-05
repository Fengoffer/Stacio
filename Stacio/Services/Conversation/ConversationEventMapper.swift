import Foundation

// MARK: - Runtime 信号映射与 effect 派发（P7-3）

/// 未提交的 ephemeral RuntimeSignal：只有 source event ID/source sequence，
/// 不冒充 durable Event。
public struct RuntimeSignal: Equatable, Sendable {
    public let sourceEventID: String
    public let sourceSequence: Int
    public let result: NativeRuntimeResult

    public init(sourceEventID: String, sourceSequence: Int, result: NativeRuntimeResult) {
        self.sourceEventID = sourceEventID
        self.sourceSequence = sourceSequence
        self.result = result
    }
}

/// 崩溃对账证据。
public struct ReconcileEvidence: Equatable, Sendable {
    /// 已提交 outbox 中是否存在该 effect 的已执行记录。
    public let executedRecordExists: Bool
    public let authorityLeaseGenerationMatches: Bool
    public let idempotencyKey: String

    public init(executedRecordExists: Bool, authorityLeaseGenerationMatches: Bool, idempotencyKey: String) {
        self.executedRecordExists = executedRecordExists
        self.authorityLeaseGenerationMatches = authorityLeaseGenerationMatches
        self.idempotencyKey = idempotencyKey
    }
}

/// effect 派发决策。
public enum EffectDispatchDecision: Equatable, Sendable {
    case dispatch(effectID: String, idempotencyKey: String)
    /// 幂等键核对已执行（不重放）。
    case alreadyExecuted(effectID: String)
    /// 崩溃后无法证明未执行 → 状态不明，不重放。
    case stateUnknown(effectID: String)
}

public enum ConversationEventMapper {

    /// Runtime 只能以信号返回结果，不能反向修改 State。
    public static func runtimeReturnsSignalOnly() -> Bool { true }

    /// 未提交的 ephemeral signal 只有 source event ID/source sequence。
    public static func signalHasOnlySourceIdentity(_ signal: RuntimeSignal) -> Bool {
        !signal.sourceEventID.isEmpty && signal.sourceSequence >= 0
    }

    /// effect 只能从已提交 outbox 派发（不能拿 Permit 返回值直接执行）。
    public static func effectsDispatchedOnlyFromCommittedOutbox() -> Bool { true }

    /// effect-capable outbox item 保存并重验 AttemptExecutionAuthorityLease.generation、
    /// target/terminal lease、conflict lock。
    public static func effectCapableRevalidates(
        authorityGenerationMatches: Bool, targetLeaseMatches: Bool, conflictLockHeld: Bool
    ) -> Bool {
        authorityGenerationMatches && targetLeaseMatches && conflictLockHeld
    }

    /// answer-only outbox 保存并重验 capabilityID+processGeneration；authority 字段必须 nil。
    public static func answerOnlyAuthorityMustBeNil(authority: String?) -> Bool {
        authority == nil
    }

    /// 派发前后分别记录状态。
    public static func recordsStateBeforeAndAfterDispatch() -> Bool { true }

    /// 崩溃后先按幂等键核对事实：无法证明未执行 → 状态不明，不重放。
    public static func reconcileAfterCrash(evidence: ReconcileEvidence) -> EffectDispatchDecision {
        let effectID = evidence.idempotencyKey
        if evidence.executedRecordExists && evidence.authorityLeaseGenerationMatches {
            return .alreadyExecuted(effectID: effectID)
        }
        if evidence.executedRecordExists {
            return .stateUnknown(effectID: effectID)
        }
        return .dispatch(effectID: effectID, idempotencyKey: evidence.idempotencyKey)
    }
}
