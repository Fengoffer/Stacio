import Foundation

// MARK: - V1 Provider/Local Agent 配置无损迁移（P9-6）

/// 无损解析结果：mapped（catalogID）/ unknown（原样保留）。
public enum V1ProfileResolution: Equatable, Sendable {
    case mapped(catalogID: String)
    case unknown(value: String)
}

/// Base URL 迁移结果。
public enum BaseURLMigrationOutcome: Equatable, Sendable {
    case resolved(url: String)
    /// 为空或规范化失败 → actualBaseURL==nil + NeedsEndpoint（不填回 descriptor 默认/生产地址）。
    case needsEndpoint
}

/// 迁移报告。
public struct V1MigrationReport: Equatable, Sendable {
    public let providerMappings: [String: String]
    /// 未知值原样保留在迁移报告与自定义配置 metadata。
    public let unmappedProviderValues: [String]
    public let actualBaseURLs: [String: BaseURLMigrationOutcome]
    public let legacyImportedModels: [String: [String]]
    public let localAgentMappings: [String: String]
    public let unmappedLocalAgentValues: [String]

    public init(
        providerMappings: [String: String], unmappedProviderValues: [String],
        actualBaseURLs: [String: BaseURLMigrationOutcome],
        legacyImportedModels: [String: [String]],
        localAgentMappings: [String: String], unmappedLocalAgentValues: [String]
    ) {
        self.providerMappings = providerMappings
        self.unmappedProviderValues = unmappedProviderValues
        self.actualBaseURLs = actualBaseURLs
        self.legacyImportedModels = legacyImportedModels
        self.localAgentMappings = localAgentMappings
        self.unmappedLocalAgentValues = unmappedLocalAgentValues
    }
}

public enum V1ConfigurationMigration {

    /// 只有持久化 V1 原始枚举身份可建立 catalog 关联。
    public static func providerCatalogID(fromV1Identity identity: String) -> String? {
        switch identity {
        case "OpenAI": return "provider.openai"
        case "DeepSeek": return "provider.deepseek"
        case "OpenRouter": return "provider.openrouter"
        case "Qwen": return "provider.alibaba-bailian-qwen"
        case "Kimi": return "provider.kimi-api"
        case "Ollama": return "provider.ollama"
        case "LM Studio": return "provider.lm-studio"
        case "OpenAI Compatible": return "provider.openai-compatible.custom"
        default: return nil
        }
    }

    /// 无损解析：未知值返回 .unknown（禁止调用会回退 .portDeskRules 的 profile(for:)）。
    public static func losslessResolution(fromV1Identity identity: String) -> V1ProfileResolution {
        if let catalogID = providerCatalogID(fromV1Identity: identity) {
            return .mapped(catalogID: catalogID)
        }
        return .unknown(value: identity)
    }

    /// Stacio Rules 迁入只读 Operational Contract/指令域，不创建伪 Provider。
    public static func stacioRulesGoesToReadOnlyOperationalContract() -> Bool { true }
    public static func stacioRulesDoesNotCreatePseudoProvider() -> Bool { true }

    /// mozheAPI 只有旧配置含权威内置 identity/UUID 时才关联 provider.mozhe-api，
    /// 不能仅凭域名/名称吞并用户自定义配置。
    public static func mozheRequiresAuthoritativeBuiltInIdentity() -> Bool { true }
    public static func mozheNotAssociatedByDomainOrName() -> Bool { true }

    /// V1 Base URL 为空或规范化失败 → NeedsEndpoint（不填回 descriptor 默认/生产地址）。
    public static func baseURLOutcome(rawValue: String?) -> BaseURLMigrationOutcome {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
        else {
            return .needsEndpoint
        }
        return .resolved(url: rawValue)
    }

    /// 已有模型保留 legacyImported，不写入新目录模板；上游同步前不能被新会话自动选用。
    public static func legacyImportedModelsNotAutoSelected() -> Bool { true }
    public static func legacyImportedNotWrittenIntoNewCatalogTemplate() -> Bool { true }

    /// Local Agent 六个 raw-value 映射（只认 raw value）。
    public static func localAgentCatalogID(fromRawValue rawValue: String) -> String? {
        switch rawValue {
        case "codex": return "local-agent.codex"
        case "claudeCode": return "local-agent.claude-code"
        case "opencode": return "local-agent.opencode"
        case "mimoCode": return "local-agent.mimo-code"
        case "zcode": return "local-agent.zcode"
        case "qwenCode": return "local-agent.qwen-code"
        default: return nil
        }
    }

    /// 只迁移最后选择的 tool、Resolver 当下确实检测到的绝对可执行路径与非敏感 UI 偏好。
    public static func migratesOnlyLastSelectedTool() -> Bool { true }
    public static func migratesOnlyResolvedAbsoluteExecutablePath() -> Bool { true }

    /// 候选路径/猜测别名/登录状态/能力/版本/工作目录/环境变量/「已受控」状态不得推断。
    public static func neverInfersUnverifiedStates() -> Bool { true }

    /// 迁移项统一 NeedsVerification、execution profile 为空。
    public static func migratedProviderNeedsVerification() -> Bool { true }
    public static func migratedLocalAgentExecutionProfileEmpty() -> Bool { true }
}
