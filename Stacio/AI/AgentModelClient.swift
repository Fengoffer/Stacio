import Foundation

/// Streaming chat-completions client for OpenAI-compatible endpoints.
///
/// The panel shows a delta the moment it is parsed: each SSE frame goes straight
/// to `onEvent` on the main queue instead of waiting for the whole response.
final class AgentModelClient {
 struct Request {
 var baseURL: String
 var apiKey: String
 var modelID: String
 var messages: [[String: Any]]
 var tools: [[String: Any]]
 var temperature: Double?
 var maxTokens: Int?
 var reasoningEffort: String?
 var thinkingCapability: Bool? = nil
 var timeout: TimeInterval

 var requestsThinking: Bool {
 if let thinkingCapability { return thinkingCapability }
 return usesThinkingParameter
 }

 private var usesThinkingParameter: Bool {
 let model = modelID.lowercased().split(separator: "/").last ?? ""
 return model.hasPrefix("deepseek-v4") || model.hasPrefix("glm-5")
 }

 var dictionary: [String: Any] {
 var body: [String: Any] = ["model": modelID, "messages": messages, "stream": true]
 if tools.isEmpty == false {
 body["tools"] = tools
 body["tool_choice"] = "auto"
 }
 if requestsThinking && usesThinkingParameter {
 body["thinking"] = ["type": "enabled"]
 if URL(string: baseURL)?.host?.lowercased() == "tokenmetro.icu" {
 body["reasoning"] = ["enabled": true]
 }
 }
 if let temperature { body["temperature"] = temperature }
 if let maxTokens { body["max_tokens"] = maxTokens }
 if let reasoningEffort, reasoningEffort.isEmpty == false {
 body["reasoning_effort"] = reasoningEffort
 }
 return body
 }
 }

 enum Event {
 /// Emitted once when the response body starts arriving.
 case firstByte
 case textDelta(String)
 case reasoningDelta(String)
 case toolCall(index: Int, id: String?, name: String?, argumentsDelta: String)
 }

 struct ToolCallAccumulator {
 var id: String = ""
 var name: String = ""
 var arguments: String = ""
 }

 private var task: URLSessionDataTask?
 /// Per-request delegate kept alive until the task finishes.
 private var selfDelegate: StreamingDelegate?

 /// One session for every turn so the connection pool and TLS session survive.
 private static let router = StreamingSessionRouter()
 private static let shared: URLSession = {
 let configuration = URLSessionConfiguration.default
 configuration.timeoutIntervalForRequest = 120
 configuration.timeoutIntervalForResource = 180
 configuration.httpMaximumConnectionsPerHost = 6
 return URLSession(
 configuration: configuration,
 delegate: AgentModelClient.router,
 delegateQueue: nil
 )
 }()


static func sharedSession() -> URLSession { shared }

 func cancel() {
 if let task {
 task.cancel()
 }
 task = nil
 selfDelegate = nil
 }

 static func chatCompletionsURL(baseURL: String) -> URL? {
 var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
 guard trimmed.isEmpty == false else { return nil }
 while trimmed.hasSuffix("/") { trimmed.removeLast() }
 if trimmed.hasSuffix("/chat/completions") == false {
 trimmed += "/chat/completions"
 }
 guard let url = URL(string: trimmed) else { return nil }
 guard let scheme = url.scheme?.lowercased() else { return nil }
 guard scheme == "https" || scheme == "http" else { return nil }
 guard url.host?.isEmpty == false else { return nil }
 return url
 }

 func stream(_ request: Request, onEvent: @escaping @MainActor (Event) -> Void, onCompletion: @escaping @MainActor (Result<[ToolCallAccumulator], Error>) -> Void) {
 guard let url = AgentModelClient.chatCompletionsURL(baseURL: request.baseURL) else {
 DispatchQueue.main.async { onCompletion(.failure(AgentRunError.endpointRejected(request.baseURL))) }
 return
 }
 var urlRequest = URLRequest(url: url)
 urlRequest.httpMethod = "POST"
 urlRequest.timeoutInterval = request.timeout
 urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
 urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
 urlRequest.setValue("Stacio", forHTTPHeaderField: "User-Agent")
 if request.apiKey.isEmpty == false {
 urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
 }
 guard let body = try? JSONSerialization.data(withJSONObject: request.dictionary) else {
 DispatchQueue.main.async { onCompletion(.failure(AgentRunError.transport("请求体编码失败"))) }
 return
 }
 urlRequest.httpBody = body
		let accumulator = StreamAccumulator()
		let delegate = StreamingDelegate(onEvent: onEvent, accumulator: accumulator, onCompletion: onCompletion)
		let session = AgentModelClient.sharedSession()
		let dataTask = session.dataTask(with: urlRequest)
		AgentModelClient.router.register(delegate, for: dataTask)
		selfDelegate = delegate
		task = dataTask
		dataTask.resume()
 }
}

