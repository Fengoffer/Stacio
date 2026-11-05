import XCTest
import Foundation
@testable import StacioApp

/// P7-5：接管/重连矩阵与审批集成。
final class TakeoverReconnectMatrixTests: XCTestCase {

    // MARK: - 接管资格按实际 handle

    func testTakeoverEligibilityRequiresHandle() {
        // 持有 handle 的相位可接管
        for phase in TakeoverSourcePhase.allCases {
            XCTAssertTrue(TakeoverReconnectAction.takeoverEligible(phase: phase, holdsHandle: true),
                          "\(phase.rawValue) 持有 handle 时可接管")
            XCTAssertFalse(TakeoverReconnectAction.takeoverEligible(phase: phase, holdsHandle: false),
                           "\(phase.rawValue) 无 handle 不可接管")
        }
        XCTAssertTrue(TakeoverReconnectAction.pureProviderStreamingHasNoHandle(),
                      "纯 Provider Streaming 无 handle 不显示")
    }

    // MARK: - takeoverReturnPhase 精确撤回

    func testTakeoverReturnPhasePerSource() {
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .streaming), .resumeStreaming)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .startingRuntime), .resumeStreaming)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .toolProposed), .resumeToolProposed)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .awaitingApproval), .resumeApproval)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .executingTool), .resumeExecutingTool)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .awaitingUser), .resumeAwaitingUser)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .paused), .resumePaused)
        XCTAssertEqual(TakeoverReconnectAction.takeoverReturnPhase(from: .stopping), .resumePaused)
    }

    // MARK: - TakenOver 规范终态

    func testTakenOverTerminalState() {
        XCTAssertTrue(TakeoverReconnectAction.takenOverIsTerminalState(), "TakenOver 是规范终态")
        XCTAssertTrue(TakeoverReconnectAction.takeoverTransfersLeaseToHuman(), "lease 转人工")
        XCTAssertTrue(TakeoverReconnectAction.takeoverRevokesOldCapabilityImmediately(), "旧 capability 立即撤销")
        XCTAssertTrue(TakeoverReconnectAction.recoveryAlwaysCreatesNewAttempt(),
                      "恢复必定创建新 Attempt 重新准入/重绑/重新审批")
    }

    // MARK: - 重连矩阵

    func testReconnectMatrix() {
        XCTAssertTrue(TakeoverReconnectAction.reconnectCreatesNewRuntimeAndLease(),
                      "断线→新 runtimeID/reconnect generation→新 lease")
        XCTAssertTrue(TakeoverReconnectAction.unexecutedOperationsRequireReapproval(),
                      "未执行操作重新审批")
    }

    // MARK: - 审批摘要与重算

    func testApprovalImmutableDigestAndReapprovalOnMismatch() {
        let before = TakeoverReconnectAction.approvalImmutableDigest(
            shell: "/bin/zsh", argv: ["-c", "deploy"], envKeys: ["STACIO"],
            stdinSource: "heredoc", redirects: ["stdout→log"], escalation: "sudo",
            timeout: 60, target: "host", workingDirectory: "/app",
            bindingDigest: "d1", leaseGeneration: 2
        )
        // 同输入 → 同摘要
        let again = TakeoverReconnectAction.approvalImmutableDigest(
            shell: "/bin/zsh", argv: ["-c", "deploy"], envKeys: ["STACIO"],
            stdinSource: "heredoc", redirects: ["stdout→log"], escalation: "sudo",
            timeout: 60, target: "host", workingDirectory: "/app",
            bindingDigest: "d1", leaseGeneration: 2
        )
        XCTAssertEqual(before, again)
        // argv 变化 → 摘要变化 → 执行前重算差异要求重新审批
        let changed = TakeoverReconnectAction.approvalImmutableDigest(
            shell: "/bin/zsh", argv: ["-c", "deploy --force"], envKeys: ["STACIO"],
            stdinSource: "heredoc", redirects: ["stdout→log"], escalation: "sudo",
            timeout: 60, target: "host", workingDirectory: "/app",
            bindingDigest: "d1", leaseGeneration: 2
        )
        XCTAssertTrue(TakeoverReconnectAction.digestMismatchRequiresReapproval(before: before, after: changed),
                      "差异要求重新审批")
        XCTAssertFalse(TakeoverReconnectAction.digestMismatchRequiresReapproval(before: before, after: again))
    }

    // MARK: - 「本会话允许」范围

    func testSessionAllowOnlySameKindLowRisk() {
        // 已批准同类低风险 → 覆盖
        XCTAssertTrue(TakeoverReconnectAction.sessionAllowCoversOnlySameKindLowRisk(
            approvedKinds: ["read"], kind: "read", risk: "low"
        ))
        // 不同 kind（未批准）→ 不覆盖
        XCTAssertFalse(TakeoverReconnectAction.sessionAllowCoversOnlySameKindLowRisk(
            approvedKinds: ["read"], kind: "write", risk: "low"
        ), "同类低风险才覆盖——不同 kind 不覆盖")
        // 高风险 → 不覆盖
        XCTAssertFalse(TakeoverReconnectAction.sessionAllowCoversOnlySameKindLowRisk(
            approvedKinds: ["read"], kind: "read", risk: "high"
        ))
        // 未批准任何 kind → 不覆盖
        XCTAssertFalse(TakeoverReconnectAction.sessionAllowCoversOnlySameKindLowRisk(
            approvedKinds: [], kind: "read", risk: "low"
        ))
    }
}
