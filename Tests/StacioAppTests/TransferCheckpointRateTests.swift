import AppKit
import SQLite3
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class TransferCheckpointRateTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824
    private let mib: UInt64 = 1_048_576

    func testRecoveredNonzeroCheckpointDoesNotCreateRateOnAnySurface() async throws {
        // Include a batch where writes have already advanced past the checkpoint
        // before the first poll. Neither cached bytes nor that initial sample is a burst.
        for coalesced in [false, true] {
            let fixture = CheckpointRateFixture(transport: .external)
            defer { fixture.stop() }
            let initial = 8 * gib + (coalesced ? mib : 0)
            fixture.clock.now = Date(timeIntervalSince1970: 100.5)
            fixture.publish(coalesced ? [(8 * gib, "resuming"), (initial, "running")] : [(initial, "resuming")])
            await waitUntil { fixture.latest?.bytesDone == initial }
            assertNoMeasuredRate(fixture)
            let baseline = try XCTUnwrap(fixture.latest?.rateBaselineID)
            fixture.clock.now = Date(timeIntervalSince1970: 101.5)
            fixture.publish([(initial + mib, "running")])
            await waitUntil { fixture.latest?.bytesDone == initial + self.mib }
            assertRate(fixture, bytesPerSecond: Double(mib))
            XCTAssertEqual(fixture.latest?.rateBaselineID, baseline)
        }
    }

    func testCheckpointAheadOfPausedDisplayResetsAllSurfacesForAllTransports() async throws {
        for transport in CheckpointRateFixture.Transport.allCases {
            let fixture = CheckpointRateFixture(transport: transport)
            defer { fixture.stop() }
            if transport != .external { await waitUntil { fixture.bridge.startedCount == 1 } }
            fixture.clock.now = Date(timeIntervalSince1970: 101)
            fixture.publish([(gib, "running")])
            await waitUntil { fixture.latest?.bytesDone == self.gib }
            let oldBaseline = try XCTUnwrap(fixture.latest?.rateBaselineID)
            XCTAssertTrue(fixture.coordinator.pauseTransfer(jobID: fixture.job.id))
            fixture.clock.now = Date(timeIntervalSince1970: 110)
            XCTAssertTrue(fixture.coordinator.resumeTransfer(jobID: fixture.job.id))
            if transport != .external {
                fixture.bridge.release()
                await waitUntil { fixture.bridge.startedCount == 2 }
            }
            fixture.clock.now = Date(timeIntervalSince1970: 110.5)
            fixture.publish([(2 * gib, "resuming")])
            await waitUntil { fixture.latest?.bytesDone == 2 * self.gib }
            assertNoMeasuredRate(fixture)
            XCTAssertNotEqual(fixture.latest?.rateBaselineID, oldBaseline)
            fixture.clock.now = Date(timeIntervalSince1970: 111.5)
            fixture.publish([(2 * gib + mib, "running")])
            await waitUntil { fixture.latest?.bytesDone == 2 * self.gib + self.mib }
            assertRate(fixture, bytesPerSecond: Double(mib))
        }
    }

    func testZeroCheckpointPublishesBaselineEvenWhenCounterAndStatusAreUnchanged() async throws {
        let fixture = CheckpointRateFixture(transport: .external)
        defer { fixture.stop() }
        fixture.clock.now = Date(timeIntervalSince1970: 100.5)
        fixture.publish([(0, "running")])
        await waitUntil { fixture.latest?.rateBaselineID != nil }
        assertNoMeasuredRate(fixture)
        fixture.clock.now = Date(timeIntervalSince1970: 101.5)
        fixture.publish([(mib, "running")])
        await waitUntil { fixture.latest?.bytesDone == self.mib }
        assertRate(fixture, bytesPerSecond: Double(mib))
    }

    func testCompletionAverageExcludesCheckpointEvenWhenPollMissedItsOffset() async throws {
        for reportBeforePoll in [false, true] {
            let fixture = CheckpointRateFixture(transport: .external)
            let checkpoint = fixture.job.bytesTotal - mib
            if !reportBeforePoll {
                fixture.publish([(checkpoint, "resuming")])
                await waitUntil { fixture.latest?.bytesDone == checkpoint }
            }
            fixture.clock.now = Date(timeIntervalSince1970: 101)
            fixture.coordinator.finishExternalTransfer(
                jobID: fixture.job.id, status: "completed", bytesDone: fixture.job.bytesTotal,
                resumedFrom: reportBeforePoll ? checkpoint : nil
            )
            XCTAssertEqual(fixture.popover.rowsForTesting.first?.speedText, "平均速率 1 MB/s")
            XCTAssertEqual(fixture.presenter.payload?.averageBytesPerSecond, Double(mib))
            XCTAssertEqual(fixture.presenter.payload?.byteCount, fixture.job.bytesTotal)
        }
    }

    func testBulkClearReleasesBothObservedAndUnobservedRunState() async throws {
        for observed in [true, false] {
            let fixture = CheckpointRateFixture(transport: .external)
            if observed {
                fixture.publish([(mib, "running")])
                await waitUntil { fixture.latest?.rateBaselineID != nil }
            }
            fixture.coordinator.finishExternalTransfer(jobID: fixture.job.id, status: "completed", bytesDone: fixture.job.bytesTotal)
            let removed = await withCheckedContinuation { continuation in
                fixture.coordinator.clearFinishedTransfers { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(removed, 1)
            let fields = Mirror(reflecting: fixture.coordinator).children
            for key in ["rateBaselineIDsByJobID", "progressRunTokensByJobID"] {
                let tokens = try XCTUnwrap(fields.first { $0.label == key }?.value as? [String: UUID])
                XCTAssertNil(tokens[fixture.job.id], key)
            }
            let pending = try XCTUnwrap(fields.first { $0.label == "awaitingInitialProgressJobIDs" }?.value as? Set<String>)
            XCTAssertFalse(pending.contains(fixture.job.id))
        }
    }

    func testLockedHistoryDoesNotBlockProgressOrReorderPauseAndCompletion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("history.db").path
        let history = CoreBridgeSCPTransferHistoryStore(databasePath: path)
        let fixture = CheckpointRateFixture(transport: .external, history: history)
        let id = fixture.job.id
        XCTAssertEqual(try history.listJobs().first?.job.id, id)
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &locker), SQLITE_OK)
        defer { sqlite3_close(locker) }
        XCTAssertEqual(sqlite3_exec(locker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        fixture.publish([(0, "running"), (mib, "running")])
        await waitUntil { fixture.latest?.bytesDone == self.mib }
        XCTAssertTrue(fixture.coordinator.pauseTransfer(jobID: id))
        XCTAssertTrue(fixture.coordinator.resumeTransfer(jobID: id))
        fixture.publish([(0, "resuming"), (2 * mib, "running")])
        await waitUntil { fixture.latest?.bytesDone == 2 * self.mib }
        fixture.coordinator.finishExternalTransfer(jobID: id, status: "completed", bytesDone: fixture.job.bytesTotal)
        XCTAssertEqual(fixture.latest?.rawStatus, "completed")
        // No SQLite write can have succeeded yet. All progress reached the UI while locked.
        XCTAssertEqual(sqlite3_exec(locker, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let otherHandle = CoreBridgeSCPTransferHistoryStore(databasePath: path)
        let events = try otherHandle.listEvents(jobID: id)
        XCTAssertEqual(events.map(\.eventType), ["running", "paused", "resuming", "running", "completed"])
        XCTAssertEqual(events.first?.bytesDone, mib)
        XCTAssertEqual(events.last?.bytesDone, fixture.job.bytesTotal)
        let removed = await withCheckedContinuation { continuation in
            fixture.coordinator.clearFinishedTransfers { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(try otherHandle.listJobs().isEmpty)
    }

    func testRemotePauseIncludesFirstCoalescedWriteInCompletionAverage() async throws {
        let fixture = CheckpointRateFixture(transport: .external)
        let firstBytes = fixture.job.bytesTotal / 4
        fixture.clock.now = Date(timeIntervalSince1970: 101)
        fixture.publish([(firstBytes, "running")])
        await waitUntil { fixture.latest?.bytesDone == firstBytes }
        XCTAssertTrue(fixture.coordinator.pauseTransfer(jobID: fixture.job.id))
        fixture.clock.now = Date(timeIntervalSince1970: 110)
        XCTAssertTrue(fixture.coordinator.resumeTransfer(jobID: fixture.job.id))
        fixture.clock.now = Date(timeIntervalSince1970: 111)
        fixture.coordinator.finishExternalTransfer(jobID: fixture.job.id, status: "completed", bytesDone: fixture.job.bytesTotal, resumedFrom: 0)
        let rate = try XCTUnwrap(fixture.latest?.averageBytesPerSecond)
        XCTAssertEqual(rate, Double(fixture.job.bytesTotal + firstBytes) / 2)
    }

    func testCompletedStateSurvivesSustainedHistoryLock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.db").path
        let history = CoreBridgeSCPTransferHistoryStore(databasePath: path)
        let fixture = CheckpointRateFixture(transport: .external, history: history)
        let id = fixture.job.id
        XCTAssertEqual(try history.listJobs().first?.job.id, id)
        let locker = Process(), requests = Pipe(), responses = Pipe()
        locker.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        locker.arguments = [path]; locker.standardInput = requests; locker.standardOutput = responses
        try locker.run()
        func sql(_ command: String) { requests.fileHandleForWriting.write(Data((command + "\n").utf8)) }
        defer { try? requests.fileHandleForWriting.close(); locker.waitUntilExit() }
        sql("BEGIN IMMEDIATE; SELECT 42;")
        XCTAssertEqual(String(decoding: responses.fileHandleForReading.availableData, as: UTF8.self), "42\n")
        fixture.coordinator.finishExternalTransfer(jobID: id, status: "completed", bytesDone: fixture.job.bytesTotal)
        XCTAssertEqual(fixture.latest?.rawStatus, "completed")
        let attempt = expectation(description: "history writer finished attempt while locked")
        history.scheduleWrite(jobID: id, coalescing: false) { attempt.fulfill() }
        await fulfillment(of: [attempt], timeout: 12)
        sql("ROLLBACK; SELECT 43;")
        XCTAssertEqual(String(decoding: responses.fileHandleForReading.availableData, as: UTF8.self), "43\n")
        let saved = try XCTUnwrap(try history.listJobs().first)
        let cleared = await withCheckedContinuation { continuation in
            fixture.coordinator.clearFinishedTransfers { continuation.resume(returning: $0) }
        }
        let rows = try history.listJobs()
        XCTAssertEqual(saved.status, "completed")
        XCTAssertEqual(cleared, 1)
        XCTAssertTrue(rows.isEmpty)
    }

    func testPauseCountsWritesPublishedBetweenPolls() async throws {
        let fixture = CheckpointRateFixture(transport: .external, bytesTotal: 16 * mib)
        let m: UInt64 = 1_048_576
        fixture.clock.now = Date(timeIntervalSince1970: 101)
        fixture.publish([(4*m,"running")])
        let deadline = Date().addingTimeInterval(2)
        while fixture.latest?.bytesDone != 4*m && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(fixture.latest?.bytesDone, 4*m)
        fixture.bridge.publish([.init(jobId: fixture.job.id, bytesDone: 8*m, bytesTotal: fixture.job.bytesTotal, status: "running")])
        XCTAssertTrue(fixture.coordinator.pauseTransfer(jobID: fixture.job.id))
        fixture.clock.now = Date(timeIntervalSince1970: 110)
        XCTAssertTrue(fixture.coordinator.resumeTransfer(jobID: fixture.job.id))
        fixture.clock.now = Date(timeIntervalSince1970: 111)
        fixture.coordinator.finishExternalTransfer(jobID: fixture.job.id, status: "completed", bytesDone: 16*m, resumedFrom: 0)
        let measured = try XCTUnwrap(fixture.latest?.averageBytesPerSecond) / Double(m)
        XCTAssertEqual(measured, 12)
    }
    private func assertNoMeasuredRate(_ fixture: CheckpointRateFixture, file: StaticString = #filePath, line: UInt = #line) {
        for text in fixture.metricTexts {
            XCTAssertLessThanOrEqual(rate(in: text) ?? 0, 0, text, file: file, line: line)
        }
        XCTAssertFalse(fixture.fileStatus.contains("剩余"), file: file, line: line)
        XCTAssertEqual(fixture.popover.rowsForTesting.first?.remainingText, "剩余 --", file: file, line: line)
    }

    private func assertRate(_ fixture: CheckpointRateFixture, bytesPerSecond: Double, file: StaticString = #filePath, line: UInt = #line) {
        for text in fixture.metricTexts {
            XCTAssertEqual(rate(in: text) ?? -1, bytesPerSecond, accuracy: 0.1, text, file: file, line: line)
        }
    }

    private func rate(in text: String) -> Double? {
        guard let range = text.range(of: #"[0-9]+(?:\.[0-9]+)? (?:B|KB|MB|GB)/s"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: " ")
        let factors: [String: Double] = ["B/s": 1, "KB/s": 1024, "MB/s": 1_048_576, "GB/s": 1_073_741_824]
        return Double(parts[0]).map { $0 * (factors[String(parts[1])] ?? 0) }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class CheckpointRatePresenter: TransferCompletionNotificationPresenting {
    var payload: TransferCompletionNotificationPayload?
    func present(_ payload: TransferCompletionNotificationPayload) { self.payload = payload }
    func dismiss(jobID: String) { }
    func dismiss(runtimeID: String) { }
    func dismissAll() { }
}

@MainActor
private final class CheckpointRateClock {
    var now = Date(timeIntervalSince1970: 100)
}

@MainActor
private final class CheckpointRateFixture {
    enum Transport: CaseIterable { case external, scp, sftp }
    let clock = CheckpointRateClock()
    let bridge = CheckpointRateBridge()
    let files = FilesViewController()
    let queue = TransferQueueViewController()
    let popover = TransferQueuePopoverViewController()
    let coordinator: TransferQueueCoordinator
    let job: ScpTransferJob
    private static func job(bytesTotal: UInt64) -> ScpTransferJob { ScpTransferJob(id: "checkpoint-rate-\(UUID().uuidString)", direction: .upload, sourcePath: "/source.bin", destinationPath: "/destination.bin", bytesTotal: bytesTotal) }
    var latest: TransferQueueSnapshot.Row?

    let presenter = CheckpointRatePresenter()

    init(transport: Transport, history: SCPTransferHistoryStoring = NoOpSCPTransferHistoryStore(), bytesTotal: UInt64 = 16 * 1_073_741_824) {
        job = Self.job(bytesTotal: bytesTotal)
        coordinator = TransferQueueCoordinator(
            bridge: bridge, sftpBridge: bridge, historyStore: history, completionNotificationPresenter: presenter,
            queueViewController: queue, nowProvider: { [clock] in clock.now },
            monotonicTimeProvider: { [clock] in clock.now.timeIntervalSince1970 }
        )
        files.loadView(); queue.loadView(); popover.loadView()
        files.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        coordinator.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            self.latest = snapshot.rows.first
            self.files.setTransferStatusSnapshot(snapshot)
            self.popover.apply(snapshot: snapshot)
        }
        let config = SshConnectionConfig(host: "fixture", port: 22, username: "fixture", authMethod: .agent, connectTimeoutMs: 1_000)
        switch transport {
        case .external:
            coordinator.registerExternalTransfer(
                runtimeID: "fixture", job: job, notificationPolicy: .userVisible, progressProvider: { [bridge] in bridge.takeLiveSCPTransferProgressBatch(jobID: "unused") },
                resume: { [bridge] in bridge.startProgress(); return true },
                cancel: { [bridge, job] in bridge.cancelLiveSCPTransfer(jobID: job.id) },
                pauseWithProgress: { [bridge, job] in bridge.pauseWithProgress(jobID: job.id) }
            )
        case .scp:
            coordinator.scheduleLiveTransfer(config: config, secret: .agent, expectedFingerprintSHA256: "fixture", job: job)
        case .sftp:
            coordinator.scheduleLiveSFTPTransfer(runtimeID: "fixture", config: config, secret: .agent, expectedFingerprintSHA256: "fixture", job: job)
        }
    }

    func publish(_ values: [(UInt64, String)]) {
        bridge.publish(values.map { .init(jobId: job.id, bytesDone: $0.0, bytesTotal: job.bytesTotal, status: $0.1) })
        coordinator.pollScheduledTransferProgressForTesting()
    }
    func stop() { _ = coordinator.cancelTransfer(jobID: job.id); bridge.release(); bridge.release() }
    var fileStatus: String {
        descendants(files.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "Stacio.Files.transferStatus" }?.stringValue ?? ""
    }
    var metricTexts: [String] { [fileStatus, queue.visibleTextSnapshot, popover.rowsForTesting.first?.speedText ?? ""] }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
}

private final class CheckpointRateBridge: SCPTransferBridging, SFTPTransferBridging, TransferPauseReporting, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var starts = 0
    private var cancelled = false
    private var events: [ScpTransferProgress] = []
    var startedCount: Int { locked { starts } }
    func release() { gate.signal() }
    func startProgress() { locked { cancelled = false; events = [] } }
    func publish(_ progress: [ScpTransferProgress]) { locked { if !cancelled { events += progress } } }
    func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        locked { let result = events; events = []; return result }
    }
    func pauseWithProgress(jobID: String) -> [ScpTransferProgress]? {
        locked {
            guard !cancelled else { return nil }
            cancelled = true
            defer { events = [] }
            return events
        }
    }
    func cancelLiveSCPTransfer(jobID: String) -> Bool { locked { cancelled = true; events = [] }; return true }
    func cancelLiveSFTPTransfer(jobID: String) -> Bool { cancelLiveSCPTransfer(jobID: jobID) }
    func runLiveSCPTransfer(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, job: ScpTransferJob) throws -> [ScpTransferProgress] { run(job) }
    func runLiveSFTPTransfer(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, job: ScpTransferJob) throws -> [ScpTransferProgress] { run(job) }
    private func run(_ job: ScpTransferJob) -> [ScpTransferProgress] {
        locked { starts += 1; cancelled = false; events = [] }
        _ = gate.wait(timeout: .now() + 10)
        return [.init(jobId: job.id, bytesDone: job.bytesTotal, bytesTotal: job.bytesTotal, status: "completed")]
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
