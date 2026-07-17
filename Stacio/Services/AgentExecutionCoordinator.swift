import Foundation
import StacioAgentBridge
import StacioCoreBindings

@MainActor
public protocol AgentTerminalTarget: AnyObject {
    var runtimeID: String { get }
    var agentTitle: String { get }
    var agentLiveSessionContext: TunnelLiveSessionContext? { get }
    var agentAutomationPolicy: SessionAutomationPolicy { get }
    var agentCommandCompletionGeneration: UInt64 { get }
    var agentTerminalOutputTranscript: String { get }
    var agentTerminalDisplaySnapshot: String { get }
    var supportsAgentCompletionMarker: Bool { get }
    func setAgentInteractionLocked(_ locked: Bool)
    func refreshAgentTerminalOutput()
    func appendAgentTrace(_ event: AgentTraceEvent)
    func sendInput(_ bytes: [UInt8])
    func sendAgentInput(_ bytes: [UInt8])
}

public extension AgentTerminalTarget {
    var agentAutomationPolicy: SessionAutomationPolicy { .default }
    var agentCommandCompletionGeneration: UInt64 { 0 }
    var agentTerminalOutputTranscript: String { "" }
    var agentTerminalDisplaySnapshot: String { agentTerminalOutputTranscript }
    var supportsAgentCompletionMarker: Bool { false }
    func setAgentInteractionLocked(_ locked: Bool) {}
    func refreshAgentTerminalOutput() {}
    func sendAgentInput(_ bytes: [UInt8]) { sendInput(bytes) }
}

@MainActor
public protocol AgentTerminalResolving {
    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget
}

public struct AgentTerminalSessionSummary: Equatable {
    public let runtimeID: String
    public let title: String
    public let kind: String
    public let environment: String
    public let isCurrent: Bool
    public let currentDirectory: String?
    public let subtitle: String?

    public init(
        runtimeID: String,
        title: String,
        kind: String,
        environment: String,
        isCurrent: Bool,
        currentDirectory: String? = nil,
        subtitle: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.title = title
        self.kind = kind
        self.environment = environment
        self.isCurrent = isCurrent
        self.currentDirectory = currentDirectory
        self.subtitle = subtitle
    }
}

@MainActor
public protocol AgentTerminalSessionListing {
    func listAgentTerminalSessions() -> [AgentTerminalSessionSummary]
}

public struct AgentAuthorizationDecision: Equatable {
    public let allowed: Bool
    public let reason: String
    public let risk: AgentActionRisk
    public let requiredUserConfirmation: Bool

    public init(
        allowed: Bool,
        reason: String,
        risk: AgentActionRisk,
        requiredUserConfirmation: Bool = true
    ) {
        self.allowed = allowed
        self.reason = reason
        self.risk = risk
        self.requiredUserConfirmation = requiredUserConfirmation
    }
}

@MainActor
public protocol AgentActionAuthorizing {
    func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool
    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision
    func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) -> Bool
    func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> AgentAuthorizationDecision
}

extension AgentActionAuthorizing {
    public func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        true
    }

    public func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) -> Bool {
        requiresUserConfirmation(actor: actor, command: command, targetTitle: targetTitle)
    }

    public func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> AgentAuthorizationDecision {
        try authorize(actor: actor, command: command, targetTitle: targetTitle)
    }
}

@MainActor
public protocol AgentCommandExecuting {
    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent]
}

@MainActor
public protocol AgentCommandStreamingExecuting: AgentCommandExecuting {
    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent]
}

@MainActor
public protocol AgentTaskControlling {
    func pauseTask(requestID: String) -> AgentTraceEvent?
    func cancelTask(requestID: String) -> AgentTraceEvent?
    func takeOverTask(requestID: String) -> AgentTraceEvent?
    func confirmTaskComplete(requestID: String) -> AgentTraceEvent?
}

public extension AgentTaskControlling {
    func confirmTaskComplete(requestID: String) -> AgentTraceEvent? { nil }
}

public enum AgentExecutionMode: Equatable {
    case visibleTerminal
    case backgroundTask

    public init(preference: AgentExecutionModePreference) {
        switch preference {
        case .visibleTerminal:
            self = .visibleTerminal
        case .backgroundTask:
            self = .backgroundTask
        }
    }
}

public struct AgentVisibleTerminalCompletion: Equatable {
    public let idleInterval: TimeInterval
    public let maximumDuration: TimeInterval

    public init(
        idleInterval: TimeInterval = 0.6,
        maximumDuration: TimeInterval = 8
    ) {
        self.idleInterval = max(0.05, idleInterval)
        self.maximumDuration = max(self.idleInterval, maximumDuration)
    }
}

public struct AgentBackgroundCommandRequest {
    public let requestID: String
    public let command: String
    public let targetRuntimeID: String
    public let targetTitle: String
    public let actor: AgentActor
    public let redactedCommand: String
    public let liveSessionContext: TunnelLiveSessionContext?

    public init(
        requestID: String,
        command: String,
        targetRuntimeID: String,
        targetTitle: String,
        actor: AgentActor,
        redactedCommand: String,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        self.requestID = requestID
        self.command = command
        self.targetRuntimeID = targetRuntimeID
        self.targetTitle = targetTitle
        self.actor = actor
        self.redactedCommand = redactedCommand
        self.liveSessionContext = liveSessionContext
    }
}

@MainActor
public protocol AgentBackgroundCommandRunning {
    func runBackgroundCommand(
        _ request: AgentBackgroundCommandRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void
    ) throws
    func cancel(requestID: String) -> AgentTraceEvent?
}

public extension AgentTaskControlling {
    func pauseTask(requestID: String) -> AgentTraceEvent? {
        nil
    }

    func takeOverTask(requestID: String) -> AgentTraceEvent? {
        nil
    }
}

public protocol AgentBackgroundRuntimeBridging {
    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus
    func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws
    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch
    func closeTerminalRuntime(runtimeID: String) throws
}

public struct CoreBridgeAgentBackgroundRuntimeBridge: AgentBackgroundRuntimeBridging {
    public init() {}

    public func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try CoreBridge.startLiveSSHShellRuntime(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            cols: cols,
            rows: rows
        )
    }

    public func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {
        try CoreBridge.writeTerminalInput(runtimeID: runtimeID, bytes: bytes)
    }

    public func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try CoreBridge.pollLiveSSHShell(runtimeID: runtimeID)
    }

    public func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        try CoreBridge.takeTerminalOutputBatch(runtimeID: runtimeID)
    }

    public func closeTerminalRuntime(runtimeID: String) throws {
        _ = try CoreBridge.closeTerminalRuntime(runtimeID: runtimeID)
    }
}

private enum VisibleTerminalObservationOutcome: Equatable {
    case completed
    case manualRequired
    case ambiguousUserInput
}

private struct VisibleTerminalObservationResult: Equatable {
    let outcome: VisibleTerminalObservationOutcome
    let summary: String
    let reason: String
}

private struct VisibleTerminalOutputUpdate: Equatable {
    let summary: String
}

@MainActor
private final class VisibleTerminalObservationSession {
    private let requestID: String
    private let runtimeID: String
    private let command: String
    private let redactedCommand: String
    private let outputHub: TerminalOutputBroadcastHub
    private let completion: AgentVisibleTerminalCompletion
    private let onOutputUpdate: (VisibleTerminalOutputUpdate) -> Void
    private let completionMarker: [UInt8]?
    private let commandCompletionGeneration: () -> UInt64
    private let terminalOutputTranscript: () -> String
    private let terminalDisplaySnapshot: () -> String
    private let refreshTerminalOutput: () -> Void
    private let initialCommandCompletionGeneration: UInt64
    private let initialTerminalOutputTranscript: String
    private let initialTerminalDisplaySnapshot: String
    private var outputBytes: [UInt8] = []
    private var sawUserInput = false
    private var commandOutputCaptureStarted = false
    private var lastOutputAt: Date?
    private var auditCompletionSummary: String?
    private var sawShellPrompt = false
    private var lastTerminalOutputTranscript: String
    private var lastTerminalDisplaySnapshot: String
    private var lastTerminalRefreshAt = Date.distantPast
    private var subscription: TerminalOutputBroadcastHub.Subscription?

