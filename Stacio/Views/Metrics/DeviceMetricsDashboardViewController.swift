import AppKit
import QuartzCore

private enum DeviceMetricsTextColorRole: Int {
    case primary = 31_001
    case secondary = 31_002
    case accent = 31_003
    case success = 31_004
    case warning = 31_005
    case danger = 31_006
}

public final class DeviceMetricsDashboardViewController: NSViewController, NSPopoverDelegate {
    private static let ioBreathingGlowAnimationKey = "Stacio.Metrics.ioBreathingGlow"
    private static let overviewIOFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)

    private let runtimeID: String
    private let dashboardTitle: String
    private let provider: DeviceMetricsProviding
    private let startsPollingAutomatically: Bool
    private let settingsStore: AppSettingsStore
    private let alertCoordinator: DeviceMetricsAlertCoordinator
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var lastSuccessfulSnapshot: DeviceMetricsDisplaySnapshot?
    private var thresholdPopover: NSPopover?
    private var cpuCorePopover: NSPopover?
    private var operatingSystemInfoPopover: NSPopover?

    private let headerTitleLabel = DeviceMetricStaticLabel(text: "设备看板")
    private let hostLabel = DeviceMetricStaticLabel(text: "")
    private let statusLabel = DeviceMetricStaticLabel(text: "等待数据")
    private let systemHostnameValueLabel = DeviceMetricStaticLabel(text: "--")
    private let systemCurrentUserValueLabel = DeviceMetricStaticLabel(text: "--")
    private let systemArchitectureValueLabel = DeviceMetricStaticLabel(text: "--")
    private let systemOperatingSystemValueLabel = DeviceMetricOverflowPopoverLabel(text: "--")
    private let systemUptimeValueLabel = DeviceMetricStaticLabel(text: "--")
    private let systemKernelValueLabel = DeviceMetricStaticLabel(text: "--")
    private let cpuLineChart = DeviceMetricLineChartView()
    private let cpuValueLabel = DeviceMetricStaticLabel(text: "--")
    private let cpuCoreButton = NSButton(title: "-- CPU", target: nil, action: nil)
    private let memoryLineChart = DeviceMetricLineChartView()
    private let memoryValueLabel = DeviceMetricStaticLabel(text: "--")
    private let memoryDetailLabel = DeviceMetricStaticLabel(text: "")
    private let networkIOLineChart = DeviceMetricLineChartView()
    private let networkIOValueLabel = DeviceMetricStaticLabel(text: "不支持")
    private let networkIODetailLabel = DeviceMetricStaticLabel(text: "")
    private let diskIOLineChart = DeviceMetricLineChartView()
    private let diskIOValueLabel = DeviceMetricStaticLabel(text: "读 --")
    private let diskIODetailLabel = DeviceMetricStaticLabel(text: "")
    private let networkPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let networkStack = NSStackView()
    private let diskStack = NSStackView()
    private weak var contentStack: NSStackView?
    private weak var virtualNetworkHintLabel: NSTextField?
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var networkIOHistory: [Double] = []
    private var diskIOHistory: [Double] = []
    private var latestCPUCoreUsages: [DeviceCPUCoreDisplayUsage] = []
    private var latestCPUModel = "--"
    private var latestNetworks: [DeviceNetworkDisplayRate] = []
    private var selectedNetworkNames = Set<String>()
    private var hasManualNetworkSelection = false
    public var metricsDidUpdate: (() -> Void)?

    public init(
        runtimeID: String,
        title: String,
        provider: DeviceMetricsProviding,
        startsPollingAutomatically: Bool = true,
        settingsStore: AppSettingsStore = .shared,
        alertCoordinator: DeviceMetricsAlertCoordinator? = nil
    ) {
        self.runtimeID = runtimeID
        self.dashboardTitle = title
        self.provider = provider
        self.startsPollingAutomatically = startsPollingAutomatically
        self.settingsStore = settingsStore
        let defaultAlertCoordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: { settingsStore.snapshot() },
            notifier: NoopDeviceMetricsAlertNotifier()
        )
        self.alertCoordinator = alertCoordinator ?? defaultAlertCoordinator
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let root = DeviceMetricsAppearanceRefreshView()
        root.onEffectiveAppearanceChanged = { [weak self] appearance in
            self?.refreshThemeForEffectiveAppearanceChange(appearance: appearance)
        }
        root.setAccessibilityIdentifier("Stacio.Metrics.dashboard.\(runtimeID)")
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: .clear)

        let panel = DeviceMetricsPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier("Stacio.Metrics.codexPanel")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("Stacio.Metrics.scrollView")

        let documentView = DeviceMetricsFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setAccessibilityIdentifier("Stacio.Metrics.content")
        contentStack = content

        root.addSubview(panel)
        panel.addSubview(scrollView)
        documentView.addSubview(content)
        scrollView.documentView = documentView

        var sections = [
            makeHeader(),
            makeSystemSection(),
            makeChartRow()
        ]
        let settings = settingsStore.snapshot()
        if settings.deviceMetricsShowNetworkSection {
            sections.append(makeNetworkSection())
        }
        if settings.deviceMetricsShowDiskSection {
            sections.append(makeDiskSection())
        }

        sections.forEach { section in
            content.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: panel.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 10),
            content.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -10)
        ])

        view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateVirtualNetworkHintPreferredWidth()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard startsPollingAutomatically, refreshTimer == nil else { return }
        refreshMetrics()
        let interval = TimeInterval(settingsStore.snapshot().deviceMetricsRefreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshMetrics()
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit {
        refreshTimer?.invalidate()
    }

    public func refreshMetricsForTesting() {
        refreshMetrics()
    }

    public func preferredFloatingHeight(width: CGFloat) -> CGFloat {
        guard isViewLoaded,
              let contentStack
        else { return 180 }
        guard width.isFinite, width > 20 else {
            return 180
        }
        let contentWidth = max(0, floor(width - 20))
        contentStack.frame.size.width = contentWidth
        contentStack.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        // Scroll-view rounding can add a point back to the constrained frame on macOS 14.
        contentStack.frame.size.width = contentWidth
        return ceil(contentHeight + 20)
    }

    public func setSelectedNetworkInterfacesForTesting(_ names: [String]) {
        hasManualNetworkSelection = true
        selectedNetworkNames = Set(names)
        renderNetwork(latestNetworks)
        renderNetworkIO(latestNetworks, appendsHistory: false)
        if let lastSuccessfulSnapshot {
            updateThresholdStyles(for: lastSuccessfulSnapshot)
        }
    }

    public var visibleTextSnapshotForTesting: String {
        view.portDeskVisibleTextSnapshot
    }

    public var metricDrawingAppearanceInvalidationCountForTesting: Int {
        let lineChartCount = [
            cpuLineChart,
            memoryLineChart,
            networkIOLineChart,
            diskIOLineChart
        ].map(\.appearanceInvalidationCountForTesting).reduce(0, +)
        return lineChartCount + diskPieAppearanceInvalidationCount(in: view)
    }

    public func refreshThemeForEffectiveAppearanceChangeForTesting(appearance: NSAppearance? = nil) {
        refreshThemeForEffectiveAppearanceChange(appearance: appearance)
    }

    public func refreshThemeForEffectiveAppearanceChangeForTesting() {
        refreshThemeForEffectiveAppearanceChange()
    }

    public var chartHistorySampleCountsForTesting: (cpu: Int, memory: Int) {
        (cpuHistory.count, memoryHistory.count)
    }

    public var cpuCorePopoverVisibleTextSnapshotForTesting: String? {
        cpuCorePopover?.contentViewController?.view.portDeskVisibleTextSnapshot
    }

    public var cpuCorePopoverPreviewTextSnapshotForTesting: String {
        let controller = DeviceMetricCPUCorePopoverViewController(
            cores: latestCPUCoreUsages,
            cpuModel: latestCPUModel
        )
        return controller.view.portDeskVisibleTextSnapshot
    }

    public var operatingSystemInfoPopoverPreviewTextSnapshotForTesting: String {
        let controller = DeviceMetricFullTextPopoverViewController(
            title: "操作系统",
            value: systemOperatingSystemValueLabel.stringValue
        )
        return controller.view.portDeskVisibleTextSnapshot
    }

    public var isOperatingSystemValueTruncatedForTesting: Bool {
        systemOperatingSystemValueLabel.isTextTruncatedForTesting
    }

    public func showCPUCorePopoverForTesting() {
        showCPUCorePopover(cpuCoreButton)
    }

    public var usesArrowCursorForTesting: Bool {
        (view as? DeviceMetricsArrowCursorView)?.usesArrowCursorForTesting == true
    }

    public func textFieldUsesArrowCursorForTesting(accessibilityIdentifier: String) -> Bool {
        guard let textField = firstSubview(withIdentifier: accessibilityIdentifier, in: view) as? NSTextField else {
            return false
        }
        return (textField as? DeviceMetricStaticLabel)?.usesArrowCursorForTesting == true
    }

    private func firstSubview(withIdentifier identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = firstSubview(withIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
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
                case let .failure(error):
                    self.renderError(error)
                }
            }
            if Thread.isMainThread {
                applyResult()
            } else {
                DispatchQueue.main.async(execute: applyResult)
            }
        }
    }

    private func makeHeader() -> NSView {
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let statusDot = DeviceMetricsStatusDotView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        headerTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        applyTextColorRole(.primary, to: headerTitleLabel)
        headerTitleLabel.setAccessibilityIdentifier("Stacio.Metrics.title")
        hostLabel.stringValue = dashboardTitle
        hostLabel.font = .systemFont(ofSize: 11, weight: .regular)
        applyTextColorRole(.secondary, to: hostLabel)
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.maximumNumberOfLines = 1

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        applyTextColorRole(.secondary, to: statusLabel)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        titleRow.addArrangedSubview(statusDot)
        titleRow.addArrangedSubview(headerTitleLabel)
        header.addArrangedSubview(titleRow)
        header.addArrangedSubview(hostLabel)
        header.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            titleRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            hostLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: header.widthAnchor)
        ])

        return header
    }

    private func makeSystemSection() -> NSView {
        let card = DeviceMetricsTileView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setAccessibilityIdentifier("Stacio.Metrics.section.system")

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "系统")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DeviceMetricStaticLabel(text: "系统")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        applyTextColorRole(.primary, to: titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        header.addArrangedSubview(icon)
        header.addArrangedSubview(titleLabel)

        let grid = NSStackView()
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.distribution = .fillEqually
        grid.spacing = 18
        grid.translatesAutoresizingMaskIntoConstraints = false

        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 10
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        let rightColumn = NSStackView()
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 10
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        leftColumn.addArrangedSubview(makeSystemInfoItem(title: "主机名称", identifier: "hostname", valueLabel: systemHostnameValueLabel))
        leftColumn.addArrangedSubview(makeSystemInfoItem(title: "操作系统", identifier: "operatingSystem", valueLabel: systemOperatingSystemValueLabel))
        leftColumn.addArrangedSubview(makeSystemInfoItem(title: "内核版本", identifier: "kernel", valueLabel: systemKernelValueLabel))
        rightColumn.addArrangedSubview(makeSystemInfoItem(title: "登录用户", identifier: "currentUser", valueLabel: systemCurrentUserValueLabel))
        rightColumn.addArrangedSubview(makeSystemInfoItem(title: "系统架构", identifier: "architecture", valueLabel: systemArchitectureValueLabel))
        rightColumn.addArrangedSubview(makeSystemInfoItem(title: "运行时长", identifier: "uptime", valueLabel: systemUptimeValueLabel))

        grid.addArrangedSubview(leftColumn)
        grid.addArrangedSubview(rightColumn)

        card.addSubview(content)
        content.addArrangedSubview(header)
        content.addArrangedSubview(grid)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 16),
            grid.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        return card
    }

    private func makeSystemInfoItem(title: String, identifier: String, valueLabel: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DeviceMetricStaticLabel(text: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        applyTextColorRole(.primary, to: titleLabel)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("Stacio.Metrics.systemLabel.\(identifier)")

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        applyTextColorRole(.primary, to: valueLabel)
        valueLabel.maximumNumberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setAccessibilityIdentifier("Stacio.Metrics.systemValue.\(identifier)")
        if let overflowLabel = valueLabel as? DeviceMetricOverflowPopoverLabel {
            overflowLabel.onHoverWhenTruncated = { [weak self] label in
                self?.showFullSystemValuePopoverIfNeeded(
                    title: title,
                    value: label.stringValue,
                    from: label
                )
            }
            overflowLabel.onHoverExit = { [weak self] in
                self?.dismissOperatingSystemInfoPopover()
            }
        }

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(valueLabel)
        titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        valueLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeChartRow() -> NSView {
        let section = makeSection(title: "概览", identifier: "Stacio.Metrics.section.overview")
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false

        cpuLineChart.setAccessibilityIdentifier("Stacio.Metrics.cpuLineChart")
        memoryLineChart.setAccessibilityIdentifier("Stacio.Metrics.memoryLineChart")
        networkIOLineChart.setAccessibilityIdentifier("Stacio.Metrics.networkIOLineChart")
        diskIOLineChart.setAccessibilityIdentifier("Stacio.Metrics.diskIOLineChart")
        networkIOValueLabel.setAccessibilityIdentifier("Stacio.Metrics.overview.network.download")
        networkIODetailLabel.setAccessibilityIdentifier("Stacio.Metrics.overview.network.upload")
        diskIOValueLabel.setAccessibilityIdentifier("Stacio.Metrics.overview.disk.read")
        diskIODetailLabel.setAccessibilityIdentifier("Stacio.Metrics.overview.disk.write")
        cpuLineChart.accentColor = StacioDesignSystem.theme.accentColor
        memoryLineChart.accentColor = StacioDesignSystem.theme.successColor
        networkIOLineChart.accentColor = StacioDesignSystem.theme.warningColor
        diskIOLineChart.accentColor = StacioDesignSystem.theme.accentColor
        let settings = settingsStore.snapshot()
        configureCPUCoreButton()

        let topRow = makeMetricTileRow()
        topRow.addArrangedSubview(makeChartTile(
            title: "CPU",
            metric: .cpuUsage,
            valueLabel: cpuValueLabel,
            chart: cpuLineChart,
            accessoryView: cpuCoreButton
        ))
        topRow.addArrangedSubview(makeChartTile(
            title: "内存",
            metric: .memoryUsage,
            valueLabel: memoryValueLabel,
            chart: memoryLineChart,
            detailLabel: memoryDetailLabel
        ))

        let bottomRow = makeMetricTileRow()
        if settings.deviceMetricsShowNetworkSection {
            bottomRow.addArrangedSubview(makeChartTile(
                title: "网络 I/O",
                metric: .networkIO,
                valueLabel: networkIOValueLabel,
                chart: networkIOLineChart,
                detailLabel: networkIODetailLabel
            ))
        }
        if settings.deviceMetricsShowDiskSection {
            bottomRow.addArrangedSubview(makeChartTile(
                title: "磁盘读写",
                metric: .diskIO,
                valueLabel: diskIOValueLabel,
                chart: diskIOLineChart,
                detailLabel: diskIODetailLabel
            ))
        }

        grid.addArrangedSubview(topRow)
        if bottomRow.arrangedSubviews.isEmpty == false {
            grid.addArrangedSubview(bottomRow)
        }
        section.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        topRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        if bottomRow.arrangedSubviews.isEmpty == false {
            bottomRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return section
    }

    private func makeMetricTileRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeChartTile(
        title: String,
        metric: DeviceMetricsAlertMetric,
        valueLabel: NSTextField,
        chart: DeviceMetricLineChartView,
        accessoryView: NSView? = nil,
        detailLabel: NSTextField? = nil
    ) -> NSView {
        let tile = DeviceMetricsTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.setAccessibilityIdentifier("Stacio.Metrics.tile.\(title)")

        let titleLabel = DeviceMetricStaticLabel(text: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        applyTextColorRole(.primary, to: titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let editButton = makeThresholdEditButton(metric: metric)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        applyTextColorRole(.primary, to: valueLabel)
        valueLabel.alignment = .left
        valueLabel.maximumNumberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        chart.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(titleLabel)
        tile.addSubview(editButton)
        tile.addSubview(valueLabel)
        tile.addSubview(chart)
        if let accessoryView {
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(accessoryView)
        }
        if let detailLabel {
            detailLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            applyTextColorRole(.secondary, to: detailLabel)
            detailLabel.alignment = .left
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(detailLabel)
        }

        var constraints = [
            tile.heightAnchor.constraint(equalToConstant: 104),
            titleLabel.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -8),
            editButton.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -8),
            editButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 22),
            editButton.heightAnchor.constraint(equalToConstant: 22),
            valueLabel.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -12),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            chart.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            chart.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            chart.heightAnchor.constraint(equalToConstant: 24),
            chart.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -8)
        ]
        if let detailLabel {
            constraints.append(contentsOf: [
                detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1),
                detailLabel.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
                detailLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
                detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: chart.topAnchor, constant: -3)
            ])
        } else if let accessoryView {
            constraints.append(contentsOf: [
                accessoryView.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1),
                accessoryView.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 8),
                accessoryView.trailingAnchor.constraint(lessThanOrEqualTo: tile.trailingAnchor, constant: -10),
                accessoryView.heightAnchor.constraint(equalToConstant: 20),
                accessoryView.bottomAnchor.constraint(lessThanOrEqualTo: chart.topAnchor, constant: -3)
            ])
        } else {
            constraints.append(valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: chart.topAnchor, constant: -5))
        }
        NSLayoutConstraint.activate(constraints)

        return tile
    }

    private func configureCPUCoreButton() {
        cpuCoreButton.target = self
        cpuCoreButton.action = #selector(showCPUCorePopover(_:))
        cpuCoreButton.isBordered = false
        cpuCoreButton.bezelStyle = .texturedRounded
        cpuCoreButton.imagePosition = .imageLeading
        cpuCoreButton.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        cpuCoreButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        cpuCoreButton.alignment = .left
        cpuCoreButton.lineBreakMode = .byTruncatingMiddle
        cpuCoreButton.cell?.lineBreakMode = .byTruncatingMiddle
        cpuCoreButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cpuCoreButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cpuCoreButton.toolTip = "查看 CPU 核心"
        cpuCoreButton.setAccessibilityLabel("查看 CPU 核心")
        cpuCoreButton.setAccessibilityIdentifier("Stacio.Metrics.cpuCoreButton")
        StacioDesignSystem.styleToolbarButton(cpuCoreButton)
        updateCPUCoreButton(isExpanded: false)
    }

    private func makeThresholdEditButton(metric: DeviceMetricsAlertMetric) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑阈值")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showThresholdPopover(_:))
        button.tag = metric.rawValue
        button.toolTip = "编辑阈值"
        button.setAccessibilityLabel("编辑阈值")
        button.setAccessibilityIdentifier("Stacio.Metrics.thresholdButton.\(metric.accessibilityID)")
        StacioDesignSystem.styleToolbarButton(button)
        return button
    }

    @objc private func showThresholdPopover(_ sender: NSButton) {
        guard let metric = DeviceMetricsAlertMetric(rawValue: sender.tag) else {
            return
        }
        cpuCorePopover?.close()
        operatingSystemInfoPopover?.close()
        thresholdPopover?.close()

        let threshold = alertCoordinator.threshold(for: metric, settingsStore: settingsStore)
        let popover = NSPopover()
        let controller = DeviceMetricThresholdPopoverViewController(
            metric: metric,
            threshold: threshold
        ) { [weak self, weak popover] value in
            guard let self else { return }
            self.alertCoordinator.updateThreshold(value, for: metric, settingsStore: self.settingsStore)
            if let snapshot = self.lastSuccessfulSnapshot {
                self.updateThresholdStyles(for: snapshot)
                self.updateIOMetricChartScales(for: snapshot)
            }
            popover?.close()
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        thresholdPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func showCPUCorePopover(_ sender: NSButton) {
        guard latestCPUCoreUsages.isEmpty == false else {
            return
        }
        thresholdPopover?.close()
        operatingSystemInfoPopover?.close()
        cpuCorePopover?.close()

        let popover = NSPopover()
        let controller = DeviceMetricCPUCorePopoverViewController(
            cores: latestCPUCoreUsages,
            cpuModel: latestCPUModel
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.delegate = self
        cpuCorePopover = popover
        updateCPUCoreButton(isExpanded: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func showFullSystemValuePopoverIfNeeded(
        title: String,
        value: String,
        from label: DeviceMetricOverflowPopoverLabel
    ) {
        guard label.isTextTruncatedForTesting else {
            return
        }
        thresholdPopover?.close()
        cpuCorePopover?.close()
        operatingSystemInfoPopover?.close()

        let popover = NSPopover()
        let controller = DeviceMetricFullTextPopoverViewController(title: title, value: value)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.delegate = self
        operatingSystemInfoPopover = popover
        popover.show(relativeTo: label.bounds, of: label, preferredEdge: .maxY)
    }

    private func dismissOperatingSystemInfoPopover() {
        let popover = operatingSystemInfoPopover
        operatingSystemInfoPopover = nil
        popover?.close()
    }

    public func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else {
            return
        }
        if let currentPopover = cpuCorePopover,
           popover === currentPopover {
            updateCPUCoreButton(isExpanded: false)
            cpuCorePopover = nil
        }
        if let currentPopover = operatingSystemInfoPopover,
           popover === currentPopover {
            operatingSystemInfoPopover = nil
        }
    }

    private func updateIOMetricChartScales(for snapshot: DeviceMetricsDisplaySnapshot) {
        if aggregateNetworkIO(from: snapshot.networks) != nil {
            networkIOLineChart.maximumValue = chartMaximumValue(
                history: networkIOHistory,
                threshold: alertCoordinator.threshold(for: .networkIO, settingsStore: settingsStore).absoluteValue
            )
        }
        if snapshot.diskIO != nil {
            diskIOLineChart.maximumValue = chartMaximumValue(
                history: diskIOHistory,
                threshold: alertCoordinator.threshold(for: .diskIO, settingsStore: settingsStore).absoluteValue
            )
        }
    }

    private func makeNetworkSection() -> NSView {
        let section = makeSection(title: "网络", identifier: "Stacio.Metrics.section.network")
        let pickerRow = NSStackView()
        pickerRow.orientation = .horizontal
        pickerRow.alignment = .centerY
        pickerRow.spacing = 8
        pickerRow.translatesAutoresizingMaskIntoConstraints = false

        let pickerLabel = metricText("显示网卡")
        pickerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pickerLabel.textColor = StacioDesignSystem.theme.primaryTextColor

        networkPicker.setAccessibilityIdentifier("Stacio.Metrics.networkPicker")
        networkPicker.controlSize = .small
        networkPicker.font = .systemFont(ofSize: 11, weight: .medium)
        networkPicker.bezelStyle = .rounded
        networkPicker.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        networkPicker.translatesAutoresizingMaskIntoConstraints = false

        pickerRow.addArrangedSubview(pickerLabel)
        pickerRow.addArrangedSubview(networkPicker)
        section.addArrangedSubview(pickerRow)
        pickerRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        networkPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 138).isActive = true

        networkStack.orientation = .vertical
        networkStack.alignment = .leading
        networkStack.spacing = 0
        networkStack.translatesAutoresizingMaskIntoConstraints = false
        section.addArrangedSubview(networkStack)
        networkStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeDiskSection() -> NSView {
        let section = makeSection(title: "磁盘", identifier: "Stacio.Metrics.section.disks")
        diskStack.orientation = .vertical
        diskStack.alignment = .leading
        diskStack.spacing = 0
        diskStack.translatesAutoresizingMaskIntoConstraints = false
        section.addArrangedSubview(diskStack)
        diskStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeSection(title: String, identifier: String? = nil) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let identifier {
            stack.setAccessibilityIdentifier(identifier)
        }

        let titleLabel = DeviceMetricStaticLabel(text: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        applyTextColorRole(.primary, to: titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("\(identifier ?? "Stacio.Metrics.section").title")

        stack.addArrangedSubview(titleLabel)
        return stack
    }

    private func render(_ snapshot: DeviceMetricsDisplaySnapshot) {
        let settings = settingsStore.snapshot()
        lastSuccessfulSnapshot = snapshot
        statusLabel.stringValue = snapshot.cpuUsage == nil
            ? "实时刷新；CPU 等待第二次采样"
            : "实时刷新"
        renderSystem(snapshot.system)
        let cpuFraction = snapshot.cpuUsage ?? 0
        appendSample(cpuFraction, to: &cpuHistory)
        cpuLineChart.samples = cpuHistory
        cpuLineChart.maximumValue = 1
        cpuValueLabel.stringValue = snapshot.cpuUsage.map { percentText($0) } ?? "--"
        renderCPUCoreSummary(snapshot.cpuCoreUsages)
        appendSample(snapshot.memory.usageFraction, to: &memoryHistory)
        memoryLineChart.samples = memoryHistory
        memoryLineChart.maximumValue = 1
        memoryValueLabel.stringValue = percentText(snapshot.memory.usageFraction)
        memoryDetailLabel.stringValue = "\(byteText(snapshot.memory.usedBytes)) / \(byteText(snapshot.memory.totalBytes))"

        if settings.deviceMetricsShowNetworkSection {
            renderNetworkIO(snapshot.networks)
        }
        if settings.deviceMetricsShowDiskSection {
            renderDiskIO(snapshot.diskIO)
        }
        updateThresholdStyles(for: snapshot)

        if settings.deviceMetricsShowNetworkSection {
            renderNetwork(snapshot.networks)
        }
        if settings.deviceMetricsShowDiskSection {
            renderDisks(snapshot.disks)
        }
        alertCoordinator.process(
            snapshot: snapshot,
            runtimeID: runtimeID,
            sessionTitle: dashboardTitle
        )
        view.needsLayout = true
        metricsDidUpdate?()
    }

    private func renderSystem(_ system: DeviceSystemDisplayInfo) {
        systemHostnameValueLabel.stringValue = system.hostname
        systemCurrentUserValueLabel.stringValue = system.currentUser
        systemArchitectureValueLabel.stringValue = system.architecture
        systemOperatingSystemValueLabel.stringValue = system.operatingSystem
        systemUptimeValueLabel.stringValue = system.uptimeText
        systemKernelValueLabel.stringValue = system.kernelVersion
        latestCPUModel = system.cpuModel
        updateCPUCoreButton(isExpanded: cpuCorePopover?.isShown == true)
        if let controller = cpuCorePopover?.contentViewController as? DeviceMetricCPUCorePopoverViewController {
            controller.update(cpuModel: latestCPUModel)
            cpuCorePopover?.contentSize = controller.preferredContentSize
        }
    }

    private func renderError(_ error: Error) {
        let settings = settingsStore.snapshot()
        if settings.deviceMetricsKeepLastSnapshotOnFailure,
           let lastSuccessfulSnapshot {
            render(lastSuccessfulSnapshot)
            statusLabel.stringValue = [
                "采集失败，已保留上次成功数据（每 \(settings.deviceMetricsRefreshIntervalSeconds) 秒刷新）：\(RuntimeDiagnosticFormatter.userMessage(for: error))",
                "主流 Linux 兼容探针依赖 /proc 与 df；覆盖 CentOS/RHEL、Rocky、Alma、Fedora、Ubuntu、Debian、Alpine 等新老版本。"
            ].joined(separator: "\n")
            return
        }
        statusLabel.stringValue = [
            "采集失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))",
            "主流 Linux 兼容探针依赖 /proc 与 df；覆盖 CentOS/RHEL、Rocky、Alma、Fedora、Ubuntu、Debian、Alpine 等新老版本。"
        ].joined(separator: "\n")
        metricsDidUpdate?()
    }

    private func renderNetwork(_ networks: [DeviceNetworkDisplayRate]) {
        latestNetworks = networks
        if !hasManualNetworkSelection {
            selectedNetworkNames = Set(defaultNetworkSelection(from: networks))
        }
        updateNetworkPickerMenu(for: networks)

        networkStack.arrangedSubviews.forEach { view in
            networkStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !networks.isEmpty else {
            networkStack.addArrangedSubview(metricText("暂无网卡流量"))
            return
        }
        let selectedNetworks = networks.filter { selectedNetworkNames.contains($0.interfaceName) }
        guard !selectedNetworks.isEmpty else {
            networkStack.addArrangedSubview(metricText("未选择网卡"))
            return
        }
        for network in selectedNetworks {
            let row = makeNetworkRow(network)
            networkStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: networkStack.widthAnchor).isActive = true
        }
        appendVirtualNetworkHintIfNeeded(networks: networks)
    }

    private func makeNetworkRow(_ network: DeviceNetworkDisplayRate) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let interfaceLabel = metricText(network.interfaceName)
        interfaceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        interfaceLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        interfaceLabel.setAccessibilityIdentifier("Stacio.Metrics.networkInterface.\(network.interfaceName)")

        let rateStack = NSStackView()
        rateStack.orientation = .horizontal
        rateStack.alignment = .centerY
        rateStack.spacing = 10
        rateStack.translatesAutoresizingMaskIntoConstraints = false
        rateStack.addArrangedSubview(makeNetworkRateLabel(
            direction: .download,
            rate: network.receiveBytesPerSecond,
            interfaceName: network.interfaceName
        ))
        rateStack.addArrangedSubview(makeNetworkRateLabel(
            direction: .upload,
            rate: network.transmitBytesPerSecond,
            interfaceName: network.interfaceName
        ))

        row.addArrangedSubview(interfaceLabel)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(rateStack)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return row
    }

    private enum NetworkRateDirection {
        case download
        case upload

        var title: String {
            switch self {
            case .download:
                return "下载"
            case .upload:
                return "上传"
            }
        }

        var arrow: String {
            switch self {
            case .download:
                return "↓"
            case .upload:
                return "↑"
            }
        }

        var color: NSColor {
            switch self {
            case .download:
                return StacioDesignSystem.theme.accentColor
            case .upload:
                return StacioDesignSystem.theme.successColor
            }
        }

        var textColorRole: DeviceMetricsTextColorRole {
            switch self {
            case .download:
                return .accent
            case .upload:
                return .success
            }
        }

        var accessibilityID: String {
            switch self {
            case .download:
                return "download"
            case .upload:
                return "upload"
            }
        }
    }

    private func makeNetworkRateLabel(
        direction: NetworkRateDirection,
        rate: Double,
        interfaceName: String
    ) -> NSTextField {
        let label = DeviceMetricStaticLabel(text: "\(direction.arrow) \(direction.title) \(rateText(rate))")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        applyTextColorRole(direction.textColorRole, to: label)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("Stacio.Metrics.networkRate.\(direction.accessibilityID).\(interfaceName)")
        return label
    }

    private func updateNetworkPickerMenu(for networks: [DeviceNetworkDisplayRate]) {
        networkPicker.removeAllItems()
        let selectionMode = hasManualNetworkSelection ? "已选" : "活动"
        let title = networks.isEmpty ? "无网卡" : "网卡：\(selectionMode) \(selectedNetworkNames.count) 个"
        networkPicker.addItem(withTitle: title)
        networkPicker.item(at: 0)?.isEnabled = true
        guard !networks.isEmpty,
              let menu = networkPicker.menu
        else { return }

        menu.addItem(.separator())
        let automaticItem = NSMenuItem(title: "自动显示活动网卡", action: #selector(resetNetworkSelectionToAutomatic(_:)), keyEquivalent: "")
        automaticItem.target = self
        automaticItem.state = hasManualNetworkSelection ? .off : .on
        menu.addItem(automaticItem)
        menu.addItem(.separator())

        for network in networks {
            let item = NSMenuItem(title: network.interfaceName, action: #selector(toggleNetworkSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = network.interfaceName
            item.state = selectedNetworkNames.contains(network.interfaceName) ? .on : .off
            menu.addItem(item)
        }
        networkPicker.selectItem(at: 0)
    }

    @objc private func toggleNetworkSelection(_ sender: NSMenuItem) {
        guard let interfaceName = sender.representedObject as? String else { return }
        hasManualNetworkSelection = true
        if selectedNetworkNames.contains(interfaceName) {
            selectedNetworkNames.remove(interfaceName)
        } else {
            selectedNetworkNames.insert(interfaceName)
        }
        renderNetwork(latestNetworks)
        renderNetworkIO(latestNetworks, appendsHistory: false)
        if let lastSuccessfulSnapshot {
            updateThresholdStyles(for: lastSuccessfulSnapshot)
        }
    }

    @objc private func resetNetworkSelectionToAutomatic(_ sender: NSMenuItem) {
        hasManualNetworkSelection = false
        selectedNetworkNames = Set(defaultNetworkSelection(from: latestNetworks))
        renderNetwork(latestNetworks)
        renderNetworkIO(latestNetworks, appendsHistory: false)
        if let lastSuccessfulSnapshot {
            updateThresholdStyles(for: lastSuccessfulSnapshot)
        }
    }

    private func defaultNetworkSelection(from networks: [DeviceNetworkDisplayRate]) -> [String] {
        let settings = settingsStore.snapshot()
        let preferredNetworks = settings.deviceMetricsHideVirtualNetworkInterfaces
            ? networks.filter { isVirtualNetworkInterface($0.interfaceName) == false }
            : networks
        let active = preferredNetworks
            .filter { $0.receiveBytesPerSecond > 0 || $0.transmitBytesPerSecond > 0 }
            .map(\.interfaceName)
        if !active.isEmpty {
            return active
        }
        if let preferred = preferredNetworks.first {
            return [preferred.interfaceName]
        }
        return networks.prefix(1).map(\.interfaceName)
    }

    private func isVirtualNetworkInterface(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased == "lo"
            || lowercased.hasPrefix("docker")
            || lowercased.hasPrefix("br-")
            || lowercased.hasPrefix("veth")
            || lowercased.hasPrefix("virbr")
            || lowercased.hasPrefix("cni")
            || lowercased.hasPrefix("cali")
            || lowercased.hasPrefix("flannel")
            || lowercased.hasPrefix("ovn")
            || lowercased.hasPrefix("tun")
            || lowercased.hasPrefix("tap")
            || lowercased.hasPrefix("tailscale")
            || lowercased.hasPrefix("zt")
            || lowercased.hasPrefix("wg")
    }

    private func appendVirtualNetworkHintIfNeeded(networks: [DeviceNetworkDisplayRate]) {
        guard hasManualNetworkSelection == false else {
            return
        }
        guard settingsStore.snapshot().deviceMetricsHideVirtualNetworkInterfaces else {
            return
        }
        let hiddenVirtualCount = networks.filter { network in
            isVirtualNetworkInterface(network.interfaceName)
                && selectedNetworkNames.contains(network.interfaceName) == false
        }.count
        guard hiddenVirtualCount > 0 else {
            return
        }
        let hint = metricText("已自动隐藏 \(hiddenVirtualCount) 个虚拟网卡\n可在网卡菜单手动显示")
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.cell?.wraps = true
        hint.cell?.lineBreakMode = .byWordWrapping
        hint.cell?.usesSingleLineMode = false
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        hint.setAccessibilityIdentifier("Stacio.Metrics.networkVirtualHint")
        virtualNetworkHintLabel = hint
        networkStack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: networkStack.widthAnchor).isActive = true
        updateVirtualNetworkHintPreferredWidth()
    }

    private func updateVirtualNetworkHintPreferredWidth() {
        guard let virtualNetworkHintLabel else {
            return
        }
        let preferredWidth = virtualNetworkHintLabel.bounds.width > 0
            ? virtualNetworkHintLabel.bounds.width
            : networkStack.bounds.width
        guard preferredWidth > 0 else {
            return
        }
        guard abs(virtualNetworkHintLabel.preferredMaxLayoutWidth - preferredWidth) > 0.5 else {
            return
        }
        virtualNetworkHintLabel.preferredMaxLayoutWidth = preferredWidth
        virtualNetworkHintLabel.invalidateIntrinsicContentSize()
        virtualNetworkHintLabel.superview?.needsLayout = true
    }

    private func appendSample(_ sample: Double, to history: inout [Double]) {
        history.append(max(sample, 0))
        let settings = settingsStore.snapshot()
        let sixtySecondSampleCount = max(
            3,
            Int(ceil(60.0 / Double(settings.deviceMetricsRefreshIntervalSeconds)))
        )
        let maxHistorySampleCount = min(settings.deviceMetricsHistorySampleCount, sixtySecondSampleCount)
        if history.count > maxHistorySampleCount {
            history.removeFirst(history.count - maxHistorySampleCount)
        }
    }

    private func renderCPUCoreSummary(_ cores: [DeviceCPUCoreDisplayUsage]) {
        latestCPUCoreUsages = cores
        updateCPUCoreButton(isExpanded: cpuCorePopover?.isShown == true)
        if let controller = cpuCorePopover?.contentViewController as? DeviceMetricCPUCorePopoverViewController {
            controller.update(cores: cores, cpuModel: latestCPUModel)
            cpuCorePopover?.contentSize = controller.preferredContentSize
        }
    }

    private func updateCPUCoreButton(isExpanded: Bool) {
        let count = latestCPUCoreUsages.count
        let coreTitle = count > 0 ? "\(count) CPU" : "-- CPU"
        let model = latestCPUModel.trimmingCharacters(in: .whitespacesAndNewlines)
        cpuCoreButton.title = coreTitle
        cpuCoreButton.toolTip = model.isEmpty || model == "--"
            ? "查看 CPU 核心"
            : "查看 CPU 核心：\(model)"
        cpuCoreButton.isEnabled = count > 0
        cpuCoreButton.alphaValue = count > 0 ? 1 : 0.58
        cpuCoreButton.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )
    }

    private func renderNetworkIO(_ networks: [DeviceNetworkDisplayRate], appendsHistory: Bool = true) {
        guard let aggregate = aggregateNetworkIO(from: networks) else {
            networkIOValueLabel.stringValue = "不支持"
            applyOverviewIOLabelStyle(networkIOValueLabel, normalRole: .primary)
            networkIODetailLabel.stringValue = "/proc/net/dev"
            applyOverviewIOLabelStyle(networkIODetailLabel, normalRole: .secondary)
            networkIOLineChart.samples = []
            networkIOLineChart.isBreachingThreshold = false
            return
        }

        let peak = max(aggregate.receiveBytesPerSecond, aggregate.transmitBytesPerSecond)
        if appendsHistory {
            appendSample(peak, to: &networkIOHistory)
        }
        networkIOLineChart.samples = networkIOHistory
        networkIOLineChart.maximumValue = chartMaximumValue(
            history: networkIOHistory,
            threshold: alertCoordinator.threshold(for: .networkIO, settingsStore: settingsStore).absoluteValue
        )
        networkIOValueLabel.stringValue = "↓ 下载 \(rateText(aggregate.receiveBytesPerSecond))"
        applyOverviewIOLabelStyle(
            networkIOValueLabel,
            normalRole: .accent,
            rate: aggregate.receiveBytesPerSecond,
            metric: .networkIO
        )
        networkIODetailLabel.stringValue = "↑ 上传 \(rateText(aggregate.transmitBytesPerSecond))"
        applyOverviewIOLabelStyle(
            networkIODetailLabel,
            normalRole: .success,
            rate: aggregate.transmitBytesPerSecond,
            metric: .networkIO
        )
    }

    private func renderDiskIO(_ diskIO: DeviceDiskIODisplayRate?) {
        guard let diskIO else {
            diskIOValueLabel.stringValue = "↓ 读 --"
            applyOverviewIOLabelStyle(diskIOValueLabel, normalRole: .primary)
            diskIODetailLabel.stringValue = "↑ 写 --"
            applyOverviewIOLabelStyle(diskIODetailLabel, normalRole: .secondary)
            diskIOLineChart.samples = []
            diskIOLineChart.isBreachingThreshold = false
            return
        }

        appendSample(diskIO.peakBytesPerSecond, to: &diskIOHistory)
        diskIOLineChart.samples = diskIOHistory
        diskIOLineChart.maximumValue = chartMaximumValue(
            history: diskIOHistory,
            threshold: alertCoordinator.threshold(for: .diskIO, settingsStore: settingsStore).absoluteValue
        )
        diskIOValueLabel.stringValue = "↓ 读 \(rateText(diskIO.readBytesPerSecond))"
        applyOverviewIOLabelStyle(
            diskIOValueLabel,
            normalRole: .accent,
            rate: diskIO.readBytesPerSecond,
            metric: .diskIO
        )
        diskIODetailLabel.stringValue = "↑ 写 \(rateText(diskIO.writeBytesPerSecond))"
        applyOverviewIOLabelStyle(
            diskIODetailLabel,
            normalRole: .warning,
            rate: diskIO.writeBytesPerSecond,
            metric: .diskIO
        )
    }

    private func applyOverviewIOLabelStyle(
        _ label: NSTextField,
        normalRole: DeviceMetricsTextColorRole,
        rate: Double? = nil,
        metric: DeviceMetricsAlertMetric? = nil
    ) {
        label.font = Self.overviewIOFont
        let isBreaching = rate.flatMap { rate in
            metric.map {
                alertCoordinator.isBreachingThreshold(value: rate, for: $0, settingsStore: settingsStore)
            }
        } ?? false
        let role: DeviceMetricsTextColorRole = isBreaching ? .danger : normalRole
        label.tag = role.rawValue
        let color = color(for: role)
        label.textColor = color
        if isBreaching {
            startBreathingGlow(on: label, color: color)
        } else {
            stopBreathingGlow(on: label)
        }
    }

    private func startBreathingGlow(on label: NSTextField, color: NSColor) {
        label.wantsLayer = true
        guard let layer = label.layer else {
            return
        }
        layer.masksToBounds = false
        layer.shadowColor = color.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 7
        layer.shadowOpacity = 0.65
        guard layer.animation(forKey: Self.ioBreathingGlowAnimationKey) == nil else {
            return
        }

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0.18
        shadow.toValue = 0.9

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.82
        opacity.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [shadow, opacity]
        group.duration = 1.05
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: Self.ioBreathingGlowAnimationKey)
    }

    private func stopBreathingGlow(on label: NSTextField) {
        guard let layer = label.layer else {
            return
        }
        layer.removeAnimation(forKey: Self.ioBreathingGlowAnimationKey)
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowColor = nil
    }

    private func updateThresholdStyles(for snapshot: DeviceMetricsDisplaySnapshot) {
        cpuLineChart.isBreachingThreshold = snapshot.cpuUsage.map {
            alertCoordinator.isBreachingThreshold(value: $0, for: .cpuUsage, settingsStore: settingsStore)
        } ?? false
        memoryLineChart.isBreachingThreshold = alertCoordinator.isBreachingThreshold(
            value: snapshot.memory.usageFraction,
            for: .memoryUsage,
            settingsStore: settingsStore
        )
        if let aggregate = aggregateNetworkIO(from: snapshot.networks) {
            networkIOLineChart.isBreachingThreshold = alertCoordinator.isBreachingThreshold(
                value: max(aggregate.receiveBytesPerSecond, aggregate.transmitBytesPerSecond),
                for: .networkIO,
                settingsStore: settingsStore
            )
        }
        if let diskIO = snapshot.diskIO {
            diskIOLineChart.isBreachingThreshold = alertCoordinator.isBreachingThreshold(
                value: diskIO.peakBytesPerSecond,
                for: .diskIO,
                settingsStore: settingsStore
            )
        }
    }

    private func chartMaximumValue(history: [Double], threshold: Double) -> Double {
        max(history.max() ?? 0, threshold, 1)
    }

    private func aggregateNetworkIO(
        from networks: [DeviceNetworkDisplayRate]
    ) -> (receiveBytesPerSecond: Double, transmitBytesPerSecond: Double)? {
        let selectedNames = hasManualNetworkSelection
            ? selectedNetworkNames
            : Set(defaultNetworkSelection(from: networks))
        let selectedNetworks = networks.filter { selectedNames.contains($0.interfaceName) }
        guard selectedNetworks.isEmpty == false else {
            return nil
        }
        return selectedNetworks.reduce(into: (receiveBytesPerSecond: 0.0, transmitBytesPerSecond: 0.0)) { total, network in
            total.receiveBytesPerSecond += network.receiveBytesPerSecond
            total.transmitBytesPerSecond += network.transmitBytesPerSecond
        }
    }

    private func renderDisks(_ disks: [DeviceDiskDisplayUsage]) {
        diskStack.arrangedSubviews.forEach { view in
            diskStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !disks.isEmpty else {
            diskStack.addArrangedSubview(metricText("暂无分区数据"))
            return
        }
        let visibleDiskLimit = settingsStore.snapshot().deviceMetricsDiskMountLimit
        for disk in disks.prefix(visibleDiskLimit) {
            let row = makeDiskRow(disk)
            diskStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: diskStack.widthAnchor).isActive = true
        }
        if disks.count > visibleDiskLimit {
            let hiddenCount = disks.count - visibleDiskLimit
            diskStack.addArrangedSubview(metricText("另有 \(hiddenCount) 个挂载点"))
        }
    }

    private func refreshThemeForEffectiveAppearanceChange(appearance: NSAppearance? = nil) {
        guard isViewLoaded else { return }
        let effectiveAppearance = appearance ?? view.effectiveAppearance
        refreshMetricsSurfaceColors(in: view, appearance: effectiveAppearance)
        StacioDesignSystem.refreshDynamicLayerColors(in: view)
        refreshTextColors(in: view, appearance: effectiveAppearance)
        [
            cpuLineChart,
            memoryLineChart,
            networkIOLineChart,
            diskIOLineChart
        ].forEach { $0.invalidateForEffectiveAppearanceChange() }
        invalidateDiskPieViewsForAppearanceChange(in: view)
        view.needsDisplay = true
        view.needsLayout = true
    }

    private func refreshMetricsSurfaceColors(in root: NSView, appearance: NSAppearance) {
        if let panel = root as? DeviceMetricsPanelView {
            panel.refreshAppearanceColors(appearance: appearance)
        }
        if let tile = root as? DeviceMetricsTileView {
            tile.refreshAppearanceColors(appearance: appearance)
        }
        root.subviews.forEach { refreshMetricsSurfaceColors(in: $0, appearance: appearance) }
    }

    private func refreshTextColors(in root: NSView, appearance: NSAppearance) {
        if let label = root as? NSTextField {
            if let role = DeviceMetricsTextColorRole(rawValue: label.tag) {
                label.textColor = color(for: role, appearance: appearance)
            } else {
                label.textColor = color(for: .secondary, appearance: appearance)
            }
            label.needsDisplay = true
        }
        root.subviews.forEach { refreshTextColors(in: $0, appearance: appearance) }
    }

    private func applyTextColorRole(_ role: DeviceMetricsTextColorRole, to label: NSTextField) {
        label.tag = role.rawValue
        label.textColor = color(for: role)
    }

    private func color(
        for role: DeviceMetricsTextColorRole,
        appearance: NSAppearance? = nil
    ) -> NSColor {
        let color: NSColor
        switch role {
        case .primary:
            color = StacioDesignSystem.theme.primaryTextColor
        case .secondary:
            color = StacioDesignSystem.theme.secondaryTextColor
        case .accent:
            color = StacioDesignSystem.theme.accentColor
        case .success:
            color = StacioDesignSystem.theme.successColor
        case .warning:
            color = NSColor.systemOrange
        case .danger:
            color = StacioDesignSystem.theme.dangerColor
        }
        guard let appearance else {
            return color
        }
        return StacioDesignSystem.resolvedColor(color, for: appearance)
    }

    private func invalidateDiskPieViewsForAppearanceChange(in root: NSView) {
        if let pie = root as? DeviceDiskPieView {
            pie.invalidateForEffectiveAppearanceChange()
        }
        root.subviews.forEach { invalidateDiskPieViewsForAppearanceChange(in: $0) }
    }

    private func diskPieAppearanceInvalidationCount(in root: NSView) -> Int {
        let ownCount = (root as? DeviceDiskPieView)?.appearanceInvalidationCountForTesting ?? 0
        return root.subviews.reduce(ownCount) { total, subview in
            total + diskPieAppearanceInvalidationCount(in: subview)
        }
    }

    private func makeDiskRow(_ disk: DeviceDiskDisplayUsage) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false

        let pie = DeviceDiskPieView()
        pie.progress = disk.usageFraction
        pie.setAccessibilityIdentifier("Stacio.Metrics.diskPie.\(disk.mountPath)")
        pie.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = metricText(disk.mountPath)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        applyTextColorRole(.accent, to: titleLabel)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setAccessibilityIdentifier("Stacio.Metrics.diskTitle.\(disk.mountPath)")
        let detailLabel = metricText("\(percentText(disk.usageFraction))  \(byteText(disk.usedBytes)) / \(byteText(disk.totalBytes))")
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        applyTextColorRole(diskUsageTextRole(for: disk.usageFraction), to: detailLabel)
        detailLabel.setAccessibilityIdentifier("Stacio.Metrics.diskDetail.\(disk.mountPath)")
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        row.addArrangedSubview(pie)
        row.addArrangedSubview(textStack)
        row.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        NSLayoutConstraint.activate([
            pie.widthAnchor.constraint(equalToConstant: 32),
            pie.heightAnchor.constraint(equalToConstant: 32)
        ])
        return row
    }

    private func diskUsageTextRole(for fraction: Double) -> DeviceMetricsTextColorRole {
        if alertCoordinator.isBreachingThreshold(value: fraction, for: .diskUsage, settingsStore: settingsStore) {
            return .danger
        }
        if fraction >= 0.75 {
            return .warning
        }
        return .success
    }

    private func metricText(_ value: String) -> NSTextField {
        let label = DeviceMetricStaticLabel(text: value)
        applyTextColorRole(.secondary, to: label)
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        "\(byteText(UInt64(max(bytesPerSecond, 0))))/s"
    }

    private func byteText(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

private class DeviceMetricsArrowCursorView: NSView {
    var usesArrowCursorForTesting: Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

private class DeviceMetricStaticLabel: NSTextField {
    var usesArrowCursorForTesting: Bool {
        true
    }

    init(text: String, wraps: Bool = false) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        maximumNumberOfLines = wraps ? 0 : 1
        lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        cell?.wraps = wraps
        cell?.isScrollable = false
        if wraps == false {
            cell?.usesSingleLineMode = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

private final class DeviceMetricOverflowPopoverLabel: DeviceMetricStaticLabel {
    var onHoverWhenTruncated: ((DeviceMetricOverflowPopoverLabel) -> Void)?
    var onHoverExit: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    var isTextTruncatedForTesting: Bool {
        guard bounds.width > 0,
              stringValue.isEmpty == false
        else {
            return false
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        let textWidth = ceil((stringValue as NSString).size(withAttributes: attributes).width)
        return textWidth > ceil(bounds.width) + 1
    }

    init(text: String) {
        super.init(text: text)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isTextTruncatedForTesting else {
            return
        }
        onHoverWhenTruncated?(self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverExit?()
    }
}

private final class DeviceMetricsPanelView: DeviceMetricsArrowCursorView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let edgeShadow = NSShadow()
        edgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        edgeShadow.shadowOffset = NSSize(width: 0, height: -1)
        edgeShadow.shadowBlurRadius = 10
        shadow = edgeShadow
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: StacioDesignSystem.metricsFloatingSurfaceColor(for: self)
        )
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBorderColor(self, color: nil)
        layer?.borderWidth = 0
    }

    func refreshAppearanceColors(appearance: NSAppearance) {
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: StacioDesignSystem.metricsFloatingSurfaceColor(for: appearance)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class DeviceMetricsAppearanceRefreshView: DeviceMetricsArrowCursorView {
    var onEffectiveAppearanceChanged: ((NSAppearance) -> Void)?
    private var windowAppearanceObservation: NSKeyValueObservation?
    private var systemAppearanceObserver: NSObjectProtocol?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleEffectiveAppearanceRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installSystemAppearanceObserverIfNeeded()
        windowAppearanceObservation = nil
        if let window {
            windowAppearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                self?.scheduleEffectiveAppearanceRefresh()
            }
        }
        scheduleEffectiveAppearanceRefresh()
    }

    deinit {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
        }
    }

    private func installSystemAppearanceObserverIfNeeded() {
        guard systemAppearanceObserver == nil else { return }
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleEffectiveAppearanceRefresh()
        }
    }

    private func scheduleEffectiveAppearanceRefresh() {
        refreshEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.refreshEffectiveAppearance()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.refreshEffectiveAppearance()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshEffectiveAppearance()
        }
    }

    private func refreshEffectiveAppearance() {
        let targetAppearance = window?.effectiveAppearance ?? effectiveAppearance
        appearance = targetAppearance
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
        onEffectiveAppearanceChanged?(targetAppearance)
    }
}

private final class DeviceMetricsTileView: DeviceMetricsArrowCursorView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: StacioDesignSystem.metricsFloatingSurfaceColor(for: self)
        )
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.12)
        )
        layer?.borderWidth = 0.5
        let edgeShadow = NSShadow()
        edgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.045)
        edgeShadow.shadowOffset = NSSize(width: 0, height: -0.5)
        edgeShadow.shadowBlurRadius = 5
        shadow = edgeShadow
    }

    func refreshAppearanceColors(appearance: NSAppearance) {
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: StacioDesignSystem.metricsFloatingSurfaceColor(for: appearance)
        )
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.12)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class DeviceMetricsStatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(self, color: StacioDesignSystem.theme.successColor)
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class DeviceMetricsFlippedView: DeviceMetricsArrowCursorView {
    override var isFlipped: Bool { true }
}

