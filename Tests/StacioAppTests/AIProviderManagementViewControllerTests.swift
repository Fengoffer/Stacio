import AppKit
import Foundation
@testable import StacioApp
import XCTest

@MainActor
final class AIProviderManagementViewControllerTests: XCTestCase {
    func testSelectingProviderShowsOnlyItsFieldsAndModelsWhileMozheRecommendationStaysAccurate() {
        let fixture = makeFixture(defaultProviderID: providerBID)
        let controller = fixture.controller
        controller.loadView()

        controller.selectProvider(id: providerBID)

        XCTAssertEqual(controller.selectedProviderID, providerBID)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue, "https://b.example/v1")
        XCTAssertEqual(controller.visibleModelIDsForTesting, ["b-default", "b-disabled"])
        XCTAssertEqual(
            controller.visibleProviderIDsForTesting,
            [BuiltInAIProvider.mozheAPIID, providerAID, providerBID]
        )
        XCTAssertFalse(controller.visibleProviderIDsForTesting.contains(BuiltInAIProvider.stacioRulesID))

        let summaries = controller.providerSummariesForTesting
        XCTAssertEqual(summaries.first?.id, BuiltInAIProvider.mozheAPIID)
        XCTAssertEqual(summaries.first?.displayName, BuiltInAIProvider.mozheAPIDisplayName)
        XCTAssertEqual(summaries.first?.enabledModelCount, 0)
        XCTAssertEqual(summaries.first?.totalModelCount, 0)
        XCTAssertFalse(summaries.first?.isDefault ?? true)
        XCTAssertTrue(summaries.first?.isRecommended ?? false)
        XCTAssertTrue(controller.recommendedBadgeVisibleForTesting(providerID: BuiltInAIProvider.mozheAPIID))
        XCTAssertFalse(controller.recommendedBadgeVisibleForTesting(providerID: providerAID))
        XCTAssertEqual(summaries.first(where: { $0.id == providerBID })?.enabledModelCount, 1)
        XCTAssertEqual(summaries.first(where: { $0.id == providerBID })?.totalModelCount, 2)
        XCTAssertTrue(summaries.first(where: { $0.id == providerBID })?.isDefault ?? false)
        XCTAssertFalse(summaries.first(where: { $0.id == providerBID })?.statusText.isEmpty ?? true)
    }

    func testMozheIdentityAndBaseURLAreReadOnlyWhileURLRemainsSelectable() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: BuiltInAIProvider.mozheAPIID)

        let nameField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)
        )
        let baseURLField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)
        )

        XCTAssertEqual(nameField.stringValue, BuiltInAIProvider.mozheAPIDisplayName)
        XCTAssertFalse(nameField.isEditable)
        XCTAssertFalse(nameField.isSelectable)
        XCTAssertTrue(nameField.isEnabled)
        XCTAssertEqual(baseURLField.stringValue, BuiltInAIProvider.mozheAPIBaseURL)
        XCTAssertFalse(baseURLField.isEditable)
        XCTAssertTrue(baseURLField.isSelectable)
        XCTAssertTrue(baseURLField.isEnabled)
        XCTAssertFalse((view("Stacio.Settings.aiProviders.remove", in: controller.view) as? NSButton)?.isEnabled ?? true)

        nameField.stringValue = "Renamed mozhe"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: nameField)
        )
        baseURLField.stringValue = "https://redirect.example/v1"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: baseURLField)
        )
        controller.commitDisplayNameForTesting("Renamed mozhe")
        controller.commitBaseURLForTesting("https://redirect.example/v1")

        XCTAssertEqual(nameField.stringValue, BuiltInAIProvider.mozheAPIDisplayName)
        XCTAssertEqual(baseURLField.stringValue, BuiltInAIProvider.mozheAPIBaseURL)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        let managedProvider = try XCTUnwrap(
            controller.currentEnvelope.aiProviders.first { $0.id == BuiltInAIProvider.mozheAPIID }
        )
        XCTAssertEqual(managedProvider.displayName, BuiltInAIProvider.mozheAPIDisplayName)
        XCTAssertEqual(managedProvider.baseURL, BuiltInAIProvider.mozheAPIBaseURL)
    }

    func testMozheWebsiteButtonOpensExactURLOnceAndIsHiddenForOtherProviders() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: BuiltInAIProvider.mozheAPIID)

        XCTAssertTrue(controller.visitWebsiteButtonVisibleForTesting)
        let visitButton = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.visitWebsite", in: controller.view) as? NSButton
        )
        XCTAssertEqual(visitButton.title, "访问官网")
        XCTAssertNotNil(visitButton.image)
        visitButton.performClick(nil)

        XCTAssertEqual(
            fixture.urlOpener.openedURLs.map(\.absoluteString),
            [BuiltInAIProvider.mozheAPIWebsiteURL]
        )

        controller.selectProvider(id: providerAID)

        XCTAssertFalse(controller.visitWebsiteButtonVisibleForTesting)
        controller.openSelectedProviderWebsiteForTesting()
        XCTAssertEqual(fixture.urlOpener.openedURLs.count, 1)
    }

    func testProviderAndModelSearchPreserveUUIDSelectionAndProviderDraft() {
        let fixture = makeFixture(defaultProviderID: providerBID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerBID)

        controller.setProviderSearchForTesting("Alpha")

        XCTAssertEqual(controller.visibleProviderIDsForTesting, [providerAID])
        XCTAssertEqual(controller.selectedProviderID, providerBID)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue, "https://b.example/v1")

        controller.setProviderSearchForTesting("")
        controller.setModelSearchForTesting("disabled")

        XCTAssertEqual(controller.selectedProviderID, providerBID)
        XCTAssertEqual(controller.visibleModelIDsForTesting, ["b-disabled"])

        controller.setModelSearchForTesting("")
        XCTAssertEqual(controller.visibleModelIDsForTesting, ["b-default", "b-disabled"])
    }

    func testTypingDisplayNameThenEndingEditingPersistsRename() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let displayName = textField("Stacio.Settings.aiProviders.displayName", in: controller.view)!
        displayName.stringValue = "Typed Provider Name"

        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: displayName)
        )

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "Alpha Provider")

        controller.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: displayName)
        )

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "Typed Provider Name")
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
    }

    func testDefaultModelAutoEnablesModelAndOnlySavesSelectedProvider() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalA = fixture.store.envelope.aiProviders[0]
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerBID)

        controller.setDefaultModelForTesting("b-disabled")

        let savedB = fixture.store.provider(id: providerBID)
        XCTAssertEqual(savedB?.defaultModelID, "b-disabled")
        XCTAssertTrue(savedB?.models.first(where: { $0.id == "b-disabled" })?.isEnabled ?? false)
        XCTAssertEqual(fixture.store.provider(id: providerAID), originalA)
        XCTAssertEqual(fixture.coordinator.saveCalls.map(\.provider.id), [providerBID])
        XCTAssertEqual(fixture.coordinator.saveCalls.map(\.apiKeyUpdate), [.unchanged])
    }

    func testModelRowActionsCarryProviderScopedSelectionIdentity() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        let selections = controller.modelActionSelectionsForTesting(modelID: "a-default")

        XCTAssertEqual(
            selections,
            [
                AIModelSelection(providerID: providerAID, modelID: "a-default"),
                AIModelSelection(providerID: providerAID, modelID: "a-default")
            ]
        )
    }

    func testSelectingCatalogModelShowsSyncedCapabilitiesAndRestrictsReasoningOptions() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        var provider = try XCTUnwrap(fixture.store.provider(id: providerAID))
        let modelIndex = try XCTUnwrap(provider.models.firstIndex(where: { $0.id == "a-default" }))
        provider.models[modelIndex].capabilities = AIModelCapabilityConfiguration(
            contextWindowTokens: 131_072,
            contextCharacterLimit: 24_000,
            contextCharacterLimitSource: .catalog,
            supportedReasoningEfforts: [.minimal, .medium, .high],
            supportedReasoningEffortsSource: .catalog,
            reasoningEffort: .medium,
            reasoningEffortSource: .catalog
        )
        fixture.store.replace(provider)

        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-default")

        XCTAssertFalse(
            try XCTUnwrap(view("Stacio.Settings.aiProviders.modelCapabilities", in: controller.view)).isHidden
        )
        XCTAssertEqual(
            try XCTUnwrap(
                textField("Stacio.Settings.aiProviders.modelCapabilities.model", in: controller.view)
            ).stringValue,
            "a-default"
        )
        XCTAssertTrue(
            try XCTUnwrap(
                textField(
                    "Stacio.Settings.aiProviders.modelCapabilities.catalogContextWindow",
                    in: controller.view
                )
            ).stringValue.contains("131,072 tokens")
        )
        XCTAssertFalse(
            try XCTUnwrap(
                view(
                    "Stacio.Settings.aiProviders.modelCapabilities.catalogContextWindowRow",
                    in: controller.view
                )
            ).isHidden
        )
        XCTAssertTrue(
            try XCTUnwrap(
                view(
                    "Stacio.Settings.aiProviders.modelCapabilities.manualContextBudgetRow",
                    in: controller.view
                )
            ).isHidden
        )
        XCTAssertTrue(
            try XCTUnwrap(
                textField(
                    "Stacio.Settings.aiProviders.modelCapabilities.catalogReasoningEfforts",
                    in: controller.view
                )
            ).stringValue.contains("最低、中、高")
        )
        let reasoningPopup = try XCTUnwrap(
            view(
                "Stacio.Settings.aiProviders.modelCapabilities.reasoningEffort",
                in: controller.view
            ) as? NSPopUpButton
        )
        XCTAssertEqual(reasoningPopup.itemTitles, ["最低", "中", "高"])
        XCTAssertEqual(reasoningPopup.titleOfSelectedItem, "中")
        XCTAssertTrue(reasoningPopup.isEnabled)
    }

    func testSelectingModelWithoutCatalogCapabilitiesPersistsManualCapabilityControls() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")

        XCTAssertFalse(
            try XCTUnwrap(
                view(
                    "Stacio.Settings.aiProviders.modelCapabilities.manualContextBudgetRow",
                    in: controller.view
                )
            ).isHidden
        )
        XCTAssertTrue(
            try XCTUnwrap(
                view(
                    "Stacio.Settings.aiProviders.modelCapabilities.catalogContextWindowRow",
                    in: controller.view
                )
            ).isHidden
        )
        XCTAssertFalse(
            try XCTUnwrap(
                view(
                    "Stacio.Settings.aiProviders.modelCapabilities.manualReasoningEffortsRow",
                    in: controller.view
                )
            ).isHidden
        )

        let contextBudget = try XCTUnwrap(
            textField(
                "Stacio.Settings.aiProviders.modelCapabilities.manualContextBudget",
                in: controller.view
            )
        )
        contextBudget.stringValue = "131072"
        contextBudget.sendAction(contextBudget.action, to: contextBudget.target)

        let supportedEfforts = try XCTUnwrap(
            view(
                "Stacio.Settings.aiProviders.modelCapabilities.manualReasoningEfforts",
                in: controller.view
            ) as? NSSegmentedControl
        )
        supportedEfforts.setSelected(true, forSegment: 1)
        supportedEfforts.setSelected(true, forSegment: 3)
        supportedEfforts.sendAction(supportedEfforts.action, to: supportedEfforts.target)

        let reasoningPopup = try XCTUnwrap(
            view(
                "Stacio.Settings.aiProviders.modelCapabilities.reasoningEffort",
                in: controller.view
            ) as? NSPopUpButton
        )
        XCTAssertEqual(reasoningPopup.itemTitles, ["低", "高"])
        reasoningPopup.selectItem(withTitle: "高")
        XCTAssertEqual(reasoningPopup.titleOfSelectedItem, "高")
        reasoningPopup.sendAction(reasoningPopup.action, to: reasoningPopup.target)

        let savedCapabilities = try XCTUnwrap(
            fixture.store.provider(id: providerAID)?.models.first(where: { $0.id == "a-old" })?.capabilities
        )
        XCTAssertEqual(savedCapabilities.contextCharacterLimit, 131_072)
        XCTAssertEqual(savedCapabilities.contextCharacterLimitSource, .manual)
        XCTAssertEqual(savedCapabilities.supportedReasoningEfforts, [.low, .high])
        XCTAssertEqual(savedCapabilities.supportedReasoningEffortsSource, .manual)
        XCTAssertEqual(savedCapabilities.reasoningEffort, .high)
        XCTAssertEqual(savedCapabilities.reasoningEffortSource, .manual)
    }

    func testSetDefaultProviderUsesSelectedProviderIDWithoutSavingOtherProviders() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        let originalProviders = controller.currentEnvelope.aiProviders
        controller.selectProvider(id: providerBID)

        controller.setDefaultProviderForTesting()

        XCTAssertEqual(fixture.coordinator.defaultProviderIDs, [providerBID])
        XCTAssertEqual(fixture.store.envelope.defaultAIProviderID, providerBID)
        XCTAssertEqual(fixture.store.envelope.aiProviders, originalProviders)
        XCTAssertTrue(controller.providerSummariesForTesting.first(where: { $0.id == providerBID })?.isDefault ?? false)
    }

    func testDefaultProviderFailureIsVisibleWhileMozheIsSelected() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalEnvelope = fixture.store.envelope
        let controller = fixture.controller
        controller.loadView()
        let originalControllerEnvelope = controller.currentEnvelope
        controller.selectProvider(id: BuiltInAIProvider.mozheAPIID)
        fixture.coordinator.defaultFailure = TestFailure.message(
            "default mutation failed Authorization: Bearer unrelated-token token=other-secret"
        )

        controller.setDefaultProviderForTesting()

        XCTAssertEqual(fixture.coordinator.defaultProviderIDs, [BuiltInAIProvider.mozheAPIID])
        XCTAssertEqual(fixture.store.envelope, originalEnvelope)
        XCTAssertEqual(controller.currentEnvelope, originalControllerEnvelope)
        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertTrue(status?.contains("default mutation failed") ?? false)
        assertNoProviderManagerSecrets(status)
    }

    func testSuccessfulMutationClearsPreviousMutationFailure() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.coordinator.saveFailure = TestFailure.message("stale mutation failure")
        controller.commitDisplayNameForTesting("Unsaved Name")
        XCTAssertTrue(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?
                .stringValue.contains("stale mutation failure") ?? false
        )

        fixture.coordinator.saveFailure = nil
        controller.setDefaultProviderForTesting()

        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertFalse(status?.contains("stale mutation failure") ?? true)
        XCTAssertFalse(status?.contains("请检查") ?? true)
    }

    func testMaskedOrEmptyAPIKeyDoesNotOverwriteStoredCredential() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "old-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        XCTAssertEqual(textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue, AIProviderManagementViewController.maskedAPIKeyPlaceholder)

        controller.commitAPIKeyForTesting("")
        controller.commitAPIKeyForTesting(AIProviderManagementViewController.maskedAPIKeyPlaceholder)

        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "old-secret")
    }

    func testRefreshingModelsPersistsPendingAPIKeyBeforeReadingKeychain() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: BuiltInAIProvider.mozheAPIID)
        fixture.catalog.result = .success(["new-model"])
        let apiKeyField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)
        )
        let revealButton = try XCTUnwrap(
            view(
                "Stacio.Settings.aiProviders.toggleAPIKeyVisibility",
                in: controller.view
            ) as? NSButton
        )
        apiKeyField.stringValue = "newly-typed-secret"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: apiKeyField)
        )

        controller.refreshModelsForTesting()

        XCTAssertEqual(
            fixture.coordinator.keys[BuiltInAIProvider.mozheAPIID],
            "newly-typed-secret"
        )
        XCTAssertEqual(
            fixture.coordinator.saveCalls.first?.apiKeyUpdate,
            .replace("newly-typed-secret")
        )
        XCTAssertEqual(
            apiKeyField.stringValue,
            AIProviderManagementViewController.maskedAPIKeyPlaceholder
        )
        XCTAssertTrue(revealButton.isEnabled)
        XCTAssertEqual(fixture.background.pendingCount, 1)

        fixture.background.runNext()

        XCTAssertEqual(fixture.catalog.calls.first?.apiKey, "newly-typed-secret")
        XCTAssertEqual(
            fixture.catalog.calls.first?.provider.id,
            BuiltInAIProvider.mozheAPIID
        )
        XCTAssertEqual(
            controller.catalogStateForTesting(providerID: BuiltInAIProvider.mozheAPIID),
            .loaded
        )
    }

    func testStoredAPIKeyIsHiddenByDefaultAndCanBeTemporarilyRevealed() throws {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "stored-secret"]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let secureField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)
        )
        let revealButton = try XCTUnwrap(
            view(
                "Stacio.Settings.aiProviders.toggleAPIKeyVisibility",
                in: controller.view
            ) as? NSButton
        )

        XCTAssertFalse(controller.isAPIKeyRevealedForTesting)
        XCTAssertEqual(
            secureField.stringValue,
            AIProviderManagementViewController.maskedAPIKeyPlaceholder
        )
        XCTAssertTrue(revealButton.isEnabled)
        XCTAssertEqual(revealButton.toolTip, "显示 API Key")

        controller.toggleAPIKeyVisibilityForTesting()

        let revealedField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.apiKey.revealed", in: controller.view)
        )
        XCTAssertTrue(controller.isAPIKeyRevealedForTesting)
        XCTAssertTrue(secureField.isHidden)
        XCTAssertFalse(revealedField.isHidden)
        XCTAssertEqual(revealedField.stringValue, "stored-secret")
        XCTAssertEqual(revealButton.toolTip, "隐藏 API Key")

        controller.toggleAPIKeyVisibilityForTesting()

        XCTAssertFalse(controller.isAPIKeyRevealedForTesting)
        XCTAssertFalse(secureField.isHidden)
        XCTAssertTrue(revealedField.isHidden)
        XCTAssertEqual(revealedField.stringValue, "")
        XCTAssertEqual(
            secureField.stringValue,
            AIProviderManagementViewController.maskedAPIKeyPlaceholder
        )
        XCTAssertEqual(revealButton.toolTip, "显示 API Key")
    }

    func testReplacingAndExplicitlyRemovingAPIKeyUseScopedUpdatesAndClearTimestamps() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "old-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        controller.commitAPIKeyForTesting("new-secret")

        XCTAssertEqual(fixture.coordinator.saveCalls.last?.apiKeyUpdate, .replace("new-secret"))
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastVerifiedAt)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastModelSyncAt)
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "new-secret")

        controller.removeAPIKeyForTesting()

        XCTAssertEqual(fixture.coordinator.saveCalls.last?.apiKeyUpdate, .remove)
        XCTAssertNil(fixture.coordinator.keys[providerAID])
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue, "")
    }

    func testAPIKeySaveFailureReflectsCoordinatorRollbackCredentialState() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "old-secret"])
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.coordinator.saveFailure = TestFailure.message("settings save failed")

        controller.removeAPIKeyForTesting()

        XCTAssertEqual(fixture.store.provider(id: providerAID), originalProvider)
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "old-secret")
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue, AIProviderManagementViewController.maskedAPIKeyPlaceholder)
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.catalogStatus", in: controller.view)?.stringValue.contains("已同步") ?? false)
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue.contains("settings save failed") ?? false)
    }

    func testAPIKeyReplaceSaveFailureRedactsAttemptedKeyAndKeepsPersistedTimestamps() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let attemptedKey = "provider-key-9f8e7d"
        fixture.coordinator.saveFailure = TestFailure.message("replace save failed: \(attemptedKey)")

        controller.commitAPIKeyForTesting(attemptedKey)

        XCTAssertEqual(fixture.store.provider(id: providerAID), originalProvider)
        XCTAssertNil(fixture.coordinator.keys[providerAID])
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue, "")
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.catalogStatus", in: controller.view)?.stringValue.contains("已同步") ?? false)
        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertTrue(status?.contains("replace save failed") ?? false)
        XCTAssertFalse(status?.contains(attemptedKey) ?? true)
        XCTAssertTrue(status?.contains("[已隐藏凭据]") ?? false)
    }

    func testDisplayNameSaveFailureRestoresPersistedNameAndShowsError() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.coordinator.saveFailure = TestFailure.message("name save failed")

        controller.commitDisplayNameForTesting("Unsaved Provider")

        XCTAssertEqual(fixture.store.provider(id: providerAID), originalProvider)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue, "Alpha Provider")
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue.contains("name save failed") ?? false)
    }

    func testBaseURLSaveFailureRestoresPersistedFieldTimestampsAndShowsError() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.coordinator.saveFailure = TestFailure.message("base URL save failed")

        controller.commitBaseURLForTesting("https://unsaved.example/v1")

        XCTAssertEqual(fixture.store.provider(id: providerAID), originalProvider)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue, "https://a.example/v1")
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.catalogStatus", in: controller.view)?.stringValue.contains("已同步") ?? false)
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue.contains("base URL save failed") ?? false)
    }

    func testNetworkSaveFailureRestoresPersistedFieldsTimestampsAndShowsError() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.coordinator.saveFailure = TestFailure.message("network save failed")

        controller.commitNetworkSettingsForTesting(
            maxRetryCount: 4,
            requestTimeoutSeconds: 90,
            userAgent: "Unsaved-Agent/4.0"
        )

        XCTAssertEqual(fixture.store.provider(id: providerAID), originalProvider)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.userAgent", in: controller.view)?.stringValue, "Stacio")
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.catalogStatus", in: controller.view)?.stringValue.contains("已同步") ?? false)
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue.contains("network save failed") ?? false)
    }

    func testDeleteUsesDeterministicDefaultFallbackAndSelectsIt() {
        let fixture = makeFixture(defaultProviderID: providerBID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerBID)

        controller.deleteSelectedProviderForTesting()

        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerBID])
        XCTAssertNil(fixture.store.provider(id: providerBID))
        XCTAssertEqual(fixture.store.envelope.defaultAIProviderID, providerAID)
        XCTAssertEqual(controller.selectedProviderID, providerAID)
    }

    func testMozheCannotBeDeleted() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: BuiltInAIProvider.mozheAPIID)

        controller.deleteSelectedProviderForTesting()

        XCTAssertTrue(fixture.coordinator.deletedProviderIDs.isEmpty)
        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.mozheAPIID)
        XCTAssertTrue(controller.visibleProviderIDsForTesting.contains(BuiltInAIProvider.mozheAPIID))
        XCTAssertFalse(controller.visibleProviderIDsForTesting.contains(BuiltInAIProvider.stacioRulesID))
        XCTAssertEqual(fixture.store.envelope.aiProviders.count, 2)
    }

    func testDeleteConfirmationTargetsProviderThatRequestedConfirmation() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        var confirmedDeletion: (() -> Void)?
        controller.onDeleteProviderConfirmationRequested = { provider, deletion in
            XCTAssertEqual(provider.id, providerAID)
            confirmedDeletion = deletion
        }

        (view("Stacio.Settings.aiProviders.remove", in: controller.view) as? NSButton)?.performClick(nil)
        controller.selectProvider(id: providerBID)
        confirmedDeletion?()

        XCTAssertNil(fixture.store.provider(id: providerAID))
        XCTAssertNotNil(fixture.store.provider(id: providerBID))
        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerAID])
    }

    func testDelayedDeleteFailureRemainsVisibleAfterSelectionChangesAndPreservesProvider() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "persisted-provider-key"]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        var confirmedDeletion: (() -> Void)?
        controller.onDeleteProviderConfirmationRequested = { provider, deletion in
            XCTAssertEqual(provider.id, providerAID)
            confirmedDeletion = deletion
        }
        (view("Stacio.Settings.aiProviders.remove", in: controller.view) as? NSButton)?
            .performClick(nil)
        controller.selectProvider(id: providerBID)
        fixture.coordinator.deleteFailure = TestFailure.message(
            "delete failed Authorization: Bearer unrelated-token token=other-secret"
        )

        confirmedDeletion?()

        XCTAssertEqual(controller.selectedProviderID, providerBID)
        XCTAssertNotNil(controller.currentEnvelope.aiProviders.first { $0.id == providerAID })
        XCTAssertNotNil(fixture.store.provider(id: providerAID))
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "persisted-provider-key")
        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerAID])
        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertTrue(status?.contains("delete failed") ?? false)
        assertNoProviderManagerSecrets(status)
    }

    func testReloadFromStoreUsesFreshEnvelopeAndLoadsSelectedProviderCredentialState() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://external-update.example/v1"
        fixture.store.replace(externallyUpdated)
        fixture.coordinator.keys[providerAID] = "external-secret"

        try controller.reloadFromStore(selecting: providerAID)

        XCTAssertEqual(controller.selectedProviderID, providerAID)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue, "https://external-update.example/v1")
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue, AIProviderManagementViewController.maskedAPIKeyPlaceholder)
    }

    func testReloadFromStoreClearsMutationFailure() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.coordinator.saveFailure = TestFailure.message("mutation failure before reload")
        controller.commitDisplayNameForTesting("Unsaved Name")
        XCTAssertTrue(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?
                .stringValue.contains("mutation failure before reload") ?? false
        )

        fixture.coordinator.saveFailure = nil
        try controller.reloadFromStore(selecting: providerAID)

        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertFalse(status?.contains("mutation failure before reload") ?? true)
        XCTAssertFalse(status?.contains("请检查") ?? true)
    }

    func testReloadFromStoreInvalidatesCatalogRequestCapturedBeforeExternalChange() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["stale-external-result"])

        controller.refreshModelsForTesting()
        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://externally-edited.example/v1"
        fixture.store.replace(externallyUpdated)
        try controller.reloadFromStore(selecting: providerAID)
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.baseURL, "https://externally-edited.example/v1")
        XCTAssertFalse(fixture.store.provider(id: providerAID)?.models.contains(where: { $0.id == "stale-external-result" }) ?? true)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }

    func testReloadFailureInvalidatesRuntimeStateDiscardsDraftAndRejectsInflightResults() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        let originalControllerEnvelope = controller.currentEnvelope
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-merge-after-reload-failure"])
        fixture.connection.result = .success(.init(message: "must-not-verify-after-reload-failure"))
        controller.refreshModelsForTesting()
        controller.testConnectionForTesting()
        let displayName = textField("Stacio.Settings.aiProviders.displayName", in: controller.view)!
        displayName.stringValue = "Unsaved Name"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: displayName)
        )
        fixture.store.loadFailure = TestFailure.message("reload failed")

        XCTAssertThrowsError(try controller.reloadFromStore(selecting: providerAID))

        XCTAssertEqual(controller.currentEnvelope, originalControllerEnvelope)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue, "Alpha Provider")
        XCTAssertTrue(textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue.contains("reload failed") ?? false)
        XCTAssertEqual(controller.catalogStateForTesting(providerID: providerAID), .idle)

        fixture.background.runNext()
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), originalProvider)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }

    func testViewingProviderBDoesNotCancelProviderARefreshAndResultWritesProviderA() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["a-default", "a-new"])

        controller.refreshModelsForTesting()
        controller.selectProvider(id: providerBID)
        fixture.background.runNext()

        XCTAssertEqual(controller.selectedProviderID, providerBID)
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.models.map(\.id), ["a-default", "a-old", "a-new"])
        XCTAssertEqual(fixture.store.provider(id: providerBID)?.models.map(\.id), ["b-default", "b-disabled"])
        XCTAssertEqual(fixture.catalog.calls.first?.provider.id, providerAID)
        XCTAssertEqual(fixture.catalog.calls.first?.apiKey, "a-secret")
        XCTAssertEqual(controller.catalogStateForTesting(providerID: providerAID), .loaded)
    }

    func testCatalogResultAfterBaseURLEditIsIgnored() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-merge"])

        controller.refreshModelsForTesting()
        controller.commitBaseURLForTesting("https://edited.example/v1")
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.baseURL, "https://edited.example/v1")
        XCTAssertFalse(fixture.store.provider(id: providerAID)?.models.contains(where: { $0.id == "must-not-merge" }) ?? true)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastVerifiedAt)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastModelSyncAt)
    }

    func testTypingBaseURLRejectsInflightCatalogAndConnectionBeforeCommit() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let original = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-merge-from-old-url"])
        fixture.connection.result = .success(.init(message: "must-not-verify-old-url"))

        controller.refreshModelsForTesting()
        controller.testConnectionForTesting()
        let baseURL = textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)!
        baseURL.stringValue = "https://typed.example/v1"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: baseURL)
        )
        fixture.background.runNext()
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)

        controller.commitBaseURLForTesting(baseURL.stringValue)

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.baseURL, "https://typed.example/v1")
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastVerifiedAt)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastModelSyncAt)
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
    }

    func testTypingUserAgentRejectsInflightCatalogBeforeNetworkCommit() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let original = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-merge-from-old-user-agent"])

        controller.refreshModelsForTesting()
        let userAgent = textField("Stacio.Settings.aiProviders.userAgent", in: controller.view)!
        userAgent.stringValue = "Typed-Agent/2.0"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: userAgent)
        )
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)

        controller.commitNetworkSettingsForTesting(
            maxRetryCount: 1,
            requestTimeoutSeconds: 45,
            userAgent: userAgent.stringValue
        )

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.userAgent, "Typed-Agent/2.0")
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastVerifiedAt)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastModelSyncAt)
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
    }

    func testTypingInvalidRetryOrTimeoutTextStillRejectsInflightCatalog() {
        for (label, typedValue) in [("重试次数", ""), ("请求超时秒数", "not-a-number")] {
            let fixture = makeFixture(defaultProviderID: providerAID)
            let original = fixture.store.provider(id: providerAID)
            let controller = fixture.controller
            controller.loadView()
            controller.selectProvider(id: providerAID)
            fixture.catalog.result = .success(["must-not-merge-for-\(label)"])

            controller.refreshModelsForTesting()
            let field = textField(accessibilityLabel: label, in: controller.view)!
            field.stringValue = typedValue
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field)
            )
            fixture.background.runNext()

            XCTAssertEqual(fixture.store.provider(id: providerAID), original, label)
            XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty, label)
        }
    }

    func testTypingAPIKeyRejectsInflightRequestsBeforeReplaceCommit() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "old-secret"])
        let original = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-merge-from-old-key"])
        fixture.connection.result = .success(.init(message: "must-not-verify-old-key"))

        controller.refreshModelsForTesting()
        controller.testConnectionForTesting()
        let apiKey = textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)!
        apiKey.stringValue = "new-secret"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: apiKey)
        )
        fixture.background.runNext()
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "old-secret")
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)

        controller.commitAPIKeyForTesting(apiKey.stringValue)

        XCTAssertEqual(fixture.coordinator.keys[providerAID], "new-secret")
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastVerifiedAt)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.lastModelSyncAt)
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
    }

    func testCatalogResultAfterDeleteIsIgnored() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-return"])

        controller.refreshModelsForTesting()
        controller.deleteSelectedProviderForTesting()
        fixture.background.runNext()

        XCTAssertNil(fixture.store.provider(id: providerAID))
        XCTAssertFalse(fixture.coordinator.saveCalls.contains(where: { $0.provider.models.contains(where: { $0.id == "must-not-return" }) }))
    }

    func testOnlyNewestCatalogRequestCanMerge() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        controller.refreshModelsForTesting()
        controller.commitBaseURLForTesting("https://newest-request.example/v1")
        controller.refreshModelsForTesting()

        fixture.catalog.result = .success(["newest"])
        fixture.background.run(at: 1)
        fixture.catalog.result = .success(["stale"])
        fixture.background.run(at: 0)

        let modelIDs = fixture.store.provider(id: providerAID)?.models.map(\.id) ?? []
        XCTAssertTrue(modelIDs.contains("newest"))
        XCTAssertFalse(modelIDs.contains("stale"))
        XCTAssertEqual(fixture.coordinator.saveCalls.filter { $0.provider.id == providerAID }.count, 2)
    }

    func testCatalogMergePreservesManualModelsMarksStaleModelsAndManualAddIsScoped() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        var providerA = fixture.store.provider(id: providerAID)!
        providerA.models = [
            model("a-default", enabled: true, returned: true),
            model("manual-old", enabled: true, manual: true, returned: false),
            model("catalog-old", enabled: false, returned: true)
        ]
        providerA.defaultModelID = "a-default"
        fixture.store.replace(providerA)
        let originalB = fixture.store.provider(id: providerBID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["a-default", "catalog-new"])

        controller.refreshModelsForTesting()
        fixture.background.runNext()
        controller.addManualModelForTesting("  manual-new  ")

        let saved = fixture.store.provider(id: providerAID)!
        XCTAssertEqual(saved.models.map(\.id), ["a-default", "manual-old", "catalog-old", "catalog-new", "manual-new"])
        XCTAssertTrue(saved.models.first(where: { $0.id == "manual-old" })?.isManual ?? false)
        XCTAssertFalse(saved.models.first(where: { $0.id == "catalog-old" })?.wasReturnedByLatestCatalog ?? true)
        XCTAssertTrue(saved.models.first(where: { $0.id == "manual-new" })?.isManual ?? false)
        XCTAssertTrue(saved.models.first(where: { $0.id == "manual-new" })?.isEnabled ?? false)
        XCTAssertEqual(controller.modelStatusTextForTesting(modelID: "catalog-old"), "目录中已移除")
        XCTAssertEqual(controller.modelStatusTextForTesting(modelID: "manual-new"), "手动添加")
        XCTAssertEqual(fixture.store.provider(id: providerBID), originalB)
    }

    func testCatalogFailurePreservesProviderFieldsAndRedactsScopedKey() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "opaque-secret"])
        let original = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .failure(TestFailure.message("upstream echoed opaque-secret"))

        controller.refreshModelsForTesting()
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        guard case let .failed(message) = controller.catalogStateForTesting(providerID: providerAID) else {
            return XCTFail("expected failed catalog state")
        }
        XCTAssertFalse(message.contains("opaque-secret"))
        XCTAssertTrue(message.contains("请检查"))
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }

    func testCatalogAndConnectionFailuresRedactUnrelatedAuthorizationSecrets() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "different-scoped-key"]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let secretDiagnostic = "Authorization: Bearer unrelated-token token=other-secret"

        fixture.catalog.result = .failure(TestFailure.message(secretDiagnostic))
        controller.refreshModelsForTesting()
        fixture.background.runNext()

        assertNoProviderManagerSecrets(
            textField("Stacio.Settings.aiProviders.catalogStatus", in: controller.view)?.stringValue
        )

        fixture.connection.result = .failure(TestFailure.message(secretDiagnostic))
        controller.testConnectionForTesting()
        fixture.background.runNext()

        assertNoProviderManagerSecrets(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        )
    }

    func testConnectionSuccessMessageIsRedactedWithoutFailureHint() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(
            .init(message: "Connected Authorization: Bearer leaked-token")
        )

        controller.testConnectionForTesting()
        fixture.background.runNext()

        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertFalse(status?.contains("leaked-token") ?? true)
        XCTAssertFalse(status?.contains("请检查") ?? true)
        XCTAssertTrue(status?.contains("[已隐藏凭据]") ?? false)
    }

    func testNilKeyLoadSaveAndReadErrorsUseUnifiedRedaction() {
        let secretDiagnostic = "Authorization: Bearer unrelated-token token=other-secret"

        let loadFixture = makeFixture(defaultProviderID: providerAID)
        loadFixture.store.loadFailure = TestFailure.message(secretDiagnostic)
        loadFixture.controller.loadView()
        assertNoProviderManagerSecrets(
            textField("Stacio.Settings.aiProviders.status", in: loadFixture.controller.view)?.stringValue
        )

        let saveFixture = makeFixture(defaultProviderID: providerAID)
        saveFixture.controller.loadView()
        saveFixture.controller.selectProvider(id: providerAID)
        saveFixture.coordinator.saveFailure = TestFailure.message(secretDiagnostic)
        saveFixture.controller.commitDisplayNameForTesting("Failed Rename")
        assertNoProviderManagerSecrets(
            textField("Stacio.Settings.aiProviders.status", in: saveFixture.controller.view)?.stringValue
        )

        let readFixture = makeFixture(defaultProviderID: providerAID)
        readFixture.coordinator.readKeyFailure = TestFailure.message(secretDiagnostic)
        readFixture.controller.loadView()
        readFixture.controller.selectProvider(id: providerAID)
        assertNoProviderManagerSecrets(
            textField("Stacio.Settings.aiProviders.status", in: readFixture.controller.view)?.stringValue
        )
    }

    func testConnectionTestUsesSelectedDefaultModelAndKeyWithoutTouchingCatalog() {
        let verifiedAt = Date(timeIntervalSince1970: 2_000)
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"],
            now: verifiedAt
        )
        let originalSync = fixture.store.provider(id: providerAID)?.lastModelSyncAt
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(.init(message: "连接成功"))

        controller.testConnectionForTesting()
        fixture.background.runNext()

        XCTAssertEqual(fixture.connection.calls.first?.provider.id, providerAID)
        XCTAssertEqual(fixture.connection.calls.first?.modelID, "a-default")
        XCTAssertEqual(fixture.connection.calls.first?.apiKey, "a-secret")
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.lastVerifiedAt, verifiedAt)
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.lastModelSyncAt, originalSync)
        XCTAssertTrue(fixture.catalog.calls.isEmpty)
    }

    func testCatalogLoadingDisablesOnlyRefreshRejectsRepeatAndReenablesAfterSuccess() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["a-default"])
        let refresh = view("Stacio.Settings.aiProviders.refreshModels", in: controller.view) as! NSButton
        let testConnection = view("Stacio.Settings.aiProviders.testConnection", in: controller.view) as! NSButton

        controller.refreshModelsForTesting()

        XCTAssertFalse(refresh.isEnabled)
        XCTAssertTrue(testConnection.isEnabled)
        XCTAssertEqual(fixture.background.pendingCount, 1)

        controller.refreshModelsForTesting()
        XCTAssertEqual(fixture.background.pendingCount, 1)

        fixture.background.runNext()

        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(testConnection.isEnabled)
        XCTAssertEqual(fixture.catalog.calls.count, 1)
    }

    func testConnectionTestingDisablesOnlyTestRejectsRepeatAndReenablesAfterFailure() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .failure(TestFailure.message("connection failed"))
        let refresh = view("Stacio.Settings.aiProviders.refreshModels", in: controller.view) as! NSButton
        let testConnection = view("Stacio.Settings.aiProviders.testConnection", in: controller.view) as! NSButton

        controller.testConnectionForTesting()

        XCTAssertTrue(refresh.isEnabled)
        XCTAssertFalse(testConnection.isEnabled)
        XCTAssertEqual(fixture.background.pendingCount, 1)

        controller.testConnectionForTesting()
        XCTAssertEqual(fixture.background.pendingCount, 1)

        fixture.background.runNext()

        XCTAssertTrue(refresh.isEnabled)
        XCTAssertTrue(testConnection.isEnabled)
        XCTAssertEqual(fixture.connection.calls.count, 1)
    }

    func testLongModelIDUsesTailTruncationAndTooltipWithoutBreakingSevenHundredPointLayout() {
        let longID = "provider/region/team/very-long-model-identifier-with-a-suffix-that-must-remain-inspectable"
        let fixture = makeFixture(defaultProviderID: providerAID)
        var providerA = fixture.store.provider(id: providerAID)!
        providerA.models.append(model(longID, enabled: false, returned: true))
        fixture.store.replace(providerA)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        controller.selectProvider(id: providerAID)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()

        let presentation = controller.modelPresentationForTesting(modelID: longID)
        XCTAssertEqual(presentation?.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(presentation?.toolTip, longID)

        let split = view("Stacio.Settings.aiProviders.split", in: controller.view) as? NSSplitView
        XCTAssertEqual(split?.subviews.count, 2)
        XCTAssertTrue((230...260).contains(split?.subviews.first?.frame.width ?? 0))
        XCTAssertGreaterThanOrEqual(split?.subviews.last?.frame.width ?? 0, 440)

        for identifier in [
            "Stacio.Settings.aiProviders.testConnection",
            "Stacio.Settings.aiProviders.refreshModels",
            "Stacio.Settings.aiProviders.toggleAPIKeyVisibility",
            "Stacio.Settings.aiProviders.removeAPIKey",
            "Stacio.Settings.aiProviders.modelCapabilities",
            "Stacio.Settings.aiProviders.modelCapabilities.model",
            "Stacio.Settings.aiProviders.modelCapabilities.catalogContextWindow",
            "Stacio.Settings.aiProviders.modelCapabilities.manualContextBudget",
            "Stacio.Settings.aiProviders.modelCapabilities.catalogReasoningEfforts",
            "Stacio.Settings.aiProviders.modelCapabilities.manualReasoningEfforts",
            "Stacio.Settings.aiProviders.modelCapabilities.reasoningEffort"
        ] {
            guard let control = view(identifier, in: controller.view) else {
                return XCTFail("missing control \(identifier)")
            }
            let frame = control.convert(control.bounds, to: controller.view)
            XCTAssertGreaterThanOrEqual(frame.minX, controller.view.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, controller.view.bounds.maxX + 0.5)
        }
    }

    func testBasicAndAdvancedFormRowsStayLeftAlignedAcrossWindowWidths() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: BuiltInAIProvider.mozheAPIID)
        let advancedDisclosure = try XCTUnwrap(
            view(
                "Stacio.Settings.aiProviders.advancedDisclosure",
                in: controller.view
            ) as? NSButton
        )
        advancedDisclosure.performClick(nil)

        let content = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailContent", in: controller.view)
        )
        let basicTitle = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.basicSection", in: controller.view) as? NSTextField
        )
        let rowIdentifiers = [
            "Stacio.Settings.aiProviders.form.displayName",
            "Stacio.Settings.aiProviders.form.baseURL",
            "Stacio.Settings.aiProviders.form.apiKey",
            "Stacio.Settings.aiProviders.form.compatibilityProtocol",
            "Stacio.Settings.aiProviders.form.retryCount",
            "Stacio.Settings.aiProviders.form.requestTimeout",
            "Stacio.Settings.aiProviders.form.userAgent"
        ]

        XCTAssertEqual(basicTitle.alignment, .left)
        XCTAssertEqual(advancedDisclosure.alignment, .left)

        var expectedControlMinX: CGFloat?
        for width in [700.0, 1_100.0] {
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 760)
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()

            let contentBounds = content.bounds
            for identifier in rowIdentifiers {
                let row = try XCTUnwrap(
                    view(identifier, in: controller.view) as? NSStackView,
                    identifier
                )
                let label = try XCTUnwrap(
                    view("\(identifier).label", in: controller.view) as? NSTextField,
                    "\(identifier).label"
                )
                let control = try XCTUnwrap(row.arrangedSubviews.last, identifier)
                let rowFrame = row.convert(row.bounds, to: content)
                let labelFrame = label.convert(label.bounds, to: content)
                let controlFrame = control.convert(control.bounds, to: content)

                XCTAssertEqual(rowFrame.minX, contentBounds.minX, accuracy: 0.5, identifier)
                XCTAssertEqual(rowFrame.maxX, contentBounds.maxX, accuracy: 0.5, identifier)
                XCTAssertEqual(labelFrame.minX, contentBounds.minX - 2, accuracy: 0.5, identifier)
                XCTAssertEqual(label.alignment, .left, identifier)
                if let expectedControlMinX {
                    XCTAssertEqual(
                        controlFrame.minX,
                        expectedControlMinX,
                        accuracy: 0.5,
                        identifier
                    )
                } else {
                    expectedControlMinX = controlFrame.minX
                }
                XCTAssertGreaterThan(controlFrame.minX, labelFrame.maxX, identifier)
                XCTAssertLessThanOrEqual(
                    controlFrame.maxX,
                    contentBounds.maxX + 0.5,
                    identifier
                )
            }
        }
    }

    func testTallLayoutKeepsProviderDetailContentTopAlignedAtIntrinsicHeight() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 980)
        controller.selectProvider(id: providerAID)
        controller.view.layoutSubtreeIfNeeded()

        let detailScroll = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailScroll", in: controller.view) as? NSScrollView
        )
        let document = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailDocument", in: controller.view)
        )
        let content = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailContent", in: controller.view)
        )
        let basicSection = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.basicSection", in: controller.view)
        )
        let modelSection = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelSection", in: controller.view)
        )
        let visibleFrame = detailScroll.contentView.convert(
            detailScroll.contentView.bounds,
            to: detailScroll
        )
        let documentFrame = document.convert(document.bounds, to: detailScroll)
        let contentFrame = content.convert(content.bounds, to: detailScroll)
        let basicSectionFrame = basicSection.convert(basicSection.bounds, to: detailScroll)
        let modelSectionFrame = modelSection.convert(modelSection.bounds, to: detailScroll)

        XCTAssertEqual(documentFrame.maxY, visibleFrame.maxY, accuracy: 0.5)
        XCTAssertEqual(contentFrame.minY, documentFrame.minY + 14, accuracy: 0.5)
        XCTAssertEqual(basicSectionFrame.minY, contentFrame.minY, accuracy: 0.5)
        XCTAssertGreaterThan(modelSectionFrame.minY, basicSectionFrame.maxY)
        XCTAssertLessThan(modelSectionFrame.minY - basicSectionFrame.maxY, 200)
        XCTAssertLessThan(contentFrame.height, documentFrame.height - 24)
    }

    func testSelectedModelCapabilitySectionAlignsWithDetailContentLeadingEdge() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")
        controller.view.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailContent", in: controller.view)
        )
        let capabilities = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities", in: controller.view)
        )
        let contentFrame = content.convert(content.bounds, to: controller.view)
        let capabilitiesFrame = capabilities.convert(capabilities.bounds, to: controller.view)

        XCTAssertEqual(capabilitiesFrame.minX, contentFrame.minX, accuracy: 2.5)
        XCTAssertLessThanOrEqual(capabilitiesFrame.maxX, contentFrame.maxX + 0.5)
    }

    func testSelectedModelCapabilityRowsAlignWithSectionLeadingEdge() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")
        controller.view.layoutSubtreeIfNeeded()

        let capabilities = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities", in: controller.view)
        )
        let title = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities.title", in: controller.view)
        )
        let contextBudgetRow = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities.manualContextBudgetRow", in: controller.view)
        )
        let reasoningRow = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities.manualReasoningEffortsRow", in: controller.view)
        )
        let reasoningEffortPopup = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities.reasoningEffort", in: controller.view)
        )
        let reasoningEffortRow = try XCTUnwrap(reasoningEffortPopup.superview)
        let capabilitiesFrame = capabilities.convert(capabilities.bounds, to: controller.view)
        let titleFrame = title.convert(title.bounds, to: controller.view)
        let contextBudgetFrame = contextBudgetRow.convert(contextBudgetRow.bounds, to: controller.view)
        let reasoningFrame = reasoningRow.convert(reasoningRow.bounds, to: controller.view)
        let reasoningEffortFrame = reasoningEffortRow.convert(reasoningEffortRow.bounds, to: controller.view)

        XCTAssertEqual(titleFrame.minX, capabilitiesFrame.minX, accuracy: 2.5)
        XCTAssertEqual(contextBudgetFrame.minX, capabilitiesFrame.minX, accuracy: 2.5)
        XCTAssertEqual(reasoningFrame.minX, capabilitiesFrame.minX, accuracy: 2.5)
        XCTAssertEqual(reasoningEffortFrame.minX, capabilitiesFrame.minX, accuracy: 2.5)
    }

    func testSelectedModelKeepsManualAddRowVisibleBeforeCapabilityDetails() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")
        controller.view.layoutSubtreeIfNeeded()

        let detailScroll = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailScroll", in: controller.view) as? NSScrollView
        )
        let manualModelField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.manualModel", in: controller.view)
        )
        let manualAddRow = try XCTUnwrap(manualModelField.superview)
        let capabilities = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities", in: controller.view)
        )
        let detailContent = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailContent", in: controller.view) as? NSStackView
        )
        let visibleFrame = detailScroll.contentView.convert(
            detailScroll.contentView.bounds,
            to: detailScroll
        )
        let manualAddFrame = manualAddRow.convert(manualAddRow.bounds, to: detailScroll)

        XCTAssertGreaterThanOrEqual(manualAddFrame.minY, visibleFrame.minY - 0.5)
        XCTAssertLessThanOrEqual(manualAddFrame.maxY, visibleFrame.maxY + 0.5)
        XCTAssertLessThan(
            try XCTUnwrap(detailContent.arrangedSubviews.firstIndex(of: manualAddRow)),
            try XCTUnwrap(detailContent.arrangedSubviews.firstIndex(of: capabilities))
        )
    }

    func testSelectingModelScrollsCapabilityDetailsFullyIntoCompactViewport() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")
        controller.view.layoutSubtreeIfNeeded()

        let detailScroll = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.detailScroll", in: controller.view) as? NSScrollView
        )
        let capabilities = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.modelCapabilities", in: controller.view)
        )
        let visibleFrame = detailScroll.contentView.convert(
            detailScroll.contentView.bounds,
            to: detailScroll
        )
        let capabilitiesFrame = capabilities.convert(capabilities.bounds, to: detailScroll)

        XCTAssertGreaterThanOrEqual(capabilitiesFrame.minY, visibleFrame.minY - 0.5)
        XCTAssertLessThanOrEqual(capabilitiesFrame.maxY, visibleFrame.maxY + 0.5)
    }

    func testDefaultModelStarHasStableTwentySixPointAutoLayoutSize() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        controller.selectProvider(id: providerAID)
        controller.view.layoutSubtreeIfNeeded()
        let table = view("Stacio.Settings.aiProviders.models", in: controller.view) as! NSTableView
        let cell = table.view(atColumn: 3, row: 0, makeIfNecessary: true)!
        cell.frame = NSRect(x: 0, y: 0, width: 46, height: 30)
        cell.layoutSubtreeIfNeeded()
        let star = cell.subviews.compactMap { $0 as? NSButton }.first!

        let widthConstraint = star.constraints.first(where: { constraint in
            constraint.isActive
                && constraint.firstAttribute == .width
                && constraint.constant == 26
        })
        let heightConstraint = star.constraints.first(where: { constraint in
            constraint.isActive
                && constraint.firstAttribute == .height
                && constraint.constant == 26
        })

        XCTAssertEqual(
            NSSize(
                width: widthConstraint?.constant ?? 0,
                height: heightConstraint?.constant ?? 0
            ),
            NSSize(width: 26, height: 26)
        )
        XCTAssertTrue(widthConstraint?.isActive ?? false)
        XCTAssertTrue(heightConstraint?.isActive ?? false)
    }

    func testRequiredAccessibilitySurfaceAndIconButtonTooltipsArePresent() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.Settings.aiProviders.manager")
        for identifier in [
            "Stacio.Settings.aiProviders.search",
            "Stacio.Settings.aiProviders.list",
            "Stacio.Settings.aiProviders.displayName",
            "Stacio.Settings.aiProviders.baseURL",
            "Stacio.Settings.aiProviders.apiKey",
            "Stacio.Settings.aiProviders.modelSearch",
            "Stacio.Settings.aiProviders.models",
            "Stacio.Settings.aiProviders.add",
            "Stacio.Settings.aiProviders.remove",
            "Stacio.Settings.aiProviders.more",
            "Stacio.Settings.aiProviders.visitWebsite",
            "Stacio.Settings.aiProviders.testConnection",
            "Stacio.Settings.aiProviders.refreshModels",
            "Stacio.Settings.aiProviders.toggleAPIKeyVisibility",
            "Stacio.Settings.aiProviders.removeAPIKey"
        ] {
            XCTAssertNotNil(view(identifier, in: controller.view), identifier)
        }

        for identifier in [
            "Stacio.Settings.aiProviders.add",
            "Stacio.Settings.aiProviders.remove",
            "Stacio.Settings.aiProviders.more",
            "Stacio.Settings.aiProviders.toggleAPIKeyVisibility",
            "Stacio.Settings.aiProviders.removeAPIKey"
        ] {
            guard let button = view(identifier, in: controller.view) as? NSButton else {
                return XCTFail("missing button \(identifier)")
            }
            XCTAssertNotNil(button.image, identifier)
            XCTAssertEqual(button.frame.size, NSSize(width: 28, height: 28), identifier)
            XCTAssertFalse(button.toolTip?.isEmpty ?? true, identifier)
            XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true, identifier)
        }
    }

    func testInitialSettingsLoadFailureKeepsMozheSelectedAndShowsTheError() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        fixture.store.loadFailure = TestFailure.message("provider settings are corrupt")
        let controller = fixture.controller

        controller.loadView()

        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertTrue(status?.contains("provider settings are corrupt") ?? false)
        XCTAssertTrue(status?.contains("请检查") ?? false)
        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.mozheAPIID)
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            BuiltInAIProvider.mozheAPIDisplayName
        )
    }

    func testAddButtonInvokesTaskEightCallback() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        var callCount = 0
        controller.onAddProviderRequested = { callCount += 1 }

        (view("Stacio.Settings.aiProviders.add", in: controller.view) as? NSButton)?.performClick(nil)

        XCTAssertEqual(callCount, 1)
    }
}

