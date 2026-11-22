import Foundation

/// needsRebind 二选一：按原上下文发送 / 绑定到当前会话上下文。
public enum QueueRebindChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case sendWithOriginalContext
    case bindToCurrentSessionContext
}
