import Foundation

public protocol AIAssistantHTTPTransport {
    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
    func performAsync(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse
}

public extension AIAssistantHTTPTransport {
    func performAsync(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try perform(request)
    }

    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        throw AIAssistantProviderError.streamUnsupported
    }
}

public protocol AIAssistantStreamingProviding {
    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse
}

public final class URLSessionAIAssistantHTTPTransport: AIAssistantHTTPTransport {
    private let session: URLSession
    private let redirectDelegate: AIAssistantRedirectRejectingSessionDelegate
    private let timeout: TimeInterval

    public convenience init(timeout: TimeInterval = 45) {
        self.init(configuration: .default, timeout: timeout)
    }

    init(
        configuration: URLSessionConfiguration,
        timeout: TimeInterval = 45
    ) {
        let redirectDelegate = AIAssistantRedirectRejectingSessionDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        self.timeout = timeout
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>?
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let data,
                  let response = response as? HTTPURLResponse
            else {
                result = .failure(AIAssistantProviderError.invalidResponse)
                return
            }
            result = .success((data, response))
        }
        task.resume()

        let waitTimeout = request.timeoutInterval > 0
            ? request.timeoutInterval
            : timeout
        if semaphore.wait(timeout: .now() + waitTimeout) == .timedOut {
            task.cancel()
            throw AIAssistantProviderError.timeout
        }
        guard let result else {
            throw AIAssistantProviderError.invalidResponse
        }
        return try result.get()
    }

    public func performAsync(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantProviderError.invalidResponse
        }
        return (data, httpResponse)
    }

    public func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIAssistantProviderError.httpStatus(httpResponse.statusCode)
        }
        var buffer = Data()
        buffer.reserveCapacity(4096)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 4096 {
                onChunk(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if buffer.isEmpty == false {
            onChunk(buffer)
        }
        return httpResponse
    }
}

private final class AIAssistantRedirectRejectingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum AIAssistantProviderError: Error, Equatable, LocalizedError {
    case missingBaseURL
    case invalidBaseURL
    case missingModel
    case missingAPIKey
    case insecureBaseURL
    case invalidResponse
    case nonJSONResponse
    case timeout
    case streamUnsupported
    case malformedAssistantPayload
    case cancelled
    case httpStatus(Int)
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "请在设置中填写 AI Base URL"
        case .invalidBaseURL:
            return "AI Base URL 无效"
        case .missingModel:
            return "请在设置中填写 AI 模型"
        case .missingAPIKey:
            return "请在设置中填写 AI API Key"
        case .insecureBaseURL:
            return "AI Base URL 必须使用 HTTPS；HTTP 仅允许 localhost 或其他本机回环地址"
        case .invalidResponse:
            return "AI 返回内容无法解析"
        case .nonJSONResponse:
            return "AI 接口返回的不是 JSON。Stacio 已尝试兼容常见 OpenAI-compatible 路径；请检查 Base URL 是否为模型服务 API 地址，或确认服务没有返回网页、登录页、代理跳转页"
        case .timeout:
            return "AI 请求超时"
        case .streamUnsupported:
            return "AI 服务不支持流式响应"
        case .malformedAssistantPayload:
            return "AI 返回格式异常，请重试"
        case .cancelled:
            return "AI 请求已停止"
        case .httpStatus(let statusCode):
            return "AI 请求失败：HTTP \(statusCode)"
        case .apiError(let statusCode, let message):
            return Self.apiErrorDescription(statusCode: statusCode, message: message)
        }
    }

    private static func apiErrorDescription(statusCode: Int, message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? "" : "，\(trimmed)"
        let lowercased = trimmed.lowercased()
        if statusCode == 401 || statusCode == 403 {
            return "AI API Key 无效或无权限：HTTP \(statusCode)\(suffix)"
        }
        if statusCode == 400, lowercased.contains("model") {
            return "AI 模型配置可能不兼容：HTTP \(statusCode)\(suffix)"
        }
        if statusCode == 400 {
            return "AI 请求参数不兼容：HTTP \(statusCode)\(suffix)"
        }
        if statusCode == 404 {
            return "AI 接口路径或模型不可用：HTTP \(statusCode)\(suffix)"
        }
        if statusCode == 429 {
            return "AI 服务限流：HTTP \(statusCode)\(suffix)"
        }
        if statusCode >= 500 {
            return "AI 服务暂时不可用：HTTP \(statusCode)\(suffix)"
        }
        return "AI 请求失败：HTTP \(statusCode)\(suffix)"
    }
}

