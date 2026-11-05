import XCTest
import Foundation
@testable import StacioApp

/// P3-8b：CredentialAttemptBinding 跨 Store saga 与零 binding proof。
final class CredentialAttemptBindingTests: XCTestCase {

    func testBindingClosedStateMachine() {
        // reserved → commitPending → committed → releasing → released
        XCTAssertEqual(
            CredentialAttemptBindingStateMachine.destination(from: .reserved, event: .markCommitPending),
            .commitPending
        )
        XCTAssertEqual(
            CredentialAttemptBindingStateMachine.destination(from: .commitPending, event: .commitConfirmed),
            .committed
        )
        XCTAssertEqual(
            CredentialAttemptBindingStateMachine.destination(from: .committed, event: .beginRelease),
            .releasing
        )
        XCTAssertEqual(
            CredentialAttemptBindingStateMachine.destination(from: .releasing, event: .beginRelease),
            .released
        )
        // 非法边
        XCTAssertNil(CredentialAttemptBindingStateMachine.destination(from: .reserved, event: .commitConfirmed))
        XCTAssertNil(CredentialAttemptBindingStateMachine.destination(from: .committed, event: .markCommitPending))
        // quarantine 出口
        XCTAssertEqual(
            CredentialAttemptBindingStateMachine.destination(from: .commitPending, event: .quarantine),
            .quarantined
        )
    }

    func testReconciliationFourWindows() {
        // 已提交但 ack 丢失 → 补 committed
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.reconcile(
                hadConversationCommit: true, ackReceived: false, pastCommitRecoveryPoint: false
            ),
            .commitConfirmed
        )
        // 明确不存在且越过可提交恢复点 → released
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.reconcile(
                hadConversationCommit: false, ackReceived: false, pastCommitRecoveryPoint: true
            ),
            .releaseConfirmed
        )
        // 无法确认 → quarantine（阻止删除）
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.reconcile(
                hadConversationCommit: false, ackReceived: false, pastCommitRecoveryPoint: false
            ),
            .quarantine
        )
        // 已提交且 ack 收到 → 正常（非 commitConfirmed 分支）
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.reconcile(
                hadConversationCommit: true, ackReceived: true, pastCommitRecoveryPoint: false
            ),
            .quarantine,
            "ack 已收到且无恢复点证据 → 保持现状判定（不伪造 commitConfirmed）"
        )
    }

    func testDerivedActiveCountOnlyFromUnreleasedBindings() {
        let states: [CredentialAttemptBindingState] = [
            .reserved, .commitPending, .committed, .releasing, .released, .quarantined
        ]
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.derivedActiveBindingCount(states),
            4,
            "released/quarantined 不计入 active binding count"
        )
    }

    func testParticipantProofFourModes() {
        // stacioCredentialBindings|combined → 必须有 binding
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .stacioCredentialBindings, bindingCount: 0),
            .missingRequiredBinding
        )
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .stacioCredentialBindings, bindingCount: 1),
            .valid
        )
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .combined, bindingCount: 0),
            .missingRequiredBinding
        )
        // cliManagedAuthentication|noneVerified → 必须零 binding
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .cliManagedAuthentication, bindingCount: 0),
            .valid
        )
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .cliManagedAuthentication, bindingCount: 1),
            .unexpectedBinding,
            "cliManaged 出现异常 binding 必须隔离"
        )
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .noneVerified, bindingCount: 1),
            .unexpectedBinding
        )
        XCTAssertEqual(
            CredentialAttemptBindingCoordinator.participantProof(mode: .noneVerified, bindingCount: 0),
            .valid
        )
    }

    func testTerminalReleaseRequiresConversationTerminalProof() {
        // 终态 release 必须验 Conversation 终态 commit proof：没有已提交序列的 binding 不能 release
        let withoutProof = CredentialAttemptBindingStateMachine.destination(from: .committed, event: .beginRelease)
        XCTAssertEqual(withoutProof, .releasing)
        // 语义断言：proof 校验在 coordinator/持久层（Rust binding_terminal_release 测试覆盖），
        // Swift 状态机不提供绕过 proof 的 release 快捷路径
        XCTAssertNil(CredentialAttemptBindingStateMachine.destination(from: .reserved, event: .beginRelease))
    }
}
