import AppKit

public enum TransferCompletionNotificationStatus: Equatable {
    case completed
    case failed
}

public struct TransferCompletionNotificationPayload: Equatable {
    public let jobID: String
    public let runtimeID: String
    public let status: TransferCompletionNotificationStatus
    public let title: String
    public let body: String
    public let itemName: String
    public let byteCount: UInt64
    public let completedAt: Date
    public let duration: TimeInterval
    public let averageBytesPerSecond: Double

    public init(
        jobID: String,
        runtimeID: String,
        status: TransferCompletionNotificationStatus,
        title: String,
        body: String,
        itemName: String = "",
        byteCount: UInt64 = 0,
        completedAt: Date = Date(timeIntervalSince1970: 0),
        duration: TimeInterval = 0,
        averageBytesPerSecond: Double = 0
    ) {
        self.jobID = jobID
        self.runtimeID = runtimeID
        self.status = status
        self.title = title
        self.body = body
        self.itemName = itemName
        self.byteCount = byteCount
        self.completedAt = completedAt
        self.duration = duration
        self.averageBytesPerSecond = averageBytesPerSecond
    }

    public var listRow: TransferCompletionNotificationListRow {
        TransferCompletionNotificationListRow(
            statusText: status == .completed ? L10n.Transfers.completed : L10n.Transfers.failed,
            itemName: itemName.isEmpty ? title : itemName,
            detailText: [
                "\(L10n.Transfers.notificationSize) \(Self.formatByteCount(byteCount))",
                "\(L10n.Transfers.notificationCompletedAt) \(Self.completedAtFormatter.string(from: completedAt))",
                "\(L10n.Transfers.notificationDuration) \(Self.formatDuration(duration))",
                "\(L10n.Transfers.notificationAverageSpeed) \(Self.formatSpeed(averageBytesPerSecond))"
            ].joined(separator: " · ")
        )
    }

    private static func formatByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(duration, 0)
        if seconds < 10, seconds.rounded(.down) != seconds {
            return String(format: "%.1f 秒", seconds)
        }
        let wholeSeconds = Int(seconds.rounded())
        if wholeSeconds < 60 {
            return "\(wholeSeconds) 秒"
        }
        let minutes = wholeSeconds / 60
        let remainingSeconds = wholeSeconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes) 分" : "\(minutes) 分 \(remainingSeconds) 秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分"
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        let speed = max(bytesPerSecond, 0)
        if speed < 1_024 {
            return "\(Int(speed.rounded())) B/s"
        }
        if speed < 1_024 * 1_024 {
            return "\(formatDecimal(speed / 1_024)) KB/s"
        }
        if speed < 1_024 * 1_024 * 1_024 {
            return "\(formatDecimal(speed / 1_024 / 1_024)) MB/s"
        }
        return "\(formatDecimal(speed / 1_024 / 1_024 / 1_024)) GB/s"
    }

    private static func formatDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded(.down) == rounded ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    private static let completedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

public struct TransferCompletionNotificationListRow: Equatable {
    public let statusText: String
    public let itemName: String
    public let detailText: String

    public init(statusText: String, itemName: String, detailText: String) {
        self.statusText = statusText
        self.itemName = itemName
        self.detailText = detailText
    }
}

@MainActor
public protocol TransferCompletionNotificationPresenting: AnyObject {
    func present(_ payload: TransferCompletionNotificationPayload)
    func dismiss(jobID: String)
    func dismiss(runtimeID: String)
    func dismissAll()
}

@MainActor
public final class NoopTransferCompletionNotificationPresenter: TransferCompletionNotificationPresenting {
    public init() {}
    public func present(_ payload: TransferCompletionNotificationPayload) {}
    public func dismiss(jobID: String) {}
    public func dismiss(runtimeID: String) {}
    public func dismissAll() {}
}

@MainActor
public final class TransferCompletionNotificationPresenter: TransferCompletionNotificationPresenting {
    public static let shared = TransferCompletionNotificationPresenter()

    public static func dismissAllForApplicationTermination() {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        guard processName != "xctest",
              processName.hasSuffix("xctest") == false
        else {
            return
        }
        shared.dismissAll()
    }

