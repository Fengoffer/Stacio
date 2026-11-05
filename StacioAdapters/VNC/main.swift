import Darwin
import Foundation
import ImageIO
import CoreGraphics
import CommonCrypto
import Compression
import StacioVNCAdapterCore

// Stacio VNC 适配器：独立进程，通过 stdout/stdin JSON Lines 与主进程通信。
// 协议见 docs/remote-desktop-agent-brief.md §三。
// 实现：RFB 3.3/3.7/3.8 握手 + VNC Password(DES) + Tight/ZRLE/Zlib/Hextile/Raw 编码 +
//       JPEG 帧输出 + 键鼠/剪贴板/resize/quality 输入 + ClientFence RTT 监测。
enum StacioVNCAdapter {
    fileprivate struct LaunchOptions: Equatable {
        let target: VNCConnectionTarget
        let password: String?
        let quality: Int        // 1-10
        let maxFps: Int
    }

    fileprivate struct ServerDesktopInfo: Equatable {
        let width: UInt16
        let height: UInt16
        let name: String
        let bytesPerRow: Int
        let byteCount: Int
    }

    fileprivate enum AdapterError: Error, LocalizedError {
        case io(String)
        case protocolFailure(String)

        var errorDescription: String? {
            switch self {
            case .io(let reason): return reason
            case .protocolFailure(let reason): return reason
            }
        }
    }

    // MARK: - 入口

    static func main(arguments: [String] = CommandLine.arguments) -> Int32 {
        guard let options = parseArguments(arguments) else {
            emitError("VNC 适配器参数无效。用法：[--password <密码>] [--quality 1-10] [--max-fps N] host:port")
            return 64
        }
        let stdinReader = StdinLineReader()
        let jpegEncoder = JpegEncoder()
        let adapter = VNCSession(options: options, stdinReader: stdinReader, jpegEncoder: jpegEncoder)
        return adapter.run()
    }

    // MARK: - 参数解析

    private static func parseArguments(_ arguments: [String]) -> LaunchOptions? {
        // Prefer the environment so credentials do not appear in the process list.
        var password = ProcessInfo.processInfo.environment["STACIO_VNC_PASSWORD"]
        var quality = 7
        var maxFps = 30
        var targetValue: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--password" || argument == "-p" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else { return nil }
                // Keep the command-line flag for compatibility with older launchers.
                if password == nil {
                    password = arguments[valueIndex]
                }
                index += 2
                continue
            }
            if argument == "--quality" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count, let value = Int(arguments[valueIndex]) else { return nil }
                quality = max(1, min(10, value))
                index += 2
                continue
            }
            if argument == "--max-fps" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count, let value = Int(arguments[valueIndex]) else { return nil }
                maxFps = max(1, min(60, value))
                index += 2
                continue
            }
            guard targetValue == nil else { return nil }
            targetValue = argument
            index += 1
        }
        guard let targetValue,
              let target = VNCConnectionTargetParser.parse(targetValue) else {
            return nil
        }
        return LaunchOptions(target: target, password: password, quality: quality, maxFps: maxFps)
    }

    // MARK: - stdout JSON 输出

    static func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func emitError(_ message: String) {
        emit(["type": "error", "message": message])
    }
}

// MARK: - stdin 非阻塞行读取

private final class StdinLineReader {
    private static let maximumLineBytes = 2 * 1024 * 1024
    private let queue = DispatchQueue(label: "stacio.vnc.stdin")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var discardingOversizedLine = false
    private var pendingHandler: ((String) -> Void)?

    func start(handler: @escaping (String) -> Void) {
        guard source == nil else { return }
        pendingHandler = handler

        // stdin 设为非阻塞，由 DispatchSourceRead 驱动
        let fd = STDIN_FILENO
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        pendingHandler = nil
    }

    private func drain() {
        let fd = STDIN_FILENO
        var localBuffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &localBuffer, localBuffer.count)
            if count > 0 {
                consume(localBuffer[0..<count])
                continue
            }
            break
        }
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if discardingOversizedLine {
                if byte == 0x0A {
                    discardingOversizedLine = false
                }
                continue
            }

            if byte == 0x0A {
                if let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                    pendingHandler?(line)
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }

            guard buffer.count < Self.maximumLineBytes else {
                buffer.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                continue
            }
            buffer.append(byte)
        }
    }
}

// MARK: - RFB Zlib 持续流解码

private final class ZlibStreamDecoder {
    private let placeholder: UnsafeMutablePointer<UInt8>
    private var stream: compression_stream
    private var isInitialized = false
    private var needsZlibHeader = true
    private var hasEnded = false

    init() {
        placeholder = .allocate(capacity: 1)
        placeholder.initialize(to: 0)
        stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        isInitialized = compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        ) != COMPRESSION_STATUS_ERROR
    }

    deinit {
        if isInitialized {
            compression_stream_destroy(&stream)
        }
        placeholder.deinitialize(count: 1)
        placeholder.deallocate()
    }

    func reset() {
        if isInitialized {
            compression_stream_destroy(&stream)
        }
        stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        isInitialized = compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        ) != COMPRESSION_STATUS_ERROR
        needsZlibHeader = true
        hasEnded = false
    }

    func decode(_ data: [UInt8], expectedOutputCount: Int) -> [UInt8]? {
        guard let output = decode(data, maximumOutputCount: expectedOutputCount),
              output.count == expectedOutputCount else { return nil }
        return output
    }

    func decode(_ data: [UInt8], maximumOutputCount: Int) -> [UInt8]? {
        guard isInitialized, !hasEnded, !data.isEmpty, maximumOutputCount > 0 else { return nil }

        var inputOffset = 0
        if needsZlibHeader {
            guard data.count >= 2 else { return nil }
            let compressionMethodAndInfo = data[0]
            let flags = data[1]
            let header = (UInt16(compressionMethodAndInfo) << 8) | UInt16(flags)
            guard compressionMethodAndInfo & 0x0F == 8,
                  compressionMethodAndInfo >> 4 <= 7,
                  header % 31 == 0,
                  flags & 0x20 == 0 else { return nil }
            inputOffset = 2
        }
        guard inputOffset < data.count else { return nil }

        // The extra byte detects a decompression bomb that exceeds the caller's
        // geometry-derived upper bound while still consuming Z_SYNC_FLUSH bytes.
        var output = [UInt8](repeating: 0, count: maximumOutputCount + 1)
        var streamEnded = false
        let consumedAllInput = output.withUnsafeMutableBufferPointer { outputBuffer in
            data.withUnsafeBufferPointer { inputBuffer in
                guard let outputBase = outputBuffer.baseAddress,
                      let inputBase = inputBuffer.baseAddress else { return false }

                stream.dst_ptr = outputBase
                stream.dst_size = outputBuffer.count
                stream.src_ptr = inputBase.advanced(by: inputOffset)
                stream.src_size = inputBuffer.count - inputOffset

                while true {
                    let previousSourceSize = stream.src_size
                    let previousDestinationSize = stream.dst_size
                    let status = compression_stream_process(&stream, 0)
                    if status == COMPRESSION_STATUS_ERROR {
                        return false
                    }
                    if stream.src_size == 0 {
                        streamEnded = status == COMPRESSION_STATUS_END
                        return true
                    }
                    if status == COMPRESSION_STATUS_END || stream.dst_size == 0 {
                        return false
                    }
                    if stream.src_size == previousSourceSize,
                       stream.dst_size == previousDestinationSize {
                        return false
                    }
                }
            }
        }

        let produced = output.count - stream.dst_size
        guard consumedAllInput, produced <= maximumOutputCount else { return nil }
        needsZlibHeader = false
        hasEnded = streamEnded
        return Array(output.prefix(produced))
    }
}

// MARK: - JPEG 编码

private final class JpegEncoder {
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
    )

    /// 把 BGRA8 像素数据编码为 JPEG，返回 base64 字符串。失败返回 nil。
    func encodeBGRAToJPEGBase64(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        quality: Int
    ) -> String? {
        guard width > 0, height > 0, bytesPerRow > 0,
              pixels.count >= bytesPerRow * height else { return nil }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        guard let provider,
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return encodeImage(cgImage, quality: quality)
    }

    func encodeImage(_ image: CGImage, quality: Int) -> String? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        let jpegQuality = Self.jpegQuality(for: quality) as CFNumber
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData.base64EncodedString()
    }

    func decodeJPEGToBGRA(
        _ data: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width,
              image.height == height else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let created = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                          | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? pixels : nil
    }

    static func jpegQuality(for adapterQuality: Int) -> CGFloat {
        switch adapterQuality {
        case 10: return 0.90
        case 9: return 0.85
        case 8: return 0.80
        case 7: return 0.75
        case 6: return 0.70
        case 5: return 0.55
        case 4: return 0.45
        case 3: return 0.38
        case 2: return 0.30
        default: return 0.25
        }
    }
}