/// Tracks tool-call fragments across SSE frames; a frame may split the argument
/// JSON at any byte, so fragments are concatenated rather than parsed.
final class StreamAccumulator {
 private var calls: [Int: AgentModelClient.ToolCallAccumulator] = [:]

 func merge(index: Int, id: String?, name: String?, arguments: String) {
 var call = calls[index] ?? AgentModelClient.ToolCallAccumulator()
 if let id, id.isEmpty == false { call.id = id }
 if let name, name.isEmpty == false { call.name = name }
 call.arguments += arguments
 calls[index] = call
 }

 var ordered: [AgentModelClient.ToolCallAccumulator] {
 return calls.keys.sorted().compactMap { calls[$0] }
 }
}

/// Routes URLSession callbacks to the per-request delegate that owns the task.
///
/// One session serves every turn so the TLS handshake and HTTP/2 connection are
/// reused. The previous code built an ephemeral session per request and called
/// invalidateAndCancel on it, which discarded the pool and left the request
/// layer noticeably slower than a plain curl call to the same endpoint.
private final class StreamingSessionRouter: NSObject, URLSessionDataDelegate {
 private let lock = NSLock()
 private var handlers: [Int: StreamingDelegate] = [:]

 func register(_ delegate: StreamingDelegate, for task: URLSessionTask) {
 lock.lock(); defer { lock.unlock() }
 handlers[task.taskIdentifier] = delegate
 }

 func unregister(_ task: URLSessionTask) {
 lock.lock(); defer { lock.unlock() }
 handlers.removeValue(forKey: task.taskIdentifier)
 }

 private func handler(for task: URLSessionTask) -> StreamingDelegate? {
 lock.lock(); defer { lock.unlock() }
 return handlers[task.taskIdentifier]
 }

 func urlSession(
 _ session: URLSession,
 task: URLSessionTask,
 didCompleteWithError error: Error?
 ) {
 handler(for: task)?.urlSession(session, task: task, didCompleteWithError: error)
 unregister(task)
 }

 func urlSession(
 _ session: URLSession,
 dataTask: URLSessionDataTask,
 didReceive response: URLResponse,
 completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
 ) {
 handler(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
 }

 func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
 handler(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
 }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
 private let onEvent: @MainActor (AgentModelClient.Event) -> Void
 private var sawFirstByte = false
 private let accumulator: StreamAccumulator
 private let onCompletion: @MainActor (Result<[AgentModelClient.ToolCallAccumulator], Error>) -> Void
 private var buffer = Data()
 private var finished = false
 private var failure: Error?

 init(onEvent: @escaping @MainActor (AgentModelClient.Event) -> Void, accumulator: StreamAccumulator, onCompletion: @escaping @MainActor (Result<[AgentModelClient.ToolCallAccumulator], Error>) -> Void) {
 self.onEvent = onEvent
 self.accumulator = accumulator
 self.onCompletion = onCompletion
 }

 func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
 if let http = response as? HTTPURLResponse {
 if http.statusCode >= 400 {
 failure = AgentRunError.upstream(status: http.statusCode, message: StreamingDelegate.reason(for: http))
 }
 }
 completionHandler(.allow)
 }

