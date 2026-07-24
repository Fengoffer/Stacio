import Foundation
import StacioAgentBridge

@MainActor
public final class AgentTaskOrchestrator {
    private let coordinator: AIAssistantCoordinator
    private let limits: AgentTaskLoopLimits
    private let targetContextsProvider: () -> [AITerminalContext]
    private var activeRequestIDs: [String] = []
    private var activeAIRequest: AIAssistantRequestCancelling?
    private var stopState: AgentTaskRunState?
    private var onUpdate: ((AgentTaskUpdate) -> Void)?
    private var activeTraceContinuation: AsyncStream<AgentTraceEvent>.Continuation?

    public init(
        coordinator: AIAssistantCoordinator,
        limits: AgentTaskLoopLimits = AgentTaskLoopLimits(),
        targetContextsProvider: @escaping () -> [AITerminalContext] = { [] }
    ) {
        self.coordinator = coordinator
        self.limits = limits
        self.targetContextsProvider = targetContextsProvider
    }

    @discardableResult
    public func run(
        goal: String,
        context: AITerminalContext,
        contextProvider: (() -> AITerminalContext?)? = nil,
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = [],
        initialResponse: AIAssistantResponse? = nil,
        continuingFrom previousSteps: [AgentTaskStepResult] = [],
        onUpdate: @escaping (AgentTaskUpdate) -> Void = { _ in }
    ) async throws -> AgentTaskRunResult {
        self.onUpdate = onUpdate
        stopState = nil
        activeRequestIDs = []
        activeAIRequest = nil
        activeTraceContinuation?.finish()
        activeTraceContinuation = nil
        var steps = previousSteps
        var observations = previousSteps.map { observationBlock(for: $0) }
        var pendingInitialResponse = initialResponse
        let startedAt = Date()
        let stepLimit = steps.count + limits.maxSteps
        let runNamespace = UUID().uuidString.lowercased()
        let selectedTargetContexts = targetContextsProvider()
        var rejectedMutationCount = 0
        var rejectedCompletionCount = 0
        var rejectedReportCount = 0

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
                let currentContext = contextProvider?() ?? context
                response = try await ask(
                    question: loopQuestion(goal: goal, observations: observations, stepIndex: steps.count + 1),
                    context: currentContext,
                    conversationHistory: conversationHistory,
                    attachments: attachments
                )
            }
            if let stopState {
                let runResult = result(goal: goal, state: stopState, summary: summary(for: stopState), steps: steps)
                onUpdate(.init(kind: updateKind(for: stopState), message: runResult.summary, result: runResult))
                return runResult
            }
            let thought = response.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if thought.isEmpty == false, response.commandProposals.isEmpty == false {
                onUpdate(.init(kind: .thinking, message: thought))
            }
            guard let proposal = response.commandProposals.first else {
                if AgentVerificationPolicy.requiresVerification(in: steps) {
                    rejectedCompletionCount += 1
                    let guardrailObservation = [
                        "变更后验证门禁：禁止结束任务，因为最后一次配置、部署或数据库变更之后还没有成功的专项验证证据。",
                        "请返回一条最小只读验证命令，检查配置语法、服务状态、容器/工作负载状态、健康端点或数据库可用性，并以终端输出作为事实依据。",
                        "验证失败时必须报告失败和回滚建议，不得宣称变更完成。"
                    ].joined(separator: "\n")
                    observations.append(guardrailObservation)
                    onUpdate(.init(kind: .thinking, message: guardrailObservation))
                    if rejectedCompletionCount >= 2 {
                        let runResult = result(
                            goal: goal,
                            state: .failed,
                            summary: "变更后验证门禁已连续阻止无证据完成，Stacio 已停止自动执行。",
                            steps: steps
                        )
                        onUpdate(.init(kind: .failed, message: runResult.summary, result: runResult))
                        return runResult
                    }
                    continue
                }
                if AgentFinalReportPolicy.isCompliant(message: response.message, steps: steps) == false {
                    rejectedReportCount += 1
                    let backupPath = AgentBackupPolicy.latestVerifiedBackup(in: steps)?.path ?? "未找到"
                    let guardrailObservation = [
                        "最终报告门禁：变更已经执行并验证，但当前答复缺少完整的备份与回滚信息。",
                        "请重新输出标准 Markdown 最终报告，必须包含“备份与回滚”章节、准确备份位置 `\(backupPath)`、备份验证结果、变更后验证结果和可执行的回滚方法；commands 返回空数组。"
                    ].joined(separator: "\n")
                    observations.append(guardrailObservation)
                    onUpdate(.init(kind: .thinking, message: guardrailObservation))
                    if rejectedReportCount >= 2 {
                        let runResult = result(
                            goal: goal,
                            state: .failed,
                            summary: "最终报告连续缺少备份与回滚信息，Stacio 已停止自动执行。",
                            steps: steps
                        )
                        onUpdate(.init(kind: .failed, message: runResult.summary, result: runResult))
                        return runResult
                    }
                    continue
                }
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
            if AgentBackupPolicy.requiresBackup(command: proposal.command),
               AgentRollbackPolicy.isRollbackCommand(proposal.command) == false,
               AgentBackupPolicy.verifiedBackupForNextMutation(in: steps) == nil {
                rejectedMutationCount += 1
                let guardrailObservation = [
                    "安全门禁：禁止执行该变更，因为当前任务尚无已成功且带明确路径的备份证据。",
                    "请先返回一条创建备份的最小命令；备份必须使用带时间戳且不覆盖历史备份的明确路径，并在输出中打印该路径。",
                    "备份失败时必须停止，不得继续配置修改、应用部署或数据库变更。"
                ].joined(separator: "\n")
                observations.append(guardrailObservation)
                onUpdate(.init(kind: .thinking, message: guardrailObservation))
                if rejectedMutationCount >= 2 {
                    let runResult = result(
                        goal: goal,
                        state: .failed,
                        summary: "备份安全门禁已连续阻止未备份的变更，Stacio 已停止自动执行。",
                        steps: steps
                    )
                    onUpdate(.init(kind: .failed, message: runResult.summary, result: runResult))
                    return runResult
                }
                continue
            }
            if Self.isRepeatedWithoutProgress(proposal.command, steps: steps) {
                let runResult = result(
                    goal: goal,
                    state: .failed,
                    summary: "AI 连续重复同一条命令且没有提出新的验证路径，Stacio 已停止自动执行。请检查现有输出或调整排查方向。",
                    steps: steps
                )
                onUpdate(.init(kind: .failed, message: runResult.summary, result: runResult))
                return runResult
            }

            let requestID = "agent-step-\(runNamespace)-\(steps.count + 1)"
            onUpdate(.init(
                kind: .step,
                message: stepPreparationText(for: proposal, stepIndex: steps.count + 1)
            ))
            var events: [AgentTraceEvent] = []
            var traceContinuation: AsyncStream<AgentTraceEvent>.Continuation?
            let traceStream = AsyncStream<AgentTraceEvent> { continuation in
                traceContinuation = continuation
            }
            activeTraceContinuation = traceContinuation
            let executionContexts = selectedTargetContexts
            activeRequestIDs = Self.childRequestIDs(
                for: requestID,
                targetCount: executionContexts.isEmpty ? 1 : executionContexts.count
            )
            let executedEvents = try coordinator.executeProposedCommand(
                proposal.command,
                contexts: executionContexts.isEmpty ? [context] : executionContexts,
                requestID: requestID,
                emit: { [weak self] event in
                    events.append(event)
                    traceContinuation?.yield(event)
                    self?.onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
                }
            )
            if events.isEmpty {
                events = executedEvents
                events.forEach { event in
                    traceContinuation?.yield(event)
                    onUpdate(.init(kind: .trace, message: event.message, traceEvent: event))
                }
            }

            let expectedTargetIDs = Set((executionContexts.isEmpty ? [context] : executionContexts).map(\.runtimeID))
            if events.contains(where: { $0.metadata?["executionMode"] == "backgroundTask" }),
               Self.hasCompletedAllTargets(
                   events: events,
                   targetIDs: expectedTargetIDs,
                   expectedTargetCount: executionContexts.isEmpty ? 1 : executionContexts.count
               ) == false {
                for await event in traceStream {
                    if events.contains(event) == false {
                        events.append(event)
                    }
                    if Self.hasCompletedAllTargets(
                        events: events,
                        targetIDs: expectedTargetIDs,
                        expectedTargetCount: executionContexts.isEmpty ? 1 : executionContexts.count
                    ) {
                        break
                    }
                }
            }
            traceContinuation?.finish()
            activeTraceContinuation = nil

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

            if stepState == .failed,
               AgentVerificationPolicy.isVerificationCommand(step.command),
               let backup = AgentBackupPolicy.latestVerifiedBackup(in: steps) {
                let recoveryObservation = [
                    "变更后验证失败，进入回滚流程。",
                    "已验证备份位置：\(backup.path)",
                    "下一步只能提出基于该备份或平台原生 rollback/undo 的最小回滚命令；回滚完成后必须再次运行只读验证。"
                ].joined(separator: "\n")
                observations.append(recoveryObservation)
                onUpdate(.init(kind: .thinking, message: recoveryObservation))
                continue
            }

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
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = []
    ) async throws -> AgentTaskPlan {
        var planningLines = [
            "先产出一个多步计划，暂时不要执行命令。",
            "目标：\(goal)",
            "计划先完成环境与依赖识别和只读基线；若包含配置、部署或数据库变更，步骤顺序必须是：备份 → 变更 → 验证 → 失败回滚。",
            "每个变更步骤必须对应明确的备份位置、成功判据、验证命令和回滚方法。",
            "请返回步骤列表、每步意图，以及可选命令。"
        ]
        if let guidance = AgentOperationalDomainClassifier.guidance(for: goal) {
            planningLines.append(guidance)
        }
        let response = try await ask(
            question: planningLines.joined(separator: "\n"),
            context: context,
            conversationHistory: conversationHistory,
            attachments: attachments
        )
        let steps = response.commandProposals.map {
            AgentTaskPlanStep(command: $0.command, intent: $0.explanation, risk: $0.risk)
        }
        return AgentTaskPlan(goal: goal, summary: response.message, steps: steps)
    }