// MARK: - VNC 会话主循环

private final class VNCSession {
    private static let maximumDesktopDimension = 8_192
    private static let maximumFramebufferRectangles = 8_192
    private static let maximumRectangleBytes = 64 * 1024 * 1024
    private static let maximumClipboardBytes = 1_048_576
    private static let maximumExtendedClipboardWireBytes = maximumClipboardBytes + 65_536

    private let options: StacioVNCAdapter.LaunchOptions
    private let stdinReader: StdinLineReader
    private let jpegEncoder: JpegEncoder
    private var socketDescriptor: Int32 = -1
    private var desktop: StacioVNCAdapter.ServerDesktopInfo?
    private var canvas: [UInt8] = []        // 当前完整桌面 BGRA 像素
    private var canvasWidth: Int = 0
    private var canvasHeight: Int = 0
    private var canvasBytesPerRow: Int = 0
    private var lastFramebufferRequestTime: TimeInterval = -.infinity
    private var framebufferRequestOutstanding = false
    private var adaptiveQualityState: VNCAdaptiveQualityState
    private var serverSupportsExtendedDesktopSize = false
    private var serverSupportsFence = false
    private var pendingDesktopResize: (width: UInt16, height: UInt16)?
    private var serverClipboardFlags: UInt32 = 0
    private var serverMaximumUnsolicitedTextBytes: UInt32 = 0
    private var latestLocalClipboardText: String?
    private let rttMonitor = VNCFenceRTTMonitor(clock: {
        ProcessInfo.processInfo.systemUptime
    })
    private let zlibDecoder = ZlibStreamDecoder()
    private let zrleDecoder = ZlibStreamDecoder()
    private let tightZlibDecoders = (0..<4).map { _ in ZlibStreamDecoder() }
    private var shouldStop = false
    private let stateLock = NSLock()
    private let ioLock = NSLock()           // 保护 socket 读写（stdin 事件可能与帧循环并发）

    init(options: StacioVNCAdapter.LaunchOptions,
         stdinReader: StdinLineReader,
         jpegEncoder: JpegEncoder) {
        self.options = options
        self.stdinReader = stdinReader
        self.jpegEncoder = jpegEncoder
        self.adaptiveQualityState = VNCAdaptiveQualityState(
            desiredQuality: options.quality,
            configuredMaxFPS: options.maxFps
        )
    }

    func run() -> Int32 {
        switch StacioVNCAdapter.connectTCP(host: options.target.host, port: options.target.port, timeoutSeconds: 6) {
        case .failure(let reason):
            StacioVNCAdapter.emitError("VNC 连接失败：\(reason)")
            return 69
        case .success(let descriptor):
            socketDescriptor = descriptor
        }
        defer { close(socketDescriptor) }

        let info: StacioVNCAdapter.ServerDesktopInfo
        do {
            info = try performHandshake()
        } catch {
            StacioVNCAdapter.emitError("VNC 握手失败：\(error.localizedDescription)")
            return 69
        }
        desktop = info
        canvasWidth = Int(info.width)
        canvasHeight = Int(info.height)
        canvasBytesPerRow = info.bytesPerRow
        canvas = [UInt8](repeating: 0, count: info.byteCount)

        StacioVNCAdapter.emit([
            "type": "connected",
            "width": Int(info.width),
            "height": Int(info.height),
            "name": info.name
        ])

        do {
            try sendFramebufferUpdateRequest(incremental: false)
            stdinReader.start { [weak self] line in
                self?.handleStdinLine(line)
            }
            defer { stdinReader.stop() }
            try runFrameLoop()
        } catch {
            StacioVNCAdapter.emit([
                "type": "disconnected",
                "reason": error.localizedDescription
            ])
            return 0
        }
        StacioVNCAdapter.emit(["type": "disconnected", "reason": "会话结束"])
        return 0
    }

    // MARK: - RFB 握手（复用既有逻辑）