    private struct PresentedNotification {
        let payload: TransferCompletionNotificationPayload
        let notificationIdentifier: String
    }

    private let notificationDelivery: StacioUserNotificationDelivering
    private var presentedByJobID: [String: PresentedNotification] = [:]
    private var orderedJobIDs: [String] = []
    private var panelController: TransferNotificationPanelController?

    public init(notificationDelivery: StacioUserNotificationDelivering = UserNotificationDelivery.shared) {
        self.notificationDelivery = notificationDelivery
    }

    public var visibleNotificationCountForTesting: Int {
        presentedByJobID.count
    }

    public var visiblePanelCountForTesting: Int {
        panelController == nil ? 0 : 1
    }

    public var visibleListRowsForTesting: [TransferCompletionNotificationListRow] {
        orderedPayloads.map(\.listRow)
    }

    var listGeometryForTesting: (columnWidth: CGFloat, viewportWidth: CGFloat)? {
        panelController?.listGeometryForTesting
    }

    var firstVisibleListRowForTesting: Int? {
        panelController?.firstVisibleRowForTesting
    }

    func scrollCompletionListToBottomForTesting() {
        panelController?.scrollToBottomForTesting()
    }

    public func present(_ payload: TransferCompletionNotificationPayload) {
        let identifier = "Stacio.transfer.\(payload.jobID)"
        if let existing = presentedByJobID[payload.jobID] {
            notificationDelivery.removeNotifications(identifiers: [existing.notificationIdentifier])
        }
        orderedJobIDs.removeAll { $0 == payload.jobID }
        orderedJobIDs.append(payload.jobID)
        notificationDelivery.deliver(StacioUserNotificationPayload(
            identifier: identifier,
            title: payload.title,
            body: payload.body,
            runtimeID: payload.runtimeID,
            retentionPolicy: .explicitRemoval
        ))

        presentedByJobID[payload.jobID] = PresentedNotification(
            payload: payload,
            notificationIdentifier: identifier
        )
        let panelController = ensurePanelController()
        panelController.setPayloads(orderedPayloads)
        panelController.show()
        positionPanel()
    }

    public func dismiss(jobID: String) {
        guard let presented = presentedByJobID.removeValue(forKey: jobID) else { return }
        orderedJobIDs.removeAll { $0 == jobID }
        notificationDelivery.removeNotifications(identifiers: [presented.notificationIdentifier])
        refreshPanelAfterRemoval()
    }

    public func dismiss(runtimeID: String) {
        let jobIDs = orderedJobIDs.filter { presentedByJobID[$0]?.payload.runtimeID == runtimeID }
        for jobID in jobIDs {
            dismiss(jobID: jobID)
        }
    }

    public func dismissAll() {
        let identifiers = orderedJobIDs.compactMap { presentedByJobID[$0]?.notificationIdentifier }
        presentedByJobID = [:]
        orderedJobIDs = []
        panelController?.closeProgrammatically()
        panelController = nil
        notificationDelivery.removeNotifications(identifiers: identifiers)
    }

    private var orderedPayloads: [TransferCompletionNotificationPayload] {
        orderedJobIDs.reversed().compactMap { presentedByJobID[$0]?.payload }
    }

    private func ensurePanelController() -> TransferNotificationPanelController {
        if let panelController {
            return panelController
        }
        let controller = TransferNotificationPanelController()
        controller.onManualClose = { [weak self] in
            self?.didManuallyClosePanel()
        }
        panelController = controller
        return controller
    }

    private func refreshPanelAfterRemoval() {
        guard presentedByJobID.isEmpty == false else {
            panelController?.closeProgrammatically()
            panelController = nil
            return
        }
        panelController?.setPayloads(orderedPayloads)
        positionPanel()
    }

    private func didManuallyClosePanel() {
        let identifiers = orderedJobIDs.compactMap { presentedByJobID[$0]?.notificationIdentifier }
        presentedByJobID = [:]
        orderedJobIDs = []
        panelController = nil
        notificationDelivery.removeNotifications(identifiers: identifiers)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard let panel = panelController?.window else { return }
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 14
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - margin - panel.frame.width,
            y: visibleFrame.maxY - margin - panel.frame.height
        ))
    }
}

