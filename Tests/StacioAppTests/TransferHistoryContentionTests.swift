import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class TransferHistoryContentionTests: XCTestCase {
    func testPauseAllOnRestoredQueuedRowDoesNotPreventLiveSessionTakingOver() throws {
        let (dir, store, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transfer = job("restored-before-pause-all")
        try store.recordJob(sessionID: nil, job: transfer, status: "queued", bytesDone: 0)
        let view = TransferQueueViewController()
        view.loadView()
        let queue = TransferQueueCoordinator(historyStore: store, queueViewController: view)
        try queue.restoreHistory()
        view.performPauseAllForTesting()
        XCTAssertEqual(view.snapshotForTesting.rows.first?.rawStatus, "paused")
        var rows: [TransferQueueSnapshot.Row] = []
        let observer = queue.observeQueue(runtimeIDs: { ["new-session"] }) { rows = $0.rows }
        defer { queue.removeQueueObservation(observer) }
        var stopped = false
        XCTAssertTrue(queue.registerExternalTransfer(runtimeID: "new-session", job: transfer, startsQueued: true,
            progressProvider: { [] }, resume: { true }, cancel: { stopped = true; return true }, pauseWithProgress: { [] }))
        queue.acquireExternalSlot(jobID: transfer.id)
        XCTAssertEqual(rows.map(\.rawStatus), ["running"])
        XCTAssertTrue(queue.stopTransfer(jobID: transfer.id))
        XCTAssertTrue(stopped)
        XCTAssertEqual(try store.listJobs().first?.status, "stopped")
    }

    func testNewDirectSessionTakesOverRestoredRouteButNotLiveControls() async throws {
        let (dir, store, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transfer = job("remote-to-remote-v1-restored")
        try store.recordJob(sessionID: nil, job: transfer, status: "queued", bytesDone: 0)
        _ = try store.appendProgress(.init(jobId: transfer.id, bytesDone: 2, bytesTotal: 5, status: "paused"))
        let view = TransferQueueViewController()
        view.loadView()
        let queue = TransferQueueCoordinator(historyStore: store, queueViewController: view)
        queue.loadHistoryWhenOpened()
        let deadline = Date().addingTimeInterval(3)
        while view.snapshotForTesting.rows.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(view.snapshotForTesting.rows.first?.rawStatus, "paused")
        XCTAssertFalse(view.bulkActionAvailabilityForTesting.resume)

        var rows: [TransferQueueSnapshot.Row] = []
        let observer = queue.observeQueue(runtimeIDs: { ["new-session"] }) { rows = $0.rows }
        defer { queue.removeQueueObservation(observer) }
        var cancellations: [String] = []
        func register(_ session: String) {
            queue.registerExternalTransfer(runtimeID: session, job: transfer, startsQueued: true,
                progressProvider: { [] }, resume: { true }, cancel: { cancellations.append(session); return true },
                pauseWithProgress: { [] })
        }
        register("new-session")
        XCTAssertEqual(rows.map(\.rawStatus), ["queued"])
        XCTAssertEqual(try store.listEvents(jobID: transfer.id).last?.eventType, "queued")
        queue.acquireExternalSlot(jobID: transfer.id)
        XCTAssertEqual(rows.map(\.rawStatus), ["running"])
        XCTAssertTrue(queue.pauseTransfer(jobID: transfer.id))
        register("other-session")
        XCTAssertEqual(rows.map(\.rawStatus), ["paused"])
        XCTAssertTrue(queue.cancelTransfer(jobID: transfer.id))
        XCTAssertEqual(cancellations, ["new-session"])
        XCTAssertEqual(try store.listJobs().first?.status, "canceled")
    }

    func testOpenRetriesAfterReplayIsBlockedAndKeepsNewTransfer() async throws {
        let (dir, store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = job("saved")
        try store.recordJob(sessionID: nil, job: saved, status: "completed", bytesDone: 5)
        let locker = try SQLiteTestLocker(path)
        _ = try store.appendProgress(.init(jobId: saved.id, bytesDone: 5, bytesTotal: 5, status: "completed"))
        let view = TransferQueueViewController(); view.loadView()
        let coordinator = TransferQueueCoordinator(historyStore: store, queueViewController: view)
        coordinator.loadHistoryWhenOpened()
        let active = job("active")
        coordinator.registerExternalTransfer(runtimeID: "live", job: active, progressProvider: { [] }, pause: { true }, resume: { true }, cancel: { true })
        try await Task.sleep(nanoseconds: 300_000_000)
        locker.unlock()
        let deadline = Date().addingTimeInterval(4)
        while view.snapshotForTesting.rows.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(Set(view.snapshotForTesting.rows.map(\.jobID)), [saved.id, active.id])
        XCTAssertTrue(coordinator.pauseTransfer(jobID: active.id))
        _ = coordinator.cancelTransfer(jobID: active.id)
        _ = try store.listJobs()
    }

    func testBulkClearReturnsImmediatelyAndPreservesLaterCompletionUnderLock() async throws {
        try await checkDeletionWhileLocked(single: false)
    }

    func testSingleDeleteReturnsImmediatelyAndPreservesLaterCompletionUnderLock() async throws {
        try await checkDeletionWhileLocked(single: true)
    }

    private func checkDeletionWhileLocked(single: Bool) async throws {
        let (dir, store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0...16 {
            try store.recordJob(sessionID: nil, job: job("file-\(i)"), status: i == 16 ? "completed" : "running", bytesDone: i == 16 ? 5 : 1)
        }
        let view = TransferQueueViewController(); view.loadView()
        let coordinator = TransferQueueCoordinator(historyStore: store, queueViewController: view)
        try coordinator.restoreHistory()
        let locker = try SQLiteTestLocker(path)
        for i in 0..<16 {
            let id = "file-\(i)"
            store.scheduleWrite(jobID: id, coalescing: true) {
                _ = try? store.appendProgress(.init(jobId: id, bytesDone: 2, bytesTotal: 5, status: "running"))
            }
        }
        let completed = expectation(description: "cleared after unlocking")
        let start = ProcessInfo.processInfo.systemUptime
        if single {
            coordinator.removeFinishedTransfer(jobID: "file-16") { removed in
                XCTAssertTrue(removed)
                completed.fulfill()
            }
        } else {
            coordinator.clearFinishedTransfers { count in
                XCTAssertEqual(count, 1)
                completed.fulfill()
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, 0.25)
        print("TRANSFER_CLEAR_MAIN_SECONDS=\(elapsed)")
        // Wait until the clear and the subsequent finish are both durable in the
        // sidecar, so this exercises replay order and not only the unlocked path.
        let staged = expectation(description: "finished after the clear was recorded")
        store.scheduleWrite(jobID: "file-0", coalescing: false) {
            _ = try? store.appendProgress(.init(jobId: "file-0", bytesDone: 5, bytesTotal: 5, status: "completed"))
            staged.fulfill()
        }
        await fulfillment(of: [staged], timeout: 8)
        locker.unlock()
        await fulfillment(of: [completed], timeout: 5)
        let records = try store.listJobs()
        XCTAssertEqual(records.count, 16)
        XCTAssertEqual(records.first { $0.job.id == "file-0" }?.status, "completed")
        XCTAssertFalse(view.snapshotForTesting.rows.contains { $0.jobID == "file-16" })
    }

    func testClearThenRetryWhileLockedPreservesTheNewAttemptAfterReopen() async throws {
        let (dir, store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let view = TransferQueueViewController()
        view.loadView()
        let queue = TransferQueueCoordinator(bridge: FailingSCPBridge(), historyStore: store, queueViewController: view)
        let transfer = job("retry")
        let config = SshConnectionConfig(host: "fixture", port: 22, username: "test", authMethod: .agent, connectTimeoutMs: 1000)
        func waitForFailure() async throws {
            let deadline = Date().addingTimeInterval(3)
            while view.snapshotForTesting.rows.first?.rawStatus != "failed", Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(view.snapshotForTesting.rows.first?.rawStatus, "failed")
        }
        queue.scheduleLiveTransfer(config: config, secret: .agent, expectedFingerprintSHA256: "fixture", job: transfer)
        try await waitForFailure()
        XCTAssertEqual(try store.listJobs().first?.status, "failed")
        let locker = try SQLiteTestLocker(path)
        let cleared = expectation(description: "the new attempt is kept")
        queue.clearFinishedTransfers { count in
            XCTAssertEqual(count, 0)
            cleared.fulfill()
        }
        XCTAssertTrue(queue.retryFailedTransfer(jobID: transfer.id))
        try await waitForFailure()
        let staged = expectation(description: "retry writes are durable")
        store.scheduleWrite(jobID: transfer.id, coalescing: false) { staged.fulfill() }
        await fulfillment(of: [staged], timeout: 5)
        locker.unlock()
        await fulfillment(of: [cleared], timeout: 5)
        let reopened = CoreBridgeSCPTransferHistoryStore(databasePath: path)
        let records = try reopened.listJobs()
        XCTAssertEqual(records.map(\.job.id), [transfer.id])
        XCTAssertEqual(records.first?.status, "failed")
        XCTAssertEqual(view.snapshotForTesting.rows.first?.rawStatus, "failed")
        try reopened.recordJob(sessionID: nil, job: job("other"), status: "queued", bytesDone: 0)
        XCTAssertEqual(try store.listJobs().count, 2)
    }

    private func job(_ id: String) -> ScpTransferJob {
        ScpTransferJob(id: id, direction: .upload, sourcePath: id, destinationPath: "/" + id, bytesTotal: 5)
    }

    private func makeStore() throws -> (URL, CoreBridgeSCPTransferHistoryStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let path = dir.appendingPathComponent("history.db").path
        return (dir, CoreBridgeSCPTransferHistoryStore(databasePath: path), path)
    }
}
private final class SQLiteTestLocker: @unchecked Sendable {
    private let p = Process(), input = Pipe(), output = Pipe()
    init(_ path: String) throws {
        p.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3"); p.arguments=[path]; p.standardInput=input; p.standardOutput=output
        try p.run(); input.fileHandleForWriting.write(Data("BEGIN IMMEDIATE; SELECT 42;\n".utf8))
        XCTAssertEqual(String(decoding:output.fileHandleForReading.availableData,as:UTF8.self),"42\n")
    }
    func unlock() { input.fileHandleForWriting.write(Data("ROLLBACK;\n".utf8)); try? input.fileHandleForWriting.close(); p.waitUntilExit() }
}

private final class FailingSCPBridge: SCPTransferBridging {
    func runLiveSCPTransfer(config: SshConnectionConfig, secret: SshAuthSecret,
                            expectedFingerprintSHA256: String, job: ScpTransferJob) throws -> [ScpTransferProgress] {
        throw NSError(domain: "TransferHistoryContentionTests", code: 1)
    }
}
