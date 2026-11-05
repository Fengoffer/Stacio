import Foundation
@testable import StacioApp
import XCTest

final class AIProviderSettingsTests: XCTestCase {
    func testDefaultConfigurationHasNoImplicitProvider() {
        let envelope = AIProviderSettingsEnvelope.defaultConfiguration

        XCTAssertEqual(envelope.aiProviders, [])
        XCTAssertEqual(envelope.defaultAIProviderID, BuiltInAIProvider.stacioRulesID)
        XCTAssertNil(envelope.legacyKeyMigrationProviderID)
        XCTAssertEqual(envelope, .rulesOnly)
    }

    func testNormalizationClearsDisabledDefaultModelWithoutSelectingAnotherModel() {
        let provider = makeProvider(
            id: providerID(1),
            models: [
                .init(
                    id: "disabled",
                    isEnabled: false,
                    isManual: false,
                    wasReturnedByLatestCatalog: true
                ),
                .init(
                    id: "enabled",
                    isEnabled: true,
                    isManual: false,
                    wasReturnedByLatestCatalog: true
                )
            ],
            defaultModelID: "disabled"
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertNil(result.aiProviders[0].defaultModelID)
        XCTAssertFalse(result.aiProviders[0].isEnabled)
        XCTAssertEqual(result.defaultAIProviderID, provider.id)
    }

    func testNormalizationDisablesProviderWithoutEnabledModels() {
        let provider = makeProvider(
            id: providerID(1),
            models: [
                .init(
                    id: "disabled",
                    isEnabled: false,
                    isManual: true,
                    wasReturnedByLatestCatalog: false
                )
            ],
            defaultModelID: "disabled"
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertNil(result.aiProviders[0].defaultModelID)
        XCTAssertFalse(result.aiProviders[0].isEnabled)
    }

    func testNormalizationRejectsStaleCatalogDefaultUsingRuntimeEligibility() {
        var provider = makeProvider(
            models: [
                .init(
                    id: "stale",
                    isEnabled: true,
                    isManual: false,
                    wasReturnedByLatestCatalog: false
                )
            ],
            defaultModelID: "stale"
        )
        provider.catalogID = "provider.example"

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertNil(result.aiProviders[0].defaultModelID)
        XCTAssertFalse(result.aiProviders[0].isEnabled)
        XCTAssertEqual(result.defaultAIProviderID, provider.id)
    }

    func testNormalizationDisablesUnverifiedCatalogProviderWithoutDiscardingConfiguredDefault() {
        var provider = makeProvider(
            models: [enabledModel("catalog-model")],
            defaultModelID: "catalog-model"
        )
        provider.catalogID = "provider.openai.com"
        provider.lastVerifiedAt = nil

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertEqual(result.aiProviders[0].defaultModelID, "catalog-model")
        XCTAssertFalse(result.aiProviders[0].isEnabled)
        XCTAssertEqual(result.defaultAIProviderID, provider.id)
    }

    func testNormalizationRejectsUnverifiedManualDefaultUsingRuntimeEligibility() {
        var provider = makeProvider(
            models: [
                .init(
                    id: "manual",
                    isEnabled: true,
                    isManual: true,
                    wasReturnedByLatestCatalog: false,
                    lastVerifiedAt: nil
                )
            ],
            defaultModelID: "manual"
        )
        provider.catalogID = "provider.openai-compatible.custom"

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertNil(result.aiProviders[0].defaultModelID)
        XCTAssertFalse(result.aiProviders[0].isEnabled)
        XCTAssertEqual(result.defaultAIProviderID, provider.id)
    }

    func testNormalizationDoesNotReplaceInvalidDefaultWithFirstEligibleProvider() {
        var invalidDefault = makeProvider(
            id: providerID(1),
            models: [enabledModel("invalid-default-model")],
            defaultModelID: "invalid-default-model"
        )
        invalidDefault.isEnabled = false
        let firstEligible = makeProvider(
            id: providerID(2),
            models: [enabledModel("first")],
            defaultModelID: "first"
        )
        let secondEligible = makeProvider(
            id: providerID(3),
            models: [enabledModel("second")],
            defaultModelID: "second"
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [invalidDefault, firstEligible, secondEligible],
                defaultAIProviderID: invalidDefault.id
            )
        )

        XCTAssertEqual(
            result.aiProviders.map(\.id),
            [invalidDefault.id, firstEligible.id, secondEligible.id]
        )
        XCTAssertEqual(result.defaultAIProviderID, invalidDefault.id)
    }

    func testNormalizationKeepsDisabledDefaultProviderIdentity() {
        var provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )
        provider.isEnabled = false

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertEqual(result.defaultAIProviderID, provider.id)
        XCTAssertEqual(result.aiProviders, [provider])
    }

