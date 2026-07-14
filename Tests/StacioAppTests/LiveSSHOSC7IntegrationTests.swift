import AppKit
import Foundation
import StacioCoreBindings
@testable import StacioApp
import XCTest

final class LiveSSHOSC7IntegrationTests: XCTestCase {
    func testSavedSSHSessionDoesNotExposeOSC7BootstrapOnRealServer() throws {
        let connection = try liveSSHTestConnection()
        let status = try StacioCoreBindings.startLiveSshShellRuntime(
            config: connection.config,
            secret: .password(value: connection.password),
            expectedFingerprintSha256: connection.fingerprint,
            cols: 160,
            rows: 40
        )
        let runtimeID = status.runtimeId
        defer { _ = try? StacioCoreBindings.closeLiveSshShell(runtimeId: runtimeID) }

        var output = Data()
        let startupDeadline = Date().addingTimeInterval(8)
        while Date() < startupDeadline {
            try pollAndDrain(runtimeID: runtimeID, into: &output)
            let text = String(decoding: output, as: UTF8.self)
            if text.contains("\u{1B}]7;file://"),
               text.contains("\(connection.username)@") || text.contains("# ") || text.contains("$ ") {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        try StacioCoreBindings.writeTerminalInput(runtimeId: runtimeID, bytes: Data("\n\n\n".utf8))
        let rapidEnterDeadline = Date().addingTimeInterval(2)
        while Date() < rapidEnterDeadline {
            try pollAndDrain(runtimeID: runtimeID, into: &output)
            Thread.sleep(forTimeInterval: 0.03)
        }

        let visible = String(decoding: output, as: UTF8.self)
        if let dumpPath = ProcessInfo.processInfo.environment["STACIO_LIVE_SSH_OSC7_DUMP"] {
            try output.write(to: URL(fileURLWithPath: dumpPath))
        }
        XCTAssertFalse(
            visible.contains("__stacio_with_timeout"),
            "Visible live SSH output leaked bootstrap timeout helper: \(redactedDiagnosticSnippet(visible))"
        )
        XCTAssertFalse(
            visible.contains("__stacio_report_cwd"),
            "Visible live SSH output leaked bootstrap cwd reporter: \(redactedDiagnosticSnippet(visible))"
        )
        XCTAssertFalse(
            visible.contains("precmd_functions"),
            "Visible live SSH output leaked zsh hook install: \(redactedDiagnosticSnippet(visible))"
        )
        XCTAssertFalse(
            visible.contains("PROMPT_COMMAND"),
            "Visible live SSH output leaked bash hook install: \(redactedDiagnosticSnippet(visible))"
        )
        XCTAssertTrue(
            visible.contains("\u{1B}]7;file://"),
            "Live SSH startup did not report OSC7 current directory: \(redactedDiagnosticSnippet(visible))"
        )
    }

    @MainActor
    func testRemoteTerminalPaneRapidEnterOnRealServerDoesNotWaitForSlowPollCadence() throws {
        let connection = try liveSSHTestConnection()
        let status = try StacioCoreBindings.startLiveSshShellRuntime(
            config: connection.config,
            secret: .password(value: connection.password),
            expectedFingerprintSha256: connection.fingerprint,
            cols: 160,
            rows: 40
        )
        let runtimeID = status.runtimeId
        defer { _ = try? StacioCoreBindings.closeLiveSshShell(runtimeId: runtimeID) }

        let controller = RemoteTerminalPaneViewController(
            runtimeID: runtimeID,
            title: "\(connection.username)@\(connection.host)",
            eventSink: CoreBridgeTerminalEventSink(),
            bridge: CoreBridgeRemoteTerminalBridge()
        )
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        defer { controller.viewWillDisappear() }

        XCTAssertTrue(
            waitForTerminalTranscript(controller: controller, timeout: 8) { transcript in
                transcript.contains("\u{1B}]7;file://")
                    && (transcript.contains("\(connection.username)@")
                        || transcript.contains("# ")
                        || transcript.contains("$ "))
            },
            "Timed out waiting for initial prompt: \(redactedDiagnosticSnippet(controller.terminalOutputTranscript))"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let promptMarker = "STACIO_PROMPT_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        controller.sendInput(Array("export PS1='\(promptMarker) '\n".utf8))
        XCTAssertTrue(
            waitForTerminalTranscript(controller: controller, timeout: 3) { transcript in
                promptOccurrences(of: promptMarker, in: transcript) >= 1
            },
            "Timed out waiting for prompt marker: \(redactedDiagnosticSnippet(controller.terminalOutputTranscript))"
        )
        let baselinePromptCount = promptOccurrences(of: promptMarker, in: controller.terminalOutputTranscript)

        let startedAt = Date()
        let rapidEnterCount = Int(ProcessInfo.processInfo.environment["STACIO_LIVE_SSH_RAPID_ENTER_COUNT"] ?? "") ?? 12
        for _ in 0..<rapidEnterCount {
            controller.sendInput([UInt8(ascii: "\r")])
        }
        XCTAssertTrue(
            waitForTerminalTranscript(controller: controller, timeout: 1.2, step: 0.005) { transcript in
                promptOccurrences(of: promptMarker, in: transcript) >= baselinePromptCount + rapidEnterCount
            },
            "Timed out waiting for rapid-enter prompts: count=\(promptOccurrences(of: promptMarker, in: controller.terminalOutputTranscript)) expected=\(baselinePromptCount + rapidEnterCount) prefix=\(redactedDiagnosticSnippet(controller.terminalOutputTranscript)) suffix=\(redactedDiagnosticTail(controller.terminalOutputTranscript))"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1.2,
            "Rapid-enter prompt rendering fell back to the slow poll cadence."
        )

        let visible = controller.terminalOutputTranscript
        XCTAssertFalse(visible.contains("__stacio_with_timeout"))
        XCTAssertFalse(visible.contains("__stacio_report_cwd"))
        XCTAssertFalse(visible.contains("precmd_functions"))
        XCTAssertFalse(visible.contains("PROMPT_COMMAND"))

        controller.sendInput(Array("cd /tmp\r".utf8))
        XCTAssertTrue(
            waitForTerminalTranscript(controller: controller, timeout: 3) { _ in
                controller.currentRemoteDirectory == "/tmp"
            },
            "Timed out waiting for cd /tmp OSC7 directory update: \(redactedDiagnosticTail(controller.terminalOutputTranscript))"
        )
    }

    private struct LiveSSHTestConnection {
        let host: String
        let username: String
        let config: SshConnectionConfig
        let password: String
        let fingerprint: String
    }

    private func liveSSHTestConnection() throws -> LiveSSHTestConnection {
        let host = ProcessInfo.processInfo.environment["STACIO_LIVE_SSH_OSC7_HOST"] ?? "172.16.10.250"
        guard ProcessInfo.processInfo.environment["STACIO_LIVE_SSH_OSC7_TEST"] == "1" else {
            throw XCTSkip("Set STACIO_LIVE_SSH_OSC7_TEST=1 to run the live SSH OSC7 bootstrap regression.")
        }
        let databasePath = try ProcessInfo.processInfo.environment["STACIO_LIVE_SSH_DATABASE"]
            ?? StacioPaths().databaseURL.path
        let sessions = try StacioCoreBindings.listAllSessionRecords(databasePath: databasePath)
        guard let session = sessions.first(where: { $0.protocol == "ssh" && $0.host == host }) else {
            XCTFail("No saved SSH session found for \(host)")
            throw XCTSkip("Missing saved SSH session.")
        }
        guard let username = session.username,
              let credentialID = session.credentialId
        else {
            XCTFail("Saved SSH session for \(host) is missing username or credential reference.")
            throw XCTSkip("Saved SSH session is incomplete.")
        }
        let config = SshConnectionConfig(
            host: host,
            port: UInt16(session.port),
            username: username,
            authMethod: .password(credentialRef: credentialID),
            connectTimeoutMs: 10_000
        )
        let password = try KeychainCredentialStore().readSecret(
            id: credentialID,
            account: "\(username)@\(host)"
        )
        let fingerprint = try knownHostFingerprint(
            databasePath: databasePath,
            host: host,
            port: UInt16(session.port)
        )
        return LiveSSHTestConnection(
            host: host,
            username: username,
            config: config,
            password: password,
            fingerprint: fingerprint
        )
    }

    private func pollAndDrain(runtimeID: String, into output: inout Data) throws {
        _ = try? StacioCoreBindings.pollLiveSshShell(runtimeId: runtimeID)
        let batch = try StacioCoreBindings.takeTerminalOutputBatch(runtimeId: runtimeID)
        output.append(batch.bytes)
    }

    @MainActor
    private func waitForTerminalTranscript(
        controller: RemoteTerminalPaneViewController,
        timeout: TimeInterval,
        step: TimeInterval = 0.01,
        _ condition: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(controller.terminalOutputTranscript) {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(step))
        }
        return condition(controller.terminalOutputTranscript)
    }

    private func knownHostFingerprint(databasePath: String, host: String, port: UInt16) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-batch",
            "-noheader",
            databasePath,
            "select fingerprint_sha256 from known_hosts where host='\(host)' and port=\(port) limit 1;"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let fingerprint = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, fingerprint.isEmpty == false else {
            throw XCTSkip("No known host fingerprint saved for \(host):\(port).")
        }
        return fingerprint
    }

    private func redactedDiagnosticSnippet(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return String(stripped.prefix(1600))
    }

    private func redactedDiagnosticTail(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return String(stripped.suffix(1600))
    }

    private func promptOccurrences(of marker: String, in text: String) -> Int {
        guard marker.isEmpty == false else {
            return 0
        }
        var count = 0
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            let contextStart = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex)
                ?? text.startIndex
            let contextEnd = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex)
                ?? text.endIndex
            let context = text[contextStart..<contextEnd]
            if context.contains("export PS1") == false {
                count += 1
            }
            searchStart = range.upperBound
        }
        return count
    }
}
