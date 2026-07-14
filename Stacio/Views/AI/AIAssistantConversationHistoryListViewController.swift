import AppKit
import ObjectiveC

public final class AIAssistantConversationHistoryListViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate {
    public var onRestoreConversation: ((String, [AIConversationHistoryItemRecord]) -> Void)?
    public var confirmDeletion: ((AIConversationHistoryConversationSummary) -> Bool)?
    public var confirmClearAll: (() -> Bool)?

    private let store: AIAssistantConversationHistoryBrowsing
    private var summaries: [AIConversationHistoryConversationSummary] = []
    private var searchQuery = ""

    private let searchField = NSSearchField()
    private let clearAllButton = NSButton(title: "清空全部历史", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(labelWithString: "暂无历史对话")

    public init(store: AIAssistantConversationHistoryBrowsing) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)
        container.setAccessibilityIdentifier("Stacio.AI.history")

        searchField.placeholderString = "搜索历史对话"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier("Stacio.AI.history.search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSearchField(searchField)

        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllPressed(_:))
        clearAllButton.setAccessibilityIdentifier("Stacio.AI.history.clearAll")
        clearAllButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(clearAllButton)

        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityIdentifier("Stacio.AI.history.summary")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("Stacio.AI.history.scroll")

        tableView.headerView = nil
        tableView.rowHeight = 68
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = contextMenu()
        tableView.setAccessibilityIdentifier("Stacio.AI.history.table")
        scrollView.documentView = tableView

        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.setAccessibilityIdentifier("Stacio.AI.history.empty")

        container.addSubview(searchField)
        container.addSubview(clearAllButton)
        container.addSubview(summaryLabel)
        container.addSubview(scrollView)
        container.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: clearAllButton.leadingAnchor, constant: -8),

            clearAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            clearAllButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            clearAllButton.heightAnchor.constraint(equalToConstant: 28),
            clearAllButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

            summaryLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: clearAllButton.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24)
        ])

        view = container
        reloadSummaries()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        summaries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard summaries.indices.contains(row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("AIConversationHistoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? AIConversationHistoryCellView)
            ?? AIConversationHistoryCellView(identifier: identifier)
        cell.configure(summary: summaries[row], searchQuery: searchQuery)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        selectConversation(at: tableView.selectedRow)
    }

    @objc
    private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        reloadSummaries()
    }

    @objc
    private func clearAllPressed(_ sender: Any?) {
        clearAllHistory()
    }

    @objc
    private func deleteMenuItemPressed(_ sender: NSMenuItem) {
        deleteConversation(at: contextMenuRow(for: sender))
    }

    private func reloadSummaries() {
        do {
            summaries = try store.listConversationSummaries(searchQuery: searchQuery)
        } catch {
            summaries = []
        }
        tableView.reloadData()
        tableView.isHidden = summaries.isEmpty
        emptyStateLabel.isHidden = summaries.isEmpty == false
        summaryLabel.stringValue = summaryText()
        clearAllButton.isEnabled = summaries.isEmpty == false || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func summaryText() -> String {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(summaries.count) 条历史对话"
        }
        return "\(summaries.count) 条匹配结果"
    }

    private func selectConversation(at row: Int) {
        guard summaries.indices.contains(row) else {
            return
        }
        let runtimeID = summaries[row].runtimeID
        do {
            let records = try store.listConversationHistory(runtimeID: runtimeID)
            onRestoreConversation?(runtimeID, records)
        } catch {
            onRestoreConversation?(runtimeID, [])
        }
    }

    private func deleteConversation(at row: Int) {
        guard summaries.indices.contains(row) else {
            return
        }
        let summary = summaries[row]
        guard confirmDeletion?(summary) ?? presentDeleteConfirmation(summary) else {
            return
        }
        do {
            try store.deleteConversationHistory(runtimeID: summary.runtimeID)
            reloadSummaries()
        } catch {
            return
        }
    }

    private func clearAllHistory() {
        guard confirmClearAll?() ?? presentClearAllConfirmation() else {
            return
        }
        do {
            try store.clearConversationHistory()
            reloadSummaries()
        } catch {
            return
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "AI 历史")
        let deleteItem = NSMenuItem(title: "删除", action: #selector(deleteMenuItemPressed(_:)), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)
        return menu
    }

    private func contextMenuRow(for item: NSMenuItem) -> Int {
        let clickedRow = tableView.clickedRow
        if summaries.indices.contains(clickedRow) {
            return clickedRow
        }
        return tableView.selectedRow
    }

    private func presentDeleteConfirmation(_ summary: AIConversationHistoryConversationSummary) -> Bool {
        let alert = NSAlert()
        alert.messageText = "删除这条历史对话？"
        alert.informativeText = summary.firstUserMessagePreview.isEmpty ? "删除后无法恢复。" : "\(summary.firstUserMessagePreview)\n删除后无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentClearAllConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "清空全部 AI 历史？"
        alert.informativeText = "所有本机 AI 历史对话都会从 SQLite 删除，操作无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var visibleRuntimeIDsForTesting: [String] {
        summaries.map(\.runtimeID)
    }

    func visibleTitleForTesting(at index: Int) -> String {
        guard summaries.indices.contains(index) else { return "" }
        return summaries[index].firstUserMessagePreview
    }

    func visibleDetailForTesting(at index: Int) -> String {
        guard summaries.indices.contains(index) else { return "" }
        return AIConversationHistoryCellView.detailText(for: summaries[index])
    }

    func visibleMatchedSnippetForTesting(at index: Int) -> String {
        guard summaries.indices.contains(index) else { return "" }
        return summaries[index].matchedSnippet ?? ""
    }

    func visibleAttributedTitleForTesting(at index: Int) -> NSAttributedString {
        guard summaries.indices.contains(index) else { return NSAttributedString(string: "") }
        return AIConversationHistoryTextHighlighter.highlighted(
            summaries[index].firstUserMessagePreview,
            query: searchQuery,
            font: .systemFont(ofSize: 13, weight: .semibold),
            textColor: StacioDesignSystem.theme.primaryTextColor
        )
    }

    func visibleAttributedSnippetForTesting(at index: Int) -> NSAttributedString {
        guard summaries.indices.contains(index) else { return NSAttributedString(string: "") }
        return AIConversationHistoryTextHighlighter.highlighted(
            summaries[index].matchedSnippet ?? "",
            query: searchQuery,
            font: .systemFont(ofSize: 11),
            textColor: StacioDesignSystem.theme.secondaryTextColor
        )
    }

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        searchQuery = query
        reloadSummaries()
    }

    func selectConversationForTesting(at index: Int) {
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func deleteConversationForTesting(at index: Int) {
        deleteConversation(at: index)
    }

    func clearAllHistoryForTesting() {
        clearAllHistory()
    }
}

