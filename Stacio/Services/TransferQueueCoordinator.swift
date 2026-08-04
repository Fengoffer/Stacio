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

public protocol SFTPTransferBridging {
    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress]
    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress]
    func cancelLiveSFTPTransfer(jobID: String) -> Bool
}

public extension SFTPTransferBridging {
    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        try runLiveSFTPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    func cancelLiveSFTPTransfer(jobID: String) -> Bool {
        false
    }
}

public struct CoreBridgeSFTPTransferBridge: SFTPTransferBridging {
    public init() {}

    public func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        try CoreBridge.runLiveSFTPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    public func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        resumeOptions: ScpResumeOptions
    ) throws -> [ScpTransferProgress] {
        try CoreBridge.runLiveSFTPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions
        )
    }

    public func cancelLiveSFTPTransfer(jobID: String) -> Bool {
        (try? CoreBridge.cancelLiveSCPTransfer(jobID: jobID)) ?? false
    }
}

public protocol SCPTransferHistoryStoring {
    func recordJob(sessionID: String?, job: ScpTransferJob, status: String, bytesDone: UInt64) throws
    func appendProgress(_ progress: ScpTransferProgress) throws -> ScpTransferEventRecord
    func appendProgress(_ progress: ScpTransferProgress, message: String?) throws -> ScpTransferEventRecord
    func listJobs() throws -> [ScpTransferJobRecord]
    func listEvents(jobID: String) throws -> [ScpTransferEventRecord]
    func clearFinishedJobs() throws -> UInt32
    func deleteFinishedJob(jobID: String) throws -> Bool
}

public enum TransferCompletionNotificationPolicy: Equatable, Sendable {
    case userVisible
    case silent
}

public enum LocalFileTransferOperation: Equatable, Sendable {
    case copy
    case move
}

public enum LocalFileTransferResult: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

@MainActor
public protocol LocalFileTransferScheduling: AnyObject {
    @discardableResult
    func scheduleLocalFileTransfer(
        runtimeID: String,
        sourceURL: URL,
        destinationURL: URL,
        operation: LocalFileTransferOperation,
        notificationPolicy: TransferCompletionNotificationPolicy,
        completion: ((LocalFileTransferResult) -> Void)?
    ) -> String
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
        public let runtimeID: String?
        public let elapsedTime: TimeInterval
        public let finishedAt: Date?