public struct OpenAICompatibleAIAssistantProvider: AIAssistantProviding, AIAssistantStreamingProviding {
    private let baseURL: URL
    private let model: String
    private let apiKeyProvider: () throws -> String?
    private let transport: AIAssistantHTTPTransport
    private let maxRetryCount: Int
    private let userAgent: String
    private let requestTimeoutSeconds: Int
    private let reasoningEffort: AIReasoningEffortPreference
    private let compatibilityProtocol: AICompatibilityProtocolPreference

    public init(
        baseURL: URL,
        model: String,
        apiKeyProvider: @escaping () throws -> String?,
        transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(),
        maxRetryCount: Int = 1,
        userAgent: String = "Stacio",
        requestTimeoutSeconds: Int = 45,
        reasoningEffort: AIReasoningEffortPreference = .medium,
        compatibilityProtocol: AICompatibilityProtocolPreference = .chatCompletions
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.maxRetryCount = AppSettings.clampedAIRetryCount(maxRetryCount)
        self.userAgent = AppSettings.normalizedAIUserAgent(userAgent)
        self.requestTimeoutSeconds = AppSettings.clampedAITimeoutSeconds(requestTimeoutSeconds)
        self.reasoningEffort = reasoningEffort
        self.compatibilityProtocol = compatibilityProtocol
    }

    public func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        let configuration = try resolvedConfiguration()
        let payload = try makeRequestPayload(
            for: request,
            normalizedModel: configuration.normalizedModel,
            stream: nil
        )

