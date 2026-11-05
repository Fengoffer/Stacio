import Foundation

// MARK: - 调度配置

public struct SchedulerConfig: Equatable, Sendable {
    /// 全局并发上限（1–4）
    public var capacity: Int
    /// 排队等待超时（默认 30min；超时 → capacityWaitExpired）
    public var waitTimeout: TimeInterval

    public init(capacity: Int = 1, waitTimeout: TimeInterval = 1_800) {
        self.capacity = min(max(capacity, 1), 4)
        self.waitTimeout = waitTimeout
    }
}

// MARK: - Scheduler 状态（唯一写入者：AgentExecutionScheduler）

public struct SchedulerState: Equatable, Sendable {
    public var schedulerGeneration: Int
    public var requests: [GlobalExecutionAdmissionRequest]
    public var activeLeases: [GlobalExecutionAdmissionLease]
    public var nextQueueOrdinal: Int

    public init(
        schedulerGeneration: Int = 0,
        requests: [GlobalExecutionAdmissionRequest] = [],
        activeLeases: [GlobalExecutionAdmissionLease] = [],
        nextQueueOrdinal: Int = 1
    ) {
        self.schedulerGeneration = schedulerGeneration
        self.requests = requests
        self.activeLeases = activeLeases
        self.nextQueueOrdinal = nextQueueOrdinal
    }
}

// MARK: - Scheduler 事件（喂给 Reducer / outbox）

public enum SchedulerEvent: Equatable, Sendable {
    case requestAccepted(requestID: String, ordinal: Int)
    case admissionGranted(requestID: String, leaseID: String, attemptID: String)
    case admissionCancelled(requestID: String)
    case admissionWaitExpired(requestID: String, attemptID: String)
    case admissionReleased(leaseID: String, capacityReleased: Bool)
}

// MARK: - AgentExecutionScheduler（纯函数 FIFO；无 I/O、无时钟）

/// 全局执行 Admission 的唯一写入者。View/会话不得自行计数或修改 request/lease。
public enum AgentExecutionScheduler {

    /// 入队：同 Attempt 幂等（重复请求不占两个名额）。
    public static func enqueue(
        state: SchedulerState,
        request: GlobalExecutionAdmissionRequest,
        now: Date
    ) -> SchedulerState {
        if state.requests.contains(where: {
            $0.sessionID == request.sessionID && $0.attemptID == request.attemptID
        }) || state.activeLeases.contains(where: {
            $0.sessionID == request.sessionID && $0.attemptID == request.attemptID
        }) {
            return state // 幂等：已排队或已持有 lease
        }
        var newState = state
        let ordinal = state.nextQueueOrdinal
        var accepted = request
        accepted.queueOrdinal = ordinal
        accepted.enqueuedAt = now
        accepted.state = .queued
        newState.requests.append(accepted)
        newState.nextQueueOrdinal = ordinal + 1
        return newState
    }

    /// 提升：FIFO 按 queueOrdinal，一次提升到容量满；
    /// 容量按「占用容量」的 lease 计数（granted/active/orphanedRuntime 都占用；orphaned 不误释放）。
    public static func promote(
        state: SchedulerState,
        config: SchedulerConfig,
        now: Date
    ) -> (SchedulerState, [SchedulerEvent]) {
        var newState = state
        var events: [SchedulerEvent] = []
        var occupied = newState.activeLeases.filter { $0.occupiesCapacity }.count
        while occupied < config.capacity,
              let next = newState.requests.min(by: { $0.queueOrdinal < $1.queueOrdinal }) {
            newState.requests.removeAll { $0.requestID == next.requestID }
            let lease = GlobalExecutionAdmissionLease(
                leaseID: "lease-\(next.requestID)",
                requestID: next.requestID,
                sessionID: next.sessionID,
                turnID: next.turnID,
                attemptID: next.attemptID,
                schedulerGeneration: next.schedulerGeneration,
                acquiredAt: now,
                lastObservedAt: nil, // runtimeStarted 前不启动有效执行时钟
                releasedAt: nil,
                state: .granted,
                releaseReason: nil,
                settlementID: "settle-\(next.requestID)",
                isolationEvidenceID: nil,
                capacityReleasedAt: nil
            )
            newState.activeLeases.append(lease)
            occupied += 1
            events.append(.admissionGranted(requestID: next.requestID, leaseID: lease.leaseID, attemptID: next.attemptID))
        }
        return (newState, events)
    }

