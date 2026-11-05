import AppKit

public protocol TerminalCloseConfirming {
    @MainActor
    func confirmCloseTerminal(title: String, parentWindow: NSWindow?) -> Bool
}

public struct AppKitTerminalCloseConfirmation: TerminalCloseConfirming {
    public init() {}

    public func confirmCloseTerminal(title: String, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.TerminalLifecycle.closeTitle
        alert.informativeText = L10n.TerminalLifecycle.closeMessage(title: title)
        alert.addButton(withTitle: L10n.TerminalLifecycle.close)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}
