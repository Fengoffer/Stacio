import Foundation
import StacioAgentBridge

public protocol AIAssistantRequestCancelling {
    func cancel()
}

public final class AIAssistantRequestHandle: AIAssistantRequestCancelling {
    private let cancellation: () -> Void

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        cancellation()
    }
}

public final class AIAssistantCoordinator {
    private static let contextCompressionTriggerRatio = 0.75
    private static let compressedContextTargetRatio = 0.65
    private static let compressedContextRecentRatio = 0.45
    private static let compressedContextSummaryMaxCharacters = 2_400

    private let provider: AIAssistantProviding
    private let executionCoordinator: AgentCommandExecuting
    private let settingsStore: AppSettingsStore
    private let modelSelectionSession: AIModelSelectionSession

    public init(
        provider: AIAssistantProviding,
        executionCoordinator: AgentCommandExecuting,
        settingsStore: AppSettingsStore = .shared,
        modelSelectionSession: AIModelSelectionSession = AIModelSelectionSession()
    ) {
        self.provider = provider
        self.executionCoordinator = executionCoordinator
        self.settingsStore = settingsStore
        self.modelSelectionSession = modelSelectionSession
    }

    public func ask(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = []
    ) throws -> AIAssistantResponse {
        let settings = settingsStore.snapshot()
        return try Self.ask(
            provider: provider,
            question: question,
            context: context,
            conversationHistory: conversationHistory,
            attachments: attachments,
            settings: settings,
            requestedSelection: modelSelectionSession.snapshot()
        )
    }

