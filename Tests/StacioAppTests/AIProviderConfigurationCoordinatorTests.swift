import Dispatch
import Foundation
@testable import StacioApp
import XCTest

final class AIProviderConfigurationCoordinatorTests: XCTestCase {
    func testCreateAppendsNormalizedProviderAndStoresKeyBeforeSettings() throws {
        let existing = makeProvider(id: providerID(1), displayName: "Existing")
        var created = makeProvider(id: providerID(2), displayName: "Created", modelID: "  created-model  ")
        created.maxRetryCount = -4
        created.requestTimeoutSeconds = 999
        created.userAgent = "  Created\nAgent  "
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [existing], defaultAIProviderID: existing.id),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(legacyKey: "legacy-secret", recorder: recorder)
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.saveProvider(created, apiKeyUpdate: .replace("created-secret"))

        XCTAssertEqual(result, settingsStore.envelope)
        XCTAssertEqual(
            result.aiProviders.map(\.id),
            [existing.id, created.id, BuiltInAIProvider.mozheAPIID]
        )
        XCTAssertEqual(result.aiProviders[1].models.map(\.id), ["created-model"])
        XCTAssertEqual(result.aiProviders[1].maxRetryCount, 0)
        XCTAssertEqual(result.aiProviders[1].requestTimeoutSeconds, 120)
        XCTAssertEqual(result.aiProviders[1].userAgent, "Created Agent")
        XCTAssertEqual(keyStore.key(for: created.id), "created-secret")
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertEqual(recorder.events, ["settings.load", "key.read", "key.save", "settings.save"])
    }

    func testEditReplacesSameUUIDInPlaceWithoutChangingOtherProvidersOrOrder() throws {
        let first = makeProvider(id: providerID(1), displayName: "First")
        let original = makeProvider(id: providerID(2), displayName: "Original")
        let third = makeProvider(id: providerID(3), displayName: "Third")
        var edited = original
        edited.displayName = "Edited"
        edited.baseURL = "https://edited.example/v1"
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [first, original, third], defaultAIProviderID: original.id),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [original.id: "old-secret"],
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.saveProvider(edited, apiKeyUpdate: .replace("new-secret"))

        XCTAssertEqual(result, settingsStore.envelope)
        XCTAssertEqual(
            result.aiProviders.map(\.id),
            [first.id, original.id, third.id, BuiltInAIProvider.mozheAPIID]
        )
        XCTAssertEqual(result.aiProviders[0], first)
        XCTAssertEqual(result.aiProviders[1], AIProviderSettingsNormalizer.normalized(
            .init(aiProviders: [edited], defaultAIProviderID: edited.id)
        ).aiProviders[0])
        XCTAssertEqual(result.aiProviders[2], third)
        XCTAssertEqual(keyStore.key(for: original.id), "new-secret")
        XCTAssertEqual(recorder.events, ["settings.load", "key.read", "key.save", "settings.save"])
    }

    func testSaveProviderRemoveDeletesOnlyScopedKeyBeforeSavingConfiguration() throws {
        let provider = makeProvider(id: providerID(1), displayName: "Edited")
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [provider.id: "scoped-secret"],
            legacyKey: "legacy-secret",
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.saveProvider(provider, apiKeyUpdate: .remove)

        XCTAssertEqual(result, settingsStore.envelope)
        XCTAssertNil(keyStore.key(for: provider.id))
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertEqual(recorder.events, ["settings.load", "key.read", "key.delete", "settings.save"])
    }

    func testReplacingScopedKeyConsumesExactLegacyMigrationMarker() throws {
        let provider = makeProvider(id: providerID(1))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(
                aiProviders: [provider],
                defaultAIProviderID: provider.id,
                legacyKeyMigrationProviderID: provider.id
            )
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [provider.id: "old-secret"],
            legacyKey: "legacy-secret"
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.saveProvider(provider, apiKeyUpdate: .replace("new-secret"))

        XCTAssertNil(result.legacyKeyMigrationProviderID)
        XCTAssertNil(settingsStore.envelope.legacyKeyMigrationProviderID)
        XCTAssertEqual(keyStore.key(for: provider.id), "new-secret")
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
    }

    func testRemovingScopedKeyConsumesMarkerAndPreventsLegacyKeyRevival() throws {
        let provider = makeProvider(id: providerID(1))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(
                aiProviders: [provider],
                defaultAIProviderID: provider.id,
                legacyKeyMigrationProviderID: provider.id
            )
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [provider.id: "old-secret"],
            legacyKey: "legacy-secret"
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.saveProvider(provider, apiKeyUpdate: .remove)
        let keyAfterRemoval = try coordinator.readAPIKey(for: provider.id)

        XCTAssertNil(result.legacyKeyMigrationProviderID)
        XCTAssertNil(settingsStore.envelope.legacyKeyMigrationProviderID)
        XCTAssertNil(keyAfterRemoval)
        XCTAssertNil(keyStore.key(for: provider.id))
        XCTAssertEqual(keyStore.legacyReadCallCount, 0)
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
    }

    func testDeleteRemovesProviderAndScopedKeyWhilePreservingOthersAndLegacyGlobal() throws {
        let first = makeProvider(id: providerID(1), displayName: "First")
        let deleted = makeProvider(id: providerID(2), displayName: "Deleted")
        let third = makeProvider(id: providerID(3), displayName: "Third")
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [first, deleted, third], defaultAIProviderID: first.id),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [deleted.id: "deleted-secret", third.id: "third-secret"],
            legacyKey: "legacy-secret",
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.deleteProvider(id: deleted.id)

        XCTAssertEqual(result, settingsStore.envelope)
        XCTAssertEqual(result.aiProviders, [first, third, BuiltInAIProvider.defaultConfiguration])
        XCTAssertEqual(result.defaultAIProviderID, first.id)
        XCTAssertNil(keyStore.key(for: deleted.id))
        XCTAssertEqual(keyStore.key(for: third.id), "third-secret")
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertEqual(recorder.events, ["settings.load", "key.read", "key.delete", "settings.save"])
    }

    func testDeleteMozheAPIReturnsNormalizedSettingsWithoutTouchingScopedKey() throws {
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .rulesOnly,
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [BuiltInAIProvider.mozheAPIID: "mozhe-secret"],
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.deleteProvider(id: BuiltInAIProvider.mozheAPIID)

        XCTAssertEqual(result, .defaultConfiguration)
        XCTAssertEqual(settingsStore.envelope, .rulesOnly)
        XCTAssertEqual(settingsStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.key(for: BuiltInAIProvider.mozheAPIID), "mozhe-secret")
        XCTAssertEqual(keyStore.totalCallCount, 0)
        XCTAssertEqual(recorder.events, ["settings.load"])
    }

    func testEditSettingsFailureRestoresOldScopedKey() throws {
        let provider = makeProvider(id: providerID(1))
        var edited = provider
        edited.displayName = "Edited"
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id),
            recorder: recorder
        )
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"], recorder: recorder)
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(
            try coordinator.saveProvider(edited, apiKeyUpdate: .replace("new-secret"))
        ) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .settingsSave)
        }

        XCTAssertEqual(settingsStore.envelope.aiProviders, [provider])
        XCTAssertEqual(keyStore.key(for: provider.id), "old-secret")
        XCTAssertEqual(
            recorder.events,
            ["settings.load", "key.read", "key.save", "settings.save", "key.save"]
        )
    }

    func testCreateSettingsFailureDeletesNewScopedKey() throws {
        let provider = makeProvider(id: providerID(1))
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: .rulesOnly, recorder: recorder)
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(recorder: recorder)
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(
            try coordinator.saveProvider(provider, apiKeyUpdate: .replace("new-secret"))
        ) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .settingsSave)
        }

        XCTAssertEqual(settingsStore.envelope, .rulesOnly)
        XCTAssertNil(keyStore.key(for: provider.id))
        XCTAssertEqual(
            recorder.events,
            ["settings.load", "key.read", "key.save", "settings.save", "key.delete"]
        )
    }

    func testUnchangedUpdatesConfigurationWithoutTouchingScopedOrLegacyKeys() throws {
        let provider = makeProvider(id: providerID(1), displayName: "Original")
        var edited = provider
        edited.displayName = "Edited"
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [provider.id: "old-secret"],
            legacyKey: "legacy-secret",
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.saveProvider(edited, apiKeyUpdate: .unchanged)

        XCTAssertEqual(result.aiProviders[0].displayName, "Edited")
        XCTAssertEqual(keyStore.key(for: provider.id), "old-secret")
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertEqual(keyStore.readCallCount, 0)
        XCTAssertEqual(keyStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertEqual(recorder.events, ["settings.load", "settings.save"])
    }

    func testDeleteKeyFailureDoesNotSaveSettings() throws {
        let provider = makeProvider(id: providerID(1))
        let recorder = CoordinatorCallRecorder()
        let original = AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original, recorder: recorder)
        let keyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"], recorder: recorder)
        keyStore.deleteFailures[1] = .keyDelete
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(try coordinator.deleteProvider(id: provider.id)) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .keyDelete)
        }

        XCTAssertEqual(settingsStore.envelope, original)
        XCTAssertEqual(settingsStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.key(for: provider.id), "old-secret")
        XCTAssertEqual(recorder.events, ["settings.load", "key.read", "key.delete"])
    }

    func testDeleteSettingsFailureRestoresOldScopedKey() throws {
        let provider = makeProvider(id: providerID(1))
        let recorder = CoordinatorCallRecorder()
        let original = AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original, recorder: recorder)
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"], recorder: recorder)
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(try coordinator.deleteProvider(id: provider.id)) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .settingsSave)
        }

        XCTAssertEqual(settingsStore.envelope, original)
        XCTAssertEqual(keyStore.key(for: provider.id), "old-secret")
        XCTAssertEqual(
            recorder.events,
            ["settings.load", "key.read", "key.delete", "settings.save", "key.save"]
        )
    }

    func testDeleteRollbackFailureSurfacesPrimaryAndRollbackErrors() throws {
        let provider = makeProvider(id: providerID(1))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"])
        keyStore.saveFailures[1] = .keyRollback
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(try coordinator.deleteProvider(id: provider.id)) { error in
            let transactionError = try? XCTUnwrap(error as? AIProviderConfigurationTransactionError)
            XCTAssertEqual(transactionError?.primaryError as? CoordinatorStoreError, .settingsSave)
            XCTAssertEqual(transactionError?.rollbackError as? CoordinatorStoreError, .keyRollback)
        }

        XCTAssertNil(keyStore.key(for: provider.id))
        XCTAssertEqual(settingsStore.envelope.aiProviders, [provider])
    }

    func testNonMigratingScopedKeyAdapterStillRollsBackWhenSettingsSaveFails() throws {
        let provider = makeProvider(id: providerID(1))
        let original = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id
        )
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original)
        settingsStore.saveFailures[1] = .settingsSave
        let underlyingKeyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"])
        let scopedOnlyStore = ScopedOnlyAIApiKeyStoreView(base: underlyingKeyStore)
        let adapter = NonMigratingAIApiKeyStoreAdapter(scopedOnlyStore)
        let coordinator = AIProviderConfigurationCoordinator(
            settingsStore: settingsStore,
            keyStore: adapter
        )

        XCTAssertThrowsError(
            try coordinator.saveProvider(provider, apiKeyUpdate: .replace("new-secret"))
        ) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .settingsSave)
        }

        XCTAssertEqual(underlyingKeyStore.key(for: provider.id), "old-secret")
        XCTAssertNil(try adapter.readLegacyGlobalAPIKey())
        XCTAssertEqual(settingsStore.envelope, original)
    }

    func testUpsertRollbackFailureSurfacesBothErrorsWithoutLeakingAPIKeyInDescription() throws {
        let provider = makeProvider(id: providerID(1))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"])
        keyStore.saveFailures[2] = .keyRollback
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(
            try coordinator.saveProvider(provider, apiKeyUpdate: .replace("highly-sensitive-new-key"))
        ) { error in
            let transactionError = try? XCTUnwrap(error as? AIProviderConfigurationTransactionError)
            XCTAssertEqual(transactionError?.primaryError as? CoordinatorStoreError, .settingsSave)
            XCTAssertEqual(transactionError?.rollbackError as? CoordinatorStoreError, .keyRollback)
            XCTAssertFalse(error.localizedDescription.contains("highly-sensitive-new-key"))
            XCTAssertFalse(error.localizedDescription.contains("old-secret"))
        }

        XCTAssertEqual(keyStore.key(for: provider.id), "highly-sensitive-new-key")
        XCTAssertEqual(settingsStore.envelope.aiProviders, [provider])
    }

    func testSetDefaultChangesOnlyDefaultAndDoesNotTouchKeys() throws {
        let first = makeProvider(id: providerID(1), displayName: "First")
        let second = makeProvider(id: providerID(2), displayName: "Second")
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [first, second], defaultAIProviderID: first.id),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [first.id: "first-secret", second.id: "second-secret"],
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.setDefaultProvider(id: second.id)

        XCTAssertEqual(result, settingsStore.envelope)
        XCTAssertEqual(result.aiProviders, [first, second, BuiltInAIProvider.defaultConfiguration])
        XCTAssertEqual(result.defaultAIProviderID, second.id)
        XCTAssertEqual(keyStore.key(for: first.id), "first-secret")
        XCTAssertEqual(keyStore.key(for: second.id), "second-secret")
        XCTAssertEqual(keyStore.totalCallCount, 0)
        XCTAssertEqual(recorder.events, ["settings.load", "settings.save"])
    }

    func testSetInvalidDefaultUsesNormalizerFallback() throws {
        let first = makeProvider(id: providerID(1), displayName: "First")
        let second = makeProvider(id: providerID(2), displayName: "Second")
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [first, second], defaultAIProviderID: second.id)
        )
        let keyStore = ThrowingAIApiKeyStore()
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.setDefaultProvider(id: providerID(999))

        XCTAssertEqual(result.defaultAIProviderID, first.id)
        XCTAssertEqual(result.aiProviders, [first, second, BuiltInAIProvider.defaultConfiguration])
        XCTAssertEqual(result, settingsStore.envelope)
        XCTAssertEqual(keyStore.totalCallCount, 0)
    }

    func testDeletingDefaultProviderFallsBackToFirstRemainingEligibleProviderInOrder() throws {
        let deletedDefault = makeProvider(id: providerID(1), displayName: "Deleted")
        let firstFallback = makeProvider(id: providerID(2), displayName: "First fallback")
        let secondFallback = makeProvider(id: providerID(3), displayName: "Second fallback")
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(
                aiProviders: [deletedDefault, firstFallback, secondFallback],
                defaultAIProviderID: deletedDefault.id
            )
        )
        let keyStore = ThrowingAIApiKeyStore()
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.deleteProvider(id: deletedDefault.id)

        XCTAssertEqual(
            result.aiProviders,
            [firstFallback, secondFallback, BuiltInAIProvider.defaultConfiguration]
        )
        XCTAssertEqual(result.defaultAIProviderID, firstFallback.id)
        XCTAssertEqual(result, settingsStore.envelope)
    }

    func testNewProviderWithoutMarkerCannotReadLegacyGlobalKey() throws {
        let provider = makeProvider(id: providerID(1))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let keyStore = ThrowingAIApiKeyStore(legacyKey: "legacy-secret")
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertNil(try coordinator.readAPIKey(for: provider.id))
        XCTAssertEqual(keyStore.readCallCount, 1)
        XCTAssertEqual(keyStore.legacyReadCallCount, 0)
        XCTAssertEqual(keyStore.saveCallCount, 0)
        XCTAssertEqual(settingsStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
    }

    func testMarkerMismatchCannotReadLegacyGlobalKey() throws {
        let migrationProvider = makeProvider(id: providerID(1))
        let otherProvider = makeProvider(id: providerID(2))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(
                aiProviders: [migrationProvider, otherProvider],
                defaultAIProviderID: migrationProvider.id,
                legacyKeyMigrationProviderID: migrationProvider.id
            )
        )
        let keyStore = ThrowingAIApiKeyStore(legacyKey: "legacy-secret")
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertNil(try coordinator.readAPIKey(for: otherProvider.id))
        XCTAssertEqual(keyStore.legacyReadCallCount, 0)
        XCTAssertEqual(settingsStore.envelope.legacyKeyMigrationProviderID, migrationProvider.id)
        XCTAssertEqual(settingsStore.saveCallCount, 0)
    }

    func testExactMarkerMigrationCopiesScopedKeyClearsMarkerAndPreservesLegacyGlobal() throws {
        let provider = makeProvider(id: providerID(1))
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(
                aiProviders: [provider],
                defaultAIProviderID: provider.id,
                legacyKeyMigrationProviderID: provider.id
            ),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(legacyKey: "legacy-secret", recorder: recorder)
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.readAPIKey(for: provider.id)

        XCTAssertEqual(result, "legacy-secret")
        XCTAssertEqual(keyStore.key(for: provider.id), "legacy-secret")
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertNil(settingsStore.envelope.legacyKeyMigrationProviderID)
        XCTAssertEqual(
            settingsStore.envelope.aiProviders,
            [provider, BuiltInAIProvider.defaultConfiguration]
        )
        XCTAssertEqual(
            recorder.events,
            ["settings.load", "key.read", "key.legacy-read", "key.save", "settings.save"]
        )
    }

    func testReadingExistingScopedKeyClearsExactMarkerWithoutReadingLegacyGlobal() throws {
        let provider = makeProvider(id: providerID(1))
        let recorder = CoordinatorCallRecorder()
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(
                aiProviders: [provider],
                defaultAIProviderID: provider.id,
                legacyKeyMigrationProviderID: provider.id
            ),
            recorder: recorder
        )
        let keyStore = ThrowingAIApiKeyStore(
            keys: [provider.id: "scoped-secret"],
            legacyKey: "legacy-secret",
            recorder: recorder
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        let result = try coordinator.readAPIKey(for: provider.id)

        XCTAssertEqual(result, "scoped-secret")
        XCTAssertNil(settingsStore.envelope.legacyKeyMigrationProviderID)
        XCTAssertEqual(keyStore.key(for: provider.id), "scoped-secret")
        XCTAssertEqual(keyStore.legacyReadCallCount, 0)
        XCTAssertEqual(recorder.events, ["settings.load", "key.read", "settings.save"])
    }

    func testExistingScopedKeyMarkerClearFailurePreservesKeyAndRetryMarker() throws {
        let provider = makeProvider(id: providerID(1))
        let original = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id,
            legacyKeyMigrationProviderID: provider.id
        )
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original)
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(
            keys: [provider.id: "scoped-secret"],
            legacyKey: "legacy-secret"
        )
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(try coordinator.readAPIKey(for: provider.id)) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .settingsSave)
        }

        XCTAssertEqual(settingsStore.envelope, original)
        XCTAssertEqual(keyStore.key(for: provider.id), "scoped-secret")
        XCTAssertEqual(keyStore.legacyReadCallCount, 0)
        XCTAssertEqual(keyStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
    }

    func testMissingLegacyGlobalKeyPreservesMarkerForRetry() throws {
        let provider = makeProvider(id: providerID(1))
        let original = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id,
            legacyKeyMigrationProviderID: provider.id
        )
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original)
        let keyStore = ThrowingAIApiKeyStore()
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertNil(try coordinator.readAPIKey(for: provider.id))
        XCTAssertEqual(settingsStore.envelope, original)
        XCTAssertEqual(settingsStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.saveCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertEqual(keyStore.legacyReadCallCount, 1)
    }

    func testMarkerClearSaveFailureDeletesCopiedScopedKeyAndKeepsLegacyGlobal() throws {
        let provider = makeProvider(id: providerID(1))
        let recorder = CoordinatorCallRecorder()
        let original = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id,
            legacyKeyMigrationProviderID: provider.id
        )
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original, recorder: recorder)
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(legacyKey: "legacy-secret", recorder: recorder)
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(try coordinator.readAPIKey(for: provider.id)) { error in
            XCTAssertEqual(error as? CoordinatorStoreError, .settingsSave)
        }

        XCTAssertNil(keyStore.key(for: provider.id))
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertEqual(settingsStore.envelope, original)
        XCTAssertEqual(
            recorder.events,
            [
                "settings.load", "key.read", "key.legacy-read", "key.save", "settings.save",
                "key.delete"
            ]
        )
    }

    func testMarkerClearRollbackFailureSurfacesPrimaryAndRollbackErrors() throws {
        let provider = makeProvider(id: providerID(1))
        let original = AIProviderSettingsEnvelope(
            aiProviders: [provider],
            defaultAIProviderID: provider.id,
            legacyKeyMigrationProviderID: provider.id
        )
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: original)
        settingsStore.saveFailures[1] = .settingsSave
        let keyStore = ThrowingAIApiKeyStore(legacyKey: "legacy-secret")
        keyStore.deleteFailures[1] = .keyRollback
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)

        XCTAssertThrowsError(try coordinator.readAPIKey(for: provider.id)) { error in
            let transactionError = try? XCTUnwrap(error as? AIProviderConfigurationTransactionError)
            XCTAssertEqual(transactionError?.primaryError as? CoordinatorStoreError, .settingsSave)
            XCTAssertEqual(transactionError?.rollbackError as? CoordinatorStoreError, .keyRollback)
            XCTAssertFalse(error.localizedDescription.contains("legacy-secret"))
        }

        XCTAssertEqual(keyStore.key(for: provider.id), "legacy-secret")
        XCTAssertEqual(keyStore.legacyKey, "legacy-secret")
        XCTAssertEqual(settingsStore.envelope, original)
    }

    func testConcurrentMutationsAreSerializedWithoutLosingEitherProvider() throws {
        let firstProvider = makeProvider(id: providerID(1), displayName: "First")
        let secondProvider = makeProvider(id: providerID(2), displayName: "Second")
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: .rulesOnly)
        let keyStore = ThrowingAIApiKeyStore()
        let coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)
        let firstKeyWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstKeyWrite = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondLoadEntered = DispatchSemaphore(value: 0)
        let results = CoordinatorResultCollector()
        settingsStore.onLoad = { call in
            if call == 2 {
                secondLoadEntered.signal()
            }
        }
        keyStore.onSave = { _, _, call in
            if call == 1 {
                firstKeyWriteEntered.signal()
                _ = releaseFirstKeyWrite.wait(timeout: .now() + 2)
            }
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "Stacio.AIProviderConfigurationCoordinatorTests.serialized",
            attributes: .concurrent
        )

        group.enter()
        queue.async {
            defer { group.leave() }
            results.record(Result {
                try coordinator.saveProvider(firstProvider, apiKeyUpdate: .replace("first-secret"))
            })
        }
        XCTAssertEqual(firstKeyWriteEntered.wait(timeout: .now() + 1), .success)

        group.enter()
        queue.async {
            defer { group.leave() }
            secondStarted.signal()
            results.record(Result {
                try coordinator.saveProvider(secondProvider, apiKeyUpdate: .replace("second-secret"))
            })
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondLoadEntered.wait(timeout: .now() + 0.1), .timedOut)

        releaseFirstKeyWrite.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondLoadEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(results.successCount, 2)
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertEqual(
            settingsStore.envelope.aiProviders.map(\.id),
            [firstProvider.id, BuiltInAIProvider.mozheAPIID, secondProvider.id]
        )
        XCTAssertEqual(keyStore.key(for: firstProvider.id), "first-secret")
        XCTAssertEqual(keyStore.key(for: secondProvider.id), "second-secret")
    }

    func testSeparateCoordinatorsSharingStoresSerializeWithoutLostUpdate() throws {
        let firstProvider = makeProvider(id: providerID(1), displayName: "First")
        let secondProvider = makeProvider(id: providerID(2), displayName: "Second")
        let settingsStore = ThrowingAIProviderSettingsStore(envelope: .rulesOnly)
        let keyStore = ThrowingAIApiKeyStore()
        let firstCoordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)
        let secondCoordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)
        let firstLoadCaptured = DispatchSemaphore(value: 0)
        let secondLoadCaptured = DispatchSemaphore(value: 0)
        let firstSettingsSaved = DispatchSemaphore(value: 0)
        let results = CoordinatorResultCollector()
        settingsStore.onLoad = { call in
            if call == 1 {
                firstLoadCaptured.signal()
                _ = secondLoadCaptured.wait(timeout: .now() + 1)
            } else if call == 2 {
                secondLoadCaptured.signal()
            }
        }
        settingsStore.onSave = { envelope, _ in
            if envelope.aiProviders.map(\.id) == [firstProvider.id, BuiltInAIProvider.mozheAPIID] {
                firstSettingsSaved.signal()
            }
        }
        keyStore.onSave = { _, providerID, _ in
            if providerID == secondProvider.id {
                _ = firstSettingsSaved.wait(timeout: .now() + 1)
            }
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "Stacio.AIProviderConfigurationCoordinatorTests.shared-stores",
            attributes: .concurrent
        )

        group.enter()
        queue.async {
            defer { group.leave() }
            results.record(Result {
                try firstCoordinator.saveProvider(
                    firstProvider,
                    apiKeyUpdate: .replace("first-secret")
                )
            })
        }
        XCTAssertEqual(firstLoadCaptured.wait(timeout: .now() + 1), .success)

        group.enter()
        queue.async {
            defer { group.leave() }
            results.record(Result {
                try secondCoordinator.saveProvider(
                    secondProvider,
                    apiKeyUpdate: .replace("second-secret")
                )
            })
        }

        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(results.successCount, 2)
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertEqual(
            settingsStore.envelope.aiProviders.map(\.id),
            [firstProvider.id, BuiltInAIProvider.mozheAPIID, secondProvider.id]
        )
        XCTAssertEqual(keyStore.key(for: firstProvider.id), "first-secret")
        XCTAssertEqual(keyStore.key(for: secondProvider.id), "second-secret")
    }

    func testSynchronousSettingsSaveReentryDoesNotDeadlock() throws {
        let provider = makeProvider(id: providerID(1))
        let settingsStore = ThrowingAIProviderSettingsStore(
            envelope: .init(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let keyStore = ThrowingAIApiKeyStore(keys: [provider.id: "old-secret"])
        var coordinator: AIProviderConfigurationCoordinator!
        coordinator = makeCoordinator(settingsStore: settingsStore, keyStore: keyStore)
        let resultBox = CoordinatorReentryResultBox()
        settingsStore.onSave = { _, call in
            guard call == 1 else { return }
            resultBox.recordNested(Result { try coordinator.readAPIKey(for: provider.id) })
        }
        let completed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            resultBox.recordOuter(Result {
                try coordinator.saveProvider(provider, apiKeyUpdate: .replace("new-secret"))
            })
            completed.signal()
        }

        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            try resultBox.outerResult?.get().aiProviders,
            [provider, BuiltInAIProvider.defaultConfiguration]
        )
        XCTAssertEqual(try resultBox.nestedResult?.get(), "new-secret")
    }
}

