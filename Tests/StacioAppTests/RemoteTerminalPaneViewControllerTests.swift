import AppKit
import StacioCoreBindings
import StacioAgentBridge
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class RemoteTerminalPaneViewControllerTests: XCTestCase {
    func testSessionAutomationPolicyParsesStartupPlanFromConfigJSON() {
        let policy = SessionAutomationPolicy.fromConfigJSON(
            #"{"environment":"production","aiExecutionPolicy":"commandCard","startupCommand":"cd /srv/app && docker compose ps","environmentVariables":["APP_ENV=prod","STACIO_TRACE=1"],"connectTimeoutMs":45000}"#
        )

        XCTAssertEqual(policy.environment, "production")
        XCTAssertEqual(policy.aiExecutionPolicy, "commandCard")
        XCTAssertEqual(policy.startupCommand, "cd /srv/app && docker compose ps")
        XCTAssertEqual(policy.environmentVariables, ["APP_ENV=prod", "STACIO_TRACE=1"])
        XCTAssertEqual(policy.connectTimeoutMs, 45_000)
        XCTAssertEqual(policy.startupPlanShellLine, "APP_ENV=prod STACIO_TRACE=1 cd /srv/app && docker compose ps")
    }

    func testSessionAutomationPolicyParsesLegacyMultilineEnvironmentVariableString() {
        let policy = SessionAutomationPolicy.fromConfigJSON(
            #"{"startupCommand":"uptime","environmentVariables":"APP_ENV=prod\n\nSTACIO_TRACE=1"}"#
        )

        XCTAssertEqual(policy.startupCommand, "uptime")
        XCTAssertEqual(policy.environmentVariables, ["APP_ENV=prod", "STACIO_TRACE=1"])
    }

    func testRemoteTerminalPaneLoadsSwiftTermViewWithoutLocalProcess() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()

        let hostedView = try XCTUnwrap(controller.view.subviews.first)
        XCTAssertTrue(controller.terminalView.superview === controller.view)
        XCTAssertTrue(hostedView is TerminalView)
        XCTAssertFalse(hostedView is LocalProcessTerminalView)
        XCTAssertEqual(controller.runtimeID, "term_remote")
        XCTAssertEqual(controller.title, "deploy@example.com")
    }

    func testRemoteTerminalDragSelectionDoesNotMoveWindow() {
        let terminalView = StacioRemoteTerminalView(frame: .zero)

        XCTAssertFalse(terminalView.mouseDownCanMoveWindow)
    }

    func testRemoteTerminalEnablesCommandClickImplicitLinks() {
        let terminalView = StacioRemoteTerminalView(frame: .zero)

        XCTAssertEqual(terminalView.linkReporting, .implicit)
        XCTAssertEqual(terminalView.linkHighlightMode, .hoverWithModifier)
    }

    func testRemoteTerminalSystemThemeReappliesWhenEffectiveAppearanceChanges() throws {
        let suiteName = "StacioRemoteTerminalSystemAppearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .system
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.viewDidChangeEffectiveAppearance()
        let lightBackground = try XCTUnwrap(controller.terminalView.layer?.backgroundColor)

        controller.view.appearance = NSAppearance(named: .darkAqua)
        controller.view.viewDidChangeEffectiveAppearance()
        let darkBackground = try XCTUnwrap(controller.terminalView.layer?.backgroundColor)

        XCTAssertGreaterThan(lightBackground.stacioTestRelativeLuminance, 0.75)
        XCTAssertLessThan(darkBackground.stacioTestRelativeLuminance, 0.25)
    }

    func testRemoteAgentTraceRendersOverlayWithoutWritingRemoteInputOrTranscript() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "prod@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-1",
            state: .awaitingApproval,
            message: "等待确认",
            redactedCommand: "rm -rf /tmp/build"
        )

        XCTAssertEqual(sink.userInputEvents, [])
        XCTAssertEqual(controller.terminalOutputTranscript, "")
        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("等待确认"))
        XCTAssertTrue(controller.agentTraceOverlayVisibleForTesting)
        XCTAssertTrue(controller.agentTraceOverlayTextForTesting.contains("等待确认"))
        XCTAssertTrue(controller.agentTraceOverlayTextForTesting.contains("rm -rf /tmp/build"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-1"))
    }

    func testRemoteAgentTraceOverlayShowsBackgroundProgressWithoutInternalMetadata() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "prod@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-background",
            state: .waitingForOutput,
            message: "已创建独立执行终端，等待输出",
            redactedCommand: "uptime",
            metadata: [
                "executionMode": "backgroundTask",
                "taskRuntimeID": "agent_bg_1"
            ]
        )

        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("已创建独立执行终端"))
        XCTAssertTrue(controller.agentTraceOverlayTextForTesting.contains("已创建独立执行终端"))
        XCTAssertFalse(controller.agentTraceOverlayTextForTesting.contains("agent_bg_1"))
        XCTAssertFalse(controller.agentTraceOverlayTextForTesting.contains("backgroundTask"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-background"))
    }

    func testUserInputIsForwardedToEventSink() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.send(source: controller.terminalView, data: ArraySlice(Array("whoami\n".utf8)))

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("whoami\n".utf8))
        ])
    }

    func testAgentLockShowsDedicatedFourEdgeGlowAndUnlockHidesIt() throws {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_agent_glow",
            title: "FengLee@FengStor",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )
        controller.loadView()

        controller.setAgentInteractionLocked(true)

        XCTAssertTrue(controller.agentInteractionGlowActiveForTesting)
        XCTAssertTrue(controller.agentInteractionGlowPreservesTransparentCenterForTesting)
        let glow = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentInteractionGlow")
        )
        XCTAssertTrue(glow.superview === controller.terminalView.superview)
        XCTAssertNil(glow.hitTest(NSPoint(x: 1, y: 1)))

        controller.setAgentInteractionLocked(false)

        XCTAssertFalse(controller.agentInteractionGlowActiveForTesting)
    }

    func testCoordinatorCompletesScreenshotCommandThroughRealRemoteTerminalController() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_real_controller",
            title: "FengLee@FengStor",
            eventSink: sink,
            startsPollingAutomatically: false
        )
        controller.loadView()
        sink.onInput = { [weak controller] event in
            guard String(decoding: event.bytes, as: UTF8.self).contains("top -bn1 | head -20") else {
                return
            }
            controller?.feedRemoteOutput(Array("top - 19:10:05 up 3 days, load average: 5.18\n%Cpu(s): 0.0 us, 0.0 sy\n793861 root 314.3 java\nFengLee@FengStor:~$ ".utf8))
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: SingleRemoteTerminalResolver(target: controller),
            authorizer: AllowingRemoteTerminalAuthorizer(),
            visibleTerminalCompletion: .init(idleInterval: 0.05, maximumDuration: 0.5)
        )
        var broadcastUserInputCount = 0
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_real_controller") { event in
            if event.kind == .userInput {
                broadcastUserInputCount += 1
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(
                runtimeID: "term_real_controller",
                subscription: subscription
            )
        }
        let request = AgentBridgeRequest(
            id: "req-real-controller-top",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(
                target: .runtimeID("term_real_controller"),
                command: "top -bn1 | head -20",
                follow: true
            ))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("793861 root 314.3 java") == true)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
        XCTAssertFalse(controller.agentInteractionGlowActiveForTesting)
        XCTAssertEqual(broadcastUserInputCount, 0, "agent input must not be classified as user input")
    }

    func testCoordinatorPumpsRemoteBridgeOutputWhileSynchronouslyObservingAgentCommand() throws {
        let runtimeID = "term_nested_runloop"
        let bridge = RecordingRemoteTerminalBridge(
            statuses: Array(
                repeating: LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running"),
                count: 3
            ),
            outputBatches: [
                TerminalOutputBatch(runtimeId: runtimeID, bytes: Data(), droppedByteCount: 0),
                TerminalOutputBatch(
                    runtimeId: runtimeID,
                    bytes: Data("5 0 3454288 603448 208988 1611640 12 0 20 0 4 4069 6832 86 6\n\u{001B}]777;stacio-agent-done=req-vmstat\u{0007}FengLee@FengStor:~$ ".utf8),
                    droppedByteCount: 0
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: runtimeID,
            title: "FengLee@FengStor",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            startsPollingAutomatically: false
        )
        controller.loadView()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: SingleRemoteTerminalResolver(target: controller),
            authorizer: AllowingRemoteTerminalAuthorizer(),
            visibleTerminalCompletion: .init(idleInterval: 0.5, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-vmstat",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(
                target: .runtimeID(runtimeID),
                command: "LC_ALL=C vmstat 1 2 | tail -n 1",
                follow: true
            ))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertGreaterThanOrEqual(bridge.outputRuntimeIDs.count, 2)
        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "agentCompletionMarker")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("3454288") == true)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
        XCTAssertFalse(controller.agentInteractionGlowActiveForTesting)
    }

    func testRemoteOutputBroadcastsSameBatchTakenByTerminalPane() {
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "")
            ],
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data("real output\n".utf8),
                    droppedByteCount: 0
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            startsPollingAutomatically: false
        )
        var mirrored: [String] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            if event.kind == .output {
                mirrored.append(String(decoding: event.bytes, as: UTF8.self))
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }

        controller.loadView()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(bridge.outputRuntimeIDs, ["term_remote"])
        XCTAssertEqual(controller.terminalOutputTranscript, "real output\n")
        XCTAssertEqual(mirrored, ["real output\n"])
    }

    func testRemoteTerminalShowsLargeOutputProtectionStatus() {
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "")
            ],
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data("abc".utf8),
                    droppedByteCount: 2,
                    protectionActive: true,
                    bufferedByteCount: 3
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()

        XCTAssertTrue(controller.outputProtectionStatusVisibleForTesting)
        XCTAssertTrue(controller.outputProtectionStatusTextForTesting.contains("已跳过 2 字节"))
    }

    func testRemoteTerminalPauseOutputTogglesCoreRuntime() {
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.toggleOutputPauseForTesting()
        controller.toggleOutputPauseForTesting()

        XCTAssertEqual(
            bridge.outputPauseEvents,
            [
                OutputPauseEvent(runtimeID: "term_remote", paused: true),
                OutputPauseEvent(runtimeID: "term_remote", paused: false)
            ]
        )
        XCTAssertFalse(controller.outputProtectionStatusVisibleForTesting)
    }

    func testUserInputSchedulesImmediateOutputDrainWithoutWaitingForPollTimer() {
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
            ],
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data("\r\nroot@host:~# ".utf8),
                    droppedByteCount: 0
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge
        )

        controller.loadView()
        controller.viewDidAppear()
        defer { controller.viewWillDisappear() }
        controller.sendInput([UInt8(ascii: "\n")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertGreaterThanOrEqual(bridge.polledRuntimeIDs.count, 1)
        XCTAssertEqual(Set(bridge.polledRuntimeIDs), ["term_remote"])
        XCTAssertGreaterThanOrEqual(bridge.outputRuntimeIDs.count, 1)
        XCTAssertEqual(Set(bridge.outputRuntimeIDs), ["term_remote"])
        XCTAssertTrue(controller.terminalOutputTranscript.contains("\r\nroot@host:~# "))
    }

    func testImmediateOutputDrainConsumesSplitPromptBatchesInOneBurst() {
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
            ],
            outputBatches: [
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("\r\n".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("root@host:~# ".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("\r\n".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("root@host:~# ".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0)
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge
        )

        controller.loadView()
        controller.feedRemoteOutput(Array("root@host:~# ".utf8))
        controller.viewDidAppear()
        defer { controller.viewWillDisappear() }
        controller.sendInput([UInt8(ascii: "\n")])
        controller.sendInput([UInt8(ascii: "\n")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertGreaterThanOrEqual(bridge.outputRuntimeIDs.count, 5)
        XCTAssertEqual(Set(bridge.outputRuntimeIDs), ["term_remote"])
        XCTAssertEqual(
            controller.terminalOutputTranscript,
            "root@host:~# \r\nroot@host:~# \r\nroot@host:~# "
        )
    }

    func testImmediateOutputDrainKeepsPollingAfterInitialEmptyBatchForRapidEnter() {
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
            ],
            outputBatches: [
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("\r\nroot@host:~# ".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("\r\nroot@host:~# ".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0)
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge
        )

        controller.loadView()
        controller.feedRemoteOutput(Array("root@host:~# ".utf8))
        controller.viewDidAppear()
        defer { controller.viewWillDisappear() }
        controller.sendInput([UInt8(ascii: "\n")])
        controller.sendInput([UInt8(ascii: "\n")])
        let expectedTranscript = "root@host:~# \r\nroot@host:~# \r\nroot@host:~# "
        XCTAssertTrue(
            waitForRemoteTerminalCondition {
                bridge.outputRuntimeIDs.count >= 4
                    && controller.terminalOutputTranscript == expectedTranscript
            },
            "Timed out waiting for immediate drain after initial empty batch; polls=\(bridge.outputRuntimeIDs.count), transcript=\(controller.terminalOutputTranscript.debugDescription)"
        )

        XCTAssertGreaterThanOrEqual(bridge.outputRuntimeIDs.count, 4)
        XCTAssertEqual(controller.terminalOutputTranscript, expectedTranscript)
    }

    func testImmediateOutputDrainKeepsTrackingDelayedRapidEnterPrompts() {
        let bridge = RecordingRemoteTerminalBridge(
            statuses: Array(
                repeating: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                count: 12
            ),
            outputBatches: Array(
                repeating: TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0),
                count: 8
            ) + [
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("\r\nroot@host:~# ".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data("\r\nroot@host:~# ".utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0)
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge
        )

        controller.loadView()
        controller.feedRemoteOutput(Array("root@host:~# ".utf8))
        controller.viewDidAppear()
        defer { controller.viewWillDisappear() }
        controller.sendInput([UInt8(ascii: "\n")])
        controller.sendInput([UInt8(ascii: "\n")])
        let expectedTranscript = "root@host:~# \r\nroot@host:~# \r\nroot@host:~# "
        XCTAssertTrue(
            waitForRemoteTerminalCondition {
                controller.terminalOutputTranscript == expectedTranscript
            },
            "Timed out waiting for delayed rapid-enter prompts; transcript=\(controller.terminalOutputTranscript.debugDescription)"
        )

        XCTAssertEqual(controller.terminalOutputTranscript, expectedTranscript)
    }

    func testRepeatedEnterRefreshesImmediateOutputDrainWindow() {
        let delayedPrompt = "\r\nroot@host:~# "
        let bridge = RecordingRemoteTerminalBridge(
            statuses: Array(
                repeating: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
                count: 48
            ),
            outputBatches: Array(
                repeating: TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0),
                count: 38
            ) + [
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(delayedPrompt.utf8), droppedByteCount: 0),
                TerminalOutputBatch(runtimeId: "term_remote", bytes: Data(), droppedByteCount: 0)
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge
        )

        controller.loadView()
        controller.feedRemoteOutput(Array("root@host:~# ".utf8))
        controller.viewDidAppear()
        defer { controller.viewWillDisappear() }
        controller.sendInput([UInt8(ascii: "\n")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        controller.sendInput([UInt8(ascii: "\n")])

        XCTAssertTrue(
            waitForRemoteTerminalCondition(timeout: 2.0, step: 0.01) {
                controller.terminalOutputTranscript.hasSuffix("root@host:~# \(delayedPrompt)")
            },
            "Timed out waiting for refreshed immediate drain window; polls=\(bridge.outputRuntimeIDs.count), transcript=\(controller.terminalOutputTranscript.debugDescription)"
        )
        XCTAssertGreaterThanOrEqual(bridge.outputRuntimeIDs.count, 39)
    }

    private func waitForRemoteTerminalCondition(
        timeout: TimeInterval = 1.0,
        step: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(step))
        }
        return condition()
    }

    func testRemoteUserInputPublishesOwnershipBoundaryEvent() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink()
        )
        var inputs: [String] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            if event.kind == .userInput {
                inputs.append(String(decoding: event.bytes, as: UTF8.self))
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }

        controller.loadView()
        controller.send(source: controller.terminalView, data: ArraySlice(Array("whoami\n".utf8)))

        XCTAssertEqual(inputs, ["whoami\n"])
    }

    func testAttachConnectedRuntimeWritesPostConnectScriptAsSilentInputWithoutClientBanners() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(
                postConnectScript: "cd /srv/app\nsource .env && export PS1='prod> '"
            ),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.displayConnectionStarting()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running"),
            startupBanner: "Stacio SSH connected\r\n"
        )

        XCTAssertEqual(controller.runtimeID, "term_remote")
        XCTAssertEqual(
            sink.userInputEvents,
            [
                TerminalInputEvent(
                    runtimeID: "term_remote",
                    bytes: Array("cd /srv/app\nsource .env && export PS1='prod> '\n".utf8)
                )
            ]
        )
        XCTAssertEqual(controller.terminalOutputTranscript, "")
        XCTAssertFalse(controller.terminalOutputTranscript.contains("正在连接 deploy@example.com"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("Stacio SSH connected"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("source .env"))
    }

    func testAttachConnectedRuntimeSkipsEmptyPostConnectScript() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: " \n\t "),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.displayConnectionStarting()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )

        XCTAssertEqual(sink.userInputEvents, [])
    }

    func testAttachConnectedRuntimeDoesNotBroadcastPostConnectScriptAsUserInput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "printf 'secret setup'\n"),
            startsPollingAutomatically: false
        )
        var inputs: [String] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            if event.kind == .userInput {
                inputs.append(String(decoding: event.bytes, as: UTF8.self))
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }

        controller.loadView()
        controller.displayConnectionStarting()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )

        XCTAssertEqual(
            sink.userInputEvents,
            [TerminalInputEvent(runtimeID: "term_remote", bytes: Array("printf 'secret setup'\n".utf8))]
        )
        XCTAssertEqual(inputs, [])
    }

    func testPostConnectScriptEchoIsFilteredFromVisibleOutputAndBroadcasts() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(
                postConnectScript: "cd /srv/app\nsource .env && echo READY"
            ),
            startsPollingAutomatically: false
        )
        var outputEvents: [String] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            if event.kind == .output {
                outputEvents.append(String(decoding: event.bytes, as: UTF8.self))
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        controller.feedRemoteOutput(Array("cd /srv/app\r\nsource .env && echo READY\r\nREADY\r\n".utf8))

        XCTAssertEqual(
            sink.userInputEvents,
            [
                TerminalInputEvent(
                    runtimeID: "term_remote",
                    bytes: Array("cd /srv/app\nsource .env && echo READY\n".utf8)
                )
            ]
        )
        XCTAssertTrue(controller.terminalOutputTranscript.contains("READY"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("cd /srv/app"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("source .env"))
        XCTAssertEqual(outputEvents, ["READY\r\n"])
    }

    func testPostConnectEchoFilterSurvivesInitialOSC7BootstrapReportUntilScriptEcho() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        controller.feedRemoteOutput(Array("\u{001B}]7;file://example.com/home/deploy\u{001B}\\".utf8))
        controller.feedRemoteOutput(Array("cd /srv/app\r\nroot@host:/srv/app# ".utf8))

        XCTAssertFalse(controller.terminalOutputTranscript.contains("cd /srv/app\r\n"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("root@host:/srv/app# "))
    }

    func testPostConnectEchoFilterClearsAlternatePatternsAfterFirstMatch() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false
        )
        var outputEvents: [String] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            if event.kind == .output {
                outputEvents.append(String(decoding: event.bytes, as: UTF8.self))
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        controller.feedRemoteOutput(Array("cd /srv/app\r\nREADY\r\n".utf8))
        controller.feedRemoteOutput(Array("cd /srv/app".utf8))

        XCTAssertEqual(outputEvents, ["READY\r\n", "cd /srv/app"])
        XCTAssertTrue(controller.terminalOutputTranscript.hasSuffix("READY\r\ncd /srv/app"))
    }

    func testSilentEchoFilterTimeoutPreservesMatchingNormalOutput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false,
            silentInputEchoTimeout: 0.01
        )

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        controller.feedRemoteOutput(Array("cd /srv/app\r\nroot@host:/srv/app# ".utf8))

        XCTAssertTrue(controller.terminalOutputTranscript.contains("cd /srv/app\r\nroot@host:/srv/app# "))
    }

    func testUserInputDuringSilentPostConnectIsSentImmediately() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        controller.sendInput(Array("pwd\n".utf8))

        XCTAssertEqual(
            sink.inputEvents,
            [
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd /srv/app\n".utf8)),
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("pwd\n".utf8))
            ]
        )

        controller.feedRemoteOutput(Array("root@host:/srv/app# ".utf8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(
            sink.inputEvents,
            [
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd /srv/app\n".utf8)),
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("pwd\n".utf8))
            ]
        )
        XCTAssertTrue(controller.terminalOutputTranscript.contains("root@host:/srv/app# "))
    }

    func testRapidEnterDuringSilentPostConnectIsSentWithoutWaitingForTimeout() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false,
            silentInputEchoTimeout: 5.0
        )
        var outputEvents: [String] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            if event.kind == .output {
                outputEvents.append(String(decoding: event.bytes, as: UTF8.self))
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        controller.sendInput([UInt8(ascii: "\n")])
        controller.sendInput([UInt8(ascii: "\n")])
        controller.sendInput([UInt8(ascii: "\n")])

        XCTAssertEqual(
            sink.inputEvents,
            [
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd /srv/app\n".utf8)),
                TerminalInputEvent(runtimeID: "term_remote", bytes: [UInt8(ascii: "\n")]),
                TerminalInputEvent(runtimeID: "term_remote", bytes: [UInt8(ascii: "\n")]),
                TerminalInputEvent(runtimeID: "term_remote", bytes: [UInt8(ascii: "\n")])
            ]
        )

        controller.feedRemoteOutput(Array("\r\nroot@host:/srv/app# ".utf8))

        XCTAssertFalse(outputEvents.isEmpty)
        XCTAssertTrue(controller.terminalOutputTranscript.contains("root@host:/srv/app# "))
    }

    func testSilentPostConnectTimeoutRestoresTTYEchoAfterImmediateUserInput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_remote",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false,
            silentInputEchoTimeout: 0.01
        )

        controller.loadView()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "running")
        )
        controller.sendInput(Array("pwd\n".utf8))
        XCTAssertEqual(
            sink.inputEvents,
            [
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd /srv/app\n".utf8)),
                TerminalInputEvent(runtimeID: "term_remote", bytes: Array("pwd\n".utf8))
            ]
        )

        XCTAssertTrue(
            waitForRemoteTerminalCondition {
                sink.inputEvents == [
                    TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd /srv/app\n".utf8)),
                    TerminalInputEvent(runtimeID: "term_remote", bytes: Array("pwd\n".utf8)),
                    TerminalInputEvent(runtimeID: "term_remote", bytes: Array("stty echo 2>/dev/null\n".utf8))
                ]
            },
            "Timed out waiting for silent post-connect echo restore; events=\(sink.inputEvents)"
        )
    }

    func testLoadedRunningRemoteTerminalWritesPostConnectScriptOnce() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_direct",
            title: "deploy@example.com",
            eventSink: sink,
            automationPolicy: SessionAutomationPolicy(postConnectScript: "cd /srv/app"),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.viewDidAppear()
        controller.viewDidAppear()

        XCTAssertEqual(
            sink.userInputEvents,
            [TerminalInputEvent(runtimeID: "term_direct", bytes: Array("cd /srv/app\n".utf8))]
        )
    }

    func testRemoteTerminalDoesNotWriteCurrentDirectoryHookIntoVisibleTerminalInputOnLoad() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()

        let startupInput = sink.inputEvents
            .map { String(decoding: $0.bytes, as: UTF8.self) }
            .joined()
        XCTAssertFalse(startupInput.contains("__stacio_report_cwd"))
        XCTAssertFalse(startupInput.contains("PROMPT_COMMAND"))
        XCTAssertFalse(startupInput.contains("precmd_functions"))
        XCTAssertFalse(startupInput.contains("ssh "))
        XCTAssertFalse(startupInput.contains("sftp "))
    }

    func testRemoteTerminalRetainsEventSinkSoKeyboardInputSurvivesFactoryScope() {
        var retainedOnlyByController: RecordingRemoteTerminalEventSink? = RecordingRemoteTerminalEventSink()
        let releasedWithoutControllerRetention = WeakReference(retainedOnlyByController)
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: retainedOnlyByController!
        )
        retainedOnlyByController = nil

        controller.loadView()
        controller.sendInput(Array("id\n".utf8))

        XCTAssertNotNil(releasedWithoutControllerRetention.value)
        XCTAssertEqual(releasedWithoutControllerRetention.value?.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("id\n".utf8))
        ])
    }

    func testInputSinkFailureShowsChineseDiagnosticInsteadOfSilentlyDroppingInput() {
        let sink = RecordingRemoteTerminalEventSink()
        sink.inputError = TerminalRuntimeError.RuntimeIo(message: "Broken pipe")
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.sendInput(Array("whoami\n".utf8))

        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "已断开：终端读写失败：连接管道已断开")
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("StacioCoreBindings"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("TerminalRuntimeError"))
    }

    func testRemoteOutputFeedsTerminalView() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.feedRemoteOutput(Array("hello\n".utf8))

        XCTAssertTrue(sink.userInputEvents.isEmpty)
    }

    func testRemoteTerminalTracksHostCurrentDirectoryUpdates() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/srv/app")
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "   ")

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/app")
    }

    func testRemoteTerminalAcceptsFinderDropsForUploadToCurrentDirectory() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            liveSessionContext: remoteLiveContext(host: "files.example.com"),
            eventSink: sink
        )
        var droppedUploads: [(remoteDirectory: String, localPaths: [String])] = []
        controller.onUploadDroppedFiles = { remoteDirectory, localPaths in
            droppedUploads.append((remoteDirectory, localPaths))
        }

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/srv/app")
        controller.performDropLocalFilesForTesting([
            "/Users/alice/build.zip",
            "/Users/alice/release"
        ])

        XCTAssertTrue(controller.terminalView.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(controller.view.registeredDraggedTypes.contains(.fileURL))
        XCTAssertEqual(droppedUploads.map(\.remoteDirectory), ["/srv/app"])
        XCTAssertEqual(droppedUploads.first?.localPaths, [
            "/Users/alice/build.zip",
            "/Users/alice/release"
        ])
    }

    func testRemoteTerminalWithoutLiveSSHContextDoesNotAcceptFinderDrops() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_serial",
            title: "串口控制台",
            connectionKind: .serial,
            eventSink: sink
        )
        var droppedUploads: [(remoteDirectory: String, localPaths: [String])] = []
        controller.onUploadDroppedFiles = { remoteDirectory, localPaths in
            droppedUploads.append((remoteDirectory, localPaths))
        }

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/srv/app")
        controller.performDropLocalFilesForTesting([
            "/Users/alice/build.zip"
        ])

        XCTAssertFalse(controller.canAcceptDroppedLocalFiles)
        XCTAssertTrue(droppedUploads.isEmpty)
    }

    func testRemoteTerminalTracksOSC7DirectoryUpdatesFromOutput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("\u{1B}]7;file://api.example.com/srv/releases/current\u{1B}\\".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/releases/current")
        XCTAssertEqual(changedDirectories, ["/srv/releases/current"])
    }

    func testRemoteTerminalTracksOSC7DirectoryUpdatesSplitAcrossOutputChunks() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("\u{1B}]7;file://api.example.com/srv/releases".utf8))
        XCTAssertEqual(controller.currentRemoteDirectory, "~")

        controller.feedRemoteOutput(Array("/current\u{1B}\\".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/releases/current")
        XCTAssertEqual(changedDirectories, ["/srv/releases/current"])
    }

    func testRemoteTerminalOSC7DirectoryUpdateHandlesVariableCdResult() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.sendInput(Array("cd $APP_HOME\n".utf8))
        XCTAssertEqual(controller.currentRemoteDirectory, "~")

        controller.feedRemoteOutput(Array("\u{1B}]7;file://api.example.com/opt/app\u{07}".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/opt/app")
        XCTAssertEqual(changedDirectories, ["/opt/app"])
    }

    func testRemoteTerminalFallsBackToCommandParserWhenOSC7StopsAfterInitialBashPrompt() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("\u{1B}]7;file://api.example.com/srv/app\u{07}".utf8))
        controller.sendInput(Array("cd /tmp\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/tmp")
        XCTAssertEqual(changedDirectories, ["/srv/app", "/tmp"])
    }

    func testRemoteTerminalOSC7CorrectsCommandParserFallbackWhenPromptReportsDifferentDirectory() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("\u{1B}]7;file://api.example.com/srv/app\u{07}".utf8))
        controller.sendInput(Array("cd ../loglink\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/loglink")
        XCTAssertEqual(changedDirectories, ["/srv/app", "/srv/loglink"])

        controller.feedRemoteOutput(Array("\u{1B}]7;file://api.example.com/tmp\u{07}".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/tmp")
        XCTAssertEqual(changedDirectories, ["/srv/app", "/srv/loglink", "/tmp"])
    }

    func testRemoteTerminalTracksCdCommandsAndNotifiesDirectoryChange() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/srv/app")
        controller.sendInput(Array("cd ../logs\n".utf8))
        controller.sendInput(Array("cd ".utf8))
        controller.sendInput(Array("'release notes'\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/logs/release notes")
        XCTAssertEqual(changedDirectories, ["/srv/app", "/srv/logs", "/srv/logs/release notes"])
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd ../logs\n".utf8)),
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd ".utf8)),
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("'release notes'\n".utf8))
        ])
    }

    func testRemoteTerminalFallsBackToCommandParserWhenOSC7IsAbsent() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.sendInput(Array("cd /var/log\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/var/log")
        XCTAssertEqual(changedDirectories, ["/var/log"])
    }

    func testRemoteTerminalRecognizesCentOSBracketPromptWhenDirectoryIsUnambiguous() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "root@centos",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("[root@centos /var/log]# ".utf8))
        controller.feedRemoteOutput(Array("[root@centos log]# ".utf8))
        controller.feedRemoteOutput(Array("[root@centos ~]# ".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "~")
        XCTAssertEqual(changedDirectories, ["/var/log", "~"])
    }

    func testRemoteTerminalRecognizesAnolisPromptFallbackWhenOSC7IsUnavailable() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "root@anolis",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("\u{1B}]0;root@anolis8:/opt/服务\u{07}\u{1B}[01;32m[root@anolis8 /opt/服务]\u{1B}[00m# ".utf8))
        controller.feedRemoteOutput(Array("\r\n[root@anolis8 ~/release]# ".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "~/release")
        XCTAssertEqual(changedDirectories, ["/opt/服务", "~/release"])
    }

    func testRemoteTerminalPromptFallbackRecognizesZshAndNetworkConsoleMarkers() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("deploy@example.com:/srv/zsh% ".utf8))
        controller.feedRemoteOutput(Array("admin@router:/cfg> ".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/cfg")
        XCTAssertEqual(changedDirectories, ["/srv/zsh", "/cfg"])
    }

    func testRemoteShellOSC7InjectionAppendsHooksWithoutPromptPollution() {
        let injection = TerminalOSC7ShellIntegration.remoteBootstrapScript()

        XCTAssertTrue(injection.contains("PROMPT_COMMAND="))
        XCTAssertTrue(injection.contains("precmd_functions+="))
        XCTAssertTrue(injection.contains("printf '\\033]7;file://%s%s\\033\\\\'"))
        XCTAssertFalse(injection.contains("fish_prompt"))
        XCTAssertFalse(injection.contains("PS1="))
        XCTAssertFalse(injection.contains("setopt promptsubst"))
        XCTAssertFalse(injection.contains("echo "))
        XCTAssertFalse(injection.contains("stty"))
    }

    func testRemoteOSC7InjectionIsBashParseableWithoutFunctionTrailingSemicolon() throws {
        let injection = TerminalOSC7ShellIntegration.remoteBootstrapScript()
        let quietInjection = TerminalOSC7ShellIntegration.quietRemoteBootstrapCommand()

        XCTAssertFalse(injection.contains("}; if [ -n \"${ZSH_VERSION:-}\" ]"))
        XCTAssertFalse(injection.contains("}; __stacio_report_cwd"))
        try assertBashAcceptsScript(injection)
        XCTAssertFalse(quietInjection.trimmingCharacters(in: .newlines).contains("\n"))
        XCTAssertTrue(quietInjection.contains("stty echo 2>/dev/null"))
        XCTAssertFalse(quietInjection.contains("stty -echo"))
        try assertBashAcceptsScript(quietInjection)
    }

    func testQuietRemoteOSC7BootstrapRestoresTTYEchoAfterBootstrapAndReport() throws {
        let quietInjection = TerminalOSC7ShellIntegration.quietRemoteBootstrapCommand()
        let restoreCommand = "stty echo 2>/dev/null || true"

        XCTAssertEqual(quietInjection.components(separatedBy: restoreCommand).count - 1, 2)
        let firstRestore = try XCTUnwrap(quietInjection.range(of: restoreCommand))
        let redirectedBootstrapEnd = try XCTUnwrap(quietInjection.range(of: "} >/dev/null 2>&1"))
        XCTAssertLessThan(firstRestore.lowerBound, redirectedBootstrapEnd.lowerBound)
        XCTAssertTrue(quietInjection.contains("__stacio_report_cwd 2>/dev/null || true; \(restoreCommand)"))
        XCTAssertTrue(quietInjection.hasSuffix("printf '\\r\\033[K'\n"))
        try assertBashAcceptsScript(quietInjection)
        try assertRemoteBootstrapShellAcceptsScript(executable: "/bin/sh", arguments: ["-n"], script: quietInjection)
    }

    func testRemoteOSC7InjectionIsParseableByPosixShellsBeforeRuntimeShellDetection() throws {
        let injection = TerminalOSC7ShellIntegration.remoteBootstrapScript()
        let quietInjection = TerminalOSC7ShellIntegration.quietRemoteBootstrapCommand()

        try assertRemoteBootstrapShellAcceptsScript(executable: "/bin/sh", arguments: ["-n"], script: injection)
        try assertRemoteBootstrapShellAcceptsScript(executable: "/bin/sh", arguments: ["-n"], script: quietInjection)
        try assertRemoteBootstrapShellAcceptsScriptIfPresent(
            executable: "/bin/dash",
            arguments: ["-n"],
            script: injection
        )
        try assertRemoteBootstrapShellAcceptsScriptIfPresent(
            executable: "/bin/dash",
            arguments: ["-n"],
            script: quietInjection
        )
    }

    func testRemoteTerminalDoesNotInjectOSC7BootstrapIntoVisibleSSHSession() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            bridge: RecordingRemoteTerminalBridge(outputBatches: [])
        )

        controller.loadView()
        controller.viewDidAppear()

        XCTAssertEqual(sink.inputEvents, [])
    }

    func testRemoteTerminalTracksSequentialRootHomeAndUserDirectoryChanges() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.sendInput(Array("cd /\n".utf8))
        controller.sendInput(Array("ls\n".utf8))
        controller.sendInput(Array("cd /home/\n".utf8))
        controller.sendInput(Array("ls\n".utf8))
        controller.sendInput(Array("cd FengLee/\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/home/FengLee")
        XCTAssertEqual(changedDirectories, ["/", "/home", "/home/FengLee"])
    }

    func testRemoteTerminalTracksPushdPopdAndChainedDirectoryCommands() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/srv/app")
        controller.sendInput(Array("pushd ../logs; ls -la\n".utf8))
        controller.sendInput(Array("cd releases && pwd\n".utf8))
        controller.sendInput(Array("cd -\n".utf8))
        controller.sendInput(Array("popd\n".utf8))
        controller.sendInput(Array("pushd\n".utf8))
        controller.sendInput(Array("popd\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/app")
        XCTAssertEqual(changedDirectories, [
            "/srv/app",
            "/srv/logs",
            "/srv/logs/releases",
            "/srv/logs",
            "/srv/app"
        ])
    }

    func testRemoteTerminalDoesNotGuessDirectoryFromTabCompletedCdInput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/")
        controller.sendInput(Array("cd /da\t\n".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/")
        XCTAssertEqual(changedDirectories, ["/"])
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("cd /da\t\n".utf8))
        ])
    }

    func testRemoteTerminalTracksPromptDirectoryAfterTabCompletedCdInput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "FengLee@FengStor",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.sendInput(Array("cd /\n".utf8))
        controller.sendInput(Array("cd /ho".utf8))
        controller.sendInput([9])
        controller.sendInput(Array("\n".utf8))
        controller.feedRemoteOutput(Array("FengLee@FengStor:/home$ ".utf8))
        controller.sendInput(Array("cd Feng".utf8))
        controller.sendInput([9])
        controller.sendInput(Array("\n".utf8))
        controller.feedRemoteOutput(Array("FengLee@FengStor:~$ ".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "~")
        XCTAssertEqual(changedDirectories, ["/", "/home", "~"])
    }

    func testRemoteTerminalPromptDirectoryTrackingIgnoresNonPromptOutputAndHandlesAnsiPrompt() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )
        var changedDirectories: [String] = []
        controller.onRemoteDirectoryChanged = { _, directory in
            changedDirectories.append(directory)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("deploy@example.com:/tmp is a log value\n".utf8))
        controller.feedRemoteOutput(Array("\u{1B}[32mdeploy@example.com:/var/log\u{1B}[0m$ ".utf8))

        XCTAssertEqual(controller.currentRemoteDirectory, "/var/log")
        XCTAssertEqual(changedDirectories, ["/var/log"])
    }

    func testRemoteTerminalShowsEnhancedCommandHintForTypedOpsCommandWithoutExtraInput() {
        let suiteName = "StacioRemoteCommandHint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.sendInput(Array("kubectl delete pod api-0 -n prod\n".utf8))

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("kubectl delete pod api-0 -n prod\n".utf8))
        ])
        XCTAssertEqual(controller.terminalOutputTranscript, "")
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：kubectl"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("delete"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("危险"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("kubectl delete pod api-0 -n prod"))
    }

    func testRemoteCommandHintDoesNotOverlapTerminalTextRegionWhenVisible() throws {
        let suiteName = "StacioRemoteCommandHintLayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        controller.sendInput(Array("kubectl delete pod api-0 -n prod\n".utf8))
        controller.view.layoutSubtreeIfNeeded()

        let overlay = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Terminal.commandHintOverlay")
        )
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(
            controller.terminalView.frame.intersects(overlay.frame),
            "Command hints must live outside the terminal text region so top rows stay readable."
        )
    }

    func testRemoteTerminalCommandHintKeepsQuotedFlagValuesWithoutExtraInput() {
        let suiteName = "StacioRemoteQuotedCommandHint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            settingsStore: settingsStore
        )

        controller.loadView()
        let command = #"docker run --name "api server" -v "/srv/app data:/app data" nginx:latest"#
        controller.sendInput(Array((command + "\n").utf8))

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array((command + "\n").utf8))
        ])
        XCTAssertEqual(controller.terminalOutputTranscript, "")
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：docker"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("参数：--name, -v"))
        XCTAssertFalse(controller.commandHintVisibleTextForTesting.contains("子命令：api"))
        XCTAssertFalse(controller.commandHintVisibleTextForTesting.contains("子命令：server"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains(command))
    }

    func testRemoteTerminalCompletesLinuxPackageManagerCommandWithTabWithoutForwardingRawTab() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "centos7.example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.sendInput(Array("dnf in".utf8))

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("dnf install"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("Tab"))

        controller.sendInput([9])

        XCTAssertEqual(sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) }, [
            "dnf in",
            "stall "
        ])
        XCTAssertFalse(sink.userInputEvents.contains { $0.bytes == [9] })
    }

    func testRemoteTerminalCompletesPathsWithoutSendingProbeCommandsToTTY() {
        let sink = RecordingRemoteTerminalEventSink()
        let provider = RecordingTerminalPathCompletionProvider(candidates: [
            TerminalPathCompletionCandidate(name: "app", isDirectory: true),
            TerminalPathCompletionCandidate(name: "api", isDirectory: true)
        ])
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false,
            pathCompletionProvider: provider
        )

        controller.loadView()
        controller.sendInput(Array("cd /srv/ap".utf8))

        XCTAssertEqual(provider.requests.last, TerminalPathCompletionRequest(parentPath: "/srv", namePrefix: "ap"))
        XCTAssertTrue(provider.requests.contains(TerminalPathCompletionRequest(parentPath: "/srv", namePrefix: "ap")))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("cd /srv/app/"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("目录"))

        controller.sendInput([9])

        XCTAssertEqual(
            sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) },
            [
                "cd /srv/ap",
                "p/"
            ]
        )
        XCTAssertFalse(sink.userInputEvents.contains { event in
            String(decoding: event.bytes, as: UTF8.self).contains("ls")
        })
        XCTAssertFalse(sink.userInputEvents.contains { $0.bytes == [9] })
    }

    func testRemoteTerminalCanNavigateAndAcceptCompletionCandidate() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        controller.view.layoutSubtreeIfNeeded()
        controller.feedRemoteOutput(Array("root@remote:~# ".utf8))
        controller.view.layoutSubtreeIfNeeded()
        controller.sendInput(Array("do".utf8))
        controller.sendInput([27, 91, 66])
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.commandHintCompletionChoiceCountForTesting, 2)
        XCTAssertEqual(controller.commandHintSelectedCompletionIndexForTesting, 1)
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("↵ Tab  docker-compose"))
        XCTAssertEqual(controller.commandHintPresentationKindForTesting, .completion)
        XCTAssertTrue(controller.commandHintUsesTerminalCompletionStyleForTesting)
        XCTAssertTrue(
            controller.terminalView.frame.intersects(controller.commandHintFrameForTesting),
            "Completion candidates should float over the terminal near the current prompt, not in the bottom command-hint area."
        )
        XCTAssertGreaterThanOrEqual(
            controller.commandHintFrameForTesting.minX,
            controller.terminalView.frame.minX + 24
        )

        controller.sendInput([9])

        XCTAssertEqual(sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) }, [
            "do",
            "cker-compose "
        ])
        XCTAssertFalse(sink.userInputEvents.contains { $0.bytes == [27, 91, 66] })
        XCTAssertFalse(sink.userInputEvents.contains { $0.bytes == [9] })
        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
    }

    func testRemoteTerminalKeepsTypedInputWhenPressingEnterWithCompletionVisible() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.sendInput(Array("do".utf8))
        controller.sendInput([27, 91, 66])
        controller.sendInput([13])

        XCTAssertEqual(sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) }, [
            "do",
            "\r"
        ])
    }

    func testRemoteTerminalEnterDoesNotAcceptHistoryCompletionForCdRoot() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.sendInput(Array("cd /home/\n".utf8))
        controller.sendInput(Array("cd /".utf8))

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("历史记录"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("cd /home/"))

        controller.sendInput([13])

        XCTAssertEqual(sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) }, [
            "cd /home/\n",
            "cd /",
            "\r"
        ])
    }

    func testRemoteTerminalShowsHistoryCommandCompletionBeforeBuiltIns() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.sendInput(Array("docker compose ps\n".utf8))
        controller.sendInput(Array("docker c".utf8))

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("历史记录"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("docker compose ps"))

        controller.sendInput([9])

        XCTAssertEqual(sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) }, [
            "docker compose ps\n",
            "docker c",
            "ompose ps"
        ])
        XCTAssertFalse(sink.userInputEvents.contains { $0.bytes == [9] })
    }

    func testRemoteTerminalNormalizesOSC7FileURLCurrentDirectoryUpdates() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(
            source: controller.terminalView,
            directory: "file://example.com/srv/Stacio%20Project"
        )

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/Stacio Project")
    }

    func testRemoteTerminalNormalizesUnescapedOSC7FileURLCurrentDirectoryUpdates() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(
            source: controller.terminalView,
            directory: "file://example.com/srv/Stacio Project"
        )

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/Stacio Project")
    }

    func testRemoteTerminalPreservesOSC7PathCharactersThatHaveURLMeaning() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(
            source: controller.terminalView,
            directory: "file://example.com/srv/build#1?draft"
        )

        XCTAssertEqual(controller.currentRemoteDirectory, "/srv/build#1?draft")
    }


    func testStartupBannerIsNotWrittenBeforeRemoteOutput() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startupBanner: "Stacio SSH session\n",
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.loadView()
        controller.feedRemoteOutput(Array("Linux prod 6.8\n".utf8))

        XCTAssertEqual(
            controller.terminalOutputTranscript,
            "Linux prod 6.8\n"
        )
    }

    func testSSHStartupBannerUsesSemanticANSIHighlightingAndClickableLinks() {
        let banner = SSHSessionStartupBanner(
            context: remoteLiveContext(host: "172.16.10.250"),
            title: "root@172.16.10.250",
            runtimeID: "term_ssh",
            initialRemotePath: "/root"
        ).rendered()

        XCTAssertTrue(banner.contains("Stacio SSH connected"))
        XCTAssertTrue(banner.contains("Host: deploy@172.16.10.250"))
        XCTAssertTrue(banner.contains("TERM=xterm-256color"))
        XCTAssertTrue(banner.contains("COLORTERM=truecolor"))
        XCTAssertTrue(banner.contains("Session: term_ssh"))
        XCTAssertTrue(banner.contains("Path: /root"))
        XCTAssertTrue(banner.contains("Docs: https://docs.stacio.app/terminal"))
        XCTAssertTrue(banner.contains("Try: pwd && uname -a"))
        XCTAssertFalse(banner.contains("\u{001B}["))
        XCTAssertFalse(banner.contains("\u{001B}]8;;"))
    }

    func testSSHStartupBannerSummarizesRemoteHighlightBootstrapWithoutDumpingShellCommand() {
        let banner = SSHSessionStartupBanner(
            context: remoteLiveContext(host: "centos7.example.com"),
            title: "root@centos7.example.com",
            runtimeID: "term_ssh",
            initialRemotePath: "/root"
        ).rendered()

        XCTAssertTrue(banner.contains("Highlight: "))
        XCTAssertTrue(banner.contains("ANSI colors ready"))
        XCTAssertFalse(banner.contains("export TERM=xterm-256color"))
        XCTAssertFalse(banner.contains("CLICOLOR_FORCE=1"))
        XCTAssertFalse(banner.contains("LS_COLORS="))
        XCTAssertFalse(banner.contains("Dockerfile=38;5;75"))
        XCTAssertFalse(banner.contains("docker-compose.yml=38;5;179"))
        XCTAssertFalse(banner.contains("alias ls='ls --color=auto'"))
    }

    func testResizeAndCloseAreForwardedToEventSink() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        controller.sizeChanged(source: controller.terminalView, newCols: 120, newRows: 40)
        controller.closeTerminal()

        let resizeDeadline = Date().addingTimeInterval(1)
        while sink.resizeEvents.contains(
            TerminalResizeEvent(runtimeID: "term_remote", cols: 120, rows: 40)
        ) == false, Date() < resizeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(sink.resizeEvents.contains(
            TerminalResizeEvent(runtimeID: "term_remote", cols: 120, rows: 40)
        ))
        XCTAssertEqual(sink.closedRuntimeIDs, ["term_remote"])
    }

    func testLateRuntimeAttachDoesNotReopenClosedPendingTerminal() {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_serial",
            title: "串口控制台",
            connectionKind: .serial,
            eventSink: sink,
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.displayConnectionStarting()
        controller.closeTerminal()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_serial", status: "running", diagnostic: "running")
        )

        XCTAssertEqual(controller.runtimeID, "pending_serial")
        XCTAssertEqual(controller.lifecycleState, RemoteTerminalLifecycleState.closed)
        XCTAssertEqual(bridge.closedRuntimeIDs, ["pending_serial", "term_serial"])
        XCTAssertEqual(sink.closedRuntimeIDs, ["pending_serial"])
    }

    func testFailedRuntimeAttachKeepsPendingTerminalDisconnected() {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_serial",
            title: "串口控制台",
            connectionKind: .serial,
            eventSink: sink,
            bridge: bridge,
            startsPollingAutomatically: false
        )
        var attachedRuntimeIDs: [String] = []
        controller.onRuntimeAttached = { _, status, _ in
            attachedRuntimeIDs.append(status.runtimeId)
        }

        controller.loadView()
        controller.displayConnectionStarting()
        controller.attachConnectedRuntime(
            status: LiveShellStatus(
                runtimeId: "term_serial_failed",
                status: "failed",
                diagnostic: "Device or resource busy /dev/cu.usbserial-001"
            )
        )
        controller.sendInput(Array("status\n".utf8))

        XCTAssertEqual(controller.runtimeID, "pending_serial")
        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertTrue(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_serial_failed"])
        XCTAssertEqual(sink.userInputEvents, [])
        XCTAssertEqual(attachedRuntimeIDs, [])
    }

    func testLateConnectionFailureDoesNotReopenClosedPendingTerminal() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_serial",
            title: "串口控制台",
            connectionKind: .serial,
            eventSink: sink,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.displayConnectionStarting()
        let transcriptBeforeClose = controller.terminalOutputTranscript
        controller.closeTerminal()
        controller.displayConnectionFailure("设备暂时不可用")

        XCTAssertEqual(controller.runtimeID, "pending_serial")
        XCTAssertEqual(controller.lifecycleState, RemoteTerminalLifecycleState.closed)
        XCTAssertEqual(controller.terminalOutputTranscript, transcriptBeforeClose)
        XCTAssertEqual(sink.closedRuntimeIDs, ["pending_serial"])
    }

    func testRemoteTerminalLoadViewDoesNotForwardInitialInvalidResizeToCoreSink() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: CoreBridgeTerminalEventSink(),
            startsPollingAutomatically: false
        )

        controller.loadView()

        XCTAssertTrue(controller.terminalView.superview === controller.view)
    }

    func testInvalidRemoteTerminalResizeIsIgnored() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        let resizeEventsBeforeInvalidResize = sink.resizeEvents
        controller.sizeChanged(source: controller.terminalView, newCols: -2, newRows: 3)
        controller.sizeChanged(source: controller.terminalView, newCols: 120, newRows: 0)

        XCTAssertEqual(sink.resizeEvents, resizeEventsBeforeInvalidResize)
    }

    func testRemoteTerminalControlScrollZoomsSharedFontSizeAndRelayoutsTerminal() {
        let suiteName = "StacioRemoteTerminalZoom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.terminalView.performControlScrollZoomForTesting(deltaY: -4)

        XCTAssertEqual(settingsStore.snapshot().terminalFontSize, 14)
        XCTAssertEqual(controller.terminalView.font.pointSize, 14, accuracy: 0.1)
        XCTAssertTrue(controller.terminalView.needsLayout)
    }

    func testPollerReadsStatusAndDrainsOutputWithoutDrivingLiveShellWorker() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data(Array("hello\n".utf8)),
                    droppedByteCount: 0
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()
        controller.closeTerminal()

        XCTAssertEqual(bridge.polledRuntimeIDs, ["term_remote"])
        XCTAssertEqual(bridge.outputRuntimeIDs, ["term_remote"])
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_remote"])
    }

    func testPollerIgnoresQueuedCallbackAfterTerminalCloses() {
        let bridge = RecordingRemoteTerminalBridge(
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data(Array("late output after close\n".utf8)),
                    droppedByteCount: 0
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.closeTerminal()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(bridge.polledRuntimeIDs, [])
        XCTAssertEqual(bridge.outputRuntimeIDs, [])
        XCTAssertFalse(controller.terminalOutputTranscript.contains("late output after close"))
        XCTAssertEqual(controller.lifecycleState, .closed)
    }

    func testPollerIgnoresStaleStatusAndOutputForPreviousRuntime() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_old", status: "closed", diagnostic: "Connection reset by peer")
            ],
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_old",
                    bytes: Data(Array("stale output from old runtime\n".utf8)),
                    droppedByteCount: 0
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_new",
            title: "deploy@example.com",
            eventSink: sink,
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(bridge.polledRuntimeIDs, ["term_new"])
        XCTAssertEqual(bridge.outputRuntimeIDs, [])
        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertFalse(controller.terminalOutputTranscript.contains("stale output"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.localizedCaseInsensitiveContains("Connection reset by peer"))
    }

    func testPollerKeepsRunningAfterTransientWouldBlockError() throws {
        let bridge = RecordingRemoteTerminalBridge(
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data(Array("after retry\n".utf8)),
                    droppedByteCount: 0
                )
            ],
            pollErrors: [
                SshRuntimeError.Transport(message: "[Session(-37)] Would block"),
                nil
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertEqual(bridge.polledRuntimeIDs, ["term_remote", "term_remote"])
        XCTAssertEqual(bridge.outputRuntimeIDs, ["term_remote"])
        XCTAssertTrue(controller.terminalOutputTranscript.contains("after retry"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("SSH 通道暂时不可用"))
    }

    func testDisconnectedRemoteTerminalCanReconnectToNewRuntime() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_old", status: "closed", diagnostic: "Connection reset by peer")
            ],
            outputBatches: []
        )
        let reconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_new", status: "running", diagnostic: "running")
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_old",
            title: "deploy@example.com",
            eventSink: sink,
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        var attachedRuntimeIDs: [String] = []
        var reattachedRuntimeIDs: [(oldRuntimeID: String, newRuntimeID: String)] = []
        controller.onRuntimeAttached = { _, status, _ in
            attachedRuntimeIDs.append(status.runtimeId)
        }
        controller.onRuntimeReattached = { _, oldRuntimeID, status, _ in
            reattachedRuntimeIDs.append((oldRuntimeID, status.runtimeId))
        }

        controller.loadView()
        controller.pollRemoteOutputOnce()
        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "已断开：连接被远端重置")
        XCTAssertFalse(controller.lifecycleMessageForTesting.localizedCaseInsensitiveContains("Connection reset by peer"))

        let status = try controller.reconnectTerminal()
        controller.sendInput(Array("pwd\n".utf8))

        XCTAssertEqual(status.runtimeId, "term_new")
        XCTAssertEqual(controller.runtimeID, "term_new")
        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_old"])
        XCTAssertEqual(reconnecter.reconnectedTitles, ["deploy@example.com"])
        XCTAssertEqual(attachedRuntimeIDs, ["term_new"])
        XCTAssertEqual(reattachedRuntimeIDs.map(\.oldRuntimeID), ["term_old"])
        XCTAssertEqual(reattachedRuntimeIDs.map(\.newRuntimeID), ["term_new"])
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_new", bytes: Array("pwd\n".utf8))
        ])
    }

    func testAutomaticallyPolledSSHSessionRunsFirstAutomaticReconnectImmediately() throws {
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let reconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_auto", status: "running", diagnostic: "running")
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_old",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: true
        )
        var reattachedRuntimeIDs: [String] = []
        controller.onRuntimeReattached = { _, _, status, _ in
            reattachedRuntimeIDs.append(status.runtimeId)
        }

        controller.loadView()
        controller.displayConnectionFailure("连接超时")
        let deadline = Date().addingTimeInterval(0.3)
        while controller.runtimeID != "term_auto" && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(controller.runtimeID, "term_auto")
        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertEqual(reconnecter.reconnectedTitles, ["deploy@example.com"])
        XCTAssertEqual(reattachedRuntimeIDs, ["term_auto"])
    }

    func testBackgroundReconnectCoalescesRapidRequestsAndAttachesLatestResult() throws {
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let reconnecter = ControlledBackgroundRemoteTerminalReconnecter()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_old",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.displayConnectionFailure("连接超时")

        _ = try controller.reconnectTerminal()
        _ = try controller.reconnectTerminal()
        let registrationDeadline = Date().addingTimeInterval(1)
        while reconnecter.pendingCompletionCount != 1, Date() < registrationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(reconnecter.pendingCompletionCount, 1)

        reconnecter.complete(
            at: 0,
            with: .success(LiveShellStatus(runtimeId: "term_latest", status: "running", diagnostic: "running"))
        )
        XCTAssertEqual(controller.runtimeID, "term_latest")
        XCTAssertEqual(controller.lifecycleState, .running)
    }

    func testClosingTerminalCancelsPendingReconnectAndClosesLateRuntime() throws {
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let reconnecter = ControlledBackgroundRemoteTerminalReconnecter()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_old",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.displayConnectionFailure("连接超时")
        _ = try controller.reconnectTerminal()
        let registrationDeadline = Date().addingTimeInterval(1)
        while reconnecter.pendingCompletionCount != 1, Date() < registrationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(reconnecter.pendingCompletionCount, 1)

        controller.closeTerminal()
        reconnecter.complete(
            at: 0,
            with: .success(LiveShellStatus(runtimeId: "term_after_close", status: "running", diagnostic: "running"))
        )

        XCTAssertEqual(reconnecter.cancelCount, 1)
        XCTAssertEqual(controller.lifecycleState, .closed)
        XCTAssertTrue(bridge.closedRuntimeIDs.contains("term_after_close"))
    }

    func testDisconnectedRemoteTerminalRejectsFailedReconnectStatusWithoutReplacingRuntime() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let reconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(
                runtimeId: "term_reconnect_failed",
                status: "failed",
                diagnostic: "Device or resource busy /dev/cu.usbserial-001"
            )
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_old",
            title: "串口控制台",
            connectionKind: .serial,
            eventSink: sink,
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        var attachedRuntimeIDs: [String] = []
        var reattachedRuntimeIDs: [String] = []
        controller.onRuntimeAttached = { _, status, _ in
            attachedRuntimeIDs.append(status.runtimeId)
        }
        controller.onRuntimeReattached = { _, _, status, _ in
            reattachedRuntimeIDs.append(status.runtimeId)
        }

        controller.loadView()
        controller.displayConnectionFailure("设备暂时不可用")

        XCTAssertThrowsError(try controller.reconnectTerminal())
        controller.sendInput(Array("status\n".utf8))

        XCTAssertEqual(controller.runtimeID, "term_old")
        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertTrue(controller.terminalOutputTranscript.contains("设备正忙"))
        XCTAssertEqual(controller.terminalOutputTranscript.components(separatedBy: "设备正忙").count - 1, 1)
        XCTAssertEqual(bridge.closedRuntimeIDs, ["term_old", "term_reconnect_failed"])
        XCTAssertEqual(attachedRuntimeIDs, [])
        XCTAssertEqual(reattachedRuntimeIDs, [])
        XCTAssertEqual(sink.userInputEvents, [])
    }

    func testStoppedSSHSessionPromptClearsAfterSuccessfulReconnectAndRRestartsSession() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let reconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_restarted", status: "running", diagnostic: "running")
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_failed",
            title: "deploy@example.com",
            eventSink: sink,
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.displayConnectionFailure("连接超时")
        XCTAssertTrue(controller.terminalOutputTranscript.contains("连接失败：连接超时"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("按 <回车> 关闭标签页"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("按 R 重新连接会话"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("按 S 保存终端输出到文件"))

        controller.send(source: controller.terminalView, data: ArraySlice(Array("r".utf8)))
        controller.sendInput(Array("uptime\n".utf8))

        XCTAssertFalse(controller.terminalOutputTranscript.contains("连接失败：连接超时"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("按 <回车> 关闭标签页"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("按 R 重新连接会话"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("按 S 保存终端输出到文件"))
        XCTAssertEqual(controller.runtimeID, "term_restarted")
        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertEqual(reconnecter.reconnectedTitles, ["deploy@example.com"])
        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_restarted", bytes: Array("uptime\n".utf8))
        ])
    }

    func testInitialSSHConnectionFailureShowsCurrentFailureWithoutStoppedTranscript() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_ssh",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 960, height: 480)
        controller.view.layoutSubtreeIfNeeded()
        controller.displayConnectionStarting()
        controller.displayConnectionFailure("SSH 无法到达主机 (os error 65)")

        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "连接失败：无法到达主机")
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("os error 65"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("SSH 无法到达主机"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("按 R 重新连接会话"))

        controller.displayConnectionFailure("SSH 连接超时")

        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "连接失败：SSH 连接超时")
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertTrue(controller.lifecycleMessageForTesting.contains("SSH 连接超时"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("SSH 连接超时"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertFalse(controller.terminalDisplaySnapshotForTesting.contains("会话已停止"))

        controller.attachConnectedRuntime(
            status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
        )
        controller.feedRemoteOutput(Array("Linux FengStor 6.1\nFengLee@FengStor:~$ ".utf8))

        XCTAssertEqual(controller.runtimeID, "term_live")
        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertFalse(controller.terminalOutputTranscript.contains("SSH 无法到达主机"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertFalse(controller.terminalDisplaySnapshotForTesting.contains("SSH 无法到达主机"))
        XCTAssertFalse(controller.terminalDisplaySnapshotForTesting.contains("会话已停止"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("FengLee@FengStor:~$ "))
    }

    func testAutomaticallyPolledInitialSSHFailureRunsAutomaticReconnectImmediately() throws {
        let reconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_auto_initial", status: "running", diagnostic: "running")
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_ssh_auto",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            reconnecter: reconnecter,
            startsPollingAutomatically: true
        )
        var attachedRuntimeIDs: [String] = []
        controller.onRuntimeAttached = { _, status, _ in
            attachedRuntimeIDs.append(status.runtimeId)
        }

        controller.loadView()
        controller.displayConnectionStarting()
        controller.displayConnectionFailure("SSH 无法到达主机 (os error 65)")

        let deadline = Date().addingTimeInterval(0.3)
        while controller.runtimeID != "term_auto_initial" && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(controller.runtimeID, "term_auto_initial")
        XCTAssertEqual(controller.lifecycleState, .running)
        XCTAssertEqual(reconnecter.reconnectedTitles, ["deploy@example.com"])
        XCTAssertEqual(attachedRuntimeIDs, ["term_auto_initial"])
        XCTAssertFalse(controller.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("os error 65"))
    }

    func testStartingNewInitialSSHAttemptClearsStaleFailureBanner() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_ssh_retry",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            reconnecter: RecordingRemoteTerminalReconnecter(
                status: LiveShellStatus(runtimeId: "term_retry", status: "running", diagnostic: "running")
            ),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 960, height: 480)
        controller.view.layoutSubtreeIfNeeded()
        controller.displayConnectionFailure("SSH 无法到达主机 (os error 65)")

        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "连接失败：无法到达主机")
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("os error 65"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))

        controller.displayConnectionStarting()

        XCTAssertEqual(controller.lifecycleState, .connecting)
        XCTAssertEqual(controller.lifecycleMessageForTesting, L10n.TerminalLifecycle.connecting)
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("os error 65"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("SSH 无法到达主机"))
        XCTAssertFalse(controller.terminalDisplaySnapshotForTesting.contains("SSH 无法到达主机"))
    }

    func testPendingSSHConnectingLifecycleStaysVisibleWhenViewLoadsAfterStateChange() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "pending_ssh_preload",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )

        controller.displayConnectionStarting()
        controller.loadView()

        XCTAssertEqual(controller.lifecycleState, .connecting)
        XCTAssertEqual(controller.lifecycleMessageForTesting, L10n.TerminalLifecycle.connecting)
        XCTAssertTrue(controller.isLifecycleBarVisibleForTesting)
    }

    func testStoppedSSHSessionEnterRequestsTabCloseInsteadOfClosingSerialSessions() {
        let sshController = RemoteTerminalPaneViewController(
            runtimeID: "term_ssh_failed",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )
        var sshCloseRequests = 0
        sshController.onRequestClose = { _ in sshCloseRequests += 1 }
        sshController.loadView()
        sshController.displayConnectionFailure("认证失败")

        sshController.send(source: sshController.terminalView, data: ArraySlice(Array("\n".utf8)))

        XCTAssertEqual(sshCloseRequests, 1)

        let serialReconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_serial_recovered", status: "running", diagnostic: "running")
        )
        let serialController = RemoteTerminalPaneViewController(
            runtimeID: "term_serial_failed",
            title: "串口控制台",
            connectionKind: .serial,
            eventSink: RecordingRemoteTerminalEventSink(),
            reconnecter: serialReconnecter,
            startsPollingAutomatically: false
        )
        var serialCloseRequests = 0
        serialController.onRequestClose = { _ in serialCloseRequests += 1 }
        serialController.loadView()
        serialController.displayConnectionFailure("设备暂时不可用")

        serialController.send(source: serialController.terminalView, data: ArraySlice(Array("\r".utf8)))

        XCTAssertEqual(serialCloseRequests, 0)
        XCTAssertEqual(serialReconnecter.reconnectedTitles, ["串口控制台"])
        XCTAssertEqual(serialController.runtimeID, "term_serial_recovered")
        XCTAssertEqual(serialController.lifecycleState, .running)
    }

    func testReconnectUpdatesLiveContextWithoutWritingStartupSummary() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let reconnecter = RecordingRemoteTerminalReconnecter(
            status: LiveShellStatus(runtimeId: "term_new", status: "running", diagnostic: "running"),
            liveSessionContext: remoteLiveContext(host: "new.example.com")
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_old",
            title: "deploy@example.com",
            liveSessionContext: remoteLiveContext(host: "old.example.com"),
            eventSink: sink,
            startupBanner: "old startup\n",
            bridge: bridge,
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )

        controller.loadView()
        try controller.reconnectTerminal()

        XCTAssertEqual(controller.terminalOutputTranscript, "")
        XCTAssertFalse(controller.terminalOutputTranscript.contains("old startup\n"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("Host: deploy@new.example.com\r\n"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("Stacio SSH connected"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("TERM=xterm-256color  COLORTERM=truecolor"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("Docs: https://docs.stacio.app/terminal"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("\u{001B}["))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("\u{001B}]8;;"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("Runtime: term_new"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("目标: deploy@new.example.com"))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("接下来显示服务器登录输出"))
        XCTAssertEqual(controller.liveSessionContext?.config.host, "new.example.com")
    }

    func testRuntimeIoFailureShowsChineseDiagnostic() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(
                    runtimeId: "term_serial",
                    status: "closed",
                    diagnostic: "Terminal runtime I/O error: Input/output error"
                )
            ],
            outputBatches: []
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_serial",
            title: "串口控制台",
            eventSink: sink,
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "已断开：终端读写失败：设备输入输出错误")
        XCTAssertFalse(controller.lifecycleMessageForTesting.localizedCaseInsensitiveContains("Terminal runtime I/O error"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.localizedCaseInsensitiveContains("Input/output error"))
    }

    func testThrownTerminalRuntimeErrorShowsChineseDiagnostic() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let bridge = RecordingRemoteTerminalBridge(
            outputBatches: [],
            pollError: TerminalRuntimeError.RuntimeClosed(runtimeId: "term_serial")
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_serial",
            title: "串口控制台",
            eventSink: sink,
            bridge: bridge,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(controller.lifecycleState, .disconnected)
        XCTAssertEqual(controller.lifecycleMessageForTesting, "已断开：终端会话已关闭")
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("StacioCoreBindings"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("TerminalRuntimeError"))
        XCTAssertFalse(controller.lifecycleMessageForTesting.contains("RuntimeClosed"))
    }

    func testRemoteTerminalSupportsFindCopyPasteCommands() {
        let sink = RecordingRemoteTerminalEventSink()
        let suiteName = "StacioRemoteTerminalPaste-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalMultiLinePasteConfirmationEnabled = false
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.feedRemoteOutput(Array("alpha beta gamma\r\n".utf8))
        NSPasteboard.general.clearContents()

        XCTAssertTrue(controller.find("beta"))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")

        controller.copySelection()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("whoami\n", forType: .string)
        controller.pasteClipboard()

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("whoami\n".utf8))
        ])
    }

    func testRemoteTerminalAppliesLineNumberAndTimestampGutterSettings() {
        let suiteName = "StacioRemoteTerminalGutter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalLineNumbersEnabled = true
            settings.terminalTimestampsEnabled = true
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.setFrameSize(NSSize(width: 900, height: 520))
        controller.terminalView.setFrameSize(NSSize(width: 740, height: 420))
        XCTAssertEqual(controller.lineInfoGutterVisibleTextForTesting, "")
        controller.feedRemoteOutput(Array("ready\r\nbravo\r\nroot@host:~# ".utf8))

        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("["))
        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("  1"))
        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("  3"))
        XCTAssertFalse(controller.lineInfoGutterVisibleTextForTesting.contains(" 24"))
        XCTAssertTrue(controller.lineInfoGutterUsesTerminalSurfaceStyleForTesting)
        XCTAssertEqual(controller.lineInfoGutterFontPointSizeForTesting, CGFloat(settingsStore.snapshot().terminalFontSize))
        XCTAssertEqual(controller.lineInfoGutterLabelCountForTesting, 3)
        XCTAssertEqual(controller.lineInfoGutterRowHeightForTesting, controller.terminalView.caretFrame.size.height, accuracy: 0.1)
        XCTAssertGreaterThan(controller.lineInfoGutterPreferredWidthForTesting, 110)
        XCTAssertLessThan(controller.lineInfoGutterPreferredWidthForTesting, 150)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.lineInfoGutter"))
    }

    func testRemoteTerminalSyncsConfiguredKeepaliveInterval() {
        let suiteName = "StacioRemoteKeepalive-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalKeepAliveIntervalSeconds = 15
        }
        let bridge = RecordingRemoteTerminalBridge(outputBatches: [])
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        settingsStore.update { settings in
            settings.terminalKeepAliveIntervalSeconds = 0
        }

        XCTAssertEqual(bridge.keepaliveEvents, [
            KeepaliveIntervalEvent(runtimeID: "term_remote", seconds: 15),
            KeepaliveIntervalEvent(runtimeID: "term_remote", seconds: 0)
        ])
    }

    func testRemoteTerminalSearchBarShowsCountsNavigatesAndEscRestoresFocus() throws {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote_search",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.feedRemoteOutput(Array("alpha beta\r\nBETA beta\r\n".utf8))

        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.terminalView)

        XCTAssertFalse(controller.terminalSearchBarVisibleForTesting)

        controller.showFind()
        XCTAssertTrue(controller.terminalSearchBarVisibleForTesting)
        let searchBar = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Terminal.searchBar") as? TerminalSearchBarView
        )
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.searchField"))

        controller.setTerminalSearchQueryForTesting("beta")

        XCTAssertEqual(controller.terminalSearchSummaryForTesting, "第 1 / 共 3 个")
        XCTAssertEqual(controller.terminalSearchVisibleHighlightCountForTesting, 3)
        XCTAssertEqual(controller.terminalView.getSelection()?.lowercased(), "beta")

        controller.selectNextTerminalSearchMatchForTesting()
        XCTAssertEqual(controller.terminalSearchSummaryForTesting, "第 2 / 共 3 个")
        XCTAssertEqual(controller.terminalView.getSelection()?.lowercased(), "beta")

        controller.selectPreviousTerminalSearchMatchForTesting()
        XCTAssertEqual(controller.terminalSearchSummaryForTesting, "第 1 / 共 3 个")

        XCTAssertTrue(searchBar.control(
            NSSearchField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))

        XCTAssertFalse(controller.terminalSearchBarVisibleForTesting)
        XCTAssertFalse(controller.terminalView.selectionActive)
        XCTAssertIdentical(window.firstResponder as AnyObject?, controller.terminalView)
    }

    func testRemoteTerminalReportsSubmittedCommandsAfterInputIsAccepted() {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )
        var submittedCommands: [(runtimeID: String, command: String)] = []
        controller.onCommandSubmitted = { pane, command in
            submittedCommands.append((pane.runtimeID, command))
        }

        controller.loadView()
        controller.send(source: controller.terminalView, data: ArraySlice(Array("  docker ps  \n".utf8)))
        controller.send(source: controller.terminalView, data: ArraySlice(Array("   \n".utf8)))

        XCTAssertEqual(sink.userInputEvents.map { String(decoding: $0.bytes, as: UTF8.self) }, [
            "  docker ps  \n",
            "   \n"
        ])
        XCTAssertEqual(submittedCommands.map(\.runtimeID), ["term_remote"])
        XCTAssertEqual(submittedCommands.map(\.command), ["docker ps"])
    }

    func testRemoteTerminalReportsSubmittedCommandsAfterShellTabCompletion() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )
        var submittedCommands: [String] = []
        controller.onCommandSubmitted = { _, command in
            submittedCommands.append(command)
        }

        controller.loadView()
        controller.send(source: controller.terminalView, data: ArraySlice(Array("cd /da".utf8)))
        controller.send(source: controller.terminalView, data: ArraySlice([9]))
        controller.send(source: controller.terminalView, data: ArraySlice(Array("\n".utf8)))

        XCTAssertEqual(submittedCommands, ["cd /da"])
    }

    func testRemoteTerminalReportsCommandCompletionFromPromptOutput() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            startsPollingAutomatically: false
        )
        var completedRuntimeIDs: [String] = []
        var broadcastKinds: [TerminalBroadcastEventKind] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: "term_remote") { event in
            broadcastKinds.append(event.kind)
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: "term_remote", subscription: subscription)
        }
        controller.onCommandFinished = { pane in
            completedRuntimeIDs.append(pane.runtimeID)
        }

        controller.loadView()
        controller.feedRemoteOutput(Array("deploy@host:/srv/app$ ".utf8))

        XCTAssertEqual(completedRuntimeIDs, ["term_remote"])
        XCTAssertEqual(broadcastKinds, [.output, .commandFinished])
    }

    func testRemoteTerminalCommandClickLinkRequestsBrowserOpen() {
        let opener = RecordingTerminalLinkOpener()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            linkOpener: opener,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.requestOpenLink(
            source: controller.terminalView,
            link: "https://docs.ubuntu.com",
            params: [:]
        )

        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), ["https://docs.ubuntu.com"])
    }

    func testRemoteTerminalCommandClickNormalizesBareIPAddressLinks() {
        let opener = RecordingTerminalLinkOpener()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            linkOpener: opener,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.requestOpenLink(
            source: controller.terminalView,
            link: "192.168.8.10:9090/status.",
            params: [:]
        )

        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), ["http://192.168.8.10:9090/status"])
    }

    func testRemoteTerminalCommandClickPathCopiesWithoutSendingInputOrOpeningBrowser() {
        let opener = RecordingTerminalLinkOpener()
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink,
            linkOpener: opener,
            startsPollingAutomatically: false
        )

        controller.loadView()
        NSPasteboard.general.clearContents()
        controller.requestOpenLink(
            source: controller.terminalView,
            link: "/var/log/nginx/error.log",
            params: [:]
        )

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/var/log/nginx/error.log")
        XCTAssertEqual(opener.openedURLs, [])
        XCTAssertEqual(sink.userInputEvents, [])
    }

    func testRemoteTerminalCommandClickBareIPAddressInBufferRequestsBrowserOpen() {
        let terminalView = StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 480))
        let delegate = RecordingTerminalViewLinkDelegate()
        terminalView.terminalDelegate = delegate
        terminalView.terminal.resize(cols: 80, rows: 25)
        terminalView.feedRemoteOutput(Array("open 192.168.8.10:9090/status\r\n".utf8))
        let frame = NSRect(origin: .zero, size: terminalView.getOptimalFrameSize().size)
        terminalView.frame = frame

        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(terminalView)

        let hoverEvent = terminalMouseEvent(
            type: .mouseMoved,
            row: 0,
            col: 8,
            in: terminalView,
            modifierFlags: .command
        )
        let normalHoverEvent = terminalMouseEvent(
            type: .mouseMoved,
            row: 0,
            col: 8,
            in: terminalView,
            modifierFlags: []
        )
        XCTAssertEqual(TerminalLinkInteraction.cursorStyle(in: terminalView, event: hoverEvent), .link)
        XCTAssertEqual(TerminalLinkInteraction.cursorStyle(in: terminalView, event: normalHoverEvent), .text)

        let event = terminalMouseEvent(
            type: .leftMouseUp,
            row: 0,
            col: 8,
            in: terminalView,
            modifierFlags: .command
        )
        XCTAssertNil(TerminalLinkInteraction.handleEvent(in: terminalView, event: event))

        XCTAssertEqual(delegate.openedLinks, ["192.168.8.10:9090/status"])
    }

    func testRemoteTerminalCommandClickPathInBufferRequestsSafePathAction() {
        let terminalView = StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 480))
        let delegate = RecordingTerminalViewLinkDelegate()
        terminalView.terminalDelegate = delegate
        terminalView.terminal.resize(cols: 80, rows: 25)
        terminalView.feedRemoteOutput(Array("tail /var/log/nginx/error.log\r\n".utf8))
        let frame = NSRect(origin: .zero, size: terminalView.getOptimalFrameSize().size)
        terminalView.frame = frame

        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(terminalView)

        let hoverEvent = terminalMouseEvent(
            type: .mouseMoved,
            row: 0,
            col: 8,
            in: terminalView,
            modifierFlags: .command
        )
        XCTAssertEqual(TerminalLinkInteraction.cursorStyle(in: terminalView, event: hoverEvent), .link)

        let event = terminalMouseEvent(
            type: .leftMouseUp,
            row: 0,
            col: 8,
            in: terminalView,
            modifierFlags: .command
        )
        XCTAssertNil(TerminalLinkInteraction.handleEvent(in: terminalView, event: event))

        XCTAssertEqual(delegate.openedLinks, ["/var/log/nginx/error.log"])
    }

    func testRemoteTerminalRichHighlightingStaysOnDisplayBranchOnly() {
        let suiteName = "StacioRemoteRichHighlightSplit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
            settings.terminalRichHighlightingEnabled = true
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "tokyo-night"
        }
        let runtimeID = "term_remote_split_\(UUID().uuidString)"
        var broadcastBytes: [[UInt8]] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: runtimeID) { event in
            if event.kind == .output {
                broadcastBytes.append(event.bytes)
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: runtimeID,
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )
        let raw = "ERROR status=1 192.168.8.10:8080 /var/log/app.log\n"

        controller.loadView()
        controller.feedRemoteOutput(Array(raw.utf8))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(controller.find("ERROR"))
        controller.copySelection()

        XCTAssertEqual(controller.terminalOutputTranscript, raw)
        XCTAssertEqual(broadcastBytes, [Array(raw.utf8)])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ERROR")
        XCTAssertFalse(controller.terminalOutputTranscript.contains("\u{001B}["))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("\u{001B}]8;;"))
    }

    func testRemoteTerminalSkipsRichHighlightingDuringOutputProtection() {
        let suiteName = "StacioRemoteProtectionHighlight-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
            settings.terminalRichHighlightingEnabled = true
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "tokyo-night"
        }
        let raw = "ERROR status=1 192.168.8.10:8080 /var/log/app.log\n"
        let bridge = RecordingRemoteTerminalBridge(
            statuses: [
                LiveShellStatus(runtimeId: "term_remote", status: "running", diagnostic: "")
            ],
            outputBatches: [
                TerminalOutputBatch(
                    runtimeId: "term_remote",
                    bytes: Data(raw.utf8),
                    droppedByteCount: 42,
                    protectionActive: true,
                    bufferedByteCount: UInt32(raw.utf8.count)
                )
            ]
        )
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            bridge: bridge,
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.pollRemoteOutputOnce()

        XCTAssertEqual(controller.terminalOutputTranscript, raw)
        XCTAssertFalse(controller.terminalLastFeedAppliedSemanticHighlightingForTesting)
    }

    func testRemoteTerminalSystemThemeRefreshesNativeColorsWhenEffectiveAppearanceChanges() {
        let suiteName = "StacioRemoteTerminalSystemAppearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .system
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink(),
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.terminalView.nativeForegroundColor = .systemRed
        controller.terminalView.nativeBackgroundColor = .systemBlue
        controller.terminalView.caretColor = .systemGreen
        controller.terminalView.selectedTextBackgroundColor = .systemYellow
        controller.view.viewDidChangeEffectiveAppearance()

        assertTerminalUsesSystemAdaptiveColors(controller.terminalView)
    }

    func testRemoteTerminalContextMenuContainsPasteAndAskAI() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink()
        )

        controller.loadView()
        let menu = controller.terminalContextMenuForTesting(selectedText: "error line")

        XCTAssertEqual(menu.items.map(\.title), ["粘贴", "询问 AI", "解释选中内容"])
    }

    func testRemoteTerminalContextMenuPasteItemPastesClipboard() throws {
        let sink = RecordingRemoteTerminalEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: sink
        )

        controller.loadView()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("date", forType: .string)

        let menu = controller.terminalContextMenuForTesting(selectedText: nil)
        let pasteItem = try XCTUnwrap(menu.items.first { $0.title == "粘贴" })
        let action = try XCTUnwrap(pasteItem.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: pasteItem.target, from: pasteItem))

        XCTAssertEqual(sink.userInputEvents, [
            TerminalInputEvent(runtimeID: "term_remote", bytes: Array("date".utf8))
        ])
    }

    func testMouseHitInsideRemoteTerminalRestoresKeyboardFocus() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote",
            title: "deploy@example.com",
            eventSink: RecordingRemoteTerminalEventSink()
        )
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(window.contentView)

        let hitView = controller.view.hitTest(NSPoint(x: 4, y: 4))

        XCTAssertIdentical(hitView, controller.terminalView)
        XCTAssertIdentical(window.firstResponder as AnyObject, controller.terminalView)
    }
}