private let providerAID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let providerBID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

@MainActor
private func makeFixture(
    defaultProviderID: UUID,
    keys: [UUID: String] = [:],
    now: Date = Date(timeIntervalSince1970: 1_000),
    urlOpener: RecordingProviderURLOpener? = nil
) -> ProviderManagerFixture {
    let urlOpener = urlOpener ?? RecordingProviderURLOpener()
    let envelope = AIProviderSettingsEnvelope(
        aiProviders: [
            provider(
                id: providerAID,
                name: "Alpha Provider",
                baseURL: "https://a.example/v1",
                models: [
                    model("a-default", enabled: true, returned: true),
                    model("a-old", enabled: false, returned: true)
                ],
                defaultModelID: "a-default"
            ),
            provider(
                id: providerBID,
                name: "Beta Provider",
                baseURL: "https://b.example/v1",
                models: [
                    model("b-default", enabled: true, returned: true),
                    model("b-disabled", enabled: false, returned: true)
                ],
                defaultModelID: "b-default"
            )
        ],
        defaultAIProviderID: defaultProviderID
    )
    let store = ProviderManagerStore(envelope: envelope)
    let coordinator = ProviderManagerCoordinator(store: store, keys: keys)
    let catalog = ProviderManagerCatalogLoader()
    let connection = ProviderManagerConnectionTester()
    let background = ManualProviderExecutor()
    let controller = AIProviderManagementViewController(
        settingsStore: store,
        mutationCoordinator: coordinator,
        modelCatalogLoader: catalog,
        connectionTester: connection,
        urlOpener: urlOpener,
        backgroundExecutor: background.execute,
        mainExecutor: { operation in operation() },
        now: { now }
    )
    return ProviderManagerFixture(
        controller: controller,
        store: store,
        coordinator: coordinator,
        catalog: catalog,
        connection: connection,
        background: background,
        urlOpener: urlOpener
    )
}

