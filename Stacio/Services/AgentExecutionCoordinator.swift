import AppKit
import CryptoKit
import Foundation
import StacioAgentBridge
import StacioCoreBindings

@MainActor
public protocol AgentTerminalTarget: AnyObject {
    var runtimeID: String { get }
    var agentRuntimeGeneration: UInt64 { get }
    var isAgentRuntimeConnected: Bool { get }
    var agentTitle: String { get }
    var agentLiveSessionContext: TunnelLiveSessionContext? { get }
    var agentAutomationPolicy: SessionAutomationPolicy { get }
    var agentCommandCompletionGeneration: UInt64 { get }
    var agentTerminalOutputTranscript: String { get }
    var agentTerminalDisplaySnapshot: String { get }
    var supportsAgentCompletionMarker: Bool { get }
    var isAwaitingSensitiveInput: Bool { get }
    var isSensitiveInputProtectionActive: Bool { get }
    func setAgentInteractionLocked(_ locked: Bool)
    func refreshAgentTerminalOutput()
    func appendAgentTrace(_ event: AgentTraceEvent)
    func sendInput(_ bytes: [UInt8])
    @discardableResult func sendAgentInput(_ bytes: [UInt8]) -> Bool
    @discardableResult func sendSensitiveUserInput(_ bytes: [UInt8]) -> Bool
}

public extension AgentTerminalTarget {
    var agentRuntimeGeneration: UInt64 { 0 }
    var isAgentRuntimeConnected: Bool { true }
    var agentAutomationPolicy: SessionAutomationPolicy { .default }
    var agentCommandCompletionGeneration: UInt64 { 0 }
    var agentTerminalOutputTranscript: String { "" }
    var agentTerminalDisplaySnapshot: String { agentTerminalOutputTranscript }
    var supportsAgentCompletionMarker: Bool { false }
    var isAwaitingSensitiveInput: Bool { false }
    var isSensitiveInputProtectionActive: Bool { false }
    func setAgentInteractionLocked(_ locked: Bool) {}
    func refreshAgentTerminalOutput() {}
    @discardableResult
    func sendAgentInput(_ bytes: [UInt8]) -> Bool {
        guard isAgentRuntimeConnected,
              isSensitiveInputProtectionActive == false
        else { return false }
        sendInput(bytes)
        return true
    }
    @discardableResult func sendSensitiveUserInput(_ bytes: [UInt8]) -> Bool { false }
}

public struct AgentSensitiveInputPrompt: Equatable {
    public let runtimeID: String
    public let connectionGeneration: UInt64
    public let targetTitle: String

    public init(
        runtimeID: String,
        connectionGeneration: UInt64 = 0,
        targetTitle: String
    ) {
        self.runtimeID = runtimeID
        self.connectionGeneration = connectionGeneration
        self.targetTitle = targetTitle
    }
}

@MainActor
public protocol AgentSensitiveInputRouting {
    func sensitiveInputPrompt(runtimeID: String) -> AgentSensitiveInputPrompt?
    @discardableResult func submitSensitiveInput(_ bytes: [UInt8], runtimeID: String) -> Bool
    @discardableResult func submitSensitiveInput(
        _ bytes: [UInt8],
        prompt: AgentSensitiveInputPrompt
    ) -> Bool
}

public extension AgentSensitiveInputRouting {
    @discardableResult
    func submitSensitiveInput(
        _ bytes: [UInt8],
        prompt: AgentSensitiveInputPrompt
    ) -> Bool {
        guard sensitiveInputPrompt(runtimeID: prompt.runtimeID) == prompt else {
            return false
        }
        return submitSensitiveInput(bytes, runtimeID: prompt.runtimeID)
    }
}

@MainActor
public protocol AgentTerminalResolving {
    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget
}

public struct AgentTerminalSessionSummary: Equatable {
    public let runtimeID: String
    public let connectionGeneration: UInt64
    public let title: String
    public let kind: String
    public let environment: String
    public let isCurrent: Bool
    public let currentDirectory: String?
    public let subtitle: String?

    public init(
        runtimeID: String,
        connectionGeneration: UInt64 = 0,
        title: String,
        kind: String,
        environment: String,
        isCurrent: Bool,
        currentDirectory: String? = nil,
        subtitle: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.connectionGeneration = connectionGeneration
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
    func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy,
        approvalEvidence: AgentCommandApprovalEvidence?
    ) -> Bool
    func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy,
        approvalEvidence: AgentCommandApprovalEvidence?
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

