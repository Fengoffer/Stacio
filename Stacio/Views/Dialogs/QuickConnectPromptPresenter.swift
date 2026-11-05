import AppKit

public protocol QuickConnectPromptPresenting {
    @MainActor
    func promptQuickConnect(parentWindow: NSWindow?) -> QuickConnectRequest?
}

@MainActor
public protocol QuickConnectErrorPresenting {
    func presentQuickConnectError(_ error: Error, parentWindow: NSWindow?)
}

public struct AppKitQuickConnectPromptPresenter: QuickConnectPromptPresenting {
    public init() {}

    public func promptQuickConnect(parentWindow: NSWindow?) -> QuickConnectRequest? {
        let model = QuickConnectPromptViewModel.default
        let controller = QuickConnectPromptWindowController(
            model: model,
            initialRequest: QuickConnectPromptPrefillStore().consume()
        )
        return controller.runModal(parentWindow: parentWindow)
    }
}

public struct AppKitQuickConnectErrorPresenter: QuickConnectErrorPresenting {
    public init() {}

    static func informativeText(for error: Error) -> String {
        let description = RuntimeDiagnosticFormatter
            .userMessage(for: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? L10n.QuickConnect.failedMessage : description
    }

    public func presentQuickConnectError(_ error: Error, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.QuickConnect.failedTitle
        alert.informativeText = Self.informativeText(for: error)
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}

struct QuickConnectPromptViewModel {
    let title: String
    let message: String
    let connectButtonTitle: String
    let cancelButtonTitle: String
    let targetLabel: String
    let targetPlaceholder: String
    let authLabel: String
    let authHint: String
    let privateKeyLabel: String
    let privateKeyPlaceholder: String
    let secretLabel: String
    let saveAsSessionTitle: String
    let saveAsSessionHint: String
    let sessionNameLabel: String
    let sessionNamePlaceholder: String

    static let `default` = QuickConnectPromptViewModel(
        title: "快速连接",
        message: "输入 SSH 目标，选择认证方式后立即连接。",
        connectButtonTitle: L10n.QuickConnect.connect,
        cancelButtonTitle: L10n.Common.cancel,
        targetLabel: "SSH 目标",
        targetPlaceholder: L10n.QuickConnect.placeholder,
        authLabel: "认证",
        authHint: "默认使用 SSH Agent；需要密码或私钥口令时可临时输入，不会调用外部 ssh。",
        privateKeyLabel: "私钥路径",
        privateKeyPlaceholder: "~/.ssh/id_ed25519",
        secretLabel: "密码或口令",
        saveAsSessionTitle: L10n.QuickConnect.saveAsSession,
        saveAsSessionHint: "开启后可命名会话，凭据按当前保存流程处理。",
        sessionNameLabel: "会话名",
        sessionNamePlaceholder: L10n.QuickConnect.sessionNamePlaceholder
    )
}

@MainActor
final class QuickConnectPromptViewController: NSViewController {
    private let model: QuickConnectPromptViewModel
    private let form: QuickConnectPromptForm
    private let connectButton: NSButton
    private let cancelButton: NSButton

    var onConnect: ((QuickConnectRequest) -> Void)?
    var onCancel: (() -> Void)?

    init(model: QuickConnectPromptViewModel, initialRequest: QuickConnectRequest? = nil) {
        self.model = model
        form = QuickConnectPromptForm(model: model)
        connectButton = NSButton(title: model.connectButtonTitle, target: nil, action: nil)
        cancelButton = NSButton(title: model.cancelButtonTitle, target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
        if let initialRequest {
            form.apply(initialRequest)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 412, height: 292))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)
        container.layer?.borderWidth = 0
        container.layer?.cornerRadius = 0
        container.setAccessibilityIdentifier("Stacio.QuickConnect.sheet")

        let titleLabel = NSTextField(labelWithString: model.title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(labelWithString: model.message)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        form.view.translatesAutoresizingMaskIntoConstraints = false

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectButtonPressed(_:))
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(connectButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelButtonPressed(_:))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(cancelButton)

        let footer = NSStackView(views: [NSView(), cancelButton, connectButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(messageLabel)
        container.addSubview(form.view)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),

            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            form.view.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            form.view.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            form.view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            form.view.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.widthAnchor.constraint(equalToConstant: 86),
            connectButton.widthAnchor.constraint(equalToConstant: 86)
        ])

        view = container
    }

    @objc private func connectButtonPressed(_ sender: NSButton) {
        guard let request = form.request() else {
            return
        }
        onConnect?(request)
    }

    @objc private func cancelButtonPressed(_ sender: NSButton) {
        onCancel?()
    }
}

@MainActor
final class QuickConnectPromptWindowController: NSWindowController, NSWindowDelegate {
    private let promptViewController: QuickConnectPromptViewController
    private var result: QuickConnectRequest?

    init(model: QuickConnectPromptViewModel, initialRequest: QuickConnectRequest? = nil) {
        promptViewController = QuickConnectPromptViewController(model: model, initialRequest: initialRequest)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 412, height: 292),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        StacioDesignSystem.applyWindowChrome(window)
        window.contentViewController = promptViewController
        super.init(window: window)
        window.delegate = self