private final class RecordingTerminalViewLinkDelegate: TerminalViewDelegate {
    private(set) var openedLinks: [String] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLinks.append(link)
    }
}

private func assertTerminalUsesSystemAdaptiveColors(
    _ terminalView: TerminalView,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        terminalView.nativeForegroundColor,
        StacioDesignSystem.resolvedColor(.textColor, for: terminalView),
        file: file,
        line: line
    )
    XCTAssertEqual(
        terminalView.nativeBackgroundColor,
        StacioDesignSystem.resolvedColor(.textBackgroundColor, for: terminalView),
        file: file,
        line: line
    )
    XCTAssertEqual(
        terminalView.caretColor,
        StacioDesignSystem.resolvedColor(.textColor, for: terminalView),
        file: file,
        line: line
    )
    XCTAssertEqual(
        terminalView.selectedTextBackgroundColor,
        StacioDesignSystem.resolvedColor(.selectedTextBackgroundColor, for: terminalView),
        file: file,
        line: line
    )
}

private func terminalMouseEvent(
    type: NSEvent.EventType,
    row: Int,
    col: Int,
    in terminalView: TerminalView,
    modifierFlags: NSEvent.ModifierFlags
) -> NSEvent {
    let cols = max(terminalView.terminal.cols, 1)
    let rows = max(terminalView.terminal.rows, 1)
    let cellWidth = terminalView.bounds.width / CGFloat(cols)
    let cellHeight = terminalView.bounds.height / CGFloat(rows)
    let point = NSPoint(
        x: (CGFloat(col) + 0.5) * cellWidth,
        y: terminalView.bounds.height - ((CGFloat(row) + 0.5) * cellHeight)
    )
    return NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: terminalView.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )!
}

