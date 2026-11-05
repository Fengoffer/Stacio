import AppKit

final class GraphicsRenderSurfaceView: NSView, NSTextInputClient {
    private static let resizeCoordinateMappingGracePeriod: TimeInterval = 0.75

    var inputHandler: ((GraphicsInputEvent) -> Void)? {
        didSet {
            cancelPendingResizeDelivery()
            lastSentResize = nil
            sendResizeEventIfNeeded()
        }
    }
    var pasteboardStringProvider: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }
    /// 真实拖拽文件时的回调。非 nil 时 performDragOperation 走此回调（用于 FilesCoordinator 上传）；
    /// 为 nil 时回退到 inputHandler 的 .fileDrop 事件（保持测试兼容）。
    var onFileDrop: (([String]) -> Void)?
    private let toastLayer = CATextLayer()
    private var toastHideWorkItem: DispatchWorkItem?
    private let statusBarLayer = CATextLayer()
    private var frameCount: Int = 0
    private var currentFps: Int = 0
    private var fpsTimer: DispatchSourceTimer?
    private var currentRttMs: Int = 0
    private var currentNetworkMode: String = "normal"
    private var isStatusBarVisible = false
    private(set) var renderedFrameSizeForTesting: CGSize?
    private(set) var remotePointerPositionForTesting: CGPoint?
    private(set) var remotePointerBitmapSizeForTesting: CGSize?
    private(set) var remotePointerAnchorPointForTesting: CGPoint?
    var isRemotePointerVisibleForTesting: Bool {
        remotePointerPresentation != .hidden
    }
    var usesLocalDefaultPointerForTesting: Bool {
        remotePointerPresentation == .localDefault
    }
    var isSystemCursorHiddenForTesting: Bool {
        remotePointerPresentation != .localDefault
    }
    var statusToastTextForTesting: String? {
        toastLayer.string as? String
    }
    var isStatusToastVisibleForTesting: Bool {
        toastLayer.superlayer != nil && toastLayer.isHidden == false
    }
    var hasRenderedImageForTesting: Bool {
        layer?.contents != nil
    }

    private var latestFrameSize: CGSize?
    private var latestMousePosition = CGPoint.zero
    private var remotePointerPresentation: RemotePointerPresentation = .localDefault
    private var suppressedKeyUpKeyCodes = Set<UInt16>()
    private var activeMouseButtonRawValues = Set<UInt8>()
    private var activeKeyScancodes = Set<ModifierScancode>()
    private var activeModifierScancodes = Set<ModifierScancode>()
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    private var markedTextStorage = NSMutableAttributedString(string: "")
    private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
    private var currentInterpretedKeyEvent: NSEvent?
    private var currentInterpretationHandled = false
    private var currentInterpretationUsesUnicode = false
    private var compositionWasActive = false
    private var lastSentResize: ResizeSignature?
    private var pendingResize: ResizeSignature?
    private var resizeDeliveryWorkItem: DispatchWorkItem?
    private var optimisticRemoteFrameSize: CGSize?
    private var resizeCoordinateMappingFallbackWorkItem: DispatchWorkItem?
    private var mouseTrackingArea: NSTrackingArea?
    private let remotePointerLayer = CAShapeLayer()
    private lazy var transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            releaseActiveMouseButtons()
            releaseActiveKeys()
            releaseActiveModifiers()
            suppressedKeyUpKeyCodes.removeAll()
            unmarkText()
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
        configureToastLayer()
        configureStatusBar()
        startFpsTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func display(_ frame: GraphicsFrame) {
        guard let image = makeImage(from: frame) else { return }
        latestFrameSize = CGSize(width: frame.width, height: frame.height)
        clearOptimisticRemoteFrameSize()
        renderedFrameSizeForTesting = latestFrameSize
        frameCount += 1
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

    func simulateRegisteredFileDropForTesting(paths: [String], at point: NSPoint) {
        latestMousePosition = point
        if let onFileDrop {
            onFileDrop(paths)
        } else {
            sendFileDrop(paths: paths, point: point)
        }
    }

    func updateRemotePointerPosition(x: Int, y: Int) {
        let localPoint = localPoint(remoteX: x, remoteY: y)
        remotePointerPositionForTesting = localPoint
        if remotePointerPresentation == .bitmap,
           remotePointerLayer.superlayer == nil {
            layer?.addSublayer(remotePointerLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remotePointerLayer.position = localPoint
        remotePointerLayer.isHidden = remotePointerPresentation != .bitmap
        CATransaction.commit()
        setNeedsDisplay(bounds)
    }

    func setRemotePointerVisible(_ isVisible: Bool) {
        if isVisible {
            remotePointerPresentation = .localDefault
            configureRemotePointerLayer()
            remotePointerBitmapSizeForTesting = nil
            remotePointerAnchorPointForTesting = nil
        } else {
            remotePointerPresentation = .hidden
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remotePointerLayer.isHidden = true
        CATransaction.commit()
        resetCursorRects()
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
        remotePointerPresentation = .bitmap
        resetCursorRects()
        setNeedsDisplay(bounds)
    }

    func releaseActiveInputForFocusLoss() {
        releaseActiveMouseButtons()
        releaseActiveKeys()
        releaseActiveModifiers()
        suppressedKeyUpKeyCodes.removeAll()
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = remotePointerPresentation == .localDefault ? .arrow : transparentCursor
        addCursorRect(bounds, cursor: cursor)
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
        let (deltaX, deltaY) = accumulateScrollDeltas(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        )
        guard deltaX != 0 || deltaY != 0 else { return }
        inputHandler?(
            .scroll(
                deltaX: deltaX,
                deltaY: deltaY,
                x: point.x,
                y: point.y
            )
        )
    }

    func accumulateScrollDeltas(deltaX: CGFloat, deltaY: CGFloat) -> (Int, Int) {
        scrollRemainderX += deltaX
        scrollRemainderY += deltaY
        let integralX = Int(scrollRemainderX.rounded(.towardZero))
        let integralY = Int(scrollRemainderY.rounded(.towardZero))
        scrollRemainderX -= CGFloat(integralX)
        scrollRemainderY -= CGFloat(integralY)
        return (integralX, integralY)
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
        let physicalShortcutFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option])
        if physicalShortcutFlags.isEmpty == false {
            sendKey(event, isPressed: true)
            return
        }

        currentInterpretedKeyEvent = event
        currentInterpretationHandled = false
        currentInterpretationUsesUnicode = false
        interpretKeyEvents([event])
        if currentInterpretationHandled == false {
            sendKey(event, isPressed: true)
        } else if currentInterpretationUsesUnicode {
            suppressedKeyUpKeyCodes.insert(event.keyCode)
        }
        currentInterpretedKeyEvent = nil
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
        if event.keyCode == 57 {
            inputHandler?(.key(scancode: scancode.scancode, isExtended: scancode.isExtended, isPressed: true))
            inputHandler?(.key(scancode: scancode.scancode, isExtended: scancode.isExtended, isPressed: false))
            return
        }
        // modifierFlags is aggregate across the left and right physical keys.
        // Track the keyCode that generated this flagsChanged event so releasing
        // one side still sends key-up while the opposite side remains held.
        if activeModifierScancodes.remove(scancode) != nil {
            inputHandler?(.key(scancode: scancode.scancode, isExtended: scancode.isExtended, isPressed: false))
            return
        }
        guard event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(modifier.flag)
        else { return }
        activeModifierScancodes.insert(scancode)
        inputHandler?(.key(scancode: scancode.scancode, isExtended: scancode.isExtended, isPressed: true))
    }

    // MARK: - NSTextInputClient / IME

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            return
        }
        guard text.isEmpty == false else { return }

        let requiresUnicode = compositionWasActive
            || text.unicodeScalars.contains(where: { $0.value > 0x7F })
        currentInterpretationHandled = true
        if requiresUnicode || currentInterpretedKeyEvent == nil {
            currentInterpretationUsesUnicode = true
            inputHandler?(.unicodeText(text))
        } else if let event = currentInterpretedKeyEvent {
            sendKey(event, isPressed: true)
        }
        markedTextStorage = NSMutableAttributedString(string: "")
        markedTextSelection = NSRange(location: NSNotFound, length: 0)
        compositionWasActive = false
    }

    override func doCommand(by selector: Selector) {
        guard let event = currentInterpretedKeyEvent else { return }
        currentInterpretationHandled = true
        currentInterpretationUsesUnicode = false
        sendKey(event, isPressed: true)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed: NSAttributedString
        if let value = string as? NSAttributedString {
            attributed = value
        } else if let value = string as? String {
            attributed = NSAttributedString(string: value)
        } else {
            return
        }
        markedTextStorage = NSMutableAttributedString(attributedString: attributed)
        markedTextSelection = selectedRange
        compositionWasActive = true
        currentInterpretationHandled = true
        currentInterpretationUsesUnicode = true
    }

    func unmarkText() {
        markedTextStorage = NSMutableAttributedString(string: "")
        markedTextSelection = NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        markedTextSelection.location == NSNotFound
            ? NSRange(location: 0, length: 0)
            : markedTextSelection
    }

    func markedRange() -> NSRange {
        markedTextStorage.length == 0
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedTextStorage.length)
    }

    func hasMarkedText() -> Bool {
        markedTextStorage.length > 0
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard range.location != NSNotFound,
              NSMaxRange(range) <= markedTextStorage.length else { return nil }
        actualRange?.pointee = range
        return markedTextStorage.attributedSubstring(from: range)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = NSRange(location: 0, length: 0)
        guard let window else { return .zero }
        let localRect = NSRect(
            x: min(max(0, latestMousePosition.x), bounds.maxX),
            y: min(max(0, latestMousePosition.y), bounds.maxY),
            width: 1,
            height: max(16, NSFont.systemFontSize + 4)
        )
        return window.convertToScreen(convert(localRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFilePaths(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = draggedFilePaths(from: sender)
        guard paths.isEmpty == false else { return false }
        if let onFileDrop {
            onFileDrop(paths)
            return true
        }
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
            CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
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
        remotePointerLayer.contents = nil
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

    private func configureToastLayer() {
        toastLayer.fontSize = 13
        toastLayer.foregroundColor = NSColor.white.cgColor
        toastLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        toastLayer.cornerRadius = 6
        toastLayer.alignmentMode = .center
        toastLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        toastLayer.isHidden = true
    }

    /// 在渲染层顶部显示临时 Toast 消息（默认 3 秒后消失）。
    func showStatusToast(_ message: String, duration: TimeInterval = 3.0) {
        toastHideWorkItem?.cancel()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let textSize = (message as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 12
        let toastWidth = textSize.width + padding * 2
        let toastHeight = textSize.height + padding
        let toastX = max(8, (bounds.width - toastWidth) / 2)
        let toastY = max(8, bounds.height - toastHeight - 16)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toastLayer.frame = CGRect(x: toastX, y: toastY, width: toastWidth, height: toastHeight)
        toastLayer.string = message
        toastLayer.isHidden = false
        if toastLayer.superlayer == nil {
            layer?.addSublayer(toastLayer)
        }
        CATransaction.commit()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideStatusToast()
        }
        toastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func hideStatusToast() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toastLayer.isHidden = true
        CATransaction.commit()
    }

    // MARK: - 状态栏覆盖层（FPS / 网络 / 分辨率 / RTT）

    private func configureStatusBar() {
        statusBarLayer.fontSize = 11
        statusBarLayer.foregroundColor = NSColor.white.cgColor
        statusBarLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        statusBarLayer.cornerRadius = 4
        statusBarLayer.alignmentMode = .left
        statusBarLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        statusBarLayer.isHidden = true
        statusBarLayer.truncationMode = .end
        statusBarLayer.isWrapped = false
    }

    private func startFpsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.currentFps = self.frameCount
            self.frameCount = 0
            self.updateStatusBar()
        }
        timer.resume()
        fpsTimer = timer
    }

    /// 更新网络状态（由 GraphicsSessionPaneViewController 从 onNetworkStatus 回调转发）。
    func updateNetworkStatus(rttMs: Int, mode: String) {
        currentRttMs = rttMs
        currentNetworkMode = mode
        updateStatusBar()
    }

    /// 显示或隐藏状态栏。
    func setStatusBarVisible(_ visible: Bool) {
        isStatusBarVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if visible {
            if statusBarLayer.superlayer == nil {
                layer?.addSublayer(statusBarLayer)
            }
            statusBarLayer.isHidden = false
            updateStatusBar()
        } else {
            statusBarLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func updateStatusBar() {
        guard isStatusBarVisible else { return }
        let resolutionText: String
        if let size = latestFrameSize {
            resolutionText = "\(Int(size.width))×\(Int(size.height))"
        } else {
            resolutionText = "—"
        }
        let signalIcon = Self.networkSignalIcon(for: currentNetworkMode)
        let fpsText = currentFps > 0 ? "\(currentFps)fps" : "—"
        let rttText = currentRttMs > 0 ? "RTT:\(currentRttMs)ms" : ""
        let statusText = "\(fpsText)  \(signalIcon)  \(resolutionText)  \(rttText)".trimmingCharacters(in: .whitespaces)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ]
        let textSize = (statusText as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8
        let barWidth = textSize.width + padding * 2
        let barHeight = textSize.height + 6
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusBarLayer.frame = CGRect(x: 8, y: 8, width: barWidth, height: barHeight)
        statusBarLayer.string = statusText
        statusBarLayer.fontSize = 11
        CATransaction.commit()
    }

    private static func networkSignalIcon(for mode: String) -> String {
        switch mode {
        case "normal": return "▌▌▌"
        case "poor": return "▌▌▏"
        case "very_poor": return "▌▏▏"
        default: return "▌▌▌"
        }
    }

    override func layout() {
        super.layout()
        // 状态栏固定在左下角，无需重新定位
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
        lastSentResize = resize
        beginOptimisticCoordinateMapping(for: resize)
        inputHandler(
            .resize(
                width: resize.width,
                height: resize.height,
                scaleFactor: Double(resize.scalePercent) / 100.0
            )
        )
    }

    private func beginOptimisticCoordinateMapping(for resize: ResizeSignature) {
        guard latestFrameSize != nil else { return }
        let requestedSize = CGSize(width: resize.width, height: resize.height)
        optimisticRemoteFrameSize = requestedSize
        resizeCoordinateMappingFallbackWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard self?.optimisticRemoteFrameSize == requestedSize else { return }
            self?.optimisticRemoteFrameSize = nil
            self?.resizeCoordinateMappingFallbackWorkItem = nil
        }
        resizeCoordinateMappingFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.resizeCoordinateMappingGracePeriod,
            execute: workItem
        )
    }

    private func clearOptimisticRemoteFrameSize() {
        optimisticRemoteFrameSize = nil
        resizeCoordinateMappingFallbackWorkItem?.cancel()
        resizeCoordinateMappingFallbackWorkItem = nil
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
        if isPressed {
            activeMouseButtonRawValues.insert(button.rawValue)
        } else {
            activeMouseButtonRawValues.remove(button.rawValue)
        }
        inputHandler?(.mouseButton(button: button, isPressed: isPressed, x: point.x, y: point.y))
    }

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int) {
        let point = convert(event.locationInWindow, from: nil)
        latestMousePosition = point
        return remotePoint(forLocalPoint: point)
    }

    private func remotePoint(forLocalPoint point: CGPoint) -> (x: Int, y: Int) {
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

    private func releaseActiveMouseButtons() {
        let buttons = activeMouseButtonRawValues
            .sorted()
            .compactMap(GraphicsMouseButton.init(rawValue:))
        activeMouseButtonRawValues.removeAll()
        let point = remotePoint(forLocalPoint: latestMousePosition)
        for button in buttons {
            inputHandler?(
                .mouseButton(
                    button: button,
                    isPressed: false,
                    x: point.x,
                    y: point.y
                )
            )
        }
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
        let scancode = ModifierScancode(
            scancode: mapping.scancode,
            isExtended: mapping.isExtended
        )
        if isPressed {
            activeKeyScancodes.insert(scancode)
        } else {
            activeKeyScancodes.remove(scancode)
        }
        inputHandler?(.key(scancode: mapping.scancode, isExtended: mapping.isExtended, isPressed: isPressed))
    }

    private func releaseActiveKeys() {
        let keys = activeKeyScancodes.sorted {
            ($0.scancode, $0.isExtended ? 1 : 0) < ($1.scancode, $1.isExtended ? 1 : 0)
        }
        activeKeyScancodes.removeAll()
        for key in keys {
            inputHandler?(.key(scancode: key.scancode, isExtended: key.isExtended, isPressed: false))
        }
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
        if let optimisticRemoteFrameSize {
            return optimisticRemoteFrameSize
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
        case 54: return (0x5C, true) // Right Command as Windows key
        case 55: return (0x5B, true) // Left Command as Windows key
        case 56: return (0x2A, false) // Left Shift
        case 60: return (0x36, false) // Right Shift
        case 58: return (0x38, false) // Left Option as Alt
        case 61: return (0x38, true) // Right Option as AltGr
        case 59: return (0x1D, false) // Left Control
        case 62: return (0x1D, true) // Right Control
        case 57: return (0x3A, false) // Caps Lock
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
        case 105: return (0x46, false) // F13 as Scroll Lock
        case 109: return (0x44, false) // F10
        case 111: return (0x58, false) // F12
        case 115: return (0x47, true) // Home
        case 116: return (0x49, true) // Page Up
        case 117: return (0x53, true) // Forward Delete
        case 118: return (0x3E, false) // F4
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
        case 56:
            return (0x2A, false, .shift)
        case 60:
            return (0x36, false, .shift)
        case 58:
            return (0x38, false, .option)
        case 61:
            return (0x38, true, .option)
        case 59:
            return (0x1D, false, .control)
        case 62:
            return (0x1D, true, .control)
        case 54:
            return (0x5C, true, .command)
        case 55:
            return (0x5B, true, .command)
        case 57:
            return (0x3A, false, .capsLock)
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

private enum RemotePointerPresentation {
    case localDefault
    case hidden
    case bitmap
}
