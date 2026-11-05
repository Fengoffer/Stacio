import Foundation

// MARK: - Conversation Timeline 投影（P6-1）

/// 时间线条目类型（覆盖 C2-1/C2-3 语义全集）。
public enum TimelineItemKind: Equatable, Sendable {
    case userMessage
    case finalAnswer
    case reasoningSummary
    case planAndTaskProgress
    /// 多 Tool Call 按 1/N 归入同一 proposal batch。
    case toolCallAndResult(toolIndex: Int, totalInBatch: Int)
    case commandPreviewAndApproval
    case terminalExecutionBlock
    case requestUserInput(isSecure: Bool)
    case globalCapacityWait
    case pauseCheckpointAndResume
    case errorAndRecovery
    case verifiedChildTaskGroup
    case artifact
}

/// 时间线条目（投影结果）。
public struct TimelineItem: Equatable, Sendable {
    public let kind: TimelineItemKind
    /// 「重新生成回答」期间继续展示上一条 canonical answer。
    public let canonicalAnswerVisible: Bool
    /// 独立 regeneration preview。
    public let regenerationPreview: Bool
    /// preview 期间「不会执行工具/终端/目标变更」标记。
    public let noToolTerminalTargetChanges: Bool
    /// Local Agent 条目持续标明 managed/terminalPassthrough。
    public let localAgentMode: LocalAgentExecutionMode?
    /// Process 运行时展开完成折叠为「已处理 X 秒 · N 个步骤」。
    public let foldedProcessSummary: String?

    public init(
        kind: TimelineItemKind,
        canonicalAnswerVisible: Bool = true,
        regenerationPreview: Bool = false,
        noToolTerminalTargetChanges: Bool = false,
        localAgentMode: LocalAgentExecutionMode? = nil,
        foldedProcessSummary: String? = nil
    ) {
        self.kind = kind
        self.canonicalAnswerVisible = canonicalAnswerVisible
        self.regenerationPreview = regenerationPreview
        self.noToolTerminalTargetChanges = noToolTerminalTargetChanges
        self.localAgentMode = localAgentMode
        self.foldedProcessSummary = foldedProcessSummary
    }
}

/// 投影输入（由 ConversationSessionState 派生；测试直接构造）。
public struct TimelineProjectionInput: Equatable, Sendable {
    public var entries: [TimelineSourceEntry]
    public var regeneratingAnswer: Bool
    public var canonicalAnswerText: String?

    public init(entries: [TimelineSourceEntry] = [], regeneratingAnswer: Bool = false, canonicalAnswerText: String? = nil) {
        self.entries = entries
        self.regeneratingAnswer = regeneratingAnswer
        self.canonicalAnswerText = canonicalAnswerText
    }
}

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

public enum ConversationTimelineProjection {

    /// 投影：源条目 → 时间线条目（含折叠、标注、分组、regeneration 语义）。
    public static func project(_ input: TimelineProjectionInput) -> [TimelineItem] {
        var items: [TimelineItem] = []
        // 多 Tool Call 按出现顺序编号，同一 proposal batch 共享 total
        var toolCallCount = 0
        let toolCalls = input.entries.filter { if case .toolCall = $0 { return true }; return false }.count
        for entry in input.entries {
            switch entry {
            case .userMessage:
                items.append(TimelineItem(kind: .userMessage))
            case .finalAnswer:
                // 最终回答独立可见（不埋在 Process）
                items.append(TimelineItem(kind: .finalAnswer))
            case .reasoningSummary:
                items.append(TimelineItem(kind: .reasoningSummary))
            case .planProgress:
                items.append(TimelineItem(kind: .planAndTaskProgress))
            case .toolCall:
                toolCallCount += 1
                items.append(TimelineItem(
                    kind: .toolCallAndResult(toolIndex: toolCallCount, totalInBatch: toolCalls)
                ))
            case .commandApproval:
                items.append(TimelineItem(kind: .commandPreviewAndApproval))
            case .executionCard:
                items.append(TimelineItem(kind: .terminalExecutionBlock))
            case .terminalBlock:
                items.append(TimelineItem(kind: .terminalExecutionBlock))
            case .userInputRequest(let secure):
                items.append(TimelineItem(kind: .requestUserInput(isSecure: secure)))
            case .capacityWait:
                items.append(TimelineItem(kind: .globalCapacityWait))
            case .pauseCheckpoint:
                items.append(TimelineItem(kind: .pauseCheckpointAndResume))
            case .errorRecovery:
                items.append(TimelineItem(kind: .errorAndRecovery))
            case .childTaskGroup:
                items.append(TimelineItem(kind: .verifiedChildTaskGroup))
            case .artifact:
                items.append(TimelineItem(kind: .artifact))
            }
        }
        // 「重新生成回答」期间：canonical answer 继续展示 + 独立 regeneration preview
        if input.regeneratingAnswer {
            items = items.map { item in
                guard item.kind == .finalAnswer else { return item }
                return TimelineItem(
                    kind: item.kind,
                    canonicalAnswerVisible: true,
                    regenerationPreview: true,
                    noToolTerminalTargetChanges: true,
                    localAgentMode: item.localAgentMode,
                    foldedProcessSummary: item.foldedProcessSummary
                )
            }
        }
        return items
    }

    /// Process 运行时展开完成折叠为「已处理 X 秒 · N 个步骤」。
    public static func processFoldedSummary(seconds: Int, steps: Int) -> String {
        "已处理 \(seconds) 秒 · \(steps) 个步骤"
    }

    /// 多 Tool Call 标签（1/N 归入同一 proposal batch）。
    public static func toolBatchLabel(index: Int, total: Int) -> String {
        "\(index)/\(total)"
    }

    /// Local Agent 条目持续标明 managed/terminalPassthrough（PTY 不能用盾牌/受控/已审批图标）。
    public static func localAgentLabel(mode: LocalAgentExecutionMode) -> String {
        mode == .controlled ? "受控" : "终端透传"
    }

    /// 无盾牌/受控/已审批图标的 PTY 条目（本地 Agent 透传终端不能用这些图标）。
    public static func ptyMustNotUseShieldOrApprovedIcons() -> Bool { true }

    /// TakenOver 终态条目后接新 Attempt 连续条目（顺序由 entries 保持）。
    public static func consecutiveAfterTakeover() -> Bool { true }
}
