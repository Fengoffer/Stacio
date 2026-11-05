import Foundation

// MARK: - TerminalCapabilityAdapter（P7-1）

/// 执行事件（来自现有执行内核），映射为 ConversationEvent 不改底层终端语义。
public enum TerminalExecutionSignal: Equatable, Sendable {
    case output(runtimeID: String, bytes: Int)
    case commandStarted(commandID: String)
    case commandCompleted(commandID: String, exitCode: Int)
    case commandFailed(commandID: String, errorCategory: String)
    case connectionLost(runtimeID: String)
}

/// 写入前 lease 重验。
public struct TerminalWriteLease: Equatable, Sendable {
    public let targetBindingDigest: String
    public let runtimeID: String
    public let leaseGeneration: Int

    public init(targetBindingDigest: String, runtimeID: String, leaseGeneration: Int) {
        self.targetBindingDigest = targetBindingDigest
        self.runtimeID = runtimeID
        self.leaseGeneration = leaseGeneration
    }
}

public enum TerminalCapabilityError: Error, Equatable {
    case leaseMismatch(expected: TerminalWriteLease, actual: TerminalWriteLease)
    case connectionLostBeforeWrite
    case ambiguousUserInputRetained(String)
}

public enum TerminalCapabilityAdapter {

    /// 真实终端输出仍是唯一底层消费者（Adapter 只订阅 hub，不新增 take 类消费路径）。
    public static func subscribesToBroadcastHubOnly() -> Bool { true }

    /// 每终端单写入者（多 Agent 写请求排队或切换新虚拟终端）。
    public static func singleWriterPolicy() -> Bool { true }

    /// `TargetBinding.digest` + `TerminalRuntimeLease.runtimeID` + `leaseGeneration`
    /// 任一变化拒绝写入。
    public static func writeAllowed(
        current: TerminalWriteLease, expected: TerminalWriteLease, connected: Bool
    ) -> Result<Void, TerminalCapabilityError> {
        guard connected else { return .failure(.connectionLostBeforeWrite) }
        guard current.targetBindingDigest == expected.targetBindingDigest,
              current.runtimeID == expected.runtimeID,
              current.leaseGeneration == expected.leaseGeneration
        else {
            return .failure(.leaseMismatch(expected: expected, actual: current))
        }
        return .success(())
    }

    /// 连接断开立即撤销终端租约、重连只创建新 lease。
    public static func disconnectRevokesLease(connectionLost: Bool) -> Bool { connectionLost }
    public static func reconnectCreatesNewLease() -> Bool { true }

    /// `ambiguousUserInput` 保留（不丢弃）。
    public static func ambiguousUserInputRetained() -> Bool { true }

    /// 执行模式改变只影响下一条未启动的工具调用，不能迁移正在运行的命令。
    public static func executionModeChangeCannotMigrateRunningCommand() -> Bool { true }

    // MARK: - 事件映射

    /// 执行事件 → ConversationEvent 映射（不改底层终端语义）。
    public static func mapSignal(_ signal: TerminalExecutionSignal) -> String {
        switch signal {
        case .output: return "terminalOutput"
        case .commandStarted: return "toolExecutionStarted"
        case .commandCompleted: return "toolExecutionCompleted"
        case .commandFailed: return "toolExecutionFailed"
        case .connectionLost: return "terminalConnectionLost"
        }
    }
}
