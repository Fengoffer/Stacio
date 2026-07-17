import StacioAgentBridge
import XCTest
@testable import StacioApp

final class AIProviderRuntimeResolverTests: XCTestCase {
    private let providerAID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let providerBID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    func testRuntimeResolverDistinguishesSameModelIDAcrossProviders() {
        let providerA = makeProvider(id: providerAID, modelIDs: ["shared"])
        let providerB = makeProvider(id: providerBID, modelIDs: ["shared"])
        let envelope = makeEnvelope(providers: [providerA, providerB], defaultProviderID: providerA.id)

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: providerB.id, modelID: "shared")
            ),
            .external(provider: providerB, modelID: "shared")
        )
    }

    func testRuntimeResolverUsesValidRequestedSelectionBeforeGlobalDefault() {
        let providerA = makeProvider(id: providerAID, modelIDs: ["a-model"])
        let providerB = makeProvider(id: providerBID, modelIDs: ["b-model"])
        let envelope = makeEnvelope(providers: [providerA, providerB], defaultProviderID: providerA.id)

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: providerB.id, modelID: "b-model")
            ),
            .external(provider: providerB, modelID: "b-model")
        )
    }

    func testRuntimeResolverFallsBackToGlobalDefaultForInvalidRequestedSelection() {
        let providerA = makeProvider(id: providerAID, modelIDs: ["a-model"])
        let providerB = makeProvider(id: providerBID, modelIDs: ["b-model"])
        let envelope = makeEnvelope(providers: [providerA, providerB], defaultProviderID: providerA.id)

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: providerB.id, modelID: "missing-model")
            ),
            .external(provider: providerA, modelID: "a-model")
        )
    }

    func testRuntimeResolverReturnsUnconfiguredMozheAPIWhenGlobalDefaultIsInvalid() {
        let disabledProvider = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            isEnabled: false
        )
        let envelope = makeEnvelope(
            providers: [disabledProvider],
            defaultProviderID: disabledProvider.id
        )

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: providerBID, modelID: "missing-model")
            ),
            .unconfigured(provider: BuiltInAIProvider.defaultConfiguration)
        )
    }

    func testRuntimeResolverTreatsRequestedRulesSelectionAsFollowingGlobalDefault() {
        let providerA = makeProvider(id: providerAID, modelIDs: ["a-model"])
        let envelope = makeEnvelope(providers: [providerA], defaultProviderID: providerA.id)

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(
                    providerID: BuiltInAIProvider.stacioRulesID,
                    modelID: "ignored"
                )
            ),
            .external(provider: providerA, modelID: "a-model")
        )
    }

    func testRuntimeResolverReturnsUnconfiguredMozheAPIForLegacyRulesOnlyEnvelope() {
        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: .rulesOnly,
                requestedSelection: nil
            ),
            .unconfigured(provider: BuiltInAIProvider.defaultConfiguration)
        )
    }

    func testLegacyCatalogPathCanLoadModelsForUnconfiguredMozheAPI() throws {
        let catalog = RuntimeRecordingModelCatalog()
        let keyStore = ScopedRecordingAIApiKeyStore(
            keys: [BuiltInAIProvider.mozheAPIID: "mozhe-secret"]
        )

        let models = try catalog.listModels(
            settings: AppSettings(),
            apiKeyStore: keyStore
        )

        XCTAssertEqual(models, ["remote-model"])
        XCTAssertEqual(catalog.providerIDs, [BuiltInAIProvider.mozheAPIID])
        XCTAssertEqual(catalog.apiKeys, ["mozhe-secret"])
        XCTAssertEqual(keyStore.readProviderIDs, [BuiltInAIProvider.mozheAPIID])
    }

    func testLegacyConnectionPathReportsMissingModelForUnconfiguredMozheAPI() {
        let tester = RuntimeRecordingConnectionTester()
        let keyStore = ScopedRecordingAIApiKeyStore(
            keys: [BuiltInAIProvider.mozheAPIID: "mozhe-secret"]
        )

        XCTAssertThrowsError(
            try tester.testConnection(settings: AppSettings(), apiKeyStore: keyStore)
        ) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .missingModel)
        }
        XCTAssertTrue(tester.providerIDs.isEmpty)
        XCTAssertTrue(keyStore.readProviderIDs.isEmpty)
    }

    func testUnconfiguredMozheAPIUsesLegacyContextLimit() {
        let settings = AppSettings(
            aiProviderSettings: .rulesOnly,
            aiContextCharacterLimit: 23_456
        )

        XCTAssertEqual(
            AIAssistantCoordinator.effectiveContextCharacterLimit(settings: settings),
            23_456
        )
    }

    func testRuntimeResolverRejectsDisabledRequestedProvider() {
        let disabledProvider = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            isEnabled: false
        )
        let defaultProvider = makeProvider(id: providerBID, modelIDs: ["b-model"])
        let envelope = makeEnvelope(
            providers: [disabledProvider, defaultProvider],
            defaultProviderID: defaultProvider.id
        )

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: disabledProvider.id, modelID: "a-model")
            ),
            .external(provider: defaultProvider, modelID: "b-model")
        )
    }

    func testRuntimeResolverRejectsDisabledRequestedModel() {
        let providerA = makeProvider(
            id: providerAID,
            models: [
                makeModel(id: "disabled-model", isEnabled: false),
                makeModel(id: "enabled-model", isEnabled: true)
            ],
            defaultModelID: "enabled-model"
        )
        let defaultProvider = makeProvider(id: providerBID, modelIDs: ["b-model"])
        let envelope = makeEnvelope(
            providers: [providerA, defaultProvider],
            defaultProviderID: defaultProvider.id
        )

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: providerA.id, modelID: "disabled-model")
            ),
            .external(provider: defaultProvider, modelID: "b-model")
        )
    }

    func testRuntimeResolverRejectsProfileWithoutModelInterface() {
        let rulesProfileProvider = makeProvider(
            id: providerAID,
            profile: .portDeskRules,
            modelIDs: ["not-a-runtime-model"]
        )
        let defaultProvider = makeProvider(id: providerBID, modelIDs: ["b-model"])
        let envelope = makeEnvelope(
            providers: [rulesProfileProvider, defaultProvider],
            defaultProviderID: defaultProvider.id
        )

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(
                    providerID: rulesProfileProvider.id,
                    modelID: "not-a-runtime-model"
                )
            ),
            .external(provider: defaultProvider, modelID: "b-model")
        )
    }

    func testRuntimeResolverFallsBackPastInvalidDefaultProfileToNextValidProvider() {
        let invalidDefault = makeProvider(
            id: providerAID,
            profile: .portDeskRules,
            modelIDs: ["not-a-runtime-model"]
        )
        let validProvider = makeProvider(id: providerBID, modelIDs: ["b-model"])
        let envelope = makeEnvelope(
            providers: [invalidDefault, validProvider],
            defaultProviderID: invalidDefault.id
        )

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: nil
            ),
            .external(provider: validProvider, modelID: "b-model")
        )
    }

    func testRuntimeResolverAllowsStaleButEnabledCatalogModel() {
        let staleModel = AIProviderModelConfiguration(
            id: "stale-model",
            isEnabled: true,
            isManual: false,
            wasReturnedByLatestCatalog: false
        )
        let providerA = makeProvider(
            id: providerAID,
            models: [staleModel],
            defaultModelID: "stale-model"
        )
        let envelope = makeEnvelope(providers: [providerA], defaultProviderID: providerA.id)

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: envelope,
                requestedSelection: .init(providerID: providerA.id, modelID: staleModel.id)
            ),
            .external(provider: providerA, modelID: staleModel.id)
        )
    }

    func testRuntimeResolverCarriesSelectedModelCapabilitiesIntoResolvedTarget() {
        var model = makeModel(id: "capable-model", isEnabled: true)
        model.capabilities.contextCharacterLimit = 18_000
        model.capabilities.contextCharacterLimitSource = .catalog
        model.capabilities.supportedReasoningEfforts = [.minimal, .high]
        model.capabilities.reasoningEffort = .high
        model.capabilities.reasoningEffortSource = .catalog
        let provider = makeProvider(
            id: providerAID,
            models: [model],
            defaultModelID: model.id
        )

        XCTAssertEqual(
            AIProviderRuntimeResolver.resolve(
                envelope: makeEnvelope(providers: [provider], defaultProviderID: provider.id),
                requestedSelection: nil
            ),
            .external(provider: provider, modelID: model.id)
        )
    }

    func testFactoryUsesSelectedModelReasoningInsteadOfLegacyGlobalPreference() throws {
        var model = makeModel(id: "capable-model", isEnabled: true)
        model.capabilities.supportedReasoningEfforts = [.minimal, .high]
        model.capabilities.supportedReasoningEffortsSource = .catalog
        model.capabilities.reasoningEffort = .high
        model.capabilities.reasoningEffortSource = .manual
        let providerConfiguration = makeProvider(
            id: providerAID,
            models: [model],
            defaultModelID: model.id,
            compatibilityProtocol: .responses
        )
        let transport = RuntimeRecordingTransport(responses: [(200, responsesBody(message: "ok"))])
        let provider = AIAssistantProviderFactory.makeProvider(
            settings: AppSettings(
                aiProviderSettings: makeEnvelope(
                    providers: [providerConfiguration],
                    defaultProviderID: providerConfiguration.id
                ),
                aiReasoningEffort: .low
            ),
            requestedSelection: nil,
            apiKeyProvider: { _ in "provider-secret" },
            transport: transport
        )

        _ = try provider.respond(to: makeAIRequest())

        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    }

    @MainActor
    func testCoordinatorCompressesContextUsingSelectedModelBudgetInsteadOfLegacyGlobalValue() throws {
        var model = makeModel(id: "small-context-model", isEnabled: true)
        model.capabilities.contextCharacterLimit = 120
        model.capabilities.contextCharacterLimitSource = .manual
        let providerConfiguration = makeProvider(
            id: providerAID,
            models: [model],
            defaultModelID: model.id
        )
        let harness = try makeSettingsStore(
            envelope: makeEnvelope(
                providers: [providerConfiguration],
                defaultProviderID: providerConfiguration.id
            )
        )
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        harness.store.update { settings in
            settings.aiContextCharacterLimit = 20_000
        }
        let recordingProvider = RuntimeContextRecordingProvider()
        let session = AIModelSelectionSession(
            selection: .init(providerID: providerConfiguration.id, modelID: model.id)
        )
        let coordinator = AIAssistantCoordinator(
            provider: recordingProvider,
            executionCoordinator: RuntimeNoopAgentCommandExecutor(),
            settingsStore: harness.store,
            modelSelectionSession: session
        )

        _ = try coordinator.ask(
            question: "summarize",
            context: AITerminalContext(
                runtimeID: "runtime-test",
                title: "Runtime Test",
                currentDirectory: "/tmp",
                recentTranscript: String(repeating: "long terminal output\n", count: 40)
            )
        )

        let request = try XCTUnwrap(recordingProvider.requests.first)
        XCTAssertLessThanOrEqual(request.context.recentTranscript.count, 120)
        XCTAssertTrue(request.context.recentTranscript.contains("自动上下文压缩"))
    }

    func testModelSelectionSessionsAreIndependentAcrossPanels() {
        let first = AIModelSelectionSession()
        let second = AIModelSelectionSession()
        let selection = AIModelSelection(providerID: providerAID, modelID: "a-model")

        first.select(selection)

        XCTAssertEqual(first.snapshot(), selection)
        XCTAssertNil(second.snapshot())
    }

    func testModelSelectionSessionSupportsConcurrentSnapshotAndSelect() {
        let session = AIModelSelectionSession()
        let queue = DispatchQueue(label: "AIModelSelectionSessionTests", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<500 {
            group.enter()
            queue.async {
                if index.isMultiple(of: 2) {
                    session.select(.init(providerID: self.providerAID, modelID: "model-\(index)"))
                } else {
                    _ = session.snapshot()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let finalSelection = AIModelSelection(providerID: providerBID, modelID: "final-model")
        session.select(finalSelection)
        XCTAssertEqual(session.snapshot(), finalSelection)
    }

    func testFactoryUsesResolvedProviderScopedKeyAndRuntimeConfiguration() throws {
        let providerA = makeProvider(
            id: providerAID,
            modelIDs: ["shared"],
            baseURL: "https://a.example/v1"
        )
        let providerB = makeProvider(
            id: providerBID,
            modelIDs: ["shared"],
            baseURL: "https://b.example/runtime",
            compatibilityProtocol: .responses,
            maxRetryCount: 1,
            requestTimeoutSeconds: 23,
            userAgent: "Provider-B/2.0"
        )
        let envelope = makeEnvelope(providers: [providerA, providerB], defaultProviderID: providerA.id)
        let transport = RuntimeRecordingTransport(responses: [
            (500, #"{"error":{"message":"temporary"}}"#),
            (200, responsesBody(message: "provider-b"))
        ])
        var keyLookupProviderIDs: [UUID] = []
        let settings = AppSettings(aiProviderSettings: envelope)
        let provider = AIAssistantProviderFactory.makeProvider(
            settings: settings,
            requestedSelection: .init(providerID: providerB.id, modelID: "shared"),
            apiKeyProvider: { providerID in
                keyLookupProviderIDs.append(providerID)
                return providerID == providerB.id ? "provider-b-secret" : nil
            },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "provider-b")
        XCTAssertEqual(keyLookupProviderIDs, [providerB.id])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "https://b.example/runtime/responses",
            "https://b.example/runtime/responses"
        ])
        XCTAssertEqual(transport.requests.first?.timeoutInterval, 23)
        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "User-Agent"),
            "Provider-B/2.0"
        )
        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer provider-b-secret"
        )
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "shared")
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
    }

    func testFactoryReturnsMissingModelForLegacyRulesWithoutReadingAnyScopedKey() {
        var keyLookupProviderIDs: [UUID] = []

        let provider = AIAssistantProviderFactory.makeProvider(
            settings: AppSettings(aiProviderSettings: .rulesOnly),
            requestedSelection: .init(
                providerID: BuiltInAIProvider.stacioRulesID,
                modelID: "ignored"
            ),
            apiKeyProvider: { providerID in
                keyLookupProviderIDs.append(providerID)
                return "unused-secret"
            },
            transport: RuntimeRecordingTransport()
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .missingModel)
        }
        XCTAssertEqual(keyLookupProviderIDs, [])
    }

    func testFactoryRejectsInvalidResolvedURLWithoutLeakingSecret() {
        let providerA = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            baseURL: "https://bad host/v1"
        )
        let envelope = makeEnvelope(providers: [providerA], defaultProviderID: providerA.id)
        let provider = AIAssistantProviderFactory.makeProvider(
            settings: AppSettings(aiProviderSettings: envelope),
            requestedSelection: nil,
            apiKeyProvider: { _ in "url-secret-must-not-leak" },
            transport: RuntimeRecordingTransport()
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .invalidBaseURL)
            XCTAssertFalse(error.localizedDescription.contains("url-secret-must-not-leak"))
        }
    }

    func testFactoryPreservesSecretSafeScopedKeyReadFailure() {
        let providerA = makeProvider(id: providerAID, modelIDs: ["a-model"])
        let envelope = makeEnvelope(providers: [providerA], defaultProviderID: providerA.id)
        let keyReadError = SecretSafeRuntimeError(
            code: 17,
            secret: "keychain-secret-must-not-leak"
        )
        let provider = AIAssistantProviderFactory.makeProvider(
            settings: AppSettings(aiProviderSettings: envelope),
            requestedSelection: nil,
            apiKeyProvider: { _ in
                throw keyReadError
            },
            transport: RuntimeRecordingTransport()
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? SecretSafeRuntimeError, keyReadError)
            XCTAssertFalse(error.localizedDescription.contains("keychain-secret-must-not-leak"))
        }
    }

    func testSettingsBackedProviderKeepsValidTemporarySelectionAfterGlobalDefaultChange() throws {
        let providerA = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            baseURL: "https://a.example/v1"
        )
        let providerB = makeProvider(
            id: providerBID,
            modelIDs: ["b-model"],
            baseURL: "https://b.example/v1"
        )
        let providerCID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let providerC = makeProvider(
            id: providerCID,
            modelIDs: ["c-model"],
            baseURL: "https://c.example/v1"
        )
        let envelope = makeEnvelope(
            providers: [providerA, providerB, providerC],
            defaultProviderID: providerA.id
        )
        let harness = try makeSettingsStore(envelope: envelope)
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let keyStore = ScopedRecordingAIApiKeyStore(keys: [providerB.id: "provider-b-secret"])
        let session = AIModelSelectionSession(
            selection: .init(providerID: providerB.id, modelID: "b-model")
        )
        let transport = RuntimeRecordingTransport(responses: [
            (200, chatBody(message: "first")),
            (200, chatBody(message: "second"))
        ])
        let provider = SettingsBackedAIAssistantProvider(
            settingsStore: harness.store,
            apiKeyStore: keyStore,
            transport: transport,
            selectionSession: session
        )

        _ = try provider.respond(to: makeAIRequest())
        var changedEnvelope = envelope
        changedEnvelope.defaultAIProviderID = providerC.id
        try harness.store.saveAIProviderSettings(changedEnvelope)
        _ = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(keyStore.readProviderIDs, [providerB.id, providerB.id])
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["b.example", "b.example"])
    }

    func testSettingsBackedProviderNeverMixesConfigurationAndKeyAcrossConcurrentMutation() throws {
        let oldProvider = makeProvider(
            id: providerAID,
            modelIDs: ["old-model"],
            baseURL: "https://old-runtime.example/v1"
        )
        let newProvider = makeProvider(
            id: providerAID,
            modelIDs: ["new-model"],
            baseURL: "https://new-runtime.example/v1"
        )
        let harness = try makeSettingsStore(
            envelope: makeEnvelope(providers: [oldProvider], defaultProviderID: oldProvider.id)
        )
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }

        let keyReadEntered = DispatchSemaphore(value: 0)
        let releaseKeyRead = DispatchSemaphore(value: 0)
        let networkEntered = DispatchSemaphore(value: 0)
        let releaseNetwork = DispatchSemaphore(value: 0)
        defer {
            releaseKeyRead.signal()
            releaseNetwork.signal()
        }

        let keyState = RuntimeRaceKeyState(keys: [oldProvider.id: "old-secret"])
        let runtimeKeyStore = RuntimeRaceScopedKeyStore(state: keyState) {
            keyReadEntered.signal()
            _ = releaseKeyRead.wait(timeout: .now() + 5)
        }
        let mutationKeyStore = RuntimeRaceCoordinatorKeyStore(state: keyState)
        let mutationCoordinator = AIProviderConfigurationCoordinator(
            settingsStore: harness.store,
            keyStore: mutationKeyStore
        )
        let transport = RuntimeRecordingTransport()
        transport.onRequest = { call in
            guard call == 1 else { return }
            networkEntered.signal()
            _ = releaseNetwork.wait(timeout: .now() + 5)
        }
        let runtimeProvider = SettingsBackedAIAssistantProvider(
            settingsStore: harness.store,
            apiKeyStore: runtimeKeyStore,
            transport: transport
        )
        let requestResult = RuntimeRaceResultBox<AIAssistantResponse>()
        let mutationResult = RuntimeRaceResultBox<AIProviderSettingsEnvelope>()
        let requestDone = DispatchSemaphore(value: 0)
        let mutationDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            requestResult.record(Result { try runtimeProvider.respond(to: self.makeAIRequest()) })
            requestDone.signal()
        }
        XCTAssertEqual(keyReadEntered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            mutationResult.record(Result {
                try mutationCoordinator.saveProvider(
                    newProvider,
                    apiKeyUpdate: .replace("new-secret")
                )
            })
            mutationDone.signal()
        }

        let mutationFinishedBeforeKeyReadRelease = mutationDone.wait(timeout: .now() + 0.2) == .success
        releaseKeyRead.signal()
        XCTAssertEqual(networkEntered.wait(timeout: .now() + 2), .success)
        if mutationFinishedBeforeKeyReadRelease == false {
            XCTAssertEqual(mutationDone.wait(timeout: .now() + 2), .success)
        }
        releaseNetwork.signal()
        XCTAssertEqual(requestDone.wait(timeout: .now() + 2), .success)

        _ = try XCTUnwrap(requestResult.value).get()
        _ = try XCTUnwrap(mutationResult.value).get()
        let request = try XCTUnwrap(transport.requests.first)
        let actualURL = request.url?.absoluteString ?? "nil"
        let actualAuthorization = request.value(forHTTPHeaderField: "Authorization") ?? "nil"
        XCTAssertEqual(
            actualURL,
            "https://old-runtime.example/v1/chat/completions",
            "Runtime URL changed after the request snapshot: \(actualURL)"
        )
        XCTAssertEqual(
            actualAuthorization,
            "Bearer old-secret",
            "Observed mixed runtime pair: url=\(actualURL), authorization=\(actualAuthorization)"
        )
        XCTAssertEqual(keyState.readAPIKey(for: oldProvider.id), "new-secret")
        XCTAssertEqual(
            try harness.store.loadAIProviderSettings().aiProviders.first?.baseURL,
            newProvider.baseURL
        )
    }

    func testSettingsBackedProviderSnapshotsSelectionOncePerSyncRequest() throws {
        let providerA = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            baseURL: "https://a.example/v1"
        )
        let providerB = makeProvider(
            id: providerBID,
            modelIDs: ["b-model"],
            baseURL: "https://b.example/v1"
        )
        let providerCID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let providerC = makeProvider(
            id: providerCID,
            modelIDs: ["c-model"],
            baseURL: "https://c.example/v1"
        )
        let envelope = makeEnvelope(
            providers: [providerA, providerB, providerC],
            defaultProviderID: providerA.id
        )
        let harness = try makeSettingsStore(envelope: envelope)
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let session = AIModelSelectionSession(
            selection: .init(providerID: providerA.id, modelID: "a-model")
        )
        let keyStore = ScopedRecordingAIApiKeyStore(keys: [
            providerA.id: "provider-a-secret",
            providerB.id: "provider-b-secret",
            providerC.id: "provider-c-secret"
        ])
        keyStore.onRead = { _, call in
            if call == 1 {
                session.select(.init(providerID: providerB.id, modelID: "b-model"))
            }
        }
        let transport = RuntimeRecordingTransport(responses: [
            (200, chatBody(message: "first")),
            (200, chatBody(message: "second"))
        ])
        transport.onRequest = { call in
            if call == 1 {
                session.select(.init(providerID: providerC.id, modelID: "c-model"))
            }
        }
        let provider = SettingsBackedAIAssistantProvider(
            settingsStore: harness.store,
            apiKeyStore: keyStore,
            transport: transport,
            selectionSession: session
        )

        _ = try provider.respond(to: makeAIRequest())
        _ = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(keyStore.readProviderIDs, [providerA.id, providerC.id])
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["a.example", "c.example"])
    }

    func testSettingsBackedProviderSnapshotsSelectionOncePerStreamingRequest() async throws {
        let providerA = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            baseURL: "https://a.example/v1"
        )
        let providerB = makeProvider(
            id: providerBID,
            modelIDs: ["b-model"],
            baseURL: "https://b.example/v1"
        )
        let providerCID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let providerC = makeProvider(
            id: providerCID,
            modelIDs: ["c-model"],
            baseURL: "https://c.example/v1"
        )
        let envelope = makeEnvelope(
            providers: [providerA, providerB, providerC],
            defaultProviderID: providerA.id
        )
        let harness = try makeSettingsStore(envelope: envelope)
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let session = AIModelSelectionSession(
            selection: .init(providerID: providerA.id, modelID: "a-model")
        )
        let keyStore = ScopedRecordingAIApiKeyStore(keys: [
            providerA.id: "provider-a-secret",
            providerB.id: "provider-b-secret",
            providerC.id: "provider-c-secret"
        ])
        keyStore.onRead = { _, call in
            if call == 1 {
                session.select(.init(providerID: providerB.id, modelID: "b-model"))
            }
        }
        let transport = RuntimeRecordingTransport()
        transport.onStreamRequest = { call in
            if call == 1 {
                session.select(.init(providerID: providerC.id, modelID: "c-model"))
            }
        }
        let provider = SettingsBackedAIAssistantProvider(
            settingsStore: harness.store,
            apiKeyStore: keyStore,
            transport: transport,
            selectionSession: session
        )

        _ = try await provider.respondStreaming(to: makeAIRequest(), onPartial: { _ in })
        _ = try await provider.respondStreaming(to: makeAIRequest(), onPartial: { _ in })

        XCTAssertEqual(keyStore.readProviderIDs, [providerA.id, providerC.id])
        XCTAssertEqual(transport.streamRequests.map { $0.url?.host }, ["a.example", "c.example"])
    }

    func testSettingsBackedProviderMigratesLegacyKeyOnlyForExactMarkedProvider() throws {
        let providerA = makeProvider(
            id: providerAID,
            modelIDs: ["a-model"],
            baseURL: "https://a.example/v1"
        )
        let providerB = makeProvider(
            id: providerBID,
            modelIDs: ["b-model"],
            baseURL: "https://b.example/v1"
        )
        let envelope = AIProviderSettingsEnvelope(
            aiProviders: [providerA, providerB],
            defaultAIProviderID: providerA.id,
            legacyKeyMigrationProviderID: providerA.id
        )
        let harness = try makeSettingsStore(envelope: envelope)
        defer { harness.defaults.removePersistentDomain(forName: harness.suiteName) }
        let backend = InMemoryKeychainBackend()
        let credentialStore = KeychainCredentialStore(backend: backend)
        let keyStore = KeychainAIApiKeyStore(credentialStore: credentialStore)
        try credentialStore.save(
            KeychainCredential(
                id: "stacio.ai.openai-compatible.api-key",
                account: "OpenAI Compatible",
                secret: "legacy-global-secret"
            )
        )
        let session = AIModelSelectionSession(
            selection: .init(providerID: providerB.id, modelID: "b-model")
        )
        let transport = RuntimeRecordingTransport(responses: [
            (200, chatBody(message: "provider-a"))
        ])
        let provider = SettingsBackedAIAssistantProvider(
            settingsStore: harness.store,
            apiKeyStore: keyStore,
            transport: transport,
            selectionSession: session
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .missingAPIKey)
        }
        XCTAssertNil(try keyStore.readAPIKey(for: providerB.id))
        XCTAssertEqual(
            try harness.store.loadAIProviderSettings().legacyKeyMigrationProviderID,
            providerA.id
        )
        XCTAssertEqual(transport.requests.count, 0)

        session.select(.init(providerID: providerA.id, modelID: "a-model"))
        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "provider-a")
        XCTAssertEqual(try keyStore.readAPIKey(for: providerA.id), "legacy-global-secret")
        XCTAssertNil(try harness.store.loadAIProviderSettings().legacyKeyMigrationProviderID)
        XCTAssertEqual(try keyStore.readLegacyGlobalAPIKey(), "legacy-global-secret")
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["a.example"])
    }

    private func makeEnvelope(
        providers: [AIProviderConfiguration],
        defaultProviderID: UUID
    ) -> AIProviderSettingsEnvelope {
        AIProviderSettingsEnvelope(
            aiProviders: providers,
            defaultAIProviderID: defaultProviderID
        )
    }

    private func makeProvider(
        id: UUID,
        profile: AIProviderProfile = .openAICompatible,
        modelIDs: [String],
        isEnabled: Bool = true,
        baseURL: String = "https://api.example.com/v1",
        compatibilityProtocol: AICompatibilityProtocolPreference = .chatCompletions,
        maxRetryCount: Int = 1,
        requestTimeoutSeconds: Int = 45,
        userAgent: String = "Stacio"
    ) -> AIProviderConfiguration {
        makeProvider(
            id: id,
            profile: profile,
            models: modelIDs.map { makeModel(id: $0, isEnabled: true) },
            defaultModelID: modelIDs.first,
            isEnabled: isEnabled,
            baseURL: baseURL,
            compatibilityProtocol: compatibilityProtocol,
            maxRetryCount: maxRetryCount,
            requestTimeoutSeconds: requestTimeoutSeconds,
            userAgent: userAgent
        )
    }

    private func makeProvider(
        id: UUID,
        profile: AIProviderProfile = .openAICompatible,
        models: [AIProviderModelConfiguration],
        defaultModelID: String?,
        isEnabled: Bool = true,
        baseURL: String = "https://api.example.com/v1",
        compatibilityProtocol: AICompatibilityProtocolPreference = .chatCompletions,
        maxRetryCount: Int = 1,
        requestTimeoutSeconds: Int = 45,
        userAgent: String = "Stacio"
    ) -> AIProviderConfiguration {
        AIProviderConfiguration(
            id: id,
            profile: profile,
            displayName: "Provider \(id.uuidString.prefix(4))",
            baseURL: baseURL,
            models: models,
            defaultModelID: defaultModelID,
            compatibilityProtocol: compatibilityProtocol,
            maxRetryCount: maxRetryCount,
            requestTimeoutSeconds: requestTimeoutSeconds,
            userAgent: userAgent,
            isEnabled: isEnabled,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil
        )
    }

    private func makeModel(
        id: String,
        isEnabled: Bool
    ) -> AIProviderModelConfiguration {
        AIProviderModelConfiguration(
            id: id,
            isEnabled: isEnabled,
            isManual: false,
            wasReturnedByLatestCatalog: true
        )
    }

    private func makeSettingsStore(
        envelope: AIProviderSettingsEnvelope
    ) throws -> (store: AppSettingsStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "AIProviderRuntimeResolverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettingsStore(defaults: defaults)
        try store.saveAIProviderSettings(envelope)
        return (store, defaults, suiteName)
    }

    private func makeAIRequest() -> AIAssistantRequest {
        AIAssistantRequest(
            question: "status",
            context: AITerminalContext(
                runtimeID: "runtime-test",
                title: "Runtime Test",
                currentDirectory: "/tmp",
                recentTranscript: ""
            )
        )
    }

    private func chatBody(message: String) -> String {
        let content = #"{"message":"\#(message)","commands":[]}"#
        return #"{"choices":[{"message":{"content":"\#(content.replacingOccurrences(of: "\"", with: "\\\""))"}}]}"#
    }

    private func responsesBody(message: String) -> String {
        let content = #"{"message":"\#(message)","commands":[]}"#
        return #"{"output_text":"\#(content.replacingOccurrences(of: "\"", with: "\\\""))"}"#
    }
}

