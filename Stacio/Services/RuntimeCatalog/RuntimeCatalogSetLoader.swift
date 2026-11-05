import CryptoKit
import Foundation

// MARK: - Catalog 资源 manifest（P4-3）

public struct AppCompatibilityRange: Codable, Equatable, Sendable {
    public let minimum: String
    public let maximum: String

    public init(minimum: String, maximum: String) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct CatalogResourceManifest: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let schemaRevision: Int

    public init(relativePath: String, sha256: String, schemaRevision: Int) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.schemaRevision = schemaRevision
    }
}

public struct RuntimeCatalogManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogSetRevision: Int
    public let appCompatibilityRange: AppCompatibilityRange
    public let resources: [CatalogResourceManifest]
    public let generatedAt: String
    public let validationEvidenceRef: String

    public init(
        schemaVersion: Int,
        catalogSetRevision: Int,
        appCompatibilityRange: AppCompatibilityRange,
        resources: [CatalogResourceManifest],
        generatedAt: String,
        validationEvidenceRef: String
    ) {
        self.schemaVersion = schemaVersion
        self.catalogSetRevision = catalogSetRevision
        self.appCompatibilityRange = appCompatibilityRange
        self.resources = resources
        self.generatedAt = generatedAt
        self.validationEvidenceRef = validationEvidenceRef
    }
}

// MARK: - 校验错误与验证证据

public enum CatalogSetError: Error, Equatable {
    case manifestSchemaVersion(expected: Int, actual: Int)
    case appIncompatible(minimum: String, maximum: String)
    case missingResource(String)
    case hashMismatch(path: String)
    case schemaRevisionMismatch(path: String, expected: Int, actual: Int)
    case duplicateCatalogID(String)
    case catalogIDReused(String)
    case duplicatePricingEntryID(String)
    case pricingOverlap(entryA: String, entryB: String)
    case pricingContentConflict(revision: Int)
    case missingCrossResourceReference(reference: String)
    case noNonPromotionalOfficialAction
    case invalidDescriptor(String)
    case invalidWebsiteAction(String)
    case experimentalDefaultViolation(String)
}

public struct CatalogValidationEvidence: Equatable, Sendable {
    public let verifiedResourceHashes: [String: String]
    public let uniqueIDsChecked: Int
    public let validatedAt: Date

    public init(verifiedResourceHashes: [String: String], uniqueIDsChecked: Int, validatedAt: Date) {
        self.verifiedResourceHashes = verifiedResourceHashes
        self.uniqueIDsChecked = uniqueIDsChecked
        self.validatedAt = validatedAt
    }
}

// MARK: - RuntimeCatalogSetLoader

/// 原子 Catalog Set 加载器：
/// 先完成 schema、唯一 ID、跨资源引用、资源 hash、整组兼容性验证，
/// 再一次性发布同一 Catalog Set（禁止新旧混用）；任何失败 → 不发布（fail closed）。
public enum RuntimeCatalogSetLoader {
    public static let manifestSchemaVersion = 1
    private static let resourceSchemaRevisions: [String: Int] = [
        "provider.json": 1,
        "coding-plan.json": 1,
        "local-agent.json": 2,
        "plan-agent-compatibility.json": 1,
        "website-action.json": 1,
        "provider-pricing.json": 1,
        "stacio-tool.json": 1
    ]

    public static func supportedResourceSchemaRevision(for relativePath: String) -> Int? {
        resourceSchemaRevisions[relativePath]
    }
    private static let requiredResourcePaths: Set<String> = [
        "provider.json",
        "coding-plan.json",
        "local-agent.json",
        "plan-agent-compatibility.json",
        "website-action.json",
        "provider-pricing.json",
        "stacio-tool.json"
    ]

