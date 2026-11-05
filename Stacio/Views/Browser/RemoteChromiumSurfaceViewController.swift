import AppKit
import ImageIO

public protocol RemoteChromiumDownloadDelegate: AnyObject {
    func remoteChromiumDidCompleteDownload(_ download: RemoteChromiumDownload)
}

final class RemoteBrowserModeLabel: NSTextField {
    init(text: String, accessibilityIdentifier: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 10, weight: .semibold)
        textColor = .secondaryLabelColor
        alignment = .center
        setAccessibilityIdentifier(accessibilityIdentifier)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: max(22, size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}

final class RemoteBrowserToolbarButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

enum RemoteChromiumZoomCommand: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

private struct RemoteChromiumZoomState {
    static let minimumFactor = 0.5
    static let maximumFactor = 2.0
    static let step = 0.1

    private(set) var factor = 1.0

    mutating func apply(_ command: RemoteChromiumZoomCommand) -> Bool {
        let candidate: Double
        switch command {
        case .zoomIn:
            candidate = factor + Self.step
        case .zoomOut:
            candidate = factor - Self.step
        case .reset:
            candidate = 1
        }
        return update(to: candidate)
    }

    mutating func applyMagnification(_ magnification: CGFloat) -> Bool {
        update(to: factor * (1 + Double(magnification)))
    }

    private mutating func update(to candidate: Double) -> Bool {
        let clamped = min(Self.maximumFactor, max(Self.minimumFactor, candidate))
        let rounded = (clamped * 100).rounded() / 100
        guard rounded != factor else { return false }
        factor = rounded
        return true
    }
}

final class RemoteChromiumFrameMailbox: @unchecked Sendable {
    typealias ImageDecoder = (Data) -> CGImage?
    typealias Delivery = (CGImage, Int, Int) -> Void

    private struct PendingFrame {
        let data: Data
        let width: Int
        let height: Int
        let delivery: Delivery
    }

    private let lock = NSLock()
    private let decodingQueue: DispatchQueue
    private let imageDecoder: ImageDecoder
    private var pendingFrame: PendingFrame?
    private var isDecoding = false

    init(
        decodingQueue: DispatchQueue = DispatchQueue(
            label: "com.stacio.remote-chromium.frame-decode",
            qos: .userInteractive
        ),
        imageDecoder: @escaping ImageDecoder = RemoteChromiumFrameMailbox.decodeImage
    ) {
        self.decodingQueue = decodingQueue
        self.imageDecoder = imageDecoder
    }

    func submit(
        data: Data,
        width: Int,
        height: Int,
        delivery: @escaping Delivery
    ) {
        lock.lock()
        pendingFrame = PendingFrame(
            data: data,
            width: width,
            height: height,
            delivery: delivery
        )
        let shouldStart = isDecoding == false
        if shouldStart {
            isDecoding = true
        }
        lock.unlock()

        if shouldStart {
            decodingQueue.async { [self] in
                decodePendingFrames()
            }
        }
    }

