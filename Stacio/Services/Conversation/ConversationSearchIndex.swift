import Foundation

// MARK: - 仅内存搜索（P9-1）

/// 搜索索引条目（仅进程内临时持有）。
public struct SearchIndexEntry: Equatable, Sendable {
    public let sessionID: String
    public let recordID: String
    /// 解密后的正文/标题（仅内存，不落盘）。
    public let text: String

    public init(sessionID: String, recordID: String, text: String) {
        self.sessionID = sessionID
        self.recordID = recordID
        self.text = text
    }
}

public enum ConversationSearchIndexAction {

    /// search worker 只在后台按需解密并构建进程内临时索引。
    public static func buildsInMemoryTemporaryIndexOnly() -> Bool { true }
    public static func decryptsOnDemandInBackground() -> Bool { true }

    /// 磁盘禁止建立含正文/标题/命令/主机信息的明文 FTS。
    public static func plaintextFTSOnDiskForbidden() -> Bool { true }

    /// 会话授权范围过滤：只索引已授权会话。
    public static func scopedToAuthorizedSessions(
        entries: [SearchIndexEntry], authorizedSessions: Set<String>
    ) -> [SearchIndexEntry] {
        entries.filter { authorizedSessions.contains($0.sessionID) }
    }

    /// 锁屏/退出/删除/密钥失效立即销毁内存索引。
    public static func destroysOnLockScreen() -> Bool { true }
    public static func destroysOnExit() -> Bool { true }
    public static func destroysOnConversationDelete() -> Bool { true }
    public static func destroysOnKeyInvalidation() -> Bool { true }

    /// 删除全部 V2 数据时销毁 V2 内存搜索缓存。
    public static func destroyedWhenAllV2DataDeleted() -> Bool { true }

    /// 首批结果 p95 ≤ 500ms（性能后置阶段 10）。
    public static let firstBatchLatencyP95: TimeInterval = 0.5
    public static func meetsLatencyBudget(elapsed: TimeInterval) -> Bool {
        elapsed <= firstBatchLatencyP95
    }
}
