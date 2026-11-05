import CryptoKit
import Foundation

// MARK: - AssistantSettingsStore（P4-2，持久化走 P3-11 settings.rs 后端）

/// Setting 值存储：Registry 校验（NeedsReview 语义）→ 可选加密（敏感 setting）
/// → P3-11 settings.rs 后端（revision CAS 持久化）。
public final class AssistantSettingsStore {
    private let backend: AssistantSettingsStoreBackend
    private let registry: AssistantSettingRegistry

    public init(backend: AssistantSettingsStoreBackend, registry: AssistantSettingRegistry) {
        self.backend = backend
        self.registry = registry
    }

    public enum StoreError: Error, Equatable {
        case unknownSetting(String)
        case needsReview(String)
        case wrongType(String)
        case outOfRange(String)
        case storage(String)
    }

    /// 写入 setting：先经 Registry resolve（未知/越界/类型错误 → 拒绝，不回退第一个选项）。
    public func write(id: String, value: SettingValue, scope: String, migrationKey: String) throws {
        switch registry.resolve(value: value, for: id) {
        case .valid(let validated):
            // valueDigest 不暴露正文（隔离 API）
            let digest = makeDigest(validated)
            do {
                try backend.upsert(
                    key: id, expectedRevision: nil, valueDigest: digest, scope: scope, migrationKey: migrationKey
                )
            } catch {
                throw StoreError.storage("\(error)")
            }
        case .needsReview:
            throw StoreError.needsReview(id)
        case .wrongType:
            throw StoreError.wrongType(id)
        case .outOfRange:
            throw StoreError.outOfRange(id)
        }
    }

    /// 读取 setting（revision + digest；不暴露正文）。
    public func read(id: String) throws -> (revision: Int64, digest: String)? {
        try backend.settingValue(key: id)
    }

    private func makeDigest(_ value: SettingValue) -> String {
        let body: Data
        switch value {
        case .string(let s): body = Data(s.utf8)
        case .int(let i): body = Data("\(i)".utf8)
        case .bool(let b): body = Data("\(b)".utf8)
        case .double(let d): body = Data("\(d)".utf8)
        case .stringArray(let a): body = Data(a.joined(separator: "\u{1f}").utf8)
        case .structured(let d): body = d
        }
        // 只存 digest 不存正文（隔离 API 约定）
        let digest = SHA256.hash(data: body)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
