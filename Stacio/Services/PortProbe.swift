import Foundation
import Network

public enum PortProbeResult: Equatable {
    case reachable
    case unreachable
}

public protocol PortProbing: AnyObject {
    @MainActor
    func checkPort(host: String, port: UInt16, completion: @escaping @MainActor (PortProbeResult) -> Void)
}

public final class NetworkPortProbe: PortProbing {
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "Stacio.NetworkPortProbe")

    public init(timeout: TimeInterval = 1.5) {
        self.timeout = timeout
    }

    @MainActor
    public func checkPort(host: String, port: UInt16, completion: @escaping @MainActor (PortProbeResult) -> Void) {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            completion(.unreachable)
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: networkPort,
            using: .tcp
        )
        let state = CompletionState()

        connection.stateUpdateHandler = { nextState in
            switch nextState {
            case .ready:
                state.complete(.reachable, connection: connection, completion: completion)
            case .failed, .waiting:
                state.complete(.unreachable, connection: connection, completion: completion)
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) {
            state.complete(.unreachable, connection: connection, completion: completion)
        }

        connection.start(queue: queue)
    }
}

private final class CompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func complete(
        _ result: PortProbeResult,
        connection: NWConnection,
        completion: @escaping @MainActor (PortProbeResult) -> Void
    ) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()

        connection.cancel()
        Task { @MainActor in
            completion(result)
        }
    }
}
