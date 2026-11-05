import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class SerialSessionCoordinatorTests: XCTestCase {
    func testStartFailureThrowsChineseDiagnosticWithoutOpeningWorkspace() {
        let workspace = RecordingSerialWorkspaceOpening()
        let starter = FailingSerialRuntimeStarter(
            error: SshRuntimeError.Transport(message: "Permission denied /dev/cu.usbserial-001")
        )
        let coordinator = SerialSessionCoordinator(runtimeStarter: starter, workspace: workspace)
        let config = SerialConnectionConfig(
            devicePath: "/dev/cu.usbserial-001",
            baudRate: 9_600,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )

        XCTAssertThrowsError(try coordinator.start(config: config, title: "串口控制台")) { error in
            XCTAssertEqual(
                SerialSessionCoordinator.diagnosticMessage(for: error),
                "串口连接失败：权限被拒绝 [已隐藏路径]"
            )
        }
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testStartDoesNotStartRuntimeWhenWorkspaceIsUnavailable() throws {
        var workspace: RecordingSerialWorkspaceOpening? = RecordingSerialWorkspaceOpening()
        let starter = RecordingSerialRuntimeStarter(
            status: LiveShellStatus(runtimeId: "term_serial_orphan", status: "running", diagnostic: "running")
        )
        let coordinator = SerialSessionCoordinator(
            runtimeStarter: starter,
            workspace: try XCTUnwrap(workspace)
        )
        let config = SerialConnectionConfig(
            devicePath: "/dev/cu.usbserial-001",
            baudRate: 9_600,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )
        workspace = nil

        XCTAssertThrowsError(try coordinator.start(config: config, title: "串口控制台")) { error in
            guard case RemoteTerminalLifecycleError.reconnectUnavailable = error else {
                return XCTFail("Expected reconnectUnavailable, got \(error)")
            }
        }

        XCTAssertEqual(starter.startCount, 0)
    }

    func testOpenSessionTabKeepsFailedSerialConnectionInsideTerminalPane() throws {
        let workspace = RecordingSerialWorkspaceOpening()
        let starter = FailingSerialRuntimeStarter(
            error: SshRuntimeError.Transport(message: "No such file or directory /dev/cu.usbserial-001")
        )
        let coordinator = SerialSessionCoordinator(runtimeStarter: starter, workspace: workspace)
        let config = SerialConnectionConfig(
            devicePath: "/dev/cu.usbserial-001",
            baudRate: 9_600,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )

        let status = try coordinator.openSessionTab(config: config, title: "串口控制台")

        XCTAssertTrue(status.runtimeId.hasPrefix("pending_"))
        XCTAssertEqual(status.status, "connecting")
        XCTAssertEqual(workspace.pendingTitles, ["串口控制台"])
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testOpenSessionTabDoesNotStartRuntimeWhenWorkspaceIsUnavailable() throws {
        var workspace: RecordingSerialWorkspaceOpening? = RecordingSerialWorkspaceOpening()
        let starter = BlockingSerialRuntimeStarter(
            status: LiveShellStatus(runtimeId: "term_serial_orphan", status: "running", diagnostic: "running")
        )
        let coordinator = SerialSessionCoordinator(
            runtimeStarter: starter,
            workspace: try XCTUnwrap(workspace)
        )
        let config = SerialConnectionConfig(
            devicePath: "/dev/cu.usbserial-001",
            baudRate: 9_600,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )
        workspace = nil

        XCTAssertThrowsError(try coordinator.openSessionTab(config: config, title: "串口控制台")) { error in
            guard case RemoteTerminalLifecycleError.reconnectUnavailable = error else {
                return XCTFail("Expected reconnectUnavailable, got \(error)")
            }
        }
        let didStartRuntime = starter.waitUntilStartRequested(timeout: 0.1)
        if didStartRuntime {
            starter.releaseStart()
        }

        XCTAssertFalse(didStartRuntime)
    }

    func testStartRejectsNonRunningSerialStatusWithoutOpeningWorkspace() {
        let workspace = RecordingSerialWorkspaceOpening()
        let starter = ReturningSerialRuntimeStarter(
            status: LiveShellStatus(
                runtimeId: "term_serial_failed",
                status: "failed",
                diagnostic: "Device or resource busy /dev/cu.usbserial-001"
            )
        )
        let coordinator = SerialSessionCoordinator(runtimeStarter: starter, workspace: workspace)
        let config = SerialConnectionConfig(
            devicePath: "/dev/cu.usbserial-001",
            baudRate: 9_600,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )

        XCTAssertThrowsError(try coordinator.start(config: config, title: "串口控制台")) { error in
            XCTAssertEqual(
                SerialSessionCoordinator.diagnosticMessage(for: error),
                "串口连接失败：设备正忙 [已隐藏路径]"
            )
        }
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testStartPermissionFailureUsesChineseDiagnostic() {
        XCTAssertEqual(
            SerialSessionCoordinator.diagnosticMessage(
                for: SshRuntimeError.Transport(message: "Operation not permitted /dev/cu.usbserial-001")
            ),
            "串口连接失败：没有操作权限 [已隐藏路径]"
        )
    }

    func testStartBusyDeviceFailureUsesChineseDiagnostic() {
        XCTAssertEqual(
            SerialSessionCoordinator.diagnosticMessage(
                for: SshRuntimeError.Transport(message: "Device or resource busy /dev/cu.usbserial-001")
            ),
            "串口连接失败：设备正忙 [已隐藏路径]"
        )
    }

    func testInvalidConfigUsesSerialSpecificChineseDiagnostic() {
        XCTAssertEqual(
            SerialSessionCoordinator.diagnosticMessage(for: SshRuntimeError.InvalidConfig),
            "串口连接失败：串口配置无效，请检查设备路径和波特率。"
        )
    }
}

private struct FailingSerialRuntimeStarter: SerialRuntimeStarting {
    let error: Error

    func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        throw error
    }
}

private struct ReturningSerialRuntimeStarter: SerialRuntimeStarting {
    let status: LiveShellStatus

    func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        status
    }
}

private final class RecordingSerialRuntimeStarter: SerialRuntimeStarting {
    private(set) var startCount = 0
    private let status: LiveShellStatus

    init(status: LiveShellStatus) {
        self.status = status
    }

    func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        startCount += 1
        return status
    }
}

private final class BlockingSerialRuntimeStarter: SerialRuntimeStarting {
    private let startRequested = DispatchSemaphore(value: 0)
    private let releaseStartSignal = DispatchSemaphore(value: 0)
    private let status: LiveShellStatus

    init(status: LiveShellStatus) {
        self.status = status
    }

    func waitUntilStartRequested(timeout: TimeInterval = 1) -> Bool {
        startRequested.wait(timeout: .now() + timeout) == .success
    }

    func releaseStart() {
        releaseStartSignal.signal()
    }

    func startLiveSerialShellRuntime(
        config: SerialConnectionConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        startRequested.signal()
        _ = releaseStartSignal.wait(timeout: .now() + 1)
        return status
    }
}

private final class RecordingSerialWorkspaceOpening: RemoteWorkspaceOpening {
    var openedStatuses: [LiveShellStatus] = []
    var pendingTitles: [String] = []

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openedStatuses.append(status)
    }

    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteTerminalPaneViewController {
        pendingTitles.append(title)
        return RemoteTerminalPaneViewController(
            runtimeID: "pending_serial_test",
            title: title,
            connectionKind: connectionKind,
            eventSink: NoopSerialTerminalEventSink(),
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
    }
}

private final class NoopSerialTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}