    init(
        requestID: String,
        runtimeID: String,
        command: String,
        redactedCommand: String,
        outputHub: TerminalOutputBroadcastHub,
        completion: AgentVisibleTerminalCompletion,
        commandCompletionGeneration: @escaping () -> UInt64,
        terminalOutputTranscript: @escaping () -> String,
        terminalDisplaySnapshot: @escaping () -> String,
        refreshTerminalOutput: @escaping () -> Void,
        completionMarker: [UInt8]?,
        onOutputUpdate: @escaping (VisibleTerminalOutputUpdate) -> Void
    ) {
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.command = command
        self.redactedCommand = redactedCommand
        self.outputHub = outputHub
        self.completion = completion
        self.commandCompletionGeneration = commandCompletionGeneration
        self.terminalOutputTranscript = terminalOutputTranscript
        self.terminalDisplaySnapshot = terminalDisplaySnapshot
        self.refreshTerminalOutput = refreshTerminalOutput
        self.completionMarker = completionMarker
        self.initialCommandCompletionGeneration = commandCompletionGeneration()
        self.initialTerminalOutputTranscript = terminalOutputTranscript()
        self.initialTerminalDisplaySnapshot = terminalDisplaySnapshot()
        self.lastTerminalOutputTranscript = self.initialTerminalOutputTranscript
        self.lastTerminalDisplaySnapshot = self.initialTerminalDisplaySnapshot
        self.onOutputUpdate = onOutputUpdate
    }

    func begin() {
        subscription = outputHub.subscribe(runtimeID: runtimeID) { [weak self] event in
            self?.ingest(event)
        }
    }

    func markCommandWriteStarted() {
        commandOutputCaptureStarted = true
    }

