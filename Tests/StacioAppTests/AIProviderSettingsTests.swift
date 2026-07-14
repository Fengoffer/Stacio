import Foundation
@testable import StacioApp
import XCTest

final class AIProviderSettingsTests: XCTestCase {
    func testNormalizationFallsBackAfterDefaultModelIsDisabled() {
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

        XCTAssertEqual(result.aiProviders[0].defaultModelID, "enabled")
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

    func testNormalizationFallsBackToFirstEligibleProvider() {
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

        XCTAssertEqual(result.aiProviders.map(\.id), [invalidDefault.id, firstEligible.id, secondEligible.id])
        XCTAssertEqual(result.defaultAIProviderID, firstEligible.id)
    }

    func testNormalizationFallsBackToRulesWhenNoProviderIsEligible() {
        var provider = makeProvider(
            id: providerID(1),
            models: [enabledModel("model")],
            defaultModelID: "model"
        )
        provider.isEnabled = false

        let result = AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertEqual(result.defaultAIProviderID, BuiltInAIProvider.stacioRulesID)
    }

    func testNormalizationKeepsRulesAsExplicitDefaultWhenExternalProviderIsEligible() {
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
