import XCTest
@testable import StacioApp
import StacioCoreBindings

final class TransferBridgeTests: XCTestCase {
    func testRemoteListingParserIsAvailableFromSwift() throws {
        let entries = try CoreBridge.parseRemoteListing("file\t/etc/hosts\t128")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "/etc/hosts")
        XCTAssertEqual(entries[0].size, 128)
        XCTAssertEqual(entries[0].kind, .file)
    }

    func testConflictResolutionIsAvailableFromSwift() throws {
        let resolved = CoreBridge.resolveSCPConflictPath(
            destinationPath: "/tmp/file.txt",
            policy: .keepBoth
        )

        XCTAssertEqual(resolved, "/tmp/file (copy).txt")
    }

    func testSimulatedSCPTransferProgressIsAvailableFromSwift() throws {
        let job = ScpTransferJob(
            id: "job_test",
            direction: .upload,
            sourcePath: "/local/file.txt",
            destinationPath: "/remote/file.txt",
            bytesTotal: 100
        )

        let progress = try CoreBridge.simulateSCPTransfer(job)

        XCTAssertEqual(progress.last?.jobId, "job_test")
        XCTAssertEqual(progress.last?.bytesDone, 100)
        XCTAssertEqual(progress.last?.status, "completed")
    }

    func testLiveSCPTransferRejectsInvalidConfigBeforeNetwork() {
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_live_invalid",
            direction: .download,
            sourcePath: "/remote/file.txt",
            destinationPath: "/local/file.txt",
            bytesTotal: 0
        )

        XCTAssertThrowsError(
            try CoreBridge.runLiveSCPTransfer(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                job: job
            )
        )
    }

    func testLiveFTPTransferRejectsInvalidConfigBeforeNetworkAndRedactsSecret() {
        let config = FtpConnectionConfig(
            host: "",
            port: 21,
            username: "deploy",
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "ftp_invalid_swift",
            direction: .download,
            sourcePath: "/pub/file.txt",
            destinationPath: "/Users/alice/file.txt",
            bytesTotal: 0
        )

        XCTAssertThrowsError(
            try CoreBridge.runLiveFTPTransfer(
                config: config,
                secret: .password(value: "ftp-secret"),
                job: job
            )
        ) { error in
            XCTAssertFalse(String(describing: error).contains("ftp-secret"))
        }
    }

    func testLiveSCPCancelBridgeIsAvailableFromSwift() throws {
        XCTAssertTrue(try CoreBridge.cancelLiveSCPTransfer(jobID: "job_cancel_bridge"))
        XCTAssertFalse(try CoreBridge.cancelLiveSCPTransfer(jobID: "   "))
    }

    func testLiveFTPCancelBridgeIsAvailableFromSwift() throws {
        XCTAssertTrue(try CoreBridge.cancelLiveFTPTransfer(jobID: "ftp_cancel_bridge"))
        XCTAssertFalse(try CoreBridge.cancelLiveFTPTransfer(jobID: "   "))
    }

    func testLiveSCPProgressBatchBridgeIsAvailableFromSwift() throws {
        let progress = try CoreBridge.takeLiveSCPTransferProgressBatch(jobID: "job_missing_progress")

        XCTAssertEqual(progress, [])
    }

    func testLiveRemoteDirectoryListingRejectsInvalidConfigBeforeNetwork() {
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        XCTAssertThrowsError(
            try CoreBridge.listLiveRemoteDirectory(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                remotePath: "/var/log"
            )
        )
    }

    func testLiveRemoteFileOperationsRejectInvalidConfigBeforeNetwork() {
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        XCTAssertThrowsError(
            try CoreBridge.createLiveRemoteDirectory(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                remotePath: "/srv/app/new"
            )
        )
        XCTAssertThrowsError(
            try CoreBridge.renameLiveRemotePath(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                fromPath: "/srv/app/old",
                toPath: "/srv/app/new"
            )
        )
        XCTAssertThrowsError(
            try CoreBridge.deleteLiveRemotePath(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                remotePath: "/srv/app/tmp",
                recursive: true
            )
        )
        XCTAssertThrowsError(
            try CoreBridge.chmodLiveRemotePath(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                remotePath: "/srv/app/run.sh",
                mode: "755"
            )
        )
        XCTAssertThrowsError(
            try CoreBridge.readLiveRemoteFile(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                remotePath: "/srv/app/config.json",
                offset: 0,
                length: nil
            )
        )
        XCTAssertThrowsError(
            try CoreBridge.writeLiveRemoteFile(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                remotePath: "/srv/app/config.json",
                contents: Data("enabled=true\n".utf8)
            )
        )
    }

    func testTransferHistoryPersistenceIsAvailableFromSwift() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let job = ScpTransferJob(
            id: "job_history_swift",
            direction: .download,
            sourcePath: "/srv/logs/app.log",
            destinationPath: "/Users/alice/app.log",
            bytesTotal: 200
        )
        let progress = ScpTransferProgress(
            jobId: job.id,
            bytesDone: 200,
            bytesTotal: 200,
            status: "completed"
        )

        try CoreBridge.recordSCPTransferJob(
            databasePath: tempURL.path,
            sessionID: nil,
            job: job,
            status: "queued",
            bytesDone: 0
        )
        let appendedEvent = try CoreBridge.appendSCPTransferProgress(
            databasePath: tempURL.path,
            progress: progress
        )

        let jobs = try CoreBridge.listSCPTransferJobs(databasePath: tempURL.path)
        let events = try CoreBridge.listSCPTransferEvents(databasePath: tempURL.path, jobID: job.id)

        XCTAssertEqual(appendedEvent.eventType, "completed")
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].job, job)
        XCTAssertEqual(jobs[0].status, "completed")
        XCTAssertEqual(jobs[0].bytesDone, 200)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, "completed")
        XCTAssertFalse(String(describing: jobs).contains("password"))
        XCTAssertFalse(String(describing: events).contains("scp "))
    }

    func testTransferHistoryClearsFinishedJobsFromSwift() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let completedJob = ScpTransferJob(
            id: "job_history_completed_clear",
            direction: .upload,
            sourcePath: "/Users/alice/completed.zip",
            destinationPath: "/srv/completed.zip",
            bytesTotal: 100
        )
        let queuedJob = ScpTransferJob(
            id: "job_history_queued_keep",
            direction: .download,
            sourcePath: "/srv/queued.zip",
            destinationPath: "/Users/alice/queued.zip",
            bytesTotal: 200
        )

        try CoreBridge.recordSCPTransferJob(
            databasePath: tempURL.path,
            sessionID: nil,
            job: completedJob,
            status: "queued",
            bytesDone: 0
        )
        _ = try CoreBridge.appendSCPTransferProgress(
            databasePath: tempURL.path,
            progress: ScpTransferProgress(
                jobId: completedJob.id,
                bytesDone: 100,
                bytesTotal: 100,
                status: "completed"
            )
        )
        try CoreBridge.recordSCPTransferJob(
            databasePath: tempURL.path,
            sessionID: nil,
            job: queuedJob,
            status: "queued",
            bytesDone: 0
        )

        let clearedCount = try CoreBridge.clearFinishedSCPTransferJobs(databasePath: tempURL.path)
        let jobs = try CoreBridge.listSCPTransferJobs(databasePath: tempURL.path)
        let completedEvents = try CoreBridge.listSCPTransferEvents(
            databasePath: tempURL.path,
            jobID: completedJob.id
        )

        XCTAssertEqual(clearedCount, 1)
        XCTAssertEqual(jobs.map(\.job), [queuedJob])
        XCTAssertEqual(completedEvents, [])
    }

    func testTransferHistoryPersistsFailureMessageFromSwift() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let job = ScpTransferJob(
            id: "job_history_message",
            direction: .upload,
            sourcePath: "/local/file.txt",
            destinationPath: "/remote/file.txt",
            bytesTotal: 100
        )
        let progress = ScpTransferProgress(
            jobId: job.id,
            bytesDone: 40,
            bytesTotal: 100,
            status: "failed"
        )

        try CoreBridge.recordSCPTransferJob(
            databasePath: tempURL.path,
            sessionID: nil,
            job: job,
            status: "queued",
            bytesDone: 0
        )
        let appendedEvent = try CoreBridge.appendSCPTransferProgress(
            databasePath: tempURL.path,
            progress: progress,
            message: "Permission denied"
        )
        let events = try CoreBridge.listSCPTransferEvents(databasePath: tempURL.path, jobID: job.id)

        XCTAssertEqual(appendedEvent.message, "Permission denied")
        XCTAssertEqual(events[0].message, "Permission denied")
    }
}