    public func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy,
        approvalEvidence: AgentCommandApprovalEvidence?
    ) -> Bool {
        requiresUserConfirmation(
            actor: actor,
            command: command,
            targetTitle: targetTitle,
            automationPolicy: automationPolicy
        )
    }

    public func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy,
        approvalEvidence: AgentCommandApprovalEvidence?
    ) throws -> AgentAuthorizationDecision {
        try authorize(
            actor: actor,
            command: command,
            targetTitle: targetTitle,
            automationPolicy: automationPolicy
        )
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
public protocol AgentCommandAsyncStreamingExecuting: AgentCommandStreamingExecuting {
    func runCommandAsync(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) async throws -> [AgentTraceEvent]
}

public extension AgentCommandAsyncStreamingExecuting {
    func runCommandAsync(_ request: AgentBridgeRequest) async throws -> [AgentTraceEvent] {
        try await runCommandAsync(request, emit: { _ in })
    }
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
    public let sourceRuntimeGeneration: UInt64
    public let targetTitle: String
    public let actor: AgentActor
    public let redactedCommand: String
    public let liveSessionContext: TunnelLiveSessionContext?

    public init(
        requestID: String,
        command: String,
        targetRuntimeID: String,
        sourceRuntimeGeneration: UInt64 = 0,
        targetTitle: String,
        actor: AgentActor,
        redactedCommand: String,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        self.requestID = requestID
        self.command = command
        self.targetRuntimeID = targetRuntimeID
        self.sourceRuntimeGeneration = sourceRuntimeGeneration
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
    case runtimeLeaseChanged
}

private struct VisibleTerminalObservationResult: Equatable {
    let outcome: VisibleTerminalObservationOutcome
    let summary: String
    let reason: String
}

private struct VisibleTerminalOutputUpdate: Equatable {
    let summary: String
    let sensitiveInputRequired: Bool
}

@MainActor
private final class VisibleTerminalObservationSession {
    private static let maximumObservedOutputByteCount = 256 * 1024
    private static let maximumSummaryCharacterCount = 8_000
    private static let maximumHistoryCharacterCount = 32_000
    private static let outputUpdateInterval: TimeInterval = 0.1
    private static let responsiveEventMask: NSEvent.EventTypeMask = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel,
        .keyDown,
        .keyUp,
        .flagsChanged
    ]

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
    private let isAwaitingSensitiveInput: () -> Bool
    private let isRuntimeLeaseCurrent: () -> Bool
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
    private var lastOutputUpdateAt = Date.distantPast
    private var lastPublishedOutputSummary: String?
    private var lastPublishedSensitiveInputRequired: Bool?
    private var subscription: TerminalOutputBroadcastHub.Subscription?
    private var previouslyAwaitingSensitiveInput = false
    private var waitingForPostSensitiveOutput = false
    private var sensitiveInteractionDeadline: Date?

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
        isAwaitingSensitiveInput: @escaping () -> Bool,
        isRuntimeLeaseCurrent: @escaping () -> Bool,
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
        self.isAwaitingSensitiveInput = isAwaitingSensitiveInput
        self.isRuntimeLeaseCurrent = isRuntimeLeaseCurrent
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

    func cancelBeforeCommandWrite() {
        close()
    }

    func wait() -> VisibleTerminalObservationResult {
        defer { close() }
        guard isRuntimeLeaseCurrent() else {
            return runtimeLeaseChangedResult()
        }
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
        let activityGrace = max(
            completion.idleInterval * 2,
            min(completion.maximumDuration, 2)
        )
        let hardDeadline = deadline.addingTimeInterval(max(completion.maximumDuration * 4, 30))
        while shouldContinueWaiting(
            baseDeadline: outputGraceDeadline,
            hardDeadline: hardDeadline,
            activityGrace: activityGrace
        ) {
            guard isRuntimeLeaseCurrent() else {
                return runtimeLeaseChangedResult()
            }
            let awaitingSensitiveInput = refreshSensitiveInputTracking()
            runResponsiveMainLoopIteration()
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
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               let auditCompletionSummary {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: auditCompletionSummary,
                    reason: "auditEndMarker"
                )
            }
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               let markerSummary = agentCompletionMarkerSummary() {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: markerSummary,
                    reason: "agentCompletionMarker"
                )
            }
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               sawShellPrompt {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: Self.summary(from: outputBytes),
                    reason: "shellPromptObserved"
                )
            }
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               let lastOutputAt,
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
        guard isRuntimeLeaseCurrent() else {
            return runtimeLeaseChangedResult()
        }
        return VisibleTerminalObservationResult(
            outcome: .manualRequired,
            summary: Self.summary(from: outputBytes),
            reason: outputBytes.isEmpty ? "noOutputBeforeTimeout" : "timeoutBeforeSafeCompletion"
        )
    }

    func waitAsync() async -> VisibleTerminalObservationResult {
        defer { close() }
        guard isRuntimeLeaseCurrent() else {
            return runtimeLeaseChangedResult()
        }
        if Self.requiresManualCompletion(command) {
            if let completed = await waitUntilManualCommandHasInitialObservationAsync() {
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
        let activityGrace = max(
            completion.idleInterval * 2,
            min(completion.maximumDuration, 2)
        )
        let hardDeadline = deadline.addingTimeInterval(max(completion.maximumDuration * 4, 30))
        while shouldContinueWaiting(
            baseDeadline: outputGraceDeadline,
            hardDeadline: hardDeadline,
            activityGrace: activityGrace
        ) {
            guard Task.isCancelled == false else {
                return VisibleTerminalObservationResult(
                    outcome: .manualRequired,
                    summary: Self.summary(from: outputBytes),
                    reason: "observationCancelled"
                )
            }
            guard isRuntimeLeaseCurrent() else {
                return runtimeLeaseChangedResult()
            }
            let awaitingSensitiveInput = refreshSensitiveInputTracking()
            refreshTerminalOutputIfNeeded()
            if let result = completedObservationIfAvailable(
                awaitingSensitiveInput: awaitingSensitiveInput,
                allowIdleCompletion: true
            ) {
                return result
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard isRuntimeLeaseCurrent() else {
            return runtimeLeaseChangedResult()
        }
        return VisibleTerminalObservationResult(
            outcome: .manualRequired,
            summary: Self.summary(from: outputBytes),
            reason: outputBytes.isEmpty ? "noOutputBeforeTimeout" : "timeoutBeforeSafeCompletion"
        )
    }

    func completedResultFromTranscriptIfPromptPresent() -> VisibleTerminalObservationResult? {
        guard isRuntimeLeaseCurrent(),
              sawUserInput == false,
              refreshSensitiveInputTracking() == false,
              waitingForPostSensitiveOutput == false
        else { return nil }
        captureDirectTerminalOutputIfNeeded()
        captureVisibleTerminalDisplayIfNeeded()
        guard sawShellPrompt
            || commandCompletionGeneration() != initialCommandCompletionGeneration
            || Self.hasTrailingShellPrompt(in: outputBytes)
        else { return nil }
        return VisibleTerminalObservationResult(
            outcome: .completed,
            summary: Self.summary(from: outputBytes),
            reason: "shellPromptObserved"
        )
    }

    var redactedHistoryOutput: String {
        var bytes = outputBytes
        if let markerRange = Self.auditEndMarkerRange(in: bytes) {
            bytes = Array(bytes[..<markerRange.lowerBound])
        } else if let completionMarker,
                  let markerRange = Self.range(of: completionMarker, in: bytes) {
            bytes = Array(bytes[..<markerRange.lowerBound])
        }
        return Self.historyOutput(from: bytes)
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
            "user_input=\(sawUserInput)",
            "sensitive_input=\(isAwaitingSensitiveInput())",
            "waiting_after_sensitive_input=\(waitingForPostSensitiveOutput)"
        ].joined(separator: " ")
    }

    private func ingest(_ event: TerminalBroadcastEvent) {
        guard isRuntimeLeaseCurrent() else { return }
        switch event.kind {
        case .output:
            guard commandOutputCaptureStarted else { return }
            guard sawUserInput == false else { return }
            _ = refreshSensitiveInputTracking(now: event.createdAt)
            waitingForPostSensitiveOutput = false
            appendObservedOutput(event.bytes)
            lastOutputAt = event.createdAt
            sawShellPrompt = TerminalOSC7SequenceParser.currentDirectories(from: outputBytes).isEmpty == false
                || Self.hasTrailingShellPrompt(in: outputBytes)
            if let markerRange = Self.auditEndMarkerRange(in: outputBytes) {
                auditCompletionSummary = Self.summary(from: Array(outputBytes[..<markerRange.lowerBound]))
            }
            publishOutputUpdateIfNeeded()
        case .userInput:
            if Self.isAICommandEcho(event.bytes, command: command) {
                commandOutputCaptureStarted = true
            } else {
                sawUserInput = true
            }
        case .commandFinished:
            guard commandOutputCaptureStarted, sawUserInput == false else { return }
            _ = refreshSensitiveInputTracking(now: event.createdAt)
            waitingForPostSensitiveOutput = false
            sawShellPrompt = true
        }
    }

    private func waitUntilManualCommandHasInitialObservation() -> VisibleTerminalObservationResult? {
        let deadline = Date().addingTimeInterval(
            min(completion.maximumDuration, max(completion.idleInterval * 2, 0.75))
        )
        while shouldContinueWaiting(baseDeadline: deadline) {
            guard isRuntimeLeaseCurrent() else {
                return runtimeLeaseChangedResult()
            }
            let awaitingSensitiveInput = refreshSensitiveInputTracking()
            runResponsiveMainLoopIteration()
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
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               let auditCompletionSummary {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: auditCompletionSummary,
                    reason: "auditEndMarker"
                )
            }
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               let markerSummary = agentCompletionMarkerSummary() {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: markerSummary,
                    reason: "agentCompletionMarker"
                )
            }
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               sawShellPrompt {
                return VisibleTerminalObservationResult(
                    outcome: .completed,
                    summary: Self.summary(from: outputBytes),
                    reason: "shellPromptObserved"
                )
            }
            if awaitingSensitiveInput == false,
               waitingForPostSensitiveOutput == false,
               let lastOutputAt,
               Date().timeIntervalSince(lastOutputAt) >= completion.idleInterval,
               outputBytes.isEmpty == false {
                return nil
            }
        }
        guard isRuntimeLeaseCurrent() else {
            return runtimeLeaseChangedResult()
        }
        return nil
    }

    private func waitUntilManualCommandHasInitialObservationAsync() async -> VisibleTerminalObservationResult? {
        let deadline = Date().addingTimeInterval(
            min(completion.maximumDuration, max(completion.idleInterval * 2, 0.75))
        )
        while shouldContinueWaiting(baseDeadline: deadline) {
            guard Task.isCancelled == false else { return nil }
            guard isRuntimeLeaseCurrent() else {
                return runtimeLeaseChangedResult()
            }
            let awaitingSensitiveInput = refreshSensitiveInputTracking()
            refreshTerminalOutputIfNeeded()
            if let result = completedObservationIfAvailable(
                awaitingSensitiveInput: awaitingSensitiveInput,
                allowIdleCompletion: false
            ) {
                return result
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard isRuntimeLeaseCurrent() else {
            return runtimeLeaseChangedResult()
        }
        return nil
    }

    private func completedObservationIfAvailable(
        awaitingSensitiveInput: Bool,
        allowIdleCompletion: Bool
    ) -> VisibleTerminalObservationResult? {
        if sawUserInput {
            return VisibleTerminalObservationResult(
                outcome: .ambiguousUserInput,
                summary: "",
                reason: "userInputDuringCommand"
            )
        }
        captureDirectTerminalOutputIfNeeded()
        captureVisibleTerminalDisplayIfNeeded()
        guard awaitingSensitiveInput == false,
              waitingForPostSensitiveOutput == false
        else { return nil }
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
        if allowIdleCompletion,
           let lastOutputAt,
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
        return nil
    }

    private func shouldContinueWaiting(
        baseDeadline: Date,
        hardDeadline: Date? = nil,
        activityGrace: TimeInterval = 0
    ) -> Bool {
        let now = Date()
        let awaitingSensitiveInput = refreshSensitiveInputTracking(now: now)
        let sensitiveInteractionActive = awaitingSensitiveInput
            || sensitiveInteractionDeadline.map { now < $0 } == true
        guard sensitiveInteractionActive == false else { return true }
        guard hardDeadline.map({ now < $0 }) ?? true else { return false }
        let activityDeadline = lastOutputAt?.addingTimeInterval(activityGrace)
        return now < baseDeadline || activityDeadline.map { now < $0 } == true
    }

    @discardableResult
    private func refreshSensitiveInputTracking(now: Date = Date()) -> Bool {
        let awaitingSensitiveInput = isAwaitingSensitiveInput()
        if awaitingSensitiveInput {
            previouslyAwaitingSensitiveInput = true
        } else if previouslyAwaitingSensitiveInput {
            previouslyAwaitingSensitiveInput = false
            waitingForPostSensitiveOutput = true
            lastOutputAt = nil
            sensitiveInteractionDeadline = now.addingTimeInterval(completion.maximumDuration)
        }
        return awaitingSensitiveInput
    }

    private func close() {
        if let subscription {
            outputHub.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        subscription = nil
    }

    private func runResponsiveMainLoopIteration() {
        let application = NSApplication.shared
        // The synchronous command contract uses a nested wait, so explicitly
        // dispatch a bounded number of queued user events to keep controls live.
        for _ in 0..<8 {
            guard let event = application.nextEvent(
                matching: Self.responsiveEventMask,
                until: Date(),
                inMode: .default,
                dequeue: true
            ) else {
                break
            }
            application.sendEvent(event)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
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
        guard isRuntimeLeaseCurrent(), sawUserInput == false else { return }
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
        replaceObservedOutput(with: Array(commandTranscript.utf8))
        lastOutputAt = Date()
        sawShellPrompt = commandCompletionGeneration() != initialCommandCompletionGeneration
            || TerminalOSC7SequenceParser.currentDirectories(from: outputBytes).isEmpty == false
            || Self.hasTrailingShellPrompt(in: outputBytes)
        if let markerRange = Self.auditEndMarkerRange(in: outputBytes) {
            auditCompletionSummary = Self.summary(from: Array(outputBytes[..<markerRange.lowerBound]))
        }
        publishOutputUpdateIfNeeded()
    }

    private func captureVisibleTerminalDisplayIfNeeded() {
        guard isRuntimeLeaseCurrent(), sawUserInput == false else { return }
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
            replaceObservedOutput(with: visibleBytes)
        }
        lastOutputAt = Date()
        sawShellPrompt = true
        publishOutputUpdateIfNeeded()
    }

    private static func normalizedOutput(from bytes: [UInt8]) -> String {
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
        // Remove only the echoed printf wrapper at the start. Some terminal
        // snapshots also retain a plain completion payload after command
        // output; using that later marker as the boundary would erase evidence.
        if let wrapperEnd = lines.firstIndex(where: { line in
            line.contains("printf")
                && line.range(
                    of: #"stacio-agent-done=[A-Za-z0-9_-]+"#,
                    options: .regularExpression
                ) != nil
        }) {
            lines.removeFirst(wrapperEnd + 1)
        }
        lines.removeAll { line in
            line.range(
                of: #"stacio-agent-done=[A-Za-z0-9_-]+"#,
                options: .regularExpression
            ) != nil
        }
        // A returned prompt proves completion but is not command output. It
        // otherwise produces prompt-only cards and appears right-aligned when
        // the terminal included cursor movement around it.
        while let trailingLine = lines.last, isShellPromptLine(trailingLine) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func isShellPromptLine(_ line: String) -> Bool {
        line.range(
            of: #"^[^\s@]+@[^\s:]+(?::[^\r\n#$%]*)?[#$%]\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func summary(from bytes: [UInt8]) -> String {
        let summary = normalizedOutput(from: bytes)
        guard summary.count > maximumSummaryCharacterCount else {
            return summary
        }
        return "...\n" + String(summary.suffix(maximumSummaryCharacterCount))
    }

    private static func historyOutput(from bytes: [UInt8]) -> String {
        let output = normalizedOutput(from: bytes)
        guard output.count > maximumHistoryCharacterCount else {
            return output
        }
        let headCount = maximumHistoryCharacterCount / 2
        let tailCount = maximumHistoryCharacterCount - headCount
        return String(output.prefix(headCount))
            + "\n... 已省略部分终端输出 ...\n"
            + String(output.suffix(tailCount))
    }

    private func appendObservedOutput(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false else {
            return
        }
        let maximumByteCount = Self.maximumObservedOutputByteCount
        if bytes.count >= maximumByteCount {
            outputBytes = Array(bytes.suffix(maximumByteCount))
            return
        }
        let overflow = outputBytes.count + bytes.count - maximumByteCount
        if overflow > 0 {
            outputBytes.removeFirst(overflow)
        }
        outputBytes.append(contentsOf: bytes)
    }

    private func replaceObservedOutput(with bytes: [UInt8]) {
        let maximumByteCount = Self.maximumObservedOutputByteCount
        outputBytes = bytes.count > maximumByteCount
            ? Array(bytes.suffix(maximumByteCount))
            : bytes
    }

    private func publishOutputUpdateIfNeeded() {
        guard isRuntimeLeaseCurrent() else { return }
        let summary = Self.summary(from: outputBytes)
        let sensitiveInputRequired = isAwaitingSensitiveInput()
        let summaryChanged = summary != lastPublishedOutputSummary
        let sensitiveStateChanged = sensitiveInputRequired != lastPublishedSensitiveInputRequired
        guard summary.isEmpty == false,
              summaryChanged || sensitiveStateChanged
        else { return }
        let now = Date()
        guard sensitiveStateChanged
                || now.timeIntervalSince(lastOutputUpdateAt) >= Self.outputUpdateInterval
        else {
            return
        }
        lastOutputUpdateAt = now
        lastPublishedOutputSummary = summary
        lastPublishedSensitiveInputRequired = sensitiveInputRequired
        onOutputUpdate(
            VisibleTerminalOutputUpdate(
                summary: summary,
                sensitiveInputRequired: sensitiveInputRequired
            )
        )
    }

    private func runtimeLeaseChangedResult() -> VisibleTerminalObservationResult {
        VisibleTerminalObservationResult(
            outcome: .runtimeLeaseChanged,
            summary: "",
            reason: "runtimeLeaseChanged"
        )
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
    case requestAlreadyActive
    case capabilityRejected
    case terminalRuntimeLeaseChanged
    case terminalInputRejected

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
        case .requestAlreadyActive:
            return "该 Agent 请求仍在执行，不能复用 request ID。"
        case .capabilityRejected:
            return "Local Agent capability 已失效或目标超出当前会话绑定。"
        case .terminalRuntimeLeaseChanged:
            return "目标终端已断开或重连，已批准的命令未写入。请基于当前连接重新确认。"
        case .terminalInputRejected:
            return "目标终端未接受 AI 命令，请确认终端仍在线且未等待敏感输入。"
        }
    }
}

private struct AgentUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private final class AgentBackgroundTaskEventGate: @unchecked Sendable {
    private enum State {
        case active
        case cancelling
        case cancelled
        case finished
    }

    private let condition = NSCondition()
    private var state: State = .active

    func beginCancellation() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard state == .active else { return false }
        state = .cancelling
        return true
    }

    func commitCancellation() {
        condition.lock()
        if state == .cancelling {
            state = .cancelled
        }
        condition.broadcast()
        condition.unlock()
    }

    func rollbackCancellation() {
        condition.lock()
        if state == .cancelling {
            state = .active
        }
        condition.broadcast()
        condition.unlock()
    }

    func canEmitProgress() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .active || state == .finished
    }

    func canActivate() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .active
    }

    func beginFinished() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while state == .cancelling {
            condition.wait()
        }
        guard state == .active else { return false }
        state = .finished
        return true
    }

    func canEmitFinished() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .finished
    }

    func waitForCancellationResolution() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while state == .cancelling {
            condition.wait()
        }
        return state == .cancelled
    }
}

