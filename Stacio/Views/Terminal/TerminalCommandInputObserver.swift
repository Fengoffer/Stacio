import Foundation
import StacioAgentBridge

public struct TerminalSubmittedCommandHint: Equatable {
    public let command: String
    public let summary: String
    public let riskLabel: String

    public init(command: String, summary: String, riskLabel: String) {
        self.command = command
        self.summary = summary
        self.riskLabel = riskLabel
    }

    public var visibleText: String {
        [summary, riskLabel, command]
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
    }
}

public struct TerminalCommandInputObservation: Equatable {
    public let submittedHint: TerminalSubmittedCommandHint?
    public let completionSuggestion: TerminalCommandCompletionSuggestion?
    public let acceptedCompletionBytes: [UInt8]?
    public let shouldConsumeInput: Bool
    public let currentLine: String

    public init(
        submittedHint: TerminalSubmittedCommandHint? = nil,
        completionSuggestion: TerminalCommandCompletionSuggestion? = nil,
        acceptedCompletionBytes: [UInt8]? = nil,
        shouldConsumeInput: Bool = false,
        currentLine: String = ""
    ) {
        self.submittedHint = submittedHint
        self.completionSuggestion = completionSuggestion
        self.acceptedCompletionBytes = acceptedCompletionBytes
        self.shouldConsumeInput = shouldConsumeInput
        self.currentLine = currentLine
    }

    public static let empty = TerminalCommandInputObservation()
}

public final class TerminalCommandInputObserver {
    private var buffer: [UInt8] = []
    private var usedCompletion = false
    private var activeCompletion: TerminalCommandCompletionSuggestion?

    public init() {}

    public func ingest(
        bytes: [UInt8],
        settings: AppSettings = AppSettings(),
        historyCommands: [String] = [],
        pathCompletionProvider: TerminalPathCompletionProviding? = nil
    ) -> TerminalCommandInputObservation {
        if isEscapeSequence(bytes) {
            if let activeCompletion {
                if bytes == [27, 91, 65] {
                    let suggestion = activeCompletion.selectingPrevious()
                    self.activeCompletion = suggestion
                    return TerminalCommandInputObservation(
                        completionSuggestion: suggestion,
                        shouldConsumeInput: true,
                        currentLine: currentLine
                    )
                }
                if bytes == [27, 91, 66] {
                    let suggestion = activeCompletion.selectingNext()
                    self.activeCompletion = suggestion
                    return TerminalCommandInputObservation(
                        completionSuggestion: suggestion,
                        shouldConsumeInput: true,
                        currentLine: currentLine
                    )
                }
                self.activeCompletion = nil
            }
            return TerminalCommandInputObservation.empty
        }

        if let activeCompletion {
            if bytes == [27] {
                self.activeCompletion = nil
                return TerminalCommandInputObservation(shouldConsumeInput: true, currentLine: currentLine)
            }
            if bytes == [9] {
                return acceptCompletion(
                    activeCompletion,
                    submits: false,
                    settings: settings,
                    historyCommands: historyCommands,
                    pathCompletionProvider: pathCompletionProvider
                )
            }
        }

        var submittedHint: TerminalSubmittedCommandHint?
        var completionSuggestion: TerminalCommandCompletionSuggestion?
        var acceptedCompletionBytes: [UInt8]?
        var shouldConsumeInput = false
        func currentSuggestion() -> TerminalCommandCompletionSuggestion? {
            let suggestion = TerminalCommandCompletionEngine.suggestion(
                for: currentLine,
                settings: settings,
                historyCommands: historyCommands,
                pathCompletionProvider: pathCompletionProvider
            )
            activeCompletion = suggestion
            return suggestion
        }
        for byte in bytes {
            switch byte {
            case 10, 13:
                submittedHint = processSubmittedLine() ?? submittedHint
                completionSuggestion = nil
                activeCompletion = nil
            case 3, 21, 27:
                buffer.removeAll()
                usedCompletion = false
                completionSuggestion = nil
                activeCompletion = nil
            case 9:
                if let suggestion = currentSuggestion() {
                    let completionBytes = Array(suggestion.insertion.utf8)
                    buffer.append(contentsOf: completionBytes)
                    acceptedCompletionBytes = completionBytes
                    shouldConsumeInput = true
                    completionSuggestion = currentSuggestion()
                } else {
                    usedCompletion = true
                    completionSuggestion = nil
                }
            case 8, 127:
                removeLastCharacter()
                completionSuggestion = currentSuggestion()
            case 0..<32:
                continue
            default:
                buffer.append(byte)
                completionSuggestion = currentSuggestion()
            }
        }
        return TerminalCommandInputObservation(
            submittedHint: submittedHint,
            completionSuggestion: completionSuggestion,
            acceptedCompletionBytes: acceptedCompletionBytes,
            shouldConsumeInput: shouldConsumeInput,
            currentLine: currentLine
        )
    }

