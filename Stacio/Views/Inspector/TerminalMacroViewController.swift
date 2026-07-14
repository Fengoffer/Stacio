import AppKit
import StacioCoreBindings
import UniformTypeIdentifiers

public protocol TerminalMacroRunPreviewPresenting: AnyObject {
    func presentRunPreview(
        for macro: TerminalMacroRecord,
        relativeTo rect: NSRect,
        of view: NSView,
        onConfirm: @escaping () -> Void
    )
}

public final class TerminalMacroViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("Stacio.TerminalMacro.name")
        static let group = NSUserInterfaceItemIdentifier("Stacio.TerminalMacro.group")
        static let commandCount = NSUserInterfaceItemIdentifier("Stacio.TerminalMacro.commandCount")
        static let updated = NSUserInterfaceItemIdentifier("Stacio.TerminalMacro.updated")
    }

    private enum GroupFilter: Equatable {
        case all
        case ungrouped
        case group(String)
    }

    public static let runPreviewConfirmationDefaultsKey = "Stacio.TerminalMacro.runPreviewConfirmationEnabled"

    public let tableView = NSTableView()
    public var onRefreshMacros: (() -> [TerminalMacroRecord])?
    public var onStartRecording: (() -> Bool)?
    public var onStopRecording: ((String) -> Void)?
    public var onPlayMacro: ((TerminalMacroRecord) -> Void)?
    public var onRenameMacro: ((TerminalMacroRecord, String) -> Void)?
    public var onDeleteMacro: ((TerminalMacroRecord) -> Void)?
    public var namePromptProvider: ((String, String) -> String?)?
    public var groupPromptProvider: ((TerminalMacroRecord, String?) -> String?)?

    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L10n.TerminalMacro.empty)
    private let groupPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let startButton = NSButton(title: L10n.TerminalMacro.startRecording, target: nil, action: nil)
    private let stopButton = NSButton(title: L10n.TerminalMacro.stopRecording, target: nil, action: nil)
    private let playButton = NSButton(title: L10n.TerminalMacro.play, target: nil, action: nil)
    private let renameButton = NSButton(title: L10n.TerminalMacro.rename, target: nil, action: nil)
    private let groupButton = NSButton(title: "分组", target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.TerminalMacro.delete, target: nil, action: nil)
    private let refreshButton = NSButton(title: L10n.TerminalMacro.refresh, target: nil, action: nil)
    private let importButton = NSButton(title: "导入", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出", target: nil, action: nil)
    private let runPreviewConfirmationCheckbox = NSButton(
        checkboxWithTitle: "运行前确认",
        target: nil,
        action: nil
    )
    private let dateFormatter: DateFormatter
    private let metadataStore: TerminalMacroMetadataStoring
    private let macroStore: TerminalMacroStoring?
    private let userDefaults: UserDefaults
    private let runPreviewPresenter: TerminalMacroRunPreviewPresenting
    private var allMacros: [TerminalMacroRecord] = []
    private var macros: [TerminalMacroRecord] = []
    private var metadataByMacroID: [String: TerminalMacroMetadata] = [:]
    private var groupFilter: GroupFilter = .all
    private var isRecording = false

    public init(
        timeZone: TimeZone = .current,
        metadataStore: TerminalMacroMetadataStoring? = try? SQLiteTerminalMacroMetadataStore.defaultStore(),
        macroStore: TerminalMacroStoring? = CoreBridgeTerminalMacroStore.defaultStore(),
        userDefaults: UserDefaults = .standard,
        runPreviewPresenter: TerminalMacroRunPreviewPresenting = PopoverTerminalMacroRunPreviewPresenter()
    ) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        self.dateFormatter = formatter
        self.metadataStore = metadataStore ?? EmptyTerminalMacroMetadataStore()
        self.macroStore = macroStore
        self.userDefaults = userDefaults
        self.runPreviewPresenter = runPreviewPresenter
        super.init(nibName: nil, bundle: nil)
        title = L10n.TerminalMacro.title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        StacioDesignSystem.applyInspectorContentSurface(container)

        configureTable()
        configureFilters()
        configureButtons()
        configureRunPreviewConfirmation()
        configureEmptyLabel()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let filterRow = NSStackView(views: [groupPopup, searchField])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 8
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let recordingRow = NSStackView(views: [startButton, stopButton, NSView()])
        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = 8

        let actionRow = NSStackView(views: [
            playButton,
            renameButton,
            groupButton,
            deleteButton,
            refreshButton,
            NSView()
        ])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let importExportRow = NSStackView(views: [importButton, exportButton, NSView()])
        importExportRow.orientation = .horizontal
        importExportRow.alignment = .centerY
        importExportRow.spacing = 8

        let settingsRow = NSStackView(views: [runPreviewConfirmationCheckbox, NSView()])
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.spacing = 8

        let footer = NSStackView(views: [recordingRow, actionRow, importExportRow, settingsRow])
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(filterRow)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            filterRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            filterRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            filterRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            groupPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        view = container
        reloadMacrosFromProvider()
        updateControlState()
    }

    public func setMacros(_ macros: [TerminalMacroRecord]) {
        let selectedID = selectedMacro()?.id
        allMacros = macros
        refreshMetadataCache()
        rebuildGroupPopup()
        applyFilters(preservingMacroID: selectedID)
    }

    public func setRecording(_ isRecording: Bool) {
        self.isRecording = isRecording
        updateControlState()
    }

    public func reloadMacrosFromProvider() {
        setMacros(onRefreshMacros?() ?? allMacros)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        macros.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0,
              row < macros.count,
              let tableColumn
        else {
            return nil
        }

        let macro = macros[row]
        let value: String
        switch tableColumn.identifier {
        case Column.group:
            value = groupDisplayName(for: macro)
        case Column.commandCount:
            value = L10n.TerminalMacro.commandCount(macro.steps.count)
        case Column.updated:
            value = formattedDate(macro.updatedAt)
        default:
            value = macro.name
        }

        let identifier = NSUserInterfaceItemIdentifier("\(tableColumn.identifier.rawValue).cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier, isName: tableColumn.identifier == Column.name)
        cell.textField?.stringValue = value
        cell.toolTip = value
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateControlState()
    }

    public var macroNamesForTesting: [String] {
        macros.map(\.name)
    }

    public var groupTitlesForTesting: [String] {
        groupPopup.itemTitles
    }

    public func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        applyFilters()
    }

    public func selectGroupForTesting(_ group: String?) {
        if let group {
            groupFilter = .group(group)
        } else {
            groupFilter = .all
        }
        rebuildGroupPopup()
        applyFilters()
    }

    public func playSelectedMacroForTesting() {
        playSelectedMacro(nil)
    }

    public func selectMacroRowForTesting(_ row: Int) {
        guard row >= 0,
              row < macros.count
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func configureTable() {
        tableView.setAccessibilityIdentifier("Stacio.TerminalMacro.table")
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(playSelectedMacro(_:))
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        StacioDesignSystem.styleTable(tableView)

        let nameColumn = NSTableColumn(identifier: Column.name)
        nameColumn.title = L10n.TerminalMacro.nameColumn
        nameColumn.width = 120
        nameColumn.minWidth = 80
        nameColumn.resizingMask = .autoresizingMask

        let groupColumn = NSTableColumn(identifier: Column.group)
        groupColumn.title = "分组"
        groupColumn.width = 64
        groupColumn.minWidth = 52
        groupColumn.maxWidth = 90

        let countColumn = NSTableColumn(identifier: Column.commandCount)
        countColumn.title = L10n.TerminalMacro.commandCountColumn
        countColumn.width = 52
        countColumn.minWidth = 44
        countColumn.maxWidth = 70

        let updatedColumn = NSTableColumn(identifier: Column.updated)
        updatedColumn.title = L10n.TerminalMacro.updatedColumn
        updatedColumn.width = 104
        updatedColumn.minWidth = 92
        updatedColumn.maxWidth = 140

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(groupColumn)
        tableView.addTableColumn(countColumn)
        tableView.addTableColumn(updatedColumn)
    }

    private func configureFilters() {
        groupPopup.target = self
        groupPopup.action = #selector(groupPopupChanged(_:))
        groupPopup.setAccessibilityIdentifier("Stacio.TerminalMacro.groupFilter")
        StacioDesignSystem.stylePopupButton(groupPopup)

        searchField.placeholderString = "搜索宏或命令"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("Stacio.TerminalMacro.search")
        StacioDesignSystem.styleSearchField(searchField)
        rebuildGroupPopup()
    }

    private func configureButtons() {
        configureButton(startButton, symbolName: "record.circle", action: #selector(startRecording(_:)))
        configureButton(stopButton, symbolName: "stop.circle", action: #selector(stopRecording(_:)))
        configureButton(playButton, symbolName: "play.fill", action: #selector(playSelectedMacro(_:)))
        configureButton(renameButton, symbolName: "pencil", action: #selector(renameSelectedMacro(_:)))
        configureButton(groupButton, symbolName: "tag", action: #selector(assignGroupToSelectedMacro(_:)))
        configureButton(deleteButton, symbolName: "trash", action: #selector(deleteSelectedMacro(_:)))
        configureButton(refreshButton, symbolName: "arrow.clockwise", action: #selector(refreshMacros(_:)))
        configureButton(importButton, symbolName: "square.and.arrow.down", action: #selector(importMacros(_:)))
        configureButton(exportButton, symbolName: "square.and.arrow.up", action: #selector(exportMacros(_:)))
    }

    private func configureButton(_ button: NSButton, symbolName: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.toolTip = button.title
        button.setAccessibilityLabel(button.title)
        button.setAccessibilityIdentifier("Stacio.TerminalMacro.\(button.title)")
        StacioDesignSystem.styleToolbarButton(button)
    }

    private func configureRunPreviewConfirmation() {
        runPreviewConfirmationCheckbox.target = self
        runPreviewConfirmationCheckbox.action = #selector(runPreviewConfirmationChanged(_:))
        runPreviewConfirmationCheckbox.state = isRunPreviewConfirmationEnabled ? .on : .off
        runPreviewConfirmationCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        runPreviewConfirmationCheckbox.setAccessibilityIdentifier("Stacio.TerminalMacro.runPreviewConfirmation")
    }

    private func configureEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("Stacio.TerminalMacro.empty")
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, isName: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.font = isName
            ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = isName
            ? StacioDesignSystem.theme.primaryTextColor
            : StacioDesignSystem.theme.secondaryTextColor
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func selectedMacro() -> TerminalMacroRecord? {
        let row = tableView.selectedRow
        guard row >= 0,
              row < macros.count
        else {
            return nil
        }
        return macros[row]
    }

    private func selectedExportMacros() -> [TerminalMacroRecord] {
        if let selected = selectedMacro() {
            return [selected]
        }
        return allMacros
    }

    private func updateControlState() {
        guard isViewLoaded else { return }
        let hasSelection = selectedMacro() != nil
        startButton.isEnabled = isRecording == false
        stopButton.isEnabled = isRecording
        playButton.isEnabled = hasSelection && isRecording == false
        renameButton.isEnabled = hasSelection
        groupButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        importButton.isEnabled = macroStore != nil
        exportButton.isEnabled = allMacros.isEmpty == false
        emptyLabel.isHidden = macros.isEmpty == false
    }

    private func promptName(title: String, defaultName: String) -> String? {
        if let namePromptProvider {
            return namePromptProvider(title, defaultName)
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.Common.save)
        alert.addButton(withTitle: L10n.Common.cancel)
        let field = NSTextField(string: defaultName)
        field.placeholderString = L10n.TerminalMacro.macroNamePlaceholder
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.TerminalMacro.defaultMacroName : trimmed
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            return value
        }
        return dateFormatter.string(from: date)
    }

    private var isRunPreviewConfirmationEnabled: Bool {
        guard userDefaults.object(forKey: Self.runPreviewConfirmationDefaultsKey) != nil else {
            return true
        }
        return userDefaults.bool(forKey: Self.runPreviewConfirmationDefaultsKey)
    }

    private func refreshMetadataCache() {
        metadataByMacroID = Dictionary(
            uniqueKeysWithValues: allMacros.map { macro in
                let metadata = (try? metadataStore.metadata(forMacroID: macro.id)) ?? TerminalMacroMetadata()
                return (macro.id, metadata)
            }
        )
    }

    private func rebuildGroupPopup() {
        let existingGroups = Set(metadataByMacroID.values.compactMap(\.group))
        let sortedGroups = existingGroups.sorted {
            $0.compare(
                $1,
                options: [.caseInsensitive, .numeric],
                locale: Locale(identifier: "zh_Hans_CN")
            ) == .orderedAscending
        }
        groupPopup.removeAllItems()
        groupPopup.addItem(withTitle: "全部分组")
        groupPopup.addItem(withTitle: "未分组")
        for group in sortedGroups {
            groupPopup.addItem(withTitle: group)
        }

        switch groupFilter {
        case .all:
            groupPopup.selectItem(at: 0)
        case .ungrouped:
            groupPopup.selectItem(at: 1)
        case .group(let group):
            if let index = groupPopup.itemTitles.firstIndex(of: group) {
                groupPopup.selectItem(at: index)
            } else {
                groupFilter = .all
                groupPopup.selectItem(at: 0)
            }
        }
    }

    private func applyFilters(preservingMacroID macroID: String? = nil) {
        let selectedID = macroID ?? selectedMacro()?.id
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        macros = allMacros.filter { macro in
            matchesGroupFilter(macro) && matchesSearch(query, macro: macro)
        }
        tableView.reloadData()
        if let selectedID,
           let row = macros.firstIndex(where: { $0.id == selectedID })
        {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateControlState()
    }

    private func matchesGroupFilter(_ macro: TerminalMacroRecord) -> Bool {
        switch groupFilter {
        case .all:
            return true
        case .ungrouped:
            return group(for: macro) == nil
        case .group(let group):
            return self.group(for: macro) == group
        }
    }

    private func matchesSearch(_ query: String, macro: TerminalMacroRecord) -> Bool {
        guard query.isEmpty == false else { return true }
        if macro.name.localizedCaseInsensitiveContains(query) {
            return true
        }
        return macro.steps.contains { step in
            step.input.localizedCaseInsensitiveContains(query)
        }
    }

    private func group(for macro: TerminalMacroRecord) -> String? {
        metadataByMacroID[macro.id]?.group
    }

    private func groupDisplayName(for macro: TerminalMacroRecord) -> String {
        group(for: macro) ?? "未分组"
    }

    private func promptGroup(for macro: TerminalMacroRecord) -> String? {
        if let groupPromptProvider {
            return groupPromptProvider(macro, group(for: macro))
        }
        let alert = NSAlert()
        alert.messageText = "设置宏分组"
        alert.informativeText = "留空则清除分组。"
        alert.addButton(withTitle: L10n.Common.save)
        alert.addButton(withTitle: L10n.Common.cancel)
        let field = NSTextField(string: group(for: macro) ?? "")
        field.placeholderString = "分组，如 部署、监控、日常"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue
    }

    private func makeImportExportCoordinator() -> TerminalMacroImportExportCoordinator? {
        guard let macroStore else { return nil }
        return TerminalMacroImportExportCoordinator(
            macroStore: macroStore,
            metadataStore: metadataStore
        )
    }

    private func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "stacio-macros-\(formatter.string(from: Date())).json"
    }

    private func promptImportConflict(item: TerminalMacroJSONItem, existing: TerminalMacroRecord) -> TerminalMacroImportConflictPolicy {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "宏名称重复"
        alert.informativeText = "已存在名为「\(existing.name)」的宏，请选择如何处理导入项。"
        alert.addButton(withTitle: "跳过")
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "重命名")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return .overwrite
        case .alertThirdButtonReturn:
            return .rename
        default:
            _ = item
            return .skip
        }
    }

    private func presentMacroManagementMessage(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.Common.ok)
        _ = alert.runModal()
    }

    private func presentMacroManagementError(_ error: Error) {
        presentMacroManagementMessage(
            title: L10n.TerminalMacro.title,
            message: RuntimeDiagnosticFormatter.userMessage(for: error),
            style: .warning
        )
    }

    @objc
    private func startRecording(_ sender: Any?) {
        guard onStartRecording?() == true else {
            return
        }
        setRecording(true)
    }

    @objc
    private func stopRecording(_ sender: Any?) {
        guard let name = promptName(
            title: L10n.TerminalMacro.saveRecordingTitle,
            defaultName: L10n.TerminalMacro.defaultMacroName
        ) else { return }
        onStopRecording?(name)
        setRecording(false)
        reloadMacrosFromProvider()
    }

    @objc
    private func playSelectedMacro(_ sender: Any?) {
        guard let macro = selectedMacro() else { return }
        guard isRunPreviewConfirmationEnabled else {
            onPlayMacro?(macro)
            return
        }
        runPreviewPresenter.presentRunPreview(
            for: macro,
            relativeTo: playButton.bounds,
            of: playButton
        ) { [weak self] in
            self?.onPlayMacro?(macro)
        }
    }

    @objc
    private func renameSelectedMacro(_ sender: Any?) {
        guard let macro = selectedMacro(),
              let name = promptName(title: L10n.TerminalMacro.rename, defaultName: macro.name)
        else { return }
        onRenameMacro?(macro, name)
        reloadMacrosFromProvider()
    }

    @objc
    private func assignGroupToSelectedMacro(_ sender: Any?) {
        guard let macro = selectedMacro(),
              let group = promptGroup(for: macro)
        else { return }
        do {
            try metadataStore.setMetadata(
                TerminalMacroMetadata(group: group),
                forMacroID: macro.id
            )
            reloadMacrosFromProvider()
        } catch {
            presentMacroManagementError(error)
        }
    }

    @objc
    private func deleteSelectedMacro(_ sender: Any?) {
        guard let macro = selectedMacro() else { return }
        onDeleteMacro?(macro)
        reloadMacrosFromProvider()
    }

    @objc
    private func refreshMacros(_ sender: Any?) {
        reloadMacrosFromProvider()
    }

    @objc
    private func importMacros(_ sender: Any?) {
        guard let coordinator = makeImportExportCoordinator() else {
            presentMacroManagementMessage(
                title: L10n.TerminalMacro.storageUnavailableTitle,
                message: L10n.TerminalMacro.storageUnavailableMessage,
                style: .warning
            )
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK,
              let url = panel.url
        else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try coordinator.importData(data) { [weak self] item, existing in
                self?.promptImportConflict(item: item, existing: existing) ?? .skip
            }
            reloadMacrosFromProvider()
            presentMacroManagementMessage(
                title: "宏导入完成",
                message: "新增 \(result.createdCount) 个，覆盖 \(result.overwrittenCount) 个，跳过 \(result.skippedCount) 个。"
            )
        } catch {
            presentMacroManagementError(error)
        }
    }

    @objc
    private func exportMacros(_ sender: Any?) {
        guard let coordinator = makeImportExportCoordinator() else {
            presentMacroManagementMessage(
                title: L10n.TerminalMacro.storageUnavailableTitle,
                message: L10n.TerminalMacro.storageUnavailableMessage,
                style: .warning
            )
            return
        }
        let macrosToExport = selectedExportMacros()
        guard macrosToExport.isEmpty == false else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultExportFileName()
        guard panel.runModal() == .OK,
              let url = panel.url
        else { return }

        do {
            let data = try coordinator.exportData(macros: macrosToExport)
            try data.write(to: url, options: .atomic)
        } catch {
            presentMacroManagementError(error)
        }
    }

    @objc
    private func searchFieldChanged(_ sender: NSSearchField) {
        applyFilters()
    }

    public func controlTextDidChange(_ obj: Notification) {
        applyFilters()
    }

    @objc
    private func groupPopupChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1:
            groupFilter = .ungrouped
        case 2...:
            groupFilter = .group(sender.titleOfSelectedItem ?? "")
        default:
            groupFilter = .all
        }
        applyFilters()
    }

    @objc
    private func runPreviewConfirmationChanged(_ sender: NSButton) {
        userDefaults.set(sender.state == .on, forKey: Self.runPreviewConfirmationDefaultsKey)
    }
}

public final class PopoverTerminalMacroRunPreviewPresenter: TerminalMacroRunPreviewPresenting {
    private var popover: NSPopover?

    public init() {}

    public func presentRunPreview(
        for macro: TerminalMacroRecord,
        relativeTo rect: NSRect,
        of view: NSView,
        onConfirm: @escaping () -> Void
    ) {
        let content = TerminalMacroRunPreviewViewController(macro: macro)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        content.onConfirm = { [weak popover] in
            popover?.close()
            onConfirm()
        }
        content.onCancel = { [weak popover] in
            popover?.close()
        }
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}

private final class TerminalMacroRunPreviewViewController: NSViewController {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private let macro: TerminalMacroRecord

    init(macro: TerminalMacroRecord) {
        self.macro = macro
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 230))
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)

        let titleLabel = NSTextField(labelWithString: "确认运行「\(macro.name)」")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let commandText = NSTextView()
        commandText.isEditable = false
        commandText.isSelectable = true
        commandText.drawsBackground = false
        commandText.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commandText.textColor = StacioDesignSystem.theme.primaryTextColor
        commandText.string = macro.steps
            .sorted { lhs, rhs in lhs.order < rhs.order }
            .map(\.input)
            .joined(separator: "\n")
        if commandText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commandText.string = "没有命令"
        }

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = commandText

        let confirmButton = NSButton(title: "确认运行", target: self, action: #selector(confirm(_:)))
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: L10n.Common.cancel, target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(equalToConstant: 360),
            scrollView.heightAnchor.constraint(equalToConstant: 150)
        ])

        view = container
    }

    @objc
    private func confirm(_ sender: Any?) {
        onConfirm?()
    }

    @objc
    private func cancel(_ sender: Any?) {
        onCancel?()
    }
}