    /// 取消：queued 直接移除；granted 走释放路径。
    public static func cancel(
        state: SchedulerState,
        requestID: String,
        now: Date
    ) -> (SchedulerState, [SchedulerEvent]) {
        var newState = state
        if newState.requests.contains(where: { $0.requestID == requestID }) {
            newState.requests.removeAll { $0.requestID == requestID }
            return (newState, [.admissionCancelled(requestID: requestID)])
        }
        return release(state: newState, requestID: requestID, reason: "cancelled", now: now)
    }

    /// 显式释放（settled 证明后）：capacityReleased 反映是否真正释放容量。
    public static func release(
        state: SchedulerState,
        requestID: String,
        reason: String,
        now: Date
    ) -> (SchedulerState, [SchedulerEvent]) {
        var newState = state
        guard let index = newState.activeLeases.firstIndex(where: { $0.requestID == requestID }) else {
            return (newState, [])
        }
        var lease = newState.activeLeases[index]
        // orphanedRuntime 不误释放：必须经显式 settlement（Phase 2 直接拒绝自动释放）
        guard lease.state != .orphanedRuntime else {
            return (newState, [])
        }
        lease.state = .released
        lease.releasedAt = now
        lease.releaseReason = reason
        lease.capacityReleasedAt = now
        newState.activeLeases[index] = lease
        return (newState, [.admissionReleased(leaseID: lease.leaseID, capacityReleased: true)])
    }

    /// 等待超时检查：queued 请求超过 waitTimeout → capacityWaitExpired（离开队列）。
    public static func checkWaitTimeouts(
        state: SchedulerState,
        config: SchedulerConfig,
        now: Date
    ) -> (SchedulerState, [SchedulerEvent]) {
        var newState = state
        var events: [SchedulerEvent] = []
        var remaining: [GlobalExecutionAdmissionRequest] = []
        for request in newState.requests {
            if now.timeIntervalSince(request.enqueuedAt) >= config.waitTimeout {
                events.append(.admissionWaitExpired(requestID: request.requestID, attemptID: request.attemptID))
            } else {
                remaining.append(request)
            }
        }
        newState.requests = remaining
        return (newState, events)
    }
}

// MARK: - Production admission coordination

/// Durable global store used only by the process-wide scheduler. Conversation
/// views and bridges never mutate request/lease rows directly.
public protocol AgentExecutionAdmissionStore: AnyObject, Sendable {
    func beginAdmissionGeneration() throws -> Int
    func loadAdmissionState() throws -> SchedulerState
    func enqueueAdmissionRequest(
        requestID: String,
        sessionID: String,
        turnID: String,
        attemptID: String,
        schedulerGeneration: Int,
        now: Date
    ) throws -> GlobalExecutionAdmissionRequest
    func grantAdmissionRequest(
        requestID: String,
        attemptID: String,
        schedulerGeneration: Int,
        now: Date
    ) throws -> GlobalExecutionAdmissionLease
    func activateAdmissionLease(_ lease: GlobalExecutionAdmissionLease) throws
    func cancelAdmissionRequest(requestID: String, schedulerGeneration: Int) throws -> Bool
    func expireAdmissionRequest(requestID: String, schedulerGeneration: Int) throws -> Bool
    func releaseAdmissionLease(_ lease: GlobalExecutionAdmissionLease, now: Date) throws -> Bool
}

public enum AgentExecutionAdmissionResolution: Equatable, Sendable {
    case granted(GlobalExecutionAdmissionLease)
    case cancelled
    case expired
    case failed
}

public protocol AgentExecutionAdmissionCoordinating: Sendable {
    /// Prepare the current process generation before session replay. Rows left
    /// by an older process are classified atomically; orphaned leases remain
    /// capacity-occupying until explicit reconciliation.
    func prepareForRestore() async throws -> SchedulerState
    func enqueue(
        sessionID: String,
        turnID: String,
        attemptID: String,
        config: SchedulerConfig
    ) async throws -> GlobalExecutionAdmissionRequest
    func resolutionIfAvailable(requestID: String) async -> AgentExecutionAdmissionResolution?
    func waitForResolution(requestID: String) async -> AgentExecutionAdmissionResolution
    func activate(_ lease: GlobalExecutionAdmissionLease) async throws
    @discardableResult
    func cancel(requestID: String) async throws -> Bool
    @discardableResult
    func release(_ lease: GlobalExecutionAdmissionLease) async throws -> Bool
}

