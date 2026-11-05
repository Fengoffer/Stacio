import Foundation

public struct StructuredLocalAgentRuntimeFailure: Error, Equatable, Sendable {
    public let reasonCode: AttemptReasonCode
    public let summary: String

    public init(reasonCode: AttemptReasonCode, summary: String) {
        self.reasonCode = reasonCode
        self.summary = summary
    }
}

/// A dynamic tool request emitted by the Codex app-server. The raw JSON-RPC
/// id is retained because JSON-RPC requires the response id to preserve its
/// original type (string versus number).
public struct StructuredLocalAgentToolCall: Equatable, Sendable {
    public let requestID: String
    public let requestIDJSON: String
    public let callID: String
    public let threadID: String?
    public let turnID: String?
    public let namespace: String
    public let tool: String
    public let argumentsJSON: String

    public init(
        requestID: String,
        requestIDJSON: String,
        callID: String,
        threadID: String?,
        turnID: String?,
        namespace: String,
        tool: String,
        argumentsJSON: String
    ) {
        self.requestID = requestID
        self.requestIDJSON = requestIDJSON
        self.callID = callID
        self.threadID = threadID
        self.turnID = turnID
        self.namespace = namespace
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

/// A Codex app-server request that Stacio does not execute locally. Keeping
/// the original id and method lets the runtime send an explicit fail-closed
/// response instead of leaving the provider waiting forever.
public struct StructuredLocalAgentServerRequest: Equatable, Sendable {
    public let requestID: String
    public let requestIDJSON: String
    public let method: String

    public init(requestID: String, requestIDJSON: String, method: String) {
        self.requestID = requestID
        self.requestIDJSON = requestIDJSON
        self.method = method
    }
}

public enum StructuredLocalAgentRuntimeEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(StructuredLocalAgentToolCall)
    case serverRequest(StructuredLocalAgentServerRequest)
    case completed(String)
    case failed(StructuredLocalAgentRuntimeFailure)
    case cancelled

    fileprivate var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .textDelta, .reasoningDelta, .toolCall, .serverRequest:
            return false
        }
    }
}

/// Stateless JSONL decoding plus small per-turn accumulators. Keeping this
/// separate from `Process` makes protocol compatibility testable without
/// launching a user's installed CLI.
public enum StructuredLocalAgentRuntimeParser {
    public struct ClaudeState: Sendable {
        fileprivate var answer = ""
        fileprivate var latestSnapshot = ""
        fileprivate var didTerminate = false

        public init() {}
    }

    public struct CodexState: Sendable {
        fileprivate var answer = ""
        fileprivate var reasoning = ""
        fileprivate var didTerminate = false

        public init() {}
    }

    public static func parseClaudeJSONLine(
        _ line: String,
        state: inout ClaudeState
    ) -> [StructuredLocalAgentRuntimeEvent] {
        guard state.didTerminate == false,
              let object = object(from: line),
              let type = string(object["type"])
        else { return [] }

        switch type {
        case "stream_event":
            guard let event = dictionary(object["event"]),
                  string(event["type"]) == "content_block_delta",
                  let delta = dictionary(event["delta"]),
                  let deltaType = string(delta["type"])
            else { return [] }
            return parseClaudeDelta(delta, type: deltaType, state: &state)

        case "content_block_delta":
            guard let delta = dictionary(object["delta"]),
                  let deltaType = string(delta["type"])
            else { return [] }
            return parseClaudeDelta(delta, type: deltaType, state: &state)

        case "assistant":
            let snapshot = contentText(dictionary(object["message"])?["content"])
            guard snapshot.isEmpty == false else { return [] }
            state.latestSnapshot = snapshot
            return appendSnapshot(snapshot, answer: &state.answer)

        case "result":
            let isError = bool(object["is_error"]) == true
                || string(object["subtype"])?.lowercased().contains("error") == true
            if isError {
                state.didTerminate = true
                let summary = firstNonEmpty(
                    string(object["error"]),
                    string(object["result"]),
                    "Claude Code 返回了错误结果。"
                )
                return [.failed(.init(reasonCode: .providerRequestFailed, summary: summary))]
            }
            let result = firstNonEmpty(
                string(object["result"]),
                state.latestSnapshot,
                state.answer
            )
            if state.answer.isEmpty, result.isEmpty == false {
                state.answer = result
            }
            state.didTerminate = true
            return [.completed(result.isEmpty ? state.answer : result)]

        case "error":
            state.didTerminate = true
            let summary = firstNonEmpty(
                string(object["message"]),
                string(dictionary(object["error"])?["message"]),
                "Claude Code 协议错误。"
            )
            return [.failed(.init(reasonCode: .protocolError, summary: summary))]

        default:
            return []
        }
    }

