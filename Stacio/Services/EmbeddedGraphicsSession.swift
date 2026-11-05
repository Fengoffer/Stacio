import AppKit
import Foundation
import StacioCoreBindings

public enum GraphicsPixelFormat: Equatable {
    case bgra8Unorm
}

public struct GraphicsFrame: Equatable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: GraphicsPixelFormat
    public let pixels: Data

    public init(width: Int, height: Int, bytesPerRow: Int, pixelFormat: GraphicsPixelFormat, pixels: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.pixels = pixels
    }
}

public struct GraphicsPointerBitmap: Equatable {
    public let width: Int
    public let height: Int
    public let hotspotX: Int
    public let hotspotY: Int
    public let rgbaPixels: Data

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, rgbaPixels: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.rgbaPixels = rgbaPixels
    }
}

public enum GraphicsMouseButton: UInt8, Equatable {
    case left = 0
    case middle = 1
    case right = 2
    case x1 = 3
    case x2 = 4
}

public enum GraphicsInputEvent: Equatable {
    case resize(width: Int, height: Int, scaleFactor: Double)
    case mouseMoved(x: Int, y: Int)
    case mouseButton(button: GraphicsMouseButton, isPressed: Bool, x: Int, y: Int)
    case scroll(deltaX: Int, deltaY: Int, x: Int, y: Int)
    case key(scancode: UInt16, isExtended: Bool, isPressed: Bool)
    /// Committed text from AppKit's input method. Physical shortcuts and
    /// navigation keys continue to use `.key` scancodes.
    case unicodeText(String)
    case fileDrop(paths: [String], x: Int, y: Int)
    case clipboardTextPaste(String)
    case quality(Int)
    case close
}

public protocol EmbeddedGraphicsSession: AnyObject {
    var onFrame: ((GraphicsFrame) -> Void)? { get set }
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)? { get set }
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)? { get set }
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)? { get set }
    func start() throws
    func stop()
    func sendInput(_ event: GraphicsInputEvent)
}

// MARK: - Lifecycle 协议（VNC/RDP 等需要连接状态通知的会话）

public enum EmbeddedGraphicsLifecycleState: Equatable {
    case connecting
    case connected(width: Int, height: Int, name: String)
    case disconnected(reason: String)
}

public protocol EmbeddedGraphicsSessionLifecycle: EmbeddedGraphicsSession {
    var onConnected: ((_ width: Int, _ height: Int, _ name: String) -> Void)? { get set }
    var onDisconnected: ((_ reason: String) -> Void)? { get set }
    var onClipboard: ((_ text: String) -> Void)? { get set }
    var onNetworkStatus: ((_ rttMs: Int, _ mode: String) -> Void)? { get set }
    var onError: ((_ message: String) -> Void)? { get set }
    var lifecycleState: EmbeddedGraphicsLifecycleState { get }
    var latestFrame: GraphicsFrame? { get }
    var latestError: String? { get }
    var isClipboardSynchronizationEnabled: Bool { get }
    func setClipboardSynchronizationEnabled(_ enabled: Bool)
}

public extension EmbeddedGraphicsSessionLifecycle {
    var lifecycleState: EmbeddedGraphicsLifecycleState { .connecting }
    var latestFrame: GraphicsFrame? { nil }
    var latestError: String? { nil }
    var isClipboardSynchronizationEnabled: Bool { false }
    func setClipboardSynchronizationEnabled(_ enabled: Bool) {}
}

private struct GraphicsPasteboardSnapshot {
    let changeCount: Int
    let text: String?
}

private func generalPasteboardSnapshot() -> GraphicsPasteboardSnapshot {
    let readSnapshot = {
        let pasteboard = NSPasteboard.general
        return GraphicsPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            text: pasteboard.string(forType: .string)
        )
    }
    if Thread.isMainThread {
        return readSnapshot()
    }
    return DispatchQueue.main.sync(execute: readSnapshot)
}

struct VNCAdapterLineBuffer {
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var discardingOversizedLine = false

    var bufferedByteCount: Int {
        buffer.count
    }

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        var cursor = data.startIndex

        while cursor < data.endIndex {
            if discardingOversizedLine {
                guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else {
                    return lines
                }
                discardingOversizedLine = false
                cursor = data.index(after: newlineIndex)
                continue
            }

            if let newlineIndex = data[cursor...].firstIndex(of: 0x0A) {
                let segment = data[cursor..<newlineIndex]
                if segment.count <= maximumLineBytes - buffer.count {
                    buffer.append(segment)
                    if let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                        lines.append(line)
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                cursor = data.index(after: newlineIndex)
                continue
            }

            let segment = data[cursor...]
            if segment.count <= maximumLineBytes - buffer.count {
                buffer.append(segment)
            } else {
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
            break
        }

        return lines
    }
}

final class VNCSerializedLineWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writeOperation: (Data) throws -> Void

    init(writeOperation: @escaping (Data) throws -> Void) {
        self.writeOperation = writeOperation
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? writeOperation(data)
    }
}

// MARK: - VNC 会话实现

