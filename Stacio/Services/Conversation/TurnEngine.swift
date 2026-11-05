import Foundation

// MARK: - Turn 提交意图

public struct TurnSubmissionIntent: Equatable, Sendable {
    public var queuedInputID: String
    public var text: String
    public var workMode: WorkMode
    public var contextSnapshot: QueuedInputContextSnapshot?
    /// 是否需要 effect 执行能力（工具/终端/审批）。answer-only 门禁以此为准（不靠 UI 按钮）。
    public var requiresEffectExecution: Bool

    public init(
        queuedInputID: String,
        text: String,
        workMode: WorkMode,
        contextSnapshot: QueuedInputContextSnapshot? = nil,
        requiresEffectExecution: Bool = false
    ) {
        self.queuedInputID = queuedInputID
        self.text = text
        self.workMode = workMode
        self.contextSnapshot = contextSnapshot
        self.requiresEffectExecution = requiresEffectExecution
    }
}

// MARK: - 门禁结果

public enum TurnEngineDenialReason: Equatable, Sendable {
    /// 同一 Turn 已有非终态 Attempt
    case activeNonTerminalAttempt
    /// 认证未验证（noneVerified 无 noCredentialProofDigest；空 generation/binding 数组不得跳过鉴权）
    case authenticationNotVerified
    /// workMode 门禁（answer-only 不允许 effect 执行等）
    case workModeDenied(required: WorkMode)
    /// 会话未绑定稳定目标
    case targetNotBound
    /// Runtime 未选择
    case runtimeNotSelected
}

public enum TurnEngineGate: Equatable, Sendable {
    case allow
    case denied(TurnEngineDenialReason)
}

// MARK: - TurnEngine

/// Attempt 生命周期门禁与策略（规格 §11；不依赖 UI）。
///
/// - 一个 Turn 同时最多一个非终态 Attempt；
/// - `Preparing` 提交前强制认证校验（`noCredentialProofDigest` / generation / binding / CLI 证据）；
/// - workMode 门禁由引擎强制（不靠按钮）；
/// - `resumePhase` 与 `takeoverReturnPhase` 分离；
/// - 接管资格：实际持有可移交 handle（正在执行工具且带 terminal execution）才可接管。
public enum TurnEngine {

    /// 新 Turn 提交门禁（在 Reducer 之前执行；拒绝则不产生任何事件）。
    public static func gateSubmission(
        state: ConversationSessionState,
        intent: TurnSubmissionIntent
    ) -> TurnEngineGate {
        // 1) 单非终态 Attempt
        if let attempt = state.activeAttempt, !attempt.phase.isTerminal {
            return .denied(.activeNonTerminalAttempt)
        }

        // 2) 认证校验
        guard authenticationVerified(intent.contextSnapshot?.runtimeAuthenticationSnapshot) else {
            return .denied(.authenticationNotVerified)
        }

        // 3) workMode 门禁
        switch intent.workMode {
        case .answerOnly:
            if intent.requiresEffectExecution {
                return .denied(.workModeDenied(required: .answerOnly))
            }
        case .agent, .plan:
            break
        }

        // 4) 目标绑定 / Runtime 选择
        guard state.session.targetBinding.id.isEmpty == false else {
            return .denied(.targetNotBound)
        }
        switch state.session.runtimeSelection.kind {
        case .nativeAPI:
            guard state.session.runtimeSelection.providerConfigurationID != nil
                || state.session.runtimeSelection.codingPlanConfigurationID != nil
            else {
                return .denied(.runtimeNotSelected)
            }
        case .localAgent:
            guard state.session.runtimeSelection.localAgentConfigurationID != nil else {
                return .denied(.runtimeNotSelected)
            }
        }

        return .allow
    }

    /// 认证事实校验：空 generation/binding 数组不等于已验证；`noneVerified` 必须有免凭据证明。
    public static func authenticationVerified(_ snapshot: RuntimeAuthenticationSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return RuntimeAuthenticationVerifier.validate(snapshot) == .verified
    }

    /// 是否可以启动新 Attempt（当前无 Attempt 或已终态）。
    public static func canStartNewAttempt(state: ConversationSessionState) -> Bool {
        guard let attempt = state.activeAttempt else { return true }
        return attempt.phase.isTerminal
    }

    /// 暂停后恢复应回到的 phase（与接管返回 phase 分离）。
    public static func resumePhase(for attempt: TurnAttempt) -> AttemptPhase {
        attempt.resumePhase ?? .streaming
    }

    /// 接管返回后应回到的 phase（与暂停恢复 phase 分离）。
    public static func takeoverReturnPhase(for attempt: TurnAttempt) -> AttemptPhase {
        attempt.takeoverReturnPhase ?? .streaming
    }

    /// 接管资格：实际持有可移交 handle（正在执行工具且带 terminal execution）才显示接管入口。
    public static func canTakeover(state: ConversationSessionState) -> Bool {
        guard let attempt = state.activeAttempt, attempt.phase == .executingTool else {
            return false
        }
        if !attempt.terminalExecutionIDs.isEmpty {
            return true
        }
        guard let activeID = attempt.activeToolProposalID,
              let proposal = attempt.toolProposalQueue.first(where: { $0.id == activeID })
        else {
            return false
        }
        return proposal.state == .executing && proposal.terminalExecutionID != nil
    }
}
