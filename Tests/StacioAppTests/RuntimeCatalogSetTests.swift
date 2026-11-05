import CryptoKit
import XCTest
import Foundation
@testable import StacioApp

/// P4-3：原子 Catalog Set 与六类资源（manifest/loader/校验/fail closed/价格区间）。
final class RuntimeCatalogSetTests: XCTestCase {

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private var resourceDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/StacioAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Stacio/Resources/RuntimeCatalog").path
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - fixtures

    private func makeProviderEntries() -> [ProviderCatalogEntry] {
        [
            ProviderCatalogEntry(
                catalogID: "provider.openai-compatible.custom", providerID: "openai-compatible.custom",
                displayName: "自定义兼容端点", officialOwner: nil, officialActionURL: nil,
                supportLevel: .ga
            ),
            ProviderCatalogEntry(
                catalogID: "provider.openai.com", providerID: "openai.com",
                displayName: "OpenAI", officialOwner: "OpenAI",
                officialActionURL: nil, supportLevel: .ga,
                suggestedBaseURL: "https://api.openai.com/v1",
                websiteActionIDs: ["provider.openai.api-key"],
                legacyProfileRawValue: "OpenAI"
            )
        ]
    }

    private func makeCodingPlans() -> [CodingPlanCatalogEntry] {
        [
            CodingPlanCatalogEntry(
                catalogID: "coding-plan.kimi-code",
                planID: "kimi-code",
                displayName: "Kimi Code",
                supportLevel: .experimental,
                suggestedBaseURL: "https://api.kimi.com/coding/v1",
                authorizationScope: "Kimi Coding Plan test scope",
                websiteActionIDs: ["coding-plan.kimi.console"]
            )
        ]
    }

    private func makeLocalAgents() -> [LocalAgentCatalogEntry] {
        [
            LocalAgentCatalogEntry(
                catalogID: "local-agent.stacio",
                rawIdentity: "stacioAgent",
                displayName: "Stacio Agent",
                supportLevel: .experimental,
                executableCandidates: [
                    .init(kind: .pathLookup, value: "stacio-agent")
                ],
                supportedOSVersions: ["macOS 14+"],
                supportedArchitectures: ["arm64", "x86_64"],
                versionArgv: ["--version"],
                capabilityProbeArgv: ["--version"],
                terminalPassthroughArgv: [],
                executionProfiles: [
                    .init(
                        profileID: "terminal-passthrough",
                        revision: 1,
                        kind: .terminalPassthrough,
                        supportLevel: .experimental
                    )
                ],
                permitsPTYFallback: true,
                supportedCapabilities: ["terminalPassthrough"],
                supportedWorkingDirectoryModes: AgentProcessWorkingDirectoryMode.allCases,
                defaultEnvironmentAllowlist: ["LANG", "LC_*", "TERM", "TMPDIR"],
                websiteActionIDs: ["local-agent.stacio.docs"],
                documentationSources: ["https://example.com/stacio-agent"]
            )
        ]
    }

    private func makeCompatibility() -> [PlanAgentCompatibilityEntry] {
        [PlanAgentCompatibilityEntry(planID: "kimi-code", agentRawIdentity: "stacioAgent", compatible: true)]
    }

    private func makeRestrictedPlan() -> CodingPlanCatalogEntry {
        CodingPlanCatalogEntry(
            catalogID: "coding-plan.restricted",
            planID: "restricted-plan",
            displayName: "Restricted Plan",
            supportLevel: .experimental,
            planKind: .restrictedLocalAgent,
            credentialOwner: .supportedCLI,
            authenticationKind: .bearerAPIKey,
            suggestedBaseURL: "https://restricted.example.com/v1",
            modelDiscoveryStrategy: .cliManaged,
            authorizationScope: "Supported interactive coding tools only",
            websiteActionIDs: ["coding-plan.restricted.manage"],
            allowedRuntimeKinds: [.localAgent]
        )
    }

    private func makeRestrictedPlanAction() -> WebsiteActionEntry {
        WebsiteActionEntry(
            actionID: "coding-plan.restricted.manage",
            ownerCatalogID: "coding-plan.restricted",
            kind: .codingPlan,
            title: "Manage Plan",
            url: "https://restricted.example.com/console",
            displayOrder: 10,
            isPrimary: true,
            isPromotional: false,
            verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
            supportLevel: .experimental
        )
    }

