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

    public var summary: String {
        "\(label) - \(environmentLabel) - \(stateLabel)"
    }

    public static func rows(for targets: [MultiExecTarget]) -> [MultiExecTargetPreviewRow] {
        targets.map(Self.init(target:))
    }

    public static func requiresProductionConfirmation(environment: String) -> Bool {
        environment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("production") == .orderedSame
    }

    private init(target: MultiExecTarget) {
        id = target.id
        label = target.label
        requiresProductionConfirmation = Self.requiresProductionConfirmation(environment: target.environment)
        environmentLabel = requiresProductionConfirmation ? L10n.MultiExec.production : L10n.MultiExec.development
        stateLabel = target.enabled ? L10n.MultiExec.executable : L10n.MultiExec.unavailable
        isEnabled = target.enabled
    }
}

public protocol MultiExecPromptPresenting {
    @MainActor
    func promptMultiExec(targets: [MultiExecTarget], parentWindow: NSWindow?) -> MultiExecPromptRequest?
}

public protocol MultiExecSessionSelecting {
    @MainActor
    func selectMultiExecTargets(targets: [MultiExecTarget], parentWindow: NSWindow?) -> MultiExecSessionSelection?
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

public struct AppKitMultiExecPromptPresenter: MultiExecPromptPresenting {
    private let macroLibrary: MultiExecMacroLibrary

    public init(macroLibrary: MultiExecMacroLibrary = MultiExecMacroLibrary()) {
        self.macroLibrary = macroLibrary
    }

    public init(savedMacros: [MultiExecSavedMacro]) {
        self.init(macroLibrary: MultiExecMacroLibrary(macros: savedMacros))
    }

    public func promptMultiExec(targets: [MultiExecTarget], parentWindow: NSWindow?) -> MultiExecPromptRequest? {
        let alert = NSAlert()
        alert.messageText = L10n.MultiExec.title
        alert.informativeText = targets.isEmpty
            ? L10n.MultiExec.noTargets
            : L10n.MultiExec.message
        alert.addButton(withTitle: L10n.MultiExec.execute)
        alert.addButton(withTitle: L10n.Common.cancel)

        let form = MultiExecPromptForm(targets: targets, savedMacros: macroLibrary.macros)
        alert.accessoryView = form.view
        alert.buttons.first?.isEnabled = form.canSubmit
        form.onValidationChanged = { [weak alert] canSubmit in
            alert?.buttons.first?.isEnabled = canSubmit
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return form.request()
    }
}

public struct AppKitMultiExecSessionSelector: MultiExecSessionSelecting {
    public init() {}

    public func selectMultiExecTargets(targets: [MultiExecTarget], parentWindow: NSWindow?) -> MultiExecSessionSelection? {
        let alert = NSAlert()
        alert.messageText = L10n.MultiExec.title
        alert.informativeText = targets.count < 2
            ? L10n.MultiExec.requiresMultipleTargets
            : L10n.MultiExec.interactiveMessage
        alert.addButton(withTitle: L10n.MultiExec.start)
        alert.addButton(withTitle: L10n.Common.cancel)

        let form = MultiExecSessionSelectionForm(targets: targets)
        alert.accessoryView = form.view
        alert.buttons.first?.isEnabled = form.canSubmit
        form.onValidationChanged = { [weak alert] canSubmit in
            alert?.buttons.first?.isEnabled = canSubmit
        }

        let response = alert.runModal()
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
}

@MainActor
final class MultiExecSessionSelectionForm: NSObject {
    let view: NSView
    var onValidationChanged: ((Bool) -> Void)?

    private let targets: [MultiExecTarget]
    private let targetRows: [MultiExecTargetPreviewRow]
    private var targetCheckboxes: [NSButton] = []

    init(targets: [MultiExecTarget]) {
        self.targets = targets
        self.targetRows = MultiExecTargetPreviewRow.rows(for: targets)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        container.translatesAutoresizingMaskIntoConstraints = false

        let targetStack = MultiExecTargetListStackView()
        targetStack.orientation = .vertical
        targetStack.spacing = 6
        targetStack.alignment = .leading
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

        configureTargets(in: targetStack)
        refreshValidation()
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

        for target in targetRows {
            let checkbox = NSButton(
                checkboxWithTitle: target.summary,
                target: self,
                action: #selector(refreshValidation)
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(target.id)
            checkbox.state = target.isEnabled ? .on : .off
            checkbox.isEnabled = target.isEnabled
            checkbox.setAccessibilityIdentifier("Stacio.MultiExec.sessionTarget.\(target.id)")
            targetCheckboxes.append(checkbox)
            stack.addArrangedSubview(checkbox)
        }
    }

    @objc
    private func refreshValidation() {
        onValidationChanged?(canSubmit)
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
    private let savedMacros: [MultiExecSavedMacro]
    private var targetCheckboxes: [NSButton] = []

    init(targets: [MultiExecTarget], savedMacros: [MultiExecSavedMacro] = []) {
        self.targets = targets
        self.targetRows = MultiExecTargetPreviewRow.rows(for: targets)
        self.savedMacros = savedMacros

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        container.translatesAutoresizingMaskIntoConstraints = false

        let targetStack = MultiExecTargetListStackView()
        targetStack.orientation = .vertical
        targetStack.spacing = 6
        targetStack.alignment = .leading
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
        configureTargets(in: targetStack)
        refreshValidation()
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

        for target in targetRows {
            let checkbox = NSButton(
                checkboxWithTitle: target.summary,
                target: self,
                action: #selector(refreshValidation)
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(target.id)
            checkbox.state = target.isEnabled ? .on : .off
            checkbox.isEnabled = target.isEnabled
            checkbox.setAccessibilityIdentifier("Stacio.MultiExec.target.\(target.id)")
            targetCheckboxes.append(checkbox)
            stack.addArrangedSubview(checkbox)
        }
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
