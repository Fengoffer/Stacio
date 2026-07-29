import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class MultiExecCoordinatorTests: XCTestCase {
    func testConsolePaneParticipatesInMultiExecAndAgentSessionListing() throws {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { MultiExecConsoleRecordingEventSink() },
            remoteTerminalBridgeFactory: { MultiExecConsoleRecordingBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_console", status: "running", diagnostic: "running"),
            title: "BLE Console",
            connectionKind: .console
        )

        XCTAssertEqual(workspace.currentSessionProtocol, .console)
        XCTAssertTrue(workspace.allowsWorkspaceCapability(.ai))
        XCTAssertTrue(workspace.allowsWorkspaceCapability(.diagnostics))
        XCTAssertFalse(workspace.allowsWorkspaceCapability(.files))
        XCTAssertFalse(workspace.allowsWorkspaceCapability(.tunnels))
        XCTAssertNil(workspace.currentDeviceMetricsDashboardTitleForTesting)
        XCTAssertEqual(workspace.listAgentTerminalSessions().map(\.kind), ["console"])

        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_ssh", status: "running", diagnostic: "running"),
            title: "SSH",
            connectionKind: .ssh
        )
        try workspace.startMultiExecSession(targetIDs: ["term_console", "term_ssh"])

        XCTAssertEqual(workspace.currentSplitPaneRuntimeIDsForTesting, ["term_console", "term_ssh"])
    }

    func testConsoleMacroAndAgentInputUseTheSamePaneInputPath() throws {
        let sink = MultiExecConsoleRecordingEventSink()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { sink },
            remoteTerminalBridgeFactory: { MultiExecConsoleRecordingBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_console", status: "running", diagnostic: "running"),
            title: "BLE Console",
            connectionKind: .console
        )

        let macroTarget = try XCTUnwrap(workspace.currentTerminalMacroPlaybackTarget())
        let agentTarget = try workspace.resolveTerminalTarget(.currentTerminal)
        macroTarget.sendInput(Array("show version\n".utf8))
        agentTarget.sendAgentInput(Array("show status\n".utf8))

        XCTAssertEqual(sink.inputEvents, [
            TerminalInputEvent(runtimeID: "term_console", bytes: Array("show version\n".utf8)),
            TerminalInputEvent(runtimeID: "term_console", bytes: Array("show status\n".utf8)),
        ])
    }

    func testConsoleWithLiveSSHContextDoesNotProbeRemoteOSOrAcceptUploadDrop() throws {
        let probeRecorder = MultiExecConsoleRemoteOSProbeRecorder()
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { MultiExecConsoleRecordingEventSink() },
            remoteTerminalBridgeFactory: { MultiExecConsoleRecordingBridge() },
            startsRemoteTerminalPollingAutomatically: false,
            remoteOSProbe: { _ in
                probeRecorder.recordCall()
                throw NSError(domain: "UnexpectedConsoleRemoteOSProbe", code: 1)
            }
        )
        workspace.loadView()
        workspace.openRemoteShell(
            status: LiveShellStatus(runtimeId: "term_console", status: "running", diagnostic: "running"),
            title: "BLE Console",
            connectionKind: .console,
            liveSessionContext: multiExecConsoleLiveContext()
        )
        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteTerminalPaneViewController)
        var droppedUploadCount = 0
        pane.onUploadDroppedFiles = { _, _ in droppedUploadCount += 1 }

        pane.performDropLocalFilesForTesting(["/tmp/console-upload.txt"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(probeRecorder.callCount, 0)
        XCTAssertFalse(pane.canAcceptDroppedLocalFiles)
        XCTAssertEqual(droppedUploadCount, 0)
    }

    func testTargetPreviewTreatsTrimmedProductionEnvironmentAsProduction() {
        let rows = MultiExecTargetPreviewRow.rows(for: [
            MultiExecTarget(
                id: "term_prod",
                label: "生产 API",
                environment: " Production ",
                enabled: true
            )
        ])

        XCTAssertEqual(rows.map(\.requiresProductionConfirmation), [true])
        XCTAssertEqual(rows.map(\.environmentLabel), [L10n.MultiExec.production])
    }

    func testSessionSelectionTargetsStartAtTopOfScrollView() throws {
        let form = MultiExecSessionSelectionForm(targets: [
            MultiExecTarget(id: "term_one", label: "172.16.10.250", environment: "development", enabled: true),
            MultiExecTarget(id: "term_two", label: "172.16.10.250", environment: "development", enabled: true)
        ])
        form.view.frame = NSRect(x: 0, y: 0, width: 520, height: 180)
        form.view.layoutSubtreeIfNeeded()

        let firstCheckbox = try XCTUnwrap(
            form.view.firstSubview(withIdentifier: "Stacio.MultiExec.sessionTarget.term_one") as? NSButton
        )
        let scrollView = try XCTUnwrap(firstCheckbox.enclosingScrollView)
        let checkboxFrameInClip = firstCheckbox.convert(firstCheckbox.bounds, to: scrollView.contentView)
        let clipBounds = scrollView.contentView.bounds
        let topGap = scrollView.contentView.isFlipped
            ? checkboxFrameInClip.minY - clipBounds.minY
            : clipBounds.maxY - checkboxFrameInClip.maxY

        XCTAssertLessThanOrEqual(topGap, 12)
    }

    func testSessionSelectionRowsIdentifyEachTerminalProtocolAtAGlance() {
        let choices = [
            MultiExecTargetChoice(
                target: MultiExecTarget(id: "term_ssh", label: "核心交换机", environment: "production", enabled: true),
                sessionProtocol: .ssh
            ),
            MultiExecTargetChoice(
                target: MultiExecTarget(id: "term_serial", label: "机房串口", environment: "development", enabled: true),
                sessionProtocol: .serial
            ),
            MultiExecTargetChoice(
                target: MultiExecTarget(id: "term_console", label: "NBEE_BLE_1103", environment: "development", enabled: true),
                sessionProtocol: .console
            ),
            MultiExecTargetChoice(
                target: MultiExecTarget(id: "term_telnet", label: "旧版交换机", environment: "development", enabled: true),
                sessionProtocol: .telnet
            )
        ]

        let form = MultiExecSessionSelectionForm(targetChoices: choices)
        form.view.frame = NSRect(x: 0, y: 0, width: 520, height: 180)
        form.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(form.protocolLabelsForTesting, [
            "term_ssh": "SSH",
            "term_serial": "串口",
            "term_console": "蓝牙 Console",
            "term_telnet": "Telnet"
        ])
        XCTAssertEqual(form.protocolSymbolNamesForTesting, [
            "term_ssh": "key.fill",
            "term_serial": "cable.connector",
            "term_console": "bluetooth",
            "term_telnet": "diamond.fill"
        ])
        XCTAssertTrue(form.protocolLabelsUseDistinctAccentColorsForTesting)
        XCTAssertGreaterThanOrEqual(form.minimumTargetRowHeightForTesting, 40)
        for choice in choices {
            let protocolLabel = form.view.firstSubview(
                withIdentifier: "Stacio.MultiExec.targetProtocol.\(choice.id)"
            )
            XCTAssertNotNil(protocolLabel)
            XCTAssertFalse(protocolLabel?.isHidden ?? true)
            XCTAssertGreaterThanOrEqual(protocolLabel?.frame.width ?? 0, 74)
        }
    }

    func testWorkspaceBuildsProtocolAwareChoicesForSplitAndMultiExec() {
        let workspace = WorkspaceViewController(
            autoStartTerminalProcesses: false,
            remoteTerminalEventSinkFactory: { MultiExecConsoleRecordingEventSink() },
            remoteTerminalBridgeFactory: { MultiExecConsoleRecordingBridge() },
            startsRemoteTerminalPollingAutomatically: false
        )
        workspace.loadView()
        for (id, title, kind) in [
            ("term_ssh", "SSH", RemoteTerminalConnectionKind.ssh),
            ("term_serial", "串口", .serial),
            ("term_console", "蓝牙 Console", .console),
            ("term_telnet", "Telnet", .telnet)
        ] {
            workspace.openRemoteShell(
                status: LiveShellStatus(runtimeId: id, status: "running", diagnostic: "running"),
                title: title,
                connectionKind: kind
            )
        }

        XCTAssertEqual(
            workspace.multiExecTargetChoices().map(\.sessionProtocol),
            [.ssh, .serial, .console, .telnet]
        )
        XCTAssertEqual(
            workspace.splitTargetChoices().map(\.sessionProtocol),
            [.ssh, .serial, .console, .telnet]
        )
    }

}

private final class MultiExecConsoleRecordingEventSink: TerminalEventSink {
    private(set) var inputEvents: [TerminalInputEvent] = []

    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {
        inputEvents.append(TerminalInputEvent(runtimeID: runtimeID, bytes: bytes))
    }
    func terminalDidClose(runtimeID: String) throws {}
}

private final class MultiExecConsoleRecordingBridge: RemoteTerminalBridging {
    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
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
        TerminalRuntime(
            id: runtimeID,
            kind: "ble_console",
            shellPath: "",
            remoteHost: nil,
            remotePort: nil,
            username: nil,
            cols: 80,
            rows: 24,
            resizeRevision: 0,
            status: "running",
            outputPaused: paused
        )
    }

    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {}

    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
    }
}

private final class MultiExecConsoleRemoteOSProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCallCount = 0

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func recordCall() {
        lock.withLock { recordedCallCount += 1 }
    }
}

private func multiExecConsoleLiveContext() -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: "console.example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:console"
    )
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
