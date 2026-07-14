import Foundation
import StacioCoreBindings

private struct RemoteSSHUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

public protocol TunnelLiveSessionContextBuilding {
    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: (String) throws -> SessionRecord?
    ) throws -> TunnelLiveSessionContext
}

public extension TunnelLiveSessionContextBuilding {
    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: (String) throws -> SessionRecord?
    ) throws -> TunnelLiveSessionContext {
        try makeTunnelLiveSessionContext(
            config: config,
            databasePath: databasePath
        )
    }
}

extension SSHConnectionCoordinator: TunnelLiveSessionContextBuilding {}

public protocol LiveShellStarting {
    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus

    func startLiveSSHShellRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus
}

public extension LiveShellStarting {
    func startLiveSSHShellRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        throw SshRuntimeError.Transport(message: "ProxyJump runtime is not supported by this starter")
    }
}

public protocol LiveShellRuntimeClosing {
    func closeLiveSSHShellRuntime(runtimeID: String) throws
}

public struct CoreBridgeLiveShellStarter: LiveShellStarting, LiveShellRuntimeClosing {
    public init() {}

    public func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try CoreBridge.startLiveSSHShellRuntime(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            cols: cols,
            rows: rows
        )
    }

    public func startLiveSSHShellRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try CoreBridge.startLiveSSHShellRuntimeWithProxyJump(
            config: config,
            secret: secret,
            proxyJump: proxyJump,
            cols: cols,
            rows: rows
        )
    }

    public func closeLiveSSHShellRuntime(runtimeID: String) throws {
        _ = try CoreBridge.closeLiveSSHShell(runtimeID: runtimeID)
    }
}

@MainActor
public protocol RemoteWorkspaceOpening: AnyObject {
    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteTerminalPaneViewController

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    )

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind
    )
}

@MainActor
public extension RemoteWorkspaceOpening {
    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteTerminalPaneViewController {
        let pane = RemoteTerminalPaneViewController(
            runtimeID: "pending_\(UUID().uuidString.lowercased())",
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            eventSink: CoreBridgeTerminalEventSink(),
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        pane.displayConnectionStarting()
        return pane
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openRemoteShell(status: status, title: title, reconnecter: reconnecter, connectionKind: .ssh)
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind
    ) {
        openRemoteShell(status: status, title: title, reconnecter: reconnecter)
    }
}

@MainActor
public protocol RemoteWorkspaceAutomationOpening: RemoteWorkspaceOpening {
    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?,
        automationPolicy: SessionAutomationPolicy
    ) -> RemoteTerminalPaneViewController

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        automationPolicy: SessionAutomationPolicy
    )
}

@MainActor
public extension RemoteWorkspaceAutomationOpening {
    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        automationPolicy: SessionAutomationPolicy
    ) {
        openRemoteShell(status: status, title: title, reconnecter: reconnecter, connectionKind: connectionKind)
    }
}

@MainActor
public protocol RemoteWorkspaceLiveSessionOpening: RemoteWorkspaceOpening {
    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        liveSessionContext: TunnelLiveSessionContext?
    )

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    )
}

@MainActor
public extension RemoteWorkspaceLiveSessionOpening {
    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        openRemoteShell(status: status, title: title, reconnecter: reconnecter)
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        openRemoteShell(
            status: status,
            title: title,
            reconnecter: reconnecter,
            liveSessionContext: liveSessionContext
        )
    }
}

@MainActor
public protocol RemoteWorkspaceLiveSessionAutomationOpening: RemoteWorkspaceLiveSessionOpening, RemoteWorkspaceAutomationOpening {
    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?,
        automationPolicy: SessionAutomationPolicy
    )
}

@MainActor
public extension RemoteWorkspaceLiveSessionAutomationOpening {
    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        automationPolicy: SessionAutomationPolicy
    ) {
        openRemoteShell(
            status: status,
            title: title,
            reconnecter: reconnecter,
            connectionKind: connectionKind,
            liveSessionContext: nil,
            automationPolicy: automationPolicy
        )
    }
}

extension WorkspaceViewController: RemoteWorkspaceLiveSessionAutomationOpening {}

