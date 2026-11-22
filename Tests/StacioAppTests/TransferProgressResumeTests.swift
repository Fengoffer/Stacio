import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class TransferProgressResumeTests: XCTestCase {
    func testRemoteResumeAcceptsRunningCheckpointThenRejectsBackwardSamples() async {
        let feed = ResumeProgressFeed()
        let (coordinator, job, snapshots) = externalFixture(feed: feed)
        defer { _ = coordinator.cancelTransfer(jobID: job.id) }
        feed.publish(job.id, [(40, "running")])
        await waitUntil { snapshots.last?.bytesDone == 40 }
        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        // Direct remote transfers use requestedOffset 0 and publish the verified
        // checkpoint as running, even when partial ranges must be retransmitted.
        feed.publish(job.id, [(0, "running"), (10, "running")])
        await waitUntil { snapshots.last?.bytesDone == 10 }
        feed.publish(job.id, [(5, "running"), (20, "running")])
        await waitUntil { snapshots.last?.bytesDone == 20 }
        XCTAssertFalse(snapshots.rows.contains { $0.bytesDone == 5 })
    }

    func testOldPollCannotOverwriteResumedProgress() async {
        let feed = ResumeProgressFeed()
        let (coordinator, job, snapshots) = externalFixture(feed: feed)
        defer { feed.releasePoll(); _ = coordinator.cancelTransfer(jobID: job.id) }
        feed.publish(job.id, [(40, "running")])
        await waitUntil { snapshots.last?.bytesDone == 40 }
        feed.blockNextPoll(captureBeforeWaiting: true)
        feed.publish(job.id, [(45, "running")])
        coordinator.pollScheduledTransferProgressForTesting()
        await waitUntil { feed.pollIsBlocked }
        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        feed.publish(job.id, [(0, "resuming"), (10, "running")])
        feed.releasePoll()
        await waitUntil { snapshots.last?.bytesDone == 10 }
        XCTAssertFalse(snapshots.rows.contains { $0.bytesDone == 45 }, "A retired poll must not supply the new run's baseline")
        XCTAssertEqual(feed.maximumConcurrentPolls, 1)
    }

    func testResumeStillRebasesWhenRetiredPollDrainsNewCheckpoint() async {
        let feed = ResumeProgressFeed()
        let (coordinator, job, snapshots) = externalFixture(feed: feed)
        defer { feed.releasePoll(); _ = coordinator.cancelTransfer(jobID: job.id) }
        feed.publish(job.id, [(40, "running")])
        await waitUntil { snapshots.last?.bytesDone == 40 }
        // The old poll has started but has not read the queue yet.
        feed.blockNextPoll(captureBeforeWaiting: false)
        coordinator.pollScheduledTransferProgressForTesting()
        await waitUntil { feed.pollIsBlocked }
        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        feed.publish(job.id, [(0, "resuming"), (10, "running")])
        feed.releasePoll()
        await waitUntil { feed.didFinishBlockedPoll }
        // Allow the retired result to reach MainActor before the next sample.
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(snapshots.last?.bytesDone, 40)
        feed.publish(job.id, [(20, "running")])
        await waitUntil { snapshots.last?.bytesDone == 20 }
        XCTAssertEqual(feed.maximumConcurrentPolls, 1)
    }

    func testScheduledResumeRebasesAfterPreviousWorkerDrains() async {
        let bridge = ResumeTransferBridge()
        let queue = TransferQueueViewController(); queue.loadView()
        let coordinator = TransferQueueCoordinator(bridge: bridge, queueViewController: queue)
        let job = makeJob()
        let snapshots = ResumeSnapshots()
        coordinator.onSnapshotChanged = { snapshots.rows.append(contentsOf: $0.rows) }
        defer { _ = coordinator.cancelTransfer(jobID: job.id); bridge.release(); bridge.release() }
        coordinator.scheduleLiveTransfer(
            config: .init(host: "fixture", port: 22, username: "fixture", authMethod: .agent, connectTimeoutMs: 1000),
            secret: .agent, expectedFingerprintSHA256: "fixture", job: job
        )
        await waitUntil { bridge.startedCount == 1 }
        bridge.feed.publish(job.id, [(40, "running")])
        await waitUntil { snapshots.last?.bytesDone == 40 }
        XCTAssertTrue(coordinator.pauseTransfer(jobID: job.id))
        XCTAssertTrue(coordinator.resumeTransfer(jobID: job.id))
        // The core ignores this late write while cancellation is active.
        bridge.feed.publish(job.id, [(45, "running")])
        bridge.release()
        await waitUntil { bridge.startedCount == 2 }
        bridge.feed.publish(job.id, [(0, "resuming"), (10, "running")])
        await waitUntil { snapshots.last?.bytesDone == 10 }
        XCTAssertFalse(snapshots.rows.contains { $0.bytesDone == 45 })
        bridge.release()
        await waitUntil { snapshots.last?.rawStatus == "completed" }
    }

    private func externalFixture(feed: ResumeProgressFeed) -> (TransferQueueCoordinator, ScpTransferJob, ResumeSnapshots) {
        let queue = TransferQueueViewController(); queue.loadView()
        let coordinator = TransferQueueCoordinator(queueViewController: queue)
        let job = makeJob()
        let snapshots = ResumeSnapshots()
        coordinator.onSnapshotChanged = { snapshots.rows.append(contentsOf: $0.rows) }
        coordinator.registerExternalTransfer(
            runtimeID: "fixture", job: job, progressProvider: { feed.take() },
            pause: { feed.pause(); return true }, resume: { feed.startRun(); return true }, cancel: { feed.pause(); return true }
        )
        return (coordinator, job, snapshots)
    }

    private func makeJob() -> ScpTransferJob {
        ScpTransferJob(id: "resume-\(UUID().uuidString)", direction: .upload, sourcePath: "/source", destinationPath: "/dest", bytesTotal: 100)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class ResumeSnapshots {
    var rows: [TransferQueueSnapshot.Row] = []
    var last: TransferQueueSnapshot.Row? { rows.last }
}

private final class ResumeProgressFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let pollGate = DispatchSemaphore(value: 0)
    private var events: [ScpTransferProgress] = []
    private var cancelled = false
    private var blockNext: Bool?
    private var blocked = false
    private var finishedBlockedPoll = false
    private var activePolls = 0
    private var maxPolls = 0
    var pollIsBlocked: Bool { locked { blocked } }
    var didFinishBlockedPoll: Bool { locked { finishedBlockedPoll } }
    var maximumConcurrentPolls: Int { locked { maxPolls } }
    func pause() { locked { cancelled = true; events = [] } }
    func startRun() { locked { cancelled = false; events = [] } }
    func publish(_ id: String, _ values: [(UInt64, String)]) {
        locked {
            guard !cancelled else { return }
            events += values.map { .init(jobId: id, bytesDone: $0.0, bytesTotal: 100, status: $0.1) }
        }
    }
    func blockNextPoll(captureBeforeWaiting: Bool) { locked { blockNext = captureBeforeWaiting } }
    func releasePoll() { pollGate.signal() }
    func take() -> [ScpTransferProgress] {
        let mode = locked { () -> Bool? in
            activePolls += 1; maxPolls = max(maxPolls, activePolls)
            let mode = blockNext; blockNext = nil; blocked = mode != nil
            return mode
        }
        defer { locked { activePolls -= 1 } }
        let captured = mode == true ? drain() : []
        if mode != nil { _ = pollGate.wait(timeout: .now() + 5) }
        let result = mode == true ? captured : drain()
        if mode != nil { locked { blocked = false; finishedBlockedPoll = true } }
        return result
    }
    private func drain() -> [ScpTransferProgress] { locked { let result = events; events = []; return result } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private final class ResumeTransferBridge: SCPTransferBridging {
    let feed = ResumeProgressFeed()
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    func release() { gate.signal() }
    func runLiveSCPTransfer(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, job: ScpTransferJob) throws -> [ScpTransferProgress] {
        feed.startRun()
        lock.lock(); starts += 1; lock.unlock()
        _ = gate.wait(timeout: .now() + 10)
        return [.init(jobId: job.id, bytesDone: 100, bytesTotal: 100, status: "completed")]
    }
    func cancelLiveSCPTransfer(jobID: String) -> Bool { feed.pause(); return true }
    func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress] { feed.take() }
}
