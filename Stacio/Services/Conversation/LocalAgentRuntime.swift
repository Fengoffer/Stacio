import Foundation

// MARK: - Local Agent Runtime 与结构化事件（P8-5）

/// 结构化事件（保留来源/原始事件引用/source ordinal）。
public struct StructuredEvent: Equatable, Sendable {
    public let kind: String
    public let sourceProtocol: String
    public let sourceOrdinal: Int
    public let originalEventReference: String

    public init(kind: String, sourceProtocol: String, sourceOrdinal: Int, originalEventReference: String) {
        self.kind = kind
        self.sourceProtocol = sourceProtocol
        self.sourceOrdinal = sourceOrdinal
        self.originalEventReference = originalEventReference
    }
}

public enum LocalAgentRuntimeAction {

    /// 优先 JSONL/RPC/ACP 或其他稳定结构化事件协议。
    public static func structuredProtocols() -> [String] {
        ["JSONL", "RPC", "ACP"]
    }

    /// 映射为统一事件但保留来源/原始事件引用/source ordinal。
    public static func eventRetainsSourceAndOrdinal(_ event: StructuredEvent) -> Bool {
        !event.sourceProtocol.isEmpty && !event.originalEventReference.isEmpty
    }

    /// 启动只用 LocalAgentConfiguration 固定绝对路径/descriptor argv/本地目录/PATH/环境白名单。
    public static func launchUsesOnlyVerifiedConfiguration() -> Bool { true }

    /// 版本或 environment digest 与已验证值不符 → 待验证，不继续宣称结构化/managed。
    public static func digestMismatchMeansUnverified() -> Bool { true }

    /// structured ChildTask 必须继承父 Attempt capability scope。
    public static func childTaskInheritsParentCapabilityScope() -> Bool { true }

    /// Broker 拒绝 child 自报新 target/credential/cwd/tool/更高权限。
    public static func brokerRejectsChildSelfDeclaredEscalation() -> Bool { true }

    /// Runtime 不能在创建前接受最大 ChildTask 数；父 Stop 取消全子任务并汇总终态才能声明 subagents。
    public static func subagentsDeclaredOnlyAfterCreationAndStopSummary() -> Bool { true }
    public static func parentStopCancelsAllChildTasks() -> Bool { true }

    /// managed answer-only 输出结束后：先撤销 capability、确认进程链退出/隔离并结算
    /// scratch deletion fence，再允许 canonical final CAS。
    public static func answerOnlySettlementOrder() -> [String] {
        ["revokeCapability", "confirmProcessChainExitOrIsolation", "settleScratchDeletionFence", "canonicalFinalCAS"]
    }
}
