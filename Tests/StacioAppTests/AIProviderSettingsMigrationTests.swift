import Dispatch
import Foundation
@testable import StacioApp
import XCTest

final class AIProviderSettingsMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "Stacio.AIProviderSettingsMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testMigratesRecognizedLegacyProviderIntoSingleEnvelope() throws {
        let migratedID = migrationProviderID(1)
        var generatedIDs = 0
        setLegacyProviderValues(
            provider: AIProviderProfile.deepSeek.rawValue,
            baseURL: "https://legacy.deepseek.example/v1",
            model: "  legacy-chat\n",
            customModels: ["custom-one", " deepseek-chat ", "custom-one", "  "],
            compatibilityProtocol: .responses,
            maxRetryCount: 4,
            requestTimeoutSeconds: 91,
            userAgent: " Legacy\nAgent "
        )
        let store = AppSettingsStore(defaults: defaults) {
            generatedIDs += 1
            return migratedID
        }

        let envelope = try store.loadAIProviderSettings()
        let provider = try XCTUnwrap(envelope.aiProviders.only)

        XCTAssertEqual(generatedIDs, 1)
        XCTAssertEqual(envelope.formatVersion, AIProviderSettingsEnvelope.currentFormatVersion)
        XCTAssertEqual(envelope.defaultAIProviderID, migratedID)
        XCTAssertEqual(envelope.legacyKeyMigrationProviderID, migratedID)
        XCTAssertEqual(provider.id, migratedID)
        XCTAssertEqual(provider.profile, .deepSeek)
        XCTAssertEqual(provider.displayName, AIProviderProfile.deepSeek.displayName)
        XCTAssertEqual(provider.baseURL, "https://legacy.deepseek.example/v1")
        XCTAssertEqual(provider.compatibilityProtocol, .responses)
        XCTAssertEqual(provider.maxRetryCount, 4)
        XCTAssertEqual(provider.requestTimeoutSeconds, 91)
        XCTAssertEqual(provider.userAgent, "Legacy Agent")
        XCTAssertTrue(provider.isEnabled)
        XCTAssertNil(provider.lastVerifiedAt)
        XCTAssertNil(provider.lastModelSyncAt)
        XCTAssertEqual(
            provider.models.map(\.id),
            ["deepseek-chat", "deepseek-reasoner", "custom-one", "legacy-chat"]
        )
        XCTAssertTrue(provider.models.allSatisfy(\.isEnabled))
        XCTAssertEqual(provider.models.map(\.isManual), [false, false, true, true])
        XCTAssertTrue(provider.models.allSatisfy { $0.wasReturnedByLatestCatalog == false })
        XCTAssertEqual(provider.defaultModelID, "legacy-chat")
        XCTAssertEqual(try decodedPersistedEnvelope(), envelope)
    }

    func testLegacyGlobalContextAndReasoningMigrateIntoEachLegacyModelAsSyncableFallbacks() throws {
        let migratedID = migrationProviderID(11)
        setLegacyProviderValues(
            provider: AIProviderProfile.openAICompatible.rawValue,
            baseURL: "https://legacy.example/v1",
            model: "legacy-model",
            customModels: ["second-model"]
        )
        defaults.set("high", forKey: "Stacio.Settings.aiReasoningEffort")
        defaults.set(16_000, forKey: "Stacio.Settings.aiContextCharacterLimit")
        let store = AppSettingsStore(defaults: defaults, aiProviderIDGenerator: { migratedID })

        let provider = try XCTUnwrap(try store.loadAIProviderSettings().aiProviders.only)

        XCTAssertTrue(provider.models.allSatisfy {
            $0.capabilities.contextCharacterLimit == 16_000
                && $0.capabilities.contextCharacterLimitSource == .unknown
                && $0.capabilities.reasoningEffort == .high
                && $0.capabilities.reasoningEffortSource == .unknown
        })
    }

    func testExistingEnvelopeWithoutCapabilitiesMigratesLegacyGlobalValuesPerModel() throws {
        var provider = migrationProvider(id: migrationProviderID(12), modelID: "saved-model")
        provider.models.append(
            .init(
                id: "second-saved-model",
                isEnabled: true,
                isManual: true,
                wasReturnedByLatestCatalog: false
            )
        )
        let envelope = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id
        )
        let originalData = try JSONEncoder().encode(envelope)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalData) as? [String: Any]
        )
        let providers = try XCTUnwrap(payload["aiProviders"] as? [[String: Any]])
        payload["aiProviders"] = providers.map { provider in
            var legacyProvider = provider
            let models = try? XCTUnwrap(legacyProvider["models"] as? [[String: Any]])
            legacyProvider["models"] = models?.map { model in
                var legacyModel = model
                legacyModel.removeValue(forKey: "capabilities")
                return legacyModel
            }
            return legacyProvider
        }
        defaults.set(
            try JSONSerialization.data(withJSONObject: payload),
            forKey: AppSettingsStore.aiProviderSettingsDefaultsKey
        )
        defaults.set("low", forKey: "Stacio.Settings.aiReasoningEffort")
        defaults.set(7_500, forKey: "Stacio.Settings.aiContextCharacterLimit")

        let loaded = try AppSettingsStore(defaults: defaults).loadAIProviderSettings()

        XCTAssertTrue(loaded.aiProviders[0].models.allSatisfy {
            $0.capabilities.contextCharacterLimit == 7_500
                && $0.capabilities.contextCharacterLimitSource == .unknown
                && $0.capabilities.reasoningEffort == .low
                && $0.capabilities.reasoningEffortSource == .unknown
        })
        let persisted = try decodedPersistedEnvelope()
        XCTAssertEqual(persisted, loaded)
    }

    func testLegacyMigrationUsesProfileDefaultWhenCurrentLegacyModelIsEmpty() throws {
        let migratedID = migrationProviderID(2)
        setLegacyProviderValues(
            provider: AIProviderProfile.openAI.rawValue,
            baseURL: "https://api.openai.com/v1",
            model: "  ",
            customModels: ["private-model"]
        )
        let store = AppSettingsStore(defaults: defaults, aiProviderIDGenerator: { migratedID })

        let provider = try XCTUnwrap(store.loadAIProviderSettings().aiProviders.only)

        XCTAssertEqual(provider.defaultModelID, AIProviderProfile.openAI.defaultModel)
    }

    func testLegacyMigrationIsIdempotent() throws {
        let migratedID = migrationProviderID(3)
        var generatedIDs = 0
        setLegacyProviderValues(
            provider: AIProviderProfile.openAI.rawValue,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1"
        )
        let store = AppSettingsStore(defaults: defaults) {
            generatedIDs += 1
            return migratedID
        }

        let first = try store.loadAIProviderSettings()
        let second = try store.loadAIProviderSettings()

        XCTAssertEqual(generatedIDs, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.aiProviders.map(\.id), [migratedID])
    }

    func testRulesResidueDoesNotCreateExternalProvider() throws {
        var generatedIDs = 0
        setLegacyProviderValues(
            provider: AIProviderProfile.portDeskRules.rawValue,
            baseURL: "https://stale.example/v1",
            model: "stale-model",
            customModels: ["another-stale-model"]
        )
        let store = AppSettingsStore(defaults: defaults) {
            generatedIDs += 1
            return migrationProviderID(4)
        }

        let envelope = try store.loadAIProviderSettings()

        XCTAssertEqual(envelope, .rulesOnly)
        XCTAssertEqual(generatedIDs, 0)
        XCTAssertEqual(defaults.string(forKey: LegacyKey.baseURL), "https://stale.example/v1")
        XCTAssertEqual(defaults.string(forKey: LegacyKey.model), "stale-model")
        XCTAssertEqual(defaults.stringArray(forKey: LegacyKey.customModels), ["another-stale-model"])
        XCTAssertEqual(try decodedPersistedEnvelope(), .rulesOnly)
    }

    func testUnknownLegacyProviderDoesNotCreateExternalProvider() throws {
        var generatedIDs = 0
        setLegacyProviderValues(
            provider: "Private Mystery Provider",
            baseURL: "https://unknown.example/v1",
            model: "unknown-model",
            customModels: ["unknown-custom"]
        )
        let store = AppSettingsStore(defaults: defaults) {
            generatedIDs += 1
            return migrationProviderID(5)
        }

        let envelope = try store.loadAIProviderSettings()

        XCTAssertEqual(envelope, .rulesOnly)
        XCTAssertEqual(generatedIDs, 0)
        XCTAssertEqual(defaults.string(forKey: LegacyKey.provider), "Private Mystery Provider")
        XCTAssertEqual(try decodedPersistedEnvelope(), .rulesOnly)
    }

    func testCorruptedEnvelopeFallsBackWithoutReplacingOriginalData() throws {
        let corrupted = Data("not-json".utf8)
        defaults.set(corrupted, forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertThrowsError(try store.loadAIProviderSettings()) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertEqual(store.snapshot().aiProviderSettings, .rulesOnly)
        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), corrupted)
    }

    func testUnsupportedVersionDoesNotRewriteOriginalData() throws {
        let unsupported = AIProviderSettingsEnvelope(
            formatVersion: AIProviderSettingsEnvelope.currentFormatVersion + 1,
            aiProviders: [],
            defaultAIProviderID: BuiltInAIProvider.stacioRulesID
        )
        let original = try JSONEncoder().encode(unsupported)
        defaults.set(original, forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertThrowsError(try store.loadAIProviderSettings()) { error in
            XCTAssertEqual(
                error as? AIProviderSettingsStoreError,
                .unsupportedVersion(AIProviderSettingsEnvelope.currentFormatVersion + 1)
            )
        }
        XCTAssertEqual(store.snapshot().aiProviderSettings, .rulesOnly)
        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), original)
    }

    func testSavingUnsupportedVersionRejectsBeforeWriteWithoutNotification() throws {
        let original = Data("original-provider-settings".utf8)
        defaults.set(original, forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        let store = AppSettingsStore(defaults: defaults)
        let notification = expectation(description: "settings change must not be posted")
        notification.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: store,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let unsupportedVersion = AIProviderSettingsEnvelope.currentFormatVersion + 1
        let unsupported = AIProviderSettingsEnvelope(
            formatVersion: unsupportedVersion,
            aiProviders: [],
            defaultAIProviderID: BuiltInAIProvider.stacioRulesID
        )

        XCTAssertThrowsError(try store.saveAIProviderSettings(unsupported)) { error in
            XCTAssertEqual(
                error as? AIProviderSettingsStoreError,
                .unsupportedVersion(unsupportedVersion)
            )
        }

        wait(for: [notification], timeout: 0.05)
        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), original)
    }

    func testFutureSchemaRejectsVersionBeforeDecodingPayload() {
        let futureVersion = AIProviderSettingsEnvelope.currentFormatVersion + 1
        let futureData = Data("{\"formatVersion\":\(futureVersion)}".utf8)
        defaults.set(futureData, forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertThrowsError(try store.loadAIProviderSettings()) { error in
            XCTAssertEqual(
                error as? AIProviderSettingsStoreError,
                .unsupportedVersion(futureVersion)
            )
        }
        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), futureData)
    }

    func testConcurrentFirstMigrationGeneratesOneProviderAndReturnsOneEnvelope() throws {
        setLegacyProviderValues(
            provider: AIProviderProfile.openAI.rawValue,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1"
        )
        let state = ConcurrentMigrationState()
        let firstGeneratorEntered = DispatchSemaphore(value: 0)
        let secondGeneratorEntered = DispatchSemaphore(value: 0)
        let releaseFirstGenerator = DispatchSemaphore(value: 0)
        let idGenerator = {
            let generation = state.nextGeneration()
            if generation == 1 {
                firstGeneratorEntered.signal()
                _ = releaseFirstGenerator.wait(timeout: .now() + 2)
            } else {
                secondGeneratorEntered.signal()
            }
            return migrationProviderID(10 + generation)
        }
        let firstStore = AppSettingsStore(defaults: defaults, aiProviderIDGenerator: idGenerator)
        let secondStore = AppSettingsStore(defaults: defaults, aiProviderIDGenerator: idGenerator)
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "Stacio.AIProviderSettingsMigrationTests.concurrent-load",
            attributes: .concurrent
        )

        group.enter()
        queue.async {
            defer { group.leave() }
            state.record(Result { try firstStore.loadAIProviderSettings() })
        }
        XCTAssertEqual(firstGeneratorEntered.wait(timeout: .now() + 1), .success)

        group.enter()
        queue.async {
            defer { group.leave() }
            state.record(Result { try secondStore.loadAIProviderSettings() })
        }
        XCTAssertEqual(secondGeneratorEntered.wait(timeout: .now() + 0.15), .timedOut)
        releaseFirstGenerator.signal()

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        let outcome = state.outcome()
        XCTAssertEqual(outcome.generationCount, 1)
        XCTAssertTrue(outcome.errors.isEmpty)
        XCTAssertEqual(outcome.envelopes.count, 2)
        XCTAssertEqual(outcome.envelopes.first, outcome.envelopes.last)
        XCTAssertEqual(try decodedPersistedEnvelope(), try XCTUnwrap(outcome.envelopes.first))
    }

    func testUnrelatedSettingsUpdateDoesNotReplaceCorruptedEnvelope() {
        let corrupted = Data("{corrupted".utf8)
        defaults.set(corrupted, forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        let store = AppSettingsStore(defaults: defaults)

        store.update { settings in
            settings.terminalFontSize = 16
            settings.aiReasoningEffort = .high
        }

        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), corrupted)
        XCTAssertEqual(defaults.object(forKey: "Stacio.Settings.terminalFontSize") as? Double, 16)
        XCTAssertEqual(defaults.string(forKey: "Stacio.Settings.aiReasoningEffort"), "high")
    }

    func testUpdateDoesNotPersistMutatedProviderEnvelope() throws {
        let originalProvider = migrationProvider(id: migrationProviderID(6), modelID: "original")
        let originalEnvelope = AIProviderSettingsEnvelope(
            aiProviders: [originalProvider],
            defaultAIProviderID: originalProvider.id
        )
        let replacementProvider = migrationProvider(id: migrationProviderID(7), modelID: "replacement")
        let replacementEnvelope = AIProviderSettingsEnvelope(
            aiProviders: [replacementProvider],
            defaultAIProviderID: replacementProvider.id
        )
        let store = AppSettingsStore(defaults: defaults)
        try store.saveAIProviderSettings(originalEnvelope)
        let originalData = try XCTUnwrap(
            defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        )

        store.update { settings in
            settings.aiProviderSettings = replacementEnvelope
            settings.terminalFontSize = 17
        }

        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), originalData)
        XCTAssertEqual(try store.loadAIProviderSettings(), originalEnvelope)
        XCTAssertEqual(defaults.object(forKey: "Stacio.Settings.terminalFontSize") as? Double, 17)
    }

    func testSavingEnvelopeDoesNotMirrorOrDeleteLegacyKeys() throws {
        setLegacyProviderValues(
            provider: "legacy-provider",
            baseURL: "legacy-base-url",
            model: "legacy-model",
            customModels: ["legacy-custom"],
            compatibilityProtocol: .responses,
            maxRetryCount: 5,
            requestTimeoutSeconds: 117,
            userAgent: "legacy-agent"
        )
        let provider = migrationProvider(id: migrationProviderID(8), modelID: "new-model")
        let store = AppSettingsStore(defaults: defaults)

        try store.saveAIProviderSettings(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        assertLegacyProviderValuesAreUnchanged()
    }

    func testCompatibilityUpdatesDoNotRewriteLegacyKeysOrEnvelope() throws {
        let provider = migrationProvider(id: migrationProviderID(9), modelID: "persisted-model")
        let store = AppSettingsStore(defaults: defaults)
        try store.saveAIProviderSettings(
            .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let persistedData = try XCTUnwrap(
            defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        )
        setLegacyProviderValues(
            provider: "legacy-provider",
            baseURL: "legacy-base-url",
            model: "legacy-model",
            customModels: ["legacy-custom"],
            compatibilityProtocol: .responses,
            maxRetryCount: 5,
            requestTimeoutSeconds: 117,
            userAgent: "legacy-agent"
        )

        store.update { settings in
            settings.aiProvider = AIProviderProfile.openAI.rawValue
            settings.aiBaseURL = "https://replacement.example/v1"
            settings.aiModel = "replacement-model"
            settings.aiCustomModels = ["replacement-custom"]
            settings.aiCompatibilityProtocol = .chatCompletions
            settings.aiMaxRetryCount = 0
            settings.aiRequestTimeoutSeconds = 5
            settings.aiUserAgent = "replacement-agent"
            settings.aiReasoningEffort = .minimal
        }

        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), persistedData)
        assertLegacyProviderValuesAreUnchanged()
        XCTAssertEqual(defaults.string(forKey: "Stacio.Settings.aiReasoningEffort"), "minimal")
    }

    func testSnapshotExposesNormalizedProviderEnvelope() throws {
        var provider = migrationProvider(id: migrationProviderID(10), modelID: "unused")
        provider.models = [
            .init(
                id: " disabled ",
                isEnabled: false,
                isManual: true,
                wasReturnedByLatestCatalog: false
            ),
            .init(
                id: " enabled\tmodel ",
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: true
            )
        ]
        provider.defaultModelID = "missing"
        provider.maxRetryCount = 99
        provider.requestTimeoutSeconds = -1
        let unnormalized = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id,
            legacyKeyMigrationProviderID: provider.id
        )
        let original = try JSONEncoder().encode(unnormalized)
        defaults.set(original, forKey: AppSettingsStore.aiProviderSettingsDefaultsKey)
        let store = AppSettingsStore(defaults: defaults)

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.aiProviderSettings, AIProviderSettingsNormalizer.normalized(unnormalized))
        XCTAssertEqual(snapshot.aiProviders, snapshot.aiProviderSettings.aiProviders)
        XCTAssertEqual(snapshot.defaultAIProviderID, provider.id)
        XCTAssertEqual(snapshot.aiModel, "enabled model")
        XCTAssertEqual(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey), original)
    }

    func testRecognizedProfileDoesNotFoldUnknownValueIntoRules() {
        for profile in AIProviderProfile.allCases {
            XCTAssertEqual(AIProviderProfile.recognizedProfile(for: " \(profile.rawValue) "), profile)
            XCTAssertEqual(AIProviderProfile.recognizedProfile(for: " \(profile.displayName) "), profile)
        }
        XCTAssertNil(AIProviderProfile.recognizedProfile(for: "Private Mystery Provider"))
        XCTAssertEqual(AIProviderProfile.profile(for: "Private Mystery Provider"), .portDeskRules)
    }

    func testStoreConformsToStorageBoundaryAndSavePostsNotification() throws {
        let store = AppSettingsStore(defaults: defaults)
        let storage: AIProviderSettingsStoring = store
        let notification = expectation(description: "settings changed")
        let observer = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: store,
            queue: nil
        ) { _ in
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try storage.saveAIProviderSettings(.rulesOnly)

        wait(for: [notification], timeout: 1)
        XCTAssertEqual(try storage.loadAIProviderSettings(), .rulesOnly)
    }

    private func setLegacyProviderValues(
        provider: String,
        baseURL: String,
        model: String,
        customModels: [String] = [],
        compatibilityProtocol: AICompatibilityProtocolPreference = .chatCompletions,
        maxRetryCount: Int = 1,
        requestTimeoutSeconds: Int = 45,
        userAgent: String = "Stacio"
    ) {
        defaults.set(provider, forKey: LegacyKey.provider)
        defaults.set(baseURL, forKey: LegacyKey.baseURL)
        defaults.set(model, forKey: LegacyKey.model)
        defaults.set(customModels, forKey: LegacyKey.customModels)
        defaults.set(compatibilityProtocol.rawValue, forKey: LegacyKey.compatibilityProtocol)
        defaults.set(maxRetryCount, forKey: LegacyKey.maxRetryCount)
        defaults.set(requestTimeoutSeconds, forKey: LegacyKey.requestTimeoutSeconds)
        defaults.set(userAgent, forKey: LegacyKey.userAgent)
    }

    private func assertLegacyProviderValuesAreUnchanged(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(defaults.string(forKey: LegacyKey.provider), "legacy-provider", file: file, line: line)
        XCTAssertEqual(defaults.string(forKey: LegacyKey.baseURL), "legacy-base-url", file: file, line: line)
        XCTAssertEqual(defaults.string(forKey: LegacyKey.model), "legacy-model", file: file, line: line)
        XCTAssertEqual(defaults.stringArray(forKey: LegacyKey.customModels), ["legacy-custom"], file: file, line: line)
        XCTAssertEqual(defaults.string(forKey: LegacyKey.compatibilityProtocol), "responses", file: file, line: line)
        XCTAssertEqual(defaults.object(forKey: LegacyKey.maxRetryCount) as? Int, 5, file: file, line: line)
        XCTAssertEqual(defaults.object(forKey: LegacyKey.requestTimeoutSeconds) as? Int, 117, file: file, line: line)
        XCTAssertEqual(defaults.string(forKey: LegacyKey.userAgent), "legacy-agent", file: file, line: line)
    }

    private func decodedPersistedEnvelope() throws -> AIProviderSettingsEnvelope {
        try JSONDecoder().decode(
            AIProviderSettingsEnvelope.self,
            from: XCTUnwrap(defaults.data(forKey: AppSettingsStore.aiProviderSettingsDefaultsKey))
        )
    }
}