private struct ProviderManagerFixture {
    let controller: AIProviderManagementViewController
    let store: ProviderManagerStore
    let coordinator: ProviderManagerCoordinator
    let catalog: ProviderManagerCatalogLoader
    let connection: ProviderManagerConnectionTester
    let background: ManualProviderExecutor
    let urlOpener: RecordingProviderURLOpener
}

private final class RecordingProviderURLOpener: StacioURLOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private func provider(
    id: UUID,
    name: String,
    baseURL: String,
    models: [AIProviderModelConfiguration],
    defaultModelID: String
) -> AIProviderConfiguration {
    AIProviderConfiguration(
        id: id,
        profile: .openAICompatible,
        displayName: name,
        baseURL: baseURL,
        models: models,
        defaultModelID: defaultModelID,
        compatibilityProtocol: .chatCompletions,
        maxRetryCount: 1,
        requestTimeoutSeconds: 45,
        userAgent: "Stacio",
        isEnabled: true,
        lastVerifiedAt: Date(timeIntervalSince1970: 100),
        lastModelSyncAt: Date(timeIntervalSince1970: 200)
    )
}

private func model(
    _ id: String,
    enabled: Bool,
    manual: Bool = false,
    returned: Bool
) -> AIProviderModelConfiguration {
    AIProviderModelConfiguration(
        id: id,
        isEnabled: enabled,
        isManual: manual,
        wasReturnedByLatestCatalog: returned
    )
}

