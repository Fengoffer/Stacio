import Foundation

/// Public entry point for observing real turn latency.
///
/// The harness lives outside the module, so it cannot touch the internal client
/// or timing types directly. This adapter performs one real streaming request
/// and reports the same checkpoints the panel records for a user turn.
public enum AgentLatencyProbe {
 public struct Report: Sendable {
 public let ok: Bool
 public let detail: String
 public let summary: String
 }

 /// Runs a request. When `executeCommand` is set, the requested tool call is
 /// also run against the local shell so toolQueue/toolRun can be measured.
 public static func run(
 baseURL: String,
 apiKey: String,
 modelID: String,
 prompt: String,
 executeCommand: Bool
 ) async -> Report {
 var timing = AgentTurnTiming(sendAt: AgentClock.now())
 let client = AgentModelClient()
 let request = AgentModelClient.Request(
 baseURL: baseURL,
 apiKey: apiKey,
 modelID: modelID,
 messages: [["role": "user", "content": prompt]],
 tools: executeCommand ? AgentToolCatalog.toolSchemas : [],
 temperature:0.2,
 maxTokens:400,
 reasoningEffort: nil,
 timeout:120
 )
 timing.requestAt = AgentClock.now()
 let result: Result<[AgentModelClient.ToolCallAccumulator], Error> = await withCheckedContinuation { continuation in
 client.stream(request, onEvent: { event in
 switch event {
 case .firstByte:
 if timing.firstByteAt == nil { timing.firstByteAt = AgentClock.now() }
 case .textDelta, .reasoningDelta:
 if timing.firstVisibleTextAt == nil { timing.firstVisibleTextAt = AgentClock.now() }
 case .toolCall:
 if timing.toolRequestedAt == nil { timing.toolRequestedAt = AgentClock.now() }
 }
 }, onCompletion: { continuation.resume(returning: $0) })
 }

 var detail = ""
 switch result {
 case .success(let calls):
 detail = "toolCalls=\(calls.count)"
 if let first = calls.first, let command = AgentLatencyProbe.command(from: first) {
 timing.toolStartedAt = AgentClock.now()
 let outcome = AgentLatencyProbe.runLocal(command: command)
 timing.toolFinishedAt = AgentClock.now()
 detail += " cmd=\(command) exit=\(outcome)"
 }
 case .failure(let error):
 timing.completedAt = AgentClock.now()
 return Report(ok: false, detail: "\(error)", summary: timing.summary)
 }
 timing.completedAt = AgentClock.now()
 return Report(ok: true, detail: detail, summary: timing.summary)
 }

 /// Extracts the `command` argument from an accumulated tool call.
 static func command(from call: AgentModelClient.ToolCallAccumulator) -> String? {
 guard let data = call.arguments.data(using: .utf8),
 let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
 let command = object["command"] as? String,
 command.isEmpty == false else { return nil }
 return command
 }

 /// Executes one non-interactive command locally and returns its exit status.
 static func runLocal(command: String) -> Int32 {
 let process = Process()
 process.executableURL = URL(fileURLWithPath: "/bin/bash")
 process.arguments = ["-lc", command]
 process.standardOutput = Pipe()
 process.standardError = Pipe()
 do {
 try process.run()
 process.waitUntilExit()
 return process.terminationStatus
 } catch {
 return -1
 }
 }
}
