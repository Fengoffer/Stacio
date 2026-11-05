import Foundation

public enum AgentCLIOutputRenderer {
    public static func render(socketLine line: String, mode: AgentCLIOutputMode) -> String {
        switch mode {
        case .json:
            return line
        case .text:
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(AgentTraceEvent.self, from: data) else {
                return line
            }
            return textLine(for: event)
        }
    }

    private static func textLine(for event: AgentTraceEvent) -> String {
        if event.metadata?["type"] == "terminalSession" {
            return terminalSessionLine(for: event)
        }
        if let control = trimmedNonEmpty(event.metadata?["control"]) {
            return controlLine(for: event, control: control)
        }
        if let terminalOutput = trimmedNonEmpty(event.metadata?["terminalOutputSummary"]) {
            return terminalFeedbackLine(for: event, output: terminalOutput)
        }
        let command = event.redactedCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command, command.isEmpty == false else {
            return "[\(event.state.rawValue)] \(event.message)"
        }
        return "[\(event.state.rawValue)] \(event.message) | \(command)"
    }

    private static func terminalFeedbackLine(for event: AgentTraceEvent, output: String) -> String {
        var lines = [
            "[terminal-status] \(event.state.rawValue) | request=\(event.requestID)"
        ]
        if let command = trimmedNonEmpty(event.redactedCommand) {
            lines.append("[terminal-command] \(command)")
        }
        lines.append("[terminal-output]")
        lines.append(output)
        lines.append("[/terminal-output]")
        return lines.joined(separator: "\n")
    }

    private static func controlLine(for event: AgentTraceEvent, control: String) -> String {
        let command = trimmedNonEmpty(event.redactedCommand)
        let mode = trimmedNonEmpty(event.metadata?["executionMode"])
        var head = "[\(event.state.rawValue)] \(event.requestID) \(control)"
        if let mode {
            head += " \(mode)"
        }
        guard let command else {
            return "\(head) | \(event.message)"
        }
        return "\(head) | \(event.message) | \(command)"
    }

    private static func terminalSessionLine(for event: AgentTraceEvent) -> String {
        let metadata = event.metadata ?? [:]
        let runtimeID = metadata["runtimeID"] ?? "-"
        let title = metadata["title"] ?? event.message
        let kind = metadata["kind"] ?? "terminal"
        let environment = metadata["environment"] ?? "development"
        let current = metadata["current"] == "true" ? " current" : ""
        var parts = ["[session\(current)] \(runtimeID)", title, kind, environment]
        if let subtitle = trimmedNonEmpty(metadata["subtitle"]) {
            parts.append(subtitle)
        }
        if let currentDirectory = trimmedNonEmpty(metadata["currentDirectory"]),
           currentDirectory != metadata["subtitle"] {
            parts.append(currentDirectory)
        }
        return parts.joined(separator: " | ")
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
