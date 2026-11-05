import AppKit
import QuartzCore

@MainActor
protocol DeviceMetricsPollingControlling: AnyObject {
    func startPollingIfNeeded()
    func stopPolling()
    func applyMetricsSettings()
}

@MainActor
final class DeviceMetricsStatusBarViewController: NSViewController, DeviceMetricsPollingControlling {
    private static let minimumBarHeight: CGFloat = 36
    private static var titleFont: NSFont {
        NSFont.preferredFont(forTextStyle: .caption1)
    }
    private static var valueFont: NSFont {
        let preferred = NSFont.preferredFont(forTextStyle: .subheadline)
        return NSFont.monospacedDigitSystemFont(ofSize: preferred.pointSize, weight: .semibold)
    }
    static var barHeightForLayout: CGFloat {
        let titleHeight = titleFont.ascender - titleFont.descender + titleFont.leading
        let valueHeight = valueFont.ascender - valueFont.descender + valueFont.leading
        return ceil(max(minimumBarHeight, max(titleHeight, valueHeight) + 14))
    }
    private let runtimeID: String
    private let deviceTitle: String
    private let provider: DeviceMetricsProviding
    private let startsPollingAutomatically: Bool
    private let settingsStore: AppSettingsStore
    private let alertCoordinator: DeviceMetricsAlertCoordinator
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var barHeightConstraint: NSLayoutConstraint?
    private var lastReportedBarHeight: CGFloat?
    private let startedAt = Date()
    private let metricsStack = NSStackView()
    private var metricsBoundsObserver: NSObjectProtocol?
    private weak var glassSurface: NSVisualEffectView?
    private var hoverCells: [String: DeviceMetricsHoverCell] = [:]
    private var hoverDetails: [String: String] = [:]
    private var hoveredDetailKey: String?
    private var latestSnapshot: DeviceMetricsDisplaySnapshot?
    private var detailDismissal: DispatchWorkItem?
    private var detailPopover: NSPopover?
    private var detailViewController: DeviceMetricsStatusDetailViewController?
    private var historyPopover: NSPopover?
    private var historyMetricKey: String?
    private var isReplacingMetrics = false
    private var isUpdatingPopoverAnchors = false
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var cpuHistorySamples: [DeviceMetricHistorySample] = []
    private var memoryHistorySamples: [DeviceMetricHistorySample] = []
    private var uploadHistorySamples: [DeviceMetricHistorySample] = []
    private var downloadHistorySamples: [DeviceMetricHistorySample] = []
    private var diskHistorySamples: [DeviceMetricHistorySample] = []
    private var latestSystem: DeviceSystemDisplayInfo?
    private var latestProcessSnapshot: [DeviceProcessDisplayInfo] = []

    var metricsDidUpdate: (() -> Void)?
    var barHeightDidChange: (() -> Void)?

    init(
        runtimeID: String,
        title: String,
        provider: DeviceMetricsProviding,
        startsPollingAutomatically: Bool = true,
        settingsStore: AppSettingsStore = .shared,
        alertCoordinator: DeviceMetricsAlertCoordinator? = nil
    ) {
        self.runtimeID = runtimeID
        self.deviceTitle = title
        self.provider = provider
        self.startsPollingAutomatically = startsPollingAutomatically
        self.settingsStore = settingsStore
        self.alertCoordinator = alertCoordinator ?? DeviceMetricsAlertCoordinator(
            settingsProvider: { settingsStore.snapshot() }, notifier: NoopDeviceMetricsAlertNotifier())
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let metricsBoundsObserver { NotificationCenter.default.removeObserver(metricsBoundsObserver) }
    }