private func makeCoordinator(
    settingsStore: ThrowingAIProviderSettingsStore,
    keyStore: ThrowingAIApiKeyStore
) -> AIProviderConfigurationCoordinator {
    AIProviderConfigurationCoordinator(settingsStore: settingsStore, keyStore: keyStore)
}

private func makeProvider(
    id: UUID,
    displayName: String = "Provider",
    modelID: String = "model"
) -> AIProviderConfiguration {
    AIProviderConfiguration(
        id: id,
        profile: .openAI,
        displayName: displayName,
        baseURL: "https://example.test/v1",
        models: [
            .init(
                id: modelID,
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: true
            )
        ],
        defaultModelID: modelID,
        compatibilityProtocol: .chatCompletions,
        maxRetryCount: 2,
        requestTimeoutSeconds: 30,
        userAgent: "Stacio",
        isEnabled: true,
        lastVerifiedAt: nil,
        lastModelSyncAt: nil
    )
}

private func providerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", value))!
}

private enum CoordinatorStoreError: Error, Equatable {
    case settingsSave
    case keyDelete
    case keyRollback
}

private final class CoordinatorCallRecorder {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private final class ThrowingAIProviderSettingsStore: AIProviderSettingsStoring {
    private let lock = NSLock()
    private let recorder: CoordinatorCallRecorder?
    private var storedEnvelope: AIProviderSettingsEnvelope
    private var loadCalls = 0
    private var saveCalls = 0

