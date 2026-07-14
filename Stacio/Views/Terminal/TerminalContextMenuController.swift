import AppKit

public struct TerminalAIContextRequest: Equatable {
    public let runtimeID: String
    public let selectedText: String?

    public init(runtimeID: String, selectedText: String?) {
        self.runtimeID = runtimeID
        self.selectedText = selectedText
    }
}

@MainActor
public final class TerminalContextMenuController: NSObject {
    private let runtimeID: String
    private let paste: () -> Void
    private let askAI: (TerminalAIContextRequest) -> Void

    public init(
        runtimeID: String,
        paste: @escaping () -> Void,
        askAI: @escaping (TerminalAIContextRequest) -> Void
    ) {
        self.runtimeID = runtimeID
        self.paste = paste
        self.askAI = askAI
    }

    public func makeMenu(selectedText: String?) -> NSMenu {
        let trimmedSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelection = trimmedSelection?.isEmpty == false
        let menu = NSMenu(title: "Terminal")

        let pasteItem = NSMenuItem(title: L10n.Menu.paste, action: #selector(pastePressed(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        let askItem = NSMenuItem(title: L10n.AI.askFromTerminal, action: #selector(askPressed(_:)), keyEquivalent: "")
        askItem.target = self
        askItem.representedObject = selectedText
        menu.addItem(askItem)

        if hasSelection {
            let explainItem = NSMenuItem(
                title: L10n.AI.explainSelection,
                action: #selector(askPressed(_:)),
                keyEquivalent: ""
            )
            explainItem.target = self
            explainItem.representedObject = selectedText
            menu.addItem(explainItem)
        }

        return menu
    }

    @objc private func pastePressed(_ sender: Any?) {
        paste()
    }

    @objc private func askPressed(_ sender: NSMenuItem) {
        askAI(
            TerminalAIContextRequest(
                runtimeID: runtimeID,
                selectedText: sender.representedObject as? String
            )
        )
    }
}