    private func makeRestrictedCompatibility(
        credentialInjectionKind: CatalogCredentialInjectionKind? = .temporaryEnvironment,
        allowedCapabilities: [String] = ["conversation"],
        authorizationNotes: String? = "Inject only for an explicitly selected plan."
    ) -> PlanAgentCompatibilityEntry {
        PlanAgentCompatibilityEntry(
            planID: "restricted-plan",
            agentRawIdentity: "stacioAgent",
            compatible: true,
            credentialInjectionKind: credentialInjectionKind,
            allowedCapabilities: allowedCapabilities,
            authorizationNotes: authorizationNotes,
            supportLevel: .experimental
        )
    }

    private func makeWebsiteActions() -> [WebsiteActionEntry] {
        [
            WebsiteActionEntry(
                actionID: "provider.openai.api-key",
                ownerCatalogID: "provider.openai.com",
                kind: .apiKey,
                title: "Get API Key",
                url: "https://platform.openai.com/api-keys",
                displayOrder: 10,
                isPrimary: true,
                isPromotional: false,
                verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
                supportLevel: .ga
            ),
            WebsiteActionEntry(
                actionID: "coding-plan.kimi.console",
                ownerCatalogID: "coding-plan.kimi-code",
                kind: .codingPlan,
                title: "Open Coding Plan",
                url: "https://www.kimi.com/code/console",
                displayOrder: 10,
                isPrimary: true,
                isPromotional: false,
                verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
                supportLevel: .experimental
            ),
            WebsiteActionEntry(
                actionID: "local-agent.stacio.docs",
                ownerCatalogID: "local-agent.stacio",
                kind: .documentation,
                title: "Stacio Agent Documentation",
                url: "https://example.com/stacio-agent",
                displayOrder: 10,
                isPrimary: true,
                isPromotional: false,
                verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
                supportLevel: .experimental
            )
        ]
    }

    private func makePricing() -> [PricingEntry] {
        [
            PricingEntry(
                pricingEntryID: "pricing.openai.gpt-4o.2026-01", providerID: "openai.com", modelID: "gpt-4o",
                effectiveFrom: Self.iso8601.date(from: "2026-01-01T00:00:00Z")!, effectiveUntil: nil,
                inputPerMillion: 2.5, outputPerMillion: 10.0
            )
        ]
    }

