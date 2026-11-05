import AppKit
import SQLite3
import StacioCoreBindings

public struct MultiExecPromptRequest: Equatable {
    public let input: String
    public let targetIDs: [String]
    public let productionConfirmed: Bool

    public init(input: String, targetIDs: [String], productionConfirmed: Bool) {
        self.input = input
        self.targetIDs = targetIDs
        self.productionConfirmed = productionConfirmed
    }
}

public struct MultiExecSessionSelection: Equatable {
    public let targetIDs: [String]

    public init(targetIDs: [String]) {
        self.targetIDs = targetIDs
    }
}

public struct MultiExecTargetChoice: Equatable {
    public let target: MultiExecTarget
    public let sessionProtocol: WorkspaceSessionProtocol

    public init(target: MultiExecTarget, sessionProtocol: WorkspaceSessionProtocol) {
        self.target = target
        self.sessionProtocol = sessionProtocol
    }

    public var id: String { target.id }
}

public struct MultiExecCommandSnippet: Equatable {
    public let title: String
    public let command: String

    public init(title: String, command: String) {
        self.title = title
        self.command = command
    }

    public static let builtIn: [MultiExecCommandSnippet] = [
        MultiExecCommandSnippet(title: L10n.MultiExec.systemOverviewSnippet, command: "uname -a"),
        MultiExecCommandSnippet(title: L10n.MultiExec.diskUsageSnippet, command: "df -h"),
        MultiExecCommandSnippet(title: L10n.MultiExec.currentUserSnippet, command: "whoami")
    ]

    public static func append(_ command: String, to input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? command
            : "\(input)\n\(command)"
    }
}

public struct MultiExecSavedMacro: Equatable {
    public let id: String
    public let title: String
    public let commandText: String

    public init(id: String, title: String, playbackSteps: [MacroStep]) {
        self.id = id
        self.title = title
        self.commandText = playbackSteps
            .sorted { lhs, rhs in lhs.order < rhs.order }
            .map { Self.redactedInput($0.input) }
            .joined(separator: "\n")
    }

    public init(recording: MacroRecording) {
        self.init(
            id: recording.id,
            title: recording.name,
            playbackSteps: CoreBridge.playbackMacroSteps(recording)
        )
    }

    private static func redactedInput(_ input: String) -> String {
        var shouldRedactNextBearerValue = false
        return input
            .split(whereSeparator: \.isWhitespace)
            .map { token -> String in
                let lowercased = token.lowercased()
                if shouldRedactNextBearerValue {
                    shouldRedactNextBearerValue = false
                    return "[redacted]"
                }
                if lowercased == "bearer" || lowercased.hasSuffix(":bearer") {
                    shouldRedactNextBearerValue = true
                    return String(token)
                }
                return lowercased.contains("password")
                    || lowercased.contains("passphrase")
                    || lowercased.contains("secret")
                    || lowercased.contains("credential")
                    || lowercased.contains("token")
                    || lowercased.contains("/.ssh/")
                    || lowercased.contains(".ssh/")
                    ? "[redacted]"
                    : String(token)
            }
            .joined(separator: " ")
    }
}

public struct MultiExecMacroLibrary: Equatable {
    public let macros: [MultiExecSavedMacro]

    public init(macros: [MultiExecSavedMacro] = []) {
        self.macros = macros
    }

    public init(recordings: [MacroRecording]) {
        self.macros = recordings.map(MultiExecSavedMacro.init(recording:))
    }
}

public struct TerminalMacroMetadata: Codable, Equatable {
    public var group: String?

    public init(group: String? = nil) {
        self.group = Self.normalizedGroup(group)
    }

    public static func normalizedGroup(_ group: String?) -> String? {
        guard let group else { return nil }
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol TerminalMacroMetadataStoring {
    func metadata(forMacroID macroID: String) throws -> TerminalMacroMetadata
    func setMetadata(_ metadata: TerminalMacroMetadata, forMacroID macroID: String) throws
}

public struct EmptyTerminalMacroMetadataStore: TerminalMacroMetadataStoring {
    public init() {}

    public func metadata(forMacroID macroID: String) throws -> TerminalMacroMetadata {
        TerminalMacroMetadata()
    }

    public func setMetadata(_ metadata: TerminalMacroMetadata, forMacroID macroID: String) throws {}
}

public enum SQLiteTerminalMacroMetadataStoreError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case macroNotFound
}

public final class SQLiteTerminalMacroMetadataStore: TerminalMacroMetadataStoring {
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let databasePath: String

    public static func defaultStore() throws -> SQLiteTerminalMacroMetadataStore {
        try SQLiteTerminalMacroMetadataStore(databasePath: StacioPaths().databaseURL.path)
    }

    public init(databasePath: String) throws {
        self.databasePath = databasePath
        try withDatabase { database in
            try Self.ensureMetadataColumn(in: database)
        }
    }

