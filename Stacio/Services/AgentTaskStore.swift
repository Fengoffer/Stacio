import Foundation
import StacioAgentBridge
import StacioCoreBindings

public protocol AgentTaskRecording {
    @discardableResult
    func recordAgentTaskSession(
        _ session: AgentTaskSession,
        requestID: String,
        userPrompt: String,
        assistantMessage: String
    ) throws -> AgentTaskSessionRecord
}

public protocol AgentTaskListing {
    func listAgentTaskSessions(limit: UInt32) throws -> [AgentTaskSessionRecord]
    func listAgentTaskSessions(requestID: String) throws -> [AgentTaskSessionRecord]
}

public typealias AgentTaskStoring = AgentTaskRecording & AgentTaskListing

public struct CoreBridgeAgentTaskStore: AgentTaskStoring {
    private let databasePath: String
    private let actorKind: String
    private let actorName: String

    public init(
        databasePath: String,
        actorKind: String = "builtInAI",
        actorName: String = "Stacio AI"
    ) {
        self.databasePath = databasePath
        self.actorKind = actorKind
        self.actorName = actorName
    }

    @discardableResult
    public func recordAgentTaskSession(
        _ session: AgentTaskSession,
        requestID: String,
        userPrompt: String,
        assistantMessage: String
    ) throws -> AgentTaskSessionRecord {
        try CoreBridge.recordAgentTaskSession(
            databasePath: databasePath,
            session: AgentTaskSessionDraft(
                id: session.id,
                requestId: requestID,
                actorKind: actorKind,
                actorName: actorName,
                targetRuntimeId: session.targetRuntimeID,
                targetTitle: session.targetTitle,
                state: session.state.rawValue,
                userPrompt: userPrompt,
                assistantMessage: assistantMessage
            ),
            proposals: session.proposals.enumerated().map { index, proposal in
                AgentTaskProposalDraft(
                    id: proposal.id,
                    command: proposal.command,
                    explanation: proposal.explanation,
                    risk: proposal.risk.rawValue,
                    state: proposal.state.rawValue,
                    sortOrder: UInt32(index)
                )
            }
        )
    }

    public func listAgentTaskSessions(limit: UInt32) throws -> [AgentTaskSessionRecord] {
        try CoreBridge.listAgentTaskSessions(databasePath: databasePath, limit: limit)
    }

    public func listAgentTaskSessions(requestID: String) throws -> [AgentTaskSessionRecord] {
        try CoreBridge.listAgentTaskSessions(databasePath: databasePath, requestID: requestID)
    }
}
