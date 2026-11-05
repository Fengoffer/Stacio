import Foundation

struct RemoteChromiumDownloadCapability: Hashable, Sendable {
    fileprivate let value: UUID
    let sourceLiveSessionContext: TunnelLiveSessionContext?

    init(
        value: UUID = UUID(),
        sourceLiveSessionContext: TunnelLiveSessionContext? = nil
    ) {
        self.value = value
        self.sourceLiveSessionContext = sourceLiveSessionContext
    }

    static func == (
        lhs: RemoteChromiumDownloadCapability,
        rhs: RemoteChromiumDownloadCapability
    ) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

public struct RemoteChromiumDownload: Equatable, Sendable {
    public let sessionLeaseID: UUID
    public let remotePath: String
    public let suggestedFilename: String
    let capability: RemoteChromiumDownloadCapability

    var sourceLiveSessionContext: TunnelLiveSessionContext? {
        capability.sourceLiveSessionContext
    }

    init(
        sessionLeaseID: UUID,
        remotePath: String,
        suggestedFilename: String,
        capability: RemoteChromiumDownloadCapability = RemoteChromiumDownloadCapability()
    ) {
        self.sessionLeaseID = sessionLeaseID
        self.remotePath = remotePath
        self.suggestedFilename = suggestedFilename
        self.capability = capability
    }

    init(
        session: RemoteChromiumRuntimeSession,
        remotePath: String,
        suggestedFilename: String
    ) {
        self.init(
            sessionLeaseID: session.leaseID,
            remotePath: remotePath,
            suggestedFilename: suggestedFilename,
            capability: session.downloadCapability
        )
    }

    public func isCanonical(for session: RemoteChromiumRuntimeSession) -> Bool {
        sessionLeaseID == session.leaseID
            && capability == session.downloadCapability
            && Self.isCanonicalRemotePath(remotePath, for: session)
    }

    static func isCanonicalRemotePath(
        _ path: String,
        for session: RemoteChromiumRuntimeSession
    ) -> Bool {
        let directory = session.remoteDownloadsDirectory
        guard directory.hasSuffix("/") == false,
              (directory as NSString).standardizingPath == directory,
              (path as NSString).standardizingPath == path
        else {
            return false
        }
        let prefix = directory + "/"
        guard path.hasPrefix(prefix) else { return false }
        let basename = String(path.dropFirst(prefix.count))
        guard basename != ".", basename != "..", basename.contains("/") == false else {
            return false
        }
        return basename.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$"#,
            options: .regularExpression
        ) != nil
    }
}

public enum ChromeDevToolsEvent: Equatable, Sendable {
    case connected
    case screencastFrame(data: Data, sessionID: Int, width: Int, height: Int)
    case loading(Bool)
    case navigationFailed(errorText: String)
    case frameNavigated(url: String)
    case navigationState(canGoBack: Bool, canGoForward: Bool)
    case downloadWillBegin(guid: String, suggestedFilename: String)
    case downloadProgress(guid: String, state: String)
    case downloadCompleted(RemoteChromiumDownload)
    case ignored
}

struct ChromeDevToolsDownloadPathTracker {
    private let remoteDownloadsDirectory: String
    private let sessionLeaseID: UUID
    private let capability: RemoteChromiumDownloadCapability
    private var suggestedFilenamesByGUID: [String: String] = [:]

    init(session: RemoteChromiumRuntimeSession) {
        self.remoteDownloadsDirectory = session.remoteDownloadsDirectory.hasSuffix("/")
            ? String(session.remoteDownloadsDirectory.dropLast())
            : session.remoteDownloadsDirectory
        self.sessionLeaseID = session.leaseID
        self.capability = session.downloadCapability
    }

    mutating func record(guid: String, suggestedFilename: String) {
        guard Self.isValidGUID(guid),
              let filename = Self.sanitizedFilename(suggestedFilename)
        else {
            return
        }
        suggestedFilenamesByGUID[guid] = filename
    }

    mutating func takeCompletedDownload(guid: String) -> RemoteChromiumDownload? {
        guard Self.isValidGUID(guid),
              let filename = suggestedFilenamesByGUID.removeValue(forKey: guid)
        else {
            return nil
        }
        return RemoteChromiumDownload(
            sessionLeaseID: sessionLeaseID,
            remotePath: remoteDownloadsDirectory + "/" + guid,
            suggestedFilename: filename,
            capability: capability
        )
    }

