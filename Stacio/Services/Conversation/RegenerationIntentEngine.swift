import Foundation

// MARK: - RegenerationIntentEngine（C2-9；逻辑并入 C2-3/TurnEngine 可共享）

/// RegenerationIntent 合并、canonical write lease 与 CAS、answer-only 合同（纯函数）。
public enum RegenerationIntentEngine {

    /// 入队一个新 RegenerationIntent：快速连续 Retry/Regenerate 只保留最后一个 durable Intent
    /// （`nextRegenerationOrdinal` 递增；旧 pending intent 标记 `superseded`）。
    /// 返回 (更新后的 Turn, 新 Intent, 被 superseded 的旧 Intent（若有）)。
    public static func enqueueIntent(
        turn: ConversationTurn,
        kind: RegenerationIntentKind,
        configurationMode: RegenerationConfigurationMode,
        sourceAttemptID: String,
        now: Date
    ) -> (ConversationTurn, RegenerationIntent, RegenerationIntent?) {
        var newTurn = turn
        let ordinal = turn.nextRegenerationOrdinal + 1
        let intent = RegenerationIntent(
            intentID: "intent-\(ordinal)",
            turnID: turn.id,
            ordinal: ordinal,
            requestedAt: now,
            kind: kind,
            state: .pending,
            sourceAttemptID: sourceAttemptID,
            expectedCanonicalRevision: turn.canonicalFinalAnswerRevision,
            configurationMode: configurationMode,
            configurationRevisionDigest: nil,
            materializedAttemptID: nil,
            supersededByIntentID: nil
        )
        // 旧 pending intent 标记 superseded（只保留最后一个 durable Intent）
        var supersededOld: RegenerationIntent?
        if let old = newTurn.pendingRegenerationIntent, old.state != .superseded {
            var superseded = old
            superseded.state = .superseded
            superseded.supersededByIntentID = intent.intentID
            supersededOld = superseded
        }
        newTurn.pendingRegenerationIntent = intent
        newTurn.nextRegenerationOrdinal = ordinal
        return (newTurn, intent, supersededOld)
    }

    /// 旧 Attempt 未终态不 materialize 新 Attempt。
    public static func canMaterialize(turn: ConversationTurn) -> Bool {
        guard let attemptID = turn.activeAttemptID,
              let attempt = turn.attempts.first(where: { $0.id == attemptID })
        else {
            return true
        }
        return attempt.phase.isTerminal
    }

    /// materialize：创建新 Attempt（从 Preparing）并标记 intent `materialized`。
    /// 返回 (更新后的 Turn, 新 Attempt ID)；旧 Attempt 未终态或 intent 已 superseded 时返回 (turn, nil)。
    public static func materialize(
        turn: ConversationTurn,
        now: Date
    ) -> (ConversationTurn, String?) {
        guard let intent = turn.pendingRegenerationIntent, intent.state != .superseded else {
            return (turn, nil)
        }
        guard canMaterialize(turn: turn) else {
            return (turn, nil)
        }
        var newTurn = turn
        let purpose = purpose(for: intent.kind, configMode: intent.configurationMode)
        let ordinal = newTurn.attempts.count + 1
        let attempt = TurnAttempt(
            id: "a-\(ordinal)",
            turnID: turn.id,
            ordinal: ordinal,
            phase: .preparing,
            purpose: purpose,
            runtimeSnapshot: "",
            workModeSnapshot: intent.kind == .answerOnly ? .answerOnly : .agent,
            policySnapshot: "",
            toolCapabilitySnapshot: "",
            instructionSnapshot: "",
            startedAt: now
        )
        newTurn.attempts.append(attempt)
        newTurn.activeAttemptID = attempt.id
        newTurn.phase = .preparing
        if var stored = newTurn.pendingRegenerationIntent {
            stored.state = .materialized
            stored.materializedAttemptID = attempt.id
            newTurn.pendingRegenerationIntent = stored
        }
        return (newTurn, attempt.id)
    }

    /// intent kind + 配置模式 → 新 Attempt purpose。
    /// `answerOnly → answerRegeneration`；`rerunTask → retrySameConfig / retryNewConfig`。
    public static func purpose(
        for kind: RegenerationIntentKind,
        configMode: RegenerationConfigurationMode
    ) -> AttemptPurpose {
        switch kind {
        case .answerOnly:
            return .answerRegeneration
        case .rerunTask:
            return configMode == .sameSnapshot ? .retrySameConfig : .retryNewConfig
        }
    }

    /// `reviewedCurrent` 必须显式审阅差异（不能静默换模型/CLI/账号/profile）。
    public static func requiresReview(_ intent: RegenerationIntent) -> Bool {
        intent.configurationMode == .reviewedCurrent
    }

    /// generation 可用性：retired/revoked/abandoned 拒绝。
    public static func generationUsable(_ state: CredentialGenerationLifecycleState) -> Bool {
        switch state {
        case .pendingActivation, .active:
            return true
        case .retired, .revoked, .abandoned:
            return false
        }
    }

    /// canonical final CAS（revision compare-and-swap）：lease 有效 + expected revision 匹配 → 单事务写入。
    /// 任一校验失败 → `superseded`（不改 canonical；旧答案保持 lastKnownGood）。
    public static func commitFinalAnswer(
        current: CanonicalFinalAnswer?,
        lease: CanonicalFinalAnswerWriteLease?,
        attemptID: String,
        markdownDigest: String,
        now: Date
    ) -> CanonicalFinalAnswerWriteResult {
        // lease 校验：存在且 active
        guard let lease, lease.state == .active else {
            return .superseded(lateCompletion(attemptID: attemptID, markdownDigest: markdownDigest, now: now))
        }
        // CAS：current.revision == expectedCanonicalRevision
        let currentRevision = current?.revision ?? 0
        guard currentRevision == lease.expectedCanonicalRevision else {
            return .superseded(lateCompletion(attemptID: attemptID, markdownDigest: markdownDigest, now: now))
        }
        let committed = CanonicalFinalAnswer(
            attemptID: attemptID,
            revision: currentRevision + 1,
            markdownSourceDigest: markdownDigest,
            state: .available,
            createdAt: current?.createdAt ?? now,
            completedAt: now,
            lastKnownGood: true
        )
        return .committed(committed)
    }

    /// 迟到完成值（superseded；不改 canonical）。
    public static func lateCompletion(attemptID: String, markdownDigest: String, now: Date) -> CanonicalFinalAnswer {
        CanonicalFinalAnswer(
            attemptID: attemptID,
            revision: 0,
            markdownSourceDigest: markdownDigest,
            state: .regenerating,
            createdAt: now,
            completedAt: now,
            lastKnownGood: false
        )
    }
}

public enum CanonicalFinalAnswerWriteResult: Equatable, Sendable {
    /// CAS 提交成功：canonical 已更新（revision 递增、lastKnownGood）。
    case committed(CanonicalFinalAnswer)
    /// 失去 lease 或 CAS 冲突的迟到完成：不改 canonical（旧答案保持 lastKnownGood）。
    case superseded(CanonicalFinalAnswer)
}
