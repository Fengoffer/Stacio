import CryptoKit
import Foundation
import StacioCoreBindings

public enum CrossDeviceTransferOperation: Equatable, Sendable {
    case copy
    case move
}

public protocol RemoteToRemoteTransferBridging: AnyObject, Sendable {
    func runLiveRemoteToRemoteTransfer(
        sourceConfig: SshConnectionConfig,
        sourceSecret: SshAuthSecret,
        sourceExpectedFingerprintSHA256: String,
        destinationConfig: SshConnectionConfig,
        destinationSecret: SshAuthSecret,
        destinationExpectedFingerprintSHA256: String,
        request: RemoteToRemoteTransferRequest
    ) throws -> RemoteToRemoteTransferReport

    func cancelLiveRemoteToRemoteTransfer(jobID: String) -> Bool
    func retireRemoteTransferAttempt(jobID: String)
    func takeLiveRemoteToRemoteTransferProgressBatch(jobID: String) -> [ScpTransferProgress]
}

public extension RemoteToRemoteTransferBridging {
    func retireRemoteTransferAttempt(jobID: String) {}

    func takeLiveRemoteToRemoteTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        []
    }
}

public final class CoreBridgeRemoteToRemoteTransferBridge: RemoteToRemoteTransferBridging, @unchecked Sendable {
    public init() {}

    public func runLiveRemoteToRemoteTransfer(
        sourceConfig: SshConnectionConfig,
        sourceSecret: SshAuthSecret,
        sourceExpectedFingerprintSHA256: String,
        destinationConfig: SshConnectionConfig,
        destinationSecret: SshAuthSecret,
        destinationExpectedFingerprintSHA256: String,
        request: RemoteToRemoteTransferRequest
    ) throws -> RemoteToRemoteTransferReport {
        try CoreBridge.runLiveRemoteToRemoteTransfer(
            sourceConfig: sourceConfig,
            sourceSecret: sourceSecret,
            sourceExpectedFingerprintSHA256: sourceExpectedFingerprintSHA256,
            destinationConfig: destinationConfig,
            destinationSecret: destinationSecret,
            destinationExpectedFingerprintSHA256: destinationExpectedFingerprintSHA256,
            request: request
        )
    }

    public func retireRemoteTransferAttempt(jobID: String) {
        StacioCoreBindings.retireRemoteTransferAttempt(jobId: jobID)
    }

    public func cancelLiveRemoteToRemoteTransfer(jobID: String) -> Bool {
        (try? CoreBridge.cancelLiveSCPTransfer(jobID: jobID)) ?? false
    }

    public func takeLiveRemoteToRemoteTransferProgressBatch(jobID: String) -> [ScpTransferProgress] {
        (try? CoreBridge.takeLiveSCPTransferProgressBatch(jobID: jobID)) ?? []
    }
}

private final class CrossDeviceDirectRouteRegistry: @unchecked Sendable {
    static let shared = CrossDeviceDirectRouteRegistry()

    private let lock = NSLock()
    private var activeRouteIDs = Set<String>()
    private struct Destination: Hashable {
        let host: String
        let port: UInt16
        let user: Data
        let absolute: Bool
        var components: [Data]

        init(_ config: SshConnectionConfig, path: String) {
            host = config.host.lowercased()
            port = config.port
            user = Data(config.username.utf8)
            absolute = path.utf8.first == 47
            components = []
            for part in path.utf8.split(separator: 47) {
                let component = Data(part)
                if component == Data(".".utf8) { continue }
                if component == Data("..".utf8) {
                    if let last = components.last, last != component { components.removeLast(); continue }
                    if absolute { continue }
                }
                components.append(component)
            }
        }

        var prefixes: [Self] {
            var prefix = self
            var result = [prefix]
            while !prefix.components.isEmpty { prefix.components.removeLast(); result.append(prefix) }
            return result
        }
    }

    private var roots = Set<Destination>()
    private var subtreeCounts: [Destination: Int] = [:]
    private var destinationsByOwner: [UUID: [Destination]] = [:]

    func reserve(_ paths: [String], on endpoint: SshConnectionConfig, owner: UUID) -> Bool {
        let keys = paths.map { Destination(endpoint, path: $0) }
        lock.lock()
        defer { lock.unlock() }
        var inserted: [Destination] = []
        for key in keys {
            let prefixes = key.prefixes
            guard subtreeCounts[key] == nil, !prefixes.contains(where: roots.contains) else {
                removeDestinations(inserted)
                return false
            }
            roots.insert(key)
            for prefix in prefixes { subtreeCounts[prefix, default: 0] += 1 }
            inserted.append(key)
        }
        destinationsByOwner[owner] = inserted
        return true
    }

    func releaseDestinations(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let keys = destinationsByOwner.removeValue(forKey: owner) { removeDestinations(keys) }
    }

    private func removeDestinations(_ keys: [Destination]) {
        for key in keys {
            roots.remove(key)
            for prefix in key.prefixes {
                if subtreeCounts[prefix] == 1 { subtreeCounts.removeValue(forKey: prefix) }
                else { subtreeCounts[prefix]? -= 1 }
            }
        }
    }

    private init() {}

    func claim(_ routeID: String) -> Bool {
        claim([routeID])
    }

    func claim(_ routeIDs: Set<String>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRouteIDs.isDisjoint(with: routeIDs) else { return false }
        activeRouteIDs.formUnion(routeIDs)
        return true
    }

    func release(_ routeIDs: Set<String>) {
        lock.lock()
        activeRouteIDs.subtract(routeIDs)
        lock.unlock()
    }
}

public enum CrossDeviceConflictResolution: Equatable, Sendable {
    case keepBoth
    case replace
    case skip
}

public struct CrossDeviceConflictDecision: Equatable, Sendable {
    public let resolution: CrossDeviceConflictResolution
    public let applyToAll: Bool

    public init(resolution: CrossDeviceConflictResolution, applyToAll: Bool) {
        self.resolution = resolution
        self.applyToAll = applyToAll
    }
}

public enum CrossDeviceTransferStatus: Equatable, Sendable {
    case resolving
    case copying
    case downloading
    case uploading
    case completed
    case skipped
    case cancelled
    case cancellationFailed(String)
    case failed(String)
}

@MainActor
public struct CrossDeviceRemoteEndpoint {
    public let runtimeID: String
    public let title: String
    public let protocolName: String
    public let context: TunnelLiveSessionContext
    public let bridge: RemoteFilesBridging
    public let transferScheduler: SCPTransferScheduling

    public init(
        runtimeID: String,
        title: String,
        protocolName: String = "sftp",
        context: TunnelLiveSessionContext,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling
    ) {
        self.runtimeID = runtimeID
        self.title = title
        self.protocolName = protocolName
        self.context = context
        self.bridge = bridge
        self.transferScheduler = transferScheduler
    }

    fileprivate func isSameHost(as other: CrossDeviceRemoteEndpoint) -> Bool {
        context.config.host.caseInsensitiveCompare(other.context.config.host) == .orderedSame
            && context.config.port == other.context.config.port
            && context.config.username == other.context.config.username
    }
}

@MainActor
public final class CrossDeviceTransferCoordinator {
    private struct ResolvedItem: Sendable {
        let selection: RemoteFileSelection
        let destinationPath: String
        let replacesExistingItem: Bool
    }

    private struct DirectTransferRoot: Sendable {
        let item: ResolvedItem
        let transferDestinationPath: String
        let replacement: DirectTransferReplacement?
    }

    private struct DirectTransferReplacement: Sendable {
        let stagingPath: String
        let destinationPath: String
        let isDirectory: Bool
        let index: Int
        // Fresh trees start empty. For a recovered tree, verify every directory before publication.
        var recoveredContents: RecoveryManifest? = nil
    }

    // Linux SFTP names can look identical while denoting different directory entries.
    private typealias RecoveryManifest = [Data: [Data: RemoteFileKind]]

    private struct DirectTransferPlan: Sendable {
        let items: [ResolvedItem]
        let replacements: [DirectTransferReplacement]
        let replacementIndexByItem: [Int: Int]
    }

    @MainActor private final class DirectoryCommit {
        nonisolated let workers = DispatchGroup()
        var expected = 0
        // Written on main before each worker leaves; read after group notification.
        var staged: [RemoteToRemoteTransferReport] = []
    }

    private struct StagedMoveItem: Sendable {
        let item: ResolvedItem
        let temporaryPath: String
    }

    private struct WorkerEndpoint: @unchecked Sendable {
        let title: String
        let protocolName: String
        let context: TunnelLiveSessionContext
        let bridge: RemoteFilesBridging

        @MainActor
        init(_ endpoint: CrossDeviceRemoteEndpoint) {
            title = endpoint.title
            protocolName = endpoint.protocolName
            context = endpoint.context
            bridge = endpoint.bridge
        }
    }

