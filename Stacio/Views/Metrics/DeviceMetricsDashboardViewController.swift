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

public final class DeviceMetricsDashboardViewController: NSViewController, NSPopoverDelegate, DeviceMetricsPollingControlling {
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
    private var lastRefreshError: Error?
    private var thresholdPopover: NSPopover?
    private var cpuCorePopover: NSPopover?
    private var operatingSystemInfoPopover: NSPopover?
    private var historyPopover: NSPopover?
    private let hoverDetailPresenter = DeviceMetricsDashboardHoverPresenter()
    private weak var overviewChartGrid: NSView?
    private weak var hoveredMetricTile: NSView?
    private var hoverDetailsAvailable = false

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
    private weak var dashboardHeaderStack: NSStackView?
    private weak var dashboardScrollView: NSScrollView?
    private var cachedPreferredFloatingHeight: (width: CGFloat, height: CGFloat)?
    private weak var virtualNetworkHintLabel: NSTextField?
    private var cpuHistory: [Double] = []
    private var memoryHistory: [Double] = []
    private var networkIOHistory: [Double] = []
    private var diskIOHistory: [Double] = []
    private var cpuHistorySamples: [DeviceMetricHistorySample] = []
    private var memoryHistorySamples: [DeviceMetricHistorySample] = []
    private var networkIOHistorySamples: [DeviceMetricHistorySample] = []
    private var diskIOHistorySamples: [DeviceMetricHistorySample] = []
    private var diskUsageHistorySamples: [String: [DeviceMetricHistorySample]] = [:]
    private var latestCPUCoreUsages: [DeviceCPUCoreDisplayUsage] = []
    private var latestCPUModel = "--"
    private var latestNetworks: [DeviceNetworkDisplayRate] = []
    private var latestProcesses: [DeviceProcessDisplayInfo] = []
    private var latestPorts: [DevicePortDisplayInfo] = []
    private var latestServices: [DeviceServiceDisplayInfo] = []
    private var latestContainers: [DeviceContainerDisplayInfo] = []
    private let inventoryTabControl = NSSegmentedControl(labels: ["概览", "进程", "端口", "服务", "容器"], trackingMode: .selectOne, target: nil, action: nil)
    /// The dashboard body is replaced as a whole when an inventory tab is selected.
    /// Keeping the navigation outside this stack prevents process/port/service/container
    /// content from being inserted into the overview card.
    private let dashboardBodyStack = NSStackView()
    private var overviewSections: [NSView] = []
    private var overviewBaseSections: [NSView] = []
    private var overviewNetworkSection: NSView?
    private var overviewDiskSection: NSView?
    private var overviewIOTileRow: NSStackView?
    private var overviewNetworkTile: NSView?
    private var overviewDiskTile: NSView?
    private var overviewVisibility: (network: Bool, disk: Bool)?
    private var dashboardBodyWidthConstraints: [NSLayoutConstraint] = []
    private var renderedDashboardSegment: Int?
    private var inventoryPanels: [Int: DeviceMetricsInventoryPanel] = [:]
    private var managementLoads = Set<Int>()
    private var managementLoadGenerations: [Int: Int] = [:]
    private var managementRefreshPending = Set<Int>()
    private var managementRefreshCompletions: [Int: [() -> Void]] = [:]
    private var managementLastLoad: [Int: Date] = [:]
    private var managementAuthorizationRequired = Set<Int>()
    private var managementAuthorizationPending = false
    private var managementAuthorizationRefreshGeneration = 0
    private var managementActionPending = false
    private var managementDeferredVisibleSegment: Int?
    // Management lists are intentionally fetched outside the fast resource
    // probe. Warm them one at a time after the first overview sample so the
    // common first click can reuse data without opening four SSH sessions at
    // once. A tab switch or disappearing view cancels the queued work.
    private var managementWarmupAttempted = false
    private var managementWarmupGeneration = 0
    private var managementWarmupWorkItem: DispatchWorkItem?
    // Explicit manual polling remains usable when automatic polling is disabled.
    // Once stopped, only the next appearance/start may resume background warmup.
    private var managementWarmupSuspended = false
    private var selectedNetworkNames = Set<String>()
    private var hasManualNetworkSelection = false
    public var metricsDidUpdate: (() -> Void)?

    public func historySamplesForTesting(metric: DeviceMetricsAlertMetric) -> [DeviceMetricHistorySample] {
        switch metric {
        case .cpuUsage: return cpuHistorySamples
        case .memoryUsage: return memoryHistorySamples
        case .networkIO: return networkIOHistorySamples
        case .diskIO: return diskIOHistorySamples
        case .diskUsage: return []
        }
    }

    public func diskUsageHistorySamplesForTesting(mountPath: String) -> [DeviceMetricHistorySample] {
        diskUsageHistorySamples[mountPath] ?? []
    }

    public func showHistoryDetailForTesting(metric: DeviceMetricsAlertMetric) {
        showHistoryDetail(metric: metric, anchor: view)
    }

    var boundRuntimeID: String {
        runtimeID
    }

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
        dashboardScrollView = scrollView

        let header = NSStackView(views: [makeHeader(), makeInventoryNavigation()])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        header.arrangedSubviews.forEach {
            $0.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }
        dashboardHeaderStack = header

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
        panel.addSubview(header)
        panel.addSubview(scrollView)
        documentView.addSubview(content)
        scrollView.documentView = documentView

