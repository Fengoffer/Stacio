import Foundation

// MARK: - V2ControlPermitState 扩展

public extension V2ControlPermitState {
    var isTerminal: Bool {
        self == .settledCommitted || self == .settledAborted
    }
}

// MARK: - Credential setup 操作的 Permit 接线（P3-8c 后置部分，P3-9 落地后实施）

/// 14 个 operation kind 中经 Permit 的 credential 操作（§8.1 首版 contract 子集）。
public enum CredentialOperationKind: String, Equatable, Sendable {
    case credentialSetupCreate
    case credentialOriginCopy
    case credentialRotation
    case proxyCredentialRotation
    case configurationActivation
}

public enum CredentialPermitWiringError: Error, Equatable {
    /// Keychain staging 只允许在 settling 阶段写入（settlement-start 持久化之后）。
    case stagingRequiresSettling(permitID: String)
    case stagingNotFound(permitID: String, id: String)
    case stagingPromotionFailed(permitID: String, id: String, reason: String)
    case notFound(id: String)
    case storage(String)
}

/// Credential setup/rotation/activation 经 V2ControlAdmissionPermit 的接线 + Keychain staging。
///
/// - `settling` 阶段才写 Runtime 不可访问的 staging item（staging service 与正式 service 分离，
///   Runtime 读取路径只走正式 service）；
/// - 目标提交（settledCommitted）时 staging 提升为正式键并删除 staging；
/// - 目标未提交（settledAborted/expiry）时删除 staging（quarantine 语义：不可恢复读取）；
/// - resume 必须签发新 Permit（旧 Permit 已结算的不可复用）。
public final class CredentialPermitWiring {
    /// staging 与正式隔离：Runtime 读取只走 `KeychainCredentialStore.serviceName`。
    public static let stagingService = "Stacio.Staging"

    private let permit: V2ControlTargetOperationCoordinator
    private let keychain: KeychainCredentialStore

    public init(permit: V2ControlTargetOperationCoordinator, keychain: KeychainCredentialStore) {
        self.permit = permit
        self.keychain = keychain
    }

    /// staging account：`staging.<permitID>`（同 permit 全部 staging items 共享，可整体隔离）。
    public static func stagingAccount(for permitID: String) -> String {
        "staging.\(permitID)"
    }

    // MARK: - Permit 生命周期

    /// 发起 setup/rotation/activation 操作：签发 Permit 并冻结 participant set。
    public func beginOperation(
        kind: CredentialOperationKind,
        permitID: String,
        generation: Int64,
        participants: [String]
    ) throws {
        do {
            try permit.createPermit(permitID: permitID, generation: generation, participants: participants)
        } catch let error as V2ControlError {
            throw map(error)
        }
    }

    /// commit decision 已批准：prepare + authorize（目标可提交）。
    public func authorizeCommit(permitID: String) throws {
        do {
            try permit.preparePermit(permitID: permitID)
            try permit.authorizePermitCommit(permitID: permitID)
        } catch let error as V2ControlError {
            throw map(error)
        }
    }

    /// settlement-start 先持久化（settling），此后 staging 才可写。
    public func beginSettlement(permitID: String) throws {
        do {
            try permit.settlePermit(permitID: permitID, settlement: "settling", proofDigest: "settlement-start")
        } catch let error as V2ControlError {
            throw map(error)
        }
    }

    // MARK: - Keychain staging

    /// 写 staging item：仅 settling 阶段允许（未到 settlement-start 一律拒绝）。
    public func stageSecret(permitID: String, id: String, secret: String) throws {
        do {
            let state = try permit.permitState(permitID: permitID)
            guard state == .settling else {
                throw CredentialPermitWiringError.stagingRequiresSettling(permitID: permitID)
            }
            try keychain.save(
                KeychainCredential(id: id, account: Self.stagingAccount(for: permitID), secret: secret)
            )
        } catch let error as CredentialPermitWiringError {
            throw error
        } catch let error as V2ControlError {
            throw map(error)
        } catch {
            throw CredentialPermitWiringError.storage("\(error)")
        }
    }

    /// 目标提交：先 settle settledCommitted（Rust 校验 journal 一致性；失败时 staging 未动可重试），
    /// 成功后 staging 提升为正式键（正式 account），再删除 staging。
    /// 提升失败时 permit 已 committed 且 staging 仍在——调用方可经 promoteStagedOnly 重试提升。
    public func commitStaged(permitID: String, id: String, account: String, proofDigest: String) throws {
        do {
            try permit.settlePermit(permitID: permitID, settlement: "settledCommitted", proofDigest: proofDigest)
        } catch let error as V2ControlError {
            throw map(error)
        }
        try promoteStagedOnly(permitID: permitID, id: id, account: account)
    }

    /// 提升 staging → 正式键并删除 staging（settle 已成功后的重试入口）。
    public func promoteStagedOnly(permitID: String, id: String, account: String) throws {
        let staged = try readStaged(permitID: permitID, id: id)
        do {
            try keychain.save(KeychainCredential(id: id, account: account, secret: staged))
        } catch {
            throw CredentialPermitWiringError.stagingPromotionFailed(
                permitID: permitID, id: id, reason: "\(error)"
            )
        }
        try keychain.delete(id: id, account: Self.stagingAccount(for: permitID))
    }

    /// 目标未提交：settle settledAborted（abort decision proof）+ 删除全部 staging items。
    public func abortStaged(permitID: String, stagedIDs: [String], proofDigest: String) throws {
        do {
            try permit.settlePermit(permitID: permitID, settlement: "settledAborted", proofDigest: proofDigest)
        } catch let error as V2ControlError {
            throw map(error)
        }
        for id in stagedIDs {
            try keychain.delete(id: id, account: Self.stagingAccount(for: permitID))
        }
    }

    /// 旧 Permit 必须已终结（settled*）才能 resume；新 Permit 由调用方生成新 permitID。
    public func resume(previousPermitID: String, newPermitID: String, generation: Int64, participants: [String]) throws {
        do {
            let state = try permit.permitState(permitID: previousPermitID)
            guard state.isTerminal else {
                throw CredentialPermitWiringError.storage(
                    "resume 需要旧 Permit 已终结，当前 \(state.rawValue)"
                )
            }
            try permit.createPermit(permitID: newPermitID, generation: generation, participants: participants)
        } catch let error as CredentialPermitWiringError {
            throw error
        } catch let error as V2ControlError {
            throw map(error)
        }
    }

    // MARK: - helpers

    private func readStaged(permitID: String, id: String) throws -> String {
        do {
            return try keychain.readSecret(id: id, account: Self.stagingAccount(for: permitID))
        } catch KeychainCredentialError.notFound {
            throw CredentialPermitWiringError.stagingNotFound(permitID: permitID, id: id)
        } catch {
            throw CredentialPermitWiringError.storage("\(error)")
        }
    }

    private func map(_ error: V2ControlError) -> CredentialPermitWiringError {
        switch error {
        case .notFound(let id):
            return .notFound(id: id)
        case .storage(let message):
            return .storage(message)
        default:
            return .storage("\(error)")
        }
    }
}
