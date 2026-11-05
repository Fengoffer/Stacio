import Foundation

public final class TunnelLiveSessionStore: CustomStringConvertible {
    private let lock = NSLock()
    private var context: TunnelLiveSessionContext?

    public init() {}

    public func current() -> TunnelLiveSessionContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    public func replace(with context: TunnelLiveSessionContext) {
        lock.lock()
        self.context = context
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        context = nil
        lock.unlock()
    }

    public var description: String {
        guard let context = current() else {
            return "TunnelLiveSessionStore(current: nil)"
        }
        return "TunnelLiveSessionStore(current: \(TunnelLiveSessionSummary(context: context)))"
    }
}

private struct TunnelLiveSessionSummary: CustomStringConvertible {
    let context: TunnelLiveSessionContext

    var description: String {
        "TunnelLiveSessionContext(host: \(context.config.host), port: \(context.config.port), username: \(context.config.username), authMethod: \(authMethodLabel), expectedFingerprintSHA256: \(context.expectedFingerprintSHA256))"
    }

    private var authMethodLabel: String {
        switch context.config.authMethod {
        case .password:
            "password"
        case .privateKey:
            "private_key"
        case .agent:
            "agent"
        }
    }
}
