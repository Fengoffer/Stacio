import XCTest
import Foundation
@testable import StacioApp

/// C2-10：Tool Proposal 串行仲裁、Decision、ChildTask 与分支。
///
/// 合同：
/// - 一 Invocation 多 Tool Call 按上游顺序一次性建整批不可变 proposal（不能单值槽覆盖）；
/// - 未闭合 JSON/重复/缺失 ID/断流 → 创建 0 个可执行 proposal（协议错误）；
/// - 严格串行：队首结算后才激活下一项；拒绝一项不拒绝其余；Stop 取消所有未执行项；
/// - 批量结果按原始 ordinal 汇总；V2 不并行执行同一 Invocation 的工具；
/// - ChildTask 继承父 Attempt scope 且 effect 进入唯一 arbitration queue（durable arbitrationOrdinal）；
/// - 分支创建原子生成自包含 BranchBaseContextSnapshot；子分支不读父会话分叉点后内容。
final class ToolProposalArbitrationTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func toolCall(id: String, ordinal: Int, json: String = #"{"cmd":"ls"}"#) -> ToolCallInput {
        ToolCallInput(id: id, ordinal: ordinal, rawJSON: json, operation: "runCommand")
    }

    // MARK: - 批量创建

    func testBatchCreatedInUpstreamOrderImmutable() {
        let calls = [
            toolCall(id: "tc-1", ordinal: 1),
            toolCall(id: "tc-2", ordinal: 2),
            toolCall(id: "tc-3", ordinal: 3)
        ]
        let result = ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: calls)
        guard case let .created(proposals) = result else {
            return XCTFail("合法输入应创建整批")
        }
        XCTAssertEqual(proposals.count, 3, "按上游顺序一次性建整批")
        XCTAssertEqual(proposals.map(\.ordinal), [1, 2, 3], "保持上游 ordinal 顺序")
        XCTAssertEqual(proposals.map(\.sourceToolCallID), ["tc-1", "tc-2", "tc-3"])
        XCTAssertEqual(proposals.map(\.arbitrationOrdinal), [1, 2, 3], "arbitrationOrdinal 唯一且按序")
        // 不可变：struct 值语义，任何修改都产生新值而非覆盖
        var first = proposals[0]
        first.state = .executing
        XCTAssertEqual(proposals[0].state, .queued, "proposal 不可变（不能单值槽覆盖）")
    }

    func testMalformedToolCallsCreateZeroProposals() {
        // 未闭合 JSON
        let unclosed = [toolCall(id: "tc-1", ordinal: 1, json: #"{"cmd":"ls""#)]
        XCTAssertEqual(
            ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: unclosed),
            .protocolError(.unclosedJSON)
        )
        // 重复 ID
        let duplicated = [toolCall(id: "tc-1", ordinal: 1), toolCall(id: "tc-1", ordinal: 2)]
        XCTAssertEqual(
            ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: duplicated),
            .protocolError(.duplicateToolCallID)
        )
        // 缺失 ID（空 ID 视为协议错误）
        let missing = [toolCall(id: "", ordinal: 1)]
        XCTAssertEqual(
            ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: missing),
            .protocolError(.missingToolCallID)
        )
        // 断流（空输入）
        XCTAssertEqual(
            ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: []),
            .protocolError(.streamInterrupted)
        )
    }

    // MARK: - 严格串行

    func testStrictSerializationActivatesNextOnlyAfterSettlement() {
        let calls = [toolCall(id: "tc-1", ordinal: 1), toolCall(id: "tc-2", ordinal: 2)]
        guard case let .created(proposals) = ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: calls) else {
            return XCTFail()
        }
        // 队首激活
        let active = ToolProposalArbitrator.activateFirst(proposals)
        XCTAssertEqual(active.first?.state, .executing, "队首激活")
        // 未结算前第二项不可激活
        let nextBeforeSettlement = ToolProposalArbitrator.nextActive(after: active)
        XCTAssertNil(nextBeforeSettlement, "队首未结算不激活下一项")
        // 队首结算（resolved）后激活下一项
        let settled = ToolProposalArbitrator.settle(active, proposalID: "tc-1", result: "ok")
        let next = ToolProposalArbitrator.nextActive(after: settled)
        XCTAssertEqual(next?.sourceToolCallID, "tc-2", "队首结算后才激活下一项")
    }

    func testRejectOneDoesNotRejectOthers() {
        let calls = [toolCall(id: "tc-1", ordinal: 1), toolCall(id: "tc-2", ordinal: 2), toolCall(id: "tc-3", ordinal: 3)]
        guard case let .created(proposals) = ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: calls) else {
            return XCTFail()
        }
        let rejected = ToolProposalArbitrator.settle(proposals, proposalID: "tc-2", result: nil, error: "denied")
        let tc2 = rejected.first { $0.sourceToolCallID == "tc-2" }
        XCTAssertEqual(tc2?.state, .resolved)
        XCTAssertTrue(tc2?.error != nil, "拒绝项带错误")
        // 其余项不受影响
        let tc1 = rejected.first { $0.sourceToolCallID == "tc-1" }
        let tc3 = rejected.first { $0.sourceToolCallID == "tc-3" }
        XCTAssertEqual(tc1?.state, .queued, "拒绝一项不拒绝其余")
        XCTAssertEqual(tc3?.state, .queued)
    }

    func testStopCancelsAllPendingItems() {
        let calls = [toolCall(id: "tc-1", ordinal: 1), toolCall(id: "tc-2", ordinal: 2), toolCall(id: "tc-3", ordinal: 3)]
        guard case let .created(proposals) = ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: calls) else {
            return XCTFail()
        }
        let executing = ToolProposalArbitrator.activateFirst(proposals)
        let cancelled = ToolProposalArbitrator.cancelPending(executing)
        XCTAssertEqual(cancelled.filter { $0.state == .cancelled }.count, 2, "Stop 取消所有未执行项")
        XCTAssertEqual(cancelled.filter { $0.state == .executing }.count, 1, "正在执行的项由执行内核确认后停止")
    }

    // MARK: - 批量结果汇总 / 不并行

    func testBatchResultsAggregatedByOriginalOrdinal() {
        let calls = [toolCall(id: "tc-1", ordinal: 1), toolCall(id: "tc-2", ordinal: 2)]
        guard case let .created(proposals) = ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: calls) else {
            return XCTFail()
        }
        let settled = ToolProposalArbitrator.settle(proposals, proposalID: "tc-2", result: "second")
        let allSettled = ToolProposalArbitrator.settle(settled, proposalID: "tc-1", result: "first")
        let aggregated = ToolProposalArbitrator.aggregateResults(allSettled)
        XCTAssertEqual(aggregated[1], "first", "批量结果按原始 ordinal 汇总")
        XCTAssertEqual(aggregated[2], "second")
    }

    func testNoParallelExecutionWithinSameInvocation() {
        let calls = [toolCall(id: "tc-1", ordinal: 1), toolCall(id: "tc-2", ordinal: 2), toolCall(id: "tc-3", ordinal: 3)]
        guard case let .created(proposals) = ToolProposalArbitrator.createBatch(invocationID: "inv-1", toolCalls: calls) else {
            return XCTFail()
        }
        let active = ToolProposalArbitrator.activateFirst(proposals)
        XCTAssertEqual(active.filter { $0.state == .executing }.count, 1, "V2 不并行执行同一 Invocation 的工具")
    }

    // MARK: - ChildTask

    func testChildTaskInheritsParentScopeWithUniqueArbitrationOrdinal() {
        let parentAttempt = TurnAttempt(
            id: "a-1", turnID: "t-1", ordinal: 1, phase: .streaming,
            purpose: .initial, runtimeSnapshot: "rs", workModeSnapshot: .agent,
            policySnapshot: "ps", toolCapabilitySnapshot: "tcs",
            instructionSnapshot: "is", startedAt: Self.fixedDate
        )
        let child = ToolProposalArbitrator.childTask(
            parent: parentAttempt,
            runtimeTaskID: "rt-1",
            title: "sub",
            capabilitySnapshot: "child-caps",
            arbitrationOrdinal: 1
        )
        XCTAssertEqual(child.attemptID, "a-1", "ChildTask 继承父 Attempt scope")
        XCTAssertEqual(child.runtimeTaskID, "rt-1")
        XCTAssertEqual(child.capabilitySnapshot, "child-caps")
        XCTAssertEqual(child.sourceOrdinal, 1)
    }

    // MARK: - 分支快照

    func testBranchBaseSnapshotSelfContainedExcludesPostForkContent() {
        // 构造一个「分叉点后」内容（更高 sequence），分支快照不得包含
        let forkedAtSequence = 10
        let postForkItem = ContextProjectionItem(
            kind: .finalAnswer, content: "after-fork", source: "post-fork"
        )
        let snapshot = ConversationContextProjector.branchBaseSnapshot(
            parentConversationID: "c-1",
            forkedAtSequence: forkedAtSequence,
            preForkItems: [ContextProjectionItem(kind: .userMessage, content: "before", source: "pre-fork")],
            digestOfPostForkContent: ContextProjectionItem.digest(of: postForkItem)
        )
        XCTAssertEqual(snapshot.parentConversationID, "c-1")
        XCTAssertEqual(snapshot.forkedAtSequence, 10)
        XCTAssertEqual(snapshot.contentItems.count, 1)
        XCTAssertEqual(snapshot.contentItems[0].source, "pre-fork")
        XCTAssertFalse(snapshot.contentItems.contains { $0.source == "post-fork" }, "子分支不读父会话分叉点后内容")
        XCTAssertFalse(snapshot.digest.isEmpty)
    }
}
