import Foundation

// MARK: - Native API Runtime（P7-2）

/// Native 请求快照：携带 Conversation/Turn/Attempt/TargetBinding/targetWorkingDirectory。
/// Native 无本地 CLI cwd——`agentProcessWorkingDirectory` 恒为 nil（不能伪造）。
public struct NativeRequestSnapshot: Equatable, Sendable {
    public let conversationID: String
    public let turnID: String
    public let attemptID: String
    public let targetBindingDigest: String
    public let targetWorkingDirectory: String?
    public let agentProcessWorkingDirectory: String?
    /// Frozen V2 work contract for this provider invocation. It must come from
    /// the durable Attempt/queued-input snapshot, never from live Composer UI.
    public let workMode: WorkMode

    public init(
        conversationID: String, turnID: String, attemptID: String,
        targetBindingDigest: String, targetWorkingDirectory: String?,
        workMode: WorkMode = .agent
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.attemptID = attemptID
        self.targetBindingDigest = targetBindingDigest
        self.targetWorkingDirectory = targetWorkingDirectory
        self.agentProcessWorkingDirectory = nil
        self.workMode = workMode
    }
}

/// 流式 tool_call delta 的 ephemeral parser 状态（只有完整验证后一次建整批 proposal）。
public enum NativeToolParsingState: Equatable, Sendable {
    case idle
    case accumulating(ordinal: Int, json: String)
}

public enum NativeRuntimeResult: Equatable, Sendable {
    case finalAnswer(text: String)
    /// 完整验证后一次建整批 proposal。
    case toolBatch(proposals: [String], ordinal: Int)
    case reasoningSummary(text: String)
    case usage(completionTokens: Int)
    /// answer-only 时 Runtime 返回工具请求 → resolved(workModeDenied)，绝不创建 EffectCommand。
    case workModeDenied
    case protocolFailure
}

public enum NativeAPIRuntimeAction {

    /// Native Runtime 不直接操作 SSH/文件系统/终端（工具调用进入现有执行协调器/权限/审计/脱敏链）。
    public static func touchesSSHOrFileSystemDirectly() -> Bool { false }
    public static func toolCallsEnterExistingExecutionChain() -> Bool { true }

    /// 模型请求失败保持原供应商与模型，不隐式重路由。
    public static func failureKeepsProviderAndModel() -> Bool { true }

    /// 流式 tool_call delta 只是 ephemeral parser state。
    public static func toolDeltaIsEphemeralParserState() -> Bool { true }

    /// 只有验证完整 JSON/schema/batch/finish reason/source ordinal 后一次建整批 proposal。
    public static func toolBatchBuiltOnlyAfterFullValidation() -> Bool { true }

    /// 初始 answer-only 与 answerRegeneration 都不发送 effect tool schema。
    public static func answerOnlySendsNoEffectToolSchema() -> Bool { true }

    /// answer-only 时 Runtime 返回工具请求只 resolved(workModeDenied) 或协议失败，绝不创建 EffectCommand。
    public static func answerOnlyToolRequestResolvesWorkModeDenied() -> Bool { true }

    /// Native 无本地 CLI cwd，不能伪造 AgentProcessWorkingDirectory。
    public static func nativeCannotForgeAgentProcessWorkingDirectory() -> Bool { true }

    public static func requestSnapshot(
        conversationID: String, turnID: String, attemptID: String,
        targetBindingDigest: String, targetWorkingDirectory: String?,
        workMode: WorkMode = .agent
    ) -> NativeRequestSnapshot {
        NativeRequestSnapshot(
            conversationID: conversationID, turnID: turnID, attemptID: attemptID,
            targetBindingDigest: targetBindingDigest,
            targetWorkingDirectory: targetWorkingDirectory,
            workMode: workMode
        )
    }

    // MARK: - 流式解析

    public static func beginToolAccumulation(ordinal: Int) -> NativeToolParsingState {
        .accumulating(ordinal: ordinal, json: "")
    }

    public static func appendToolDelta(_ state: NativeToolParsingState, delta: String) -> NativeToolParsingState {
        guard case .accumulating(let ordinal, let json) = state else { return state }
        return .accumulating(ordinal: ordinal, json: json + delta)
    }

    /// 验证完整 JSON + schema 字段 + finish reason + source ordinal 后才可建批。
    public static func validateToolBatch(
        json: String, schemaFields: Set<String>, finishReason: String
    ) -> Bool {
        guard finishReason == "tool_calls" || finishReason == "stop" else { return false }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return schemaFields.allSatisfy { object[$0] != nil }
    }
}