        public init(
            jobID: String,
            direction: ScpDirection,
            sourcePath: String,
            destinationPath: String,
            bytesDone: UInt64,
            bytesTotal: UInt64,
            rawStatus: String,
            diagnostic: String?,
            runtimeID: String? = nil,
            elapsedTime: TimeInterval = 0,
            finishedAt: Date? = nil
        ) {
            self.jobID = jobID
            self.direction = direction
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.rawStatus = rawStatus
            self.diagnostic = diagnostic
            self.runtimeID = runtimeID
            self.elapsedTime = elapsedTime
            self.finishedAt = finishedAt
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

    public func deleteFinishedJob(jobID: String) throws -> Bool {
        true
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

    public func deleteFinishedJob(jobID: String) throws -> Bool {
        try CoreBridge.deleteFinishedSCPTransferJob(
            databasePath: databasePath,
            jobID: jobID
        )
    }
}

@MainActor
public final class TransferQueueCoordinator {
    public var onRetryRequested: ((String) -> Void)?
    public var onSnapshotChanged: ((TransferQueueSnapshot) -> Void)?

    private let bridge: SCPTransferBridging
    private let sftpBridge: SFTPTransferBridging
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
    private var notificationPolicyByJobID: [String: TransferCompletionNotificationPolicy] = [:]
    private var finishedAtByJobID: [String: Date] = [:]
    private struct QueueObservation {
        let runtimeIDs: () -> Set<String>
        let handler: (TransferQueueSnapshot) -> Void
    }
    private var queueObservations: [UUID: QueueObservation] = [:]
    private struct ExternalTransferControl {
        let progressProvider: @Sendable () -> [ScpTransferProgress]
        let pause: () -> Bool
        let resume: () -> Bool
        let cancel: () -> Bool
    }
    private var externalTransferControlsByJobID: [String: ExternalTransferControl] = [:]
    private struct OrchestratedRetry {
        let runtimeIDs: Set<String>
        let retry: () -> Bool
        let discard: () -> Void
    }
    private var orchestratedRetriesByJobID: [String: OrchestratedRetry] = [:]
    private var queuedScheduledJobIDs: [String] = []
    private var runningJobIDs: [String] = []
    private var runningSCPJobIDs = Set<String>()
    private var canceledJobIDs = Set<String>()
    private var pausedJobIDs = Set<String>()
    private var stoppedJobIDs = Set<String>()
    private var runTokensByJobID: [String: UUID] = [:]
    private var drainingRunTokensByJobID: [String: UUID] = [:]
    private var drainingCancellationCompletionsByJobID: [String: (ScpTransferProgress) -> Void] = [:]
    private var drainingCancellationProgressByJobID: [String: ScpTransferProgress] = [:]
    private var drainingUsesWorkerResultJobIDs = Set<String>()
    private var pendingRequeueByJobID: [String: PendingTransferRequeue] = [:]
    private var runtimeIDByJobID: [String: String] = [:]
    private var priorRuntimeIDsByCurrentRuntimeID: [String: Set<String>] = [:]
    private var progressPollTimer: Timer?
    private var progressPollInFlight = false
    private let maxConcurrentTransfers: Int
    private let localFileTransferExecutor: LocalFileTransferExecutor
    private let nowProvider: () -> Date
    private let monotonicTimeProvider: () -> TimeInterval
    private var timingByJobID: [String: TransferTimingState] = [:]
    private var terminalObservationByJobID: [String: TransferTerminalObservation] = [:]

    var maxConcurrentTransfersForTesting: Int {
        maxConcurrentTransfers
    }

    public init(
        bridge: SCPTransferBridging = CoreBridgeSCPTransferBridge(),
        sftpBridge: SFTPTransferBridging = CoreBridgeSFTPTransferBridge(),
        ftpBridge: FTPTransferBridging = CoreBridgeFTPTransferBridge(),
        historyStore: SCPTransferHistoryStoring = NoOpSCPTransferHistoryStore(),
        completionNotificationPresenter: TransferCompletionNotificationPresenting? = nil,
        queueViewController: TransferQueueViewController,
        maxConcurrentTransfers: Int = 2,
        nowProvider: @escaping () -> Date = Date.init,
        monotonicTimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.bridge = bridge
        self.sftpBridge = sftpBridge
        self.ftpBridge = ftpBridge
        self.historyStore = historyStore
        self.completionNotificationPresenter = completionNotificationPresenter
            ?? NoopTransferCompletionNotificationPresenter()
        self.queueViewController = queueViewController
        self.maxConcurrentTransfers = max(1, maxConcurrentTransfers)
        self.localFileTransferExecutor = LocalFileTransferExecutor(
            maxConcurrentTransfers: max(1, maxConcurrentTransfers)
        )
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

    @discardableResult
    public func observeQueue(
        runtimeIDs: @escaping () -> Set<String>,
        handler: @escaping (TransferQueueSnapshot) -> Void
    ) -> UUID {
        let observationID = UUID()
        let observation = QueueObservation(runtimeIDs: runtimeIDs, handler: handler)
        queueObservations[observationID] = observation
        handler(makeSessionSnapshot(runtimeIDs: runtimeIDs()))
        return observationID
    }

    public func removeQueueObservation(_ observationID: UUID) {
        queueObservations[observationID] = nil
    }

    public func registerExternalTransfer(
        runtimeID: String,
        job: ScpTransferJob,
        notificationPolicy: TransferCompletionNotificationPolicy = .silent,
        progressProvider: @escaping @Sendable () -> [ScpTransferProgress],
        pause: @escaping () -> Bool,
        resume: @escaping () -> Bool,
        cancel: @escaping () -> Bool
    ) {
        if let existingStatus = progressByJobID[job.id]?.last?.status {
            guard Self.finishedStatuses.contains(existingStatus) else { return }
            removeTransfer(jobID: job.id)
        } else if jobsByID[job.id] != nil {
            return
        }
        notificationPolicyByJobID[job.id] = notificationPolicy
        enqueueTransfer(runtimeID: runtimeID, job: job)
        externalTransferControlsByJobID[job.id] = ExternalTransferControl(
            progressProvider: progressProvider,
            pause: pause,
            resume: resume,
            cancel: cancel
        )
        beginTransferTiming(jobID: job.id)
        runningJobIDs.append(job.id)
        runningSCPJobIDs.insert(job.id)
        progressByJobID[job.id] = [ScpTransferProgress(
            jobId: job.id,
            bytesDone: 0,
            bytesTotal: job.bytesTotal,
            status: "running"
        )]
        startProgressPollingIfNeeded()
        refreshQueueView()
    }

    public func finishExternalTransfer(
        jobID: String,
        status: String,
        bytesDone: UInt64,
        diagnostic: String? = nil
    ) {
        guard let job = jobsByID[jobID] else { return }
        runningJobIDs.removeAll { $0 == jobID }
        runningSCPJobIDs.remove(jobID)
        externalTransferControlsByJobID[jobID] = nil
        pausedJobIDs.remove(jobID)
        _ = endTransferTiming(jobID: jobID)
        if Self.finishedStatuses.contains(status) {
            finishedAtByJobID[jobID] = nowProvider()
        }
        let latest = progressByJobID[jobID]?.last
        let progress = ScpTransferProgress(
            jobId: jobID,
            bytesDone: max(bytesDone, latest?.bytesDone ?? 0),
            bytesTotal: max(job.bytesTotal, latest?.bytesTotal ?? 0),
            status: status
        )
        progressByJobID[jobID] = [progress]
        diagnosticsByJobID[jobID] = diagnostic
        _ = try? historyStore.appendProgress(progress, message: diagnostic)
        presentCompletionNotificationIfNeeded(jobID: jobID, progress: progress)
        stopProgressPollingIfIdle()
        refreshQueueView()
    }

    @discardableResult
    public func scheduleLocalFileTransfer(
        runtimeID: String,
        sourceURL: URL,
        destinationURL: URL,
        operation: LocalFileTransferOperation,
        notificationPolicy: TransferCompletionNotificationPolicy = .userVisible,
        completion: ((LocalFileTransferResult) -> Void)? = nil
    ) -> String {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let jobID = "local_file_\(UUID().uuidString)"
        let task = LocalFileTransferTask(
            jobID: jobID,
            sourceURL: source,
            destinationURL: destination,
            operation: operation
        )
        let job = ScpTransferJob(
            id: jobID,
            direction: .upload,
            sourcePath: source.path,
            destinationPath: destination.path,
            bytesTotal: task.initialByteCount
        )
        registerExternalTransfer(
            runtimeID: runtimeID,
            job: job,
            notificationPolicy: notificationPolicy,
            progressProvider: { [task] in task.takeProgressBatch() },
            pause: { [task] in task.pause() },
            resume: { [task] in task.resume() },
            cancel: { [task] in task.cancel() }
        )
        localFileTransferExecutor.submit(task) { [weak self] result, progress in
            guard let self else {
                completion?(result)
                return
            }
            if progress.bytesTotal > 0 {
                self.updateScheduledTransferEstimatedByteTotal(
                    jobID: jobID,
                    bytesTotal: progress.bytesTotal
                )
            }
            let status: String
            let diagnostic: String?
            switch result {
            case .completed:
                status = "completed"
                diagnostic = nil
            case .cancelled:
                status = "canceled"
                diagnostic = nil
            case .failed(let message):
                status = "failed"
                diagnostic = message
            }
            self.finishExternalTransfer(
                jobID: jobID,
                status: status,
                bytesDone: progress.bytesDone,
                diagnostic: diagnostic
            )
            completion?(result)
        }
        return jobID
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
        finishedAtByJobID[job.id] = nil
        if notificationPolicyByJobID[job.id] == nil {
            notificationPolicyByJobID[job.id] = .userVisible
        }
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
        scheduleLiveTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .userVisible,
            completion: completion
        )
    }

    public func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        notificationPolicy: TransferCompletionNotificationPolicy,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        guard !isActiveScheduledTransfer(jobID: job.id) else {
            return
        }
        notificationPolicyByJobID[job.id] = notificationPolicy
        enqueueTransfer(runtimeID: runtimeID, job: job)
        scheduledTransfersByJobID[job.id] = ScheduledSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions(requestedOffset: 0, forceRestart: false),
            transport: .scp
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

    public func registerOrchestratedRetry(
        jobID: String,
        runtimeIDs: Set<String>,
        retry: @escaping () -> Bool,
        discard: @escaping () -> Void
    ) {
        orchestratedRetriesByJobID[jobID] = OrchestratedRetry(
            runtimeIDs: runtimeIDs,
            retry: retry,
            discard: discard
        )
    }

    public func unregisterOrchestratedRetry(jobID: String) {
        orchestratedRetriesByJobID[jobID] = nil
    }

    public func scheduleLiveSFTPTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        scheduleLiveSFTPTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .userVisible,
            completion: completion
        )
    }

