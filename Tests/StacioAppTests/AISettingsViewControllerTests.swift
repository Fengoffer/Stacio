import AppKit
import Foundation
@testable import StacioApp
import XCTest

@MainActor
final class AISettingsViewControllerTests: XCTestCase {
    func testAISettingsShowsFourInternalTabs() {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()

        XCTAssertEqual(controller.tabTitlesForTesting, ["模型", "上下文", "执行与权限", "历史"])
    }

    func testModelsTabMountsProviderManagerWithoutWrappingItInScrollView() {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()

        XCTAssertEqual(controller.selectedTabForTesting, .models)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Settings.ai.models.scroll"))
    }

    func testContextExecutionAndHistoryTabsMountExpectedContent() {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()

        controller.selectTabForTesting(.context)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Test.AI.Context"))

        controller.selectTabForTesting(.executionPermissions)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Test.AI.Execution"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Settings.group.agentBridge"))

        controller.selectTabForTesting(.history)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Test.AI.History"))
    }

    func testAddProviderCallbackPresentsSheetAndReloadsManagerAfterSave() throws {
        let fixture = makeFixture()
        let controller = fixture.controller
        controller.loadView()
        let savedProviderID = UUID(uuidString: "50000000-0000-0000-0000-000000000009")!

        fixture.manager.onAddProviderRequested?()
        XCTAssertEqual(controller.presentedAddProviderSheetCountForTesting, 1)

        controller.completePresentedAddProviderForTesting(providerID: savedProviderID)

        XCTAssertEqual(controller.lastReloadedProviderIDForTesting, savedProviderID)
    }

    private func makeFixture() -> AISettingsFixture {
        let envelope = AIProviderSettingsEnvelope(
            aiProviders: [
                AIProviderConfiguration(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                    profile: .openAICompatible,
                    displayName: "Team Gateway",
                    baseURL: "https://gateway.example/v1",
                    models: [
                        AIProviderModelConfiguration(
                            id: "gpt-4.1-mini",
                            isEnabled: true,
                            isManual: false,
                            wasReturnedByLatestCatalog: true
                        )
                    ],
                    defaultModelID: "gpt-4.1-mini",
                    compatibilityProtocol: .chatCompletions,
                    maxRetryCount: 1,
                    requestTimeoutSeconds: 45,
                    userAgent: "Stacio",
                    isEnabled: true,
                    lastVerifiedAt: nil,
                    lastModelSyncAt: nil
                )
            ],
            defaultAIProviderID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        let settingsStore = AISettingsStore(envelope: envelope)
        let coordinator = AISettingsCoordinator(store: settingsStore)
        let manager = AIProviderManagementViewController(
            settingsStore: settingsStore,
            mutationCoordinator: coordinator,
            modelCatalogLoader: AISettingsCatalogLoader(),
            connectionTester: AISettingsConnectionTester(),
            backgroundExecutor: { $0() },
            mainExecutor: { $0() }
        )
        let controller = AISettingsViewController(
            providerManager: manager,
            contextView: Self.labeledView(identifier: "Test.AI.Context", text: "Context"),
            executionPermissionsView: Self.executionView(),
            historyView: Self.labeledView(identifier: "Test.AI.History", text: "History"),
            addProviderSheetFactory: {
                AddAIProviderSheetController(
                    providerIDGenerator: UUID.init,
                    mutationCoordinator: coordinator,
                    modelCatalogLoader: AISettingsCatalogLoader(),
                    backgroundExecutor: { $0() },
                    mainExecutor: { $0() }
                )
            }
        )
        return AISettingsFixture(
            controller: controller,
            manager: manager,
            settingsStore: settingsStore
        )
    }

    private static func labeledView(identifier: String, text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.setAccessibilityIdentifier(identifier)
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.setAccessibilityIdentifier("\(identifier).container")
        return stack
    }

    private static func executionView() -> NSView {
        let bridge = NSTextField(labelWithString: "Agent Bridge")
        bridge.setAccessibilityIdentifier("Stacio.Settings.group.agentBridge")
        let stack = NSStackView(views: [
            labeledView(identifier: "Test.AI.Execution", text: "Execution"),
            bridge
        ])
        stack.orientation = .vertical
        return stack
    }
}

private struct AISettingsFixture {
    let controller: AISettingsViewController
    let manager: AIProviderManagementViewController
    let settingsStore: AISettingsStore
}

private final class AISettingsStore: AIProviderSettingsStoring {
    var envelope: AIProviderSettingsEnvelope

    init(envelope: AIProviderSettingsEnvelope) {
        self.envelope = envelope
    }

    func loadAIProviderSettings() throws -> AIProviderSettingsEnvelope {
        envelope
    }

    func saveAIProviderSettings(_ envelope: AIProviderSettingsEnvelope) throws {
        self.envelope = envelope
    }

}

private final class AISettingsCoordinator: AIProviderMutationCoordinating {
    private let store: AISettingsStore

    init(store: AISettingsStore) {
        self.store = store
    }

    func saveProvider(
        _ provider: AIProviderConfiguration,
        apiKeyUpdate: AIProviderAPIKeyUpdate
    ) throws -> AIProviderSettingsEnvelope {
        store.envelope.aiProviders.append(provider)
        return store.envelope
    }

    func deleteProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        store.envelope.aiProviders.removeAll { $0.id == id }
        return store.envelope
    }

    func setDefaultProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        store.envelope.defaultAIProviderID = id
        return store.envelope
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        nil
    }
}

private final class AISettingsCatalogLoader: AIModelCatalogLoading {
    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        []
    }
}

private final class AISettingsConnectionTester: AIAssistantConnectionTesting {
    func testConnection(
        provider: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) throws -> AIAssistantConnectionTestResult {
        .init(message: "ok")
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