    private final class ActiveOperation: @unchecked Sendable {
        let id: UUID
        let source: CrossDeviceRemoteEndpoint
        let destination: CrossDeviceRemoteEndpoint
        let operation: CrossDeviceTransferOperation
        let selections: [RemoteFileSelection]
        let startedAt: TimeInterval
        let statusHandler: (CrossDeviceTransferStatus) -> Void
        var items: [ResolvedItem] = []
        var currentItemIndex = 0
        var relayDirectory: URL?
        var activeJobs: [(scheduler: SCPTransferScheduling, jobID: String)] = []
        var activeDirectJobIDs: Set<String> = []
        var startedDirectJobIDs: Set<String> = []  // Accessed on the main queue.
        private var cancelled = false
        var cancelRequested: Bool {
            get {
                directTransferCondition.lock()
                defer { directTransferCondition.unlock() }
                return cancelled
            }
            set {
                directTransferCondition.lock()
                cancelled = newValue
                directTransferCondition.broadcast()
                directTransferCondition.unlock()
            }
        }
        var remoteTemporaryPaths: Set<String> = []
        var retryDiscarded = false
        var moveRecoveryItems: [ResolvedItem] = []
        var moveRecoveryItemIndex = 0
        var moveRecoveryCompletionStatus: CrossDeviceTransferStatus?
        private let directTransferCondition = NSCondition()
        private var pausedDirectJobs = Set<String>()
        private var stoppedDirectJobs = Set<String>()
        // Main queue only. A paused attempt can still be returning from Rust.
        var drainingPauses = Set<String>()

        init(
            id: UUID,
            source: CrossDeviceRemoteEndpoint,
            destination: CrossDeviceRemoteEndpoint,
            operation: CrossDeviceTransferOperation,
            selections: [RemoteFileSelection],
            startedAt: TimeInterval,
            statusHandler: @escaping (CrossDeviceTransferStatus) -> Void
        ) {
            self.id = id
            self.source = source
            self.destination = destination
            self.operation = operation
            self.selections = selections
            self.startedAt = startedAt
            self.statusHandler = statusHandler
        }

        deinit {
            CrossDeviceDirectRouteRegistry.shared.releaseDestinations(owner: id)
            CrossDeviceDirectRouteRegistry.shared.release(activeDirectJobIDs)
        }

        func pauseDirectTransfer(jobID: String) -> Bool {
            directTransferCondition.lock()
            defer { directTransferCondition.unlock() }
            return !cancelled && pausedDirectJobs.insert(jobID).inserted
        }

        @discardableResult
        func resumeDirectTransfer(jobID: String) -> Bool {
            directTransferCondition.lock()
            defer { directTransferCondition.unlock() }
            let wasPaused = pausedDirectJobs.remove(jobID) != nil
            directTransferCondition.broadcast()
            return wasPaused
        }

        func waitUntilRunnable(jobID: String) -> Bool {
            directTransferCondition.lock()
            defer { directTransferCondition.unlock() }
            while pausedDirectJobs.contains(jobID), !cancelled, !stoppedDirectJobs.contains(jobID) {
                directTransferCondition.wait()
            }
            return !cancelled && !stoppedDirectJobs.contains(jobID)
        }

        func canStartDirectTransfer(jobID: String) -> Bool {
            directTransferCondition.lock()
            defer { directTransferCondition.unlock() }
            return !cancelled && !pausedDirectJobs.contains(jobID) && !stoppedDirectJobs.contains(jobID)
        }

        // Runs on the main queue, serialized with slot admission and worker retirement.
        func stopDirectTransfer(jobID: String, using bridge: RemoteToRemoteTransferBridging?) -> Bool {
            if startedDirectJobIDs.contains(jobID), !drainingPauses.contains(jobID),
               bridge?.cancelLiveRemoteToRemoteTransfer(jobID: jobID) != true { return false }
            directTransferCondition.lock()
            defer { directTransferCondition.unlock() }
            guard !cancelled, stoppedDirectJobs.insert(jobID).inserted else { return false }
            directTransferCondition.broadcast()
            return true
        }

        func hasStoppedDirectTransfer(_ jobID: String? = nil) -> Bool {
            directTransferCondition.lock()
            defer { directTransferCondition.unlock() }
            return jobID.map(stoppedDirectJobs.contains) ?? !stoppedDirectJobs.isEmpty
        }

        // Called on the main queue, which serializes pause, cancel and retirement.
        @discardableResult
        func cancelDirectTransfers(using bridge: RemoteToRemoteTransferBridging?, selectedJobID: String? = nil) -> Bool {
            let live = startedDirectJobIDs.subtracting(drainingPauses).filter { !hasStoppedDirectTransfer($0) }
            var accepted = selectedJobID.map { !live.contains($0) } ?? true
            for id in live {
                if bridge?.cancelLiveRemoteToRemoteTransfer(jobID: id) == true { accepted = true }
            }
            if accepted { cancelRequested = true }
            return accepted
        }

    }

    private let fileManager: FileManager
    private let relayDirectoryProvider: () -> URL
    private let remoteTransferBridge: RemoteToRemoteTransferBridging?
    private let completionNotificationPresenter: TransferCompletionNotificationPresenting
    private let nowProvider: () -> Date
    private let monotonicTimeProvider: () -> TimeInterval
    private let workQueue: DispatchQueue
    private var activeOperations: [UUID: ActiveOperation] = [:]

    public init(
        fileManager: FileManager = .default,
        relayDirectoryProvider: @escaping () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("StacioCrossDeviceTransfers", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        },
        remoteTransferBridge: RemoteToRemoteTransferBridging? = nil,
        completionNotificationPresenter: TransferCompletionNotificationPresenting? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        monotonicTimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.fileManager = fileManager
        self.relayDirectoryProvider = relayDirectoryProvider
        self.remoteTransferBridge = remoteTransferBridge
        self.completionNotificationPresenter = completionNotificationPresenter
            ?? NoopTransferCompletionNotificationPresenter()
        self.nowProvider = nowProvider
        self.monotonicTimeProvider = monotonicTimeProvider
        self.workQueue = DispatchQueue(
            label: "com.stacio.files.cross-device-transfer",
            qos: .userInitiated
        )
    }

    @discardableResult
    public func transfer(
        _ selections: [RemoteFileSelection],
        from source: CrossDeviceRemoteEndpoint,
        to destination: CrossDeviceRemoteEndpoint,
        destinationDirectory: String,
        operation: CrossDeviceTransferOperation,
        conflictResolution: CrossDeviceConflictResolution,
        statusHandler: @escaping (CrossDeviceTransferStatus) -> Void
    ) -> UUID {
        transfer(
            selections,
            from: source,
            to: destination,
            destinationDirectory: destinationDirectory,
            operation: operation,
            conflictDecisionProvider: { _ in
                CrossDeviceConflictDecision(
                    resolution: conflictResolution,
                    applyToAll: true
                )
            },
            statusHandler: statusHandler
        )
    }

    @discardableResult
    public func transfer(
        _ selections: [RemoteFileSelection],
        from source: CrossDeviceRemoteEndpoint,
        to destination: CrossDeviceRemoteEndpoint,
        destinationDirectory: String,
        operation: CrossDeviceTransferOperation,
        conflictDecisionProvider: @escaping (String) -> CrossDeviceConflictDecision?,
        statusHandler: @escaping (CrossDeviceTransferStatus) -> Void
    ) -> UUID {
        let operationID = UUID()
        let active = ActiveOperation(
            id: operationID,
            source: source,
            destination: destination,
            operation: operation,
            selections: selections,
            startedAt: monotonicTimeProvider(),
            statusHandler: statusHandler
        )
        activeOperations[operationID] = active
        guard selections.isEmpty == false else {
            finish(active, status: .completed)
            return operationID
        }

        statusHandler(.resolving)
        resolveDestinations(
            selections: selections,
            destinationDirectory: Self.normalizedRemoteDirectory(destinationDirectory),
            conflictDecisionProvider: conflictDecisionProvider,
            operation: active
        )
        return operationID
    }

    @discardableResult
    public func cancel(operationID: UUID) -> Bool {
        guard let operation = activeOperations[operationID], operation.cancelRequested == false else {
            return false
        }
        operation.cancelDirectTransfers(using: remoteTransferBridge)
        for activeJob in operation.activeJobs {
            guard activeJob.scheduler.cancelTransfer(jobID: activeJob.jobID) else {
                operation.statusHandler(.cancellationFailed("传输队列未接受取消请求，请重试。"))
                return false
            }
        }
        return true
    }

    @discardableResult
    public func cancelOperations(involvingRuntimeIDs runtimeIDs: Set<String>) -> [UUID] {
        guard runtimeIDs.isEmpty == false else { return [] }
        let operationIDs = activeOperations.values
            .filter {
                runtimeIDs.contains($0.source.runtimeID)
                    || runtimeIDs.contains($0.destination.runtimeID)
            }
            .map(\.id)
        return operationIDs.filter { cancel(operationID: $0) }
    }

