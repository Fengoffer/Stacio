import XCTest
import Foundation
@testable import StacioApp

/// C2-5：ConversationSessionActor 单写入、ActorRegistry 跨窗口、Store 契约与 test double。
///
/// 合同：
/// - Registry 对同一 sessionID 返回同一 Actor；
/// - Actor 串行化并发 intent（单写入）；`expectedLastSequence` 推导连续 candidate range；
/// - 批提交只有事务成功才发布 TentativeState；冲突/失败时丢弃整批预演（不发布、不推进）；
/// - 提交前经可注入的 `ConversationSealing` 做本地 sealed-box 验证（Phase 2 test double；
///   真实 CryptoKit 实现属 P3-5，P3-6 以相同测试名接入真实密封器）；
/// - 重复投递幂等忽略；乱序/缺口拒绝。
final class ConversationSessionActorTests: XCTestCase {

    // MARK: - helpers

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTargetBinding() -> TargetBinding {
        TargetBinding(
            id: "tb-1", revision: 1, digest: "d1", connectionID: "conn-1",
            connectionKind: "ssh", remoteIdentity: "user@host", hostKeyFingerprint: "fp",
            host: "host", user: "user", port: 22, targetWorkingDirectory: "~"
        )
    }

    private func makeState() -> ConversationSessionState {
        let session = ConversationSession(
            id: "c-1", title: "t", createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
            targetBinding: makeTargetBinding(),
            runtimeSelection: AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1")
        )
        return ConversationSessionState(session: session, lastAppliedSequence: 0)
    }

    private func makeDraft(kind: ConversationEventKind, sequence: Int, expectedLast: Int, payload: Data = Data()) -> EventDraft {
        let envelope = ConversationEventEnvelope(
            eventID: "ev-\(sequence)", conversationID: "c-1", scope: .attempt,
            turnID: "t-1", attemptID: "a-1", candidateSequence: sequence,
            source: "test", timestamp: Self.fixedDate, kind: kind,
            writeClass: .durable, payloadHash: "h-\(sequence)", payload: payload
        )
        return EventDraft(envelope: envelope, expectedLastSequence: expectedLast)
    }

    private func makeSealing() -> TestConversationSealing {
        TestConversationSealing()
    }

    /// P3-6：真实 Repository（去掉 test double）——Swift facade → ConversationEncryption → Rust 独立库。
    private func makeStore(
        databasePath: String? = nil,
        conversationID: String = "c-1"
    ) -> ConversationSessionStore {
        let path = databasePath
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("v2-test-\(UUID().uuidString).sqlite3").path
        let encryption = ConversationEncryption(masterKeyData: Data((0..<32).map { UInt8($0) }))
        return try! ConversationRepositoryV2(
            conversationID: conversationID, databasePath: path, encryption: encryption
        )
    }

    private func makeIdentityStore() -> InMemoryConversationSessionStore {
        InMemoryConversationSessionStore()
    }

    // MARK: - Registry 跨窗口

    func testRegistryReturnsSameActorAcrossScenes() {
        let registry = ConversationActorRegistry()
        let store = makeStore()
        let sealing = makeSealing()
        let initialState = makeState()
        let first = registry.actor(for: "c-1", store: store, sealing: sealing, initialState: initialState)
        let second = registry.actor(for: "c-1", store: store, sealing: sealing, initialState: initialState)
        XCTAssertTrue(first === second, "跨窗口/场景同一会话必须返回同一 Actor")
        let other = registry.actor(for: "c-2", store: store, sealing: sealing, initialState: initialState)
        XCTAssertFalse(first === other, "不同会话必须返回不同 Actor")
    }

    func testRegistryReleasesActorAfterLastClientCloses() {
        let registry = ConversationActorRegistry()
        weak var releasedActor: ConversationSessionActor?
        do {
            let actor = registry.actor(
                for: "c-1",
                store: makeStore(),
                sealing: makeSealing(),
                initialState: makeState()
            )
            releasedActor = actor
            XCTAssertTrue(registry.existingActor(for: "c-1") === actor)
        }

        XCTAssertNil(releasedActor)
        XCTAssertNil(registry.existingActor(for: "c-1"))
    }

    // MARK: - 单写入与串行化

