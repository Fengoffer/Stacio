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
        var redactNextToken = false
        let redactedTokens = text
            .split(whereSeparator: \.isWhitespace)
            .map { token -> String in
                let value = String(token)
                let lower = value.lowercased()
                if redactNextToken {
                    if isAuthorizationSchemeToken(lower) {
                        return value
                    }
                    redactNextToken = false
                    return "[redacted]"
                }
                if isAuthorizationSchemeToken(lower) {
                    redactNextToken = true
                    return value
                }
                if redactsFollowingToken(lower) {
                    redactNextToken = true
                    return "[redacted]"
                }
                if isSensitiveToken(lower) {
                    return "[redacted]"
                }
                return value
            }
            .joined(separator: " ")
        return redactURLCredentials(in: redactedTokens)
    }

    private static func isAuthorizationSchemeToken(_ lower: String) -> Bool {
        lower == "bearer"
            || lower == "basic"
            || lower.hasSuffix(":bearer")
            || lower.hasSuffix(":basic")
    }

    private static func redactsFollowingToken(_ lower: String) -> Bool {
        var key = lower.trimmingCharacters(in: CharacterSet(charactersIn: "-'\""))
        while key.hasPrefix("-") {
            key.removeFirst()
        }
        if key.hasSuffix(":") {
            key.removeLast()
        }
        return [
            "authorization",
            "proxy-authorization",
            "password",
            "passphrase",
            "secret",
            "token",
            "api_key",
            "apikey",
            "api-key",
            "access_key",
            "access-key",
            "private_key",
            "private-key",
            "credential"
        ].contains(key)
    }

    private static func isSensitiveToken(_ lower: String) -> Bool {
        lower.contains("secret")
            || lower.contains("passphrase")
            || lower.contains("credential")
            || lower.contains("token")
            || lower.contains("token=")
            || lower.contains("password")
            || lower.contains("password=")
            || lower.contains("api_key")
            || lower.contains("apikey")
            || lower.contains("api-key")
            || lower.contains("access_key")
            || lower.contains("access-key")
            || lower.contains("private_key")
            || lower.contains("private-key")
            || lower.contains("authorization")
            || lower.contains("/.ssh/")
            || lower.contains(".ssh/")
    }

    /// 脱敏 URL 内嵌凭据：将 `protocol://user:password@host` 中的 `user:password@` 替换为 `[redacted]@`
    private static func redactURLCredentials(in text: String) -> String {
        // 匹配 scheme://非空白非冒号:非空白非@@
        let pattern = #"://[^\s/:]+:[^\s/@]+@"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "://[redacted]@")
    }

    public static func redactPreservingLineBreaks(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map(redact)
            .joined(separator: "\n")
    }
}