    var saveFailures: [Int: CoordinatorStoreError] = [:]
    var onLoad: ((Int) -> Void)?
    var onSave: ((AIProviderSettingsEnvelope, Int) -> Void)?

    init(
        envelope: AIProviderSettingsEnvelope,
        recorder: CoordinatorCallRecorder? = nil
    ) {
        storedEnvelope = envelope
        self.recorder = recorder
    }

    var envelope: AIProviderSettingsEnvelope {
        lock.lock()
        defer { lock.unlock() }
        return storedEnvelope
    }

    var saveCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCalls
    }

    func loadAIProviderSettings() throws -> AIProviderSettingsEnvelope {
        recorder?.record("settings.load")
        lock.lock()
        loadCalls += 1
        let call = loadCalls
        let result = storedEnvelope
        lock.unlock()
        onLoad?(call)
        return result
    }

    func saveAIProviderSettings(_ envelope: AIProviderSettingsEnvelope) throws {
        recorder?.record("settings.save")
        lock.lock()
        saveCalls += 1
        let call = saveCalls
        let failure = saveFailures[call]
        if failure == nil {
            storedEnvelope = envelope
        }
        lock.unlock()
        if let failure {
            throw failure
        }
        onSave?(envelope, call)
    }
}

private final class ThrowingAIApiKeyStore: AIApiKeyStoring, LegacyAIApiKeyReading {
    private let lock = NSLock()
    private let recorder: CoordinatorCallRecorder?
    private var scopedKeys: [UUID: String]
    private let storedLegacyKey: String?
    private var readCalls = 0
    private var saveCalls = 0
    private var deleteCalls = 0
    private var legacyReadCalls = 0

