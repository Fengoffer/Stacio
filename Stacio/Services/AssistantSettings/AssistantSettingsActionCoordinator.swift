import Foundation

// MARK: - Settings Action 协调器（P4-2）

public enum AssistantSettingsActionError: Error, Equatable {
    case unknownAction(String)
    case notPermitEligible(String)
    case controlStateBlocks(String)
    case safetySettlementScopeViolation(String)
    case missingPrerequisiteProof(subActionID: String)
    case invalidRequest(String)
    case missingOwner(String)
    case cancelled
    case storage(String)
}

public struct AssistantSettingsActionRequest: Equatable, Sendable {
    public let actionID: String
    public let operationID: String
    public let parameters: [String: SettingValue]

    public init(actionID: String, operationID: String, parameters: [String: SettingValue] = [:]) {
        self.actionID = actionID
        self.operationID = operationID
        self.parameters = parameters
    }
}

/// 业务 owner 的关闭结果集合。`succeeded` 必须代表业务事实已经提交，
/// 不能用“请求已派发”或“Permit 已结算”冒充。
public enum AssistantSettingsActionExecutionResult: Equatable, Sendable {
    case succeeded(proofDigest: String?)
    case cancelled
    case failed(reasonCode: String)
    case reconciliationRequired(referenceID: String)
}

public protocol AssistantSettingsControlStateProviding: AnyObject {
    func controlState() throws -> AgentConversationV2ControlState
}

extension AgentConversationV2ControlCoordinator: AssistantSettingsControlStateProviding {}

public typealias AssistantSettingsActionOwner = (
    AssistantSettingsActionRequest,
    @escaping (AssistantSettingsActionExecutionResult) -> Void
) -> Void

/// 唯一的 Setting → Action 绑定表。
///
/// 这张表同时被设置 UI 和持久化 owner 使用，避免 UI 显示了一个 action
/// 而实际写入路径却由另一套字符串规则决定。实例模板（`{id}`）按前缀
/// 解析，具体 ID 不会把 owner 权限扩展到未声明的 Action。
public enum AssistantSettingsActionBinding {
    public static func actionID(for settingID: String) -> String? {
        switch settingID {
        case "assistant.general.configurationOrder":
            return "configuration.saveDraft"
        case "assistant.history.retention":
            return "history.changeRetention"
        case "assistant.privacy.telemetryEnabled":
            return "privacy.changeTelemetryConsent"
        default:
            if settingID.hasPrefix("provider.") {
                return "configuration.saveDraft"
            }
            if settingID.hasPrefix("codingPlan.") {
                return "configuration.saveDraft"
            }
            if settingID.hasPrefix("localAgent.") {
                if settingID.hasSuffix(".executionProfileID") {
                    return "localAgent.changeExecutionProfile"
                }
                if settingID.hasSuffix(".executableReference") {
                    return "localAgent.detect"
                }
                return "configuration.saveDraft"
            }
            return nil
        }
    }
}

/// Action → 唯一业务 owner 的显式表。未注册不使用默认 no-op，必须失败关闭。
public final class AssistantSettingsActionOwnerRegistry {
    private let lock = NSLock()
    private var owners: [String: AssistantSettingsActionOwner] = [:]

    public init() {}

    public func register(actionIDs: [String], owner: @escaping AssistantSettingsActionOwner) throws {
        lock.lock()
        defer { lock.unlock() }
        for actionID in actionIDs {
            guard owners[actionID] == nil else {
                throw AssistantSettingsActionError.invalidRequest("duplicate owner: \(actionID)")
            }
        }
        for actionID in actionIDs {
            owners[actionID] = owner
        }
    }

    /// 单 Action 注册的便捷入口，保持重复注册 fail closed。
    public func register(actionID: String, owner: @escaping AssistantSettingsActionOwner) throws {
        try register(actionIDs: [actionID], owner: owner)
    }

    public func owner(for actionID: String) -> AssistantSettingsActionOwner? {
        lock.lock()
        defer { lock.unlock() }
        return owners[actionID]
    }

    public func hasOwner(for actionID: String) -> Bool {
        owner(for: actionID) != nil
    }
}

/// Action 能力判定（按 controlPolicy 分区）：
/// - `enabledPermit` 仅在 enabled 签发 Permit；drain 后无新 authorization；
/// - `safetySettlement` 三态可用但只能关闭 access/撤销/隔离/收集证据；
/// - `controlIndependentUserAction` 三态可用但不得获得 Permit/credential/Target capability；
/// - `maintenanceFence` 按 descriptor 状态与 maintenance fence 运行；delete-all 仅 disabled；
/// - `enabledEphemeral` 仅 enabled 三态可用、立即完成、无持久副作用。
public enum AssistantSettingsActionPolicy {
    /// enabledPermit 分区：仅在 enabled 签发 Permit。
    public static func canIssuePermit(controlState: AgentConversationV2ControlState) -> Bool {
        controlState == .enabled
    }