    public func pause() {
        guard activeRequestIDs.isEmpty == false else {
            activeAIRequest?.cancel()
            activeAIRequest = nil
            stopState = .paused
            return
        }
        for requestID in activeRequestIDs {
            if let event = coordinator.pauseTask(requestID: requestID) {
                onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
                activeTraceContinuation?.yield(event)
            }
        }
        activeTraceContinuation?.finish()
        activeTraceContinuation = nil
        activeAIRequest?.cancel()
        activeAIRequest = nil
        stopState = .paused
    }

    public func cancel() {
        guard activeRequestIDs.isEmpty == false else {
            activeAIRequest?.cancel()
            activeAIRequest = nil
            stopState = .cancelled
            return
        }
        for requestID in activeRequestIDs {
            if let event = coordinator.cancelTask(requestID: requestID) {
                onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
                activeTraceContinuation?.yield(event)
            }
        }
        activeTraceContinuation?.finish()
        activeTraceContinuation = nil
        activeAIRequest?.cancel()
        activeAIRequest = nil
        stopState = .cancelled
    }

    public func takeOver() {
        guard activeRequestIDs.isEmpty == false else {
            activeAIRequest?.cancel()
            activeAIRequest = nil
            stopState = .takenOver
            return
        }
        for requestID in activeRequestIDs {
            if let event = coordinator.takeOverTask(requestID: requestID) {
                onUpdate?(.init(kind: .trace, message: event.message, traceEvent: event))
                activeTraceContinuation?.yield(event)
            }
        }
        activeTraceContinuation?.finish()
        activeTraceContinuation = nil
        activeAIRequest?.cancel()
        activeAIRequest = nil
        stopState = .takenOver
    }

