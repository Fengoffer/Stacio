import Foundation

// MARK: - Catalog 支持分级（GA/Experimental/Unsupported）

public enum CatalogSupportLevel: String, Codable, Equatable, Sendable {
    case ga
    case experimental
    case unsupported

    /// Experimental 不默认、不 fallback：只有显式选择才可用。
    public var isDefaultable: Bool { self == .ga }
    public var isFallbackable: Bool { self == .ga }
}

public enum CatalogProtocolFamily: String, Codable, Equatable, Sendable {
    case openAICompatible
    case anthropicMessages
    case localAgent
}

public enum CatalogAuthenticationKind: String, Codable, Equatable, Sendable {
    case bearerAPIKey
    case none
    case cliManaged
}

public enum CatalogModelDiscoveryStrategy: String, Codable, Equatable, Sendable {
    case openAIModels
    case anthropicModels
    case manualOnly
    case cliManaged
    case unavailable
}

public enum CodingPlanKind: String, Codable, Equatable, Sendable {
    case apiKeyNative
    case restrictedLocalAgent
    case accountSubscription
}

public enum CatalogCredentialOwner: String, Codable, Equatable, Sendable {
    case stacioKeychain
    case supportedCLI
}

public enum CatalogRuntimeKind: String, Codable, Equatable, Sendable {
    case nativeAPI
    case localAgent
}

public enum CatalogCredentialInjectionKind: String, Codable, Equatable, Sendable {
    case dedicatedStdin
    case temporaryEnvironment
    case officialCLIConfiguration
    case cliManagedAccount
}

// MARK: - Provider Catalog

/// Provider 目录条目：`catalogID` 一经发布永不复用；废弃条目保留 tombstone/alias。
/// `officialOwner` 为 nil 的条目（如 `provider.openai-compatible.custom`）不得伪造官网按钮。
public struct ProviderCatalogEntry: Codable, Equatable, Sendable {
    public let catalogID: String
    public let schemaVersion: Int
    public let revision: Int
    public let providerID: String
    public let displayName: String
    public let aliases: [String]
    public let protocolFamily: CatalogProtocolFamily
    public let authenticationKind: CatalogAuthenticationKind
    public let suggestedBaseURL: String?
    public let modelDiscoveryStrategy: CatalogModelDiscoveryStrategy
    public let permitsNoCredential: Bool
    public let websiteActionIDs: [String]
    public let usageRestriction: String?
    public let documentationSources: [String]
    /// Temporary bridge identity for decoding V1 configurations. It is not a source of provider facts.
    public let legacyProfileRawValue: String?
    public let officialOwner: String?
    public let officialActionURL: String?
    public let supportLevel: CatalogSupportLevel
    public let tombstone: String?
    public let alias: String?

    public init(
        catalogID: String, providerID: String, displayName: String,
        officialOwner: String?, officialActionURL: String?,
        supportLevel: CatalogSupportLevel, tombstone: String? = nil, alias: String? = nil,
        schemaVersion: Int = 1, revision: Int = 1, aliases: [String] = [],
        protocolFamily: CatalogProtocolFamily = .openAICompatible,
        authenticationKind: CatalogAuthenticationKind = .bearerAPIKey,
        suggestedBaseURL: String? = nil,
        modelDiscoveryStrategy: CatalogModelDiscoveryStrategy = .openAIModels,
        permitsNoCredential: Bool = false, websiteActionIDs: [String] = [],
        usageRestriction: String? = nil, documentationSources: [String] = [],
        legacyProfileRawValue: String? = nil
    ) {
        self.catalogID = catalogID
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.providerID = providerID
        self.displayName = displayName
        self.aliases = aliases
        self.protocolFamily = protocolFamily
        self.authenticationKind = authenticationKind
        self.suggestedBaseURL = suggestedBaseURL
        self.modelDiscoveryStrategy = modelDiscoveryStrategy
        self.permitsNoCredential = permitsNoCredential
        self.websiteActionIDs = websiteActionIDs
        self.usageRestriction = usageRestriction
        self.documentationSources = documentationSources
        self.legacyProfileRawValue = legacyProfileRawValue
        self.officialOwner = officialOwner
        self.officialActionURL = officialActionURL
        self.supportLevel = supportLevel
        self.tombstone = tombstone
        self.alias = alias
    }

