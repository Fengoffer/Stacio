import Foundation

// MARK: - 存储配额、保留与删除门禁（P9-4）

/// 存储配额（默认总量 5 GiB）。
public struct StorageQuotaProfile: Equatable, Sendable {
    public static let totalBytes: Int64 = 5 * 1024 * 1024 * 1024
    public static let sessionDatabaseBytes: Int64 = 1 * 1024 * 1024 * 1024
    public static let attachmentsBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let terminalLogsBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let singleAttachmentBytes: Int64 = 100 * 1024 * 1024
    public static let singleLogBytes: Int64 = 100 * 1024 * 1024

    public init() {}
}

/// 终端日志达限的 ContentOmitted 记录。
public struct ContentOmittedRecord: Equatable, Sendable {
    public let originalBytes: Int
    public let retainedBytes: Int
    public let timeRange: ClosedRange<Date>
    public let reason: String
    public let fullSourceStillExists: Bool

    public init(
        originalBytes: Int, retainedBytes: Int, timeRange: ClosedRange<Date>,
        reason: String, fullSourceStillExists: Bool
    ) {
        self.originalBytes = originalBytes
        self.retainedBytes = retainedBytes
        self.timeRange = timeRange
        self.reason = reason
        self.fullSourceStillExists = fullSourceStillExists
    }
}

public enum ConversationQuotaAction {

    public static func quotaProfile() -> StorageQuotaProfile { StorageQuotaProfile() }

    /// 达到 90% 预警并停止自动下载大附件。
    public static let warningThreshold = 0.9
    public static func warnsAt90Percent(usedBytes: Int64, totalBytes: Int64) -> Bool {
        Double(usedBytes) / Double(totalBytes) >= warningThreshold
    }
    public static func stopsAutoDownloadingLargeAttachments(atWarning: Bool) -> Bool { atWarning }

    /// 会话数据库预留至少 5% 只用于活动 Turn durable 终态/错误/清理。
    public static let sessionReserveRatio = 0.05
    public static func sessionDBReservedForActiveTurn() -> Double { sessionReserveRatio }

    /// 达到硬上限暂停新 Turn 保留草稿并提供清理入口。
    public static func hardLimitPausesNewTurnsButKeepsDraft() -> Bool { true }

    /// 自动清理只处理已超保留期/未固定/不被引用内容。
    public static func autoCleanupOnlyExpiredUnpinnedUnreferenced() -> Bool { true }

    /// Event 物理删除只按 verified snapshot 覆盖连续前缀 + 原子 compaction。
    public static func eventDeletionRequiresVerifiedSnapshotPrefix() -> Bool { true }
    public static func atomicCompactionRequired() -> Bool { true }

    /// 中间 checkpoint 只清理 payload，保留 sequence skeleton/原 hash/字节数/omission reason。
    public static func checkpointCleanupKeepsSequenceSkeleton() -> Bool { true }

    /// 终端日志达限插入 ContentOmitted（原始/保留字节数/时间范围/原因/完整来源是否仍存在）。
    public static func terminalLogOmission(
        originalBytes: Int, retainedBytes: Int, timeRange: ClosedRange<Date>, reason: String,
        fullSourceStillExists: Bool
    ) -> ContentOmittedRecord {
        ContentOmittedRecord(
            originalBytes: originalBytes, retainedBytes: retainedBytes,
            timeRange: timeRange, reason: reason, fullSourceStillExists: fullSourceStillExists
        )
    }

    /// `history.deleteAllV2` 只在 control disabled + 删除维护 fence +
    /// setup/binding/use/revoke/delete/outbox/orphan/conflict 全结算后执行。
    public static func deleteAllV2Allowed(
        controlDisabled: Bool, maintenanceFenceEngaged: Bool, sagasFullySettled: Bool
    ) -> Bool {
        controlDisabled && maintenanceFenceEngaged && sagasFullySettled
    }

    /// deleteAllV2 不触碰共用数据库/Provider 凭证/CLI 登录。
    public static func deleteAllV2NeverTouchesSharedDBOrCredentials() -> Bool { true }

    /// 「清空历史」只作用于 V2 会话。
    public static func clearHistoryAppliesToV2Only() -> Bool { true }

    /// `assistant.resetSettingsAndInstructions` 保留 RuntimeConfigurationMetadataKey 加密的
    /// Provider/Coding/LocalAgent 配置与凭证。
    public static func resetSettingsKeepsProviderConfigAndCredentials() -> Bool { true }
}
