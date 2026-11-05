import XCTest
import Foundation
@testable import StacioApp

/// C2-2：ConversationEvent 目录与 EventDraft 信封 + 事件应用规则。
final class ConversationEventTests: XCTestCase {

    private func envelope(
        kind: ConversationEventKind,
        sequence: Int,
        eventID: String = UUID().uuidString,
        scope: ConversationEventScope = .session
    ) -> ConversationEventEnvelope {
        ConversationEventEnvelope(
            eventID: eventID, conversationID: "c-1", scope: scope,
            candidateSequence: sequence, source: "test", timestamp: Date(),
            kind: kind, writeClass: .durable, payloadHash: "hash", payload: Data()
        )
    }

    func testAllDurableEventKindsConstructibleWithScope() {
        // 编译期 + 运行时：§8.3 durable 事件种类全部可构造并携带 scope
        for kind in ConversationEventKind.allCases {
            let env = envelope(kind: kind, sequence: 1, scope: .attempt)
            XCTAssertEqual(env.kind, kind)
            XCTAssertEqual(env.scope, .attempt)
            XCTAssertEqual(env.writeClass, .durable)
            XCTAssertEqual(env.conversationID, "c-1")
        }
        XCTAssertTrue(ConversationEventKind.allCases.count > 60, "§8.3 durable 事件清单应较大")
    }

    func testWriteClassThreeTiersDistinguishable() {
        let tiers = Set(ConversationEventWriteClass.allCases)
        XCTAssertEqual(tiers.count, 3)
        XCTAssertNotEqual(ConversationEventWriteClass.ephemeral, .checkpoint)
        XCTAssertNotEqual(ConversationEventWriteClass.checkpoint, .durable)
        XCTAssertNotEqual(ConversationEventWriteClass.ephemeral, .durable)
    }

    func testTerminalEventProtocolEnforcesRequiredFields() {
        // 满足 TerminalEventProviding 的样本类型可编译；缺字段即编译失败
        let sample = SampleTerminalEvent(
            attemptID: "a-1",
            phaseAtTermination: .streaming,
            reasonCode: .completed,
            effectReconciliationState: "settled",
            admissionSettlementID: "s-1",
            idempotencyKey: "idem-1"
        )
        XCTAssertEqual(sample.attemptID, "a-1")
        XCTAssertEqual(sample.reasonCode, .completed)
        XCTAssertEqual(sample.idempotencyKey, "idem-1")
    }

    func testApplicatorAppliesSequentialEvent() {
        let outcome = ConversationEventApplicator.apply(
            envelope: envelope(kind: .turnSubmitted, sequence: 5),
            lastApplied: 4,
            existingEventIDAtSequence: nil,
            existingPayloadHashAtSequence: nil
        )
        XCTAssertEqual(outcome, .applied)
    }

    func testApplicatorIgnoresDuplicateIdempotently() {
        let id = "idem-event"
        let outcome = ConversationEventApplicator.apply(
            envelope: envelope(kind: .attemptCompleted, sequence: 5, eventID: id),
            lastApplied: 4,
            existingEventIDAtSequence: id,
            existingPayloadHashAtSequence: "hash"
        )
        XCTAssertEqual(outcome, .duplicateIgnored)
    }

    func testApplicatorBuffersFutureGap() {
        let outcome = ConversationEventApplicator.apply(
            envelope: envelope(kind: .attemptStarted, sequence: 10),
            lastApplied: 4,
            existingEventIDAtSequence: nil,
            existingPayloadHashAtSequence: nil
        )
        guard case .futureBuffered(let from, let to) = outcome else {
            return XCTFail("应为 futureBuffered")
        }
        XCTAssertEqual(from, 5)
        XCTAssertEqual(to, 9)
    }

    func testApplicatorCorruptedOnSameSequenceDifferentEvent() {
        let outcome = ConversationEventApplicator.apply(
            envelope: envelope(kind: .attemptCompleted, sequence: 5, eventID: "different"),
            lastApplied: 4,
            existingEventIDAtSequence: "original",
            existingPayloadHashAtSequence: "other-hash"
        )
        XCTAssertEqual(outcome, .corrupted(reason: "same sequence with different event/hash"))
    }

    func testApplicatorCorruptedOnAlreadyConsumedSequence() {
        let outcome = ConversationEventApplicator.apply(
            envelope: envelope(kind: .attemptStarted, sequence: 3),
            lastApplied: 10,
            existingEventIDAtSequence: nil,
            existingPayloadHashAtSequence: nil
        )
        guard case .corrupted = outcome else {
            return XCTFail("应为 corrupted（sequence 已被消费）")
        }
    }
}

/// 满足 TerminalEventProviding 的样本（编译期证明协议字段被强制）
private struct SampleTerminalEvent: TerminalEventProviding {
    let attemptID: String
    let phaseAtTermination: AttemptPhase
    let reasonCode: AttemptReasonCode
    let effectReconciliationState: String
    let admissionSettlementID: String
    let idempotencyKey: String
}
