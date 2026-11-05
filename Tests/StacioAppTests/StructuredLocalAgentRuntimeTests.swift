import Foundation
import XCTest
@testable import StacioApp

final class StructuredLocalAgentRuntimeTests: XCTestCase {
    func testStructuredRuntimeCapabilityIsLimitedToCodexRPC() {
        XCTAssertTrue(LocalAgentRuntimeCapabilities.supportsStructuredRuntime(
            rawIdentity: LocalAgentRawIdentity.codex.rawValue,
            structuredProtocol: .rpc
        ))
        XCTAssertFalse(LocalAgentRuntimeCapabilities.supportsStructuredRuntime(
            rawIdentity: LocalAgentRawIdentity.codex.rawValue,
            structuredProtocol: .jsonl
        ))
        XCTAssertFalse(LocalAgentRuntimeCapabilities.supportsStructuredRuntime(
            rawIdentity: LocalAgentRawIdentity.claudeCode.rawValue,
            structuredProtocol: .jsonl
        ))
        XCTAssertTrue(LocalAgentRuntimeCapabilities.supportsManagedProfile(
            rawIdentity: LocalAgentRawIdentity.codex.rawValue
        ))
        XCTAssertFalse(LocalAgentRuntimeCapabilities.supportsManagedProfile(
            rawIdentity: LocalAgentRawIdentity.claudeCode.rawValue
        ))
    }

