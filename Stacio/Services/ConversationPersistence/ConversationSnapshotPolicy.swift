import Foundation

// MARK: - checkpoint 种类与阈值

public enum ConversationCheckpointKind: Equatable, Sendable {
    case modelBody
    case terminalOutput
}

public struct SnapshotThresholds: Equatable, Sendable {
    /// 模型正文 1s / 16KiB
    public var modelBodyInterval: TimeInterval
    public var modelBodyBytes: Int
    /// 终端输出 1s / 64KiB
    public var terminalOutputInterval: TimeInterval
    public var terminalOutputBytes: Int

    public init(
        modelBodyInterval: TimeInterval = 1.0,
        modelBodyBytes: Int = 16 * 1024,
        terminalOutputInterval: TimeInterval = 1.0,
        terminalOutputBytes: Int = 64 * 1024
    ) {
        self.modelBodyInterval = modelBodyInterval
        self.modelBodyBytes = modelBodyBytes
        self.terminalOutputInterval = terminalOutputInterval
        self.terminalOutputBytes = terminalOutputBytes
    }
}

// MARK: - flush 判定

public enum SnapshotFlushReason: Equatable, Sendable {
    case intervalElapsed(kind: ConversationCheckpointKind)
    case byteThreshold(kind: ConversationCheckpointKind)
}

public struct SnapshotDecision: Equatable, Sendable {
    public var shouldCheckpoint: Bool
    public var reason: SnapshotFlushReason?
    /// SecureInputLease 期间豁免（安全隔离，不计为意外数据丢失）
    public var omittedDuringSecureInput: Bool

    public init(shouldCheckpoint: Bool, reason: SnapshotFlushReason?, omittedDuringSecureInput: Bool) {
        self.shouldCheckpoint = shouldCheckpoint
        self.reason = reason
        self.omittedDuringSecureInput = omittedDuringSecureInput
    }
}

/// 强制 flush 边界（进入 Decision / 执行 Effect / 停止 / 终态前）
public enum ConversationFlushBoundary: Equatable, Sendable {
    case enteringDecision
    case executingEffect
    case stopping
    case terminalState
}

public enum ConversationSnapshotPolicy {
    /// checkpoint 判定：1s/16KiB（模型正文）与 1s/64KiB（终端输出）任一先到即合并提交。
    /// SecureInputLease 期间主动暂停内容 checkpoint（§8.3/§14.5：安全隔离，不计为丢失）。
    public static func shouldCheckpoint(
        kind: ConversationCheckpointKind,
        lastCheckpointAt: Date?,
        accumulatedBytes: Int,
        now: Date,
        thresholds: SnapshotThresholds,
        secureInputActive: Bool
    ) -> SnapshotDecision {
        if secureInputActive {
            return SnapshotDecision(
                shouldCheckpoint: false, reason: nil, omittedDuringSecureInput: true
            )
        }
        let interval: TimeInterval
        let byteLimit: Int
        switch kind {
        case .modelBody:
            interval = thresholds.modelBodyInterval
            byteLimit = thresholds.modelBodyBytes
        case .terminalOutput:
            interval = thresholds.terminalOutputInterval
            byteLimit = thresholds.terminalOutputBytes
        }
        if accumulatedBytes >= byteLimit {
            return SnapshotDecision(
                shouldCheckpoint: true,
                reason: .byteThreshold(kind: kind),
                omittedDuringSecureInput: false
            )
        }
        if let last = lastCheckpointAt, now.timeIntervalSince(last) >= interval {
            return SnapshotDecision(
                shouldCheckpoint: true,
                reason: .intervalElapsed(kind: kind),
                omittedDuringSecureInput: false
            )
        }
        return SnapshotDecision(
            shouldCheckpoint: false, reason: nil, omittedDuringSecureInput: false
        )
    }

    /// 进入 Decision / 执行 Effect / 停止 / 终态前强制 flush（恒必须）。
    public static func forceFlushBefore(_ boundary: ConversationFlushBoundary) -> Bool {
        true
    }

    /// 磁盘不足暂停新 Turn。
    public static func diskInsufficientBlocksNewTurn(
        availableBytes: Int64,
        minimumRequired: Int64
    ) -> Bool {
        availableBytes < minimumRequired
    }
}

// MARK: - ConversationRetentionPolicy（保留/配额门禁）

public struct ConversationRetentionPolicy: Equatable, Sendable {
    public var maxConversationCount: Int
    public var maxConversationBytes: Int64

    public init(maxConversationCount: Int, maxConversationBytes: Int64) {
        self.maxConversationCount = maxConversationCount
        self.maxConversationBytes = maxConversationBytes
    }

    public func allowsNewConversation(currentCount: Int, currentBytes: Int64) -> Bool {
        currentCount < maxConversationCount && currentBytes < maxConversationBytes
    }

    public func allowsAppend(currentBytes: Int64, additionalBytes: Int64) -> Bool {
        currentBytes + additionalBytes <= maxConversationBytes
    }
}
