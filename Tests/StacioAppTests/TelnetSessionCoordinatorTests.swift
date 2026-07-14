import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class TelnetSessionCoordinatorTests: XCTestCase {
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

private final class RecordingTelnetWorkspaceOpening: RemoteWorkspaceOpening {
    var openedStatuses: [LiveShellStatus] = []

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openedStatuses.append(status)
    }
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
