import Foundation

// MARK: - terminalPassthrough 保留合同（P8-6）

public enum TerminalPassthroughAction {

    /// 完整 PTY 输入输出可用；复杂交互由用户聚焦 Local Agent 终端块完成。
    public static func fullPTYIOAvailable() -> Bool { true }

    /// 只有 PTY 输出不伪造成结构化工具/审批/子 Agent/完成状态。
    public static func ptyOutputNeverFabricatedAsStructured() -> Bool { true }

    /// Stacio 只能审批自己代理的远程操作。
    public static func stacioApprovesOnlyOwnProxiedRemoteOperations() -> Bool { true }

    /// App 崩溃后纯 PTY CLI 是否仍运行无法由 OS identity 证明 → 恢复页显示「进程状态未知」并提供查看/终止说明。
    public static func crashRecoveryShowsProcessStateUnknown() -> Bool { true }
    public static func crashRecoveryOffersViewAndTerminateGuidance() -> Bool { true }

    /// 不得自动续接输入/标记完成/同工作目录静默再启动第二个 CLI。
    public static func noAutoReattachInputOrMarkComplete() -> Bool { true }
    public static func noSilentSecondCLIInSameWorkingDirectory() -> Bool { true }

    /// CLI 升级/结构化协议/containment 校验运行中失败 → 当前 managed Attempt 明确失败并撤销 capability。
    public static func runningFailureFailsManagedAttemptAndRevokesCapability() -> Bool { true }

    /// UI 可提议「以终端透传新建 Attempt」但必须展示能力差异并显式确认；
    /// 绝不在原 Attempt 内自动降级。
    public static func downgradeProposalShowsCapabilityDiffAndRequiresExplicitConfirm() -> Bool { true }
    public static func neverAutoDowngradeWithinOriginalAttempt() -> Bool { true }

    /// PTY profile 保持 Trusted/Experimental 标签、不进入 GA、不能满足 GA PlanAgentCompatibility、
    /// 不能成为新安装默认 Runtime。
    public static func ptyProfileStaysTrustedExperimental() -> Bool { true }
    public static func ptyProfileNotGA() -> Bool { true }
    public static func ptyCannotSatisfyGACompatibility() -> Bool { true }
    public static func ptyNotDefaultRuntimeForNewInstall() -> Bool { true }

    /// `terminalPassthrough` 只允许 `agent` work mode。
    public static func passthroughAllowsWorkMode(_ mode: TurnWorkMode) -> Bool {
        mode == .agent
    }
}
