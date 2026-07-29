import AppKit
import StacioCoreBindings

public struct TransferQueuePopoverRowPresentation: Equatable {
    public let jobID: String
    public let fileName: String
    public let percentText: String
    public let speedText: String
    public let elapsedText: String
    public let remainingText: String
    public let primaryActionLabel: String?
    public let canCancel: Bool
}

@MainActor
public final class TransferQueuePopoverViewController: NSViewController {
    public var onTransferAction: ((TransferQueueAction, String) -> Void)?
    public var onCancelTransfer: ((String) -> Void)?
    public var onClearFinished: (() -> Void)?
    public var onCollapseRequested: (() -> Void)?

    private struct SpeedSample {
        let bytesDone: UInt64
        let capturedAt: Date
    }

    private let titleLabel = NSTextField(labelWithString: "传输队列")
    private let summaryLabel = NSTextField(labelWithString: "暂无传输任务")
    private let clearFinishedButton = NSButton()
    private let backgroundButton = NSButton(title: "后台传输", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()
    private let emptyStateLabel = NSTextField(labelWithString: "当前会话还没有传输记录")
    private var rowViewsByJobID: [String: TransferQueuePopoverRowView] = [:]
    private var rowWidthConstraintsByJobID: [String: NSLayoutConstraint] = [:]
    private var speedSamplesByJobID: [String: SpeedSample] = [:]
    private var measuredSpeedByJobID: [String: Double] = [:]
    private var lastProgressAtByJobID: [String: Date] = [:]
    private var latestSnapshot = TransferQueueSnapshot(rows: [])
    private let nowProvider: () -> Date

    public private(set) var rowsForTesting: [TransferQueuePopoverRowPresentation] = []

    public var activeTransferCountForTesting: Int {
        latestSnapshot.rows.filter { Self.isActive(status: $0.rawStatus) }.count
    }

    public var backgroundButtonForTesting: NSButton {
        backgroundButton
    }

    public init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 520, height: 460)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let materialView = NSVisualEffectView()
        materialView.material = .popover
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.setAccessibilityIdentifier("Stacio.Transfers.queuePopover")