private final class DeviceMetricFullTextPopoverViewController: NSViewController {
    private let titleText: String
    private let valueText: String

    init(title: String, value: String) {
        titleText = title
        valueText = value
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.contentSize(for: value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        root.layer?.cornerCurve = .continuous
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Metrics.fullTextPopover")

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DeviceMetricStaticLabel(text: titleText)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = DeviceMetricStaticLabel(text: valueText, wraps: true)
        valueLabel.font = .systemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        valueLabel.maximumNumberOfLines = 0
        valueLabel.preferredMaxLayoutWidth = Self.contentWidth
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(content)
        content.addArrangedSubview(titleLabel)
        content.addArrangedSubview(valueLabel)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            valueLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        view = root
    }

    private static let contentWidth: CGFloat = 300

    private static func contentSize(for value: String) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular)
        ]
        let bounding = (value as NSString).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return NSSize(width: contentWidth + 28, height: min(max(72, ceil(bounding.height) + 54), 180))
    }
}

private final class DeviceMetricCPUCorePopoverViewController: NSViewController {
    private var cores: [DeviceCPUCoreDisplayUsage]
    private var cpuModel: String
    private let rowStack = NSStackView()
    private let cpuModelLabel = DeviceMetricStaticLabel(text: "")

    init(cores: [DeviceCPUCoreDisplayUsage], cpuModel: String) {
        self.cores = cores
        self.cpuModel = cpuModel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.contentSize(for: cores.count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        root.layer?.cornerCurve = .continuous
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Metrics.cpuCorePopover")

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        cpuModelLabel.stringValue = Self.displayCPUModel(cpuModel)
        cpuModelLabel.font = .systemFont(ofSize: 11, weight: .medium)
        cpuModelLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        cpuModelLabel.maximumNumberOfLines = 1
        cpuModelLabel.lineBreakMode = .byTruncatingMiddle
        cpuModelLabel.toolTip = cpuModelLabel.stringValue
        cpuModelLabel.translatesAutoresizingMaskIntoConstraints = false
        cpuModelLabel.setAccessibilityIdentifier("Stacio.Metrics.cpuCorePopover.cpuModel")

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = DeviceMetricStaticLabel(text: "CPU 核心")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = DeviceMetricStaticLabel(text: "\(cores.count) CPU")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(countLabel)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = cores.count > 8
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = DeviceMetricsFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(content)
        content.addArrangedSubview(cpuModelLabel)
        content.addArrangedSubview(header)
        content.addArrangedSubview(scrollView)
        documentView.addSubview(rowStack)
        scrollView.documentView = documentView
        rebuildRows()

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            cpuModelLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.rowsHeight(for: cores.count)),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            rowStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor)
        ])

        view = root
    }

    func update(cores: [DeviceCPUCoreDisplayUsage], cpuModel: String) {
        self.cores = cores
        self.cpuModel = cpuModel
        preferredContentSize = Self.contentSize(for: cores.count)
        guard isViewLoaded else {
            return
        }
        updateCPUModelLabel()
        rebuildRows()
    }

    func update(cpuModel: String) {
        self.cpuModel = cpuModel
        preferredContentSize = Self.contentSize(for: cores.count)
        guard isViewLoaded else {
            return
        }
        updateCPUModelLabel()
    }

    private func updateCPUModelLabel() {
        cpuModelLabel.stringValue = Self.displayCPUModel(cpuModel)
        cpuModelLabel.toolTip = cpuModelLabel.stringValue
    }

    private func rebuildRows() {
        rowStack.arrangedSubviews.forEach { view in
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for core in cores {
            let row = makeCoreRow(core)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func makeCoreRow(_ core: DeviceCPUCoreDisplayUsage) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let indexLabel = DeviceMetricStaticLabel(text: "\(core.index + 1)")
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        indexLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        indexLabel.alignment = .right
        indexLabel.translatesAutoresizingMaskIntoConstraints = false

        let bar = DeviceMetricCPUCoreUsageBarView()
        bar.usageFraction = core.usage ?? 0
        bar.isUnavailable = core.usage == nil
        bar.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = DeviceMetricStaticLabel(text: core.usage.map(Self.percentText) ?? "--")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addArrangedSubview(indexLabel)
        row.addArrangedSubview(bar)
        row.addArrangedSubview(valueLabel)
        NSLayoutConstraint.activate([
            indexLabel.widthAnchor.constraint(equalToConstant: 20),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            bar.heightAnchor.constraint(equalToConstant: 12),
            valueLabel.widthAnchor.constraint(equalToConstant: 54)
        ])
        return row
    }

    private static func rowsHeight(for count: Int) -> CGFloat {
        CGFloat(min(max(count, 1), 8)) * 24
    }

    private static func contentSize(for count: Int) -> NSSize {
        NSSize(width: 360, height: rowsHeight(for: count) + 76)
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", min(max(value, 0), 1) * 100)
    }

    private static func displayCPUModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "--" ? "CPU 型号未知" : trimmed
    }
}