    private func performHandshake() throws -> StacioVNCAdapter.ServerDesktopInfo {
        let socket = socketDescriptor
        let serverVersionBytes = try StacioVNCAdapter.readExact(socket: socket, count: 12)
        guard let serverVersion = String(bytes: serverVersionBytes, encoding: .ascii),
              StacioVNCAdapter.isValidRFBVersion(serverVersion) else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("服务端不是 RFB/VNC 协议")
        }
        guard let negotiatedVersion = StacioVNCAdapter.negotiatedProtocolVersion(for: serverVersion) else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("服务端 RFB 版本 \(serverVersion.trimmingCharacters(in: .newlines)) 不支持")
        }
        try StacioVNCAdapter.writeAll(socket: socket, bytes: Array(negotiatedVersion.utf8))

        let shouldReadSecurityResult: Bool
        if negotiatedVersion == "RFB 003.003\n" {
            let rawSecurityType = try StacioVNCAdapter.readUInt32(socket: socket)
            switch rawSecurityType {
            case 1:
                shouldReadSecurityResult = false
            case 2:
                guard let password = options.password, !password.isEmpty else {
                    throw StacioVNCAdapter.AdapterError.protocolFailure("服务端要求 VNC 密码认证，但未提供密码")
                }
                try StacioVNCAdapter.authenticateVNCPassword(socket: socket, password: password)
                shouldReadSecurityResult = true
            case 0:
                let reason = try StacioVNCAdapter.readSecurityFailureReason(socket: socket)
                throw StacioVNCAdapter.AdapterError.protocolFailure(reason.isEmpty ? "服务端拒绝安全协商" : "服务端拒绝：\(reason)")
            default:
                throw StacioVNCAdapter.AdapterError.protocolFailure("不支持的安全类型：\(rawSecurityType)")
            }
        } else {
            let securityTypeCount = try StacioVNCAdapter.readExact(socket: socket, count: 1)[0]
            guard securityTypeCount > 0 else {
                let reason = try StacioVNCAdapter.readSecurityFailureReason(socket: socket)
                throw StacioVNCAdapter.AdapterError.protocolFailure(reason.isEmpty ? "服务端拒绝安全协商" : "服务端拒绝：\(reason)")
            }
            let securityTypes = try StacioVNCAdapter.readExact(socket: socket, count: Int(securityTypeCount))
            if let password = options.password,
               password.isEmpty == false,
               securityTypes.contains(2) {
                try StacioVNCAdapter.writeAll(socket: socket, bytes: [2])
                try StacioVNCAdapter.authenticateVNCPassword(socket: socket, password: password)
                shouldReadSecurityResult = true
            } else if securityTypes.contains(1) {
                try StacioVNCAdapter.writeAll(socket: socket, bytes: [1])
                shouldReadSecurityResult = negotiatedVersion != "RFB 003.007\n"
            } else if securityTypes.contains(2) {
                throw StacioVNCAdapter.AdapterError.protocolFailure("服务端要求 VNC 密码认证，但未提供密码")
            } else {
                let offered = securityTypes.map(String.init).joined(separator: ",")
                throw StacioVNCAdapter.AdapterError.protocolFailure("不支持的安全类型：\(offered)")
            }
        }

        if shouldReadSecurityResult {
            let securityResult = try StacioVNCAdapter.readUInt32(socket: socket)
            guard securityResult == 0 else {
                let reason = negotiatedVersion == "RFB 003.008\n"
                    ? (try? StacioVNCAdapter.readSecurityFailureReason(socket: socket)) ?? ""
                    : ""
                throw StacioVNCAdapter.AdapterError.protocolFailure(
                    reason.isEmpty ? "安全协商失败，状态码：\(securityResult)" : "安全协商失败：\(reason)"
                )
            }
        }

        // ClientInit（共享标志=1）
        try StacioVNCAdapter.writeAll(socket: socket, bytes: [1])

        let width = try StacioVNCAdapter.readUInt16(socket: socket)
        let height = try StacioVNCAdapter.readUInt16(socket: socket)
        let layout = try Self.canvasLayout(width: Int(width), height: Int(height))
        let pixelFormat = try StacioVNCAdapter.readExact(socket: socket, count: 16)
        let nameLength = try StacioVNCAdapter.readUInt32(socket: socket)
        guard nameLength <= 16_384 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("ServerInit 名称过长：\(nameLength)")
        }
        let nameBytes = try StacioVNCAdapter.readExact(socket: socket, count: Int(nameLength))
        let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .ascii) ?? "VNC 桌面"

        // 强制设置 BGRA8 像素格式（与主进程渲染层一致）
        try setBGRAPixelFormat(currentFormat: pixelFormat)
        // 按压缩效率排序，Raw 只作为所有服务端都能理解的最终兜底。
        try setEncodings(quality: currentState().quality)

        return StacioVNCAdapter.ServerDesktopInfo(
            width: width,
            height: height,
            name: name,
            bytesPerRow: layout.bytesPerRow,
            byteCount: layout.byteCount
        )
    }

    private func setBGRAPixelFormat(currentFormat: [UInt8]) throws {
        // 若服务端已是目标格式则跳过
        if currentFormat.count >= 16,
           currentFormat[0] == 32, currentFormat[1] == 24,
           currentFormat[2] == 0, currentFormat[3] == 1,
           currentFormat[4] == 0, currentFormat[5] == 255,
           currentFormat[6] == 0, currentFormat[7] == 255,
           currentFormat[8] == 0, currentFormat[9] == 255,
           currentFormat[10] == 16, currentFormat[11] == 8, currentFormat[12] == 0 {
            return
        }
        // SetPixelFormat: 0, padding(3), bpp=32, depth=24, bigEndian=0, trueColor=1,
        // redMax=255, greenMax=255, blueMax=255, redShift=16, greenShift=8, blueShift=0, padding(3)
        let payload: [UInt8] = [
            0, 0, 0, 0,
            32, 24, 0, 1,
            0, 255, 0, 255, 0, 255,
            16, 8, 0,
            0, 0, 0
        ]
        try StacioVNCAdapter.writeAll(socket: socketDescriptor, bytes: payload)
    }

    private func setEncodings(quality: Int) throws {
        // SetEncodings: 2, padding, count, encodings...
        let encodings = VNCEncodingNegotiation.encodings(forQuality: quality)
        var payload: [UInt8] = [2, 0]
        payload += StacioVNCAdapter.bigEndianBytes(UInt16(encodings.count))
        for encoding in encodings {
            payload += StacioVNCAdapter.bigEndianBytes(UInt32(bitPattern: encoding))
        }
        try StacioVNCAdapter.writeAll(socket: socketDescriptor, bytes: payload)
    }

    private func sendEncodingPreferences(quality: Int) {
        let encodings = VNCEncodingNegotiation.encodings(forQuality: quality)
        var payload: [UInt8] = [2, 0]
        payload += StacioVNCAdapter.bigEndianBytes(UInt16(encodings.count))
        for encoding in encodings {
            payload += StacioVNCAdapter.bigEndianBytes(UInt32(bitPattern: encoding))
        }
        sendPayload(payload)
    }

    // MARK: - 帧循环

    private func runFrameLoop() throws {
        rttMonitor.start { [weak self] rttMs, mode in
            guard let self else { return }
            StacioVNCAdapter.emit([
                "type": "network",
                "rtt_ms": rttMs,
                "mode": mode
            ])
            self.adjustQualityForNetworkMode(mode)
        }

        while isStopped == false {
            let stateBeforePoll = currentState()
            let pollTimeoutMicroseconds = VNCFrameLoopTiming.pollTimeoutMicroseconds(
                framebufferRequestOutstanding: framebufferRequestOutstanding,
                lastFramebufferRequestTime: lastFramebufferRequestTime,
                now: ProcessInfo.processInfo.systemUptime,
                maxFPS: stateBeforePoll.maxFps
            )
            if try processServerMessages(timeoutMicroseconds: pollTimeoutMicroseconds) {
                framebufferRequestOutstanding = false
            }

            if framebufferRequestOutstanding == false {
                let now = ProcessInfo.processInfo.systemUptime
                let minInterval = 1.0 / Double(currentState().maxFps)
                if now - lastFramebufferRequestTime >= minInterval {
                    try sendFramebufferUpdateRequest(incremental: true)
                }
            }

            if fenceIsSupported,
               let fenceProbe = rttMonitor.tick() {
                sendPayload(fenceProbe.wireBytes)
            }
        }
    }

    @discardableResult
    private func processServerMessages(timeoutMicroseconds: Int) throws -> Bool {
        // 处理当前可读的服务端消息；超时与下一次帧请求截止时间对齐。
        var readSet = fd_set()
        StacioVNCAdapter.fdSet(socketDescriptor, set: &readSet)
        var timeout = timeval(
            tv_sec: 0,
            tv_usec: Int32(clamping: timeoutMicroseconds)
        )
        let ready = select(socketDescriptor + 1, &readSet, nil, nil, &timeout)
        if ready < 0 {
            if errno == EINTR { return false }
            throw StacioVNCAdapter.AdapterError.io(StacioVNCAdapter.posixDescription(errno))
        }
        if ready == 0 { return false }

        var receivedFramebufferUpdate = false

        while true {
            // 继续用 select 探测是否有更多数据，避免阻塞
            var probe = fd_set()
            StacioVNCAdapter.fdSet(socketDescriptor, set: &probe)
            var probeTimeout = timeval(tv_sec: 0, tv_usec: 0)
            if select(socketDescriptor + 1, &probe, nil, nil, &probeTimeout) <= 0 {
                return receivedFramebufferUpdate
            }
            receivedFramebufferUpdate = try readAndDispatchMessage() || receivedFramebufferUpdate
        }
    }

    private func readAndDispatchMessage() throws -> Bool {
        let messageType = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0]
        switch messageType {
        case 0:  // FramebufferUpdate
            try handleFramebufferUpdate()
            return true
        case 1:  // SetColourMapEntries
            _ = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1) // padding
            _ = try StacioVNCAdapter.readUInt16(socket: socketDescriptor) // first colour
            let count = try StacioVNCAdapter.readUInt16(socket: socketDescriptor)
            _ = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: Int(count) * 6)
            return false
        case 2:  // Bell
            return false
        case 3:  // ServerCutText
            try handleServerCutText()
            return false
        case 248: // Fence
            try handleFenceMessage()
            return false
        default:
            // 未知消息，跳过剩余不可知；为安全起见终止
            throw StacioVNCAdapter.AdapterError.protocolFailure("未知服务端消息类型：\(messageType)")
        }
    }

    private func handleFramebufferUpdate() throws {
        _ = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1) // padding
        let rectangleCount = try StacioVNCAdapter.readUInt16(socket: socketDescriptor)
        let usesLastRectSentinel = rectangleCount == UInt16.max
        guard Int(rectangleCount) <= Self.maximumFramebufferRectangles || usesLastRectSentinel else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("矩形数量过多：\(rectangleCount)")
        }

        var dirtyRectangles: [(x: Int, y: Int, w: Int, h: Int)] = []
        var parsedRectangleCount = 0
        var sawLastRect = false
        let maximumHeaders = usesLastRectSentinel
            ? Self.maximumFramebufferRectangles + 1
            : Int(rectangleCount)
        rectangleLoop: while parsedRectangleCount < maximumHeaders {
            parsedRectangleCount += 1
            let x = Int(try StacioVNCAdapter.readUInt16(socket: socketDescriptor))
            let y = Int(try StacioVNCAdapter.readUInt16(socket: socketDescriptor))
            let w = Int(try StacioVNCAdapter.readUInt16(socket: socketDescriptor))
            let h = Int(try StacioVNCAdapter.readUInt16(socket: socketDescriptor))
            let encoding = try StacioVNCAdapter.readInt32(socket: socketDescriptor)

            switch encoding {
            case 0, 5, 6, 7, 16:
                try validateFramebufferRectangle(x: x, y: y, width: w, height: h)
            default:
                break
            }

            switch encoding {
            case 0: // Raw
                try readRawRectangle(x: x, y: y, width: w, height: h)
                if w > 0 && h > 0 { dirtyRectangles.append((x, y, w, h)) }
            case 7: // Tight
                try readTightRectangle(x: x, y: y, width: w, height: h)
                if w > 0 && h > 0 { dirtyRectangles.append((x, y, w, h)) }
            case 16: // ZRLE
                try readZRLERectangle(x: x, y: y, width: w, height: h)
                if w > 0 && h > 0 { dirtyRectangles.append((x, y, w, h)) }
            case 6: // Zlib
                try readZlibRectangle(x: x, y: y, width: w, height: h)
                if w > 0 && h > 0 { dirtyRectangles.append((x, y, w, h)) }
            case 5: // Hextile
                try readHextileRectangle(x: x, y: y, width: w, height: h)
                if w > 0 && h > 0 { dirtyRectangles.append((x, y, w, h)) }
            case -223: // DesktopSize
                try applyDesktopResize(width: w, height: h)
            case -308: // ExtendedDesktopSize
                try readExtendedDesktopSizeScreenRecords()
                recordExtendedDesktopSizeSupport()
                if y == 0 {
                    try applyDesktopResize(width: w, height: h)
                }
            case -224: // LastRect
                sawLastRect = true
                break rectangleLoop
            case -239: // Cursor
                try readCursorRectangle(
                    width: w,
                    height: h,
                    hotspotX: x,
                    hotspotY: y
                )
            case -232: // CursorPosition
                // 无 payload
                StacioVNCAdapter.emit([
                    "type": "pointer_position",
                    "x": x,
                    "y": y
                ])
            default:
                throw StacioVNCAdapter.AdapterError.protocolFailure("不支持的编码：\(encoding)")
            }

            if usesLastRectSentinel,
               parsedRectangleCount > Self.maximumFramebufferRectangles {
                throw StacioVNCAdapter.AdapterError.protocolFailure(
                    "LastRect 更新在 \(Self.maximumFramebufferRectangles) 个矩形内未终止"
                )
            }
        }

        if usesLastRectSentinel, !sawLastRect {
            throw StacioVNCAdapter.AdapterError.protocolFailure("LastRect 更新缺少终止矩形")
        }

        if !dirtyRectangles.isEmpty {
            flushDirtyRectangles(dirtyRectangles)
        }
    }

    private func readRawRectangle(x: Int, y: Int, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { return }
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height
        guard totalBytes <= 64 * 1024 * 1024 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("Raw 矩形过大：\(totalBytes)")
        }
        let pixels = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: totalBytes)
        blitToCanvas(pixels: pixels, x: x, y: y, width: width, height: height, srcBytesPerRow: bytesPerRow)
    }

    private func readZlibRectangle(x: Int, y: Int, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { return }
        let expected = width * 4 * height
        guard expected <= 64 * 1024 * 1024 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("Zlib 矩形过大：\(expected)")
        }
        let length = Int(try StacioVNCAdapter.readUInt32(socket: socketDescriptor))
        guard length > 0, length <= 64 * 1024 * 1024 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("Zlib 数据长度无效：\(length)")
        }
        let compressed = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: length)
        guard let inflated = zlibDecoder.decode(compressed, expectedOutputCount: expected) else {
            throw StacioVNCAdapter.AdapterError.io("Zlib 解压失败")
        }
        blitToCanvas(pixels: inflated, x: x, y: y, width: width, height: height, srcBytesPerRow: width * 4)
    }

    private func readZRLERectangle(x: Int, y: Int, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { return }
        let expectedBGRABytes = try Self.rectangleByteCount(width: width, height: height)
        guard expectedBGRABytes <= Self.maximumRectangleBytes else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "ZRLE 矩形过大：\(expectedBGRABytes)"
            )
        }
        let compressedLength = Int(try StacioVNCAdapter.readUInt32(socket: socketDescriptor))
        guard compressedLength > 0, compressedLength <= Self.maximumRectangleBytes else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "ZRLE 数据长度无效：\(compressedLength)"
            )
        }
        let compressed = try StacioVNCAdapter.readExact(
            socket: socketDescriptor,
            count: compressedLength
        )
        let maximumDecodedBytes = try Self.maximumZRLEDecodedByteCount(
            width: width,
            height: height
        )
        guard let decoded = zrleDecoder.decode(
            compressed,
            maximumOutputCount: maximumDecodedBytes
        ) else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("ZRLE 解压失败")
        }
        do {
            let pixels = try VNCZRLETileDecoder.decode(
                data: decoded,
                width: width,
                height: height
            )
            blitToCanvas(
                pixels: pixels,
                x: x,
                y: y,
                width: width,
                height: height,
                srcBytesPerRow: width * 4
            )
        } catch {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "ZRLE 解码失败：\(error.localizedDescription)"
            )
        }
    }

    private func readTightRectangle(x: Int, y: Int, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { return }
        let expectedBGRABytes = try Self.rectangleByteCount(width: width, height: height)
        guard expectedBGRABytes <= Self.maximumRectangleBytes else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Tight 矩形过大：\(expectedBGRABytes)"
            )
        }

        let control = try StacioVNCAdapter.readExact(
            socket: socketDescriptor,
            count: 1
        )[0]
        for streamIndex in 0..<tightZlibDecoders.count where control & (1 << UInt8(streamIndex)) != 0 {
            tightZlibDecoders[streamIndex].reset()
        }

        let compressionMode = control >> 4
        // TigerVNC 1.15 and earlier could emit wide Fill rectangles even
        // though the Tight basic/JPEG width limit is 2048 pixels. Fill has a
        // fixed three-byte payload, so accept it after the geometry bound.
        guard compressionMode == 8 || width <= 2_048 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Tight 矩形宽度超过 2048：\(width)"
            )
        }
        switch compressionMode {
        case 8: // Fill
            let rgb = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 3)
            fillCanvas(
                x: x,
                y: y,
                width: width,
                height: height,
                color: [rgb[2], rgb[1], rgb[0], 0xFF]
            )

        case 9: // JPEG
            let length = try readTightCompactLength()
            guard length > 0, length <= Self.maximumRectangleBytes else {
                throw StacioVNCAdapter.AdapterError.protocolFailure(
                    "Tight JPEG 数据长度无效：\(length)"
                )
            }
            let jpeg = try StacioVNCAdapter.readExact(
                socket: socketDescriptor,
                count: length
            )
            guard let pixels = jpegEncoder.decodeJPEGToBGRA(
                jpeg,
                width: width,
                height: height
            ) else {
                throw StacioVNCAdapter.AdapterError.protocolFailure("Tight JPEG 解码失败")
            }
            blitToCanvas(
                pixels: pixels,
                x: x,
                y: y,
                width: width,
                height: height,
                srcBytesPerRow: width * 4
            )

        case 0...7, 10, 14:
            try readTightBasicRectangle(
                x: x,
                y: y,
                width: width,
                height: height,
                compressionMode: compressionMode
            )

        default:
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Tight 子编码无效：\(compressionMode)"
            )
        }
    }

    private func readTightBasicRectangle(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        compressionMode: UInt8
    ) throws {
        let usesNoZlib = compressionMode == 10 || compressionMode == 14
        let hasExplicitFilter = compressionMode & 0x04 != 0
        let filterID = hasExplicitFilter
            ? try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0]
            : 0

        let filter: VNCTightPixelFilter
        let filteredByteCount: Int
        let pixelCount = width * height
        switch filterID {
        case 0:
            filter = .copy
            filteredByteCount = pixelCount * 3

        case 1:
            let paletteSize = Int(
                try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0]
            ) + 1
            guard (2...256).contains(paletteSize) else {
                throw StacioVNCAdapter.AdapterError.protocolFailure(
                    "Tight 调色板大小无效：\(paletteSize)"
                )
            }
            let paletteBytes = try StacioVNCAdapter.readExact(
                socket: socketDescriptor,
                count: paletteSize * 3
            )
            var colors: [VNCRGBColor] = []
            colors.reserveCapacity(paletteSize)
            for index in 0..<paletteSize {
                colors.append(
                    VNCRGBColor(
                        red: paletteBytes[index * 3],
                        green: paletteBytes[index * 3 + 1],
                        blue: paletteBytes[index * 3 + 2]
                    )
                )
            }
            filter = .palette(colors: colors)
            filteredByteCount = paletteSize == 2
                ? ((width + 7) / 8) * height
                : pixelCount

        case 2:
            filter = .gradient
            filteredByteCount = pixelCount * 3

        default:
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Tight 过滤器无效：\(filterID)"
            )
        }

        guard filteredByteCount > 0, filteredByteCount <= Self.maximumRectangleBytes else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Tight 过滤后数据大小无效：\(filteredByteCount)"
            )
        }

        let filtered: [UInt8]
        if filteredByteCount < 12 {
            filtered = try StacioVNCAdapter.readExact(
                socket: socketDescriptor,
                count: filteredByteCount
            )
        } else {
            let encodedLength = try readTightCompactLength()
            guard encodedLength > 0, encodedLength <= Self.maximumRectangleBytes else {
                throw StacioVNCAdapter.AdapterError.protocolFailure(
                    "Tight 数据长度无效：\(encodedLength)"
                )
            }
            let encoded = try StacioVNCAdapter.readExact(
                socket: socketDescriptor,
                count: encodedLength
            )
            if usesNoZlib {
                guard encoded.count == filteredByteCount else {
                    throw StacioVNCAdapter.AdapterError.protocolFailure(
                        "Tight 未压缩数据长度不匹配"
                    )
                }
                filtered = encoded
            } else {
                let streamIndex = Int(compressionMode & 0x03)
                guard let decoded = tightZlibDecoders[streamIndex].decode(
                    encoded,
                    expectedOutputCount: filteredByteCount
                ) else {
                    throw StacioVNCAdapter.AdapterError.protocolFailure(
                        "Tight zlib 流 \(streamIndex) 解压失败"
                    )
                }
                filtered = decoded
            }
        }

        do {
            let pixels = try VNCTightPixelDecoder.decode(
                data: filtered,
                width: width,
                height: height,
                filter: filter
            )
            blitToCanvas(
                pixels: pixels,
                x: x,
                y: y,
                width: width,
                height: height,
                srcBytesPerRow: width * 4
            )
        } catch {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Tight 解码失败：\(error.localizedDescription)"
            )
        }
    }

    private func readTightCompactLength() throws -> Int {
        var bytes = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)
        if bytes[0] & 0x80 != 0 {
            bytes += try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)
            if bytes[1] & 0x80 != 0 {
                bytes += try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)
            }
        }
        return try VNCTightCompactLength.decodePrefix(bytes).length
    }

    private func readHextileRectangle(x: Int, y: Int, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { return }
        let bytesPerPixel = 4
        let expectedBytes = try Self.rectangleByteCount(width: width, height: height)
        guard expectedBytes <= Self.maximumRectangleBytes else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Hextile 矩形过大：\(expectedBytes)"
            )
        }
        var background = [UInt8](repeating: 0, count: bytesPerPixel)
        var foreground = [UInt8](repeating: 0, count: bytesPerPixel)
        var rowTop = 0
        while rowTop < height {
            let tileHeight = min(16, height - rowTop)
            var colLeft = 0
            while colLeft < width {
                let tileWidth = min(16, width - colLeft)
                let subencoding = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0]
                guard subencoding & 0xE0 == 0 else {
                    throw StacioVNCAdapter.AdapterError.protocolFailure(
                        "Hextile 子编码包含保留位：0x\(String(subencoding, radix: 16, uppercase: true))"
                    )
                }

                if subencoding & 0x01 != 0 {
                    // RawTile
                    let tileBytes = tileWidth * tileHeight * bytesPerPixel
                    let pixels = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: tileBytes)
                    blitToCanvas(pixels: pixels, x: x + colLeft, y: y + rowTop,
                                 width: tileWidth, height: tileHeight, srcBytesPerRow: tileWidth * bytesPerPixel)
                } else {
                    if subencoding & 0x02 != 0 {
                        background = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: bytesPerPixel)
                    }
                    if subencoding & 0x04 != 0 {
                        foreground = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: bytesPerPixel)
                    }
                    fillCanvas(x: x + colLeft, y: y + rowTop, width: tileWidth, height: tileHeight, color: background)
                    if subencoding & 0x08 != 0 {
                        let subrectCount = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0]
                        for _ in 0..<subrectCount {
                            let color: [UInt8]
                            if subencoding & 0x10 != 0 {
                                color = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: bytesPerPixel)
                            } else {
                                color = foreground
                            }
                            let packed = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 2)
                            let sx = Int(packed[0] >> 4)
                            let sy = Int(packed[0] & 0x0F)
                            let swidth = Int(packed[1] >> 4) + 1
                            let sheight = Int(packed[1] & 0x0F) + 1
                            guard sx + swidth <= tileWidth,
                                  sy + sheight <= tileHeight else {
                                throw StacioVNCAdapter.AdapterError.protocolFailure(
                                    "Hextile 子矩形越界"
                                )
                            }
                            fillCanvas(x: x + colLeft + sx, y: y + rowTop + sy,
                                       width: swidth, height: sheight, color: color)
                        }
                    }
                }
                colLeft += 16
            }
            rowTop += 16
        }
    }

    private func readCursorRectangle(
        width: Int,
        height: Int,
        hotspotX: Int,
        hotspotY: Int
    ) throws {
        // Cursor 伪编码：width*height*4 像素 + width*height*1 位掩码
        if width == 0, height == 0 {
            StacioVNCAdapter.emit([
                "type": "pointer_visibility",
                "visible": false
            ])
            return
        }
        let pixelBytes = width * height * 4
        guard pixelBytes > 0, pixelBytes <= 4 * 1024 * 1024 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("Cursor 位图尺寸无效：\(width)x\(height)")
        }
        let bgra = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: pixelBytes)
        let maskBytesPerRow = (width + 7) / 8
        let mask = try StacioVNCAdapter.readExact(
            socket: socketDescriptor,
            count: maskBytesPerRow * height
        )

        guard hotspotX >= 0, hotspotY >= 0,
              hotspotX < width, hotspotY < height else { return }

        var rgba = [UInt8](repeating: 0, count: pixelBytes)
        for row in 0..<height {
            for column in 0..<width {
                let pixelOffset = (row * width + column) * 4
                rgba[pixelOffset] = bgra[pixelOffset + 2]
                rgba[pixelOffset + 1] = bgra[pixelOffset + 1]
                rgba[pixelOffset + 2] = bgra[pixelOffset]
                let maskByte = mask[row * maskBytesPerRow + column / 8]
                let isVisible = maskByte & (0x80 >> UInt8(column % 8)) != 0
                rgba[pixelOffset + 3] = isVisible ? 0xFF : 0x00
            }
        }

        StacioVNCAdapter.emit([
            "type": "pointer_bitmap",
            "width": width,
            "height": height,
            "hotspot_x": hotspotX,
            "hotspot_y": hotspotY,
            "data": Data(rgba).base64EncodedString()
        ])
    }

    private func readExtendedDesktopSizeScreenRecords() throws {
        let screenCount = Int(try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0])
        _ = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 3)
        for _ in 0..<screenCount {
            _ = try StacioVNCAdapter.readUInt32(socket: socketDescriptor) // screen ID
            _ = try StacioVNCAdapter.readUInt16(socket: socketDescriptor) // x
            _ = try StacioVNCAdapter.readUInt16(socket: socketDescriptor) // y
            _ = try StacioVNCAdapter.readUInt16(socket: socketDescriptor) // width
            _ = try StacioVNCAdapter.readUInt16(socket: socketDescriptor) // height
            _ = try StacioVNCAdapter.readUInt32(socket: socketDescriptor) // flags
        }
    }

    private func handleServerCutText() throws {
        _ = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 3) // padding
        let rawLength = try StacioVNCAdapter.readUInt32(socket: socketDescriptor)
        if rawLength & 0x8000_0000 != 0 {
            let length = Int((~rawLength) &+ 1)
            guard length >= 4,
                  length <= Self.maximumExtendedClipboardWireBytes else {
                throw StacioVNCAdapter.AdapterError.protocolFailure(
                    "Extended Clipboard 数据长度无效：\(length)"
                )
            }
            let payload = try StacioVNCAdapter.readExact(
                socket: socketDescriptor,
                count: length
            )
            try handleExtendedServerCutText(payload)
            return
        }

        guard rawLength <= UInt32(Self.maximumClipboardBytes) else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "剪贴板文本过长：\(rawLength)"
            )
        }
        let bytes = try StacioVNCAdapter.readExact(
            socket: socketDescriptor,
            count: Int(rawLength)
        )
        // RFB 3.x 的标准 CutText 固定为 ISO-8859-1；UTF-8 只能走
        // Extended Clipboard，不能靠“先尝试 UTF-8”猜测。
        let text = VNCExtendedClipboardCodec.latin1String(from: bytes)
        StacioVNCAdapter.emit([
            "type": "clipboard",
            "text": text
        ])
    }

    private func handleExtendedServerCutText(_ payload: [UInt8]) throws {
        let message: VNCExtendedClipboardMessage
        do {
            message = try VNCExtendedClipboardCodec.decode(
                payload: payload,
                maximumTextBytes: Self.maximumClipboardBytes
            )
        } catch {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "Extended Clipboard 消息无效：\(error)"
            )
        }

        switch message.action {
        case .capabilities:
            stateLock.lock()
            serverClipboardFlags = message.flags
            serverMaximumUnsolicitedTextBytes = message.maximumTextBytes ?? 0
            let latestText = latestLocalClipboardText
            stateLock.unlock()

            sendExtendedClipboardPayload(
                VNCExtendedClipboardCodec.capabilitiesPayload(
                    maximumTextBytes: UInt32(Self.maximumClipboardBytes)
                )
            )
            if let latestText {
                sendClipboardText(latestText, allowStandardFallback: false)
            }

        case .notify:
            guard message.flags & VNCExtendedClipboardCodec.textFlag != 0,
                  serverSupportsClipboardAction(VNCExtendedClipboardCodec.requestFlag) else { return }
            sendExtendedClipboardPayload(VNCExtendedClipboardCodec.requestPayload())

        case .request:
            guard message.flags & VNCExtendedClipboardCodec.textFlag != 0 else { return }
            stateLock.lock()
            let latestText = latestLocalClipboardText
            stateLock.unlock()
            if let latestText {
                sendExtendedClipboardProvide(latestText)
            }

        case .peek:
            stateLock.lock()
            let hasText = latestLocalClipboardText != nil
            stateLock.unlock()
            guard serverSupportsClipboardAction(VNCExtendedClipboardCodec.notifyFlag) else { return }
            sendExtendedClipboardPayload(
                VNCExtendedClipboardCodec.notifyPayload(hasText: hasText)
            )

        case .provide:
            if let text = message.text {
                StacioVNCAdapter.emit([
                    "type": "clipboard",
                    "text": text
                ])
            }
        }
    }

    private func handleFenceMessage() throws {
        _ = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 3)
        let flags = try StacioVNCAdapter.readUInt32(socket: socketDescriptor)
        let length = Int(try StacioVNCAdapter.readExact(socket: socketDescriptor, count: 1)[0])
        guard length <= 64 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure("Fence payload 过长：\(length)")
        }
        let payload = try StacioVNCAdapter.readExact(socket: socketDescriptor, count: length)

        stateLock.lock()
        serverSupportsFence = true
        stateLock.unlock()

        let requestFlag: UInt32 = 0x8000_0000
        if flags & requestFlag != 0 {
            let responseFlags = flags & ~requestFlag
            let response: [UInt8] = [248, 0, 0, 0]
                + StacioVNCAdapter.bigEndianBytes(responseFlags)
                + [UInt8(payload.count)]
                + payload
            sendPayload(response)
        } else {
            rttMonitor.onFenceResponse(payload: payload)
        }
    }

    // MARK: - 画布操作

    private func validateFramebufferRectangle(
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        guard canvasWidth > 0,
              canvasHeight > 0,
              width > 0,
              height > 0,
              x >= 0,
              y >= 0,
              x < canvasWidth,
              y < canvasHeight,
              width <= canvasWidth - x,
              height <= canvasHeight - y else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "帧缓冲矩形越界：(\(x),\(y)) \(width)x\(height)，画布 \(canvasWidth)x\(canvasHeight)"
            )
        }
    }

    private func blitToCanvas(pixels: [UInt8], x: Int, y: Int, width: Int, height: Int, srcBytesPerRow: Int) {
        guard canvas.isEmpty == false,
              x >= 0, y >= 0,
              x + width <= canvasWidth,
              y + height <= canvasHeight else { return }
        let dstBytesPerRow = canvasBytesPerRow
        for row in 0..<height {
            let srcOffset = row * srcBytesPerRow
            let dstOffset = (y + row) * dstBytesPerRow + x * 4
            let copyLength = min(width * 4, srcBytesPerRow, dstBytesPerRow - x * 4)
            guard srcOffset + copyLength <= pixels.count,
                  dstOffset + copyLength <= canvas.count else { continue }
            canvas.replaceSubrange(dstOffset..<(dstOffset + copyLength), with: pixels[srcOffset..<(srcOffset + copyLength)])
        }
    }

    private func fillCanvas(x: Int, y: Int, width: Int, height: Int, color: [UInt8]) {
        guard color.count >= 4,
              width > 0,
              height > 0,
              x >= 0,
              y >= 0,
              x <= canvasWidth,
              y <= canvasHeight,
              width <= canvasWidth - x,
              height <= canvasHeight - y else { return }
        var coloredRow = [UInt8](repeating: 0, count: width * 4)
        for col in 0..<width {
            coloredRow[col * 4] = color[0]
            coloredRow[col * 4 + 1] = color[1]
            coloredRow[col * 4 + 2] = color[2]
            coloredRow[col * 4 + 3] = color[3]
        }
        for rowIdx in 0..<height {
            let dstOffset = (y + rowIdx) * canvasBytesPerRow + x * 4
            guard dstOffset + coloredRow.count <= canvas.count else { break }
            canvas.replaceSubrange(dstOffset..<(dstOffset + coloredRow.count), with: coloredRow)
        }
    }

    private func applyDesktopResize(width: Int, height: Int) throws {
        let layout = try Self.canvasLayout(width: width, height: height)
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
        StacioVNCAdapter.emit([
            "type": "resize",
            "width": width,
            "height": height
        ])
    }

    private static func canvasLayout(
        width: Int,
        height: Int
    ) throws -> (bytesPerRow: Int, byteCount: Int) {
        guard width > 0,
              height > 0,
              width <= maximumDesktopDimension,
              height <= maximumDesktopDimension else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "桌面尺寸超出支持范围：\(width)x\(height)"
            )
        }
        let bytesPerRow = try rectangleByteCount(width: width, height: 1)
        let byteCount = try rectangleByteCount(width: width, height: height)
        return (bytesPerRow, byteCount)
    }

    private static func rectangleByteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "矩形尺寸无效：\(width)x\(height)"
            )
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "矩形尺寸溢出：\(width)x\(height)"
            )
        }
        return byteCount
    }

    private static func maximumZRLEDecodedByteCount(
        width: Int,
        height: Int
    ) throws -> Int {
        let bgraByteCount = try rectangleByteCount(width: width, height: height)
        let pixelCount = bgraByteCount / 4
        let tileColumns = (width + 63) / 64
        let tileRows = (height + 63) / 64
        let (tileCount, tileOverflow) = tileColumns.multipliedReportingOverflow(by: tileRows)
        let (paletteOverhead, paletteOverflow) = tileCount.multipliedReportingOverflow(by: 382)
        let (paletteRLEBytes, paletteTotalOverflow) = pixelCount.addingReportingOverflow(
            paletteOverhead
        )
        let (plainRLEBytes, plainOverflow) = bgraByteCount.addingReportingOverflow(tileCount)
        guard tileOverflow == false,
              paletteOverflow == false,
              paletteTotalOverflow == false,
              plainOverflow == false else {
            throw StacioVNCAdapter.AdapterError.protocolFailure(
                "ZRLE 解码大小溢出：\(width)x\(height)"
            )
        }
        return max(paletteRLEBytes, plainRLEBytes)
    }

    private func flushDirtyRectangles(_ rectangles: [(x: Int, y: Int, w: Int, h: Int)]) {
        guard canvas.isEmpty == false, canvasWidth > 0, canvasHeight > 0 else { return }
        let quality = currentState().quality

        // 若脏区域覆盖大部分画面，发送整帧
        let totalDirty = rectangles.reduce(0) { $0 + $1.w * $1.h }
        let totalCanvas = canvasWidth * canvasHeight
        if totalDirty * 4 >= totalCanvas * 3 {
            // 整帧
            if let base64 = jpegEncoder.encodeBGRAToJPEGBase64(
                pixels: canvas,
                width: canvasWidth,
                height: canvasHeight,
                bytesPerRow: canvasBytesPerRow,
                quality: quality
            ) {
                StacioVNCAdapter.emit([
                    "type": "frame",
                    "x": 0,
                    "y": 0,
                    "w": canvasWidth,
                    "h": canvasHeight,
                    "encoding": "jpeg",
                    "data": base64
                ])
            }
            return
        }

        // 增量矩形。同一 FramebufferUpdate 的补丁全部编码完后再输出，最后一个
        // 标记 batch_end，让 App 只创建一次完整画布快照。
        var patchPayloads: [[String: Any]] = []
        for rect in rectangles {
            guard rect.x >= 0, rect.y >= 0,
                  rect.x + rect.w <= canvasWidth,
                  rect.y + rect.h <= canvasHeight,
                  rect.w > 0, rect.h > 0 else { continue }
            let patchBytesPerRow = rect.w * 4
            var patch = [UInt8](repeating: 0, count: patchBytesPerRow * rect.h)
            for row in 0..<rect.h {
                let srcOffset = (rect.y + row) * canvasBytesPerRow + rect.x * 4
                let dstOffset = row * patchBytesPerRow
                guard srcOffset + patchBytesPerRow <= canvas.count,
                      dstOffset + patchBytesPerRow <= patch.count else { continue }
                patch.replaceSubrange(dstOffset..<(dstOffset + patchBytesPerRow),
                                      with: canvas[srcOffset..<(srcOffset + patchBytesPerRow)])
            }
            guard let base64 = jpegEncoder.encodeBGRAToJPEGBase64(
                pixels: patch,
                width: rect.w,
                height: rect.h,
                bytesPerRow: patchBytesPerRow,
                quality: quality
            ) else { continue }
            patchPayloads.append([
                "type": "frame_patch",
                "x": rect.x,
                "y": rect.y,
                "w": rect.w,
                "h": rect.h,
                "encoding": "jpeg",
                "data": base64
            ])
        }
        for index in patchPayloads.indices {
            patchPayloads[index]["batch_end"] = index == patchPayloads.index(before: patchPayloads.endIndex)
            StacioVNCAdapter.emit(patchPayloads[index])
        }
    }

    // MARK: - 请求

    private func sendFramebufferUpdateRequest(incremental: Bool) throws {
        // FramebufferUpdateRequest: 3, incremental(1), x(2), y(2), w(2), h(2)
        let width = min(UInt16(canvasWidth), UInt16.max)
        let height = min(UInt16(canvasHeight), UInt16.max)
        let payload: [UInt8] = [
            3,
            incremental ? 1 : 0,
            0, 0,
            0, 0
        ] + StacioVNCAdapter.bigEndianBytes(width) + StacioVNCAdapter.bigEndianBytes(height)
        ioLock.lock()
        defer { ioLock.unlock() }
        try StacioVNCAdapter.writeAll(socket: socketDescriptor, bytes: payload)
        lastFramebufferRequestTime = ProcessInfo.processInfo.systemUptime
        framebufferRequestOutstanding = true
    }

    // MARK: - stdin 事件处理

    private func handleStdinLine(_ line: String) {
        guard isStopped == false,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "key":
            handleKeyEvent(json)
        case "pointer":
            handlePointerEvent(json)
        case "clipboard":
            handleClipboardEvent(json)
        case "resize_request":
            handleResizeRequest(json)
        case "quality":
            handleQualityEvent(json)
        case "close":
            stateLock.lock()
            shouldStop = true
            stateLock.unlock()
        default:
            break
        }
    }

    private func handleKeyEvent(_ json: [String: Any]) {
        guard let keysym = json["keysym"] as? Int,
              let rfbKeysym = UInt32(exactly: keysym),
              let down = json["down"] as? Bool else { return }
        // KeyEvent: 4, down(1), padding(2), keysym(4)
        let payload: [UInt8] = [
            4,
            down ? 1 : 0,
            0, 0
        ] + StacioVNCAdapter.bigEndianBytes(rfbKeysym)
        sendPayload(payload)
    }

    private func handlePointerEvent(_ json: [String: Any]) {
        guard let x = json["x"] as? Int,
              let y = json["y"] as? Int,
              let buttons = json["buttons"] as? Int else { return }
        let mask = UInt8(min(255, max(0, buttons)))
        sendPointerEvent(mask: mask, x: x, y: y)

        let vertical = Self.scrollStep(from: json["scroll_dy"])
        let horizontal = Self.scrollStep(from: json["scroll_dx"])
        if vertical != 0 {
            let wheelMask: UInt8 = vertical > 0 ? 0x08 : 0x10
            sendPointerEvent(mask: mask | wheelMask, x: x, y: y)
            sendPointerEvent(mask: mask, x: x, y: y)
        }
        if horizontal != 0 {
            let wheelMask: UInt8 = horizontal < 0 ? 0x20 : 0x40
            sendPointerEvent(mask: mask | wheelMask, x: x, y: y)
            sendPointerEvent(mask: mask, x: x, y: y)
        }
    }

    private func sendPointerEvent(mask: UInt8, x: Int, y: Int) {
        // PointerEvent: 5, buttonMask(1), x(2), y(2)
        let payload: [UInt8] = [5, mask]
            + StacioVNCAdapter.bigEndianBytes(UInt16(clamped: x))
            + StacioVNCAdapter.bigEndianBytes(UInt16(clamped: y))
        sendPayload(payload)
    }

    private static func scrollStep(from value: Any?) -> Int {
        if let value = value as? Int {
            return value == 0 ? 0 : (value > 0 ? 1 : -1)
        }
        if let value = value as? Double {
            return value == 0 ? 0 : (value > 0 ? 1 : -1)
        }
        return 0
    }

    private func handleClipboardEvent(_ json: [String: Any]) {
        guard let text = json["text"] as? String else { return }
        guard text.utf8.count <= Self.maximumClipboardBytes else { return }
        stateLock.lock()
        latestLocalClipboardText = text
        stateLock.unlock()
        sendClipboardText(text, allowStandardFallback: true)
    }

    private func sendClipboardText(_ text: String, allowStandardFallback: Bool) {
        let serverSupportsText = serverSupportsClipboardFormat(
            VNCExtendedClipboardCodec.textFlag
        )
        let serverSupportsProvide = serverSupportsClipboardAction(
            VNCExtendedClipboardCodec.provideFlag
        )
        if serverSupportsText, serverSupportsProvide {
            if serverSupportsClipboardAction(VNCExtendedClipboardCodec.notifyFlag) {
                sendExtendedClipboardPayload(
                    VNCExtendedClipboardCodec.notifyPayload(hasText: true)
                )
            }

            stateLock.lock()
            let maximumUnsolicited = serverMaximumUnsolicitedTextBytes
            stateLock.unlock()
            if maximumUnsolicited == 0 || text.utf8.count < Int(maximumUnsolicited) {
                sendExtendedClipboardProvide(text)
                return
            }

            // The server advertised a smaller unsolicited limit. Notify is
            // sufficient; it can request the full value explicitly.
            if serverSupportsClipboardAction(VNCExtendedClipboardCodec.notifyFlag) {
                return
            }
        }

        guard allowStandardFallback else { return }
        let bytes = VNCExtendedClipboardCodec.latin1Bytes(for: text)
        guard bytes.count <= Self.maximumClipboardBytes else { return }
        let payload: [UInt8] = [6, 0, 0, 0]
            + StacioVNCAdapter.bigEndianBytes(UInt32(bytes.count))
            + bytes
        sendPayload(payload)
    }

    private func sendExtendedClipboardProvide(_ text: String) {
        guard let payload = try? VNCExtendedClipboardCodec.providePayload(
            text: text,
            maximumTextBytes: Self.maximumClipboardBytes
        ) else { return }
        sendExtendedClipboardPayload(payload)
    }

    private func sendExtendedClipboardPayload(_ payload: [UInt8]) {
        guard let wireMessage = try? VNCExtendedClipboardCodec.clientCutTextMessage(
            extendedPayload: payload
        ) else { return }
        sendPayload(wireMessage)
    }

    private func serverSupportsClipboardAction(_ action: UInt32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return serverClipboardFlags & action != 0
    }

    private func serverSupportsClipboardFormat(_ format: UInt32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return serverClipboardFlags & format != 0
    }

    private func handleResizeRequest(_ json: [String: Any]) {
        guard let width = json["width"] as? Int,
              let height = json["height"] as? Int,
              width > 0,
              height > 0,
              width <= Self.maximumDesktopDimension,
              height <= Self.maximumDesktopDimension else { return }
        // SetDesktopSize: 8-byte header followed by one 16-byte screen record.
        let requestedWidth = UInt16(clamped: width)
        let requestedHeight = UInt16(clamped: height)
        stateLock.lock()
        guard serverSupportsExtendedDesktopSize else {
            pendingDesktopResize = (requestedWidth, requestedHeight)
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        sendDesktopResize(width: requestedWidth, height: requestedHeight)
    }

    private func recordExtendedDesktopSizeSupport() {
        stateLock.lock()
        serverSupportsExtendedDesktopSize = true
        let pendingResize = pendingDesktopResize
        pendingDesktopResize = nil
        stateLock.unlock()

        if let pendingResize {
            sendDesktopResize(width: pendingResize.width, height: pendingResize.height)
        }
    }

    private func sendDesktopResize(width requestedWidth: UInt16, height requestedHeight: UInt16) {
        let payload: [UInt8] = [
            251, 0
        ] + StacioVNCAdapter.bigEndianBytes(requestedWidth)
          + StacioVNCAdapter.bigEndianBytes(requestedHeight)
          + [1, 0]
          + StacioVNCAdapter.bigEndianBytes(UInt32(0))
          + StacioVNCAdapter.bigEndianBytes(UInt16(0))
          + StacioVNCAdapter.bigEndianBytes(UInt16(0))
          + StacioVNCAdapter.bigEndianBytes(requestedWidth)
          + StacioVNCAdapter.bigEndianBytes(requestedHeight)
          + StacioVNCAdapter.bigEndianBytes(UInt32(0))
        sendPayload(payload)
    }

    private func handleQualityEvent(_ json: [String: Any]) {
        guard let level = json["level"] as? Int else { return }
        stateLock.lock()
        let changed = adaptiveQualityState.setDesiredQuality(level)
        let quality = adaptiveQualityState.effectiveQuality
        stateLock.unlock()
        if changed {
            sendEncodingPreferences(quality: quality)
        }
    }

    private func sendPayload(_ payload: [UInt8]) {
        ioLock.lock()
        defer { ioLock.unlock() }
        try? StacioVNCAdapter.writeAll(socket: socketDescriptor, bytes: payload)
    }

    private func adjustQualityForNetworkMode(_ mode: String) {
        stateLock.lock()
        let changed = adaptiveQualityState.applyNetworkMode(mode)
        let adjustedQuality = adaptiveQualityState.effectiveQuality
        stateLock.unlock()
        if changed {
            sendEncodingPreferences(quality: adjustedQuality)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    private func currentState() -> (quality: Int, maxFps: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            adaptiveQualityState.effectiveQuality,
            adaptiveQualityState.effectiveMaxFPS
        )
    }

    private var fenceIsSupported: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return serverSupportsFence
    }
}

