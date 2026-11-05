import AppKit

public enum SavedSessionCredentialKind: Equatable {
    case password
    case privateKeyPassphrase

    var storageKind: String {
        switch self {
        case .password:
            return "password"
        case .privateKeyPassphrase:
            return "private_key_passphrase"
        }
    }

    var promptPlaceholder: String {
        switch self {
        case .password:
            return L10n.Workbench.savedCredentialPasswordPlaceholder
        case .privateKeyPassphrase:
            return L10n.Workbench.savedCredentialPassphrasePlaceholder
        }
    }
}

public struct SavedSessionCredentialPromptRequest: Equatable {
    public let sessionID: String
    public let sessionName: String
    public let protocolName: String
    public let host: String
    public let account: String
    public let kind: SavedSessionCredentialKind
    public let label: String

    public init(
        sessionID: String,
        sessionName: String,
        protocolName: String,
        host: String,
        account: String,
        kind: SavedSessionCredentialKind,
        label: String
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.protocolName = protocolName
        self.host = host
        self.account = account
        self.kind = kind
        self.label = label
    }
}

@MainActor
public protocol SavedSessionCredentialPrompting {
    func promptForSavedSessionCredential(
        _ request: SavedSessionCredentialPromptRequest,
        parentWindow: NSWindow?
    ) -> String?
}

@MainActor
public final class AppKitSavedSessionCredentialPromptPresenter: SavedSessionCredentialPrompting {
    public init() {}

    public func promptForSavedSessionCredential(
        _ request: SavedSessionCredentialPromptRequest,
        parentWindow: NSWindow?
    ) -> String? {
        let controller = SavedSessionCredentialPromptViewController(request: request)
        let panel = makePromptPanel(for: controller, parentWindow: parentWindow)
        controller.onFinish = { response in
            NSApp.stopModal(withCode: response)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(controller.secretField)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()

        guard response == .OK else {
            return nil
        }
        return controller.result
    }

    func makePromptPanel(
        for controller: SavedSessionCredentialPromptViewController,
        parentWindow: NSWindow?
    ) -> NSPanel {
        let size = controller.view.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.level = .modalPanel
        panel.collectionBehavior = [.transient]
        if let parentWindow {
            let parentFrame = parentWindow.frame
            panel.setFrameOrigin(
                NSPoint(
                    x: parentFrame.midX - size.width / 2,
                    y: parentFrame.midY - size.height / 2
                )
            )
        } else {
            panel.center()
        }
        return panel
    }
}

@MainActor
final class SavedSessionCredentialPromptViewController: NSViewController {
    let request: SavedSessionCredentialPromptRequest
    private(set) var result: String?
    var onFinish: ((NSApplication.ModalResponse) -> Void)?
    let secretField = NSSecureTextField(string: "")

    init(request: SavedSessionCredentialPromptRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 440, height: 224))
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: NSColor.windowBackgroundColor)
        root.layer?.cornerRadius = 18
        root.layer?.cornerCurve = .continuous
        root.setAccessibilityIdentifier("Stacio.CredentialPrompt.root")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(makeMessageLabel())
        stack.addArrangedSubview(makeSecretField())
        stack.addArrangedSubview(makeButtonRow())

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 440),
            root.heightAnchor.constraint(equalToConstant: 224),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        view = root
    }

    private func makeHeader() -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        let iconBadge = NSView()
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 10
        iconBadge.layer?.cornerCurve = .continuous
        iconBadge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityIdentifier("Stacio.CredentialPrompt.icon")
        iconBadge.addSubview(icon)

        let title = NSTextField(labelWithString: L10n.Workbench.savedCredentialMissingTitle)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.setAccessibilityIdentifier("Stacio.CredentialPrompt.title")

        let account = NSTextField(labelWithString: "\(request.account) · \(request.protocolName)")
        account.font = .systemFont(ofSize: 12)
        account.textColor = StacioDesignSystem.theme.secondaryTextColor
        account.lineBreakMode = .byTruncatingMiddle
        account.maximumNumberOfLines = 1
        account.setAccessibilityIdentifier("Stacio.CredentialPrompt.account")

        let textStack = NSStackView(views: [title, account])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        header.addArrangedSubview(iconBadge)
        header.addArrangedSubview(textStack)

        NSLayoutConstraint.activate([
            iconBadge.widthAnchor.constraint(equalToConstant: 36),
            iconBadge.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            header.widthAnchor.constraint(equalToConstant: 384),
            textStack.widthAnchor.constraint(equalToConstant: 336)
        ])
        return header
    }

    private func makeMessageLabel() -> NSTextField {
        let message = NSTextField(wrappingLabelWithString: informativeText)
        message.font = .systemFont(ofSize: 13)
        message.textColor = StacioDesignSystem.theme.secondaryTextColor
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.setAccessibilityIdentifier("Stacio.CredentialPrompt.message")
        message.widthAnchor.constraint(equalToConstant: 384).isActive = true
        return message
    }

    private func makeSecretField() -> NSSecureTextField {
        secretField.placeholderString = request.kind.promptPlaceholder
        secretField.target = self
        secretField.action = #selector(submitCredential(_:))
        secretField.setAccessibilityIdentifier("Stacio.CredentialPrompt.secret")
        StacioDesignSystem.styleTextField(secretField)
        NSLayoutConstraint.activate([
            secretField.widthAnchor.constraint(equalToConstant: 384),
            secretField.heightAnchor.constraint(equalToConstant: 34)
        ])
        return secretField
    }

    private func makeButtonRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(
            title: L10n.Common.cancel,
            target: self,
            action: #selector(cancelCredentialPrompt(_:))
        )
        cancelButton.setAccessibilityIdentifier("Stacio.CredentialPrompt.cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        StacioDesignSystem.styleSheetButton(cancelButton)

        let primaryButton = NSButton(
            title: L10n.Workbench.savedCredentialSaveAndRetry,
            target: self,
            action: #selector(submitCredential(_:))
        )
        primaryButton.setAccessibilityIdentifier("Stacio.CredentialPrompt.primary")
        StacioDesignSystem.styleSheetButton(primaryButton, isDefault: true)

        let buttonStack = NSStackView(views: [cancelButton, primaryButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 384),
            row.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.widthAnchor.constraint(equalToConstant: 82),
            primaryButton.widthAnchor.constraint(equalToConstant: 132),
            buttonStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            buttonStack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private var informativeText: String {
        switch request.kind {
        case .password:
            return L10n.Workbench.savedPasswordCredentialMissingMessage(account: request.account)
        case .privateKeyPassphrase:
            return L10n.Workbench.savedPassphraseCredentialMissingMessage(account: request.account)
        }
    }

    @objc private func submitCredential(_ sender: Any?) {
        let secret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            NSSound.beep()
            return
        }
        result = secretField.stringValue
        onFinish?(.OK)
    }

    @objc private func cancelCredentialPrompt(_ sender: Any?) {
        result = nil
        onFinish?(.cancel)
    }
}
