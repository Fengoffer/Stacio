import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class TransferQueueViewControllerTests: XCTestCase {
    func testTransferQueueRendersSCPJobProgressInNativeTable() {
        let controller = TransferQueueViewController()
        controller.loadView()

        let job = ScpTransferJob(
            id: "job_upload_1",
            direction: .upload,
            sourcePath: "/Users/alice/build.zip",
            destinationPath: "/srv/releases/build.zip",
            bytesTotal: 100
        )
        let events = [
            ScpTransferProgress(jobId: "job_upload_1", bytesDone: 25, bytesTotal: 100, status: "running"),
            ScpTransferProgress(jobId: "job_upload_1", bytesDone: 64, bytesTotal: 100, status: "running")
        ]

        controller.setTransfers(jobs: [job], progressEvents: events)

        XCTAssertEqual(controller.transferCount, 1)
        XCTAssertEqual(controller.latestStatusText, "传输中")
        XCTAssertEqual(controller.tableView.numberOfRows, 1)
        XCTAssertNotNil(controller.tableView.enclosingScrollView)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["方向", "文件", "进度", "状态"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "上传")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "build.zip")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "64%")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "传输中")
        XCTAssertEqual(controller.engineSummaryText, "SCP 传输")
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("rsync"))
    }

    func testTransferQueueRendersResumingStatusSeparatelyFromFreshTransfer() {
        let controller = TransferQueueViewController()
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_resume_download",
            direction: .download,
            sourcePath: "/srv/releases/build.zip",
            destinationPath: "/Users/alice/build.zip",
            bytesTotal: 100
        )

        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: 40,
                    bytesTotal: 100,
                    status: "resuming"
                )
            ]
        )

        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "40%")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "续传中")
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("状态\n续传中"))
        XCTAssertEqual(controller.transferActionLabels, ["暂停", "停止"])
    }

    func testEmptyTransferQueueUsesAccessibleNativeInspectorState() {
        let controller = TransferQueueViewController()
        controller.loadView()

        XCTAssertEqual(controller.transferCount, 0)
        XCTAssertEqual(controller.tableView.accessibilityIdentifier(), "Stacio.Transfers.queueTable")
        XCTAssertEqual(controller.engineSummaryText, "SCP 传输")
        XCTAssertTrue(controller.visibleTextSnapshot.contains("暂无传输任务"))
    }

    func testTransferQueueInspectorAvoidsNestedCardsAndHorizontalScrolling() throws {
        let controller = TransferQueueViewController()
        controller.loadView()

        let scrollView = try XCTUnwrap(controller.tableView.enclosingScrollView)
        let totalColumnWidth = controller.tableView.tableColumns.reduce(CGFloat(0)) { partialResult, column in
            partialResult + column.width
        }

        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(totalColumnWidth, 300)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Transfers.queueCard"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Transfers.detailCard"))
    }

    func testTransferQueueInspectorSeparatesHeaderTableAndDetailRegions() throws {
        let controller = TransferQueueViewController()
        controller.loadView()

        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        controller.view.layoutSubtreeIfNeeded()

        let header = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Transfers.header"))
        let scrollView = try XCTUnwrap(controller.tableView.enclosingScrollView)
        let detailTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Transfers.detailTitle") as? NSTextField
        )
        let emptyLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Transfers.empty") as? NSTextField
        )

        XCTAssertGreaterThan(scrollView.frame.minY, detailTitle.frame.maxY + 8)
        XCTAssertGreaterThan(header.frame.minY, scrollView.frame.maxY + 8)
        XCTAssertGreaterThanOrEqual(scrollView.frame.height, 118)
        XCTAssertGreaterThan(emptyLabel.frame.minY, scrollView.frame.minY + 24)
        XCTAssertLessThan(emptyLabel.frame.maxY, scrollView.frame.maxY - 24)
    }

    func testProgressOnlyUpdateCoalescesEventsByJobID() {
        let controller = TransferQueueViewController()
        controller.loadView()

        controller.setProgressEvents([
            ScpTransferProgress(jobId: "job_download_1", bytesDone: 10, bytesTotal: 100, status: "running"),
            ScpTransferProgress(jobId: "job_download_1", bytesDone: 90, bytesTotal: 100, status: "running")
        ])

        XCTAssertEqual(controller.transferCount, 1)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "job_download_1")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "90%")
    }

    func testTransferQueueRendersLiveSpeedAndETAAfterProgressAdvances() {
        var now = Date(timeIntervalSince1970: 100)
        let controller = TransferQueueViewController(nowProvider: { now })
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_speed_eta",
            direction: .upload,
            sourcePath: "/Users/alice/build.zip",
            destinationPath: "/srv/releases/build.zip",
            bytesTotal: 2_048
        )

        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 0, bytesTotal: 2_048, status: "running")
            ]
        )
        now = Date(timeIntervalSince1970: 101)
        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 0, bytesTotal: 2_048, status: "running"),
                ScpTransferProgress(jobId: job.id, bytesDone: 1_024, bytesTotal: 2_048, status: "running")
            ]
        )

        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "50% · 剩余 1 秒")
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("50% · 剩余 1 秒  1 KB/s"))
    }

    func testTransferQueueRendersLiveSpeedAndETAWhileResuming() {
        var now = Date(timeIntervalSince1970: 100)
        let controller = TransferQueueViewController(nowProvider: { now })
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_resume_speed_eta",
            direction: .download,
            sourcePath: "/srv/releases/build.zip",
            destinationPath: "/Users/alice/build.zip",
            bytesTotal: 2_048
        )
        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 512, bytesTotal: 2_048, status: "resuming")
            ]
        )
        now = Date(timeIntervalSince1970: 101)
        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 1_024, bytesTotal: 2_048, status: "resuming")
            ]
        )

        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "50% · 剩余 2 秒")
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("50% · 剩余 2 秒  512 B/s"))
    }

    func testTransferQueueRendersFailureDetailWithoutChangingProgressColumns() {
        let controller = TransferQueueViewController()
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_failed_detail",
            direction: .upload,
            sourcePath: "/Users/alice/build.zip",
            destinationPath: "/srv/releases/build.zip",
            bytesTotal: 100
        )

        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 0, bytesTotal: 100, status: "failed")
            ],
            diagnosticsByJobID: [
                job.id: "Authentication failed"
            ]
        )

        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "0%")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "失败")
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("诊断\n认证失败"))
    }

    func testTransferQueueShowsPauseStopResumeAndRetryActionsForTransferStates() {
        let controller = TransferQueueViewController()
        controller.loadView()
        var actions: [(TransferQueueAction, String)] = []
        controller.onTransferAction = { action, jobID in
            actions.append((action, jobID))
        }

        let runningJob = makeTransferJob(id: "job_running")
        let pausedJob = makeTransferJob(id: "job_paused")
        let stoppedJob = makeTransferJob(id: "job_stopped")

        controller.setTransfers(
            jobs: [runningJob, pausedJob, stoppedJob],
            progressEvents: [
                ScpTransferProgress(jobId: "job_running", bytesDone: 20, bytesTotal: 100, status: "running"),
                ScpTransferProgress(jobId: "job_paused", bytesDone: 40, bytesTotal: 100, status: "paused"),
                ScpTransferProgress(jobId: "job_stopped", bytesDone: 60, bytesTotal: 100, status: "stopped")
            ]
        )

        XCTAssertEqual(controller.transferCount, 3)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "传输中")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 1), "已暂停")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 2), "已停止")

        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["暂停", "停止"])
        controller.performTransferActionForTesting(at: 0)
        controller.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["恢复", "重新开始"])
        controller.performTransferActionForTesting(at: 0)
        controller.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["重试", "重新开始"])
        controller.performTransferActionForTesting(at: 0)

        XCTAssertEqual(actions.map(\.0), [.pause, .resume, .retry])
        XCTAssertEqual(actions.map(\.1), ["job_running", "job_paused", "job_stopped"])
    }

    func testTransferQueueExposesClearFinishedAction() throws {
        let controller = TransferQueueViewController()
        controller.loadView()
        var clearCount = 0
        controller.onClearFinished = { clearCount += 1 }
        let job = makeTransferJob(id: "job_completed")
        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ]
        )

        let clearButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Transfers.clearFinished") as? NSButton
        )

        XCTAssertEqual(clearButton.toolTip, "清理已结束")
        XCTAssertEqual(clearButton.accessibilityLabel(), "清理已结束")

        clearButton.performClick(nil as Any?)

        XCTAssertEqual(clearCount, 1)
    }

    func testTransferQueueDisablesClearFinishedWhenQueueIsEmpty() throws {
        let controller = TransferQueueViewController()
        controller.loadView()

        controller.setTransfers(jobs: [], progressEvents: [])

        let clearButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Transfers.clearFinished") as? NSButton
        )
        XCTAssertFalse(clearButton.isEnabled)
    }

    func testTransferQueueEnablesClearFinishedWhenAnyFinishedJobExists() throws {
        let controller = TransferQueueViewController()
        controller.loadView()
        let jobs = [
            makeTransferJob(id: "job_completed"),
            makeTransferJob(id: "job_failed"),
            makeTransferJob(id: "job_canceled")
        ]

        controller.setTransfers(
            jobs: jobs,
            progressEvents: [
                ScpTransferProgress(jobId: "job_completed", bytesDone: 100, bytesTotal: 100, status: "completed"),
                ScpTransferProgress(jobId: "job_failed", bytesDone: 50, bytesTotal: 100, status: "failed"),
                ScpTransferProgress(jobId: "job_canceled", bytesDone: 10, bytesTotal: 100, status: "canceled")
            ]
        )

        let clearButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Transfers.clearFinished") as? NSButton
        )
        XCTAssertTrue(clearButton.isEnabled)
    }

    func testTransferQueueActionButtonsFollowSelectedJobStatus() throws {
        let controller = TransferQueueViewController()
        controller.loadView()
        let jobs = [
            makeTransferJob(id: "job_running"),
            makeTransferJob(id: "job_queued"),
            makeTransferJob(id: "job_failed"),
            makeTransferJob(id: "job_completed"),
            makeTransferJob(id: "job_canceled")
        ]
        controller.setTransfers(
            jobs: jobs,
            progressEvents: [
                ScpTransferProgress(jobId: "job_running", bytesDone: 10, bytesTotal: 100, status: "running"),
                ScpTransferProgress(jobId: "job_queued", bytesDone: 0, bytesTotal: 100, status: "queued"),
                ScpTransferProgress(jobId: "job_failed", bytesDone: 20, bytesTotal: 100, status: "failed"),
                ScpTransferProgress(jobId: "job_completed", bytesDone: 100, bytesTotal: 100, status: "completed"),
                ScpTransferProgress(jobId: "job_canceled", bytesDone: 30, bytesTotal: 100, status: "canceled")
            ]
        )

        let primaryButton = try XCTUnwrap(controller.view.firstButton(withAccessibilityLabel: "暂停"))
        let secondaryButton = try XCTUnwrap(controller.view.firstButton(withAccessibilityLabel: "停止"))

        XCTAssertFalse(primaryButton.isEnabled)
        XCTAssertFalse(secondaryButton.isEnabled)

        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["暂停", "停止"])
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(secondaryButton.isEnabled)

        controller.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["暂停", "停止"])
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(secondaryButton.isEnabled)

        controller.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["重试", "重新开始"])
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(secondaryButton.isEnabled)

        controller.tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["暂停", "停止"])
        XCTAssertFalse(primaryButton.isEnabled)
        XCTAssertFalse(secondaryButton.isEnabled)

        controller.tableView.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        XCTAssertEqual(controller.transferActionLabels, ["重试", "重新开始"])
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(secondaryButton.isEnabled)
    }

    func testTransferQueueSelectionFollowsSelectedJobWhenRowsReorder() {
        let controller = TransferQueueViewController()
        controller.loadView()
        var actions: [(TransferQueueAction, String)] = []
        controller.onTransferAction = { action, jobID in
            actions.append((action, jobID))
        }
        let selectedJob = makeTransferJob(id: "job_selected")
        let otherJob = makeTransferJob(id: "job_other")

        controller.setTransfers(
            jobs: [otherJob, selectedJob],
            progressEvents: [
                ScpTransferProgress(jobId: otherJob.id, bytesDone: 10, bytesTotal: 100, status: "running"),
                ScpTransferProgress(jobId: selectedJob.id, bytesDone: 40, bytesTotal: 100, status: "paused")
            ]
        )
        controller.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        controller.setTransfers(
            jobs: [selectedJob, otherJob],
            progressEvents: [
                ScpTransferProgress(jobId: selectedJob.id, bytesDone: 40, bytesTotal: 100, status: "paused"),
                ScpTransferProgress(jobId: otherJob.id, bytesDone: 10, bytesTotal: 100, status: "running")
            ]
        )

        XCTAssertEqual(controller.tableView.selectedRow, 0)
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("任务 ID\njob_selected"))
        XCTAssertEqual(controller.transferActionLabels, ["恢复", "重新开始"])

        controller.performTransferActionForTesting(at: 0)

        XCTAssertEqual(actions.map(\.0), [.resume])
        XCTAssertEqual(actions.map(\.1), ["job_selected"])
    }

    func testTransferQueueShowsSelectedJobDetailInspectorWithRedactedDiagnostic() {
        let controller = TransferQueueViewController()
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_detail",
            direction: .download,
            sourcePath: "/srv/releases/build.zip",
            destinationPath: "/Users/alice/build.zip",
            bytesTotal: 200
        )

        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 128, bytesTotal: 200, status: "failed")
            ],
            diagnosticsByJobID: [
                job.id: "认证失败 secret-ref=/Users/alice/.ssh/id_ed25519"
            ]
        )
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("任务 ID\njob_detail"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("方向\n下载"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("状态\n失败"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("进度\n64%"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("来源\n/srv/releases/build.zip"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("目标\n/Users/alice/build.zip"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("诊断\n认证失败 [已隐藏凭据]"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("传输日志"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("任务详情"))
        XCTAssertFalse(controller.selectedTransferDetailTextForTesting.contains("secret-ref"))
        XCTAssertFalse(controller.selectedTransferDetailTextForTesting.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testTransferQueueDetailInspectorShowsTransferLogFromProgressEvents() {
        let controller = TransferQueueViewController()
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_log",
            direction: .upload,
            sourcePath: "/Users/alice/build.zip",
            destinationPath: "/srv/releases/build.zip",
            bytesTotal: 100
        )

        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 0, bytesTotal: 100, status: "queued"),
                ScpTransferProgress(jobId: job.id, bytesDone: 30, bytesTotal: 100, status: "running"),
                ScpTransferProgress(jobId: job.id, bytesDone: 100, bytesTotal: 100, status: "completed")
            ]
        )
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("传输日志"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("排队中 · 0%"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("传输中 · 30%"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("已完成 · 100%"))
    }

    func testTransferQueueDetailInspectorShowsHistoricalTransferLogWithRedactedMessages() {
        let controller = TransferQueueViewController()
        controller.loadView()
        let job = ScpTransferJob(
            id: "job_history_log",
            direction: .download,
            sourcePath: "/srv/releases/build.zip",
            destinationPath: "/Users/alice/build.zip",
            bytesTotal: 100
        )

        controller.setTransfers(
            jobs: [job],
            progressEvents: [
                ScpTransferProgress(jobId: job.id, bytesDone: 40, bytesTotal: 100, status: "failed")
            ],
            eventLogsByJobID: [
                job.id: [
                    TransferEventLogEntry(
                        status: "queued",
                        bytesDone: 0,
                        bytesTotal: 100,
                        createdAt: "2026-05-27T00:00:00Z"
                    ),
                    TransferEventLogEntry(
                        status: "failed",
                        bytesDone: 40,
                        bytesTotal: 100,
                        message: "Permission denied secret-ref=/Users/alice/.ssh/id_ed25519",
                        createdAt: "2026-05-27T00:00:02Z"
                    )
                ]
            ]
        )
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("2026-05-27T00:00:00Z · 排队中 · 0%"))
        XCTAssertTrue(controller.selectedTransferDetailTextForTesting.contains("2026-05-27T00:00:02Z · 失败 · 40% · 权限被拒绝"))
        XCTAssertFalse(controller.selectedTransferDetailTextForTesting.contains("secret-ref"))
        XCTAssertFalse(controller.selectedTransferDetailTextForTesting.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testTransferQueueDetailInspectorReturnsEmptyStateWhenSelectionIsCleared() {
        let controller = TransferQueueViewController()
        controller.loadView()

        controller.setTransfers(jobs: [], progressEvents: [])

        XCTAssertEqual(controller.selectedTransferDetailTextForTesting, "选择传输任务查看详情")
    }

    func testInspectorDoesNotExposeSeparateTransfersTabButKeepsTransferCoordinator() {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())
        controller.loadView()

        XCTAssertNotNil(controller.transferQueueViewController)
        XCTAssertNotNil(controller.transferQueueCoordinator)
        XCTAssertEqual(controller.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        XCTAssertFalse(controller.sectionLabelsForTesting.contains("传输"))
    }
}

private func makeTransferJob(id: String) -> ScpTransferJob {
    ScpTransferJob(
        id: id,
        direction: .upload,
        sourcePath: "/Users/alice/\(id)",
        destinationPath: "/srv/\(id)",
        bytesTotal: 100
    )
}

private extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }
}


private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }

        return nil
    }

    func firstButton(withAccessibilityLabel label: String) -> NSButton? {
        if let button = self as? NSButton,
           button.accessibilityLabel() == label {
            return button
        }

        for subview in subviews {
            if let match = subview.firstButton(withAccessibilityLabel: label) {
                return match
            }
        }

        return nil
    }
}
