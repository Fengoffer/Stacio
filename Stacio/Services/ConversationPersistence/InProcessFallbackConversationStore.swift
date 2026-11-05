import Foundation

// MARK: - ConversationEncryption → ConversationSealing 适配器（P0-1 统一密封合同）

/// 将 `ConversationEncryption` 适配为 `ConversationSealing` 协议。
///
/// 统一密封合同（P0-1 修复）：
/// - `verifyRoundTrip(payload:aad:)` 接收**明文** payload，内部执行 seal→open 往返验证；
/// - seal 使用 `ConversationEncryption.seal()`（canonical AAD = recordType + recordID + sequence + schemaVersion）；
/// - open 使用 `ConversationEncryption.open()` 验证 tag/AAD；
/// - 往返成功返回 true（加密可用）；任何步骤失败返回 false（fail closed，Actor 不提交）。
///
/// AAD 格式：`stacio.v2|conversationEvent|<eventID>|<candidateSequence>|schema-1`
/// 解析为 recordType=<kind>, recordID=<eventID>, candidateSequence=<seq>, schemaVersion=1。
public final class ConversationEncryptionSealingAdapter: ConversationSealing {
    private let encryption: ConversationEncryption
    private let conversationID: String
    private let schemaVersion: Int

    public init(encryption: ConversationEncryption, conversationID: String, schemaVersion: Int = 1) {
        self.encryption = encryption
        self.conversationID = conversationID
        self.schemaVersion = schemaVersion
    }

    public func verifyRoundTrip(payload: Data, aad: String) -> Bool {
        // 解析并严格校验 canonical AAD；不能把任意字符串当成加密证据。
        let parts = aad.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0] == "stacio.v2",
              parts[1] == "conversationEvent",
              parts[2].isEmpty == false,
              parts[2].contains("|") == false,
              let sequence = Int(parts[3]),
              sequence > 0,
              parts[4] == "schema-\(schemaVersion)"
        else { return false }
        let recordType = String(parts[1])
        let recordID = String(parts[2])

        // seal → open 往返验证
        do {
            let sealed = try encryption.seal(
                payload: payload,
                conversationID: conversationID,
                recordType: recordType,
                recordID: recordID,
                candidateSequence: sequence,
                schemaVersion: schemaVersion
            )
            let reopened = try encryption.open(
                sealed,
                conversationID: conversationID,
                recordType: recordType,
                recordID: recordID,
                candidateSequence: sequence,
                schemaVersion: schemaVersion
            )
            // 往返数据必须与原始明文一致
            return reopened == payload
        } catch {
            // 加密/解密失败 → fail closed
            return false
        }
    }
}

// MARK: - 存储失败错误（P0-2 fail closed）

/// V2 存储装配失败时向用户显示的可恢复错误。
/// 不使用不安全 fallback（旧 InProcessFallbackSealing.verify 永远 true 已删除）；
/// 存储或 Keychain 不可用时必须 fail closed，向用户显示此错误并提供恢复入口。
public struct ConversationStorageError: Error, Equatable {
    public let summary: String
    public let recoveryHint: String

    public init(summary: String, recoveryHint: String) {
        self.summary = summary
        self.recoveryHint = recoveryHint
    }

    public static let keychainUnavailable = ConversationStorageError(
        summary: "无法访问 Keychain 主密钥",
        recoveryHint: "请检查钥匙串访问权限，或重启 App 后重试。"
    )

    public static let databaseUnavailable = ConversationStorageError(
        summary: "无法打开 V2 会话数据库",
        recoveryHint: "请检查磁盘空间和 App Support 目录权限。"
    )
}

// MARK: - 生产环境内存后备 Store（fail-closed 路径）

/// 仅当 `ConversationRepositoryV2`（Rust 独立库）打开失败时使用的进程内内存后备。
/// P0-2 fail closed：此 store 仅让桥接可实例化（不崩溃），但 `storageError` 标记会阻止实际发送。
/// 不持久化（重启丢失）；正常路径应使用 `ConversationRepositoryV2`。
public final class InProcessFallbackConversationStore: ConversationSessionStore, ConversationEventIdentityProviding {
    private var events: [(identity: ConversationEventIdentity, sequence: Int)] = []
    private var lastApplied: Int = 0
    private let lock = NSLock()

    public init() {}

    public func load() throws -> ConversationSessionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return ConversationSessionSnapshot(state: nil, lastAppliedSequence: lastApplied)
    }

    public func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        lock.lock(); defer { lock.unlock() }
        guard expectedLastSequence == lastApplied else {
            return .conflict(expected: expectedLastSequence, actual: lastApplied)
        }
        guard candidates.isEmpty == false else {
            return .storageFailure(reason: "empty candidate batch")
        }
        var expected = lastApplied
        for envelope in candidates {
            guard envelope.candidateSequence == expected + 1 else {
                return .storageFailure(reason: "sequence gap in fallback store")
            }
            expected = envelope.candidateSequence
        }
        // Validate the entire range before mutating memory so a malformed batch
        // cannot leave a partially advanced fallback projection.
        for envelope in candidates {
            events.append((ConversationEventIdentity(envelope: envelope), envelope.candidateSequence))
        }
        lastApplied = expected
        return .committed(lastSequence: lastApplied)
    }

    public func existingEventID(at sequence: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return events.first { $0.sequence == sequence }?.identity.eventID
    }

    public func existingPayloadHash(at sequence: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return events.first { $0.sequence == sequence }?.identity.payloadHash
    }

    public func existingEventIdentity(at sequence: Int) -> ConversationEventIdentity? {
        lock.lock(); defer { lock.unlock() }
        return events.first { $0.sequence == sequence }?.identity
    }
}

// MARK: - fail-closed 后备密封器

/// P0-2 fail closed：存储/Keychain 失败时的密封器。
/// `verifyRoundTrip` 永远返回 false（不通过验证 → Actor 不提交 → 无网络副作用）。
/// 仅让桥接可实例化；`storageError` 标记阻止用户发送。
public final class InProcessFallbackSealing: ConversationSealing {
    public init() {}

    public func verifyRoundTrip(payload: Data, aad: String) -> Bool {
        // fail closed：永远不通过验证
        false
    }
}
