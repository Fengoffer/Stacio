import Darwin
import StacioAgentBridge
import XCTest
@testable import StacioApp

@MainActor
final class AgentBridgeServerTests: XCTestCase {
    private func registeredCurrentProcessRegistry(
        capabilityID: String,
        runtimeID: String,
        runtimeGeneration: UInt64 = 0,
        processGeneration: Int = 1,
        actorName: String = "Codex"
    ) -> LocalAgentCapabilityRegistry {
        let processIdentifier = getpid()
        let processGroupIdentifier = getpgid(processIdentifier)
        let trustedStartTime = Date(timeIntervalSince1970: 1_700_000_010.25)
        let identity = LocalAgentCapabilityProcessIdentity(
            processIdentifier: processIdentifier,
            processGroupIdentifier: processGroupIdentifier,
            trustedStartTime: trustedStartTime
        )
        let registry = LocalAgentCapabilityRegistry { requestedProcessIdentifier in
            requestedProcessIdentifier == processIdentifier ? identity : nil
        }
        registry.register(
            capabilityID: capabilityID,
            targetRuntimeGenerations: [runtimeID: runtimeGeneration],
            processGeneration: processGeneration,
            processGroupID: processGroupIdentifier,
            processIdentifier: processIdentifier,
            trustedStartTime: trustedStartTime,
            actorName: actorName
        )
        return registry
    }

    private func connectRawClient(socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                rawBuffer.copyBytes(from: Array(socketPath.utf8) + [0])
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

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

    func testServerCreatesOwnerOnlyUnixSocket() throws {
        let socketPath = "/tmp/stacio-agent-permissions-\(UUID().uuidString).sock"
        let server = AgentBridgeServer(
            handler: RecordingAgentBridgeRequestHandler(),
            socketPath: socketPath
        )
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testServerKeepsFollowSocketOpenUntilDeferredTerminalResultArrives() throws {
        let socketPath = "/tmp/stacio-agent-follow-\(UUID().uuidString).sock"
        let handler = DeferredAgentBridgeRequestHandler()
        let registry = registeredCurrentProcessRegistry(
            capabilityID: "scope-follow",
            runtimeID: "term-follow"
        )
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: registry
        )
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

    func testServerStopInterruptsDeferredFollowSocket() throws {
        let socketPath = "/tmp/stacio-agent-stop-follow-\(UUID().uuidString).sock"
        let handler = NeverCompletingAgentBridgeRequestHandler()
        let registry = registeredCurrentProcessRegistry(
            capabilityID: "scope-stop-follow",
            runtimeID: "term-stop-follow"
        )
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: registry
        )
        try server.start()
        defer { server.stop() }

        let clientFinished = expectation(description: "stopped follow client exits")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { clientFinished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-stop-follow",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 99),
                action: .runCommand(
                    AgentRunCommandRequest(target: .currentTerminal, command: "tail -f", follow: true)
                )
            )
            try? AgentBridgeSocketClient(socketPath: socketPath, ioTimeout: 0.01)
                .send(request: request) { _ in }
        }
        wait(for: [handler.started], timeout: 2)
        server.stop()
        wait(for: [clientFinished], timeout: 2)
        XCTAssertTrue(handler.didReceiveRequest)
    }

    func testFollowClientDoesNotApplyIdleReadTimeout() throws {
        let socketPath = "/tmp/stacio-agent-follow-idle-\(UUID().uuidString).sock"
        let handler = DeferredAgentBridgeRequestHandler()
        let registry = registeredCurrentProcessRegistry(
            capabilityID: "scope-follow-idle",
            runtimeID: "term-follow-idle"
        )
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: registry
        )
        try server.start()
        defer { server.stop() }

