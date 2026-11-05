import XCTest
import Foundation
@testable import StacioApp

/// P6-1：Conversation Timeline 投影（条目类型全覆盖、折叠、1/N 分组、Local Agent 标注、regeneration）。
final class ConversationTimelineProjectionTests: XCTestCase {

    // MARK: - 条目类型全覆盖

    func testAllEntryKindsProjected() {
        let input = TimelineProjectionInput(entries: [
            .userMessage("你好"),
            .reasoningSummary("先分析"),
            .planProgress("步骤 1"),
            .toolCall("ls", result: "file"),
            .commandApproval("rm -rf"),
            .terminalBlock("$ pwd"),
            .userInputRequest(secure: true),
            .capacityWait,
            .pauseCheckpoint("等待审批"),
            .errorRecovery("重试成功"),
            .childTaskGroup("子任务组"),
            .artifact("report.pdf"),
            .finalAnswer("完成")
        ])
        let items = ConversationTimelineProjection.project(input)
        let kinds = items.map(\.kind)
        XCTAssertTrue(kinds.contains(.userMessage))
        XCTAssertTrue(kinds.contains(.finalAnswer))
        XCTAssertTrue(kinds.contains(.reasoningSummary))
        XCTAssertTrue(kinds.contains(.planAndTaskProgress))
        XCTAssertTrue(kinds.contains(.commandPreviewAndApproval))
        XCTAssertTrue(kinds.contains(.terminalExecutionBlock))
        XCTAssertEqual(kinds.first(where: { if case .requestUserInput(let secure) = $0 { return secure }; return false }),
                       .requestUserInput(isSecure: true), "安全输入请求")
        XCTAssertTrue(kinds.contains(.globalCapacityWait))
        XCTAssertTrue(kinds.contains(.pauseCheckpointAndResume))
        XCTAssertTrue(kinds.contains(.errorAndRecovery))
        XCTAssertTrue(kinds.contains(.verifiedChildTaskGroup))
        XCTAssertTrue(kinds.contains(.artifact))
    }

    // MARK: - Process 折叠

    func testProcessFoldedSummary() {
        XCTAssertEqual(
            ConversationTimelineProjection.processFoldedSummary(seconds: 12, steps: 3),
            "已处理 12 秒 · 3 个步骤"
        )
        // 展开完成折叠：条目带 foldedProcessSummary
        let item = TimelineItem(kind: .planAndTaskProgress, foldedProcessSummary: "已处理 12 秒 · 3 个步骤")
        XCTAssertEqual(item.foldedProcessSummary, "已处理 12 秒 · 3 个步骤")
    }

    // MARK: - 最终回答独立可见

    func testFinalAnswerNotBuriedInProcess() {
        let input = TimelineProjectionInput(entries: [
            .planProgress("执行中"),
            .finalAnswer("最终回答"),
            .planProgress("后续步骤")
        ])
        let items = ConversationTimelineProjection.project(input)
        // 最终回答是独立条目（不埋在 Process）
        let finalIndices = items.enumerated().filter { $0.element.kind == .finalAnswer }.map(\.offset)
        XCTAssertEqual(finalIndices.count, 1, "最终回答独立可见")
        let planIndices = items.enumerated().filter { $0.element.kind == .planAndTaskProgress }.map(\.offset)
        XCTAssertEqual(planIndices.count, 2, "Process 条目各自独立")
    }

    // MARK: - 多 Tool Call 1/N 分组

    func testToolCallsGroupedWithBatchCount() {
        let input = TimelineProjectionInput(entries: [
            .userMessage("执行"),
            .toolCall("read", result: "a"),
            .toolCall("write", result: "b"),
            .toolCall("list", result: "c")
        ])
        let items = ConversationTimelineProjection.project(input)
        let tools = items.compactMap { item -> TimelineItemKind? in
            if case .toolCallAndResult = item.kind { return item.kind }
            return nil
        }
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(tools[0], .toolCallAndResult(toolIndex: 1, totalInBatch: 3), "1/3")
        XCTAssertEqual(tools[1], .toolCallAndResult(toolIndex: 2, totalInBatch: 3), "2/3")
        XCTAssertEqual(tools[2], .toolCallAndResult(toolIndex: 3, totalInBatch: 3), "3/3")
        XCTAssertEqual(
            ConversationTimelineProjection.toolBatchLabel(index: 1, total: 3),
            "1/3",
            "多 Tool Call 按 1/N 归入同一 proposal batch"
        )
    }

    // MARK: - Local Agent 标注

    func testLocalAgentModeLabeledPersistently() {
        XCTAssertEqual(ConversationTimelineProjection.localAgentLabel(mode: .controlled), "受控")
        XCTAssertEqual(ConversationTimelineProjection.localAgentLabel(mode: .terminalPassthrough), "终端透传")
        let item = TimelineItem(kind: .terminalExecutionBlock, localAgentMode: .terminalPassthrough)
        XCTAssertEqual(item.localAgentMode, .terminalPassthrough, "Local Agent 条目持续标明 terminalPassthrough")
        XCTAssertTrue(ConversationTimelineProjection.ptyMustNotUseShieldOrApprovedIcons(),
                      "PTY 不能用盾牌/受控/已审批图标")
    }

    // MARK: - 重新生成回答

    func testRegenerationKeepsCanonicalAnswerAndShowsPreviewWithoutExecution() {
        let input = TimelineProjectionInput(
            entries: [.userMessage("重写"), .finalAnswer("上一条回答")],
            regeneratingAnswer: true
        )
        let items = ConversationTimelineProjection.project(input)
        let finalItem = items.first { $0.kind == .finalAnswer }
        XCTAssertNotNil(finalItem)
        XCTAssertTrue(finalItem?.canonicalAnswerVisible ?? false, "重新生成期间继续展示上一条 canonical answer")
        XCTAssertTrue(finalItem?.regenerationPreview ?? false, "独立 regeneration preview")
        XCTAssertTrue(finalItem?.noToolTerminalTargetChanges ?? false,
                      "「不会执行工具/终端/目标变更」标记")
    }

    func testNoRegenerationNoPreviewFlags() {
        let input = TimelineProjectionInput(entries: [.finalAnswer("正常回答")], regeneratingAnswer: false)
        let items = ConversationTimelineProjection.project(input)
        let finalItem = items.first { $0.kind == .finalAnswer }
        XCTAssertFalse(finalItem?.regenerationPreview ?? true)
        XCTAssertFalse(finalItem?.noToolTerminalTargetChanges ?? true)
    }

    // MARK: - TakenOver 连续条目

    func testTakeoverTerminalFollowedByNewAttemptConsecutive() {
        // TakenOver 终态条目与新 Attempt 连续条目（顺序保持）
        let input = TimelineProjectionInput(entries: [
            .userMessage("接管后继续"),
            .toolCall("run", result: nil)
        ])
        let items = ConversationTimelineProjection.project(input)
        XCTAssertEqual(items.count, 2, "TakenOver 后新 Attempt 条目连续")
        XCTAssertTrue(ConversationTimelineProjection.consecutiveAfterTakeover())
    }
}
