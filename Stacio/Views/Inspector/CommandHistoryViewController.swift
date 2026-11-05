import AppKit

public final class CommandHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column {
        static let favorite = NSUserInterfaceItemIdentifier("Stacio.CommandHistory.favorite")
        static let time = NSUserInterfaceItemIdentifier("Stacio.CommandHistory.time")
        static let command = NSUserInterfaceItemIdentifier("Stacio.CommandHistory.command")
    }

    private static let favoritesDefaultsKey = "stacio.commandHistory.favorites"

    public let tableView = StacioDeleteKeyTableView()
    public var onPasteCommand: ((String) -> Void)?
    public var onExportError: ((String) -> Void)?
    public var onAddToFavoriteCommand: ((String) -> Void)? = { command in
        _ = TerminalFavoriteCommandStore.shared.addFromHistory(command)
    }

    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L10n.Inspector.noCommandHistory)
    private let pasteButton = NSButton()
    private let favoriteButton = NSButton(title: "添加到常用命令", target: nil, action: nil)
    private let copyButton = NSButton()
    private let sendSelectedButton = NSButton()
    private let exportButton = NSButton()
    private let favoritesToggleButton = NSButton()
    private let searchField = NSSearchField()
    private let statsLabel = NSTextField(labelWithString: "")

    private let dateFormatter: DateFormatter
    private let defaults: UserDefaults
    private let exportWriter: (String, URL) throws -> Void
    private var allEntries: [TerminalCommandHistoryEntry] = []
    private var filteredEntries: [TerminalCommandHistoryEntry] = []
    private var favorites: Set<String> = []
    private var showFavoritesOnly = false
    private var searchQuery = ""

    // MARK: - Init

    public init(
        timeZone: TimeZone = .current,
        defaults: UserDefaults = .standard,
        exportWriter: @escaping (String, URL) throws -> Void = { text, url in
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    ) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.dateFormatter = formatter
        self.defaults = defaults
        self.exportWriter = exportWriter
        super.init(nibName: nil, bundle: nil)
        title = L10n.Inspector.commandHistory
        loadFavorites()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    // MARK: - View loading

    public override func loadView() {
        let container = NSView()
        StacioDesignSystem.applyInspectorContentSurface(container)

        configureSearchField()
        configureTable()
        configurePasteButton()
        configureFavoriteButton()
        configureCopyButton()
        configureSendSelectedButton()
        configureExportButton()
        configureFavoritesToggleButton()
        configureEmptyLabel()
        configureStatsLabel()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let toolbarStack = NSStackView(views: [favoritesToggleButton, NSView(), exportButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 4
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [pasteButton, favoriteButton, sendSelectedButton, copyButton, NSView(), statsLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(toolbarStack)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            toolbarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            toolbarStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            toolbarStack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            toolbarStack.heightAnchor.constraint(equalToConstant: 24),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            pasteButton.heightAnchor.constraint(equalToConstant: 26),
            favoriteButton.heightAnchor.constraint(equalToConstant: 26),
            sendSelectedButton.heightAnchor.constraint(equalToConstant: 26),
            copyButton.heightAnchor.constraint(equalToConstant: 26)
        ])

        view = container
        applyFilter()
    }

    // MARK: - Public API (unchanged)

    public func setEntries(_ entries: [TerminalCommandHistoryEntry]) {
        self.allEntries = entries
        applyFilter()
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredEntries.count, let tableColumn else { return nil }
        let entry = filteredEntries[row]

        if tableColumn.identifier == Column.favorite {
            let identifier = NSUserInterfaceItemIdentifier("Stacio.CommandHistory.favorite.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeFavoriteCell(identifier: identifier)
            if let button = cell.viewWithTag(101) as? NSButton {
                let isFav = favorites.contains(entry.command)
                button.contentTintColor = isFav ? .systemYellow : .tertiaryLabelColor
                button.image = NSImage(systemSymbolName: isFav ? "star.fill" : "star",
                                       accessibilityDescription: isFav ? "取消收藏" : "收藏")
                button.tag = 101
                button.identifier = NSUserInterfaceItemIdentifier("fav:\(entry.id)")
                button.target = self
                button.action = #selector(toggleFavorite(_:))
            }
            return cell
        }

        let value: String
        if tableColumn.identifier == Column.time {
            value = dateFormatter.string(from: entry.usedAt)
        } else {
            value = entry.command
        }

        let identifier = NSUserInterfaceItemIdentifier("\(tableColumn.identifier.rawValue).cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTextCell(identifier: identifier, isCommand: tableColumn.identifier == Column.command)
        if let query = searchQuery.isEmpty ? nil : searchQuery,
           tableColumn.identifier == Column.command {
            cell.textField?.attributedStringValue = highlighted(value, query: query)
        } else {
            cell.textField?.stringValue = value
        }
        cell.toolTip = value
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    // MARK: - Testing helpers (backward compatible)

    public var visibleTextSnapshot: String {
        let rows = filteredEntries.flatMap { entry in
            [dateFormatter.string(from: entry.usedAt), entry.command]
        }
        let emptyText = emptyLabel.isHidden ? [] : [emptyLabel.stringValue]
        return (emptyText + [pasteButton.title, favoriteButton.title] + rows).joined(separator: "\n")
    }

    public var commandsForTesting: [String] {
        filteredEntries.map(\.command)
    }

    public var statsTextForTesting: String { statsLabel.stringValue }

    public func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        searchQuery = query
        applyFilter()
    }

    public func setFavoritesOnlyForTesting(_ enabled: Bool) {
        showFavoritesOnly = enabled
        favoritesToggleButton.contentTintColor = enabled ? .systemYellow : .secondaryLabelColor
        applyFilter()
    }

    public func toggleFavoriteForTesting(at row: Int) {
        guard filteredEntries.indices.contains(row) else { return }
        toggleFavorite(for: filteredEntries[row])
    }

    public func selectHistoryRowForTesting(_ row: Int) {
        guard row >= 0, row < filteredEntries.count else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    public func selectHistoryRowsForTesting(_ rows: IndexSet) {
        let validRows = rows.filter { filteredEntries.indices.contains($0) }
        tableView.selectRowIndexes(IndexSet(validRows), byExtendingSelection: false)
    }

    public func pasteSelectedCommandForTesting() {
        pasteSelectedCommand(nil)
    }

    public func addSelectedCommandToFavoritesForTesting() {
        addSelectedCommandToFavorites(nil)
    }

    public func doubleClickSelectedCommandForTesting() {
        pasteSelectedCommand(nil)
    }

    public func sendSelectedCommandsForTesting() {
        sendSelectedCommandsToTerminal(nil)
    }

    public func exportHistoryForTesting(to url: URL) {
        writeExport(to: url)
    }

    // MARK: - Actions

    @objc private func pasteSelectedCommand(_ sender: Any?) {
        guard let command = singleSelectedCommand() else { return }
        onPasteCommand?(command)
    }

    @objc private func addSelectedCommandToFavorites(_ sender: Any?) {
        guard let command = singleSelectedCommand() else { return }
        onAddToFavoriteCommand?(command)
    }

    @objc private func copySelectedCommands(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes
        guard rows.isEmpty == false else { return }
        let text = rows.compactMap { idx in
            idx < filteredEntries.count ? filteredEntries[idx].command : nil
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func sendSelectedCommandsToTerminal(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes
        guard rows.isEmpty == false else { return }
        let commands = rows.compactMap { idx in
            idx < filteredEntries.count ? filteredEntries[idx].command : nil
        }
        guard commands.isEmpty == false else { return }
        // Paste without an implicit return. The user can inspect the compound
        // command before executing it, and an interactive command cannot
        // consume following history entries as password/program input.
        onPasteCommand?(commands.joined(separator: "; "))
    }

    @objc private func toggleFavoritesOnly(_ sender: Any?) {
        showFavoritesOnly.toggle()
        let isOn = showFavoritesOnly
        favoritesToggleButton.contentTintColor = isOn ? .systemYellow : .secondaryLabelColor
        applyFilter()
    }

    @objc private func toggleFavorite(_ sender: NSButton) {
        guard let idStr = sender.identifier?.rawValue,
              idStr.hasPrefix("fav:"),
              let uuid = UUID(uuidString: String(idStr.dropFirst(4))),
              let entry = filteredEntries.first(where: { $0.id == uuid })
        else { return }
        toggleFavorite(for: entry)
    }

    @objc private func exportHistory(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "stacio-history-\(date).txt"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.writeExport(to: url)
        }
    }

    private func writeExport(to url: URL) {
        let text = filteredEntries.map { entry in
            "\(dateFormatter.string(from: entry.usedAt))\t\(entry.command)"
        }.joined(separator: "\n")
        do {
            try exportWriter(text, url)
        } catch {
            presentExportError(error)
        }
    }

    private func presentExportError(_ error: Error) {
        let message = "无法导出命令历史：\(error.localizedDescription)"
        if let onExportError {
            onExportError(message)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "导出失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        applyFilter()
    }

    // MARK: - Filter & stats

    private func applyFilter() {
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { row in
            filteredEntries.indices.contains(row) ? filteredEntries[row].id : nil
        })
        var result = allEntries
        if searchQuery.isEmpty == false {
            result = result.filter { $0.command.localizedCaseInsensitiveContains(searchQuery) }
        }
        if showFavoritesOnly {
            result = result.filter { favorites.contains($0.command) }
        }
        filteredEntries = result
        if isViewLoaded {
            tableView.reloadData()
            let selectedRows = IndexSet(filteredEntries.indices.filter {
                selectedIDs.contains(filteredEntries[$0].id)
            })
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            updateEmptyState()
            updateButtonStates()
            updateStatsLabel()
        }
    }

    private func updateEmptyState() {
        guard isViewLoaded else { return }
        emptyLabel.isHidden = filteredEntries.isEmpty == false
    }

    private func updateButtonStates() {
        let hasSelection = tableView.selectedRowIndexes.isEmpty == false
        let hasSingleSelection = singleSelectedCommand() != nil
        pasteButton.isEnabled = hasSingleSelection
        favoriteButton.isEnabled = hasSingleSelection
        sendSelectedButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection
    }

    private func updateStatsLabel() {
        guard isViewLoaded else { return }
        let total = allEntries.count
        let favCount = allEntries.filter { favorites.contains($0.command) }.count
        let cal = Calendar.current
        let todayCount = allEntries.filter { cal.isDateInToday($0.usedAt) }.count
        statsLabel.stringValue = "共\(total)条 | ★\(favCount) | 今日\(todayCount)"
    }

    private func singleSelectedCommand() -> String? {
        guard tableView.selectedRowIndexes.count == 1,
              let row = tableView.selectedRowIndexes.first
        else {
            return nil
        }
        guard row >= 0, row < filteredEntries.count else { return nil }
        return filteredEntries[row].command
    }

    private func toggleFavorite(for entry: TerminalCommandHistoryEntry) {
        if favorites.contains(entry.command) {
            favorites.remove(entry.command)
        } else {
            favorites.insert(entry.command)
        }
        saveFavorites()
        applyFilter()
    }

    // MARK: - Favorites persistence

    private func loadFavorites() {
        let saved = defaults.stringArray(forKey: Self.favoritesDefaultsKey) ?? []
        favorites = Set(saved)
    }

    private func saveFavorites() {
        defaults.set(Array(favorites), forKey: Self.favoritesDefaultsKey)
    }

    // MARK: - View configuration

    private func configureSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索命令…"
        searchField.setAccessibilityIdentifier("Stacio.CommandHistory.search")
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = self
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell?.action = #selector(searchFieldChanged(_:))
    }

    private func configureTable() {
        tableView.setAccessibilityIdentifier("Stacio.CommandHistory.table")
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pasteSelectedCommand(_:))
        tableView.allowsMultipleSelection = true
        tableView.deleteSelectionHandler = { [weak self] in
            guard let self, self.tableView.selectedRowIndexes.isEmpty == false else { return false }
            let selectedIDs = Set(self.tableView.selectedRowIndexes.compactMap { index in
                self.filteredEntries.indices.contains(index) ? self.filteredEntries[index].id : nil
            })
            guard selectedIDs.isEmpty == false else { return false }
            self.allEntries.removeAll { selectedIDs.contains($0.id) }
            self.applyFilter()
            return true
        }
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        StacioDesignSystem.styleTable(tableView)

        let favColumn = NSTableColumn(identifier: Column.favorite)
        favColumn.title = ""
        favColumn.width = 22
        favColumn.minWidth = 22
        favColumn.maxWidth = 22
        favColumn.resizingMask = []

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

        tableView.addTableColumn(favColumn)
        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(commandColumn)
    }

    private func configurePasteButton() {
        pasteButton.title = L10n.Inspector.pasteCommandToTerminal
        pasteButton.target = self
        pasteButton.action = #selector(pasteSelectedCommand(_:))
        pasteButton.bezelStyle = .texturedRounded
        pasteButton.image = NSImage(systemSymbolName: "arrow.turn.down.right",
                                    accessibilityDescription: L10n.Inspector.pasteCommandToTerminal)
        pasteButton.imagePosition = .imageLeading
        pasteButton.toolTip = L10n.Inspector.pasteCommandToTerminal
        pasteButton.setAccessibilityLabel(L10n.Inspector.pasteCommandToTerminal)
        pasteButton.setAccessibilityIdentifier("Stacio.CommandHistory.paste")
        pasteButton.isEnabled = false
        StacioDesignSystem.styleToolbarButton(pasteButton)
    }

    private func configureCopyButton() {
        copyButton.title = ""
        copyButton.target = self
        copyButton.action = #selector(copySelectedCommands(_:))
        copyButton.bezelStyle = .texturedRounded
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制选中命令")
        copyButton.toolTip = "复制选中命令到剪贴板"
        copyButton.setAccessibilityLabel("复制选中命令")
        copyButton.setAccessibilityIdentifier("Stacio.CommandHistory.copy")
        copyButton.isEnabled = false
        StacioDesignSystem.styleToolbarButton(copyButton)
    }

    private func configureSendSelectedButton() {
        sendSelectedButton.title = "批量发送"
        sendSelectedButton.target = self
        sendSelectedButton.action = #selector(sendSelectedCommandsToTerminal(_:))
        sendSelectedButton.bezelStyle = .texturedRounded
        sendSelectedButton.image = NSImage(
            systemSymbolName: "paperplane",
            accessibilityDescription: "批量发送到终端"
        )
        sendSelectedButton.imagePosition = .imageLeading
        sendSelectedButton.toolTip = "按列表顺序执行选中的命令"
        sendSelectedButton.setAccessibilityLabel("批量发送到终端")
        sendSelectedButton.setAccessibilityIdentifier("Stacio.CommandHistory.sendSelected")
        sendSelectedButton.isEnabled = false
        StacioDesignSystem.styleToolbarButton(sendSelectedButton)
    }

    private func configureExportButton() {
        exportButton.title = ""
        exportButton.target = self
        exportButton.action = #selector(exportHistory(_:))
        exportButton.bezelStyle = .texturedRounded
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "导出历史")
        exportButton.toolTip = "导出命令历史到文件"
        exportButton.setAccessibilityLabel("导出命令历史")
        exportButton.setAccessibilityIdentifier("Stacio.CommandHistory.export")
        StacioDesignSystem.styleToolbarButton(exportButton)
    }

    private func configureFavoritesToggleButton() {
        favoritesToggleButton.title = ""
        favoritesToggleButton.target = self
        favoritesToggleButton.action = #selector(toggleFavoritesOnly(_:))
        favoritesToggleButton.bezelStyle = .texturedRounded
        favoritesToggleButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "只显示收藏")
        favoritesToggleButton.contentTintColor = .secondaryLabelColor
        favoritesToggleButton.toolTip = "只显示收藏的命令"
        favoritesToggleButton.setAccessibilityLabel("只显示收藏")
        favoritesToggleButton.setAccessibilityIdentifier("Stacio.CommandHistory.favoritesToggle")
        StacioDesignSystem.styleToolbarButton(favoritesToggleButton)
    }

    private func configureFavoriteButton() {
        favoriteButton.target = self
        favoriteButton.action = #selector(addSelectedCommandToFavorites(_:))
        favoriteButton.bezelStyle = .texturedRounded
        favoriteButton.image = NSImage(
            systemSymbolName: "star",
            accessibilityDescription: favoriteButton.title
        )
        favoriteButton.imagePosition = .imageLeading
        favoriteButton.toolTip = favoriteButton.title
        favoriteButton.setAccessibilityLabel(favoriteButton.title)
        favoriteButton.setAccessibilityIdentifier("Stacio.CommandHistory.addFavorite")
        favoriteButton.isEnabled = false
        StacioDesignSystem.styleToolbarButton(favoriteButton)
    }

    private func configureEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("Stacio.CommandHistory.empty")
    }

    private func configureStatsLabel() {
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .systemFont(ofSize: 10)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.alignment = .right
        statsLabel.maximumNumberOfLines = 1
        statsLabel.lineBreakMode = .byTruncatingTail
    }

    // MARK: - Cell factories

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier, isCommand: Bool) -> NSTableCellView {
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

    private func makeFavoriteCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.tag = 101
        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 16),
            button.heightAnchor.constraint(equalToConstant: 16),
            button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Search highlighting

    private func highlighted(_ text: String, query: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        guard query.isEmpty == false else { return attributed }
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let nsRange = source.range(
                of: query,
                options: [.caseInsensitive],
                range: searchRange
            )
            guard nsRange.location != NSNotFound else { break }
            attributed.addAttribute(.backgroundColor,
                                    value: NSColor.systemYellow.withAlphaComponent(0.4),
                                    range: nsRange)
            attributed.addAttribute(.font,
                                    value: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                                    range: nsRange)
            let nextLocation = NSMaxRange(nsRange)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return attributed
    }
}
