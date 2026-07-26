import Foundation
import Network
import WebKit

public final class RemoteFileOnlineMediaRegistry: @unchecked Sendable {
    public static let shared = RemoteFileOnlineMediaRegistry()
    public static let scheme = "stacio-remote-media"

    private let lock = NSLock()
    private var sources: [String: RemoteFileOnlineMediaSource] = [:]
    private let playbackServerLock = NSLock()
    private var playbackServer: RemoteFileLoopbackHTTPServer?

    private init() {}

    public func register(
        fileName: String,
        mimeType: String,
        byteCount: UInt64,
        onInvalidate: @escaping @Sendable () -> Void = {},
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    ) -> URL {
        let token = storeSource(
            fileName: fileName,
            mimeType: mimeType,
            byteCount: byteCount,
            responseMode: .bounded,
            onInvalidate: onInvalidate,
            reader: reader
        )
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        components.percentEncodedPath = "/" + encodedFileName
        if let url = components.url {
            return url
        }

        var fallbackComponents = URLComponents()
        fallbackComponents.scheme = Self.scheme
        fallbackComponents.host = token
        fallbackComponents.path = "/media"
        if let url = fallbackComponents.url {
            return url
        }
        return URL(fileURLWithPath: "/stacio-remote-media/\(token)")
    }

    public func registerForPlayback(
        fileName: String,
        mimeType: String,
        byteCount: UInt64,
        onInvalidate: @escaping @Sendable () -> Void = {},
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    ) throws -> URL {
        let token = storeSource(
            fileName: fileName,
            mimeType: mimeType,
            byteCount: byteCount,
            responseMode: .bounded,
            onInvalidate: onInvalidate,
            reader: reader
        )
        do {
            return try loopbackPlaybackServer().url(token: token, fileName: fileName)
        } catch {
            removeSource(token: token)
            throw error
        }
    }

    public func registerForStreaming(
        fileName: String,
        mimeType: String,
        byteCount: UInt64,
        onInvalidate: @escaping @Sendable () -> Void = {},
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    ) throws -> URL {
        let token = storeSource(
            fileName: fileName,
            mimeType: mimeType,
            byteCount: byteCount,
            responseMode: .completeStreaming,
            onInvalidate: onInvalidate,
            reader: reader
        )
        do {
            return try loopbackPlaybackServer().url(token: token, fileName: fileName)
        } catch {
            removeSource(token: token)
            throw error
        }
    }

    public func unregister(url: URL) {
        guard let token = token(for: url) else { return }
        removeSource(token: token)
    }

    func source(for url: URL) -> RemoteFileOnlineMediaSource? {
        guard url.scheme == Self.scheme,
              let token = url.host,
              token.isEmpty == false
        else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return sources[token]
    }

    private func source(token: String) -> RemoteFileOnlineMediaSource? {
        lock.lock()
        defer { lock.unlock() }
        return sources[token]
    }

    private func storeSource(
        fileName: String,
        mimeType: String,
        byteCount: UInt64,
        responseMode: RemoteFileOnlineMediaResponseMode,
        onInvalidate: @escaping @Sendable () -> Void,
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    ) -> String {
        let token = UUID().uuidString
        lock.lock()
        sources[token] = RemoteFileOnlineMediaSource(
            token: token,
            fileName: fileName,
            mimeType: mimeType,
            byteCount: byteCount,
            responseMode: responseMode,
            onInvalidate: onInvalidate,
            reader: reader
        )
        lock.unlock()
        return token
    }

    private func removeSource(token: String) {
        lock.lock()
        let source = sources.removeValue(forKey: token)
        lock.unlock()
        source?.invalidate()
    }

    private func token(for url: URL) -> String? {
        if url.scheme == Self.scheme {
            return url.host
        }
        guard url.scheme == "http", url.host == RemoteFileLoopbackHTTPServer.host else {
            return nil
        }
        return url.pathComponents.dropFirst().first
    }

