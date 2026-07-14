import AppKit
import StacioCoreBindings

public enum TransferQueueAction: Equatable {
    case retry
    case pause
    case resume
    case restart
    case stop

    fileprivate init?(label: String) {
        switch label {
        case L10n.Transfers.retry:
            self = .retry
        case L10n.Transfers.pause:
            self = .pause
        case L10n.Transfers.resume:
            self = .resume
        case L10n.Transfers.restart:
            self = .restart
        case L10n.Transfers.stop:
            self = .stop
        default:
            return nil
        }
    }

    fileprivate var label: String {
        switch self {
        case .retry:
            L10n.Transfers.retry
        case .pause:
            L10n.Transfers.pause
        case .resume:
            L10n.Transfers.resume
        case .restart:
            L10n.Transfers.restart
        case .stop:
            L10n.Transfers.stop
        }
    }
}

@MainActor
public final class TransferQueueViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let tableView = NSTableView()
    public var onTransferAction: ((TransferQueueAction, String) -> Void)?
    public var onClearFinished: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: L10n.Transfers.title)
    private let engineLabel = NSTextField(labelWithString: L10n.Transfers.engine)
    private let emptyLabel = NSTextField(labelWithString: L10n.Transfers.empty)
    private let summaryLabel = NSTextField(labelWithString: L10n.Transfers.empty)
    private let clearFinishedButton = NSButton()
    private let actionStrip = NSStackView()
    private let primaryActionButton = NSButton()
    private let secondaryActionButton = NSButton()
    private let detailTitleLabel = NSTextField(labelWithString: L10n.Transfers.detailTitle)
    private let detailTextView = NSTextView()
    private var rows: [TransferRow] = []
    private var samplesByJobID: [String: TransferSample] = [:]
    private let nowProvider: () -> Date

    public init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var transferCount: Int {
        rows.count
    }

    public var latestStatusText: String {
        rows.last?.status ?? L10n.Transfers.empty
    }

    public var engineSummaryText: String {
        engineLabel.stringValue
    }

    public var visibleTextSnapshot: String {
        var values = [titleLabel.stringValue, engineLabel.stringValue]
        if rows.isEmpty {
            values.append(emptyLabel.stringValue)
        }
        values.append(contentsOf: rows.flatMap(\.visibleValues))
        values.append(selectedTransferDetailTextForTesting)
        return values.joined(separator: "\n")
    }

    public var selectedTransferDetailTextForTesting: String {
        detailTextView.string
    }

    public var snapshotForTesting: TransferQueueSnapshot {
        TransferQueueSnapshot(rows: rows.map { row in
            TransferQueueSnapshot.Row(
                jobID: row.jobID,
                direction: row.direction == L10n.Transfers.upload ? .upload : .download,
                sourcePath: row.sourcePath,
                destinationPath: row.destinationPath,
                bytesDone: 0,
                bytesTotal: 0,
                rawStatus: row.rawStatus,
                diagnostic: row.detailText.isEmpty ? nil : row.detailText
            )
        })
    }

    public var transferActionLabels: [String] {
        actionStrip.arrangedSubviews.compactMap { view in
            (view as? NSButton)?.accessibilityLabel()
        }
    }

    public func performTransferActionForTesting(at index: Int) {
        guard actionStrip.arrangedSubviews.indices.contains(index),
              let button = actionStrip.arrangedSubviews[index] as? NSButton
        else {
            return
        }
        performTransferAction(button)
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        engineLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        engineLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        engineLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        configureClearFinishedButton()

        actionStrip.orientation = .horizontal
        actionStrip.alignment = .centerY
        actionStrip.spacing = 6
        actionStrip.translatesAutoresizingMaskIntoConstraints = false

        tableView.addTableColumn(makeColumn(identifier: "direction", title: "方向", width: 42))
        tableView.addTableColumn(makeColumn(identifier: "file", title: "文件", width: 100))
        tableView.addTableColumn(makeColumn(identifier: "progress", title: "进度", width: 94))
        tableView.addTableColumn(makeColumn(identifier: "status", title: "状态", width: 54))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.Transfers.queueTable")
        tableView.setAccessibilityLabel(L10n.Transfers.queue)
        StacioDesignSystem.styleTable(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        detailTitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        detailTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        detailTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.drawsBackground = false
        detailTextView.textColor = StacioDesignSystem.theme.secondaryTextColor
        detailTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailTextView.textContainerInset = NSSize(width: 0, height: 0)
        detailTextView.textContainer?.lineFragmentPadding = 0
        detailTextView.setAccessibilityIdentifier("Stacio.Transfers.detailText")
        detailTextView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("Stacio.Transfers.empty")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [titleLabel, NSView(), clearFinishedButton, actionStrip])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let summaryRow = NSStackView(views: [engineLabel, summaryLabel])
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = 8
        summaryRow.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [titleRow, summaryRow])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 5
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setAccessibilityIdentifier("Stacio.Transfers.header")

        detailTitleLabel.setAccessibilityIdentifier("Stacio.Transfers.detailTitle")

        container.addSubview(headerStack)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(detailTitleLabel)
        container.addSubview(detailTextView)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            titleRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            summaryRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor),

            clearFinishedButton.widthAnchor.constraint(equalToConstant: 28),
            clearFinishedButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            scrollView.heightAnchor.constraint(equalToConstant: 150),
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: detailTitleLabel.topAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            detailTitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            detailTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            detailTitleLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 16),

            detailTextView.leadingAnchor.constraint(equalTo: detailTitleLabel.leadingAnchor),
            detailTextView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            detailTextView.topAnchor.constraint(equalTo: detailTitleLabel.bottomAnchor, constant: 6),
            detailTextView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            detailTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])

        updateEmptyState()
        updateDetailInspector()
        view = container
    }

    private func configureClearFinishedButton() {
        clearFinishedButton.image = actionImage(systemName: "checkmark.circle", label: L10n.Transfers.clearFinished)
        clearFinishedButton.bezelStyle = .texturedRounded
        clearFinishedButton.imagePosition = .imageOnly
        clearFinishedButton.toolTip = L10n.Transfers.clearFinished
        clearFinishedButton.setAccessibilityIdentifier("Stacio.Transfers.clearFinished")
        clearFinishedButton.setAccessibilityLabel(L10n.Transfers.clearFinished)
        clearFinishedButton.target = self
        clearFinishedButton.action = #selector(clearFinishedTransfers)
        clearFinishedButton.translatesAutoresizingMaskIntoConstraints = false
        clearFinishedButton.isEnabled = false
        StacioDesignSystem.styleIconButton(clearFinishedButton)
    }

    public func setTransfers(
        jobs: [ScpTransferJob],
        progressEvents: [ScpTransferProgress],
        diagnosticsByJobID: [String: String] = [:],
        eventLogsByJobID: [String: [TransferEventLogEntry]] = [:]
    ) {
        let selectedJobID = rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].jobID : nil
        let progressByJob = Dictionary(grouping: progressEvents, by: \.jobId)
        let now = nowProvider()
        rows = jobs.map { job in
            let latest = progressByJob[job.id]?.last
            let metric = metric(for: job, latestProgress: latest, now: now)
            let logEntries = eventLogsByJobID[job.id] ?? Self.logEntries(
                for: job,
                progressEvents: progressByJob[job.id] ?? []
            )
            return TransferRow(
                job: job,
                latestProgress: latest,
                metric: metric,
                detailText: diagnosticsByJobID[job.id] ?? "",
                logEntries: logEntries
            )
        }
        tableView.reloadData()
        restoreSelection(jobID: selectedJobID)
        updateActionStrip()
        updateEmptyState()
        updateDetailInspector()
    }

    public func setProgressEvents(_ progressEvents: [ScpTransferProgress]) {
        var seenJobIDs = Set<String>()
        let jobs = progressEvents.reversed().compactMap { progress -> ScpTransferJob? in
            guard seenJobIDs.insert(progress.jobId).inserted else {
                return nil
            }

            return ScpTransferJob(
                id: progress.jobId,
                direction: .upload,
                sourcePath: progress.jobId,
                destinationPath: "",
                bytesTotal: progress.bytesTotal
            )
        }
        setTransfers(jobs: jobs.reversed(), progressEvents: progressEvents)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("TransferCell.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = StacioDesignSystem.theme.primaryTextColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = rows[row].value(for: tableColumn.identifier.rawValue)
        cell.textField = textField

        if textField.superview == nil {
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetailInspector()
        updateActionButtonStates()
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = min(width, 44)
        column.resizingMask = .userResizingMask
        return column
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
        summaryLabel.stringValue = rows.isEmpty
            ? L10n.Transfers.empty
            : "\(rows.count) 个任务 · \(rows.last?.status ?? L10n.Transfers.empty)"
    }

    private func updateDetailInspector() {
        guard rows.indices.contains(tableView.selectedRow) else {
            detailTextView.string = L10n.Transfers.detailEmpty
            return
        }

        detailTextView.string = rows[tableView.selectedRow].detailInspectorText
    }

    private func restoreSelection(jobID: String?) {
        guard let jobID,
              let rowIndex = rows.firstIndex(where: { $0.jobID == jobID })
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
    }

    private func updateActionStrip() {
        if actionStrip.arrangedSubviews.isEmpty {
            actionStrip.addArrangedSubview(configuredActionButton(primaryActionButton, label: L10n.Transfers.pause))
            actionStrip.addArrangedSubview(configuredActionButton(secondaryActionButton, label: L10n.Transfers.stop))
        }
        clearFinishedButton.isEnabled = rows.contains(where: \.isFinished)
        updateActionButtonStates()
    }

    private func configuredActionButton(_ button: NSButton, label: String) -> NSButton {
        button.target = self
        button.action = #selector(performTransferAction(_:))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        update(button: button, label: label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        StacioDesignSystem.styleIconButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    private func updateActionButtonStates() {
        let selectedRow = rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow] : nil
        update(button: primaryActionButton, label: selectedRow?.primaryActionLabel ?? L10n.Transfers.pause)
        update(button: secondaryActionButton, label: selectedRow?.secondaryActionLabel ?? L10n.Transfers.stop)
        primaryActionButton.isEnabled = selectedRow?.primaryAction != nil
        secondaryActionButton.isEnabled = selectedRow?.secondaryAction != nil
    }

    @objc private func performTransferAction(_ sender: NSButton) {
        guard let label = sender.accessibilityLabel(),
              rows.indices.contains(tableView.selectedRow)
        else {
            return
        }
        let row = rows[tableView.selectedRow]
        guard let action = TransferQueueAction(label: label) else {
            return
        }
        guard row.supports(action) else {
            return
        }
        onTransferAction?(action, row.jobID)
    }

    private func actionImage(named label: String) -> NSImage {
        let systemName = switch label {
        case L10n.Transfers.retry:
            "arrow.clockwise"
        case L10n.Transfers.resume:
            "play.fill"
        case L10n.Transfers.restart:
            "arrow.counterclockwise"
        case L10n.Transfers.stop:
            "stop.fill"
        default:
            "pause.fill"
        }
        return actionImage(systemName: systemName, label: label)
    }

    private func update(button: NSButton, label: String) {
        button.image = actionImage(named: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func actionImage(systemName: String, label: String) -> NSImage {
        if #available(macOS 11.0, *) {
            if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: label) {
                return image
            }
        }
        return NSImage(size: NSSize(width: 14, height: 14))
    }

    @objc private func clearFinishedTransfers() {
        onClearFinished?()
    }

    private func metric(
        for job: ScpTransferJob,
        latestProgress: ScpTransferProgress?,
        now: Date
    ) -> TransferMetric {
        guard let latestProgress,
              latestProgress.status == "running",
              latestProgress.bytesDone > 0
        else {
            samplesByJobID[job.id] = latestProgress.map {
                TransferSample(bytesDone: $0.bytesDone, capturedAt: now, bytesPerSecond: nil)
            }
            return .empty
        }

        let previous = samplesByJobID[job.id]
        var bytesPerSecond = previous?.bytesPerSecond
        if let previous,
           latestProgress.bytesDone > previous.bytesDone
        {
            let elapsed = now.timeIntervalSince(previous.capturedAt)
            if elapsed > 0 {
                bytesPerSecond = Double(latestProgress.bytesDone - previous.bytesDone) / elapsed
            }
        }

        samplesByJobID[job.id] = TransferSample(
            bytesDone: latestProgress.bytesDone,
            capturedAt: now,
            bytesPerSecond: bytesPerSecond
        )

        guard let bytesPerSecond,
              bytesPerSecond > 0
        else {
            return .empty
        }

        let bytesTotal = latestProgress.bytesTotal > 0 ? latestProgress.bytesTotal : job.bytesTotal
        let remainingBytes = bytesTotal > latestProgress.bytesDone ? bytesTotal - latestProgress.bytesDone : 0
        return TransferMetric(
            speedText: TransferRow.formatSpeed(bytesPerSecond: bytesPerSecond),
            etaText: TransferRow.formatETA(seconds: Double(remainingBytes) / bytesPerSecond)
        )
    }

    private static func logEntries(
        for job: ScpTransferJob,
        progressEvents: [ScpTransferProgress]
    ) -> [TransferEventLogEntry] {
        let events = progressEvents.isEmpty
            ? [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 0,
                    bytesTotal: job.bytesTotal,
                    status: "queued"
                )
            ]
            : progressEvents
        return events.map { progress in
            TransferEventLogEntry(
                status: progress.status,
                bytesDone: progress.bytesDone,
                bytesTotal: progress.bytesTotal > 0 ? progress.bytesTotal : job.bytesTotal,
                message: nil,
                createdAt: nil
            )
        }
    }
}

