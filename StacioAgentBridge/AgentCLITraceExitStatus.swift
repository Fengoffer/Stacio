import Foundation

public struct AgentCLITraceExitStatus {
    public private(set) var exitCode: Int32 = 0

    public init() {}

    public mutating func observe(socketLine line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(AgentTraceEvent.self, from: data) else {
            return
        }
        if event.state == .failed {
            exitCode = 1
            return
        }
        if event.state == .cancelled,
           event.metadata?["control"] == nil {
            exitCode = 1
        }
    }
}
