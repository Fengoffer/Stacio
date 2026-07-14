import AppKit
import StacioCoreBindings

public protocol TunnelProfileStoring {
    func listProfiles() throws -> [TunnelProfile]
    func saveProfile(_ profile: TunnelProfile) throws
    func listProfileRecords() throws -> [TunnelProfileRecord]
    func saveProfileRecord(_ record: TunnelProfileRecord) throws
    func deleteProfile(id: String) throws
}

public extension TunnelProfileStoring {
    func listProfiles() throws -> [TunnelProfile] {
        try listProfileRecords().map(\.profile)
    }

    func saveProfile(_ profile: TunnelProfile) throws {
        try saveProfileRecord(TunnelProfileRecord(profile: profile, sessionId: nil, endpointSessionId: nil))
    }

    func listProfileRecords() throws -> [TunnelProfileRecord] {
        try listProfiles().map { profile in
            TunnelProfileRecord(profile: profile, sessionId: nil, endpointSessionId: nil)
        }
    }

    func saveProfileRecord(_ record: TunnelProfileRecord) throws {
        try saveProfile(record.profile)
    }
}

public protocol TunnelEndpointSessionStoring {
    func listFolders() throws -> [SessionFolder]
    func listSessions(folderID: String?) throws -> [SessionRecord]
}

extension CoreBridgeSessionSidebarStore: TunnelEndpointSessionStoring {}

public enum TunnelEndpointSessionResolutionError: Error, Equatable {
    case missingSession
    case unsupportedProtocol(String)
    case missingCredential
    case invalidPort(UInt32)
}

public protocol TunnelEndpointSessionResolving {
    func resolveEndpointSession(id: String) throws -> SessionRecord
}

public final class StoredTunnelEndpointSessionResolver: TunnelEndpointSessionResolving {
    private let store: TunnelEndpointSessionStoring

    public init(store: TunnelEndpointSessionStoring) {
        self.store = store
    }

    public func resolveEndpointSession(id: String) throws -> SessionRecord {
        let rootSessions = try store.listSessions(folderID: nil)
        if let session = rootSessions.first(where: { $0.id == id }) {
            return session
        }

        for folder in try store.listFolders() {
            if let session = try store.listSessions(folderID: folder.id).first(where: { $0.id == id }) {
                return session
            }
        }

        throw TunnelEndpointSessionResolutionError.missingSession
    }
}

public struct TunnelEndpointSession: Equatable {
    public let id: String
    public let title: String
    public let protocolName: String
    public let host: String
    public let port: UInt16
    public let username: String?

    public init?(session: SessionRecord) {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedProtocol == "ssh" || normalizedProtocol == "scp",
              session.port > 0,
              session.port <= UInt32(UInt16.max)
        else {
            return nil
        }

        let host = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return nil
        }

        let username = session.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = Self.endpointText(host: host, port: UInt16(session.port), username: username)
        let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = session.id
        self.title = name.isEmpty ? endpoint : "\(name) - \(endpoint)"
        self.protocolName = normalizedProtocol
        self.host = host
        self.port = UInt16(session.port)
        self.username = username?.isEmpty == true ? nil : username
    }

    public static func selectable(from sessions: [SessionRecord]) -> [TunnelEndpointSession] {
        sessions.compactMap(TunnelEndpointSession.init(session:))
    }

    public func applyEndpoint(to profile: TunnelProfile) -> TunnelProfile {
        TunnelProfile(
            id: profile.id,
            kind: profile.kind,
            localHost: profile.localHost,
            localPort: profile.localPort,
            remoteHost: host,
            remotePort: port
        )
    }

    private static func endpointText(host: String, port: UInt16, username: String?) -> String {
        if let username, !username.isEmpty {
            return "\(username)@\(host):\(port)"
        }
        return "\(host):\(port)"
    }
}

public final class CoreBridgeTunnelProfileStore: TunnelProfileStoring {
    private let databasePath: String
    private let sessionID: String?

    public init(databasePath: String, sessionID: String? = nil) {
        self.databasePath = databasePath
        self.sessionID = sessionID
    }

    public func listProfileRecords() throws -> [TunnelProfileRecord] {
        try CoreBridge.listTunnelProfileRecords(databasePath: databasePath, sessionID: sessionID)
    }

