import AppKit

// The status bar, hover surface, native popovers, cells, gestures and delayed
// dismissal code all come from production. Only app-wide dependencies and the
// history content's unrelated plotting implementation are substituted.
enum L10n { enum DeviceMetricsAlerts { static let title = "设备指标告警" } }
final class StacioAppearanceRefreshView: NSView {
    private(set) var layoutPasses = 0
    override func layout() { layoutPasses += 1; super.layout() }
}
enum StacioDesignSystem {
    struct Theme {
        let primaryTextColor = NSColor.labelColor
        let secondaryTextColor = NSColor.secondaryLabelColor
        let accentColor = NSColor.controlAccentColor
        let successColor = NSColor.systemGreen
        let dangerColor = NSColor.systemRed
        let separatorColor = NSColor.separatorColor
    }
    static let theme = Theme()
}
final class AppSettingsStore {
    static let shared = AppSettingsStore()
    private(set) var snapshotCount = 0
    struct Settings {
        var deviceMetricsRefreshIntervalSeconds = 3
        var deviceMetricsCPUAlertThresholdPercent = 90
        var deviceMetricsMemoryAlertThresholdPercent = 90
        var deviceMetricsDiskAlertThresholdPercent = 90
        var deviceMetricsHideVirtualNetworkInterfaces = true
        var deviceMetricsAlertEnabled = true
        var deviceMetricsAlertConsecutiveRefreshCount = 2
        static func normalizedDeviceMetricsAlertThresholdPercent(_ value: Int) -> Int { min(100, max(1, value)) }
    }
    var settings = Settings()
    func snapshot() -> Settings {
        snapshotCount += 1
        return settings
    }
    func update(_ change: (inout Settings) -> Void) { change(&settings) }
}
typealias AppSettings = AppSettingsStore.Settings
private final class RecordingMetricsNotifier: DeviceMetricsAlertNotificationDelivering {
    var payloads: [DeviceMetricsAlertNotificationPayload] = []
    func deliver(_ payload: DeviceMetricsAlertNotificationPayload) { payloads.append(payload) }
}
@MainActor
final class DeviceMetricHistoryDetailViewController: NSViewController {
    private(set) var samples: [DeviceMetricHistorySample]
    var selectedRange = 0.2...0.7
    init(resourceTitle: String, samples: [DeviceMetricHistorySample], accentColor: NSColor,
         unit: String, deviceName: String?, deviceAddress: String?) {
        self.samples = samples
        super.init(nibName: nil, bundle: nil)
        view = NSTextField(labelWithString: "\(resourceTitle) (\(unit))")
        preferredContentSize = NSSize(width: 300, height: 100)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    func updateHistorySamples(_ samples: [DeviceMetricHistorySample]) { self.samples = samples }
}
private final class HoverProvider: DeviceMetricsProviding {
    enum ProbeFailure: Error { case unavailable }
    var value = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.42, cpuCoreUsages: [.init(index: 0, usage: 0.42)],
        memory: .init(usedBytes: 40, totalBytes: 100), networks: [], disks: []
    )
    var fails = false
    private(set) var requestCount = 0
    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        requestCount += 1
        completion(fails ? .failure(ProbeFailure.unavailable) : .success(value))
    }
}