    mutating func discard(guid: String) {
        suggestedFilenamesByGUID.removeValue(forKey: guid)
    }

    private static func sanitizedFilename(_ value: String) -> String? {
        let filename = (value.replacingOccurrences(of: "\\", with: "/") as NSString)
            .lastPathComponent
            .unicodeScalars
            .filter { CharacterSet.controlCharacters.contains($0) == false }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard filename.isEmpty == false, filename != ".", filename != ".." else {
            return nil
        }
        return filename
    }

    private static func isValidGUID(_ value: String) -> Bool {
        guard value != ".", value != ".." else { return false }
        return value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$"#,
            options: .regularExpression
        ) != nil
    }
}

public enum ChromeDevToolsWebSocketMessage: Sendable {
    case data(Data)
    case string(String)
}

public protocol ChromeDevToolsWebSocketTransport: AnyObject {
    func resume()
    func send(data: Data, completionHandler: @escaping (Error?) -> Void)
    func receive(
        completionHandler: @escaping (Result<ChromeDevToolsWebSocketMessage, Error>) -> Void
    )
    func sendPing(completionHandler: @escaping (Error?) -> Void)
    func cancel()
}

public final class URLSessionChromeDevToolsWebSocketTransport: ChromeDevToolsWebSocketTransport {
    private let task: URLSessionWebSocketTask

    public init(webSocketURL: URL, urlSession: URLSession = .shared) {
        task = urlSession.webSocketTask(with: webSocketURL)
    }

    public func resume() {
        task.resume()
    }

    public func send(data: Data, completionHandler: @escaping (Error?) -> Void) {
        task.send(.data(data), completionHandler: completionHandler)
    }

    public func receive(
        completionHandler: @escaping (Result<ChromeDevToolsWebSocketMessage, Error>) -> Void
    ) {
        task.receive { result in
            completionHandler(
                result.map { message in
                    switch message {
                    case let .data(data):
                        return .data(data)
                    case let .string(string):
                        return .string(string)
                    @unknown default:
                        return .data(Data())
                    }
                }
            )
        }
    }

    public func sendPing(completionHandler: @escaping (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: completionHandler)
    }

    public func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

final class ChromeDevToolsEventDecoder {
    private var mainFrameID: String?

    func decode(_ data: Data) throws -> ChromeDevToolsEvent {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        return decode(object: object)
    }

