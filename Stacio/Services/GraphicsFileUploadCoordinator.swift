import AppKit
import Foundation
import StacioCoreBindings

private func preparePrivateGraphicsUploadFile(
    target: GraphicsSSHUploadTarget,
    path: String
) throws {
    try CoreBridge.createLiveRemoteFileExclusive(
        config: target.context.config,
        secret: target.context.secret,
        expectedFingerprintSHA256: target.context.expectedFingerprintSHA256,
        remotePath: path
    )
}

private func removePreparedGraphicsUploadFile(
    target: GraphicsSSHUploadTarget,
    path: String
) throws {
    try CoreBridge.deleteLiveRemotePath(
        config: target.context.config,
        secret: target.context.secret,
        expectedFingerprintSHA256: target.context.expectedFingerprintSHA256,
        remotePath: path,
        recursive: false
    )
}

func normalizedGraphicsTransferHost(_ host: String) -> String {
    var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("["), normalized.hasSuffix("]") {
        normalized.removeFirst()
        normalized.removeLast()
    }
    while normalized.hasSuffix(".") {
        normalized.removeLast()
    }
    return normalized
}

private struct GraphicsUploadReservationScope: Hashable {
    let host: String
    let port: String
    let username: String
    let fingerprint: String

    init(target: GraphicsSSHUploadTarget) {
        host = normalizedGraphicsTransferHost(target.context.config.host)
        port = String(target.context.config.port)
        username = target.context.config.username
        fingerprint = target.context.expectedFingerprintSHA256
    }
}

struct GraphicsSSHUploadTarget: @unchecked Sendable {
    let runtimeID: String
    let context: TunnelLiveSessionContext
}

@MainActor
protocol GraphicsTransferQueueObserving: AnyObject {
    @discardableResult
    func observeQueue(
        runtimeIDs: @escaping () -> Set<String>,
        handler: @escaping (TransferQueueSnapshot) -> Void
    ) -> UUID

    func removeQueueObservation(_ observationID: UUID)
}

extension TransferQueueCoordinator: GraphicsTransferQueueObserving {}

enum GraphicsFileUploadError: LocalizedError {
    case missingAssociatedSSH
    case ambiguousAssociatedSSH
    case unsupportedProxyJump
    case unavailable
    case preparationFailed(String)
    case incomplete
    case duplicateFileNames
    case directoriesUnsupported
    case unsupportedFileName
    case transferFailed

    var errorDescription: String? {
        switch self {
        case .missingAssociatedSSH:
            return "请先建立同一主机的 SSH 连接以使用文件传输功能"
        case .ambiguousAssociatedSSH:
            return "检测到多个同一主机的 SSH 连接，请仅保留目标连接后重试"
        case .unsupportedProxyJump:
            return "当前文件传输暂不支持 ProxyJump SSH 会话"
        case .unavailable:
            return "文件传输服务暂不可用"
        case .preparationFailed(let message):
            return "文件上传失败：\(message)"
        case .incomplete:
            return "部分文件未加入上传队列"
        case .duplicateFileNames:
            return "拖入的文件包含同名项，请分开上传"
        case .directoriesUnsupported:
            return "VNC 拖传暂不支持文件夹，请选择文件"
        case .unsupportedFileName:
            return "文件名不受 SCP 安全规则支持，请重命名后重试"
        case .transferFailed:
            return "文件上传失败"
        }
    }
}

@MainActor
final class GraphicsFileUploadCoordinator {
    typealias RemoteDirectoryLoader = @Sendable (
        GraphicsSSHUploadTarget,
        String
    ) throws -> [RemoteFileEntry]

    typealias RemoteFilePreparer = @Sendable (
        GraphicsSSHUploadTarget,
        String
    ) throws -> Void

    typealias RemoteFileCleaner = @Sendable (
        GraphicsSSHUploadTarget,
        String
    ) throws -> Void

    private let remoteDirectory: String
    private let remoteDirectoryLoader: RemoteDirectoryLoader
    private let remoteFilePreparer: RemoteFilePreparer
    private let remoteFileCleaner: RemoteFileCleaner
    private let remotePreparationQueue = DispatchQueue(label: "stacio.graphics-upload.prepare")
    private var batches: [String: GraphicsFileUploadBatch] = [:]
    private var reservedPathsByScope: [GraphicsUploadReservationScope: Set<String>] = [:]
    private var reservationsByBatchID: [
        String: (scope: GraphicsUploadReservationScope, paths: Set<String>)
    ] = [:]