public struct TransferEventLogEntry: Equatable {
    public let status: String
    public let bytesDone: UInt64
    public let bytesTotal: UInt64
    public let message: String?
    public let createdAt: String?

    public init(
        status: String,
        bytesDone: UInt64,
        bytesTotal: UInt64,
        message: String? = nil,
        createdAt: String? = nil
    ) {
        self.status = status
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.message = message
        self.createdAt = createdAt
    }
}

private struct TransferRow {
    let jobID: String
    let direction: String
    let sourcePath: String
    let destinationPath: String
    let progressText: String
    let status: String
    let speedText: String
    let etaText: String
    let detailText: String
    let logEntries: [TransferEventLogEntry]
    let rawStatus: String

    init(
        job: ScpTransferJob,
        latestProgress: ScpTransferProgress?,
        metric: TransferMetric = .empty,
        detailText: String = "",
        logEntries: [TransferEventLogEntry] = []
    ) {
        jobID = job.id
        direction = switch job.direction {
        case .upload: L10n.Transfers.upload
        case .download: L10n.Transfers.download
        }
        sourcePath = job.sourcePath
        destinationPath = job.destinationPath
        let bytesDone = latestProgress?.bytesDone ?? 0
        let bytesTotal = latestProgress?.bytesTotal ?? job.bytesTotal
        rawStatus = latestProgress?.status ?? "queued"
        let baseProgressText = TransferRow.formatProgress(bytesDone: bytesDone, bytesTotal: bytesTotal)
        status = L10n.Transfers.status(rawStatus)
        speedText = metric.speedText
        etaText = metric.etaText
        progressText = rawStatus == "running" && etaText != "-"
            ? "\(baseProgressText) · \(L10n.Transfers.remainingPrefix) \(etaText)"
            : baseProgressText
        self.detailText = detailText
        self.logEntries = logEntries
    }