    /// drain 后无新 authorization（存量可完成）：Permit 已签发的不回收。
    public static func drainBlocksNewAuthorization(controlState: AgentConversationV2ControlState) -> Bool {
        controlState == .draining
    }

    /// safetySettlement：只允许关闭 access/撤销/隔离/收集证据类能力。
    public static func safetySettlementAllows(_ capability: ActionCapability) -> Bool {
        switch capability {
        case .disableAccess, .revokeCredential, .isolateTarget, .collectEvidence:
            return true
        case .issuePermit, .readCredential, .targetCapability:
            return false
        }
    }

    /// controlIndependentUserAction：不得获得 Permit/credential/Target capability。
    public static func controlIndependentAllows(_ capability: ActionCapability) -> Bool {
        switch capability {
        case .issuePermit, .readCredential, .targetCapability:
            return false
        case .disableAccess, .revokeCredential, .isolateTarget, .collectEvidence:
            return false
        }
    }

    /// maintenanceFence：delete-all 仅 disabled；其余按 fence 状态运行。
    public static func maintenanceFenceAllows(actionID: String, controlState: AgentConversationV2ControlState, fenceEngaged: Bool) -> Bool {
        if actionID == "history.deleteAllV2" {
            return controlState == .disabled
        }
        return !fenceEngaged
    }

    /// 三态可用性：enabledEphemeral 仅 enabled；safetySettlement/controlIndependent 三态可用。
    public static func usableIn(state: AgentConversationV2ControlState, policy: ActionControlPolicy) -> Bool {
        switch policy {
        case .enabledEphemeral, .enabledPermit:
            return state == .enabled
        case .safetySettlement, .controlIndependentUserAction:
            return true
        case .maintenanceFence:
            return true
        }
    }
}

/// 能力枚举（用于 safetySettlement/controlIndependent 边界判定）。
public enum ActionCapability: Equatable, Sendable {
    case issuePermit
    case disableAccess
    case revokeCredential
    case isolateTarget
    case collectEvidence
    case readCredential
    case targetCapability
}

// MARK: - 复合 Action proof 链

public enum ActionProof: Equatable, Sendable {
    case none
    case proof(String)
    case settledAborted(String)
}

/// 复合 Action 编排：每个子 operation 独立稳定 ID/Permit；
/// 前一步 proof 是后一步前置（不是共享成功布尔）。
public struct CompositeActionExecutor {
    public let registry: AssistantSettingsActionRegistry

    public init(registry: AssistantSettingsActionRegistry) {
        self.registry = registry
    }

    /// 验证复合 Action 的全部前置 proof（按 steps 顺序逐级检查）。
    public func validatePrerequisites(parentID: String, proofs: [String: ActionProof]) -> Result<Void, AssistantSettingsActionError> {
        guard let steps = registry.compositeSteps[parentID], !steps.isEmpty else {
            return .success(())
        }
        for step in steps {
            guard let proof = proofs[step.subActionID], proof != .none else {
                return .failure(.missingPrerequisiteProof(subActionID: step.subActionID))
            }
            if let required = step.requiresProofOf {
                guard let requiredProof = proofs[required],
                      requiredProof != ActionProof.none else {
                    return .failure(.missingPrerequisiteProof(subActionID: required))
                }
            }
        }
        return .success(())
    }
}

// MARK: - Action 协调器（facade：gate 判定 + Permit 接线 + audit 事件）

/// Settings Action 协调器：唯一执行入口——每个 Action 经 controlPolicy gate 判定后
/// 才可发起；Permit 相关操作接 V2ControlTargetOperationCoordinator。
public final class AssistantSettingsActionCoordinator {
    private let registry: AssistantSettingsActionRegistry
    private let control: AssistantSettingsControlStateProviding
    private let eventStore: AssistantSettingsEventStore
    private let owners: AssistantSettingsActionOwnerRegistry

    public init(
        registry: AssistantSettingsActionRegistry,
        control: AssistantSettingsControlStateProviding,
        eventStore: AssistantSettingsEventStore,
        owners: AssistantSettingsActionOwnerRegistry = AssistantSettingsActionOwnerRegistry()
    ) {
        self.registry = registry
        self.control = control
        self.eventStore = eventStore
        self.owners = owners
    }

    public func hasBusinessOwner(for actionID: String) -> Bool {
        owners.hasOwner(for: actionID)
    }