private final class DeviceMetricCPUCoreUsageBarView: NSView {
    var usageFraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var isUnavailable = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let barRect = bounds.insetBy(dx: 0, dy: 3)
        let radius = barRect.height / 2
        context.setFillColor(StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.45).cgColor)
        context.addPath(CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()

        guard isUnavailable == false else {
            return
        }
        let clamped = min(max(usageFraction, 0), 1)
        let fillRect = CGRect(
            x: barRect.minX,
            y: barRect.minY,
            width: max(radius, barRect.width * clamped),
            height: barRect.height
        )
        context.setFillColor(StacioDesignSystem.theme.accentColor.cgColor)
        context.addPath(CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }
}

private final class DeviceMetricThresholdPopoverViewController: NSViewController {
    private let metric: DeviceMetricsAlertMetric
    private let threshold: DeviceMetricsAlertThreshold
    private let onCommit: (Double) -> Void
    private let valueField = NSTextField()

    init(
        metric: DeviceMetricsAlertMetric,
        threshold: DeviceMetricsAlertThreshold,
        onCommit: @escaping (Double) -> Void
    ) {
        self.metric = metric
        self.threshold = threshold
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 220, height: 104)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: StacioDesignSystem.theme.controlBackgroundColor)

        let titleLabel = DeviceMetricStaticLabel(text: "\(metric.displayName) 阈值")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueField.stringValue = Self.fieldText(for: threshold)
        valueField.alignment = .right
        valueField.target = self
        valueField.action = #selector(commitThreshold(_:))
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.setAccessibilityIdentifier("Stacio.Metrics.thresholdPopover.value")
        StacioDesignSystem.styleTextField(valueField)

        let unitLabel = DeviceMetricStaticLabel(text: metric.thresholdUnitLabel)
        unitLabel.font = .systemFont(ofSize: 11, weight: .medium)
        unitLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        unitLabel.translatesAutoresizingMaskIntoConstraints = false

        let confirmButton = NSButton(title: "确认", target: self, action: #selector(commitThreshold(_:)))
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setAccessibilityIdentifier("Stacio.Metrics.thresholdPopover.confirm")
        StacioDesignSystem.styleProminentButton(confirmButton)

        root.addSubview(titleLabel)
        root.addSubview(valueField)
        root.addSubview(unitLabel)
        root.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),

            valueField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            valueField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            valueField.widthAnchor.constraint(equalToConstant: 116),
            valueField.heightAnchor.constraint(equalToConstant: 30),

            unitLabel.leadingAnchor.constraint(equalTo: valueField.trailingAnchor, constant: 8),
            unitLabel.centerYAnchor.constraint(equalTo: valueField.centerYAnchor),
            unitLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),

            confirmButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            confirmButton.topAnchor.constraint(equalTo: valueField.bottomAnchor, constant: 10),
            confirmButton.widthAnchor.constraint(equalToConstant: 68),
            confirmButton.heightAnchor.constraint(equalToConstant: 28),
            confirmButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(valueField)
        valueField.selectText(nil)
    }

    @objc private func commitThreshold(_ sender: Any?) {
        let raw = valueField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        onCommit(Double(raw) ?? threshold.displayValue)
    }

    private static func fieldText(for threshold: DeviceMetricsAlertThreshold) -> String {
        switch threshold.unit {
        case .percent:
            return "\(Int(threshold.displayValue.rounded()))"
        case .megabytesPerSecond:
            return String(format: "%.1f", threshold.displayValue)
        }
    }
}