private final class RecordingRemoteTerminalEventSink: TerminalEventSink {
    private(set) var resizeEvents: [TerminalResizeEvent] = []
    private(set) var inputEvents: [TerminalInputEvent] = []
    private(set) var closedRuntimeIDs: [String] = []
    var inputError: Error?
    var onInput: ((TerminalInputEvent) -> Void)?

    var userInputEvents: [TerminalInputEvent] {
        inputEvents.filter { event in
            String(decoding: event.bytes, as: UTF8.self).contains("__stacio_report_cwd") == false
        }
    }

    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {
        resizeEvents.append(TerminalResizeEvent(runtimeID: runtimeID, cols: cols, rows: rows))
    }

    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}

    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {
        if let inputError {
            throw inputError
        }
        inputEvents.append(TerminalInputEvent(runtimeID: runtimeID, bytes: bytes))
        onInput?(inputEvents[inputEvents.count - 1])
    }

    func terminalDidClose(runtimeID: String) throws {
        closedRuntimeIDs.append(runtimeID)
    }
}

@MainActor
private final class SingleRemoteTerminalResolver: AgentTerminalResolving {
    let target: AgentTerminalTarget

    init(target: AgentTerminalTarget) {
        self.target = target
    }

    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        self.target
    }
}

@MainActor
private final class AllowingRemoteTerminalAuthorizer: AgentActionAuthorizing {
    func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        false
    }

    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "test",
            risk: .readOnly,
            requiredUserConfirmation: false
        )
    }
}

