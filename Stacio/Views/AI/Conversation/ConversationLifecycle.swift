import Foundation

// MARK: - Conversation 生命周期（P6-6：空状态/归档/删除门禁/Final Answer/回滚）

/// 会话活动状态（删除/归档门禁判定）。
public enum ConversationActivityState: Equatable, Sendable {
    case idle
    case active
    case waitingForCapacity
    case paused
    case waitingApproval
    case waitingUser
    case takeoverPending
    case orphanedRuntime
    case hasUnresolvedExternalEffects
}

public enum ConversationLifecycleAction {

    // MARK: - 归档

    /// 归档只移出默认侧栏，不停止/删除数据。
    public static func archiveMovesOutOfDefaultSidebarOnly() -> Bool { true }
    public static func archiveDoesNotStopOrDeleteData() -> Bool { true }

    /// 活动/等待/暂停会话必须先完成 Stop 才能归档。
    public static func archiveRequiresStopped(_ state: ConversationActivityState) -> Bool {
        switch state {
        case .active, .waitingForCapacity, .paused, .waitingApproval, .waitingUser:
            return false
        case .idle, .takeoverPending, .orphanedRuntime, .hasUnresolvedExternalEffects:
            return true
        }
    }

    // MARK: - 删除

    /// 删除活动/等待/暂停/TakeoverPending/orphanedRuntime/unresolved External Effect
    /// 会话前必须先完成停止/隔离与影响预览。
    public static func deleteRequiresStopOrIsolation(_ state: ConversationActivityState) -> Bool {
        switch state {
        case .idle:
            return false
        case .active, .waitingForCapacity, .paused, .waitingApproval, .waitingUser,
             .takeoverPending, .orphanedRuntime, .hasUnresolvedExternalEffects:
            return true
        }
    }

    /// 删除 Conversation 不删除 Provider/Coding 凭证/官方 CLI 登录/Catalog/其他分支。
    public static func deleteScopes() -> [String] {
        ["conversationEvents", "attachments"]
    }
    public static func deleteNeverTouchesProviderCredentials() -> Bool { true }
    public static func deleteNeverTouchesCodingPlanCredentials() -> Bool { true }
    public static func deleteNeverTouchesOfficialCLILogin() -> Bool { true }
    public static func deleteNeverTouchesCatalogs() -> Bool { true }
    public static func deleteNeverTouchesOtherBranches() -> Bool { true }

    // MARK: - Final Answer 分组

    /// Final Answer 固定区分：结论/已执行已更改/验证证据/风险或未完成/建议下一步。
    public static func finalAnswerSections() -> [String] {
        ["结论", "已执行已更改", "验证证据", "风险或未完成", "建议下一步"]
    }

    /// 纯回答模式隐藏无内容分组。
    public static func hidesEmptySectionsInAnswerOnlyMode(isAnswerOnly: Bool) -> Bool {
        isAnswerOnly
    }

    /// 「重新生成回答（仅推理）」与「重新运行任务（可能再次执行需重新审批）」并列分开。
    public static func regenerateActions() -> [String] {
        ["重新生成回答（仅推理）", "重新运行任务（可能再次执行需重新审批）"]
    }

    // MARK: - 回滚

    /// 回滚只在现有执行内核持有经过验证的 backup/rollback plan 且目标与 generation 匹配时出现。
    public static func rollbackAvailable(
        hasVerifiedBackupPlan: Bool, targetMatches: Bool, generationMatches: Bool
    ) -> Bool {
        hasVerifiedBackupPlan && targetMatches && generationMatches
    }
}