public final class EmbeddedVNCGraphicsSession: EmbeddedGraphicsSessionLifecycle {
    private static let maximumDesktopDimension = 8_192
    private static let maximumClipboardBytes = 1_048_576
    private static let maximumAdapterLineBytes = 96 * 1024 * 1024
    private static let maximumJPEGFrameBytes = 64 * 1024 * 1024
    public var onFrame: ((GraphicsFrame) -> Void)?
    public var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    public var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    public var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?
    public var onConnected: ((_ width: Int, _ height: Int, _ name: String) -> Void)?
    public var onDisconnected: ((_ reason: String) -> Void)?
    public var onClipboard: ((_ text: String) -> Void)?
    public var onNetworkStatus: ((_ rttMs: Int, _ mode: String) -> Void)?
    public var onError: ((_ message: String) -> Void)?
    public var lifecycleState: EmbeddedGraphicsLifecycleState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleStateValue
    }
    public var latestFrame: GraphicsFrame? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestFrameValue
    }
    public var latestError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestErrorValue
    }
    public var isClipboardSynchronizationEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clipboardSynchronizationEnabledValue
    }

    private let host: String
    private let port: UInt16
    private let password: String?
    private let quality: Int
    private let maxFps: Int
    private let adapterExecutablePath: String
    private let appLog: StacioLogWriting?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdinWriter: VNCSerializedLineWriter?
    private var stdoutPipe: Pipe?
    private var stdoutLineBuffer: VNCAdapterLineBuffer
    private let stdoutQueue = DispatchQueue(label: "stacio.vnc.stdout")
    private var canvas: [UInt8] = []
    private var canvasWidth: Int = 0
    private var canvasHeight: Int = 0
    private var canvasBytesPerRow: Int = 0
    private let stateLock = NSLock()
    private var isStopped = false
    private var hasConnected = false
    private var lifecycleStateValue: EmbeddedGraphicsLifecycleState = .connecting
    private var latestFrameValue: GraphicsFrame?
    private var latestErrorValue: String?
    private var clipboardSynchronizationEnabledValue = false
    private var lastPasteboardChangeCount: Int = 0
    private var pasteboardTimer: DispatchSourceTimer?
    private let pasteboardLock = NSLock()
    private let pasteboardQueue = DispatchQueue(label: "stacio.vnc.pasteboard")
    private var currentPointerButtons: Int = 0

    public init(
        host: String,
        port: UInt16,
        password: String?,
        quality: Int = 7,
        maxFps: Int = 30,
        adapterExecutablePath: String,
        appLog: StacioLogWriting? = StacioLogStore.shared
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.quality = max(1, min(10, quality))
        self.maxFps = max(1, min(60, maxFps))
        self.adapterExecutablePath = adapterExecutablePath
        self.appLog = appLog
        self.stdoutLineBuffer = VNCAdapterLineBuffer(
            maximumLineBytes: Self.maximumAdapterLineBytes
        )
    }

    public func start() throws {
        stateLock.lock()
        isStopped = false
        hasConnected = false
        lifecycleStateValue = .connecting
        latestFrameValue = nil
        latestErrorValue = nil
        stateLock.unlock()

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: adapterExecutablePath)
        process.arguments = buildLaunchArguments()
        if let password, !password.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["STACIO_VNC_PASSWORD": password]
            ) { _, sessionValue in
                sessionValue
            }
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        process.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            self?.appLog?.append(
                level: code == 0 ? .info : .error,
                category: "Graphics",
                message: "vnc.session.terminated status=\(code)"
            )
            self?.stdoutQueue.async { [weak self] in
                guard let self else { return }
                let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if remaining.isEmpty == false {
                    self.processStdoutData(remaining)
                }
                self.handleTermination()
            }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdinWriter = VNCSerializedLineWriter { data in
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        self.stdoutPipe = stdoutPipe

        appLog?.append(
            level: .info,
            category: "Graphics",
            message: "vnc.session.started host=\(host):\(port) pid=\(process.processIdentifier)"
        )

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.stdoutQueue.async { [weak self] in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.processStdoutData(data)
            }
        }

    }

    public func stop() {
        stateLock.lock()
        let alreadyStopped = isStopped
        let connected = hasConnected
        isStopped = true
        clipboardSynchronizationEnabledValue = false
        if !alreadyStopped {
            lifecycleStateValue = .disconnected(reason: "会话已停止")
        }
        stateLock.unlock()

        guard !alreadyStopped else { return }

        stopPasteboardMonitor()

        sendJSON(["type": "close"])

        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            if process?.isRunning == true {
                process?.terminate()
            }
        }

        if !connected {
            onDisconnected?("会话已停止")
        }
    }

    public func setClipboardSynchronizationEnabled(_ enabled: Bool) {
        stateLock.lock()
        let changed = clipboardSynchronizationEnabledValue != enabled
        clipboardSynchronizationEnabledValue = enabled
        let active = isStopped == false
        stateLock.unlock()

        guard changed else { return }
        if enabled, active, process?.isRunning == true {
            startPasteboardMonitor()
        } else {
            stopPasteboardMonitor()
        }
    }

    public func sendInput(_ event: GraphicsInputEvent) {
        guard sessionIsActive else { return }
        switch event {
        case .resize(let width, let height, _):
            guard width > 0,
                  height > 0,
                  width <= Self.maximumDesktopDimension,
                  height <= Self.maximumDesktopDimension else { return }
            sendJSON([
                "type": "resize_request",
                "width": width,
                "height": height
            ])
        case .mouseMoved(let x, let y):
            sendJSON([
                "type": "pointer",
                "x": x,
                "y": y,
                "buttons": currentPointerButtons
            ])
        case .mouseButton(let button, let isPressed, let x, let y):
            updatePointerButtons(button: button, isPressed: isPressed)
            sendJSON([
                "type": "pointer",
                "x": x,
                "y": y,
                "buttons": currentPointerButtons
            ])
        case .scroll(let deltaX, let deltaY, let x, let y):
            var payload: [String: Any] = [
                "type": "pointer",
                "x": x,
                "y": y,
                "buttons": currentPointerButtons
            ]
            if deltaX != 0 { payload["scroll_dx"] = deltaX }
            if deltaY != 0 { payload["scroll_dy"] = deltaY }
            sendJSON(payload)
        case .key(let scancode, let isExtended, let isPressed):
            if let keysym = Self.keysymForScancode(scancode, isExtended: isExtended) {
                sendJSON([
                    "type": "key",
                    "keysym": keysym,
                    "down": isPressed
                ])
            }
        case .unicodeText(let text):
            for scalar in text.unicodeScalars {
                let keysym: UInt32
                if scalar.value >= 0x20 && scalar.value <= 0x7E
                    || scalar.value >= 0xA0 && scalar.value <= 0xFF
                {
                    keysym = scalar.value
                } else {
                    keysym = 0x0100_0000 | scalar.value
                }
                sendJSON(["type": "key", "keysym": keysym, "down": true])
                sendJSON(["type": "key", "keysym": keysym, "down": false])
            }
        case .fileDrop(let paths, let x, let y):
            sendJSON([
                "type": "file_drop",
                "paths": paths,
                "x": x,
                "y": y
            ])
        case .clipboardTextPaste(let text):
            guard Self.clipboardTextFits(text) else { return }
            sendJSON([
                "type": "clipboard",
                "text": text
            ])
        case .quality(let level):
            sendJSON([
                "type": "quality",
                "level": max(1, min(10, level))
            ])
        case .close:
            sendJSON(["type": "close"])
        }
    }

    // MARK: - 启动参数

    private func buildLaunchArguments() -> [String] {
        var args: [String] = ["\(host):\(port)"]
        args.append(contentsOf: ["--quality", "\(quality)"])
        args.append(contentsOf: ["--max-fps", "\(maxFps)"])
        return args
    }

    // MARK: - stdout 解析

    private func processStdoutData(_ data: Data) {
        guard sessionIsActive else { return }
        for line in stdoutLineBuffer.append(data) {
            handleAdapterLine(line)
        }
    }

    private func handleAdapterLine(_ line: String) {
        guard sessionIsActive,
              let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "connected":
            let width = json["width"] as? Int ?? 0
            let height = json["height"] as? Int ?? 0
            let name = json["name"] as? String ?? ""
            handleConnected(width: width, height: height, name: name)
        case "frame":
            handleFrame(json)
        case "frame_patch":
            handleFramePatch(json)
        case "pointer_position":
            handlePointerPosition(json)
        case "pointer_bitmap":
            handlePointerBitmap(json)
        case "pointer_visibility":
            guard let visible = json["visible"] as? Bool else { return }
            if Thread.isMainThread {
                guard sessionIsActive else { return }
                onPointerVisibilityChanged?(visible)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionIsActive else { return }
                    self.onPointerVisibilityChanged?(visible)
                }
            }
        case "clipboard":
            let text = json["text"] as? String ?? ""
            // 分发到主线程执行 onClipboard（写 NSPasteboard），完成后同步 changeCount 避免回环
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionIsActive,
                      self.isClipboardSynchronizationEnabled else { return }
                self.onClipboard?(text)
                let newCount = generalPasteboardSnapshot().changeCount
                self.pasteboardLock.lock()
                self.lastPasteboardChangeCount = newCount
                self.pasteboardLock.unlock()
            }
        case "resize":
            let width = json["width"] as? Int ?? 0
            let height = json["height"] as? Int ?? 0
            if width > 0, height > 0 {
                handleResize(width: width, height: height)
            }
        case "network":
            let rttMs = json["rtt_ms"] as? Int ?? 0
            let mode = json["mode"] as? String ?? "normal"
            onNetworkStatus?(rttMs, mode)
        case "error":
            let message = json["message"] as? String ?? "未知错误"
            handleAdapterError(message: message)
        case "disconnected":
            let reason = json["reason"] as? String ?? "连接断开"
            handleDisconnected(reason: reason)
        default:
            break
        }
    }

    // MARK: - 事件处理

    private func handleConnected(width: Int, height: Int, name: String) {
        guard let layout = Self.canvasLayout(width: width, height: height) else { return }

        stateLock.lock()
        guard isStopped == false else {
            stateLock.unlock()
            return
        }
        hasConnected = true
        lifecycleStateValue = .connected(width: width, height: height, name: name)
        stateLock.unlock()

        canvasWidth = width
        canvasHeight = height
        canvasBytesPerRow = layout.bytesPerRow
        canvas = [UInt8](repeating: 0, count: layout.byteCount)
        onConnected?(width, height, name)
    }

    private func handleResize(width: Int, height: Int) {
        guard width != canvasWidth || height != canvasHeight,
              let layout = Self.canvasLayout(width: width, height: height) else { return }
        let preservedWidth = min(canvasWidth, width)
        let preservedHeight = min(canvasHeight, height)
        var resizedCanvas = [UInt8](repeating: 0, count: layout.byteCount)
        if preservedWidth > 0, preservedHeight > 0, canvas.isEmpty == false {
            let preservedBytesPerRow = preservedWidth * 4
            for row in 0..<preservedHeight {
                let sourceOffset = row * canvasBytesPerRow
                let destinationOffset = row * layout.bytesPerRow
                resizedCanvas.replaceSubrange(
                    destinationOffset..<(destinationOffset + preservedBytesPerRow),
                    with: canvas[sourceOffset..<(sourceOffset + preservedBytesPerRow)]
                )
            }
        }
        canvasWidth = width
        canvasHeight = height
        canvasBytesPerRow = layout.bytesPerRow
        canvas = resizedCanvas
    }

    private static func canvasLayout(
        width: Int,
        height: Int
    ) -> (bytesPerRow: Int, byteCount: Int)? {
        guard width > 0,
              height > 0,
              width <= maximumDesktopDimension,
              height <= maximumDesktopDimension else { return nil }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !countOverflow else { return nil }
        return (bytesPerRow, byteCount)
    }

    private func handleFrame(_ json: [String: Any]) {
        guard let x = json["x"] as? Int,
              let y = json["y"] as? Int,
              let w = json["w"] as? Int,
              let h = json["h"] as? Int,
              let encoding = json["encoding"] as? String,
              encoding == "jpeg",
              let dataBase64 = json["data"] as? String,
              Self.framePatchFitsCanvas(
                  x: x,
                  y: y,
                  width: w,
                  height: h,
                  canvasWidth: canvasWidth,
                  canvasHeight: canvasHeight
              ),
              dataBase64.utf8.count <= ((Self.maximumJPEGFrameBytes + 2) / 3) * 4,
              let jpegData = Data(base64Encoded: dataBase64)
        else { return }
        applyJPEGToCanvas(jpegData, x: x, y: y, width: w, height: h)
        if json["batch_end"] as? Bool != false {
            deliverCanvasFrame()
        }
    }

    static func framePatchFitsCanvas(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Bool {
        guard x >= 0,
              y >= 0,
              width > 0,
              height > 0,
              width <= canvasWidth,
              height <= canvasHeight else { return false }
        return x <= canvasWidth - width && y <= canvasHeight - height
    }

    private func handleFramePatch(_ json: [String: Any]) {
        // frame_patch 的处理与 frame 相同——都是把 JPEG 补丁合成到画布
        handleFrame(json)
    }

    private func handlePointerPosition(_ json: [String: Any]) {
        guard let x = json["x"] as? Int,
              let y = json["y"] as? Int,
              x >= 0,
              y >= 0,
              x < canvasWidth,
              y < canvasHeight else { return }

        if Thread.isMainThread {
            guard sessionIsActive else { return }
            onPointerPosition?(x, y)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionIsActive else { return }
                self.onPointerPosition?(x, y)
            }
        }
    }

    private func handlePointerBitmap(_ json: [String: Any]) {
        let maximumRGBABytes = 4 * 1024 * 1024
        let maximumPixels = maximumRGBABytes / 4
        guard let width = json["width"] as? Int,
              let height = json["height"] as? Int,
              let hotspotX = json["hotspot_x"] as? Int,
              let hotspotY = json["hotspot_y"] as? Int,
              let dataBase64 = json["data"] as? String,
              width > 0,
              height > 0,
              width <= maximumPixels,
              height <= maximumPixels / width,
              hotspotX >= 0,
              hotspotY >= 0,
              hotspotX < width,
              hotspotY < height else { return }

        let expectedByteCount = width * height * 4
        let expectedBase64Length = ((expectedByteCount + 2) / 3) * 4
        guard dataBase64.utf8.count == expectedBase64Length,
              let rgbaPixels = Data(base64Encoded: dataBase64),
              rgbaPixels.count == expectedByteCount else { return }

        let bitmap = GraphicsPointerBitmap(
            width: width,
            height: height,
            hotspotX: hotspotX,
            hotspotY: hotspotY,
            rgbaPixels: rgbaPixels
        )
        if Thread.isMainThread {
            guard sessionIsActive else { return }
            onPointerBitmap?(bitmap)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionIsActive else { return }
                self.onPointerBitmap?(bitmap)
            }
        }
    }

    private func handleDisconnected(reason: String) {
        stateLock.lock()
        guard isStopped == false else {
            stateLock.unlock()
            return
        }
        isStopped = true
        clipboardSynchronizationEnabledValue = false
        lifecycleStateValue = .disconnected(reason: reason)
        stateLock.unlock()

        stopPasteboardMonitor()
        onDisconnected?(reason)
    }

    private func handleAdapterError(message: String) {
        stateLock.lock()
        guard isStopped == false else {
            stateLock.unlock()
            return
        }
        isStopped = true
        latestErrorValue = message
        clipboardSynchronizationEnabledValue = false
        lifecycleStateValue = .disconnected(reason: message)
        stateLock.unlock()

        stopPasteboardMonitor()
        appLog?.append(
            level: .error,
            category: "Graphics",
            message: "vnc.session.error reason=\(message)"
        )
        onError?(message)
        onDisconnected?(message)
    }

    private func handleTermination() {
        stateLock.lock()
        let stopped = isStopped
        let reason = latestErrorValue ?? "适配器进程已退出"
        isStopped = true
        clipboardSynchronizationEnabledValue = false
        if !stopped {
            lifecycleStateValue = .disconnected(reason: reason)
        }
        stateLock.unlock()

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stopPasteboardMonitor()

        if !stopped {
            onDisconnected?(reason)
        }
    }

    // MARK: - JPEG 解码与画布合成

    private func applyJPEGToCanvas(_ jpegData: Data, x: Int, y: Int, width: Int, height: Int) {
        guard Self.framePatchFitsCanvas(
            x: x,
            y: y,
            width: width,
            height: height,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        ) else { return }

        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }

        guard let context = CGContext(
            data: &canvas,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        // CGContext 原点在左下角，VNC/RFB 原点在左上角
        let drawRect = CGRect(
            x: x,
            y: canvasHeight - y - height,
            width: width,
            height: height
        )
        context.clear(drawRect)
        context.draw(cgImage, in: drawRect)
    }

    private func deliverCanvasFrame() {
        guard canvasWidth > 0, canvasHeight > 0, !canvas.isEmpty else { return }
        let pixels = Data(canvas)
        let frame = GraphicsFrame(
            width: canvasWidth,
            height: canvasHeight,
            bytesPerRow: canvasBytesPerRow,
            pixelFormat: .bgra8Unorm,
            pixels: pixels
        )
        stateLock.lock()
        guard isStopped == false else {
            stateLock.unlock()
            return
        }
        latestFrameValue = frame
        stateLock.unlock()
        if Thread.isMainThread {
            guard sessionIsActive else { return }
            onFrame?(frame)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionIsActive else { return }
                self.onFrame?(frame)
            }
        }
    }

    // MARK: - 剪贴板同步（Mac → 远端）

    private func startPasteboardMonitor() {
        stopPasteboardMonitor()
        let initialChangeCount = generalPasteboardSnapshot().changeCount
        let timer = DispatchSource.makeTimerSource(queue: pasteboardQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.checkPasteboard()
        }

        pasteboardLock.lock()
        lastPasteboardChangeCount = initialChangeCount
        pasteboardTimer = timer
        pasteboardLock.unlock()
        timer.resume()

        if sessionIsActive == false {
            stopPasteboardMonitor()
        }
    }

    private func stopPasteboardMonitor() {
        pasteboardLock.lock()
        let timer = pasteboardTimer
        pasteboardTimer = nil
        pasteboardLock.unlock()
        timer?.cancel()
    }

    private func checkPasteboard() {
        guard sessionIsActive, isClipboardSynchronizationEnabled else { return }
        let snapshot = generalPasteboardSnapshot()
        pasteboardLock.lock()
        let didChange = snapshot.changeCount != lastPasteboardChangeCount
        if didChange {
            lastPasteboardChangeCount = snapshot.changeCount
        }
        pasteboardLock.unlock()
        guard didChange,
              let text = snapshot.text,
              !text.isEmpty,
              Self.clipboardTextFits(text)
        else { return }
        guard sessionIsActive, isClipboardSynchronizationEnabled else { return }
        sendJSON([
            "type": "clipboard",
            "text": text
        ])
    }

    private static func clipboardTextFits(_ text: String) -> Bool {
        text.utf8.count <= maximumClipboardBytes
    }

    // MARK: - stdin 写入

    private func updatePointerButtons(button: GraphicsMouseButton, isPressed: Bool) {
        let bit: Int
        switch button {
        case .left:
            bit = 1 << 0
        case .middle:
            bit = 1 << 1
        case .right:
            bit = 1 << 2
        case .x1, .x2:
            // Standard RFB reserves bits 3–6 for wheel directions. Sending
            // X1/X2 through rawValue would turn a side-button click into a
            // remote scroll event, so leave unsupported side buttons unset.
            return
        }
        if isPressed {
            currentPointerButtons |= bit
        } else {
            currentPointerButtons &= ~bit
        }
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let lineData = Data((line + "\n").utf8)
        stdinWriter?.write(lineData)
    }

    private var sessionIsActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStopped == false
    }

    // MARK: - PC Scancode → X11 Keysym 映射

    static func keysymForScancode(_ scancode: UInt16, isExtended: Bool) -> UInt32? {
        // 扩展键（0xE0 前缀）单独处理
        if isExtended {
            switch scancode {
            case 0x1C: return 0xFF8D  // KP_Enter
            case 0x1D: return 0xFFE4  // Control_R
            case 0x35: return 0xFFAF  // KP_Divide
            case 0x38: return 0xFFEA  // Alt_R
            case 0x47: return 0xFF50  // Home
            case 0x48: return 0xFF52  // Up
            case 0x49: return 0xFF55  // Page_Up
            case 0x4B: return 0xFF51  // Left
            case 0x4D: return 0xFF53  // Right
            case 0x4F: return 0xFF57  // End
            case 0x50: return 0xFF54  // Down
            case 0x51: return 0xFF56  // Page_Down
            case 0x52: return 0xFF63  // Insert
            case 0x53: return 0xFFFF  // Delete
            case 0x5B: return 0xFFEB  // Super_L (Windows key)
            case 0x5C: return 0xFFEC  // Super_R
            case 0x5D: return 0xFF67  // Menu
            default: return nil
            }
        }

        switch scancode {
        // 数字行
        case 0x02: return 0x31  // 1
        case 0x03: return 0x32  // 2
        case 0x04: return 0x33  // 3
        case 0x05: return 0x34  // 4
        case 0x06: return 0x35  // 5
        case 0x07: return 0x36  // 6
        case 0x08: return 0x37  // 7
        case 0x09: return 0x38  // 8
        case 0x0A: return 0x39  // 9
        case 0x0B: return 0x30  // 0
        case 0x0C: return 0x2D  // -
        case 0x0D: return 0x3D  // =
        case 0x0E: return 0xFF08 // BackSpace
        case 0x0F: return 0xFF09 // Tab
        // 字母第一行 Q-P
        case 0x10: return 0x71  // q
        case 0x11: return 0x77  // w
        case 0x12: return 0x65  // e
        case 0x13: return 0x72  // r
        case 0x14: return 0x74  // t
        case 0x15: return 0x79  // y
        case 0x16: return 0x75  // u
        case 0x17: return 0x69  // i
        case 0x18: return 0x6F  // o
        case 0x19: return 0x70  // p
        case 0x1A: return 0x5B  // [
        case 0x1B: return 0x5D  // ]
        case 0x1C: return 0xFF0D // Return
        case 0x1D: return 0xFFE3 // Control_L
        // 字母第二行 A-L
        case 0x1E: return 0x61  // a
        case 0x1F: return 0x73  // s
        case 0x20: return 0x64  // d
        case 0x21: return 0x66  // f
        case 0x22: return 0x67  // g
        case 0x23: return 0x68  // h
        case 0x24: return 0x6A  // j
        case 0x25: return 0x6B  // k
        case 0x26: return 0x6C  // l
        case 0x27: return 0x3B  // ;
        case 0x28: return 0x27  // '
        case 0x29: return 0x60  // `
        case 0x2A: return 0xFFE1 // Shift_L
        case 0x36: return 0xFFE2 // Shift_R
        case 0x2B: return 0x5C  // backslash
        // 字母第三行 Z-M
        case 0x2C: return 0x7A  // z
        case 0x2D: return 0x78  // x
        case 0x2E: return 0x63  // c
        case 0x2F: return 0x76  // v
        case 0x30: return 0x62  // b
        case 0x31: return 0x6E  // n
        case 0x32: return 0x6D  // m
        case 0x33: return 0x2C  // ,
        case 0x34: return 0x2E  // .
        case 0x35: return 0x2F  // /
        case 0x37: return 0xFFAA // KP_Multiply
        case 0x38: return 0xFFE9 // Alt_L
        case 0x39: return 0x20  // space
        case 0x3A: return 0xFFE5 // Caps_Lock
        case 0x3B: return 0xFFBE // F1
        case 0x3C: return 0xFFBF // F2
        case 0x3D: return 0xFFC0 // F3
        case 0x3E: return 0xFFC1 // F4
        case 0x3F: return 0xFFC2 // F5
        case 0x40: return 0xFFC3 // F6
        case 0x41: return 0xFFC4 // F7
        case 0x42: return 0xFFC5 // F8
        case 0x43: return 0xFFC6 // F9
        case 0x44: return 0xFFC7 // F10
        case 0x45: return 0xFF7F // Num_Lock
        case 0x46: return 0xFF14 // Scroll_Lock
        case 0x47: return 0xFFB7 // KP_7
        case 0x48: return 0xFFB8 // KP_8
        case 0x49: return 0xFFB9 // KP_9
        case 0x4A: return 0xFFAD // KP_Subtract
        case 0x4B: return 0xFFB4 // KP_4
        case 0x4C: return 0xFFB5 // KP_5
        case 0x4D: return 0xFFB6 // KP_6
        case 0x4E: return 0xFFAB // KP_Add
        case 0x4F: return 0xFFB1 // KP_1
        case 0x50: return 0xFFB2 // KP_2
        case 0x51: return 0xFFB3 // KP_3
        case 0x52: return 0xFFB0 // KP_0
        case 0x53: return 0xFFAE // KP_Decimal
        case 0x57: return 0xFFC8 // F11
        case 0x58: return 0xFFC9 // F12
        default: return nil
        }
    }
}

