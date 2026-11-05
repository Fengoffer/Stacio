import Foundation

public protocol AIProviderSettingsStoring: AnyObject {
    func loadAIProviderSettings() throws -> AIProviderSettingsEnvelope
    func saveAIProviderSettings(_ envelope: AIProviderSettingsEnvelope) throws
}

public enum AIProviderSettingsStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case writeVerificationFailed
}

public enum BuiltInAIProvider {
    public static let stacioRulesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

public struct AIModelSelection: Codable, Equatable, Hashable {
    public let providerID: UUID
    public let modelID: String

    public init(providerID: UUID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public enum AIModelCapabilitySource: String, Codable, Equatable {
    case unknown
    case catalog
    case manual
}

public struct AIModelCatalogCapabilities: Equatable {
    public var contextWindowTokens: Int?
    public var supportedReasoningEfforts: [AIReasoningEffortPreference]?

    public init(
        contextWindowTokens: Int? = nil,
        supportedReasoningEfforts: [AIReasoningEffortPreference]? = nil
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }
}

public struct AIModelCatalogEntry: Equatable {
    public var id: String
    public var capabilities: AIModelCatalogCapabilities

    public init(
        id: String,
        capabilities: AIModelCatalogCapabilities = .init()
    ) {
        self.id = id
        self.capabilities = capabilities
    }
}

public struct AIModelCapabilityConfiguration: Codable, Equatable {
    public static let defaultContextCharacterLimit = 12_000
    private static let maximumContextWindowTokens = 10_000_000
    private static let estimatedCharactersPerToken = 4
    public static let maximumContextCharacterLimit = maximumContextWindowTokens * estimatedCharactersPerToken

    public var contextWindowTokens: Int?
    public var contextCharacterLimit: Int?
    public var contextCharacterLimitSource: AIModelCapabilitySource
    public var supportedReasoningEfforts: [AIReasoningEffortPreference]?
    public var supportedReasoningEffortsSource: AIModelCapabilitySource
    public var reasoningEffort: AIReasoningEffortPreference?
    public var reasoningEffortSource: AIModelCapabilitySource

    public init(
        contextWindowTokens: Int? = nil,
        contextCharacterLimit: Int? = nil,
        contextCharacterLimitSource: AIModelCapabilitySource = .unknown,
        supportedReasoningEfforts: [AIReasoningEffortPreference]? = nil,
        supportedReasoningEffortsSource: AIModelCapabilitySource = .unknown,
        reasoningEffort: AIReasoningEffortPreference? = nil,
        reasoningEffortSource: AIModelCapabilitySource = .unknown
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.contextCharacterLimit = contextCharacterLimit
        self.contextCharacterLimitSource = contextCharacterLimitSource
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportedReasoningEffortsSource = supportedReasoningEffortsSource
        self.reasoningEffort = reasoningEffort
        self.reasoningEffortSource = reasoningEffortSource
        self = normalized()
    }

    public var effectiveContextCharacterLimit: Int {
        Self.clampedContextCharacterLimit(
            contextCharacterLimit ?? Self.defaultContextCharacterLimit
        )
    }

    public var effectiveReasoningEffort: AIReasoningEffortPreference {
        guard let supportedReasoningEfforts,
              supportedReasoningEfforts.isEmpty == false
        else {
            return reasoningEffort
                ?? (reasoningEffortSource == .unknown ? .medium : .minimal)
        }
        guard let reasoningEffort,
              supportedReasoningEfforts.contains(reasoningEffort)
        else {
            return Self.defaultReasoningEffort(for: supportedReasoningEfforts) ?? .minimal
        }
        return reasoningEffort
    }

    public mutating func applyCatalogCapabilities(_ catalog: AIModelCatalogCapabilities) {
        if let contextWindowTokens = Self.normalizedContextWindowTokens(catalog.contextWindowTokens) {
            self.contextWindowTokens = contextWindowTokens
            if contextCharacterLimitSource != .manual {
                contextCharacterLimit = Self.recommendedContextCharacterLimit(
                    for: contextWindowTokens
                )
                contextCharacterLimitSource = .catalog
            }
        } else if contextCharacterLimitSource == .catalog {
            self.contextWindowTokens = nil
            self.contextCharacterLimit = nil
            self.contextCharacterLimitSource = .unknown
        }

        if let supportedReasoningEfforts = catalog.supportedReasoningEfforts {
            let normalizedEfforts = Self.normalizedReasoningEfforts(supportedReasoningEfforts)
            self.supportedReasoningEfforts = normalizedEfforts
            supportedReasoningEffortsSource = .catalog
            if normalizedEfforts.contains(reasoningEffort ?? .minimal) == false {
                reasoningEffort = Self.defaultReasoningEffort(for: normalizedEfforts)
                reasoningEffortSource = .catalog
            }
        } else if supportedReasoningEffortsSource == .catalog {
            self.supportedReasoningEfforts = nil
            self.supportedReasoningEffortsSource = .unknown
            if reasoningEffortSource == .catalog {
                self.reasoningEffort = nil
                self.reasoningEffortSource = .unknown
            }
        }
        self = normalized()
    }

    public func normalized() -> AIModelCapabilityConfiguration {
        var result = self
        result.contextWindowTokens = Self.normalizedContextWindowTokens(contextWindowTokens)
        if let contextCharacterLimit {
            result.contextCharacterLimit = Self.clampedContextCharacterLimit(contextCharacterLimit)
        }
        if result.contextWindowTokens == nil,
           result.contextCharacterLimit == nil,
           result.contextCharacterLimitSource == .catalog {
            result.contextCharacterLimitSource = .unknown
        }

        if let supportedReasoningEfforts {
            result.supportedReasoningEfforts = Self.normalizedReasoningEfforts(
                supportedReasoningEfforts
            )
        }
        if result.supportedReasoningEfforts == nil,
           result.supportedReasoningEffortsSource == .catalog {
            result.supportedReasoningEffortsSource = .unknown
        }
        if let supportedReasoningEfforts = result.supportedReasoningEfforts,
           supportedReasoningEfforts.isEmpty == false,
           supportedReasoningEfforts.contains(result.reasoningEffort ?? .minimal) == false {
            result.reasoningEffort = Self.defaultReasoningEffort(for: supportedReasoningEfforts)
        }
        return result
    }

    public static func normalizedReasoningEfforts(
        _ efforts: [AIReasoningEffortPreference]
    ) -> [AIReasoningEffortPreference] {
        AIReasoningEffortPreference.allCases.filter(efforts.contains)
    }

    public static func clampedContextCharacterLimit(_ value: Int) -> Int {
        min(max(value, 1), maximumContextCharacterLimit)
    }

    private static func normalizedContextWindowTokens(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return min(value, maximumContextWindowTokens)
    }

    private static func recommendedContextCharacterLimit(for contextWindowTokens: Int) -> Int {
        let estimated = contextWindowTokens > Int.max / estimatedCharactersPerToken
            ? Int.max
            : contextWindowTokens * estimatedCharactersPerToken
        return Self.clampedContextCharacterLimit(estimated)
    }

    private static func defaultReasoningEffort(
        for supportedReasoningEfforts: [AIReasoningEffortPreference]
    ) -> AIReasoningEffortPreference? {
        if supportedReasoningEfforts.contains(.minimal) {
            return .minimal
        }
        return supportedReasoningEfforts.first
    }
}

public struct AIProviderModelConfiguration: Codable, Equatable, Identifiable {
    public var id: String
    public var isEnabled: Bool
    public var isManual: Bool
    public var wasReturnedByLatestCatalog: Bool
    /// Manual model IDs must be verified against the configured endpoint before
    /// they can be enabled or selected as the default model.
    public var lastVerifiedAt: Date?
    public var capabilities: AIModelCapabilityConfiguration

    public init(
        id: String,
        isEnabled: Bool,
        isManual: Bool,
        wasReturnedByLatestCatalog: Bool,
        lastVerifiedAt: Date? = nil,
        capabilities: AIModelCapabilityConfiguration = .init()
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.isManual = isManual
        self.wasReturnedByLatestCatalog = wasReturnedByLatestCatalog
        self.lastVerifiedAt = lastVerifiedAt
        self.capabilities = capabilities.normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case isManual
        case wasReturnedByLatestCatalog
        case lastVerifiedAt
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isManual = try container.decode(Bool.self, forKey: .isManual)
        wasReturnedByLatestCatalog = try container.decode(Bool.self, forKey: .wasReturnedByLatestCatalog)
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        capabilities = try container.decodeIfPresent(
            AIModelCapabilityConfiguration.self,
            forKey: .capabilities
        )?.normalized() ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isManual, forKey: .isManual)
        try container.encode(wasReturnedByLatestCatalog, forKey: .wasReturnedByLatestCatalog)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
        try container.encode(capabilities.normalized(), forKey: .capabilities)
    }
}

public enum AIProviderBaseURLSource: String, Codable, Equatable {
    case catalogSuggestion
    case userProvided
    case legacyMigration
}

public enum AIProviderRuntimeConfigurationKind: String, Codable, Equatable, Sendable {
    case provider
    case codingPlan
}

public struct AIProviderConfiguration: Codable, Equatable, Identifiable {
    public var id: UUID
    public var profile: AIProviderProfile
    public var displayName: String
    public var baseURL: String
    public var models: [AIProviderModelConfiguration]
    public var defaultModelID: String?
    public var compatibilityProtocol: AICompatibilityProtocolPreference
    public var maxRetryCount: Int
    public var requestTimeoutSeconds: Int
    public var userAgent: String
    public var isEnabled: Bool
    public var lastVerifiedAt: Date?
    public var lastModelSyncAt: Date?
    /// Immutable catalog identity. Descriptor updates never mutate this configuration.
    public var catalogID: String?
    public var catalogRevisionAtCreation: Int?
    public var baseURLSource: AIProviderBaseURLSource?
    public var wasBaseURLUserEdited: Bool?
    /// Normalized origin the user explicitly approved for credential-bearing
    /// requests. Catalog-suggested origins do not need a persisted approval.
    /// This local trust decision is deliberately removed from exports/imports.
    public var confirmedCredentialOrigin: String?
    /// Optional for backward-compatible decoding of V1 provider records.
    /// New Coding Plan records set this explicitly so routing never infers the
    /// configuration kind from a display name or URL.
    public var runtimeConfigurationKind: AIProviderRuntimeConfigurationKind?

