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

    /// The list may contain only IDs. Query the selected model, then ask the
    /// chat endpoint to validate its effort parameter when metadata is absent.
    func discoverReasoning(for provider: AIProviderConfiguration, modelID: String, apiKey: String?) throws -> AIModelCatalogCapabilities {
        let entries = (try? listModelEntries(for: provider, apiKey: apiKey)) ?? []
        var capability = entries.first { $0.id == modelID }?.capabilities ?? .init()
        if capability.supportsImages == nil, let url = AgentModelClient.chatCompletionsURL(baseURL: provider.baseURL) {
            try AIEndpointSecurityPolicy.validate(url)
            capability.supportsImages = try? probeImages(url, modelID, apiKey)
        }
        guard capability.supportedReasoningEfforts == nil, capability.supportsThinking != false,
              let url = AgentModelClient.chatCompletionsURL(baseURL: provider.baseURL) else { return capability }
        try AIEndpointSecurityPolicy.validate(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": "What is 17 times 13?"]],
            "max_tokens": 64, "reasoning_effort": "stacio-capability-probe"
        ])
        guard let (data, response) = try? transport.perform(request) else { return capability }
        if [400, 422].contains(response.statusCode),
           let error = OpenAICompatibleAIAssistantProvider.apiErrorMessage(from: data)?.lowercased(),
           error.contains("reasoning_effort") || error.contains("reasoning effort") {
            let words = Set(error.split { !$0.isLetter }.map(String.init))
            let supported = AIReasoningEffortPreference.allCases.filter { words.contains($0.rawValue) }
            if !supported.isEmpty { capability.supportedReasoningEfforts = supported; capability.supportsThinking = true }
        } else if response.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                  let reasoning = (message["reasoning_content"] ?? message["reasoning"]) as? String, !reasoning.isEmpty {
            capability.supportsThinking = true
        }
        return capability
    }

    private func probeImages(_ url: URL, _ modelID: String, _ apiKey: String?) throws -> Bool? {
        let colors = [
            ("red", "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC"),
            ("blue", "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdNvJ8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ2oPcf88OIhvJ6vAAAAAElFTkSuQmCC"),
            ("green", "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLu58QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ24Pbjs8OLsrFddAAAAAElFTkSuQmCC"),
            ("yellow", "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAdklEQVR4nO3PQQkAMAzAwPo33Yno4xgEIuAyu/N1XtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWjBsQcyl+HSnr9raQAAAABJRU5ErkJggg==")
        ].shuffled().prefix(2)
        var parts: [[String: Any]] = [["type": "text", "text": "Name each image's solid color in order. Reply with only two English color names."]]
        for (_, png) in colors {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + png]])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID, "messages": [["role": "user", "content": parts]], "max_tokens": 512])
        let (data, response) = try transport.perform(request)
        if [400, 415, 422].contains(response.statusCode), let error = OpenAICompatibleAIAssistantProvider.apiErrorMessage(from: data)?.lowercased(), (error.contains("image") || error.contains("vision")), (error.contains("not support") || error.contains("unsupported") || error.contains("text-only")) { return false }
        guard response.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any], let answer = message["content"] as? String else { return nil }
        return answer.lowercased().split { !$0.isLetter }.map(String.init) == colors.map { $0.0 } ? true : nil
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
            var entry = AIModelCatalogEntry(
                id: id,
                capabilities: AIModelCatalogCapabilities(
                    contextWindowTokens: model.contextWindowTokens,
                    supportedReasoningEfforts: model.supportedReasoningEfforts
                )
            )
            entry.capabilities.supportsImages = model.supportsImages
            entry.capabilities.supportsThinking = model.supportsThinking
            return entry
        }
    }
}

private struct ModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let supportsImages: Bool?
        let supportsThinking: Bool?
        let contextWindowTokens: Int?
        let supportedReasoningEfforts: [AIReasoningEffortPreference]?

        private enum CodingKeys: String, CodingKey {
            case id
            case supportsImages = "supports_vision"
            case inputModalities = "input_modalities"
            case architecture
            case supportsThinking = "supports_reasoning"
            case supportedParameters = "supported_parameters"
            case contextWindowTokens = "context_window"
            case contextLength = "context_length"
            case contextWindowSize = "context_window_size"
            case supportedReasoningEfforts = "supported_reasoning_efforts"
            case reasoningEfforts = "reasoning_efforts"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let architecture = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .architecture)
            let modalities = (try? container.decode([String].self, forKey: .inputModalities)) ?? (try? architecture?.decode([String].self, forKey: .inputModalities))
            supportsImages = (try? container.decode(Bool.self, forKey: .supportsImages)) ?? modalities.flatMap { $0.isEmpty ? nil : $0.contains { $0.lowercased() == "image" } }
            id = try container.decode(String.self, forKey: .id)
            contextWindowTokens = try container.decodeIfPresent(
                Int.self,
                forKey: .contextWindowTokens
            ) ?? container.decodeIfPresent(Int.self, forKey: .contextLength)
                ?? container.decodeIfPresent(Int.self, forKey: .contextWindowSize)
            let efforts = try container.decodeIfPresent([String].self, forKey: .supportedReasoningEfforts)
                ?? container.decodeIfPresent([String].self, forKey: .reasoningEfforts)
            supportedReasoningEfforts = efforts?.compactMap(AIReasoningEffortPreference.init(rawValue:))
            let parameters = try container.decodeIfPresent([String].self, forKey: .supportedParameters) ?? []
            supportsThinking = try container.decodeIfPresent(Bool.self, forKey: .supportsThinking)
                ?? ((efforts?.isEmpty == false || parameters.contains("reasoning") || parameters.contains("reasoning_effort")) ? true : nil)
        }
    }

    let data: [Model]
}