    var visibleValues: [String] {
        [direction, sourcePath, destinationPath, progressText, status, speedText, etaText, detailText]
    }

    func value(for columnIdentifier: String) -> String {
        switch columnIdentifier {
        case "direction": direction
        case "file": displayPath
        case "source": sourcePath
        case "destination": destinationPath
        case "progress": progressText
        case "status": status
        case "speed": speedText
        case "eta": etaText
        case "detail": detailText
        default: ""
        }
    }

    var detailInspectorText: String {
        let diagnostic = RuntimeDiagnosticFormatter.userMessage(detailText)
        var lines = [
            L10n.Transfers.detailTitle,
            L10n.Transfers.detailJobID,
            jobID,
            L10n.Transfers.detailDirection,
            direction,
            L10n.Transfers.detailStatus,
            status,
            L10n.Transfers.detailProgress,
            progressSummary,
            L10n.Transfers.detailSource,
            sourcePath,
            L10n.Transfers.detailDestination,
            destinationPath
        ]
        if !diagnostic.isEmpty {
            lines.append(L10n.Transfers.detailDiagnostic)
            lines.append(diagnostic)
        }
        lines.append(L10n.Transfers.detailLog)
        lines.append(contentsOf: logLines)
        return lines.joined(separator: "\n")
    }

