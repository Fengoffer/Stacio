import Foundation

// MARK: - CredentialUseLease owner 隔离（P3-8c）

public enum CredentialUseLeasePolicy {
    /// 三类 owner 不能互换：Attempt/setup/configuration-action 各自只能操作自己的 lease。
    public static func ownerIsolationValid(
        leaseOwner: CredentialUseLeaseOwner,
        requestedBy: CredentialUseLeaseOwner
    ) -> Bool {
        leaseOwner == requestedBy
    }
}

// MARK: - ConfigurationVerificationRequest 状态机（P3-8c）

public enum VerificationRequestEvent: Equatable, Sendable {
    case markInFlight
    case requestCancellation
    case settleSucceeded
    case settleFailed
    case settleCancelled
    case stateUnknown
}

public enum ConfigurationVerificationRequestStateMachine {
    /// 关闭转换表：
    /// `prepared→inFlight|settledCancelled`、`inFlight→cancellationRequested|settledSucceeded|settledFailed|stateUnknown`、
    /// `cancellationRequested→settled*|stateUnknown`。
    public static func destination(
        from state: ConfigurationVerificationRequestState,
        event: VerificationRequestEvent
    ) -> ConfigurationVerificationRequestState? {
        switch (state, event) {
        case (.prepared, .markInFlight): return .inFlight
        case (.prepared, .settleCancelled): return .settledCancelled
        case (.inFlight, .requestCancellation): return .cancellationRequested
        case (.inFlight, .settleSucceeded): return .settledSucceeded
        case (.inFlight, .settleFailed): return .settledFailed
        case (.inFlight, .stateUnknown): return .stateUnknown
        case (.cancellationRequested, .settleCancelled): return .settledCancelled
        case (.cancellationRequested, .settleSucceeded): return .settledSucceeded
        case (.cancellationRequested, .settleFailed): return .settledFailed
        case (.cancellationRequested, .stateUnknown): return .stateUnknown
        default:
            return nil
        }
    }
}

// MARK: - Access mode 隔离（P3-8c）

public enum CredentialAccessModePolicy {
    /// `none` 模式必须零 generation/use lease/setup/lifecycle：late callback 不能反向迁移。
    public static func lateCallbackCannotMigrateFromNone(mode: CredentialAccessMode) -> Bool {
        mode == .none
    }

    /// `setupPending` 只允许 setup 相关操作；`activeConfiguration` 只允许配置激活操作。
    public static func operationAllowed(
        mode: CredentialAccessMode,
        operation: CredentialAccessOperation
    ) -> Bool {
        switch (mode, operation) {
        case (.none, _):
            return false // none 零能力
        case (.setupPending, .setupOnly), (.setupPending, .readOnly):
            return true
        case (.activeConfiguration, .configurationOnly), (.activeConfiguration, .readOnly):
            return true
        default:
            return false
        }
    }
}

public enum CredentialAccessOperation: Equatable, Sendable {
    case setupOnly
    case configurationOnly
    case readOnly
}

// MARK: - Setup operation 状态机与期限（P3-8c）

public enum CredentialSetupOperationPolicy {
    /// ephemeralSetup：30min owner lease 自动期限；savedDraft：无自动期限。
    public static let ephemeralOwnerLeaseDuration: TimeInterval = 30 * 60

    public static func hasAutomaticDeadline(_ retention: CredentialSetupPendingRetention) -> Bool {
        retention == .ephemeralSetup
    }

    public static func ephemeralLeaseExpired(createdAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= ephemeralOwnerLeaseDuration
    }

    /// `pendingActivation→abandoned`：仅 open/suspended 可放弃。
    public static func abandonAllowed(state: CredentialSetupOperationState) -> Bool {
        state == .open || state == .suspended
    }

    /// drain：suspended/discardRequested 是合法暂停/放弃前置。
    public static func drainSuspends(state: CredentialSetupOperationState) -> Bool {
        state == .suspended || state == .discardRequested
    }
}