    public func listProfiles() throws -> [TunnelProfile] {
        try CoreBridge.listTunnelProfiles(databasePath: databasePath, sessionID: sessionID)
    }

    public func saveProfileRecord(_ record: TunnelProfileRecord) throws {
        let storedRecord = TunnelProfileRecord(
            profile: record.profile,
            sessionId: sessionID,
            endpointSessionId: record.endpointSessionId
        )
        try CoreBridge.saveTunnelProfileRecord(
            databasePath: databasePath,
            record: storedRecord
        )
    }

    public func saveProfile(_ profile: TunnelProfile) throws {
        try CoreBridge.saveTunnelProfile(
            databasePath: databasePath,
            sessionID: sessionID,
            profile: profile
        )
    }

    public func deleteProfile(id: String) throws {
        try CoreBridge.deleteTunnelProfile(databasePath: databasePath, profileID: id)
    }
}

public struct TunnelProfileEditResult: Equatable {
    public let profile: TunnelProfile
    public let endpointSessionID: String?

    public init(profile: TunnelProfile, endpointSessionID: String?) {
        self.profile = profile
        self.endpointSessionID = endpointSessionID
    }
}

@MainActor
public protocol TunnelProfileEditing {
    func makeTunnelProfile(
        existingRecord: TunnelProfileRecord?,
        existingProfiles: [TunnelProfile],
        endpointSessions: [TunnelEndpointSession],
        parentWindow: NSWindow?
    ) -> TunnelProfileEditResult?
}

@MainActor
public final class AppKitTunnelProfileEditor: TunnelProfileEditing {
    public init() {}

    public func makeTunnelProfile(
        existingRecord: TunnelProfileRecord?,
        existingProfiles: [TunnelProfile],
        endpointSessions: [TunnelEndpointSession],
        parentWindow: NSWindow?
    ) -> TunnelProfileEditResult? {
        let controller = TunnelProfileEditorWindowController(
            existingRecord: existingRecord,
            existingProfiles: existingProfiles,
            endpointSessions: endpointSessions
        )
        return controller.runModal(parentWindow: parentWindow)
    }
}

@MainActor
public protocol TunnelProfileDeletionConfirming {
    func shouldDeleteTunnelProfiles(_ profiles: [TunnelProfile], parentWindow: NSWindow?) -> Bool
}

@MainActor
public final class AppKitTunnelProfileDeletionConfirmation: TunnelProfileDeletionConfirming {
    public init() {}

    public func shouldDeleteTunnelProfiles(_ profiles: [TunnelProfile], parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = profiles.count == 1 ? L10n.Tunnels.deleteOneTitle : L10n.Tunnels.deleteManyTitle
        alert.informativeText = profiles.count == 1
            ? L10n.Tunnels.deleteOneMessage
            : L10n.Tunnels.deleteManyMessage(profiles.count)
        alert.addButton(withTitle: L10n.Common.delete)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum TunnelQuickAddProfileBuilder {
    static func makeResult(
        kind: TunnelKind,
        localPortText: String,
        targetText: String,
        remarkText: String,
        existingProfiles: [TunnelProfile]
    ) -> TunnelProfileEditResult? {
        let localPortText = localPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let localPort = UInt16(localPortText) else {
            return nil
        }

        let endpoint = kind == .dynamic ? nil : parseEndpoint(targetText)
        if kind != .dynamic && endpoint == nil {
            return nil
        }

        let id = uniqueID(
            remarkText: remarkText,
            kind: kind,
            localPort: localPort,
            existingProfiles: existingProfiles
        )
        let profile: TunnelProfile
        switch kind {
        case .local:
            guard let endpoint else { return nil }
            profile = TunnelProfile(
                id: id,
                kind: kind,
                localHost: "127.0.0.1",
                localPort: localPort,
                remoteHost: endpoint.host,
                remotePort: endpoint.port
            )
        case .remote:
            guard let endpoint else { return nil }
            profile = TunnelProfile(
                id: id,
                kind: kind,
                localHost: "127.0.0.1",
                localPort: localPort,
                remoteHost: endpoint.host,
                remotePort: endpoint.port
            )
        case .dynamic:
            profile = TunnelProfile(
                id: id,
                kind: kind,
                localHost: "127.0.0.1",
                localPort: localPort,
                remoteHost: dynamicPlaceholderRemoteHost,
                remotePort: localPort
            )
        }
        return TunnelProfileEditResult(profile: profile, endpointSessionID: nil)
    }

    private static func parseEndpoint(_ text: String) -> (host: String, port: UInt16)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if text.hasPrefix("["),
           let closingBracket = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<closingBracket])
            let suffix = text[text.index(after: closingBracket)...]
            guard suffix.hasPrefix(":"),
                  let port = UInt16(suffix.dropFirst()),
                  !host.isEmpty
            else {
                return nil
            }
            return (host, port)
        }

        guard let separator = text.lastIndex(of: ":") else {
            return nil
        }
        let host = String(text[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(portText) else {
            return nil
        }
        return (host, port)
    }

    private static func uniqueID(
        remarkText: String,
        kind: TunnelKind,
        localPort: UInt16,
        existingProfiles: [TunnelProfile]
    ) -> String {
        let preferredSlug = slug(remarkText)
        let fallbackSlug = "\(kindSlug(kind))_\(localPort)"
        let base = preferredSlug.isEmpty ? fallbackSlug : preferredSlug
        let existingIDs = Set(existingProfiles.map(\.id))
        var candidate = "tun_\(base)"
        var suffix = 2
        while existingIDs.contains(candidate) {
            candidate = "tun_\(base)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func slug(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 97...122:
                return Character(scalar)
            default:
                return "_"
            }
        }
        return String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func kindSlug(_ kind: TunnelKind) -> String {
        switch kind {
        case .local: "local"
        case .remote: "remote"
        case .dynamic: "dynamic"
        }
    }

    static let dynamicPlaceholderRemoteHost = "socks"
}

