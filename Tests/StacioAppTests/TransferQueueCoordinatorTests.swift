import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class TransferQueueCoordinatorTests: XCTestCase {
    func testCoordinatorDefaultsToTwoConcurrentTransfers() {
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queue)

        XCTAssertEqual(coordinator.maxConcurrentTransfersForTesting, 2)
    }

    func testCompletedSCPTransferPresentsPersistentNotification() throws {
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(
                jobId: "job_notify_completed",
                bytesDone: 128,
                bytesTotal: 128,
                status: "completed"
            )
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let completedAt = Date(timeIntervalSince1970: 1_721_111_111)
        var monotonicTimes: [TimeInterval] = [10, 14]
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue,
            nowProvider: { completedAt },
            monotonicTimeProvider: { monotonicTimes.removeFirst() }
        )
        let job = ScpTransferJob(
            id: "job_notify_completed",
            direction: .upload,
            sourcePath: "/local/release.tar",
            destinationPath: "/srv/release.tar",
            bytesTotal: 128
        )

        _ = try coordinator.runLiveTransfer(
            config: SshConnectionConfig(
                host: "notify.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        XCTAssertEqual(presenter.payloads, [
            TransferCompletionNotificationPayload(
                jobID: job.id,
                runtimeID: "notify.example.com",
                status: .completed,
                title: "文件传输完成",
                body: "上传“release.tar”已完成。",
                itemName: "release.tar",
                byteCount: 128,
                completedAt: completedAt,
                duration: 4,
                averageBytesPerSecond: 32
            )
        ])
    }

    func testCompletedFolderUploadNotificationUsesFinalRecursiveSizeAndAverageRate() throws {
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(
                jobId: "job_notify_folder",
                bytesDone: 4_096,
                bytesTotal: 4_096,
                status: "completed"
            )
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        var monotonicTimes: [TimeInterval] = [20, 24]
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue,
            nowProvider: { Date(timeIntervalSince1970: 1_721_222_222) },
            monotonicTimeProvider: { monotonicTimes.removeFirst() }
        )
        let job = ScpTransferJob(
            id: "job_notify_folder",
            direction: .upload,
            sourcePath: "/local/release-assets",
            destinationPath: "/srv/release-assets",
            bytesTotal: 0
        )

        _ = try coordinator.runLiveTransfer(
            config: SshConnectionConfig(
                host: "notify.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let payload = try XCTUnwrap(presenter.payloads.first)
        XCTAssertEqual(payload.itemName, "release-assets")
        XCTAssertEqual(payload.byteCount, 4_096)
        XCTAssertEqual(payload.duration, 4)
        XCTAssertEqual(payload.averageBytesPerSecond, 1_024)
    }

    func testCompletedFTPNotificationUsesActualBytesWhenQueuedFileSizeChanged() throws {
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let ftpBridge = RecordingFTPTransferBridge(progress: [
            ScpTransferProgress(
                jobId: "job_notify_ftp_size_changed",
                bytesDone: 150,
                bytesTotal: 100,
                status: "completed"
            )
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        var monotonicTimes: [TimeInterval] = [10, 14]
        let coordinator = TransferQueueCoordinator(
            ftpBridge: ftpBridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue,
            monotonicTimeProvider: { monotonicTimes.removeFirst() }
        )
        let job = ScpTransferJob(
            id: "job_notify_ftp_size_changed",
            direction: .upload,
            sourcePath: "/local/release.tar",
            destinationPath: "/srv/release.tar",
            bytesTotal: 100
        )

        _ = try coordinator.runLiveFTPTransfer(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "secret"),
            job: job
        )

        let payload = try XCTUnwrap(presenter.payloads.first)
        XCTAssertEqual(payload.byteCount, 150)
        XCTAssertEqual(payload.duration, 4)
        XCTAssertEqual(payload.averageBytesPerSecond, 37.5)
    }

    func testCompletedFolderNotificationDoesNotLetEstimateOverrideFinalEngineSize() async throws {
        let job = ScpTransferJob(
            id: "job_notify_folder_estimate",
            direction: .upload,
            sourcePath: "/local/release-assets",
            destinationPath: "/srv/release-assets",
            bytesTotal: 0
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 4_096,
                    bytesTotal: 4_096,
                    status: "completed"
                )
            ]
        ])
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        var monotonicTimes: [TimeInterval] = [20, 24]
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue,
            monotonicTimeProvider: { monotonicTimes.removeFirst() }
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime_one",
            config: SshConnectionConfig(
                host: "notify.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let didStart = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(didStart)
        coordinator.updateScheduledTransferEstimatedByteTotal(jobID: job.id, bytesTotal: 8_192)

        bridge.release(jobID: job.id)

        let didPresent = await eventually { presenter.payloads.count == 1 }
        XCTAssertTrue(didPresent)
        let payload = try XCTUnwrap(presenter.payloads.first)
        XCTAssertEqual(payload.byteCount, 4_096)
        XCTAssertEqual(payload.duration, 4)
        XCTAssertEqual(payload.averageBytesPerSecond, 1_024)
    }

    func testPolledTerminalProgressCapturesCompletionTimeBeforeBridgeReturns() async throws {
        let job = ScpTransferJob(
            id: "job_notify_polled_terminal",
            direction: .download,
            sourcePath: "/srv/release.tar",
            destinationPath: "/local/release.tar",
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
        bridge.progressBatchesByJobID[job.id] = [[
            ScpTransferProgress(
                jobId: job.id,
                bytesDone: 100,
                bytesTotal: 100,
                status: "completed"
            )
        ]]
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let observedCompletionDate = Date(timeIntervalSince1970: 1_721_111_111)
        var currentDate = observedCompletionDate
        var monotonicTimes: [TimeInterval] = [10, 14]
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue,
            nowProvider: { currentDate },
            monotonicTimeProvider: { monotonicTimes.removeFirst() }
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime_one",
            config: SshConnectionConfig(
                host: "notify.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )
        let didStart = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(didStart)
        coordinator.pollScheduledTransferProgressForTesting()
        let didObserveCompletion = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(didObserveCompletion)

        currentDate = Date(timeIntervalSince1970: 1_721_111_999)
        bridge.release(jobID: job.id)

        let didPresent = await eventually { presenter.payloads.count == 1 }
        XCTAssertTrue(didPresent)
        let payload = try XCTUnwrap(presenter.payloads.first)
        XCTAssertEqual(payload.completedAt, observedCompletionDate)
        XCTAssertEqual(payload.duration, 4)
    }

    func testFailedSCPTransferPresentsPersistentNotification() {
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let bridge = RecordingSCPTransferBridge(error: SshRuntimeError.Timeout)
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue
        )
        let job = ScpTransferJob(
            id: "job_notify_failed",
            direction: .download,
            sourcePath: "/srv/release.tar",
            destinationPath: "/local/release.tar",
            bytesTotal: 128
        )

        XCTAssertThrowsError(try coordinator.runLiveTransfer(
            config: SshConnectionConfig(
                host: "notify.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        ))

        XCTAssertEqual(presenter.payloads.count, 1)
        XCTAssertEqual(presenter.payloads[0].jobID, job.id)
        XCTAssertEqual(presenter.payloads[0].runtimeID, "notify.example.com")
        XCTAssertEqual(presenter.payloads[0].status, .failed)
        XCTAssertEqual(presenter.payloads[0].title, "文件传输失败")
        XCTAssertTrue(presenter.payloads[0].body.contains("下载“release.tar”失败"))
        XCTAssertTrue(presenter.payloads[0].body.contains("连接超时"))
    }

    func testClosingRuntimeDismissesTransferNotificationsEvenWithoutQueuedJobs() {
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            completionNotificationPresenter: presenter,
            queueViewController: queue
        )

        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "term_closed"), [])

        XCTAssertEqual(presenter.dismissedRuntimeIDs, ["term_closed"])
    }

    func testClosingReattachedRuntimeDismissesPreReconnectTransferNotification() throws {
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(
                jobId: "job_notify_reattached",
                bytesDone: 128,
                bytesTotal: 128,
                status: "completed"
            )
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue
        )
        let job = ScpTransferJob(
            id: "job_notify_reattached",
            direction: .upload,
            sourcePath: "/local/release.tar",
            destinationPath: "/srv/release.tar",
            bytesTotal: 128
        )
        _ = try coordinator.runLiveTransfer(
            config: SshConnectionConfig(
                host: "old-runtime.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        coordinator.reattachTransfers(
            oldRuntimeID: "old-runtime.example.com",
            runtimeID: "term_reconnected"
        )
        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "term_reconnected"), [job.id])

        XCTAssertEqual(
            presenter.dismissedRuntimeIDs,
            ["term_reconnected", "old-runtime.example.com"]
        )
    }

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

    func testCoordinatorSchedulesLiveSFTPTransferThroughSFTPBridge() async {
        let scpBridge = RecordingSCPTransferBridge()
        let sftpBridge = RecordingSFTPTransferBridge(progress: [
            ScpTransferProgress(
                jobId: "sftp_background_upload",
                bytesDone: 128,
                bytesTotal: 128,
                status: "completed"
            )
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            sftpBridge: sftpBridge,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "sftp.example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let job = ScpTransferJob(
            id: "sftp_background_upload",
            direction: .upload,
            sourcePath: "/Users/alice/build.zip",
            destinationPath: "/srv/build.zip",
            bytesTotal: 128
        )

        coordinator.scheduleLiveSFTPTransfer(
            runtimeID: "sftp-pane-runtime",
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(sftpBridge.events, ["run:sftp_background_upload"])
        XCTAssertEqual(scpBridge.events, [])
        XCTAssertEqual(queue.tableView.progressText(row: 0), "100%")
    }

    func testCoordinatorCancelsRunningSFTPTransferThroughSFTPBridgeAndIgnoresLateCompletion() async {
        let job = ScpTransferJob(
            id: "sftp_background_cancel",
            direction: .download,
            sourcePath: "/srv/build.zip",
            destinationPath: "/Users/alice/build.zip",
            bytesTotal: 128
        )
        let scpBridge = RecordingSCPTransferBridge()
        let sftpBridge = BlockingSFTPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 128,
                    bytesTotal: 128,
                    status: "completed"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            sftpBridge: sftpBridge,
            queueViewController: queue
        )

        coordinator.scheduleLiveSFTPTransfer(
            runtimeID: "sftp-pane-runtime",
            config: SshConnectionConfig(
                host: "sftp.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job
        )

        let started = await eventually { sftpBridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)
        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))
        XCTAssertEqual(sftpBridge.cancelledJobIDs, [job.id])
        XCTAssertEqual(scpBridge.events, [])
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已取消")

        sftpBridge.release(jobID: job.id)

        let finished = await eventually { sftpBridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(finished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已取消")
    }

    func testCoordinatorDisconnectDrainsSFTPTransferThroughSFTPBridgeOnly() async {
        let job = ScpTransferJob(
            id: "sftp_disconnect_draining",
            direction: .download,
            sourcePath: "/srv/archive.zip",
            destinationPath: "/Users/alice/archive.zip",
            bytesTotal: 128
        )
        let scpBridge = BlockingSCPTransferBridge(completionsByJobID: [job.id: []])
        let sftpBridge = BlockingSFTPTransferBridge(completionsByJobID: [job.id: []])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            sftpBridge: sftpBridge,
            queueViewController: queue
        )

        coordinator.scheduleLiveSFTPTransfer(
            runtimeID: "sftp-disconnect-runtime",
            config: Self.crossDeviceContext(host: "sftp.example.com").config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:sftp",
            job: job
        )
        let started = await eventually { sftpBridge.startedJobIDs == [job.id] }
        XCTAssertTrue(started)

        XCTAssertEqual(
            coordinator.disconnectTransfers(runtimeID: "sftp-disconnect-runtime"),
            [job.id]
        )

        XCTAssertEqual(sftpBridge.cancelledJobIDs, [job.id])
        XCTAssertTrue(scpBridge.cancelledJobIDs.isEmpty)
        sftpBridge.release(jobID: job.id)
        let finished = await eventually { sftpBridge.finishedJobIDs == [job.id] }
        XCTAssertTrue(finished)
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

    func testCoordinatorWaitsForPausedFTPWorkerBeforeStartingResume() async {
        let ftpBridge = DelayedFTPTransferBridge(
            delay: 0.2,
            progress: [
                ScpTransferProgress(
                    jobId: "ftp_pause_resume_serial",
                    bytesDone: 64,
                    bytesTotal: 64,
                    status: "completed"
                )
            ]
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            ftpBridge: ftpBridge,
            queueViewController: queue
        )
        let job = ScpTransferJob(
            id: "ftp_pause_resume_serial",
            direction: .upload,
            sourcePath: "/Users/alice/readme.txt",
            destinationPath: "/pub/readme.txt",
            bytesTotal: 64
        )
        var completionStatuses: [String] = []
        coordinator.scheduleLiveFTPTransfer(
            runtimeID: "ftp_runtime",
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-secret"),
            job: job,
            completion: { completionStatuses.append($0.status) }
        )
        let started = await eventually { ftpBridge.events == ["run:\(job.id)"] }
        XCTAssertTrue(started)

        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        let overlappedBeforeOriginalRunFinished = await eventually(timeout: 0.1) {
            ftpBridge.events.count > 1
        }
        XCTAssertFalse(overlappedBeforeOriginalRunFinished)

        let restarted = await eventually(timeout: 0.5) {
            ftpBridge.events == ["run:\(job.id)", "run:\(job.id)"]
        }
        XCTAssertTrue(restarted)
        XCTAssertEqual(completionStatuses, [])
        let completed = await eventually(timeout: 0.5) {
            completionStatuses == ["completed"]
        }
        XCTAssertTrue(completed)
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
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
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
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.rows.map(\.jobID) == [firstJob.id, secondJob.id, thirdJob.id]
                && snapshot.rows.map(\.rawStatus) == ["running", "running", "queued"]
        })

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
        var completionStatuses: [String] = []
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
            job: job,
            completion: { completionStatuses.append($0.status) }
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
        XCTAssertEqual(completionStatuses, ["canceled"])
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
        var completionStatuses: [String] = []
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
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        var monotonicTimes: [TimeInterval] = [10, 14, 20, 26]
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            completionNotificationPresenter: presenter,
            queueViewController: queue,
            monotonicTimeProvider: { monotonicTimes.removeFirst() }
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
            job: job,
            completion: { completionStatuses.append($0.status) }
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

        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        let overlappedBeforeOriginalRunFinished = await eventually(timeout: 0.05) {
            bridge.startedJobIDs.count > 1
        }
        XCTAssertFalse(overlappedBeforeOriginalRunFinished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已暂停")

        bridge.release(jobID: job.id)

        let restarted = await eventually { bridge.startedJobIDs == [job.id, job.id] }
        XCTAssertTrue(restarted)
        XCTAssertEqual(bridge.finishedJobIDs, [job.id])
        XCTAssertEqual(completionStatuses, [])
        XCTAssertEqual(queue.tableView.statusText(row: 0), "续传中")
        XCTAssertEqual(snapshots.last?.rows.first?.rawStatus, "resuming")
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.requestedOffset), [0, 40])
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.forceRestart), [false, false])

        bridge.release(jobID: job.id)
        let completed = await eventually { queue.tableView.statusText(row: 0) == "已完成" }
        XCTAssertTrue(completed)
        XCTAssertEqual(completionStatuses, ["completed"])
        XCTAssertEqual(presenter.payloads.first?.duration, 10)
        XCTAssertEqual(presenter.payloads.first?.averageBytesPerSecond, 10)
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
        var completionStatuses: [String] = []
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
            job: job,
            completion: { completionStatuses.append($0.status) }
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

        XCTAssertTrue(coordinator.retryFailedTransfer(jobID: job.id))
        let overlappedBeforeOriginalRunFinished = await eventually(timeout: 0.05) {
            bridge.startedJobIDs.count > 1
        }
        XCTAssertFalse(overlappedBeforeOriginalRunFinished)
        XCTAssertEqual(queue.tableView.statusText(row: 0), "已停止")

        bridge.release(jobID: job.id)
        let restarted = await eventually { bridge.startedJobIDs == [job.id, job.id] }
        XCTAssertTrue(restarted)
        XCTAssertEqual(bridge.finishedJobIDs, [job.id])
        XCTAssertEqual(completionStatuses, [])
        XCTAssertEqual(queue.tableView.statusText(row: 0), "续传中")
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.requestedOffset), [0, 30])
        XCTAssertEqual(bridge.resumeOptionsByRun.map(\.forceRestart), [false, false])

        bridge.release(jobID: job.id)
        let completed = await eventually { queue.tableView.statusText(row: 0) == "已完成" }
        XCTAssertTrue(completed)
        XCTAssertEqual(completionStatuses, ["completed"])
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

    func testCoordinatorKeepsFailedTransferInSnapshotWhileAnotherRunsAndAllowsRetry() async {
        let failedJob = ScpTransferJob(
            id: "ftp_failed_while_scp_runs",
            direction: .upload,
            sourcePath: "/local/failed.tar",
            destinationPath: "/srv/failed.tar",
            bytesTotal: 100
        )
        let runningJob = ScpTransferJob(
            id: "scp_running_after_ftp_failure",
            direction: .download,
            sourcePath: "/srv/running.tar",
            destinationPath: "/local/running.tar",
            bytesTotal: 200
        )
        let scpBridge = BlockingSCPTransferBridge(completionsByJobID: [
            runningJob.id: [
                ScpTransferProgress(
                    jobId: runningJob.id,
                    bytesDone: 200,
                    bytesTotal: 200,
                    status: "completed"
                )
            ]
        ])
        let ftpBridge = RecordingSequenceFTPTransferBridge(results: [
            .failure(SshRuntimeError.Transport(message: "temporary upload failure")),
            .success([
                ScpTransferProgress(
                    jobId: failedJob.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ])
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: scpBridge,
            ftpBridge: ftpBridge,
            queueViewController: queue,
            maxConcurrentTransfers: 2
        )
        var snapshots: [TransferQueueSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        var failedJobCompletionStatuses: [String] = []

        coordinator.scheduleLiveFTPTransfer(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-secret"),
            job: failedJob,
            completion: { failedJobCompletionStatuses.append($0.status) }
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
            job: runningJob
        )

        let failedAndRunningAreVisible = await eventually {
            snapshots.last?.rows.map(\.jobID) == [failedJob.id, runningJob.id]
                && snapshots.last?.rows.map(\.rawStatus) == ["failed", "running"]
        }
        XCTAssertTrue(failedAndRunningAreVisible)
        XCTAssertEqual(failedJobCompletionStatuses, ["failed"])

        XCTAssertTrue(coordinator.retryFailedTransfer(jobID: failedJob.id))
        let retryCompleted = await eventually {
            failedJobCompletionStatuses == ["failed", "completed"]
        }
        XCTAssertTrue(retryCompleted)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.rows.map(\.jobID) == [failedJob.id, runningJob.id]
                && snapshot.rows.map(\.rawStatus) == ["running", "running"]
        })
        XCTAssertEqual(ftpBridge.events, [
            "run:\(failedJob.id)",
            "run:\(failedJob.id)"
        ])

        scpBridge.release(jobID: runningJob.id)
        let runningJobCompleted = await eventually {
            scpBridge.finishedJobIDs == [runningJob.id]
        }
        XCTAssertTrue(runningJobCompleted)
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
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            historyStore: history,
            completionNotificationPresenter: presenter,
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
        XCTAssertEqual(presenter.payloads.map(\.jobID), [job.id])
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

    func testCoordinatorDisconnectKeepsRemovedWorkerInConcurrencyLimitUntilItFinishes() async {
        let firstJob = ScpTransferJob(
            id: "job_disconnect_draining_first",
            direction: .upload,
            sourcePath: "/local/first.tar",
            destinationPath: "/srv/first.tar",
            bytesTotal: 100
        )
        let secondJob = ScpTransferJob(
            id: "job_disconnect_draining_second",
            direction: .upload,
            sourcePath: "/local/second.tar",
            destinationPath: "/srv/second.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            firstJob.id: [
                ScpTransferProgress(jobId: firstJob.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ],
            secondJob.id: [
                ScpTransferProgress(jobId: secondJob.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ]
        ])
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
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
        var firstCompletionStatuses: [String] = []

        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-disconnect-first",
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: firstJob,
            completion: { firstCompletionStatuses.append($0.status) }
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-disconnect-second",
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: secondJob
        )
        let firstStarted = await eventually { bridge.startedJobIDs == [firstJob.id] }
        XCTAssertTrue(firstStarted)

        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "runtime-disconnect-first"), [firstJob.id])
        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "runtime-disconnect-first"), [])
        XCTAssertEqual(bridge.cancelledJobIDs, [firstJob.id])
        XCTAssertEqual(queue.snapshotForTesting.rows.map(\.jobID), [secondJob.id])
        let overlappedBeforeFirstFinished = await eventually(timeout: 0.05) {
            bridge.startedJobIDs.count > 1
        }
        XCTAssertFalse(overlappedBeforeFirstFinished)

        bridge.release(jobID: firstJob.id)
        let secondStarted = await eventually {
            bridge.finishedJobIDs.contains(firstJob.id)
                && bridge.startedJobIDs == [firstJob.id, secondJob.id]
        }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(firstCompletionStatuses, ["canceled"])
        XCTAssertFalse(presenter.payloads.contains { $0.jobID == firstJob.id })

        bridge.release(jobID: secondJob.id)
        let secondCompleted = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(secondCompleted)
    }

    func testCoordinatorDisconnectDeliversWorkerTerminalStateWhenCancellationIsRejectedWithoutRevivingUI() async {
        let job = ScpTransferJob(
            id: "job_disconnect_rejected_cancel",
            direction: .upload,
            sourcePath: "/local/report.txt",
            destinationPath: "/srv/report.txt",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(
            completionsByJobID: [
                job.id: [
                    ScpTransferProgress(
                        jobId: job.id,
                        bytesDone: 100,
                        bytesTotal: 100,
                        status: "completed"
                    )
                ]
            ],
            acceptsCancellation: false
        )
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue
        )
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        var completionStatuses: [String] = []
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-disconnect-rejected",
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: job,
            completion: { completionStatuses.append($0.status) }
        )
        let didStart = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(didStart)

        XCTAssertEqual(
            coordinator.disconnectTransfers(runtimeID: "runtime-disconnect-rejected"),
            [job.id]
        )
        XCTAssertEqual(queue.snapshotForTesting.rows, [])
        bridge.release(jobID: job.id)

        let didComplete = await eventually { completionStatuses == ["completed"] }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(queue.snapshotForTesting.rows, [])
        XCTAssertTrue(presenter.payloads.isEmpty)
    }

    func testCoordinatorCancelsRunningTransferThroughReattachedRuntimeID() async {
        let job = ScpTransferJob(
            id: "job_runtime_reattached",
            direction: .upload,
            sourcePath: "/local/reattached.tar",
            destinationPath: "/srv/reattached.tar",
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
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            queueViewController: queue
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-old",
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
        let didStart = await eventually {
            bridge.startedJobIDs == [job.id]
        }
        XCTAssertTrue(didStart)

        coordinator.reattachTransfers(oldRuntimeID: "runtime-old", runtimeID: "runtime-new")
        XCTAssertEqual(coordinator.disconnectTransfers(runtimeID: "runtime-new"), [job.id])

        XCTAssertEqual(bridge.cancelledJobIDs, [job.id])
        XCTAssertEqual(queue.snapshotForTesting.rows, [])
        bridge.release(jobID: job.id)
    }

    func testReattachedTransferCompletionUsesCurrentRuntimeIDForNotification() async {
        let job = ScpTransferJob(
            id: "job_runtime_notification_reattached",
            direction: .download,
            sourcePath: "/srv/reattached.tar",
            destinationPath: "/local/reattached.tar",
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
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-before-reconnect",
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
        let didStart = await eventually {
            bridge.startedJobIDs == [job.id]
        }
        XCTAssertTrue(didStart)

        coordinator.reattachTransfers(
            oldRuntimeID: "runtime-before-reconnect",
            runtimeID: "runtime-after-reconnect"
        )
        bridge.release(jobID: job.id)
        let didPresent = await eventually {
            presenter.payloads.count == 1
        }
        XCTAssertTrue(didPresent)
        XCTAssertEqual(presenter.payloads.first?.runtimeID, "runtime-after-reconnect")
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
        var completionStatuses: [String] = []
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
            job: job,
            completion: { completionStatuses.append($0.status) }
        )

        let failed = await eventually {
            queue.tableView.statusText(row: 0) == "失败"
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(completionStatuses, ["failed"])
        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(queue.selectedTransferDetailTextForTesting.contains("认证失败 [已隐藏凭据] [已隐藏路径]"))

        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        queue.performTransferActionForTesting(at: 0)

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(completionStatuses, ["failed", "completed"])
        XCTAssertEqual(bridge.events, ["run:job_retry_scheduled_scp", "run:job_retry_scheduled_scp"])
        XCTAssertFalse(bridge.debugDescription.contains("top-secret-password"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("top-secret-password"))
        XCTAssertFalse(queue.visibleTextSnapshot.contains("/Users/me/.ssh/id_ed25519"))
    }

    func testCoordinatorRetriesFailedScheduledFTPTransferFromQueueActionWithoutExposingSecret() async {
        var completionStatuses: [String] = []
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
            job: job,
            completion: { completionStatuses.append($0.status) }
        )

        let failed = await eventually {
            queue.tableView.statusText(row: 0) == "失败"
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(completionStatuses, ["failed"])

        queue.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        queue.performTransferActionForTesting(at: 0)

        let completed = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(completionStatuses, ["failed", "completed"])
        XCTAssertEqual(ftpBridge.events, ["run:job_retry_scheduled_ftp", "run:job_retry_scheduled_ftp"])
        XCTAssertFalse(ftpBridge.debugDescription.contains("ftp-secret"))
        XCTAssertFalse(queue.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testRestoreHistoryDiscardsEveryOrchestratedRetryBeforeCallbacksMutateRegistry() throws {
        let replacementJob = ScpTransferJob(
            id: "relay-restore-replacement",
            direction: .download,
            sourcePath: "/srv/replacement.bin",
            destinationPath: "/tmp/replacement.bin",
            bytesTotal: 128
        )
        let history = RecordingTransferHistoryStore(jobs: [
            ScpTransferJobRecord(
                job: replacementJob,
                sessionId: nil,
                status: "failed",
                bytesDone: 0
            )
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            historyStore: history,
            queueViewController: queue
        )
        var discardedJobIDs: [String] = []
        var retriedReplacement = false
        for jobID in ["relay-restore-one", "relay-restore-two"] {
            coordinator.registerOrchestratedRetry(
                jobID: jobID,
                runtimeIDs: ["runtime-restore"],
                retry: { false },
                discard: { [weak coordinator] in
                    discardedJobIDs.append(jobID)
                    coordinator?.unregisterOrchestratedRetry(jobID: jobID)
                    guard jobID == "relay-restore-one" else { return }
                    coordinator?.registerOrchestratedRetry(
                        jobID: replacementJob.id,
                        runtimeIDs: ["runtime-replacement"],
                        retry: {
                            retriedReplacement = true
                            return true
                        },
                        discard: {}
                    )
                }
            )
        }

        try coordinator.restoreHistory()

        XCTAssertEqual(Set(discardedJobIDs), Set(["relay-restore-one", "relay-restore-two"]))
        XCTAssertEqual(discardedJobIDs.count, 2)
        XCTAssertTrue(coordinator.retryFailedTransfer(jobID: replacementJob.id))
        XCTAssertTrue(retriedReplacement)
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

    func testCoordinatorRemovesOnlyRequestedFinishedTransferAndKeepsActiveTransfers() {
        let history = RecordingTransferHistoryStore()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            historyStore: history,
            queueViewController: queue
        )
        let completedJob = ScpTransferJob(
            id: "job_completed_remove_one",
            direction: .upload,
            sourcePath: "/local/completed.tar",
            destinationPath: "/srv/completed.tar",
            bytesTotal: 100
        )
        let failedJob = ScpTransferJob(
            id: "job_failed_keep",
            direction: .download,
            sourcePath: "/srv/failed.tar",
            destinationPath: "/local/failed.tar",
            bytesTotal: 100
        )
        let runningJob = ScpTransferJob(
            id: "job_running_keep_after_single_remove",
            direction: .download,
            sourcePath: "/srv/running.tar",
            destinationPath: "/local/running.tar",
            bytesTotal: 100
        )
        coordinator.enqueueTransfer(job: completedJob)
        coordinator.enqueueTransfer(job: failedJob)
        coordinator.enqueueTransfer(job: runningJob)
        coordinator.replaceProgressForTesting(jobID: completedJob.id, status: "completed", bytesDone: 100)
        coordinator.replaceProgressForTesting(jobID: failedJob.id, status: "failed", bytesDone: 40)
        coordinator.replaceProgressForTesting(jobID: runningJob.id, status: "running", bytesDone: 25)

        XCTAssertTrue(coordinator.removeFinishedTransfer(jobID: completedJob.id))
        XCTAssertFalse(coordinator.removeFinishedTransfer(jobID: runningJob.id))

        XCTAssertTrue(history.events.contains("delete-finished:\(completedJob.id)"))
        XCTAssertFalse(history.events.contains("delete-finished:\(runningJob.id)"))
        XCTAssertEqual(queue.snapshotForTesting.rows.map(\.jobID), [failedJob.id, runningJob.id])
    }

    func testCoordinatorKeepsFinishedTransferWhenPersistentSingleDeleteIsRejected() {
        let history = RecordingTransferHistoryStore(deleteFinishedResult: false)
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            historyStore: history,
            queueViewController: queue
        )
        let completedJob = ScpTransferJob(
            id: "job_completed_delete_rejected",
            direction: .upload,
            sourcePath: "/local/completed.tar",
            destinationPath: "/srv/completed.tar",
            bytesTotal: 100
        )
        coordinator.enqueueTransfer(job: completedJob)
        coordinator.replaceProgressForTesting(
            jobID: completedJob.id,
            status: "completed",
            bytesDone: 100
        )

        XCTAssertFalse(coordinator.removeFinishedTransfer(jobID: completedJob.id))
        XCTAssertEqual(queue.snapshotForTesting.rows.map(\.jobID), [completedJob.id])
        XCTAssertEqual(history.events.last, "delete-finished:\(completedJob.id)")
    }

    func testCoordinatorKeepsFinishedTransfersWhenPersistentClearFails() {
        let history = RecordingTransferHistoryStore(clearFinishedShouldThrow: true)
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            historyStore: history,
            queueViewController: queue
        )
        let completedJob = ScpTransferJob(
            id: "job_completed_clear_failed",
            direction: .download,
            sourcePath: "/srv/completed.tar",
            destinationPath: "/local/completed.tar",
            bytesTotal: 100
        )
        coordinator.enqueueTransfer(job: completedJob)
        coordinator.replaceProgressForTesting(
            jobID: completedJob.id,
            status: "completed",
            bytesDone: 100
        )

        XCTAssertEqual(coordinator.clearFinishedTransfers(), 0)
        XCTAssertEqual(queue.snapshotForTesting.rows.map(\.jobID), [completedJob.id])
        XCTAssertEqual(history.events.last, "clear-finished")
    }

    func testCoordinatorClearFinishedKeepsRemovedWorkerInConcurrencyLimitUntilItFinishes() async {
        let firstJob = ScpTransferJob(
            id: "job_clear_draining_first",
            direction: .download,
            sourcePath: "/srv/first.tar",
            destinationPath: "/local/first.tar",
            bytesTotal: 100
        )
        let secondJob = ScpTransferJob(
            id: "job_clear_draining_second",
            direction: .download,
            sourcePath: "/srv/second.tar",
            destinationPath: "/local/second.tar",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            firstJob.id: [
                ScpTransferProgress(jobId: firstJob.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ],
            secondJob.id: [
                ScpTransferProgress(jobId: secondJob.id, bytesDone: 100, bytesTotal: 100, status: "completed")
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

        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-clear-first",
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: firstJob
        )
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime-clear-second",
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            job: secondJob
        )
        let firstStarted = await eventually { bridge.startedJobIDs == [firstJob.id] }
        XCTAssertTrue(firstStarted)

        XCTAssertTrue(coordinator.stopTransfer(jobID: firstJob.id))
        XCTAssertEqual(coordinator.clearFinishedTransfers(), 1)
        XCTAssertEqual(queue.snapshotForTesting.rows.map(\.jobID), [secondJob.id])
        XCTAssertEqual(queue.snapshotForTesting.rows.first?.rawStatus, "queued")
        let overlappedBeforeFirstFinished = await eventually(timeout: 0.05) {
            bridge.startedJobIDs.count > 1
        }
        XCTAssertFalse(overlappedBeforeFirstFinished)

        bridge.release(jobID: firstJob.id)
        let secondStarted = await eventually {
            bridge.finishedJobIDs.contains(firstJob.id)
                && bridge.startedJobIDs == [firstJob.id, secondJob.id]
        }
        XCTAssertTrue(secondStarted)

        bridge.release(jobID: secondJob.id)
        let secondCompleted = await eventually {
            queue.tableView.statusText(row: 0) == "已完成"
        }
        XCTAssertTrue(secondCompleted)
    }

    func testCancellationDeliversTerminalCompletionForDependentCleanup() async {
        let job = ScpTransferJob(
            id: "job_cancel_cleanup_callback",
            direction: .download,
            sourcePath: "/srv/report.txt",
            destinationPath: "/tmp/report.txt",
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
        var terminalProgress: ScpTransferProgress?

        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime_cancel_cleanup",
            config: Self.crossDeviceContext(host: "source.example.com").config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:source",
            job: job,
            completion: { terminalProgress = $0 }
        )
        let didStart = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(didStart)

        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))

        XCTAssertNil(terminalProgress, "dependent cleanup must wait until the worker has actually stopped")
        bridge.release(jobID: job.id)
        let didAcknowledgeCancellation = await eventually {
            terminalProgress?.status == "canceled"
        }
        XCTAssertTrue(didAcknowledgeCancellation)
        XCTAssertEqual(terminalProgress?.jobId, job.id)
    }

    func testRunningTransferCancellationRejectedByWorkerRemainsRetryable() async {
        let job = ScpTransferJob(
            id: "job_cancel_rejected",
            direction: .download,
            sourcePath: "/srv/report.txt",
            destinationPath: "/tmp/report.txt",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(
            completionsByJobID: [job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 100,
                    bytesTotal: 100,
                    status: "completed"
                )
            ]],
            acceptsCancellation: false
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        var terminalProgress: ScpTransferProgress?
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime_cancel_rejected",
            config: Self.crossDeviceContext(host: "source.example.com").config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:source",
            job: job,
            completion: { terminalProgress = $0 }
        )
        let didStart = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(didStart)

        XCTAssertFalse(coordinator.cancelTransfer(jobID: job.id))
        XCTAssertEqual(queue.tableView.statusText(row: 0), "传输中")
        XCTAssertNil(terminalProgress)

        bridge.release(jobID: job.id)
        let didComplete = await eventually { terminalProgress?.status == "completed" }
        XCTAssertTrue(didComplete)
    }

    func testAcceptedCancellationClearsSinglePhaseRetryAfterOrchestratorUnregisters() async {
        let job = ScpTransferJob(
            id: "job_orchestrated_cancel",
            direction: .download,
            sourcePath: "/srv/report.txt",
            destinationPath: "/tmp/report.txt",
            bytesTotal: 100
        )
        let bridge = BlockingSCPTransferBridge(completionsByJobID: [
            job.id: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 0,
                    bytesTotal: 100,
                    status: "canceled"
                )
            ]
        ])
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        var orchestratedRetryCount = 0
        coordinator.scheduleLiveTransfer(
            runtimeID: "runtime_orchestrated_cancel",
            config: Self.crossDeviceContext(host: "source.example.com").config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:source",
            job: job,
            completion: { [weak coordinator] progress in
                if progress.status == "canceled" {
                    coordinator?.unregisterOrchestratedRetry(jobID: job.id)
                }
            }
        )
        coordinator.registerOrchestratedRetry(
            jobID: job.id,
            runtimeIDs: ["runtime_orchestrated_cancel"],
            retry: {
                orchestratedRetryCount += 1
                return true
            },
            discard: {}
        )
        let didStart = await eventually { bridge.startedJobIDs == [job.id] }
        XCTAssertTrue(didStart)

        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))
        bridge.release(jobID: job.id)
        let didCancel = await eventually {
            queue.snapshotForTesting.rows.first?.rawStatus == "canceled"
        }
        XCTAssertTrue(didCancel)

        XCTAssertFalse(coordinator.retryFailedTransfer(jobID: job.id))
        XCTAssertEqual(orchestratedRetryCount, 0)
        XCTAssertEqual(bridge.startedJobIDs, [job.id])
    }

    func testOrchestratedCleanupRetryKeepsFailedRowRecoverableAndDoesNotOverwriteSuccessWithQueued() {
        let job = ScpTransferJob(
            id: "job_orchestrated_cleanup_retry",
            direction: .upload,
            sourcePath: "/tmp/report.txt",
            destinationPath: "/srv/report.txt",
            bytesTotal: 100
        )
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queue)
        coordinator.enqueueTransfer(job: job)
        coordinator.replaceProgressForTesting(jobID: job.id, status: "failed", bytesDone: 0)
        var retryAttempts = 0
        coordinator.registerOrchestratedRetry(
            jobID: job.id,
            runtimeIDs: ["source", "destination"],
            retry: { [weak coordinator] in
                retryAttempts += 1
                if retryAttempts == 2 {
                    coordinator?.replaceProgressForTesting(
                        jobID: job.id,
                        status: "completed",
                        bytesDone: job.bytesTotal
                    )
                }
                return true
            },
            discard: {}
        )

        XCTAssertTrue(coordinator.retryFailedTransfer(jobID: job.id))
        XCTAssertEqual(queue.snapshotForTesting.rows.first?.rawStatus, "failed")

        coordinator.replaceProgressForTesting(jobID: job.id, status: "failed", bytesDone: 0)
        XCTAssertTrue(coordinator.retryFailedTransfer(jobID: job.id))
        XCTAssertEqual(retryAttempts, 2)
        XCTAssertEqual(queue.snapshotForTesting.rows.first?.rawStatus, "completed")
        XCTAssertFalse(queue.snapshotForTesting.rows.contains { $0.rawStatus == "queued" })
    }

    func testSessionQueueObservationFiltersRuntimeAndOrdersActiveBeforeNewestHistory() {
        var now = Date(timeIntervalSince1970: 100)
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            queueViewController: queue,
            nowProvider: { now }
        )
        let oldFinished = ScpTransferJob(
            id: "session_old_finished",
            direction: .download,
            sourcePath: "/srv/old.iso",
            destinationPath: "/tmp/old.iso",
            bytesTotal: 100
        )
        let newestFinished = ScpTransferJob(
            id: "session_new_finished",
            direction: .download,
            sourcePath: "/srv/new.iso",
            destinationPath: "/tmp/new.iso",
            bytesTotal: 200
        )
        let active = ScpTransferJob(
            id: "session_active",
            direction: .upload,
            sourcePath: "/tmp/current.iso",
            destinationPath: "/srv/current.iso",
            bytesTotal: 300
        )
        let anotherSession = ScpTransferJob(
            id: "other_session",
            direction: .upload,
            sourcePath: "/tmp/other.iso",
            destinationPath: "/srv/other.iso",
            bytesTotal: 400
        )

        coordinator.enqueueTransfer(runtimeID: "session-a", job: oldFinished)
        coordinator.replaceProgressForTesting(jobID: oldFinished.id, status: "completed", bytesDone: 100)
        now = Date(timeIntervalSince1970: 200)
        coordinator.enqueueTransfer(runtimeID: "session-a", job: newestFinished)
        coordinator.replaceProgressForTesting(jobID: newestFinished.id, status: "completed", bytesDone: 200)
        now = Date(timeIntervalSince1970: 300)
        coordinator.enqueueTransfer(runtimeID: "session-a", job: active)
        coordinator.replaceProgressForTesting(jobID: active.id, status: "running", bytesDone: 75)
        coordinator.enqueueTransfer(runtimeID: "session-b", job: anotherSession)

        var snapshots: [TransferQueueSnapshot] = []
        let observation = coordinator.observeQueue(runtimeIDs: { ["session-a"] }) {
            snapshots.append($0)
        }
        defer { coordinator.removeQueueObservation(observation) }

        XCTAssertEqual(
            snapshots.last?.rows.map(\.jobID),
            [active.id, newestFinished.id, oldFinished.id]
        )
        XCTAssertEqual(snapshots.last?.rows.first?.elapsedTime, 0)
        XCTAssertEqual(snapshots.last?.rows.dropFirst().compactMap(\.finishedAt), [
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 100)
        ])
    }

    func testSilentTransferCompletionDoesNotPresentNotification() async {
        let job = ScpTransferJob(
            id: "silent_preview_download",
            direction: .download,
            sourcePath: "/srv/preview.png",
            destinationPath: "/tmp/preview.png",
            bytesTotal: 128
        )
        let bridge = RecordingSCPTransferBridge(progress: [
            ScpTransferProgress(
                jobId: job.id,
                bytesDone: job.bytesTotal,
                bytesTotal: job.bytesTotal,
                status: "completed"
            )
        ])
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let queue = TransferQueueViewController()
        queue.loadView()
        let coordinator = TransferQueueCoordinator(
            bridge: bridge,
            completionNotificationPresenter: presenter,
            queueViewController: queue
        )

        coordinator.scheduleLiveTransfer(
            runtimeID: "preview-runtime",
            config: Self.crossDeviceContext(host: "preview.example.com").config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:preview",
            job: job,
            notificationPolicy: .silent,
            completion: nil
        )

        let completed = await eventually {
            queue.snapshotForTesting.rows.first?.rawStatus == "completed"
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(presenter.payloads.isEmpty)
    }

    func testCrossDeviceTransferPresentsOneCompletionNotification() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = []
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let presenter = RecordingTransferCompletionNotificationPresenter()
        let coordinator = CrossDeviceTransferCoordinator(
            completionNotificationPresenter: presenter
        )
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "notify-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "notify-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { _ in }
        )

        let notified = await eventually { presenter.payloads.count == 1 }
        XCTAssertTrue(notified)
        XCTAssertEqual(presenter.payloads.first?.runtimeID, destination.runtimeID)
        XCTAssertEqual(presenter.payloads.first?.status, .completed)
        XCTAssertEqual(presenter.payloads.first?.byteCount, 10)
        XCTAssertEqual(presenter.payloads.first?.itemName, "report.txt")
    }

    func testDirectRemoteTransferAppearsInDestinationSessionQueueUntilCompleted() async {
        let filesBridge = CrossDeviceRecordingRemoteBridge()
        filesBridge.entriesByPath["/archive"] = []
        let directBridge = RecordingRemoteToRemoteTransferBridge(delay: 0.15)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let transferQueue = TransferQueueCoordinator(queueViewController: queueView)
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "direct-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: filesBridge,
            transferScheduler: transferQueue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "direct-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: filesBridge,
            transferScheduler: transferQueue
        )
        var snapshots: [TransferQueueSnapshot] = []
        let observation = transferQueue.observeQueue(runtimeIDs: { ["direct-destination"] }) {
            snapshots.append($0)
        }
        defer { transferQueue.removeQueueObservation(observation) }

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { _ in }
        )

        let appeared = await eventually {
            snapshots.contains { snapshot in
                snapshot.rows.contains { $0.rawStatus == "running" && $0.runtimeID == destination.runtimeID }
            }
        }
        XCTAssertTrue(appeared)
        let completed = await eventually {
            snapshots.last?.rows.first?.rawStatus == "completed"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(snapshots.last?.rows.first?.bytesDone, 10)
    }

    func testExternalTransferQueuePauseResumeAndCancelInvokeTransportControls() {
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queueView)
        let job = ScpTransferJob(
            id: "external-controls",
            direction: .upload,
            sourcePath: "/source/archive.iso",
            destinationPath: "/destination/archive.iso",
            bytesTotal: 100
        )
        var pauseCount = 0
        var resumeCount = 0
        var cancelCount = 0
        var latest = TransferQueueSnapshot(rows: [])
        let observation = coordinator.observeQueue(runtimeIDs: { ["external-runtime"] }) { latest = $0 }
        defer { coordinator.removeQueueObservation(observation) }
        coordinator.registerExternalTransfer(
            runtimeID: "external-runtime",
            job: job,
            progressProvider: { [] },
            pause: { pauseCount += 1; return true },
            resume: { resumeCount += 1; return true },
            cancel: { cancelCount += 1; return true }
        )

        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
        XCTAssertEqual(latest.rows.first?.rawStatus, "paused")
        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        XCTAssertEqual(latest.rows.first?.rawStatus, "resuming")
        XCTAssertTrue(coordinator.cancelTransfer(jobID: job.id))
        XCTAssertEqual(latest.rows.first?.rawStatus, "canceled")
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(cancelCount, 1)
    }

    func testExternalTransferCanReuseStableRecoveryJobIDAfterCompletion() {
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queueView)
        let job = ScpTransferJob(
            id: "stable-direct-route",
            direction: .upload,
            sourcePath: "/source/archive.iso",
            destinationPath: "/destination/archive.iso",
            bytesTotal: 100
        )
        var snapshots: [TransferQueueSnapshot] = []
        let observation = coordinator.observeQueue(runtimeIDs: { ["destination-runtime"] }) {
            snapshots.append($0)
        }
        defer { coordinator.removeQueueObservation(observation) }

        for _ in 0..<2 {
            coordinator.registerExternalTransfer(
                runtimeID: "destination-runtime",
                job: job,
                progressProvider: { [] },
                pause: { true },
                resume: { true },
                cancel: { true }
            )
            XCTAssertEqual(snapshots.last?.rows.first?.rawStatus, "running")
            coordinator.finishExternalTransfer(
                jobID: job.id,
                status: "completed",
                bytesDone: job.bytesTotal
            )
            XCTAssertEqual(snapshots.last?.rows.first?.rawStatus, "completed")
        }
        XCTAssertEqual(snapshots.last?.rows.count, 1)
    }

    func testLocalFileCopyRunsThroughSessionQueueAndPreservesContents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalQueue-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = sourceDirectory.appendingPathComponent("archive.bin")
        let destinationURL = destinationDirectory.appendingPathComponent("archive.bin")
        let contents = Data((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        try contents.write(to: sourceURL)

        let queueView = TransferQueueViewController()
        queueView.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queueView)
        var snapshots: [TransferQueueSnapshot] = []
        let observation = coordinator.observeQueue(runtimeIDs: { ["local-pane"] }) {
            snapshots.append($0)
        }
        defer { coordinator.removeQueueObservation(observation) }
        var result: LocalFileTransferResult?

        let jobID = coordinator.scheduleLocalFileTransfer(
            runtimeID: "local-pane",
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            operation: .copy,
            notificationPolicy: .silent,
            completion: { result = $0 }
        )

        let completed = await eventually(timeout: 3) {
            result == .completed
                && snapshots.last?.rows.first(where: { $0.jobID == jobID })?.rawStatus == "completed"
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(try Data(contentsOf: destinationURL), contents)
        let row = try XCTUnwrap(snapshots.last?.rows.first(where: { $0.jobID == jobID }))
        XCTAssertEqual(row.bytesDone, UInt64(contents.count))
        XCTAssertEqual(row.bytesTotal, UInt64(contents.count))
        XCTAssertNotNil(row.finishedAt)
    }

    func testLocalFileTransferTaskPausesWithoutAdvancingAndResumes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalPause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let destinationURL = root.appendingPathComponent("destination.bin")
        try Data(repeating: 0x4A, count: 2 * 1_024 * 1_024).write(to: sourceURL)
        let task = LocalFileTransferTask(
            jobID: "local-pause",
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            operation: .copy,
            chunkSize: 64 * 1_024,
            chunkDelay: 0.005
        )
        let worker = Task.detached { task.run() }
        let started = await eventually {
            task.currentProgress.bytesDone >= 64 * 1_024
        }
        XCTAssertTrue(started)

        XCTAssertTrue(task.pause())
        try await Task.sleep(nanoseconds: 30_000_000)
        let pausedBytes = task.currentProgress.bytesDone
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(task.currentProgress.bytesDone, pausedBytes)

        XCTAssertTrue(task.resume())
        let result = await worker.value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(try Data(contentsOf: destinationURL), try Data(contentsOf: sourceURL))
    }

    func testLocalFileTransferTaskCancellationRemovesPartialDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let destinationURL = root.appendingPathComponent("destination.bin")
        try Data(repeating: 0x5B, count: 2 * 1_024 * 1_024).write(to: sourceURL)
        let task = LocalFileTransferTask(
            jobID: "local-cancel",
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            operation: .copy,
            chunkSize: 64 * 1_024,
            chunkDelay: 0.005
        )
        let worker = Task.detached { task.run() }
        let started = await eventually {
            task.currentProgress.bytesDone >= 64 * 1_024
        }
        XCTAssertTrue(started)

        XCTAssertTrue(task.cancel())
        let result = await worker.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    ".destination.bin.stacio-transfer-local-cancel.partial"
                ).path
            )
        )
    }

    func testLocalFileTransferRestoresExistingDestinationWhenBackupCleanupFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.txt")
        let destinationURL = root.appendingPathComponent("destination.txt")
        try Data("new contents".utf8).write(to: sourceURL)
        try Data("existing contents".utf8).write(to: destinationURL)
        let fileManager = LocalFileFailingBackupCleanupFileManager()
        let task = LocalFileTransferTask(
            jobID: "local-rollback",
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            operation: .copy,
            fileManager: fileManager
        )

        guard case .failed = task.run() else {
            return XCTFail("备份清理失败时传输必须报告失败")
        }

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "new contents")
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "existing contents")
        let residualNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(residualNames.contains { $0.contains(".stacio-backup-") })
        XCTAssertFalse(residualNames.contains { $0.contains(".stacio-transfer-") })
    }

    func testSameHostTransferUsesResumableDirectEngineWhenAvailable() async {
        let filesBridge = CrossDeviceRecordingRemoteBridge()
        filesBridge.entriesByPath["/archive"] = []
        let directBridge = RecordingRemoteToRemoteTransferBridge(delay: 0.02)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let context = Self.crossDeviceContext(host: "files.example.com")
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-direct-source",
            title: "源目录",
            context: context,
            bridge: filesBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-direct-destination",
            title: "目标目录",
            context: context,
            bridge: filesBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/archive.bin", size: 1_024)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let completed = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(completed)
        XCTAssertEqual(directBridge.requests.count, 1)
        XCTAssertTrue(filesBridge.copiedPaths.isEmpty)
    }

    func testCrossDeviceTransferUsesRemoteCopyForSameHostAndKeepsConflictingName() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(
                kind: .file,
                path: "/archive/report.txt",
                size: 10,
                modifiedTime: nil,
                linkTarget: nil,
                owner: nil,
                permissions: nil
            )
        ]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let coordinator = CrossDeviceTransferCoordinator()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "source-runtime",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "destination-runtime",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .keepBoth,
            statusHandler: { statuses.append($0) }
        )

        let didCopy = await eventually {
            bridge.copiedPaths == [
                CrossDeviceRecordingRemoteBridge.PathPair(
                    from: "/incoming/report.txt",
                    to: "/archive/report (2).txt"
                )
            ]
        }
        XCTAssertTrue(didCopy)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(statuses.last, .completed)
    }

    func testCrossDeviceSameHostReplaceUsesAtomicRemoteOperationWithoutPreDelete() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let coordinator = CrossDeviceTransferCoordinator()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didComplete = await eventually { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        let copiedPath = bridge.copiedPaths.first?.to
        XCTAssertNotEqual(copiedPath, "/archive/report.txt")
        XCTAssertTrue(copiedPath?.contains(".stacio-transfer-") == true)
        XCTAssertFalse(bridge.deletedPaths.contains("/archive/report.txt"))
    }

    func testSameHostReplaceDoesNotMergeStaleDirectoryChildren() async throws {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .directory, path: "/archive/site", size: 0, linkTarget: nil)
        ]
        bridge.directoryChildren = [
            "/incoming/site": ["index.html", "assets/app.js"],
            "/archive/site": ["old.html", "assets/legacy.js"]
        ]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let coordinator = CrossDeviceTransferCoordinator()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-directory-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-directory-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/site", size: 0, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didComplete = await eventually { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(bridge.directoryChildren["/archive/site"], ["index.html", "assets/app.js"])
        XCTAssertFalse(bridge.directoryChildren["/archive/site"]?.contains("old.html") == true)
        XCTAssertFalse(bridge.directoryChildren.keys.contains { $0.contains(".stacio-transfer-") })
        XCTAssertFalse(bridge.directoryChildren.keys.contains { $0.contains(".stacio-backup-") })
    }

    func testSameHostPromotionFailureRollsBackOriginalDestinationAndCleansStage() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 3, linkTarget: nil)
        ]
        bridge.directoryChildren = [
            "/incoming/report.txt": ["new"],
            "/archive/report.txt": ["old"]
        ]
        bridge.renameFailuresByDestination = ["/archive/report.txt": 1]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let coordinator = CrossDeviceTransferCoordinator()
        let endpoint = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-rollback",
            title: "服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 3)],
            from: endpoint,
            to: endpoint,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFail = await eventually {
            guard case .failed = statuses.last else { return false }
            return true
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(bridge.directoryChildren["/archive/report.txt"], ["old"])
        XCTAssertFalse(bridge.directoryChildren.keys.contains { $0.contains(".stacio-transfer-") })
        XCTAssertFalse(bridge.directoryChildren.keys.contains { $0.contains(".stacio-backup-") })
    }

    func testCrossDeviceTransferRejectsSourceEqualToDestinationBeforeMutation() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let endpoint = CrossDeviceRemoteEndpoint(
            runtimeID: "same-path-runtime",
            title: "服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        let coordinator = coordinatorForSamePathTest()
        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/archive/report.txt", size: 10)],
            from: endpoint,
            to: endpoint,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didRejectSamePath = await eventually {
            guard let status = statuses.last else { return false }
            if case .failed = status { return true }
            return false
        }
        XCTAssertTrue(didRejectSamePath)
        XCTAssertTrue(bridge.copiedPaths.isEmpty)
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testCrossDeviceTransferRelaysSameAbsolutePathAcrossDifferentHosts() async {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRelaySamePath-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/srv"] = []
        let sourceScheduler = CrossDeviceRecordingTransferScheduler()
        sourceScheduler.completesImmediately = true
        sourceScheduler.materializesDownloads = true
        let destinationScheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "same-path-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: sourceScheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "same-path-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: destinationScheduler
        )
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: { relayRoot })
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/srv/a", size: 1)],
            from: source,
            to: destination,
            destinationDirectory: "/srv",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didScheduleRelay = await eventually { destinationScheduler.jobs.count == 1 }
        XCTAssertTrue(didScheduleRelay)
        XCTAssertEqual(sourceScheduler.jobs.map(\.sourcePath), ["/srv/a"])
        XCTAssertEqual(destinationScheduler.jobs.map(\.destinationPath), ["/srv/a"])

        destinationScheduler.completeLast(status: "completed")

        let didComplete = await eventually { statuses.last == .completed }
        XCTAssertTrue(didComplete)
    }

    func testCrossDeviceConflictDecisionAppliesToAllConflictsInBatch() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/one.txt", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/archive/two.txt", size: 1, linkTarget: nil)
        ]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "conflict-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "conflict-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var requestedPaths: [String] = []
        var statuses: [CrossDeviceTransferStatus] = []

        let coordinator = CrossDeviceTransferCoordinator()
        _ = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/one.txt", size: 1),
                RemoteFileSelection(path: "/incoming/two.txt", size: 1)
            ],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictDecisionProvider: { path in
                requestedPaths.append(path)
                return CrossDeviceConflictDecision(resolution: .skip, applyToAll: true)
            },
            statusHandler: { statuses.append($0) }
        )

        let didSkip = await eventually { statuses.last == .skipped }
        XCTAssertTrue(didSkip)
        XCTAssertEqual(requestedPaths.count, 1)
        XCTAssertTrue(bridge.copiedPaths.isEmpty)
    }

    func testCrossDeviceMoveConflictSkipPreservesEverySourceInBatch() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/existing.txt", size: 1, linkTarget: nil)
        ]
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/existing.txt", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/fresh.txt", size: 1, linkTarget: nil)
        ]
        let sourcePaths: Set<String> = ["/incoming/existing.txt", "/incoming/fresh.txt"]
        bridge.trackedPaths = sourcePaths
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "move-skip-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "move-skip-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []
        let coordinator = CrossDeviceTransferCoordinator()

        _ = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/existing.txt", size: 1),
                RemoteFileSelection(path: "/incoming/fresh.txt", size: 1)
            ],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .skip,
            statusHandler: { statuses.append($0) }
        )

        let didFinish = await eventually { statuses.last == .skipped }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(bridge.trackedPaths, sourcePaths)
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testCrossDeviceMovePreflightFailurePreservesEverySourceInBatch() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = []
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/first.txt", size: 1, linkTarget: nil)
        ]
        let sourcePaths: Set<String> = ["/incoming/first.txt", "/incoming/missing.txt"]
        bridge.trackedPaths = sourcePaths
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "move-preflight-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "move-preflight-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []
        let coordinator = CrossDeviceTransferCoordinator()

        _ = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/first.txt", size: 1),
                RemoteFileSelection(path: "/incoming/missing.txt", size: 1)
            ],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFail = await eventually {
            guard case .failed = statuses.last else { return false }
            return true
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(bridge.trackedPaths, sourcePaths)
        XCTAssertTrue(bridge.copiedPaths.isEmpty)
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testCrossDeviceSameHostMoveTransferFailurePreservesEverySourceInBatch() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = []
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/first.txt", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/second.txt", size: 1, linkTarget: nil)
        ]
        let sourcePaths: Set<String> = ["/incoming/first.txt", "/incoming/second.txt"]
        bridge.trackedPaths = sourcePaths
        bridge.mutationFailurePaths = ["/incoming/second.txt"]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-failure-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-failure-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []
        let coordinator = CrossDeviceTransferCoordinator()

        _ = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/first.txt", size: 1),
                RemoteFileSelection(path: "/incoming/second.txt", size: 1)
            ],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFail = await eventually {
            guard case .failed = statuses.last else { return false }
            return true
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(bridge.trackedPaths, sourcePaths)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testCrossDeviceSameHostMoveDeleteFailureRestoresSourcesAndLeavesNoPendingStage() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = []
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .directory, path: "/incoming/first", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/incoming/second", size: 0, linkTarget: nil)
        ]
        bridge.directoryChildren = [
            "/incoming/first": ["first.txt"],
            "/incoming/second": ["second.txt"]
        ]
        bridge.trackedPaths = ["/incoming/first", "/incoming/second"]
        bridge.deleteFailuresByCallIndex = [2]
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let endpoint = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-move-delete-failure",
            title: "服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let coordinator = CrossDeviceTransferCoordinator()
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/first", size: 0, kind: .directory),
                RemoteFileSelection(path: "/incoming/second", size: 0, kind: .directory)
            ],
            from: endpoint,
            to: endpoint,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFail = await eventually {
            guard case .failed = statuses.last else { return false }
            return bridge.deletedPaths.count >= 2
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(bridge.directoryChildren["/incoming/first"], ["first.txt"])
        XCTAssertEqual(bridge.directoryChildren["/incoming/second"], ["second.txt"])
        XCTAssertFalse(bridge.directoryChildren.keys.contains { $0.contains(".stacio-move-") })
        XCTAssertFalse(bridge.trackedPaths.contains { $0.contains(".stacio-move-") })
    }

    func testCrossDeviceSameHostCopyStopsBeforeNextItemWhenCancelledInsideLoop() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = []
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/first.txt", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/second.txt", size: 1, linkTarget: nil)
        ]
        let releaseFirstCopy = DispatchSemaphore(value: 0)
        bridge.onCopyLiveRemotePath = { _, callIndex in
            guard callIndex == 1 else { return }
            releaseFirstCopy.wait()
        }
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let endpoint = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-copy-cancel",
            title: "服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let coordinator = CrossDeviceTransferCoordinator()
        var statuses: [CrossDeviceTransferStatus] = []
        let operationID = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/first.txt", size: 1),
                RemoteFileSelection(path: "/incoming/second.txt", size: 1)
            ],
            from: endpoint,
            to: endpoint,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )
        let didStartFirstCopy = await eventually { bridge.copiedPaths.count == 1 }
        XCTAssertTrue(didStartFirstCopy)

        XCTAssertTrue(coordinator.cancel(operationID: operationID))
        releaseFirstCopy.signal()

        let didCancel = await eventually { statuses.last == .cancelled }
        XCTAssertTrue(didCancel)
        XCTAssertEqual(bridge.copiedPaths.count, 1)
    }

    func testCrossDeviceMoveCommitRollsBackStagedItemWhenCancelledInsideLoop() async {
        let bridge = CrossDeviceRecordingRemoteBridge()
        bridge.entriesByPath["/archive"] = []
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .directory, path: "/incoming/first", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/incoming/second", size: 0, linkTarget: nil)
        ]
        bridge.directoryChildren = [
            "/incoming/first": ["first.txt"],
            "/incoming/second": ["second.txt"]
        ]
        bridge.trackedPaths = ["/incoming/first", "/incoming/second"]
        let releaseFirstMoveStage = DispatchSemaphore(value: 0)
        bridge.onRenameLiveRemotePath = { pair, callIndex in
            guard callIndex == 1, pair.to.contains(".stacio-move-") else { return }
            releaseFirstMoveStage.wait()
        }
        let scheduler = CrossDeviceRecordingTransferScheduler()
        let endpoint = CrossDeviceRemoteEndpoint(
            runtimeID: "same-host-move-cancel",
            title: "服务器",
            context: Self.crossDeviceContext(host: "files.example.com"),
            bridge: bridge,
            transferScheduler: scheduler
        )
        let coordinator = CrossDeviceTransferCoordinator()
        var statuses: [CrossDeviceTransferStatus] = []
        let operationID = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/first", size: 0, kind: .directory),
                RemoteFileSelection(path: "/incoming/second", size: 0, kind: .directory)
            ],
            from: endpoint,
            to: endpoint,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )
        let didStageFirstMove = await eventually {
            bridge.renamedPaths.contains { $0.to.contains(".stacio-move-") }
        }
        XCTAssertTrue(didStageFirstMove)

        XCTAssertTrue(coordinator.cancel(operationID: operationID))
        releaseFirstMoveStage.signal()

        let didCancel = await eventually { statuses.last == .cancelled }
        XCTAssertTrue(didCancel)
        XCTAssertEqual(bridge.trackedPaths, ["/incoming/first", "/incoming/second"])
        XCTAssertFalse(bridge.trackedPaths.contains { $0.contains(".stacio-move-") })
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testCrossDeviceRelayMoveUploadFailurePreservesEverySourceAndCleansRelay() async {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRelayMoveFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        sourceBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/first.txt", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/second.txt", size: 1, linkTarget: nil)
        ]
        let sourcePaths: Set<String> = ["/incoming/first.txt", "/incoming/second.txt"]
        sourceBridge.trackedPaths = sourcePaths
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = []
        let sourceScheduler = CrossDeviceRecordingTransferScheduler()
        sourceScheduler.materializesDownloads = true
        let destinationScheduler = CrossDeviceRecordingTransferScheduler()
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: { relayRoot })
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-move-failure-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: sourceScheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-move-failure-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: destinationScheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [
                RemoteFileSelection(path: "/incoming/first.txt", size: 1),
                RemoteFileSelection(path: "/incoming/second.txt", size: 1)
            ],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .move,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didScheduleFirstDownload = await eventually { sourceScheduler.jobs.count == 1 }
        XCTAssertTrue(didScheduleFirstDownload)
        sourceScheduler.completeLast(status: "completed")
        let didScheduleFirstUpload = await eventually { destinationScheduler.jobs.count == 1 }
        XCTAssertTrue(didScheduleFirstUpload)
        destinationScheduler.completeLast(status: "completed")
        let didScheduleSecondDownload = await eventually { sourceScheduler.jobs.count == 2 }
        XCTAssertTrue(didScheduleSecondDownload)
        sourceScheduler.completeLast(status: "completed")
        let didScheduleSecondUpload = await eventually { destinationScheduler.jobs.count == 2 }
        XCTAssertTrue(didScheduleSecondUpload)
        destinationScheduler.completeLast(status: "failed")

        let didFailAndClean = await eventually {
            guard case .failed = statuses.last else { return false }
            return FileManager.default.fileExists(atPath: relayRoot.path) == false
        }
        XCTAssertTrue(didFailAndClean)
        XCTAssertEqual(sourceBridge.trackedPaths, sourcePaths)
        XCTAssertTrue(sourceBridge.renamedPaths.isEmpty)
        XCTAssertTrue(sourceBridge.deletedPaths.isEmpty)
    }

    func testCrossDeviceTransferRelaysAcrossHostsWith0700DirectoryAndCleansAfterUpload() async throws {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRelayTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        let sourceScheduler = CrossDeviceRecordingTransferScheduler()
        sourceScheduler.completesImmediately = true
        sourceScheduler.materializesDownloads = true
        let destinationScheduler = CrossDeviceRecordingTransferScheduler()
        let coordinator = CrossDeviceTransferCoordinator(
            relayDirectoryProvider: { relayRoot }
        )
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: sourceScheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: destinationScheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didScheduleUpload = await eventually { destinationScheduler.jobs.count == 1 }
        XCTAssertTrue(didScheduleUpload)
        XCTAssertEqual(sourceScheduler.jobs.map(\.direction), [.download])
        XCTAssertEqual(destinationScheduler.jobs.map(\.direction), [.upload])
        let temporaryUploadPath = try XCTUnwrap(destinationScheduler.jobs.first?.destinationPath)
        XCTAssertNotEqual(temporaryUploadPath, "/archive/report.txt")
        XCTAssertEqual((temporaryUploadPath as NSString).deletingLastPathComponent, "/archive")
        XCTAssertTrue((temporaryUploadPath as NSString).lastPathComponent.contains(".stacio-transfer-"))
        let attributes = try FileManager.default.attributesOfItem(atPath: relayRoot.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(statuses.contains(.downloading))
        XCTAssertTrue(statuses.contains(.uploading))

        destinationScheduler.completeLast(status: "completed")

        let didCommitReplacement = await eventually {
            let renames = destinationBridge.renamedPaths
            guard renames.count == 2 else { return false }
            return renames[0].from == "/archive/report.txt"
                && renames[0].to.contains(".stacio-backup-")
                && renames[1] == .init(
                    from: temporaryUploadPath,
                    to: "/archive/report.txt"
                )
        }
        XCTAssertTrue(didCommitReplacement)
        let backupPath = try XCTUnwrap(destinationBridge.renamedPaths.first?.to)
        XCTAssertTrue(destinationBridge.deletedPaths.contains(backupPath))
        XCTAssertFalse(destinationBridge.deletedPaths.contains("/archive/report.txt"))
        let didCleanRelay = await eventually {
            FileManager.default.fileExists(atPath: relayRoot.path) == false
        }
        XCTAssertTrue(didCleanRelay)
        XCTAssertEqual(statuses.last, .completed)
    }

    func testCrossDeviceDefaultRelayUsesDedicatedParentAndUUIDChild() async throws {
        let sourceScheduler = CrossDeviceRecordingTransferScheduler()
        let destinationScheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "default-relay-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: CrossDeviceRecordingRemoteBridge(),
            transferScheduler: sourceScheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "default-relay-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: CrossDeviceRecordingRemoteBridge(),
            transferScheduler: destinationScheduler
        )
        let coordinator = CrossDeviceTransferCoordinator()
        let operationID = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { _ in }
        )
        let didSchedule = await eventually { sourceScheduler.jobs.count == 1 }
        XCTAssertTrue(didSchedule)
        let job = try XCTUnwrap(sourceScheduler.jobs.first)
        let relayDirectory = URL(fileURLWithPath: job.destinationPath).deletingLastPathComponent()

        XCTAssertEqual(relayDirectory.deletingLastPathComponent().lastPathComponent, "StacioCrossDeviceTransfers")
        XCTAssertNotNil(UUID(uuidString: relayDirectory.lastPathComponent))
        XCTAssertEqual(
            relayDirectory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
            FileManager.default.temporaryDirectory.standardizedFileURL
        )

        XCTAssertTrue(coordinator.cancel(operationID: operationID))
    }

    func testCrossDeviceRelayRetryRecreatesStageAndCompletesOriginalOperation() async throws {
        let relayParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRelayRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayParent) }
        var relayAttempt = 0
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        destinationBridge.directoryChildren = ["/archive/report.txt": ["old"]]
        let transferBridge = CrossDeviceRelayRetryTransferBridge(destinationBridge: destinationBridge)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            bridge: transferBridge,
            queueViewController: queueView,
            maxConcurrentTransfers: 1
        )
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: {
            relayAttempt += 1
            return relayParent.appendingPathComponent("attempt-\(relayAttempt)", isDirectory: true)
        })
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-retry-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-retry-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFailAndCleanFirstRelay = await eventually {
            guard case .failed = statuses.last else { return false }
            return FileManager.default.fileExists(
                atPath: relayParent.appendingPathComponent("attempt-1").path
            ) == false
        }
        XCTAssertTrue(didFailAndCleanFirstRelay)
        let failedUploadJobID = try XCTUnwrap(
            transferBridge.jobs.first(where: { $0.direction == .upload })?.id
        )

        XCTAssertTrue(queue.retryFailedTransfer(jobID: failedUploadJobID))

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(transferBridge.jobs.filter { $0.direction == .download }.count, 2)
        XCTAssertEqual(transferBridge.jobs.filter { $0.direction == .upload }.count, 2)
        let downloadDestinations = transferBridge.jobs
            .filter { $0.direction == .download }
            .map(\.destinationPath)
        XCTAssertEqual(Set(downloadDestinations.map { ($0 as NSString).deletingLastPathComponent }).count, 2)
        XCTAssertEqual(destinationBridge.directoryChildren["/archive/report.txt"], ["new"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relayParent.appendingPathComponent("attempt-1").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relayParent.appendingPathComponent("attempt-2").path
        ))
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: relayParent.path))?.isEmpty ?? true)
    }

    func testCrossDeviceDirectTransferExpandsDirectoriesUsesPerEndpointProtocolsAndSkipsLocalRelay() async throws {
        let relayParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioDirectRelay-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayParent) }

        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        sourceBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .directory, path: "/incoming/nested", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/root.bin", size: 12, linkTarget: nil)
        ]
        sourceBridge.entriesByPath["/incoming/nested"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/nested/child.bin", size: 24, linkTarget: nil)
        ]
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = []
        let directBridge = RecordingRemoteToRemoteTransferBridge(delay: 0.03)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let coordinator = CrossDeviceTransferCoordinator(
            relayDirectoryProvider: { relayParent },
            remoteTransferBridge: directBridge
        )
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "direct-source",
            title: "源 SFTP",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "direct-destination",
            title: "目标 SCP",
            protocolName: "scp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming", size: 36, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relayParent.path))
        XCTAssertEqual(directBridge.requests.count, 2)
        XCTAssertEqual(
            Set(directBridge.requests.map { "\($0.sourceProtocol)-\($0.destinationProtocol)" }),
            ["sftp-scp"]
        )
        XCTAssertEqual(
            Set(directBridge.requests.map(\.job.destinationPath)),
            Set(["/archive/incoming/root.bin", "/archive/incoming/nested/child.bin"])
        )
        XCTAssertLessThanOrEqual(directBridge.maximumConcurrentRequests, 2)
        XCTAssertGreaterThan(directBridge.maximumConcurrentRequests, 1)
    }

    func testCrossDeviceDirectTransferUsesStableJobIDWhenUserRetriesSameRoute() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = []
        let directBridge = RecordingRemoteToRemoteTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "stable-retry-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "stable-retry-destination",
            title: "目标服务器",
            protocolName: "scp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )

        for attempt in 1...2 {
            var statuses: [CrossDeviceTransferStatus] = []
            _ = coordinator.transfer(
                [RemoteFileSelection(path: "/incoming/archive.tar", size: 4 * 1_024 * 1_024)],
                from: source,
                to: destination,
                destinationDirectory: "/archive",
                operation: .copy,
                conflictResolution: .replace,
                statusHandler: { statuses.append($0) }
            )
            let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
            XCTAssertTrue(didComplete, "attempt \(attempt)")
        }

        XCTAssertEqual(directBridge.requests.count, 2)
        let jobIDs = directBridge.requests.map(\.job.id)
        XCTAssertEqual(Set(jobIDs).count, 1)
        let jobID = try XCTUnwrap(jobIDs.first)
        XCTAssertFalse(jobID.contains("source.example.com"))
        XCTAssertFalse(jobID.contains("destination.example.com"))
        XCTAssertFalse(jobID.contains("archive.tar"))
    }

    func testCrossDeviceDirectDirectoryRetryPreservesStableRecoveryRoute() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        sourceBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/archive.tar", size: 4 * 1_024 * 1_024, linkTarget: nil)
        ]
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .directory, path: "/archive/incoming", size: 0, linkTarget: nil)
        ]
        let directBridge = RecordingRemoteToRemoteTransferBridge(failuresRemaining: 1)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "stable-directory-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "stable-directory-destination",
            title: "目标服务器",
            protocolName: "scp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )

        var firstStatuses: [CrossDeviceTransferStatus] = []
        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming", size: 4 * 1_024 * 1_024, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { firstStatuses.append($0) }
        )
        let didFail = await eventually(timeout: 3) {
            if case .failed = firstStatuses.last { return true }
            return false
        }
        XCTAssertTrue(didFail)
        let firstRequest = try XCTUnwrap(directBridge.requests.first)
        let firstStagingRoot = (firstRequest.job.destinationPath as NSString).deletingLastPathComponent
        XCTAssertFalse(destinationBridge.deletedPaths.contains(firstStagingRoot))

        var secondStatuses: [CrossDeviceTransferStatus] = []
        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming", size: 4 * 1_024 * 1_024, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { secondStatuses.append($0) }
        )
        let didComplete = await eventually(timeout: 3) { secondStatuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(directBridge.requests.count, 2)
        XCTAssertEqual(directBridge.requests.map(\.job.id), [firstRequest.job.id, firstRequest.job.id])
        XCTAssertEqual(directBridge.requests.map(\.job.destinationPath), [firstRequest.job.destinationPath, firstRequest.job.destinationPath])
    }

    func testCrossDeviceDirectTransferRejectsConcurrentDuplicateRecoveryRoute() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = []
        let directBridge = RecordingRemoteToRemoteTransferBridge(blockUntilCancelled: true)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let firstCoordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let secondCoordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "duplicate-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "duplicate-destination",
            title: "目标服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )

        var firstStatuses: [CrossDeviceTransferStatus] = []
        let firstOperationID = firstCoordinator.transfer(
            [RemoteFileSelection(path: "/incoming/archive.tar", size: 4 * 1_024 * 1_024)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { firstStatuses.append($0) }
        )
        let firstDidStart = await eventually { directBridge.requests.count == 1 }
        XCTAssertTrue(firstDidStart)

        var secondStatuses: [CrossDeviceTransferStatus] = []
        _ = secondCoordinator.transfer(
            [RemoteFileSelection(path: "/incoming/archive.tar", size: 4 * 1_024 * 1_024)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { secondStatuses.append($0) }
        )
        let secondWasRejected = await eventually(timeout: 3) {
            if case .failed = secondStatuses.last { return true }
            return false
        }
        XCTAssertTrue(secondWasRejected)
        XCTAssertEqual(directBridge.requests.count, 1)
        XCTAssertTrue(firstCoordinator.cancel(operationID: firstOperationID))
        let firstDidCancel = await eventually(timeout: 3) { firstStatuses.last == .cancelled }
        XCTAssertTrue(firstDidCancel)
    }

    func testCrossDeviceDirectTransferCancellationCancelsEveryActiveRemoteJob() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        sourceBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/one.bin", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/two.bin", size: 1, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/incoming/three.bin", size: 1, linkTarget: nil)
        ]
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = []
        let directBridge = RecordingRemoteToRemoteTransferBridge(blockUntilCancelled: true)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        var latestQueueSnapshot = TransferQueueSnapshot(rows: [])
        let queueObservation = queue.observeQueue(
            runtimeIDs: { Set(["cancel-direct-destination"]) },
            handler: { latestQueueSnapshot = $0 }
        )
        defer { queue.removeQueueObservation(queueObservation) }
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "cancel-direct-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "cancel-direct-destination",
            title: "目标服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        let operationID = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming", size: 3, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didStartTwoWorkers = await eventually { directBridge.requests.count == 2 }
        XCTAssertTrue(didStartTwoWorkers)
        XCTAssertTrue(coordinator.cancel(operationID: operationID))
        let didCancel = await eventually(timeout: 3) { statuses.last == .cancelled }
        XCTAssertTrue(didCancel)
        XCTAssertEqual(directBridge.requests.count, 2)
        XCTAssertEqual(directBridge.cancelledJobIDs.count, 3)
        let didFinishEveryQueueRow = await eventually(timeout: 3) {
            latestQueueSnapshot.rows.count == 3
                && latestQueueSnapshot.rows.allSatisfy { $0.rawStatus == "canceled" }
        }
        XCTAssertTrue(didFinishEveryQueueRow)
    }

    func testCrossDeviceDirectTransferFastPauseResumeConsumesExpectedTransportCancellation() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = []
        let directBridge = PauseResumeRemoteToRemoteTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        var latestQueueSnapshot = TransferQueueSnapshot(rows: [])
        let queueObservation = queue.observeQueue(
            runtimeIDs: { Set(["pause-resume-destination"]) },
            handler: { latestQueueSnapshot = $0 }
        )
        defer { queue.removeQueueObservation(queueObservation) }
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "pause-resume-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "pause-resume-destination",
            title: "目标服务器",
            protocolName: "scp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/archive.tar", size: 4 * 1_024 * 1_024)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didStart = await eventually(timeout: 3) { directBridge.runCount == 1 }
        XCTAssertTrue(didStart)
        let jobID = try XCTUnwrap(directBridge.jobIDs.first)
        XCTAssertTrue(queue.pauseTransfer(jobID: jobID))
        XCTAssertTrue(queue.resumeTransfer(jobID: jobID))
        directBridge.allowFirstCancellationToReturn()

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(directBridge.runCount, 2)
        XCTAssertEqual(latestQueueSnapshot.rows.first?.rawStatus, "completed")
    }

    func testCrossDeviceDirectTransferCancellationDuringDirectoryExpansionFinishesAndCleansStaging() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        sourceBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .directory, path: "/incoming/nested", size: 0, linkTarget: nil)
        ]
        sourceBridge.entriesByPath["/incoming/nested"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/nested/large.bin", size: 1024, linkTarget: nil)
        ]
        let listingStarted = DispatchSemaphore(value: 0)
        let allowListingToReturn = DispatchSemaphore(value: 0)
        sourceBridge.onListLiveRemoteDirectory = { path, _ in
            guard path == "/incoming" else { return }
            listingStarted.signal()
            _ = allowListingToReturn.wait(timeout: .now() + 2)
        }
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .directory, path: "/archive/incoming", size: 0, linkTarget: nil)
        ]
        let directBridge = RecordingRemoteToRemoteTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "expansion-cancel-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "expansion-cancel-destination",
            title: "目标服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        let operationID = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming", size: 1024, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didStartListing = await eventually(timeout: 3) {
            listingStarted.wait(timeout: .now()) == .success
        }
        XCTAssertTrue(didStartListing)
        XCTAssertTrue(coordinator.cancel(operationID: operationID))
        allowListingToReturn.signal()

        let didCancel = await eventually(timeout: 3) { statuses.last == .cancelled }
        XCTAssertTrue(didCancel)
        XCTAssertTrue(directBridge.requests.isEmpty)
        XCTAssertEqual(destinationBridge.deletedPaths.count, 1)
        XCTAssertTrue(destinationBridge.deletedPaths.first?.contains(".incoming.stacio-transfer-") == true)
    }

    func testCrossDeviceDirectTransferReplacesDirectoryThroughStagingWithoutMerging() async throws {
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        sourceBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/new.txt", size: 3, linkTarget: nil)
        ]
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .directory, path: "/archive/incoming", size: 0, linkTarget: nil)
        ]
        let directBridge = RecordingRemoteToRemoteTransferBridge()
        let coordinator = CrossDeviceTransferCoordinator(remoteTransferBridge: directBridge)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "replace-source",
            title: "源服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "replace-destination",
            title: "目标服务器",
            protocolName: "sftp",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming", size: 3, kind: .directory)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        let request = try XCTUnwrap(directBridge.requests.first)
        let stagingDirectory = (request.job.destinationPath as NSString).deletingLastPathComponent
        XCTAssertTrue(stagingDirectory.contains(".incoming.stacio-transfer-"))
        XCTAssertEqual(destinationBridge.renamedPaths.count, 2)
        guard destinationBridge.renamedPaths.count == 2 else { return }
        XCTAssertEqual(
            destinationBridge.renamedPaths.map { [$0.from, $0.to] },
            [
                ["/archive/incoming", destinationBridge.renamedPaths[0].to],
                [stagingDirectory, "/archive/incoming"]
            ]
        )
        XCTAssertTrue(destinationBridge.deletedPaths.contains { $0.contains(".incoming.stacio-backup-") })
    }

    func testCrossDeviceRelayRetryCleansRemoteTemporaryPathAfterInitialCleanupFailure() async throws {
        let relayParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteCleanupRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayParent) }
        var relayAttempt = 0
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        destinationBridge.directoryChildren = ["/archive/report.txt": ["old"]]
        destinationBridge.deleteFailuresRemaining = 1
        let transferBridge = CrossDeviceRelayRetryTransferBridge(destinationBridge: destinationBridge)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            bridge: transferBridge,
            queueViewController: queueView,
            maxConcurrentTransfers: 1
        )
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: {
            relayAttempt += 1
            return relayParent.appendingPathComponent("attempt-\(relayAttempt)", isDirectory: true)
        })
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "remote-cleanup-retry-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "remote-cleanup-retry-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFailCleanup = await eventually {
            guard case .failed(let message) = statuses.last else { return false }
            return message.contains("远端临时文件清理失败")
                && destinationBridge.deletedPaths.count == 1
        }
        XCTAssertTrue(didFailCleanup)
        let failedUploadJobID = try XCTUnwrap(
            transferBridge.jobs.first(where: { $0.direction == .upload })?.id
        )
        let temporaryPath = try XCTUnwrap(
            transferBridge.jobs.first(where: { $0.direction == .upload })?.destinationPath
        )

        XCTAssertTrue(queue.retryFailedTransfer(jobID: failedUploadJobID))

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(destinationBridge.deletedPaths.filter { $0 == temporaryPath }.count, 2)
        XCTAssertEqual(transferBridge.relayDirectoryPermissionsByDownload, [0o700, 0o700])
        XCTAssertEqual(destinationBridge.directoryChildren["/archive/report.txt"], ["new"])
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: relayParent.path))?.isEmpty ?? true)
    }

    func testCrossDeviceRelayRetryRemovesLocalRelayAfterInitialCleanupFailure() async throws {
        let relayParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalCleanupRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayParent) }
        let firstRelay = relayParent.appendingPathComponent("attempt-1", isDirectory: true)
        let fileManager = CrossDeviceFailOnceRelayRemovalFileManager(failingRemovalURL: firstRelay)
        var relayAttempt = 0
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        destinationBridge.directoryChildren = ["/archive/report.txt": ["old"]]
        let transferBridge = CrossDeviceRelayRetryTransferBridge(destinationBridge: destinationBridge)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            bridge: transferBridge,
            queueViewController: queueView,
            maxConcurrentTransfers: 1
        )
        let coordinator = CrossDeviceTransferCoordinator(
            fileManager: fileManager,
            relayDirectoryProvider: {
                relayAttempt += 1
                return relayParent.appendingPathComponent("attempt-\(relayAttempt)", isDirectory: true)
            }
        )
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "local-cleanup-retry-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: queue
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "local-cleanup-retry-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: queue
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFailCleanup = await eventually {
            guard case .failed(let message) = statuses.last else { return false }
            return message.contains("本机临时中继清理失败")
                && FileManager.default.fileExists(atPath: firstRelay.path)
        }
        XCTAssertTrue(didFailCleanup)
        let failedUploadJobID = try XCTUnwrap(
            transferBridge.jobs.first(where: { $0.direction == .upload })?.id
        )

        XCTAssertTrue(queue.retryFailedTransfer(jobID: failedUploadJobID))

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(transferBridge.relayDirectoryPermissionsByDownload, [0o700, 0o700])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRelay.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relayParent.appendingPathComponent("attempt-2").path
        ))
        XCTAssertEqual(destinationBridge.directoryChildren["/archive/report.txt"], ["new"])
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: relayParent.path))?.isEmpty ?? true)
    }

    func testSFTPAdapterCrossDeviceRelayRetryRecreatesProtectedRelay() async throws {
        let relayParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioSFTPRelayRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayParent) }
        var relayAttempt = 0
        let sourceBridge = CrossDeviceRecordingRemoteBridge()
        let destinationBridge = CrossDeviceRecordingRemoteBridge()
        destinationBridge.entriesByPath["/archive"] = [
            RemoteFileEntry(kind: .file, path: "/archive/report.txt", size: 10, linkTarget: nil)
        ]
        destinationBridge.directoryChildren = ["/archive/report.txt": ["old"]]
        let transferBridge = CrossDeviceRelayRetryTransferBridge(destinationBridge: destinationBridge)
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            sftpBridge: transferBridge,
            queueViewController: queueView,
            maxConcurrentTransfers: 1
        )
        let scheduler = SFTPTransferSchedulerAdapter(scheduler: queue)
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: {
            relayAttempt += 1
            return relayParent.appendingPathComponent("attempt-\(relayAttempt)", isDirectory: true)
        })
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "sftp-relay-retry-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: sourceBridge,
            transferScheduler: scheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "sftp-relay-retry-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: destinationBridge,
            transferScheduler: scheduler
        )
        var statuses: [CrossDeviceTransferStatus] = []

        _ = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .replace,
            statusHandler: { statuses.append($0) }
        )

        let didFailAndCleanFirstRelay = await eventually {
            guard case .failed = statuses.last else { return false }
            return FileManager.default.fileExists(
                atPath: relayParent.appendingPathComponent("attempt-1").path
            ) == false
        }
        XCTAssertTrue(didFailAndCleanFirstRelay)
        let failedUploadJobID = try XCTUnwrap(
            transferBridge.jobs.first(where: { $0.direction == .upload })?.id
        )

        XCTAssertTrue(queue.retryFailedTransfer(jobID: failedUploadJobID))

        let didComplete = await eventually(timeout: 3) { statuses.last == .completed }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(transferBridge.jobs.filter { $0.direction == .download }.count, 2)
        XCTAssertEqual(transferBridge.jobs.filter { $0.direction == .upload }.count, 2)
        XCTAssertEqual(destinationBridge.directoryChildren["/archive/report.txt"], ["new"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relayParent.appendingPathComponent("attempt-1").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: relayParent.appendingPathComponent("attempt-2").path
        ))
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: relayParent.path))?.isEmpty ?? true)
    }

    func testCrossDeviceTransferCancellationCancelsQueueJobAndRemovesRelayDirectory() async {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRelayCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let sourceScheduler = CrossDeviceRecordingTransferScheduler()
        sourceScheduler.completesCancellationImmediately = false
        let destinationScheduler = CrossDeviceRecordingTransferScheduler()
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-cancel-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: CrossDeviceRecordingRemoteBridge(),
            transferScheduler: sourceScheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-cancel-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: CrossDeviceRecordingRemoteBridge(),
            transferScheduler: destinationScheduler
        )
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: { relayRoot })
        var statuses: [CrossDeviceTransferStatus] = []

        let operationID = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .keepBoth,
            statusHandler: { statuses.append($0) }
        )
        let didScheduleDownload = await eventually { sourceScheduler.jobs.count == 1 }
        XCTAssertTrue(didScheduleDownload)

        XCTAssertTrue(coordinator.cancel(operationID: operationID))

        XCTAssertEqual(sourceScheduler.cancelledJobIDs, sourceScheduler.jobs.map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: relayRoot.path))
        XCTAssertNotEqual(statuses.last, .cancelled)
        sourceScheduler.completeLast(status: "canceled")
        let didCleanRelay = await eventually {
            FileManager.default.fileExists(atPath: relayRoot.path) == false
        }
        XCTAssertTrue(didCleanRelay)
        XCTAssertEqual(statuses.last, .cancelled)
    }

    func testCrossDeviceCancellationRejectionLeavesRelayAndReportsRetryableFailure() async {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRelayCancelRejected-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let sourceScheduler = CrossDeviceRecordingTransferScheduler()
        sourceScheduler.acceptsCancellation = false
        let source = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-reject-source",
            title: "源服务器",
            context: Self.crossDeviceContext(host: "source.example.com"),
            bridge: CrossDeviceRecordingRemoteBridge(),
            transferScheduler: sourceScheduler
        )
        let destination = CrossDeviceRemoteEndpoint(
            runtimeID: "relay-reject-destination",
            title: "目标服务器",
            context: Self.crossDeviceContext(host: "destination.example.com"),
            bridge: CrossDeviceRecordingRemoteBridge(),
            transferScheduler: CrossDeviceRecordingTransferScheduler()
        )
        let coordinator = CrossDeviceTransferCoordinator(relayDirectoryProvider: { relayRoot })
        var statuses: [CrossDeviceTransferStatus] = []
        let operationID = coordinator.transfer(
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            from: source,
            to: destination,
            destinationDirectory: "/archive",
            operation: .copy,
            conflictResolution: .keepBoth,
            statusHandler: { statuses.append($0) }
        )
        let didSchedule = await eventually { sourceScheduler.jobs.count == 1 }
        XCTAssertTrue(didSchedule)

        XCTAssertFalse(coordinator.cancel(operationID: operationID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: relayRoot.path))
        guard case .cancellationFailed(let message) = statuses.last else {
            return XCTFail("expected an explicit retryable cancellation failure")
        }
        XCTAssertTrue(message.contains("重试"))
    }

    private func coordinatorForSamePathTest() -> CrossDeviceTransferCoordinator {
        CrossDeviceTransferCoordinator()
    }

    private static func crossDeviceContext(host: String) -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: host,
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:\(host)"
        )
    }
}

