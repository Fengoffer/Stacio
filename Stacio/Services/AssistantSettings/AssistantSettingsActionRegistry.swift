import Foundation

// MARK: - 14 个 operation kind（§8.1 首版 contract，完整集合）

public enum V2OperationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case configurationSaveDraft
    case queuePromotion
    case attemptMaterialization
    case credentialSetupCreate
    case credentialSetupSaveDraft
    case configurationActivation
    case credentialRotation
    case proxyCredentialRotation
    case configurationMutation
    case configurationDelete
    case credentialSetupResume
    case configurationVerificationRequest
    case runtimeLaunch
    case localAgentMaintenanceLaunch
}

// MARK: - Action 控制策略（§9.5 五个穷尽分区）

/// 48 个 Action ID 的五个穷尽分区：
/// `enabledEphemeral 1 / enabledPermit 25 / safetySettlement 7 / controlIndependentUserAction 9 / maintenanceFence 6`。
public enum ActionControlPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    /// 仅 enabled 三态可用；轻量、立即完成、无持久副作用（无 Permit）。
    case enabledEphemeral
    /// 仅 enabled 签发 Permit；drain 后无新 authorization。
    case enabledPermit
    /// 三态可用，但只能关闭 access/撤销/隔离/收集证据。
    case safetySettlement
    /// 三态可用，但不得获得 Permit/credential/Target capability。
    case controlIndependentUserAction
    /// 按 descriptor 状态与 maintenance fence 运行；delete-all 仅 disabled。
    case maintenanceFence
}

public enum ActionAuthorizationClass: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case attemptScoped
    case sessionScoped
    case permitRequired
}

/// 幂等键范围：ack 丢失/重放按此范围去重。
public enum ActionIdempotencyKeyScope: String, Codable, CaseIterable, Equatable, Sendable {
    case operation
    case action
    case attempt
}

public enum ActionCancellationPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    /// 不可取消（必须 await 结算）。
    case none
    /// 请求取消并结算为 cancelled。
    case cancelAndSettle
    /// 等待自然结算。
    case awaitSettlement
}

public enum ActionSettlementOwner: String, Codable, CaseIterable, Equatable, Sendable {
    /// 由 ActionCoordinator 在业务结果取得后结算。
    case coordinator
    /// 由 Permit 结算驱动（Permit settled 不等同业务结果）。
    case permit
    /// 由 Evidence Store 证据驱动。
    case evidenceStore
}

// MARK: - ActionDescriptor（9 个必含字段）

public struct ActionDescriptor: Equatable, Sendable {
    public let id: String
    public let parameterSchema: [String]
    public let resultSchema: [String]
    public let controlPolicy: ActionControlPolicy
    /// Actions that only open a verified website or build an in-memory
    /// preview do not own a durable operation. `nil` records that boundary
    /// explicitly instead of assigning a fake mutation kind.
    public let requiredOperationKind: V2OperationKind?
    public let authorizationClass: ActionAuthorizationClass
    public let idempotencyKeyScope: ActionIdempotencyKeyScope
    public let auditEventKind: String
    public let cancellationPolicy: ActionCancellationPolicy
    public let settlementOwner: ActionSettlementOwner

    public init(
        id: String,
        parameterSchema: [String],
        resultSchema: [String],
        controlPolicy: ActionControlPolicy,
        requiredOperationKind: V2OperationKind?,
        authorizationClass: ActionAuthorizationClass,
        idempotencyKeyScope: ActionIdempotencyKeyScope,
        auditEventKind: String,
        cancellationPolicy: ActionCancellationPolicy,
        settlementOwner: ActionSettlementOwner
    ) {
        self.id = id
        self.parameterSchema = parameterSchema
        self.resultSchema = resultSchema
        self.controlPolicy = controlPolicy
        self.requiredOperationKind = requiredOperationKind
        self.authorizationClass = authorizationClass
        self.idempotencyKeyScope = idempotencyKeyScope
        self.auditEventKind = auditEventKind
        self.cancellationPolicy = cancellationPolicy
        self.settlementOwner = settlementOwner
    }
}

public enum AssistantSettingsActionRegistryError: Error, Equatable {
    case duplicateID(String)
    case missingRequiredFields([String])
    case partitionMismatch(expected: Int, actual: Int, partition: String)
}

// MARK: - 复合 Action 结构

/// 复合 Action（如 `provider.saveCredentialAndFetchModels`）：每个子 operation
/// 独立稳定 ID/Permit；前一步 proof 是后一步前置（不是共享成功布尔）。
public struct CompositeActionStep: Equatable, Sendable {
    public let subActionID: String
    public let requiresProofOf: String?

    public init(subActionID: String, requiresProofOf: String? = nil) {
        self.subActionID = subActionID
        self.requiresProofOf = requiresProofOf
    }
}

// MARK: - AssistantSettingsActionRegistry

/// 48 个 Action 唯一 Registry：一个 Action ID 必须且只能命中一行；
/// 未知/多重命中构建失败；五个分区计数穷尽。
public struct AssistantSettingsActionRegistry {
    public let actionsByID: [String: ActionDescriptor]
    public let compositeSteps: [String: [CompositeActionStep]]
    public let revision: Int

