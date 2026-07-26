import Foundation
import StacioCoreBindings

public enum RemoteChromiumRuntimeError: Error, Equatable, LocalizedError {
    case browserUnavailable
    case invalidLaunchMetadata
    case commandFailed(String)
    case commandTimedOut
    case webSocketConnectionTimedOut
    case tunnelFailed(String)
    case pageEndpointUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            return "远端未安装受支持的 Chromium 浏览器。"
        case .invalidLaunchMetadata:
            return "远端 Chromium 返回了无效的启动信息。"
        case let .commandFailed(message):
            return "远端 Chromium 命令失败：\(message)"
        case .commandTimedOut:
            return "远端 Chromium 命令执行超时。"
        case .webSocketConnectionTimedOut:
            return "远端 Chromium 调试连接超时。"
        case let .tunnelFailed(message):
            return "远端 Chromium 调试通道失败：\(message)"
        case let .pageEndpointUnavailable(message):
            return "远端 Chromium 页面端点不可用：\(message)"
        }
    }
}

public struct RemoteChromiumCommandExecutionFailure: Error, LocalizedError {
    public let error: RemoteChromiumRuntimeError
    public let partialOutput: String

    public init(error: RemoteChromiumRuntimeError, partialOutput: String) {
        self.error = error
        self.partialOutput = partialOutput
    }

    public var errorDescription: String? {
        error.errorDescription
    }
}

public struct RemoteChromiumRuntimeSession: Equatable, Sendable {
    public let leaseID: UUID
    public let remoteProcessID: Int
    public let remoteTemporaryDirectory: String
    public let remoteDownloadsDirectory: String
    public let localDebugPort: UInt16
    public let pageWebSocketURL: URL
    let downloadCapability: RemoteChromiumDownloadCapability

    public init(
        leaseID: UUID = UUID(),
        remoteProcessID: Int,
        remoteTemporaryDirectory: String,
        remoteDownloadsDirectory: String,
        localDebugPort: UInt16,
        pageWebSocketURL: URL
    ) {
        self.init(
            leaseID: leaseID,
            remoteProcessID: remoteProcessID,
            remoteTemporaryDirectory: remoteTemporaryDirectory,
            remoteDownloadsDirectory: remoteDownloadsDirectory,
            localDebugPort: localDebugPort,
            pageWebSocketURL: pageWebSocketURL,
            downloadCapability: RemoteChromiumDownloadCapability()
        )
    }

    init(
        leaseID: UUID = UUID(),
        remoteProcessID: Int,
        remoteTemporaryDirectory: String,
        remoteDownloadsDirectory: String,
        localDebugPort: UInt16,
        pageWebSocketURL: URL,
        downloadCapability: RemoteChromiumDownloadCapability
    ) {
        self.leaseID = leaseID
        self.remoteProcessID = remoteProcessID
        self.remoteTemporaryDirectory = remoteTemporaryDirectory
        self.remoteDownloadsDirectory = remoteDownloadsDirectory
        self.localDebugPort = localDebugPort
        self.pageWebSocketURL = pageWebSocketURL
        self.downloadCapability = downloadCapability
    }
}

public protocol RemoteChromiumRuntimeControlling: AnyObject {
    func start(context: TunnelLiveSessionContext, localPort: UInt16) throws -> RemoteChromiumRuntimeSession
    func stop(session: RemoteChromiumRuntimeSession)
    @discardableResult func retainDownload(_ download: RemoteChromiumDownload) -> Bool
    @discardableResult
    func acknowledgeDownload(
        _ download: RemoteChromiumDownload,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool
}

public protocol RemoteChromiumCommandExecuting: AnyObject {
    func execute(
        command: String,
        context: TunnelLiveSessionContext,
        timeout: TimeInterval
    ) throws -> String
}

public final class CoreRemoteChromiumCommandExecutor: RemoteChromiumCommandExecuting {
    private let shellStarter: LiveShellStarting
    private let runtimeBridge: AgentBackgroundRuntimeBridging
    private let pollInterval: TimeInterval

    public init(
        shellStarter: LiveShellStarting = CoreBridgeLiveShellStarter(),
        runtimeBridge: AgentBackgroundRuntimeBridging = CoreBridgeAgentBackgroundRuntimeBridge(),
        pollInterval: TimeInterval = 0.08
    ) {
        self.shellStarter = shellStarter
        self.runtimeBridge = runtimeBridge
        self.pollInterval = max(0, pollInterval)
    }