    public func metadata(forMacroID macroID: String) throws -> TerminalMacroMetadata {
        try withDatabase { database in
            try Self.ensureMetadataColumn(in: database)
            guard try Self.tableExists(in: database) else {
                return TerminalMacroMetadata()
            }
            var statement: OpaquePointer?
            try Self.prepare(
                "SELECT metadata_json FROM terminal_macros WHERE id = ?1",
                database: database,
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            Self.bindText(macroID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return TerminalMacroMetadata()
            }
            guard let text = sqlite3_column_text(statement, 0) else {
                return TerminalMacroMetadata()
            }
            let raw = String(cString: text)
            guard let data = raw.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(TerminalMacroMetadata.self, from: data)
            else {
                return TerminalMacroMetadata()
            }
            return metadata
        }
    }

    public func setMetadata(_ metadata: TerminalMacroMetadata, forMacroID macroID: String) throws {
        try withDatabase { database in
            try Self.ensureMetadataColumn(in: database)
            guard try Self.tableExists(in: database) else {
                throw SQLiteTerminalMacroMetadataStoreError.macroNotFound
            }
            let data = try JSONEncoder().encode(metadata)
            let json = String(decoding: data, as: UTF8.self)
            var statement: OpaquePointer?
            try Self.prepare(
                "UPDATE terminal_macros SET metadata_json = ?2, updated_at = ?3 WHERE id = ?1",
                database: database,
                statement: &statement
            )
            defer { sqlite3_finalize(statement) }
            Self.bindText(macroID, at: 1, in: statement)
            Self.bindText(json, at: 2, in: statement)
            Self.bindText(ISO8601DateFormatter().string(from: Date()), at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Self.stepError(database)
            }
            if sqlite3_changes(database) == 0 {
                throw SQLiteTerminalMacroMetadataStoreError.macroNotFound
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK,
              let database
        else {
            let message = database.map { Self.errorMessage(database: $0) } ?? "unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteTerminalMacroMetadataStoreError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func ensureMetadataColumn(in database: OpaquePointer) throws {
        guard try tableExists(in: database),
              try columnExists("metadata_json", in: database) == false
        else {
            return
        }
        try execute(
            "ALTER TABLE terminal_macros ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}'",
            database: database
        )
    }

    private static func tableExists(in database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'terminal_macros' LIMIT 1",
            database: database,
            statement: &statement
        )
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnExists(_ column: String, in database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(terminal_macros)", database: database, statement: &statement)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: text) == column {
                return true
            }
        }
        return false
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage(database: database)
            sqlite3_free(error)
            throw SQLiteTerminalMacroMetadataStoreError.stepFailed(message)
        }
    }

    private static func prepare(_ sql: String, database: OpaquePointer, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTerminalMacroMetadataStoreError.prepareFailed(errorMessage(database: database))
        }
    }

    private static func bindText(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transientDestructor)
        }
    }

    private static func stepError(_ database: OpaquePointer) -> SQLiteTerminalMacroMetadataStoreError {
        .stepFailed(errorMessage(database: database))
    }

    private static func errorMessage(database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}

public struct TerminalMacroJSONItem: Codable, Equatable {
    public let name: String
    public let commands: [String]
    public let group: String?

    public init(name: String, commands: [String], group: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? L10n.TerminalMacro.defaultMacroName : trimmedName
        self.commands = commands
        self.group = TerminalMacroMetadata.normalizedGroup(group)
    }
}

public enum TerminalMacroImportConflictPolicy: Equatable {
    case skip
    case overwrite
    case rename
}

public struct TerminalMacroImportResult: Equatable {
    public let createdCount: Int
    public let skippedCount: Int
    public let overwrittenCount: Int
    public let renamedCount: Int

    public init(createdCount: Int, skippedCount: Int, overwrittenCount: Int, renamedCount: Int) {
        self.createdCount = createdCount
        self.skippedCount = skippedCount
        self.overwrittenCount = overwrittenCount
        self.renamedCount = renamedCount
    }
}

public struct TerminalMacroImportExportCoordinator {
    public typealias ConflictResolver = (TerminalMacroJSONItem, TerminalMacroRecord) -> TerminalMacroImportConflictPolicy

    private let macroStore: TerminalMacroStoring
    private let metadataStore: TerminalMacroMetadataStoring

    public init(
        macroStore: TerminalMacroStoring,
        metadataStore: TerminalMacroMetadataStoring = EmptyTerminalMacroMetadataStore()
    ) {
        self.macroStore = macroStore
        self.metadataStore = metadataStore
    }

