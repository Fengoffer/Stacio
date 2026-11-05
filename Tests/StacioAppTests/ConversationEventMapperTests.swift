import XCTest
import Foundation
@testable import StacioApp

/// P7-3：Runtime 信号映射与 effect 派发（信号不反向改 State、ephemeral 不冒充 durable、
/// outbox 派发、重验、崩溃对账）。
final class ConversationEventMapperTests: XCTestCase {

    // MARK: - Runtime 只以信号返回

    func testRuntimeReturnsSignalOnly() {
        XCTAssertTrue(ConversationEventMapper.runtimeReturnsSignalOnly(),
                      "Runtime 只能以信号返回结果不能反向修改 State")
    }

    func testEphemeralSignalOnlySourceIdentity() {
        let signal = RuntimeSignal(
            sourceEventID: "ev-1", sourceSequence: 3, result: .finalAnswer(text: "答")
        )
        XCTAssertTrue(ConversationEventMapper.signalHasOnlySourceIdentity(signal),
                      "未提交的 ephemeral RuntimeSignal 只有 source event ID/source sequence")
        XCTAssertFalse(
            ConversationEventMapper.signalHasOnlySourceIdentity(
                RuntimeSignal(sourceEventID: "", sourceSequence: 0, result: .protocolFailure)
            )
        )
    }

    // MARK: - effect 只能从已提交 outbox 派发

    func testEffectsDispatchedOnlyFromCommittedOutbox() {
        XCTAssertTrue(ConversationEventMapper.effectsDispatchedOnlyFromCommittedOutbox(),
                      "effect 只能从已提交 outbox 派发（不能拿 Permit 返回值直接执行）")
    }

    // MARK: - effect-capable 重验

    func testEffectCapableRevalidatesGenerationTargetLeaseAndLock() {
        XCTAssertTrue(ConversationEventMapper.effectCapableRevalidates(
            authorityGenerationMatches: true, targetLeaseMatches: true, conflictLockHeld: true
        ))
        // 任一不匹配 → 不派发
        XCTAssertFalse(ConversationEventMapper.effectCapableRevalidates(
            authorityGenerationMatches: false, targetLeaseMatches: true, conflictLockHeld: true
        ))
        XCTAssertFalse(ConversationEventMapper.effectCapableRevalidates(
            authorityGenerationMatches: true, targetLeaseMatches: false, conflictLockHeld: true
        ))
        XCTAssertFalse(ConversationEventMapper.effectCapableRevalidates(
            authorityGenerationMatches: true, targetLeaseMatches: true, conflictLockHeld: false
        ))
    }

    // MARK: - answer-only authority nil

    func testAnswerOnlyAuthorityMustBeNil() {
        XCTAssertTrue(ConversationEventMapper.answerOnlyAuthorityMustBeNil(authority: nil),
                      "answer-only outbox 的 authority 字段必须 nil")
        XCTAssertFalse(ConversationEventMapper.answerOnlyAuthorityMustBeNil(authority: "lease-1"))
    }

    func testRecordsStateBeforeAndAfterDispatch() {
        XCTAssertTrue(ConversationEventMapper.recordsStateBeforeAndAfterDispatch(),
                      "派发前后分别记录状态")
    }

    // MARK: - 崩溃对账

    func testReconcileAfterCrashDispatchWhenNoExecutedRecord() {
        let decision = ConversationEventMapper.reconcileAfterCrash(
            evidence: ReconcileEvidence(
                executedRecordExists: false, authorityLeaseGenerationMatches: true, idempotencyKey: "effect-1"
            )
        )
        XCTAssertEqual(decision, .dispatch(effectID: "effect-1", idempotencyKey: "effect-1"))
    }

    func testReconcileAfterCrashAlreadyExecutedWhenRecordAndGenerationMatch() {
        let decision = ConversationEventMapper.reconcileAfterCrash(
            evidence: ReconcileEvidence(
                executedRecordExists: true, authorityLeaseGenerationMatches: true, idempotencyKey: "effect-1"
            )
        )
        XCTAssertEqual(decision, .alreadyExecuted(effectID: "effect-1"), "幂等键核对已执行不重放")
    }

    func testReconcileAfterCrashStateUnknownWhenCannotProve() {
        let decision = ConversationEventMapper.reconcileAfterCrash(
            evidence: ReconcileEvidence(
                executedRecordExists: true, authorityLeaseGenerationMatches: false, idempotencyKey: "effect-1"
            )
        )
        XCTAssertEqual(decision, .stateUnknown(effectID: "effect-1"),
                       "无法证明未执行 → 状态不明，不重放")
    }
}
