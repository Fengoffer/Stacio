import Foundation

public enum AgentActorKind: String, Codable, Equatable {
    case builtInAI
    case externalCLI
}

public struct AgentActor: Codable, Equatable {
    public let kind: AgentActorKind
    public let name: String
    public let processID: Int32?

    public init(kind: AgentActorKind, name: String, processID: Int32?) {
        self.kind = kind
        self.name = name
        self.processID = processID
    }
}

public enum AgentTarget: Codable, Equatable {
    case currentTerminal
    case runtimeID(String)
    case sessionID(String)
}

public struct AgentRunCommandRequest: Codable, Equatable {
    public let target: AgentTarget
    public let command: String
    public let follow: Bool

    public init(target: AgentTarget, command: String, follow: Bool) {
        self.target = target
        self.command = command
        self.follow = follow
    }
}

public enum AgentAction: Codable, Equatable {
    case listSessions
    case runCommand(AgentRunCommandRequest)
    case pauseTask(String)
    case cancelTask(String)
    case takeOverTask(String)
}

public struct AgentBridgeRequest: Codable, Equatable {
    public let id: String
    public let actor: AgentActor
    public let action: AgentAction

    public init(id: String, actor: AgentActor, action: AgentAction) {
        self.id = id
        self.actor = actor
        self.action = action
    }
}

public enum AgentTraceState: String, Codable, Equatable {
    case queued
    case awaitingApproval
    case approved
    case typing
    case running
    case waitingForOutput
    case paused
    case completed
    case failed
    case cancelled
    case takenOver
}

public struct AgentTraceEvent: Codable, Equatable {
    public let requestID: String
    public let state: AgentTraceState
    public let message: String
    public let redactedCommand: String?
    public let metadata: [String: String]?

    public init(
        requestID: String,
        state: AgentTraceState,
        message: String,
        redactedCommand: String?,
        metadata: [String: String]? = nil
    ) {
        self.requestID = requestID
        self.state = state
        self.message = message
        self.redactedCommand = redactedCommand
        self.metadata = metadata
    }
}
