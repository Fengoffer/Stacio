import Foundation

/// A bounded, redacted projection of one terminal execution. The view never
/// owns a terminal or executes a command; actions are routed back to the
/// Workbench/SessionRuntimeBridge owners.
public struct TerminalArtifactPresentation: Equatable, Sendable {
    public let requestID: String?
    public let runtimeID: String?
    public let liveTail: String?
    public let exitCode: Int?
    public let durationSeconds: Int?
    public let completionBasis: String?
    public let hasTerminalState: Bool
    public let stateLabel: String
    public let isRealTerminal: Bool
    public let canOpenTerminal: Bool
    public let canCancel: Bool
    public let canSaveRedactedLog: Bool
    public let redactedLog: String

    public init(
        requestID: String? = nil,
        runtimeID: String? = nil,
        liveTail: String?,
        exitCode: Int?,
        durationSeconds: Int?,
        completionBasis: String? = nil,
        hasTerminalState: Bool? = nil,
        stateLabel: String = "",
        isRealTerminal: Bool = true,
        canOpenTerminal: Bool = false,
        canCancel: Bool = false,
        canSaveRedactedLog: Bool = false,
        redactedLog: String = ""
    ) {
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.liveTail = liveTail
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.completionBasis = completionBasis
        self.hasTerminalState = hasTerminalState ?? (exitCode != nil)
        self.stateLabel = stateLabel
        self.isRealTerminal = isRealTerminal
        self.canOpenTerminal = canOpenTerminal
        self.canCancel = canCancel
        self.canSaveRedactedLog = canSaveRedactedLog
        self.redactedLog = redactedLog
    }

    public var isFinished: Bool {
        hasTerminalState || exitCode != nil
    }
}
