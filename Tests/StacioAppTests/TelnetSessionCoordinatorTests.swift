import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class TelnetSessionCoordinatorTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testStartFailureThrowsChineseDiagnosticWithoutOpeningWorkspace() {
        let workspace = RecordingTelnetWorkspaceOpening()
        let starter = FailingTelnetRuntimeStarter(
            error: SshRuntimeError.Transport(message: "Permission denied credential secret-ref failed at /Users/me/.ssh/id_rsa")
        )
        let coordinator = TelnetSessionCoordinator(runtimeStarter: starter, workspace: workspace)

        XCTAssertThrowsError(try coordinator.start(config: telnetConfig(), title: "Telnet 控制台")) { error in
            XCTAssertEqual(
                displayMessage(for: error),
                "Telnet 连接失败：权限被拒绝 [已隐藏凭据] 失败位置 [已隐藏路径]"
            )
        }
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testStartRejectsNonRunningTelnetStatusWithoutOpeningWorkspace() {
        let workspace = RecordingTelnetWorkspaceOpening()
        let starter = ReturningTelnetRuntimeStarter(
            status: LiveShellStatus(
                runtimeId: "term_telnet_failed",
                status: "failed",
                diagnostic: "connection refused"
            )
        )
        let coordinator = TelnetSessionCoordinator(runtimeStarter: starter, workspace: workspace)

        XCTAssertThrowsError(try coordinator.start(config: telnetConfig(), title: "Telnet 控制台")) { error in
            XCTAssertEqual(
                displayMessage(for: error),
                "Telnet 连接失败：连接被拒绝"
            )
        }
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testInvalidConfigUsesTelnetSpecificChineseDiagnostic() {
        let workspace = RecordingTelnetWorkspaceOpening()
        let starter = FailingTelnetRuntimeStarter(error: SshRuntimeError.InvalidConfig)
        let coordinator = TelnetSessionCoordinator(runtimeStarter: starter, workspace: workspace)

        XCTAssertThrowsError(try coordinator.start(config: telnetConfig(), title: "Telnet 控制台")) { error in
            XCTAssertEqual(
                displayMessage(for: error),
                "Telnet 连接失败：配置无效，请检查主机和端口。"
            )
        }
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testTimeoutUsesSharedSanitizedDiagnostic() {
        let workspace = RecordingTelnetWorkspaceOpening()
        let starter = FailingTelnetRuntimeStarter(error: SshRuntimeError.Timeout)
        let coordinator = TelnetSessionCoordinator(runtimeStarter: starter, workspace: workspace)

        XCTAssertThrowsError(try coordinator.start(config: telnetConfig(), title: "Telnet 控制台")) { error in
            XCTAssertEqual(
                displayMessage(for: error),
                "Telnet 连接失败：连接超时"
            )
        }
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testOpenSessionTabShowsPendingTelnetStateBeforeAttachingRuntime() throws {
        let workspace = RecordingTelnetWorkspaceOpening()
        let starter = BlockingTelnetRuntimeStarter(
            status: LiveShellStatus(
                runtimeId: "term_telnet_connected",
                status: "running",
                diagnostic: "connected"
            )
        )
        let coordinator = TelnetSessionCoordinator(runtimeStarter: starter, workspace: workspace)

        let status = try coordinator.openSessionTab(config: telnetConfig(), title: "Telnet 控制台")
        let pane = try XCTUnwrap(workspace.connectingPanes.first)

        XCTAssertTrue(status.runtimeId.hasPrefix("pending_"))
        XCTAssertEqual(status.status, "connecting")
        XCTAssertEqual(pane.runtimeID, status.runtimeId)
        XCTAssertTrue(pane.isConnectionStateVisibleForTesting)
        XCTAssertTrue(pane.isTerminalContentHiddenForTesting)
        XCTAssertEqual(
            pane.connectionStateVisibleTextForTesting,
            "正在连接...\nTelnet · operator@example.com:23"
        )
        XCTAssertTrue(starter.waitUntilStarted())

        starter.release()

        XCTAssertTrue(waitUntil { pane.runtimeID == "term_telnet_connected" })
        XCTAssertEqual(pane.lifecycleState, .running)
        XCTAssertFalse(pane.isConnectionStateVisibleForTesting)
        XCTAssertFalse(pane.isTerminalContentHiddenForTesting)
    }
}

private struct ReturningTelnetRuntimeStarter: TelnetRuntimeStarting {
    let status: LiveShellStatus

    func startLiveTelnetShellRuntime(
        config: TelnetConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        status
    }
}

private struct FailingTelnetRuntimeStarter: TelnetRuntimeStarting {
    let error: Error

    func startLiveTelnetShellRuntime(
        config: TelnetConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        throw error
    }
}

private final class BlockingTelnetRuntimeStarter: TelnetRuntimeStarting {
    private let status: LiveShellStatus
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)

    init(status: LiveShellStatus) {
        self.status = status
    }

    func startLiveTelnetShellRuntime(
        config: TelnetConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        started.signal()
        _ = releaseGate.wait(timeout: .now() + 2)
        return status
    }

    func waitUntilStarted(timeout: TimeInterval = 1) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        releaseGate.signal()
    }
}

private final class RecordingTelnetWorkspaceOpening: RemoteWorkspaceOpening {
    var openedStatuses: [LiveShellStatus] = []
    var connectingPanes: [RemoteTerminalPaneViewController] = []

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
            eventSink: NoOpTelnetTerminalEventSink(),
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        pane.loadView()
        pane.displayConnectionStarting()
        connectingPanes.append(pane)
        return pane
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openedStatuses.append(status)
    }
}

private final class NoOpTelnetTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

private func telnetConfig() -> TelnetConnectionConfig {
    TelnetConnectionConfig(
        host: "example.com",
        port: 23,
        username: "operator",
        connectTimeoutMs: 10_000
    )
}

private func displayMessage(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}
