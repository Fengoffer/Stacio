import Foundation

public enum ComposerRunPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case preparing
    case waitingForCapacity
    case startingRuntime
    case streaming
    case toolProposed
    case executingTool
    case pausing
    case paused
    case awaitingUser
    case awaitingApproval
    case takeoverPending
    case editingQueuedItem
    case stopping
    case takenOver

    /// 活动 Turn（显示 Stop 的相位集合）。
    public var showsStop: Bool {
        switch self {
        case .idle, .editingQueuedItem, .takenOver:
            return false
        default:
            return true
        }
    }
}
