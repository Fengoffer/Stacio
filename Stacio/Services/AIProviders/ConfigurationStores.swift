import CryptoKit
import Foundation

// MARK: - RuntimeConfigurationMetadataKey（P4-4，独立 Keychain-backed 加密域）

public enum RuntimeConfigurationMetadataError: Error, Equatable {
    case invalidMasterKey
    case authenticationFailed
    case cryptoFailure
}

/// 配置 metadata（自定义名称、内网 Base URL、proxy origin、自定义 header 值、
/// 本地路径/环境 metadata）的独立加密域：
/// - 与 `AssistantPreferenceContentKey` 加密域分离（不同 HKDF info）；
/// - 与 V2 会话主密钥、各 Credential Keychain item 分离；
/// - 列表只为检索保留 ID/类型/状态（不含内容）；重置偏好后仍可解密恢复。
public enum RuntimeConfigurationMetadataKey {
    public static let domain = "stacio.runtimeConfigurationMetadata"

    public static func deriveKey(masterKeyData: Data) -> SymmetricKey {
        let info = Data("stacio.v2|runtimeConfigurationMetadataKey|v1".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKeyData),
            salt: Data(domain.utf8),
            info: info,
            outputByteCount: 32
        )
    }

    /// AAD = `stacio.runtimeConfigurationMetadata|configurationID|field|schema-1`。
    public static func seal(value: Data, configurationID: String, field: String, masterKeyData: Data) throws -> Data {
        guard !masterKeyData.isEmpty else {
            throw RuntimeConfigurationMetadataError.invalidMasterKey
        }
        let aad = Data("\(domain)|\(configurationID)|\(field)|schema-1".utf8)
        do {
            let box = try AES.GCM.seal(value, using: deriveKey(masterKeyData: masterKeyData), authenticating: aad)
            guard let combined = box.combined else {
                throw RuntimeConfigurationMetadataError.cryptoFailure
            }
            return combined
        } catch {
            throw RuntimeConfigurationMetadataError.cryptoFailure
        }
    }

    public static func open(sealed: Data, configurationID: String, field: String, masterKeyData: Data) throws -> Data {
        guard !masterKeyData.isEmpty else {
            throw RuntimeConfigurationMetadataError.invalidMasterKey
        }
        let aad = Data("\(domain)|\(configurationID)|\(field)|schema-1".utf8)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: deriveKey(masterKeyData: masterKeyData), authenticating: aad)
        } catch {
            throw RuntimeConfigurationMetadataError.authenticationFailed
        }
    }

    /// 加密域隔离断言：RuntimeConfigurationMetadataKey 派生 info 与
    /// AssistantPreferenceContentKey 不同（两域不得共用密钥材料路径）。
    public static func isDomainSeparatedFromPreferenceContentKey() -> Bool {
        Self.domain != AssistantPreferenceContentKey.domain
    }
}

// MARK: - 配置 metadata 列表（只为检索保留 ID/类型/状态）

public struct ConfigurationMetadataListEntry: Codable, Equatable, Sendable {
    public let configurationID: String
    public let kind: ConfigurationKind
    public let state: String

    public init(configurationID: String, kind: ConfigurationKind, state: String) {
        self.configurationID = configurationID
        self.kind = kind
        self.state = state
    }
}

public enum ConfigurationKind: String, Codable, Equatable, Hashable, Sendable {
    case provider
    case codingPlan
    case localAgent
}

// MARK: - Provider Configuration Store（CRUD + revision + digest；状态由 Projector 计算）

public final class ProviderConfigurationStore {
    private let backend: ConfigurationStoreBackend

    public init(backend: ConfigurationStoreBackend) {
        self.backend = backend
    }

    public func upsert(configurationID: String, expectedRevision: Int64?, valueDigest: String, credentialReference: String) throws {
        try backend.upsert(
            configurationID: configurationID, expectedRevision: expectedRevision,
            valueDigest: valueDigest, credentialReference: credentialReference
        )
    }

    public func snapshot(configurationID: String) throws -> (revision: Int64, digest: String, state: String)? {
        try backend.snapshot(configurationID: configurationID)
    }

    /// 状态唯一由 Projector 计算（本 Store 不接受外部赋值）。
    public func projectedState(_ input: ProviderProjectionInput) -> ProviderConfigurationState {
        RuntimeConfigurationStateProjector.projectProvider(input)
    }
}

// MARK: - Coding Plan Configuration Store

public final class CodingPlanConfigurationStore {
    private let backend: ConfigurationStoreBackend

    public init(backend: ConfigurationStoreBackend) {
        self.backend = backend
    }

    public func upsert(configurationID: String, expectedRevision: Int64?, valueDigest: String, credentialReference: String) throws {
        try backend.upsert(
            configurationID: configurationID, expectedRevision: expectedRevision,
            valueDigest: valueDigest, credentialReference: credentialReference
        )
    }

    public func snapshot(configurationID: String) throws -> (revision: Int64, digest: String, state: String)? {
        try backend.snapshot(configurationID: configurationID)
    }
}
