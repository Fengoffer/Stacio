import AppKit
import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class ConsoleSessionCoordinatorTests: XCTestCase {
    func testOpensExternalRuntimeAndAttachesOnlyAfterSubscription() throws {
        let lifecycle = ConsoleLifecycleRecorder()
        let runtime = RecordingConsoleTerminalRuntime(lifecycle: lifecycle)
        let driver = RecordingConsoleCentralDriver(lifecycle: lifecycle)
        let workspace = RecordingConsoleWorkspaceOpening()
        var session: BLEConsoleSession?
        let coordinator = ConsoleSessionCoordinator(
            runtime: runtime,
            sessionFactory: { config in
                let created = BLEConsoleSession(config: config, driver: driver)
                session = created
                return created
            },
            workspace: workspace
        )

        let opened = try coordinator.openSessionTab(
            config: coordinatorConsoleConfig(deviceID: driver.deviceID),
            title: "Core Switch"
        )
        let pane = try XCTUnwrap(workspace.pane)
        let activeSession = try XCTUnwrap(session)

        XCTAssertEqual(opened.kind, "ble_console")
        XCTAssertEqual(runtime.openedKinds, ["ble_console"])
        XCTAssertEqual(workspace.connectionKinds, [.console])
        XCTAssertTrue(workspace.serialOpenRequests.isEmpty)
        XCTAssertEqual(pane.runtimeID, opened.id)
        XCTAssertEqual(pane.lifecycleState, .connecting)

        connectCoordinatorSession(activeSession, driver: driver)
        XCTAssertEqual(activeSession.state, .subscribing)
        XCTAssertEqual(pane.lifecycleState, .connecting)

        activeSession.handle(.subscribed(
            identifier: driver.deviceID,
            characteristicUUID: "FFE2",
            generation: activeSession.currentGeneration
        ))

        XCTAssertEqual(pane.lifecycleState, .running)
        XCTAssertEqual(pane.runtimeID, opened.id)
    }

    func testRXInputResizePauseAndCloseUseTheBLEOwner() throws {
        let lifecycle = ConsoleLifecycleRecorder()
        let runtime = RecordingConsoleTerminalRuntime(lifecycle: lifecycle)
        let driver = RecordingConsoleCentralDriver(lifecycle: lifecycle)
        let workspace = RecordingConsoleWorkspaceOpening()
        var session: BLEConsoleSession?
        let coordinator = ConsoleSessionCoordinator(
            runtime: runtime,
            sessionFactory: { config in
                let created = BLEConsoleSession(config: config, driver: driver)
                session = created
                return created
            },
            workspace: workspace
        )

        let opened = try coordinator.openSessionTab(
            config: coordinatorConsoleConfig(deviceID: driver.deviceID),
            title: "Access Switch"
        )
        let activeSession = try XCTUnwrap(session)
        connectCoordinatorSession(activeSession, driver: driver)
        activeSession.handle(.subscribed(
            identifier: driver.deviceID,
            characteristicUUID: "FFE2",
            generation: activeSession.currentGeneration
        ))
        let pane = try XCTUnwrap(workspace.pane)

        let rx: [UInt8] = [0x00, 0xFF, 0x0D, 0x0A]
        activeSession.handle(.rxData(
            identifier: driver.deviceID,
            characteristicUUID: "FFE2",
            data: Data(rx),
            generation: activeSession.currentGeneration
        ))
        pane.sendInput([0x01, 0x02, 0x03])
        try workspace.eventSink?.terminalDidResize(runtimeID: opened.id, cols: 132, rows: 43)
        _ = try workspace.bridge?.setTerminalOutputPaused(runtimeID: opened.id, paused: true)
        try workspace.bridge?.setLiveShellKeepaliveInterval(runtimeID: opened.id, seconds: 30)

        XCTAssertEqual(runtime.recordedOutputs, [rx])
        XCTAssertEqual(driver.writes.flatMap { Array($0) }, [0x01, 0x02, 0x03])
        XCTAssertEqual(
            runtime.resizeEvents.last,
            TerminalResizeEvent(runtimeID: opened.id, cols: 132, rows: 43)
        )
        XCTAssertEqual(runtime.pauseValues, [true])
        XCTAssertEqual(runtime.keepaliveCallCount, 0)

        pane.closeTerminal()
        pane.closeTerminal()

        XCTAssertEqual(driver.disconnectCount, 1)
        XCTAssertEqual(runtime.closedRuntimeIDs, [opened.id])
        XCTAssertEqual(Array(lifecycle.events.suffix(2)), ["ble.close", "runtime.close"])
    }

    func testReturnRetriesStoppedConsoleWithoutOpeningSerial() throws {
        let runtime = RecordingConsoleTerminalRuntime()
        let driver = RecordingConsoleCentralDriver()
        let workspace = RecordingConsoleWorkspaceOpening()
        var session: BLEConsoleSession?
        let coordinator = ConsoleSessionCoordinator(
            runtime: runtime,
            sessionFactory: { config in
                let created = BLEConsoleSession(config: config, driver: driver)
                session = created
                return created
            },
            workspace: workspace
        )
        _ = try coordinator.openSessionTab(
            config: coordinatorConsoleConfig(deviceID: driver.deviceID),
            title: "Router Console"
        )
        let activeSession = try XCTUnwrap(session)
        let pane = try XCTUnwrap(workspace.pane)

        activeSession.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: "busy",
            generation: activeSession.currentGeneration
        ))
        activeSession.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: "busy",
            generation: activeSession.currentGeneration
        ))
        activeSession.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: "busy",
            generation: activeSession.currentGeneration
        ))
        activeSession.handle(.connectionFailed(
            identifier: driver.deviceID,
            code: .connectFailed,
            diagnostic: "busy",
            generation: activeSession.currentGeneration
        ))
        XCTAssertEqual(pane.lifecycleState, .disconnected)

        pane.send(source: pane.terminalView, data: ArraySlice(Array("\r".utf8)))

        XCTAssertEqual(driver.connectCount, 2)
        XCTAssertEqual(pane.lifecycleState, .connecting)
        XCTAssertTrue(workspace.serialOpenRequests.isEmpty)
    }

    func testWorkspaceRejectsConsoleSplitAndDuplicate() throws {
        let runtime = RecordingConsoleTerminalRuntime()
        let driver = RecordingConsoleCentralDriver()
        let presenter = RecordingConsoleTabOperationsPresenter()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            startsRemoteTerminalPollingAutomatically: false,
            tabOperationsPresenter: presenter
        )
        workspace.loadView()
        let coordinator = ConsoleSessionCoordinator(
            runtime: runtime,
            sessionFactory: { config in
                BLEConsoleSession(config: config, driver: driver)
            },
            workspace: workspace
        )

        _ = try coordinator.openSessionTab(
            config: coordinatorConsoleConfig(deviceID: driver.deviceID),
            title: "NBEE Console"
        )

        XCTAssertThrowsError(try workspace.splitCurrentTerminal())
        XCTAssertThrowsError(try workspace.performTabContextActionForTesting(.duplicate, index: 0))
        XCTAssertEqual(workspace.tabIconIdentifierForTesting(index: 0), "console-default")
        XCTAssertEqual(driver.connectCount, 1)
        XCTAssertEqual(presenter.errorCount, 1)
    }
}