    public static func parseCodexJSONLine(
        _ line: String,
        state: inout CodexState
    ) -> [StructuredLocalAgentRuntimeEvent] {
        guard state.didTerminate == false,
              let object = object(from: line)
        else { return [] }

        if let error = dictionary(object["error"]) {
            state.didTerminate = true
            let summary = firstNonEmpty(
                string(error["message"]),
                string(error["code"]),
                "Codex App Server 返回协议错误。"
            )
            return [.failed(.init(reasonCode: .protocolError, summary: summary))]
        }

        guard let method = string(object["method"]) else { return [] }
        let normalizedMethod = method.lowercased()
        let params = dictionary(object["params"]) ?? [:]

        if normalizedMethod == "item/tool/call" {
            guard let requestIDValue = object["id"],
                  let requestID = string(requestIDValue),
                  let callID = nonEmptyString(params["callId"]),
                  let threadID = nonEmptyString(params["threadId"]),
                  let turnID = nonEmptyString(params["turnId"]),
                  let tool = string(params["tool"]),
                  tool.isEmpty == false,
                  let arguments = dictionary(params["arguments"]),
                  let requestIDJSON = jsonString(requestIDValue)
            else {
                state.didTerminate = true
                return [.failed(.init(
                    reasonCode: .protocolError,
                    summary: "Codex 动态工具请求缺少 callId、threadId、turnId、arguments 或 tool。"
                ))]
            }

            // The app-server schema permits namespace to be omitted/null for
            // a tool with an unambiguous name. Stacio only exposes one
            // namespace today, so normalize that wire-compatible form while
            // retaining the normal namespace for current clients.
            let namespace = string(params["namespace"])
                ?? "stacio_terminal"
            guard namespace.isEmpty == false else {
                state.didTerminate = true
                return [.failed(.init(
                    reasonCode: .protocolError,
                    summary: "Codex 动态工具请求的 namespace 为空。"
                ))]
            }

            guard let argumentsJSON = jsonString(arguments) else {
                state.didTerminate = true
                return [.failed(.init(
                    reasonCode: .protocolError,
                    summary: "Codex 动态工具请求的 arguments 不是有效对象。"
                ))]
            }
            return [.toolCall(.init(
                requestID: requestID,
                requestIDJSON: requestIDJSON,
                callID: callID,
                threadID: threadID,
                turnID: turnID,
                namespace: namespace,
                tool: tool,
                argumentsJSON: argumentsJSON
            ))]
        }

        switch normalizedMethod {
        case "item/agentmessage/delta":
            guard let delta = firstString(in: params, keys: ["delta", "textDelta", "text"]),
                  delta.isEmpty == false
            else { return [] }
            state.answer += delta
            return [.textDelta(delta)]

        case "item/reasoning/delta",
             "item/reasoning/summarydelta",
             "item/reasoning/summarytextdelta",
             "item/reasoning/textdelta":
            guard let delta = firstString(in: params, keys: ["delta", "reasoningDelta", "text"]),
                  delta.isEmpty == false
            else { return [] }
            state.reasoning += delta
            return [.reasoningDelta(delta)]

        case "item/agentmessage/completed":
            let snapshot = firstNonEmpty(
                firstString(in: params, keys: ["text", "content"]),
                firstString(in: dictionary(params["item"]) ?? [:], keys: ["text", "content"])
            )
            return appendSnapshot(snapshot, answer: &state.answer)

        case "item/completed":
            let item = dictionary(params["item"]) ?? params
            let itemType = string(item["type"])?.lowercased()
            if itemType == "reasoning" {
                let summary = firstString(in: item, keys: ["summary", "text", "content"])
                    ?? contentText(item["summary"])
                guard summary.isEmpty == false else { return [] }
                return appendReasoningSnapshot(summary, reasoning: &state.reasoning)
            }
            let snapshot = firstString(in: item, keys: ["text", "content"])
                ?? contentText(item["content"])
            return appendSnapshot(snapshot, answer: &state.answer)

        case "turn/completed":
            let turn = dictionary(params["turn"]) ?? [:]
            let status = firstNonEmpty(
                string(turn["status"]),
                string(params["status"]),
                "completed"
            ).lowercased()
            if ["failed", "error"].contains(status) {
                state.didTerminate = true
                let summary = firstNonEmpty(
                    string(dictionary(turn["error"])?["message"]),
                    string(turn["error"]),
                    string(params["error"]),
                    "Codex 任务执行失败。"
                )
                return [.failed(.init(reasonCode: .providerRequestFailed, summary: summary))]
            }
            if ["cancelled", "canceled", "interrupted", "aborted"].contains(status) {
                state.didTerminate = true
                return [.cancelled]
            }
            state.didTerminate = true
            return [.completed(state.answer)]

        case "error":
            state.didTerminate = true
            return [.failed(.init(
                reasonCode: .protocolError,
                summary: firstNonEmpty(
                    string(params["message"]),
                    string(dictionary(params["error"])?["message"]),
                    "Codex App Server 协议错误。"
                )
            ))]

        default:
            guard let requestIDValue = object["id"],
                  let requestID = string(requestIDValue),
                  let requestIDJSON = jsonString(requestIDValue)
            else { return [] }
            return [.serverRequest(.init(
                requestID: requestID,
                requestIDJSON: requestIDJSON,
                method: method
            ))]
        }
    }