    private var logLines: [String] {
        guard logEntries.isEmpty == false else {
            return [L10n.Transfers.detailLogEmpty]
        }
        return logEntries.map { entry in
            let status = L10n.Transfers.status(entry.status)
            let progress = Self.formatProgress(bytesDone: entry.bytesDone, bytesTotal: entry.bytesTotal)
            let timestamp = entry.createdAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prefix = timestamp.isEmpty ? status : "\(timestamp) · \(status)"
            let message = RuntimeDiagnosticFormatter.userMessage(entry.message ?? "")
            return message.isEmpty ? "\(prefix) · \(progress)" : "\(prefix) · \(progress) · \(message)"
        }
    }

    private var displayPath: String {
        let path = direction == L10n.Transfers.upload ? sourcePath : destinationPath
        guard let fileName = path.split(separator: "/").last, !fileName.isEmpty else {
            return path
        }
        return String(fileName)
    }

    private var progressSummary: String {
        guard speedText != "-" else {
            return progressText
        }
        return "\(progressText)  \(speedText)"
    }

    var canRetry: Bool {
        rawStatus == "failed" || rawStatus == "stopped" || rawStatus == "canceled" || rawStatus == "cancelled"
    }

    var canRestart: Bool {
        rawStatus == "paused" || rawStatus == "failed" || rawStatus == "stopped" || rawStatus == "canceled" || rawStatus == "cancelled"
    }

