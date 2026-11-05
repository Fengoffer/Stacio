import AppKit
import StacioAgentBridge
import StacioCoreBindings

public protocol TerminalMacroStoring {
    func listMacros() throws -> [TerminalMacroRecord]
    func createMacro(name: String, commands: [String], delayMS: UInt32) throws -> TerminalMacroRecord
    func updateMacro(id: String, name: String, commands: [String], delayMS: UInt32) throws -> TerminalMacroRecord
    func renameMacro(id: String, name: String) throws -> TerminalMacroRecord
    func deleteMacro(id: String) throws
}

public struct CoreBridgeTerminalMacroStore: TerminalMacroStoring {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public static func defaultStore() -> CoreBridgeTerminalMacroStore? {
        guard let databasePath = try? StacioPaths().databaseURL.path else {
            return nil
        }
        return CoreBridgeTerminalMacroStore(databasePath: databasePath)
    }

    public func listMacros() throws -> [TerminalMacroRecord] {
        try CoreBridge.listTerminalMacros(databasePath: databasePath)
    }

    public func createMacro(name: String, commands: [String], delayMS: UInt32 = 300) throws -> TerminalMacroRecord {
        try CoreBridge.createTerminalMacro(
            databasePath: databasePath,
            name: name,
            steps: Self.steps(from: commands, delayMS: delayMS)
        )
    }

    public func updateMacro(id: String, name: String, commands: [String], delayMS: UInt32 = 300) throws -> TerminalMacroRecord {
        try CoreBridge.updateTerminalMacro(
            databasePath: databasePath,
            macroID: id,
            name: name,
            steps: Self.steps(from: commands, delayMS: delayMS)
        )
    }

    public func renameMacro(id: String, name: String) throws -> TerminalMacroRecord {
        try CoreBridge.renameTerminalMacro(databasePath: databasePath, macroID: id, name: name)
    }

    public func deleteMacro(id: String) throws {
        try CoreBridge.deleteTerminalMacro(databasePath: databasePath, macroID: id)
    }

    private static func steps(from commands: [String], delayMS: UInt32) -> [MacroStep] {
        commands.enumerated().map { index, command in
            MacroStep(
                order: UInt32(index + 1),
                input: AgentProtocolRedaction.redact(command),
                delayMs: delayMS
            )
        }
    }
}

public final class TerminalMacroRecorder {
    public private(set) var isRecording = false
    public var isCaptureSuppressed = false
    public let defaultDelayMS: UInt32

    private let store: TerminalMacroStoring
    private var commands: [String] = []

    public init(store: TerminalMacroStoring, defaultDelayMS: UInt32 = 300) {
        self.store = store
        self.defaultDelayMS = defaultDelayMS
    }

    public var recordedCommandCount: Int {
        commands.count
    }

    public func startRecording() {
        commands.removeAll()
        isRecording = true
    }

    public func cancelRecording() {
        commands.removeAll()
        isRecording = false
    }

    public func recordSubmittedCommand(_ command: String) {
        guard isRecording,
              isCaptureSuppressed == false
        else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commands.append(trimmed)
    }

    @discardableResult
    public func stopRecording(name: String) throws -> TerminalMacroRecord? {
        defer {
            commands.removeAll()
            isRecording = false
        }
        guard isRecording,
              commands.isEmpty == false
        else {
            return nil
        }
        return try store.createMacro(
            name: name,
            commands: commands,
            delayMS: defaultDelayMS
        )
    }
}

public protocol TerminalMacroPlaybackTarget: AnyObject {
    func sendInput(_ bytes: [UInt8])
}

public protocol TerminalMacroPlaybackScheduling {
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void)
}

public struct DispatchTerminalMacroPlaybackScheduler: TerminalMacroPlaybackScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

public protocol TerminalMacroRiskConfirming {
    @MainActor
    func confirmDangerousMacro(_ macro: TerminalMacroRecord, risk: AgentActionRisk, parentWindow: NSWindow?) -> Bool
}