@MainActor
private final class RecordingConsoleTabOperationsPresenter: WorkspaceTabOperationsPresenting {
    private(set) var errorCount = 0

    func promptRenameTab(currentTitle: String, parentWindow: NSWindow?) -> String? { nil }
    func chooseTabColor(currentColor: NSColor, title: String, parentWindow: NSWindow?) -> NSColor? { nil }
    func chooseTerminalOutputDestination(suggestedName: String, parentWindow: NSWindow?) -> URL? { nil }
    func presentTerminalOutputSaved(destinationURL: URL, parentWindow: NSWindow?) {}

    func presentError(title: String, message: String, parentWindow: NSWindow?) {
        errorCount += 1
    }
}

@MainActor
private func connectCoordinatorSession(
    _ session: BLEConsoleSession,
    driver: RecordingConsoleCentralDriver
) {
    session.handle(.connected(
        identifier: driver.deviceID,
        generation: session.currentGeneration
    ))
    session.handle(.servicesDiscovered(
        identifier: driver.deviceID,
        services: [ConsoleServiceMetadata(
            uuid: "FFE1",
            characteristics: [
                ConsoleCharacteristicMetadata(
                    uuid: "FFE3",
                    supportsWrite: false,
                    supportsWriteWithoutResponse: true,
                    supportsNotify: false,
                    supportsIndicate: false
                ),
                ConsoleCharacteristicMetadata(
                    uuid: "FFE2",
                    supportsWrite: false,
                    supportsWriteWithoutResponse: false,
                    supportsNotify: true,
                    supportsIndicate: false
                ),
            ]
        )],
        generation: session.currentGeneration
    ))
}

private func coordinatorConsoleConfig(deviceID: UUID) -> ConsoleSessionConfig {
    ConsoleSessionConfig(
        kind: "console",
        schemaVersion: 1,
        transportPolicy: "prefer_ble",
        ble: ConsoleBleConfig(
            deviceName: "NBEE_BLE_1103",
            profileId: "bterm-ffe1-split-v1",
            serviceUuid: "FFE1",
            txCharacteristicUuid: "FFE3",
            rxCharacteristicUuid: "FFE2",
            writeType: "without_response",
            platformBindings: ConsolePlatformBindings(
                macOsPeripheralUuid: deviceID.uuidString,
                windowsDeviceId: nil
            )
        ),
        sppFallback: nil
    )
}