    public func scheduleLiveSFTPTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        notificationPolicy: TransferCompletionNotificationPolicy,
        completion: ((ScpTransferProgress) -> Void)? = nil
    ) {
        guard !isActiveScheduledTransfer(jobID: job.id) else {
            return
        }
        notificationPolicyByJobID[job.id] = notificationPolicy
        enqueueTransfer(runtimeID: runtimeID, job: job)
        scheduledTransfersByJobID[job.id] = ScheduledSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions(requestedOffset: 0, forceRestart: false),
            transport: .sftp
        )
        retryableTransfersByJobID[job.id] = scheduledTransfersByJobID[job.id]
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
        let orchestrationJobIDs = orchestratedRetriesByJobID.compactMap { jobID, orchestration in
            orchestration.runtimeIDs.contains(runtimeID) ? jobID : nil
        }
        for jobID in orchestrationJobIDs {
            discardOrchestratedRetry(jobID: jobID)
        }
        let jobIDs = orderedJobIDs.filter { runtimeIDByJobID[$0] == runtimeID }
        guard jobIDs.isEmpty == false else {
            return []
        }
        for jobID in jobIDs {
            if let externalControl = externalTransferControlsByJobID[jobID] {
                _ = externalControl.cancel()
            }
            let latest = progressByJobID[jobID]?.last
            let canceled = ScpTransferProgress(
                jobId: jobID,
                bytesDone: latest?.bytesDone ?? 0,
                bytesTotal: jobsByID[jobID]?.bytesTotal ?? latest?.bytesTotal ?? 0,
                status: "canceled"
            )
            let completion = completionByJobID[jobID]
            var immediateCompletion: (() -> Void)?
            if let cancellationAccepted = moveActiveWorkerToDrainingState(jobID: jobID) {
                if let completion {
                    drainingCancellationCompletionsByJobID[jobID] = completion
                    drainingCancellationProgressByJobID[jobID] = canceled
                    if cancellationAccepted == false {
                        drainingUsesWorkerResultJobIDs.insert(jobID)
                    }
                }
            } else {
                immediateCompletion = { completion?(canceled) }
            }
            removeTransfer(jobID: jobID)
            immediateCompletion?()
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
        if let control = externalTransferControlsByJobID[jobID] {
            guard control.cancel() else { return false }
            return markExternalTransferInterrupted(jobID: jobID, status: "canceled", keepsControl: false)
        }
        return markTransferInterrupted(jobID: jobID, status: "canceled", keepsRetryableTransfer: false)
    }

    @discardableResult
    public func pauseTransfer(jobID: String) -> Bool {
        if let control = externalTransferControlsByJobID[jobID] {
            guard control.pause() else { return false }
            return markExternalTransferInterrupted(jobID: jobID, status: "paused", keepsControl: true)
        }
        return markTransferInterrupted(jobID: jobID, status: "paused", keepsRetryableTransfer: true)
    }

    @discardableResult
    public func resumeTransfer(jobID: String) -> Bool {
        guard progressByJobID[jobID]?.last?.status == "paused" else {
            return false
        }
        if let control = externalTransferControlsByJobID[jobID] {
            guard control.resume() else { return false }
            pausedJobIDs.remove(jobID)
            beginTransferTiming(jobID: jobID)
            if runningJobIDs.contains(jobID) == false {
                runningJobIDs.append(jobID)
            }
            runningSCPJobIDs.insert(jobID)
            let latest = progressByJobID[jobID]?.last
            progressByJobID[jobID] = [ScpTransferProgress(
                jobId: jobID,
                bytesDone: latest?.bytesDone ?? 0,
                bytesTotal: latest?.bytesTotal ?? jobsByID[jobID]?.bytesTotal ?? 0,
                status: "resuming"
            )]
            startProgressPollingIfNeeded()
            refreshQueueView()
            return true
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
        let orchestratedRetries = Array(orchestratedRetriesByJobID.values)
        orchestratedRetriesByJobID = [:]
        orchestratedRetries.forEach { $0.discard() }
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
        notificationPolicyByJobID = [:]
        finishedAtByJobID = [:]
        externalTransferControlsByJobID = [:]
        queuedScheduledJobIDs = []
        runningJobIDs = []
        runningSCPJobIDs = []
        pausedJobIDs = []
        stoppedJobIDs = []
        canceledJobIDs = []
        runTokensByJobID = [:]
        drainingRunTokensByJobID = [:]
        drainingCancellationCompletionsByJobID = [:]
        drainingCancellationProgressByJobID = [:]
        drainingUsesWorkerResultJobIDs = []
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

        do {
            _ = try historyStore.clearFinishedJobs()
        } catch {
            return 0
        }

        let finished = Set(finishedJobIDs)
        orderedJobIDs.removeAll { finished.contains($0) }
        for jobID in finished {
            discardOrchestratedRetry(jobID: jobID)
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
            notificationPolicyByJobID[jobID] = nil
            finishedAtByJobID[jobID] = nil
            externalTransferControlsByJobID[jobID] = nil
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

    @discardableResult
    public func removeFinishedTransfer(jobID: String) -> Bool {
        guard orderedJobIDs.contains(jobID),
              let status = progressByJobID[jobID]?.last?.status,
              Self.finishedStatuses.contains(status)
        else {
            return false
        }
        do {
            guard try historyStore.deleteFinishedJob(jobID: jobID) else {
                return false
            }
        } catch {
            return false
        }

        moveActiveWorkerToDrainingState(jobID: jobID)
        removeTransfer(jobID: jobID)
        refreshQueueView()
        stopProgressPollingIfIdle()
        startNextScheduledTransferIfNeeded()
        return true
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
        if Self.finishedStatuses.contains(status) {
            finishedAtByJobID[jobID] = nowProvider()
            _ = endTransferTiming(jobID: jobID)
        } else {
            finishedAtByJobID[jobID] = nil
        }
        refreshQueueView()
    }

    @discardableResult
    public func retryFailedTransfer(jobID: String) -> Bool {
        guard let status = progressByJobID[jobID]?.last?.status,
              Self.retryableStatuses.contains(status)
        else {
            return false
        }

        if let orchestration = orchestratedRetriesByJobID[jobID] {
            return orchestration.retry()
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
        finishedAtByJobID[jobID] = nil
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
    private func markExternalTransferInterrupted(
        jobID: String,
        status: String,
        keepsControl: Bool
    ) -> Bool {
        guard let job = jobsByID[jobID],
              let latest = progressByJobID[jobID]?.last
        else { return false }
        runningJobIDs.removeAll { $0 == jobID }
        runningSCPJobIDs.remove(jobID)
        _ = endTransferTiming(jobID: jobID)
        let interrupted = ScpTransferProgress(
            jobId: jobID,
            bytesDone: latest.bytesDone,
            bytesTotal: latest.bytesTotal > 0 ? latest.bytesTotal : job.bytesTotal,
            status: status
        )
        progressByJobID[jobID] = [interrupted]
        if status == "paused" {
            pausedJobIDs.insert(jobID)
        } else {
            pausedJobIDs.remove(jobID)
            finishedAtByJobID[jobID] = nowProvider()
        }
        if keepsControl == false {
            externalTransferControlsByJobID[jobID] = nil
        }
        _ = try? historyStore.appendProgress(interrupted)
        stopProgressPollingIfIdle()
        refreshQueueView()
        return true
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
        let isCancellation = ["canceled", "cancelled"].contains(status.lowercased())
        let cancellationCompletion = isCancellation
            ? completionByJobID[jobID]
            : nil
        if runningJobIDs.contains(jobID),
           let scheduledTransfer = scheduledTransfersByJobID[jobID]
        {
            let accepted: Bool
            switch scheduledTransfer.transport {
            case .scp:
                accepted = bridge.cancelLiveSCPTransfer(jobID: jobID)
            case .sftp:
                accepted = sftpBridge.cancelLiveSFTPTransfer(jobID: jobID)
            }
            guard accepted else { return false }
        }
        if runningJobIDs.contains(jobID),
           scheduledFTPTransfersByJobID[jobID] != nil,
           ftpBridge.cancelLiveFTPTransfer(jobID: jobID) == false
        {
            return false
        }
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

        queuedScheduledJobIDs.removeAll { $0 == jobID }
        scheduledTransfersByJobID[jobID] = nil
        scheduledFTPTransfersByJobID[jobID] = nil
        if !keepsRetryableTransfer {
            retryableTransfersByJobID[jobID] = nil
            retryableFTPTransfersByJobID[jobID] = nil
            if !(isCancellation && hasActiveWorker) {
                completionByJobID[jobID] = nil
            }
        }
        runningSCPJobIDs.remove(jobID)
        if hasActiveWorker == false {
            runningJobIDs.removeAll { $0 == jobID }
            runTokensByJobID[jobID] = nil
        }
        stopProgressPollingIfIdle()
        progressByJobID[jobID] = [interrupted]
        if Self.finishedStatuses.contains(status) {
            finishedAtByJobID[jobID] = nowProvider()
        }
        _ = try? historyStore.appendProgress(interrupted)
        refreshQueueView()
        if isCancellation && hasActiveWorker == false {
            completionByJobID[jobID] = nil
            cancellationCompletion?(interrupted)
        }
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

        let task = Task.detached(priority: .utility) { [bridge, sftpBridge] in
            Result {
                switch scheduledTransfer.transport {
                case .scp:
                    return try bridge.runLiveSCPTransfer(
                        config: scheduledTransfer.config,
                        secret: scheduledTransfer.secret,
                        expectedFingerprintSHA256: scheduledTransfer.expectedFingerprintSHA256,
                        job: scheduledTransfer.job,
                        resumeOptions: scheduledTransfer.resumeOptions
                    )
                case .sftp:
                    return try sftpBridge.runLiveSFTPTransfer(
                        config: scheduledTransfer.config,
                        secret: scheduledTransfer.secret,
                        expectedFingerprintSHA256: scheduledTransfer.expectedFingerprintSHA256,
                        job: scheduledTransfer.job,
                        resumeOptions: scheduledTransfer.resumeOptions
                    )
                }
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
        timing.begin(at: monotonicTimeProvider(), displayDate: nowProvider())
        timingByJobID[jobID] = timing
    }

    @discardableResult
    private func endTransferTiming(jobID: String) -> TimeInterval {
        var timing = timingByJobID[jobID] ?? TransferTimingState()
        let duration = timing.end(at: monotonicTimeProvider(), displayDate: nowProvider())
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
        let completedAt = nowProvider()
        terminalObservationByJobID[jobID] = TransferTerminalObservation(
            completedAt: completedAt,
            duration: endTransferTiming(jobID: jobID)
        )
        finishedAtByJobID[jobID] = completedAt
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
            let completion = drainingCancellationCompletionsByJobID.removeValue(forKey: jobID)
            let fallbackProgress = drainingCancellationProgressByJobID.removeValue(forKey: jobID)
            let usesWorkerResult = drainingUsesWorkerResultJobIDs.remove(jobID) != nil
            let progress = usesWorkerResult
                ? drainingTerminalProgress(result: result, fallback: fallbackProgress)
                : fallbackProgress
            if let progress {
                completion?(progress)
            }
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

        if canceledJobIDs.contains(jobID) {
            let interrupted = progressByJobID[jobID]?.last
            let completion = completionByJobID.removeValue(forKey: jobID)
            if let interrupted {
                completion?(interrupted)
            }
            startNextScheduledTransferIfNeeded()
            return
        }
        if pausedJobIDs.contains(jobID) || stoppedJobIDs.contains(jobID) {
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
        guard notificationPolicyByJobID[jobID] != .silent else {
            terminalObservationByJobID[jobID] = nil
            return
        }
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
        let externalProgressProviders = Dictionary(uniqueKeysWithValues: jobIDs.compactMap { jobID in
            externalTransferControlsByJobID[jobID].map { (jobID, $0.progressProvider) }
        })

        let task = Task.detached(priority: .utility) { [bridge, externalProgressProviders] in
            var batches: [String: [ScpTransferProgress]] = [:]
            for jobID in jobIDs {
                let progress = externalProgressProviders[jobID]?()
                    ?? bridge.takeLiveSCPTransferProgressBatch(jobID: jobID)
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
            if runningSCPJobIDs.isEmpty == false {
                refreshQueueView()
            }
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
            || externalTransferControlsByJobID[jobID] != nil
    }

    private var activeWorkerCount: Int {
        runningJobIDs.lazy.filter { self.externalTransferControlsByJobID[$0] == nil }.count
            + drainingRunTokensByJobID.count
    }

    @discardableResult
    private func moveActiveWorkerToDrainingState(jobID: String) -> Bool? {
        guard let runToken = runTokensByJobID[jobID] else {
            return nil
        }
        var cancellationAccepted: Bool?
        if runningJobIDs.contains(jobID), let scheduledTransfer = scheduledTransfersByJobID[jobID] {
            switch scheduledTransfer.transport {
            case .scp:
                cancellationAccepted = bridge.cancelLiveSCPTransfer(jobID: jobID)
            case .sftp:
                cancellationAccepted = sftpBridge.cancelLiveSFTPTransfer(jobID: jobID)
            }
        }
        if runningJobIDs.contains(jobID), scheduledFTPTransfersByJobID[jobID] != nil {
            cancellationAccepted = ftpBridge.cancelLiveFTPTransfer(jobID: jobID)
        }
        drainingRunTokensByJobID[jobID] = runToken
        return cancellationAccepted ?? false
    }

    private func drainingTerminalProgress(
        result: Result<[ScpTransferProgress], Error>,
        fallback: ScpTransferProgress?
    ) -> ScpTransferProgress? {
        switch result {
        case .success(let progressEvents):
            if let terminal = progressEvents.last(where: {
                $0.jobId == fallback?.jobId
                    && ["completed", "failed", "canceled", "cancelled"].contains($0.status.lowercased())
            }) {
                return terminal
            }
        case .failure:
            break
        }
        guard let fallback else { return nil }
        return ScpTransferProgress(
            jobId: fallback.jobId,
            bytesDone: fallback.bytesDone,
            bytesTotal: fallback.bytesTotal,
            status: "failed"
        )
    }

    private func removeTransfer(jobID: String) {
        discardOrchestratedRetry(jobID: jobID)
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
        notificationPolicyByJobID[jobID] = nil
        externalTransferControlsByJobID[jobID] = nil
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
        finishedAtByJobID[jobID] = nil
    }

    private func discardOrchestratedRetry(jobID: String) {
        orchestratedRetriesByJobID.removeValue(forKey: jobID)?.discard()
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
        for observation in Array(queueObservations.values) {
            observation.handler(makeSessionSnapshot(runtimeIDs: observation.runtimeIDs()))
        }
    }

    private func makeSessionSnapshot(runtimeIDs: Set<String>) -> TransferQueueSnapshot {
        guard runtimeIDs.isEmpty == false else {
            return TransferQueueSnapshot(rows: [], capturedAt: nowProvider())
        }
        let matchingJobIDs = orderedJobIDs.filter { jobID in
            runtimeIDByJobID[jobID].map(runtimeIDs.contains) == true
        }
        let activeJobIDs = matchingJobIDs.filter { jobID in
            guard let status = progressByJobID[jobID]?.last?.status else { return false }
            return Self.finishedStatuses.contains(status) == false
        }
        let historyJobIDs = matchingJobIDs
            .filter { !activeJobIDs.contains($0) }
            .sorted { lhs, rhs in
                let lhsFinishedAt = finishedAtByJobID[lhs] ?? .distantPast
                let rhsFinishedAt = finishedAtByJobID[rhs] ?? .distantPast
                if lhsFinishedAt != rhsFinishedAt {
                    return lhsFinishedAt > rhsFinishedAt
                }
                return (orderedJobIDs.firstIndex(of: lhs) ?? 0) > (orderedJobIDs.firstIndex(of: rhs) ?? 0)
            }
        return makeSnapshot(jobIDs: activeJobIDs + historyJobIDs)
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
                diagnostic: diagnosticsByJobID[job.id],
                runtimeID: runtimeIDByJobID[job.id],
                elapsedTime: timingByJobID[job.id]?.displayElapsed(at: nowProvider()) ?? 0,
                finishedAt: finishedAtByJobID[job.id]
            )
        }
        return TransferQueueSnapshot(rows: rows, capturedAt: nowProvider())
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

extension TransferQueueCoordinator: LocalFileTransferScheduling {}

private final class LocalFileTransferExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.stacio.files.local-transfer",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let limiter: DispatchSemaphore

    init(maxConcurrentTransfers: Int) {
        limiter = DispatchSemaphore(value: max(1, maxConcurrentTransfers))
    }

    func submit(
        _ task: LocalFileTransferTask,
        completion: @escaping @MainActor (LocalFileTransferResult, ScpTransferProgress) -> Void
    ) {
        queue.async {
            self.limiter.wait()
            let result = task.run()
            let progress = task.currentProgress
            self.limiter.signal()
            DispatchQueue.main.async {
                completion(result, progress)
            }
        }
    }
}

final class LocalFileTransferTask: @unchecked Sendable {
    private enum TaskError: Error, LocalizedError {
        case cancelled
        case invalidSource(String)
        case destinationInsideSource
        case unsupportedItem(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "本地传输已取消"
            case .invalidSource(let path):
                return "本地源文件不存在或不可读取：\(path)"
            case .destinationInsideSource:
                return "目标目录不能位于源目录内部"
            case .unsupportedItem(let path):
                return "不支持传输此本地项目：\(path)"
            }
        }
    }

    let initialByteCount: UInt64

    private let jobID: String
    private let sourceURL: URL
    private let destinationURL: URL
    private let operation: LocalFileTransferOperation
    private let fileManager: FileManager
    private let chunkSize: Int
    private let chunkDelay: TimeInterval
    private let state = NSCondition()
    private var isPaused = false
    private var isCancelled = false
    private var isFinished = false
    private var pendingProgress: ScpTransferProgress?
    private var latestProgress: ScpTransferProgress
    private var temporaryURL: URL?

    init(
        jobID: String,
        sourceURL: URL,
        destinationURL: URL,
        operation: LocalFileTransferOperation,
        fileManager: FileManager = .default,
        chunkSize: Int = 1_024 * 1_024,
        chunkDelay: TimeInterval = 0
    ) {
        self.jobID = jobID
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.operation = operation
        self.fileManager = fileManager
        self.chunkSize = max(64 * 1_024, chunkSize)
        self.chunkDelay = max(0, chunkDelay)
        self.initialByteCount = Self.fileByteCount(at: sourceURL, fileManager: fileManager) ?? 0
        self.latestProgress = ScpTransferProgress(
            jobId: jobID,
            bytesDone: 0,
            bytesTotal: initialByteCount,
            status: "running"
        )
    }

    var currentProgress: ScpTransferProgress {
        state.lock()
        defer { state.unlock() }
        return latestProgress
    }

    func takeProgressBatch() -> [ScpTransferProgress] {
        state.lock()
        defer { state.unlock() }
        guard let pendingProgress else { return [] }
        self.pendingProgress = nil
        return [pendingProgress]
    }

    func pause() -> Bool {
        state.lock()
        defer { state.unlock() }
        guard isFinished == false, isCancelled == false, isPaused == false else { return false }
        isPaused = true
        return true
    }

    func resume() -> Bool {
        state.lock()
        defer { state.unlock() }
        guard isFinished == false, isCancelled == false, isPaused else { return false }
        isPaused = false
        state.broadcast()
        return true
    }

    func cancel() -> Bool {
        state.lock()
        defer { state.unlock() }
        guard isFinished == false, isCancelled == false else { return false }
        isCancelled = true
        isPaused = false
        state.broadcast()
        return true
    }

    func run() -> LocalFileTransferResult {
        do {
            try checkpoint()
            let values = try sourceURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true
                    || values.isRegularFile == true
                    || values.isSymbolicLink == true
            else {
                throw TaskError.invalidSource(sourceURL.path)
            }
            if values.isDirectory == true,
               Self.isDescendant(destinationURL, of: sourceURL)
            {
                throw TaskError.destinationInsideSource
            }

            let bytesTotal = try totalByteCount(at: sourceURL)
            recordProgress(bytesDone: 0, bytesTotal: bytesTotal)
            if operation == .move, try canMoveAtomically() {
                try checkpoint()
                try promote(sourceURL, to: destinationURL)
                recordProgress(bytesDone: bytesTotal, bytesTotal: bytesTotal)
                markFinished()
                return .completed
            }

            let stagingURL = Self.stagingURL(for: destinationURL, jobID: jobID)
            temporaryURL = stagingURL
            try? fileManager.removeItem(at: stagingURL)
            var bytesDone: UInt64 = 0
            try copyItem(
                at: sourceURL,
                to: stagingURL,
                bytesDone: &bytesDone,
                bytesTotal: bytesTotal
            )
            try checkpoint()
            try promote(stagingURL, to: destinationURL)
            temporaryURL = nil
            if operation == .move {
                try fileManager.removeItem(at: sourceURL)
            }
            recordProgress(bytesDone: bytesTotal, bytesTotal: bytesTotal)
            markFinished()
            return .completed
        } catch TaskError.cancelled {
            cleanupTemporaryItem()
            markFinished()
            return .cancelled
        } catch {
            cleanupTemporaryItem()
            markFinished()
            return .failed(error.localizedDescription)
        }
    }

    private func totalByteCount(at url: URL) throws -> UInt64 {
        try checkpoint()
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        if values.isSymbolicLink == true { return 0 }
        if values.isRegularFile == true {
            return UInt64(max(values.fileSize ?? 0, 0))
        }
        guard values.isDirectory == true else {
            throw TaskError.unsupportedItem(url.path)
        }
        var total: UInt64 = 0
        for child in try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let value = try totalByteCount(at: child)
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? UInt64.max : sum
        }
        return total
    }

    private func copyItem(
        at source: URL,
        to destination: URL,
        bytesDone: inout UInt64,
        bytesTotal: UInt64
    ) throws {
        try checkpoint()
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        if values.isSymbolicLink == true {
            let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            return
        }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                try copyItem(
                    at: child,
                    to: destination.appendingPathComponent(child.lastPathComponent),
                    bytesDone: &bytesDone,
                    bytesTotal: bytesTotal
                )
            }
            try applyMetadata(from: source, to: destination)
            return
        }
        guard values.isRegularFile == true else {
            throw TaskError.unsupportedItem(source.path)
        }

        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: destination)
        defer {
            try? reader.close()
            try? writer.close()
        }
        while true {
            try checkpoint()
            guard let data = try reader.read(upToCount: chunkSize), data.isEmpty == false else { break }
            try writer.write(contentsOf: data)
            let (sum, overflow) = bytesDone.addingReportingOverflow(UInt64(data.count))
            bytesDone = overflow ? UInt64.max : sum
            recordProgress(bytesDone: bytesDone, bytesTotal: bytesTotal)
            if chunkDelay > 0 {
                Thread.sleep(forTimeInterval: chunkDelay)
            }
        }
        try writer.synchronize()
        try applyMetadata(from: source, to: destination)
    }

    private func applyMetadata(from source: URL, to destination: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        var preserved: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.posixPermissions, .modificationDate] {
            if let value = attributes[key] {
                preserved[key] = value
            }
        }
        if preserved.isEmpty == false {
            try fileManager.setAttributes(preserved, ofItemAtPath: destination.path)
        }
    }

    private func canMoveAtomically() throws -> Bool {
        let sourceVolume = try sourceURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let destinationVolume = try destinationURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier
        guard let sourceVolume, let destinationVolume else { return false }
        return sourceVolume.isEqual(destinationVolume)
    }

    private func promote(_ source: URL, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }

        let backup = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).stacio-backup-\(UUID().uuidString)",
            isDirectory: destination.hasDirectoryPath
        )
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: destination, to: source)
            }
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func checkpoint() throws {
        state.lock()
        while isPaused, isCancelled == false {
            state.wait()
        }
        let cancelled = isCancelled
        state.unlock()
        if cancelled { throw TaskError.cancelled }
    }

    private func recordProgress(bytesDone: UInt64, bytesTotal: UInt64) {
        let progress = ScpTransferProgress(
            jobId: jobID,
            bytesDone: min(bytesDone, bytesTotal),
            bytesTotal: bytesTotal,
            status: "running"
        )
        state.lock()
        latestProgress = progress
        pendingProgress = progress
        state.unlock()
    }

    private func markFinished() {
        state.lock()
        isFinished = true
        isPaused = false
        state.broadcast()
        state.unlock()
    }

    private func cleanupTemporaryItem() {
        guard let temporaryURL else { return }
        try? fileManager.removeItem(at: temporaryURL)
        self.temporaryURL = nil
    }

    private static func stagingURL(for destination: URL, jobID: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).stacio-transfer-\(jobID).partial",
            isDirectory: destination.hasDirectoryPath
        )
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/")
    }

    private static func fileByteCount(at url: URL, fileManager: FileManager) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }
}