private final class ProviderManagerStore: AIProviderSettingsStoring {
    var envelope: AIProviderSettingsEnvelope
    var loadFailure: Error?

    init(envelope: AIProviderSettingsEnvelope) {
        self.envelope = envelope
    }

    func loadAIProviderSettings() throws -> AIProviderSettingsEnvelope {
        if let loadFailure {
            throw loadFailure
        }
        return envelope
    }

    func saveAIProviderSettings(_ envelope: AIProviderSettingsEnvelope) throws {
        self.envelope = envelope
    }

    func provider(id: UUID) -> AIProviderConfiguration? {
        envelope.aiProviders.first { $0.id == id }
    }

    func replace(_ provider: AIProviderConfiguration) {
        guard let index = envelope.aiProviders.firstIndex(where: { $0.id == provider.id }) else { return }
        envelope.aiProviders[index] = provider
    }
}

private final class ProviderManagerCoordinator: AIProviderMutationCoordinating {
    struct SaveCall {
        let provider: AIProviderConfiguration
        let apiKeyUpdate: AIProviderAPIKeyUpdate
    }

    let store: ProviderManagerStore
    var keys: [UUID: String]
    private(set) var saveCalls: [SaveCall] = []
    private(set) var deletedProviderIDs: [UUID] = []
    private(set) var defaultProviderIDs: [UUID] = []
    var saveFailure: Error?
    var deleteFailure: Error?
    var defaultFailure: Error?
    var readKeyFailure: Error?