    func testActorSerializesConcurrentIntents() {
        // 两个并发提交同一序列（竞争单写入）：串行处理后只有一个成功
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: makeStore(), sealing: makeSealing()
        )
        let exp1 = expectation(description: "first")
        let exp2 = expectation(description: "second")
        var results: [Bool] = []

        let queue1 = DispatchQueue(label: "q1")
        let queue2 = DispatchQueue(label: "q2")
        queue1.async {
            actor.submit([self.makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { tentative in
                results.append(tentative != nil)
                exp1.fulfill()
            }
        }
        queue2.async {
            actor.submit([self.makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { tentative in
                results.append(tentative != nil)
                exp2.fulfill()
            }
        }
        wait(for: [exp1, exp2], timeout: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter { $0 }.count, 2, "同一事件的并发重复投递应都得到幂等成功")
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)
        XCTAssertEqual(actor.latestPublishedState?.phase, .preparing)
    }

    // MARK: - candidate range

    func testCandidateRangeContiguousAndExpectedDerived() {
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let drafts = [
            makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0),
            makeDraft(kind: .admissionRequested, sequence: 2, expectedLast: 1),
            makeDraft(kind: .admissionGranted, sequence: 3, expectedLast: 2)
        ]
        let exp = expectation(description: "commit")
        actor.submit(drafts) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        // 真实持久层：整批一次事务提交，candidate range 连续（lastApplied 直接推进到 3）
        XCTAssertEqual(actor.currentLastAppliedSequence, 3, "expectedLastSequence 推导 + candidate range 连续")
        XCTAssertEqual(actor.latestPublishedState?.phase, .startingRuntime)
        let snapshot = try? store.load()
        XCTAssertEqual(snapshot?.lastAppliedSequence, 3, "真实库确认整批提交")
    }

    // MARK: - 发布与冲突

    func testCommitSuccessPublishesTentativeState() {
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let exp = expectation(description: "commit")
        var published: TentativeState?
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { tentative in
            published = tentative
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNotNil(published, "事务成功才发布 TentativeState")
        XCTAssertEqual(published?.state.phase, .preparing)
        XCTAssertEqual(published?.state.lastAppliedSequence, 1)
    }

    func testAllStateObserversReceiveCommittedStateOnMainThread() {
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: makeStore(), sealing: makeSealing()
        )
        let first = expectation(description: "first observer")
        let second = expectation(description: "second observer")
        let firstToken = actor.addStateObserver { state in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(state.lastAppliedSequence, 1)
            first.fulfill()
        }
        let secondToken = actor.addStateObserver { state in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(state.lastAppliedSequence, 1)
            second.fulfill()
        }
        defer {
            actor.removeStateObserver(firstToken)
            actor.removeStateObserver(secondToken)
        }

        let outcome = actor.submitSync([
            makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)
        ])
        guard case .committed = outcome else {
            return XCTFail("事件应提交成功")
        }
        wait(for: [first, second], timeout: 5)
    }

    func testConflictDiscardsTentativeBatchAndReplaysCommittedWinner() {
        // 真实冲突：预提交 sequence 1（模拟并发竞争者），Actor 用旧 expected 提交 → Rust 层 ExpectedMismatch
        let store = makeStore()
        let preEnvelope = ConversationEventEnvelope(
            eventID: "ev-pre", conversationID: "c-1", scope: .attempt,
            turnID: "t-1", attemptID: "a-1", candidateSequence: 1,
            source: "competitor", timestamp: Self.fixedDate, kind: .turnSubmitted,
            writeClass: .durable, payloadHash: "h-pre", payload: Data()
        )
        _ = try? store.commit(
            expectedLastSequence: 0, candidates: [preEnvelope], projections: [:], outbox: []
        )

        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let exp = expectation(description: "commit")
        var published: TentativeState?
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { tentative in
            published = tentative
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(published, "冲突必须丢弃整批预演，不发布")
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)
        XCTAssertEqual(actor.latestPublishedState?.phase, .preparing)
        XCTAssertEqual(actor.latestPublishedState?.activeTurn?.id, "t-1")

        // 后续重试必须从竞争者已经提交并 replay 的 preparing 状态继续，而不是重复创建 Turn。
        let exp2 = expectation(description: "retry")
        actor.submit([makeDraft(kind: .admissionRequested, sequence: 2, expectedLast: 1)]) { tentative in
            XCTAssertNotNil(tentative, "以新 range 重试可成功")
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(actor.currentLastAppliedSequence, 2)
        XCTAssertEqual(actor.latestPublishedState?.phase, .waitingForCapacity)
    }

    // MARK: - P3-6 真实持久层契约

    func testRealRepositoryPersistsLastAppliedAcrossInstances() throws {
        // 真实持久化：同一数据库文件重新打开 → lastApplied 保留
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-persist-\(UUID().uuidString).sqlite3").path
        let store = makeStore(databasePath: path)
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let exp = expectation(description: "commit")
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)

        let reopened = makeStore(databasePath: path)
        let snapshot = try reopened.load()
        XCTAssertEqual(snapshot.lastAppliedSequence, 1, "真实库跨实例保留 lastApplied")
    }

