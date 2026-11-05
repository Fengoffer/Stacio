import AppKit
import Foundation
@testable import StacioApp
import XCTest

@MainActor
final class AIProviderManagementViewControllerTests: XCTestCase {
    func testSelectingProviderShowsOnlyItsFieldsAndModelsInStoreOrder() {
        let fixture = makeFixture(defaultProviderID: providerBID)
        let controller = fixture.controller
        controller.loadView()

        controller.selectProvider(id: providerBID)

        XCTAssertEqual(controller.selectedProviderID, providerBID)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue, "https://b.example/v1")
        XCTAssertEqual(controller.visibleModelIDsForTesting, ["b-default", "b-disabled"])
        XCTAssertEqual(
            controller.visibleProviderIDsForTesting,
            [providerAID, providerBID]
        )
        XCTAssertFalse(controller.visibleProviderIDsForTesting.contains(BuiltInAIProvider.stacioRulesID))

        let summaries = controller.providerSummariesForTesting
        XCTAssertEqual(summaries.first?.id, providerAID)
        XCTAssertEqual(summaries.first?.displayName, "Alpha Provider")
        XCTAssertEqual(summaries.first?.enabledModelCount, 1)
        XCTAssertEqual(summaries.first?.totalModelCount, 2)
        XCTAssertFalse(summaries.first?.isDefault ?? true)
        XCTAssertFalse(summaries.first?.isRecommended ?? true)
        XCTAssertFalse(controller.recommendedBadgeVisibleForTesting(providerID: providerAID))
        XCTAssertFalse(controller.recommendedBadgeVisibleForTesting(providerID: providerBID))
        XCTAssertEqual(summaries.first(where: { $0.id == providerBID })?.enabledModelCount, 1)
        XCTAssertEqual(summaries.first(where: { $0.id == providerBID })?.totalModelCount, 2)
        XCTAssertTrue(summaries.first(where: { $0.id == providerBID })?.isDefault ?? false)
        XCTAssertFalse(summaries.first(where: { $0.id == providerBID })?.statusText.isEmpty ?? true)
    }

    func testMozheIsEditableAndPersistsLikeAnyOtherProvider() throws {
        let originalMozhe = mozheProvider()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            providers: [originalMozhe, alphaProvider()]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: mozheProviderID)

        let nameField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)
        )
        let baseURLField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)
        )

        XCTAssertEqual(nameField.stringValue, originalMozhe.displayName)
        XCTAssertTrue(nameField.isEditable)
        XCTAssertTrue(nameField.isSelectable)
        XCTAssertTrue(nameField.isEnabled)
        XCTAssertEqual(baseURLField.stringValue, originalMozhe.baseURL)
        XCTAssertTrue(baseURLField.isEditable)
        XCTAssertTrue(baseURLField.isSelectable)
        XCTAssertTrue(baseURLField.isEnabled)
        XCTAssertTrue((view("Stacio.Settings.aiProviders.remove", in: controller.view) as? NSButton)?.isEnabled ?? false)

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

        XCTAssertEqual(nameField.stringValue, "Renamed mozhe")
        XCTAssertEqual(baseURLField.stringValue, "https://redirect.example/v1")
        // 名称与 URL 同属一个编辑草稿：提交时合并为一次保存。
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
        let managedProvider = try XCTUnwrap(
            controller.currentEnvelope.aiProviders.first { $0.id == mozheProviderID }
        )
        XCTAssertEqual(managedProvider.displayName, "Renamed mozhe")
        XCTAssertEqual(managedProvider.baseURL, "https://redirect.example/v1")
    }

    func testWebsiteButtonRequiresCatalogActionAndNeverOpensBaseURL() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        XCTAssertFalse(controller.visitWebsiteButtonVisibleForTesting)
        controller.openSelectedProviderWebsiteForTesting()
        XCTAssertTrue(fixture.urlOpener.openedURLs.isEmpty)

        controller.selectProvider(id: providerBID)

        XCTAssertFalse(controller.visitWebsiteButtonVisibleForTesting)
        controller.openSelectedProviderWebsiteForTesting()
        XCTAssertTrue(fixture.urlOpener.openedURLs.isEmpty)
    }

    func testNativeCodingPlanManagementKeepsIdentityAcrossWebsiteURLAndModelActions() throws {
        let descriptor = try XCTUnwrap(
            BundledRuntimeCatalog.shared.catalogSet?.codingPlan(
                catalogID: "coding-plan.kimi-code"
            )
        )
        let planID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let plan = try XCTUnwrap(
            AIProviderConfiguration.catalogDraft(descriptor: descriptor, id: planID)
        )
        let fixture = makeFixture(
            defaultProviderID: planID,
            providers: [plan],
            keys: [planID: "coding-plan-key"]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: planID)

        XCTAssertEqual(controller.selectedProviderWebsiteURLForTesting?.absoluteString, "https://www.kimi.com/code/console")
        let websiteButton = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.visitWebsite", in: controller.view) as? NSButton
        )
        XCTAssertEqual(websiteButton.title, "打开 Coding Plan")
        websiteButton.performClick(nil)
        XCTAssertEqual(fixture.urlOpener.openedURLs.map(\.absoluteString), ["https://www.kimi.com/code/console"])

        controller.commitBaseURLForTesting("https://proxy.example/v1")
        XCTAssertTrue(controller.restoreOfficialURLButtonVisibleForTesting)
        controller.restoreOfficialURLForTesting()
        XCTAssertEqual(
            fixture.store.provider(id: planID)?.baseURL,
            "https://api.kimi.com/coding/v1"
        )

        fixture.catalog.result = .success(["user-visible-model"])
        controller.refreshModelsForTesting()
        fixture.background.runNext()

        let saved = try XCTUnwrap(fixture.store.provider(id: planID))
        XCTAssertEqual(saved.runtimeConfigurationKind, .codingPlan)
        XCTAssertEqual(saved.catalogID, "coding-plan.kimi-code")
        XCTAssertEqual(saved.models.map(\.id), ["user-visible-model"])
        XCTAssertEqual(fixture.catalog.calls.last?.provider.runtimeConfigurationKind, .codingPlan)
        XCTAssertEqual(fixture.catalog.calls.last?.apiKey, "coding-plan-key")
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
        XCTAssertFalse(savedB?.isEnabled ?? true)
        XCTAssertNil(savedB?.lastVerifiedAt)
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

    func testDefaultProviderFailureIsVisibleWhileDefaultIsSelected() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let originalEnvelope = fixture.store.envelope
        let controller = fixture.controller
        controller.loadView()
        let originalControllerEnvelope = controller.currentEnvelope
        controller.selectProvider(id: providerAID)
        fixture.coordinator.defaultFailure = TestFailure.message(
            "default mutation failed Authorization: Bearer unrelated-token token=other-secret"
        )

        controller.setDefaultProviderForTesting()

        XCTAssertEqual(fixture.coordinator.defaultProviderIDs, [providerAID])
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

    func testRefreshModelsIsDisabledUntilRequiredCredentialIsAvailable() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let refresh = try XCTUnwrap(
            view("Stacio.Settings.aiProviders.refreshModels", in: controller.view) as? NSButton
        )

        XCTAssertFalse(refresh.isEnabled)
        controller.refreshModelsForTesting()
        XCTAssertEqual(fixture.background.pendingCount, 0)

        let apiKeyField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)
        )
        apiKeyField.stringValue = "pending-secret"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: apiKeyField)
        )

        XCTAssertTrue(refresh.isEnabled)
    }

    func testRefreshingModelsPersistsPendingAPIKeyBeforeReadingKeychain() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
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
            fixture.coordinator.keys[providerAID],
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
            providerAID
        )
        XCTAssertEqual(
            controller.catalogStateForTesting(providerID: providerAID),
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

    func testDeleteSelectedProviderLeavesExplicitUnconfiguredState() {
        let fixture = makeFixture(defaultProviderID: providerBID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerBID)

        controller.deleteSelectedProviderForTesting()

        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerBID])
        XCTAssertNil(fixture.store.provider(id: providerBID))
        XCTAssertEqual(fixture.store.envelope.defaultAIProviderID, BuiltInAIProvider.stacioRulesID)
        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.stacioRulesID)
    }

    func testMozheCanBeDeletedLikeAnyOtherProvider() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            providers: [mozheProvider(), alphaProvider()]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: mozheProviderID)

        controller.deleteSelectedProviderForTesting()

        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [mozheProviderID])
        XCTAssertNil(fixture.store.provider(id: mozheProviderID))
        XCTAssertEqual(controller.selectedProviderID, providerAID)
        XCTAssertEqual(controller.visibleProviderIDsForTesting, [providerAID])
        XCTAssertFalse(controller.visibleProviderIDsForTesting.contains(BuiltInAIProvider.stacioRulesID))
        XCTAssertEqual(fixture.store.envelope.aiProviders.count, 1)
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

    func testQueuedDeleteRejectsExternallyChangedProviderAndReloadsLatestConfiguration() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "persisted-secret"],
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.deleteSelectedProviderForTesting()
        XCTAssertEqual(persistence.pendingCount, 1)

        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://external-before-delete.example/v1"
        fixture.store.replace(externallyUpdated)
        persistence.runNext()

        XCTAssertTrue(fixture.coordinator.deletedProviderIDs.isEmpty)
        XCTAssertEqual(fixture.store.provider(id: providerAID), externallyUpdated)
        let reloaded = controller.currentEnvelope.aiProviders.first { $0.id == providerAID }
        XCTAssertEqual(reloaded?.baseURL, externallyUpdated.baseURL)
        XCTAssertNil(reloaded?.confirmedCredentialOrigin, "old-origin approval must not survive an external endpoint change")
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue,
            externallyUpdated.baseURL
        )
        XCTAssertTrue(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?
                .stringValue.contains("已重新加载") ?? false
        )
    }

    func testQueuedSaveRejectsExternalProviderChangeInsteadOfOverwritingIt() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("Local Rename")
        XCTAssertEqual(persistence.pendingCount, 1)

        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://external-before-save.example/v1"
        fixture.store.replace(externallyUpdated)
        persistence.runNext()

        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(fixture.store.provider(id: providerAID), externallyUpdated)
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            externallyUpdated.displayName
        )
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.baseURL", in: controller.view)?.stringValue,
            externallyUpdated.baseURL
        )
        XCTAssertTrue(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?
                .stringValue.contains("已重新加载") ?? false
        )
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

        controller.reloadFromStoreAsync(selecting: providerAID)

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
        controller.reloadFromStoreAsync(selecting: providerAID)

        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertFalse(status?.contains("mutation failure before reload") ?? true)
        XCTAssertFalse(status?.contains("请检查") ?? true)
    }

    func testReloadFromStoreInvalidatesCatalogRequestCapturedBeforeExternalChange() throws {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["stale-external-result"])

        controller.refreshModelsForTesting()
        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://externally-edited.example/v1"
        fixture.store.replace(externallyUpdated)
        controller.reloadFromStoreAsync(selecting: providerAID)
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.baseURL, "https://externally-edited.example/v1")
        XCTAssertFalse(fixture.store.provider(id: providerAID)?.models.contains(where: { $0.id == "stale-external-result" }) ?? true)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }

    func testReloadFailureInvalidatesRuntimeStateDiscardsDraftAndRejectsInflightResults() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let originalProvider = fixture.store.provider(id: providerAID)
        let controller = fixture.controller
        controller.loadView()
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

        controller.reloadFromStoreAsync(selecting: providerAID)

        XCTAssertEqual(controller.currentEnvelope, .defaultConfiguration)
        XCTAssertEqual(textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue, "")
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
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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

    func testCatalogResultAfterExternalBaseURLOnlyChangeIsIgnoredAndDoesNotMarkNewConfigStale() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let original = fixture.store.provider(id: providerAID)!
        fixture.catalog.result = .failure(TestFailure.message("old endpoint failed"))

        controller.refreshModelsForTesting()
        var externallyUpdated = original
        externallyUpdated.baseURL = "https://external-only-url.example/v1"
        externallyUpdated.lastModelSyncAt = Date(timeIntervalSince1970: 321)
        fixture.store.replace(externallyUpdated)
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), externallyUpdated)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(controller.catalogStateForTesting(providerID: providerAID), .idle)
    }

    func testCatalogResultIsDroppedWhenPersistentCredentialReadFails() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let original = fixture.store.provider(id: providerAID)!
        fixture.catalog.result = .success(["must-not-merge-after-key-read-failure"])

        controller.refreshModelsForTesting()
        fixture.coordinator.readKeyFailure = TestFailure.message("keychain unavailable")
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(controller.catalogStateForTesting(providerID: providerAID), .idle)
    }

    func testCatalogResultIsDroppedWhenPersistentSettingsReloadFails() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let original = fixture.store.provider(id: providerAID)!
        fixture.catalog.result = .success(["must-not-merge-after-settings-read-failure"])

        controller.refreshModelsForTesting()
        fixture.store.loadFailure = TestFailure.message("settings temporarily unavailable")
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(controller.catalogStateForTesting(providerID: providerAID), .idle)
    }

    func testTypingBaseURLRejectsInflightCatalogAndConnectionBeforeCommit() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
            let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
        let saves = fixture.coordinator.saveCalls.filter { $0.provider.id == providerAID }
        XCTAssertEqual(saves.count, 3)
        XCTAssertNil(saves[0].provider.confirmedCredentialOrigin, "origin change invalidates prior approval")
        XCTAssertEqual(
            saves[1].provider.confirmedCredentialOrigin,
            "https://newest-request.example",
            "the new origin is durably approved before transport"
        )
        XCTAssertEqual(saves[2].provider.models.map(\.id), ["a-default", "a-old", "newest"])
    }

    func testCredentialOriginCancellationStartsNoCatalogOrConnectionNetwork() {
        var providerA = alphaProvider()
        providerA.confirmedCredentialOrigin = nil
        var requests: [AIProviderCredentialOriginConfirmationRequest] = []
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            providers: [providerA, betaProvider()],
            keys: [providerAID: "a-secret"],
            credentialOriginConfirmationHandler: { request in
                requests.append(request)
                return false
            }
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        controller.refreshModelsForTesting()
        controller.testConnectionForTesting()

        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(fixture.background.pendingCount, 0)
        XCTAssertTrue(fixture.catalog.calls.isEmpty)
        XCTAssertTrue(fixture.connection.calls.isEmpty)
    }

    func testCredentialOriginConfirmationPersistsAcrossReloadAndConnectionSnapshot() throws {
        var providerA = alphaProvider()
        providerA.confirmedCredentialOrigin = nil
        var requests: [AIProviderCredentialOriginConfirmationRequest] = []
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            providers: [providerA, betaProvider()],
            keys: [providerAID: "a-secret"],
            credentialOriginConfirmationHandler: { request in
                requests.append(request)
                return true
            }
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        controller.testConnectionForTesting()
        XCTAssertEqual(fixture.background.pendingCount, 1)
        XCTAssertEqual(
            fixture.store.provider(id: providerAID)?.confirmedCredentialOrigin,
            "https://a.example"
        )
        fixture.background.runNext()

        XCTAssertEqual(fixture.connection.calls.count, 1)
        XCTAssertEqual(
            fixture.connection.calls.first?.provider.confirmedCredentialOrigin,
            "https://a.example"
        )
        controller.reloadFromStoreAsync(selecting: providerAID)
        controller.testConnectionForTesting()

        XCTAssertEqual(requests.count, 1, "persisted approval must survive the settings controller reload")
        XCTAssertEqual(fixture.background.pendingCount, 1)
    }

    func testCredentialOriginPersistenceFailurePreventsNetwork() {
        var providerA = alphaProvider()
        providerA.confirmedCredentialOrigin = nil
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            providers: [providerA, betaProvider()],
            keys: [providerAID: "a-secret"],
            credentialOriginConfirmationHandler: { _ in true }
        )
        fixture.coordinator.saveFailure = TestFailure.message("approval save failed")
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        controller.refreshModelsForTesting()

        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
        XCTAssertEqual(fixture.background.pendingCount, 0)
        XCTAssertTrue(fixture.catalog.calls.isEmpty)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.confirmedCredentialOrigin)
    }

    func testCatalogMergePreservesManualModelsMarksStaleModelsAndManualAddIsScoped() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        var providerA = fixture.store.provider(id: providerAID)!
        providerA.models = [
            model("a-default", enabled: true, returned: true),
            model("manual-old", enabled: true, manual: true, returned: false),
            model("catalog-old", enabled: true, returned: true)
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
        XCTAssertFalse(saved.models.first(where: { $0.id == "catalog-old" })?.isEnabled ?? true)
        XCTAssertTrue(saved.models.first(where: { $0.id == "manual-new" })?.isManual ?? false)
        XCTAssertFalse(saved.models.first(where: { $0.id == "manual-new" })?.isEnabled ?? true)
        XCTAssertEqual(controller.modelStatusTextForTesting(modelID: "catalog-old"), "目录中已移除")
        XCTAssertEqual(controller.modelStatusTextForTesting(modelID: "manual-new"), "手动待测试")
        XCTAssertEqual(fixture.store.provider(id: providerBID), originalB)
    }

    func testCatalogRefreshClearsRemovedDefaultAndRejectsReenablingIt() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        var providerA = fixture.store.provider(id: providerAID)!
        providerA.models = [
            model("removed-default", enabled: true, returned: true)
        ]
        providerA.defaultModelID = "removed-default"
        providerA.isEnabled = true
        fixture.store.replace(providerA)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["new-model"])

        controller.refreshModelsForTesting()
        fixture.background.runNext()

        let refreshed = fixture.store.provider(id: providerAID)
        XCTAssertNil(refreshed?.defaultModelID)
        XCTAssertFalse(refreshed?.isEnabled ?? true)
        XCTAssertFalse(
            refreshed?.models.first(where: { $0.id == "removed-default" })?.isEnabled ?? true
        )

        let saveCount = fixture.coordinator.saveCalls.count
        controller.setDefaultModelForTesting("removed-default")
        controller.toggleModelEnabledForTesting("removed-default", enabled: true)

        XCTAssertEqual(fixture.coordinator.saveCalls.count, saveCount)
        XCTAssertNil(fixture.store.provider(id: providerAID)?.defaultModelID)
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

        let persisted = fixture.store.provider(id: providerAID)
        XCTAssertEqual(persisted?.displayName, original?.displayName)
        XCTAssertEqual(persisted?.baseURL, original?.baseURL)
        XCTAssertEqual(persisted?.models.map(\.id), original?.models.map(\.id))
        XCTAssertNil(persisted?.lastModelSyncAt)
        XCTAssertTrue(persisted?.models.allSatisfy { $0.wasReturnedByLatestCatalog == false } ?? false)
        guard case let .failed(message) = controller.catalogStateForTesting(providerID: providerAID) else {
            return XCTFail("expected failed catalog state")
        }
        XCTAssertFalse(message.contains("opaque-secret"))
        XCTAssertTrue(message.contains("请检查"))
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
    }

    func testEmptyCatalogSuccessIsRejectedAndMarksExistingCatalogStale() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success([])

        controller.refreshModelsForTesting()
        fixture.background.runNext()

        let persisted = fixture.store.provider(id: providerAID)
        XCTAssertNil(persisted?.lastModelSyncAt)
        XCTAssertTrue(persisted?.models.allSatisfy { !$0.wasReturnedByLatestCatalog } ?? false)
        guard case let .failed(message) = controller.catalogStateForTesting(providerID: providerAID) else {
            return XCTFail("expected empty catalog to fail")
        }
        XCTAssertTrue(message.contains("无法解析"))
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
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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

    func testTestingNonDefaultModelPreservesExistingProviderVerification() {
        let verifiedAt = Date(timeIntervalSince1970: 2_000)
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"],
            now: verifiedAt
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")
        fixture.connection.result = .success(.init(message: "连接成功"))

        controller.testConnectionForTesting()
        fixture.background.runNext()

        let persisted = fixture.store.provider(id: providerAID)
        XCTAssertEqual(persisted?.lastVerifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(persisted?.isEnabled ?? false)
        XCTAssertEqual(
            persisted?.models.first(where: { $0.id == "a-old" })?.lastVerifiedAt,
            verifiedAt
        )
    }

    func testDefaultModelConnectionFailureRevokesProviderVerificationAndDisablesRuntime() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"]
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .failure(TestFailure.message("connection failed"))

        controller.testConnectionForTesting()
        fixture.background.runNext()

        let persisted = fixture.store.provider(id: providerAID)
        XCTAssertNil(persisted?.lastVerifiedAt)
        XCTAssertFalse(persisted?.isEnabled ?? true)
        XCTAssertEqual(fixture.store.envelope.defaultAIProviderID, providerAID)
        XCTAssertNil(
            persisted?.models.first(where: { $0.id == "a-default" })?.lastVerifiedAt
        )
        XCTAssertEqual(persisted?.baseURL, "https://a.example/v1")
        XCTAssertEqual(persisted?.defaultModelID, "a-default")
    }

    func testNonDefaultModelConnectionFailureOnlyRevokesThatModelVerification() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"]
        )
        var configured = fixture.store.provider(id: providerAID)!
        configured.models[1].isEnabled = true
        configured.models[1].lastVerifiedAt = Date(timeIntervalSince1970: 90)
        fixture.store.replace(configured)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        controller.selectModelForTesting("a-old")
        fixture.connection.result = .failure(TestFailure.message("connection failed"))

        controller.testConnectionForTesting()
        fixture.background.runNext()

        let persisted = fixture.store.provider(id: providerAID)
        XCTAssertEqual(persisted?.lastVerifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(persisted?.isEnabled ?? false)
        XCTAssertNil(
            persisted?.models.first(where: { $0.id == "a-old" })?.lastVerifiedAt
        )
    }

    func testTestingCatalogDefaultModelIsOnlyActionThatEnablesProvider() {
        var configured = mozheProvider()
        configured.isEnabled = false
        configured.lastVerifiedAt = nil
        let fixture = makeFixture(
            defaultProviderID: mozheProviderID,
            providers: [configured],
            keys: [mozheProviderID: "mozhe-secret"],
            now: Date(timeIntervalSince1970: 2_000)
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: mozheProviderID)
        fixture.connection.result = .success(.init(message: "连接成功"))

        controller.testConnectionForTesting()
        fixture.background.runNext()

        XCTAssertTrue(fixture.store.provider(id: mozheProviderID)?.isEnabled ?? false)
        XCTAssertEqual(
            fixture.store.provider(id: mozheProviderID)?.lastVerifiedAt,
            Date(timeIntervalSince1970: 2_000)
        )
    }

    func testActivationVerifiesFirstEnabledModelAndMakesItDefault() {
        var configured = mozheProvider()
        configured.defaultModelID = nil
        configured.isEnabled = false
        configured.lastVerifiedAt = nil
        let fixture = makeFixture(
            defaultProviderID: mozheProviderID,
            providers: [configured],
            keys: [mozheProviderID: "mozhe-secret"],
            now: Date(timeIntervalSince1970: 2_000)
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: mozheProviderID)
        fixture.connection.result = .success(.init(message: "连接成功"))

        XCTAssertEqual(controller.providerActivationButtonTitleForTesting, "验证并启用")
        XCTAssertTrue(controller.providerActivationButtonEnabledForTesting)

        controller.toggleProviderActivationForTesting()
        fixture.background.runNext()

        let persisted = fixture.store.provider(id: mozheProviderID)
        XCTAssertEqual(persisted?.defaultModelID, configured.models.first?.id)
        XCTAssertEqual(persisted?.lastVerifiedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(persisted?.isEnabled ?? false)
        XCTAssertEqual(controller.providerActivationButtonTitleForTesting, "停用")
    }

    func testActivationButtonCanDisableAndReenableVerifiedProvider() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)

        XCTAssertEqual(controller.providerActivationButtonTitleForTesting, "停用")
        controller.toggleProviderActivationForTesting()
        XCTAssertFalse(fixture.store.provider(id: providerAID)?.isEnabled ?? true)
        XCTAssertEqual(controller.providerActivationButtonTitleForTesting, "启用")

        controller.toggleProviderActivationForTesting()
        XCTAssertTrue(fixture.store.provider(id: providerAID)?.isEnabled ?? false)
        XCTAssertEqual(controller.providerActivationButtonTitleForTesting, "停用")
    }

    func testConnectionResultAfterExternalProviderOrKeyChangeIsIgnored() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "old-secret"],
            now: Date(timeIntervalSince1970: 999)
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(.init(message: "旧配置测试成功"))

        controller.testConnectionForTesting()
        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://new-endpoint.example/v1"
        fixture.store.replace(externallyUpdated)
        fixture.coordinator.keys[providerAID] = "new-secret"
        fixture.background.runNext()

        let persisted = fixture.store.provider(id: providerAID)
        XCTAssertEqual(persisted?.baseURL, "https://new-endpoint.example/v1")
        XCTAssertEqual(persisted?.lastVerifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }

    func testConnectionResultAfterExternalBaseURLOnlyChangeIsIgnoredAndPreservesNewVerification() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "old-secret"],
            now: Date(timeIntervalSince1970: 999)
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(.init(message: "old endpoint succeeded"))

        controller.testConnectionForTesting()
        var externallyUpdated = fixture.store.provider(id: providerAID)!
        externallyUpdated.baseURL = "https://external-only-url.example/v1"
        externallyUpdated.lastVerifiedAt = Date(timeIntervalSince1970: 777)
        fixture.store.replace(externallyUpdated)
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), externallyUpdated)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }

    func testConnectionResultIsDroppedWhenPersistentCredentialReadFails() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"],
            now: Date(timeIntervalSince1970: 999)
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(.init(message: "must-not-verify"))

        controller.testConnectionForTesting()
        fixture.coordinator.readKeyFailure = TestFailure.message("keychain unavailable")
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.lastVerifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue,
            "已验证"
        )
    }

    func testConnectionResultIsDroppedWhenPersistentSettingsReloadFails() {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"],
            now: Date(timeIntervalSince1970: 999)
        )
        let controller = fixture.controller
        controller.loadView()
        controller.selectProvider(id: providerAID)
        let original = fixture.store.provider(id: providerAID)!
        fixture.connection.result = .success(.init(message: "must-not-verify"))

        controller.testConnectionForTesting()
        fixture.store.loadFailure = TestFailure.message("settings temporarily unavailable")
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue,
            "已验证"
        )
    }

    func testCatalogLoadingDisablesOnlyRefreshRejectsRepeatAndReenablesAfterSuccess() {
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
        let fixture = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
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
        controller.selectProvider(id: providerAID)
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
            "Stacio.Settings.aiProviders.export",
            "Stacio.Settings.aiProviders.import",
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
            "Stacio.Settings.aiProviders.export",
            "Stacio.Settings.aiProviders.import",
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

    func testInitialSettingsLoadFailureShowsTheErrorWithoutConfiguredProviders() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        fixture.store.loadFailure = TestFailure.message("provider settings are corrupt")
        let controller = fixture.controller

        controller.loadView()

        let status = textField("Stacio.Settings.aiProviders.status", in: controller.view)?.stringValue
        XCTAssertTrue(status?.contains("provider settings are corrupt") ?? false)
        XCTAssertTrue(status?.contains("请检查") ?? false)
        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.stacioRulesID)
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            ""
        )
    }

    func testInitialLoadAndCredentialAvailabilityUsePersistenceExecutor() throws {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "persisted-secret"],
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller

        controller.loadView()

        XCTAssertTrue(controller.isSettingsLoadingForTesting)
        XCTAssertEqual(persistence.pendingCount, 1)
        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.stacioRulesID)

        persistence.runNext()

        XCTAssertFalse(controller.isSettingsLoadingForTesting)
        XCTAssertEqual(controller.selectedProviderID, providerAID)
        XCTAssertEqual(persistence.pendingCount, 1, "credential presence must be read off the main thread")
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue,
            ""
        )

        persistence.runNext()

        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue,
            AIProviderManagementViewController.maskedAPIKeyPlaceholder
        )
    }

    func testSaveWhileCredentialAvailabilityIsPendingRestartsCredentialRead() {
        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "pending-availability-secret"],
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        XCTAssertEqual(persistence.pendingCount, 1, "credential availability read should be pending")

        controller.commitDisplayNameForTesting("Rename During Credential Read")
        persistence.runNext()
        main.runNext()
        XCTAssertEqual(persistence.pendingCount, 1, "provider save should be pending")
        persistence.runNext()
        main.runNext()
        XCTAssertEqual(persistence.pendingCount, 1, "cancelled availability read must be restarted")

        persistence.runNext()
        main.runNext()

        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)?.stringValue,
            AIProviderManagementViewController.maskedAPIKeyPlaceholder
        )
        XCTAssertEqual(
            fixture.store.provider(id: providerAID)?.displayName,
            "Rename During Credential Read"
        )
    }

    func testViewDisappearanceDropsLateInitialLoad() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller

        controller.loadView()
        XCTAssertEqual(persistence.pendingCount, 1)
        controller.viewWillDisappear()
        persistence.runNext()

        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.stacioRulesID)
        XCTAssertTrue(controller.isSettingsLoadingForTesting)
    }

    func testViewAppearanceReloadsAfterPendingLoadWasCancelled() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        controller.viewWillDisappear()
        persistence.runNext()

        controller.viewWillAppear()

        XCTAssertEqual(persistence.pendingCount, 1)
        persistence.runNext()
        XCTAssertEqual(controller.selectedProviderID, providerAID)
        XCTAssertFalse(controller.isSettingsLoadingForTesting)
    }

    func testRevealReadsCredentialAsynchronouslyAndDropsLateResultAfterSelectionChange() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "persisted-secret"],
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.toggleAPIKeyVisibilityForTesting()

        XCTAssertFalse(controller.isAPIKeyRevealedForTesting)
        XCTAssertEqual(persistence.pendingCount, 1)
        controller.selectProvider(id: providerBID)
        persistence.runNext()

        XCTAssertFalse(controller.isAPIKeyRevealedForTesting)
        XCTAssertEqual(controller.selectedProviderID, providerBID)
    }

    func testPendingAPIKeyRefreshWaitsForPersistenceBeforeStartingNetwork() throws {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)
        let apiKeyField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)
        )
        apiKeyField.stringValue = "new-secret"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: apiKeyField)
        )
        fixture.catalog.result = .success(["fresh-model"])

        controller.refreshModelsForTesting()

        XCTAssertEqual(persistence.pendingCount, 1)
        XCTAssertTrue(fixture.catalog.calls.isEmpty)
        XCTAssertEqual(fixture.background.pendingCount, 0)

        persistence.runNext()

        XCTAssertEqual(persistence.pendingCount, 1, "saved credential must be re-read before network")
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "new-secret")
        XCTAssertTrue(fixture.catalog.calls.isEmpty)

        persistence.runNext()

        XCTAssertEqual(fixture.background.pendingCount, 1)
        fixture.background.runNext()
        XCTAssertEqual(persistence.pendingCount, 1, "network result persistence must stay off main")
        persistence.runNext()

        XCTAssertTrue(
            fixture.store.provider(id: providerAID)?.models.contains(where: {
                $0.id == "fresh-model" && $0.wasReturnedByLatestCatalog
            }) ?? false
        )
    }

    func testConnectionResultWaitsForPersistenceExecutorBeforeMutatingStore() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "persisted-secret"],
            now: Date(timeIntervalSince1970: 999),
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(.init(message: "连接成功"))

        controller.testConnectionForTesting()
        XCTAssertEqual(persistence.pendingCount, 1, "credential read must precede transport")
        persistence.runNext()
        XCTAssertEqual(fixture.background.pendingCount, 1)

        fixture.background.runNext()

        XCTAssertEqual(persistence.pendingCount, 1, "network completion must enqueue persistence")
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.lastVerifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)

        persistence.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.lastVerifiedAt, Date(timeIntervalSince1970: 999))
        XCTAssertEqual(fixture.coordinator.saveCalls.count, 1)
    }

    func testBackgroundImportWaitsForPersistenceAfterParsingBeforeMutatingStore() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var importedProvider = try XCTUnwrap(source.store.provider(id: providerAID))
        importedProvider.displayName = "Parsed But Not Persisted"
        source.store.replace(importedProvider)
        source.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-two-stage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.controller.exportConfigurationForTesting(to: url)

        let persistence = ManualProviderExecutor()
        let target = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        target.controller.loadView()
        persistence.runNext()
        persistence.runNext()

        target.controller.importConfigurationInBackgroundForTesting(from: url)
        XCTAssertEqual(target.background.pendingCount, 1)
        target.background.runNext()

        XCTAssertEqual(persistence.pendingCount, 1, "parsed document must still wait for persistence")
        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Alpha Provider")

        persistence.runNext()

        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Parsed But Not Persisted")
    }

    func testQueuedSaveThenSetDefaultStillDeliversSaveCompletion() throws {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)
        let apiKeyField = try XCTUnwrap(
            textField("Stacio.Settings.aiProviders.apiKey", in: controller.view)
        )
        apiKeyField.stringValue = "queued-secret"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: apiKeyField)
        )
        fixture.catalog.result = .success(["queued-model"])

        controller.refreshModelsForTesting()
        controller.setDefaultProviderForTesting()

        XCTAssertEqual(persistence.pendingCount, 2)
        persistence.runNext()
        XCTAssertEqual(
            persistence.pendingCount,
            2,
            "save completion must enqueue its credential read without cancelling set-default"
        )
        persistence.runNext()
        persistence.runNext()

        XCTAssertEqual(fixture.background.pendingCount, 1)
        XCTAssertEqual(fixture.coordinator.defaultProviderIDs, [providerAID])
        XCTAssertEqual(fixture.coordinator.keys[providerAID], "queued-secret")
    }

    func testQueuedSaveThenDeleteAcceptsSameWindowVersion() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("Rename Before Delete")
        controller.deleteSelectedProviderForTesting()

        XCTAssertEqual(persistence.pendingCount, 2)
        persistence.runNext()
        XCTAssertEqual(
            fixture.store.provider(id: providerAID)?.displayName,
            "Rename Before Delete"
        )
        persistence.runNext()

        XCTAssertNil(fixture.store.provider(id: providerAID))
        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerAID])
        XCTAssertEqual(controller.selectedProviderID, BuiltInAIProvider.stacioRulesID)
    }

    func testDeleteAcceptsSameWindowSaveWhoseUICallbackIsStillPending() {
        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        main.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("Persisted Before Callback")
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 1)
        XCTAssertEqual(
            fixture.store.provider(id: providerAID)?.displayName,
            "Persisted Before Callback"
        )
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Alpha Provider"
        )

        controller.deleteSelectedProviderForTesting()
        main.runNext()
        persistence.runNext()
        main.runNext()

        XCTAssertNil(fixture.store.provider(id: providerAID))
        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerAID])
    }

    func testQueuedSaveUICallbackCannotReplaceImportedEnvelope() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var importedProvider = try XCTUnwrap(source.store.provider(id: providerAID))
        importedProvider.displayName = "Imported Provider"
        source.store.replace(importedProvider)
        source.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-late-save-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.controller.exportConfigurationForTesting(to: url)

        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let target = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = target.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        main.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("Old Local Save")
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 1)
        try controller.importConfigurationForTesting(from: url)

        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Imported Provider")
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Imported Provider"
        )

        main.runNext()

        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Imported Provider")
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Imported Provider"
        )
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            "Imported Provider"
        )
    }

    func testPendingInitialLoadCannotReplaceImportedEnvelope() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var importedProvider = try XCTUnwrap(source.store.provider(id: providerAID))
        importedProvider.displayName = "Imported Before Initial Load Completes"
        source.store.replace(importedProvider)
        source.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-late-initial-load-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.controller.exportConfigurationForTesting(to: url)

        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let target = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = target.controller
        controller.loadView()
        XCTAssertEqual(persistence.pendingCount, 1, "initial settings load should be pending")

        // Capture the old envelope but delay its UI completion until after the
        // imported envelope has been applied.
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 1, "old initial-load callback should be pending")

        controller.importConfigurationInBackgroundForTesting(from: url)
        target.background.runNext()
        XCTAssertEqual(main.pendingCount, 2, "import should be queued beside the old load")
        main.run(at: 1)
        XCTAssertEqual(persistence.pendingCount, 1, "import must queue persistence")

        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 2, "import and old-load UI callbacks should be pending")
        main.run(at: 1)
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Imported Before Initial Load Completes"
        )
        XCTAssertFalse(controller.isSettingsLoadingForTesting)
        main.runNext()

        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Imported Before Initial Load Completes"
        )
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            "Imported Before Initial Load Completes"
        )
        XCTAssertFalse(controller.isSettingsLoadingForTesting)
    }

    func testCredentialOriginCallbackAfterImportCannotRestoreOldEnvelopeOrStartNetwork() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var importedProvider = try XCTUnwrap(source.store.provider(id: providerAID))
        importedProvider.displayName = "Imported During Origin Gate"
        source.store.replace(importedProvider)
        source.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-origin-gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.controller.exportConfigurationForTesting(to: url)

        var customProvider = alphaProvider()
        customProvider.applyUserBaseURL("https://custom-origin.example/v1")
        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let target = makeFixture(
            defaultProviderID: providerAID,
            providers: [customProvider, betaProvider()],
            keys: [providerAID: "custom-origin-secret"],
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = target.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        main.runNext()
        controller.selectProvider(id: providerAID)
        target.catalog.result = .success(["must-not-start"])

        controller.refreshModelsForTesting()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 1, "origin confirmation callback should still be pending")
        XCTAssertNotNil(target.store.provider(id: providerAID)?.confirmedCredentialOrigin)

        try controller.importConfigurationForTesting(from: url)
        main.runNext()

        XCTAssertEqual(
            target.store.provider(id: providerAID)?.displayName,
            "Imported During Origin Gate"
        )
        XCTAssertNil(target.store.provider(id: providerAID)?.confirmedCredentialOrigin)
        XCTAssertNil(target.coordinator.keys[providerAID])
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Imported During Origin Gate"
        )
        XCTAssertEqual(target.background.pendingCount, 0)
        XCTAssertTrue(target.catalog.calls.isEmpty)
    }

    func testBaseURLEditAfterOriginApprovalPersistenceCancelsOldTransportAndStillSaves() throws {
        var customProvider = alphaProvider()
        customProvider.applyUserBaseURL("https://old-custom-origin.example/v1")
        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            providers: [customProvider, betaProvider()],
            keys: [providerAID: "origin-race-secret"],
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        main.runNext()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-fetch-from-old-origin"])

        controller.refreshModelsForTesting()
        persistence.runNext()
        main.runNext()
        XCTAssertEqual(persistence.pendingCount, 1, "origin approval should be pending")
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 1, "approval persistence callback should be pending")
        XCTAssertEqual(
            fixture.store.provider(id: providerAID)?.confirmedCredentialOrigin,
            "https://old-custom-origin.example"
        )

        controller.commitBaseURLForTesting("https://new-custom-origin.example/v1")
        main.runNext()
        XCTAssertTrue(fixture.catalog.calls.isEmpty)
        XCTAssertEqual(fixture.background.pendingCount, 0)

        persistence.runNext()
        main.runNext()

        XCTAssertEqual(
            fixture.store.provider(id: providerAID)?.baseURL,
            "https://new-custom-origin.example/v1"
        )
        XCTAssertNil(fixture.store.provider(id: providerAID)?.confirmedCredentialOrigin)
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.baseURL,
            "https://new-custom-origin.example/v1"
        )
        XCTAssertTrue(fixture.catalog.calls.isEmpty)
        XCTAssertEqual(fixture.background.pendingCount, 0)
    }

    func testDisplayNameEditWinsAfterCatalogWritePersistsBeforeItsCallback() throws {
        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "catalog-race-secret"],
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        main.runNext()
        controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["catalog-before-local-edit"])

        controller.refreshModelsForTesting()
        persistence.runNext()
        main.runNext()
        fixture.background.runNext()
        main.runNext()
        XCTAssertEqual(persistence.pendingCount, 1, "catalog result persistence should be pending")
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 1, "catalog persistence callback should be pending")
        XCTAssertTrue(
            fixture.store.provider(id: providerAID)?.models.contains(where: {
                $0.id == "catalog-before-local-edit"
            }) ?? false
        )

        controller.commitDisplayNameForTesting("User Rename Wins")
        main.runNext()
        persistence.runNext()
        main.runNext()

        let persisted = try XCTUnwrap(fixture.store.provider(id: providerAID))
        XCTAssertEqual(persisted.displayName, "User Rename Wins")
        XCTAssertTrue(persisted.models.contains { $0.id == "catalog-before-local-edit" })
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID }),
            persisted
        )
        XCTAssertTrue(
            (view("Stacio.Settings.aiProviders.refreshModels", in: controller.view) as? NSButton)?
                .isEnabled ?? false
        )
    }

    func testProviderSaveAndReorderCallbacksCannotUndoEachOtherWhenDeliveredOutOfOrder() {
        let persistence = ManualProviderExecutor()
        let main = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute,
            mainExecutor: main.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        main.runNext()
        persistence.runNext()
        main.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("Renamed Before Reorder")
        XCTAssertTrue(controller.moveProviderForTesting(from: 0, to: 1))
        persistence.runNext()
        persistence.runNext()
        XCTAssertEqual(main.pendingCount, 2)

        main.run(at: 1)
        main.runNext()

        XCTAssertEqual(controller.visibleProviderIDsForTesting, [providerBID, providerAID])
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID })?.displayName,
            "Renamed Before Reorder"
        )
        XCTAssertEqual(fixture.store.envelope.aiProviders.map(\.id), [providerBID, providerAID])
    }

    func testReusedUUIDAfterDeleteAndImportDoesNotInheritOldLocalVersions() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var importedProvider = try XCTUnwrap(source.store.provider(id: providerAID))
        importedProvider.displayName = "Imported Reuse"
        source.store.replace(importedProvider)
        source.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-reused-id-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.controller.exportConfigurationForTesting(to: url)

        let persistence = ManualProviderExecutor()
        let target = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = target.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("Old Local Version")
        controller.deleteSelectedProviderForTesting()
        persistence.runNext()
        let oldLocalVersion = try XCTUnwrap(target.coordinator.saveCalls.first?.provider)
        persistence.runNext()
        XCTAssertNil(target.store.provider(id: providerAID))

        try controller.importConfigurationForTesting(from: url)
        while persistence.pendingCount > 0 {
            persistence.runNext()
        }
        controller.selectProvider(id: providerAID)
        controller.commitDisplayNameForTesting("Fresh Local Version")
        XCTAssertGreaterThanOrEqual(persistence.pendingCount, 1)
        target.store.replace(oldLocalVersion)
        while persistence.pendingCount > 0 {
            persistence.runNext()
        }

        XCTAssertEqual(
            target.coordinator.saveCalls.map(\.provider.displayName),
            ["Old Local Version"],
            "the old local version must be treated as an external conflict after identity reuse"
        )
        XCTAssertEqual(target.store.provider(id: providerAID), oldLocalVersion)
        XCTAssertEqual(
            controller.currentEnvelope.aiProviders.first(where: { $0.id == providerAID }),
            oldLocalVersion
        )
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            "Old Local Version"
        )
    }

    func testRapidQueuedSavesKeepNewestDraftWhenFirstFailsAndSecondSucceeds() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("First Rename")
        controller.commitDisplayNameForTesting("Second Rename")
        XCTAssertEqual(persistence.pendingCount, 2)

        fixture.coordinator.saveFailure = TestFailure.message("first save failed")
        persistence.runNext()
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "Alpha Provider")

        fixture.coordinator.saveFailure = nil
        persistence.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "Second Rename")
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            "Second Rename"
        )
        XCTAssertEqual(fixture.coordinator.saveCalls.map(\.provider.displayName), [
            "First Rename",
            "Second Rename"
        ])
    }

    func testThreeQueuedSavesKeepNewestDraftAcrossMiddleFailure() {
        let persistence = ManualProviderExecutor()
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            persistenceExecutor: persistence.execute
        )
        let controller = fixture.controller
        controller.loadView()
        persistence.runNext()
        persistence.runNext()
        controller.selectProvider(id: providerAID)

        controller.commitDisplayNameForTesting("First Rename")
        controller.commitDisplayNameForTesting("Second Rename")
        controller.commitDisplayNameForTesting("Third Rename")
        XCTAssertEqual(persistence.pendingCount, 3)

        persistence.runNext()
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "First Rename")

        fixture.coordinator.saveFailure = TestFailure.message("middle save failed")
        persistence.runNext()
        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "First Rename")

        fixture.coordinator.saveFailure = nil
        persistence.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID)?.displayName, "Third Rename")
        XCTAssertEqual(
            textField("Stacio.Settings.aiProviders.displayName", in: controller.view)?.stringValue,
            "Third Rename"
        )
        XCTAssertEqual(fixture.coordinator.saveCalls.map(\.provider.displayName), [
            "First Rename",
            "Second Rename",
            "Third Rename"
        ])
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

    func testProviderDragReordersAllConfiguredProviders() {
        let fixture = makeFixture(defaultProviderID: providerAID)
        let controller = fixture.controller
        controller.loadView()

        XCTAssertTrue(controller.moveProviderForTesting(from: 0, to: 1))
        XCTAssertEqual(controller.visibleProviderIDsForTesting, [providerBID, providerAID])
        XCTAssertEqual(fixture.store.envelope.aiProviders.map(\.id), [providerBID, providerAID])
    }

    func testExportOmitsAPIKeyAndImportRequiresFreshCredentialAndVerification() throws {
        let source = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "must-not-be-exported"]
        )
        source.controller.loadView()
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        try source.controller.exportConfigurationForTesting(to: exportURL)

        let exportedText = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertFalse(exportedText.contains("must-not-be-exported"))
        XCTAssertFalse(exportedText.contains("confirmedCredentialOrigin"))

        let target = makeFixture(
            defaultProviderID: providerBID,
            keys: [providerAID: "existing-local-key"]
        )
        target.controller.loadView()
        try target.controller.importConfigurationForTesting(from: exportURL)

        XCTAssertNil(target.store.provider(id: providerAID)?.lastVerifiedAt)
        XCTAssertNil(target.store.provider(id: providerAID)?.lastModelSyncAt)
        XCTAssertNil(target.store.provider(id: providerBID)?.lastVerifiedAt)
        XCTAssertNil(target.store.provider(id: providerBID)?.lastModelSyncAt)
        let imported = try XCTUnwrap(target.store.provider(id: providerAID))
        XCTAssertFalse(imported.isEnabled)
        XCTAssertTrue(imported.models.allSatisfy { $0.lastVerifiedAt == nil })
        XCTAssertTrue(imported.models.filter { !$0.isManual }.allSatisfy {
            !$0.wasReturnedByLatestCatalog
        })
        XCTAssertNil(target.coordinator.keys[providerAID])
        XCTAssertNil(imported.confirmedCredentialOrigin)
        XCTAssertEqual(target.store.envelope.defaultAIProviderID, providerAID)
    }

    func testImportClearsCraftedCredentialOriginApproval() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        fixture.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-crafted-trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.controller.exportConfigurationForTesting(to: url)

        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var providers = try XCTUnwrap(document["providers"] as? [[String: Any]])
        providers[0]["confirmedCredentialOrigin"] = "https://attacker.example"
        document["providers"] = providers
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        try fixture.controller.importConfigurationForTesting(from: url)

        XCTAssertNil(fixture.store.provider(id: providerAID)?.confirmedCredentialOrigin)
    }

    func testConfigurationExportAndImportUseBackgroundExecutor() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var importedProvider = try XCTUnwrap(source.store.provider(id: providerAID))
        importedProvider.displayName = "Imported Provider"
        source.store.replace(importedProvider)
        source.controller.loadView()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-background-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        source.controller.exportConfigurationInBackgroundForTesting(to: url)
        XCTAssertEqual(source.background.pendingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        source.background.runNext()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let target = makeFixture(defaultProviderID: providerAID)
        target.controller.loadView()
        target.controller.importConfigurationInBackgroundForTesting(from: url)
        XCTAssertEqual(target.background.pendingCount, 1)
        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Alpha Provider")
        target.background.runNext()
        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Imported Provider")
    }

    func testImportWithChangedEndpointRemovesExistingScopedKeyAndMigrationMarker() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var imported = try XCTUnwrap(source.store.provider(id: providerAID))
        imported.baseURL = "https://new.example/v1"
        source.store.replace(imported)
        source.controller.loadView()
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-endpoint-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try source.controller.exportConfigurationForTesting(to: exportURL)

        let target = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "old-host-secret"],
            legacyKeyMigrationProviderID: providerAID
        )
        target.controller.loadView()
        try target.controller.importConfigurationForTesting(from: exportURL)

        XCTAssertNil(target.coordinator.keys[providerAID])
        XCTAssertNil(target.store.envelope.legacyKeyMigrationProviderID)
        XCTAssertEqual(target.store.provider(id: providerAID)?.baseURL, "https://new.example/v1")
    }

    func testImportRejectsInvalidFormatAndOversizedPayloadBeforeMutation() throws {
        let fixture = makeFixture(defaultProviderID: providerAID)
        fixture.controller.loadView()
        let originalEnvelope = fixture.store.envelope
        let validURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-valid-\(UUID().uuidString).json")
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-invalid-\(UUID().uuidString).json")
        let oversizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-oversized-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: validURL)
            try? FileManager.default.removeItem(at: invalidURL)
            try? FileManager.default.removeItem(at: oversizedURL)
        }

        try fixture.controller.exportConfigurationForTesting(to: validURL)
        var invalidDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: validURL)) as? [String: Any]
        )
        invalidDocument["format"] = "wrong"
        try JSONSerialization.data(withJSONObject: invalidDocument).write(to: invalidURL)
        XCTAssertThrowsError(try fixture.controller.importConfigurationForTesting(from: invalidURL))
        XCTAssertEqual(fixture.store.envelope, originalEnvelope)

        try Data(repeating: 0x7F, count: 2 * 1024 * 1024 + 1).write(to: oversizedURL)
        XCTAssertThrowsError(try fixture.controller.importConfigurationForTesting(from: oversizedURL))
        XCTAssertEqual(fixture.store.envelope, originalEnvelope)
    }

    func testImportInvalidatesInFlightCatalogResult() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        source.controller.loadView()
        let importURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-inflight-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: importURL) }
        try source.controller.exportConfigurationForTesting(to: importURL)

        let target = makeFixture(defaultProviderID: providerAID, keys: [providerAID: "a-secret"])
        target.controller.loadView()
        target.controller.selectProvider(id: providerAID)
        target.catalog.result = .success(["stale-after-import"])
        target.controller.refreshModelsForTesting()
        XCTAssertEqual(target.background.pendingCount, 1)

        try target.controller.importConfigurationForTesting(from: importURL)
        target.background.runNext()

        XCTAssertFalse(
            target.store.provider(id: providerAID)?.models.contains { $0.id == "stale-after-import" }
                ?? true
        )
    }

    func testViewDisappearancePreventsPendingImportFromMutatingSettings() throws {
        let source = makeFixture(defaultProviderID: providerAID)
        var imported = try XCTUnwrap(source.store.provider(id: providerAID))
        imported.displayName = "Must Not Apply"
        source.store.replace(imported)
        source.controller.loadView()
        let importURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ai-providers-cancelled-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: importURL) }
        try source.controller.exportConfigurationForTesting(to: importURL)

        let target = makeFixture(defaultProviderID: providerAID)
        target.controller.loadView()
        target.controller.importConfigurationInBackgroundForTesting(from: importURL)
        target.controller.viewWillDisappear()
        target.background.runNext()

        XCTAssertEqual(target.store.provider(id: providerAID)?.displayName, "Alpha Provider")
    }

    func testViewDisappearancePreventsPendingCatalogResultFromMutatingSettings() throws {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"]
        )
        let original = try XCTUnwrap(fixture.store.provider(id: providerAID))
        fixture.controller.loadView()
        fixture.controller.selectProvider(id: providerAID)
        fixture.catalog.result = .success(["must-not-merge-after-view-disappears"])

        fixture.controller.refreshModelsForTesting()
        XCTAssertEqual(fixture.background.pendingCount, 1)

        fixture.controller.viewWillDisappear()
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
        XCTAssertEqual(
            fixture.controller.catalogStateForTesting(providerID: providerAID),
            .idle
        )
    }

    func testViewDisappearancePreventsPendingConnectionResultFromMutatingSettings() throws {
        let fixture = makeFixture(
            defaultProviderID: providerAID,
            keys: [providerAID: "a-secret"],
            now: Date(timeIntervalSince1970: 999)
        )
        let original = try XCTUnwrap(fixture.store.provider(id: providerAID))
        fixture.controller.loadView()
        fixture.controller.selectProvider(id: providerAID)
        fixture.connection.result = .success(.init(message: "must-not-verify-after-view-disappears"))

        fixture.controller.testConnectionForTesting()
        XCTAssertEqual(fixture.background.pendingCount, 1)

        fixture.controller.viewWillDisappear()
        fixture.background.runNext()

        XCTAssertEqual(fixture.store.provider(id: providerAID), original)
        XCTAssertTrue(fixture.coordinator.saveCalls.isEmpty)
    }
}