    public init(
        id: UUID,
        profile: AIProviderProfile,
        displayName: String,
        baseURL: String,
        models: [AIProviderModelConfiguration],
        defaultModelID: String?,
        compatibilityProtocol: AICompatibilityProtocolPreference,
        maxRetryCount: Int,
        requestTimeoutSeconds: Int,
        userAgent: String,
        isEnabled: Bool,
        lastVerifiedAt: Date?,
        lastModelSyncAt: Date?,
        catalogID: String? = nil,
        catalogRevisionAtCreation: Int? = nil,
        baseURLSource: AIProviderBaseURLSource? = nil,
        wasBaseURLUserEdited: Bool? = nil,
        confirmedCredentialOrigin: String? = nil,
        runtimeConfigurationKind: AIProviderRuntimeConfigurationKind? = nil
    ) {
        self.id = id
        self.profile = profile
        self.displayName = displayName
        self.baseURL = baseURL
        self.models = models
        self.defaultModelID = defaultModelID
        self.compatibilityProtocol = compatibilityProtocol
        self.maxRetryCount = maxRetryCount
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.userAgent = userAgent
        self.isEnabled = isEnabled
        self.lastVerifiedAt = lastVerifiedAt
        self.lastModelSyncAt = lastModelSyncAt
        self.catalogID = catalogID
        self.catalogRevisionAtCreation = catalogRevisionAtCreation
        self.baseURLSource = baseURLSource
        self.wasBaseURLUserEdited = wasBaseURLUserEdited
        self.confirmedCredentialOrigin = confirmedCredentialOrigin
        self.runtimeConfigurationKind = runtimeConfigurationKind
    }