    func testClaudeParserDeduplicatesAssistantSnapshotAndCompletes() {
        var state = StructuredLocalAgentRuntimeParser.ClaudeState()

        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseClaudeJSONLine(
                #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}}"#,
                state: &state
            ),
            [.textDelta("你")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseClaudeJSONLine(
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}]}}"#,
                state: &state
            ),
            [.textDelta("好")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseClaudeJSONLine(
                #"{"type":"result","subtype":"success","result":"你好","is_error":false}"#,
                state: &state
            ),
            [.completed("你好")]
        )
    }

    func testClaudeParserMapsThinkingAndErrorsWithoutExposingUnknownPayloads() {
        var state = StructuredLocalAgentRuntimeParser.ClaudeState()
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseClaudeJSONLine(
                #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"检查服务状态"}}}"#,
                state: &state
            ),
            [.reasoningDelta("检查服务状态")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseClaudeJSONLine(
                #"{"type":"error","message":"authentication failed"}"#,
                state: &state
            ),
            [.failed(.init(reasonCode: .protocolError, summary: "authentication failed"))]
        )
    }

    func testCodexParserMapsTextReasoningAndTurnCompletion() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"检查中"}}"#,
                state: &state
            ),
            [.textDelta("检查中")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","method":"item/reasoning/summaryDelta","params":{"delta":"读取日志"}}"#,
                state: &state
            ),
            [.reasoningDelta("读取日志")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","method":"item/reasoning/summaryTextDelta","params":{"delta":"并确认端口"}}"#,
                state: &state
            ),
            [.reasoningDelta("并确认端口")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","id":"notification-id","method":"item/agentMessage/delta","params":{"delta":"仍是正常消息"}}"#,
                state: &state
            ),
            [.textDelta("仍是正常消息")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}"#,
                state: &state
            ),
            [.completed("检查中仍是正常消息")]
        )
    }

    func testCodexParserUsesGenericCompletedItemWhenNoDeltaArrived() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"type":"agentMessage","id":"item-1","text":"无增量的最终答案"}}}"#,
                state: &state
            ),
            [.textDelta("无增量的最终答案")]
        )
        XCTAssertEqual(
            StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
                #"{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}"#,
                state: &state
            ),
            [.completed("无增量的最终答案")]
        )
    }

    func testCodexParserMapsNyaTermStyleDynamicToolCallWithoutJSONRPCEnvelope() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        let events = StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
            #"{"id":42,"method":"item/tool/call","params":{"callId":"call-42","threadId":"thread-1","turnId":"turn-1","namespace":"stacio_terminal","tool":"execute_command","arguments":{"command":"uname -a","reason":"确认系统版本"}}}"#,
            state: &state
        )
        XCTAssertEqual(events, [.toolCall(.init(
            requestID: "42",
            requestIDJSON: "42",
            callID: "call-42",
            threadID: "thread-1",
            turnID: "turn-1",
            namespace: "stacio_terminal",
            tool: "execute_command",
            argumentsJSON: #"{"command":"uname -a","reason":"确认系统版本"}"#
        ))])
    }

    func testCodexParserAcceptsOmittedNamespaceForRegisteredLocalTool() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        let events = StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
            #"{"id":"tool-1","method":"item/tool/call","params":{"callId":"call-1","threadId":"thread-1","turnId":"turn-1","tool":"get_context","arguments":{}}}"#,
            state: &state
        )
        XCTAssertEqual(events, [.toolCall(.init(
            requestID: "tool-1",
            requestIDJSON: #""tool-1""#,
            callID: "call-1",
            threadID: "thread-1",
            turnID: "turn-1",
            namespace: "stacio_terminal",
            tool: "get_context",
            argumentsJSON: "{}"
        ))])
    }

    func testCodexParserRejectsDynamicToolCallWithMissingSchemaIdentity() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        let events = StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
            #"{"id":"tool-1","method":"item/tool/call","params":{"tool":"get_context","arguments":{}}}"#,
            state: &state
        )
        guard case .failed(let failure) = events.first else {
            return XCTFail("Expected an explicit protocol failure")
        }
        XCTAssertEqual(failure.reasonCode, .protocolError)
        XCTAssertTrue(failure.summary.contains("callId"))
    }

    func testCodexParserKeepsUnsupportedServerRequestActionable() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        let events = StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
            #"{"id":7,"method":"item/commandExecution/requestApproval","params":{}}"#,
            state: &state
        )
        XCTAssertEqual(events, [.serverRequest(.init(
            requestID: "7",
            requestIDJSON: "7",
            method: "item/commandExecution/requestApproval"
        ))])
    }

    func testCodexParserKeepsUnsupportedApprovalRequestActionable() {
        var state = StructuredLocalAgentRuntimeParser.CodexState()
        let events = StructuredLocalAgentRuntimeParser.parseCodexJSONLine(
            #"{"jsonrpc":"2.0","id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}"#,
            state: &state
        )
        XCTAssertEqual(events, [.serverRequest(.init(
            requestID: "approval-1",
            requestIDJSON: #""approval-1""#,
            method: "item/commandExecution/requestApproval"
        ))])
    }

    @MainActor
    func testClaudeStructuredRuntimeFailsClosedUntilToolChannelExists() throws {
        let fixture = try ScriptFixture(body: "#!/bin/sh\nexit 0\n")
        defer { fixture.cleanup() }

        let runtime = StructuredLocalAgentRuntime(
            configuration: fixture.configuration(tool: .claude, protocol: .jsonl),
            workingDirectory: AgentProcessWorkingDirectory(mode: .managedWorkspace)
        )
        let rejected = expectation(description: "Claude structured runtime rejected")
        var received: [StructuredLocalAgentRuntimeEvent] = []
        runtime.start(prompt: "status") { event in
            received.append(event)
            if case .failed(let failure) = event,
               failure.reasonCode == .configurationInvalid {
                rejected.fulfill()
            }
        }
        wait(for: [rejected], timeout: 1)
        XCTAssertEqual(received.count, 1)
    }

    @MainActor
    func testClaudeLaunchArgumentsUseDocumentedSafeDefaults() {
        let arguments = StructuredLocalAgentRuntime.launchArguments(for: .jsonl)
        XCTAssertTrue(arguments.contains("--verbose"))
        guard let permissionIndex = arguments.firstIndex(of: "--permission-mode"),
              let toolsIndex = arguments.firstIndex(of: "--tools"),
              permissionIndex + 1 < arguments.count,
              toolsIndex + 1 < arguments.count
        else {
            XCTFail("Claude safe launch flags are incomplete")
            return
        }
        XCTAssertEqual(arguments[permissionIndex + 1], "plan")
        XCTAssertEqual(arguments[toolsIndex + 1], "")
    }

    @MainActor
    func testCodexRuntimePerformsRPCHandshakeAndCompletes() throws {
        let fixture = try ScriptFixture(body: """
        #!/bin/sh
        read init_line
        init_id=$(printf '%s' "$init_line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{}}\\n' "$init_id"
        read initialized_line
        read thread_line
        thread_id=$(printf '%s' "$thread_line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"thread":{"id":"thread-1"}}}\\n' "$thread_id"
        read turn_line
        turn_id=$(printf '%s' "$turn_line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"turn":{"id":"turn-1"}}}\\n' "$turn_id"
        printf '%s\\n' '{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"healthy"}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
        sleep 1
        """)
        defer { fixture.cleanup() }

        let runtime = StructuredLocalAgentRuntime(
            configuration: fixture.configuration(tool: .codex, protocol: .rpc),
            workingDirectory: AgentProcessWorkingDirectory(mode: .managedWorkspace)
        )
        let completed = expectation(description: "Codex runtime completed")
        var received: [StructuredLocalAgentRuntimeEvent] = []
        runtime.start(prompt: "check service") { event in
            received.append(event)
            if case .completed = event {
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(received.contains(.textDelta("healthy")))
        XCTAssertEqual(received.last, .completed("healthy"))
    }

    @MainActor
    func testCodexRuntimeRespondsToDynamicToolCallAndContinuesTurn() throws {
        let fixture = try ScriptFixture(body: """
        #!/bin/sh
        read init_line
        init_id=$(printf '%s' "$init_line" | sed -E 's/.*"id":"?([^",}]+).*/\\1/')
        printf '{"id":"%s","result":{}}\\n' "$init_id"
        read initialized_line
        read thread_line
        thread_id=$(printf '%s' "$thread_line" | sed -E 's/.*"id":"?([^",}]+).*/\\1/')
        printf '{"id":"%s","result":{"thread":{"id":"thread-1"}}}\\n' "$thread_id"
        read turn_line
        turn_id=$(printf '%s' "$turn_line" | sed -E 's/.*"id":"?([^",}]+).*/\\1/')
        printf '{"id":"%s","result":{"turn":{"id":"turn-1"}}}\\n' "$turn_id"
        printf '%s\\n' '{"id":42,"method":"item/tool/call","params":{"callId":"call-42","threadId":"thread-1","turnId":"turn-1","namespace":"stacio_terminal","tool":"get_context","arguments":{}}}'
        read tool_result
        case "$tool_result" in
          *'"success":true'*) printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"after-tool"}}' ;;
          *) printf '%s\\n' '{"method":"error","params":{"message":"tool response missing"}}' ;;
        esac
        printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
        sleep 1
        """)
        defer { fixture.cleanup() }

        let runtime = StructuredLocalAgentRuntime(
            configuration: fixture.configuration(tool: .codex, protocol: .rpc),
            workingDirectory: AgentProcessWorkingDirectory(mode: .managedWorkspace)
        )
        let completed = expectation(description: "Codex runtime completed after tool")
        var received: [StructuredLocalAgentRuntimeEvent] = []
        runtime.start(prompt: "check service") { event in
            received.append(event)
            if case .toolCall(let call) = event {
                runtime.respondToToolCall(call, success: true, text: "target=local")
            }
            if case .completed = event {
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(received.contains {
            if case .toolCall(let call) = $0 {
                return call.requestID == "42" && call.tool == "get_context"
            }
            return false
        })
        XCTAssertTrue(received.contains(.textDelta("after-tool")))
        XCTAssertEqual(received.last, .completed("after-tool"))
    }
}

private struct ScriptFixture {
    let root: URL
    let executable: URL
    let environment: [String]

    init(body: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-structured-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("agent")
        try Data(body.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        environment = ["LANG=C", "PATH=/usr/bin:/bin"]
    }

    func configuration(
        tool: LocalAgentTool,
        protocol structuredProtocol: LocalAgentStructuredProtocol
    ) -> LocalAgentPassthroughConfiguration {
        LocalAgentPassthroughConfiguration(
            configurationID: "structured-\(tool.rawValue)",
            configurationRevision: 1,
            catalogID: "local-agent.\(tool.catalogRawIdentity)",
            catalogSetRevision: 1,
            descriptorRevision: 1,
            tool: tool,
            displayName: tool.displayName,
            executablePath: executable.path,
            executableIdentityDigest: "sha256:test",
            executableReferenceConfirmedAt: Date(),
            lastVerifiedAt: Date(),
            executionProfileID: "structured-\(structuredProtocol.rawValue)",
            executionProfileRevision: 1,
            structuredProtocol: structuredProtocol,
            authenticationState: .authenticated,
            authenticationEvidenceRevision: "auth-1",
            cliAuthenticationScopeDigest: "scope-1",
            cliLoginIdentityDigest: "identity-1",
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(environment),
            launchEnvironment: environment,
            supportLevel: .ga,
            explicitlyEnabled: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
