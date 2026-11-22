import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class RemoteTerminalConnectionStabilityTests: XCTestCase {
    func testReconnectInHiddenPaneRestartsOutputConsumption() throws {
        let bridge = StabilityTerminalBridge()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "old-runtime", title: "Hidden reconnect",
            eventSink: StabilityTerminalEventSink(), bridge: bridge,
            reconnecter: StabilityTerminalReconnecter()
        )
        controller.loadView()
        controller.viewDidAppear()
        controller.viewWillDisappear()
        defer { controller.closeTerminal() }
        XCTAssertTrue(wait { !controller.isPollingRemoteOutputForTesting })
        let status = try controller.reconnectTerminal()
        XCTAssertEqual(status.runtimeId, "new-runtime")
        XCTAssertNil(controller.view.window)
        bridge.enqueue("after-hidden-reconnect\r\n")
        XCTAssertTrue(wait { controller.terminalOutputTranscript.contains("after-hidden-reconnect") })
        XCTAssertEqual(controller.lifecycleState, .running)
    }

    func testHiddenSessionsKeepConsumingAndClosingOneDoesNotStopPeers() {
        let kinds: [RemoteTerminalConnectionKind] = [.ssh, .telnet, .serial, .console]
        let bridges = kinds.map { _ in StabilityTerminalBridge() }
        let controllers = kinds.enumerated().map { index, kind in
            let controller = RemoteTerminalPaneViewController(
                runtimeID: "stability_\(index)", title: "Stability fixture",
                connectionKind: kind, eventSink: StabilityTerminalEventSink(), bridge: bridges[index]
            )
            controller.loadView()
            controller.viewDidAppear()
            controller.viewWillDisappear()
            return controller
        }
        defer { controllers.forEach { $0.closeTerminal() } }

        for round in 0..<3 {
            for (index, bridge) in bridges.enumerated() {
                bridge.enqueue("hidden-\(index)-\(round)\r\n")
            }
            XCTAssertTrue(wait {
                controllers.enumerated().allSatisfy { index, controller in
                    controller.terminalOutputTranscript.contains("hidden-\(index)-\(round)")
                }
            }, "Every hidden connection must keep consuming output")
            for controller in controllers {
                XCTAssertEqual(controller.lifecycleState, .running)
                controller.viewDidAppear()
                controller.viewWillDisappear()
            }
        }
        XCTAssertTrue(bridges.allSatisfy { $0.closeCount == 0 })

        controllers[0].closeTerminal()
        XCTAssertTrue(wait { !controllers[0].isPollingRemoteOutputForTesting })
        let closedPollCount = bridges[0].pollCount
        for bridge in bridges.dropFirst() { bridge.enqueue("peer-still-alive\r\n") }
        XCTAssertTrue(wait {
            controllers.dropFirst().allSatisfy { $0.terminalOutputTranscript.contains("peer-still-alive") }
        })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(bridges[0].pollCount, closedPollCount, "Explicit close must stop consumption")
        XCTAssertEqual(bridges[0].closeCount, 1)
        XCTAssertTrue(bridges.dropFirst().allSatisfy { $0.closeCount == 0 })
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}

private final class StabilityTerminalBridge: RemoteTerminalBridging {
    private let lock = NSLock()
    private var pending = Data()
    private var polls = 0
    private var closes = 0
    var pollCount: Int { lock.withLock { polls } }
    var closeCount: Int { lock.withLock { closes } }

    func enqueue(_ text: String) { lock.withLock { pending.append(contentsOf: text.utf8) } }
    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        lock.withLock { polls += 1 }
        return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
    }
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        let bytes = lock.withLock {
            let bytes = pending
            pending.removeAll(keepingCapacity: true)
            return bytes
        }
        return TerminalOutputBatch(runtimeId: runtimeID, bytes: bytes, droppedByteCount: 0)
    }
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        fatalError("This fixture never pauses output")
    }
    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {}
    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        lock.withLock { closes += 1 }
        return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
    }
}

private final class StabilityTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

@MainActor
private final class StabilityTerminalReconnecter: RemoteTerminalReconnecting {
    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: "new-runtime", status: "running", diagnostic: "running")
    }
}
