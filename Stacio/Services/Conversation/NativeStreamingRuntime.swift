import Foundation

// MARK: - NativeStreamingRuntime（真实流式 Runtime，P核心闭环·步骤 4）

/// Provider 运行时配置值对象（baseURL/model/apiKey/timeout）。
/// 不硬编码 URL/模型名——值来自 `LegacyProviderConfigurationAdapter`（V1 配置迁移）
/// 或后续 V2 ProviderConfigurationStore。`apiKey` 经 Keychain 读取，不持久化在此值对象。
public struct ProviderRuntimeConfiguration: Equatable, Sendable, CustomStringConvertible {
    public let configurationID: String?
    public let configurationRevision: Int
    public let runtimeConfigurationKind: AIProviderRuntimeConfigurationKind
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    /// Non-secret identity for the credential material captured by this runtime
    /// binding. Durable authentication snapshots store this value, never a hash
    /// of the API key itself. Callers backed by a credential lifecycle store
    /// should pass its immutable generation ID.
    public let credentialGenerationID: String?
    public let requestTimeoutSeconds: Int
    public let userAgent: String
    public let supportedReasoningEfforts: [AIReasoningEffortPreference]?

    public var hasCredential: Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public var description: String {
        let generationID = credentialGenerationID ?? "none"
        return "ProviderRuntimeConfiguration(configurationID: \(effectiveConfigurationID), kind: \(runtimeConfigurationKind.rawValue), endpoint: \(Self.normalizedEndpointIdentity(baseURL)), model: \(model), apiKey: [redacted], credentialGenerationID: \(generationID), requestTimeoutSeconds: \(requestTimeoutSeconds), userAgent: \(userAgent))"
    }

    /// Durable runtime selection requires a non-empty identity. Older V1/test
    /// adapters may omit `configurationID`; derive a deterministic, non-secret
    /// identity from the endpoint, model, kind and revision so the omission
    /// cannot silently become an unresolved route during replay.
    public var effectiveConfigurationID: String {
        if let configurationID {
            let normalized = configurationID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty == false { return normalized }
        }
        return Self.derivedConfigurationID(
            runtimeConfigurationKind: runtimeConfigurationKind,
            endpointIdentity: Self.normalizedEndpointIdentity(baseURL),
            model: model,
            configurationRevision: configurationRevision
        )
    }

    /// IDs emitted by older builds. The literal value preserves compatibility
    /// with a historical interpolation bug; the origin-derived value covers
    /// snapshots written before endpoint paths became part of the identity.
    /// Newly captured snapshots always use `effectiveConfigurationID`.
    var legacyConfigurationIDs: Set<String> {
        if let configurationID {
            let normalized = configurationID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty == false { return [normalized] }
        }
        return [
            "runtime-(String(hash, radix: 16))",
            Self.derivedConfigurationID(
                runtimeConfigurationKind: runtimeConfigurationKind,
                endpointIdentity: WebsiteActionResolver.normalizedOrigin(url: baseURL)
                    ?? baseURL.absoluteString,
                model: model,
                configurationRevision: configurationRevision
            )
        ]
    }

    /// Canonical API endpoint identity. Unlike a website origin, this includes
    /// the path because providers commonly expose distinct APIs on one host.
    static func normalizedEndpointIdentity(_ url: URL) -> String {
        guard let origin = WebsiteActionResolver.normalizedOrigin(url: url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url.absoluteString
        }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        return origin + path
    }

    private static func derivedConfigurationID(
        runtimeConfigurationKind: AIProviderRuntimeConfigurationKind,
        endpointIdentity: String,
        model: String,
        configurationRevision: Int
    ) -> String {
        let material = [
            runtimeConfigurationKind.rawValue,
            endpointIdentity,
            model.trimmingCharacters(in: .whitespacesAndNewlines),
            String(configurationRevision)
        ].joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "runtime-\(String(hash, radix: 16))"
    }

