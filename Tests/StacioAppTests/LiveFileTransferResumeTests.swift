import AppKit
import CryptoKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class LiveFileTransferResumeTests: XCTestCase {
    func testSCPAndSFTPAndRemoteTransfersResumeFromVerifiedCheckpoint() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STACIO_TRANSFER_REAL_SSH"] == "1" else { throw XCTSkip("Opt-in real file transfer resume workload") }
        let host = try XCTUnwrap(env["STACIO_TERMINAL_SSH_HOST"])
        let user = try XCTUnwrap(env["STACIO_TERMINAL_SSH_USER"])
        let key = try XCTUnwrap(env["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(env["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(host: host, port: 22, username: user, authMethod: .privateKey(keyPath: key, passphraseRef: nil), connectTimeoutMs: 5_000)
        let secret = SshAuthSecret.privateKey(privateKeyPem: try String(contentsOfFile: key, encoding: .utf8), passphrase: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StacioTransferResume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let block = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var bytes = Data()
        bytes.reserveCapacity(256 * 1024 * 1024)
        for _ in 0..<4096 { bytes.append(block) }
        try bytes.write(to: source)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let remoteDirectory = "/tmp/StacioTransferResume-\(UUID().uuidString)"
        _ = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: "mkdir \(remoteDirectory)")
        defer { try? CoreBridge.deleteLiveSFTPPath(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, remotePath: remoteDirectory, recursive: true) }

        for transport in ["scp", "sftp", "remote"] {
            let job = ScpTransferJob(
                id: "live-resume-\(transport)-\(UUID().uuidString)", direction: .upload,
                sourcePath: transport == "remote" ? "\(remoteDirectory)/sftp.bin" : source.path,
                destinationPath: "\(remoteDirectory)/\(transport).bin", bytesTotal: UInt64(bytes.count)
            )
            let queue = TransferQueueViewController(); queue.loadView()
            let files = FilesViewController(); files.loadView()
            let popover = TransferQueuePopoverViewController(); popover.loadView()
            let coordinator = TransferQueueCoordinator(queueViewController: queue)
            var latest: TransferQueueSnapshot.Row?
            var resumed = false
            var resumedSamples: [UInt64] = []
            var completed: ScpTransferProgress?
            var remoteWorker: LiveRemoteResumeWorker?
            coordinator.onSnapshotChanged = { snapshot in
                files.setTransferStatusSnapshot(snapshot)
                popover.apply(snapshot: snapshot)
                latest = snapshot.rows.first
                if resumed, let row = latest, ["running", "resuming"].contains(row.rawStatus), resumedSamples.last != row.bytesDone {
                    resumedSamples.append(row.bytesDone)
                }
            }
            defer {
                _ = coordinator.cancelTransfer(jobID: job.id)
                remoteWorker?.stop()
                // Drain the asynchronous completion before deleting either endpoint.
                _ = pump(until: { completed != nil }, timeout: 15)
            }
            switch transport {
            case "scp":
                coordinator.scheduleLiveTransfer(runtimeID: "fixture", config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: job, notificationPolicy: .silent, completion: { completed = $0 })
            case "sftp":
                coordinator.scheduleLiveSFTPTransfer(runtimeID: "fixture", config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: job, notificationPolicy: .silent, completion: { completed = $0 })
            default:
                let worker = LiveRemoteResumeWorker()
                remoteWorker = worker
                coordinator.registerExternalTransfer(
                    runtimeID: "fixture", job: job,
                    progressProvider: { (try? CoreBridge.takeLiveSCPTransferProgressBatch(jobID: job.id)) ?? [] },
                    resume: { worker.resume(); return true },
                    cancel: { worker.stop(); return (try? CoreBridge.cancelLiveSCPTransfer(jobID: job.id)) ?? false },
                    pauseWithProgress: { worker.pause(); return StacioCoreBindings.pauseLiveScpTransfer(jobId: job.id) }
                )
                DispatchQueue.global(qos: .utility).async {
                    let status = worker.run {
                        _ = try CoreBridge.runLiveRemoteToRemoteTransfer(
                            sourceConfig: config, sourceSecret: secret, sourceExpectedFingerprintSHA256: fingerprint,
                            destinationConfig: config, destinationSecret: secret, destinationExpectedFingerprintSHA256: fingerprint,
                            request: .init(job: job, sourceProtocol: .scp, destinationProtocol: .sftp, requestedOffset: 0, forceRestart: false, chunkSizeBytes: 1_048_576, workerCount: 4)
                        )
                    }
                    Task { @MainActor in
                        completed = .init(jobId: job.id, bytesDone: status == "completed" ? job.bytesTotal : 0, bytesTotal: job.bytesTotal, status: status)
                        coordinator.finishExternalTransfer(jobID: job.id, status: status, bytesDone: completed!.bytesDone)
                    }
                }
            }
            XCTAssertTrue(pump(until: { (latest?.bytesDone ?? 0) > 0 || completed != nil }, timeout: 20))
            let lastRendered = try XCTUnwrap(latest?.bytesDone)
            XCTAssertGreaterThan(lastRendered, 0)
            XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
            let pausedBytes = try XCTUnwrap(latest?.bytesDone)
            XCTAssertGreaterThanOrEqual(pausedBytes, lastRendered)
            XCTAssertLessThan(pausedBytes, job.bytesTotal / 4, "Pause before any range can be committed")
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(latest?.rawStatus, "paused")
            XCTAssertEqual(latest?.bytesDone, pausedBytes)
            resumed = true
            XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
            XCTAssertTrue(pump(until: { completed != nil }, timeout: 180))
            XCTAssertEqual(completed?.status, "completed")
            let checkpoint = try XCTUnwrap(resumedSamples.first(where: { $0 < pausedBytes }), "The real checkpoint must replace partial, uncommitted bytes")
            let fromCheckpoint = Array(resumedSamples.drop(while: { $0 >= pausedBytes }))
            XCTAssertGreaterThan(fromCheckpoint.count, 2, "Progress must continue after the checkpoint rollback")
            XCTAssertTrue(zip(fromCheckpoint, fromCheckpoint.dropFirst()).allSatisfy { $0 <= $1 })
            let result = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: "sha256sum \(job.destinationPath)")
            XCTAssertTrue(result.stdout.hasPrefix(hash))
            print("TRANSFER_RESUME protocol=\(transport) paused_bytes=\(pausedBytes) checkpoint_bytes=\(checkpoint) updates_after_checkpoint=\(fromCheckpoint.count) sha256=matched")
        }
    }

    func testDirectoryUploadReportsVerifiedStartForSCPAndSFTP() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STACIO_TRANSFER_REAL_SSH"] == "1" else { throw XCTSkip() }
        let key = try XCTUnwrap(env["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(env["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(host: try XCTUnwrap(env["STACIO_TERMINAL_SSH_HOST"]), port: 22, username: try XCTUnwrap(env["STACIO_TERMINAL_SSH_USER"]), authMethod: .privateKey(keyPath: key, passphraseRef: nil), connectTimeoutMs: 5_000)
        let secret = SshAuthSecret.privateKey(privateKeyPem: try String(contentsOfFile: key, encoding: .utf8), passphrase: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data(repeating: 91, count: 4 * 1_048_576)
        try data.write(to: dir.appendingPathComponent("a.bin"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let remote = "/tmp/stacio-review-dir-\(UUID().uuidString)"
        _ = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: "mkdir \(remote)")
        defer { try? CoreBridge.deleteLiveSFTPPath(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, remotePath: remote, recursive: true) }
        for kind in ["scp", "sftp"] {
            let dest = "\(remote)/\(kind)"
            let job = ScpTransferJob(id: UUID().uuidString, direction: .upload, sourcePath: dir.path, destinationPath: dest, bytesTotal: UInt64(data.count))
            let options = ScpResumeOptions(requestedOffset: 3 * 1_048_576, forceRestart: false)
            let report = try kind == "scp" ? CoreBridge.runLiveSCPTransfer(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: job, resumeOptions: options) : CoreBridge.runLiveSFTPTransfer(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: job, resumeOptions: options)
            let verified = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: "sha256sum \(dest)/a.bin")
            XCTAssertTrue(verified.stdout.hasPrefix(hash), verified.stdout)
            print("TRANSFER_DIR kind=\(kind) first=\(report.first?.bytesDone ?? 0) completed=\(report.last?.bytesDone ?? 0) sha256=\(verified.stdout.hasPrefix(hash))")
            XCTAssertEqual(report.first?.bytesDone, 0, kind)
        }
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
}

private final class LiveRemoteResumeWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var pauseRequested = false
    private var resumeRequested = false
    private var stopped = false
    private var didFinish = false
    var finished: Bool { condition.lock(); defer { condition.unlock() }; return didFinish }
    func pause() { condition.lock(); pauseRequested = true; resumeRequested = false; condition.unlock() }
    func resume() { condition.lock(); resumeRequested = true; condition.broadcast(); condition.unlock() }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func run(_ transfer: () throws -> Void) -> String {
        defer { condition.lock(); didFinish = true; condition.unlock() }
        while true {
            do { try transfer(); return "completed" }
            catch {
                condition.lock()
                guard pauseRequested else { condition.unlock(); return "failed" }
                while !resumeRequested && !stopped { condition.wait() }
                let shouldStop = stopped
                pauseRequested = false; resumeRequested = false
                condition.unlock()
                if shouldStop { return "canceled" }
            }
        }
    }
}