        let sections = [makeDashboardBodyStack()]

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
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
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
        hoverDetailPresenter.reposition()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        startPollingIfNeeded()
    }

    func startPollingIfNeeded() {
        managementWarmupSuspended = false
        guard startsPollingAutomatically, refreshTimer == nil else { return }
        refreshMetrics()
        let interval = TimeInterval(settingsStore.snapshot().deviceMetricsRefreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetrics()
            }
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        stopPolling()
    }

    func stopPolling() {
        hoverDetailPresenter.dismiss()
        managementWarmupSuspended = true
        managementAuthorizationRefreshGeneration += 1
        managementDeferredVisibleSegment = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelManagementWarmup()
    }

    func applyMetricsSettings() {
        let interval = TimeInterval(settingsStore.snapshot().deviceMetricsRefreshIntervalSeconds)
        if let timer = refreshTimer, timer.timeInterval != interval {
            timer.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMetrics()
                }
            }
        }
        // Applying a preference to a hidden dashboard must not start polling or
        // load its view. Reuse every chart, history buffer, and inventory panel.
        guard isViewLoaded else { return }
        updateOverviewVisibility()
        if let error = lastRefreshError {
            // A presentation change is not a successful probe. Preserve the
            // failure state and apply the current keep-last-data preference.
            renderError(error)
        } else if let snapshot = lastSuccessfulSnapshot {
            render(snapshot, recordsHistory: false)
        } else {
            invalidatePreferredFloatingHeight()
            metricsDidUpdate?()
        }
        refreshThemeForEffectiveAppearanceChange(appearance: view.effectiveAppearance)
    }

    deinit {
        refreshTimer?.invalidate()
        cancelManagementWarmup()
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
        if let cachedPreferredFloatingHeight,
           abs(cachedPreferredFloatingHeight.width - width) <= 0.5
        {
            return cachedPreferredFloatingHeight.height
        }
        let contentWidth = max(0, floor(width - 20))
        contentStack.frame.size.width = contentWidth
        contentStack.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        // Scroll-view rounding can add a point back to the constrained frame on macOS 14.
        contentStack.frame.size.width = contentWidth
        dashboardHeaderStack?.frame.size.width = contentWidth
        dashboardHeaderStack?.layoutSubtreeIfNeeded()
        let preferredHeight = ceil(contentHeight + (dashboardHeaderStack?.fittingSize.height ?? 0) + 30)
        cachedPreferredFloatingHeight = (width, preferredHeight)
        return preferredHeight
    }

    private func invalidatePreferredFloatingHeight() {
        cachedPreferredFloatingHeight = nil
    }

    public func setSelectedNetworkInterfacesForTesting(_ names: [String]) {
        hasManualNetworkSelection = true
        selectedNetworkNames = Set(names)
        invalidatePreferredFloatingHeight()
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

    public func textFieldSupportsSelectionForTesting(accessibilityIdentifier: String) -> Bool {
        guard let textField = firstSubview(withIdentifier: accessibilityIdentifier, in: view) as? NSTextField else {
            return false
        }
        return textField.isSelectable
            && textField.isEditable == false
            && (textField as? DeviceMetricStaticLabel)?.usesTextCursorForTesting == true
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
        loadManagementData(for: inventoryTabControl.selectedSegment, force: false)
        guard !isRefreshing else { return }
        isRefreshing = true
        provider.pollDeviceMetrics { [weak self] result in
            let applyResult = { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case let .success(snapshot):
                    self.lastRefreshError = nil
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
        overviewChartGrid = grid
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
        overviewIOTileRow = bottomRow
        let networkTile = makeChartTile(
                title: "网络 I/O",
                metric: .networkIO,
                valueLabel: networkIOValueLabel,
                chart: networkIOLineChart,
                detailLabel: networkIODetailLabel
            )
        let diskTile = makeChartTile(
                title: "磁盘读写",
                metric: .diskIO,
                valueLabel: diskIOValueLabel,
                chart: diskIOLineChart,
                detailLabel: diskIODetailLabel
            )
        overviewNetworkTile = networkTile
        overviewDiskTile = diskTile
        bottomRow.addArrangedSubview(networkTile)
        bottomRow.addArrangedSubview(diskTile)

        grid.addArrangedSubview(topRow)
        grid.addArrangedSubview(bottomRow)
        section.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        topRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        bottomRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
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
        tile.metricRawValue = metric.rawValue
        tile.setAccessibilityIdentifier("Stacio.Metrics.tile.\(title)")
        tile.setAccessibilityHelp("悬停查看详情，单击查看历史资源使用情况")
        tile.setAccessibilityLabel("\(title)，悬停查看详情，单击查看历史资源使用情况")
        tile.onHoverChanged = { [weak self, weak tile] inside in
            guard let self, let tile else { return }
            if inside { self.showHoverDetail(title: title, anchor: tile) }
            else if self.hoveredMetricTile === tile { self.hoverDetailPresenter.scheduleDismissal() }
        }
        let historyClick = NSClickGestureRecognizer(target: self, action: #selector(showHistoryDetail(_:)))
        historyClick.numberOfClicksRequired = 1
        historyClick.delegate = tile
        tile.addGestureRecognizer(historyClick)

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

    private func showHoverDetail(title: String, anchor: NSView) {
        guard hoverDetailsAvailable, inventoryTabControl.selectedSegment == 0,
              thresholdPopover?.isShown != true, cpuCorePopover?.isShown != true,
              operatingSystemInfoPopover?.isShown != true, historyPopover?.isShown != true,
              let snapshot = lastSuccessfulSnapshot, let overviewChartGrid else { return }
        hoveredMetricTile = anchor
        hoverDetailPresenter.show(title: title, snapshot: snapshot, anchor: anchor, avoiding: overviewChartGrid,
                                  usageColor: hoverUsageColors())
    }

    private func hoverUsageColors() -> DeviceMetricsDashboardHoverPresenter.UsageColor {
        // One settings read per rendered detail, independent of CPU core count.
        let settings = settingsStore.snapshot()
        let cpuThreshold = Double(settings.deviceMetricsCPUAlertThresholdPercent) / 100
        let diskThreshold = Double(settings.deviceMetricsDiskAlertThresholdPercent) / 100
        return { value, metric in
            let danger = metric == .diskUsage ? diskThreshold : cpuThreshold
            let warning = min(0.80, max(0.75, danger * 0.85))
            if value >= danger { return .systemRed }
            if value >= warning { return .systemOrange }
            return .systemGreen
        }
    }

    @objc private func showHistoryDetail(_ sender: NSClickGestureRecognizer) {
        guard let tile = sender.view as? DeviceMetricsTileView,
              let metric = DeviceMetricsAlertMetric(rawValue: tile.metricRawValue)
        else { return }
        showHistoryDetail(metric: metric, anchor: tile)
    }

    private func showHistoryDetail(metric: DeviceMetricsAlertMetric, anchor: NSView) {
        let samples = historySamplesForTesting(metric: metric)
        guard samples.isEmpty == false else { return }
        showHistoryDetail(
            title: historyTitle(for: metric),
            samples: samples,
            accentColor: accentColor(for: metric),
            unit: unit(for: metric),
            anchor: anchor
        )
    }

    private func showHistoryDetail(
        title: String,
        samples: [DeviceMetricHistorySample],
        accentColor: NSColor,
        unit: String,
        anchor: NSView
    ) {
        guard samples.isEmpty == false else { return }
        hoverDetailPresenter.dismiss()
        thresholdPopover?.close()
        cpuCorePopover?.close()
        operatingSystemInfoPopover?.close()
        historyPopover?.close()
        let popover = NSPopover()
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: title,
            samples: samples,
            accentColor: accentColor,
            unit: unit,
            deviceName: systemHostnameValueLabel.stringValue == "--" ? nil : systemHostnameValueLabel.stringValue,
            deviceAddress: dashboardTitle
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        historyPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func accentColor(for metric: DeviceMetricsAlertMetric) -> NSColor {
        switch metric {
        case .cpuUsage: return .systemBlue
        case .memoryUsage: return .systemGreen
        case .networkIO: return .systemOrange
        case .diskIO: return .systemPurple
        case .diskUsage: return .systemBlue
        }
    }

    private func unit(for metric: DeviceMetricsAlertMetric) -> String {
        switch metric {
        case .cpuUsage, .diskUsage: return "%"
        case .memoryUsage: return "B"
        case .networkIO, .diskIO: return "B/s"
        }
    }

    private func historyTitle(for metric: DeviceMetricsAlertMetric) -> String {
        metric == .memoryUsage ? "内存已用" : metric.displayName
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
        hoverDetailPresenter.dismiss()
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
            if self.hoverDetailsAvailable, let snapshot = self.lastSuccessfulSnapshot {
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
        guard hoverDetailsAvailable, latestCPUCoreUsages.isEmpty == false else {
            return
        }
        hoverDetailPresenter.dismiss()
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
        guard hoverDetailsAvailable, label.isTextTruncatedForTesting else {
            return
        }
        hoverDetailPresenter.dismiss()
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

    private func makeInventoryNavigation() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("Stacio.Metrics.inventoryNavigation")
        inventoryTabControl.translatesAutoresizingMaskIntoConstraints = false
        inventoryTabControl.segmentStyle = .texturedRounded
        inventoryTabControl.selectedSegment = 0
        inventoryTabControl.target = self
        inventoryTabControl.action = #selector(selectInventoryTab(_:))
        inventoryTabControl.setAccessibilityIdentifier("Stacio.Metrics.inventoryTabs")
        stack.addArrangedSubview(inventoryTabControl)
        inventoryTabControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeDashboardBodyStack() -> NSStackView {
        dashboardBodyStack.orientation = .vertical
        dashboardBodyStack.alignment = .leading
        dashboardBodyStack.spacing = 10
        dashboardBodyStack.translatesAutoresizingMaskIntoConstraints = false
        dashboardBodyStack.setAccessibilityIdentifier("Stacio.Metrics.dashboardBody")
        overviewBaseSections = [makeSystemSection(), makeChartRow()]
        overviewNetworkSection = makeNetworkSection()
        overviewDiskSection = makeDiskSection()
        updateOverviewVisibility()
        renderedDashboardSegment = nil
        renderDashboardBody()
        return dashboardBodyStack
    }

    private func updateOverviewVisibility() {
        let settings = settingsStore.snapshot()
        let network = settings.deviceMetricsShowNetworkSection
        let disk = settings.deviceMetricsShowDiskSection
        guard overviewVisibility?.network != network || overviewVisibility?.disk != disk else { return }
        overviewVisibility = (network, disk)
        hoverDetailPresenter.dismiss()
        hoveredMetricTile = nil
        thresholdPopover?.close()
        cpuCorePopover?.close()
        operatingSystemInfoPopover?.close()
        historyPopover?.close()
        overviewNetworkTile?.isHidden = !network
        overviewDiskTile?.isHidden = !disk
        overviewIOTileRow?.isHidden = !network && !disk
        overviewSections = overviewBaseSections
        if network, let section = overviewNetworkSection { overviewSections.append(section) }
        if disk, let section = overviewDiskSection { overviewSections.append(section) }
        // An inventory tab remains mounted while overview preferences change.
        // Its next visit will install the retained overview in its new order.
        if inventoryTabControl.selectedSegment == 0 {
            renderedDashboardSegment = nil
            renderDashboardBody()
        }
        invalidatePreferredFloatingHeight()
    }

    @objc private func selectInventoryTab(_ sender: NSSegmentedControl) {
        hoverDetailPresenter.dismiss()
        if inventoryTabControl.selectedSegment != 0 {
            cancelManagementWarmup()
        }
        thresholdPopover?.close()
        cpuCorePopover?.close()
        operatingSystemInfoPopover?.close()
        historyPopover?.close()
        renderDashboardBody()
        // A tab switch should reveal the panel's retained rows immediately. The
        // refresh button and completed management actions still use force=true;
        // forcing here reopened an SSH command on every round trip through the
        // overview and made already-loaded tabs feel slow.
        loadManagementData(for: inventoryTabControl.selectedSegment, force: false)
        dashboardScrollView?.contentView.scroll(to: .zero)
        if let dashboardScrollView { dashboardScrollView.reflectScrolledClipView(dashboardScrollView.contentView) }
        metricsDidUpdate?()
    }

    private func scheduleManagementWarmupIfNeeded() {
        guard !managementWarmupSuspended,
              !managementWarmupAttempted,
              inventoryTabControl.selectedSegment == 0,
              isViewLoaded
        else { return }

        managementWarmupAttempted = true
        managementWarmupGeneration += 1
        let generation = managementWarmupGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.managementWarmupSuspended,
                  self.managementWarmupGeneration == generation,
                  self.inventoryTabControl.selectedSegment == 0
            else { return }
            self.managementWarmupWorkItem = nil
            self.runNextManagementWarmup(segmentIndex: 0, generation: generation)
        }
        managementWarmupWorkItem = workItem
        // Let the first overview render and its layout settle before opening
        // an auxiliary SSH request. The work itself remains on the provider's
        // utility queue; only scheduling and completion touch the main queue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func cancelManagementWarmup() {
        managementWarmupGeneration += 1
        managementWarmupWorkItem?.cancel()
        managementWarmupWorkItem = nil
        // A cancelled warm-up may be followed by another overview visit. Do
        // not permanently suppress the next attempt just because the first
        // visit was interrupted by a tab switch or disappearing view.
        managementWarmupAttempted = false
    }

    private func runNextManagementWarmup(segmentIndex: Int, generation: Int) {
        guard !managementWarmupSuspended,
              generation == managementWarmupGeneration,
              inventoryTabControl.selectedSegment == 0,
              segmentIndex < 4
        else { return }

        let segment = segmentIndex + 1
        loadManagementData(for: segment, force: false) { [weak self] in
            guard let self,
                  !self.managementWarmupSuspended,
                  generation == self.managementWarmupGeneration,
                  self.inventoryTabControl.selectedSegment == 0
            else { return }
            // Yield briefly between remote commands. This keeps the utility
            // queue from opening a burst of sessions and gives a user click
            // priority over the next warmup request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.runNextManagementWarmup(segmentIndex: segmentIndex + 1, generation: generation)
            }
        }
    }

    private func renderDashboardBody() {
        let segment = inventoryTabControl.selectedSegment
        // Keep the overview's chart and popover anchors alive during polling and tab switches.
        // Rebuilding these controls after render() would reset threshold colors and constraints.
        if segment == renderedDashboardSegment { return }
        invalidatePreferredFloatingHeight()
        NSLayoutConstraint.deactivate(dashboardBodyWidthConstraints)
        dashboardBodyWidthConstraints.removeAll()
        dashboardBodyStack.arrangedSubviews.forEach {
            dashboardBodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let content: [NSView]
        switch segment {
        case 1...4: content = [inventoryPanel(for: segment)]
        default: content = overviewSections
        }

        for view in content {
            dashboardBodyStack.addArrangedSubview(view)
            dashboardBodyWidthConstraints.append(view.widthAnchor.constraint(equalTo: dashboardBodyStack.widthAnchor))
        }
        NSLayoutConstraint.activate(dashboardBodyWidthConstraints)
        renderedDashboardSegment = segment
        dashboardBodyStack.needsLayout = true
    }

    private func inventoryPanel(for segment: Int) -> DeviceMetricsInventoryPanel {
        if let panel = inventoryPanels[segment] { return panel }
        let panel = DeviceMetricsInventoryPanel(segment: segment)
        panel.setBusy(managementActionPending || managementAuthorizationPending)
        panel.onRefresh = { [weak self] in self?.loadManagementData(for: segment, force: true) }
        panel.onAuthorize = { [weak self] in
            self?.requestInventoryAuthorization(for: segment) { [weak self] in self?.loadManagementData(for: segment, force: true) }
        }
        panel.onAction = { [weak self] in self?.confirmInventoryAction($0, segment: segment) }
        inventoryPanels[segment] = panel
        return panel
    }

    private func processRows(_ values: [ManagedProcessInfo]) -> [DeviceMetricsInventoryPanel.Row] {
        values.map { item in
            let cpuText = item.hasCPUUsage ? String(format: "%.1f%%", item.cpuPercent) : "不可用"
            let cpuSearch = item.hasCPUUsage ? String(item.cpuPercent) : ""
            let memoryText = item.hasMemoryUsage ? String(format: "%.1f%%", item.memoryPercent) : "--"
            let memorySearch = item.hasMemoryUsage ? String(item.memoryPercent) : ""
            let residentText = item.hasMemoryUsage ? DeviceMetricValueFormatter.bytes(Double(item.residentBytes)) : "--"
            var row = DeviceMetricsInventoryPanel.Row(id: String(item.pid), title: item.command,
                subtitle: "\(item.user) · PID \(item.pid)", badge: item.statusLabel,
                tone: item.isRunning ? .success : item.isStopped ? .warning : .normal,
                filter: item.isRunning ? 1 : 0,
                search: "\(item.command) \(item.user) \(item.pid) \(cpuSearch) \(memorySearch)",
                cpu: item.cpuPercent, hasCPUUsage: item.hasCPUUsage, memory: item.memoryPercent, hasMemoryUsage: item.hasMemoryUsage, pid: item.pid, user: item.user,
                tooltip: "\(item.command)\n用户：\(item.user) · PID \(item.pid) · PPID \(item.parentPID)\nCPU：\(cpuText) · 内存：\(memoryText) · RSS：\(residentText)\n状态：\(item.state) · 已运行：\(item.elapsed)")
            let processActionEnabled = item.pid > 1 && item.processIdentity != nil
            let protectedSuffix = item.pid <= 1 ? "（系统进程受保护）" : item.processIdentity == nil ? "（未获取进程身份，请刷新后重试）" : ""
            row.buttons = [
                .init(symbol: item.isStopped ? "play.fill" : "pause.fill", title: (item.isStopped ? "继续进程" : "暂停进程") + protectedSuffix, action: .process(item.isStopped ? .resume : .pause, item.pid, item.processIdentity), isEnabled: processActionEnabled),
                .init(symbol: "xmark.circle", title: "终止进程" + protectedSuffix, action: .process(.terminate, item.pid, item.processIdentity), isEnabled: processActionEnabled),
                .init(symbol: "xmark.octagon.fill", title: "强行终止进程（SIGKILL，立即结束）" + protectedSuffix, action: .process(.forceTerminate, item.pid, item.processIdentity), isEnabled: processActionEnabled),
                .init(symbol: "gauge.with.dots.needle.50percent", title: "调整优先级" + protectedSuffix, action: .process(.renice(0), item.pid, item.processIdentity), isEnabled: processActionEnabled)
            ]
            return row
        }
    }

    private func portRows(_ values: [ManagedPortInfo]) -> [DeviceMetricsInventoryPanel.Row] {
        values.sorted { $0.port == $1.port ? $0.id < $1.id : $0.port < $1.port }.map { item in
            let address = item.address.contains(":") ? "[\(item.address)]" : item.address
            let process = item.processName.isEmpty ? item.pid.map { "PID \($0)" } ?? "未返回进程信息"
                : item.processName + (item.pid.map { " · PID \($0)" } ?? "")
            return .init(id: item.id, title: "\(address):\(item.port)", subtitle: process,
                badge: item.protocolName, tone: .normal, filter: item.protocolName.hasPrefix("TCP") ? 1 : 2,
                search: "\(address) \(item.port) \(process) \(item.pid.map(String.init) ?? "") \(item.protocolName)",
                buttons: item.pid.flatMap { $0 > 1 ? [.init(symbol: "xmark.circle", title: item.processIdentity == nil ? "终止端口进程（未获取进程身份，请刷新后重试）" : "终止端口进程", action: .process(.terminate, $0, item.processIdentity), isEnabled: item.processIdentity != nil)] : nil } ?? [])
        }
    }

    private func serviceRows(_ values: [ManagedServiceInfo]) -> [DeviceMetricsInventoryPanel.Row] {
        values.map { item in
            let active = item.activeState == "active"
            let failed = item.activeState == "failed"
            return .init(id: item.scope + ":" + item.name, title: item.name,
                subtitle: item.description.isEmpty ? item.name : item.description,
                badge: item.activeState, tone: failed ? .warning : active ? .success : .normal,
                filter: active ? 1 : failed ? 2 : 3,
                search: "\(item.name) \(item.description) \(item.activeState) \(item.scope)",
                tooltip: "\(item.name)\n\(item.description)\n\(item.loadState) · \(item.activeState) · \(item.subState) · \(item.scope)",
                buttons: [
                    .init(symbol: active ? "stop" : "play", title: active ? "停止服务" : "启动服务", action: .service(active ? .stop : .start, item)),
                    .init(symbol: "arrow.clockwise", title: "重启服务", action: .service(.restart, item))
                ])
        }
    }

    private func containerRows(_ values: [ManagedContainerInfo]) -> [DeviceMetricsInventoryPanel.Row] {
        values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { item in
            var buttons: [DeviceMetricsInventoryPanel.Button] = [
                .init(symbol: item.isPaused || !item.isRunning ? "play" : "stop", title: item.isPaused ? "继续容器" : item.isRunning ? "停止容器" : "启动容器", action: .container(item.isPaused ? .unpause : item.isRunning ? .stop : .start, item)),
                .init(symbol: "arrow.clockwise", title: "重启容器", action: .container(.restart, item))
            ]
            if item.isRunning { buttons.append(.init(symbol: "pause", title: "暂停容器", action: .container(.pause, item))) }
            if item.isRunning || item.isPaused { buttons.append(.init(symbol: "xmark.octagon.fill", title: "强行终止容器（立即结束）", action: .container(.kill, item))) }
            return .init(id: item.engine + ":" + item.id, title: item.name, subtitle: item.engine.capitalized + " · " + item.image,
                badge: item.isPaused ? "已暂停" : item.isRunning ? "运行中" : "已停止",
                tone: item.isPaused ? .warning : item.isRunning ? .success : .normal,
                filter: item.isPaused ? 3 : item.isRunning ? 1 : 2,
                search: "\(item.id) \(item.name) \(item.image) \(item.status)",
                tooltip: "\(item.name)\n\(item.id)\n\(item.image)\n\(item.status)", buttons: buttons)
        }
    }

    private func confirmInventoryAction(_ requested: DeviceMetricsInventoryPanel.Action, segment: Int) {
        guard !managementActionPending, !managementAuthorizationPending else { return }
        var action = requested
        let alert = NSAlert()
        alert.messageText = "确认管理操作"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        switch requested {
        case let .process(operation, pid, identity):
            guard identity != nil else { return }
            let title: String
            switch operation {
            case .pause: title = "暂停进程"
            case .resume: title = "继续进程"
            case .terminate: title = "终止进程"
            case .forceTerminate: title = "强行终止进程"
            case .renice: title = "调整优先级"
            }
            alert.messageText = title
            alert.informativeText = "设备：\(dashboardTitle)\nPID：\(pid)"
            if case .forceTerminate = operation {
                alert.informativeText += "\n将发送 SIGKILL，进程会立即退出，无法执行保存和清理。"
                alert.buttons.first?.title = "强行终止"
            }
            if case .renice = operation {
                alert.informativeText += "\n输入 nice 值（-20 到 19；数值越小优先级越高）。"
                let field = NSTextField(string: "0")
                field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
                alert.accessoryView = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (-20...19).contains(value) else {
                    inventoryPanel(for: segment).setFailure(DeviceMetricsInventoryError.invalidArgument)
                    return
                }
                action = .process(.renice(value), pid, identity)
                executeInventoryAction(action, segment: segment)
                return
            }
        case let .service(operation, item):
            alert.messageText = ["start": "启动服务", "stop": "停止服务", "restart": "重启服务"][operation.rawValue] ?? "服务操作"
            alert.informativeText = "设备：\(dashboardTitle)\n服务：\(item.name)（\(item.scope)）"
        case let .container(operation, item):
            alert.messageText = ["start": "启动容器", "stop": "停止容器", "restart": "重启容器", "pause": "暂停容器", "unpause": "继续容器", "kill": "强行终止容器"][operation.rawValue] ?? "容器操作"
            alert.informativeText = "设备：\(dashboardTitle)\n容器：\(item.name)\n\(item.id)"
            if operation == .kill {
                alert.informativeText += "\n容器内的主进程会立即结束，无法执行正常停止时的清理。"
                alert.buttons.first?.title = "强行终止"
            }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        executeInventoryAction(action, segment: segment)
    }

    private func executeInventoryAction(_ action: DeviceMetricsInventoryPanel.Action, segment: Int, allowsAuthorizationRetry: Bool = true) {
        guard !managementActionPending, !managementAuthorizationPending,
              let manager = provider as? DeviceMetricsInventoryManaging else { return }
        managementActionPending = true
        // A list that started before this mutation must not restore the old state,
        // including when its response arrives before the mutation completes.
        managementLoadGenerations[segment, default: 0] += 1
        inventoryPanels.values.forEach { $0.setBusy(true) }
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.managementActionPending = false
            self.inventoryPanels.values.forEach { $0.setBusy(false) }
            switch result {
            case .success: self.loadManagementData(for: segment, force: true)
            case let .failure(error):
                self.inventoryPanel(for: segment).setFailure(error)
                if case DeviceMetricsInventoryError.authorizationRequired = error, allowsAuthorizationRetry {
                    self.requestInventoryAuthorization(for: segment) { [weak self] in
                        self?.executeInventoryAction(action, segment: segment, allowsAuthorizationRetry: false)
                    }
                }
            }
            for pendingSegment in self.managementRefreshPending.sorted() {
                self.loadManagementData(for: pendingSegment, force: true)
            }
            // A tab selected during the mutation may have had no list request
            // to join. Resume only the still-visible tab, after forced refreshes
            // so their in-flight requests already satisfy the deferred read.
            if !self.managementActionPending, let segment = self.managementDeferredVisibleSegment {
                self.managementDeferredVisibleSegment = nil
                if !self.managementWarmupSuspended, self.inventoryTabControl.selectedSegment == segment {
                    self.loadManagementData(for: segment, force: false)
                }
            }
        }
        switch action {
        case let .process(operation, pid, identity): manager.performProcessAction(operation, pid: pid, expectedIdentity: identity, completion: completion)
        case let .service(operation, item): manager.performServiceAction(operation, name: item.name, scope: item.scope, completion: completion)
        case let .container(operation, item): manager.performContainerAction(operation, id: item.id, engine: item.engine, completion: completion)
        }
    }

    private func requestInventoryAuthorization(for segment: Int, retry: @escaping () -> Void) {
        guard !managementActionPending, !managementAuthorizationPending,
              provider is DeviceMetricsInventoryAuthorizing else { return }
        let alert = NSAlert()
        alert.messageText = "sudo 提权"
        alert.informativeText = "设备：\(dashboardTitle)\n提权成功后，本设备看板中需要 sudo 权限的功能将共享此次授权。密码仅在当前看板会话内使用。"
        alert.addButton(withTitle: "sudo 提权")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "sudo 密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        field.stringValue = ""
        guard !password.isEmpty, password.utf8.count < 4096, !password.contains("\n"), !password.contains("\r") else { return }
        authorizeManagement(password: password, segment: segment, retry: retry)
    }

    private func authorizeManagement(password: String, segment: Int, retry: @escaping () -> Void) {
        guard !managementActionPending, !managementAuthorizationPending,
              let authorizer = provider as? DeviceMetricsInventoryAuthorizing else { return }
        managementAuthorizationPending = true
        cancelManagementWarmup()
        inventoryPanels.values.forEach { $0.setBusy(true) }
        authorizer.authorizeInventorySudo(password) { [weak self] result in
            guard let self else { return }
            self.managementAuthorizationPending = false
            self.inventoryPanels.values.forEach { $0.setBusy(false) }
            switch result {
            case .success:
                // Every tab uses the provider's same session-scoped credential.
                // Invalidate requests started with the old authorization so
                // their delayed failures cannot restore stale permission UI.
                self.managementAuthorizationRequired.removeAll()
                self.managementLastLoad.removeAll()
                for tab in 1...4 { self.managementLoadGenerations[tab, default: 0] += 1 }
                self.inventoryPanels.values.forEach { $0.clearAuthorizationFailure() }
                self.managementAuthorizationRefreshGeneration += 1
                let generation = self.managementAuthorizationRefreshGeneration
                let visible = self.inventoryTabControl.selectedSegment
                let remaining = self.inventoryPanels.keys.filter { $0 != segment }.sorted {
                    if ($0 == visible) != ($1 == visible) { return $0 == visible }
                    return $0 < $1
                }
                retry()
                self.refreshAuthorizedManagementPanels(remaining, generation: generation)
            case let .failure(error):
                // A rejected credential is never fanned out across tabs.
                self.inventoryPanel(for: segment).setFailure(error)
                for tab in self.managementRefreshPending.sorted() {
                    self.loadManagementData(for: tab, force: true)
                }
            }
            if !self.managementActionPending, let visible = self.managementDeferredVisibleSegment {
                self.managementDeferredVisibleSegment = nil
                if !self.managementWarmupSuspended, self.inventoryTabControl.selectedSegment == visible {
                    self.loadManagementData(for: visible, force: false)
                }
            }
            self.invalidatePreferredFloatingHeight()
            self.metricsDidUpdate?()
        }
    }

    private func refreshAuthorizedManagementPanels(_ segments: [Int], generation: Int) {
        guard !managementWarmupSuspended,
              generation == managementAuthorizationRefreshGeneration,
              let segment = segments.first else { return }
        loadManagementData(for: segment, force: true) { [weak self] in
            self?.refreshAuthorizedManagementPanels(Array(segments.dropFirst()), generation: generation)
        }
    }

    private func loadManagementData(for segment: Int, force: Bool, completion: (() -> Void)? = nil) {
        guard (1...4).contains(segment),
              let manager = provider as? DeviceMetricsInventoryManaging else {
            completion?()
            return
        }
        if force {
            managementLoadGenerations[segment, default: 0] += 1
        }
        if managementActionPending || managementAuthorizationPending || managementLoads.contains(segment) {
            if force {
                // Coalesce refresh clicks and post-action refreshes without launching
                // overlapping SSH requests. Their results supersede the current load.
                managementRefreshPending.insert(segment)
                if let completion { managementRefreshCompletions[segment, default: []].append(completion) }
            } else {
                if (managementActionPending || managementAuthorizationPending), !managementWarmupSuspended,
                   inventoryTabControl.selectedSegment == segment, !managementLoads.contains(segment) {
                    managementDeferredVisibleSegment = segment
                }
                completion?()
            }
            return
        }
        let needsForcedRefresh = force || managementRefreshPending.contains(segment)
        let interval: TimeInterval = segment == 3 ? 20 : 5
        if !needsForcedRefresh, let previous = managementLastLoad[segment], Date().timeIntervalSince(previous) < interval {
            completion?()
            return
        }
        // A denied read stays actionable without repeatedly issuing failing SSH/sudo requests.
        if !needsForcedRefresh && managementAuthorizationRequired.contains(segment) {
            completion?()
            return
        }
        if (segment == 2 || segment == 4) && needsForcedRefresh {
            (provider as? DeviceMetricsInventoryAuthorizing)?.retryInventoryAuthorization()
        }
        managementLoads.insert(segment)
        managementRefreshPending.remove(segment)
        let generation = managementLoadGenerations[segment, default: 0]
        var completions = managementRefreshCompletions.removeValue(forKey: segment) ?? []
        if let completion { completions.append(completion) }
        managementLastLoad[segment] = Date()
        let panel = inventoryPanel(for: segment)
        panel.setLoading(true)
        let complete: (Result<[DeviceMetricsInventoryPanel.Row], Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.managementLoads.remove(segment)
            if self.managementRefreshPending.contains(segment), !self.managementActionPending, !self.managementAuthorizationPending {
                self.loadManagementData(for: segment, force: true) { completions.forEach { $0() } }
                return
            }
            panel.setLoading(false)
            guard generation == self.managementLoadGenerations[segment, default: 0] else {
                completions.forEach { $0() }
                return
            }
            switch result {
            case let .success(rows):
                self.managementAuthorizationRequired.remove(segment)
                panel.update(rows)
            case let .failure(error):
                let inventoryError = error as? DeviceMetricsInventoryError
                if let containers = inventoryError?.partialContainers {
                    panel.update(self.containerRows(containers))
                }
                if let ports = inventoryError?.partialPorts {
                    panel.update(self.portRows(ports))
                }
                // A partial response still has readable listeners or a healthy
                // container engine to poll. The provider suppresses only denied
                // lookups until an explicit retry.
                if inventoryError?.requiresAuthorization == true && inventoryError?.partialContainers == nil && inventoryError?.partialPorts == nil {
                    self.managementAuthorizationRequired.insert(segment)
                } else {
                    self.managementAuthorizationRequired.remove(segment)
                }
                panel.setFailure(error)
            }
            self.invalidatePreferredFloatingHeight()
            self.metricsDidUpdate?()
            completions.forEach { $0() }
        }
        switch segment {
        case 1: manager.listManagedProcesses { [weak self] result in guard let self else { return }; complete(result.map(self.processRows)) }
        case 2: manager.listManagedPorts { [weak self] result in guard let self else { return }; complete(result.map(self.portRows)) }
        case 3: manager.listManagedServices { [weak self] result in guard let self else { return }; complete(result.map(self.serviceRows)) }
        case 4: manager.listManagedContainers { [weak self] result in guard let self else { return }; complete(result.map(self.containerRows)) }
        default: break
        }
    }

    private func usageColor(_ value: Double) -> NSColor {
        if value >= 0.9 { return StacioDesignSystem.theme.dangerColor }
        if value >= 0.75 { return StacioDesignSystem.theme.warningColor }
        return StacioDesignSystem.theme.successColor
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

    private func render(_ snapshot: DeviceMetricsDisplaySnapshot, recordsHistory: Bool = true) {
        invalidatePreferredFloatingHeight()
        let settings = settingsStore.snapshot()
        lastSuccessfulSnapshot = snapshot
        updateCollectionStatus(cpuAvailable: snapshot.cpuUsage != nil)
        latestProcesses = snapshot.processes
        latestPorts = snapshot.ports
        latestServices = snapshot.services
        latestContainers = snapshot.containers
        renderSystem(snapshot.system)
        let cpuFraction = snapshot.cpuUsage ?? 0
        let sampleDate = Date()
        if recordsHistory {
            appendSample(cpuFraction, to: &cpuHistory)
            if snapshot.cpuUsage != nil {
                appendHistorySample(sampleDate, value: cpuFraction, to: &cpuHistorySamples)
            }
        }
        cpuLineChart.samples = cpuHistory
        cpuLineChart.maximumValue = 1
        cpuValueLabel.stringValue = snapshot.cpuUsage.map { percentText($0) } ?? "--"
        renderCPUCoreSummary(snapshot.cpuCoreUsages)
        if recordsHistory {
            appendSample(snapshot.memory.usageFraction, to: &memoryHistory)
            appendHistorySample(sampleDate, value: Double(snapshot.memory.usedBytes), to: &memoryHistorySamples)
        }
        memoryLineChart.samples = memoryHistory
        memoryLineChart.maximumValue = 1
        // Show the actual used capacity on the card.  The usage fraction is
        // still retained for the chart and threshold colouring.
        memoryValueLabel.stringValue = DeviceMetricValueFormatter.bytes(Double(snapshot.memory.usedBytes))
        memoryDetailLabel.stringValue = "\(byteText(snapshot.memory.usedBytes)) / \(byteText(snapshot.memory.totalBytes))"

        if settings.deviceMetricsShowNetworkSection && recordsHistory {
            if let aggregate = aggregateNetworkIO(from: snapshot.networks) {
                appendHistorySample(sampleDate, value: max(aggregate.receiveBytesPerSecond, aggregate.transmitBytesPerSecond), to: &networkIOHistorySamples)
            }
        }
        if settings.deviceMetricsShowNetworkSection {
            renderNetworkIO(snapshot.networks, appendsHistory: recordsHistory)
        }
        if settings.deviceMetricsShowDiskSection {
            if recordsHistory {
                for disk in uniqueDiskMounts(snapshot.disks) {
                    appendHistorySample(sampleDate, value: disk.usageFraction, to: &diskUsageHistorySamples[disk.mountPath, default: []])
                }
            }
            if recordsHistory, let diskIO = snapshot.diskIO {
                appendHistorySample(sampleDate, value: diskIO.peakBytesPerSecond, to: &diskIOHistorySamples)
            }
            renderDiskIO(snapshot.diskIO, appendsHistory: recordsHistory)
        }
        updateThresholdStyles(for: snapshot)

        if settings.deviceMetricsShowNetworkSection {
            renderNetwork(snapshot.networks)
        }
        if settings.deviceMetricsShowDiskSection {
            renderDisks(snapshot.disks)
        }
        renderDashboardBody()
        if recordsHistory {
            alertCoordinator.process(
                snapshot: snapshot,
                runtimeID: runtimeID,
                sessionTitle: dashboardTitle
            )
        }
        view.needsLayout = true
        metricsDidUpdate?()
        if recordsHistory {
            scheduleManagementWarmupIfNeeded()
        }
        if hoverDetailPresenter.isShown {
            hoverDetailPresenter.update(snapshot: snapshot, usageColor: hoverUsageColors())
        }
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
        lastRefreshError = error
        invalidatePreferredFloatingHeight()
        let settings = settingsStore.snapshot()
        if settings.deviceMetricsKeepLastSnapshotOnFailure,
           let lastSuccessfulSnapshot {
            render(lastSuccessfulSnapshot, recordsHistory: false)
            return
        }
        updateCollectionStatus(cpuAvailable: false)
        renderUnavailableSnapshot()
        metricsDidUpdate?()
    }

    private func renderUnavailableSnapshot() {
        // Remove only the displayed live data. Keep the successful snapshot,
        // history buffers and chart instances for historical views and recovery.
        cpuValueLabel.stringValue = "--"
        memoryValueLabel.stringValue = "--"
        memoryDetailLabel.stringValue = "-- / --"
        networkIOValueLabel.stringValue = "↓ 下载 --"
        networkIODetailLabel.stringValue = "↑ 上传 --"
        diskIOValueLabel.stringValue = "↓ 读 --"
        diskIODetailLabel.stringValue = "↑ 写 --"
        for chart in [cpuLineChart, memoryLineChart, networkIOLineChart, diskIOLineChart] {
            chart.samples = []
            chart.isBreachingThreshold = false
        }
        for label in [networkIOValueLabel, diskIOValueLabel] {
            applyOverviewIOLabelStyle(label, normalRole: .primary)
        }
        for label in [networkIODetailLabel, diskIODetailLabel] {
            applyOverviewIOLabelStyle(label, normalRole: .secondary)
        }
        for label in [systemHostnameValueLabel, systemCurrentUserValueLabel,
                      systemArchitectureValueLabel, systemOperatingSystemValueLabel,
                      systemUptimeValueLabel, systemKernelValueLabel] {
            label.stringValue = "--"
        }
        networkPicker.isEnabled = false
        networkStack.arrangedSubviews.forEach { item in
            networkStack.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        networkStack.addArrangedSubview(metricText("采集失败，暂无实时数据"))
        // Historical occupancy stays available even when current capacities
        // must be hidden. These rows contain no cached utilization or pie.
        let mountsWithHistory = diskUsageHistorySamples.filter { !$0.value.isEmpty }.keys.sorted()
        if mountsWithHistory.isEmpty {
            replaceDiskRows(with: [metricText("采集失败，暂无实时数据")])
        } else {
            replaceDiskRows(with: mountsWithHistory.map { makeUnavailableDiskHistoryRow(mountPath: $0) })
        }
        cpuCorePopover?.close()
        cpuCorePopover = nil
        operatingSystemInfoPopover?.close()
        operatingSystemInfoPopover = nil
        hoveredMetricTile = nil
        updateCPUCoreButton(isExpanded: false)
        view.needsLayout = true
    }

    private func updateCollectionStatus(cpuAvailable: Bool) {
        guard let error = lastRefreshError else {
            hoverDetailsAvailable = true
            statusLabel.stringValue = cpuAvailable ? "实时刷新" : "实时刷新；CPU 等待第二次采样"
            return
        }
        let settings = settingsStore.snapshot()
        let retainsSnapshot = settings.deviceMetricsKeepLastSnapshotOnFailure && lastSuccessfulSnapshot != nil
        hoverDetailsAvailable = retainsSnapshot
        if !retainsSnapshot { hoverDetailPresenter.dismiss() }
        let prefix = retainsSnapshot
            ? "采集失败，已保留上次成功数据（每 \(settings.deviceMetricsRefreshIntervalSeconds) 秒刷新）"
            : "采集失败"
        statusLabel.stringValue = [
            "\(prefix)：\(RuntimeDiagnosticFormatter.userMessage(for: error))",
            "主流 Linux 兼容探针依赖 /proc 与 df；覆盖 CentOS/RHEL、Rocky、Alma、Fedora、Ubuntu、Debian、Alpine 等新老版本。"
        ].joined(separator: "\n")
    }

    private func renderNetwork(_ networks: [DeviceNetworkDisplayRate]) {
        guard hoverDetailsAvailable else { return }
        networkPicker.isEnabled = true
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
        invalidatePreferredFloatingHeight()
        renderNetwork(latestNetworks)
        renderNetworkIO(latestNetworks, appendsHistory: false)
        if let lastSuccessfulSnapshot {
            updateThresholdStyles(for: lastSuccessfulSnapshot)
        }
    }

    @objc private func resetNetworkSelectionToAutomatic(_ sender: NSMenuItem) {
        hasManualNetworkSelection = false
        selectedNetworkNames = Set(defaultNetworkSelection(from: latestNetworks))
        invalidatePreferredFloatingHeight()
        renderNetwork(latestNetworks)
        renderNetworkIO(latestNetworks, appendsHistory: false)
        if let lastSuccessfulSnapshot {
            updateThresholdStyles(for: lastSuccessfulSnapshot)
        }
    }

    private func defaultNetworkSelection(from networks: [DeviceNetworkDisplayRate]) -> [String] {
        DeviceMetricsNetworkSelection.automaticSelection(
            from: networks,
            hideVirtual: settingsStore.snapshot().deviceMetricsHideVirtualNetworkInterfaces
        ).map(\.interfaceName)
    }

    private func isVirtualNetworkInterface(_ name: String) -> Bool {
        DeviceMetricsNetworkSelection.isVirtual(name)
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

    private func appendHistorySample(_ date: Date, value: Double, to history: inout [DeviceMetricHistorySample]) {
        history.append(DeviceMetricHistorySample(date: date, value: max(value, 0)))
        let cutoff = date.addingTimeInterval(-7 * 86400)
        if let first = history.firstIndex(where: { $0.date >= cutoff }), first > 0 {
            history.removeFirst(first)
        }
        if history.count > 100_000 { history.removeFirst(history.count - 100_000) }
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
        let count = hoverDetailsAvailable ? latestCPUCoreUsages.count : 0
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
        guard hoverDetailsAvailable else { return }
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

    private func renderDiskIO(_ diskIO: DeviceDiskIODisplayRate?, appendsHistory: Bool = true) {
        guard hoverDetailsAvailable else { return }
        guard let diskIO else {
            diskIOValueLabel.stringValue = "↓ 读 --"
            applyOverviewIOLabelStyle(diskIOValueLabel, normalRole: .primary)
            diskIODetailLabel.stringValue = "↑ 写 --"
            applyOverviewIOLabelStyle(diskIODetailLabel, normalRole: .secondary)
            diskIOLineChart.samples = []
            diskIOLineChart.isBreachingThreshold = false
            return
        }

        if appendsHistory {
            appendSample(diskIO.peakBytesPerSecond, to: &diskIOHistory)
        }
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
        guard hoverDetailsAvailable else { return }
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

    private func uniqueDiskMounts(_ disks: [DeviceDiskDisplayUsage]) -> [DeviceDiskDisplayUsage] {
        // Use the first sample per mount for both live rows and recorded history.
        var seenMountPaths = Set<String>()
        return disks.filter { seenMountPaths.insert($0.mountPath).inserted }
    }

    private func renderDisks(_ disks: [DeviceDiskDisplayUsage]) {
        guard !disks.isEmpty else {
            replaceDiskRows(with: [metricText("暂无分区数据")])
            return
        }
        // Count distinct mount rows before applying the display limit.
        let uniqueDisks = uniqueDiskMounts(disks)
        let visibleDiskLimit = settingsStore.snapshot().deviceMetricsDiskMountLimit
        var rows = uniqueDisks.prefix(visibleDiskLimit).map { makeDiskRow($0) }
        if uniqueDisks.count > visibleDiskLimit {
            let hiddenCount = uniqueDisks.count - visibleDiskLimit
            rows.append(metricText("另有 \(hiddenCount) 个挂载点"))
        }
        replaceDiskRows(with: rows)
    }

    private func replaceDiskRows(with replacements: [NSView]) {
        // A disk row is also the native history popover's positioning view.
        // Keep that outer stack attached while replacing its live/history-only
        // contents, otherwise AppKit closes the popover during every refresh.
        let existing = diskStack.arrangedSubviews.reduce(into: [NSUserInterfaceItemIdentifier: NSStackView]()) { rows, view in
            if let id = view.identifier, let row = view as? NSStackView { rows[id] = row }
        }
        var identifiers = Set<NSUserInterfaceItemIdentifier>()
        var rows: [NSView] = []
        for replacement in replacements {
            guard let id = replacement.identifier, let content = replacement as? NSStackView else {
                rows.append(replacement)
                continue
            }
            guard identifiers.insert(id).inserted else { continue }
            guard let row = existing[id] else {
                rows.append(replacement)
                continue
            }
            row.arrangedSubviews.forEach { child in
                row.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
            row.orientation = content.orientation
            row.alignment = content.alignment
            row.distribution = content.distribution
            row.spacing = content.spacing
            row.edgeInsets = content.edgeInsets
            row.toolTip = content.toolTip
            for child in content.arrangedSubviews {
                content.removeArrangedSubview(child)
                child.removeFromSuperview()
                row.addArrangedSubview(child)
            }
            rows.append(row)
        }
        let retained = Set(rows.map(ObjectIdentifier.init))
        for row in diskStack.arrangedSubviews where !retained.contains(ObjectIdentifier(row)) {
            diskStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            if let currentIndex = diskStack.arrangedSubviews.firstIndex(where: { $0 === row }) {
                if currentIndex != index { diskStack.insertArrangedSubview(row, at: index) }
            } else {
                diskStack.insertArrangedSubview(row, at: index)
                row.widthAnchor.constraint(equalTo: diskStack.widthAnchor).isActive = true
            }
        }
    }

    private func refreshThemeForEffectiveAppearanceChange(appearance: NSAppearance? = nil) {
        guard isViewLoaded else { return }
        let effectiveAppearance = appearance ?? view.effectiveAppearance
        // Overview controls retain chart/history state while a management tab is
        // visible, so refresh their resolved colors even when they are detached.
        let roots = [view] + overviewSections.filter { !$0.isDescendant(of: view) }
        for root in roots {
            refreshMetricsSurfaceColors(in: root, appearance: effectiveAppearance)
            StacioDesignSystem.refreshDynamicLayerColors(in: root)
            refreshTextColors(in: root, appearance: effectiveAppearance)
            invalidateDiskPieViewsForAppearanceChange(in: root)
            root.needsDisplay = true
        }
        [
            cpuLineChart,
            memoryLineChart,
            networkIOLineChart,
            diskIOLineChart
        ].forEach { $0.invalidateForEffectiveAppearanceChange() }
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
        // Inventory controls own their semantic colors and use dynamic NSColor
        // values. Applying overview roles would turn status badges and primary
        // text into secondary text whenever the system appearance changes.
        guard !(root is DeviceMetricsInventoryPanel) else { return }
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
        row.identifier = NSUserInterfaceItemIdentifier("Stacio.Metrics.diskRow.\(disk.mountPath)")
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showDiskHistory(_:))))

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

    private func makeUnavailableDiskHistoryRow(mountPath: String) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.identifier = NSUserInterfaceItemIdentifier("Stacio.Metrics.diskRow.\(mountPath)")
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showDiskHistory(_:))))
        row.toolTip = "查看 \(mountPath) 的磁盘占用历史"

        let titleLabel = metricText(mountPath)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        applyTextColorRole(.accent, to: titleLabel)
        titleLabel.setAccessibilityIdentifier("Stacio.Metrics.diskTitle.\(mountPath)")
        let detailLabel = metricText("实时数据不可用 · 点击查看历史")
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.setAccessibilityIdentifier("Stacio.Metrics.diskHistoryUnavailable.\(mountPath)")
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(detailLabel)
        return row
    }

    @objc private func showDiskHistory(_ sender: NSClickGestureRecognizer) {
        guard let row = sender.view,
              let identifier = row.identifier?.rawValue,
              identifier.hasPrefix("Stacio.Metrics.diskRow."),
              let path = identifier.split(separator: ".", maxSplits: 3).last,
              let samples = diskUsageHistorySamples[String(path)], samples.isEmpty == false
        else { return }
        showHistoryDetail(title: "磁盘 \(path)", samples: samples, accentColor: .systemGreen, unit: "%", anchor: row)
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
        DeviceMetricValueFormatter.bytesPerSecond(bytesPerSecond)
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

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false, alphaValue > 0.01, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
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
    var usesTextCursorForTesting: Bool {
        true
    }

    init(text: String, wraps: Bool = false) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
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

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
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

private final class DeviceMetricsTileView: DeviceMetricsArrowCursorView, NSGestureRecognizerDelegate {
    var metricRawValue = 0
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // AppKit hitTest expects coordinates in the receiver's superview.
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var target = hitTest(point)
        while let current = target, current !== self {
            // Labels remain part of the tile's click target. Interactive child
            // controls retain their own actions instead of opening history.
            if let field = current as? NSTextField, !field.isEditable {
                target = current.superview
                continue
            }
            if current is NSControl { return false }
            target = current.superview
        }
        return true
    }

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