    override func loadView() {
        let root = StacioAppearanceRefreshView()
        root.setAccessibilityIdentifier("Stacio.Metrics.statusBar.\(runtimeID)")

        let glassSurface = NSVisualEffectView()
        glassSurface.material = .underWindowBackground
        glassSurface.blendingMode = .withinWindow
        glassSurface.state = .active
        glassSurface.isEmphasized = false
        glassSurface.translatesAutoresizingMaskIntoConstraints = false
        glassSurface.setAccessibilityIdentifier("Stacio.Metrics.statusBar.glassSurface")
        self.glassSurface = glassSurface

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("Stacio.Metrics.statusBar.scrollView")
        scrollView.contentView.postsBoundsChangedNotifications = true
        metricsBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisiblePopoverAnchors() }
        }

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = 0
        metricsStack.translatesAutoresizingMaskIntoConstraints = false
        metricsStack.setAccessibilityIdentifier("Stacio.Metrics.statusBar.metrics")
        document.addSubview(metricsStack)
        scrollView.documentView = document

        root.addSubview(glassSurface)
        root.addSubview(scrollView)
        let barHeightConstraint = root.heightAnchor.constraint(equalToConstant: Self.barHeightForLayout)
        self.barHeightConstraint = barHeightConstraint
        NSLayoutConstraint.activate([
            barHeightConstraint,
            glassSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glassSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glassSurface.topAnchor.constraint(equalTo: root.topAnchor),
            glassSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            metricsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            metricsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            metricsStack.topAnchor.constraint(equalTo: document.topAnchor),
            metricsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            metricsStack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        ])
        renderUnavailable()
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Clip bounds notifications cover scrolling, but a resized viewport's
        // final visible region is only available after layout completes.
        updateVisiblePopoverAnchors()
        let preferredHeight = Self.barHeightForLayout
        if barHeightConstraint?.constant != preferredHeight {
            barHeightConstraint?.constant = preferredHeight
        }
        guard lastReportedBarHeight != preferredHeight else { return }
        lastReportedBarHeight = preferredHeight
        barHeightDidChange?()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        startPollingIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopPolling()
        detailDismissal?.cancel()
        detailDismissal = nil
        hoveredDetailKey = nil
        detailPopover?.close()
        historyMetricKey = nil
        historyPopover?.close()
        historyPopover = nil
    }

    func startPollingIfNeeded() {
        guard startsPollingAutomatically, refreshTimer == nil else { return }
        refreshMetrics()
        let interval = TimeInterval(settingsStore.snapshot().deviceMetricsRefreshIntervalSeconds)
        installRefreshTimer(interval: interval)
    }

    private func installRefreshTimer(interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetrics()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func applyMetricsSettings() {
        let interval = TimeInterval(settingsStore.snapshot().deviceMetricsRefreshIntervalSeconds)
        if let timer = refreshTimer, timer.timeInterval != interval {
            timer.invalidate()
            installRefreshTimer(interval: interval)
        }
        guard isViewLoaded else { return }
        // Repaint thresholds/selection without inventing a sample or counting
        // a settings notification as another consecutive threshold breach.
        if let latestSnapshot { render(latestSnapshot, recordsHistory: false) }
        else { renderUnavailable() }
    }

    var pollingIntervalForTesting: TimeInterval? { refreshTimer?.timeInterval }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshMetricsForTesting() {
        refreshMetrics()
    }

    var visibleTextSnapshotForTesting: String {
        guard isViewLoaded else { return "" }
        var values: [String] = []
        collectVisibleText(from: view, into: &values)
        return values.joined(separator: " ")
    }

    var runtimeIDForTesting: String {
        runtimeID
    }

    func historySampleCountForTesting(title: String) -> Int {
        switch title {
        case "CPU": cpuHistory.count
        case "内存": memoryHistory.count
        default: 0
        }
    }

    var hoverDetailTextForTesting: String {
        detailViewController?.visibleTextForTesting ?? ""
    }

    var hoverDetailIsShownForTesting: Bool {
        detailPopover?.isShown == true
    }

    var hoverDetailPopoverIdentityForTesting: ObjectIdentifier? {
        detailPopover.map(ObjectIdentifier.init)
    }

    var hoverDetailPopoverForTesting: NSPopover? { detailPopover }

    var historyPopoverForTesting: NSPopover? { historyPopover }

    func detailTextForTesting(title: String) -> String {
        hoverDetails[title] ?? ""
    }

    func beginHoverDetailForTesting(title: String) {
        guard let cell = hoverCells[title] else { return }
        presentDetail(for: title, source: cell)
    }

    func endHoverDetailForTesting(title: String) {
        dismissDetail(for: title)
    }

    private func refreshMetrics() {
        guard !isRefreshing else { return }
        isRefreshing = true
        provider.pollDeviceMetrics { [weak self] result in
            let applyResult = { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case let .success(snapshot):
                    self.render(snapshot)
                case .failure:
                    self.renderUnavailable()
                }
            }
            if Thread.isMainThread {
                applyResult()
            } else {
                DispatchQueue.main.async(execute: applyResult)
            }
        }
    }

    private func renderUnavailable() {
        latestSnapshot = nil
        guard isViewLoaded else { return }
        replaceMetrics([
            makeIdentityCell(system: .unavailable),
            makeMetricCell(symbol: "person", title: "用户", value: "--", detail: "远端用户信息暂不可用"),
            makeMetricCell(symbol: "clock", title: "连接", value: connectionDuration(), detail: connectionDetail()),
            makeMetricCell(symbol: "clock.badge", title: "运行", value: "--", detail: "远端运行时间暂不可用"),
            makeMetricCell(symbol: "cpu", title: "CPU", value: "--", detail: "CPU 信息暂不可用"),
            makeMetricCell(symbol: "memorychip", title: "内存", value: "--", detail: "内存信息暂不可用"),
            makeMetricCell(symbol: "arrow.up", title: "上传", value: "--", detail: "网络信息暂不可用", valueColor: .systemCyan),
            makeMetricCell(symbol: "arrow.down", title: "下载", value: "--", detail: "网络信息暂不可用", valueColor: .systemGreen),
            makeMetricCell(symbol: "internaldrive", title: "磁盘", value: "--", detail: "磁盘信息暂不可用")
        ])
    }

    private func render(_ snapshot: DeviceMetricsDisplaySnapshot, recordsHistory: Bool = true) {
        latestSnapshot = snapshot
        let sampleDate = Date()
        latestSystem = snapshot.system
        latestProcessSnapshot = snapshot.processes
        let selectedNetworks = DeviceMetricsNetworkSelection.automaticSelection(
            from: snapshot.networks, hideVirtual: settingsStore.snapshot().deviceMetricsHideVirtualNetworkInterfaces)
        let network = selectedNetworks.reduce((upload: 0.0, download: 0.0)) { result, item in
            (result.upload + item.transmitBytesPerSecond, result.download + item.receiveBytesPerSecond)
        }
        if recordsHistory {
            append(snapshot.cpuUsage, to: &cpuHistory)
            append(snapshot.memory.usageFraction, to: &memoryHistory)
            if let cpuUsage = snapshot.cpuUsage {
                appendHistorySample(sampleDate, value: cpuUsage, to: &cpuHistorySamples)
            }
            appendHistorySample(sampleDate, value: Double(snapshot.memory.usedBytes), to: &memoryHistorySamples)
            appendHistorySample(sampleDate, value: network.upload, to: &uploadHistorySamples)
            appendHistorySample(sampleDate, value: network.download, to: &downloadHistorySamples)
            appendHistorySample(sampleDate, value: snapshot.disks.map(\.usageFraction).max() ?? 0, to: &diskHistorySamples)
            alertCoordinator.process(snapshot: snapshot, runtimeID: runtimeID, sessionTitle: deviceTitle)
        }
        replaceMetrics([
            makeIdentityCell(system: snapshot.system),
            makeMetricCell(
                symbol: "person",
                title: "用户",
                value: snapshot.system.currentUser,
                detail: "远端用户: \(snapshot.system.currentUser)"
            ),
            makeMetricCell(symbol: "clock", title: "连接", value: connectionDuration(), detail: connectionDetail()),
            makeMetricCell(
                symbol: "clock.badge",
                title: "运行",
                value: snapshot.system.uptimeText,
                detail: uptimeDetail(snapshot.system)
            ),
            makeUsageMetricCell(
                symbol: "cpu",
                title: "CPU",
                value: snapshot.cpuUsage.map { percent($0) } ?? "--",
                usageFraction: snapshot.cpuUsage,
                history: cpuHistory,
                metric: .cpuUsage,
                detail: cpuDetail(snapshot)
            ),
            makeUsageMetricCell(
                symbol: "memorychip",
                title: "内存",
                value: DeviceMetricValueFormatter.bytes(Double(snapshot.memory.usedBytes)),
                usageFraction: snapshot.memory.usageFraction,
                history: memoryHistory,
                metric: .memoryUsage,
                detail: memoryDetail(snapshot)
            ),
            makeMetricCell(
                symbol: "arrow.up",
                title: "上传",
                value: rate(network.upload),
                detail: networkDetail(snapshot),
                valueColor: .systemCyan,
                symbolColor: .systemCyan
            ),
            makeMetricCell(
                symbol: "arrow.down",
                title: "下载",
                value: rate(network.download),
                detail: networkDetail(snapshot),
                valueColor: .systemGreen,
                symbolColor: .systemGreen
            ),
            makeDiskMetricCell(snapshot.disks)
        ])
    }

    private func replaceMetrics(_ cells: [NSView]) {
        isReplacingMetrics = true
        metricsStack.arrangedSubviews.forEach {
            metricsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        hoverCells.removeAll(keepingCapacity: true)
        for (index, cell) in cells.enumerated() {
            if index > 0 {
                let separator = NSView()
                separator.wantsLayer = true
                separator.layer?.backgroundColor = StacioDesignSystem.theme.separatorColor.cgColor
                separator.translatesAutoresizingMaskIntoConstraints = false
                metricsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
                separator.heightAnchor.constraint(equalTo: metricsStack.heightAnchor, multiplier: 0.55).isActive = true
            }
            metricsStack.addArrangedSubview(cell)
            if let hoverCell = cell as? DeviceMetricsHoverCell {
                hoverCells[hoverCell.detailKey] = hoverCell
                hoverCell.onClick = { [weak self, weak hoverCell] in
                    guard let self, let hoverCell else { return }
                    self.showHistory(for: hoverCell.detailKey, anchor: hoverCell)
                }
            }
        }
        isReplacingMetrics = false
        refreshVisibleDetailAfterMetricsReplacement()
        refreshVisibleHistoryAfterMetricsReplacement()
        metricsDidUpdate?()
    }

    private func makeIdentityCell(system: DeviceSystemDisplayInfo) -> NSView {
        let cell = makeCell(symbol: "server.rack", title: "设备")
        let value = NSTextField(labelWithString: "\(system.hostname) · \(system.operatingSystem)")
        value.font = Self.valueFont
        value.textColor = StacioDesignSystem.theme.primaryTextColor
        value.lineBreakMode = .byTruncatingMiddle
        value.maximumNumberOfLines = 1
        value.setAccessibilityIdentifier("Stacio.Metrics.statusBar.device")
        cell.addArrangedSubview(value)
        applyDetail(
            [
                "主机: \(system.hostname)",
                "系统: \(system.operatingSystem)",
                "内核: \(system.kernelVersion)",
                "架构: \(system.architecture)",
                "处理器: \(system.cpuModel)"
            ].joined(separator: "\n"),
            to: cell
        )
        return cell
    }

    private func makeUsageMetricCell(
        symbol: String,
        title: String,
        value: String,
        usageFraction: Double?,
        history: [Double],
        metric: DeviceMetricsAlertMetric,
        detail: String
    ) -> NSView {
        let state = usageFraction.map { usageState($0, metric: metric) } ?? .normal
        let cell = makeCell(symbol: symbol, title: title, symbolColor: state.color)
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = Self.valueFont
        valueLabel.textColor = state.color
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.setAccessibilityIdentifier("Stacio.Metrics.statusBar.\(title)")
        applyBreathingGlow(to: valueLabel, isDanger: state == .danger)
        cell.addArrangedSubview(valueLabel)
        if usageFraction != nil {
            let graph = DeviceMetricsHistoryGraphView(
                samples: history,
                color: state.color,
                isDanger: state == .danger,
                accessibilityIdentifier: "Stacio.Metrics.statusBar.history.\(title)"
            )
            cell.addArrangedSubview(graph)
        }
        applyDetail(detail, to: cell)
        return cell
    }

    private func makeMetricCell(
        symbol: String,
        title: String,
        value: String,
        detail: String? = nil,
        valueColor: NSColor? = nil,
        symbolColor: NSColor? = nil
    ) -> NSView {
        let cell = makeCell(symbol: symbol, title: title)
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = Self.valueFont
        valueLabel.textColor = valueColor ?? StacioDesignSystem.theme.primaryTextColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.setAccessibilityIdentifier("Stacio.Metrics.statusBar.\(title)")
        if let symbolColor,
           let imageView = cell.arrangedSubviews.first as? NSImageView {
            imageView.contentTintColor = symbolColor
        }
        cell.addArrangedSubview(valueLabel)
        if let detail {
            applyDetail(detail, to: cell)
        }
        return cell
    }

    private func makeDiskMetricCell(_ disks: [DeviceDiskDisplayUsage]) -> NSView {
        let cell = makeCell(symbol: "internaldrive", title: "磁盘")
        let values = NSStackView()
        values.orientation = .horizontal
        values.alignment = .centerY
        values.spacing = 5
        values.setAccessibilityIdentifier("Stacio.Metrics.statusBar.磁盘")

        if disks.isEmpty {
            let unavailable = makeDiskValueLabel(text: "--", color: StacioDesignSystem.theme.primaryTextColor)
            unavailable.setAccessibilityIdentifier("Stacio.Metrics.statusBar.disk.unavailable")
            values.addArrangedSubview(unavailable)
        } else {
            for (index, disk) in disks.enumerated() {
                if index > 0 {
                    let separator = NSTextField(labelWithString: "·")
                    separator.font = Self.valueFont
                    separator.textColor = StacioDesignSystem.theme.secondaryTextColor
                    values.addArrangedSubview(separator)
                }
                let state = usageState(disk.usageFraction, metric: .diskUsage)
                let label = makeDiskValueLabel(
                    text: "\(disk.mountPath) \(Int((disk.usageFraction * 100).rounded()))%",
                    color: state.color
                )
                label.setAccessibilityIdentifier("Stacio.Metrics.statusBar.disk.\(disk.mountPath)")
                applyBreathingGlow(to: label, isDanger: state == .danger)
                values.addArrangedSubview(label)
            }
        }

        cell.addArrangedSubview(values)
        applyDetail(diskDetail(disks), to: cell)
        return cell
    }

    private func makeDiskValueLabel(text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Self.valueFont
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private enum UsageState: Equatable {
        case normal
        case warning
        case danger

        var color: NSColor {
            switch self {
            case .normal:
                return StacioDesignSystem.theme.successColor
            case .warning:
                return NSColor.systemOrange
            case .danger:
                return StacioDesignSystem.theme.dangerColor
            }
        }
    }

    private func usageState(_ fraction: Double, metric: DeviceMetricsAlertMetric) -> UsageState {
        let settings = settingsStore.snapshot()
        let configuredThreshold: Double
        switch metric {
        case .cpuUsage:
            configuredThreshold = Double(settings.deviceMetricsCPUAlertThresholdPercent) / 100
        case .memoryUsage:
            configuredThreshold = Double(settings.deviceMetricsMemoryAlertThresholdPercent) / 100
        case .diskUsage:
            configuredThreshold = Double(settings.deviceMetricsDiskAlertThresholdPercent) / 100
        case .networkIO, .diskIO:
            configuredThreshold = 0.90
        }
        return Self.usageState(fraction, configuredThreshold: configuredThreshold)
    }

    private static func usageState(_ fraction: Double, configuredThreshold: Double) -> UsageState {
        let value = min(max(fraction, 0), 1)
        let dangerThreshold = max(0.90, configuredThreshold)
        let warningThreshold = min(0.80, max(0.75, dangerThreshold * 0.85))
        if value >= dangerThreshold { return .danger }
        if value >= warningThreshold { return .warning }
        return .normal
    }

    private func applyBreathingGlow(to label: NSTextField, isDanger: Bool) {
        guard isDanger else { return }
        label.wantsLayer = true
        label.layer?.shadowColor = StacioDesignSystem.theme.dangerColor.cgColor
        label.layer?.shadowOffset = .zero
        label.layer?.shadowRadius = 5
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = 0.25
        animation.toValue = 0.9
        animation.duration = 1.15
        animation.autoreverses = true
        animation.repeatCount = .infinity
        label.layer?.add(animation, forKey: "Stacio.Metrics.statusBar.breathingGlow")
    }

    private func makeCell(symbol: String, title: String, symbolColor: NSColor? = nil) -> NSStackView {
        let cell = DeviceMetricsHoverCell(detailKey: title)
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 5
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        cell.setAccessibilityLabel(title)
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image.contentTintColor = symbolColor ?? StacioDesignSystem.theme.secondaryTextColor
        image.setAccessibilityIdentifier("Stacio.Metrics.statusBar.icon.\(title)")
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 15).isActive = true
        image.heightAnchor.constraint(equalToConstant: 15).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Self.titleFont
        titleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        cell.addArrangedSubview(image)
        cell.addArrangedSubview(titleLabel)
        cell.onHoverChanged = { [weak self, weak cell] isHovering in
            guard let self, let cell else { return }
            if isHovering {
                self.presentDetail(for: cell.detailKey, source: cell)
            } else {
                self.scheduleDetailDismissal(for: cell.detailKey, source: cell)
            }
        }
        return cell
    }

    private func append(_ value: Double?, to history: inout [Double]) {
        guard let value, value.isFinite else { return }
        history.append(min(max(value, 0), 1))
        if history.count > DeviceMetricsHistoryGraphView.maximumSampleCount {
            history.removeFirst(history.count - DeviceMetricsHistoryGraphView.maximumSampleCount)
        }
    }

    private func appendHistorySample(_ date: Date, value: Double, to history: inout [DeviceMetricHistorySample]) {
        guard value.isFinite else { return }
        history.append(DeviceMetricHistorySample(date: date, value: max(value, 0)))
        // Keep the detail view useful for minute/hour/day inspection. The
        // compact graph has its own 48-point limit and must not constrain the
        // underlying history used by the click detail popover.
        let cutoff = date.addingTimeInterval(-7 * 86400)
        if let first = history.firstIndex(where: { $0.date >= cutoff }), first > 0 {
            history.removeFirst(first)
        }
        if history.count > 100_000 {
            history.removeFirst(history.count - 100_000)
        }
    }

    private func showHistory(for key: String, anchor: NSView) {
        let title: String
        let unit: String
        let samples: [DeviceMetricHistorySample]
        switch key {
        case "CPU": title = "CPU"; unit = "%"; samples = cpuHistorySamples
        case "内存": title = "内存已用"; unit = "B"; samples = memoryHistorySamples
        case "上传": title = "上传"; unit = "B/s"; samples = uploadHistorySamples
        case "下载": title = "下载"; unit = "B/s"; samples = downloadHistorySamples
        case "磁盘": title = "磁盘占用"; unit = "%"; samples = diskHistorySamples
        default: return
        }
        guard samples.isEmpty == false else { return }
        view.layoutSubtreeIfNeeded()
        guard let anchorRect = visibleAnchorRect(for: anchor) else {
            closeHistoryPopover()
            return
        }
        detailDismissal?.cancel()
        detailDismissal = nil
        hoveredDetailKey = nil
        detailPopover?.close()
        if historyMetricKey == key, let popover = historyPopover,
           let controller = popover.contentViewController as? DeviceMetricHistoryDetailViewController {
            controller.updateHistorySamples(samples)
            popover.positioningRect = anchorRect
            if !popover.isShown {
                popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
            }
            return
        }
        historyPopover?.close()
        historyMetricKey = key
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: title,
            samples: samples,
            accentColor: StacioDesignSystem.theme.accentColor,
            unit: unit,
            deviceName: latestSystem?.hostname,
            deviceAddress: deviceTitle
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        historyPopover = popover
        // The bar survives refreshes; individual metric cells are replaced.
        // Keeping a stable anchor avoids closing the popup or stealing focus
        // from its range controls every time a new sample arrives.
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    private func refreshVisibleHistoryAfterMetricsReplacement() {
        guard let key = historyMetricKey,
              historyPopover?.isShown == true
        else { return }
        guard let source = hoverCells[key] else { closeHistoryPopover(); return }
        showHistory(for: key, anchor: source)
    }

    private func closeHistoryPopover() {
        historyMetricKey = nil
        historyPopover?.close()
        historyPopover = nil
    }

    private func visibleAnchorRect(for source: NSView) -> NSRect? {
        guard let window = view.window, source.window === window,
              window.isVisible, !window.isMiniaturized,
              !source.isHiddenOrHasHiddenAncestor else { return nil }
        let visible = source.visibleRect.intersection(source.bounds)
        guard !visible.isEmpty else { return nil }
        return source.convert(visible, to: view)
    }

    private func updateVisiblePopoverAnchors() {
        guard !isReplacingMetrics, !isUpdatingPopoverAnchors else { return }
        isUpdatingPopoverAnchors = true
        defer { isUpdatingPopoverAnchors = false }
        // The popovers use the stable status-bar view as their AppKit anchor;
        // scrolling or resizing its document does not move that anchor. Avoid
        // setting an unchanged rect, which can request another native layout.
        if let key = hoveredDetailKey {
            if let source = hoverCells[key], let rect = visibleAnchorRect(for: source) {
                if detailPopover?.positioningRect != rect { detailPopover?.positioningRect = rect }
            } else {
                dismissDetail(for: key)
            }
        }
        if let key = historyMetricKey {
            if let source = hoverCells[key], let rect = visibleAnchorRect(for: source) {
                if historyPopover?.positioningRect != rect { historyPopover?.positioningRect = rect }
            } else {
                closeHistoryPopover()
            }
        }
    }

    private func applyDetail(_ detail: String, to view: NSView) {
        var accessibilityDetail = detail
        if let hoverCell = view as? DeviceMetricsHoverCell {
            hoverDetails[hoverCell.detailKey] = detail
            if ["CPU", "内存", "上传", "下载", "磁盘"].contains(hoverCell.detailKey) {
                accessibilityDetail += "\n单击查看历史资源使用。"
            }
        }
        applyAccessibilityDetail(accessibilityDetail, to: view)
    }

    private func applyAccessibilityDetail(_ detail: String, to view: NSView) {
        view.setAccessibilityHelp(detail)
        for subview in view.subviews {
            applyAccessibilityDetail(detail, to: subview)
        }
    }

    private func presentDetail(for key: String, source: DeviceMetricsHoverCell) {
        guard historyPopover?.isShown != true else { return }
        guard let detail = hoverDetails[key], detail.isEmpty == false else { return }
        view.layoutSubtreeIfNeeded()
        guard let anchorRect = visibleAnchorRect(for: source) else { return }
        detailDismissal?.cancel()
        detailDismissal = nil
        hoveredDetailKey = key
        updateVisibleDetail(title: key, detail: detail)
        let popover = detailPopover ?? makeDetailPopover()
        if popover.isShown {
            popover.positioningRect = anchorRect
            return
        }
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    private func scheduleDetailDismissal(for key: String, source: DeviceMetricsHoverCell? = nil) {
        guard !isReplacingMetrics, hoveredDetailKey == key else { return }
        if let source, hoverCells[key] !== source { return }
        detailDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissDetail(for: key) }
        detailDismissal = work
        // Give the pointer time to cross the popover arrow into its scroll area.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func dismissDetail(for key: String, source: DeviceMetricsHoverCell? = nil) {
        guard isReplacingMetrics == false, hoveredDetailKey == key else { return }
        if let source, hoverCells[key] !== source { return }
        detailDismissal?.cancel()
        detailDismissal = nil
        hoveredDetailKey = nil
        detailPopover?.close()
    }

    private func refreshVisibleDetailAfterMetricsReplacement() {
        guard let key = hoveredDetailKey else { return }
        guard let source = hoverCells[key], let detail = hoverDetails[key] else {
            dismissDetail(for: key)
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let anchorRect = visibleAnchorRect(for: source) else {
            dismissDetail(for: key)
            return
        }
        updateVisibleDetail(title: key, detail: detail)
        if detailPopover?.isShown == true {
            detailPopover?.positioningRect = anchorRect
        } else {
            presentDetail(for: key, source: source)
        }
    }

    private func makeDetailPopover() -> NSPopover {
        let controller = DeviceMetricsStatusDetailViewController()
        controller.onHoverChanged = { [weak self] inside in
            guard let self else { return }
            if inside {
                self.detailDismissal?.cancel()
                self.detailDismissal = nil
            } else if let key = self.hoveredDetailKey {
                self.scheduleDetailDismissal(for: key)
            }
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        detailViewController = controller
        detailPopover = popover
        return popover
    }

    private func updateVisibleDetail(title: String, detail: String) {
        let controller: DeviceMetricsStatusDetailViewController
        if let detailViewController {
            controller = detailViewController
        } else {
            _ = makeDetailPopover()
            guard let created = detailViewController else { return }
            controller = created
        }
        let settings = settingsStore.snapshot()
        controller.update(title: title, detail: detail, snapshot: latestSnapshot) { fraction, metric in
            let threshold: Double
            switch metric {
            case .cpuUsage: threshold = Double(settings.deviceMetricsCPUAlertThresholdPercent) / 100
            case .memoryUsage: threshold = Double(settings.deviceMetricsMemoryAlertThresholdPercent) / 100
            case .diskUsage: threshold = Double(settings.deviceMetricsDiskAlertThresholdPercent) / 100
            case .networkIO, .diskIO: threshold = 0.90
            }
            return Self.usageState(fraction, configuredThreshold: threshold).color
        }
        detailPopover?.contentSize = controller.preferredContentSize
    }

    private func connectionDetail() -> String {
        let destination = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationLine = destination.flatMap { $0.isEmpty ? nil : "连接目标: \($0)\n" } ?? ""
        return "\(destinationLine)连接时长: \(connectionDuration())"
    }

    private func uptimeDetail(_ system: DeviceSystemDisplayInfo) -> String {
        guard let seconds = system.uptimeSeconds else {
            return "远端运行时间: \(system.uptimeText)"
        }
        return "远端运行时间: \(system.uptimeText) (\(seconds) 秒)"
    }

    private func cpuDetail(_ snapshot: DeviceMetricsDisplaySnapshot) -> String {
        var lines = ["当前 CPU 负载: \(snapshot.cpuUsage.map(percent) ?? "--")"]
        lines.append("处理器: \(snapshot.system.cpuModel)")
        if !snapshot.cpuCoreUsages.isEmpty {
            lines.append("逻辑核心: \(snapshot.cpuCoreUsages.count)")
            let coreLines = stride(from: 0, to: snapshot.cpuCoreUsages.count, by: 4).map { start in
                snapshot.cpuCoreUsages[start..<min(start + 4, snapshot.cpuCoreUsages.count)]
                    .map { "CPU \($0.index): \($0.usage.map(percent) ?? "--")" }
                    .joined(separator: "    ")
            }
            lines.append(contentsOf: coreLines)
        }
        let top = snapshot.processes.sorted {
            if $0.hasCPUUsage != $1.hasCPUUsage { return $0.hasCPUUsage }
            return $0.cpuFraction == $1.cpuFraction ? $0.pid < $1.pid : $0.cpuFraction > $1.cpuFraction
        }.prefix(10)
        if top.isEmpty == false {
            lines.append("CPU 占用 Top 10")
            lines.append(contentsOf: top.map { process in
                let usage = process.hasCPUUsage ? String(format: "%.1f%%", process.cpuFraction * 100) : "--"
                return "  \(usage)  \(process.name)  PID \(process.pid)"
            })
        } else {
            lines.append("CPU 占用 Top 10: 暂无进程数据")
        }
        return lines.joined(separator: "\n")
    }

    private func memoryDetail(_ snapshot: DeviceMetricsDisplaySnapshot) -> String {
        let memory = snapshot.memory
        var lines = [
            "内存占用: \(percent(memory.usageFraction))",
            "总内存: \(storage(memory.totalBytes))",
            "已用内存: \(storage(memory.usedBytes))",
            "可用内存: \(storage(memory.availableBytes))"
        ]
        let top = snapshot.processes.sorted {
            if $0.residentBytes != $1.residentBytes {
                switch ($0.residentBytes, $1.residentBytes) {
                case let (left?, right?): return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return $0.memoryFraction == $1.memoryFraction ? $0.pid < $1.pid : $0.memoryFraction > $1.memoryFraction
        }.prefix(10)
        lines.append("内存占用 Top 10")
        lines.append(contentsOf: top.map {
            let amount = $0.residentBytes.map { DeviceMetricValueFormatter.bytes(Double($0)) } ?? "--"
            return "  \(percent($0.memoryFraction)) · \(amount)  \($0.name)  PID \($0.pid)"
        })
        if top.isEmpty { lines.append("  暂无进程数据") }
        return lines.joined(separator: "\n")
    }

    private func networkDetail(_ snapshot: DeviceMetricsDisplaySnapshot) -> String {
        let latency = snapshot.sshLatencyMilliseconds.map { $0 < 1 ? "<1 ms" : String(format: "%.1f ms", $0) } ?? "--"
        var lines = ["SSH 时延: \(latency)"]
        if snapshot.networks.isEmpty { lines.append("未检测到活动网卡") }
        lines.append(contentsOf: snapshot.networks.flatMap { network in
            [
                "网卡: \(network.interfaceName)",
                "  上传: \(rate(network.transmitBytesPerSecond))    累计: \(storage(network.totalTransmitBytes))",
                "  下载: \(rate(network.receiveBytesPerSecond))    累计: \(storage(network.totalReceiveBytes))"
            ]
        })
        let top = latestProcessSnapshot.filter { $0.networkBytesPerSecond > 0 }.sorted { $0.networkBytesPerSecond > $1.networkBytesPerSecond }.prefix(10)
        lines.append("网络占用 Top 10")
        lines.append(contentsOf: top.map { "  \(rate($0.networkBytesPerSecond))  \($0.name)  PID \($0.pid)" })
        if top.isEmpty { lines.append("  暂无网络进程数据") }
        return lines.joined(separator: "\n")
    }

    private func diskDetail(_ disks: [DeviceDiskDisplayUsage]) -> String {
        guard !disks.isEmpty else { return "未检测到磁盘挂载点" }
        var lines = ["挂载点    占用    已用 / 总量    可用"]
        lines.append(contentsOf: disks.map { disk in
            let available = disk.totalBytes >= disk.usedBytes ? disk.totalBytes - disk.usedBytes : 0
            return "\(disk.mountPath)    \(percent(disk.usageFraction))    \(storage(disk.usedBytes)) / \(storage(disk.totalBytes))    \(storage(available))"
        })
        return lines.joined(separator: "\n")
    }

    private func storage(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func rate(_ bytes: Double) -> String {
        DeviceMetricValueFormatter.bytesPerSecond(bytes)
    }

    private func connectionDuration() -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func collectVisibleText(from view: NSView, into values: inout [String]) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            values.append(field.stringValue)
        }
        for subview in view.subviews {
            collectVisibleText(from: subview, into: &values)
        }
    }
}

private final class DeviceMetricsHoverCell: NSStackView {
    let detailKey: String
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    init(detailKey: String) {
        self.detailKey = detailKey
        super.init(frame: .zero)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        onClick?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

private final class DeviceMetricsHistoryGraphView: NSView {
    static let maximumSampleCount = 48

    private let samples: [CGFloat]
    private let color: NSColor

    init(samples: [Double], color: NSColor, isDanger: Bool, accessibilityIdentifier: String) {
        self.samples = samples.suffix(Self.maximumSampleCount).map { CGFloat(min(max($0, 0), 1)) }
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 54, height: 21))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(accessibilityIdentifier)
        widthAnchor.constraint(equalToConstant: 54).isActive = true
        heightAnchor.constraint(equalToConstant: 21).isActive = true
        if isDanger {
            layer?.shadowColor = color.cgColor
            layer?.shadowOffset = .zero
            layer?.shadowRadius = 5
            let animation = CABasicAnimation(keyPath: "shadowOpacity")
            animation.fromValue = 0.2
            animation.toValue = 0.85
            animation.duration = 1.15
            animation.autoreverses = true
            animation.repeatCount = .infinity
            layer?.add(animation, forKey: "Stacio.Metrics.statusBar.breathingGlow")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, !samples.isEmpty else { return }
        let container = bounds.insetBy(dx: 0.5, dy: 0.5)
        let containerPath = CGPath(
            roundedRect: container,
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        )
        context.addPath(containerPath)
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.62).cgColor)
        context.fillPath()

        let plot = container.insetBy(dx: 3, dy: 3)
        context.saveGState()
        context.addPath(containerPath)
        context.clip()
        context.setStrokeColor(StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(0.5)
        for fraction in [CGFloat(0.25), 0.5, 0.75] {
            let y = plot.minY + plot.height * fraction
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.strokePath()

        let line = CGMutablePath()
        let denominator = CGFloat(max(samples.count - 1, 1))
        for (index, sample) in samples.enumerated() {
            let x = plot.minX + plot.width * CGFloat(index) / denominator
            let y = plot.minY + plot.height * sample
            if index == 0 {
                line.move(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if samples.count == 1, let sample = samples.first {
            line.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + plot.height * sample))
        }

        let fill = line.mutableCopy() ?? CGMutablePath()
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        fill.closeSubpath()
        context.addPath(fill)
        context.setFillColor(color.withAlphaComponent(0.20).cgColor)
        context.fillPath()
        context.addPath(line)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.35)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
        context.restoreGState()
    }
}
