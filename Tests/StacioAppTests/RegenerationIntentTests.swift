import XCTest
import Foundation
@testable import StacioApp

/// C2-9：RegenerationIntent、canonical write lease 与 CAS、answer-only 合同。
///
/// 合同：
/// - 快速连续 Retry/Regenerate 只保留最后一个 durable Intent（nextRegenerationOrdinal 递增、旧 intent superseded）；
/// - 旧 Attempt 未终态不 materialize 新 Attempt；
/// - `answerOnly → purpose == answerRegeneration`、`rerunTask → retrySameConfig/retryNewConfig`；
/// - answer-only 两类 Attempt `executionAuthorityLeaseID == nil`、allowedEffectClasses 全 0；
/// - `launchKind == answerOnlyTurn|answerRegeneration` 独立 capability/process/journal；
/// - `sameSnapshot/reviewedCurrent` 差异审阅（不能静默换模型/CLI/账号/profile）；
/// - retired/deleted/revoked generation 拒绝；
/// - canonical final CAS（revision compare-and-swap）在 lease/expected revision 校验后单事务写入；
/// - 失去 lease/CAS 冲突的迟到完成写 `finalAnswerSuperseded` 不改 canonical；旧答案在 CAS 前保持 lastKnownGood。
final class RegenerationIntentTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTurn(attempt: TurnAttempt? = nil) -> ConversationTurn {
        let attempt = attempt ?? TurnAttempt(
            id: "a-1", turnID: "t-1", ordinal: 1, phase: .completed,
            purpose: .initial, runtimeSnapshot: "rs", workModeSnapshot: .agent,
            policySnapshot: "ps", toolCapabilitySnapshot: "tcs",
            instructionSnapshot: "is", startedAt: Self.fixedDate
        )
        return ConversationTurn(
            id: "t-1", sessionID: "c-1", ordinal: 1, userRequest: "hi",
            phase: attempt.phase, attempts: [attempt], activeAttemptID: attempt.id,
            nextRegenerationOrdinal: 0, timing: [:], usage: [:]
        )
    }

    // MARK: - Intent 合并

    func testRapidRegenerateKeepsOnlyLastDurableIntent() {
        var turn = makeTurn()
        let (turn1, intent1, _) = RegenerationIntentEngine.enqueueIntent(
            turn: turn, kind: .answerOnly, configurationMode: .sameSnapshot,
            sourceAttemptID: "a-1", now: Self.fixedDate
        )
        XCTAssertEqual(intent1.ordinal, 1)
        XCTAssertEqual(intent1.state, .pending)

        let (turn2, intent2, supersededOld) = RegenerationIntentEngine.enqueueIntent(
            turn: turn1, kind: .answerOnly, configurationMode: .sameSnapshot,
            sourceAttemptID: "a-1", now: Self.fixedDate
        )
        XCTAssertEqual(intent2.ordinal, 2, "nextRegenerationOrdinal 递增")
        XCTAssertEqual(intent2.state, .pending, "最后 intent 保留 pending")
        XCTAssertEqual(turn2.nextRegenerationOrdinal, 2)
        XCTAssertEqual(supersededOld?.state, .superseded, "旧 intent 必须 superseded")
        XCTAssertEqual(supersededOld?.supersededByIntentID, intent2.intentID)
        XCTAssertEqual(turn2.pendingRegenerationIntent?.intentID, intent2.intentID, "只保留最后一个 durable Intent")
    }

    func testOldAttemptNotTerminalBlocksMaterialize() {
        var turn = makeTurn()
        let (withIntent, intent, _) = RegenerationIntentEngine.enqueueIntent(
            turn: turn, kind: .answerOnly, configurationMode: .sameSnapshot,
            sourceAttemptID: "a-1", now: Self.fixedDate
        )
        // 旧 Attempt 未终态（streaming）→ 不 materialize
        var streamingTurn = makeTurn(attempt: TurnAttempt(
            id: "a-1", turnID: "t-1", ordinal: 1, phase: .streaming,
            purpose: .initial, runtimeSnapshot: "rs", workModeSnapshot: .agent,
            policySnapshot: "ps", toolCapabilitySnapshot: "tcs",
            instructionSnapshot: "is", startedAt: Self.fixedDate
        ))
        streamingTurn.pendingRegenerationIntent = intent
        XCTAssertFalse(RegenerationIntentEngine.canMaterialize(turn: streamingTurn), "旧 Attempt 未终态不 materialize")

        // 终态后 materialize → 新 Attempt
        let (materialized, newAttemptID) = RegenerationIntentEngine.materialize(turn: withIntent, now: Self.fixedDate)
        XCTAssertTrue(materialized.pendingRegenerationIntent?.state == .materialized)
        XCTAssertNotNil(newAttemptID)
        XCTAssertEqual(materialized.attempts.count, 2, "materialize 创建新 Attempt")
        XCTAssertEqual(materialized.attempts.last?.phase, .preparing)
    }

    // MARK: - purpose 映射

    func testAnswerOnlyPurposeIsAnswerRegeneration() {
        XCTAssertEqual(
            RegenerationIntentEngine.purpose(for: .answerOnly, configMode: .sameSnapshot),
            .answerRegeneration
        )
        XCTAssertEqual(
            RegenerationIntentEngine.purpose(for: .answerOnly, configMode: .reviewedCurrent),
            .answerRegeneration
        )
    }

    func testRerunTaskPurposeByConfigMode() {
        XCTAssertEqual(
            RegenerationIntentEngine.purpose(for: .rerunTask, configMode: .sameSnapshot),
            .retrySameConfig
        )
        XCTAssertEqual(
            RegenerationIntentEngine.purpose(for: .rerunTask, configMode: .reviewedCurrent),
            .retryNewConfig
        )
    }

    func testReviewedCurrentRequiresReviewNotSilent() {
        // sameSnapshot 无需审阅；reviewedCurrent 必须显式审阅差异（不能静默换模型/CLI/账号/profile）
        let same = RegenerationIntent(
            intentID: "i-1", turnID: "t-1", ordinal: 1, requestedAt: Self.fixedDate,
            kind: .rerunTask, state: .pending, sourceAttemptID: "a-1",
            expectedCanonicalRevision: 1, configurationMode: .sameSnapshot,
            configurationRevisionDigest: "cfg-1"
        )
        XCTAssertFalse(RegenerationIntentEngine.requiresReview(same))

        let reviewed = RegenerationIntent(
            intentID: "i-2", turnID: "t-1", ordinal: 2, requestedAt: Self.fixedDate,
            kind: .rerunTask, state: .pending, sourceAttemptID: "a-1",
            expectedCanonicalRevision: 1, configurationMode: .reviewedCurrent,
            configurationRevisionDigest: "cfg-2"
        )
        XCTAssertTrue(RegenerationIntentEngine.requiresReview(reviewed), "reviewedCurrent 必须审阅差异")
    }

    // MARK: - generation 可用性

    func testRetiredRevokedGenerationRejected() {
        XCTAssertTrue(RegenerationIntentEngine.generationUsable(.active))
        XCTAssertTrue(RegenerationIntentEngine.generationUsable(.pendingActivation))
        XCTAssertFalse(RegenerationIntentEngine.generationUsable(.retired))
        XCTAssertFalse(RegenerationIntentEngine.generationUsable(.revoked))
        XCTAssertFalse(RegenerationIntentEngine.generationUsable(.abandoned))
    }

    // MARK: - answer-only 合同

    func testAnswerOnlyAttemptHasNoAuthorityAndZeroEffectClasses() {
        // answer-only 两类 Attempt：executionAuthorityLeaseID == nil、allowedEffectClasses 全 0
        let capability = AnswerOnlyRuntimeLaunchCapability(
            capabilityID: "cap-1", turnID: "t-1", attemptID: "a-1",
            localAgentConfigurationID: "lc-1", admissionLeaseID: "lease-1",
            launchKind: .answerOnlyTurn, state: .issued,
            executableIdentityDigest: "exec", executionProfileID: "profile",
            containmentRevision: "cont-1", processGeneration: 1,
            cliAuthenticationScopeDigest: "", allowedModelOrigins: ["moonshot"],
            networkPolicyDigest: "net-1", readOnlyInputChannelDigest: "input-1",
            privateEphemeralScratchReference: "scratch-1", scratchDeletionFence: "fence-1",
            targetBindingAccess: "none", projectWorkspaceAccess: "readonly",
            terminalAccess: "none", effectBrokerAccess: "none",
            childProcessPolicy: "none", persistentWritePolicy: "none",
            launchJournalID: "journal-1", issuedAt: Self.fixedDate
        )
        // effect broker access 全 0（无工具/无 effect 能力）
        XCTAssertEqual(capability.effectBrokerAccess, "none")
        XCTAssertEqual(capability.terminalAccess, "none")
        XCTAssertEqual(capability.targetBindingAccess, "none")

        // answer-only Attempt 无 execution authority lease
        let answerOnlyAttempt = TurnAttempt(
            id: "a-2", turnID: "t-1", ordinal: 2, phase: .streaming,
            purpose: .answerRegeneration, runtimeSnapshot: "rs",
            workModeSnapshot: .answerOnly, policySnapshot: "ps",
            toolCapabilitySnapshot: "tcs", instructionSnapshot: "is",
            executionAuthorityLeaseID: nil, answerOnlyRuntimeLaunchCapabilityID: "cap-1",
            startedAt: Self.fixedDate
        )
        XCTAssertNil(answerOnlyAttempt.executionAuthorityLeaseID, "answer-only 不得持有 execution authority")
        XCTAssertEqual(answerOnlyAttempt.answerOnlyRuntimeLaunchCapabilityID, "cap-1")
    }

    func testLaunchKindsAreIndependentCapabilities() {
        // launchKind == answerOnlyTurn | answerRegeneration 独立 capability/process/journal
        let turnLaunch = AnswerOnlyRuntimeLaunchCapability(
            capabilityID: "cap-turn", turnID: "t-1", attemptID: "a-1",
            localAgentConfigurationID: "lc-1", admissionLeaseID: "lease-1",
            launchKind: .answerOnlyTurn, state: .issued,
            executableIdentityDigest: "exec", executionProfileID: "profile",
            containmentRevision: "cont-1", processGeneration: 1,
            cliAuthenticationScopeDigest: "", allowedModelOrigins: [],
            networkPolicyDigest: "net-1", readOnlyInputChannelDigest: "input-1",
            privateEphemeralScratchReference: "scratch-1", scratchDeletionFence: "fence-1",
            targetBindingAccess: "none", projectWorkspaceAccess: "readonly",
            terminalAccess: "none", effectBrokerAccess: "none",
            childProcessPolicy: "none", persistentWritePolicy: "none",
            launchJournalID: "journal-turn", issuedAt: Self.fixedDate
        )
        let regenLaunch = AnswerOnlyRuntimeLaunchCapability(
            capabilityID: "cap-regen", turnID: "t-1", attemptID: "a-2",
            localAgentConfigurationID: "lc-1", admissionLeaseID: "lease-2",
            launchKind: .answerRegeneration, state: .issued,
            executableIdentityDigest: "exec", executionProfileID: "profile",
            containmentRevision: "cont-1", processGeneration: 2,
            cliAuthenticationScopeDigest: "", allowedModelOrigins: [],
            networkPolicyDigest: "net-1", readOnlyInputChannelDigest: "input-2",
            privateEphemeralScratchReference: "scratch-2", scratchDeletionFence: "fence-2",
            targetBindingAccess: "none", projectWorkspaceAccess: "readonly",
            terminalAccess: "none", effectBrokerAccess: "none",
            childProcessPolicy: "none", persistentWritePolicy: "none",
            launchJournalID: "journal-regen", issuedAt: Self.fixedDate
        )
        XCTAssertNotEqual(turnLaunch.capabilityID, regenLaunch.capabilityID)
        XCTAssertNotEqual(turnLaunch.processGeneration, regenLaunch.processGeneration)
        XCTAssertNotEqual(turnLaunch.launchJournalID, regenLaunch.launchJournalID)
        XCTAssertNotEqual(turnLaunch.launchKind, regenLaunch.launchKind)
    }

    // MARK: - canonical final CAS

    private func makeLease(expectedRevision: Int = 0, state: CanonicalFinalAnswerWriteLeaseState = .active) -> CanonicalFinalAnswerWriteLease {
        CanonicalFinalAnswerWriteLease(
            leaseID: "w-1", turnID: "t-1", attemptID: "a-1",
            regenerationOrdinal: 1, expectedCanonicalRevision: expectedRevision,
            issuedAt: Self.fixedDate, state: state
        )
    }

    private func makeCurrentAnswer(revision: Int, lastKnownGood: Bool = true) -> CanonicalFinalAnswer {
        CanonicalFinalAnswer(
            attemptID: "a-0", revision: revision, markdownSourceDigest: "old",
            state: .available, createdAt: Self.fixedDate,
            completedAt: Self.fixedDate, lastKnownGood: lastKnownGood
        )
    }

    func testCanonicalFinalAnswerCASCommitsOnExpectedRevision() {
        let current = makeCurrentAnswer(revision: 0)
        let result = RegenerationIntentEngine.commitFinalAnswer(
            current: current,
            lease: makeLease(expectedRevision: 0),
            attemptID: "a-1",
            markdownDigest: "new-digest",
            now: Self.fixedDate
        )
        guard case let .committed(answer) = result else {
            return XCTFail("expected revision 匹配应提交")
        }
        XCTAssertEqual(answer.revision, 1, "CAS 后 canonical revision 递增")
        XCTAssertEqual(answer.markdownSourceDigest, "new-digest")
        XCTAssertTrue(answer.lastKnownGood)
        XCTAssertEqual(answer.state, .available)
    }

    func testOldAnswerLastKnownGoodUntilCAS() {
        // CAS 前旧答案保持 lastKnownGood
        let current = makeCurrentAnswer(revision: 0, lastKnownGood: true)
        // 迟到完成（lease 失效）→ superseded，不改 canonical
        let result = RegenerationIntentEngine.commitFinalAnswer(
            current: current,
            lease: makeLease(expectedRevision: 0, state: .consumed),
            attemptID: "a-1",
            markdownDigest: "late",
            now: Self.fixedDate
        )
        guard case let .superseded(late) = result else {
            return XCTFail("失去 lease 的迟到完成必须 superseded")
        }
        XCTAssertEqual(late.markdownSourceDigest, "late")
        XCTAssertEqual(current.revision, 0, "canonical 不被迟到完成修改")
        XCTAssertTrue(current.lastKnownGood, "旧答案在 CAS 前保持 lastKnownGood")
    }

    func testCASConflictSupersededDoesNotMutateCanonical() {
        // CAS 冲突：current.revision(2) != expected(0) → superseded，不改 canonical
        let current = makeCurrentAnswer(revision: 2)
        let result = RegenerationIntentEngine.commitFinalAnswer(
            current: current,
            lease: makeLease(expectedRevision: 0),
            attemptID: "a-1",
            markdownDigest: "conflict",
            now: Self.fixedDate
        )
        guard case .superseded = result else {
            return XCTFail("revision 不匹配必须 superseded")
        }
        XCTAssertEqual(current.revision, 2, "CAS 冲突不改 canonical")
        XCTAssertTrue(current.lastKnownGood)
    }

    func testMissingLeaseSuperseded() {
        let result = RegenerationIntentEngine.commitFinalAnswer(
            current: makeCurrentAnswer(revision: 1),
            lease: nil,
            attemptID: "a-1",
            markdownDigest: "no-lease",
            now: Self.fixedDate
        )
        guard case .superseded = result else {
            return XCTFail("无 write lease 的完成必须 superseded")
        }
    }
}
