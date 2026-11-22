import AppKit
import Darwin
import StacioCoreBindings
import SwiftTerm
import XCTest
@testable import StacioApp

/// Opt-in, repeatable AppKit + Rust-buffer workload. No SSH server or user data.
/// Run with STACIO_TERMINAL_PERFORMANCE=1 and filter this class. The bridge uses
/// the real FFI/status lookup and buffer, but supplies a running synthetic peer.
@MainActor
final class TerminalOutputPerformanceTests: XCTestCase {
    func testReportTerminalOutputCosts() throws {
        guard ProcessInfo.processInfo.environment["STACIO_TERMINAL_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt-in terminal performance workload")
        }
        _ = NSApplication.shared
        if ProcessInfo.processInfo.environment["STACIO_TERMINAL_STREAM_ONLY"] != "1" {
            for count in [1, 5] {
                try runScenario(name: "idle-\(count)", count: count, streaming: false)
            }
        }
        try runScenario(name: "stream-1", count: 1, streaming: true)
    }

    private func runScenario(name: String, count: Int, streaming: Bool) throws {
        let suite = "Stacio.TerminalPerformance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let bridge = MeasuredTerminalBridge()
        var controllers: [RemoteTerminalPaneViewController] = []
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 900, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controllers.forEach { $0.closeTerminal() }
            window.close()
        }
        for index in 0..<count {
            let runtime = CoreBridge.openRemoteSSHRuntime(host: "performance.invalid", port: 22,
                                                          username: "fixture", cols: 100, rows: 30)
            let controller = RemoteTerminalPaneViewController(
                runtimeID: runtime.id, title: "Performance \(index)",
                eventSink: CoreBridgeTerminalEventSink(), bridge: bridge, settingsStore: settings
            )
            controller.loadView()
            controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 550)
            if index == 0 { window.contentViewController = controller }
            controller.viewDidAppear()
            controllers.append(controller)
        }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        pump(for: 0.6)
        for controller in controllers {
            try controller.terminalView.setUseMetal(true)
            controller.terminalView.metalBufferingMode = .perFrameAggregated
        }
        pump(for: 0.2)
        XCTAssertTrue(controllers[0].terminalView.isUsingMetalRenderer)
        let startUsage = usage()
        let started = ProcessInfo.processInfo.systemUptime
        let initialPolls = bridge.pollCount
        if streaming {
            let runtimeID = controllers[0].runtimeID
            let chunk = Data(String(repeating: "build 0123456789 abcdefghijklmnopqrstuvwxyz\r\n", count: 48).utf8)
            let producer = TerminalPerformanceProducer(runtimeID: runtimeID, chunk: chunk, iterations: 400)
            producer.start()
            let deadline = Date().addingTimeInterval(20)
            while !producer.finished && Date() < deadline { pump(for: 0.01) }
            XCTAssertTrue(producer.finished)
            pump(for: 0.5)
            let marker = "STACIO_STREAM_COMPLETE"
            try CoreBridge.recordTerminalOutput(runtimeID: runtimeID, bytes: Array((marker + "\r\n").utf8))
            let renderDeadline = Date().addingTimeInterval(10)
            while !visibleText(controllers[0]).contains(marker) && Date() < renderDeadline { pump(for: 0.01) }
            XCTAssertTrue(visibleText(controllers[0]).contains(marker), "The final marker must reach SwiftTerm, not only the transcript")
            pump(for: 1)
            var expected = (0..<400).reduce(into: Data()) { bytes, _ in bytes.append(chunk) }
            expected.append(Data((marker + "\r\n").utf8))
            XCTAssertEqual(bridge.receivedBytes, expected.count - Int(bridge.droppedBytes))
            print("TERMINAL_BYTES expected=\(expected.count) received=\(bridge.receivedBytes) dropped=\(bridge.droppedBytes) exact=\(bridge.receivedData == expected)")
            if ProcessInfo.processInfo.environment["STACIO_TERMINAL_ALLOW_BASELINE_LOSS"] != "1" {
                XCTAssertEqual(bridge.droppedBytes, 0)
                XCTAssertEqual(bridge.receivedData, expected)
            }
            XCTAssertNil(producer.error)
        } else {
            pump(for: 3)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let endUsage = usage()
        print("TERMINAL_PERF name=\(name) seconds=\(elapsed) cpu_ms=\((endUsage.cpu - startUsage.cpu) * 1000) polls=\(bridge.pollCount - initialPolls) voluntary_switches=\(endUsage.voluntary - startUsage.voluntary) involuntary_switches=\(endUsage.involuntary - startUsage.involuntary) metal=\(controllers[0].terminalView.isUsingMetalRenderer)")
        // Check the user-input fast path after idle, separately from stream throughput.
        pump(for: 0.6)
        let marker = "PERF_ECHO_\(UUID().uuidString)"
        let outputPosition = controllers[0].agentOutputPosition
        controllers[0].sendInput(Array("x".utf8))
        let echoStart = ProcessInfo.processInfo.systemUptime
        try CoreBridge.recordTerminalOutput(runtimeID: controllers[0].runtimeID, bytes: Array((marker + "\r\n").utf8))
        let deadline = Date().addingTimeInterval(1)
        while !controllers[0].agentOutput(since: outputPosition, limit: 256).contains(marker) && Date() < deadline { pump(for: 0.001) }
        XCTAssertTrue(controllers[0].agentOutput(since: outputPosition, limit: 256).contains(marker))
        let receiptLatency = (ProcessInfo.processInfo.systemUptime - echoStart) * 1000
        while !visibleText(controllers[0]).contains(marker) && Date() < deadline { pump(for: 0.001) }
        XCTAssertTrue(visibleText(controllers[0]).contains(marker))
        print("TERMINAL_ECHO name=\(name) receipt_ms=\(receiptLatency) terminal_ms=\((ProcessInfo.processInfo.systemUptime - echoStart) * 1000)")
        controllers.forEach { $0.viewWillDisappear() }
        pump(for: 0.1)
        let hiddenPolls = bridge.pollCount
        pump(for: 0.3)
        XCTAssertEqual(bridge.pollCount, hiddenPolls, "Disappeared panes must stop polling")
    }

    private func pump(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func visibleText(_ controller: RemoteTerminalPaneViewController) -> String {
        let terminal = controller.terminalView.getTerminal()
        return (0..<terminal.getDims().rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true)
        }.joined(separator: "\n")
    }

    private func usage() -> (cpu: Double, voluntary: Int, involuntary: Int) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        return (cpu, Int(value.ru_nvcsw), Int(value.ru_nivcsw))
    }
}