@MainActor
final class TunnelQuickAddViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 320
        static let height: CGFloat = 232
        static let inset: CGFloat = 18
    }

    private let existingProfiles: [TunnelProfile]
    private let kindPopup = NSPopUpButton()
    private let localPortField = NSTextField(string: "")
    private let targetField = NSTextField(string: "")
    private let remarkField = NSTextField(string: "")
    private let validationLabel = NSTextField(labelWithString: "请填写有效的端口和目标。")
    private let createButton = NSButton(title: "创建并启动", target: nil, action: nil)

    var onCreate: ((TunnelProfileEditResult) -> Void)?

    init(existingProfiles: [TunnelProfile]) {
        self.existingProfiles = existingProfiles
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: StacioDesignSystem.theme.windowBackgroundColor)
        container.setAccessibilityIdentifier("Stacio.Tunnels.quickAddPopover")

        let titleLabel = NSTextField(labelWithString: "快速新建隧道")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configureControls()
        let grid = NSGridView(views: [
            Self.gridViews(label: "类型", control: kindPopup),
            Self.gridViews(label: "本地端口", control: localPortField),
            Self.gridViews(label: "目标", control: targetField),
            Self.gridViews(label: "备注", control: remarkField)
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).width = 68
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.textColor = StacioDesignSystem.theme.dangerColor
        validationLabel.isHidden = true
        validationLabel.translatesAutoresizingMaskIntoConstraints = false

        createButton.target = self
        createButton.action = #selector(createPressed(_:))
        createButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(createButton, isDefault: true)

        container.addSubview(titleLabel)
        container.addSubview(grid)
        container.addSubview(validationLabel)
        container.addSubview(createButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Layout.width),
            container.heightAnchor.constraint(equalToConstant: Layout.height),

            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.inset),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.inset),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),

            grid.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),

            validationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 78),
            validationLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            validationLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),

            createButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            createButton.topAnchor.constraint(greaterThanOrEqualTo: validationLabel.bottomAnchor, constant: 10),
            createButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            createButton.widthAnchor.constraint(equalToConstant: 104),
            createButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        view = container
        updateTargetPlaceholder()
    }

    private func configureControls() {
        ["本地", "远端", "动态"].forEach(kindPopup.addItem(withTitle:))
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        kindPopup.setAccessibilityIdentifier("Stacio.Tunnels.quickAdd.kind")
        StacioDesignSystem.stylePopupButton(kindPopup)

        localPortField.placeholderString = "18080"
        targetField.placeholderString = "db.internal:5432"
        remarkField.placeholderString = "api / db / socks"
        [localPortField, targetField, remarkField].forEach { field in
            field.cell?.usesSingleLineMode = true
            field.isEditable = true
            field.isSelectable = true
            StacioDesignSystem.styleCompactTextField(field)
        }
        localPortField.setAccessibilityIdentifier("Stacio.Tunnels.quickAdd.localPort")
        targetField.setAccessibilityIdentifier("Stacio.Tunnels.quickAdd.target")
        remarkField.setAccessibilityIdentifier("Stacio.Tunnels.quickAdd.remark")
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        updateTargetPlaceholder()
    }

    @objc private func createPressed(_ sender: NSButton) {
        guard let result = TunnelQuickAddProfileBuilder.makeResult(
            kind: selectedKind,
            localPortText: localPortField.stringValue,
            targetText: targetField.stringValue,
            remarkText: remarkField.stringValue,
            existingProfiles: existingProfiles
        ) else {
            validationLabel.isHidden = false
            return
        }
        validationLabel.isHidden = true
        onCreate?(result)
    }

    private var selectedKind: TunnelKind {
        switch kindPopup.indexOfSelectedItem {
        case 1: .remote
        case 2: .dynamic
        default: .local
        }
    }

    private func updateTargetPlaceholder() {
        switch selectedKind {
        case .local:
            targetField.isEnabled = true
            targetField.placeholderString = "db.internal:5432"
        case .remote:
            targetField.isEnabled = true
            targetField.placeholderString = "0.0.0.0:19000"
        case .dynamic:
            targetField.isEnabled = false
            targetField.stringValue = ""
            targetField.placeholderString = "SOCKS5 动态转发不需要目标"
        }
    }

    private static func gridViews(label: String, control: NSView) -> [NSView] {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.font = .systemFont(ofSize: NSFont.systemFontSize)
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return [labelView, control]
    }
}

