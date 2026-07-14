import Foundation
import StacioAgentBridge

public struct TerminalTraceEvent: Equatable {
    public let requestID: String
    public let state: AgentTraceState
    public let message: String
    public let redactedCommand: String?
    public let metadata: [String: String]?
    public let createdAt: Date

    public init(
        requestID: String,
        state: AgentTraceState,
        message: String,
        redactedCommand: String?,
        metadata: [String: String]? = nil,
        createdAt: Date = Date()
    ) {
        self.requestID = requestID
        self.state = state
        self.message = message
        self.redactedCommand = redactedCommand
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public enum TerminalAgentTraceNotification {
    public static let didAppend = Notification.Name("Stacio.Terminal.agentTraceDidAppend")
    public static let runtimeIDKey = "runtimeID"
    public static let titleKey = "title"
    public static let eventKey = "event"

    public static func post(
        runtimeID: String,
        title: String,
        event: AgentTraceEvent,
        center: NotificationCenter = .default
    ) {
        center.post(
            name: didAppend,
            object: nil,
            userInfo: [
                runtimeIDKey: runtimeID,
                titleKey: title,
                eventKey: event
            ]
        )
    }

    public static func payload(from notification: Notification) -> (
        runtimeID: String,
        title: String,
        event: AgentTraceEvent
    )? {
        guard notification.name == didAppend,
              let runtimeID = notification.userInfo?[runtimeIDKey] as? String,
              let title = notification.userInfo?[titleKey] as? String,
              let event = notification.userInfo?[eventKey] as? AgentTraceEvent
        else {
            return nil
        }
        return (runtimeID, title, event)
    }
}
