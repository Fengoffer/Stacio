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
    private let copySelection: () -> Void
    private let selectAll: () -> Void
    private let clear: () -> Void
    private let askAI: (TerminalAIContextRequest) -> Void
    private let canAskAI: () -> Bool
    private let disabledAIActionToolTip: String?
    private let favoriteCommands: () -> [TerminalFavoriteCommand]
    private let favoriteOperatingSystem: () -> TerminalCommandOperatingSystem
    private let favoriteOperatingSystemIdentity: () -> String
    private let insertFavoriteCommand: (String) -> Void

    public init(
        runtimeID: String,
        paste: @escaping () -> Void,
        copySelection: @escaping () -> Void = {},
        selectAll: @escaping () -> Void = {},
        clear: @escaping () -> Void = {},
        askAI: @escaping (TerminalAIContextRequest) -> Void,
        canAskAI: @escaping () -> Bool = { true },
        disabledAIActionToolTip: String? = nil,
        favoriteCommands: @escaping () -> [TerminalFavoriteCommand] = { TerminalFavoriteCommandStore.shared.commands },
        favoriteOperatingSystem: @escaping () -> TerminalCommandOperatingSystem = { .unknown },
        favoriteOperatingSystemIdentity: @escaping () -> String = { "" },
        insertFavoriteCommand: @escaping (String) -> Void = { _ in }
    ) {
        self.runtimeID = runtimeID
        self.paste = paste
        self.copySelection = copySelection
        self.selectAll = selectAll
        self.clear = clear
        self.askAI = askAI
        self.canAskAI = canAskAI
        self.disabledAIActionToolTip = disabledAIActionToolTip
        self.favoriteCommands = favoriteCommands
        self.favoriteOperatingSystem = favoriteOperatingSystem
        self.favoriteOperatingSystemIdentity = favoriteOperatingSystemIdentity
        self.insertFavoriteCommand = insertFavoriteCommand
    }

    public func makeMenu(selectedText: String?) -> NSMenu {
        let trimmedSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelection = trimmedSelection?.isEmpty == false
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(title: L10n.Menu.copy, action: #selector(copyPressed(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: L10n.Menu.paste, action: #selector(pastePressed(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(title: L10n.Menu.selectAll, action: #selector(selectAllPressed(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        let clearItem = NSMenuItem(title: "清屏", action: #selector(clearPressed(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())

        let askItem = NSMenuItem(title: L10n.AI.askFromTerminal, action: #selector(askPressed(_:)), keyEquivalent: "")
        askItem.target = self
        askItem.representedObject = selectedText
        configureAIActionAvailability(askItem)
        menu.addItem(askItem)

        let explainItem = NSMenuItem(
            title: L10n.AI.explainSelection,
            action: #selector(askPressed(_:)),
            keyEquivalent: ""
        )
        explainItem.target = self
        explainItem.representedObject = selectedText
        let canExplainSelection = canAskAI()
        explainItem.isEnabled = hasSelection && canExplainSelection
        explainItem.toolTip = canExplainSelection
            ? (hasSelection ? nil : "请先选择终端文本")
            : disabledAIActionToolTip
        menu.addItem(explainItem)

        let availableFavorites = favoriteCommands().filter {
            $0.isSafeForInsertion && favoriteOperatingSystem().accepts(
                $0,
                operatingSystemIdentity: favoriteOperatingSystemIdentity()
            )
        }
        if availableFavorites.isEmpty == false {
            menu.addItem(.separator())
            let favoritesItem = NSMenuItem(title: "常用命令", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "常用命令")
            submenu.autoenablesItems = false
            for favorite in availableFavorites {
                let item = NSMenuItem(title: "\(favorite.name) · \(favorite.command)", action: #selector(favoritePressed(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = favorite.command
                item.toolTip = favorite.displayDetail
                submenu.addItem(item)
            }
            favoritesItem.submenu = submenu
            menu.addItem(favoritesItem)
        }

        return menu
    }

    @objc private func pastePressed(_ sender: Any?) {
        paste()
    }

    @objc private func copyPressed(_ sender: Any?) {
        copySelection()
    }

    @objc private func selectAllPressed(_ sender: Any?) {
        selectAll()
    }

    @objc private func clearPressed(_ sender: Any?) {
        clear()
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

    @objc private func favoritePressed(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        insertFavoriteCommand(command)
    }
}
