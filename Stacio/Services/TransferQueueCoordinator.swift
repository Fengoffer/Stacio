import Foundation
import StacioCoreBindings

public protocol SCPTransferBridging {
    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress]
    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress]
    func cancelLiveSCPTransfer(jobID: String) -> Bool
    func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress]
}

public extension SCPTransferBridging {
    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        try runLiveSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    func cancelLiveSCPTransfer(jobID: String) -> Bool {
        false
    }

    func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        []
    }
}

public final class CoreBridgeSCPTransferBridge: SCPTransferBridging {
    public init() {}

    public func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try CoreBridge.runLiveSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    public func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        try CoreBridge.runLiveSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions
        )
    }

    public func cancelLiveSCPTransfer(jobID: String) -> Bool {
        (try? CoreBridge.cancelLiveSCPTransfer(jobID: jobID)) ?? false
    }

    public func takeLiveSCPTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        (try? CoreBridge.takeLiveSCPTransferProgressBatch(jobID: jobID)) ?? []
    }
}

public protocol FTPTransferBridging {
    func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress]
    func cancelLiveFTPTransfer(jobID: String) -> Bool
}

public extension FTPTransferBridging {
    func cancelLiveFTPTransfer(jobID: String) -> Bool {
        false
    }
}

public final class CoreBridgeFTPTransferBridge: FTPTransferBridging {
    public init() {}

    public func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try CoreBridge.runLiveFTPTransfer(
            config: config,
            secret: secret,
            job: job
        )
    }

    public func cancelLiveFTPTransfer(jobID: String) -> Bool {
        (try? CoreBridge.cancelLiveFTPTransfer(jobID: jobID)) ?? false
    }
}

public protocol SCPTransferHistoryStoring {
    func recordJob(sessionID: String?, job: ScpTransferJob, status: String, bytesDone: UInt64) throws
    func appendProgress(_ progress: ScpTransferProgress) throws -> ScpTransferEventRecord
    func appendProgress(_ progress: ScpTransferProgress, message: String?) throws -> ScpTransferEventRecord
    func listJobs() throws -> [ScpTransferJobRecord]
    func listEvents(jobID: String) throws -> [ScpTransferEventRecord]
    func clearFinishedJobs() throws -> UInt32
}

public struct TransferQueueSnapshot: Equatable {
    public struct Row: Equatable {
        public let jobID: String
        public let direction: ScpDirection
        public let sourcePath: String
        public let destinationPath: String
        public let bytesDone: UInt64
        public let bytesTotal: UInt64
        public let rawStatus: String
        public let diagnostic: String?

        public init(
            jobID: String,
            direction: ScpDirection,
            sourcePath: String,
            destinationPath: String,
            bytesDone: UInt64,
            bytesTotal: UInt64,
            rawStatus: String,
            diagnostic: String?
        ) {
            self.jobID = jobID
            self.direction = direction
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.rawStatus = rawStatus
            self.diagnostic = diagnostic
        }
    }

    public let rows: [Row]
    public let capturedAt: Date

    public init(rows: [Row], capturedAt: Date = Date()) {
        self.rows = rows
        self.capturedAt = capturedAt
    }
}

public final class NoOpSCPTransferHistoryStore: SCPTransferHistoryStoring {
    public init() {}

    public func recordJob(sessionID: String?, job: ScpTransferJob, status: String, bytesDone: UInt64) throws {}

    public func appendProgress(_ progress: ScpTransferProgress) throws -> ScpTransferEventRecord {
        try appendProgress(progress, message: nil)
    }

    public func appendProgress(_ progress: ScpTransferProgress, message: String?) throws -> ScpTransferEventRecord {
        ScpTransferEventRecord(
            id: "",
            jobId: progress.jobId,
            eventType: progress.status,
            message: message,
            bytesDone: progress.bytesDone,
            createdAt: ""
        )
    }

    public func listJobs() throws -> [ScpTransferJobRecord] {
        []
    }

    public func listEvents(jobID: String) throws -> [ScpTransferEventRecord] {
        []
    }

    public func clearFinishedJobs() throws -> UInt32 {
        0
    }
}

public final class CoreBridgeSCPTransferHistoryStore: SCPTransferHistoryStoring {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func recordJob(sessionID: String?, job: ScpTransferJob, status: String, bytesDone: UInt64) throws {
        try CoreBridge.recordSCPTransferJob(
            databasePath: databasePath,
            sessionID: sessionID,
            job: job,
            status: status,
            bytesDone: bytesDone
        )
    }

    public func appendProgress(_ progress: ScpTransferProgress) throws -> ScpTransferEventRecord {
        try appendProgress(progress, message: nil)
    }

    public func appendProgress(_ progress: ScpTransferProgress, message: String?) throws -> ScpTransferEventRecord {
        if let message {
            return try CoreBridge.appendSCPTransferProgress(
                databasePath: databasePath,
                progress: progress,
                message: message
            )
        }
        return try CoreBridge.appendSCPTransferProgress(databasePath: databasePath, progress: progress)
    }

    public func listJobs() throws -> [ScpTransferJobRecord] {
        try CoreBridge.listSCPTransferJobs(databasePath: databasePath)
    }

    public func listEvents(jobID: String) throws -> [ScpTransferEventRecord] {
        try CoreBridge.listSCPTransferEvents(databasePath: databasePath, jobID: jobID)
    }

    public func clearFinishedJobs() throws -> UInt32 {
        try CoreBridge.clearFinishedSCPTransferJobs(databasePath: databasePath)
    }
}

@MainActor
public final class TransferQueueCoordinator {
    public var onRetryRequested: ((String) -> Void)?
    public var onSnapshotChanged: ((TransferQueueSnapshot) -> Void)?

    private let bridge: SCPTransferBridging
    private let ftpBridge: FTPTransferBridging
    private let historyStore: SCPTransferHistoryStoring
    private let completionNotificationPresenter: TransferCompletionNotificationPresenting
    private weak var queueViewController: TransferQueueViewController?
    private var orderedJobIDs: [String] = []
    private var jobsByID: [String: ScpTransferJob] = [:]
    private var progressByJobID: [String: [ScpTransferProgress]] = [:]
    private var estimatedBytesTotalByJobID: [String: UInt64] = [:]
    private var diagnosticsByJobID: [String: String] = [:]
    private var eventLogsByJobID: [String: [TransferEventLogEntry]] = [:]
    private var scheduledTransfersByJobID: [String: ScheduledSCPTransfer] = [:]
    private var scheduledFTPTransfersByJobID: [String: ScheduledFTPTransfer] = [:]
    private var retryableTransfersByJobID: [String: ScheduledSCPTransfer] = [:]
    private var retryableFTPTransfersByJobID: [String: ScheduledFTPTransfer] = [:]
    private var completionByJobID: [String: (ScpTransferProgress) -> Void] = [:]
    private var queuedScheduledJobIDs: [String] = []
    private var runningJobIDs: [String] = []
    private var runningSCPJobIDs = Set<String>()
    private var canceledJobIDs = Set<String>()
    private var pausedJobIDs = Set<String>()
    private var stoppedJobIDs = Set<String>()
    private var runTokensByJobID: [String: UUID] = [:]
    private var drainingRunTokensByJobID: [String: UUID] = [:]
    private var pendingRequeueByJobID: [String: PendingTransferRequeue] = [:]
    private var runtimeIDByJobID: [String: String] = [:]
    private var priorRuntimeIDsByCurrentRuntimeID: [String: Set<String>] = [:]
    private var progressPollTimer: Timer?
    private var progressPollInFlight = false
    private let maxConcurrentTransfers: Int
    private let nowProvider: () -> Date
    private let monotonicTimeProvider: () -> TimeInterval
    private var timingByJobID: [String: TransferTimingState] = [:]
    private var terminalObservationByJobID: [String: TransferTerminalObservation] = [:]

