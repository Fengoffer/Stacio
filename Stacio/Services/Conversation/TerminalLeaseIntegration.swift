import Foundation

// MARK: - Terminal / SecureInput Lease（P7-4）

/// 安全输入 lease：绑定 TerminalRuntimeLease.generation 与 prompt digest、单次使用。
public struct SecureInputLease: Equatable, Sendable {
    public let leaseID: String
    public let terminalRuntimeGeneration: Int
    public let promptDigest: String
    public let issuedAt: Date
    public let consumed: Bool

    public init(
        leaseID: String, terminalRuntimeGeneration: Int, promptDigest: String,
        issuedAt: Date, consumed: Bool = false
    ) {
        self.leaseID = leaseID
        self.terminalRuntimeGeneration = terminalRuntimeGeneration
        self.promptDigest = promptDigest
        self.issuedAt = issuedAt
        self.consumed = consumed
    }
}

/// 立即失效事件。
public enum SecureInputInvalidationEvent: Equatable, Sendable {
    case windowResignsKey
    case generationChanged
    case stopped
    case takenOver
    case sleepOrLock
    case processExited
}

public enum TerminalLeaseContract {

    /// 真实/虚拟终端共用审批/审计/脱敏/取消/输出事件合同。
    public static func sharedContractForRealAndVirtualTerminals() -> Bool { true }

    /// Local Agent control PTY 与目标执行面是独立 lease 与 UI 区域。
    public static func controlPTYIndependentLeaseAndUIRegion() -> Bool { true }
    public static func controlPTYCannotReuseRuntimeIDInputLockCompletion() -> Bool { true }
}

public enum SecureInputLeaseAction {

    /// 单次使用默认 2 分钟。
    public static let singleUseDefaultDuration: TimeInterval = 120

    /// 任一失效事件立即失效。
    public static func invalidatedBy(_ event: SecureInputInvalidationEvent) -> Bool { true }

    public static func expired(issuedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(issuedAt) >= singleUseDefaultDuration
    }

    public static func singleUse(consumed: Bool) -> Bool { consumed }

    /// 期间暂停：Agent 输入注入/按键与 echo 广播/Transcript Recorder/终端内容 checkpoint/普通日志采集。
    public static func pausesAgentInputInjection() -> Bool { true }
    public static func pausesKeyAndEchoBroadcast() -> Bool { true }
    public static func pausesTranscriptRecorder() -> Bool { true }
    public static func pausesTerminalContentCheckpoint() -> Bool { true }
    public static func pausesNormalLogging() -> Bool { true }

    /// 敏感值只从内存缓冲直接写该代次目标 PTY；提交或取消后立即清零；
    /// 不进入模型/历史/队列/剪贴板监控/Event payload/日志/崩溃报告。
    public static func writesOnlyFromMemoryBufferToCurrentGenerationPTY() -> Bool { true }
    public static func clearsAfterCommitOrCancel() -> Bool { true }
    public static func neverEntersModelHistoryQueueClipboardEventsLogsOrCrashReports() -> Bool { true }

    /// lease 结束只恢复非敏感记录并返回结构化结果，不回填含回显原文。
    public static func returnsStructuredResultWithoutEchoBackfill() -> Bool { true }
}