    public static func load(
        manifest: RuntimeCatalogManifest,
        resources: [String: Data],
        previouslyPublishedCatalogIDs: Set<String>,
        currentAppVersion: String? = nil
    ) -> Result<(set: RuntimeCatalogSet, evidence: CatalogValidationEvidence), CatalogSetError> {
        // 1) manifest schema 固定
        guard manifest.schemaVersion == manifestSchemaVersion else {
            return .failure(.manifestSchemaVersion(expected: manifestSchemaVersion, actual: manifest.schemaVersion))
        }
        guard manifest.catalogSetRevision >= 1,
              nonEmpty(manifest.generatedAt),
              nonEmpty(manifest.validationEvidenceRef)
        else {
            return .failure(.invalidDescriptor("runtime-catalog-manifest"))
        }
        guard validCompatibilityRange(manifest.appCompatibilityRange) else {
            return .failure(.invalidDescriptor("runtime-catalog-manifest.appCompatibilityRange"))
        }
        if let currentAppVersion,
           !version(
               currentAppVersion,
               isWithin: manifest.appCompatibilityRange
           ) {
            return .failure(
                .appIncompatible(
                    minimum: manifest.appCompatibilityRange.minimum,
                    maximum: manifest.appCompatibilityRange.maximum
                )
            )
        }

        let manifestPaths = manifest.resources.map(\.relativePath)
        let uniqueManifestPaths = Set(manifestPaths)
        guard manifestPaths.count == uniqueManifestPaths.count else {
            return .failure(.invalidDescriptor("runtime-catalog-manifest.duplicate-resource"))
        }
        if let missingPath = requiredResourcePaths.subtracting(uniqueManifestPaths).sorted().first {
            return .failure(.missingResource(missingPath))
        }

        // 2) 每资源存在 + SHA-256 匹配
        var verifiedHashes: [String: String] = [:]
        for resource in manifest.resources {
            guard let data = resources[resource.relativePath] else {
                return .failure(.missingResource(resource.relativePath))
            }
            guard let expectedSchemaRevision = resourceSchemaRevisions[resource.relativePath],
                  resource.schemaRevision == expectedSchemaRevision
            else {
                return .failure(
                    .schemaRevisionMismatch(
                        path: resource.relativePath,
                        expected: resourceSchemaRevisions[resource.relativePath] ?? -1,
                        actual: resource.schemaRevision
                    )
                )
            }
            guard resource.sha256.count == 64,
                  resource.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                return .failure(.invalidDescriptor("\(resource.relativePath).sha256"))
            }
            let digest = SHA256Hex(data)
            guard digest == resource.sha256 else {
                return .failure(.hashMismatch(path: resource.relativePath))
            }
            verifiedHashes[resource.relativePath] = digest
        }

        // 3) 解码 + schema 校验（失败即 fail closed，不发布任何部分）
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let providerData = resources["provider.json"],
              let providers = try? decoder.decode([ProviderCatalogEntry].self, from: providerData) else {
            return .failure(.missingResource("provider.json"))
        }
        guard let codingPlanData = resources["coding-plan.json"],
              let codingPlans = try? decoder.decode([CodingPlanCatalogEntry].self, from: codingPlanData) else {
            return .failure(.missingResource("coding-plan.json"))
        }
        guard let localAgentData = resources["local-agent.json"],
              let localAgents = try? decoder.decode([LocalAgentCatalogEntry].self, from: localAgentData) else {
            return .failure(.missingResource("local-agent.json"))
        }
        guard let compatibilityData = resources["plan-agent-compatibility.json"],
              let compatibility = try? decoder.decode([PlanAgentCompatibilityEntry].self, from: compatibilityData) else {
            return .failure(.missingResource("plan-agent-compatibility.json"))
        }
        guard let websiteActionData = resources["website-action.json"],
              let websiteActions = try? decoder.decode([WebsiteActionEntry].self, from: websiteActionData) else {
            return .failure(.missingResource("website-action.json"))
        }
        guard let pricingData = resources["provider-pricing.json"],
              let pricing = try? decoder.decode([PricingEntry].self, from: pricingData) else {
            return .failure(.missingResource("provider-pricing.json"))
        }
        guard let toolData = resources["stacio-tool.json"],
              let toolDocument = try? decoder.decode(StacioToolCatalogDocument.self, from: toolData),
              toolDocument.schemaVersion == resourceSchemaRevisions["stacio-tool.json"],
              toolDocument.revision >= 1,
              let toolCatalog = try? StacioToolCatalogLoader.load(
                revision: toolDocument.revision,
                tools: toolDocument.tools,
                userCheckedPlanningSafeReadOnlyIDs: []
              ) else {
            return .failure(.invalidDescriptor("stacio-tool.json"))
        }

