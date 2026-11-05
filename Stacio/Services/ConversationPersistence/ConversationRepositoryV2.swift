import Foundation
import StacioCoreBindings

/// ConversationSessionStore 的真实实现（P3-6）：Swift facade → ConversationEncryption 密封
/// → Rust conversation_v2 独立库单事务提交 → 投影发布。
///
/// - 主密钥 → HKDF 派生会话密钥 → canonical AAD AES-GCM 密封每条敏感负载；
/// - 提交前本地 sealed-box 验证（验证失败不调用 Rust Repository）；
/// - 幂等判定基于本实例已提交序列缓存（与 Rust 库一致性由 sequence 校验兜底）。
public enum ConversationRepositoryV2Error: Error, Equatable {
    case corruptedEvent(sequence: Int, reason: String)
    case invalidProjection(key: String, reason: String)
    case invalidAdmissionRecord(kind: String, state: String)
}

public struct ConversationSessionIndexRecord: Equatable, Sendable {
    public let conversationID: String
    public let schemaVersion: Int
    public let createdAt: Date?
    public let updatedAt: Date?
    public let isCorrupted: Bool
}

public final class ConversationRepositoryV2: ConversationSessionStore, ConversationEventLoading, ConversationEventIdentityProviding, AgentExecutionAdmissionStore, @unchecked Sendable {
    private let handle: UInt64
    private let encryption: ConversationEncryption
    private let conversationID: String
    private let schemaVersion = 1
    private let lock = NSLock()
    private var committedEvents: [Int: ConversationEventIdentity] = [:]

    /// - Parameters:
    ///   - databasePath: V2 独立库路径（`agent-conversations-v2.sqlite3`）。
    public init(conversationID: String, databasePath: String, encryption: ConversationEncryption) throws {
        self.conversationID = conversationID
        self.encryption = encryption
        self.handle = try CoreBridge.conversationV2Open(path: databasePath)
    }

    deinit {
        CoreBridge.conversationV2Close(handle: handle)
    }

    // MARK: - ConversationSessionStore

    public func load() throws -> ConversationSessionSnapshot {
        let last = try CoreBridge.conversationV2LastApplied(handle: handle, conversationId: conversationID)
        return ConversationSessionSnapshot(state: nil, lastAppliedSequence: Int(last))
    }

    public func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        // 1) 密封每条 candidate 的敏感 payload（canonical AAD；失败不提交）
        var sealedCandidates: [StacioCoreBindings.EnvelopeCandidate] = []
        for envelope in candidates {
            guard envelope.conversationID == conversationID else {
                throw ConversationRepositoryV2Error.corruptedEvent(
                    sequence: envelope.candidateSequence,
                    reason: "conversation ID mismatch"
                )
            }
            // scope/turn/attempt/timestamp 与业务 payload 必须处于同一个认证密文中。
            // Rust 仅保留事务索引所需的最小明文字段；回放以此密文信封为权威并逐项交叉验证。
            let encodedEnvelope = try JSONEncoder().encode(envelope)
            let sealed = try encryption.seal(
                payload: encodedEnvelope,
                conversationID: conversationID,
                recordType: "conversationEvent",
                recordID: envelope.eventID,
                candidateSequence: envelope.candidateSequence,
                schemaVersion: schemaVersion
            )
            // 提交前本地 sealed-box 验证（tag/AAD 失败 → 抛错，不调用 Repository）
            guard encryption.verifySealedBox(
                sealed,
                conversationID: conversationID,
                recordType: "conversationEvent",
                recordID: envelope.eventID,
                candidateSequence: envelope.candidateSequence,
                schemaVersion: schemaVersion
            ) else {
                throw ConversationEncryptionError.authenticationFailed
            }
            let serializedBox = Self.serializeSealedBox(sealed)
            sealedCandidates.append(
                StacioCoreBindings.EnvelopeCandidate(
                    sequence: Int64(envelope.candidateSequence),
                    eventId: envelope.eventID,
                    eventType: envelope.kind.rawValue,
                    writeClass: envelope.writeClass.rawValue,
                    source: envelope.source,
                    createdAt: ISO8601DateFormatter().string(from: envelope.timestamp),
                    payloadHash: envelope.payloadHash,
                    visibility: envelope.visibility,
                    // P0-5 修复：存储完整 sealed box（nonce + ciphertext + tag），
                    // 而非仅 ciphertext——否则 loadEvents 无法重建 box 解密。
                    payloadCipher: serializedBox,
                    payloadCipherVersion: sealed.cipherVersion,
                    payloadByteLength: Int64(serializedBox.count)
                )
            )
        }