    public func exportData(macros: [TerminalMacroRecord]) throws -> Data {
        let items = try macros.map { macro in
            TerminalMacroJSONItem(
                name: macro.name,
                commands: macro.steps
                    .sorted { lhs, rhs in lhs.order < rhs.order }
                    .map(\.input),
                group: try metadataStore.metadata(forMacroID: macro.id).group
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(items)
    }

    @discardableResult
    public func importData(
        _ data: Data,
        conflictResolver: ConflictResolver
    ) throws -> TerminalMacroImportResult {
        let items = try JSONDecoder().decode([TerminalMacroJSONItem].self, from: data)
        var records = try macroStore.listMacros()
        var createdCount = 0
        var skippedCount = 0
        var overwrittenCount = 0
        var renamedCount = 0

        for item in items {
            if let existing = records.first(where: { $0.name == item.name }) {
                switch conflictResolver(item, existing) {
                case .skip:
                    skippedCount += 1
                case .overwrite:
                    let updated = try macroStore.updateMacro(
                        id: existing.id,
                        name: item.name,
                        commands: item.commands,
                        delayMS: 300
                    )
                    try metadataStore.setMetadata(
                        TerminalMacroMetadata(group: item.group),
                        forMacroID: updated.id
                    )
                    if let index = records.firstIndex(where: { $0.id == updated.id }) {
                        records[index] = updated
                    }
                    overwrittenCount += 1
                case .rename:
                    let uniqueName = Self.uniqueName(for: item.name, existingNames: Set(records.map(\.name)))
                    let created = try macroStore.createMacro(
                        name: uniqueName,
                        commands: item.commands,
                        delayMS: 300
                    )
                    try metadataStore.setMetadata(
                        TerminalMacroMetadata(group: item.group),
                        forMacroID: created.id
                    )
                    records.append(created)
                    createdCount += 1
                    renamedCount += 1
                }
            } else {
                let created = try macroStore.createMacro(
                    name: item.name,
                    commands: item.commands,
                    delayMS: 300
                )
                try metadataStore.setMetadata(
                    TerminalMacroMetadata(group: item.group),
                    forMacroID: created.id
                )
                records.append(created)
                createdCount += 1
            }
        }

        return TerminalMacroImportResult(
            createdCount: createdCount,
            skippedCount: skippedCount,
            overwrittenCount: overwrittenCount,
            renamedCount: renamedCount
        )
    }

    private static func uniqueName(for name: String, existingNames: Set<String>) -> String {
        var suffix = 2
        var candidate = "\(name) \(suffix)"
        while existingNames.contains(candidate) {
            suffix += 1
            candidate = "\(name) \(suffix)"
        }
        return candidate
    }
}

public extension MultiExecPromptRequest {
    func appendingSnippet(_ snippet: MultiExecCommandSnippet) -> MultiExecPromptRequest {
        MultiExecPromptRequest(
            input: MultiExecCommandSnippet.append(snippet.command, to: input),
            targetIDs: targetIDs,
            productionConfirmed: productionConfirmed
        )
    }

    func appendingMacro(_ macro: MultiExecSavedMacro) -> MultiExecPromptRequest {
        MultiExecPromptRequest(
            input: MultiExecCommandSnippet.append(macro.commandText, to: input),
            targetIDs: targetIDs,
            productionConfirmed: productionConfirmed
        )
    }
}

public struct MultiExecTargetPreviewRow: Equatable {
    public let id: String
    public let label: String
    public let environmentLabel: String
    public let stateLabel: String
    public let isEnabled: Bool
    public let requiresProductionConfirmation: Bool
    public let sessionProtocol: WorkspaceSessionProtocol

    public var summary: String {
        "\(label) - \(environmentLabel) - \(stateLabel)"
    }

    public static func rows(for targets: [MultiExecTarget]) -> [MultiExecTargetPreviewRow] {
        rows(for: targets.map {
            MultiExecTargetChoice(target: $0, sessionProtocol: .unmanaged)
        })
    }

    public static func rows(for targetChoices: [MultiExecTargetChoice]) -> [MultiExecTargetPreviewRow] {
        targetChoices.map(Self.init(targetChoice:))
    }

    public static func requiresProductionConfirmation(environment: String) -> Bool {
        environment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("production") == .orderedSame
    }

    private init(targetChoice: MultiExecTargetChoice) {
        let target = targetChoice.target
        id = target.id
        label = target.label
        requiresProductionConfirmation = Self.requiresProductionConfirmation(environment: target.environment)
        environmentLabel = requiresProductionConfirmation ? L10n.MultiExec.production : L10n.MultiExec.development
        stateLabel = target.enabled ? L10n.MultiExec.executable : L10n.MultiExec.unavailable
        isEnabled = target.enabled
        sessionProtocol = targetChoice.sessionProtocol
    }
}

public protocol MultiExecPromptPresenting {
    @MainActor
    func promptMultiExec(targetChoices: [MultiExecTargetChoice], parentWindow: NSWindow?) -> MultiExecPromptRequest?
}

public protocol MultiExecSessionSelecting {
    @MainActor
    func selectMultiExecTargets(targetChoices: [MultiExecTargetChoice], parentWindow: NSWindow?) -> MultiExecSessionSelection?
    @MainActor
    func presentMultiExecError(_ error: Error, parentWindow: NSWindow?)
}

public protocol MultiExecPreparing {
    func prepareBroadcastInput(
        targets: [MultiExecTarget],
        input: String,
        productionConfirmed: Bool
    ) throws -> BroadcastAuditEvent

    func markBroadcastExecuted(
        _ event: BroadcastAuditEvent,
        sentCount: UInt32
    ) -> BroadcastAuditEvent
}

public protocol MultiExecAuditRecording {
    func recordBroadcastAuditEvent(
        databasePath: String,
        event: BroadcastAuditEvent
    ) throws -> BroadcastAuditRecord
}

public protocol MultiExecAuditListing {
    func listBroadcastAuditRecords(limit: UInt32) throws -> [BroadcastAuditRecord]
}

public struct CoreBridgeMultiExecBridge: MultiExecPreparing {
    public init() {}

    public func prepareBroadcastInput(
        targets: [MultiExecTarget],
        input: String,
        productionConfirmed: Bool
    ) throws -> BroadcastAuditEvent {
        try CoreBridge.prepareBroadcastInput(
            targets: targets,
            input: input,
            productionConfirmed: productionConfirmed
        )
    }

    public func markBroadcastExecuted(
        _ event: BroadcastAuditEvent,
        sentCount: UInt32
    ) -> BroadcastAuditEvent {
        CoreBridge.markBroadcastExecuted(event, sentCount: sentCount)
    }
}

public struct CoreBridgeMultiExecAuditRecorder: MultiExecAuditRecording {
    public init() {}

    public func recordBroadcastAuditEvent(
        databasePath: String,
        event: BroadcastAuditEvent
    ) throws -> BroadcastAuditRecord {
        try CoreBridge.recordBroadcastAuditEvent(databasePath: databasePath, event: event)
    }
}

public struct CoreBridgeMultiExecAuditStore: MultiExecAuditRecording, MultiExecAuditListing {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func recordBroadcastAuditEvent(
        databasePath: String,
        event: BroadcastAuditEvent
    ) throws -> BroadcastAuditRecord {
        try CoreBridge.recordBroadcastAuditEvent(databasePath: databasePath, event: event)
    }

    public func listBroadcastAuditRecords(limit: UInt32) throws -> [BroadcastAuditRecord] {
        try CoreBridge.listBroadcastAuditRecords(databasePath: databasePath, limit: limit)
    }
}

@MainActor
private final class MultiExecModalShortcutScope {
    private let disabledMenuItems: [(NSMenuItem, Bool)]

    init() {
        disabledMenuItems = Self.commandDigitMenuItems().map { item in
            let state = (item, item.isEnabled)
            item.isEnabled = false
            return state
        }
    }

    deinit {
        disabledMenuItems.forEach { item, wasEnabled in
            item.isEnabled = wasEnabled
        }
    }

    private static func commandDigitMenuItems() -> [NSMenuItem] {
        guard let mainMenu = NSApp?.mainMenu else { return [] }
        var result: [NSMenuItem] = []

        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu {
                    visit(submenu)
                }
                let key = item.keyEquivalent
                let modifiers = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
                if key.count == 1,
                   key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "123456789").contains($0) }),
                   modifiers == [.command] {
                    result.append(item)
                }
            }
        }

        visit(mainMenu)
        return result
    }
}