private func resumeOptions(requestedOffset: UInt64, forceRestart: Bool) -> ScpResumeOptions {
    ScpResumeOptions(requestedOffset: forceRestart ? 0 : requestedOffset, forceRestart: forceRestart)
}

private struct TransferTimingState {
    private var activeStartedAt: TimeInterval?
    private var displayActiveStartedAt: Date?
    private(set) var accumulatedDuration: TimeInterval = 0
    private(set) var displayAccumulatedDuration: TimeInterval = 0

    mutating func begin(at timestamp: TimeInterval, displayDate: Date) {
        guard activeStartedAt == nil else { return }
        activeStartedAt = timestamp
        displayActiveStartedAt = displayDate
    }

    mutating func end(at timestamp: TimeInterval, displayDate: Date) -> TimeInterval {
        if let activeStartedAt {
            accumulatedDuration += max(timestamp - activeStartedAt, 0)
            self.activeStartedAt = nil
        }
        if let displayActiveStartedAt {
            displayAccumulatedDuration += max(displayDate.timeIntervalSince(displayActiveStartedAt), 0)
            self.displayActiveStartedAt = nil
        }
        return accumulatedDuration
    }

    func displayElapsed(at date: Date) -> TimeInterval {
        displayAccumulatedDuration
            + (displayActiveStartedAt.map { max(date.timeIntervalSince($0), 0) } ?? 0)
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

private enum SecureTransferTransport: Sendable {
    case scp
    case sftp
}

private struct ScheduledSCPTransfer: Sendable {
    let config: SshConnectionConfig
    let secret: SshAuthSecret
    let expectedFingerprintSHA256: String
    let job: ScpTransferJob
    let resumeOptions: ScpResumeOptions
    let transport: SecureTransferTransport

    func withResumeOptions(_ resumeOptions: ScpResumeOptions) -> ScheduledSCPTransfer {
        ScheduledSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            resumeOptions: resumeOptions,
            transport: transport
        )
    }
}

private struct ScheduledFTPTransfer: Sendable {
    let config: FtpConnectionConfig
    let secret: FtpAuthSecret
    let job: ScpTransferJob
}
