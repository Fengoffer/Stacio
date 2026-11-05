import Foundation

// MARK: - Settings 记忆/历史/存储分区（P9-5）

public enum MemoryHistorySettingsAction {

    /// 记忆与历史页、存储与配额页从 Registry 渲染，无控制器私有默认。
    public static func rendersFromRegistry() -> Bool { true }
    public static func noControllerPrivateDefaults() -> Bool { true }

    /// `history.changeRetention` 缩短：先预览候选/固定/活动/分支/恢复证据排除项。
    public static func shortenRetentionRequiresPreviewFirst() -> Bool { true }

    /// 排除项：固定/活动/分支/恢复证据（这些内容不因缩短而删除）。
    public static func retentionShortenExcludedKinds() -> Set<String> {
        ["pinned", "active", "branch", "recoveryEvidence"]
    }

    public static func excludedFromShortening(kind: String) -> Bool {
        retentionShortenExcludedKinds().contains(kind)
    }

    /// `memory.exportProject/deleteProject` 绑定精确 project+TargetBinding。
    public static func projectActionBoundToExactProjectAndTargetBinding() -> Bool { true }
    public static func projectActionRequiresBothIdentities(
        projectIdentity: String, remoteTargetIdentityDigest: String
    ) -> Bool {
        !projectIdentity.isEmpty && !remoteTargetIdentityDigest.isEmpty
    }

    /// 删除会话数据只作用于 V2 独立存储并需二次确认。
    public static func deleteAppliesToV2IndependentStorageOnly() -> Bool { true }
    public static func deleteRequiresSecondaryConfirmation() -> Bool { true }
}
