import Foundation

/// How a turn is executed. The services route on it, so it lives with them.

public enum TurnWorkMode: String, Codable, CaseIterable, Equatable, Sendable {
    case agent
    case planFirst
    case answerOnly

    public var displayName: String {
        switch self {
        case .agent: return "Agent"
        case .planFirst: return "先规划"
        case .answerOnly: return "仅回答"
        }
    }
}
