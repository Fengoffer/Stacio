import Foundation
import StacioAgentBridge

public enum AgentCommandProposalState: String, Codable, Equatable {
    case proposed
    case skipped
    case running
    case completed
    case failed
}

public struct AgentCommandProposal: Codable, Equatable {
    public let id: String
    public var toolID: String
    public var schemaRevision: Int
    public var command: String
    public var explanation: String
    public var risk: AgentActionRisk
    public var state: AgentCommandProposalState

    public init(
        id: String = UUID().uuidString,
        toolID: String = StacioBuiltinToolID.terminalCommand,
        schemaRevision: Int = 1,
        command: String,
        explanation: String,
        risk: AgentActionRisk,
        state: AgentCommandProposalState = .proposed
    ) {
        self.id = id
        self.toolID = toolID
        self.schemaRevision = schemaRevision
        self.command = command
        self.explanation = explanation
        self.risk = risk
        self.state = state
    }

    public init(
        id: String = UUID().uuidString,
        toolID: String = StacioBuiltinToolID.terminalCommand,
        schemaRevision: Int = 1,
        command: String,
        explanation: String,
        state: AgentCommandProposalState = .proposed
    ) {
        self.init(
            id: id,
            toolID: toolID,
            schemaRevision: schemaRevision,
            command: command,
            explanation: explanation,
            risk: AgentActionClassifier.risk(forCommand: command),
            state: state
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case toolID
        case schemaRevision
        case command
        case explanation
        case risk
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        toolID = try container.decodeIfPresent(String.self, forKey: .toolID)
            ?? StacioBuiltinToolID.terminalCommand
        schemaRevision = try container.decodeIfPresent(Int.self, forKey: .schemaRevision) ?? 1
        command = try container.decode(String.self, forKey: .command)
        explanation = try container.decode(String.self, forKey: .explanation)
        risk = try container.decodeIfPresent(AgentActionRisk.self, forKey: .risk)
            ?? AgentActionClassifier.risk(forCommand: command)
        state = try container.decodeIfPresent(AgentCommandProposalState.self, forKey: .state)
            ?? .proposed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolID, forKey: .toolID)
        try container.encode(schemaRevision, forKey: .schemaRevision)
        try container.encode(command, forKey: .command)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(risk, forKey: .risk)
        try container.encode(state, forKey: .state)
    }
}

public enum AgentTaskSessionState: String, Codable, Equatable {
    case idle
    case awaitingUser
    case running
    case completed
    case cancelled
    case failed
}

public struct AgentTaskSession: Codable, Equatable {
    public let id: String
    public var targetRuntimeID: String?
    public var targetTitle: String
    public var state: AgentTaskSessionState
    public var proposals: [AgentCommandProposal]

    public init(
        id: String = UUID().uuidString,
        targetRuntimeID: String?,
        targetTitle: String,
        state: AgentTaskSessionState = .idle,
        proposals: [AgentCommandProposal] = []
    ) {
        self.id = id
        self.targetRuntimeID = targetRuntimeID
        self.targetTitle = targetTitle
        self.state = state
        self.proposals = proposals
    }
}

public enum AgentTaskRunState: String, Codable, Equatable {
    case idle
    case planning
    case awaitingUser
    case running
    case completed
    case paused
    case cancelled
    case takenOver
    case failed
}

public enum AgentTaskStepState: String, Codable, Equatable {
    case queued
    case awaitingConfirmation
    case running
    case completed
    case paused
    case cancelled
    case takenOver
    case failed
}

public struct AgentTaskLoopLimits: Codable, Equatable {
    public let maxSteps: Int
    public let maxDuration: TimeInterval
    public let maxModelInvocations: Int

    public init(
        maxSteps: Int = 20,
        maxDuration: TimeInterval = 1_200,
        maxModelInvocations: Int = 20
    ) {
        self.maxSteps = max(1, maxSteps)
        self.maxDuration = max(1, maxDuration)
        self.maxModelInvocations = max(1, maxModelInvocations)
    }
}

public struct AgentTaskPlanStep: Codable, Equatable {
    public let id: String
    public var command: String
    public var intent: String
    public var risk: AgentActionRisk
    public var state: AgentTaskStepState

    public init(
        id: String = UUID().uuidString,
        command: String,
        intent: String,
        risk: AgentActionRisk,
        state: AgentTaskStepState = .queued
    ) {
        self.id = id
        self.command = command
        self.intent = intent
        self.risk = risk
        self.state = state
    }

    public init(
        id: String = UUID().uuidString,
        command: String,
        intent: String,
        state: AgentTaskStepState = .queued
    ) {
        self.init(
            id: id,
            command: command,
            intent: intent,
            risk: AgentActionClassifier.risk(forCommand: command),
            state: state
        )
    }
}

public struct AgentTaskPlan: Codable, Equatable {
    public let id: String
    public var goal: String
    public var summary: String
    public var steps: [AgentTaskPlanStep]
    public var state: AgentTaskRunState

    public init(
        id: String = UUID().uuidString,
        goal: String,
        summary: String,
        steps: [AgentTaskPlanStep],
        state: AgentTaskRunState = .awaitingUser
    ) {
        self.id = id
        self.goal = goal
        self.summary = summary
        self.steps = steps
        self.state = state
    }
}

public struct AgentTaskStepResult: Codable, Equatable {
    public let requestID: String
    public var command: String
    public var intent: String
    public var state: AgentTaskStepState
    public var events: [AgentTraceEvent]
    public var observation: String

    public init(
        requestID: String,
        command: String,
        intent: String,
        state: AgentTaskStepState,
        events: [AgentTraceEvent],
        observation: String
    ) {
        self.requestID = requestID
        self.command = command
        self.intent = intent
        self.state = state
        self.events = events
        self.observation = observation
    }
}

public struct AgentTaskRunResult: Codable, Equatable {
    public let id: String
    public var goal: String
    public var state: AgentTaskRunState
    public var summary: String
    public var steps: [AgentTaskStepResult]
    public var stopReason: AgentTaskRunStopReason?

    public init(
        id: String = UUID().uuidString,
        goal: String,
        state: AgentTaskRunState,
        summary: String,
        steps: [AgentTaskStepResult],
        stopReason: AgentTaskRunStopReason? = nil
    ) {
        self.id = id
        self.goal = goal
        self.state = state
        self.summary = summary
        self.steps = steps
        self.stopReason = stopReason
    }
}

public enum AgentTaskRunStopReason: String, Codable, Equatable {
    case stepLimitReached
    case modelInvocationLimitReached
}

public enum AgentTaskUpdateKind: String, Codable, Equatable {
    case thinking
    case thinkingDelta
    case plan
    case step
    case trace
    case limitReached
    case completed
    case paused
    case cancelled
    case takenOver
    case failed
}

public struct AgentTaskUpdate: Equatable {
    public let kind: AgentTaskUpdateKind
    public let message: String
    public let plan: AgentTaskPlan?
    public let step: AgentTaskStepResult?
    public let traceEvent: AgentTraceEvent?
    public let result: AgentTaskRunResult?

    public init(
        kind: AgentTaskUpdateKind,
        message: String,
        plan: AgentTaskPlan? = nil,
        step: AgentTaskStepResult? = nil,
        traceEvent: AgentTraceEvent? = nil,
        result: AgentTaskRunResult? = nil
    ) {
        self.kind = kind
        self.message = message
        self.plan = plan
        self.step = step
        self.traceEvent = traceEvent
        self.result = result
    }
}
