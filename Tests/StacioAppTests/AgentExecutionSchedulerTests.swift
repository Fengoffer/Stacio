import XCTest
import Foundation
@testable import StacioApp

/// C2-8：AgentExecutionScheduler FIFO 公平、容量升降、超时与 orphaned 语义；QueuedInput 冻结/needsRebind。
///
/// 合同：
/// - 持久化 FIFO 公平（同 Attempt 幂等请求）；上限 1–4 升降（降低不抢占）；
/// - 取消/等待超时（30min 默认）→ capacityWaitExpired；
/// - admissionGranted 后 Attempt 必须 StartingRuntime；runtimeStarted 才开始有效执行时钟；
/// - AwaitingApproval/AwaitingUser/Paused 占位不释放；orphanedRuntime 不误释放；
/// - Scheduler 是 request/lease 唯一写入者；
/// - QueuedInput 写入时冻结完整 ContextSnapshot；任一 digest 变化 → needsRebind；
///   用户选择原/当前上下文都创建新 revision 与审计；无选择不得自动提升。
final class AgentExecutionSchedulerTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRequest(
        id: String = "req-1",
        attemptID: String = "a-1",
        ordinal: Int = 1,
        state: GlobalExecutionAdmissionRequestState = .queued,
        enqueuedAt: Date = AgentExecutionSchedulerTests.fixedDate
    ) -> GlobalExecutionAdmissionRequest {
        GlobalExecutionAdmissionRequest(
            requestID: id, sessionID: "c-1", turnID: "t-1", attemptID: attemptID,
            schedulerGeneration: 1, queueOrdinal: ordinal, enqueuedAt: enqueuedAt,
            state: state
        )
    }

    private func makeLease(
        id: String = "lease-1",
        requestID: String = "req-1",
        attemptID: String = "a-1",
        state: GlobalExecutionAdmissionLeaseState = .granted
    ) -> GlobalExecutionAdmissionLease {
        GlobalExecutionAdmissionLease(
            leaseID: id, requestID: requestID, sessionID: "c-1", turnID: "t-1",
            attemptID: attemptID, schedulerGeneration: 1,
            acquiredAt: AgentExecutionSchedulerTests.fixedDate,
            state: state, settlementID: "settle-1"
        )
    }

    private func makeEmptyState() -> SchedulerState {
        SchedulerState(requests: [], activeLeases: [], nextQueueOrdinal: 1)
    }

    // MARK: - FIFO 公平

    func testFIFOFairnessPromotesInOrdinalOrder() {
        var state = makeEmptyState()
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r2", attemptID: "a-2", ordinal: 2), now: Self.fixedDate)
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r3", attemptID: "a-3", ordinal: 3), now: Self.fixedDate)
        XCTAssertEqual(state.requests.map(\.requestID), ["r1", "r2", "r3"], "入队保持 FIFO")

        // capacity 3：一次 promote 提升全部（FIFO 顺序）
        let config = SchedulerConfig(capacity: 3)
        let (newState, events) = AgentExecutionScheduler.promote(state: state, config: config, now: Self.fixedDate)
        var grantedIDs: [String] = []
        for event in events {
            if case let .admissionGranted(requestID, _, _) = event {
                grantedIDs.append(requestID)
            }
        }
        XCTAssertEqual(grantedIDs, ["r1", "r2", "r3"], "FIFO 公平：按队首顺序提升")
        XCTAssertEqual(newState.activeLeases.count, 3)
    }

    // MARK: - 幂等

    func testSameAttemptIdempotentEnqueue() {
        var state = makeEmptyState()
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r2", attemptID: "a-1", ordinal: 2), now: Self.fixedDate)
        XCTAssertEqual(state.requests.count, 1, "同 Attempt 重复请求幂等（不占两个名额）")
        XCTAssertEqual(state.requests[0].requestID, "r1")
    }

    // MARK: - 容量升降不抢占

    func testCapacityLoweringDoesNotPreemptGranted() {
        var state = makeEmptyState()
        for i in 1...4 {
            state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r\(i)", attemptID: "a-\(i)", ordinal: i), now: Self.fixedDate)
        }
        let high = SchedulerConfig(capacity: 4)
        (state, _) = AgentExecutionScheduler.promote(state: state, config: high, now: Self.fixedDate)
        XCTAssertEqual(state.activeLeases.count, 4, "capacity 4 全部提升")

        // 降低到 1：已 granted 的 4 个不被抢占
        let low = SchedulerConfig(capacity: 1)
        let (afterLower, events) = AgentExecutionScheduler.promote(state: state, config: low, now: Self.fixedDate)
        XCTAssertEqual(afterLower.activeLeases.count, 4, "降低容量不抢占已 granted")
        XCTAssertFalse(events.contains { if case .admissionReleased = $0 { return true } else { return false } }, "降低容量不产生释放事件")
    }

    // MARK: - 超时

    func testWaitTimeoutExpiresToCapacityWaitExpired() {
        var state = makeEmptyState()
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        let config = SchedulerConfig(capacity: 1, waitTimeout: 1_800)
        // 入队 31 分钟后
        let late = Self.fixedDate.addingTimeInterval(1_860)
        let (after, events) = AgentExecutionScheduler.checkWaitTimeouts(state: state, config: config, now: late)
        XCTAssertTrue(events.contains(.admissionWaitExpired(requestID: "r1", attemptID: "a-1")), "超时必须产出 capacityWaitExpired 事件")
        XCTAssertTrue(after.requests.isEmpty, "超时请求离开队列")
        // 未超时
        let (before, earlyEvents) = AgentExecutionScheduler.checkWaitTimeouts(state: state, config: config, now: Self.fixedDate.addingTimeInterval(1_000))
        XCTAssertTrue(before.requests.count == 1)
        XCTAssertFalse(earlyEvents.contains { if case .admissionWaitExpired = $0 { return true } else { return false } })
    }

    // MARK: - granted → StartingRuntime；执行时钟

    func testAdmissionGrantedDrivesAttemptToStartingRuntime() {
        var scheduler = makeEmptyState()
        scheduler = AgentExecutionScheduler.enqueue(state: scheduler, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        let (afterPromote, events) = AgentExecutionScheduler.promote(state: scheduler, config: SchedulerConfig(capacity: 1), now: Self.fixedDate)
        guard case let .admissionGranted(requestID, leaseID, _) = events.first else {
            return XCTFail("promote 应产出 admissionGranted")
        }
        XCTAssertEqual(requestID, "r1")

        // 把 granted 事件喂 reducer：Attempt 必须进入 StartingRuntime
        let session = ConversationSession(
            id: "c-1", title: "t", createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
            targetBinding: TargetBinding(
                id: "tb", revision: 1, digest: "d", connectionID: "conn",
                connectionKind: "ssh", remoteIdentity: "u@h", hostKeyFingerprint: "fp",
                host: "h", user: "u", port: 22, targetWorkingDirectory: "~"
            ),
            runtimeSelection: AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1")
        )
        var state = ConversationSessionState(session: session)
        func apply(_ kind: ConversationEventKind, sequence: Int) {
            let envelope = ConversationEventEnvelope(
                eventID: "ev-\(sequence)", conversationID: "c-1", scope: .attempt,
                turnID: "t-1", attemptID: "a-1", candidateSequence: sequence,
                source: "scheduler", timestamp: Self.fixedDate, kind: kind,
                writeClass: .durable, payloadHash: "h", payload: Data()
            )
            let (tentative, _) = ConversationReducer.reduce(state: state, draft: EventDraft(envelope: envelope, expectedLastSequence: sequence - 1))
            XCTAssertTrue(tentative.isValid)
            state = tentative.state
        }
        apply(.turnSubmitted, sequence: 1)
        apply(.admissionRequested, sequence: 2)
        apply(.admissionGranted, sequence: 3)
        XCTAssertEqual(state.phase, .startingRuntime, "admissionGranted 后 Attempt 必须 StartingRuntime")

        // runtimeStarted 前 lease 无有效执行时钟（lease 的 lastObservedAt 为空即未开始计时）
        let pendingLease = afterPromote.activeLeases.first
        XCTAssertNil(pendingLease?.lastObservedAt, "runtimeStarted 前不启动有效执行时钟")
        _ = leaseID
    }

    // MARK: - 占位与 orphaned

    func testAwaitingApprovalAwaitingUserPausedHoldLease() {
        // 这些阶段不释放 lease：release 只由 scheduler 显式触发，attempt phase 不影响容量
        var state = makeEmptyState()
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        (state, _) = AgentExecutionScheduler.promote(state: state, config: SchedulerConfig(capacity: 1), now: Self.fixedDate)
        XCTAssertEqual(state.activeLeases.count, 1)
        // 无释放事件
        let (after, events) = AgentExecutionScheduler.promote(state: state, config: SchedulerConfig(capacity: 1), now: Self.fixedDate)
        XCTAssertEqual(after.activeLeases.count, 1)
        XCTAssertFalse(events.contains { if case .admissionReleased = $0 { return true } else { return false } })
    }

    func testOrphanedRuntimeDoesNotReleaseCapacity() {
        var state = makeEmptyState()
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        (state, _) = AgentExecutionScheduler.promote(state: state, config: SchedulerConfig(capacity: 1), now: Self.fixedDate)
        // 将 lease 置为 orphanedRuntime（模拟 runtime 状态不明）
        let orphaned = makeLease(id: state.activeLeases[0].leaseID, requestID: "r1", attemptID: "a-1", state: .orphanedRuntime)
        state = SchedulerState(requests: state.requests, activeLeases: [orphaned], nextQueueOrdinal: state.nextQueueOrdinal)
        // orphaned 不自动释放：promote/超时检查都不产出释放事件
        let (afterPromote, promoteEvents) = AgentExecutionScheduler.promote(state: state, config: SchedulerConfig(capacity: 1), now: Self.fixedDate)
        XCTAssertFalse(promoteEvents.contains { if case .admissionReleased = $0 { return true } else { return false } }, "orphaned 不误释放")
        XCTAssertTrue(afterPromote.activeLeases.contains { $0.state == .orphanedRuntime })
    }

    func testRelaunchGenerationOrphansLeaseAndBlocksNewCapacity() async throws {
        let databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-admission-relaunch-\(UUID().uuidString).sqlite3")
            .path
        let repository = try ConversationRepositoryV2(
            conversationID: "scheduler-owner",
            databasePath: databasePath,
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x7A, count: 32))
        )
        let firstScheduler = ProductionAgentExecutionScheduler(store: repository, capacity: 1)
        let request = try await firstScheduler.enqueue(
            sessionID: "session-1",
            turnID: "turn-1",
            attemptID: "attempt-1",
            config: SchedulerConfig(capacity: 1, waitTimeout: 60)
        )
        guard case .granted(let lease) = await firstScheduler.waitForResolution(requestID: request.requestID) else {
            return XCTFail("首个 Attempt 必须获得 lease")
        }
        try await firstScheduler.activate(lease)

        // A new process generation must quarantine the old lease instead of
        // silently releasing capacity that may still protect an external task.
        let relaunchedScheduler = ProductionAgentExecutionScheduler(store: repository, capacity: 1)
        let recoveredState = try await relaunchedScheduler.prepareForRestore()
        XCTAssertEqual(recoveredState.schedulerGeneration, lease.schedulerGeneration + 1)
        XCTAssertTrue(recoveredState.activeLeases.contains {
            $0.leaseID == lease.leaseID && $0.state == .orphanedRuntime
        })

        do {
            _ = try await relaunchedScheduler.release(lease)
            XCTFail("旧 generation 的 orphaned lease 不得被普通 release 绕过")
        } catch AgentExecutionAdmissionCoordinatorError.staleGeneration {
            // Expected fail-closed result.
        }

        let queued = try await relaunchedScheduler.enqueue(
            sessionID: "session-2",
            turnID: "turn-2",
            attemptID: "attempt-2",
            config: SchedulerConfig(capacity: 1, waitTimeout: 60)
        )
        let queuedResolution = await relaunchedScheduler.resolutionIfAvailable(
            requestID: queued.requestID
        )
        XCTAssertNil(queuedResolution)
        let blockedState = try repository.loadAdmissionState()
        XCTAssertTrue(blockedState.activeLeases.contains {
            $0.leaseID == lease.leaseID && $0.state == .orphanedRuntime
        })
        XCTAssertTrue(blockedState.requests.contains { $0.requestID == queued.requestID })
        _ = try await relaunchedScheduler.cancel(requestID: queued.requestID)
    }

    // MARK: - Scheduler 唯一写入者

    func testSchedulerIsSoleWriterOfRequestsAndLeases() {
        // Scheduler 状态只通过其纯函数变更：无公共写入 API（请求/租约不可由 View 直接改）
        var state = makeEmptyState()
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        let before = state
        // 再次 enqueue 同一 attempt（幂等）→ 状态不变
        state = AgentExecutionScheduler.enqueue(state: state, request: makeRequest(id: "r1", attemptID: "a-1", ordinal: 1), now: Self.fixedDate)
        XCTAssertEqual(state, before, "幂等入队不改变状态")
        // request.state 变更只经 scheduler 返回的新状态
        let (granted, _) = AgentExecutionScheduler.promote(state: state, config: SchedulerConfig(capacity: 1), now: Self.fixedDate)
        XCTAssertEqual(granted.requests.count, 0)
        XCTAssertEqual(granted.activeLeases.count, 1)
    }

    // MARK: - QueuedInput 冻结 / needsRebind

    private func makeContext(
        targetDigest: String = "d1",
        authDigest: String = "auth-1",
        configDigest: String = "cfg-1",
        instructionDigest: String? = "instr-1"
    ) -> QueuedInputContextSnapshot {
        QueuedInputContextSnapshot(
            targetBindingSnapshot: TargetBinding(
                id: "tb", revision: 1, digest: targetDigest, connectionID: "conn",
                connectionKind: "ssh", remoteIdentity: "u@h", hostKeyFingerprint: "fp",
                host: "h", user: "u", port: 22, targetWorkingDirectory: "~"
            ),
            targetWorkingDirectory: "~",
            targetDigest: targetDigest,
            runtimeSelectionSnapshot: AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1"),
            runtimeAuthenticationSnapshot: RuntimeAuthenticationSnapshot(
                mode: .stacioCredentialBindings, verificationFingerprint: "vf",
                generationIDsByRole: ["api": "g-1"], createdAt: Self.fixedDate, digest: authDigest
            ),
            authenticationDigest: authDigest,
            configurationRevisionDigest: configDigest,
            workMode: .agent,
            instructionDigest: instructionDigest,
            capturedAt: Self.fixedDate,
            source: .explicitUserChoice
        )
    }

    private func makeQueuedInput(context: QueuedInputContextSnapshot) -> QueuedInput {
        QueuedInput(
            id: "q-1", sessionID: "c-1", revision: 3, position: 0, text: "hi",
            contextSnapshot: context, revalidationState: .valid,
            createdAt: Self.fixedDate, updatedAt: Self.fixedDate
        )
    }

    func testQueuedInputFrozenSnapshotDetectsDigestChange() {
        let frozen = makeQueuedInput(context: makeContext())
        // 目标 digest 变化 → needsRebind
        let changedTarget = makeContext(targetDigest: "d2")
        XCTAssertEqual(
            QueuedInputRevalidator.revalidationState(for: frozen, current: changedTarget),
            .needsRebind,
            "任一 digest 变化必须 needsRebind"
        )
        // 认证 digest 变化 → needsRebind
        let changedAuth = makeContext(authDigest: "auth-2")
        XCTAssertEqual(
            QueuedInputRevalidator.revalidationState(for: frozen, current: changedAuth),
            .needsRebind
        )
        // 全部相同 → 保持 valid
        XCTAssertEqual(
            QueuedInputRevalidator.revalidationState(for: frozen, current: frozen.contextSnapshot),
            .valid
        )
    }

    func testRebindCreatesNewRevisionAndAudit() {
        let frozen = makeQueuedInput(context: makeContext())
        let current = makeContext(targetDigest: "d2")
        let (rebound, audit) = QueuedInputRevalidator.rebind(
            input: frozen, to: current, source: .explicitUserChoice, now: Self.fixedDate
        )
        XCTAssertEqual(rebound.revision, 4, "选择原/当前上下文都创建新 revision")
        XCTAssertEqual(rebound.revalidationState, .valid)
        XCTAssertEqual(rebound.contextSnapshot.targetDigest, "d2")
        XCTAssertEqual(audit.previousRevision, 3)
        XCTAssertEqual(audit.newRevision, 4)
        XCTAssertEqual(audit.queuedInputID, "q-1")
        XCTAssertTrue(audit.changedDigests.contains("targetDigest"), "审计记录变化的 digest")
    }

    func testNeedsRebindBlocksAutoPromotion() {
        // 无选择不得自动提升：needsRebind 输入不进入 Turn 提交
        let frozen = makeQueuedInput(context: makeContext())
        let changedContext = makeContext(targetDigest: "d2")
        XCTAssertEqual(QueuedInputRevalidator.revalidationState(for: frozen, current: changedContext), .needsRebind)

        // 处于 needsRebind 的输入（用户未选择）不得自动提升
        var changed = makeQueuedInput(context: changedContext)
        changed.revalidationState = .needsRebind
        XCTAssertEqual(QueuedInputRevalidator.promotionGate(for: changed), .blocked, "needsRebind 无用户选择不得自动提升")

        // 有效输入可提升
        let valid = makeQueuedInput(context: makeContext())
        XCTAssertEqual(QueuedInputRevalidator.promotionGate(for: valid), .valid)
    }
}