// MARK: - VNC 会话工厂（便于测试注入 mock，避免单元测试启动真实适配器进程）

public protocol EmbeddedVNCGraphicsSessionFactory: AnyObject {
    func makeSession(
        host: String,
        port: UInt16,
        password: String?,
        quality: Int,
        maxFps: Int,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?
    ) -> EmbeddedGraphicsSessionLifecycle
}

public final class DefaultEmbeddedVNCGraphicsSessionFactory: EmbeddedVNCGraphicsSessionFactory {
    public init() {}

    public func makeSession(
        host: String,
        port: UInt16,
        password: String?,
        quality: Int,
        maxFps: Int,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?
    ) -> EmbeddedGraphicsSessionLifecycle {
        EmbeddedVNCGraphicsSession(
            host: host,
            port: port,
            password: password,
            quality: quality,
            maxFps: maxFps,
            adapterExecutablePath: adapterExecutablePath,
            appLog: appLog
        )
    }
}

// MARK: - RDP 会话实现
// RDP 使用进程内 IronRDP 会话：帧、指针、键鼠和文本剪贴板均通过
// UniFFI 与图形面板双向桥接，不依赖外部 RDP 窗口。

public struct EmbeddedRDPSessionOptions: Equatable {
    public let host: String
    public let port: UInt16
    public let user: String
    public let password: String
    public let domain: String?
    public let width: Int
    public let height: Int
    public let quality: Int
    public let ignoreCert: Bool
    public let security: RDPSecurityType
    public let drive: String?  // "name:localpath"