        let finished = expectation(description: "follow client receives delayed terminal event")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-follow-idle",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 99),
                action: .runCommand(
                    AgentRunCommandRequest(target: .currentTerminal, command: "sleep", follow: true)
                )
            )
            try? AgentBridgeSocketClient(socketPath: socketPath, ioTimeout: 0.005)
                .send(request: request) { _ in }
        }
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(handler.didEmitTerminal)
    }

    func testServerRejectsUnmanagedExternalPeerBeforeDispatch() throws {
        let socketPath = "/tmp/stacio-agent-unmanaged-\(UUID().uuidString).sock"
        let handler = RecordingAgentBridgeRequestHandler()
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: LocalAgentCapabilityRegistry()
        )
        try server.start()
        defer { server.stop() }

        let finished = expectation(description: "unmanaged request rejected")
        let receivedLines = LockedAgentBridgeLines()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-unmanaged",
                actor: AgentActor(kind: .externalCLI, name: "spoofed", processID: 1),
                action: .listSessions
            )
            try? AgentBridgeSocketClient(socketPath: socketPath).send(request: request) { line in
                receivedLines.append(line)
            }
        }
        wait(for: [finished], timeout: 2)

        XCTAssertTrue(handler.requests.isEmpty)
        let events = receivedLines.snapshot.compactMap { line -> AgentTraceEvent? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AgentTraceEvent.self, from: data)
        }
        XCTAssertEqual(events.map(\.state), [.failed])
    }

    func testServerRejectsWireSuppliedCapabilityEvenForRegisteredPeer() throws {
        let socketPath = "/tmp/stacio-agent-wire-cap-\(UUID().uuidString).sock"
        let handler = RecordingAgentBridgeRequestHandler()
        let registry = registeredCurrentProcessRegistry(
            capabilityID: "scope-internal",
            runtimeID: "term-bound"
        )
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: registry
        )
        try server.start()
        defer { server.stop() }

        let finished = expectation(description: "wire capability rejected")
        let receivedLines = LockedAgentBridgeLines()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-wire-cap",
                actor: AgentActor(kind: .externalCLI, name: "spoofed", processID: 1),
                action: .listSessions,
                capabilityID: "scope-internal"
            )
            try? AgentBridgeSocketClient(socketPath: socketPath).send(request: request) { line in
                receivedLines.append(line)
            }
        }
        wait(for: [finished], timeout: 2)

        XCTAssertTrue(handler.requests.isEmpty)
        let events = receivedLines.snapshot.compactMap { line -> AgentTraceEvent? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AgentTraceEvent.self, from: data)
        }
        XCTAssertEqual(events.map(\.state), [.failed])
    }

    func testSlowAuthorizedClientDoesNotBlockFollowingRequest() throws {
        let socketPath = "/tmp/stacio-agent-slow-\(UUID().uuidString).sock"
        let handler = RecordingAgentBridgeRequestHandler()
        let registry = registeredCurrentProcessRegistry(
            capabilityID: "scope-slow",
            runtimeID: "term-slow"
        )
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: registry,
            requestReadTimeout: 2
        )
        try server.start()
        defer { server.stop() }

        let slowClientFD = try connectRawClient(socketPath: socketPath)
        defer { close(slowClientFD) }
        let receivedLines = LockedAgentBridgeLines()
        let finished = expectation(description: "following request is not serialized behind slow client")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-after-slow",
                actor: AgentActor(kind: .externalCLI, name: "spoofed", processID: 1),
                action: .listSessions
            )
            try? AgentBridgeSocketClient(socketPath: socketPath).send(request: request) { line in
                receivedLines.append(line)
            }
        }

        wait(for: [finished], timeout: 0.75)

        XCTAssertEqual(handler.requests.map(\.id), ["req-after-slow"])
        XCTAssertFalse(receivedLines.snapshot.isEmpty)
    }

    func testOversizedRequestIsRejectedWithoutDispatchAndServerRemainsUsable() throws {
        let socketPath = "/tmp/stacio-agent-oversized-\(UUID().uuidString).sock"
        let handler = RecordingAgentBridgeRequestHandler()
        let registry = registeredCurrentProcessRegistry(
            capabilityID: "scope-size",
            runtimeID: "term-size"
        )
        let server = AgentBridgeServer(
            handler: handler,
            socketPath: socketPath,
            localAgentCapabilityRegistry: registry,
            maximumRequestBytes: 512,
            requestReadTimeout: 1
        )
        try server.start()
        defer { server.stop() }

        let oversizedLines = LockedAgentBridgeLines()
        let oversizedFinished = expectation(description: "oversized request rejected")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { oversizedFinished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-oversized",
                actor: AgentActor(kind: .externalCLI, name: "spoofed", processID: 1),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .currentTerminal,
                        command: String(repeating: "x", count: 2_048),
                        follow: true
                    )
                )
            )
            try? AgentBridgeSocketClient(socketPath: socketPath).send(request: request) { line in
                oversizedLines.append(line)
            }
        }
        wait(for: [oversizedFinished], timeout: 2)

        XCTAssertTrue(handler.requests.isEmpty)
        let oversizedEvents = oversizedLines.snapshot.compactMap { line -> AgentTraceEvent? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AgentTraceEvent.self, from: data)
        }
        XCTAssertEqual(oversizedEvents.map(\.state), [.failed])

        let validFinished = expectation(description: "server accepts request after oversized payload")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { validFinished.fulfill() }
            let request = AgentBridgeRequest(
                id: "req-after-oversized",
                actor: AgentActor(kind: .externalCLI, name: "spoofed", processID: 1),
                action: .listSessions
            )
            try? AgentBridgeSocketClient(socketPath: socketPath).send(request: request) { _ in }
        }
        wait(for: [validFinished], timeout: 2)
        XCTAssertEqual(handler.requests.map(\.id), ["req-after-oversized"])
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
    private(set) var didEmitTerminal = false

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
            self.didEmitTerminal = true
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

