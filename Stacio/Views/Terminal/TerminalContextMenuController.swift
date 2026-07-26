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
    private let canAskAI: () -> Bool
    private let disabledAIActionToolTip: String?

    public init(
        runtimeID: String,
        paste: @escaping () -> Void,
        askAI: @escaping (TerminalAIContextRequest) -> Void,
        canAskAI: @escaping () -> Bool = { true },
        disabledAIActionToolTip: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.paste = paste
        self.askAI = askAI
        self.canAskAI = canAskAI
        self.disabledAIActionToolTip = disabledAIActionToolTip
    }

    public func makeMenu(selectedText: String?) -> NSMenu {
        let trimmedSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelection = trimmedSelection?.isEmpty == false
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false

        let pasteItem = NSMenuItem(title: L10n.Menu.paste, action: #selector(pastePressed(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        let askItem = NSMenuItem(title: L10n.AI.askFromTerminal, action: #selector(askPressed(_:)), keyEquivalent: "")
        askItem.target = self
        askItem.representedObject = selectedText
        configureAIActionAvailability(askItem)
        menu.addItem(askItem)

        if hasSelection {
            let explainItem = NSMenuItem(
                title: L10n.AI.explainSelection,
                action: #selector(askPressed(_:)),
                keyEquivalent: ""
            )
            explainItem.target = self
            explainItem.representedObject = selectedText
            configureAIActionAvailability(explainItem)
            menu.addItem(explainItem)
        }

        return menu
    }

    @objc private func pastePressed(_ sender: Any?) {
        paste()
    }

    @objc private func askPressed(_ sender: NSMenuItem) {
        guard canAskAI() else { return }
        askAI(
            TerminalAIContextRequest(
                runtimeID: runtimeID,
                selectedText: sender.representedObject as? String
            )
        )
    }

    private func configureAIActionAvailability(_ item: NSMenuItem) {
        let isEnabled = canAskAI()
        item.isEnabled = isEnabled
        item.toolTip = isEnabled ? nil : disabledAIActionToolTip
    }
}
