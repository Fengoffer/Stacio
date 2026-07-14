import AppKit
import SwiftTerm

    public final class StacioRemoteTerminalView: TerminalView {
        public var fontZoomSettingsStore: AppSettingsStore = .shared
        public var contextMenuProvider: ((String?) -> NSMenu?)?
        public var onSearchViewportChanged: (() -> Void)?
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
        public private(set) var lastFeedAppliedSemanticHighlightingForTesting = false
        private var controlScrollZoomMonitor: Any?
        private var linkInteractionMonitor: Any?

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureStacioLinkInteraction()
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) {
            nil
        }

    deinit {
        if let controlScrollZoomMonitor {
            NSEvent.removeMonitor(controlScrollZoomMonitor)
        }
        if let linkInteractionMonitor {
            NSEvent.removeMonitor(linkInteractionMonitor)
        }
    }

    public override var mouseDownCanMoveWindow: Bool {
        false
    }

        public func feedRemoteOutput(_ bytes: [UInt8], applySemanticHighlighting: Bool = true) {
            let displayBytes: [UInt8]
            if applySemanticHighlighting {
                let settings = fontZoomSettingsStore.snapshot()
                displayBytes = TerminalSemanticOutputHighlighter.highlight(
                    bytes,
                    level: settings.terminalHighlightLevel,
                    richHighlightingEnabled: settings.terminalRichHighlightingEnabled,
                    theme: TerminalAppearanceApplier.highlightTheme(for: settings)
                )
            } else {
                displayBytes = bytes
            }
            lastFeedAppliedSemanticHighlightingForTesting = applySemanticHighlighting
            feed(byteArray: ArraySlice(displayBytes))
            onSearchViewportChanged?()
        }

        private func configureStacioLinkInteraction() {
            linkReporting = .implicit
            linkHighlightMode = .hoverWithModifier
        }

    public override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        StacioTerminalMouseBehavior.copySelectionToClipboardIfNeeded(
            from: self,
            settingsStore: fontZoomSettingsStore
        )
    }

    public override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        onSearchViewportChanged?()
    }

    public override func rightMouseDown(with event: NSEvent) {
        StacioTerminalMouseBehavior.handleRightMouseDown(
            in: self,
            event: event,
            settingsStore: fontZoomSettingsStore,
            contextMenuProvider: contextMenuProvider
        )
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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateControlScrollZoomMonitor()
        updateLinkInteractionMonitor()
    }

    private func updateControlScrollZoomMonitor() {
        if let controlScrollZoomMonitor {
            NSEvent.removeMonitor(controlScrollZoomMonitor)
            self.controlScrollZoomMonitor = nil
        }
        guard window != nil else { return }
        controlScrollZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.control),
                  StacioTerminalMouseBehavior.shouldApplyControlScrollZoom(settingsStore: self.fontZoomSettingsStore),
                  let window = self.window,
                  event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else {
                return event
            }
            TerminalFontZoomController.applyControlScrollZoom(
                deltaY: event.deltaY,
                settingsStore: self.fontZoomSettingsStore,
                terminalView: self
            )
            return nil
        }
    }

    private func updateLinkInteractionMonitor() {
        if let linkInteractionMonitor {
            NSEvent.removeMonitor(linkInteractionMonitor)
            self.linkInteractionMonitor = nil
        }
        guard window != nil else { return }
        linkInteractionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .mouseMoved, .flagsChanged]) { [weak self] event in
            guard let self,
                  event.window === self.window
            else {
                return event
            }
            return TerminalLinkInteraction.handleEvent(in: self, event: event)
        }
    }

    public func performControlScrollZoomForTesting(deltaY: CGFloat) {
        guard StacioTerminalMouseBehavior.shouldApplyControlScrollZoom(settingsStore: fontZoomSettingsStore) else {
            return
        }
        TerminalFontZoomController.applyControlScrollZoom(
            deltaY: deltaY,
            settingsStore: fontZoomSettingsStore,
            terminalView: self
        )
    }
}