/// Process-wide FIFO coordinator. The actor is the only Swift writer of
/// admission request/lease state. A durable store is required by production;
/// the in-memory mode exists for isolated unit tests and still enforces FIFO.
public actor ProductionAgentExecutionScheduler: AgentExecutionAdmissionCoordinating {
    private let store: AgentExecutionAdmissionStore?
    private let nowProvider: @Sendable () -> Date
    private let requestIDProvider: @Sendable (String, String) -> String
    private var state = SchedulerState()
    private var didBeginGeneration = false
    private var capacity: Int
    private var knownRequestIDs = Set<String>()
    private var resolutions: [String: AgentExecutionAdmissionResolution] = [:]
    private var waiters: [String: [CheckedContinuation<AgentExecutionAdmissionResolution, Never>]] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    public init(
        store: AgentExecutionAdmissionStore? = nil,
        capacity: Int = 2,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        requestIDProvider: @escaping @Sendable (String, String) -> String = { sessionID, attemptID in
            "request-\(sessionID)-\(attemptID)"
        }
    ) {
        self.store = store
        self.capacity = min(max(capacity, 1), 4)
        self.nowProvider = nowProvider
        self.requestIDProvider = requestIDProvider
    }

    public func prepareForRestore() async throws -> SchedulerState {
        try ensureGenerationStarted()
        if let store {
            state = try store.loadAdmissionState()
        }
        return state
    }

    public func enqueue(
        sessionID: String,
        turnID: String,
        attemptID: String,
        config: SchedulerConfig
    ) async throws -> GlobalExecutionAdmissionRequest {
        try ensureGenerationStarted()
        capacity = config.capacity
        let requestID = requestIDProvider(sessionID, attemptID)
        let now = nowProvider()
        let request: GlobalExecutionAdmissionRequest
        if let store {
            request = try store.enqueueAdmissionRequest(
                requestID: requestID,
                sessionID: sessionID,
                turnID: turnID,
                attemptID: attemptID,
                schedulerGeneration: state.schedulerGeneration,
                now: now
            )
            state = try store.loadAdmissionState()
        } else {
            let candidate = GlobalExecutionAdmissionRequest(
                requestID: requestID,
                sessionID: sessionID,
                turnID: turnID,
                attemptID: attemptID,
                schedulerGeneration: state.schedulerGeneration,
                queueOrdinal: state.nextQueueOrdinal,
                enqueuedAt: now,
                state: .queued
            )
            state = AgentExecutionScheduler.enqueue(state: state, request: candidate, now: now)
            request = state.requests.first {
                $0.sessionID == sessionID && $0.attemptID == attemptID
            } ?? candidate
        }
        knownRequestIDs.insert(request.requestID)
        scheduleTimeout(
            requestID: request.requestID,
            waitTimeout: max(config.waitTimeout, 0)
        )
        try promoteAvailableCapacity()
        return request
    }

    public func waitForResolution(requestID: String) async -> AgentExecutionAdmissionResolution {
        if let resolution = resolutions[requestID] {
            return resolution
        }
        guard knownRequestIDs.contains(requestID) else { return .failed }
        return await withCheckedContinuation { continuation in
            waiters[requestID, default: []].append(continuation)
        }
    }

    public func resolutionIfAvailable(
        requestID: String
    ) async -> AgentExecutionAdmissionResolution? {
        resolutions[requestID]
    }

    public func activate(_ lease: GlobalExecutionAdmissionLease) async throws {
        try ensureGenerationStarted()
        guard lease.schedulerGeneration == state.schedulerGeneration else {
            throw AgentExecutionAdmissionCoordinatorError.staleGeneration
        }
        if let store {
            try store.activateAdmissionLease(lease)
            state = try store.loadAdmissionState()
        } else if let index = state.activeLeases.firstIndex(where: { $0.leaseID == lease.leaseID }) {
            guard state.activeLeases[index].state == .granted else {
                throw AgentExecutionAdmissionCoordinatorError.invalidLeaseState
            }
            state.activeLeases[index].state = .active
            state.activeLeases[index].lastObservedAt = nowProvider()
        } else {
            throw AgentExecutionAdmissionCoordinatorError.missingLease
        }
    }

    @discardableResult
    public func cancel(requestID: String) async throws -> Bool {
        try ensureGenerationStarted()
        let changed: Bool
        if let store {
            if try store.cancelAdmissionRequest(
                requestID: requestID,
                schedulerGeneration: state.schedulerGeneration
            ) {
                changed = true
            } else {
                let loaded = try store.loadAdmissionState()
                if let lease = loaded.activeLeases.first(where: {
                    $0.requestID == requestID && $0.schedulerGeneration == loaded.schedulerGeneration
                }) {
                    changed = try store.releaseAdmissionLease(lease, now: nowProvider())
                } else {
                    changed = false
                }
            }
            state = try store.loadAdmissionState()
        } else {
            let before = state
            let result = AgentExecutionScheduler.cancel(
                state: state,
                requestID: requestID,
                now: nowProvider()
            )
            state = result.0
            changed = before != state
        }
        if changed {
            resolve(requestID: requestID, as: .cancelled)
            try promoteAvailableCapacity()
        }
        return changed
    }

    @discardableResult
    public func release(_ lease: GlobalExecutionAdmissionLease) async throws -> Bool {
        try ensureGenerationStarted()
        guard lease.schedulerGeneration == state.schedulerGeneration else {
            throw AgentExecutionAdmissionCoordinatorError.staleGeneration
        }
        let changed: Bool
        if let store {
            changed = try store.releaseAdmissionLease(lease, now: nowProvider())
            state = try store.loadAdmissionState()
        } else {
            let before = state
            state = AgentExecutionScheduler.release(
                state: state,
                requestID: lease.requestID,
                reason: "settled",
                now: nowProvider()
            ).0
            changed = before != state
        }
        timeoutTasks.removeValue(forKey: lease.requestID)?.cancel()
        if changed {
            try promoteAvailableCapacity()
        }
        return changed
    }

    private func ensureGenerationStarted() throws {
        guard didBeginGeneration == false else { return }
        if let store {
            let generation = try store.beginAdmissionGeneration()
            state = try store.loadAdmissionState()
            guard state.schedulerGeneration == generation else {
                throw AgentExecutionAdmissionCoordinatorError.staleGeneration
            }
        } else {
            state.schedulerGeneration = max(state.schedulerGeneration + 1, 1)
        }
        didBeginGeneration = true
    }

    private func promoteAvailableCapacity() throws {
        if let store {
            state = try store.loadAdmissionState()
            var occupied = state.activeLeases.filter(\.occupiesCapacity).count
            let queued = state.requests
                .filter { $0.schedulerGeneration == state.schedulerGeneration }
                .sorted { $0.queueOrdinal < $1.queueOrdinal }
            for request in queued where occupied < capacity {
                let lease = try store.grantAdmissionRequest(
                    requestID: request.requestID,
                    attemptID: request.attemptID,
                    schedulerGeneration: state.schedulerGeneration,
                    now: nowProvider()
                )
                occupied += 1
                resolve(requestID: request.requestID, as: .granted(lease))
            }
            state = try store.loadAdmissionState()
        } else {
            let result = AgentExecutionScheduler.promote(
                state: state,
                config: SchedulerConfig(capacity: capacity),
                now: nowProvider()
            )
            state = result.0
            for event in result.1 {
                guard case let .admissionGranted(requestID, leaseID, _) = event,
                      let lease = state.activeLeases.first(where: { $0.leaseID == leaseID })
                else { continue }
                resolve(requestID: requestID, as: .granted(lease))
            }
        }
    }

    private func scheduleTimeout(requestID: String, waitTimeout: TimeInterval) {
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        guard resolutions[requestID] == nil else { return }
        let nanoseconds = UInt64(min(max(waitTimeout, 0), 86_400) * 1_000_000_000)
        timeoutTasks[requestID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.expire(requestID: requestID)
        }
    }

    private func expire(requestID: String) {
        guard resolutions[requestID] == nil else { return }
        do {
            let changed: Bool
            if let store {
                changed = try store.expireAdmissionRequest(
                    requestID: requestID,
                    schedulerGeneration: state.schedulerGeneration
                )
                state = try store.loadAdmissionState()
            } else if let request = state.requests.first(where: { $0.requestID == requestID }) {
                state.requests.removeAll { $0.requestID == requestID }
                changed = true
                _ = request
            } else {
                changed = false
            }
            if changed {
                resolve(requestID: requestID, as: .expired)
                try promoteAvailableCapacity()
            }
        } catch {
            resolve(requestID: requestID, as: .failed)
        }
    }

    private func resolve(
        requestID: String,
        as resolution: AgentExecutionAdmissionResolution
    ) {
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        resolutions[requestID] = resolution
        let continuations = waiters.removeValue(forKey: requestID) ?? []
        for continuation in continuations {
            continuation.resume(returning: resolution)
        }
    }
}

