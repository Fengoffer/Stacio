import AppKit
import Foundation

// MARK: - Pending Input Queue（P5-4，可编辑队列）

/// 队列项视图状态：可编辑/删除/拖动排序/设为下一条/拉回 Composer。
public struct PendingQueueItemViewState: Equatable, Sendable {
    public let itemID: String
    public var text: String
    /// 上下文快照 revision：编辑正文不改变；「重新绑定」生成新 revision。
    public var contextSnapshotRevision: Int
    public var needsRebind: Bool
    public var contextDiff: String
    public var isNextUp: Bool

    public init(
        itemID: String, text: String, contextSnapshotRevision: Int,
        needsRebind: Bool = false, contextDiff: String = "", isNextUp: Bool = false
    ) {
        self.itemID = itemID
        self.text = text
        self.contextSnapshotRevision = contextSnapshotRevision
        self.needsRebind = needsRebind
        self.contextDiff = contextDiff
        self.isNextUp = isNextUp
    }
}

/// needsRebind 二选一：按原上下文发送 / 绑定到当前会话上下文。
public enum QueueRebindChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case sendWithOriginalContext
    case bindToCurrentSessionContext
}

public struct QueueRebindDecision: Equatable, Sendable {
    public let diff: String
    public let choices: [QueueRebindChoice]

    public init(diff: String, choices: [QueueRebindChoice] = QueueRebindChoice.allCases) {
        self.diff = diff
        self.choices = choices
    }
}

public enum PendingInputQueueAction {

    /// 拖动排序（只影响本会话输入，不改变全局 Admission FIFO）。
    public static func reorder(items: [String], fromIndex: Int, toIndex: Int) -> [String] {
        guard items.indices.contains(fromIndex),
              items.indices.contains(toIndex),
              fromIndex != toIndex
        else {
            return items
        }
        var result = items
        let moved = result.remove(at: fromIndex)
        result.insert(moved, at: toIndex)
        return result
    }

    public static func delete(items: [String], itemID: String) -> [String] {
        items.filter { $0 != itemID }
    }

    public static func setNextUp(items: [String], itemID: String) -> [String] {
        guard items.contains(itemID) else { return items }
        var result = items.filter { $0 != itemID }
        result.insert(itemID, at: 0)
        return result
    }

    /// 拉回 Composer：从队列移除并返回给编辑区。
    public static func pullBackToComposer(items: [String], itemID: String) -> (queue: [String], pulledText: String?) {
        guard let index = items.firstIndex(of: itemID) else {
            return (items, nil)
        }
        var result = items
        let pulled = result.remove(at: index)
        return (result, pulled)
    }

    /// 编辑正文不改变上下文快照（revision 不变）。
    public static func editText(
        item: PendingQueueItemViewState, newText: String
    ) -> PendingQueueItemViewState {
        PendingQueueItemViewState(
            itemID: item.itemID, text: newText,
            contextSnapshotRevision: item.contextSnapshotRevision,
            needsRebind: item.needsRebind, contextDiff: item.contextDiff,
            isNextUp: item.isNextUp
        )
    }

    /// 修改上下文必须单独「重新绑定」并生成新 revision。
    public static func rebindContext(
        item: PendingQueueItemViewState, choice: QueueRebindChoice
    ) -> PendingQueueItemViewState {
        PendingQueueItemViewState(
            itemID: item.itemID, text: item.text,
            contextSnapshotRevision: item.contextSnapshotRevision + 1,
            needsRebind: false, contextDiff: "",
            isNextUp: item.isNextUp
        )
    }

    /// needsRebind 显示差异与二选一。
    public static func rebindDecision(diff: String) -> QueueRebindDecision {
        QueueRebindDecision(diff: diff)
    }

    /// 队列摘要始终提供「暂停/继续自动衔接」且跨重启保存。
    public static func autoAdvancePaused() -> Bool { true }
    public static func autoAdvancePersistenceKey() -> String { "pendingInputQueue.autoAdvancePaused" }

