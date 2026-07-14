import AppKit
import StacioCoreBindings

@MainActor
public protocol SessionSidebarSessionEditing {
    func makeSessionDraft(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        parentWindow: NSWindow?
    ) -> SessionDraft?
}

@MainActor
public protocol SessionSidebarSessionDeleteConfirming {
    func shouldDeleteSessions(_ sessions: [SessionRecord], parentWindow: NSWindow?) -> Bool
}

public enum SessionSidebarSessionAuthMode: Equatable {
    case agent
    case password
    case privateKey
}

public struct SessionSidebarSessionFormValues {
    public let name: String
    public let host: String
    public let port: String
    public let username: String
    public let authMode: SessionSidebarSessionAuthMode
    public let privateKeyPath: String
    public let credentialSecret: String
    public let tags: String
    public let tagColorHex: String?
    public let allowsZeroPort: Bool

    public init(
        name: String,
        host: String,
        port: String,
        username: String,
        authMode: SessionSidebarSessionAuthMode,
        privateKeyPath: String,
        credentialSecret: String,
        tags: String,
        tagColorHex: String? = nil,
        allowsZeroPort: Bool = false
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMode = authMode
        self.privateKeyPath = privateKeyPath
        self.credentialSecret = credentialSecret
        self.tags = tags
        self.tagColorHex = tagColorHex
        self.allowsZeroPort = allowsZeroPort
    }
}

enum SerialConnectionSupport {
    static let baudRateOptions = [
        L10n.SessionSettings.autoBaudRate,
        "1200",
        "2400",
        "4800",
        "9600",
        "19200",
        "38400",
        "57600",
        "74880",
        "115200",
        "230400",
        "250000",
        "460800",
        "921600"
    ]

