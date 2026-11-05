import Foundation

// MARK: - ConversationSessionActor（单写入）

/// 会话唯一写入者：串行化并发 intent，逐批走
/// `EventDraft → 序列校验 → 纯 Reducer 预演 → 本地 sealed-box 验证 → Store 单事务提交 → 发布 TentativeState`。
///
/// 不变量：
/// - 同一时刻只有一个底层提交者（DispatchQueue 串行）；
/// - `expectedLastSequence` 从 `lastApplied` 推导，candidate range 必须连续；
/// - 批提交只有事务成功才发布 `TentativeState`；冲突时丢弃本批预演并从认证事件恢复已提交状态；
///   验证失败/非法边不发布、不推进；
/// - 重复投递幂等忽略（返回已发布状态，不重复 commit）；sequence 缺口拒绝。
public final class ConversationSessionActor: @unchecked Sendable {
    public let sessionID: String

    private let store: ConversationSessionStore
    private let sealing: ConversationSealing
    private let queue: DispatchQueue
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()

    private var lastApplied: Int
    private var publishedState: ConversationSessionState
    /// Process-local owner of the external runtime for the current Attempt.
    /// The weak reference prevents the shared Actor from retaining a window.
    private weak var runtimeOwner: AnyObject?
    private var runtimeOwnerAttemptID: String?

