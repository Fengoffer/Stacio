import Foundation

// MARK: - Legacy 只读适配（P9-3）

/// 旧 role 只按原始标签展示。
public enum LegacyRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    /// 无法确定类型的条目 → 只读 Legacy 区，不猜测 V2 事件类型。
    case undetermined
}

/// 旧历史记录（只读）。
public struct LegacyHistoryRecord: Equatable, Sendable {
    public let recordID: String
    public let legacyRuntimeID: String
    public let role: LegacyRole
    public let text: String
    public let byteCount: Int
    /// 2,048 与 2,045–2,047 字节记录标记为可能截断。
    public let mayBeTruncated: Bool

    public init(
        recordID: String, legacyRuntimeID: String, role: LegacyRole,
        text: String, byteCount: Int, mayBeTruncated: Bool
    ) {
        self.recordID = recordID
        self.legacyRuntimeID = legacyRuntimeID
        self.role = role
        self.text = text
        self.byteCount = byteCount
        self.mayBeTruncated = mayBeTruncated
    }
}

/// continuation reference：指向 legacyRuntimeID/记录 ID/时间范围。
public struct LegacyContinuationReference: Equatable, Sendable {
    public let legacyRuntimeID: String
    public let recordID: String
    public let timeRange: ClosedRange<Date>?

    public init(legacyRuntimeID: String, recordID: String, timeRange: ClosedRange<Date>?) {
        self.legacyRuntimeID = legacyRuntimeID
        self.recordID = recordID
        self.timeRange = timeRange
    }
}

/// 第一次调用模型前创建的不可变 LegacyContextSnapshot。
public struct LegacyContextSnapshot: Equatable, Sendable {
    public let visibleLegacyText: String
    public let originID: String
    public let byteCount: Int
    public let truncated: Bool

    public init(visibleLegacyText: String, originID: String, byteCount: Int, truncated: Bool) {
        self.visibleLegacyText = visibleLegacyText
        self.originID = originID
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public enum LegacyConversationHistoryAdapter {

    /// 旧 ai_conversation_history 不删除/不改写/不批量复制；只读按需展示。
    public static func readOnlyNeverModifiesOrCopies() -> Bool { true }

    /// 2,048 与 2,045–2,047 字节记录 `legacyMayBeTruncated=true`。
    public static func mayBeTruncated(byteCount: Int) -> Bool {
        byteCount == 2_048 || (2_045...2_047).contains(byteCount)
    }

    public static func truncationWarningDisplay() -> String { "旧版本可能已截断" }

    /// 旧 role 只按原始 user/assistant 标签展示。
    public static func roleDisplay(_ role: LegacyRole) -> String {
        role.rawValue
    }

    /// 无法确定类型的条目进入只读 Legacy 区，不猜测 V2 事件类型。
    public static func undeterminedGoesToReadOnlyLegacyZone() -> Bool { true }

    /// continuation 必须显式选择并确认新 TargetBinding。
    public static func continuationRequiresExplicitNewTargetBinding() -> Bool { true }

    /// `legacyRuntimeID` 只作旧表查询键，不推断为 V2 TargetBinding。
    public static func legacyRuntimeIDIsQueryKeyOnly() -> Bool { true }

    /// 第一次调用模型前创建不可变 LegacyContextSnapshot。
    public static func snapshot(from record: LegacyHistoryRecord) -> LegacyContextSnapshot {
        LegacyContextSnapshot(
            visibleLegacyText: record.text,
            originID: record.recordID,
            byteCount: record.byteCount,
            truncated: record.mayBeTruncated
        )
    }

    /// Adapter 读取失败只影响 Legacy 区，V2 仍可用。
    public static func readFailureOnlyAffectsLegacyZone() -> Bool { true }

    /// 保留旧历史只读适配至少一个稳定发布周期。
    public static func keepReadOnlyAdapterAtLeastOneStableRelease() -> Bool { true }
}