private enum LegacyKey {
    static let provider = "Stacio.Settings.aiProvider"
    static let baseURL = "Stacio.Settings.aiBaseURL"
    static let model = "Stacio.Settings.aiModel"
    static let maxRetryCount = "Stacio.Settings.aiMaxRetryCount"
    static let userAgent = "Stacio.Settings.aiUserAgent"
    static let requestTimeoutSeconds = "Stacio.Settings.aiRequestTimeoutSeconds"
    static let customModels = "Stacio.Settings.aiCustomModels"
    static let compatibilityProtocol = "Stacio.Settings.aiCompatibilityProtocol"
}

private func migrationProvider(id: UUID, modelID: String) -> AIProviderConfiguration {
    AIProviderConfiguration(
        id: id,
        profile: .openAICompatible,
        displayName: "Migration Test",
        baseURL: "https://api.example.com/v1",
        models: [
            .init(
                id: modelID,
                isEnabled: true,
                isManual: true,
                wasReturnedByLatestCatalog: false
            )
        ],
        defaultModelID: modelID,
        compatibilityProtocol: .chatCompletions,
        maxRetryCount: 1,
        requestTimeoutSeconds: 45,
        userAgent: "Stacio",
        isEnabled: true,
        lastVerifiedAt: nil,
        lastModelSyncAt: nil
    )
}

private func migrationProviderID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", suffix))!
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private final class ConcurrentMigrationState: @unchecked Sendable {
    private let lock = NSLock()
    private var generationCount = 0
    private var envelopes: [AIProviderSettingsEnvelope] = []
    private var errors: [Error] = []

    func nextGeneration() -> Int {
        lock.withLock {
            generationCount += 1
            return generationCount
        }
    }

    func record(_ result: Result<AIProviderSettingsEnvelope, Error>) {
        lock.withLock {
            switch result {
            case let .success(envelope):
                envelopes.append(envelope)
            case let .failure(error):
                errors.append(error)
            }
        }
    }

    func outcome() -> (
        generationCount: Int,
        envelopes: [AIProviderSettingsEnvelope],
        errors: [Error]
    ) {
        lock.withLock {
            (generationCount, envelopes, errors)
        }
    }
}