    public var effectiveRuntimeConfigurationKind: AIProviderRuntimeConfigurationKind {
        runtimeConfigurationKind ?? .provider
    }

    public var userEditedBaseURL: Bool {
        wasBaseURLUserEdited ?? (baseURLSource == .userProvided)
    }

    public mutating func applyUserBaseURL(_ value: String) {
        let previousOrigin = Self.normalizedCredentialOrigin(for: baseURL)
        let nextOrigin = Self.normalizedCredentialOrigin(for: value)
        baseURL = value
        baseURLSource = .userProvided
        wasBaseURLUserEdited = true
        if previousOrigin != nextOrigin {
            confirmedCredentialOrigin = nil
        }
        invalidateVerificationForEndpointChange()
    }

    public mutating func restoreCatalogBaseURL(_ value: String, catalogRevision: Int) {
        let previousOrigin = Self.normalizedCredentialOrigin(for: baseURL)
        let nextOrigin = Self.normalizedCredentialOrigin(for: value)
        baseURL = value
        catalogRevisionAtCreation = catalogRevision
        baseURLSource = .catalogSuggestion
        wasBaseURLUserEdited = false
        if previousOrigin != nextOrigin {
            confirmedCredentialOrigin = nil
        }
        invalidateVerificationForEndpointChange()
    }

