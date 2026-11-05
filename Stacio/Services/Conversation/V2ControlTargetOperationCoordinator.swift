import Foundation

// MARK: - V2ControlPermit 状态机（P3-9）

/// Permit 状态：`issued→prepared→commitAuthorized→settling→settledCommitted|settledAborted`
/// （状态类型 `V2ControlPermitState` 与 P3-8 系列共用，权威状态在 Rust 控制面库）。
/// 终态无出口；`commitAuthorized/settling` 不靠超时猜失败——结算必须带 proof 持久化。
public enum V2ControlPermitEvent: Equatable, Sendable {
    case prepare
    case authorizeCommit
    case beginSettlement
    case settleCommitted
    case settleAborted
}

public enum V2ControlPermitStateMachine {
    /// 关闭转换表：
    /// - 授权路径 `issued→prepared→commitAuthorized→settling→settledCommitted|settledAborted`；
    /// - 全 target journal 一致 committed 即授权证据：`issued/prepared→settling|settledCommitted`；
    /// - abort path：`issued/prepared/commitAuthorized/settling→settledAborted`；
    /// - 终态无出口。journal 一致性由 Rust 控制面库校验（Swift 纯函数表不校验 I/O）。
    public static func destination(
        from state: V2ControlPermitState,
        event: V2ControlPermitEvent
    ) -> V2ControlPermitState? {
        switch (state, event) {
        case (.issued, .prepare): return .prepared
        case (.prepared, .authorizeCommit): return .commitAuthorized
        case (.commitAuthorized, .beginSettlement): return .settling
        case (.settling, .settleCommitted): return .settledCommitted
        case (.settling, .settleAborted): return .settledAborted
        // 全 target committed 收尾路径
        case (.issued, .beginSettlement), (.prepared, .beginSettlement): return .settling
        case (.issued, .settleCommitted), (.prepared, .settleCommitted): return .settledCommitted
        // abort path
        case (.issued, .settleAborted), (.prepared, .settleAborted),
             (.commitAuthorized, .settleAborted):
            return .settledAborted
        default:
            return nil
        }
    }
}

// MARK: - Target operation 协调器

/// Permit + target journal 协调器：Swift facade → CoreBridge control* → Rust 控制面库。
/// 每个决策（prepare/commit/abort/settlement-start）都带 proof digest 持久化，按 proof 对账，
/// ack 丢失与 App 崩溃不会重放或猜测结果。
/// `V2ControlTargetOperationJournal`：createPermit 时冻结完整 participant set（签发顺序）；
/// 每 participant 状态见 `V2ControlTargetJournalState`；局部提交（reconciliationRequired）阻止 disabled。
public final class V2ControlTargetOperationCoordinator {
    private let control: AgentConversationV2ControlCoordinator

    public init(control: AgentConversationV2ControlCoordinator) {
        self.control = control
    }

    private var handle: UInt64 { control.handle }

    /// 签发 Permit 并冻结 target journal（完整 participant set）。
    public func createPermit(permitID: String, generation: Int64, participants: [String]) throws {
        do {
            try CoreBridge.controlCreatePermit(
                handle: handle, permitId: permitID, generation: generation, participants: participants
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func permitState(permitID: String) throws -> V2ControlPermitState {
        do {
            let raw = try CoreBridge.controlPermitState(handle: handle, permitId: permitID)
            guard let state = V2ControlPermitState(rawValue: raw) else {
                throw V2ControlError.storage("unknown permit state: \(raw)")
            }
            return state
        } catch let error as V2ControlError {
            throw error
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func preparePermit(permitID: String) throws {
        do {
            try CoreBridge.controlPreparePermit(handle: handle, permitId: permitID)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func authorizePermitCommit(permitID: String) throws {
        do {
            try CoreBridge.controlAuthorizePermitCommit(handle: handle, permitId: permitID)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 结算（settlement-start 与终态结算共用）：`settlement` 为
    /// settling/settledCommitted/settledAborted；`proofDigest` 作为对账锚点持久化。
    public func settlePermit(permitID: String, settlement: String, proofDigest: String) throws {
        do {
            try CoreBridge.controlSettlePermit(
                handle: handle, permitId: permitID, settlement: settlement, proof: proofDigest
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// expiry：未 prepared 只允许 no-target proof；prepared/commitAuthorized 必须走 abort decision。
    public func expirePermit(permitID: String, withTargetProof: Bool) throws {
        do {
            try CoreBridge.controlExpirePermit(handle: handle, permitId: permitID, withTargetProof: withTargetProof)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 冻结的 participant set（签发顺序）。
    public func journalParticipants(permitID: String) throws -> [String] {
        do {
            return try CoreBridge.controlJournalParticipants(handle: handle, permitId: permitID)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    public func markJournal(permitID: String, participant: String, state: V2ControlTargetJournalState) throws {
        do {
            try CoreBridge.controlMarkJournal(
                handle: handle, permitId: permitID, participant: participant, state: state.rawValue
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }
}
