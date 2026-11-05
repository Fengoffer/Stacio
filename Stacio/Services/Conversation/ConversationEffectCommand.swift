import Foundation

// MARK: - EffectCommand（C2-3 引入，C2-4 迁移到本文件并包装为 outbox 值）

/// Reducer 产出的 effect 命令（纯值，不执行）。
/// C2-4 起由 `ConversationEffectOutboxItem` 包装为带稳定 ID / 幂等键 / authority 重验字段的 outbox 值。
public enum EffectCommand: Equatable, Sendable {
    /// 请求全局执行 Admission（Scheduler 唯一写入者）
    case requestAdmission(sessionID: String, turnID: String, attemptID: String)
    /// 请求启动 Runtime（admissionGranted 后）
    case startRuntime(attemptID: String)
    /// 结算一个 Decision（approved/denied/expired）
    case resolveDecision(decisionID: String, outcome: DecisionState, source: String?)
    /// 已批准的工具建议进入既有 AgentExecutionCoordinator；具体命令从 durable proposal 重建。
    case executeTool(attemptID: String, proposalID: String)
    /// 结算 Attempt 终态（outcome + reasonCode；不得伪造）
    case finalizeAttempt(attemptID: String, outcome: AttemptOutcome, reasonCode: AttemptReasonCode?)
    /// 请求 answer-only 启动（不携带任何 authority）
    case requestAnswerOnlyLaunch(attemptID: String)
}

public enum ConversationEffectCommandKind: String, Codable, Sendable {
    case requestAdmission
    case startRuntime
    case resolveDecision
    case executeTool
    case finalizeAttempt
    case requestAnswerOnlyLaunch
}

/// Stable, non-sensitive encoding used by the durable outbox. Tool command text,
/// prompts, terminal output, and credentials remain in encrypted event payloads.
public enum ConversationEffectCommandCodec {
    private struct Payload: Codable {
        var sessionID: String? = nil
        var turnID: String? = nil
        var attemptID: String? = nil
        var decisionID: String? = nil
        var decisionOutcome: String? = nil
        var source: String? = nil
        var proposalID: String? = nil
        var attemptOutcome: String? = nil
        var reasonCode: String? = nil
    }

