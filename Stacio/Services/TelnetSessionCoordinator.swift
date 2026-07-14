import Foundation
import StacioCoreBindings

public enum TelnetSessionError: LocalizedError, Equatable {
    case startFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .startFailed(message):
            return message
        }
    }
}

public protocol TelnetRuntimeStarting {
    func startLiveTelnetShellRuntime(
        config: TelnetConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus
}

public struct CoreBridgeTelnetRuntimeStarter: TelnetRuntimeStarting {
    public init() {}

    public func startLiveTelnetShellRuntime(
        config: TelnetConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try CoreBridge.startLiveTelnetShellRuntime(config: config, cols: cols, rows: rows)
    }
}

@MainActor
public protocol TelnetSessionStarting: AnyObject {
    @discardableResult
    func start(config: TelnetConnectionConfig, title: String) throws -> LiveShellStatus
}

@MainActor
public final class TelnetSessionCoordinator: TelnetSessionStarting {
    private let runtimeStarter: TelnetRuntimeStarting
    private weak var workspace: RemoteWorkspaceOpening?
    private let defaultCols: UInt32
    private let defaultRows: UInt32

    public init(
        runtimeStarter: TelnetRuntimeStarting = CoreBridgeTelnetRuntimeStarter(),
        workspace: RemoteWorkspaceOpening,
        defaultCols: UInt32 = 80,
        defaultRows: UInt32 = 24
    ) {
        self.runtimeStarter = runtimeStarter
        self.workspace = workspace
        self.defaultCols = defaultCols
        self.defaultRows = defaultRows
    }

    @discardableResult
    public func start(config: TelnetConnectionConfig, title: String) throws -> LiveShellStatus {
        let status: LiveShellStatus
        do {
            status = try runtimeStarter.startLiveTelnetShellRuntime(
                config: config,
                cols: defaultCols,
                rows: defaultRows
            )
            guard status.status == "running" else {
                throw TelnetSessionError.startFailed(message: Self.diagnosticMessage(forStatusDiagnostic: status.diagnostic))
            }
        } catch {
            throw TelnetSessionError.startFailed(message: Self.diagnosticMessage(for: error))
        }
        workspace?.openRemoteShell(status: status, title: title, reconnecter: nil, connectionKind: .telnet)
        return status
    }

    public static func diagnosticMessage(for error: Error) -> String {
        if case let TelnetSessionError.startFailed(message) = error {
            return message
        }
        if case SshRuntimeError.InvalidConfig = error {
            return "Telnet 连接失败：配置无效，请检查主机和端口。"
        }
        if case SshRuntimeError.AuthFailed = error {
            return "Telnet 连接失败：认证失败"
        }
        if case SshRuntimeError.Timeout = error {
            return "Telnet 连接失败：连接超时"
        }
        if case let SshRuntimeError.Transport(message) = error {
            return "Telnet 连接失败：\(RuntimeDiagnosticFormatter.userMessage(message))"
        }
        return "Telnet 连接失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
    }

    private static func diagnosticMessage(forStatusDiagnostic diagnostic: String) -> String {
        let message = RuntimeDiagnosticFormatter.userMessage(diagnostic)
        return "Telnet 连接失败：\(message.isEmpty ? "Telnet 运行时未进入运行状态。" : message)"
    }
}