        // 2) 构造 Rust CommitRequest。Projection 的 Swift 契约接收明文值，
        //    因此在 facade 内按稳定 key 密封；不能把调用方的明文直接交给
        //    Rust 的 opaque payload_cipher 列。Projection AAD 使用固定
        //    sequence 0，因为 projection 没有事件序列，更新时仍需可解密。
        let rustProjections = try projections
            .sorted { $0.key < $1.key }
            .map { key, payload in
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedKey.isEmpty == false else {
                    throw ConversationRepositoryV2Error.invalidProjection(
                        key: key,
                        reason: "projection key is empty"
                    )
                }
                let sealed = try encryption.seal(
                    payload: payload,
                    conversationID: conversationID,
                    recordType: "conversationProjection",
                    recordID: normalizedKey,
                    candidateSequence: 0,
                    schemaVersion: schemaVersion
                )
                guard encryption.verifySealedBox(
                    sealed,
                    conversationID: conversationID,
                    recordType: "conversationProjection",
                    recordID: normalizedKey,
                    candidateSequence: 0,
                    schemaVersion: schemaVersion
                ) else {
                    throw ConversationRepositoryV2Error.invalidProjection(
                        key: normalizedKey,
                        reason: "projection sealing verification failed"
                    )
                }
                return StacioCoreBindings.ProjectionValue(
                    key: normalizedKey,
                    payloadCipher: Self.serializeSealedBox(sealed),
                    payloadCipherVersion: sealed.cipherVersion,
                    payloadByteLength: Int64(
                        sealed.nonce.count + sealed.ciphertext.count + sealed.tag.count
                    )
                )
            }

        // 3) 构造 Rust CommitRequest（outbox 带稳定 ID）
        let rustOutbox = try outbox.map { item in
            let encoded = try ConversationEffectCommandCodec.encode(item.command)
            return StacioCoreBindings.OutboxItem(
                itemId: item.itemID,
                effectId: item.effectID,
                operationId: item.operationID,
                idempotencyKey: item.idempotencyKey,
                commandKind: encoded.kind,
                commandPayload: encoded.payload,
                authorityLeaseId: item.authorityLeaseID,
                capabilityGeneration: item.capabilityGeneration.map(Int64.init),
                permitCommitDecision: item.permitCommitDecision?.rawValue
            )
        }
        let request = StacioCoreBindings.CommitRequest(
            conversationId: conversationID,
            expectedLastSequence: Int64(expectedLastSequence),
            candidates: sealedCandidates,
            projections: rustProjections,
            outbox: rustOutbox,
            requiredReservations: []
        )

        // 3) Rust 单事务提交
        let outcome: StacioCoreBindings.CommitOutcome
        do {
            outcome = try CoreBridge.conversationV2Commit(handle: handle, request: request)
        } catch {
            // Rust 层 ExpectedMismatch（并发冲突）→ 结构化映射为 conflict（Actor 重读 lastApplied 后重试）；
            // 其余错误（损坏隔离/存储/校验）继续抛出
            if "\(error)".contains("ExpectedMismatch") {
                let actual = (try? CoreBridge.conversationV2LastApplied(
                    handle: handle,
                    conversationId: conversationID
                )).map(Int.init) ?? expectedLastSequence
                return .conflict(expected: expectedLastSequence, actual: actual)
            }
            throw error
        }