        var lastRetryableError: Error?
        for (index, endpoint) in payload.endpoints.enumerated() {
            do {
                return try performAIRequest(
                    endpoint: endpoint,
                    apiKey: configuration.apiKey,
                    requestBody: payload.body
                )
            } catch {
                if index < payload.endpoints.count - 1, Self.canRetryWithNextEndpoint(error) {
                    lastRetryableError = error
                    continue
                }
                throw error
            }
        }
        throw lastRetryableError ?? AIAssistantProviderError.invalidResponse
    }

    public func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        let configuration = try resolvedConfiguration()
        let streamingPayload = try makeRequestPayload(
            for: request,
            normalizedModel: configuration.normalizedModel,
            stream: true
        )
        let fallbackPayload = try makeRequestPayload(
            for: request,
            normalizedModel: configuration.normalizedModel,
            stream: nil
        )

        var lastRetryableError: Error?
        for (index, endpoint) in streamingPayload.endpoints.enumerated() {
            do {
                return try await performStreamingAIRequest(
                    endpoint: endpoint,
                    apiKey: configuration.apiKey,
                    requestBody: streamingPayload.body,
                    onPartial: onPartial
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Self.shouldFallbackFromStreaming(error) {
                    do {
                        return try await performAIRequestAsync(
                            endpoint: endpoint,
                            apiKey: configuration.apiKey,
                            requestBody: fallbackPayload.body
                        )
                    } catch {
                        if index < streamingPayload.endpoints.count - 1,
                           Self.canRetryWithNextEndpoint(error) {
                            lastRetryableError = error
                            continue
                        }
                        throw error
                    }
                }
                if index < streamingPayload.endpoints.count - 1,
                   Self.canRetryWithNextEndpoint(error) {
                    lastRetryableError = error
                    continue
                }
                throw error
            }
        }
        throw lastRetryableError ?? AIAssistantProviderError.invalidResponse
    }

    private func resolvedConfiguration() throws -> (apiKey: String?, normalizedModel: String) {
        try AIEndpointSecurityPolicy.validate(baseURL)
        let apiKey = try apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard apiKey.isEmpty == false || AIEndpointSecurityPolicy.isLoopbackHost(baseURL.host) else {
            throw AIAssistantProviderError.missingAPIKey
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty == false else {
            throw AIAssistantProviderError.missingModel
        }
        let normalizedModel = AppSettings.normalizedAIModelName(model)
        guard normalizedModel.isEmpty == false else {
            throw AIAssistantProviderError.missingModel
        }
        return (apiKey.isEmpty ? nil : apiKey, normalizedModel)
    }

    private func makeRequestPayload(
        for request: AIAssistantRequest,
        normalizedModel: String,
        stream: Bool?
    ) throws -> (body: Data, endpoints: [URL]) {
        let requestBody: Data
        let endpoints: [URL]
        switch compatibilityProtocol {
        case .chatCompletions:
            requestBody = try JSONEncoder().encode(
                ChatCompletionRequest(
                    model: normalizedModel,
                    messages: [
                        .text(role: "system", Self.systemPrompt),
                        .user(prompt: Self.userPrompt(for: request), attachments: request.attachments)
                    ],
                    temperature: 0.2,
                    reasoningEffort: reasoningEffort == .minimal ? nil : reasoningEffort.rawValue,
                    stream: stream
                )
            )
            endpoints = Self.chatCompletionsURLs(for: baseURL)
        case .responses:
            requestBody = try JSONEncoder().encode(
                ResponsesRequest(
                    model: normalizedModel,
                    instructions: Self.systemPrompt,
                    input: .from(prompt: Self.userPrompt(for: request), attachments: request.attachments),
                    temperature: 0.2,
                    reasoning: reasoningEffort == .minimal
                        ? nil
                        : ResponsesRequest.Reasoning(effort: reasoningEffort.rawValue),
                    stream: stream
                )
            )
            endpoints = Self.responsesURLs(for: baseURL)
        }
        return (requestBody, endpoints)
    }

    private func performAIRequest(
        endpoint: URL,
        apiKey: String?,
        requestBody: Data
    ) throws -> AIAssistantResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(requestTimeoutSeconds)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = requestBody

        let (data, response) = try performWithTransientRetries(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            if let message = Self.apiErrorMessage(from: data) {
                throw AIAssistantProviderError.apiError(
                    statusCode: response.statusCode,
                    message: Self.redactingExplicitAPIKey(apiKey, from: message)
                )
            }
            throw AIAssistantProviderError.httpStatus(response.statusCode)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AIAssistantProviderError.nonJSONResponse
        }
        let content = try assistantText(from: data)
        return try Self.parseAssistantContent(content)
    }

    private func performAIRequestAsync(
        endpoint: URL,
        apiKey: String?,
        requestBody: Data
    ) async throws -> AIAssistantResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(requestTimeoutSeconds)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = requestBody

        let (data, response) = try await performWithTransientRetriesAsync(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            if let message = Self.apiErrorMessage(from: data) {
                throw AIAssistantProviderError.apiError(
                    statusCode: response.statusCode,
                    message: Self.redactingExplicitAPIKey(apiKey, from: message)
                )
            }
            throw AIAssistantProviderError.httpStatus(response.statusCode)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AIAssistantProviderError.nonJSONResponse
        }
        let content = try assistantText(from: data)
        return try Self.parseAssistantContent(content)
    }

    private func performStreamingAIRequest(
        endpoint: URL,
        apiKey: String?,
        requestBody: Data,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(requestTimeoutSeconds)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = requestBody

        var parser = OpenAICompatibleSSEParser()
        var rawContent = ""
        var visibleText = ""
        var emittedVisibleText = false
        let response = try await transport.stream(urlRequest) { chunk in
            for event in parser.consume(chunk) {
                if event.isDone {
                    continue
                }
                guard let delta = event.contentDelta,
                      delta.isEmpty == false
                else {
                    continue
                }
                rawContent += delta
                let projected = Self.visibleAssistantMessage(fromPartialContent: rawContent)
                guard projected.count > visibleText.count else {
                    continue
                }
                let suffix = String(projected.dropFirst(visibleText.count))
                visibleText = projected
                if suffix.isEmpty == false {
                    emittedVisibleText = true
                    onPartial(suffix)
                }
            }
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw AIAssistantProviderError.httpStatus(response.statusCode)
        }
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw AIAssistantProviderError.streamUnsupported
        }
        let parsed = try Self.parseAssistantContent(content)
        if parsed.message != visibleText {
            let suffix: String
            if parsed.message.hasPrefix(visibleText) {
                suffix = String(parsed.message.dropFirst(visibleText.count))
            } else if emittedVisibleText == false {
                suffix = parsed.message
            } else {
                suffix = ""
            }
            if suffix.isEmpty == false {
                onPartial(suffix)
            }
        }
        return parsed
    }

    private func assistantText(from data: Data) throws -> String {
        switch compatibilityProtocol {
        case .chatCompletions:
            let completion: ChatCompletionResponse
            do {
                completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            } catch {
                throw AIAssistantProviderError.invalidResponse
            }
            guard let content = completion.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  content.isEmpty == false
            else {
                throw AIAssistantProviderError.invalidResponse
            }
            return content
        case .responses:
            let response: ResponsesResponse
            do {
                response = try JSONDecoder().decode(ResponsesResponse.self, from: data)
            } catch {
                throw AIAssistantProviderError.invalidResponse
            }
            let content = response.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.isEmpty == false else {
                throw AIAssistantProviderError.invalidResponse
            }
            return content
        }
    }

    private func performWithTransientRetries(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
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

    private func performWithTransientRetriesAsync(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetryCount {
            do {
                let result = try await transport.performAsync(request)
                guard Self.isTransientHTTPStatus(result.1.statusCode),
                      attempt < maxRetryCount
                else {
                    return result
                }
                lastError = AIAssistantProviderError.httpStatus(result.1.statusCode)
            } catch is CancellationError {
                throw CancellationError()
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

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let value = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: value),
              let host = canonicalHost(from: components.host),
              components.user == nil,
              components.password == nil,
              isValidPort(components.port)
        else {
            return nil
        }
        if trimmed.contains("://") {
            guard let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else {
                return nil
            }
            components.scheme = scheme
        } else {
            components.scheme = defaultScheme(for: host)
        }
        components.query = nil
        components.fragment = nil
        components.path = trimTrailingSlashes(components.path)
        return components.url
    }

    static func chatCompletionsURLs(for baseURL: URL) -> [URL] {
        let normalized = normalizedAPIURL(baseURL)
        let pathComponents = normalized.path
            .split(separator: "/")
            .map { String($0).lowercased() }
        if hasChatCompletionsSuffix(pathComponents) {
            return [normalized]
        }

        var candidates: [URL] = []
        candidates.append(normalized.appendingPathComponent("chat").appendingPathComponent("completions"))
        if pathComponents.last != "v1" {
            candidates.append(
                normalized
                    .appendingPathComponent("v1")
                    .appendingPathComponent("chat")
                    .appendingPathComponent("completions")
            )
        }
        return uniqueURLs(candidates)
    }

    static func responsesURLs(for baseURL: URL) -> [URL] {
        let normalized = normalizedAPIURL(baseURL)
        let pathComponents = normalized.path
            .split(separator: "/")
            .map { String($0).lowercased() }
        if pathComponents.last == "responses" {
            return [normalized]
        }

        var candidates: [URL] = []
        candidates.append(normalized.appendingPathComponent("responses"))
        if pathComponents.last != "v1" {
            candidates.append(normalized.appendingPathComponent("v1").appendingPathComponent("responses"))
        }
        return uniqueURLs(candidates)
    }

    static func normalizedAPIURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.query = nil
        components.fragment = nil
        components.path = trimTrailingSlashes(components.path)
        return components.url ?? url
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func hasChatCompletionsSuffix(_ components: [String]) -> Bool {
        components.count >= 2
            && components[components.count - 2] == "chat"
            && components[components.count - 1] == "completions"
    }

    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.absoluteString).inserted
        }
    }

    static func canRetryWithNextEndpoint(_ error: Error) -> Bool {
        guard let providerError = error as? AIAssistantProviderError else {
            return false
        }
        switch providerError {
        case .nonJSONResponse:
            return true
        case .httpStatus(let statusCode):
            return statusCode == 404 || statusCode == 405
        case .apiError(let statusCode, _):
            return statusCode == 404 || statusCode == 405
        default:
            return false
        }
    }

    private static func shouldFallbackFromStreaming(_ error: Error) -> Bool {
        if isTransientTransportError(error) {
            return true
        }
        guard let providerError = error as? AIAssistantProviderError else {
            return false
        }
        switch providerError {
        case .streamUnsupported, .nonJSONResponse, .malformedAssistantPayload:
            return true
        case .httpStatus(let statusCode):
            return [400, 404, 405, 406, 415, 422].contains(statusCode)
        case .apiError(let statusCode, _):
            return [400, 404, 405, 406, 415, 422].contains(statusCode)
        default:
            return false
        }
    }

    private static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        if let providerError = error as? AIAssistantProviderError {
            switch providerError {
            case .timeout:
                return true
            default:
                return false
            }
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

    static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let rawMessage: String?
        if let dictionary = object as? [String: Any] {
            if let error = dictionary["error"] as? [String: Any] {
                rawMessage = error["message"] as? String
                    ?? error["code"] as? String
                    ?? error["type"] as? String
            } else {
                rawMessage = dictionary["error"] as? String
                    ?? dictionary["message"] as? String
                    ?? detailMessage(from: dictionary["detail"])
            }
        } else {
            rawMessage = nil
        }
        guard let rawMessage else {
            return nil
        }
        let redacted = redactSensitiveTokens(in: rawMessage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? nil : redacted
    }

    static func redactingExplicitAPIKey(
        _ apiKey: String?,
        from message: String
    ) -> String {
        guard let apiKey, apiKey.isEmpty == false else {
            return message
        }
        return message.replacingOccurrences(
            of: apiKey,
            with: L10n.Diagnostics.redactedCredential
        )
    }

    private static func redactSensitiveTokens(in message: String) -> String {
        let tokens = message.split(whereSeparator: \.isWhitespace).map(String.init)
        var redacted: [String] = []
        var shouldRedactNextAPIKeyValue = false
        for token in tokens {
            let value = token
            let lowercased = value.lowercased()
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}\"'"))
            if shouldRedactNextAPIKeyValue {
                redacted.append(value.replacingOccurrences(of: trimmed, with: L10n.Diagnostics.redactedCredential))
                shouldRedactNextAPIKeyValue = false
                continue
            }
            if lowercased == "key",
               redacted.last?.lowercased() == "api" {
                shouldRedactNextAPIKeyValue = true
                redacted.append(value)
                continue
            }
            if trimmed.hasPrefix("sk-")
                || trimmed.hasPrefix("ghp_")
                || trimmed.hasPrefix("gho_")
                || trimmed.hasPrefix("github_pat_")
            {
                redacted.append(value.replacingOccurrences(of: trimmed, with: L10n.Diagnostics.redactedCredential))
                continue
            }
            if let separatorIndex = value.firstIndex(of: "=") {
                let key = String(value[..<separatorIndex]).lowercased()
                if key.contains("key")
                    || key.contains("token")
                    || key.contains("secret")
                    || key.contains("password")
                    || key.contains("credential") {
                    redacted.append("\(value[..<value.index(after: separatorIndex)])\(L10n.Diagnostics.redactedCredential)")
                    continue
                }
            }
            redacted.append(value)
        }
        return redacted.joined(separator: " ")
    }

    private static func detailMessage(from value: Any?) -> String? {
        if let message = value as? String {
            return message
        }
        if let entries = value as? [[String: Any]] {
            let messages = entries.compactMap { entry -> String? in
                if let message = entry["msg"] as? String {
                    return message
                }
                if let message = entry["message"] as? String {
                    return message
                }
                return nil
            }
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
        return nil
    }

    private static func canonicalHost(from host: String?) -> String? {
        guard let host, host.isEmpty == false else {
            return nil
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func defaultScheme(for host: String) -> String {
        AIEndpointSecurityPolicy.isLoopbackHost(host) ? "http" : "https"
    }

    private static func isValidPort(_ port: Int?) -> Bool {
        guard let port else {
            return true
        }
        return (1...65535).contains(port)
    }

    private static func parseAssistantContent(_ content: String) throws -> AIAssistantResponse {
        if let payload = decodeAssistantPayload(from: content) {
            return AIAssistantResponse(
                message: payload.message,
                commandProposals: payload.commands.map {
                    AgentCommandProposal(
                        command: $0.command,
                        explanation: $0.explanation
                    )
                }
            )
        }
        throw AIAssistantProviderError.malformedAssistantPayload
    }

    private static func decodeAssistantPayload(from content: String) -> AssistantPayload? {
        let trimmed = stripCodeFence(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AssistantPayload.self, from: data)
    }

    private static func stripCodeFence(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else {
            return trimmed
        }
        var lines = trimmed.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func firstShellCommand(in content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var isInFence = false
        var captured: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                if isInFence {
                    break
                }
                isInFence = true
                continue
            }
            if isInFence, trimmed.isEmpty == false {
                captured.append(trimmed)
            }
        }
        return captured.isEmpty ? nil : captured.joined(separator: "\n")
    }

    private static func visibleAssistantMessage(fromPartialContent content: String) -> String {
        if let payload = decodeAssistantPayload(from: content) {
            return payload.message
        }
        let trimmed = stripCodeFence(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return content
        }
        return partialJSONStringValue(named: "message", in: trimmed) ?? ""
    }

    private static func partialJSONStringValue(named fieldName: String, in content: String) -> String? {
        let pattern = #""\#(NSRegularExpression.escapedPattern(for: fieldName))"\s*:\s*""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let start = Range(match.range, in: content)?.upperBound
        else {
            return nil
        }
        var output = ""
        var index = start
        var isEscaped = false
        while index < content.endIndex {
            let character = content[index]
            if isEscaped {
                switch character {
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                default:
                    output.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return output
            } else {
                output.append(character)
            }
            index = content.index(after: index)
        }
        return output
    }

    private static func userPrompt(for request: AIAssistantRequest) -> String {
        var lines = [
            "用户问题：\(request.question)",
            "目标终端：\(request.context.title)",
            "Runtime ID：\(request.context.runtimeID)",
            "当前目录：\(request.context.currentDirectory ?? "未知")",
            "最近终端输出：",
            request.context.recentTranscript
        ]
        if request.attachments.isEmpty == false {
            lines.append("附件：")
            lines.append(contentsOf: request.attachments.enumerated().map { index, attachment in
                "\(index + 1). \(attachment.promptSummary)"
            })
        }
        return lines.joined(separator: "\n")
    }

    private static let systemPrompt = """
    你是 Stacio 内置 AI 助手，面向远程运维终端场景。
    始终返回一个 JSON 对象，不要在 JSON 外输出任何文字。
    JSON 结构必须为 {"message":"中文 Markdown 回复","commands":[{"command":"可选 shell 命令","explanation":"为什么执行"}]}。
    普通问答时，把完整回答写在 message，commands 返回空数组；需要建议写入终端的命令时，才填 commands。
    命令必须适合写入当前可见终端，优先只读诊断命令；不要请求或输出密码、私钥、token 等秘密。
    message 可以使用标题、列表、粗体、行内代码和代码块；不要为了满足 JSON 而答非所问。
    """
}

public enum AIAssistantProviderFactory {
    public static func makeProvider(
        settings snapshot: AppSettings,
        requestedSelection: AIModelSelection?,
        apiKeyProvider: @escaping (UUID) throws -> String?,
        transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport()
    ) -> AIAssistantProviding {
        switch AIProviderRuntimeResolver.resolve(
            envelope: snapshot.aiProviderSettings,
            requestedSelection: requestedSelection
        ) {
        case .stacioRules:
            return RuleBasedAIAssistantProvider()
        case let .external(provider, modelID):
            let model = provider.models.first(where: { $0.id == modelID })
            return makeExternalProvider(
                provider: provider,
                modelID: modelID,
                reasoningEffort: model?.capabilities.effectiveReasoningEffort ?? .minimal,
                apiKeyProvider: apiKeyProvider,
                transport: transport
            )
        }
    }

    private static func makeExternalProvider(
        provider: AIProviderConfiguration,
        modelID: String,
        reasoningEffort: AIReasoningEffortPreference,
        apiKeyProvider: (UUID) throws -> String?,
        transport: AIAssistantHTTPTransport
    ) -> AIAssistantProviding {
        let rawBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawBaseURL.isEmpty == false else {
            return FailingAIAssistantProvider(error: AIAssistantProviderError.missingBaseURL)
        }
        guard let baseURL = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: rawBaseURL) else {
            return FailingAIAssistantProvider(error: AIAssistantProviderError.invalidBaseURL)
        }
        do {
            try AIEndpointSecurityPolicy.validate(baseURL)
        } catch {
            return FailingAIAssistantProvider(error: error)
        }

        let normalizedModel = AppSettings.normalizedAIModelName(modelID)
        guard normalizedModel.isEmpty == false else {
            return FailingAIAssistantProvider(error: AIAssistantProviderError.missingModel)
        }

        let apiKey: String?
        do {
            let candidate = try apiKeyProvider(provider.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            apiKey = candidate?.isEmpty == false ? candidate : nil
        } catch {
            return FailingAIAssistantProvider(error: error)
        }
        guard apiKey != nil || AIEndpointSecurityPolicy.isLoopbackHost(baseURL.host) else {
            return FailingAIAssistantProvider(error: AIAssistantProviderError.missingAPIKey)
        }

        return OpenAICompatibleAIAssistantProvider(
            baseURL: baseURL,
            model: normalizedModel,
            apiKeyProvider: { apiKey },
            transport: transport,
            maxRetryCount: provider.maxRetryCount,
            userAgent: provider.userAgent,
            requestTimeoutSeconds: provider.requestTimeoutSeconds,
            reasoningEffort: reasoningEffort,
            compatibilityProtocol: provider.compatibilityProtocol
        )
    }
}

public final class SettingsBackedAIAssistantProvider: AIAssistantProviding, AIAssistantStreamingProviding {
    private let settingsStore: AppSettingsStore
    private let apiKeyProvider: (UUID) throws -> String?
    private let transport: AIAssistantHTTPTransport
    private let selectionSession: AIModelSelectionSession

    public init(
        settingsStore: AppSettingsStore,
        apiKeyStore: AIApiKeyStoring = KeychainAIApiKeyStore(),
        transport: AIAssistantHTTPTransport = URLSessionAIAssistantHTTPTransport(),
        selectionSession: AIModelSelectionSession = AIModelSelectionSession()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
        self.selectionSession = selectionSession
        if let migrationCapableStore = apiKeyStore as? (AIApiKeyStoring & LegacyAIApiKeyReading) {
            let coordinator = AIProviderConfigurationCoordinator(
                settingsStore: settingsStore,
                keyStore: migrationCapableStore
            )
            self.apiKeyProvider = { providerID in
                try coordinator.readAPIKey(for: providerID)
            }
        } else {
            self.apiKeyProvider = { providerID in
                try apiKeyStore.readAPIKey(for: providerID)
            }
        }
    }

    public func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        let provider = makeProviderForCurrentRequest()
        return try provider.respond(to: request)
    }

    public func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        let provider = makeProviderForCurrentRequest()
        if let streamingProvider = provider as? AIAssistantStreamingProviding {
            return try await streamingProvider.respondStreaming(to: request, onPartial: onPartial)
        }
        return try await provider.respondAsync(to: request)
    }

    private func makeProviderForCurrentRequest() -> AIAssistantProviding {
        AIProviderConfigurationCoordinator.withSharedTransaction {
            let requestedSelection = selectionSession.snapshot()
            let settings = settingsStore.snapshot()
            return AIAssistantProviderFactory.makeProvider(
                settings: settings,
                requestedSelection: requestedSelection,
                apiKeyProvider: apiKeyProvider,
                transport: transport
            )
        }
    }
}