private struct SecretSafeRuntimeError: LocalizedError, Equatable {
    let code: Int
    let secret: String

    var errorDescription: String? {
        "Keychain access denied (\(code))"
    }
}

private final class RuntimeRecordingModelCatalog: AIModelCatalogLoading {
    private(set) var providerIDs: [UUID] = []
    private(set) var apiKeys: [String?] = []

    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        providerIDs.append(provider.id)
        apiKeys.append(apiKey)
        return ["remote-model"]
    }
}

private final class RuntimeRecordingConnectionTester: AIAssistantConnectionTesting {
    private(set) var providerIDs: [UUID] = []

    func testConnection(
        provider: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) throws -> AIAssistantConnectionTestResult {
        providerIDs.append(provider.id)
        return AIAssistantConnectionTestResult(message: "unexpected")
    }
}

private final class ScopedRecordingAIApiKeyStore: AIApiKeyStoring {
    private let lock = NSLock()
    private var keys: [UUID: String]
    private var recordedReadProviderIDs: [UUID] = []
    var onRead: ((UUID, Int) -> Void)?

    init(keys: [UUID: String]) {
        self.keys = keys
    }

    var readProviderIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReadProviderIDs
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        lock.lock()
        keys[providerID] = apiKey
        lock.unlock()
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        lock.lock()
        recordedReadProviderIDs.append(providerID)
        let call = recordedReadProviderIDs.count
        let apiKey = keys[providerID]
        let onRead = onRead
        lock.unlock()
        onRead?(providerID, call)
        return apiKey
    }

    func deleteAPIKey(for providerID: UUID) throws {
        lock.lock()
        keys.removeValue(forKey: providerID)
        lock.unlock()
    }
}