    fileprivate static func object(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return value as? [String: Any]
    }

    fileprivate static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    fileprivate static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = string(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["true", "1", "yes"].contains(value.lowercased())
        default:
            return nil
        }
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = string(object[key]), value.isEmpty == false {
                return value
            }
        }
        return nil
    }

    private static func contentText(_ value: Any?) -> String {
        guard let items = value as? [Any] else {
            return string(value) ?? ""
        }
        return items.compactMap { item -> String? in
            guard let block = dictionary(item),
                  string(block["type"]) == "text"
            else { return nil }
            return string(block["text"])
        }.joined()
    }

    private static func parseClaudeDelta(
        _ delta: [String: Any],
        type: String,
        state: inout ClaudeState
    ) -> [StructuredLocalAgentRuntimeEvent] {
        if type == "text_delta", let text = string(delta["text"]), text.isEmpty == false {
            state.answer += text
            return [.textDelta(text)]
        }
        if type == "thinking_delta" {
            let reasoning = firstNonEmpty(string(delta["thinking"]), string(delta["text"]))
            guard reasoning.isEmpty == false else { return [] }
            return [.reasoningDelta(reasoning)]
        }
        return []
    }

    private static func appendReasoningSnapshot(
        _ snapshot: String,
        reasoning: inout String
    ) -> [StructuredLocalAgentRuntimeEvent] {
        guard snapshot.isEmpty == false else { return [] }
        if snapshot.hasPrefix(reasoning) {
            let suffix = String(snapshot.dropFirst(reasoning.count))
            guard suffix.isEmpty == false else { return [] }
            reasoning += suffix
            return [.reasoningDelta(suffix)]
        }
        if reasoning.isEmpty {
            reasoning = snapshot
            return [.reasoningDelta(snapshot)]
        }
        return []
    }

    private static func appendSnapshot(
        _ snapshot: String,
        answer: inout String
    ) -> [StructuredLocalAgentRuntimeEvent] {
        guard snapshot.isEmpty == false else { return [] }
        if snapshot.hasPrefix(answer) {
            let suffix = String(snapshot.dropFirst(answer.count))
            guard suffix.isEmpty == false else { return [] }
            answer += suffix
            return [.textDelta(suffix)]
        }
        if answer.isEmpty {
            answer = snapshot
            return [.textDelta(snapshot)]
        }
        return []
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return value
            }
        }
        return ""
    }
}

@MainActor
public final class StructuredLocalAgentRuntime {
    public typealias EventHandler = @MainActor (StructuredLocalAgentRuntimeEvent) -> Void

    private enum CodexRequestKind {
        case initialize
        case startThread
        case startTurn
        case interrupt
    }

    private let configuration: LocalAgentPassthroughConfiguration
    private let workingDirectory: AgentProcessWorkingDirectory
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrText = ""
    private var eventHandler: EventHandler?
    private var generation: UInt64 = 0
    private var didEmitTerminal = false
    private var cancelRequested = false
    private var prompt = ""
    private var claudeState = StructuredLocalAgentRuntimeParser.ClaudeState()
    private var codexState = StructuredLocalAgentRuntimeParser.CodexState()
    private var codexRequestKinds: [String: CodexRequestKind] = [:]
    private var codexThreadID: String?
    private var codexTurnID: String?

    public init(
        configuration: LocalAgentPassthroughConfiguration,
        workingDirectory: AgentProcessWorkingDirectory
    ) {
        self.configuration = configuration
        self.workingDirectory = workingDirectory
    }