    private static func normalizedCredentialOrigin(for rawBaseURL: String) -> String? {
        guard let url = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: rawBaseURL) else {
            return nil
        }
        return WebsiteActionResolver.normalizedOrigin(url: url)
    }

    public mutating func invalidateVerificationForEndpointChange() {
        lastVerifiedAt = nil
        lastModelSyncAt = nil
        for index in models.indices {
            models[index].lastVerifiedAt = nil
            if !models[index].isManual {
                models[index].wasReturnedByLatestCatalog = false
            }
        }
        isEnabled = false
    }

    public static func catalogDraft(
        descriptor: ProviderCatalogEntry,
        id: UUID = UUID()
    ) -> AIProviderConfiguration? {
        guard descriptor.supportLevel != .unsupported,
              descriptor.protocolFamily == .openAICompatible,
              let profileRawValue = descriptor.legacyProfileRawValue,
              let profile = AIProviderProfile.recognizedProfile(for: profileRawValue)
        else {
            return nil
        }
        return AIProviderConfiguration(
            id: id,
            profile: profile,
            displayName: descriptor.displayName,
            baseURL: descriptor.suggestedBaseURL ?? "",
            models: [],
            defaultModelID: nil,
            compatibilityProtocol: .chatCompletions,
            maxRetryCount: 1,
            requestTimeoutSeconds: 60,
            userAgent: "Stacio",
            isEnabled: false,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil,
            catalogID: descriptor.catalogID,
            catalogRevisionAtCreation: descriptor.revision,
            baseURLSource: descriptor.suggestedBaseURL == nil ? .userProvided : .catalogSuggestion,
            wasBaseURLUserEdited: descriptor.suggestedBaseURL == nil
        )
    }

    public static func catalogDraft(
        descriptor: CodingPlanCatalogEntry,
        id: UUID = UUID()
    ) -> AIProviderConfiguration? {
        let nativeEntry = NativeRuntimeCatalogEntry.codingPlan(descriptor)
        guard nativeEntry.isExecutableByNativeRuntime,
              let suggestedBaseURL = descriptor.suggestedBaseURL
        else {
            return nil
        }
        return AIProviderConfiguration(
            id: id,
            profile: .openAICompatible,
            displayName: descriptor.displayName,
            baseURL: suggestedBaseURL,
            models: [],
            defaultModelID: nil,
            compatibilityProtocol: .chatCompletions,
            maxRetryCount: 1,
            requestTimeoutSeconds: 60,
            userAgent: "Stacio",
            isEnabled: false,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil,
            catalogID: descriptor.catalogID,
            catalogRevisionAtCreation: descriptor.revision,
            baseURLSource: .catalogSuggestion,
            wasBaseURLUserEdited: false,
            runtimeConfigurationKind: .codingPlan
        )
    }