    public init(
        host: String,
        port: UInt16,
        user: String,
        password: String,
        domain: String? = nil,
        width: Int = 1280,
        height: Int = 800,
        quality: Int = 7,
        ignoreCert: Bool = false,
        security: RDPSecurityType = .nla,
        drive: String? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.domain = domain
        self.width = width
        self.height = height
        self.quality = max(1, min(10, quality))
        self.ignoreCert = ignoreCert
        self.security = security
        self.drive = drive
    }
}

public enum RDPSecurityType: String, Equatable, CaseIterable {
    case nla
    case tls
    case rdp

    /// Security modes implemented by the embedded IronRDP transport. The
    /// legacy Standard RDP mode remains decodable so old data can be rejected
    /// explicitly, but it must never be offered for a new connection.
    public static let supportedConnectionTypes: [RDPSecurityType] = [.nla, .tls]

    public var displayName: String {
        switch self {
        case .nla: return "NLA（网络级认证，推荐）"
        case .tls: return "TLS"
        case .rdp: return "RDP（传统）"
        }
    }
}

public enum EmbeddedRDPGraphicsSessionError: Error, Equatable, LocalizedError {
    case unsupportedLegacySecurity
    case unsupportedDesktopSize(Int, Int)
    case invalidDriveFormat
    case emptyDriveName
    case unsafeDriveName
    case emptyDrivePath
    case missingDriveDirectory(String)
    case drivePathIsNotDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLegacySecurity:
            return "Stacio 不支持传统 RDP 安全模式，请选择 NLA 或 TLS。"
        case .unsupportedDesktopSize(let width, let height):
            return "RDP 分辨率无效或过大：\(width)×\(height)，单边最大支持 8192 像素。"
        case .invalidDriveFormat:
            return "RDP 驱动器共享格式无效，应为 名称:本地目录。"
        case .emptyDriveName:
            return "RDP 共享驱动器名称不能为空。"
        case .unsafeDriveName:
            return "RDP 共享驱动器名称只允许字母、数字、空格、点、下划线和连字符，且最长 32 个字符。"
        case .emptyDrivePath:
            return "RDP 共享本地目录不能为空。"
        case .missingDriveDirectory(let path):
            return "RDP 共享本地目录不存在：\(path)"
        case .drivePathIsNotDirectory(let path):
            return "RDP 共享路径不是目录：\(path)"
        }
    }
}

