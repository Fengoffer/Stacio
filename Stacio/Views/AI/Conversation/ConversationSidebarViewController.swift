import AppKit
import Foundation

// MARK: - Conversation Sidebar（P6-5）

/// 会话运行状态（系统状态符号 + 文字，不只依赖颜色）。
public enum ConversationRunState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case paused
    case waitingCapacity
    case waitingApproval
    case waitingUser
    case takenOver
    case failed

    /// SF Symbol 名称（系统状态符号）。
    public var systemSymbol: String {
        switch self {
        case .idle: return "circle"
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle"
        case .waitingCapacity: return "hourglass"
        case .waitingApproval: return "hand.raised.circle"
        case .waitingUser: return "person.crop.circle"
        case .takenOver: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    public var displayText: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .waitingCapacity: return "等待容量"
        case .waitingApproval: return "等待审批"
        case .waitingUser: return "等待用户"
        case .takenOver: return "已接管"
        case .failed: return "失败"
        }
    }
}

/// 会话列表条目：标题/目标主机/Runtime/更新时间/运行状态/未读。
public struct ConversationListEntry: Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let targetHost: String
    public let runtimeLabel: String
    public let updatedAt: Date
    public let runState: ConversationRunState
    public let unread: Bool
    public let pinned: Bool
    public let archived: Bool

    public init(
        sessionID: String, title: String, targetHost: String, runtimeLabel: String,
        updatedAt: Date, runState: ConversationRunState, unread: Bool, pinned: Bool,
        archived: Bool = false
    ) {
        self.sessionID = sessionID
        self.title = title
        self.targetHost = targetHost
        self.runtimeLabel = runtimeLabel
        self.updatedAt = updatedAt
        self.runState = runState
        self.unread = unread
        self.pinned = pinned
        self.archived = archived
    }

    public init(catalogEntry: ConversationSessionCatalogEntry, unread: Bool = false) {
        let session = catalogEntry.session
        let runtimeLabel: String
        switch session.runtimeSelection.kind {
        case .nativeAPI:
            runtimeLabel = session.runtimeSelection.modelID.map { "Native · \($0)" } ?? "Native API"
        case .localAgent:
            runtimeLabel = session.runtimeSelection.localAgentConfigurationID
                .map { "Stacio Agent · \($0)" } ?? "Stacio Agent"
        }
        self.init(
            sessionID: session.id,
            title: session.title,
            targetHost: session.targetBinding.remoteIdentity,
            runtimeLabel: runtimeLabel,
            updatedAt: catalogEntry.updatedAt,
            runState: Self.runState(
                phase: catalogEntry.latestAttemptPhase,
                corrupted: catalogEntry.isCorrupted
            ),
            unread: unread,
            pinned: session.isPinned == true,
            archived: session.archivedAt != nil
        )
    }

    private static func runState(phase: AttemptPhase?, corrupted: Bool) -> ConversationRunState {
        if corrupted { return .failed }
        guard let phase else { return .idle }
        switch phase {
        case .preparing, .startingRuntime, .streaming, .toolProposed, .executingTool, .pausing,
             .stopping:
            return .running
        case .waitingForCapacity:
            return .waitingCapacity
        case .awaitingApproval:
            return .waitingApproval
        case .awaitingUser:
            return .waitingUser
        case .paused:
            return .paused
        case .takeoverPending, .takenOver:
            return .takenOver
        case .failed, .interruptedByRelaunch:
            return .failed
        case .completed, .cancelled, .passthroughInputDelivered:
            return .idle
        }
    }
}

public enum ConversationSidebarAction {

