import CryptoKit
import Foundation

/// Production-only dependencies used by the existing Inspector surface.
/// The Inspector owns presentation; this type owns one durable V2 session.
@MainActor
public final class InspectorConversationRuntime {
    public let sessionID: String
    public let bridge: SessionRuntimeBridge
    public let repository: ConversationRepositoryV2
    public let executionModeState: InspectorConversationExecutionModeState

    public init(
        sessionID: String,
        bridge: SessionRuntimeBridge,
        repository: ConversationRepositoryV2,
        initialExecutionChoice: TurnExecutionChoice,
        executionModeState: InspectorConversationExecutionModeState? = nil
    ) {
        self.sessionID = sessionID
        self.bridge = bridge
        self.repository = repository
        self.executionModeState = executionModeState
            ?? InspectorConversationExecutionModeState(choice: initialExecutionChoice)
    }

    public func updateExecutionChoice(_ choice: TurnExecutionChoice) {
        bridge.setExecutionChoice(choice)
    }

    public func executionMode() -> AgentExecutionMode {
        executionModeState.mode
    }

    public static func stableSessionID(historyScopeID: String, threadID: String) -> String {
        let material = Data("\(historyScopeID)\u{1F}\(threadID)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "inspector-\(digest)"
    }
}

/// One mutable source of truth shared by the Inspector, the V2 bridge and the
/// terminal execution coordinator. A Turn freezes its choice before command
/// dispatch, so later UI changes cannot retarget an approved command.
@MainActor
public final class InspectorConversationExecutionModeState {
    public private(set) var choice: TurnExecutionChoice

    public init(choice: TurnExecutionChoice) {
        self.choice = choice
    }

    /// Only a committed or restored Turn may change the coordinator's mode.
    /// Composer changes describe the next Turn and must not retarget work that
    /// is already streaming, awaiting approval, or executing.
    func applyFrozenTurnChoice(_ choice: TurnExecutionChoice) {
        self.choice = choice
    }

    public var mode: AgentExecutionMode {
        choice == .backgroundVirtualTerminal ? .backgroundTask : .visibleTerminal
    }
}

public typealias InspectorConversationRuntimeFactory = @MainActor (
    _ sessionID: String,
    _ terminalContext: AITerminalContext,
    _ modelSelection: AIModelSelection?
) throws -> InspectorConversationRuntime