public struct AppKitMultiExecPromptPresenter: MultiExecPromptPresenting {
    private let macroLibrary: MultiExecMacroLibrary

    public init(macroLibrary: MultiExecMacroLibrary = MultiExecMacroLibrary()) {
        self.macroLibrary = macroLibrary
    }

    public init(savedMacros: [MultiExecSavedMacro]) {
        self.init(macroLibrary: MultiExecMacroLibrary(macros: savedMacros))
    }

    public func promptMultiExec(
        targetChoices: [MultiExecTargetChoice],
        parentWindow: NSWindow?
    ) -> MultiExecPromptRequest? {
        let alert = NSAlert()
        alert.messageText = L10n.MultiExec.title
        alert.informativeText = targetChoices.isEmpty
            ? L10n.MultiExec.noTargets
            : "\(L10n.MultiExec.message)\n\(L10n.MultiExec.keyboardHint)"
        alert.addButton(withTitle: L10n.MultiExec.execute)
        alert.addButton(withTitle: L10n.Common.cancel)

        let form = MultiExecPromptForm(targetChoices: targetChoices, savedMacros: macroLibrary.macros)
        alert.accessoryView = form.view
        alert.buttons.first?.isEnabled = form.canSubmit
        form.onValidationChanged = { [weak alert] canSubmit in
            alert?.buttons.first?.isEnabled = canSubmit
        }

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak form] event in
            guard let form else { return event }
            return form.handleModalKeyEvent(event) ? nil : event
        }
        defer {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        let shortcutScope = MultiExecModalShortcutScope()

        let response = withExtendedLifetime(shortcutScope) {
            alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return form.request()
    }
}

public struct AppKitMultiExecSessionSelector: MultiExecSessionSelecting {
    public init() {}

    public func selectMultiExecTargets(
        targetChoices: [MultiExecTargetChoice],
        parentWindow: NSWindow?
    ) -> MultiExecSessionSelection? {
        let alert = NSAlert()
        alert.messageText = L10n.MultiExec.title
        alert.informativeText = targetChoices.count < 2
            ? "\(L10n.MultiExec.requiresMultipleTargets)\n\(L10n.MultiExec.keyboardHint)"
            : "\(L10n.MultiExec.interactiveMessage)\n\(L10n.MultiExec.keyboardHint)"
        alert.addButton(withTitle: L10n.MultiExec.start)
        alert.addButton(withTitle: L10n.Common.cancel)

        let form = MultiExecSessionSelectionForm(targetChoices: targetChoices)
        alert.accessoryView = form.view
        alert.buttons.first?.isEnabled = form.canSubmit
        form.onValidationChanged = { [weak alert] canSubmit in
            alert?.buttons.first?.isEnabled = canSubmit
        }

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak form] event in
            guard let form else { return event }
            return form.handleModalKeyEvent(event) ? nil : event
        }
        defer {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        let shortcutScope = MultiExecModalShortcutScope()

        let response = withExtendedLifetime(shortcutScope) {
            alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return form.selection()
    }

    public func presentMultiExecError(_ error: Error, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.MultiExec.title
        alert.informativeText = RuntimeDiagnosticFormatter.userMessage(for: error)
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
private final class MultiExecTargetListStackView: NSStackView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for subview in arrangedSubviews.reversed() where subview.frame.contains(point) {
            let localPoint = convert(point, to: subview)
            return subview.hitTest(localPoint) ?? subview
        }
        return self
    }
}

