import AppKit
import SwiftTerm

    public final class StacioRemoteTerminalView: TerminalView {
        public var fontZoomSettingsStore: AppSettingsStore = .shared
        public var contextMenuProvider: ((String?) -> NSMenu?)?
        public var onSearchViewportChanged: (() -> Void)?
        public var semanticHighlightProfile: TerminalSemanticHighlightProfile = .generalPurpose
        public var semanticHighlightThemeOverride: TerminalColorTheme?
        public private(set) var isProcessingRemoteOutput = false
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
        private let semanticOutputProcessor = TerminalSemanticOutputProcessor(
            label: "cn.stacio.terminal.semantic.remote.\(UUID().uuidString)"
        )
        private var controlScrollZoomMonitor: Any?
        private var linkInteractionMonitor: Any?
        private var selectionAutoCopyGate = TerminalSelectionAutoCopyGate()
        private var tracksFrameSizeTransitionsForTesting = false
        private var lastTrackedFrameSizeForTesting: NSSize?
        private(set) var distinctFrameSizeTransitionsForTesting: [NSSize] = []

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureStacioLinkInteraction()
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) {
            nil
        }

    deinit {
        semanticOutputProcessor.cancel()
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

    public override func setFrameSize(_ newSize: NSSize) {
        if tracksFrameSizeTransitionsForTesting,
           lastTrackedFrameSizeForTesting.map({
               abs($0.width - newSize.width) > 0.5 || abs($0.height - newSize.height) > 0.5
           }) ?? true
        {
            distinctFrameSizeTransitionsForTesting.append(newSize)
            lastTrackedFrameSizeForTesting = newSize
        }
        super.setFrameSize(newSize)
    }

    func beginFrameSizeTransitionTrackingForTesting() {
        distinctFrameSizeTransitionsForTesting.removeAll(keepingCapacity: true)
        lastTrackedFrameSizeForTesting = frame.size
        tracksFrameSizeTransitionsForTesting = true
    }

        public func feedRemoteOutput(_ bytes: [UInt8], applySemanticHighlighting: Bool = true) {
            let configuration: TerminalSemanticHighlightConfiguration?
            if applySemanticHighlighting {
                let settings = fontZoomSettingsStore.snapshot()
                configuration = TerminalSemanticHighlightConfiguration(
                    level: settings.terminalHighlightLevel,
                    richHighlightingEnabled: settings.terminalRichHighlightingEnabled,
                    theme: semanticHighlightThemeOverride ?? TerminalAppearanceApplier.highlightTheme(for: settings),
                    profile: semanticHighlightProfile,
                    highlightsIncompleteLines: false
                )
            } else {
                configuration = nil
            }
            lastFeedAppliedSemanticHighlightingForTesting = applySemanticHighlighting
            semanticOutputProcessor.process(
                bytes: bytes,
                configuration: configuration
            ) { [weak self] displayBytes in
                guard let self else { return }
                self.isProcessingRemoteOutput = true
                defer { self.isProcessingRemoteOutput = false }
                self.feed(byteArray: ArraySlice(displayBytes))
                self.onSearchViewportChanged?()
            }
        }

        func cancelPendingSemanticOutput() {
            semanticOutputProcessor.cancel()
        }

        private func configureStacioLinkInteraction() {
            linkReporting = .implicit
            linkHighlightMode = .hoverWithModifier
        }

    public override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        guard selectionAutoCopyGate.shouldCopyAfterSelectionChanged() else { return }
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
                  TerminalLinkInteraction.isEventTargetingTerminalSurface(self, event: event)
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
        linkInteractionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: TerminalLinkInteraction.monitoredEventMask
        ) { [weak self] event in
            guard let self,
                  event.window === self.window
            else {
                return event
            }
            if event.type == .leftMouseDown,
               TerminalLinkInteraction.isEventTargetingTerminalSurface(self, event: event) {
                self.selectionAutoCopyGate.beginPointerSelection()
            } else if event.type == .leftMouseUp {
                self.finishPointerSelectionAutoCopyIfNeeded()
            }
            return TerminalLinkInteraction.handleEvent(in: self, event: event)
        }
    }

    private func finishPointerSelectionAutoCopyIfNeeded() {
        guard selectionAutoCopyGate.shouldCopyAfterMouseUp() else { return }
        StacioTerminalMouseBehavior.copySelectionToClipboardIfNeeded(
            from: self,
            settingsStore: fontZoomSettingsStore
        )
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
