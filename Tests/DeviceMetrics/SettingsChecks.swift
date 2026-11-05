import AppKit

// Compile the production settings, overview layout, timer, and workspace
// installation methods. Only unrelated metric rendering/provider I/O is stubbed.
private struct Settings {
    var deviceMetricsRefreshIntervalSeconds = 60
    var deviceMetricsShowNetworkSection = true
    var deviceMetricsShowDiskSection = true
    var deviceMetricsKeepLastSnapshotOnFailure = true
    var deviceMetricsDiskMountLimit = 10
}
private final class SettingsStore {
    var value = Settings()
    func snapshot() -> Settings { value }
}
private typealias DeviceMetricsDisplaySnapshot = Int
private struct Memory {
    let usedBytes: Int
    var totalBytes: Int { 100 }
    var usageFraction: Double { Double(usedBytes) / 100 }
}
private struct Disk {
    var mountPath = "/"
    let usageFraction: Double
    var usedBytes: Int { Int((usageFraction * 100).rounded()) }
    var totalBytes: Int { 100 }
}
private typealias DeviceDiskDisplayUsage = Disk
private struct DiskIO { let peakBytesPerSecond: Double }
@MainActor private enum SnapshotFixtures {
    static var disksBySample: [Int: [Disk]] = [:]
}
private extension Int {
    var cpuUsage: Double? { Double(self) / 100 }
    var system: Int { self }
    var processes: [Int] { [self] }
    var ports: [Int] { [self] }
    var services: [Int] { [self] }
    var containers: [Int] { [self] }
    var cpuCoreUsages: [Int] { [self, self] }
    var memory: Memory { Memory(usedBytes: self) }
    var networks: [Int] { [self] }
    @MainActor var disks: [Disk] {
        SnapshotFixtures.disksBySample[self] ?? [Disk(usageFraction: Double(self) / 100)]
    }
    var diskIO: DiskIO? { DiskIO(peakBytesPerSecond: Double(self)) }
}
private enum DeviceMetricValueFormatter { static func bytes(_ value: Double) -> String { "\(Int(value)) B" } }
private enum DeviceMetricsTextColorRole { case primary, secondary, accent }
private final class Alerts {
    var count = 0
    func process(snapshot: Int, runtimeID: String, sessionTitle: String) { count += 1 }
    func isBreachingThreshold(value: Double, for metric: DeviceMetricsAlertMetric, settingsStore: SettingsStore) -> Bool { true }
}
private enum RuntimeDiagnosticFormatter {
    static func userMessage(for error: Error) -> String { "connection lost" }
}
private enum ProbeFailure: Error { case disconnected }
private final class DeferredMetricsProvider {
    var polls = 0
    var replies: [(Result<DeviceMetricsDisplaySnapshot, Error>) -> Void] = []
    func pollDeviceMetrics(_ completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        polls += 1
        replies.append(completion)
    }
    func complete(_ result: Result<DeviceMetricsDisplaySnapshot, Error>) {
        replies.removeFirst()(result)
    }
}
private enum DeviceMetricsAlertMetric { case cpuUsage, memoryUsage, networkIO, diskIO }
private enum StacioDesignSystem {
    struct Theme {
        let accentColor = NSColor.systemBlue
        let successColor = NSColor.systemGreen
        let warningColor = NSColor.systemOrange
    }
    static let theme = Theme()
}
private final class Chart: NSView {
    var accentColor = NSColor.labelColor
    var samples: [Double] = []
    var maximumValue: Double = 1
    var isBreachingThreshold = false
}
private final class DeviceDiskPieView: NSView { var progress: Double = 0 }
private final class Hover {
    var closes = 0
    var isShown = false
    func dismiss() { closes += 1; isShown = false }
    func update(snapshot: Int, usageColor: Int) { }
}
private final class Popover { var closes = 0; var isShown = false; func close() { closes += 1; isShown = false } }
@MainActor private protocol DeviceMetricsPollingControlling {
    func startPollingIfNeeded()
    func stopPolling()
    func applyMetricsSettings()
}