        // 4) 稳定 ID 唯一 + catalogID 永不复用 + schema revision 匹配
        var uniqueIDs = Set<String>()
        var uniqueCount = 0
        func checkUnique(_ id: String) -> CatalogSetError? {
            uniqueCount += 1
            guard Self.nonEmpty(id) else { return .invalidDescriptor("empty catalogID") }
            guard !uniqueIDs.contains(id) else { return .duplicateCatalogID(id) }
            uniqueIDs.insert(id)
            guard !previouslyPublishedCatalogIDs.contains(id) else { return .catalogIDReused(id) }
            return nil
        }
        for entry in providers {
            if let error = checkUnique(entry.catalogID) { return .failure(error) }
        }
        for entry in codingPlans {
            if let error = checkUnique(entry.catalogID) { return .failure(error) }
        }
        for entry in localAgents {
            if let error = checkUnique(entry.catalogID) { return .failure(error) }
        }
        var websiteActionIDs = Set<String>()
        for entry in websiteActions {
            guard nonEmpty(entry.actionID) else {
                return .failure(.invalidWebsiteAction(entry.actionID))
            }
            guard websiteActionIDs.insert(entry.actionID).inserted else {
                return .failure(.duplicateCatalogID(entry.actionID))
            }
        }

        if let duplicate = firstDuplicate(providers.map(\.providerID)) {
            return .failure(.invalidDescriptor("duplicate providerID: \(duplicate)"))
        }
        if let duplicate = firstDuplicate(codingPlans.map(\.planID)) {
            return .failure(.invalidDescriptor("duplicate planID: \(duplicate)"))
        }
        if let duplicate = firstDuplicate(localAgents.map(\.rawIdentity)) {
            return .failure(.invalidDescriptor("duplicate agent identity: \(duplicate)"))
        }
        let compatibilityKeys = compatibility.map { "\($0.planID)\u{1f}\($0.agentRawIdentity)" }
        if let duplicate = firstDuplicate(compatibilityKeys) {
            return .failure(.invalidDescriptor("duplicate plan-agent compatibility: \(duplicate)"))
        }

        // 5) 跨资源引用：pricing.providerID 必须命中 provider.catalogID
        let providerIDs = Set(providers.map(\.providerID))
        for entry in pricing where !providerIDs.contains(entry.providerID) {
            return .failure(.missingCrossResourceReference(reference: entry.providerID))
        }

        let providerCatalogIDs = Set(providers.map(\.catalogID))
        let codingPlanCatalogIDs = Set(codingPlans.map(\.catalogID))
        let localAgentCatalogIDs = Set(localAgents.map(\.catalogID))
        let planIDs = Set(codingPlans.map(\.planID))
        let agentIdentities = Set(localAgents.map(\.rawIdentity))
        for entry in compatibility {
            guard nonEmpty(entry.planID), nonEmpty(entry.agentRawIdentity),
                  planIDs.contains(entry.planID) else {
                return .failure(.missingCrossResourceReference(reference: entry.planID))
            }
            guard agentIdentities.contains(entry.agentRawIdentity) else {
                return .failure(.missingCrossResourceReference(reference: entry.agentRawIdentity))
            }
        }

        for action in websiteActions {
            guard providerCatalogIDs.contains(action.ownerCatalogID)
                    || codingPlanCatalogIDs.contains(action.ownerCatalogID)
                    || localAgentCatalogIDs.contains(action.ownerCatalogID),
                  nonEmpty(action.ownerCatalogID),
                  nonEmpty(action.title),
                  action.displayOrder >= 0,
                  action.source == .catalog,
                  action.verifiedAt != nil,
                  action.isPrimary == false || action.isPromotional == false,
                  let url = URL(string: action.url),
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false
            else {
                return .failure(.invalidWebsiteAction(action.actionID))
            }
            let ownerSupportLevel = providers.first { $0.catalogID == action.ownerCatalogID }?.supportLevel
                ?? codingPlans.first { $0.catalogID == action.ownerCatalogID }?.supportLevel
                ?? localAgents.first { $0.catalogID == action.ownerCatalogID }?.supportLevel
            guard ownerSupportLevel == action.supportLevel else {
                return .failure(.invalidWebsiteAction(action.actionID))
            }
        }
        let primaryCountsByOwner = websiteActions
            .filter(\.isPrimary)
            .reduce(into: [String: Int]()) { counts, action in
                counts[action.ownerCatalogID, default: 0] += 1
            }
        if let ownerWithMultiplePrimary = primaryCountsByOwner.keys.sorted().first(where: {
            primaryCountsByOwner[$0, default: 0] > 1
        }) {
            return .failure(.invalidWebsiteAction(ownerWithMultiplePrimary))
        }

