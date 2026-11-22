import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class LiveDirectoryRecoveryTests: XCTestCase {
    func testReplacementPublishesOnlyCurrentTree() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STACIO_TRANSFER_REAL_SSH"] == "1" else { throw XCTSkip("Requires the SSH test VM") }
        let key = try XCTUnwrap(env["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(env["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(host: try XCTUnwrap(env["STACIO_TERMINAL_SSH_HOST"]), port: 22,
            username: try XCTUnwrap(env["STACIO_TERMINAL_SSH_USER"]), authMethod: .privateKey(keyPath: key, passphraseRef: nil), connectTimeoutMs: 5000)
        let secret = SshAuthSecret.privateKey(privateKeyPem: try String(contentsOfFile: key, encoding: .utf8), passphrase: nil)
        let context = TunnelLiveSessionContext(config: config, secret: secret, expectedFingerprintSHA256: fingerprint)
        let root = "/tmp/stacio-dir-recovery-\(UUID().uuidString)"
        func shell(_ command: String) throws -> String {
            let result = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: command)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let src = root + "/source", out = root + "/out", target = out + "/source"
        _ = try shell("mkdir -p \(src) \(target) && echo first > \(src)/first")
        defer { try? CoreBridge.deleteLiveSFTPPath(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, remotePath: root, recursive: true) }
        let view = TransferQueueViewController(); view.loadView()
        let queue = TransferQueueCoordinator(queueViewController: view)
        let mgr = CrossDeviceTransferCoordinator(remoteTransferBridge: CoreBridgeRemoteToRemoteTransferBridge())
        let fs = CoreBridgeRemoteFilesBridge()
        let endpoint = CrossDeviceRemoteEndpoint(runtimeID: "vm", title: "vm", context: context, bridge: fs, transferScheduler: queue)
        func transfer() async throws {
            var status: CrossDeviceTransferStatus?
            let id = mgr.transfer([.init(path: src, size: 0, kind: .directory)], from: endpoint, to: endpoint,
                destinationDirectory: out, operation: .copy, conflictResolution: .replace) { status = $0 }
            defer { _ = mgr.cancel(operationID: id) }
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                if status == .completed { return }
                if case .failed(let reason) = status { XCTFail(reason); return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("Directory replacement did not complete")
        }
        try await transfer()
        let destFile = try XCTUnwrap(view.snapshotForTesting.rows.first?.destinationPath)
        let stage = (destFile as NSString).deletingLastPathComponent
        guard stage.hasPrefix(out + "/.source.stacio-transfer-"), stage.hasSuffix(".partial") else {
            return XCTFail("Unexpected staging path: \(stage)")
        }
        _ = try shell("mkdir -p \(stage)/old-dir \(stage)/nested \(src)/nested && touch \(stage)/old-dir/x \(stage)/nested/deleted && echo current > \(src)/nested/live")
        try await transfer()
        XCTAssertEqual(try shell("find \(target) -mindepth 1 -printf '%P\\n' | sort"), "first\nnested\nnested/live")
        XCTAssertEqual(try shell("cat \(target)/nested/live"), "current")
        _ = try shell("rm -r \(src)/nested \(src)/first && mkdir -p \(stage)/old-dir && touch \(stage)/old-dir/x")
        try await transfer()
        XCTAssertEqual(try shell("find \(target) -mindepth 1 -print"), "")

        let nfc = "\u{00E9}", nfd = "e\u{0301}"
        _ = try shell("mkdir -p \(stage) \(src)/d\(nfc) \(src)/d\(nfd) && printf A > \(src)/\(nfc) && printf B > \(src)/\(nfd) && printf C > \(src)/d\(nfc)/one && printf D > \(src)/d\(nfd)/two")
        try await transfer()
        XCTAssertEqual(try shell("cat \(target)/\(nfc) \(target)/\(nfd) \(target)/d\(nfc)/one \(target)/d\(nfd)/two"), "ABCD")

        let gate = DirectoryRecoveryGate()
        let parent = CrossDeviceTransferCoordinator(remoteTransferBridge: gate)
        var parentStatus: CrossDeviceTransferStatus?
        let parentID = parent.transfer([.init(path: src, size: 0, kind: .directory)], from: endpoint, to: endpoint,
            destinationDirectory: out, operation: .copy, conflictResolution: .replace) { parentStatus = $0 }
        defer { gate.release(); _ = parent.cancel(operationID: parentID) }
        let deadline = Date().addingTimeInterval(30)
        while !gate.started && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard gate.started else { return XCTFail("Parent did not enter transfer") }
        _ = try shell("printf child > \(root)/extra")
        func child(to directory: String) async throws -> CrossDeviceTransferStatus? {
            var status: CrossDeviceTransferStatus?
            let id = mgr.transfer([.init(path: root + "/extra", size: 5)], from: endpoint, to: endpoint,
                destinationDirectory: directory, operation: .copy, conflictResolution: .replace) { status = $0 }
            defer { _ = mgr.cancel(operationID: id) }
            let end = Date().addingTimeInterval(20)
            while Date() < end {
                if case .failed = status { return status }
                if status == .completed { return status }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return status
        }
        guard case .failed(let reason) = try await child(to: target), reason.contains("目标路径") else {
            return XCTFail("A child transfer must be rejected while its parent destination is reserved")
        }
        _ = try shell("test ! -e \(target)/extra && mkdir \(target)-sibling")
        let sibling = try await child(to: target + "-sibling")
        XCTAssertEqual(sibling, .completed)
        gate.release()
        let end = Date().addingTimeInterval(30)
        while parentStatus != .completed && Date() < end {
            if case .failed(let reason) = parentStatus { return XCTFail(reason) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(parentStatus, .completed)
        let retried = try await child(to: target)
        XCTAssertEqual(retried, .completed)
        XCTAssertEqual(try shell("cat \(target)/extra \(target)-sibling/extra"), "childchild")
    }
}

private final class DirectoryRecoveryGate: RemoteToRemoteTransferBridging, @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, open = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
    func cancelLiveRemoteToRemoteTransfer(jobID: String) -> Bool {
        release()
        return (try? CoreBridge.cancelLiveSCPTransfer(jobID: jobID)) ?? false
    }
    func runLiveRemoteToRemoteTransfer(sourceConfig: SshConnectionConfig, sourceSecret: SshAuthSecret,
        sourceExpectedFingerprintSHA256: String, destinationConfig: SshConnectionConfig,
        destinationSecret: SshAuthSecret, destinationExpectedFingerprintSHA256: String,
        request: RemoteToRemoteTransferRequest) throws -> RemoteToRemoteTransferReport {
        condition.lock(); entered = true
        let deadline = Date().addingTimeInterval(60)
        while !open, condition.wait(until: deadline) {}
        condition.unlock()
        return try CoreBridge.runLiveRemoteToRemoteTransfer(sourceConfig: sourceConfig, sourceSecret: sourceSecret,
            sourceExpectedFingerprintSHA256: sourceExpectedFingerprintSHA256, destinationConfig: destinationConfig,
            destinationSecret: destinationSecret, destinationExpectedFingerprintSHA256: destinationExpectedFingerprintSHA256, request: request)
    }
}
