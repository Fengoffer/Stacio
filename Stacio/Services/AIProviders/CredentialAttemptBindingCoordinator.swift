import Foundation

// MARK: - Binding 对账结果

public enum BindingReconciliationOutcome: Equatable, Sendable {
    /// 已提交但 ack 丢失 → 补 committed
    case commitConfirmed
    /// 明确不存在且越过可提交恢复点 → released
    case releaseConfirmed
    /// 无法确认 → quarantine（阻止删除）
    case quarantine
}

public enum ParticipantProofVerdict: Equatable, Sendable {
    case valid
    /// 要求 binding 但为零（stacioCredentialBindings|combined）
    case missingRequiredBinding
    /// 要求零 binding 但出现异常 binding（cliManagedAuthentication|noneVerified → 隔离并在 Admission 前失败）
    case unexpectedBinding
}

// MARK: - CredentialAttemptBindingCoordinator（P3-8b，仅状态机/对账/参与证明）

public enum CredentialAttemptBindingEvent: Equatable, Sendable {
    case markCommitPending
    case commitConfirmed
    case beginRelease
    case quarantine
}

public enum CredentialAttemptBindingStateMachine {
    /// 关闭转换表：reserved→commitPending→committed→releasing→released|quarantined。
    public static func destination(
        from state: CredentialAttemptBindingState,
        event: CredentialAttemptBindingEvent
    ) -> CredentialAttemptBindingState? {
        switch (state, event) {
        case (.reserved, .markCommitPending): return .commitPending
        case (.reserved, .quarantine): return .quarantined
        case (.commitPending, .commitConfirmed): return .committed
        case (.commitPending, .quarantine): return .quarantined
        case (.committed, .beginRelease): return .releasing
        case (.committed, .quarantine): return .quarantined
        case (.releasing, .beginRelease): return .released
        case (.releasing, .quarantine): return .quarantined
        default:
            return nil
        }
    }
}

public enum CredentialAttemptBindingCoordinator {
    /// 四种窗口对账（不可变 proof）：
    /// 已提交但 ack 丢失 → 补 committed；明确不存在且越过可提交恢复点 → released；
    /// 无法确认 → quarantine（阻止删除）。
    public static func reconcile(
        hadConversationCommit: Bool,
        ackReceived: Bool,
        pastCommitRecoveryPoint: Bool
    ) -> BindingReconciliationOutcome {
        if hadConversationCommit && !ackReceived {
            return .commitConfirmed
        }
        if !hadConversationCommit && pastCommitRecoveryPoint {
            return .releaseConfirmed
        }
        return .quarantine
    }

    /// derivedActiveBindingCount 只由未释放 binding 的权威索引派生
    /// （released/quarantined 不计；两库各自增减是 invariant violation）。
    public static func derivedActiveBindingCount(
        _ states: [CredentialAttemptBindingState]
    ) -> Int {
        states.filter { $0 != .released && $0 != .quarantined }.count
    }

    /// 四 mode participant proof：
    /// `stacioCredentialBindings|combined` 必须有 binding；
    /// `cliManagedAuthentication|noneVerified` 必须零 binding（异常 → 隔离并在 Admission 前失败）。
    public static func participantProof(
        mode: RuntimeAuthenticationMode,
        bindingCount: Int
    ) -> ParticipantProofVerdict {
        switch mode {
        case .stacioCredentialBindings, .combined:
            return bindingCount > 0 ? .valid : .missingRequiredBinding
        case .cliManagedAuthentication, .noneVerified:
            return bindingCount == 0 ? .valid : .unexpectedBinding
        }
    }
}
