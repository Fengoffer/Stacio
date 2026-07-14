import Foundation

public enum TerminalBroadcastEventKind: Equatable {
    case output
    case userInput
}
public struct TerminalBroadcastEvent: Equatable {
    public let runtimeID: String
    public let kind: TerminalBroadcastEventKind
    public let bytes: [UInt8]
    public let createdAt: Date

    public init(
        runtimeID: String,
        kind: TerminalBroadcastEventKind,
        bytes: [UInt8],
        createdAt: Date = Date()
    ) {
        self.runtimeID = runtimeID
        self.kind = kind
        self.bytes = bytes
        self.createdAt = createdAt
    }
}

public final class TerminalOutputBroadcastHub {
    public static let shared = TerminalOutputBroadcastHub()

    public typealias Subscription = UUID
    public typealias Handler = @MainActor (TerminalBroadcastEvent) -> Void

    @MainActor
    private var handlersByRuntimeID: [String: [Subscription: Handler]] = [:]

    public init() {}

    @MainActor
    public func subscribe(
        runtimeID: String,
        handler: @escaping Handler
    ) -> Subscription {
        let subscription = UUID()
        var handlers = handlersByRuntimeID[runtimeID] ?? [:]
        handlers[subscription] = handler
        handlersByRuntimeID[runtimeID] = handlers
        return subscription
    }

    @MainActor
    public func unsubscribe(runtimeID: String, subscription: Subscription) {
        handlersByRuntimeID[runtimeID]?[subscription] = nil
        if handlersByRuntimeID[runtimeID]?.isEmpty == true {
            handlersByRuntimeID[runtimeID] = nil
        }
    }

    @MainActor
    public func publishOutput(runtimeID: String, bytes: [UInt8]) {
        publish(TerminalBroadcastEvent(runtimeID: runtimeID, kind: .output, bytes: bytes))
    }

    @MainActor
    public func publishUserInput(runtimeID: String, bytes: [UInt8]) {
        publish(TerminalBroadcastEvent(runtimeID: runtimeID, kind: .userInput, bytes: bytes))
    }

    @MainActor
    private func publish(_ event: TerminalBroadcastEvent) {
        guard event.bytes.isEmpty == false,
              let handlers = handlersByRuntimeID[event.runtimeID]
        else {
            return
        }
        for handler in handlers.values {
            handler(event)
        }
    }
}
