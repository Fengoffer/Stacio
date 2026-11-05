import XCTest
import Foundation
@testable import StacioApp

/// C2-4：EffectCommand 与 outbox 值。
///
/// 合同：
/// - outbox 值带稳定 effect ID、operation ID、幂等键、authority/capability generation 重验字段，
///   需要时带 V2 Permit commit decision；
/// - answer-only effect 的 authority 字段必须为 nil（工厂强制，不能塞入伪空 authority）；
/// - 每个 outbox item 幂等键唯一。
final class ConversationEffectCommandTests: XCTestCase {

    func testAllEffectKindsConstructible() {
        // 编译期：EffectCommand 全部 case 可构造（C2-3 迁移到本文件后仍可用）
        let commands: [EffectCommand] = [
            .requestAdmission(sessionID: "c-1", turnID: "t-1", attemptID: "a-1"),
            .startRuntime(attemptID: "a-1"),
            .resolveDecision(decisionID: "d-1", outcome: .approved, source: "user"),
            .finalizeAttempt(attemptID: "a-1", outcome: .completed, reasonCode: .completed),
            .requestAnswerOnlyLaunch(attemptID: "a-1")
        ]
        XCTAssertEqual(commands.count, 5)
    }

    func testOutboxItemCarriesStableIDsAndRevalidationFields() {
        let commands: [EffectCommand] = [
            .requestAdmission(sessionID: "c-1", turnID: "t-1", attemptID: "a-1"),
            .startRuntime(attemptID: "a-1")
        ]
        let items = ConversationEffectOutboxFactory.make(
            commands: commands,
            sessionID: "c-1",
            turnID: "t-1",
            attemptID: "a-1",
            authorityLeaseID: "auth-9",
            capabilityGeneration: 3
        )
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertFalse(item.effectID.isEmpty, "effectID 必须稳定非空")
            XCTAssertFalse(item.operationID.isEmpty, "operationID 必须非空")
            XCTAssertFalse(item.idempotencyKey.isEmpty, "幂等键必须非空")
            XCTAssertEqual(item.authorityLeaseID, "auth-9", "普通 effect 携带 authority 重验引用")
            XCTAssertEqual(item.capabilityGeneration, 3, "携带 capability generation 重验字段")
        }
        // 稳定 effect ID 可对账：requestAdmission 的 effectID 编码 kind + attempt
        XCTAssertTrue(items[0].effectID.contains("a-1"))
    }

    func testPermitCommitDecisionOnlyWhenNeeded() {
        let commands: [EffectCommand] = [.startRuntime(attemptID: "a-1")]
        let withPermit = ConversationEffectOutboxFactory.make(
            commands: commands,
            sessionID: "c-1", turnID: "t-1", attemptID: "a-1",
            permitCommitDecision: .commitAuthorized
        )
        XCTAssertEqual(withPermit[0].permitCommitDecision, .commitAuthorized)

        let withoutPermit = ConversationEffectOutboxFactory.make(
            commands: commands,
            sessionID: "c-1", turnID: "t-1", attemptID: "a-1"
        )
        XCTAssertNil(withoutPermit[0].permitCommitDecision, "不需要 Permit 时不得填充")
    }

    func testAnswerOnlyEffectAuthorityForcedNil() {
        // answer-only effect 的 authority 必须为 nil：即使调用方误传也强制清空，不能塞入伪空 authority
        let commands: [EffectCommand] = [
            .requestAnswerOnlyLaunch(attemptID: "a-1"),
            .finalizeAttempt(attemptID: "a-1", outcome: .completed, reasonCode: .completed)
        ]
        let items = ConversationEffectOutboxFactory.make(
            commands: commands,
            sessionID: "c-1", turnID: "t-1", attemptID: "a-1",
            authorityLeaseID: "auth-9",
            capabilityGeneration: 2
        )
        XCTAssertNil(items[0].authorityLeaseID, "answer-only launch 不得携带 authority")
        XCTAssertNil(items[0].capabilityGeneration, "answer-only launch 不得携带 capability generation")
        XCTAssertEqual(items[1].authorityLeaseID, "auth-9", "非 answer-only effect 正常携带 authority")
    }

    func testIdempotencyKeysUniqueWithinBatch() {
        // 同一批内多个命令（含同类重复）幂等键必须唯一
        let commands: [EffectCommand] = [
            .resolveDecision(decisionID: "d-1", outcome: .approved, source: "user"),
            .resolveDecision(decisionID: "d-2", outcome: .denied, source: "user"),
            .finalizeAttempt(attemptID: "a-1", outcome: .completed, reasonCode: .completed)
        ]
        let items = ConversationEffectOutboxFactory.make(
            commands: commands,
            sessionID: "c-1", turnID: "t-1", attemptID: "a-1"
        )
        let keys = Set(items.map(\.idempotencyKey))
        XCTAssertEqual(keys.count, items.count, "每个 outbox item 幂等键必须唯一")
        XCTAssertEqual(Set(items.map(\.itemID)).count, items.count, "itemID 必须唯一")
    }

    func testOutboxDeterministicForSameInput() {
        // outbox 工厂是纯计算：相同输入产出相同 itemID/effectID/幂等键（无随机）
        let commands: [EffectCommand] = [.requestAdmission(sessionID: "c-1", turnID: "t-1", attemptID: "a-1")]
        let first = ConversationEffectOutboxFactory.make(
            commands: commands, sessionID: "c-1", turnID: "t-1", attemptID: "a-1"
        )
        let second = ConversationEffectOutboxFactory.make(
            commands: commands, sessionID: "c-1", turnID: "t-1", attemptID: "a-1"
        )
        XCTAssertEqual(first, second)
    }
}
