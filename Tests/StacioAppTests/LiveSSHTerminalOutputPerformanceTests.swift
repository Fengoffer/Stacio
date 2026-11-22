import AppKit
import StacioCoreBindings
import SwiftTerm
import XCTest
@testable import StacioApp

/// Opt-in end-to-end SSH + AppKit workload. Requires an explicitly supplied test
/// host, username, private-key path and verified host-key fingerprint in Stacio's
/// SHA256:<hex digest> format (not OpenSSH's base64 fingerprint).
/// The stability workload creates unique temporary transfer files and removes them.
@MainActor
final class LiveSSHTerminalOutputPerformanceTests: XCTestCase {
    func testContinuousOutputAndInputOnRealSSH() throws {
        try runWorkload(paced: true)
    }

    func testBurstOutputOnRealSSH() throws {
        try runWorkload(paced: false)
    }

    func testHiddenConcurrentSessionsSurvivePeerCloseAndFileTransfers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STACIO_TERMINAL_REAL_SSH"] == "1" else {
            throw XCTSkip("Opt-in real SSH stability workload")
        }
        let host = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_HOST"])
        let username = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_USER"])
        let keyPath = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let duration = max(5, Int(environment["STACIO_TERMINAL_STABILITY_SECONDS"] ?? "10") ?? 10)
        let config = SshConnectionConfig(
            host: host, port: 22, username: username,
            authMethod: .privateKey(keyPath: keyPath, passphraseRef: nil), connectTimeoutMs: 5_000
        )
        let secret = SshAuthSecret.privateKey(
            privateKeyPem: try String(contentsOfFile: keyPath, encoding: .utf8), passphrase: nil
        )
        _ = NSApplication.shared
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let suite = "Stacio.ConnectionStability.\(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var controllers: [RemoteTerminalPaneViewController] = []
        var bridges: [LiveSSHOutputMeasurementBridge] = []
        defer { controllers.forEach { $0.closeTerminal() } }
        for index in 0..<4 {
            let status = try CoreBridge.startLiveSSHShellRuntime(
                config: config, secret: secret, expectedFingerprintSHA256: fingerprint, cols: 100, rows: 30
            )
            let bridge = LiveSSHOutputMeasurementBridge()
            let controller = RemoteTerminalPaneViewController(
                runtimeID: status.runtimeId, title: "Hidden SSH stability \(index)",
                eventSink: CoreBridgeTerminalEventSink(), bridge: bridge,
                settingsStore: AppSettingsStore(defaults: defaults)
            )
            controllers.append(controller)
            bridges.append(bridge)
            controller.loadView()
            controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 550)
            controller.viewDidAppear()
            pump(0.3)
            let ready = "READY_\(index)_\(token)"
            controller.sendInput(Array("unset HISTFILE; HISTSIZE=0; stty -echo; PS1=''; printf '\\r\\n\(ready)\\n'\r".utf8))
            guard wait(5, until: { bridge.output.contains(Data("\r\n\(ready)\r\n".utf8)) }) else {
                return XCTFail("SSH stability shell \(index) did not become ready")
            }
            controller.viewWillDisappear()
        }

        let ticks = duration * 10
        for (index, controller) in controllers.enumerated() {
            let script = """
            import sys,time
            out=sys.stdout.buffer
            out.write(('BEGIN_\(index)_\(token)\\n').encode()); out.flush()
            for n in range(32768):
                out.write((f'B{n:06d} '+('x'*96)+'\\n').encode())
            out.write(('BURST_END_\(index)_\(token)\\n').encode()); out.flush()
            for n in range(\(ticks)):
                out.write((f'T{n:06d} alive\\n').encode()); out.flush()
                time.sleep(0.1)
            out.write(('END_\(index)_\(token)\\n').encode()); out.flush()
            """
            let encoded = Data(script.utf8).base64EncodedString()
            controller.sendInput(Array("python3 -u -c 'import base64; exec(base64.b64decode(\"\(encoded)\"))'\r".utf8))
        }
        guard wait(40, until: {
            bridges.enumerated().allSatisfy { index, bridge in
                bridge.output.contains(Data("BURST_END_\(index)_\(token)\r\n".utf8))
            }
        }) else { return XCTFail("Hidden sessions must drain every initial burst") }
        controllers[0].closeTerminal()

        // Separate transfer sessions must coexist with running terminal sessions.
        let transfers = SSHStabilityTransferResult()
        DispatchQueue.global(qos: .userInitiated).async {
            transfers.run(config: config, secret: secret, fingerprint: fingerprint, token: token)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(duration + 20))
        var lastReported = Date.distantPast
        while Date() < deadline {
            guard controllers.dropFirst().allSatisfy({ $0.lifecycleState == .running }) else {
                return XCTFail("Closing one session or transferring files disconnected a healthy peer")
            }
            if bridges.enumerated().dropFirst().allSatisfy({ index, bridge in
                bridge.output.contains(Data("\r\nEND_\(index)_\(token)\r\n".utf8))
            }) { break }
            if Date().timeIntervalSince(lastReported) >= 30 {
                print("TERMINAL_STABILITY progress remaining_s=\(Int(deadline.timeIntervalSinceNow)) active=3")
                lastReported = Date()
            }
            pump(0.05)
        }
        XCTAssertTrue(wait(60) { transfers.isFinished }, "File transfers must finish")
        XCTAssertNil(transfers.error)
        let burst = (0..<32_768).map { String(format: "B%06d ", $0) + String(repeating: "x", count: 96) + "\r\n" }.joined()
        let stream = (0..<ticks).map { String(format: "T%06d alive\r\n", $0) }.joined()
        var allExact = true
        for index in 1..<4 {
            let expected = Data(("BEGIN_\(index)_\(token)\r\n" + burst
                + "BURST_END_\(index)_\(token)\r\n" + stream + "END_\(index)_\(token)\r\n").utf8)
            let exact = bridges[index].output.contains(expected)
            allExact = allExact && exact
            XCTAssertTrue(exact, "Every byte must arrive in order on hidden session \(index)")
            XCTAssertEqual(bridges[index].droppedBytes, 0)
            XCTAssertEqual(controllers[index].lifecycleState, .running)
            controllers[index].sendInput(Array("printf 'FINAL_\(index)_\(token)\\n'\r".utf8))
            XCTAssertTrue(wait(5) { bridges[index].output.contains(Data("FINAL_\(index)_\(token)\r\n".utf8)) })
        }
        print("TERMINAL_STABILITY duration_s=\(duration) sessions=4 closed_by_user=1 healthy_peers=3 exact=\(allExact) transfers=\(transfers.error ?? "ok")")
    }

    private func runWorkload(paced: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STACIO_TERMINAL_REAL_SSH"] == "1" else {
            throw XCTSkip("Opt-in real SSH terminal workload")
        }
        let host = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_HOST"])
        let username = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_USER"])
        let keyPath = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(environment["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(
            host: host, port: 22, username: username,
            authMethod: .privateKey(keyPath: keyPath, passphraseRef: nil), connectTimeoutMs: 5_000
        )
        let status = try CoreBridge.startLiveSSHShellRuntime(
            config: config,
            secret: .privateKey(privateKeyPem: String(contentsOfFile: keyPath, encoding: .utf8), passphrase: nil),
            expectedFingerprintSHA256: fingerprint, cols: 100, rows: 30
        )
        let runtimeID = status.runtimeId
        defer { _ = try? CoreBridge.closeLiveSSHShell(runtimeID: runtimeID) }
        _ = NSApplication.shared
        let suite = "Stacio.LiveTerminalPerformance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = LiveSSHOutputMeasurementBridge()
        let controller = RemoteTerminalPaneViewController(
            runtimeID: runtimeID, title: "SSH terminal validation",
            eventSink: CoreBridgeTerminalEventSink(), bridge: bridge,
            settingsStore: AppSettingsStore(defaults: defaults)
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 550)
        let window = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 900, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        defer {
            controller.viewWillDisappear()
            controller.closeTerminal()
            window.close()
        }
        pump(1)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let ready = "READY_\(token)"
        controller.sendInput(Array("unset HISTFILE; HISTSIZE=0; stty -echo; PS1=''; printf '\\r\\n\(ready)\\n'\r".utf8))
        guard wait(5, until: { bridge.output.contains(Data("\r\n\(ready)\r\n".utf8)) }) else {
            return XCTFail("The remote test shell must be ready before generating output")
        }
        try controller.terminalView.setUseMetal(true)
        controller.terminalView.metalBufferingMode = .perFrameAggregated
        pump(0.3)
        XCTAssertTrue(controller.terminalView.isUsingMetalRenderer)

        let begin = "BEGIN_\(token)"
        let end = "END_\(token)"
        let input = "INPUT_\(token)"
        let echo = Data("ECHO_\(input)\r\n".utf8)
        let script = """
        import sys,time,select
        out=sys.stdout.buffer
        out.write(b'\(begin)\\n'); out.flush()
        for batch in range(400):
            out.write(''.join(f'{i:06d} build 0123456789 abcdefghijklmnopqrstuvwxyz\\n' for i in range(batch*48,(batch+1)*48)).encode())
            out.flush()
            if \(paced ? "True" : "False"):
                if select.select([sys.stdin],[],[],0)[0]:
                    line=sys.stdin.readline().rstrip('\\n')
                    out.write(('ECHO_'+line+'\\n').encode()); out.flush()
                time.sleep(0.004)
        out.write(b'\(end)\\n'); out.flush()
        """
        let encoded = Data(script.utf8).base64EncodedString()
        let startCPU = cpuTime()
        let start = ProcessInfo.processInfo.systemUptime
        let initialDropped = bridge.droppedBytes
        controller.sendInput(Array("python3 -u -c 'import base64; exec(base64.b64decode(\"\(encoded)\"))'\r".utf8))
        var liveEchoMilliseconds: Double?
        if paced {
            XCTAssertTrue(wait(5) { bridge.output.contains(Data("\(begin)\r\n".utf8)) })
            pump(0.2)
            let inputStart = ProcessInfo.processInfo.systemUptime
            controller.sendInput(Array("\(input)\r".utf8))
            XCTAssertTrue(wait(5) { bridge.output.contains(echo) }, "Input must be answered during continuous output")
            liveEchoMilliseconds = (ProcessInfo.processInfo.systemUptime - inputStart) * 1_000
        }
        let sawEnd = wait(15) { bridge.output.contains(Data("\(end)\r\n".utf8)) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let cpuMilliseconds = (cpuTime() - startCPU) * 1_000
        let dropped = bridge.droppedBytes - initialDropped
        let allOutput = bridge.output
        let beginBytes = Data("\(begin)\r\n".utf8)
        let endBytes = Data("\(end)\r\n".utf8)
        let expected = Data((0..<19_200).map {
            String(format: "%06d build 0123456789 abcdefghijklmnopqrstuvwxyz\r\n", $0)
        }.joined().utf8)
        var payload = Data()
        if let first = allOutput.range(of: beginBytes),
           let last = allOutput.range(of: endBytes, in: first.upperBound..<allOutput.endIndex) {
            payload = allOutput.subdata(in: first.upperBound..<last.lowerBound)
            if paced, let echoed = payload.range(of: echo) { payload.removeSubrange(echoed) }
        }
        let name = paced ? "continuous" : "burst"
        print("TERMINAL_SSH name=\(name) seconds=\(elapsed) cpu_ms=\(cpuMilliseconds) expected=\(expected.count) received=\(payload.count) dropped=\(dropped) exact=\(payload == expected) live_echo_ms=\(liveEchoMilliseconds.map(String.init(describing:)) ?? "n/a")")
        XCTAssertTrue(sawEnd, "The end marker must arrive over real SSH")
        XCTAssertEqual(dropped, 0, "The real SSH output queue must not discard bytes")
        XCTAssertTrue(payload == expected, "All 19,200 numbered lines must arrive in order, byte for byte")
        XCTAssertTrue(wait(3) { self.visibleText(controller).contains(end) }, "The end marker must reach SwiftTerm")

        // Real remote round trip after the load, measured through SwiftTerm's
        // visible buffer. This is not a GPU-present latency measurement.
        pump(0.4)
        for index in 0..<5 {
            let marker = "IDLE_ECHO_\(index)_\(token)"
            let echoStart = ProcessInfo.processInfo.systemUptime
            controller.sendInput(Array("printf '\(marker)\\n'\r".utf8))
            XCTAssertTrue(wait(3) { self.visibleText(controller).contains(marker) })
            print("TERMINAL_SSH_ECHO name=\(name) index=\(index) terminal_ms=\((ProcessInfo.processInfo.systemUptime - echoStart) * 1_000)")
        }
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { pump(0.002) }
        return condition()
    }

    private func visibleText(_ controller: RemoteTerminalPaneViewController) -> String {
        let terminal = controller.terminalView.getTerminal()
        return (0..<terminal.getDims().rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true)
        }.joined(separator: "\n")
    }

    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

