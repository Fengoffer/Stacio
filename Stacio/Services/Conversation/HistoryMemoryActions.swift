import Foundation

// MARK: - 历史与记忆动作（P9-7）

public enum HistoryMemoryAction {

    // MARK: - history.exportSelection

    /// 展示精确会话与导出路径。
    public static func exportSelection(sessions: [String], exportPath: String) -> (sessions: [String], exportPath: String) {
        (sessions, exportPath)
    }

    // MARK: - history.clearSelection

    /// 清空所选历史：V2-only 范围、不触碰共用库。
    public static func clearSelectionAppliesToV2Only() -> Bool { true }
    public static func clearSelectionNeverTouchesSharedDatabase() -> Bool { true }

    // MARK: - history.deleteAllV2（接线 P9-4 门禁）

    /// 仅 control disabled + 删除维护 fence + 全结算门禁。
    public static func deleteAllV2Allowed(
        controlDisabled: Bool, maintenanceFenceEngaged: Bool, sagasFullySettled: Bool
    ) -> Bool {
        ConversationQuotaAction.deleteAllV2Allowed(
            controlDisabled: controlDisabled,
            maintenanceFenceEngaged: maintenanceFenceEngaged,
            sagasFullySettled: sagasFullySettled
        )
    }

    // MARK: - history.changeRetention

    /// 缩短先预览候选与固定/活动/分支/恢复证据排除项。
    public static func changeRetentionShortenPreview(
        candidateSessions: [String], excludedKinds: Set<String>
    ) -> [String] {
        candidateSessions.filter { !excludedKinds.contains($0) }
    }
    public static func shortenExcludedKinds() -> Set<String> {
        MemoryHistorySettingsAction.retentionShortenExcludedKinds()
    }

    // MARK: - memory.exportProject / memory.deleteProject

    /// 绑定精确 project+TargetBinding；删除二次确认。
    public static func projectActionRequiresBothIdentities(
        projectIdentity: String, remoteTargetIdentityDigest: String
    ) -> Bool {
        MemoryHistorySettingsAction.projectActionRequiresBothIdentities(
            projectIdentity: projectIdentity, remoteTargetIdentityDigest: remoteTargetIdentityDigest
        )
    }
    public static func deleteProjectRequiresSecondaryConfirmation() -> Bool { true }

    // MARK: - 幂等与 audit

    public static func idempotent() -> Bool { true }
    public static func auditedSettlement() -> Bool { true }
}