    func decode(object: [String: Any]) -> ChromeDevToolsEvent {
        guard let method = object["method"] as? String,
              let parameters = object["params"] as? [String: Any]
        else {
            return .ignored
        }

        switch method {
        case "Page.screencastFrame":
            guard let encoded = parameters["data"] as? String,
                  let frameData = Data(base64Encoded: encoded),
                  let sessionID = Self.integer(parameters["sessionId"])
            else {
                return .ignored
            }
            let metadata = parameters["metadata"] as? [String: Any]
            return .screencastFrame(
                data: frameData,
                sessionID: sessionID,
                width: Self.integer(metadata?["deviceWidth"]) ?? 0,
                height: Self.integer(metadata?["deviceHeight"]) ?? 0
            )
        case "Page.frameStartedLoading":
            guard let frameID = parameters["frameId"] as? String,
                  frameID == mainFrameID
            else {
                return .ignored
            }
            return .loading(true)
        case "Page.frameStoppedLoading":
            guard let frameID = parameters["frameId"] as? String,
                  frameID == mainFrameID
            else {
                return .ignored
            }
            return .loading(false)
        case "Page.loadEventFired":
            return .loading(false)
        case "Network.loadingFailed":
            guard parameters["type"] as? String == "Document",
                  parameters["canceled"] as? Bool != true,
                  let errorText = parameters["errorText"] as? String,
                  errorText.isEmpty == false
            else {
                return .ignored
            }
            return .navigationFailed(errorText: errorText)
        case "Page.frameNavigated":
            guard let frame = parameters["frame"] as? [String: Any],
                  frame["parentId"] == nil,
                  let frameID = frame["id"] as? String,
                  let url = frame["url"] as? String
            else {
                return .ignored
            }
            mainFrameID = frameID
            return .frameNavigated(url: url)
        case "Browser.downloadProgress":
            guard let guid = parameters["guid"] as? String,
                  let state = parameters["state"] as? String
            else {
                return .ignored
            }
            return .downloadProgress(guid: guid, state: state)
        case "Browser.downloadWillBegin":
            guard let guid = parameters["guid"] as? String,
                  let suggestedFilename = parameters["suggestedFilename"] as? String
            else {
                return .ignored
            }
            return .downloadWillBegin(guid: guid, suggestedFilename: suggestedFilename)
        default:
            return .ignored
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        return nil
    }
}

private struct ChromeDevToolsResponse: Sendable {
    let id: Int
    let errorMessage: String?
    let navigationErrorText: String?
    let navigationIndex: Int?
    let navigationEntryCount: Int?
    let stringValue: String?
}

private enum ChromeDevToolsDecodedMessage: Sendable {
    case response(ChromeDevToolsResponse)
    case event(ChromeDevToolsEvent)
}

private final class ChromeDevToolsMessageProcessor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let eventDecoder = ChromeDevToolsEventDecoder()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func process(
        _ data: Data,
        completion: @escaping (Result<ChromeDevToolsDecodedMessage, Error>) -> Void
    ) {
        queue.async { [eventDecoder] in
            let result = Result { () -> ChromeDevToolsDecodedMessage in
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .event(.ignored)
                }
                if let responseID = Self.integer(object["id"]) {
                    let errorMessage = (object["error"] as? [String: Any])?["message"] as? String
                    let responseResult = object["result"] as? [String: Any]
                    let navigationErrorText = responseResult?["errorText"] as? String
                    let currentIndex = Self.integer(responseResult?["currentIndex"])
                    let entryCount = (responseResult?["entries"] as? [[String: Any]])?.count
                    let stringValue = (responseResult?["result"] as? [String: Any])?["value"] as? String
                    return .response(
                        ChromeDevToolsResponse(
                            id: responseID,
                            errorMessage: errorMessage,
                            navigationErrorText: navigationErrorText,
                            navigationIndex: currentIndex,
                            navigationEntryCount: entryCount,
                            stringValue: stringValue
                        )
                    )
                }
                return .event(eventDecoder.decode(object: object))
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        return nil
    }
}

@MainActor
public protocol ChromeDevToolsControlling: AnyObject {
    var onEvent: ((ChromeDevToolsEvent) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    func connect()
    func disconnect()
    func send(method: String, parameters: [String: Any])
    func evaluateString(
        _ expression: String,
        completion: @escaping (Result<String?, Error>) -> Void
    )
}

public extension ChromeDevToolsControlling {
    func evaluateString(
        _ expression: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        send(
            method: "Runtime.evaluate",
            parameters: ["expression": expression, "returnByValue": true, "awaitPromise": true]
        )
        completion(.success(nil))
    }
}

@MainActor
public final class ChromeDevToolsClient: ChromeDevToolsControlling {
    public var onEvent: ((ChromeDevToolsEvent) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let webSocketTransport: ChromeDevToolsWebSocketTransport
    private let remoteDownloadsDirectory: String
    private let startupTimeout: TimeInterval
    private let messageProcessor: ChromeDevToolsMessageProcessor
    private var downloadPathTracker: ChromeDevToolsDownloadPathTracker
    private var startupTimeoutWorkItem: DispatchWorkItem?
    private var connectionGeneration: UUID?
    private var nextCommandID = 1
    private var pendingMethodsByID: [Int: String] = [:]
    private var pendingStringEvaluations: [Int: (Result<String?, Error>) -> Void] = [:]
    private var pendingInitializationMethods: Set<String> = []
    private var isConnecting = false
    private var isConnected = false
    private var didReportFailure = false

    public init(
        session: RemoteChromiumRuntimeSession,
        urlSession: URLSession = .shared,
        startupTimeout: TimeInterval = 5
    ) {
        self.webSocketTransport = URLSessionChromeDevToolsWebSocketTransport(
            webSocketURL: session.pageWebSocketURL,
            urlSession: urlSession
        )
        self.remoteDownloadsDirectory = session.remoteDownloadsDirectory
        self.startupTimeout = max(0.01, startupTimeout)
        self.messageProcessor = ChromeDevToolsMessageProcessor(
            queue: DispatchQueue(
                label: "com.stacio.chrome-devtools.decode",
                qos: .userInitiated
            )
        )
        self.downloadPathTracker = ChromeDevToolsDownloadPathTracker(session: session)
    }

    public init(
        webSocketTransport: ChromeDevToolsWebSocketTransport,
        session: RemoteChromiumRuntimeSession,
        startupTimeout: TimeInterval = 5,
        processingQueue: DispatchQueue = DispatchQueue(
            label: "com.stacio.chrome-devtools.decode",
            qos: .userInitiated
        )
    ) {
        self.webSocketTransport = webSocketTransport
        self.remoteDownloadsDirectory = session.remoteDownloadsDirectory
        self.startupTimeout = max(0.01, startupTimeout)
        self.messageProcessor = ChromeDevToolsMessageProcessor(queue: processingQueue)
        self.downloadPathTracker = ChromeDevToolsDownloadPathTracker(session: session)
    }

    deinit {
        startupTimeoutWorkItem?.cancel()
        webSocketTransport.cancel()
    }

    public func connect() {
        guard isConnecting == false, isConnected == false else { return }
        isConnecting = true
        didReportFailure = false
        let generation = UUID()
        connectionGeneration = generation
        webSocketTransport.resume()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionGeneration == generation,
                  self.isConnecting
            else {
                return
            }
            self.reportFailure(RemoteChromiumRuntimeError.webSocketConnectionTimedOut)
        }
        startupTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + startupTimeout,
            execute: timeoutWorkItem
        )