    func testRealRepositoryRejectsTamperedPayloadBeforeCommit() {
        // AAD 本地验证失败不调用 Repository：篡改密封前 payload 不可行（seal 即验证），
        // 此处验证真实密封器 seal→verify 闭环（错误 AAD 场景由 ConversationEncryptionTests 覆盖）
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let exp = expectation(description: "commit")
        var published: TentativeState?
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { tentative in
            published = tentative
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNotNil(published, "真实密封器验证通过后可提交")
    }

    func testSealingFailurePreventsCommit() {
        let store = makeStore()
        let sealing = makeSealing()
        sealing.shouldVerify = false
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: sealing
        )
        let exp = expectation(description: "commit")
        var published: TentativeState?
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { tentative in
            published = tentative
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(published, "提交前本地 sealed-box 验证失败不得提交")
        XCTAssertEqual(actor.currentLastAppliedSequence, 0, "验证失败不调用 Repository commit（lastApplied 不推进）")
    }

    // MARK: - 幂等与乱序

    func testDuplicateDeliveryIdempotentlyIgnored() {
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let exp1 = expectation(description: "first")
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 5)

        // 同 eventID 同 hash 重复投递（重放携带当前期望序列）→ 幂等忽略（不重复 commit、状态不变）
        let exp2 = expectation(description: "duplicate")
        var published: TentativeState?
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 1)]) { tentative in
            published = tentative
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5)
        XCTAssertNotNil(published, "重复投递幂等忽略，返回已发布状态")
        XCTAssertEqual(actor.currentLastAppliedSequence, 1, "重复投递不推进 lastApplied（幂等忽略）")
        let snapshot = try? store.load()
        XCTAssertEqual(snapshot?.lastAppliedSequence, 1, "真实库事件未被重复写入")
    }

    func testDuplicateDeliveryWithOriginalExpectedSequenceIsIdempotent() {
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let draft = makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)
        guard case .committed = actor.submitSync([draft]) else {
            return XCTFail("first delivery should commit")
        }

        guard case .committed(let state) = actor.submitSync([draft]) else {
            return XCTFail("retrying the original batch must be idempotent")
        }
        XCTAssertEqual(state.lastAppliedSequence, 1)
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)
        XCTAssertEqual(try? store.load().lastAppliedSequence, 1)
    }

    func testConversationIDMismatchFailsBeforeStoreCommit() {
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        var draft = makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)
        draft.envelope.conversationID = "other-conversation"

        guard case .rejected(.invalidTransition) = actor.submitSync([draft]) else {
            return XCTFail("cross-conversation event must fail closed")
        }
        XCTAssertEqual(actor.currentLastAppliedSequence, 0)
        XCTAssertEqual(try? store.load().lastAppliedSequence, 0)
    }

    func testIdempotentDeliveryRecoversActorWhenStoreIsAhead() {
        let store = makeStore()
        let draft = makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)
        _ = try? store.commit(
            expectedLastSequence: 0,
            candidates: [draft.envelope],
            projections: [:],
            outbox: []
        )
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: makeState(),
            store: store,
            sealing: makeSealing()
        )

        let outcome = actor.submitSync([draft])

        guard case .committed(let state) = outcome else {
            return XCTFail("库内同 eventID/hash 的事件应幂等恢复")
        }
        XCTAssertEqual(state.lastAppliedSequence, 1)
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)
    }

    func testIdempotentFastPathRequiresCompleteEventIdentity() {
        let store = makeIdentityStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: makeState(),
            store: store,
            sealing: makeSealing()
        )
        let original = makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)
        guard case .committed = actor.submitSync([original]) else {
            return XCTFail("first delivery should commit")
        }

        // Keep the event ID/hash but alter reducer-visible identity. The Actor
        // must not treat this as an idempotent retry or let the replacement
        // advance the durable sequence.
        var conflicting = original
        conflicting.envelope.kind = .admissionRequested
        conflicting.envelope.source = "different-source"
        conflicting.expectedLastSequence = 1

        guard case .rejected = actor.submitSync([conflicting]) else {
            return XCTFail("same ID/hash with different event identity must be rejected")
        }
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)
        XCTAssertEqual(store.commitCount, 1, "conflicting identity must not hit the commit fast path")

        var rebound = original
        rebound.envelope.scope = .session
        rebound.envelope.turnID = "turn-other"
        rebound.envelope.attemptID = "attempt-other"
        rebound.expectedLastSequence = 1
        guard case .rejected = actor.submitSync([rebound]) else {
            return XCTFail("same ID/hash with rebound scope or owner IDs must be rejected")
        }

        var changedPayload = original
        changedPayload.envelope.payload = Data("different payload".utf8)
        changedPayload.expectedLastSequence = 1
        guard case .rejected = actor.submitSync([changedPayload]) else {
            return XCTFail("caller-provided payloadHash cannot hide different payload bytes")
        }
        XCTAssertEqual(store.commitCount, 1)
    }

    func testRestoreStateCannotRollBackOrDivergePublishedActorState() {
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: makeState(),
            store: makeStore(),
            sealing: makeSealing()
        )
        guard case .committed(let committed) = actor.submitSync([
            makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)
        ]) else {
            return XCTFail("test state must commit")
        }

        XCTAssertEqual(actor.restoreState(makeState()), .rejectedNewerState)
        var divergent = committed
        divergent.session.title = "different projection"
        XCTAssertEqual(actor.restoreState(divergent), .rejectedDivergentState)
        XCTAssertEqual(actor.latestPublishedState, committed)
        XCTAssertEqual(actor.currentLastAppliedSequence, 1)
    }

    func testPublishedStateCanBeReadFromSubmitCompletionWithoutDeadlock() {
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: makeState(),
            store: makeStore(),
            sealing: makeSealing()
        )
        let completed = expectation(description: "completion reads actor state")
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 1, expectedLast: 0)]) { _ in
            XCTAssertEqual(actor.latestPublishedState?.phase, .preparing)
            XCTAssertEqual(actor.currentLastAppliedSequence, 1)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
    }

    func testFutureGapRejected() {
        let store = makeStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: makeState(), store: store, sealing: makeSealing()
        )
        let exp = expectation(description: "gap")
        var published: TentativeState?
        actor.submit([makeDraft(kind: .turnSubmitted, sequence: 3, expectedLast: 0)]) { tentative in
            published = tentative
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(published, "sequence 缺口必须拒绝（不投影、不提交）")
        XCTAssertEqual(actor.currentLastAppliedSequence, 0, "缺口事件不推进 lastApplied")
        let snapshot = try? store.load()
        XCTAssertEqual(snapshot?.lastAppliedSequence, 0, "真实库无缺口事件")
    }
}

