import Foundation

// MARK: - Legacy 迁移适配器（P核心闭环·步骤 5）

/// 从 V1 `AppSettings`/`AIApiKeyStore` 读取当前激活供应商配置，产出 V2 Runtime 所需的
/// `ProviderRuntimeConfiguration` + 真实 `OpenAICompatibleAIAssistantProvider`（§6 受保护能力）。
///
/// 合规边界（规格 §18.1 迁移）：
/// - 仅装配阶段读取 V1 配置；不写回 V1、不修改 V1 数据；
/// - 不硬编码供应商 URL/模型名——baseURL/model 来自用户在 V1 已存配置；
/// - 无有效配置时返回 nil（不静默回退、不预置模型、不伪造 provider）；
/// - API Key 经 Keychain 读取，不持久化在 V2 值对象。
///
/// V2 独立配置存储（ProviderConfigurationStore）作为后续阶段推进；本适配器是规格允许的迁移过渡。
public enum LegacyProviderConfigurationAdapter {

    /// 解析结果：V2 Runtime 装配所需的真实 provider + 配置值。
    public struct ResolvedProvider: Equatable {
        public let configuration: ProviderRuntimeConfiguration
        /// 真实流式 provider（封装 V1 OpenAICompatible SSE）；非 Equatable 比较，仅配置参与相等。
        public static func == (lhs: ResolvedProvider, rhs: ResolvedProvider) -> Bool {
            lhs.configuration == rhs.configuration
        }
    }

    /// 从 V1 配置解析当前激活供应商。
    /// - Parameters:
    ///   - settingsStore: V1 设置存储（默认 `.shared`）。
    ///   - keyStore: API Key 存储（默认真实 Keychain store）。
    /// - Returns: 解析成功返回 `(provider, configuration)`；无有效配置返回 nil。
    public static func resolveActiveProvider(
        settingsStore: AppSettingsStore = .shared,
        keyStore: AIApiKeyStoring = KeychainAIApiKeyStore(),
        transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(),
        preferredConfigurationID: String? = nil,
        preferredModelID: String? = nil,
        defaultReasoningEffort: AIReasoningEffortPreference = .medium,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> (provider: OpenAICompatibleAIAssistantProvider, configuration: ProviderRuntimeConfiguration)? {
        // V1 激活供应商经 aiProviderSettings.defaultAIProviderID 选择
        let settings = settingsStore.snapshot()
        let providerSettings = settings.aiProviderSettings
        let selectedProviderID: UUID
        if let preferredConfigurationID {
            guard let preferred = UUID(uuidString: preferredConfigurationID) else { return nil }
            selectedProviderID = preferred
        } else {
            selectedProviderID = providerSettings.defaultAIProviderID
        }
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              let active = providerSettings.aiProviders.first(where: {
                  $0.id == selectedProviderID && $0.isEnabled
              })
        else {
            return nil
        }
        guard AIProviderRuntimeEligibility.isConfigurationRunnable(
            active,
            runtimeCatalog: runtimeCatalog
        ) else {
            return nil
        }

        let rawBaseURL = active.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawBaseURL.isEmpty == false,
              let baseURL = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: rawBaseURL)
        else {
            return nil
        }

        // 端点安全校验（复用 V1 策略；不绕过 TLS）
        do {
            try AIEndpointSecurityPolicy.validate(baseURL)
        } catch {
            return nil
        }

        // Inspector 的显式模型选择是 fail-closed 边界：当调用方传入
        // preferredModelID 时，只能使用该模型，失效后不得回退供应商默认值。
        // 未显式选择时仍沿用供应商已保存的默认模型；两条路径都不会自动选第一个。
        let requestedModelID: String
        if let preferredModelID {
            requestedModelID = preferredModelID
        } else if let defaultModelID = active.defaultModelID {
            requestedModelID = defaultModelID
        } else {
            return nil
        }
        guard let model = AIProviderRuntimeEligibility.runnableModel(
                  id: requestedModelID,
                  in: active
              )
        else {
            return nil
        }
        let normalizedModel = AppSettings.normalizedAIModelName(model.id)
        guard normalizedModel.isEmpty == false else { return nil }

        // API Key 经 Keychain 读取（Loopback 可无 Key）。目录声明无需鉴权
        // 时不读取 Keychain，避免历史残留密钥被附加到本地请求。
        let requiresCredential = AIProviderCredentialOriginPolicy.requiresCredential(
            for: active,
            runtimeCatalog: runtimeCatalog
        )
        let apiKey: String?
        if requiresCredential {
            do {
                apiKey = AIProviderCredentialOriginPolicy.credentialForRequest(
                    try keyStore.readAPIKey(for: active.id),
                    provider: active,
                    runtimeCatalog: runtimeCatalog
                )
            } catch {
                apiKey = nil
            }
        } else {
            apiKey = nil
        }
        guard apiKey != nil || AIEndpointSecurityPolicy.isLoopbackHost(baseURL.host) else {
            return nil
        }

        // V1 has no immutable CredentialGeneration record. Use the latest
        // successful, non-secret verification timestamp as a stable migration
        // identity. An unverified legacy record receives an in-process identity,
        // so a durable queued input fails closed after relaunch instead of being
        // rebound to credential material that cannot be proven identical.
        let credentialGenerationID: String?
        if apiKey != nil {
            if let evidenceDate = active.lastVerifiedAt ?? active.lastModelSyncAt {
                credentialGenerationID = [
                    "legacy-provider",
                    active.id.uuidString.lowercased(),
                    String(evidenceDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
                ].joined(separator: ":")
            } else {
                credentialGenerationID = "ephemeral-legacy-\(active.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
            }
        } else {
            credentialGenerationID = nil
        }

        let configuration = ProviderRuntimeConfiguration(
            configurationID: active.id.uuidString,
            configurationRevision: active.catalogRevisionAtCreation ?? 1,
            runtimeConfigurationKind: active.effectiveRuntimeConfigurationKind,
            baseURL: baseURL,
            model: normalizedModel,
            apiKey: apiKey,
            credentialGenerationID: credentialGenerationID,
            requestTimeoutSeconds: active.requestTimeoutSeconds,
            userAgent: active.userAgent,
            supportedReasoningEfforts: model.capabilities.supportedReasoningEfforts
        )

        // 构造真实 V1 流式 provider（apiKeyProvider 闭包捕获已读 Key，不重复读 Keychain）
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: baseURL,
            model: normalizedModel,
            apiKeyProvider: { apiKey },
            transport: transport,
            maxRetryCount: active.maxRetryCount,
            userAgent: active.userAgent,
            requestTimeoutSeconds: active.requestTimeoutSeconds,
            reasoningEffort: resolvedReasoningEffort(
                requested: defaultReasoningEffort,
                model: model
            ),
            compatibilityProtocol: active.compatibilityProtocol
        )

        return (provider, configuration)
    }

    private static func resolvedReasoningEffort(
        requested: AIReasoningEffortPreference,
        model: AIProviderModelConfiguration
    ) -> AIReasoningEffortPreference {
        guard let supported = model.capabilities.supportedReasoningEfforts,
              supported.isEmpty == false
        else {
            return requested
        }
        return supported.contains(requested)
            ? requested
            : model.capabilities.effectiveReasoningEffort
    }
}
