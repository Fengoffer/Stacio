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
    private struct PeerCredentials {
        let processID: Int32
        let processGroupID: Int32
        let userID: uid_t
    }

    private let handler: AgentBridgeRequestHandling
    private let socketPath: String
    private let localAgentCapabilityRegistry: LocalAgentCapabilityRegistry
    private let maximumRequestBytes: Int
    private let requestReadTimeout: TimeInterval
    #if canImport(Darwin)
    private let activeConnections = ActiveClientConnections()
    #endif
    private var listenerFD: Int32 = -1
    private var listenerThread: Thread?

    public init(
        handler: AgentBridgeRequestHandling,
        socketPath: String,
        localAgentCapabilityRegistry: LocalAgentCapabilityRegistry = .shared,
        maximumRequestBytes: Int = 1_048_576,
        requestReadTimeout: TimeInterval = 2
    ) {
        self.handler = handler
        self.socketPath = socketPath
        self.localAgentCapabilityRegistry = localAgentCapabilityRegistry
        self.maximumRequestBytes = max(1, maximumRequestBytes)
        self.requestReadTimeout = max(0.001, requestReadTimeout)
    }

    deinit {
        stop()
    }

    public func start() throws {
        #if canImport(Darwin)
        guard listenerFD < 0 else { return }
        activeConnections.beginAccepting()
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
            startAcceptLoop(
                fd: fd,
                handler: handler,
                localAgentCapabilityRegistry: localAgentCapabilityRegistry,
                maximumRequestBytes: maximumRequestBytes,
                requestReadTimeout: requestReadTimeout,
                activeConnections: activeConnections
            )
        } catch {
            close(fd)
            activeConnections.stopAll()
            unlink(socketPath)
            throw error
        }
        #else
        throw POSIXError(.ENOTSUP)
        #endif
    }

    public func stop() {
        #if canImport(Darwin)
        if listenerFD >= 0 {
            _ = shutdown(listenerFD, SHUT_RDWR)
            close(listenerFD)
            listenerFD = -1
        }
        activeConnections.stopAll()
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
    private func startAcceptLoop(
        fd: Int32,
        handler: AgentBridgeRequestHandling,
        localAgentCapabilityRegistry: LocalAgentCapabilityRegistry,
        maximumRequestBytes: Int,
        requestReadTimeout: TimeInterval,
        activeConnections: ActiveClientConnections
    ) {
        let thread = Thread {
            while Thread.current.isCancelled == false {
                let clientFD = accept(fd, nil, nil)
                guard clientFD >= 0 else {
                    break
                }
                let connection = ClientConnection(fd: clientFD)
                guard activeConnections.insert(connection) else {
                    connection.close()
                    continue
                }
                var noSigPipe: Int32 = 1
                let configured = connection.withFileDescriptor { fd in
                    setsockopt(
                        fd,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &noSigPipe,
                        socklen_t(MemoryLayout<Int32>.size)
                    ) == 0
                } ?? false
                guard configured else {
                    activeConnections.remove(connection)
                    connection.close()
                    continue
                }
                // A slow client must not serialize every Bridge request behind
                // the listener. Each accepted socket gets a bounded worker.
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.handleClient(
                        connection: connection,
                        handler: handler,
                        localAgentCapabilityRegistry: localAgentCapabilityRegistry,
                        maximumRequestBytes: maximumRequestBytes,
                        requestReadTimeout: requestReadTimeout,
                        activeConnections: activeConnections
                    )
                }
            }
        }
        thread.name = "Stacio Agent Bridge"
        thread.start()
        listenerThread = thread
    }

    private static func handleClient(
        connection: ClientConnection,
        handler: AgentBridgeRequestHandling,
        localAgentCapabilityRegistry: LocalAgentCapabilityRegistry,
        maximumRequestBytes: Int,
        requestReadTimeout: TimeInterval,
        activeConnections: ActiveClientConnections
    ) {
        var transferredToMainActor = false
        defer {
            if transferredToMainActor == false {
                activeConnections.remove(connection)
                connection.close()
            }
        }

        guard let peer = Self.peerCredentials(for: connection),
              peer.userID == geteuid()
        else {
            writeAndClose(
                connection,
                event: failedEvent(requestID: "unknown", error: AgentExecutionError.capabilityRejected)
            )
            return
        }

        // This early check rejects unmanaged peers before they can withhold a
        // newline. Attestation repeats the lookup after decoding, so a revoke
        // or root-process exit during upload still wins before dispatch.
        guard case .authorized = localAgentCapabilityRegistry.resolvePeer(
            processID: peer.processID,
            processGroupID: peer.processGroupID
        ) else {
            writeAndClose(
                connection,
                event: failedEvent(requestID: "unknown", error: AgentExecutionError.capabilityRejected)
            )
            return
        }

        guard configureSocketTimeouts(connection: connection, timeout: requestReadTimeout) else {
            writeAndClose(
                connection,
                event: failedEvent(requestID: "unknown", error: POSIXError(.EIO))
            )
            return
        }

        do {
            let data = try Self.readAll(from: connection, maximumBytes: maximumRequestBytes)
            transferredToMainActor = true
            Task { @MainActor in
                var didFinish = false
                let finish: @MainActor () -> Void = {
                    guard didFinish == false else { return }
                    didFinish = true
                    activeConnections.remove(connection)
                    connection.close()
                }
                Self.streamResponse(
                    for: data,
                    handler: handler,
                    peer: peer,
                    localAgentCapabilityRegistry: localAgentCapabilityRegistry,
                    writeLine: { line in
                        Self.writeAll(line, to: connection)
                    },
                    completion: finish
                )
            }
        } catch {
            writeAndClose(
                connection,
                event: failedEvent(requestID: "unknown", error: error)
            )
        }
    }

    private static func peerCredentials(for connection: ClientConnection) -> PeerCredentials? {
        connection.withFileDescriptor { fd in
            peerCredentials(for: fd)
        } ?? nil
    }

    private static func peerCredentials(for fd: Int32) -> PeerCredentials? {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(fd, &userID, &groupID) == 0 else { return nil }
        var processID: pid_t = 0
        var processIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            fd,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &processIDLength
        ) == 0,
        processID > 0
        else { return nil }
        let processGroupID = getpgid(processID)
        guard processGroupID > 0 else { return nil }
        return PeerCredentials(
            processID: processID,
            processGroupID: processGroupID,
            userID: userID
        )
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
        guard chmod(socketPath, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readAll(from connection: ClientConnection, maximumBytes: Int) throws -> Data {
        guard let data = try connection.withFileDescriptor({ fd in
            try readAll(from: fd, maximumBytes: maximumBytes)
        }) else {
            throw POSIXError(.ECANCELED)
        }
        return data
    }

    private static func readAll(from fd: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw POSIXError(.ETIMEDOUT)
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                return data
            }

            let chunk = buffer[..<count]
            if let newline = chunk.firstIndex(of: 0x0A) {
                let payloadCount = newline
                guard data.count + payloadCount <= maximumBytes else {
                    throw POSIXError(.EMSGSIZE)
                }
                data.append(contentsOf: chunk.prefix(payloadCount))
                return data
            }
            guard data.count + count <= maximumBytes else {
                throw POSIXError(.EMSGSIZE)
            }
            data.append(contentsOf: chunk)
        }
    }

    private static func configureSocketTimeouts(
        connection: ClientConnection,
        timeout: TimeInterval
    ) -> Bool {
        connection.withFileDescriptor { fd in
            configureSocketTimeouts(fd: fd, timeout: timeout)
        } ?? false
    }

    private static func configureSocketTimeouts(fd: Int32, timeout: TimeInterval) -> Bool {
        let boundedTimeout = max(0.001, timeout)
        let seconds = Int(boundedTimeout.rounded(.down))
        let microseconds = Int32((boundedTimeout - Double(seconds)) * 1_000_000)
        var value = timeval(tv_sec: seconds, tv_usec: microseconds)
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { return false }
        return setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0
    }

    private static func writeAndClose(_ connection: ClientConnection, event: AgentTraceEvent) {
        _ = configureSocketTimeouts(connection: connection, timeout: 1)
        writeAll(encodedLine(for: event), to: connection)
        connection.close()
    }

    @MainActor
    private static func streamResponse(
        for data: Data,
        handler: AgentBridgeRequestHandling,
        peer: PeerCredentials,
        localAgentCapabilityRegistry: LocalAgentCapabilityRegistry,
        writeLine: @escaping @MainActor (Data) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        do {
            let trimmed = data.firstIndex(of: 0x0A).map { Data(data[..<$0]) } ?? data
            let decodedRequest = try JSONDecoder().decode(AgentBridgeRequest.self, from: trimmed)
            let request = try attestedRequest(
                decodedRequest,
                peer: peer,
                localAgentCapabilityRegistry: localAgentCapabilityRegistry
            )
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

    private static func attestedRequest(
        _ request: AgentBridgeRequest,
        peer: PeerCredentials,
        localAgentCapabilityRegistry: LocalAgentCapabilityRegistry
    ) throws -> AgentBridgeRequest {
        guard request.actor.kind == .externalCLI,
              request.capabilityID == nil
        else {
            throw AgentExecutionError.capabilityRejected
        }
        switch localAgentCapabilityRegistry.resolvePeer(
            processID: peer.processID,
            processGroupID: peer.processGroupID
        ) {
        case .authorized(let capabilityID, let actorName, _):
            return AgentBridgeRequest(
                id: request.id,
                actor: AgentActor(
                    kind: .externalCLI,
                    name: actorName,
                    processID: peer.processID
                ),
                action: request.action,
                capabilityID: capabilityID
            )
        case .rejected, .unmanaged:
            throw AgentExecutionError.capabilityRejected
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

    private static func writeAll(_ data: Data, to connection: ClientConnection) {
        _ = connection.withFileDescriptor { fd in
            writeAll(data, to: fd)
        }
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

    private final class ClientConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        private var activeOperations = 0
        private var closeRequested = false

        init(fd: Int32) {
            self.fd = fd
        }

        deinit {
            close()
        }

        func withFileDescriptor<Result>(
            _ operation: (Int32) throws -> Result
        ) rethrows -> Result? {
            lock.lock()
            guard closeRequested == false, fd >= 0 else {
                lock.unlock()
                return nil
            }
            activeOperations += 1
            let activeFD = fd
            lock.unlock()

            defer { finishOperation() }
            return try operation(activeFD)
        }

        func close() {
            var fdToClose: Int32 = -1
            lock.lock()
            if closeRequested == false {
                closeRequested = true
                if fd >= 0 {
                    _ = shutdown(fd, SHUT_RDWR)
                }
            }
            if activeOperations == 0, fd >= 0 {
                fdToClose = fd
                fd = -1
            }
            lock.unlock()
            if fdToClose >= 0 {
                Darwin.close(fdToClose)
            }
        }

        private func finishOperation() {
            var fdToClose: Int32 = -1
            lock.lock()
            activeOperations -= 1
            if closeRequested, activeOperations == 0, fd >= 0 {
                fdToClose = fd
                fd = -1
            }
            lock.unlock()
            if fdToClose >= 0 {
                Darwin.close(fdToClose)
            }
        }
    }

    private final class ActiveClientConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var accepting = false
        private var connections: [ObjectIdentifier: ClientConnection] = [:]

        func beginAccepting() {
            lock.lock()
            accepting = true
            lock.unlock()
        }

        func insert(_ connection: ClientConnection) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard accepting else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }

        func remove(_ connection: ClientConnection) {
            lock.lock()
            connections.removeValue(forKey: ObjectIdentifier(connection))
            lock.unlock()
        }

        func stopAll() {
            lock.lock()
            accepting = false
            let active = Array(connections.values)
            connections.removeAll()
            lock.unlock()
            active.forEach { $0.close() }
        }
    }
    #endif
}

extension AgentExecutionCoordinator: AgentBridgeRequestHandling {
    public func handleAgentBridgeRequest(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try validateScopedBridgeAction(request)
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
        try validateScopedBridgeAction(request)
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
        try validateScopedBridgeAction(request)
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

    private func validateScopedBridgeAction(_ request: AgentBridgeRequest) throws {
        guard request.capabilityID != nil else { return }
        switch request.action {
        case .runCommand, .listSessions:
            return
        case .pauseTask, .cancelTask, .takeOverTask:
            throw AgentExecutionError.capabilityRejected
        }
    }
}

private extension Data {
    func dropLastNewline() -> Data {
        guard last == 0x0A else { return self }
        return Data(dropLast())
    }
}
