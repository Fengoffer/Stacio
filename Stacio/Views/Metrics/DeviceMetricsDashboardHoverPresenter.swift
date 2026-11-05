import AppKit

/// Hosts the shared metric detail UI beside the dashboard's resource grid.
/// It consumes the dashboard's latest sample and never starts polling itself.
@MainActor
final class DeviceMetricsDashboardHoverPresenter {
    typealias UsageColor = (Double, DeviceMetricsAlertMetric) -> NSColor

    private var detailController = DeviceMetricsStatusDetailViewController(presentation: .floating)
    private var surfaceEnvironment: GlassCapabilityEnvironment?
    private var retainedPanel: DashboardMetricDetailPanel?
    private var panel: DashboardMetricDetailPanel {
        if let retainedPanel { return retainedPanel }
        let created = makePanel()
        retainedPanel = created
        return created
    }
    private weak var anchor: NSView?
    private weak var avoiding: NSView?
    private weak var hostWindow: NSWindow?
    private var anchorMonitor: DashboardMetricAnchorMonitor?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pendingDismissal: DispatchWorkItem?
    private var title = ""
    private var snapshot: DeviceMetricsDisplaySnapshot?
    private var usageColor: UsageColor?
    private var renderedWidth: CGFloat?
    private var renderedMaximumHeight: CGFloat?
    private var dismissalGeneration = 0
    private var isPresenting = false

    // Also lets the native smoke harness exercise constrained screens without
    // changing the user's display configuration.
    var screenVisibleFrameForTesting: NSRect?
    var isShown: Bool { isPresenting && retainedPanel?.isVisible == true }
    var isShownForTesting: Bool { isShown }
    var panelForTesting: NSPanel { panel }
    var detailControllerForTesting: DeviceMetricsStatusDetailViewController { detailController }
    var observerCountForTesting: Int { observers.count }

    deinit {
        pendingDismissal?.cancel()
        observers.forEach { $0.center.removeObserver($0.token) }
        // A host retains child windows. Detach even when its presenter is dropped
        // without a matching view-disappearance callback.
        let panelToClose = retainedPanel
        let monitorToRemove = anchorMonitor
        DispatchQueue.main.async {
            if let panelToClose {
                panelToClose.parent?.removeChildWindow(panelToClose)
                panelToClose.orderOut(nil)
            }
            monitorToRemove?.onAvailabilityChanged = nil
            monitorToRemove?.onAppearanceChanged = nil
            monitorToRemove?.removeFromSuperview()
        }
    }

    func show(title: String, snapshot: DeviceMetricsDisplaySnapshot, anchor: NSView,
              avoiding: NSView, usageColor: @escaping UsageColor) {
        guard let window = anchor.window, avoiding.window === window else { dismiss(); return }
        cancelDismissal()
        if self.anchor !== anchor || self.avoiding !== avoiding || hostWindow !== window {
            detachSource()
            self.anchor = anchor
            self.avoiding = avoiding
            hostWindow = window
            attachSource(anchor, window: window)
        }
        self.title = title
        self.snapshot = snapshot
        self.usageColor = usageColor
        isPresenting = true
        renderAndPosition(forceRender: true)
    }

    func update(snapshot: DeviceMetricsDisplaySnapshot, usageColor: @escaping UsageColor) {
        guard isPresenting else { return }
        self.snapshot = snapshot
        self.usageColor = usageColor
        renderAndPosition(forceRender: true)
    }

    func scheduleDismissal() {
        guard isPresenting else { return }
        cancelDismissal()
        let generation = dismissalGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dismissalGeneration == generation else { return }
            self.dismiss()
        }
        pendingDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func dismiss() {
        isPresenting = false
        cancelDismissal()
        if let retainedPanel {
            retainedPanel.parent?.removeChildWindow(retainedPanel)
            retainedPanel.orderOut(nil)
        }
        detachSource()
        snapshot = nil
        usageColor = nil
        renderedWidth = nil
        renderedMaximumHeight = nil
    }

    func reposition() {
        guard isPresenting else { return }
        renderAndPosition(forceRender: false)
    }

    private func cancelDismissal() {
        dismissalGeneration &+= 1
        pendingDismissal?.cancel()
        pendingDismissal = nil
    }

