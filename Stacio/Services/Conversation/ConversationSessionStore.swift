import CryptoKit
import Foundation

// MARK: - ConversationSealing（提交前本地 sealed-box 验证）

/// canonical AAD sealed-box 验证协议（规格 §15.1）。
///
/// 统一密封合同（P0-1 修复）：
/// - `verifyRoundTrip` 接收**明文 payload**，内部执行 seal→open 往返验证加密是否工作正常；
/// - 不接受调用方另传密封后字节（旧 `verify(payload:aad:)` 合同已废弃——它把明文当密封字节解析，导致生产路径每次返回 false）；
/// - 真实实现 `ConversationEncryptionSealingAdapter` 经 `ConversationEncryption.seal()` + `open()` 完成往返；
/// - 无安全 fallback：Keychain/存储失败时 fail closed（不创建桥接，向用户显示可恢复错误）。
public protocol ConversationSealing: AnyObject {
    /// 提交前本地往返验证：密封明文 payload 后立即解密验证，确认加密密钥/AAD 工作正常。
    /// 返回 true 表示加密可用；false 表示加密不可用（Actor 不得提交，fail closed）。
    func verifyRoundTrip(payload: Data, aad: String) -> Bool
}

// MARK: - 提交结果

public enum ConversationCommitOutcome: Equatable, Sendable {
    case committed(lastSequence: Int)
    case conflict(expected: Int, actual: Int)
    case storageFailure(reason: String)
}

// MARK: - 会话快照（load 结果）

public struct ConversationSessionSnapshot: Equatable, Sendable {
    public var state: ConversationSessionState?
    public var lastAppliedSequence: Int

    public init(state: ConversationSessionState? = nil, lastAppliedSequence: Int = 0) {
        self.state = state
        self.lastAppliedSequence = lastAppliedSequence
    }
}

/// Identity fields that the durable Repository authenticates alongside an
/// event payload. Event ID + payload hash alone are insufficient for the
/// Actor's idempotent fast path: a tampered event could retain both while
/// changing its reducer-visible metadata (type/source/visibility).
public struct ConversationEventIdentity: Equatable, Sendable {
    public let eventID: String
    public let conversationID: String
    public let scope: ConversationEventScope
    public let turnID: String?
    public let attemptID: String?
    public let candidateSequence: Int
    public let eventType: String
    public let writeClass: String
    public let source: String
    public let visibility: String
    public let payloadHash: String
    /// Derived from the actual payload bytes. `payloadHash` is persisted caller
    /// metadata and cannot by itself prove an idempotent retry.
    public let payloadDigest: String

    public init(
        eventID: String,
        conversationID: String,
        scope: ConversationEventScope,
        turnID: String?,
        attemptID: String?,
        candidateSequence: Int,
        eventType: String,
        writeClass: String,
        source: String,
        visibility: String,
        payloadHash: String,
        payloadDigest: String
    ) {
        self.eventID = eventID
        self.conversationID = conversationID
        self.scope = scope
        self.turnID = turnID
        self.attemptID = attemptID
        self.candidateSequence = candidateSequence
        self.eventType = eventType
        self.writeClass = writeClass
        self.source = source
        self.visibility = visibility
        self.payloadHash = payloadHash
        self.payloadDigest = payloadDigest
    }

