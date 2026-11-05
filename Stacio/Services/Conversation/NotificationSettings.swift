import Foundation

// MARK: - 通知设置（P4-15）

/// 可通知事件集合。
public enum NotificationEventID: String, Codable, CaseIterable, Equatable, Sendable {
    case completion
    case failure
    case capacityGrantedLongWait
    case waitingApproval
    case waitingUser
    case revocation
    case orphanUnknownEffect
}

public struct NotificationSettingsSnapshot: Equatable, Sendable {
    public var enabledEventIDs: Set<NotificationEventID>
    public var longCapacityWaitMinutes: Int

    public init(
        enabledEventIDs: Set<NotificationEventID> = NotificationSettingsAction.defaultEnabledEvents(),
        longCapacityWaitMinutes: Int = NotificationSettingsAction.longCapacityWaitDefault()
    ) {
        self.enabledEventIDs = enabledEventIDs
        self.longCapacityWaitMinutes = longCapacityWaitMinutes
    }
}

public enum NotificationSettingsAction {

    /// 默认可通知事件：完成/失败/容量获准-长等待/等待审批/用户/吊销/orphan-未知 effect。
    public static func defaultEnabledEvents() -> Set<NotificationEventID> {
        Set(NotificationEventID.allCases)
    }

    /// longCapacityWaitMinutes 默认 5（1..30）。
    public static func longCapacityWaitDefault() -> Int { 5 }
    public static func longCapacityWaitRange() -> ClosedRange<Int> { 1...30 }
    public static func validateLongCapacityWaitMinutes(_ value: Int) -> Bool {
        longCapacityWaitRange().contains(value)
    }

    /// 只作用于新 Admission Request 的单次长等待提醒 deadline：
    /// 修改不追溯既有 request；deadline = 创建时间 + 配置分钟数。
    public static func reminderDeadline(requestCreatedAt: Date, configuredMinutes: Int, now: Date) -> Date? {
        guard validateLongCapacityWaitMinutes(configuredMinutes) else { return nil }
        let deadline = requestCreatedAt.addingTimeInterval(TimeInterval(configuredMinutes * 60))
        return now >= deadline ? deadline : nil
    }

    /// 每个 request 最多提醒一次（容量获准可另行通知）。
    public static func alreadyReminded(requestID: String, remindedRequestIDs: Set<String>) -> Bool {
        remindedRequestIDs.contains(requestID)
    }

    public static func markReminded(requestID: String, reminded: inout Set<String>) {
        reminded.insert(requestID)
    }

    /// 仅在 Stacio 非前台或对应会话不可见时通知。
    public static func shouldNotify(appIsForeground: Bool, sessionVisible: Bool) -> Bool {
        !appIsForeground || !sessionVisible
    }

    public static func onlyWhenNotForegroundOrHidden() -> Bool { true }

    // MARK: - 正文净化

    /// 通知正文永不包含 prompt、主机、路径、命令或 secret。
    public static func containsForbiddenContent(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("prompt") || lower.contains("host") || lower.contains("/")
            || lower.contains("secret") || lower.contains("key")
    }

    public static func sanitizedBody(_ body: String) -> String {
        containsForbiddenContent(body) ? "（已脱敏）" : body
    }

    // MARK: - 容量长等待提醒语义

    /// 容量长等待提醒不改变 FIFO、等待 deadline 或自动取消行为。
    public static func reminderDoesNotChangeFIFO() -> Bool { true }
    public static func reminderDoesNotChangeWaitDeadline() -> Bool { true }
    public static func reminderDoesNotChangeAutoCancel() -> Bool { true }
}
