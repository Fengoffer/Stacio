import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

/// Uses the same opt-in, verified-host environment as the SSH stability suite.
@MainActor
final class LiveSSHTerminalRecordingTests: XCTestCase {
    func testConcurrentRecordingRemoteEOFReconnectAndManualClose() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STACIO_TERMINAL_REAL_SSH"] == "1" else { throw XCTSkip("Opt-in real SSH recording workload") }
        let host = try XCTUnwrap(env["STACIO_TERMINAL_SSH_HOST"])
        let user = try XCTUnwrap(env["STACIO_TERMINAL_SSH_USER"])
        let key = try XCTUnwrap(env["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(env["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(host: host, port: 22, username: user,
                                         authMethod: .privateKey(keyPath: key, passphraseRef: nil), connectTimeoutMs: 5_000)
        let secret = SshAuthSecret.privateKey(privateKeyPem: try String(contentsOfFile: key, encoding: .utf8), passphrase: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StacioLiveRTF-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "StacioRecordingLive-\(UUID().uuidString)")!
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        var panes: [RemoteTerminalPaneViewController] = []
        defer {
            panes.forEach { $0.closeTerminal(); $0.styledRecording?.waitUntilSaved() }
            if testRun?.failureCount == 0 { try? FileManager.default.removeItem(at: directory) }
            else { print("TERMINAL_RECORDING failure_artifacts=\(directory.path)") }
        }
        func connect() throws -> LiveShellStatus {
            try CoreBridge.startLiveSSHShellRuntime(config: config, secret: secret,
                                                    expectedFingerprintSHA256: fingerprint, cols: 100, rows: 30)
        }
        func rendered(_ pane: RemoteTerminalPaneViewController) -> String {
            String(decoding: pane.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        }
        for index in 0..<4 {
            let status = try connect()
            let pane = RemoteTerminalPaneViewController(runtimeID: status.runtimeId, title: "Recording SSH \(index)",
                                                       eventSink: CoreBridgeTerminalEventSink(), settingsStore: AppSettingsStore(defaults: defaults))
            panes.append(pane)
            pane.loadView()
            pane.view.frame = NSRect(x: 0, y: 0, width: 950, height: 600)
            pane.viewDidAppear()
            pane.sendInput(Array("unset HISTFILE; HISTSIZE=0; stty -echo; PS1=''; printf '\\r\\nREADY_\(index)\\n'\r".utf8))
            XCTAssertTrue(wait(10) { rendered(pane).contains("READY_\(index)") })
            pane.styledRecording = try StyledTerminalRecording(view: pane.terminalView, title: pane.terminalTitle, directory: directory)
            pane.viewWillDisappear()
        }
        let first = try XCTUnwrap(panes[0].styledRecording)
        let originalURL = first.fileURL
        for index in 1..<4 {
            let script = """
            import sys, time
            for n in range(3000):
                print(f'\u{1b}[38;2;17;34;51mS\(index)_ROW{n:06d}\u{1b}[0m', flush=True)
            print('BURST_DONE_\(index)', flush=True)
            for n in range(100):
                print(f'S\(index)_TICK{n:04d}', flush=True); time.sleep(0.1)
            print('STREAM_DONE_\(index)', flush=True)
            """
            let base64 = Data(script.utf8).base64EncodedString()
            panes[index].sendInput(Array("python3 -u -c 'import base64; exec(base64.b64decode(\"\(base64)\"))'\r".utf8))
        }
        panes[0].sendInput(Array("printf 'BEFORE_REMOTE_EXIT\\n'; exit\r".utf8))
        XCTAssertTrue(wait(10) { panes[0].lifecycleState == .disconnected })
        XCTAssertTrue(first.isRecording, "Remote EOF must not end recording")
        let oldRuntime = panes[0].runtimeID
        panes[0].attachConnectedRuntime(status: try connect())
        _ = try? CoreBridge.closeLiveSSHShell(runtimeID: oldRuntime)
        panes[0].sendInput(Array("unset HISTFILE; HISTSIZE=0; stty -echo; printf 'AFTER_RECONNECT\\n'\r".utf8))
        XCTAssertTrue(wait(10) { rendered(panes[0]).contains("AFTER_RECONNECT") })
        XCTAssertTrue(first === panes[0].styledRecording)
        XCTAssertEqual(first.fileURL, originalURL)
        XCTAssertTrue(wait(30) { (1..<4).allSatisfy { rendered(panes[$0]).contains("BURST_DONE_\($0)") } })
        panes[1].closeTerminal()
        XCTAssertTrue(wait(30) { (2..<4).allSatisfy { rendered(panes[$0]).contains("STREAM_DONE_\($0)") } })
        for index in [0, 2, 3] {
            XCTAssertEqual(panes[index].lifecycleState, .running)
            XCTAssertTrue(try XCTUnwrap(panes[index].styledRecording).isRecording)
            panes[index].closeTerminal()
        }
        for (index, pane) in panes.enumerated() {
            let recording = try XCTUnwrap(pane.styledRecording)
            recording.waitUntilSaved()
            XCTAssertNil(recording.error)
            let output = try NSAttributedString(url: recording.fileURL, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            if index == 0 {
                XCTAssertTrue(output.string.contains("BEFORE_REMOTE_EXIT"))
                XCTAssertTrue(output.string.contains("AFTER_RECONNECT"))
            } else {
                let lines = output.string.components(separatedBy: .newlines).filter { $0.hasPrefix("S\(index)_ROW") }
                let expected = (0..<3000).map { String(format: "S%d_ROW%06d", index, $0) }
                let actual = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                if actual != expected {
                    try output.string.write(to: directory.appendingPathComponent("recorded-\(index).txt"), atomically: true, encoding: .utf8)
                    try rendered(pane).write(to: directory.appendingPathComponent("screen-\(index).txt"), atomically: true, encoding: .utf8)
                    let missing = expected.filter { !actual.contains($0) }
                    print("TERMINAL_RECORDING peer=\(index) missing=\(missing.prefix(10)) count=\(lines.count)")
                }
                XCTAssertEqual(actual, expected, "Every rendered output row must survive recording")
                if index > 1 { XCTAssertTrue(output.string.contains("STREAM_DONE_\(index)")) }
            }
        }
        print("TERMINAL_RECORDING real_ssh=4 remote_eof_reconnect=1 peer_closed=1 surviving_peers=2 rows_per_peer=3000 failures=\(testRun?.failureCount ?? 0)")
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
}
