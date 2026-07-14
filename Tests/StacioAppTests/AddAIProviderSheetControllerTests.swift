import AppKit
import Foundation
@testable import StacioApp
import XCTest

@MainActor
final class AddAIProviderSheetControllerTests: XCTestCase {
    func testFetchFailurePreservesFieldsAndAllowsUnverifiedSave() throws {
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
    }

    func testCannotSaveUnverifiedProviderBeforeFetchOrManualModel() {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: ""
        )

        XCTAssertFalse(controller.canSaveForTesting)
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
        XCTAssertFalse(controller.canSaveForTesting)
    }

    func testNewFetchSupersedesOldRequestWithoutClearingActiveStatus() {
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
        XCTAssertEqual(controller.defaultModelIDForTesting, "fresh-model")
        XCTAssertTrue(controller.canSaveForTesting)
        XCTAssertEqual(fixture.loader.calls.map(\.provider.baseURL), [
            "https://first.example/v1",
            "https://second.example/v1"
        ])
    }

    func testFetchResultMergesManualModelAddedWhileRequestIsInFlight() throws {
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
            apiKey: ""
        )

        controller.fetchModelsForTesting()
        background.runNext()
        controller.addManualModelForTesting("custom-model")
        main.runNext()

        XCTAssertEqual(
            controller.modelIDsForTesting,
            ["custom-model", "gpt-4.1-mini", "qwen2.5-coder"]
        )
        XCTAssertEqual(controller.defaultModelIDForTesting, "custom-model")
        XCTAssertTrue(controller.canSaveForTesting)

        controller.saveForTesting()

        let savedProvider = try XCTUnwrap(fixture.coordinator.savedProviders.first)
        XCTAssertEqual(
            savedProvider.models.map(\.id),
            ["custom-model", "gpt-4.1-mini", "qwen2.5-coder"]
        )
        XCTAssertEqual(savedProvider.defaultModelID, "custom-model")
    }

    func testTemplateSwitchAppliesSelectedDefaultsAndStillAllowsFieldEditing() throws {
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

        profilePopup.selectItem(withTitle: AIProviderProfile.openAI.displayName)
        profilePopup.sendAction(profilePopup.action, to: profilePopup.target)
        XCTAssertEqual(controller.nameForTesting, AIProviderProfile.openAI.displayName)
        XCTAssertEqual(controller.baseURLForTesting, AIProviderProfile.openAI.defaultBaseURL)
        XCTAssertEqual(controller.modelIDsForTesting, AIProviderProfile.openAI.suggestedModels)
        XCTAssertEqual(controller.defaultModelIDForTesting, AIProviderProfile.openAI.defaultModel)
        XCTAssertFalse(controller.canSaveForTesting)

        profilePopup.selectItem(withTitle: AIProviderProfile.deepSeek.displayName)
        profilePopup.sendAction(profilePopup.action, to: profilePopup.target)
        XCTAssertEqual(controller.nameForTesting, AIProviderProfile.deepSeek.displayName)
        XCTAssertEqual(controller.baseURLForTesting, AIProviderProfile.deepSeek.defaultBaseURL)
        XCTAssertEqual(controller.modelIDsForTesting, AIProviderProfile.deepSeek.suggestedModels)
        XCTAssertEqual(controller.defaultModelIDForTesting, AIProviderProfile.deepSeek.defaultModel)
        XCTAssertFalse(controller.canSaveForTesting)

        nameField.stringValue = "Private DeepSeek"
        nameField.sendAction(nameField.action, to: nameField.target)
        baseURLField.stringValue = "https://deepseek-proxy.example/v1"
        baseURLField.sendAction(baseURLField.action, to: baseURLField.target)

        XCTAssertEqual(controller.nameForTesting, "Private DeepSeek")
        XCTAssertEqual(controller.baseURLForTesting, "https://deepseek-proxy.example/v1")
    }

    func testModelSearchFiltersRowsWithoutMutatingModelsOrDefault() throws {
        let fixture = makeFixture()
        fixture.loader.result = .success(["gpt-4.1-mini", "qwen2.5-coder", "deepseek-chat"])
        let controller = fixture.controller
        controller.loadView()
        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: ""
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
        XCTAssertEqual(controller.defaultModelIDForTesting, "gpt-4.1-mini")

        searchField.stringValue = ""
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField)
        )

        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(controller.modelIDsForTesting, ["gpt-4.1-mini", "qwen2.5-coder", "deepseek-chat"])
        XCTAssertEqual(controller.defaultModelIDForTesting, "gpt-4.1-mini")
    }

    func testDeclaredSheetSizeContainsFittingContentWithoutClippingOrOverlap() throws {
        let declaredSize = NSSize(width: 560, height: 550)
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
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
            "Stacio.Settings.addAIProvider.apiKey",
            "Stacio.Settings.addAIProvider.fetchModels",
            "Stacio.Settings.addAIProvider.modelSearch",
            "Stacio.Settings.addAIProvider.models",
            "Stacio.Settings.addAIProvider.manualModel",
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

        let modelScrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.models") as? NSScrollView
        )
        let cancelButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.cancel") as? NSButton
        )
        let saveButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Settings.addAIProvider.save") as? NSButton
        )
        let cancelFrame = cancelButton.convert(cancelButton.bounds, to: controller.view)
        let saveFrame = saveButton.convert(saveButton.bounds, to: controller.view)

        XCTAssertTrue(modelScrollView.hasVerticalScroller)
        XCTAssertLessThan(cancelFrame.maxX, saveFrame.minX)
        XCTAssertEqual(saveFrame.maxX, controller.view.bounds.maxX - 22, accuracy: 1.5)
    }

    func testSuccessfulFetchEnablesModelsSelectsDefaultAndSavesScopedKey() throws {
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
        XCTAssertEqual(controller.defaultModelIDForTesting, "gpt-4.1-mini")
        XCTAssertEqual(fixture.coordinator.savedProviders.count, 1)
        XCTAssertEqual(fixture.coordinator.savedProviders.first?.displayName, "Team Gateway")
        XCTAssertEqual(fixture.coordinator.savedProviders.first?.baseURL, "https://gateway.example/v1")
        XCTAssertEqual(fixture.coordinator.savedProviders.first?.models.map(\.id), ["gpt-4.1-mini", "qwen2.5-coder"])
        XCTAssertEqual(fixture.coordinator.savedProviders.first?.defaultModelID, "gpt-4.1-mini")
        XCTAssertTrue(fixture.coordinator.savedProviders.first?.isEnabled ?? false)
        XCTAssertEqual(fixture.coordinator.apiKeyUpdates, [.replace("sk-team-secret")])
        XCTAssertFalse(String(describing: fixture.coordinator.savedProviders.first).contains("sk-team-secret"))
    }

    func testEnabledFetchedModelsRequireDefaultBeforeSaving() {
        let fixture = makeFixture()
        fixture.loader.result = .success(["gpt-4.1-mini"])
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: ""
        )
        controller.fetchModelsForTesting()
        controller.clearDefaultModelForTesting()

        XCTAssertFalse(controller.canSaveForTesting)
    }

    func testManualModelAllowsSaveAfterFailedFetch() throws {
        let fixture = makeFixture()
        fixture.loader.result = .failure(AIAssistantProviderError.invalidResponse)
        let controller = fixture.controller
        controller.loadView()

        controller.setDraft(
            name: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            apiKey: ""
        )
        controller.fetchModelsForTesting()
        controller.addManualModelForTesting("custom-model")
        controller.saveForTesting()

        XCTAssertEqual(fixture.coordinator.savedProviders.first?.models.map(\.id), ["custom-model"])
        XCTAssertEqual(fixture.coordinator.savedProviders.first?.defaultModelID, "custom-model")
        XCTAssertEqual(fixture.coordinator.apiKeyUpdates, [.unchanged])
    }

    private func makeFixture(
        providerID: UUID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
        backgroundExecutor: @escaping AIProviderTaskExecutor = { $0() },
        mainExecutor: @escaping AIProviderTaskExecutor = { $0() }
    ) -> AddProviderFixture {
        let coordinator = AddProviderCoordinator()
        let loader = AddProviderCatalogLoader()
        let controller = AddAIProviderSheetController(
            providerIDGenerator: { providerID },
            mutationCoordinator: coordinator,
            modelCatalogLoader: loader,
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

    func saveProvider(
        _ provider: AIProviderConfiguration,
        apiKeyUpdate: AIProviderAPIKeyUpdate
    ) throws -> AIProviderSettingsEnvelope {
        savedProviders.append(provider)
        apiKeyUpdates.append(apiKeyUpdate)
        return AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
    }

    func deleteProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        .rulesOnly
    }

    func setDefaultProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        .rulesOnly
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        nil
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