    private func resolveDestinations(
        selections: [RemoteFileSelection],
        destinationDirectory: String,
        conflictDecisionProvider: @escaping (String) -> CrossDeviceConflictDecision?,
        operation: ActiveOperation
    ) {
        let operationBox = CrossDeviceUncheckedSendableBox(operation)
        let destination = WorkerEndpoint(operation.destination)
        let source = WorkerEndpoint(operation.source)
        let sourceAndDestinationShareEndpoint = operation.source.isSameHost(as: operation.destination)
        let conflictDecisionProviderBox = CrossDeviceUncheckedSendableBox(conflictDecisionProvider)
        workQueue.async { [weak self] in
            guard let self else { return }
            let operation = operationBox.value
            do {
                let context = destination.context
                let entries = try destination.bridge.listLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: destinationDirectory
                )
                var existingNames = Set(entries.map { ($0.path as NSString).lastPathComponent })
                var resolved: [ResolvedItem] = []
                var appliedResolution: CrossDeviceConflictResolution?
                var skippedMoveItem = false
                for selection in selections {
                    let originalName = (selection.path as NSString).lastPathComponent
                    guard originalName.isEmpty == false else { continue }
                    let hasConflict = existingNames.contains(originalName)
                    let originalDestinationPath = Self.join(destinationDirectory, originalName)
                    if sourceAndDestinationShareEndpoint,
                       Self.comparableRemotePath(selection.path)
                        == Self.comparableRemotePath(originalDestinationPath)
                    {
                        throw CrossDeviceTransferError.sourceEqualsDestination(selection.path)
                    }
                    let resolution: CrossDeviceConflictResolution
                    if hasConflict {
                        if let appliedResolution {
                            resolution = appliedResolution
                        } else if let decision = conflictDecisionProviderBox.value(originalDestinationPath) {
                            resolution = decision.resolution
                            if decision.applyToAll { appliedResolution = decision.resolution }
                        } else {
                            resolution = .skip
                        }
                    } else {
                        resolution = .replace
                    }
                    switch resolution {
                    case .skip where hasConflict:
                        skippedMoveItem = skippedMoveItem || operation.operation == .move
                        continue
                    case .keepBoth where hasConflict:
                        let uniqueName = Self.uniqueRemoteName(originalName, existingNames: existingNames)
                        existingNames.insert(uniqueName)
                        resolved.append(ResolvedItem(
                            selection: selection,
                            destinationPath: Self.join(destinationDirectory, uniqueName),
                            replacesExistingItem: false
                        ))
                    default:
                        existingNames.insert(originalName)
                        resolved.append(ResolvedItem(
                            selection: selection,
                            destinationPath: Self.join(destinationDirectory, originalName),
                            replacesExistingItem: hasConflict && resolution == .replace
                        ))
                    }
                }
                if operation.operation == .move, skippedMoveItem == false {
                    try Self.preflightMoveSources(
                        resolved.map(\.selection),
                        source: source
                    )
                }
                if skippedMoveItem {
                    resolved.removeAll()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.activeOperations[operation.id] === operation,
                          operation.cancelRequested == false
                    else {
                        if operation.cancelRequested {
                            self?.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                        }
                        return
                    }
                    operation.items = resolved
                    guard resolved.isEmpty == false else {
                        self.finish(operation, status: .skipped)
                        return
                    }
                    if self.remoteTransferBridge != nil {
                        self.performDirectRemoteTransfer(operation)
                    } else if operation.source.isSameHost(as: operation.destination) {
                        self.performSameHostTransfer(operation)
                    } else {
                        self.prepareRelay(operation)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if operation.cancelRequested {
                        self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                    } else {
                        self.cleanupRemoteTemporaryItemsAndFinish(
                            operation,
                            status: .failed(error.localizedDescription)
                        )
                    }
                }
            }
        }
    }

