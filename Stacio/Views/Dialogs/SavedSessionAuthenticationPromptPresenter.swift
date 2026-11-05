import AppKit

public struct SavedSessionAuthenticationInput: Equatable {
    public let username: String
    public let password: String?

    public init(username: String, password: String?) {
        self.username = username
        self.password = password
    }
}

@MainActor
public protocol SavedSessionAuthenticationPrompting {
    func promptForSavedSessionAuthentication(
        host: String,
        initialUsername: String?,
        parentWindow: NSWindow?
    ) -> SavedSessionAuthenticationInput?
}

@MainActor
public protocol SavedSessionPasswordSavingConfirming {
    func shouldSavePassword(forHost host: String, username: String, parentWindow: NSWindow?) -> Bool
}

@MainActor
public final class AppKitSavedSessionAuthenticationPromptPresenter: SavedSessionAuthenticationPrompting {
    public init() {}

    public func promptForSavedSessionAuthentication(
        host: String,
        initialUsername: String?,
        parentWindow: NSWindow?
    ) -> SavedSessionAuthenticationInput? {
        let controller = SavedSessionAuthenticationPromptViewController(
            host: host,
            initialUsername: initialUsername
        )
        let panel = controller.makePanel(parentWindow: parentWindow)
        controller.onFinish = { response in
            NSApp.stopModal(withCode: response)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(controller.usernameField)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()
        return response == .OK ? controller.result : nil
    }
}

@MainActor
final class SavedSessionAuthenticationPromptViewController: NSViewController {
    let host: String
    let usernameField: NSTextField
    let passwordField = NSSecureTextField(string: "")
    private(set) var result: SavedSessionAuthenticationInput?
    var onFinish: ((NSApplication.ModalResponse) -> Void)?

    init(host: String, initialUsername: String?) {
        self.host = host
        usernameField = NSTextField(string: initialUsername ?? "")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: NSColor.windowBackgroundColor)
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.setAccessibilityIdentifier("Stacio.SessionAuthentication.root")

        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignLeft
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityIdentifier("Stacio.SessionAuthentication.icon")

        let title = NSTextField(labelWithString: L10n.Workbench.sessionAuthenticationTitle)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: L10n.Workbench.sessionAuthenticationMessage)
        message.font = .systemFont(ofSize: 13)
        let hostLabel = NSTextField(labelWithString: host)
        hostLabel.font = .systemFont(ofSize: 13)
        hostLabel.textColor = .secondaryLabelColor

        usernameField.placeholderString = L10n.Workbench.sessionUsernamePlaceholder
        usernameField.isEditable = true
        usernameField.isSelectable = true
        usernameField.isEnabled = true
        usernameField.setAccessibilityIdentifier("Stacio.SessionAuthentication.username")
        passwordField.placeholderString = L10n.Workbench.sessionPasswordPlaceholder
        passwordField.isEditable = true
        passwordField.isSelectable = true
        passwordField.isEnabled = true
        passwordField.setAccessibilityIdentifier("Stacio.SessionAuthentication.password")
        for field in [usernameField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            StacioDesignSystem.styleCompactTextField(field)
        }
        passwordField.target = self
        passwordField.action = #selector(connectPressed(_:))

        let text = NSStackView(views: [title, message, hostLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let fields = NSStackView(views: [usernameField, passwordField])
        fields.orientation = .vertical
        fields.alignment = .width
        fields.spacing = 8
        let buttons = NSStackView(views: [cancelButton(), connectButton()])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        let content = NSStackView(views: [icon, text, fields, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            fields.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor),
            usernameField.heightAnchor.constraint(equalToConstant: 28),
            passwordField.heightAnchor.constraint(equalToConstant: 28),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])
        view = root
    }

    private func cancelButton() -> NSButton {
        let button = NSButton(title: L10n.Common.cancel, target: self, action: #selector(cancelPressed(_:)))
        StacioDesignSystem.styleSheetButton(button)
        button.keyEquivalent = "\u{1b}"
        return button
    }

    private func connectButton() -> NSButton {
        let button = NSButton(title: L10n.Common.connect, target: self, action: #selector(connectPressed(_:)))
        StacioDesignSystem.styleSheetButton(button, isDefault: true)
        button.keyEquivalent = "\r"
        button.hasDestructiveAction = false
        return button
    }

    func makePanel(parentWindow: NSWindow?) -> NSPanel {
        // Keep the credential sheet compact and deterministic. Letting the
        // wrapping message determine fittingSize makes AppKit expand the panel
        // to the full width of an unwrapped localized sentence.
        let size = NSSize(width: 440, height: 280)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.level = .modalPanel
        if let parentWindow {
            panel.setFrameOrigin(NSPoint(x: parentWindow.frame.midX - size.width / 2, y: parentWindow.frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        return panel
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onFinish?(.cancel)
    }

    @objc private func connectPressed(_ sender: Any?) {
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.isEmpty == false else {
            NSSound.beep()
            return
        }
        result = SavedSessionAuthenticationInput(
            username: username,
            password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        )
        onFinish?(.OK)
    }

    #if DEBUG
    func connectPressedForTesting() {
        connectPressed(nil)
    }
    #endif
}

@MainActor
public final class AppKitSavedSessionPasswordSavingConfirmation: SavedSessionPasswordSavingConfirming {
    public init() {}

    public func shouldSavePassword(forHost host: String, username: String, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.Workbench.savePasswordTitle
        alert.informativeText = "\(L10n.Workbench.savePasswordMessage)\n\(username)@\(host)"
        alert.addButton(withTitle: L10n.Workbench.savePassword)
        alert.addButton(withTitle: L10n.Workbench.connectOnce)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