private final class DeviceMetricLineChartView: NSView {
    private(set) var appearanceInvalidationCountForTesting = 0

    var samples: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var accentColor: NSColor = StacioDesignSystem.theme.accentColor {
        didSet { needsDisplay = true }
    }
    var maximumValue: Double = 1 {
        didSet { needsDisplay = true }
    }
    var isBreachingThreshold = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateForEffectiveAppearanceChange()
    }

    func invalidateForEffectiveAppearanceChange() {
        appearanceInvalidationCountForTesting += 1
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let graphRect = bounds.insetBy(dx: 2, dy: 6)
        guard graphRect.width > 2,
              graphRect.height > 2,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.18).cgColor)
        context.move(to: CGPoint(x: graphRect.minX, y: graphRect.maxY))
        context.addLine(to: CGPoint(x: graphRect.maxX, y: graphRect.maxY))
        context.strokePath()

        context.setLineWidth(0.5)
        context.setStrokeColor(StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.08).cgColor)
        for fraction in [0.25, 0.5, 0.75] {
            let y = graphRect.minY + graphRect.height * fraction
            context.move(to: CGPoint(x: graphRect.minX, y: y))
            context.addLine(to: CGPoint(x: graphRect.maxX, y: y))
        }
        context.strokePath()

        let scale = max(maximumValue, 1)
        let normalizedSamples = samples.isEmpty ? [0] : samples.map { min(max($0 / scale, 0), 1) }
        let step = normalizedSamples.count > 1 ? graphRect.width / CGFloat(normalizedSamples.count - 1) : 0
        context.beginPath()
        for (index, sample) in normalizedSamples.enumerated() {
            let x = graphRect.minX + CGFloat(index) * step
            let y = graphRect.maxY - CGFloat(sample) * graphRect.height
            if index == 0 {
                context.move(to: CGPoint(x: x, y: y))
            } else {
                context.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        let strokeColor = isBreachingThreshold
            ? StacioDesignSystem.theme.dangerColor
            : accentColor
        context.setStrokeColor(strokeColor.cgColor)
        context.strokePath()
        context.restoreGState()
    }
}

