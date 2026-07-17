import Foundation
import StacioCoreBindings

private struct SerialUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

public enum SerialSessionError: LocalizedError, Equatable {
    case startFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .startFailed(message):
            return message
        }
    }
}

public protocol SerialRuntimeStarting {
    func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus
}

public struct CoreBridgeSerialRuntimeStarter: SerialRuntimeStarting {
    public init() {}

    public func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try CoreBridge.startLiveSerialShellRuntime(config: config, cols: cols, rows: rows)
    }
}

@MainActor
public protocol SerialSessionStarting: AnyObject {
    @discardableResult
    func start(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus

    @discardableResult
    func openSessionTab(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus
}

@MainActor
public extension SerialSessionStarting {
    @discardableResult
    func openSessionTab(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus {
        try start(config: config, title: title)
    }
}

@MainActor
public final class SerialSessionCoordinator: SerialSessionStarting {
    private let runtimeStarter: SerialRuntimeStarting
    private weak var workspace: RemoteWorkspaceOpening?
    private let defaultCols: UInt32
    private let defaultRows: UInt32

    public init(
        runtimeStarter: SerialRuntimeStarting = CoreBridgeSerialRuntimeStarter(),
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
    public func start(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus {
        guard let workspace else {
            throw RemoteTerminalLifecycleError.reconnectUnavailable
        }
        let status: LiveShellStatus
        do {
            status = try startRuntime(config: config)
        } catch {
            throw SerialSessionError.startFailed(message: Self.diagnosticMessage(for: error))
        }
        workspace.openRemoteShell(
            status: status,
            title: title,
            reconnecter: SerialSessionReconnecter(coordinator: self, config: config),
            connectionKind: .serial
        )
        return status
    }

    @discardableResult
    public func openSessionTab(config: SerialConnectionConfig, title: String) throws -> LiveShellStatus {
        guard let workspace else {
            throw RemoteTerminalLifecycleError.reconnectUnavailable
        }
        let reconnecter = SerialSessionReconnecter(coordinator: self, config: config)
        let pane = workspace.openConnectingRemoteShell(
            title: title,
            reconnecter: reconnecter,
            connectionKind: .serial,
            liveSessionContext: nil
        )
        let pendingStatus = LiveShellStatus(
            runtimeId: pane.runtimeID,
            status: "connecting",
            diagnostic: L10n.TerminalLifecycle.connecting
        )
        startRuntimeInBackground(config: config, pane: pane)
        return pendingStatus
    }

    fileprivate func startRuntime(config: SerialConnectionConfig) throws -> LiveShellStatus {
        let status = try runtimeStarter.startLiveSerialShellRuntime(
            config: config,
            cols: defaultCols,
            rows: defaultRows
        )
        guard status.status == "running" else {
            throw SerialSessionError.startFailed(message: Self.diagnosticMessage(forStatusDiagnostic: status.diagnostic))
        }
        return status
    }

    private func startRuntimeInBackground(
        config: SerialConnectionConfig,
        pane: RemoteTerminalPaneViewController?
    ) {
        startRuntimeInBackground(config: config) { [weak pane] result in
            switch result {
            case let .success(status):
                pane?.attachConnectedRuntime(status: status)
            case let .failure(error):
                pane?.displayConnectionFailure(Self.diagnosticMessage(for: error))
            }
        }
    }

    fileprivate func startRuntimeInBackground(
        config: SerialConnectionConfig,
        completion: @escaping @MainActor (Result<LiveShellStatus, Error>) -> Void
    ) {
        let runtimeStarter = SerialUncheckedSendable(value: runtimeStarter)
        let defaultCols = defaultCols
        let defaultRows = defaultRows

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<LiveShellStatus, Error>
            do {
                let status = try runtimeStarter.value.startLiveSerialShellRuntime(
                    config: config,
                    cols: defaultCols,
                    rows: defaultRows
                )
                guard status.status == "running" else {
                    throw SerialSessionError.startFailed(
                        message: Self.diagnosticMessage(forStatusDiagnostic: status.diagnostic)
                    )
                }
                result = .success(status)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    nonisolated public static func diagnosticMessage(for error: Error) -> String {
        if case let SerialSessionError.startFailed(message) = error {
            return message
        }
        if case SshRuntimeError.InvalidConfig = error {
            return "串口连接失败：串口配置无效，请检查设备路径和波特率。"
        }
        if case SshRuntimeError.AuthFailed = error {
            return "串口连接失败：认证失败"
        }
        if case SshRuntimeError.Timeout = error {
            return "串口连接失败：连接超时"
        }
        if case let SshRuntimeError.Transport(message) = error {
            return "串口连接失败：\(RuntimeDiagnosticFormatter.userMessage(message))"
        }
        return "串口连接失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
    }

    nonisolated private static func diagnosticMessage(forStatusDiagnostic diagnostic: String) -> String {
        let message = RuntimeDiagnosticFormatter.userMessage(diagnostic)
        return "串口连接失败：\(message.isEmpty ? "串口运行时未进入运行状态。" : message)"
    }
}

@MainActor
private final class SerialSessionReconnecter: RemoteTerminalBackgroundReconnecting {
    private weak var coordinator: SerialSessionCoordinator?
    private let config: SerialConnectionConfig

    init(coordinator: SerialSessionCoordinator, config: SerialConnectionConfig) {
        self.coordinator = coordinator
        self.config = config
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        guard let coordinator else {
            throw RemoteTerminalLifecycleError.reconnectUnavailable
        }
        return try coordinator.startRuntime(config: config)
    }

    func reconnectRemoteTerminalInBackground(
        title: String,
        automatically: Bool,
        completion: @escaping @MainActor (Result<LiveShellStatus, Error>) -> Void
    ) {
        guard let coordinator else {
            completion(.failure(RemoteTerminalLifecycleError.reconnectUnavailable))
            return
        }
        coordinator.startRuntimeInBackground(config: config, completion: completion)
    }
}