    public func start(
        prompt: String,
        onEvent: @escaping EventHandler
    ) {
        guard process == nil else {
            onEvent(.failed(.init(
                reasonCode: .runtimeStartFailed,
                summary: "Local Agent Runtime 已在运行。"
            )))
            return
        }
        guard configuration.isReadyForStructuredRuntime,
              let structuredProtocol = configuration.structuredProtocol
        else {
            onEvent(.failed(.init(
                reasonCode: .configurationInvalid,
                summary: "Local Agent 结构化协议配置无效。"
            )))
            return
        }

        generation &+= 1
        let activeGeneration = generation
        self.prompt = prompt
        eventHandler = onEvent
        didEmitTerminal = false
        cancelRequested = false
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrText = ""
        claudeState = .init()
        codexState = .init()
        codexRequestKinds.removeAll()
        codexThreadID = nil
        codexTurnID = nil

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = Self.launchArguments(for: structuredProtocol)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = launchEnvironment()
        if let directory = workingDirectory.localPathReference {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleTermination(
                    status: terminatedProcess.terminationStatus,
                    generation: activeGeneration
                )
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else { return }
            Task { @MainActor [weak self] in
                self?.consumeStdout(data, generation: activeGeneration)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else { return }
            Task { @MainActor [weak self] in
                self?.consumeStderr(data, generation: activeGeneration)
            }
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        do {
            try process.run()
        } catch {
            cleanupProcess()
            emit(.failed(.init(
                reasonCode: .runtimeStartFailed,
                summary: "无法启动 \(configuration.displayName)：\(error.localizedDescription)"
            )), generation: activeGeneration)
            return
        }

        switch structuredProtocol {
        case .jsonl:
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                emit(.failed(.init(
                    reasonCode: .runtimeStartFailed,
                    summary: "无法向 \(configuration.displayName) 投递输入：\(error.localizedDescription)"
                )), generation: activeGeneration)
                terminateProcess()
            }
        case .rpc:
            sendCodexRequest(
                kind: .initialize,
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "stacio",
                        "title": "Stacio",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ],
                generation: activeGeneration
            )
        case .acp:
            emit(.failed(.init(
                reasonCode: .configurationInvalid,
                summary: "当前版本尚未启用 ACP Local Agent Runtime。"
            )), generation: activeGeneration)
            terminateProcess()
        }
    }

    public func cancel() {
        guard process != nil, didEmitTerminal == false else { return }
        let activeGeneration = generation
        cancelRequested = true
        if configuration.structuredProtocol == .rpc,
           let threadID = codexThreadID,
           let turnID = codexTurnID {
            sendCodexRequest(
                kind: .interrupt,
                method: "turn/interrupt",
                params: ["threadId": threadID, "turnId": turnID],
                generation: activeGeneration
            )
        }
        emit(.cancelled, generation: activeGeneration)
        terminateProcess()
    }

    /// Completes a dynamic Codex tool request. This method deliberately does
    /// not terminate the process: the app-server keeps the turn suspended
    /// while Stacio presents approval and executes the command.
    public func respondToToolCall(
        _ call: StructuredLocalAgentToolCall,
        success: Bool,
        text: String
    ) {
        guard configuration.structuredProtocol == .rpc,
              process != nil,
              didEmitTerminal == false,
              call.threadID == codexThreadID,
              call.turnID == codexTurnID
        else { return }

        var response: [String: Any] = [
            "result": [
                "success": success,
                "contentItems": [[
                    "type": "inputText",
                    "text": text
                ]]
            ]
        ]
        if let data = call.requestIDJSON.data(using: .utf8),
           let id = try? JSONSerialization.jsonObject(with: data) {
            response["id"] = id
        } else {
            response["id"] = call.requestID
        }
        writeJSON(response, generation: generation)
    }

    /// Respond to a provider-initiated request that is outside Stacio's
    /// dynamic terminal tool contract. Approval-like requests are explicitly
    /// declined; other requests receive a JSON-RPC error. Both paths keep the
    /// app-server from hanging while never granting an unreviewed capability.
    public func respondToServerRequest(
        _ request: StructuredLocalAgentServerRequest
    ) {
        guard configuration.structuredProtocol == .rpc,
              process != nil,
              didEmitTerminal == false,
              let data = request.requestIDJSON.data(using: .utf8),
              let id = try? JSONSerialization.jsonObject(with: data)
        else { return }

        let normalizedMethod = request.method.lowercased()
        let isApprovalRequest = normalizedMethod.contains("approval")
            || normalizedMethod.contains("permission")
            || normalizedMethod.contains("elicitation")
        var response: [String: Any] = ["id": id]
        if isApprovalRequest {
            response["result"] = ["decision": "decline"]
        } else {
            response["error"] = [
                "code": -32000,
                "message": "Stacio 未接管 Codex 请求：\(request.method)"
            ]
        }
        writeJSON(response, generation: generation)
    }

