import Foundation

public struct ExecutionCardPresentation: Equatable, Sendable {
    public let proposalID: String
    public let target: String
    public let targetRuntimeID: String?
    public let workingDirectory: String
    public let redactedCommand: String
    public let riskAndApproval: String
    public let isRealTerminal: Bool
    public let exitCode: Int?
    public let durationSeconds: Int?
    public let completionBasis: String
    public let status: String
    public let terminalArtifact: TerminalArtifactPresentation?
    public let holdsTransferableHandle: Bool

    public init(
        proposalID: String = "",
        target: String,
        targetRuntimeID: String? = nil,
        workingDirectory: String,
        redactedCommand: String,
        riskAndApproval: String,
        isRealTerminal: Bool,
        exitCode: Int?,
        durationSeconds: Int?,
        completionBasis: String,
        status: String = "",
        terminalArtifact: TerminalArtifactPresentation? = nil,
        holdsTransferableHandle: Bool = false
    ) {
        self.proposalID = proposalID
        self.target = target
        self.targetRuntimeID = targetRuntimeID
        self.workingDirectory = workingDirectory
        self.redactedCommand = redactedCommand
        self.riskAndApproval = riskAndApproval
        self.isRealTerminal = isRealTerminal
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.completionBasis = completionBasis
        self.status = status
        self.terminalArtifact = terminalArtifact
        self.holdsTransferableHandle = holdsTransferableHandle
    }

    public var isFinished: Bool {
        terminalArtifact?.isFinished == true || exitCode != nil
    }
}