    func wait() -> VisibleTerminalObservationResult {
        defer { close() }
        if Self.requiresManualCompletion(command) {
            if let completed = waitUntilManualCommandHasInitialObservation() {
                return completed
            }
            return VisibleTerminalObservationResult(
                outcome: .manualRequired,
                summary: Self.summary(from: outputBytes),
                reason: "longRunningCommand"
            )
        }
        let deadline = Date().addingTimeInterval(completion.maximumDuration)
        let outputGraceDeadline = deadline.addingTimeInterval(completion.idleInterval * 2)
        while Date() < outputGraceDeadline {
            if Date() >= deadline,
               (lastOutputAt == nil || outputBytes.isEmpty) {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            refreshTerminalOutputIfNeeded()
            if sawUserInput {
                return VisibleTerminalObservationResult(
                    outcome: .ambiguousUserInput,
                    summary: "",
                    reason: "userInputDuringCommand"
                )
            }
            captureDirectTerminalOutputIfNeeded()
            captureVisibleTerminalDisplayIfNeeded()
            if let auditCompletionSummary {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: auditCompletionSummary,
                    reason: "auditEndMarker"
                )
            }
            if let markerSummary = agentCompletionMarkerSummary() {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: markerSummary,
                    reason: "agentCompletionMarker"
                )
            }
            if sawShellPrompt {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: Self.summary(from: outputBytes),
                    reason: "shellPromptObserved"
                )
            }
            if let lastOutputAt,
               Date().timeIntervalSince(lastOutputAt) >= completion.idleInterval,
               outputBytes.isEmpty == false {
                let summary = Self.summary(from: outputBytes)
                if summary.isEmpty == false {
                    return VisibleTerminalObservationResult(
                        outcome: .completed,
                        summary: summary,
                        reason: "outputIdle"
                    )
                }
            }
        }
        return VisibleTerminalObservationResult(
            outcome: .manualRequired,
            summary: Self.summary(from: outputBytes),
            reason: outputBytes.isEmpty ? "noOutputBeforeTimeout" : "timeoutBeforeSafeCompletion"
        )
    }

    func completedResultFromTranscriptIfPromptPresent() -> VisibleTerminalObservationResult? {
        guard sawUserInput == false else { return nil }
        captureDirectTerminalOutputIfNeeded()
        captureVisibleTerminalDisplayIfNeeded()
        guard Self.hasTrailingShellPrompt(in: outputBytes) else { return nil }
        return VisibleTerminalObservationResult(
            outcome: .completed,
            summary: Self.summary(from: outputBytes),
            reason: "shellPromptObserved"
        )
    }

    var diagnosticDescription: String {
        let markerSeen = agentCompletionMarkerSummary() != nil || auditCompletionSummary != nil
        return [
            "request=\(requestID)",
            "runtime=\(runtimeID)",
            "output_bytes=\(outputBytes.count)",
            "transcript_initial=\(initialTerminalOutputTranscript.utf8.count)",
            "transcript_current=\(terminalOutputTranscript().utf8.count)",
            "display_initial=\(initialTerminalDisplaySnapshot.utf8.count)",
            "display_current=\(terminalDisplaySnapshot().utf8.count)",
            "generation_initial=\(initialCommandCompletionGeneration)",
            "generation_current=\(commandCompletionGeneration())",
            "marker_seen=\(markerSeen)",
            "prompt_seen=\(sawShellPrompt)",
            "user_input=\(sawUserInput)"
        ].joined(separator: " ")
    }

    private func ingest(_ event: TerminalBroadcastEvent) {
        switch event.kind {
        case .output:
            guard commandOutputCaptureStarted else { return }
            guard sawUserInput == false else { return }
            outputBytes.append(contentsOf: event.bytes)
            lastOutputAt = event.createdAt
            sawShellPrompt = TerminalOSC7SequenceParser.currentDirectories(from: outputBytes).isEmpty == false
                || Self.hasTrailingShellPrompt(in: outputBytes)
            if let markerRange = Self.auditEndMarkerRange(in: outputBytes) {
                auditCompletionSummary = Self.summary(from: Array(outputBytes[..<markerRange.lowerBound]))
            }
            let summary = Self.summary(from: outputBytes)
            if summary.isEmpty == false {
                onOutputUpdate(VisibleTerminalOutputUpdate(summary: summary))
            }
        case .userInput:
            if Self.isAICommandEcho(event.bytes, command: command) {
                commandOutputCaptureStarted = true
            } else {
                sawUserInput = true
            }
        case .commandFinished:
            guard commandOutputCaptureStarted, sawUserInput == false else { return }
            sawShellPrompt = true
        }
    }

    private func waitUntilManualCommandHasInitialObservation() -> VisibleTerminalObservationResult? {
        let deadline = Date().addingTimeInterval(
            min(completion.maximumDuration, max(completion.idleInterval * 2, 0.75))
        )
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            refreshTerminalOutputIfNeeded()
            if sawUserInput {
                return VisibleTerminalObservationResult(
                    outcome: .ambiguousUserInput,
                    summary: "",
                    reason: "userInputDuringCommand"
                )
            }
            captureDirectTerminalOutputIfNeeded()
            captureVisibleTerminalDisplayIfNeeded()
            if let auditCompletionSummary {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: auditCompletionSummary,
                    reason: "auditEndMarker"
                )
            }
            if let markerSummary = agentCompletionMarkerSummary() {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: markerSummary,
                    reason: "agentCompletionMarker"
                )
            }
            if sawShellPrompt {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: Self.summary(from: outputBytes),
                    reason: "shellPromptObserved"
                )
            }
            if let lastOutputAt,
               Date().timeIntervalSince(lastOutputAt) >= completion.idleInterval,
               outputBytes.isEmpty == false {
                return nil
            }
        }
        return nil
    }

    private func close() {
        if let subscription {
            outputHub.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        subscription = nil
    }

    private func refreshTerminalOutputIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastTerminalRefreshAt) >= 0.05 else { return }
        lastTerminalRefreshAt = now
        refreshTerminalOutput()
    }

    private func agentCompletionMarkerSummary() -> String? {
        guard let completionMarker,
              let markerRange = Self.range(of: completionMarker, in: outputBytes)
        else { return nil }
        return Self.summary(from: Array(outputBytes[..<markerRange.lowerBound]))
    }

    private func captureDirectTerminalOutputIfNeeded() {
        guard sawUserInput == false else { return }
        let currentTranscript = terminalOutputTranscript()
        guard currentTranscript != lastTerminalOutputTranscript else { return }
        let commandTranscript: Substring
        if currentTranscript.hasPrefix(initialTerminalOutputTranscript) {
            commandTranscript = currentTranscript.dropFirst(initialTerminalOutputTranscript.count)
        } else {
            commandTranscript = currentTranscript[...]
        }
        lastTerminalOutputTranscript = currentTranscript
        guard commandTranscript.isEmpty == false else { return }
        outputBytes = Array(commandTranscript.utf8)
        lastOutputAt = Date()
        sawShellPrompt = commandCompletionGeneration() != initialCommandCompletionGeneration
            || TerminalOSC7SequenceParser.currentDirectories(from: outputBytes).isEmpty == false
            || Self.hasTrailingShellPrompt(in: outputBytes)
        if let markerRange = Self.auditEndMarkerRange(in: outputBytes) {
            auditCompletionSummary = Self.summary(from: Array(outputBytes[..<markerRange.lowerBound]))
        }
        let summary = Self.summary(from: outputBytes)
        if summary.isEmpty == false {
            onOutputUpdate(VisibleTerminalOutputUpdate(summary: summary))
        }
    }

    private func captureVisibleTerminalDisplayIfNeeded() {
        guard sawUserInput == false else { return }
        let currentSnapshot = terminalDisplaySnapshot()
        guard currentSnapshot != lastTerminalDisplaySnapshot else { return }
        lastTerminalDisplaySnapshot = currentSnapshot

        let commandSnapshot: Substring
        if currentSnapshot.hasPrefix(initialTerminalDisplaySnapshot) {
            commandSnapshot = currentSnapshot.dropFirst(initialTerminalDisplaySnapshot.count)
        } else if let commandRange = currentSnapshot.range(of: command, options: .backwards) {
            commandSnapshot = currentSnapshot[commandRange.upperBound...]
        } else {
            commandSnapshot = currentSnapshot[...]
        }
        guard commandSnapshot.isEmpty == false else { return }

        let visibleBytes = Array(commandSnapshot.utf8)
        let displayShowsPrompt = TerminalOSC7SequenceParser.currentDirectories(from: visibleBytes).isEmpty == false
            || Self.hasTrailingShellPrompt(in: visibleBytes)
        guard displayShowsPrompt else { return }

        if outputBytes.isEmpty {
            outputBytes = visibleBytes
        }
        lastOutputAt = Date()
        sawShellPrompt = true
        let summary = Self.summary(from: outputBytes)
        if summary.isEmpty == false {
            onOutputUpdate(VisibleTerminalOutputUpdate(summary: summary))
        }
    }

    private static func summary(from bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let withoutAgentMarkers = text.replacingOccurrences(
            of: #"\x1B\]777;stacio-agent-done=[^\x07]*(?:\x07|\x1B\\)"#,
            with: "",
            options: .regularExpression
        )
        var lines = AgentProtocolRedaction.redactPreservingLineBreaks(withoutAgentMarkers)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("\u{001B}]7;") == false }
            .filter { $0 != "STACIO_AUDIT_BEGIN" && $0 != "STACIO_AUDIT_END" }
            .filter { $0.isEmpty == false }
        if let trailingLine = lines.last,
           "STACIO_AUDIT_END".hasPrefix(trailingLine) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func auditEndMarkerRange(in bytes: [UInt8]) -> Range<Int>? {
        let marker = Array("STACIO_AUDIT_END".utf8)
        guard bytes.count >= marker.count else { return nil }

        for start in 0...(bytes.count - marker.count) where bytes[start..<(start + marker.count)].elementsEqual(marker) {
            let linePrefix = bytes[..<start].reversed().prefix { $0 != 0x0A && $0 != 0x0D }
            guard linePrefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { continue }

            let end = start + marker.count
            let lineSuffix = bytes[end...].prefix { $0 != 0x0A && $0 != 0x0D }
            guard lineSuffix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { continue }
            return start..<end
        }
        return nil
    }

    private static func range(of marker: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard marker.isEmpty == false, bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count)
            where bytes[start..<(start + marker.count)].elementsEqual(marker) {
            return start..<(start + marker.count)
        }
        return nil
    }

    private static func hasTrailingShellPrompt(in bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes.suffix(4_096), as: UTF8.self)
        guard let rawLine = text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
        else { return false }
        let line = String(rawLine)
            .replacingOccurrences(
                of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = line.last, marker == "#" || marker == "$" || marker == "%" else {
            return false
        }
        let promptBody = line.dropLast()
        return promptBody.contains("@")
            && (promptBody.contains(":") || promptBody.contains(" "))
    }

    private static func isAICommandEcho(_ bytes: [UInt8], command: String) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return false }
        if text == command || text.contains(command) { return true }
        return text.contains("stacio-agent-done=") && text.contains(command)
    }

    private static func requiresManualCompletion(_ command: String) -> Bool {
        let lower = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.isEmpty == false else {
            return false
        }

        return lower
            .components(separatedBy: CharacterSet(charactersIn: ";\n|&"))
            .compactMap(commandInvocation(from:))
            .contains { invocation in
                let arguments = invocation.arguments
                switch invocation.executable {
                case "tail":
                    return hasShortOption("f", in: arguments) || arguments.contains("--follow")
                case "top":
                    return hasShortOption("b", in: arguments) == false
                        && arguments.contains("--batch") == false
                case "htop", "less", "more", "vim", "vi", "nano", "ssh", "watch", "irb":
                    return true
                case "mysql":
                    return hasShortOption("e", in: arguments) == false
                        && arguments.contains("--execute") == false
                case "psql":
                    return hasShortOption("c", in: arguments) == false
                        && arguments.contains("--command") == false
                case "redis-cli":
                    return arguments.isEmpty
                case "python", "python3", "node":
                    return arguments.isEmpty || hasShortOption("i", in: arguments)
                case "rails":
                    return arguments.first == "console"
                case "ping", "ping6":
                    return hasShortOption("c", in: arguments) == false
                        && arguments.contains("--count") == false
                        && hasShortOption("w", in: arguments) == false
                        && arguments.contains("--deadline") == false
                default:
                    return false
                }
            }
    }

    private static func hasShortOption(_ option: Character, in arguments: [String]) -> Bool {
        arguments.contains { argument in
            guard argument.hasPrefix("-"), argument.hasPrefix("--") == false else { return false }
            return argument.dropFirst().contains(option)
        }
    }

    private static func commandInvocation(from rawSegment: String) -> (
        executable: String,
        arguments: [String]
    )? {
        var words = rawSegment
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.isEmpty == false else { return nil }

        while let first = words.first,
              first.contains("=") && first.hasPrefix("-") == false {
            words.removeFirst()
        }
        if words.first == "env" {
            words.removeFirst()
            while let first = words.first,
                  first.contains("=") && first.hasPrefix("-") == false {
                words.removeFirst()
            }
        }
        if words.first == "sudo" {
            words.removeFirst()
            while let first = words.first, first.hasPrefix("-") {
                words.removeFirst()
            }
        }
        guard let executableWord = words.first else { return nil }
        words.removeFirst()
        let executable = URL(fileURLWithPath: executableWord).lastPathComponent
        return (executable, words)
    }
}

