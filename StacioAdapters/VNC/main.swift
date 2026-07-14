import Darwin
import Foundation
import CommonCrypto

struct StacioVNCAdapter {
    private struct LaunchOptions: Equatable {
        let target: Target
        let password: String?
    }

    private struct Target: Equatable {
        let host: String
        let port: UInt16
    }

    private struct RFBServerInfo: Equatable {
        let negotiatedVersion: String
        let serverVersion: String
        let securityType: RFBSecurityType
        let width: UInt16
        let height: UInt16
        let bitsPerPixel: UInt8
        let depth: UInt8
        let name: String
        let firstUpdate: RFBFramebufferUpdate
    }

    private struct RFBFramebufferUpdate: Equatable {
        let rectangleCount: UInt16
        let firstEncoding: Int32
        let desktopSize: RFBDesktopSize?
        let rawPayloadBytes: UInt64

        var firstEncodingName: String {
            switch firstEncoding {
            case 0:
                return "Raw"
            case 1:
                return "CopyRect"
            case 2:
                return "RRE"
            case 4:
                return "CoRRE"
            case 5:
                return "Hextile"
            case 6:
                return "Zlib"
            case 16:
                return "ZRLE"
            case -224:
                return "LastRect"
            case -223:
                return "DesktopSize"
            default:
                return "未知(\(firstEncoding))"
            }
        }
    }

    private struct RFBDesktopSize: Equatable {
        let width: UInt16
        let height: UInt16
    }

    private enum RFBHandshakeResult: Equatable {
        case success(RFBServerInfo)
        case failure(String)
    }

    private enum RFBSecurityType: Equatable {
        case none
        case vncPassword

        var displayName: String {
            switch self {
            case .none:
                return "None"
            case .vncPassword:
                return "VNCPassword"
            }
        }
    }

    private enum TCPConnectResult {
        case success(Int32)
        case failure(String)
    }

    static func main(arguments: [String] = CommandLine.arguments) -> Int32 {
        guard let options = parseArguments(arguments) else {
            print("VNC 适配器需要目标地址，格式：host:port；可选：--password <密码>")
            return 64
        }
        let target = options.target

        print("VNC RFB 握手开始：\(target.host):\(target.port)")
        switch performRFBHandshake(host: target.host, port: target.port, password: options.password) {
        case .success(let info):
            print("VNC RFB 握手成功：\(target.host):\(target.port)")
            print("协议版本：\(info.negotiatedVersion)")
            print("服务端版本：\(info.serverVersion)")
            print("安全类型：\(info.securityType.displayName)")
            print("尺寸：\(info.width)x\(info.height)")
            print("像素格式：\(info.bitsPerPixel)bpp / depth \(info.depth)")
            print("桌面：\(info.name)")
            print("已发送 framebuffer 初始请求（SetPixelFormat / SetEncodings / FramebufferUpdateRequest）")
            print("首帧更新：\(info.firstUpdate.rectangleCount) 个矩形")
            print("编码：\(info.firstUpdate.firstEncodingName)")
            if let desktopSize = info.firstUpdate.desktopSize {
                print("桌面尺寸更新：\(desktopSize.width)x\(desktopSize.height)")
            }
            print("字节：\(info.firstUpdate.rawPayloadBytes)")
            return 0
        case .failure(let reason):
            print("VNC RFB 握手失败：\(target.host):\(target.port)。原因：\(reason)")
            return 69
        }
    }