    public init(
        configurationID: String? = nil,
        configurationRevision: Int = 1,
        runtimeConfigurationKind: AIProviderRuntimeConfigurationKind = .provider,
        baseURL: URL,
        model: String,
        apiKey: String?,
        credentialGenerationID: String? = nil,
        requestTimeoutSeconds: Int = 45,
        userAgent: String = "Stacio",
        supportedReasoningEfforts: [AIReasoningEffortPreference]? = nil
    ) {
        self.configurationID = configurationID
        self.configurationRevision = configurationRevision
        self.runtimeConfigurationKind = runtimeConfigurationKind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.userAgent = userAgent
        self.supportedReasoningEfforts = supportedReasoningEfforts
        if apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let normalizedGenerationID = credentialGenerationID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedConfigurationID = configurationID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackConfigurationID = normalizedConfigurationID?.isEmpty == false
                ? normalizedConfigurationID!
                : Self.derivedConfigurationID(
                    runtimeConfigurationKind: runtimeConfigurationKind,
                    endpointIdentity: Self.normalizedEndpointIdentity(baseURL),
                    model: model,
                    configurationRevision: configurationRevision
                )
            self.credentialGenerationID = normalizedGenerationID?.isEmpty == false
                ? normalizedGenerationID
                : "unversioned-credential:\(fallbackConfigurationID)"
        } else {
            self.credentialGenerationID = nil
        }
    }

    public func resolvedReasoningEffort(
        requested: AIReasoningEffortPreference
    ) -> AIReasoningEffortPreference {
        guard let supportedReasoningEfforts,
              supportedReasoningEfforts.isEmpty == false
        else { return requested }
        if supportedReasoningEfforts.contains(requested) {
            return requested
        }
        if supportedReasoningEfforts.contains(.medium) {
            return .medium
        }
        return supportedReasoningEfforts[0]
    }
}

/// Provider object and the immutable configuration used for one turn.
/// Queue promotion carries this binding instead of rereading bridge globals.
public struct ProviderRuntimeBinding {
    public let provider: AIAssistantStreamingProviding
    public let configuration: ProviderRuntimeConfiguration

    public init(
        provider: AIAssistantStreamingProviding,
        configuration: ProviderRuntimeConfiguration
    ) {
        self.provider = provider
        self.configuration = configuration
    }
}

/// Native API 流式 Runtime：封装 V1 `AIAssistantStreamingProviding`（§6 受保护能力，真实 HTTP/SSE 流式）。
///
/// - 不直接操作 SSH/文件系统/终端（工具调用进入现有执行协调器，本核心闭环不伪造工具调用）；
/// - `stream(onDelta:)` 真实逐 token 回放经 provider 的 SSE 解析；
/// - `cancel()` 取消底层 Task（V1 流式内已有 `Task.checkCancellation`）；
/// - 失败映射为稳定 `AttemptReasonCode`（不静默重路由、不换供应商/模型）。
///
/// 这是具体 `final class`（非 enum 占位），持有可取消的流式 Task 与 provider 实例。
@MainActor
public final class NativeStreamingRuntime {

    private enum TerminalEvent {
        case response(AIAssistantResponse)
        case failure(StreamFailure)
        case cancelled
    }

    /// 流式失败：携带稳定 reasonCode，供 Bridge 提交 `attemptFailed`。
    public struct StreamFailure: Error, Equatable {
        public let reasonCode: AttemptReasonCode
        public let summary: String

        public init(reasonCode: AttemptReasonCode, summary: String) {
            self.reasonCode = reasonCode
            self.summary = summary
        }
    }

    private let provider: AIAssistantStreamingProviding
    private let configuration: ProviderRuntimeConfiguration
    private let request: NativeRequestSnapshot
    private let terminalContext: AITerminalContext?
    private let settings: AppSettings
    private let assistantSettings: AssistantRuntimeSettingsSnapshot?
    private let allowedToolIDs: [String]?
    private var streamTask: Task<Void, Never>?
    private var streamGeneration: UInt64 = 0
    private var terminalDeliveredGeneration: UInt64?
    private var cancellationRequestedGeneration: UInt64?

    public var isStreaming: Bool { streamTask != nil }

    public init(
        provider: AIAssistantStreamingProviding,
        configuration: ProviderRuntimeConfiguration,
        request: NativeRequestSnapshot,
        terminalContext: AITerminalContext? = nil,
        settings: AppSettings = AppSettings(),
        assistantSettings: AssistantRuntimeSettingsSnapshot? = nil,
        allowedToolIDs: [String]? = nil
    ) {
        self.provider = provider
        self.configuration = configuration
        self.request = request
        self.terminalContext = terminalContext
        self.settings = settings
        self.assistantSettings = assistantSettings
        self.allowedToolIDs = allowedToolIDs
    }

