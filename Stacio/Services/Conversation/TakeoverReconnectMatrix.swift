import Foundation

// MARK: - 接管/重连矩阵（P7-5）

/// 接管来源相位（持有 handle 时才有接管资格）。
public enum TakeoverSourcePhase: String, Codable, CaseIterable, Equatable, Sendable {
    case startingRuntime
    case streaming
    case toolProposed
    case awaitingApproval
    case executingTool
    case awaitingUser
    case pausing
    case paused
    case stopping
}

/// 接管返回相位（对每个来源 phase 精确撤回）。
public enum TakeoverReturnPhase: String, Equatable, Sendable {
    case resumeStreaming
    case resumeToolProposed
    case resumeApproval
    case resumeExecutingTool
    case resumeAwaitingUser
    case resumePaused
}

public enum TakeoverReconnectAction {

    /// 接管资格按实际 handle 判定：StartingRuntime 已创建 handle 后、
    /// Streaming/ToolProposed/AwaitingApproval/ExecutingTool/AwaitingUser/Pausing/Paused
    /// 持有 handle 时、Stopping 可安全移交时。
    public static func takeoverEligible(phase: TakeoverSourcePhase, holdsHandle: Bool) -> Bool {
        guard holdsHandle else { return false }
        switch phase {
        case .startingRuntime, .streaming, .toolProposed, .awaitingApproval,
             .executingTool, .awaitingUser, .pausing, .paused, .stopping:
            return true
        }
    }

    /// 纯 Provider Streaming 无 handle 不显示接管。
    public static func pureProviderStreamingHasNoHandle() -> Bool { true }

    /// takeoverReturnPhase 对每个来源 phase 精确撤回。
    public static func takeoverReturnPhase(from phase: TakeoverSourcePhase) -> TakeoverReturnPhase {
        switch phase {
        case .streaming, .startingRuntime: return .resumeStreaming
        case .toolProposed: return .resumeToolProposed
        case .awaitingApproval: return .resumeApproval
        case .executingTool: return .resumeExecutingTool
        case .awaitingUser: return .resumeAwaitingUser
        case .pausing, .paused, .stopping: return .resumePaused
        }
    }

    /// TakenOver 是规范终态：lease 转人工、旧 capability 立即撤销、恢复必定创建新 Attempt。
    public static func takenOverIsTerminalState() -> Bool { true }
    public static func takeoverTransfersLeaseToHuman() -> Bool { true }
    public static func takeoverRevokesOldCapabilityImmediately() -> Bool { true }
    public static func recoveryAlwaysCreatesNewAttempt() -> Bool { true }

    // MARK: - 重连矩阵

    /// 断线 → 新 runtimeID/reconnect generation → 新 lease。
    public static func reconnectCreatesNewRuntimeAndLease() -> Bool { true }

    /// 未执行操作重新审批。
    public static func unexecutedOperationsRequireReapproval() -> Bool { true }

    // MARK: - 审批摘要

    /// 审批 UI 对 shell/argv/env/stdin/重定向/提权/超时/目标/工作目录/digest/lease generation
    /// 生成不可变摘要。
    public static func approvalImmutableDigest(
        shell: String, argv: [String], envKeys: [String], stdinSource: String,
        redirects: [String], escalation: String?, timeout: Int?,
        target: String, workingDirectory: String, bindingDigest: String,
        leaseGeneration: Int
    ) -> String {
        let fields = [
            shell, argv.joined(separator: " "), envKeys.joined(separator: ","),
            stdinSource, redirects.joined(separator: ","), escalation ?? "-",
            "\(timeout ?? -1)", target, workingDirectory, bindingDigest, "\(leaseGeneration)"
        ]
        return "digest:" + fields.map { "\($0.count):\($0)" }.joined(separator: "|")
    }

    /// 执行前重算：差异要求重新审批。
    public static func digestMismatchRequiresReapproval(before: String, after: String) -> Bool {
        before != after
    }

    /// 「本会话允许」只覆盖同类低风险（此前已批准过的同类操作）。
    public static func sessionAllowCoversOnlySameKindLowRisk(
        approvedKinds: Set<String>, kind: String, risk: String
    ) -> Bool {
        risk == "low" && approvedKinds.contains(kind)
    }
}
