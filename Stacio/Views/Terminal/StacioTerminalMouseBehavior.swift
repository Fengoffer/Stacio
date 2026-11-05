import AppKit
import SwiftTerm

struct TerminalSelectionAutoCopyGate {
    private var isPointerSelectionActive = false
    private var didChangeSelectionDuringPointerSelection = false

    mutating func beginPointerSelection() {
        isPointerSelectionActive = true
        didChangeSelectionDuringPointerSelection = false
    }

    mutating func shouldCopyAfterSelectionChanged() -> Bool {
        guard isPointerSelectionActive else { return true }
        didChangeSelectionDuringPointerSelection = true
        return false
    }

    mutating func shouldCopyAfterMouseUp() -> Bool {
        defer {
            isPointerSelectionActive = false
            didChangeSelectionDuringPointerSelection = false
        }
        return isPointerSelectionActive && didChangeSelectionDuringPointerSelection
    }
}

public enum StacioTerminalMouseBehavior {
    enum RightMouseDownAction: Equatable {
        case paste
        case contextMenu
        case none
    }

    public static func focusForKeyboardInput(_ terminalView: TerminalView) {
        guard terminalView.acceptsFirstResponder else { return }
        terminalView.window?.makeFirstResponder(terminalView)
    }

    public static func copySelectionToClipboardIfNeeded(
        from terminalView: TerminalView,
        settingsStore: AppSettingsStore = .shared
    ) {
        guard settingsStore.snapshot().terminalSelectionAutoCopyEnabled else {
            return
        }
        guard let selectedText = terminalView.getSelection(),
              selectedText.isEmpty == false
        else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    public static func pasteClipboard(into terminalView: TerminalView) {
        focusForKeyboardInput(terminalView)
        terminalView.paste(terminalView)
    }

    public static func shouldApplyControlScrollZoom(settingsStore: AppSettingsStore = .shared) -> Bool {
        settingsStore.snapshot().terminalControlScrollZoomEnabled
    }

    public static func handleRightMouseDown(
        in terminalView: TerminalView,
        event: NSEvent,
        settingsStore: AppSettingsStore = .shared,
        contextMenuProvider: ((String?) -> NSMenu?)?
    ) {
        handleRightMouseDown(
            in: terminalView,
            event: event,
            settingsStore: settingsStore,
            contextMenuProvider: contextMenuProvider,
            pasteAction: { pasteClipboard(into: terminalView) },
            contextMenuAction: { menu in
                NSMenu.popUpContextMenu(menu, with: event, for: terminalView)
            }
        )
    }

    static func rightMouseDownAction(
        behavior: TerminalRightClickBehaviorPreference,
        modifierFlags: NSEvent.ModifierFlags
    ) -> RightMouseDownAction {
        switch behavior {
        case .paste:
            return modifierFlags.contains(.option) ? .contextMenu : .paste
        case .contextMenu:
            return .contextMenu
        case .none:
            return .none
        }
    }

    static func handleRightMouseDown(
        in terminalView: TerminalView,
        event: NSEvent,
        settingsStore: AppSettingsStore,
        contextMenuProvider: ((String?) -> NSMenu?)?,
        pasteAction: @escaping () -> Void,
        contextMenuAction: @escaping (NSMenu) -> Void
    ) {
        let action = rightMouseDownAction(
            behavior: settingsStore.snapshot().terminalRightClickBehavior,
            modifierFlags: event.modifierFlags
        )
        switch action {
        case .paste:
            pasteAction()
        case .contextMenu:
            guard let menu = contextMenuProvider?(terminalView.getSelection()) else { return }
            contextMenuAction(menu)
        case .none:
            return
        }
    }
}

public final class TerminalFocusContainerView: NSView {
    public weak var terminalFocusView: TerminalView?
    public var onTerminalFocusRequested: (() -> Void)?
    public var onEffectiveAppearanceChanged: (() -> Void)?
    private var effectiveAppearanceObservation: NSKeyValueObservation?
    private var systemAppearanceObserver: NSObjectProtocol?
    /// 是否已对当前窗口做过首次外观刷新。
    ///
    /// 切回标签页会反复触发 `viewDidMoveToWindow`，若每次都执行
    /// `performEffectiveAppearanceRefresh` + `scheduleEffectiveAppearanceRefresh`
    /// （共 5 次完整重布局），会让终端反复 apply（setFrameSize/needsLayout），
    /// 在 Claude 等 TUI 全屏应用下产生抖动。此标志确保仅首次挂载时同步刷新一次；
    /// 真实外观变化由 `viewDidChangeEffectiveAppearance` 与 KVO 观察负责。
    /// 视图离开窗口（window 变 nil）时重置，以便重新挂载到新窗口时能再次首次刷新。
    private var didPerformInitialAppearanceRefresh = false
    public var acceptsLocalFileDrops: (() -> Bool)? {
        didSet {
            LocalFileDropHandler.register(self)
        }
    }

    public var localFileDropHandler: (([String]) -> Void)? {
        didSet {
            LocalFileDropHandler.register(self)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performEffectiveAppearanceRefresh()
        scheduleEffectiveAppearanceRefresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        effectiveAppearanceObservation = window?.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            self?.scheduleEffectiveAppearanceRefresh()
        }
        installSystemAppearanceObserverIfNeeded()
        if window == nil {
            // 视图离开窗口：重置标志，使重新挂载到新窗口时能再次首次刷新。
            didPerformInitialAppearanceRefresh = false
            return
        }
        // 仅在首次挂载到窗口时做一次同步外观刷新；切回标签页会反复触发
        // viewDidMoveToWindow，若每次都 performEffectiveAppearanceRefresh +
        // scheduleEffectiveAppearanceRefresh（共 5 次）会让终端反复 apply，
        // 在 Claude 等 TUI 全屏应用下产生抖动。真实外观变化由
        // viewDidChangeEffectiveAppearance 与上面的 KVO 观察负责。
        if didPerformInitialAppearanceRefresh == false {
            didPerformInitialAppearanceRefresh = true
            performEffectiveAppearanceRefresh()
        }
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
        let delays: [TimeInterval] = [0, 0.02, 0.12, 0.35]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performEffectiveAppearanceRefresh()
            }
        }
    }

    private func performEffectiveAppearanceRefresh() {
        if let window {
            appearance = window.effectiveAppearance
        }
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
        onEffectiveAppearanceChanged?()
        needsDisplay = true
        terminalFocusView?.needsDisplay = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        if let terminalFocusView,
           hitView != nil,
           hitView === terminalFocusView || hitView?.isDescendant(of: terminalFocusView) == true {
            StacioTerminalMouseBehavior.focusForKeyboardInput(terminalFocusView)
            if terminalFocusView.window?.firstResponder === terminalFocusView {
                onTerminalFocusRequested?()
            }
        }
        return hitView
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsLocalFileDrops?() ?? (localFileDropHandler != nil) else {
            return []
        }
        return LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsLocalFileDrops?() ?? (localFileDropHandler != nil) else {
            return false
        }
        return LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.localFileDropHandler?(paths)
        }
    }
}
