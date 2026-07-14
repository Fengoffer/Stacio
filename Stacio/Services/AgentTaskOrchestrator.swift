import Foundation
import StacioAgentBridge

@MainActor
public final class AgentTaskOrchestrator {
    private let coordinator: AIAssistantCoordinator
    private let limits: AgentTaskLoopLimits
    private var activeRequestID: String?
    private var activeAIRequest: AIAssistantRequestCancelling?
    private var stopState: AgentTaskRunState?
    private var onUpdate: ((AgentTaskUpdate) -> Void)?

    public init(
        coordinator: AIAssistantCoordinator,
        limits: AgentTaskLoopLimits = AgentTaskLoopLimits()
    ) {
        self.coordinator = coordinator
        self.limits = limits
    }

    @discardableResult
    public func run(
        goal: String,
        context: AITerminalContext,
        attachments: [AIAssistantAttachment] = [],
        initialResponse: AIAssistantResponse? = nil,
        continuingFrom previousSteps: [AgentTaskStepResult] = [],
        onUpdate: @escaping (AgentTaskUpdate) -> Void = { _ in }
    ) async throws -> AgentTaskRunResult {
        self.onUpdate = onUpdate
        stopState = nil
        activeRequestID = nil
        activeAIRequest = nil
        var steps = previousSteps
        var observations = previousSteps.map { observationBlock(for: $0) }
        var pendingInitialResponse = initialResponse
        let startedAt = Date()
        let stepLimit = steps.count + limits.maxSteps

        while steps.count < stepLimit {
            if let stopState {
                return result(goal: goal, state: stopState, summary: summary(for: stopState), steps: steps)
            }
            if Date().timeIntervalSince(startedAt) >= limits.maxDuration {
                let runResult = result(
                    goal: goal,
                    state: .failed,
                    summary: "已达到自主执行总时长上限，Stacio 已停止继续请求 AI。",
                    steps: steps
                )
                onUpdate(.init(kind: .failed, message: runResult.summary, result: runResult))
                return runResult
            }

            let response: AIAssistantResponse
            if let initialResponse = pendingInitialResponse {
                pendingInitialResponse = nil
                response = initialResponse
            } else {
                onUpdate(.init(kind: .thinking, message: steps.isEmpty ? "AI 正在决定第一步" : "AI 正在根据执行结果决定下一步"))
                response = try await ask(
                    question: loopQuestion(goal: goal, observations: observations, stepIndex: steps.count + 1),
                    context: context,
                    attachments: attachments
                )
            }
            if let stopState {
                let runResult = result(goal: goal, state: stopState, summary: summary(for: stopState), steps: steps)
                onUpdate(.init(kind: updateKind(for: stopState), message: runResult.summary, result: runResult))
                return runResult
            }
            let thought = response.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if thought.isEmpty == false {
                onUpdate(.init(kind: .thinking, message: thought))
            }
            guard let proposal = response.commandProposals.first else {
                let runResult = result(
                    goal: goal,
                    state: .completed,
                    summary: response.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "AI 已判断任务完成。"
                        : response.message,
                    steps: steps
                )
                onUpdate(.init(kind: .completed, message: runResult.summary, result: runResult))
                return runResult
            }

            let requestID = "agent-step-\(steps.count + 1)"
            activeRequestID = requestID
            onUpdate(.init(
                kind: .step,
                message: stepPreparationText(for: proposal, stepIndex: steps.count + 1)
            ))
            var events: [AgentTraceEvent] = []
            let executedEvents = try coordinator.executeProposedCommand(
                proposal.command,
                context: context,
                requestID: requestID,
                emit: { [weak self] event in
                    events.append(event)
                    self?.onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
                }
            )
            if events.isEmpty {
                events = executedEvents
                events.forEach { event in
                    onUpdate(.init(kind: .trace, message: event.message, traceEvent: event))
                }
            }

            let stepState = stepState(from: events)
            let observation = observationText(from: events)
            let step = AgentTaskStepResult(
                requestID: requestID,
                command: proposal.command,
                intent: proposal.explanation,
                state: stepState,
                events: events,
                observation: observation
            )
            steps.append(step)
            observations.append(observationBlock(for: step))
            onUpdate(.init(kind: .step, message: stepSummaryText(for: step), step: step))

            if let stopState = stopState ?? runState(for: stepState) {
                let runResult = result(goal: goal, state: stopState, summary: summary(for: stopState), steps: steps)
                onUpdate(.init(kind: updateKind(for: stopState), message: runResult.summary, result: runResult))
                return runResult
            }
            if isWaitingOnActiveStep(stepState) {
                let runResult = result(
                    goal: goal,
                    state: .running,
                    summary: "当前步骤仍在执行或等待确认，Stacio 已暂停继续请求下一步。",
                    steps: steps
                )
                onUpdate(.init(kind: .step, message: runResult.summary, step: step, result: runResult))
                return runResult
            }
            if stepState == .failed {
                let runResult = result(goal: goal, state: .failed, summary: "执行失败，Stacio 已停止继续请求 AI。", steps: steps)
                onUpdate(.init(kind: .failed, message: runResult.summary, result: runResult))
                return runResult
            }
        }

        let summary = "已达到自主执行步数上限（\(limits.maxSteps) 步），Stacio 已暂停继续请求 AI。你可以点击“继续”再放行一轮。"
        let runResult = result(
            goal: goal,
            state: .awaitingUser,
            summary: summary,
            steps: steps,
            stopReason: .stepLimitReached
        )
        onUpdate(.init(kind: .limitReached, message: runResult.summary, result: runResult))
        return runResult
    }