    private func decodePendingFrames() {
        while true {
            lock.lock()
            guard let frame = pendingFrame else {
                isDecoding = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            lock.unlock()

            guard let image = imageDecoder(frame.data) else { continue }
            DispatchQueue.main.async {
                frame.delivery(image, frame.width, frame.height)
            }
        }
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

enum RemoteChromiumInputMapper {
    private struct KeyDefinition {
        let key: String?
        let fallbackKey: String
        let code: String
        let windowsVirtualKeyCode: Int
        let location: Int
        let modifierFlag: NSEvent.ModifierFlags?
        let isKeypad: Bool

        init(
            key: String? = nil,
            fallbackKey: String,
            code: String,
            windowsVirtualKeyCode: Int,
            location: Int = 0,
            modifierFlag: NSEvent.ModifierFlags? = nil,
            isKeypad: Bool = false
        ) {
            self.key = key
            self.fallbackKey = fallbackKey
            self.code = code
            self.windowsVirtualKeyCode = windowsVirtualKeyCode
            self.location = location
            self.modifierFlag = modifierFlag
            self.isKeypad = isKeypad
        }
    }

    static func mouseParameters(
        type: String,
        button: String,
        location: NSPoint,
        canvasBounds: NSRect,
        frameSize: NSSize,
        pageScaleFactor: CGFloat = 1,
        clickCount: Int
    ) -> [String: Any]? {
        guard let imageRect = renderedImageRect(canvasBounds: canvasBounds, frameSize: frameSize),
              imageRect.contains(location)
        else {
            return nil
        }
        let scale = max(0.01, pageScaleFactor)
        let x = (location.x - imageRect.minX) / imageRect.width * frameSize.width / scale
        let y = (imageRect.maxY - location.y) / imageRect.height * frameSize.height / scale
        return [
            "type": type,
            "button": button,
            "x": Double(x),
            "y": Double(y),
            "clickCount": max(0, clickCount)
        ]
    }

    static func renderedImageRect(canvasBounds: NSRect, frameSize: NSSize) -> NSRect? {
        guard canvasBounds.width > 0, canvasBounds.height > 0,
              frameSize.width > 0, frameSize.height > 0
        else {
            return nil
        }
        let scale = min(canvasBounds.width / frameSize.width, canvasBounds.height / frameSize.height)
        let size = NSSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return NSRect(
            x: canvasBounds.midX - size.width / 2,
            y: canvasBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func modifiers(for flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.option) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.command) { value |= 4 }
        if flags.contains(.shift) { value |= 8 }
        return value
    }

    static func keyParameters(
        type: String,
        keyCode: UInt16,
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> [String: Any]? {
        guard let definition = keyDefinitions[keyCode] else { return nil }
        let printableCharacters = characters.flatMap { value -> String? in
            guard value.isEmpty == false,
                  value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false
            else {
                return nil
            }
            return value
        }
        var parameters: [String: Any] = [
            "type": type,
            "key": definition.key ?? printableCharacters ?? definition.fallbackKey,
            "code": definition.code,
            "windowsVirtualKeyCode": definition.windowsVirtualKeyCode,
            "nativeVirtualKeyCode": Int(keyCode),
            "modifiers": modifiers(for: modifierFlags)
        ]
        if definition.location != 0 {
            parameters["location"] = definition.location
        }
        if definition.isKeypad {
            parameters["isKeypad"] = true
        }
        return parameters
    }

    static func modifierKeyParameters(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> [String: Any]? {
        guard let definition = keyDefinitions[keyCode],
              let modifierFlag = definition.modifierFlag
        else {
            return nil
        }
        let type = modifierFlags.contains(modifierFlag) ? "rawKeyDown" : "keyUp"
        return keyParameters(
            type: type,
            keyCode: keyCode,
            characters: nil,
            modifierFlags: modifierFlags
        )
    }

    private static let keyDefinitions: [UInt16: KeyDefinition] = [
        0: .init(fallbackKey: "a", code: "KeyA", windowsVirtualKeyCode: 65),
        1: .init(fallbackKey: "s", code: "KeyS", windowsVirtualKeyCode: 83),
        2: .init(fallbackKey: "d", code: "KeyD", windowsVirtualKeyCode: 68),
        3: .init(fallbackKey: "f", code: "KeyF", windowsVirtualKeyCode: 70),
        4: .init(fallbackKey: "h", code: "KeyH", windowsVirtualKeyCode: 72),
        5: .init(fallbackKey: "g", code: "KeyG", windowsVirtualKeyCode: 71),
        6: .init(fallbackKey: "z", code: "KeyZ", windowsVirtualKeyCode: 90),
        7: .init(fallbackKey: "x", code: "KeyX", windowsVirtualKeyCode: 88),
        8: .init(fallbackKey: "c", code: "KeyC", windowsVirtualKeyCode: 67),
        9: .init(fallbackKey: "v", code: "KeyV", windowsVirtualKeyCode: 86),
        11: .init(fallbackKey: "b", code: "KeyB", windowsVirtualKeyCode: 66),
        12: .init(fallbackKey: "q", code: "KeyQ", windowsVirtualKeyCode: 81),
        13: .init(fallbackKey: "w", code: "KeyW", windowsVirtualKeyCode: 87),
        14: .init(fallbackKey: "e", code: "KeyE", windowsVirtualKeyCode: 69),
        15: .init(fallbackKey: "r", code: "KeyR", windowsVirtualKeyCode: 82),
        16: .init(fallbackKey: "y", code: "KeyY", windowsVirtualKeyCode: 89),
        17: .init(fallbackKey: "t", code: "KeyT", windowsVirtualKeyCode: 84),
        18: .init(fallbackKey: "1", code: "Digit1", windowsVirtualKeyCode: 49),
        19: .init(fallbackKey: "2", code: "Digit2", windowsVirtualKeyCode: 50),
        20: .init(fallbackKey: "3", code: "Digit3", windowsVirtualKeyCode: 51),
        21: .init(fallbackKey: "4", code: "Digit4", windowsVirtualKeyCode: 52),
        22: .init(fallbackKey: "6", code: "Digit6", windowsVirtualKeyCode: 54),
        23: .init(fallbackKey: "5", code: "Digit5", windowsVirtualKeyCode: 53),
        24: .init(fallbackKey: "=", code: "Equal", windowsVirtualKeyCode: 187),
        25: .init(fallbackKey: "9", code: "Digit9", windowsVirtualKeyCode: 57),
        26: .init(fallbackKey: "7", code: "Digit7", windowsVirtualKeyCode: 55),
        27: .init(fallbackKey: "-", code: "Minus", windowsVirtualKeyCode: 189),
        28: .init(fallbackKey: "8", code: "Digit8", windowsVirtualKeyCode: 56),
        29: .init(fallbackKey: "0", code: "Digit0", windowsVirtualKeyCode: 48),
        30: .init(fallbackKey: "]", code: "BracketRight", windowsVirtualKeyCode: 221),
        31: .init(fallbackKey: "o", code: "KeyO", windowsVirtualKeyCode: 79),
        32: .init(fallbackKey: "u", code: "KeyU", windowsVirtualKeyCode: 85),
        33: .init(fallbackKey: "[", code: "BracketLeft", windowsVirtualKeyCode: 219),
        34: .init(fallbackKey: "i", code: "KeyI", windowsVirtualKeyCode: 73),
        35: .init(fallbackKey: "p", code: "KeyP", windowsVirtualKeyCode: 80),
        36: .init(key: "Enter", fallbackKey: "Enter", code: "Enter", windowsVirtualKeyCode: 13),
        37: .init(fallbackKey: "l", code: "KeyL", windowsVirtualKeyCode: 76),
        38: .init(fallbackKey: "j", code: "KeyJ", windowsVirtualKeyCode: 74),
        39: .init(fallbackKey: "'", code: "Quote", windowsVirtualKeyCode: 222),
        40: .init(fallbackKey: "k", code: "KeyK", windowsVirtualKeyCode: 75),
        41: .init(fallbackKey: ";", code: "Semicolon", windowsVirtualKeyCode: 186),
        42: .init(fallbackKey: "\\", code: "Backslash", windowsVirtualKeyCode: 220),
        43: .init(fallbackKey: ",", code: "Comma", windowsVirtualKeyCode: 188),
        44: .init(fallbackKey: "/", code: "Slash", windowsVirtualKeyCode: 191),
        45: .init(fallbackKey: "n", code: "KeyN", windowsVirtualKeyCode: 78),
        46: .init(fallbackKey: "m", code: "KeyM", windowsVirtualKeyCode: 77),
        47: .init(fallbackKey: ".", code: "Period", windowsVirtualKeyCode: 190),
        48: .init(key: "Tab", fallbackKey: "Tab", code: "Tab", windowsVirtualKeyCode: 9),
        49: .init(key: " ", fallbackKey: " ", code: "Space", windowsVirtualKeyCode: 32),
        50: .init(fallbackKey: "`", code: "Backquote", windowsVirtualKeyCode: 192),
        51: .init(key: "Backspace", fallbackKey: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8),
        53: .init(key: "Escape", fallbackKey: "Escape", code: "Escape", windowsVirtualKeyCode: 27),
        54: .init(key: "Meta", fallbackKey: "Meta", code: "MetaRight", windowsVirtualKeyCode: 92, location: 2, modifierFlag: .command),
        55: .init(key: "Meta", fallbackKey: "Meta", code: "MetaLeft", windowsVirtualKeyCode: 91, location: 1, modifierFlag: .command),
        56: .init(key: "Shift", fallbackKey: "Shift", code: "ShiftLeft", windowsVirtualKeyCode: 16, location: 1, modifierFlag: .shift),
        57: .init(key: "CapsLock", fallbackKey: "CapsLock", code: "CapsLock", windowsVirtualKeyCode: 20, modifierFlag: .capsLock),
        58: .init(key: "Alt", fallbackKey: "Alt", code: "AltLeft", windowsVirtualKeyCode: 18, location: 1, modifierFlag: .option),
        59: .init(key: "Control", fallbackKey: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17, location: 1, modifierFlag: .control),
        60: .init(key: "Shift", fallbackKey: "Shift", code: "ShiftRight", windowsVirtualKeyCode: 16, location: 2, modifierFlag: .shift),
        61: .init(key: "Alt", fallbackKey: "Alt", code: "AltRight", windowsVirtualKeyCode: 18, location: 2, modifierFlag: .option),
        62: .init(key: "Control", fallbackKey: "Control", code: "ControlRight", windowsVirtualKeyCode: 17, location: 2, modifierFlag: .control),
        65: .init(fallbackKey: ".", code: "NumpadDecimal", windowsVirtualKeyCode: 110, location: 3, isKeypad: true),
        67: .init(fallbackKey: "*", code: "NumpadMultiply", windowsVirtualKeyCode: 106, location: 3, isKeypad: true),
        69: .init(fallbackKey: "+", code: "NumpadAdd", windowsVirtualKeyCode: 107, location: 3, isKeypad: true),
        75: .init(fallbackKey: "/", code: "NumpadDivide", windowsVirtualKeyCode: 111, location: 3, isKeypad: true),
        76: .init(key: "Enter", fallbackKey: "Enter", code: "NumpadEnter", windowsVirtualKeyCode: 13, location: 3, isKeypad: true),
        78: .init(fallbackKey: "-", code: "NumpadSubtract", windowsVirtualKeyCode: 109, location: 3, isKeypad: true),
        82: .init(fallbackKey: "0", code: "Numpad0", windowsVirtualKeyCode: 96, location: 3, isKeypad: true),
        83: .init(fallbackKey: "1", code: "Numpad1", windowsVirtualKeyCode: 97, location: 3, isKeypad: true),
        84: .init(fallbackKey: "2", code: "Numpad2", windowsVirtualKeyCode: 98, location: 3, isKeypad: true),
        85: .init(fallbackKey: "3", code: "Numpad3", windowsVirtualKeyCode: 99, location: 3, isKeypad: true),
        86: .init(fallbackKey: "4", code: "Numpad4", windowsVirtualKeyCode: 100, location: 3, isKeypad: true),
        87: .init(fallbackKey: "5", code: "Numpad5", windowsVirtualKeyCode: 101, location: 3, isKeypad: true),
        88: .init(fallbackKey: "6", code: "Numpad6", windowsVirtualKeyCode: 102, location: 3, isKeypad: true),
        89: .init(fallbackKey: "7", code: "Numpad7", windowsVirtualKeyCode: 103, location: 3, isKeypad: true),
        91: .init(fallbackKey: "8", code: "Numpad8", windowsVirtualKeyCode: 104, location: 3, isKeypad: true),
        92: .init(fallbackKey: "9", code: "Numpad9", windowsVirtualKeyCode: 105, location: 3, isKeypad: true),
        96: .init(key: "F5", fallbackKey: "F5", code: "F5", windowsVirtualKeyCode: 116),
        97: .init(key: "F6", fallbackKey: "F6", code: "F6", windowsVirtualKeyCode: 117),
        98: .init(key: "F7", fallbackKey: "F7", code: "F7", windowsVirtualKeyCode: 118),
        99: .init(key: "F3", fallbackKey: "F3", code: "F3", windowsVirtualKeyCode: 114),
        100: .init(key: "F8", fallbackKey: "F8", code: "F8", windowsVirtualKeyCode: 119),
        101: .init(key: "F9", fallbackKey: "F9", code: "F9", windowsVirtualKeyCode: 120),
        103: .init(key: "F11", fallbackKey: "F11", code: "F11", windowsVirtualKeyCode: 122),
        109: .init(key: "F10", fallbackKey: "F10", code: "F10", windowsVirtualKeyCode: 121),
        111: .init(key: "F12", fallbackKey: "F12", code: "F12", windowsVirtualKeyCode: 123),
        114: .init(key: "Insert", fallbackKey: "Insert", code: "Insert", windowsVirtualKeyCode: 45),
        115: .init(key: "Home", fallbackKey: "Home", code: "Home", windowsVirtualKeyCode: 36),
        116: .init(key: "PageUp", fallbackKey: "PageUp", code: "PageUp", windowsVirtualKeyCode: 33),
        117: .init(key: "Delete", fallbackKey: "Delete", code: "Delete", windowsVirtualKeyCode: 46),
        118: .init(key: "F4", fallbackKey: "F4", code: "F4", windowsVirtualKeyCode: 115),
        119: .init(key: "End", fallbackKey: "End", code: "End", windowsVirtualKeyCode: 35),
        120: .init(key: "F2", fallbackKey: "F2", code: "F2", windowsVirtualKeyCode: 113),
        121: .init(key: "PageDown", fallbackKey: "PageDown", code: "PageDown", windowsVirtualKeyCode: 34),
        122: .init(key: "F1", fallbackKey: "F1", code: "F1", windowsVirtualKeyCode: 112),
        123: .init(key: "ArrowLeft", fallbackKey: "ArrowLeft", code: "ArrowLeft", windowsVirtualKeyCode: 37),
        124: .init(key: "ArrowRight", fallbackKey: "ArrowRight", code: "ArrowRight", windowsVirtualKeyCode: 39),
        125: .init(key: "ArrowDown", fallbackKey: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40),
        126: .init(key: "ArrowUp", fallbackKey: "ArrowUp", code: "ArrowUp", windowsVirtualKeyCode: 38)
    ]
}

final class RemoteChromiumCanvasView: NSView, NSTextInputClient {
    var onInput: ((String, [String: Any]) -> Void)?
    var onZoomCommand: ((RemoteChromiumZoomCommand) -> Void)?
    var onMagnification: ((CGFloat) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onCopyRequested: (() -> Void)?
    var onPasteRequested: (() -> Void)?
    var pageScaleFactor: CGFloat = 1
    private var frameImage: NSImage?
    private var remoteFrameSize = NSSize(width: 1, height: 1)
    private var trackingAreaReference: NSTrackingArea?
    private var markedTextStorage = ""
    private var markedSelectionRange = NSRange(location: NSNotFound, length: 0)
    private var consumedZoomKeyCodes: Set<UInt16> = []
    private var consumedClipboardKeyCodes: Set<UInt16> = []

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard let frameImage,
              let destination = RemoteChromiumInputMapper.renderedImageRect(
                  canvasBounds: bounds,
                  frameSize: remoteFrameSize
              )
        else {
            return
        }
        frameImage.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    func displayFrame(image: CGImage, width: Int, height: Int) {
        let image = NSImage(cgImage: image, size: .zero)
        frameImage = image
        if width > 0, height > 0 {
            remoteFrameSize = NSSize(width: width, height: height)
        } else {
            remoteFrameSize = NSSize(width: image.size.width, height: image.size.height)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dispatchMouse(type: "mousePressed", button: "left", event: event)
    }

    override func mouseUp(with event: NSEvent) {
        dispatchMouse(type: "mouseReleased", button: "left", event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dispatchMouse(type: "mousePressed", button: "right", event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        dispatchMouse(type: "mouseReleased", button: "right", event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dispatchMouse(type: "mousePressed", button: "middle", event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        dispatchMouse(type: "mouseReleased", button: "middle", event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        dispatchMouse(type: "mouseMoved", button: "none", event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dispatchMouse(type: "mouseMoved", button: "left", event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        dispatchMouse(type: "mouseMoved", button: "right", event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        dispatchMouse(type: "mouseMoved", button: "middle", event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard var parameters = RemoteChromiumInputMapper.mouseParameters(
            type: "mouseWheel",
            button: "none",
            location: location,
            canvasBounds: bounds,
            frameSize: remoteFrameSize,
            pageScaleFactor: pageScaleFactor,
            clickCount: 0
        ) else {
            return
        }
        parameters["deltaX"] = Double(-event.scrollingDeltaX)
        parameters["deltaY"] = Double(-event.scrollingDeltaY)
        parameters["modifiers"] = RemoteChromiumInputMapper.modifiers(for: event.modifierFlags)
        onInput?("Input.dispatchMouseEvent", parameters)
    }

    override func keyDown(with event: NSEvent) {
        if let command = Self.zoomCommand(for: event) {
            consumedZoomKeyCodes.insert(event.keyCode)
            onZoomCommand?(command)
            return
        }
        if event.modifierFlags.contains(.command), event.keyCode == 9 {
            consumedClipboardKeyCodes.insert(event.keyCode)
            onPasteRequested?()
            return
        }
        guard var parameters = RemoteChromiumInputMapper.keyParameters(
            type: "rawKeyDown",
            keyCode: event.keyCode,
            characters: event.characters,
            modifierFlags: event.modifierFlags
        ) else {
            super.keyDown(with: event)
            return
        }
        parameters["autoRepeat"] = event.isARepeat
        onInput?("Input.dispatchKeyEvent", parameters)
        if event.modifierFlags.contains(.command), event.keyCode == 8 {
            DispatchQueue.main.async { [weak self] in self?.onCopyRequested?() }
        }
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            interpretKeyEvents([event])
        }
    }

    override func keyUp(with event: NSEvent) {
        if consumedClipboardKeyCodes.remove(event.keyCode) != nil {
            return
        }
        if consumedZoomKeyCodes.remove(event.keyCode) != nil {
            return
        }
        if Self.zoomCommand(for: event) != nil {
            return
        }
        guard let parameters = RemoteChromiumInputMapper.keyParameters(
            type: "keyUp",
            keyCode: event.keyCode,
            characters: event.characters,
            modifierFlags: event.modifierFlags
        ) else {
            return
        }
        onInput?("Input.dispatchKeyEvent", parameters)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let parameters = RemoteChromiumInputMapper.modifierKeyParameters(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            super.flagsChanged(with: event)
            return
        }
        onInput?("Input.dispatchKeyEvent", parameters)
    }

    override func magnify(with event: NSEvent) {
        onMagnification?(event.magnification)
    }

    private func dispatchMouse(type: String, button: String, event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard var parameters = RemoteChromiumInputMapper.mouseParameters(
            type: type,
            button: button,
            location: location,
            canvasBounds: bounds,
            frameSize: remoteFrameSize,
            pageScaleFactor: pageScaleFactor,
            clickCount: event.clickCount
        ) else {
            return
        }
        parameters["modifiers"] = RemoteChromiumInputMapper.modifiers(for: event.modifierFlags)
        onInput?("Input.dispatchMouseEvent", parameters)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainText(from: string)
        guard text.isEmpty == false else { return }
        markedTextStorage = ""
        markedSelectionRange = NSRange(location: NSNotFound, length: 0)
        onInput?("Input.insertText", ["text": text])
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        let text = Self.plainText(from: string)
        markedTextStorage = text
        markedSelectionRange = selectedRange
        var parameters: [String: Any] = [
            "text": text,
            "selectionStart": max(0, selectedRange.location),
            "selectionEnd": max(0, selectedRange.location + selectedRange.length)
        ]
        if replacementRange.location != NSNotFound {
            parameters["replacementStart"] = replacementRange.location
            parameters["replacementEnd"] = replacementRange.location + replacementRange.length
        }
        onInput?("Input.imeSetComposition", parameters)
    }

    func unmarkText() {
        markedTextStorage = ""
        markedSelectionRange = NSRange(location: NSNotFound, length: 0)
        onInput?(
            "Input.imeSetComposition",
            ["text": "", "selectionStart": 0, "selectionEnd": 0]
        )
    }

    func hasMarkedText() -> Bool {
        markedTextStorage.isEmpty == false
    }

    func markedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (markedTextStorage as NSString).length)
    }

    func selectedRange() -> NSRange {
        markedSelectionRange
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    private static func plainText(from value: Any) -> String {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return String(describing: value)
    }

    private static func zoomCommand(for event: NSEvent) -> RemoteChromiumZoomCommand? {
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty
        else {
            return nil
        }
        switch event.keyCode {
        case 24, 69:
            return .zoomIn
        case 27, 78:
            return .zoomOut
        case 29, 82:
            return .reset
        default:
            return nil
        }
    }
}

private struct RemoteChromiumPageMetadata: Decodable {
    let title: String
    let favicon: String?
}

public final class RemoteChromiumSurfaceViewController: NSViewController {
    public weak var remoteDownloadDelegate: RemoteChromiumDownloadDelegate?
    public var onRuntimeFailure: ((Error) -> Void)?
    public var onNavigationURLChange: ((URL) -> Void)?
    public var onPageTitleChange: ((String) -> Void)?

    private let initialURL: URL
    private let client: ChromeDevToolsControlling
    private let addressField = NSTextField(string: "")
    private let faviconImageView = NSImageView()
    private let statusIndicator = NSProgressIndicator()
    private let backButton = RemoteBrowserToolbarButton()
    private let forwardButton = RemoteBrowserToolbarButton()
    private let canvasView = RemoteChromiumCanvasView()
    private let frameMailbox = RemoteChromiumFrameMailbox()
    private let pasteboard: NSPasteboard
    private let waitingLabel = NSTextField(labelWithString: "正在等待远端 Chromium 画面...")
    private let navigationRetryButton = RemoteBrowserToolbarButton()
    private var currentURL: URL
    private var isClosed = false
    private var cachedViewportSize = NSSize.zero
    private var lastSentViewportSize = NSSize.zero
    private var isClientReady = false
    private var didSendInitialNavigation = false
    private var pendingNavigationURL: URL?
    private var zoomState = RemoteChromiumZoomState()
    private var windowFocusObservers: [NSObjectProtocol] = []

    var pageScaleFactor: Double { zoomState.factor }

    public init(
        initialURL: URL,
        client: ChromeDevToolsControlling,
        pasteboard: NSPasteboard = .general
    ) {
        self.initialURL = initialURL
        self.currentURL = initialURL
        self.pendingNavigationURL = initialURL
        self.client = client
        self.pasteboard = pasteboard
        super.init(nibName: nil, bundle: nil)
        title = L10n.Inspector.browser
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = StacioAppearanceRefreshView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        let toolbarContainer = NSView()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.setAccessibilityIdentifier("Stacio.RemoteBrowser.toolbar")

        let navigationRow = NSStackView()
        navigationRow.orientation = .horizontal
        navigationRow.alignment = .centerY
        navigationRow.spacing = 6
        navigationRow.translatesAutoresizingMaskIntoConstraints = false

        configureToolbarButton(
            backButton,
            symbolName: "chevron.left",
            toolTip: "后退",
            action: #selector(goBack)
        )
        backButton.isEnabled = false
        configureToolbarButton(
            forwardButton,
            symbolName: "chevron.right",
            toolTip: "前进",
            action: #selector(goForward)
        )
        forwardButton.isEnabled = false
        let reloadButton = RemoteBrowserToolbarButton()
        configureToolbarButton(
            reloadButton,
            symbolName: "arrow.clockwise",
            toolTip: "重新载入",
            action: #selector(reload)
        )

        addressField.stringValue = initialURL.absoluteString
        addressField.placeholderString = L10n.Browser.address
        addressField.target = self
        addressField.action = #selector(submitAddress)
        addressField.cell?.usesSingleLineMode = true
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.setAccessibilityIdentifier("Stacio.RemoteBrowser.address")
        addressField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleCompactTextField(addressField)

        faviconImageView.image = Self.fallbackFavicon
        faviconImageView.imageScaling = .scaleProportionallyDown
        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.setAccessibilityIdentifier("Stacio.RemoteBrowser.favicon")

        statusIndicator.style = .spinning
        statusIndicator.controlSize = .small
        statusIndicator.isDisplayedWhenStopped = false
        statusIndicator.setAccessibilityIdentifier("Stacio.RemoteBrowser.statusIndicator")
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false

        let goButton = RemoteBrowserToolbarButton()
        configureToolbarButton(
            goButton,
            symbolName: "arrow.right.circle",
            toolTip: L10n.Browser.go,
            action: #selector(submitAddress)
        )

        let modeLabel = RemoteBrowserModeLabel(
            text: "远端 Chromium",
            accessibilityIdentifier: "Stacio.RemoteBrowser.mode"
        )

        navigationRow.addArrangedSubview(backButton)
        navigationRow.addArrangedSubview(forwardButton)
        navigationRow.addArrangedSubview(reloadButton)
        navigationRow.addArrangedSubview(faviconImageView)
        navigationRow.addArrangedSubview(addressField)
        navigationRow.addArrangedSubview(statusIndicator)
        navigationRow.addArrangedSubview(goButton)
        navigationRow.addArrangedSubview(modeLabel)
        [backButton, forwardButton, reloadButton, faviconImageView, statusIndicator, goButton, modeLabel].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.setAccessibilityIdentifier("Stacio.RemoteBrowser.surface")
        canvasView.onInput = { [weak self] method, parameters in
            self?.client.send(method: method, parameters: parameters)
        }
        canvasView.onZoomCommand = { [weak self] command in
            self?.performZoom(command)
        }
        canvasView.onMagnification = { [weak self] magnification in
            self?.applyMagnification(magnification)
        }
        canvasView.onFocusChange = { [weak self] focused in
            self?.setPageFocus(focused)
        }
        canvasView.onPasteRequested = { [weak self] in
            self?.pasteLocalClipboard()
        }
        canvasView.onCopyRequested = { [weak self] in
            self?.copyRemoteSelection()
        }

        waitingLabel.textColor = .secondaryLabelColor
        waitingLabel.alignment = .center
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        waitingLabel.setAccessibilityIdentifier("Stacio.RemoteBrowser.waiting")
        configureToolbarButton(
            navigationRetryButton,
            symbolName: "arrow.clockwise",
            toolTip: "重新载入",
            action: #selector(reload)
        )
        navigationRetryButton.isHidden = true
        navigationRetryButton.setAccessibilityIdentifier("Stacio.RemoteBrowser.retry")

        toolbarContainer.addSubview(navigationRow)
        container.addSubview(toolbarContainer)
        container.addSubview(separator)
        container.addSubview(canvasView)
        container.addSubview(waitingLabel)
        container.addSubview(navigationRetryButton)
        let addressMinimumWidth = addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        addressMinimumWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            toolbarContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            toolbarContainer.heightAnchor.constraint(equalToConstant: 36),
            navigationRow.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 8),
            navigationRow.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -8),
            navigationRow.topAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: -2),
            navigationRow.heightAnchor.constraint(equalToConstant: 28),
            addressMinimumWidth,
            addressField.heightAnchor.constraint(equalToConstant: 28),
            faviconImageView.widthAnchor.constraint(equalToConstant: 18),
            faviconImageView.heightAnchor.constraint(equalToConstant: 18),
            modeLabel.heightAnchor.constraint(equalToConstant: 22),
            statusIndicator.widthAnchor.constraint(equalToConstant: 14),
            statusIndicator.heightAnchor.constraint(equalToConstant: 14),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            canvasView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            waitingLabel.centerXAnchor.constraint(equalTo: canvasView.centerXAnchor),
            waitingLabel.centerYAnchor.constraint(equalTo: canvasView.centerYAnchor, constant: -18),
            waitingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: canvasView.leadingAnchor, constant: 16),
            waitingLabel.trailingAnchor.constraint(lessThanOrEqualTo: canvasView.trailingAnchor, constant: -16),
            navigationRetryButton.centerXAnchor.constraint(equalTo: canvasView.centerXAnchor),
            navigationRetryButton.topAnchor.constraint(equalTo: waitingLabel.bottomAnchor, constant: 10)
        ])

        view = container
        configureClientCallbacks()
        statusIndicator.startAnimation(nil)
        client.connect()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let size = canvasView.bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        cachedViewportSize = size
        sendViewportAndInitialNavigationIfReady()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        beginObservingWindowFocus()
        setPageFocus(view.window?.isKeyWindow == true)
    }

    public override func viewWillDisappear() {
        setPageFocus(false)
        endObservingWindowFocus()
        super.viewWillDisappear()
    }

    private func sendViewportAndInitialNavigationIfReady() {
        guard isClientReady,
              cachedViewportSize.width >= 1,
              cachedViewportSize.height >= 1
        else {
            return
        }
        if cachedViewportSize != lastSentViewportSize {
            lastSentViewportSize = cachedViewportSize
            client.send(
                method: "Emulation.setDeviceMetricsOverride",
                parameters: [
                    "width": max(1, Int(cachedViewportSize.width.rounded(.down))),
                    "height": max(1, Int(cachedViewportSize.height.rounded(.down))),
                    "deviceScaleFactor": 1,
                    "mobile": false
                ]
            )
        }
        guard didSendInitialNavigation == false else { return }
        didSendInitialNavigation = true
        if zoomState.factor != 1 {
            sendPageScaleFactor()
        }
        let navigationURL = pendingNavigationURL ?? initialURL
        pendingNavigationURL = nil
        navigate(to: navigationURL)
    }

    func performZoom(_ command: RemoteChromiumZoomCommand) {
        guard isClosed == false, zoomState.apply(command) else { return }
        canvasView.pageScaleFactor = CGFloat(zoomState.factor)
        if isClientReady {
            sendPageScaleFactor()
        }
    }

    private func applyMagnification(_ magnification: CGFloat) {
        guard isClosed == false, zoomState.applyMagnification(magnification) else { return }
        canvasView.pageScaleFactor = CGFloat(zoomState.factor)
        if isClientReady {
            sendPageScaleFactor()
        }
    }

    private func sendPageScaleFactor() {
        client.send(
            method: "Emulation.setPageScaleFactor",
            parameters: ["pageScaleFactor": zoomState.factor]
        )
    }

    public func closeRemoteChromiumSurface() {
        guard isClosed == false else { return }
        isClosed = true
        client.onEvent = nil
        client.onFailure = nil
        endObservingWindowFocus()
        client.disconnect()
        pendingNavigationURL = nil
        onRuntimeFailure = nil
        onNavigationURLChange = nil
        onPageTitleChange = nil
    }

    public func navigate(toAddress value: String) {
        guard isClosed == false else { return }
        guard let url = BrowserURLNormalizer.normalizedURL(value) else {
            addressField.stringValue = currentURL.absoluteString
            NSSound.beep()
            return
        }
        navigate(to: url)
    }

    private func configureClientCallbacks() {
        client.onEvent = { [weak self] event in
            self?.handle(event)
        }
        client.onFailure = { [weak self] error in
            guard let self, self.isClosed == false else { return }
            self.onRuntimeFailure?(error)
        }
    }

    private func handle(_ event: ChromeDevToolsEvent) {
        guard isClosed == false else { return }
        switch event {
        case .connected:
            isClientReady = true
            sendViewportAndInitialNavigationIfReady()
        case let .screencastFrame(data, _, width, height):
            frameMailbox.submit(data: data, width: width, height: height) { [weak self] image, width, height in
                guard let self, self.isClosed == false else { return }
                self.canvasView.displayFrame(image: image, width: width, height: height)
                self.waitingLabel.isHidden = true
                self.navigationRetryButton.isHidden = true
            }
        case let .loading(isLoading):
            if isLoading {
                statusIndicator.startAnimation(nil)
            } else {
                statusIndicator.stopAnimation(nil)
                refreshPageMetadata()
            }
        case let .navigationFailed(errorText):
            statusIndicator.stopAnimation(nil)
            waitingLabel.stringValue = "载入失败：\(errorText)；点击重新载入"
            waitingLabel.isHidden = false
            navigationRetryButton.isHidden = false
        case let .frameNavigated(rawURL):
            if let url = BrowserURLNormalizer.normalizedURL(rawURL) {
                currentURL = url
                addressField.stringValue = url.absoluteString
                onNavigationURLChange?(url)
            }
        case let .navigationState(canGoBack, canGoForward):
            backButton.isEnabled = canGoBack
            forwardButton.isEnabled = canGoForward
        case let .downloadCompleted(download):
            remoteDownloadDelegate?.remoteChromiumDidCompleteDownload(download)
        case .downloadWillBegin, .downloadProgress, .ignored:
            break
        }
    }

    var faviconImageForTesting: NSImage? { faviconImageView.image }

    func setPageFocusForTesting(_ focused: Bool) {
        setPageFocus(focused)
    }

    func pasteLocalClipboardForTesting() {
        pasteLocalClipboard()
    }

    func copyRemoteSelectionForTesting() {
        copyRemoteSelection()
    }

    private func setPageFocus(_ focused: Bool) {
        guard isClosed == false, isClientReady else { return }
        client.send(
            method: "Emulation.setFocusEmulationEnabled",
            parameters: ["enabled": focused]
        )
    }

    private func beginObservingWindowFocus() {
        endObservingWindowFocus()
        guard let observedWindow = view.window else { return }
        let center = NotificationCenter.default
        windowFocusObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: observedWindow,
                queue: .main
            ) { [weak self] _ in
                self?.setPageFocus(true)
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: observedWindow,
                queue: .main
            ) { [weak self] _ in
                self?.setPageFocus(false)
            }
        ]
    }

    private func endObservingWindowFocus() {
        let center = NotificationCenter.default
        windowFocusObservers.forEach(center.removeObserver)
        windowFocusObservers.removeAll()
    }

    private func pasteLocalClipboard() {
        guard isClosed == false,
              isClientReady,
              let text = pasteboard.string(forType: .string)
        else { return }
        client.send(method: "Input.insertText", parameters: ["text": text])
    }

    private func copyRemoteSelection() {
        guard isClosed == false, isClientReady else { return }
        let expression = """
        (() => {
          const activeElement = document.activeElement;
          if (activeElement && activeElement.tagName === 'INPUT' && activeElement.type === 'password') return null;
          if (activeElement && typeof activeElement.selectionStart === 'number' && typeof activeElement.value === 'string') {
            return activeElement.value.slice(activeElement.selectionStart, activeElement.selectionEnd);
          }
          return window.getSelection ? window.getSelection().toString() : '';
        })()
        """
        client.evaluateString(expression) { [weak self] result in
            guard let self,
                  self.isClosed == false,
                  case let .success(value) = result,
                  let value
            else { return }
            self.pasteboard.clearContents()
            self.pasteboard.setString(value, forType: .string)
        }
    }

    private func refreshPageMetadata() {
        guard isClientReady else { return }
        let expression = """
        (async () => {
          const title = document.title || '';
          const icon = document.querySelector('link[rel~="icon"]');
          let favicon = icon && icon.href ? icon.href : null;
          if (favicon && !favicon.startsWith('data:')) {
            try {
              const response = await fetch(favicon);
              const blob = await response.blob();
              favicon = await new Promise((resolve) => {
                const reader = new FileReader();
                reader.onloadend = () => resolve(reader.result);
                reader.onerror = () => resolve(null);
                reader.readAsDataURL(blob);
              });
            } catch (_) { favicon = null; }
          }
          return JSON.stringify({ title, favicon });
        })()
        """
        client.evaluateString(expression) { [weak self] result in
            guard let self,
                  self.isClosed == false,
                  case let .success(value) = result,
                  let value,
                  let data = value.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(RemoteChromiumPageMetadata.self, from: data)
            else { return }
            let pageTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = pageTitle.isEmpty ? L10n.Inspector.browser : pageTitle
            self.title = resolvedTitle
            self.onPageTitleChange?(resolvedTitle)
            self.faviconImageView.image = metadata.favicon
                .flatMap(Self.imageFromDataURL) ?? Self.fallbackFavicon
        }
    }

    private static var fallbackFavicon: NSImage? {
        NSImage(systemSymbolName: "globe", accessibilityDescription: "网页图标")
    }

    private static func imageFromDataURL(_ value: String) -> NSImage? {
        guard value.hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ","),
              value[..<comma].contains(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }

    private func navigate(to url: URL) {
        currentURL = url
        addressField.stringValue = url.absoluteString
        onNavigationURLChange?(url)
        statusIndicator.startAnimation(nil)
        waitingLabel.isHidden = true
        navigationRetryButton.isHidden = true
        guard isClientReady else {
            pendingNavigationURL = url
            return
        }
        client.send(method: "Page.navigate", parameters: ["url": url.absoluteString])
    }

    @objc private func submitAddress() {
        navigate(toAddress: addressField.stringValue)
    }

    @objc private func reload() {
        statusIndicator.startAnimation(nil)
        waitingLabel.isHidden = true
        navigationRetryButton.isHidden = true
        guard isClientReady else {
            pendingNavigationURL = currentURL
            return
        }
        client.send(method: "Page.reload", parameters: ["ignoreCache": false])
    }

    @objc private func goBack() {
        guard isClientReady else { return }
        statusIndicator.startAnimation(nil)
        client.send(method: "Runtime.evaluate", parameters: ["expression": "history.back()"])
    }

    @objc private func goForward() {
        guard isClientReady else { return }
        statusIndicator.startAnimation(nil)
        client.send(method: "Runtime.evaluate", parameters: ["expression": "history.forward()"])
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbolName: String,
        toolTip: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.target = self
        button.action = action
        button.bezelStyle = .texturedRounded
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }
}