    public static func build(
        actions: [ActionDescriptor],
        compositeSteps: [String: [CompositeActionStep]] = [:],
        revision: Int = 1
    ) throws -> AssistantSettingsActionRegistry {
        var byID: [String: ActionDescriptor] = [:]
        var missing: [String] = []
        for action in actions {
            if byID[action.id] != nil {
                throw AssistantSettingsActionRegistryError.duplicateID(action.id)
            }
            if action.id.isEmpty || action.parameterSchema.isEmpty || action.resultSchema.isEmpty {
                missing.append(action.id)
            }
            if !["actionRequested", "actionCancelled", "actionFailed",
                 "actionReconciliationRequired", "actionSettled"].contains(action.auditEventKind) {
                missing.append(action.id)
            }
            byID[action.id] = action
        }
        if !missing.isEmpty {
            throw AssistantSettingsActionRegistryError.missingRequiredFields(missing)
        }
        // 复合 Action 的子 operation 必须存在且 id 唯一命中
        for (parent, steps) in compositeSteps {
            if byID[parent] == nil {
                throw AssistantSettingsActionRegistryError.missingRequiredFields([parent])
            }
            for step in steps {
                if byID[step.subActionID] == nil {
                    throw AssistantSettingsActionRegistryError.missingRequiredFields([step.subActionID])
                }
            }
        }
        return AssistantSettingsActionRegistry(
            actionsByID: byID, compositeSteps: compositeSteps, revision: revision
        )
    }

    public func action(for id: String) -> ActionDescriptor? {
        actionsByID[id]
    }

    /// 分区穷尽校验：48 个 Action 必须正好命中五个分区计数。
    public func validatePartitionCounts() throws {
        let counts = partitionCounts()
        try check("enabledEphemeral", expected: 1, actual: counts[.enabledEphemeral] ?? 0)
        try check("enabledPermit", expected: 25, actual: counts[.enabledPermit] ?? 0)
        try check("safetySettlement", expected: 7, actual: counts[.safetySettlement] ?? 0)
        try check("controlIndependentUserAction", expected: 9, actual: counts[.controlIndependentUserAction] ?? 0)
        try check("maintenanceFence", expected: 6, actual: counts[.maintenanceFence] ?? 0)
    }

    private func check(_ partition: String, expected: Int, actual: Int) throws {
        guard expected == actual else {
            throw AssistantSettingsActionRegistryError.partitionMismatch(
                expected: expected, actual: actual, partition: partition
            )
        }
    }

    public func partitionCounts() -> [ActionControlPolicy: Int] {
        var counts: [ActionControlPolicy: Int] = [:]
        for action in actionsByID.values {
            counts[action.controlPolicy, default: 0] += 1
        }
        return counts
    }
}

// MARK: - 标准 48 Action Registry（§9.5 穷尽分区）

public extension AssistantSettingsActionRegistry {
    /// 标准 48 Action：enabledEphemeral 1 / enabledPermit 25 / safetySettlement 7 /
    /// controlIndependentUserAction 9 / maintenanceFence 6。
    /// 缓存避免每次打开设置/装配面板重复构造 48 个 Action。
    private static let cachedStandard: Result<AssistantSettingsActionRegistry, Error> = {
        Result { try buildStandard() }
    }()

    static func standard() throws -> AssistantSettingsActionRegistry {
        try cachedStandard.get()
    }