    deinit {
        streamTask?.cancel()
    }

    /// 启动流式请求。
    /// - `userQuestion`：用户本轮请求文本（进入 V1 AIAssistantRequest.question）。
    /// - `conversationHistory`：已确认历史投影（P0-4：多轮上下文）。
    /// - `onDelta`/`onComplete`/`onError`/`onCancelled`：结果回调（主线程派发）。
    /// - Returns: 可取消的 Task（`Task<Void, Never>`，永不抛出；结果经回调）。
    @discardableResult
    public func stream(
        userQuestion: String,
        conversationHistory: [AIAssistantConversationMessage] = [],
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (StreamFailure) -> Void,
        onCancelled: @escaping () -> Void
    ) -> Task<Void, Never> {
        stream(
            userQuestion: userQuestion,
            conversationHistory: conversationHistory,
            onDelta: onDelta,
            onResponse: { response in
                onComplete(response.message)
            },
            onError: onError,
            onCancelled: onCancelled
        )
    }

    /// 启动流式请求并保留完整响应（包括结构化命令建议）。
    /// 字符串版本保留给旧面板；V2 会话必须使用此入口，避免丢失工具调用。
    @discardableResult
    public func stream(
        userQuestion: String,
        conversationHistory: [AIAssistantConversationMessage] = [],
        onDelta: @escaping (String) -> Void,
        onResponse: @escaping (AIAssistantResponse) -> Void,
        onError: @escaping (StreamFailure) -> Void,
        onCancelled: @escaping () -> Void
    ) -> Task<Void, Never> {
        streamTask?.cancel()
        streamGeneration &+= 1
        let generation = streamGeneration
        terminalDeliveredGeneration = nil
        cancellationRequestedGeneration = nil

        let provider = UncheckedNativeStreamingProviderBox(provider)
        let callbacks = UncheckedNativeStreamingCallbacks(
            onDelta: onDelta,
            onResponse: onResponse,
            onError: onError,
            onCancelled: onCancelled
        )
        let context = terminalContext ?? AITerminalContext(
            runtimeID: request.targetBindingDigest,
            historyScopeID: request.conversationID,
            title: "Stacio V2 会话",
            currentDirectory: request.targetWorkingDirectory,
            recentTranscript: ""
        )
        let workMode: AIAssistantWorkMode
        switch request.workMode {
        case .agent:
            workMode = .agent
        case .plan:
            workMode = .plan
        case .answerOnly:
            workMode = .answerOnly
        }
        // Non-agent turns never receive effect tools. Agent turns require an
        // explicit Attempt-frozen capability snapshot; nil fails closed.
        let effectiveAllowedToolIDs = workMode == .agent ? (allowedToolIDs ?? []) : []
        // 复用 V1 已验证的上下文预算、历史裁剪、终端压缩与脱敏合同。
        let assistantRequest = AIAssistantCoordinator.preparedRequest(
            question: userQuestion,
            context: context,
            conversationHistory: conversationHistory,
            attachments: [],
            settings: settings,
            requestedSelection: nil,
            additionalInstructions: assistantSettings?.globalInstructions,
            reasoningEffort: assistantSettings.map {
                configuration.resolvedReasoningEffort(requested: $0.defaultReasoningEffort)
            },
            allowedToolIDs: effectiveAllowedToolIDs,
            workMode: workMode,
            terminalOutputMode: assistantSettings?.terminalOutputMode,
            automaticCompressionEnabled: assistantSettings?.automaticContextCompressionEnabled ?? true
        )

        let task = Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.clearStreamTask(generation: generation)
                }
            }
            do {
                let response = try await provider.value.respondStreaming(to: assistantRequest) { partial in
                    Task { @MainActor [weak self] in
                        self?.deliverDelta(
                            partial,
                            generation: generation,
                            callback: callbacks.onDelta
                        )
                    }
                }
                // A provider may swallow CancellationError and return normally.
                // The user's cancellation must still win over that late response.
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.deliverTerminal(
                        .response(response),
                        generation: generation,
                        callbacks: callbacks
                    )
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.deliverTerminal(
                        .cancelled,
                        generation: generation,
                        callbacks: callbacks
                    )
                }
            } catch {
                let terminal: TerminalEvent = Task.isCancelled
                    ? .cancelled
                    : .failure(Self.mapError(error))
                await MainActor.run { [weak self] in
                    self?.deliverTerminal(
                        terminal,
                        generation: generation,
                        callbacks: callbacks
                    )
                }
            }
        }
        streamTask = task
        return task
    }

    /// 取消当前流式请求（不阻塞；状态终态由 Bridge 经 Actor 提交）。
    public func cancel() {
        guard streamTask != nil else { return }
        cancellationRequestedGeneration = streamGeneration
        streamTask?.cancel()
    }

    private func deliverDelta(
        _ delta: String,
        generation: UInt64,
        callback: (String) -> Void
    ) {
        guard delta.isEmpty == false,
              generation == streamGeneration,
              cancellationRequestedGeneration != generation,
              terminalDeliveredGeneration != generation
        else { return }
        callback(delta)
    }

    private func deliverTerminal(
        _ terminal: TerminalEvent,
        generation: UInt64,
        callbacks: UncheckedNativeStreamingCallbacks
    ) {
        guard generation == streamGeneration,
              terminalDeliveredGeneration != generation
        else { return }

        terminalDeliveredGeneration = generation
        streamTask = nil
        let cancellationWins = cancellationRequestedGeneration == generation
        cancellationRequestedGeneration = nil

        if cancellationWins {
            callbacks.onCancelled()
            return
        }
        switch terminal {
        case .response(let response):
            callbacks.onResponse(response)
        case .failure(let failure):
            callbacks.onError(failure)
        case .cancelled:
            callbacks.onCancelled()
        }
    }

    private func clearStreamTask(generation: UInt64) {
        guard generation == streamGeneration else { return }
        streamTask = nil
    }

    /// 将 V1 provider 错误映射为稳定 `AttemptReasonCode`（规格 §16.1 错误分类）。
    nonisolated private static func mapError(_ error: Error) -> StreamFailure {
        let nsError = error as NSError
        // 超时
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorTimedOut {
            return StreamFailure(reasonCode: .providerRequestFailed, summary: "请求超时")
        }
        // HTTP 状态错误
        if case AIAssistantProviderError.httpStatus(let code) = error {
            if code == 401 {
                return StreamFailure(reasonCode: .authenticationFailed, summary: "认证失败（API Key 无效或过期）")
            }
            if code == 403 {
                return StreamFailure(
                    reasonCode: .providerRequestFailed,
                    summary: error.localizedDescription
                )
            }
            if code == 429 {
                return StreamFailure(reasonCode: .providerRequestFailed, summary: "请求频率超限（429）")
            }
            if code == 404 {
                return StreamFailure(reasonCode: .modelUnavailable, summary: "模型不存在（404）")
            }
            return StreamFailure(reasonCode: .providerRequestFailed, summary: "HTTP \(code)")
        }
        if case AIAssistantProviderError.apiError(let code, _) = error {
            return StreamFailure(
                reasonCode: code == 401 ? .authenticationFailed : .providerRequestFailed,
                summary: error.localizedDescription
            )
        }
        // provider 自身错误
        if case AIAssistantProviderError.timeout = error {
            return StreamFailure(reasonCode: .providerRequestFailed, summary: "请求超时")
        }
        if case AIAssistantProviderError.invalidResponse = error {
            return StreamFailure(reasonCode: .protocolError, summary: "响应格式无效")
        }
        if case AIAssistantProviderError.streamUnsupported = error {
            return StreamFailure(reasonCode: .protocolError, summary: "流式不可用或空响应")
        }
        return StreamFailure(reasonCode: .providerRequestFailed, summary: error.localizedDescription)
    }
}

private final class UncheckedNativeStreamingProviderBox: @unchecked Sendable {
    let value: AIAssistantStreamingProviding

    init(_ value: AIAssistantStreamingProviding) {
        self.value = value
    }
}

private final class UncheckedNativeStreamingCallbacks: @unchecked Sendable {
    let onDelta: (String) -> Void
    let onResponse: (AIAssistantResponse) -> Void
    let onError: (NativeStreamingRuntime.StreamFailure) -> Void
    let onCancelled: () -> Void

    init(
        onDelta: @escaping (String) -> Void,
        onResponse: @escaping (AIAssistantResponse) -> Void,
        onError: @escaping (NativeStreamingRuntime.StreamFailure) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        self.onDelta = onDelta
        self.onResponse = onResponse
        self.onError = onError
        self.onCancelled = onCancelled
    }
}