@main
struct StatusHoverChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let provider = HoverProvider()
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "hover-smoke", title: "root@example.com", provider: provider,
            startsPollingAutomatically: false
        )
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1_400, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
        window.setFrameOrigin(NSPoint(x: 50, y: 200))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func source(_ title: String) -> NSView {
            guard let field = descendants(controller.view).first(where: { $0.accessibilityIdentifier() == "Stacio.Metrics.statusBar.\(title)" }), let parent = field.superview else {
                preconditionFailure("missing hover source \(title)")
            }
            return parent
        }
        func event(_ type: NSEvent.EventType, for view: NSView) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        func enter(_ view: NSView) { view.mouseEntered(with: event(.mouseEntered, for: view)) }
        func exit(_ view: NSView) { view.mouseExited(with: event(.mouseExited, for: view)) }
        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
        }
        func currentPopover() -> NSPopover {
            guard let popover = controller.hoverDetailPopoverForTesting else { preconditionFailure("missing native hover popover") }
            return popover
        }
        func checkNativeSize(_ popover: NSPopover) {
            // NSPopover can reconcile its window size on the next run-loop turn.
            // Checking only the synchronous setter misses clipping regressions.
            pump(0.1)
            let detail = popover.contentViewController!
            let preferred = detail.preferredContentSize
            let native = detail.view.window!
            let state = "popover=\(popover.contentSize), preferred=\(preferred), root=\(detail.view.frame), window=\(native.frame)"
            precondition(abs(popover.contentSize.width - preferred.width) < 1 && abs(popover.contentSize.height - preferred.height) < 1,
                         "native popover reverted to the previous resource's size: \(state)")
            precondition(abs(detail.view.frame.width - preferred.width) < 1 && abs(detail.view.frame.height - preferred.height) < 1,
                         "native popover content differs from its requested size: \(state)")
            precondition(native.frame.width >= preferred.width && native.frame.height >= preferred.height,
                         "native window clips its content: \(state)")
        }
        func showHistory(_ title: String) {
            let cell = source(title)
            guard let gesture = cell.gestureRecognizers.first as? NSClickGestureRecognizer, let action = gesture.action else {
                preconditionFailure("missing history single click")
            }
            precondition(gesture.numberOfClicksRequired == 1)
            precondition(cell.accessibilityHelp()?.contains("单击查看历史资源使用") == true)
            precondition(NSApp.sendAction(action, to: gesture.target, from: gesture))
        }

        controller.refreshMetricsForTesting()
        controller.view.layoutSubtreeIfNeeded()
        pump(0.1)
        precondition(provider.requestCount == 1)
        let initialSettingsReads = AppSettingsStore.shared.snapshotCount
        enter(source("CPU"))
        precondition(controller.hoverDetailIsShownForTesting, "hover must open immediately")
        precondition(AppSettingsStore.shared.snapshotCount - initialSettingsReads == 1,
                     "a hover render must read the resource thresholds once")
        let popover = currentPopover()
        let detail = popover.contentViewController!
        let firstCPUCell = source("CPU")
        let firstCPUAnchor = popover.positioningRect
        precondition(controller.hoverDetailTextForTesting.contains("当前 CPU 负载: 42%"))
        provider.value = .init(cpuUsage: 0.95, cpuCoreUsages: (0..<4).map { .init(index: $0, usage: 0.95) },
                               memory: .init(usedBytes: 50, totalBytes: 100, freeBytes: 10, buffersBytes: 10,
                                             cachedBytes: 30, swapTotalBytes: 40, swapFreeBytes: 10),
                               networks: [], disks: [.init(mountPath: "/", usedBytes: 40, totalBytes: 100)],
                               processes: (1...10).map { .init(pid: UInt32($0), name: "worker-\($0)", cpuFraction: Double($0) / 20, memoryFraction: Double($0) / 100) },
                               sshLatencyMilliseconds: 4.2)
        controller.refreshMetricsForTesting()
        precondition(currentPopover() === popover && popover.contentViewController === detail && popover.isShown,
                     "refresh replaced or closed the hover popover")
        precondition(controller.hoverDetailTextForTesting.contains("当前 CPU 负载: 95%"))
        precondition(descendants(detail.view).filter {
            $0 is DeviceMetricsDetailBar && $0.accessibilityIdentifier().hasPrefix("Stacio.Metrics.detail.cpu.process.")
        }.count == 10, "refresh must populate the CPU process ranking")
        checkNativeSize(popover)
        precondition(source("CPU") !== firstCPUCell)
        exit(firstCPUCell)
        pump(0.32)
        precondition(popover.isShown, "a removed source's stale mouseExit closed the replacement hover")

        enter(source("内存"))
        precondition(currentPopover() === popover && popover.contentViewController === detail)
        checkNativeSize(popover)
        precondition(detail.preferredContentSize.height > 400, "fixture must exercise the large memory surface")
        let memoryAnchor = source("内存").convert(source("内存").bounds, to: controller.view)
        precondition(popover.positioningRect == memoryAnchor && popover.positioningRect != firstCPUAnchor,
                     "cross-resource hover did not reposition to the new source")
        precondition(controller.hoverDetailTextForTesting.contains("内存详情"))
        enter(source("磁盘"))
        checkNativeSize(popover)
        enter(source("CPU"))
        checkNativeSize(popover)
        precondition(detail.preferredContentSize.width == 440, "CPU process ranking needs the full readable width")
        enter(source("上传"))
        checkNativeSize(popover)
        precondition(detail.preferredContentSize.height < 200, "network fixture must exercise shrinking after the CPU ranking")
        let latency = descendants(detail.view).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "Stacio.Metrics.detail.network.latency"
        }
        precondition(latency?.stringValue.contains("4.2") == true, "native network hover omitted SSH latency")
        enter(source("CPU"))
        checkNativeSize(popover)
        enter(source("内存"))
        checkNativeSize(popover)

        exit(source("内存"))
        precondition(popover.isShown, "source exit must leave a bridge into the popover")
        enter(detail.view)
        pump(0.32)
        precondition(popover.isShown, "entering the popup did not cancel delayed dismissal")
        exit(detail.view)
        precondition(popover.isShown, "popover exit should dismiss after the bridge interval")
        pump(0.32)
        precondition(!popover.isShown, "popover exit did not dismiss")

        enter(source("CPU"))
        exit(source("CPU"))
        enter(source("内存"))
        pump(0.32)
        precondition(popover.isShown && controller.hoverDetailTextForTesting.contains("内存详情"),
                     "old source's delayed exit closed the newly selected resource")
        precondition(provider.requestCount == 2, "hover started additional remote polling")

        exit(source("内存"))
        showHistory("CPU")
        let history = controller.historyPopoverForTesting!
        let historyController = history.contentViewController as! DeviceMetricHistoryDetailViewController
        precondition(history.isShown && !popover.isShown)
        enter(source("CPU"))
        pump(0.32)
        precondition(history.isShown && !popover.isShown, "hover was not suppressed while history was open")
        controller.refreshMetricsForTesting()
        precondition(controller.historyPopoverForTesting === history && history.contentViewController === historyController)
        precondition(historyController.selectedRange == 0.2...0.7 && historyController.samples.count == 3)
        provider.fails = true
        controller.refreshMetricsForTesting()
        precondition(history.isShown && historyController.selectedRange == 0.2...0.7,
                     "transient sample failure destroyed history state")
        history.close()
        enter(source("CPU"))
        precondition(popover.isShown, "hover must resume after the history popup closes")
        showHistory("CPU")
        precondition(history.isShown && !popover.isShown && controller.historyPopoverForTesting === history && history.contentViewController === historyController,
                     "reopening the same history resource lost its retained content")
        controller.viewWillDisappear()
        precondition(!history.isShown && controller.historyPopoverForTesting == nil && !popover.isShown)

        provider.fails = false
        controller.refreshMetricsForTesting()
        enter(source("CPU"))
        precondition(popover.isShown)
        exit(source("CPU"))
        controller.viewWillDisappear()
        pump(0.32)
        precondition(!popover.isShown && controller.historyPopoverForTesting == nil,
                     "view disappearance left an open surface or pending dismissal")
        provider.value = .init(cpuUsage: 0.42,
                               cpuCoreUsages: (0..<96).map { .init(index: $0, usage: Double($0 % 100) / 100) },
                               memory: .init(usedBytes: 40, totalBytes: 100), networks: [], disks: [])
        controller.refreshMetricsForTesting()
        let manyCoreSettingsReads = AppSettingsStore.shared.snapshotCount
        enter(source("CPU"))
        precondition(AppSettingsStore.shared.snapshotCount - manyCoreSettingsReads == 1,
                     "96-core hover must not read preferences separately for each color callback")
        controller.viewWillDisappear()

        // The native popover is anchored to the stable bar, while its metric
        // lives in a horizontally scrolling document. Exercise real clip-view
        // bounds notifications, including partial visibility and re-entry.
        window.setContentSize(NSSize(width: 400, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
        controller.view.layoutSubtreeIfNeeded()
        let metricsScroll = descendants(controller.view).compactMap { $0 as? NSScrollView }.first!
        func scrollMetrics(to x: CGFloat) {
            let clip = metricsScroll.contentView
            let proposed = NSRect(origin: NSPoint(x: x, y: 0), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            metricsScroll.reflectScrolledClipView(clip)
            pump(0.05)
        }
        func visibleCPUAnchor() -> NSRect {
            let cell = source("CPU")
            return cell.convert(cell.visibleRect.intersection(cell.bounds), to: controller.view)
        }
        let cpuDocumentRect = source("CPU").convert(source("CPU").bounds, to: metricsScroll.documentView!)
        let visibleOffset = max(0, cpuDocumentRect.minX - 40)
        scrollMetrics(to: visibleOffset)
        let probesBeforeScrolling = provider.requestCount
        enter(source("CPU"))
        precondition(popover.isShown)
        let anchorBeforeScroll = popover.positioningRect
        scrollMetrics(to: visibleOffset + 20)
        precondition(currentPopover() === popover && popover.isShown
                     && popover.positioningRect == visibleCPUAnchor()
                     && popover.positioningRect.minX < anchorBeforeScroll.minX,
                     "visible hover did not follow its source during horizontal scrolling")
        scrollMetrics(to: cpuDocumentRect.midX)
        precondition(popover.isShown && popover.positioningRect == visibleCPUAnchor()
                     && popover.positioningRect.width < source("CPU").bounds.width,
                     "partially visible hover must use only the visible source as its anchor")
        scrollMetrics(to: 10_000)
        precondition(source("CPU").visibleRect.intersection(source("CPU").bounds).isEmpty)
        precondition(!popover.isShown, "scrolling a hover source out of view left its popup open")
        precondition(provider.requestCount == probesBeforeScrolling, "scrolling started a remote probe")
        controller.applyMetricsSettings()
        controller.refreshMetricsForTesting()
        scrollMetrics(to: visibleOffset)
        controller.refreshMetricsForTesting()
        pump(0.05)
        precondition(!popover.isShown, "a refresh reopened a hover that scrolling had dismissed")

        showHistory("CPU")
        let scrollingHistory = controller.historyPopoverForTesting!
        let scrollingHistoryController = scrollingHistory.contentViewController as! DeviceMetricHistoryDetailViewController
        let historyAnchorBeforeScroll = scrollingHistory.positioningRect
        scrollMetrics(to: visibleOffset + 20)
        precondition(scrollingHistory.isShown && controller.historyPopoverForTesting === scrollingHistory
                     && scrollingHistory.positioningRect == visibleCPUAnchor()
                     && scrollingHistory.positioningRect.minX < historyAnchorBeforeScroll.minX
                     && scrollingHistoryController.selectedRange == 0.2...0.7,
                     "visible history lost its anchor, controller or selected range during scrolling")
        scrollMetrics(to: 10_000)
        precondition(!scrollingHistory.isShown && controller.historyPopoverForTesting == nil,
                     "scrolling a history source out of view left its popup open")
        controller.refreshMetricsForTesting()
        scrollMetrics(to: visibleOffset)
        controller.refreshMetricsForTesting()
        precondition(controller.historyPopoverForTesting == nil && !popover.isShown,
                     "refresh or scrolling back reopened a dismissed history popup")
        showHistory("CPU")
        precondition(controller.historyPopoverForTesting?.isShown == true,
                     "single click could not reopen history after scrolling back")
        controller.viewWillDisappear()
        window.setContentSize(NSSize(width: 1_400, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
        scrollMetrics(to: 0)

        // A viewport resize does not necessarily post a clip bounds change
        // after its final layout. Use the actual window/layout path, not a
        // fabricated notification or a direct controller lifecycle callback.
        func resizeWindow(to width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
            controller.view.layoutSubtreeIfNeeded()
            pump(0.1)
        }
        let probesBeforeResizing = provider.requestCount
        enter(source("CPU"))
        precondition(popover.isShown)
        for width: CGFloat in [400, 430, 400] {
            resizeWindow(to: width)
            precondition(popover.isShown && currentPopover() === popover
                         && popover.positioningRect == visibleCPUAnchor()
                         && popover.positioningRect.width < source("CPU").bounds.width,
                         "resizing a partially visible hover source retained its old full-width anchor")
        }
        let root = controller.view as! StacioAppearanceRefreshView
        let settledLayoutPasses = root.layoutPasses
        pump(0.15)
        precondition(root.layoutPasses == settledLayoutPasses,
                     "updating the popup anchor caused a repeating native layout")
        resizeWindow(to: 250)
        precondition(source("CPU").visibleRect.intersection(source("CPU").bounds).isEmpty)
        precondition(!popover.isShown, "resizing the hover source out of view left its popup open")
        resizeWindow(to: 1_400)
        precondition(provider.requestCount == probesBeforeResizing, "resizing started a remote probe")
        controller.applyMetricsSettings()
        controller.refreshMetricsForTesting()
        pump(0.05)
        precondition(!popover.isShown, "widening and refreshing reopened a resize-dismissed hover")

        showHistory("CPU")
        let resizingHistory = controller.historyPopoverForTesting!
        let resizingHistoryController = resizingHistory.contentViewController as! DeviceMetricHistoryDetailViewController
        resizeWindow(to: 400)
        precondition(resizingHistory.isShown && controller.historyPopoverForTesting === resizingHistory
                     && resizingHistory.positioningRect == visibleCPUAnchor()
                     && resizingHistoryController.selectedRange == 0.2...0.7,
                     "resize lost the visible history anchor, controller or range")
        resizeWindow(to: 250)
        precondition(!resizingHistory.isShown && controller.historyPopoverForTesting == nil,
                     "resizing the history source out of view left its popup open")
        resizeWindow(to: 1_400)
        controller.refreshMetricsForTesting()
        precondition(controller.historyPopoverForTesting == nil && !popover.isShown,
                     "widening and refreshing reopened resize-dismissed history")

        // Retain the observed object past controller disposal, then emit more
        // bounds events. The observer must neither retain nor revive its owner.
        weak var releasedController: DeviceMetricsStatusBarViewController?
        var retainedClip: NSClipView?
        autoreleasepool {
            let disposable = DeviceMetricsStatusBarViewController(runtimeID: "observer-disposal", title: "fixture",
                provider: HoverProvider(), startsPollingAutomatically: false)
            disposable.loadViewIfNeeded()
            releasedController = disposable
            retainedClip = descendants(disposable.view).compactMap { $0 as? NSScrollView }.first!.contentView
        }
        pump(0.05)
        precondition(releasedController == nil, "bounds observer retained its controller")
        for _ in 0..<20 { NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: retainedClip) }
        retainedClip = nil

        // Settings redraws must retain history and alert state. Use the real
        // coordinator with a recording delivery adapter, never system notices.
        let settings = AppSettingsStore()
        let alerts = RecordingMetricsNotifier()
        let high = HoverProvider()
        high.value = .init(cpuUsage: 0.95, memory: .init(usedBytes: 95, totalBytes: 100),
            networks: ["eth0", "docker0", "veth123"].map {
                .init(interfaceName: $0, receiveBytesPerSecond: 102400, transmitBytesPerSecond: 102400)
            }, disks: [.init(mountPath: "/", usedBytes: 95, totalBytes: 100)])
        let monitored = DeviceMetricsStatusBarViewController(runtimeID: "alerts", title: "fixture",
            provider: high, startsPollingAutomatically: true, settingsStore: settings,
            alertCoordinator: DeviceMetricsAlertCoordinator(settingsProvider: { settings.snapshot() }, notifier: alerts))
        monitored.loadViewIfNeeded()
        monitored.startPollingIfNeeded()
        precondition(monitored.pollingIntervalForTesting == 3 && high.requestCount == 1)
        precondition(monitored.visibleTextSnapshotForTesting.contains("上传 100 KB/s"), "virtual network counters were counted twice")
        precondition(alerts.payloads.isEmpty)
        for _ in 0..<3 { monitored.applyMetricsSettings() }
        precondition(monitored.historySampleCountForTesting(title: "CPU") == 1 && alerts.payloads.isEmpty,
                     "settings repaint created history samples or false consecutive breaches")
        settings.settings.deviceMetricsRefreshIntervalSeconds = 10
        settings.settings.deviceMetricsHideVirtualNetworkInterfaces = false
        monitored.applyMetricsSettings()
        precondition(monitored.pollingIntervalForTesting == 10 && high.requestCount == 1)
        precondition(monitored.visibleTextSnapshotForTesting.contains("上传 300 KB/s"), "explicit interface preference was ignored")
        monitored.refreshMetricsForTesting()
        precondition(Set(alerts.payloads.map(\.metricID)) == ["cpu", "memory", "disk:/"])
        precondition(alerts.payloads.allSatisfy { $0.runtimeID == "alerts" })
        monitored.refreshMetricsForTesting()
        precondition(alerts.payloads.count == 3, "sustained breaches produced duplicate notifications")
        monitored.stopPolling()
        settings.settings.deviceMetricsRefreshIntervalSeconds = 5
        monitored.applyMetricsSettings()
        precondition(monitored.pollingIntervalForTesting == nil, "a settings change restarted a hidden status bar")
        precondition(DeviceMetricsNetworkSelection.automaticSelection(from: [], hideVirtual: true).isEmpty)
        precondition(DeviceMetricsNetworkSelection.automaticSelection(from: Array(high.value.networks.dropFirst()), hideVirtual: true).count == 1)
        let virtualOnly: [DeviceNetworkDisplayRate] = [
            .init(interfaceName: "lo", receiveBytesPerSecond: 200, transmitBytesPerSecond: 200),
            .init(interfaceName: "docker0", receiveBytesPerSecond: 0, transmitBytesPerSecond: 0),
            .init(interfaceName: "veth123", receiveBytesPerSecond: 100, transmitBytesPerSecond: 100)
        ]
        precondition(DeviceMetricsNetworkSelection.automaticSelection(from: virtualOnly, hideVirtual: true).map(\.interfaceName) == ["veth123"],
                     "virtual-only host chose loopback or an idle bridge instead of an active interface")
        precondition(DeviceMetricsNetworkSelection.automaticSelection(from: Array(virtualOnly.prefix(2)), hideVirtual: true).map(\.interfaceName) == ["docker0"])
        print("PASS: real native hover opens immediately, retains identity across refresh, reanchors across resources, ignores removed cells, permits pointer transfer and scrolling, delays dismissal, yields to single-click history, resumes after history closes, and closes on disappearance without extra probes")
        print("PASS: status-bar alerts use real consecutive-breach logic; network totals respect virtual-interface selection; settings preserve history and update only an active timer")
        print("PASS: horizontal scrolling reanchors visible hover/history without replacing controllers, clips partial anchors, closes invisible sources and prevents refresh from reopening them without new user input")
        print("PASS: native window resize updates partial hover/history anchors, closes hidden sources without reopening, settles without a layout loop, and bounds observers release their controllers")
    }
}