 func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
 if sawFirstByte == false {
 sawFirstByte = true
 DispatchQueue.main.async { [onEvent] in onEvent(.firstByte) }
 }
 buffer.append(data)
 if failure != nil { return }
 drain()
 }

 func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
 if finished { return }
 finished = true
 let calls = accumulator.ordered
 let failure = self.failure
 let body = String(data: buffer, encoding: .utf8) ?? ""
 DispatchQueue.main.async {
 if let failure {
 if case AgentRunError.upstream(let status, let original) = failure {
 let detail = StreamingDelegate.extractErrorMessage(body) ?? original
 self.onCompletion(.failure(AgentRunError.upstream(status: status, message: detail)))
 } else {
 self.onCompletion(.failure(failure))
 }
 return
 }
 if let error = error as NSError? {
 if error.code == NSURLErrorCancelled {
 self.onCompletion(.failure(AgentRunError.cancelled))
 return
 }
 self.onCompletion(.failure(AgentRunError.transport(error.localizedDescription)))
 return
 }
 self.onCompletion(.success(calls))
 }
 }

 private func drain() {
 let separator = Data([0x0A])
 while let range = buffer.range(of: separator) {
 let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
 buffer.removeSubrange(buffer.startIndex...range.lowerBound)
 guard let line = String(data: lineData, encoding: .utf8) else { continue }
 handle(line: line)
 }
 }

 private func handle(line: String) {
 let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
 guard trimmed.isEmpty == false else { return }
 guard trimmed.hasPrefix("data:") else { return }
 let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
 if payload == "[DONE]" { return }
 guard let data = payload.data(using: .utf8) else { return }
 guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

 if let error = object["error"] as? [String: Any] {
 let message = error["message"] as? String ?? "模型返回错误"
 failure = AgentRunError.upstream(status:200, message: message)
 return
 }
 guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return }
 if let delta = choice["delta"] as? [String: Any] {
 emit(delta)
 } else if let message = choice["message"] as? [String: Any] {
 emit(message)
 }
 }

 private func emit(_ message: [String: Any]) {
 let deliver = onEvent
 if let reasoning = message["reasoning_content"] as? String, reasoning.isEmpty == false {
 DispatchQueue.main.async { deliver(.reasoningDelta(reasoning)) }
 } else if let reasoning = message["reasoning"] as? String, reasoning.isEmpty == false {
 DispatchQueue.main.async { deliver(.reasoningDelta(reasoning)) }
 }
 if let content = message["content"] as? String, content.isEmpty == false {
 DispatchQueue.main.async { deliver(.textDelta(content)) }
 }
 guard let toolCalls = message["tool_calls"] as? [[String: Any]] else { return }
 for (position, call) in toolCalls.enumerated() {
 let index = call["index"] as? Int ?? position
 let id = call["id"] as? String
 let function = call["function"] as? [String: Any]
 let name = function?["name"] as? String
 let arguments = function?["arguments"] as? String ?? ""
 accumulator.merge(index: index, id: id, name: name, arguments: arguments)
 DispatchQueue.main.async { deliver(.toolCall(index: index, id: id, name: name, argumentsDelta: arguments)) }
 }
 }

 private static func reason(for response: HTTPURLResponse) -> String {
 switch response.statusCode {
 case 401,403: return "凭据被拒绝"
 case 404: return "接口地址不存在"
 case 429: return "请求过于频繁"
 default: return HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
 }
 }

 private static func extractErrorMessage(_ body: String) -> String? {
 guard let data = body.data(using: .utf8) else { return nil }
 guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
 if let error = object["error"] as? [String: Any] {
 if let message = error["message"] as? String { return message }
 }
 return object["message"] as? String
 }
}

/// Provider control frames are never assistant prose or executable tool calls.
struct AgentVisibleResponse {
 private var pending = ""
 private(set) var sawProtocol = false

 mutating func append(_ fragment: String) -> String {
 guard !sawProtocol else { return "" }
 pending += fragment
 var visible = ""
 while let start = pending.firstIndex(of: "<") {
 visible += pending[..<start]
 pending.removeSubrange(..<start)
 let normalized = pending.prefix(24).replacingOccurrences(of: "｜", with: "|").replacingOccurrences(of: " ", with: "").lowercased()
 let markers = ["<|dsml|", "<||dsml||"]
 if markers.contains(where: { normalized.hasPrefix($0) }) {
 sawProtocol = true
 pending = ""
 return visible
 }
 if markers.contains(where: { $0.hasPrefix(normalized) }) && pending.count < 24 { return visible }
 visible.append(pending.removeFirst())
 }
 visible += pending
 pending = ""
 return visible
 }

 mutating func finish() -> String {
 defer { pending = "" }
 return pending
 }
}
