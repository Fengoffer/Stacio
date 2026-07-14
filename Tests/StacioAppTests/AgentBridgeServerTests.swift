import StacioAgentBridge
import XCTest
@testable import StacioApp

@MainActor
final class AgentBridgeServerTests: XCTestCase {
    func testServerForwardsRunRequestToExecutionCoordinator() throws {
        let handler = RecordingAgentBridgeRequestHandler()
        let server = AgentBridgeServer(handler: handler, socketPath: "/tmp/stacio-agent-test.sock")

        let request = AgentBridgeRequest(
            id: "req-1",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 99),
            action: .runCommand(
                AgentRunCommandRequest(target: .currentTerminal, command: "uptime", follow: true)
            )
        )

        let responseLines = try server.handleRequestForTesting(request)

        XCTAssertEqual(handler.requests.map(\.id), ["req-1"])
        XCTAssertTrue(responseLines.contains { $0.contains("running") })
    }

    func testServerUsesStreamingHandlerForTraceResponses() throws {
        let handler = StreamingAgentBridgeRequestHandler()
        let server = AgentBridgeServer(handler: handler, socketPath: "/tmp/stacio-agent-test.sock")

        let request = AgentBridgeRequest(
            id: "req-stream",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 99),
            action: .runCommand(
                AgentRunCommandRequest(target: .currentTerminal, command: "uptime", follow: true)
            )
        )

        let responseLines = try server.handleRequestForTesting(request)

        XCTAssertEqual(handler.streamedRequests.map(\.id), ["req-stream"])
        XCTAssertEqual(handler.bufferedRequests, [])
        XCTAssertEqual(responseLines.count, 2)
        XCTAssertTrue(responseLines[0].contains("queued"))
        XCTAssertTrue(responseLines[1].contains("running"))
    }

    func testServerStreamsListSessionsMetadataResponses() throws {
        let handler = RecordingAgentBridgeRequestHandler(events: [
            AgentTraceEvent(
                requestID: "req-sessions",
                state: .completed,
                message: "dev@example.com",
                redactedCommand: nil,
                metadata: [
                    "type": "terminalSession",
                    "runtimeID": "term_1",
                    "title": "dev@example.com"
                ]
            )
        ])
        let server = AgentBridgeServer(handler: handler, socketPath: "/tmp/stacio-agent-test.sock")

        let responseLines = try server.handleRequestForTesting(
            AgentBridgeRequest(
                id: "req-sessions",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 99),
                action: .listSessions
            )
        )

        XCTAssertEqual(responseLines.count, 1)
        XCTAssertTrue(responseLines[0].contains(#""metadata""#))
        XCTAssertTrue(responseLines[0].contains(#""runtimeID":"term_1""#))
    }
}

@MainActor
private final class RecordingAgentBridgeRequestHandler: AgentBridgeRequestHandling {
    private(set) var requests: [AgentBridgeRequest] = []
    let events: [AgentTraceEvent]

    init(events: [AgentTraceEvent]? = nil) {
        self.events = events ?? [
            AgentTraceEvent(
                requestID: "req-1",
                state: .running,
                message: "命令已在终端执行",
                redactedCommand: "uptime"
            )
        ]
    }

    func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        requests.append(request)
        return events
    }
}

@MainActor
private final class StreamingAgentBridgeRequestHandler: AgentBridgeRequestHandling {
    private(set) var streamedRequests: [AgentBridgeRequest] = []
    private(set) var bufferedRequests: [AgentBridgeRequest] = []

    func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        bufferedRequests.append(request)
        return []
    }

    func handleAgentBridgeRequest(_ request: AgentBridgeRequest, emit: @escaping @MainActor (AgentTraceEvent) -> Void) throws {
        streamedRequests.append(request)
        emit(
            AgentTraceEvent(
                requestID: request.id,
                state: .queued,
                message: "已排队",
                redactedCommand: "uptime"
            )
        )
        emit(
            AgentTraceEvent(
                requestID: request.id,
                state: .running,
                message: "命令已在终端执行",
                redactedCommand: "uptime"
            )
        )
    }
}
