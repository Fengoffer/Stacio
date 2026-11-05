import Foundation

public struct OpenAICompatibleAIModelCatalog: AIModelCatalogLoading {
    private struct RequestConfiguration {
        let baseURL: URL
        let maxRetryCount: Int
        let requestTimeoutSeconds: Int
        let userAgent: String
    }

    private let transport: AIAssistantHTTPTransport
    public init(
        transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport()
    ) {
        self.transport = transport
    }

    public func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        try listModelEntries(for: provider, apiKey: apiKey).map(\.id)
    }

    public func listModelEntries(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [AIModelCatalogEntry] {
        let rawBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawBaseURL.isEmpty == false else {
            throw AIAssistantProviderError.missingBaseURL
        }
        guard let baseURL = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: rawBaseURL) else {
            throw AIAssistantProviderError.invalidBaseURL
        }
        return try listModels(
            configuration: RequestConfiguration(
                baseURL: baseURL,
                maxRetryCount: AppSettings.clampedAIRetryCount(provider.maxRetryCount),
                requestTimeoutSeconds: AppSettings.clampedAITimeoutSeconds(provider.requestTimeoutSeconds),
                userAgent: AppSettings.normalizedAIUserAgent(provider.userAgent)
            ),
            apiKey: apiKey
        )
    }

    private func listModels(
        configuration: RequestConfiguration,
        apiKey: String?
    ) throws -> [AIModelCatalogEntry] {
        try AIEndpointSecurityPolicy.validate(configuration.baseURL)
        let normalizedAPIKey = apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalizedAPIKey.isEmpty == false
                || AIEndpointSecurityPolicy.isLoopbackHost(configuration.baseURL.host)
        else {
            throw AIAssistantProviderError.missingAPIKey
        }

        let endpoints = Self.modelURLs(for: configuration.baseURL)
        for (index, endpoint) in endpoints.enumerated() {
            do {
                return try fetchModels(
                    endpoint: endpoint,
                    apiKey: normalizedAPIKey.isEmpty ? nil : normalizedAPIKey,
                    configuration: configuration
                )
            } catch {
                guard index < endpoints.count - 1,
                      Self.canFallbackToNextEndpoint(after: error)
                else {
                    throw error
                }
            }
        }
        throw AIAssistantProviderError.invalidResponse
    }

    private func fetchModels(
        endpoint: URL,
        apiKey: String?,
        configuration: RequestConfiguration
    ) throws -> [AIModelCatalogEntry] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(configuration.requestTimeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try performWithTransientRetries(
            request,
            maxRetryCount: configuration.maxRetryCount
        )
        guard (200..<300).contains(response.statusCode) else {
            if let message = OpenAICompatibleAIAssistantProvider.apiErrorMessage(from: data) {
                throw AIAssistantProviderError.apiError(
                    statusCode: response.statusCode,
                    message: OpenAICompatibleAIAssistantProvider.redactingExplicitAPIKey(
                        apiKey,
                        from: message
                    )
                )
            }
            throw AIAssistantProviderError.httpStatus(response.statusCode)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AIAssistantProviderError.nonJSONResponse
        }

        let responseBody: ModelListResponse
        do {
            responseBody = try JSONDecoder().decode(ModelListResponse.self, from: data)
        } catch {
            throw AIAssistantProviderError.invalidResponse
        }
        let entries = normalizedEntries(from: responseBody.data)
        guard entries.isEmpty == false else {
            throw AIAssistantProviderError.invalidResponse
        }
        return entries
    }

    private func performWithTransientRetries(
        _ request: URLRequest,
        maxRetryCount: Int
    ) throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetryCount {
            do {
                let result = try transport.perform(request)
                guard Self.isTransientHTTPStatus(result.1.statusCode),
                      attempt < maxRetryCount
                else {
                    return result
                }
                lastError = AIAssistantProviderError.httpStatus(result.1.statusCode)
            } catch {
                guard Self.isTransientTransportError(error),
                      attempt < maxRetryCount
                else {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError ?? AIAssistantProviderError.invalidResponse
    }

    private static func canFallbackToNextEndpoint(after error: Error) -> Bool {
        guard let error = error as? AIAssistantProviderError else {
            return false
        }
        switch error {
        case .nonJSONResponse, .invalidResponse:
            return true
        case .httpStatus(let statusCode), .apiError(let statusCode, _):
            return statusCode == 404 || statusCode == 405
        default:
            return false
        }
    }

    private static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        if let providerError = error as? AIAssistantProviderError,
           providerError == .timeout {
            return true
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet
        ].contains(nsError.code)
    }

    private static func modelURLs(for baseURL: URL) -> [URL] {
        let normalized = OpenAICompatibleAIAssistantProvider.normalizedAPIURL(baseURL)
        let normalizedPathComponents = normalized.path
            .split(separator: "/")
            .map { String($0).lowercased() }
        let catalogBaseURL: URL
        if normalizedPathComponents.count >= 2,
           normalizedPathComponents.suffix(2).elementsEqual(["chat", "completions"])
        {
            catalogBaseURL = normalized
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        } else if normalizedPathComponents.last == "responses" {
            catalogBaseURL = normalized.deletingLastPathComponent()
        } else {
            catalogBaseURL = normalized
        }
        let pathComponents = catalogBaseURL.path
            .split(separator: "/")
            .map { String($0).lowercased() }
        if pathComponents.last == "models" {
            return [catalogBaseURL]
        }
        var candidates = [catalogBaseURL.appendingPathComponent("models")]
        if pathComponents.last != "v1" {
            candidates.append(
                catalogBaseURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("models")
            )
        }
        return OpenAICompatibleAIAssistantProvider.uniqueURLs(candidates)
    }

    private func normalizedEntries(
        from models: [ModelListResponse.Model]
    ) -> [AIModelCatalogEntry] {
        var seen = Set<String>()
        return models.compactMap { model in
            let id = AppSettings.normalizedAIModelName(model.id)
            guard id.isEmpty == false,
                  seen.insert(id).inserted
            else {
                return nil
            }
            return AIModelCatalogEntry(
                id: id,
                capabilities: AIModelCatalogCapabilities(
                    contextWindowTokens: model.contextWindowTokens,
                    supportedReasoningEfforts: model.supportedReasoningEfforts
                )
            )
        }
    }
}

private struct ModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let contextWindowTokens: Int?
        let supportedReasoningEfforts: [AIReasoningEffortPreference]?

        private enum CodingKeys: String, CodingKey {
            case id
            case contextWindowTokens = "context_window"
            case contextLength = "context_length"
            case contextWindowSize = "context_window_size"
            case supportedReasoningEfforts = "supported_reasoning_efforts"
            case reasoningEfforts = "reasoning_efforts"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            contextWindowTokens = try container.decodeIfPresent(
                Int.self,
                forKey: .contextWindowTokens
            ) ?? container.decodeIfPresent(Int.self, forKey: .contextLength)
                ?? container.decodeIfPresent(Int.self, forKey: .contextWindowSize)
            supportedReasoningEfforts = try container.decodeIfPresent(
                [AIReasoningEffortPreference].self,
                forKey: .supportedReasoningEfforts
            ) ?? container.decodeIfPresent(
                [AIReasoningEffortPreference].self,
                forKey: .reasoningEfforts
            )
        }
    }

    let data: [Model]
}