fileprivate struct RemoteSSHRuntimeStartResult {
    let status: LiveShellStatus
    let context: TunnelLiveSessionContext
    let shellElapsedMs: UInt32
}

enum RemoteSSHReconnectPolicy {
    static let maximumAdaptiveTimeoutMs: UInt32 = 60_000
    static let adaptiveTimeoutMultiplier = 1.5

    static func timeoutMs(
        currentTimeoutMs: UInt32,
        lastSuccessfulShellElapsedMs: UInt32?
    ) -> UInt32 {
        guard let lastSuccessfulShellElapsedMs, lastSuccessfulShellElapsedMs > 0 else {
            return currentTimeoutMs
        }
        let adaptiveTimeout = UInt32(
            min(
                Double(maximumAdaptiveTimeoutMs),
                ceil(Double(lastSuccessfulShellElapsedMs) * adaptiveTimeoutMultiplier)
            )
        )
        return max(currentTimeoutMs, adaptiveTimeout)
    }

    static func configForReconnect(
        _ config: SshConnectionConfig,
        lastSuccessfulShellElapsedMs: UInt32?
    ) -> SshConnectionConfig {
        var reconnectConfig = config
        reconnectConfig.connectTimeoutMs = timeoutMs(
            currentTimeoutMs: config.connectTimeoutMs,
            lastSuccessfulShellElapsedMs: lastSuccessfulShellElapsedMs
        )
        return reconnectConfig
    }

    static func automaticDelaySeconds(forAttempt attempt: Int) -> TimeInterval {
        switch max(1, attempt) {
        case 1:
            return 0
        case 2:
            return 3
        case 3:
            return 8
        case 4:
            return 20
        default:
            return 60
        }
    }
}

@MainActor
public final class RemoteSSHSessionCoordinator {
    private let contextBuilder: TunnelLiveSessionContextBuilding
    private let liveShellStarter: LiveShellStarting
    private let contextStore: TunnelLiveSessionStore
    private weak var workspace: RemoteWorkspaceOpening?
    private let databasePathProvider: () -> String
    private let defaultCols: UInt32
    private let defaultRows: UInt32
    private let appLog: StacioLogWriting?
    private let clock: () -> Date

    public init(
        contextBuilder: TunnelLiveSessionContextBuilding,
        liveShellStarter: LiveShellStarting = CoreBridgeLiveShellStarter(),
        contextStore: TunnelLiveSessionStore,
        workspace: RemoteWorkspaceOpening,
        databasePathProvider: @escaping () -> String,
        defaultCols: UInt32 = 80,
        defaultRows: UInt32 = 24,
        appLog: StacioLogWriting? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.contextBuilder = contextBuilder
        self.liveShellStarter = liveShellStarter
        self.contextStore = contextStore
        self.workspace = workspace
        self.databasePathProvider = databasePathProvider
        self.defaultCols = defaultCols
        self.defaultRows = defaultRows
        self.appLog = appLog
        self.clock = clock
    }

    @discardableResult
    public func start(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy = .default
    ) throws -> LiveShellStatus {
        try start(
            config: config,
            title: title,
            automationPolicy: automationPolicy,
            proxyJumpSelection: .disabled,
            proxyJumpSessionResolver: { _ in nil }
        )
    }

    @discardableResult
    public func start(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy = .default,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?
    ) throws -> LiveShellStatus {
        try openSessionTab(
            config: config,
            title: title,
            automationPolicy: automationPolicy,
            proxyJumpSelection: proxyJumpSelection,
            proxyJumpSessionResolver: proxyJumpSessionResolver
        )
    }

    @discardableResult
    public func openSessionTab(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy = .default
    ) throws -> LiveShellStatus {
        try openSessionTab(
            config: config,
            title: title,
            automationPolicy: automationPolicy,
            proxyJumpSelection: .disabled,
            proxyJumpSessionResolver: { _ in nil }
        )
    }