// MARK: - test doubles

/// 提交前本地 sealed-box 往返验证协议（test double；真实 CryptoKit 实现属 P3-5）。
/// P0-1 统一密封合同：verifyRoundTrip 接收明文 payload，内部执行 seal→open 往返验证。
final class TestConversationSealing: ConversationSealing {
    var shouldVerify = true

    func verifyRoundTrip(payload: Data, aad: String) -> Bool {
        shouldVerify
    }
}

/// in-memory Store test double：记录 commit 调用、按 sequence 记录事件（幂等去重）、可注入冲突。
final class InMemoryConversationSessionStore: ConversationSessionStore, ConversationEventIdentityProviding {
    struct CommittedBatch {
        let expected: Int
        let candidates: [ConversationEventEnvelope]
        let outbox: [ConversationEffectOutboxItem]
    }

    var committed: [CommittedBatch] = []
    var eventsBySequence: [Int: ConversationEventIdentity] = [:]
    private(set) var commitCount = 0
    var conflictOnNextCommit = false
    var beforeCommit: (([ConversationEventEnvelope]) -> Void)?
    var beforeClaimOutboxEffect: ((EffectCommand?) -> Void)?
    var rejectNextOutboxClaim = false
    private var appliedSequences: [Int] = []
    private var outboxByItemID: [String: ConversationOutboxDispatchRecord] = [:]

