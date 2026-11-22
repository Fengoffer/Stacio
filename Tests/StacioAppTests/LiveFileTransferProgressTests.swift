import AppKit
import CryptoKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class LiveFileTransferProgressTests: XCTestCase {
    func testSFTPReplacesExistingFileAfterVerification() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STACIO_TRANSFER_REAL_SSH"] == "1" else { throw XCTSkip("Requires SSH fixture") }
        let key = try XCTUnwrap(env["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(env["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(host: try XCTUnwrap(env["STACIO_TERMINAL_SSH_HOST"]), port: 22,
            username: try XCTUnwrap(env["STACIO_TERMINAL_SSH_USER"]), authMethod: .privateKey(keyPath: key, passphraseRef: nil), connectTimeoutMs: 5000)
        let secret = SshAuthSecret.privateKey(privateKeyPem: try String(contentsOfFile: key, encoding: .utf8), passphrase: nil)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("replacement payload".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = env["STACIO_TEST_UPLOAD_SOURCE"].map { URL(fileURLWithPath: $0) } ?? tmp
        let size = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let dir = "/tmp/stacio-replace-\(UUID().uuidString)", dst = dir + "/existing"
        func shell(_ command: String) throws -> String {
            let result = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: command)
            XCTAssertEqual(result.exitCode, 0); return result.stdout
        }
        _ = try shell("mkdir \(dir) && printf old > \(dst)")
        defer { try? CoreBridge.deleteLiveSFTPPath(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, remotePath: dir, recursive: true) }
        let job = ScpTransferJob(id: UUID().uuidString, direction: .upload, sourcePath: source.path, destinationPath: dst, bytesTotal: UInt64(size))
        let result = try CoreBridge.runLiveSFTPTransfer(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: job)
        XCTAssertEqual(result.last?.status, "completed")
        let reader = try FileHandle(forReadingFrom: source); defer { try? reader.close() }
        var hash = SHA256()
        while let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        let expected = hash.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(try shell("sha256sum \(dst)").hasPrefix(expected))
        XCTAssertEqual(try shell("ls -A \(dir)"), "existing\n")
    }

    func testConcurrentSCPAndSFTPUploadsReportProgressBeforeRangeCompletion() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STACIO_TRANSFER_REAL_SSH"] == "1" else { throw XCTSkip("Opt-in real SCP/SFTP progress workload") }
        let host = try XCTUnwrap(env["STACIO_TERMINAL_SSH_HOST"])
        let user = try XCTUnwrap(env["STACIO_TERMINAL_SSH_USER"])
        let key = try XCTUnwrap(env["STACIO_TERMINAL_SSH_KEY"])
        let fingerprint = try XCTUnwrap(env["STACIO_TERMINAL_SSH_FINGERPRINT"])
        let config = SshConnectionConfig(host: host, port: 22, username: user, authMethod: .privateKey(keyPath: key, passphraseRef: nil), connectTimeoutMs: 5_000)
        let secret = SshAuthSecret.privateKey(privateKeyPem: try String(contentsOfFile: key, encoding: .utf8), passphrase: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StacioTransferProgress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.bin")
        let block = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var bytes = Data()
        bytes.reserveCapacity(128 * 1024 * 1024)
        for _ in 0..<2048 { bytes.append(block) }
        try bytes.write(to: source)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let queue = TransferQueueViewController(); queue.loadView()
        let files = FilesViewController(); files.loadView()
        files.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let popover = TransferQueuePopoverViewController(); popover.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queue, maxConcurrentTransfers: 2)
        let remoteDirectory = "/tmp/StacioTransferProgress-\(UUID().uuidString)"
        _ = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: "mkdir \(remoteDirectory)")
        let jobs = ["scp", "sftp"].map { transport in
            ScpTransferJob(id: "live-\(transport)-\(UUID().uuidString)", direction: .upload, sourcePath: source.path, destinationPath: "\(remoteDirectory)/\(transport).bin", bytesTotal: UInt64(bytes.count))
        }
        var observations: [String: [(Date, UInt64)]] = [:]
        var finished: [String: ScpTransferProgress] = [:]
        var peakRates: [String: Double] = [:]
        let started = Date()
        coordinator.onSnapshotChanged = { snapshot in
            files.setTransferStatusSnapshot(snapshot)
            popover.apply(snapshot: snapshot)
            for row in snapshot.rows where row.rawStatus == "running" || row.rawStatus == "resuming" {
                if row.bytesDone > 0, observations[row.jobID]?.last?.1 != row.bytesDone {
                    observations[row.jobID, default: []].append((snapshot.capturedAt, row.bytesDone))
                }
                if let speed = popover.rowsForTesting.first(where: { $0.jobID == row.jobID })?.speedText,
                   let value = Double(speed.split(separator: " ").first ?? "") {
                    let units: [String: Double] = ["B/s": 1, "KB/s": 1024, "MB/s": 1_048_576, "GB/s": 1_073_741_824]
                    let rate = value * (units[String(speed.split(separator: " ").last ?? "")] ?? 0)
                    peakRates[row.jobID] = max(peakRates[row.jobID] ?? 0, rate)
                }
            }
        }
        defer {
            jobs.forEach { _ = coordinator.cancelTransfer(jobID: $0.id) }
            let drainDeadline = Date().addingTimeInterval(10)
            while finished.count < jobs.count, Date() < drainDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try? CoreBridge.deleteLiveSFTPPath(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, remotePath: remoteDirectory, recursive: true)
            try? FileManager.default.removeItem(at: directory)
        }
        coordinator.scheduleLiveTransfer(runtimeID: "fixture", config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: jobs[0], notificationPolicy: .silent, completion: { finished[jobs[0].id] = $0 })
        coordinator.scheduleLiveSFTPTransfer(runtimeID: "fixture", config: config, secret: secret, expectedFingerprintSHA256: fingerprint, job: jobs[1], notificationPolicy: .silent, completion: { finished[jobs[1].id] = $0 })
        let deadline = Date().addingTimeInterval(180)
        while finished.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(finished.count, 2)
        for job in jobs {
            XCTAssertEqual(finished[job.id]?.status, "completed")
            let samples = try XCTUnwrap(observations[job.id])
            let first = try XCTUnwrap(samples.first)
            XCTAssertLessThan(first.1, job.bytesTotal / 4, "Progress must arrive before the first range completes")
            XCTAssertLessThan(first.0.timeIntervalSince(started), 10)
            XCTAssertGreaterThan(samples.count, 4)
            XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0.1 < $1.1 })
            let peakRate = try XCTUnwrap(peakRates[job.id])
            let measuredRate = Double(job.bytesTotal - first.1) / samples.last!.0.timeIntervalSince(first.0)
            XCTAssertGreaterThan(peakRate, 0)
            XCTAssertLessThan(peakRate, measuredRate * 2, "Displayed speed must agree with independently timed byte progress")
            let result = try CoreBridge.runLiveRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: fingerprint, command: "sha256sum \(job.destinationPath)")
            XCTAssertTrue(result.stdout.hasPrefix(hash), "Remote file integrity")
            print("TRANSFER_PROGRESS protocol=\(job.id.hasPrefix("live-sftp") ? "sftp" : "scp") first_seconds=\(first.0.timeIntervalSince(started)) first_bytes=\(first.1) updates=\(samples.count) data_seconds=\(samples.last!.0.timeIntervalSince(started)) total_bytes=\(job.bytesTotal) peak_display_MiB_s=\(peakRate / 1_048_576) measured_MiB_s=\(measuredRate / 1_048_576)")
        }
    }
}