    @discardableResult
    public func openSessionTab(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy = .default,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?
    ) throws -> LiveShellStatus {
        logSessionStartRequested(config: config, mode: "background")
        guard let workspace else {
            logSessionStartFailed(config: config, error: RemoteTerminalLifecycleError.reconnectUnavailable, mode: "background")
            throw RemoteTerminalLifecycleError.reconnectUnavailable
        }
        let reconnecter = RemoteSSHSessionReconnecter(
            coordinator: self,
            config: config,
            liveSessionContext: nil,
            lastSuccessfulShellElapsedMs: nil,
            proxyJumpSelection: proxyJumpSelection,
            proxyJumpSessionResolver: proxyJumpSessionResolver
        )
        let pane: RemoteTerminalPaneViewController?
        if let workspace = workspace as? RemoteWorkspaceAutomationOpening {
            pane = workspace.openConnectingRemoteShell(
                title: title,
                reconnecter: reconnecter,
                connectionKind: .ssh,
                liveSessionContext: nil,
                automationPolicy: automationPolicy
            )
        } else {
            pane = workspace.openConnectingRemoteShell(
                title: title,
                reconnecter: reconnecter,
                connectionKind: .ssh,
                liveSessionContext: nil
            )
        }
        pane?.displayConnectionStarting()
        let pendingStatus = LiveShellStatus(
            runtimeId: pane?.runtimeID ?? "pending_\(UUID().uuidString.lowercased())",
            status: "connecting",
            diagnostic: L10n.TerminalLifecycle.connecting
        )
        startRuntimeInBackground(
            config: config,
            title: title,
            reconnecter: reconnecter,
            pane: pane,
            automationPolicy: automationPolicy,
            proxyJumpSelection: proxyJumpSelection,
            proxyJumpSessionResolver: proxyJumpSessionResolver
        )
        return pendingStatus
    }

    @discardableResult
    public func reconnect(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        try openSessionTab(config: config, title: title)
    }

    nonisolated private static func diagnosticMessage(forStatusDiagnostic diagnostic: String) -> String {
        let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "SSH runtime did not enter running state" : message
    }

    private func startRuntimeInBackground(
        config: SshConnectionConfig,
        title: String,
        reconnecter: RemoteSSHSessionReconnecter,
        pane: RemoteTerminalPaneViewController?,
        automationPolicy: SessionAutomationPolicy,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?
    ) {
        let liveShellCloser = RemoteSSHUncheckedSendable(value: liveShellStarter as? LiveShellRuntimeClosing)
        let contextBuilder = RemoteSSHUncheckedSendable(value: contextBuilder)
        let liveShellStarter = RemoteSSHUncheckedSendable(value: liveShellStarter)
        let contextStore = RemoteSSHUncheckedSendable(value: contextStore)
        let appLog = RemoteSSHUncheckedSendable(value: appLog)
        let clock = RemoteSSHUncheckedSendable(value: clock)
        let endpointDescription = Self.endpointDescription(for: config)
        let requestDescription = Self.connectionRequestDescription(for: config)
        let databasePath = databasePathProvider()
        let defaultCols = defaultCols
        let defaultRows = defaultRows

        DispatchQueue.global(qos: .userInitiated).async { [weak pane, weak reconnecter] in
            let startDate = Date()
            do {
                appLog.value?.append(
                    level: .info,
                    category: "SSH",
                    message: "ssh.session.runtime.prepare mode=background \(requestDescription)"
                )
                let contextStartDate = Date()
                let context = try contextBuilder.value.makeTunnelLiveSessionContext(
                    config: config,
                    databasePath: databasePath,
                    proxyJumpSelection: proxyJumpSelection,
                    proxyJumpSessionResolver: proxyJumpSessionResolver
                )
                let contextElapsedMs = Self.elapsedMilliseconds(since: contextStartDate)
                appLog.value?.append(
                    level: .info,
                    category: "SSH",
                    message: "ssh.session.runtime.context.ready mode=background endpoint=\(endpointDescription) context_ms=\(contextElapsedMs)"
                )
                let shellStartDate = clock.value()
                let status = try Self.startLiveShell(
                    starter: liveShellStarter.value,
                    context: context,
                    cols: defaultCols,
                    rows: defaultRows
                )
                let shellElapsedMs = Self.elapsedMilliseconds(since: shellStartDate, now: clock.value())
                let totalElapsedMs = Self.elapsedMilliseconds(since: startDate)
                guard status.status == "running" else {
                    try? liveShellCloser.value?.closeLiveSSHShellRuntime(runtimeID: status.runtimeId)
                    throw SshRuntimeError.Transport(message: Self.diagnosticMessage(forStatusDiagnostic: status.diagnostic))
                }
                contextStore.value.replace(with: context)
                appLog.value?.append(
                    level: .info,
                    category: "SSH",
                    message: [
                        "ssh.session.start.succeeded",
                        "mode=background",
                        "endpoint=\(endpointDescription)",
                        "runtime=\(status.runtimeId)",
                        "context_ms=\(contextElapsedMs)",
                        "shell_ms=\(shellElapsedMs)",
                        "total_ms=\(totalElapsedMs)"
                    ].joined(separator: " ")
                )
                DispatchQueue.main.async {
                    guard let pane, pane.lifecycleState != .closed else {
                        if let current = contextStore.value.current(),
                           Self.isSameLiveSessionContext(current, context) {
                            contextStore.value.clear()
                        }
                        try? liveShellCloser.value?.closeLiveSSHShellRuntime(runtimeID: status.runtimeId)
                        return
                    }
                    reconnecter?.update(
                        liveSessionContext: context,
                        lastSuccessfulShellElapsedMs: shellElapsedMs
                    )
                    pane.attachConnectedRuntime(
                        status: status,
                        liveSessionContext: context,
                        automationPolicy: automationPolicy,
                        startupBanner: SSHSessionStartupBanner(
                            context: context,
                            title: title,
                            runtimeID: status.runtimeId,
                            automationPolicy: automationPolicy
                        ).rendered()
                    )
                }
            } catch {
                let diagnostic = RuntimeDiagnosticFormatter.userMessage(for: error)
                appLog.value?.append(
                    level: .error,
                    category: "SSH",
                    message: "ssh.session.start.failed mode=background endpoint=\(endpointDescription) diagnostic=\(diagnostic)"
                )
                DispatchQueue.main.async {
                    pane?.displayConnectionFailure(diagnostic)
                }
            }
        }
    }