    public static func encode(_ command: EffectCommand) throws -> (kind: String, payload: Data) {
        let kind: ConversationEffectCommandKind
        let value: Payload
        switch command {
        case let .requestAdmission(sessionID, turnID, attemptID):
            kind = .requestAdmission
            value = Payload(sessionID: sessionID, turnID: turnID, attemptID: attemptID)
        case let .startRuntime(attemptID):
            kind = .startRuntime
            value = Payload(attemptID: attemptID)
        case let .resolveDecision(decisionID, outcome, source):
            kind = .resolveDecision
            value = Payload(
                decisionID: decisionID,
                decisionOutcome: outcome.rawValue,
                source: source
            )
        case let .executeTool(attemptID, proposalID):
            kind = .executeTool
            value = Payload(attemptID: attemptID, proposalID: proposalID)
        case let .finalizeAttempt(attemptID, outcome, reasonCode):
            kind = .finalizeAttempt
            value = Payload(
                attemptID: attemptID,
                attemptOutcome: outcome.rawValue,
                reasonCode: reasonCode?.rawValue
            )
        case let .requestAnswerOnlyLaunch(attemptID):
            kind = .requestAnswerOnlyLaunch
            value = Payload(attemptID: attemptID)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (kind.rawValue, try encoder.encode(value))
    }

    public static func decode(kind rawKind: String, payload: Data) throws -> EffectCommand {
        guard let kind = ConversationEffectCommandKind(rawValue: rawKind) else {
            throw ConversationOutboxStoreError.invalidCommandKind(rawKind)
        }
        let value = try JSONDecoder().decode(Payload.self, from: payload)
        switch kind {
        case .requestAdmission:
            guard let sessionID = value.sessionID,
                  let turnID = value.turnID,
                  let attemptID = value.attemptID else {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            return .requestAdmission(sessionID: sessionID, turnID: turnID, attemptID: attemptID)
        case .startRuntime:
            guard let attemptID = value.attemptID else {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            return .startRuntime(attemptID: attemptID)
        case .resolveDecision:
            guard let decisionID = value.decisionID,
                  let rawOutcome = value.decisionOutcome,
                  let outcome = DecisionState(rawValue: rawOutcome) else {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            return .resolveDecision(decisionID: decisionID, outcome: outcome, source: value.source)
        case .executeTool:
            guard let attemptID = value.attemptID, let proposalID = value.proposalID else {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            return .executeTool(attemptID: attemptID, proposalID: proposalID)
        case .finalizeAttempt:
            guard let attemptID = value.attemptID,
                  let rawOutcome = value.attemptOutcome,
                  let outcome = AttemptOutcome(rawValue: rawOutcome) else {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            let reason = value.reasonCode.flatMap { AttemptReasonCode(rawValue: $0) }
            if value.reasonCode != nil, reason == nil {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            return .finalizeAttempt(attemptID: attemptID, outcome: outcome, reasonCode: reason)
        case .requestAnswerOnlyLaunch:
            guard let attemptID = value.attemptID else {
                throw ConversationOutboxStoreError.invalidCommandPayload(rawKind)
            }
            return .requestAnswerOnlyLaunch(attemptID: attemptID)
        }
    }
}

// MARK: - outbox 值（C2-4；规格 §7 执行闭环的 effect outbox）

/// 一个待派发的 effect outbox item。
///
/// - `effectID`：稳定逻辑 ID（跨重试不变，供对账/幂等去重）；
/// - `operationID`：一次操作内唯一；
/// - `idempotencyKey`：投递幂等键（重复投递忽略）；
/// - `authorityLeaseID` / `capabilityGeneration`：authority/capability generation 重验字段；
///   **answer-only effect 必须为 nil**（工厂强制，调用方无法塞入伪空 authority）；
/// - `permitCommitDecision`：需要 V2 Permit commit 决定时填充，否则 nil。
public struct ConversationEffectOutboxItem: Equatable, Sendable {
    public var itemID: String
    public var effectID: String
    public var operationID: String
    public var idempotencyKey: String
    public var command: EffectCommand
    public var authorityLeaseID: String?
    public var capabilityGeneration: Int?
    public var permitCommitDecision: V2ControlPermitState?

    public init(
        itemID: String,
        effectID: String,
        operationID: String,
        idempotencyKey: String,
        command: EffectCommand,
        authorityLeaseID: String?,
        capabilityGeneration: Int?,
        permitCommitDecision: V2ControlPermitState?
    ) {
        self.itemID = itemID
        self.effectID = effectID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.authorityLeaseID = authorityLeaseID
        self.capabilityGeneration = capabilityGeneration
        self.permitCommitDecision = permitCommitDecision
    }
}

// MARK: - outbox 工厂（纯计算，无随机 / 无时钟）

public enum ConversationEffectOutboxFactory {
    /// 把一批 effect 命令包装为 outbox items。
    ///
    /// 纯函数：相同输入产出相同 itemID/effectID/幂等键（便于重放与对账）。
    /// answer-only 命令（`.requestAnswerOnlyLaunch`）的 `authorityLeaseID` /
    /// `capabilityGeneration` 一律强制为 nil——不得给 answer-only 塞入伪空 authority。
    public static func make(
        commands: [EffectCommand],
        sessionID: String,
        turnID: String,
        attemptID: String,
        authorityLeaseID: String? = nil,
        capabilityGeneration: Int? = nil,
        permitCommitDecision: V2ControlPermitState? = nil,
        startingOrdinal: Int = 1
    ) -> [ConversationEffectOutboxItem] {
        commands.enumerated().map { index, command in
            let ordinal = startingOrdinal + index
            let effectID = stableEffectID(for: command)
            let isAnswerOnly = isAnswerOnlyEffect(command)
            let operationID = "op-\(ordinal)"
            let itemID = "\(effectID)#\(operationID)"
            return ConversationEffectOutboxItem(
                itemID: itemID,
                effectID: effectID,
                operationID: operationID,
                idempotencyKey: itemID,
                command: command,
                authorityLeaseID: isAnswerOnly ? nil : authorityLeaseID,
                capabilityGeneration: isAnswerOnly ? nil : capabilityGeneration,
                permitCommitDecision: permitCommitDecision
            )
        }
    }

    /// 稳定逻辑 effect ID（编码 kind 与标识参数，跨重试不变）。
    public static func stableEffectID(for command: EffectCommand) -> String {
        switch command {
        case let .requestAdmission(sessionID, _, attemptID):
            return "admission-\(sessionID)-\(attemptID)"
        case let .startRuntime(attemptID):
            return "startRuntime-\(attemptID)"
        case let .resolveDecision(decisionID, _, _):
            return "resolveDecision-\(decisionID)"
        case let .executeTool(attemptID, proposalID):
            return "executeTool-\(attemptID)-\(proposalID)"
        case let .finalizeAttempt(attemptID, _, _):
            return "finalizeAttempt-\(attemptID)"
        case let .requestAnswerOnlyLaunch(attemptID):
            return "answerOnlyLaunch-\(attemptID)"
        }
    }

    /// answer-only 相关 effect 判定（不得携带 authority/capability generation）。
    public static func isAnswerOnlyEffect(_ command: EffectCommand) -> Bool {
        switch command {
        case .requestAnswerOnlyLaunch:
            return true
        default:
            return false
        }
    }
}
