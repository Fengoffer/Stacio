import Foundation

// MARK: - Provider 配置流程计划（P4-5）

/// 凭证存在性：严格免凭证（Ollama/LM Studio）走独立分支。
public enum CredentialPresence: Equatable, Sendable {
    case none
    case present(generationCount: Int)
}

/// saveDraft 计划步骤。
public enum SaveDraftStep: Equatable, Sendable {
    /// 无凭证分支：仅 SavedDraft Configuration（零 credential 活动）。
    case configurationSavedDraft
    /// 有凭证分支：credentialSetupSaveDraft + durable pendingRetention==savedDraft。
    case credentialSetupSavedDraft(retention: String)
    /// 逐 generation 的 credentialActivationSavedAsDraft 事件。
    case credentialActivationSavedAsDraft(generationIndex: Int)
}

public struct SaveDraftPlan: Equatable, Sendable {
    public let steps: [SaveDraftStep]
    public let credentialActivity: Bool
    /// 无凭证分支必须零 CredentialGeneration/Keychain/credential event。
    public let keychainWrites: Int

    public init(steps: [SaveDraftStep], credentialActivity: Bool, keychainWrites: Int) {
        self.steps = steps
        self.credentialActivity = credentialActivity
        self.keychainWrites = keychainWrites
    }
}

/// saveCredentialAndFetchModels 步骤（先 credentialSetupCreate 再独立 verificationRequest）。
public enum SaveCredentialAndFetchStep: Equatable, Sendable {
    /// credentialSetupCreate：Keychain staging write 只在 settling 阶段、Runtime 不可访问、
    /// 目标未提交时删除或 quarantine。
    case credentialSetupCreate
    case keychainStagingWrite(stage: String)
    /// 独立 configurationVerificationRequest（setup-owner use lease）。
    case configurationVerificationRequest(owner: String)
    case settle
}

public struct SaveCredentialAndFetchPlan: Equatable, Sendable {
    public let steps: [SaveCredentialAndFetchStep]

    public init(steps: [SaveCredentialAndFetchStep]) {
        self.steps = steps
    }
}

/// 严格免凭证分支计划（Ollama/LM Studio）：
/// configurationSaveDraft → owner==configurationAction、accessMode==none 的独立请求，
/// 零 generation/use lease/setup/lifecycle。
public struct NoCredentialFetchPlan: Equatable, Sendable {
    public let steps: [SaveCredentialAndFetchStep]
    public let owner: String
    public let accessMode: String
    public let generationCount: Int
    public let useLeaseCount: Int
    public let setupCount: Int
    public let lifecycleCount: Int

    public init(
        steps: [SaveCredentialAndFetchStep], owner: String, accessMode: String,
        generationCount: Int, useLeaseCount: Int, setupCount: Int, lifecycleCount: Int
    ) {
        self.steps = steps
        self.owner = owner
        self.accessMode = accessMode
        self.generationCount = generationCount
        self.useLeaseCount = useLeaseCount
        self.setupCount = setupCount
        self.lifecycleCount = lifecycleCount
    }
}

/// activate 计划。
public enum ActivationStep: Equatable, Sendable {
    /// 有凭证分支：全 participant settlement 后才 Active。
    case participantSettlement(participant: String)
    case activated
    /// 免凭证分支：只提交 Configuration participant 且 enabled false→true 在同一 Configuration 事务。
    case configurationParticipantCommit(enabledTransition: String)
}

public struct ActivationPlan: Equatable, Sendable {
    public let steps: [ActivationStep]
    public let requiresFullSettlement: Bool

    public init(steps: [ActivationStep], requiresFullSettlement: Bool) {
        self.steps = steps
        self.requiresFullSettlement = requiresFullSettlement
    }
}

// MARK: - 流程规划器（纯函数；编排语义的唯一来源）

public enum ProviderConfigurationFlow {

    /// saveDraft：
    /// - 无凭证分支：仅 SavedDraft Configuration（零 CredentialGeneration/Keychain/credential event）；
    /// - 有凭证分支：credentialSetupSaveDraft（durable pendingRetention==savedDraft）
    ///   + 逐 generation 发 credentialActivationSavedAsDraft。
    public static func planSaveDraft(credential: CredentialPresence) -> SaveDraftPlan {
        switch credential {
        case .none:
            return SaveDraftPlan(
                steps: [.configurationSavedDraft],
                credentialActivity: false,
                keychainWrites: 0
            )
        case .present(let generationCount):
            var steps: [SaveDraftStep] = [.credentialSetupSavedDraft(retention: "savedDraft")]
            for index in 0..<generationCount {
                steps.append(.credentialActivationSavedAsDraft(generationIndex: index))
            }
            return SaveDraftPlan(
                steps: steps,
                credentialActivity: true,
                keychainWrites: 0
            )
        }
    }

    /// saveCredentialAndFetchModels：先 credentialSetupCreate（Keychain staging write 只在
    /// settling 阶段、Runtime 不可访问、目标未提交时删除或 quarantine），
    /// 再独立 configurationVerificationRequest（setup-owner use lease）。
    public static func planSaveCredentialAndFetchModels() -> SaveCredentialAndFetchPlan {
        SaveCredentialAndFetchPlan(steps: [
            .credentialSetupCreate,
            .keychainStagingWrite(stage: "settling"),
            .configurationVerificationRequest(owner: "setup"),
            .settle
        ])
    }

    /// 严格免凭证（Ollama/LM Studio）：configurationSaveDraft → owner==configurationAction、
    /// accessMode==none 的独立请求，零 generation/use lease/setup/lifecycle。
    public static func planNoCredentialFetch() -> NoCredentialFetchPlan {
        NoCredentialFetchPlan(
            steps: [
                .configurationVerificationRequest(owner: "configurationAction"),
                .settle
            ],
            owner: "configurationAction",
            accessMode: "none",
            generationCount: 0,
            useLeaseCount: 0,
            setupCount: 0,
            lifecycleCount: 0
        )
    }

    /// activate：
    /// - 有凭证分支：全 participant settlement 后才 Active（requiresFullSettlement）；
    /// - 免凭证分支：只提交 Configuration participant 且 enabled false→true 在同一 Configuration 事务。
    public static func planActivation(credential: CredentialPresence) -> ActivationPlan {
        switch credential {
        case .present(let generationCount):
            var steps: [ActivationStep] = []
            for index in 0..<generationCount {
                steps.append(.participantSettlement(participant: "credential-generation-\(index)"))
            }
            steps.append(.participantSettlement(participant: "configuration"))
            steps.append(.activated)
            return ActivationPlan(steps: steps, requiresFullSettlement: true)
        case .none:
            return ActivationPlan(
                steps: [.configurationParticipantCommit(enabledTransition: "false->true")],
                requiresFullSettlement: false
            )
        }
    }

    /// Keychain staging 规则（复用 P3-8c Permit 接线语义）：
    /// 只在 settling 阶段写；目标未提交时删除或 quarantine。
    public static func stagingWriteAllowed(stage: String) -> Bool {
        stage == "settling"
    }
}