public enum AgentExecutionError: Error, LocalizedError, Equatable {
    case unsupportedAction
    case terminalNotFound
    case denied(String)
    case backgroundTaskUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedAction:
            return "Stacio Agent Bridge 暂不支持该操作。"
        case .terminalNotFound:
            return "未找到可执行该操作的 Stacio 终端。"
        case .denied(let reason):
            return reason
        case .backgroundTaskUnavailable:
            return "当前终端暂不支持 AI 独立任务执行。"
        }
    }
}

private struct AgentUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private final class AgentBackgroundActiveTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTasksByRequestID: [String: RemoteSSHAgentBackgroundCommandRunner.PendingTask] = [:]
    private var tasksByRequestID: [String: RemoteSSHAgentBackgroundCommandRunner.ActiveTask] = [:]
    private var cancelledRequestIDs = Set<String>()

    func prepare(_ task: RemoteSSHAgentBackgroundCommandRunner.PendingTask, requestID: String) {
        lock.lock()
        pendingTasksByRequestID[requestID] = task
        cancelledRequestIDs.remove(requestID)
        lock.unlock()
    }

    func set(_ task: RemoteSSHAgentBackgroundCommandRunner.ActiveTask, requestID: String) -> Bool {
        lock.lock()
        if cancelledRequestIDs.contains(requestID) {
            pendingTasksByRequestID.removeValue(forKey: requestID)
            cancelledRequestIDs.remove(requestID)
            lock.unlock()
            return false
        }
        tasksByRequestID[requestID] = task
        pendingTasksByRequestID.removeValue(forKey: requestID)
        cancelledRequestIDs.remove(requestID)
        lock.unlock()
        return true
    }

    func take(requestID: String) -> RemoteSSHAgentBackgroundCommandRunner.CancelledTask? {
        lock.lock()
        let task = tasksByRequestID.removeValue(forKey: requestID)
        let pendingTask = pendingTasksByRequestID.removeValue(forKey: requestID)
        let cancelledTask: RemoteSSHAgentBackgroundCommandRunner.CancelledTask?
        if let task {
            cancelledRequestIDs.insert(requestID)
            cancelledTask = RemoteSSHAgentBackgroundCommandRunner.CancelledTask(
                runtimeID: task.runtimeID,
                sourceRuntimeID: task.sourceRuntimeID,
                redactedCommand: task.redactedCommand
            )
        } else if let pendingTask {
            cancelledRequestIDs.insert(requestID)
            cancelledTask = RemoteSSHAgentBackgroundCommandRunner.CancelledTask(
                runtimeID: nil,
                sourceRuntimeID: pendingTask.sourceRuntimeID,
                redactedCommand: pendingTask.redactedCommand
            )
        } else {
            cancelledTask = nil
        }
        lock.unlock()
        return cancelledTask
    }

    func clear(requestID: String, runtimeID: String) {
        lock.lock()
        if tasksByRequestID[requestID]?.runtimeID == runtimeID {
            tasksByRequestID.removeValue(forKey: requestID)
        }
        cancelledRequestIDs.remove(requestID)
        lock.unlock()
    }

    func clearPending(requestID: String) {
        lock.lock()
        pendingTasksByRequestID.removeValue(forKey: requestID)
        lock.unlock()
    }

    func isCancelled(requestID: String) -> Bool {
        lock.lock()
        let cancelled = cancelledRequestIDs.contains(requestID)
        lock.unlock()
        return cancelled
    }
}

@MainActor
public final class RemoteSSHAgentBackgroundCommandRunner: AgentBackgroundCommandRunning {
    fileprivate struct PendingTask {
        let sourceRuntimeID: String
        let redactedCommand: String
    }

    fileprivate struct ActiveTask {
        let runtimeID: String
        let sourceRuntimeID: String
        let redactedCommand: String
    }

    fileprivate struct CancelledTask {
        let runtimeID: String?
        let sourceRuntimeID: String
        let redactedCommand: String
    }

    private let runtimeBridge: AgentBackgroundRuntimeBridging
    private let cols: UInt32
    private let rows: UInt32
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let outputLimit: Int
    private let activeTaskRegistry = AgentBackgroundActiveTaskRegistry()

    public init(
        runtimeBridge: AgentBackgroundRuntimeBridging = CoreBridgeAgentBackgroundRuntimeBridge(),
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        timeout: TimeInterval = 12,
        pollInterval: TimeInterval = 0.12,
        outputLimit: Int = 1_200
    ) {
        self.runtimeBridge = runtimeBridge
        self.cols = cols
        self.rows = rows
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.outputLimit = outputLimit
    }