@MainActor
private final class TransferNotificationPanelController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    var onManualClose: (() -> Void)?
    private var isClosingProgrammatically = false
    private var payloads: [TransferCompletionNotificationPayload] = []
    private let countLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    var listGeometryForTesting: (columnWidth: CGFloat, viewportWidth: CGFloat)? {
        guard let column = tableView.tableColumns.first else { return nil }
        return (column.width, scrollView.contentView.bounds.width)
    }

    var firstVisibleRowForTesting: Int? {
        guard payloads.isEmpty == false else { return nil }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return nil }
        return visibleRows.location
    }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: Self.panelWidth, height: Self.minimumHeight)
            ),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.Transfers.notificationListTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = StacioDesignSystem.theme.panelBackgroundColor

        let content = NSView()

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "arrow.up.arrow.down.circle.fill",
            accessibilityDescription: L10n.Transfers.notificationListTitle
        ) ?? NSImage())
        icon.contentTintColor = StacioDesignSystem.theme.accentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: L10n.Transfers.notificationListTitle)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer"))
        column.title = L10n.Transfers.notificationListTitle
        column.resizingMask = .autoresizingMask
        column.minWidth = 100
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.setAccessibilityIdentifier("Stacio.Transfers.completionList")
        tableView.setAccessibilityLabel(L10n.Transfers.notificationListTitle)
        StacioDesignSystem.styleTable(tableView)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(titleLabel)
        content.addSubview(countLabel)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),

            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        panel.contentView = content
        super.init(window: panel)
        tableView.dataSource = self
        tableView.delegate = self
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func setPayloads(_ payloads: [TransferCompletionNotificationPayload]) {
        self.payloads = payloads
        countLabel.stringValue = "\(payloads.count) \(L10n.Transfers.notificationItemUnit)"
        tableView.reloadData()
        let visibleRows = min(max(payloads.count, 1), Self.maximumVisibleRows)
        let contentHeight = Self.headerHeight + CGFloat(visibleRows) * Self.rowHeight + 12
        window?.setContentSize(NSSize(
            width: Self.panelWidth,
            height: max(contentHeight, Self.minimumHeight)
        ))
        window?.contentView?.layoutSubtreeIfNeeded()
        tableView.sizeLastColumnToFit()
        if payloads.isEmpty == false {
            tableView.scrollRowToVisible(0)
        }
    }

    func scrollToBottomForTesting() {
        guard payloads.isEmpty == false else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let maximumY = max(tableView.frame.height - clipView.bounds.height, 0)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: maximumY))
        scrollView.reflectScrolledClipView(clipView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        payloads.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard payloads.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TransferNotificationCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TransferNotificationCellView
            ?? TransferNotificationCellView(identifier: identifier)
        cell.configure(payloads[row])
        return cell
    }

    func closeProgrammatically() {
        guard window?.isVisible == true else { return }
        isClosingProgrammatically = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if isClosingProgrammatically {
            isClosingProgrammatically = false
            return
        }
        onManualClose?()
    }

    private static let panelWidth: CGFloat = 520
    private static let rowHeight: CGFloat = 68
    private static let headerHeight: CGFloat = 56
    private static let minimumHeight: CGFloat = 124
    private static let maximumVisibleRows = 6
}

@MainActor
private final class TransferNotificationCellView: NSTableCellView {
    private let statusIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        statusIcon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusIcon)
        addSubview(nameLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 20),
            statusIcon.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ payload: TransferCompletionNotificationPayload) {
        let row = payload.listRow
        let isCompleted = payload.status == .completed
        statusIcon.image = NSImage(
            systemSymbolName: isCompleted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: row.statusText
        )
        statusIcon.contentTintColor = isCompleted ? .systemGreen : .systemRed
        nameLabel.stringValue = "\(row.statusText) · \(row.itemName)"
        nameLabel.toolTip = nameLabel.stringValue
        detailLabel.stringValue = row.detailText
        detailLabel.toolTip = row.detailText
        setAccessibilityLabel("\(nameLabel.stringValue)，\(row.detailText)")
    }
}