    private func makePanel() -> DashboardMetricDetailPanel {
        let window = DashboardMetricDetailPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = true
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .fullScreenAuxiliary]
        window.contentViewController = detailController
        detailController.loadViewIfNeeded()
        detailController.onHoverChanged = { [weak self] inside in
            if inside { self?.cancelDismissal() } else { self?.scheduleDismissal() }
        }
        return window
    }

    private func renderAndPosition(forceRender: Bool) {
        guard let anchor, let avoiding, let window = hostWindow,
              anchor.window === window, avoiding.window === window,
              window.isVisible, !window.isMiniaturized,
              !anchor.isHiddenOrHasHiddenAncestor, !avoiding.isHiddenOrHasHiddenAncestor,
              !anchor.visibleRect.intersection(anchor.bounds).isEmpty, let snapshot, let usageColor,
              let screen = screenVisibleFrameForTesting ?? window.screen?.visibleFrame else {
            dismiss(); return
        }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.visibleRect.intersection(anchor.bounds), to: nil))
        let avoidRect = window.convertToScreen(avoiding.convert(avoiding.bounds, to: nil))
        let defaultWidth: CGFloat
        switch title {
        case "CPU", "内存", "磁盘读写": defaultWidth = 440
        case "磁盘": defaultWidth = 380
        case "上传", "下载", "网络 I/O": defaultWidth = 400
        default: defaultWidth = 360
        }
        guard let placement = Self.availablePlacement(avoiding: avoidRect, screen: screen,
                                                       preferredWidth: defaultWidth) else {
            dismiss(); return
        }
        let width = min(defaultWidth, placement.region.width)
        let maximumHeight = placement.region.height
        let environment = GlassCapabilityAdapter.currentEnvironment()
        if surfaceEnvironment != environment {
            // Accessibility settings can change while this reusable presenter
            // is hidden or open. Let the adapter choose the material again.
            if let retainedPanel {
                retainedPanel.parent?.removeChildWindow(retainedPanel)
                retainedPanel.orderOut(nil)
            }
            retainedPanel = nil
            detailController = DeviceMetricsStatusDetailViewController(
                presentation: .floating, surfaceEnvironment: environment)
            surfaceEnvironment = environment
            renderedWidth = nil
            renderedMaximumHeight = nil
        }
        panel.appearance = anchor.effectiveAppearance
        if forceRender || renderedWidth != width || renderedMaximumHeight != maximumHeight {
            detailController.update(title: title, detail: "", snapshot: snapshot,
                                    maximumContentHeight: maximumHeight, contentWidth: width, usageColor: usageColor)
            renderedWidth = width
            renderedMaximumHeight = maximumHeight
        }
        let size = detailController.preferredContentSize
        // A shared detail renderer that cannot fit must not cover the resource grid.
        guard size.width <= placement.region.width + 0.5,
              size.height <= placement.region.height + 0.5 else { dismiss(); return }
        let frame = placement.frame(size: size, anchor: anchorRect)
        guard !frame.intersects(avoidRect), screen.contains(frame) else { dismiss(); return }
        panel.setFrame(frame, display: true)
        detailController.view.setFrameSize(size)
        detailController.view.layoutSubtreeIfNeeded()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func attachSource(_ source: NSView, window: NSWindow) {
        let monitor = DashboardMetricAnchorMonitor(frame: .zero)
        source.addSubview(monitor)
        monitor.onAvailabilityChanged = { [weak self] in self?.reposition() }
        monitor.onAppearanceChanged = { [weak self] in
            guard let self, self.isPresenting else { return }
            self.renderAndPosition(forceRender: true)
        }
        anchorMonitor = monitor
        func observe(_ name: Notification.Name, object: AnyObject?,
                     center: NotificationCenter = .default, action: @escaping () -> Void) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
            observers.append((center, token))
        }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.renderAndPosition(forceRender: true)
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            observe(name, object: window) { [weak self] in self?.reposition() }
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification] {
            observe(name, object: window) { [weak self] in self?.dismiss() }
        }
        observe(NSApplication.didResignActiveNotification, object: NSApp) { [weak self] in self?.dismiss() }
        // Bounds notifications cover scrolling; frame notifications cover split
        // view and dashboard layout changes without a repeating monitor timer.
        var ancestor: NSView? = source
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, object: view) { [weak self] in self?.reposition() }
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, object: clip) { [weak self] in self?.dismiss() }
            }
            ancestor = view.superview
        }
    }

    private func detachSource() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        anchorMonitor?.onAvailabilityChanged = nil
        anchorMonitor?.onAppearanceChanged = nil
        anchorMonitor?.removeFromSuperview()
        anchorMonitor = nil
        anchor = nil
        avoiding = nil
        hostWindow = nil
    }

    private struct Placement {
        enum Side { case left, right, above, below }
        let region: NSRect
        let side: Side

        func frame(size: NSSize, anchor: NSRect) -> NSRect {
            func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
                min(max(value, low), high)
            }
            let x: CGFloat
            let y: CGFloat
            switch side {
            case .left, .right:
                x = side == .left ? region.maxX - size.width : region.minX
                y = clamp(anchor.maxY - size.height, region.minY, region.maxY - size.height)
            case .above, .below:
                x = clamp(anchor.midX - size.width / 2, region.minX, region.maxX - size.width)
                y = side == .above ? region.minY : region.maxY - size.height
            }
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
    }

    private static func availablePlacement(avoiding avoid: NSRect, screen: NSRect,
                                          preferredWidth: CGFloat) -> Placement? {
        let bounds = screen.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 12
        let minimumWidth: CGFloat = 280
        let minimumHeight: CGFloat = 100
        let left = Placement(region: NSRect(x: bounds.minX, y: bounds.minY,
            width: max(0, min(bounds.maxX, avoid.minX - gap) - bounds.minX), height: bounds.height), side: .left)
        let rightX = max(bounds.minX, avoid.maxX + gap)
        let right = Placement(region: NSRect(x: rightX, y: bounds.minY,
            width: max(0, bounds.maxX - rightX), height: bounds.height), side: .right)
        let aboveY = max(bounds.minY, avoid.maxY + gap)
        let above = Placement(region: NSRect(x: bounds.minX, y: aboveY,
            width: bounds.width, height: max(0, bounds.maxY - aboveY)), side: .above)
        let below = Placement(region: NSRect(x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: max(0, min(bounds.maxY, avoid.minY - gap) - bounds.minY)), side: .below)
        let candidates = [left, right]
        return candidates.first { $0.region.width >= preferredWidth && $0.region.height >= minimumHeight }
            ?? candidates.first { $0.region.width >= minimumWidth && $0.region.height >= minimumHeight }
            ?? [above, below].first { $0.region.width >= minimumWidth && $0.region.height >= minimumHeight }
    }
}

@MainActor
private final class DashboardMetricDetailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DashboardMetricAnchorMonitor: NSView {
    var onAvailabilityChanged: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAvailabilityChanged?() }
    override func viewDidHide() { super.viewDidHide(); onAvailabilityChanged?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChanged?() }
}