    init(
        remoteDirectory: String = "/tmp",
        remoteDirectoryLoader: @escaping RemoteDirectoryLoader = { target, path in
            try CoreBridge.listLiveRemoteDirectory(
                config: target.context.config,
                secret: target.context.secret,
                expectedFingerprintSHA256: target.context.expectedFingerprintSHA256,
                remotePath: path
            )
        },
        remoteFilePreparer: @escaping RemoteFilePreparer = { target, path in
            try preparePrivateGraphicsUploadFile(target: target, path: path)
        },
        remoteFileCleaner: @escaping RemoteFileCleaner = { target, path in
            try removePreparedGraphicsUploadFile(target: target, path: path)
        }
    ) {
        self.remoteDirectory = remoteDirectory
        self.remoteDirectoryLoader = remoteDirectoryLoader
        self.remoteFilePreparer = remoteFilePreparer
        self.remoteFileCleaner = remoteFileCleaner
    }

    static func selectTarget(from targets: [GraphicsSSHUploadTarget]) throws -> GraphicsSSHUploadTarget {
        let directTargets = targets.filter { $0.context.proxyJump == nil }
        guard !directTargets.isEmpty else {
            throw targets.isEmpty
                ? GraphicsFileUploadError.missingAssociatedSSH
                : GraphicsFileUploadError.unsupportedProxyJump
        }
        guard directTargets.count == 1, let target = directTargets.first else {
            throw GraphicsFileUploadError.ambiguousAssociatedSSH
        }
        return target
    }

    func upload(
        localPaths: [String],
        target: GraphicsSSHUploadTarget,
        transferScheduler: SCPTransferScheduling,
        isTargetActive: @escaping @MainActor () -> Bool,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !localPaths.isEmpty else {
            completion(.success([]))
            return
        }
        do {
            for localPath in localPaths {
                let url = URL(fileURLWithPath: localPath)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory != true else {
                    completion(.failure(GraphicsFileUploadError.directoriesUnsupported))
                    return
                }
                let fileName = url.lastPathComponent
                guard !fileName.hasPrefix("-"),
                      !fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else {
                    completion(.failure(GraphicsFileUploadError.unsupportedFileName))
                    return
                }
            }
        } catch {
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            completion(.failure(GraphicsFileUploadError.preparationFailed(message)))
            return
        }
        let fileNames = localPaths.map {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased()
        }
        guard Set(fileNames).count == fileNames.count else {
            completion(.failure(GraphicsFileUploadError.duplicateFileNames))
            return
        }

        let remoteDirectory = self.remoteDirectory
        let loader = remoteDirectoryLoader
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    try loader(target, remoteDirectory)
                }.value
                guard isTargetActive() else {
                    completion(.failure(GraphicsFileUploadError.missingAssociatedSSH))
                    return
                }
                self.scheduleUploads(
                    localPaths: localPaths,
                    remoteEntries: entries,
                    remoteDirectory: remoteDirectory,
                    target: target,
                    transferScheduler: transferScheduler,
                    isTargetActive: isTargetActive,
                    completion: completion
                )
            } catch {
                let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                completion(.failure(GraphicsFileUploadError.preparationFailed(message)))
            }
        }
    }

    private func scheduleUploads(
        localPaths: [String],
        remoteEntries: [RemoteFileEntry],
        remoteDirectory: String,
        target: GraphicsSSHUploadTarget,
        transferScheduler: SCPTransferScheduling,
        isTargetActive: @escaping @MainActor () -> Bool,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let batchID = UUID().uuidString
        let reservationScope = GraphicsUploadReservationScope(target: target)
        let existingReservedPaths = reservedPathsByScope[reservationScope] ?? []
        let effectiveRemoteEntries = remoteEntries + existingReservedPaths.map {
            RemoteFileEntry(
                kind: .file,
                path: $0,
                size: 0,
                modifiedTime: nil,
                linkTarget: nil,
                owner: nil,
                permissions: nil
            )
        }
        let filesViewController = FilesViewController()
        filesViewController.setRemoteEntries(effectiveRemoteEntries, remotePath: remoteDirectory)

        let remotePreparationQueue = self.remotePreparationQueue
        let remoteFilePreparer = self.remoteFilePreparer
        let trackingScheduler = GraphicsUploadTrackingScheduler(
            scheduler: transferScheduler,
            target: target,
            remoteFilePreparer: { target, path in
                try remotePreparationQueue.sync {
                    try remoteFilePreparer(target, path)
                }
            },
            remoteFileCleaner: remoteFileCleaner,
            isTargetActive: isTargetActive
        ) { [weak self] result in
            self?.finishBatch(batchID: batchID)
            completion(result)
        }
        trackingScheduler.startObservingTransferQueue()
        let filesCoordinator = FilesCoordinator(
            filesViewController: filesViewController,
            liveSessionContextProvider: { target.context },
            liveSessionRuntimeIDProvider: { target.runtimeID },
            transferScheduler: trackingScheduler,
            conflictResolver: GraphicsUploadConflictResolver()
        )
        let batch = GraphicsFileUploadBatch(
            filesViewController: filesViewController,
            filesCoordinator: filesCoordinator,
            trackingScheduler: trackingScheduler,
            remoteEntries: effectiveRemoteEntries
        )
        batches[batchID] = batch
        let reservedPaths = Set(
            batch.schedule(
                localPaths: localPaths,
                remoteDirectory: remoteDirectory,
                target: target,
                transferScheduler: trackingScheduler
            )
        )
        if !reservedPaths.isEmpty {
            reservedPathsByScope[reservationScope, default: []].formUnion(reservedPaths)
            reservationsByBatchID[batchID] = (reservationScope, reservedPaths)
        }
        batch.finish(expectedItemCount: localPaths.count)
    }

    private func finishBatch(batchID: String) {
        batches.removeValue(forKey: batchID)
        guard let reservation = reservationsByBatchID.removeValue(forKey: batchID) else { return }
        reservedPathsByScope[reservation.scope]?.subtract(reservation.paths)
        if reservedPathsByScope[reservation.scope]?.isEmpty == true {
            reservedPathsByScope.removeValue(forKey: reservation.scope)
        }
    }
}