private final class WeakReference<T: AnyObject> {
    weak var value: T?

    init(_ value: T?) {
        self.value = value
    }
}

private final class RecordingRemoteTerminalBridge: RemoteTerminalBridging {
    private(set) var polledRuntimeIDs: [String] = []
    private(set) var outputRuntimeIDs: [String] = []
    private(set) var closedRuntimeIDs: [String] = []
    private(set) var outputPauseEvents: [OutputPauseEvent] = []
    private(set) var keepaliveEvents: [KeepaliveIntervalEvent] = []
    private var statuses: [LiveShellStatus]
    private var outputBatches: [TerminalOutputBatch]
    private var pollError: Error?
    private var pollErrors: [Error?]

    init(
        statuses: [LiveShellStatus] = [],
        outputBatches: [TerminalOutputBatch],
        pollError: Error? = nil,
        pollErrors: [Error?] = []
    ) {
        self.statuses = statuses
        self.outputBatches = outputBatches
        self.pollError = pollError
        self.pollErrors = pollErrors
    }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        polledRuntimeIDs.append(runtimeID)
        if !pollErrors.isEmpty,
           let nextPollError = pollErrors.removeFirst()
        {
            throw nextPollError
        }
        if let pollError {
            throw pollError
        }
        return statuses.isEmpty
            ? LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
            : statuses.removeFirst()
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        outputRuntimeIDs.append(runtimeID)
        return outputBatches.isEmpty
            ? TerminalOutputBatch(runtimeId: runtimeID, bytes: Data(), droppedByteCount: 0)
            : outputBatches.removeFirst()
    }

    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        outputPauseEvents.append(OutputPauseEvent(runtimeID: runtimeID, paused: paused))
        return TerminalRuntime(
            id: runtimeID,
            kind: "remote_ssh",
            shellPath: "",
            remoteHost: "example.com",
            remotePort: 22,
            username: "deploy",
            cols: 80,
            rows: 24,
            resizeRevision: 0,
            status: "running",
            outputPaused: paused
        )
    }

    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {
        keepaliveEvents.append(KeepaliveIntervalEvent(runtimeID: runtimeID, seconds: seconds))
    }

    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        closedRuntimeIDs.append(runtimeID)
        return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
    }
}