        for provider in providers {
            guard provider.schemaVersion >= 1, provider.revision >= 1,
                  nonEmpty(provider.providerID),
                  nonEmpty(provider.displayName),
                  provider.aliases.allSatisfy(nonEmpty),
                  Set(provider.websiteActionIDs).count == provider.websiteActionIDs.count,
                  provider.websiteActionIDs.allSatisfy(websiteActionIDs.contains),
                  provider.websiteActionIDs.allSatisfy({ actionID in
                      websiteActions.contains {
                          $0.actionID == actionID && $0.ownerCatalogID == provider.catalogID
                      }
                  }),
                  provider.noForgedOfficialButton,
                  validOfficialActionURL(provider.officialActionURL),
                  validModelDiscovery(
                      provider.modelDiscoveryStrategy,
                      protocolFamily: provider.protocolFamily
                  ),
                  provider.permitsNoCredential == (provider.authenticationKind == .none),
                  validSuggestedBaseURL(provider.suggestedBaseURL, permitsHTTP: provider.permitsNoCredential)
            else {
                return .failure(.invalidDescriptor(provider.catalogID))
            }
            if provider.hasOfficialOwner, provider.tombstone == nil {
                let actions = websiteActions.filter { provider.websiteActionIDs.contains($0.actionID) }
                guard actions.filter({ $0.isPrimary && !$0.isPromotional }).count == 1 else {
                    return .failure(.noNonPromotionalOfficialAction)
                }
            } else if provider.hasOfficialOwner == false, provider.websiteActionIDs.isEmpty == false {
                return .failure(.invalidDescriptor(provider.catalogID))
            }
        }

        for plan in codingPlans {
            guard plan.schemaVersion >= 1, plan.revision >= 1,
                  nonEmpty(plan.planID),
                  nonEmpty(plan.displayName),
                  nonEmpty(plan.authorizationScope),
                  plan.aliases.allSatisfy(nonEmpty),
                  plan.allowedRuntimeKinds.isEmpty == false,
                  Set(plan.allowedRuntimeKinds.map(\.rawValue)).count == plan.allowedRuntimeKinds.count,
                  Set(plan.websiteActionIDs).count == plan.websiteActionIDs.count,
                  plan.websiteActionIDs.allSatisfy(websiteActionIDs.contains),
                  plan.websiteActionIDs.allSatisfy({ actionID in
                      websiteActions.contains {
                          $0.actionID == actionID && $0.ownerCatalogID == plan.catalogID
                      }
                  }),
                  plan.quotaActionID.map({ actionID in
                      websiteActions.contains {
                          $0.actionID == actionID && $0.ownerCatalogID == plan.catalogID
                      }
                  }) ?? true,
                  validSuggestedBaseURL(plan.suggestedBaseURL, permitsHTTP: false),
                  validCodingPlanCombination(plan)
            else {
                return .failure(.invalidDescriptor(plan.catalogID))
            }
            if plan.tombstone == nil {
                let actions = websiteActions.filter { plan.websiteActionIDs.contains($0.actionID) }
                guard actions.filter({ $0.isPrimary && !$0.isPromotional }).count == 1 else {
                    return .failure(.noNonPromotionalOfficialAction)
                }
            }
        }