    /// 排序只影响本会话输入，不改变全局 Admission FIFO。
    public static func reorderAffectsOnlySessionInput() -> Bool { true }
}

// MARK: - Native pending-input queue

@MainActor
public final class PendingInputQueueView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public var onEdit: ((String, String) -> Void)?
    public var onRemove: ((String) -> Void)?
    public var onMove: ((String, Int) -> Void)?
    public var onSetNext: ((String) -> Void)?
    public var onPullBack: ((String) -> Void)?
    public var onRebind: ((String, QueueRebindChoice) -> Void)?
    public var onAutoAdvanceChanged: ((Bool) -> Void)?
    public var rebindSummaryProvider: ((QueuedInput) -> String)?

    private static let dragType = NSPasteboard.PasteboardType("com.stacio.pending-input")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let disclosureButton = NSButton()
    private let autoAdvanceSwitch = NSSwitch()
    private let tableView = StacioDeleteKeyTableView()
    private let scrollView = NSScrollView()
    private var items: [QueuedInput] = []
    private var suppressAutoAdvanceCallback = false
    private var compactPresentation = false
    private var compactPopover: NSPopover?
    private weak var compactPopoverQueueView: PendingInputQueueView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func apply(
        items: [QueuedInput],
        autoAdvancePaused: Bool,
        forceRefresh: Bool = false
    ) {
        let sortedItems = items.sorted { $0.position < $1.position }
        let itemsChanged = sortedItems != self.items
        self.items = sortedItems
        summaryLabel.stringValue = "待发送 \(sortedItems.count) 条"
        suppressAutoAdvanceCallback = true
        autoAdvanceSwitch.state = autoAdvancePaused ? .off : .on
        suppressAutoAdvanceCallback = false
        isHidden = sortedItems.isEmpty
        disclosureButton.isHidden = compactPresentation == false || sortedItems.isEmpty
        if itemsChanged || forceRefresh {
            tableView.reloadData()
        }
        compactPopoverQueueView?.apply(
            items: sortedItems,
            autoAdvancePaused: autoAdvanceSwitch.state != .on,
            forceRefresh: forceRefresh
        )
        if sortedItems.isEmpty {
            compactPopover?.performClose(nil)
        }
        invalidateIntrinsicContentSize()
    }

    public var itemCount: Int { items.count }
    public var visibleTexts: [String] { items.map(\.text) }
    public var isCompactPresentation: Bool { compactPresentation }

    /// Approval is the primary action surface in a short Inspector. Keep the
    /// queue count and auto-advance control visible without letting editable
    /// rows compete with the immutable approval details.
    public func setCompactPresentation(_ compact: Bool) {
        guard compactPresentation != compact else { return }
        compactPresentation = compact
        if compact == false {
            compactPopover?.performClose(nil)
        }
        disclosureButton.isHidden = compact == false || items.isEmpty
        scrollView.isHidden = compact
        setContentCompressionResistancePriority(
            compact ? .required : .defaultLow,
            for: .vertical
        )
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Opens the full queue in a transient popover while the approval card
    /// remains in place. This keeps row editing, reordering and pull-back
    /// actions available in a narrow Inspector without growing the transcript
    /// stack underneath the Composer.
    private func showCompactQueuePopover(from sender: NSButton) {
        guard compactPresentation, items.isEmpty == false else { return }
        if let compactPopover, compactPopover.isShown {
            compactPopover.performClose(nil)
            return
        }

        let queue = PendingInputQueueView(frame: NSRect(x: 0, y: 0, width: 420, height: 190))
        queue.rebindSummaryProvider = rebindSummaryProvider
        queue.onEdit = onEdit
        queue.onRemove = onRemove
        queue.onMove = onMove
        queue.onSetNext = onSetNext
        queue.onPullBack = onPullBack
        queue.onRebind = onRebind
        queue.onAutoAdvanceChanged = onAutoAdvanceChanged
        queue.apply(
            items: items,
            autoAdvancePaused: autoAdvanceSwitch.state != .on
        )

        let controller = NSViewController()
        controller.view = queue
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 420, height: min(238, queue.intrinsicContentSize.height + 8))
        compactPopover = popover
        compactPopoverQueueView = queue
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    public override var intrinsicContentSize: NSSize {
        guard items.isEmpty == false else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        if compactPresentation {
            return NSSize(width: NSView.noIntrinsicMetric, height: 34)
        }
        let rowsHeight = min(CGFloat(items.count) * 48, 144)
        return NSSize(width: NSView.noIntrinsicMetric, height: 34 + rowsHeight)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        48
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("PendingInputCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PendingInputCellView)
            ?? PendingInputCellView()
        cell.identifier = identifier
        let item = items[row]
        cell.configure(
            item: item,
            isNext: row == 0,
            rebindSummary: rebindSummaryProvider?(item) ?? "上下文需要重新确认"
        )
        cell.onEdit = { [weak self] text in self?.onEdit?(item.id, text) }
        cell.onRemove = { [weak self] in self?.onRemove?(item.id) }
        cell.onSetNext = { [weak self] in self?.onSetNext?(item.id) }
        cell.onPullBack = { [weak self] in self?.onPullBack?(item.id) }
        cell.onRebind = { [weak self] choice in self?.onRebind?(item.id, choice) }
        return cell
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard items.indices.contains(row) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(items[row].id, forType: Self.dragType)
        return pasteboardItem
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingPasteboard.string(forType: Self.dragType) == nil ? [] : .move
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let itemID = info.draggingPasteboard.string(forType: Self.dragType),
              let source = items.firstIndex(where: { $0.id == itemID })
        else { return false }
        var destination = min(max(row, 0), items.count)
        if source < destination { destination -= 1 }
        guard destination != source else { return false }
        onMove?(itemID, destination)
        return true
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("Stacio.AI.pendingQueue")
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.setAccessibilityIdentifier("Stacio.AI.pendingQueue.summary")

        disclosureButton.image = NSImage(
            systemSymbolName: "chevron.up.chevron.down",
            accessibilityDescription: "查看待发送队列"
        )
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .accessoryBarAction
        disclosureButton.controlSize = .small
        disclosureButton.toolTip = "查看待发送队列"
        disclosureButton.setAccessibilityLabel("查看待发送队列")
        disclosureButton.setAccessibilityIdentifier("Stacio.AI.pendingQueue.disclosure")
        disclosureButton.target = self
        disclosureButton.action = #selector(compactQueueDisclosurePressed(_:))
        disclosureButton.isHidden = true

        let autoLabel = NSTextField(labelWithString: "自动衔接")
        autoLabel.font = .systemFont(ofSize: 11)
        autoLabel.textColor = .secondaryLabelColor
        autoAdvanceSwitch.controlSize = .small
        autoAdvanceSwitch.target = self
        autoAdvanceSwitch.action = #selector(autoAdvanceChanged(_:))
        autoAdvanceSwitch.toolTip = "完成当前任务后自动发送下一条"
        autoAdvanceSwitch.setAccessibilityIdentifier("Stacio.AI.pendingQueue.autoAdvance")

        header.addArrangedSubview(summaryLabel)
        header.addArrangedSubview(disclosureButton)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(autoLabel)
        header.addArrangedSubview(autoAdvanceSwitch)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pending-input"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.deleteSelectionHandler = { [weak self] in
            guard let self, self.tableView.selectedRowIndexes.isEmpty == false else { return false }
            let selectedIDs = self.tableView.selectedRowIndexes.compactMap { index in
                self.items.indices.contains(index) ? self.items[index].id : nil
            }
            guard selectedIDs.isEmpty == false else { return false }
            selectedIDs.forEach { self.onRemove?($0) }
            return true
        }
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 26),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    @objc private func autoAdvanceChanged(_ sender: NSSwitch) {
        guard suppressAutoAdvanceCallback == false else { return }
        onAutoAdvanceChanged?(sender.state != .on)
    }

    @objc private func compactQueueDisclosurePressed(_ sender: NSButton) {
        showCompactQueuePopover(from: sender)
    }
}

