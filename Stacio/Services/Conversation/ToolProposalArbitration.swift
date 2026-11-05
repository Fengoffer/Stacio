import Foundation

// MARK: - ToolProposalArbitrator（C2-10：串行仲裁）

/// 上游工具调用输入（原始 JSON 用于闭合校验）。
public struct ToolCallInput: Equatable, Sendable {
    public var id: String
    public var ordinal: Int
    public var rawJSON: String
    public var operation: String

    public init(id: String, ordinal: Int, rawJSON: String, operation: String) {
        self.id = id
        self.ordinal = ordinal
        self.rawJSON = rawJSON
        self.operation = operation
    }
}

public enum ToolProposalBatchResult: Equatable, Sendable {
    case created([ToolProposal])
    case protocolError(ToolProposalProtocolError)
}

public enum ToolProposalProtocolError: String, Equatable, Sendable {
    case unclosedJSON
    case duplicateToolCallID
    case missingToolCallID
    case streamInterrupted
}

/// ToolProposal 串行仲裁（纯函数）。
///
/// - 一 Invocation 多 Tool Call 按上游顺序一次性建整批不可变 proposal；
/// - 协议错误（未闭合 JSON/重复/缺失 ID/断流）→ 0 个可执行 proposal；
/// - 严格串行：队首结算后才激活下一项；拒绝一项不拒绝其余；Stop 取消所有未执行项；
/// - V2 不并行执行同一 Invocation 的工具。
public enum ToolProposalArbitrator {

    /// 解析上游 tool calls → 整批不可变 proposal（保持上游 ordinal；arbitrationOrdinal 唯一按序）。
    public static func createBatch(
        invocationID: String,
        toolCalls: [ToolCallInput]
    ) -> ToolProposalBatchResult {
        guard !toolCalls.isEmpty else {
            return .protocolError(.streamInterrupted)
        }
        var seenIDs = Set<String>()
        var proposals: [ToolProposal] = []
        for (index, call) in toolCalls.enumerated() {
            guard !call.id.isEmpty else {
                return .protocolError(.missingToolCallID)
            }
            guard !seenIDs.contains(call.id) else {
                return .protocolError(.duplicateToolCallID)
            }
            guard isClosedJSON(call.rawJSON) else {
                return .protocolError(.unclosedJSON)
            }
            seenIDs.insert(call.id)
            proposals.append(
                ToolProposal(
                    id: call.id,
                    invocationID: invocationID,
                    batchID: "batch-\(invocationID)",
                    sourceChildTaskID: nil,
                    ordinal: call.ordinal,
                    arbitrationOrdinal: index + 1,
                    sourceToolCallID: call.id,
                    immutableOperation: call.operation,
                    operationDigest: digest(of: call.operation),
                    state: .queued,
                    decisionID: nil,
                    effectID: nil,
                    terminalExecutionID: nil,
                    result: nil,
                    error: nil
                )
            )
        }
        return .created(proposals)
    }

    /// 激活队首（唯一 executing；不并行）。
    public static func activateFirst(_ proposals: [ToolProposal]) -> [ToolProposal] {
        guard let first = proposals.first(where: { $0.state == .queued }) else {
            return proposals
        }
        return proposals.map { proposal in
            guard proposal.id == first.id else { return proposal }
            var active = proposal
            active.state = .executing
            return active
        }
    }

    /// 队首结算后激活下一项；未结算返回 nil。
    public static func nextActive(after proposals: [ToolProposal]) -> ToolProposal? {
        guard let executingIndex = proposals.firstIndex(where: { $0.state == .executing }) else {
            // 无 executing：若存在 queued 则激活队首
            return proposals.first(where: { $0.state == .queued })
        }
        // 当前 executing 未结算 → 不激活下一项
        let current = proposals[executingIndex]
        if current.state == .executing {
            return nil
        }
        return proposals.first(where: { $0.state == .queued })
    }

    /// 结算一项（result 或 error）；拒绝一项不拒绝其余。
    public static func settle(
        _ proposals: [ToolProposal],
        proposalID: String,
        result: String? = nil,
        error: String? = nil
    ) -> [ToolProposal] {
        proposals.map { proposal in
            guard proposal.id == proposalID else { return proposal }
            var settled = proposal
            settled.state = .resolved
            settled.result = result
            settled.error = error
            return settled
        }
    }

    /// Stop：取消所有未执行项（queued/cancelled）；正在执行的项由执行内核确认后停止。
    public static func cancelPending(_ proposals: [ToolProposal]) -> [ToolProposal] {
        proposals.map { proposal in
            guard proposal.state == .queued || proposal.state == .evaluating || proposal.state == .awaitingApproval else {
                return proposal
            }
            var cancelled = proposal
            cancelled.state = .cancelled
            return cancelled
        }
    }

    /// 批量结果按原始 ordinal 汇总（result 非 nil 的项）。
    public static func aggregateResults(_ proposals: [ToolProposal]) -> [Int: String] {
        var aggregated: [Int: String] = [:]
        for proposal in proposals where proposal.state == .resolved {
            if let result = proposal.result {
                aggregated[proposal.ordinal] = result
            }
        }
        return aggregated
    }

    /// ChildTask 继承父 Attempt scope 且 effect 进入唯一 arbitration queue（durable arbitrationOrdinal）。
    public static func childTask(
        parent: TurnAttempt,
        runtimeTaskID: String,
        title: String,
        capabilitySnapshot: String,
        arbitrationOrdinal: Int
    ) -> ChildTask {
        ChildTask(
            id: "child-\(arbitrationOrdinal)",
            attemptID: parent.id,
            parentChildTaskID: nil,
            runtimeTaskID: runtimeTaskID,
            title: title,
            state: "running",
            sourceOrdinal: arbitrationOrdinal,
            capabilitySnapshot: capabilitySnapshot,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            usage: [:],
            childTaskIDs: [],
            invocationIDs: [],
            proposalIDs: [],
            outcome: nil,
            error: nil
        )
    }

    private static func isClosedJSON(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8) else { return false }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            _ = object
            return true
        } catch {
            return false
        }
    }

    private static func digest(of operation: String) -> String {
        "op-\(operation.count)"
    }
}