private struct OutputPauseEvent: Equatable {
    let runtimeID: String
    let paused: Bool
}

private struct KeepaliveIntervalEvent: Equatable {
    let runtimeID: String
    let seconds: UInt32
}

extension TerminalOutputBatch {
    init(runtimeId: String, bytes: Data, droppedByteCount: UInt32) {
        self.init(
            runtimeId: runtimeId,
            bytes: bytes,
            droppedByteCount: droppedByteCount,
            protectionActive: droppedByteCount > 0,
            bufferedByteCount: UInt32(bytes.count)
        )
    }
}

private final class RecordingRemoteTerminalReconnecter: RemoteTerminalReconnecting {
    private let status: LiveShellStatus
    private(set) var reconnectedTitles: [String] = []
    private(set) var liveSessionContext: TunnelLiveSessionContext?

    init(status: LiveShellStatus, liveSessionContext: TunnelLiveSessionContext? = nil) {
        self.status = status
        self.liveSessionContext = liveSessionContext
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        reconnectedTitles.append(title)
        return status
    }
}

private final class ControlledBackgroundRemoteTerminalReconnecter: RemoteTerminalBackgroundReconnecting {
    private var completions: [(@MainActor (Result<LiveShellStatus, Error>) -> Void)?] = []
    private(set) var cancelCount = 0

