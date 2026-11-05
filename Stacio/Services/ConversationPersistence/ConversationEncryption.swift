import CryptoKit
import Foundation

// MARK: - 主密钥提供（V2 master key）

public protocol ConversationMasterKeyProviding {
    func masterKeyData() throws -> Data
}

public enum ConversationEncryptionError: Error, Equatable {
    /// 主密钥不可用
    case masterKeyUnavailable
    /// 解密/验证失败 → 只读损坏隔离（不是缺失 payload，不自动重加密覆盖）
    case authenticationFailed
    case invalidSealedBox
}

// MARK: - 密封负载值

public struct SealedConversationPayload: Equatable, Sendable {
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
    public var cipherVersion: String

    public init(nonce: Data, ciphertext: Data, tag: Data, cipherVersion: String) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.cipherVersion = cipherVersion
    }
}

// MARK: - ConversationEncryption（canonical AAD sealed box，规格 §15.1）

/// V2 会话加密 facade：HKDF 派生会话密钥 + 每条敏感记录独立 nonce 的 AES-GCM sealed box。
///
/// - canonical AAD = record type + ID + candidate sequence + schema version，不接受调用方另传任意 AAD；
/// - 提交前本地 sealed-box 验证（tag/AAD 失败不提交）；
/// - Loader 每次解密再验证：失败进入只读损坏隔离（抛 `authenticationFailed`），
///   不视为缺失 payload、不自动重加密覆盖。
public final class ConversationEncryption {
    private let masterKey: SymmetricKey
    public static let cipherVersion = "stacio.aes-256-gcm.v1"
    private static let hkdfInfoPrefix = "stacio.v2.conversation-key"

    public init(masterKey: SymmetricKey) {
        self.masterKey = masterKey
    }

    public convenience init(masterKeyData: Data) {
        self.init(masterKey: SymmetricKey(data: masterKeyData))
    }

    public convenience init(masterKeyProvider: ConversationMasterKeyProviding) throws {
        let data = try masterKeyProvider.masterKeyData()
        self.init(masterKeyData: data)
    }

    /// HKDF 以 conversation ID + schema generation 派生会话密钥。
    public func sessionKey(conversationID: String, schemaGeneration: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data(conversationID.utf8),
            info: Data("\(Self.hkdfInfoPrefix)|gen-\(schemaGeneration)".utf8),
            outputByteCount: 32
        )
    }

    /// canonical AAD：record type + ID + candidate sequence + schema version。
    /// 不接受调用方另传任意 AAD——AAD 必须由记录字段固定派生。
    public static func canonicalAAD(
        recordType: String,
        recordID: String,
        candidateSequence: Int,
        schemaVersion: Int
    ) -> String {
        "stacio.v2|\(recordType)|\(recordID)|\(candidateSequence)|schema-\(schemaVersion)"
    }

    /// 每条敏感记录独立 nonce + AES-GCM sealed box。
    public func seal(
        payload: Data,
        conversationID: String,
        recordType: String,
        recordID: String,
        candidateSequence: Int,
        schemaVersion: Int
    ) throws -> SealedConversationPayload {
        let key = sessionKey(conversationID: conversationID, schemaGeneration: schemaVersion)
        let nonce = AES.GCM.Nonce()
        let aad = Self.canonicalAAD(
            recordType: recordType,
            recordID: recordID,
            candidateSequence: candidateSequence,
            schemaVersion: schemaVersion
        )
        let sealed = try AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: Data(aad.utf8))
        return SealedConversationPayload(
            nonce: nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            cipherVersion: Self.cipherVersion
        )
    }

    /// 提交前本地 sealed-box 验证（tag/AAD 失败返回 false，不提交）。
    public func verifySealedBox(
        _ box: SealedConversationPayload,
        conversationID: String,
        recordType: String,
        recordID: String,
        candidateSequence: Int,
        schemaVersion: Int
    ) -> Bool {
        (try? open(
            box,
            conversationID: conversationID,
            recordType: recordType,
            recordID: recordID,
            candidateSequence: candidateSequence,
            schemaVersion: schemaVersion
        )) != nil
    }

    /// Loader 解密：每次解密再验证；失败抛 `authenticationFailed`（只读损坏隔离）。
    public func open(
        _ box: SealedConversationPayload,
        conversationID: String,
        recordType: String,
        recordID: String,
        candidateSequence: Int,
        schemaVersion: Int
    ) throws -> Data {
        guard box.cipherVersion == Self.cipherVersion else {
            throw ConversationEncryptionError.invalidSealedBox
        }
        guard let nonce = try? AES.GCM.Nonce(data: box.nonce) else {
            throw ConversationEncryptionError.invalidSealedBox
        }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: box.ciphertext, tag: box.tag)
        } catch {
            throw ConversationEncryptionError.invalidSealedBox
        }
        let key = sessionKey(conversationID: conversationID, schemaGeneration: schemaVersion)
        let aad = Self.canonicalAAD(
            recordType: recordType,
            recordID: recordID,
            candidateSequence: candidateSequence,
            schemaVersion: schemaVersion
        )
        do {
            return try AES.GCM.open(sealed, using: key, authenticating: Data(aad.utf8))
        } catch {
            // tag/AAD 失败 → 只读损坏隔离（不是缺失 payload，不自动重加密覆盖）
            throw ConversationEncryptionError.authenticationFailed
        }
    }
}

// MARK: - Keychain 主密钥 provider

/// 真实 Keychain 主密钥 provider（经 KeychainCredentialStore 保存/读取 V2 master key）。
/// 首次访问时生成并保存；后续读取同一主密钥。
public enum KeychainConversationMasterKeyProvider: ConversationMasterKeyProviding {
    public static let storageKeyID = "stacio.v2.conversation-master-key"
    public static let storageKeyAccount = "stacio-conversation-v2"
    private static let initializationLock = NSLock()

    case shared

    public func masterKeyData() throws -> Data {
        // Serialize the read-create sequence inside the process. Without this,
        // two windows opening their first V2 session can generate different keys
        // and one of the databases becomes undecryptable after restart.
        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
        let store = KeychainCredentialStore()
        do {
            let existing = try store.readSecret(id: Self.storageKeyID, account: Self.storageKeyAccount)
            guard let decoded = Data(base64Encoded: existing), decoded.count == 32 else {
                // 已存在但内容损坏时绝不生成新密钥覆盖，否则历史会话将永久不可解密。
                throw ConversationEncryptionError.masterKeyUnavailable
            }
            return decoded
        } catch KeychainCredentialError.notFound {
            // 只有明确不存在时才允许首次创建。
        } catch let error as ConversationEncryptionError {
            throw error
        } catch {
            throw ConversationEncryptionError.masterKeyUnavailable
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ConversationEncryptionError.masterKeyUnavailable
        }
        let newKey = Data(bytes)
        do {
            try store.save(
                KeychainCredential(
                    id: Self.storageKeyID,
                    account: Self.storageKeyAccount,
                    secret: newKey.base64EncodedString()
                )
            )
        } catch {
            throw ConversationEncryptionError.masterKeyUnavailable
        }
        return newKey
    }
}
