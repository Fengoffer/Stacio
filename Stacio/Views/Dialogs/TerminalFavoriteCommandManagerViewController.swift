import AppKit

@MainActor
public final class TerminalFavoriteCommandManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let tableView = StacioDeleteKeyTableView()
    private let store: TerminalFavoriteCommandStore
    private var commands: [TerminalFavoriteCommand] = []
    private var storeObserver: NSObjectProtocol?
    private var editorWindowController: NSWindowController?
    private let addButton = NSButton(title: "新增", target: nil, action: nil)
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let toggleButton = NSButton(title: "启用/停用", target: nil, action: nil)
    private let emptyStateLabel = NSTextField(labelWithString: "还没有常用命令\n点击“新增”添加一条可跨本地与 SSH 会话复用的命令")

    public init(store: TerminalFavoriteCommandStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "常用命令"
        commands = store.commands
        storeObserver = NotificationCenter.default.addObserver(
            forName: TerminalFavoriteCommandStore.didChangeNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.addTableColumn(column("名称", identifier: "name", width: 136))
        tableView.addTableColumn(column("命令", identifier: "command", width: 220))
        tableView.addTableColumn(column("适用系统", identifier: "os", width: 216))
        tableView.addTableColumn(column("状态", identifier: "enabled", width: 72))
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.deleteSelectionHandler = { [weak self] in
            guard let self, self.tableView.selectedRowIndexes.isEmpty == false else { return false }
            self.deleteSelectedCommands()
            return true
        }
        tableView.headerView = NSTableHeaderView()
        tableView.doubleAction = #selector(editPressed(_:))
        tableView.target = self
        scroll.documentView = tableView

        let buttons = NSStackView(views: [addButton, editButton, deleteButton, toggleButton, NSView()])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for button in [addButton, editButton, deleteButton, toggleButton] {
            button.target = self
            button.bezelStyle = .rounded
        }
        addButton.action = #selector(addPressed(_:))
        editButton.action = #selector(editPressed(_:))
        deleteButton.action = #selector(deletePressed(_:))
        toggleButton.action = #selector(togglePressed(_:))
        addButton.setAccessibilityIdentifier("Stacio.FavoriteCommands.add")
        editButton.setAccessibilityIdentifier("Stacio.FavoriteCommands.edit")
        deleteButton.setAccessibilityIdentifier("Stacio.FavoriteCommands.delete")
        toggleButton.setAccessibilityIdentifier("Stacio.FavoriteCommands.toggle")

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 13)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.maximumNumberOfLines = 2
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.setAccessibilityIdentifier("Stacio.FavoriteCommands.emptyState")

        root.addSubview(scroll)
        root.addSubview(buttons)
        root.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            tableView.widthAnchor.constraint(greaterThanOrEqualToConstant: 644),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 20),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -20)
        ])
        view = root
        refresh()
    }

    private func column(_ title: String, identifier: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        return column
    }

    public func refresh() {
        let selectedID = tableView.selectedRow >= 0 && tableView.selectedRow < commands.count
            ? commands[tableView.selectedRow].id
            : nil
        commands = store.commands
        tableView.reloadData()
        if let selectedID, let selectedRow = commands.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
        updateButtons()
        emptyStateLabel.isHidden = !commands.isEmpty
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < commands.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = tableColumn!.identifier
        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        if label.superview == nil { cell.addSubview(label); NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ]) }
        let command = commands[row]
        switch identifier {
        case "name": label.stringValue = command.name
        case "command": label.stringValue = command.command
        case "os": label.stringValue = command.operatingSystemDisplayNames.joined(separator: ", ")
        case "enabled": label.stringValue = command.enabled ? "启用" : "停用"
        default: label.stringValue = ""
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func addPressed(_ sender: Any?) { presentEditor(command: nil) }

    @objc private func editPressed(_ sender: Any?) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < commands.count else { return }
        presentEditor(command: commands[tableView.selectedRow])
    }

    @objc private func deletePressed(_ sender: Any?) {
        deleteSelectedCommands()
    }

    private func deleteSelectedCommands() {
        let selected = tableView.selectedRowIndexes.compactMap { index -> UUID? in
            commands.indices.contains(index) ? commands[index].id : nil
        }
        guard selected.isEmpty == false else { return }
        selected.forEach { _ = store.remove(id: $0) }
        refresh()
    }

    @objc private func togglePressed(_ sender: Any?) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < commands.count else { return }
        let command = commands[tableView.selectedRow]
        _ = store.setEnabled(!command.enabled, id: command.id)
        refresh()
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0 && tableView.selectedRow < commands.count
        editButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        toggleButton.isEnabled = hasSelection
    }

    private func presentEditor(command existing: TerminalFavoriteCommand?) {
        let editor = TerminalFavoriteCommandEditorViewController(command: existing) { [weak self] value in
            guard let self else { return false }
            let saved = existing == nil ? self.store.add(value) != nil : self.store.update(value)
            if saved { self.refresh() }
            return saved
        }
        let window = NSWindow(contentViewController: editor)
        window.title = existing == nil ? "新增常用命令" : "编辑常用命令"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 680, height: 456))
        window.isReleasedWhenClosed = false
        let windowController = NSWindowController(window: window)
        editorWindowController = windowController
        if let parentWindow = view.window {
            parentWindow.beginSheet(window)
        } else {
            windowController.showWindow(self)
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func selectCommandRowForTesting(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    public func toggleSelectedCommandForTesting() { togglePressed(nil) }

    public func deleteSelectedCommandForTesting() { deletePressed(nil) }
}

@MainActor
private final class TerminalFavoriteCommandEditorViewController: NSViewController {
    private let existing: TerminalFavoriteCommand?
    private let saveHandler: (TerminalFavoriteCommand) -> Bool
    private let nameField = NSTextField()
    private let commandField = NSTextField()
    private let detailsField = NSTextField()
    private let tagsField = NSTextField()
    private let customOperatingSystemsField = NSTokenField()
    private let validationLabel = NSTextField(labelWithString: "")
    private var operatingSystemButtons: [(TerminalCommandOperatingSystem, NSButton)] = []

    init(command: TerminalFavoriteCommand?, saveHandler: @escaping (TerminalFavoriteCommand) -> Bool) {
        existing = command
        self.saveHandler = saveHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("Stacio.FavoriteCommands.editor")

        let title = NSTextField(labelWithString: existing == nil ? "新增常用命令" : "编辑常用命令")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        let help = NSTextField(labelWithString: "命令只会填入终端，不会自动执行。请勿保存密码、令牌等敏感内容。")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor

        configure(nameField, value: existing?.name, placeholder: "例如：查看服务状态", identifier: "name")
        configure(commandField, value: existing?.command, placeholder: "例如：systemctl status nginx", identifier: "command")
        configure(detailsField, value: existing?.details, placeholder: "可选", identifier: "details")
        configure(tagsField, value: existing?.tags.joined(separator: ", "), placeholder: "可选，使用逗号分隔", identifier: "tags")
        let form = NSGridView(views: [
            [formLabel("名称"), nameField],
            [formLabel("命令"), commandField],
            [formLabel("说明"), detailsField],
            [formLabel("标签"), tagsField]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 14
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        for rowIndex in 0..<form.numberOfRows {
            form.row(at: rowIndex).height = 26
        }
        form.setContentHuggingPriority(.required, for: .vertical)
        form.setContentCompressionResistancePriority(.required, for: .vertical)

        let osTitle = formLabel("适用系统")
        operatingSystemButtons = TerminalCommandOperatingSystem.allCases
            .filter { $0 != .unknown }
            .map { operatingSystem in
                let button = NSButton(checkboxWithTitle: operatingSystem.displayName, target: nil, action: nil)
                button.target = self
                button.action = #selector(operatingSystemChanged(_:))
                button.state = existing?.operatingSystems.contains(operatingSystem) == true
                    || (existing == nil && operatingSystem == .generic) ? .on : .off
                button.setAccessibilityIdentifier("Stacio.FavoriteCommands.os.\(operatingSystem.rawValue)")
                return (operatingSystem, button)
            }
        let osGrid = NSGridView()
        osGrid.translatesAutoresizingMaskIntoConstraints = false
        osGrid.rowSpacing = 2
        osGrid.columnSpacing = 18
        for start in stride(from: 0, to: operatingSystemButtons.count, by: 2) {
            let buttons = operatingSystemButtons[start..<min(start + 2, operatingSystemButtons.count)].map { $0.1 }
            let row = osGrid.addRow(with: buttons)
            row.yPlacement = .center
            row.height = 24
        }
        osGrid.column(at: 0).width = 238
        if osGrid.numberOfColumns > 1 { osGrid.column(at: 1).width = 238 }

        let osDocument = TerminalFavoriteCommandFlippedView()
        osDocument.translatesAutoresizingMaskIntoConstraints = false
        osDocument.addSubview(osGrid)
        let osScroll = NSScrollView()
        osScroll.translatesAutoresizingMaskIntoConstraints = false
        osScroll.hasVerticalScroller = true
        osScroll.autohidesScrollers = true
        osScroll.drawsBackground = false
        osScroll.borderType = .noBorder
        osScroll.documentView = osDocument
        osScroll.setAccessibilityIdentifier("Stacio.FavoriteCommands.os.scroll")
        NSLayoutConstraint.activate([
            osGrid.leadingAnchor.constraint(equalTo: osDocument.leadingAnchor),
            osGrid.trailingAnchor.constraint(equalTo: osDocument.trailingAnchor),
            osGrid.topAnchor.constraint(equalTo: osDocument.topAnchor),
            osGrid.bottomAnchor.constraint(equalTo: osDocument.bottomAnchor),
            osDocument.widthAnchor.constraint(equalTo: osScroll.contentView.widthAnchor),
            osScroll.heightAnchor.constraint(equalToConstant: 128)
        ])

        customOperatingSystemsField.objectValue = existing?.customOperatingSystems.sorted() ?? []
        customOperatingSystemsField.placeholderString = "自定义系统名称，使用逗号或回车添加"
        customOperatingSystemsField.tokenizingCharacterSet = CharacterSet(charactersIn: ",，")
        customOperatingSystemsField.target = self
        customOperatingSystemsField.action = #selector(customOperatingSystemsChanged(_:))
        customOperatingSystemsField.setAccessibilityIdentifier("Stacio.FavoriteCommands.os.custom")
        customOperatingSystemsField.toolTip = "名称会与远端 /etc/os-release 的系统标识和名称匹配"
        let customRow = NSGridView(views: [[formLabel("自定义"), customOperatingSystemsField]])
        customRow.rowSpacing = 0
        customRow.columnSpacing = 12
        customRow.column(at: 0).xPlacement = .trailing
        customRow.column(at: 1).xPlacement = .fill

        let osControls = NSStackView(views: [osScroll, customRow])
        osControls.orientation = .vertical
        osControls.alignment = .leading
        osControls.spacing = 8
        let osForm = NSGridView(views: [[osTitle, osControls]])
        osForm.columnSpacing = 14
        osForm.column(at: 0).xPlacement = .trailing
        osForm.column(at: 1).xPlacement = .fill
        osForm.setContentHuggingPriority(.required, for: .vertical)
        osForm.setContentCompressionResistancePriority(.required, for: .vertical)

        validationLabel.font = .systemFont(ofSize: 12)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        validationLabel.setAccessibilityIdentifier("Stacio.FavoriteCommands.validation")

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelPressed(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "保存", target: self, action: #selector(savePressed(_:)))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.setAccessibilityIdentifier("Stacio.FavoriteCommands.save")
        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let content = NSStackView(views: [title, help, form, osForm, validationLabel, buttonRow])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(20, after: help)
        content.setCustomSpacing(16, after: validationLabel)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            form.widthAnchor.constraint(equalTo: content.widthAnchor),
            osForm.widthAnchor.constraint(equalTo: content.widthAnchor),
            osScroll.widthAnchor.constraint(equalToConstant: 510),
            customRow.widthAnchor.constraint(equalTo: osScroll.widthAnchor),
            customOperatingSystemsField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            buttonRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
        view = root
    }

    private func configure(_ field: NSTextField, value: String?, placeholder: String, identifier: String) {
        field.stringValue = value ?? ""
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.setAccessibilityIdentifier("Stacio.FavoriteCommands.editor.\(identifier)")
    }

    private func formLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func cancelPressed(_ sender: Any?) { closeEditor() }

    @objc private func operatingSystemChanged(_ sender: NSButton) {
        guard let selected = operatingSystemButtons.first(where: { $0.1 === sender })?.0,
              sender.state == .on else { return }
        if selected == .generic {
            for (operatingSystem, button) in operatingSystemButtons where operatingSystem != .generic {
                button.state = .off
            }
            customOperatingSystemsField.objectValue = []
        } else {
            operatingSystemButtons.first(where: { $0.0 == .generic })?.1.state = .off
        }
    }

    @objc private func customOperatingSystemsChanged(_ sender: NSTokenField) {
        guard customOperatingSystemNames().isEmpty == false else { return }
        operatingSystemButtons.first(where: { $0.0 == .generic })?.1.state = .off
    }

    @objc private func savePressed(_ sender: Any?) {
        let customOperatingSystems = customOperatingSystemNames()
        var operatingSystems = Set(operatingSystemButtons.compactMap { operatingSystem, button in
            button.state == .on ? operatingSystem : nil
        })
        if customOperatingSystems.isEmpty == false || operatingSystems.contains(where: { $0 != .generic }) {
            operatingSystems.remove(.generic)
        }
        let value = TerminalFavoriteCommand(
            id: existing?.id ?? UUID(),
            name: nameField.stringValue,
            command: commandField.stringValue,
            details: detailsField.stringValue,
            tags: tagsField.stringValue.split(separator: ",").map(String.init),
            operatingSystems: operatingSystems,
            customOperatingSystems: customOperatingSystems,
            enabled: existing?.enabled ?? true
        )
        guard saveHandler(value) else {
            validationLabel.stringValue = "名称和命令不能为空，命令不能重复，也不能包含换行或控制字符。"
            validationLabel.isHidden = false
            return
        }
        closeEditor()
    }

    private func customOperatingSystemNames() -> Set<String> {
        if let values = customOperatingSystemsField.objectValue as? [String] {
            return Set(values)
        }
        return Set(customOperatingSystemsField.stringValue.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init))
    }

    private func closeEditor() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}

private final class TerminalFavoriteCommandFlippedView: NSView {
    override var isFlipped: Bool { true }
}