    var canPause: Bool {
        rawStatus == "queued" || rawStatus == "running"
    }

    var canResume: Bool {
        rawStatus == "paused"
    }

    var canStop: Bool {
        rawStatus == "queued" || rawStatus == "running" || rawStatus == "paused"
    }

    var isFinished: Bool {
        Self.finishedStatuses.contains(rawStatus)
    }

    var primaryAction: TransferQueueAction? {
        if canResume {
            return .resume
        }
        if canRetry {
            return .retry
        }
        if canPause {
            return .pause
        }
        return nil
    }

    var secondaryAction: TransferQueueAction? {
        if canRestart {
            return .restart
        }
        if canStop {
            return .stop
        }
        return nil
    }

    var primaryActionLabel: String {
        primaryAction?.label ?? L10n.Transfers.pause
    }

    var secondaryActionLabel: String {
        secondaryAction?.label ?? L10n.Transfers.stop
    }

    func supports(_ action: TransferQueueAction) -> Bool {
        switch action {
        case .retry: canRetry
        case .pause: canPause
        case .resume: canResume
        case .restart: canRestart
        case .stop: canStop
        }
    }

    private static let finishedStatuses = Set(["completed", "failed", "stopped", "canceled", "cancelled"])

    private static func formatProgress(bytesDone: UInt64, bytesTotal: UInt64) -> String {
        guard bytesTotal > 0 else {
            return "0%"
        }
        let percent = min(100, Int((Double(bytesDone) / Double(bytesTotal) * 100).rounded(.down)))
        return "\(percent)%"
    }

    fileprivate static func formatSpeed(bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_024 {
            return "\(Int(bytesPerSecond.rounded())) B/s"
        }
        if bytesPerSecond < 1_024 * 1_024 {
            return "\(formatDecimal(bytesPerSecond / 1_024)) KB/s"
        }
        return "\(formatDecimal(bytesPerSecond / 1_024 / 1_024)) MB/s"
    }

    fileprivate static func formatETA(seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.up)))
        if wholeSeconds < 60 {
            return "\(wholeSeconds) 秒"
        }
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes) 分" : "\(minutes) 分 \(seconds) 秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分"
    }

    private static func formatDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded(.down) == rounded {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}

private struct TransferSample {
    let bytesDone: UInt64
    let capturedAt: Date
    let bytesPerSecond: Double?
}

private struct TransferMetric {
    static let empty = TransferMetric(speedText: "-", etaText: "-")

    let speedText: String
    let etaText: String
}