    var maxConcurrentTransfersForTesting: Int {
        maxConcurrentTransfers
    }

    public init(
        bridge: SCPTransferBridging = CoreBridgeSCPTransferBridge(),
        ftpBridge: FTPTransferBridging = CoreBridgeFTPTransferBridge(),
        historyStore: SCPTransferHistoryStoring = NoOpSCPTransferHistoryStore(),
        completionNotificationPresenter: TransferCompletionNotificationPresenting? = nil,
        queueViewController: TransferQueueViewController,
        maxConcurrentTransfers: Int = 2,
        nowProvider: @escaping () -> Date = Date.init,
        monotonicTimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.bridge = bridge
        self.ftpBridge = ftpBridge
        self.historyStore = historyStore
        self.completionNotificationPresenter = completionNotificationPresenter
            ?? NoopTransferCompletionNotificationPresenter()
        self.queueViewController = queueViewController
        self.maxConcurrentTransfers = max(1, maxConcurrentTransfers)
        self.nowProvider = nowProvider
        self.monotonicTimeProvider = monotonicTimeProvider
        queueViewController.onTransferAction = { [weak self] action, jobID in
            switch action {
            case .retry:
                if self?.retryFailedTransfer(jobID: jobID) != true {
                    self?.onRetryRequested?(jobID)
                }
            case .pause:
                _ = self?.pauseTransfer(jobID: jobID)
            case .resume:
                _ = self?.resumeTransfer(jobID: jobID)
            case .restart:
                _ = self?.restartTransfer(jobID: jobID)
            case .stop:
                _ = self?.stopTransfer(jobID: jobID)
            }
        }
        queueViewController.onClearFinished = { [weak self] in
            _ = self?.clearFinishedTransfers()
        }
    }

    deinit {
        progressPollTimer?.invalidate()
    }

    public func enqueueTransfer(job: ScpTransferJob) {
        enqueueTransfer(runtimeID: nil, job: job)
    }

    public func enqueueTransfer(runtimeID: String, job: ScpTransferJob) {
        enqueueTransfer(runtimeID: Optional(runtimeID), job: job)
    }

    private func enqueueTransfer(runtimeID: String?, job: ScpTransferJob) {
        record(job: job)
        timingByJobID[job.id] = TransferTimingState()
        terminalObservationByJobID[job.id] = nil
        pendingRequeueByJobID[job.id] = nil
        if let runtimeID {
            runtimeIDByJobID[job.id] = runtimeID
        }
        let queued = ScpTransferProgress(
            jobId: job.id,
            bytesDone: 0,
            bytesTotal: job.bytesTotal,
            status: "queued"
        )
        progressByJobID[job.id] = [queued]
        diagnosticsByJobID[job.id] = Self.largeFileTransferWarning(for: job)
        try? historyStore.recordJob(sessionID: nil, job: job, status: queued.status, bytesDone: queued.bytesDone)
        refreshQueueView()
    }