    @discardableResult
    public func askInBackground(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = [],
        progress: @escaping (String) -> Void = { _ in },
        stream: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<AIAssistantResponse, Error>) -> Void
    ) -> AIAssistantRequestCancelling {
        let providerBox = UncheckedAIAssistantProviderBox(provider)
        let settings = settingsStore.snapshot()
        let requestedSelection = modelSelectionSession.snapshot()
        let task = Task.detached(priority: .userInitiated) {
            await MainActor.run {
                progress("正在准备终端上下文")
            }
            let recentTranscript = Self.effectiveRecentTranscript(
                for: context,
                settings: settings,
                requestedSelection: requestedSelection
            )
            let boundedContext = AITerminalContext(
                runtimeID: context.runtimeID,
                historyScopeID: context.historyScopeID,
                title: context.title,
                currentDirectory: context.currentDirectory,
                recentTranscript: recentTranscript
            )
            await MainActor.run {
                progress("AI 正在生成回复")
            }
            let aiRequest = AIAssistantRequest(
                question: question,
                context: boundedContext,
                conversationHistory: Self.boundedConversationHistory(
                    conversationHistory,
                    characterLimit: Self.effectiveContextCharacterLimit(
                        settings: settings,
                        requestedSelection: requestedSelection
                    )
                ),
                attachments: attachments
            )
            do {
                let response: AIAssistantResponse
                if let streamingProvider = providerBox.provider as? AIAssistantStreamingProviding {
                    response = try await streamingProvider.respondStreaming(
                        to: aiRequest,
                        onPartial: { delta in
                            Task { @MainActor in
                                stream(delta)
                            }
                        }
                    )
                } else {
                    response = try await providerBox.provider.respondAsync(to: aiRequest)
                }
                try Task.checkCancellation()
                await MainActor.run {
                    progress("AI 已返回结果")
                    completion(.success(response))
                }
            } catch is CancellationError {
                await MainActor.run {
                    completion(.failure(AIAssistantProviderError.cancelled))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
        return AIAssistantRequestHandle {
            task.cancel()
        }
    }

    private static func ask(
        provider: AIAssistantProviding,
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment],
        settings: AppSettings,
        requestedSelection: AIModelSelection?
    ) throws -> AIAssistantResponse {
        let recentTranscript = effectiveRecentTranscript(
            for: context,
            settings: settings,
            requestedSelection: requestedSelection
        )
        let boundedContext = AITerminalContext(
            runtimeID: context.runtimeID,
            historyScopeID: context.historyScopeID,
            title: context.title,
            currentDirectory: context.currentDirectory,
            recentTranscript: recentTranscript
        )
        return try provider.respond(to: AIAssistantRequest(
            question: question,
            context: boundedContext,
            conversationHistory: boundedConversationHistory(
                conversationHistory,
                characterLimit: effectiveContextCharacterLimit(
                    settings: settings,
                    requestedSelection: requestedSelection
                )
            ),
            attachments: attachments
        ))
    }

    static func boundedConversationHistory(
        _ history: [AIAssistantConversationMessage],
        characterLimit: Int
    ) -> [AIAssistantConversationMessage] {
        let budget = max(0, min(12_000, characterLimit / 3))
        guard budget > 0 else { return [] }
        var selected: [AIAssistantConversationMessage] = []
        var used = 0
        for message in history.suffix(20).reversed() {
            let redacted = AgentProtocolRedaction.redactPreservingLineBreaks(message.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard redacted.isEmpty == false else { continue }
            let remaining = budget - used
            guard remaining > 0 else { break }
            let content = redacted.count <= remaining ? redacted : String(redacted.suffix(remaining))
            selected.append(AIAssistantConversationMessage(role: message.role, content: content))
            used += content.count
            if content.count < redacted.count { break }
        }
        return selected.reversed()
    }

    static func effectiveRecentTranscript(
        for context: AITerminalContext,
        settings: AppSettings,
        requestedSelection: AIModelSelection? = nil
    ) -> String {
        guard settings.aiIncludeRecentTerminalTranscript else {
            return ""
        }
        return compressedRecentTranscript(
            context.recentTranscript,
            limit: effectiveContextCharacterLimit(
                settings: settings,
                requestedSelection: requestedSelection
            )
        )
    }

    static func effectiveContextCharacterLimit(
        settings: AppSettings,
        requestedSelection: AIModelSelection? = nil
    ) -> Int {
        switch AIProviderRuntimeResolver.resolve(
            envelope: settings.aiProviderSettings,
            requestedSelection: requestedSelection
        ) {
        case .unconfigured:
            return AppSettings.clampedAIContextCharacterLimit(settings.aiContextCharacterLimit)
        case let .external(provider, modelID):
            return provider.models
                .first(where: { $0.id == modelID })?
                .capabilities
                .effectiveContextCharacterLimit
                ?? AIModelCapabilityConfiguration.defaultContextCharacterLimit
        }
    }

    private static func compressedRecentTranscript(_ transcript: String, limit: Int) -> String {
        let normalizedLimit = max(limit, 1)
        guard transcript.count > Int(Double(normalizedLimit) * contextCompressionTriggerRatio) else {
            return transcript
        }
        let targetLimit = max(1, min(normalizedLimit, Int(Double(normalizedLimit) * compressedContextTargetRatio)))
        let compactPrefix = "[Stacio 自动上下文压缩]"
        if targetLimit < 160 {
            let recentBudget = max(1, targetLimit - compactPrefix.count - 1)
            return "\(compactPrefix)\n\(String(transcript.suffix(recentBudget)))"
        }
        if targetLimit < 320 {
            return compactCompressedRecentTranscript(transcript, targetLimit: targetLimit)
        }
        let recentLimit = max(1, min(Int(Double(targetLimit) * compressedContextRecentRatio), targetLimit / 2))
        let recent = String(transcript.suffix(min(recentLimit, transcript.count)))
        let olderCount = max(0, transcript.count - recent.count)
        let older = String(transcript.prefix(olderCount))
        let prefix = [
            "[Stacio 自动上下文压缩]",
            "旧终端上下文已压缩为摘要；最近输出保留原文，优先以最近输出为准。"
        ].joined(separator: "\n")
        let recentHeader = "\n\n[最近终端输出原文]\n"
        let summaryBudget = max(
            60,
            targetLimit - prefix.count - recentHeader.count - recent.count - 2
        )
        var summary = transcriptCompressionSummary(for: older, maxCharacters: summaryBudget)
        let maxSummaryCount = max(0, targetLimit - prefix.count - recentHeader.count - recent.count - 2)
        if summary.count > maxSummaryCount {
            summary = String(summary.prefix(maxSummaryCount))
        }
        let compressed = "\(prefix)\n\(summary)\(recentHeader)\(recent)"
        guard compressed.count > targetLimit else {
            return compressed
        }
        let remainingForRecent = max(
            1,
            targetLimit - prefix.count - summary.count - recentHeader.count - 2
        )
        let boundedRecent = String(recent.suffix(remainingForRecent))
        return "\(prefix)\n\(summary)\(recentHeader)\(boundedRecent)"
    }

    private static func compactCompressedRecentTranscript(_ transcript: String, targetLimit: Int) -> String {
        let prefix = "[Stacio 自动上下文压缩]"
        let recentHeader = "\n[最近输出]\n"
        let recentLimit = max(1, min(Int(Double(targetLimit) * compressedContextRecentRatio), targetLimit / 2))
        let recent = String(transcript.suffix(min(recentLimit, transcript.count)))
        let olderCount = max(0, transcript.count - recent.count)
        let older = String(transcript.prefix(olderCount))
        let summaryBudget = max(0, targetLimit - prefix.count - recentHeader.count - recent.count - 1)
        let summary = compactTranscriptCompressionSummary(for: older, maxCharacters: summaryBudget)
        let compressed = summary.isEmpty
            ? "\(prefix)\(recentHeader)\(recent)"
            : "\(prefix)\n\(summary)\(recentHeader)\(recent)"
        guard compressed.count > targetLimit else {
            return compressed
        }
        let recentBudget = max(1, targetLimit - prefix.count - recentHeader.count - summary.count - 2)
        let boundedRecent = String(recent.suffix(recentBudget))
        return summary.isEmpty
            ? "\(prefix)\(recentHeader)\(boundedRecent)"
            : "\(prefix)\n\(summary)\(recentHeader)\(boundedRecent)"
    }

    private static func compactTranscriptCompressionSummary(for transcript: String, maxCharacters: Int) -> String {
        guard maxCharacters > 3 else {
            return ""
        }
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard lines.isEmpty == false else {
            return ""
        }
        var selected: [String] = []
        selected.append(contentsOf: lines.filter(isSignalTranscriptLine).prefix(3))
        for line in lines.prefix(2) where selected.contains(line) == false {
            selected.append(line)
        }
        for line in lines.suffix(2) where selected.contains(line) == false {
            selected.append(line)
        }
        let prefix = "摘要："
        let budget = maxCharacters - prefix.count
        guard budget > 0 else {
            return ""
        }
        let body = selected.joined(separator: " / ")
        return "\(prefix)\(String(body.prefix(budget)))"
    }

    private static func transcriptCompressionSummary(for transcript: String, maxCharacters: Int) -> String {
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard lines.isEmpty == false else {
            return "摘要：旧上下文为空。"
        }
        var selected: [String] = []
        selected.append(contentsOf: lines.prefix(6))
        let signalLines = lines.filter(isSignalTranscriptLine)
        for line in signalLines where selected.contains(line) == false {
            selected.append(line)
            if selected.count >= 16 {
                break
            }
        }
        for line in lines.suffix(6) where selected.contains(line) == false {
            selected.append(line)
        }
        let joined = selected.prefix(24).joined(separator: "\n")
        return "摘要：旧上下文约 \(transcript.count) 字符，以下为保留线索：\n"
            + String(joined.prefix(min(maxCharacters, compressedContextSummaryMaxCharacters)))
    }

    private static func isSignalTranscriptLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return [
            "error",
            "failed",
            "failure",
            "denied",
            "timeout",
            "exception",
            "warning",
            "panic",
            "traceback",
            "docker",
            "systemctl",
            "ssh",
            "permission",
            "no such file",
            "command not found"
        ].contains { lower.contains($0) }
    }

    @discardableResult
    @MainActor
    public func executeProposedCommand(
        _ command: String,
        context: AITerminalContext,
        requestID: String = UUID().uuidString,
        emit: ((AgentTraceEvent) -> Void)? = nil
    ) throws -> [AgentTraceEvent] {
        try executeProposedCommand(
            command,
            contexts: [context],
            requestID: requestID,
            emit: emit
        )
    }

    @discardableResult
    @MainActor
    public func executeProposedCommand(
        _ command: String,
        contexts: [AITerminalContext],
        requestID: String = UUID().uuidString,
        emit: ((AgentTraceEvent) -> Void)? = nil
    ) throws -> [AgentTraceEvent] {
        var seenRuntimeIDs = Set<String>()
        let normalizedContexts = contexts.filter {
            $0.runtimeID.isEmpty == false && seenRuntimeIDs.insert($0.runtimeID).inserted
        }
        guard normalizedContexts.isEmpty == false else {
            return []
        }
        var allEvents: [AgentTraceEvent] = []
        for (index, context) in normalizedContexts.enumerated() {
            let childRequestID = normalizedContexts.count == 1
                ? requestID
                : "\(requestID)-\(index + 1)"
            let request = AgentBridgeRequest(
                id: childRequestID,
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID(context.runtimeID),
                        command: command,
                        follow: true
                    )
                )
            )
            let events: [AgentTraceEvent]
            do {
                if let emit,
                   let streamingExecutor = executionCoordinator as? AgentCommandStreamingExecuting {
                    events = try streamingExecutor.runCommand(request, emit: emit)
                } else {
                    events = try executionCoordinator.runCommand(request)
                    events.forEach { emit?($0) }
                }
            } catch {
                if normalizedContexts.count == 1 {
                    throw error
                }
                let failed = AgentTraceEvent(
                    requestID: childRequestID,
                    state: .failed,
                    message: RuntimeDiagnosticFormatter.userMessage(for: error),
                    redactedCommand: AgentProtocolRedaction.redact(command),
                    metadata: [
                        "sourceRuntimeID": context.runtimeID,
                        "targetTitle": context.title,
                        "multiTarget": "true"
                    ]
                )
                emit?(failed)
                allEvents.append(failed)
                continue
            }
            allEvents.append(contentsOf: events)
        }
        return allEvents
    }

    @MainActor
    public func pauseTask(requestID: String) -> AgentTraceEvent? {
        (executionCoordinator as? AgentTaskControlling)?.pauseTask(requestID: requestID)
    }

    @MainActor
    public func cancelTask(requestID: String) -> AgentTraceEvent? {
        (executionCoordinator as? AgentTaskControlling)?.cancelTask(requestID: requestID)
    }

    @MainActor
    public func takeOverTask(requestID: String) -> AgentTraceEvent? {
        (executionCoordinator as? AgentTaskControlling)?.takeOverTask(requestID: requestID)
    }

    @MainActor
    public func confirmTaskComplete(requestID: String) -> AgentTraceEvent? {
        (executionCoordinator as? AgentTaskControlling)?.confirmTaskComplete(requestID: requestID)
    }
}

private final class UncheckedAIAssistantProviderBox: @unchecked Sendable {
    let provider: AIAssistantProviding

    init(_ provider: AIAssistantProviding) {
        self.provider = provider
    }
}

private extension AIAssistantProviding {
    func respondAsync(to request: AIAssistantRequest) async throws -> AIAssistantResponse {
        try respond(to: request)
    }
}