private final class CrossDeviceRecordingRemoteBridge: RemoteFilesBridging {
    struct PathPair: Equatable {
        let from: String
        let to: String
    }

    private let lock = NSLock()
    var entriesByPath: [String: [RemoteFileEntry]] = [:]
    private var copies: [PathPair] = []
    private var renames: [PathPair] = []
    private var deletes: [String] = []
    private var permissionChanges: [(String, String)] = []
    private var trackedPathsStorage = Set<String>()
    private var mutationFailurePathsStorage = Set<String>()
    private var directoryChildrenStorage: [String: Set<String>] = [:]
    private var renameFailuresByDestinationStorage: [String: Int] = [:]
    private var deleteFailuresRemainingStorage = 0
    private var deleteFailuresByCallIndexStorage = Set<Int>()
    private var onCopyLiveRemotePathStorage: ((PathPair, Int) -> Void)?
    private var onRenameLiveRemotePathStorage: ((PathPair, Int) -> Void)?
    private var onListLiveRemoteDirectoryStorage: ((String, Int) -> Void)?
    private var listLiveRemoteDirectoryCallCount = 0

    var copiedPaths: [PathPair] { locked { copies } }
    var renamedPaths: [PathPair] { locked { renames } }
    var deletedPaths: [String] { locked { deletes } }
    var trackedPaths: Set<String> {
        get { locked { trackedPathsStorage } }
        set { locked { trackedPathsStorage = newValue } }
    }
    var mutationFailurePaths: Set<String> {
        get { locked { mutationFailurePathsStorage } }
        set { locked { mutationFailurePathsStorage = newValue } }
    }
    var directoryChildren: [String: Set<String>] {
        get { locked { directoryChildrenStorage } }
        set { locked { directoryChildrenStorage = newValue } }
    }
    var renameFailuresByDestination: [String: Int] {
        get { locked { renameFailuresByDestinationStorage } }
        set { locked { renameFailuresByDestinationStorage = newValue } }
    }
    var deleteFailuresRemaining: Int {
        get { locked { deleteFailuresRemainingStorage } }
        set { locked { deleteFailuresRemainingStorage = newValue } }
    }
    var deleteFailuresByCallIndex: Set<Int> {
        get { locked { deleteFailuresByCallIndexStorage } }
        set { locked { deleteFailuresByCallIndexStorage = newValue } }
    }
    var onCopyLiveRemotePath: ((PathPair, Int) -> Void)? {
        get { locked { onCopyLiveRemotePathStorage } }
        set { locked { onCopyLiveRemotePathStorage = newValue } }
    }
    var onRenameLiveRemotePath: ((PathPair, Int) -> Void)? {
        get { locked { onRenameLiveRemotePathStorage } }
        set { locked { onRenameLiveRemotePathStorage = newValue } }
    }
    var onListLiveRemoteDirectory: ((String, Int) -> Void)? {
        get { locked { onListLiveRemoteDirectoryStorage } }
        set { locked { onListLiveRemoteDirectoryStorage = newValue } }
    }

