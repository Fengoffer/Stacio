import XCTest
import Foundation
@testable import StacioApp

/// P3-9：External Effect reconciliation（真实 Rust reconciliation 库后端，经 CoreBridge UniFFI）。
final class ExternalEffectReconciliationTests: XCTestCase {

    private func makeCoordinator() -> ExternalEffectReconciliationCoordinator {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-reconciliation-\(UUID().uuidString).sqlite3").path
        return try! ExternalEffectReconciliationCoordinator(databasePath: path)
    }

    // MARK: - conflictKey

    func testConflictKeyIsStableComposition() {
        let key = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "target-digest-1", resourceScope: "resource:file:/etc", operationClass: "write"
        )
        let same = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "target-digest-1", resourceScope: "resource:file:/etc", operationClass: "write"
        )
        XCTAssertEqual(key, same, "conflictKey 稳定")

        let differentClass = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "target-digest-1", resourceScope: "resource:file:/etc", operationClass: "read"
        )
        XCTAssertNotEqual(key, differentClass, "operationClass 变化改变 conflictKey")

        let differentTarget = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "target-digest-2", resourceScope: "resource:file:/etc", operationClass: "write"
        )
        XCTAssertNotEqual(key, differentTarget, "target digest 变化改变 conflictKey")

        let differentScope = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "target-digest-1", resourceScope: "resource:file:/var", operationClass: "write"
        )
        XCTAssertNotEqual(key, differentScope, "resource scope 变化改变 conflictKey")
    }

    // MARK: - 锁语义

    func testLockNotReleasedUntilAllRecordsSettled() throws {
        let coordinator = makeCoordinator()
        let key = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "d-1", resourceScope: "resource:file:/x", operationClass: "write"
        )

        try coordinator.createRecord(effectID: "effect-1", conflictKey: key, state: .unknown)
        try coordinator.createRecord(effectID: "effect-2", conflictKey: key, state: .verifiedCompleted)

        // 同 key 尚有 unknown 记录 → 锁不释放
        XCTAssertFalse(try coordinator.lockReleased(conflictKey: key))
        XCTAssertEqual(try coordinator.lockOwner(conflictKey: key), "reconciliation", "同 key 全记录终结前锁不释放")

        // 全部终结后锁释放
        try coordinator.settleRecord(effectID: "effect-1", settlement: .isolated)
        XCTAssertTrue(try coordinator.lockReleased(conflictKey: key), "全记录终结后锁释放")
        XCTAssertEqual(try coordinator.lockOwner(conflictKey: key), "released")
    }

    func testUnknownRemoteEffectLockDoesNotHoldGlobalAdmission() throws {
        let coordinator = makeCoordinator()
        let key = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "d-1", resourceScope: "resource:file:/x", operationClass: "write"
        )
        try coordinator.createRecord(effectID: "effect-1", conflictKey: key, state: .unknown)

        // 未知远端 effect 转锁：不永久占全局 Admission
        XCTAssertFalse(try coordinator.holdsGlobalAdmission(conflictKey: key), "未知远端 effect 锁不占全局 Admission")
    }

    // MARK: - evidence strength

    func testEvidenceStrengthRecordedPerRecord() throws {
        let coordinator = makeCoordinator()
        let key = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "d-1", resourceScope: "resource:file:/x", operationClass: "write"
        )
        try coordinator.createRecord(
            effectID: "effect-1", conflictKey: key, state: .unknown, evidenceStrength: .structured
        )

        XCTAssertEqual(try coordinator.evidenceStrength(effectID: "effect-1"), .structured, "每条记录冻结 evidence strength")

        // structured 不足以结算 verifiedCompleted（需要 verified 级证据）
        do {
            try coordinator.settleRecord(effectID: "effect-1", settlement: .verifiedCompleted)
            XCTFail("structured 证据不得结算 verifiedCompleted")
        } catch let error as V2ControlError {
            XCTAssertEqual(error, .evidenceTooWeak(effectID: "effect-1", required: "verified"))
        }
    }

    func testVerifiedStrengthAllowsVerifiedCompleted() throws {
        let coordinator = makeCoordinator()
        let key = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "d-1", resourceScope: "resource:file:/x", operationClass: "write"
        )
        try coordinator.createRecord(
            effectID: "effect-1", conflictKey: key, state: .unknown, evidenceStrength: .verified
        )
        try coordinator.settleRecord(effectID: "effect-1", settlement: .verifiedCompleted)
        XCTAssertTrue(try coordinator.lockReleased(conflictKey: key), "verified 证据结算后记录终结")
    }

    func testSettleTerminalIdempotent() throws {
        let coordinator = makeCoordinator()
        let key = ExternalEffectReconciliationCoordinator.conflictKey(
            targetDigest: "d-1", resourceScope: "resource:file:/x", operationClass: "write"
        )
        try coordinator.createRecord(effectID: "effect-1", conflictKey: key, state: .unknown)
        try coordinator.settleRecord(effectID: "effect-1", settlement: .isolated)
        // 终态重复结算幂等（ack 丢失/重放安全）
        try coordinator.settleRecord(effectID: "effect-1", settlement: .isolated)
        XCTAssertTrue(try coordinator.lockReleased(conflictKey: key))
    }
}
