import StacioCoreBindings

public struct SSHSessionStartupBanner {
    public let context: TunnelLiveSessionContext
    public let title: String
    public let runtimeID: String?
    public let initialRemotePath: String
    public let terminalHighlightLevel: TerminalHighlightLevelPreference
    public let automationPolicy: SessionAutomationPolicy

    public init(
        context: TunnelLiveSessionContext,
        title: String,
        runtimeID: String? = nil,
        initialRemotePath: String = "~",
        terminalHighlightLevel: TerminalHighlightLevelPreference = .ansiOnly,
        automationPolicy: SessionAutomationPolicy = .default
    ) {
        self.context = context
        self.title = title
        self.runtimeID = runtimeID
        self.terminalHighlightLevel = terminalHighlightLevel
        self.automationPolicy = automationPolicy
        let trimmedInitialRemotePath = initialRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialRemotePath = trimmedInitialRemotePath.isEmpty ? "~" : trimmedInitialRemotePath
    }

    public func rendered() -> String {
        let config = context.config
        let host = Self.hostDescription(config)
        let portSuffix = config.port == 22 ? "" : ":\(Self.number(String(config.port)))"
        var lines = [
            "\(Self.title("Stacio SSH connected"))",
            "Host: \(Self.user(config.username))@\(host)\(portSuffix)",
            "TERM=\(Self.resource("xterm-256color"))  COLORTERM=\(Self.resource("truecolor"))",
            "Session: \(Self.value(runtimeID ?? "-"))  Path: \(Self.path(initialRemotePath))",
            "Docs: \(Self.link("https://docs.stacio.app/terminal"))",
            "Highlight: \(Self.value(Self.highlightSummary(for: terminalHighlightLevel)))",
            "Try: \(Self.command("pwd && uname -a"))"
        ]
        if let startupPlan = automationPolicy.startupPlanShellLine {
            lines.append("Startup plan: \(Self.command(startupPlan)) \(Self.value("(not executed automatically)"))")
        }
        lines.append("")

        return lines.joined(separator: "\r\n")
    }

    private static func hostDescription(_ config: SshConnectionConfig) -> String {
        if isIPAddress(config.host) {
            return number(config.host)
        }
        return host(config.host)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        value.allSatisfy { character in
            character.isNumber || character == "." || character == ":" || character == "[" || character == "]"
        }
    }

    private static func title(_ value: String) -> String {
        value
    }

    private static func user(_ value: String) -> String {
        value
    }

    private static func host(_ value: String) -> String {
        value
    }

    private static func number(_ value: String) -> String {
        value
    }

    private static func resource(_ value: String) -> String {
        value
    }

    private static func value(_ value: String) -> String {
        value
    }

    private static func path(_ value: String) -> String {
        value
    }

    private static func command(_ value: String) -> String {
        value
    }

    private static func link(_ value: String) -> String {
        value
    }

    private static func highlightSummary(for level: TerminalHighlightLevelPreference) -> String {
        switch level {
        case .off:
            return "off"
        case .ansiOnly:
            return "ANSI colors ready"
        case .commandLineEnhanced:
            return "ANSI colors and command hints ready"
        }
    }
}
