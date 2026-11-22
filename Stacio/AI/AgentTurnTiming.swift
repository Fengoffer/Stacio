import Foundation

/// Wall-clock checkpoints for one assistant turn.
///
/// The rewrite has to show measured latency rather than an impression, so each
/// user-visible boundary is stamped as it happens and the deltas are computed
/// once the turn settles.
struct AgentTurnTiming: Equatable {
 /// User pressed send.
 var sendAt: TimeInterval?
 /// Request handed to the URL session.
 var requestAt: TimeInterval?
 /// First byte of the response body arrived.
 var firstByteAt: TimeInterval?
 /// First delta appended to the transcript (visible text).
 var firstVisibleTextAt: TimeInterval?
 /// Model asked for a tool. Fires when the tool-call delta first arrives, so the
 /// gap to toolStartedAt also covers the remaining model stream. Read it as
 /// "time until the tool could run", not as dispatch overhead.
 var toolRequestedAt: TimeInterval?
 /// Command actually written to the terminal.
 var toolStartedAt: TimeInterval?
 /// Completion marker observed (or timeout declared).
 var toolFinishedAt: TimeInterval?
 /// Final answer fully received.
 var completedAt: TimeInterval?

 var requestLatencyMs: Double? { delta(requestAt, firstByteAt) }
 var firstTextLatencyMs: Double? { delta(requestAt, firstVisibleTextAt) }
 var sendToFirstTextMs: Double? { delta(sendAt, firstVisibleTextAt) }
 var toolQueueMs: Double? { delta(toolRequestedAt, toolStartedAt) }
 var toolRunMs: Double? { delta(toolStartedAt, toolFinishedAt) }
 var turnTotalMs: Double? { delta(sendAt, completedAt) }

 private func delta(_ from: TimeInterval?, _ to: TimeInterval?) -> Double? {
 guard let from, let to, to >= from else { return nil }
 return (to - from) * 1000
 }

 /// One-line summary used by tests and the diagnostics surface.
 var summary: String {
 let parts: [String] = [
 "request→firstByte=\(fmt(requestLatencyMs))",
 "request→firstText=\(fmt(firstTextLatencyMs))",
 "send→firstText=\(fmt(sendToFirstTextMs))",
 "toolQueue=\(fmt(toolQueueMs))",
 "toolRun=\(fmt(toolRunMs))",
 "turnTotal=\(fmt(turnTotalMs))"
 ]
 return parts.joined(separator: " ")
 }

 private func fmt(_ value: Double?) -> String {
 guard let value else { return "—" }
 return String(format: "%.2fms", value)
 }
}

/// Shared monotonic clock so every checkpoint uses the same time base.
enum AgentClock {
 static func now() -> TimeInterval {
 Date().timeIntervalSinceReferenceDate
 }
}
