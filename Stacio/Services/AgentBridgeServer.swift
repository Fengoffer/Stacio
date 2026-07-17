import Foundation
import StacioAgentBridge

#if canImport(Darwin)
import Darwin
#endif

@MainActor
public protocol AgentBridgeRequestHandling {
    func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent]
    func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void
    ) throws
    func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void,
        completion: @escaping @MainActor () -> Void
    ) throws
}

@MainActor
public extension AgentBridgeRequestHandling {
    func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void
    ) throws {
        let events = try handleAgentBridgeRequest(request)
        events.forEach(emit)
    }

    func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void,
        completion: @escaping @MainActor () -> Void
    ) throws {
        try handleAgentBridgeRequest(request, emit: emit)
        completion()
    }
}

public final class AgentBridgeServer {
    private let handler: AgentBridgeRequestHandling
    private let socketPath: String
    private var listenerFD: Int32 = -1
    private var listenerThread: Thread?

    public init(handler: AgentBridgeRequestHandling, socketPath: String) {
        self.handler = handler
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    public func start() throws {
        #if canImport(Darwin)
        guard listenerFD < 0 else { return }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try bindSocket(fd, socketPath: socketPath)
            guard listen(fd, 16) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            listenerFD = fd
            startAcceptLoop(fd: fd, handler: handler)
        } catch {
            close(fd)
            throw error
        }
        #else
        throw POSIXError(.ENOTSUP)
        #endif
    }

    public func stop() {
        #if canImport(Darwin)
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
        listenerThread?.cancel()
        listenerThread = nil
        unlink(socketPath)
        #endif
    }

    @MainActor
    public func handleRequestForTesting(_ request: AgentBridgeRequest) throws -> [String] {
        var lines: [String] = []
        Self.streamResponse(
            for: request,
            handler: handler,
            writeLine: { line in
                lines.append(String(decoding: line.dropLastNewline(), as: UTF8.self))
            },
            completion: {}
        )
        return lines
    }

    #if canImport(Darwin)
    private func startAcceptLoop(fd: Int32, handler: AgentBridgeRequestHandling) {
        let thread = Thread {
            while Thread.current.isCancelled == false {
                let clientFD = accept(fd, nil, nil)
                guard clientFD >= 0 else {
                    break
                }
                let data = Self.readAll(from: clientFD)
                Task { @MainActor in
                    var didFinish = false
                    let finish: @MainActor () -> Void = {
                        guard didFinish == false else { return }
                        didFinish = true
                        close(clientFD)
                    }
                    Self.streamResponse(
                        for: data,
                        handler: handler,
                        writeLine: { line in
                            Self.writeAll(line, to: clientFD)
                        },
                        completion: finish
                    )
                }
            }
        }
        thread.name = "Stacio Agent Bridge"
        thread.start()
        listenerThread = thread
    }

    private func bindSocket(_ fd: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: Array(socketPath.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readAll(from fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
            if buffer[..<count].contains(0x0A) {
                break
            }
        }
        return data
    }

    @MainActor
    private static func streamResponse(
        for data: Data,
        handler: AgentBridgeRequestHandling,
        writeLine: @escaping @MainActor (Data) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        do {
            let trimmed = data.firstIndex(of: 0x0A).map { Data(data[..<$0]) } ?? data
            let request = try JSONDecoder().decode(AgentBridgeRequest.self, from: trimmed)
            streamResponse(
                for: request,
                handler: handler,
                writeLine: writeLine,
                completion: completion
            )
        } catch {
            writeLine(encodedLine(for: failedEvent(requestID: "unknown", error: error)))
            completion()
        }
    }

    @MainActor
    private static func streamResponse(
        for request: AgentBridgeRequest,
        handler: AgentBridgeRequestHandling,
        writeLine: @escaping @MainActor (Data) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        do {
            try handler.handleAgentBridgeRequest(
                request,
                emit: { event in
                    writeLine(encodedLine(for: event))
                },
                completion: completion
            )
        } catch {
            writeLine(encodedLine(for: failedEvent(requestID: request.id, error: error)))
            completion()
        }
    }

    private static func failedEvent(requestID: String, error: Error) -> AgentTraceEvent {
        AgentTraceEvent(
            requestID: requestID,
            state: .failed,
            message: RuntimeDiagnosticFormatter.userMessage(for: error),
            redactedCommand: nil
        )
    }

    private static func encodedLine(for event: AgentTraceEvent) -> Data {
        var line = (try? JSONEncoder().encode(event)) ?? Data()
        line.append(0x0A)
        return line
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let written = write(fd, baseAddress.advanced(by: sent), data.count - sent)
                guard written > 0 else {
                    return
                }
                sent += written
            }
        }
    }
    #endif
}