    public static func catalogDraft(
        descriptor: NativeRuntimeCatalogEntry,
        id: UUID = UUID()
    ) -> AIProviderConfiguration? {
        switch descriptor {
        case .provider(let provider):
            return catalogDraft(descriptor: provider, id: id)
        case .codingPlan(let plan):
            return catalogDraft(descriptor: plan, id: id)
        }
    }
}

public struct AIProviderSettingsEnvelope: Codable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var aiProviders: [AIProviderConfiguration]
    public var defaultAIProviderID: UUID
    public var legacyKeyMigrationProviderID: UUID?

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        aiProviders: [AIProviderConfiguration],
        defaultAIProviderID: UUID,
        legacyKeyMigrationProviderID: UUID? = nil
    ) {
        self.formatVersion = formatVersion
        self.aiProviders = aiProviders
        self.defaultAIProviderID = defaultAIProviderID
        self.legacyKeyMigrationProviderID = legacyKeyMigrationProviderID
    }

    public static let rulesOnly = AIProviderSettingsEnvelope(
        aiProviders: [],
        defaultAIProviderID: BuiltInAIProvider.stacioRulesID,
        legacyKeyMigrationProviderID: nil
    )

    /// 新安装默认：无隐式供应商（规格 §9.3）。mozhe 不再是虚拟预置项，
    /// 只有用户显式添加后才出现在 `aiProviders` 中。
    public static var defaultConfiguration: AIProviderSettingsEnvelope {
        rulesOnly
    }
}

public enum AIProviderSettingsNormalizer {
    public static func normalized(_ envelope: AIProviderSettingsEnvelope) -> AIProviderSettingsEnvelope {
        var result = envelope
        result.aiProviders = envelope.aiProviders.compactMap { provider in
            guard provider.id != BuiltInAIProvider.stacioRulesID,
                  provider.profile.usesModelInterface
            else {
                return nil
            }
            return normalizedProvider(provider)
        }

        if envelope.defaultAIProviderID == BuiltInAIProvider.stacioRulesID {
            result.defaultAIProviderID = BuiltInAIProvider.stacioRulesID
        } else if result.aiProviders.contains(where: {
            $0.id == envelope.defaultAIProviderID
        }) == false {
            // A deleted or unknown provider cannot remain selected. A provider
            // that still exists keeps its identity even while disabled,
            // unverified, or missing a runnable model; runtime eligibility is a
            // separate concern and must not erase the user's default choice.
            result.defaultAIProviderID = BuiltInAIProvider.stacioRulesID
        }

        if let migrationProviderID = result.legacyKeyMigrationProviderID,
           result.aiProviders.contains(where: { $0.id == migrationProviderID }) == false {
            result.legacyKeyMigrationProviderID = nil
        }

        return result
    }

    private static func normalizedProvider(
        _ provider: AIProviderConfiguration
    ) -> AIProviderConfiguration {
        var result = provider
        var seenModelIDs = Set<String>()
        result.models = provider.models.compactMap { model in
            let normalizedID = AppSettings.normalizedAIModelName(model.id)
            guard normalizedID.isEmpty == false,
                  seenModelIDs.insert(normalizedID).inserted
            else {
                return nil
            }
            var normalizedModel = model
            normalizedModel.id = normalizedID
            normalizedModel.capabilities = normalizedModel.capabilities.normalized()
            return normalizedModel
        }

        let requestedDefaultModelID = provider.defaultModelID.map(AppSettings.normalizedAIModelName)
        if let requestedDefaultModelID,
           let defaultModel = result.models.first(where: { $0.id == requestedDefaultModelID }),
           AIProviderRuntimeEligibility.isModelRunnable(defaultModel, in: result) {
            result.defaultModelID = requestedDefaultModelID
        } else {
            result.defaultModelID = nil
        }

        if result.defaultModelID == nil {
            result.isEnabled = false
        }
        if result.catalogID != nil, result.lastVerifiedAt == nil {
            result.isEnabled = false
        }

        result.maxRetryCount = AppSettings.clampedAIRetryCount(provider.maxRetryCount)
        result.requestTimeoutSeconds = AppSettings.clampedAITimeoutSeconds(provider.requestTimeoutSeconds)
        result.userAgent = AppSettings.normalizedAIUserAgent(provider.userAgent)
        let currentOrigin = OpenAICompatibleAIAssistantProvider
            .normalizedBaseURL(from: result.baseURL)
            .flatMap(WebsiteActionResolver.normalizedOrigin(url:))
        if result.confirmedCredentialOrigin != currentOrigin {
            result.confirmedCredentialOrigin = nil
        }
        return result
    }

}