@MainActor
private final class GraphicsFileUploadBatch {
    private let filesViewController: FilesViewController
    private let filesCoordinator: FilesCoordinator
    private let trackingScheduler: GraphicsUploadTrackingScheduler
    private var remoteEntries: [RemoteFileEntry]

    init(
        filesViewController: FilesViewController,
        filesCoordinator: FilesCoordinator,
        trackingScheduler: GraphicsUploadTrackingScheduler,
        remoteEntries: [RemoteFileEntry]
    ) {
        self.filesViewController = filesViewController
        self.filesCoordinator = filesCoordinator
        self.trackingScheduler = trackingScheduler
        self.remoteEntries = remoteEntries
    }

    func schedule(
        localPaths: [String],
        remoteDirectory: String,
        target: GraphicsSSHUploadTarget,
        transferScheduler: SCPTransferScheduling
    ) -> [String] {
        for localPath in localPaths {
            let scheduledCount = trackingScheduler.scheduledDestinationPaths.count
            filesCoordinator.scheduleDroppedUploads(
                localPaths: [localPath],
                remoteDirectory: remoteDirectory,
                runtimeID: target.runtimeID,
                context: target.context,
                transferScheduler: transferScheduler
            )
            guard trackingScheduler.scheduledDestinationPaths.count > scheduledCount,
                  let reservedPath = trackingScheduler.scheduledDestinationPaths.last
            else { continue }
            remoteEntries.append(
                RemoteFileEntry(
                    kind: .file,
                    path: reservedPath,
                    size: 0,
                    modifiedTime: nil,
                    linkTarget: nil,
                    owner: nil,
                    permissions: nil
                )
            )
            filesViewController.setRemoteEntries(remoteEntries, remotePath: remoteDirectory)
        }
        return trackingScheduler.scheduledDestinationPaths
    }

    func finish(expectedItemCount: Int) {
        trackingScheduler.finishScheduling(expectedItemCount: expectedItemCount)
    }
}

