import AppKit

/// A persistent toolbar and a virtualized list. Metrics ticks never replace the search field or its editor.
final class DeviceMetricsInventoryPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Action: Equatable {
        case process(ManagedProcessAction, UInt32, String? = nil)
        case service(ManagedServiceAction, ManagedServiceInfo)
        case container(ManagedContainerAction, ManagedContainerInfo)
    }
    enum Tone: Equatable { case normal, success, warning }
    struct Button: Equatable {
        let symbol: String
        let title: String
        let action: Action
        let isEnabled: Bool

        init(symbol: String, title: String, action: Action, isEnabled: Bool = true) {
            self.symbol = symbol
            self.title = title
            self.action = action
            self.isEnabled = isEnabled
        }
    }
    struct Row: Equatable {
        let id: String
        let title: String
        let subtitle: String
        let badge: String
        let tone: Tone
        let filter: Int
        let search: String
        var cpu: Double = 0
        var hasCPUUsage: Bool = true
        var memory: Double = 0
        var hasMemoryUsage: Bool = true
        var pid: UInt32 = 0
        var user: String = ""
        var tooltip: String = ""
        var buttons: [Button] = []
    }

    let segment: Int
    let searchField = NSSearchField()
    let filterControl: NSSegmentedControl
    let sortControl = NSSegmentedControl(labels: ["CPU ↓", "内存", "PID", "命令", "用户"], trackingMode: .selectOne, target: nil, action: nil)
    private let processSortLabels = ["CPU", "内存", "PID", "命令", "用户"]
    let countLabel = NSTextField(labelWithString: "等待加载")
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let refresh = InventoryClosureButton(symbol: "arrow.clockwise", title: "刷新")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let authorize = NSButton(title: "sudo 提权", target: nil, action: nil)
    private let feedback = NSStackView()
    private var rows: [Row] = []
    private(set) var visibleRows: [Row] = []
    private var hasLoaded = false
    private var loading = false
    private var busy = false
    private var failure: Error?
    private var partialInventoryFailure: DeviceMetricsInventoryError?
    private var hasPartialContainerInventory = false
    private var ascending = false
    var onRefresh: (() -> Void)?
    var onAuthorize: (() -> Void)?
    var onAction: ((Action) -> Void)?

    init(segment: Int) {
        self.segment = segment
        let labels: [String]
        switch segment {
        case 1: labels = ["全部", "运行中"]
        case 2: labels = ["全部", "TCP", "UDP"]
        case 3: labels = ["全部", "运行中", "失败", "未运行"]
        default: labels = ["全部", "运行中", "已停止", "已暂停"]
        }
        filterControl = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = ["", "process", "port", "service", "container"][segment]
        setAccessibilityIdentifier("Stacio.Metrics.\(name)List")
        searchField.placeholderString = "搜索\(["", "进程", "端口", "服务", "容器"][segment])…"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("Stacio.Metrics.\(name)Search")
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh.handler = { [weak self] in self?.onRefresh?() }
        let searchRow = NSStackView(views: [searchField, refresh])
        searchRow.spacing = 8
        searchRow.alignment = .centerY
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.selectedSegment = 0
        filterControl.segmentStyle = .texturedRounded
        filterControl.setAccessibilityIdentifier("Stacio.Metrics.\(name)Filter")
        for index in labels.indices { filterControl.setWidth(index == 0 ? 40 : 54, forSegment: index) }
        let filterRow = NSStackView(views: [filterControl, NSView()])
        filterRow.alignment = .centerY
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        countLabel.setAccessibilityIdentifier("Stacio.Metrics.\(name)Count")
        let meta = NSStackView(views: [countLabel, NSView()])
        meta.alignment = .centerY
        meta.spacing = 2
        if segment == 1 {
            sortControl.controlSize = .small
            sortControl.font = .systemFont(ofSize: 11)
            sortControl.segmentStyle = .texturedRounded
            sortControl.selectedSegment = 0
            sortControl.target = self
            sortControl.action = #selector(sortChanged)
            sortControl.setAccessibilityIdentifier("Stacio.Metrics.processSort")
            configureProcessSortWidths()
            sortControl.setContentCompressionResistancePriority(.required, for: .horizontal)
            meta.addArrangedSubview(sortControl)
        }
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byTruncatingTail
        authorize.target = self
        authorize.action = #selector(authorizePressed)
        authorize.bezelStyle = .rounded
        feedback.orientation = .vertical
        feedback.alignment = .leading
        feedback.addArrangedSubview(message)
        feedback.addArrangedSubview(authorize)
        authorize.isHidden = true
        feedback.isHidden = true
        let column = NSTableColumn(identifier: .init("inventory"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("Stacio.Metrics.\(name)Table")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let stack = NSStackView(views: [searchRow, filterRow, meta, feedback, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 420),
        ])
        for row in [searchRow, filterRow, meta, feedback, scroll] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        message.widthAnchor.constraint(equalTo: feedback.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let viewportWidth = scroll.contentView.bounds.width
        guard viewportWidth > 0 else { return }
        // NSTableView is the scroll view's document view, so the surrounding
        // Auto Layout stack does not automatically resize its single column.
        // Keep it aligned with the visible viewport after dashboard resizes.
        if abs(table.frame.width - viewportWidth) > 0.5 {
            var frame = table.frame
            frame.size.width = viewportWidth
            table.frame = frame
            table.sizeLastColumnToFit()
        }
    }

    func update(_ values: [Row]) {
        let changed = rows != values || !hasLoaded
        rows = values
        hasLoaded = true
        failure = nil
        partialInventoryFailure = nil
        hasPartialContainerInventory = false
        if changed { applyFilter() }
        updateFeedback()
    }
    func setLoading(_ value: Bool) { loading = value; updateFeedback() }
    func setFailure(_ error: Error) {
        failure = error
        if let error = error as? DeviceMetricsInventoryError,
           error.partialContainers != nil || error.partialPorts != nil {
            partialInventoryFailure = error
            if error.partialContainers != nil { hasPartialContainerInventory = true }
        }
        updateFeedback()
    }
    func clearAuthorizationFailure() {
        if (failure as? DeviceMetricsInventoryError)?.requiresAuthorization == true { failure = nil }
        if partialInventoryFailure?.requiresAuthorization == true { partialInventoryFailure = nil }
        // Clearing an obsolete permission error does not make existing container
        // data complete. Retain its partial marker until the next data update.
        updateFeedback()
    }
    func setBusy(_ value: Bool) { busy = value; updateFeedback(); table.reloadData() }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    @objc private func filterChanged() { applyFilter() }
    private var sortIndex = 0
    @objc private func sortChanged() {
        let selected = sortControl.selectedSegment
        if sortIndex == selected { ascending.toggle() }
        else { sortIndex = selected; ascending = selected >= 2 }
        for i in processSortLabels.indices {
            sortControl.setLabel(processSortLabels[i] + (i == selected ? (ascending ? " ↑" : " ↓") : ""), forSegment: i)
        }
        // Reapply widths after changing labels. AppKit may recompute the
        // intrinsic width when a segment becomes selected, which otherwise
        // clips the first character on narrow dashboard panels.
        configureProcessSortWidths()
        applyFilter()
    }
    @objc private func authorizePressed() { onAuthorize?() }

    private func configureProcessSortWidths() {
        guard segment == 1 else { return }
        let font = sortControl.font ?? NSFont.systemFont(ofSize: 11)
        for (index, label) in processSortLabels.enumerated() {
            let textWidth = ([label + " ↑", label + " ↓"] as [NSString])
                .map { $0.size(withAttributes: [.font: font]).width }
                .max() ?? 0
            // Textured rounded segments reserve extra inset when selected.
            // Keep a fixed width for both sort directions and include a native
            // control margin so labels remain fully visible.
            sortControl.setWidth(ceil(textWidth) + 14, forSegment: index)
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filterControl.selectedSegment
        var next = rows.filter { (filter == 0 || $0.filter == filter) && (query.isEmpty || $0.search.localizedCaseInsensitiveContains(query)) }
        if segment == 1 {
            next.sort { a, b in
                if sortIndex == 0 {
                    // Missing samples are neither idle processes nor CPU-core
                    // numbers. Keep them last in either sort direction.
                    if a.hasCPUUsage != b.hasCPUUsage { return a.hasCPUUsage }
                    if !a.hasCPUUsage { return a.pid < b.pid }
                }
                if sortIndex == 1 {
                    if a.hasMemoryUsage != b.hasMemoryUsage { return a.hasMemoryUsage }
                    if !a.hasMemoryUsage { return a.pid < b.pid }
                }
                let comparison: ComparisonResult
                switch sortIndex {
                case 0: comparison = a.cpu == b.cpu ? .orderedSame : a.cpu < b.cpu ? .orderedAscending : .orderedDescending
                case 1: comparison = a.memory == b.memory ? .orderedSame : a.memory < b.memory ? .orderedAscending : .orderedDescending
                case 2: comparison = a.pid == b.pid ? .orderedSame : a.pid < b.pid ? .orderedAscending : .orderedDescending
                case 3: comparison = a.title.localizedStandardCompare(b.title)
                default: comparison = a.user.localizedStandardCompare(b.user)
                }
                if comparison == .orderedSame { return a.pid < b.pid }
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
        if next != visibleRows {
            let origin = scroll.contentView.bounds.origin
            visibleRows = next
            table.reloadData()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, table.bounds.height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateFeedback()
    }
    private func updateFeedback() {
        refresh.isEnabled = !loading && !busy
        authorize.isEnabled = !busy
        refresh.toolTip = loading ? "正在刷新…" : "刷新"
        let noun = ["", "个进程", "个监听", "个服务", "个容器"][segment]
        let currentFailure: Error? = failure ?? partialInventoryFailure
        let inventoryError = currentFailure as? DeviceMetricsInventoryError
        // Port rows remain a complete listener inventory when only ownership
        // lookup fails. Reserve the partial count for missing container engines.
        countLabel.stringValue = hasLoaded ? "\(visibleRows.count) \(noun)" + (hasPartialContainerInventory ? "（部分）" : "") : loading ? "正在加载…" : "尚未加载"
        authorize.isHidden = true
        if let failure = currentFailure {
            let prefix = inventoryError?.partialPorts != nil ? "端口列表已更新，部分进程信息未获取。\n"
                : hasPartialContainerInventory ? "已显示可读取的容器。\n"
                : hasLoaded ? "刷新失败，保留上次数据。\n" : "读取失败。\n"
            message.stringValue = prefix + failure.localizedDescription
            if let partialInventoryFailure,
               inventoryError?.partialContainers == nil && inventoryError?.partialPorts == nil {
                if partialInventoryFailure.partialPorts != nil { message.stringValue += "\n部分进程信息未获取。" }
                message.stringValue += "\n" + partialInventoryFailure.localizedDescription
            }
            authorize.isHidden = inventoryError?.requiresAuthorization != true && partialInventoryFailure?.requiresAuthorization != true
        } else if hasLoaded && visibleRows.isEmpty {
            if rows.isEmpty {
                message.stringValue = hasPartialContainerInventory ? "容器列表尚不完整。" : "没有\(["", "进程", "监听端口", "服务", "容器"][segment])"
            } else { message.stringValue = "没有匹配的结果" }
        } else { message.stringValue = "" }
        message.toolTip = message.stringValue
        feedback.isHidden = message.stringValue.isEmpty
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("inventoryRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? InventoryTableCell ?? InventoryTableCell()
        cell.identifier = identifier
        let actionSlots: Int
        switch segment {
        case 2: actionSlots = 1
        case 3: actionSlots = 2
        default: actionSlots = 4
        }
        cell.configure(visibleRows[row], actionSlots: actionSlots, enabled: !busy) { [weak self] in self?.onAction?($0) }
        return cell
    }
}

private final class InventoryClosureButton: NSButton {
    var handler: (() -> Void)?
    init(symbol: String, title: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = title
        setAccessibilityLabel(title)
        target = self
        action = #selector(invoke)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
}

private final class InventoryTableCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let actionSpacer = NSView()
    private var actionsWidthConstraint: NSLayoutConstraint!
    private var buttons: [InventoryClosureButton] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        title.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.alignment = .center
        badge.lineBreakMode = .byTruncatingTail
        badge.widthAnchor.constraint(equalToConstant: 54).isActive = true
        actions.orientation = .horizontal
        actions.distribution = .fill
        actions.spacing = 2
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(actionSpacer)
        for _ in 0..<4 {
            let button = InventoryClosureButton(symbol: "circle", title: "")
            buttons.append(button)
            actions.addArrangedSubview(button)
        }
        // Pin the action group to the cell edge and give the remaining width to text.
        // A stack gravity area can otherwise leave unused space after short titles.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionsWidthConstraint = actions.widthAnchor.constraint(equalToConstant: 0)
        actionsWidthConstraint.isActive = true
        for item in [text, badge, actions] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            text.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -6),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ value: DeviceMetricsInventoryPanel.Row, actionSlots: Int, enabled: Bool, handler: @escaping (DeviceMetricsInventoryPanel.Action) -> Void) {
        title.stringValue = value.title
        subtitle.stringValue = value.subtitle
        badge.stringValue = value.badge
        // Every row in a tab reserves the same trailing column, including rows
        // without actions. Hidden controls remain noninteractive; the spacer
        // keeps any available buttons right aligned inside that fixed column.
        // Ports reserve only one slot, leaving more width for the address/name.
        actionsWidthConstraint.constant = CGFloat(actionSlots * 26)
        badge.textColor = value.tone == .success ? .systemGreen : value.tone == .warning ? .systemOrange : .secondaryLabelColor
        toolTip = value.tooltip.isEmpty ? "\(value.title)\n\(value.subtitle)" : value.tooltip
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= value.buttons.count
            guard index < value.buttons.count else { button.handler = nil; continue }
            let definition = value.buttons[index]
            let isForceTermination: Bool
            switch definition.action {
            case .process(.forceTerminate, _, _), .container(.kill, _): isForceTermination = true
            default: isForceTermination = false
            }
            button.image = NSImage(systemSymbolName: definition.symbol, accessibilityDescription: definition.title)
            // Keep the fixed 24pt action cell icon-only; the explicit tooltip and
            // accessibility label explain that this is SIGKILL/force termination.
            button.title = ""
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.imagePosition = .imageOnly
            button.contentTintColor = isForceTermination ? .systemRed : .secondaryLabelColor
            button.toolTip = definition.title
            button.setAccessibilityLabel(definition.title)
            button.isEnabled = enabled && definition.isEnabled
            button.handler = { handler(definition.action) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 3, y: 0, width: max(0, bounds.width - 8), height: 0.5).fill()
    }
}
