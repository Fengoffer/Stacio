import XCTest
import Foundation
@testable import StacioApp

/// P3-9：agentConversationV2 三态控制面 + V2ControlAdmissionPermit + target journal
/// （真实 Rust 控制面库后端，经 CoreBridge UniFFI）。
final class V2ControlCoordinatorTests: XCTestCase {

    // MARK: - helpers

    private func makeControl() -> AgentConversationV2ControlCoordinator {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-control-\(UUID().uuidString).sqlite3").path
        return try! AgentConversationV2ControlCoordinator(databasePath: path)
    }

    private func makePermit(control: AgentConversationV2ControlCoordinator) -> V2ControlTargetOperationCoordinator {
        V2ControlTargetOperationCoordinator(control: control)
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () throws -> T,
        _ error: V2ControlError,
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail(message, file: file, line: line)
        } catch let actual as V2ControlError {
            XCTAssertEqual(actual, error, message, file: file, line: line)
        } catch {
            XCTFail("\(message) — unexpected error: \(error)", file: file, line: line)
        }
    }

    // MARK: - 三态控制面

    func testControlStateTransitionsWithGenerationCAS() throws {
        let control = makeControl()
        XCTAssertEqual(try control.controlState(), .enabled)

        try control.transition(to: .draining, expectedGeneration: 1, transitionID: "transition-1")
        try control.transition(to: .disabled, expectedGeneration: 2, transitionID: "transition-2")
        try control.transition(to: .enabled, expectedGeneration: 2, transitionID: "transition-3")
        XCTAssertEqual(try control.controlState(), .enabled)

        // 旧 generation 的 transition 拒绝（CAS）
        assertThrows(
            try control.transition(to: .draining, expectedGeneration: 0, transitionID: "transition-stale"),
            .staleGeneration(expected: 0, current: 3),
            "旧 generation 的 transition 必须拒绝"
        )
    }

    func testControlTransitionIDIdempotentReplay() throws {
        let control = makeControl()
        try control.transition(to: .draining, expectedGeneration: 1, transitionID: "transition-1")
        // 同 transition ID 重复投递幂等：不改变状态、不报错
        try control.transition(to: .draining, expectedGeneration: 1, transitionID: "transition-1")
        XCTAssertEqual(try control.controlState(), .draining)
    }

    func testControlStateIsAuthoritativeFlagNotUIBool() throws {
        // 旗标权威状态是 AgentConversationV2ControlState（Rust 库持久化），不是 UI 布尔值：
        // 崩溃/重启后从库重建，UI 开关只是投影。
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-control-persist-\(UUID().uuidString).sqlite3").path
        let first = try AgentConversationV2ControlCoordinator(databasePath: path)
        try first.transition(to: .disabled, expectedGeneration: 1, transitionID: "t-1")
        XCTAssertEqual(try first.controlState(), .disabled)

        // 重新打开同一库：权威状态保留
        let reopened = try AgentConversationV2ControlCoordinator(databasePath: path)
        XCTAssertEqual(try reopened.controlState(), .disabled, "控制面状态持久化于 Rust 库，重启后重建")
    }

    func testDrainingFenceBlocksNewAuthorization() throws {
        let control = makeControl()
        try control.transition(to: .draining, expectedGeneration: 1, transitionID: "t-1")
        XCTAssertFalse(try control.authorizationAllowed(), "draining 后必须关闭新 authorization")
        XCTAssertEqual(try control.admissionGateAllowsNewExecution(), .closed, "draining 后必须关闭新 admission")

        try control.transition(to: .disabled, expectedGeneration: 2, transitionID: "t-2")
        XCTAssertFalse(try control.authorizationAllowed(), "disabled 后无新 authorization（draining fence 已关）")
        XCTAssertEqual(try control.admissionGateAllowsNewExecution(), .closed, "disabled 后 gate 关闭")
    }

    func testSchedulerAdmissionGateTiedToControlState() throws {
        // Scheduler admission gate 与 Control 同域：gate 权威状态来自 Rust 控制面库，
        // 调用方在 promote 前必须检查 gate；gate 关闭时 request 留在队列（幂等保留）。
        let control = makeControl()
        XCTAssertEqual(try control.admissionGateAllowsNewExecution(), .open, "enabled 时 gate 打开")

        try control.transition(to: .disabled, expectedGeneration: 1, transitionID: "t-1")
        XCTAssertEqual(try control.admissionGateAllowsNewExecution(), .closed, "disabled 后 gate 关闭")

        var state = SchedulerState()
        state = AgentExecutionScheduler.enqueue(
            state: state,
            request: GlobalExecutionAdmissionRequest(
                requestID: "r-1", sessionID: "s-1", turnID: "t-1", attemptID: "a-1",
                schedulerGeneration: 1, queueOrdinal: 0, enqueuedAt: Date(), state: .queued
            ),
            now: Date()
        )
        // 守则：promote 前过 gate；gate 关闭时不得授权，request 幂等保留在队列
        guard try control.admissionGateAllowsNewExecution() == .open else {
            XCTAssertEqual(state.requests.count, 1, "gate 关闭时 request 留在队列（幂等保留）")
            XCTAssertEqual(state.activeLeases.count, 0, "gate 关闭时不产生 lease")
            return
        }
        XCTFail("disabled 状态下 gate 不应通过")
    }

    // MARK: - Permit 状态机（纯 Swift 关闭表）

    func testPermitStateMachineClosedTransitionTable() {
        // 授权路径 issued→prepared→commitAuthorized→settling→settledCommitted
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .issued, event: .prepare),
            .prepared
        )
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .prepared, event: .authorizeCommit),
            .commitAuthorized
        )
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .commitAuthorized, event: .beginSettlement),
            .settling
        )
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .settling, event: .settleCommitted),
            .settledCommitted
        )
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .settling, event: .settleAborted),
            .settledAborted
        )
        // 终态无出口
        XCTAssertNil(V2ControlPermitStateMachine.destination(from: .settledCommitted, event: .prepare))
        XCTAssertNil(V2ControlPermitStateMachine.destination(from: .settledCommitted, event: .settleCommitted))
        XCTAssertNil(V2ControlPermitStateMachine.destination(from: .settledAborted, event: .settleAborted))
        // settledCommitted 必须经过 settling（不靠超时猜失败）
        XCTAssertNil(
            V2ControlPermitStateMachine.destination(from: .commitAuthorized, event: .settleCommitted),
            "commitAuthorized 不能跳过 settlement-start 直接 settledCommitted"
        )
        // abort path 可直接结算
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .issued, event: .settleAborted),
            .settledAborted
        )
        XCTAssertEqual(
            V2ControlPermitStateMachine.destination(from: .prepared, event: .settleAborted),
            .settledAborted
        )
    }

    // MARK: - Permit（真实 Rust 后端）

    func testPermitStateMachineClosedOnRealBackend() throws {
        let control = makeControl()
        let permit = makePermit(control: control)

        try permit.createPermit(permitID: "permit-1", generation: 1, participants: ["participant-a", "participant-b"])
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .issued)
        try permit.preparePermit(permitID: "permit-1")
        try permit.authorizePermitCommit(permitID: "permit-1")
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .commitAuthorized)
        // settlement-start 先持久化，再终态结算
        try permit.settlePermit(permitID: "permit-1", settlement: "settling", proofDigest: "settlement-start-proof")
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .settling)
        try permit.settlePermit(permitID: "permit-1", settlement: "settledCommitted", proofDigest: "proof-1")
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .settledCommitted)

        // 终态无出口
        assertThrows(
            try permit.preparePermit(permitID: "permit-1"),
            .invalidTransition(from: "settledCommitted", to: "prepared"),
            "终态不允许再迁移"
        )
    }

    func testPermitAbortPath() throws {
        let control = makeControl()
        let permit = makePermit(control: control)
        try permit.createPermit(permitID: "permit-1", generation: 1, participants: ["participant-a"])
        try permit.preparePermit(permitID: "permit-1")
        try permit.settlePermit(permitID: "permit-1", settlement: "settledAborted", proofDigest: "abort-proof")
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .settledAborted)
    }

    func testPermitExpiryRules() throws {
        let control = makeControl()
        let permit = makePermit(control: control)

        // 未 prepared 的 issued Permit：带 target proof 的 expiry 不允许（只能 no-target proof）
        try permit.createPermit(permitID: "permit-1", generation: 1, participants: ["participant-a"])
        assertThrows(
            try permit.expirePermit(permitID: "permit-1", withTargetProof: true),
            .invalidSettlement(permitID: "permit-1", detail: "unprepared permit cannot settle with target proof"),
            "未 prepared 只能 no-target proof 结算"
        )
        try permit.expirePermit(permitID: "permit-1", withTargetProof: false)
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .settledAborted)

        // prepared 未授权：必须 abort decision（不允许 no-target expiry）
        try permit.createPermit(permitID: "permit-2", generation: 1, participants: ["participant-a", "participant-b"])
        try permit.preparePermit(permitID: "permit-2")
        assertThrows(
            try permit.expirePermit(permitID: "permit-2", withTargetProof: false),
            .preparedRequiresAbortDecision(permitID: "permit-2"),
            "prepared 未授权必须 abort decision + 全 target abort proof"
        )
    }

    func testTargetJournalFrozenParticipantsAndPartialCommitBlocksDisabled() throws {
        let control = makeControl()
        let permit = makePermit(control: control)

        try permit.createPermit(permitID: "permit-1", generation: 1, participants: ["participant-a", "participant-b"])
        let participants = try permit.journalParticipants(permitID: "permit-1")
        XCTAssertEqual(participants, ["participant-a", "participant-b"], "journal 冻结完整 participant set（签发顺序）")

        // 局部提交：a committed，b reconciliationRequired → 阻止 disabled
        try permit.markJournal(permitID: "permit-1", participant: "participant-a", state: .committed)
        try permit.markJournal(permitID: "permit-1", participant: "participant-b", state: .reconciliationRequired)
        assertThrows(
            try control.transition(to: .disabled, expectedGeneration: 1, transitionID: "transition-blocked"),
            .partialCommitBlocksDisabled(detail: "1 permits not settled"),
            "局部提交/reconciliationRequired 阻止 disabled"
        )

        // 全部结算后可 disabled（settlement-start 先持久化）
        try permit.markJournal(permitID: "permit-1", participant: "participant-b", state: .committed)
        try permit.settlePermit(permitID: "permit-1", settlement: "settling", proofDigest: "settlement-start-proof")
        try permit.settlePermit(permitID: "permit-1", settlement: "settledCommitted", proofDigest: "proof")
        try control.transition(to: .disabled, expectedGeneration: 1, transitionID: "transition-ok")
        XCTAssertEqual(try control.controlState(), .disabled)
    }
}
