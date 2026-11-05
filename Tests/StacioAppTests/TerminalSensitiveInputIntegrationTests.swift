import AppKit
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class TerminalSensitiveInputIntegrationTests: XCTestCase {
    func testLocalPasswordInputBypassesSuggestionsHistoryBroadcastAndAgentLock() {
        let runtimeID = "term_local_sensitive_\(UUID().uuidString)"
        let launcher = SensitiveInputRecordingLocalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: runtimeID,
            shellPath: "/bin/zsh",
            eventSink: SensitiveInputRecordingEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )
        var submittedCommands: [String] = []
        var userInputBroadcasts: [[UInt8]] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: runtimeID) { event in
            if event.kind == .userInput {
                userInputBroadcasts.append(event.bytes)
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        controller.onCommandSubmitted = { _, command in submittedCommands.append(command) }
        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )
        XCTAssertFalse(controller.commandHintVisibleTextForTesting.isEmpty)
        userInputBroadcasts.removeAll()
        controller.setAgentInteractionLocked(true)

        controller.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))

        XCTAssertTrue(controller.isAwaitingSensitiveInputForTesting)
        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("local-secret".utf8))
        )
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([13]))

        XCTAssertEqual(launcher.sentInput, [Array("local-secret".utf8), [13]])
        XCTAssertEqual(submittedCommands, [])
        XCTAssertEqual(userInputBroadcasts, [])
        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)

        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("blocked".utf8))
        )
        XCTAssertEqual(launcher.sentInput, [Array("local-secret".utf8), [13]])
    }

    func testMappedLocalPasswordInputUsesSamePrivateSink() {
        let runtimeID = "term_local_mapped_sensitive_\(UUID().uuidString)"
        let launcher = SensitiveInputRecordingLocalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: runtimeID,
            shellPath: "/bin/zsh",
            eventSink: SensitiveInputRecordingEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )
        var userInputBroadcasts = 0
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: runtimeID) { event in
            if event.kind == .userInput { userInputBroadcasts += 1 }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        controller.loadView()
        controller.setAgentInteractionLocked(true)
        controller.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))

        XCTAssertTrue(controller.sendSensitiveUserInput(Array("mapped-secret\r".utf8)))

        XCTAssertEqual(launcher.sentInput, [Array("mapped-secret\r".utf8)])
        XCTAssertEqual(userInputBroadcasts, 0)
        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)
        controller.sendInput(Array("blocked".utf8))
        XCTAssertEqual(launcher.sentInput, [Array("mapped-secret\r".utf8)])
    }

    func testSensitivePasteStopsAtFirstLineBoundaryWhileAgentRemainsLocked() {
        let launcher = SensitiveInputRecordingLocalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local_sensitive_multiline_paste",
            shellPath: "/bin/zsh",
            eventSink: SensitiveInputRecordingEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )
        controller.loadView()
        controller.setAgentInteractionLocked(true)
        controller.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))

        XCTAssertTrue(
            controller.sendSensitiveUserInput(Array("single-secret\rwhoami\r".utf8))
        )

        XCTAssertEqual(launcher.sentInput, [Array("single-secret\r".utf8)])
        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)
        controller.sendInput(Array("still-blocked".utf8))
        XCTAssertEqual(launcher.sentInput, [Array("single-secret\r".utf8)])
    }

    func testAgentCannotInjectInputWhilePasswordPromptIsActive() {
        let launcher = SensitiveInputRecordingLocalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local_agent_sensitive",
            shellPath: "/bin/zsh",
            eventSink: SensitiveInputRecordingEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )
        controller.loadView()
        controller.setAgentInteractionLocked(true)
        controller.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))

        controller.sendAgentInput(Array("agent-guessed-secret\r".utf8))

        XCTAssertEqual(launcher.sentInput, [])
        XCTAssertTrue(controller.isAwaitingSensitiveInputForTesting)
    }

    func testProgrammaticLocalInputCannotBecomePasswordForWaitingTerminal() {
        let launcher = SensitiveInputRecordingLocalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local_sensitive_programmatic_input",
            shellPath: "/bin/zsh",
            eventSink: SensitiveInputRecordingEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )
        controller.loadView()
        controller.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))

        controller.sendInput(Array("broadcast-command\r".utf8))

        XCTAssertEqual(launcher.sentInput, [])
        XCTAssertTrue(controller.isAwaitingSensitiveInputForTesting)
    }

    func testRemotePasswordInputBypassesSuggestionsHistoryBroadcastAndMultiExecHook() {
        let runtimeID = "term_remote_sensitive_\(UUID().uuidString)"
        let sink = SensitiveInputRecordingEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: runtimeID,
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )
        var submittedCommands: [String] = []
        var userInputHookCalls = 0
        var userInputBroadcasts: [[UInt8]] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: runtimeID) { event in
            if event.kind == .userInput {
                userInputBroadcasts.append(event.bytes)
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        controller.onCommandSubmitted = { _, command in submittedCommands.append(command) }
        controller.onUserInput = { _, _ in
            userInputHookCalls += 1
            return true
        }
        controller.loadView()
        controller.setAgentInteractionLocked(true)

        controller.feedRemoteOutput(Array("\u{001B}[33mPassword:\u{001B}[0m".utf8))
        controller.send(
            source: controller.terminalView,
            data: ArraySlice(Array("remote-secret".utf8))
        )
        controller.send(source: controller.terminalView, data: ArraySlice([13]))

        XCTAssertEqual(sink.userInputEvents.map(\.bytes), [Array("remote-secret".utf8), [13]])
        XCTAssertEqual(submittedCommands, [])
        XCTAssertEqual(userInputHookCalls, 0)
        XCTAssertEqual(userInputBroadcasts, [])
        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)

        controller.send(source: controller.terminalView, data: ArraySlice(Array("blocked".utf8)))
        XCTAssertEqual(sink.userInputEvents.map(\.bytes), [Array("remote-secret".utf8), [13]])
    }

    func testPotentialPasswordEchoNeverReachesTranscriptOrAIOutputBroadcast() {
        let runtimeID = "term_remote_sensitive_echo_\(UUID().uuidString)"
        let controller = RemoteTerminalPaneViewController(
            runtimeID: runtimeID,
            title: "deploy@example.com",
            eventSink: SensitiveInputRecordingEventSink(),
            startsPollingAutomatically: false
        )
        var observableOutput: [UInt8] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: runtimeID) { event in
            if event.kind == .output {
                observableOutput.append(contentsOf: event.bytes)
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        controller.loadView()
        controller.feedRemoteOutput(Array("Password:".utf8))
        XCTAssertTrue(controller.sendSensitiveUserInput(Array("never-observe-me\r".utf8)))

        controller.feedRemoteOutput(Array("never-observe-me\r\ncommand output\r\n".utf8))

        XCTAssertFalse(controller.terminalOutputTranscript.contains("never-observe-me"))
        XCTAssertFalse(String(decoding: observableOutput, as: UTF8.self).contains("never-observe-me"))
        XCTAssertTrue(controller.terminalOutputTranscript.contains("command output"))
    }

    func testProgrammaticRemoteInputCannotBecomePasswordForWaitingTerminal() {
        let sink = SensitiveInputRecordingEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote_sensitive_programmatic_input",
            title: "production",
            eventSink: sink,
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.feedRemoteOutput(Array("Password:".utf8))

        controller.sendInput(Array("broadcast-command\r".utf8))

        XCTAssertEqual(sink.userInputEvents, [])
        XCTAssertTrue(controller.isAwaitingSensitiveInputForTesting)
    }

    func testControlCLeavesSensitiveModeAndRestoresAgentLock() {
        let sink = SensitiveInputRecordingEventSink()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote_sensitive_cancel",
            title: "deploy@example.com",
            eventSink: sink,
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.setAgentInteractionLocked(true)
        controller.feedRemoteOutput(Array("Password:".utf8))

        controller.send(source: controller.terminalView, data: ArraySlice([3]))
        controller.send(source: controller.terminalView, data: ArraySlice(Array("blocked".utf8)))

        XCTAssertEqual(sink.userInputEvents.map(\.bytes), [[3]])
        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)
    }

    func testLocalProcessTerminationClearsSensitiveInputState() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local_sensitive_terminated",
            shellPath: "/bin/zsh",
            eventSink: SensitiveInputRecordingEventSink(),
            processLauncher: SensitiveInputRecordingLocalLauncher(),
            autoStartProcess: false
        )
        controller.loadView()
        controller.terminalView.dataReceived(slice: ArraySlice(Array("Password:".utf8)))
        XCTAssertTrue(controller.isAwaitingSensitiveInputForTesting)

        controller.processTerminated(source: controller.terminalView, exitCode: 0)

        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)
    }

    func testRemoteDisconnectClearsSensitiveInputState() {
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_remote_sensitive_disconnected",
            title: "production",
            eventSink: SensitiveInputRecordingEventSink(),
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.feedRemoteOutput(Array("Password:".utf8))
        XCTAssertTrue(controller.isAwaitingSensitiveInputForTesting)

        controller.displayConnectionFailure("connection lost")

        XCTAssertFalse(controller.isAwaitingSensitiveInputForTesting)
    }
}

private final class SensitiveInputRecordingEventSink: TerminalEventSink {
    private(set) var userInputEvents: [TerminalInputEvent] = []

    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {
        userInputEvents.append(TerminalInputEvent(runtimeID: runtimeID, bytes: bytes))
    }
    func terminalDidClose(runtimeID: String) throws {}
}

private final class SensitiveInputRecordingLocalLauncher: LocalTerminalProcessLaunching {
    private(set) var sentInput: [[UInt8]] = []

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool { false }
    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {}
    func terminate(_ terminalView: LocalProcessTerminalView) {}
    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {
        sentInput.append(bytes)
    }
}