private final class ConsoleLifecycleRecorder {
    var events: [String] = []
}

private final class RecordingConsoleCentralDriver: BLEConsoleCentralDriving, @unchecked Sendable {
    let deviceID = UUID()
    var eventHandler: (@Sendable (BLEConsoleCentralEvent) -> Void)?
    private let lifecycle: ConsoleLifecycleRecorder?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var writes: [Data] = []

    init(lifecycle: ConsoleLifecycleRecorder? = nil) {
        self.lifecycle = lifecycle
    }

    func startScan() {}
    func stopScan() {}

    func connect(identifier: UUID, generation: UInt64) {
        connectCount += 1
        lifecycle?.events.append("ble.connect")
    }

    func discoverProfile(identifier: UUID, generation: UInt64) {}
    func subscribe(identifier: UUID, characteristicUUID: String, generation: UInt64) {}
    func maximumWriteLength(identifier: UUID, withoutResponse: Bool) -> Int { 185 }
    func canSendWriteWithoutResponse(identifier: UUID) -> Bool { true }

    func write(
        identifier: UUID,
        characteristicUUID: String,
        data: Data,
        withoutResponse: Bool,
        generation: UInt64
    ) {
        writes.append(data)
    }

    func disconnect(identifier: UUID, generation: UInt64) {
        disconnectCount += 1
        lifecycle?.events.append("ble.close")
    }
}

private final class RecordingConsoleTerminalRuntime: BLEConsoleTerminalRuntimeManaging {
    private let lifecycle: ConsoleLifecycleRecorder?
    private(set) var openedKinds: [String] = []
    private(set) var recordedOutputs: [[UInt8]] = []
    private(set) var resizeEvents: [TerminalResizeEvent] = []
    private(set) var pauseValues: [Bool] = []
    private(set) var closedRuntimeIDs: [String] = []
    private(set) var keepaliveCallCount = 0
    private var runtime: TerminalRuntime?

    init(lifecycle: ConsoleLifecycleRecorder? = nil) {
        self.lifecycle = lifecycle
    }

    func openExternalTerminalRuntime(
        kind: String,
        endpoint: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> TerminalRuntime {
        openedKinds.append(kind)
        let opened = TerminalRuntime(
            id: "term_ble_console",
            kind: kind,
            shellPath: "",
            remoteHost: endpoint,
            remotePort: nil,
            username: nil,
            cols: cols,
            rows: rows,
            resizeRevision: 0,
            status: "running",
            outputPaused: false
        )
        runtime = opened
        return opened
    }

    func recordTerminalResize(runtimeID: String, cols: UInt32, rows: UInt32) throws -> TerminalRuntime {
        resizeEvents.append(TerminalResizeEvent(runtimeID: runtimeID, cols: Int(cols), rows: Int(rows)))
        var updated = runtime!
        updated.cols = cols
        updated.rows = rows
        runtime = updated
        return updated
    }

    func recordTerminalOutput(runtimeID: String, bytes: [UInt8]) throws {
        recordedOutputs.append(bytes)
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(
            runtimeId: runtimeID,
            bytes: Data(),
            droppedByteCount: 0,
            protectionActive: false,
            bufferedByteCount: 0
        )
    }

    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        pauseValues.append(paused)
        var updated = runtime!
        updated.outputPaused = paused
        runtime = updated
        return updated
    }

    func closeTerminalRuntime(runtimeID: String) throws -> TerminalRuntime {
        closedRuntimeIDs.append(runtimeID)
        lifecycle?.events.append("runtime.close")
        var closed = runtime!
        closed.status = "closed"
        runtime = closed
        return closed
    }
}

@MainActor
private final class RecordingConsoleWorkspaceOpening: ConsoleWorkspaceOpening {
    private(set) var connectionKinds: [RemoteTerminalConnectionKind] = []
    private(set) var serialOpenRequests: [String] = []
    private(set) var pane: RemoteTerminalPaneViewController?
    private(set) var eventSink: TerminalEventSink?
    private(set) var bridge: RemoteTerminalBridging?

    func openConnectingConsole(
        runtimeID: String,
        title: String,
        eventSink: TerminalEventSink,
        bridge: RemoteTerminalBridging
    ) -> RemoteTerminalPaneViewController {
        connectionKinds.append(.console)
        self.eventSink = eventSink
        self.bridge = bridge
        let pane = RemoteTerminalPaneViewController(
            runtimeID: runtimeID,
            title: title,
            connectionKind: .console,
            eventSink: eventSink,
            bridge: bridge,
            startsPollingAutomatically: false
        )
        pane.loadView()
        pane.displayConnectionStarting()
        self.pane = pane
        return pane
    }
}
