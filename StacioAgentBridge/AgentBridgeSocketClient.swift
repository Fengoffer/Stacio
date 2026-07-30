import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum AgentBridgeSocketPath {
    public static let environmentKey = "STACIO_AGENT_SOCKET"

    public static var defaultPath: String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Stacio", isDirectory: true)
            .appendingPathComponent("agent-bridge.sock")
            .path
    }

    public static func resolve(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let explicitPath = trimmedNonEmpty(explicitPath) {
            return explicitPath
        }
        if let environmentPath = trimmedNonEmpty(environment[environmentKey]) {
            return environmentPath
        }
        return defaultPath
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct AgentBridgeSocketClient {
    private let socketPath: String

    public init(socketPath: String = AgentBridgeSocketPath.defaultPath) {
        self.socketPath = socketPath
    }

    public func send(request: AgentBridgeRequest, onLine: (String) -> Void) throws {
        #if canImport(Darwin)
        // C3: 连接前校验 socket 文件属主为当前用户且 group/other 无权限
        try validateSocketOwnership(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw AgentBridgeSocketClientError.bridgeUnavailable(
                socketPath: socketPath,
                code: POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: Array(socketPath.utf8) + [0])
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw AgentBridgeSocketClientError.bridgeUnavailable(
                socketPath: socketPath,
                code: POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: sent), payload.count - sent)
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                sent += written
            }
        }
        _ = shutdown(fd, SHUT_WR)

        var readBuffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while true {
            let count = Darwin.read(fd, &readBuffer, readBuffer.count)
            if count == 0 {
                break
            }
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            pending.append(readBuffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newline]
                pending.removeSubrange(...newline)
                if lineData.isEmpty == false {
                    onLine(String(decoding: lineData, as: UTF8.self))
                }
            }
        }
        if pending.isEmpty == false {
            onLine(String(decoding: pending, as: UTF8.self))
        }
        #else
        throw POSIXError(.ENOTSUP)
        #endif
    }
    /// 校验 Unix socket 文件属主为当前用户，且 group/other 无读写权限。
    /// 防止同机其他用户通过权限宽松的 socket 执行任意 Agent Bridge 命令。
    private func validateSocketOwnership(_ path: String) throws {
        #if canImport(Darwin)
        var statBuffer = stat()
        guard stat(path, &statBuffer) == 0 else {
            throw AgentBridgeSocketClientError.bridgeUnavailable(
                socketPath: path,
                code: POSIXErrorCode(rawValue: errno) ?? .ENOENT
            )
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFSOCK else {
            throw AgentBridgeSocketClientError.bridgeUnavailable(
                socketPath: path,
                code: .ENOTSOCK
            )
        }
        guard statBuffer.st_uid == getuid() else {
            throw AgentBridgeSocketClientError.bridgeUnavailable(
                socketPath: path,
                code: .EACCES
            )
        }
        // group/other 不得有读写权限
        let groupOtherPermissions = statBuffer.st_mode & 0o077
        guard groupOtherPermissions == 0 else {
            throw AgentBridgeSocketClientError.bridgeUnavailable(
                socketPath: path,
                code: .EACCES
            )
        }
        #endif
    }
}

public enum AgentBridgeSocketClientError: Error, LocalizedError, Equatable {
    case bridgeUnavailable(socketPath: String, code: POSIXErrorCode)

    public var errorDescription: String? {
        switch self {
        case .bridgeUnavailable(let socketPath, let code):
            return "Stacio Agent Bridge 未连接。请先打开 Stacio 并保持主窗口运行，然后重试。Socket：\(socketPath)，错误：\(code.rawValue)。"
        }
    }
}