@MainActor
final class TunnelProfileEditorViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 560
        static let height: CGFloat = 430
        static let horizontalInset: CGFloat = 24
    }

    private let existingRecord: TunnelProfileRecord?
    private let existingProfiles: [TunnelProfile]
    private let form: TunnelProfileForm
    private let saveButton = NSButton(title: L10n.Common.save, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.Common.cancel, target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "请填写完整且唯一的隧道配置。")

    var onSave: ((TunnelProfileEditResult) -> Void)?
    var onCancel: (() -> Void)?

    init(
        existingRecord: TunnelProfileRecord?,
        existingProfiles: [TunnelProfile],
        endpointSessions: [TunnelEndpointSession]
    ) {
        self.existingRecord = existingRecord
        self.existingProfiles = existingProfiles
        form = TunnelProfileForm(existingRecord: existingRecord, endpointSessions: endpointSessions)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)
        container.setAccessibilityIdentifier("Stacio.Tunnels.editorSheet")

        let titleLabel = NSTextField(labelWithString: existingRecord == nil ? L10n.Tunnels.addTitle : L10n.Tunnels.editTitle)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(labelWithString: "选择 SSH/SCP 会话端点后，Stacio 会用内置 SSH 引擎创建隧道。")
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        form.view.translatesAutoresizingMaskIntoConstraints = false

        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.textColor = StacioDesignSystem.theme.dangerColor
        validationLabel.isHidden = true
        validationLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelButtonPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setAccessibilityIdentifier("Stacio.Tunnels.cancel")
        StacioDesignSystem.styleSheetButton(cancelButton)

        saveButton.target = self
        saveButton.action = #selector(saveButtonPressed(_:))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setAccessibilityIdentifier("Stacio.Tunnels.save")
        StacioDesignSystem.styleSheetButton(saveButton, isDefault: true)

        let footer = NSStackView(views: [NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(messageLabel)
        container.addSubview(form.view)
        container.addSubview(validationLabel)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Layout.width),
            container.heightAnchor.constraint(equalToConstant: Layout.height),

            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Layout.horizontalInset),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Layout.horizontalInset),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),

            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            form.view.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            form.view.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            form.view.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),

            validationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 110),
            validationLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            validationLabel.topAnchor.constraint(equalTo: form.view.bottomAnchor, constant: 8),

            footer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            footer.topAnchor.constraint(greaterThanOrEqualTo: validationLabel.bottomAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            footer.heightAnchor.constraint(equalToConstant: 32),

            cancelButton.widthAnchor.constraint(equalToConstant: 86),
            saveButton.widthAnchor.constraint(equalToConstant: 86)
        ])

        view = container
    }

    var initialFirstResponder: NSView {
        form.initialFirstResponder
    }

    @objc private func saveButtonPressed(_ sender: NSButton) {
        guard let result = form.profile(existingRecord: existingRecord, existingProfiles: existingProfiles) else {
            validationLabel.isHidden = false
            return
        }
        onSave?(result)
    }

    @objc private func cancelButtonPressed(_ sender: NSButton) {
        onCancel?()
    }
}

