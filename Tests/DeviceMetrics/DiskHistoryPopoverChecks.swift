import AppKit

// Compile actual dashboard renderers and the complete history detail controller.
// Unrelated metric collectors/theme state are leaves; NSStackView, row contents,
// gestures, positioning, animations and NSPopover lifetime are native AppKit.
private struct DeviceDiskDisplayUsage {
    let mountPath: String
    let usedBytes: UInt64
    let totalBytes: UInt64
    var usageFraction: Double { Double(usedBytes) / Double(totalBytes) }
}

private enum DeviceMetricsTextColorRole { case primary, secondary, accent, success }
private struct Settings { var deviceMetricsDiskMountLimit = 4 }
private final class SettingsStore {
    var value = Settings()
    func snapshot() -> Settings { value }
}
private final class ChartState {
    var samples: [Double] = [0.5]
    var isBreachingThreshold = false
}
private final class HoverPresenter { func dismiss() {} }
private enum StacioDesignSystem {
    struct Theme {
        let separatorColor = NSColor.separatorColor
        let accentColor = NSColor.controlAccentColor
        let workspaceBackgroundColor = NSColor.windowBackgroundColor
    }
    static let theme = Theme()
}

// PRODUCTION_DISK_VIEWS

@MainActor private final class DashboardFixture: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 500))
    let diskStack = NSStackView()
    let networkStack = NSStackView()
    let networkPicker = NSButton()
    let settingsStore = SettingsStore()
    var diskUsageHistorySamples: [String: [DeviceMetricHistorySample]] = [:]
    var historyPopover: NSPopover?
    var thresholdPopover: NSPopover?
    var cpuCorePopover: NSPopover?
    var operatingSystemInfoPopover: NSPopover?
    let hoverDetailPresenter = HoverPresenter()
    let dashboardTitle = "disk-history-local-fixture"
    var hoveredMetricTile: NSView?
    let cpuValueLabel = NSTextField(labelWithString: "50%")
    let memoryValueLabel = NSTextField(labelWithString: "50%")
    let memoryDetailLabel = NSTextField(labelWithString: "50 / 100")
    let networkIOValueLabel = NSTextField(labelWithString: "50 B/s")
    let networkIODetailLabel = NSTextField(labelWithString: "50 B/s")
    let diskIOValueLabel = NSTextField(labelWithString: "50 B/s")
    let diskIODetailLabel = NSTextField(labelWithString: "50 B/s")
    let systemHostnameValueLabel = NSTextField(labelWithString: "fixture")
    let systemCurrentUserValueLabel = NSTextField(labelWithString: "fixture")
    let systemArchitectureValueLabel = NSTextField(labelWithString: "fixture")
    let systemOperatingSystemValueLabel = NSTextField(labelWithString: "fixture")
    let systemUptimeValueLabel = NSTextField(labelWithString: "fixture")
    let systemKernelValueLabel = NSTextField(labelWithString: "fixture")
    let cpuLineChart = ChartState(), memoryLineChart = ChartState()
    let networkIOLineChart = ChartState(), diskIOLineChart = ChartState()
    let inventoryTabControl = NSSegmentedControl(labels: ["Overview", "Processes"],
        trackingMode: .selectOne, target: nil, action: nil)
    var dashboardScrollView: NSScrollView?
    var metricsDidUpdate: (() -> Void)?
    func updateCPUCoreButton(isExpanded: Bool) {}
    func applyOverviewIOLabelStyle(_ label: NSTextField, normalRole: DeviceMetricsTextColorRole) {}
    func applyTextColorRole(_ role: DeviceMetricsTextColorRole, to label: NSTextField) {
        label.textColor = role == .accent ? .controlAccentColor : .labelColor
    }
    func diskUsageTextRole(for fraction: Double) -> DeviceMetricsTextColorRole { .success }
    func cancelManagementWarmup() {}
    func loadManagementData(for segment: Int, force: Bool) {}
    func renderDashboardBody() { diskStack.isHidden = inventoryTabControl.selectedSegment != 0 }

    override init() {
        super.init()
        inventoryTabControl.selectedSegment = 0
        diskStack.orientation = .vertical
        diskStack.alignment = .leading
        diskStack.spacing = 0
        diskStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diskStack)
        NSLayoutConstraint.activate([
            diskStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            diskStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            diskStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16)
        ])
    }

    // PRODUCTION_DASHBOARD_METHODS
}

