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

/// Evidence produced by the durable conversation state machine before a
/// built-in Agent command reaches the terminal coordinator. External clients
/// cannot mint authority from this field; only the in-process coordinator
/// adapter consumes it.
public enum AgentCommandApprovalEvidence: String, Codable, Equatable {
    case userApproved
    case policyAutoAllowed
}

public struct AgentRunCommandRequest: Codable, Equatable {
    public let target: AgentTarget
    public let command: String
    public let follow: Bool
    /// Built-in callers bind an approved command to the exact terminal
    /// connection they displayed. External/legacy callers may omit it.
    public let expectedRuntimeGeneration: UInt64?
    public let approvalEvidence: AgentCommandApprovalEvidence?

    public init(
        target: AgentTarget,
        command: String,
        follow: Bool,
        expectedRuntimeGeneration: UInt64? = nil,
        approvalEvidence: AgentCommandApprovalEvidence? = nil
    ) {
        self.target = target
        self.command = command
        self.follow = follow
        self.expectedRuntimeGeneration = expectedRuntimeGeneration
        self.approvalEvidence = approvalEvidence
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
    /// App-attested Local Agent scope. On-wire clients must leave this nil; the
    /// bridge server derives it from kernel peer credentials before dispatch.
    public let capabilityID: String?

    public init(
        id: String,
        actor: AgentActor,
        action: AgentAction,
        capabilityID: String? = nil
    ) {
        self.id = id
        self.actor = actor
        self.action = action
        self.capabilityID = capabilityID
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