    /// 搜索（标题/目标主机/runtime 匹配）。
    public static func search(_ entries: [ConversationListEntry], query: String) -> [ConversationListEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.targetHost.localizedCaseInsensitiveContains(trimmed)
                || $0.runtimeLabel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public static func togglePin(_ entries: [ConversationListEntry], sessionID: String) -> [ConversationListEntry] {
        entries.map { entry in
            guard entry.sessionID == sessionID else { return entry }
            return ConversationListEntry(
                sessionID: entry.sessionID, title: entry.title, targetHost: entry.targetHost,
                runtimeLabel: entry.runtimeLabel, updatedAt: entry.updatedAt,
                runState: entry.runState, unread: entry.unread, pinned: !entry.pinned,
                archived: entry.archived
            )
        }
    }

    public static func rename(_ entries: [ConversationListEntry], sessionID: String, newTitle: String) -> [ConversationListEntry] {
        entries.map { entry in
            guard entry.sessionID == sessionID else { return entry }
            return ConversationListEntry(
                sessionID: entry.sessionID, title: newTitle, targetHost: entry.targetHost,
                runtimeLabel: entry.runtimeLabel, updatedAt: entry.updatedAt,
                runState: entry.runState, unread: entry.unread, pinned: entry.pinned,
                archived: entry.archived
            )
        }
    }

    public static func archive(_ entries: [ConversationListEntry], sessionID: String) -> [ConversationListEntry] {
        entries.filter { $0.sessionID != sessionID }
    }

    public static func markUnread(_ entries: [ConversationListEntry], sessionID: String, unread: Bool) -> [ConversationListEntry] {
        entries.map { entry in
            guard entry.sessionID == sessionID else { return entry }
            return ConversationListEntry(
                sessionID: entry.sessionID, title: entry.title, targetHost: entry.targetHost,
                runtimeLabel: entry.runtimeLabel, updatedAt: entry.updatedAt,
                runState: entry.runState, unread: unread, pinned: entry.pinned,
                archived: entry.archived
            )
        }
    }

    /// 侧栏不提供跨会话插队或拖动全局顺序（会话列表顺序由会话存储决定）。
    public static func crossSessionReorderAvailable() -> Bool { false }
}

@MainActor
public final class ConversationSidebarViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    public var onSelect: ((String) -> Void)?
    public var onTogglePin: ((String, Bool) -> Void)?
    public var onRename: ((String, String) -> Void)?
    public var onArchive: ((String, Bool) -> Void)?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "没有会话")
    private var allEntries: [ConversationListEntry] = []
    private var visibleEntries: [ConversationListEntry] = []
    private var selectedSessionID: String?
    private var includesArchived = false
    private var shouldFocusSearchOnAppearance = false

    var visibleSessionIDsForTesting: [String] { visibleEntries.map(\.sessionID) }

    public override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .withinWindow
        root.state = .followsWindowActiveState
        root.setAccessibilityIdentifier("Stacio.AI.conversationNavigator")
        view = root
        configureView()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if shouldFocusSearchOnAppearance {
            view.window?.makeFirstResponder(searchField)
            shouldFocusSearchOnAppearance = false
        }
    }

    public func configure(
        entries: [ConversationListEntry],
        selectedSessionID: String?,
        includesArchived: Bool,
        focusSearch: Bool
    ) {
        allEntries = entries
        self.selectedSessionID = selectedSessionID
        self.includesArchived = includesArchived
        shouldFocusSearchOnAppearance = focusSearch
        applyFilter()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ConversationSidebarRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self)
            as? ConversationSidebarRowView) ?? ConversationSidebarRowView()
        rowView.identifier = identifier
        rowView.apply(visibleEntries[row])
        return rowView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard visibleEntries.indices.contains(row) else { return }
        let sessionID = visibleEntries[row].sessionID
        selectedSessionID = sessionID
        onSelect?(sessionID)
    }

    public func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        guard let entry = actionEntry else { return }
        menu.item(withTag: 1)?.title = entry.pinned ? "取消固定" : "固定"
        menu.item(withTag: 3)?.title = entry.archived ? "移出归档" : "归档"
    }

    private func configureView() {
        searchField.placeholderString = "搜索标题、目标或 Runtime"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("搜索排查助手会话")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(renameSelected)
        tableView.target = self
        tableView.setAccessibilityLabel("排查助手会话")

        let menu = NSMenu()
        let pin = menu.addItem(withTitle: "固定", action: #selector(togglePin), keyEquivalent: "")
        pin.tag = 1
        let rename = menu.addItem(withTitle: "重命名…", action: #selector(renameSelected), keyEquivalent: "")
        rename.tag = 2
        let archive = menu.addItem(withTitle: "归档", action: #selector(toggleArchive), keyEquivalent: "")
        archive.tag = 3
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        applyFilter()
    }

    private func applyFilter() {
        guard isViewLoaded else { return }
        let candidates = allEntries.filter { includesArchived || $0.archived == false }
        visibleEntries = ConversationSidebarAction.search(candidates, query: searchField.stringValue)
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.sessionID < $1.sessionID
            }
        tableView.reloadData()
        emptyLabel.isHidden = visibleEntries.isEmpty == false
        if let selectedSessionID,
           let row = visibleEntries.firstIndex(where: { $0.sessionID == selectedSessionID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private var actionEntry: ConversationListEntry? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard visibleEntries.indices.contains(row) else { return nil }
        return visibleEntries[row]
    }

    @objc private func togglePin() {
        guard let entry = actionEntry else { return }
        onTogglePin?(entry.sessionID, !entry.pinned)
    }

    @objc private func renameSelected() {
        guard let entry = actionEntry else { return }
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.informativeText = "标题仅加密保存在本机的排查助手会话库中。"
        let field = NSTextField(string: entry.title)
        field.placeholderString = "会话标题"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        onRename?(entry.sessionID, title)
    }

    @objc private func toggleArchive() {
        guard let entry = actionEntry else { return }
        onArchive?(entry.sessionID, !entry.archived)
    }
}

@MainActor
private final class ConversationSidebarRowView: NSTableCellView {
    private let statusImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func apply(_ entry: ConversationListEntry) {
        statusImage.image = NSImage(
            systemSymbolName: entry.runState.systemSymbol,
            accessibilityDescription: entry.runState.displayText
        )
        titleLabel.stringValue = entry.title
        titleLabel.font = .systemFont(ofSize: 13, weight: entry.unread ? .semibold : .regular)
        detailLabel.stringValue = "\(entry.targetHost) · \(entry.runtimeLabel)"
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        trailingLabel.stringValue = relative.localizedString(for: entry.updatedAt, relativeTo: Date())
        toolTip = "\(entry.title)\n\(entry.targetHost)\n\(entry.runtimeLabel)\n\(entry.runState.displayText)"
        setAccessibilityLabel("\(entry.title)，\(entry.targetHost)，\(entry.runState.displayText)")
    }

    private func configureView() {
        statusImage.contentTintColor = .secondaryLabelColor
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingLabel.font = .systemFont(ofSize: 10)
        trailingLabel.textColor = .tertiaryLabelColor
        trailingLabel.alignment = .right
        trailingLabel.translatesAutoresizingMaskIntoConstraints = false
        [statusImage, titleLabel, detailLabel, trailingLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 16),
            statusImage.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -6),
            trailingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            trailingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
        ])
    }
}