@MainActor
private final class TunnelProfileEditorWindowController: NSWindowController, NSWindowDelegate {
    private let editorViewController: TunnelProfileEditorViewController
    private var result: TunnelProfileEditResult?

    init(
        existingRecord: TunnelProfileRecord?,
        existingProfiles: [TunnelProfile],
        endpointSessions: [TunnelEndpointSession]
    ) {
        editorViewController = TunnelProfileEditorViewController(
            existingRecord: existingRecord,
            existingProfiles: existingProfiles,
            endpointSessions: endpointSessions
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existingRecord == nil ? L10n.Tunnels.addTitle : L10n.Tunnels.editTitle
        window.minSize = NSSize(width: 560, height: 430)
        StacioDesignSystem.applyWindowChrome(window)
        window.contentViewController = editorViewController
        super.init(window: window)
        window.delegate = self

        editorViewController.onSave = { [weak self] result in
            self?.result = result
            NSApplication.shared.stopModal(withCode: .OK)
        }
        editorViewController.onCancel = {
            NSApplication.shared.stopModal(withCode: .cancel)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func runModal(parentWindow: NSWindow?) -> TunnelProfileEditResult? {
        guard let window else {
            return nil
        }

        _ = editorViewController.view
        window.initialFirstResponder = editorViewController.initialFirstResponder
        window.makeFirstResponder(editorViewController.initialFirstResponder)

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
private final class TunnelProfileForm: NSObject {
    let view: NSView

    private let idField = NSTextField(string: "")
    private let kindControl = NSSegmentedControl(
        labels: ["本地", "远端", "动态"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let localHostField = NSTextField(string: "")
    private let localPortField = NSTextField(string: "")
    private let remoteHostField = NSTextField(string: "")
    private let remotePortField = NSTextField(string: "")
    private let bindWarningLabel = NSTextField(labelWithString: "监听地址不是 127.0.0.1 时，SOCKS5 代理可能暴露给局域网，请确认只在可信网络中使用。")
    private let endpointPopup = NSPopUpButton()
    private let endpointSessions: [TunnelEndpointSession]
    private weak var formGrid: NSGridView?

    init(existingRecord: TunnelProfileRecord?, endpointSessions: [TunnelEndpointSession]) {
        self.endpointSessions = endpointSessions
        let profile = existingRecord?.profile ?? TunnelProfile(
            id: "tun_\(UUID().uuidString.lowercased())",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )

        idField.stringValue = profile.id
        kindControl.selectedSegment = Self.segment(for: profile.kind)
        localHostField.stringValue = profile.localHost
        localPortField.stringValue = String(profile.localPort)
        remoteHostField.stringValue = profile.remoteHost
        remotePortField.stringValue = String(profile.remotePort)

        idField.placeholderString = "tun_prod_api"
        localHostField.placeholderString = "127.0.0.1"
        localPortField.placeholderString = "18080"
        remoteHostField.placeholderString = "db.internal"
        remotePortField.placeholderString = "5432"

        view = Self.makeFormView(
            endpointPopup: endpointPopup,
            idField: idField,
            kindControl: kindControl,
            localHostField: localHostField,
            localPortField: localPortField,
            remoteHostField: remoteHostField,
            remotePortField: remotePortField,
            bindWarningLabel: bindWarningLabel
        )
        super.init()
        kindControl.target = self
        kindControl.action = #selector(kindControlChanged(_:))
        localHostField.target = self
        localHostField.action = #selector(localHostFieldChanged(_:))
        formGrid = view.subviews.compactMap { $0 as? NSGridView }.first
        configureEndpointPopup(existingRecord: existingRecord)
        updateKindDependentFields()
    }

    var initialFirstResponder: NSView {
        localPortField
    }

    func profile(existingRecord: TunnelProfileRecord?, existingProfiles: [TunnelProfile]) -> TunnelProfileEditResult? {
        let id = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind(for: kindControl.selectedSegment)
        let localHost = localHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHost = kind == .dynamic
            ? Self.dynamicPlaceholderRemoteHost
            : remoteHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPortText = localPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePortText = kind == .dynamic ? localPortText : remotePortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicatesExistingProfile = existingProfiles.contains { profile in
            profile.id == id && profile.id != existingRecord?.profile.id
        }

        guard !id.isEmpty,
              !localHost.isEmpty,
              !remoteHost.isEmpty,
              !duplicatesExistingProfile,
              let localPort = UInt16(localPortText),
              let remotePort = UInt16(remotePortText)
        else {
            return nil
        }

        let profile = TunnelProfile(
            id: id,
            kind: kind,
            localHost: localHost,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
        return TunnelProfileEditResult(
            profile: profile,
            endpointSessionID: selectedEndpointSessionID(remoteHost: remoteHost, remotePort: remotePort)
        )
    }

    @objc private func endpointPopupChanged(_ sender: NSPopUpButton) {
        applySelectedEndpoint()
    }

    @objc private func kindControlChanged(_ sender: NSSegmentedControl) {
        updateKindDependentFields()
    }

    @objc private func localHostFieldChanged(_ sender: NSTextField) {
        updateBindWarning()
    }

    private func configureEndpointPopup(existingRecord: TunnelProfileRecord?) {
        endpointPopup.removeAllItems()
        endpointPopup.isEnabled = !endpointSessions.isEmpty
        endpointPopup.target = self
        endpointPopup.action = #selector(endpointPopupChanged(_:))
        endpointPopup.setAccessibilityIdentifier("Stacio.Tunnels.endpointSession")

        guard !endpointSessions.isEmpty else {
            endpointPopup.addItem(withTitle: "未找到 SSH/SCP 会话")
            return
        }

        for endpoint in endpointSessions {
            endpointPopup.addItem(withTitle: endpoint.title)
            endpointPopup.lastItem?.representedObject = endpoint.id
        }

        if let endpointSessionID = existingRecord?.endpointSessionId,
           let matchingIndex = endpointSessions.firstIndex(where: { $0.id == endpointSessionID }) {
            endpointPopup.selectItem(at: matchingIndex)
            applySelectedEndpoint()
        } else if let existingProfile = existingRecord?.profile,
           let matchingIndex = endpointSessions.firstIndex(where: {
               $0.host == existingProfile.remoteHost && $0.port == existingProfile.remotePort
           }) {
            endpointPopup.selectItem(at: matchingIndex)
        } else {
            endpointPopup.selectItem(at: 0)
            applySelectedEndpoint()
        }
    }

    private func applySelectedEndpoint() {
        guard kind(for: kindControl.selectedSegment) != .dynamic else {
            return
        }
        guard endpointSessions.indices.contains(endpointPopup.indexOfSelectedItem) else {
            return
        }
        let endpoint = endpointSessions[endpointPopup.indexOfSelectedItem]
        remoteHostField.stringValue = endpoint.host
        remotePortField.stringValue = String(endpoint.port)
    }

    private func selectedEndpointSessionID(remoteHost: String, remotePort: UInt16) -> String? {
        guard endpointSessions.indices.contains(endpointPopup.indexOfSelectedItem) else {
            return nil
        }
        let endpoint = endpointSessions[endpointPopup.indexOfSelectedItem]
        guard endpoint.host == remoteHost && endpoint.port == remotePort else {
            return nil
        }
        return endpoint.id
    }

    private static func makeFormView(
        endpointPopup: NSPopUpButton,
        idField: NSTextField,
        kindControl: NSSegmentedControl,
        localHostField: NSTextField,
        localPortField: NSTextField,
        remoteHostField: NSTextField,
        remotePortField: NSTextField,
        bindWarningLabel: NSTextField
    ) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 512, height: 282))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let rows: [(String, NSView)] = [
            ("SSH 会话端点", endpointPopup),
            ("配置标识", idField),
            ("类型", kindControl),
            ("本地主机", localHostField),
            ("本地端口", localPortField),
            ("远端主机", remoteHostField),
            ("远端端口", remotePortField)
        ]

        [
            idField,
            localHostField,
            localPortField,
            remoteHostField,
            remotePortField
        ].forEach { field in
            field.cell?.usesSingleLineMode = true
            field.isEditable = true
            field.isSelectable = true
            StacioDesignSystem.styleTextField(field)
        }
        StacioDesignSystem.stylePopupButton(endpointPopup)
        StacioDesignSystem.styleSegmentedControl(kindControl)
        bindWarningLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bindWarningLabel.textColor = StacioDesignSystem.theme.dangerColor
        bindWarningLabel.lineBreakMode = .byWordWrapping
        bindWarningLabel.maximumNumberOfLines = 2
        bindWarningLabel.isHidden = true
        bindWarningLabel.translatesAutoresizingMaskIntoConstraints = false

        endpointPopup.setAccessibilityIdentifier("Stacio.Tunnels.endpointSession")
        idField.setAccessibilityIdentifier("Stacio.Tunnels.id")
        kindControl.setAccessibilityIdentifier("Stacio.Tunnels.kind")
        localHostField.setAccessibilityIdentifier("Stacio.Tunnels.localHost")
        localPortField.setAccessibilityIdentifier("Stacio.Tunnels.localPort")
        remoteHostField.setAccessibilityIdentifier("Stacio.Tunnels.remoteHost")
        remotePortField.setAccessibilityIdentifier("Stacio.Tunnels.remotePort")
        bindWarningLabel.setAccessibilityIdentifier("Stacio.Tunnels.bindWarning")

        let grid = NSGridView(views: rows.map { title, control in
            gridViews(label: title, control: control)
        })
        grid.setAccessibilityIdentifier("Stacio.Tunnels.editorGrid")
        grid.rowSpacing = 9
        grid.columnSpacing = 14
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 96
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 390
        container.addSubview(grid)
        container.addSubview(bindWarningLabel)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 512),
            container.heightAnchor.constraint(equalToConstant: 282),
            endpointPopup.widthAnchor.constraint(equalToConstant: 390),
            idField.widthAnchor.constraint(equalToConstant: 390),
            kindControl.widthAnchor.constraint(equalToConstant: 390),
            localHostField.widthAnchor.constraint(equalToConstant: 390),
            localPortField.widthAnchor.constraint(equalToConstant: 390),
            remoteHostField.widthAnchor.constraint(equalToConstant: 390),
            remotePortField.widthAnchor.constraint(equalToConstant: 390),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            bindWarningLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 110),
            bindWarningLabel.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            bindWarningLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            bindWarningLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])

        return container
    }

    private static func gridViews(label: String, control: NSView) -> [NSView] {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.font = .systemFont(ofSize: NSFont.systemFontSize)
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return [labelView, control]
    }

    private static func segment(for kind: TunnelKind) -> Int {
        switch kind {
        case .local: 0
        case .remote: 1
        case .dynamic: 2
        }
    }

    private func kind(for segment: Int) -> TunnelKind {
        switch segment {
        case 1: .remote
        case 2: .dynamic
        default: .local
        }
    }

    private func updateKindDependentFields() {
        let isDynamic = kind(for: kindControl.selectedSegment) == .dynamic
        remoteHostField.isHidden = isDynamic
        remotePortField.isHidden = isDynamic
        formGrid?.row(at: Self.remoteHostRowIndex).isHidden = isDynamic
        formGrid?.row(at: Self.remotePortRowIndex).isHidden = isDynamic
        endpointPopup.isEnabled = !isDynamic && !endpointSessions.isEmpty
        if !isDynamic {
            applySelectedEndpoint()
        }
        updateBindWarning()
    }

    private func updateBindWarning() {
        let isDynamic = kind(for: kindControl.selectedSegment) == .dynamic
        let localHost = localHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        bindWarningLabel.isHidden = !(isDynamic && localHost != "127.0.0.1")
    }

    private static let dynamicPlaceholderRemoteHost = "socks"
    private static let remoteHostRowIndex = 5
    private static let remotePortRowIndex = 6
}
