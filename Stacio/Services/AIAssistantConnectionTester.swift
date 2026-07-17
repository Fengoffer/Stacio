import Foundation

public struct AIAssistantConnectionTestResult: Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public protocol AIAssistantConnectionTesting {
    func testConnection(
        provider: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) throws -> AIAssistantConnectionTestResult

    func testConnection(
        settings: AppSettings,
        apiKeyStore: AIApiKeyStoring
    ) throws -> AIAssistantConnectionTestResult
}

public protocol AIModelCatalogLoading {
    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String]

    func listModels(
        settings: AppSettings,
        apiKeyStore: AIApiKeyStoring
    ) throws -> [String]
}

public extension AIModelCatalogLoading {
    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        throw AIAssistantProviderError.invalidResponse
    }

    func listModelEntries(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [AIModelCatalogEntry] {
        try listModels(for: provider, apiKey: apiKey).map { AIModelCatalogEntry(id: $0) }
    }

    // Retains the old settings-page call path while persisted settings migrate to per-provider keys.
    func listModels(
        settings: AppSettings,
        apiKeyStore: AIApiKeyStoring
    ) throws -> [String] {
        switch AIProviderRuntimeResolver.resolve(
            envelope: settings.aiProviderSettings,
            requestedSelection: nil
        ) {
        case let .unconfigured(provider), let .external(provider, _):
            return try listModels(
                for: provider,
                apiKey: try apiKeyStore.readAPIKey(for: provider.id)
            )
        }
    }
}

public extension AIAssistantConnectionTesting {
    func testConnection(
        provider: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) throws -> AIAssistantConnectionTestResult {
        throw AIAssistantProviderError.invalidResponse
    }

    // Retains the old settings-page call path while the visible UI uses provider-scoped settings.
    func testConnection(
        settings: AppSettings,
        apiKeyStore: AIApiKeyStoring
    ) throws -> AIAssistantConnectionTestResult {
        switch AIProviderRuntimeResolver.resolve(
            envelope: settings.aiProviderSettings,
            requestedSelection: nil
        ) {
        case .unconfigured:
            throw AIAssistantProviderError.missingModel
        case let .external(provider, modelID):
            return try testConnection(
                provider: provider,
                modelID: modelID,
                apiKey: try apiKeyStore.readAPIKey(for: provider.id)
            )
        }
    }
}

public struct DefaultAIModelCatalogLoader: AIModelCatalogLoading {
    private let catalog: OpenAICompatibleAIModelCatalog

    public init(transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(timeout: 12)) {
        self.catalog = OpenAICompatibleAIModelCatalog(transport: transport)
    }

    public func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        try catalog.listModels(for: provider, apiKey: apiKey)
    }

    public func listModelEntries(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [AIModelCatalogEntry] {
        try catalog.listModelEntries(for: provider, apiKey: apiKey)
    }
}

public struct DefaultAIAssistantConnectionTester: AIAssistantConnectionTesting {
    private let transport: AIAssistantHTTPTransport

    public init(transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(timeout: 12)) {
        self.transport = transport
    }

    public func testConnection(
        provider: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) throws -> AIAssistantConnectionTestResult {
        guard provider.profile.usesModelInterface else {
            return AIAssistantConnectionTestResult(message: L10n.Settings.aiRulesConnectionSuccess)
        }
        let rawBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawBaseURL.isEmpty == false else {
            throw AIAssistantProviderError.missingBaseURL
        }
        guard let baseURL = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: rawBaseURL) else {
            throw AIAssistantProviderError.invalidBaseURL
        }
        let assistantProvider = OpenAICompatibleAIAssistantProvider(
            baseURL: baseURL,
            model: modelID,
            apiKeyProvider: { apiKey },
            transport: transport,
            maxRetryCount: provider.maxRetryCount,
            userAgent: provider.userAgent,
            requestTimeoutSeconds: provider.requestTimeoutSeconds,
            compatibilityProtocol: provider.compatibilityProtocol
        )
        _ = try assistantProvider.respond(
            to: AIAssistantRequest(
                question: "测试 Stacio AI 连接",
                context: AITerminalContext(
                    runtimeID: "settings-ai-test",
                    title: "设置测试",
                    currentDirectory: nil,
                    recentTranscript: "Stacio settings connection test."
                )
            )
        )
        return AIAssistantConnectionTestResult(message: L10n.Settings.aiConnectionSuccess)
    }
}