private extension WorkspaceSessionProtocol {
    var multiExecProtocolLabel: String {
        switch self {
        case .ssh:
            return "SSH"
        case .serial:
            return "串口"
        case .console:
            return "蓝牙 Console"
        case .telnet:
            return "Telnet"
        case .local:
            return "本地终端"
        default:
            return "终端"
        }
    }

    var multiExecProtocolSymbolName: String {
        switch self {
        case .ssh:
            return "key.fill"
        case .serial:
            return "cable.connector"
        case .console:
            return "bluetooth"
        case .telnet:
            return "diamond.fill"
        case .local:
            return "terminal"
        default:
            return "terminal"
        }
    }

    var multiExecProtocolAccentColor: NSColor {
        switch self {
        case .ssh:
            return .systemGreen
        case .serial:
            return .systemOrange
        case .console:
            return .systemBlue
        case .telnet:
            return .systemPurple
        case .local:
            return .systemGray
        default:
            return .secondaryLabelColor
        }
    }

    var multiExecProtocolAccentIdentifier: String {
        switch self {
        case .ssh:
            return "green"
        case .serial:
            return "orange"
        case .console:
            return "blue"
        case .telnet:
            return "purple"
        case .local:
            return "gray"
        default:
            return "secondary"
        }
    }
}

@MainActor
private final class MultiExecSelectionKeyboardView: NSView {
    var onCommandDigit: ((Int) -> Void)?
    var onSelectAll: (() -> Void)?
    var onClearSelection: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyboardEvent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyboardEvent(event) { return }
        super.keyDown(with: event)
    }

    func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 51 || event.keyCode == 117 {
            onClearSelection?()
            return true
        }
        if modifiers == [.command], event.keyCode == 0 {
            onSelectAll?()
            return true
        }
        if let digit = Self.commandDigit(for: event), modifiers == [.command] {
            onCommandDigit?(digit)
            return true
        }
        return false
    }

    private static func commandDigit(for event: NSEvent) -> Int? {
        switch event.keyCode {
        case 18, 83: return 1
        case 19, 84: return 2
        case 20, 85: return 3
        case 21, 86: return 4
        case 23, 87: return 5
        case 22, 88: return 6
        case 26, 89: return 7
        case 28, 91: return 8
        case 25, 92: return 9
        default: return nil
        }
    }
}

@MainActor
private final class MultiExecTargetSelectionRowView: NSView {
    static let minimumHeight: CGFloat = 40

    let targetID: String
    let checkbox: NSButton
    let protocolLabel: String
    let protocolSymbolName: String
    let protocolAccentIdentifier: String
    var onMouseSelection: ((NSEvent) -> Void)?

    init(
        targetRow: MultiExecTargetPreviewRow,
        number: Int,
        accessibilityIdentifier: String,
        target: AnyObject?,
        action: Selector?
    ) {
        targetID = targetRow.id
        protocolLabel = targetRow.sessionProtocol.multiExecProtocolLabel
        protocolSymbolName = targetRow.sessionProtocol.multiExecProtocolSymbolName
        protocolAccentIdentifier = targetRow.sessionProtocol.multiExecProtocolAccentIdentifier
        checkbox = NSButton(checkboxWithTitle: "", target: target, action: action)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "\(protocolLabel) · \(targetRow.label)"

        checkbox.identifier = NSUserInterfaceItemIdentifier(targetRow.id)
        checkbox.state = targetRow.isEnabled ? .on : .off
        checkbox.isEnabled = targetRow.isEnabled
        checkbox.refusesFirstResponder = true
        checkbox.setAccessibilityIdentifier(accessibilityIdentifier)
        checkbox.setAccessibilityLabel(
            "\(protocolLabel)，\(targetRow.label)，\(targetRow.environmentLabel)，\(targetRow.stateLabel)"
        )
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let numberLabel = NSTextField(labelWithString: "\(number)")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        numberLabel.textColor = targetRow.isEnabled
            ? StacioDesignSystem.theme.secondaryTextColor
            : .tertiaryLabelColor
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        let accentColor = targetRow.sessionProtocol.multiExecProtocolAccentColor
        let iconView = NSImageView()
        iconView.image = StacioSymbolImage.image(
            named: protocolSymbolName,
            accessibilityDescription: protocolLabel,
            size: NSSize(width: 18, height: 18)
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = targetRow.isEnabled ? accentColor : .tertiaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: targetRow.label)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.textColor = targetRow.isEnabled
            ? StacioDesignSystem.theme.primaryTextColor
            : .tertiaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.toolTip = targetRow.label

        let detailLabel = NSTextField(
            labelWithString: "\(targetRow.environmentLabel) · \(targetRow.stateLabel)"
        )
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = targetRow.isEnabled
            ? StacioDesignSystem.theme.secondaryTextColor
            : .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let protocolLabelView = NSTextField(labelWithString: protocolLabel)
        protocolLabelView.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        protocolLabelView.textColor = targetRow.isEnabled ? accentColor : .tertiaryLabelColor
        protocolLabelView.alignment = .right
        protocolLabelView.lineBreakMode = .byTruncatingTail
        protocolLabelView.maximumNumberOfLines = 1
        protocolLabelView.setAccessibilityIdentifier(
            "Stacio.MultiExec.targetProtocol.\(targetRow.id)"
        )
        protocolLabelView.translatesAutoresizingMaskIntoConstraints = false
        protocolLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(numberLabel)
        addSubview(checkbox)
        addSubview(iconView)
        addSubview(textStack)
        addSubview(protocolLabelView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 22),
            checkbox.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 6),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            protocolLabelView.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12),
            protocolLabelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            protocolLabelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            protocolLabelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onMouseSelection?(event)
    }
}

