import Foundation

// MARK: - 上下文预算与自动压缩（P4-14）

/// 保留优先级（固定，不可由用户调整顺序）：
/// 系统与安全策略 → 已冻结指令来源 → 当前目标与用户请求 → 最近有效对话
/// → 用户附件 → 工具结果摘要 → 较旧对话摘要。
public enum ContextRetentionPriority: Int, CaseIterable, Equatable, Sendable {
    case systemAndSecurityPolicy = 1
    case frozenInstructionSources
    case currentTargetAndUserRequest
    case recentConversation
    case userAttachments
    case toolResultSummaries
    case olderConversationSummaries

    public static func order() -> [ContextRetentionPriority] {
        allCases.sorted { $0.rawValue < $1.rawValue }
    }
}

/// 预算模式：上游报告真实能力 / 保守自动（能力未知时自动用后者并标注）。
public enum ContextBudgetMode: String, Codable, CaseIterable, Equatable, Sendable {
    case runtimeReported
    case conservativeAutomatic
}

public struct ContextBudgetState: Equatable, Sendable {
    public var budgetBytes: Int
    public var mode: ContextBudgetMode
    /// 保守估计标注：mode == .conservativeAutomatic 时必须展示。
    public var conservativeEstimateMarked: Bool
    /// 模型返回真实上下文能力时用上游值。
    public var upstreamReportedContextBytes: Int?

    public init(
        budgetBytes: Int = 64_000,
        mode: ContextBudgetMode = .conservativeAutomatic,
        conservativeEstimateMarked: Bool = true,
        upstreamReportedContextBytes: Int? = nil
    ) {
        self.budgetBytes = budgetBytes
        self.mode = mode
        self.conservativeEstimateMarked = conservativeEstimateMarked
        self.upstreamReportedContextBytes = upstreamReportedContextBytes
    }
}

public enum ContextBudgetAction {

    public static func retentionOrder() -> [ContextRetentionPriority] {
        ContextRetentionPriority.order()
    }

    /// 上游报告真实能力时用上游值；未知时用「保守估计」的预算（标注）。
    public static func resolvedBudget(state: ContextBudgetState) -> (bytes: Int, markedConservative: Bool) {
        if let upstream = state.upstreamReportedContextBytes, state.mode == .runtimeReported {
            return (upstream, false)
        }
        return (state.budgetBytes, true)
    }

    /// 能力未知自动用 conservativeAutomatic 并标注；不允许用户输入伪上下文窗口提升能力。
    public static func modeForUnknownCapability(selectedMode: ContextBudgetMode) -> ContextBudgetMode {
        selectedMode == .runtimeReported ? .conservativeAutomatic : selectedMode
    }

    public static func userCannotInflateContextWindow() -> Bool { true }

    /// 达到预算前先压缩旧工具输出再压缩旧对话。
    public static func compressionOrder() -> [ContextRetentionPriority] {
        [.toolResultSummaries, .olderConversationSummaries]
    }

    /// 当前请求、未完成 Decision 和最近错误不得裁剪。
    public static func neverTrimmedKinds() -> Set<String> {
        ["currentRequest", "pendingDecision", "recentErrors"]
    }

    /// 自动压缩生成 `contextSummarized` Summary Event（记录覆盖范围与来源 Turn）。
    public static func summaryEventKind() -> String { "contextSummarized" }

    /// `defaultOptionalSourceIDs` 不允许把终端全文、任意文件、记忆或附件设为无确认默认。
    public static func neverDefaultOptionalSources() -> Set<String> {
        ["terminalFullText", "anyFile", "memory", "attachments"]
    }

    /// maxSingleSourceMiB 默认 10（1..25），超限阻止并要求选片段不静默截断。
    public static func defaultMaxSingleSourceMiB() -> Int { 10 }
    public static func maxSingleSourceRange() -> ClosedRange<Int> { 1...25 }
    public static func validateMaxSingleSourceMiB(_ value: Int) -> Bool {
        maxSingleSourceRange().contains(value)
    }
    public static func oversizedSourceRequiresExplicitSelection() -> Bool { true }
}