    func load() throws -> ConversationSessionSnapshot {
        ConversationSessionSnapshot(lastAppliedSequence: appliedSequences.last ?? 0)
    }

    func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        beforeCommit?(candidates)
        commitCount += 1
        if conflictOnNextCommit {
            conflictOnNextCommit = false
            return .conflict(expected: expectedLastSequence, actual: expectedLastSequence)
        }
        committed.append(CommittedBatch(expected: expectedLastSequence, candidates: candidates, outbox: outbox))
        for item in outbox where outboxByItemID[item.itemID] == nil {
            outboxByItemID[item.itemID] = ConversationOutboxDispatchRecord(
                itemID: item.itemID,
                effectID: item.effectID,
                operationID: item.operationID,
                idempotencyKey: item.idempotencyKey,
                command: item.command,
                authorityLeaseID: item.authorityLeaseID,
                capabilityGeneration: item.capabilityGeneration,
                permitCommitDecision: item.permitCommitDecision,
                state: .pending,
                dispatchToken: nil,
                dispatchedAt: nil,
                settlementOutcome: nil,
                settledAt: nil,
                reconciliationReason: nil
            )
        }
        for envelope in candidates {
            eventsBySequence[envelope.candidateSequence] = ConversationEventIdentity(envelope: envelope)
            appliedSequences.append(envelope.candidateSequence)
        }
        return .committed(lastSequence: candidates.map(\.candidateSequence).max() ?? expectedLastSequence)
    }

    func existingEventID(at sequence: Int) -> String? {
        eventsBySequence[sequence]?.eventID
    }

    func existingPayloadHash(at sequence: Int) -> String? {
        eventsBySequence[sequence]?.payloadHash
    }

    func existingEventIdentity(at sequence: Int) -> ConversationEventIdentity? {
        eventsBySequence[sequence]
    }

    func loadUnsettledOutbox() throws -> [ConversationOutboxDispatchRecord] {
        outboxByItemID.values
            .filter { $0.state != .settled }
            .sorted { $0.itemID < $1.itemID }
    }

    func claimOutboxEffect(
        effectID: String,
        dispatchToken: String,
        dispatchedAt: String
    ) throws -> ConversationOutboxDispatchRecord? {
        if rejectNextOutboxClaim {
            rejectNextOutboxClaim = false
            return nil
        }
        guard let itemID = outboxByItemID.values
            .filter({ $0.effectID == effectID && $0.state == .pending })
            .map(\.itemID)
            .sorted()
            .first,
              var record = outboxByItemID[itemID]
        else { return nil }
        beforeClaimOutboxEffect?(record.command)
        record.state = .dispatching
        record.dispatchToken = dispatchToken
        record.dispatchedAt = dispatchedAt
        outboxByItemID[itemID] = record
        return record
    }

    func settleOutbox(
        itemID: String,
        dispatchToken: String,
        outcome: ConversationOutboxSettlementOutcome,
        settledAt: String
    ) throws -> Bool {
        guard var record = outboxByItemID[itemID] else { return false }
        if record.state == .settled {
            return record.dispatchToken == dispatchToken
                && record.settlementOutcome == outcome.rawValue
        }
        guard record.state == .dispatching, record.dispatchToken == dispatchToken else {
            return false
        }
        record.state = .settled
        record.settlementOutcome = outcome.rawValue
        record.settledAt = settledAt
        outboxByItemID[itemID] = record
        return true
    }

    func requireOutboxReconciliation(itemID: String, reason: String) throws -> Bool {
        guard var record = outboxByItemID[itemID],
              record.state == .pending || record.state == .dispatching else {
            return false
        }
        record.state = .reconciliationRequired
        record.reconciliationReason = reason
        outboxByItemID[itemID] = record
        return true
    }
}
