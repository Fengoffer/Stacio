import Foundation

// MARK: - External Effect reconciliation（P3-9）

/// External Effect 状态：`unknown`（远端 effect 转锁）→ 终态。
/// 终态：`isolated` / `verifiedCompleted` / `verifiedFailed` / `noop`。
public enum ExternalEffectState: String, Equatable, Sendable {
    case unknown
    case isolated
    case verifiedCompleted
    case verifiedFailed
    case noop

    public var isTerminal: Bool {
        switch self {
        case .isolated, .verifiedCompleted, .verifiedFailed, .noop: return true
        case .unknown: return false
        }
    }
}

/// 证据强度等级：`none < structured < verified`。
/// `verifiedCompleted` 需要 verified 级证据（structured 不够）。
public enum ExternalEffectEvidenceStrength: String, Equatable, Sendable {
    case none
    case structured
    case verified
}

// MARK: - Reconciliation 协调器

/// External Effect reconciliation 协调器：Swift facade → CoreBridge reconciliation* → Rust 独立库。
///
/// - `conflictKey`：`TargetBinding.digest + resourceScope + operationClass` 稳定组合；
/// - 每条记录冻结 evidence strength；
/// - 同 key 全记录终结前锁不释放；
/// - unknown 远端 effect 转锁不永久占全局 Admission。
public final class ExternalEffectReconciliationCoordinator {
    private let handle: UInt64

    public init(databasePath: String) throws {
        handle = try CoreBridge.reconciliationOpen(path: databasePath)
    }

    deinit {
        CoreBridge.reconciliationClose(handle: handle)
    }

    /// 稳定 conflictKey：target digest + resource scope + operation class。
    public static func conflictKey(targetDigest: String, resourceScope: String, operationClass: String) -> String {
        CoreBridge.reconciliationConflictKey(
            targetDigest: targetDigest, resourceScope: resourceScope, operationClass: operationClass
        )
    }

    public func createRecord(effectID: String, conflictKey: String, state: ExternalEffectState) throws {
        do {
            try CoreBridge.reconciliationCreateRecord(
                handle: handle, effectId: effectID, conflictKey: conflictKey, state: state.rawValue
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func createRecord(
        effectID: String,
        conflictKey: String,
        state: ExternalEffectState,
        evidenceStrength: ExternalEffectEvidenceStrength
    ) throws {
        do {
            try CoreBridge.reconciliationCreateRecordWithStrength(
                handle: handle, effectId: effectID, conflictKey: conflictKey,
                state: state.rawValue, evidenceStrength: evidenceStrength.rawValue
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 同 key 全记录终结前锁不释放。
    public func lockReleased(conflictKey: String) throws -> Bool {
        do {
            return try CoreBridge.reconciliationLockReleased(handle: handle, conflictKey: conflictKey)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func lockOwner(conflictKey: String) throws -> String {
        do {
            return try CoreBridge.reconciliationLockOwner(handle: handle, conflictKey: conflictKey)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// unknown 远端 effect 锁不占全局 Admission（仅已识别且在途记录占用）。
    public func holdsGlobalAdmission(conflictKey: String) throws -> Bool {
        do {
            return try CoreBridge.reconciliationHoldsGlobalAdmission(handle: handle, conflictKey: conflictKey)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func evidenceStrength(effectID: String) throws -> ExternalEffectEvidenceStrength {
        do {
            let raw = try CoreBridge.reconciliationEvidenceStrength(handle: handle, effectId: effectID)
            guard let strength = ExternalEffectEvidenceStrength(rawValue: raw) else {
                throw V2ControlError.storage("unknown evidence strength: \(raw)")
            }
            return strength
        } catch let error as V2ControlError {
            throw error
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 结算记录：unknown → 终态；弱证据不得结算 verifiedCompleted。
    public func settleRecord(effectID: String, settlement: ExternalEffectState) throws {
        do {
            try CoreBridge.reconciliationSettleRecord(
                handle: handle, effectId: effectID, settlement: settlement.rawValue
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }
}