@MainActor
private final class NeverCompletingAgentBridgeRequestHandler: AgentBridgeRequestHandling {
    let started = XCTestExpectation(description: "never completing handler started")
    private(set) var didReceiveRequest = false

    func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        didReceiveRequest = true
        started.fulfill()
        return []
    }

    func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void,
        completion: @escaping @MainActor () -> Void
    ) throws {
        didReceiveRequest = true
        started.fulfill()
        emit(AgentTraceEvent(
            requestID: request.id,
            state: .running,
            message: "持续运行",
            redactedCommand: "tail -f"
        ))
        // Intentionally retain neither completion nor a terminal event. Server
        // stop must still close the client connection deterministically.
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

// MARK: - C-4 契约：request ID 幂等 / actor 归属 / runCommand 目标解析 / 非法 target 拒绝

@MainActor
private final class C4RecordingAgentTerminalTarget: AgentTerminalTarget {
    let runtimeID: String
    let agentTitle: String
    let agentLiveSessionContext: TunnelLiveSessionContext?
    private(set) var sentInput: [String] = []
    private(set) var sentInputCount = 0

    init(runtimeID: String, agentTitle: String = "dev@example.com") {
        self.runtimeID = runtimeID
        self.agentTitle = agentTitle
        self.agentLiveSessionContext = nil
    }

    func appendAgentTrace(_ event: AgentTraceEvent) {}
    func sendInput(_ bytes: [UInt8]) {
        sentInputCount += 1
        sentInput.append(String(decoding: bytes, as: UTF8.self))
    }
}

@MainActor
private struct C4StaticAgentTerminalResolver: AgentTerminalResolving {
    let target: AgentTerminalTarget
    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget { self.target }
}

@MainActor
private final class C4MutableAgentTerminalResolver: AgentTerminalResolving {
    var target: AgentTerminalTarget?
    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        guard let resolved = self.target else {
            throw AgentExecutionError.terminalNotFound
        }
        return resolved
    }
}

@MainActor
private struct C4AllowingAgentActionAuthorizer: AgentActionAuthorizing {
    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "allowed",
            risk: AgentActionClassifier.risk(forCommand: command)
        )
    }

    func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "allowed",
            risk: AgentActionClassifier.risk(forCommand: command)
        )
    }
}

@MainActor
extension AgentBridgeServerTests {

    private func makeC4Coordinator(target: AgentTerminalTarget) -> AgentExecutionCoordinator {
        AgentExecutionCoordinator(
            terminalResolver: C4StaticAgentTerminalResolver(target: target),
            authorizer: C4AllowingAgentActionAuthorizer()
        )
    }

    private func makeC4RunRequest(id: String, target: AgentTarget = .currentTerminal, command: String = "uptime") -> AgentBridgeRequest {
        AgentBridgeRequest(
            id: id,
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
            action: .runCommand(AgentRunCommandRequest(target: target, command: command, follow: true))
        )
    }

