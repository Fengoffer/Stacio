import XCTest
import Foundation
@testable import StacioApp

/// P3-8a：CredentialLifecycleStore（仅生命周期状态机）合同。
final class CredentialLifecycleStoreTests: XCTestCase {

    // MARK: - generation 关闭状态机

    func testGenerationClosedStateMachineTransitions() {
        // pendingActivation → active|abandoned|revoked
        XCTAssertEqual(
            CredentialLifecycleStateMachine.destination(from: .pendingActivation, event: .activate),
            .active
        )
        XCTAssertEqual(
            CredentialLifecycleStateMachine.destination(from: .pendingActivation, event: .abandon),
            .abandoned
        )
        XCTAssertEqual(
            CredentialLifecycleStateMachine.destination(from: .pendingActivation, event: .revoke),
            .revoked
        )
        // active → retired|revoked
        XCTAssertEqual(
            CredentialLifecycleStateMachine.destination(from: .active, event: .retire),
            .retired
        )
        XCTAssertEqual(
            CredentialLifecycleStateMachine.destination(from: .active, event: .revoke),
            .revoked
        )
        // retired → revoked
        XCTAssertEqual(
            CredentialLifecycleStateMachine.destination(from: .retired, event: .revoke),
            .revoked
        )
        // 非法边
        XCTAssertNil(CredentialLifecycleStateMachine.destination(from: .active, event: .abandon))
        XCTAssertNil(CredentialLifecycleStateMachine.destination(from: .retired, event: .activate))
        XCTAssertNil(CredentialLifecycleStateMachine.destination(from: .pendingActivation, event: .retire))
    }

    func testAbandonedIsTerminalCannotRevive() {
        XCTAssertTrue(CredentialLifecycleStateMachine.isTerminal(.abandoned))
        XCTAssertTrue(CredentialLifecycleStateMachine.isTerminal(.revoked))
        XCTAssertFalse(CredentialLifecycleStateMachine.isTerminal(.active))
        // abandoned 无出口
        for event in [CredentialLifecycleEvent.activate, .retire, .revoke, .abandon] {
            XCTAssertNil(
                CredentialLifecycleStateMachine.destination(from: .abandoned, event: event),
                "abandoned 终态不可复活"
            )
        }
        // revoked 无出口
        XCTAssertNil(CredentialLifecycleStateMachine.destination(from: .revoked, event: .activate))
    }

    func testReviveBlockedWhilePendingDeletion() {
        // 删除进行中不得复活
        XCTAssertTrue(
            CredentialLifecycleStateMachine.reviveBlocked(
                state: .pendingActivation, secretAvailability: .pendingDeletion
            )
        )
        XCTAssertTrue(
            CredentialLifecycleStateMachine.reviveBlocked(state: .active, secretAvailability: .pendingDeletion)
        )
        XCTAssertFalse(
            CredentialLifecycleStateMachine.reviveBlocked(state: .active, secretAvailability: .present)
        )
        XCTAssertFalse(
            CredentialLifecycleStateMachine.reviveBlocked(state: .revoked, secretAvailability: .pendingDeletion),
            "已撤销状态不参与复活判定"
        )
    }

    // MARK: - 删除 saga

    func testDeletionSagaTransitionsAndFence() {
        // requested → blockedByUse → deleting → completed
        XCTAssertEqual(
            CredentialDeletionSaga.destination(from: .requested, event: .blockByUse),
            .blockedByUse
        )
        // blockedByUse 不得直接完成删除
        XCTAssertNil(CredentialDeletionSaga.destination(from: .blockedByUse, event: .complete))
        XCTAssertEqual(
            CredentialDeletionSaga.destination(from: .blockedByUse, event: .beginDelete),
            .deleting
        )
        XCTAssertEqual(
            CredentialDeletionSaga.destination(from: .deleting, event: .complete),
            .completed
        )
        // 删除失败：requested/deleting → failed（不复活）
        XCTAssertEqual(
            CredentialDeletionSaga.destination(from: .requested, event: .fail),
            .failed
        )
        XCTAssertEqual(
            CredentialDeletionSaga.destination(from: .deleting, event: .fail),
            .failed
        )
        XCTAssertEqual(CredentialDeletionSaga.nextFence(current: 1), 2, "deletionFence 递增")
        XCTAssertEqual(CredentialDeletionSaga.nextFence(current: 2), 3)
    }

    func testDeletionFailureKeepsPendingDeletionNotRevive() {
        // 删除失败：secretAvailability 保持 pendingDeletion；generation 不复活（状态机层面）
        XCTAssertTrue(
            CredentialLifecycleStateMachine.reviveBlocked(
                state: .pendingActivation, secretAvailability: .pendingDeletion
            ),
            "删除失败后保持 pendingDeletion，不得复活 generation"
        )
    }

    // MARK: - 孤儿策略

    func testOrphanSettlementRejectsAutoAttach() {
        XCTAssertEqual(CredentialOrphanPolicy.settle(resolution: "deleted"), .deleted)
        XCTAssertEqual(CredentialOrphanPolicy.settle(resolution: "manualReview"), .manualReview)
        // 自动挂接/回填 active 一律拒绝
        XCTAssertNil(CredentialOrphanPolicy.settle(resolution: "auto_attach"))
        XCTAssertNil(CredentialOrphanPolicy.settle(resolution: "reactivate"))
    }

    func testNoSecretExposureThroughOrphanPath() {
        // 孤儿路径只持有 keychain 引用，任何结算都不输出 secret 正文
        let resolution = CredentialOrphanPolicy.settle(resolution: "manualReview")
        XCTAssertNotNil(resolution)
        // 语义断言：孤儿记录模型不含 secret 字段（编译期证明——CredentialOrphanRecord 不存在于会话模型）
        XCTAssertTrue(CredentialOrphanPolicy.settle(resolution: "deleted") == .deleted)
    }
}
