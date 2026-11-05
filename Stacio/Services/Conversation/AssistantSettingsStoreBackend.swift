import Foundation

// MARK: - AssistantSettingsStore 后端（P3-11，独立设置域）

/// Swift facade → CoreBridge settings* → Rust 设置域独立库。
/// 只读/隔离后端 API：只暴露 setting key/revision/digest/scope/migrationKey 与事件 audit，
/// 不暴露 secret/prompt/路径正文/capability token。
public final class AssistantSettingsStoreBackend {
    private let handle: UInt64

    public init(databasePath: String) throws {
        handle = try CoreBridge.settingsOpen(path: databasePath)
    }

    deinit {
        CoreBridge.settingsClose(handle: handle)
    }

    /// expected-revision CAS 写入（revision 递增）。
    public func upsert(
        key: String, expectedRevision: Int64?, valueDigest: String,
        scope: String, migrationKey: String
    ) throws {
        do {
            try CoreBridge.settingsUpsert(
                handle: handle, key: key, expectedRevision: expectedRevision,
                valueDigest: valueDigest, scope: scope, migrationKey: migrationKey
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func settingValue(key: String) throws -> (revision: Int64, digest: String)? {
        do {
            guard let snapshot = try CoreBridge.settingsValue(handle: handle, key: key) else {
                return nil
            }
            return (snapshot.revision, snapshot.valueDigest)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func settingMetadata(key: String) throws -> (scope: String, migrationKey: String)? {
        do {
            guard let snapshot = try CoreBridge.settingsMetadata(handle: handle, key: key) else {
                return nil
            }
            return (snapshot.scope, snapshot.migrationKey)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 已提交 key 列表；只用于 sidecar/backend 双向一致性检查。
    public func settingKeys() throws -> [String] {
        do {
            return try CoreBridge.settingsKeys(handle: handle)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 追加 audit 事件（关闭 kind 集合 + settled 前置证据 + 幂等），返回 durable sequence。
    public func appendEvent(eventID: String, operationID: String, kind: String) throws -> Int64 {
        do {
            return try CoreBridge.settingsAppendEvent(
                handle: handle, eventId: eventID, operationId: operationID, kind: kind
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func nextSequence() throws -> Int64 {
        do {
            return try CoreBridge.settingsNextSequence(handle: handle)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// operation-scoped audit（按 sequence 排序）。
    public func events(operationID: String) throws -> [String] {
        do {
            return try CoreBridge.settingsEvents(handle: handle, operationId: operationID)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }
}