@main private struct DiskHistoryPopoverChecks {
    @MainActor static func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let fixture = DashboardFixture()
        let window = NSWindow(contentRect: fixture.view.bounds,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Stacio disk history lifecycle check"
        window.contentView = fixture.view
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { fixture.historyPopover?.close(); window.close() }
        let target = "/vol1.with.dot data"
        let samples = (0..<3).map {
            DeviceMetricHistorySample(date: Date(timeIntervalSince1970: 1_000 + Double($0) * 60),
                                      value: Double($0 + 1) / 10)
        }
        fixture.diskUsageHistorySamples = [target: samples, "/": samples, "/no-history": []]
        func disk(_ mount: String, _ used: UInt64 = 40) -> DeviceDiskDisplayUsage {
            .init(mountPath: mount, usedBytes: used, totalBytes: 100)
        }
        func row(_ mount: String) -> NSView? {
            fixture.diskStack.arrangedSubviews.first {
                $0.identifier?.rawValue == "Stacio.Metrics.diskRow.\(mount)"
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func text(_ view: NSView) -> String {
            descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        }
        func widthConstraints() -> Int {
            fixture.diskStack.constraints.filter { $0.firstAttribute == .width && $0.secondAttribute == .width }.count
        }
        func open(_ mount: String) -> NSPopover {
            let anchor = row(mount)!
            window.contentView!.layoutSubtreeIfNeeded()
            fixture.showDiskHistory(anchor.gestureRecognizers.first as! NSClickGestureRecognizer)
            pump(0.5)
            let popover = fixture.historyPopover!
            precondition(popover.animates, "Regression must use production animated popover")
            precondition(popover.isShown && popover.contentViewController?.view.window?.isVisible == true)
            return popover
        }
        func remainsOpen(_ popover: NSPopover, _ label: String) {
            window.contentView!.layoutSubtreeIfNeeded()
            // Short waits can incorrectly pass while an animated native close is pending.
            pump(2)
            precondition(fixture.historyPopover === popover && popover.isShown,
                         "Disk history closed during \(label)")
            precondition(popover.contentViewController?.view.window?.isVisible == true,
                         "Native history window disappeared during \(label)")
            print("PASS: native history survives \(label)")
        }

        fixture.renderDisks([disk(target), disk("/")])
        pump()
        var anchor: NSView? = row(target)
        let initialWidthConstraints = widthConstraints()
        let popover = open(target)
        let controller = popover.contentViewController as! DeviceMetricHistoryDetailViewController
        controller.setRangeForTesting(lower: 0.2, upper: 0.8)
        let selectedRange = controller.selectedRangeForTesting

        fixture.renderDisks([disk("/", 60), disk(target, 70)])
        precondition(row(target) === anchor && fixture.diskStack.arrangedSubviews.last === anchor)
        precondition(text(anchor!).contains("70%"), "Retained row did not update live values")
        remainsOpen(popover, "successful refresh and reorder")
        precondition(controller.selectedRangeForTesting.lower == selectedRange.lower
                     && controller.selectedRangeForTesting.upper == selectedRange.upper)

        fixture.renderUnavailableSnapshot()
        precondition(row(target) === anchor && text(anchor!).contains("实时数据不可用"))
        precondition(!text(anchor!).contains("70%") && !text(anchor!).contains("100 B"))
        precondition(!descendants(anchor!).contains { $0 is DeviceDiskPieView })
        precondition(row("/no-history") == nil)
        remainsOpen(popover, "failure without cached realtime values")
        fixture.renderUnavailableSnapshot()
        fixture.renderUnavailableSnapshot()
        precondition(row(target) === anchor && fixture.diskStack.arrangedSubviews.count == 2)
        remainsOpen(popover, "repeated failure/settings rerender")

        fixture.renderDisks([disk(target, 80), disk("/", 65)])
        precondition(row(target) === anchor && text(anchor!).contains("80%"))
        precondition(descendants(anchor!).contains { $0 is DeviceDiskPieView })
        remainsOpen(popover, "successful recovery")
        for _ in 0..<12 { fixture.renderDisks([disk(target, 81), disk("/", 65)]) }
        precondition(anchor!.gestureRecognizers.count == 1, "Refresh duplicated history actions")
        precondition(widthConstraints() == initialWidthConstraints, "Refresh accumulated width constraints")
        precondition(fixture.diskUsageHistorySamples[target] == samples, "Row rendering changed retained history")
        precondition(controller.selectedRangeForTesting.lower == selectedRange.lower
                     && controller.selectedRangeForTesting.upper == selectedRange.upper,
                     "Refresh reset historical range selection")

        fixture.settingsStore.value.deviceMetricsDiskMountLimit = 1
        fixture.renderDisks([disk(target), disk("/")])
        precondition(row(target) === anchor && text(fixture.diskStack).contains("另有 1 个挂载点"))
        remainsOpen(popover, "visible mount limit retaining the selected mount")
        anchor = nil
        fixture.renderDisks([disk("/"), disk(target)])
        pump(2)
        precondition(row(target) == nil)
        precondition(!popover.isShown, "History stayed orphaned after its mount became hidden")
        print("PASS: hiding the selected mount closes its native history")

        fixture.settingsStore.value.deviceMetricsDiskMountLimit = 4
        fixture.renderDisks([disk(target), disk(target), disk("/")])
        precondition(fixture.diskStack.arrangedSubviews.count == 2, "Duplicate mount produced duplicate history rows")
        let tabPopover = open(target)
        fixture.inventoryTabControl.selectedSegment = 1
        fixture.selectInventoryTab(fixture.inventoryTabControl)
        pump(2)
        precondition(!tabPopover.isShown, "Changing dashboard tabs did not dismiss history")
        fixture.inventoryTabControl.selectedSegment = 0
        fixture.selectInventoryTab(fixture.inventoryTabControl)
        precondition(row(target) != nil, "Tab change discarded retained disk rows")

        let disappearedPopover = open(target)
        fixture.renderDisks([disk("/")])
        pump(2)
        precondition(!disappearedPopover.isShown, "Removed mount left orphaned history")
        fixture.renderDisks([])
        precondition(fixture.diskStack.arrangedSubviews.count == 1 && text(fixture.diskStack) == "暂无分区数据")
        fixture.diskUsageHistorySamples = [:]
        fixture.renderUnavailableSnapshot()
        precondition(fixture.diskStack.arrangedSubviews.count == 1
                     && text(fixture.diskStack) == "采集失败，暂无实时数据")
        print("Disk history popover checks passed: native animated lifecycle, reorder, failure/recovery, limits, removal and tab changes")
    }
}