    func materializeRemotePath(_ path: String, children: Set<String>) {
        locked { directoryChildrenStorage[path] = children }
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] { [] }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        let result = locked { () -> ([RemoteFileEntry], ((String, Int) -> Void)?, Int) in
            listLiveRemoteDirectoryCallCount += 1
            return (
                entriesByPath[remotePath] ?? [],
                onListLiveRemoteDirectoryStorage,
                listLiveRemoteDirectoryCallCount
            )
        }
        result.1?(remotePath, result.2)
        return result.0
    }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        let pair = PathPair(from: fromPath, to: toPath)
        let callback = try locked { () -> (((PathPair, Int) -> Void)?, Int) in
            if mutationFailurePathsStorage.contains(fromPath) {
                throw CrossDeviceRecordingBridgeError.forcedMutationFailure
            }
            if let remainingFailures = renameFailuresByDestinationStorage[toPath],
               remainingFailures > 0
            {
                renameFailuresByDestinationStorage[toPath] = remainingFailures - 1
                throw CrossDeviceRecordingBridgeError.forcedMutationFailure
            }
            renames.append(pair)
            if let children = directoryChildrenStorage.removeValue(forKey: fromPath) {
                directoryChildrenStorage[toPath] = children
            }
            if trackedPathsStorage.remove(fromPath) != nil {
                trackedPathsStorage.insert(toPath)
            }
            return (onRenameLiveRemotePathStorage, renames.count)
        }
        callback.0?(pair, callback.1)
    }

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        try locked {
            let callIndex = deletes.count + 1
            deletes.append(remotePath)
            if deleteFailuresByCallIndexStorage.contains(callIndex) {
                throw CrossDeviceRecordingBridgeError.forcedMutationFailure
            }
            if deleteFailuresRemainingStorage > 0 {
                deleteFailuresRemainingStorage -= 1
                throw CrossDeviceRecordingBridgeError.forcedMutationFailure
            }
            trackedPathsStorage.remove(remotePath)
            directoryChildrenStorage[remotePath] = nil
        }
    }

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {
        locked { permissionChanges.append((remotePath, mode)) }
    }

    func copyLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        let pair = PathPair(from: fromPath, to: toPath)
        let callback = try locked { () -> (((PathPair, Int) -> Void)?, Int) in
            if mutationFailurePathsStorage.contains(fromPath) {
                throw CrossDeviceRecordingBridgeError.forcedMutationFailure
            }
            copies.append(pair)
            let sourceChildren = directoryChildrenStorage[fromPath] ?? []
            if directoryChildrenStorage[toPath] != nil {
                directoryChildrenStorage[toPath, default: []].formUnion(sourceChildren)
            } else {
                directoryChildrenStorage[toPath] = sourceChildren
            }
            return (onCopyLiveRemotePathStorage, copies.count)
        }
        callback.0?(pair, callback.1)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class CrossDeviceRelayRetryTransferBridge: SCPTransferBridging, SFTPTransferBridging {
    private let lock = NSLock()
    private let destinationBridge: CrossDeviceRecordingRemoteBridge
    private var jobsStorage: [ScpTransferJob] = []
    private var uploadAttempts = 0
    private var relayDirectoryPermissionsByDownloadStorage: [Int] = []

    init(destinationBridge: CrossDeviceRecordingRemoteBridge) {
        self.destinationBridge = destinationBridge
    }

    var jobs: [ScpTransferJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobsStorage
    }

    var relayDirectoryPermissionsByDownload: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return relayDirectoryPermissionsByDownloadStorage
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try runTransfer(job: job)
    }

    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try runTransfer(job: job)
    }

    private func runTransfer(job: ScpTransferJob) throws -> [ScpTransferProgress] {
        lock.lock()
        jobsStorage.append(job)
        if job.direction == .upload { uploadAttempts += 1 }
        let currentUploadAttempt = uploadAttempts
        lock.unlock()

        if job.direction == .download {
            let destination = URL(fileURLWithPath: job.destinationPath)
            let relayDirectory = destination.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: relayDirectory.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            lock.lock()
            relayDirectoryPermissionsByDownloadStorage.append(permissions)
            lock.unlock()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x52, count: Int(clamping: job.bytesTotal)).write(to: destination)
            return [ScpTransferProgress(
                jobId: job.id,
                bytesDone: job.bytesTotal,
                bytesTotal: job.bytesTotal,
                status: "completed"
            )]
        }

        guard FileManager.default.fileExists(atPath: job.sourcePath) else {
            return [ScpTransferProgress(
                jobId: job.id,
                bytesDone: 0,
                bytesTotal: job.bytesTotal,
                status: "failed"
            )]
        }
        guard currentUploadAttempt > 1 else {
            return [ScpTransferProgress(
                jobId: job.id,
                bytesDone: 0,
                bytesTotal: job.bytesTotal,
                status: "failed"
            )]
        }
        destinationBridge.materializeRemotePath(job.destinationPath, children: ["new"])
        return [ScpTransferProgress(
            jobId: job.id,
            bytesDone: job.bytesTotal,
            bytesTotal: job.bytesTotal,
            status: "completed"
        )]
    }
}