    var saveFailures: [Int: CoordinatorStoreError] = [:]
    var deleteFailures: [Int: CoordinatorStoreError] = [:]
    var onSave: ((String, UUID, Int) -> Void)?

    init(
        keys: [UUID: String] = [:],
        legacyKey: String? = nil,
        recorder: CoordinatorCallRecorder? = nil
    ) {
        scopedKeys = keys
        storedLegacyKey = legacyKey
        self.recorder = recorder
    }

    var legacyKey: String? {
        storedLegacyKey
    }

    var readCallCount: Int {
        locked { readCalls }
    }

    var saveCallCount: Int {
        locked { saveCalls }
    }

    var deleteCallCount: Int {
        locked { deleteCalls }
    }

    var legacyReadCallCount: Int {
        locked { legacyReadCalls }
    }

    var totalCallCount: Int {
        locked { readCalls + saveCalls + deleteCalls + legacyReadCalls }
    }

    func key(for providerID: UUID) -> String? {
        locked { scopedKeys[providerID] }
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        recorder?.record("key.save")
        lock.lock()
        saveCalls += 1
        let call = saveCalls
        let failure = saveFailures[call]
        if failure == nil {
            scopedKeys[providerID] = apiKey
        }
        lock.unlock()
        if let failure {
            throw failure
        }
        onSave?(apiKey, providerID, call)
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        recorder?.record("key.read")
        return locked {
            readCalls += 1
            return scopedKeys[providerID]
        }
    }

