import Foundation

// MARK: - 高级诊断与可观测性关联链（P4-16）

/// 全链路关联链：`Conversation → Turn → Attempt → Admission Lease/Scheduler Generation
/// → Permit/Target Journal → Invocation/Provider Request 或 Local Agent Session
/// → Capability/Process Generation → Tool Proposal → Terminal Execution ID`。
public struct ObservabilityCorrelationChain: Equatable, Sendable {
    public let conversationID: String
    public let turnID: String
    public let attemptID: String
    public let admissionLeaseID: String
    public let schedulerGeneration: Int
    public let permitID: String?
    public let invocationID: String?
    public let providerRequestID: String?
    public let localAgentSessionID: String?
    public let capabilityGeneration: String?
    public let toolProposalID: String?
    public let terminalExecutionID: String?

    public init(
        conversationID: String, turnID: String, attemptID: String,
        admissionLeaseID: String, schedulerGeneration: Int,
        permitID: String?, invocationID: String?, providerRequestID: String?,
        localAgentSessionID: String?, capabilityGeneration: String?,
        toolProposalID: String?, terminalExecutionID: String?
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.attemptID = attemptID
        self.admissionLeaseID = admissionLeaseID
        self.schedulerGeneration = schedulerGeneration
        self.permitID = permitID
        self.invocationID = invocationID
        self.providerRequestID = providerRequestID
        self.localAgentSessionID = localAgentSessionID
        self.capabilityGeneration = capabilityGeneration
        self.toolProposalID = toolProposalID
        self.terminalExecutionID = terminalExecutionID
    }

    /// 从时间线追到脱敏日志：关联 ID 只指向脱敏日志路径（不含正文）。
    public func redactedLogPath() -> String {
        "redacted-logs/\(conversationID)/\(turnID)/\(attemptID)/\(admissionLeaseID).jsonl"
    }
}

/// 高级诊断面板只读投影（脱敏）。
public struct AdvancedDiagnosticsSnapshot: Equatable, Sendable {
    public let catalogSetRevision: Int
    public let catalogResourceHashes: [String: String]
    public let modelSyncRawState: String
    public let schedulerGeneration: Int
    public let localAgentContainment: LocalAgentContainment
    public let localAgentProcessState: LocalAgentSettingsProcessState
    public let externalEffectReconciliationSummary: String
    public let correlationChain: ObservabilityCorrelationChain

    public init(
        catalogSetRevision: Int, catalogResourceHashes: [String: String],
        modelSyncRawState: String, schedulerGeneration: Int,
        localAgentContainment: LocalAgentContainment,
        localAgentProcessState: LocalAgentSettingsProcessState,
        externalEffectReconciliationSummary: String,
        correlationChain: ObservabilityCorrelationChain
    ) {
        self.catalogSetRevision = catalogSetRevision
        self.catalogResourceHashes = catalogResourceHashes
        self.modelSyncRawState = modelSyncRawState
        self.schedulerGeneration = schedulerGeneration
        self.localAgentContainment = localAgentContainment
        self.localAgentProcessState = localAgentProcessState
        self.externalEffectReconciliationSummary = externalEffectReconciliationSummary
        self.correlationChain = correlationChain
    }
}

public enum AdvancedDiagnosticsAction {

    /// 高级诊断只暴露脱敏信息（不显示原始 Key、Token、capability 或完整环境变量）。
    public static func redacted(_ value: String) -> String {
        value.isEmpty ? "" : "[redacted]"
    }

    public static func showsRawSecrets() -> Bool { false }

    /// 损坏/混合 Catalog Set 只允许诊断，不能继续新执行。
    public static func corruptedCatalogAllowsDiagnosticsOnly() -> Bool { true }
    public static func corruptedCatalogBlocksNewExecution() -> Bool { true }

    /// 默认日志只记录阶段/耗时/状态/字节数/错误类别。
    public static func defaultLogFields() -> Set<String> {
        ["phase", "duration", "state", "byteCount", "errorCategory"]
    }

    /// Prompt/回复正文/终端内容/附件默认不进遥测。
    public static func contentNeverInTelemetry() -> Set<String> {
        ["promptBody", "responseBody", "terminalContent", "attachments"]
    }

    /// 诊断包导出前显示文件清单与脱敏预览；永不包含 Keychain 凭证/OAuth/安全输入/完整环境变量。
    public static func exportShowsManifestAndRedactedPreviewFirst() -> Bool { true }
    public static func exportNeverIncludesSensitive() -> Bool { true }

    /// `assistant.resetCaches` 只删除可再生模型/Catalog 诊断缓存。
    public static func resetCachesRemovesOnlyRegenerable() -> Bool { true }

    /// `assistant.redetectRuntimes` 逐配置创建独立 detect operation 且受 settings-process 全局上限 1 约束。
    public static func redetectPerConfigurationIndependentOperation() -> Bool { true }
    public static func redetectSubjectToGlobalLimitOne() -> Bool { true }
}