@MainActor private final class DeviceMetricsDashboardViewController: NSViewController, DeviceMetricsPollingControlling {
    let boundRuntimeID: String
    let settingsStore = SettingsStore()
    var refreshTimer: Timer?
    var startsPollingAutomatically = true
    let provider = DeferredMetricsProvider()
    var refreshCount: Int { provider.polls }
    var isRefreshing = false
    var lastRefreshError: Error?
    var hoverDetailsAvailable = false
    let statusLabel = NSTextField()
    let alertCoordinator = Alerts()
    var alertCount: Int { alertCoordinator.count }
    var history: [Int] { cpuHistory.map { Int(($0 * 100).rounded()) } }
    var cpuHistory: [Double] = [0.42], memoryHistory: [Double] = [0.42]
    var networkIOHistory: [Double] = [42], diskIOHistory: [Double] = [42]
    var cpuHistorySamples: [Double] = [], memoryHistorySamples: [Double] = []
    var networkIOHistorySamples: [Double] = [], diskIOHistorySamples: [Double] = []
    var diskUsageHistorySamples: [String: [Double]] = [:]
    var latestProcesses: [Int] = [], latestPorts: [Int] = [], latestServices: [Int] = [], latestContainers: [Int] = []
    var latestCPUCoreUsages = [Int]()
    var latestCPUModel = "fixture CPU"
    var runtimeID: String { boundRuntimeID }
    let dashboardTitle = "fixture dashboard"
    var lastSuccessfulSnapshot: Int? = 42
    var metricsDidUpdate: (() -> Void)?
    var heightInvalidations = 0
    var themeRefreshes = 0
    var managementWarmupSuspended = false
    var managementAuthorizationRefreshGeneration = 0
    var managementDeferredVisibleSegment: Int?
    let hoverDetailPresenter = Hover()
    var hoveredMetricTile: NSView?
    var thresholdPopover: Popover? = Popover()
    var cpuCorePopover: Popover? = Popover()
    var operatingSystemInfoPopover: Popover? = Popover()
    var historyPopover: Popover? = Popover()
    var overviewChartGrid: NSView?
    let inventoryTabControl = NSSegmentedControl(labels: ["overview", "process"], trackingMode: .selectOne, target: nil, action: nil)
    let dashboardBodyStack = NSStackView()
    var overviewSections: [NSView] = []
    var overviewBaseSections: [NSView] = []
    var overviewNetworkSection: NSView?
    var overviewDiskSection: NSView?
    var overviewIOTileRow: NSStackView?
    var overviewNetworkTile: NSView?
    var overviewDiskTile: NSView?
    var overviewVisibility: (network: Bool, disk: Bool)?
    var dashboardBodyWidthConstraints: [NSLayoutConstraint] = []
    var renderedDashboardSegment: Int?
    let inventory = NSView()
    let cpuLineChart = Chart(), memoryLineChart = Chart(), networkIOLineChart = Chart(), diskIOLineChart = Chart()
    let cpuValueLabel = NSTextField(), memoryValueLabel = NSTextField(), memoryDetailLabel = NSTextField()
    let networkIOValueLabel = NSTextField(), networkIODetailLabel = NSTextField()
    let diskIOValueLabel = NSTextField(), diskIODetailLabel = NSTextField()
    let cpuCoreButton = NSButton()
    let networkPicker = NSPopUpButton()
    let networkStack = NSStackView(), diskStack = NSStackView()
    let systemHostnameValueLabel = NSTextField(), systemCurrentUserValueLabel = NSTextField()
    let systemArchitectureValueLabel = NSTextField(), systemOperatingSystemValueLabel = NSTextField()
    let systemUptimeValueLabel = NSTextField(), systemKernelValueLabel = NSTextField()
    var styledLabels = Set<ObjectIdentifier>()
    var shownDiskHistory: (title: String, samples: [Double], unit: String, anchor: NSView)?
    init(_ runtime: String) { boundRuntimeID = runtime; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 760))
        inventoryTabControl.selectedSegment = 0
        let body = makeDashboardBodyStack()
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: view.topAnchor)
        ])
    }
    func loadManagementData(for segment: Int, force: Bool) { }
    func cancelManagementWarmup() { }
    func appendSample(_ sample: Double, to history: inout [Double]) { history.append(sample) }
    func appendHistorySample(_ date: Date, value: Double, to history: inout [Double]) { history.append(value) }
    func percentText(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    func byteText(_ value: Int) -> String { "\(value) B" }
    func renderSystem(_ system: Int) { systemUptimeValueLabel.stringValue = "uptime \(system)" }
    func renderCPUCoreSummary(_ cores: [Int]) { latestCPUCoreUsages = cores; updateCPUCoreButton(isExpanded: false) }
    func aggregateNetworkIO(from networks: [Int]) -> (receiveBytesPerSecond: Double, transmitBytesPerSecond: Double)? {
        networks.first.map { (Double($0), Double($0)) }
    }
    func renderNetworkIO(_ networks: [Int], appendsHistory: Bool) {
        let rate = Double(networks[0])
        if appendsHistory { networkIOHistory.append(rate) }
        networkIOLineChart.samples = networkIOHistory
        networkIOValueLabel.stringValue = "download \(rate)"
        networkIODetailLabel.stringValue = "upload \(rate)"
    }
    func renderDiskIO(_ diskIO: DiskIO?, appendsHistory: Bool) {
        let rate = diskIO!.peakBytesPerSecond
        if appendsHistory { diskIOHistory.append(rate) }
        diskIOLineChart.samples = diskIOHistory
        diskIOValueLabel.stringValue = "read \(rate)"
        diskIODetailLabel.stringValue = "write \(rate)"
    }
    func renderNetwork(_ networks: [Int]) {
        networkPicker.isEnabled = true
        replaceRows(networkStack, text: "network \(networks[0])")
    }
    func diskUsageTextRole(for fraction: Double) -> DeviceMetricsTextColorRole { .secondary }
    func replaceRows(_ stack: NSStackView, text: String) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        stack.addArrangedSubview(metricText(text))
    }
    func metricText(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    func applyTextColorRole(_ role: DeviceMetricsTextColorRole, to label: NSTextField) { }
    func showHistoryDetail(title: String, samples: [Double], accentColor: NSColor, unit: String, anchor: NSView) {
        shownDiskHistory = (title, samples, unit, anchor)
    }
    func applyOverviewIOLabelStyle(_ label: NSTextField, normalRole: DeviceMetricsTextColorRole) { styledLabels.insert(ObjectIdentifier(label)) }
    func scheduleManagementWarmupIfNeeded() { }
    func hoverUsageColors() -> Int { 0 }
    func invalidatePreferredFloatingHeight() { heightInvalidations += 1 }
    func refreshThemeForEffectiveAppearanceChange(appearance: NSAppearance) { themeRefreshes += 1 }
    func inventoryPanel(for segment: Int) -> NSView { inventory }
    func configureCPUCoreButton() { }
    func makeSection(title: String, identifier: String) -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setAccessibilityIdentifier(identifier)
        return section
    }
    func fixedSection(_ id: String) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setAccessibilityIdentifier(id)
        section.heightAnchor.constraint(equalToConstant: 60).isActive = true
        return section
    }
    func makeSystemSection() -> NSView { fixedSection("system") }
    func makeNetworkSection() -> NSView { fixedSection("network") }
    func makeDiskSection() -> NSView { fixedSection("disk") }
    func makeChartTile(title: String, metric: DeviceMetricsAlertMetric, valueLabel: NSTextField,
                       chart: Chart, accessoryView: NSView? = nil, detailLabel: NSTextField? = nil) -> NSView {
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.heightAnchor.constraint(equalToConstant: 104).isActive = true
        tile.addSubview(chart)
        return tile
    }
    // PRODUCTION_DASHBOARD_METHODS
}

