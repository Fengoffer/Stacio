import Foundation

// MARK: - Local Agent Settings Process journal（P3-10）

/// Settings process journal 事件。
/// `completed` 只在整棵进程树退出且具名业务结果由 Evidence Store 提交后成立；
/// PTY EOF/窗口关闭/根进程退出不足结算；`stateUnknown` 仅 reconcile 证据后可转
/// `completed|isolated`。
public enum LocalAgentSettingsProcessEvent: Equatable, Sendable {
    case beginStart
    case processStarted
    case startFailed
    case cancel
    /// PTY EOF/窗口关闭/根进程退出 → stopping（不足结算）。
    case ptyExited
    /// 整棵进程树退出；`businessResultCommitted` 表示具名业务结果已由 Evidence Store 提交。
    case treeExited(businessResultCommitted: Bool)
    /// 整棵进程树已确认退出，且业务结果明确为用户取消。
    case treeExitedCancelled
    /// 整棵进程树已确认退出，且业务结果明确失败。
    case treeExitedFailed
    /// 进程或进程树结算证据不足；必须显式 reconcile。
    case settlementUnknown
    /// 仅 reconcile 证据后可发生：stateUnknown → completed。
    case reconcileSucceeded
    /// 仅 reconcile 证据后可发生：stateUnknown → isolated。
    case reconcileIsolated
}

/// 新 detect/login/Runtime launch 动作（reconciliation gate 按动作判定）。
public enum LocalAgentSettingsProcessAction: Equatable, Sendable {
    case detect
    case login
    case runtimeLaunch
}

/// Local Agent Settings process journal 状态机（纯函数；全局上限 1；logout safety priority）。
/// 权威状态由 LocalAgentSettingsProcessCoordinator 持有，崩溃后按磁盘证据对账重建。
public enum LocalAgentSettingsProcessJournal {

    /// 关闭转换表：
    /// - `prepared→starting|cancelled|failed`、`starting→running|failed`；
    /// - `running→stopping`（PTY EOF 不足结算）、`stopping→completed|stateUnknown`
    ///   （整棵树退出；completed 需要业务结果已提交）；
    /// - `stateUnknown→completed|isolated`（仅 reconcile 证据）；
    /// - 终态（completed/failed/cancelled/isolated）无出口。
    public static func destination(
        from state: LocalAgentSettingsProcessState,
        event: LocalAgentSettingsProcessEvent
    ) -> LocalAgentSettingsProcessState? {
        switch (state, event) {
        case (.prepared, .beginStart): return .starting
        case (.prepared, .cancel): return .cancelled
        case (.starting, .cancel): return .cancelled
        case (.prepared, .startFailed): return .failed
        case (.starting, .processStarted): return .running
        case (.starting, .startFailed): return .failed
        case (.running, .ptyExited): return .stopping
        case (.running, .treeExited(let committed)): return committed ? .completed : .stateUnknown
        case (.stopping, .treeExited(let committed)): return committed ? .completed : .stateUnknown
        case (.running, .treeExitedCancelled), (.stopping, .treeExitedCancelled): return .cancelled
        case (.running, .treeExitedFailed), (.stopping, .treeExitedFailed): return .failed
        case (.starting, .settlementUnknown), (.running, .settlementUnknown), (.stopping, .settlementUnknown):
            return .stateUnknown
        case (.stateUnknown, .reconcileSucceeded): return .completed
        case (.stateUnknown, .reconcileIsolated): return .isolated
        default:
            return nil
        }
    }

    /// `stateUnknown` 或 `processSettlement == unknown` → 需要对账，并阻止新 detect/login/Runtime launch。
    public static func reconciliationRequired(
        state: LocalAgentSettingsProcessState,
        settlement: LocalAgentSettingsProcessSettlement
    ) -> Bool {
        state == .stateUnknown || settlement == .unknown
    }

    /// 按动作判定的 reconciliation gate：
    /// - detect：恢复路径（重新检测 auth 状态以收集 reconcile 证据）——authenticationUnknown
    ///   后允许重新检测，不阻止；
    /// - login/runtimeLaunch：stateUnknown 或 settlement==unknown 时阻止（需先 reconcile）。
    public static func actionBlocked(
        _ action: LocalAgentSettingsProcessAction,
        state: LocalAgentSettingsProcessState,
        settlement: LocalAgentSettingsProcessSettlement
    ) -> Bool {
        switch action {
        case .detect:
            return false
        case .login, .runtimeLaunch:
            return reconciliationRequired(state: state, settlement: settlement)
        }
    }

    /// settings process 全局上限 1：任何非终态进程存在时不允许新进程。
    public static func globalLimitExceeded(activeProcesses: [LocalAgentSettingsProcessState]) -> Bool {
        activeProcesses.contains { !$0.isTerminal }
    }

    /// logout safety priority：登出时阻止新 launch（在途进程优先安全停止）。
    public static func launchBlockedDuringLogout(isLoggingOut: Bool) -> Bool {
        isLoggingOut
    }

    /// 崩溃恢复对账入口：按 action event/Permit/safety fence/launch outbox/executable/
    /// process generation 证据重建 journal 状态。
    ///
    /// 规则：PID 缺失/根进程退出/Permit settled 都不自动写业务结算——`completed` 只在
    /// 具名业务结果由 Evidence Store 提交后成立；无法确认的进入 `stateUnknown` 等待
    /// reconcile 证据（可转为 completed/isolated）。
    public static func reconcileAfterCrash(
        persistedState: LocalAgentSettingsProcessState,
        pidKnown: Bool,
        rootProcessExited: Bool,
        businessResultCommitted: Bool
    ) -> LocalAgentSettingsProcessState {
        if persistedState.isTerminal {
            // 已终结状态不因崩溃回退（不重发、不恢复旧 PTY 输入）
            return persistedState
        }
        if businessResultCommitted && rootProcessExited {
            // 整棵树退出 + 具名业务结果已提交 → completed
            return .completed
        }
        if rootProcessExited || !pidKnown {
            // 根进程退出但无业务结果证据 / PID 缺失无法确认 → 需 reconcile
            return .stateUnknown
        }
        // 进程可能仍在运行：保留 persistedState（starting/running/stopping）
        return persistedState
    }
}