private final class DeviceDiskPieView: NSView {
    private(set) var appearanceInvalidationCountForTesting = 0

    var progress: Double = 0 {
        didSet {
            progress = min(max(progress, 0), 1)
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateForEffectiveAppearanceChange()
    }

    func invalidateForEffectiveAppearanceChange() {
        appearanceInvalidationCountForTesting += 1
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let background = NSBezierPath(ovalIn: rect)
        StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.35).setFill()
        background.fill()

        guard progress > 0 else { return }
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: -90,
            endAngle: -90 + CGFloat(progress) * 360,
            clockwise: false
        )
        wedge.close()
        StacioDesignSystem.theme.accentColor.setFill()
        wedge.fill()

        let innerRect = rect.insetBy(dx: 8, dy: 8)
        StacioDesignSystem.theme.workspaceBackgroundColor.setFill()
        NSBezierPath(ovalIn: innerRect).fill()
    }
}

private extension NSView {
    var portDeskVisibleTextSnapshot: String {
        var values: [String] = []
        collectVisibleText(into: &values)
        return values.joined(separator: "\n") + (values.isEmpty ? "" : "\n")
    }

    private func collectVisibleText(into values: inout [String]) {
        guard !isHidden else { return }
        if let label = self as? NSTextField, label.isEditable == false {
            let value = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values.append(value)
            }
        }
        subviews.forEach { $0.collectVisibleText(into: &values) }
    }
}