private struct GraphicsUploadConflictResolver: RemoteFileConflictResolving {
    func resolveConflict(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> ScpConflictPolicy? {
        .skip
    }
}

@MainActor
private final class GraphicsUploadTrackingScheduler: SCPTransferScheduling {
    private struct PendingTransfer {
        let runtimeID: String
        let config: SshConnectionConfig
        let secret: SshAuthSecret
        let expectedFingerprintSHA256: String
        let job: ScpTransferJob
        let downstreamCompletion: ((ScpTransferProgress) -> Void)?
    }

    private let scheduler: SCPTransferScheduling
    private let target: GraphicsSSHUploadTarget
    private let remoteFilePreparer: GraphicsFileUploadCoordinator.RemoteFilePreparer
    private let remoteFileCleaner: GraphicsFileUploadCoordinator.RemoteFileCleaner
    private let isTargetActive: @MainActor () -> Bool
    private let completion: (Result<[String], Error>) -> Void
    private var orderedJobIDs: [String] = []
    private var destinationPathByJobID: [String: String] = [:]
    private var terminalJobIDs: Set<String> = []
    private var failedJobIDs: Set<String> = []
    private var observedJobIDs: Set<String> = []
    private var latestSnapshotJobIDs: Set<String> = []
    private var pendingMissingJobIDs: Set<String> = []
    private var pendingCleanupJobIDs: Set<String> = []
    private weak var snapshotSource: GraphicsTransferQueueObserving?
    private var snapshotObserverToken: UUID?
    private var expectedItemCount = 0
    private var didFinishScheduling = false
    private var didComplete = false
    private var pendingTransfers: [PendingTransfer] = []
    private var isPreparingTransfer = false

    var scheduledDestinationPaths: [String] {
        orderedJobIDs.compactMap { destinationPathByJobID[$0] }
    }

    init(
        scheduler: SCPTransferScheduling,
        target: GraphicsSSHUploadTarget,
        remoteFilePreparer: @escaping GraphicsFileUploadCoordinator.RemoteFilePreparer,
        remoteFileCleaner: @escaping GraphicsFileUploadCoordinator.RemoteFileCleaner,
        isTargetActive: @escaping @MainActor () -> Bool,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        self.scheduler = scheduler
        self.target = target
        self.remoteFilePreparer = remoteFilePreparer
        self.remoteFileCleaner = remoteFileCleaner
        self.isTargetActive = isTargetActive
        self.completion = completion
    }

    func startObservingTransferQueue() {
        guard let source = scheduler as? GraphicsTransferQueueObserving else { return }
        snapshotSource = source
        let runtimeID = target.runtimeID
        snapshotObserverToken = source.observeQueue(
            runtimeIDs: { [runtimeID] in [runtimeID] },
            handler: { [weak self] snapshot in
                self?.handleSnapshot(snapshot)
            }
        )
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion downstreamCompletion: ((ScpTransferProgress) -> Void)?
    ) {
        orderedJobIDs.append(job.id)
        destinationPathByJobID[job.id] = job.destinationPath
        pendingTransfers.append(
            PendingTransfer(
                runtimeID: runtimeID,
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                job: job,
                downstreamCompletion: downstreamCompletion
            )
        )
    }

    private func prepareQueuedTransfers() {
        guard didFinishScheduling, !isPreparingTransfer, !pendingTransfers.isEmpty else { return }
        isPreparingTransfer = true
        let pendingTransfers = self.pendingTransfers
        self.pendingTransfers.removeAll(keepingCapacity: true)
        let target = self.target
        let preparer = remoteFilePreparer
        let cleaner = remoteFileCleaner
        let destinationPaths = pendingTransfers.map { $0.job.destinationPath }
        Task { @MainActor [weak self] in
            let preparationResults = await Task.detached(priority: .userInitiated) {
                destinationPaths.map { path in
                    do {
                        try preparer(target, path)
                        return true
                    } catch {
                        return false
                    }
                }
            }.value
            guard let self else { return }
            let targetIsActive = self.isTargetActive()
            for (index, pending) in pendingTransfers.enumerated() {
                let didPrepareRemoteFile = preparationResults[index]
                if didPrepareRemoteFile, targetIsActive {
                    self.scheduler.scheduleLiveTransfer(
                        runtimeID: pending.runtimeID,
                        config: pending.config,
                        secret: pending.secret,
                        expectedFingerprintSHA256: pending.expectedFingerprintSHA256,
                        job: pending.job
                    ) { [weak self] progress in
                        pending.downstreamCompletion?(progress)
                        self?.recordTerminalProgress(progress, jobID: pending.job.id)
                    }
                    continue
                }
                if didPrepareRemoteFile {
                    try? await Task.detached(priority: .utility) {
                        try cleaner(target, pending.job.destinationPath)
                    }.value
                }
                let progress = ScpTransferProgress(
                    jobId: pending.job.id,
                    bytesDone: 0,
                    bytesTotal: pending.job.bytesTotal,
                    status: "failed"
                )
                pending.downstreamCompletion?(progress)
                self.failedJobIDs.insert(pending.job.id)
                self.terminalJobIDs.insert(pending.job.id)
            }
            self.isPreparingTransfer = false
            self.completeIfReady()
        }
    }

