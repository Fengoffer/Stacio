import AppKit
import Foundation
@testable import StacioApp
import XCTest

@MainActor
final class AddAIProviderSheetControllerTests: XCTestCase {
    func testFetchFailurePreservesFieldsAndLeavesSavedDraft() throws {
        let fixture = makeFixture()
        fixture.loader.result = .failure(AIAssistantProviderError.timeout)
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "secret"
        )
        controller.fetchModelsForTesting()

        XCTAssertEqual(controller.nameForTesting, "Team Gateway")
        XCTAssertEqual(controller.baseURLForTesting, "https://gateway.example/v1")
        XCTAssertTrue(controller.canSaveForTesting)
        XCTAssertTrue(controller.statusTextForTesting.contains("超时"))
        XCTAssertFalse(controller.statusTextForTesting.contains("secret"))
        XCTAssertEqual(fixture.coordinator.apiKeyUpdates, [.replace("secret")])
    }

    func testEmptyFetchResponseIsFailureAndMarksPreviouslyFetchedModelsStale() {
        let fixture = makeFixture()
        fixture.loader.results = [
            .success(["old-model"]),
            .success([])
        ]
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "secret"
        )

        controller.fetchModelsForTesting()
        controller.setDefaultModelForTesting("old-model")
        controller.fetchModelsForTesting()

        XCTAssertEqual(controller.modelIDsForTesting, ["old-model"])
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false])
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertTrue(controller.statusTextForTesting.contains("无法解析"))
        XCTAssertFalse(controller.statusTextForTesting.contains("获取成功"))
    }

    func testDraftCanSaveWithoutFetchOrModel() {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: ""
        )

        XCTAssertTrue(controller.canSaveForTesting)
    }

    func testEditingRequiredFieldsDoesNotEnableFetchBeforeCredentialIsPresent() throws {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
        controller.selectProviderForTesting(catalogID: "provider.openai.com")
        let nameField = try XCTUnwrap(
            controller.view.firstSubview(
                withIdentifier: "Stacio.Settings.addAIProvider.displayName"
            ) as? NSTextField
        )
        let baseURLField = try XCTUnwrap(
            controller.view.firstSubview(
                withIdentifier: "Stacio.Settings.addAIProvider.baseURL"
            ) as? NSTextField
        )

        nameField.stringValue = "OpenAI Team"
        baseURLField.stringValue = "https://api.openai.com/v1"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: baseURLField)
        )

        XCTAssertTrue(controller.canSaveForTesting)
        XCTAssertFalse(controller.canFetchModelsForTesting)
        XCTAssertFalse(controller.fetchModelsButtonEnabledForTesting)
    }

    func testActiveFetchKeepsUnverifiedSaveDisabledUntilFailureCompletes() {
        let background = ManualAddProviderExecutor()
        let fixture = makeFixture(backgroundExecutor: background.execute)
        fixture.loader.result = .failure(AIAssistantProviderError.timeout)
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "secret"
        )

        controller.fetchModelsForTesting()

        XCTAssertEqual(background.pendingCount, 1)
        XCTAssertFalse(controller.canSaveForTesting)

        background.runNext()

        XCTAssertTrue(controller.canSaveForTesting)
        XCTAssertTrue(controller.statusTextForTesting.contains("超时"))
    }

    func testAPIKeyEditRejectsInflightFetchResult() {
        let background = ManualAddProviderExecutor()
        let main = ManualAddProviderExecutor()
        let fixture = makeFixture(
            backgroundExecutor: background.execute,
            mainExecutor: main.execute
        )
        fixture.loader.result = .success(["stale-model"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "old-secret"
        )

        controller.fetchModelsForTesting()
        background.runNext()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "new-secret"
        )
        main.runNext()

        XCTAssertEqual(controller.modelIDsForTesting, [])
        XCTAssertEqual(controller.statusTextForTesting, L10n.Settings.addAIProviderReady)
        XCTAssertTrue(controller.canSaveForTesting)
    }

    func testNewFetchSupersedesOldRequestWithoutApplyingStaleModels() {
        let background = ManualAddProviderExecutor()
        let main = ManualAddProviderExecutor()
        let fixture = makeFixture(
            backgroundExecutor: background.execute,
            mainExecutor: main.execute
        )
        fixture.loader.results = [
            .success(["stale-model"]),
            .success(["fresh-model"])
        ]
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "First Gateway",
            baseURL: "https://first.example/v1",
            apiKey: "first-secret"
        )

        controller.fetchModelsForTesting()
        background.runNext()
        controller.setDraft(
            name: "Second Gateway",
            baseURL: "https://second.example/v1",
            apiKey: "second-secret"
        )
        controller.fetchModelsForTesting()
        background.runNext()

        main.runNext()

        XCTAssertEqual(controller.modelIDsForTesting, [])
        XCTAssertEqual(controller.statusTextForTesting, L10n.Settings.addAIProviderFetching)
        XCTAssertFalse(controller.canSaveForTesting)

        main.runNext()

        XCTAssertEqual(controller.modelIDsForTesting, ["fresh-model"])
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertTrue(controller.canSaveForTesting)
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false])
        XCTAssertEqual(fixture.loader.calls.map(\.provider.baseURL), [
            "https://first.example/v1",
            "https://second.example/v1"
        ])
    }

    func testFetchedModelsRemainDisabledUntilUserSelectsOne() throws {
        let background = ManualAddProviderExecutor()
        let main = ManualAddProviderExecutor()
        let fixture = makeFixture(
            backgroundExecutor: background.execute,
            mainExecutor: main.execute
        )
        fixture.loader.result = .success(["gpt-4.1-mini", "qwen2.5-coder"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )

        controller.fetchModelsForTesting()
        background.runNext()
        main.runNext()

        XCTAssertEqual(
            controller.modelIDsForTesting,
            ["gpt-4.1-mini", "qwen2.5-coder"]
        )
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false, false])
        XCTAssertTrue(controller.canSaveForTesting)

        controller.setDefaultModelForTesting("qwen2.5-coder")
        controller.saveForTesting()
        background.runNext()
        main.runNext()

        let savedProvider = try XCTUnwrap(fixture.coordinator.savedProviders.last)
        XCTAssertEqual(
            savedProvider.models.map(\.id),
            ["gpt-4.1-mini", "qwen2.5-coder"]
        )
        XCTAssertEqual(savedProvider.defaultModelID, "qwen2.5-coder")
        XCTAssertFalse(savedProvider.isEnabled)
    }

    func testFirstEnabledFetchedModelBecomesDefaultForVerification() {
        let fixture = makeFixture()
        fixture.loader.result = .success(["gpt-4.1-mini", "qwen2.5-coder"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )

        controller.fetchModelsForTesting()
        controller.setModelEnabledForTesting("gpt-4.1-mini", isEnabled: true)

        XCTAssertEqual(controller.defaultModelIDForTesting, "gpt-4.1-mini")
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [true, false])
    }

    func testSuccessfulRefreshDisablesRemovedModelAndClearsItsDefault() {
        let fixture = makeFixture()
        fixture.loader.results = [
            .success(["old-model"]),
            .success(["new-model"])
        ]
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )

        controller.fetchModelsForTesting()
        controller.setDefaultModelForTesting("old-model")
        controller.fetchModelsForTesting()

        XCTAssertEqual(controller.modelIDsForTesting, ["old-model", "new-model"])
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false, false])
        XCTAssertNil(controller.defaultModelIDForTesting)
    }

    func testCatalogSelectionCopiesOnlySuggestionAndKeepsModelsEmpty() throws {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
        let profilePopup = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.profile") as? NSPopUpButton
        )
        let nameField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.displayName") as? NSTextField
        )
        let baseURLField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.baseURL") as? NSTextField
        )

        profilePopup.selectItem(withTitle: "OpenAI")
        profilePopup.sendAction(profilePopup.action, to: profilePopup.target)
        XCTAssertEqual(controller.nameForTesting, "OpenAI")
        XCTAssertEqual(controller.baseURLForTesting, "https://api.openai.com/v1")
        XCTAssertEqual(controller.catalogIDForTesting, "provider.openai.com")
        XCTAssertEqual(controller.modelIDsForTesting, [])
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertTrue(controller.canSaveForTesting)

        profilePopup.selectItem(withTitle: "DeepSeek")
        profilePopup.sendAction(profilePopup.action, to: profilePopup.target)
        XCTAssertEqual(controller.nameForTesting, "DeepSeek")
        XCTAssertEqual(controller.baseURLForTesting, "https://api.deepseek.com/v1")
        XCTAssertEqual(controller.modelIDsForTesting, [], "模型区为空")
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertTrue(controller.canSaveForTesting)

        nameField.stringValue = "Private DeepSeek"
        nameField.sendAction(nameField.action, to: nameField.target)
        baseURLField.stringValue = "https://deepseek-proxy.example/v1"
        baseURLField.sendAction(baseURLField.action, to: baseURLField.target)

        XCTAssertEqual(controller.nameForTesting, "Private DeepSeek")
        XCTAssertEqual(controller.baseURLForTesting, "https://deepseek-proxy.example/v1")
    }

    func testEmptyModelListUsesOneCenteredEmptyStateInsteadOfPlaceholderRows() throws {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
        let table = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.modelTable") as? NSTableView
        )
        let emptyState = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.modelEmptyState") as? NSTextField
        )

        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertFalse(emptyState.isHidden)
        XCTAssertEqual(emptyState.stringValue, L10n.Settings.addAIProviderNoModels)

        fixture.loader.result = .success(["gpt-4.1-mini"])
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )
        controller.fetchModelsForTesting()

        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(emptyState.isHidden)
    }

    func testUnselectedProviderCollapsesConditionalRows() throws {
        let controller = makeFixture().controller
        controller.loadView()
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: 600, height: 540))
        controller.view.layoutSubtreeIfNeeded()

        let baseURLField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.baseURL")
        )
        let modelSearchField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.modelSearch")
        )
        let baseURLFrame = baseURLField.convert(baseURLField.bounds, to: controller.view)
        let modelSearchFrame = modelSearchField.convert(modelSearchField.bounds, to: controller.view)

        XCTAssertLessThanOrEqual(
            baseURLFrame.minY - modelSearchFrame.maxY,
            18,
            "Hidden website, credential, and fetch rows must not leave an empty block"
        )
        XCTAssertTrue(controller.isAPIKeyHiddenForTesting)
        XCTAssertNil(controller.websiteButtonTitleForTesting)
    }

    func testModelSearchFiltersRowsWithoutMutatingModelsOrDefault() throws {
        let fixture = makeFixture()
        fixture.loader.result = .success(["gpt-4.1-mini", "qwen2.5-coder", "deepseek-chat"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )
        controller.fetchModelsForTesting()
        let searchField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.modelSearch") as? NSSearchField
        )
        let table = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.modelTable") as? NSTableView
        )

        searchField.stringValue = "qwen"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField)
        )

        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(controller.modelIDsForTesting, ["gpt-4.1-mini", "qwen2.5-coder", "deepseek-chat"])
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false, false, false])

        searchField.stringValue = ""
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField)
        )

        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(controller.modelIDsForTesting, ["gpt-4.1-mini", "qwen2.5-coder", "deepseek-chat"])
        XCTAssertNil(controller.defaultModelIDForTesting)
    }

    func testDeclaredSheetSizeContainsFittingContentWithoutClippingOrOverlap() throws {
        let declaredSize = NSSize(width: 600, height: 540)
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
        controller.selectProviderForTesting(catalogID: "provider.openai.com")
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(declaredSize)
        let content = try XCTUnwrap(window.contentView)

        content.updateConstraintsForSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(content.bounds.size.width, declaredSize.width, accuracy: 0.5)
        XCTAssertEqual(content.bounds.size.height, declaredSize.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.width, declaredSize.width + 0.5)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.height, declaredSize.height + 0.5)

        let orderedIdentifiers = [
            "Stacio.Settings.addAIProvider.profile",
            "Stacio.Settings.addAIProvider.displayName",
            "Stacio.Settings.addAIProvider.baseURL",
            "Stacio.Settings.addAIProvider.website",
            "Stacio.Settings.addAIProvider.apiKey",
            "Stacio.Settings.addAIProvider.fetchModels",
            "Stacio.Settings.addAIProvider.modelSearch",
            "Stacio.Settings.addAIProvider.models",
            "Stacio.Settings.addAIProvider.status",
            "Stacio.Settings.addAIProvider.save"
        ]
        let orderedFrames = try orderedIdentifiers.map { identifier -> NSRect in
            let child = try XCTUnwrap(controller.view.firstSubview(withIdentifier: identifier), identifier)
            let frame = child.convert(child.bounds, to: controller.view)
            XCTAssertTrue(
                controller.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "\(identifier) is clipped outside the declared sheet: \(frame)"
            )
            return frame
        }

        for index in 0..<(orderedFrames.count - 1) {
            XCTAssertGreaterThanOrEqual(
                orderedFrames[index].minY,
                orderedFrames[index + 1].maxY - 0.5,
                "\(orderedIdentifiers[index]) overlaps \(orderedIdentifiers[index + 1])"
            )
        }

        let profileToNameGap = orderedFrames[0].minY - orderedFrames[1].maxY
        XCTAssertGreaterThanOrEqual(
            profileToNameGap,
            8,
            "Provider form rows need enough breathing room to remain visually distinct"
        )
        XCTAssertLessThanOrEqual(
            profileToNameGap,
            16,
            "The provider row must not absorb the sheet's remaining vertical space"
        )

        let modelScrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.models") as? NSScrollView
        )
        let cancelButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.cancel") as? NSButton
        )
        let saveButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.save") as? NSButton
        )
        func alignmentFrame(_ view: NSView) -> NSRect {
            let alignmentRect = view.alignmentRect(forFrame: view.bounds)
            return view.convert(alignmentRect, to: controller.view)
        }
        let cancelFrame = alignmentFrame(cancelButton)
        let saveFrame = alignmentFrame(saveButton)

        XCTAssertTrue(modelScrollView.hasVerticalScroller)
        XCTAssertLessThan(cancelFrame.maxX, saveFrame.minX)
        XCTAssertEqual(saveFrame.maxX, controller.view.bounds.maxX - 22, accuracy: 1.5)
    }

    func testSuccessfulFetchSavesCredentialBeforeFetchingAndLeavesModelsUnselected() throws {
        let fixture = makeFixture()
        fixture.loader.result = .success(["gpt-4.1-mini", "qwen2.5-coder"])
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "sk-team-secret"
        )
        controller.fetchModelsForTesting()
        controller.saveForTesting()

        XCTAssertEqual(controller.modelIDsForTesting, ["gpt-4.1-mini", "qwen2.5-coder"])
        XCTAssertNil(controller.defaultModelIDForTesting)
        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false, false])
        XCTAssertEqual(fixture.coordinator.savedProviders.count, 3)
        XCTAssertEqual(fixture.coordinator.savedProviders.last?.displayName, "Team Gateway")
        XCTAssertEqual(fixture.coordinator.savedProviders.last?.baseURL, "https://gateway.example/v1")
        XCTAssertEqual(fixture.coordinator.savedProviders.last?.models.map(\.id), ["gpt-4.1-mini", "qwen2.5-coder"])
        XCTAssertNil(fixture.coordinator.savedProviders.last?.defaultModelID)
        XCTAssertFalse(fixture.coordinator.savedProviders.last?.isEnabled ?? true)
        XCTAssertEqual(fixture.coordinator.apiKeyUpdates, [.replace("sk-team-secret"), .unchanged, .unchanged])
        XCTAssertFalse(String(describing: fixture.coordinator.savedProviders.last).contains("sk-team-secret"))
    }

    func testFetchedModelsMayRemainUnselectedInSavedDraft() {
        let fixture = makeFixture()
        fixture.loader.result = .success(["gpt-4.1-mini"])
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )
        controller.fetchModelsForTesting()
        controller.clearDefaultModelForTesting()

        XCTAssertTrue(controller.canSaveForTesting)
    }

    func testManualModelIsDraftOnlyForCustomNoEnumerationProvider() throws {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
        controller.selectProviderForTesting(catalogID: "provider.openai-compatible.custom")

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: ""
        )
        controller.fetchModelsForTesting()
        controller.addManualModelForTesting("custom-model")
        controller.saveForTesting()

        XCTAssertEqual(fixture.coordinator.savedProviders.first?.models.map(\.id), ["custom-model"])
        XCTAssertNil(fixture.coordinator.savedProviders.first?.defaultModelID)
        XCTAssertFalse(fixture.coordinator.savedProviders.first?.isEnabled ?? true)
        XCTAssertEqual(fixture.coordinator.apiKeyUpdates, [.unchanged])
    }

    func testNativeCodingPlanCopiesEditableURLAndUsesRealModelFetchFlow() throws {
        let fixture = makeFixture()
        fixture.loader.result = .success(["upstream-plan-model"])
        let controller = fixture.controller
        controller.loadView()

        controller.selectProviderForTesting(catalogID: "coding-plan.kimi-code")
        XCTAssertEqual(controller.nameForTesting, "Kimi Code")
        XCTAssertEqual(controller.baseURLForTesting, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(controller.modelIDsForTesting, [])

        controller.setDraft(
            name: "Kimi Team Plan",
            baseURL: "https://plan-proxy.example/v1",
            apiKey: "plan-secret"
        )
        controller.fetchModelsForTesting()
        controller.saveForTesting()

        let saved = try XCTUnwrap(fixture.coordinator.savedProviders.last)
        XCTAssertEqual(saved.catalogID, "coding-plan.kimi-code")
        XCTAssertEqual(saved.effectiveRuntimeConfigurationKind, .codingPlan)
        XCTAssertEqual(saved.baseURL, "https://plan-proxy.example/v1")
        XCTAssertEqual(saved.models.map(\.id), ["upstream-plan-model"])
        XCTAssertFalse(String(describing: saved).contains("plan-secret"))
    }

    func testCancelRemovesCredentialBackedDraftCreatedForModelFetch() {
        let fixture = makeFixture()
        fixture.loader.result = .failure(AIAssistantProviderError.timeout)
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Temporary Provider",
            baseURL: "https://temporary.example/v1",
            apiKey: "temporary-secret"
        )

        controller.fetchModelsForTesting()
        controller.cancelForTesting()

        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [
            UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        ])
        XCTAssertNil(try? fixture.coordinator.readAPIKey(
            for: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        ))
    }

    func testCustomOriginCancellationPerformsNoSaveKeyWriteOrNetwork() {
        var requests: [AIProviderCredentialOriginConfirmationRequest] = []
        let fixture = makeFixture(credentialOriginConfirmationHandler: { request in
            requests.append(request)
            return false
        })
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Cancelled Gateway",
            baseURL: "https://cancelled.example:8443/v1",
            apiKey: "must-not-persist"
        )

        controller.fetchModelsForTesting()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.providerName, "Cancelled Gateway")
        XCTAssertEqual(requests.first?.origin, "https://cancelled.example:8443")
        XCTAssertTrue(fixture.coordinator.savedProviders.isEmpty)
        XCTAssertTrue(fixture.coordinator.apiKeyUpdates.isEmpty)
        XCTAssertTrue(fixture.loader.calls.isEmpty)
        XCTAssertEqual(controller.statusTextForTesting, L10n.Settings.aiCredentialOriginCancelled)
    }

    func testCustomOriginConfirmationIsPersistedBeforeModelRequest() throws {
        var requests: [AIProviderCredentialOriginConfirmationRequest] = []
        let fixture = makeFixture(credentialOriginConfirmationHandler: { request in
            requests.append(request)
            return true
        })
        fixture.loader.result = .success(["confirmed-model"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Confirmed Gateway",
            baseURL: "HTTPS://Confirmed.Example:443/custom/v1",
            apiKey: "confirmed-secret"
        )

        controller.fetchModelsForTesting()

        XCTAssertEqual(requests.map(\.origin), ["https://confirmed.example"])
        let persistedBeforeRequest = try XCTUnwrap(fixture.coordinator.savedProviders.first)
        XCTAssertEqual(persistedBeforeRequest.confirmedCredentialOrigin, "https://confirmed.example")
        XCTAssertEqual(fixture.loader.calls.first?.provider.confirmedCredentialOrigin, "https://confirmed.example")
        XCTAssertEqual(fixture.loader.calls.first?.apiKey, "confirmed-secret")
    }

    func testOfficialSuggestedOriginDoesNotPromptForModelDiscovery() {
        var confirmationCount = 0
        let fixture = makeFixture(credentialOriginConfirmationHandler: { _ in
            confirmationCount += 1
            return true
        })
        fixture.loader.result = .success(["official-model"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProviderForTesting(catalogID: "provider.openai.com")
        controller.setDraft(
            name: "OpenAI",
            baseURL: "https://api.openai.com/alternate/path",
            apiKey: "official-secret"
        )

        controller.fetchModelsForTesting()

        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(fixture.loader.calls.count, 1)
        XCTAssertNil(fixture.loader.calls.first?.provider.confirmedCredentialOrigin)
    }

    func testPathOnlyEditKeepsConfirmationButOriginEditClearsIt() {
        var confirmedOrigins: [String] = []
        let fixture = makeFixture(credentialOriginConfirmationHandler: { request in
            confirmedOrigins.append(request.origin)
            return true
        })
        fixture.loader.result = .success(["custom-model"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Custom",
            baseURL: "https://custom.example/v1",
            apiKey: "secret"
        )
        controller.fetchModelsForTesting()

        controller.setDraft(
            name: "Custom",
            baseURL: "https://custom.example/another/path",
            apiKey: "secret"
        )
        controller.fetchModelsForTesting()

        XCTAssertEqual(confirmedOrigins, ["https://custom.example"])
        XCTAssertEqual(
            fixture.coordinator.savedProviders.last?.confirmedCredentialOrigin,
            "https://custom.example"
        )

        controller.setDraft(
            name: "Custom",
            baseURL: "https://other.example/v1",
            apiKey: "secret"
        )
        controller.saveForTesting()

        XCTAssertEqual(confirmedOrigins, ["https://custom.example"])
        XCTAssertNil(fixture.coordinator.savedProviders.last?.confirmedCredentialOrigin)
    }

    func testSwitchingProviderAfterFetchRemovesTemporarilyPersistedCredential() throws {
        let providerID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let fixture = makeFixture(providerID: providerID)
        fixture.loader.result = .success(["temporary-model"])
        let controller = fixture.controller
        controller.loadView()
        controller.selectProviderForTesting(catalogID: "provider.openai.com")
        controller.setDraft(
            name: "OpenAI Temporary",
            baseURL: "https://api.openai.com/v1",
            apiKey: "openai-secret"
        )
        controller.fetchModelsForTesting()
        XCTAssertEqual(try fixture.coordinator.readAPIKey(for: providerID), "openai-secret")

        controller.selectProviderForTesting(catalogID: "provider.deepseek.com")
        controller.setDraft(
            name: "DeepSeek Draft",
            baseURL: "https://api.deepseek.com/v1",
            apiKey: ""
        )
        controller.saveForTesting()

        XCTAssertEqual(fixture.coordinator.savedProviders.last?.catalogID, "provider.deepseek.com")
        XCTAssertEqual(fixture.coordinator.apiKeyUpdates.last, .unchanged)
        XCTAssertEqual(fixture.coordinator.deletedProviderIDs, [providerID])
        XCTAssertNil(try fixture.coordinator.readAPIKey(for: providerID))
    }

    func testFailedRefreshMarksPreviouslyFetchedModelsStale() {
        let fixture = makeFixture()
        fixture.loader.results = [
            .success(["old-model"]),
            .failure(AIAssistantProviderError.timeout)
        ]
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )

        controller.fetchModelsForTesting()
        controller.setDefaultModelForTesting("old-model")
        controller.fetchModelsForTesting()

        XCTAssertEqual(controller.modelEnabledStatesForTesting, [false])
        XCTAssertNil(controller.defaultModelIDForTesting)
    }

    private func makeFixture(
        providerID: UUID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
        backgroundExecutor: @escaping AIProviderTaskExecutor = { $0() },
        mainExecutor: @escaping AIProviderTaskExecutor = { $0() },
        credentialOriginConfirmationHandler: @escaping AIProviderCredentialOriginConfirmationHandler = { _ in true }
    ) -> AddProviderFixture {
        let coordinator = AddProviderCoordinator()
        let loader = AddProviderCatalogLoader()
        let controller = AddAIProviderSheetController(
            providerIDGenerator: { providerID },
            mutationCoordinator: coordinator,
            modelCatalogLoader: loader,
            credentialOriginConfirmationHandler: credentialOriginConfirmationHandler,
            backgroundExecutor: backgroundExecutor,
            mainExecutor: mainExecutor
        )
        return AddProviderFixture(
            controller: controller,
            coordinator: coordinator,
            loader: loader
        )
    }
}

private struct AddProviderFixture {
    let controller: AddAIProviderSheetController
    let coordinator: AddProviderCoordinator
    let loader: AddProviderCatalogLoader
}

private final class AddProviderCoordinator: AIProviderMutationCoordinating {
    private(set) var savedProviders: [AIProviderConfiguration] = []
    private(set) var apiKeyUpdates: [AIProviderAPIKeyUpdate] = []
    private var apiKeys: [UUID: String] = [:]
    private(set) var deletedProviderIDs: [UUID] = []

    func saveProvider(
        _ provider: AIProviderConfiguration,
        apiKeyUpdate: AIProviderAPIKeyUpdate
    ) throws -> AIProviderSettingsEnvelope {
        savedProviders.append(provider)
        apiKeyUpdates.append(apiKeyUpdate)
        switch apiKeyUpdate {
        case let .replace(value):
            apiKeys[provider.id] = value
        case .remove:
            apiKeys.removeValue(forKey: provider.id)
        case .unchanged:
            break
        }
        return AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
    }

    func deleteProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        deletedProviderIDs.append(id)
        apiKeys.removeValue(forKey: id)
        return .rulesOnly
    }

    func deleteProviderConfiguration(id: UUID) throws -> AIProviderSettingsEnvelope {
        deletedProviderIDs.append(id)
        return .rulesOnly
    }

    func setDefaultProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        .rulesOnly
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        apiKeys[providerID]
    }
}

private final class AddProviderCatalogLoader: AIModelCatalogLoading {
    var result: Result<[String], Error> = .success([])
    var results: [Result<[String], Error>] = []
    private(set) var calls: [(provider: AIProviderConfiguration, apiKey: String?)] = []

    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        calls.append((provider, apiKey))
        if results.isEmpty == false {
            return try results.removeFirst().get()
        }
        return try result.get()
    }
}

private final class ManualAddProviderExecutor {
    private var operations: [() -> Void] = []

    var pendingCount: Int {
        operations.count
    }

    func execute(_ operation: @escaping () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        operations.removeFirst()()
    }
}

@MainActor
private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