    public func runBackgroundCommand(
        _ request: AgentBackgroundCommandRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void
    ) throws {
        func emitEvent(
            _ state: AgentTraceState,
            _ message: String,
            _ request: AgentBackgroundCommandRequest,
            taskRuntimeID: String? = nil,
            terminalOutputSummary: String? = nil
        ) {
            var metadata = [
                "executionMode": "backgroundTask",
                "sourceRuntimeID": request.targetRuntimeID
            ]
            if let taskRuntimeID {
                metadata["taskRuntimeID"] = taskRuntimeID
            }
            if let terminalOutputSummary,
               terminalOutputSummary.isEmpty == false {
                metadata["terminalOutputSummary"] = terminalOutputSummary
            }
            emit(AgentTraceEvent(
                requestID: request.requestID,
                state: state,
                message: message,
                redactedCommand: request.redactedCommand,
                metadata: metadata
            ))
        }

        guard let context = request.liveSessionContext else {
            emitEvent(.failed, "AI 独立任务失败：\(AgentExecutionError.backgroundTaskUnavailable.localizedDescription)", request)
            return
        }
        activeTaskRegistry.prepare(
            PendingTask(
                sourceRuntimeID: request.targetRuntimeID,
                redactedCommand: request.redactedCommand
            ),
            requestID: request.requestID
        )

        let runtimeBridge = AgentUncheckedSendable(value: runtimeBridge)
        let contextBox = AgentUncheckedSendable(value: context)
        let requestBox = AgentUncheckedSendable(value: request)
        let cols = cols
        let rows = rows
        let timeout = timeout
        let pollInterval = pollInterval
        let outputLimit = outputLimit
        let activeTaskRegistry = activeTaskRegistry

        DispatchQueue.global(qos: .userInitiated).async {
            let request = requestBox.value
            var taskRuntimeID: String?
            do {
                let status = try runtimeBridge.value.startLiveSSHShellRuntime(
                    config: contextBox.value.config,
                    secret: contextBox.value.secret,
                    expectedFingerprintSHA256: contextBox.value.expectedFingerprintSHA256,
                    cols: cols,
                    rows: rows
                )
                taskRuntimeID = status.runtimeId
                guard status.status == "running" else {
                    throw SshRuntimeError.Transport(message: Self.diagnosticMessage(forStatusDiagnostic: status.diagnostic))
                }
                let didRegisterTask = activeTaskRegistry.set(
                    ActiveTask(
                        runtimeID: status.runtimeId,
                        sourceRuntimeID: request.targetRuntimeID,
                        redactedCommand: request.redactedCommand
                    ),
                    requestID: request.requestID
                )
                guard didRegisterTask else {
                    try? runtimeBridge.value.closeTerminalRuntime(runtimeID: status.runtimeId)
                    return
                }
                Task { @MainActor in
                    emitEvent(
                        .waitingForOutput,
                        "已创建独立执行终端，等待输出",
                        request,
                        taskRuntimeID: status.runtimeId
                    )
                }
                let wrappedCommand = Self.remoteLogWrappedCommand(for: request.command)
                try runtimeBridge.value.writeTerminalInput(
                    runtimeID: status.runtimeId,
                    bytes: Array(wrappedCommand.utf8)
                )

                var output = Data()
                let deadline = Date().addingTimeInterval(timeout)
                var didTimeout = true
                while Date() < deadline {
                    if activeTaskRegistry.isCancelled(requestID: request.requestID) {
                        return
                    }
                    let liveStatus = try runtimeBridge.value.pollLiveSSHShell(runtimeID: status.runtimeId)
                    let batch = try runtimeBridge.value.takeTerminalOutputBatch(runtimeID: status.runtimeId)
                    if activeTaskRegistry.isCancelled(requestID: request.requestID) {
                        return
                    }
                    if !batch.bytes.isEmpty {
                        output.append(batch.bytes)
                        let summary = Self.outputSummary(from: batch.bytes, limit: outputLimit)
                        if summary.isEmpty == false {
                            Task { @MainActor in
                                emitEvent(
                                    .running,
                                    "AI 独立任务输出：\(summary)",
                                    request,
                                    taskRuntimeID: status.runtimeId,
                                    terminalOutputSummary: summary
                                )
                            }
                        }
                    }
                    if liveStatus.status != "running" || Self.containsCompletionSentinel(output) {
                        didTimeout = false
                        break
                    }
                    Thread.sleep(forTimeInterval: pollInterval)
                }
                if activeTaskRegistry.isCancelled(requestID: request.requestID) {
                    return
                }
                if let taskRuntimeID {
                    try? runtimeBridge.value.closeTerminalRuntime(runtimeID: taskRuntimeID)
                    activeTaskRegistry.clear(requestID: request.requestID, runtimeID: taskRuntimeID)
                }
                if didTimeout {
                    if activeTaskRegistry.isCancelled(requestID: request.requestID) {
                        return
                    }
                    Task { @MainActor in
                        emitEvent(
                            .failed,
                            "AI 独立任务失败：执行超时，请检查命令是否仍在运行。",
                            request,
                            taskRuntimeID: status.runtimeId
                        )
                    }
                    return
                }

                let summary = Self.outputSummary(from: output, limit: outputLimit)
                let message = summary.isEmpty
                    ? "AI 独立任务已完成。"
                    : "AI 独立任务已完成：\(summary)"
                if activeTaskRegistry.isCancelled(requestID: request.requestID) {
                    return
                }
                Task { @MainActor in
                    emitEvent(
                        .completed,
                        message,
                        request,
                        taskRuntimeID: status.runtimeId,
                        terminalOutputSummary: summary.isEmpty ? nil : summary
                    )
                }
            } catch {
                if activeTaskRegistry.isCancelled(requestID: request.requestID) {
                    return
                }
                activeTaskRegistry.clearPending(requestID: request.requestID)
                if let taskRuntimeID {
                    try? runtimeBridge.value.closeTerminalRuntime(runtimeID: taskRuntimeID)
                    activeTaskRegistry.clear(requestID: request.requestID, runtimeID: taskRuntimeID)
                }
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                let failedTaskRuntimeID = taskRuntimeID
                Task { @MainActor in
                    emitEvent(.failed, "AI 独立任务失败：\(message)", request, taskRuntimeID: failedTaskRuntimeID)
                }
            }
        }
    }

    nonisolated private static func diagnosticMessage(forStatusDiagnostic diagnostic: String) -> String {
        let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "AI background runtime did not enter running state" : message
    }

    public func cancel(requestID: String) -> AgentTraceEvent? {
        guard let task = activeTaskRegistry.take(requestID: requestID) else {
            return nil
        }
        if let runtimeID = task.runtimeID {
            try? runtimeBridge.closeTerminalRuntime(runtimeID: runtimeID)
        }
        var metadata = [
            "executionMode": "backgroundTask",
            "sourceRuntimeID": task.sourceRuntimeID,
            "control": "cancel"
        ]
        if let runtimeID = task.runtimeID {
            metadata["taskRuntimeID"] = runtimeID
        }
        return AgentTraceEvent(
            requestID: requestID,
            state: .cancelled,
            message: "AI 独立任务已取消。",
            redactedCommand: task.redactedCommand,
            metadata: metadata
        )
    }

    nonisolated private static func outputSummary(from data: Data, limit: Int) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .filter { isStacioBackgroundControlLine($0) == false }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return ""
        }
        let redacted = AgentProtocolRedaction.redactPreservingLineBreaks(normalized)
        if redacted.count <= limit {
            return redacted
        }
        return "\(redacted.prefix(limit))..."
    }

    nonisolated private static func remoteLogWrappedCommand(for command: String) -> String {
        let quotedCommand = shellSingleQuoted(command)
        return """
        __STACIO_AGENT_LOG="$(mktemp /tmp/stacio-agent.XXXXXX 2>/dev/null || printf '/tmp/stacio-agent-%s.log' "$$")"
        __STACIO_AGENT_CMD=\(quotedCommand)
        sh -c "$__STACIO_AGENT_CMD" >"$__STACIO_AGENT_LOG" 2>&1
        __STACIO_AGENT_STATUS=$?
        cat "$__STACIO_AGENT_LOG" 2>/dev/null || true
        rm -f "$__STACIO_AGENT_LOG" 2>/dev/null || true
        printf '\\n__STACIO_AGENT_DONE__:%s\\n' "$__STACIO_AGENT_STATUS"
        exit
        """
    }

    nonisolated private static func containsCompletionSentinel(_ output: Data) -> Bool {
        output.range(of: Data("__STACIO_AGENT_DONE__:".utf8)) != nil
    }

    nonisolated private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func isStacioBackgroundControlLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return false
        }
        return trimmed.hasPrefix("__STACIO_AGENT_LOG=")
            || trimmed.hasPrefix("__STACIO_AGENT_CMD=")
            || trimmed.hasPrefix("__STACIO_AGENT_STATUS=")
            || trimmed.hasPrefix("__STACIO_AGENT_DONE__:")
            || trimmed == "exit"
            || trimmed.hasPrefix("sh -c \"$__STACIO_AGENT_CMD\"")
            || trimmed.hasPrefix("cat \"$__STACIO_AGENT_LOG\"")
            || trimmed.hasPrefix("rm -f \"$__STACIO_AGENT_LOG\"")
            || trimmed.hasPrefix("printf '\\n__STACIO_AGENT_DONE__:%s\\n'")
    }
}

@MainActor
public final class AgentExecutionCoordinator: AgentCommandStreamingExecuting {
    private static let agentAuditRedactionVersion = "stacio.agent-redaction.v1"

    private struct TrackedTask {
        let target: AgentTerminalTarget
        let sourceRuntimeID: String
        let redactedCommand: String
        let executionMode: String
        let actor: AgentActor
    }

    private struct AuditContext {
        let request: AgentBridgeRequest
        let target: AgentTerminalTarget
        let risk: AgentActionRisk
        let redactedInput: String
        let decision: AgentAuthorizationDecision
    }

    private struct BridgeFollowStream {
        let emit: @MainActor (AgentTraceEvent) -> Void
        let completion: @MainActor () -> Void
    }

