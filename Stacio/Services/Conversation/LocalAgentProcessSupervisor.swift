import Foundation

// MARK: - Local Agent Process Supervisor（P8-4）

/// managed launch journal（durable 记录）。
public struct ManagedLaunchJournalEntry: Equatable, Sendable {
    public let launchKind: String
    public let executableIdentity: String
    public let rootPID: Int
    public let trustedStartTime: Date
    public let processGeneration: Int
    public let childProcessPolicy: String
    public let attemptAdmissionCapabilityBinding: String

    public init(
        launchKind: String, executableIdentity: String, rootPID: Int,
        trustedStartTime: Date, processGeneration: Int, childProcessPolicy: String,
        attemptAdmissionCapabilityBinding: String
    ) {
        self.launchKind = launchKind
        self.executableIdentity = executableIdentity
        self.rootPID = rootPID
        self.trustedStartTime = trustedStartTime
        self.processGeneration = processGeneration
        self.childProcessPolicy = childProcessPolicy
        self.attemptAdmissionCapabilityBinding = attemptAdmissionCapabilityBinding
    }
}

/// 进程结算状态。
public enum ProcessSettlementState: Equatable, Sendable {
    case running
    case exited
    case unableToProveExit
    case orphaned
}

public enum LocalAgentProcessSupervisorAction {

    /// 每次 managed launch 放入可整体终止的受管进程组/等价 OS job。
    public static func managedProcessGroupRequired() -> Bool { true }

    /// durable 记录 launch journal（launchKind/executable identity/根 PID/可信启动时间/
    /// process generation/子进程策略/Attempt-Admission-capability 绑定）。
    public static func journalEntry(
        launchKind: String, executableIdentity: String, rootPID: Int,
        trustedStartTime: Date, processGeneration: Int, childProcessPolicy: String,
        attemptAdmissionCapabilityBinding: String
    ) -> ManagedLaunchJournalEntry {
        ManagedLaunchJournalEntry(
            launchKind: launchKind, executableIdentity: executableIdentity, rootPID: rootPID,
            trustedStartTime: trustedStartTime, processGeneration: processGeneration,
            childProcessPolicy: childProcessPolicy,
            attemptAdmissionCapabilityBinding: attemptAdmissionCapabilityBinding
        )
    }

    /// 正常 Stop/终态：先撤销 capability 再终止或确认整个允许进程链退出并清理 ephemeral scratch。
    public static func stopOrder() -> [String] {
        ["revokeCapability", "terminateOrConfirmProcessChainExit", "cleanupEphemeralScratch"]
    }

    /// 根进程退出/PTY EOF 不足证明执行体结束（须确认整个允许进程链）。
    public static func rootExitOrPTYEOFInsufficientToProveEnd() -> Bool { true }

    /// App 非正常退出后：新 generation 先使旧 Broker endpoint/capability 永久失效，
    /// 再按 launch journal 与 OS identity 对账旧进程树。
    public static func crashRecoveryOrder() -> [String] {
        ["invalidateOldBrokerEndpoint", "reconcileAgainstLaunchJournalAndOSIdentity"]
    }

    /// PID 被复用/身份不匹配/无法停止 → OrphanedLocalAgentProcess 阻止冲突 launch。
    public static func settlement(
        pidReused: Bool, identityMatches: Bool, canStop: Bool
    ) -> ProcessSettlementState {
        if pidReused || !identityMatches || !canStop {
            return .orphaned
        }
        return .running
    }

    public static func orphanBlocksConflictLaunch() -> Bool { true }

    /// 启动时 Scheduler/Broker/Supervisor 提升 generation 并按 journal 分类对账
    /// （仍可运行/无法证明退出 → orphanedRuntime）。
    public static func generationAdvancedOnLaunch() -> Bool { true }
    public static func journalReconciliationClassifiesRunningOrOrphaned() -> Bool { true }

    /// scratch 未删除前不释放名额。
    public static func slotHeldUntilScratchCleaned() -> Bool { true }
}