struct ValidatedRDPDrive: Equatable {
    let name: String
    let localPath: String
}

struct RDPAdaptiveQualityState: Equatable {
    private(set) var desiredQuality: Int
    private(set) var effectiveQuality: Int
    private(set) var effectiveMaxFPS: Int
    private var networkMode = "normal"

    init(desiredQuality: Int) {
        let quality = Self.clamp(desiredQuality)
        self.desiredQuality = quality
        self.effectiveQuality = quality
        self.effectiveMaxFPS = Self.maxFPS(forQuality: quality)
    }

    @discardableResult
    mutating func setDesiredQuality(_ quality: Int) -> Bool {
        desiredQuality = Self.clamp(quality)
        return recompute()
    }

    @discardableResult
    mutating func applyNetworkMode(_ mode: String) -> Bool {
        guard mode == "normal" || mode == "poor" || mode == "very_poor" else {
            return false
        }
        networkMode = mode
        return recompute()
    }

    private mutating func recompute() -> Bool {
        let previousQuality = effectiveQuality
        switch networkMode {
        case "poor":
            effectiveQuality = min(desiredQuality, 5)
            effectiveMaxFPS = min(Self.maxFPS(forQuality: desiredQuality), 15)
        case "very_poor":
            effectiveQuality = min(desiredQuality, 2)
            effectiveMaxFPS = min(Self.maxFPS(forQuality: desiredQuality), 8)
        default:
            effectiveQuality = desiredQuality
            effectiveMaxFPS = Self.maxFPS(forQuality: desiredQuality)
        }
        return effectiveQuality != previousQuality
    }

    private static func clamp(_ quality: Int) -> Int {
        max(1, min(10, quality))
    }

    private static func maxFPS(forQuality quality: Int) -> Int {
        switch quality {
        case ...3: return 8
        case ...6: return 15
        default: return 30
        }
    }
}