@MainActor private final class DeviceMetricsStatusBarViewController: NSViewController, DeviceMetricsPollingControlling {
    let runtimeIDForTesting: String
    var applies = 0
    var stops = 0
    var history = [7, 8]
    init(_ runtime: String) { runtimeIDForTesting = runtime; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    func startPollingIfNeeded() { }
    func stopPolling() { stops += 1 }
    func applyMetricsSettings() { applies += 1 }
}

@MainActor private final class WorkspaceHarness: NSViewController {
    var deviceDashboard: NSViewController?
    var deviceMetricsAccessoryFactory: (() -> NSViewController?)?
    func layoutTerminalWorkspace() { }
    func refreshDeviceDashboardVisibility() { }
    func addDeviceDashboardIfNeeded(to view: NSView) { }
    // PRODUCTION_WORKSPACE_METHODS
}

@main private enum SettingsChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let dashboard = DeviceMetricsDashboardViewController("one")
        dashboard.settingsStore.value.deviceMetricsShowNetworkSection = false
        dashboard.applyMetricsSettings()
        precondition(!dashboard.isViewLoaded && dashboard.refreshTimer == nil, "Hidden settings must not load the view or start polling")
        _ = dashboard.view
        let network = dashboard.overviewNetworkSection!
        let disk = dashboard.overviewDiskSection!
        let networkTile = dashboard.overviewNetworkTile!
        let diskTile = dashboard.overviewDiskTile!
        let chartIdentity = ObjectIdentifier(dashboard.networkIOLineChart)
        precondition(dashboard.overviewSections.count == 3 && network.superview == nil)
        dashboard.startPollingIfNeeded()
        let initialTimer = dashboard.refreshTimer!
        let popover = dashboard.historyPopover!
        let initialCloses = popover.closes
        dashboard.applyMetricsSettings()
        precondition(dashboard.refreshTimer === initialTimer && dashboard.refreshCount == 1)
        precondition(dashboard.history == [42] && popover.closes == initialCloses, "Unrelated settings cannot append history or close the open history panel")
        dashboard.settingsStore.value.deviceMetricsRefreshIntervalSeconds = 30
        dashboard.applyMetricsSettings()
        precondition(!initialTimer.isValid && dashboard.refreshTimer?.timeInterval == 30 && dashboard.refreshCount == 1)
        let window = NSWindow(contentRect: dashboard.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = dashboard.view
        window.orderFrontRegardless()
        for index in 0..<20 {
            let showNetwork = index % 2 == 0
            let showDisk = index % 4 < 2
            dashboard.settingsStore.value.deviceMetricsShowNetworkSection = showNetwork
            dashboard.settingsStore.value.deviceMetricsShowDiskSection = showDisk
            dashboard.applyMetricsSettings()
            window.contentView?.layoutSubtreeIfNeeded()
            let expected = 2 + (showNetwork ? 1 : 0) + (showDisk ? 1 : 0)
            precondition(dashboard.dashboardBodyStack.arrangedSubviews.count == expected)
            precondition(dashboard.dashboardBodyWidthConstraints.count == expected && dashboard.dashboardBodyWidthConstraints.allSatisfy(\.isActive))
            precondition(networkTile.isHidden == !showNetwork && diskTile.isHidden == !showDisk)
            precondition(dashboard.overviewIOTileRow?.isHidden == (!showNetwork && !showDisk))
            precondition((network.superview != nil) == showNetwork && (disk.superview != nil) == showDisk)
            let gridHeight = dashboard.overviewBaseSections[1].fittingSize.height
            precondition(abs(gridHeight - (showNetwork || showDisk ? 214 : 104)) < 1, "The hidden I/O row must relinquish its height")
            if showNetwork && showDisk {
                precondition(abs(networkTile.frame.width - diskTile.frame.width) < 1)
            } else if showNetwork || showDisk {
                let visibleTile = showNetwork ? networkTile : diskTile
                precondition(abs(visibleTile.frame.width - (dashboard.overviewIOTileRow?.bounds.width ?? 0)) < 1, "The remaining tile must take the whole row")
            }
            precondition(ObjectIdentifier(dashboard.networkIOLineChart) == chartIdentity && dashboard.networkIOLineChart.superview === networkTile)
            precondition(dashboard.history == [42] && dashboard.refreshCount == 1)
        }
        dashboard.inventoryTabControl.selectedSegment = 1
        dashboard.renderDashboardBody()
        dashboard.settingsStore.value.deviceMetricsShowNetworkSection.toggle()
        dashboard.applyMetricsSettings()
        precondition(dashboard.dashboardBodyStack.arrangedSubviews.first === dashboard.inventory && dashboard.dashboardBodyWidthConstraints.count == 1)
        dashboard.inventoryTabControl.selectedSegment = 0
        dashboard.renderDashboardBody()
        precondition(dashboard.dashboardBodyStack.arrangedSubviews.count == dashboard.overviewSections.count)
        dashboard.stopPolling()
        dashboard.settingsStore.value.deviceMetricsRefreshIntervalSeconds = 10
        dashboard.applyMetricsSettings()
        precondition(dashboard.refreshTimer == nil && dashboard.refreshCount == 1, "Stopped dashboard must stay stopped")
        window.close()

        // Run the production disk row builders and reconciliation with native
        // stack views. Stable outer rows are the anchors retained by AppKit's
        // history popover; only their live/failed presentation may change.
        let diskReuse = DeviceMetricsDashboardViewController("disk-row-reuse")
        _ = diskReuse.view
        func diskRows(_ controller: DeviceMetricsDashboardViewController) -> [String: NSView] {
            controller.diskStack.arrangedSubviews.reduce(into: [:]) { result, row in
                if let id = row.identifier?.rawValue, id.hasPrefix("Stacio.Metrics.diskRow.") {
                    result[String(id.dropFirst("Stacio.Metrics.diskRow.".count))] = row
                }
            }
        }
        func allSubviews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allSubviews) }
        diskReuse.renderDisks([.init(usageFraction: 0.2),
                              .init(mountPath: "/vol1.with.dot data", usageFraction: 0.3),
                              .init(mountPath: "/removed", usageFraction: 0.4)])
        let originalDiskRows = diskRows(diskReuse)
        let originalGestures = originalDiskRows.mapValues { $0.gestureRecognizers.first! }
        for step in 0..<20 {
            let paths = step.isMultiple(of: 2) ? ["/vol1.with.dot data", "/", "/removed"]
                : ["/", "/removed", "/vol1.with.dot data"]
            diskReuse.renderDisks(paths.map { Disk(mountPath: $0, usageFraction: 0.5 + Double(step) / 100) })
            precondition(diskReuse.diskStack.arrangedSubviews.map { String($0.identifier!.rawValue.dropFirst("Stacio.Metrics.diskRow.".count)) } == paths,
                         "Disk reconciliation did not preserve the requested ordering")
            for (path, row) in diskRows(diskReuse) {
                precondition(row === originalDiskRows[path] && row.superview === diskReuse.diskStack,
                             "Repeated disk polling replaced an existing mount anchor")
                precondition(row.gestureRecognizers.count == 1 && row.gestureRecognizers.first === originalGestures[path],
                             "Disk polling accumulated or replaced the history gesture")
                let widthConstraints = diskReuse.diskStack.constraints.filter {
                    ($0.firstItem as? NSView) === row && $0.firstAttribute == .width
                        && ($0.secondItem as? NSView) === diskReuse.diskStack && $0.secondAttribute == .width
                }
                precondition(widthConstraints.count == 1, "Disk polling duplicated its row-width constraint")
                let pies = allSubviews(row).compactMap { $0 as? DeviceDiskPieView }
                precondition(pies.count == 1 && abs(pies[0].progress - (0.5 + Double(step) / 100)) < 0.0001,
                             "Stable disk anchor retained stale or duplicated contents")
            }
        }
        diskReuse.renderDisks([.init(mountPath: "/vol1.with.dot data", usageFraction: 0.7), .init(usageFraction: 0.6)])
        precondition(originalDiskRows["/removed"]?.superview == nil, "A removed mount remained attached")
        diskReuse.diskUsageHistorySamples = ["/": [0.2, 0.6], "/vol1.with.dot data": [0.3, 0.7]]
        for _ in 0..<3 {
            diskReuse.renderUnavailableSnapshot()
            for (path, row) in diskRows(diskReuse) {
                precondition(row === originalDiskRows[path], "Failure replaced the history popover's mount anchor")
                let stack = row as! NSStackView
                precondition(stack.orientation == .vertical && stack.arrangedSubviews.count == 2
                             && allSubviews(row).allSatisfy { !($0 is DeviceDiskPieView) },
                             "Failed disk presentation retained a utilization graphic or incorrect layout")
                precondition((stack.arrangedSubviews[1] as? NSTextField)?.stringValue == "实时数据不可用 · 点击查看历史")
            }
        }
        diskReuse.renderDisks([.init(usageFraction: 0.8), .init(mountPath: "/vol1.with.dot data", usageFraction: 0.9)])
        for (path, row) in diskRows(diskReuse) {
            precondition(row === originalDiskRows[path] && (row as! NSStackView).orientation == .horizontal,
                         "Recovery replaced the anchor or kept the failed row layout")
            precondition(row.toolTip == nil && allSubviews(row).compactMap { $0 as? DeviceDiskPieView }.count == 1,
                         "Recovery did not restore current disk contents")
        }
        diskReuse.renderDisks([.init(usageFraction: 0.25), .init(usageFraction: 0.75)])
        precondition(diskReuse.diskStack.arrangedSubviews.count == 1 && diskRows(diskReuse)["/"] === originalDiskRows["/"],
                     "Duplicate mount names inserted the same anchor more than once")
        precondition(allSubviews(originalDiskRows["/"]!).compactMap { $0 as? DeviceDiskPieView }.first?.progress == 0.25,
                     "Duplicate mount reconciliation did not retain the first row's current contents")

        // Duplicate collector entries must not consume visible mount slots or
        // count as hidden mounts. Keep each mount's first sample and ordering.
        func assertDiskMountLimit(_ limit: Int, disks: [Disk], paths: [String],
                                  progress: [Double], hidden: Int) {
            diskReuse.settingsStore.value.deviceMetricsDiskMountLimit = limit
            diskReuse.renderDisks(disks)
            let rows = diskReuse.diskStack.arrangedSubviews.filter { $0.identifier != nil }
            let actualPaths = rows.map { String($0.identifier!.rawValue.dropFirst("Stacio.Metrics.diskRow.".count)) }
            precondition(actualPaths == paths,
                         "Duplicate mounts consumed visible slots or changed first-occurrence order at limit \(limit)")
            let actualProgress = rows.map { allSubviews($0).compactMap { $0 as? DeviceDiskPieView }.first!.progress }
            precondition(actualProgress == progress, "A duplicate mount replaced its first sample at limit \(limit)")
            let notices = diskReuse.diskStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
            precondition(notices == (hidden == 0 ? [] : ["另有 \(hidden) 个挂载点"]),
                         "Hidden mount count included duplicate entries at limit \(limit)")
            precondition(diskRows(diskReuse)["/"] === originalDiskRows["/"],
                         "Applying mount limits replaced the retained root history anchor")
        }
        assertDiskMountLimit(2,
            disks: [.init(usageFraction: 0.25), .init(usageFraction: 0.75),
                    .init(mountPath: "/data", usageFraction: 0.4)],
            paths: ["/", "/data"], progress: [0.25, 0.4], hidden: 0)
        assertDiskMountLimit(1,
            disks: [.init(usageFraction: 0.25), .init(usageFraction: 0.75)],
            paths: ["/"], progress: [0.25], hidden: 0)
        assertDiskMountLimit(1,
            disks: [.init(usageFraction: 0.25), .init(usageFraction: 0.75),
                    .init(mountPath: "/data", usageFraction: 0.4),
                    .init(mountPath: "/data", usageFraction: 0.9),
                    .init(mountPath: "/backup", usageFraction: 0.6)],
            paths: ["/"], progress: [0.25], hidden: 2)
        assertDiskMountLimit(2,
            disks: [.init(mountPath: "/data", usageFraction: 0.4), .init(usageFraction: 0.25),
                    .init(mountPath: "/data", usageFraction: 0.9),
                    .init(mountPath: "/backup", usageFraction: 0.6), .init(usageFraction: 0.75)],
            paths: ["/data", "/"], progress: [0.4, 0.25], hidden: 1)
        diskReuse.renderDisks([])
        precondition(originalDiskRows.values.allSatisfy { $0.superview == nil }
                     && diskReuse.diskStack.arrangedSubviews.count == 1
                     && (diskReuse.diskStack.arrangedSubviews[0] as? NSTextField)?.stringValue == "暂无分区数据",
                     "Empty inventory kept obsolete history anchors attached")

        // Drive the actual render/history path, including duplicate collector
        // rows outside the visible mount limit. Do not deduplicate in fixtures.
        let diskSampling = DeviceMetricsDashboardViewController("disk-history-sampling")
        _ = diskSampling.view
        diskSampling.settingsStore.value.deviceMetricsDiskMountLimit = 1
        SnapshotFixtures.disksBySample[71] = [
            .init(usageFraction: 0.25), .init(usageFraction: 0.9),
            .init(mountPath: "/data", usageFraction: 0.4),
            .init(mountPath: "/data", usageFraction: 0.8),
            .init(mountPath: "/backup", usageFraction: 0.6)
        ]
        diskSampling.render(71)
        precondition(diskSampling.diskUsageHistorySamples == ["/": [0.25], "/data": [0.4], "/backup": [0.6]],
                     "One snapshot appended duplicate disk history samples or skipped hidden mounts")
        let firstVisibleRows = diskRows(diskSampling)
        precondition(Set(firstVisibleRows.keys) == ["/"]
                     && allSubviews(firstVisibleRows["/"]!).compactMap { $0 as? DeviceDiskPieView }.first?.progress
                        == diskSampling.diskUsageHistorySamples["/"]!.last,
                     "Visible disk data and the first history sample disagree")

        SnapshotFixtures.disksBySample[72] = [
            .init(mountPath: "/data", usageFraction: 0.5), .init(usageFraction: 0.35),
            .init(mountPath: "/data", usageFraction: 0.85),
            .init(mountPath: "/backup", usageFraction: 0.65), .init(usageFraction: 0.95)
        ]
        diskSampling.render(72)
        let sampledDisks = ["/": [0.25, 0.35], "/data": [0.4, 0.5], "/backup": [0.6, 0.65]]
        precondition(diskSampling.diskUsageHistorySamples == sampledDisks,
                     "A later snapshot did not append exactly one first-occurrence value per mount")
        let secondVisibleRows = diskRows(diskSampling)
        precondition(Set(secondVisibleRows.keys) == ["/data"]
                     && allSubviews(secondVisibleRows["/data"]!).compactMap { $0 as? DeviceDiskPieView }.first?.progress
                        == diskSampling.diskUsageHistorySamples["/data"]!.last,
                     "Reordered snapshot history does not match the visible first mount")

        let resourceHistories = [diskSampling.cpuHistorySamples, diskSampling.memoryHistorySamples,
                                 diskSampling.networkIOHistorySamples, diskSampling.diskIOHistorySamples]
        let sampledAlerts = diskSampling.alertCount
        diskSampling.settingsStore.value.deviceMetricsDiskMountLimit = 2
        diskSampling.render(72, recordsHistory: false)
        precondition(diskSampling.diskUsageHistorySamples == sampledDisks
                     && resourceHistories == [diskSampling.cpuHistorySamples, diskSampling.memoryHistorySamples,
                                              diskSampling.networkIOHistorySamples, diskSampling.diskIOHistorySamples]
                     && diskSampling.alertCount == sampledAlerts,
                     "Presentation-only rerender appended disk/resource history or alerts")
        precondition(Set(diskRows(diskSampling).keys) == ["/", "/data"],
                     "Presentation-only rerender failed to apply the visible mount limit")
        SnapshotFixtures.disksBySample[73] = []
        diskSampling.render(73)
        precondition(diskSampling.diskUsageHistorySamples == sampledDisks
                     && diskRows(diskSampling).isEmpty,
                     "An empty disk snapshot changed previously collected mount histories")
        SnapshotFixtures.disksBySample = [:]

        // Drive the production polling, error, settings and status methods.
        // A settings notification must never masquerade as a successful probe.
        for keep in [false, true] {
            let failing = DeviceMetricsDashboardViewController("failure-\(keep)")
            failing.settingsStore.value.deviceMetricsKeepLastSnapshotOnFailure = keep
            _ = failing.view
            let chart = failing.cpuLineChart
            failing.refreshMetrics()
            failing.provider.complete(.success(55))
            precondition(failing.statusLabel.stringValue == "实时刷新" && failing.hoverDetailsAvailable)
            let initialDiskAnchor = diskRows(failing)["/"]!
            // Previously mounted volumes may still have useful history; an
            // empty history must not manufacture a clickable entry.
            failing.diskUsageHistorySamples["/vol1.with.dot data"] = [0.12, 0.34]
            failing.diskUsageHistorySamples["/no-history"] = []
            let allCharts = [failing.cpuLineChart, failing.memoryLineChart, failing.networkIOLineChart, failing.diskIOLineChart]
            let overview = failing.overviewSections
            let historyPopover = failing.historyPopover!
            let historyPopoverCloses = historyPopover.closes
            let corePopover = Popover(), systemPopover = Popover()
            corePopover.isShown = true; systemPopover.isShown = true
            failing.cpuCorePopover = corePopover
            failing.operatingSystemInfoPopover = systemPopover
            failing.hoverDetailPresenter.isShown = true
            let histories = [failing.cpuHistory, failing.memoryHistory, failing.networkIOHistory, failing.diskIOHistory,
                             failing.cpuHistorySamples, failing.memoryHistorySamples, failing.networkIOHistorySamples, failing.diskIOHistorySamples]
            let diskHistory = failing.diskUsageHistorySamples
            func assertPresentation(retains: Bool) {
                precondition(failing.cpuValueLabel.stringValue == (retains ? "55%" : "--"))
                precondition(failing.memoryValueLabel.stringValue == (retains ? "55 B" : "--"))
                precondition(failing.cpuCoreButton.isEnabled == retains && failing.networkPicker.isEnabled == retains)
                precondition(failing.cpuCoreButton.title == (retains ? "2 CPU" : "-- CPU"))
                precondition(diskRows(failing)["/"] === initialDiskAnchor,
                             "Failure/settings toggles replaced the retained disk history anchor")
                precondition(allCharts.allSatisfy { retains ? !$0.samples.isEmpty : $0.samples.isEmpty && !$0.isBreachingThreshold })
                if !retains {
                    precondition(failing.memoryDetailLabel.stringValue == "-- / --")
                    precondition(failing.networkIOValueLabel.stringValue == "↓ 下载 --" && failing.networkIODetailLabel.stringValue == "↑ 上传 --")
                    precondition(failing.diskIOValueLabel.stringValue == "↓ 读 --" && failing.diskIODetailLabel.stringValue == "↑ 写 --")
                    precondition(failing.systemUptimeValueLabel.stringValue == "--")
                    precondition(failing.networkStack.arrangedSubviews.count == 1 && (failing.networkStack.arrangedSubviews[0] as? NSTextField)?.stringValue == "采集失败，暂无实时数据")
                    let rows = failing.diskStack.arrangedSubviews
                    precondition(rows.count == diskHistory.values.filter { !$0.isEmpty }.count, "Failure lost or duplicated disk history entries")
                    for row in rows {
                        let mount = String(row.identifier!.rawValue.dropFirst("Stacio.Metrics.diskRow.".count))
                        let labels = (row as! NSStackView).arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
                        precondition(labels == [mount, "实时数据不可用 · 点击查看历史"], "Unavailable rows exposed cached capacities or percentages")
                        precondition((row as! NSStackView).arrangedSubviews.allSatisfy { $0 is NSTextField }, "Unavailable row retained an old utilization graphic")
                        let click = row.gestureRecognizers.first as! NSClickGestureRecognizer
                        precondition(click.target === failing && click.action == #selector(DeviceMetricsDashboardViewController.showDiskHistory(_:)))
                        failing.showDiskHistory(click)
                        let shown = failing.shownDiskHistory!
                        precondition(shown.title == "磁盘 \(mount)" && shown.samples == diskHistory[mount]! && shown.unit == "%" && shown.anchor === row,
                                     "History click did not use the retained samples for this mount")
                    }
                    precondition(!failing.hoverDetailPresenter.isShown && failing.cpuCorePopover == nil && failing.operatingSystemInfoPopover == nil)
                    precondition(failing.styledLabels.count == 4, "Every I/O label must reset its active threshold style")
                    // A delayed threshold update or core-button refresh cannot
                    // revive the last snapshot while keep-last-data is off.
                    failing.updateThresholdStyles(for: 55)
                    failing.updateCPUCoreButton(isExpanded: false)
                    precondition(allCharts.allSatisfy { !$0.isBreachingThreshold } && !failing.cpuCoreButton.isEnabled)
                }
                precondition(failing.historyPopover === historyPopover && historyPopover.closes == historyPopoverCloses)
                precondition(zip(failing.overviewSections, overview).allSatisfy { $0 === $1 })
                precondition([failing.cpuHistory, failing.memoryHistory, failing.networkIOHistory, failing.diskIOHistory,
                              failing.cpuHistorySamples, failing.memoryHistorySamples, failing.networkIOHistorySamples, failing.diskIOHistorySamples] == histories)
                precondition(failing.diskUsageHistorySamples == diskHistory)
            }
            let invalidationsBeforeFailure = failing.heightInvalidations
            failing.metricsDidUpdate = { precondition(failing.heightInvalidations > invalidationsBeforeFailure, "Layout cache must be invalidated before notifying the floating panel") }
            failing.refreshMetrics()
            failing.provider.complete(.failure(ProbeFailure.disconnected))
            precondition(failing.statusLabel.stringValue.contains("采集失败") && failing.hoverDetailsAvailable == keep)
            assertPresentation(retains: keep)
            if !keep { precondition(corePopover.closes == 1 && systemPopover.closes == 1) }
            let history = failing.history, alerts = failing.alertCount, polls = failing.refreshCount
            var reportedStatuses: [String] = []
            failing.metricsDidUpdate = { reportedStatuses.append(failing.statusLabel.stringValue) }
            for _ in 0..<3 { failing.applyMetricsSettings() }
            precondition(!reportedStatuses.isEmpty && reportedStatuses.allSatisfy { $0.contains("采集失败") }, "A presentation callback observed a falsely recovered state")
            precondition(failing.lastRefreshError != nil && failing.hoverDetailsAvailable == keep)
            precondition(failing.history == history && failing.alertCount == alerts && failing.refreshCount == polls)
            precondition(failing.cpuLineChart === chart)
            assertPresentation(retains: keep)
            // Turning keep-last-data on/off re-evaluates availability while the
            // failure stays visible until the next actual successful response.
            for retains in [true, false, true, false] {
                failing.settingsStore.value.deviceMetricsKeepLastSnapshotOnFailure = retains
                failing.applyMetricsSettings()
                precondition(failing.statusLabel.stringValue.contains("采集失败") && failing.hoverDetailsAvailable == retains)
                precondition(failing.statusLabel.stringValue.contains("已保留上次成功数据") == retains)
                precondition(failing.history == history && failing.alertCount == alerts && failing.refreshCount == polls)
                assertPresentation(retains: retains)
            }
            failing.refreshMetrics()
            precondition(failing.statusLabel.stringValue.contains("采集失败"), "Starting a retry must not clear failure before its response")
            failing.provider.complete(.success(65))
            precondition(failing.lastRefreshError == nil && failing.statusLabel.stringValue == "实时刷新" && failing.hoverDetailsAvailable)
            precondition(failing.history == history + [65] && failing.alertCount == alerts + 1 && failing.refreshCount == polls + 1)
            precondition(failing.cpuValueLabel.stringValue == "65%" && failing.memoryValueLabel.stringValue == "65 B")
            precondition(failing.networkPicker.isEnabled && failing.cpuCoreButton.isEnabled && allCharts.allSatisfy { !$0.samples.isEmpty })
            precondition(failing.diskStack.arrangedSubviews.count == 1 && diskRows(failing)["/"] === initialDiskAnchor
                         && allSubviews(initialDiskAnchor).compactMap { $0 as? DeviceDiskPieView }.count == 1,
                         "Real recovery left unavailable rows alongside the current disk rows")
            precondition([failing.cpuHistory, failing.memoryHistory, failing.networkIOHistory, failing.diskIOHistory,
                          failing.cpuHistorySamples, failing.memoryHistorySamples, failing.networkIOHistorySamples, failing.diskIOHistorySamples].map(\.count) == histories.map { $0.count + 1 })
            failing.metricsDidUpdate = nil
        }
        let neverSucceeded = DeviceMetricsDashboardViewController("no-sample")
        neverSucceeded.lastSuccessfulSnapshot = nil
        _ = neverSucceeded.view
        neverSucceeded.refreshMetrics()
        neverSucceeded.provider.complete(.failure(ProbeFailure.disconnected))
        neverSucceeded.applyMetricsSettings()
        precondition(neverSucceeded.statusLabel.stringValue.contains("采集失败") && !neverSucceeded.hoverDetailsAvailable)
        precondition(neverSucceeded.diskStack.arrangedSubviews.count == 1 && (neverSucceeded.diskStack.arrangedSubviews[0] as? NSTextField)?.stringValue == "采集失败，暂无实时数据")

        let workspace = WorkspaceHarness()
        workspace.installDeviceDashboard(dashboard)
        workspace.deviceMetricsAccessoryFactory = { DeviceMetricsDashboardViewController("one") }
        workspace.refreshDeviceMetricsDisplayLocation()
        precondition(workspace.deviceDashboard === dashboard && dashboard.history == [42])
        let other = DeviceMetricsDashboardViewController("two")
        workspace.installDeviceDashboard(other)
        precondition(workspace.deviceDashboard === other, "Different runtimes must never be mistaken for nil-equal counterparts")
        let status = DeviceMetricsStatusBarViewController("two")
        workspace.installDeviceDashboard(status)
        precondition(workspace.deviceDashboard === status, "Changing display location must replace the type")
        workspace.deviceMetricsAccessoryFactory = { DeviceMetricsStatusBarViewController("two") }
        workspace.refreshDeviceMetricsDisplayLocation()
        precondition(workspace.deviceDashboard === status && status.applies == 1 && status.stops == 0 && status.history == [7, 8])
        let otherStatus = DeviceMetricsStatusBarViewController("three")
        workspace.installDeviceDashboard(otherStatus)
        precondition(workspace.deviceDashboard === otherStatus && status.stops == 1)
        workspace.installDeviceDashboard(nil)
        precondition(workspace.deviceDashboard == nil && otherStatus.stops == 1)
        print("PASS: same-session settings preserve controller/history, changed runtimes replace, timers update without sampling/resuming, overview sections and charts reuse across 20 layout toggles; failure clears live readouts/charts but retained disk histories remain clickable without cached quantities or graphics, empty histories keep a placeholder, keep-last-data restores cache without clearing failure, and real recovery replaces unavailable rows and appends each history and alert exactly once")
        print("PASS: real disk row reconciliation preserves mount anchors/gestures/width constraints through 20 polling reorders, failure/settings/recovery swaps only contents, duplicate mounts are bounded and removed mounts detach")
        print("PASS: duplicate mounts do not consume mount-limit slots or inflate hidden counts, with first samples/order and root history anchor preserved")
        print("PASS: production render appends one first-occurrence disk history value per mount per snapshot, includes hidden mounts, and skips history during presentation-only or empty disk renders")
    }
}