    func testNormalizationKeepsRulesDefaultWhenExternalProviderIsEligible() {
        let provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [provider],
                defaultAIProviderID: BuiltInAIProvider.stacioRulesID
            )
        )

        XCTAssertEqual(result.defaultAIProviderID, BuiltInAIProvider.stacioRulesID)
        XCTAssertEqual(result.aiProviders, [provider])
    }

    func testNormalizationDoesNotReplaceUnconfiguredExplicitDefaultWithAnotherProvider() {
        let external = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )
        let unconfiguredID = providerID(2)
        var unconfigured = makeProvider(
            id: unconfiguredID,
            models: [],
            defaultModelID: nil
        )
        unconfigured.isEnabled = true

        let result = AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [unconfigured, external],
                defaultAIProviderID: unconfiguredID
            )
        )

        XCTAssertEqual(result.defaultAIProviderID, unconfiguredID)
        XCTAssertEqual(result.aiProviders.map(\.id), [unconfiguredID, external.id])
        XCTAssertFalse(result.aiProviders[0].isEnabled)
    }

    func testNormalizationDropsLegacyRulesResidueAndKeepsOrdinaryProviderAsStored() {
        var storedProvider = makeProvider(
            id: providerID(2),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )
        storedProvider.displayName = "Private deployment"
        storedProvider.baseURL = "https://private.example/v1"
        var rulesIDProvider = makeProvider(
            id: BuiltInAIProvider.stacioRulesID,
            models: [enabledModel("rules-id")],
            defaultModelID: "rules-id"
        )
        rulesIDProvider.profile = .openAICompatible
        var rulesProfileProvider = makeProvider(
            id: providerID(9),
            models: [enabledModel("rules-profile")],
            defaultModelID: "rules-profile"
        )
        rulesProfileProvider.profile = .portDeskRules

        let result = AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [storedProvider, rulesIDProvider, rulesProfileProvider],
                defaultAIProviderID: storedProvider.id
            )
        )

        XCTAssertEqual(result.aiProviders, [storedProvider])
        XCTAssertEqual(result.defaultAIProviderID, storedProvider.id)
    }

    func testNormalizationDropsEmptyAndDuplicateModelsPreservingFirstOccurrenceAndOrder() {
        let first = AIProviderModelConfiguration(
            id: "  alpha  ",
            isEnabled: false,
            isManual: true,
            wasReturnedByLatestCatalog: false
        )
        let duplicate = AIProviderModelConfiguration(
            id: "alpha",
            isEnabled: true,
            isManual: false,
            wasReturnedByLatestCatalog: true
        )
        let second = AIProviderModelConfiguration(
            id: " beta\tmodel ",
            isEnabled: true,
            isManual: false,
            wasReturnedByLatestCatalog: true
        )
        let provider = makeProvider(
            models: [first, .init(id: " \n ", isEnabled: true, isManual: true, wasReturnedByLatestCatalog: true), duplicate, second],
            defaultModelID: " beta\tmodel "
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertEqual(result.aiProviders[0].models, [
            .init(id: "alpha", isEnabled: false, isManual: true, wasReturnedByLatestCatalog: false),
            .init(id: "beta model", isEnabled: true, isManual: false, wasReturnedByLatestCatalog: true)
        ])
        XCTAssertEqual(result.aiProviders[0].defaultModelID, "beta model")
    }

    func testNormalizationClearsInvalidMigrationMarker() {
        let provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [provider],
                defaultAIProviderID: provider.id,
                legacyKeyMigrationProviderID: providerID(2)
            )
        )

        XCTAssertNil(result.legacyKeyMigrationProviderID)
    }

    func testNormalizationKeepsMigrationMarkerForExistingProvider() {
        let provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )

        let result = AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [provider],
                defaultAIProviderID: provider.id,
                legacyKeyMigrationProviderID: provider.id
            )
        )

        XCTAssertEqual(result.legacyKeyMigrationProviderID, provider.id)
    }

    func testNormalizationSanitizesRequestFieldsAndPreservesOtherProviderFields() {
        let verifiedAt = Date(timeIntervalSince1970: 1_234)
        let syncedAt = Date(timeIntervalSince1970: 5_678)
        var provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )
        provider.profile = .deepSeek
        provider.displayName = "  Private deployment  "
        provider.baseURL = "https://example.test/custom"
        provider.compatibilityProtocol = .responses
        provider.maxRetryCount = -9
        provider.requestTimeoutSeconds = 999
        provider.userAgent = "  Custom\nAgent  "
        provider.lastVerifiedAt = verifiedAt
        provider.lastModelSyncAt = syncedAt

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        ).aiProviders[0]

        XCTAssertEqual(result.profile, .deepSeek)
        XCTAssertEqual(result.displayName, "  Private deployment  ")
        XCTAssertEqual(result.baseURL, "https://example.test/custom")
        XCTAssertEqual(result.compatibilityProtocol, .responses)
        XCTAssertEqual(result.maxRetryCount, 0)
        XCTAssertEqual(result.requestTimeoutSeconds, 120)
        XCTAssertEqual(result.userAgent, "Custom Agent")
        XCTAssertEqual(result.lastVerifiedAt, verifiedAt)
        XCTAssertEqual(result.lastModelSyncAt, syncedAt)
    }

    func testNormalizationClampsOtherRequestFieldBoundaries() {
        var provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )
        provider.maxRetryCount = 99
        provider.requestTimeoutSeconds = 0
        provider.userAgent = " \n\t "

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        ).aiProviders[0]

        XCTAssertEqual(result.maxRetryCount, 5)
        XCTAssertEqual(result.requestTimeoutSeconds, 5)
        XCTAssertEqual(result.userAgent, AppSettings.normalizedAIUserAgent(provider.userAgent))
        XCTAssertEqual(result.userAgent, "Stacio")
    }

    func testCodableRoundTripKeepsIsolatedProviderFieldsAndContainsNoAPIKey() throws {
        var first = makeProvider(
            id: providerID(1),
            models: [enabledModel("shared")],
            defaultModelID: "shared"
        )
        first.displayName = "First"
        first.baseURL = "https://first.example/v1"
        var second = makeProvider(
            id: providerID(2),
            models: [enabledModel("shared")],
            defaultModelID: "shared"
        )
        second.displayName = "Second"
        second.baseURL = "https://second.example/v1"
        second.compatibilityProtocol = .responses
        second.userAgent = "second-agent"
        let envelope = AIProviderSettingsEnvelope(
            aiProviders: [first, second],
            defaultAIProviderID: second.id,
            legacyKeyMigrationProviderID: first.id
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(AIProviderSettingsEnvelope.self, from: data)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let encodedKeys = allJSONKeys(in: jsonObject)
        let forbiddenCredentialKeys = Set(["apikey", "secret", "authorization"])

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.aiProviders.map(\.baseURL), ["https://first.example/v1", "https://second.example/v1"])
        XCTAssertTrue(encodedKeys.contains("aiProviders"))
        XCTAssertTrue(encodedKeys.contains("baseURL"))
        XCTAssertTrue(forbiddenCredentialKeys.isDisjoint(with: encodedKeys.map { $0.lowercased() }))
    }

    func testCatalogDraftCopiesSuggestionWithoutModelsOrImplicitDefault() throws {
        let descriptor = ProviderCatalogEntry(
            catalogID: "provider.example",
            providerID: "example",
            displayName: "Example",
            officialOwner: "Example Inc.",
            officialActionURL: "https://console.example.com/keys",
            supportLevel: .experimental,
            revision: 7,
            suggestedBaseURL: "https://api.example.com/v1",
            websiteActionIDs: ["provider.example.api-key"],
            legacyProfileRawValue: AIProviderProfile.openAICompatible.rawValue
        )

        let draft = try XCTUnwrap(AIProviderConfiguration.catalogDraft(descriptor: descriptor))

        XCTAssertEqual(draft.catalogID, descriptor.catalogID)
        XCTAssertEqual(draft.catalogRevisionAtCreation, 7)
        XCTAssertEqual(draft.baseURL, descriptor.suggestedBaseURL)
        XCTAssertEqual(draft.baseURLSource, .catalogSuggestion)
        XCTAssertFalse(draft.userEditedBaseURL)
        XCTAssertEqual(draft.models, [])
        XCTAssertNil(draft.defaultModelID)
        XCTAssertFalse(draft.isEnabled)
    }

    func testNativeCodingPlanDraftKeepsDistinctIdentityWithoutPresetModels() throws {
        let descriptor = try XCTUnwrap(
            BundledRuntimeCatalog.shared.catalogSet?.codingPlan(
                catalogID: "coding-plan.kimi-code"
            )
        )
        var draft = try XCTUnwrap(AIProviderConfiguration.catalogDraft(descriptor: descriptor))

        XCTAssertEqual(draft.effectiveRuntimeConfigurationKind, .codingPlan)
        XCTAssertEqual(draft.catalogID, descriptor.catalogID)
        XCTAssertEqual(draft.baseURL, descriptor.suggestedBaseURL)
        XCTAssertTrue(draft.models.isEmpty)
        XCTAssertNil(draft.defaultModelID)

        draft.applyUserBaseURL("https://user-plan-endpoint.example/v1")
        XCTAssertEqual(draft.baseURL, "https://user-plan-endpoint.example/v1")
        XCTAssertTrue(draft.userEditedBaseURL)
    }

    func testApplyingUserBaseURLInvalidatesVerificationAndDiscoveredModels() {
        var provider = makeProvider(
            models: [
                .init(id: "discovered", isEnabled: true, isManual: false, wasReturnedByLatestCatalog: true),
                .init(id: "manual", isEnabled: true, isManual: true, wasReturnedByLatestCatalog: false)
            ],
            defaultModelID: "discovered"
        )
        provider.lastVerifiedAt = Date(timeIntervalSince1970: 1_234)
        provider.lastModelSyncAt = Date(timeIntervalSince1970: 5_678)

        provider.applyUserBaseURL("https://private.example/v1")

        XCTAssertEqual(provider.baseURL, "https://private.example/v1")
        XCTAssertEqual(provider.baseURLSource, .userProvided)
        XCTAssertTrue(provider.userEditedBaseURL)
        XCTAssertNil(provider.lastVerifiedAt)
        XCTAssertNil(provider.lastModelSyncAt)
        XCTAssertFalse(provider.isEnabled)
        XCTAssertFalse(provider.models[0].wasReturnedByLatestCatalog)
        XCTAssertTrue(provider.models[1].isManual)
    }

    func testModelSelectionIsHashableAndCodable() throws {
        let selection = AIModelSelection(providerID: providerID(1), modelID: "shared")

        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(AIModelSelection.self, from: data)

        XCTAssertEqual(decoded, selection)
        XCTAssertEqual(Set([selection, decoded]).count, 1)
    }
}

private func makeProvider(
    id: UUID = providerID(99),
    models: [AIProviderModelConfiguration],
    defaultModelID: String?
) -> AIProviderConfiguration {
    AIProviderConfiguration(
        id: id,
        profile: .openAICompatible,
        displayName: "Test Provider",
        baseURL: "https://api.example.com/v1",
        models: models,
        defaultModelID: defaultModelID,
        compatibilityProtocol: .chatCompletions,
        maxRetryCount: 1,
        requestTimeoutSeconds: 45,
        userAgent: "Stacio",
        isEnabled: true,
        lastVerifiedAt: nil,
        lastModelSyncAt: nil
    )
}

private func enabledModel(_ id: String) -> AIProviderModelConfiguration {
    .init(id: id, isEnabled: true, isManual: false, wasReturnedByLatestCatalog: true)
}

private func providerID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))!
}

private func allJSONKeys(in value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        return Array(dictionary.keys) + dictionary.values.flatMap(allJSONKeys)
    }
    if let array = value as? [Any] {
        return array.flatMap(allJSONKeys)
    }
    return []
}