public final class EmbeddedRDPGraphicsSession: EmbeddedGraphicsSessionLifecycle {
    private static let maximumDesktopDimension = 8_192
    private static let maximumClipboardUTF16CodeUnits = (1_048_576 - 2) / 2
    public var onFrame: ((GraphicsFrame) -> Void)?
    public var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    public var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    public var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?
    public var onConnected: ((_ width: Int, _ height: Int, _ name: String) -> Void)?
    public var onDisconnected: ((_ reason: String) -> Void)?
    public var onClipboard: ((_ text: String) -> Void)?
    public var onNetworkStatus: ((_ rttMs: Int, _ mode: String) -> Void)?
    public var onError: ((_ message: String) -> Void)?
    public var lifecycleState: EmbeddedGraphicsLifecycleState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycleStateValue
    }
    public var latestFrame: GraphicsFrame? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestFrameValue
    }
    public var isClipboardSynchronizationEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clipboardSynchronizationEnabledValue
    }

    private let options: EmbeddedRDPSessionOptions
    private let appLog: StacioLogWriting?
    private let frameClock: () -> TimeInterval

    private let rdpSessionFactory: () -> any RdpSessionProtocol
    private var rdpSession: (any RdpSessionProtocol)?
    private var delegate: RDPDelegateBridge?
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private var connectionGeneration: UInt64 = 0
    private var isStopped = false
    private var hasConnected = false
    private var lifecycleStateValue: EmbeddedGraphicsLifecycleState = .connecting
    private var latestFrameValue: GraphicsFrame?
    private var frameCanvas = Data()
    private var frameCanvasWidth = 0
    private var frameCanvasHeight = 0
    private var clipboardSynchronizationEnabledValue = false
    private var lastWidth: Int
    private var lastHeight: Int
    private var lastDeliveredFrameTime: TimeInterval?
    private var currentMaxFps: Int
    private var adaptiveQualityState: RDPAdaptiveQualityState
    private var networkMode = "normal"
    private var lastPasteboardChangeCount = 0
    private var lastRemoteClipboardText: String?
    private var pasteboardTimer: DispatchSourceTimer?
    private let pasteboardLock = NSLock()
    private let pasteboardQueue = DispatchQueue(label: "stacio.rdp.pasteboard")

    // adapterExecutablePath is retained for API compatibility with the
    // process-based factory, but the embedded IronRDP client runs in-process
    // and ignores it.
    public convenience init(
        options: EmbeddedRDPSessionOptions,
        adapterExecutablePath: String,
        appLog: StacioLogWriting? = StacioLogStore.shared
    ) {
        self.init(
            options: options,
            adapterExecutablePath: adapterExecutablePath,
            appLog: appLog,
            frameClock: { ProcessInfo.processInfo.systemUptime }
        )
    }

    init(
        options: EmbeddedRDPSessionOptions,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?,
        frameClock: @escaping () -> TimeInterval,
        rdpSessionFactory: @escaping () -> any RdpSessionProtocol = { RdpSession() }
    ) {
        self.options = options
        self.appLog = appLog
        self.frameClock = frameClock
        self.rdpSessionFactory = rdpSessionFactory
        self.lastWidth = options.width
        self.lastHeight = options.height
        let adaptiveQualityState = RDPAdaptiveQualityState(desiredQuality: options.quality)
        self.adaptiveQualityState = adaptiveQualityState
        self.currentMaxFps = adaptiveQualityState.effectiveMaxFPS
    }

    public func start() throws {
        guard options.security != .rdp else {
            throw EmbeddedRDPGraphicsSessionError.unsupportedLegacySecurity
        }
        guard options.width > 0,
              options.height > 0,
              options.width <= Self.maximumDesktopDimension,
              options.height <= Self.maximumDesktopDimension else {
            throw EmbeddedRDPGraphicsSessionError.unsupportedDesktopSize(
                options.width,
                options.height
            )
        }
        let validatedDrive = try Self.validateDrive(options.drive)

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let session = rdpSessionFactory()

        stateLock.lock()
        let previousSession = rdpSession
        connectionGeneration &+= 1
        if connectionGeneration == 0 {
            connectionGeneration = 1
        }
        let generation = connectionGeneration
        let bridge = RDPDelegateBridge(owner: self, generation: generation)
        rdpSession = session
        delegate = bridge
        isStopped = false
        hasConnected = false
        lifecycleStateValue = .connecting
        latestFrameValue = nil
        frameCanvas = Data()
        frameCanvasWidth = 0
        frameCanvasHeight = 0
        lastDeliveredFrameTime = nil
        adaptiveQualityState = RDPAdaptiveQualityState(desiredQuality: options.quality)
        currentMaxFps = adaptiveQualityState.effectiveMaxFPS
        networkMode = "normal"
        lastRemoteClipboardText = nil
        buttonMask = 0
        stateLock.unlock()

        // Invalidate the old delegate before asking the previous transport to
        // close, so a late disconnect/frame cannot stop or overwrite the new
        // connection that is about to start.
        previousSession?.close()

        appLog?.append(
            level: .info,
            category: "Graphics",
            message: "rdp.session.connecting host=\(options.host):\(options.port) embedded=ironrdp"
        )

        let security: RdpSecurityMode
        switch options.security {
        case .nla:
            security = .nla
        case .tls:
            security = .tls
        case .rdp:
            throw EmbeddedRDPGraphicsSessionError.unsupportedLegacySecurity
        }

        session.connect(
            host: options.host,
            port: options.port,
            username: options.user,
            password: options.password,
            domain: options.domain,
            width: UInt16(clamping: options.width),
            height: UInt16(clamping: options.height),
            quality: UInt8(clamping: options.quality),
            security: security,
            ignoreCertificate: options.ignoreCert,
            driveName: validatedDrive?.name,
            drivePath: validatedDrive?.localPath,
            delegate: bridge
        )
    }

    static func validateDrive(_ rawDrive: String?) throws -> ValidatedRDPDrive? {
        guard let rawDrive else { return nil }
        guard let separator = rawDrive.firstIndex(of: ":") else {
            throw EmbeddedRDPGraphicsSessionError.invalidDriveFormat
        }

        let name = rawDrive[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pathStart = rawDrive.index(after: separator)
        let rawPath = rawDrive[pathStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw EmbeddedRDPGraphicsSessionError.emptyDriveName
        }
        let scalars = name.unicodeScalars
        let isSafeName = scalars.count <= 32
            && scalars.contains(where: Self.isASCIIAlphanumeric)
            && scalars.allSatisfy { scalar in
                Self.isASCIIAlphanumeric(scalar)
                    || scalar == " "
                    || scalar == "."
                    || scalar == "_"
                    || scalar == "-"
            }
        guard isSafeName else {
            throw EmbeddedRDPGraphicsSessionError.unsafeDriveName
        }
        guard !rawPath.isEmpty else {
            throw EmbeddedRDPGraphicsSessionError.emptyDrivePath
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDirectory) else {
            throw EmbeddedRDPGraphicsSessionError.missingDriveDirectory(rawPath)
        }
        guard isDirectory.boolValue else {
            throw EmbeddedRDPGraphicsSessionError.drivePathIsNotDirectory(rawPath)
        }

        let canonicalPath = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return ValidatedRDPDrive(name: name, localPath: canonicalPath)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    public func stop() {
        lifecycleLock.lock()
        stateLock.lock()
        let alreadyStopped = isStopped
        isStopped = true
        let connected = hasConnected
        connectionGeneration &+= 1
        if connectionGeneration == 0 {
            connectionGeneration = 1
        }
        let session = rdpSession
        rdpSession = nil
        delegate = nil
        clipboardSynchronizationEnabledValue = false
        buttonMask = 0
        if !alreadyStopped {
            lifecycleStateValue = .disconnected(reason: "会话已停止")
        }
        stateLock.unlock()

        guard !alreadyStopped else {
            lifecycleLock.unlock()
            return
        }

        stopPasteboardMonitor()
        session?.close()
        lifecycleLock.unlock()
        if !connected {
            onDisconnected?("会话已停止")
        }
    }

    public func setClipboardSynchronizationEnabled(_ enabled: Bool) {
        stateLock.lock()
        let changed = clipboardSynchronizationEnabledValue != enabled
        clipboardSynchronizationEnabledValue = enabled
        let active = isStopped == false
        stateLock.unlock()

        guard changed else { return }
        stateLock.lock()
        let hasSession = rdpSession != nil
        stateLock.unlock()
        if enabled, active, hasSession {
            startPasteboardMonitor()
        } else {
            stopPasteboardMonitor()
        }
    }

    public func sendInput(_ event: GraphicsInputEvent) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.lock()
        guard isStopped == false, let session = rdpSession else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        switch event {
        case .resize(let width, let height, _):
            guard width > 0,
                  height > 0,
                  width <= Self.maximumDesktopDimension,
                  height <= Self.maximumDesktopDimension else { return }
            stateLock.lock()
            lastWidth = width
            lastHeight = height
            stateLock.unlock()
            session.requestResize(width: UInt32(clamping: width), height: UInt32(clamping: height))
        case .mouseMoved(let x, let y):
            session.sendPointer(x: UInt32(clamping: x), y: UInt32(clamping: y), buttons: currentButtonMask())
        case .mouseButton(let button, let isPressed, let x, let y):
            updateButtonMask(button: button, isPressed: isPressed)
            session.sendPointer(x: UInt32(clamping: x), y: UInt32(clamping: y), buttons: currentButtonMask())
        case .scroll(let deltaX, let deltaY, _, _):
            if deltaY != 0 {
                session.sendScroll(delta: Int32(clamping: deltaY), horizontal: false)
            }
            if deltaX != 0 {
                session.sendScroll(delta: Int32(clamping: deltaX), horizontal: true)
            }
        case .key(let scancode, let isExtended, let isPressed):
            // ironrdp-input represents an E0-prefixed PC scancode as
            // 0xE000 | code. Preserve the render surface's extended-key bit
            // so arrows, navigation keys and right-side modifiers are not
            // interpreted as their non-extended keypad/control variants.
            let encodedScancode = UInt32(scancode) | (isExtended ? 0xE000 : 0)
            session.sendKey(scancode: encodedScancode, down: isPressed)
        case .unicodeText(let text):
            for scalar in text.unicodeScalars {
                let character = String(scalar)
                session.sendUnicode(character: character, down: true)
                session.sendUnicode(character: character, down: false)
            }
        case .clipboardTextPaste(let text):
            guard text.utf16.count <= Self.maximumClipboardUTF16CodeUnits else { return }
            session.sendClipboardText(text: text)
        case .quality(let level):
            stateLock.lock()
            let changed = adaptiveQualityState.setDesiredQuality(level)
            currentMaxFps = adaptiveQualityState.effectiveMaxFPS
            let effectiveQuality = adaptiveQualityState.effectiveQuality
            stateLock.unlock()
            if changed {
                session.setQuality(quality: UInt8(clamping: effectiveQuality))
            }
        case .close:
            session.close()
        case .fileDrop:
            // Not supported by the embedded IronRDP client.
            break
        }
    }

    // MARK: - 鼠标按键状态跟踪

    private var buttonMask: UInt32 = 0

    private func currentButtonMask() -> UInt32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return buttonMask
    }

    private func updateButtonMask(button: GraphicsMouseButton, isPressed: Bool) {
        let bit: UInt32
        switch button {
        case .left: bit = 0b001
        case .right: bit = 0b010
        case .middle: bit = 0b100
        case .x1: bit = 0b1_000
        case .x2: bit = 0b10_000
        }
        if bit == 0 { return }
        stateLock.lock()
        if isPressed {
            buttonMask |= bit
        } else {
            buttonMask &= ~bit
        }
        stateLock.unlock()
    }

    // MARK: - Delegate 回调（来自 Rust 后台线程）
    //
    // 与 VNC session 对齐：回调直接触发，线程切换由消费者
    // （GraphicsSessionPaneViewController）负责。会话状态统一经 stateLock 保护。

    func handleFrame(
        width: Int,
        height: Int,
        bgra: Data,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        handleFrame(
            desktopWidth: width,
            desktopHeight: height,
            width: width,
            height: height,
            bgra: bgra,
            connectionGeneration: expectedGeneration
        )
    }

    func handleFrame(
        desktopWidth: Int,
        desktopHeight: Int,
        x: Int = 0,
        y: Int = 0,
        width: Int,
        height: Int,
        bgra: Data,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        guard let desktopLayout = Self.frameLayout(
                  width: desktopWidth,
                  height: desktopHeight
              ),
              Self.framePatchFitsCanvas(
                  x: x,
                  y: y,
                  width: width,
                  height: height,
                  canvasWidth: desktopWidth,
                  canvasHeight: desktopHeight
              ),
              let patchLayout = Self.frameLayout(width: width, height: height),
              bgra.count == patchLayout.byteCount else { return }

        let now = frameClock()
        stateLock.lock()
        guard isStopped == false,
              expectedGeneration.map({ $0 == connectionGeneration }) ?? true else {
            stateLock.unlock()
            return
        }

        if frameCanvasWidth != desktopWidth || frameCanvasHeight != desktopHeight {
            frameCanvas = Data(repeating: 0, count: desktopLayout.byteCount)
            frameCanvasWidth = desktopWidth
            frameCanvasHeight = desktopHeight
        }
        frameCanvas.withUnsafeMutableBytes { canvasBytes in
            bgra.withUnsafeBytes { patchBytes in
                guard let canvasBase = canvasBytes.baseAddress,
                      let patchBase = patchBytes.baseAddress else { return }
                for row in 0..<height {
                    let destinationOffset = (y + row) * desktopLayout.bytesPerRow + x * 4
                    let sourceOffset = row * patchLayout.bytesPerRow
                    canvasBase.advanced(by: destinationOffset).copyMemory(
                        from: patchBase.advanced(by: sourceOffset),
                        byteCount: patchLayout.bytesPerRow
                    )
                }
            }
        }

        // 帧率限制必须以最后实际提交的帧为基准。若用最后收到的帧，稳定 60fps
        // 输入在 30fps 上限下会不断刷新时间戳，从而永久丢弃后续帧。
        let minInterval = 1.0 / Double(currentMaxFps)
        if let lastDeliveredFrameTime,
           now - lastDeliveredFrameTime < minInterval
        {
            stateLock.unlock()
            return
        }
        lastDeliveredFrameTime = now

        let frame = GraphicsFrame(
            width: desktopWidth,
            height: desktopHeight,
            bytesPerRow: desktopLayout.bytesPerRow,
            pixelFormat: .bgra8Unorm,
            pixels: Self.snapshot(frameCanvas)
        )

        let sizeChanged = (desktopWidth != lastWidth || desktopHeight != lastHeight)
        let firstFrame = !hasConnected
        if sizeChanged {
            lastWidth = desktopWidth
            lastHeight = desktopHeight
        }
        if firstFrame {
            hasConnected = true
        }
        if firstFrame || sizeChanged {
            lifecycleStateValue = .connected(
                width: desktopWidth,
                height: desktopHeight,
                name: "RDP Desktop"
            )
        }
        latestFrameValue = frame
        stateLock.unlock()

        guard isActiveConnection(expectedGeneration) else { return }

        // 首帧即连接成功信号；后续尺寸变化（Display Control 协商结果）只更新
        // 状态，不重复触发 onConnected（避免面板误判为重连）。
        if firstFrame {
            appLog?.append(
                level: .info,
                category: "Graphics",
                message: "rdp.session.connected \(desktopWidth)x\(desktopHeight)"
            )
            onConnected?(desktopWidth, desktopHeight, "RDP Desktop")
        }

        onFrame?(frame)
    }

    private static func frameLayout(
        width: Int,
        height: Int
    ) -> (bytesPerRow: Int, byteCount: Int)? {
        guard width > 0,
              height > 0,
              width <= maximumDesktopDimension,
              height <= maximumDesktopDimension else { return nil }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !countOverflow else { return nil }
        return (bytesPerRow, byteCount)
    }

    private static func framePatchFitsCanvas(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> Bool {
        guard x >= 0,
              y >= 0,
              width > 0,
              height > 0,
              width <= canvasWidth,
              height <= canvasHeight else { return false }
        return x <= canvasWidth - width && y <= canvasHeight - height
    }

    fileprivate func handlePointerVisibility(
        _ visible: Bool,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        guard isActiveConnection(expectedGeneration) else { return }
        onPointerVisibilityChanged?(visible)
    }

    fileprivate func handlePointerPosition(
        x: Int,
        y: Int,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        guard isActiveConnection(expectedGeneration) else { return }
        onPointerPosition?(x, y)
    }

    fileprivate func handlePointerBitmap(
        width: Int,
        height: Int,
        hotspotX: Int,
        hotspotY: Int,
        rgba: Data,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        let maximumRGBABytes = 4 * 1024 * 1024
        let maximumPixels = maximumRGBABytes / 4
        guard isActiveConnection(expectedGeneration),
              width > 0,
              height > 0,
              width <= maximumPixels,
              height <= maximumPixels / width,
              hotspotX >= 0,
              hotspotY >= 0,
              hotspotX < width,
              hotspotY < height,
              rgba.count == width * height * 4 else { return }

        onPointerBitmap?(
            GraphicsPointerBitmap(
                width: width,
                height: height,
                hotspotX: hotspotX,
                hotspotY: hotspotY,
                rgbaPixels: rgba
            )
        )
    }

    fileprivate func handleClipboard(
        _ text: String,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        stateLock.lock()
        guard isStopped == false,
              clipboardSynchronizationEnabledValue,
              expectedGeneration.map({ $0 == connectionGeneration }) ?? true else {
            stateLock.unlock()
            return
        }
        lastRemoteClipboardText = text
        stateLock.unlock()
        guard isActiveConnection(expectedGeneration) else { return }
        onClipboard?(text)
    }

    fileprivate func handleNetworkStatus(
        rttMs: Int,
        mode: String,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        guard mode == "normal" || mode == "poor" || mode == "very_poor" else { return }

        stateLock.lock()
        guard isStopped == false,
              expectedGeneration.map({ $0 == connectionGeneration }) ?? true else {
            stateLock.unlock()
            return
        }
        networkMode = mode
        let qualityChanged = adaptiveQualityState.applyNetworkMode(mode)
        currentMaxFps = adaptiveQualityState.effectiveMaxFPS
        let effectiveQuality = adaptiveQualityState.effectiveQuality
        let session = qualityChanged ? rdpSession : nil
        stateLock.unlock()

        session?.setQuality(quality: UInt8(clamping: effectiveQuality))

        guard isActiveConnection(expectedGeneration) else { return }
        onNetworkStatus?(rttMs, mode)
    }

    fileprivate func handleDisconnected(
        _ reason: String,
        connectionGeneration expectedGeneration: UInt64? = nil
    ) {
        stateLock.lock()
        guard isStopped == false,
              expectedGeneration.map({ $0 == connectionGeneration }) ?? true else {
            stateLock.unlock()
            return
        }
        isStopped = true
        clipboardSynchronizationEnabledValue = false
        lifecycleStateValue = .disconnected(reason: reason)
        stateLock.unlock()
        stopPasteboardMonitor()
        appLog?.append(level: .info, category: "Graphics", message: "rdp.session.disconnected reason=\(reason)")
        onDisconnected?(reason)
    }

    // MARK: - 剪贴板同步（Mac → Windows）

    private func startPasteboardMonitor() {
        stopPasteboardMonitor()
        let initialChangeCount = generalPasteboardSnapshot().changeCount
        let timer = DispatchSource.makeTimerSource(queue: pasteboardQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.checkPasteboard()
        }

        pasteboardLock.lock()
        lastPasteboardChangeCount = initialChangeCount
        pasteboardTimer = timer
        pasteboardLock.unlock()
        timer.resume()

        if sessionIsActive == false {
            stopPasteboardMonitor()
        }
    }

    private func stopPasteboardMonitor() {
        pasteboardLock.lock()
        let timer = pasteboardTimer
        pasteboardTimer = nil
        pasteboardLock.unlock()
        timer?.cancel()
    }

    private func checkPasteboard() {
        guard sessionIsActive, isClipboardSynchronizationEnabled else { return }
        let snapshot = generalPasteboardSnapshot()
        pasteboardLock.lock()
        let didChange = snapshot.changeCount != lastPasteboardChangeCount
        if didChange {
            lastPasteboardChangeCount = snapshot.changeCount
        }
        pasteboardLock.unlock()
        guard didChange,
              let text = snapshot.text,
              !text.isEmpty,
              text.utf16.count <= Self.maximumClipboardUTF16CodeUnits else { return }

        stateLock.lock()
        let originatedRemotely = lastRemoteClipboardText == text
        lastRemoteClipboardText = nil
        stateLock.unlock()
        guard !originatedRemotely,
              sessionIsActive,
              isClipboardSynchronizationEnabled else { return }

        lifecycleLock.lock()
        stateLock.lock()
        let session = isStopped ? nil : rdpSession
        stateLock.unlock()
        session?.sendClipboardText(text: text)
        lifecycleLock.unlock()
    }

    // MARK: - 弱网自适应（RDP）

    private static func snapshot(_ data: Data) -> Data {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress, bytes.isEmpty == false else {
                return Data()
            }
            return Data(bytes: baseAddress, count: bytes.count)
        }
    }

    private var sessionIsActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStopped == false
    }


    private func isActiveConnection(_ expectedGeneration: UInt64?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStopped == false
            && (expectedGeneration.map { $0 == connectionGeneration } ?? true)
    }
}