    private let terminalResolver: AgentTerminalResolving
    private let authorizer: AgentActionAuthorizing
    private let auditRecorder: AgentActionAuditRecording?
    private let sessionLister: AgentTerminalSessionListing?
    private let executionMode: AgentExecutionMode
    private let executionModeResolver: (() -> AgentExecutionMode)?
    private let backgroundCommandRunner: AgentBackgroundCommandRunning
    private let visibleTerminalOutputHub: TerminalOutputBroadcastHub
    private let visibleTerminalCompletion: AgentVisibleTerminalCompletion
    private var backgroundTargetsByRequestID: [String: AgentTerminalTarget] = [:]
    private var trackedTasksByRequestID: [String: TrackedTask] = [:]
    private var auditContextsByRequestID: [String: AuditContext] = [:]
    private var bridgeFollowStreamsByRequestID: [String: BridgeFollowStream] = [:]

    public init(
        terminalResolver: AgentTerminalResolving,
        authorizer: AgentActionAuthorizing,
        auditRecorder: AgentActionAuditRecording? = nil,
        sessionLister: AgentTerminalSessionListing? = nil,
        executionMode: AgentExecutionMode = .visibleTerminal,
        executionModeResolver: (() -> AgentExecutionMode)? = nil,
        backgroundCommandRunner: AgentBackgroundCommandRunning? = nil,
        visibleTerminalOutputHub: TerminalOutputBroadcastHub = .shared,
        visibleTerminalCompletion: AgentVisibleTerminalCompletion = AgentVisibleTerminalCompletion()
    ) {
        self.terminalResolver = terminalResolver
        self.authorizer = authorizer
        self.auditRecorder = auditRecorder
        self.sessionLister = sessionLister
        self.executionMode = executionMode
        self.executionModeResolver = executionModeResolver
        self.backgroundCommandRunner = backgroundCommandRunner ?? RemoteSSHAgentBackgroundCommandRunner()
        self.visibleTerminalOutputHub = visibleTerminalOutputHub
        self.visibleTerminalCompletion = visibleTerminalCompletion
    }

    public func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    public func runCommand(
        _ request: AgentBridgeRequest,
        emit externalEmit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        guard case .runCommand(let commandRequest) = request.action else {
            throw AgentExecutionError.unsupportedAction
        }

        let target = try terminalResolver.resolveTerminalTarget(commandRequest.target)
        let redactedCommand = AgentProtocolRedaction.redact(commandRequest.command)
        let mode = resolvedExecutionMode()
        var events: [AgentTraceEvent] = []

        func traceMetadata(
            extra: [String: String]? = nil,
            decision: AgentAuthorizationDecision? = nil
        ) -> [String: String] {
            var metadata: [String: String] = [
                "executionMode": traceValue(for: mode),
                "sourceRuntimeID": target.runtimeID,
                "targetTitle": target.agentTitle,
                "environment": target.agentAutomationPolicy.environment,
                "aiExecutionPolicy": target.agentAutomationPolicy.aiExecutionPolicy
            ]
            if let decision {
                metadata["policyDecision"] = policyDecisionValue(for: decision)
                metadata["risk"] = decision.risk.rawValue
            }
            if let extra {
                metadata.merge(extra) { _, new in new }
            }
            metadata["actorKind"] = request.actor.kind.rawValue
            metadata["actorName"] = request.actor.name
            return metadata
        }

        func emit(
            _ state: AgentTraceState,
            _ message: String,
            metadata: [String: String]? = nil,
            decision: AgentAuthorizationDecision? = nil
        ) {
            let event = AgentTraceEvent(
                requestID: request.id,
                state: state,
                message: message,
                redactedCommand: redactedCommand,
                metadata: traceMetadata(extra: metadata, decision: decision)
            )
            events.append(event)
            target.appendAgentTrace(event)
            externalEmit(event)
        }
        emit(.queued, "\(request.actor.name) 已请求操作 \(target.agentTitle)")
        let willRequireUserConfirmation = authorizer.requiresUserConfirmation(
            actor: request.actor,
            command: commandRequest.command,
            targetTitle: target.agentTitle,
            automationPolicy: target.agentAutomationPolicy
        )
        if willRequireUserConfirmation {
            emit(.awaitingApproval, "等待 Stacio 确认")
        }
        let decision = try authorizer.authorize(
            actor: request.actor,
            command: commandRequest.command,
            targetTitle: target.agentTitle,
            automationPolicy: target.agentAutomationPolicy
        )
        var didRecordRunningAudit = false
        func recordRunningAuditIfNeeded() {
            guard didRecordRunningAudit == false else { return }
            didRecordRunningAudit = true
            recordAuditEvent(
                request: request,
                target: target,
                risk: decision.risk,
                state: .running,
                redactedInput: redactedCommand,
                decision: decision
            )
        }
        if decision.requiredUserConfirmation && willRequireUserConfirmation == false {
            emit(.awaitingApproval, "等待 Stacio 确认")
        }
        guard decision.allowed else {
            emit(.cancelled, "操作已取消", decision: decision)
            recordAuditEvent(
                request: request,
                target: target,
                risk: decision.risk,
                state: .cancelled,
                redactedInput: redactedCommand,
                decision: decision
            )
            throw AgentExecutionError.denied(decision.reason)
        }

        if decision.requiredUserConfirmation {
            emit(.approved, "已确认，准备写入终端", decision: decision)
        } else {
            emit(.approved, "已按全局策略自动放行", decision: decision)
        }
        auditContextsByRequestID[request.id] = AuditContext(
            request: request,
            target: target,
            risk: decision.risk,
            redactedInput: redactedCommand,
            decision: decision
        )
        switch mode {
        case .visibleTerminal:
            trackedTasksByRequestID[request.id] = TrackedTask(
                target: target,
                sourceRuntimeID: target.runtimeID,
                redactedCommand: redactedCommand,
                executionMode: "visibleTerminal",
                actor: request.actor
            )
            target.setAgentInteractionLocked(true)
            emit(.typing, "正在写入终端", decision: decision)
            let visibleObservation = VisibleTerminalObservationSession(
                requestID: request.id,
                runtimeID: target.runtimeID,
                command: commandRequest.command,
                redactedCommand: redactedCommand,
                outputHub: visibleTerminalOutputHub,
                completion: visibleTerminalCompletion,
                commandCompletionGeneration: { target.agentCommandCompletionGeneration },
                terminalOutputTranscript: { target.agentTerminalOutputTranscript },
                terminalDisplaySnapshot: { target.agentTerminalDisplaySnapshot },
                refreshTerminalOutput: { target.refreshAgentTerminalOutput() },
                completionMarker: target.supportsAgentCompletionMarker
                    ? Self.agentCompletionMarker(requestID: request.id)
                    : nil,
                onOutputUpdate: { update in
                    emit(
                        .waitingForOutput,
                        "终端输出更新：\(update.summary)",
                        metadata: [
                            "terminalOutputSummary": update.summary,
                            "completionConfidence": "streaming"
                        ],
                        decision: decision
                    )
                }
            )
            visibleObservation.begin()
            visibleObservation.markCommandWriteStarted()
            let terminalCommand = target.supportsAgentCompletionMarker
                ? Self.commandWithCompletionMarker(commandRequest.command, requestID: request.id)
                : commandRequest.command
            target.sendAgentInput(Array((terminalCommand + "\n").utf8))
            emit(.running, "命令已在终端执行，输出将实时显示", decision: decision)
            recordRunningAuditIfNeeded()
            let initialObservation = visibleObservation.wait()
            let observation = initialObservation.outcome == .manualRequired
                ? (visibleObservation.completedResultFromTranscriptIfPromptPresent() ?? initialObservation)
                : initialObservation
            StacioLogStore.shared.append(
                level: observation.outcome == .completed ? .info : .warning,
                category: "Agent",
                message: "agent.visible.observation outcome=\(observation.outcome) reason=\(observation.reason) \(visibleObservation.diagnosticDescription)"
            )
            switch observation.outcome {
            case .completed:
                let completionConfidence: String
                switch observation.reason {
                case "auditEndMarker", "agentCompletionMarker":
                    completionConfidence = "explicitMarker"
                case "shellPromptObserved":
                    completionConfidence = "observedPrompt"
                default:
                    completionConfidence = "observedIdle"
                }
                emit(
                    .completed,
                    "本次命令已完成：\(observation.summary)",
                    metadata: [
                        "terminalOutputSummary": observation.summary,
                        "completionConfidence": completionConfidence,
                        "completionReason": observation.reason
                    ],
                    decision: decision
                )
                trackedTasksByRequestID.removeValue(forKey: request.id)
                target.setAgentInteractionLocked(false)
            case .manualRequired:
                var metadata = [
                    "completionConfidence": "manualRequired",
                    "completionReason": observation.reason
                ]
                if observation.summary.isEmpty == false {
                    metadata["terminalOutputSummary"] = observation.summary
                }
                emit(
                    .waitingForOutput,
                    "这条命令可能仍在运行，Stacio 不会根据静默输出自动判定完成；请手动停止、确认或接管。",
                    metadata: metadata,
                    decision: decision
                )
            case .ambiguousUserInput:
                emit(
                    .waitingForOutput,
                    "执行期间检测到人工输入，当前终端输出归属不确定；Stacio 已暂停本步自动总结，请确认或接管。",
                    metadata: [
                        "completionConfidence": "ambiguousUserInput",
                        "completionReason": observation.reason
                    ],
                    decision: decision
                )
            }
        case .backgroundTask:
            guard let liveSessionContext = target.agentLiveSessionContext else {
                emit(
                    .failed,
                    "AI 独立任务失败：\(AgentExecutionError.backgroundTaskUnavailable.localizedDescription)",
                    metadata: [
                        "fallbackReason": "backgroundTaskUnavailable"
                    ],
                    decision: decision
                )
                recordAuditEvent(
                    request: request,
                    target: target,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                break
            }
            emit(
                .running,
                "独立任务已启动，输出将同步显示",
                decision: decision
            )
            backgroundTargetsByRequestID[request.id] = target
            trackedTasksByRequestID[request.id] = TrackedTask(
                target: target,
                sourceRuntimeID: target.runtimeID,
                redactedCommand: redactedCommand,
                executionMode: "backgroundTask",
                actor: request.actor
            )
            recordRunningAuditIfNeeded()
            try backgroundCommandRunner.runBackgroundCommand(
                AgentBackgroundCommandRequest(
                    requestID: request.id,
                    command: commandRequest.command,
                    targetRuntimeID: target.runtimeID,
                    targetTitle: target.agentTitle,
                    actor: request.actor,
                    redactedCommand: redactedCommand,
                liveSessionContext: liveSessionContext
            ),
                emit: { event in
                    let contextualEvent = AgentTraceEvent(
                        requestID: event.requestID,
                        state: event.state,
                        message: event.message,
                        redactedCommand: event.redactedCommand,
                        metadata: traceMetadata(extra: event.metadata, decision: decision)
                    )
                    target.appendAgentTrace(contextualEvent)
                    externalEmit(contextualEvent)
                    self.recordAuditTerminalStateIfNeeded(contextualEvent)
                    if Self.shouldRemoveTrackedTask(for: contextualEvent.state) {
                        self.trackedTasksByRequestID.removeValue(forKey: contextualEvent.requestID)
                        self.backgroundTargetsByRequestID.removeValue(forKey: contextualEvent.requestID)
                    }
                }
            )
        }
        if events.last?.state != .failed {
            recordRunningAuditIfNeeded()
        }
        return events
    }

    private static func agentCompletionMarker(requestID: String) -> [UInt8] {
        Array("\u{001B}]777;stacio-agent-done=\(sanitizedMarkerID(requestID))\u{0007}".utf8)
    }

    private static func commandWithCompletionMarker(_ command: String, requestID: String) -> String {
        let markerID = sanitizedMarkerID(requestID)
        return "{ \(command)\n}; printf '\\033]777;stacio-agent-done=\(markerID)\\007'"
    }

    private static func sanitizedMarkerID(_ requestID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(requestID.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
    }

    public func pauseTask(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID.removeValue(forKey: requestID) else {
            return nil
        }
        task.target.setAgentInteractionLocked(false)
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .paused,
            message: "AI 后续自动动作已暂停；当前命令仍以目标终端输出为准。",
            redactedCommand: task.redactedCommand,
            metadata: [
                "executionMode": task.executionMode,
                "sourceRuntimeID": task.sourceRuntimeID,
                "targetTitle": task.target.agentTitle,
                "actorKind": task.actor.kind.rawValue,
                "actorName": task.actor.name,
                "control": "pause"
            ]
        )
        task.target.appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: event)
        return event
    }