        configureHeader()
        configureRows()

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, NSView(), clearFinishedButton, backgroundButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        materialView.addSubview(header)
        materialView.addSubview(summaryLabel)
        materialView.addSubview(separator)
        materialView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 14),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            summaryLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),

            separator.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor)
        ])

        view = materialView
        updateHeader()
        updateEmptyState()
    }

    public func apply(snapshot: TransferQueueSnapshot) {
        loadViewIfNeeded()
        latestSnapshot = snapshot

        var presentations: [TransferQueuePopoverRowPresentation] = []
        var actionsByJobID: [String: TransferQueueAction] = [:]
        var currentJobIDs = Set<String>()
        let sampleTime = nowProvider()

        for row in snapshot.rows {
            currentJobIDs.insert(row.jobID)
            let speed = transferSpeed(for: row, capturedAt: sampleTime)
            let presentation = Self.presentation(for: row, speed: speed)
            presentations.append(presentation)
            if let action = Self.primaryAction(for: row.rawStatus) {
                actionsByJobID[row.jobID] = action
            }
        }

        for jobID in Set(rowViewsByJobID.keys).subtracting(currentJobIDs) {
            if let rowView = rowViewsByJobID.removeValue(forKey: jobID) {
                rowWidthConstraintsByJobID.removeValue(forKey: jobID)?.isActive = false
                rowsStack.removeArrangedSubview(rowView)
                rowView.removeFromSuperview()
            }
            speedSamplesByJobID.removeValue(forKey: jobID)
            measuredSpeedByJobID.removeValue(forKey: jobID)
            lastProgressAtByJobID.removeValue(forKey: jobID)
        }

        let desiredJobIDs = presentations.map(\.jobID)
        let existingJobIDs = rowsStack.arrangedSubviews.compactMap {
            ($0 as? TransferQueuePopoverRowView)?.jobID
        }
        if desiredJobIDs != existingJobIDs {
            rowWidthConstraintsByJobID.values.forEach { $0.isActive = false }
            rowWidthConstraintsByJobID.removeAll(keepingCapacity: true)
            for view in rowsStack.arrangedSubviews {
                rowsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for presentation in presentations {
                let rowView = rowViewsByJobID[presentation.jobID]
                    ?? makeRowView(jobID: presentation.jobID)
                rowViewsByJobID[presentation.jobID] = rowView
                rowsStack.addArrangedSubview(rowView)
                let widthConstraint = rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor)
                widthConstraint.isActive = true
                rowWidthConstraintsByJobID[presentation.jobID] = widthConstraint
            }
        }

        for (index, presentation) in presentations.enumerated() {
            guard let snapshotRow = snapshot.rows[safe: index],
                  let rowView = rowViewsByJobID[presentation.jobID]
            else { continue }
            rowView.apply(
                presentation: presentation,
                statusText: Self.statusText(for: snapshotRow.rawStatus),
                direction: snapshotRow.direction,
                sourcePath: snapshotRow.sourcePath,
                destinationPath: snapshotRow.destinationPath,
                progressValue: Self.progressValue(for: snapshotRow),
                hasKnownTotal: snapshotRow.bytesTotal > 0,
                primaryAction: actionsByJobID[presentation.jobID]
            )
        }

        rowsForTesting = presentations
        updateHeader()
        updateEmptyState()
    }

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        configureHeaderButton(
            clearFinishedButton,
            title: "清除历史",
            symbolName: "trash",
            action: #selector(clearFinishedPressed)
        )
        clearFinishedButton.toolTip = "清除已完成的传输记录"

        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundPressed)
        backgroundButton.controlSize = .small
        backgroundButton.bezelStyle = .rounded
        backgroundButton.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: "后台传输"
        )
        backgroundButton.imagePosition = .imageLeading
        backgroundButton.toolTip = "收起窗口并继续在后台传输"
        backgroundButton.setAccessibilityLabel("后台传输")
        backgroundButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureHeaderButton(
        _ button: NSButton,
        title: String,
        symbolName: String,
        action: Selector
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.controlSize = .small
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configureRows() {
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = TransferQueueFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)
        documentView.addSubview(emptyStateLabel)
        scrollView.documentView = documentView

        emptyStateLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor),

            emptyStateLabel.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            emptyStateLabel.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),
            emptyStateLabel.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 72),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: rowsStack.bottomAnchor)
        ])

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeRowView(jobID: String) -> TransferQueuePopoverRowView {
        let rowView = TransferQueuePopoverRowView(jobID: jobID)
        rowView.onPrimaryAction = { [weak self] action, jobID in
            self?.onTransferAction?(action, jobID)
        }
        rowView.onCancel = { [weak self] jobID in
            if let onCancelTransfer = self?.onCancelTransfer {
                onCancelTransfer(jobID)
            } else {
                self?.onTransferAction?(.stop, jobID)
            }
        }
        return rowView
    }

    private func transferSpeed(
        for row: TransferQueueSnapshot.Row,
        capturedAt: Date
    ) -> Double {
        let previous = speedSamplesByJobID[row.jobID]
        speedSamplesByJobID[row.jobID] = SpeedSample(
            bytesDone: row.bytesDone,
            capturedAt: capturedAt
        )
        if let previous {
            let interval = capturedAt.timeIntervalSince(previous.capturedAt)
            if interval > 0, row.bytesDone >= previous.bytesDone {
                let byteDelta = row.bytesDone - previous.bytesDone
                if byteDelta > 0 {
                    let measuredSpeed = Double(byteDelta) / interval
                    measuredSpeedByJobID[row.jobID] = measuredSpeed
                    lastProgressAtByJobID[row.jobID] = capturedAt
                    return measuredSpeed
                }
                if Self.normalizedStatus(row.rawStatus) != "paused",
                   let lastProgressAt = lastProgressAtByJobID[row.jobID],
                   capturedAt.timeIntervalSince(lastProgressAt) <= 1.5
                {
                    return measuredSpeedByJobID[row.jobID] ?? 0
                }
                return 0
            }
        }
        guard row.elapsedTime > 0 else { return 0 }
        let averageSpeed = Double(row.bytesDone) / row.elapsedTime
        measuredSpeedByJobID[row.jobID] = averageSpeed
        lastProgressAtByJobID[row.jobID] = capturedAt
        return averageSpeed
    }

    private func updateHeader() {
        let activeCount = activeTransferCountForTesting
        let completedCount = latestSnapshot.rows.count - activeCount
        switch (activeCount, completedCount) {
        case (0, 0):
            summaryLabel.stringValue = "暂无传输任务"
        case (0, let history):
            summaryLabel.stringValue = "本次会话已完成 \(history) 项"
        case (let active, 0):
            summaryLabel.stringValue = "正在传输 \(active) 项"
        case (let active, let history):
            summaryLabel.stringValue = "正在传输 \(active) 项 · 历史 \(history) 项"
        }
        backgroundButton.isHidden = activeCount == 0
        clearFinishedButton.isHidden = completedCount == 0
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = latestSnapshot.rows.isEmpty == false
        scrollView.verticalScrollElasticity = latestSnapshot.rows.isEmpty ? .none : .automatic
    }

    @objc private func clearFinishedPressed() {
        onClearFinished?()
    }

    @objc private func backgroundPressed() {
        guard activeTransferCountForTesting > 0 else { return }
        onCollapseRequested?()
    }

    private static func presentation(
        for row: TransferQueueSnapshot.Row,
        speed: Double
    ) -> TransferQueuePopoverRowPresentation {
        let percent: Int?
        if row.bytesTotal > 0 {
            percent = Int(min(100, (Double(row.bytesDone) / Double(row.bytesTotal) * 100).rounded(.down)))
        } else {
            percent = isCompleted(status: row.rawStatus) ? 100 : nil
        }
        let remainingSeconds: TimeInterval?
        if speed > 0, row.bytesTotal > row.bytesDone {
            remainingSeconds = Double(row.bytesTotal - row.bytesDone) / speed
        } else {
            remainingSeconds = nil
        }
        return TransferQueuePopoverRowPresentation(
            jobID: row.jobID,
            fileName: displayFileName(for: row),
            percentText: percent.map { "\($0)%" } ?? "--",
            speedText: speedText(speed, status: row.rawStatus),
            elapsedText: "已用 \(durationText(row.elapsedTime))",
            remainingText: remainingSeconds.map { "剩余 \(durationText($0))" }
                ?? (isCompleted(status: row.rawStatus) ? "已完成" : "剩余 --"),
            primaryActionLabel: primaryAction(for: row.rawStatus).map(actionLabel),
            canCancel: isActive(status: row.rawStatus)
        )
    }

    private static func displayFileName(for row: TransferQueueSnapshot.Row) -> String {
        let path = row.sourcePath.isEmpty ? row.destinationPath : row.sourcePath
        let fileName = (path as NSString).lastPathComponent
        return fileName.isEmpty ? path : fileName
    }

    private static func progressValue(for row: TransferQueueSnapshot.Row) -> Double {
        guard row.bytesTotal > 0 else { return 0 }
        return min(1, Double(row.bytesDone) / Double(row.bytesTotal))
    }

    private static func speedText(_ bytesPerSecond: Double, status: String) -> String {
        guard isActive(status: status), bytesPerSecond > 0 else { return "-- B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1_024, unitIndex < units.count - 1 {
            value /= 1_024
            unitIndex += 1
        }
        if unitIndex == 0 || value >= 100 {
            return "\(Int(value.rounded())) \(units[unitIndex])"
        }
        let formatted = String(format: value >= 10 ? "%.1f" : "%.2f", value)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\.\d*[1-9])0+$"#, with: "$1", options: .regularExpression)
        return "\(formatted) \(units[unitIndex])"
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--" }
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainingSeconds) 秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分"
    }

    private static func normalizedStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isCompleted(status: String) -> Bool {
        normalizedStatus(status) == "completed"
    }

    private static func isActive(status: String) -> Bool {
        !["completed", "failed", "canceled", "cancelled", "stopped"].contains(normalizedStatus(status))
    }

    private static func primaryAction(for status: String) -> TransferQueueAction? {
        switch normalizedStatus(status) {
        case "paused":
            return .resume
        case "failed", "canceled", "cancelled", "stopped":
            return .retry
        case "completed":
            return nil
        default:
            return .pause
        }
    }

    private static func actionLabel(_ action: TransferQueueAction) -> String {
        switch action {
        case .retry: return "重试"
        case .pause: return "暂停"
        case .resume: return "恢复"
        case .restart: return "重新开始"
        case .stop: return "停止"
        }
    }

    private static func statusText(for status: String) -> String {
        switch normalizedStatus(status) {
        case "queued": return "等待中"
        case "running", "uploading", "downloading": return "传输中"
        case "paused": return "已暂停"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "canceled", "cancelled": return "已取消"
        case "stopped": return "已停止"
        default: return status
        }
    }
}

