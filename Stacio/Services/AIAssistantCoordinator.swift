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
    private static let attachmentTruncationMarker = "\n[附件文本已按上下文预算截断]"

    private let provider: AIAssistantProviding
    private let executionCoordinator: AgentCommandExecuting
    private let settingsStore: AppSettingsStore
    private let modelSelectionSession: AIModelSelectionSession
    private let assistantSettingsProvider: () -> AssistantRuntimeSettingsSnapshot?
    private let legacyConversationMode: Bool
    private struct VerifiedBackupRecord {
        let connectionGeneration: UInt64
        let backup: AgentVerifiedBackup
    }
    /// Runtime-scoped proof that a completed backup was observed before the
    /// next configuration-changing command. This is intentionally ephemeral:
    /// restarting Stacio requires a fresh backup rather than trusting stale
    /// evidence from a previous process.
    @MainActor
    private var verifiedBackupsByRuntimeID: [String: VerifiedBackupRecord] = [:]

    public init(
        provider: AIAssistantProviding,
        executionCoordinator: AgentCommandExecuting,
        settingsStore: AppSettingsStore = .shared,
        modelSelectionSession: AIModelSelectionSession = AIModelSelectionSession(),
        assistantSettingsProvider: @escaping () -> AssistantRuntimeSettingsSnapshot? = { nil },
        legacyConversationMode: Bool = false
    ) {
        self.provider = provider
        self.executionCoordinator = executionCoordinator
        self.settingsStore = settingsStore
        self.modelSelectionSession = modelSelectionSession
        self.assistantSettingsProvider = assistantSettingsProvider
        self.legacyConversationMode = legacyConversationMode
    }

    /// Stable 0.14.3 conversation mode disables the experimental plan/goal
    /// orchestration entry points in the UI and keeps responses single-turn.
    public var usesLegacyConversationMode: Bool {
        legacyConversationMode
    }

    public func ask(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = [],
        workMode: AIAssistantWorkMode = .answerOnly,
        toolEvidence: [AIAssistantToolEvidence] = []
    ) throws -> AIAssistantResponse {
        let settings = settingsStore.snapshot()
        if legacyConversationMode {
            return try Self.askLegacy(
                provider: provider,
                question: question,
                context: context,
                conversationHistory: conversationHistory,
                attachments: attachments,
                settings: settings,
                requestedSelection: modelSelectionSession.snapshot()
            )
        }
        let assistantSettings = assistantSettingsProvider()
        return try Self.ask(
            provider: provider,
            question: question,
            context: context,
            conversationHistory: conversationHistory,
            attachments: attachments,
            settings: settings,
            requestedSelection: modelSelectionSession.snapshot(),
            allowedToolIDs: legacyConversationMode ? nil : Self.allowedToolIDs(for: workMode),
            workMode: legacyConversationMode ? nil : workMode,
            toolEvidence: toolEvidence,
            terminalOutputMode: legacyConversationMode ? nil : assistantSettings?.terminalOutputMode,
            automaticCompressionEnabled: assistantSettings?.automaticContextCompressionEnabled ?? true
        )
    }

    @discardableResult
    public func askInBackground(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = [],
        workMode: AIAssistantWorkMode = .answerOnly,
        toolEvidence: [AIAssistantToolEvidence] = [],
        progress: @escaping (String) -> Void = { _ in },
        stream: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<AIAssistantResponse, Error>) -> Void
    ) -> AIAssistantRequestCancelling {
        let providerBox = UncheckedAIAssistantProviderBox(provider)
        let settings = settingsStore.snapshot()
        let assistantSettings = assistantSettingsProvider()
        let requestedSelection = modelSelectionSession.snapshot()
        let usesLegacyConversation = legacyConversationMode
        let task = Task.detached(priority: .userInitiated) {
            await MainActor.run {
                progress("正在准备终端上下文")
            }
            await MainActor.run {
                progress("AI 正在生成回复")
            }
            let aiRequest = usesLegacyConversation
                ? Self.legacyPreparedRequest(
                    question: question,
                    context: context,
                    conversationHistory: conversationHistory,
                    attachments: attachments,
                    settings: settings,
                    requestedSelection: requestedSelection
                )
                : Self.preparedRequest(
                    question: question,
                    context: context,
                    conversationHistory: conversationHistory,
                    attachments: attachments,
                    settings: settings,
                    requestedSelection: requestedSelection,
                    allowedToolIDs: Self.allowedToolIDs(for: workMode),
                    workMode: workMode,
                    toolEvidence: toolEvidence,
                    terminalOutputMode: assistantSettings?.terminalOutputMode,
                    automaticCompressionEnabled: assistantSettings?.automaticContextCompressionEnabled ?? true
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
                    let finalResponse = usesLegacyConversation
                        ? response
                        : Self.responseEnforcingToolContract(
                            response,
                            allowedToolIDs: aiRequest.allowedToolIDs
                        )
                    completion(.success(finalResponse))
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
        requestedSelection: AIModelSelection?,
        additionalInstructions: String? = nil,
        reasoningEffort: AIReasoningEffortPreference? = nil,
        allowedToolIDs: [String]? = nil,
        workMode: AIAssistantWorkMode? = nil,
        toolEvidence: [AIAssistantToolEvidence] = [],
        terminalOutputMode: String? = nil,
        automaticCompressionEnabled: Bool = true
    ) throws -> AIAssistantResponse {
        let request = preparedRequest(
            question: question,
            context: context,
            conversationHistory: conversationHistory,
            attachments: attachments,
            settings: settings,
            requestedSelection: requestedSelection,
            additionalInstructions: additionalInstructions,
            reasoningEffort: reasoningEffort,
            allowedToolIDs: allowedToolIDs,
            workMode: workMode,
            toolEvidence: toolEvidence,
            terminalOutputMode: terminalOutputMode,
            automaticCompressionEnabled: automaticCompressionEnabled
        )
        return responseEnforcingToolContract(
            try provider.respond(to: request),
            allowedToolIDs: request.allowedToolIDs
        )
    }

    private static func askLegacy(
        provider: AIAssistantProviding,
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment],
        settings: AppSettings,
        requestedSelection: AIModelSelection?
    ) throws -> AIAssistantResponse {
        try provider.respond(to: legacyPreparedRequest(
            question: question,
            context: context,
            conversationHistory: conversationHistory,
            attachments: attachments,
            settings: settings,
            requestedSelection: requestedSelection
        ))
    }

    static func responseEnforcingToolContract(
        _ response: AIAssistantResponse,
        allowedToolIDs: [String]?
    ) -> AIAssistantResponse {
        let allowed = Set(allowedToolIDs ?? [StacioBuiltinToolID.terminalCommand])
        let proposals = response.commandProposals.filter { proposal in
            proposal.toolID == StacioBuiltinToolID.terminalCommand
                && proposal.schemaRevision == 1
                && allowed.contains(proposal.toolID)
                && proposal.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return AIAssistantResponse(message: response.message, commandProposals: proposals)
    }

    /// The public assistant's 0.14.3 request contract. Keep this path free of
    /// V2 work-mode metadata, evidence, and terminal-output policy fields.
    private static func legacyPreparedRequest(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment],
        settings: AppSettings,
        requestedSelection: AIModelSelection?
    ) -> AIAssistantRequest {
        let characterLimit = max(
            0,
            effectiveContextCharacterLimit(
                settings: settings,
                requestedSelection: requestedSelection
            )
        )
        var remainingBudget = max(0, characterLimit - question.count)
        let boundedAttachments = boundedAttachments(
            attachments,
            remainingBudget: &remainingBudget
        )
        let historyBudget = min(
            remainingBudget,
            max(0, min(12_000, characterLimit / 3))
        )
        let boundedHistory = boundedConversationHistory(
            conversationHistory,
            characterBudget: historyBudget
        )
        remainingBudget = max(
            0,
            remainingBudget - boundedHistory.reduce(0) { $0 + $1.content.count }
        )
        let recentTranscript = effectiveRecentTranscript(
            for: context,
            settings: settings,
            characterLimit: remainingBudget
        )
        let boundedContext = AITerminalContext(
            runtimeID: context.runtimeID,
            historyScopeID: context.historyScopeID,
            title: context.title,
            currentDirectory: context.currentDirectory,
            recentTranscript: recentTranscript
        )
        return AIAssistantRequest(
            question: question,
            context: boundedContext,
            conversationHistory: boundedHistory,
            attachments: boundedAttachments
        )
    }

    static func preparedRequest(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment],
        settings: AppSettings,
        requestedSelection: AIModelSelection?,
        additionalInstructions: String? = nil,
        reasoningEffort: AIReasoningEffortPreference? = nil,
        allowedToolIDs: [String]? = nil,
        workMode: AIAssistantWorkMode? = nil,
        toolEvidence: [AIAssistantToolEvidence] = [],
        terminalOutputMode: String? = nil,
        automaticCompressionEnabled: Bool = true
    ) -> AIAssistantRequest {
        let characterLimit = max(
            0,
            effectiveContextCharacterLimit(
                settings: settings,
                requestedSelection: requestedSelection
            )
        )
        let instructionCount = additionalInstructions?.count ?? 0
        var remainingBudget = max(0, characterLimit - question.count - instructionCount)
        let boundedAttachments = boundedAttachments(
            attachments,
            remainingBudget: &remainingBudget
        )
        let historyBudget = min(
            remainingBudget,
            max(0, min(12_000, characterLimit / 3))
        )
        let boundedHistory = boundedConversationHistory(
            conversationHistory,
            characterBudget: historyBudget
        )
        remainingBudget = max(
            0,
            remainingBudget - boundedHistory.reduce(0) { $0 + $1.content.count }
        )
        let recentTranscript = effectiveRecentTranscript(
            for: context,
            settings: settings,
            characterLimit: remainingBudget,
            terminalOutputMode: terminalOutputMode,
            automaticCompressionEnabled: automaticCompressionEnabled
        )
        let boundedContext = AITerminalContext(
            runtimeID: context.runtimeID,
            connectionGeneration: context.connectionGeneration,
            isConnected: context.isConnected,
            historyScopeID: context.historyScopeID,
            title: context.title,
            currentDirectory: context.currentDirectory,
            recentTranscript: recentTranscript
        )
        return AIAssistantRequest(
            question: question,
            context: boundedContext,
            conversationHistory: boundedHistory,
            attachments: boundedAttachments,
            additionalInstructions: additionalInstructions,
            reasoningEffort: reasoningEffort,
            allowedToolIDs: allowedToolIDs,
            workMode: workMode,
            toolEvidence: toolEvidence
        )
    }

    public static func allowedToolIDs(for workMode: AIAssistantWorkMode) -> [String] {
        switch workMode {
        case .answerOnly:
            return []
        case .plan, .agent:
            return [StacioBuiltinToolID.terminalCommand]
        }
    }

    static func dynamicContextCharacterCount(in request: AIAssistantRequest) -> Int {
        request.question.count
            + (request.additionalInstructions?.count ?? 0)
            + request.context.recentTranscript.count
            + request.conversationHistory.reduce(0) { $0 + $1.content.count }
            + request.attachments.reduce(0) { $0 + $1.promptSummary.count }
    }

    static func boundedConversationHistory(
        _ history: [AIAssistantConversationMessage],
        characterLimit: Int
    ) -> [AIAssistantConversationMessage] {
        let budget = max(0, min(12_000, characterLimit / 3))
        return boundedConversationHistory(history, characterBudget: budget)
    }

    private static func boundedConversationHistory(
        _ history: [AIAssistantConversationMessage],
        characterBudget: Int
    ) -> [AIAssistantConversationMessage] {
        let budget = max(0, characterBudget)
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

    private static func boundedAttachments(
        _ attachments: [AIAssistantAttachment],
        remainingBudget: inout Int
    ) -> [AIAssistantAttachment] {
        guard remainingBudget > 0 else { return [] }
        var selected: [AIAssistantAttachment] = []
        for attachment in attachments {
            let fullCost = attachment.promptSummary.count
            if fullCost <= remainingBudget {
                selected.append(attachment)
                remainingBudget -= fullCost
                continue
            }
            guard let textPreview = attachment.textPreview,
                  textPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                continue
            }
            let markerOnlyAttachment = replacingTextPreview(
                attachment,
                with: attachmentTruncationMarker
            )
            let markerCost = markerOnlyAttachment.promptSummary.count
            guard markerCost <= remainingBudget else { continue }
            let previewBudget = remainingBudget - markerCost
            let boundedAttachment = replacingTextPreview(
                attachment,
                with: String(textPreview.prefix(previewBudget))
                    + attachmentTruncationMarker
            )
            selected.append(boundedAttachment)
            remainingBudget = max(0, remainingBudget - boundedAttachment.promptSummary.count)
        }
        return selected
    }

    private static func replacingTextPreview(
        _ attachment: AIAssistantAttachment,
        with textPreview: String?
    ) -> AIAssistantAttachment {
        AIAssistantAttachment(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount,
            base64Data: attachment.base64Data,
            textPreview: textPreview,
            localFileURL: attachment.localFileURL
        )
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

    private static func effectiveRecentTranscript(
        for context: AITerminalContext,
        settings: AppSettings,
        characterLimit: Int,
        terminalOutputMode: String? = nil,
        automaticCompressionEnabled: Bool = true
    ) -> String {
        let mode = terminalOutputMode
            ?? (settings.aiIncludeRecentTerminalTranscript ? "boundedHeadTail" : "excluded")
        guard mode != "excluded",
              characterLimit > 0
        else {
            return ""
        }
        let redactedTranscript = AgentProtocolRedaction.redactPreservingLineBreaks(
            context.recentTranscript
        )
        if mode == "summaryOnly" {
            let header = "[Stacio 终端输出摘要]\n"
            let summaryBudget = max(0, characterLimit - header.count)
            guard summaryBudget > 0 else { return String(header.prefix(characterLimit)) }
            let summary = transcriptCompressionSummary(
                for: redactedTranscript,
                maxCharacters: summaryBudget
            )
            return header + String(summary.prefix(summaryBudget))
        }
        let compressed = automaticCompressionEnabled
            ? compressedRecentTranscript(redactedTranscript, limit: characterLimit)
            : String(redactedTranscript.suffix(characterLimit))
        guard compressed.count > characterLimit else { return compressed }
        return String(compressed.suffix(characterLimit))
    }

    static func effectiveContextCharacterLimit(
        settings: AppSettings,
        requestedSelection: AIModelSelection? = nil
    ) -> Int {
        switch AIProviderRuntimeResolver.resolve(
            envelope: settings.aiProviderSettings,
            requestedSelection: requestedSelection
        ) {
        case .unconfigured, .credentialOriginConfirmationRequired:
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
        // Validate every target before writing to any of them. A multi-target
        // request must not partially execute because one target lacks a fresh
        // backup proof.
        for context in normalizedContexts {
            try guardBackupIfNeeded(command: command, context: context, consumeProof: false)
        }
        // This second, synchronous pass consumes each proof only after the
        // entire target set has passed validation. It remains atomic on the
        // main actor while preserving the no-partial-execution preflight.
        for context in normalizedContexts {
            try guardBackupIfNeeded(command: command, context: context, consumeProof: true)
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
                        follow: true,
                        expectedRuntimeGeneration: context.connectionGeneration
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
            updateBackupLedger(command: command, context: context, events: events)
        }
        return allEvents
    }

    @discardableResult
    @MainActor
    public func executeProposedCommandAsync(
        _ command: String,
        context: AITerminalContext,
        requestID: String = UUID().uuidString,
        emit: ((AgentTraceEvent) -> Void)? = nil
    ) async throws -> [AgentTraceEvent] {
        try await executeProposedCommandAsync(
            command,
            contexts: [context],
            requestID: requestID,
            emit: emit
        )
    }

    @discardableResult
    @MainActor
    public func executeProposedCommandAsync(
        _ command: String,
        contexts: [AITerminalContext],
        requestID: String = UUID().uuidString,
        emit: ((AgentTraceEvent) -> Void)? = nil
    ) async throws -> [AgentTraceEvent] {
        var seenRuntimeIDs = Set<String>()
        let normalizedContexts = contexts.filter {
            $0.runtimeID.isEmpty == false && seenRuntimeIDs.insert($0.runtimeID).inserted
        }
        guard normalizedContexts.isEmpty == false else { return [] }

        for context in normalizedContexts {
            try guardBackupIfNeeded(command: command, context: context, consumeProof: false)
        }
        for context in normalizedContexts {
            try guardBackupIfNeeded(command: command, context: context, consumeProof: true)
        }

        var allEvents: [AgentTraceEvent] = []
        for (index, context) in normalizedContexts.enumerated() {
            try Task.checkCancellation()
            let childRequestID = normalizedContexts.count == 1
                ? requestID
                : "\(requestID)-\(index + 1)"
            let request = AgentBridgeRequest(
                id: childRequestID,
                actor: AgentActor(kind: .builtInAI, name: "Stacio 排查助手", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID(context.runtimeID),
                        command: command,
                        follow: true,
                        expectedRuntimeGeneration: context.connectionGeneration
                    )
                )
            )
            do {
                let events: [AgentTraceEvent]
                if let asyncExecutor = executionCoordinator as? AgentCommandAsyncStreamingExecuting {
                    events = try await asyncExecutor.runCommandAsync(request, emit: { event in
                        emit?(event)
                    })
                } else if let streamingExecutor = executionCoordinator as? AgentCommandStreamingExecuting {
                    events = try streamingExecutor.runCommand(request, emit: { event in
                        emit?(event)
                    })
                } else {
                    events = try executionCoordinator.runCommand(request)
                    events.forEach { emit?($0) }
                }
                allEvents.append(contentsOf: events)
                updateBackupLedger(command: command, context: context, events: events)
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
            }
        }
        return allEvents
    }

    @MainActor
    private func guardBackupIfNeeded(
        command: String,
        context: AITerminalContext,
        consumeProof: Bool
    ) throws {
        guard AgentBackupPolicy.requiresBackup(command: command),
              AgentBackupPolicy.isDeploymentCommand(command: command) == false,
              AgentRollbackPolicy.isRollbackCommand(command) == false
        else {
            return
        }
        guard let record = verifiedBackupsByRuntimeID[context.runtimeID],
              record.connectionGeneration == context.connectionGeneration else {
            // A reconnect creates a new terminal generation. Never reuse a
            // backup proof from the previous connection, even if the runtime
            // identifier was reused by the transport layer.
            verifiedBackupsByRuntimeID.removeValue(forKey: context.runtimeID)
            throw AgentExecutionError.denied(
                "安全门禁：配置或服务变更前必须先完成备份。请先执行备份命令，并确认输出包含备份路径后再重试。"
            )
        }
        if consumeProof {
            // Consume at admission rather than after completion so concurrent
            // direct-card requests cannot reuse one backup proof.
            verifiedBackupsByRuntimeID.removeValue(forKey: context.runtimeID)
        }
    }

    @MainActor
    private func updateBackupLedger(
        command: String,
        context: AITerminalContext,
        events: [AgentTraceEvent]
    ) {
        if AgentBackupPolicy.isBackupCommand(command: command) {
            // A backup is valid only after the terminal reported audited
            // completion; approval/running events alone are not evidence that
            // it worked.
            guard events.contains(where: {
                $0.state == .completed
                    && $0.metadata?["terminalOutputAudited"] == "true"
            }) else { return }
            let output = events
                .compactMap { $0.metadata?["terminalOutputSummary"] }
                .joined(separator: "\n")
            if let path = AgentBackupPolicy.backupPath(from: output) {
                verifiedBackupsByRuntimeID[context.runtimeID] = VerifiedBackupRecord(
                    connectionGeneration: context.connectionGeneration,
                    backup: AgentVerifiedBackup(path: path, command: command)
                )
            }
            return
        }

        // A verified backup is single-use. Consume it when execution is
        // admitted, not only after completion, so a failed/cancelled mutation
        // cannot accidentally reuse proof for a later mutation.
        let reachedExecution = events.contains {
            switch $0.state {
            case .approved, .typing, .running, .waitingForOutput, .completed:
                return true
            default:
                return false
            }
        }
        if reachedExecution, AgentBackupPolicy.requiresBackup(command: command) {
            verifiedBackupsByRuntimeID.removeValue(forKey: context.runtimeID)
        }
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

    @MainActor
    public func sensitiveInputPrompt(runtimeID: String) -> AgentSensitiveInputPrompt? {
        (executionCoordinator as? AgentSensitiveInputRouting)?
            .sensitiveInputPrompt(runtimeID: runtimeID)
    }

    @MainActor
    @discardableResult
    public func submitSensitiveInput(_ bytes: [UInt8], runtimeID: String) -> Bool {
        (executionCoordinator as? AgentSensitiveInputRouting)?
            .submitSensitiveInput(bytes, runtimeID: runtimeID) ?? false
    }

    @MainActor
    @discardableResult
    public func submitSensitiveInput(
        _ bytes: [UInt8],
        prompt: AgentSensitiveInputPrompt
    ) -> Bool {
        (executionCoordinator as? AgentSensitiveInputRouting)?
            .submitSensitiveInput(bytes, prompt: prompt) ?? false
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