private extension AIAssistantProviding {
    func respondAsync(to request: AIAssistantRequest) async throws -> AIAssistantResponse {
        try respond(to: request)
    }
}

private struct FailingAIAssistantProvider: AIAssistantProviding {
    let error: Error

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        throw error
    }
}

struct OpenAICompatibleSSEEvent: Equatable {
    let contentDelta: String?
    let isDone: Bool
}

struct OpenAICompatibleSSEParser {
    private var pendingText = ""
    private(set) var isDone = false

    mutating func consume(_ data: Data) -> [OpenAICompatibleSSEEvent] {
        guard isDone == false,
              let chunk = String(data: data, encoding: .utf8)
        else {
            return []
        }
        pendingText += chunk
        var events: [OpenAICompatibleSSEEvent] = []
        while let newlineRange = pendingText.rangeOfCharacter(from: .newlines) {
            var line = String(pendingText[..<newlineRange.lowerBound])
            pendingText.removeSubrange(pendingText.startIndex...newlineRange.lowerBound)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            guard line.hasPrefix("data:") else {
                continue
            }
            let dataLine = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if dataLine == "[DONE]" {
                isDone = true
                events.append(OpenAICompatibleSSEEvent(contentDelta: nil, isDone: true))
                continue
            }
            guard let event = Self.event(from: dataLine) else {
                continue
            }
            events.append(event)
        }
        return events
    }