private final class SSHStabilityTransferResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: String?
    var isFinished: Bool { lock.withLock { finished } }
    var error: String? { lock.withLock { failure } }

    func run(config: SshConnectionConfig, secret: SshAuthSecret, fingerprint: String, token: String) {
        defer { lock.withLock { finished = true } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-transfer-\(token)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let remoteDirectory = "/tmp/stacio-transfer-\(token)"
            try CoreBridge.createLiveRemoteDirectory(config: config, secret: secret,
                expectedFingerprintSHA256: fingerprint, remotePath: remoteDirectory)
            defer {
                do {
                    try CoreBridge.deleteLiveRemotePath(config: config, secret: secret,
                        expectedFingerprintSHA256: fingerprint, remotePath: remoteDirectory, recursive: true)
                } catch { lock.withLock { failure = "Transfer cleanup failed: \(error)" } }
            }
            let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
            let source = directory.appendingPathComponent("source.bin")
            try payload.write(to: source)
            for useSFTP in [false, true] {
                let name = useSFTP ? "sftp" : "scp"
                let remote = "\(remoteDirectory)/\(name).bin"
                let destination = directory.appendingPathComponent("\(name).bin")
                for direction in [ScpDirection.upload, .download] {
                    let job = ScpTransferJob(id: UUID().uuidString, direction: direction,
                        sourcePath: direction == .upload ? source.path : remote,
                        destinationPath: direction == .upload ? remote : destination.path,
                        bytesTotal: UInt64(payload.count))
                    if useSFTP {
                        _ = try CoreBridge.runLiveSFTPTransfer(config: config, secret: secret,
                            expectedFingerprintSHA256: fingerprint, job: job)
                    } else {
                        _ = try CoreBridge.runLiveSCPTransfer(config: config, secret: secret,
                            expectedFingerprintSHA256: fingerprint, job: job)
                    }
                }
                guard try Data(contentsOf: destination) == payload else {
                    throw NSError(domain: "StacioStability", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "\(name) round-trip bytes differ"])
                }
            }
        } catch { lock.withLock { failure = String(describing: error) } }
    }
}

private final class LiveSSHOutputMeasurementBridge: RemoteTerminalBridging {
    private let underlying = CoreBridgeRemoteTerminalBridge()
    private let lock = NSLock()
    private var received = Data()
    private var dropped: UInt64 = 0
    var output: Data { lock.withLock { received } }
    var droppedBytes: UInt64 { lock.withLock { dropped } }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try underlying.pollLiveSSHShell(runtimeID: runtimeID)
    }
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        let batch = try underlying.takeTerminalOutputBatch(runtimeID: runtimeID)
        lock.withLock { received.append(batch.bytes); dropped += UInt64(batch.droppedByteCount) }
        return batch
    }
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        try underlying.setTerminalOutputPaused(runtimeID: runtimeID, paused: paused)
    }
    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {
        try underlying.setLiveShellKeepaliveInterval(runtimeID: runtimeID, seconds: seconds)
    }
    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try underlying.closeLiveSSHShell(runtimeID: runtimeID)
    }
}
