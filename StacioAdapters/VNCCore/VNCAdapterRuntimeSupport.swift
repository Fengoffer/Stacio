import Compression
import Foundation

package struct VNCConnectionTarget: Equatable {
    package let host: String
    package let port: UInt16

    package init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

package enum VNCConnectionTargetParser {
    package static func parse(_ rawValue: String) -> VNCConnectionTarget? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return nil }

        let host: String
        let portValue: Substring
        if value.first == "[" {
            guard let closingBracket = value.firstIndex(of: "]"),
                  closingBracket > value.startIndex else { return nil }
            let separator = value.index(after: closingBracket)
            guard separator < value.endIndex,
                  value[separator] == ":" else { return nil }
            host = String(value[value.index(after: value.startIndex)..<closingBracket])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            portValue = value[value.index(after: separator)...]
        } else {
            guard let separator = value.lastIndex(of: ":") else { return nil }
            host = String(value[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            portValue = value[value.index(after: separator)...]
        }

        let normalizedPort = portValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false,
              let port = UInt16(normalizedPort),
              port > 0 else { return nil }
        return VNCConnectionTarget(host: host, port: port)
    }
}

package enum VNCFrameLoopTiming {
    private static let maximumPollMicroseconds = 50_000

    package static func pollTimeoutMicroseconds(
        framebufferRequestOutstanding: Bool,
        lastFramebufferRequestTime: TimeInterval,
        now: TimeInterval,
        maxFPS: Int
    ) -> Int {
        guard framebufferRequestOutstanding == false else {
            return maximumPollMicroseconds
        }

        let frameInterval = 1.0 / Double(max(1, maxFPS))
        let remaining = frameInterval - (now - lastFramebufferRequestTime)
        guard remaining.isFinite else {
            return remaining.sign == .minus ? 0 : maximumPollMicroseconds
        }
        guard remaining > 0 else { return 0 }
        return min(maximumPollMicroseconds, Int(remaining * 1_000_000))
    }
}

package struct VNCAdaptiveQualityState: Equatable {
    package private(set) var desiredQuality: Int
    package private(set) var effectiveQuality: Int
    package private(set) var effectiveMaxFPS: Int
    package let configuredMaxFPS: Int

    private var networkMode = "normal"

    package init(desiredQuality: Int, configuredMaxFPS: Int) {
        let quality = Self.clampQuality(desiredQuality)
        self.desiredQuality = quality
        self.effectiveQuality = quality
        self.configuredMaxFPS = max(1, min(60, configuredMaxFPS))
        self.effectiveMaxFPS = max(1, min(60, configuredMaxFPS))
    }

    @discardableResult
    package mutating func setDesiredQuality(_ quality: Int) -> Bool {
        desiredQuality = Self.clampQuality(quality)
        return recompute()
    }

    @discardableResult
    package mutating func applyNetworkMode(_ mode: String) -> Bool {
        switch mode {
        case "normal", "poor", "very_poor":
            networkMode = mode
        default:
            return false
        }
        return recompute()
    }

    private mutating func recompute() -> Bool {
        let previousQuality = effectiveQuality
        switch networkMode {
        case "poor":
            effectiveQuality = min(desiredQuality, 5)
            effectiveMaxFPS = min(configuredMaxFPS, 15)
        case "very_poor":
            effectiveQuality = min(desiredQuality, 2)
            effectiveMaxFPS = min(configuredMaxFPS, 8)
        default:
            effectiveQuality = desiredQuality
            effectiveMaxFPS = configuredMaxFPS
        }
        return effectiveQuality != previousQuality
    }

    private static func clampQuality(_ quality: Int) -> Int {
        max(1, min(10, quality))
    }
}

package enum VNCExtendedClipboardAction: Equatable {
    case capabilities
    case request
    case peek
    case notify
    case provide
}

package struct VNCExtendedClipboardMessage: Equatable {
    package let action: VNCExtendedClipboardAction
    package let flags: UInt32
    package let maximumTextBytes: UInt32?
    package let text: String?

    package init(
        action: VNCExtendedClipboardAction,
        flags: UInt32,
        maximumTextBytes: UInt32? = nil,
        text: String? = nil
    ) {
        self.action = action
        self.flags = flags
        self.maximumTextBytes = maximumTextBytes
        self.text = text
    }
}

package enum VNCExtendedClipboardError: Error, Equatable {
    case malformedMessage
    case unsupportedAction
    case invalidUTF8
    case compressionFailure
    case messageTooLarge
}

package enum VNCExtendedClipboardCodec {
    package static let pseudoEncoding = Int32(bitPattern: 0xC0A1_E5CE)
    package static let textFlag: UInt32 = 1 << 0
    package static let capabilitiesFlag: UInt32 = 1 << 24
    package static let requestFlag: UInt32 = 1 << 25
    package static let peekFlag: UInt32 = 1 << 26
    package static let notifyFlag: UInt32 = 1 << 27
    package static let provideFlag: UInt32 = 1 << 28
    package static let supportedActionFlags = requestFlag | peekFlag | notifyFlag | provideFlag

    private static let actionMask: UInt32 = 0xFF00_0000
    private static let formatMask: UInt32 = 0x0000_FFFF

    package static func capabilitiesPayload(maximumTextBytes: UInt32) -> [UInt8] {
        bigEndianBytes(capabilitiesFlag | supportedActionFlags | textFlag)
            + bigEndianBytes(maximumTextBytes)
    }

    package static func requestPayload() -> [UInt8] {
        bigEndianBytes(requestFlag | textFlag)
    }

    package static func notifyPayload(hasText: Bool) -> [UInt8] {
        bigEndianBytes(notifyFlag | (hasText ? textFlag : 0))
    }

    package static func providePayload(
        text: String,
        maximumTextBytes: Int
    ) throws -> [UInt8] {
        var utf8 = Array(text.utf8)
        guard utf8.count < maximumTextBytes else {
            throw VNCExtendedClipboardError.messageTooLarge
        }
        utf8.append(0)
        let uncompressed = bigEndianBytes(UInt32(utf8.count)) + utf8
        let compressed = try zlibCompress(uncompressed, maximumOutputBytes: maximumTextBytes + 1_024)
        return bigEndianBytes(provideFlag | textFlag) + compressed
    }

    package static func clientCutTextMessage(extendedPayload: [UInt8]) throws -> [UInt8] {
        guard extendedPayload.count >= 4,
              extendedPayload.count <= Int(Int32.max) else {
            throw VNCExtendedClipboardError.messageTooLarge
        }
        let negativeLength = UInt32(bitPattern: -Int32(extendedPayload.count))
        return [6, 0, 0, 0] + bigEndianBytes(negativeLength) + extendedPayload
    }

    package static func decode(
        payload: [UInt8],
        maximumTextBytes: Int
    ) throws -> VNCExtendedClipboardMessage {
        guard payload.count >= 4,
              maximumTextBytes > 0 else {
            throw VNCExtendedClipboardError.malformedMessage
        }
        let flags = readUInt32(payload, at: 0)
        let actionFlags = flags & actionMask

        if actionFlags & capabilitiesFlag != 0 {
            let formatCount = Int((flags & formatMask).nonzeroBitCount)
            guard payload.count == 4 + formatCount * 4 else {
                throw VNCExtendedClipboardError.malformedMessage
            }
            var maximumTextBytesValue: UInt32?
            var offset = 4
            for formatIndex in 0..<16 where flags & (1 << UInt32(formatIndex)) != 0 {
                let maximumBytes = readUInt32(payload, at: offset)
                if formatIndex == 0 {
                    maximumTextBytesValue = maximumBytes
                }
                offset += 4
            }
            return VNCExtendedClipboardMessage(
                action: .capabilities,
                flags: flags,
                maximumTextBytes: maximumTextBytesValue
            )
        }

        switch actionFlags {
        case requestFlag:
            guard payload.count == 4 else { throw VNCExtendedClipboardError.malformedMessage }
            return VNCExtendedClipboardMessage(action: .request, flags: flags)
        case peekFlag:
            guard payload.count == 4 else { throw VNCExtendedClipboardError.malformedMessage }
            return VNCExtendedClipboardMessage(action: .peek, flags: flags)
        case notifyFlag:
            guard payload.count == 4 else { throw VNCExtendedClipboardError.malformedMessage }
            return VNCExtendedClipboardMessage(action: .notify, flags: flags)
        case provideFlag:
            break
        default:
            throw VNCExtendedClipboardError.unsupportedAction
        }

        let maximumInflatedBytes = maximumTextBytes + 16 * 4
        let inflated = try zlibDecompress(
            Array(payload.dropFirst(4)),
            maximumOutputBytes: maximumInflatedBytes
        )
        var cursor = 0
        var text: String?
        for formatIndex in 0..<16 where flags & (1 << UInt32(formatIndex)) != 0 {
            guard cursor <= inflated.count - 4 else {
                throw VNCExtendedClipboardError.malformedMessage
            }
            let length = Int(readUInt32(inflated, at: cursor))
            cursor += 4
            guard length <= maximumTextBytes,
                  cursor <= inflated.count,
                  length <= inflated.count - cursor else {
                throw VNCExtendedClipboardError.messageTooLarge
            }
            if formatIndex == 0 {
                var bytes = Array(inflated[cursor..<(cursor + length)])
                if bytes.last == 0 {
                    bytes.removeLast()
                }
                guard let decoded = String(bytes: bytes, encoding: .utf8) else {
                    throw VNCExtendedClipboardError.invalidUTF8
                }
                text = decoded
            }
            cursor += length
        }
        guard cursor == inflated.count else {
            throw VNCExtendedClipboardError.malformedMessage
        }
        return VNCExtendedClipboardMessage(action: .provide, flags: flags, text: text)
    }

    package static func latin1Bytes(for text: String) -> [UInt8] {
        Array(text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
    }

    package static func latin1String(from bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: .isoLatin1) ?? ""
    }

    private static func zlibCompress(
        _ input: [UInt8],
        maximumOutputBytes: Int
    ) throws -> [UInt8] {
        var capacity = max(64, input.count + input.count / 8 + 64)
        while capacity <= maximumOutputBytes {
            var output = [UInt8](repeating: 0, count: capacity)
            let encodedCount = input.withUnsafeBytes { inputBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    compression_encode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        outputBuffer.count,
                        inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        inputBuffer.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if encodedCount > 0 {
                let checksum = adler32(input)
                return [0x78, 0x9C]
                    + Array(output.prefix(encodedCount))
                    + bigEndianBytes(checksum)
            }
            if capacity == maximumOutputBytes { break }
            capacity = min(maximumOutputBytes, capacity * 2)
        }
        throw VNCExtendedClipboardError.compressionFailure
    }

    private static func zlibDecompress(
        _ input: [UInt8],
        maximumOutputBytes: Int
    ) throws -> [UInt8] {
        guard input.count >= 2,
              maximumOutputBytes > 0 else {
            throw VNCExtendedClipboardError.compressionFailure
        }
        let methodAndInfo = input[0]
        let flags = input[1]
        let header = (UInt16(methodAndInfo) << 8) | UInt16(flags)
        guard methodAndInfo & 0x0F == 8,
              methodAndInfo >> 4 <= 7,
              header % 31 == 0,
              flags & 0x20 == 0 else {
            throw VNCExtendedClipboardError.compressionFailure
        }

        let usesSyncFlush = input.count >= 6 && Array(input.suffix(4)) == [0, 0, 0xFF, 0xFF]
        let rawEnd = usesSyncFlush ? input.count : input.count - 4
        guard rawEnd > 2 else { throw VNCExtendedClipboardError.compressionFailure }
        let rawDeflate = Array(input[2..<rawEnd])
        let decoded = try inflateRaw(rawDeflate, maximumOutputBytes: maximumOutputBytes)

        if usesSyncFlush == false {
            let expectedChecksum = readUInt32(input, at: input.count - 4)
            guard adler32(decoded) == expectedChecksum else {
                throw VNCExtendedClipboardError.compressionFailure
            }
        }
        return decoded
    }

    private static func inflateRaw(
        _ input: [UInt8],
        maximumOutputBytes: Int
    ) throws -> [UInt8] {
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        placeholder.initialize(to: 0)
        defer {
            placeholder.deinitialize(count: 1)
            placeholder.deallocate()
        }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else {
            throw VNCExtendedClipboardError.compressionFailure
        }
        defer { compression_stream_destroy(&stream) }

        var output = [UInt8](repeating: 0, count: maximumOutputBytes + 1)
        let succeeded = output.withUnsafeMutableBufferPointer { outputBuffer in
            input.withUnsafeBufferPointer { inputBuffer in
                guard let outputBase = outputBuffer.baseAddress,
                      let inputBase = inputBuffer.baseAddress else { return false }
                stream.dst_ptr = outputBase
                stream.dst_size = outputBuffer.count
                stream.src_ptr = inputBase
                stream.src_size = inputBuffer.count

                while true {
                    let previousSourceSize = stream.src_size
                    let previousDestinationSize = stream.dst_size
                    let status = compression_stream_process(&stream, 0)
                    if status == COMPRESSION_STATUS_ERROR { return false }
                    if stream.src_size == 0 { return true }
                    if status == COMPRESSION_STATUS_END || stream.dst_size == 0 { return false }
                    if stream.src_size == previousSourceSize,
                       stream.dst_size == previousDestinationSize { return false }
                }
            }
        }
        let produced = output.count - stream.dst_size
        guard succeeded, produced <= maximumOutputBytes else {
            throw VNCExtendedClipboardError.compressionFailure
        }
        return Array(output.prefix(produced))
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}

package struct VNCFenceProbe: Equatable {
    package let payload: [UInt8]
    package let wireBytes: [UInt8]
}

package final class VNCFenceRTTMonitor {
    package typealias Clock = () -> TimeInterval

    private struct PendingProbe {
        let payload: [UInt8]
        let sentAt: TimeInterval
    }

    private let interval: TimeInterval
    private let clock: Clock
    private let lock = NSLock()
    private var handler: ((Int, String) -> Void)?
    private var nextProbeAt: TimeInterval?
    private var nextSequence: UInt64 = 1
    private var pendingProbe: PendingProbe?

    package init(interval: TimeInterval = 10, clock: @escaping Clock) {
        self.interval = max(0, interval)
        self.clock = clock
    }

    package func start(handler: @escaping (Int, String) -> Void) {
        lock.lock()
        self.handler = handler
        nextProbeAt = clock() + interval
        pendingProbe = nil
        lock.unlock()
    }

    package func tick() -> VNCFenceProbe? {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        guard let nextProbeAt, now >= nextProbeAt else { return nil }

        let sequence = nextSequence
        nextSequence &+= 1
        if nextSequence == 0 {
            nextSequence = 1
        }
        let payload = Self.bigEndianBytes(sequence)
        pendingProbe = PendingProbe(payload: payload, sentAt: now)
        self.nextProbeAt = now + interval

        let wireBytes: [UInt8] = [248, 0, 0, 0]
            + Self.bigEndianBytes(UInt32(0x8000_0000))
            + [UInt8(payload.count)]
            + payload
        return VNCFenceProbe(payload: payload, wireBytes: wireBytes)
    }

    package func onFenceResponse(payload: [UInt8]) {
        let callback: ((Int, String) -> Void)?
        let milliseconds: Int

        lock.lock()
        guard let pendingProbe, payload == pendingProbe.payload else {
            lock.unlock()
            return
        }
        let elapsed = max(0, clock() - pendingProbe.sentAt)
        milliseconds = Int((elapsed * 1_000).rounded())
        callback = handler
        self.pendingProbe = nil
        lock.unlock()

        callback?(milliseconds, Self.networkMode(forRTTMilliseconds: milliseconds))
    }

    package static func networkMode(forRTTMilliseconds milliseconds: Int) -> String {
        switch milliseconds {
        case ..<100:
            return "normal"
        case ...300:
            return "poor"
        default:
            return "very_poor"
        }
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }
}