    private static func event(from line: String) -> OpenAICompatibleSSEEvent? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        if let chat = try? JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data) {
            let delta = chat.choices.compactMap(\.delta.content).joined()
            guard delta.isEmpty == false else {
                return nil
            }
            return OpenAICompatibleSSEEvent(contentDelta: delta, isDone: false)
        }
        if let response = try? JSONDecoder().decode(ResponsesStreamChunk.self, from: data) {
            let delta = response.contentDelta
            guard delta.isEmpty == false else {
                return nil
            }
            return OpenAICompatibleSSEEvent(contentDelta: delta, isDone: false)
        }
        return nil
    }
}

private struct ChatCompletionStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    let choices: [Choice]
}

private struct ResponsesStreamChunk: Decodable {
    let type: String?
    let delta: String?
    let text: String?
    let outputText: String?

    var contentDelta: String {
        if let delta {
            return delta
        }
        if let text {
            return text
        }
        return outputText ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case delta
        case text
        case outputText = "output_text"
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        struct ContentPart: Encodable {
            struct ImageURL: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let imageURL: ImageURL?

            private enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }

            static func text(_ value: String) -> ContentPart {
                ContentPart(type: "text", text: value, imageURL: nil)
            }

            static func imageURL(_ value: String) -> ContentPart {
                ContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: value))
            }
        }

        let role: String
        let content: Content

        enum Content: Encodable {
            case text(String)
            case parts([ContentPart])

            func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let value):
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                case .parts(let parts):
                    var container = encoder.singleValueContainer()
                    try container.encode(parts)
                }
            }
        }

        static func text(role: String, _ content: String) -> Message {
            Message(role: role, content: .text(content))
        }

        static func user(prompt: String, attachments: [AIAssistantAttachment]) -> Message {
            let imageParts = attachments.compactMap(\.dataURL).map(ContentPart.imageURL)
            guard imageParts.isEmpty == false else {
                return .text(role: "user", prompt)
            }
            return Message(role: "user", content: .parts([.text(prompt)] + imageParts))
        }
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let reasoningEffort: String?
    let stream: Bool?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case reasoningEffort = "reasoning_effort"
        case stream
    }
}