@MainActor
final class MultiExecSessionSelectionForm: NSObject {
    let view: NSView
    var onValidationChanged: ((Bool) -> Void)?

    private let targets: [MultiExecTarget]
    private let targetRows: [MultiExecTargetPreviewRow]
    private let keyboardView: MultiExecSelectionKeyboardView
    private var targetCheckboxes: [NSButton] = []
    private var targetSelectionRows: [MultiExecTargetSelectionRowView] = []
    private var mouseSelectionAnchorIndex: Int?

    convenience init(targets: [MultiExecTarget]) {
        self.init(targetChoices: targets.map {
            MultiExecTargetChoice(target: $0, sessionProtocol: .unmanaged)
        })
    }

    init(targetChoices: [MultiExecTargetChoice]) {
        self.targets = targetChoices.map(\.target)
        self.targetRows = MultiExecTargetPreviewRow.rows(for: targetChoices)

        let container = MultiExecSelectionKeyboardView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        keyboardView = container
        container.translatesAutoresizingMaskIntoConstraints = false

        let targetStack = MultiExecTargetListStackView()
        targetStack.orientation = .vertical
        targetStack.spacing = 4
        targetStack.alignment = .width
        targetStack.translatesAutoresizingMaskIntoConstraints = false

        let targetScrollView = NSScrollView()
        targetScrollView.borderType = .bezelBorder
        targetScrollView.hasVerticalScroller = true
        targetScrollView.translatesAutoresizingMaskIntoConstraints = false
        targetScrollView.documentView = targetStack

        let stack = NSStackView(views: [
            NSTextField(labelWithString: L10n.MultiExec.targets),
            targetScrollView
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 520),
            targetScrollView.heightAnchor.constraint(equalToConstant: 150),
            targetStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 500)
        ])

        view = container
        super.init()

        container.onCommandDigit = { [weak self] digit in self?.toggleCommandDigit(digit) }
        container.onSelectAll = { [weak self] in self?.selectAllTargets() }
        container.onClearSelection = { [weak self] in self?.clearTargetSelection() }
        configureTargets(in: targetStack)
        refreshValidation()
    }

    func handleModalKeyEvent(_ event: NSEvent) -> Bool {
        if (event.keyCode == 51 || event.keyCode == 117), keyboardView.window?.firstResponder !== keyboardView {
            return false
        }
        return keyboardView.handleKeyboardEvent(event)
    }

    var canSubmit: Bool {
        selectedTargetIDs.count >= 2
    }

    func selection() -> MultiExecSessionSelection? {
        guard canSubmit else { return nil }
        return MultiExecSessionSelection(targetIDs: selectedTargetIDs)
    }

    private var selectedTargetIDs: [String] {
        targetCheckboxes.compactMap { checkbox in
            checkbox.state == .on ? checkbox.identifier?.rawValue : nil
        }
    }

    private func configureTargets(in stack: NSStackView) {
        guard !targetRows.isEmpty else {
            stack.addArrangedSubview(NSTextField(labelWithString: L10n.MultiExec.noTargets))
            return
        }

        for (index, target) in targetRows.enumerated() {
            let row = MultiExecTargetSelectionRowView(
                targetRow: target,
                number: index + 1,
                accessibilityIdentifier: "Stacio.MultiExec.sessionTarget.\(target.id)",
                target: self,
                action: #selector(refreshValidation)
            )
            targetCheckboxes.append(row.checkbox)
            targetSelectionRows.append(row)
            row.onMouseSelection = { [weak self] event in
                self?.handleMouseSelection(at: index, modifiers: event.modifierFlags)
            }
            stack.addArrangedSubview(row)
        }
    }

    private func handleMouseSelection(at index: Int, modifiers: NSEvent.ModifierFlags) {
        guard targetRows.indices.contains(index), targetCheckboxes[index].isEnabled else { return }
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)

        if isShift {
            let anchor = mouseSelectionAnchorIndex ?? index
            let range = min(anchor, index)...max(anchor, index)
            if !isCommand {
                targetCheckboxes.forEach { $0.state = .off }
            }
            for rowIndex in range where targetCheckboxes[rowIndex].isEnabled {
                targetCheckboxes[rowIndex].state = .on
            }
        } else {
            let checkbox = targetCheckboxes[index]
            checkbox.state = checkbox.state == .on ? .off : .on
        }

        mouseSelectionAnchorIndex = index
        refreshValidation()
    }

    private var commandDigitSelectionStarted = false

    private func toggleCommandDigit(_ digit: Int) {
        guard targetRows.indices.contains(digit - 1) else { return }
        if commandDigitSelectionStarted == false {
            commandDigitSelectionStarted = true
            if targetCheckboxes.allSatisfy({ $0.state == .on || $0.isEnabled == false }) {
                targetCheckboxes.forEach { if $0.isEnabled { $0.state = .off } }
            }
        }
        let checkbox = targetCheckboxes[digit - 1]
        guard checkbox.isEnabled else { return }
        checkbox.state = checkbox.state == .on ? .off : .on
        refreshValidation()
    }

    private func selectAllTargets() {
        commandDigitSelectionStarted = false
        targetCheckboxes.forEach { $0.state = $0.isEnabled ? .on : .off }
        refreshValidation()
    }

    private func clearTargetSelection() {
        commandDigitSelectionStarted = false
        targetCheckboxes.forEach { $0.state = .off }
        refreshValidation()
    }

    @objc
    private func refreshValidation() {
        onValidationChanged?(canSubmit)
    }

    var protocolLabelsForTesting: [String: String] {
        Dictionary(uniqueKeysWithValues: targetSelectionRows.map { ($0.targetID, $0.protocolLabel) })
    }

    var protocolSymbolNamesForTesting: [String: String] {
        Dictionary(uniqueKeysWithValues: targetSelectionRows.map { ($0.targetID, $0.protocolSymbolName) })
    }

    var protocolLabelsUseDistinctAccentColorsForTesting: Bool {
        let identifiers = targetSelectionRows.map(\.protocolAccentIdentifier)
        return Set(identifiers).count == identifiers.count
    }

    var minimumTargetRowHeightForTesting: CGFloat {
        MultiExecTargetSelectionRowView.minimumHeight
    }
}