    private static func buildStandard() throws -> AssistantSettingsActionRegistry {
        let actions: [ActionDescriptor] = [
            // enabledEphemeral (1)
            action("configuration.createFromCatalog", .enabledEphemeral, nil, .none),

            // enabledPermit (25)
            action("configuration.saveDraft", .enabledPermit, .configurationSaveDraft, .permitRequired),
            action("configuration.resumeCredentialSetup", .enabledPermit, .credentialSetupResume, .permitRequired),
            action("configuration.activate", .enabledPermit, .configurationActivation, .permitRequired),
            action("configuration.delete", .enabledPermit, .configurationDelete, .permitRequired),
            action("configuration.duplicate", .enabledPermit, .configurationSaveDraft, .permitRequired),
            action("configuration.import", .enabledPermit, .configurationSaveDraft, .permitRequired),
            action("provider.restoreOfficialURL", .enabledPermit, .configurationMutation, .permitRequired),
            action("codingPlan.restoreOfficialURL", .enabledPermit, .configurationMutation, .permitRequired),
            action("provider.manageManualModelIDs", .enabledPermit, .configurationMutation, .permitRequired),
            action("configuration.changeNetworkTrust", .enabledPermit, .configurationMutation, .permitRequired),
            action("localAgent.changeExecutionProfile", .enabledPermit, .configurationMutation, .permitRequired),
            action("provider.saveCredentialAndFetchModels", .enabledPermit, .credentialSetupCreate, .permitRequired),
            action("codingPlan.saveCredentialAndFetchModels", .enabledPermit, .credentialSetupCreate, .permitRequired),
            action("provider.fetchModels", .enabledPermit, .configurationVerificationRequest, .permitRequired),
            action("provider.testConnection", .enabledPermit, .configurationVerificationRequest, .permitRequired),
            action("codingPlan.fetchModels", .enabledPermit, .configurationVerificationRequest, .permitRequired),
            action("codingPlan.testConnection", .enabledPermit, .configurationVerificationRequest, .permitRequired),
            action("provider.rotateCredential", .enabledPermit, .credentialRotation, .permitRequired),
            action("codingPlan.rotateCredential", .enabledPermit, .credentialRotation, .permitRequired),
            action("configuration.copyCredentialToNewOrigin", .enabledPermit, .credentialSetupCreate, .permitRequired),
            action("provider.saveProxyCredential", .enabledPermit, .proxyCredentialRotation, .permitRequired),
            action("codingPlan.saveProxyCredential", .enabledPermit, .proxyCredentialRotation, .permitRequired),
            action("localAgent.detect", .enabledPermit, .localAgentMaintenanceLaunch, .permitRequired),
            action("localAgent.login", .enabledPermit, .localAgentMaintenanceLaunch, .permitRequired),
            action("assistant.redetectRuntimes", .enabledPermit, .localAgentMaintenanceLaunch, .permitRequired),

            // safetySettlement (7)
            action("configuration.discardCredentialSetup", .safetySettlement, .credentialSetupResume, .attemptScoped),
            action("provider.revokeCredentialNow", .safetySettlement, .credentialRotation, .attemptScoped),
            action("codingPlan.revokeCredentialNow", .safetySettlement, .credentialRotation, .attemptScoped),
            action("provider.clearProxyCredential", .safetySettlement, .proxyCredentialRotation, .attemptScoped),
            action("codingPlan.clearProxyCredential", .safetySettlement, .proxyCredentialRotation, .attemptScoped),
            action("localAgent.logout", .safetySettlement, .localAgentMaintenanceLaunch, .attemptScoped),
            action("localAgent.reconcileProcesses", .safetySettlement, .localAgentMaintenanceLaunch, .attemptScoped),

            // controlIndependentUserAction (9)
            action("configuration.export", .controlIndependentUserAction, nil, .none),
            action("configuration.openWebsiteAction", .controlIndependentUserAction, nil, .none),
            action("localAgent.openUpgrade", .controlIndependentUserAction, nil, .none),
            action("context.previewOutboundPayload", .controlIndependentUserAction, nil, .none),
            action("history.exportSelection", .controlIndependentUserAction, nil, .none),
            action("memory.exportProject", .controlIndependentUserAction, nil, .none),
            action("diagnostics.previewBundle", .controlIndependentUserAction, nil, .none),
            action("diagnostics.exportBundle", .controlIndependentUserAction, nil, .none),
            action("privacy.changeTelemetryConsent", .controlIndependentUserAction, .configurationMutation, .none),

            // maintenanceFence (6)
            action("history.clearSelection", .maintenanceFence, .configurationDelete, .none),
            action("history.deleteAllV2", .maintenanceFence, .configurationDelete, .none),
            action("history.changeRetention", .maintenanceFence, .configurationMutation, .none),
            action("memory.deleteProject", .maintenanceFence, .configurationDelete, .none),
            action("assistant.resetSettingsAndInstructions", .maintenanceFence, .configurationDelete, .none),
            action("assistant.resetCaches", .maintenanceFence, .configurationDelete, .none)
        ]

        let compositeSteps: [String: [CompositeActionStep]] = [
            "provider.saveCredentialAndFetchModels": [
                CompositeActionStep(subActionID: "provider.saveCredentialAndFetchModels"),
                CompositeActionStep(
                    subActionID: "provider.fetchModels",
                    requiresProofOf: "provider.saveCredentialAndFetchModels"
                )
            ],
            "codingPlan.saveCredentialAndFetchModels": [
                CompositeActionStep(subActionID: "codingPlan.saveCredentialAndFetchModels"),
                CompositeActionStep(
                    subActionID: "codingPlan.fetchModels",
                    requiresProofOf: "codingPlan.saveCredentialAndFetchModels"
                )
            ]
        ]
        return try build(actions: actions, compositeSteps: compositeSteps)
    }

    /// 便捷构造（parameterSchema/resultSchema 标准化）。
    private static func action(
        _ id: String,
        _ policy: ActionControlPolicy,
        _ operationKind: V2OperationKind?,
        _ authorization: ActionAuthorizationClass
    ) -> ActionDescriptor {
        ActionDescriptor(
            id: id,
            parameterSchema: ["operationID", "idempotencyKey"],
            resultSchema: ["outcome", "proofDigest"],
            controlPolicy: policy,
            requiredOperationKind: operationKind,
            authorizationClass: authorization,
            idempotencyKeyScope: .operation,
            auditEventKind: "actionRequested",
            cancellationPolicy: policy == .enabledEphemeral ? .none : .cancelAndSettle,
            settlementOwner: .coordinator
        )
    }
}
