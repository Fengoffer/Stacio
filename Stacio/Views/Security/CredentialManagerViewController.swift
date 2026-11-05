import AppKit
import Foundation
import StacioCoreBindings

internal typealias CredentialManagerTaskExecutor = (@escaping () -> Void) -> Void

private final class UncheckedCredentialManagerOperationBox: @unchecked Sendable {
    let operation: () -> Void

    init(_ operation: @escaping () -> Void) {
        self.operation = operation
    }
}

private struct CredentialManagerLoadResult {
    let credentials: [CredentialRecord]
    let creationDates: [String: Date]
    let metadataErrorMessage: String?
}

@MainActor
public final class CredentialManagerViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private static let createdAtDefaultsKey = "stacio.credentialCenter.createdAt"

    private let store: CredentialCenterManaging
    private let secretReader: (CredentialRecord) throws -> String
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let clipboardClearDelay: TimeInterval
    private let backgroundExecutor: CredentialManagerTaskExecutor
    private let mainExecutor: CredentialManagerTaskExecutor

    private let searchField = NSSearchField()
    private let tableView = CredentialManagerTableView()
    private let addButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var credentials: [CredentialRecord] = []
    private var filteredCredentials: [CredentialRecord] = []
    private var createdAt: [String: Date] = [:]
    private var clipboardClearWorkItem: DispatchWorkItem?
    private var clipboardWriteChangeCount: Int?
    private var activeSheetController: NewCredentialSheetController?
    private var reloadRequestID = UUID()
    private var copyRequestID: UUID?

    init(
        store: CredentialCenterManaging,
        secretReader: @escaping (CredentialRecord) throws -> String = { record in
            try KeychainCredentialStore().readSecret(
                id: record.id,
                account: record.keychainAccount
            )
        },
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        clipboardClearDelay: TimeInterval = 5,
        backgroundExecutor: @escaping CredentialManagerTaskExecutor = { operation in
            let box = UncheckedCredentialManagerOperationBox(operation)
            DispatchQueue.global(qos: .userInitiated).async {
                box.operation()
            }
        },
        mainExecutor: @escaping CredentialManagerTaskExecutor = { operation in
            if Thread.isMainThread {
                operation()
            } else {
                let box = UncheckedCredentialManagerOperationBox(operation)
                DispatchQueue.main.async {
                    box.operation()
                }
            }
        }
    ) {
        self.store = store
        self.secretReader = secretReader
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.clipboardClearDelay = clipboardClearDelay
        self.backgroundExecutor = backgroundExecutor
        self.mainExecutor = mainExecutor
        super.init(nibName: nil, bundle: nil)
        createdAt = Self.loadCreatedAt(defaults: defaults)
    }

    public static func makeDefault() -> CredentialManagerViewController? {
        guard let store = CoreBridgeCredentialCenterStore.defaultStore() else { return nil }
        return CredentialManagerViewController(store: store)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(root)

        searchField.placeholderString = "搜索凭证"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("Stacio.Credentials.search")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = ""
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建凭证")
        addButton.toolTip = "新建凭证"
        addButton.setAccessibilityLabel("新建凭证")
        addButton.setAccessibilityIdentifier("Stacio.Credentials.add")
        addButton.target = self
        addButton.action = #selector(addCredential(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(addButton)

        for (identifier, title, width) in [
            ("kind", "类型", 110.0),
            ("label", "标签", 180.0),
            ("account", "账号", 200.0),
            ("createdAt", "创建时间", 150.0),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = 80
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.deleteSelectionHandler = { [weak self] in
            guard let self, self.tableView.selectedRowIndexes.isEmpty == false else { return false }
            self.deleteSelectedCredentials()
            return true
        }
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.setAccessibilityIdentifier("Stacio.Credentials.table")
        tableView.menu = makeContextMenu()
        StacioDesignSystem.styleTable(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(addButton)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 26),
            addButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 26),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),
        ])
        view = root
        // Keep SQLite and metadata reads off the main thread. The window can
        // present with an empty table briefly, then applies only the newest
        // request result.
        reloadCredentials()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        copyRequestID = nil
        clipboardClearWorkItem?.cancel()
        clipboardClearWorkItem = nil
        if let clipboardWriteChangeCount,
           pasteboard.changeCount == clipboardWriteChangeCount {
            pasteboard.clearContents()
        }
        self.clipboardWriteChangeCount = nil
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { filteredCredentials.count }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, filteredCredentials.indices.contains(row) else { return nil }
        let record = filteredCredentials[row]
        let value: String
        switch tableColumn.identifier.rawValue {
        case "kind": value = record.kind
        case "label": value = record.label
        case "account": value = record.keychainAccount
        case "createdAt": value = createdAt[record.id].map(Self.dateFormatter.string(from:)) ?? "未知"
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public var visibleCredentialsForTesting: [CredentialRecord] { filteredCredentials }

    public func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        applyFilter()
    }

    public func selectCredentialForTesting(id: String) {
        guard let row = filteredCredentials.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    public func copySelectedSecretForTesting() {
        copySelectedSecret(nil)
    }

    public func deleteSelectedCredentialForTesting() {
        guard let record = selectedCredential else { return }
        do {
            try store.deleteCredential(id: record.id)
            createdAt.removeValue(forKey: record.id)
            saveCreatedAt()
            reloadCredentialsSynchronously()
        } catch {
            statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
    }

    public func saveCredentialForTesting(
        kind: String,
        label: String,
        account: String,
        secret: String
    ) {
        do {
            _ = try store.saveCredential(
                kind: kind,
                label: label,
                account: account,
                secret: secret
            )
            reloadCredentialsSynchronously()
        } catch {
            statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
    }

    public func reloadCredentialsForPresentation() {
        guard isViewLoaded else { return }
        reloadCredentials()
    }

    @objc private func searchChanged(_ sender: NSSearchField) { applyFilter() }

    @objc private func addCredential(_ sender: Any?) {
        guard let parentWindow = view.window else { return }
        let sheet = NewCredentialSheetController()
        activeSheetController = sheet
        parentWindow.beginSheet(sheet.window!) { [weak self] response in
            guard let self else { return }
            defer { self.activeSheetController = nil }
            guard response == .OK, let sheet = self.activeSheetController else { return }
            self.saveCredential(
                kind: sheet.kind,
                label: sheet.label,
                account: sheet.account,
                secret: sheet.secret
            )
        }
    }

    @objc private func copySelectedSecret(_ sender: Any?) {
        guard let record = selectedCredential else { return }
        let requestID = UUID()
        copyRequestID = requestID
        let reader = secretReader
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result { try reader(record) }
            mainExecutor { [weak self] in
                guard let self, self.copyRequestID == requestID else { return }
                self.copyRequestID = nil
                self.finishCopySecret(result)
            }
        }
    }

    @objc private func deleteSelectedCredential(_ sender: Any?) {
        deleteSelectedCredentials()
    }

    private func deleteSelectedCredentials() {
        let records = tableView.selectedRowIndexes.compactMap { index -> CredentialRecord? in
            filteredCredentials.indices.contains(index) ? filteredCredentials[index] : nil
        }
        guard records.isEmpty == false else { return }
        requestDeletionConfirmation(for: records) { [weak self] in
            guard let self else { return }
            let store = self.store
            let mainExecutor = self.mainExecutor
            self.backgroundExecutor { [weak self] in
                let result = Result {
                    for record in records {
                        try store.deleteCredential(id: record.id)
                    }
                }
                mainExecutor { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success:
                        records.forEach { self.createdAt.removeValue(forKey: $0.id) }
                        self.saveCreatedAt()
                        self.reloadCredentials()
                    case let .failure(error):
                        self.statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
                    }
                }
            }
        }
    }

    private func requestDeletionConfirmation(
        for records: [CredentialRecord],
        confirmed: @escaping () -> Void
    ) {
        // Unit-test controllers are intentionally windowless. The real window
        // always uses the confirmation sheet before the destructive operation.
        guard let window = view.window else {
            confirmed()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if records.count == 1, let record = records.first {
            alert.messageText = "删除凭证“\(record.label)”？"
        } else {
            alert.messageText = "删除所选的 \(records.count) 个凭证？"
        }
        alert.informativeText = "删除后将无法恢复对应的密钥。仍要继续吗？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            confirmed()
        }
    }

    private func saveCredential(kind: String, label: String, account: String, secret: String) {
        let store = self.store
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                try store.saveCredential(
                    kind: kind,
                    label: label,
                    account: account,
                    secret: secret
                )
            }
            mainExecutor { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.reloadCredentials()
                case let .failure(error):
                    self.statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
                }
            }
        }
    }

    private func finishCopySecret(_ result: Result<String, Error>) {
        do {
            let secret = try result.get()
            pasteboard.clearContents()
            pasteboard.setString(secret, forType: .string)
            let changeCount = pasteboard.changeCount
            clipboardWriteChangeCount = changeCount
            clipboardClearWorkItem?.cancel()
            let clipboard = pasteboard
            let workItem = DispatchWorkItem {
                guard clipboard.changeCount == changeCount else { return }
                clipboard.clearContents()
            }
            clipboardClearWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + clipboardClearDelay,
                execute: workItem
            )
            statusLabel.stringValue = "密钥已复制，5 秒后清空"
        } catch {
            statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
    }

    private var selectedCredential: CredentialRecord? {
        let clickedRow = tableView.clickedRow
        let row = clickedRow >= 0 && tableView.selectedRowIndexes.contains(clickedRow)
            ? clickedRow
            : tableView.selectedRow
        guard filteredCredentials.indices.contains(row) else { return nil }
        return filteredCredentials[row]
    }

    private func reloadCredentials() {
        let requestID = UUID()
        reloadRequestID = requestID
        let store = self.store
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                let records = try store.listCredentials()
                let dates: [String: Date]
                let metadataErrorMessage: String?
                do {
                    dates = try store.credentialCreationDates()
                    metadataErrorMessage = nil
                } catch {
                    dates = [:]
                    metadataErrorMessage = RuntimeDiagnosticFormatter.userMessage(for: error)
                }
                return CredentialManagerLoadResult(
                    credentials: records,
                    creationDates: dates,
                    metadataErrorMessage: metadataErrorMessage
                )
            }
            mainExecutor { [weak self] in
                guard let self, self.reloadRequestID == requestID else { return }
                self.applyLoadResult(result)
            }
        }
    }

    private func reloadCredentialsSynchronously() {
        reloadRequestID = UUID()
        do {
            let records = try store.listCredentials()
            let dates: [String: Date]
            let metadataErrorMessage: String?
            do {
                dates = try store.credentialCreationDates()
                metadataErrorMessage = nil
            } catch {
                dates = [:]
                metadataErrorMessage = RuntimeDiagnosticFormatter.userMessage(for: error)
            }
            applyLoadResult(.success(CredentialManagerLoadResult(
                credentials: records,
                creationDates: dates,
                metadataErrorMessage: metadataErrorMessage
            )))
        } catch {
            applyLoadResult(.failure(error))
        }
    }

    private func applyLoadResult(_ result: Result<CredentialManagerLoadResult, Error>) {
        do {
            let loaded = try result.get()
            credentials = loaded.credentials
            createdAt.merge(loaded.creationDates) { _, databaseDate in databaseDate }
            let credentialIDs = Set(credentials.map(\.id))
            createdAt = createdAt.filter { credentialIDs.contains($0.key) }
            saveCreatedAt()
            applyFilter()
            statusLabel.stringValue = loaded.metadataErrorMessage.map {
                "凭证已加载，但创建时间读取失败：\($0)"
            } ?? "\(credentials.count) 个凭证"
        } catch {
            credentials = []
            applyFilter()
            statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredCredentials = query.isEmpty ? credentials : credentials.filter { record in
            [record.kind, record.label, record.keychainAccount].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.deselectAll(nil)
        tableView.reloadData()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "凭证")
        let copy = NSMenuItem(title: "复制密钥", action: #selector(copySelectedSecret(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "删除", action: #selector(deleteSelectedCredential(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    private func saveCreatedAt() {
        defaults.set(
            createdAt.mapValues { ISO8601DateFormatter().string(from: $0) },
            forKey: Self.createdAtDefaultsKey
        )
    }

    private static func loadCreatedAt(defaults: UserDefaults) -> [String: Date] {
        let raw = defaults.dictionary(forKey: createdAtDefaultsKey) as? [String: String] ?? [:]
        let formatter = ISO8601DateFormatter()
        return raw.reduce(into: [:]) { result, item in
            result[item.key] = formatter.date(from: item.value)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private final class CredentialManagerTableView: NSTableView {
    var deleteSelectionHandler: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117),
           deleteSelectionHandler?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow < 0 {
            deselectAll(nil)
            return nil
        } else if selectedRowIndexes.contains(clickedRow) == false {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

@MainActor
private final class NewCredentialSheetController: NSWindowController {
    private let labelField = NSTextField()
    private let accountField = NSTextField()
    private let secretField = NSSecureTextField()

    let kind = "password"
    var label: String { labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var account: String { accountField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var secret: String { secretField.stringValue }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.title = "新建凭证"
        let content = NSView()
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "标签"), labelField],
            [NSTextField(labelWithString: "账号"), accountField],
            [NSTextField(labelWithString: "密码/密钥"), secretField],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        let save = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, save])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(form)
        content.addSubview(actions)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            actions.topAnchor.constraint(greaterThanOrEqualTo: form.bottomAnchor, constant: 16),
        ])
        panel.contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func cancel(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: .cancel)
    }

    @objc private func save(_ sender: Any?) {
        guard label.isEmpty == false, account.isEmpty == false, secret.isEmpty == false,
              let window, let parent = window.sheetParent
        else { return }
        parent.endSheet(window, returnCode: .OK)
    }
}

@MainActor
public final class CredentialManagerWindowController: NSWindowController {
    private let credentialViewController: CredentialManagerViewController

    public init(viewController: CredentialManagerViewController) {
        credentialViewController = viewController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "凭证中心"
        window.minSize = NSSize(width: 620, height: 340)
        window.contentViewController = viewController
        super.init(window: window)
        window.delegate = self
    }

    public static func makeDefault() -> CredentialManagerWindowController? {
        guard let viewController = CredentialManagerViewController.makeDefault() else {
            return nil
        }
        return CredentialManagerWindowController(viewController: viewController)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }
}

extension CredentialManagerWindowController: NSWindowDelegate {
    public func windowDidBecomeKey(_ notification: Notification) {
        credentialViewController.reloadCredentialsForPresentation()
    }
}
