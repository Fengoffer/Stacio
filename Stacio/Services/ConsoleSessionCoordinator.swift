import Foundation
import StacioCoreBindings

protocol BLEConsoleTerminalRuntimeManaging: AnyObject {
    func openExternalTerminalRuntime(
        kind: String,
        endpoint: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> TerminalRuntime
    func recordTerminalResize(runtimeID: String, cols: UInt32, rows: UInt32) throws -> TerminalRuntime
    func recordTerminalOutput(runtimeID: String, bytes: [UInt8]) throws
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime
    func closeTerminalRuntime(runtimeID: String) throws -> TerminalRuntime
}

final class CoreBridgeBLEConsoleTerminalRuntime: BLEConsoleTerminalRuntimeManaging {
    func openExternalTerminalRuntime(
        kind: String,
        endpoint: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> TerminalRuntime {
        try CoreBridge.openExternalTerminalRuntime(
            kind: kind,
            endpoint: endpoint,
            cols: cols,
            rows: rows
        )
    }

    func recordTerminalResize(runtimeID: String, cols: UInt32, rows: UInt32) throws -> TerminalRuntime {
        try CoreBridge.recordTerminalResize(runtimeID: runtimeID, cols: cols, rows: rows)
    }

    func recordTerminalOutput(runtimeID: String, bytes: [UInt8]) throws {
        try CoreBridge.recordTerminalOutput(runtimeID: runtimeID, bytes: bytes)
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        try CoreBridge.takeTerminalOutputBatch(runtimeID: runtimeID)
    }

    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        try CoreBridge.setTerminalOutputPaused(runtimeID: runtimeID, paused: paused)
    }

    func closeTerminalRuntime(runtimeID: String) throws -> TerminalRuntime {
        try CoreBridge.closeTerminalRuntime(runtimeID: runtimeID)
    }
}

@MainActor
protocol ConsoleWorkspaceOpening: AnyObject {
    func openConnectingConsole(
        runtimeID: String,
        title: String,
        eventSink: TerminalEventSink,
        bridge: RemoteTerminalBridging
    ) -> RemoteTerminalPaneViewController
}

@MainActor
public protocol ConsoleSessionStarting: AnyObject {
    @discardableResult
    func openSessionTab(config: ConsoleSessionConfig, title: String) throws -> TerminalRuntime
}

private final class BLEConsoleSessionOwner: @unchecked Sendable {
    let runtimeID: String

    private let runtime: BLEConsoleTerminalRuntimeManaging
    private let session: BLEConsoleSession
    private let lock = NSLock()
    private var latestState: BLEConsoleSessionState = .idle
    private var didClose = false

    init(
        runtimeID: String,
        runtime: BLEConsoleTerminalRuntimeManaging,
        session: BLEConsoleSession
    ) {
        self.runtimeID = runtimeID
        self.runtime = runtime
        self.session = session
    }

    @MainActor
    func start() {
        guard isClosed == false else { return }
        session.start()
    }

    func update(state: BLEConsoleSessionState) {
        lock.lock()
        latestState = state
        lock.unlock()
    }

    func status() -> LiveShellStatus {
        lock.lock()
        let state = latestState
        lock.unlock()

        switch state {
        case .connected:
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
        case let .failed(code):
            return LiveShellStatus(runtimeId: runtimeID, status: "failed", diagnostic: code.rawValue)
        case .closed:
            return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
        case .idle, .connecting, .discovering, .subscribing, .reconnecting:
            return LiveShellStatus(runtimeId: runtimeID, status: "connecting", diagnostic: "connecting")
        }
    }

    func enqueueWrite(_ bytes: [UInt8]) throws {
        try performOnMainActor {
            try self.session.enqueueWrite(bytes)
        }
    }

    func recordOutput(_ bytes: [UInt8]) throws {
        try runtime.recordTerminalOutput(runtimeID: runtimeID, bytes: bytes)
    }

    func resize(cols: UInt32, rows: UInt32) throws -> TerminalRuntime {
        try runtime.recordTerminalResize(runtimeID: runtimeID, cols: cols, rows: rows)
    }

    func takeOutput() throws -> TerminalOutputBatch {
        try runtime.takeTerminalOutputBatch(runtimeID: runtimeID)
    }

    func setOutputPaused(_ paused: Bool) throws -> TerminalRuntime {
        try runtime.setTerminalOutputPaused(runtimeID: runtimeID, paused: paused)
    }

    func close() throws {
        lock.lock()
        guard didClose == false else {
            lock.unlock()
            return
        }
        didClose = true
        lock.unlock()

        try performOnMainActor {
            self.session.close()
        }
        _ = try runtime.closeTerminalRuntime(runtimeID: runtimeID)
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didClose
    }

    private func performOnMainActor<T>(
        _ operation: @escaping @MainActor () throws -> T
    ) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(operation)
        }

        // 使用 async + 信号量替代 DispatchQueue.main.sync，避免主线程被占用时死锁。
        // 超时后抛错而非永久阻塞，让调用方有机会降级处理。
        // 注意：必须用 box 包裹 result，避免超时后闭包写入已回收的栈变量（use-after-free）。
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = LockedResultBox<T>()
        DispatchQueue.main.async {
            resultBox.store(Result {
                try MainActor.assumeIsolated(operation)
            })
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            // 超时后闭包仍可能在稍后执行并写入 resultBox（堆内存，安全），
            // 但我们已不再读取它，直接抛错。
            throw NSError(
                domain: "Stacio.ConsoleSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "主线程在 5 秒内未响应，BLE 控制台操作已取消。"]
            )
        }
        return try resultBox.load().get()
    }

    /// 堆分配的结果容器，避免超时后闭包写入栈变量导致 use-after-free。
    private final class LockedResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var inner: Result<T, Error>?

        func store(_ result: Result<T, Error>) {
            lock.lock()
            inner = result
            lock.unlock()
        }

        func load() -> Result<T, Error> {
            lock.lock()
            defer { lock.unlock() }
            // 理论上 load 只在 signal 之后调用，inner 必非 nil；
            // 但防御性兜底以防极端时序。
            return inner ?? .failure(NSError(
                domain: "Stacio.ConsoleSession",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "主线程操作结果未就绪。"]
            ))
        }
    }
}