    static func launchArguments(for structuredProtocol: LocalAgentStructuredProtocol) -> [String] {
        switch structuredProtocol {
        case .jsonl:
            return [
                "-p",
                "--verbose",
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--permission-mode", "plan",
                // Claude's built-in tools are intentionally disabled until a
                // verified MCP/SDK bridge can return tool results through the
                // Stacio approval and terminal-audit pipeline.
                "--tools", ""
            ]
        case .rpc:
            return ["app-server", "--listen", "stdio://"]
        case .acp:
            return []
        }
    }

    private func launchEnvironment() -> [String: String] {
        // Only pass the frozen, verified environment captured with the
        // configuration. Inheriting the app process environment would allow
        // unverified PATH/credential changes to affect a managed runtime.
        var environment: [String: String] = [:]
        for entry in configuration.launchEnvironment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard key.isEmpty == false else { continue }
            environment[key] = value
        }
        environment["TERM"] = "dumb"
        return environment
    }

    private func consumeStdout(_ data: Data, generation: UInt64) {
        guard generation == self.generation, didEmitTerminal == false else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  line.isEmpty == false
            else { continue }
            consumeJSONLine(line, generation: generation)
        }
    }

    private func consumeStderr(_ data: Data, generation: UInt64) {
        guard generation == self.generation,
              let value = String(data: data, encoding: .utf8),
              value.isEmpty == false
        else { return }
        let remaining = max(0, 8_192 - stderrText.count)
        if remaining > 0 {
            stderrText += String(value.prefix(remaining))
        }
    }

    private func consumeJSONLine(_ line: String, generation: UInt64) {
        guard generation == self.generation,
              didEmitTerminal == false,
              let structuredProtocol = configuration.structuredProtocol
        else { return }

        if structuredProtocol == .rpc {
            handleCodexControlMessage(line, generation: generation)
        }
        let events: [StructuredLocalAgentRuntimeEvent]
        switch structuredProtocol {
        case .jsonl:
            events = StructuredLocalAgentRuntimeParser.parseClaudeJSONLine(
                line,
                state: &claudeState
            )
        case .rpc:
            events = StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                line,
                state: &codexState
            )
        case .acp:
            events = []
        }
        for event in events {
            emit(event, generation: generation)
            if event.isTerminal {
                terminateProcess()
                break
            }
        }
    }

    private func handleCodexControlMessage(_ line: String, generation: UInt64) {
        guard let object = StructuredLocalAgentRuntimeParser.object(from: line),
              object["method"] == nil,
              let id = Self.idString(object["id"]),
              let kind = codexRequestKinds.removeValue(forKey: id)
        else { return }

        if let error = StructuredLocalAgentRuntimeParser.dictionary(object["error"]) {
            let summary = StructuredLocalAgentRuntimeParser.string(error["message"])
                ?? "Codex App Server 请求失败。"
            emit(.failed(.init(reasonCode: .protocolError, summary: summary)), generation: generation)
            terminateProcess()
            return
        }
        let result = StructuredLocalAgentRuntimeParser.dictionary(object["result"]) ?? [:]
        switch kind {
        case .initialize:
            sendCodexNotification(method: "initialized", params: [:], generation: generation)
            var params: [String: Any] = [:]
            if let directory = workingDirectory.localPathReference {
                params["cwd"] = directory
            }
            params["approvalPolicy"] = [
                "granular": [
                    "rules": false,
                    "mcp_elicitations": false,
                    "request_permissions": false,
                    "sandbox_approval": false
                ]
            ]
            params["approvalsReviewer"] = "user"
            params["sandbox"] = "read-only"
            params["ephemeral"] = false
            params["developerInstructions"] = """
            You are operating inside Stacio's troubleshooting assistant. Use the dynamic stacio_terminal tools for commands instead of asking the user to copy commands manually. get_context is read-only. execute_command requires a concise reason and must use the currently selected terminal target. Never claim a command ran until its tool result is returned.
            """
            params["dynamicTools"] = [[
                "type": "namespace",
                "name": "stacio_terminal",
                "description": "Stacio troubleshooting terminal access",
                "tools": [
                    [
                        "type": "function",
                        "name": "get_context",
                        "description": "Read the selected terminal context",
                        "inputSchema": ["type": "object", "properties": [:]]
                    ],
                    [
                        "type": "function",
                        "name": "execute_command",
                        "description": "Propose a command for the selected terminal",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "command": ["type": "string"],
                                "reason": ["type": "string"],
                                "targetTerminalSessionId": ["type": "string"]
                            ],
                            "required": ["targetTerminalSessionId", "command"]
                        ]
                    ]
                ]
            ]]
            sendCodexRequest(
                kind: .startThread,
                method: "thread/start",
                params: params,
                generation: generation
            )

        case .startThread:
            let thread = StructuredLocalAgentRuntimeParser.dictionary(result["thread"]) ?? [:]
            guard let threadID = StructuredLocalAgentRuntimeParser.string(thread["id"])
                ?? StructuredLocalAgentRuntimeParser.string(result["id"]),
                  threadID.isEmpty == false
            else {
                emit(.failed(.init(
                    reasonCode: .protocolError,
                    summary: "Codex thread/start 未返回 thread id。"
                )), generation: generation)
                terminateProcess()
                return
            }
            codexThreadID = threadID
            sendCodexRequest(
                kind: .startTurn,
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "clientUserMessageId": "stacio-\(UUID().uuidString.lowercased())",
                    "input": [[
                        "type": "text",
                        "text": prompt,
                        "text_elements": []
                    ]]
                ],
                generation: generation
            )

        case .startTurn:
            let turn = StructuredLocalAgentRuntimeParser.dictionary(result["turn"]) ?? [:]
            codexTurnID = StructuredLocalAgentRuntimeParser.string(turn["id"])
                ?? StructuredLocalAgentRuntimeParser.string(result["id"])

        case .interrupt:
            break
        }
    }

    private func sendCodexRequest(
        kind: CodexRequestKind,
        method: String,
        params: [String: Any],
        generation: UInt64
    ) {
        let id = "stacio-\(generation)-\(UUID().uuidString.lowercased())"
        codexRequestKinds[id] = kind
        writeJSON([
            "id": id,
            "method": method,
            "params": params
        ], generation: generation)
    }

    private func sendCodexNotification(
        method: String,
        params: [String: Any],
        generation: UInt64
    ) {
        writeJSON([
            "method": method,
            "params": params
        ], generation: generation)
    }

    private func writeJSON(_ object: [String: Any], generation: UInt64) {
        guard generation == self.generation,
              didEmitTerminal == false,
              let handle = stdinPipe?.fileHandleForWriting
        else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            emit(.failed(.init(
                reasonCode: .protocolError,
                summary: "无法写入 Codex App Server：\(error.localizedDescription)"
            )), generation: generation)
            terminateProcess()
        }
    }

    private func handleTermination(status: Int32, generation: UInt64) {
        guard generation == self.generation else { return }
        if stdoutBuffer.isEmpty == false,
           let line = String(data: stdoutBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           line.isEmpty == false {
            stdoutBuffer.removeAll()
            consumeJSONLine(line, generation: generation)
        }
        let wasCancelled = cancelRequested
        let answer: String
        switch configuration.structuredProtocol {
        case .jsonl:
            answer = claudeState.answer
        case .rpc:
            answer = codexState.answer
        case .acp, .none:
            answer = ""
        }
        cleanupProcess()
        guard didEmitTerminal == false else { return }
        if wasCancelled {
            emit(.cancelled, generation: generation)
        } else if status == 0, answer.isEmpty == false {
            emit(.completed(answer), generation: generation)
        } else {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = detail.isEmpty
                ? "\(configuration.displayName) 已退出（状态码 \(status)），但未返回完整结果。"
                : "\(configuration.displayName) 已退出：\(String(detail.prefix(1_024)))"
            emit(.failed(.init(
                reasonCode: status == 0 ? .protocolError : .runtimeStartFailed,
                summary: summary
            )), generation: generation)
        }
    }

    private func emit(_ event: StructuredLocalAgentRuntimeEvent, generation: UInt64) {
        guard generation == self.generation,
              didEmitTerminal == false
        else { return }
        if event.isTerminal {
            didEmitTerminal = true
        }
        eventHandler?(event)
    }

    private func terminateProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func cleanupProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private static func idString(_ value: Any?) -> String? {
        StructuredLocalAgentRuntimeParser.string(value)
    }
}