    /// Availability used by native Settings controls. It is deliberately
    /// stricter than owner presence: the durable control state and Action
    /// policy must both permit the operation.
    public func isActionAvailable(_ actionID: String) -> Bool {
        guard owners.hasOwner(for: actionID),
              let descriptor = registry.action(for: actionID),
              let controlState = try? control.controlState()
        else {
            return false
        }
        return AssistantSettingsActionPolicy.usableIn(
            state: controlState,
            policy: descriptor.controlPolicy
        )
    }

    /// 生产装配只能为 Registry 中存在的 Action 注册 owner；未知 ID 直接拒绝，
    /// 防止拼写错误把一个业务 closure 暴露给错误的控制项。
    public func registerOwner(
        for actionID: String,
        owner: @escaping AssistantSettingsActionOwner
    ) throws {
        try registerOwner(for: [actionID], owner: owner)
    }

    /// Registers a business surface atomically. If any ID is unknown or already
    /// owned, none of the supplied actions become visible to Settings.
    public func registerOwner(
        for actionIDs: [String],
        owner: @escaping AssistantSettingsActionOwner
    ) throws {
        for actionID in actionIDs {
            guard registry.action(for: actionID) != nil else {
                throw AssistantSettingsActionError.unknownAction(actionID)
            }
        }
        try owners.register(actionIDs: actionIDs, owner: owner)
    }

    /// 唯一 Action 执行入口。流程固定为 gate → durable requested → owner → durable settlement。
    /// completion 恰好调用一次；重复 owner callback 被忽略。
    public func perform(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping (Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>) -> Void
    ) {
        guard !request.operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(.invalidRequest("operationID")))
            return
        }
        guard let descriptor = registry.action(for: request.actionID) else {
            completion(.failure(.unknownAction(request.actionID)))
            return
        }

        let controlState: AgentConversationV2ControlState
        do {
            controlState = try control.controlState()
            try validate(descriptor: descriptor, actionID: request.actionID, controlState: controlState)
            try eventStore.requested(actionID: request.actionID, operationID: request.operationID)
        } catch let error as AssistantSettingsActionError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(.storage("\(error)")))
            return
        }

        guard let owner = owners.owner(for: request.actionID) else {
            try? eventStore.failed(actionID: request.actionID, operationID: request.operationID)
            completion(.failure(.missingOwner(request.actionID)))
            return
        }

        let settlement = ActionSettlementOnce()
        owner(request) { [weak self] result in
            guard let self, settlement.claim() else { return }
            do {
                switch result {
                case .succeeded:
                    try self.eventStore.settled(
                        actionID: request.actionID,
                        operationID: request.operationID
                    )
                case .cancelled:
                    try self.eventStore.cancelled(
                        actionID: request.actionID,
                        operationID: request.operationID
                    )
                case .failed:
                    try self.eventStore.failed(
                        actionID: request.actionID,
                        operationID: request.operationID
                    )
                case .reconciliationRequired:
                    try self.eventStore.reconciliationRequired(
                        actionID: request.actionID,
                        operationID: request.operationID
                    )
                }
                completion(.success(result))
            } catch {
                try? self.eventStore.reconciliationRequired(
                    actionID: request.actionID,
                    operationID: request.operationID
                )
                completion(.failure(.storage("action settlement: \(error)")))
            }
        }
    }

    private func validate(
        descriptor: ActionDescriptor,
        actionID: String,
        controlState: AgentConversationV2ControlState
    ) throws {
        guard AssistantSettingsActionPolicy.usableIn(state: controlState, policy: descriptor.controlPolicy) else {
            throw AssistantSettingsActionError.controlStateBlocks(actionID)
        }
        if descriptor.controlPolicy == .enabledPermit,
           !AssistantSettingsActionPolicy.canIssuePermit(controlState: controlState) {
            throw AssistantSettingsActionError.notPermitEligible(actionID)
        }
        if descriptor.controlPolicy == .maintenanceFence,
           !AssistantSettingsActionPolicy.maintenanceFenceAllows(
               actionID: actionID, controlState: controlState, fenceEngaged: false
           ) {
            throw AssistantSettingsActionError.controlStateBlocks(actionID)
        }
    }

    /// 结算：业务结果取得后写 actionSettled（前置证据由 Rust settings 域校验；
    /// Permit 已结算但异步 Action 未取得业务结果时协调器不会调用本方法）。
    public func settle(actionID: String, operationID: String) throws {
        try eventStore.settled(actionID: actionID, operationID: operationID)
    }

    /// 取消。
    public func cancel(actionID: String, operationID: String) throws {
        try eventStore.cancelled(actionID: actionID, operationID: operationID)
    }
}

private final class ActionSettlementOnce {
    private let lock = NSLock()
    private var settled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        return true
    }
}