// MARK: - StacioVNCAdapter 扩展（既有 RFB 工具函数 + 新增工具）

extension StacioVNCAdapter {
    static func connectTCP(host: String, port: UInt16, timeoutSeconds: Int) -> TCPConnectResult {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookupStatus = getaddrinfo(host, String(port), &hints, &info)
        guard lookupStatus == 0, let firstInfo = info else { return .failure("DNS 解析失败") }
        defer { freeaddrinfo(firstInfo) }

        var cursor: UnsafeMutablePointer<addrinfo>? = firstInfo
        var lastFailure = "连接失败"
        while let addressInfo = cursor {
            let descriptor = socket(addressInfo.pointee.ai_family, addressInfo.pointee.ai_socktype, addressInfo.pointee.ai_protocol)
            if descriptor < 0 {
                lastFailure = posixDescription(errno)
                cursor = addressInfo.pointee.ai_next
                continue
            }

            var enabled: Int32 = 1
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            )

            let originalFlags = fcntl(descriptor, F_GETFL, 0)
            guard originalFlags >= 0,
                  fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                lastFailure = posixDescription(errno)
                close(descriptor)
                cursor = addressInfo.pointee.ai_next
                continue
            }

            let connectStatus = connect(
                descriptor,
                addressInfo.pointee.ai_addr,
                addressInfo.pointee.ai_addrlen
            )
            let connectionError: Int32
            if connectStatus == 0 {
                connectionError = 0
            } else if errno == EINPROGRESS {
                connectionError = waitForConnect(
                    descriptor: descriptor,
                    timeoutSeconds: timeoutSeconds
                )
            } else {
                connectionError = errno
            }