    private func ask(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage],
        attachments: [AIAssistantAttachment]
    ) async throws -> AIAssistantResponse {
        try await withCheckedThrowingContinuation { continuation in
            activeAIRequest = coordinator.askInBackground(
                question: question,
                context: context,
                conversationHistory: conversationHistory,
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

    private static func isRepeatedWithoutProgress(
        _ command: String,
        steps: [AgentTaskStepResult]
    ) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false, steps.count >= 2 else { return false }
        return steps.suffix(2).allSatisfy {
            $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }

    private func loopQuestion(goal: String, observations: [String], stepIndex: Int) -> String {
        var lines = [
            "自主执行目标：\(goal)",
            "请根据已有观察决定第 \(stepIndex) 步。",
            "在任何命令尚未执行或证据尚不充分时，message 只能写“初步判断”和“待验证项”，不得使用“最终结论”“任务完成”等确定性表述；需要只读核验时应说明核验目的。",
            "如果目标已经完成，commands 返回空数组，message 只写给用户的最终答复。",
            "最终答复必须是排版完整、层次清晰的标准 Markdown 报告，并直接回答原始目标。至少包含结论、关键证据和风险/状态；仅在确有必要时补充后续建议。指标对比、资源状态或多对象结果适合表格时应主动使用 Markdown 表格。不要粘贴完整日志、重复全部执行步骤或暴露内部思考过程。",
            "如果本次任务执行了配置、部署或数据库变更，最终 Markdown 必须包含“备份与回滚”章节，明确说明已完成备份、备份位置、验证结果和可执行的回滚方法。",
            "执行任何变更后必须运行针对性的只读验证命令；没有成功验证证据时不得结束任务或宣称完成。",
            "如果还需要行动，只返回下一步最小必要命令。"
        ]
        if let guidance = AgentOperationalDomainClassifier.guidance(for: goal) {
            lines.append(guidance)
        }
        if observations.isEmpty == false {
            lines.append("已执行步骤与观察（敏感信息已由 Stacio redaction 处理）：")
            lines.append(contentsOf: observations)
        }
        return lines.joined(separator: "\n")
    }

    private func observationBlock(for step: AgentTaskStepResult) -> String {
        var lines = [
            "步骤 \(step.requestID)",
            "命令：\(step.command)",
            "状态：\(step.state.rawValue)",
            "观察：\(step.observation)"
        ]
        if let backup = AgentBackupPolicy.latestVerifiedBackup(in: [step]) {
            lines.append("备份位置：\(backup.path)")
            lines.append("最终报告必须包含“备份与回滚”章节，并基于此路径给出回滚方法。")
        }
        return lines.joined(separator: "\n")
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
        if let latestStructured = structured.last {
            return latestStructured
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

    private static func isTerminalTraceState(_ state: AgentTraceState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled, .paused, .takenOver:
            return true
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            return false
        }
    }

    private static func hasCompletedAllTargets(
        events: [AgentTraceEvent],
        targetIDs: Set<String>,
        expectedTargetCount: Int
    ) -> Bool {
        let terminalEvents = events.filter { isTerminalTraceState($0.state) }
        guard targetIDs.isEmpty == false else {
            return terminalEvents.count >= max(1, expectedTargetCount)
        }
        let completedTargets = Set(
            terminalEvents.compactMap { $0.metadata?["sourceRuntimeID"] }
        )
        return targetIDs.isSubset(of: completedTargets)
            || (completedTargets.isEmpty && terminalEvents.count >= max(1, expectedTargetCount))
    }

    private static func childRequestIDs(for requestID: String, targetCount: Int) -> [String] {
        guard targetCount > 1 else { return [requestID] }
        return (1...targetCount).map { "\(requestID)-\($0)" }
    }
}