private struct ResponsesRequest: Encodable {
    struct Reasoning: Encodable {
        let effort: String
    }

    struct InputItem: Encodable {
        struct ContentPart: Encodable {
            struct ImageURL: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let imageURL: ImageURL?

            private enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }

            static func inputText(_ value: String) -> ContentPart {
                ContentPart(type: "input_text", text: value, imageURL: nil)
            }

            static func inputImage(_ value: String) -> ContentPart {
                ContentPart(type: "input_image", text: nil, imageURL: ImageURL(url: value))
            }
        }

        let role: String
        let content: [ContentPart]
    }

    enum Input: Encodable {
        case text(String)
        case items([InputItem])

        static func from(prompt: String, attachments: [AIAssistantAttachment]) -> Input {
            let imageParts = attachments.compactMap(\.dataURL).map(InputItem.ContentPart.inputImage)
            guard imageParts.isEmpty == false else {
                return .text(prompt)
            }
            return .items([
                InputItem(role: "user", content: [.inputText(prompt)] + imageParts)
            ])
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .items(let items):
                var container = encoder.singleValueContainer()
                try container.encode(items)
            }
        }
    }

    let model: String
    let instructions: String
    let input: Input
    let temperature: Double
    let reasoning: Reasoning?
    let stream: Bool?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String

            private enum CodingKeys: String, CodingKey {
                case content
            }

            private struct ContentPart: Decodable {
                let type: String?
                let text: String?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let content = try? container.decode(String.self, forKey: .content) {
                    self.content = content
                    return
                }
                let parts = try container.decode([ContentPart].self, forKey: .content)
                self.content = parts
                    .filter { part in
                        part.type == nil || part.type == "text"
                    }
                    .compactMap(\.text)
                    .joined()
            }
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ResponsesResponse: Decodable {
    struct OutputItem: Decodable {
        struct ContentPart: Decodable {
            let type: String?
            let text: String?
        }

        let content: [ContentPart]?
    }

    let outputText: String?
    let output: [OutputItem]?

    var assistantText: String {
        if let outputText, outputText.isEmpty == false {
            return outputText
        }
        var pieces: [String] = []
        for item in output ?? [] {
            for part in item.content ?? [] {
                if part.type == nil || part.type == "output_text" || part.type == "text",
                   let text = part.text {
                    pieces.append(text)
                }
            }
        }
        return pieces.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }
}

private struct AssistantPayload: Decodable {
    struct Command: Decodable {
        let command: String
        let explanation: String
    }

    let message: String
    let commands: [Command]

    private enum CodingKeys: String, CodingKey {
        case message
        case commands
        case command
        case explanation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        if let commands = try container.decodeIfPresent([Command].self, forKey: .commands) {
            self.commands = commands
            return
        }
        let command = (try container.decodeIfPresent(String.self, forKey: .command))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let command, command.isEmpty == false {
            let explanation = (try container.decodeIfPresent(String.self, forKey: .explanation))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedExplanation: String
            if let explanation, explanation.isEmpty == false {
                resolvedExplanation = explanation
            } else {
                resolvedExplanation = "AI 建议执行此命令。"
            }
            self.commands = [
                Command(
                    command: command,
                    explanation: resolvedExplanation
                )
            ]
        } else {
            self.commands = []
        }
    }
}
