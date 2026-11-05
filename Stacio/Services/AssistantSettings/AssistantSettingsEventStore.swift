import Foundation

// MARK: - AssistantSettingsEventStore（P4-2，durable sequence 走 P3-11 settings.rs 后端）

/// 单写入 audit：requested/committed/cancelled/failed/reconciliationRequired/settled；
/// 成功 Setting mutation 写 committed + settled 双事件；
/// `actionSettled` 的前置证据（actionRequested）由 Rust settings 域校验。
public final class AssistantSettingsEventStore {
    private let backend: AssistantSettingsStoreBackend

    public init(backend: AssistantSettingsStoreBackend) {
        self.backend = backend
    }

    // MARK: - Action audit

    public func requested(actionID: String, operationID: String) throws {
        _ = try backend.appendEvent(
            eventID: "\(operationID).requested", operationID: operationID, kind: "actionRequested"
        )
    }

    public func cancelled(actionID: String, operationID: String) throws {
        _ = try backend.appendEvent(
            eventID: "\(operationID).cancelled", operationID: operationID, kind: "actionCancelled"
        )
    }

    public func failed(actionID: String, operationID: String) throws {
        _ = try backend.appendEvent(
            eventID: "\(operationID).failed", operationID: operationID, kind: "actionFailed"
        )
    }

    public func reconciliationRequired(actionID: String, operationID: String) throws {
        _ = try backend.appendEvent(
            eventID: "\(operationID).reconciliationRequired", operationID: operationID,
            kind: "actionReconciliationRequired"
        )
    }

    /// actionSettled：Rust 侧要求同 operation 已有 actionRequested 证据
    /// （Permit 已结算但异步 Action 未取得业务结果时不允许提前 settled）。
    public func settled(actionID: String, operationID: String) throws {
        _ = try backend.appendEvent(
            eventID: "\(operationID).settled", operationID: operationID, kind: "actionSettled"
        )
    }

    // MARK: - Setting mutation audit（成功 mutation 写 committed + settled 双事件）

    public func mutationCommittedAndSettled(operationID: String) throws {
        _ = try backend.appendEvent(
            eventID: "\(operationID).mutationCommitted", operationID: operationID,
            kind: "settingMutationCommitted"
        )
        _ = try backend.appendEvent(
            eventID: "\(operationID).mutationSettled", operationID: operationID,
            kind: "settingMutationSettled"
        )
    }

    /// operation-scoped audit 快照（按 sequence 排序）。
    public func events(operationID: String) throws -> [String] {
        try backend.events(operationID: operationID)
    }
}
