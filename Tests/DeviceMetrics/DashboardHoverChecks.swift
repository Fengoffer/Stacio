import AppKit

enum DeviceMetricsAlertMetric { case cpuUsage, memoryUsage, diskUsage, networkIO, diskIO }

@main
struct DashboardHoverChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let screen = NSScreen.main!.visibleFrame
        let root = NSView(frame: NSRect(x: 0, y: 0, width: min(1_000, screen.width - 40),
                                       height: min(650, screen.height - 80)))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.minY + 20))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let grid = NSView(frame: NSRect(x: 0, y: 160, width: 420, height: 260))
        let anchor = NSView(frame: NSRect(x: 10, y: 150, width: 180, height: 90))
        root.addSubview(grid)
        grid.addSubview(anchor)
        let snapshot = DeviceMetricsDisplaySnapshot(cpuUsage: 0.65,
            cpuCoreUsages: (0..<96).map { .init(index: $0, usage: Double($0 % 10) / 10) },
            memory: .init(usedBytes: 60, totalBytes: 100, freeBytes: 20, buffersBytes: 5,
                          cachedBytes: 15, swapTotalBytes: 100, swapFreeBytes: 30),
            networks: [.init(interfaceName: "en0", receiveBytesPerSecond: 420, transmitBytesPerSecond: 128,
                             totalReceiveBytes: 1_000, totalTransmitBytes: 500)],
            disks: [.init(mountPath: "/", usedBytes: 70, totalBytes: 100)],
            processes: (0..<10).map { .init(pid: UInt32($0 + 1), name: "worker-\($0)",
                                            cpuFraction: Double($0) / 50, memoryFraction: Double($0) / 100) },
            sshLatencyMilliseconds: 4)
        let presenter = DeviceMetricsDashboardHoverPresenter()
        let originalChildCount = window.childWindows?.count ?? 0
        presenter.dismiss()
        precondition((window.childWindows?.count ?? 0) == originalChildCount,
                     "dismiss before the first hover must not create a child window")
        let virtualScreen = window.convertToScreen(root.bounds)
        presenter.screenVisibleFrameForTesting = virtualScreen
        func pump(_ seconds: TimeInterval = 0.05) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func show(_ title: String = "CPU") {
            presenter.show(title: title, snapshot: snapshot, anchor: anchor, avoiding: grid) { value, _ in
                value >= 0.9 ? .systemRed : value >= 0.8 ? .systemOrange : .systemGreen
            }
            pump()
            precondition(presenter.isShownForTesting, "hover panel failed to open for \(title)")
        }
        func checkNoOverlap() {
            let panel = presenter.panelForTesting
            let avoid = window.convertToScreen(grid.convert(grid.bounds, to: nil))
            precondition(!panel.frame.intersects(avoid), "detail panel covers the resource grid")
            precondition(presenter.screenVisibleFrameForTesting!.contains(panel.frame), "detail panel escaped visible screen")
            let detail = presenter.detailControllerForTesting
            precondition(abs(panel.frame.height - detail.preferredContentSize.height) < 1)
            precondition(abs(detail.view.frame.height - detail.preferredContentSize.height) < 1)
            precondition(!panel.canBecomeKey && !panel.canBecomeMain, "hover must not steal keyboard focus")
        }

        pump()
        show()
        checkNoOverlap()
        let panel = presenter.panelForTesting
        let detail = presenter.detailControllerForTesting
        precondition(!panel.isOpaque && panel.backgroundColor == .clear && panel.hasShadow,
                     "Floating details need a transparent window and a native shadow")
        if #available(macOS 26.0, *), GlassCapabilityAdapter.currentCapability() == .systemGlass {
            guard let glass = detail.view as? NSGlassEffectView else {
                preconditionFailure("Dashboard details did not request their floating glass surface")
            }
            precondition(glass.cornerRadius == 14 && glass.contentView != nil,
                         "Floating details must use native rounded glass and its supported content slot")
        }
        precondition((detail.view.layer?.borderWidth ?? 0) == 0,
                     "Floating details gained a duplicate custom outline")
        let visibleObserverCount = presenter.observerCountForTesting
        let visibleChildCount = window.childWindows?.count ?? 0
        for _ in 0..<3 {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            pump()
            precondition(presenter.panelForTesting === panel && presenter.detailControllerForTesting === detail,
                         "An unchanged accessibility notification rebuilt the hover surface")
            precondition(presenter.observerCountForTesting == visibleObserverCount
                         && (window.childWindows?.count ?? 0) == visibleChildCount,
                         "Accessibility notifications duplicated windows or observers")
            checkNoOverlap()
        }
        precondition(panel.frame.minX >= window.convertToScreen(grid.convert(grid.bounds, to: nil)).maxX)
        let oldOrigin = panel.frame.origin
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 10, y: window.frame.minY))
        presenter.screenVisibleFrameForTesting = window.convertToScreen(root.bounds)
        presenter.reposition()
        pump()
        precondition(abs(panel.frame.minX - oldOrigin.x - 10) < 1,
                     "hover did not track host window movement")
        window.setFrameOrigin(NSPoint(x: window.frame.minX - 10, y: window.frame.minY))
        presenter.screenVisibleFrameForTesting = virtualScreen
        presenter.reposition()
        grid.setFrameOrigin(NSPoint(x: root.bounds.width - grid.frame.width, y: 160))
        presenter.reposition()
        checkNoOverlap()
        precondition(panel.frame.maxX <= window.convertToScreen(grid.convert(grid.bounds, to: nil)).minX)

        // With no wide side region, the bounded viewport fits above or below.
        grid.frame = NSRect(x: 260, y: 190, width: root.bounds.width - 520, height: 170)
        anchor.frame = NSRect(x: 10, y: 60, width: 180, height: 90)
        presenter.reposition()
        checkNoOverlap()
        precondition(panel.frame.height < 300, "vertical fallback should bound the scrollable content")
        let scroll = descendants(detail.view).compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.documentView!.frame.height > scroll.contentSize.height,
                     "long CPU list must remain available by scrolling")

        grid.frame = NSRect(x: 0, y: 60, width: 420, height: 100)
        anchor.frame = NSRect(x: 10, y: 5, width: 180, height: 90)
        presenter.screenVisibleFrameForTesting = NSRect(x: virtualScreen.minX, y: virtualScreen.minY,
                                                        width: virtualScreen.width, height: 260)
        presenter.reposition()
        checkNoOverlap()
        precondition(panel.frame.height <= 244)
        show("内存")
        precondition(presenter.panelForTesting === panel && presenter.detailControllerForTesting === detail,
                     "resource changes should reuse their panel and detail controller")
        presenter.update(snapshot: snapshot) { _, _ in .systemGreen }
        checkNoOverlap()

        presenter.scheduleDismissal()
        detail.onHoverChanged?(true)
        pump(0.32)
        precondition(presenter.isShownForTesting, "moving into detail must cancel delayed dismissal")
        detail.onHoverChanged?(false)
        pump(0.32)
        precondition(!presenter.isShownForTesting && presenter.observerCountForTesting == 0 && panel.parent == nil,
                     "exit must close the panel and remove source observers")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        pump()
        precondition(!presenter.isShownForTesting && presenter.observerCountForTesting == 0 && panel.parent == nil,
                     "A workspace notification reopened a dismissed hover or leaked its observer")
        show()
        anchor.isHidden = true
        pump()
        precondition(!presenter.isShownForTesting, "a hidden source must close its detail")
        anchor.isHidden = false
        show()
        anchor.removeFromSuperview()
        pump()
        precondition(!presenter.isShownForTesting, "a removed source must close its detail")
        grid.addSubview(anchor)
        show()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(!presenter.isShownForTesting && presenter.observerCountForTesting == 0)

        // A clip-view bounds change must remove details once their source leaves
        // the viewport; there is no polling timer doing this cleanup.
        grid.removeFromSuperview()
        let viewport = NSScrollView(frame: root.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: root.bounds.width, height: 1_500))
        viewport.documentView = document
        root.addSubview(viewport)
        document.addSubview(grid)
        viewport.contentView.scroll(to: .zero)
        presenter.screenVisibleFrameForTesting = virtualScreen
        show()
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 900))
        viewport.reflectScrolledClipView(viewport.contentView)
        pump()
        precondition(!presenter.isShownForTesting && presenter.observerCountForTesting == 0,
                     "scrolling source did not close: visible=\(anchor.visibleRect), clip=\(viewport.contentView.bounds), observers=\(presenter.observerCountForTesting)")
        viewport.contentView.scroll(to: .zero)
        var temporary: DeviceMetricsDashboardHoverPresenter? = DeviceMetricsDashboardHoverPresenter()
        temporary?.screenVisibleFrameForTesting = virtualScreen
        temporary?.show(title: "磁盘", snapshot: snapshot, anchor: anchor, avoiding: grid) { _, _ in .systemGreen }
        let orphanCandidate = temporary!.panelForTesting
        weak var weakPresenter = temporary
        precondition(orphanCandidate.isVisible)
        temporary = nil
        pump()
        precondition(weakPresenter == nil && !orphanCandidate.isVisible && orphanCandidate.parent == nil,
                     "disposing the presenter left a retained child window")
        print("Dashboard hover native placement, sizing, reuse and lifecycle checks passed")
    }
}