final class BLEConsoleTerminalEventSink: TerminalEventSink {
    private let owner: BLEConsoleSessionOwner

    fileprivate init(owner: BLEConsoleSessionOwner) {
        self.owner = owner
    }

    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {
        guard runtimeID == owner.runtimeID,
              let size = TerminalResizeValidator.sanitized(cols: cols, rows: rows)
        else {
            return
        }
        // SwiftTerm emits a 2x1 placeholder while an unattached AppKit view is
        // first laid out. Keep the runtime's 80x24 default until real geometry arrives.
        guard size.cols > 2 || size.rows > 1 else { return }
        _ = try owner.resize(cols: size.cols, rows: size.rows)
    }

    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {
        guard runtimeID == owner.runtimeID else { return }
        try owner.recordOutput(bytes)
    }

    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {
        guard runtimeID == owner.runtimeID else { return }
        try owner.enqueueWrite(bytes)
    }

    func terminalDidClose(runtimeID: String) throws {
        guard runtimeID == owner.runtimeID else { return }
        try owner.close()
    }
}

final class BLEConsoleRemoteTerminalBridge: RemoteTerminalBridging {
    private let owner: BLEConsoleSessionOwner

    fileprivate init(owner: BLEConsoleSessionOwner) {
        self.owner = owner
    }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        guard runtimeID == owner.runtimeID else {
            return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "runtime mismatch")
        }
        return owner.status()
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        guard runtimeID == owner.runtimeID else {
            return TerminalOutputBatch(
                runtimeId: runtimeID,
                bytes: Data(),
                droppedByteCount: 0,
                protectionActive: false,
                bufferedByteCount: 0
            )
        }
        return try owner.takeOutput()
    }

    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        try owner.setOutputPaused(paused)
    }

    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {
        // BLE GATT has no SSH keepalive operation.
    }

    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        guard runtimeID == owner.runtimeID else {
            return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "runtime mismatch")
        }
        try owner.close()
        return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
    }
}

@MainActor
final class ConsoleSessionCoordinator: ConsoleSessionStarting {
    typealias SessionFactory = (ConsoleSessionConfig) -> BLEConsoleSession

    private let runtime: BLEConsoleTerminalRuntimeManaging
    private let sessionFactory: SessionFactory
    private weak var workspace: ConsoleWorkspaceOpening?
    private let defaultCols: UInt32
    private let defaultRows: UInt32

    init(
        runtime: BLEConsoleTerminalRuntimeManaging = CoreBridgeBLEConsoleTerminalRuntime(),
        sessionFactory: SessionFactory? = nil,
        workspace: ConsoleWorkspaceOpening,
        defaultCols: UInt32 = 80,
        defaultRows: UInt32 = 24
    ) {
        self.runtime = runtime
        self.sessionFactory = sessionFactory ?? { config in
            BLEConsoleSession(
                config: config,
                driver: CoreBluetoothBLEConsoleCentralDriver()
            )
        }
        self.workspace = workspace
        self.defaultCols = defaultCols
        self.defaultRows = defaultRows
    }

    @discardableResult
    func openSessionTab(config: ConsoleSessionConfig, title: String) throws -> TerminalRuntime {
        guard let workspace else {
            throw RemoteTerminalLifecycleError.reconnectUnavailable
        }

        let terminalRuntime = try runtime.openExternalTerminalRuntime(
            kind: "ble_console",
            endpoint: config.ble.deviceName,
            cols: defaultCols,
            rows: defaultRows
        )
        let session = sessionFactory(config)
        let owner = BLEConsoleSessionOwner(
            runtimeID: terminalRuntime.id,
            runtime: runtime,
            session: session
        )
        let eventSink = BLEConsoleTerminalEventSink(owner: owner)
        let bridge = BLEConsoleRemoteTerminalBridge(owner: owner)
        let pane = workspace.openConnectingConsole(
            runtimeID: terminalRuntime.id,
            title: title,
            eventSink: eventSink,
            bridge: bridge
        )

        session.onStateChange = { [weak owner, weak pane] state in
            owner?.update(state: state)
            switch state {
            case .connected:
                pane?.attachConnectedRuntime(
                    status: LiveShellStatus(
                        runtimeId: terminalRuntime.id,
                        status: "running",
                        diagnostic: "running"
                    )
                )
            case let .failed(code):
                pane?.displayConnectionFailure(code.errorDescription ?? code.rawValue)
            case .connecting, .discovering, .subscribing, .reconnecting:
                pane?.displayConnectionStarting()
            case .idle, .closed:
                break
            }
        }
        session.onReceiveBytes = { [weak owner, weak pane] bytes in
            do {
                try owner?.recordOutput(bytes)
            } catch {
                pane?.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
            }
        }
        pane.onConsoleRetryRequested = { [weak owner, weak pane] in
            pane?.displayConnectionStarting()
            owner?.start()
        }
        owner.start()
        return terminalRuntime
    }
}

extension WorkspaceViewController: ConsoleWorkspaceOpening {}
