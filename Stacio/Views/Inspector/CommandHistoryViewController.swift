import AppKit

public final class CommandHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column {
        static let time = NSUserInterfaceItemIdentifier("Stacio.CommandHistory.time")
        static let command = NSUserInterfaceItemIdentifier("Stacio.CommandHistory.command")
    }

    public let tableView = NSTableView()
    public var onPasteCommand: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L10n.Inspector.noCommandHistory)
    private let pasteButton = NSButton(
        title: L10n.Inspector.pasteCommandToTerminal,
        target: nil,
        action: nil
    )
    private let dateFormatter: DateFormatter
    private var entries: [TerminalCommandHistoryEntry] = []

    public init(timeZone: TimeZone = .current) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.dateFormatter = formatter
        super.init(nibName: nil, bundle: nil)
        title = L10n.Inspector.commandHistory
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        StacioDesignSystem.applyInspectorContentSurface(container)

        configureTable()
        configurePasteButton()
        configureEmptyLabel()

        let footer = NSStackView(views: [pasteButton, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            pasteButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        view = container
        updateEmptyState()
    }

    public func setEntries(_ entries: [TerminalCommandHistoryEntry]) {
        self.entries = entries
        tableView.reloadData()
        if tableView.selectedRow >= entries.count {
            tableView.deselectAll(nil)
        }
        updateEmptyState()
        updatePasteButtonState()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0,
              row < entries.count,
              let tableColumn
        else {
            return nil
        }

        let value: String
        if tableColumn.identifier == Column.time {
            value = dateFormatter.string(from: entries[row].usedAt)
        } else {
            value = entries[row].command
        }

        let identifier = NSUserInterfaceItemIdentifier("\(tableColumn.identifier.rawValue).cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier, isCommand: tableColumn.identifier == Column.command)
        cell.textField?.stringValue = value
        cell.toolTip = value
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updatePasteButtonState()
    }

    public var visibleTextSnapshot: String {
        let rows = entries.flatMap { entry in
            [dateFormatter.string(from: entry.usedAt), entry.command]
        }
        let emptyText = emptyLabel.isHidden ? [] : [emptyLabel.stringValue]
        return (emptyText + [pasteButton.title] + rows).joined(separator: "\n")
    }

    public var commandsForTesting: [String] {
        entries.map(\.command)
    }

    public func selectHistoryRowForTesting(_ row: Int) {
        guard row >= 0,
              row < entries.count
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    public func pasteSelectedCommandForTesting() {
        pasteSelectedCommand(nil)
    }

    public func doubleClickSelectedCommandForTesting() {
        doubleClickCommand(nil)
    }

    private func configureTable() {
        tableView.setAccessibilityIdentifier("Stacio.CommandHistory.table")
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickCommand(_:))
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        StacioDesignSystem.styleTable(tableView)

        let timeColumn = NSTableColumn(identifier: Column.time)
        timeColumn.title = L10n.Inspector.commandHistoryTime
        timeColumn.width = 138
        timeColumn.minWidth = 120
        timeColumn.maxWidth = 170

        let commandColumn = NSTableColumn(identifier: Column.command)
        commandColumn.title = L10n.Inspector.commandHistoryCommand
        commandColumn.width = 220
        commandColumn.minWidth = 140
        commandColumn.resizingMask = .autoresizingMask

        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(commandColumn)
    }

    private func configurePasteButton() {
        pasteButton.target = self
        pasteButton.action = #selector(pasteSelectedCommand(_:))
        pasteButton.bezelStyle = .texturedRounded
        pasteButton.image = NSImage(
            systemSymbolName: "arrow.turn.down.right",
            accessibilityDescription: L10n.Inspector.pasteCommandToTerminal
        )
        pasteButton.imagePosition = .imageLeading
        pasteButton.toolTip = L10n.Inspector.pasteCommandToTerminal
        pasteButton.setAccessibilityLabel(L10n.Inspector.pasteCommandToTerminal)
        pasteButton.setAccessibilityIdentifier("Stacio.CommandHistory.paste")
        pasteButton.isEnabled = false
        StacioDesignSystem.styleToolbarButton(pasteButton)
    }

    private func configureEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("Stacio.CommandHistory.empty")
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, isCommand: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.font = isCommand
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = isCommand ? .labelColor : .secondaryLabelColor
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func updateEmptyState() {
        guard isViewLoaded else { return }
        emptyLabel.isHidden = entries.isEmpty == false
    }

    private func updatePasteButtonState() {
        pasteButton.isEnabled = selectedCommand() != nil
    }

    private func selectedCommand() -> String? {
        let row = tableView.selectedRow
        guard row >= 0,
              row < entries.count
        else {
            return nil
        }
        return entries[row].command
    }

    @objc
    private func pasteSelectedCommand(_ sender: Any?) {
        guard let command = selectedCommand() else {
            return
        }
        onPasteCommand?(command)
    }

    @objc
    private func doubleClickCommand(_ sender: Any?) {
        pasteSelectedCommand(sender)
    }
}