    public func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        guard !isActiveScheduledTransfer(jobID: job.id) else {
            return
        }
        enqueueTransfer(runtimeID: runtimeID, job: job)
        scheduledTransfersByJobID[job.id] = ScheduledSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions(requestedOffset: 0, forceRestart: false)
        )
        retryableTransfersByJobID[job.id] = scheduledTransfersByJobID[job.id]
        completionByJobID[job.id] = completion
        queuedScheduledJobIDs.append(job.id)
        refreshQueueView()
        startNextScheduledTransferIfNeeded()
    }

    public func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        scheduleLiveTransfer(
            runtimeID: config.host,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: completion
        )
    }

    public func scheduleLiveFTPTransfer(
        runtimeID: String,
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        guard !isActiveScheduledTransfer(jobID: job.id) else {
            return
        }
        enqueueTransfer(runtimeID: runtimeID, job: job)
        scheduledFTPTransfersByJobID[job.id] = ScheduledFTPTransfer(
            config: config,
            secret: secret,
            job: job
        )
        retryableFTPTransfersByJobID[job.id] = scheduledFTPTransfersByJobID[job.id]
        completionByJobID[job.id] = completion
        queuedScheduledJobIDs.append(job.id)
        refreshQueueView()
        startNextScheduledTransferIfNeeded()
    }

    public func scheduleLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        scheduleLiveFTPTransfer(
            runtimeID: "ftp://\(config.username)@\(config.host):\(config.port)",
            config: config,
            secret: secret,
            job: job,
            completion: completion
        )
    }

    @discardableResult
    public func disconnectTransfers(runtimeID: String) -> [String] {
        dismissTransferNotifications(runtimeID: runtimeID, removesRuntimeAliases: true)
        let jobIDs = orderedJobIDs.filter { runtimeIDByJobID[$0] == runtimeID }
        guard jobIDs.isEmpty == false else {
            return []
        }
        for jobID in jobIDs {
            moveActiveWorkerToDrainingState(jobID: jobID)
            removeTransfer(jobID: jobID)
        }
        refreshQueueView()
        stopProgressPollingIfIdle()
        startNextScheduledTransferIfNeeded()
        return jobIDs
    }

    public func reattachTransfers(oldRuntimeID: String, runtimeID: String) {
        guard oldRuntimeID.isEmpty == false,
              runtimeID.isEmpty == false,
              oldRuntimeID != runtimeID
        else { return }

        let matchingJobIDs = runtimeIDByJobID.compactMap { jobID, associatedRuntimeID in
            associatedRuntimeID == oldRuntimeID ? jobID : nil
        }
        for jobID in matchingJobIDs {
            runtimeIDByJobID[jobID] = runtimeID
        }

        var priorRuntimeIDs = priorRuntimeIDsByCurrentRuntimeID.removeValue(forKey: oldRuntimeID) ?? []
        priorRuntimeIDs.insert(oldRuntimeID)
        if let existingAliases = priorRuntimeIDsByCurrentRuntimeID.removeValue(forKey: runtimeID) {
            priorRuntimeIDs.formUnion(existingAliases)
        }
        priorRuntimeIDs.remove(runtimeID)
        if priorRuntimeIDs.isEmpty == false {
            priorRuntimeIDsByCurrentRuntimeID[runtimeID] = priorRuntimeIDs
        }
    }

    public func dismissTransferNotifications(runtimeID: String) {
        dismissTransferNotifications(runtimeID: runtimeID, removesRuntimeAliases: true)
    }

    private func dismissTransferNotifications(runtimeID: String, removesRuntimeAliases: Bool) {
        completionNotificationPresenter.dismiss(runtimeID: runtimeID)
        let priorRuntimeIDs = priorRuntimeIDsByCurrentRuntimeID[runtimeID] ?? []
        for priorRuntimeID in priorRuntimeIDs.sorted() {
            completionNotificationPresenter.dismiss(runtimeID: priorRuntimeID)
        }
        if removesRuntimeAliases {
            priorRuntimeIDsByCurrentRuntimeID[runtimeID] = nil
        }
    }

    public func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {
        guard bytesTotal > 0,
              jobsByID[jobID] != nil
        else {
            return
        }
        let latestTotal = progressByJobID[jobID]?.last?.bytesTotal ?? 0
        guard latestTotal == 0 else {
            return
        }
        estimatedBytesTotalByJobID[jobID] = bytesTotal
        refreshQueueView()
    }

    @discardableResult
    public func cancelTransfer(jobID: String) -> Bool {
        markTransferInterrupted(jobID: jobID, status: "canceled", keepsRetryableTransfer: false)
    }

    @discardableResult
    public func pauseTransfer(jobID: String) -> Bool {
        markTransferInterrupted(jobID: jobID, status: "paused", keepsRetryableTransfer: true)
    }

    @discardableResult
    public func resumeTransfer(jobID: String) -> Bool {
        guard progressByJobID[jobID]?.last?.status == "paused" else {
            return false
        }
        return requeueRetryableTransfer(jobID: jobID, bytesDone: progressByJobID[jobID]?.last?.bytesDone ?? 0)
    }

    @discardableResult
    public func restartTransfer(jobID: String) -> Bool {
        guard let status = progressByJobID[jobID]?.last?.status,
              status == "paused" || Self.retryableStatuses.contains(status)
        else {
            return false
        }
        return requeueRetryableTransfer(jobID: jobID, bytesDone: 0, forceRestart: true)
    }

    @discardableResult
    public func stopTransfer(jobID: String) -> Bool {
        markTransferInterrupted(jobID: jobID, status: "stopped", keepsRetryableTransfer: true)
    }

    @discardableResult
    public func runLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        enqueueTransfer(runtimeID: config.host, job: job)
        beginTransferTiming(jobID: job.id)
        do {
            let progress = try bridge.runLiveSCPTransfer(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                job: job
            )
            let acceptedProgress = acceptedCompletionProgress(jobID: job.id, job: job, progress: progress)
            progressByJobID[job.id] = acceptedProgress.events
            diagnosticsByJobID[job.id] = acceptedProgress.diagnostic
            persistProgress(acceptedProgress.events, message: acceptedProgress.diagnostic)
            presentCompletionNotificationIfNeeded(jobID: job.id, progress: acceptedProgress.events.last)
            refreshQueueView()
            return acceptedProgress.events
        } catch {
            let failed = ScpTransferProgress(
                jobId: job.id,
                bytesDone: 0,
                bytesTotal: job.bytesTotal,
                status: "failed"
            )
            progressByJobID[job.id] = [failed]
            let diagnostic = diagnosticMessage(for: error)
            diagnosticsByJobID[job.id] = diagnostic
            _ = try? historyStore.appendProgress(failed, message: diagnostic)
            presentCompletionNotificationIfNeeded(jobID: job.id, progress: failed)
            refreshQueueView()
            throw error
        }
    }

    @discardableResult
    public func runLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        enqueueTransfer(runtimeID: "ftp://\(config.username)@\(config.host):\(config.port)", job: job)
        beginTransferTiming(jobID: job.id)
        do {
            let progress = try ftpBridge.runLiveFTPTransfer(
                config: config,
                secret: secret,
                job: job
            )
            let acceptedProgress = acceptedCompletionProgress(jobID: job.id, job: job, progress: progress)
            progressByJobID[job.id] = acceptedProgress.events
            diagnosticsByJobID[job.id] = acceptedProgress.diagnostic
            persistProgress(acceptedProgress.events, message: acceptedProgress.diagnostic)
            presentCompletionNotificationIfNeeded(jobID: job.id, progress: acceptedProgress.events.last)
            refreshQueueView()
            return acceptedProgress.events
        } catch {
            let failed = ScpTransferProgress(
                jobId: job.id,
                bytesDone: 0,
                bytesTotal: job.bytesTotal,
                status: "failed"
            )
            progressByJobID[job.id] = [failed]
            let diagnostic = diagnosticMessage(for: error)
            diagnosticsByJobID[job.id] = diagnostic
            _ = try? historyStore.appendProgress(failed, message: diagnostic)
            presentCompletionNotificationIfNeeded(jobID: job.id, progress: failed)
            refreshQueueView()
            throw error
        }
    }

    @discardableResult
    public func retryLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try runLiveTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    public func restoreHistory() throws {
        let records = Self.restorableHistoryRecords(from: try historyStore.listJobs())
        orderedJobIDs = []
        jobsByID = [:]
        progressByJobID = [:]
        estimatedBytesTotalByJobID = [:]
        diagnosticsByJobID = [:]
        eventLogsByJobID = [:]
        scheduledTransfersByJobID = [:]
        scheduledFTPTransfersByJobID = [:]
        retryableTransfersByJobID = [:]
        retryableFTPTransfersByJobID = [:]
        completionByJobID = [:]
        queuedScheduledJobIDs = []
        runningJobIDs = []
        runningSCPJobIDs = []
        pausedJobIDs = []
        stoppedJobIDs = []
        canceledJobIDs = []
        runTokensByJobID = [:]
        drainingRunTokensByJobID = [:]
        pendingRequeueByJobID = [:]
        runtimeIDByJobID = [:]
        priorRuntimeIDsByCurrentRuntimeID = [:]
        timingByJobID = [:]
        terminalObservationByJobID = [:]
        progressPollTimer?.invalidate()
        progressPollTimer = nil
        progressPollInFlight = false

        for jobRecord in records {
            record(job: jobRecord.job)
            let events = try historyStore.listEvents(jobID: jobRecord.job.id)
            diagnosticsByJobID[jobRecord.job.id] = events.reversed().first { event in
                event.message?.isEmpty == false
            }?.message.map(RuntimeDiagnosticFormatter.userMessage)
            eventLogsByJobID[jobRecord.job.id] = events.map { event in
                TransferEventLogEntry(
                    status: event.eventType,
                    bytesDone: event.bytesDone ?? jobRecord.bytesDone,
                    bytesTotal: jobRecord.job.bytesTotal,
                    message: event.message,
                    createdAt: event.createdAt
                )
            }
            progressByJobID[jobRecord.job.id] = events.map { event in
                ScpTransferProgress(
                    jobId: event.jobId,
                    bytesDone: event.bytesDone ?? jobRecord.bytesDone,
                    bytesTotal: jobRecord.job.bytesTotal,
                    status: event.eventType
                )
            }
            if progressByJobID[jobRecord.job.id]?.isEmpty != false {
                progressByJobID[jobRecord.job.id] = [
                    ScpTransferProgress(
                        jobId: jobRecord.job.id,
                        bytesDone: jobRecord.bytesDone,
                        bytesTotal: jobRecord.job.bytesTotal,
                        status: jobRecord.status
                    )
                ]
            }
        }

        refreshQueueView()
    }

    private static func restorableHistoryRecords(from records: [ScpTransferJobRecord]) -> [ScpTransferJobRecord] {
        let completedIDs = Set(
            records
                .filter { $0.status == "completed" }
                .suffix(maxCompletedHistoryRows)
                .map(\.job.id)
        )
        return records.filter { record in
            record.status != "completed" || completedIDs.contains(record.job.id)
        }
    }

    public func pollScheduledTransferProgressForTesting() {
        pollRunningTransferProgressOnce()
    }

    @discardableResult
    public func clearFinishedTransfers() -> Int {
        let finishedJobIDs = orderedJobIDs.filter { jobID in
            guard let status = progressByJobID[jobID]?.last?.status else {
                return false
            }
            return Self.finishedStatuses.contains(status)
        }
        guard !finishedJobIDs.isEmpty else {
            return 0
        }

        let finished = Set(finishedJobIDs)
        _ = try? historyStore.clearFinishedJobs()
        orderedJobIDs.removeAll { finished.contains($0) }
        for jobID in finished {
            moveActiveWorkerToDrainingState(jobID: jobID)
            jobsByID[jobID] = nil
            progressByJobID[jobID] = nil
            estimatedBytesTotalByJobID[jobID] = nil
            diagnosticsByJobID[jobID] = nil
            eventLogsByJobID[jobID] = nil
            scheduledTransfersByJobID[jobID] = nil
            scheduledFTPTransfersByJobID[jobID] = nil
            retryableTransfersByJobID[jobID] = nil
            retryableFTPTransfersByJobID[jobID] = nil
            completionByJobID[jobID] = nil
            runningSCPJobIDs.remove(jobID)
            canceledJobIDs.remove(jobID)
            pausedJobIDs.remove(jobID)
            stoppedJobIDs.remove(jobID)
            runTokensByJobID[jobID] = nil
            pendingRequeueByJobID[jobID] = nil
            runtimeIDByJobID[jobID] = nil
            timingByJobID[jobID] = nil
            terminalObservationByJobID[jobID] = nil
        }
        queuedScheduledJobIDs.removeAll { finished.contains($0) }
        runningJobIDs.removeAll { finished.contains($0) }
        refreshQueueView()
        stopProgressPollingIfIdle()
        startNextScheduledTransferIfNeeded()
        return finished.count
    }

    public func replaceProgressForTesting(jobID: String, status: String, bytesDone: UInt64) {
        guard let job = jobsByID[jobID] else {
            return
        }
        progressByJobID[jobID] = [
            ScpTransferProgress(
                jobId: jobID,
                bytesDone: bytesDone,
                bytesTotal: job.bytesTotal,
                status: status
            )
        ]
        refreshQueueView()
    }

    @discardableResult
    public func retryFailedTransfer(jobID: String) -> Bool {
        guard let status = progressByJobID[jobID]?.last?.status,
              Self.retryableStatuses.contains(status)
        else {
            return false
        }

        return requeueRetryableTransfer(jobID: jobID, bytesDone: progressByJobID[jobID]?.last?.bytesDone ?? 0)
    }

    @discardableResult
    private func requeueRetryableTransfer(
        jobID: String,
        bytesDone: UInt64,
        forceRestart: Bool = false
    ) -> Bool {
        guard retryableTransfersByJobID[jobID] != nil || retryableFTPTransfersByJobID[jobID] != nil else {
            return false
        }
        if runTokensByJobID[jobID] != nil {
            pendingRequeueByJobID[jobID] = PendingTransferRequeue(
                bytesDone: bytesDone,
                forceRestart: forceRestart
            )
            return true
        }

        pendingRequeueByJobID[jobID] = nil
        terminalObservationByJobID[jobID] = nil
        if forceRestart {
            timingByJobID[jobID] = TransferTimingState()
        }
        if let retryableTransfer = retryableTransfersByJobID[jobID] {
            scheduledTransfersByJobID[jobID] = retryableTransfer.withResumeOptions(
                resumeOptions(requestedOffset: bytesDone, forceRestart: forceRestart)
            )
            retryableFTPTransfersByJobID[jobID] = nil
            diagnosticsByJobID[jobID] = nil
            canceledJobIDs.remove(jobID)
            pausedJobIDs.remove(jobID)
            stoppedJobIDs.remove(jobID)
            let queued = ScpTransferProgress(
                jobId: jobID,
                bytesDone: bytesDone,
                bytesTotal: retryableTransfer.job.bytesTotal,
                status: "queued"
            )
            progressByJobID[jobID] = [queued]
            _ = try? historyStore.appendProgress(queued)
            if !queuedScheduledJobIDs.contains(jobID),
               !runningJobIDs.contains(jobID)
            {
                queuedScheduledJobIDs.append(jobID)
            }
            refreshQueueView()
            startNextScheduledTransferIfNeeded()
            return true
        }

        if let retryableTransfer = retryableFTPTransfersByJobID[jobID] {
            scheduledFTPTransfersByJobID[jobID] = retryableTransfer
            retryableTransfersByJobID[jobID] = nil
            diagnosticsByJobID[jobID] = nil
            canceledJobIDs.remove(jobID)
            pausedJobIDs.remove(jobID)
            stoppedJobIDs.remove(jobID)
            let queued = ScpTransferProgress(
                jobId: jobID,
                bytesDone: bytesDone,
                bytesTotal: retryableTransfer.job.bytesTotal,
                status: "queued"
            )
            progressByJobID[jobID] = [queued]
            _ = try? historyStore.appendProgress(queued)
            if !queuedScheduledJobIDs.contains(jobID),
               !runningJobIDs.contains(jobID)
            {
                queuedScheduledJobIDs.append(jobID)
            }
            refreshQueueView()
            startNextScheduledTransferIfNeeded()
            return true
        }

        return false
    }

    private func startNextScheduledTransferIfNeeded() {
        guard activeWorkerCount < maxConcurrentTransfers else {
            return
        }

        while activeWorkerCount < maxConcurrentTransfers,
              !queuedScheduledJobIDs.isEmpty
        {
            let jobID = queuedScheduledJobIDs.removeFirst()
            guard !canceledJobIDs.contains(jobID) else {
                scheduledTransfersByJobID[jobID] = nil
                scheduledFTPTransfersByJobID[jobID] = nil
                continue
            }

            if let scheduledTransfer = scheduledTransfersByJobID[jobID] {
                startScheduledSCPTransfer(jobID: jobID, scheduledTransfer: scheduledTransfer)
            } else if let scheduledTransfer = scheduledFTPTransfersByJobID[jobID] {
                startScheduledFTPTransfer(jobID: jobID, scheduledTransfer: scheduledTransfer)
            } else {
                continue
            }
        }
    }

    @discardableResult
    private func markTransferInterrupted(
        jobID: String,
        status: String,
        keepsRetryableTransfer: Bool
    ) -> Bool {
        guard let job = jobsByID[jobID] else {
            return false
        }

        let latest = progressByJobID[jobID]?.last
        guard let latestStatus = latest?.status,
              Self.interruptibleStatuses.contains(latestStatus)
        else {
            return false
        }

        let bytesDone = latest?.bytesDone ?? 0
        let hasActiveWorker = runTokensByJobID[jobID] != nil
        pendingRequeueByJobID[jobID] = nil
        _ = endTransferTiming(jobID: jobID)
        let interrupted = ScpTransferProgress(
            jobId: jobID,
            bytesDone: bytesDone,
            bytesTotal: latest?.bytesTotal ?? job.bytesTotal,
            status: status
        )

        switch status {
        case "paused":
            pausedJobIDs.insert(jobID)
            stoppedJobIDs.remove(jobID)
            canceledJobIDs.remove(jobID)
        case "stopped":
            stoppedJobIDs.insert(jobID)
            pausedJobIDs.remove(jobID)
            canceledJobIDs.insert(jobID)
        default:
            canceledJobIDs.insert(jobID)
            pausedJobIDs.remove(jobID)
            stoppedJobIDs.remove(jobID)
        }

        if runningJobIDs.contains(jobID),
           scheduledTransfersByJobID[jobID] != nil
        {
            _ = bridge.cancelLiveSCPTransfer(jobID: jobID)
        }
        if runningJobIDs.contains(jobID),
           scheduledFTPTransfersByJobID[jobID] != nil
        {
            _ = ftpBridge.cancelLiveFTPTransfer(jobID: jobID)
        }

        queuedScheduledJobIDs.removeAll { $0 == jobID }
        scheduledTransfersByJobID[jobID] = nil
        scheduledFTPTransfersByJobID[jobID] = nil
        if !keepsRetryableTransfer {
            retryableTransfersByJobID[jobID] = nil
            retryableFTPTransfersByJobID[jobID] = nil
            completionByJobID[jobID] = nil
        }
        runningSCPJobIDs.remove(jobID)
        if hasActiveWorker == false {
            runningJobIDs.removeAll { $0 == jobID }
            runTokensByJobID[jobID] = nil
        }
        stopProgressPollingIfIdle()
        progressByJobID[jobID] = [interrupted]
        _ = try? historyStore.appendProgress(interrupted)
        refreshQueueView()
        startNextScheduledTransferIfNeeded()
        return true
    }

    private func startScheduledSCPTransfer(
        jobID: String,
        scheduledTransfer: ScheduledSCPTransfer
    ) {
        let runToken = beginScheduledRun(jobID: jobID)
        markScheduledTransferRunning(jobID: jobID, job: scheduledTransfer.job)
        runningSCPJobIDs.insert(jobID)
        startProgressPollingIfNeeded()

        let task = Task.detached(priority: .utility) { [bridge] in
            Result {
                try bridge.runLiveSCPTransfer(
                    config: scheduledTransfer.config,
                    secret: scheduledTransfer.secret,
                    expectedFingerprintSHA256: scheduledTransfer.expectedFingerprintSHA256,
                    job: scheduledTransfer.job,
                    resumeOptions: scheduledTransfer.resumeOptions
                )
            }
        }
        Task { @MainActor [weak self] in
            let result = await task.value
            self?.finishScheduledTransfer(jobID: jobID, runToken: runToken, result: result)
        }
    }

    private func startScheduledFTPTransfer(
        jobID: String,
        scheduledTransfer: ScheduledFTPTransfer
    ) {
        let runToken = beginScheduledRun(jobID: jobID)
        markScheduledTransferRunning(jobID: jobID, job: scheduledTransfer.job)

        let task = Task.detached(priority: .utility) { [ftpBridge] in
            Result {
                try ftpBridge.runLiveFTPTransfer(
                    config: scheduledTransfer.config,
                    secret: scheduledTransfer.secret,
                    job: scheduledTransfer.job
                )
            }
        }
        Task { @MainActor [weak self] in
            let result = await task.value
            self?.finishScheduledTransfer(jobID: jobID, runToken: runToken, result: result)
        }
    }

    private func beginScheduledRun(jobID: String) -> UUID {
        let runToken = UUID()
        runTokensByJobID[jobID] = runToken
        return runToken
    }

    private func beginTransferTiming(jobID: String) {
        var timing = timingByJobID[jobID] ?? TransferTimingState()
        timing.begin(at: monotonicTimeProvider())
        timingByJobID[jobID] = timing
    }

    @discardableResult
    private func endTransferTiming(jobID: String) -> TimeInterval {
        var timing = timingByJobID[jobID] ?? TransferTimingState()
        let duration = timing.end(at: monotonicTimeProvider())
        timingByJobID[jobID] = timing
        return duration
    }

    private func recordTerminalObservationIfNeeded(
        jobID: String,
        progress: ScpTransferProgress
    ) {
        guard progress.status == "completed" || progress.status == "failed",
              terminalObservationByJobID[jobID] == nil
        else {
            return
        }
        terminalObservationByJobID[jobID] = TransferTerminalObservation(
            completedAt: nowProvider(),
            duration: endTransferTiming(jobID: jobID)
        )
    }

    private func markScheduledTransferRunning(jobID: String, job: ScpTransferJob) {
        let resumeOptions = scheduledTransfersByJobID[jobID]?.resumeOptions
        let resumeOffset = resumeOptions?.forceRestart == true ? 0 : resumeOptions?.requestedOffset ?? 0
        beginTransferTiming(jobID: jobID)
        runningJobIDs.append(jobID)
        pausedJobIDs.remove(jobID)
        stoppedJobIDs.remove(jobID)
        canceledJobIDs.remove(jobID)
        let running = ScpTransferProgress(
            jobId: jobID,
            bytesDone: resumeOffset > 0 ? resumeOffset : progressByJobID[jobID]?.last?.bytesDone ?? 0,
            bytesTotal: job.bytesTotal,
            status: resumeOffset > 0 ? "resuming" : "running"
        )
        progressByJobID[jobID] = [running]
        _ = try? historyStore.appendProgress(running)
        refreshQueueView()
    }

    private func finishScheduledTransfer(
        jobID: String,
        runToken: UUID,
        result: Result<[ScpTransferProgress], Error>
    ) {
        if drainingRunTokensByJobID[jobID] == runToken {
            drainingRunTokensByJobID[jobID] = nil
            startNextScheduledTransferIfNeeded()
            return
        }
        guard runTokensByJobID[jobID] == runToken else {
            return
        }
        runningJobIDs.removeAll { $0 == jobID }
        runningSCPJobIDs.remove(jobID)
        scheduledTransfersByJobID[jobID] = nil
        scheduledFTPTransfersByJobID[jobID] = nil
        runTokensByJobID[jobID] = nil
        stopProgressPollingIfIdle()

        if let pendingRequeue = pendingRequeueByJobID.removeValue(forKey: jobID) {
            if requeueRetryableTransfer(
                jobID: jobID,
                bytesDone: pendingRequeue.bytesDone,
                forceRestart: pendingRequeue.forceRestart
            ) == false {
                startNextScheduledTransferIfNeeded()
            }
            return
        }

        if canceledJobIDs.contains(jobID) || pausedJobIDs.contains(jobID) || stoppedJobIDs.contains(jobID) {
            startNextScheduledTransferIfNeeded()
            return
        }

        var callbackProgress: ScpTransferProgress?
        switch result {
        case .success(let progress):
            if let job = jobsByID[jobID] {
                let acceptedProgress = acceptedCompletionProgress(jobID: jobID, job: job, progress: progress)
                if !acceptedProgress.events.isEmpty {
                    progressByJobID[jobID] = acceptedProgress.events
                    persistProgress(acceptedProgress.events, message: acceptedProgress.diagnostic)
                }
                diagnosticsByJobID[jobID] = acceptedProgress.diagnostic
                if acceptedProgress.diagnostic == nil {
                    retryableTransfersByJobID[jobID] = nil
                    retryableFTPTransfersByJobID[jobID] = nil
                }
                pausedJobIDs.remove(jobID)
                stoppedJobIDs.remove(jobID)
                canceledJobIDs.remove(jobID)
                callbackProgress = acceptedProgress.events.last ?? progressByJobID[jobID]?.last
            }
        case .failure(let error):
            if let job = jobsByID[jobID] {
                let failed = ScpTransferProgress(
                    jobId: jobID,
                    bytesDone: progressByJobID[jobID]?.last?.bytesDone ?? 0,
                    bytesTotal: job.bytesTotal,
                    status: "failed"
                )
                progressByJobID[jobID] = [failed]
                let diagnostic = diagnosticMessage(for: error)
                diagnosticsByJobID[jobID] = diagnostic
                _ = try? historyStore.appendProgress(failed, message: diagnostic)
                callbackProgress = failed
            }
        }

        presentCompletionNotificationIfNeeded(jobID: jobID, progress: callbackProgress)
        if callbackProgress?.status == "completed" {
            estimatedBytesTotalByJobID[jobID] = nil
        }
        refreshQueueView()
        if let callbackProgress,
           let completion = completionByJobID[jobID]
        {
            let retainsCompletionForRetry = callbackProgress.status == "failed"
                && (retryableTransfersByJobID[jobID] != nil || retryableFTPTransfersByJobID[jobID] != nil)
            if retainsCompletionForRetry == false {
                completionByJobID[jobID] = nil
            }
            completion(callbackProgress)
        }
        startNextScheduledTransferIfNeeded()
    }

    private func presentCompletionNotificationIfNeeded(
        jobID: String,
        progress: ScpTransferProgress?
    ) {
        guard let progress,
              let job = jobsByID[jobID]
        else {
            return
        }

        let status: TransferCompletionNotificationStatus
        let title: String
        switch progress.status {
        case "completed":
            status = .completed
            title = L10n.Transfers.completedNotificationTitle
        case "failed":
            status = .failed
            title = L10n.Transfers.failedNotificationTitle
        default:
            return
        }

        recordTerminalObservationIfNeeded(jobID: jobID, progress: progress)
        let observation = terminalObservationByJobID.removeValue(forKey: jobID)
            ?? TransferTerminalObservation(completedAt: nowProvider(), duration: endTransferTiming(jobID: jobID))
        let byteCount: UInt64
        if status == .completed, progress.bytesDone > 0 {
            byteCount = progress.bytesDone
        } else if progress.bytesTotal > 0 {
            byteCount = progress.bytesTotal
        } else if progress.bytesDone > 0 {
            byteCount = progress.bytesDone
        } else if job.bytesTotal > 0 {
            byteCount = job.bytesTotal
        } else {
            byteCount = estimatedBytesTotalByJobID[jobID] ?? 0
        }
        let rateByteCount = progress.bytesDone > 0
            ? progress.bytesDone
            : (status == .completed ? byteCount : 0)
        let completedAt = observation.completedAt
        let duration = observation.duration
        let averageBytesPerSecond = duration > 0 ? Double(rateByteCount) / duration : 0

        guard let runtimeID = runtimeIDByJobID[jobID],
              runtimeID.isEmpty == false
        else {
            return
        }

        let direction = job.direction == .upload ? L10n.Transfers.upload : L10n.Transfers.download
        let path = job.direction == .upload ? job.sourcePath : job.destinationPath
        let fileName = URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? path
            : URL(fileURLWithPath: path).lastPathComponent
        let body = status == .completed
            ? L10n.Transfers.completedNotificationBody(direction: direction, fileName: fileName)
            : L10n.Transfers.failedNotificationBody(
                direction: direction,
                fileName: fileName,
                diagnostic: diagnosticsByJobID[jobID]
            )
        completionNotificationPresenter.present(TransferCompletionNotificationPayload(
            jobID: jobID,
            runtimeID: runtimeID,
            status: status,
            title: title,
            body: body,
            itemName: fileName,
            byteCount: byteCount,
            completedAt: completedAt,
            duration: duration,
            averageBytesPerSecond: averageBytesPerSecond
        ))
    }

    private func startProgressPollingIfNeeded() {
        guard progressPollTimer == nil else {
            return
        }

        progressPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.pollRunningTransferProgressOnce()
            }
        }
    }

    private func pollRunningTransferProgressOnce() {
        guard !progressPollInFlight else {
            return
        }
        let jobIDs = runningSCPJobIDs.filter { !canceledJobIDs.contains($0) }
        guard !jobIDs.isEmpty else {
            return
        }
        progressPollInFlight = true

        let task = Task.detached(priority: .utility) { [bridge] in
            var batches: [String: [ScpTransferProgress]] = [:]
            for jobID in jobIDs {
                let progress = bridge.takeLiveSCPTransferProgressBatch(jobID: jobID)
                if !progress.isEmpty {
                    batches[jobID] = progress
                }
            }
            return batches
        }
        Task { @MainActor [weak self] in
            let batches = await task.value
            self?.applyPolledTransferProgress(batches)
        }
    }

    private func applyPolledTransferProgress(_ batches: [String: [ScpTransferProgress]]) {
        progressPollInFlight = false
        guard !batches.isEmpty else {
            return
        }

        var didApplyProgress = false
        for (jobID, progress) in batches where !canceledJobIDs.contains(jobID) && runningSCPJobIDs.contains(jobID) {
            let filteredProgress = filteredTransferProgress(jobID: jobID, progress: progress)
            guard !filteredProgress.isEmpty else {
                continue
            }
            progressByJobID[jobID] = filteredProgress
            if let terminalProgress = filteredProgress.last(where: {
                $0.status == "completed" || $0.status == "failed"
            }) {
                recordTerminalObservationIfNeeded(jobID: jobID, progress: terminalProgress)
            }
            persistProgress(filteredProgress)
            didApplyProgress = true
        }
        if didApplyProgress {
            refreshQueueView()
        }
    }

    private func filteredTransferProgress(
        jobID: String,
        progress: [ScpTransferProgress]
    ) -> [ScpTransferProgress] {
        var baselineBytesDone = progressByJobID[jobID]?.last?.bytesDone ?? 0
        var latestStatus = progressByJobID[jobID]?.last?.status
        return progress.compactMap { event in
            guard event.jobId == jobID,
                  event.bytesDone >= baselineBytesDone
            else {
                return nil
            }
            guard event.bytesDone != baselineBytesDone || event.status != latestStatus else {
                return nil
            }
            baselineBytesDone = event.bytesDone
            latestStatus = event.status
            return event
        }
    }

    private func acceptedCompletionProgress(
        jobID: String,
        job: ScpTransferJob,
        progress: [ScpTransferProgress]
    ) -> (events: [ScpTransferProgress], diagnostic: String?) {
        let filteredProgress = filteredTransferProgress(jobID: jobID, progress: progress)
        guard filteredProgress.isEmpty else {
            return (filteredProgress, nil)
        }

        if let latest = progressByJobID[jobID]?.last,
           latest.status == "completed",
           progress.contains(where: { event in
               event.jobId == jobID
                   && event.status == latest.status
                   && event.bytesDone >= latest.bytesDone
           })
        {
            return ([], nil)
        }

        return ([
            ScpTransferProgress(
                jobId: jobID,
                bytesDone: progressByJobID[jobID]?.last?.bytesDone ?? 0,
                bytesTotal: job.bytesTotal,
                status: "failed"
            )
        ], L10n.Transfers.transferFailed)
    }

    private func stopProgressPollingIfIdle() {
        guard runningSCPJobIDs.isEmpty else {
            return
        }

        progressPollTimer?.invalidate()
        progressPollTimer = nil
        progressPollInFlight = false
    }

    private func record(job: ScpTransferJob) {
        if jobsByID[job.id] == nil {
            orderedJobIDs.append(job.id)
        }
        jobsByID[job.id] = job
    }

    private func isActiveScheduledTransfer(jobID: String) -> Bool {
        if runningJobIDs.contains(jobID)
            || queuedScheduledJobIDs.contains(jobID)
            || pausedJobIDs.contains(jobID)
            || drainingRunTokensByJobID[jobID] != nil
        {
            return true
        }
        return scheduledTransfersByJobID[jobID] != nil || scheduledFTPTransfersByJobID[jobID] != nil
    }

    private var activeWorkerCount: Int {
        runningJobIDs.count + drainingRunTokensByJobID.count
    }

    private func moveActiveWorkerToDrainingState(jobID: String) {
        guard let runToken = runTokensByJobID[jobID] else {
            return
        }
        if runningJobIDs.contains(jobID), scheduledTransfersByJobID[jobID] != nil {
            _ = bridge.cancelLiveSCPTransfer(jobID: jobID)
        }
        if runningJobIDs.contains(jobID), scheduledFTPTransfersByJobID[jobID] != nil {
            _ = ftpBridge.cancelLiveFTPTransfer(jobID: jobID)
        }
        drainingRunTokensByJobID[jobID] = runToken
    }

    private func removeTransfer(jobID: String) {
        orderedJobIDs.removeAll { $0 == jobID }
        jobsByID[jobID] = nil
        progressByJobID[jobID] = nil
        estimatedBytesTotalByJobID[jobID] = nil
        diagnosticsByJobID[jobID] = nil
        eventLogsByJobID[jobID] = nil
        scheduledTransfersByJobID[jobID] = nil
        scheduledFTPTransfersByJobID[jobID] = nil
        retryableTransfersByJobID[jobID] = nil
        retryableFTPTransfersByJobID[jobID] = nil
        completionByJobID[jobID] = nil
        queuedScheduledJobIDs.removeAll { $0 == jobID }
        runningJobIDs.removeAll { $0 == jobID }
        runningSCPJobIDs.remove(jobID)
        canceledJobIDs.remove(jobID)
        pausedJobIDs.remove(jobID)
        stoppedJobIDs.remove(jobID)
        runTokensByJobID[jobID] = nil
        pendingRequeueByJobID[jobID] = nil
        runtimeIDByJobID[jobID] = nil
        timingByJobID[jobID] = nil
        terminalObservationByJobID[jobID] = nil
    }

    private func persistProgress(_ progressEvents: [ScpTransferProgress], message: String? = nil) {
        for progress in progressEvents {
            _ = try? historyStore.appendProgress(progress, message: message)
        }
    }

    private func refreshQueueView() {
        let visibleJobIDs = visibleQueueJobIDs()
        let jobs = visibleJobIDs.compactMap { jobsByID[$0] }
        let progress = visibleJobIDs.flatMap { progressByJobID[$0] ?? [] }
        queueViewController?.setTransfers(
            jobs: jobs,
            progressEvents: progress,
            diagnosticsByJobID: diagnosticsByJobID,
            eventLogsByJobID: eventLogsByJobID
        )
        onSnapshotChanged?(makeTransferStatusSnapshot())
    }

    private func makeTransferStatusSnapshot() -> TransferQueueSnapshot {
        let actionableOrActiveJobIDs = orderedJobIDs.filter { jobID in
            guard let status = progressByJobID[jobID]?.last?.status else {
                return false
            }
            let isActive = runningJobIDs.contains(jobID)
                || queuedScheduledJobIDs.contains(jobID)
                || pausedJobIDs.contains(jobID)
            return (isActive && Self.interruptibleStatuses.contains(status))
                || Self.retryableStatuses.contains(status)
        }
        if actionableOrActiveJobIDs.isEmpty == false {
            return makeSnapshot(jobIDs: actionableOrActiveJobIDs)
        }
        return makeSnapshot(jobIDs: Array(finishedHistoryJobIDs().suffix(1)))
    }

    private func makeSnapshot(jobIDs: [String]) -> TransferQueueSnapshot {
        let jobs = jobIDs.compactMap { jobsByID[$0] }
        let rows = jobs.map { job in
            let latest = progressByJobID[job.id]?.last
            return TransferQueueSnapshot.Row(
                jobID: job.id,
                direction: job.direction,
                sourcePath: job.sourcePath,
                destinationPath: job.destinationPath,
                bytesDone: latest?.bytesDone ?? 0,
                bytesTotal: Self.displayBytesTotal(
                    job: job,
                    latest: latest,
                    estimatedBytesTotal: estimatedBytesTotalByJobID[job.id]
                ),
                rawStatus: latest?.status ?? "queued",
                diagnostic: diagnosticsByJobID[job.id]
            )
        }
        return TransferQueueSnapshot(rows: rows)
    }

    private static func displayBytesTotal(
        job: ScpTransferJob,
        latest: ScpTransferProgress?,
        estimatedBytesTotal: UInt64?
    ) -> UInt64 {
        if let latestBytesTotal = latest?.bytesTotal,
           latestBytesTotal > 0
        {
            return latestBytesTotal
        }
        if job.bytesTotal > 0 {
            return job.bytesTotal
        }
        return estimatedBytesTotal ?? 0
    }

    private static func largeFileTransferWarning(for job: ScpTransferJob) -> String? {
        guard job.bytesTotal >= largeFileWarningThresholdBytes else {
            return nil
        }
        let size = formatByteCount(job.bytesTotal)
        let seconds = Double(job.bytesTotal) / largeFileEstimateBytesPerSecond
        let estimate = formatDuration(seconds)
        return "大文件提醒：\(size)，预计 \(estimate)。传输会在后台继续，可随时暂停或停止。"
    }

    private static func formatByteCount(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_024 / 1_024
        if megabytes < 1_024 {
            let rounded = megabytes.rounded()
            return "\(Int(rounded)) MB"
        }
        let gigabytes = megabytes / 1_024
        let rounded = (gigabytes * 10).rounded() / 10
        if rounded.rounded(.down) == rounded {
            return "\(Int(rounded)) GB"
        }
        return String(format: "%.1f GB", rounded)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let wholeSeconds = max(1, Int(seconds.rounded(.up)))
        if wholeSeconds < 60 {
            return "\(wholeSeconds) 秒"
        }
        let minutes = wholeSeconds / 60
        let remainingSeconds = wholeSeconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes) 分" : "\(minutes) 分 \(remainingSeconds) 秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分"
    }

    private func visibleQueueJobIDs() -> [String] {
        let visibleCompleted = Set(completedHistoryJobIDs().suffix(Self.maxCompletedHistoryRows))
        return orderedJobIDs.filter { jobID in
            guard progressByJobID[jobID]?.last?.status == "completed" else {
                return true
            }
            return visibleCompleted.contains(jobID)
        }
    }

    private func completedHistoryJobIDs() -> [String] {
        orderedJobIDs.filter { jobID in
            progressByJobID[jobID]?.last?.status == "completed"
        }
    }

    private func finishedHistoryJobIDs() -> [String] {
        orderedJobIDs.filter { jobID in
            guard let status = progressByJobID[jobID]?.last?.status else {
                return false
            }
            return Self.finishedStatuses.contains(status)
        }
    }

    private func diagnosticMessage(for error: Error?) -> String {
        guard let error else {
            return L10n.Transfers.transferFailed
        }

        guard let sshError = error as? SshRuntimeError else {
            return RuntimeDiagnosticFormatter.userMessage(for: error)
        }

        return switch sshError {
        case .InvalidConfig:
            L10n.Transfers.invalidSSHConfiguration
        case .AuthFailed:
            L10n.Transfers.authenticationFailed
        case .Timeout:
            L10n.Transfers.connectionTimedOut
        case .HostKeyChanged:
            L10n.Transfers.hostKeyChanged
        case .UnknownHostKey:
            L10n.Transfers.unknownHostKey
        case let .Transport(message):
            RuntimeDiagnosticFormatter.userMessage(message)
        }
    }

    private static let interruptibleStatuses = Set(["queued", "running", "resuming", "paused"])
    private static let retryableStatuses = Set(["failed", "stopped", "canceled", "cancelled"])
    private static let finishedStatuses = Set(["completed", "failed", "stopped", "canceled", "cancelled"])
    private static let maxCompletedHistoryRows = 5
    private static let largeFileWarningThresholdBytes: UInt64 = 100 * 1024 * 1024
    private static let largeFileEstimateBytesPerSecond: Double = 20 * 1024 * 1024
}