private final class AIConversationHistoryCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(summary: AIConversationHistoryConversationSummary, searchQuery: String) {
        let title = summary.firstUserMessagePreview.isEmpty ? "无用户消息" : summary.firstUserMessagePreview
        titleLabel.attributedStringValue = AIConversationHistoryTextHighlighter.highlighted(
            title,
            query: searchQuery,
            font: titleLabel.font ?? .systemFont(ofSize: 13, weight: .semibold),
            textColor: StacioDesignSystem.theme.primaryTextColor
        )
        detailLabel.stringValue = Self.detailText(for: summary)
        let snippet = summary.matchedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        snippetLabel.isHidden = snippet.isEmpty
        snippetLabel.attributedStringValue = AIConversationHistoryTextHighlighter.highlighted(
            snippet,
            query: searchQuery,
            font: snippetLabel.font ?? .systemFont(ofSize: 11),
            textColor: StacioDesignSystem.theme.secondaryTextColor
        )
    }

    static func detailText(for summary: AIConversationHistoryConversationSummary) -> String {
        "\(summary.messageCount) 条消息 · \(displayDate(summary.createdAt))"
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(self, color: .clear)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(snippetLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            snippetLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 4),
            snippetLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7)
        ])
    }

    private static func displayDate(_ value: String) -> String {
        if let date = ISO8601DateFormatter().date(from: value) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return value
    }
}

private enum AIConversationHistoryTextHighlighter {
    static func highlighted(
        _ text: String,
        query: String,
        font: NSFont,
        textColor: NSColor
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor
            ]
        )
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            return attributed
        }
        let searchRange = NSRange(location: 0, length: (text as NSString).length)
        var currentLocation = 0
        while currentLocation < searchRange.length {
            let range = (text as NSString).range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: currentLocation, length: searchRange.length - currentLocation)
            )
            if range.location == NSNotFound {
                break
            }
            attributed.addAttributes(
                [
                    .backgroundColor: StacioDesignSystem.theme.accentColor.withAlphaComponent(0.22),
                    .foregroundColor: StacioDesignSystem.theme.primaryTextColor
                ],
                range: range
            )
            currentLocation = range.location + max(range.length, 1)
        }
        return attributed
    }
}