// MARK: - RDP Delegate 桥接（Rust -> Swift）

private final class RDPDelegateBridge: RdpSessionDelegate, @unchecked Sendable {
    private weak var owner: EmbeddedRDPGraphicsSession?
    private let generation: UInt64

    init(owner: EmbeddedRDPGraphicsSession, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    func onFrame(
        desktopWidth: UInt32,
        desktopHeight: UInt32,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        bgra: Data
    ) {
        owner?.handleFrame(
            desktopWidth: Int(desktopWidth),
            desktopHeight: Int(desktopHeight),
            x: Int(x),
            y: Int(y),
            width: Int(width),
            height: Int(height),
            bgra: bgra,
            connectionGeneration: generation
        )
    }

    func onPointerVisibility(visible: Bool) {
        owner?.handlePointerVisibility(visible, connectionGeneration: generation)
    }

    func onPointerPosition(x: UInt32, y: UInt32) {
        owner?.handlePointerPosition(
            x: Int(x),
            y: Int(y),
            connectionGeneration: generation
        )
    }

    func onPointerBitmap(
        width: UInt32,
        height: UInt32,
        hotspotX: UInt32,
        hotspotY: UInt32,
        rgba: Data
    ) {
        owner?.handlePointerBitmap(
            width: Int(width),
            height: Int(height),
            hotspotX: Int(hotspotX),
            hotspotY: Int(hotspotY),
            rgba: rgba,
            connectionGeneration: generation
        )
    }

    func onClipboard(text: String) {
        owner?.handleClipboard(text, connectionGeneration: generation)
    }

    func onNetworkStatus(rttMs: UInt32, mode: String) {
        owner?.handleNetworkStatus(
            rttMs: Int(rttMs),
            mode: mode,
            connectionGeneration: generation
        )
    }

    func onDisconnected(reason: String) {
        owner?.handleDisconnected(reason, connectionGeneration: generation)
    }
}

// MARK: - RDP 会话工厂

public protocol EmbeddedRDPGraphicsSessionFactory: AnyObject {
    func makeSession(
        options: EmbeddedRDPSessionOptions,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?
    ) -> EmbeddedGraphicsSessionLifecycle
}

public final class DefaultEmbeddedRDPGraphicsSessionFactory: EmbeddedRDPGraphicsSessionFactory {
    public init() {}

    public func makeSession(
        options: EmbeddedRDPSessionOptions,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?
    ) -> EmbeddedGraphicsSessionLifecycle {
        EmbeddedRDPGraphicsSession(
            options: options,
            adapterExecutablePath: adapterExecutablePath,
            appLog: appLog
        )
    }
}

public enum GraphicsRuntimeAttachmentKind: Equatable {
    case embeddedGraphics
}

public final class GraphicsRuntimeAttachment: Equatable {
    public let runtimeID: String
    public let kind: GraphicsRuntimeAttachmentKind
    public let session: EmbeddedGraphicsSession

    public init(runtimeID: String, kind: GraphicsRuntimeAttachmentKind, session: EmbeddedGraphicsSession) {
        self.runtimeID = runtimeID
        self.kind = kind
        self.session = session
    }

    public static func == (lhs: GraphicsRuntimeAttachment, rhs: GraphicsRuntimeAttachment) -> Bool {
        lhs.runtimeID == rhs.runtimeID && lhs.kind == rhs.kind
    }
}