    private func recordTerminalProgress(_ progress: ScpTransferProgress, jobID: String) {
        guard progress.status == "completed" || progress.status == "failed" else { return }
        guard !terminalJobIDs.contains(jobID), !pendingCleanupJobIDs.contains(jobID) else { return }
        if progress.status == "failed" {
            scheduleRemoteCleanup(jobID)
            return
        }
        terminalJobIDs.insert(jobID)
        completeIfReady()
    }

    func disconnectTransfers(runtimeID: String) -> [String] {
        scheduler.disconnectTransfers(runtimeID: runtimeID)
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {
        scheduler.updateScheduledTransferEstimatedByteTotal(jobID: jobID, bytesTotal: bytesTotal)
    }

    func finishScheduling(expectedItemCount: Int) {
        self.expectedItemCount = expectedItemCount
        didFinishScheduling = true
        prepareQueuedTransfers()
        completeIfReady()
    }

    private func handleSnapshot(_ snapshot: TransferQueueSnapshot) {
        let rowsByJobID = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.jobID, $0) })
        latestSnapshotJobIDs = Set(rowsByJobID.keys)
        let terminalStatuses = Set(["completed", "failed", "stopped", "canceled", "cancelled"])
        for jobID in orderedJobIDs where !terminalJobIDs.contains(jobID) {
            if let row = rowsByJobID[jobID] {
                pendingMissingJobIDs.remove(jobID)
                observedJobIDs.insert(jobID)
                if terminalStatuses.contains(row.rawStatus) {
                    if row.rawStatus != "completed" {
                        scheduleRemoteCleanup(jobID)
                    } else {
                        terminalJobIDs.insert(jobID)
                    }
                }
            } else if observedJobIDs.contains(jobID) {
                scheduleMissingJobCheck(jobID)
            }
        }
        completeIfReady()
    }

    private func scheduleMissingJobCheck(_ jobID: String) {
        guard pendingMissingJobIDs.insert(jobID).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMissingJobIDs.remove(jobID)
            guard !self.terminalJobIDs.contains(jobID),
                  !self.latestSnapshotJobIDs.contains(jobID)
            else { return }
            self.scheduleRemoteCleanup(jobID)
        }
    }

    private func scheduleRemoteCleanup(_ jobID: String) {
        guard pendingCleanupJobIDs.insert(jobID).inserted,
              let path = destinationPathByJobID[jobID]
        else { return }
        let target = self.target
        let cleaner = remoteFileCleaner
        Task { @MainActor [weak self] in
            try? await Task.detached(priority: .utility) {
                try cleaner(target, path)
            }.value
            guard let self else { return }
            self.pendingCleanupJobIDs.remove(jobID)
            self.terminalJobIDs.insert(jobID)
            self.failedJobIDs.insert(jobID)
            self.completeIfReady()
        }
    }

    private func stopObservingTransferQueue() {
        guard let token = snapshotObserverToken else { return }
        snapshotSource?.removeQueueObservation(token)
        snapshotObserverToken = nil
    }

    private func completeIfReady() {
        guard didFinishScheduling,
              !didComplete,
              terminalJobIDs.count == orderedJobIDs.count
        else { return }
        didComplete = true
        stopObservingTransferQueue()

        if orderedJobIDs.count != expectedItemCount {
            completion(.failure(GraphicsFileUploadError.incomplete))
            return
        }
        if !failedJobIDs.isEmpty {
            completion(.failure(GraphicsFileUploadError.transferFailed))
            return
        }
        completion(.success(orderedJobIDs.compactMap { destinationPathByJobID[$0] }))
    }
}