private final class AgentBackgroundActiveTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTasksByRequestID: [String: RemoteSSHAgentBackgroundCommandRunner.PendingTask] = [:]
    private var tasksByRequestID: [String: RemoteSSHAgentBackgroundCommandRunner.ActiveTask] = [:]
    private var cancellationGatesByRequestID: [String: AgentBackgroundTaskEventGate] = [:]

    func prepare(_ task: RemoteSSHAgentBackgroundCommandRunner.PendingTask, requestID: String) -> Bool {
        lock.lock()
        guard pendingTasksByRequestID[requestID] == nil,
              tasksByRequestID[requestID] == nil,
              cancellationGatesByRequestID[requestID] == nil else {
            lock.unlock()
            return false
        }
        pendingTasksByRequestID[requestID] = task
        lock.unlock()
        return true
    }

    func set(_ task: RemoteSSHAgentBackgroundCommandRunner.ActiveTask, requestID: String) -> Bool {
        lock.lock()
        if cancellationGatesByRequestID[requestID] != nil || task.gate.canActivate() == false {
            lock.unlock()
            return false
        }
        tasksByRequestID[requestID] = task
        pendingTasksByRequestID.removeValue(forKey: requestID)
        lock.unlock()
        return true
    }

    func beginCancellation(requestID: String) -> RemoteSSHAgentBackgroundCommandRunner.CancelledTask? {
        lock.lock()
        let cancelledTask: RemoteSSHAgentBackgroundCommandRunner.CancelledTask?
        if let task = tasksByRequestID[requestID], task.gate.beginCancellation() {
            cancelledTask = RemoteSSHAgentBackgroundCommandRunner.CancelledTask(
                runtimeID: task.runtimeID,
                sourceRuntimeID: task.sourceRuntimeID,
                sourceRuntimeGeneration: task.sourceRuntimeGeneration,
                sourceTitle: task.sourceTitle,
                redactedCommand: task.redactedCommand
            )
        } else if let pendingTask = pendingTasksByRequestID[requestID],
                  pendingTask.gate.beginCancellation() {
            cancelledTask = RemoteSSHAgentBackgroundCommandRunner.CancelledTask(
                runtimeID: nil,
                sourceRuntimeID: pendingTask.sourceRuntimeID,
                sourceRuntimeGeneration: pendingTask.sourceRuntimeGeneration,
                sourceTitle: pendingTask.sourceTitle,
                redactedCommand: pendingTask.redactedCommand
            )
        } else {
            cancelledTask = nil
        }
        lock.unlock()
        return cancelledTask
    }

    func commitCancellation(
        requestID: String,
        task: RemoteSSHAgentBackgroundCommandRunner.CancelledTask
    ) -> Bool {
        lock.lock()
        let gate: AgentBackgroundTaskEventGate?
        if let runtimeID = task.runtimeID,
           let activeTask = tasksByRequestID[requestID],
           activeTask.runtimeID == runtimeID {
            tasksByRequestID.removeValue(forKey: requestID)
            gate = activeTask.gate
        } else if task.runtimeID == nil,
                  let pendingTask = pendingTasksByRequestID.removeValue(forKey: requestID) {
            gate = pendingTask.gate
        } else {
            gate = nil
        }
        if gate != nil {
            cancellationGatesByRequestID[requestID] = gate
        }
        lock.unlock()
        guard let gate else { return false }
        gate.commitCancellation()
        return true
    }

    func rollbackCancellation(
        requestID: String,
        task: RemoteSSHAgentBackgroundCommandRunner.CancelledTask
    ) {
        lock.lock()
        let gate: AgentBackgroundTaskEventGate?
        if let runtimeID = task.runtimeID,
           let activeTask = tasksByRequestID[requestID],
           activeTask.runtimeID == runtimeID {
            gate = activeTask.gate
        } else if task.runtimeID == nil {
            gate = pendingTasksByRequestID[requestID]?.gate
        } else {
            gate = nil
        }
        lock.unlock()
        gate?.rollbackCancellation()
    }

    func finish(requestID: String, runtimeID: String?) -> Bool {
        lock.lock()
        let gate: AgentBackgroundTaskEventGate?
        if let runtimeID,
           let task = tasksByRequestID[requestID],
           task.runtimeID == runtimeID {
            gate = task.gate
        } else {
            gate = pendingTasksByRequestID[requestID]?.gate
        }
        lock.unlock()
        guard let gate, gate.beginFinished() else {
            return false
        }

        lock.lock()
        let removed: Bool
        if let runtimeID,
           let task = tasksByRequestID[requestID],
           task.runtimeID == runtimeID,
           task.gate === gate {
            tasksByRequestID.removeValue(forKey: requestID)
            removed = true
        } else if let pendingTask = pendingTasksByRequestID[requestID],
                  pendingTask.gate === gate {
            pendingTasksByRequestID.removeValue(forKey: requestID)
            removed = true
        } else {
            removed = false
        }
        lock.unlock()
        return removed
    }

    func releaseCancellation(requestID: String, gate: AgentBackgroundTaskEventGate) {
        lock.lock()
        if cancellationGatesByRequestID[requestID] === gate {
            cancellationGatesByRequestID.removeValue(forKey: requestID)
        }
        lock.unlock()
    }

    func isCancelled(requestID: String, gate: AgentBackgroundTaskEventGate) -> Bool {
        lock.lock()
        let cancelled = cancellationGatesByRequestID[requestID] === gate
        lock.unlock()
        return cancelled
    }
}

@MainActor
public final class RemoteSSHAgentBackgroundCommandRunner: AgentBackgroundCommandRunning {
    fileprivate struct PendingTask {
        let sourceRuntimeID: String
        let sourceRuntimeGeneration: UInt64
        let sourceTitle: String
        let redactedCommand: String
        let gate: AgentBackgroundTaskEventGate
    }

    fileprivate struct ActiveTask {
        let runtimeID: String
        let sourceRuntimeID: String
        let sourceRuntimeGeneration: UInt64
        let sourceTitle: String
        let redactedCommand: String
        let gate: AgentBackgroundTaskEventGate
    }

    fileprivate struct CancelledTask {
        let runtimeID: String?
        let sourceRuntimeID: String
        let sourceRuntimeGeneration: UInt64
        let sourceTitle: String
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
        let eventGate = AgentBackgroundTaskEventGate()
        func emitEvent(
            _ state: AgentTraceState,
            _ message: String,
            _ request: AgentBackgroundCommandRequest,
            taskRuntimeID: String? = nil,
            terminalOutputSummary: String? = nil,
            terminalHistoryOutput: String? = nil,
            terminalOutputAudited: Bool = false,
            isTerminalEvent: Bool = false
        ) {
            guard isTerminalEvent
                ? eventGate.canEmitFinished()
                : eventGate.canEmitProgress()
            else { return }
            var metadata = [
                "executionMode": "backgroundTask",
                "sourceRuntimeID": request.targetRuntimeID,
                "sourceRuntimeGeneration": String(request.sourceRuntimeGeneration),
                "targetTitle": request.targetTitle
            ]
            if let taskRuntimeID {
                metadata["taskRuntimeID"] = taskRuntimeID
            }
            if let terminalOutputSummary,
               terminalOutputSummary.isEmpty == false {
                metadata["terminalOutputSummary"] = terminalOutputSummary
            }
            if terminalOutputAudited {
                metadata["terminalOutputAudited"] = "true"
            }
            if let terminalHistoryOutput,
               terminalHistoryOutput.isEmpty == false,
               terminalOutputAudited,
               request.actor.kind == .builtInAI {
                metadata["terminalHistoryOutput"] = terminalHistoryOutput
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
        guard activeTaskRegistry.prepare(
            PendingTask(
                sourceRuntimeID: request.targetRuntimeID,
                sourceRuntimeGeneration: request.sourceRuntimeGeneration,
                sourceTitle: request.targetTitle,
                redactedCommand: request.redactedCommand,
                gate: eventGate
            ),
            requestID: request.requestID
        ) else {
            throw AgentExecutionError.requestAlreadyActive
        }

        let runtimeBridge = AgentUncheckedSendable(value: runtimeBridge)
        let contextBox = AgentUncheckedSendable(value: context)
        let requestBox = AgentUncheckedSendable(value: request)
        let cols = cols
        let rows = rows
        let timeout = timeout
        let pollInterval = pollInterval
        let outputLimit = outputLimit
        let outputCaptureLimit = 256 * 1024
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
                        sourceRuntimeGeneration: request.sourceRuntimeGeneration,
                        sourceTitle: request.targetTitle,
                        redactedCommand: request.redactedCommand,
                        gate: eventGate
                    ),
                    requestID: request.requestID
                )
                guard didRegisterTask else {
                    try? runtimeBridge.value.closeTerminalRuntime(runtimeID: status.runtimeId)
                    if eventGate.waitForCancellationResolution() {
                        activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                    }
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
                    if activeTaskRegistry.isCancelled(requestID: request.requestID, gate: eventGate) {
                        activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                        return
                    }
                    let liveStatus = try runtimeBridge.value.pollLiveSSHShell(runtimeID: status.runtimeId)
                    let batch = try runtimeBridge.value.takeTerminalOutputBatch(runtimeID: status.runtimeId)
                    if activeTaskRegistry.isCancelled(requestID: request.requestID, gate: eventGate) {
                        activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                        return
                    }
                    if !batch.bytes.isEmpty {
                        Self.appendOutputBatch(
                            batch.bytes,
                            to: &output,
                            maximumByteCount: outputCaptureLimit
                        )
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
                if activeTaskRegistry.isCancelled(requestID: request.requestID, gate: eventGate) {
                    activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                    return
                }
                if let taskRuntimeID {
                    try? runtimeBridge.value.closeTerminalRuntime(runtimeID: taskRuntimeID)
                }
                let didClaimTerminalEvent = activeTaskRegistry.finish(
                    requestID: request.requestID,
                    runtimeID: taskRuntimeID
                )
                guard didClaimTerminalEvent else {
                    activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                    return
                }
                if didTimeout {
                    if activeTaskRegistry.isCancelled(requestID: request.requestID, gate: eventGate) {
                        activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                        return
                    }
                    Task { @MainActor in
                        emitEvent(
                            .failed,
                            "AI 独立任务失败：执行超时，请检查命令是否仍在运行。",
                            request,
                            taskRuntimeID: status.runtimeId,
                            isTerminalEvent: true
                        )
                    }
                    return
                }

                let summary = Self.outputSummary(from: output, limit: outputLimit)
                let historyOutput = Self.outputHistory(from: output, limit: 32_000)
                let message = summary.isEmpty
                    ? "AI 独立任务已完成。"
                    : "AI 独立任务已完成：\(summary)"
                if activeTaskRegistry.isCancelled(requestID: request.requestID, gate: eventGate) {
                    activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                    return
                }
                Task { @MainActor in
                    emitEvent(
                        .completed,
                        message,
                        request,
                        taskRuntimeID: status.runtimeId,
                        terminalOutputSummary: summary.isEmpty ? nil : summary,
                        terminalHistoryOutput: historyOutput.isEmpty ? nil : historyOutput,
                        terminalOutputAudited: true,
                        isTerminalEvent: true
                    )
                }
            } catch {
                if activeTaskRegistry.isCancelled(requestID: request.requestID, gate: eventGate) {
                    if let taskRuntimeID {
                        try? runtimeBridge.value.closeTerminalRuntime(runtimeID: taskRuntimeID)
                    }
                    activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                    return
                }
                if let taskRuntimeID {
                    try? runtimeBridge.value.closeTerminalRuntime(runtimeID: taskRuntimeID)
                }
                let didClaimTerminalEvent = activeTaskRegistry.finish(
                    requestID: request.requestID,
                    runtimeID: taskRuntimeID
                )
                guard didClaimTerminalEvent else {
                    activeTaskRegistry.releaseCancellation(requestID: request.requestID, gate: eventGate)
                    return
                }
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                let failedTaskRuntimeID = taskRuntimeID
                Task { @MainActor in
                    emitEvent(
                        .failed,
                        "AI 独立任务失败：\(message)",
                        request,
                        taskRuntimeID: failedTaskRuntimeID,
                        isTerminalEvent: true
                    )
                }
            }
        }
    }

    nonisolated private static func diagnosticMessage(forStatusDiagnostic diagnostic: String) -> String {
        let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "AI background runtime did not enter running state" : message
    }