    init(store: ProviderManagerStore, keys: [UUID: String]) {
        self.store = store
        self.keys = keys
    }

    func saveProvider(
        _ provider: AIProviderConfiguration,
        apiKeyUpdate: AIProviderAPIKeyUpdate
    ) throws -> AIProviderSettingsEnvelope {
        saveCalls.append(.init(provider: provider, apiKeyUpdate: apiKeyUpdate))
        if let saveFailure {
            throw saveFailure
        }
        switch apiKeyUpdate {
        case .unchanged:
            break
        case let .replace(key):
            keys[provider.id] = key
        case .remove:
            keys[provider.id] = nil
        }
        var envelope = store.envelope
        if let index = envelope.aiProviders.firstIndex(where: { $0.id == provider.id }) {
            envelope.aiProviders[index] = provider
        } else {
            envelope.aiProviders.append(provider)
        }
        envelope = AIProviderSettingsNormalizer.normalized(envelope)
        try store.saveAIProviderSettings(envelope)
        return envelope
    }

    func deleteProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        deletedProviderIDs.append(id)
        if let deleteFailure {
            throw deleteFailure
        }
        keys[id] = nil
        var envelope = store.envelope
        envelope.aiProviders.removeAll { $0.id == id }
        envelope = AIProviderSettingsNormalizer.normalized(envelope)
        try store.saveAIProviderSettings(envelope)
        return envelope
    }

    func setDefaultProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        defaultProviderIDs.append(id)
        if let defaultFailure {
            throw defaultFailure
        }
        var envelope = store.envelope
        envelope.defaultAIProviderID = id
        envelope = AIProviderSettingsNormalizer.normalized(envelope)
        try store.saveAIProviderSettings(envelope)
        return envelope
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        if let readKeyFailure {
            throw readKeyFailure
        }
        return keys[providerID]
    }
}