    private func loopbackPlaybackServer() throws -> RemoteFileLoopbackHTTPServer {
        playbackServerLock.lock()
        defer { playbackServerLock.unlock() }
        if let playbackServer {
            return playbackServer
        }
        let server = try RemoteFileLoopbackHTTPServer { [weak self] token in
            self?.source(token: token)
        }
        playbackServer = server
        return server
    }
}

fileprivate enum RemoteFileOnlineMediaResponseMode: Sendable {
    case bounded
    case completeStreaming
}

private final class RemoteFileOnlineMediaSourceState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var onInvalidate: (@Sendable () -> Void)?

    init(onInvalidate: @escaping @Sendable () -> Void) {
        self.onInvalidate = onInvalidate
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        let onInvalidate = self.onInvalidate
        self.onInvalidate = nil
        lock.unlock()
        onInvalidate?()
    }
}

struct RemoteFileOnlineMediaSource: @unchecked Sendable {
    fileprivate static let maximumReadLength: UInt64 = 256 * 1_024
    fileprivate static let maximumResponseLength: UInt64 = 1 * 1_024 * 1_024

    let token: String
    let fileName: String
    let mimeType: String
    let byteCount: UInt64
    private let responseMode: RemoteFileOnlineMediaResponseMode
    let reader: @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    private let state: RemoteFileOnlineMediaSourceState

    fileprivate init(
        token: String,
        fileName: String,
        mimeType: String,
        byteCount: UInt64,
        responseMode: RemoteFileOnlineMediaResponseMode,
        onInvalidate: @escaping @Sendable () -> Void,
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    ) {
        self.token = token
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.responseMode = responseMode
        self.reader = reader
        self.state = RemoteFileOnlineMediaSourceState(onInvalidate: onInvalidate)
    }

    fileprivate var streamsCompleteResponse: Bool {
        responseMode == .completeStreaming
    }

    fileprivate var isActive: Bool {
        state.isActive
    }

    fileprivate func invalidate() {
        state.invalidate()
    }

    fileprivate func readChunk(
        offset: UInt64,
        byteCount: UInt64,
        shouldContinue: () -> Bool
    ) throws -> Data? {
        guard isActive, shouldContinue() else { return nil }
        let requestedLength = min(byteCount, Self.maximumReadLength)
        let rawChunk = try reader(offset, requestedLength)
        guard isActive, shouldContinue() else { return nil }
        return rawChunk.count > Int(requestedLength)
            ? Data(rawChunk.prefix(Int(requestedLength)))
            : rawChunk
    }

    fileprivate func readChunks(
        offset: UInt64,
        byteCount: UInt64,
        shouldContinue: () -> Bool
    ) throws -> [Data] {
        var chunks: [Data] = []
        var currentOffset = offset
        var remaining = byteCount
        while remaining > 0 {
            let requestedLength = min(remaining, Self.maximumReadLength)
            guard let chunk = try readChunk(
                offset: currentOffset,
                byteCount: requestedLength,
                shouldContinue: shouldContinue
            ) else { break }
            guard chunk.isEmpty == false else { break }
            chunks.append(chunk)
            currentOffset += UInt64(chunk.count)
            remaining -= UInt64(chunk.count)
            if UInt64(chunk.count) < requestedLength {
                break
            }
        }
        return chunks
    }
}

public final class RemoteFileOnlineMediaSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let shared = RemoteFileOnlineMediaSchemeHandler(registry: .shared)

    private let registry: RemoteFileOnlineMediaRegistry
    private let queue = DispatchQueue(label: "Stacio.RemoteMediaScheme", qos: .userInitiated, attributes: .concurrent)
    private let activeTasksLock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    init(registry: RemoteFileOnlineMediaRegistry) {
        self.registry = registry
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let source = registry.source(for: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        markTaskActive(urlSchemeTask)
        let requestedRange = Self.byteRange(
            from: urlSchemeTask.request.value(forHTTPHeaderField: "Range"),
            sourceByteCount: source.byteCount
        )
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.markTaskFinished(urlSchemeTask)
            }
            do {
                let offset = requestedRange?.offset ?? 0
                guard offset < source.byteCount || source.byteCount == 0 else {
                    guard self.isTaskActive(urlSchemeTask) else { return }
                    urlSchemeTask.didReceive(Self.unsatisfiableRangeResponse(for: url, source: source))
                    urlSchemeTask.didFinish()
                    return
                }
                let remaining = source.byteCount >= offset ? source.byteCount - offset : 0
                let responseLength: UInt64
                if let requestedRange {
                    responseLength = min(
                        requestedRange.length ?? Self.maximumResponseLength,
                        remaining,
                        Self.maximumResponseLength
                    )
                } else {
                    responseLength = min(remaining, Self.maximumResponseLength)
                }
                let chunks = try source.readChunks(
                    offset: offset,
                    byteCount: responseLength,
                    shouldContinue: { self.isTaskActive(urlSchemeTask) }
                )
                guard source.isActive else { return }
                let deliveredByteCount = chunks.reduce(UInt64(0)) { $0 + UInt64($1.count) }
                let response = Self.response(
                    for: url,
                    source: source,
                    offset: offset,
                    byteCount: deliveredByteCount,
                    isPartial: requestedRange != nil || responseLength < remaining
                )
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didReceive(response)
                for chunk in chunks {
                    guard source.isActive, self.isTaskActive(urlSchemeTask) else { return }
                    urlSchemeTask.didReceive(chunk)
                }
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didFinish()
            } catch {
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        markTaskFinished(urlSchemeTask)
    }

    private func markTaskActive(_ task: WKURLSchemeTask) {
        activeTasksLock.lock()
        activeTasks.insert(ObjectIdentifier(task))
        activeTasksLock.unlock()
    }

    private func markTaskFinished(_ task: WKURLSchemeTask) {
        activeTasksLock.lock()
        activeTasks.remove(ObjectIdentifier(task))
        activeTasksLock.unlock()
    }

    private func isTaskActive(_ task: WKURLSchemeTask) -> Bool {
        activeTasksLock.lock()
        defer { activeTasksLock.unlock() }
        return activeTasks.contains(ObjectIdentifier(task))
    }

    private static func response(
        for url: URL,
        source: RemoteFileOnlineMediaSource,
        offset: UInt64,
        byteCount: UInt64,
        isPartial: Bool
    ) -> URLResponse {
        let expectedLength = expectedContentLength(source.byteCount)
        guard isPartial else {
            let headers: [String: String] = [
                "Content-Type": source.mimeType,
                "Content-Length": String(byteCount),
                "Accept-Ranges": "bytes"
            ]
            return HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) ?? URLResponse(
                url: url,
                mimeType: source.mimeType,
                expectedContentLength: expectedLength,
                textEncodingName: nil
            )
        }

        let end = byteCount == 0 ? offset : offset + byteCount - 1
        let headers: [String: String] = [
            "Content-Type": source.mimeType,
            "Content-Length": String(byteCount),
            "Content-Range": "bytes \(offset)-\(end)/\(source.byteCount)",
            "Accept-Ranges": "bytes"
        ]
        return HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? URLResponse(
            url: url,
            mimeType: source.mimeType,
            expectedContentLength: expectedContentLength(byteCount),
            textEncodingName: nil
        )
    }

    private static func unsatisfiableRangeResponse(
        for url: URL,
        source: RemoteFileOnlineMediaSource
    ) -> URLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 416,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes */\(source.byteCount)",
                "Accept-Ranges": "bytes"
            ]
        ) ?? URLResponse(
            url: url,
            mimeType: source.mimeType,
            expectedContentLength: 0,
            textEncodingName: nil
        )
    }

    private static func expectedContentLength(_ value: UInt64) -> Int {
        value <= UInt64(Int.max) ? Int(value) : -1
    }

    private static let maximumResponseLength = RemoteFileOnlineMediaSource.maximumResponseLength

    fileprivate static func byteRange(
        from header: String?,
        sourceByteCount: UInt64
    ) -> (offset: UInt64, length: UInt64?)? {
        guard let header,
              header.hasPrefix("bytes=")
        else {
            return nil
        }
        let body = header.dropFirst("bytes=".count)
        guard let separator = body.firstIndex(of: "-") else {
            return nil
        }
        let startText = body[..<separator]
        let endText = body[body.index(after: separator)...]
        if startText.isEmpty {
            guard let suffixLength = UInt64(endText),
                  suffixLength > 0
            else {
                return nil
            }
            if suffixLength >= sourceByteCount {
                return (0, sourceByteCount)
            }
            return (sourceByteCount - suffixLength, suffixLength)
        }
        guard let start = UInt64(startText) else {
            return nil
        }
        guard let end = UInt64(endText) else {
            return (start, nil)
        }
        guard end >= start else {
            return nil
        }
        return (start, end - start + 1)
    }
}

