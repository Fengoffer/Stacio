import Foundation

// Production error localization, polling, failure presentation and close paths
// are extracted by the script. UI/network leaves are inert; no AppKit or remote
// connection is needed to exercise the actual diagnostic propagation.
// PRODUCTION_MODELS

private struct Status { let runtimeId: String; let status: String; let diagnostic: String }
private typealias LiveShellStatus = Status
private typealias TerminalOutputBatch = Batch
private struct Batch {
    let runtimeId: String
    var bytes = Data()
    let protectionActive = false
    let droppedByteCount: UInt32 = 0
    let bufferedByteCount: UInt32 = 0
}
private final class Bridge {
    var pollError: Error?
    var readError: Error?
    var status = "running"
    var diagnostic = "running"
    var closes = 0
    var polls = 0
    var output = Data()
    func pollLiveSSHShell(runtimeID: String) throws -> Status {
        polls += 1
        if let pollError { throw pollError }
        return Status(runtimeId: runtimeID, status: status, diagnostic: diagnostic)
    }
    func takeTerminalOutputBatch(runtimeID: String) throws -> Batch {
        if let readError { throw readError }
        return Batch(runtimeId: runtimeID, bytes: output)
    }
    func closeLiveSSHShell(runtimeID: String) throws { closes += 1 }
}
private final class Resettable { func reset() {} }
private class View {
    var isHidden = false, isEnabled = false
    var superview: View?
    var window: Int?
    var stringValue = ""
}
private final class Terminal: View { func cancelPendingSemanticOutput() {} }
private enum SessionConnectionPhase { case connecting, reconnecting, failed(message: String) }
private final class ConnectionStateView {
    var isPresented = false
    var phase: SessionConnectionPhase = .connecting
    func update(phase: SessionConnectionPhase) { self.phase = phase }
    func setPresented(_ isPresented: Bool, animated: Bool) { self.isPresented = isPresented }
}
private struct Settings { func snapshot() -> Int { 0 } }
private final class Sink { func terminalDidClose(runtimeID: String) throws {} }
private protocol RemoteTerminalBackgroundReconnecting { func cancelPendingReconnects() }

private final class Pane {
    let connectionKind: RemoteTerminalConnectionKind
    let bridge = Bridge(), sensitiveInputState = Resettable(), terminalView = Terminal(), eventSink = Sink()
    let view = View(), lifecycleLabel = View(), lifecycleBar = View(), reconnectButton = View()
    let connectionStateView = ConnectionStateView(), settingsStore = Settings()
    var isViewLoaded = false, agentInteractionLocked = false, isNormalTelnetDisconnection = false
    var lifecycleState: RemoteTerminalLifecycleState = .running
    var lifecycleMessage: String { lifecycleLabel.stringValue }
    var transcript = ""
    var didClose = false
    var hasEstablishedRuntime = true
    var isPollingRemoteOutput = false
    var reconnectGeneration = 0
    var pendingTerminalResize: Int?
    var reconnecter: Any?
    let runtimeID = "fixture"
    var onTerminalClosed: ((Bool) -> Void)?
    var onRequestClose: ((Pane) -> Void)?, onRequestSaveOutput: ((Pane) -> Void)?
    var initialTransientNetworkFailureCount = 0
    var pollStops = 0
    var retryCount = 0, automaticRetryCount = 0
    init(_ kind: RemoteTerminalConnectionKind) { connectionKind = kind }
    func cancelAutomaticReconnect() {}
    func resetSilentInputEchoRecoveryState() {}
    func resetTerminalOutputForConnectedRuntime() { transcript = "" }
    func stopOutputPolling() { pollStops += 1 }
    func shouldRetryInitialSSHNetworkFailure(_ diagnostic: String) -> Bool { false }
    @discardableResult func scheduleAutomaticReconnectIfNeeded() -> Bool { automaticRetryCount += 1; return false }
    func applyTerminalRuntimeSettings(_ settings: Int) {}
    func retryStoppedSession() {
        retryCount += 1
        setLifecycle(.reconnecting, message: "")
        setLifecycle(.running, message: "")
    }
    func feedRemoteOutput(_ bytes: [UInt8], applySemanticHighlighting: Bool = true) {
        transcript += String(decoding: bytes, as: UTF8.self)
    }
    func updateOutputProtectionStatus(protectionActive: Bool, droppedByteCount: UInt32, bufferedByteCount: UInt32) {}
    // PRODUCTION_PANE_METHODS
}