    private func makeResources(
        providers: [ProviderCatalogEntry]? = nil,
        codingPlans: [CodingPlanCatalogEntry]? = nil,
        localAgents: [LocalAgentCatalogEntry]? = nil,
        compatibility: [PlanAgentCompatibilityEntry]? = nil,
        websiteActions: [WebsiteActionEntry]? = nil,
        pricing: [PricingEntry]? = nil
    ) -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var resources: [String: Data] = [:]
        resources["provider.json"] = try! encoder.encode(providers ?? makeProviderEntries())
        resources["coding-plan.json"] = try! encoder.encode(codingPlans ?? makeCodingPlans())
        resources["local-agent.json"] = try! encoder.encode(localAgents ?? makeLocalAgents())
        resources["plan-agent-compatibility.json"] = try! encoder.encode(compatibility ?? [])
        resources["website-action.json"] = try! encoder.encode(websiteActions ?? makeWebsiteActions())
        resources["provider-pricing.json"] = try! encoder.encode(pricing ?? makePricing())
        resources["stacio-tool.json"] = try! encoder.encode(
            StacioToolCatalogDocument(
                revision: 1,
                tools: [
                    StacioToolDescriptor(
                        toolID: StacioBuiltinToolID.terminalCommand,
                        schemaRevision: 1,
                        applicableTargetBindingKinds: ["local", "terminal"],
                        writeRisk: true,
                        escalationRisk: true,
                        networkRisk: true,
                        planningSafeReadOnly: false,
                        requiredLease: "terminal.runtime",
                        maxInputBytes: 65_536,
                        maxOutputBytes: 1_048_576,
                        auditPolicy: "durable-decision-and-terminal-trace"
                    )
                ]
            )
        )
        return resources
    }

    private func makeManifest(resources: [String: Data]) -> RuntimeCatalogManifest {
        RuntimeCatalogManifest(
            schemaVersion: RuntimeCatalogSetLoader.manifestSchemaVersion,
            catalogSetRevision: 1,
            appCompatibilityRange: AppCompatibilityRange(minimum: "1.0", maximum: "2.0"),
            resources: resources.map {
                CatalogResourceManifest(
                    relativePath: $0.key,
                    sha256: sha256($0.value),
                    schemaRevision: RuntimeCatalogSetLoader.supportedResourceSchemaRevision(for: $0.key) ?? 1
                )
            },
            generatedAt: "2026-08-06T00:00:00Z",
            validationEvidenceRef: "evidence:ci-catalog-v1"
        )
    }

    // MARK: - manifest 固定结构

    func testManifestFixedSchemaVersionAndEvidence() {
        let manifest = makeManifest(resources: makeResources())
        XCTAssertEqual(manifest.schemaVersion, 1, "manifest schemaVersion 固定")
        XCTAssertEqual(manifest.catalogSetRevision, 1)
        XCTAssertEqual(manifest.appCompatibilityRange.minimum, "1.0")
        XCTAssertFalse(manifest.validationEvidenceRef.isEmpty, "验证证据引用必含")
        XCTAssertFalse(manifest.generatedAt.isEmpty, "生成时间必含")
        XCTAssertEqual(manifest.resources.count, 7, "七个资源包含 Stacio Tool Catalog")
    }

    func testWrongManifestSchemaVersionFails() {
        let manifest = RuntimeCatalogManifest(
            schemaVersion: 2,
            catalogSetRevision: 1,
            appCompatibilityRange: AppCompatibilityRange(minimum: "1.0", maximum: "2.0"),
            resources: [],
            generatedAt: "2026-08-06T00:00:00Z",
            validationEvidenceRef: "evidence"
        )
        let result = RuntimeCatalogSetLoader.load(
            manifest: manifest, resources: makeResources(), previouslyPublishedCatalogIDs: []
        )
        guard case .failure(let error) = result else {
            return XCTFail("schemaVersion 错误必须失败")
        }
        XCTAssertEqual(error, .manifestSchemaVersion(expected: 1, actual: 2))
        XCTAssertTrue(RuntimeCatalogSetLoader.failClosed(outcome: .failure(error)), "验证失败 fail closed")
    }

    func testManifestCompatibilityRangeIsValidatedAndEnforced() {
        let resources = makeResources()
        let base = makeManifest(resources: resources)
        let malformed = RuntimeCatalogManifest(
            schemaVersion: base.schemaVersion,
            catalogSetRevision: base.catalogSetRevision,
            appCompatibilityRange: AppCompatibilityRange(minimum: "2.0.0", maximum: "1.0.0"),
            resources: base.resources,
            generatedAt: base.generatedAt,
            validationEvidenceRef: base.validationEvidenceRef
        )
        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: malformed,
                resources: resources,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidDescriptor("runtime-catalog-manifest.appCompatibilityRange")
        )

        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: base,
                resources: resources,
                previouslyPublishedCatalogIDs: [],
                currentAppVersion: "2.0.1"
            ).failure,
            .appIncompatible(minimum: "1.0", maximum: "2.0")
        )
        XCTAssertNotNil(
            try? RuntimeCatalogSetLoader.load(
                manifest: base,
                resources: resources,
                previouslyPublishedCatalogIDs: [],
                currentAppVersion: "1.5.0"
            ).get()
        )
    }

    // MARK: - hash 与原子发布

    func testLoaderValidatesHashesBeforePublish() {
        let original = makeResources()
        let manifest = makeManifest(resources: original) // hash 基于原始内容
        var tampered = original
        tampered["provider.json"] = Data("tampered".utf8) // 磁盘内容被篡改
        let result = RuntimeCatalogSetLoader.load(
            manifest: manifest, resources: tampered, previouslyPublishedCatalogIDs: []
        )
        guard case .failure(let error) = result else {
            return XCTFail("hash 不匹配必须失败")
        }
        XCTAssertEqual(error, .hashMismatch(path: "provider.json"))
    }

    func testAtomicPublishNoMixedVersions() {
        // 一资源缺失 → 整组不发布（禁止新旧混用）
        var resources = makeResources()
        let manifestResources = makeManifest(resources: resources).resources
        resources.removeValue(forKey: "stacio-tool.json")
        let manifest = RuntimeCatalogManifest(
            schemaVersion: RuntimeCatalogSetLoader.manifestSchemaVersion,
            catalogSetRevision: 1,
            appCompatibilityRange: AppCompatibilityRange(minimum: "1.0", maximum: "2.0"),
            resources: manifestResources,
            generatedAt: "2026-08-06T00:00:00Z",
            validationEvidenceRef: "evidence"
        )
        let result = RuntimeCatalogSetLoader.load(
            manifest: manifest, resources: resources, previouslyPublishedCatalogIDs: []
        )
        guard case .failure(let error) = result else {
            return XCTFail("缺失资源必须失败")
        }
        XCTAssertEqual(error, .missingResource("stacio-tool.json"))
    }

    func testSuccessfulLoadPublishesSetWithEvidence() throws {
        let resources = makeResources()
        let manifest = makeManifest(resources: resources)
        let result = RuntimeCatalogSetLoader.load(
            manifest: manifest, resources: resources, previouslyPublishedCatalogIDs: []
        )
        let (set, evidence) = try result.get()
        XCTAssertEqual(set.catalogSetRevision, 1)
        XCTAssertEqual(evidence.verifiedResourceHashes.count, 7, "全部资源 hash 已核实")
        XCTAssertEqual(evidence.verifiedResourceHashes["provider.json"], sha256(resources["provider.json"]!))
        XCTAssertGreaterThan(evidence.uniqueIDsChecked, 0)
    }

    // MARK: - catalogID 永不复用

    func testCatalogIDNeverReused() {
        let resources = makeResources()
        let manifest = makeManifest(resources: resources)
        let result = RuntimeCatalogSetLoader.load(
            manifest: manifest, resources: resources,
            previouslyPublishedCatalogIDs: ["provider.openai.com"] // 已发布过
        )
        guard case .failure(let error) = result else {
            return XCTFail("catalogID 复用必须失败")
        }
        XCTAssertEqual(error, .catalogIDReused("provider.openai.com"))
    }

    func testDuplicateCatalogIDFails() {
        var providers = makeProviderEntries()
        providers.append(providers[0]) // 同一 catalogID 两次
        let resources = makeResources(providers: providers)
        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )
        guard case .failure(let error) = result else {
            return XCTFail("重复 catalogID 必须失败")
        }
        XCTAssertEqual(error, .duplicateCatalogID("provider.openai-compatible.custom"))
    }

    func testManifestMustHashEveryCoreCatalogResource() {
        let resources = makeResources()
        let complete = makeManifest(resources: resources)
        let incomplete = RuntimeCatalogManifest(
            schemaVersion: complete.schemaVersion,
            catalogSetRevision: complete.catalogSetRevision,
            appCompatibilityRange: complete.appCompatibilityRange,
            resources: complete.resources.filter { $0.relativePath != "provider.json" },
            generatedAt: complete.generatedAt,
            validationEvidenceRef: complete.validationEvidenceRef
        )

        let result = RuntimeCatalogSetLoader.load(
            manifest: incomplete,
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )

        XCTAssertEqual(try? result.get().set, nil)
        guard case let .failure(error) = result else {
            return XCTFail("未被 manifest 覆盖的核心资源必须 fail closed")
        }
        XCTAssertEqual(error, .missingResource("provider.json"))
    }

    func testDuplicateProviderIdentityFailsEvenWithDistinctCatalogIDs() {
        var providers = makeProviderEntries()
        providers.append(
            ProviderCatalogEntry(
                catalogID: "provider.duplicate.identity",
                providerID: providers[0].providerID,
                displayName: "Duplicate identity",
                officialOwner: nil,
                officialActionURL: nil,
                supportLevel: .experimental
            )
        )
        let resources = makeResources(providers: providers)

        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )

        guard case let .failure(error) = result else {
            return XCTFail("业务 identity 重复必须失败")
        }
        XCTAssertEqual(
            error,
            .invalidDescriptor("duplicate providerID: \(providers[0].providerID)")
        )
    }

    func testDuplicatePlanAgentCompatibilityPairFails() {
        let compatibility = makeCompatibility() + makeCompatibility()
        let resources = makeResources(compatibility: compatibility)

        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )

        guard case let .failure(error) = result else {
            return XCTFail("同一套餐和 Agent 的兼容性事实只能有一条")
        }
        XCTAssertEqual(
            error,
            .invalidDescriptor("duplicate plan-agent compatibility: kimi-code\u{1f}stacioAgent")
        )
    }

    // MARK: - 官网按钮

    func testProviderCustomNoForgedOfficialButton() {
        for provider in makeProviderEntries() {
            XCTAssertTrue(provider.noForgedOfficialButton, "\(provider.catalogID): 无 owner 不得伪造官网按钮")
        }
        // 无 owner 但有 URL → 伪造
        let forged = ProviderCatalogEntry(
            catalogID: "provider.forged", providerID: "forged", displayName: "F",
            officialOwner: nil, officialActionURL: "https://example.com", supportLevel: .ga
        )
        XCTAssertFalse(forged.noForgedOfficialButton)
    }

    func testLoaderRejectsForgedOfficialURLWithoutOwner() {
        let forged = ProviderCatalogEntry(
            catalogID: "provider.forged",
            providerID: "forged",
            displayName: "Forged",
            officialOwner: nil,
            officialActionURL: "https://example.com/console",
            supportLevel: .experimental
        )
        let resources = makeResources(providers: makeProviderEntries() + [forged])

        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )

        guard case let .failure(error) = result else {
            return XCTFail("无官方 owner 的条目不能声明官方 URL")
        }
        XCTAssertEqual(error, .invalidDescriptor(forged.catalogID))
    }

    func testCodingPlanQuotaActionMustBelongToTheSamePlan() {
        let plan = CodingPlanCatalogEntry(
            catalogID: "coding-plan.kimi-code",
            planID: "kimi-code",
            displayName: "Kimi Code",
            supportLevel: .experimental,
            suggestedBaseURL: "https://api.kimi.com/coding/v1",
            authorizationScope: "Kimi Coding Plan test scope",
            quotaActionID: "provider.openai.api-key",
            websiteActionIDs: ["coding-plan.kimi.console"]
        )
        let resources = makeResources(codingPlans: [plan])

        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )

        guard case let .failure(error) = result else {
            return XCTFail("quota action 不能跨 owner 引用")
        }
        XCTAssertEqual(error, .invalidDescriptor(plan.catalogID))
    }

    func testCodingPlanKindCredentialAndRuntimeCombinationMustBeConsistent() {
        let invalid = CodingPlanCatalogEntry(
            catalogID: "coding-plan.kimi-code",
            planID: "kimi-code",
            displayName: "Kimi Code",
            supportLevel: .experimental,
            planKind: .apiKeyNative,
            credentialOwner: .supportedCLI,
            authenticationKind: .cliManaged,
            suggestedBaseURL: "https://api.kimi.com/coding/v1",
            modelDiscoveryStrategy: .cliManaged,
            authorizationScope: "Kimi Coding Plan test scope",
            websiteActionIDs: ["coding-plan.kimi.console"],
            allowedRuntimeKinds: [.nativeAPI, .localAgent]
        )
        let resources = makeResources(codingPlans: [invalid])

        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: resources),
                resources: resources,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidDescriptor(invalid.catalogID)
        )
    }

    func testRestrictedPlanRequiresUsableNamedCompatibility() throws {
        let plan = makeRestrictedPlan()
        let actions = makeWebsiteActions().filter {
            $0.ownerCatalogID != "coding-plan.kimi-code"
        } + [makeRestrictedPlanAction()]
        let missing = makeResources(
            codingPlans: [plan],
            compatibility: [],
            websiteActions: actions
        )
        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: missing),
                resources: missing,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidDescriptor(plan.catalogID)
        )

        let valid = makeResources(
            codingPlans: [plan],
            compatibility: [makeRestrictedCompatibility()],
            websiteActions: actions
        )
        XCTAssertNoThrow(
            try RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: valid),
                resources: valid,
                previouslyPublishedCatalogIDs: []
            ).get()
        )
    }

    func testCompatiblePlanAgentPairRequiresInjectionAndCapabilityEvidence() {
        let plan = makeRestrictedPlan()
        let actions = makeWebsiteActions().filter {
            $0.ownerCatalogID != "coding-plan.kimi-code"
        } + [makeRestrictedPlanAction()]
        let incomplete = makeResources(
            codingPlans: [plan],
            compatibility: [
                makeRestrictedCompatibility(
                    credentialInjectionKind: nil,
                    allowedCapabilities: [],
                    authorizationNotes: nil
                )
            ],
            websiteActions: actions
        )
        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: incomplete),
                resources: incomplete,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidDescriptor("plan-agent-compatibility:restricted-plan:stacioAgent")
        )
    }

    func testWebsiteActionSupportLevelMustMatchOwner() {
        var actions = makeWebsiteActions()
        actions[0] = WebsiteActionEntry(
            actionID: "provider.openai.api-key",
            ownerCatalogID: "provider.openai.com",
            kind: .apiKey,
            title: "Get API Key",
            url: "https://platform.openai.com/api-keys",
            displayOrder: 10,
            isPrimary: true,
            isPromotional: false,
            verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
            supportLevel: .experimental
        )
        let resources = makeResources(websiteActions: actions)
        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: resources),
                resources: resources,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidWebsiteAction("provider.openai.api-key")
        )
    }

    func testCatalogWebsiteActionRequiresVerificationTimestamp() {
        var actions = makeWebsiteActions()
        actions[0] = WebsiteActionEntry(
            actionID: "provider.openai.api-key",
            ownerCatalogID: "provider.openai.com",
            kind: .apiKey,
            title: "Get API Key",
            url: "https://platform.openai.com/api-keys",
            displayOrder: 10,
            isPrimary: true,
            isPromotional: false,
            verifiedAt: nil,
            supportLevel: .ga
        )
        let resources = makeResources(websiteActions: actions)

        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: resources),
                resources: resources,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidWebsiteAction("provider.openai.api-key")
        )
    }

    func testCatalogOwnerCannotHavePrimaryActionsAcrossDifferentKinds() {
        let duplicatePrimary = WebsiteActionEntry(
            actionID: "provider.openai.billing",
            ownerCatalogID: "provider.openai.com",
            kind: .billing,
            title: "Billing",
            url: "https://platform.openai.com/settings/billing",
            displayOrder: 20,
            isPrimary: true,
            isPromotional: false,
            verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
            supportLevel: .ga
        )
        let resources = makeResources(
            websiteActions: makeWebsiteActions() + [duplicatePrimary]
        )

        XCTAssertEqual(
            RuntimeCatalogSetLoader.load(
                manifest: makeManifest(resources: resources),
                resources: resources,
                previouslyPublishedCatalogIDs: []
            ).failure,
            .invalidWebsiteAction("provider.openai.com")
        )
    }

    func testWebsiteActionRequiresNonPromotionalOfficialAction() {
        // 只有推广 action → 失败
        let promotionalOnly = [
            WebsiteActionEntry(
                actionID: "provider.openai.promo",
                ownerCatalogID: "provider.openai.com",
                kind: .website,
                title: "Promotion",
                url: "https://platform.openai.com/",
                displayOrder: 10,
                isPrimary: true,
                isPromotional: true,
                verifiedAt: Self.iso8601.date(from: "2026-08-04T00:00:00Z"),
                supportLevel: .ga
            )
        ]
        let provider = ProviderCatalogEntry(
            catalogID: "provider.openai.com",
            providerID: "openai.com",
            displayName: "OpenAI",
            officialOwner: "OpenAI",
            officialActionURL: nil,
            supportLevel: .ga,
            suggestedBaseURL: "https://api.openai.com/v1",
            websiteActionIDs: ["provider.openai.promo"]
        )
        let resources = makeResources(
            providers: [provider],
            codingPlans: [],
            localAgents: [],
            compatibility: [],
            websiteActions: promotionalOnly
        )
        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )
        XCTAssertEqual(result.failure, .invalidWebsiteAction("provider.openai.promo"))
    }

    // MARK: - pricing 半开区间

    func testPricingIntervalsNonOverlapping() {
        // 边界相接 [a,b) + [b,∞) 不重叠 → 成功
        let pricing = [
            PricingEntry(
                pricingEntryID: "pricing.openai.gpt-4o.2026-01", providerID: "openai.com", modelID: "gpt-4o",
                effectiveFrom: Self.iso8601.date(from: "2026-01-01T00:00:00Z")!,
                effectiveUntil: Self.iso8601.date(from: "2026-06-01T00:00:00Z")!,
                inputPerMillion: 2.5, outputPerMillion: 10.0
            ),
            PricingEntry(
                pricingEntryID: "pricing.openai.gpt-4o.2026-06", providerID: "openai.com", modelID: "gpt-4o",
                effectiveFrom: Self.iso8601.date(from: "2026-06-01T00:00:00Z")!,
                effectiveUntil: nil,
                inputPerMillion: 2.0, outputPerMillion: 8.0
            )
        ]
        let resources = makeResources(pricing: pricing)
        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )
        XCTAssertTrue(result.isSuccess, "边界相接不重叠")

        // 重叠 [a,c) + [b,d) → 失败
        let overlapping = [
            pricing[0],
            PricingEntry(
                pricingEntryID: "pricing.openai.gpt-4o.2026-03", providerID: "openai.com", modelID: "gpt-4o",
                effectiveFrom: Self.iso8601.date(from: "2026-03-01T00:00:00Z")!,
                effectiveUntil: Self.iso8601.date(from: "2026-09-01T00:00:00Z")!,
                inputPerMillion: 2.2, outputPerMillion: 9.0
            )
        ]
        let overlapResources = makeResources(pricing: overlapping)
        let overlapResult = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: overlapResources),
            resources: overlapResources,
            previouslyPublishedCatalogIDs: []
        )
        guard case .failure(let error) = overlapResult else {
            return XCTFail("重叠价格区间必须失败")
        }
        XCTAssertEqual(error, .pricingOverlap(entryA: "pricing.openai.gpt-4o.2026-01", entryB: "pricing.openai.gpt-4o.2026-03"))
    }

    func testPricingEntryIDUnique() {
        var pricing = makePricing()
        pricing.append(pricing[0]) // 重复 pricingEntryID
        let resources = makeResources(pricing: pricing)
        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )
        guard case .failure(let error) = result else {
            return XCTFail("重复 pricingEntryID 必须失败")
        }
        XCTAssertEqual(error, .duplicatePricingEntryID("pricing.openai.gpt-4o.2026-01"))
    }

    func testPricingRejectsNegativeAmountAndReversedInterval() {
        let invalid = PricingEntry(
            pricingEntryID: "pricing.invalid",
            providerID: "openai.com",
            modelID: "model",
            effectiveFrom: Self.iso8601.date(from: "2026-06-01T00:00:00Z")!,
            effectiveUntil: Self.iso8601.date(from: "2026-01-01T00:00:00Z")!,
            inputPerMillion: -1,
            outputPerMillion: 1
        )
        let resources = makeResources(pricing: [invalid])

        let result = RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        )

        guard case let .failure(error) = result else {
            return XCTFail("非法价格事实必须失败")
        }
        XCTAssertEqual(error, .invalidDescriptor(invalid.pricingEntryID))
    }

    func testPricingEntryIDNeverServesAsModelCatalog() throws {
        let resources = makeResources()
        let (set, _) = try RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        ).get()
        XCTAssertTrue(set.pricingEntryIDNeverServesAsModelID())
        // 价格 ID 与模型 ID 命名空间分离：pricingEntryID 不出现在 modelID 位置
        let pricingIDs = Set(set.pricing.map(\.pricingEntryID))
        for entry in set.pricing {
            XCTAssertFalse(pricingIDs.contains(entry.modelID))
        }
    }

    // MARK: - 支持分级

    func testExperimentalNotDefaultNorFallback() throws {
        let resources = makeResources()
        let (set, _) = try RuntimeCatalogSetLoader.load(
            manifest: makeManifest(resources: resources),
            resources: resources,
            previouslyPublishedCatalogIDs: []
        ).get()
        // Experimental 不默认
        XCTAssertFalse(CatalogSupportLevel.experimental.isDefaultable)
        XCTAssertFalse(CatalogSupportLevel.experimental.isFallbackable)
        XCTAssertTrue(CatalogSupportLevel.ga.isDefaultable)
        // 默认集合只含 GA
        let defaults = set.defaultableProviders()
        XCTAssertFalse(defaults.contains { $0.supportLevel == .experimental })
        // 可执行候选保持 Experimental；没有真实 Local Agent Runtime 的受限套餐 fail closed。
        let plans = try JSONDecoder().decode(
            [CodingPlanCatalogEntry].self,
            from: Data(contentsOf: URL(fileURLWithPath: resourceDirectory + "/coding-plan.json"))
        )
        XCTAssertEqual(
            Set(plans.filter { $0.supportLevel == .unsupported }.map(\.planID)),
            ["aliyun-coding-plan", "glm-coding-plan"]
        )
        XCTAssertTrue(
            plans.filter { $0.supportLevel != .unsupported }.allSatisfy {
                $0.supportLevel == .experimental
            }
        )
    }

    // MARK: - 真实资源 JSON 加载

    func testLoadRealResourceJSONFiles() throws {
        let fileNames = [
            "provider.json", "coding-plan.json", "local-agent.json",
            "plan-agent-compatibility.json", "website-action.json", "provider-pricing.json",
            "stacio-tool.json"
        ]
        var resources: [String: Data] = [:]
        for name in fileNames {
            resources[name] = try Data(contentsOf: URL(fileURLWithPath: resourceDirectory + "/" + name))
        }
        let manifest = makeManifest(resources: resources)
        let result = RuntimeCatalogSetLoader.load(
            manifest: manifest, resources: resources, previouslyPublishedCatalogIDs: []
        )
        let (set, evidence) = try result.get()
        XCTAssertEqual(set.providers.count, 10, "九个可配置 API Provider 加一个明确 Unsupported 的 Anthropic descriptor")
        XCTAssertEqual(set.codingPlans.count, 8, "四个 Key/受限套餐加四个账号订阅 Coding Plan")
        XCTAssertEqual(set.localAgents.count, 10)
        XCTAssertEqual(set.pricing.count, 2)
        XCTAssertEqual(set.toolCatalog.revision, 3)
        XCTAssertEqual(set.toolCatalog.tools.map(\.toolID), [StacioBuiltinToolID.terminalCommand])
        XCTAssertEqual(evidence.verifiedResourceHashes.count, 7)
        // openai-compatible.custom 无官方 owner
        let custom = try XCTUnwrap(set.providers.first { $0.catalogID == "provider.openai-compatible.custom" })
        XCTAssertNil(custom.officialOwner)
        XCTAssertTrue(custom.noForgedOfficialButton)
        // 至少一个非推广官方主动作
        XCTAssertTrue(set.websiteActions.contains { $0.nonPromotional })

        let openAI = try XCTUnwrap(set.provider(catalogID: "provider.openai.com"))
        XCTAssertEqual(openAI.suggestedBaseURL, "https://api.openai.com/v1")
        XCTAssertTrue(openAI.requiresCredential)
        XCTAssertEqual(openAI.modelDiscoveryStrategy, .openAIModels)
        XCTAssertEqual(
            set.primaryWebsiteAction(ownerCatalogID: openAI.catalogID)?.url,
            "https://platform.openai.com/api-keys"
        )

        let ollama = try XCTUnwrap(set.provider(catalogID: "provider.ollama.local"))
        XCTAssertEqual(ollama.suggestedBaseURL, "http://127.0.0.1:11434/v1")
        XCTAssertTrue(ollama.permitsNoCredential)
        XCTAssertFalse(ollama.requiresCredential)

        let customProvider = try XCTUnwrap(set.provider(catalogID: "provider.openai-compatible.custom"))
        XCTAssertNil(customProvider.suggestedBaseURL)
        XCTAssertTrue(customProvider.allowsManualModelIDs)

        let mozheActions = set.websiteActions(ownerCatalogID: "provider.mozheapi")
        XCTAssertTrue(mozheActions.contains { !$0.isPromotional && !$0.url.contains("aff=") })
        XCTAssertTrue(mozheActions.contains { $0.isPromotional && $0.url.contains("aff=79LZW99ZKN8S") })
    }

    func testBundledCatalogLoadsHashVerifiedSnapshot() throws {
        let catalog = BundledRuntimeCatalog.shared
        XCTAssertNil(catalog.loadError)
        let set = try XCTUnwrap(catalog.catalogSet)
        XCTAssertEqual(set.catalogSetRevision, 3)
        XCTAssertEqual(set.providers.count, 10)
        XCTAssertEqual(set.codingPlans.count, 8)
        XCTAssertEqual(catalog.toolCatalog?.tools.map(\.toolID), [StacioBuiltinToolID.terminalCommand])
        XCTAssertEqual(catalog.evidence?.verifiedResourceHashes.count, 7)
    }

    func testBundledCatalogSupportsCurrentShippingAppVersion() throws {
        let manifestData = try Data(
            contentsOf: URL(fileURLWithPath: resourceDirectory)
                .appendingPathComponent("runtime-catalog-manifest-v1.json")
        )
        let manifest = try JSONDecoder().decode(RuntimeCatalogManifest.self, from: manifestData)
        var resources: [String: Data] = [:]
        for descriptor in manifest.resources {
            resources[descriptor.relativePath] = try Data(
                contentsOf: URL(fileURLWithPath: resourceDirectory)
                    .appendingPathComponent(descriptor.relativePath)
            )
        }

        XCTAssertNoThrow(
            try RuntimeCatalogSetLoader.load(
                manifest: manifest,
                resources: resources,
                previouslyPublishedCatalogIDs: [],
                currentAppVersion: "0.14.4"
            ).get()
        )
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