@MainActor
private final class TransferQueuePopoverRowView: NSView {
    let jobID: String
    var onPrimaryAction: ((TransferQueueAction, String) -> Void)?
    var onCancel: ((String) -> Void)?

    private let directionImageView = NSImageView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let cancelButton = NSButton()
    private var primaryAction: TransferQueueAction?

    init(jobID: String) {
        self.jobID = jobID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(
        presentation: TransferQueuePopoverRowPresentation,
        statusText: String,
        direction: ScpDirection,
        sourcePath: String,
        destinationPath: String,
        progressValue: Double,
        hasKnownTotal: Bool,
        primaryAction: TransferQueueAction?
    ) {
        self.primaryAction = primaryAction
        fileNameLabel.stringValue = presentation.fileName
        fileNameLabel.toolTip = "\(sourcePath) → \(destinationPath)"
        statusLabel.stringValue = statusText
        percentLabel.stringValue = presentation.percentText
        metricsLabel.stringValue = [
            presentation.speedText,
            presentation.elapsedText,
            presentation.remainingText
        ].joined(separator: "  ·  ")

        directionImageView.image = NSImage(
            systemSymbolName: direction == .upload ? "arrow.up" : "arrow.down",
            accessibilityDescription: direction == .upload ? "上传" : "下载"
        )

        progressIndicator.isIndeterminate = hasKnownTotal == false && presentation.canCancel
        if hasKnownTotal {
            progressIndicator.stopAnimation(nil)
            progressIndicator.doubleValue = progressValue
        } else if presentation.canCancel {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.isIndeterminate = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.doubleValue = statusText == "已完成" ? 1 : 0
        }

        configurePrimaryButton(label: presentation.primaryActionLabel)
        cancelButton.isHidden = presentation.canCancel == false
        setAccessibilityLabel("\(presentation.fileName)，\(statusText)，\(presentation.percentText)")
    }

    private func buildView() {
        directionImageView.imageScaling = .scaleProportionallyDown
        directionImageView.contentTintColor = .secondaryLabelColor
        directionImageView.translatesAutoresizingMaskIntoConstraints = false

        fileNameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        fileNameLabel.textColor = .labelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.maximumNumberOfLines = 1
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        metricsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        metricsLabel.textColor = .secondaryLabelColor
        metricsLabel.lineBreakMode = .byTruncatingTail
        metricsLabel.maximumNumberOfLines = 1
        metricsLabel.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(
            primaryButton,
            symbolName: "pause.fill",
            accessibilityLabel: "暂停",
            action: #selector(primaryPressed)
        )
        configureActionButton(
            cancelButton,
            symbolName: "xmark",
            accessibilityLabel: "取消任务",
            action: #selector(cancelPressed)
        )

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(directionImageView)
        addSubview(fileNameLabel)
        addSubview(statusLabel)
        addSubview(progressIndicator)
        addSubview(percentLabel)
        addSubview(metricsLabel)
        addSubview(primaryButton)
        addSubview(cancelButton)
        addSubview(separator)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            heightAnchor.constraint(equalToConstant: 88),

            directionImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            directionImageView.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            directionImageView.widthAnchor.constraint(equalToConstant: 16),
            directionImageView.heightAnchor.constraint(equalToConstant: 16),

            fileNameLabel.leadingAnchor.constraint(equalTo: directionImageView.trailingAnchor, constant: 8),
            fileNameLabel.centerYAnchor.constraint(equalTo: directionImageView.centerYAnchor),
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: fileNameLabel.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),

            progressIndicator.leadingAnchor.constraint(equalTo: fileNameLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -8),
            progressIndicator.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 10),
            progressIndicator.heightAnchor.constraint(equalToConstant: 6),

            percentLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 42),

            metricsLabel.leadingAnchor.constraint(equalTo: fileNameLabel.leadingAnchor),
            metricsLabel.trailingAnchor.constraint(lessThanOrEqualTo: primaryButton.leadingAnchor, constant: -10),
            metricsLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 8),

            cancelButton.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: metricsLabel.centerYAnchor),
            primaryButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -6),
            primaryButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureActionButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.controlSize = .small
        button.bezelStyle = .texturedRounded
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configurePrimaryButton(label: String?) {
        guard let label, let primaryAction else {
            primaryButton.isHidden = true
            return
        }
        primaryButton.isHidden = false
        let symbolName: String
        switch primaryAction {
        case .pause: symbolName = "pause.fill"
        case .resume: symbolName = "play.fill"
        case .retry, .restart: symbolName = "arrow.clockwise"
        case .stop: symbolName = "stop.fill"
        }
        primaryButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        primaryButton.setAccessibilityLabel(label)
        primaryButton.toolTip = label
    }

    @objc private func primaryPressed() {
        guard let primaryAction else { return }
        onPrimaryAction?(primaryAction, jobID)
    }

    @objc private func cancelPressed() {
        onCancel?(jobID)
    }
}

private final class TransferQueueFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