        promptViewController.onConnect = { [weak self] request in
            self?.result = request
            NSApplication.shared.stopModal(withCode: .OK)
        }
        promptViewController.onCancel = {
            NSApplication.shared.stopModal(withCode: .cancel)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func runModal(parentWindow: NSWindow?) -> QuickConnectRequest? {
        guard let window else {
            return nil
        }

        if let parentWindow {
            parentWindow.beginSheet(window)
            let response = NSApplication.shared.runModal(for: window)
            parentWindow.endSheet(window)
            window.orderOut(nil)
            return response == .OK ? result : nil
        }

        window.center()
        let response = NSApplication.shared.runModal(for: window)
        window.close()
        return response == .OK ? result : nil
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.stopModal(withCode: .cancel)
    }
}

@MainActor
final class QuickConnectPromptForm: NSObject {
    let view: NSView
    private let targetField = NSTextField(string: "")
    private let authPopup = NSPopUpButton()
    private let privateKeyField = NSTextField(string: "")
    private let secretField = NSSecureTextField(string: "")
    private let saveCheckbox: NSButton
    private let sessionNameField = NSTextField(string: "")
    private let authHintLabel: NSTextField
    private let saveHintLabel: NSTextField
    private var privateKeyRow: NSGridRow!
    private var secretRow: NSGridRow!
    private var sessionNameRow: NSGridRow!

    init(model: QuickConnectPromptViewModel) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 348, height: 168))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.borderWidth = 0
        container.layer?.cornerRadius = 0

        targetField.placeholderString = model.targetPlaceholder
        targetField.setAccessibilityIdentifier("Stacio.QuickConnect.target")
        targetField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1.0, weight: .medium)
        privateKeyField.placeholderString = model.privateKeyPlaceholder
        privateKeyField.setAccessibilityIdentifier("Stacio.QuickConnect.privateKey")
        secretField.setAccessibilityIdentifier("Stacio.QuickConnect.secret")
        sessionNameField.placeholderString = model.sessionNamePlaceholder
        sessionNameField.setAccessibilityIdentifier("Stacio.QuickConnect.sessionName")
        [
            targetField,
            privateKeyField,
            secretField,
            sessionNameField
        ].forEach(StacioDesignSystem.styleTextField(_:))

        authPopup.addItems(withTitles: [
            L10n.SessionSettings.agent,
            L10n.SessionSettings.passwordAuth,
            L10n.SessionSettings.privateKeyAuth
        ])
        authPopup.setAccessibilityIdentifier("Stacio.QuickConnect.auth")
        StacioDesignSystem.stylePopupButton(authPopup)
        authHintLabel = Self.hintLabel(model.authHint)
        saveHintLabel = Self.hintLabel(model.saveAsSessionHint)
        saveCheckbox = NSButton(checkboxWithTitle: model.saveAsSessionTitle, target: nil, action: nil)
        saveCheckbox.contentTintColor = StacioDesignSystem.theme.primaryTextColor

        let grid = NSGridView(views: [
            Self.gridViews(label: model.targetLabel, field: targetField),
            Self.gridViews(label: model.authLabel, field: authPopup),
            [Self.spacer(), authHintLabel],
            Self.gridViews(label: model.privateKeyLabel, field: privateKeyField),
            Self.gridViews(label: model.secretLabel, field: secretField),
            [Self.spacer(), saveCheckbox],
            [Self.spacer(), saveHintLabel],
            Self.gridViews(label: model.sessionNameLabel, field: sessionNameField)
        ])
        privateKeyRow = grid.row(at: 3)
        secretRow = grid.row(at: 4)
        sessionNameRow = grid.row(at: 7)
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 242
        NSLayoutConstraint.activate([
            targetField.widthAnchor.constraint(equalToConstant: 242),
            authPopup.widthAnchor.constraint(equalToConstant: 242),
            privateKeyField.widthAnchor.constraint(equalToConstant: 242),
            secretField.widthAnchor.constraint(equalToConstant: 242),
            sessionNameField.widthAnchor.constraint(equalToConstant: 242),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 348)
        ])

        view = container
        super.init()
        authPopup.target = self
        authPopup.action = #selector(refreshVisibility)
        saveCheckbox.target = self
        saveCheckbox.action = #selector(refreshVisibility)
        refreshVisibility()
    }

    func request() -> QuickConnectRequest? {
        let target = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return nil
        }
        return QuickConnectRequest(
            target: target,
            authMode: authMode(),
            privateKeyPath: optionalTrimmed(privateKeyField.stringValue),
            temporarySecret: optionalTrimmed(secretField.stringValue),
            saveAsSession: saveCheckbox.state == .on,
            sessionName: optionalTrimmed(sessionNameField.stringValue)
        )
    }

    func apply(_ request: QuickConnectRequest) {
        targetField.stringValue = request.target
        privateKeyField.stringValue = request.privateKeyPath ?? ""
        secretField.stringValue = request.temporarySecret ?? ""
        saveCheckbox.state = request.saveAsSession ? .on : .off
        sessionNameField.stringValue = request.sessionName ?? ""
        switch request.authMode {
        case .agent:
            authPopup.selectItem(at: 0)
        case .password:
            authPopup.selectItem(at: 1)
        case .privateKey:
            authPopup.selectItem(at: 2)
        }
        refreshVisibility()
    }

    @objc
    private func refreshVisibility() {
        let mode = authMode()
        privateKeyRow.isHidden = mode != .privateKey
        secretRow.isHidden = mode == .agent
        sessionNameRow.isHidden = saveCheckbox.state != .on
    }

    private func authMode() -> QuickConnectAuthMode {
        switch authPopup.indexOfSelectedItem {
        case 1:
            return .password
        case 2:
            return .privateKey
        default:
            return .agent
        }
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.font = NSFont.systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 242).isActive = true
        return label
    }

    private static func gridViews(label: String, field: NSView) -> [NSView] {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 84).isActive = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return [labelView, field]
    }

    private static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return view
    }
}