private enum TelnetDiagnostics {
    // PRODUCTION_TELNET_METHODS
}

@main private struct TelnetDiagnosticChecks {
    static func main() {
        func waitUntil(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(predicate(), "Asynchronous production poll did not complete")
        }
        let errors: [(Error, String)] = [
            (SshRuntimeError.Timeout, "Telnet 连接超时"),
            (SshRuntimeError.AuthFailed, "Telnet 认证失败"),
            (SshRuntimeError.Transport(message: "Connection refused"), "Telnet 连接被拒绝"),
            (SshRuntimeError.Transport(message: "Connection reset by peer (os error 54)"), "Telnet 连接被远端重置"),
            (TerminalRuntimeError.RuntimeIo(message: "Broken pipe"), "终端读写失败：连接管道已断开")
        ]
        for (error, expected) in errors {
            // Same bridge-error formatting used by the reconnect callback.
            let reconnect = Pane(.telnet)
            reconnect.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
            precondition(reconnect.lifecycleMessage == "已断开：\(expected)", reconnect.lifecycleMessage)
            precondition(reconnect.transcript.contains(expected) && !reconnect.transcript.contains("SSH"))
            for failsDuringRead in [false, true] {
                let polling = Pane(.telnet)
                if failsDuringRead { polling.bridge.readError = error }
                else { polling.bridge.pollError = error }
                _ = polling.pollRemoteOutputOnce()
                precondition(polling.lifecycleState == .disconnected && polling.pollStops == 1)
                precondition(polling.lifecycleMessage == "已断开：\(expected)", polling.lifecycleMessage)
                precondition(!polling.transcript.contains("SSH"))
            }
        }
        let stopped = Pane(.telnet)
        stopped.bridge.status = "closed"
        stopped.bridge.diagnostic = "Connection reset by peer"
        _ = stopped.pollRemoteOutputOnce()
        precondition(stopped.lifecycleMessage == "已断开：连接被远端重置")

        let sanitized = Pane(.telnet)
        sanitized.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(
            for: SshRuntimeError.Transport(message: "Connection refused TOKEN=fake-value /tmp/fake-key")))
        precondition(sanitized.lifecycleMessage.hasPrefix("已断开：Telnet "))
        precondition(!sanitized.transcript.contains("fake-value") && !sanitized.transcript.contains("/tmp/fake-key"))

        let ssh = Pane(.ssh), serial = Pane(.serial), alreadyTelnet = Pane(.telnet)
        let sharedError = RuntimeDiagnosticFormatter.userMessage(for: SshRuntimeError.Timeout)
        ssh.displayConnectionFailure(sharedError)
        serial.displayConnectionFailure(sharedError)
        alreadyTelnet.displayConnectionFailure("Telnet 连接失败：连接超时")
        precondition(ssh.lifecycleMessage == "已断开：SSH 连接超时")
        precondition(serial.lifecycleMessage == "已断开：串口连接超时")
        precondition(alreadyTelnet.lifecycleMessage == "已断开：Telnet 连接失败：连接超时")
        precondition(TelnetDiagnostics.diagnosticMessage(for: SshRuntimeError.Timeout) == "Telnet 连接失败：连接超时")
        precondition(TelnetDiagnostics.diagnosticMessage(for: SshRuntimeError.Transport(message: "Connection refused"))
                     == "Telnet 连接失败：连接被拒绝")

        let transient = Pane(.telnet)
        transient.bridge.pollError = SshRuntimeError.Transport(message: "Would block")
        _ = transient.pollRemoteOutputOnce()
        precondition(transient.lifecycleState == .running && transient.transcript.isEmpty && transient.pollStops == 0)

