import StacioAgentBridge
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class AgentRealtimeFollowTests: XCTestCase {
    func testFollowStreamWaitsForBroadcastOutputBeforeCompletingVisibleTerminalCommand() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-follow",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "uname -a",
                    follow: true
                )
            )
        )
        var streamed: [AgentTraceEvent] = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("Darwin dev 25.0\n".utf8))
        }
        let events = try coordinator.runCommand(request, emit: { streamed.append($0) })

        XCTAssertEqual(events.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput, .completed])
        XCTAssertEqual(streamed.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput, .completed])
        XCTAssertEqual(terminal.sentInput, ["uname -a\n"])
        XCTAssertEqual(terminal.traceStates, [.queued, .approved, .typing, .running, .waitingForOutput, .completed])
        XCTAssertEqual(events.first(where: { $0.state == .waitingForOutput })?.metadata?["terminalOutputSummary"], "Darwin dev 25.0")
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "Darwin dev 25.0")
        XCTAssertTrue(terminal.traceSnapshot.contains("本次命令已完成"))
    }

    func testLongRunningVisibleCommandDoesNotCompleteFromIdleOutput() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.05)
        )
        let request = AgentBridgeRequest(
            id: "req-long",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "tail -f /var/log/system.log",
                    follow: true
                )
            )
        )
        var streamed: [AgentTraceEvent] = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("line 1\n".utf8))
        }
        let events = try coordinator.runCommand(request, emit: { streamed.append($0) })

        XCTAssertEqual(events.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput, .waitingForOutput])
        XCTAssertEqual(streamed.last?.state, .waitingForOutput)
        XCTAssertEqual(events.first(where: { $0.metadata?["completionConfidence"] == "streaming" })?.metadata?["terminalOutputSummary"], "line 1")
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "manualRequired")
        XCTAssertNil(events.last?.metadata?["terminalOutputSummary"])
        XCTAssertFalse(terminal.traceSnapshot.contains("本次命令已完成"))
    }

    func testUserInputDuringVisibleCommandMarksObservationAmbiguous() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-mixed",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "pwd",
                    follow: true
                )
            )
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("/srv/app\n".utf8))
            hub.publishUserInput(runtimeID: "term_1", bytes: Array("whoami\n".utf8))
            hub.publishOutput(runtimeID: "term_1", bytes: Array("deploy\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .waitingForOutput)
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "ambiguousUserInput")
        XCTAssertNil(events.last?.metadata?["terminalOutputSummary"])
        XCTAssertFalse(events.contains { $0.state == .completed })
        XCTAssertFalse(events.last?.message.contains("deploy") == true)
    }

    func testVisibleCommandIgnoresBroadcastOutputBeforeAICommandBoundary() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        terminal.onSendInput = {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("stale user output\n".utf8))
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-boundary",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "pwd",
                    follow: true
                )
            )
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("/srv/app\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "/srv/app")
        XCTAssertFalse(events.contains { $0.metadata?["terminalOutputSummary"]?.contains("stale user output") == true })
    }
}

@MainActor
private final class RealtimeFollowRecordingTerminalTarget: AgentTerminalTarget {
    let runtimeID: String
    let agentTitle: String
    let agentLiveSessionContext: TunnelLiveSessionContext? = nil
    var onSendInput: (() -> Void)?
    private(set) var sentInput: [String] = []
    private(set) var traceEvents: [AgentTraceEvent] = []

    init(runtimeID: String, agentTitle: String) {
        self.runtimeID = runtimeID
        self.agentTitle = agentTitle
    }

    func appendAgentTrace(_ event: AgentTraceEvent) {
        traceEvents.append(event)
    }

    func sendInput(_ bytes: [UInt8]) {
        sentInput.append(String(decoding: bytes, as: UTF8.self))
        onSendInput?()
    }

    var traceStates: [AgentTraceState] {
        traceEvents.map(\.state)
    }

    var traceSnapshot: String {
        traceEvents
            .map { "\($0.state.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }
}

@MainActor
private struct RealtimeFollowStaticTerminalResolver: AgentTerminalResolving {
    let target: AgentTerminalTarget

    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        self.target
    }
}

private struct RealtimeFollowAllowingAuthorizer: AgentActionAuthorizing {
    func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        false
    }

    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "allowed by policy",
            risk: AgentActionClassifier.risk(forCommand: command),
            requiredUserConfirmation: false
        )
    }
}
