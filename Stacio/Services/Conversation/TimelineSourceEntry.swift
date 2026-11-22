import Foundation

/// 源条目（按 Attempt/事件顺序）。
public enum TimelineSourceEntry: Equatable, Sendable {
    case userMessage(String)
    case finalAnswer(String)
    case reasoningSummary(String)
    case planProgress(String)
    case toolCall(String, result: String?)
    case commandApproval(String)
    case executionCard(ExecutionCardPresentation)
    case terminalBlock(String)
    case userInputRequest(secure: Bool)
    case capacityWait
    case pauseCheckpoint(String)
    case errorRecovery(String)
    case childTaskGroup(String)
    case artifact(String)
}
