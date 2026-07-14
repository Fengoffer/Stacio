import AppKit

public struct StacioMenuBuilder {
    private weak var target: AppDelegate?

    public init(target: AppDelegate) {
        self.target = target
    }

    public func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(terminalMenuItem())
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = StacioAppMetadata.applicationName
        let submenu = NSMenu(title: StacioAppMetadata.applicationName)
        submenu.addItem(menuItem(
            title: L10n.Menu.about,
            action: #selector(AppDelegate.showAboutPanel(_:)),
            key: ""
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            title: L10n.Menu.settings,
            action: #selector(AppDelegate.showSettingsWindow(_:)),
            key: ","
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            title: L10n.Menu.quit,
            action: #selector(NSApplication.terminate(_:)),
            key: "q",
            target: NSApp
        ))
        item.submenu = submenu
        return item
    }

    private func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = L10n.Menu.file
        let submenu = NSMenu(title: L10n.Menu.file)
        submenu.addItem(menuItem(
            title: L10n.Menu.newLocalTerminal,
            action: #selector(AppDelegate.openLocalShellFromMenu(_:)),
            key: "n"
        ))
        submenu.addItem(menuItem(
            title: L10n.Menu.closeCurrentTerminal,
            action: #selector(AppDelegate.closeCurrentTerminalFromMenu(_:)),
            key: "w"
        ))
        item.submenu = submenu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = L10n.Menu.edit
        let submenu = NSMenu(title: L10n.Menu.edit)
        submenu.addItem(menuItem(
            title: L10n.Menu.cut,
            action: #selector(NSText.cut(_:)),
            key: "x",
            usesResponderChain: true
        ))
        submenu.addItem(menuItem(
            title: L10n.Menu.copy,
            action: #selector(NSText.copy(_:)),
            key: "c",
            usesResponderChain: true
        ))
        submenu.addItem(menuItem(
            title: L10n.Menu.paste,
            action: #selector(NSText.paste(_:)),
            key: "v",
            usesResponderChain: true
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            title: L10n.Menu.selectAll,
            action: #selector(NSText.selectAll(_:)),
            key: "a",
            usesResponderChain: true
        ))
        item.submenu = submenu
        return item
    }

    private func terminalMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = L10n.Menu.terminal
        let submenu = NSMenu(title: L10n.Menu.terminal)
        submenu.addItem(menuItem(
            title: L10n.Menu.find,
            action: #selector(AppDelegate.findInTerminalMenu(_:)),
            key: "f"
        ))
        submenu.addItem(menuItem(
            title: L10n.Menu.splitTerminal,
            action: #selector(AppDelegate.splitTerminalFromMenu(_:)),
            key: "d"
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            title: L10n.Menu.toggleDeviceDashboard,
            action: #selector(AppDelegate.toggleDeviceDashboardFromMenu(_:)),
            key: ""
        ))
        item.submenu = submenu
        return item
    }

    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = L10n.Menu.help
        let submenu = NSMenu(title: L10n.Menu.help)
        submenu.addItem(menuItem(
            title: L10n.Menu.feedback,
            action: #selector(AppDelegate.showFeedbackWindow(_:)),
            key: ""
        ))
        submenu.addItem(menuItem(
            title: L10n.Menu.checkForUpdates,
            action: #selector(AppDelegate.showUpdateCheckWindow(_:)),
            key: ""
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            title: L10n.Menu.license,
            action: #selector(AppDelegate.showLicenseWindow(_:)),
            key: ""
        ))
        item.submenu = submenu
        return item
    }

    private func menuItem(
        title: String,
        action: Selector,
        key: String,
        target explicitTarget: AnyObject? = nil,
        usesResponderChain: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = usesResponderChain ? nil : (explicitTarget ?? target)
        return item
    }
}
