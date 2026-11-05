import AppKit

enum StacioDesignSystem {
    struct Theme {
        let separatorColor = NSColor.separatorColor
    }

    static let theme = Theme()

    static func metricsFloatingSurfaceColor(for object: Any) -> NSColor {
        .controlBackgroundColor
    }

    static func setLayerBackgroundColor(_ view: NSView, color: NSColor) {
        view.layer?.backgroundColor = color.cgColor
    }

    static func setLayerBorderColor(_ view: NSView, color: NSColor) {
        view.layer?.borderColor = color.cgColor
    }
}

@MainActor
private final class DashboardTileClickRecorder: NSObject {
    private(set) var historyClicks = 0
    private(set) var buttonClicks = 0

    @objc func historyClicked(_ sender: NSClickGestureRecognizer) {
        historyClicks += 1
    }

    @objc func buttonClicked(_ sender: NSButton) {
        buttonClicks += 1
    }
}

@main
struct DashboardTileGestureChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // A non-zero origin catches frame-vs-bounds mistakes in production
        // hitTest(_:), matching the right-hand tiles in the overview grid.
        let tile = makeProductionMetricTileForGestureCheck(
            frame: NSRect(x: 120, y: 45, width: 360, height: 180)
        )
        root.addSubview(tile)

        let recorder = DashboardTileClickRecorder()
        let history = NSClickGestureRecognizer(target: recorder, action: #selector(DashboardTileClickRecorder.historyClicked(_:)))
        history.numberOfClicksRequired = 1
        installProductionMetricTileDelegate(history, on: tile)
        tile.addGestureRecognizer(history)

        let button = NSButton(title: "编辑阈值", target: recorder, action: #selector(DashboardTileClickRecorder.buttonClicked(_:)))
        button.frame = NSRect(x: 245, y: 125, width: 96, height: 30)
        tile.addSubview(button)

        // Dashboard labels are read-only but selectable so users can copy their
        // values. A plain click still belongs to the tile's history action.
        let label = NSTextField(labelWithString: "CPU 42%")
        label.isEditable = false
        label.isSelectable = true
        label.frame = NSRect(x: 20, y: 125, width: 120, height: 24)
        tile.addSubview(label)

        window.contentView?.layoutSubtreeIfNeeded()
        pumpRunLoop()

        let blankPoint = NSPoint(x: 50, y: 55)
        let labelPoint = NSPoint(x: label.frame.midX, y: label.frame.midY)
        let buttonPoint = NSPoint(x: button.frame.midX, y: button.frame.midY)

        let blankPointInSuperview = tile.convert(blankPoint, to: root)
        let labelPointInSuperview = tile.convert(labelPoint, to: root)
        let buttonPointInSuperview = tile.convert(buttonPoint, to: root)
        precondition(tile.hitTest(blankPointInSuperview) === tile,
                     "a metric tile at a non-zero origin rejects its own local hit coordinates")
        precondition(tile.hitTest(labelPointInSuperview) === label,
                     "the read-only metric label is not reachable through the tile")
        precondition(tile.hitTest(buttonPointInSuperview) === button,
                     "the threshold button is not reachable through the tile")

        precondition(shouldAttempt(history, at: blankPoint, in: tile),
                     "a plain tile click was incorrectly rejected")
        precondition(shouldAttempt(history, at: labelPoint, in: tile),
                     "a read-only selectable label should retain the tile history click")
        precondition(!shouldAttempt(history, at: buttonPoint, in: tile),
                     "an interactive child button was allowed to open history")

        click(at: buttonPoint, in: tile, window: window)
        precondition(recorder.buttonClicks == 1,
                     "the child button did not receive its native click")
        precondition(recorder.historyClicks == 0,
                     "the child button click also fired the tile history action")

        click(at: blankPoint, in: tile, window: window)
        precondition(recorder.historyClicks == 1,
                     "a plain tile click did not fire the history action")

        click(at: labelPoint, in: tile, window: window)
        precondition(recorder.historyClicks == 2,
                     "a read-only label click did not fire the tile history action")
        precondition(recorder.buttonClicks == 1,
                     "tile or label clicks unexpectedly fired the child button")

        print("PASS: production dashboard tile hit testing preserves child buttons while plain tile and read-only label clicks open history")
    }

    @MainActor
    private static func shouldAttempt(
        _ recognizer: NSGestureRecognizer,
        at point: NSPoint,
        in tile: NSView
    ) -> Bool {
        guard let event = mouseEvent(type: .leftMouseDown, at: point, in: tile) else {
            preconditionFailure("failed to create gesture decision event")
        }
        return recognizer.delegate?.gestureRecognizer?(
            recognizer,
            shouldAttemptToRecognizeWith: event
        ) ?? true
    }

    @MainActor
    private static func click(at point: NSPoint, in tile: NSView, window: NSWindow) {
        guard let down = mouseEvent(type: .leftMouseDown, at: point, in: tile),
              let up = mouseEvent(type: .leftMouseUp, at: point, in: tile)
        else {
            preconditionFailure("failed to create native click events")
        }
        window.sendEvent(down)
        window.sendEvent(up)
        pumpRunLoop()
    }

    @MainActor
    private static func mouseEvent(
        type: NSEvent.EventType,
        at point: NSPoint,
        in tile: NSView
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: tile.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: tile.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )
    }

    @MainActor
    private static func pumpRunLoop() {
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
    }
}