    public func cancelTask(requestID: String) -> AgentTraceEvent? {
        if let task = trackedTasksByRequestID[requestID],
           task.executionMode == "visibleTerminal" {
            trackedTasksByRequestID.removeValue(forKey: requestID)
            backgroundTargetsByRequestID.removeValue(forKey: requestID)
            task.target.setAgentInteractionLocked(false)
            guard let currentTarget = currentTerminalTarget(for: task) else {
                return nil
            }
            currentTarget.sendInput([3])
            let event = AgentTraceEvent(
                requestID: requestID,
                state: .cancelled,
                message: "已向可见终端发送中断；输出仍以目标终端为准。",
                redactedCommand: task.redactedCommand,
                metadata: [
                    "executionMode": task.executionMode,
                    "sourceRuntimeID": task.sourceRuntimeID,
                    "targetTitle": currentTarget.agentTitle,
                    "actorKind": task.actor.kind.rawValue,
                    "actorName": task.actor.name,
                    "control": "cancel"
                ]
            )
            currentTarget.appendAgentTrace(event)
            recordAuditTerminalStateIfNeeded(event, removeContext: true)
            finishBridgeFollowStream(requestID: requestID, event: event)
            return event
        }
        let trackedTask = trackedTasksByRequestID[requestID]
        guard let event = backgroundCommandRunner.cancel(requestID: requestID) else {
            return nil
        }
        trackedTasksByRequestID.removeValue(forKey: requestID)
        var metadata = event.metadata ?? [:]
        if let trackedTask {
            metadata["executionMode"] = trackedTask.executionMode
            metadata["sourceRuntimeID"] = trackedTask.sourceRuntimeID
            metadata["targetTitle"] = trackedTask.target.agentTitle
            metadata["actorKind"] = trackedTask.actor.kind.rawValue
            metadata["actorName"] = trackedTask.actor.name
        }
        let contextualEvent = AgentTraceEvent(
            requestID: event.requestID,
            state: event.state,
            message: event.message,
            redactedCommand: event.redactedCommand ?? trackedTask?.redactedCommand,
            metadata: metadata
        )
        let target = backgroundTargetsByRequestID.removeValue(forKey: requestID) ?? trackedTask?.target
        target?.appendAgentTrace(contextualEvent)
        recordAuditTerminalStateIfNeeded(contextualEvent, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: contextualEvent)
        return contextualEvent
    }