private final class ProviderManagerCatalogLoader: AIModelCatalogLoading {
    struct Call {
        let provider: AIProviderConfiguration
        let apiKey: String?
    }

    var result: Result<[String], Error> = .success([])
    private(set) var calls: [Call] = []

    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        calls.append(.init(provider: provider, apiKey: apiKey))
        return try result.get()
    }
}

private final class ProviderManagerConnectionTester: AIAssistantConnectionTesting {
    struct Call {
        let provider: AIProviderConfiguration
        let modelID: String
        let apiKey: String?
    }

    var result: Result<AIAssistantConnectionTestResult, Error> = .success(.init(message: "ok"))
    private(set) var calls: [Call] = []

    func testConnection(
        provider: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) throws -> AIAssistantConnectionTestResult {
        calls.append(.init(provider: provider, modelID: modelID, apiKey: apiKey))
        return try result.get()
    }
}

private final class ManualProviderExecutor {
    private var operations: [() -> Void] = []

    var pendingCount: Int {
        operations.count
    }

    func execute(_ operation: @escaping () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        run(at: 0)
    }

    func run(at index: Int) {
        operations.remove(at: index)()
    }
}

private enum TestFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

private func view(_ identifier: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == identifier {
        return root
    }
    for subview in root.subviews {
        if let match = view(identifier, in: subview) {
            return match
        }
    }
    return nil
}

private func textField(_ identifier: String, in root: NSView) -> NSTextField? {
    view(identifier, in: root) as? NSTextField
}

private func textField(accessibilityLabel: String, in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField,
       field.accessibilityLabel() == accessibilityLabel {
        return field
    }
    for subview in root.subviews {
        if let match = textField(accessibilityLabel: accessibilityLabel, in: subview) {
            return match
        }
    }
    return nil
}

private func assertNoProviderManagerSecrets(
    _ message: String?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNotNil(message, file: file, line: line)
    XCTAssertFalse(message?.contains("unrelated-token") ?? true, file: file, line: line)
    XCTAssertFalse(message?.contains("other-secret") ?? true, file: file, line: line)
    XCTAssertTrue(message?.contains("[已隐藏凭据]") ?? false, file: file, line: line)
}