        // 4) 更新幂等缓存 + 映射结果
        lock.lock()
        for envelope in candidates {
            committedEvents[envelope.candidateSequence] = ConversationEventIdentity(envelope: envelope)
        }
        lock.unlock()
        return .committed(lastSequence: Int(outcome.snapshotAtSequence))
    }

    /// P0-5：序列化 sealed box 为单一 BLOB（nonce[12] + ciphertext + tag[16]）。
    /// commit 存储此格式；loadEvents 按此格式拆分重建 box。
    private static func serializeSealedBox(_ box: SealedConversationPayload) -> Data {
        var data = Data()
        data.append(box.nonce)
        data.append(box.ciphertext)
        data.append(box.tag)
        return data
    }

    /// P0-5：从 BLOB 拆分重建 sealed box（nonce[12] + ciphertext + tag[16]）。
    private static func deserializeSealedBox(_ data: Data, cipherVersion: String) -> SealedConversationPayload? {
        guard data.count >= 12 + 16 else { return nil }
        let nonce = data.prefix(12)
        let tag = data.suffix(16)
        let ciphertext = data.dropFirst(12).dropLast(16)
        return SealedConversationPayload(
            nonce: nonce, ciphertext: ciphertext, tag: tag, cipherVersion: cipherVersion
        )
    }

    public func existingEventID(at sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return committedEvents[sequence]?.eventID
    }

    public func existingPayloadHash(at sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return committedEvents[sequence]?.payloadHash
    }

    public func existingEventIdentity(at sequence: Int) -> ConversationEventIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return committedEvents[sequence]
    }

    // MARK: - P0-5：事件加载与解密（重启恢复/replay）

    /// 加载会话全部事件并解密完整信封，返回按 sequence 升序的 envelope 数组。
    /// 任一记录损坏、缺口或明密文元数据不一致都会失败关闭；禁止跳过后继续 replay。
    public func loadEvents() throws -> [ConversationEventEnvelope] {
        try loadEvents(conversationID: conversationID)
    }

    /// Plaintext index rows contain only IDs, schema and timestamps. Display
    /// metadata is reconstructed from encrypted events by the catalog loader.
    public func listSessionIndex() throws -> [ConversationSessionIndexRecord] {
        let formatter = ISO8601DateFormatter()
        return try CoreBridge.conversationV2ListSessions(handle: handle).map { record in
            ConversationSessionIndexRecord(
                conversationID: record.conversationId,
                schemaVersion: Int(record.schemaVersion),
                createdAt: formatter.date(from: record.createdAt),
                updatedAt: formatter.date(from: record.updatedAt),
                isCorrupted: record.isCorrupted
            )
        }
    }

    /// Uses the same repository handle to decrypt another session on demand.
    /// This avoids opening one SQLite connection per row in the sidebar.
    public func loadEvents(conversationID requestedConversationID: String) throws -> [ConversationEventEnvelope] {
        let records = try CoreBridge.conversationV2LoadEvents(
            handle: handle,
            conversationId: requestedConversationID
        )
        var envelopes: [ConversationEventEnvelope] = []
        var expectedSequence = 1
        for record in records {
            let sequence = Int(record.sequence)
            guard sequence == expectedSequence else {
                throw ConversationRepositoryV2Error.corruptedEvent(
                    sequence: sequence,
                    reason: "sequence gap: expected \(expectedSequence)"
                )
            }
            // 解密 payload（canonical AAD）——从 BLOB 重建 sealed box
            let cipherVersion = record.payloadCipherVersion.isEmpty
                ? ConversationEncryption.cipherVersion : record.payloadCipherVersion
            guard let box = Self.deserializeSealedBox(Data(record.payloadCipher), cipherVersion: cipherVersion) else {
                throw ConversationRepositoryV2Error.corruptedEvent(
                    sequence: sequence,
                    reason: "invalid sealed box"
                )
            }
            let plaintext = try encryption.open(
                box,
                conversationID: requestedConversationID,
                recordType: "conversationEvent",
                recordID: record.eventId,
                candidateSequence: sequence,
                schemaVersion: schemaVersion
            )
            let envelope: ConversationEventEnvelope
            do {
                envelope = try JSONDecoder().decode(ConversationEventEnvelope.self, from: plaintext)
            } catch {
                throw ConversationRepositoryV2Error.corruptedEvent(
                    sequence: sequence,
                    reason: "encrypted envelope cannot be decoded"
                )
            }
            guard envelope.eventID == record.eventId,
                  envelope.conversationID == requestedConversationID,
                  envelope.candidateSequence == sequence,
                  envelope.kind.rawValue == record.eventType,
                  envelope.writeClass.rawValue == record.writeClass,
                  envelope.source == record.source,
                  ISO8601DateFormatter().string(from: envelope.timestamp) == record.createdAt,
                  envelope.payloadHash == record.payloadHash,
                  envelope.visibility == record.visibility
            else {
                throw ConversationRepositoryV2Error.corruptedEvent(
                    sequence: sequence,
                    reason: "plaintext index does not match authenticated envelope"
                )
            }
            envelopes.append(envelope)
            expectedSequence += 1
        }
        if requestedConversationID == conversationID {
            lock.lock()
            committedEvents = Dictionary(uniqueKeysWithValues: envelopes.map {
                ($0.candidateSequence, ConversationEventIdentity(envelope: $0))
            })
            lock.unlock()
        }
        return envelopes
    }

    public func loadUnsettledOutbox() throws -> [ConversationOutboxDispatchRecord] {
        try CoreBridge.conversationV2LoadUnsettledOutbox(
            handle: handle,
            conversationId: conversationID
        ).map(Self.mapOutboxRecord)
    }

    public func claimOutboxEffect(
        effectID: String,
        dispatchToken: String,
        dispatchedAt: String
    ) throws -> ConversationOutboxDispatchRecord? {
        try CoreBridge.conversationV2ClaimOutboxEffect(
            handle: handle,
            conversationId: conversationID,
            effectId: effectID,
            dispatchToken: dispatchToken,
            dispatchedAt: dispatchedAt
        ).map(Self.mapOutboxRecord)
    }

    public func settleOutbox(
        itemID: String,
        dispatchToken: String,
        outcome: ConversationOutboxSettlementOutcome,
        settledAt: String
    ) throws -> Bool {
        try CoreBridge.conversationV2SettleOutbox(
            handle: handle,
            conversationId: conversationID,
            itemId: itemID,
            dispatchToken: dispatchToken,
            outcome: outcome.rawValue,
            settledAt: settledAt
        )
    }

    public func requireOutboxReconciliation(itemID: String, reason: String) throws -> Bool {
        try CoreBridge.conversationV2RequireOutboxReconciliation(
            handle: handle,
            conversationId: conversationID,
            itemId: itemID,
            reason: reason
        )
    }

    private static func mapOutboxRecord(
        _ record: StacioCoreBindings.LoadedOutboxRecord
    ) throws -> ConversationOutboxDispatchRecord {
        guard let state = ConversationOutboxDispatchState(rawValue: record.status) else {
            throw ConversationOutboxStoreError.invalidDispatchState(record.status)
        }
        let command: EffectCommand?
        if record.commandKind == "legacyUnknown",
           state == .reconciliationRequired {
            command = nil
        } else {
            command = try ConversationEffectCommandCodec.decode(
                kind: record.commandKind,
                payload: record.commandPayload
            )
        }
        let permitState: V2ControlPermitState?
        if let rawPermit = record.permitCommitDecision {
            guard let parsed = V2ControlPermitState(rawValue: rawPermit) else {
                throw ConversationOutboxStoreError.invalidCommandPayload("permitCommitDecision")
            }
            permitState = parsed
        } else {
            permitState = nil
        }
        return ConversationOutboxDispatchRecord(
            itemID: record.itemId,
            effectID: record.effectId,
            operationID: record.operationId,
            idempotencyKey: record.idempotencyKey,
            command: command,
            authorityLeaseID: record.authorityLeaseId,
            capabilityGeneration: record.capabilityGeneration.map(Int.init),
            permitCommitDecision: permitState,
            state: state,
            dispatchToken: record.dispatchToken,
            dispatchedAt: record.dispatchedAt,
            settlementOutcome: record.settlementOutcome,
            settledAt: record.settledAt,
            reconciliationReason: record.reconciliationReason
        )
    }

    // MARK: - Process-global execution admission

    public func beginAdmissionGeneration() throws -> Int {
        Int(try CoreBridge.conversationV2AdmissionBeginGeneration(handle: handle))
    }

    public func loadAdmissionState() throws -> SchedulerState {
        let record = try CoreBridge.conversationV2AdmissionLoadState(handle: handle)
        return SchedulerState(
            schedulerGeneration: Int(record.schedulerGeneration),
            requests: try record.requests.map(Self.mapAdmissionRequest),
            activeLeases: try record.activeLeases.map(Self.mapAdmissionLease),
            nextQueueOrdinal: Int(record.nextQueueOrdinal)
        )
    }

    public func enqueueAdmissionRequest(
        requestID: String,
        sessionID: String,
        turnID: String,
        attemptID: String,
        schedulerGeneration: Int,
        now: Date
    ) throws -> GlobalExecutionAdmissionRequest {
        try Self.mapAdmissionRequest(CoreBridge.conversationV2AdmissionEnqueue(
            handle: handle,
            requestId: requestID,
            conversationId: sessionID,
            turnId: turnID,
            attemptId: attemptID,
            schedulerGeneration: Int64(schedulerGeneration),
            nowSeconds: now.timeIntervalSince1970
        ))
    }

    public func grantAdmissionRequest(
        requestID: String,
        attemptID: String,
        schedulerGeneration: Int,
        now: Date
    ) throws -> GlobalExecutionAdmissionLease {
        try Self.mapAdmissionLease(CoreBridge.conversationV2AdmissionGrant(
            handle: handle,
            requestId: requestID,
            attemptId: attemptID,
            schedulerGeneration: Int64(schedulerGeneration),
            nowSeconds: now.timeIntervalSince1970
        ))
    }

    public func activateAdmissionLease(_ lease: GlobalExecutionAdmissionLease) throws {
        try CoreBridge.conversationV2AdmissionActivate(
            handle: handle,
            leaseId: lease.leaseID,
            schedulerGeneration: Int64(lease.schedulerGeneration)
        )
    }

    public func cancelAdmissionRequest(
        requestID: String,
        schedulerGeneration: Int
    ) throws -> Bool {
        try CoreBridge.conversationV2AdmissionCancelRequest(
            handle: handle,
            requestId: requestID,
            schedulerGeneration: Int64(schedulerGeneration)
        )
    }

    public func expireAdmissionRequest(
        requestID: String,
        schedulerGeneration: Int
    ) throws -> Bool {
        try CoreBridge.conversationV2AdmissionExpireRequest(
            handle: handle,
            requestId: requestID,
            schedulerGeneration: Int64(schedulerGeneration)
        )
    }

    public func releaseAdmissionLease(
        _ lease: GlobalExecutionAdmissionLease,
        now: Date
    ) throws -> Bool {
        try CoreBridge.conversationV2AdmissionRelease(
            handle: handle,
            leaseId: lease.leaseID,
            schedulerGeneration: Int64(lease.schedulerGeneration),
            nowSeconds: now.timeIntervalSince1970
        )
    }

    private static func mapAdmissionRequest(
        _ record: StacioCoreBindings.AdmissionRequestRecord
    ) throws -> GlobalExecutionAdmissionRequest {
        guard let state = GlobalExecutionAdmissionRequestState(rawValue: record.state) else {
            throw ConversationRepositoryV2Error.invalidAdmissionRecord(
                kind: "request",
                state: record.state
            )
        }
        return GlobalExecutionAdmissionRequest(
            requestID: record.requestId,
            sessionID: record.conversationId,
            turnID: record.turnId,
            attemptID: record.attemptId,
            schedulerGeneration: Int(record.schedulerGeneration),
            queueOrdinal: Int(record.queueOrdinal),
            enqueuedAt: Date(timeIntervalSince1970: record.createdAtSeconds),
            state: state,
            grantedLeaseID: record.grantedLeaseId
        )
    }

    private static func mapAdmissionLease(
        _ record: StacioCoreBindings.AdmissionLeaseRecord
    ) throws -> GlobalExecutionAdmissionLease {
        guard let state = GlobalExecutionAdmissionLeaseState(rawValue: record.state) else {
            throw ConversationRepositoryV2Error.invalidAdmissionRecord(
                kind: "lease",
                state: record.state
            )
        }
        let acquiredAt = Date(timeIntervalSince1970: record.acquiredAtSeconds)
        let releasedAt = record.releasedAtSeconds.map(Date.init(timeIntervalSince1970:))
        return GlobalExecutionAdmissionLease(
            leaseID: record.leaseId,
            requestID: record.requestId,
            sessionID: record.conversationId,
            turnID: record.turnId,
            attemptID: record.attemptId,
            schedulerGeneration: Int(record.schedulerGeneration),
            acquiredAt: acquiredAt,
            lastObservedAt: state == .active ? acquiredAt : nil,
            releasedAt: releasedAt,
            state: state,
            settlementID: record.settlementId,
            capacityReleasedAt: state == .released ? releasedAt : nil
        )
    }
}