private final class RuntimeRecordingTransport: AIAssistantHTTPTransport {
    private let responses: [(statusCode: Int, body: String)]
    private(set) var requests: [URLRequest] = []
    private(set) var streamRequests: [URLRequest] = []
    var onRequest: ((Int) -> Void)?
    var onStreamRequest: ((Int) -> Void)?

    init(responses: [(Int, String)] = []) {
        self.responses = responses.map { (statusCode: $0.0, body: $0.1) }
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        onRequest?(requests.count)
        let response = responses.isEmpty
            ? (200, #"{"choices":[{"message":{"content":"{\"message\":\"ok\",\"commands\":[]}"}}]}"#)
            : responses[min(requests.count - 1, responses.count - 1)]
        return (
            Data(response.1.utf8),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: response.0,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        streamRequests.append(request)
        onStreamRequest?(streamRequests.count)
        let content = #"{"message":"stream-ok","commands":[]}"#
        let payload = try JSONEncoder().encode(["delta": content])
        var chunk = Data("data: ".utf8)
        chunk.append(payload)
        chunk.append(Data("\n\ndata: [DONE]\n\n".utf8))
        onChunk(chunk)
        return HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }
}

private final class RuntimeContextRecordingProvider: AIAssistantProviding {
    private(set) var requests: [AIAssistantRequest] = []

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        requests.append(request)
        return AIAssistantResponse(message: "ok", proposedCommand: nil)
    }
}

@MainActor
private final class RuntimeNoopAgentCommandExecutor: AgentCommandExecuting {
    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        []
    }
}