    public func execute(
        command: String,
        context: TunnelLiveSessionContext,
        timeout: TimeInterval
    ) throws -> String {
        let status: LiveShellStatus
        if let proxyJump = context.proxyJump {
            status = try shellStarter.startLiveSSHShellRuntimeWithProxyJump(
                config: context.config,
                secret: context.secret,
                proxyJump: proxyJump,
                cols: 100,
                rows: 24
            )
        } else {
            status = try shellStarter.startLiveSSHShellRuntime(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                cols: 100,
                rows: 24
            )
        }
        guard status.status == "running" else {
            try? runtimeBridge.closeTerminalRuntime(runtimeID: status.runtimeId)
            throw RemoteChromiumRuntimeError.commandFailed(
                Self.conciseMessage(status.diagnostic, fallback: "SSH runtime did not enter running state")
            )
        }
        defer { try? runtimeBridge.closeTerminalRuntime(runtimeID: status.runtimeId) }

        let wrappedCommand = """
        __STACIO_CHROMIUM_COMMAND=\(Self.shellSingleQuoted(command))
        sh -c "$__STACIO_CHROMIUM_COMMAND"
        __STACIO_CHROMIUM_STATUS=$?
        printf '\\n__STACIO_CHROMIUM_COMMAND_DONE__=%s\\n' "$__STACIO_CHROMIUM_STATUS"
        exit
        """
        try runtimeBridge.writeTerminalInput(
            runtimeID: status.runtimeId,
            bytes: Array(wrappedCommand.utf8)
        )

        var output = Data()
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while Date() < deadline {
            let liveStatus: LiveShellStatus
            let batch: TerminalOutputBatch
            do {
                liveStatus = try runtimeBridge.pollLiveSSHShell(runtimeID: status.runtimeId)
                batch = try runtimeBridge.takeTerminalOutputBatch(runtimeID: status.runtimeId)
            } catch {
                throw RemoteChromiumCommandExecutionFailure(
                    error: .commandFailed(RuntimeDiagnosticFormatter.userMessage(for: error)),
                    partialOutput: String(decoding: output, as: UTF8.self)
                )
            }
            if batch.bytes.isEmpty == false {
                output.append(batch.bytes)
                if output.count > 512 * 1_024 {
                    output.removeFirst(output.count - 512 * 1_024)
                }
            }
            let decoded = String(decoding: output, as: UTF8.self)
            if let exitStatus = Self.commandExitStatus(in: decoded) {
                guard exitStatus == 0 else {
                    throw RemoteChromiumCommandExecutionFailure(
                        error: .commandFailed(
                            Self.conciseMessage(decoded, fallback: "exit status \(exitStatus)")
                        ),
                        partialOutput: decoded
                    )
                }
                return decoded
            }
            if liveStatus.status != "running" {
                throw RemoteChromiumCommandExecutionFailure(
                    error: .commandFailed(
                        Self.conciseMessage(decoded, fallback: liveStatus.diagnostic)
                    ),
                    partialOutput: decoded
                )
            }
            if pollInterval > 0 {
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        throw RemoteChromiumCommandExecutionFailure(
            error: .commandTimedOut,
            partialOutput: String(decoding: output, as: UTF8.self)
        )
    }

    private static func commandExitStatus(in output: String) -> Int? {
        markerValue("__STACIO_CHROMIUM_COMMAND_DONE__", in: output).flatMap(Int.init)
    }

    fileprivate static func markerValue(_ marker: String, in output: String) -> String? {
        output.components(separatedBy: .newlines).reversed().compactMap { line in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(marker)="
            guard let range = normalized.range(of: prefix) else { return nil }
            return String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
    }

    private static func conciseMessage(_ value: String, fallback: String) -> String {
        let lines = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.contains("__STACIO_CHROMIUM_COMMAND") == false }
        return String((lines.last ?? fallback).prefix(400))
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public final class RemoteChromiumRuntime: RemoteChromiumRuntimeControlling {
    public static let launchCommand = """
    set -eu
    STACIO_CHROMIUM_BINARY=''
    for STACIO_CHROMIUM_CANDIDATE in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "$STACIO_CHROMIUM_CANDIDATE" >/dev/null 2>&1; then
            STACIO_CHROMIUM_BINARY=$(command -v "$STACIO_CHROMIUM_CANDIDATE")
            break
        fi
    done
    if [ -z "$STACIO_CHROMIUM_BINARY" ]; then
        printf '__STACIO_CHROMIUM_ERROR__=browser_not_found\\n'
        exit 127
    fi
    if [ "$(id -u)" = 0 ]; then
        printf '__STACIO_CHROMIUM_ERROR__=root_not_supported\\n'
        exit 125
    fi
    STACIO_CHROMIUM_DIR=$(mktemp -d /tmp/stacio-chromium.XXXXXX)
    printf '__STACIO_CHROMIUM_DIR__=%s\\n' "$STACIO_CHROMIUM_DIR"
    mkdir -p "$STACIO_CHROMIUM_DIR/profile" "$STACIO_CHROMIUM_DIR/downloads"
    nohup "$STACIO_CHROMIUM_BINARY" \
        --headless \
        --disable-gpu \
        --disable-dev-shm-usage \
        --no-first-run \
        --no-default-browser-check \
        --remote-debugging-address=127.0.0.1 \
        --remote-debugging-port=0 \
        --user-data-dir="$STACIO_CHROMIUM_DIR/profile" \
        about:blank >"$STACIO_CHROMIUM_DIR/chromium.log" 2>&1 </dev/null &
    STACIO_CHROMIUM_PID=$!
    printf '__STACIO_CHROMIUM_PID__=%s\\n' "$STACIO_CHROMIUM_PID"
    STACIO_CHROMIUM_ATTEMPT=0
    while [ "$STACIO_CHROMIUM_ATTEMPT" -lt 80 ]; do
        if [ -s "$STACIO_CHROMIUM_DIR/profile/DevToolsActivePort" ]; then
            break
        fi
        if ! kill -0 "$STACIO_CHROMIUM_PID" 2>/dev/null; then
            cat "$STACIO_CHROMIUM_DIR/chromium.log" 2>/dev/null || true
            rm -rf -- "$STACIO_CHROMIUM_DIR"
            exit 126
        fi
        STACIO_CHROMIUM_ATTEMPT=$((STACIO_CHROMIUM_ATTEMPT + 1))
        sleep 0.1
    done
    if [ ! -s "$STACIO_CHROMIUM_DIR/profile/DevToolsActivePort" ]; then
        kill "$STACIO_CHROMIUM_PID" 2>/dev/null || true
        rm -rf -- "$STACIO_CHROMIUM_DIR"
        exit 124
    fi
    STACIO_CHROMIUM_PORT=$(sed -n '1p' "$STACIO_CHROMIUM_DIR/profile/DevToolsActivePort")
    printf '__STACIO_CHROMIUM_PORT__=%s\\n' "$STACIO_CHROMIUM_PORT"
    printf '__STACIO_CHROMIUM_BINARY__=%s\\n' "$STACIO_CHROMIUM_BINARY"
    """

    private struct LaunchMetadata {
        let processID: Int
        let temporaryDirectory: String
        let remoteDebugPort: UInt16
    }

    private struct PartialLaunchMetadata {
        let processID: Int?
        let temporaryDirectory: String
    }

    private struct PendingLaunchCleanup {
        let id: UUID
        let context: TunnelLiveSessionContext
        let metadata: PartialLaunchMetadata
        let tunnelProfile: TunnelProfile?
        let tunnelState: TunnelState?
        var needsTunnelCleanup: Bool
        var needsBrowserCleanup: Bool
    }

    private struct ActiveRuntime {
        let context: TunnelLiveSessionContext
        let session: RemoteChromiumRuntimeSession
        let tunnelProfile: TunnelProfile
        let tunnelState: TunnelState
        var retainedDownloadPaths: Set<String> = []
        var isStopped = false
        var needsTunnelCleanup = true
        var needsBrowserCleanup = true
    }

    private struct RetainedDownloadIdentity: Hashable {
        let sessionLeaseID: UUID
        let remotePath: String
        let capability: RemoteChromiumDownloadCapability

        init(_ download: RemoteChromiumDownload) {
            self.sessionLeaseID = download.sessionLeaseID
            self.remotePath = download.remotePath
            self.capability = download.capability
        }
    }

    private enum DownloadCleanupAction {
        case file
        case directory
    }

    private final class DetachedCleanupWorker: @unchecked Sendable {
        private var runtime: ActiveRuntime
        private var pendingAcknowledgedPaths: Set<String>
        private let commandExecutor: RemoteChromiumCommandExecuting
        private let tunnelBridge: TunnelRuntimeBridging
        private let commandTimeout: TimeInterval
        private let retryDelays: [TimeInterval]
        private let diagnosticLog: StacioLogWriting?
        private let queue: DispatchQueue
        private var retryIndex = 0

        init(
            runtime: ActiveRuntime,
            pendingAcknowledgedPaths: Set<String>,
            commandExecutor: RemoteChromiumCommandExecuting,
            tunnelBridge: TunnelRuntimeBridging,
            commandTimeout: TimeInterval,
            retryDelays: [TimeInterval],
            diagnosticLog: StacioLogWriting?,
            queue: DispatchQueue
        ) {
            self.runtime = runtime
            self.pendingAcknowledgedPaths = pendingAcknowledgedPaths
            self.commandExecutor = commandExecutor
            self.tunnelBridge = tunnelBridge
            self.commandTimeout = commandTimeout
            self.retryDelays = retryDelays
            self.diagnosticLog = diagnosticLog
            self.queue = queue
        }

        func start() {
            scheduleNextAttempt()
        }

        private func scheduleNextAttempt() {
            guard retryIndex < retryDelays.count else {
                diagnosticLog?.append(
                    level: .warning,
                    category: "Browser",
                    message: "remote.chromium.cleanup.exhausted stage=deinit lease=\(runtime.session.leaseID.uuidString.lowercased()) attempts=\(retryIndex + 2)"
                )
                return
            }
            let delay = retryDelays[retryIndex]
            retryIndex += 1
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                runAttempt()
            }
        }

        private func runAttempt() {
            var failures: [String] = []
            if runtime.needsTunnelCleanup {
                do {
                    let status = try tunnelBridge.stop(
                        profile: runtime.tunnelProfile,
                        state: runtime.tunnelState
                    )
                    guard status.profileId == runtime.tunnelProfile.id,
                          status.state == .stopped
                    else {
                        throw RemoteChromiumRuntimeError.tunnelFailed(
                            "cleanup status mismatch: \(status.profileId) \(status.state)"
                        )
                    }
                    runtime.needsTunnelCleanup = false
                } catch {
                    failures.append("tunnel=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
                }
            }
            if runtime.needsBrowserCleanup {
                do {
                    try RemoteChromiumRuntime.cleanup(
                        metadata: PartialLaunchMetadata(
                            processID: runtime.session.remoteProcessID,
                            temporaryDirectory: runtime.session.remoteTemporaryDirectory
                        ),
                        context: runtime.context,
                        commandExecutor: commandExecutor,
                        timeout: commandTimeout,
                        removeTemporaryDirectory: runtime.retainedDownloadPaths.isEmpty
                    )
                    runtime.needsBrowserCleanup = false
                } catch {
                    failures.append("browser=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
                }
            }
            if runtime.needsTunnelCleanup == false,
               runtime.needsBrowserCleanup == false,
               pendingAcknowledgedPaths.isEmpty == false
            {
                do {
                    try cleanupAcknowledgedDownloads()
                } catch {
                    failures.append("download=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
                }
            }
            guard failures.isEmpty == false else { return }
            diagnosticLog?.append(
                level: .warning,
                category: "Browser",
                message: "remote.chromium.cleanup.failed stage=deinit-retry lease=\(runtime.session.leaseID.uuidString.lowercased()) \(failures.joined(separator: "; "))"
            )
            scheduleNextAttempt()
        }

        private func cleanupAcknowledgedDownloads() throws {
            if pendingAcknowledgedPaths == runtime.retainedDownloadPaths {
                let directory = runtime.session.remoteTemporaryDirectory
                guard RemoteChromiumRuntime.isOwnedTemporaryDirectory(directory) else {
                    throw RemoteChromiumRuntimeError.invalidLaunchMetadata
                }
                _ = try commandExecutor.execute(
                    command: "rm -rf -- \(RemoteChromiumRuntime.shellSingleQuoted(directory))",
                    context: runtime.context,
                    timeout: min(commandTimeout, 5)
                )
                runtime.retainedDownloadPaths.removeAll()
                pendingAcknowledgedPaths.removeAll()
                return
            }

            for path in Array(pendingAcknowledgedPaths) {
                guard RemoteChromiumDownload.isCanonicalRemotePath(path, for: runtime.session) else {
                    throw RemoteChromiumRuntimeError.invalidLaunchMetadata
                }
                _ = try commandExecutor.execute(
                    command: "rm -f -- \(RemoteChromiumRuntime.shellSingleQuoted(path))",
                    context: runtime.context,
                    timeout: min(commandTimeout, 5)
                )
                runtime.retainedDownloadPaths.remove(path)
                pendingAcknowledgedPaths.remove(path)
            }
        }
    }

    private let commandExecutor: RemoteChromiumCommandExecuting
    private let tunnelBridge: TunnelRuntimeBridging
    private let pageEndpointResolver: (UInt16) throws -> URL
    private let commandTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let performsCleanupAsynchronously: Bool
    private let cleanupRetryDelays: [TimeInterval]
    private let diagnosticLog: StacioLogWriting?
    private let lifecycleQueue = DispatchQueue(label: "com.stacio.remote-chromium.lifecycle")
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private let retainedDownloadLock = NSLock()
    private var activeRuntimes: [UUID: ActiveRuntime] = [:]
    private var pendingLaunchCleanups: [UUID: PendingLaunchCleanup] = [:]
    private var runtimeCleanupRetryAttempts: [UUID: Int] = [:]
    private var launchCleanupRetryAttempts: [UUID: Int] = [:]
    private var retainedDownloads: Set<RetainedDownloadIdentity> = []
    private var acknowledgementsInFlight: Set<RetainedDownloadIdentity> = []
    private var pendingAcknowledgedDownloads: [RetainedDownloadIdentity: RemoteChromiumDownload] = [:]
    private var downloadableSessions: [UUID: RemoteChromiumRuntimeSession] = [:]
    private var stoppedDownloadSessionLeases: Set<UUID> = []
    private var pendingRetainedDownloads: [RetainedDownloadIdentity: RemoteChromiumDownload] = [:]

    public init(
        commandExecutor: RemoteChromiumCommandExecuting = CoreRemoteChromiumCommandExecutor(),
        tunnelBridge: TunnelRuntimeBridging = CoreBridgeTunnelRuntimeBridge(),
        pageEndpointResolver: @escaping (UInt16) throws -> URL = RemoteChromiumRuntime.resolvePageWebSocketURL,
        commandTimeout: TimeInterval = 12,
        performsCleanupAsynchronously: Bool = true,
        cleanupRetryDelays: [TimeInterval] = [0.25, 1, 3],
        pollInterval: TimeInterval = 0.05,
        diagnosticLog: StacioLogWriting? = StacioLogStore.shared
    ) {
        self.commandExecutor = commandExecutor
        self.tunnelBridge = tunnelBridge
        self.pageEndpointResolver = pageEndpointResolver
        self.commandTimeout = max(1, commandTimeout)
        self.performsCleanupAsynchronously = performsCleanupAsynchronously
        self.cleanupRetryDelays = cleanupRetryDelays.map { max(0, $0) }
        self.pollInterval = max(0, pollInterval)
        self.diagnosticLog = diagnosticLog
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            stopAllSerialized()
        } else {
            lifecycleQueue.sync { stopAllSerialized() }
        }
    }

    public func start(
        context: TunnelLiveSessionContext,
        localPort: UInt16
    ) throws -> RemoteChromiumRuntimeSession {
        try lifecycleQueue.sync {
            try startSerialized(context: context, localPort: localPort)
        }
    }

    public func stop(session: RemoteChromiumRuntimeSession) {
        retainedDownloadLock.withLock {
            if downloadableSessions[session.leaseID] == session {
                stoppedDownloadSessionLeases.insert(session.leaseID)
            }
        }
        let work = { [self] in
            stopSerialized(session: session)
        }
        if performsCleanupAsynchronously {
            lifecycleQueue.async(execute: work)
        } else if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            work()
        } else {
            lifecycleQueue.sync(execute: work)
        }
    }

    @discardableResult
    public func retainDownload(_ download: RemoteChromiumDownload) -> Bool {
        let identity = RetainedDownloadIdentity(download)
        let accepted = retainedDownloadLock.withLock {
            guard let session = downloadableSessions[download.sessionLeaseID],
                  stoppedDownloadSessionLeases.contains(download.sessionLeaseID) == false,
                  download.isCanonical(for: session)
            else {
                return false
            }
            retainedDownloads.insert(identity)
            pendingRetainedDownloads[identity] = download
            return true
        }
        guard accepted else { return false }

        lifecycleQueue.async { [weak self] in
            self?.materializeRetainedDownload(download, identity: identity)
        }
        return true
    }

    private func materializeRetainedDownload(
        _ download: RemoteChromiumDownload,
        identity: RetainedDownloadIdentity
    ) {
        guard var runtime = activeRuntimes[download.sessionLeaseID],
              download.isCanonical(for: runtime.session)
        else {
            retainedDownloadLock.withLock {
                retainedDownloads.remove(identity)
                pendingRetainedDownloads.removeValue(forKey: identity)
            }
            diagnosticLog?.append(
                level: .warning,
                category: "Browser",
                message: "remote.chromium.download.retain.discarded lease=\(download.sessionLeaseID.uuidString.lowercased()) path=\(download.remotePath)"
            )
            return
        }
        runtime.retainedDownloadPaths.insert(download.remotePath)
        activeRuntimes[download.sessionLeaseID] = runtime
        _ = retainedDownloadLock.withLock {
            pendingRetainedDownloads.removeValue(forKey: identity)
        }
    }

    private func materializePendingRetainedDownloads(runtime: inout ActiveRuntime) {
        let pending = retainedDownloadLock.withLock { () -> [RetainedDownloadIdentity: RemoteChromiumDownload] in
            let pending = pendingRetainedDownloads.filter {
                $0.key.sessionLeaseID == runtime.session.leaseID
            }
            pending.keys.forEach {
                pendingRetainedDownloads.removeValue(forKey: $0)
            }
            return pending
        }
        for (identity, download) in pending {
            guard download.isCanonical(for: runtime.session) else {
                _ = retainedDownloadLock.withLock {
                    retainedDownloads.remove(identity)
                }
                continue
            }
            runtime.retainedDownloadPaths.insert(download.remotePath)
        }
    }

    @discardableResult
    public func acknowledgeDownload(
        _ download: RemoteChromiumDownload,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool {
        let identity = RetainedDownloadIdentity(download)
        let accepted = retainedDownloadLock.withLock {
            guard retainedDownloads.contains(identity),
                  acknowledgementsInFlight.contains(identity) == false
            else {
                return false
            }
            acknowledgementsInFlight.insert(identity)
            pendingAcknowledgedDownloads[identity] = download
            return true
        }
        guard accepted else { return false }

        lifecycleQueue.async { [self] in
            acknowledgeDownloadSerialized(
                download,
                identity: identity,
                completion: completion
            )
        }
        return true
    }

    private func acknowledgeDownloadSerialized(
        _ download: RemoteChromiumDownload,
        identity: RetainedDownloadIdentity,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let runtime = activeRuntimes[download.sessionLeaseID],
              download.isCanonical(for: runtime.session),
              runtime.retainedDownloadPaths.contains(download.remotePath)
        else {
            retainedDownloadLock.withLock {
                _ = acknowledgementsInFlight.remove(identity)
                _ = pendingAcknowledgedDownloads.removeValue(forKey: identity)
            }
            deliverAcknowledgement(
                .failure(RemoteChromiumRuntimeError.commandFailed("download acknowledgement state changed")),
                completion: completion
            )
            return
        }

        let action: DownloadCleanupAction = runtime.isStopped
            && runtime.needsTunnelCleanup == false
            && runtime.needsBrowserCleanup == false
            && runtime.retainedDownloadPaths.count == 1
            ? .directory
            : .file
        attemptDownloadAcknowledgement(
            download,
            identity: identity,
            runtime: runtime,
            action: action,
            retryAttempt: 0,
            completion: completion
        )
    }

    private func attemptDownloadAcknowledgement(
        _ download: RemoteChromiumDownload,
        identity: RetainedDownloadIdentity,
        runtime: ActiveRuntime,
        action: DownloadCleanupAction,
        retryAttempt: Int,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        let result: Result<Void, Error> = Result {
            switch action {
            case .file:
                try removeRemoteDownload(download.remotePath, from: runtime)
            case .directory:
                try removeStoppedRuntimeDirectory(runtime)
            }
        }
        switch result {
        case let .failure(error):
            if performsCleanupAsynchronously, retryAttempt < cleanupRetryDelays.count {
                let delay = cleanupRetryDelays[retryAttempt]
                lifecycleQueue.asyncAfter(deadline: .now() + delay) { [self] in
                    guard let currentRuntime = activeRuntimes[download.sessionLeaseID],
                          download.isCanonical(for: currentRuntime.session),
                          currentRuntime.retainedDownloadPaths.contains(download.remotePath)
                    else {
                        retainedDownloadLock.withLock {
                            _ = acknowledgementsInFlight.remove(identity)
                        }
                        deliverAcknowledgement(
                            .failure(RemoteChromiumRuntimeError.commandFailed("download acknowledgement state changed")),
                            completion: completion
                        )
                        return
                    }
                    attemptDownloadAcknowledgement(
                        download,
                        identity: identity,
                        runtime: currentRuntime,
                        action: action,
                        retryAttempt: retryAttempt + 1,
                        completion: completion
                    )
                }
                return
            }
            retainedDownloadLock.withLock {
                _ = acknowledgementsInFlight.remove(identity)
            }
            diagnosticLog?.append(
                level: .warning,
                category: "Browser",
                message: "remote.chromium.download.cleanup.exhausted lease=\(download.sessionLeaseID.uuidString.lowercased()) path=\(download.remotePath) error=\(RuntimeDiagnosticFormatter.userMessage(for: error))"
            )
            deliverAcknowledgement(.failure(error), completion: completion)
        case .success:
            var runtime = runtime
            runtime.retainedDownloadPaths.remove(download.remotePath)
            let removedRuntime: Bool
            if runtime.isStopped,
               runtime.retainedDownloadPaths.isEmpty,
               runtime.needsTunnelCleanup == false,
               runtime.needsBrowserCleanup == false
            {
                activeRuntimes.removeValue(forKey: download.sessionLeaseID)
                removedRuntime = true
            } else {
                activeRuntimes[download.sessionLeaseID] = runtime
                removedRuntime = false
            }
            retainedDownloadLock.withLock {
                retainedDownloads.remove(identity)
                acknowledgementsInFlight.remove(identity)
                pendingAcknowledgedDownloads.removeValue(forKey: identity)
            }
            if removedRuntime {
                forgetDownloadSessionIfUnretained(leaseID: download.sessionLeaseID)
            }
            deliverAcknowledgement(.success(()), completion: completion)
        }
    }

    private func deliverAcknowledgement(
        _ result: Result<Void, Error>,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func startSerialized(
        context: TunnelLiveSessionContext,
        localPort: UInt16
    ) throws -> RemoteChromiumRuntimeSession {
        retryStoppedRuntimesSerialized()
        retryPendingLaunchCleanupsSerialized()
        let leaseID = UUID()
        let downloadCapability = RemoteChromiumDownloadCapability(
            sourceLiveSessionContext: context
        )
        let output: String
        do {
            output = try commandExecutor.execute(
                command: Self.launchCommand,
                context: context,
                timeout: commandTimeout
            )
        } catch let failure as RemoteChromiumCommandExecutionFailure {
            let launchFailure = Self.launchError(in: failure.partialOutput) ?? failure.error
            cleanupPartialLaunchIfNeeded(
                output: failure.partialOutput,
                context: context,
                originalError: launchFailure
            )
            throw launchFailure
        }

        let metadata: LaunchMetadata
        do {
            metadata = try Self.parseLaunchMetadata(output)
        } catch {
            cleanupPartialLaunchIfNeeded(
                output: output,
                context: context,
                originalError: error
            )
            throw error
        }
        let profile = TunnelProfile(
            id: "remote_chromium_cdp_\(localPort)_\(leaseID.uuidString.lowercased())",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: localPort,
            remoteHost: "127.0.0.1",
            remotePort: metadata.remoteDebugPort
        )
        var startedState: TunnelState? = .starting
        do {
            var status = try tunnelBridge.start(profile: profile, liveSessionContext: context)
            startedState = status.state
            if status.state == .starting {
                for _ in 0..<40 where status.state == .starting {
                    if pollInterval > 0 { Thread.sleep(forTimeInterval: pollInterval) }
                    status = try tunnelBridge.poll(profileID: profile.id)
                    startedState = status.state
                }
            }
            guard status.profileId == profile.id, status.state == .running else {
                throw RemoteChromiumRuntimeError.tunnelFailed(status.message)
            }
            let webSocketURL = try pageEndpointResolver(localPort)
            let session = RemoteChromiumRuntimeSession(
                leaseID: leaseID,
                remoteProcessID: metadata.processID,
                remoteTemporaryDirectory: metadata.temporaryDirectory,
                remoteDownloadsDirectory: metadata.temporaryDirectory + "/downloads",
                localDebugPort: localPort,
                pageWebSocketURL: webSocketURL,
                downloadCapability: downloadCapability
            )
            activeRuntimes[leaseID] = ActiveRuntime(
                context: context,
                session: session,
                tunnelProfile: profile,
                tunnelState: status.state
            )
            retainedDownloadLock.withLock {
                downloadableSessions[leaseID] = session
                stoppedDownloadSessionLeases.remove(leaseID)
            }
            return session
        } catch {
            retainFailedStartCleanup(
                metadata: PartialLaunchMetadata(
                    processID: metadata.processID,
                    temporaryDirectory: metadata.temporaryDirectory
                ),
                context: context,
                tunnelProfile: profile,
                tunnelState: startedState,
                originalError: error
            )
            throw error
        }
    }

    private func stopSerialized(session: RemoteChromiumRuntimeSession) {
        let pendingState = retainedDownloadLock.withLock {
            (
                acknowledgement: pendingAcknowledgedDownloads.keys.contains {
                    $0.sessionLeaseID == session.leaseID
                },
                retention: pendingRetainedDownloads.keys.contains {
                    $0.sessionLeaseID == session.leaseID
                }
            )
        }
        guard var runtime = activeRuntimes[session.leaseID],
              runtime.session == session,
              runtime.isStopped == false || runtime.needsTunnelCleanup || runtime.needsBrowserCleanup
                || pendingState.acknowledgement || pendingState.retention
        else {
            return
        }
        materializePendingRetainedDownloads(runtime: &runtime)
        _ = retainedDownloadLock.withLock {
            stoppedDownloadSessionLeases.insert(session.leaseID)
        }
        runtime.isStopped = true
        var failures = attemptRuntimeCleanup(
            &runtime,
            removeTemporaryDirectory: runtime.retainedDownloadPaths.isEmpty
        )
        failures.append(contentsOf: retryPendingAcknowledgedDownloads(runtime: &runtime))
        recordCleanupFailures(failures, stage: "stop", leaseID: session.leaseID)
        if runtime.retainedDownloadPaths.isEmpty,
           runtime.needsTunnelCleanup == false,
           runtime.needsBrowserCleanup == false
        {
            activeRuntimes.removeValue(forKey: session.leaseID)
            forgetDownloadSessionIfUnretained(leaseID: session.leaseID)
        } else {
            activeRuntimes[session.leaseID] = runtime
            if failures.isEmpty == false {
                scheduleRuntimeCleanupRetry(leaseID: session.leaseID)
            }
        }
    }

    private func forgetDownloadSessionIfUnretained(leaseID: UUID) {
        retainedDownloadLock.withLock {
            let hasRetainedDownload = retainedDownloads.contains {
                $0.sessionLeaseID == leaseID
            }
            let hasPendingRetention = pendingRetainedDownloads.keys.contains {
                $0.sessionLeaseID == leaseID
            }
            guard hasRetainedDownload == false, hasPendingRetention == false else { return }
            downloadableSessions.removeValue(forKey: leaseID)
            stoppedDownloadSessionLeases.remove(leaseID)
        }
    }

    private func scheduleRuntimeCleanupRetry(leaseID: UUID) {
        guard performsCleanupAsynchronously else { return }
        let attempt = runtimeCleanupRetryAttempts[leaseID, default: 0]
        guard attempt < cleanupRetryDelays.count else {
            diagnosticLog?.append(
                level: .warning,
                category: "Browser",
                message: "remote.chromium.cleanup.exhausted stage=stop lease=\(leaseID.uuidString.lowercased()) attempts=\(attempt + 1)"
            )
            runtimeCleanupRetryAttempts.removeValue(forKey: leaseID)
            return
        }
        runtimeCleanupRetryAttempts[leaseID] = attempt + 1
        lifecycleQueue.asyncAfter(deadline: .now() + cleanupRetryDelays[attempt]) { [self] in
            guard var runtime = activeRuntimes[leaseID], runtime.isStopped else {
                runtimeCleanupRetryAttempts.removeValue(forKey: leaseID)
                return
            }
            var failures = attemptRuntimeCleanup(
                &runtime,
                removeTemporaryDirectory: runtime.retainedDownloadPaths.isEmpty
            )
            failures.append(contentsOf: retryPendingAcknowledgedDownloads(runtime: &runtime))
            recordCleanupFailures(failures, stage: "stop-retry", leaseID: leaseID)
            if runtime.retainedDownloadPaths.isEmpty,
               runtime.needsTunnelCleanup == false,
               runtime.needsBrowserCleanup == false
            {
                activeRuntimes.removeValue(forKey: leaseID)
                runtimeCleanupRetryAttempts.removeValue(forKey: leaseID)
                forgetDownloadSessionIfUnretained(leaseID: leaseID)
            } else {
                activeRuntimes[leaseID] = runtime
                if failures.isEmpty == false {
                    scheduleRuntimeCleanupRetry(leaseID: leaseID)
                }
            }
        }
    }

    private func stopAllSerialized() {
        retryPendingLaunchCleanupsSerialized()
        retryPendingLaunchCleanupsSerialized()
        for leaseID in Array(activeRuntimes.keys) {
            guard var runtime = activeRuntimes[leaseID] else { continue }
            materializePendingRetainedDownloads(runtime: &runtime)
            runtime.isStopped = true
            var failures: [String] = []
            for _ in 0..<2 {
                failures = attemptRuntimeCleanup(
                    &runtime,
                    removeTemporaryDirectory: runtime.retainedDownloadPaths.isEmpty
                )
                failures.append(contentsOf: retryPendingAcknowledgedDownloads(runtime: &runtime))
                if failures.isEmpty { break }
            }
            recordCleanupFailures(failures, stage: "deinit", leaseID: leaseID)
            if failures.isEmpty == false {
                let pendingPaths = retainedDownloadLock.withLock {
                    Set(
                        pendingAcknowledgedDownloads
                            .filter { $0.key.sessionLeaseID == leaseID }
                            .map { $0.value.remotePath }
                    )
                }
                DetachedCleanupWorker(
                    runtime: runtime,
                    pendingAcknowledgedPaths: pendingPaths,
                    commandExecutor: commandExecutor,
                    tunnelBridge: tunnelBridge,
                    commandTimeout: commandTimeout,
                    retryDelays: cleanupRetryDelays,
                    diagnosticLog: diagnosticLog,
                    queue: lifecycleQueue
                ).start()
            }
        }
        activeRuntimes.removeAll()
    }

    private func retryStoppedRuntimesSerialized() {
        let stoppedSessions = activeRuntimes.values
            .filter { runtime in
                guard runtime.isStopped else { return false }
                if runtime.needsTunnelCleanup || runtime.needsBrowserCleanup { return true }
                return retainedDownloadLock.withLock {
                    pendingAcknowledgedDownloads.keys.contains {
                        $0.sessionLeaseID == runtime.session.leaseID
                    }
                }
            }
            .map(\.session)
        for session in stoppedSessions {
            stopSerialized(session: session)
        }
    }

    private func attemptRuntimeCleanup(
        _ runtime: inout ActiveRuntime,
        removeTemporaryDirectory: Bool
    ) -> [String] {
        var failures: [String] = []
        if runtime.needsTunnelCleanup {
            do {
                let status = try tunnelBridge.stop(
                    profile: runtime.tunnelProfile,
                    state: runtime.tunnelState
                )
                guard status.profileId == runtime.tunnelProfile.id,
                      status.state == .stopped
                else {
                    throw RemoteChromiumRuntimeError.tunnelFailed(
                        "cleanup status mismatch: \(status.profileId) \(status.state)"
                    )
                }
                runtime.needsTunnelCleanup = false
            } catch {
                failures.append("tunnel=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
            }
        }
        if runtime.needsBrowserCleanup {
            do {
                try Self.cleanup(
                    metadata: PartialLaunchMetadata(
                        processID: runtime.session.remoteProcessID,
                        temporaryDirectory: runtime.session.remoteTemporaryDirectory
                    ),
                    context: runtime.context,
                    commandExecutor: commandExecutor,
                    timeout: commandTimeout,
                    removeTemporaryDirectory: removeTemporaryDirectory
                )
                runtime.needsBrowserCleanup = false
            } catch {
                failures.append("browser=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
            }
        }
        return failures
    }

    private func retryPendingAcknowledgedDownloads(runtime: inout ActiveRuntime) -> [String] {
        let pending = retainedDownloadLock.withLock {
            pendingAcknowledgedDownloads.filter { identity, _ in
                identity.sessionLeaseID == runtime.session.leaseID
                    && acknowledgementsInFlight.contains(identity) == false
            }
        }
        guard pending.isEmpty == false else { return [] }

        let canRemoveDirectory = runtime.isStopped
            && runtime.needsTunnelCleanup == false
            && runtime.needsBrowserCleanup == false
            && Set(pending.values.map(\.remotePath)) == runtime.retainedDownloadPaths
        do {
            if canRemoveDirectory {
                try removeStoppedRuntimeDirectory(runtime)
                let identities = Array(pending.keys)
                runtime.retainedDownloadPaths.removeAll()
                retainedDownloadLock.withLock {
                    identities.forEach {
                        retainedDownloads.remove($0)
                        pendingAcknowledgedDownloads.removeValue(forKey: $0)
                    }
                }
                return []
            }

            for (identity, download) in pending {
                try removeRemoteDownload(download.remotePath, from: runtime)
                runtime.retainedDownloadPaths.remove(download.remotePath)
                retainedDownloadLock.withLock {
                    retainedDownloads.remove(identity)
                    pendingAcknowledgedDownloads.removeValue(forKey: identity)
                }
            }
            return []
        } catch {
            return ["download=\(RuntimeDiagnosticFormatter.userMessage(for: error))"]
        }
    }

    private func removeRemoteDownload(_ path: String, from runtime: ActiveRuntime) throws {
        guard RemoteChromiumDownload.isCanonicalRemotePath(path, for: runtime.session) else {
            throw RemoteChromiumRuntimeError.invalidLaunchMetadata
        }
        let command = "rm -f -- \(Self.shellSingleQuoted(path))"
        _ = try commandExecutor.execute(
            command: command,
            context: runtime.context,
            timeout: min(commandTimeout, 5)
        )
    }

    private func removeStoppedRuntimeDirectory(_ runtime: ActiveRuntime) throws {
        let directory = runtime.session.remoteTemporaryDirectory
        guard Self.isOwnedTemporaryDirectory(directory) else {
            throw RemoteChromiumRuntimeError.invalidLaunchMetadata
        }
        _ = try commandExecutor.execute(
            command: "rm -rf -- \(Self.shellSingleQuoted(directory))",
            context: runtime.context,
            timeout: min(commandTimeout, 5)
        )
    }

    private func cleanupPartialLaunchIfNeeded(
        output: String,
        context: TunnelLiveSessionContext,
        originalError: Error
    ) {
        guard let partial = Self.parsePartialLaunchMetadata(output) else { return }
        retainFailedStartCleanup(
            metadata: partial,
            context: context,
            tunnelProfile: nil,
            tunnelState: nil,
            originalError: originalError
        )
    }

    private func retainFailedStartCleanup(
        metadata: PartialLaunchMetadata,
        context: TunnelLiveSessionContext,
        tunnelProfile: TunnelProfile?,
        tunnelState: TunnelState?,
        originalError: Error
    ) {
        var cleanup = PendingLaunchCleanup(
            id: UUID(),
            context: context,
            metadata: metadata,
            tunnelProfile: tunnelProfile,
            tunnelState: tunnelState,
            needsTunnelCleanup: tunnelProfile != nil && tunnelState != nil,
            needsBrowserCleanup: true
        )
        let failures = attemptPendingLaunchCleanup(&cleanup)
        guard cleanup.needsTunnelCleanup || cleanup.needsBrowserCleanup else { return }
        pendingLaunchCleanups[cleanup.id] = cleanup
        diagnosticLog?.append(
            level: .warning,
            category: "Browser",
            message: "remote.chromium.start.cleanup.pending original=\(RuntimeDiagnosticFormatter.userMessage(for: originalError)) cleanup=\(failures.joined(separator: "; "))"
        )
        schedulePendingLaunchCleanupRetry(id: cleanup.id)
    }

    private func schedulePendingLaunchCleanupRetry(id: UUID) {
        guard performsCleanupAsynchronously else { return }
        let attempt = launchCleanupRetryAttempts[id, default: 0]
        guard attempt < cleanupRetryDelays.count else {
            diagnosticLog?.append(
                level: .warning,
                category: "Browser",
                message: "remote.chromium.cleanup.exhausted stage=start lease=\(id.uuidString.lowercased()) attempts=\(attempt + 1)"
            )
            launchCleanupRetryAttempts.removeValue(forKey: id)
            return
        }
        launchCleanupRetryAttempts[id] = attempt + 1
        lifecycleQueue.asyncAfter(deadline: .now() + cleanupRetryDelays[attempt]) { [self] in
            guard var cleanup = pendingLaunchCleanups[id] else {
                launchCleanupRetryAttempts.removeValue(forKey: id)
                return
            }
            let failures = attemptPendingLaunchCleanup(&cleanup)
            if cleanup.needsTunnelCleanup || cleanup.needsBrowserCleanup {
                pendingLaunchCleanups[id] = cleanup
                recordCleanupFailures(failures, stage: "start-retry", leaseID: id)
                schedulePendingLaunchCleanupRetry(id: id)
            } else {
                pendingLaunchCleanups.removeValue(forKey: id)
                launchCleanupRetryAttempts.removeValue(forKey: id)
            }
        }
    }

    private func retryPendingLaunchCleanupsSerialized() {
        for id in Array(pendingLaunchCleanups.keys) {
            guard var cleanup = pendingLaunchCleanups[id] else { continue }
            let failures = attemptPendingLaunchCleanup(&cleanup)
            if cleanup.needsTunnelCleanup || cleanup.needsBrowserCleanup {
                pendingLaunchCleanups[id] = cleanup
                recordCleanupFailures(failures, stage: "start-retry", leaseID: id)
            } else {
                pendingLaunchCleanups.removeValue(forKey: id)
                launchCleanupRetryAttempts.removeValue(forKey: id)
            }
        }
    }

    private func attemptPendingLaunchCleanup(
        _ cleanup: inout PendingLaunchCleanup
    ) -> [String] {
        var failures: [String] = []
        if cleanup.needsTunnelCleanup,
           let profile = cleanup.tunnelProfile,
           let state = cleanup.tunnelState
        {
            do {
                let status = try tunnelBridge.stop(profile: profile, state: state)
                guard status.profileId == profile.id, status.state == .stopped else {
                    throw RemoteChromiumRuntimeError.tunnelFailed(
                        "cleanup status mismatch: \(status.profileId) \(status.state)"
                    )
                }
                cleanup.needsTunnelCleanup = false
            } catch {
                failures.append("tunnel=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
            }
        }
        if cleanup.needsBrowserCleanup {
            do {
                try Self.cleanup(
                    metadata: cleanup.metadata,
                    context: cleanup.context,
                    commandExecutor: commandExecutor,
                    timeout: commandTimeout,
                    removeTemporaryDirectory: true
                )
                cleanup.needsBrowserCleanup = false
            } catch {
                failures.append("browser=\(RuntimeDiagnosticFormatter.userMessage(for: error))")
            }
        }
        return failures
    }

    private func recordCleanupFailures(
        _ failures: [String],
        stage: String,
        leaseID: UUID
    ) {
        guard failures.isEmpty == false else { return }
        diagnosticLog?.append(
            level: .warning,
            category: "Browser",
            message: "remote.chromium.cleanup.failed stage=\(stage) lease=\(leaseID.uuidString.lowercased()) \(failures.joined(separator: "; "))"
        )
    }

    private static func parseLaunchMetadata(_ output: String) throws -> LaunchMetadata {
        if let error = launchError(in: output) { throw error }
        guard
            let pidValue = CoreRemoteChromiumCommandExecutor.markerValue("__STACIO_CHROMIUM_PID__", in: output),
            let processID = Int(pidValue),
            processID > 1,
            let directory = CoreRemoteChromiumCommandExecutor.markerValue("__STACIO_CHROMIUM_DIR__", in: output),
            isOwnedTemporaryDirectory(directory),
            let portValue = CoreRemoteChromiumCommandExecutor.markerValue("__STACIO_CHROMIUM_PORT__", in: output),
            let remoteDebugPort = UInt16(portValue),
            remoteDebugPort > 0
        else {
            throw RemoteChromiumRuntimeError.invalidLaunchMetadata
        }
        return LaunchMetadata(
            processID: processID,
            temporaryDirectory: directory,
            remoteDebugPort: remoteDebugPort
        )
    }

    private static func parsePartialLaunchMetadata(_ output: String) -> PartialLaunchMetadata? {
        guard
            let directory = CoreRemoteChromiumCommandExecutor.markerValue("__STACIO_CHROMIUM_DIR__", in: output),
            isOwnedTemporaryDirectory(directory)
        else {
            return nil
        }
        let processID = CoreRemoteChromiumCommandExecutor
            .markerValue("__STACIO_CHROMIUM_PID__", in: output)
            .flatMap(Int.init)
            .flatMap { $0 > 1 ? $0 : nil }
        return PartialLaunchMetadata(processID: processID, temporaryDirectory: directory)
    }

    private static func launchError(in output: String) -> RemoteChromiumRuntimeError? {
        switch CoreRemoteChromiumCommandExecutor.markerValue("__STACIO_CHROMIUM_ERROR__", in: output) {
        case "browser_not_found", "root_not_supported":
            return .browserUnavailable
        default:
            return nil
        }
    }

    private static func isOwnedTemporaryDirectory(_ path: String) -> Bool {
        path.range(
            of: #"^/tmp/stacio-chromium\.[A-Za-z0-9]{6,64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func cleanup(
        metadata: PartialLaunchMetadata,
        context: TunnelLiveSessionContext,
        commandExecutor: RemoteChromiumCommandExecuting,
        timeout: TimeInterval,
        removeTemporaryDirectory: Bool = true
    ) throws {
        guard isOwnedTemporaryDirectory(metadata.temporaryDirectory) else {
            throw RemoteChromiumRuntimeError.invalidLaunchMetadata
        }
        let directory = shellSingleQuoted(metadata.temporaryDirectory)
        let removeDirectoryCommand = removeTemporaryDirectory ? "rm -rf -- \(directory)" : ":"
        let processCleanupCommand: String
        if let processID = metadata.processID, processID > 1 {
            let pid = shellSingleQuoted(String(processID))
            let expectedProfileArgument = shellSingleQuoted(
                "--user-data-dir=\(metadata.temporaryDirectory)/profile"
            )
            processCleanupCommand = """
            STACIO_CHROMIUM_EXPECTED_ARG=\(expectedProfileArgument)
            STACIO_CHROMIUM_PID_UID=$(ps -o uid= -p \(pid) 2>/dev/null | tr -d '[:space:]' || true)
            STACIO_CHROMIUM_PID_MATCH=0
            if [ "$STACIO_CHROMIUM_PID_UID" = "$(id -u)" ]; then
                if [ -r /proc/\(processID)/cmdline ]; then
                    if tr '\\000' '\\n' </proc/\(processID)/cmdline | grep -Fqx -- "$STACIO_CHROMIUM_EXPECTED_ARG"; then
                        STACIO_CHROMIUM_PID_MATCH=1
                    fi
                else
                    STACIO_CHROMIUM_COMMAND=$(ps -ww -o command= -p \(pid) 2>/dev/null || true)
                    for STACIO_CHROMIUM_ARGUMENT in $STACIO_CHROMIUM_COMMAND; do
                        if [ "$STACIO_CHROMIUM_ARGUMENT" = "$STACIO_CHROMIUM_EXPECTED_ARG" ]; then
                            STACIO_CHROMIUM_PID_MATCH=1
                            break
                        fi
                    done
                fi
            fi
            if [ "$STACIO_CHROMIUM_PID_MATCH" = 1 ] && kill -0 \(pid) 2>/dev/null; then
                kill \(pid) 2>/dev/null || true
                STACIO_CHROMIUM_STOP_ATTEMPT=0
                while kill -0 \(pid) 2>/dev/null && [ "$STACIO_CHROMIUM_STOP_ATTEMPT" -lt 20 ]; do
                    STACIO_CHROMIUM_STOP_ATTEMPT=$((STACIO_CHROMIUM_STOP_ATTEMPT + 1))
                    sleep 0.1
                done
                if kill -0 \(pid) 2>/dev/null; then kill -9 \(pid) 2>/dev/null || true; fi
            fi
            """
        } else {
            processCleanupCommand = ":"
        }
        let command = """
        \(processCleanupCommand)
        \(removeDirectoryCommand)
        """
        _ = try commandExecutor.execute(command: command, context: context, timeout: min(timeout, 5))
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func resolvePageWebSocketURL(localPort: UInt16) throws -> URL {
        guard let discoveryURL = URL(string: "http://127.0.0.1:\(localPort)/json/list") else {
            throw RemoteChromiumRuntimeError.pageEndpointUnavailable("invalid loopback URL")
        }
        var lastMessage = "no page target"
        for _ in 0..<30 {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, Error>?
            let task = URLSession.shared.dataTask(with: discoveryURL) { data, response, error in
                if let error {
                    result = .failure(error)
                } else if let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let data
                {
                    result = .success(data)
                } else {
                    result = .failure(RemoteChromiumRuntimeError.pageEndpointUnavailable("HTTP discovery failed"))
                }
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 1)
            task.cancel()
            if case let .success(data) = result,
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let rawURL = targets.first(where: { ($0["type"] as? String) == "page" })?["webSocketDebuggerUrl"] as? String,
               var components = URLComponents(string: rawURL)
            {
                components.scheme = "ws"
                components.host = "127.0.0.1"
                components.port = Int(localPort)
                if let localURL = components.url {
                    return localURL
                }
            }
            if case let .failure(error) = result {
                lastMessage = RuntimeDiagnosticFormatter.userMessage(for: error)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw RemoteChromiumRuntimeError.pageEndpointUnavailable(lastMessage)
    }
}