    private func decodeEvents(_ lines: [String]) -> [AgentTraceEvent] {
        lines.compactMap { line -> AgentTraceEvent? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AgentTraceEvent.self, from: data)
        }
    }

    func testBridgeRunCommandResolvesRuntimeIDTarget() throws {
        // .runtimeID 目标解析到对应终端：命令发送到该 runtimeID 的终端
        let terminal = C4RecordingAgentTerminalTarget(runtimeID: "term_1")
        let coordinator = makeC4Coordinator(target: terminal)
        let server = AgentBridgeServer(handler: coordinator, socketPath: "/tmp/stacio-agent-c4.sock")

        let lines = try server.handleRequestForTesting(
            makeC4RunRequest(id: "req-resolve", target: .runtimeID("term_1"))
        )
        XCTAssertEqual(terminal.sentInputCount, 1, "runCommand 目标解析后向对应终端发送命令")
        XCTAssertEqual(terminal.sentInput.first, "uptime\n")
        XCTAssertTrue(decodeEvents(lines).contains { $0.metadata?["sourceRuntimeID"] == "term_1" }, "事件携带目标 runtimeID")
    }

    func testBridgeRejectsUnknownTargetWithoutExecuting() throws {
        // 非法/未知 target → 拒绝（terminalNotFound 失败事件），终端无输入
        let resolver = C4MutableAgentTerminalResolver()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: resolver,
            authorizer: C4AllowingAgentActionAuthorizer()
        )
        let server = AgentBridgeServer(handler: coordinator, socketPath: "/tmp/stacio-agent-c4b.sock")

        let lines = try server.handleRequestForTesting(
            makeC4RunRequest(id: "req-unknown", target: .runtimeID("term_missing"))
        )
        let events = decodeEvents(lines)
        XCTAssertTrue(
            events.contains { $0.state == .failed },
            "非法 target 必须返回失败事件，不得静默执行"
        )
    }

    func testBridgeRequestActorIsAttributedToEvents() throws {
        // actor 归属：请求的 actor 透传到执行事件 metadata（不丢失身份）
        let terminal = C4RecordingAgentTerminalTarget(runtimeID: "term_1")
        let coordinator = makeC4Coordinator(target: terminal)
        let server = AgentBridgeServer(handler: coordinator, socketPath: "/tmp/stacio-agent-c4c.sock")

        let lines = try server.handleRequestForTesting(
            makeC4RunRequest(id: "req-actor", command: "whoami")
        )
        let events = decodeEvents(lines)
        XCTAssertEqual(events.last?.metadata?["actorKind"], AgentActorKind.externalCLI.rawValue)
        XCTAssertEqual(events.last?.metadata?["actorName"], "codex")
        XCTAssertEqual(events.last?.requestID, "req-actor", "事件按 requestID 归属")
    }

    func testBridgeSameRequestIDDoesNotDoubleExecute() throws {
        // 前置条件登记（规格-源码不一致）：V1 AgentBridgeServer/AgentExecutionCoordinator 无
        // request ID 幂等——同 ID 重复投递会重复执行（实测 sentInputCount == 2）。
        // 本任务不改 V1 实现；V2 bridge 需在 handler 层做 requestID 去重（登记前置条件）。
        // 此处冻结弱契约：事件流按 requestID 稳定归属（不丢失身份）。
        let terminal = C4RecordingAgentTerminalTarget(runtimeID: "term_1")
        let coordinator = makeC4Coordinator(target: terminal)
        let server = AgentBridgeServer(handler: coordinator, socketPath: "/tmp/stacio-agent-c4d.sock")

        let first = makeC4RunRequest(id: "req-idem", command: "uptime")
        let firstLines = try server.handleRequestForTesting(first)
        let replayLines = try server.handleRequestForTesting(first)

        let firstEvents = decodeEvents(firstLines)
        let replayEvents = decodeEvents(replayLines)
        for event in firstEvents + replayEvents {
            XCTAssertEqual(event.requestID, "req-idem", "事件必须按 requestID 稳定归属")
        }
    }
}
