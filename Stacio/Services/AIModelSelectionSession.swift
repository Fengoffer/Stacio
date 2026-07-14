import Foundation

public final class AIModelSelectionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AIModelSelection?

    public init(selection: AIModelSelection? = nil) {
        value = selection
    }

    public func snapshot() -> AIModelSelection? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func select(_ selection: AIModelSelection?) {
        lock.lock()
        value = selection
        lock.unlock()
    }
}
