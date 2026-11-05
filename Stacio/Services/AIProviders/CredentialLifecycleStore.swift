import Foundation

// MARK: - 删除操作状态（关闭集合；P3-8a）

public enum CredentialDeletionOperationState: String, Codable, CaseIterable, Equatable, Sendable {
    case requested
    case blockedByUse
    case deleting
    case completed
    case failed
}

// MARK: - 生命周期状态机（仅状态机；权威持久层在 Rust credential_lifecycle.rs 独立存储域）

public enum CredentialLifecycleEvent: Equatable, Sendable {
    case activate
    case retire
    case revoke
    case abandon
}

public enum CredentialLifecycleStateMachine {
    /// 关闭转换表：
    /// `pendingActivation→active|abandoned|revoked`、`active→retired|revoked`、
    /// `retired→revoked`；`abandoned/revoked` 终态且不可复活（返回 nil）。
    public static func destination(
        from state: CredentialGenerationLifecycleState,
        event: CredentialLifecycleEvent
    ) -> CredentialGenerationLifecycleState? {
        switch (state, event) {
        case (.pendingActivation, .activate): return .active
        case (.pendingActivation, .abandon): return .abandoned
        case (.pendingActivation, .revoke): return .revoked
        case (.active, .retire): return .retired
        case (.active, .revoke): return .revoked
        case (.retired, .revoke): return .revoked
        default:
            return nil // 终态（abandoned/revoked）无出口；非法边拒绝
        }
    }

    public static func isTerminal(_ state: CredentialGenerationLifecycleState) -> Bool {
        state == .abandoned || state == .revoked
    }

    /// 删除进行中（secretAvailability == pendingDeletion）不得复活。
    public static func reviveBlocked(
        state: CredentialGenerationLifecycleState,
        secretAvailability: SecretAvailability
    ) -> Bool {
        secretAvailability == .pendingDeletion
            && (state == .pendingActivation || state == .active)
    }
}

// MARK: - 删除 saga（deletionFence 递增；blockedByUse 不得完成）

public enum CredentialDeletionSaga {
    /// 关闭转换表；blockedByUse 状态下不得直接完成删除（先 deleting）。
    public static func destination(
        from state: CredentialDeletionOperationState,
        event: CredentialDeletionEvent
    ) -> CredentialDeletionOperationState? {
        switch (state, event) {
        case (.requested, .blockByUse): return .blockedByUse
        case (.requested, .beginDelete): return .deleting
        case (.requested, .fail): return .failed
        case (.blockedByUse, .beginDelete): return .deleting
        case (.blockedByUse, .fail): return .failed
        case (.deleting, .complete): return .completed
        case (.deleting, .fail): return .failed
        default:
            return nil
        }
    }

    public static func nextFence(current: Int) -> Int {
        current + 1
    }
}

public enum CredentialDeletionEvent: Equatable, Sendable {
    case blockByUse
    case beginDelete
    case complete
    case fail
}

// MARK: - 孤儿策略（不自动挂接、不输出 secret）

public enum CredentialOrphanResolution: String, Equatable, Sendable {
    case deleted
    case manualReview
}

public enum CredentialOrphanPolicy {
    /// 孤儿结算只允许 deleted|manualReview；自动挂接/回填 active 一律拒绝。
    public static func settle(resolution: String) -> CredentialOrphanResolution? {
        switch resolution {
        case "deleted": return .deleted
        case "manualReview": return .manualReview
        default: return nil
        }
    }
}
