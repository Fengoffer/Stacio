import AppKit
import SwiftTerm

public enum StacioTerminalMouseBehavior {
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
        let behavior = settingsStore.snapshot().terminalRightClickBehavior
        if behavior == .contextMenu,
           let menu = contextMenuProvider?(terminalView.getSelection()) {
            NSMenu.popUpContextMenu(menu, with: event, for: terminalView)
            return
        }
        switch behavior {
        case .paste:
            pasteClipboard(into: terminalView)
        case .contextMenu, .none:
            return
        }
    }
}

public final class TerminalFocusContainerView: NSView {
    public weak var terminalFocusView: TerminalView?
    public var onEffectiveAppearanceChanged: (() -> Void)?
    private var effectiveAppearanceObservation: NSKeyValueObservation?
    private var systemAppearanceObserver: NSObjectProtocol?
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
        performEffectiveAppearanceRefresh()
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
