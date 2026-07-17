import AppKit
import SwiftTerm

public final class StacioLocalTerminalView: LocalProcessTerminalView {
    public var onOutput: (([UInt8]) -> Void)?
    public var onUserInput: (([UInt8]) -> Bool)?
    public var onSearchViewportChanged: (() -> Void)?
    public var fontZoomSettingsStore: AppSettingsStore = .shared
    public var contextMenuProvider: ((String?) -> NSMenu?)?
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

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        onOutput?(bytes)
        let settings = fontZoomSettingsStore.snapshot()
        let displayBytes = TerminalSemanticOutputHighlighter.highlight(
            bytes,
            level: settings.terminalHighlightLevel,
            richHighlightingEnabled: settings.terminalRichHighlightingEnabled,
            theme: TerminalAppearanceApplier.highlightTheme(for: settings)
        )
        super.dataReceived(slice: ArraySlice(displayBytes))
        onSearchViewportChanged?()
    }

    public override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if onUserInput?(Array(data)) == true {
            return
        }
        super.send(source: source, data: data)
    }

    public func sendProgrammaticInput(_ bytes: [UInt8]) {
        super.send(source: self, data: ArraySlice(bytes))
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
