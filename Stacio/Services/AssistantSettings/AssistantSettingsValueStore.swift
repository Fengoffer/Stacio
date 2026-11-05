import CryptoKit
import Foundation

/// Typed value persistence for the V2 settings surface.
///
/// `AssistantSettingsStoreBackend` deliberately stores only a digest.  The
/// settings UI still needs a value source, so this facade keeps the typed
/// payload in an atomic sidecar and uses the Rust backend as its revision/audit
/// index.  Sensitive and structured payloads are sealed before they touch disk.
public enum AssistantSettingsValueStoreError: Error, Equatable {
    case unknownSetting(String)
    case readOnly(String)
    case actionOnly(String)
    case migrationMismatch(String)
    case invalidValue(String)
    case missingMasterKey(String)
    case corruptedValue(String)
    case consistencyMismatch(String)
    case storage(String)
}

public final class AssistantSettingsValueStore {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var values: [String: StoredValue]
    }

    private struct StoredValue: Codable {
        var revision: Int64
        var sealed: Bool
        var payload: Data
    }

    private struct CodableValue: Codable {
        var type: SettingValueType
        var stringValue: String?
        var intValue: Int?
        var boolValue: Bool?
        var doubleValue: Double?
        var stringArrayValue: [String]?
        var dataValue: Data?

        init(_ value: SettingValue) {
            switch value {
            case .string(let value):
                type = .string; stringValue = value
            case .int(let value):
                type = .int; intValue = value
            case .bool(let value):
                type = .bool; boolValue = value
            case .double(let value):
                type = .double; doubleValue = value
            case .stringArray(let value):
                type = .stringArray; stringArrayValue = value
            case .structured(let value):
                type = .structured; dataValue = value
            }
        }

        func settingValue() -> SettingValue? {
            switch type {
            case .string:
                guard let stringValue else { return nil }
                return .string(stringValue)
            case .int:
                guard let intValue else { return nil }
                return .int(intValue)
            case .bool:
                guard let boolValue else { return nil }
                return .bool(boolValue)
            case .double:
                guard let doubleValue else { return nil }
                return .double(doubleValue)
            case .stringArray:
                guard let stringArrayValue else { return nil }
                return .stringArray(stringArrayValue)
            case .structured:
                guard let dataValue else { return nil }
                return .structured(dataValue)
            }
        }
    }

    private let registry: AssistantSettingRegistry
    private let backend: AssistantSettingsStoreBackend?
    private let fileURL: URL?
    private let masterKeyProvider: ConversationMasterKeyProviding?
    private let fileManager: FileManager
    private var envelope: Envelope
    private let lock = NSLock()

    public init(
        registry: AssistantSettingRegistry,
        backend: AssistantSettingsStoreBackend? = nil,
        fileURL: URL? = nil,
        masterKeyProvider: ConversationMasterKeyProviding? = KeychainConversationMasterKeyProvider.shared,
        fileManager: FileManager = .default
    ) throws {
        self.registry = registry
        self.backend = backend
        self.fileURL = fileURL
        self.masterKeyProvider = masterKeyProvider
        self.fileManager = fileManager
        if let fileURL, fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                self.envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard self.envelope.schemaVersion == 1 else {
                    throw AssistantSettingsValueStoreError.corruptedValue("settings schema")
                }
            } catch let error as AssistantSettingsValueStoreError {
                throw error
            } catch {
                throw AssistantSettingsValueStoreError.storage("无法读取设置值")
            }
        } else {
            self.envelope = Envelope(schemaVersion: 1, values: [:])
        }
        try validateBackendConsistency()
    }

    /// A memory-only store is useful for tests and for a read-only degraded UI.
    /// Sensitive writes still fail closed because no master key is supplied.
    public static func inMemory(
        registry: AssistantSettingRegistry,
        masterKeyProvider: ConversationMasterKeyProviding? = nil
    ) -> AssistantSettingsValueStore? {
        try? AssistantSettingsValueStore(
            registry: registry,
            backend: nil,
            fileURL: nil,
            masterKeyProvider: masterKeyProvider
        )
    }

    public func descriptor(for id: String) -> SettingDescriptor? {
        registry.descriptor(for: id)
    }

    /// Returns the stored value, or the Registry default when it has not been
    /// customized. A malformed/corrupted stored value is never replaced by a
    /// default silently.
    public func value(for id: String) throws -> SettingValue {
        lock.lock()
        defer { lock.unlock() }
        try validateBackendConsistency()
        guard let descriptor = registry.descriptor(for: id) else {
            throw AssistantSettingsValueStoreError.unknownSetting(id)
        }
        guard let stored = envelope.values[id] else {
            return descriptor.defaultValue
        }
        let valueData: Data
        if stored.sealed {
            guard let masterKeyProvider else {
                throw AssistantSettingsValueStoreError.missingMasterKey(id)
            }
            do {
                valueData = try AssistantPreferenceContentKey.open(
                    sealed: stored.payload,
                    settingID: id,
                    revision: Int(stored.revision),
                    masterKeyData: try masterKeyProvider.masterKeyData()
                )
            } catch {
                throw AssistantSettingsValueStoreError.corruptedValue(id)
            }
        } else {
            valueData = stored.payload
        }
        guard let value = try? JSONDecoder().decode(CodableValue.self, from: valueData).settingValue(),
              case .valid = registry.resolve(value: value, for: id)
        else {
            throw AssistantSettingsValueStoreError.corruptedValue(id)
        }
        return value
    }

    /// `nil` distinguishes an untouched setting from a Registry default.
    public func storedValue(for id: String) throws -> SettingValue? {
        lock.lock()
        let exists = envelope.values[id] != nil
        lock.unlock()
        return exists ? try value(for: id) : nil
    }

    /// Registry-validated write. The sidecar is written before the metadata
    /// CAS; a failed CAS restores the previous sidecar snapshot.
    @discardableResult
    public func write(
        id: String,
        value: SettingValue,
        scope: String? = nil,
        migrationKey: String? = nil
    ) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try writeLocked(
            id: id,
            value: value,
            scope: scope,
            migrationKey: migrationKey,
            allowActionOnly: false
        )
    }

    /// Action-only setting 的受控写入口。只有 Registry 声明的绑定 Action
    /// 才能使用它；普通 `write` 仍会拒绝 actionOnly，避免批量 setter 绕过
    /// Permit/audit 入口。
    @discardableResult
    public func writeActionValue(
        id: String,
        value: SettingValue,
        actionID: String,
        scope: String? = nil,
        migrationKey: String? = nil
    ) throws -> Int64 {
        guard AssistantSettingsActionBinding.actionID(for: id) == actionID else {
            throw AssistantSettingsValueStoreError.actionOnly(id)
        }
        lock.lock()
        defer { lock.unlock() }
        return try writeLocked(
            id: id,
            value: value,
            scope: scope,
            migrationKey: migrationKey,
            allowActionOnly: true
        )
    }

    @discardableResult
    public func reset(id: String) throws -> Int64 {
        guard let descriptor = registry.descriptor(for: id) else {
            throw AssistantSettingsValueStoreError.unknownSetting(id)
        }
        return try write(id: id, value: descriptor.defaultValue)
    }

    /// Redacted snapshot for diagnostics/export. Secret payloads are omitted.
    public func redactedSnapshot() -> [String: SettingValue] {
        lock.lock()
        let ids = envelope.values.keys.sorted()
        lock.unlock()
        var result: [String: SettingValue] = [:]
        for id in ids {
            guard let descriptor = registry.descriptor(for: id),
                  descriptor.exportPolicy != .alwaysExclude,
                  let value = try? value(for: id)
            else { continue }
            result[id] = descriptor.exportPolicy == .includeRedacted
                ? redacted(value)
                : value
        }
        return result
    }

    private func encodedPayload(
        value: SettingValue,
        descriptor: SettingDescriptor,
        id: String,
        revision: Int64
    ) throws -> (data: Data, sealed: Bool) {
        let plain = try JSONEncoder().encode(CodableValue(value))
        let shouldSeal = descriptor.sensitivity == .sensitive
            || descriptor.sensitivity == .secret
            || descriptor.sensitivity == .credential
            || descriptor.valueType == .structured
        guard shouldSeal else { return (plain, false) }
        guard let masterKeyProvider else {
            throw AssistantSettingsValueStoreError.missingMasterKey(id)
        }
        do {
            let key = try masterKeyProvider.masterKeyData()
            return (
                try AssistantPreferenceContentKey.seal(
                    value: plain, settingID: id, revision: Int(revision), masterKeyData: key
                ),
                true
            )
        } catch {
            throw AssistantSettingsValueStoreError.missingMasterKey(id)
        }
    }

    /// 双写存储的 fail-closed 校验。sidecar 和 backend 任一方缺失、revision/
    /// migration metadata 不一致，或 payload digest 不匹配，都不得继续读取/覆盖。
    /// 这会把“进程恰好死在双写窗口”的状态暴露为待恢复，而不是静默回退默认值。
    private func validateBackendConsistency() throws {
        guard let backend else { return }

        let backendKeys: Set<String>
        do {
            backendKeys = Set(try backend.settingKeys())
        } catch {
            throw AssistantSettingsValueStoreError.storage("设置一致性读取失败")
        }
        let sidecarKeys = Set(envelope.values.keys)
        guard backendKeys == sidecarKeys else {
            let missingSidecar = backendKeys.subtracting(sidecarKeys).sorted().joined(separator: ",")
            let missingBackend = sidecarKeys.subtracting(backendKeys).sorted().joined(separator: ",")
            throw AssistantSettingsValueStoreError.consistencyMismatch(
                "keys:backendOnly=\(missingSidecar);sidecarOnly=\(missingBackend)"
            )
        }

        for id in sidecarKeys {
            guard let descriptor = registry.descriptor(for: id),
                  let stored = envelope.values[id]
            else {
                throw AssistantSettingsValueStoreError.corruptedValue(id)
            }
            let metadata: (revision: Int64, digest: String, scope: String, migrationKey: String)
            do {
                guard let value = try backend.settingValue(key: id),
                      let details = try backend.settingMetadata(key: id)
                else {
                    throw AssistantSettingsValueStoreError.consistencyMismatch("missing backend metadata: \(id)")
                }
                metadata = (value.revision, value.digest, details.scope, details.migrationKey)
            } catch let error as AssistantSettingsValueStoreError {
                throw error
            } catch {
                throw AssistantSettingsValueStoreError.storage("设置一致性读取失败")
            }
            guard stored.revision == metadata.revision,
                  metadata.revision > 0,
                  metadata.migrationKey == descriptor.migrationKey,
                  !metadata.scope.isEmpty
            else {
                throw AssistantSettingsValueStoreError.consistencyMismatch("metadata: \(id)")
            }
            let decoded = try decodedValue(from: stored, id: id)
            guard case .valid = registry.resolve(value: decoded, for: id),
                  digest(decoded) == metadata.digest
            else {
                throw AssistantSettingsValueStoreError.consistencyMismatch("digest: \(id)")
            }
        }
    }

    private func decodedValue(from stored: StoredValue, id: String) throws -> SettingValue {
        let valueData: Data
        if stored.sealed {
            guard let masterKeyProvider else {
                throw AssistantSettingsValueStoreError.missingMasterKey(id)
            }
            do {
                valueData = try AssistantPreferenceContentKey.open(
                    sealed: stored.payload,
                    settingID: id,
                    revision: Int(stored.revision),
                    masterKeyData: try masterKeyProvider.masterKeyData()
                )
            } catch {
                throw AssistantSettingsValueStoreError.corruptedValue(id)
            }
        } else {
            valueData = stored.payload
        }
        guard let value = try? JSONDecoder().decode(CodableValue.self, from: valueData).settingValue() else {
            throw AssistantSettingsValueStoreError.corruptedValue(id)
        }
        return value
    }

    private func writeLocked(
        id: String,
        value: SettingValue,
        scope: String?,
        migrationKey: String?,
        allowActionOnly: Bool
    ) throws -> Int64 {
        try validateBackendConsistency()
        guard let descriptor = registry.descriptor(for: id) else {
            throw AssistantSettingsValueStoreError.unknownSetting(id)
        }
        switch descriptor.writeControlPolicy {
        case .readOnlyProjection:
            throw AssistantSettingsValueStoreError.readOnly(id)
        case .actionOnly where !allowActionOnly:
            throw AssistantSettingsValueStoreError.actionOnly(id)
        case .actionOnly, .userWritable:
            break
        }
        guard migrationKey == nil || migrationKey == descriptor.migrationKey else {
            throw AssistantSettingsValueStoreError.migrationMismatch(id)
        }
        guard case .valid = registry.resolve(value: value, for: id) else {
            throw AssistantSettingsValueStoreError.invalidValue(id)
        }

        let currentRevision: Int64
        if let backend {
            do {
                currentRevision = try backend.settingValue(key: id)?.revision ?? 0
            } catch {
                throw AssistantSettingsValueStoreError.storage("设置版本读取失败")
            }
        } else {
            currentRevision = envelope.values[id]?.revision ?? 0
        }
        let nextRevision = currentRevision + 1
        let payload = try encodedPayload(value: value, descriptor: descriptor, id: id, revision: nextRevision)
        let oldEnvelope = envelope
        envelope.values[id] = StoredValue(revision: nextRevision, sealed: payload.sealed, payload: payload.data)
        do {
            try persistEnvelope()
            if let backend {
                try backend.upsert(
                    key: id,
                    expectedRevision: currentRevision == 0 ? nil : currentRevision,
                    valueDigest: digest(value),
                    scope: scope ?? descriptor.scope.rawValue,
                    migrationKey: migrationKey ?? descriptor.migrationKey
                )
            }
        } catch let error as AssistantSettingsValueStoreError {
            envelope = oldEnvelope
            try? persistEnvelope()
            throw error
        } catch {
            envelope = oldEnvelope
            try? persistEnvelope()
            throw AssistantSettingsValueStoreError.storage("设置保存失败")
        }
        return nextRevision
    }

    private func persistEnvelope() throws {
        guard let fileURL else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw AssistantSettingsValueStoreError.storage("设置值文件写入失败")
        }
    }

    private func digest(_ value: SettingValue) -> String {
        let body: Data
        switch value {
        case .string(let value): body = Data(value.utf8)
        case .int(let value): body = Data(String(value).utf8)
        case .bool(let value): body = Data(String(value).utf8)
        case .double(let value): body = Data(String(value).utf8)
        case .stringArray(let value): body = Data(value.joined(separator: "\u{1f}").utf8)
        case .structured(let value): body = value
        }
        let hash = SHA256.hash(data: body)
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    private func redacted(_ value: SettingValue) -> SettingValue {
        switch value {
        case .string(let value): return .string(value.isEmpty ? "" : "[已隐藏]")
        case .stringArray(let value): return .stringArray(value.map { _ in "[已隐藏]" })
        case .structured: return .structured(Data("[已隐藏]".utf8))
        case .int, .bool, .double: return value
        }
    }
}

/// The live app must have exactly one in-process owner for the settings
/// sidecar. Multiple cached stores can otherwise overwrite each other's
/// snapshots even when the metadata backend correctly rejects a stale CAS.
@MainActor
public enum AssistantSettingsLiveStore {
    private static var cachedStore: AssistantSettingsValueStore?

    public static func shared() throws -> AssistantSettingsValueStore {
        if let cachedStore { return cachedStore }

        let registry = try AssistantSettingRegistry.standard()
        let paths = try StacioPaths()
        let databaseURL = paths.applicationSupportDirectory
            .appendingPathComponent("assistant-settings.sqlite3")
        let valuesURL = paths.applicationSupportDirectory
            .appendingPathComponent("assistant-settings-values-v1.json")
        let backend = try AssistantSettingsStoreBackend(databasePath: databaseURL.path)
        let store = try AssistantSettingsValueStore(
            registry: registry,
            backend: backend,
            fileURL: valuesURL,
            masterKeyProvider: KeychainConversationMasterKeyProvider.shared
        )
        cachedStore = store
        return store
    }

    public static func sharedIfAvailable() -> AssistantSettingsValueStore? {
        try? shared()
    }
}