private final class RuntimeRaceKeyState: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String]

    init(keys: [UUID: String]) {
        self.keys = keys
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) {
        lock.lock()
        keys[providerID] = apiKey
        lock.unlock()
    }

    func readAPIKey(for providerID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[providerID]
    }

    func deleteAPIKey(for providerID: UUID) {
        lock.lock()
        keys.removeValue(forKey: providerID)
        lock.unlock()
    }
}

private final class RuntimeRaceScopedKeyStore: AIApiKeyStoring {
    private let state: RuntimeRaceKeyState
    private let beforeRead: () -> Void

    init(state: RuntimeRaceKeyState, beforeRead: @escaping () -> Void) {
        self.state = state
        self.beforeRead = beforeRead
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        state.saveAPIKey(apiKey, for: providerID)
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        beforeRead()
        return state.readAPIKey(for: providerID)
    }

    func deleteAPIKey(for providerID: UUID) throws {
        state.deleteAPIKey(for: providerID)
    }
}

private final class RuntimeRaceCoordinatorKeyStore: AIApiKeyStoring, LegacyAIApiKeyReading {
    private let state: RuntimeRaceKeyState

    init(state: RuntimeRaceKeyState) {
        self.state = state
    }

    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        state.saveAPIKey(apiKey, for: providerID)
    }

    func readAPIKey(for providerID: UUID) throws -> String? {
        state.readAPIKey(for: providerID)
    }

    func deleteAPIKey(for providerID: UUID) throws {
        state.deleteAPIKey(for: providerID)
    }

    func readLegacyGlobalAPIKey() throws -> String? {
        nil
    }
}

private final class RuntimeRaceResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<Value, Error>?

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Result<Value, Error>) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