public enum AgentExecutionAdmissionCoordinatorError: Error, Equatable, Sendable {
    case staleGeneration
    case invalidLeaseState
    case missingLease
}

extension GlobalExecutionAdmissionLease {
    /// 是否占用容量（granted/active/orphanedRuntime 占用；orphaned 不误释放）。
    var occupiesCapacity: Bool {
        switch state {
        case .granted, .active, .orphanedRuntime:
            return true
        case .releasing, .released, .isolated:
            return false
        }
    }
}

// MARK: - QueuedInput 冻结 / needsRebind（C2-8）

public enum QueuedInputRevalidator {
    /// 校验冻结快照与当前上下文：任一 digest 变化 → needsRebind。
    public static func revalidationState(
        for input: QueuedInput,
        current: QueuedInputContextSnapshot
    ) -> QueuedInputRevalidationState {
        let frozen = input.contextSnapshot
        var changed: [String] = []
        if frozen.targetDigest != current.targetDigest { changed.append("targetDigest") }
        if frozen.authenticationDigest != current.authenticationDigest { changed.append("authenticationDigest") }
        if frozen.configurationRevisionDigest != current.configurationRevisionDigest { changed.append("configurationRevisionDigest") }
        if frozen.instructionDigest != current.instructionDigest { changed.append("instructionDigest") }
        if frozen.workMode != current.workMode { changed.append("workMode") }
        return changed.isEmpty ? .valid : .needsRebind
    }