private enum RemoteFileLoopbackHTTPServerError: Error, LocalizedError {
    case invalidLoopbackAddress
    case startupFailed(String)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidLoopbackAddress:
            return "无法初始化远端媒体回环地址。"
        case .startupFailed(let message):
            return "远端媒体服务启动失败：\(message)"
        case .startupTimedOut:
            return "远端媒体服务启动超时。"
        }
    }
}

private final class RemoteFileLoopbackHTTPServer: @unchecked Sendable {
    static let host = "127.0.0.1"

    private let listener: NWListener
    private var port: NWEndpoint.Port?
    private let sourceProvider: @Sendable (String) -> RemoteFileOnlineMediaSource?
    private let listenerQueue = DispatchQueue(label: "Stacio.RemoteMediaHTTP.Listener", qos: .userInitiated)
    private let workerQueue = DispatchQueue(label: "Stacio.RemoteMediaHTTP.Reader", qos: .userInitiated, attributes: .concurrent)
    private let connectionsLock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(sourceProvider: @escaping @Sendable (String) -> RemoteFileOnlineMediaSource?) throws {
        self.sourceProvider = sourceProvider
        guard let loopback = IPv4Address(Self.host) else {
            throw RemoteFileLoopbackHTTPServerError.invalidLoopbackAddress
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
        listener = try NWListener(using: parameters)
        port = nil

        let ready = DispatchSemaphore(value: 0)
        let startupLock = NSLock()
        var startupError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupLock.lock()
                startupError = error
                startupLock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: listenerQueue)
        guard ready.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw RemoteFileLoopbackHTTPServerError.startupTimedOut
        }
        startupLock.lock()
        let capturedError = startupError
        startupLock.unlock()
        if let capturedError {
            listener.cancel()
            throw RemoteFileLoopbackHTTPServerError.startupFailed(capturedError.localizedDescription)
        }
        guard let readyPort = listener.port else {
            listener.cancel()
            throw RemoteFileLoopbackHTTPServerError.startupFailed("未分配监听端口")
        }
        port = readyPort
    }

    deinit {
        listener.cancel()
        connectionsLock.lock()
        let activeConnections = Array(connections.values)
        connections.removeAll()
        connectionsLock.unlock()
        activeConnections.forEach { $0.cancel() }
    }

    func url(token: String, fileName: String) throws -> URL {
        guard let port else {
            throw RemoteFileLoopbackHTTPServerError.startupFailed("未分配监听端口")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = Self.host
        components.port = Int(port.rawValue)
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media"
        components.percentEncodedPath = "/\(token)/\(encodedName)"
        guard let url = components.url else {
            throw RemoteFileLoopbackHTTPServerError.startupFailed("无法生成媒体地址")
        }
        return url
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connectionsLock.lock()
        connections[identifier] = connection
        connectionsLock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveRequest(from: connection, accumulated: Data())
            case .failed, .cancelled:
                self.finish(connection)
            default:
                break
            }
        }
        connection.start(queue: listenerQueue)
    }

    private func receiveRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var requestData = accumulated
            if let data {
                requestData.append(data)
            }
            if let headerEnd = requestData.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                self.monitorDisconnect(from: connection)
                self.handleRequest(Data(requestData[..<headerEnd]), from: connection)
                return
            }
            if requestData.count > 64 * 1_024 {
                self.send(status: 431, reason: "Request Header Fields Too Large", headers: [:], body: Data(), to: connection)
                return
            }
            if error != nil || isComplete {
                self.send(status: 400, reason: "Bad Request", headers: [:], body: Data(), to: connection)
                return
            }
            self.receiveRequest(from: connection, accumulated: requestData)
        }
    }

    private func monitorDisconnect(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak connection] _, _, isComplete, error in
            guard let self, let connection, self.isConnectionActive(connection) else { return }
            if error != nil || isComplete {
                self.finish(connection)
            } else {
                self.monitorDisconnect(from: connection)
            }
        }
    }

    private func handleRequest(_ data: Data, from connection: NWConnection) {
        guard let request = Self.parseRequest(data) else {
            send(status: 400, reason: "Bad Request", headers: [:], body: Data(), to: connection)
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            send(status: 405, reason: "Method Not Allowed", headers: ["Allow": "GET, HEAD"], body: Data(), to: connection)
            return
        }
        guard let token = Self.token(fromRequestTarget: request.target),
              let source = sourceProvider(token)
        else {
            send(status: 404, reason: "Not Found", headers: [:], body: Data(), to: connection)
            return
        }

        let rangeHeader = request.headers["range"]
        let requestedRange = RemoteFileOnlineMediaSchemeHandler.byteRange(
            from: rangeHeader,
            sourceByteCount: source.byteCount
        )
        let offset = requestedRange?.offset ?? 0
        guard offset < source.byteCount || source.byteCount == 0 else {
            send(
                status: 416,
                reason: "Range Not Satisfiable",
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes */\(source.byteCount)"
                ],
                body: Data(),
                to: connection
            )
            return
        }

        let commonHeaders = [
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
            "Content-Type": source.mimeType,
            "X-Content-Type-Options": "nosniff"
        ]
        if request.method == "HEAD" {
            var headers = commonHeaders
            headers["Content-Length"] = String(source.byteCount)
            send(status: 200, reason: "OK", headers: headers, body: Data(), to: connection)
            return
        }

        if source.streamsCompleteResponse, requestedRange == nil {
            streamCompleteResponse(
                source: source,
                headers: commonHeaders,
                to: connection
            )
            return
        }

        let remaining = source.byteCount >= offset ? source.byteCount - offset : 0
        let responseLength: UInt64
        if let requestedRange {
            responseLength = min(
                requestedRange.length ?? RemoteFileOnlineMediaSource.maximumResponseLength,
                remaining,
                RemoteFileOnlineMediaSource.maximumResponseLength
            )
        } else {
            responseLength = min(remaining, RemoteFileOnlineMediaSource.maximumResponseLength)
        }
        var headers = commonHeaders
        headers["Content-Length"] = String(responseLength)
        let isPartialResponse = requestedRange != nil || responseLength < remaining
        if isPartialResponse {
            let end = responseLength == 0 ? offset : offset + responseLength - 1
            headers["Content-Range"] = "bytes \(offset)-\(end)/\(source.byteCount)"
        }
        streamResponse(
            source: source,
            status: isPartialResponse ? 206 : 200,
            reason: isPartialResponse ? "Partial Content" : "OK",
            headers: headers,
            offset: offset,
            byteCount: responseLength,
            to: connection
        )
    }

    private func streamCompleteResponse(
        source: RemoteFileOnlineMediaSource,
        headers: [String: String],
        to connection: NWConnection
    ) {
        var fields = headers
        fields["Content-Length"] = String(source.byteCount)
        streamResponse(
            source: source,
            status: 200,
            reason: "OK",
            headers: fields,
            offset: 0,
            byteCount: source.byteCount,
            to: connection
        )
    }

    private func streamResponse(
        source: RemoteFileOnlineMediaSource,
        status: Int,
        reason: String,
        headers: [String: String],
        offset: UInt64,
        byteCount: UInt64,
        to connection: NWConnection
    ) {
        guard source.isActive, isConnectionActive(connection) else { return }
        var fields = headers
        fields["Connection"] = "close"
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"
        let isEmpty = byteCount == 0
        connection.send(
            content: Data(response.utf8),
            contentContext: isEmpty ? .finalMessage : .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                guard error == nil, source.isActive, self.isConnectionActive(connection) else {
                    self.finish(connection)
                    return
                }
                if isEmpty {
                    self.finish(connection)
                } else {
                    self.streamNextChunk(
                        source: source,
                        offset: offset,
                        remainingByteCount: byteCount,
                        to: connection
                    )
                }
            }
        )
    }

    private func streamNextChunk(
        source: RemoteFileOnlineMediaSource,
        offset: UInt64,
        remainingByteCount: UInt64,
        to connection: NWConnection
    ) {
        workerQueue.async { [weak self, weak connection] in
            guard let self,
                  let connection,
                  source.isActive,
                  self.isConnectionActive(connection),
                  offset < source.byteCount,
                  remainingByteCount > 0
            else {
                if let self, let connection {
                    self.finish(connection)
                }
                return
            }
            do {
                guard let chunk = try source.readChunk(
                    offset: offset,
                    byteCount: min(source.byteCount - offset, remainingByteCount),
                    shouldContinue: { [weak self, weak connection] in
                        guard let self, let connection else { return false }
                        return source.isActive && self.isConnectionActive(connection)
                    }
                ), chunk.isEmpty == false else {
                    self.finish(connection)
                    return
                }
                guard source.isActive, self.isConnectionActive(connection) else {
                    self.finish(connection)
                    return
                }
                let nextOffset = offset + UInt64(chunk.count)
                let nextRemainingByteCount = remainingByteCount - min(
                    UInt64(chunk.count),
                    remainingByteCount
                )
                let isComplete = nextRemainingByteCount == 0 || nextOffset >= source.byteCount
                connection.send(
                    content: chunk,
                    contentContext: isComplete ? .finalMessage : .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection else { return }
                        guard error == nil,
                              source.isActive,
                              self.isConnectionActive(connection)
                        else {
                            self.finish(connection)
                            return
                        }
                        if isComplete {
                            self.finish(connection)
                        } else {
                            self.streamNextChunk(
                                source: source,
                                offset: nextOffset,
                                remainingByteCount: nextRemainingByteCount,
                                to: connection
                            )
                        }
                    }
                )
            } catch {
                self.finish(connection)
            }
        }
    }

    private func send(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        to connection: NWConnection
    ) {
        var fields = headers
        fields["Connection"] = "close"
        fields["Content-Length"] = fields["Content-Length"] ?? String(body.count)
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(
            content: payload,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] _ in
                guard let self, let connection else { return }
                self.finish(connection)
            }
        )
    }

    private func finish(_ connection: NWConnection) {
        connectionsLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connectionsLock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func isConnectionActive(_ connection: NWConnection) -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections[ObjectIdentifier(connection)] != nil
    }

    private static func parseRequest(_ data: Data) -> (method: String, target: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let requestParts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return (String(requestParts[0]).uppercased(), String(requestParts[1]), headers)
    }

    private static func token(fromRequestTarget target: String) -> String? {
        guard let components = URLComponents(string: "http://\(host)\(target)"),
              let token = components.path.split(separator: "/").first,
              token.isEmpty == false
        else { return nil }
        return String(token)
    }
}