    public func takeOverTask(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID.removeValue(forKey: requestID) else {
            return nil
        }
        task.target.setAgentInteractionLocked(false)
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let cancelEvent = task.executionMode == "backgroundTask"
            ? backgroundCommandRunner.cancel(requestID: requestID)
            : nil
        var metadata: [String: String] = [
            "executionMode": task.executionMode,
            "sourceRuntimeID": task.sourceRuntimeID,
            "targetTitle": task.target.agentTitle,
            "actorKind": task.actor.kind.rawValue,
            "actorName": task.actor.name,
            "control": "takeover"
        ]
        if let taskRuntimeID = cancelEvent?.metadata?["taskRuntimeID"] {
            metadata["taskRuntimeID"] = taskRuntimeID
        }
        let message = task.executionMode == "visibleTerminal"
            ? "可见终端已切换为人工接管；AI 不再继续自动执行。"
            : "任务已切换为人工接管；AI 不再继续自动执行。"
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .takenOver,
            message: message,
            redactedCommand: cancelEvent?.redactedCommand ?? task.redactedCommand,
            metadata: metadata
        )
        task.target.appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: event)
        return event
    }

    public func confirmTaskComplete(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID.removeValue(forKey: requestID) else {
            return nil
        }
        task.target.setAgentInteractionLocked(false)
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .completed,
            message: "已确认本步结束。",
            redactedCommand: task.redactedCommand,
            metadata: [
                "executionMode": task.executionMode,
                "sourceRuntimeID": task.sourceRuntimeID,
                "targetTitle": task.target.agentTitle,
                "actorKind": task.actor.kind.rawValue,
                "actorName": task.actor.name,
                "completionConfidence": "userConfirmed",
                "completionReason": "userConfirmed"
            ]
        )
        task.target.appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: event)
        return event
    }

    private func finishBridgeFollowStream(requestID: String, event: AgentTraceEvent) {
        guard let stream = bridgeFollowStreamsByRequestID.removeValue(forKey: requestID) else {
            return
        }
        stream.emit(event)
        stream.completion()
    }

    func registerBridgeFollowStream(
        requestID: String,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        bridgeFollowStreamsByRequestID[requestID] = BridgeFollowStream(
            emit: emit,
            completion: completion
        )
    }

    func discardBridgeFollowStream(requestID: String) {
        bridgeFollowStreamsByRequestID.removeValue(forKey: requestID)
    }

    private func currentTerminalTarget(for task: TrackedTask) -> AgentTerminalTarget? {
        do {
            let target = try terminalResolver.resolveTerminalTarget(.runtimeID(task.sourceRuntimeID))
            guard target.runtimeID == task.sourceRuntimeID else {
                return nil
            }
            return target
        } catch {
            return nil
        }
    }

    private func recordAuditTerminalStateIfNeeded(
        _ event: AgentTraceEvent,
        removeContext: Bool? = nil
    ) {
        guard shouldRecordAuditState(event.state),
              let context = auditContextsByRequestID[event.requestID]
        else { return }
        recordAuditEvent(
            request: context.request,
            target: context.target,
            risk: context.risk,
            state: event.state,
            redactedInput: event.redactedCommand ?? context.redactedInput,
            decision: context.decision
        )
        if removeContext ?? shouldRemoveAuditContext(for: event.state) {
            auditContextsByRequestID.removeValue(forKey: event.requestID)
        }
    }

    private func shouldRecordAuditState(_ state: AgentTraceState) -> Bool {
        switch state {
        case .paused, .completed, .failed, .cancelled, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            return false
        }
    }

    private func shouldRemoveAuditContext(for state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .takenOver:
            return true
        case .paused, .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            return false
        }
    }

    private static func shouldRemoveTrackedTask(for state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .paused, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            return false
        }
    }

    private func resolvedExecutionMode() -> AgentExecutionMode {
        executionModeResolver?() ?? executionMode
    }

    private func traceValue(for mode: AgentExecutionMode) -> String {
        switch mode {
        case .visibleTerminal:
            return "visibleTerminal"
        case .backgroundTask:
            return "backgroundTask"
        }
    }

    private func recordAuditEvent(
        request: AgentBridgeRequest,
        target: AgentTerminalTarget,
        risk: AgentActionRisk,
        state: AgentTraceState,
        redactedInput: String,
        decision: AgentAuthorizationDecision
    ) {
        _ = try? auditRecorder?.recordAgentActionEvent(
            AgentActionAuditEvent(
                requestId: request.id,
                actorKind: request.actor.kind.rawValue,
                actorName: request.actor.name,
                targetRuntimeId: target.runtimeID,
                targetTitle: target.agentTitle,
                actionKind: "runCommand",
                risk: risk.rawValue,
                state: state.rawValue,
                redactedInput: redactedInput,
                environment: target.agentAutomationPolicy.environment,
                approvalMode: target.agentAutomationPolicy.aiExecutionPolicy,
                policyDecision: policyDecisionValue(for: decision),
                redactionVersion: Self.agentAuditRedactionVersion
            )
        )
    }

    private func policyDecisionValue(for decision: AgentAuthorizationDecision) -> String {
        guard decision.allowed else {
            return "denied"
        }
        return decision.requiredUserConfirmation ? "confirmed" : "autoAllowed"
    }

    public func listSessions(_ request: AgentBridgeRequest) -> [AgentTraceEvent] {
        guard case .listSessions = request.action else {
            return []
        }
        let sessions = sessionLister?.listAgentTerminalSessions() ?? []
        guard !sessions.isEmpty else {
            return [
                AgentTraceEvent(
                    requestID: request.id,
                    state: .completed,
                    message: "当前没有可执行的 Stacio 终端。",
                    redactedCommand: nil,
                    metadata: ["type": "terminalSessionList", "count": "0"]
                )
            ]
        }
        return sessions.map { session in
            var metadata: [String: String] = [
                "type": "terminalSession",
                "runtimeID": session.runtimeID,
                "title": session.title,
                "kind": session.kind,
                "environment": session.environment,
                "current": session.isCurrent ? "true" : "false"
            ]
            if let currentDirectory = session.currentDirectory {
                metadata["currentDirectory"] = currentDirectory
            }
            if let subtitle = session.subtitle {
                metadata["subtitle"] = subtitle
            }
            return AgentTraceEvent(
                requestID: request.id,
                state: .completed,
                message: session.title,
                redactedCommand: nil,
                metadata: metadata
            )
        }
    }
}

extension AgentExecutionCoordinator: AgentCommandExecuting, AgentTaskControlling {}

extension TerminalPaneViewController: AgentTerminalTarget {
    public var agentCommandCompletionGeneration: UInt64 { commandCompletionGeneration }
    public var agentTerminalOutputTranscript: String { terminalOutputTranscript }
    public var agentTerminalDisplaySnapshot: String { terminalDisplaySnapshotForTesting }
    public var supportsAgentCompletionMarker: Bool { true }

    public var agentTitle: String {
        title ?? L10n.Workspace.local
    }

    public var agentLiveSessionContext: TunnelLiveSessionContext? {
        nil
    }

    public var agentAutomationPolicy: SessionAutomationPolicy {
        .default
    }

    public func appendAgentTrace(_ event: AgentTraceEvent) {
        appendAgentTrace(
            requestID: event.requestID,
            state: event.state,
            message: event.message,
            redactedCommand: event.redactedCommand,
            metadata: event.metadata
        )
    }
}

extension RemoteTerminalPaneViewController: AgentTerminalTarget {
    public var agentCommandCompletionGeneration: UInt64 { commandCompletionGeneration }
    public var agentTerminalOutputTranscript: String { terminalOutputTranscript }
    public var agentTerminalDisplaySnapshot: String { terminalDisplaySnapshotForTesting }
    public var supportsAgentCompletionMarker: Bool { true }

    public var agentTitle: String {
        terminalTitle
    }

    public var agentLiveSessionContext: TunnelLiveSessionContext? {
        liveSessionContext
    }

    public var agentAutomationPolicy: SessionAutomationPolicy {
        automationPolicy
    }

    public func appendAgentTrace(_ event: AgentTraceEvent) {
        appendAgentTrace(
            requestID: event.requestID,
            state: event.state,
            message: event.message,
            redactedCommand: event.redactedCommand,
            metadata: event.metadata
        )
    }
}
