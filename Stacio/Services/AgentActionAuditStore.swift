import Foundation
import StacioCoreBindings

public protocol AgentActionAuditRecording {
    @discardableResult
    func recordAgentActionEvent(_ event: AgentActionAuditEvent) throws -> AgentActionAuditRecord?
}

public protocol AgentActionAuditListing {
    func listAgentActionEvents(limit: UInt32) throws -> [AgentActionAuditRecord]
}

public struct CoreBridgeAgentActionAuditStore: AgentActionAuditRecording, AgentActionAuditListing {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    @discardableResult
    public func recordAgentActionEvent(_ event: AgentActionAuditEvent) throws -> AgentActionAuditRecord? {
        try CoreBridge.recordAgentActionEvent(databasePath: databasePath, event: event)
    }

    public func listAgentActionEvents(limit: UInt32) throws -> [AgentActionAuditRecord] {
        try CoreBridge.listAgentActionEvents(databasePath: databasePath, limit: limit)
    }
}