    func deleteAPIKey(for providerID: UUID) throws {
        recorder?.record("key.delete")
        try locked {
            deleteCalls += 1
            if let failure = deleteFailures[deleteCalls] {
                throw failure
            }
            scopedKeys.removeValue(forKey: providerID)
        }
    }

    func readLegacyGlobalAPIKey() throws -> String? {
        recorder?.record("key.legacy-read")
        return locked {
            legacyReadCalls += 1
            return storedLegacyKey
        }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class ScopedOnlyAIApiKeyStoreView: AIApiKeyStoring {
    private let base: AIApiKeyStoring

    init(base: AIApiKeyStoring) {
        self.base = base
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        try base.saveAPIKey(apiKey, for: providerID)
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        try base.readAPIKey(for: providerID)
    }

    func deleteAPIKey(for providerID: UUID) throws {
        try base.deleteAPIKey(for: providerID)
    }
}

private final class CoordinatorResultCollector {
    private let lock = NSLock()
    private var results: [Result<AIProviderSettingsEnvelope, Error>] = []

    var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.compactMap { try? $0.get() }.count
    }

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return results.compactMap {
            guard case let .failure(error) = $0 else { return nil }
            return error
        }
    }

    func record(_ result: Result<AIProviderSettingsEnvelope, Error>) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }
}

private final class CoordinatorReentryResultBox {
    private let lock = NSLock()
    private var storedOuterResult: Result<AIProviderSettingsEnvelope, Error>?
    private var storedNestedResult: Result<String?, Error>?

    var outerResult: Result<AIProviderSettingsEnvelope, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedOuterResult
    }

    var nestedResult: Result<String?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedNestedResult
    }

    func recordOuter(_ result: Result<AIProviderSettingsEnvelope, Error>) {
        lock.lock()
        storedOuterResult = result
        lock.unlock()
    }

    func recordNested(_ result: Result<String?, Error>) {
        lock.lock()
        storedNestedResult = result
        lock.unlock()
    }
}