public struct AppKitTerminalMacroRiskConfirmer: TerminalMacroRiskConfirming {
    public init() {}

    @MainActor
    public func confirmDangerousMacro(_ macro: TerminalMacroRecord, risk: AgentActionRisk, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.TerminalMacro.dangerousPlaybackTitle
        alert.informativeText = L10n.TerminalMacro.dangerousPlaybackMessage(name: macro.name)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.TerminalMacro.playAnyway)
        alert.addButton(withTitle: L10n.Common.cancel)
        _ = parentWindow
        return alert.runModal() == .alertFirstButtonReturn
    }
}

public protocol TerminalMacroMessagePresenting {
    @MainActor
    func presentMacroMessage(title: String, message: String, parentWindow: NSWindow?)
}

public struct AppKitTerminalMacroMessagePresenter: TerminalMacroMessagePresenting {
    public init() {}

    @MainActor
    public func presentMacroMessage(title: String, message: String, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.Common.ok)
        _ = parentWindow
        _ = alert.runModal()
    }
}

public enum TerminalMacroPlaybackResult: Equatable {
    case started
    case noTerminal
    case empty
    case cancelled
}

public final class TerminalMacroPlaybackCoordinator {
    public var onPlaybackStateChanged: ((Bool) -> Void)?

    private let scheduler: TerminalMacroPlaybackScheduling
    private let riskConfirmer: TerminalMacroRiskConfirming
    private let messagePresenter: TerminalMacroMessagePresenting

    public init(
        scheduler: TerminalMacroPlaybackScheduling = DispatchTerminalMacroPlaybackScheduler(),
        riskConfirmer: TerminalMacroRiskConfirming = AppKitTerminalMacroRiskConfirmer(),
        messagePresenter: TerminalMacroMessagePresenting = AppKitTerminalMacroMessagePresenter()
    ) {
        self.scheduler = scheduler
        self.riskConfirmer = riskConfirmer
        self.messagePresenter = messagePresenter
    }

    @MainActor
    public func play(
        macro: TerminalMacroRecord,
        target: TerminalMacroPlaybackTarget?,
        parentWindow: NSWindow?
    ) -> TerminalMacroPlaybackResult {
        guard let target else {
            messagePresenter.presentMacroMessage(
                title: L10n.TerminalMacro.noTerminalTitle,
                message: L10n.TerminalMacro.noTerminalMessage,
                parentWindow: parentWindow
            )
            return .noTerminal
        }
        let steps = macro.steps
            .sorted { lhs, rhs in lhs.order < rhs.order }
            .filter { $0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard steps.isEmpty == false else {
            return .empty
        }
        let highestRisk = steps
            .map { AgentActionClassifier.risk(forCommand: $0.input) }
            .max() ?? .readOnly
        if highestRisk >= .destructive,
           riskConfirmer.confirmDangerousMacro(macro, risk: highestRisk, parentWindow: parentWindow) == false
        {
            return .cancelled
        }

        onPlaybackStateChanged?(true)
        send(steps: steps, index: 0, target: target)
        return .started
    }

    private func send(steps: [MacroStep], index: Int, target: TerminalMacroPlaybackTarget) {
        let step = steps[index]
        let input = step.input.hasSuffix("\n") ? step.input : "\(step.input)\n"
        target.sendInput(Array(input.utf8))

        let nextIndex = index + 1
        guard nextIndex < steps.count else {
            onPlaybackStateChanged?(false)
            return
        }
        let delay = TimeInterval(step.delayMs == 0 ? 300 : step.delayMs) / 1_000
        scheduler.schedule(after: delay) { [weak self, weak target] in
            guard let target else {
                self?.onPlaybackStateChanged?(false)
                return
            }
            self?.send(steps: steps, index: nextIndex, target: target)
        }
    }
}

extension TerminalPaneViewController: TerminalMacroPlaybackTarget {}
extension RemoteTerminalPaneViewController: TerminalMacroPlaybackTarget {}
