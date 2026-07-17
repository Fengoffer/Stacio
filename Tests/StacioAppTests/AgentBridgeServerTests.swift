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

    func testServerKeepsFollowSocketOpenUntilDeferredTerminalResultArrives() throws {
        let socketPath = "/tmp/stacio-agent-follow-\(UUID().uuidString).sock"
        let handler = DeferredAgentBridgeRequestHandler()
        let server = AgentBridgeServer(handler: handler, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let receivedLines = LockedAgentBridgeLines()
        let finished = expectation(description: "follow socket closes after terminal result")

        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-deferred",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 99),
                action: .runCommand(
                    AgentRunCommandRequest(target: .currentTerminal, command: "uptime", follow: true)
                )
            )
            try? AgentBridgeSocketClient(socketPath: socketPath).send(request: request) { line in
                receivedLines.append(line)
            }
        }

        wait(for: [finished], timeout: 2)
        let events = receivedLines.snapshot.compactMap { line -> AgentTraceEvent? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AgentTraceEvent.self, from: data)
        }

        XCTAssertEqual(events.map(\.state), [.running, .completed])
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "up 2 days")
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

@MainActor
private final class DeferredAgentBridgeRequestHandler: AgentBridgeRequestHandling {
    func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        []
    }

    func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void,
        completion: @escaping @MainActor () -> Void
    ) throws {
        emit(
            AgentTraceEvent(
                requestID: request.id,
                state: .running,
                message: "命令已在终端执行",
                redactedCommand: "uptime"
            )
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            emit(
                AgentTraceEvent(
                    requestID: request.id,
                    state: .completed,
                    message: "本次命令已完成：up 2 days",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "up 2 days"]
                )
            )
            completion()
        }
    }
}

private final class LockedAgentBridgeLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