    public var hasOfficialOwner: Bool { officialOwner != nil && !officialOwner!.isEmpty }
    /// 无官方 owner 的条目不得伪造官网按钮（officialActionURL 必须为空）。
    public var noForgedOfficialButton: Bool {
        hasOfficialOwner || officialActionURL == nil || officialActionURL!.isEmpty
    }

    public var requiresCredential: Bool {
        !permitsNoCredential && authenticationKind != .none
    }

    public var allowsManualModelIDs: Bool {
        modelDiscoveryStrategy == .manualOnly
    }
}

// MARK: - Coding Plan Catalog

public struct CodingPlanCatalogEntry: Codable, Equatable, Sendable {
    public let catalogID: String
    public let schemaVersion: Int
    public let revision: Int
    public let planID: String
    public let displayName: String
    public let aliases: [String]
    public let planKind: CodingPlanKind
    public let credentialOwner: CatalogCredentialOwner
    public let authenticationKind: CatalogAuthenticationKind
    public let suggestedBaseURL: String?
    public let modelDiscoveryStrategy: CatalogModelDiscoveryStrategy
    public let authorizationScope: String
    public let quotaActionID: String?
    public let websiteActionIDs: [String]
    public let allowedRuntimeKinds: [CatalogRuntimeKind]
    public let documentationSources: [String]
    public let supportLevel: CatalogSupportLevel
    public let tombstone: String?
    public let alias: String?

    public init(
        catalogID: String, planID: String, displayName: String,
        supportLevel: CatalogSupportLevel, tombstone: String? = nil, alias: String? = nil,
        schemaVersion: Int = 1, revision: Int = 1, aliases: [String] = [],
        planKind: CodingPlanKind = .apiKeyNative,
        credentialOwner: CatalogCredentialOwner = .stacioKeychain,
        authenticationKind: CatalogAuthenticationKind = .bearerAPIKey,
        suggestedBaseURL: String? = nil,
        modelDiscoveryStrategy: CatalogModelDiscoveryStrategy = .openAIModels,
        authorizationScope: String = "",
        quotaActionID: String? = nil, websiteActionIDs: [String] = [],
        allowedRuntimeKinds: [CatalogRuntimeKind] = [.nativeAPI],
        documentationSources: [String] = []
    ) {
        self.catalogID = catalogID
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.planID = planID
        self.displayName = displayName
        self.aliases = aliases
        self.planKind = planKind
        self.credentialOwner = credentialOwner
        self.authenticationKind = authenticationKind
        self.suggestedBaseURL = suggestedBaseURL
        self.modelDiscoveryStrategy = modelDiscoveryStrategy
        self.authorizationScope = authorizationScope
        self.quotaActionID = quotaActionID
        self.websiteActionIDs = websiteActionIDs
        self.allowedRuntimeKinds = allowedRuntimeKinds
        self.documentationSources = documentationSources
        self.supportLevel = supportLevel
        self.tombstone = tombstone
        self.alias = alias
    }
}

// MARK: - Local Agent Catalog

public enum LocalAgentExecutableCandidateKind: String, Codable, Equatable, Sendable {
    case pathLookup
    case homeRelative
    case absolute
}

/// Candidate search input only. Detection never turns one of these values into
/// an executable configuration without a separate user confirmation and probe.
public struct LocalAgentExecutableCandidate: Codable, Equatable, Sendable {
    public let kind: LocalAgentExecutableCandidateKind
    public let value: String

    public init(kind: LocalAgentExecutableCandidateKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum LocalAgentStructuredProtocol: String, Codable, Equatable, Sendable {
    case jsonl
    case rpc
    case acp
}

public enum LocalAgentPATHPolicy: String, Codable, Equatable, Sendable {
    case controlled
    case loginShell
    case custom
}

public struct LocalAgentExecutionProfileDescriptor: Codable, Equatable, Sendable {
    public let profileID: String
    public let revision: Int
    public let kind: LocalAgentExecutionProfileKind
    public let supportLevel: CatalogSupportLevel

    public init(
        profileID: String,
        revision: Int,
        kind: LocalAgentExecutionProfileKind,
        supportLevel: CatalogSupportLevel
    ) {
        self.profileID = profileID
        self.revision = revision
        self.kind = kind
        self.supportLevel = supportLevel
    }
}

public struct LocalAgentCatalogEntry: Codable, Equatable, Sendable {
    public let catalogID: String
    public let schemaVersion: Int
    public let revision: Int
    public let rawIdentity: String
    public let displayName: String
    public let aliases: [String]
    public let executableCandidates: [LocalAgentExecutableCandidate]
    public let supportedOSVersions: [String]
    public let supportedArchitectures: [String]
    public let versionArgv: [String]
    public let capabilityProbeArgv: [String]?
    public let loginStatusArgv: [String]?
    public let loginArgv: [String]?
    public let logoutArgv: [String]?
    public let terminalPassthroughArgv: [String]
    public let executionProfiles: [LocalAgentExecutionProfileDescriptor]
    public let upgradeActionID: String?
    public let structuredProtocolPriority: [LocalAgentStructuredProtocol]
    public let permitsPTYFallback: Bool
    public let supportedCapabilities: [String]
    public let supportedWorkingDirectoryModes: [AgentProcessWorkingDirectoryMode]
    public let defaultPATHPolicy: LocalAgentPATHPolicy
    public let defaultEnvironmentAllowlist: [String]
    public let websiteActionIDs: [String]
    public let documentationSources: [String]
    public let supportLevel: CatalogSupportLevel
    public let tombstone: String?
    public let alias: String?

    public init(
        catalogID: String, rawIdentity: String, displayName: String,
        supportLevel: CatalogSupportLevel, tombstone: String? = nil, alias: String? = nil,
        schemaVersion: Int = 1, revision: Int = 1, aliases: [String] = [],
        executableCandidates: [LocalAgentExecutableCandidate] = [],
        supportedOSVersions: [String] = [], supportedArchitectures: [String] = [],
        versionArgv: [String] = [], capabilityProbeArgv: [String]? = nil,
        loginStatusArgv: [String]? = nil, loginArgv: [String]? = nil,
        logoutArgv: [String]? = nil, terminalPassthroughArgv: [String] = [],
        executionProfiles: [LocalAgentExecutionProfileDescriptor] = [],
        upgradeActionID: String? = nil,
        structuredProtocolPriority: [LocalAgentStructuredProtocol] = [],
        permitsPTYFallback: Bool = false, supportedCapabilities: [String] = [],
        supportedWorkingDirectoryModes: [AgentProcessWorkingDirectoryMode] = [],
        defaultPATHPolicy: LocalAgentPATHPolicy = .controlled,
        defaultEnvironmentAllowlist: [String] = [], websiteActionIDs: [String] = [],
        documentationSources: [String] = []
    ) {
        self.catalogID = catalogID
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.rawIdentity = rawIdentity
        self.displayName = displayName
        self.aliases = aliases
        self.executableCandidates = executableCandidates
        self.supportedOSVersions = supportedOSVersions
        self.supportedArchitectures = supportedArchitectures
        self.versionArgv = versionArgv
        self.capabilityProbeArgv = capabilityProbeArgv
        self.loginStatusArgv = loginStatusArgv
        self.loginArgv = loginArgv
        self.logoutArgv = logoutArgv
        self.terminalPassthroughArgv = terminalPassthroughArgv
        self.executionProfiles = executionProfiles
        self.upgradeActionID = upgradeActionID
        self.structuredProtocolPriority = structuredProtocolPriority
        self.permitsPTYFallback = permitsPTYFallback
        self.supportedCapabilities = supportedCapabilities
        self.supportedWorkingDirectoryModes = supportedWorkingDirectoryModes
        self.defaultPATHPolicy = defaultPATHPolicy
        self.defaultEnvironmentAllowlist = defaultEnvironmentAllowlist
        self.websiteActionIDs = websiteActionIDs
        self.documentationSources = documentationSources
        self.supportLevel = supportLevel
        self.tombstone = tombstone
        self.alias = alias
    }

    public var isExecutableCandidate: Bool {
        tombstone == nil && supportLevel != .unsupported
    }
}

// MARK: - Plan-Agent 兼容性

public struct PlanAgentCompatibilityEntry: Codable, Equatable, Sendable {
    public let planID: String
    public let agentRawIdentity: String
    public let compatible: Bool
    public let supportedVersionRange: String?
    public let credentialInjectionKind: CatalogCredentialInjectionKind?
    public let allowedCapabilities: [String]
    public let authorizationNotes: String?
    public let supportLevel: CatalogSupportLevel
    public let lastVerifiedCatalogRevision: Int?

    public init(
        planID: String, agentRawIdentity: String, compatible: Bool,
        supportedVersionRange: String? = nil,
        credentialInjectionKind: CatalogCredentialInjectionKind? = nil,
        allowedCapabilities: [String] = [], authorizationNotes: String? = nil,
        supportLevel: CatalogSupportLevel = .experimental,
        lastVerifiedCatalogRevision: Int? = nil
    ) {
        self.planID = planID
        self.agentRawIdentity = agentRawIdentity
        self.compatible = compatible
        self.supportedVersionRange = supportedVersionRange
        self.credentialInjectionKind = credentialInjectionKind
        self.allowedCapabilities = allowedCapabilities
        self.authorizationNotes = authorizationNotes
        self.supportLevel = supportLevel
        self.lastVerifiedCatalogRevision = lastVerifiedCatalogRevision
    }
}

// MARK: - Native configuration catalog projection

/// A configuration that can execute through Stacio's Native API runtime.
/// Provider and Coding Plan identities remain distinct even though they share
/// the same editable endpoint/model UI and OpenAI-compatible transport.
public enum NativeRuntimeCatalogEntry: Equatable, Sendable {
    case provider(ProviderCatalogEntry)
    case codingPlan(CodingPlanCatalogEntry)

    public var catalogID: String {
        switch self {
        case .provider(let entry): return entry.catalogID
        case .codingPlan(let entry): return entry.catalogID
        }
    }

    public var revision: Int {
        switch self {
        case .provider(let entry): return entry.revision
        case .codingPlan(let entry): return entry.revision
        }
    }

    public var displayName: String {
        switch self {
        case .provider(let entry): return entry.displayName
        case .codingPlan(let entry): return entry.displayName
        }
    }

    public var aliases: [String] {
        switch self {
        case .provider(let entry): return entry.aliases
        case .codingPlan(let entry): return entry.aliases
        }
    }

    public var suggestedBaseURL: String? {
        switch self {
        case .provider(let entry): return entry.suggestedBaseURL
        case .codingPlan(let entry): return entry.suggestedBaseURL
        }
    }

    public var authenticationKind: CatalogAuthenticationKind {
        switch self {
        case .provider(let entry): return entry.authenticationKind
        case .codingPlan(let entry): return entry.authenticationKind
        }
    }

    public var protocolFamily: CatalogProtocolFamily {
        switch self {
        case .provider(let entry): return entry.protocolFamily
        case .codingPlan: return .openAICompatible
        }
    }

    public var modelDiscoveryStrategy: CatalogModelDiscoveryStrategy {
        switch self {
        case .provider(let entry): return entry.modelDiscoveryStrategy
        case .codingPlan(let entry): return entry.modelDiscoveryStrategy
        }
    }

    public var supportLevel: CatalogSupportLevel {
        switch self {
        case .provider(let entry): return entry.supportLevel
        case .codingPlan(let entry): return entry.supportLevel
        }
    }

    public var isCodingPlan: Bool {
        if case .codingPlan = self { return true }
        return false
    }

    public var requiresCredential: Bool {
        switch self {
        case .provider(let entry): return entry.requiresCredential
        case .codingPlan: return authenticationKind != .none
        }
    }

    public var permitsNoCredential: Bool {
        switch self {
        case .provider(let entry): return entry.permitsNoCredential
        case .codingPlan: return authenticationKind == .none
        }
    }

    public var allowsManualModelIDs: Bool {
        guard case .provider(let entry) = self else { return false }
        return entry.allowsManualModelIDs
    }

    public var isExecutableByNativeRuntime: Bool {
        guard supportLevel != .unsupported else { return false }
        switch self {
        case .provider(let entry):
            return entry.tombstone == nil && entry.protocolFamily == .openAICompatible
        case .codingPlan(let entry):
            return entry.tombstone == nil
                && entry.planKind == .apiKeyNative
                && entry.allowedRuntimeKinds == [.nativeAPI]
                && entry.credentialOwner == .stacioKeychain
                && entry.authenticationKind == .bearerAPIKey
                && entry.modelDiscoveryStrategy == .openAIModels
        }
    }
}

// MARK: - Website Action Catalog

/// 官网 action：owner 唯一 + primary 标记；至少一个非推广官方主动作。
public struct WebsiteActionEntry: Codable, Equatable, Sendable {
    public let actionID: String
    public let ownerCatalogID: String
    public let kind: WebsiteActionKind
    public let title: String
    public let url: String
    public let displayOrder: Int
    public let isPrimary: Bool
    public let isPromotional: Bool
    public let source: WebsiteActionSource
    public let verifiedAt: Date?
    public let supportLevel: CatalogSupportLevel

    public init(actionID: String, owner: String, primary: Bool, nonPromotional: Bool, url: String) {
        self.actionID = actionID
        self.ownerCatalogID = owner
        self.kind = .website
        self.title = owner
        self.url = url
        self.displayOrder = 0
        self.isPrimary = primary
        self.isPromotional = !nonPromotional
        self.source = .catalog
        self.verifiedAt = nil
        self.supportLevel = .ga
    }

    public init(
        actionID: String, ownerCatalogID: String, kind: WebsiteActionKind,
        title: String, url: String, displayOrder: Int, isPrimary: Bool,
        isPromotional: Bool, source: WebsiteActionSource = .catalog,
        verifiedAt: Date?, supportLevel: CatalogSupportLevel
    ) {
        self.actionID = actionID
        self.ownerCatalogID = ownerCatalogID
        self.kind = kind
        self.title = title
        self.url = url
        self.displayOrder = displayOrder
        self.isPrimary = isPrimary
        self.isPromotional = isPromotional
        self.source = source
        self.verifiedAt = verifiedAt
        self.supportLevel = supportLevel
    }

    public var owner: String { ownerCatalogID }
    public var primary: Bool { isPrimary }
    public var nonPromotional: Bool { !isPromotional }

    public var descriptor: WebsiteActionDescriptor? {
        guard let resolvedURL = URL(string: url) else { return nil }
        return WebsiteActionDescriptor(
            actionID: actionID,
            owner: ownerCatalogID,
            kind: kind,
            title: title,
            url: resolvedURL,
            displayOrder: displayOrder,
            isPrimary: isPrimary,
            isPromotional: isPromotional,
            source: source,
            verifiedAt: verifiedAt,
            supportLevel: supportLevel
        )
    }
}

// MARK: - Provider Pricing Catalog

/// 价格条目：半开区间 `[effectiveFrom, effectiveUntil)`；`effectiveUntil == nil` 表示无穷。
/// 同一 provider+model 的区间不得重叠（边界相接 `a.until == b.from` 不重叠）。
public struct PricingEntry: Codable, Equatable, Sendable {
    public let pricingEntryID: String
    public let providerID: String
    public let modelID: String
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let inputPerMillion: Double
    public let outputPerMillion: Double

    public init(
        pricingEntryID: String, providerID: String, modelID: String,
        effectiveFrom: Date, effectiveUntil: Date?,
        inputPerMillion: Double, outputPerMillion: Double
    ) {
        self.pricingEntryID = pricingEntryID
        self.providerID = providerID
        self.modelID = modelID
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// 半开区间语义：`[from, until)`。
    public func overlaps(_ other: PricingEntry) -> Bool {
        guard providerID == other.providerID, modelID == other.modelID else { return false }
        return self.effectiveFrom < other.effectiveUntil ?? .distantFuture
            && other.effectiveFrom < self.effectiveUntil ?? .distantFuture
    }
}

// MARK: - 原子 Catalog Set

public struct RuntimeCatalogSet: Equatable, Sendable {
    public let catalogSetRevision: Int
    public let providers: [ProviderCatalogEntry]
    public let codingPlans: [CodingPlanCatalogEntry]
    public let localAgents: [LocalAgentCatalogEntry]
    public let planAgentCompatibility: [PlanAgentCompatibilityEntry]
    public let websiteActions: [WebsiteActionEntry]
    public let pricing: [PricingEntry]
    public let toolCatalog: StacioToolCatalog

    public init(
        catalogSetRevision: Int,
        providers: [ProviderCatalogEntry],
        codingPlans: [CodingPlanCatalogEntry],
        localAgents: [LocalAgentCatalogEntry],
        planAgentCompatibility: [PlanAgentCompatibilityEntry],
        websiteActions: [WebsiteActionEntry],
        pricing: [PricingEntry],
        toolCatalog: StacioToolCatalog
    ) {
        self.catalogSetRevision = catalogSetRevision
        self.providers = providers
        self.codingPlans = codingPlans
        self.localAgents = localAgents
        self.planAgentCompatibility = planAgentCompatibility
        self.websiteActions = websiteActions
        self.pricing = pricing
        self.toolCatalog = toolCatalog
    }

    /// Experimental 条目不默认、不 fallback：默认集合只含 GA。
    public func defaultableProviders() -> [ProviderCatalogEntry] {
        providers.filter { $0.supportLevel.isDefaultable && $0.tombstone == nil }
    }

    public func provider(catalogID: String?) -> ProviderCatalogEntry? {
        guard let catalogID else { return nil }
        return providers.first { $0.catalogID == catalogID && $0.tombstone == nil }
    }

    public func codingPlan(catalogID: String?) -> CodingPlanCatalogEntry? {
        guard let catalogID else { return nil }
        return codingPlans.first { $0.catalogID == catalogID && $0.tombstone == nil }
    }

    public func localAgent(catalogID: String?) -> LocalAgentCatalogEntry? {
        guard let catalogID else { return nil }
        return localAgents.first { $0.catalogID == catalogID && $0.tombstone == nil }
    }

    public func localAgent(rawIdentity: String?) -> LocalAgentCatalogEntry? {
        guard let rawIdentity else { return nil }
        return localAgents.first { $0.rawIdentity == rawIdentity && $0.tombstone == nil }
    }

    public func nativeRuntimeEntry(catalogID: String?) -> NativeRuntimeCatalogEntry? {
        if let provider = provider(catalogID: catalogID) {
            let entry = NativeRuntimeCatalogEntry.provider(provider)
            return entry.isExecutableByNativeRuntime ? entry : nil
        }
        if let plan = codingPlan(catalogID: catalogID) {
            let entry = NativeRuntimeCatalogEntry.codingPlan(plan)
            return entry.isExecutableByNativeRuntime ? entry : nil
        }
        return nil
    }

    public func websiteActions(ownerCatalogID: String) -> [WebsiteActionEntry] {
        websiteActions
            .filter { $0.ownerCatalogID == ownerCatalogID }
            .sorted {
                if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
                return $0.actionID < $1.actionID
            }
    }

    public func primaryWebsiteAction(ownerCatalogID: String) -> WebsiteActionEntry? {
        websiteActions(ownerCatalogID: ownerCatalogID).first {
            $0.isPrimary && !$0.isPromotional
        }
    }

    /// 价格条目 ID 永不充当模型目录：pricingEntryID 命名空间与 modelID 命名空间分离，
    /// 没有任何 pricingEntryID 出现在 modelID 位置。
    public func pricingEntryIDNeverServesAsModelID() -> Bool {
        let pricingIDs = Set(pricing.map(\.pricingEntryID))
        return !pricing.contains { pricingIDs.contains($0.modelID) }
    }
}
