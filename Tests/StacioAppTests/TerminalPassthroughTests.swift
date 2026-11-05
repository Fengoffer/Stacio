import XCTest
import Foundation
@testable import StacioApp

/// P8-6：terminalPassthrough 保留合同（PTY 语义、审批边界、崩溃状态未知、不自动降级、profile 分级、agent-only）。
final class TerminalPassthroughTests: XCTestCase {

    // MARK: - PTY 语义

    func testFullPTYIOAndNotFabricatedAsStructured() {
        XCTAssertTrue(TerminalPassthroughAction.fullPTYIOAvailable(),
                      "完整 PTY 输入输出可用、复杂交互由用户聚焦 Local Agent 终端块完成")
        XCTAssertTrue(TerminalPassthroughAction.ptyOutputNeverFabricatedAsStructured(),
                      "只有 PTY 输出不伪造成结构化工具/审批/子 Agent/完成状态")
    }

    func testStacioApprovesOnlyOwnProxiedRemoteOps() {
        XCTAssertTrue(TerminalPassthroughAction.stacioApprovesOnlyOwnProxiedRemoteOperations(),
                      "Stacio 只能审批自己代理的远程操作")
    }

    // MARK: - 崩溃状态未知

    func testCrashRecoveryShowsProcessStateUnknown() {
        XCTAssertTrue(TerminalPassthroughAction.crashRecoveryShowsProcessStateUnknown(),
                      "App 崩溃后纯 PTY CLI 是否仍运行无法由 OS identity 证明 → 恢复页显示「进程状态未知」")
        XCTAssertTrue(TerminalPassthroughAction.crashRecoveryOffersViewAndTerminateGuidance(),
                      "提供查看/终止说明")
    }

    // MARK: - 不自动续接/静默重启

    func testNoAutoReattachOrSilentSecondCLI() {
        XCTAssertTrue(TerminalPassthroughAction.noAutoReattachInputOrMarkComplete(),
                      "不得自动续接输入/标记完成")
        XCTAssertTrue(TerminalPassthroughAction.noSilentSecondCLIInSameWorkingDirectory(),
                      "同工作目录静默再启动第二个 CLI 禁止")
    }

    // MARK: - 运行中失败与不自动降级

    func testRunningFailureFailsAttemptAndRevokesCapability() {
        XCTAssertTrue(TerminalPassthroughAction.runningFailureFailsManagedAttemptAndRevokesCapability(),
                      "CLI 升级/结构化协议/containment 校验运行中失败 → 当前 managed Attempt 明确失败并撤销 capability")
        XCTAssertTrue(TerminalPassthroughAction.downgradeProposalShowsCapabilityDiffAndRequiresExplicitConfirm(),
                      "UI 可提议「以终端透传新建 Attempt」但必须展示能力差异并显式确认")
        XCTAssertTrue(TerminalPassthroughAction.neverAutoDowngradeWithinOriginalAttempt(),
                      "绝不在原 Attempt 内自动降级")
    }

    // MARK: - profile 分级

    func testPTYProfileStaysTrustedExperimentalNotGA() {
        XCTAssertTrue(TerminalPassthroughAction.ptyProfileStaysTrustedExperimental(),
                      "PTY profile 保持 Trusted/Experimental 标签")
        XCTAssertTrue(TerminalPassthroughAction.ptyProfileNotGA(), "不进入 GA")
        XCTAssertTrue(TerminalPassthroughAction.ptyCannotSatisfyGACompatibility(),
                      "不能满足 GA PlanAgentCompatibility")
        XCTAssertTrue(TerminalPassthroughAction.ptyNotDefaultRuntimeForNewInstall(),
                      "不能成为新安装默认 Runtime")
    }

    // MARK: - agent-only work mode

    func testPassthroughOnlyAllowsAgentWorkMode() {
        XCTAssertTrue(TerminalPassthroughAction.passthroughAllowsWorkMode(.agent))
        XCTAssertFalse(TerminalPassthroughAction.passthroughAllowsWorkMode(.planFirst),
                       "terminalPassthrough 只允许 agent work mode")
        XCTAssertFalse(TerminalPassthroughAction.passthroughAllowsWorkMode(.answerOnly))
    }
}