@MainActor
private final class PendingInputCellView: NSTableCellView, NSTextFieldDelegate {
    var onEdit: ((String) -> Void)?
    var onRemove: (() -> Void)?
    var onSetNext: (() -> Void)?
    var onPullBack: (() -> Void)?
    var onRebind: ((QueueRebindChoice) -> Void)?

    private let dragHandle = NSImageView()
    private let editorField = NSTextField()
    private let nextButton = NSButton()
    private let pullBackButton = NSButton()
    private let deleteButton = NSButton()
    private let rebindButton = NSButton()
    private var originalText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(item: QueuedInput, isNext: Bool, rebindSummary: String) {
        originalText = item.text
        editorField.stringValue = item.text
        nextButton.isEnabled = isNext == false
        nextButton.toolTip = isNext ? "下一条" : "设为下一条"
        let requiresRebind = item.revalidationState != .valid
        rebindButton.isHidden = requiresRebind == false
        rebindButton.toolTip = rebindSummary
        rebindButton.setAccessibilityHelp(rebindSummary)
        rebindButton.menu = requiresRebind ? makeRebindMenu() : nil
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let trimmed = editorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            editorField.stringValue = originalText
            NSSound.beep()
            return
        }
        editorField.stringValue = trimmed
        guard trimmed != originalText else { return }
        originalText = trimmed
        onEdit?(trimmed)
    }

    private func setupView() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        dragHandle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")
        dragHandle.contentTintColor = .tertiaryLabelColor
        dragHandle.setContentHuggingPriority(.required, for: .horizontal)

        editorField.isEditable = true
        editorField.isBordered = false
        editorField.drawsBackground = false
        editorField.font = .systemFont(ofSize: 12)
        editorField.lineBreakMode = .byTruncatingTail
        editorField.delegate = self
        editorField.setAccessibilityIdentifier("Stacio.AI.pendingQueue.text")

        configureIconButton(nextButton, symbol: "arrow.up.to.line", tooltip: "设为下一条", action: #selector(setNext))
        configureIconButton(pullBackButton, symbol: "arrow.uturn.backward", tooltip: "拉回输入框", action: #selector(pullBack))
        configureIconButton(deleteButton, symbol: "trash", tooltip: "删除", action: #selector(remove))
        configureIconButton(
            rebindButton,
            symbol: "exclamationmark.triangle",
            tooltip: "上下文需要确认",
            action: #selector(showRebindMenu(_:))
        )
        rebindButton.contentTintColor = .systemOrange
        rebindButton.setAccessibilityLabel("重新绑定队列上下文")

        stack.addArrangedSubview(dragHandle)
        stack.addArrangedSubview(editorField)
        stack.addArrangedSubview(rebindButton)
        stack.addArrangedSubview(nextButton)
        stack.addArrangedSubview(pullBackButton)
        stack.addArrangedSubview(deleteButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            dragHandle.widthAnchor.constraint(equalToConstant: 16),
            rebindButton.widthAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func setNext() { onSetNext?() }
    @objc private func pullBack() { onPullBack?() }
    @objc private func remove() { onRemove?() }

    @objc private func showRebindMenu(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func makeRebindMenu() -> NSMenu {
        let menu = NSMenu()
        let original = NSMenuItem(
            title: "按原上下文发送",
            action: #selector(rebindWithOriginalContext),
            keyEquivalent: ""
        )
        original.target = self
        menu.addItem(original)
        let current = NSMenuItem(
            title: "绑定到当前会话上下文",
            action: #selector(rebindToCurrentContext),
            keyEquivalent: ""
        )
        current.target = self
        menu.addItem(current)
        return menu
    }

    @objc private func rebindWithOriginalContext() {
        onRebind?(.sendWithOriginalContext)
    }

    @objc private func rebindToCurrentContext() {
        onRebind?(.bindToCurrentSessionContext)
    }
}