    private func performSameHostTransfer(_ operation: ActiveOperation) {
        operation.statusHandler(.copying)
        let operationBox = CrossDeviceUncheckedSendableBox(operation)
        let source = WorkerEndpoint(operation.source)
        let transferItems = operation.items.enumerated().map { index, item in
            (
                item: item,
                stagingPath: item.replacesExistingItem
                    ? Self.temporaryRemotePath(for: item, operation: operation, index: index)
                    : nil,
                index: index
            )
        }
        operation.remoteTemporaryPaths.formUnion(transferItems.compactMap(\.stagingPath))
        workQueue.async { [weak self] in
            guard let self else { return }
            let operation = operationBox.value
            var promotedTemporaryPaths: [String] = []
            do {
                for transferItem in transferItems {
                    guard operation.cancelRequested == false else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            operation.remoteTemporaryPaths.subtract(promotedTemporaryPaths)
                            self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                        }
                        return
                    }
                    let item = transferItem.item
                    let destinationPath = transferItem.stagingPath ?? item.destinationPath
                    try source.bridge.copyLiveRemotePath(
                        config: source.context.config,
                        secret: source.context.secret,
                        expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                        fromPath: item.selection.path,
                        toPath: destinationPath
                    )
                    guard operation.cancelRequested == false else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            operation.remoteTemporaryPaths.subtract(promotedTemporaryPaths)
                            self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                        }
                        return
                    }
                    if let stagingPath = transferItem.stagingPath {
                        try Self.promoteRemoteReplacement(
                            stagingPath: stagingPath,
                            destinationPath: item.destinationPath,
                            isDirectory: item.selection.isDirectory,
                            operationID: operation.id,
                            index: transferItem.index,
                            endpoint: source
                        )
                        promotedTemporaryPaths.append(stagingPath)
                    }
                    guard operation.cancelRequested == false else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            operation.remoteTemporaryPaths.subtract(promotedTemporaryPaths)
                            self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                        }
                        return
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    operation.remoteTemporaryPaths.subtract(promotedTemporaryPaths)
                    if operation.cancelRequested {
                        self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                    } else if operation.operation == .move {
                        self.commitMoveSources(operation)
                    } else {
                        self.finish(operation, status: .completed)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    operation.remoteTemporaryPaths.subtract(promotedTemporaryPaths)
                    self.cleanupRemoteTemporaryItemsAndFinish(
                        operation,
                        status: .failed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private func performDirectRemoteTransfer(_ operation: ActiveOperation) {
        guard let bridge = remoteTransferBridge else {
            prepareRelay(operation)
            return
        }
        operation.statusHandler(.copying)
        let source = WorkerEndpoint(operation.source)
        let destination = WorkerEndpoint(operation.destination)
        let roots = operation.items.enumerated().map { index, item in
            let replacement: DirectTransferReplacement?
            if item.selection.isDirectory, item.replacesExistingItem {
                let stagingPath = Self.stableDirectReplacementPath(
                    for: item,
                    source: source,
                    destination: destination
                )
                replacement = DirectTransferReplacement(
                    stagingPath: stagingPath,
                    destinationPath: item.destinationPath,
                    isDirectory: true,
                    index: index
                )
            } else {
                replacement = nil
            }
            return DirectTransferRoot(
                item: item,
                transferDestinationPath: replacement?.stagingPath ?? item.destinationPath,
                replacement: replacement
            )
        }
        let destinations = roots.flatMap { root in
            [root.item.destinationPath] + (root.replacement.map { [$0.stagingPath] } ?? [])
        }
        guard CrossDeviceDirectRouteRegistry.shared.reserve(destinations, on: destination.context.config, owner: operation.id) else {
            finish(operation, status: .failed("目标路径与正在传输的项目冲突，请在任务结束后重试。"))
            return
        }
        let bridgeBox = CrossDeviceUncheckedSendableBox(bridge)
        workQueue.async { [weak self, weak operation] in
            guard let self, let operation else { return }
            var createdStaging = Set<String>()
            do {
                let plan = try Self.expandDirectRemoteItems(
                    roots,
                    source: source,
                    destination: destination,
                    isCancelled: { operation.cancelRequested }, createdStaging: &createdStaging
                )
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self, let operation else { return }
                    guard self.activeOperations[operation.id] === operation else { return }
                    guard operation.cancelRequested == false else {
                        operation.remoteTemporaryPaths.formUnion(createdStaging)
                        self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                        return
                    }
                    self.startDirectRemoteTransfer(
                        operation,
                        plan: plan,
                        bridge: bridgeBox.value
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self, let operation else { return }
                    operation.remoteTemporaryPaths.formUnion(createdStaging)
                    if operation.cancelRequested {
                        self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                    } else {
                        self.cleanupRemoteTemporaryItemsAndFinish(
                            operation,
                            status: .failed(error.localizedDescription)
                        )
                    }
                }
            }
        }
    }

    private func startDirectRemoteTransfer(
        _ operation: ActiveOperation,
        plan: DirectTransferPlan,
        bridge: RemoteToRemoteTransferBridging
    ) {
        let items = plan.items
        let source = WorkerEndpoint(operation.source)
        let destination = WorkerEndpoint(operation.destination)
        let sourceProtocol: RemoteTransferProtocol =
            source.protocolName.lowercased().contains("scp") ? .scp : .sftp
        let destinationProtocol: RemoteTransferProtocol =
            destination.protocolName.lowercased().contains("scp") ? .scp : .sftp
        let bridgeBox = CrossDeviceUncheckedSendableBox(bridge)
        let queueCoordinator = (operation.destination.transferScheduler as? TransferQueueCoordinatorProviding)?
            .transferQueueCoordinator
            ?? (operation.source.transferScheduler as? TransferQueueCoordinatorProviding)?.transferQueueCoordinator
        let limiter = DispatchSemaphore(value: min(2, max(1, items.count)))
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        var completedCount = 0
        let commits = Dictionary(uniqueKeysWithValues: plan.replacements.map { ($0.index, DirectoryCommit()) })

        for (index, item) in items.enumerated() {
            let commit = plan.replacementIndexByItem[index].flatMap { commits[$0] }
            commit?.expected += 1
            let jobID = Self.stableDirectJobID(
                source: source,
                destination: destination,
                item: item
            )
            guard CrossDeviceDirectRouteRegistry.shared.claim(jobID) else {
                lock.lock()
                failures.append("相同的远端传输任务正在进行，请等待当前任务完成后重试。")
                lock.unlock()
                continue
            }
            operation.activeDirectJobIDs.insert(jobID)
            let job = ScpTransferJob(
                id: jobID,
                direction: .upload,
                sourcePath: item.selection.path,
                destinationPath: item.destinationPath,
                bytesTotal: item.selection.size
            )
            let registered = queueCoordinator?.registerExternalTransfer(
                runtimeID: operation.destination.runtimeID,
                job: job,
                notificationPolicy: .silent,
                startsQueued: true,
                progressProvider: { [weak bridge] in
                    let samples = bridge?.takeLiveRemoteToRemoteTransferProgressBatch(jobID: jobID) ?? []
                    // Transport completion for a staged file is not directory completion.
                    return commit == nil ? samples : samples.filter { $0.status != "completed" }
                },
                resume: { [weak operation] in
                    operation?.resumeDirectTransfer(jobID: jobID) ?? false
                },
                cancel: { [weak operation, weak bridge] in
                    guard let operation, operation.cancelRequested == false else { return false }
                    return operation.cancelDirectTransfers(using: bridge, selectedJobID: jobID)
                },
                stop: { [weak operation, weak bridge] in
                    operation?.stopDirectTransfer(jobID: jobID, using: bridge) ?? false
                },
                pauseWithProgress: { [weak operation, weak bridge] in
                    guard let operation, let bridge, operation.pauseDirectTransfer(jobID: jobID) else { return nil }
                    guard operation.startedDirectJobIDs.contains(jobID),
                          !operation.drainingPauses.contains(jobID) else { return [] }
                    let receipt: [ScpTransferProgress]?
                    if let reporter = bridge as? TransferPauseReporting {
                        receipt = reporter.pauseWithProgress(jobID: jobID)
                    } else {
                        receipt = bridge.cancelLiveRemoteToRemoteTransfer(jobID: jobID) ? [] : nil
                    }
                    if receipt == nil {
                        operation.resumeDirectTransfer(jobID: jobID)
                    } else {
                        operation.drainingPauses.insert(jobID)
                    }
                    return receipt
                }
            )
            if registered == false {
                lock.lock()
                failures.append("相同的远端传输任务正在进行，请等待当前任务完成后重试。")
                lock.unlock()
                continue
            }
            group.enter()
            commit?.workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { commit?.workers.leave(); group.leave() }
                let request = RemoteToRemoteTransferRequest(
                    job: job,
                    sourceProtocol: sourceProtocol,
                    destinationProtocol: destinationProtocol,
                    requestedOffset: 0,
                    forceRestart: false,
                    chunkSizeBytes: 1 * 1_024 * 1_024,
                    workerCount: 4
                )
                while operation.waitUntilRunnable(jobID: jobID) {
                    limiter.wait()
                    defer { limiter.signal() }
                    let acquired = DispatchQueue.main.sync {
                        guard operation.canStartDirectTransfer(jobID: jobID) else { return false }
                        operation.startedDirectJobIDs.insert(jobID)
                        queueCoordinator?.acquireExternalSlot(jobID: jobID)
                        return true
                    }
                    guard acquired else { continue }
                    // Once admitted, always enter the transport so it observes a
                    // preflight pause/cancel. This slot belongs to one attempt only.
                    let result = Result {
                        try bridgeBox.value.runLiveRemoteToRemoteTransfer(
                            sourceConfig: source.context.config,
                            sourceSecret: source.context.secret,
                            sourceExpectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                            destinationConfig: destination.context.config,
                            destinationSecret: destination.context.secret,
                            destinationExpectedFingerprintSHA256: destination.context.expectedFingerprintSHA256,
                            request: request
                        )
                    }
                    let shouldRequeue = DispatchQueue.main.sync {
                        operation.startedDirectJobIDs.remove(jobID)
                        bridgeBox.value.retireRemoteTransferAttempt(jobID: jobID)
                        let wasPaused = operation.drainingPauses.remove(jobID) != nil
                        if operation.hasStoppedDirectTransfer(jobID) { return false }
                        switch result {
                        case let .success(report):
                            lock.lock()
                            completedCount += 1
                            lock.unlock()
                            if let commit {
                                commit.staged.append(report)
                                queueCoordinator?.awaitDirectoryCommit(jobID: jobID, bytesDone: report.bytesDone, resumedFrom: report.resumedFrom)
                            } else {
                                queueCoordinator?.finishExternalTransfer(jobID: jobID, status: "completed",
                                    bytesDone: report.bytesDone, resumedFrom: report.resumedFrom)
                            }
                        case .failure where operation.cancelRequested:
                            queueCoordinator?.finishExternalTransfer(jobID: jobID, status: "canceled", bytesDone: 0)
                        case .failure where wasPaused:
                            return true
                        case let .failure(error):
                            lock.lock()
                            failures.append(error.localizedDescription)
                            lock.unlock()
                            queueCoordinator?.finishExternalTransfer(jobID: jobID, status: "failed",
                                bytesDone: 0, diagnostic: error.localizedDescription)
                        }
                        return false
                    }
                    if !shouldRequeue { return }
                }
                guard !operation.hasStoppedDirectTransfer(jobID) else { return }
                DispatchQueue.main.async { [weak queueCoordinator] in
                    queueCoordinator?.finishExternalTransfer(jobID: jobID, status: "canceled", bytesDone: 0)
                }
            }
        }

        for replacement in plan.replacements {
            guard let commit = commits[replacement.index] else { continue }
            group.enter()
            commit.workers.notify(queue: workQueue) {
                var status = "canceled"
                var message: String? = "目录未替换，已保留原目标。"
                let canCommit = DispatchQueue.main.sync { commit.staged.count == commit.expected }
                if !operation.cancelRequested && canCommit {
                    do {
                        if let contents = replacement.recoveredContents {
                            try Self.verifyRecoveredDirectory(replacement.stagingPath, contents: contents,
                                endpoint: destination, isCancelled: { operation.cancelRequested })
                        }
                        guard !operation.cancelRequested else { throw CrossDeviceTransferError.transferCancelled }
                        try Self.promoteRemoteReplacement(
                            stagingPath: replacement.stagingPath,
                            destinationPath: replacement.destinationPath,
                            isDirectory: replacement.isDirectory,
                            operationID: operation.id,
                            index: replacement.index,
                            endpoint: destination
                        )
                        status = "completed"
                        message = nil
                    } catch {
                        status = "failed"
                        message = error.localizedDescription
                        lock.lock()
                        failures.append(error.localizedDescription)
                        lock.unlock()
                    }
                }
                DispatchQueue.main.sync {
                    for report in commit.staged {
                        queueCoordinator?.finishExternalTransfer(jobID: report.jobId, status: status,
                            bytesDone: report.bytesDone, diagnostic: message)
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: workQueue) { [weak self, weak operation] in
            guard let self, let operation else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, let operation,
                      self.activeOperations[operation.id] === operation
                else { return }
                if operation.cancelRequested || (failures.isEmpty && operation.hasStoppedDirectTransfer()) {
                    self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                } else if failures.isEmpty == false {
                    self.cleanupRemoteTemporaryItemsAndFinish(
                        operation,
                        status: .failed(failures.first ?? "远端到远端传输失败。")
                    )
                } else if completedCount == items.count {
                    if operation.operation == .move {
                        self.commitMoveSources(operation)
                    } else {
                        self.finish(operation, status: .completed)
                    }
                } else {
                    self.cleanupRemoteTemporaryItemsAndFinish(
                        operation,
                        status: .failed("远端到远端传输未完成。")
                    )
                }
            }
        }
    }

    private nonisolated static func expandDirectRemoteItems(
        _ roots: [DirectTransferRoot],
        source: WorkerEndpoint,
        destination: WorkerEndpoint,
        isCancelled: () -> Bool, createdStaging: inout Set<String>
    ) throws -> DirectTransferPlan {
        var expanded: [ResolvedItem] = []
        var replacements: [DirectTransferReplacement] = []
        var replacementIndexByItem: [Int: Int] = [:]
        for transferRoot in roots {
            guard isCancelled() == false else {
                throw CrossDeviceTransferError.transferCancelled
            }
            let item = transferRoot.item
            if item.selection.isFile {
                expanded.append(ResolvedItem(
                    selection: item.selection,
                    destinationPath: transferRoot.transferDestinationPath,
                    replacesExistingItem: false
                ))
                continue
            }
            let root = item.selection.path
            let destinationRoot = transferRoot.transferDestinationPath
            var contents: RecoveryManifest?
            if transferRoot.replacement != nil,
               let existing = try listRemoteDirectory((destinationRoot as NSString).deletingLastPathComponent, endpoint: destination)
                    .first(where: { $0.path.utf8.elementsEqual(destinationRoot.utf8) }) {
                guard existing.kind == .directory else { throw CrossDeviceTransferError.remoteReplacementFailed("暂存路径不是目录。") }
                contents = [:]
            }
            try createRemoteDirectory(destinationRoot, endpoint: destination)
            if transferRoot.replacement != nil && contents == nil {
                createdStaging.insert(destinationRoot)
            }
            let start = expanded.count
            try appendDirectRemoteChildren(
                sourcePath: root,
                destinationPath: destinationRoot,
                source: source,
                destination: destination,
                into: &expanded,
                recoveredContents: &contents,
                isCancelled: isCancelled
            )
            if var replacement = transferRoot.replacement {
                replacement.recoveredContents = contents
                replacements.append(replacement)
                for i in start..<expanded.count { replacementIndexByItem[i] = replacement.index }
            }
        }
        return DirectTransferPlan(items: expanded, replacements: replacements, replacementIndexByItem: replacementIndexByItem)
    }

    private nonisolated static func appendDirectRemoteChildren(
        sourcePath: String,
        destinationPath: String,
        source: WorkerEndpoint,
        destination: WorkerEndpoint,
        into items: inout [ResolvedItem],
        recoveredContents: inout RecoveryManifest?,
        isCancelled: () -> Bool
    ) throws {
        guard isCancelled() == false else {
            throw CrossDeviceTransferError.transferCancelled
        }
        let entries = try listRemoteDirectory(sourcePath, endpoint: source)
        if recoveredContents != nil {
            var expected: [Data: RemoteFileKind] = [:]
            for entry in entries where entry.kind == .file || entry.kind == .directory {
                expected[Data((entry.path as NSString).lastPathComponent.utf8)] = entry.kind
            }
            recoveredContents?[Data(destinationPath.utf8)] = expected
            // Clear type conflicts before creating directories or opening any file in the recovered tree.
            for entry in try listRemoteDirectory(destinationPath, endpoint: destination) {
                if let kind = expected[Data((entry.path as NSString).lastPathComponent.utf8)], kind != entry.kind {
                    try removeStagedEntry(entry, from: destinationPath, endpoint: destination)
                }
            }
        }
        for entry in entries {
            guard isCancelled() == false else {
                throw CrossDeviceTransferError.transferCancelled
            }
            let name = (entry.path as NSString).lastPathComponent
            guard name.isEmpty == false else { continue }
            let destinationChild = Self.join(destinationPath, name)
            let selection = RemoteFileSelection(
                path: entry.path,
                size: entry.kind == .symlink ? 0 : entry.size,
                kind: entry.kind,
                modifiedTime: entry.modifiedTime
            )
            if selection.isDirectory {
                try createRemoteDirectory(destinationChild, endpoint: destination)
                try appendDirectRemoteChildren(
                    sourcePath: entry.path,
                    destinationPath: destinationChild,
                    source: source,
                    destination: destination,
                    into: &items,
                    recoveredContents: &recoveredContents,
                    isCancelled: isCancelled
                )
            } else if selection.isFile {
                items.append(ResolvedItem(
                    selection: selection,
                    destinationPath: destinationChild,
                    replacesExistingItem: false
                ))
            }
        }
    }

    private nonisolated static func verifyRecoveredDirectory(
        _ path: String, contents: RecoveryManifest, endpoint: WorkerEndpoint,
        isCancelled: () -> Bool
    ) throws {
        guard !isCancelled() else { throw CrossDeviceTransferError.transferCancelled }
        guard var missing = contents[Data(path.utf8)] else { throw CrossDeviceTransferError.remoteReplacementFailed("缺少暂存目录清单。") }
        for entry in try listRemoteDirectory(path, endpoint: endpoint) {
            guard !isCancelled() else { throw CrossDeviceTransferError.transferCancelled }
            let name = (entry.path as NSString).lastPathComponent
            guard let expected = missing.removeValue(forKey: Data(name.utf8)) else {
                try removeStagedEntry(entry, from: path, endpoint: endpoint)
                continue
            }
            guard entry.kind == expected else { throw CrossDeviceTransferError.remoteReplacementFailed("暂存条目类型不符：\(entry.path)") }
            if expected == .directory {
                try verifyRecoveredDirectory(join(path, name), contents: contents, endpoint: endpoint, isCancelled: isCancelled)
            }
        }
        guard missing.isEmpty else { throw CrossDeviceTransferError.remoteReplacementFailed("暂存目录缺少预期条目：\(path)") }
    }

    private nonisolated static func removeStagedEntry(_ entry: RemoteFileEntry, from parent: String, endpoint: WorkerEndpoint) throws {
        let name = (entry.path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", entry.path.utf8.elementsEqual(join(parent, name).utf8) else {
            throw CrossDeviceTransferError.remoteReplacementFailed("暂存目录返回了无效的子路径。")
        }
        try endpoint.bridge.deleteLiveRemotePath(config: endpoint.context.config, secret: endpoint.context.secret,
            expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256, remotePath: entry.path, recursive: entry.kind == .directory)
    }

    private nonisolated static func listRemoteDirectory(
        _ path: String,
        endpoint: WorkerEndpoint
    ) throws -> [RemoteFileEntry] {
        return try endpoint.bridge.listLiveRemoteDirectory(
            config: endpoint.context.config,
            secret: endpoint.context.secret,
            expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256,
            remotePath: path
        )
    }

    private nonisolated static func createRemoteDirectory(
        _ path: String,
        endpoint: WorkerEndpoint
    ) throws {
        try endpoint.bridge.createLiveRemoteDirectory(
            config: endpoint.context.config,
            secret: endpoint.context.secret,
            expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256,
            remotePath: path
        )
    }

    private func prepareRelay(_ operation: ActiveOperation) {
        let relayDirectory = relayDirectoryProvider().standardizedFileURL
        operation.relayDirectory = relayDirectory
        let fileManagerBox = CrossDeviceUncheckedSendableBox(fileManager)
        workQueue.async { [weak self, weak operation] in
            guard let self, let operation else { return }
            do {
                try fileManagerBox.value.createDirectory(
                    at: relayDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try fileManagerBox.value.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: relayDirectory.path
                )
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self,
                          let operation,
                          self.activeOperations[operation.id] === operation
                    else { return }
                    guard operation.cancelRequested == false else {
                        self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                        return
                    }
                    self.scheduleNextRelayDownload(operation)
                }
            } catch {
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self, let operation else { return }
                    self.cleanupRemoteTemporaryItemsAndFinish(
                        operation,
                        status: .failed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private func scheduleNextRelayDownload(_ operation: ActiveOperation) {
        guard operation.cancelRequested == false else {
            cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
            return
        }
        guard operation.currentItemIndex < operation.items.count else {
            if operation.operation == .move {
                commitMoveSources(operation)
            } else {
                cleanupAndFinish(operation, status: .completed)
            }
            return
        }
        guard let relayDirectory = operation.relayDirectory else {
            cleanupAndFinish(operation, status: .failed("无法创建本机临时中继目录。"))
            return
        }

        let item = operation.items[operation.currentItemIndex]
        scheduleRelayDownload(item, operation: operation, relayDirectory: relayDirectory)
    }

    private func scheduleRelayDownload(
        _ item: ResolvedItem,
        operation: ActiveOperation,
        relayDirectory: URL
    ) {
        operation.statusHandler(.downloading)
        let name = (item.destinationPath as NSString).lastPathComponent
        let localURL = relayDirectory.appendingPathComponent(name, isDirectory: item.selection.isDirectory)
        let job = ScpTransferJob(
            id: "cross_device_download_\(operation.id.uuidString)_\(operation.currentItemIndex)",
            direction: .download,
            sourcePath: item.selection.path,
            destinationPath: localURL.path,
            bytesTotal: item.selection.size
        )
        registerRelayRetry(jobID: job.id, scheduler: operation.source.transferScheduler, operation: operation)
        operation.activeJobs = [(operation.source.transferScheduler, job.id)]
        operation.source.transferScheduler.scheduleLiveTransfer(
            runtimeID: operation.source.runtimeID,
            config: operation.source.context.config,
            secret: operation.source.context.secret,
            expectedFingerprintSHA256: operation.source.context.expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .silent,
            completion: { [weak self, weak operation] progress in
                guard let self, let operation else { return }
                operation.activeJobs = []
                if operation.cancelRequested {
                    self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                    return
                }
                guard progress.status == "completed" else {
                    if Self.isCancellationStatus(progress.status) {
                        operation.source.transferScheduler.unregisterOrchestratedRetry(jobID: job.id)
                    }
                    let status: CrossDeviceTransferStatus = Self.isCancellationStatus(progress.status)
                        ? .cancelled
                        : .failed("从 \(operation.source.title) 下载失败。")
                    self.cleanupRemoteTemporaryItemsAndFinish(operation, status: status)
                    return
                }
                guard Self.validateRelayStage(
                    at: localURL,
                    selection: item.selection,
                    fileManager: self.fileManager
                ) else {
                    self.cleanupRemoteTemporaryItemsAndFinish(
                        operation,
                        status: .failed("本机临时中继校验失败，源文件已保留。")
                    )
                    return
                }
                operation.source.transferScheduler.unregisterOrchestratedRetry(jobID: job.id)
                self.scheduleRelayUpload(item, localURL: localURL, operation: operation)
            }
        )
    }

    private func scheduleRelayUpload(
        _ item: ResolvedItem,
        localURL: URL,
        operation: ActiveOperation
    ) {
        operation.statusHandler(.uploading)
        let uploadDestinationPath = item.replacesExistingItem
            ? Self.temporaryRemotePath(for: item, operation: operation)
            : item.destinationPath
        if item.replacesExistingItem {
            operation.remoteTemporaryPaths.insert(uploadDestinationPath)
        }
        let job = ScpTransferJob(
            id: "cross_device_upload_\(operation.id.uuidString)_\(operation.currentItemIndex)",
            direction: .upload,
            sourcePath: localURL.path,
            destinationPath: uploadDestinationPath,
            bytesTotal: item.selection.size
        )
        registerRelayRetry(jobID: job.id, scheduler: operation.destination.transferScheduler, operation: operation)
        operation.activeJobs = [(operation.destination.transferScheduler, job.id)]
        operation.destination.transferScheduler.scheduleLiveTransfer(
            runtimeID: operation.destination.runtimeID,
            config: operation.destination.context.config,
            secret: operation.destination.context.secret,
            expectedFingerprintSHA256: operation.destination.context.expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .silent,
            completion: { [weak self, weak operation] progress in
                guard let self, let operation else { return }
                operation.activeJobs = []
                if operation.cancelRequested {
                    self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                    return
                }
                guard progress.status == "completed" else {
                    if Self.isCancellationStatus(progress.status) {
                        operation.destination.transferScheduler.unregisterOrchestratedRetry(jobID: job.id)
                    }
                    let status: CrossDeviceTransferStatus = Self.isCancellationStatus(progress.status)
                        ? .cancelled
                        : .failed("上传到 \(operation.destination.title) 失败。")
                    self.cleanupRemoteTemporaryItemsAndFinish(operation, status: status)
                    return
                }
                operation.destination.transferScheduler.unregisterOrchestratedRetry(jobID: job.id)
                if item.replacesExistingItem {
                    self.commitRelayReplacement(
                        item,
                        temporaryPath: uploadDestinationPath,
                        operation: operation
                    )
                } else {
                    operation.currentItemIndex += 1
                    self.scheduleNextRelayDownload(operation)
                }
            }
        )
    }

    private func commitRelayReplacement(
        _ item: ResolvedItem,
        temporaryPath: String,
        operation: ActiveOperation
    ) {
        let destination = WorkerEndpoint(operation.destination)
        workQueue.async { [weak self, weak operation] in
            guard let self, let operation else { return }
            do {
                try Self.promoteRemoteReplacement(
                    stagingPath: temporaryPath,
                    destinationPath: item.destinationPath,
                    isDirectory: item.selection.isDirectory,
                    operationID: operation.id,
                    index: operation.currentItemIndex,
                    endpoint: destination
                )
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self, let operation else { return }
                    operation.remoteTemporaryPaths.remove(temporaryPath)
                    if operation.cancelRequested {
                        self.cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
                    } else {
                        operation.currentItemIndex += 1
                        self.scheduleNextRelayDownload(operation)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let self, let operation else { return }
                    self.cleanupRemoteTemporaryItemsAndFinish(
                        operation,
                        status: .failed("无法原子替换目标文件：\(error.localizedDescription)")
                    )
                }
            }
        }
    }

    private func commitMoveSources(_ operation: ActiveOperation) {
        guard operation.cancelRequested == false else {
            cleanupRemoteTemporaryItemsAndFinish(operation, status: .cancelled)
            return
        }
        let operationBox = CrossDeviceUncheckedSendableBox(operation)
        let source = WorkerEndpoint(operation.source)
        let sourceAndDestinationShareEndpoint = operation.source.isSameHost(as: operation.destination)
        workQueue.async { [weak self] in
            guard let self else { return }
            let operation = operationBox.value
            var stagedItems: [StagedMoveItem] = []
            var stagingError: Error?
            var wasCancelled = false
            for (index, item) in operation.items.enumerated() {
                guard operation.cancelRequested == false else {
                    wasCancelled = true
                    break
                }
                let temporaryPath = Self.temporarySourcePath(
                    for: item,
                    operation: operation,
                    index: index
                )
                do {
                    try source.bridge.renameLiveRemotePath(
                        config: source.context.config,
                        secret: source.context.secret,
                        expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                        fromPath: item.selection.path,
                        toPath: temporaryPath
                    )
                    stagedItems.append(StagedMoveItem(item: item, temporaryPath: temporaryPath))
                } catch {
                    stagingError = error
                    break
                }
                if operation.cancelRequested {
                    wasCancelled = true
                    break
                }
            }

            if stagingError != nil || wasCancelled {
                let rollbackError = Self.rollbackStagedMoveItems(stagedItems, source: source)
                let status: CrossDeviceTransferStatus
                if let rollbackError {
                    status = .failed(
                        "源文件批量提交中止且回滚不完整：\(rollbackError.localizedDescription)"
                    )
                } else if wasCancelled {
                    status = .cancelled
                } else {
                    status = .failed(
                        "源文件批量提交失败，所有源路径已回滚：\(stagingError?.localizedDescription ?? "未知错误")"
                    )
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cleanupRemoteTemporaryItemsAndFinish(operation, status: status)
                }
                return
            }

            var deletedItems: [StagedMoveItem] = []
            var deletionError: Error?
            for staged in stagedItems {
                guard operation.cancelRequested == false else {
                    wasCancelled = true
                    break
                }
                do {
                    try source.bridge.deleteLiveRemotePath(
                        config: source.context.config,
                        secret: source.context.secret,
                        expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                        remotePath: staged.temporaryPath,
                        recursive: staged.item.selection.isDirectory
                    )
                    deletedItems.append(staged)
                } catch {
                    deletionError = error
                    break
                }
                if operation.cancelRequested {
                    wasCancelled = true
                    break
                }
            }

            guard deletionError != nil || wasCancelled else {
                DispatchQueue.main.async { [weak self] in
                    self?.cleanupRemoteTemporaryItemsAndFinish(operation, status: .completed)
                }
                return
            }

            let undeletedItems = Array(stagedItems.dropFirst(deletedItems.count))
            let rollbackError = Self.rollbackStagedMoveItems(undeletedItems, source: source)
            let recoveredStatus: CrossDeviceTransferStatus
            if let rollbackError {
                recoveredStatus = .failed(
                    "源文件删除中止且暂存路径回滚不完整：\(rollbackError.localizedDescription)"
                )
            } else if wasCancelled {
                recoveredStatus = .cancelled
            } else {
                recoveredStatus = .failed(
                    "源文件删除失败，所有源路径已恢复：\(deletionError?.localizedDescription ?? "未知错误")"
                )
            }

            if sourceAndDestinationShareEndpoint {
                let restorationError = Self.restoreDeletedSameHostMoveItems(
                    deletedItems,
                    source: source
                )
                let finalStatus: CrossDeviceTransferStatus
                if let restorationError {
                    finalStatus = .failed(
                        "源文件删除中止且已删除路径恢复不完整：\(restorationError.localizedDescription)"
                    )
                } else {
                    finalStatus = recoveredStatus
                }
                DispatchQueue.main.async { [weak self] in
                    self?.cleanupRemoteTemporaryItemsAndFinish(operation, status: finalStatus)
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.beginRelayMoveSourceRecovery(
                    deletedItems.map(\.item),
                    operation: operation,
                    completionStatus: recoveredStatus
                )
            }
        }
    }

    private nonisolated static func rollbackStagedMoveItems(
        _ stagedItems: [StagedMoveItem],
        source: WorkerEndpoint
    ) -> Error? {
        var rollbackError: Error?
        for staged in stagedItems.reversed() {
            do {
                try source.bridge.renameLiveRemotePath(
                    config: source.context.config,
                    secret: source.context.secret,
                    expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                    fromPath: staged.temporaryPath,
                    toPath: staged.item.selection.path
                )
            } catch {
                rollbackError = rollbackError ?? error
            }
        }
        return rollbackError
    }

    private nonisolated static func restoreDeletedSameHostMoveItems(
        _ deletedItems: [StagedMoveItem],
        source: WorkerEndpoint
    ) -> Error? {
        var restorationError: Error?
        for deleted in deletedItems {
            do {
                try source.bridge.copyLiveRemotePath(
                    config: source.context.config,
                    secret: source.context.secret,
                    expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                    fromPath: deleted.item.destinationPath,
                    toPath: deleted.item.selection.path
                )
            } catch {
                restorationError = restorationError ?? error
            }
        }
        return restorationError
    }

    private func beginRelayMoveSourceRecovery(
        _ items: [ResolvedItem],
        operation: ActiveOperation,
        completionStatus: CrossDeviceTransferStatus
    ) {
        guard activeOperations[operation.id] === operation else { return }
        guard items.isEmpty == false else {
            cleanupRemoteTemporaryItemsAndFinish(operation, status: completionStatus)
            return
        }
        operation.moveRecoveryItems = items
        operation.moveRecoveryItemIndex = 0
        operation.moveRecoveryCompletionStatus = completionStatus
        scheduleNextRelayMoveSourceRecovery(operation)
    }

    private func scheduleNextRelayMoveSourceRecovery(_ operation: ActiveOperation) {
        guard activeOperations[operation.id] === operation else { return }
        guard operation.moveRecoveryItemIndex < operation.moveRecoveryItems.count else {
            let status = operation.moveRecoveryCompletionStatus
                ?? .failed("源文件恢复状态丢失，请检查源路径。")
            operation.moveRecoveryItems = []
            operation.moveRecoveryItemIndex = 0
            operation.moveRecoveryCompletionStatus = nil
            cleanupRemoteTemporaryItemsAndFinish(operation, status: status)
            return
        }
        guard let relayDirectory = operation.relayDirectory else {
            finish(operation, status: .failed("本机中继已丢失，无法恢复已删除的源路径。"))
            return
        }

        let item = operation.moveRecoveryItems[operation.moveRecoveryItemIndex]
        let localURL = Self.relayURL(for: item, in: relayDirectory)
        guard Self.validateRelayStage(
            at: localURL,
            selection: item.selection,
            fileManager: fileManager
        ) else {
            finish(operation, status: .failed("本机中继校验失败，无法恢复已删除的源路径。"))
            return
        }

        operation.statusHandler(.uploading)
        let job = ScpTransferJob(
            id: "cross_device_restore_\(operation.id.uuidString)_\(operation.moveRecoveryItemIndex)",
            direction: .upload,
            sourcePath: localURL.path,
            destinationPath: item.selection.path,
            bytesTotal: item.selection.size
        )
        registerMoveSourceRecoveryRetry(
            jobID: job.id,
            scheduler: operation.source.transferScheduler,
            operation: operation
        )
        operation.activeJobs = [(operation.source.transferScheduler, job.id)]
        operation.source.transferScheduler.scheduleLiveTransfer(
            runtimeID: operation.source.runtimeID,
            config: operation.source.context.config,
            secret: operation.source.context.secret,
            expectedFingerprintSHA256: operation.source.context.expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .silent,
            completion: { [weak self, weak operation] progress in
                guard let self, let operation else { return }
                operation.activeJobs = []
                guard progress.status == "completed" else {
                    self.finish(
                        operation,
                        status: .failed("源路径恢复失败，本机中继已保留，可从传输队列重试。")
                    )
                    return
                }
                operation.source.transferScheduler.unregisterOrchestratedRetry(jobID: job.id)
                operation.moveRecoveryItemIndex += 1
                self.scheduleNextRelayMoveSourceRecovery(operation)
            }
        )
    }

    private func registerMoveSourceRecoveryRetry(
        jobID: String,
        scheduler: SCPTransferScheduling,
        operation: ActiveOperation
    ) {
        scheduler.registerOrchestratedRetry(
            jobID: jobID,
            runtimeIDs: [operation.source.runtimeID, operation.destination.runtimeID],
            retry: { [weak self, operation] in
                self?.retryMoveSourceRecovery(operation) ?? false
            },
            discard: { [weak operation] in
                operation?.retryDiscarded = true
            }
        )
    }

    private func retryMoveSourceRecovery(_ operation: ActiveOperation) -> Bool {
        guard operation.retryDiscarded == false,
              activeOperations[operation.id] == nil,
              operation.moveRecoveryItemIndex < operation.moveRecoveryItems.count,
              operation.relayDirectory != nil
        else { return false }
        operation.activeJobs = []
        activeOperations[operation.id] = operation
        scheduleNextRelayMoveSourceRecovery(operation)
        return true
    }

    private func cleanupRemoteTemporaryItemsAndFinish(
        _ operation: ActiveOperation,
        status: CrossDeviceTransferStatus
    ) {
        guard activeOperations[operation.id] === operation else { return }
        let temporaryPaths = Array(operation.remoteTemporaryPaths)
        guard temporaryPaths.isEmpty == false else {
            cleanupAndFinish(operation, status: status)
            return
        }
        let destination = WorkerEndpoint(operation.destination)
        workQueue.async { [weak self, weak operation] in
            guard let self, let operation else { return }
            var cleanupError: Error?
            for path in temporaryPaths {
                do {
                    try destination.bridge.deleteLiveRemotePath(
                        config: destination.context.config,
                        secret: destination.context.secret,
                        expectedFingerprintSHA256: destination.context.expectedFingerprintSHA256,
                        remotePath: path,
                        recursive: true
                    )
                } catch {
                    cleanupError = cleanupError ?? error
                }
            }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, let operation else { return }
                if let cleanupError {
                    self.cleanupAndFinish(
                        operation,
                        status: .failed(
                            "远端临时文件清理失败，可重试：\(cleanupError.localizedDescription)"
                        )
                    )
                } else {
                    operation.remoteTemporaryPaths.subtract(temporaryPaths)
                    self.cleanupAndFinish(operation, status: status)
                }
            }
        }
    }

    private func cleanupAndFinish(_ operation: ActiveOperation, status: CrossDeviceTransferStatus) {
        guard activeOperations[operation.id] === operation else { return }
        operation.activeJobs = []
        guard let relayDirectory = operation.relayDirectory else {
            finish(operation, status: status)
            return
        }
        let fileManagerBox = CrossDeviceUncheckedSendableBox(fileManager)
        workQueue.async { [weak self, weak operation] in
            var cleanupError: Error?
            do {
                if fileManagerBox.value.fileExists(atPath: relayDirectory.path) {
                    try fileManagerBox.value.removeItem(at: relayDirectory)
                }
            } catch {
                cleanupError = error
            }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, let operation else { return }
                if let cleanupError {
                    self.finish(
                        operation,
                        status: .failed(
                            "本机临时中继清理失败，可重试：\(cleanupError.localizedDescription)"
                        )
                    )
                } else {
                    operation.relayDirectory = nil
                    self.finish(operation, status: status)
                }
            }
        }
    }

    private func finish(_ operation: ActiveOperation, status: CrossDeviceTransferStatus) {
        guard activeOperations[operation.id] === operation else { return }
        CrossDeviceDirectRouteRegistry.shared.releaseDestinations(owner: operation.id)
        CrossDeviceDirectRouteRegistry.shared.release(operation.activeDirectJobIDs)
        operation.activeDirectJobIDs.removeAll()
        activeOperations[operation.id] = nil
        operation.statusHandler(status)
        presentCompletionNotification(for: operation, status: status)
    }

    private func presentCompletionNotification(
        for operation: ActiveOperation,
        status: CrossDeviceTransferStatus
    ) {
        let notificationStatus: TransferCompletionNotificationStatus
        let diagnostic: String?
        switch status {
        case .completed:
            notificationStatus = .completed
            diagnostic = nil
        case .failed(let message):
            notificationStatus = .failed
            diagnostic = message
        default:
            return
        }
        let byteCount = operation.selections.reduce(UInt64(0)) { total, selection in
            let (sum, overflow) = total.addingReportingOverflow(selection.size)
            return overflow ? UInt64.max : sum
        }
        let duration = max(monotonicTimeProvider() - operation.startedAt, 0)
        let itemName: String
        if operation.selections.count == 1,
           let path = operation.selections.first?.path
        {
            let name = (path as NSString).lastPathComponent
            itemName = name.isEmpty ? path : name
        } else {
            itemName = "\(operation.selections.count) 个项目"
        }
        let title = notificationStatus == .completed
            ? L10n.Transfers.completedNotificationTitle
            : L10n.Transfers.failedNotificationTitle
        let body = notificationStatus == .completed
            ? "已完成从 \(operation.source.title) 到 \(operation.destination.title) 的传输：\(itemName)"
            : "从 \(operation.source.title) 到 \(operation.destination.title) 的传输失败：\(diagnostic ?? L10n.Transfers.transferFailed)"
        completionNotificationPresenter.present(TransferCompletionNotificationPayload(
            jobID: "cross-device-\(operation.id.uuidString.lowercased())",
            runtimeID: operation.destination.runtimeID,
            status: notificationStatus,
            title: title,
            body: body,
            diagnostic: diagnostic,
            itemName: itemName,
            byteCount: byteCount,
            completedAt: nowProvider(),
            duration: duration,
            averageBytesPerSecond: duration > 0 ? Double(byteCount) / duration : 0
        ))
    }

    private nonisolated static func normalizedRemoteDirectory(_ path: String) -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "~" : value
    }

    private nonisolated static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/\(name)" }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private nonisolated static func stableDirectJobID(
        source: WorkerEndpoint,
        destination: WorkerEndpoint,
        item: ResolvedItem
    ) -> String {
        "remote-to-remote-v1-" + stableDirectRouteDigest(
            source: source,
            destination: destination,
            item: item
        )
    }

    private nonisolated static func stableDirectReplacementPath(
        for item: ResolvedItem,
        source: WorkerEndpoint,
        destination: WorkerEndpoint
    ) -> String {
        let parent = (item.destinationPath as NSString).deletingLastPathComponent
        let name = (item.destinationPath as NSString).lastPathComponent
        let digest = stableDirectRouteDigest(
            source: source,
            destination: destination,
            item: item
        )
        let temporaryName = ".\(name).stacio-transfer-v1-\(digest).partial"
        return join(parent.isEmpty ? "." : parent, temporaryName)
    }

    private nonisolated static func stableDirectRouteDigest(
        source: WorkerEndpoint,
        destination: WorkerEndpoint,
        item: ResolvedItem
    ) -> String {
        let fields = [
            "v1",
            source.protocolName.lowercased(),
            source.context.config.host.lowercased(),
            String(source.context.config.port),
            source.context.config.username,
            source.context.expectedFingerprintSHA256,
            destination.protocolName.lowercased(),
            destination.context.config.host.lowercased(),
            String(destination.context.config.port),
            destination.context.config.username,
            destination.context.expectedFingerprintSHA256,
            item.selection.path,
            item.destinationPath,
            String(item.selection.size),
            item.selection.modifiedTime ?? ""
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func comparableRemotePath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized == "/" { return standardized }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    private static func temporaryRemotePath(
        for item: ResolvedItem,
        operation: ActiveOperation,
        index: Int? = nil
    ) -> String {
        let parent = (item.destinationPath as NSString).deletingLastPathComponent
        let name = (item.destinationPath as NSString).lastPathComponent
        let temporaryName = ".\(name).stacio-transfer-\(operation.id.uuidString.lowercased())-\(index ?? operation.currentItemIndex).partial"
        return join(parent.isEmpty ? "." : parent, temporaryName)
    }

    private nonisolated static func backupRemotePath(
        destinationPath: String,
        operationID: UUID,
        index: Int
    ) -> String {
        let destination = destinationPath as NSString
        let parent = destination.deletingLastPathComponent
        let name = destination.lastPathComponent
        let backupName = ".\(name).stacio-backup-\(operationID.uuidString.lowercased())-\(index).pending"
        return join(parent.isEmpty ? "." : parent, backupName)
    }

    private nonisolated static func promoteRemoteReplacement(
        stagingPath: String,
        destinationPath: String,
        isDirectory: Bool,
        operationID: UUID,
        index: Int,
        endpoint: WorkerEndpoint
    ) throws {
        let backupPath = backupRemotePath(
            destinationPath: destinationPath,
            operationID: operationID,
            index: index
        )
        let context = endpoint.context
        try endpoint.bridge.renameLiveRemotePath(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            fromPath: destinationPath,
            toPath: backupPath
        )
        do {
            try endpoint.bridge.renameLiveRemotePath(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                fromPath: stagingPath,
                toPath: destinationPath
            )
        } catch {
            do {
                try endpoint.bridge.renameLiveRemotePath(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    fromPath: backupPath,
                    toPath: destinationPath
                )
            } catch let rollbackError {
                throw CrossDeviceTransferError.remoteReplacementFailed(
                    "提交失败且无法恢复原目标：\(rollbackError.localizedDescription)"
                )
            }
            throw CrossDeviceTransferError.remoteReplacementFailed(
                "提交失败，原目标已恢复：\(error.localizedDescription)"
            )
        }

        do {
            try endpoint.bridge.deleteLiveRemotePath(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                remotePath: backupPath,
                recursive: isDirectory
            )
        } catch {
            do {
                try endpoint.bridge.renameLiveRemotePath(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    fromPath: destinationPath,
                    toPath: stagingPath
                )
                try endpoint.bridge.renameLiveRemotePath(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    fromPath: backupPath,
                    toPath: destinationPath
                )
            } catch let rollbackError {
                throw CrossDeviceTransferError.remoteReplacementFailed(
                    "清理备份失败且无法完整回滚：\(rollbackError.localizedDescription)"
                )
            }
            throw CrossDeviceTransferError.remoteReplacementFailed(
                "清理备份失败，原目标已恢复：\(error.localizedDescription)"
            )
        }
    }

    private func registerRelayRetry(
        jobID: String,
        scheduler: SCPTransferScheduling,
        operation: ActiveOperation
    ) {
        scheduler.registerOrchestratedRetry(
            jobID: jobID,
            runtimeIDs: [operation.source.runtimeID, operation.destination.runtimeID],
            retry: { [weak self, operation] in
                guard let self else { return false }
                return self.retryRelayOperation(operation)
            },
            discard: { [weak operation] in
                operation?.retryDiscarded = true
            }
        )
    }

    private func retryRelayOperation(_ operation: ActiveOperation) -> Bool {
        guard operation.retryDiscarded == false,
              activeOperations[operation.id] == nil
        else { return false }
        operation.cancelRequested = false
        operation.activeJobs = []
        activeOperations[operation.id] = operation
        operation.statusHandler(.resolving)
        if operation.remoteTemporaryPaths.isEmpty == false || operation.relayDirectory != nil {
            retryRelayCleanup(operation)
        } else {
            prepareRelay(operation)
        }
        return true
    }

    private func retryRelayCleanup(_ operation: ActiveOperation) {
        let temporaryPaths = Array(operation.remoteTemporaryPaths)
        let relayDirectory = operation.relayDirectory
        let destination = WorkerEndpoint(operation.destination)
        let fileManagerBox = CrossDeviceUncheckedSendableBox(fileManager)
        workQueue.async { [weak self, weak operation] in
            guard let self, let operation else { return }
            var cleanedRemotePaths = Set<String>()
            var remoteCleanupError: Error?
            for path in temporaryPaths {
                do {
                    try destination.bridge.deleteLiveRemotePath(
                        config: destination.context.config,
                        secret: destination.context.secret,
                        expectedFingerprintSHA256: destination.context.expectedFingerprintSHA256,
                        remotePath: path,
                        recursive: true
                    )
                    cleanedRemotePaths.insert(path)
                } catch {
                    remoteCleanupError = remoteCleanupError ?? error
                }
            }

            var localCleanupError: Error?
            if let relayDirectory {
                do {
                    if fileManagerBox.value.fileExists(atPath: relayDirectory.path) {
                        try fileManagerBox.value.removeItem(at: relayDirectory)
                    }
                } catch {
                    localCleanupError = error
                }
            }

            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self,
                      let operation,
                      self.activeOperations[operation.id] === operation
                else { return }
                operation.remoteTemporaryPaths.subtract(cleanedRemotePaths)
                if localCleanupError == nil {
                    operation.relayDirectory = nil
                }
                if let remoteCleanupError {
                    self.finish(
                        operation,
                        status: .failed(
                            "远端临时文件清理重试失败：\(remoteCleanupError.localizedDescription)"
                        )
                    )
                } else if let localCleanupError {
                    self.finish(
                        operation,
                        status: .failed(
                            "本机临时中继清理重试失败：\(localCleanupError.localizedDescription)"
                        )
                    )
                } else {
                    self.prepareRelay(operation)
                }
            }
        }
    }

    private nonisolated static func temporarySourcePath(
        for item: ResolvedItem,
        operation: ActiveOperation,
        index: Int
    ) -> String {
        let sourcePath = item.selection.path as NSString
        let parent = sourcePath.deletingLastPathComponent
        let name = sourcePath.lastPathComponent
        let temporaryName = ".\(name).stacio-move-\(operation.id.uuidString.lowercased())-\(index).pending"
        return join(parent.isEmpty ? "." : parent, temporaryName)
    }

    private nonisolated static func relayURL(
        for item: ResolvedItem,
        in relayDirectory: URL
    ) -> URL {
        let name = (item.destinationPath as NSString).lastPathComponent
        return relayDirectory.appendingPathComponent(name, isDirectory: item.selection.isDirectory)
    }

    private nonisolated static func preflightMoveSources(
        _ selections: [RemoteFileSelection],
        source: WorkerEndpoint
    ) throws {
        var seenPaths = Set<String>()
        var entriesByDirectory: [String: [RemoteFileEntry]] = [:]
        for selection in selections {
            let comparablePath = comparableRemotePath(selection.path)
            guard seenPaths.insert(comparablePath).inserted else {
                throw CrossDeviceTransferError.sourcePreflightFailed(
                    "源路径在批次中重复：\(selection.path)"
                )
            }
            let path = selection.path as NSString
            let directory = path.deletingLastPathComponent.isEmpty
                ? "."
                : path.deletingLastPathComponent
            let entries: [RemoteFileEntry]
            if let cached = entriesByDirectory[directory] {
                entries = cached
            } else {
                entries = try source.bridge.listLiveRemoteDirectory(
                    config: source.context.config,
                    secret: source.context.secret,
                    expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                    remotePath: directory
                )
                entriesByDirectory[directory] = entries
            }
            let name = path.lastPathComponent
            guard let entry = entries.first(where: {
                ($0.path as NSString).lastPathComponent == name
            }) else {
                throw CrossDeviceTransferError.sourcePreflightFailed(
                    "源路径不存在或无法读取：\(selection.path)"
                )
            }
            guard entry.kind == selection.kind else {
                throw CrossDeviceTransferError.sourcePreflightFailed(
                    "源路径类型已变化：\(selection.path)"
                )
            }
        }
    }

    private static func validateRelayStage(
        at url: URL,
        selection: RemoteFileSelection,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == selection.isDirectory
        else { return false }
        guard selection.isDirectory == false, selection.size > 0 else { return true }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.uint64Value == selection.size
    }

    private nonisolated static func uniqueRemoteName(
        _ name: String,
        existingNames: Set<String>
    ) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = ext.isEmpty ? name : nsName.deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if existingNames.contains(candidate) == false { return candidate }
            index += 1
        }
    }

    private static func isCancellationStatus(_ status: String) -> Bool {
        ["canceled", "cancelled", "stopped"].contains(status.lowercased())
    }
}

private enum CrossDeviceTransferError: LocalizedError {
    case sourceEqualsDestination(String)
    case sourcePreflightFailed(String)
    case remoteReplacementFailed(String)
    case transferCancelled

    var errorDescription: String? {
        switch self {
        case .sourceEqualsDestination(let path):
            return "源路径与目标路径相同，已拒绝操作：\(path)"
        case .sourcePreflightFailed(let message):
            return "移动预检失败，未修改任何源文件：\(message)"
        case .remoteReplacementFailed(let message):
            return "远端安全替换失败：\(message)"
        case .transferCancelled:
            return "传输已取消。"
        }
    }
}

private struct CrossDeviceUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