    private static func parseArguments(_ arguments: [String]) -> LaunchOptions? {
        var password: String?
        var targetValue: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--password" || argument == "-p" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    return nil
                }
                password = arguments[valueIndex]
                index += 2
                continue
            }
            guard targetValue == nil else {
                return nil
            }
            targetValue = argument
            index += 1
        }
        guard let targetValue, let target = parseTarget(targetValue) else {
            return nil
        }
        return LaunchOptions(target: target, password: password)
    }

    private static func parseTarget(_ rawValue: String) -> Target? {
        guard let separatorIndex = rawValue.lastIndex(of: ":") else {
            return nil
        }
        let host = String(rawValue[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = String(rawValue[rawValue.index(after: separatorIndex)...])
        guard
            !host.isEmpty,
            let port = UInt16(portValue),
            port > 0
        else {
            return nil
        }
        return Target(host: host, port: port)
    }

    private static func performRFBHandshake(
        host: String,
        port: UInt16,
        password: String?,
        timeoutSeconds: Int = 3
    ) -> RFBHandshakeResult {
        switch connectTCP(host: host, port: port, timeoutSeconds: timeoutSeconds) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let descriptor):
            defer { close(descriptor) }
            return performRFBHandshake(socket: descriptor, password: password)
        }
    }

    private static func performRFBHandshake(socket: Int32, password: String?) -> RFBHandshakeResult {
        do {
            let serverVersionBytes = try readExact(socket: socket, count: 12)
            guard let serverVersion = String(bytes: serverVersionBytes, encoding: .ascii),
                  isValidRFBVersion(serverVersion)
            else {
                return .failure("服务端不是 RFB/VNC 协议")
            }
            guard let negotiatedVersion = negotiatedProtocolVersion(for: serverVersion) else {
                let readableVersion = serverVersion.trimmingCharacters(in: .newlines)
                return .failure("服务端 RFB 版本 \(readableVersion) 需要旧版安全协商；需要后续兼容支持。")
            }

            try writeAll(socket: socket, bytes: Array(negotiatedVersion.utf8))

            let securityType: RFBSecurityType
            let shouldReadSecurityResult: Bool
            if negotiatedVersion == "RFB 003.003\n" {
                let rawSecurityType = try readUInt32(socket: socket)
                switch rawSecurityType {
                case 1:
                    securityType = .none
                    shouldReadSecurityResult = false
                case 2:
                    guard let password, !password.isEmpty else {
                        return .failure("服务端要求 VNC 密码认证（security type 2），但本次启动未提供密码。")
                    }
                    try authenticateVNCPassword(socket: socket, password: password)
                    securityType = .vncPassword
                    shouldReadSecurityResult = true
                case 0:
                        let reason = try readSecurityFailureReason(socket: socket)
                        return .failure(reason.isEmpty ? "服务端拒绝 RFB 安全协商" : "服务端拒绝 RFB 安全协商：\(reason)")
                default:
                    return .failure("服务端未提供 None(1) 或 VNCPassword(2) 安全类型（提供：\(rawSecurityType)）；需要后续实现更多 VNC 认证支持。")
                }
            } else {
                let securityTypeCount = try readExact(socket: socket, count: 1)[0]
                guard securityTypeCount > 0 else {
                    let reason = try readSecurityFailureReason(socket: socket)
                    return .failure(reason.isEmpty ? "服务端拒绝 RFB 安全协商" : "服务端拒绝 RFB 安全协商：\(reason)")
                }

                let securityTypes = try readExact(socket: socket, count: Int(securityTypeCount))
                if securityTypes.contains(1) {
                    try writeAll(socket: socket, bytes: [1])
                    securityType = .none
                    shouldReadSecurityResult = negotiatedVersion != "RFB 003.007\n"
                } else if securityTypes.contains(2) {
                    guard let password, !password.isEmpty else {
                        let offered = securityTypes.map(String.init).joined(separator: ", ")
                        return .failure("服务端要求 VNC 密码认证（security type 2，提供：\(offered)），但本次启动未提供密码。")
                    }
                    try writeAll(socket: socket, bytes: [2])
                    try authenticateVNCPassword(socket: socket, password: password)
                    securityType = .vncPassword
                    shouldReadSecurityResult = true
                } else {
                    let offered = securityTypes.map(String.init).joined(separator: ", ")
                    return .failure("服务端未提供 None(1) 或 VNCPassword(2) 安全类型（提供：\(offered)）；需要后续实现更多 VNC 认证支持。")
                }
            }

            if shouldReadSecurityResult {
                let securityResult = try readUInt32(socket: socket)
                guard securityResult == 0 else {
                    let reason = negotiatedVersion == "RFB 003.008\n"
                        ? (try? readSecurityFailureReason(socket: socket)) ?? ""
                        : ""
                    return .failure(reason.isEmpty ? "\(securityType.displayName) 安全类型协商失败，状态码：\(securityResult)" : "\(securityType.displayName) 安全类型协商失败：\(reason)")
                }
            }

            try writeAll(socket: socket, bytes: [1])

            let width = try readUInt16(socket: socket)
            let height = try readUInt16(socket: socket)
            let pixelFormat = try readExact(socket: socket, count: 16)
            let nameLength = try readUInt32(socket: socket)
            guard nameLength <= 16_384 else {
                return .failure("ServerInit 名称过长：\(nameLength) 字节")
            }
            let nameBytes = try readExact(socket: socket, count: Int(nameLength))
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .ascii) ?? "未命名 VNC 桌面"

            try sendInitialFramebufferRequest(socket: socket, width: width, height: height)
            let firstUpdate = try readFramebufferUpdate(socket: socket, bytesPerPixel: 4)

            return .success(
                RFBServerInfo(
                    negotiatedVersion: negotiatedVersion.trimmingCharacters(in: .newlines),
                    serverVersion: serverVersion.trimmingCharacters(in: .newlines),
                    securityType: securityType,
                    width: width,
                    height: height,
                    bitsPerPixel: pixelFormat[0],
                    depth: pixelFormat[1],
                    name: name,
                    firstUpdate: firstUpdate
                )
            )
        } catch let error as RFBIOError {
            return .failure(error.localizedDescription)
        } catch {
            return .failure("协议读写失败：\(error.localizedDescription)")
        }
    }

    private static func connectTCP(host: String, port: UInt16, timeoutSeconds: Int) -> TCPConnectResult {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookupStatus = getaddrinfo(host, String(port), &hints, &info)
        guard lookupStatus == 0, let firstInfo = info else {
            return .failure("DNS 解析失败")
        }
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

            setSocketTimeouts(descriptor: descriptor, timeoutSeconds: timeoutSeconds)
            if connect(descriptor, addressInfo.pointee.ai_addr, addressInfo.pointee.ai_addrlen) == 0 {
                return .success(descriptor)
            }

            lastFailure = posixDescription(errno)
            close(descriptor)
            cursor = addressInfo.pointee.ai_next
        }

        return .failure(lastFailure)
    }

    private static func setSocketTimeouts(descriptor: Int32, timeoutSeconds: Int) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func isValidRFBVersion(_ value: String) -> Bool {
        let pattern = #"^RFB [0-9]{3}\.[0-9]{3}\n$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func negotiatedProtocolVersion(for serverVersion: String) -> String? {
        guard isValidRFBVersion(serverVersion) else {
            return nil
        }
        let minorStart = serverVersion.index(serverVersion.startIndex, offsetBy: 8)
        let minorEnd = serverVersion.index(minorStart, offsetBy: 3)
        guard let minor = Int(serverVersion[minorStart..<minorEnd]) else {
            return nil
        }
        if minor >= 8 {
            return "RFB 003.008\n"
        }
        if minor == 7 {
            return "RFB 003.007\n"
        }
        if minor == 3 {
            return "RFB 003.003\n"
        }
        return nil
    }

    private static func authenticateVNCPassword(socket: Int32, password: String) throws {
        let challenge = try readExact(socket: socket, count: 16)
        try writeAll(socket: socket, bytes: try vncPasswordResponse(password: password, challenge: challenge))
    }

    private static func vncPasswordResponse(password: String, challenge: [UInt8]) throws -> [UInt8] {
        guard challenge.count == 16 else {
            throw RFBProtocolError.invalidVNCChallengeLength(challenge.count)
        }
        var key = Array(password.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
            .prefix(kCCKeySizeDES)
            .map(reverseBits)
        while key.count < kCCKeySizeDES {
            key.append(0)
        }
        return try desEncrypt(block: Array(challenge[0..<8]), key: key)
            + desEncrypt(block: Array(challenge[8..<16]), key: key)
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    private static func desEncrypt(block: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard block.count == kCCBlockSizeDES, key.count == kCCKeySizeDES else {
            throw RFBProtocolError.invalidVNCChallengeLength(block.count)
        }
        var output = [UInt8](repeating: 0, count: kCCBlockSizeDES)
        var outputLength = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key,
            key.count,
            nil,
            block,
            block.count,
            &output,
            output.count,
            &outputLength
        )
        guard status == kCCSuccess, outputLength == kCCBlockSizeDES else {
            throw RFBProtocolError.vncPasswordResponseFailed(status)
        }
        return output
    }

    private static func sendInitialFramebufferRequest(socket: Int32, width: UInt16, height: UInt16) throws {
        try writeAll(socket: socket, bytes: [
            0,
            0, 0, 0,
            32, 24, 0, 1,
            0, 255,
            0, 255,
            0, 255,
            16, 8, 0,
            0, 0, 0
        ])

        try writeAll(socket: socket, bytes: [
            2, 0,
            0, 9,
            0, 0, 0, 0,
            0, 0, 0, 1,
            0, 0, 0, 2,
            0, 0, 0, 4,
            0, 0, 0, 5,
            0, 0, 0, 6,
            0, 0, 0, 16,
            255, 255, 255, 33,
            255, 255, 255, 32
        ])

        let requestWidth = max(UInt16(1), min(width, UInt16(1)))
        let requestHeight = max(UInt16(1), min(height, UInt16(1)))
        try writeAll(socket: socket, bytes: [
            3, 0,
            0, 0,
            0, 0
        ] + bigEndianBytes(requestWidth) + bigEndianBytes(requestHeight))
    }

    private static func readFramebufferUpdate(socket: Int32, bytesPerPixel: UInt64) throws -> RFBFramebufferUpdate {
        while true {
            let messageType = try readExact(socket: socket, count: 1)[0]
            if messageType == 2 {
                continue
            }
            if messageType == 3 {
                try skipServerCutText(socket: socket)
                continue
            }
            guard messageType == 0 else {
                throw RFBProtocolError.unexpectedServerMessage(messageType)
            }
            break
        }

        _ = try readExact(socket: socket, count: 1)
        let rectangleCount = try readUInt16(socket: socket)
        guard rectangleCount > 0 else {
            throw RFBProtocolError.emptyFramebufferUpdate
        }
        guard rectangleCount <= 4_096 else {
            throw RFBProtocolError.tooManyRectangles(rectangleCount)
        }

        var firstEncoding: Int32?
        var desktopSize: RFBDesktopSize?
        var rawPayloadBytes: UInt64 = 0
        for _ in 0..<rectangleCount {
            _ = try readUInt16(socket: socket)
            _ = try readUInt16(socket: socket)
            let rectangleWidth = try readUInt16(socket: socket)
            let rectangleHeight = try readUInt16(socket: socket)
            let encoding = try readInt32(socket: socket)
            if firstEncoding == nil {
                firstEncoding = encoding
            }

            if encoding == 1 {
                _ = try readExact(socket: socket, count: 4)
                rawPayloadBytes += 4
                continue
            }
            if encoding == 2 {
                rawPayloadBytes += try skipRREPayload(socket: socket, bytesPerPixel: bytesPerPixel)
                continue
            }
            if encoding == 4 {
                rawPayloadBytes += try skipCoRREPayload(socket: socket, bytesPerPixel: bytesPerPixel)
                continue
            }
            if encoding == 5 {
                rawPayloadBytes += try skipHextilePayload(
                    socket: socket,
                    width: rectangleWidth,
                    height: rectangleHeight,
                    bytesPerPixel: bytesPerPixel
                )
                continue
            }
            if encoding == 6 || encoding == 16 {
                let payloadBytes = try readUInt32(socket: socket)
                guard payloadBytes <= 64 * 1024 * 1024 else {
                    throw RFBProtocolError.compressedPayloadTooLarge(payloadBytes)
                }
                _ = try readExact(socket: socket, count: Int(payloadBytes))
                rawPayloadBytes += UInt64(payloadBytes)
                continue
            }
            if encoding == -224 {
                continue
            }
            if encoding == -223 {
                desktopSize = RFBDesktopSize(width: rectangleWidth, height: rectangleHeight)
                continue
            }
            guard encoding == 0 else {
                throw RFBProtocolError.unsupportedEncoding(encoding)
            }
            let payloadBytes = UInt64(rectangleWidth) * UInt64(rectangleHeight) * bytesPerPixel
            guard payloadBytes <= 64 * 1024 * 1024 else {
                throw RFBProtocolError.rectanglePayloadTooLarge(payloadBytes)
            }
            _ = try readExact(socket: socket, count: Int(payloadBytes))
            rawPayloadBytes += payloadBytes
        }

        return RFBFramebufferUpdate(
            rectangleCount: rectangleCount,
            firstEncoding: firstEncoding ?? 0,
            desktopSize: desktopSize,
            rawPayloadBytes: rawPayloadBytes
        )
    }

    private static func skipRREPayload(socket: Int32, bytesPerPixel: UInt64) throws -> UInt64 {
        guard bytesPerPixel > 0, bytesPerPixel <= 8 else {
            throw RFBProtocolError.invalidBytesPerPixel(bytesPerPixel)
        }
        let subrectCount = try readUInt32(socket: socket)
        var skippedBytes: UInt64 = 4
        try skipBoundedPayload(socket: socket, bytes: bytesPerPixel)
        skippedBytes += bytesPerPixel

        let subrectBytes = UInt64(subrectCount) * (bytesPerPixel + 8)
        try skipBoundedPayload(socket: socket, bytes: subrectBytes)
        skippedBytes += subrectBytes
        return skippedBytes
    }

    private static func skipCoRREPayload(socket: Int32, bytesPerPixel: UInt64) throws -> UInt64 {
        guard bytesPerPixel > 0, bytesPerPixel <= 8 else {
            throw RFBProtocolError.invalidBytesPerPixel(bytesPerPixel)
        }
        let subrectCount = try readUInt32(socket: socket)
        var skippedBytes: UInt64 = 4
        try skipBoundedPayload(socket: socket, bytes: bytesPerPixel)
        skippedBytes += bytesPerPixel

        let subrectBytes = UInt64(subrectCount) * (bytesPerPixel + 4)
        try skipBoundedPayload(socket: socket, bytes: subrectBytes)
        skippedBytes += subrectBytes
        return skippedBytes
    }

    private static func skipHextilePayload(
        socket: Int32,
        width: UInt16,
        height: UInt16,
        bytesPerPixel: UInt64
    ) throws -> UInt64 {
        guard bytesPerPixel > 0, bytesPerPixel <= 8 else {
            throw RFBProtocolError.invalidBytesPerPixel(bytesPerPixel)
        }
        var skippedBytes: UInt64 = 0
        var tileTop: UInt16 = 0
        while tileTop < height {
            let tileHeight = UInt16(min(16, Int(height - tileTop)))
            var tileLeft: UInt16 = 0
            while tileLeft < width {
                let tileWidth = UInt16(min(16, Int(width - tileLeft)))
                let subencoding = try readExact(socket: socket, count: 1)[0]
                skippedBytes += 1

                if subencoding & 0x01 != 0 {
                    let tileBytes = UInt64(tileWidth) * UInt64(tileHeight) * bytesPerPixel
                    try skipBoundedPayload(socket: socket, bytes: tileBytes)
                    skippedBytes += tileBytes
                } else {
                    if subencoding & 0x02 != 0 {
                        try skipBoundedPayload(socket: socket, bytes: bytesPerPixel)
                        skippedBytes += bytesPerPixel
                    }
                    if subencoding & 0x04 != 0 {
                        try skipBoundedPayload(socket: socket, bytes: bytesPerPixel)
                        skippedBytes += bytesPerPixel
                    }
                    if subencoding & 0x08 != 0 {
                        let subrectCount = try readExact(socket: socket, count: 1)[0]
                        skippedBytes += 1
                        for _ in 0..<subrectCount {
                            if subencoding & 0x10 != 0 {
                                try skipBoundedPayload(socket: socket, bytes: bytesPerPixel)
                                skippedBytes += bytesPerPixel
                            }
                            _ = try readExact(socket: socket, count: 2)
                            skippedBytes += 2
                        }
                    }
                }

                guard skippedBytes <= 64 * 1024 * 1024 else {
                    throw RFBProtocolError.rectanglePayloadTooLarge(skippedBytes)
                }
                tileLeft += 16
            }
            tileTop += 16
        }
        return skippedBytes
    }

    private static func skipBoundedPayload(socket: Int32, bytes: UInt64) throws {
        guard bytes <= 64 * 1024 * 1024 else {
            throw RFBProtocolError.rectanglePayloadTooLarge(bytes)
        }
        _ = try readExact(socket: socket, count: Int(bytes))
    }

    private static func skipServerCutText(socket: Int32) throws {
        _ = try readExact(socket: socket, count: 3)
        let length = try readUInt32(socket: socket)
        guard length <= 16_384 else {
            throw RFBProtocolError.serverCutTextTooLarge(length)
        }
        _ = try readExact(socket: socket, count: Int(length))
    }

    private static func readSecurityFailureReason(socket: Int32) throws -> String {
        let length = try readUInt32(socket: socket)
        guard length > 0, length <= 16_384 else {
            return ""
        }
        let bytes = try readExact(socket: socket, count: Int(length))
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readUInt16(socket: Int32) throws -> UInt16 {
        let bytes = try readExact(socket: socket, count: 2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private static func readUInt32(socket: Int32) throws -> UInt32 {
        let bytes = try readExact(socket: socket, count: 4)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private static func readInt32(socket: Int32) throws -> Int32 {
        Int32(bitPattern: try readUInt32(socket: socket))
    }

    private static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func readExact(socket: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(socket, rawBuffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received == 0 {
                throw RFBIOError.connectionClosed
            }
            if received < 0 {
                if errno == EINTR {
                    continue
                }
                throw RFBIOError.posix(errno)
            }
            offset += received
        }
        return buffer
    }

    private static func writeAll(socket: Int32, bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { rawBuffer in
                send(socket, rawBuffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR {
                    continue
                }
                throw RFBIOError.posix(errno)
            }
            offset += sent
        }
    }

    static func posixDescription(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED:
            return "连接被拒绝"
        case ETIMEDOUT:
            return "连接超时"
        case ENETUNREACH:
            return "网络不可达"
        case EHOSTUNREACH:
            return "主机不可达"
        default:
            return "网络错误：\(String(cString: strerror(code)))"
        }
    }
}

private enum RFBProtocolError: Error, LocalizedError {
    case unexpectedServerMessage(UInt8)
    case emptyFramebufferUpdate
    case tooManyRectangles(UInt16)
    case unsupportedEncoding(Int32)
    case rectanglePayloadTooLarge(UInt64)
    case compressedPayloadTooLarge(UInt32)
    case invalidBytesPerPixel(UInt64)
    case serverCutTextTooLarge(UInt32)
    case invalidVNCChallengeLength(Int)
    case vncPasswordResponseFailed(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedServerMessage(let messageType):
            return "收到非 FramebufferUpdate 消息：\(messageType)"
        case .emptyFramebufferUpdate:
            return "首帧 framebuffer 更新没有矩形"
        case .tooManyRectangles(let count):
            return "首帧 framebuffer 矩形过多：\(count)"
        case .unsupportedEncoding(let encoding):
            return "首帧 framebuffer 编码暂不支持：\(encoding)"
        case .rectanglePayloadTooLarge(let bytes):
            return "Raw 矩形数据过大：\(bytes) 字节"
        case .compressedPayloadTooLarge(let bytes):
            return "压缩矩形数据过大：\(bytes) 字节"
        case .invalidBytesPerPixel(let bytes):
            return "像素字节宽度无效：\(bytes)"
        case .serverCutTextTooLarge(let length):
            return "ServerCutText 过长：\(length) 字节"
        case .invalidVNCChallengeLength(let length):
            return "VNC 密码认证 challenge 长度无效：\(length) 字节"
        case .vncPasswordResponseFailed(let status):
            return "VNC 密码认证响应生成失败：\(status)"
        }
    }
}

private enum RFBIOError: Error, LocalizedError {
    case connectionClosed
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "连接已关闭"
        case .posix(let code):
            return StacioVNCAdapter.posixDescription(code)
        }
    }
}

exit(StacioVNCAdapter.main())