private enum CrossDeviceRecordingBridgeError: Error {
    case forcedMutationFailure
}

private final class CrossDeviceFailOnceRelayRemovalFileManager: FileManager, @unchecked Sendable {
    private let failingRemovalURL: URL
    private let lock = NSLock()
    private var hasFailed = false

    init(failingRemovalURL: URL) {
        self.failingRemovalURL = failingRemovalURL.standardizedFileURL
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        let shouldFail = locked { () -> Bool in
            guard hasFailed == false,
                  URL.standardizedFileURL == failingRemovalURL
            else { return false }
            hasFailed = true
            return true
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: URL)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LocalFileFailingBackupCleanupFileManager: FileManager, @unchecked Sendable {
    private var didFailBackupCleanup = false

    override func removeItem(at URL: URL) throws {
        if didFailBackupCleanup == false,
           URL.lastPathComponent.contains(".stacio-backup-")
        {
            didFailBackupCleanup = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

@MainActor
private final class CrossDeviceRecordingTransferScheduler: SCPTransferScheduling {
    private(set) var jobs: [ScpTransferJob] = []
    private(set) var cancelledJobIDs: [String] = []
    var completesImmediately = false
    var materializesDownloads = false
    var acceptsCancellation = true
    var completesCancellationImmediately = true
    private var completions: [String: (ScpTransferProgress) -> Void] = [:]

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        jobs.append(job)
        completions[job.id] = completion
        if materializesDownloads, job.direction == .download {
            let url = URL(fileURLWithPath: job.destinationPath)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(repeating: 0x5A, count: Int(clamping: job.bytesTotal))
            )
        }
        if completesImmediately {
            complete(jobID: job.id, status: "completed")
        }
    }

    func cancelTransfer(jobID: String) -> Bool {
        cancelledJobIDs.append(jobID)
        guard acceptsCancellation else { return false }
        if completesCancellationImmediately {
            complete(jobID: jobID, status: "canceled")
        }
        return true
    }

    func completeLast(status: String) {
        guard let jobID = jobs.last?.id else { return }
        complete(jobID: jobID, status: status)
    }

    private func complete(jobID: String, status: String) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let completion = completions.removeValue(forKey: jobID)
        else { return }
        completion(ScpTransferProgress(
            jobId: jobID,
            bytesDone: status == "completed" ? job.bytesTotal : 0,
            bytesTotal: job.bytesTotal,
            status: status
        ))
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

private final class RecordingRemoteToRemoteTransferBridge: RemoteToRemoteTransferBridging, @unchecked Sendable {
    struct Request: Sendable {
        let job: ScpTransferJob
        let sourceProtocol: String
        let destinationProtocol: String
    }

    private let lock = NSLock()
    private let delay: TimeInterval
    private let blockUntilCancelled: Bool
    private var failuresRemainingStorage: Int
    private var requestsStorage: [Request] = []
    private var cancelledJobIDsStorage: [String] = []
    private var activeRequests = 0
    private var maximumConcurrentRequestsStorage = 0

    init(
        delay: TimeInterval = 0,
        blockUntilCancelled: Bool = false,
        failuresRemaining: Int = 0
    ) {
        self.delay = delay
        self.blockUntilCancelled = blockUntilCancelled
        failuresRemainingStorage = failuresRemaining
    }

    var requests: [Request] { locked { requestsStorage } }
    var cancelledJobIDs: [String] { locked { cancelledJobIDsStorage } }
    var maximumConcurrentRequests: Int { locked { maximumConcurrentRequestsStorage } }

    func runLiveRemoteToRemoteTransfer(
        sourceConfig: SshConnectionConfig,
        sourceSecret: SshAuthSecret,
        sourceExpectedFingerprintSHA256: String,
        destinationConfig: SshConnectionConfig,
        destinationSecret: SshAuthSecret,
        destinationExpectedFingerprintSHA256: String,
        request: RemoteToRemoteTransferRequest
    ) throws -> RemoteToRemoteTransferReport {
        let sourceProtocol = request.sourceProtocol == .scp ? "scp" : "sftp"
        let destinationProtocol = request.destinationProtocol == .scp ? "scp" : "sftp"
        locked {
            requestsStorage.append(Request(
                job: request.job,
                sourceProtocol: sourceProtocol,
                destinationProtocol: destinationProtocol
            ))
            activeRequests += 1
            maximumConcurrentRequestsStorage = max(maximumConcurrentRequestsStorage, activeRequests)
        }
        defer { locked { activeRequests -= 1 } }

        if blockUntilCancelled {
            while locked({ cancelledJobIDsStorage.contains(request.job.id) }) == false {
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw NSError(domain: "RecordingRemoteToRemoteTransferBridge", code: 1)
        }
        let shouldFail = locked { () -> Bool in
            guard failuresRemainingStorage > 0 else { return false }
            failuresRemainingStorage -= 1
            return true
        }
        if shouldFail {
            throw NSError(domain: "RecordingRemoteToRemoteTransferBridge", code: 2)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return RemoteToRemoteTransferReport(
            jobId: request.job.id,
            bytesDone: request.job.bytesTotal,
            bytesTotal: request.job.bytesTotal,
            resumedFrom: request.requestedOffset,
            sha256Hex: String(repeating: "0", count: 64)
        )
    }

    func cancelLiveRemoteToRemoteTransfer(jobID: String) -> Bool {
        locked { cancelledJobIDsStorage.append(jobID) }
        return true
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class PauseResumeRemoteToRemoteTransferBridge: RemoteToRemoteTransferBridging, @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationReceived = DispatchSemaphore(value: 0)
    private let allowCancellationReturn = DispatchSemaphore(value: 0)
    private var runCountStorage = 0
    private var jobIDsStorage: [String] = []

    var runCount: Int { locked { runCountStorage } }
    var jobIDs: [String] { locked { jobIDsStorage } }

    func runLiveRemoteToRemoteTransfer(
        sourceConfig: SshConnectionConfig,
        sourceSecret: SshAuthSecret,
        sourceExpectedFingerprintSHA256: String,
        destinationConfig: SshConnectionConfig,
        destinationSecret: SshAuthSecret,
        destinationExpectedFingerprintSHA256: String,
        request: RemoteToRemoteTransferRequest
    ) throws -> RemoteToRemoteTransferReport {
        let currentRun = locked { () -> Int in
            runCountStorage += 1
            jobIDsStorage.append(request.job.id)
            return runCountStorage
        }
        if currentRun == 1 {
            _ = cancellationReceived.wait(timeout: .now() + 2)
            _ = allowCancellationReturn.wait(timeout: .now() + 2)
            throw NSError(domain: "PauseResumeRemoteToRemoteTransferBridge", code: 1)
        }
        return RemoteToRemoteTransferReport(
            jobId: request.job.id,
            bytesDone: request.job.bytesTotal,
            bytesTotal: request.job.bytesTotal,
            resumedFrom: request.requestedOffset,
            sha256Hex: String(repeating: "0", count: 64)
        )
    }

    func cancelLiveRemoteToRemoteTransfer(jobID: String) -> Bool {
        cancellationReceived.signal()
        return true
    }

    func allowFirstCancellationToReturn() {
        allowCancellationReturn.signal()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
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

private final class RecordingSFTPTransferBridge: SFTPTransferBridging, CustomDebugStringConvertible {
    private let lock = NSLock()
    private let progress: [ScpTransferProgress]
    private var recordedEvents: [String] = []

    init(progress: [ScpTransferProgress]) {
        self.progress = progress
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var debugDescription: String {
        events.joined(separator: " ")
    }

    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        lock.lock()
        recordedEvents.append("run:\(job.id)")
        lock.unlock()
        return progress
    }
}

private final class BlockingSFTPTransferBridge: SFTPTransferBridging {
    private let lock = NSLock()
    private let completionsByJobID: [String: [ScpTransferProgress]]
    private var gatesByJobID: [String: DispatchSemaphore] = [:]
    private var started: [String] = []
    private var finished: [String] = []
    private var cancelled: [String] = []

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

    func release(jobID: String) {
        locked { gatesByJobID[jobID] }?.signal()
    }

    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        let gate = locked { () -> DispatchSemaphore in
            started.append(job.id)
            let gate = gatesByJobID[job.id] ?? DispatchSemaphore(value: 0)
            gatesByJobID[job.id] = gate
            return gate
        }
        gate.wait()
        locked { finished.append(job.id) }
        return completionsByJobID[job.id] ?? []
    }

    func cancelLiveSFTPTransfer(jobID: String) -> Bool {
        locked { cancelled.append(jobID) }
        return true
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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

    private let acceptsCancellation: Bool

    init(
        completionsByJobID: [String: [ScpTransferProgress]],
        acceptsCancellation: Bool = true
    ) {
        self.completionsByJobID = completionsByJobID
        self.acceptsCancellation = acceptsCancellation
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
        return acceptsCancellation
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

@MainActor
private final class RecordingTransferCompletionNotificationPresenter: TransferCompletionNotificationPresenting {
    private(set) var payloads: [TransferCompletionNotificationPayload] = []
    private(set) var dismissedJobIDs: [String] = []
    private(set) var dismissedRuntimeIDs: [String] = []
    private(set) var dismissAllCount = 0

    func present(_ payload: TransferCompletionNotificationPayload) {
        payloads.append(payload)
    }

    func dismiss(jobID: String) {
        dismissedJobIDs.append(jobID)
    }

    func dismiss(runtimeID: String) {
        dismissedRuntimeIDs.append(runtimeID)
    }

    func dismissAll() {
        dismissAllCount += 1
    }
}

private final class RecordingTransferHistoryStore: SCPTransferHistoryStoring {
    var events: [String] = []
    private let jobs: [ScpTransferJobRecord]
    private let eventsByJobID: [String: [ScpTransferEventRecord]]
    private let deleteFinishedResult: Bool
    private let clearFinishedShouldThrow: Bool

    init(
        jobs: [ScpTransferJobRecord] = [],
        eventsByJobID: [String: [ScpTransferEventRecord]] = [:],
        deleteFinishedResult: Bool = true,
        clearFinishedShouldThrow: Bool = false
    ) {
        self.jobs = jobs
        self.eventsByJobID = eventsByJobID
        self.deleteFinishedResult = deleteFinishedResult
        self.clearFinishedShouldThrow = clearFinishedShouldThrow
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
        if clearFinishedShouldThrow {
            throw NSError(domain: "RecordingTransferHistoryStore", code: 1)
        }
        return 0
    }

    func deleteFinishedJob(jobID: String) throws -> Bool {
        events.append("delete-finished:\(jobID)")
        return deleteFinishedResult
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