private extension NSView {
    func aiHistoryFirstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.aiHistoryFirstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

private enum AIAssistantHistoryPanelAssociatedKeys {
    static var browserController: UInt8 = 0
    static var browserInstalled: UInt8 = 0
}

extension AIAssistantPanelViewController {
    public func installConversationHistoryBrowser(store: AIAssistantConversationHistoryBrowsing) {
        if objc_getAssociatedObject(self, &AIAssistantHistoryPanelAssociatedKeys.browserInstalled) as? Bool == true {
            return
        }
        guard let header = view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.header"),
              let conversation = view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.conversation")
        else {
            return
        }

        let historyButton = NSButton(title: "历史", target: self, action: #selector(aiHistoryButtonPressed(_:)))
        historyButton.setAccessibilityIdentifier("Stacio.AI.history.button")
        historyButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(historyButton)
        header.addSubview(historyButton)

        let browserController = AIAssistantConversationHistoryListViewController(store: store)
        browserController.onRestoreConversation = { [weak self] runtimeID, _ in
            guard let self else { return }
            self.selectTargetRuntimeForTesting(runtimeID)
            self.aiHistoryHideBrowser()
            self.aiHistoryInsertHistoryDivider()
        }
        addChild(browserController)
        let browserView = browserController.view
        browserView.isHidden = true
        browserView.translatesAutoresizingMaskIntoConstraints = false
        browserView.setAccessibilityIdentifier("Stacio.AI.history.browser")
        conversation.addSubview(browserView)

        NSLayoutConstraint.activate([
            historyButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -46),
            historyButton.centerYAnchor.constraint(equalTo: header.topAnchor, constant: 23),
            historyButton.heightAnchor.constraint(equalToConstant: 28),
            historyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),

            browserView.leadingAnchor.constraint(equalTo: conversation.leadingAnchor),
            browserView.trailingAnchor.constraint(equalTo: conversation.trailingAnchor),
            browserView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            browserView.bottomAnchor.constraint(equalTo: conversation.bottomAnchor)
        ])

        objc_setAssociatedObject(
            self,
            &AIAssistantHistoryPanelAssociatedKeys.browserController,
            browserController,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        objc_setAssociatedObject(
            self,
            &AIAssistantHistoryPanelAssociatedKeys.browserInstalled,
            true,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    @objc
    private func aiHistoryButtonPressed(_ sender: NSButton) {
        guard let controller = objc_getAssociatedObject(
            self,
            &AIAssistantHistoryPanelAssociatedKeys.browserController
        ) as? AIAssistantConversationHistoryListViewController else {
            return
        }
        controller.view.isHidden.toggle()
        let showsHistory = controller.view.isHidden == false
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.transcriptScroll")?.isHidden = showsHistory
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.localAgent")?.isHidden = true
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.surfaceMode")?.isHidden = showsHistory
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.composer")?.isHidden = showsHistory
    }

    private func aiHistoryHideBrowser() {
        guard let controller = objc_getAssociatedObject(
            self,
            &AIAssistantHistoryPanelAssociatedKeys.browserController
        ) as? AIAssistantConversationHistoryListViewController else {
            return
        }
        controller.view.isHidden = true
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.transcriptScroll")?.isHidden = false
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.surfaceMode")?.isHidden = false
        view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.composer")?.isHidden = false
    }

    private func aiHistoryInsertHistoryDivider() {
        guard let transcriptStack = view.aiHistoryFirstSubview(withIdentifier: "Stacio.AI.transcript") as? NSStackView else {
            return
        }
        transcriptStack.arrangedSubviews
            .filter { $0.accessibilityIdentifier() == "Stacio.AI.history.divider" }
            .forEach { view in
                transcriptStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        let divider = NSTextField(labelWithString: "以下是历史对话记录")
        divider.font = .systemFont(ofSize: 11, weight: .medium)
        divider.textColor = StacioDesignSystem.theme.secondaryTextColor
        divider.alignment = .center
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setAccessibilityIdentifier("Stacio.AI.history.divider")
        transcriptStack.insertArrangedSubview(divider, at: 0)
        divider.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
    }
}