        for agent in localAgents {
            let commandArgv = [
                Optional(agent.versionArgv), agent.capabilityProbeArgv,
                agent.loginStatusArgv, agent.loginArgv, agent.logoutArgv,
                Optional(agent.terminalPassthroughArgv)
            ]
            guard agent.schemaVersion >= 1,
                  agent.revision >= 1,
                  nonEmpty(agent.rawIdentity),
                  nonEmpty(agent.displayName),
                  agent.catalogID.hasPrefix("local-agent."),
                  agent.aliases.allSatisfy(nonEmpty),
                  Set(agent.aliases).count == agent.aliases.count,
                  agent.executableCandidates.allSatisfy(validExecutableCandidate),
                  agent.supportedOSVersions.allSatisfy(nonEmpty),
                  Set(agent.supportedOSVersions).count == agent.supportedOSVersions.count,
                  agent.supportedArchitectures.allSatisfy(nonEmpty),
                  Set(agent.supportedArchitectures).count == agent.supportedArchitectures.count,
                  commandArgv.compactMap({ $0 }).allSatisfy(validArgv),
                  agent.executionProfiles.allSatisfy({ profile in
                      nonEmpty(profile.profileID) && profile.revision > 0 && profile.kind != .none
                  }),
                  Set(agent.executionProfiles.map(\.profileID)).count
                    == agent.executionProfiles.count,
                  agent.executionProfiles.allSatisfy({ profile in
                      (profile.kind != .terminalPassthrough || agent.permitsPTYFallback)
                        && (profile.kind != .managed || agent.structuredProtocolPriority.isEmpty == false)
                  }),
                  Set(agent.structuredProtocolPriority.map(\.rawValue)).count
                    == agent.structuredProtocolPriority.count,
                  agent.supportedCapabilities.allSatisfy(nonEmpty),
                  Set(agent.supportedCapabilities).count == agent.supportedCapabilities.count,
                  agent.supportedWorkingDirectoryModes.isEmpty == false
                    || agent.supportLevel == .unsupported,
                  Set(agent.supportedWorkingDirectoryModes.map(\.rawValue)).count
                    == agent.supportedWorkingDirectoryModes.count,
                  agent.defaultEnvironmentAllowlist.allSatisfy(validEnvironmentName),
                  Set(agent.defaultEnvironmentAllowlist).count
                    == agent.defaultEnvironmentAllowlist.count,
                  Set(agent.websiteActionIDs).count == agent.websiteActionIDs.count,
                  agent.websiteActionIDs.allSatisfy(websiteActionIDs.contains),
                  agent.websiteActionIDs.allSatisfy({ actionID in
                      websiteActions.contains {
                          $0.actionID == actionID && $0.ownerCatalogID == agent.catalogID
                      }
                  }),
                  agent.documentationSources.allSatisfy(validDocumentationURL),
                  agent.upgradeActionID.map({ actionID in
                      websiteActions.contains {
                          $0.actionID == actionID
                            && $0.ownerCatalogID == agent.catalogID
                            && $0.kind == .upgrade
                      }
                  }) ?? true
            else {
                return .failure(.invalidDescriptor(agent.catalogID))
            }
            if agent.isExecutableCandidate {
                guard agent.executableCandidates.isEmpty == false,
                      agent.supportedOSVersions.isEmpty == false,
                      agent.supportedArchitectures.isEmpty == false,
                      agent.versionArgv.isEmpty == false,
                      agent.executionProfiles.isEmpty == false,
                      agent.permitsPTYFallback || agent.structuredProtocolPriority.isEmpty == false,
                      agent.supportedCapabilities.isEmpty == false,
                      agent.documentationSources.isEmpty == false,
                      agent.websiteActionIDs.isEmpty == false
                else {
                    return .failure(.invalidDescriptor(agent.catalogID))
                }
                let actions = websiteActions.filter { agent.websiteActionIDs.contains($0.actionID) }
                guard actions.filter({ $0.isPrimary && !$0.isPromotional }).count == 1 else {
                    return .failure(.noNonPromotionalOfficialAction)
                }
            }
        }

