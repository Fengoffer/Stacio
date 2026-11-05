import XCTest
import Foundation
@testable import StacioApp

/// P4-14：上下文预算与自动压缩。
final class ContextBudgetTests: XCTestCase {

    // MARK: - 保留优先级固定

    func testRetentionPriorityFixedOrder() {
        XCTAssertEqual(ContextBudgetAction.retentionOrder(), [
            .systemAndSecurityPolicy,
            .frozenInstructionSources,
            .currentTargetAndUserRequest,
            .recentConversation,
            .userAttachments,
            .toolResultSummaries,
            .olderConversationSummaries
        ], "保留优先级固定（系统与安全策略最高）")
    }

    // MARK: - 预算解析

    func testUpstreamReportedUsedWhenKnown() {
        let state = ContextBudgetState(
            mode: .runtimeReported, upstreamReportedContextBytes: 200_000
        )
        let (bytes, marked) = ContextBudgetAction.resolvedBudget(state: state)
        XCTAssertEqual(bytes, 200_000, "模型返回真实上下文能力时用上游值")
        XCTAssertFalse(marked)
    }

    func testConservativeAutomaticWhenUnknown() {
        let state = ContextBudgetState(
            mode: .runtimeReported, upstreamReportedContextBytes: nil
        )
        let (bytes, marked) = ContextBudgetAction.resolvedBudget(state: state)
        XCTAssertEqual(bytes, 64_000, "能力未知用预算默认值")
        XCTAssertTrue(marked, "未知时使用标明「保守估计」的预算")
    }

    func testUnknownCapabilityForcesConservativeMode() {
        XCTAssertEqual(
            ContextBudgetAction.modeForUnknownCapability(selectedMode: .runtimeReported),
            .conservativeAutomatic,
            "能力未知自动用 conservativeAutomatic 并标注"
        )
        XCTAssertEqual(
            ContextBudgetAction.modeForUnknownCapability(selectedMode: .conservativeAutomatic),
            .conservativeAutomatic
        )
        XCTAssertTrue(ContextBudgetAction.userCannotInflateContextWindow(), "不允许用户输入伪上下文窗口提升能力")
    }

    // MARK: - 压缩顺序与不可裁剪

    func testCompressionOrderToolOutputBeforeOldConversation() {
        XCTAssertEqual(ContextBudgetAction.compressionOrder(), [
            .toolResultSummaries, .olderConversationSummaries
        ], "达到预算前先压缩旧工具输出再压缩旧对话")
    }

    func testNeverTrimmedKinds() {
        let neverTrim = ContextBudgetAction.neverTrimmedKinds()
        XCTAssertTrue(neverTrim.contains("currentRequest"), "当前请求不得裁剪")
        XCTAssertTrue(neverTrim.contains("pendingDecision"), "未完成 Decision 不得裁剪")
        XCTAssertTrue(neverTrim.contains("recentErrors"), "最近错误不得裁剪")
    }

    func testAutoCompressionWritesSummarizedEvent() {
        XCTAssertEqual(ContextBudgetAction.summaryEventKind(), "contextSummarized")
    }

    // MARK: - defaultOptionalSourceIDs

    func testNeverDefaultOptionalSources() {
        let never = ContextBudgetAction.neverDefaultOptionalSources()
        XCTAssertTrue(never.contains("terminalFullText"), "终端全文不可无确认默认")
        XCTAssertTrue(never.contains("anyFile"), "任意文件不可无确认默认")
        XCTAssertTrue(never.contains("memory"), "记忆不可无确认默认")
        XCTAssertTrue(never.contains("attachments"), "附件不可无确认默认")
    }

    // MARK: - maxSingleSourceMiB

    func testMaxSingleSourceLimit() {
        XCTAssertEqual(ContextBudgetAction.defaultMaxSingleSourceMiB(), 10, "默认 10")
        XCTAssertTrue(ContextBudgetAction.validateMaxSingleSourceMiB(1))
        XCTAssertTrue(ContextBudgetAction.validateMaxSingleSourceMiB(10))
        XCTAssertTrue(ContextBudgetAction.validateMaxSingleSourceMiB(25))
        XCTAssertFalse(ContextBudgetAction.validateMaxSingleSourceMiB(0))
        XCTAssertFalse(ContextBudgetAction.validateMaxSingleSourceMiB(26))
        XCTAssertTrue(ContextBudgetAction.oversizedSourceRequiresExplicitSelection(), "超限要求选片段不静默截断")
    }
}