    public init(envelope: ConversationEventEnvelope) {
        self.init(
            eventID: envelope.eventID,
            conversationID: envelope.conversationID,
            scope: envelope.scope,
            turnID: envelope.turnID,
            attemptID: envelope.attemptID,
            candidateSequence: envelope.candidateSequence,
            eventType: envelope.kind.rawValue,
            writeClass: envelope.writeClass.rawValue,
            source: envelope.source,
            visibility: envelope.visibility,
            payloadHash: envelope.payloadHash,
            payloadDigest: SHA256.hash(data: envelope.payload)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    public func matches(_ envelope: ConversationEventEnvelope) -> Bool {
        self == ConversationEventIdentity(envelope: envelope)
    }
}

/// Optional stronger identity lookup used by the Actor's idempotent shortcut.
/// Legacy test doubles may continue to expose only the historical ID/hash
/// methods; the production Rust-backed stores implement this contract.
public protocol ConversationEventIdentityProviding: AnyObject {
    func existingEventIdentity(at sequence: Int) -> ConversationEventIdentity?
}

public enum ConversationOutboxDispatchState: String, Codable, Equatable, Sendable {
    case pending
    case dispatching
    case settled
    case reconciliationRequired
}

public enum ConversationOutboxSettlementOutcome: String, Codable, Equatable, Sendable {
    case acknowledged
    case completed
    case failed
    case cancelled
}

public struct ConversationOutboxDispatchRecord: Equatable, Sendable {
    public var itemID: String
    public var effectID: String
    public var operationID: String
    public var idempotencyKey: String
    public var command: EffectCommand?
    public var authorityLeaseID: String?
    public var capabilityGeneration: Int?
    public var permitCommitDecision: V2ControlPermitState?
    public var state: ConversationOutboxDispatchState
    public var dispatchToken: String?
    public var dispatchedAt: String?
    public var settlementOutcome: String?
    public var settledAt: String?
    public var reconciliationReason: String?
}

public enum ConversationOutboxStoreError: Error, Equatable {
    case unsupported
    case invalidCommandKind(String)
    case invalidCommandPayload(String)
    case invalidDispatchState(String)
}

// MARK: - ConversationSessionStore（Repository 契约；阶段 3 由真实 Rust Repository 实现）

/// V2 会话库的 Swift 侧契约（durable sequence 的真实实现属阶段 3，本阶段以 test double 满足）。
public protocol ConversationSessionStore: AnyObject {
    /// 读取会话当前快照与 lastAppliedSequence。
    func load() throws -> ConversationSessionSnapshot

    /// 单事务提交：expected sequence 校验 + candidate range + Event append + 投影 + outbox。
    /// 冲突返回 `.conflict`（Actor 丢弃整批预演）；事务失败时任何动作不可见。
    func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome

    /// 幂等去重查询：指定 sequence 上已存在的事件 ID（重复投递判定）。
    func existingEventID(at sequence: Int) -> String?

    /// 幂等去重查询：指定 sequence 上已存在的 payload hash。
    func existingPayloadHash(at sequence: Int) -> String?

    /// Every effect that has not reached a durable settlement.
    func loadUnsettledOutbox() throws -> [ConversationOutboxDispatchRecord]

    /// Atomically claim one pending effect by stable effect ID.
    func claimOutboxEffect(
        effectID: String,
        dispatchToken: String,
        dispatchedAt: String
    ) throws -> ConversationOutboxDispatchRecord?

    /// Settle only the claimant that owns `dispatchToken`.
    func settleOutbox(
        itemID: String,
        dispatchToken: String,
        outcome: ConversationOutboxSettlementOutcome,
        settledAt: String
    ) throws -> Bool

    /// Prevent automatic replay when the external result cannot be proven.
    func requireOutboxReconciliation(itemID: String, reason: String) throws -> Bool
}

/// Stores that can return the authenticated event stream support in-process
/// conflict recovery. The Actor replays this stream after another writer wins
/// a sequence race instead of advancing only its sequence counter.
public protocol ConversationEventLoading: AnyObject {
    func loadEvents() throws -> [ConversationEventEnvelope]
}

public extension ConversationSessionStore {
    func loadUnsettledOutbox() throws -> [ConversationOutboxDispatchRecord] {
        throw ConversationOutboxStoreError.unsupported
    }

    func claimOutboxEffect(
        effectID: String,
        dispatchToken: String,
        dispatchedAt: String
    ) throws -> ConversationOutboxDispatchRecord? {
        throw ConversationOutboxStoreError.unsupported
    }

    func settleOutbox(
        itemID: String,
        dispatchToken: String,
        outcome: ConversationOutboxSettlementOutcome,
        settledAt: String
    ) throws -> Bool {
        throw ConversationOutboxStoreError.unsupported
    }

    func requireOutboxReconciliation(itemID: String, reason: String) throws -> Bool {
        throw ConversationOutboxStoreError.unsupported
    }
}