    /// 用户选择原/当前上下文：都创建新 revision 与审计记录。
    public static func rebind(
        input: QueuedInput,
        to context: QueuedInputContextSnapshot,
        source: QueuedInputContextSource,
        now: Date
    ) -> (QueuedInput, RebindAuditRecord) {
        let changed = changedDigests(from: input.contextSnapshot, to: context)
        var rebound = input
        rebound.revision += 1
        rebound.contextSnapshot = context
        rebound.contextSnapshot.source = source
        rebound.revalidationState = .valid
        rebound.updatedAt = now
        let audit = RebindAuditRecord(
            queuedInputID: input.id,
            previousRevision: input.revision,
            newRevision: rebound.revision,
            selectedSource: source,
            changedDigests: changed,
            at: now
        )
        return (rebound, audit)
    }

    /// 队列提升门禁：needsRebind 未选择前不得自动提升（无选择不得自动提升）。
    public static func promotionGate(for input: QueuedInput) -> QueuedInputRevalidationState {
        input.revalidationState == .valid ? .valid : .blocked
    }

    private static func changedDigests(
        from frozen: QueuedInputContextSnapshot,
        to current: QueuedInputContextSnapshot
    ) -> [String] {
        var changed: [String] = []
        if frozen.targetDigest != current.targetDigest { changed.append("targetDigest") }
        if frozen.authenticationDigest != current.authenticationDigest { changed.append("authenticationDigest") }
        if frozen.configurationRevisionDigest != current.configurationRevisionDigest { changed.append("configurationRevisionDigest") }
        if frozen.instructionDigest != current.instructionDigest { changed.append("instructionDigest") }
        if frozen.workMode != current.workMode { changed.append("workMode") }
        return changed
    }
}

public struct RebindAuditRecord: Equatable, Sendable {
    public var queuedInputID: String
    public var previousRevision: Int
    public var newRevision: Int
    public var selectedSource: QueuedInputContextSource
    public var changedDigests: [String]
    public var at: Date

    public init(
        queuedInputID: String,
        previousRevision: Int,
        newRevision: Int,
        selectedSource: QueuedInputContextSource,
        changedDigests: [String],
        at: Date
    ) {
        self.queuedInputID = queuedInputID
        self.previousRevision = previousRevision
        self.newRevision = newRevision
        self.selectedSource = selectedSource
        self.changedDigests = changedDigests
        self.at = at
    }
}