        let plansByID = Dictionary(uniqueKeysWithValues: codingPlans.map { ($0.planID, $0) })
        let agentsByIdentity = Dictionary(uniqueKeysWithValues: localAgents.map { ($0.rawIdentity, $0) })
        for entry in compatibility {
            guard let plan = plansByID[entry.planID],
                  let agent = agentsByIdentity[entry.agentRawIdentity],
                  plan.allowedRuntimeKinds == [.localAgent],
                  entry.lastVerifiedCatalogRevision.map({
                      $0 >= 1 && $0 <= manifest.catalogSetRevision
                  }) ?? true
            else {
                return .failure(
                    .invalidDescriptor("plan-agent-compatibility:\(entry.planID):\(entry.agentRawIdentity)")
                )
            }
            if entry.compatible {
                guard plan.supportLevel != .unsupported,
                      agent.isExecutableCandidate,
                      entry.supportLevel != .unsupported,
                      entry.credentialInjectionKind != nil,
                      entry.allowedCapabilities.isEmpty == false,
                      entry.allowedCapabilities.allSatisfy(nonEmpty),
                      Set(entry.allowedCapabilities).count == entry.allowedCapabilities.count,
                      entry.authorizationNotes.map(nonEmpty) == true
                else {
                    return .failure(
                        .invalidDescriptor("plan-agent-compatibility:\(entry.planID):\(entry.agentRawIdentity)")
                    )
                }
            }
            if entry.supportLevel == .ga {
                guard plan.supportLevel == .ga,
                      agent.supportLevel == .ga,
                      entry.compatible,
                      entry.lastVerifiedCatalogRevision == manifest.catalogSetRevision
                else {
                    return .failure(
                        .invalidDescriptor("plan-agent-compatibility:\(entry.planID):\(entry.agentRawIdentity)")
                    )
                }
            }
        }

        for plan in codingPlans where plan.planKind == .restrictedLocalAgent
            && plan.tombstone == nil && plan.supportLevel != .unsupported {
            guard compatibility.contains(where: {
                $0.planID == plan.planID && $0.compatible && $0.supportLevel != .unsupported
            }) else {
                return .failure(.invalidDescriptor(plan.catalogID))
            }
        }

        for plan in codingPlans where plan.allowedRuntimeKinds == [.localAgent]
            && plan.tombstone == nil && plan.supportLevel != .unsupported {
            guard compatibility.contains(where: {
                $0.planID == plan.planID && $0.compatible && $0.supportLevel != .unsupported
            }) else {
                return .failure(.invalidDescriptor(plan.catalogID))
            }
        }

        // 6) pricing 半开区间不重叠 + 条目 ID 唯一 + 同 revision 内容冲突
        var pricingIDs = Set<String>()
        for entry in pricing {
            guard nonEmpty(entry.pricingEntryID),
                  nonEmpty(entry.providerID),
                  nonEmpty(entry.modelID),
                  entry.inputPerMillion.isFinite,
                  entry.outputPerMillion.isFinite,
                  entry.inputPerMillion >= 0,
                  entry.outputPerMillion >= 0,
                  entry.effectiveUntil.map({ $0 > entry.effectiveFrom }) ?? true
            else {
                return .failure(.invalidDescriptor(entry.pricingEntryID))
            }
            guard !pricingIDs.contains(entry.pricingEntryID) else {
                return .failure(.duplicatePricingEntryID(entry.pricingEntryID))
            }
            pricingIDs.insert(entry.pricingEntryID)
        }
        for i in 0..<pricing.count {
            for j in (i + 1)..<pricing.count where pricing[i].overlaps(pricing[j]) {
                return .failure(.pricingOverlap(entryA: pricing[i].pricingEntryID, entryB: pricing[j].pricingEntryID))
            }
        }

        // 7) website action：至少一个非推广官方主动作
        guard websiteActions.contains(where: { $0.isPrimary && $0.nonPromotional && !$0.url.isEmpty }) else {
            return .failure(.noNonPromotionalOfficialAction)
        }