    fileprivate func reconnectRuntimeInBackground(
        config: SshConnectionConfig,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?,
        completion: @escaping @MainActor (Result<RemoteSSHRuntimeStartResult, Error>) -> Void
    ) {
        let liveShellCloser = RemoteSSHUncheckedSendable(value: liveShellStarter as? LiveShellRuntimeClosing)
        let contextBuilder = RemoteSSHUncheckedSendable(value: contextBuilder)
        let liveShellStarter = RemoteSSHUncheckedSendable(value: liveShellStarter)
        let clock = RemoteSSHUncheckedSendable(value: clock)
        let databasePath = databasePathProvider()
        let defaultCols = defaultCols
        let defaultRows = defaultRows

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<RemoteSSHRuntimeStartResult, Error>
            do {
                let context = try contextBuilder.value.makeTunnelLiveSessionContext(
                    config: config,
                    databasePath: databasePath,
                    proxyJumpSelection: proxyJumpSelection,
                    proxyJumpSessionResolver: proxyJumpSessionResolver
                )
                let shellStartDate = clock.value()
                let status = try Self.startLiveShell(
                    starter: liveShellStarter.value,
                    context: context,
                    cols: defaultCols,
                    rows: defaultRows
                )
                let shellElapsedMs = Self.elapsedMilliseconds(since: shellStartDate, now: clock.value())
                guard status.status == "running" else {
                    try? liveShellCloser.value?.closeLiveSSHShellRuntime(runtimeID: status.runtimeId)
                    throw SshRuntimeError.Transport(
                        message: Self.diagnosticMessage(forStatusDiagnostic: status.diagnostic)
                    )
                }
                result = .success(
                    RemoteSSHRuntimeStartResult(
                        status: status,
                        context: context,
                        shellElapsedMs: shellElapsedMs
                    )
                )
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    nonisolated private static func elapsedMilliseconds(since date: Date, now: Date = Date()) -> UInt32 {
        let milliseconds = max(0, Int(now.timeIntervalSince(date) * 1000))
        return UInt32(min(milliseconds, Int(UInt32.max)))
    }

    nonisolated private static func startLiveShell(
        starter: LiveShellStarting,
        context: TunnelLiveSessionContext,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        if let proxyJump = context.proxyJump {
            return try starter.startLiveSSHShellRuntimeWithProxyJump(
                config: context.config,
                secret: context.secret,
                proxyJump: proxyJump,
                cols: cols,
                rows: rows
            )
        }
        return try starter.startLiveSSHShellRuntime(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            cols: cols,
            rows: rows
        )
    }

    fileprivate func logSessionStartRequested(
        config: SshConnectionConfig,
        mode: String
    ) {
        appLog?.append(
            level: .info,
            category: "SSH",
            message: "ssh.session.start.request mode=\(mode) endpoint=\(Self.endpointDescription(for: config)) auth=\(Self.authMethodDescription(for: config))"
        )
    }

    fileprivate func acceptReconnectRuntime(_ result: RemoteSSHRuntimeStartResult) {
        contextStore.replace(with: result.context)
    }

    fileprivate func discardReconnectRuntime(_ result: RemoteSSHRuntimeStartResult) {
        try? (liveShellStarter as? LiveShellRuntimeClosing)?
            .closeLiveSSHShellRuntime(runtimeID: result.status.runtimeId)
    }

    fileprivate func logSessionStartSucceeded(
        config: SshConnectionConfig,
        status: LiveShellStatus,
        mode: String
    ) {
        appLog?.append(
            level: .info,
            category: "SSH",
            message: "ssh.session.start.succeeded mode=\(mode) endpoint=\(Self.endpointDescription(for: config)) runtime=\(status.runtimeId)"
        )
    }

    fileprivate func logSessionStartFailed(
        config: SshConnectionConfig,
        error: Error,
        mode: String
    ) {
        appLog?.append(
            level: .error,
            category: "SSH",
            message: "ssh.session.start.failed mode=\(mode) endpoint=\(Self.endpointDescription(for: config)) diagnostic=\(RuntimeDiagnosticFormatter.userMessage(for: error))"
        )
    }

    private static func endpointDescription(for config: SshConnectionConfig) -> String {
        "\(config.host):\(config.port)"
    }

    private static func connectionRequestDescription(for config: SshConnectionConfig) -> String {
        [
            "endpoint=\(endpointDescription(for: config))",
            "username=\(config.username)",
            "auth=\(authMethodDescription(for: config))",
            "timeout_ms=\(config.connectTimeoutMs)"
        ].joined(separator: " ")
    }

    private static func authMethodDescription(for config: SshConnectionConfig) -> String {
        switch config.authMethod {
        case .agent:
            return "agent"
        case .password:
            return "password"
        case .privateKey:
            return "private_key"
        }
    }

    nonisolated private static func isSameLiveSessionContext(
        _ lhs: TunnelLiveSessionContext,
        _ rhs: TunnelLiveSessionContext
    ) -> Bool {
        lhs.config.host == rhs.config.host
            && lhs.config.port == rhs.config.port
            && lhs.config.username == rhs.config.username
            && lhs.config.authMethod == rhs.config.authMethod
            && lhs.expectedFingerprintSHA256 == rhs.expectedFingerprintSHA256
    }
}

@MainActor
public protocol RemoteSSHSessionStarting: AnyObject {
    @discardableResult
    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus

    @discardableResult
    func openSessionTab(config: SshConnectionConfig, title: String) throws -> LiveShellStatus
}

@MainActor
public extension RemoteSSHSessionStarting {
    @discardableResult
    func openSessionTab(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        try start(config: config, title: title)
    }
}

@MainActor
public protocol RemoteSSHSessionAutomationStarting: RemoteSSHSessionStarting {
    @discardableResult
    func start(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> LiveShellStatus

    @discardableResult
    func openSessionTab(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> LiveShellStatus
}

@MainActor
public protocol RemoteSSHSessionProxyJumpStarting: RemoteSSHSessionAutomationStarting {
    @discardableResult
    func openSessionTab(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?
    ) throws -> LiveShellStatus
}

@MainActor
public extension RemoteSSHSessionAutomationStarting {
    @discardableResult
    func start(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        try start(config: config, title: title, automationPolicy: .default)
    }

    @discardableResult
    func openSessionTab(config: SshConnectionConfig, title: String) throws -> LiveShellStatus {
        try openSessionTab(config: config, title: title, automationPolicy: .default)
    }

    @discardableResult
    func openSessionTab(
        config: SshConnectionConfig,
        title: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> LiveShellStatus {
        try start(config: config, title: title, automationPolicy: automationPolicy)
    }
}

extension RemoteSSHSessionCoordinator: RemoteSSHSessionProxyJumpStarting {}

@MainActor
private final class RemoteSSHSessionReconnecter: RemoteTerminalBackgroundReconnecting {
    private weak var coordinator: RemoteSSHSessionCoordinator?
    private let config: SshConnectionConfig
    private(set) var liveSessionContext: TunnelLiveSessionContext?
    private var lastSuccessfulShellElapsedMs: UInt32?
    private var automaticAttemptCount = 0
    private var reconnectGeneration: UInt64 = 0
    private let proxyJumpSelection: SSHProxyJumpSelection
    private let proxyJumpSessionResolver: (String) throws -> SessionRecord?

    init(
        coordinator: RemoteSSHSessionCoordinator,
        config: SshConnectionConfig,
        liveSessionContext: TunnelLiveSessionContext?,
        lastSuccessfulShellElapsedMs: UInt32?,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: @escaping (String) throws -> SessionRecord?
    ) {
        self.coordinator = coordinator
        self.config = config
        self.liveSessionContext = liveSessionContext
        self.lastSuccessfulShellElapsedMs = lastSuccessfulShellElapsedMs
        self.proxyJumpSelection = proxyJumpSelection
        self.proxyJumpSessionResolver = proxyJumpSessionResolver
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        throw RemoteTerminalLifecycleError.reconnectUnavailable
    }

    func reconnectRemoteTerminalAutomatically(title: String) throws -> LiveShellStatus {
        throw RemoteTerminalLifecycleError.reconnectUnavailable
    }

    func automaticReconnectDelaySeconds() -> TimeInterval {
        automaticAttemptCount += 1
        return RemoteSSHReconnectPolicy.automaticDelaySeconds(forAttempt: automaticAttemptCount)
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
        let mode = automatically ? "auto_reconnect" : "reconnect"
        let reconnectConfig = RemoteSSHReconnectPolicy.configForReconnect(
            config,
            lastSuccessfulShellElapsedMs: lastSuccessfulShellElapsedMs
        )
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        coordinator.logSessionStartRequested(config: reconnectConfig, mode: mode)
        coordinator.reconnectRuntimeInBackground(
            config: reconnectConfig,
            proxyJumpSelection: proxyJumpSelection,
            proxyJumpSessionResolver: proxyJumpSessionResolver
        ) { [weak self, weak coordinator] result in
            guard let coordinator else {
                completion(.failure(RemoteTerminalLifecycleError.reconnectUnavailable))
                return
            }
            guard let self else {
                if case let .success(runtimeResult) = result {
                    coordinator.discardReconnectRuntime(runtimeResult)
                }
                completion(.failure(RemoteTerminalLifecycleError.reconnectUnavailable))
                return
            }
            guard generation == self.reconnectGeneration else {
                if case let .success(runtimeResult) = result {
                    coordinator.discardReconnectRuntime(runtimeResult)
                }
                completion(.failure(RemoteTerminalLifecycleError.reconnectUnavailable))
                return
            }
            switch result {
            case let .success(runtimeResult):
                coordinator.logSessionStartSucceeded(
                    config: reconnectConfig,
                    status: runtimeResult.status,
                    mode: mode
                )
                coordinator.acceptReconnectRuntime(runtimeResult)
                self.liveSessionContext = runtimeResult.context
                self.lastSuccessfulShellElapsedMs = runtimeResult.shellElapsedMs
                self.automaticAttemptCount = 0
                completion(.success(runtimeResult.status))
            case let .failure(error):
                coordinator.logSessionStartFailed(config: reconnectConfig, error: error, mode: mode)
                completion(.failure(error))
            }
        }
    }

    func cancelPendingReconnects() {
        reconnectGeneration &+= 1
    }

    func update(
        liveSessionContext: TunnelLiveSessionContext,
        lastSuccessfulShellElapsedMs: UInt32
    ) {
        self.liveSessionContext = liveSessionContext
        self.lastSuccessfulShellElapsedMs = lastSuccessfulShellElapsedMs
        self.automaticAttemptCount = 0
    }
}