        webSocketTransport.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self,
                      self.connectionGeneration == generation,
                      self.isConnecting
                else {
                    return
                }
                if let error {
                    self.reportFailure(error)
                } else {
                    self.beginInitialization()
                }
            }
        }
    }

    private func beginInitialization() {
        receiveNextMessage()
        // A pong proves only that the socket is open. These responses prove the
        // target can support the domains needed to render and control the page.
        let initializationCommands: [(String, [String: Any])] = [
            ("Page.enable", [:]),
            ("Page.setLifecycleEventsEnabled", ["enabled": true]),
            ("Runtime.enable", [:]),
            (
                "Browser.setDownloadBehavior",
                [
                    "behavior": "allowAndName",
                    "downloadPath": remoteDownloadsDirectory,
                    "eventsEnabled": true
                ]
            ),
            (
                "Page.startScreencast",
                [
                    "format": "jpeg",
                    "quality": 82,
                    "maxWidth": 1_920,
                    "maxHeight": 1_200,
                    "everyNthFrame": 2
                ]
            )
        ]
        pendingInitializationMethods = Set(initializationCommands.map(\.0))
        for (method, parameters) in initializationCommands {
            sendCommand(method: method, parameters: parameters, whileConnecting: true)
        }
    }

    private func finishConnection() {
        guard isConnecting, pendingInitializationMethods.isEmpty else { return }
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        isConnecting = false
        isConnected = true
        // Network.loadingFailed is emitted only after the Network domain is
        // enabled. It is intentionally outside the readiness barrier because
        // older Chromium builds may reject the optional domain.
        send(method: "Network.enable", parameters: [:])
        send(method: "Page.getNavigationHistory", parameters: [:])
        onEvent?(.connected)
    }