        // 8) 全部通过 → 一次性发布同一 Catalog Set
        let set = RuntimeCatalogSet(
            catalogSetRevision: manifest.catalogSetRevision,
            providers: providers,
            codingPlans: codingPlans,
            localAgents: localAgents,
            planAgentCompatibility: compatibility,
            websiteActions: websiteActions,
            pricing: pricing,
            toolCatalog: toolCatalog
        )
        let evidence = CatalogValidationEvidence(
            verifiedResourceHashes: verifiedHashes,
            uniqueIDsChecked: uniqueCount,
            validatedAt: Date()
        )
        return .success((set, evidence))
    }

    /// 验证失败时 fail closed：已有配置只读可导出、新配置/模型同步/新 Attempt 拒绝。
    public static func failClosed(outcome: Result<RuntimeCatalogSet, CatalogSetError>) -> Bool {
        if case .success = outcome { return false }
        return true
    }

    private static func SHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validExecutableCandidate(_ candidate: LocalAgentExecutableCandidate) -> Bool {
        let value = candidate.value
        guard nonEmpty(value), value.utf8.contains(0) == false else { return false }
        switch candidate.kind {
        case .pathLookup:
            return value.contains("/") == false && value != "." && value != ".."
        case .homeRelative:
            guard value.hasPrefix("/") == false else { return false }
            return validRelativePathComponents(value)
        case .absolute:
            guard value.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: value).standardizedFileURL.path == value
        }
    }

    private static func validRelativePathComponents(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.isEmpty == false && components.allSatisfy {
            $0.isEmpty == false && $0 != "." && $0 != ".."
        }
    }

    private static func validArgv(_ argv: [String]) -> Bool {
        argv.allSatisfy { nonEmpty($0) && $0.utf8.contains(0) == false }
    }

    private static func validEnvironmentName(_ value: String) -> Bool {
        guard nonEmpty(value), let first = value.first,
              first == "_" || first.isLetter
        else { return false }
        let body = value.dropFirst()
        if body.last == "*" {
            guard body.dropLast().last == "_" else { return false }
            return body.dropLast().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
        }
        return body.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func validDocumentationURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    private static func validSuggestedBaseURL(_ value: String?, permitsHTTP: Bool) -> Bool {
        guard let value else { return true }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        guard permitsHTTP, scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func validOfficialActionURL(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    private static func validModelDiscovery(
        _ strategy: CatalogModelDiscoveryStrategy,
        protocolFamily: CatalogProtocolFamily
    ) -> Bool {
        switch strategy {
        case .openAIModels, .manualOnly:
            return protocolFamily == .openAICompatible
        case .anthropicModels:
            return protocolFamily == .anthropicMessages
        case .cliManaged, .unavailable:
            return true
        }
    }

    private static func validCodingPlanCombination(_ plan: CodingPlanCatalogEntry) -> Bool {
        switch plan.planKind {
        case .apiKeyNative:
            return plan.credentialOwner == .stacioKeychain
                && plan.authenticationKind == .bearerAPIKey
                && plan.modelDiscoveryStrategy == .openAIModels
                && plan.suggestedBaseURL != nil
                && plan.allowedRuntimeKinds == [.nativeAPI]
        case .restrictedLocalAgent:
            let validAuthentication: Bool
            switch plan.credentialOwner {
            case .stacioKeychain:
                validAuthentication = plan.authenticationKind == .bearerAPIKey
            case .supportedCLI:
                validAuthentication = plan.authenticationKind == .bearerAPIKey
                    || plan.authenticationKind == .cliManaged
            }
            return validAuthentication
                && (plan.modelDiscoveryStrategy == .cliManaged
                    || plan.modelDiscoveryStrategy == .openAIModels)
                && plan.allowedRuntimeKinds == [.localAgent]
        case .accountSubscription:
            return plan.credentialOwner == .supportedCLI
                && plan.authenticationKind == .cliManaged
                && plan.modelDiscoveryStrategy == .cliManaged
                && plan.suggestedBaseURL == nil
                && plan.allowedRuntimeKinds == [.localAgent]
        }
    }

    private static func validCompatibilityRange(_ range: AppCompatibilityRange) -> Bool {
        guard let minimum = versionComponents(range.minimum),
              let maximum = versionComponents(range.maximum)
        else { return false }
        return compareVersionComponents(minimum, maximum) != .orderedDescending
    }

    private static func version(_ value: String, isWithin range: AppCompatibilityRange) -> Bool {
        guard let candidate = versionComponents(value),
              let minimum = versionComponents(range.minimum),
              let maximum = versionComponents(range.maximum)
        else { return false }
        return compareVersionComponents(candidate, minimum) != .orderedAscending
            && compareVersionComponents(candidate, maximum) != .orderedDescending
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard part.isEmpty == false,
                  part.allSatisfy(\.isNumber),
                  let component = Int(part),
                  component >= 0
            else { return nil }
            components.append(component)
        }
        return components
    }

    private static func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func nonEmpty(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func firstDuplicate(_ values: [String]) -> String? {
        var seen = Set<String>()
        for value in values {
            guard nonEmpty(value), seen.insert(value).inserted else { return value }
        }
        return nil
    }
}
