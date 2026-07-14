import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class TransferQueueCoordinatorTests: XCTestCase {
    func testCoordinatorPublishesEstimatedByteTotalForQueuedUnknownSizeUpload() {
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            "job_unknown_size_upload": [
                ScpTransferProgress(
                    jobId: "job_unknown_size_upload",
                    bytesDone: 96,
                    bytesTotal: 96,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: RecordingTransferHistoryStore(),
            queueViewController: queue
        )
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        let job = ScpTransferJob(
            id: "job_unknown_size_upload",
            direction: .upload,
            sourcePath: "/Users/alice/release",
            destinationPath: "/srv/release",
            bytesTotal: 0
        )

        coordinator.scheduleLiveTransfer(
            config: SshConnectionConfig(
                host: "example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        coordinator.updateScheduledTransferEstimatedByteTotal(jobID: job.id, bytesTotal: 96)

        XCTAssertTrue(snapshots.contains { $0.rows.first?.bytesTotal == 0 })
        XCTAssertEqual(snapshots.last?.rows.first?.bytesTotal, 96)
        XCTAssertEqual(queue.tableView.progressText(row: 0), "0%")
        bridge.release(jobID: job.id)
    }

    func testCoordinatorRunsLiveSCPTransferAndUpdatesQueueView() throws {
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(jobId: "job_upload_1", bytesDone: 0, bytesTotal: 100, status: "running"),
            ScpTransferProgress(jobId: "job_upload_1", bytesDone: 100, bytesTotal: 100, status: "completed")
        ])
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_upload_1",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )

        let progress = try coordinator.runLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        XCTAssertEqual(progress.last?.status, "completed")
        XCTAssertEqual(bridge.events, ["run:job_upload_1"])
        XCTAssertEqual(history.events, [
            "record:job_upload_1:queued:0",
            "progress:job_upload_1:running:0",
            "progress:job_upload_1:completed:100"
        ])
        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.latestStatusText, "已完成")
        XCTAssertEqual(queue.tableView.fileText(row: 0), "app.tar.gz")
        XCTAssertEqual(queue.tableView.progressText(row: 0), "100%")
        XCTAssertFalse(queue.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
        XCTAssertFalse(bridge.debugDescription.contains("scp "))
        XCTAssertFalse(bridge.debugDescription.contains("sftp "))
        XCTAssertFalse(bridge.debugDescription.contains("rsync "))
    }

    func testCoordinatorShowsLargeFileEstimateBeforeStartingSCPTransfer() async {
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            "job_large_file_warning": [
                ScpTransferProgress(
                    jobId: "job_large_file_warning",
                    bytesDone: 150 * 1024 * 1024,
                    bytesTotal: 150 * 1024 * 1024,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_large_file_warning",
            direction: .download,
            sourcePath: "/srv/releases/large.dmg",
            destinationPath: "/Users/alice/Downloads/large.dmg",
            bytesTotal: 150 * 1024 * 1024
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        defer { bridge.release(jobID: job.id) }

        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let detail = queue.selectedTransferDetailTextForTesting
        XCTAssertTrue(detail.contains("大文件"))
        XCTAssertTrue(detail.contains("预计"))
        XCTAssertTrue(detail.contains("150 MB"))
    }

    func testCoordinatorRejectsMismatchedImmediateSCPCompletionProgress() throws {
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(jobId: "other_job", bytesDone: 100, bytesTotal: 100, status: "completed")
        ])
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_immediate_mismatch",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )

        let progress = try coordinator.runLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        XCTAssertEqual(progress.map(\.jobId), [job.id])
        XCTAssertEqual(progress.last?.status, "failed")
        XCTAssertEqual(queue.latestStatusText, "失败")
        XCTAssertFalse(history.events.contains { $0.contains("other_job") })
        XCTAssertEqual(history.events, [
            "record:job_immediate_mismatch:queued:0",
            "progress:job_immediate_mismatch:failed:0:传输失败"
        ])
    }

    func testCoordinatorRunsLiveFTPTransferAndUpdatesQueueViewWithoutSFTP() throws {
        let scpBridge = RecordingSCPTransferBridge()
        let ftpBridge = RecordingFTPTransferBridge(progress: [
            ScpTransferProgress(jobId: "ftp_download_1", bytesDone: 0, bytesTotal: 64, status: "running"),
            ScpTransferProgress(jobId: "ftp_download_1", bytesDone: 64, bytesTotal: 64, status: "completed")
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            ftpBridge: ftpBridge,
            queueViewController: queue
        )
        let config = FtpConnectionConfig(
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "ftp_download_1",
            direction: .download,
            sourcePath: "/pub/readme.txt",
            destinationPath: "/Users/alice/readme.txt",
            bytesTotal: 64
        )

        let progress = try coordinator.runLiveFTPTransfer(
            config: config,
            secret: .password(value: "ftp-secret"),
            job: job
        )

        XCTAssertEqual(progress.last?.status, "completed")
        XCTAssertEqual(ftpBridge.events, ["run:ftp_download_1"])
        XCTAssertEqual(scpBridge.events, [])
        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.latestStatusText, "已完成")
        XCTAssertEqual(queue.tableView.fileText(row: 0), "readme.txt")
        XCTAssertFalse(queue.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
        XCTAssertFalse(ftpBridge.debugDescription.contains("ftp-secret"))
        XCTAssertFalse(ftpBridge.debugDescription.contains("sftp "))
    }

    func testCoordinatorRejectsMismatchedImmediateFTPCompletionProgress() throws {
        let scpBridge = RecordingSCPTransferBridge()
        let ftpBridge = RecordingFTPTransferBridge(progress: [
            ScpTransferProgress(jobId: "other_ftp_job", bytesDone: 64, bytesTotal: 64, status: "completed")
        ])
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            ftpBridge: ftpBridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = FtpConnectionConfig(
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "ftp_immediate_mismatch",
            direction: .download,
            sourcePath: "/pub/readme.txt",
            destinationPath: "/Users/alice/readme.txt",
            bytesTotal: 64
        )

        let progress = try coordinator.runLiveFTPTransfer(
            config: config,
            secret: .password(value: "ftp-secret"),
            job: job
        )

        XCTAssertEqual(progress.map(\.jobId), [job.id])
        XCTAssertEqual(progress.last?.status, "failed")
        XCTAssertEqual(queue.latestStatusText, "失败")
        XCTAssertFalse(history.events.contains { $0.contains("other_ftp_job") })
        XCTAssertEqual(history.events, [
            "record:ftp_immediate_mismatch:queued:0",
            "progress:ftp_immediate_mismatch:failed:0:传输失败"
        ])
        XCTAssertFalse(ftpBridge.debugDescription.contains("ftp-secret"))
    }

    func testCoordinatorSchedulesLiveFTPTransferInBackgroundAndUpdatesQueueWithoutSFTP() async {
        let scpBridge = RecordingSCPTransferBridge()
        let ftpBridge = DelayedFTPTransferBridge(
            delay: 0.2,
            progress: [
                ScpTransferProgress(jobId: "ftp_background_download", bytesDone: 64, bytesTotal: 64, status: "completed")
            ]
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            ftpBridge: ftpBridge,
            queueViewController: queue
        )
        let config = FtpConnectionConfig(
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "ftp_background_download",
            direction: .download,
            sourcePath: "/pub/readme.txt",
            destinationPath: "/Users/alice/readme.txt",
            bytesTotal: 64
        )

        coordinator.scheduleLiveFTPTransfer(
            config: config,
            secret: .password(value: "ftp-secret"),
            job: job
        )

        XCTAssertEqual(scpBridge.events, [])
        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "传输中")
        XCTAssertFalse(queue.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(ftpBridge.events, ["run:ftp_background_download"])
        XCTAssertEqual(queue.tableView.progressText(row: 0), "100%")
        XCTAssertFalse(ftpBridge.debugDescription.contains("ftp-secret"))
    }

    func testCoordinatorCallsScheduledSCPCompletionAfterBackgroundTransferCompletes() async {
        let bridge = RecordingSequenceSCPTransferBridge(results: [
            .success([
                ScpTransferProgress(
                    jobId: "remote_edit_download_1",
                    bytesDone: 64,
                    bytesTotal: 64,
                    status: "completed"
                )
            ])
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "remote_edit_download_1",
            direction: .download,
            sourcePath: "/srv/app/config.json",
            destinationPath: "/Users/alice/Library/Application Support/Stacio/Remote Edits/config.json",
            bytesTotal: 64
        )
        var completedStatuses: [String] = []

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job,
            completion: { progress in
                completedStatuses.append(progress.status)
            }
        )

        let completed = await eventually {
            completedStatuses == ["completed"]
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已完成")
    }

    func testCoordinatorRejectsMismatchedScheduledSCPCompletionProgress() async {
        let bridge = RecordingSequenceSCPTransferBridge(results: [
            .success([
                ScpTransferProgress(
                    jobId: "other_job",
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ])
        ])
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_mismatch_result",
            direction: .download,
            sourcePath: "/srv/app.tar.gz",
            destinationPath: "/Users/alice/app.tar.gz",
            bytesTotal: 100
        )
        var callbackEvents: [String] = []

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job,
            completion: { progress in
                callbackEvents.append("\(progress.jobId):\(progress.status)")
            }
        )

        let failed = await eventually {
            queue.tableView.statusText(row: 0) == "失败"
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(callbackEvents, ["job_mismatch_result:failed"])
        XCTAssertEqual(queue.tableView.progressText(row: 0), "0%")
        XCTAssertFalse(history.events.contains { $0.contains("other_job") })
        XCTAssertEqual(history.events, [
            "record:job_mismatch_result:queued:0",
            "progress:job_mismatch_result:running:0",
            "progress:job_mismatch_result:failed:0:传输失败"
        ])
    }

    func testCoordinatorCancelsRunningFTPTransferAndIgnoresLateCompletion() async {
        let ftpBridge = DelayedFTPTransferBridge(
            delay: 0.2,
            progress: [
                ScpTransferProgress(jobId: "ftp_background_cancel", bytesDone: 64, bytesTotal: 64, status: "completed")
            ]
        )
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            ftpBridge: ftpBridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = FtpConnectionConfig(
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "ftp_background_cancel",
            direction: .upload,
            sourcePath: "/Users/alice/readme.txt",
            destinationPath: "/pub/readme.txt",
            bytesTotal: 64
        )

        coordinator.scheduleLiveFTPTransfer(
            config: config,
            secret: .password(value: "ftp-secret"),
            job: job
        )

        let started = await eventually { ftpBridge.events == ["run:ftp_background_cancel"] }
        XCTAssertTrue(started)
        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已取消")
        XCTAssertEqual(ftpBridge.cancelledJobIDs, [job.id])

        let finished = await eventually { ftpBridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(finished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已取消")
        XCTAssertEqual(history.events, [
            "record:ftp_background_cancel:queued:0",
            "progress:ftp_background_cancel:running:0",
            "progress:ftp_background_cancel:canceled:0"
        ])
        XCTAssertFalse(queue.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testCoordinatorMarksFailedStateWhenLiveTransferFails() {
        let bridge = RecordingSCPTransferBridge(error: SshRuntimeError.InvalidConfig)
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_invalid",
            direction: .download,
            sourcePath: "/remote/file.txt",
            destinationPath: "/local/file.txt",
            bytesTotal: 0
        )

        XCTAssertThrowsError(
            try coordinator.runLiveTransfer(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                job: job
            )
        )

        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.latestStatusText, "失败")
        XCTAssertEqual(queue.tableView.progressText(row: 0), "0%")
    }

    func testCoordinatorRecordsFailureDiagnosticWithoutSecretsWhenLiveTransferFails() {
        let bridge = RecordingSCPTransferBridge(
            error: SshRuntimeError.Transport(message: "credential secret-ref failed at /Users/me/.ssh/id_ed25519")
        )
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_failed_diagnostic",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )

        XCTAssertThrowsError(
            try coordinator.runLiveTransfer(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                job: job
            )
        )

        XCTAssertEqual(queue.tableView.statusText(row: 0), "失败")
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("[已隐藏凭据] 失败位置 [已隐藏路径]"))
        XCTAssertEqual(history.events, [
            "record:job_failed_diagnostic:queued:0",
            "progress:job_failed_diagnostic:failed:0:[已隐藏凭据] 失败位置 [已隐藏路径]"
        ])
    }

    func testCoordinatorRetriesFailedTransferWithoutPersistingSecretInBridgeDebugOutput() throws {
        let bridge = RecordingSCPTransferBridge(results: [
            .failure(SshRuntimeError.InvalidConfig),
            .success([
                ScpTransferProgress(jobId: "job_retry", bytesDone: 100, bytesTotal: 100, status: "completed")
            ])
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .password(credentialRef: "credential:retry"),
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_retry",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )

        XCTAssertThrowsError(
            try coordinator.runLiveTransfer(
                config: config,
                secret: .password(value: "top-secret-password"),
                expectedFingerprintSHA256: "SHA256:test",
                job: job
            )
        )
        XCTAssertEqual(queue.latestStatusText, "失败")

        let progress = try coordinator.retryLiveTransfer(
            config: config,
            secret: .password(value: "top-secret-password"),
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        XCTAssertEqual(progress.last?.status, "completed")
        XCTAssertEqual(bridge.events, ["run:job_retry", "run:job_retry"])
        XCTAssertEqual(queue.latestStatusText, "已完成")
        XCTAssertFalse(bridge.debugDescription.contains("top-secret-password"))
    }

    func testCoordinatorClearsFailureDiagnosticWhenRetrySucceeds() throws {
        let bridge = RecordingSCPTransferBridge(results: [
            .failure(SshRuntimeError.AuthFailed),
            .success([
                ScpTransferProgress(jobId: "job_retry_diagnostic", bytesDone: 100, bytesTotal: 100, status: "completed")
            ])
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "job_retry_diagnostic",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )

        XCTAssertThrowsError(
            try coordinator.runLiveTransfer(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                job: job
            )
        )
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("认证失败"))

        _ = try coordinator.retryLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        XCTAssertEqual(queue.tableView.statusText(row: 0), "已完成")
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertFalse(queue.selectedTransferDetailTextForTesting.contains("认证失败"))
    }

    func testCoordinatorCancelsQueuedTransferWithoutRunningBridge() {
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(jobId: "job_queued_cancel", bytesDone: 100, bytesTotal: 100, status: "completed")
        ])
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let job = ScpTransferJob(
            id: "job_queued_cancel",
            direction: .download,
            sourcePath: "/remote/archive.tar",
            destinationPath: "/local/archive.tar",
            bytesTotal: 100
        )

        coordinator.enqueueTransfer(job: job)
        let didCancel = coordinator.cancelTransfer(jobID: job.id)

        XCTAssertTrue(didCancel)
        XCTAssertEqual(bridge.events, [])
        XCTAssertEqual(history.events, [
            "record:job_queued_cancel:queued:0",
            "progress:job_queued_cancel:canceled:0"
        ])
        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.latestStatusText, "已取消")
        XCTAssertEqual(queue.tableView.progressText(row: 0), "0%")
    }

    func testCoordinatorSchedulesLiveTransfersOneAtATimeInBackground() async {
        let firstJob = ScpTransferJob(
            id: "job_background_first",
            direction: .upload,
            sourcePath: "/local/first.tar",
            destinationPath: "/srv/first.tar",
            bytesTotal: 100
        )
        let secondJob = ScpTransferJob(
            id: "job_background_second",
            direction: .download,
            sourcePath: "/srv/second.tar",
            destinationPath: "/local/second.tar",
            bytesTotal: 200
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            firstJob.id: [
                ScpTransferProgress(
                    jobId: firstJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ],
            secondJob.id: [
                ScpTransferProgress(
                    jobId: secondJob.id,
                    bytesDone: 200,
                    bytesTotal: 200,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: firstJob
        )
        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: secondJob
        )

        let firstStarted = await eventually { bridge.startedJobIDs == [firstJob.id] }
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "传输中")
        XCTAssertEqual(queue.tableView.statusText(row: 1), "排队中")

        bridge.release(jobID: firstJob.id)

        let secondStarted = await eventually { bridge.startedJobIDs == [firstJob.id, secondJob.id] }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已完成")
        XCTAssertEqual(queue.tableView.statusText(row: 1), "传输中")

        bridge.release(jobID: secondJob.id)

        let secondCompleted = await eventually {
            queue.tableView.statusText(row: 1) == "已完成"
        }
        XCTAssertTrue(secondCompleted)
    }

    func testCoordinatorHonorsConfiguredBackgroundTransferConcurrencyLimit() async {
        let firstJob = ScpTransferJob(
            id: "job_concurrent_first",
            direction: .upload,
            sourcePath: "/local/first.tar",
            destinationPath: "/srv/first.tar",
            bytesTotal: 100
        )
        let secondJob = ScpTransferJob(
            id: "job_concurrent_second",
            direction: .upload,
            sourcePath: "/local/second.tar",
            destinationPath: "/srv/second.tar",
            bytesTotal: 200
        )
        let thirdJob = ScpTransferJob(
            id: "job_concurrent_third",
            direction: .download,
            sourcePath: "/srv/third.tar",
            destinationPath: "/local/third.tar",
            bytesTotal: 300
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            firstJob.id: [
                ScpTransferProgress(
                    jobId: firstJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ],
            secondJob.id: [
                ScpTransferProgress(
                    jobId: secondJob.id,
                    bytesDone: 200,
                    bytesTotal: 200,
                    status: "completed"
                )
            ],
            thirdJob.id: [
                ScpTransferProgress(
                    jobId: thirdJob.id,
                    bytesDone: 300,
                    bytesTotal: 300,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue,
            maxConcurrentTransfers: 2
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        for job in [firstJob, secondJob, thirdJob] {
            coordinator.scheduleLiveTransfer(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                job: job
            )
        }

        let firstTwoStarted = await eventually {
            Set(bridge.startedJobIDs) == Set([firstJob.id, secondJob.id])
        }
        XCTAssertTrue(firstTwoStarted)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "传输中")
        XCTAssertEqual(queue.tableView.statusText(row: 1), "传输中")
        XCTAssertEqual(queue.tableView.statusText(row: 2), "排队中")

        bridge.release(jobID: firstJob.id)

        let thirdStarted = await eventually {
            Set(bridge.startedJobIDs) == Set([firstJob.id, secondJob.id, thirdJob.id])
        }
        XCTAssertTrue(thirdStarted)
        XCTAssertEqual(queue.tableView.statusText(row: 2), "传输中")

        bridge.release(jobID: secondJob.id)
        bridge.release(jobID: thirdJob.id)

        let allCompleted = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
                && queue.tableView.statusText(row: 1) == "已完成"
                && queue.tableView.statusText(row: 2) == "已完成"
        }
        XCTAssertTrue(allCompleted)
    }

    func testCoordinatorCancelsRunningBackgroundTransferAndIgnoresLateCompletion() async {
        let job = ScpTransferJob(
            id: "job_background_cancel",
            direction: .upload,
            sourcePath: "/local/cancel.tar",
            destinationPath: "/srv/cancel.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))
        XCTAssertEqual(bridge.cancelledJobIDs, [job.id])
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已取消")

        bridge.release(jobID: job.id)

        let finished = await eventually { bridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(finished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已取消")
        XCTAssertEqual(history.events, [
            "record:job_background_cancel:queued:0",
            "progress:job_background_cancel:running:0",
            "progress:job_background_cancel:canceled:0"
        ])
    }

    func testCoordinatorStopsProgressPollingWhenLastRunningSCPTransferIsCanceled() async {
        let job = ScpTransferJob(
            id: "job_background_cancel_polling",
            direction: .upload,
            sourcePath: "/local/cancel-polling.tar",
            destinationPath: "/srv/cancel-polling.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        XCTAssertTrue(isTransferProgressPollingActive(coordinator))

        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))

        XCTAssertFalse(isTransferProgressPollingActive(coordinator))

        bridge.release(jobID: job.id)
    }

    func testCoordinatorPausesRunningSCPTransferAndResumesSameQueuedTask() async {
        let job = ScpTransferJob(
            id: "job_background_pause_resume",
            direction: .upload,
            sourcePath: "/local/pause.tar",
            destinationPath: "/srv/pause.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let progressUpdated = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true
        }
        XCTAssertTrue(progressUpdated)

        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))

        XCTAssertEqual(bridge.cancelledJobIDs, [job.id])
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已暂停")
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true)
        XCTAssertEqual(snapshots.last?.rows.first?.rawStatus, "paused")

        bridge.release(jobID: job.id)
        let originalRunFinished = await eventually { bridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(originalRunFinished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已暂停")

        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))

        let restarted = await eventually { bridge.startedJobIDs == [job.id, job.id] }
        XCTAssertTrue(restarted)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "续传中")
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.requestedOffset), [0, 40])
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.forceRestart), [false, false])

        bridge.release(jobID: job.id)
        let completed = await eventually { queue.tableView.statusText(row: 0) == "已完成" }
        XCTAssertTrue(completed)
        XCTAssertEqual(history.events.filter { $0.contains(":paused:40") }, [
            "progress:job_background_pause_resume:paused:40"
        ])
    }

    func testCoordinatorCanAbandonResumeAndRestartStoppedSCPTransferFromZero() async {
        let job = ScpTransferJob(
            id: "job_background_restart_without_resume",
            direction: .download,
            sourcePath: "/srv/restart.tar",
            destinationPath: "/local/restart.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let progressUpdated = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true
        }
        XCTAssertTrue(progressUpdated)

        XCTAssertTrue(coordinator.stopTransfer(jobID: job.id))
        bridge.release(jobID: job.id)
        let originalRunFinished = await eventually { bridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(originalRunFinished)

        XCTAssertTrue(coordinator.restartTransfer(jobID: job.id))

        let restarted = await eventually { bridge.startedJobIDs == [job.id, job.id] }
        XCTAssertTrue(restarted)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "传输中")
        XCTAssertEqual(queue.tableView.progressText(row: 0), "0%")
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.requestedOffset), [0, 0])
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.forceRestart), [false, true])

        bridge.release(jobID: job.id)
    }

    func testCoordinatorStopsRunningTransferAndRetriesStoppedTask() async {
        let job = ScpTransferJob(
            id: "job_background_stop_retry",
            direction: .download,
            sourcePath: "/srv/stop.tar",
            destinationPath: "/local/stop.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 30,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let progressUpdated = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("30%") == true
        }
        XCTAssertTrue(progressUpdated)

        XCTAssertTrue(coordinator.stopTransfer(jobID: job.id))

        XCTAssertEqual(bridge.cancelledJobIDs, [job.id])
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已停止")
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("30%") == true)

        bridge.release(jobID: job.id)
        let originalRunFinished = await eventually { bridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(originalRunFinished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已停止")

        XCTAssertTrue(coordinator.retryFailedTransfer(jobID: job.id))

        let restarted = await eventually { bridge.startedJobIDs == [job.id, job.id] }
        XCTAssertTrue(restarted)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "续传中")
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.requestedOffset), [0, 30])
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.forceRestart), [false, false])

        bridge.release(jobID: job.id)
        let completed = await eventually { queue.tableView.statusText(row: 0) == "已完成" }
        XCTAssertTrue(completed)
        XCTAssertEqual(history.events.filter { $0.contains(":stopped:30") }, [
            "progress:job_background_stop_retry:stopped:30"
        ])
    }

    func testCoordinatorPublishesStoppedTransferSnapshotForFilesBottomStrip() async {
        let job = ScpTransferJob(
            id: "job_background_stop_snapshot",
            direction: .download,
            sourcePath: "/srv/stop.tar",
            destinationPath: "/local/stop.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 30,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: RecordingTransferHistoryStore(),
            queueViewController: queue
        )
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let progressUpdated = await eventually {
            snapshots.last?.rows.first?.bytesDone == 30
        }
        XCTAssertTrue(progressUpdated)
        XCTAssertTrue(coordinator.stopTransfer(jobID: job.id))

        XCTAssertEqual(snapshots.last?.rows.first?.jobID, job.id)
        XCTAssertEqual(snapshots.last?.rows.first?.rawStatus, "stopped")
        XCTAssertEqual(snapshots.last?.rows.first?.bytesDone, 30)

        bridge.release(jobID: job.id)
    }

    func testCoordinatorPollsLiveTransferProgressWhileBackgroundTransferRuns() async {
        let job = ScpTransferJob(
            id: "job_progress_stream",
            direction: .upload,
            sourcePath: "/local/progress.tar",
            destinationPath: "/srv/progress.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)

        coordinator.pollScheduledTransferProgressForTesting()

        let progressUpdated = await eventually {
            bridge.progressBatchJobIDs == [job.id]
                && queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true
        }
        XCTAssertTrue(progressUpdated)
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "传输中")

        bridge.release(jobID: job.id)

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
    }

    func testCoordinatorKeepsPolledCompletionWhenBackgroundSCPRunReturnsDuplicateCompletion() async {
        let job = ScpTransferJob(
            id: "job_progress_polled_completion",
            direction: .upload,
            sourcePath: "/local/release.tar",
            destinationPath: "/srv/release.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ]
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let polledCompletion = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(polledCompletion)

        bridge.release(jobID: job.id)

        let finished = await eventually { bridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(finished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已完成")
        XCTAssertFalse(history.events.contains("progress:job_progress_polled_completion:failed:100:传输失败"))
    }

    func testCoordinatorKeepsPolledSCPProgressMonotonicForSameJob() async {
        let job = ScpTransferJob(
            id: "job_progress_monotonic",
            direction: .upload,
            sourcePath: "/local/release",
            destinationPath: "/srv/release",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 70,
                    bytesTotal: 100,
                    status: "running"
                )
            ],
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 50,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let firstProgress = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("70%") == true
        }
        XCTAssertTrue(firstProgress)

        coordinator.pollScheduledTransferProgressForTesting()
        let staleProgressPolled = await eventually {
            bridge.progressBatchJobIDs.count >= 2
        }
        XCTAssertTrue(staleProgressPolled)
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("70%") == true)

        bridge.release(jobID: job.id)
    }

    func testCoordinatorIgnoresDuplicatePolledSCPProgressEvents() async {
        let job = ScpTransferJob(
            id: "job_progress_duplicate",
            direction: .upload,
            sourcePath: "/local/release",
            destinationPath: "/srv/release",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "running"
                )
            ],
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let firstProgress = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true
        }
        XCTAssertTrue(firstProgress)

        coordinator.pollScheduledTransferProgressForTesting()
        let duplicateProgressPolled = await eventually {
            bridge.progressBatchJobIDs.count >= 2
        }
        XCTAssertTrue(duplicateProgressPolled)

        XCTAssertEqual(
            history.events.filter { $0 == "progress:job_progress_duplicate:running:40" },
            ["progress:job_progress_duplicate:running:40"]
        )
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("40%") == true)

        bridge.release(jobID: job.id)
    }

    func testCoordinatorIgnoresPolledSCPProgressForDifferentJobID() async {
        let uploadJob = ScpTransferJob(
            id: "job_progress_upload",
            direction: .upload,
            sourcePath: "/local/release",
            destinationPath: "/srv/release",
            bytesTotal: 100
        )
        let downloadJob = ScpTransferJob(
            id: "job_progress_download",
            direction: .download,
            sourcePath: "/srv/swap.img",
            destinationPath: "/local/swap.img",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            uploadJob.id: [
                ScpTransferProgress(
                    jobId: uploadJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ],
            downloadJob.id: [
                ScpTransferProgress(
                    jobId: downloadJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[uploadJob.id] = [
            [
                ScpTransferProgress(
                    jobId: uploadJob.id,
                    bytesDone: 70,
                    bytesTotal: 100,
                    status: "running"
                )
            ],
            [
                ScpTransferProgress(
                    jobId: downloadJob.id,
                    bytesDone: 50,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue,
            maxConcurrentTransfers: 2
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: uploadJob
        )
        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: downloadJob
        )
        let started = await eventually {
            Set(bridge.startedJobIDs) == Set([uploadJob.id, downloadJob.id])
        }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()
        let firstProgress = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("70%") == true
        }
        XCTAssertTrue(firstProgress)

        coordinator.pollScheduledTransferProgressForTesting()
        let mismatchedProgressPolled = await eventually {
            bridge.progressBatchJobIDs.filter { $0 == uploadJob.id }.count >= 2
        }
        XCTAssertTrue(mismatchedProgressPolled)
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("70%") == true)
        XCTAssertEqual(queue.tableView.progressText(row: 1), "0%")

        bridge.release(jobID: uploadJob.id)
        bridge.release(jobID: downloadJob.id)
    }

    func testCoordinatorCancelsAndRemovesTransfersForRuntimeWithoutTouchingOtherRuntime() async {
        let targetJob = ScpTransferJob(
            id: "job_runtime_target",
            direction: .upload,
            sourcePath: "/local/target.tar",
            destinationPath: "/srv/target.tar",
            bytesTotal: 100
        )
        let otherJob = ScpTransferJob(
            id: "job_runtime_other",
            direction: .upload,
            sourcePath: "/local/other.tar",
            destinationPath: "/srv/other.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            targetJob.id: [
                ScpTransferProgress(jobId: targetJob.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ],
            otherJob.id: [
                ScpTransferProgress(jobId: otherJob.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue,
            maxConcurrentTransfers: 2
        )
        let targetConfig = SshConnectionConfig(
            host: "target.example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let otherConfig = SshConnectionConfig(
            host: "other.example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-target",
            config: targetConfig,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:target",
            job: targetJob
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-other",
            config: otherConfig,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:other",
            job: otherJob
        )
        let started = await eventually {
            Set(bridge.startedJobIDs) == Set([targetJob.id, otherJob.id])
        }
        XCTAssertTrue(started)

        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "runtime-target"), [targetJob.id])

        XCTAssertEqual(bridge.cancelledJobIDs, [targetJob.id])
        XCTAssertEqual(queue.snapshotForTesting.rows.map(\.jobID), [otherJob.id])
        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "runtime-target"), [])

        bridge.release(jobID: targetJob.id)
        bridge.release(jobID: otherJob.id)
    }

    func testCoordinatorIgnoresDuplicateScheduleForRunningJobID() async {
        let originalJob = ScpTransferJob(
            id: "job_duplicate_running",
            direction: .upload,
            sourcePath: "/local/original.tar",
            destinationPath: "/srv/original.tar",
            bytesTotal: 100
        )
        let duplicateJob = ScpTransferJob(
            id: originalJob.id,
            direction: .upload,
            sourcePath: "/local/duplicate.tar",
            destinationPath: "/srv/duplicate.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            originalJob.id: [
                ScpTransferProgress(
                    jobId: originalJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue,
            maxConcurrentTransfers: 1
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        var originalCompletions: [ScpTransferProgress] = []
        var duplicateCompletions: [ScpTransferProgress] = []

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: originalJob,
            completion: { originalCompletions.append($0) }
        )
        let started = await eventually { bridge.startedJobIDs == [originalJob.id] }
        XCTAssertTrue(started)

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: duplicateJob,
            completion: { duplicateCompletions.append($0) }
        )

        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.tableView.fileText(row: 0), "original.tar")

        bridge.release(jobID: originalJob.id)
        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(bridge.startedJobIDs, [originalJob.id])
        XCTAssertEqual(queue.tableView.fileText(row: 0), "original.tar")
        XCTAssertEqual(originalCompletions.map(\.status), ["completed"])
        XCTAssertEqual(duplicateCompletions.map(\.status), [])
    }

    func testCoordinatorPublishesSnapshotsForFilesTransferStatusStrip() async {
        let job = ScpTransferJob(
            id: "job_files_footer_progress",
            direction: .download,
            sourcePath: "/srv/video.mp4",
            destinationPath: "/Users/alice/video.mp4",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[job.id] = [
            [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        coordinator.pollScheduledTransferProgressForTesting()

        let snapshotUpdated = await eventually {
            snapshots.last?.rows.first?.bytesDone == 40
        }
        XCTAssertTrue(snapshotUpdated)
        XCTAssertEqual(snapshots.last?.rows.first?.jobID, job.id)
        XCTAssertEqual(snapshots.last?.rows.first?.direction, .download)
        XCTAssertEqual(snapshots.last?.rows.first?.bytesDone, 40)
        XCTAssertEqual(snapshots.last?.rows.first?.rawStatus, "running")

        bridge.release(jobID: job.id)
        let completed = await eventually {
            snapshots.last?.rows.first?.rawStatus == "completed"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(snapshots.last?.rows.first?.jobID, job.id)
        XCTAssertEqual(snapshots.last?.rows.first?.bytesDone, 100)
    }

    func testCoordinatorLimitsCompletedTransferHistoryForFilesTransferStatusStrip() async {
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let completedJobs = (0..<25).map { index in
            ScpTransferJob(
                id: "job_history_\(index)",
                direction: .download,
                sourcePath: "/srv/history-\(index).log",
                destinationPath: "/Users/alice/history-\(index).log",
                bytesTotal: 100
            )
        }
        let activeJob = ScpTransferJob(
            id: "job_active_upload",
            direction: .upload,
            sourcePath: "/Users/alice/release.tar",
            destinationPath: "/srv/release.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            activeJob.id: [
                ScpTransferProgress(
                    jobId: activeJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        for job in completedJobs {
            coordinator.enqueueTransfer(job: job)
            coordinator.replaceProgressForTesting(jobID: job.id, status: "completed", bytesDone: 100)
        }
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: activeJob
        )

        let started = await eventually { bridge.startedJobIDs == [activeJob.id] }
        XCTAssertTrue(started)
        XCTAssertEqual(snapshots.last?.rows.map(\.jobID), [activeJob.id])
        XCTAssertEqual(queue.transferCount, 6)
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/srv/history-0.log"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/srv/history-19.log"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("/srv/history-20.log"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("/srv/history-24.log"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("/Users/alice/release.tar"))

        bridge.release(jobID: activeJob.id)
    }

    func testCoordinatorPollsSCPProgressWithoutBlockingMainActor() async {
        let job = ScpTransferJob(
            id: "job_slow_progress",
            direction: .upload,
            sourcePath: "/Users/alice/slow.tar",
            destinationPath: "/srv/slow.tar",
            bytesTotal: 100
        )
        let bridge = SlowProgressSCPTransferBridge(
            progressDelay: 0.2,
            progress: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 25,
                    bytesTotal: 100,
                    status: "running"
                )
            ],
            completion: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let started = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)

        let startedAt = Date()
        coordinator.pollScheduledTransferProgressForTesting()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.05)
        let updated = await eventually {
            queue.tableView.progressText(row: 0)?.hasPrefix("25%") == true
        }
        XCTAssertTrue(updated)

        bridge.release(jobID: job.id)
    }

    func testCoordinatorPollsProgressForAllRunningConcurrentTransfers() async {
        let firstJob = ScpTransferJob(
            id: "job_progress_first",
            direction: .upload,
            sourcePath: "/local/first-progress.tar",
            destinationPath: "/srv/first-progress.tar",
            bytesTotal: 100
        )
        let secondJob = ScpTransferJob(
            id: "job_progress_second",
            direction: .download,
            sourcePath: "/srv/second-progress.tar",
            destinationPath: "/local/second-progress.tar",
            bytesTotal: 200
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            firstJob.id: [
                ScpTransferProgress(
                    jobId: firstJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ],
            secondJob.id: [
                ScpTransferProgress(
                    jobId: secondJob.id,
                    bytesDone: 200,
                    bytesTotal: 200,
                    status: "completed"
                )
            ]
        ])
        bridge.progressBatchesByJobID[firstJob.id] = [
            [
                ScpTransferProgress(
                    jobId: firstJob.id,
                    bytesDone: 25,
                    bytesTotal: 100,
                    status: "running"
                )
            ]
        ]
        bridge.progressBatchesByJobID[secondJob.id] = [
            [
                ScpTransferProgress(
                    jobId: secondJob.id,
                    bytesDone: 100,
                    bytesTotal: 200,
                    status: "running"
                )
            ]
        ]
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue,
            maxConcurrentTransfers: 2
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: firstJob
        )
        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: secondJob
        )

        let started = await eventually {
            Set(bridge.startedJobIDs) == Set([firstJob.id, secondJob.id])
        }
        XCTAssertTrue(started)

        coordinator.pollScheduledTransferProgressForTesting()

        let progressUpdated = await eventually {
            Set(bridge.progressBatchJobIDs) == Set([firstJob.id, secondJob.id])
                && queue.tableView.progressText(row: 0)?.hasPrefix("25%") == true
                && queue.tableView.progressText(row: 1)?.hasPrefix("50%") == true
        }
        XCTAssertTrue(progressUpdated)
        XCTAssertTrue(queue.tableView.progressText(row: 0)?.hasPrefix("25%") == true)
        XCTAssertTrue(queue.tableView.progressText(row: 1)?.hasPrefix("50%") == true)

        bridge.release(jobID: firstJob.id)
        bridge.release(jobID: secondJob.id)

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
                && queue.tableView.statusText(row: 1) == "已完成"
        }
        XCTAssertTrue(completed)
    }

    func testCoordinatorHandlesQueueViewStopAndRetryActionsWithoutCachingSecret() {
        let bridge = RecordingSCPTransferBridge(error: SshRuntimeError.InvalidConfig)
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        var retryRequests: [String] = []
        coordinator.onRetryRequested = { jobID in
            retryRequests.append(jobID)
        }
        let failedJob = ScpTransferJob(
            id: "job_failed_action",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )
        let queuedJob = ScpTransferJob(
            id: "job_cancel_action",
            direction: .download,
            sourcePath: "/remote/archive.tar",
            destinationPath: "/local/archive.tar",
            bytesTotal: 100
        )
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        XCTAssertThrowsError(
            try coordinator.runLiveTransfer(
                config: config,
                secret: .password(value: "top-secret-password"),
                expectedFingerprintSHA256: "SHA256:test",
                job: failedJob
            )
        )
        coordinator.enqueueTransfer(job: queuedJob)

        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        queue.performTransferActionForTesting(at: 0)
        queue.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        queue.performTransferActionForTesting(at: 1)

        XCTAssertEqual(retryRequests, ["job_failed_action"])
        XCTAssertEqual(queue.latestStatusText, "已停止")
        XCTAssertFalse(bridge.debugDescription.contains("top-secret-password"))
    }

    func testCoordinatorRetriesFailedScheduledSCPTransferFromQueueActionWithoutExposingSecret() async {
        let job = ScpTransferJob(
            id: "job_retry_scheduled_scp",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )
        let bridge = RecordingSequenceSCPTransferBridge(results: [
            .failure(SshRuntimeError.Transport(message: "Authentication failed secret-ref /Users/me/.ssh/id_ed25519")),
            .success([
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ])
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .password(credentialRef: "credential:retry"),
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .password(value: "top-secret-password"),
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let failed = await eventually {
            queue.tableView.statusText(row: 0) == "失败"
        }
        XCTAssertTrue(failed)
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("认证失败 [已隐藏凭据] [已隐藏路径]"))

        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        queue.performTransferActionForTesting(at: 0)

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(bridge.events, ["run:job_retry_scheduled_scp", "run:job_retry_scheduled_scp"])
        XCTAssertFalse(bridge.debugDescription.contains("top-secret-password"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("top-secret-password"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/Users/me/.ssh/id_ed25519"))
    }

    func testCoordinatorRetriesFailedScheduledFTPTransferFromQueueActionWithoutExposingSecret() async {
        let job = ScpTransferJob(
            id: "job_retry_scheduled_ftp",
            direction: .download,
            sourcePath: "/pub/readme.txt",
            destinationPath: "/Users/alice/readme.txt",
            bytesTotal: 64
        )
        let ftpBridge = RecordingSequenceFTPTransferBridge(results: [
            .failure(SshRuntimeError.Transport(message: "Permission denied secret-ref")),
            .success([
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 64,
                    bytesTotal: 64,
                    status: "completed"
                )
            ])
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            ftpBridge: ftpBridge,
            queueViewController: queue
        )
        let config = FtpConnectionConfig(
            host: "ftp.example.com",
            port: 21,
            username: "deploy",
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveFTPTransfer(
            config: config,
            secret: .password(value: "ftp-secret"),
            job: job
        )

        let failed = await eventually {
            queue.tableView.statusText(row: 0) == "失败"
        }
        XCTAssertTrue(failed)

        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        queue.performTransferActionForTesting(at: 0)

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(ftpBridge.events, ["run:job_retry_scheduled_ftp", "run:job_retry_scheduled_ftp"])
        XCTAssertFalse(ftpBridge.debugDescription.contains("ftp-secret"))
        XCTAssertFalse(queue.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testCoordinatorRestoresTransferHistoryIntoQueueView() throws {
        let bridge = RecordingSCPTransferBridge()
        let job = ScpTransferJob(
            id: "job_restored",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )
        let history = RecordingTransferHistoryStore(
            jobs: [
                ScpTransferJobRecord(
                    job: job,
                    sessionId: nil,
                    status: "completed",
                    bytesDone: 100
                )
            ],
            eventsByJobID: [
                job.id: [
                    ScpTransferEventRecord(
                        id: "event_1",
                        jobId: job.id,
                        eventType: "completed",
                        message: nil,
                        bytesDone: 100,
                        createdAt: "2026-05-27T00:00:00Z"
                    )
                ]
            ]
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )

        try coordinator.restoreHistory()

        XCTAssertEqual(queue.transferCount, 1)
        XCTAssertEqual(queue.latestStatusText, "已完成")
        XCTAssertEqual(queue.tableView.fileText(row: 0), "app.tar.gz")
        XCTAssertEqual(queue.tableView.progressText(row: 0), "100%")
        XCTAssertEqual(history.events, ["list-jobs", "list-events:job_restored"])
    }

    func testCoordinatorRestoresOnlyVisibleCompletedHistoryEvents() throws {
        let completedJobs = (0..<8).map { index in
            ScpTransferJobRecord(
                job: ScpTransferJob(
                    id: "job_restore_completed_\(index)",
                    direction: .download,
                    sourcePath: "/srv/history-\(index).log",
                    destinationPath: "/Users/alice/history-\(index).log",
                    bytesTotal: 100
                ),
                sessionId: nil,
                status: "completed",
                bytesDone: 100
            )
        }
        let running = ScpTransferJobRecord(
            job: ScpTransferJob(
                id: "job_restore_running",
                direction: .upload,
                sourcePath: "/Users/alice/release.tar",
                destinationPath: "/srv/release.tar",
                bytesTotal: 100
            ),
            sessionId: nil,
            status: "running",
            bytesDone: 40
        )
        let eventsByJobID = Dictionary(
            uniqueKeysWithValues: (completedJobs + [running]).map { record in
                (
                    record.job.id,
                    [
                        ScpTransferEventRecord(
                            id: "event_\(record.job.id)",
                            jobId: record.job.id,
                            eventType: record.status,
                            message: nil,
                            bytesDone: record.bytesDone,
                            createdAt: "2026-05-27T00:00:00Z"
                        )
                    ]
                )
            }
        )
        let history = RecordingTransferHistoryStore(
            jobs: completedJobs + [running],
            eventsByJobID: eventsByJobID
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            historyStore: history,
            queueViewController: queue
        )

        try coordinator.restoreHistory()

        XCTAssertEqual(queue.transferCount, 6)
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/srv/history-0.log"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/srv/history-2.log"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("/srv/history-3.log"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("/srv/history-7.log"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("/Users/alice/release.tar"))
        XCTAssertEqual(history.events, [
            "list-jobs",
            "list-events:job_restore_completed_3",
            "list-events:job_restore_completed_4",
            "list-events:job_restore_completed_5",
            "list-events:job_restore_completed_6",
            "list-events:job_restore_completed_7",
            "list-events:job_restore_running"
        ])
    }

    func testCoordinatorRestoreHistoryClearsStaleRunningStateBeforeSchedulingNewTransfer() async throws {
        let staleJob = ScpTransferJob(
            id: "job_restore_stale_running",
            direction: .upload,
            sourcePath: "/Users/alice/stale.tar",
            destinationPath: "/srv/stale.tar",
            bytesTotal: 100
        )
        let newJob = ScpTransferJob(
            id: "job_restore_new_transfer",
            direction: .download,
            sourcePath: "/srv/new.tar",
            destinationPath: "/Users/alice/new.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            staleJob.id: [
                ScpTransferProgress(
                    jobId: staleJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ],
            newJob.id: [
                ScpTransferProgress(
                    jobId: newJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        defer {
            bridge.release(jobID: staleJob.id)
            bridge.release(jobID: newJob.id)
        }
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue,
            maxConcurrentTransfers: 1
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: staleJob
        )
        let staleStarted = await eventually {
            bridge.startedJobIDs == [staleJob.id]
        }
        XCTAssertTrue(staleStarted)

        try coordinator.restoreHistory()
        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: newJob
        )

        let newStarted = await eventually {
            bridge.startedJobIDs == [staleJob.id, newJob.id]
        }
        XCTAssertTrue(newStarted)
        XCTAssertEqual(history.events, [
            "record:job_restore_stale_running:queued:0",
            "progress:job_restore_stale_running:running:0",
            "list-jobs",
            "record:job_restore_new_transfer:queued:0",
            "progress:job_restore_new_transfer:running:0"
        ])
    }

    func testCoordinatorAllowsReschedulingSameJobIDAfterRestoredRunningHistory() async throws {
        let job = ScpTransferJob(
            id: "job_restore_same_id",
            direction: .upload,
            sourcePath: "/Users/alice/release.tar",
            destinationPath: "/srv/release.tar",
            bytesTotal: 100
        )
        let history = RecordingTransferHistoryStore(
            jobs: [
                ScpTransferJobRecord(
                    job: job,
                    sessionId: nil,
                    status: "running",
                    bytesDone: 40
                )
            ],
            eventsByJobID: [
                job.id: [
                    ScpTransferEventRecord(
                        id: "event_running",
                        jobId: job.id,
                        eventType: "running",
                        message: nil,
                        bytesDone: 40,
                        createdAt: "2026-05-27T00:00:00Z"
                    )
                ]
            ]
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]
        ])
        defer {
            bridge.release(jobID: job.id)
        }
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        try coordinator.restoreHistory()
        coordinator.scheduleLiveTransfer(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let started = await eventually {
            bridge.startedJobIDs == [job.id]
        }
        XCTAssertTrue(started)
    }

    func testCoordinatorRestoresFailureDiagnosticIntoQueueView() throws {
        let bridge = RecordingSCPTransferBridge()
        let job = ScpTransferJob(
            id: "job_restored_failed",
            direction: .download,
            sourcePath: "/srv/app.tar.gz",
            destinationPath: "/local/app.tar.gz",
            bytesTotal: 100
        )
        let history = RecordingTransferHistoryStore(
            jobs: [
                ScpTransferJobRecord(
                    job: job,
                    sessionId: nil,
                    status: "failed",
                    bytesDone: 40
                )
            ],
            eventsByJobID: [
                job.id: [
                    ScpTransferEventRecord(
                        id: "event_failed",
                        jobId: job.id,
                        eventType: "failed",
                        message: "Permission denied",
                        bytesDone: 40,
                        createdAt: "2026-05-27T00:00:00Z"
                    )
                ]
            ]
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )

        try coordinator.restoreHistory()

        XCTAssertEqual(queue.tableView.statusText(row: 0), "失败")
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("权限被拒绝"))
    }

    func testCoordinatorRestoresTransferEventLogIntoQueueDetail() throws {
        let bridge = RecordingSCPTransferBridge()
        let job = ScpTransferJob(
            id: "job_restored_log",
            direction: .upload,
            sourcePath: "/local/app.tar.gz",
            destinationPath: "/srv/app.tar.gz",
            bytesTotal: 100
        )
        let history = RecordingTransferHistoryStore(
            jobs: [
                ScpTransferJobRecord(
                    job: job,
                    sessionId: nil,
                    status: "failed",
                    bytesDone: 40
                )
            ],
            eventsByJobID: [
                job.id: [
                    ScpTransferEventRecord(
                        id: "event_queued",
                        jobId: job.id,
                        eventType: "queued",
                        message: nil,
                        bytesDone: 0,
                        createdAt: "2026-05-27T00:00:00Z"
                    ),
                    ScpTransferEventRecord(
                        id: "event_failed",
                        jobId: job.id,
                        eventType: "failed",
                        message: "Permission denied secret-ref=/Users/alice/.ssh/id_ed25519",
                        bytesDone: 40,
                        createdAt: "2026-05-27T00:00:02Z"
                    )
                ]
            ]
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            queueViewController: queue
        )

        try coordinator.restoreHistory()
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("传输日志"))
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("2026-05-27T00:00:00Z · 排队中 · 0%"))
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("2026-05-27T00:00:02Z · 失败 · 40% · 权限被拒绝"))
        XCTAssertFalse(queue.selectedTransferDetailTextForTesting.contains("secret-ref"))
        XCTAssertFalse(queue.selectedTransferDetailTextForTesting.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testCoordinatorClearsFinishedTransfersButKeepsActiveTransfers() {
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            historyStore: history,
            queueViewController: queue
        )
        let completedJob = ScpTransferJob(
            id: "job_completed_clear",
            direction: .upload,
            sourcePath: "/local/completed.tar",
            destinationPath: "/srv/completed.tar",
            bytesTotal: 100
        )
        let failedJob = ScpTransferJob(
            id: "job_failed_clear",
            direction: .download,
            sourcePath: "/srv/failed.tar",
            destinationPath: "/local/failed.tar",
            bytesTotal: 100
        )
        let queuedJob = ScpTransferJob(
            id: "job_queued_keep",
            direction: .upload,
            sourcePath: "/local/queued.tar",
            destinationPath: "/srv/queued.tar",
            bytesTotal: 100
        )
        let runningJob = ScpTransferJob(
            id: "job_running_keep",
            direction: .download,
            sourcePath: "/srv/running.tar",
            destinationPath: "/local/running.tar",
            bytesTotal: 100
        )

        coordinator.enqueueTransfer(job: completedJob)
        coordinator.enqueueTransfer(job: failedJob)
        coordinator.enqueueTransfer(job: queuedJob)
        coordinator.enqueueTransfer(job: runningJob)
        coordinator.replaceProgressForTesting(jobID: completedJob.id, status: "completed", bytesDone: 100)
        coordinator.replaceProgressForTesting(jobID: failedJob.id, status: "failed", bytesDone: 40)
        coordinator.replaceProgressForTesting(jobID: runningJob.id, status: "running", bytesDone: 25)

        let removedCount = coordinator.clearFinishedTransfers()

        XCTAssertEqual(removedCount, 2)
        XCTAssertEqual(history.events.last, "clear-finished")
        XCTAssertEqual(queue.transferCount, 2)
        XCTAssertEqual(queue.tableView.fileText(row: 0), "queued.tar")
        XCTAssertEqual(queue.tableView.statusText(row: 0), "排队中")
        XCTAssertEqual(queue.tableView.fileText(row: 1), "running.tar")
        XCTAssertEqual(queue.tableView.statusText(row: 1), "传输中")
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/local/completed.tar"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/srv/failed.tar"))
    }
}

private func eventually(
    timeout: TimeInterval = 1.0,
    condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@MainActor
private func isTransferProgressPollingActive(_ coordinator: TransferQueueCoordinator) -> Bool {
    Mirror(reflecting: coordinator)
        .children
        .first { $0.label == "progressPollTimer" }?
        .value as? Timer != nil
}

private enum RecordingSCPTransferResult {
    case success([ScpTransferProgress])
    case failure(Error)
}

private enum RecordingFTPTransferResult {
    case success([ScpTransferProgress])
    case failure(Error)
}

private final class RecordingSCPTransferBridge: SCPTransferBridging, CustomDebugStringConvertible {
    var events: [String] = []
    var debugDescription: String { events.joined(separator: " ") }
    private var results: [RecordingSCPTransferResult]

    init(progress: [ScpTransferProgress] = [], error: Error? = nil) {
        if let error {
            results = [.failure(error)]
        } else {
            results = [.success(progress)]
        }
    }

    init(results: [RecordingSCPTransferResult]) {
        self.results = results
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        events.append("run:\(job.id)")
        let result = results.isEmpty ? .success([]) : results.removeFirst()
        switch result {
        case .success(let progress):
            return progress
        case .failure(let error):
            throw error
        }
    }
}

private final class RecordingFTPTransferBridge: FTPTransferBridging, CustomDebugStringConvertible {
    var events: [String] = []
    var debugDescription: String { events.joined(separator: " ") }
    private let progress: [ScpTransferProgress]

    init(progress: [ScpTransferProgress] = []) {
        self.progress = progress
    }

    func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        events.append("run:\(job.id)")
        return progress
    }
}

private final class RecordingSequenceSCPTransferBridge: SCPTransferBridging, CustomDebugStringConvertible {
    var events: [String] = []
    var debugDescription: String { events.joined(separator: " ") }
    private let lock = NSLock()
    private var results: [RecordingSCPTransferResult]

    init(results: [RecordingSCPTransferResult]) {
        self.results = results
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        let result = locked { () -> RecordingSCPTransferResult in
            events.append("run:\(job.id)")
            return results.isEmpty ? .success([]) : results.removeFirst()
        }
        switch result {
        case .success(let progress):
            return progress
        case .failure(let error):
            throw error
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class RecordingSequenceFTPTransferBridge: FTPTransferBridging, CustomDebugStringConvertible {
    var events: [String] = []
    var debugDescription: String { events.joined(separator: " ") }
    private let lock = NSLock()
    private var results: [RecordingFTPTransferResult]

    init(results: [RecordingFTPTransferResult]) {
        self.results = results
    }

    func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        let result = locked { () -> RecordingFTPTransferResult in
            events.append("run:\(job.id)")
            return results.isEmpty ? .success([]) : results.removeFirst()
        }
        switch result {
        case .success(let progress):
            return progress
        case .failure(let error):
            throw error
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class DelayedFTPTransferBridge: FTPTransferBridging, CustomDebugStringConvertible {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let progress: [ScpTransferProgress]
    private var recordedEvents: [String] = []
    private var finished: [String] = []
    private var cancelled: [String] = []

    init(delay: TimeInterval, progress: [ScpTransferProgress]) {
        self.delay = delay
        self.progress = progress
    }

    var events: [String] {
        locked { recordedEvents }
    }

    var finishedJobIDs: [String] {
        locked { finished }
    }

    var cancelledJobIDs: [String] {
        locked { cancelled }
    }

    var debugDescription: String {
        events.joined(separator: " ")
    }

    func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        locked {
            recordedEvents.append("run:\(job.id)")
        }
        Thread.sleep(forTimeInterval: delay)
        locked {
            finished.append(job.id)
        }
        return progress
    }

    func cancelLiveFTPTransfer(jobID: String) -> Bool {
        locked {
            cancelled.append(jobID)
        }
        return true
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class BlockingSCPTransferBridge: SCPTransferBridging {
    private let lock = NSLock()
    private let completionsByJobID: [String: [ScpTransferProgress]]
    var progressBatchesByJobID: [String: [[ScpTransferProgress]]] = [:]
    private var gatesByJobID: [String: DispatchSemaphore] = [:]
    private var started: [String] = []
    private var finished: [String] = []
    private var cancelled: [String] = []
    private var progressBatchJobs: [String] = []
    private var recordedResumeOptions: [ScpResumeOptions] = []

    init(completionsByJobID: [String: [ScpTransferProgress]]) {
        self.completionsByJobID = completionsByJobID
        for jobID in completionsByJobID.keys {
            gatesByJobID[jobID] = DispatchSemaphore(value: 0)
        }
    }

    var startedJobIDs: [String] {
        locked { started }
    }

    var finishedJobIDs: [String] {
        locked { finished }
    }

    var cancelledJobIDs: [String] {
        locked { cancelled }
    }

    var progressBatchJobIDs: [String] {
        locked { progressBatchJobs }
    }

    var resumeOptionsByRun: [ScpResumeOptions] {
        locked { recordedResumeOptions }
    }

    func release(jobID: String) {
        locked {
            gatesByJobID[jobID]
        }?.signal()
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try runLiveSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: ScpResumeOptions(requestedOffset: 0, forceRestart: false)
        )
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        let gate = locked { () -> DispatchSemaphore in
            started.append(job.id)
            recordedResumeOptions.append(resumeOptions)
            let gate = gatesByJobID[job.id] ?? DispatchSemaphore(value: 0)
            gatesByJobID[job.id] = gate
            return gate
        }
        gate.wait()
        locked {
            finished.append(job.id)
        }
        return completionsByJobID[job.id] ?? []
    }

    func cancelLiveSCPTransfer(jobID: String) -> Bool {
        locked {
            cancelled.append(jobID)
        }
        return true
    }

    func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        locked {
            progressBatchJobs.append(jobID)
            guard var batches = progressBatchesByJobID[jobID], !batches.isEmpty else {
                return []
            }
            let batch = batches.removeFirst()
            progressBatchesByJobID[jobID] = batches
            return batch
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SlowProgressSCPTransferBridge: SCPTransferBridging {
    private let lock = NSLock()
    private let progressDelay: TimeInterval
    private let progress: [ScpTransferProgress]
    private let completion: [ScpTransferProgress]
    private var gate = DispatchSemaphore(value: 0)
    private var started: [String] = []

    init(
        progressDelay: TimeInterval,
        progress: [ScpTransferProgress],
        completion: [ScpTransferProgress]
    ) {
        self.progressDelay = progressDelay
        self.progress = progress
        self.completion = completion
    }

    var startedJobIDs: [String] {
        locked { started }
    }

    func release(jobID: String) {
        gate.signal()
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        locked {
            started.append(job.id)
        }
        gate.wait()
        return completion
    }

    func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        Thread.sleep(forTimeInterval: progressDelay)
        return progress
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class RecordingTransferHistoryStore: SCPTransferHistoryStoring {
    var events: [String] = []
    private let jobs: [ScpTransferJobRecord]
    private let eventsByJobID: [String: [ScpTransferEventRecord]]

    init(
        jobs: [ScpTransferJobRecord] = [],
        eventsByJobID: [String: [ScpTransferEventRecord]] = [:]
    ) {
        self.jobs = jobs
        self.eventsByJobID = eventsByJobID
    }

    func recordJob(sessionID: String?, job: ScpTransferJob, status: String, bytesDone: UInt64) throws {
        events.append("record:\(job.id):\(status):\(bytesDone)")
    }

    func appendProgress(_ progress: ScpTransferProgress) throws -> ScpTransferEventRecord {
        try appendProgress(progress, message: nil)
    }

    func appendProgress(_ progress: ScpTransferProgress, message: String?) throws -> ScpTransferEventRecord {
        let suffix = message.map { ":\($0)" } ?? ""
        events.append("progress:\(progress.jobId):\(progress.status):\(progress.bytesDone)\(suffix)")
        return ScpTransferEventRecord(
            id: "event_\(events.count)",
            jobId: progress.jobId,
            eventType: progress.status,
            message: message,
            bytesDone: progress.bytesDone,
            createdAt: "2026-05-27T00:00:00Z"
        )
    }

    func listJobs() throws -> [ScpTransferJobRecord] {
        events.append("list-jobs")
        return jobs
    }

    func listEvents(jobID: String) throws -> [ScpTransferEventRecord] {
        events.append("list-events:\(jobID)")
        return eventsByJobID[jobID] ?? []
    }

    func clearFinishedJobs() throws -> UInt32 {
        events.append("clear-finished")
        return 0
    }
}

fileprivate extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String? {
        guard column >= 0,
              column < numberOfColumns,
              row >= 0,
              row < numberOfRows
        else {
            return nil
        }
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }

    func fileText(row: Int) -> String? {
        viewText(atColumn: 1, row: row)
    }

    func progressText(row: Int) -> String? {
        viewText(atColumn: 2, row: row)
    }

    func statusText(row: Int) -> String? {
        viewText(atColumn: 3, row: row)
    }
}
