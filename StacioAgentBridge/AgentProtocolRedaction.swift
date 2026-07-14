import Foundation

public extension AgentBridgeRequest {
    func redactedForLog() -> AgentBridgeRequest {
        switch action {
        case .listSessions, .pauseTask, .cancelTask, .takeOverTask:
            return self
        case .runCommand(let run):
            return AgentBridgeRequest(
                id: id,
                actor: actor,
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: run.target,
                        command: AgentProtocolRedaction.redact(run.command),
                        follow: run.follow
                    )
                )
            )
        }
    }
}

public enum AgentProtocolRedaction {
    public static func redact(_ text: String) -> String {
        var shouldRedactNextBearerValue = false
        return text
            .split(whereSeparator: \.isWhitespace)
            .map { token -> String in
                let lower = token.lowercased()
                if shouldRedactNextBearerValue {
                    shouldRedactNextBearerValue = false
                    return "[redacted]"
                }
                if lower == "bearer" || lower.hasSuffix(":bearer") {
                    shouldRedactNextBearerValue = true
                    return String(token)
                }
                return lower.contains("secret")
                    || lower.contains("passphrase")
                    || lower.contains("credential")
                    || lower.contains("token")
                    || lower.contains("token=")
                    || lower.contains("password")
                    || lower.contains("password=")
                    || lower.contains("/.ssh/")
                    || lower.contains(".ssh/")
                    ? "[redacted]"
                    : String(token)
            }
            .joined(separator: " ")
    }
}