private let providerAID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let providerBID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
private let mozheProviderID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

@MainActor
private func makeFixture(
    defaultProviderID: UUID,
    providers: [AIProviderConfiguration]? = nil,
    keys: [UUID: String] = [:],
    now: Date = Date(timeIntervalSince1970: 1_000),
    urlOpener: RecordingProviderURLOpener? = nil,
    legacyKeyMigrationProviderID: UUID? = nil,
    credentialOriginConfirmationHandler: @escaping AIProviderCredentialOriginConfirmationHandler = { _ in true },
    persistenceExecutor: @escaping AIProviderTaskExecutor = { $0() },
    mainExecutor: @escaping AIProviderTaskExecutor = { $0() }
) -> ProviderManagerFixture {
    let urlOpener = urlOpener ?? RecordingProviderURLOpener()
    let envelope = AIProviderSettingsEnvelope(
        aiProviders: providers ?? [alphaProvider(), betaProvider()],
        defaultAIProviderID: defaultProviderID,
        legacyKeyMigrationProviderID: legacyKeyMigrationProviderID
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
        persistenceExecutor: persistenceExecutor,
        mainExecutor: mainExecutor,
        credentialOriginConfirmationHandler: credentialOriginConfirmationHandler,
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

private func alphaProvider() -> AIProviderConfiguration {
    provider(
        id: providerAID,
        name: "Alpha Provider",
        baseURL: "https://a.example/v1",
        models: [
            model("a-default", enabled: true, returned: true),
            model("a-old", enabled: false, returned: true)
        ],
        defaultModelID: "a-default"
    )
}

private func betaProvider() -> AIProviderConfiguration {
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
}

private func mozheProvider() -> AIProviderConfiguration {
    let descriptor = BundledRuntimeCatalog.shared.provider(catalogID: "provider.mozheapi")!
    var configuration = AIProviderConfiguration.catalogDraft(
        descriptor: descriptor,
        id: mozheProviderID
    )!
    configuration.models = [model("mozhe-default", enabled: true, returned: true)]
    configuration.defaultModelID = "mozhe-default"
    configuration.isEnabled = true
    return configuration
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
        lastModelSyncAt: Date(timeIntervalSince1970: 200),
        confirmedCredentialOrigin: AIProviderCredentialOriginPolicy.normalizedOrigin(
            forBaseURL: baseURL
        )
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

    func deleteProviderConfiguration(id: UUID) throws -> AIProviderSettingsEnvelope {
        try deleteProvider(id: id)
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

    func applyConfiguration(
        _ envelope: AIProviderSettingsEnvelope,
        removingAPIKeys: Set<UUID>,
        deletingProviderIDs: Set<UUID>
    ) throws -> AIProviderSettingsEnvelope {
        if let saveFailure {
            throw saveFailure
        }
        for providerID in removingAPIKeys.union(deletingProviderIDs) {
            keys[providerID] = nil
        }
        let normalized = AIProviderSettingsNormalizer.normalized(envelope)
        try store.saveAIProviderSettings(normalized)
        return normalized
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