    var pendingCompletionCount: Int {
        completions.compactMap { $0 }.count
    }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        throw RemoteTerminalLifecycleError.reconnectUnavailable
    }

    func reconnectRemoteTerminalInBackground(
        title: String,
        automatically: Bool,
        completion: @escaping @MainActor (Result<LiveShellStatus, Error>) -> Void
    ) {
        completions.append(completion)
    }

    func cancelPendingReconnects() {
        cancelCount += 1
    }

    func complete(at index: Int, with result: Result<LiveShellStatus, Error>) {
        guard completions.indices.contains(index), let completion = completions[index] else {
            return
        }
        completions[index] = nil
        completion(result)
    }
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

private func remoteLiveContext(host: String) -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: host,
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:\(host)"
    )
}

private func assertBashAcceptsScript(
    _ script: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-n"]

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output

    try process.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTFail("bash rejected OSC7 bootstrap: \(diagnostics)", file: file, line: line)
    }
}

private func assertRemoteBootstrapShellAcceptsScriptIfPresent(
    executable: String,
    arguments: [String],
    script: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw XCTSkip("\(executable) is not available")
    }
    try assertRemoteBootstrapShellAcceptsScript(
        executable: executable,
        arguments: arguments,
        script: script,
        file: file,
        line: line
    )
}

private func assertRemoteBootstrapShellAcceptsScript(
    executable: String,
    arguments: [String],
    script: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output

    try process.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTFail(
            "\(executable) rejected OSC7 bootstrap: \(diagnostics)",
            file: file,
            line: line
        )
    }
}