    @discardableResult
    private func sendCommand(
        method: String,
        parameters: [String: Any],
        whileConnecting: Bool
    ) -> Int? {
        guard isConnected || (whileConnecting && isConnecting) else { return nil }
        let id = nextCommandID
        nextCommandID += 1
        do {
            let data = try Self.commandData(id: id, method: method, parameters: parameters)
            pendingMethodsByID[id] = method
            webSocketTransport.send(data: data) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async {
                    self?.reportFailure(error)
                }
            }
            return id
        } catch {
            reportFailure(error)
            return nil
        }
    }

    public func disconnect() {
        guard isConnecting || isConnected else { return }
        isConnecting = false
        isConnected = false
        connectionGeneration = nil
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        webSocketTransport.cancel()
        pendingMethodsByID.removeAll()
        let evaluationCompletions = pendingStringEvaluations.values
        pendingStringEvaluations.removeAll()
        evaluationCompletions.forEach {
            $0(.failure(RemoteChromiumRuntimeError.commandFailed("DevTools disconnected")))
        }
        pendingInitializationMethods.removeAll()
    }

    public func send(method: String, parameters: [String: Any]) {
        sendCommand(method: method, parameters: parameters, whileConnecting: false)
    }

    public func evaluateString(
        _ expression: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        guard let id = sendCommand(
            method: "Runtime.evaluate",
            parameters: [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true
            ],
            whileConnecting: false
        ) else {
            completion(.failure(RemoteChromiumRuntimeError.commandFailed("DevTools is not connected")))
            return
        }
        pendingStringEvaluations[id] = completion
    }

    public static func commandData(
        id: Int,
        method: String,
        parameters: [String: Any]
    ) throws -> Data {
        let object: [String: Any] = [
            "id": id,
            "method": method,
            "params": parameters
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RemoteChromiumRuntimeError.commandFailed("invalid DevTools command payload")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func decodeEvent(_ data: Data) throws -> ChromeDevToolsEvent {
        try ChromeDevToolsEventDecoder().decode(data)
    }

    private func receiveNextMessage() {
        guard isConnecting || isConnected else { return }
        webSocketTransport.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isConnecting || self.isConnected else { return }
                switch result {
                case let .success(message):
                    self.process(message)
                    self.receiveNextMessage()
                case let .failure(error):
                    self.reportFailure(error)
                }
            }
        }
    }

    private func process(_ message: ChromeDevToolsWebSocketMessage) {
        let data: Data
        switch message {
        case let .data(value):
            data = value
        case let .string(value):
            data = Data(value.utf8)
        }

        messageProcessor.process(data) { [weak self] result in
            guard let self, self.isConnecting || self.isConnected else { return }
            switch result {
            case let .success(.response(response)):
                self.handle(response)
            case let .success(.event(event)):
                self.handle(event)
            case let .failure(error):
                self.reportFailure(error)
            }
        }
    }

    private func handle(_ event: ChromeDevToolsEvent) {
        switch event {
        case let .screencastFrame(_, sessionID, _, _):
            send(method: "Page.screencastFrameAck", parameters: ["sessionId": sessionID])
            onEvent?(event)
        case .frameNavigated:
            onEvent?(event)
            send(method: "Page.getNavigationHistory", parameters: [:])
        case let .downloadWillBegin(guid, suggestedFilename):
            downloadPathTracker.record(guid: guid, suggestedFilename: suggestedFilename)
        case let .downloadProgress(guid, state) where state == "completed":
            guard let download = downloadPathTracker.takeCompletedDownload(guid: guid) else { return }
            onEvent?(.downloadCompleted(download))
        case let .downloadProgress(guid, state) where state == "canceled":
            downloadPathTracker.discard(guid: guid)
        case .ignored:
            break
        default:
            onEvent?(event)
        }
    }

    private func handle(_ response: ChromeDevToolsResponse) {
        let method = pendingMethodsByID.removeValue(forKey: response.id)
        if method == "Page.navigate",
           let errorText = response.navigationErrorText?.trimmingCharacters(in: .whitespacesAndNewlines),
           errorText.isEmpty == false
        {
            onEvent?(.navigationFailed(errorText: errorText))
            onEvent?(.loading(false))
            return
        }
        if let message = response.errorMessage {
            if let completion = pendingStringEvaluations.removeValue(forKey: response.id) {
                completion(.failure(RemoteChromiumRuntimeError.commandFailed(message)))
                return
            }
            if method == "Page.navigate" {
                onEvent?(.navigationFailed(errorText: message))
                onEvent?(.loading(false))
            } else if method == "Network.enable" {
                // Navigation response errors are still available on Chromium
                // versions that do not expose the optional Network domain.
                return
            } else {
                reportFailure(RemoteChromiumRuntimeError.commandFailed(message))
            }
            return
        }
        if let completion = pendingStringEvaluations.removeValue(forKey: response.id) {
            completion(.success(response.stringValue))
            return
        }
        if let method, pendingInitializationMethods.remove(method) != nil {
            finishConnection()
            return
        }
        guard method == "Page.getNavigationHistory",
              let currentIndex = response.navigationIndex,
              let entryCount = response.navigationEntryCount
        else {
            return
        }
        onEvent?(
            .navigationState(
                canGoBack: currentIndex > 0,
                canGoForward: currentIndex >= 0 && currentIndex < entryCount - 1
            )
        )
    }

    private func reportFailure(_ error: Error) {
        guard (isConnecting || isConnected), didReportFailure == false else { return }
        didReportFailure = true
        isConnecting = false
        isConnected = false
        connectionGeneration = nil
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        webSocketTransport.cancel()
        pendingInitializationMethods.removeAll()
        pendingMethodsByID.removeAll()
        let evaluationCompletions = pendingStringEvaluations.values
        pendingStringEvaluations.removeAll()
        evaluationCompletions.forEach { $0(.failure(error)) }
        onFailure?(error)
    }
}