            _ = fcntl(descriptor, F_SETFL, originalFlags)
            if connectionError == 0 {
                setSocketTimeouts(descriptor: descriptor, timeoutSeconds: timeoutSeconds)
                return .success(descriptor)
            }
            lastFailure = posixDescription(connectionError)
            close(descriptor)
            cursor = addressInfo.pointee.ai_next
        }
        return .failure(lastFailure)
    }

    private static func waitForConnect(descriptor: Int32, timeoutSeconds: Int) -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(max(0, timeoutSeconds))
        while true {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let timeoutMilliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1_000)))
            var socketPoll = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollStatus = poll(&socketPoll, 1, timeoutMilliseconds)
            if pollStatus == 0 { return ETIMEDOUT }
            if pollStatus < 0 {
                if errno == EINTR { continue }
                return errno
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0 else {
                return errno
            }
            return socketError
        }
    }

    enum TCPConnectResult {
        case success(Int32)
        case failure(String)
    }

    static func setSocketTimeouts(descriptor: Int32, timeoutSeconds: Int) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func isValidRFBVersion(_ value: String) -> Bool {
        let pattern = #"^RFB [0-9]{3}\.[0-9]{3}\n$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    static func negotiatedProtocolVersion(for serverVersion: String) -> String? {
        guard isValidRFBVersion(serverVersion) else { return nil }
        let minorStart = serverVersion.index(serverVersion.startIndex, offsetBy: 8)
        let minorEnd = serverVersion.index(minorStart, offsetBy: 3)
        guard let minor = Int(serverVersion[minorStart..<minorEnd]) else { return nil }
        if minor >= 8 { return "RFB 003.008\n" }
        if minor == 7 { return "RFB 003.007\n" }
        if minor == 3 { return "RFB 003.003\n" }
        return nil
    }

    static func authenticateVNCPassword(socket: Int32, password: String) throws {
        let challenge = try readExact(socket: socket, count: 16)
        try writeAll(socket: socket, bytes: try vncPasswordResponse(password: password, challenge: challenge))
    }

    static func vncPasswordResponse(password: String, challenge: [UInt8]) throws -> [UInt8] {
        guard challenge.count == 16 else {
            throw AdapterError.protocolFailure("VNC challenge 长度无效：\(challenge.count)")
        }
        var key = Array(password.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
            .prefix(kCCKeySizeDES)
            .map(reverseBits)
        while key.count < kCCKeySizeDES { key.append(0) }
        return try desEncrypt(block: Array(challenge[0..<8]), key: key)
            + desEncrypt(block: Array(challenge[8..<16]), key: key)
    }

    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    static func desEncrypt(block: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard block.count == kCCBlockSizeDES, key.count == kCCKeySizeDES else {
            throw AdapterError.protocolFailure("DES 块/密钥长度无效")
        }
        var output = [UInt8](repeating: 0, count: kCCBlockSizeDES)
        var outputLength = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
            key, key.count, nil, block, block.count, &output, output.count, &outputLength
        )
        guard status == kCCSuccess, outputLength == kCCBlockSizeDES else {
            throw AdapterError.protocolFailure("DES 加密失败：\(status)")
        }
        return output
    }

    static func readSecurityFailureReason(socket: Int32) throws -> String {
        let length = try readUInt32(socket: socket)
        guard length > 0, length <= 16_384 else { return "" }
        let bytes = try readExact(socket: socket, count: Int(length))
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .ascii) ?? ""
    }

    static func readUInt16(socket: Int32) throws -> UInt16 {
        let bytes = try readExact(socket: socket, count: 2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    static func readUInt32(socket: Int32) throws -> UInt32 {
        let bytes = try readExact(socket: socket, count: 4)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    static func readInt32(socket: Int32) throws -> Int32 {
        Int32(bitPattern: try readUInt32(socket: socket))
    }

    static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }

    static func readExact(socket: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(socket, rawBuffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received == 0 { throw AdapterError.io("连接已关闭") }
            if received < 0 {
                if errno == EINTR { continue }
                throw AdapterError.io(posixDescription(errno))
            }
            offset += received
        }
        return buffer
    }

    static func writeAll(socket: Int32, bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { rawBuffer in
                send(socket, rawBuffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw AdapterError.io(posixDescription(errno))
            }
            if sent == 0 {
                throw AdapterError.io("连接写入失败：未发送任何数据")
            }
            offset += sent
        }
    }

    static func posixDescription(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "连接被拒绝"
        case ETIMEDOUT: return "连接超时"
        case ENETUNREACH: return "网络不可达"
        case EHOSTUNREACH: return "主机不可达"
        default: return "网络错误：\(String(cString: strerror(code)))"
        }
    }

    static func fdSet(_ fd: Int32, set: inout fd_set) {
        guard fd >= 0 else { return }
        let byteOffset = Int(fd) / 8
        let bitOffset = Int(fd) % 8
        withUnsafeMutableBytes(of: &set) { bytes in
            guard byteOffset < bytes.count else { return }
            bytes[byteOffset] |= UInt8(1) << UInt8(bitOffset)
        }
    }

}

private extension UInt16 {
    init(clamped value: Int) {
        self = UInt16(clamping: value)
    }
}

exit(StacioVNCAdapter.main())
