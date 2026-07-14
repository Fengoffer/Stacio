import Foundation
import StacioAgentBridge
import StacioCoreBindings

@MainActor
public protocol AgentTerminalTarget: AnyObject {
    var runtimeID: String { get }
    var agentTitle: String { get }
    var agentLiveSessionContext: TunnelLiveSessionContext? { get }
    var agentAutomationPolicy: SessionAutomationPolicy { get }
    func appendAgentTrace(_ event: AgentTraceEvent)
    func sendInput(_ bytes: [UInt8])
}

public extension AgentTerminalTarget {
    var agentAutomationPolicy: SessionAutomationPolicy { .default }
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
    private var outputBytes: [UInt8] = []
    private var sawUserInput = false
    private var commandOutputCaptureStarted = false
    private var lastOutputAt: Date?
    private var subscription: TerminalOutputBroadcastHub.Subscription?

    init(
        requestID: String,
        runtimeID: String,
        command: String,
        redactedCommand: String,
        outputHub: TerminalOutputBroadcastHub,
        completion: AgentVisibleTerminalCompletion,
        onOutputUpdate: @escaping (VisibleTerminalOutputUpdate) -> Void
    ) {
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.command = command
        self.redactedCommand = redactedCommand
        self.outputHub = outputHub
        self.completion = completion
        self.onOutputUpdate = onOutputUpdate
    }

    func begin() {
        subscription = outputHub.subscribe(runtimeID: runtimeID) { [weak self] event in
            self?.ingest(event)
        }
    }

    func markCommandWritten() {
        commandOutputCaptureStarted = true
    }

    func wait() -> VisibleTerminalObservationResult {
        defer { close() }
        if Self.requiresManualCompletion(command) {
            waitUntilManualCommandHasInitialObservation()
            return VisibleTerminalObservationResult(
                outcome: .manualRequired,
                summary: "",
                reason: "longRunningCommand"
            )
        }
        let deadline = Date().addingTimeInterval(completion.maximumDuration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if sawUserInput {
                return VisibleTerminalObservationResult(
                    outcome: .ambiguousUserInput,
                    summary: "",
                    reason: "userInputDuringCommand"
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
            summary: "",
            reason: outputBytes.isEmpty ? "noOutputBeforeTimeout" : "timeoutBeforeSafeCompletion"
        )
    }

    private func ingest(_ event: TerminalBroadcastEvent) {
        switch event.kind {
        case .output:
            guard commandOutputCaptureStarted else { return }
            guard sawUserInput == false else { return }
            outputBytes.append(contentsOf: event.bytes)
            lastOutputAt = event.createdAt
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
        }
    }

    private func waitUntilManualCommandHasInitialObservation() {
        let deadline = Date().addingTimeInterval(min(completion.maximumDuration, max(completion.idleInterval, 0.25)))
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if sawUserInput || outputBytes.isEmpty == false {
                return
            }
        }
    }

    private func close() {
        if let subscription {
            outputHub.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        subscription = nil
    }

    private static func summary(from bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        return AgentProtocolRedaction.redact(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    private static func isAICommandEcho(_ bytes: [UInt8], command: String) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == command
    }

    private static func requiresManualCompletion(_ command: String) -> Bool {
        let lower = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.isEmpty == false else {
            return false
        }
        let longRunningPrefixes = [
            "tail -f",
            "tail -F",
            "top",
            "htop",
            "less ",
            "more ",
            "vim",
            "vi ",
            "nano",
            "ssh ",
            "mysql",
            "psql",
            "redis-cli",
            "python",
            "node",
            "irb",
            "rails console",
            "ping ",
            "watch "
        ]
        return longRunningPrefixes.contains { prefix in
            lower == prefix.trimmingCharacters(in: .whitespaces)
                || lower.hasPrefix(prefix)
                || lower.contains(" \(prefix)")
        }
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
        let redacted = AgentProtocolRedaction.redact(normalized)
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
    }

    private struct AuditContext {
        let request: AgentBridgeRequest
        let target: AgentTerminalTarget
        let risk: AgentActionRisk
        let redactedInput: String
        let decision: AgentAuthorizationDecision
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
                executionMode: "visibleTerminal"
            )
            emit(.typing, "正在写入终端", decision: decision)
            let visibleObservation = VisibleTerminalObservationSession(
                requestID: request.id,
                runtimeID: target.runtimeID,
                command: commandRequest.command,
                redactedCommand: redactedCommand,
                outputHub: visibleTerminalOutputHub,
                completion: visibleTerminalCompletion,
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
            target.sendInput(Array((commandRequest.command + "\n").utf8))
            visibleObservation.markCommandWritten()
            emit(.running, "命令已在终端执行，输出将实时显示", decision: decision)
            recordRunningAuditIfNeeded()
            let observation = visibleObservation.wait()
            switch observation.outcome {
            case .completed:
                emit(
                    .completed,
                    "本次命令已完成：\(observation.summary)",
                    metadata: [
                        "terminalOutputSummary": observation.summary,
                        "completionConfidence": "observedIdle",
                        "completionReason": "outputIdle"
                    ],
                    decision: decision
                )
                trackedTasksByRequestID.removeValue(forKey: request.id)
            case .manualRequired:
                emit(
                    .waitingForOutput,
                    "这条命令可能仍在运行，Stacio 不会根据静默输出自动判定完成；请手动停止、确认或接管。",
                    metadata: [
                        "completionConfidence": "manualRequired",
                        "completionReason": observation.reason
                    ],
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
                executionMode: "backgroundTask"
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
                }
            )
        }
        if events.last?.state != .failed {
            recordRunningAuditIfNeeded()
        }
        return events
    }

    public func pauseTask(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID.removeValue(forKey: requestID) else {
            return nil
        }
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
                "control": "pause"
            ]
        )
        task.target.appendAgentTrace(event)
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        return event
    }

    public func cancelTask(requestID: String) -> AgentTraceEvent? {
        if let task = trackedTasksByRequestID[requestID],
           task.executionMode == "visibleTerminal" {
            trackedTasksByRequestID.removeValue(forKey: requestID)
            backgroundTargetsByRequestID.removeValue(forKey: requestID)
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
                    "control": "cancel"
                ]
            )
            currentTarget.appendAgentTrace(event)
            recordAuditTerminalStateIfNeeded(event, removeContext: true)
            return event
        }
        guard let event = backgroundCommandRunner.cancel(requestID: requestID) else {
            return nil
        }
        trackedTasksByRequestID.removeValue(forKey: requestID)
        if let target = backgroundTargetsByRequestID.removeValue(forKey: requestID) {
            target.appendAgentTrace(event)
        }
        recordAuditTerminalStateIfNeeded(event, removeContext: true)
        return event
    }

    public func takeOverTask(requestID: String) -> AgentTraceEvent? {
        guard let task = trackedTasksByRequestID.removeValue(forKey: requestID) else {
            return nil
        }
        backgroundTargetsByRequestID.removeValue(forKey: requestID)
        let cancelEvent = task.executionMode == "backgroundTask"
            ? backgroundCommandRunner.cancel(requestID: requestID)
            : nil
        var metadata: [String: String] = [
            "executionMode": task.executionMode,
            "sourceRuntimeID": task.sourceRuntimeID,
            "targetTitle": task.target.agentTitle,
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
        return event
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