private final class MeasuredTerminalBridge: RemoteTerminalBridging {
    private let lock = NSLock()
    private var polls = 0
    private var received = Data()
    private var dropped: UInt64 = 0
    var pollCount: Int { lock.withLock { polls } }
    var receivedBytes: Int { lock.withLock { received.count } }
    var receivedData: Data { lock.withLock { received } }
    var droppedBytes: UInt64 { lock.withLock { dropped } }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        _ = try CoreBridge.pollLiveSSHShell(runtimeID: runtimeID)
        lock.withLock { polls += 1 }
        return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "fixture")
    }
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        let batch = try CoreBridge.takeTerminalOutputBatch(runtimeID: runtimeID)
        lock.withLock { received.append(batch.bytes); dropped += UInt64(batch.droppedByteCount) }
        return batch
    }
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        try CoreBridge.setTerminalOutputPaused(runtimeID: runtimeID, paused: paused)
    }
    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {}
    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        _ = try CoreBridge.closeTerminalRuntime(runtimeID: runtimeID)
        return LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "fixture")
    }
}

private final class TerminalPerformanceProducer: @unchecked Sendable {
    let runtimeID: String
    let chunk: Data
    let iterations: Int
    private let lock = NSLock()
    private var done = false
    private var failure: Error?
    var finished: Bool { lock.withLock { done } }
    var error: Error? { lock.withLock { failure } }
    init(runtimeID: String, chunk: Data, iterations: Int) {
        self.runtimeID = runtimeID; self.chunk = chunk; self.iterations = iterations
    }
    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.lock.withLock { self.done = true } }
            do {
                for _ in 0..<self.iterations {
                    try StacioCoreBindings.recordTerminalOutput(runtimeId: self.runtimeID, bytes: self.chunk)
                    Thread.sleep(forTimeInterval: 0.004)
                }
            } catch { self.lock.withLock { self.failure = error } }
        }
    }
}