    static func defaultDevicePaths() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return preferredDevicePaths(from: entries.map { "/dev/\($0)" })
    }

    static func preferredDevicePaths(from devicePaths: [String]) -> [String] {
        var uniquePaths: [String] = []
        var seen = Set<String>()
        for path in devicePaths where seen.insert(path).inserted {
            guard path.hasPrefix("/dev/cu.") else {
                continue
            }
            uniquePaths.append(path)
        }
        return uniquePaths.sorted { lhs, rhs in
            let lhsPriority = priority(for: lhs)
            let rhsPriority = priority(for: rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func priority(for devicePath: String) -> Int {
        let lowercased = devicePath.lowercased()
        if lowercased.contains("usbserial")
            || lowercased.contains("usbmodem")
            || lowercased.contains("slab")
            || lowercased.contains("wchusbserial")
            || lowercased.contains("usb") {
            return 0
        }
        if lowercased.contains("bluetooth-incoming-port") {
            return 2
        }
        if lowercased.contains("bluetooth") {
            return 1
        }
        return 3
    }
}

enum SessionSidebarSessionFormMode: Equatable {
    case network
    case serial
    case ftp
    case browser
    case file
    case shell

    var hidesHost: Bool {
        self == .shell
    }

    var hidesPort: Bool {
        switch self {
        case .browser, .file, .shell:
            return true
        case .network, .serial, .ftp:
            return false
        }
    }

    var hidesUserAndAuth: Bool {
        switch self {
        case .serial, .browser, .file, .shell:
            return true
        case .network, .ftp:
            return false
        }
    }

    var stripsSecrets: Bool {
        hidesUserAndAuth
    }

    var forcedAuthMode: SessionSidebarSessionAuthMode? {
        self == .ftp ? .password : nil
    }

    var hostLabel: String {
        switch self {
        case .network, .ftp:
            return L10n.SessionSettings.host
        case .serial:
            return L10n.SessionSettings.devicePath
        case .browser:
            return L10n.SessionSettings.url
        case .file:
            return L10n.SessionSettings.localPath
        case .shell:
            return L10n.SessionSettings.host
        }
    }

    var portLabel: String {
        self == .serial ? L10n.SessionSettings.baudRate : L10n.SessionSettings.port
    }

    var hostPlaceholder: String {
        switch self {
        case .network, .ftp:
            return "api.example.com"
        case .serial:
            return "/dev/cu.usbserial-001"
        case .browser:
            return "https://example.com"
        case .file:
            return "~/Downloads"
        case .shell:
            return "localhost"
        }
    }

    var portPlaceholder: String {
        switch self {
        case .serial:
            return "9600"
        case .ftp:
            return "21"
        default:
            return "22"
        }
    }

    var hiddenPortValue: String? {
        switch self {
        case .browser:
            return "443"
        case .file, .shell:
            return "1"
        case .network, .serial, .ftp:
            return nil
        }
    }

    var allowsZeroPort: Bool {
        self == .serial
    }

    var treatsEmptyPortAsZero: Bool {
        self == .serial
    }
}

public enum SessionSidebarSessionDraftFactoryError: Error, Equatable {
    case credentialSaverUnavailable
}

public enum SessionSidebarSessionDraftValidationError: Error, Equatable, LocalizedError {
    case missingName
    case missingHost
    case invalidPort
    case privateKeyPathRequired
    case privateKeyPassphraseRequired

    public var errorDescription: String? {
        switch self {
        case .missingName:
            return L10n.SessionValidation.missingName
        case .missingHost:
            return L10n.SessionValidation.missingHost
        case .invalidPort:
            return L10n.SessionValidation.invalidPort
        case .privateKeyPathRequired:
            return L10n.SessionValidation.privateKeyPathRequired
        case .privateKeyPassphraseRequired:
            return L10n.SessionValidation.privateKeyPassphraseRequired
        }
    }
}

public final class SessionSidebarSessionDraftFactory {
    private let credentialSaver: SessionSidebarCredentialSaving?
    private let defaultUsername: () -> String

    public init(
        credentialSaver: SessionSidebarCredentialSaving? = nil,
        defaultUsername: @escaping () -> String = { NSUserName() }
    ) {
        self.credentialSaver = credentialSaver
        self.defaultUsername = defaultUsername
    }

    public func makeDraft(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        values: SessionSidebarSessionFormValues
    ) throws -> SessionDraft? {
        do {
            return try makeValidatedDraft(
                existingSession: existingSession,
                selectedFolderID: selectedFolderID,
                values: values
            )
        } catch is SessionSidebarSessionDraftValidationError {
            return nil
        }
    }

    public func makeValidatedDraft(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        values: SessionSidebarSessionFormValues
    ) throws -> SessionDraft {
        if let error = validationError(existingSession: existingSession, values: values) {
            throw error
        }

        let name = trimmed(values.name)
        let host = trimmed(values.host)
        let port = UInt32(trimmed(values.port))!

        let username = optionalTrimmed(values.username)
        let account = "\(username ?? defaultUsername())@\(host)"
        let existingMode = Self.authMode(for: existingSession)
        let preservedCredentialID = values.authMode == existingMode
            && account == existingAccount(for: existingSession)
            ? optionalTrimmed(existingSession?.credentialId ?? "")
            : nil
        let privateKeyPath: String?
        switch values.authMode {
        case .agent, .password:
            privateKeyPath = nil
        case .privateKey:
            privateKeyPath = optionalTrimmed(values.privateKeyPath)!
        }
        let credential = try credentialID(
            for: values.authMode,
            name: name,
            account: account,
            secret: values.credentialSecret,
            preservedCredentialID: preservedCredentialID
        )

        return SessionDraft(
            folderId: existingSession?.folderId ?? selectedFolderID,
            name: name,
            protocol: "ssh",
            host: host,
            port: port,
            username: username,
            privateKeyPath: privateKeyPath,
            credentialId: credential,
            tags: values.tags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty },
            configJson: tagStyleConfigJSON(colorHex: values.tagColorHex)
        )
    }

    public func validationError(
        existingSession: SessionRecord?,
        values: SessionSidebarSessionFormValues
    ) -> SessionSidebarSessionDraftValidationError? {
        let name = trimmed(values.name)
        let host = trimmed(values.host)
        guard !name.isEmpty else {
            return .missingName
        }
        guard !host.isEmpty else {
            return .missingHost
        }
        guard let port = UInt32(trimmed(values.port)) else {
            return .invalidPort
        }
        if !values.allowsZeroPort, port == 0 {
            return .invalidPort
        }

        let username = optionalTrimmed(values.username)
        let account = "\(username ?? defaultUsername())@\(host)"
        let existingMode = Self.authMode(for: existingSession)
        let preservedCredentialID = values.authMode == existingMode
            && account == existingAccount(for: existingSession)
            ? optionalTrimmed(existingSession?.credentialId ?? "")
            : nil

        switch values.authMode {
        case .agent:
            return nil
        case .password:
            return nil
        case .privateKey:
            guard optionalTrimmed(values.privateKeyPath) != nil else {
                return .privateKeyPathRequired
            }
            if values.credentialSecret.isEmpty,
               preservedCredentialID == nil,
               optionalTrimmed(existingSession?.credentialId ?? "") != nil {
                return .privateKeyPassphraseRequired
            }
            return nil
        }
    }

    private func credentialID(
        for authMode: SessionSidebarSessionAuthMode,
        name: String,
        account: String,
        secret: String,
        preservedCredentialID: String?
    ) throws -> String? {
        switch authMode {
        case .agent:
            return nil
        case .password:
            guard !secret.isEmpty else {
                return preservedCredentialID
            }
            return try saveCredential(
                kind: "password",
                label: "\(name) password",
                account: account,
                secret: secret
            )
        case .privateKey:
            guard !secret.isEmpty else {
                return preservedCredentialID
            }
            return try saveCredential(
                kind: "private_key_passphrase",
                label: "\(name) private key passphrase",
                account: account,
                secret: secret
            )
        }
    }

    private func saveCredential(
        kind: String,
        label: String,
        account: String,
        secret: String
    ) throws -> String {
        guard let credentialSaver else {
            throw SessionSidebarSessionDraftFactoryError.credentialSaverUnavailable
        }
        return try credentialSaver
            .saveCredential(kind: kind, label: label, account: account, secret: secret)
            .id
    }

    public static func authMode(for session: SessionRecord?) -> SessionSidebarSessionAuthMode {
        guard let session else {
            return .password
        }
        if let privateKeyPath = session.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !privateKeyPath.isEmpty {
            return .privateKey
        }
        if let credentialID = session.credentialId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !credentialID.isEmpty {
            return .password
        }
        return .agent
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private func existingAccount(for session: SessionRecord?) -> String? {
        guard let session else {
            return nil
        }
        return "\(session.username ?? defaultUsername())@\(session.host)"
    }

    private func tagStyleConfigJSON(colorHex: String?) -> String? {
        guard let colorHex = optionalTrimmed(colorHex ?? "") else {
            return nil
        }
        let payload = ["tagStyle": ["color": colorHex]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
public final class AppKitSessionSidebarSessionEditor: SessionSidebarSessionEditing {
    private let draftFactory: SessionSidebarSessionDraftFactory
    private let errorPresenter: SessionSidebarErrorPresenting
    private let sessionConfigJSONProvider: (SessionRecord) -> String?

    public init(
        credentialSaver: SessionSidebarCredentialSaving? = nil,
        errorPresenter: SessionSidebarErrorPresenting? = nil,
        sessionConfigJSONProvider: @escaping (SessionRecord) -> String? = { _ in nil }
    ) {
        draftFactory = SessionSidebarSessionDraftFactory(credentialSaver: credentialSaver)
        self.errorPresenter = errorPresenter ?? AppKitSessionSidebarErrorPresenter()
        self.sessionConfigJSONProvider = sessionConfigJSONProvider
    }

    public func makeSessionDraft(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        parentWindow: NSWindow?
    ) -> SessionDraft? {
        let controller = SessionSettingsWindowController(
            existingSession: existingSession,
            selectedFolderID: selectedFolderID,
            draftFactory: draftFactory,
            errorPresenter: errorPresenter,
            existingSerialConfigJSON: existingSession.flatMap(sessionConfigJSONProvider),
            parentWindowProvider: { parentWindow }
        )
        return controller.runModal(parentWindow: parentWindow)
    }
}

@MainActor
public final class AppKitSessionSidebarSessionDeleteConfirmation: SessionSidebarSessionDeleteConfirming {
    public init() {}

    public func shouldDeleteSessions(_ sessions: [SessionRecord], parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = sessions.count == 1 ? L10n.DeleteSession.oneTitle : L10n.DeleteSession.manyTitle
        alert.informativeText = sessions.count == 1
            ? L10n.DeleteSession.oneMessage
            : L10n.DeleteSession.manyMessage(sessions.count)
        alert.addButton(withTitle: L10n.Common.delete)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class SessionSidebarSessionForm: NSObject, NSTextFieldDelegate {
    let view: NSView

    private let existingSession: SessionRecord?
    private let selectedFolderID: String?
    private let draftFactory: SessionSidebarSessionDraftFactory
    private let nameField = NSTextField(string: "")
    private let hostField = NSComboBox()
    private let portField = NSComboBox()
    private let usernameField = NSTextField(string: "")
    private let authPopup = NSPopUpButton()
    private let privateKeyField = NSTextField(string: "")
    private let credentialSecretField = NSSecureTextField(string: "")
    private let tagsField = NSTextField(string: "")
    private let tagColorWell = NSColorWell()
    private var tagColorButtons: [NSButton] = []
    private let tagColorSample = NSTextField(labelWithString: "")
    private let grid: NSGridView
    private let hostRow: NSGridRow
    private let portRow: NSGridRow
    private let formLabels: [NSTextField]
    private let formControls: [NSView]
    private let hostLabel: NSTextField
    private let portLabel: NSTextField
    private let userRow: NSGridRow
    private let authRow: NSGridRow
    private let privateKeyRow: NSGridRow
    private let credentialSecretRow: NSGridRow
    private let tagsRow: NSGridRow
    private let tagColorRow: NSGridRow
    private let validationRow: NSGridRow
    private let credentialSecretLabel: NSTextField
    private let validationLabel: NSTextField
    private weak var saveButton: NSButton?
    private var mode: SessionSidebarSessionFormMode = .network
    private var shouldShowValidationFeedback = false
    private var lastAutofilledName: String?
    private let serialDevicePathProvider: () -> [String]
    private var serialDevicePathSuggestions: [String] = []
    private var serialPortSuggestions: [String] = []

    init(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        draftFactory: SessionSidebarSessionDraftFactory,
        serialDevicePathProvider: @escaping () -> [String] = SerialConnectionSupport.defaultDevicePaths
    ) {
        self.existingSession = existingSession
        self.selectedFolderID = selectedFolderID
        self.draftFactory = draftFactory
        self.serialDevicePathProvider = serialDevicePathProvider
        let components = Self.makeFormView(
            nameField: nameField,
            hostField: hostField,
            portField: portField,
            usernameField: usernameField,
            authPopup: authPopup,
            privateKeyField: privateKeyField,
            credentialSecretField: credentialSecretField,
            tagsField: tagsField,
            tagColorWell: tagColorWell,
            tagColorButtons: &tagColorButtons,
            tagColorSample: tagColorSample
        )
        view = components.container
        grid = components.grid
        hostRow = components.hostRow
        portRow = components.portRow
        formLabels = components.formLabels
        formControls = components.formControls
        hostLabel = components.hostLabel
        portLabel = components.portLabel
        userRow = components.userRow
        authRow = components.authRow
        privateKeyRow = components.privateKeyRow
        credentialSecretRow = components.credentialSecretRow
        tagsRow = components.tagsRow
        tagColorRow = components.tagColorRow
        validationRow = components.validationRow
        credentialSecretLabel = components.credentialSecretLabel
        validationLabel = components.validationLabel
        super.init()

        nameField.stringValue = existingSession?.name ?? ""
        hostField.stringValue = existingSession?.host ?? ""
        portField.stringValue = String(existingSession?.port ?? 22)
        usernameField.stringValue = existingSession?.username ?? ""
        privateKeyField.stringValue = existingSession?.privateKeyPath ?? ""
        tagsField.stringValue = existingSession?.tags.joined(separator: ", ") ?? ""
        tagColorWell.color = NSColor.systemBlue

        authPopup.addItems(withTitles: [
            L10n.SessionSettings.agent,
            L10n.SessionSettings.passwordAuth,
            L10n.SessionSettings.privateKeyAuth
        ])
        authPopup.selectItem(at: Self.popupIndex(for: SessionSidebarSessionDraftFactory.authMode(for: existingSession)))
        nameField.placeholderString = "生产 API"
        hostField.placeholderString = "例如：server.example.com"
        portField.placeholderString = "22"
        hostField.completes = true
        portField.completes = true
        usernameField.placeholderString = L10n.SessionSettings.optionalUser
        privateKeyField.placeholderString = "~/.ssh/id_ed25519"
        credentialSecretField.placeholderString = L10n.SessionSettings.passwordOrPassphrase
        tagsField.placeholderString = "生产, 接口"
        nameField.setAccessibilityIdentifier("Stacio.SessionEditor.name")
        hostField.setAccessibilityIdentifier("Stacio.SessionEditor.host")
        portField.setAccessibilityIdentifier("Stacio.SessionEditor.port")
        usernameField.setAccessibilityIdentifier("Stacio.SessionEditor.username")
        privateKeyField.setAccessibilityIdentifier("Stacio.SessionEditor.privateKey")
        credentialSecretField.setAccessibilityIdentifier("Stacio.SessionEditor.secret")
        tagsField.setAccessibilityIdentifier("Stacio.SessionEditor.tags")
        authPopup.setAccessibilityIdentifier("Stacio.SessionEditor.auth")

        [
            nameField,
            hostField,
            portField,
            usernameField,
            privateKeyField,
            credentialSecretField,
            tagsField
        ].forEach { field in
            field.delegate = self
            field.target = self
            field.action = #selector(controlValueChanged(_:))
            field.isEditable = true
            field.isSelectable = true
            field.cell?.usesSingleLineMode = true
            StacioDesignSystem.styleTextField(field)
        }
        StacioDesignSystem.stylePopupButton(authPopup)
        authPopup.target = self
        authPopup.action = #selector(authPopupChanged(_:))
        tagColorWell.target = self
        tagColorWell.action = #selector(tagColorChanged(_:))
        tagColorWell.setAccessibilityLabel(L10n.SessionSettings.tagColor)
        tagColorButtons.forEach { button in
            button.target = self
            button.action = #selector(tagColorPresetSelected(_:))
        }
        configureKeyViewLoop()
        updateTagColorSample()
        refreshSerialChoicesIfNeeded()
        refreshFormState()
    }

    func bind(saveButton: NSButton) {
        self.saveButton = saveButton
        refreshFormState()
    }

    var initialFirstResponder: NSView {
        existingSession == nil ? hostField : nameField
    }

    func draft() throws -> SessionDraft? {
        try draftFactory.makeValidatedDraft(
            existingSession: existingSession,
            selectedFolderID: selectedFolderID,
            values: formValues
        )
    }

    @objc private func authPopupChanged(_ sender: NSPopUpButton) {
        shouldShowValidationFeedback = true
        refreshFormState()
    }

    @objc private func tagColorChanged(_ sender: NSColorWell) {
        shouldShowValidationFeedback = true
        updateTagColorSample()
        refreshFormState()
    }

    @objc private func tagColorPresetSelected(_ sender: NSButton) {
        guard tagColorPresetColors.indices.contains(sender.tag) else {
            return
        }
        shouldShowValidationFeedback = true
        tagColorWell.color = tagColorPresetColors[sender.tag]
        updateTagColorSample()
        refreshFormState()
    }

    @objc private func controlValueChanged(_ sender: NSControl) {
        shouldShowValidationFeedback = true
        autofillNameFromHostIfNeeded(changedControl: sender)
        refreshFormState()
    }

    func controlTextDidChange(_ obj: Notification) {
        shouldShowValidationFeedback = true
        autofillNameFromHostIfNeeded(changedControl: obj.object as? NSControl)
        refreshFormState()
    }

    private var formValues: SessionSidebarSessionFormValues {
        let username = mode.stripsSecrets ? "" : usernameField.stringValue
        let authMode = mode.stripsSecrets ? .agent : mode.forcedAuthMode ?? Self.authMode(for: authPopup.indexOfSelectedItem)
        let host = mode == .shell ? "localhost" : hostField.stringValue
        let rawPort = mode.hiddenPortValue ?? portField.stringValue
        let port = mode.treatsEmptyPortAsZero && rawPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "0"
            : rawPort
        return SessionSidebarSessionFormValues(
            name: nameField.stringValue,
            host: host,
            port: port,
            username: username,
            authMode: authMode,
            privateKeyPath: privateKeyField.stringValue,
            credentialSecret: mode.stripsSecrets ? "" : credentialSecretField.stringValue,
            tags: tagsField.stringValue,
            tagColorHex: tagsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : tagColorWell.color.stacioHexRGB,
            allowsZeroPort: mode.allowsZeroPort
        )
    }

    private func refreshFormState() {
        refreshSerialChoicesIfNeeded()
        hostLabel.stringValue = mode.hostLabel
        portLabel.stringValue = mode.portLabel
        hostField.placeholderString = mode.hostPlaceholder
        portField.placeholderString = mode.portPlaceholder
        hostRow.isHidden = mode.hidesHost
        portRow.isHidden = mode.hidesPort
        userRow.isHidden = mode.hidesUserAndAuth
        authRow.isHidden = mode.hidesUserAndAuth || mode.forcedAuthMode != nil
        tagsRow.isHidden = false
        tagColorRow.isHidden = false

        let mode = self.mode.forcedAuthMode ?? Self.authMode(for: authPopup.indexOfSelectedItem)
        switch self.mode.stripsSecrets ? .agent : mode {
        case .agent:
            privateKeyRow.isHidden = true
            credentialSecretRow.isHidden = true
            credentialSecretLabel.stringValue = L10n.SessionSettings.secret
            credentialSecretField.placeholderString = L10n.SessionSettings.passwordOrPassphrase
        case .password:
            privateKeyRow.isHidden = true
            credentialSecretRow.isHidden = false
            credentialSecretLabel.stringValue = L10n.SessionSettings.password
            credentialSecretField.placeholderString = L10n.SessionSettings.optionalPassword
        case .privateKey:
            privateKeyRow.isHidden = false
            credentialSecretRow.isHidden = false
            credentialSecretLabel.stringValue = L10n.SessionSettings.passphrase
            credentialSecretField.placeholderString = L10n.SessionSettings.optionalPassphrase
        }

        if let error = draftFactory.validationError(existingSession: existingSession, values: formValues) {
            validationLabel.stringValue = shouldShowValidationFeedback ? error.localizedDescription : ""
            validationLabel.isHidden = !shouldShowValidationFeedback
            validationRow.isHidden = !shouldShowValidationFeedback
            saveButton?.isEnabled = false
        } else {
            validationLabel.stringValue = ""
            validationLabel.isHidden = true
            validationRow.isHidden = true
            saveButton?.isEnabled = true
        }
    }

    private func refreshSerialChoicesIfNeeded() {
        guard mode == .serial else {
            if !serialDevicePathSuggestions.isEmpty || !serialPortSuggestions.isEmpty {
                serialDevicePathSuggestions = []
                serialPortSuggestions = []
                hostField.removeAllItems()
                portField.removeAllItems()
            }
            return
        }

        let devicePaths = SerialConnectionSupport.preferredDevicePaths(from: serialDevicePathProvider())
        if devicePaths != serialDevicePathSuggestions {
            serialDevicePathSuggestions = devicePaths
            hostField.removeAllItems()
            hostField.addItems(withObjectValues: devicePaths)
        }

        let baudRates = SerialConnectionSupport.baudRateOptions
        if baudRates != serialPortSuggestions {
            serialPortSuggestions = baudRates
            portField.removeAllItems()
            portField.addItems(withObjectValues: baudRates)
        }

        autoSelectSerialDevicePathIfNeeded()
    }

    private func autoSelectSerialDevicePathIfNeeded() {
        guard mode == .serial,
              hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let firstDevicePath = serialDevicePathSuggestions.first
        else {
            return
        }
        hostField.stringValue = firstDevicePath
        if nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            nameField.stringValue == lastAutofilledName {
            nameField.stringValue = firstDevicePath
            lastAutofilledName = firstDevicePath
        }
    }

    private func updateTagColorSample() {
        tagColorSample.textColor = tagColorWell.color
    }

    private func autofillNameFromHostIfNeeded(changedControl: NSControl?) {
        guard changedControl === hostField else {
            if changedControl === nameField {
                let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedName != lastAutofilledName {
                    lastAutofilledName = nil
                }
            }
            return
        }

        let trimmedHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return
        }
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == lastAutofilledName {
            nameField.stringValue = trimmedHost
            lastAutofilledName = trimmedHost
        }
    }

    private func configureKeyViewLoop() {
        let controls: [NSView] = [
            nameField,
            hostField,
            portField,
            usernameField,
            authPopup,
            privateKeyField,
            credentialSecretField,
            tagsField
        ] + tagColorButtons + [tagColorWell]

        for (index, control) in controls.enumerated() {
            control.nextKeyView = controls[(index + 1) % controls.count]
        }
    }

    private static func makeFormView(
        nameField: NSTextField,
        hostField: NSTextField,
        portField: NSTextField,
        usernameField: NSTextField,
        authPopup: NSPopUpButton,
        privateKeyField: NSTextField,
        credentialSecretField: NSSecureTextField,
        tagsField: NSTextField,
        tagColorWell: NSColorWell,
        tagColorButtons: inout [NSButton],
        tagColorSample: NSTextField
    ) -> FormComponents {
        let nameRow = row(label: L10n.SessionSettings.name, field: nameField)
        let hostRow = row(label: L10n.SessionSettings.host, field: hostField)
        let portRow = row(label: L10n.SessionSettings.port, field: portField)
        let userRow = row(label: L10n.SessionSettings.user, field: usernameField)
        let authRow = row(label: L10n.SessionSettings.auth, field: authPopup)
        let privateKeyRow = row(
            label: L10n.SessionSettings.privateKey,
            field: privateKeyField,
            identifier: "Stacio.SessionEditor.privateKeyRow"
        )
        let credentialSecretRow = row(
            label: L10n.SessionSettings.secret,
            field: credentialSecretField,
            identifier: "Stacio.SessionEditor.credentialSecretRow"
        )
        let tagsRow = row(label: L10n.SessionSettings.tags, field: tagsField)
        tagColorSample.stringValue = ""
        tagColorSample.font = .systemFont(ofSize: NSFont.systemFontSize)
        tagColorSample.translatesAutoresizingMaskIntoConstraints = false
        tagColorSample.isHidden = true
        tagColorWell.controlSize = .regular
        tagColorWell.translatesAutoresizingMaskIntoConstraints = false
        tagColorWell.setAccessibilityIdentifier("Stacio.SessionEditor.tagColorCustom")
        tagColorButtons = tagColorPresetColors.enumerated().map { index, color in
            makeTagColorPresetButton(color: color, index: index)
        }
        let presetStack = NSStackView(views: tagColorButtons)
        presetStack.orientation = .horizontal
        presetStack.alignment = .centerY
        presetStack.spacing = 7
        presetStack.translatesAutoresizingMaskIntoConstraints = false
        let tagColorInput = NSStackView(views: [presetStack, tagColorWell, tagColorSample, NSView()])
        tagColorInput.orientation = .horizontal
        tagColorInput.alignment = .centerY
        tagColorInput.spacing = 12
        tagColorInput.translatesAutoresizingMaskIntoConstraints = false
        let tagColorRow = row(label: L10n.SessionSettings.tagColor, field: tagColorInput)
        let validationLabel = NSTextField(labelWithString: "")
        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 2
        validationLabel.translatesAutoresizingMaskIntoConstraints = false
        validationLabel.setAccessibilityIdentifier("Stacio.SessionEditor.validationMessage")
        validationLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let validationRow = row(label: "", field: validationLabel)

        let grid = NSGridView(views: [
            [nameRow.label, nameField],
            [hostRow.label, hostField],
            [portRow.label, portField],
            [userRow.label, usernameField],
            [authRow.label, authPopup],
            [privateKeyRow.label, privateKeyField],
            [credentialSecretRow.label, credentialSecretField],
            [tagsRow.label, tagsField],
            [tagColorRow.label, tagColorInput],
            [validationRow.label, validationLabel]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 11
        grid.columnSpacing = 14
        grid.setAccessibilityIdentifier("Stacio.SessionEditor.formGrid")
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 82
        grid.column(at: 1).xPlacement = .leading
        for rowIndex in 0..<grid.numberOfRows {
            grid.row(at: rowIndex).yPlacement = .center
        }

        let hostGridRow = grid.row(at: 1)
        let portGridRow = grid.row(at: 2)
        let userGridRow = grid.row(at: 3)
        let authGridRow = grid.row(at: 4)
        let privateKeyGridRow = grid.row(at: 5)
        let credentialSecretGridRow = grid.row(at: 6)
        let tagsGridRow = grid.row(at: 7)
        let tagColorGridRow = grid.row(at: 8)
        let validationGridRow = grid.row(at: 9)
        validationGridRow.isHidden = true

        [
            nameField,
            hostField,
            portField,
            usernameField,
            authPopup,
            privateKeyField,
            credentialSecretField
        ].forEach { field in
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 252).isActive = true
            field.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        tagsField.widthAnchor.constraint(equalToConstant: 252).isActive = true
        tagsField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        tagColorInput.widthAnchor.constraint(equalToConstant: 252).isActive = true
        tagColorInput.heightAnchor.constraint(equalToConstant: 36).isActive = true
        tagColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        tagColorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        tagColorButtons.forEach { button in
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 416, height: 294))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return FormComponents(
            container: container,
            grid: grid,
            hostRow: hostGridRow,
            portRow: portGridRow,
            formLabels: [
                nameRow.label,
                hostRow.label,
                portRow.label,
                userRow.label,
                authRow.label,
                privateKeyRow.label,
                credentialSecretRow.label,
                tagsRow.label,
                tagColorRow.label
            ],
            formControls: [
                nameField,
                hostField,
                portField,
                usernameField,
                authPopup,
                privateKeyField,
                credentialSecretField,
                tagsField,
                tagColorInput
            ],
            hostLabel: hostRow.label,
            portLabel: portRow.label,
            userRow: userGridRow,
            authRow: authGridRow,
            privateKeyRow: privateKeyGridRow,
            credentialSecretRow: credentialSecretGridRow,
            tagsRow: tagsGridRow,
            tagColorRow: tagColorGridRow,
            validationRow: validationGridRow,
            credentialSecretLabel: credentialSecretRow.label,
            validationLabel: validationLabel
        )
    }

    private static func row(label: String, field: NSView, identifier: String? = nil) -> FormRow {
        let labelView = NSTextField(labelWithString: label)
        labelView.cell = StacioCenteredLabelCell(textCell: label)
        labelView.alignment = .right
        labelView.font = .systemFont(ofSize: NSFont.systemFontSize)
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.lineBreakMode = .byClipping
        labelView.maximumNumberOfLines = 1
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 82).isActive = true
        labelView.heightAnchor.constraint(equalToConstant: 36).isActive = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelView.setAccessibilityIdentifier(identifier)
        return FormRow(label: labelView)
    }

    private static func makeTagColorPresetButton(color: NSColor, index: Int) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = tagColorPresetImage(color: color)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.tag = index
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("标签颜色 \(index + 1)")
        button.setAccessibilityIdentifier("Stacio.SessionEditor.tagColorPreset.\(index)")
        return button
    }

    private static func tagColorPresetImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: rect).fill()
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func selectAuthModeForTesting(_ mode: SessionSidebarSessionAuthMode) {
        authPopup.selectItem(at: Self.popupIndex(for: mode))
        refreshFormState()
    }

    func setValuesForTesting(_ values: SessionSidebarSessionFormValues) {
        shouldShowValidationFeedback = true
        applyValues(values, resetsMissingTagColor: false)
        refreshFormState()
    }

    func restoreValues(_ values: SessionSidebarSessionFormValues) {
        shouldShowValidationFeedback = false
        applyValues(values, resetsMissingTagColor: true)
        refreshFormState()
    }

    private func applyValues(_ values: SessionSidebarSessionFormValues, resetsMissingTagColor: Bool) {
        nameField.stringValue = values.name
        hostField.stringValue = values.host
        portField.stringValue = values.port
        usernameField.stringValue = values.username
        authPopup.selectItem(at: Self.popupIndex(for: values.authMode))
        privateKeyField.stringValue = values.privateKeyPath
        credentialSecretField.stringValue = values.credentialSecret
        tagsField.stringValue = values.tags
        if let tagColorHex = values.tagColorHex,
           let color = NSColor.stacioColor(hexRGB: tagColorHex) {
            tagColorWell.color = color
        } else if resetsMissingTagColor {
            tagColorWell.color = .systemBlue
        }
        updateTagColorSample()
    }

    func setConnectionValues(devicePath: String, baudRate: UInt32) {
        shouldShowValidationFeedback = true
        hostField.stringValue = devicePath
        portField.stringValue = baudRate == 0 ? "" : String(baudRate)
        refreshFormState()
    }

    func typeHostForTesting(_ value: String) {
        hostField.stringValue = value
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: hostField))
    }

    func typeNameForTesting(_ value: String) {
        nameField.stringValue = value
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nameField))
    }

    func setTagColorForTesting(_ hexRGB: String) {
        if let color = NSColor.stacioColor(hexRGB: hexRGB) {
            tagColorWell.color = color
        }
        updateTagColorSample()
        refreshFormState()
    }

    func replacePortForProtocolDefault(previousDefaultPort: UInt16, newDefaultPort: UInt16) {
        guard newDefaultPort > 0 else {
            return
        }
        let trimmedPort = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPort.isEmpty || trimmedPort == String(previousDefaultPort) {
            portField.stringValue = String(newDefaultPort)
            refreshFormState()
        }
    }

    func setPortValue(_ value: String) {
        shouldShowValidationFeedback = true
        portField.stringValue = value
        refreshFormState()
    }

    func selectBaudRateForTesting(_ title: String) {
        setPortValue(title == L10n.SessionSettings.autoBaudRate ? "" : title)
    }

    func applyModeForTesting(_ mode: SessionSidebarSessionFormMode) {
        applyMode(mode)
    }

    func applyMode(_ mode: SessionSidebarSessionFormMode) {
        self.mode = mode
        refreshFormState()
    }

    func markEditedForTesting() {
        shouldShowValidationFeedback = true
        refreshFormState()
    }

    func bindSaveButtonForTesting(_ button: NSButton) {
        bind(saveButton: button)
    }

    func layoutForTesting() {
        view.layoutSubtreeIfNeeded()
    }

    var secretLabelForTesting: String {
        credentialSecretLabel.stringValue
    }

    var validationMessageForTesting: String {
        validationLabel.stringValue
    }

    var isValidForSaving: Bool {
        draftFactory.validationError(existingSession: existingSession, values: formValues) == nil
    }

    var portValueForTesting: String {
        portField.stringValue
    }

    var currentValues: SessionSidebarSessionFormValues {
        SessionSidebarSessionFormValues(
            name: nameField.stringValue,
            host: hostField.stringValue,
            port: portField.stringValue,
            username: usernameField.stringValue,
            authMode: Self.authMode(for: authPopup.indexOfSelectedItem),
            privateKeyPath: privateKeyField.stringValue,
            credentialSecret: credentialSecretField.stringValue,
            tags: tagsField.stringValue,
            tagColorHex: tagColorWell.color.stacioHexRGB,
            allowsZeroPort: mode.allowsZeroPort
        )
    }

    var hostValueForTesting: String {
        hostField.stringValue
    }

    var hostSuggestionsForTesting: [String] {
        (0..<hostField.numberOfItems).compactMap { hostField.itemObjectValue(at: $0) as? String }
    }

    var portSuggestionsForTesting: [String] {
        (0..<portField.numberOfItems).compactMap { portField.itemObjectValue(at: $0) as? String }
    }

    var nameValueForTesting: String {
        nameField.stringValue
    }

    var usernameValueForTesting: String {
        usernameField.stringValue
    }

    var selectedAuthModeForTesting: SessionSidebarSessionAuthMode {
        Self.authMode(for: authPopup.indexOfSelectedItem)
    }

    var hostRowIsHiddenForTesting: Bool {
        hostRow.isHidden
    }

    var portRowIsHiddenForTesting: Bool {
        portRow.isHidden
    }

    var hostLabelForTesting: String {
        hostLabel.stringValue
    }

    var portLabelForTesting: String {
        portLabel.stringValue
    }

    var userRowIsHiddenForTesting: Bool {
        userRow.isHidden
    }

    var authRowIsHiddenForTesting: Bool {
        authRow.isHidden
    }

    var privateKeyRowIsHiddenForTesting: Bool {
        privateKeyRow.isHidden
    }

    var credentialSecretRowIsHiddenForTesting: Bool {
        credentialSecretRow.isHidden
    }

    var textFieldHeightsForTesting: [CGFloat] {
        [
            nameField,
            hostField,
            portField,
            usernameField,
            privateKeyField,
            credentialSecretField,
            tagsField
        ].map(\.fittingSize.height)
    }

    var textFieldsUseNativeBezelForTesting: Bool {
        [
            nameField,
            hostField,
            portField,
            usernameField,
            privateKeyField,
            credentialSecretField,
            tagsField
        ].allSatisfy { $0.isBezeled && $0.bezelStyle == .roundedBezel }
    }

    var textFieldsUseSystemRoundedBezelForTesting: Bool {
        editableFieldsForTesting.allSatisfy {
            $0.isBezeled && $0.bezelStyle == .roundedBezel
        }
    }

    var textFieldsUseCustomLayerBackgroundForTesting: Bool {
        editableFieldsForTesting.contains {
            $0.wantsLayer && $0.layer?.backgroundColor != nil
        }
    }

    var textFieldsUseCustomLayerBorderForTesting: Bool {
        editableFieldsForTesting.contains {
            $0.wantsLayer && (($0.layer?.borderWidth ?? 0) > 0 || $0.layer?.borderColor != nil)
        }
    }

    var textFieldsFollowSystemAppearanceForTesting: Bool {
        editableFieldsForTesting.allSatisfy {
            $0.backgroundColor == .textBackgroundColor && $0.appearance == nil
        }
    }

    var authPopupHeightForTesting: CGFloat {
        authPopup.fittingSize.height
    }

    var labelColumnWidthForTesting: CGFloat {
        grid.column(at: 0).width
    }

    var fieldColumnWidthForTesting: CGFloat {
        nameField.constraints
            .first { $0.firstAttribute == .width && $0.relation == .equal }?
            .constant ?? nameField.fittingSize.width
    }

    var formColumnSpacingForTesting: CGFloat {
        grid.columnSpacing
    }

    var formRowSpacingForTesting: CGFloat {
        grid.rowSpacing
    }

    var formLabelsUseTrailingAlignmentForTesting: Bool {
        formLabelViewsForTesting.allSatisfy { $0.alignment == .right }
    }

    var formRowsUseCenterYPlacementForTesting: Bool {
        (0..<grid.numberOfRows).allSatisfy { grid.row(at: $0).yPlacement == .center }
    }

    var formLabelsHaveStableControlHeightForTesting: Bool {
        formLabelViewsForTesting.allSatisfy { label in
            label.constraints.contains {
                $0.firstAttribute == .height
                    && $0.relation == .equal
                    && abs($0.constant - 36) < 0.1
            }
        }
    }

    var formLabelsUseFieldAlignedVerticalCenterForTesting: Bool {
        formLabelViewsForTesting.allSatisfy {
            $0.alignment == .right
                && $0.lineBreakMode == .byClipping
                && $0.maximumNumberOfLines == 1
        }
    }

    var formLabelAndFieldCentersAreAlignedForTesting: Bool {
        let pairs = Array(zip(formLabelViewsForTesting, formControlsForTesting))
        return pairs.allSatisfy { label, field in
            let labelFrame = label.convert(label.bounds, to: view)
            let fieldFrame = field.convert(field.bounds, to: view)
            return abs(labelFrame.midY - fieldFrame.midY) <= 1
        }
    }

    var formLabelTextAndInputContentCentersAreAlignedForTesting: Bool {
        let pairs = Array(zip(formLabelViewsForTesting, formControlsForTesting))
        return pairs.allSatisfy { label, control in
            let labelTextRect = label.cell?.drawingRect(forBounds: label.bounds) ?? label.bounds
            let controlContentRect: NSRect
            if let field = control as? NSTextField {
                controlContentRect = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
            } else if let popup = control as? NSPopUpButton {
                controlContentRect = popup.cell?.drawingRect(forBounds: popup.bounds) ?? popup.bounds
            } else {
                controlContentRect = control.bounds
            }
            let labelTextFrame = label.convert(labelTextRect, to: view)
            let controlContentFrame = control.convert(controlContentRect, to: view)
            return abs(labelTextFrame.midY - controlContentFrame.midY) <= 1
        }
    }

    var formControlsUseStableMacFormHeightForTesting: Bool {
        formControlsForTesting.allSatisfy { control in
            control.constraints.contains {
                $0.firstAttribute == .height
                    && $0.relation == .equal
                    && abs($0.constant - 36) < 0.1
            }
        }
    }

    var formFieldLeadingEdgesAreAlignedForTesting: Bool {
        let fields: [NSView] = [
            nameField,
            hostField,
            portField,
            usernameField,
            authPopup,
            credentialSecretField,
            tagsField
        ]
        guard let first = fields.first?.convert(fields[0].bounds, to: view).minX else {
            return false
        }
        return fields.allSatisfy { field in
            abs(field.convert(field.bounds, to: view).minX - first) <= 1
        }
    }

    var editableTextFieldsAllowSelectionForTesting: Bool {
        editableFieldsForTesting.allSatisfy(\.isSelectable)
    }

    var editableTextFieldsAcceptEditingForTesting: Bool {
        editableFieldsForTesting.allSatisfy(\.isEditable)
    }

    var editableTextFieldsUseFieldEditorForTesting: Bool {
        editableFieldsForTesting.allSatisfy { $0.cell?.usesSingleLineMode == true }
    }

    var editableTextFieldsUseReadableInsetsForTesting: Bool {
        editableFieldsForTesting.allSatisfy { field in
            if field is NSComboBox {
                return true
            }
            guard let cell = field.cell else {
                return false
            }
            let rect = cell.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 320, height: 36))
            return rect.minX >= 8 && rect.width <= 304 && rect.height < 36
        }
    }

    var validationRowIsHiddenForTesting: Bool {
        validationRow.isHidden
    }

    var tagColorWellIsHiddenForTesting: Bool {
        tagColorWell.isHidden
    }

    var tagColorRowIsHiddenForTesting: Bool {
        tagColorRow.isHidden
    }

    var tagColorAccessibilityLabelForTesting: String {
        tagColorWell.accessibilityLabel() ?? ""
    }

    var tagColorSampleTextForTesting: String {
        tagColorSample.stringValue
    }

    var tagColorPresetCountForTesting: Int {
        tagColorButtons.count
    }

    var tagColorPresetButtonsUseMinimumHitAreaForTesting: Bool {
        tagColorButtons.allSatisfy {
            let size = $0.fittingSize
            return size.width >= 28 && size.height >= 28
        }
    }

    var tagColorCustomWellAccessibilityIdentifierForTesting: String {
        tagColorWell.accessibilityIdentifier()
    }

    var selectedTagColorHexForTesting: String? {
        tagColorWell.color.stacioHexRGB
    }

    func selectTagColorPresetForTesting(index: Int) {
        guard tagColorButtons.indices.contains(index) else {
            return
        }
        tagColorPresetSelected(tagColorButtons[index])
    }

    private var editableFieldsForTesting: [NSTextField] {
        [
            nameField,
            hostField,
            portField,
            usernameField,
            privateKeyField,
            credentialSecretField,
            tagsField
        ]
    }

    private var formLabelViewsForTesting: [NSTextField] {
        formLabels
    }

    private var formControlsForTesting: [NSView] {
        formControls
    }

    var keyViewLoopIdentifiersForTesting: [String] {
        let controls: [NSView] = [
            nameField,
            hostField,
            portField,
            usernameField,
            authPopup,
            credentialSecretField,
            tagsField
        ] + tagColorButtons + [tagColorWell]
        return controls.map { $0.accessibilityIdentifier() }
    }

    private static func popupIndex(for mode: SessionSidebarSessionAuthMode) -> Int {
        switch mode {
        case .agent:
            return 0
        case .password:
            return 1
        case .privateKey:
            return 2
        }
    }

    private static func authMode(for popupIndex: Int) -> SessionSidebarSessionAuthMode {
        switch popupIndex {
        case 1:
            return .password
        case 2:
            return .privateKey
        default:
            return .agent
        }
    }

    private struct FormComponents {
        let container: NSView
        let grid: NSGridView
        let hostRow: NSGridRow
        let portRow: NSGridRow
        let formLabels: [NSTextField]
        let formControls: [NSView]
        let hostLabel: NSTextField
        let portLabel: NSTextField
        let userRow: NSGridRow
        let authRow: NSGridRow
        let privateKeyRow: NSGridRow
        let credentialSecretRow: NSGridRow
        let tagsRow: NSGridRow
        let tagColorRow: NSGridRow
        let validationRow: NSGridRow
        let credentialSecretLabel: NSTextField
        let validationLabel: NSTextField
    }

    private struct FormRow {
        let label: NSTextField
    }

    private static let tagColorPresetColors: [NSColor] = [
        NSColor.stacioColor(hexRGB: "#007AFF")!,
        NSColor.stacioColor(hexRGB: "#34C759")!,
        NSColor.stacioColor(hexRGB: "#FF9500")!,
        NSColor.stacioColor(hexRGB: "#FF3B30")!,
        NSColor.stacioColor(hexRGB: "#AF52DE")!,
        NSColor.stacioColor(hexRGB: "#8E8E93")!
    ]

    private var tagColorPresetColors: [NSColor] {
        Self.tagColorPresetColors
    }
}

private extension NSColor {
    var stacioHexRGB: String? {
        guard let color = usingColorSpace(.sRGB) else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }

    static func stacioColor(hexRGB: String) -> NSColor? {
        let trimmed = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6,
              let value = Int(hex, radix: 16)
        else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private final class StacioCenteredLabelCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: rect)
    }

    private func centeredTextRect(for rect: NSRect) -> NSRect {
        let textHeight = min(cellSize.height, rect.height)
        let yOffset = floor((rect.height - textHeight) / 2)
        return NSRect(
            x: rect.minX,
            y: rect.minY + yOffset,
            width: rect.width,
            height: textHeight
        )
    }
}