    /// 最近一次成功发布的状态（测试/投影可读）。读取也经过会话串行队列，
    /// 避免窗口主线程与提交队列并发访问同一值。
    public var latestPublishedState: ConversationSessionState? {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return publishedState
        }
        return queue.sync { publishedState }
    }

    /// 状态订阅者。Actor 可被多个窗口共享，因此必须多播，不能由后装配的窗口覆盖前一个回调。
    private var stateObservers: [UUID: (ConversationSessionState) -> Void] = [:]

    public init(
        sessionID: String,
        initialState: ConversationSessionState,
        store: ConversationSessionStore,
        sealing: ConversationSealing,
        queueLabel: String? = nil
    ) {
        self.sessionID = sessionID
        self.store = store
        self.sealing = sealing
        self.queue = DispatchQueue(label: queueLabel ?? "stacio.conversation.actor.\(sessionID)")
        self.lastApplied = initialState.lastAppliedSequence
        self.publishedState = initialState
        self.queue.setSpecific(key: queueSpecificKey, value: 1)
    }

    public var currentLastAppliedSequence: Int {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return lastApplied
        }
        return queue.sync { lastApplied }
    }

    /// Claims responsibility for dispatching or reconciling one live Attempt.
    /// Other windows remain interactive observers, but must not treat the same
    /// process-local Runtime as relaunch recovery work.
    public func claimRuntimeOwnership(attemptID: String, owner: AnyObject) -> Bool {
        withActorQueue {
            if let currentOwner = runtimeOwner {
                return currentOwner === owner && runtimeOwnerAttemptID == attemptID
            }
            runtimeOwner = owner
            runtimeOwnerAttemptID = attemptID
            return true
        }
    }

    public func releaseRuntimeOwnership(attemptID: String, owner: AnyObject) {
        withActorQueue {
            guard runtimeOwner === owner,
                  runtimeOwnerAttemptID == attemptID else { return }
            runtimeOwner = nil
            runtimeOwnerAttemptID = nil
        }
    }

    public func hasLiveRuntimeOwner(attemptID: String) -> Bool {
        withActorQueue {
            guard runtimeOwnerAttemptID == attemptID else { return false }
            if runtimeOwner == nil {
                runtimeOwnerAttemptID = nil
                return false
            }
            return true
        }
    }

    // MARK: - P0-5：重启恢复后同步 lastApplied

    /// Conditionally publishes an authenticated replay projection. The sequence
    /// comparison and assignment happen on the same Actor queue so a concurrent
    /// window cannot commit between a caller-side check and this write.
    @discardableResult
    public func restoreState(_ state: ConversationSessionState) -> RestoreOutcome {
        withActorQueue {
            if state.lastAppliedSequence < lastApplied {
                return .rejectedNewerState
            }
            if state.lastAppliedSequence == lastApplied {
                return state == publishedState ? .alreadyCurrent : .rejectedDivergentState
            }
            lastApplied = state.lastAppliedSequence
            publishedState = state
            return .applied
        }
    }

    /// 提交一个或多个 EventDraft（同一 intent 的原子批）。
    /// `completion` 收到成功发布的 `TentativeState`；被拒绝/冲突/验证失败时为 nil（可区分 reason）。
    public func submit(
        _ drafts: [EventDraft],
        completion: @escaping (TentativeState?) -> Void
    ) {
        queue.async { [self] in
            switch self.process(drafts: drafts) {
            case .committed(let state):
                completion(TentativeState(state: state))
            case .rejected:
                completion(nil)
            }
        }
    }

    /// 非阻塞结构化提交。加密与 Rust/SQLite 工作均在会话串行队列执行，调用方可安全地从主线程 await。
    public func submit(_ drafts: [EventDraft]) async -> SubmitOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: self.process(drafts: drafts))
            }
        }
    }

    // MARK: - Durable effect outbox

    public func loadUnsettledOutbox() async throws -> [ConversationOutboxDispatchRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try store.loadUnsettledOutbox())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func claimOutboxEffect(
        effectID: String,
        dispatchToken: String,
        dispatchedAt: String
    ) async throws -> ConversationOutboxDispatchRecord? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try store.claimOutboxEffect(
                        effectID: effectID,
                        dispatchToken: dispatchToken,
                        dispatchedAt: dispatchedAt
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func settleOutbox(
        itemID: String,
        dispatchToken: String,
        outcome: ConversationOutboxSettlementOutcome,
        settledAt: String
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try store.settleOutbox(
                        itemID: itemID,
                        dispatchToken: dispatchToken,
                        outcome: outcome,
                        settledAt: settledAt
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func requireOutboxReconciliation(itemID: String, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try store.requireOutboxReconciliation(
                        itemID: itemID,
                        reason: reason
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - P0-3：可等待的结构化同步提交

    /// 提交结果（结构化；P0-3）。
    public enum SubmitOutcome: Equatable {
        case committed(state: ConversationSessionState)
        case rejected(reason: SubmitRejection)
    }

    /// 提交被拒绝原因（结构化；P0-3）。
    public enum SubmitRejection: Equatable {
        case sealingFailed
        case sequenceGap
        case invalidTransition(reason: String)
        case storageFailure
        case conflict
    }

    public enum RestoreOutcome: Equatable {
        case applied
        case alreadyCurrent
        case rejectedNewerState
        case rejectedDivergentState
    }

    /// 同步提交仅保留给测试与非 UI 调用方。生产 Bridge 必须使用异步 `submit(_:)`。
    public func submitSync(_ drafts: [EventDraft]) -> SubmitOutcome {
        queue.sync { self.process(drafts: drafts) }
    }

    /// 注册状态订阅。回调始终在主线程调用。
    @discardableResult
    public func addStateObserver(_ observer: @escaping (ConversationSessionState) -> Void) -> UUID {
        let token = UUID()
        queue.sync {
            stateObservers[token] = observer
        }
        return token
    }

    public func removeStateObserver(_ token: UUID) {
        _ = queue.sync {
            stateObservers.removeValue(forKey: token)
        }
    }

    // MARK: - 处理（仅在串行队列内调用）

    private func process(drafts: [EventDraft]) -> SubmitOutcome {
        guard let first = drafts.first else {
            return .rejected(reason: .sequenceGap)
        }
        guard drafts.allSatisfy({ $0.envelope.conversationID == sessionID }) else {
            return .rejected(reason: .invalidTransition(reason: "conversation ID mismatch"))
        }
        // Candidate sequences must describe one contiguous batch, even when the
        // batch is being replayed idempotently. A retry may carry either the
        // original expected sequence or the caller's current last sequence.
        let contiguous = drafts.enumerated().allSatisfy { index, draft in
            draft.envelope.candidateSequence == first.envelope.candidateSequence + index
        }
        guard contiguous else {
            return .rejected(reason: .sequenceGap)
        }

        // 幂等预检查：整批全部命中（同 eventID + 同 hash）才短路返回已发布状态。
        // （reducer 不允许重放已应用事件；Rust 层幂等判定兜底。）
        // 其他情形（expected mismatch / 同 sequence 不同事件）放行给 Rust 持久层：
        // - expected mismatch → ExpectedMismatch → facade 映射 conflict → 本 Actor 重读重试
        // - 同 sequence 不同事件/hash → CorruptionDetected（只读隔离）
        let wholeBatchIdempotent: Bool
        if let identityStore = store as? ConversationEventIdentityProviding {
            // Production stores must authenticate all reducer-visible identity
            // fields before taking the shortcut. ID/hash-only equality is not
            // enough to prove that an event is the same command.
            wholeBatchIdempotent = drafts.allSatisfy { draft in
                identityStore.existingEventIdentity(at: draft.envelope.candidateSequence)?
                    .matches(draft.envelope) == true
            }
        } else {
            // Preserve compatibility for legacy test doubles and V1 adapters;
            // their commit implementation remains the final integrity gate.
            wholeBatchIdempotent = drafts.allSatisfy { draft in
                guard let existing = store.existingEventID(at: draft.envelope.candidateSequence),
                      existing == draft.envelope.eventID,
                      store.existingPayloadHash(at: draft.envelope.candidateSequence) == draft.envelope.payloadHash
                else {
                    return false
                }
                return true
            }
        }
        if wholeBatchIdempotent {
            let highestExistingSequence = drafts.map(\.envelope.candidateSequence).max() ?? lastApplied
            if highestExistingSequence > lastApplied {
                guard recoverPublishedStateAfterConflict(),
                      lastApplied >= highestExistingSequence else {
                    return .rejected(reason: .conflict)
                }
            }
            return .committed(state: publishedState)
        }

        let expected = lastApplied
        guard first.expectedLastSequence == expected else {
            // 缺口/乱序：拒绝整批（持久层负责 buffering；Phase 2 直接拒绝）
            return .rejected(reason: .sequenceGap)
        }

        // 1) 纯 Reducer 逐条预演（同一批内状态前进；任一非法边丢弃整批）
        var tentativeState = publishedState
        var effectsAccumulator: [EffectCommand] = []
        for draft in drafts {
            guard draft.expectedLastSequence == tentativeState.lastAppliedSequence else {
                return .rejected(reason: .sequenceGap)
            }
            let (tentative, effects) = ConversationReducer.reduce(state: tentativeState, draft: draft)
            guard tentative.isValid else {
                let reason = tentative.invalidTransitions.first?.reason ?? "invalid transition"
                return .rejected(reason: .invalidTransition(reason: reason))
            }
            tentativeState = tentative.state
            effectsAccumulator.append(contentsOf: effects)
        }

        // 3) 提交前本地 sealed-box 往返验证（canonical AAD）
        //    统一密封合同（P0-1）：sealing.verifyRoundTrip 接收明文 payload，
        //    内部执行 seal→open 往返验证加密是否工作正常（不是验证明文本身）。
        //    失败 → fail closed：不提交、不发布、不产生网络副作用。
        for draft in drafts {
            let aad = canonicalAAD(for: draft.envelope)
            guard sealing.verifyRoundTrip(payload: draft.envelope.payload, aad: aad) else {
                return .rejected(reason: .sealingFailed)
            }
        }

        // 4) outbox（纯计算；effect 由外部派发）
        let outbox = ConversationEffectOutboxFactory.make(
            commands: effectsAccumulator,
            sessionID: sessionID,
            turnID: drafts.lazy.compactMap(\.envelope.turnID).first ?? "",
            attemptID: drafts.lazy.compactMap(\.envelope.attemptID).first ?? ""
        )

        // 5) Store 单事务提交
        do {
            let outcome = try store.commit(
                expectedLastSequence: expected,
                candidates: drafts.map(\.envelope),
                projections: [:],
                outbox: outbox
            )
            switch outcome {
            case let .committed(lastSequence):
                lastApplied = lastSequence
                publishedState = tentativeState
                notifyStateChange(tentativeState)
                return .committed(state: tentativeState)
            case .conflict:
                // Another writer committed first. Rebuild the full projection
                // from authenticated events; advancing only the sequence would
                // make every later reduction start from stale state.
                _ = recoverPublishedStateAfterConflict()
                return .rejected(reason: .conflict)
            case .storageFailure:
                return .rejected(reason: .storageFailure)
            }
        } catch {
            return .rejected(reason: .storageFailure)
        }
    }

    private func recoverPublishedStateAfterConflict() -> Bool {
        do {
            let snapshot = try store.load()
            if let state = snapshot.state,
               state.lastAppliedSequence == snapshot.lastAppliedSequence {
                publishRecoveredState(state)
                return true
            }

            guard let eventLoader = store as? ConversationEventLoading else {
                return false
            }
            let pending = try eventLoader.loadEvents()
                .filter { $0.candidateSequence > lastApplied }
                .sorted { $0.candidateSequence < $1.candidateSequence }
            guard pending.isEmpty == false else {
                return snapshot.lastAppliedSequence == lastApplied
            }

            var recovered = publishedState
            var expected = lastApplied
            for envelope in pending {
                guard envelope.candidateSequence == expected + 1 else {
                    return false
                }
                let draft = EventDraft(
                    envelope: envelope,
                    expectedLastSequence: expected
                )
                let (tentative, _) = ConversationReducer.reduce(state: recovered, draft: draft)
                guard tentative.isValid else { return false }
                recovered = tentative.state
                expected = envelope.candidateSequence
            }
            guard expected == snapshot.lastAppliedSequence else { return false }
            publishRecoveredState(recovered)
            return true
        } catch {
            return false
        }
    }

    private func publishRecoveredState(_ state: ConversationSessionState) {
        lastApplied = state.lastAppliedSequence
        publishedState = state
        notifyStateChange(state)
    }

    /// canonical AAD（规格 §15.1：record type + ID + candidate sequence + schema version；不接受调用方另传 AAD）
    public func canonicalAAD(for envelope: ConversationEventEnvelope) -> String {
        ConversationEncryption.canonicalAAD(
            recordType: "conversationEvent",
            recordID: envelope.eventID,
            candidateSequence: envelope.candidateSequence,
            schemaVersion: 1
        )
    }

    /// 主线程派发状态变更通知（不在串行队列内同步调用，避免递归提交/死锁）。
    private func notifyStateChange(_ state: ConversationSessionState) {
        let observers = Array(stateObservers.values)
        guard observers.isEmpty == false else { return }
        DispatchQueue.main.async {
            observers.forEach { $0(state) }
        }
    }

    private func withActorQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }
}