@MainActor
private final class MultiExecPromptForm: NSObject {
    let view: NSView
    var onValidationChanged: ((Bool) -> Void)?

    private let inputView = NSTextView()
    private let snippetPopup = NSPopUpButton()
    private let productionConfirmationCheckbox = NSButton(
        checkboxWithTitle: L10n.MultiExec.productionConfirmation,
        target: nil,
        action: nil
    )
    private let targets: [MultiExecTarget]
    private let targetRows: [MultiExecTargetPreviewRow]
    private let keyboardView: MultiExecSelectionKeyboardView
    private let savedMacros: [MultiExecSavedMacro]
    private var targetCheckboxes: [NSButton] = []
    private var commandDigitSelectionStarted = false
    private var mouseSelectionAnchorIndex: Int?

    convenience init(targets: [MultiExecTarget], savedMacros: [MultiExecSavedMacro] = []) {
        self.init(
            targetChoices: targets.map {
                MultiExecTargetChoice(target: $0, sessionProtocol: .unmanaged)
            },
            savedMacros: savedMacros
        )
    }

    init(targetChoices: [MultiExecTargetChoice], savedMacros: [MultiExecSavedMacro] = []) {
        self.targets = targetChoices.map(\.target)
        self.targetRows = MultiExecTargetPreviewRow.rows(for: targetChoices)
        self.savedMacros = savedMacros

        let container = MultiExecSelectionKeyboardView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        keyboardView = container
        container.translatesAutoresizingMaskIntoConstraints = false

        let targetStack = MultiExecTargetListStackView()
        targetStack.orientation = .vertical
        targetStack.spacing = 4
        targetStack.alignment = .width
        targetStack.translatesAutoresizingMaskIntoConstraints = false

        let inputScrollView = NSScrollView()
        inputScrollView.borderType = .bezelBorder
        inputScrollView.hasVerticalScroller = true
        inputScrollView.translatesAutoresizingMaskIntoConstraints = false
        inputView.minSize = NSSize(width: 0, height: 80)
        inputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        inputView.setAccessibilityIdentifier("Stacio.MultiExec.input")
        inputScrollView.documentView = inputView

        let snippetLabel = NSTextField(labelWithString: L10n.MultiExec.snippets)
        snippetLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        let snippetRow = NSStackView(views: [snippetLabel, snippetPopup])
        snippetRow.orientation = .horizontal
        snippetRow.spacing = 8
        snippetRow.alignment = .centerY
        snippetRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            snippetLabel.widthAnchor.constraint(equalToConstant: 72),
            snippetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])

        let targetScrollView = NSScrollView()
        targetScrollView.borderType = .bezelBorder
        targetScrollView.hasVerticalScroller = true
        targetScrollView.translatesAutoresizingMaskIntoConstraints = false
        targetScrollView.documentView = targetStack

        productionConfirmationCheckbox.setAccessibilityIdentifier("Stacio.MultiExec.productionConfirmation")

        let stack = NSStackView(views: [
            NSTextField(labelWithString: L10n.MultiExec.command),
            snippetRow,
            inputScrollView,
            NSTextField(labelWithString: L10n.MultiExec.targets),
            targetScrollView,
            productionConfirmationCheckbox
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 520),
            inputScrollView.heightAnchor.constraint(equalToConstant: 92),
            targetScrollView.heightAnchor.constraint(equalToConstant: 132),
            targetStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 500)
        ])

        view = container
        super.init()

        inputView.delegate = self
        configureSnippetPopup()
        productionConfirmationCheckbox.target = self
        productionConfirmationCheckbox.action = #selector(refreshValidation)
        container.onCommandDigit = { [weak self] digit in self?.toggleCommandDigit(digit) }
        container.onSelectAll = { [weak self] in self?.selectAllTargets() }
        container.onClearSelection = { [weak self] in self?.clearTargetSelection() }
        configureTargets(in: targetStack)
        refreshValidation()
    }

    func handleModalKeyEvent(_ event: NSEvent) -> Bool {
        if (event.keyCode == 51 || event.keyCode == 117), keyboardView.window?.firstResponder !== keyboardView {
            return false
        }
        return keyboardView.handleKeyboardEvent(event)
    }

    var canSubmit: Bool {
        !trimmedInput.isEmpty
            && !selectedTargetIDs.isEmpty
            && (!selectedTargetsContainProduction || productionConfirmationCheckbox.state == .on)
    }

    func request() -> MultiExecPromptRequest? {
        guard canSubmit else { return nil }
        return MultiExecPromptRequest(
            input: inputView.string,
            targetIDs: selectedTargetIDs,
            productionConfirmed: productionConfirmationCheckbox.state == .on
        )
    }

    private var trimmedInput: String {
        inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTargetIDs: [String] {
        targetCheckboxes.compactMap { checkbox in
            checkbox.state == .on ? checkbox.identifier?.rawValue : nil
        }
    }

    private var selectedTargetsContainProduction: Bool {
        let selected = Set(selectedTargetIDs)
        return targets.contains { target in
            selected.contains(target.id)
                && MultiExecTargetPreviewRow.requiresProductionConfirmation(environment: target.environment)
        }
    }

    private func configureSnippetPopup() {
        snippetPopup.addItem(withTitle: L10n.MultiExec.chooseSnippet)
        snippetPopup.menu?.items.first?.isEnabled = false
        for snippet in MultiExecCommandSnippet.builtIn {
            snippetPopup.addItem(withTitle: snippet.title)
        }
        if !savedMacros.isEmpty {
            snippetPopup.menu?.addItem(.separator())
            for macro in savedMacros {
                snippetPopup.addItem(withTitle: "\(L10n.MultiExec.macroPrefix)\(macro.title)")
            }
        }
        snippetPopup.target = self
        snippetPopup.action = #selector(snippetPopupChanged(_:))
        snippetPopup.setAccessibilityIdentifier("Stacio.MultiExec.snippets")
        StacioDesignSystem.stylePopupButton(snippetPopup)
    }

    private func configureTargets(in stack: NSStackView) {
        guard !targetRows.isEmpty else {
            stack.addArrangedSubview(NSTextField(labelWithString: L10n.MultiExec.noTargets))
            return
        }

        for (index, target) in targetRows.enumerated() {
            let row = MultiExecTargetSelectionRowView(
                targetRow: target,
                number: index + 1,
                accessibilityIdentifier: "Stacio.MultiExec.target.\(target.id)",
                target: self,
                action: #selector(refreshValidation)
            )
            targetCheckboxes.append(row.checkbox)
            row.onMouseSelection = { [weak self] event in
                self?.handleMouseSelection(at: index, modifiers: event.modifierFlags)
            }
            stack.addArrangedSubview(row)
        }
    }

    private func handleMouseSelection(at index: Int, modifiers: NSEvent.ModifierFlags) {
        guard targetRows.indices.contains(index), targetCheckboxes[index].isEnabled else { return }
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)

        if isShift {
            let anchor = mouseSelectionAnchorIndex ?? index
            let range = min(anchor, index)...max(anchor, index)
            if !isCommand {
                targetCheckboxes.forEach { $0.state = .off }
            }
            for rowIndex in range where targetCheckboxes[rowIndex].isEnabled {
                targetCheckboxes[rowIndex].state = .on
            }
        } else {
            let checkbox = targetCheckboxes[index]
            checkbox.state = checkbox.state == .on ? .off : .on
        }

        mouseSelectionAnchorIndex = index
        refreshValidation()
    }

    private func toggleCommandDigit(_ digit: Int) {
        guard targetRows.indices.contains(digit - 1) else { return }
        if commandDigitSelectionStarted == false {
            commandDigitSelectionStarted = true
            if targetCheckboxes.allSatisfy({ $0.state == .on || $0.isEnabled == false }) {
                targetCheckboxes.forEach { if $0.isEnabled { $0.state = .off } }
            }
        }
        let checkbox = targetCheckboxes[digit - 1]
        guard checkbox.isEnabled else { return }
        checkbox.state = checkbox.state == .on ? .off : .on
        refreshValidation()
    }

    private func selectAllTargets() {
        commandDigitSelectionStarted = false
        targetCheckboxes.forEach { $0.state = $0.isEnabled ? .on : .off }
        refreshValidation()
    }

    private func clearTargetSelection() {
        commandDigitSelectionStarted = false
        targetCheckboxes.forEach { $0.state = .off }
        refreshValidation()
    }

    @objc
    private func refreshValidation() {
        productionConfirmationCheckbox.isHidden = !selectedTargetsContainProduction
        onValidationChanged?(canSubmit)
    }

    @objc
    private func snippetPopupChanged(_ sender: NSPopUpButton) {
        let snippetIndex = sender.indexOfSelectedItem - 1
        let builtInSnippets = MultiExecCommandSnippet.builtIn
        if builtInSnippets.indices.contains(snippetIndex) {
            inputView.string = MultiExecCommandSnippet.append(
                builtInSnippets[snippetIndex].command,
                to: inputView.string
            )
        } else {
            let macroIndex = snippetIndex - builtInSnippets.count - 1
            guard savedMacros.indices.contains(macroIndex) else { return }
            inputView.string = MultiExecCommandSnippet.append(
                savedMacros[macroIndex].commandText,
                to: inputView.string
            )
        }
        sender.selectItem(at: 0)
        refreshValidation()
    }
}

extension MultiExecPromptForm: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        refreshValidation()
    }
}
