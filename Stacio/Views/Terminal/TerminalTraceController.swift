import Foundation
import StacioAgentBridge

public final class TerminalTraceController {
    private var events: [TerminalTraceEvent] = []
    public var onChange: (([TerminalTraceEvent]) -> Void)?

    public init() {}

    public var snapshot: String {
        events
            .map { event in
                if let command = event.redactedCommand, command.isEmpty == false {
                    return "\(event.state.rawValue): \(event.message) - \(command)"
                }
                return "\(event.state.rawValue): \(event.message)"
            }
            .joined(separator: "\n")
    }

    public var eventsSnapshot: [TerminalTraceEvent] {
        events
    }

    public func append(_ event: TerminalTraceEvent) {
        events.append(event)
        if events.count > 50 {
            events.removeFirst(events.count - 50)
        }
        onChange?(events)
    }

    public func append(
        requestID: String,
        state: AgentTraceState,
        message: String,
        redactedCommand: String?,
        metadata: [String: String]? = nil
    ) {
        append(
            TerminalTraceEvent(
                requestID: requestID,
                state: state,
                message: message,
                redactedCommand: redactedCommand,
                metadata: metadata
            )
        )
    }
}
