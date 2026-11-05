import Foundation

// MARK: - Configuration Store 后端（P3-12，独立 Configuration Store）

/// Swift facade → CoreBridge configuration* → Rust Configuration Store 独立库。
/// UI 的 RuntimeConfigurationState 只由已提交事实计算（本库 configuration 表 + event audit）；
/// credential 只存引用不存权威；无 secret 存储。
public final class ConfigurationStoreBackend {
    private let handle: UInt64

    public init(databasePath: String) throws {
        handle = try CoreBridge.configurationOpen(path: databasePath)
    }

    deinit {
        CoreBridge.configurationClose(handle: handle)
    }

    /// revision CAS 写入（credential 只存引用，如 `credential-lifecycle:gen-7`）。
    public func upsert(
        configurationID: String, expectedRevision: Int64?, valueDigest: String, credentialReference: String
    ) throws {
        do {
            try CoreBridge.configurationUpsert(
                handle: handle, configurationId: configurationID, expectedRevision: expectedRevision,
                valueDigest: valueDigest, credentialReference: credentialReference
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// Publishes a verified runtime configuration as `active` in one Rust
    /// transaction. This is the only path Local Agent launch authority uses.
    @discardableResult
    public func commitVerified(
        configurationID: String,
        expectedRevision: Int64?,
        valueDigest: String,
        credentialReference: String,
        operationID: String,
        eventID: String
    ) throws -> Int64 {
        do {
            return try CoreBridge.configurationCommitVerified(
                handle: handle,
                configurationId: configurationID,
                expectedRevision: expectedRevision,
                valueDigest: valueDigest,
                credentialReference: credentialReference,
                operationId: operationID,
                eventId: eventID
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// Revision-CAS deletion with terminal state and audit written atomically
    /// by Rust. The sidecar owner removes its encrypted value around this call.
    @discardableResult
    public func delete(
        configurationID: String,
        expectedRevision: Int64,
        tombstoneDigest: String,
        operationID: String,
        eventID: String
    ) throws -> Int64 {
        do {
            return try CoreBridge.configurationDelete(
                handle: handle,
                configurationId: configurationID,
                expectedRevision: expectedRevision,
                tombstoneDigest: tombstoneDigest,
                operationId: operationID,
                eventId: eventID
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func snapshot(configurationID: String) throws -> (revision: Int64, digest: String, state: String)? {
        do {
            guard let record = try CoreBridge.configurationSnapshot(handle: handle, configurationId: configurationID) else {
                return nil
            }
            return (record.revision, record.valueDigest, record.state)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func transitionState(configurationID: String, to state: String) throws {
        do {
            try CoreBridge.configurationTransitionState(handle: handle, configurationId: configurationID, to: state)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 追加 runtime_configuration_event（关闭 kind 集合 + 幂等），返回 durable sequence。
    public func appendEvent(eventID: String, configurationID: String, operationID: String, kind: String) throws -> Int64 {
        do {
            return try CoreBridge.configurationAppendEvent(
                handle: handle, eventId: eventID, configurationId: configurationID,
                operationId: operationID, kind: kind
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// configuration-scoped audit。
    public func events(configurationID: String) throws -> [String] {
        do {
            return try CoreBridge.configurationEvents(handle: handle, configurationId: configurationID)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// operation-scoped 关联（与 settings 域事件合并后投影 NeedsReview）。
    public func eventsByOperation(operationID: String) throws -> [String] {
        do {
            return try CoreBridge.configurationEventsByOperation(handle: handle, operationId: operationID)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }
}
