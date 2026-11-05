import XCTest
import Foundation
@testable import StacioApp

/// P8-5：LocalAgentRuntime 与结构化事件（协议、来源保留、配置验证、ChildTask 继承、answer-only 结算顺序）。
final class LocalAgentRuntimeTests: XCTestCase {

    // MARK: - 结构化事件协议

    func testStructuredProtocols() {
        XCTAssertEqual(LocalAgentRuntimeAction.structuredProtocols(), ["JSONL", "RPC", "ACP"])
    }

    func testEventRetainsSourceAndOrdinal() {
        let event = StructuredEvent(
            kind: "toolCall", sourceProtocol: "JSONL", sourceOrdinal: 7,
            originalEventReference: "jsonl:line:7"
        )
        XCTAssertTrue(LocalAgentRuntimeAction.eventRetainsSourceAndOrdinal(event),
                      "映射为统一事件但保留来源/原始事件引用/source ordinal")
        XCTAssertFalse(
            LocalAgentRuntimeAction.eventRetainsSourceAndOrdinal(
                StructuredEvent(kind: "x", sourceProtocol: "", sourceOrdinal: 0, originalEventReference: "")
            )
        )
        XCTAssertEqual(event.sourceOrdinal, 7)
        XCTAssertEqual(event.originalEventReference, "jsonl:line:7")
    }

    // MARK: - 配置验证

    func testLaunchUsesOnlyVerifiedConfiguration() {
        XCTAssertTrue(LocalAgentRuntimeAction.launchUsesOnlyVerifiedConfiguration(),
                      "启动只用 LocalAgentConfiguration 固定绝对路径/descriptor argv/本地目录/PATH/环境白名单")
        XCTAssertTrue(LocalAgentRuntimeAction.digestMismatchMeansUnverified(),
                      "版本或 environment digest 与已验证值不符 → 待验证不继续宣称结构化/managed")
    }

    // MARK: - ChildTask 继承

    func testChildTaskInheritanceAndEscalationRejection() {
        XCTAssertTrue(LocalAgentRuntimeAction.childTaskInheritsParentCapabilityScope(),
                      "structured ChildTask 必须继承父 Attempt capability scope")
        XCTAssertTrue(LocalAgentRuntimeAction.brokerRejectsChildSelfDeclaredEscalation(),
                      "Broker 拒绝 child 自报新 target/credential/cwd/tool/更高权限")
    }

    func testSubagentsDeclaredOnlyAfterCreationAndStopSummary() {
        XCTAssertTrue(LocalAgentRuntimeAction.subagentsDeclaredOnlyAfterCreationAndStopSummary(),
                      "Runtime 不能在创建前接受最大 ChildTask 数/父 Stop 取消全子任务并汇总终态才能声明 subagents")
        XCTAssertTrue(LocalAgentRuntimeAction.parentStopCancelsAllChildTasks(),
                      "父 Stop 取消全子任务")
    }

    // MARK: - answer-only 结算顺序

    func testAnswerOnlySettlementOrder() {
        XCTAssertEqual(LocalAgentRuntimeAction.answerOnlySettlementOrder(), [
            "revokeCapability",
            "confirmProcessChainExitOrIsolation",
            "settleScratchDeletionFence",
            "canonicalFinalCAS"
        ], "managed answer-only 输出结束后先撤销 capability、确认进程链退出/隔离并结算 scratch deletion fence 再允许 canonical final CAS")
    }
}
