import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum AgentBridgeSocketPath {
    public static let environmentKey = "STACIO_AGENT_SOCKET"
    private static let legacyEnvironmentKey = "STACIO_AGENT_SOCKET"

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
        if let legacyEnvironmentPath = trimmedNonEmpty(environment[legacyEnvironmentKey]) {
            return legacyEnvironmentPath
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(fd) }

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
