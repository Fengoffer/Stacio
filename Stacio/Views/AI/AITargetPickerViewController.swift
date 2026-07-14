import AppKit

public final class AITargetPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public var onSelectRuntimeID: ((String) -> Void)?

    private let sessions: [AgentTerminalSessionSummary]
    private var filteredSessions: [AgentTerminalSessionSummary]
    private var searchQuery = ""
    private let searchField = NSSearchField()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: L10n.AI.noMatchingTargets)
    private let tableView = NSTableView()

    public init(sessions: [AgentTerminalSessionSummary]) {
        let sortedSessions = Self.sortedSessions(sessions)
        self.sessions = sortedSessions
        self.filteredSessions = sortedSessions
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

        searchField.placeholderString = L10n.AI.targetSearchPlaceholder
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier("Stacio.AI.targetPicker.search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSearchField(searchField)

        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setAccessibilityIdentifier("Stacio.AI.targetPicker.summary")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.AI.targetPicker.table")
        scrollView.documentView = tableView

        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.setAccessibilityIdentifier("Stacio.AI.targetPicker.empty")

        container.addSubview(searchField)
        container.addSubview(summaryLabel)
        container.addSubview(scrollView)
        container.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 360),
            container.heightAnchor.constraint(equalToConstant: 320),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            summaryLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
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
        applyFilter()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filteredSessions.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredSessions.indices.contains(row) else {
            return nil
        }
        let session = filteredSessions[row]
        let identifier = NSUserInterfaceItemIdentifier("AITargetCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? AITargetPickerCellView)
            ?? AITargetPickerCellView(identifier: identifier)
        cell.configure(with: session, text: displayText(for: session))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard filteredSessions.indices.contains(row) else {
            return
        }
        onSelectRuntimeID?(filteredSessions[row].runtimeID)
    }

    @objc
    private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        applyFilter()
    }

    private func applyFilter() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredSessions = sessions
        } else {
            filteredSessions = sessions.filter { searchableText(for: $0).contains(query) }
        }
        tableView.reloadData()
        emptyStateLabel.isHidden = filteredSessions.isEmpty == false
        tableView.isHidden = filteredSessions.isEmpty
        summaryLabel.stringValue = "\(filteredSessions.count)/\(sessions.count) \(L10n.AI.targetSearchSummary)"
    }

    private static func sortedSessions(_ sessions: [AgentTerminalSessionSummary]) -> [AgentTerminalSessionSummary] {
        sessions.enumerated().sorted { lhs, rhs in
            if lhs.element.isCurrent != rhs.element.isCurrent {
                return lhs.element.isCurrent
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func searchableText(for session: AgentTerminalSessionSummary) -> String {
        [
            session.runtimeID,
            session.title,
            session.kind,
            session.environment,
            session.currentDirectory,
            session.subtitle,
            session.isCurrent ? L10n.AI.currentTarget : nil
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    private func displayText(for session: AgentTerminalSessionSummary) -> String {
        let subtitle = session.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = session.environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPrefix = session.isCurrent ? "\(L10n.AI.currentTarget) · " : ""
        let detail = [subtitle, environment.isEmpty ? nil : environment]
            .compactMap { value -> String? in
                guard let value, value.isEmpty == false else { return nil }
                return value
            }
            .joined(separator: " · ")
        if detail.isEmpty {
            return "\(currentPrefix)\(session.title)"
        }
        return "\(currentPrefix)\(session.title) · \(detail)"
    }

    func selectRuntimeForTesting(_ runtimeID: String) {
        guard let index = filteredSessions.firstIndex(where: { $0.runtimeID == runtimeID }) else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        onSelectRuntimeID?(runtimeID)
    }

    var visibleRuntimeIDsForTesting: [String] {
        filteredSessions.map(\.runtimeID)
    }

    var summaryTextForTesting: String {
        summaryLabel.stringValue
    }

    var emptyStateIsVisibleForTesting: Bool {
        emptyStateLabel.isHidden == false
    }

    var emptyStateTextForTesting: String {
        emptyStateLabel.stringValue
    }

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        searchQuery = query
        applyFilter()
    }

    func visibleRowTextForTesting(at index: Int) -> String {
        guard filteredSessions.indices.contains(index) else {
            return ""
        }
        return displayText(for: filteredSessions[index])
    }
}

private final class AITargetPickerCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with session: AgentTerminalSessionSummary, text: String) {
        titleLabel.font = .systemFont(ofSize: 13, weight: session.isCurrent ? .semibold : .regular)
        titleLabel.stringValue = session.isCurrent ? "\(L10n.AI.currentTarget) · \(session.title)" : session.title
        let details = [
            session.subtitle,
            session.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : session.environment,
            session.runtimeID
        ]
            .compactMap { value -> String? in
                guard let value,
                      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else {
                    return nil
                }
                return value
            }
        detailLabel.stringValue = details.joined(separator: " · ")
        setAccessibilityLabel(text)
    }

    private func setup() {
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6)
        ])
    }
}