private func resumeOptions(requestedOffset: UInt64, forceRestart: Bool) -> ScpResumeOptions {
    ScpResumeOptions(requestedOffset: forceRestart ? 0 : requestedOffset, forceRestart: forceRestart)
}

private struct TransferTimingState {
    private var activeStartedAt: TimeInterval?
    private(set) var accumulatedDuration: TimeInterval = 0

    mutating func begin(at timestamp: TimeInterval) {
        guard activeStartedAt == nil else { return }
        activeStartedAt = timestamp
    }

    mutating func end(at timestamp: TimeInterval) -> TimeInterval {
        if let activeStartedAt {
            accumulatedDuration += max(timestamp - activeStartedAt, 0)
            self.activeStartedAt = nil
        }
        return accumulatedDuration
    }
}

private struct TransferTerminalObservation {
    let completedAt: Date
    let duration: TimeInterval
}

private struct PendingTransferRequeue {
    let bytesDone: UInt64
    let forceRestart: Bool
}

private struct ScheduledSCPTransfer: Sendable {
    let config: SshConnectionConfig
    let secret: SshAuthSecret
    let expectedFingerprintSHA256: String
    let job: ScpTransferJob
    let resumeOptions: ScpResumeOptions

    func withResumeOptions(_ resumeOptions: ScpResumeOptions) -> ScheduledSCPTransfer {
        ScheduledSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions
        )
    }
}

private struct ScheduledFTPTransfer: Sendable {
    let config: FtpConnectionConfig
    let secret: FtpAuthSecret
    let job: ScpTransferJob
}