    public func cancel(requestID: String) -> AgentTraceEvent? {
        guard let task = activeTaskRegistry.beginCancellation(requestID: requestID) else {
            return nil
        }
        if let runtimeID = task.runtimeID {
            do {
                try runtimeBridge.closeTerminalRuntime(runtimeID: runtimeID)
            } catch {
                activeTaskRegistry.rollbackCancellation(requestID: requestID, task: task)
                return AgentTraceEvent(
                    requestID: requestID,
                    state: .waitingForOutput,
                    message: "无法确认独立执行终端已关闭；任务仍可能运行，请重试取消。",
                    redactedCommand: task.redactedCommand,
                    metadata: [
                        "executionMode": "backgroundTask",
                        "sourceRuntimeID": task.sourceRuntimeID,
                        "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                        "targetTitle": task.sourceTitle,
                        "taskRuntimeID": runtimeID,
                        "control": "cancel",
                        "controlResult": "runtimeCloseFailed",
                        "taskStillRunning": "unknown"
                    ]
                )
            }
        }
        guard activeTaskRegistry.commitCancellation(requestID: requestID, task: task) else {
            activeTaskRegistry.rollbackCancellation(requestID: requestID, task: task)
            return AgentTraceEvent(
                requestID: requestID,
                state: .waitingForOutput,
                message: "无法确认独立任务取消状态；任务仍保留为活动状态。",
                redactedCommand: task.redactedCommand,
                metadata: [
                    "executionMode": "backgroundTask",
                    "sourceRuntimeID": task.sourceRuntimeID,
                    "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                    "targetTitle": task.sourceTitle,
                    "control": "cancel",
                    "controlResult": "stateRace",
                    "taskStillRunning": "unknown"
                ]
            )
        }
        var metadata = [
            "executionMode": "backgroundTask",
            "sourceRuntimeID": task.sourceRuntimeID,
            "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
            "targetTitle": task.sourceTitle,
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
        let normalized = normalizedOutput(from: data)
        guard normalized.isEmpty == false else {
            return ""
        }
        if normalized.count <= limit {
            return normalized
        }
        return "\(normalized.prefix(limit))..."
    }

    nonisolated private static func outputHistory(from data: Data, limit: Int) -> String {
        let normalized = normalizedOutput(from: data)
        guard normalized.isEmpty == false else { return "" }
        guard normalized.count > limit else { return normalized }
        let headCount = limit / 2
        let tailCount = limit - headCount
        return String(normalized.prefix(headCount))
            + "\n... 已省略部分终端输出 ...\n"
            + String(normalized.suffix(tailCount))
    }

    nonisolated private static func normalizedOutput(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .filter { isStacioBackgroundControlLine($0) == false }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentProtocolRedaction.redactPreservingLineBreaks(normalized)
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

    nonisolated private static func appendOutputBatch(
        _ batch: Data,
        to output: inout Data,
        maximumByteCount: Int
    ) {
        guard maximumByteCount > 0, batch.isEmpty == false else {
            return
        }
        if batch.count >= maximumByteCount {
            output = Data(batch.suffix(maximumByteCount))
            return
        }
        let overflow = output.count + batch.count - maximumByteCount
        if overflow > 0 {
            output.removeFirst(overflow)
        }
        output.append(batch)
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
public final class AgentExecutionCoordinator: AgentCommandAsyncStreamingExecuting {
    private static func completedOutputSummary(_ value: String) -> String {
        value.isEmpty ? "命令执行完成，未产生标准输出。" : value
    }

    private static let agentAuditRedactionVersion = "stacio.agent-redaction.v1"

    private struct TrackedTask {
        let target: AgentTerminalTarget
        let sourceRuntimeID: String
        let sourceRuntimeGeneration: UInt64
        let sourceTitle: String
        let redactedCommand: String
        let executionMode: String
        let actor: AgentActor
    }

    private struct AuditContext {
        let request: AgentBridgeRequest
        let target: AuditTarget
        let risk: AgentActionRisk
        let redactedInput: String
        let decision: AgentAuthorizationDecision
    }

    private struct AuditTarget {
        let runtimeID: String
        let title: String
        let automationPolicy: SessionAutomationPolicy
    }

    private struct BridgeFollowStream {
        let emit: @MainActor (AgentTraceEvent) -> Void
        let completion: @MainActor () -> Void
    }

    private struct CompletedRequestReplay {
        let fingerprint: String
        let terminalEvent: AgentTraceEvent
    }

    private struct VisibleRuntimeLease: Hashable {
        let runtimeID: String
        let generation: UInt64
    }

    private enum VisibleTerminalControlResolution {
        case current(AgentTerminalTarget)
        case leaseChanged(AgentTraceEvent)
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
    private let localAgentCapabilityRegistry: LocalAgentCapabilityRegistry
    private let backupLedger = AgentBackupLedger()
    private var backgroundTargetsByRequestID: [String: AgentTerminalTarget] = [:]
    private var trackedTasksByRequestID: [String: TrackedTask] = [:]
    private var auditContextsByRequestID: [String: AuditContext] = [:]
    private var bridgeFollowStreamsByRequestID: [String: BridgeFollowStream] = [:]
    private var dispatchingRequestIDs = Set<String>()
    private var dispatchingVisibleRuntimeLeases: [VisibleRuntimeLease: String] = [:]
    private var completedRequestReplaysByID: [String: CompletedRequestReplay] = [:]
    private var completedRequestReplayOrder: [String] = []

    private static let maximumCompletedRequestReplays = 256

    public init(
        terminalResolver: AgentTerminalResolving,
        authorizer: AgentActionAuthorizing,
        auditRecorder: AgentActionAuditRecording? = nil,
        sessionLister: AgentTerminalSessionListing? = nil,
        executionMode: AgentExecutionMode = .visibleTerminal,
        executionModeResolver: (() -> AgentExecutionMode)? = nil,
        backgroundCommandRunner: AgentBackgroundCommandRunning? = nil,
        visibleTerminalOutputHub: TerminalOutputBroadcastHub = .shared,
        visibleTerminalCompletion: AgentVisibleTerminalCompletion = AgentVisibleTerminalCompletion(),
        localAgentCapabilityRegistry: LocalAgentCapabilityRegistry = .shared
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
        self.localAgentCapabilityRegistry = localAgentCapabilityRegistry
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
        let requestFingerprint = Self.requestFingerprint(request)
        if let replay = completedRequestReplaysByID[request.id] {
            guard replay.fingerprint == requestFingerprint else {
                throw AgentExecutionError.requestAlreadyActive
            }
            externalEmit(replay.terminalEvent)
            return [replay.terminalEvent]
        }
        guard dispatchingRequestIDs.insert(request.id).inserted else {
            throw AgentExecutionError.requestAlreadyActive
        }
        defer { dispatchingRequestIDs.remove(request.id) }
        guard trackedTasksByRequestID[request.id] == nil else {
            throw AgentExecutionError.requestAlreadyActive
        }

        let target = try terminalResolver.resolveTerminalTarget(commandRequest.target)
        // Older Agent Bridge clients do not carry a generation field. Preserve
        // wire compatibility, but bind those requests to the concrete runtime
        // observed at ingress so an approval wait can never retarget the command
        // to a later connection that happens to reuse the same runtime ID.
        let initialRuntimeGeneration = target.agentRuntimeGeneration
        let initialRuntimeConnected = target.isAgentRuntimeConnected
        let sourceRuntimeID = target.runtimeID
        let sourceTitle = target.agentTitle
        let sourceAutomationPolicy = target.agentAutomationPolicy
        let sourceLiveSessionContext = target.agentLiveSessionContext
        let auditTarget = AuditTarget(
            runtimeID: sourceRuntimeID,
            title: sourceTitle,
            automationPolicy: sourceAutomationPolicy
        )
        let expectedRuntimeGeneration = commandRequest.expectedRuntimeGeneration
            ?? initialRuntimeGeneration
        let runtimeGenerationSource = commandRequest.expectedRuntimeGeneration == nil
            ? "coordinatorSnapshot"
            : "request"
        if let capabilityID = request.capabilityID,
           localAgentCapabilityRegistry.allows(
               capabilityID: capabilityID,
               runtimeID: sourceRuntimeID,
               runtimeGeneration: initialRuntimeGeneration
           ) == false {
            throw AgentExecutionError.capabilityRejected
        }
        let redactedCommand = AgentProtocolRedaction.redact(commandRequest.command)
        let mode = resolvedExecutionMode()
        let visibleRuntimeLease: VisibleRuntimeLease?
        switch mode {
        case .visibleTerminal:
            visibleRuntimeLease = VisibleRuntimeLease(
                runtimeID: sourceRuntimeID,
                generation: initialRuntimeGeneration
            )
        case .backgroundTask:
            visibleRuntimeLease = nil
        }
        if let visibleRuntimeLease {
            let hasTrackedWriter = trackedTasksByRequestID.values.contains { task in
                task.executionMode == "visibleTerminal"
                    && task.sourceRuntimeID == visibleRuntimeLease.runtimeID
                    && task.sourceRuntimeGeneration == visibleRuntimeLease.generation
            }
            guard hasTrackedWriter == false,
                  dispatchingVisibleRuntimeLeases[visibleRuntimeLease] == nil
            else {
                throw AgentExecutionError.requestAlreadyActive
            }
            dispatchingVisibleRuntimeLeases[visibleRuntimeLease] = request.id
        }
        defer {
            if let visibleRuntimeLease,
               dispatchingVisibleRuntimeLeases[visibleRuntimeLease] == request.id {
                dispatchingVisibleRuntimeLeases.removeValue(forKey: visibleRuntimeLease)
            }
        }
        var events: [AgentTraceEvent] = []
        defer {
            backupLedger.record(
                command: commandRequest.command,
                runtimeID: sourceRuntimeID,
                generation: expectedRuntimeGeneration,
                events: events
            )
        }

        func traceMetadata(
            extra: [String: String]? = nil,
            decision: AgentAuthorizationDecision? = nil
        ) -> [String: String] {
            var metadata: [String: String] = [
                "executionMode": traceValue(for: mode),
                "sourceRuntimeID": sourceRuntimeID,
                "sourceRuntimeGeneration": String(expectedRuntimeGeneration),
                "targetTitle": sourceTitle,
                "environment": sourceAutomationPolicy.environment,
                "aiExecutionPolicy": sourceAutomationPolicy.aiExecutionPolicy
            ]
            if let decision {
                metadata["policyDecision"] = policyDecisionValue(for: decision)
                metadata["risk"] = decision.risk.rawValue
            }
            if let extra {
                metadata.merge(extra) { _, new in new }
            }
            metadata["sourceRuntimeID"] = sourceRuntimeID
            metadata["sourceRuntimeGeneration"] = String(expectedRuntimeGeneration)
            metadata["targetTitle"] = sourceTitle
            metadata["environment"] = sourceAutomationPolicy.environment
            metadata["aiExecutionPolicy"] = sourceAutomationPolicy.aiExecutionPolicy
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
            let retainedEvent = event.removingTransientTerminalHistoryOutput()
            events.append(retainedEvent)
            target.appendAgentTrace(event)
            // `terminalHistoryOutput` is already redacted and is needed by the
            // in-process V2 Bridge to continue the same model turn. Keep it
            // inside that trusted boundary, while external actors receive the
            // short summary only. The returned event list remains
            // summary-only; the Bridge decides how the redacted result is
            // recorded in the conversation evidence.
            if request.actor.kind == .builtInAI {
                externalEmit(event)
            } else {
                externalEmit(retainedEvent)
            }
            rememberCompletedRequestIfNeeded(event, fingerprint: requestFingerprint)
        }
        emit(.queued, "\(request.actor.name) 已请求操作 \(sourceTitle)")
        let willRequireUserConfirmation = authorizer.requiresUserConfirmation(
            actor: request.actor,
            command: commandRequest.command,
            targetTitle: sourceTitle,
            automationPolicy: sourceAutomationPolicy,
            approvalEvidence: commandRequest.approvalEvidence
        )
        if willRequireUserConfirmation {
            emit(.awaitingApproval, "等待 Stacio 确认")
        }
        let decision = try authorizer.authorize(
            actor: request.actor,
            command: commandRequest.command,
            targetTitle: sourceTitle,
            automationPolicy: sourceAutomationPolicy,
            approvalEvidence: commandRequest.approvalEvidence
        )
        var didRecordRunningAudit = false
        func recordRunningAuditIfNeeded() {
            guard didRecordRunningAudit == false else { return }
            didRecordRunningAudit = true
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .running,
                redactedInput: redactedCommand,
                decision: decision
            )
        }
        if decision.requiredUserConfirmation
            && willRequireUserConfirmation == false
            && commandRequest.approvalEvidence == nil {
            emit(.awaitingApproval, "等待 Stacio 确认")
        }
        guard decision.allowed else {
            emit(.cancelled, "操作已取消", decision: decision)
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .cancelled,
                redactedInput: redactedCommand,
                decision: decision
            )
            throw AgentExecutionError.denied(decision.reason)
        }
        guard backupLedger.allows(
            command: commandRequest.command,
            runtimeID: sourceRuntimeID,
            generation: expectedRuntimeGeneration
        ) else {
            let reason = "安全门禁：配置或服务变更前必须先完成备份。请先执行备份命令，并确认终端输出包含备份路径后再重试。"
            emit(.cancelled, reason, decision: decision)
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .cancelled,
                redactedInput: redactedCommand,
                decision: decision
            )
            throw AgentExecutionError.denied(reason)
        }

        func capabilityIsCurrent() -> Bool {
            guard let capabilityID = request.capabilityID else { return true }
            return localAgentCapabilityRegistry.allows(
                capabilityID: capabilityID,
                runtimeID: sourceRuntimeID,
                runtimeGeneration: expectedRuntimeGeneration
            )
        }

        func resolvedCurrentTarget() -> AgentTerminalTarget? {
            try? terminalResolver.resolveTerminalTarget(.runtimeID(sourceRuntimeID))
        }

        func runtimeLeaseIsCurrent() -> Bool {
            guard capabilityIsCurrent(),
                  initialRuntimeConnected,
                  initialRuntimeGeneration == expectedRuntimeGeneration,
                  let currentTarget = resolvedCurrentTarget(),
                  currentTarget === target,
                  currentTarget.runtimeID == sourceRuntimeID,
                  currentTarget.isAgentRuntimeConnected,
                  currentTarget.agentRuntimeGeneration == expectedRuntimeGeneration
            else { return false }
            return true
        }

        func ensureRuntimeLease(forceFailure: Bool = false) throws {
            guard capabilityIsCurrent() else {
                emit(
                    .failed,
                    AgentExecutionError.capabilityRejected.localizedDescription,
                    metadata: [
                        "expectedRuntimeGeneration": String(expectedRuntimeGeneration),
                        "runtimeGenerationSource": runtimeGenerationSource,
                        "authorityState": "revokedExpiredOrProcessExited"
                    ],
                    decision: decision
                )
                recordAuditEvent(
                    request: request,
                    target: auditTarget,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                auditContextsByRequestID.removeValue(forKey: request.id)
                throw AgentExecutionError.capabilityRejected
            }

            let currentTarget = resolvedCurrentTarget()
            let leaseChanged = forceFailure
                || initialRuntimeConnected == false
                || initialRuntimeGeneration != expectedRuntimeGeneration
                || currentTarget == nil
                || currentTarget.map({ $0 === target }) != true
                || currentTarget?.runtimeID != sourceRuntimeID
                || currentTarget?.isAgentRuntimeConnected != true
                || currentTarget?.agentRuntimeGeneration != expectedRuntimeGeneration
            if leaseChanged {
                emit(
                    .failed,
                    AgentExecutionError.terminalRuntimeLeaseChanged.localizedDescription,
                    metadata: [
                        "expectedRuntimeGeneration": String(expectedRuntimeGeneration),
                        "initialRuntimeGeneration": String(initialRuntimeGeneration),
                        "actualRuntimeGeneration": currentTarget
                            .map { String($0.agentRuntimeGeneration) }
                            ?? "unavailable",
                        "runtimeConnected": currentTarget?.isAgentRuntimeConnected == true
                            ? "true"
                            : "false",
                        "runtimeGenerationSource": runtimeGenerationSource
                    ],
                    decision: decision
                )
                recordAuditEvent(
                    request: request,
                    target: auditTarget,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                auditContextsByRequestID.removeValue(forKey: request.id)
                throw AgentExecutionError.terminalRuntimeLeaseChanged
            }
        }
        try ensureRuntimeLease()

        if decision.requiredUserConfirmation {
            emit(.approved, "已确认，准备写入终端", decision: decision)
        } else {
            emit(.approved, "已按全局策略自动放行", decision: decision)
        }
        auditContextsByRequestID[request.id] = AuditContext(
            request: request,
            target: auditTarget,
            risk: decision.risk,
            redactedInput: redactedCommand,
            decision: decision
        )
        switch mode {
        case .visibleTerminal:
            trackedTasksByRequestID[request.id] = TrackedTask(
                target: target,
                sourceRuntimeID: sourceRuntimeID,
                sourceRuntimeGeneration: expectedRuntimeGeneration,
                sourceTitle: sourceTitle,
                redactedCommand: redactedCommand,
                executionMode: "visibleTerminal",
                actor: request.actor
            )
            target.setAgentInteractionLocked(true)
            emit(.typing, "正在写入终端", decision: decision)
            let isInteractiveConfirmationReply = Self.isInteractiveConfirmationReply(
                commandRequest.command,
                terminalText: [
                    target.agentTerminalOutputTranscript,
                    target.agentTerminalDisplaySnapshot
                ].joined(separator: "\n")
            )
            let usesCompletionMarker = target.supportsAgentCompletionMarker
                && isInteractiveConfirmationReply == false
            let visibleObservation = VisibleTerminalObservationSession(
                requestID: request.id,
                runtimeID: sourceRuntimeID,
                command: commandRequest.command,
                redactedCommand: redactedCommand,
                outputHub: visibleTerminalOutputHub,
                completion: visibleTerminalCompletion,
                commandCompletionGeneration: { target.agentCommandCompletionGeneration },
                terminalOutputTranscript: { target.agentTerminalOutputTranscript },
                terminalDisplaySnapshot: { target.agentTerminalDisplaySnapshot },
                refreshTerminalOutput: { target.refreshAgentTerminalOutput() },
                isAwaitingSensitiveInput: { target.isAwaitingSensitiveInput },
                isRuntimeLeaseCurrent: runtimeLeaseIsCurrent,
                completionMarker: usesCompletionMarker
                    ? Self.agentCompletionMarker(requestID: request.id)
                    : nil,
                onOutputUpdate: { update in
                    emit(
                        .waitingForOutput,
                        "终端输出更新：\(update.summary)",
                        metadata: [
                            "terminalOutputSummary": update.summary,
                            "completionConfidence": "streaming",
                            "sensitiveInputRequired": update.sensitiveInputRequired ? "true" : "false"
                        ],
                        decision: decision
                    )
                }
            )
            visibleObservation.begin()
            visibleObservation.markCommandWriteStarted()
            let terminalCommand = usesCompletionMarker
                ? Self.commandWithCompletionMarker(commandRequest.command, requestID: request.id)
                : commandRequest.command
            do {
                try ensureRuntimeLease()
            } catch {
                visibleObservation.cancelBeforeCommandWrite()
                trackedTasksByRequestID.removeValue(forKey: request.id)
                unlockVisibleTerminalIfUnowned(target)
                throw error
            }
            guard target.sendAgentInput(Array((terminalCommand + "\n").utf8)) else {
                visibleObservation.cancelBeforeCommandWrite()
                trackedTasksByRequestID.removeValue(forKey: request.id)
                unlockVisibleTerminalIfUnowned(target)
                emit(
                    .failed,
                    AgentExecutionError.terminalInputRejected.localizedDescription,
                    metadata: ["writeAccepted": "false"],
                    decision: decision
                )
                recordAuditEvent(
                    request: request,
                    target: auditTarget,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                auditContextsByRequestID.removeValue(forKey: request.id)
                throw AgentExecutionError.terminalInputRejected
            }
            emit(
                .running,
                "命令已在终端执行，输出将实时显示",
                metadata: ["writeAccepted": "true"],
                decision: decision
            )
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
            case .runtimeLeaseChanged:
                trackedTasksByRequestID.removeValue(forKey: request.id)
                unlockVisibleTerminalIfUnowned(target)
                try ensureRuntimeLease(forceFailure: true)
            case .completed:
                let completedSummary = Self.completedOutputSummary(observation.summary)
                let completionConfidence: String
                switch observation.reason {
                case "auditEndMarker", "agentCompletionMarker":
                    completionConfidence = "explicitMarker"
                case "shellPromptObserved":
                    completionConfidence = "observedPrompt"
                default:
                    completionConfidence = "observedIdle"
                }
                let outputAudited = completionConfidence == "explicitMarker"
                    || completionConfidence == "observedPrompt"
                var completionMetadata = [
                    "terminalOutputSummary": completedSummary,
                    "completionConfidence": completionConfidence,
                    "completionReason": observation.reason
                ]
                if outputAudited {
                    completionMetadata["terminalOutputAudited"] = "true"
                    if request.actor.kind == .builtInAI {
                        let historyOutput = visibleObservation.redactedHistoryOutput
                        if historyOutput.isEmpty == false {
                            completionMetadata["terminalHistoryOutput"] = historyOutput
                        }
                    }
                }
                emit(
                    .completed,
                    "本次命令已完成：\(completedSummary)",
                    metadata: completionMetadata,
                    decision: decision
                )
                trackedTasksByRequestID.removeValue(forKey: request.id)
                unlockVisibleTerminalIfUnowned(target)
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
            guard sourceLiveSessionContext != nil else {
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
                    target: auditTarget,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                auditContextsByRequestID.removeValue(forKey: request.id)
                break
            }
            backgroundTargetsByRequestID[request.id] = target
            trackedTasksByRequestID[request.id] = TrackedTask(
                target: target,
                sourceRuntimeID: sourceRuntimeID,
                sourceRuntimeGeneration: expectedRuntimeGeneration,
                sourceTitle: sourceTitle,
                redactedCommand: redactedCommand,
                executionMode: "backgroundTask",
                actor: request.actor
            )
            do {
                try ensureRuntimeLease()
            } catch {
                trackedTasksByRequestID.removeValue(forKey: request.id)
                backgroundTargetsByRequestID.removeValue(forKey: request.id)
                throw error
            }
            guard let liveSessionContext = sourceLiveSessionContext else {
                trackedTasksByRequestID.removeValue(forKey: request.id)
                backgroundTargetsByRequestID.removeValue(forKey: request.id)
                emit(
                    .failed,
                    "AI 独立任务失败：\(AgentExecutionError.backgroundTaskUnavailable.localizedDescription)",
                    metadata: ["fallbackReason": "backgroundTaskUnavailable"],
                    decision: decision
                )
                recordAuditEvent(
                    request: request,
                    target: auditTarget,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                auditContextsByRequestID.removeValue(forKey: request.id)
                break
            }
            var didReceiveBackgroundTerminalEvent = false
            func publishBackgroundEvent(_ event: AgentTraceEvent) {
                guard didReceiveBackgroundTerminalEvent == false else { return }
                let contextualEvent = AgentTraceEvent(
                    requestID: event.requestID,
                    state: event.state,
                    message: event.message,
                    redactedCommand: event.redactedCommand,
                    metadata: traceMetadata(extra: event.metadata, decision: decision)
                )
                target.appendAgentTrace(contextualEvent)
                externalEmit(contextualEvent.removingTransientTerminalHistoryOutput())
                self.rememberCompletedRequestIfNeeded(
                    contextualEvent,
                    fingerprint: requestFingerprint
                )
                self.recordAuditTerminalStateIfNeeded(contextualEvent)
                self.backupLedger.record(
                    command: commandRequest.command,
                    runtimeID: sourceRuntimeID,
                    generation: expectedRuntimeGeneration,
                    events: [contextualEvent]
                )
                if Self.shouldRemoveTrackedTask(for: contextualEvent.state) {
                    didReceiveBackgroundTerminalEvent = true
                    self.trackedTasksByRequestID.removeValue(forKey: contextualEvent.requestID)
                    self.backgroundTargetsByRequestID.removeValue(forKey: contextualEvent.requestID)
                }
            }
            var launchAccepted = false
            var deferredEvents: [AgentTraceEvent] = []
            do {
                try backgroundCommandRunner.runBackgroundCommand(
                    AgentBackgroundCommandRequest(
                        requestID: request.id,
                        command: commandRequest.command,
                        targetRuntimeID: sourceRuntimeID,
                        sourceRuntimeGeneration: expectedRuntimeGeneration,
                        targetTitle: sourceTitle,
                        actor: request.actor,
                        redactedCommand: redactedCommand,
                        liveSessionContext: liveSessionContext
                    ),
                    emit: { event in
                        if launchAccepted {
                            publishBackgroundEvent(event)
                        } else {
                            deferredEvents.append(event)
                        }
                    }
                )
            } catch {
                trackedTasksByRequestID.removeValue(forKey: request.id)
                backgroundTargetsByRequestID.removeValue(forKey: request.id)
                emit(
                    .failed,
                    "AI 独立任务启动失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))",
                    decision: decision
                )
                recordAuditEvent(
                    request: request,
                    target: auditTarget,
                    risk: decision.risk,
                    state: .failed,
                    redactedInput: redactedCommand,
                    decision: decision
                )
                auditContextsByRequestID.removeValue(forKey: request.id)
                throw error
            }
            emit(
                .running,
                "独立任务已启动，输出将同步显示",
                decision: decision
            )
            recordRunningAuditIfNeeded()
            launchAccepted = true
            deferredEvents.forEach(publishBackgroundEvent)
        }
        if events.last?.state != .failed {
            recordRunningAuditIfNeeded()
        }
        return events
    }

    public func runCommandAsync(
        _ request: AgentBridgeRequest,
        emit externalEmit: @escaping (AgentTraceEvent) -> Void
    ) async throws -> [AgentTraceEvent] {
        guard case .runCommand(let commandRequest) = request.action else {
            throw AgentExecutionError.unsupportedAction
        }
        guard resolvedExecutionMode() == .visibleTerminal else {
            return try runCommand(request, emit: externalEmit)
        }

        let requestFingerprint = Self.requestFingerprint(request)
        if let replay = completedRequestReplaysByID[request.id] {
            guard replay.fingerprint == requestFingerprint else {
                throw AgentExecutionError.requestAlreadyActive
            }
            externalEmit(replay.terminalEvent)
            return [replay.terminalEvent]
        }
        guard dispatchingRequestIDs.insert(request.id).inserted else {
            throw AgentExecutionError.requestAlreadyActive
        }
        defer { dispatchingRequestIDs.remove(request.id) }
        guard trackedTasksByRequestID[request.id] == nil else {
            throw AgentExecutionError.requestAlreadyActive
        }

        let target = try terminalResolver.resolveTerminalTarget(commandRequest.target)
        let initialRuntimeGeneration = target.agentRuntimeGeneration
        let initialRuntimeConnected = target.isAgentRuntimeConnected
        let sourceRuntimeID = target.runtimeID
        let sourceTitle = target.agentTitle
        let sourceAutomationPolicy = target.agentAutomationPolicy
        let auditTarget = AuditTarget(
            runtimeID: sourceRuntimeID,
            title: sourceTitle,
            automationPolicy: sourceAutomationPolicy
        )
        let expectedRuntimeGeneration = commandRequest.expectedRuntimeGeneration
            ?? initialRuntimeGeneration
        let runtimeGenerationSource = commandRequest.expectedRuntimeGeneration == nil
            ? "coordinatorSnapshot"
            : "request"
        if let capabilityID = request.capabilityID,
           localAgentCapabilityRegistry.allows(
               capabilityID: capabilityID,
               runtimeID: sourceRuntimeID,
               runtimeGeneration: initialRuntimeGeneration
           ) == false {
            throw AgentExecutionError.capabilityRejected
        }
        let redactedCommand = AgentProtocolRedaction.redact(commandRequest.command)
        let visibleRuntimeLease = VisibleRuntimeLease(
            runtimeID: sourceRuntimeID,
            generation: initialRuntimeGeneration
        )
        let hasTrackedWriter = trackedTasksByRequestID.values.contains { task in
            task.executionMode == "visibleTerminal"
                && task.sourceRuntimeID == visibleRuntimeLease.runtimeID
                && task.sourceRuntimeGeneration == visibleRuntimeLease.generation
        }
        guard hasTrackedWriter == false,
              dispatchingVisibleRuntimeLeases[visibleRuntimeLease] == nil
        else {
            throw AgentExecutionError.requestAlreadyActive
        }
        dispatchingVisibleRuntimeLeases[visibleRuntimeLease] = request.id
        defer {
            if dispatchingVisibleRuntimeLeases[visibleRuntimeLease] == request.id {
                dispatchingVisibleRuntimeLeases.removeValue(forKey: visibleRuntimeLease)
            }
        }

        var events: [AgentTraceEvent] = []
        defer {
            backupLedger.record(
                command: commandRequest.command,
                runtimeID: sourceRuntimeID,
                generation: expectedRuntimeGeneration,
                events: events
            )
        }
        func traceMetadata(
            extra: [String: String]? = nil,
            decision: AgentAuthorizationDecision? = nil
        ) -> [String: String] {
            var metadata: [String: String] = [
                "executionMode": "visibleTerminal",
                "sourceRuntimeID": sourceRuntimeID,
                "sourceRuntimeGeneration": String(expectedRuntimeGeneration),
                "targetTitle": sourceTitle,
                "environment": sourceAutomationPolicy.environment,
                "aiExecutionPolicy": sourceAutomationPolicy.aiExecutionPolicy,
                "actorKind": request.actor.kind.rawValue,
                "actorName": request.actor.name
            ]
            if let decision {
                metadata["policyDecision"] = policyDecisionValue(for: decision)
                metadata["risk"] = decision.risk.rawValue
            }
            if let extra {
                metadata.merge(extra) { _, new in new }
            }
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
            let retainedEvent = event.removingTransientTerminalHistoryOutput()
            events.append(retainedEvent)
            target.appendAgentTrace(event)
            if request.actor.kind == .builtInAI {
                externalEmit(event)
            } else {
                externalEmit(retainedEvent)
            }
            rememberCompletedRequestIfNeeded(event, fingerprint: requestFingerprint)
        }

        emit(.queued, "\(request.actor.name) 已请求操作 \(sourceTitle)")
        let willRequireUserConfirmation = authorizer.requiresUserConfirmation(
            actor: request.actor,
            command: commandRequest.command,
            targetTitle: sourceTitle,
            automationPolicy: sourceAutomationPolicy,
            approvalEvidence: commandRequest.approvalEvidence
        )
        if willRequireUserConfirmation {
            emit(.awaitingApproval, "等待 Stacio 确认")
        }
        let decision = try authorizer.authorize(
            actor: request.actor,
            command: commandRequest.command,
            targetTitle: sourceTitle,
            automationPolicy: sourceAutomationPolicy,
            approvalEvidence: commandRequest.approvalEvidence
        )
        if decision.requiredUserConfirmation
            && willRequireUserConfirmation == false
            && commandRequest.approvalEvidence == nil {
            emit(.awaitingApproval, "等待 Stacio 确认")
        }
        guard decision.allowed else {
            emit(.cancelled, "操作已取消", decision: decision)
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .cancelled,
                redactedInput: redactedCommand,
                decision: decision
            )
            throw AgentExecutionError.denied(decision.reason)
        }
        guard backupLedger.allows(
            command: commandRequest.command,
            runtimeID: sourceRuntimeID,
            generation: expectedRuntimeGeneration
        ) else {
            let reason = "安全门禁：配置或服务变更前必须先完成备份。请先执行备份命令，并确认终端输出包含备份路径后再重试。"
            emit(.cancelled, reason, decision: decision)
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .cancelled,
                redactedInput: redactedCommand,
                decision: decision
            )
            throw AgentExecutionError.denied(reason)
        }

        func capabilityIsCurrent() -> Bool {
            guard let capabilityID = request.capabilityID else { return true }
            return localAgentCapabilityRegistry.allows(
                capabilityID: capabilityID,
                runtimeID: sourceRuntimeID,
                runtimeGeneration: expectedRuntimeGeneration
            )
        }
        func resolvedCurrentTarget() -> AgentTerminalTarget? {
            try? terminalResolver.resolveTerminalTarget(.runtimeID(sourceRuntimeID))
        }
        func runtimeLeaseIsCurrent() -> Bool {
            guard capabilityIsCurrent(),
                  initialRuntimeConnected,
                  initialRuntimeGeneration == expectedRuntimeGeneration,
                  let currentTarget = resolvedCurrentTarget(),
                  currentTarget === target,
                  currentTarget.runtimeID == sourceRuntimeID,
                  currentTarget.isAgentRuntimeConnected,
                  currentTarget.agentRuntimeGeneration == expectedRuntimeGeneration
            else { return false }
            return true
        }
        func failRuntimeLease(_ error: AgentExecutionError) throws {
            emit(
                .failed,
                error.localizedDescription,
                metadata: [
                    "expectedRuntimeGeneration": String(expectedRuntimeGeneration),
                    "initialRuntimeGeneration": String(initialRuntimeGeneration),
                    "actualRuntimeGeneration": resolvedCurrentTarget()
                        .map { String($0.agentRuntimeGeneration) } ?? "unavailable",
                    "runtimeGenerationSource": runtimeGenerationSource
                ],
                decision: decision
            )
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .failed,
                redactedInput: redactedCommand,
                decision: decision
            )
            auditContextsByRequestID.removeValue(forKey: request.id)
            throw error
        }
        guard capabilityIsCurrent() else {
            try failRuntimeLease(.capabilityRejected)
            return events
        }
        guard runtimeLeaseIsCurrent() else {
            try failRuntimeLease(.terminalRuntimeLeaseChanged)
            return events
        }

        emit(
            .approved,
            decision.requiredUserConfirmation ? "已确认，准备写入终端" : "已按全局策略自动放行",
            decision: decision
        )
        auditContextsByRequestID[request.id] = AuditContext(
            request: request,
            target: auditTarget,
            risk: decision.risk,
            redactedInput: redactedCommand,
            decision: decision
        )
        trackedTasksByRequestID[request.id] = TrackedTask(
            target: target,
            sourceRuntimeID: sourceRuntimeID,
            sourceRuntimeGeneration: expectedRuntimeGeneration,
            sourceTitle: sourceTitle,
            redactedCommand: redactedCommand,
            executionMode: "visibleTerminal",
            actor: request.actor
        )
        target.setAgentInteractionLocked(true)
        emit(.typing, "正在写入终端", decision: decision)

        let isInteractiveConfirmationReply = Self.isInteractiveConfirmationReply(
            commandRequest.command,
            terminalText: [
                target.agentTerminalOutputTranscript,
                target.agentTerminalDisplaySnapshot
            ].joined(separator: "\n")
        )
        let usesCompletionMarker = target.supportsAgentCompletionMarker
            && isInteractiveConfirmationReply == false
        let visibleObservation = VisibleTerminalObservationSession(
            requestID: request.id,
            runtimeID: sourceRuntimeID,
            command: commandRequest.command,
            redactedCommand: redactedCommand,
            outputHub: visibleTerminalOutputHub,
            completion: visibleTerminalCompletion,
            commandCompletionGeneration: { target.agentCommandCompletionGeneration },
            terminalOutputTranscript: { target.agentTerminalOutputTranscript },
            terminalDisplaySnapshot: { target.agentTerminalDisplaySnapshot },
            refreshTerminalOutput: { target.refreshAgentTerminalOutput() },
            isAwaitingSensitiveInput: { target.isAwaitingSensitiveInput },
            isRuntimeLeaseCurrent: runtimeLeaseIsCurrent,
            completionMarker: usesCompletionMarker
                ? Self.agentCompletionMarker(requestID: request.id)
                : nil,
            onOutputUpdate: { update in
                emit(
                    .waitingForOutput,
                    "终端输出更新：\(update.summary)",
                    metadata: [
                        "terminalOutputSummary": update.summary,
                        "completionConfidence": "streaming",
                        "sensitiveInputRequired": update.sensitiveInputRequired ? "true" : "false"
                    ],
                    decision: decision
                )
            }
        )
        visibleObservation.begin()
        visibleObservation.markCommandWriteStarted()
        let terminalCommand = usesCompletionMarker
            ? Self.commandWithCompletionMarker(commandRequest.command, requestID: request.id)
            : commandRequest.command
        guard runtimeLeaseIsCurrent() else {
            visibleObservation.cancelBeforeCommandWrite()
            trackedTasksByRequestID.removeValue(forKey: request.id)
            unlockVisibleTerminalIfUnowned(target)
            try failRuntimeLease(.terminalRuntimeLeaseChanged)
            return events
        }
        guard target.sendAgentInput(Array((terminalCommand + "\n").utf8)) else {
            visibleObservation.cancelBeforeCommandWrite()
            trackedTasksByRequestID.removeValue(forKey: request.id)
            unlockVisibleTerminalIfUnowned(target)
            emit(
                .failed,
                AgentExecutionError.terminalInputRejected.localizedDescription,
                metadata: ["writeAccepted": "false"],
                decision: decision
            )
            recordAuditEvent(
                request: request,
                target: auditTarget,
                risk: decision.risk,
                state: .failed,
                redactedInput: redactedCommand,
                decision: decision
            )
            auditContextsByRequestID.removeValue(forKey: request.id)
            throw AgentExecutionError.terminalInputRejected
        }
        emit(
            .running,
            "命令已在终端执行，输出将实时显示",
            metadata: ["writeAccepted": "true"],
            decision: decision
        )
        recordAuditEvent(
            request: request,
            target: auditTarget,
            risk: decision.risk,
            state: .running,
            redactedInput: redactedCommand,
            decision: decision
        )

        let initialObservation = await visibleObservation.waitAsync()
        let observation = initialObservation.outcome == .manualRequired
            ? (visibleObservation.completedResultFromTranscriptIfPromptPresent() ?? initialObservation)
            : initialObservation
        StacioLogStore.shared.append(
            level: observation.outcome == .completed ? .info : .warning,
            category: "Agent",
            message: "agent.visible.observation outcome=\(observation.outcome) reason=\(observation.reason) \(visibleObservation.diagnosticDescription)"
        )
        switch observation.outcome {
        case .runtimeLeaseChanged:
            trackedTasksByRequestID.removeValue(forKey: request.id)
            unlockVisibleTerminalIfUnowned(target)
            try failRuntimeLease(.terminalRuntimeLeaseChanged)
        case .completed:
            let completedSummary = Self.completedOutputSummary(observation.summary)
            let completionConfidence: String
            switch observation.reason {
            case "auditEndMarker", "agentCompletionMarker":
                completionConfidence = "explicitMarker"
            case "shellPromptObserved":
                completionConfidence = "observedPrompt"
            default:
                completionConfidence = "observedIdle"
            }
            let outputAudited = completionConfidence == "explicitMarker"
                || completionConfidence == "observedPrompt"
            var completionMetadata = [
                "terminalOutputSummary": completedSummary,
                "completionConfidence": completionConfidence,
                "completionReason": observation.reason
            ]
            if outputAudited {
                completionMetadata["terminalOutputAudited"] = "true"
                if request.actor.kind == .builtInAI {
                    let historyOutput = visibleObservation.redactedHistoryOutput
                    if historyOutput.isEmpty == false {
                        completionMetadata["terminalHistoryOutput"] = historyOutput
                    }
                }
            }
            emit(
                .completed,
                "本次命令已完成：\(completedSummary)",
                metadata: completionMetadata,
                decision: decision
            )
            trackedTasksByRequestID.removeValue(forKey: request.id)
            unlockVisibleTerminalIfUnowned(target)
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
        return events
    }

    private static func agentCompletionMarker(requestID: String) -> [UInt8] {
        Array("\u{001B}]777;stacio-agent-done=\(sanitizedMarkerID(requestID))\u{0007}".utf8)
    }

    private static func commandWithCompletionMarker(_ command: String, requestID: String) -> String {
        let markerID = sanitizedMarkerID(requestID)
        return "{ \(command)\n}; printf '\\033]777;stacio-agent-done=\(markerID)\\007'"
    }

    private static func isInteractiveConfirmationReply(_ command: String, terminalText: String) -> Bool {
        let reply = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["y", "n", "yes", "no"].contains(reply) else { return false }

        let recentLines = terminalText
            .lowercased()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(6)
            .joined(separator: "\n")
        let tail = String(recentLines.suffix(1_024))
        let explicitOptionMarkers = [
            "[y/n]",
            "(y/n)",
            "[yes/no]",
            "(yes/no)",
            "[y/yes/n/no]",
            "(y/yes/n/no)"
        ]
        if explicitOptionMarkers.contains(where: tail.contains) {
            return true
        }

        let namesBothReplies = (tail.contains("'y'") || tail.contains("\"y\""))
            && (tail.contains("'n'") || tail.contains("\"n\""))
        let describesConfirmation = tail.contains("proceed")
            || tail.contains("continue")
            || tail.contains("confirm")
            || tail.contains("abort")
        return namesBothReplies && describesConfirmation
    }

    private static func sanitizedMarkerID(_ requestID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(requestID.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
    }

    public func pauseTask(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID[requestID] else {
            return nil
        }
        if task.executionMode == "backgroundTask" {
            let event = AgentTraceEvent(
                requestID: requestID,
                state: .waitingForOutput,
                message: "独立任务不支持暂停；任务仍在运行，请使用取消或人工接管。",
                redactedCommand: task.redactedCommand,
                metadata: [
                    "executionMode": task.executionMode,
                    "sourceRuntimeID": task.sourceRuntimeID,
                    "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                    "targetTitle": task.sourceTitle,
                    "actorKind": task.actor.kind.rawValue,
                    "actorName": task.actor.name,
                    "control": "pause",
                    "controlResult": "unsupported",
                    "taskStillRunning": "true"
                ]
            )
            task.target.appendAgentTrace(event)
            return event
        }
        trackedTasksByRequestID.removeValue(forKey: requestID)
        releaseVisibleTerminalOwnership(
            on: task.target,
            runtimeID: task.sourceRuntimeID,
            generation: task.sourceRuntimeGeneration,
            excluding: requestID,
            state: .paused,
            message: "同一终端上的旧 AI 任务已随本次暂停一并释放。"
        )
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let traceTarget: AgentTerminalTarget
        if task.executionMode == "visibleTerminal" {
            switch resolveVisibleTerminalControl(
                requestID: requestID,
                task: task,
                control: "pause",
                failureMessage: "目标终端已断开或重连，无法确认原任务已暂停；请核对原任务状态。"
            ) {
            case .current(let target):
                traceTarget = target
            case .leaseChanged(let event):
                return event
            }
        } else {
            traceTarget = task.target
        }
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .paused,
            message: "AI 后续自动动作已暂停；当前命令仍以目标终端输出为准。",
            redactedCommand: task.redactedCommand,
            metadata: [
                "executionMode": task.executionMode,
                "sourceRuntimeID": task.sourceRuntimeID,
                "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                "targetTitle": task.sourceTitle,
                "actorKind": task.actor.kind.rawValue,
                "actorName": task.actor.name,
                "control": "pause"
            ]
        )
        traceTarget.appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: event)
        return event
    }

    public func cancelTask(requestID: String) -> AgentTraceEvent? {
        if let task = trackedTasksByRequestID[requestID],
           task.executionMode == "visibleTerminal" {
            trackedTasksByRequestID.removeValue(forKey: requestID)
            backgroundTargetsByRequestID.removeValue(forKey: requestID)
            releaseVisibleTerminalOwnership(
                on: task.target,
                runtimeID: task.sourceRuntimeID,
                generation: task.sourceRuntimeGeneration,
                excluding: requestID,
                state: .cancelled,
                message: "同一终端上的旧 AI 任务已随本次取消一并释放。"
            )
            let currentTarget: AgentTerminalTarget
            switch resolveVisibleTerminalControl(
                requestID: requestID,
                task: task,
                control: "cancel",
                failureMessage: "目标终端已断开或重连，未向当前连接发送中断；请核对原任务状态。"
            ) {
            case .current(let target):
                currentTarget = target
            case .leaseChanged(let event):
                return event
            }
            if currentTarget.isSensitiveInputProtectionActive {
                _ = currentTarget.sendSensitiveUserInput([3])
            } else {
                currentTarget.sendInput([3])
            }
            let event = AgentTraceEvent(
                requestID: requestID,
                state: .cancelled,
                message: "已向可见终端发送中断；输出仍以目标终端为准。",
                redactedCommand: task.redactedCommand,
                metadata: [
                    "executionMode": task.executionMode,
                    "sourceRuntimeID": task.sourceRuntimeID,
                    "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                    "targetTitle": task.sourceTitle,
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
        var metadata = event.metadata ?? [:]
        if let trackedTask {
            metadata["executionMode"] = trackedTask.executionMode
            metadata["sourceRuntimeID"] = trackedTask.sourceRuntimeID
            metadata["sourceRuntimeGeneration"] = String(trackedTask.sourceRuntimeGeneration)
            metadata["targetTitle"] = trackedTask.sourceTitle
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
        let isTerminalCancellation = contextualEvent.state == .cancelled
        if isTerminalCancellation {
            trackedTasksByRequestID.removeValue(forKey: requestID)
        }
        let target = isTerminalCancellation
            ? (backgroundTargetsByRequestID.removeValue(forKey: requestID) ?? trackedTask?.target)
            : (backgroundTargetsByRequestID[requestID] ?? trackedTask?.target)
        target?.appendAgentTrace(contextualEvent)
        if isTerminalCancellation {
            recordAuditTerminalStateIfNeeded(contextualEvent, removeContext: true)
            finishBridgeFollowStream(requestID: requestID, event: contextualEvent)
        }
        return contextualEvent
    }

    public func takeOverTask(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID[requestID] else {
            return nil
        }
        if task.executionMode == "backgroundTask" {
            guard let cancelEvent = backgroundCommandRunner.cancel(requestID: requestID),
                  cancelEvent.state == .cancelled else {
                let event = AgentTraceEvent(
                    requestID: requestID,
                    state: .waitingForOutput,
                    message: "无法确认独立执行终端已停止；任务仍保留为活动状态，请重试取消。",
                    redactedCommand: task.redactedCommand,
                    metadata: [
                        "executionMode": task.executionMode,
                        "sourceRuntimeID": task.sourceRuntimeID,
                        "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                        "targetTitle": task.sourceTitle,
                        "actorKind": task.actor.kind.rawValue,
                        "actorName": task.actor.name,
                        "control": "takeover",
                        "controlResult": "cancellationUnconfirmed",
                        "taskStillRunning": "unknown"
                    ]
                )
                task.target.appendAgentTrace(event)
                return event
            }
            trackedTasksByRequestID.removeValue(forKey: requestID)
            backgroundTargetsByRequestID.removeValue(forKey: requestID)
            var metadata: [String: String] = [
                "executionMode": task.executionMode,
                "sourceRuntimeID": task.sourceRuntimeID,
                "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                "targetTitle": task.sourceTitle,
                "actorKind": task.actor.kind.rawValue,
                "actorName": task.actor.name,
                "control": "takeover",
                "backgroundCancelState": cancelEvent.state.rawValue
            ]
            if let taskRuntimeID = cancelEvent.metadata?["taskRuntimeID"] {
                metadata["taskRuntimeID"] = taskRuntimeID
            }
            let event = AgentTraceEvent(
                requestID: requestID,
                state: .takenOver,
                message: "独立执行终端已关闭，任务已切换为人工接管；AI 不再继续自动执行。",
                redactedCommand: cancelEvent.redactedCommand ?? task.redactedCommand,
                metadata: metadata
            )
            task.target.appendAgentTrace(event)
            recordAuditTerminalStateIfNeeded(event, removeContext: true)
            finishBridgeFollowStream(requestID: requestID, event: event)
            return event
        }
        trackedTasksByRequestID.removeValue(forKey: requestID)
        releaseVisibleTerminalOwnership(
            on: task.target,
            runtimeID: task.sourceRuntimeID,
            generation: task.sourceRuntimeGeneration,
            excluding: requestID,
            state: .takenOver,
            message: "同一终端上的旧 AI 任务已随人工接管一并释放。"
        )
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let traceTarget: AgentTerminalTarget
        switch resolveVisibleTerminalControl(
            requestID: requestID,
            task: task,
            control: "takeover",
            failureMessage: "目标终端已断开或重连，无法将原任务标记为人工接管；请核对原任务状态。"
        ) {
        case .current(let target):
            traceTarget = target
        case .leaseChanged(let event):
            return event
        }
        let metadata: [String: String] = [
            "executionMode": task.executionMode,
            "sourceRuntimeID": task.sourceRuntimeID,
            "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
            "targetTitle": task.sourceTitle,
            "actorKind": task.actor.kind.rawValue,
            "actorName": task.actor.name,
            "control": "takeover"
        ]
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .takenOver,
            message: "可见终端已切换为人工接管；AI 不再继续自动执行。",
            redactedCommand: task.redactedCommand,
            metadata: metadata
        )
        traceTarget.appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: event)
        return event
    }

    public func confirmTaskComplete(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID[requestID] else {
            return nil
        }
        if task.executionMode == "backgroundTask" {
            let event = AgentTraceEvent(
                requestID: requestID,
                state: .waitingForOutput,
                message: "独立任务尚未报告完成，不能手动确认结束；请等待结果或取消任务。",
                redactedCommand: task.redactedCommand,
                metadata: [
                    "executionMode": task.executionMode,
                    "sourceRuntimeID": task.sourceRuntimeID,
                    "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                    "targetTitle": task.sourceTitle,
                    "actorKind": task.actor.kind.rawValue,
                    "actorName": task.actor.name,
                    "control": "confirmComplete",
                    "controlResult": "unsupported",
                    "taskStillRunning": "true"
                ]
            )
            task.target.appendAgentTrace(event)
            return event
        }
        trackedTasksByRequestID.removeValue(forKey: requestID)
        releaseVisibleTerminalOwnership(
            on: task.target,
            runtimeID: task.sourceRuntimeID,
            generation: task.sourceRuntimeGeneration,
            excluding: requestID,
            state: .completed,
            message: "同一终端上的旧 AI 任务已随本步确认一并释放。"
        )
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let traceTarget: AgentTerminalTarget
        if task.executionMode == "visibleTerminal" {
            switch resolveVisibleTerminalControl(
                requestID: requestID,
                task: task,
                control: "confirmComplete",
                failureMessage: "目标终端已断开或重连，无法确认原任务已完成；请核对原任务状态。"
            ) {
            case .current(let target):
                traceTarget = target
            case .leaseChanged(let event):
                return event
            }
        } else {
            traceTarget = task.target
        }
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .completed,
            message: "已确认本步结束。",
            redactedCommand: task.redactedCommand,
            metadata: [
                "executionMode": task.executionMode,
                "sourceRuntimeID": task.sourceRuntimeID,
                "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
                "targetTitle": task.sourceTitle,
                "actorKind": task.actor.kind.rawValue,
                "actorName": task.actor.name,
                "completionConfidence": "userConfirmed",
                "completionReason": "userConfirmed"
            ]
        )
        traceTarget.appendAgentTrace(event)
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

    private func rememberCompletedRequestIfNeeded(
        _ event: AgentTraceEvent,
        fingerprint: String? = nil
    ) {
        guard Self.isTerminalTraceState(event.state),
              let context = auditContextsByRequestID[event.requestID]
        else { return }
        let value = CompletedRequestReplay(
            fingerprint: fingerprint ?? Self.requestFingerprint(context.request),
            terminalEvent: event.removingTransientTerminalHistoryOutput()
        )
        completedRequestReplaysByID[event.requestID] = value
        completedRequestReplayOrder.removeAll { $0 == event.requestID }
        completedRequestReplayOrder.append(event.requestID)
        while completedRequestReplayOrder.count > Self.maximumCompletedRequestReplays {
            let oldest = completedRequestReplayOrder.removeFirst()
            completedRequestReplaysByID.removeValue(forKey: oldest)
        }
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

    private func resolvedTerminalTarget(for task: TrackedTask) -> AgentTerminalTarget? {
        try? terminalResolver.resolveTerminalTarget(.runtimeID(task.sourceRuntimeID))
    }

    private func unlockVisibleTerminalIfUnowned(_ target: AgentTerminalTarget) {
        let currentRuntimeID = target.runtimeID
        let currentGeneration = target.agentRuntimeGeneration
        let hasCurrentWriter = trackedTasksByRequestID.values.contains { task in
            task.executionMode == "visibleTerminal"
                && task.target === target
                && task.sourceRuntimeID == currentRuntimeID
                && task.sourceRuntimeGeneration == currentGeneration
        }
        if hasCurrentWriter == false {
            target.setAgentInteractionLocked(false)
        }
    }

    private func releaseVisibleTerminalOwnership(
        on target: AgentTerminalTarget,
        runtimeID: String,
        generation: UInt64,
        excluding requestID: String,
        state: AgentTraceState,
        message: String
    ) {
        let staleIDs: [(String, TrackedTask)] = trackedTasksByRequestID.compactMap { entry in
            let (id, task) = entry
            guard id != requestID,
                  task.executionMode == "visibleTerminal",
                  task.target === target,
                  task.sourceRuntimeID == runtimeID,
                  task.sourceRuntimeGeneration == generation
            else { return nil }
            return (id, task)
        }
        for (staleID, staleTask) in staleIDs {
            trackedTasksByRequestID.removeValue(forKey: staleID)
            backgroundTargetsByRequestID.removeValue(forKey: staleID)
            let event = AgentTraceEvent(
                requestID: staleID,
                state: state,
                message: message,
                redactedCommand: staleTask.redactedCommand,
                metadata: [
                    "executionMode": staleTask.executionMode,
                    "sourceRuntimeID": staleTask.sourceRuntimeID,
                    "sourceRuntimeGeneration": String(staleTask.sourceRuntimeGeneration),
                    "targetTitle": staleTask.sourceTitle,
                    "actorKind": staleTask.actor.kind.rawValue,
                    "actorName": staleTask.actor.name,
                    "controlResult": "supersededByTerminalControl"
                ]
            )
            target.appendAgentTrace(event)
            recordAuditTerminalStateIfNeeded(event, removeContext: true)
            finishBridgeFollowStream(requestID: staleID, event: event)
        }
        target.setAgentInteractionLocked(false)
    }

    private func resolveVisibleTerminalControl(
        requestID: String,
        task: TrackedTask,
        control: String,
        failureMessage: String
    ) -> VisibleTerminalControlResolution {
        let resolvedTarget = resolvedTerminalTarget(for: task)
        if let resolvedTarget,
           resolvedTarget.runtimeID == task.sourceRuntimeID,
           resolvedTarget.agentRuntimeGeneration == task.sourceRuntimeGeneration,
           resolvedTarget.isAgentRuntimeConnected {
            return .current(resolvedTarget)
        }

        var metadata: [String: String] = [
            "executionMode": task.executionMode,
            "sourceRuntimeID": task.sourceRuntimeID,
            "sourceRuntimeGeneration": String(task.sourceRuntimeGeneration),
            "targetTitle": task.sourceTitle,
            "actorKind": task.actor.kind.rawValue,
            "actorName": task.actor.name,
            "control": control,
            "controlResult": "runtimeLeaseChanged",
            "expectedRuntimeGeneration": String(task.sourceRuntimeGeneration),
            "runtimeConnected": resolvedTarget?.isAgentRuntimeConnected == true ? "true" : "false"
        ]
        metadata["actualRuntimeGeneration"] = resolvedTarget
            .map { String($0.agentRuntimeGeneration) }
            ?? "unavailable"
        let event = AgentTraceEvent(
            requestID: requestID,
            state: .failed,
            message: failureMessage,
            redactedCommand: task.redactedCommand,
            metadata: metadata
        )
        (resolvedTarget ?? task.target).appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        finishBridgeFollowStream(requestID: requestID, event: event)
        return .leaseChanged(event)
    }

    private func recordAuditTerminalStateIfNeeded(
        _ event: AgentTraceEvent,
        removeContext: Bool? = nil
    ) {
        rememberCompletedRequestIfNeeded(event)
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

    private static func requestFingerprint(_ request: AgentBridgeRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request)) ?? Data()
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func isTerminalTraceState(_ state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput, .paused:
            return false
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
        target: AuditTarget,
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
                targetTitle: target.title,
                actionKind: "runCommand",
                risk: risk.rawValue,
                state: state.rawValue,
                redactedInput: redactedInput,
                environment: target.automationPolicy.environment,
                approvalMode: target.automationPolicy.aiExecutionPolicy,
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
        var sessions = sessionLister?.listAgentTerminalSessions() ?? []
        if let capabilityID = request.capabilityID {
            let allowedRuntimeGenerations = localAgentCapabilityRegistry.allowedRuntimeGenerations(
                capabilityID: capabilityID
            )
            guard allowedRuntimeGenerations.isEmpty == false else {
                return [
                    AgentTraceEvent(
                        requestID: request.id,
                        state: .failed,
                        message: AgentExecutionError.capabilityRejected.localizedDescription,
                        redactedCommand: nil
                    )
                ]
            }
            sessions = sessions.filter { session in
                allowedRuntimeGenerations[session.runtimeID] == session.connectionGeneration
            }
            guard sessions.isEmpty == false else {
                return [
                    AgentTraceEvent(
                        requestID: request.id,
                        state: .failed,
                        message: AgentExecutionError.capabilityRejected.localizedDescription,
                        redactedCommand: nil
                    )
                ]
            }
        }
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

private extension AgentTraceEvent {
    func removingTransientTerminalHistoryOutput() -> AgentTraceEvent {
        guard var metadata,
              metadata.removeValue(forKey: "terminalHistoryOutput") != nil
        else { return self }
        return AgentTraceEvent(
            requestID: requestID,
            state: state,
            message: message,
            redactedCommand: redactedCommand,
            metadata: metadata
        )
    }
}

extension AgentExecutionCoordinator: AgentCommandExecuting, AgentTaskControlling, AgentSensitiveInputRouting {
    public func sensitiveInputPrompt(runtimeID: String) -> AgentSensitiveInputPrompt? {
        guard let target = try? terminalResolver.resolveTerminalTarget(.runtimeID(runtimeID)),
              target.runtimeID == runtimeID,
              target.isAgentRuntimeConnected,
              target.isSensitiveInputProtectionActive
        else { return nil }
        return AgentSensitiveInputPrompt(
            runtimeID: runtimeID,
            connectionGeneration: target.agentRuntimeGeneration,
            targetTitle: target.agentTitle
        )
    }

    @discardableResult
    public func submitSensitiveInput(_ bytes: [UInt8], runtimeID: String) -> Bool {
        guard let prompt = sensitiveInputPrompt(runtimeID: runtimeID) else {
            return false
        }
        return submitSensitiveInput(bytes, prompt: prompt)
    }

    @discardableResult
    public func submitSensitiveInput(
        _ bytes: [UInt8],
        prompt: AgentSensitiveInputPrompt
    ) -> Bool {
        let runtimeID = prompt.runtimeID
        guard let target = try? terminalResolver.resolveTerminalTarget(.runtimeID(runtimeID)),
              target.runtimeID == runtimeID,
              target.isAgentRuntimeConnected,
              target.agentRuntimeGeneration == prompt.connectionGeneration,
              target.isSensitiveInputProtectionActive
        else { return false }
        return target.sendSensitiveUserInput(bytes)
    }
}

extension TerminalPaneViewController: AgentTerminalTarget {
    public var agentRuntimeGeneration: UInt64 { terminalRuntimeGeneration }
    public var isAgentRuntimeConnected: Bool { isTerminalRuntimeConnected }
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
    public var agentRuntimeGeneration: UInt64 { terminalRuntimeGeneration }
    public var isAgentRuntimeConnected: Bool { isTerminalRuntimeConnected }
    public var agentCommandCompletionGeneration: UInt64 { commandCompletionGeneration }
    public var agentTerminalOutputTranscript: String { terminalOutputTranscript }
    public var agentTerminalDisplaySnapshot: String { terminalDisplaySnapshotForTesting }
    /// Shell completion markers are valid for SSH sessions, where the remote
    /// endpoint is a POSIX shell. Serial/BLE console sessions may terminate at
    /// a network-device CLI (for example `Switch#`), which treats the wrapper
    /// syntax and OSC escape sequence as literal command input.
    public var supportsAgentCompletionMarker: Bool {
        connectionKind == .ssh
    }

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
