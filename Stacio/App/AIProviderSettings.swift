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
    public var capabilities: AIModelCapabilityConfiguration

    public init(
        id: String,
        isEnabled: Bool,
        isManual: Bool,
        wasReturnedByLatestCatalog: Bool,
        capabilities: AIModelCapabilityConfiguration = .init()
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.isManual = isManual
        self.wasReturnedByLatestCatalog = wasReturnedByLatestCatalog
        self.capabilities = capabilities.normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case isManual
        case wasReturnedByLatestCatalog
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isManual = try container.decode(Bool.self, forKey: .isManual)
        wasReturnedByLatestCatalog = try container.decode(Bool.self, forKey: .wasReturnedByLatestCatalog)
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
        try container.encode(capabilities.normalized(), forKey: .capabilities)
    }
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
        lastModelSyncAt: Date?
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
}

public enum AIProviderSettingsNormalizer {
    public static func normalized(_ envelope: AIProviderSettingsEnvelope) -> AIProviderSettingsEnvelope {
        var result = envelope
        result.aiProviders = envelope.aiProviders.map(normalizedProvider)

        if envelope.defaultAIProviderID == BuiltInAIProvider.stacioRulesID {
            result.defaultAIProviderID = BuiltInAIProvider.stacioRulesID
        } else if eligibleProvider(
            id: envelope.defaultAIProviderID,
            in: result.aiProviders
        ) == nil {
            result.defaultAIProviderID = result.aiProviders.first(where: isEligible)?.id
                ?? BuiltInAIProvider.stacioRulesID
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
           result.models.contains(where: { $0.id == requestedDefaultModelID && $0.isEnabled }) {
            result.defaultModelID = requestedDefaultModelID
        } else {
            result.defaultModelID = result.models.first(where: \.isEnabled)?.id
        }

        if result.defaultModelID == nil {
            result.isEnabled = false
        }

        result.maxRetryCount = AppSettings.clampedAIRetryCount(provider.maxRetryCount)
        result.requestTimeoutSeconds = AppSettings.clampedAITimeoutSeconds(provider.requestTimeoutSeconds)
        result.userAgent = AppSettings.normalizedAIUserAgent(provider.userAgent)
        return result
    }

    private static func eligibleProvider(
        id: UUID,
        in providers: [AIProviderConfiguration]
    ) -> AIProviderConfiguration? {
        providers.first { $0.id == id && isEligible($0) }
    }

    private static func isEligible(_ provider: AIProviderConfiguration) -> Bool {
        guard provider.id != BuiltInAIProvider.stacioRulesID,
              provider.isEnabled,
              let defaultModelID = provider.defaultModelID
        else {
            return false
        }
        return provider.models.contains { $0.id == defaultModelID && $0.isEnabled }
    }
}
