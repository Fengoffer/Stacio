import Foundation
@testable import StacioApp
import XCTest

final class AIProviderModelCatalogTests: XCTestCase {
    func testCatalogPreservesExplicitModelCapabilitiesWithoutGuessingMissingFields() throws {
        let transport = CatalogRecordingTransport(responses: [
            (
                200,
                #"{"data":[{"id":"reasoning-model","context_window":131072,"supported_reasoning_efforts":["minimal","medium","high"]},{"id":"unknown-model"}]}"#
            )
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let entries = try catalog.listModelEntries(
            for: makeCatalogProvider(baseURL: "https://api.example.com/v1"),
            apiKey: "sk-test"
        )

        XCTAssertEqual(entries.map(\.id), ["reasoning-model", "unknown-model"])
        XCTAssertEqual(entries[0].capabilities.contextWindowTokens, 131_072)
        XCTAssertEqual(entries[0].capabilities.supportedReasoningEfforts, [.minimal, .medium, .high])
        XCTAssertNil(entries[1].capabilities.contextWindowTokens)
        XCTAssertNil(entries[1].capabilities.supportedReasoningEfforts)
    }

    func testCatalogUsesProviderModelsEndpointHeadersTimeoutAndStableCleaning() throws {
        let transport = CatalogRecordingTransport(responses: [
            (200, #"{"data":[{"id":"  gpt-4.1-mini  "},{"id":"ops\tmodel\u0000\r\nalpha"},{"id":"gpt-4.1-mini"},{"id":"\u0000"}]}"#)
        ])
        var provider = makeCatalogProvider(baseURL: "https://api.example.com")
        provider.maxRetryCount = 0
        provider.requestTimeoutSeconds = 17
        provider.userAgent = "  Stacio-Catalog/1.0  "
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(for: provider, apiKey: "  sk-current-request  ")

        XCTAssertEqual(models, ["gpt-4.1-mini", "ops model alpha"])
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/models"])
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
        XCTAssertEqual(transport.requests.first?.timeoutInterval, 17)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "User-Agent"), "Stacio-Catalog/1.0")
        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-current-request"
        )
    }