    public func makePlan(
        goal: String,
        context: AITerminalContext,
        attachments: [AIAssistantAttachment] = []
    ) async throws -> AgentTaskPlan {
        let response = try await ask(
            question: [
                "先产出一个多步计划，暂时不要执行命令。",
                "目标：\(goal)",
                "请返回步骤列表、每步意图，以及可选命令。"
            ].joined(separator: "\n"),
            context: context,
            attachments: attachments
        )
        let steps = response.commandProposals.map {
            AgentTaskPlanStep(command: $0.command, intent: $0.explanation, risk: $0.risk)
        }
        return AgentTaskPlan(goal: goal, summary: response.message, steps: steps)
    }

    public func pause() {
        guard let activeRequestID else {
            activeAIRequest?.cancel()
            activeAIRequest = nil
            stopState = .paused
            return
        }
        if let event = coordinator.pauseTask(requestID: activeRequestID) {
            onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
        }
        activeAIRequest?.cancel()
        activeAIRequest = nil
        stopState = .paused
    }

    public func cancel() {
        guard let activeRequestID else {
            activeAIRequest?.cancel()
            activeAIRequest = nil
            stopState = .cancelled
            return
        }
        if let event = coordinator.cancelTask(requestID: activeRequestID) {
            onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
        }
        activeAIRequest?.cancel()
        activeAIRequest = nil
        stopState = .cancelled
    }

    public func takeOver() {
        guard let activeRequestID else {
            activeAIRequest?.cancel()
            activeAIRequest = nil
            stopState = .takenOver
            return
        }
        if let event = coordinator.takeOverTask(requestID: activeRequestID) {
            onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
        }
        activeAIRequest?.cancel()
        activeAIRequest = nil
        stopState = .takenOver
    }

    private func ask(
        question: String,
        context: AITerminalContext,
        attachments: [AIAssistantAttachment]
    ) async throws -> AIAssistantResponse {
        try await withCheckedThrowingContinuation { continuation in
            activeAIRequest = coordinator.askInBackground(
                question: question,
                context: context,
                attachments: attachments,
                progress: { [weak self] message in
                    self?.onUpdate?(.init(kind: .thinking, message: message))
                },
                stream: { [weak self] delta in
                    self?.onUpdate?(.init(kind: .thinkingDelta, message: delta))
                },
                completion: { result in
                    self.activeAIRequest = nil
                    continuation.resume(with: result)
                }
            )
        }
    }

    private func loopQuestion(goal: String, observations: [String], stepIndex: Int) -> String {
        var lines = [
            "自主执行目标：\(goal)",
            "请根据已有观察决定第 \(stepIndex) 步。",
            "如果目标已经完成，commands 返回空数组并给出结论。",
            "如果还需要行动，只返回下一步最小必要命令。"
        ]
        if observations.isEmpty == false {
            lines.append("已执行步骤与观察（敏感信息已由 Stacio redaction 处理）：")
            lines.append(contentsOf: observations)
        }
        return lines.joined(separator: "\n")
    }