extension AgentExecutionCoordinator: AgentBridgeRequestHandling {
    public func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        switch request.action {
        case .runCommand:
            return try runCommand(request)
        case .listSessions:
            return listSessions(request)
        case .pauseTask(let requestID):
            return pauseTask(requestID: requestID).map { [$0] } ?? [
                AgentTraceEvent(
                    requestID: requestID,
                    state: .failed,
                    message: "没有找到可暂停的 AI 任务。",
                    redactedCommand: nil
                )
            ]
        case .cancelTask(let requestID):
            return cancelTask(requestID: requestID).map { [$0] } ?? [
                AgentTraceEvent(
                    requestID: requestID,
                    state: .failed,
                    message: "没有找到可取消的 AI 独立任务。",
                    redactedCommand: nil
                )
            ]
        case .takeOverTask(let requestID):
            return takeOverTask(requestID: requestID).map { [$0] } ?? [
                AgentTraceEvent(
                    requestID: requestID,
                    state: .failed,
                    message: "没有找到可接管的 AI 任务。",
                    redactedCommand: nil
                )
            ]
        }
    }

    public func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void
    ) throws {
        switch request.action {
        case .runCommand:
            _ = try runCommand(request, emit: emit)
        case .listSessions:
            listSessions(request).forEach(emit)
        case .pauseTask(let requestID):
            let events = pauseTask(requestID: requestID).map { [$0] } ?? [
                AgentTraceEvent(
                    requestID: requestID,
                    state: .failed,
                    message: "没有找到可暂停的 AI 任务。",
                    redactedCommand: nil
                )
            ]
            events.forEach(emit)
        case .cancelTask(let requestID):
            let events = cancelTask(requestID: requestID).map { [$0] } ?? [
                AgentTraceEvent(
                    requestID: requestID,
                    state: .failed,
                    message: "没有找到可取消的 AI 独立任务。",
                    redactedCommand: nil
                )
            ]
            events.forEach(emit)
        case .takeOverTask(let requestID):
            let events = takeOverTask(requestID: requestID).map { [$0] } ?? [
                AgentTraceEvent(
                    requestID: requestID,
                    state: .failed,
                    message: "没有找到可接管的 AI 任务。",
                    redactedCommand: nil
                )
            ]
            events.forEach(emit)
        }
    }

    public func handleAgentBridgeRequest(
        _ request: AgentBridgeRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void,
        completion: @escaping @MainActor () -> Void
    ) throws {
        guard case .runCommand(let commandRequest) = request.action else {
            try handleAgentBridgeRequest(request, emit: emit)
            completion()
            return
        }

        var didFinish = false
        let finishOnce: @MainActor () -> Void = {
            guard didFinish == false else { return }
            didFinish = true
            completion()
        }
        let events = try runCommand(request) { event in
            emit(event)
            if Self.shouldCloseBridgeFollowStream(for: event.state) {
                self.discardBridgeFollowStream(requestID: request.id)
                finishOnce()
            }
        }

        let continuesAsBackgroundTask = commandRequest.follow
            && events.last?.metadata?["executionMode"] == "backgroundTask"
            && events.last.map { Self.shouldCloseBridgeFollowStream(for: $0.state) } != true
        guard continuesAsBackgroundTask, didFinish == false else {
            finishOnce()
            return
        }
        registerBridgeFollowStream(
            requestID: request.id,
            emit: emit,
            completion: finishOnce
        )
    }

    private static func shouldCloseBridgeFollowStream(for state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .paused, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            return false
        }
    }
}

private extension Data {
    func dropLastNewline() -> Data {
        guard last == 0x0A else { return self }
        return Data(dropLast())
    }
}