    func testCatalogUsesV1ModelsWhenProviderBaseURLIsFullKnownEndpoint() throws {
        for baseURL in [
            "https://api.example.com/v1/chat/completions",
            "https://api.example.com/v1/responses"
        ] {
            let transport = CatalogRecordingTransport(responses: [
                (200, #"{"data":[{"id":"endpoint-model"}]}"#)
            ])
            let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

            XCTAssertEqual(
                try catalog.listModels(
                    for: makeCatalogProvider(baseURL: baseURL),
                    apiKey: "sk-test"
                ),
                ["endpoint-model"],
                baseURL
            )
            XCTAssertEqual(
                transport.requests.compactMap { $0.url?.path },
                ["/v1/models"],
                baseURL
            )
        }
    }

    func testCatalogUsesModelsBaseURLDirectly() throws {
        for (baseURL, expectedPath) in [
            ("https://api.example.com/models", "/models"),
            ("https://api.example.com/v1/models", "/v1/models")
        ] {
            let transport = CatalogRecordingTransport(responses: [
                (200, #"{"data":[{"id":"direct-model"}]}"#)
            ])
            let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

            XCTAssertEqual(
                try catalog.listModels(
                    for: makeCatalogProvider(baseURL: baseURL),
                    apiKey: "sk-test"
                ),
                ["direct-model"],
                baseURL
            )
            XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, [expectedPath], baseURL)
        }
    }

    func testCatalogFallsBackFromModelsToV1ModelsAfter404() throws {
        let transport = CatalogRecordingTransport(responses: [
            (404, #"{"error":{"message":"root models missing"}}"#),
            (200, #"{"data":[{"id":"fallback-model"}]}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(for: makeCatalogProvider(), apiKey: "sk-test")

        XCTAssertEqual(models, ["fallback-model"])
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/models", "/v1/models"])
    }

    func testCatalogFallsBackFromNonJSONModelsResponse() throws {
        let transport = CatalogRecordingTransport(responses: [
            (200, "<html>proxy login</html>"),
            (200, #"{"data":[{"id":"json-model"}]}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(for: makeCatalogProvider(), apiKey: "sk-test")

        XCTAssertEqual(models, ["json-model"])
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/models", "/v1/models"])
    }

    func testCatalogFallsBackFromEmptyAndInvalidModelShapes() throws {
        for firstResponse in [
            #"{"data":[]}"#,
            #"{"models":[{"id":"wrong-shape"}]}"#,
            #"{"data":[{"name":"missing-id"}]}"#
        ] {
            let transport = CatalogRecordingTransport(responses: [
                (200, firstResponse),
                (200, #"{"data":[{"id":"valid-model"}]}"#)
            ])
            let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

            XCTAssertEqual(
                try catalog.listModels(for: makeCatalogProvider(), apiKey: "sk-test"),
                ["valid-model"],
                firstResponse
            )
            XCTAssertEqual(
                transport.requests.compactMap { $0.url?.path },
                ["/models", "/v1/models"],
                firstResponse
            )
        }
    }

    func testCatalogDoesNotRetryOrFallbackAuthenticationFailures() throws {
        for statusCode in [401, 403] {
            let transport = CatalogRecordingTransport(responses: [
                (statusCode, #"{"error":{"message":"credential rejected"}}"#),
                (200, #"{"data":[{"id":"must-not-load"}]}"#)
            ])
            var provider = makeCatalogProvider()
            provider.maxRetryCount = 3
            let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

            XCTAssertThrowsError(try catalog.listModels(for: provider, apiKey: "sk-secret")) { error in
                XCTAssertEqual(catalogStatusCode(from: error), statusCode)
            }
            XCTAssertEqual(transport.requests.count, 1, "HTTP \(statusCode)")
        }
    }

    func testCatalogReportsFinal404AfterBothEndpoints() throws {
        let transport = CatalogRecordingTransport(responses: [
            (404, #"{"error":{"message":"root missing"}}"#),
            (404, #"{"error":{"message":"v1 missing"}}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        XCTAssertThrowsError(
            try catalog.listModels(for: makeCatalogProvider(), apiKey: "sk-secret")
        ) { error in
            XCTAssertEqual(catalogStatusCode(from: error), 404)
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("HTTP 404"))
            XCTAssertTrue(message.contains("v1 missing"))
        }
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/models", "/v1/models"])
    }

    func testCatalogReportsNonJSONWithoutLeakingExplicitAPIKey() throws {
        let transport = CatalogRecordingTransport(responses: [
            (200, "<html>sk-current-request</html>"),
            (200, "still not json sk-current-request")
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        XCTAssertThrowsError(
            try catalog.listModels(for: makeCatalogProvider(), apiKey: "sk-current-request")
        ) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .nonJSONResponse)
            XCTAssertFalse(RuntimeDiagnosticFormatter.userMessage(for: error).contains("sk-current-request"))
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testCatalogRedactsExactExplicitAPIKeyEchoedByUpstream() throws {
        let transport = CatalogRecordingTransport(responses: [
            (500, #"{"error":{"message":"upstream rejected opaqueABC123XYZ value"}}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        XCTAssertThrowsError(
            try catalog.listModels(
                for: makeCatalogProvider(baseURL: "https://api.example.com/v1"),
                apiKey: "opaqueABC123XYZ"
            )
        ) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertFalse(message.contains("opaqueABC123XYZ"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

    func testCatalogReportsEmptyAndInvalidShapesAsInvalidResponse() throws {
        for body in [#"{"data":[]}"#, #"{"models":[]}"#] {
            let transport = CatalogRecordingTransport(responses: [(200, body), (200, body)])
            let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

            XCTAssertThrowsError(
                try catalog.listModels(for: makeCatalogProvider(), apiKey: "sk-secret")
            ) { error in
                XCTAssertEqual(error as? AIAssistantProviderError, .invalidResponse)
                XCTAssertFalse(RuntimeDiagnosticFormatter.userMessage(for: error).contains("sk-secret"))
            }
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testCatalogUsesProviderRetryCountOnSameEndpoint() throws {
        let transport = CatalogRecordingTransport(responses: [
            (500, #"{"error":{"message":"temporary"}}"#),
            (200, #"{"data":[{"id":"retried-model"}]}"#)
        ])
        var provider = makeCatalogProvider(baseURL: "https://api.example.com/v1")
        provider.maxRetryCount = 1
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        XCTAssertEqual(
            try catalog.listModels(for: provider, apiKey: "sk-secret"),
            ["retried-model"]
        )
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/v1/models", "/v1/models"])
    }

    func testCatalogAllowsLoopbackHTTPWithoutAuthorization() throws {
        let transport = CatalogRecordingTransport(responses: [
            (200, #"{"data":[{"id":"local-model"}]}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(
            for: makeCatalogProvider(baseURL: "http://models.localhost:11434/v1"),
            apiKey: nil
        )

        XCTAssertEqual(models, ["local-model"])
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testCatalogRejectsPrivateLANHTTPBeforeTransportWithOrWithoutKey() throws {
        for apiKey in [nil, "sk-secret"] as [String?] {
            let transport = CatalogRecordingTransport(responses: [
                (200, #"{"data":[{"id":"must-not-load"}]}"#)
            ])
            let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

            XCTAssertThrowsError(
                try catalog.listModels(
                    for: makeCatalogProvider(baseURL: "http://192.168.1.20:11434/v1"),
                    apiKey: apiKey
                )
            ) { error in
                XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testModelCatalogMergerPreservesManualOldAndNewModels() {
        let existing = [
            AIProviderModelConfiguration(
                id: "manual",
                isEnabled: true,
                isManual: true,
                wasReturnedByLatestCatalog: false
            ),
            AIProviderModelConfiguration(
                id: "old",
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: true
            )
        ]

        let merged = AIProviderModelCatalogMerger.merge(
            existing: existing,
            fetchedModelIDs: ["  new  "]
        )

        XCTAssertEqual(merged.map(\.id), ["manual", "old", "new"])
        XCTAssertEqual(merged[0], existing[0])
        XCTAssertFalse(merged[1].wasReturnedByLatestCatalog)
        XCTAssertTrue(merged[1].isEnabled)
        XCTAssertEqual(
            merged[2],
            AIProviderModelConfiguration(
                id: "new",
                isEnabled: false,
                isManual: false,
                wasReturnedByLatestCatalog: true
            )
        )
    }

    func testModelCatalogMergerMarksHitsAndCleansFetchedDuplicates() {
        let existing = [
            AIProviderModelConfiguration(
                id: "manual",
                isEnabled: false,
                isManual: true,
                wasReturnedByLatestCatalog: false
            ),
            AIProviderModelConfiguration(
                id: "catalog",
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: false
            )
        ]

        let merged = AIProviderModelCatalogMerger.merge(
            existing: existing,
            fetchedModelIDs: [" catalog ", "manual", "new\tmodel", "new model", "\u{0000}"]
        )

        XCTAssertEqual(merged.map(\.id), ["manual", "catalog", "new model"])
        XCTAssertTrue(merged[0].isManual)
        XCTAssertTrue(merged[0].wasReturnedByLatestCatalog)
        XCTAssertTrue(merged[1].isEnabled)
        XCTAssertTrue(merged[1].wasReturnedByLatestCatalog)
        XCTAssertFalse(merged[2].isEnabled)
    }

    func testModelCatalogMergerAppliesCatalogCapabilitiesWithoutOverwritingManualOverrides() {
        var manuallyConfigured = AIProviderModelConfiguration(
            id: "configured",
            isEnabled: true,
            isManual: true,
            wasReturnedByLatestCatalog: false
        )
        manuallyConfigured.capabilities.contextCharacterLimit = 9_000
        manuallyConfigured.capabilities.contextCharacterLimitSource = .manual
        manuallyConfigured.capabilities.supportedReasoningEfforts = [.minimal, .low]
        manuallyConfigured.capabilities.reasoningEffort = .low
        manuallyConfigured.capabilities.reasoningEffortSource = .manual

        let merged = AIProviderModelCatalogMerger.merge(
            existing: [manuallyConfigured],
            fetchedEntries: [
                .init(
                    id: "configured",
                    capabilities: .init(
                        contextWindowTokens: 128_000,
                        supportedReasoningEfforts: [.minimal, .medium, .high]
                    )
                ),
                .init(
                    id: "catalog-only",
                    capabilities: .init(
                        contextWindowTokens: 64_000,
                        supportedReasoningEfforts: [.minimal, .low]
                    )
                )
            ]
        )

        XCTAssertEqual(merged[0].capabilities.contextWindowTokens, 128_000)
        XCTAssertEqual(merged[0].capabilities.contextCharacterLimit, 9_000)
        XCTAssertEqual(merged[0].capabilities.contextCharacterLimitSource, .manual)
        XCTAssertEqual(merged[0].capabilities.supportedReasoningEfforts, [.minimal, .medium, .high])
        XCTAssertEqual(merged[0].capabilities.reasoningEffort, .minimal)
        XCTAssertEqual(merged[0].capabilities.reasoningEffortSource, .catalog)
        XCTAssertEqual(merged[1].capabilities.contextWindowTokens, 64_000)
        XCTAssertEqual(merged[1].capabilities.contextCharacterLimitSource, .catalog)
        XCTAssertEqual(merged[1].capabilities.supportedReasoningEfforts, [.minimal, .low])
    }

    func testModelCatalogContextBudgetPreservesLargeAdvertisedWindow() {
        let merged = AIProviderModelCatalogMerger.merge(
            existing: [],
            fetchedEntries: [
                .init(
                    id: "large-context",
                    capabilities: .init(contextWindowTokens: 131_072)
                )
            ]
        )

        let capabilities = merged[0].capabilities
        XCTAssertEqual(capabilities.contextWindowTokens, 131_072)
        XCTAssertEqual(capabilities.contextCharacterLimit, 524_288)
        XCTAssertEqual(capabilities.effectiveContextCharacterLimit, 524_288)
        XCTAssertEqual(capabilities.contextCharacterLimitSource, .catalog)
    }

    func testModelCatalogMergerReplacesLegacyFallbackWhenCatalogCapabilitiesArrive() {
        var legacyModel = AIProviderModelConfiguration(
            id: "legacy-model",
            isEnabled: true,
            isManual: false,
            wasReturnedByLatestCatalog: false
        )
        legacyModel.capabilities.contextCharacterLimit = 16_000
        legacyModel.capabilities.contextCharacterLimitSource = .unknown
        legacyModel.capabilities.reasoningEffort = .high
        legacyModel.capabilities.reasoningEffortSource = .unknown

        let merged = AIProviderModelCatalogMerger.merge(
            existing: [legacyModel],
            fetchedEntries: [
                .init(
                    id: "legacy-model",
                    capabilities: .init(
                        contextWindowTokens: 64_000,
                        supportedReasoningEfforts: [.minimal, .medium]
                    )
                )
            ]
        )

        let capabilities = merged[0].capabilities
        XCTAssertEqual(capabilities.contextCharacterLimit, 256_000)
        XCTAssertEqual(capabilities.contextCharacterLimitSource, .catalog)
        XCTAssertEqual(capabilities.supportedReasoningEfforts, [.minimal, .medium])
        XCTAssertEqual(capabilities.reasoningEffort, .minimal)
        XCTAssertEqual(capabilities.reasoningEffortSource, .catalog)
    }

    func testConnectionTesterUsesSuppliedModelWithoutMutatingProviderOrLoadingCatalog() throws {
        let transport = CatalogRecordingTransport(responses: [
            (200, #"{"choices":[{"message":{"content":"{\"message\":\"连接成功。\",\"commands\":[]}"}}]}"#)
        ])
        var provider = makeCatalogProvider(baseURL: "https://api.example.com/v1")
        provider.models = [
            .init(id: "configured-default", isEnabled: true, isManual: false, wasReturnedByLatestCatalog: true),
            .init(id: "supplied-model", isEnabled: false, isManual: true, wasReturnedByLatestCatalog: false)
        ]
        provider.defaultModelID = "configured-default"
        provider.lastVerifiedAt = Date(timeIntervalSince1970: 100)
        provider.lastModelSyncAt = Date(timeIntervalSince1970: 200)
        let originalProvider = provider
        let tester = DefaultAIAssistantConnectionTester(transport: transport)

        let result = try tester.testConnection(
            provider: provider,
            modelID: "supplied-model",
            apiKey: "sk-current-request"
        )

        XCTAssertEqual(result.message, L10n.Settings.aiConnectionSuccess)
        XCTAssertEqual(provider, originalProvider)
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/v1/chat/completions"])
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "supplied-model")
    }

    func testConnectionTesterAppliesEndpointSecurityBeforeTransport() throws {
        let transport = CatalogRecordingTransport(responses: [
            (200, #"{"choices":[{"message":{"content":"{\"message\":\"unexpected\",\"commands\":[]}"}}]}"#)
        ])
        let tester = DefaultAIAssistantConnectionTester(transport: transport)

        XCTAssertThrowsError(
            try tester.testConnection(
                provider: makeCatalogProvider(baseURL: "http://10.0.0.5:11434/v1"),
                modelID: "supplied-model",
                apiKey: nil
            )
        ) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testConnectionTesterRedactsExactOpaqueAPIKeyEchoedByUpstream() throws {
        let transport = CatalogRecordingTransport(responses: [
            (401, #"{"error":{"message":"upstream rejected opaqueABC123XYZ value"}}"#)
        ])
        let tester = DefaultAIAssistantConnectionTester(transport: transport)

        XCTAssertThrowsError(
            try tester.testConnection(
                provider: makeCatalogProvider(baseURL: "https://api.example.com/v1"),
                modelID: "supplied-model",
                apiKey: "opaqueABC123XYZ"
            )
        ) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertFalse(message.contains("opaqueABC123XYZ"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

}

private final class CatalogRecordingTransport: AIAssistantHTTPTransport {
    private let responses: [(statusCode: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Int, String)]) {
        self.responses = responses.map { (statusCode: $0.0, body: $0.1) }
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses[min(requests.count - 1, responses.count - 1)]
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

private func makeCatalogProvider(
    baseURL: String = "https://api.example.com"
) -> AIProviderConfiguration {
    AIProviderConfiguration(
        id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        profile: .openAICompatible,
        displayName: "Catalog Test",
        baseURL: baseURL,
        models: [
            .init(
                id: "configured-model",
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: true
            )
        ],
        defaultModelID: "configured-model",
        compatibilityProtocol: .chatCompletions,
        maxRetryCount: 0,
        requestTimeoutSeconds: 12,
        userAgent: "Stacio",
        isEnabled: true,
        lastVerifiedAt: nil,
        lastModelSyncAt: nil
    )
}

private func catalogStatusCode(from error: Error) -> Int? {
    switch error as? AIAssistantProviderError {
    case .httpStatus(let statusCode):
        return statusCode
    case .apiError(let statusCode, _):
        return statusCode
    default:
        return nil
    }
}
