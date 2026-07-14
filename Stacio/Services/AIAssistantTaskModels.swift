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
    public var command: String
    public var explanation: String
    public var risk: AgentActionRisk
    public var state: AgentCommandProposalState

    public init(
        id: String = UUID().uuidString,
        command: String,
        explanation: String,
        risk: AgentActionRisk,
        state: AgentCommandProposalState = .proposed
    ) {
        self.id = id
        self.command = command
        self.explanation = explanation
        self.risk = risk
        self.state = state
    }

    public init(
        id: String = UUID().uuidString,
        command: String,
        explanation: String,
        state: AgentCommandProposalState = .proposed
    ) {
        self.init(
            id: id,
            command: command,
            explanation: explanation,
            risk: AgentActionClassifier.risk(forCommand: command),
            state: state
        )
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

    public init(maxSteps: Int = 20, maxDuration: TimeInterval = 1_200) {
        self.maxSteps = max(1, maxSteps)
        self.maxDuration = max(1, maxDuration)
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
