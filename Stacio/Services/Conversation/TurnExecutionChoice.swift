import Foundation

/// How a turn is executed. Declared with the conversation services because they
/// persist and route it; the views only read it.

public enum TurnExecutionChoice: String, Codable, CaseIterable, Equatable, Sendable {
    /// Settings 选择 `ask` 时的未决状态；不能被写入一个新的 Turn。
    case ask
    case realTerminal
    case backgroundVirtualTerminal
}