    public func reset() {
        buffer.removeAll()
        usedCompletion = false
        activeCompletion = nil
    }

    public func refreshCompletion(
        settings: AppSettings = AppSettings(),
        historyCommands: [String] = [],
        pathCompletionProvider: TerminalPathCompletionProviding? = nil
    ) -> TerminalCommandInputObservation {
        let suggestion = TerminalCommandCompletionEngine.suggestion(
            for: currentLine,
            settings: settings,
            historyCommands: historyCommands,
            pathCompletionProvider: pathCompletionProvider
        )
        activeCompletion = suggestion
        return TerminalCommandInputObservation(
            completionSuggestion: suggestion,
            currentLine: currentLine
        )
    }

    private func acceptCompletion(
        _ suggestion: TerminalCommandCompletionSuggestion,
        submits: Bool,
        settings: AppSettings,
        historyCommands: [String],
        pathCompletionProvider: TerminalPathCompletionProviding?
    ) -> TerminalCommandInputObservation {
        let insertionBytes = Array(suggestion.insertion.utf8)
        buffer.append(contentsOf: insertionBytes)
        usedCompletion = false

        if submits {
            let submittedHint = processSubmittedLine()
            activeCompletion = nil
            return TerminalCommandInputObservation(
                submittedHint: submittedHint,
                acceptedCompletionBytes: insertionBytes + [10],
                shouldConsumeInput: true,
                currentLine: currentLine
            )
        }

        let nextSuggestion = TerminalCommandCompletionEngine.suggestion(
            for: currentLine,
            settings: settings,
            historyCommands: historyCommands,
            pathCompletionProvider: pathCompletionProvider
        )
        activeCompletion = nextSuggestion
        return TerminalCommandInputObservation(
            completionSuggestion: nextSuggestion,
            acceptedCompletionBytes: insertionBytes,
            shouldConsumeInput: true,
            currentLine: currentLine
        )
    }

    private func processSubmittedLine() -> TerminalSubmittedCommandHint? {
        guard buffer.isEmpty == false else {
            usedCompletion = false
            return nil
        }
        let line = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        guard usedCompletion == false else {
            usedCompletion = false
            return nil
        }
        usedCompletion = false
        guard line.isEmpty == false else { return nil }
        let result = TerminalCommandHighlighter.highlight(line)
        guard result.primaryCommand != nil else { return nil }
        return TerminalSubmittedCommandHint(
            command: line,
            summary: result.summary,
            riskLabel: TerminalCommandInputObserver.label(for: result.risk)
        )
    }

    private func removeLastCharacter() {
        guard buffer.isEmpty == false else { return }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer = Array(text.dropLast().utf8)
    }

    private var currentLine: String {
        String(decoding: buffer, as: UTF8.self)
    }

    private func isEscapeSequence(_ bytes: [UInt8]) -> Bool {
        bytes.count > 1 && bytes.first == 27
    }

    private static func label(for risk: AgentActionRisk) -> String {
        switch risk {
        case .readOnly:
            return L10n.AI.commandRiskReadOnly
        case .write:
            return L10n.AI.commandRiskWrite
        case .network:
            return L10n.AI.commandRiskNetwork
        case .destructive:
            return L10n.AI.commandRiskDestructive
        }
    }
}
