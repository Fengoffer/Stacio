import AppKit

final class GraphicsRenderSurfaceView: NSView {
    private static let minimumProductionRemoteFrameDimension = 200

    var inputHandler: ((GraphicsInputEvent) -> Void)? {
        didSet {
            cancelPendingResizeDelivery()
            lastSentResize = nil
            suppressedInitialResize = nil
            isAwaitingFrameForLastSentResize = false
            didSendInitialResizeBeforeFirstFrame = false
            shouldKeepProductionFirstFrameStable = false
            sendResizeEventIfNeeded()
        }
    }
    var pasteboardStringProvider: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }
    private(set) var renderedFrameSizeForTesting: CGSize?
    private(set) var remotePointerPositionForTesting: CGPoint?
    private(set) var remotePointerBitmapSizeForTesting: CGSize?
    private(set) var remotePointerAnchorPointForTesting: CGPoint?
    var isRemotePointerVisibleForTesting: Bool {
        remotePointerLayer.superlayer != nil && remotePointerLayer.isHidden == false
    }
    var hasRenderedImageForTesting: Bool {
        layer?.contents != nil
    }

    private var latestFrameSize: CGSize?
    private var latestMousePosition = CGPoint.zero
    private var isRemotePointerVisible = true
    private var suppressedKeyUpKeyCodes = Set<UInt16>()
    private var activeModifierScancodes = Set<ModifierScancode>()
    private var lastSentResize: ResizeSignature?
    private var pendingResize: ResizeSignature?
    private var suppressedInitialResize: ResizeSignature?
    private var resizeDeliveryWorkItem: DispatchWorkItem?
    private var isAwaitingFrameForLastSentResize = false
    private var didSendInitialResizeBeforeFirstFrame = false
    private var shouldKeepProductionFirstFrameStable = false
    private let remotePointerLayer = CAShapeLayer()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            releaseActiveModifiers()
            suppressedKeyUpKeyCodes.removeAll()
        }
        return didResign
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        updateBackingScaleForRendering()
        configureRemotePointerLayer()
        setAccessibilityIdentifier("Stacio.Graphics.renderSurface")
        setAccessibilityRole(.image)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func display(_ frame: GraphicsFrame) {
        guard let image = makeImage(from: frame) else { return }
        let isFirstFrame = latestFrameSize == nil
        latestFrameSize = CGSize(width: frame.width, height: frame.height)
        renderedFrameSizeForTesting = latestFrameSize
        if isFirstFrame,
           didSendInitialResizeBeforeFirstFrame,
           Self.isProductionRemoteFrame(width: frame.width, height: frame.height) {
            shouldKeepProductionFirstFrameStable = true
            cancelPendingResizeDelivery()
        }
        if let lastSentResize,
           frame.width == lastSentResize.width,
           frame.height == lastSentResize.height {
            isAwaitingFrameForLastSentResize = false
        }
        layer?.contents = image
        needsDisplay = true
        sendResizeEventIfNeeded()
    }

    func sendInputForTesting(_ event: GraphicsInputEvent) {
        inputHandler?(event)
    }

    func simulateFileDropForTesting(paths: [String], at point: NSPoint) {
        latestMousePosition = point
        sendFileDrop(paths: paths, point: point)
    }

    func updateRemotePointerPosition(x: Int, y: Int) {
        let localPoint = localPoint(remoteX: x, remoteY: y)
        remotePointerPositionForTesting = localPoint
        if remotePointerLayer.superlayer == nil {
            layer?.addSublayer(remotePointerLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remotePointerLayer.position = localPoint
        remotePointerLayer.isHidden = !isRemotePointerVisible
        CATransaction.commit()
        setNeedsDisplay(bounds)
    }

    func setRemotePointerVisible(_ isVisible: Bool) {
        isRemotePointerVisible = isVisible
        if isVisible {
            configureRemotePointerLayer()
            remotePointerBitmapSizeForTesting = nil
            remotePointerAnchorPointForTesting = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remotePointerLayer.isHidden = !isVisible
        CATransaction.commit()
        setNeedsDisplay(bounds)
    }

    func setRemotePointerBitmap(_ bitmap: GraphicsPointerBitmap) {
        guard bitmap.width > 0,
              bitmap.height > 0,
              bitmap.hotspotX >= 0,
              bitmap.hotspotY >= 0,
              bitmap.hotspotX < bitmap.width,
              bitmap.hotspotY < bitmap.height,
              bitmap.rgbaPixels.count == bitmap.width * bitmap.height * 4,
              let image = makePointerImage(from: bitmap)
        else {
            return
        }
        remotePointerBitmapSizeForTesting = CGSize(width: bitmap.width, height: bitmap.height)
        remotePointerAnchorPointForTesting = CGPoint(
            x: CGFloat(bitmap.hotspotX) / CGFloat(bitmap.width),
            y: CGFloat(bitmap.hotspotY) / CGFloat(bitmap.height)
        )
        if remotePointerLayer.superlayer == nil {
            layer?.addSublayer(remotePointerLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remotePointerLayer.path = nil
        remotePointerLayer.contents = image
        remotePointerLayer.bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        remotePointerLayer.anchorPoint = remotePointerAnchorPointForTesting ?? .zero
        remotePointerLayer.fillColor = nil
        remotePointerLayer.strokeColor = nil
        remotePointerLayer.shadowOpacity = 0
        remotePointerLayer.isHidden = false
        CATransaction.commit()
        isRemotePointerVisible = true
        setNeedsDisplay(bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sendResizeEventIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScaleForRendering()
        window?.makeFirstResponder(self)
        sendResizeEventIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScaleForRendering()
        sendResizeEventIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        sendMouseMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouseMove(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouseMove(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMouseMove(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(.left, isPressed: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(.left, isPressed: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(.right, isPressed: true, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(.right, isPressed: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(mouseButton(for: event), isPressed: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(mouseButton(for: event), isPressed: false, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = remotePoint(for: event)
        inputHandler?(
            .scroll(
                deltaX: Int(event.scrollingDeltaX.rounded()),
                deltaY: Int(event.scrollingDeltaY.rounded()),
                x: point.x,
                y: point.y
            )
        )
    }

    override func keyDown(with event: NSEvent) {
        if isPasteShortcut(event) {
            guard suppressedKeyUpKeyCodes.insert(event.keyCode).inserted else {
                return
            }
            if let text = pasteboardStringProvider(),
               text.isEmpty == false {
                inputHandler?(.clipboardTextPaste(text))
            }
            return
        }
        sendKey(event, isPressed: true)
    }

    override func keyUp(with event: NSEvent) {
        if suppressedKeyUpKeyCodes.remove(event.keyCode) != nil {
            return
        }
        sendKey(event, isPressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let modifier = Self.modifierScancode(forMacKeyCode: event.keyCode) else { return }
        let scancode = ModifierScancode(scancode: modifier.scancode, isExtended: modifier.isExtended)
        let isPressed = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(modifier.flag)
        if isPressed {
            guard activeModifierScancodes.insert(scancode).inserted else { return }
            inputHandler?(.key(scancode: scancode.scancode, isExtended: scancode.isExtended, isPressed: true))
        } else if activeModifierScancodes.remove(scancode) != nil {
            inputHandler?(.key(scancode: scancode.scancode, isExtended: scancode.isExtended, isPressed: false))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFilePaths(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = draggedFilePaths(from: sender)
        guard paths.isEmpty == false else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        sendFileDrop(paths: paths, point: point)
        return true
    }

    private func makeImage(from frame: GraphicsFrame) -> CGImage? {
        guard frame.pixelFormat == .bgra8Unorm,
              frame.width > 0,
              frame.height > 0,
              frame.bytesPerRow > 0,
              let provider = CGDataProvider(data: frame.pixels as CFData)
        else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func makePointerImage(from bitmap: GraphicsPointerBitmap) -> CGImage? {
        guard let provider = CGDataProvider(data: bitmap.rgbaPixels as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func configureRemotePointerLayer() {
        updateBackingScaleForRendering()
        remotePointerLayer.bounds = CGRect(x: 0, y: 0, width: 12, height: 18)
        remotePointerLayer.anchorPoint = CGPoint(x: 0, y: 0)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 16))
        path.addLine(to: CGPoint(x: 4, y: 12))
        path.addLine(to: CGPoint(x: 7, y: 18))
        path.addLine(to: CGPoint(x: 9, y: 17))
        path.addLine(to: CGPoint(x: 6, y: 11))
        path.addLine(to: CGPoint(x: 12, y: 11))
        path.closeSubpath()
        remotePointerLayer.path = path
        remotePointerLayer.fillColor = NSColor.white.cgColor
        remotePointerLayer.strokeColor = NSColor.black.withAlphaComponent(0.85).cgColor
        remotePointerLayer.lineWidth = 1
        remotePointerLayer.shadowColor = NSColor.black.cgColor
        remotePointerLayer.shadowOpacity = 0.45
        remotePointerLayer.shadowRadius = 1
        remotePointerLayer.shadowOffset = CGSize(width: 0, height: 1)
        remotePointerLayer.isHidden = true
    }

    private func sendResizeEventIfNeeded() {
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        guard let inputHandler else { return }
        let scale = backingScaleForRendering()
        let resize = ResizeSignature(
            width: Int((bounds.width * scale).rounded()),
            height: Int((bounds.height * scale).rounded()),
            scalePercent: Int((scale * 100).rounded())
        )
        guard latestFrameSize != nil else {
            guard resize != lastSentResize else {
                cancelPendingResizeDelivery()
                return
            }
            if lastSentResize == nil {
                deliverResize(resize, inputHandler: inputHandler)
            } else {
                pendingResize = resize
                schedulePendingResizeDelivery()
            }
            return
        }
        if lastSentResize == nil,
           latestFrameSize.map({
               Int($0.width.rounded()) == resize.width && Int($0.height.rounded()) == resize.height
           }) == true {
            suppressedInitialResize = nil
            return
        }
        if let suppressedInitialResize {
            if suppressedInitialResize == resize {
                return
            }
            self.suppressedInitialResize = nil
        }
        if lastSentResize == nil,
           shouldSuppressInitialProductionResize(resize) {
            suppressedInitialResize = resize
            return
        }
        if shouldKeepProductionFirstFrameStable,
           shouldSuppressInitialProductionResize(resize) {
            cancelPendingResizeDelivery()
            return
        }
        guard resize != lastSentResize else {
            cancelPendingResizeDelivery()
            return
        }
        guard lastSentResize != nil else {
            deliverResize(resize, inputHandler: inputHandler)
            return
        }
        pendingResize = resize
        schedulePendingResizeDelivery()
    }

    private func schedulePendingResizeDelivery() {
        resizeDeliveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.deliverPendingResize()
        }
        resizeDeliveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func cancelPendingResizeDelivery() {
        pendingResize = nil
        resizeDeliveryWorkItem?.cancel()
        resizeDeliveryWorkItem = nil
    }

    private func deliverPendingResize() {
        guard let resize = pendingResize,
              let inputHandler
        else {
            return
        }
        pendingResize = nil
        resizeDeliveryWorkItem = nil
        guard resize != lastSentResize else { return }
        deliverResize(resize, inputHandler: inputHandler)
    }

    private func deliverResize(_ resize: ResizeSignature, inputHandler: (GraphicsInputEvent) -> Void) {
        if latestFrameSize == nil {
            didSendInitialResizeBeforeFirstFrame = true
        }
        suppressedInitialResize = nil
        isAwaitingFrameForLastSentResize = latestFrameSize.map {
            Int($0.width.rounded()) != resize.width || Int($0.height.rounded()) != resize.height
        } ?? false
        lastSentResize = resize
        inputHandler(
            .resize(
                width: resize.width,
                height: resize.height,
                scaleFactor: Double(resize.scalePercent) / 100.0
            )
        )
    }

    private func shouldSuppressInitialProductionResize(_ resize: ResizeSignature) -> Bool {
        guard let latestFrameSize else { return false }
        let remoteWidth = Int(latestFrameSize.width.rounded())
        let remoteHeight = Int(latestFrameSize.height.rounded())
        guard Self.isProductionRemoteFrame(width: remoteWidth, height: remoteHeight) else {
            return false
        }
        return remoteWidth != resize.width || remoteHeight != resize.height
    }

    private static func isProductionRemoteFrame(width: Int, height: Int) -> Bool {
        width >= minimumProductionRemoteFrameDimension
            && height >= minimumProductionRemoteFrameDimension
    }

    private func updateBackingScaleForRendering() {
        let scale = backingScaleForRendering()
        layer?.contentsScale = scale
        remotePointerLayer.contentsScale = scale
    }

    private func backingScaleForRendering() -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func sendMouseMove(_ event: NSEvent) {
        let point = remotePoint(for: event)
        inputHandler?(.mouseMoved(x: point.x, y: point.y))
    }

    private func sendMouseButton(_ button: GraphicsMouseButton, isPressed: Bool, event: NSEvent) {
        let point = remotePoint(for: event)
        inputHandler?(.mouseButton(button: button, isPressed: isPressed, x: point.x, y: point.y))
    }

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int) {
        let point = convert(event.locationInWindow, from: nil)
        latestMousePosition = point
        let frameSize = remoteFrameSizeForCoordinateMapping()
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let x = Int((point.x / width * frameSize.width).rounded())
        let y = Int((point.y / height * frameSize.height).rounded())
        return (
            x: max(0, min(max(0, Int(frameSize.width) - 1), x)),
            y: max(0, min(max(0, Int(frameSize.height) - 1), y))
        )
    }

    private func localPoint(remoteX: Int, remoteY: Int) -> CGPoint {
        let frameSize = remoteFrameSizeForPointerMapping()
        let frameWidth = max(1, frameSize.width)
        let frameHeight = max(1, frameSize.height)
        let x = CGFloat(remoteX) / frameWidth * max(1, bounds.width)
        let y = CGFloat(remoteY) / frameHeight * max(1, bounds.height)
        return CGPoint(
            x: max(0, min(bounds.width, x)),
            y: max(0, min(bounds.height, y))
        )
    }

    private func mouseButton(for event: NSEvent) -> GraphicsMouseButton {
        switch event.buttonNumber {
        case 2:
            return .middle
        case 3:
            return .x1
        case 4:
            return .x2
        default:
            return .middle
        }
    }

    private func sendKey(_ event: NSEvent, isPressed: Bool) {
        guard let mapping = Self.pcScancode(forMacKeyCode: event.keyCode) else { return }
        inputHandler?(.key(scancode: mapping.scancode, isExtended: mapping.isExtended, isPressed: isPressed))
    }

    private func releaseActiveModifiers() {
        let modifiers = activeModifierScancodes.sorted {
            ($0.scancode, $0.isExtended ? 1 : 0) < ($1.scancode, $1.isExtended ? 1 : 0)
        }
        activeModifierScancodes.removeAll()
        for modifier in modifiers {
            inputHandler?(.key(scancode: modifier.scancode, isExtended: modifier.isExtended, isPressed: false))
        }
    }

    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == 9 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    private func sendFileDrop(paths: [String], point: NSPoint) {
        guard paths.isEmpty == false else { return }
        let frameSize = remoteFrameSizeForCoordinateMapping()
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let x = Int((point.x / width * frameSize.width).rounded())
        let y = Int((point.y / height * frameSize.height).rounded())
        inputHandler?(
            .fileDrop(
                paths: paths,
                x: max(0, min(max(0, Int(frameSize.width) - 1), x)),
                y: max(0, min(max(0, Int(frameSize.height) - 1), y))
            )
        )
    }

    private func remoteFrameSizeForCoordinateMapping() -> CGSize {
        if isAwaitingFrameForLastSentResize,
           let lastSentResize {
            return CGSize(width: lastSentResize.width, height: lastSentResize.height)
        }
        if let latestFrameSize {
            return latestFrameSize
        }
        if let lastSentResize {
            return CGSize(width: lastSentResize.width, height: lastSentResize.height)
        }
        return CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
    }

    private func remoteFrameSizeForPointerMapping() -> CGSize {
        if let latestFrameSize {
            return latestFrameSize
        }
        if let lastSentResize {
            return CGSize(width: lastSentResize.width, height: lastSentResize.height)
        }
        return CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
    }

    private func draggedFilePaths(from sender: NSDraggingInfo) -> [String] {
        Self.fileDropPaths(from: sender.draggingPasteboard)
    }

    static func fileDropPaths(from pasteboard: NSPasteboard) -> [String] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])?
            .compactMap { ($0 as? URL)?.path } ?? []
    }

    private static func pcScancode(forMacKeyCode keyCode: UInt16) -> (scancode: UInt16, isExtended: Bool)? {
        switch keyCode {
        case 0: return (0x1E, false) // A
        case 1: return (0x1F, false) // S
        case 2: return (0x20, false) // D
        case 3: return (0x21, false) // F
        case 4: return (0x23, false) // H
        case 5: return (0x22, false) // G
        case 6: return (0x2C, false) // Z
        case 7: return (0x2D, false) // X
        case 8: return (0x2E, false) // C
        case 9: return (0x2F, false) // V
        case 11: return (0x30, false) // B
        case 12: return (0x10, false) // Q
        case 13: return (0x11, false) // W
        case 14: return (0x12, false) // E
        case 15: return (0x13, false) // R
        case 16: return (0x15, false) // Y
        case 17: return (0x14, false) // T
        case 18: return (0x02, false) // 1
        case 19: return (0x03, false) // 2
        case 20: return (0x04, false) // 3
        case 21: return (0x05, false) // 4
        case 22: return (0x07, false) // 6
        case 23: return (0x06, false) // 5
        case 24: return (0x0D, false) // =
        case 25: return (0x09, false) // 9
        case 26: return (0x08, false) // 7
        case 27: return (0x0C, false) // -
        case 28: return (0x0A, false) // 8
        case 29: return (0x0B, false) // 0
        case 30: return (0x1B, false) // ]
        case 31: return (0x18, false) // O
        case 32: return (0x16, false) // U
        case 33: return (0x1A, false) // [
        case 34: return (0x17, false) // I
        case 35: return (0x19, false) // P
        case 36: return (0x1C, false) // Return
        case 37: return (0x26, false) // L
        case 38: return (0x24, false) // J
        case 39: return (0x28, false) // '
        case 40: return (0x25, false) // K
        case 41: return (0x27, false) // ;
        case 42: return (0x2B, false) // \
        case 43: return (0x33, false) // ,
        case 44: return (0x35, false) // /
        case 45: return (0x31, false) // N
        case 46: return (0x32, false) // M
        case 47: return (0x34, false) // .
        case 48: return (0x0F, false) // Tab
        case 49: return (0x39, false) // Space
        case 50: return (0x29, false) // `
        case 51: return (0x0E, false) // Backspace
        case 53: return (0x01, false) // Escape
        case 55: return (0x5B, true) // Command as Windows key
        case 56, 60: return (0x2A, false) // Shift
        case 58, 61: return (0x38, false) // Option as Alt
        case 59, 62: return (0x1D, false) // Control
        case 63: return (0x5C, true) // Function as Windows Menu fallback
        case 65: return (0x53, false) // Numpad .
        case 67: return (0x37, false) // Numpad *
        case 69: return (0x4E, false) // Numpad +
        case 71: return (0x45, false) // Num Lock
        case 75: return (0x35, true) // Numpad /
        case 76: return (0x1C, true) // Numpad Enter
        case 78: return (0x4A, false) // Numpad -
        case 81: return (0x4E, false) // Numpad =
        case 82: return (0x52, false) // Numpad 0
        case 83: return (0x4F, false) // Numpad 1
        case 84: return (0x50, false) // Numpad 2
        case 85: return (0x51, false) // Numpad 3
        case 86: return (0x4B, false) // Numpad 4
        case 87: return (0x4C, false) // Numpad 5
        case 88: return (0x4D, false) // Numpad 6
        case 89: return (0x47, false) // Numpad 7
        case 91: return (0x48, false) // Numpad 8
        case 92: return (0x49, false) // Numpad 9
        case 96: return (0x3F, false) // F5
        case 97: return (0x40, false) // F6
        case 98: return (0x41, false) // F7
        case 99: return (0x3D, false) // F3
        case 100: return (0x42, false) // F8
        case 101: return (0x43, false) // F9
        case 103: return (0x57, false) // F11
        case 109: return (0x58, false) // F12
        case 111: return (0x46, false) // F13 as Scroll Lock
        case 115: return (0x47, true) // Home
        case 116: return (0x49, true) // Page Up
        case 117: return (0x53, true) // Forward Delete
        case 118: return (0x3F, false) // F4
        case 119: return (0x4F, true) // End
        case 120: return (0x3C, false) // F2
        case 121: return (0x51, true) // Page Down
        case 122: return (0x3B, false) // F1
        case 123: return (0x4B, true) // Left
        case 124: return (0x4D, true) // Right
        case 125: return (0x50, true) // Down
        case 126: return (0x48, true) // Up
        default: return nil
        }
    }

    private static func modifierScancode(
        forMacKeyCode keyCode: UInt16
    ) -> (scancode: UInt16, isExtended: Bool, flag: NSEvent.ModifierFlags)? {
        switch keyCode {
        case 56, 60:
            return (0x2A, false, .shift)
        case 58, 61:
            return (0x38, false, .option)
        case 59, 62:
            return (0x1D, false, .control)
        default:
            return nil
        }
    }
}

private struct ResizeSignature: Equatable {
    let width: Int
    let height: Int
    let scalePercent: Int
}

private struct ModifierScancode: Hashable {
    let scancode: UInt16
    let isExtended: Bool
}