        let closed = Pane(.telnet)
        closed.closeTerminal()
        closed.displayConnectionFailure(sharedError)
        _ = closed.pollRemoteOutputOnce()
        precondition(closed.lifecycleState == .closed && closed.lifecycleMessage == "已断开")
        precondition(closed.transcript.isEmpty && closed.bridge.closes == 1)
        for asynchronously in [false, true] {
            let eof = Pane(.telnet)
            eof.bridge.status = "closed"
            eof.bridge.diagnostic = "closed"
            eof.bridge.output = Data("final Telnet output\r\n".utf8)
            if asynchronously {
                eof.pollRemoteOutputInBackground()
                waitUntil { eof.lifecycleState == .disconnected }
            } else {
                precondition(eof.pollRemoteOutputOnce())
            }
            precondition(eof.lifecycleMessage == "Telnet 连接已断开" && eof.isNormalTelnetDisconnection)
            precondition(!eof.connectionStateView.isPresented && !eof.terminalView.isHidden)
            precondition(eof.transcript.hasPrefix("final Telnet output\r\n"))
            precondition(eof.transcript.contains("按 <回车> 重新连接会话"))
            precondition(!eof.transcript.contains("失败") && !eof.transcript.contains("SSH"))
            precondition(eof.pollStops == 1 && eof.retryCount == 0 && eof.automaticRetryCount == 0)
            precondition(!eof.pollRemoteOutputOnce() && eof.bridge.polls == 1)
            eof.handleStoppedSessionInput([13])
            precondition(eof.retryCount == 1 && eof.lifecycleState == .running && !eof.isNormalTelnetDisconnection)
            eof.displayConnectionFailure(sharedError)
            precondition(eof.connectionStateView.isPresented && !eof.isNormalTelnetDisconnection)
            precondition(eof.lifecycleMessage == "已断开：Telnet 连接超时")
            precondition(!eof.transcript.contains("按 <回车> 关闭标签页"))

            for diagnostic in ["Connection reset by peer", "keepalive_failed", "", "closed: error"] {
                let failed = Pane(.telnet)
                failed.bridge.status = "closed"
                failed.bridge.diagnostic = diagnostic
                if asynchronously {
                    failed.pollRemoteOutputInBackground()
                    waitUntil { failed.lifecycleState == .disconnected }
                } else { _ = failed.pollRemoteOutputOnce() }
                precondition(failed.connectionStateView.isPresented && !failed.isNormalTelnetDisconnection)
                precondition(failed.transcript.contains("失败"))
            }
        }
        let failedStatus = Pane(.telnet)
        failedStatus.bridge.status = "failed"
        failedStatus.bridge.diagnostic = "closed"
        _ = failedStatus.pollRemoteOutputOnce()
        precondition(failedStatus.connectionStateView.isPresented && !failedStatus.isNormalTelnetDisconnection)
        let sshEOF = Pane(.ssh)
        sshEOF.bridge.status = "closed"
        sshEOF.bridge.diagnostic = "closed"
        _ = sshEOF.pollRemoteOutputOnce()
        precondition(sshEOF.connectionStateView.isPresented && !sshEOF.isNormalTelnetDisconnection)
        closed.handleStoppedSessionInput([13])
        precondition(closed.retryCount == 0 && closed.lifecycleState == .closed)
        let lateEOF = Pane(.telnet)
        lateEOF.bridge.status = "closed"
        lateEOF.bridge.diagnostic = "closed"
        lateEOF.pollRemoteOutputInBackground()
        lateEOF.closeTerminal()
        waitUntil { !lateEOF.isPollingRemoteOutput }
        precondition(lateEOF.lifecycleState == .closed && lateEOF.transcript.isEmpty)
        print("PASS: Telnet reconnect/poll/read errors use the actual protocol; status disconnects, redaction, SSH/serial, initial Telnet diagnostics, transient retries and intentional close remain correct")
        print("PASS: actual sync/async polling drains final Telnet EOF output, stays neutral and retryable without automatic reconnect; real failures, recovery resets and explicit close remain distinct")
    }
}