    private func observationBlock(for step: AgentTaskStepResult) -> String {
        [
            "步骤 \(step.requestID)",
            "命令：\(step.command)",
            "状态：\(step.state.rawValue)",
            "观察：\(step.observation)"
        ].joined(separator: "\n")
    }

    private func stepPreparationText(for proposal: AgentCommandProposal, stepIndex: Int) -> String {
        [
            "第 \(stepIndex) 步：\(proposal.explanation)",
            "准备执行命令：\(proposal.command)"
        ].joined(separator: "\n")
    }

    private func stepSummaryText(for step: AgentTaskStepResult) -> String {
        let prefix: String
        switch step.state {
        case .completed:
            prefix = "这一步已完成。"
        case .failed:
            prefix = "这一步执行失败，Stacio 已停止自动推进。"
        case .queued, .awaitingConfirmation, .running:
            prefix = "这一步还没有明确完成，Stacio 已暂停自动推进。"
        case .paused:
            prefix = "这一步已暂停，Stacio 已停止自动推进。"
        case .cancelled:
            prefix = "这一步已取消，Stacio 已停止自动推进。"
        case .takenOver:
            prefix = "这一步已切换为人工接管，Stacio 已停止自动推进。"
        }
        return [
            prefix,
            "命令：\(step.command)",
            "结果：\(step.observation)"
        ].joined(separator: "\n")
    }

    private func observationText(from events: [AgentTraceEvent]) -> String {
        let structured = events
            .compactMap { $0.metadata?["terminalOutputSummary"] }
            .map { AgentProtocolRedaction.redact($0) }
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        if structured.isEmpty == false {
            return structured.joined(separator: "\n")
        }
        let messages = events.map { AgentProtocolRedaction.redact($0.message) }
        guard messages.isEmpty == false else {
            return "暂无输出，原始终端是事实源。"
        }
        return messages.joined(separator: "\n")
    }

    private func stepState(from events: [AgentTraceEvent]) -> AgentTaskStepState {
        guard let latest = events.last?.state else {
            return .running
        }
        switch latest {
        case .queued:
            return .queued
        case .awaitingApproval:
            return .awaitingConfirmation
        case .approved, .typing, .running, .waitingForOutput:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .paused:
            return .paused
        case .takenOver:
            return .takenOver
        }
    }

    private func runState(for stepState: AgentTaskStepState) -> AgentTaskRunState? {
        switch stepState {
        case .paused:
            return .paused
        case .cancelled:
            return .cancelled
        case .takenOver:
            return .takenOver
        case .failed:
            return .failed
        case .queued, .awaitingConfirmation, .running, .completed:
            return nil
        }
    }

    private func isWaitingOnActiveStep(_ stepState: AgentTaskStepState) -> Bool {
        switch stepState {
        case .queued, .awaitingConfirmation, .running:
            return true
        case .completed, .paused, .cancelled, .takenOver, .failed:
            return false
        }
    }

    private func summary(for state: AgentTaskRunState) -> String {
        switch state {
        case .paused:
            return "自主执行已暂停。"
        case .cancelled:
            return "自主执行已取消。"
        case .takenOver:
            return "自主执行已切换为人工接管。"
        case .failed:
            return "自主执行失败。"
        case .completed:
            return "自主执行已完成。"
        case .idle, .planning, .awaitingUser, .running:
            return "自主执行已停止。"
        }
    }

    private func updateKind(for state: AgentTaskRunState) -> AgentTaskUpdateKind {
        switch state {
        case .paused:
            return .paused
        case .cancelled:
            return .cancelled
        case .takenOver:
            return .takenOver
        case .failed:
            return .failed
        case .completed:
            return .completed
        case .idle, .planning, .awaitingUser, .running:
            return .step
        }
    }

    private func result(
        goal: String,
        state: AgentTaskRunState,
        summary: String,
        steps: [AgentTaskStepResult],
        stopReason: AgentTaskRunStopReason? = nil
    ) -> AgentTaskRunResult {
        AgentTaskRunResult(goal: goal, state: state, summary: summary, steps: steps, stopReason: stopReason)
    }
}
