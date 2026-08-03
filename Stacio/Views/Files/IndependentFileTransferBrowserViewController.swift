import AppKit
import StacioCoreBindings

public enum FileTransferWorkspaceLayoutMode: String, Equatable {
    case columns
    case grid
}

@MainActor
struct FileTransferRemotePaneConfiguration {
    let sourceRuntimeID: String
    let context: TunnelLiveSessionContext
    let title: String
    let bridge: RemoteFilesBridging
    let transferScheduler: SCPTransferScheduling?
    let remoteProtocolName: String
    let initialRemotePath: String
    let remoteFilePathTerminalSender: (String) -> Void
    let onRuntimeClosed: (() -> Void)?

    init(
        sourceRuntimeID: String,
        context: TunnelLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling?,
        remoteProtocolName: String,
        initialRemotePath: String,
        remoteFilePathTerminalSender: @escaping (String) -> Void,
        onRuntimeClosed: (() -> Void)? = nil
    ) {
        self.sourceRuntimeID = sourceRuntimeID
        self.context = context
        self.title = title
        self.bridge = bridge
        self.transferScheduler = transferScheduler
        self.remoteProtocolName = remoteProtocolName
        self.initialRemotePath = initialRemotePath
        self.remoteFilePathTerminalSender = remoteFilePathTerminalSender
        self.onRuntimeClosed = onRuntimeClosed
    }
}

struct FileTransferRemoteDeviceOption: Equatable {
    let sessionID: String
    let title: String
    let protocolName: String
    let endpoint: String

    var menuTitle: String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceTitle = normalizedTitle.isEmpty ? normalizedEndpoint : normalizedTitle
        let endpointSuffix = normalizedEndpoint.isEmpty || normalizedEndpoint == deviceTitle
            ? ""
            : " · \(normalizedEndpoint)"
        return "\(deviceTitle)\(endpointSuffix) (\(protocolName))"
    }
}

private struct FileWorkspaceTransferPlanningResult<Value> {
    let values: [Value]
    let plannedEverySource: Bool
}

private struct FileWorkspacePlannedDownload {
    let selection: RemoteFileSelection
    let job: ScpTransferJob
    let replacementDestinationPath: String?
}

private struct FileWorkspacePlannedUpload {
    let job: ScpTransferJob
    let isDirectory: Bool
    let replacementDestinationPath: String?
}

@MainActor
private enum FileWorkspaceTransferPlanner {
    static func uploadJobs(
        paths: [String],
        remoteDirectory: String,
        existingEntries: [RemoteFileEntry],
        conflictSession: RemoteFileConflictResolutionSession,
        parentWindow: NSWindow?,
        idPrefix: String
    ) -> FileWorkspaceTransferPlanningResult<FileWorkspacePlannedUpload> {
        var occupiedNames = Set(existingEntries.map { ($0.path as NSString).lastPathComponent })
        var plans: [FileWorkspacePlannedUpload] = []
        var plannedEverySource = true
        for path in paths {
            let sourceURL = URL(fileURLWithPath: path)
            let fileName = sourceURL.lastPathComponent
            guard fileName.isEmpty == false else {
                plannedEverySource = false
                continue
            }
            let proposedPath = joinRemotePath(remoteDirectory, fileName)
            let hasConflict = occupiedNames.contains(fileName)
            let policy = hasConflict
                ? conflictSession.resolveConflict(
                    destinationPath: proposedPath,
                    direction: .upload,
                    parentWindow: parentWindow
                )
                : .overwrite
            guard let policy,
                  let resolvedPath = resolvedPath(
                    proposedPath,
                    policy: policy,
                    occupiedNames: &occupiedNames
                  )
            else {
                plannedEverySource = false
                continue
            }
            occupiedNames.insert((resolvedPath as NSString).lastPathComponent)
            let jobID = "\(idPrefix)_\(UUID().uuidString)"
            let replacesExistingItem = hasConflict && policy == .overwrite
            let transferDestinationPath = replacesExistingItem
                ? temporarySiblingPath(resolvedPath, jobID: jobID)
                : resolvedPath
            plans.append(FileWorkspacePlannedUpload(
                job: ScpTransferJob(
                    id: jobID,
                    direction: .upload,
                    sourcePath: path,
                    destinationPath: transferDestinationPath,
                    bytesTotal: localByteSize(at: sourceURL)
                ),
                isDirectory: isLocalDirectory(at: sourceURL),
                replacementDestinationPath: replacesExistingItem ? resolvedPath : nil
            ))
        }
        return FileWorkspaceTransferPlanningResult(
            values: plans,
            plannedEverySource: plannedEverySource && plans.count == paths.count
        )
    }

    static func downloadPlans(
        selections: [RemoteFileSelection],
        directory: URL,
        conflictSession: RemoteFileConflictResolutionSession,
        parentWindow: NSWindow?,
        idPrefix: String
    ) -> FileWorkspaceTransferPlanningResult<FileWorkspacePlannedDownload> {
        var reservedPaths = Set<String>()
        var plans: [FileWorkspacePlannedDownload] = []
        var plannedEverySource = true
        for selection in selections {
            let fileName = (selection.path as NSString).lastPathComponent
            guard fileName.isEmpty == false else {
                plannedEverySource = false
                continue
            }
            let proposedURL = directory.appendingPathComponent(
                fileName,
                isDirectory: selection.isDirectory
            )
            let proposedPath = proposedURL.path
            let hasConflict = FileManager.default.fileExists(atPath: proposedPath)
                || reservedPaths.contains(proposedPath)
            let policy = hasConflict
                ? conflictSession.resolveConflict(
                    destinationPath: proposedPath,
                    direction: .download,
                    parentWindow: parentWindow
                )
                : .overwrite
            guard let policy,
                  let resolvedPath = resolvedLocalPath(
                    proposedPath,
                    policy: policy,
                    reservedPaths: reservedPaths
                  )
            else {
                plannedEverySource = false
                continue
            }
            reservedPaths.insert(resolvedPath)
            let jobID = "\(idPrefix)_\(UUID().uuidString)"
            let replacesExistingItem = hasConflict && policy == .overwrite
            let transferDestinationPath = replacesExistingItem
                ? temporarySiblingPath(resolvedPath, jobID: jobID)
                : resolvedPath
            plans.append(FileWorkspacePlannedDownload(
                selection: selection,
                job: ScpTransferJob(
                    id: jobID,
                    direction: .download,
                    sourcePath: selection.path,
                    destinationPath: transferDestinationPath,
                    bytesTotal: selection.size
                ),
                replacementDestinationPath: replacesExistingItem ? resolvedPath : nil
            ))
        }
        return FileWorkspaceTransferPlanningResult(
            values: plans,
            plannedEverySource: plannedEverySource && plans.count == selections.count
        )
    }

    static func resolvedPath(
        _ proposedPath: String,
        policy: ScpConflictPolicy,
        occupiedNames: inout Set<String>
    ) -> String? {
        guard var candidate = CoreBridge.resolveSCPConflictPath(
            destinationPath: proposedPath,
            policy: policy
        ) else { return nil }
        guard policy == .keepBoth || policy == .rename else { return candidate }
        var index = 2
        while occupiedNames.contains((candidate as NSString).lastPathComponent) {
            candidate = pathByAppendingNumericSuffix(candidate, index: index)
            index += 1
        }
        return candidate
    }

    private static func resolvedLocalPath(
        _ proposedPath: String,
        policy: ScpConflictPolicy,
        reservedPaths: Set<String>
    ) -> String? {
        guard var candidate = CoreBridge.resolveSCPConflictPath(
            destinationPath: proposedPath,
            policy: policy
        ) else { return nil }
        guard policy == .keepBoth || policy == .rename else { return candidate }
        var index = 2
        while FileManager.default.fileExists(atPath: candidate) || reservedPaths.contains(candidate) {
            candidate = pathByAppendingNumericSuffix(candidate, index: index)
            index += 1
        }
        return candidate
    }

    private static func pathByAppendingNumericSuffix(_ path: String, index: Int) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent as NSString
        let ext = fileName.pathExtension
        let base = ext.isEmpty ? fileName as String : fileName.deletingPathExtension
        let suffixedName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        return directory == "/" ? "/\(suffixedName)" : (directory as NSString).appendingPathComponent(suffixedName)
    }

    private static func temporarySiblingPath(_ destinationPath: String, jobID: String) -> String {
        let destination = destinationPath as NSString
        let parent = destination.deletingLastPathComponent
        let name = destination.lastPathComponent
        let sanitizedJobID = jobID.replacingOccurrences(of: "_", with: "-").lowercased()
        let temporaryName = ".\(name).stacio-transfer-\(sanitizedJobID).partial"
        return parent == "/"
            ? "/\(temporaryName)"
            : (parent as NSString).appendingPathComponent(temporaryName)
    }

    private static func joinRemotePath(_ directory: String, _ name: String) -> String {
        let normalizedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDirectory = normalizedDirectory.isEmpty ? "~" : normalizedDirectory
        if resolvedDirectory == "/" { return "/\(name)" }
        return resolvedDirectory.hasSuffix("/")
            ? resolvedDirectory + name
            : resolvedDirectory + "/" + name
    }

    private static func localByteSize(at url: URL) -> UInt64 {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
    }

    private static func isLocalDirectory(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private struct FileWorkspaceRemoteStageCleanupRequest: @unchecked Sendable {
    let path: String
    let context: TunnelLiveSessionContext
    let bridge: RemoteFilesBridging
}

@MainActor
private final class FileWorkspaceRemoteStageCleanupRegistry {
    private static let maximumClosingRetryCyclesPerPath = 1

    private var pendingRequests: [String: FileWorkspaceRemoteStageCleanupRequest] = [:]
    private var activeRetryPaths: Set<String> = []
    private var closingRetryCyclesByPath: [String: Int] = [:]
    private var isClosing = false
    private let diagnosticHandler: (String) -> Void

    init(diagnosticHandler: @escaping (String) -> Void) {
        self.diagnosticHandler = diagnosticHandler
    }

    func retain(
        _ request: FileWorkspaceRemoteStageCleanupRequest,
        failureDescription: String
    ) {
        pendingRequests[request.path] = request
        diagnosticHandler(
            "传输失败；远端临时文件清理失败，已保留并将在下次上传或关闭会话时重试："
                + "\(request.path)（\(failureDescription)）"
        )
        if isClosing {
            retryPending()
            if closingRetryCyclesByPath[request.path, default: 0]
                >= Self.maximumClosingRetryCyclesPerPath,
               activeRetryPaths.contains(request.path) == false
            {
                diagnosticHandler("关闭会话后的自动清理重试已耗尽，请手动确认远端临时文件。")
                StacioLogStore.shared.append(
                    level: .warning,
                    category: "FileTransfer",
                    message: "remote stage cleanup retry exhausted during close"
                )
            }
        }
    }

    func beginClosing() {
        isClosing = true
        retryPending()
    }

    func retryPending() {
        for request in pendingRequests.values where activeRetryPaths.contains(request.path) == false {
            if isClosing {
                let retryCycles = closingRetryCyclesByPath[request.path, default: 0]
                guard retryCycles < Self.maximumClosingRetryCyclesPerPath else { continue }
                closingRetryCyclesByPath[request.path] = retryCycles + 1
            }
            activeRetryPaths.insert(request.path)
            FileWorkspaceAtomicTransferCommitter.retryRemoteStageCleanup(request) { [self] failureDescription in
                self.activeRetryPaths.remove(request.path)
                if let failureDescription {
                    self.retain(request, failureDescription: failureDescription)
                } else {
                    self.pendingRequests[request.path] = nil
                    self.closingRetryCyclesByPath[request.path] = nil
                }
            }
        }
    }
}

private enum FileWorkspaceAtomicTransferCommitter {
    private static let remoteCleanupAttemptCount = 3
    private static let remoteCleanupRetryDelay: TimeInterval = 0.02

    @MainActor
    static func finishUpload(
        _ progress: ScpTransferProgress,
        plan: FileWorkspacePlannedUpload,
        context: TunnelLiveSessionContext,
        bridge: RemoteFilesBridging,
        cleanupFailure: @escaping (FileWorkspaceRemoteStageCleanupRequest, String) -> Void,
        completion: @escaping (ScpTransferProgress) -> Void
    ) {
        guard isTerminal(progress.status) else {
            completion(progress)
            return
        }
        guard let destinationPath = plan.replacementDestinationPath else {
            completion(progress)
            return
        }
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let contextBox = TransferUncheckedSendableBox(context)
        DispatchQueue.global(qos: .userInitiated).async {
            let terminalProgress: ScpTransferProgress
            var pendingCleanup: (request: FileWorkspaceRemoteStageCleanupRequest, description: String)?
            let cleanupRequest = FileWorkspaceRemoteStageCleanupRequest(
                path: plan.job.destinationPath,
                context: contextBox.value,
                bridge: bridgeBox.value
            )
            if progress.status.lowercased() == "completed" {
                let context = contextBox.value
                do {
                    try validateRemoteStage(
                        path: plan.job.destinationPath,
                        isDirectory: plan.isDirectory,
                        expectedSize: plan.job.bytesTotal,
                        context: context,
                        bridge: bridgeBox.value
                    )
                    try replaceRemoteDestination(
                        stagingPath: plan.job.destinationPath,
                        destinationPath: destinationPath,
                        isDirectory: plan.isDirectory,
                        jobID: plan.job.id,
                        context: context,
                        bridge: bridgeBox.value
                    )
                    terminalProgress = progress
                } catch {
                    do {
                        try cleanupRemoteStageWithRetry(cleanupRequest)
                    } catch {
                        pendingCleanup = (cleanupRequest, error.localizedDescription)
                    }
                    terminalProgress = failedProgress(for: progress)
                }
            } else {
                do {
                    try cleanupRemoteStageWithRetry(cleanupRequest)
                    terminalProgress = progress
                } catch {
                    pendingCleanup = (cleanupRequest, error.localizedDescription)
                    terminalProgress = failedProgress(for: progress)
                }
            }
            DispatchQueue.main.async {
                completion(terminalProgress)
                if let pendingCleanup {
                    cleanupFailure(pendingCleanup.request, pendingCleanup.description)
                }
            }
        }
    }

    @MainActor
    static func retryRemoteStageCleanup(
        _ request: FileWorkspaceRemoteStageCleanupRequest,
        completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let failureDescription: String?
            do {
                try cleanupRemoteStageWithRetry(request)
                failureDescription = nil
            } catch {
                failureDescription = error.localizedDescription
            }
            DispatchQueue.main.async {
                completion(failureDescription)
            }
        }
    }

    @MainActor
    static func finishDownload(
        _ progress: ScpTransferProgress,
        plan: FileWorkspacePlannedDownload,
        completion: @escaping (ScpTransferProgress) -> Void
    ) {
        guard isTerminal(progress.status) else {
            completion(progress)
            return
        }
        guard let destinationPath = plan.replacementDestinationPath else {
            completion(progress)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let stageURL = URL(fileURLWithPath: plan.job.destinationPath)
            let destinationURL = URL(fileURLWithPath: destinationPath)
            let terminalProgress: ScpTransferProgress
            do {
                if progress.status.lowercased() == "completed" {
                    try validateLocalStage(at: stageURL, selection: plan.selection)
                    try replaceLocalDestination(
                        stagingURL: stageURL,
                        destinationURL: destinationURL,
                        jobID: plan.job.id
                    )
                    terminalProgress = progress
                } else {
                    try cleanupLocalStage(at: stageURL)
                    terminalProgress = progress
                }
            } catch {
                try? cleanupLocalStage(at: stageURL)
                terminalProgress = failedProgress(for: progress)
            }
            DispatchQueue.main.async {
                completion(terminalProgress)
            }
        }
    }

    private static func validateRemoteStage(
        path: String,
        isDirectory: Bool,
        expectedSize: UInt64,
        context: TunnelLiveSessionContext,
        bridge: RemoteFilesBridging
    ) throws {
        let pathValue = path as NSString
        let parent = pathValue.deletingLastPathComponent.isEmpty ? "." : pathValue.deletingLastPathComponent
        let name = pathValue.lastPathComponent
        let entries = try bridge.listLiveRemoteDirectory(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: parent
        )
        guard let entry = entries.first(where: { ($0.path as NSString).lastPathComponent == name }),
              entry.kind == (isDirectory ? .directory : .file),
              isDirectory || expectedSize == 0 || entry.size == expectedSize
        else {
            throw FileWorkspaceAtomicTransferError.stageValidationFailed
        }
    }

    static func replaceRemoteDestination(
        stagingPath: String,
        destinationPath: String,
        isDirectory: Bool,
        jobID: String,
        context: TunnelLiveSessionContext,
        bridge: RemoteFilesBridging
    ) throws {
        let backupPath = backupSiblingPath(destinationPath, jobID: jobID)
        try bridge.renameLiveRemotePath(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            fromPath: destinationPath,
            toPath: backupPath
        )
        do {
            try bridge.renameLiveRemotePath(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                fromPath: stagingPath,
                toPath: destinationPath
            )
        } catch {
            do {
                try bridge.renameLiveRemotePath(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    fromPath: backupPath,
                    toPath: destinationPath
                )
            } catch {
                throw FileWorkspaceAtomicTransferError.rollbackFailed
            }
            throw FileWorkspaceAtomicTransferError.promotionFailed
        }
        do {
            try bridge.deleteLiveRemotePath(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                remotePath: backupPath,
                recursive: isDirectory
            )
        } catch {
            do {
                try bridge.renameLiveRemotePath(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    fromPath: destinationPath,
                    toPath: stagingPath
                )
                try bridge.renameLiveRemotePath(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    fromPath: backupPath,
                    toPath: destinationPath
                )
            } catch {
                throw FileWorkspaceAtomicTransferError.rollbackFailed
            }
            throw FileWorkspaceAtomicTransferError.backupCleanupFailed
        }
    }

    private static func cleanupRemoteStage(
        _ path: String,
        context: TunnelLiveSessionContext,
        bridge: RemoteFilesBridging
    ) throws {
        try bridge.deleteLiveRemotePath(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: path,
            recursive: true
        )
    }

    private static func cleanupRemoteStageWithRetry(
        _ request: FileWorkspaceRemoteStageCleanupRequest
    ) throws {
        var lastError: Error?
        for attempt in 0..<remoteCleanupAttemptCount {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: remoteCleanupRetryDelay * Double(attempt))
            }
            do {
                try cleanupRemoteStage(
                    request.path,
                    context: request.context,
                    bridge: request.bridge
                )
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FileWorkspaceAtomicTransferError.remoteStageCleanupFailed
    }

    private static func validateLocalStage(
        at url: URL,
        selection: RemoteFileSelection
    ) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == selection.isDirectory
        else { throw FileWorkspaceAtomicTransferError.stageValidationFailed }
        guard selection.isDirectory == false, selection.size > 0 else { return }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard size?.uint64Value == selection.size else {
            throw FileWorkspaceAtomicTransferError.stageValidationFailed
        }
    }

    private static func replaceLocalDestination(
        stagingURL: URL,
        destinationURL: URL,
        jobID: String
    ) throws {
        let backupURL = URL(fileURLWithPath: backupSiblingPath(destinationURL.path, jobID: jobID))
        try FileManager.default.moveItem(at: destinationURL, to: backupURL)
        do {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            do {
                try FileManager.default.moveItem(at: backupURL, to: destinationURL)
            } catch {
                throw FileWorkspaceAtomicTransferError.rollbackFailed
            }
            throw FileWorkspaceAtomicTransferError.promotionFailed
        }
        do {
            try FileManager.default.removeItem(at: backupURL)
        } catch {
            do {
                try FileManager.default.moveItem(at: destinationURL, to: stagingURL)
                try FileManager.default.moveItem(at: backupURL, to: destinationURL)
            } catch {
                throw FileWorkspaceAtomicTransferError.rollbackFailed
            }
            throw FileWorkspaceAtomicTransferError.backupCleanupFailed
        }
    }

    private static func cleanupLocalStage(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func backupSiblingPath(_ destinationPath: String, jobID: String) -> String {
        let destination = destinationPath as NSString
        let parent = destination.deletingLastPathComponent
        let name = destination.lastPathComponent
        let sanitizedJobID = jobID.replacingOccurrences(of: "_", with: "-").lowercased()
        let backupName = ".\(name).stacio-backup-\(sanitizedJobID).pending"
        return parent == "/"
            ? "/\(backupName)"
            : (parent as NSString).appendingPathComponent(backupName)
    }

    private static func failedProgress(for progress: ScpTransferProgress) -> ScpTransferProgress {
        ScpTransferProgress(
            jobId: progress.jobId,
            bytesDone: 0,
            bytesTotal: progress.bytesTotal,
            status: "failed"
        )
    }

    private static func isTerminal(_ status: String) -> Bool {
        ["completed", "failed", "canceled", "cancelled", "stopped"].contains(status.lowercased())
    }
}

private enum FileWorkspaceAtomicTransferError: Error {
    case stageValidationFailed
    case promotionFailed
    case backupCleanupFailed
    case rollbackFailed
    case remoteStageCleanupFailed
}

/// The file-transfer workspace is intentionally separate from the Inspector
/// Files panel. It owns both sides of the WinSCP/Xftp-style browser and shares
/// its transport queue only with other standalone SCP/SFTP workspaces.
@MainActor
public final class IndependentFileTransferBrowserViewController: NSViewController, NSSplitViewDelegate {
    private enum Layout {
        static let minimumPaneWidth: CGFloat = 360
        static let toolbarHeight: CGFloat = 36
        static let gridSpacing: CGFloat = 1
        static let storedModeKey = "Stacio.FileTransferBrowser.layoutMode"
    }

    public let runtimeID: String
    public let localFilesViewController: LocalFilePaneViewController
    public let remoteFilesViewController: IndependentRemoteFilesViewController
    public var onEntriesLoaded: (([RemoteFileEntry], String) -> Void)?
    public var onLoadError: ((Error) -> Void)?

    private let bridge: RemoteFilesBridging
    private let sshContext: TunnelLiveSessionContext?
    private let transferScheduler: SCPTransferScheduling?
    private let remoteProtocolName: String
    private let initialRemotePath: String
    private let initialLoadPresentation: RemoteFilesInitialLoadPresentation
    private let connectionStateView: SessionConnectionStateView
    private let layoutDefaults: UserDefaults
    private let documentCoordinator: FileTransferDocumentCoordinator
    private let workspaceClipboard: FileWorkspaceClipboard
    private let crossDeviceTransferCoordinator: CrossDeviceTransferCoordinator
    private let conflictResolver: RemoteFileConflictResolving
    private lazy var remoteStageCleanupRegistry = FileWorkspaceRemoteStageCleanupRegistry { [weak self] message in
        self?.remoteFilesViewController.setStatus(message)
    }
    private let remoteContainer = NSView()
    private let splitView = FileTransferWorkspaceSplitView()
    private let gridContainer = NSView()
    private let layoutControl = NSSegmentedControl()
    private let transferQueueButton = NSButton()
    private let addLocalDirectoryButton = NSButton()
    private let addRemoteDeviceButton = NSButton()
    private var transferQueuePopover: NSPopover?
    private var transferQueuePopoverViewController: TransferQueuePopoverViewController?
    private var removeTransferQueueObservation: (() -> Void)?
    private var previousActiveTransferCount = 0
    private var pendingTransferQueueAutoPresentation = false
    private var layoutMode: FileTransferWorkspaceLayoutMode
    private var additionalLocalPanes: [LocalFilePaneViewController] = []
    private var additionalRemotePanes: [IndependentFileTransferRemotePaneViewController] = []
    private var attachedRemoteSourceRuntimeIDs: Set<String>
    private var primaryRemoteSourceRuntimeIDs: Set<String>
    private var primaryRemoteSessionID: String?
    private var pendingRemoteDeviceSessionIDs: [Int: String] = [:]
    private var propertiesWindowControllers: [FileWorkspacePropertiesWindowController] = []
    var remoteDeviceOptionsProvider: (() -> [FileTransferRemoteDeviceOption])?
    var onRequestConnectRemoteDevice: ((String) -> Void)?
    var onRequestCreateRemoteDevice: ((String) -> Void)?
    private var loadGeneration = 0
    private var initialLoadErrorStorage: Error?
    private var paneWidthConstraints: [NSLayoutConstraint] = []
    private var equalPaneWidthConstraints: [NSLayoutConstraint] = []
    private var gridColumnCount = 0
    private var gridRowCount = 0
    private var didCloseRuntime = false

    public private(set) var initialLoadError: Error? {
        get { initialLoadErrorStorage }
        set { initialLoadErrorStorage = newValue }
    }

    public init(
        runtimeID: String,
        context: TunnelLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling?,
        remoteProtocolName: String,
        initialRemotePath: String,
        initialLoadPresentation: RemoteFilesInitialLoadPresentation,
        layoutDefaults: UserDefaults = .standard,
        localFilesViewController: LocalFilePaneViewController,
        workspaceClipboard: FileWorkspaceClipboard? = nil,
        crossDeviceTransferCoordinator: CrossDeviceTransferCoordinator? = nil,
        conflictResolver: RemoteFileConflictResolving = SettingsBackedRemoteFileConflictResolver(),
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in }
    ) {
        self.runtimeID = runtimeID
        self.sshContext = context
        self.bridge = bridge
        self.transferScheduler = transferScheduler
        self.remoteProtocolName = remoteProtocolName
        self.initialRemotePath = Self.normalizedPath(initialRemotePath)
        self.initialLoadPresentation = initialLoadPresentation
        self.layoutDefaults = layoutDefaults
        self.layoutMode = Self.restoredLayoutMode(from: layoutDefaults)
        self.attachedRemoteSourceRuntimeIDs = [runtimeID]
        self.primaryRemoteSourceRuntimeIDs = [runtimeID]
        self.documentCoordinator = FileTransferDocumentCoordinator()
        self.workspaceClipboard = workspaceClipboard ?? .shared
        self.crossDeviceTransferCoordinator = crossDeviceTransferCoordinator
            ?? CrossDeviceTransferCoordinator(
                remoteTransferBridge: CoreBridgeRemoteToRemoteTransferBridge(),
                completionNotificationPresenter: NoopTransferCompletionNotificationPresenter()
            )
        self.conflictResolver = conflictResolver
        self.localFilesViewController = localFilesViewController
        self.remoteFilesViewController = IndependentRemoteFilesViewController(
            title: title,
            protocolName: remoteProtocolName,
            initialPath: Self.normalizedPath(initialRemotePath),
            dragSourceRuntimeID: runtimeID,
            remoteFilePathTerminalSender: remoteFilePathTerminalSender
        )
        self.connectionStateView = SessionConnectionStateView(
            protocolName: remoteProtocolName,
            endpoint: "\(context.config.username)@\(context.config.host):\(context.config.port)"
        )
        super.init(nibName: nil, bundle: nil)
        self.title = title
        wireCallbacks()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let root = StacioAppearanceRefreshView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(root)

        let layoutBar = NSVisualEffectView()
        layoutBar.material = .headerView
        layoutBar.blendingMode = .withinWindow
        layoutBar.state = .active
        layoutBar.translatesAutoresizingMaskIntoConstraints = false
        layoutBar.setAccessibilityIdentifier("Stacio.FileTransferBrowser.layoutBar")

        configureAddLocalDirectoryButton()
        configureAddRemoteDeviceButton()
        configureTransferQueueButton()
        configureLayoutControl()
        layoutBar.addSubview(addLocalDirectoryButton)
        layoutBar.addSubview(addRemoteDeviceButton)
        layoutBar.addSubview(transferQueueButton)
        layoutBar.addSubview(layoutControl)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setAccessibilityIdentifier("Stacio.FileTransferBrowser.split")
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        splitView.delegate = self
        splitView.onUserDividerDragBegan = { [weak self] in
            self?.allowManualColumnWidths()
        }

        gridContainer.translatesAutoresizingMaskIntoConstraints = false
        gridContainer.setAccessibilityIdentifier("Stacio.FileTransferBrowser.grid")
        StacioDesignSystem.setLayerBackgroundColor(
            gridContainer,
            color: StacioDesignSystem.theme.separatorColor
        )

        localFilesViewController.view.translatesAutoresizingMaskIntoConstraints = false
        localFilesViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        remoteContainer.translatesAutoresizingMaskIntoConstraints = false
        remoteContainer.setAccessibilityIdentifier("Stacio.FileTransferBrowser.remoteContainer")
        remoteFilesViewController.view.translatesAutoresizingMaskIntoConstraints = false
        remoteFilesViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteContainer.addSubview(remoteFilesViewController.view)
        NSLayoutConstraint.activate([
            remoteFilesViewController.view.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor),
            remoteFilesViewController.view.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor),
            remoteFilesViewController.view.topAnchor.constraint(equalTo: remoteContainer.topAnchor),
            remoteFilesViewController.view.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor)
        ])

        addChild(localFilesViewController)
        addChild(remoteFilesViewController)
        for pane in additionalLocalPanes where pane.parent == nil {
            addChild(pane)
            _ = pane.view
        }
        for pane in additionalRemotePanes where pane.parent == nil {
            addChild(pane)
            _ = pane.view
        }

        if initialLoadPresentation == .connectionState {
            remoteContainer.addSubview(connectionStateView)
            NSLayoutConstraint.activate([
                connectionStateView.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor),
                connectionStateView.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor),
                connectionStateView.topAnchor.constraint(equalTo: remoteContainer.topAnchor),
                connectionStateView.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor)
            ])
            remoteFilesViewController.view.isHidden = true
        }

        root.addSubview(layoutBar)
        root.addSubview(splitView)
        root.addSubview(gridContainer)
        NSLayoutConstraint.activate([
            layoutBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layoutBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layoutBar.topAnchor.constraint(equalTo: root.topAnchor),
            layoutBar.heightAnchor.constraint(equalToConstant: Layout.toolbarHeight),
            layoutControl.trailingAnchor.constraint(equalTo: layoutBar.trailingAnchor, constant: -10),
            layoutControl.centerYAnchor.constraint(equalTo: layoutBar.centerYAnchor),
            layoutControl.widthAnchor.constraint(equalToConstant: 72),
            layoutControl.heightAnchor.constraint(equalToConstant: 28),
            transferQueueButton.trailingAnchor.constraint(equalTo: layoutControl.leadingAnchor, constant: -8),
            transferQueueButton.centerYAnchor.constraint(equalTo: layoutBar.centerYAnchor),
            transferQueueButton.widthAnchor.constraint(equalToConstant: 28),
            transferQueueButton.heightAnchor.constraint(equalToConstant: 28),
            addRemoteDeviceButton.leadingAnchor.constraint(equalTo: layoutBar.leadingAnchor, constant: 10),
            addRemoteDeviceButton.centerYAnchor.constraint(equalTo: layoutBar.centerYAnchor),
            addRemoteDeviceButton.widthAnchor.constraint(equalToConstant: 132),
            addRemoteDeviceButton.heightAnchor.constraint(equalToConstant: 28),
            addLocalDirectoryButton.leadingAnchor.constraint(equalTo: addRemoteDeviceButton.trailingAnchor, constant: 8),
            addLocalDirectoryButton.centerYAnchor.constraint(equalTo: layoutBar.centerYAnchor),
            addLocalDirectoryButton.widthAnchor.constraint(equalToConstant: 132),
            addLocalDirectoryButton.heightAnchor.constraint(equalToConstant: 28),
            addLocalDirectoryButton.trailingAnchor.constraint(lessThanOrEqualTo: transferQueueButton.leadingAnchor, constant: -12),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: layoutBar.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            gridContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridContainer.topAnchor.constraint(equalTo: layoutBar.bottomAnchor),
            gridContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        configureTransferQueuePopoverIfAvailable()
        rebuildWorkspaceLayout()
        connectionStateView.setRetryAction(
            title: L10n.Files.retry,
            action: initialLoadPresentation == .connectionState ? { [weak self] in
                self?.startInitialLoad()
            } : nil
        )
        startInitialLoad()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutGridPanes()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        presentTransferQueueIfPending()
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView,
              self.splitView.arrangedSubviews.count == 2,
              dividerIndex == 0
        else { return proposedPosition }
        guard proposedPosition.isFinite, proposedPosition >= 0 else { return proposedPosition }
        let maximum = splitView.bounds.width
            - splitView.dividerThickness
            - Layout.minimumPaneWidth
        guard maximum >= Layout.minimumPaneWidth else { return proposedPosition }
        let localWidth = min(max(proposedPosition, Layout.minimumPaneWidth), maximum)
        return localWidth
    }

    public var currentRemotePath: String {
        remoteFilesViewController.currentPath
    }

    public var visibleTextSnapshotForTesting: String {
        if initialLoadPresentation == .connectionState,
           connectionStateView.isHidden == false
        {
            return connectionStateView.visibleTextForTesting
        }
        return remoteFilesViewController.visibleTextSnapshotForTesting
    }

    public var isInitialConnectionStateVisibleForTesting: Bool {
        initialLoadPresentation == .connectionState && connectionStateView.isHidden == false
    }

    public var isFilesWorkspaceHiddenForTesting: Bool {
        remoteFilesViewController.view.isHidden
    }

    public var fileTransferSplitViewForTesting: NSSplitView {
        splitView
    }

    public var layoutModeForTesting: FileTransferWorkspaceLayoutMode {
        layoutMode
    }

    var documentCoordinatorForTesting: FileTransferDocumentCoordinator {
        documentCoordinator
    }

    public var layoutControlForTesting: NSSegmentedControl {
        layoutControl
    }

    public var transferQueueButtonForTesting: NSButton {
        transferQueueButton
    }

    public var hasTransferQueuePopoverForTesting: Bool {
        transferQueuePopover != nil
    }

    public var workspacePaneCountForTesting: Int {
        workspacePaneViews.count
    }

    public var workspaceSessionGroupDefinitionForTesting: WorkspaceSessionGroupDefinition? {
        workspaceSessionGroupDefinition
    }

    public var remoteFilesViewControllersForTesting: [IndependentRemoteFilesViewController] {
        [remoteFilesViewController] + additionalRemotePanes.map(\.remoteFilesViewController)
    }

    public var localFilesViewControllersForTesting: [LocalFilePaneViewController] {
        [localFilesViewController] + additionalLocalPanes
    }

    public var availableRemoteDeviceSessionIDsForTesting: [String] {
        availableRemoteDeviceOptions.map(\.sessionID)
    }

    public var gridColumnCountForTesting: Int {
        gridColumnCount
    }

    public var gridRowCountForTesting: Int {
        gridRowCount
    }

    public var workspacePaneFramesForTesting: [NSRect] {
        workspacePaneViews.map { pane in
            guard let superview = pane.superview else { return .zero }
            return gridContainer.convert(pane.frame, from: superview)
        }
    }

    public func setLayoutModeForTesting(_ mode: FileTransferWorkspaceLayoutMode) {
        setLayoutMode(mode)
    }

    public var addRemoteDeviceButtonForTesting: NSButton {
        addRemoteDeviceButton
    }

    public var addLocalDirectoryButtonForTesting: NSButton {
        addLocalDirectoryButton
    }

    public func addLocalDirectoryForTesting(_ directoryURL: URL) {
        _ = addLocalDirectoryPane(directoryURL)
    }

    func restoreWorkspace(
        additionalLocalDirectoryPaths: [String],
        layout: FileTransferWorkspaceLayoutMode
    ) {
        for path in additionalLocalDirectoryPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            _ = addLocalDirectoryPane(URL(fileURLWithPath: expandedPath, isDirectory: true))
        }
        setLayoutMode(layout, persistPreference: false)
    }

    public var addRemoteDeviceMenuTitlesForTesting: [String] {
        makeRemoteDeviceMenu().items.filter { $0.isSeparatorItem == false }.map(\.title)
    }

    public func requestRemoteDeviceConnectionForTesting(sessionID: String) {
        onRequestConnectRemoteDevice?(sessionID)
    }

    public func requestRemoteDeviceCreationForTesting() {
        onRequestCreateRemoteDevice?(normalizedRemoteProtocolName.uppercased())
    }

    func markPrimaryRemoteDevice(sessionID: String) {
        let sourceRuntimeID = Self.savedSessionSourceID(sessionID)
        primaryRemoteSessionID = sessionID
        primaryRemoteSourceRuntimeIDs.insert(sourceRuntimeID)
        attachedRemoteSourceRuntimeIDs.insert(sourceRuntimeID)
    }

    @discardableResult
    public func addRemotePane(
        runtimeID: String,
        context: TunnelLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling?,
        remoteProtocolName: String,
        initialRemotePath: String = "~",
        initialLoadPresentation: RemoteFilesInitialLoadPresentation = .connectionState,
        sourceRuntimeID: String? = nil,
        onRuntimeClosed: (() -> Void)? = nil,
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in }
    ) -> IndependentFileTransferRemotePaneViewController {
        let pane = IndependentFileTransferRemotePaneViewController(
            runtimeID: runtimeID,
            context: context,
            title: title,
            bridge: bridge,
            transferScheduler: transferScheduler,
            remoteProtocolName: remoteProtocolName,
            initialRemotePath: initialRemotePath,
            initialLoadPresentation: initialLoadPresentation,
            sourceRuntimeID: sourceRuntimeID,
            onRuntimeClosed: onRuntimeClosed,
            localDirectoryProvider: { [weak self] in
                self?.localFilesViewController.directoryURL
            },
            localDirectoryRefresh: { [weak self] in
                self?.localFilesViewController.refreshDirectory()
            },
            conflictResolver: conflictResolver,
            remoteFilePathTerminalSender: remoteFilePathTerminalSender
        )
        pane.documentCoordinator = documentCoordinator
        pane.remoteFilesViewController.onRequestClose = { [weak self, weak pane] in
            guard let pane else { return }
            self?.removeAdditionalRemotePane(pane)
        }
        additionalRemotePanes.append(pane)
        configureRemoteWorkspaceActions(
            pane.remoteFilesViewController,
            runtimeID: pane.runtimeID,
            endpointProvider: { [weak pane] in pane?.crossDeviceEndpoint },
            refresh: { [weak pane] in pane?.refreshCurrentDirectory() }
        )
        if isViewLoaded {
            addChild(pane)
            _ = pane.view
            rebuildWorkspaceLayout()
        }
        return pane
    }

    public func uploadLocalPaths(_ paths: [String], to remoteDirectory: String? = nil) {
        scheduleUploads(paths, to: remoteDirectory ?? currentRemotePath)
    }

    public func performUploadLocalPathsForTesting(_ paths: [String], remoteDirectory: String? = nil) {
        uploadLocalPaths(paths, to: remoteDirectory)
    }

    public func performDownloadSelectionsForTesting(
        _ selections: [RemoteFileSelection],
        to localDirectory: URL
    ) {
        scheduleDownloads(selections, to: localDirectory)
    }

    public func performRemoteDropForTesting(
        sourceRuntimeID: String?,
        selections: [RemoteFileSelection],
        to localDirectory: URL
    ) {
        routeRemoteSelectionsDrop(
            sourceRuntimeID: sourceRuntimeID,
            selections: selections,
            to: localDirectory
        )
    }

    public func loadDirectoryForTesting(_ path: String) {
        loadDirectory(path)
    }

    public func closeRuntime() {
        guard didCloseRuntime == false else { return }
        didCloseRuntime = true
        removeTransferQueueObservation?()
        removeTransferQueueObservation = nil
        transferQueuePopover?.close()
        loadGeneration &+= 1
        remoteStageCleanupRegistry.beginClosing()
        documentCoordinator.closeDocumentWindows()
        _ = crossDeviceTransferCoordinator.cancelOperations(
            involvingRuntimeIDs: Set([runtimeID] + additionalRemotePanes.map(\.runtimeID))
        )
        _ = transferScheduler?.disconnectTransfers(runtimeID: runtimeID)
        additionalRemotePanes.forEach { $0.closeRuntime() }
    }

    public func retryInitialLoadForTesting() {
        startInitialLoad()
    }

    private var workspacePaneViews: [NSView] {
        [localFilesViewController.view]
            + additionalLocalPanes.map(\.view)
            + [remoteContainer]
            + additionalRemotePanes.map(\.view)
    }

    var workspaceSessionGroupDefinition: WorkspaceSessionGroupDefinition? {
        let kind: WorkspaceSessionGroupKind
        switch remoteProtocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scp":
            kind = .scp
        case "sftp":
            kind = .sftp
        default:
            return nil
        }
        let localPanes = [localFilesViewController] + additionalLocalPanes
        let localDefinitions = localPanes.map {
            WorkspaceSessionGroupPane.localDirectory(path: $0.directoryURL.standardizedFileURL.path)
        }
        let primaryRemote = WorkspaceSessionGroupPane.remoteSession(
            sessionID: primaryRemoteSessionID ?? "",
            path: currentRemotePath
        )
        let additionalRemoteDefinitions = additionalRemotePanes.map { pane in
            WorkspaceSessionGroupPane.remoteSession(
                sessionID: Self.savedSessionID(from: pane.sourceRuntimeID) ?? "",
                path: pane.currentRemotePath
            )
        }
        return WorkspaceSessionGroupDefinition(
            kind: kind,
            layout: layoutMode == .grid ? .grid : .columns,
            panes: localDefinitions + [primaryRemote] + additionalRemoteDefinitions
        )
    }

    private var availableRemoteDeviceOptions: [FileTransferRemoteDeviceOption] {
        (remoteDeviceOptionsProvider?() ?? []).filter { option in
            option.protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == normalizedRemoteProtocolName
                && attachedRemoteSourceRuntimeIDs.contains(Self.savedSessionSourceID(option.sessionID)) == false
        }
    }

    private var normalizedRemoteProtocolName: String {
        remoteProtocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func configureAddRemoteDeviceButton() {
        let tooltip = "连接更多远端设备"
        addRemoteDeviceButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: tooltip
        ) ?? NSImage()
        addRemoteDeviceButton.title = "连接远端设备"
        addRemoteDeviceButton.imagePosition = .imageLeading
        addRemoteDeviceButton.imageHugsTitle = true
        addRemoteDeviceButton.target = self
        addRemoteDeviceButton.action = #selector(addRemoteDeviceButtonPressed(_:))
        addRemoteDeviceButton.bezelStyle = .texturedRounded
        addRemoteDeviceButton.controlSize = .small
        addRemoteDeviceButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        addRemoteDeviceButton.toolTip = tooltip
        addRemoteDeviceButton.setAccessibilityLabel(tooltip)
        addRemoteDeviceButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.addRemoteDevice")
        addRemoteDeviceButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(addRemoteDeviceButton)
    }

    private func configureAddLocalDirectoryButton() {
        let tooltip = "添加本地目录到文件工作区"
        addLocalDirectoryButton.image = NSImage(
            systemSymbolName: "folder.badge.plus",
            accessibilityDescription: tooltip
        ) ?? NSImage()
        addLocalDirectoryButton.title = "添加本地目录"
        addLocalDirectoryButton.imagePosition = .imageLeading
        addLocalDirectoryButton.imageHugsTitle = true
        addLocalDirectoryButton.target = self
        addLocalDirectoryButton.action = #selector(addLocalDirectoryButtonPressed(_:))
        addLocalDirectoryButton.bezelStyle = .texturedRounded
        addLocalDirectoryButton.controlSize = .small
        addLocalDirectoryButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        addLocalDirectoryButton.toolTip = tooltip
        addLocalDirectoryButton.setAccessibilityLabel(tooltip)
        addLocalDirectoryButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.addLocalDirectory")
        addLocalDirectoryButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(addLocalDirectoryButton)
    }

    private func configureTransferQueueButton() {
        let tooltip = "传输队列"
        transferQueueButton.title = ""
        transferQueueButton.image = NSImage(
            systemSymbolName: "arrow.up.arrow.down.circle",
            accessibilityDescription: tooltip
        ) ?? NSImage(
            systemSymbolName: "tray.full",
            accessibilityDescription: tooltip
        )
        transferQueueButton.imagePosition = .imageOnly
        transferQueueButton.target = self
        transferQueueButton.action = #selector(transferQueueButtonPressed(_:))
        transferQueueButton.bezelStyle = .texturedRounded
        transferQueueButton.controlSize = .small
        transferQueueButton.toolTip = tooltip
        transferQueueButton.setAccessibilityLabel(tooltip)
        transferQueueButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.transferQueue")
        transferQueueButton.translatesAutoresizingMaskIntoConstraints = false
        transferQueueButton.isEnabled = false
        StacioDesignSystem.styleToolbarButton(transferQueueButton)
    }

    private func configureTransferQueuePopoverIfAvailable() {
        guard transferQueuePopover == nil,
              let coordinator = (transferScheduler as? TransferQueueCoordinatorProviding)?
                .transferQueueCoordinator
        else { return }

        let contentViewController = TransferQueuePopoverViewController()
        contentViewController.onTransferAction = { [weak coordinator] action, jobID in
            switch action {
            case .retry:
                _ = coordinator?.retryFailedTransfer(jobID: jobID)
            case .pause:
                _ = coordinator?.pauseTransfer(jobID: jobID)
            case .resume:
                _ = coordinator?.resumeTransfer(jobID: jobID)
            case .restart:
                _ = coordinator?.restartTransfer(jobID: jobID)
            case .stop:
                _ = coordinator?.stopTransfer(jobID: jobID)
            }
        }
        contentViewController.onCancelTransfer = { [weak coordinator] jobID in
            _ = coordinator?.cancelTransfer(jobID: jobID)
        }
        contentViewController.onRemoveFinishedTransfer = { [weak coordinator] jobID in
            _ = coordinator?.removeFinishedTransfer(jobID: jobID)
        }
        contentViewController.onClearFinished = { [weak coordinator] in
            _ = coordinator?.clearFinishedTransfers()
        }
        contentViewController.onCollapseRequested = { [weak self] in
            self?.transferQueuePopover?.close()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 520, height: 460)
        popover.contentViewController = contentViewController
        transferQueuePopover = popover
        transferQueuePopoverViewController = contentViewController
        transferQueueButton.isEnabled = true

        let observation = coordinator.observeQueue(runtimeIDs: { [weak self] in
            guard let self else { return [] }
            return Set(
                [self.runtimeID]
                    + self.additionalRemotePanes.map(\.runtimeID)
                    + self.allLocalPanes.map(\.runtimeID)
            )
        }) { [weak self, weak contentViewController] snapshot in
            contentViewController?.apply(snapshot: snapshot)
            self?.updateTransferQueueButton(snapshot: snapshot)
        }
        removeTransferQueueObservation = { [weak coordinator] in
            coordinator?.removeQueueObservation(observation)
        }
    }

    private func updateTransferQueueButton(snapshot: TransferQueueSnapshot) {
        let activeCount = snapshot.rows.filter { row in
            !["completed", "failed", "canceled", "cancelled", "stopped"].contains(
                row.rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }.count
        if previousActiveTransferCount == 0, activeCount > 0 {
            pendingTransferQueueAutoPresentation = true
        } else if activeCount == 0 {
            pendingTransferQueueAutoPresentation = false
        }
        previousActiveTransferCount = activeCount
        let symbolName = activeCount > 0
            ? "arrow.up.arrow.down.circle.fill"
            : "arrow.up.arrow.down.circle"
        transferQueueButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "传输队列"
        )
        transferQueueButton.contentTintColor = activeCount > 0 ? .controlAccentColor : nil
        transferQueueButton.toolTip = activeCount > 0
            ? "传输队列（正在传输 \(activeCount) 项）"
            : "传输队列"
        transferQueueButton.setAccessibilityLabel(transferQueueButton.toolTip ?? "传输队列")
        if pendingTransferQueueAutoPresentation {
            DispatchQueue.main.async { [weak self] in
                self?.presentTransferQueueIfPending()
            }
        }
    }

    private func presentTransferQueueIfPending() {
        guard pendingTransferQueueAutoPresentation,
              didCloseRuntime == false,
              transferQueueButton.window != nil,
              let transferQueuePopover
        else { return }
        pendingTransferQueueAutoPresentation = false
        guard transferQueuePopover.isShown == false else { return }
        transferQueuePopover.show(
            relativeTo: transferQueueButton.bounds,
            of: transferQueueButton,
            preferredEdge: .maxY
        )
    }

    @objc private func transferQueueButtonPressed(_ sender: NSButton) {
        guard let transferQueuePopover else { return }
        if transferQueuePopover.isShown {
            transferQueuePopover.close()
        } else {
            transferQueuePopover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .maxY
            )
        }
    }

    @objc private func addLocalDirectoryButtonPressed(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要加入文件工作区的本地目录"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { _ = addLocalDirectoryPane($0) }
    }

    @objc private func addRemoteDeviceButtonPressed(_ sender: NSButton) {
        let menu = makeRemoteDeviceMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
            in: sender
        )
    }

    private func makeRemoteDeviceMenu() -> NSMenu {
        let menu = NSMenu(title: "连接远端设备")
        menu.autoenablesItems = false
        let options = availableRemoteDeviceOptions
        pendingRemoteDeviceSessionIDs = [:]
        if options.isEmpty {
            let emptyItem = NSMenuItem(
                title: "没有可连接的已保存 \(normalizedRemoteProtocolName.uppercased()) 设备",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (index, option) in options.enumerated() {
                let tag = 1_000 + index
                pendingRemoteDeviceSessionIDs[tag] = option.sessionID
                let item = NSMenuItem(
                    title: option.menuTitle,
                    action: #selector(connectRemoteDeviceMenuItemPressed(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = tag
                item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
                item.isEnabled = onRequestConnectRemoteDevice != nil
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let createItem = NSMenuItem(
            title: "新建 \(normalizedRemoteProtocolName.uppercased()) 连接...",
            action: #selector(createRemoteDeviceMenuItemPressed(_:)),
            keyEquivalent: ""
        )
        createItem.target = self
        createItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        createItem.isEnabled = onRequestCreateRemoteDevice != nil
        menu.addItem(createItem)
        return menu
    }

    @objc private func connectRemoteDeviceMenuItemPressed(_ sender: NSMenuItem) {
        guard let sessionID = pendingRemoteDeviceSessionIDs[sender.tag] else { return }
        pendingRemoteDeviceSessionIDs = [:]
        onRequestConnectRemoteDevice?(sessionID)
    }

    @objc private func createRemoteDeviceMenuItemPressed(_ sender: NSMenuItem) {
        pendingRemoteDeviceSessionIDs = [:]
        onRequestCreateRemoteDevice?(normalizedRemoteProtocolName.uppercased())
    }

    @discardableResult
    public func addLocalDirectoryPane(_ directoryURL: URL) -> LocalFilePaneViewController {
        let pane = LocalFilePaneViewController(
            runtimeID: "\(runtimeID)_local_\(UUID().uuidString.lowercased())",
            directoryURL: directoryURL,
            title: directoryURL.lastPathComponent.isEmpty ? "本地文件" : directoryURL.lastPathComponent
        )
        pane.onRemoteSelectionsDropped = { [weak self] selections, destination in
            self?.scheduleDownloads(selections, to: destination)
        }
        pane.onRemoteSelectionsDroppedWithSource = { [weak self] sourceRuntimeID, selections, destination in
            self?.routeRemoteSelectionsDrop(
                sourceRuntimeID: sourceRuntimeID,
                selections: selections,
                to: destination
            )
        }
        pane.onUploadLocalPaths = { [weak self] paths in
            guard let self else { return }
            self.scheduleUploads(paths, to: self.currentRemotePath)
        }
        pane.onOpenFile = { [weak self] url in
            self?.documentCoordinator.openLocalURL(url)
        }
        pane.onQuickLookURLs = { [weak self] urls in
            self?.documentCoordinator.quickLookLocalURLs(urls)
        }
        pane.onRequestClose = { [weak self, weak pane] in
            guard let pane else { return }
            self?.removeAdditionalLocalPane(pane)
        }
        configureLocalWorkspaceActions(pane)
        additionalLocalPanes.append(pane)
        if isViewLoaded {
            addChild(pane)
            _ = pane.view
            rebuildWorkspaceLayout()
        }
        return pane
    }

    private func removeAdditionalLocalPane(_ pane: LocalFilePaneViewController) {
        guard let index = additionalLocalPanes.firstIndex(where: { $0 === pane }) else { return }
        additionalLocalPanes.remove(at: index)
        rebuildWorkspaceLayout()
        pane.removeFromParent()
    }

    private func removeAdditionalRemotePane(_ pane: IndependentFileTransferRemotePaneViewController) {
        guard let index = additionalRemotePanes.firstIndex(where: { $0 === pane }) else { return }
        let sourceRuntimeID = pane.sourceRuntimeID
        _ = crossDeviceTransferCoordinator.cancelOperations(involvingRuntimeIDs: [pane.runtimeID])
        pane.closeRuntime()
        additionalRemotePanes.remove(at: index)
        if let sourceRuntimeID,
           primaryRemoteSourceRuntimeIDs.contains(sourceRuntimeID) == false,
           additionalRemotePanes.contains(where: { $0.sourceRuntimeID == sourceRuntimeID }) == false
        {
            attachedRemoteSourceRuntimeIDs.remove(sourceRuntimeID)
        }
        rebuildWorkspaceLayout()
        pane.removeFromParent()
    }

    @discardableResult
    func removeAttachedRemoteDevices(savedSessionIDs: Set<String>) -> Int {
        let matchingPanes = additionalRemotePanes.filter { pane in
            guard let sessionID = Self.savedSessionID(from: pane.sourceRuntimeID) else {
                return false
            }
            return savedSessionIDs.contains(sessionID)
        }
        matchingPanes.forEach(removeAdditionalRemotePane)
        return matchingPanes.count
    }

    @discardableResult
    func attachRemoteDevice(
        _ configuration: FileTransferRemotePaneConfiguration
    ) -> IndependentFileTransferRemotePaneViewController {
        attachedRemoteSourceRuntimeIDs.insert(configuration.sourceRuntimeID)
        return addRemotePane(
            runtimeID: "\(configuration.sourceRuntimeID)_split_\(UUID().uuidString.lowercased())",
            context: configuration.context,
            title: configuration.title,
            bridge: configuration.bridge,
            transferScheduler: configuration.transferScheduler,
            remoteProtocolName: configuration.remoteProtocolName,
            initialRemotePath: configuration.initialRemotePath,
            initialLoadPresentation: .connectionState,
            sourceRuntimeID: configuration.sourceRuntimeID,
            onRuntimeClosed: configuration.onRuntimeClosed,
            remoteFilePathTerminalSender: configuration.remoteFilePathTerminalSender
        )
    }

    private func configureLayoutControl() {
        layoutControl.segmentCount = 2
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentStyle = .texturedRounded
        layoutControl.controlSize = .small
        layoutControl.target = self
        layoutControl.action = #selector(layoutControlChanged(_:))
        layoutControl.translatesAutoresizingMaskIntoConstraints = false
        layoutControl.setAccessibilityIdentifier("Stacio.FileTransferBrowser.layoutControl")
        layoutControl.setAccessibilityLabel("文件工作区布局")

        let columnsTitle = "连续分栏"
        let gridTitle = "网格分屏"
        let columnsImage = NSImage(
            systemSymbolName: "rectangle.split.3x1",
            accessibilityDescription: columnsTitle
        ) ?? NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: columnsTitle)
        let gridImage = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: gridTitle
        )
        layoutControl.setImage(columnsImage, forSegment: 0)
        layoutControl.setImage(gridImage, forSegment: 1)
        layoutControl.setLabel(columnsImage == nil ? columnsTitle : "", forSegment: 0)
        layoutControl.setLabel(gridImage == nil ? gridTitle : "", forSegment: 1)
        layoutControl.setToolTip(columnsTitle, forSegment: 0)
        layoutControl.setToolTip(gridTitle, forSegment: 1)
        layoutControl.setWidth(34, forSegment: 0)
        layoutControl.setWidth(34, forSegment: 1)
        layoutControl.selectedSegment = layoutMode == .columns ? 0 : 1
        StacioDesignSystem.styleSegmentedControl(layoutControl)
    }

    @objc private func layoutControlChanged(_ sender: NSSegmentedControl) {
        setLayoutMode(sender.selectedSegment == 1 ? .grid : .columns)
    }

    private func setLayoutMode(
        _ mode: FileTransferWorkspaceLayoutMode,
        persistPreference: Bool = true
    ) {
        layoutControl.selectedSegment = mode == .columns ? 0 : 1
        guard layoutMode != mode else { return }
        layoutMode = mode
        if persistPreference {
            layoutDefaults.set(mode.rawValue, forKey: Layout.storedModeKey)
        }
        guard isViewLoaded else { return }
        rebuildWorkspaceLayout()
    }

    private func rebuildWorkspaceLayout() {
        guard isViewLoaded else { return }
        NSLayoutConstraint.deactivate(paneWidthConstraints)
        NSLayoutConstraint.deactivate(equalPaneWidthConstraints)
        paneWidthConstraints = []
        equalPaneWidthConstraints = []

        for pane in splitView.arrangedSubviews {
            splitView.removeArrangedSubview(pane)
            pane.removeFromSuperview()
        }
        gridContainer.subviews.forEach { $0.removeFromSuperview() }

        switch layoutMode {
        case .columns:
            splitView.isHidden = false
            gridContainer.isHidden = true
            for (index, pane) in workspacePaneViews.enumerated() {
                pane.translatesAutoresizingMaskIntoConstraints = false
                pane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                splitView.addArrangedSubview(pane)
                splitView.setHoldingPriority(.defaultLow, forSubviewAt: index)
            }
            installPaneWidthConstraints()
            gridColumnCount = 0
            gridRowCount = 0

        case .grid:
            splitView.isHidden = true
            gridContainer.isHidden = false
            for pane in workspacePaneViews {
                pane.translatesAutoresizingMaskIntoConstraints = true
                pane.autoresizingMask = []
                gridContainer.addSubview(pane)
            }
            layoutGridPanes()
        }
        view.needsLayout = true
    }

    private func layoutGridPanes() {
        guard isViewLoaded, layoutMode == .grid else { return }
        let panes = workspacePaneViews
        guard panes.isEmpty == false,
              gridContainer.bounds.width > 0,
              gridContainer.bounds.height > 0
        else {
            gridColumnCount = 0
            gridRowCount = 0
            return
        }

        let columns = max(1, Int(ceil(sqrt(Double(panes.count)))))
        let rows = max(1, Int(ceil(Double(panes.count) / Double(columns))))
        gridColumnCount = columns
        gridRowCount = rows

        let spacing = Layout.gridSpacing
        let cellWidth = max(0, (
            gridContainer.bounds.width - CGFloat(columns - 1) * spacing
        ) / CGFloat(columns))
        let cellHeight = max(0, (
            gridContainer.bounds.height - CGFloat(rows - 1) * spacing
        ) / CGFloat(rows))
        for (index, pane) in panes.enumerated() {
            let row = index / columns
            let column = index % columns
            pane.frame = NSRect(
                x: CGFloat(column) * (cellWidth + spacing),
                y: gridContainer.bounds.height - CGFloat(row + 1) * cellHeight - CGFloat(row) * spacing,
                width: cellWidth,
                height: cellHeight
            )
        }
    }

    private func wireCallbacks() {
        remoteFilesViewController.onNavigate = { [weak self] path in
            self?.loadDirectory(path)
        }
        remoteFilesViewController.onRefresh = { [weak self] path in
            self?.loadDirectory(path)
        }
        remoteFilesViewController.onUploadLocalPaths = { [weak self] paths, destination in
            self?.scheduleUploads(paths, to: destination)
        }
        remoteFilesViewController.onDownloadSelections = { [weak self] selections in
            self?.scheduleDownloads(selections, to: self?.localFilesViewController.directoryURL)
        }
        remoteFilesViewController.onCreateDirectory = { [weak self] path, name in
            self?.createRemoteDirectory(named: name, in: path)
        }
        remoteFilesViewController.onOpenSelection = { [weak self] selection in
            guard let self, let source = self.primaryRemoteDocumentSource else { return }
            self.documentCoordinator.openRemoteSelection(selection, source: source)
        }
        remoteFilesViewController.onQuickLookSelections = { [weak self] selections in
            guard let self, let source = self.primaryRemoteDocumentSource else { return }
            self.documentCoordinator.quickLookRemoteSelections(selections, source: source)
        }
        localFilesViewController.onRemoteSelectionsDropped = { [weak self] selections, directoryURL in
            self?.scheduleDownloads(selections, to: directoryURL)
        }
        localFilesViewController.onRemoteSelectionsDroppedWithSource = { [weak self] sourceRuntimeID, selections, directoryURL in
            self?.routeRemoteSelectionsDrop(
                sourceRuntimeID: sourceRuntimeID,
                selections: selections,
                to: directoryURL
            )
        }
        localFilesViewController.onUploadLocalPaths = { [weak self] paths in
            guard let self else { return }
            self.scheduleUploads(paths, to: self.currentRemotePath)
        }
        localFilesViewController.onOpenFile = { [weak self] url in
            self?.documentCoordinator.openLocalURL(url)
        }
        localFilesViewController.onQuickLookURLs = { [weak self] urls in
            self?.documentCoordinator.quickLookLocalURLs(urls)
        }
        configureLocalWorkspaceActions(localFilesViewController)
        configureRemoteWorkspaceActions(
            remoteFilesViewController,
            runtimeID: runtimeID,
            endpointProvider: { [weak self] in self?.primaryCrossDeviceEndpoint },
            refresh: { [weak self] in
                guard let self else { return }
                self.loadDirectory(self.currentRemotePath)
            }
        )
    }

    private var primaryCrossDeviceEndpoint: CrossDeviceRemoteEndpoint? {
        guard let sshContext, let transferScheduler else { return nil }
        return CrossDeviceRemoteEndpoint(
            runtimeID: runtimeID,
            title: title ?? sshContext.config.host,
            protocolName: remoteProtocolName,
            context: sshContext,
            bridge: bridge,
            transferScheduler: transferScheduler
        )
    }

    private var crossDeviceEndpoints: [CrossDeviceRemoteEndpoint] {
        [primaryCrossDeviceEndpoint].compactMap { $0 }
            + additionalRemotePanes.compactMap(\.crossDeviceEndpoint)
    }

    private var allLocalPanes: [LocalFilePaneViewController] {
        [localFilesViewController] + additionalLocalPanes
    }

    private func workspaceTransferTargets(excluding deviceID: String) -> [FileWorkspaceTransferTarget] {
        let localTargets = allLocalPanes
            .filter { $0.runtimeID != deviceID }
            .map { pane in
                let name = pane.directoryURL.lastPathComponent.isEmpty
                    ? pane.directoryURL.path
                    : pane.directoryURL.lastPathComponent
                return FileWorkspaceTransferTarget(
                    deviceID: pane.runtimeID,
                    title: "本地 · \(name)",
                    kind: .local(directoryURL: pane.directoryURL)
                )
            }
        let remoteTargets = crossDeviceEndpoints
            .filter { $0.runtimeID != deviceID }
            .map { endpoint in
                let path = remotePath(runtimeID: endpoint.runtimeID)
                return FileWorkspaceTransferTarget(
                    deviceID: endpoint.runtimeID,
                    title: "\(endpoint.title) · \(endpoint.context.config.username)@\(endpoint.context.config.host)",
                    kind: .remote(directoryPath: path)
                )
            }
        return localTargets + remoteTargets
    }

    private func configureLocalWorkspaceActions(_ pane: LocalFilePaneViewController) {
        pane.workspaceClipboard = workspaceClipboard
        pane.conflictResolver = conflictResolver
        pane.localFileTransferScheduler = (transferScheduler as? TransferQueueCoordinatorProviding)?
            .transferQueueCoordinator
        pane.transferTargetsProvider = { [weak self, weak pane] in
            guard let self, let pane else { return [] }
            return self.workspaceTransferTargets(excluding: pane.runtimeID)
        }
        pane.onTransferLocalURLsToTarget = { [weak self, weak pane] urls, target in
            guard let self, let pane else { return }
            self.routeLocalURLs(urls, from: pane.runtimeID, to: target)
        }
        pane.onPastePayload = { [weak self, weak pane] payload, destination in
            guard let self, let pane else { return }
            self.routePastePayload(payload, toLocalPane: pane, destination: destination)
        }
    }

    private func configureRemoteWorkspaceActions(
        _ viewController: IndependentRemoteFilesViewController,
        runtimeID: String,
        endpointProvider: @escaping () -> CrossDeviceRemoteEndpoint?,
        refresh: @escaping () -> Void
    ) {
        viewController.workspaceClipboard = workspaceClipboard
        viewController.transferTargetsProvider = { [weak self] in
            self?.workspaceTransferTargets(excluding: runtimeID) ?? []
        }
        viewController.onTransferSelectionsToTarget = { [weak self] selections, target in
            self?.routeRemoteSelections(
                selections,
                sourceRuntimeID: runtimeID,
                to: target,
                operation: .copy
            )
        }
        viewController.onPastePayload = { [weak self] payload, destinationPath in
            self?.routePastePayload(
                payload,
                toRemoteRuntimeID: runtimeID,
                destinationPath: destinationPath
            )
        }
        viewController.onRemoteSelectionsDropped = { [weak self] sourceRuntimeID, selections, destinationPath in
            guard let self, let sourceRuntimeID else { return }
            self.transferRemoteSelections(
                selections,
                sourceRuntimeID: sourceRuntimeID,
                destinationRuntimeID: runtimeID,
                destinationPath: destinationPath,
                operation: .copy
            )
        }
        viewController.onRenameSelection = { [weak self] selection, name in
            guard let self, let endpoint = endpointProvider() else { return }
            self.renameRemoteSelection(selection, to: name, endpoint: endpoint, refresh: refresh)
        }
        viewController.onDeleteSelections = { [weak self] selections in
            guard let self, let endpoint = endpointProvider() else { return }
            self.deleteRemoteSelections(selections, endpoint: endpoint, refresh: refresh)
        }
        viewController.onChangePermissions = { [weak self] selections, mode in
            guard let self, let endpoint = endpointProvider() else { return }
            self.changeRemotePermissions(selections, mode: mode, endpoint: endpoint, refresh: refresh)
        }
        viewController.onShowProperties = { [weak self] entry, allowsPermissionEditing in
            guard let self, let endpoint = endpointProvider() else { return }
            self.showRemoteProperties(
                entry,
                endpoint: endpoint,
                allowsPermissionEditing: allowsPermissionEditing,
                refresh: refresh
            )
        }
        viewController.allowsRemoteMutations = endpointProvider() != nil
    }

    private func routeLocalURLs(
        _ urls: [URL],
        from sourceDeviceID: String,
        to target: FileWorkspaceTransferTarget
    ) {
        guard urls.isEmpty == false else { return }
        switch target.kind {
        case .local:
            guard let pane = allLocalPanes.first(where: { $0.runtimeID == target.deviceID }) else { return }
            pane.acceptPastePayload(FileWorkspaceClipboardPayload(
                operation: .copy,
                sourceDeviceID: sourceDeviceID,
                localURLs: urls
            ))
        case .remote(let destinationPath):
            uploadLocalURLs(urls, toRemoteRuntimeID: target.deviceID, destinationPath: destinationPath)
        }
    }

    private func routeRemoteSelections(
        _ selections: [RemoteFileSelection],
        sourceRuntimeID: String,
        to target: FileWorkspaceTransferTarget,
        operation: CrossDeviceTransferOperation
    ) {
        switch target.kind {
        case .local(let directoryURL):
            if operation == .copy {
                routeRemoteSelectionsDrop(
                    sourceRuntimeID: sourceRuntimeID,
                    selections: selections,
                    to: directoryURL
                )
            } else {
                scheduleRemoteMoveToLocal(
                    selections,
                    sourceRuntimeID: sourceRuntimeID,
                    directoryURL: directoryURL
                )
            }
        case .remote(let destinationPath):
            transferRemoteSelections(
                selections,
                sourceRuntimeID: sourceRuntimeID,
                destinationRuntimeID: target.deviceID,
                destinationPath: destinationPath,
                operation: operation
            )
        }
    }

    private func routePastePayload(
        _ payload: FileWorkspaceClipboardPayload,
        toLocalPane pane: LocalFilePaneViewController,
        destination: URL
    ) {
        if payload.localURLs.isEmpty == false {
            pane.acceptPastePayload(payload)
            return
        }
        if payload.operation == .cut {
            scheduleRemoteMoveToLocal(
                payload.remoteSelections,
                sourceRuntimeID: payload.sourceDeviceID,
                directoryURL: destination,
                completion: { [weak self] didComplete in
                    guard didComplete else { return }
                    self?.workspaceClipboard.clear()
                }
            )
            return
        }
        let operation: CrossDeviceTransferOperation = payload.operation == .cut ? .move : .copy
        routeRemoteSelections(
            payload.remoteSelections,
            sourceRuntimeID: payload.sourceDeviceID,
            to: FileWorkspaceTransferTarget(
                deviceID: pane.runtimeID,
                title: pane.title ?? destination.lastPathComponent,
                kind: .local(directoryURL: destination)
            ),
            operation: operation
        )
    }

    private func routePastePayload(
        _ payload: FileWorkspaceClipboardPayload,
        toRemoteRuntimeID runtimeID: String,
        destinationPath: String
    ) {
        if payload.localURLs.isEmpty == false {
            if payload.operation == .cut {
                uploadLocalURLs(
                    payload.localURLs,
                    toRemoteRuntimeID: runtimeID,
                    destinationPath: destinationPath,
                    completion: { [weak self] didComplete in
                        guard let self else { return }
                        if didComplete {
                            self.removeLocalItemsAfterQueuedTransfer(payload.localURLs)
                        } else {
                            self.setRemoteStatus(
                                "上传未全部完成，本地源文件和剪贴板已保留",
                                runtimeID: runtimeID
                            )
                        }
                    }
                )
            } else {
                uploadLocalURLs(
                    payload.localURLs,
                    toRemoteRuntimeID: runtimeID,
                    destinationPath: destinationPath
                )
            }
            return
        }
        transferRemoteSelections(
            payload.remoteSelections,
            sourceRuntimeID: payload.sourceDeviceID,
            destinationRuntimeID: runtimeID,
            destinationPath: destinationPath,
            operation: payload.operation == .cut ? .move : .copy,
            terminalHandler: { [weak self] status in
                guard payload.operation == .cut, status == .completed else { return }
                self?.workspaceClipboard.clear()
            }
        )
    }

    private func uploadLocalURLs(
        _ urls: [URL],
        toRemoteRuntimeID runtimeID: String,
        destinationPath: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        if runtimeID == self.runtimeID {
            scheduleUploads(urls.map(\.path), to: destinationPath, completion: completion)
        } else {
            guard let pane = additionalRemotePanes.first(where: { $0.runtimeID == runtimeID }) else {
                completion?(false)
                return
            }
            pane.uploadLocalPaths(
                urls.map(\.path),
                to: destinationPath,
                completion: completion
            )
        }
    }

    private func transferRemoteSelections(
        _ selections: [RemoteFileSelection],
        sourceRuntimeID: String,
        destinationRuntimeID: String,
        destinationPath: String,
        operation: CrossDeviceTransferOperation,
        terminalHandler: ((CrossDeviceTransferStatus) -> Void)? = nil
    ) {
        guard let source = crossDeviceEndpoints.first(where: { $0.runtimeID == sourceRuntimeID }),
              let destination = crossDeviceEndpoints.first(where: { $0.runtimeID == destinationRuntimeID })
        else { return }
        let conflictSession = RemoteFileConflictResolutionSession(resolver: conflictResolver)
        let parentWindow = view.window
        _ = crossDeviceTransferCoordinator.transfer(
            selections,
            from: source,
            to: destination,
            destinationDirectory: destinationPath,
            operation: operation,
            conflictDecisionProvider: { path in
                guard let policy = conflictSession.resolveConflict(
                    destinationPath: path,
                    direction: .upload,
                    parentWindow: parentWindow
                )
                else { return nil }
                return CrossDeviceConflictDecision(
                    resolution: Self.crossDeviceConflictResolution(for: policy),
                    applyToAll: false
                )
            },
            statusHandler: { [weak self] status in
                guard let self else { return }
                self.setRemoteStatus(Self.statusText(status), runtimeID: destinationRuntimeID)
                if status == .completed {
                    self.refreshRemote(runtimeID: sourceRuntimeID)
                    self.refreshRemote(runtimeID: destinationRuntimeID)
                }
                switch status {
                case .completed, .skipped, .cancelled, .failed:
                    terminalHandler?(status)
                case .resolving, .copying, .downloading, .uploading, .cancellationFailed:
                    break
                }
            }
        )
    }

    private static func crossDeviceConflictResolution(
        for policy: ScpConflictPolicy
    ) -> CrossDeviceConflictResolution {
        switch policy {
        case .overwrite:
            return .replace
        case .skip:
            return .skip
        case .keepBoth, .rename:
            return .keepBoth
        }
    }

    private func scheduleRemoteMoveToLocal(
        _ selections: [RemoteFileSelection],
        sourceRuntimeID: String,
        directoryURL: URL,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard selections.isEmpty == false,
              let endpoint = crossDeviceEndpoints.first(where: { $0.runtimeID == sourceRuntimeID })
        else {
            completion?(false)
            return
        }
        let conflictSession = RemoteFileConflictResolutionSession(resolver: conflictResolver)
        let planningResult = FileWorkspaceTransferPlanner.downloadPlans(
            selections: selections,
            directory: directoryURL.standardizedFileURL,
            conflictSession: conflictSession,
            parentWindow: view.window,
            idPrefix: "file_workspace_move_download"
        )
        let plans = planningResult.values
        guard plans.isEmpty == false else {
            completion?(false)
            return
        }
        let batch = FileWorkspaceTransferBatch(
            jobIDs: plans.map(\.job.id),
            didFailInitially: planningResult.plannedEverySource == false
        ) { [weak self] didComplete in
            guard let self else { return }
            guard didComplete, Self.downloadedTargetsAreValid(plans) else {
                self.setRemoteStatus(
                    "下载未全部完成，远端源文件和剪贴板已保留",
                    runtimeID: sourceRuntimeID
                )
                completion?(false)
                return
            }
            self.deleteRemoteSelections(selections, endpoint: endpoint) {
                self.allLocalPanes.first(where: {
                    $0.directoryURL.standardizedFileURL == directoryURL.standardizedFileURL
                })?.refreshDirectory()
                completion?(true)
            }
        }
        for plan in plans {
            let job = plan.job
            endpoint.transferScheduler.scheduleLiveTransfer(
                runtimeID: endpoint.runtimeID,
                config: endpoint.context.config,
                secret: endpoint.context.secret,
                expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256,
                job: job,
                notificationPolicy: .silent,
                completion: { progress in
                    FileWorkspaceAtomicTransferCommitter.finishDownload(
                        progress,
                        plan: plan
                    ) { committedProgress in
                        batch.receive(committedProgress)
                    }
                }
            )
        }
    }

    private static func downloadedTargetsAreValid(
        _ plans: [FileWorkspacePlannedDownload]
    ) -> Bool {
        plans.allSatisfy { plan in
            let destinationPath = plan.replacementDestinationPath ?? plan.job.destinationPath
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: destinationPath,
                isDirectory: &isDirectory
            ) else { return false }
            if plan.selection.isDirectory {
                return isDirectory.boolValue
            }
            guard isDirectory.boolValue == false else { return false }
            guard plan.selection.size > 0 else { return true }
            let size = (try? FileManager.default.attributesOfItem(
                atPath: destinationPath
            )[.size] as? NSNumber)?.uint64Value
            return size == plan.selection.size
        }
    }

    private func removeLocalItemsAfterQueuedTransfer(_ urls: [URL]) {
        let normalizedURLs = urls.map(\.standardizedFileURL)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                for url in normalizedURLs {
                    try FileManager.default.removeItem(at: url)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.workspaceClipboard.clear()
                    self.allLocalPanes.forEach { $0.refreshDirectory() }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.remoteFilesViewController.setStatus(
                        "上传已完成，但无法移除本地源文件：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func remotePath(runtimeID: String) -> String {
        if runtimeID == self.runtimeID { return currentRemotePath }
        return additionalRemotePanes.first(where: { $0.runtimeID == runtimeID })?.currentRemotePath ?? "~"
    }

    private func setRemoteStatus(_ text: String, runtimeID: String) {
        if runtimeID == self.runtimeID {
            remoteFilesViewController.setStatus(text)
        } else {
            additionalRemotePanes.first(where: { $0.runtimeID == runtimeID })?
                .remoteFilesViewController.setStatus(text)
        }
    }

    private func refreshRemote(runtimeID: String) {
        if runtimeID == self.runtimeID {
            loadDirectory(currentRemotePath)
        } else {
            additionalRemotePanes.first(where: { $0.runtimeID == runtimeID })?.refreshCurrentDirectory()
        }
    }

    private func renameRemoteSelection(
        _ selection: RemoteFileSelection,
        to proposedName: String,
        endpoint: CrossDeviceRemoteEndpoint,
        refresh: @escaping () -> Void
    ) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false, name != ".", name != "..", name.contains("/") == false else { return }
        let rawParent = (selection.path as NSString).deletingLastPathComponent
        let parent = rawParent.isEmpty ? "." : rawParent
        let destination = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
        guard destination != selection.path else { return }

        setRemoteStatus("正在检查目标冲突...", runtimeID: endpoint.runtimeID)
        let endpointBox = TransferUncheckedSendableBox(endpoint)
        let bridgeBox = TransferUncheckedSendableBox(endpoint.bridge)
        let contextBox = TransferUncheckedSendableBox(endpoint.context)
        let runtimeID = endpoint.runtimeID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let context = contextBox.value
                let entries = try bridgeBox.value.listLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: parent
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let endpoint = endpointBox.value
                    let targetEntry = entries.first { entry in
                        entry.path != selection.path
                            && (entry.path as NSString).lastPathComponent == name
                    }
                    guard let targetEntry else {
                        self.performRemoteRename(
                            selection,
                            destinationPath: destination,
                            replacing: nil,
                            endpoint: endpoint,
                            refresh: refresh
                        )
                        return
                    }

                    let conflictSession = RemoteFileConflictResolutionSession(
                        resolver: self.conflictResolver
                    )
                    guard let policy = conflictSession.resolveConflict(
                        destinationPath: destination,
                        direction: .upload,
                        parentWindow: self.view.window
                    ) else {
                        self.setRemoteStatus("已取消重命名", runtimeID: endpoint.runtimeID)
                        return
                    }
                    guard policy != .skip else {
                        self.setRemoteStatus("目标冲突项已跳过", runtimeID: endpoint.runtimeID)
                        return
                    }

                    if policy == .overwrite {
                        self.performRemoteRename(
                            selection,
                            destinationPath: destination,
                            replacing: targetEntry,
                            endpoint: endpoint,
                            refresh: refresh
                        )
                        return
                    }

                    var occupiedNames = Set(entries.map { ($0.path as NSString).lastPathComponent })
                    guard let resolvedDestination = FileWorkspaceTransferPlanner.resolvedPath(
                        destination,
                        policy: policy,
                        occupiedNames: &occupiedNames
                    ) else {
                        self.setRemoteStatus("目标冲突项已跳过", runtimeID: endpoint.runtimeID)
                        return
                    }
                    self.performRemoteRename(
                        selection,
                        destinationPath: resolvedDestination,
                        replacing: nil,
                        endpoint: endpoint,
                        refresh: refresh
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.setRemoteStatus(
                        "操作失败：\(error.localizedDescription)",
                        runtimeID: runtimeID
                    )
                }
            }
        }
    }

    private func performRemoteRename(
        _ selection: RemoteFileSelection,
        destinationPath: String,
        replacing targetEntry: RemoteFileEntry?,
        endpoint: CrossDeviceRemoteEndpoint,
        refresh: @escaping () -> Void
    ) {
        performRemoteMutation(
            endpoint: endpoint,
            workingStatus: "正在重命名...",
            completion: refresh
        ) {
            if let targetEntry {
                try FileWorkspaceAtomicTransferCommitter.replaceRemoteDestination(
                    stagingPath: selection.path,
                    destinationPath: destinationPath,
                    isDirectory: targetEntry.kind == .directory,
                    jobID: "rename_\(UUID().uuidString)",
                    context: endpoint.context,
                    bridge: endpoint.bridge
                )
            } else {
                try endpoint.bridge.renameLiveRemotePath(
                    config: endpoint.context.config,
                    secret: endpoint.context.secret,
                    expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256,
                    fromPath: selection.path,
                    toPath: destinationPath
                )
            }
        }
    }

    private func deleteRemoteSelections(
        _ selections: [RemoteFileSelection],
        endpoint: CrossDeviceRemoteEndpoint,
        refresh: @escaping () -> Void = {}
    ) {
        performRemoteMutation(endpoint: endpoint, workingStatus: "正在删除...", completion: refresh) {
            for selection in selections {
                try endpoint.bridge.deleteLiveRemotePath(
                    config: endpoint.context.config,
                    secret: endpoint.context.secret,
                    expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256,
                    remotePath: selection.path,
                    recursive: selection.isDirectory
                )
            }
        }
    }

    private func changeRemotePermissions(
        _ selections: [RemoteFileSelection],
        mode: String,
        endpoint: CrossDeviceRemoteEndpoint,
        refresh: @escaping () -> Void
    ) {
        guard Int(mode, radix: 8) != nil else { return }
        performRemoteMutation(endpoint: endpoint, workingStatus: "正在更新权限...", completion: refresh) {
            for selection in selections {
                try endpoint.bridge.chmodLiveRemotePath(
                    config: endpoint.context.config,
                    secret: endpoint.context.secret,
                    expectedFingerprintSHA256: endpoint.context.expectedFingerprintSHA256,
                    remotePath: selection.path,
                    mode: mode
                )
            }
        }
    }

    private func performRemoteMutation(
        endpoint: CrossDeviceRemoteEndpoint,
        workingStatus: String,
        completion: @escaping () -> Void,
        operation: @escaping () throws -> Void
    ) {
        setRemoteStatus(workingStatus, runtimeID: endpoint.runtimeID)
        let operationBox = TransferUncheckedSendableBox(operation)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try operationBox.value()
                DispatchQueue.main.async { [weak self] in
                    self?.setRemoteStatus("操作完成", runtimeID: endpoint.runtimeID)
                    completion()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.setRemoteStatus(
                        "操作失败：\(error.localizedDescription)",
                        runtimeID: endpoint.runtimeID
                    )
                }
            }
        }
    }

    private func showRemoteProperties(
        _ entry: RemoteFileEntry,
        endpoint: CrossDeviceRemoteEndpoint,
        allowsPermissionEditing: Bool,
        refresh: @escaping () -> Void
    ) {
        let controller = FileWorkspacePropertiesWindowController(
            properties: .remote(entry: entry, device: endpoint.title),
            allowsPermissionEditing: allowsPermissionEditing,
            onApplyPermissions: allowsPermissionEditing ? { [weak self] mode in
                self?.changeRemotePermissions(
                    [RemoteFileSelection(
                        path: entry.path,
                        size: entry.size,
                        kind: entry.kind,
                        modifiedTime: entry.modifiedTime
                    )],
                    mode: mode,
                    endpoint: endpoint,
                    refresh: refresh
                )
            } : nil
        )
        propertiesWindowControllers.removeAll { $0.window?.isVisible == false }
        propertiesWindowControllers.append(controller)
        controller.showWindow(nil as Any?)
        controller.window?.center()
    }

    private static func statusText(_ status: CrossDeviceTransferStatus) -> String {
        switch status {
        case .resolving: return "正在处理目标冲突..."
        case .copying: return "正在远端复制..."
        case .downloading: return "正在下载到安全临时中继..."
        case .uploading: return "正在从安全临时中继上传..."
        case .completed: return "跨设备传输完成"
        case .skipped: return "目标已存在，已跳过"
        case .cancelled: return "跨设备传输已取消"
        case .cancellationFailed(let message): return "取消跨设备传输失败：\(message)"
        case .failed(let message): return "跨设备传输失败：\(message)"
        }
    }

    private var primaryRemoteDocumentSource: FileTransferRemoteDocumentSource? {
        guard let sshContext else {
            remoteFilesViewController.setStatus("当前协议不支持内置编辑和快速预览")
            return nil
        }
        return FileTransferRemoteDocumentSource(
            runtimeID: runtimeID,
            context: sshContext,
            bridge: bridge,
            transferScheduler: transferScheduler,
            setStatus: { [weak remoteFilesViewController] message in
                remoteFilesViewController?.setStatus(message)
            }
        )
    }

    private func startInitialLoad() {
        guard isViewLoaded else { return }
        if initialLoadPresentation == .connectionState {
            remoteFilesViewController.view.isHidden = true
            connectionStateView.update(phase: .connecting)
            connectionStateView.setPresented(true, animated: view.window != nil)
        }
        loadDirectory(initialRemotePath)
    }

    private func routeRemoteSelectionsDrop(
        sourceRuntimeID: String?,
        selections: [RemoteFileSelection],
        to localDirectory: URL
    ) {
        guard let sourceRuntimeID,
              sourceRuntimeID != runtimeID
        else {
            scheduleDownloads(selections, to: localDirectory)
            return
        }
        if let sourcePane = additionalRemotePanes.first(where: { $0.runtimeID == sourceRuntimeID }) {
            sourcePane.downloadSelections(selections, to: localDirectory)
        } else {
            scheduleDownloads(selections, to: localDirectory)
        }
    }

    private func loadDirectory(_ path: String) {
        let normalizedPath = Self.normalizedPath(path)
        loadGeneration &+= 1
        let generation = loadGeneration
        remoteFilesViewController.setLoading(path: normalizedPath)
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let sshBox = sshContext.map(TransferUncheckedSendableBox.init)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let ssh = sshBox?.value else {
                    throw FilesCoordinatorError.missingLiveSSHContext
                }
                let entries = try bridgeBox.value.listLiveRemoteDirectory(
                    config: ssh.config,
                    secret: ssh.secret,
                    expectedFingerprintSHA256: ssh.expectedFingerprintSHA256,
                    remotePath: normalizedPath
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.initialLoadError = nil
                    self.remoteFilesViewController.setEntries(entries, path: normalizedPath)
                    self.onEntriesLoaded?(entries, normalizedPath)
                    self.finishInitialLoad(success: true, error: nil)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.initialLoadError = error
                    self.onLoadError?(error)
                    self.remoteFilesViewController.setError(FilesCoordinator.remoteListingErrorMessage(for: error))
                    self.finishInitialLoad(success: false, error: error)
                }
            }
        }
    }

    private func finishInitialLoad(success: Bool, error: Error?) {
        guard initialLoadPresentation == .connectionState else { return }
        if success {
            remoteFilesViewController.view.isHidden = false
            connectionStateView.setPresented(false, animated: view.window != nil)
        } else {
            remoteFilesViewController.view.isHidden = true
            let detail = FilesCoordinator.remoteListingErrorMessage(for: error ?? FilesCoordinatorError.missingLiveSSHContext)
            let message = detail.hasPrefix(L10n.TerminalLifecycle.connectionFailed)
                ? detail
                : L10n.TerminalLifecycle.connectionFailedMessage(detail)
            connectionStateView.update(phase: .failed(message: message))
            connectionStateView.setPresented(true, animated: view.window != nil)
        }
    }

    private func scheduleUploads(
        _ paths: [String],
        to remoteDirectory: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        remoteStageCleanupRegistry.retryPending()
        guard paths.isEmpty == false,
              let sshContext,
              let transferScheduler
        else {
            completion?(false)
            return
        }
        remoteFilesViewController.setStatus("正在检查目标冲突...")
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let contextBox = TransferUncheckedSendableBox(sshContext)
        let transferSchedulerBox = TransferUncheckedSendableBox(transferScheduler)
        let cleanupRegistry = remoteStageCleanupRegistry
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let context = contextBox.value
                let entries = try bridgeBox.value.listLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: remoteDirectory
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.didCloseRuntime == false else {
                        completion?(false)
                        return
                    }
                    let transferScheduler = transferSchedulerBox.value
                    let conflictSession = RemoteFileConflictResolutionSession(
                        resolver: self.conflictResolver
                    )
                    let planningResult = FileWorkspaceTransferPlanner.uploadJobs(
                        paths: paths,
                        remoteDirectory: remoteDirectory,
                        existingEntries: entries,
                        conflictSession: conflictSession,
                        parentWindow: self.view.window,
                        idPrefix: "file_transfer_upload"
                    )
                    let plans = planningResult.values
                    guard plans.isEmpty == false else {
                        self.remoteFilesViewController.setStatus("目标冲突项已跳过")
                        completion?(false)
                        return
                    }
                    let batch = completion.map {
                        FileWorkspaceTransferBatch(
                            jobIDs: plans.map(\.job.id),
                            didFailInitially: planningResult.plannedEverySource == false,
                            completion: $0
                        )
                    }
                    for plan in plans {
                        transferScheduler.scheduleLiveTransfer(
                            runtimeID: self.runtimeID,
                            config: context.config,
                            secret: context.secret,
                            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                            job: plan.job,
                            notificationPolicy: .silent,
                            completion: { [weak self] progress in
                                FileWorkspaceAtomicTransferCommitter.finishUpload(
                                    progress,
                                    plan: plan,
                                    context: context,
                                    bridge: bridgeBox.value,
                                    cleanupFailure: { request, description in
                                        cleanupRegistry.retain(
                                            request,
                                            failureDescription: description
                                        )
                                    }
                                ) { committedProgress in
                                    self?.transferCompletion(committedProgress)
                                    batch?.receive(committedProgress)
                                }
                            }
                        )
                    }
                    self.remoteFilesViewController.setStatus("已加入上传队列")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.remoteFilesViewController.setStatus(
                        FilesCoordinator.remoteListingErrorMessage(for: error)
                    )
                    completion?(false)
                }
            }
        }
    }

    private func scheduleDownloads(
        _ selections: [RemoteFileSelection],
        to directory: URL?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let directory,
              selections.isEmpty == false,
              let sshContext,
              let transferScheduler
        else {
            completion?(false)
            return
        }
        let conflictSession = RemoteFileConflictResolutionSession(resolver: conflictResolver)
        let planningResult = FileWorkspaceTransferPlanner.downloadPlans(
            selections: selections,
            directory: directory.standardizedFileURL,
            conflictSession: conflictSession,
            parentWindow: view.window,
            idPrefix: "file_transfer_download"
        )
        let plans = planningResult.values
        guard plans.isEmpty == false else {
            completion?(false)
            return
        }
        let batch = completion.map {
            FileWorkspaceTransferBatch(
                jobIDs: plans.map(\.job.id),
                didFailInitially: planningResult.plannedEverySource == false,
                completion: $0
            )
        }
        for plan in plans {
            transferScheduler.scheduleLiveTransfer(
                runtimeID: runtimeID,
                config: sshContext.config,
                secret: sshContext.secret,
                expectedFingerprintSHA256: sshContext.expectedFingerprintSHA256,
                job: plan.job,
                notificationPolicy: .silent,
                completion: { [weak self] progress in
                    FileWorkspaceAtomicTransferCommitter.finishDownload(
                        progress,
                        plan: plan
                    ) { committedProgress in
                        self?.transferCompletion(committedProgress)
                        batch?.receive(committedProgress)
                    }
                }
            )
        }
        remoteFilesViewController.setStatus("已加入下载队列")
    }

    private var transferCompletion: ((ScpTransferProgress) -> Void) {
        { [weak self] progress in
            guard let self else { return }
            guard progress.status == "completed" else {
                if progress.status == "failed" {
                    self.remoteFilesViewController.setStatus("传输失败")
                }
                return
            }
            self.remoteFilesViewController.setStatus("传输完成")
            self.loadDirectory(self.currentRemotePath)
            self.localFilesViewController.refreshDirectory()
        }
    }

    private func createRemoteDirectory(named name: String, in path: String) {
        let destination = Self.join(path, name)
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let sshBox = sshContext.map(TransferUncheckedSendableBox.init)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let ssh = sshBox?.value else {
                    throw FilesCoordinatorError.missingLiveSSHContext
                }
                try bridgeBox.value.createLiveRemoteDirectory(
                    config: ssh.config,
                    secret: ssh.secret,
                    expectedFingerprintSHA256: ssh.expectedFingerprintSHA256,
                    remotePath: destination
                )
                DispatchQueue.main.async { [weak self] in
                    self?.loadDirectory(path)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.remoteFilesViewController.setStatus(FilesCoordinator.remoteListingErrorMessage(for: error))
                }
            }
        }
    }

    private func installPaneWidthConstraints() {
        NSLayoutConstraint.deactivate(paneWidthConstraints)
        NSLayoutConstraint.deactivate(equalPaneWidthConstraints)
        let panes = splitView.arrangedSubviews
        guard let firstPane = panes.first else { return }
        let minimumWidth = panes.count == 2 ? Layout.minimumPaneWidth : 260
        paneWidthConstraints = panes.map { pane in
            let constraint = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
            constraint.priority = .defaultHigh
            return constraint
        }
        equalPaneWidthConstraints = panes.dropFirst().map { pane in
            let constraint = pane.widthAnchor.constraint(equalTo: firstPane.widthAnchor)
            constraint.priority = NSLayoutConstraint.Priority(751)
            return constraint
        }
        NSLayoutConstraint.activate(paneWidthConstraints)
        NSLayoutConstraint.activate(equalPaneWidthConstraints)
    }

    private func allowManualColumnWidths() {
        guard layoutMode == .columns, equalPaneWidthConstraints.isEmpty == false else { return }
        NSLayoutConstraint.deactivate(equalPaneWidthConstraints)
        equalPaneWidthConstraints = []
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    private static func savedSessionSourceID(_ sessionID: String) -> String {
        "saved:\(sessionID)"
    }

    private static func savedSessionID(from sourceRuntimeID: String?) -> String? {
        guard let sourceRuntimeID,
              sourceRuntimeID.hasPrefix("saved:")
        else { return nil }
        let sessionID = String(sourceRuntimeID.dropFirst("saved:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionID.isEmpty ? nil : sessionID
    }

    private static func restoredLayoutMode(from defaults: UserDefaults) -> FileTransferWorkspaceLayoutMode {
        guard let rawValue = defaults.string(forKey: Layout.storedModeKey),
              let mode = FileTransferWorkspaceLayoutMode(rawValue: rawValue)
        else {
            return .columns
        }
        return mode
    }

    private static func join(_ directory: String, _ name: String) -> String {
        let directory = normalizedPath(directory)
        if directory == "/" { return "/\(name)" }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func localByteSize(at url: URL) -> UInt64 {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        // Directory sizes are calculated by the SCP/SFTP/FTP worker while it
        // walks the tree. Keeping the UI-side estimate at zero avoids blocking
        // the main thread when a user drops a large folder.
        guard isDirectory.boolValue == false else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func uniqueLocalURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if FileManager.default.fileExists(atPath: candidate.path) == false { return candidate }
            index += 1
        }
    }
}

@MainActor
public final class IndependentFileTransferRemotePaneViewController: NSViewController {
    public let runtimeID: String
    let sourceRuntimeID: String?
    public let remoteFilesViewController: IndependentRemoteFilesViewController

    private let context: TunnelLiveSessionContext
    private let bridge: RemoteFilesBridging
    private let transferScheduler: SCPTransferScheduling?
    private let remoteProtocolName: String
    private let initialRemotePath: String
    private let initialLoadPresentation: RemoteFilesInitialLoadPresentation
    private let connectionStateView: SessionConnectionStateView
    private let localDirectoryProvider: () -> URL?
    private let localDirectoryRefresh: () -> Void
    private let conflictResolver: RemoteFileConflictResolving
    private let onRuntimeClosed: (() -> Void)?
    private lazy var remoteStageCleanupRegistry = FileWorkspaceRemoteStageCleanupRegistry { [weak self] message in
        self?.remoteFilesViewController.setStatus(message)
    }
    var documentCoordinator = FileTransferDocumentCoordinator()
    private var loadGeneration = 0
    private var didCloseRuntime = false

    public init(
        runtimeID: String,
        context: TunnelLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling?,
        remoteProtocolName: String,
        initialRemotePath: String,
        initialLoadPresentation: RemoteFilesInitialLoadPresentation,
        sourceRuntimeID: String? = nil,
        onRuntimeClosed: (() -> Void)? = nil,
        localDirectoryProvider: @escaping () -> URL?,
        localDirectoryRefresh: @escaping () -> Void,
        conflictResolver: RemoteFileConflictResolving,
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in }
    ) {
        self.runtimeID = runtimeID
        self.sourceRuntimeID = sourceRuntimeID
        self.context = context
        self.bridge = bridge
        self.transferScheduler = transferScheduler
        self.remoteProtocolName = remoteProtocolName
        self.initialRemotePath = Self.normalizedPath(initialRemotePath)
        self.initialLoadPresentation = initialLoadPresentation
        self.localDirectoryProvider = localDirectoryProvider
        self.localDirectoryRefresh = localDirectoryRefresh
        self.conflictResolver = conflictResolver
        self.onRuntimeClosed = onRuntimeClosed
        self.remoteFilesViewController = IndependentRemoteFilesViewController(
            title: title,
            protocolName: remoteProtocolName,
            initialPath: Self.normalizedPath(initialRemotePath),
            dragSourceRuntimeID: runtimeID,
            remoteFilePathTerminalSender: remoteFilePathTerminalSender
        )
        self.connectionStateView = SessionConnectionStateView(
            protocolName: remoteProtocolName,
            endpoint: "\(context.config.username)@\(context.config.host):\(context.config.port)"
        )
        super.init(nibName: nil, bundle: nil)
        self.title = title
        wireCallbacks()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.FileTransferBrowser.remotePane.\(runtimeID)")
        StacioDesignSystem.applyWorkspaceSurface(root)

        addChild(remoteFilesViewController)
        remoteFilesViewController.view.translatesAutoresizingMaskIntoConstraints = false
        remoteFilesViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(remoteFilesViewController.view)
        NSLayoutConstraint.activate([
            remoteFilesViewController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            remoteFilesViewController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            remoteFilesViewController.view.topAnchor.constraint(equalTo: root.topAnchor),
            remoteFilesViewController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        if initialLoadPresentation == .connectionState {
            root.addSubview(connectionStateView)
            NSLayoutConstraint.activate([
                connectionStateView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                connectionStateView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                connectionStateView.topAnchor.constraint(equalTo: root.topAnchor),
                connectionStateView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            remoteFilesViewController.view.isHidden = true
        }

        view = root
        connectionStateView.setRetryAction(
            title: L10n.Files.retry,
            action: initialLoadPresentation == .connectionState ? { [weak self] in
                self?.startInitialLoad()
            } : nil
        )
        startInitialLoad()
    }

    public var currentRemotePath: String {
        remoteFilesViewController.currentPath
    }

    public func closeRuntime() {
        guard didCloseRuntime == false else { return }
        didCloseRuntime = true
        loadGeneration &+= 1
        remoteStageCleanupRegistry.beginClosing()
        _ = transferScheduler?.disconnectTransfers(runtimeID: runtimeID)
        onRuntimeClosed?()
    }

    var crossDeviceEndpoint: CrossDeviceRemoteEndpoint? {
        guard let transferScheduler else { return nil }
        return CrossDeviceRemoteEndpoint(
            runtimeID: runtimeID,
            title: title ?? context.config.host,
            protocolName: remoteProtocolName,
            context: context,
            bridge: bridge,
            transferScheduler: transferScheduler
        )
    }

    func refreshCurrentDirectory() {
        loadDirectory(currentRemotePath)
    }

    func uploadLocalPaths(
        _ paths: [String],
        to remoteDirectory: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        scheduleUploads(
            paths,
            to: remoteDirectory ?? currentRemotePath,
            completion: completion
        )
    }

    func downloadSelections(_ selections: [RemoteFileSelection], to localDirectory: URL) {
        scheduleDownloads(selections, to: localDirectory)
    }

    private func wireCallbacks() {
        remoteFilesViewController.onNavigate = { [weak self] path in
            self?.loadDirectory(path)
        }
        remoteFilesViewController.onRefresh = { [weak self] path in
            self?.loadDirectory(path)
        }
        remoteFilesViewController.onUploadLocalPaths = { [weak self] paths, destination in
            self?.scheduleUploads(paths, to: destination)
        }
        remoteFilesViewController.onDownloadSelections = { [weak self] selections in
            guard let self else { return }
            self.scheduleDownloads(selections, to: self.localDirectoryProvider())
        }
        remoteFilesViewController.onCreateDirectory = { [weak self] path, name in
            self?.createRemoteDirectory(named: name, in: path)
        }
        remoteFilesViewController.onOpenSelection = { [weak self] selection in
            guard let self else { return }
            self.documentCoordinator.openRemoteSelection(selection, source: self.remoteDocumentSource)
        }
        remoteFilesViewController.onQuickLookSelections = { [weak self] selections in
            guard let self else { return }
            self.documentCoordinator.quickLookRemoteSelections(selections, source: self.remoteDocumentSource)
        }
    }

    private var remoteDocumentSource: FileTransferRemoteDocumentSource {
        FileTransferRemoteDocumentSource(
            runtimeID: runtimeID,
            context: context,
            bridge: bridge,
            transferScheduler: transferScheduler,
            setStatus: { [weak remoteFilesViewController] message in
                remoteFilesViewController?.setStatus(message)
            }
        )
    }

    private func startInitialLoad() {
        guard isViewLoaded else { return }
        if initialLoadPresentation == .connectionState {
            remoteFilesViewController.view.isHidden = true
            connectionStateView.update(phase: .connecting)
            connectionStateView.setPresented(true, animated: view.window != nil)
        }
        loadDirectory(initialRemotePath)
    }

    private func loadDirectory(_ path: String) {
        let normalizedPath = Self.normalizedPath(path)
        loadGeneration &+= 1
        let generation = loadGeneration
        remoteFilesViewController.setLoading(path: normalizedPath)
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let contextBox = TransferUncheckedSendableBox(context)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let context = contextBox.value
                let entries = try bridgeBox.value.listLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: normalizedPath
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.remoteFilesViewController.setEntries(entries, path: normalizedPath)
                    self.finishInitialLoad(success: true, error: nil)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.remoteFilesViewController.setError(FilesCoordinator.remoteListingErrorMessage(for: error))
                    self.finishInitialLoad(success: false, error: error)
                }
            }
        }
    }

    private func finishInitialLoad(success: Bool, error: Error?) {
        guard initialLoadPresentation == .connectionState else { return }
        if success {
            remoteFilesViewController.view.isHidden = false
            connectionStateView.setPresented(false, animated: view.window != nil)
        } else {
            remoteFilesViewController.view.isHidden = true
            let detail = FilesCoordinator.remoteListingErrorMessage(
                for: error ?? FilesCoordinatorError.missingLiveSSHContext
            )
            let message = detail.hasPrefix(L10n.TerminalLifecycle.connectionFailed)
                ? detail
                : L10n.TerminalLifecycle.connectionFailedMessage(detail)
            connectionStateView.update(phase: .failed(message: message))
            connectionStateView.setPresented(true, animated: view.window != nil)
        }
    }

    private func scheduleUploads(
        _ paths: [String],
        to remoteDirectory: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        remoteStageCleanupRegistry.retryPending()
        guard paths.isEmpty == false,
              let transferScheduler
        else {
            completion?(false)
            return
        }
        remoteFilesViewController.setStatus("正在检查目标冲突...")
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let contextBox = TransferUncheckedSendableBox(context)
        let transferSchedulerBox = TransferUncheckedSendableBox(transferScheduler)
        let cleanupRegistry = remoteStageCleanupRegistry
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let context = contextBox.value
                let entries = try bridgeBox.value.listLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: remoteDirectory
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.didCloseRuntime == false else {
                        completion?(false)
                        return
                    }
                    let transferScheduler = transferSchedulerBox.value
                    let conflictSession = RemoteFileConflictResolutionSession(
                        resolver: self.conflictResolver
                    )
                    let planningResult = FileWorkspaceTransferPlanner.uploadJobs(
                        paths: paths,
                        remoteDirectory: remoteDirectory,
                        existingEntries: entries,
                        conflictSession: conflictSession,
                        parentWindow: self.view.window,
                        idPrefix: "file_transfer_upload"
                    )
                    let plans = planningResult.values
                    guard plans.isEmpty == false else {
                        self.remoteFilesViewController.setStatus("目标冲突项已跳过")
                        completion?(false)
                        return
                    }
                    let batch = completion.map {
                        FileWorkspaceTransferBatch(
                            jobIDs: plans.map(\.job.id),
                            didFailInitially: planningResult.plannedEverySource == false,
                            completion: $0
                        )
                    }
                    for plan in plans {
                        transferScheduler.scheduleLiveTransfer(
                            runtimeID: self.runtimeID,
                            config: context.config,
                            secret: context.secret,
                            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                            job: plan.job,
                            notificationPolicy: .silent,
                            completion: { [weak self] progress in
                                FileWorkspaceAtomicTransferCommitter.finishUpload(
                                    progress,
                                    plan: plan,
                                    context: context,
                                    bridge: bridgeBox.value,
                                    cleanupFailure: { request, description in
                                        cleanupRegistry.retain(
                                            request,
                                            failureDescription: description
                                        )
                                    }
                                ) { committedProgress in
                                    self?.transferCompletion(committedProgress)
                                    batch?.receive(committedProgress)
                                }
                            }
                        )
                    }
                    self.remoteFilesViewController.setStatus("已加入上传队列")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.remoteFilesViewController.setStatus(
                        FilesCoordinator.remoteListingErrorMessage(for: error)
                    )
                    completion?(false)
                }
            }
        }
    }

    private func scheduleDownloads(
        _ selections: [RemoteFileSelection],
        to directory: URL?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let directory,
              selections.isEmpty == false,
              let transferScheduler
        else {
            completion?(false)
            return
        }
        let conflictSession = RemoteFileConflictResolutionSession(resolver: conflictResolver)
        let planningResult = FileWorkspaceTransferPlanner.downloadPlans(
            selections: selections,
            directory: directory.standardizedFileURL,
            conflictSession: conflictSession,
            parentWindow: view.window,
            idPrefix: "file_transfer_download"
        )
        let plans = planningResult.values
        guard plans.isEmpty == false else {
            completion?(false)
            return
        }
        let batch = completion.map {
            FileWorkspaceTransferBatch(
                jobIDs: plans.map(\.job.id),
                didFailInitially: planningResult.plannedEverySource == false,
                completion: $0
            )
        }
        for plan in plans {
            transferScheduler.scheduleLiveTransfer(
                runtimeID: runtimeID,
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                job: plan.job,
                notificationPolicy: .silent,
                completion: { [weak self] progress in
                    FileWorkspaceAtomicTransferCommitter.finishDownload(
                        progress,
                        plan: plan
                    ) { committedProgress in
                        self?.transferCompletion(committedProgress)
                        batch?.receive(committedProgress)
                    }
                }
            )
        }
        remoteFilesViewController.setStatus("已加入下载队列")
    }

    private var transferCompletion: ((ScpTransferProgress) -> Void) {
        { [weak self] progress in
            guard let self else { return }
            guard progress.status == "completed" else {
                if progress.status == "failed" {
                    self.remoteFilesViewController.setStatus("传输失败")
                }
                return
            }
            self.remoteFilesViewController.setStatus("传输完成")
            self.loadDirectory(self.currentRemotePath)
            self.localDirectoryRefresh()
        }
    }

    private func createRemoteDirectory(named name: String, in path: String) {
        let destination = Self.join(path, name)
        let bridgeBox = TransferUncheckedSendableBox(bridge)
        let contextBox = TransferUncheckedSendableBox(context)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let context = contextBox.value
                try bridgeBox.value.createLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: destination
                )
                DispatchQueue.main.async { [weak self] in
                    self?.loadDirectory(path)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.remoteFilesViewController.setStatus(
                        FilesCoordinator.remoteListingErrorMessage(for: error)
                    )
                }
            }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    private static func join(_ directory: String, _ name: String) -> String {
        let directory = normalizedPath(directory)
        if directory == "/" { return "/\(name)" }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func localByteSize(at url: URL) -> UInt64 {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func uniqueLocalURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = ext.isEmpty
            ? url.lastPathComponent
            : String(url.lastPathComponent.dropLast(ext.count + 1))
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(
                name,
                isDirectory: url.hasDirectoryPath
            )
            if FileManager.default.fileExists(atPath: candidate.path) == false {
                return candidate
            }
            index += 1
        }
    }
}

private struct TransferUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class FileWorkspaceTransferBatch {
    private var pendingJobIDs: Set<String>
    private var didFail = false
    private var didFinish = false
    private let completion: (Bool) -> Void

    init(
        jobIDs: [String],
        didFailInitially: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        self.pendingJobIDs = Set(jobIDs)
        self.didFail = didFailInitially
        self.completion = completion
    }

    func receive(_ progress: ScpTransferProgress) {
        let status = progress.status.lowercased()
        guard ["completed", "failed", "canceled", "cancelled", "stopped"].contains(status),
              pendingJobIDs.remove(progress.jobId) != nil,
              didFinish == false
        else { return }
        if status != "completed" { didFail = true }
        guard pendingJobIDs.isEmpty else { return }
        didFinish = true
        completion(didFail == false)
    }
}

@MainActor
public final class IndependentRemoteFilesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let tableView = IndependentRemoteFilesTableView()
    public private(set) var currentPath: String
    public var onNavigate: ((String) -> Void)?
    public var onRefresh: ((String) -> Void)?
    public var onUploadLocalPaths: (([String], String) -> Void)?
    public var onDownloadSelections: (([RemoteFileSelection]) -> Void)?
    public var onCreateDirectory: ((String, String) -> Void)?
    public var onOpenSelection: ((RemoteFileSelection) -> Void)?
    public var onQuickLookSelections: (([RemoteFileSelection]) -> Void)?
    public var workspaceClipboard: FileWorkspaceClipboard = .shared
    public var transferTargetsProvider: (() -> [FileWorkspaceTransferTarget])?
    public var onTransferSelectionsToTarget: (([RemoteFileSelection], FileWorkspaceTransferTarget) -> Void)?
    public var onPastePayload: ((FileWorkspaceClipboardPayload, String) -> Void)?
    public var onRemoteSelectionsDropped: ((String?, [RemoteFileSelection], String) -> Void)?
    public var onRenameSelection: ((RemoteFileSelection, String) -> Void)?
    public var onDeleteSelections: (([RemoteFileSelection]) -> Void)?
    public var onChangePermissions: (([RemoteFileSelection], String) -> Void)?
    public var onShowProperties: ((RemoteFileEntry, Bool) -> Void)?
    var onRequestClose: (() -> Void)? {
        didSet { updateCloseButtonPlacement() }
    }
    public var allowsRemoteMutations = true

    private let titleLabel: NSTextField
    private let protocolLabel: NSTextField
    private let pathField = NSTextField(string: "~")
    private let statusLabel = NSTextField(labelWithString: "")
    private let parentButton = FileWorkspaceToolbarButton()
    private let refreshButton = FileWorkspaceToolbarButton()
    private let uploadButton = FileWorkspaceToolbarButton()
    private let downloadButton = FileWorkspaceToolbarButton()
    private let newFolderButton = FileWorkspaceToolbarButton()
    private let hiddenButton = FileWorkspaceToolbarButton()
    private let closeButton = FileWorkspaceToolbarButton()
    private weak var toolbarStackView: NSStackView?
    private var entries: [RemoteFileEntry] = []
    private var showHiddenFiles = false
    private var isLoading = false
    private var sortOrder = FileWorkspaceTableSortOrder.initial
    private var isSynchronizingSortDescriptor = false
    private let modifiedTimeParser = RemoteFileModifiedTimeParser()
    private let dragSourceRuntimeID: String?
    private let protocolName: String
    private var pendingTransferTargets: [Int: FileWorkspaceTransferTarget] = [:]

    public init(
        title: String,
        protocolName: String,
        initialPath: String,
        dragSourceRuntimeID: String? = nil,
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in }
    ) {
        self.currentPath = initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "~" : initialPath
        self.titleLabel = NSTextField(labelWithString: title)
        self.protocolLabel = NSTextField(labelWithString: protocolName)
        self.protocolName = protocolName
        self.dragSourceRuntimeID = dragSourceRuntimeID
        super.init(nibName: nil, bundle: nil)
        self.title = title
        tableView.remoteFilePathTerminalSender = remoteFilePathTerminalSender
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(root)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        protocolLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        protocolLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        protocolLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(parentButton, symbol: "chevron.up", tooltip: "上一级", action: #selector(parentPressed))
        configureButton(refreshButton, symbol: "arrow.clockwise", tooltip: "刷新远端目录", action: #selector(refreshPressed))
        configureButton(uploadButton, symbol: "arrow.up.circle", tooltip: "上传到远端", action: #selector(uploadPressed))
        configureButton(downloadButton, symbol: "arrow.down.circle", tooltip: "下载到本地", action: #selector(downloadPressed))
        configureButton(newFolderButton, symbol: "folder.badge.plus", tooltip: "新建远端文件夹", action: #selector(newFolderPressed))
        configureButton(hiddenButton, symbol: "eye", tooltip: "显示隐藏文件", action: #selector(hiddenPressed))
        configureButton(closeButton, symbol: "xmark", tooltip: "关闭此远端设备", action: #selector(closePressed))
        closeButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.closeRemotePane")

        pathField.stringValue = currentPath
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.target = self
        pathField.action = #selector(pathSubmitted)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTextField(pathField)
        pathField.setAccessibilityIdentifier("Stacio.FileTransferBrowser.remotePath")

        let heading = NSStackView(views: [titleLabel, protocolLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 1
        heading.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [heading, parentButton, refreshButton, uploadButton, downloadButton, newFolderButton, hiddenButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarStackView = toolbar
        updateCloseButtonPlacement()
        heading.setContentHuggingPriority(.required, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pathBar = NSStackView(views: [NSTextField(labelWithString: "远端"), pathField])
        pathBar.orientation = .horizontal
        pathBar.alignment = .centerY
        pathBar.spacing = 6
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.arrangedSubviews.first?.setContentHuggingPriority(.required, for: .horizontal)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = StacioFileDisplay.tableRowHeight
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedEntry)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.registerForDraggedTypes([RemoteFileDragPayload.pasteboardType])
        tableView.setAccessibilityIdentifier("Stacio.FileTransferBrowser.remoteTable")
        StacioDesignSystem.styleTable(tableView)
        tableView.addTableColumn(makeColumn("name", title: "名称", width: 250, minWidth: 150, sortable: true))
        tableView.addTableColumn(makeColumn("size", title: "大小", width: 90, minWidth: 70, sortable: true))
        tableView.addTableColumn(makeColumn("time", title: "时间", width: 145, minWidth: 110, sortable: true))
        tableView.addTableColumn(makeColumn("kind", title: "类型", width: 82, minWidth: 64))
        tableView.addTableColumn(makeColumn("owner", title: "用户", width: 82, minWidth: 64))
        tableView.addTableColumn(makeColumn("permissions", title: "权限", width: 104, minWidth: 82))
        synchronizeTableSortDescriptor()
        tableView.onLocalFileDrop = { [weak self] paths, row in
            let destination = self?.destinationPath(forRow: row) ?? self?.currentPath ?? "~"
            self?.onUploadLocalPaths?(paths, destination)
        }
        tableView.onRemoteFileDrop = { [weak self] sourceRuntimeID, selections, row in
            guard let self else { return }
            guard self.acceptsRemoteFileDrop(
                sourceRuntimeID: sourceRuntimeID,
                selections: selections,
                row: row
            ) else { return }
            self.onRemoteSelectionsDropped?(
                sourceRuntimeID,
                selections,
                self.destinationPath(forRow: row)
            )
        }
        tableView.validateRemoteFileDrop = { [weak self] sourceRuntimeID, selections, row in
            self?.acceptsRemoteFileDrop(
                sourceRuntimeID: sourceRuntimeID,
                selections: selections,
                row: row
            ) ?? false
        }
        tableView.rowContextMenuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.onQuickLookRequested = { [weak self] in
            self?.quickLookSelectedItems()
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("Stacio.FileTransferBrowser.remoteStatus")

        root.addSubview(toolbar)
        root.addSubview(pathBar)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            pathBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            pathBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7),
            statusLabel.heightAnchor.constraint(equalToConstant: 18)
        ])
        view = root
        updateStatus("当前路径：\(currentPath)")
        updateActionStates()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, visibleEntries.indices.contains(row) else { return nil }
        let entry = visibleEntries[row]
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("Stacio.TransferCell.\(tableColumn.identifier.rawValue)"), owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("Stacio.TransferCell.\(tableColumn.identifier.rawValue)")
        cell.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: value(for: tableColumn.identifier.rawValue, entry: entry))
        label.font = StacioFileDisplay.tableTextFont
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        if tableColumn.identifier.rawValue == "name" {
            let displayRow = RemoteFileRow(entry: entry)
            let imageView = NSImageView(image: StacioFileDisplay.remoteIcon(for: displayRow))
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityLabel(StacioFileDisplay.iconAccessibilityLabel(for: displayRow))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.addSubview(imageView)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: StacioFileDisplay.iconDimension),
                imageView.heightAnchor.constraint(equalToConstant: StacioFileDisplay.iconDimension),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            cell.imageView = nil
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard visibleEntries.indices.contains(row) else { return nil }
        return RemoteFileDragPayload.pasteboardItem(
            for: selection(for: visibleEntries[row]),
            sourceRuntimeID: dragSourceRuntimeID
        )
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionStates()
    }

    public func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard isSynchronizingSortDescriptor == false,
              let descriptor = tableView.sortDescriptors.first,
              let order = FileWorkspaceTableSortOrder(descriptor: descriptor)
        else { return }
        applySortOrder(order, synchronizesDescriptor: false)
    }

    public func setLoading(path: String) {
        currentPath = Self.normalizedPath(path)
        pathField.stringValue = currentPath
        isLoading = true
        updateStatus("正在读取：\(currentPath)")
        updateActionStates()
    }

    public func setEntries(_ entries: [RemoteFileEntry], path: String) {
        currentPath = Self.normalizedPath(path)
        pathField.stringValue = currentPath
        self.entries = sortedEntries(entries)
        isLoading = false
        updateStatus("当前路径：\(currentPath) · \(visibleEntries.count) 项")
        tableView.reloadData()
        updateActionStates()
    }

    public func setError(_ message: String) {
        isLoading = false
        entries = []
        tableView.reloadData()
        updateStatus(message)
        updateActionStates()
    }

    public func setStatus(_ message: String) {
        updateStatus(message)
    }

    public var visibleTextSnapshotForTesting: String {
        let rows = visibleEntries.flatMap { entry in
            [
                value(for: "name", entry: entry),
                value(for: "size", entry: entry),
                value(for: "kind", entry: entry),
                value(for: "owner", entry: entry),
                value(for: "permissions", entry: entry),
                value(for: "time", entry: entry)
            ]
        }
        return ([titleLabel.stringValue, protocolLabel.stringValue, currentPath, statusLabel.stringValue] + rows).joined(separator: "\n")
    }

    public var displayedItemNamesForTesting: [String] {
        visibleEntries.map { ($0.path as NSString).lastPathComponent }
    }

    public func sortColumnForTesting(identifier: String) {
        guard let order = sortOrder.toggled(for: identifier) else { return }
        applySortOrder(order, synchronizesDescriptor: true)
    }

    public var parentButtonIsEnabledForTesting: Bool {
        parentButton.isEnabled
    }

    public var toolbarIconButtonSizesForTesting: [NSSize] {
        [parentButton, refreshButton, uploadButton, downloadButton, newFolderButton, hiddenButton].map(\.frame.size)
    }

    public func performParentNavigationForTesting() {
        parentPressed()
    }

    public func contextMenuTitlesForTesting(row: Int) -> [String] {
        contextMenu(forRow: row).items
            .filter { $0.isSeparatorItem == false }
            .map(\.title)
    }

    public func performQuickLookForTesting() {
        quickLookSelectedItems()
    }

    public func performDropLocalFilesForTesting(_ paths: [String], onRemoteRow row: Int? = nil) {
        let destination = destinationPath(forRow: row ?? -1)
        onUploadLocalPaths?(paths, destination)
    }

    public func transferTargetMenuTitlesForTesting(row: Int) -> [String] {
        if visibleEntries.indices.contains(row), tableView.selectedRowIndexes.contains(row) == false {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return makeTransferTargetMenu().items.map(\.title)
    }

    private var visibleEntries: [RemoteFileEntry] {
        showHiddenFiles ? entries : entries.filter { !(($0.path as NSString).lastPathComponent.hasPrefix(".")) }
    }

    private func applySortOrder(
        _ order: FileWorkspaceTableSortOrder,
        synchronizesDescriptor: Bool
    ) {
        let selectedPaths = Set(selectedRemoteEntries.map(\.path))
        sortOrder = order
        entries = sortedEntries(entries)
        tableView.reloadData()
        let selectedIndexes = IndexSet(visibleEntries.enumerated().compactMap { index, entry in
            selectedPaths.contains(entry.path) ? index : nil
        })
        tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        if synchronizesDescriptor {
            synchronizeTableSortDescriptor()
        }
        updateActionStates()
    }

    private func sortedEntries(_ candidates: [RemoteFileEntry]) -> [RemoteFileEntry] {
        let parsedTimes: [String: Date]
        if sortOrder.column == .time {
            let referenceDate = Date()
            let values = Set(candidates.compactMap { entry -> String? in
                let value = Self.normalizedRemoteTime(entry.modifiedTime)
                return value.isEmpty ? nil : value
            })
            parsedTimes = Dictionary(uniqueKeysWithValues: values.compactMap { value in
                modifiedTimeParser.date(from: value, relativeTo: referenceDate).map { (value, $0) }
            })
        } else {
            parsedTimes = [:]
        }
        return candidates.sorted { lhs, rhs in
            let lhsIsDirectory = lhs.kind == .directory
            let rhsIsDirectory = rhs.kind == .directory
            if lhsIsDirectory != rhsIsDirectory {
                return lhsIsDirectory
            }
            let lhsName = (lhs.path as NSString).lastPathComponent
            let rhsName = (rhs.path as NSString).lastPathComponent
            let comparison: ComparisonResult
            switch sortOrder.column {
            case .name:
                comparison = lhsName.localizedStandardCompare(rhsName)
            case .size:
                comparison = Self.compare(lhs.size, rhs.size)
            case .time:
                comparison = Self.compareRemoteTime(
                    lhs.modifiedTime,
                    rhs.modifiedTime,
                    parsedTimes: parsedTimes
                )
            }
            if comparison != .orderedSame {
                return sortOrder.placesBefore(comparison)
            }
            let nameComparison = lhsName.localizedStandardCompare(rhsName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.path < rhs.path
        }
    }

    private func synchronizeTableSortDescriptor() {
        isSynchronizingSortDescriptor = true
        tableView.sortDescriptors = [sortOrder.descriptor]
        isSynchronizingSortDescriptor = false
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func compareRemoteTime(
        _ lhs: String?,
        _ rhs: String?,
        parsedTimes: [String: Date]
    ) -> ComparisonResult {
        let lhs = normalizedRemoteTime(lhs)
        let rhs = normalizedRemoteTime(rhs)
        if lhs.isEmpty != rhs.isEmpty {
            return lhs.isEmpty ? .orderedDescending : .orderedAscending
        }
        switch (parsedTimes[lhs], parsedTimes[rhs]) {
        case (.some(let lhsDate), .some(let rhsDate)):
            return compare(lhsDate, rhsDate)
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            break
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func normalizedRemoteTime(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func selection(for entry: RemoteFileEntry) -> RemoteFileSelection {
        RemoteFileSelection(path: entry.path, size: entry.kind == .symlink ? 0 : entry.size, kind: entry.kind, modifiedTime: entry.modifiedTime)
    }

    private func value(for column: String, entry: RemoteFileEntry) -> String {
        switch column {
        case "name":
            return (entry.path as NSString).lastPathComponent
        case "size":
            let clampedSize = Int(min(entry.size, UInt64(Int.max)))
            return entry.kind == .directory ? "" : StacioFileDisplay.byteSizeText(clampedSize)
        case "time":
            return StacioFileDisplay.remoteTimeText(entry.modifiedTime)
        case "owner":
            let owner = entry.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return owner.isEmpty ? "-" : owner
        case "permissions":
            let permissions = entry.permissions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return permissions.isEmpty ? "-" : permissions
        case "kind":
            switch entry.kind {
            case .file: return "文件"
            case .directory: return "文件夹"
            case .symlink: return "链接"
            }
        default: return ""
        }
    }

    private func destinationPath(forRow row: Int) -> String {
        guard visibleEntries.indices.contains(row), visibleEntries[row].kind == .directory else { return currentPath }
        return visibleEntries[row].path
    }

    private func acceptsRemoteFileDrop(
        sourceRuntimeID: String?,
        selections: [RemoteFileSelection],
        row: Int
    ) -> Bool {
        guard sourceRuntimeID == dragSourceRuntimeID else { return true }
        let destination = Self.comparableRemotePath(destinationPath(forRow: row))
        return selections.contains { selection in
            selection.isDirectory
                && Self.comparableRemotePath(selection.path) == destination
        } == false
    }

    private static func comparableRemotePath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized == "/" { return standardized }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    private func updateStatus(_ value: String) {
        statusLabel.stringValue = value
    }

    private func updateActionStates() {
        let hasSelection = tableView.selectedRowIndexes.isEmpty == false
        downloadButton.isEnabled = hasSelection && isLoading == false
        uploadButton.isEnabled = isLoading == false
        parentButton.isEnabled = isLoading == false
        let parentTooltip = currentPath == "/" ? "返回主目录" : "上一级"
        parentButton.toolTip = parentTooltip
        parentButton.setAccessibilityLabel(parentTooltip)
        refreshButton.isEnabled = isLoading == false
        newFolderButton.isEnabled = isLoading == false
    }

    private func configureButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        button.title = ""
        button.target = self
        button.action = action
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        StacioDesignSystem.styleToolbarButton(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func updateCloseButtonPlacement() {
        guard let toolbarStackView else { return }
        if onRequestClose != nil {
            guard closeButton.superview == nil else { return }
            toolbarStackView.addArrangedSubview(closeButton)
        } else if closeButton.superview != nil {
            toolbarStackView.removeArrangedSubview(closeButton)
            closeButton.removeFromSuperview()
        }
    }

    @objc private func closePressed() {
        onRequestClose?()
    }

    private func makeColumn(
        _ identifier: String,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        sortable: Bool = false
    ) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.resizingMask = .userResizingMask
        if sortable {
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        }
        return column
    }

    @objc private func parentPressed() {
        guard isLoading == false else { return }
        let parent: String
        if currentPath == "/" {
            parent = "~"
        } else if currentPath == "~" {
            parent = "/"
        } else if currentPath.hasPrefix("~/") {
            let suffix = String(currentPath.dropFirst(2))
            let parentSuffix = (suffix as NSString).deletingLastPathComponent
            parent = parentSuffix.isEmpty ? "~" : "~/\(parentSuffix)"
        } else {
            let normalized = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
            let value = (normalized as NSString).deletingLastPathComponent
            parent = value.isEmpty ? "/" : value
        }
        onNavigate?(parent)
    }

    @objc private func refreshPressed() {
        onRefresh?(currentPath)
    }

    @objc private func pathSubmitted() {
        onNavigate?(Self.normalizedPath(pathField.stringValue))
    }

    @objc private func uploadPressed() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要上传的文件或文件夹"
        guard panel.runModal() == .OK else { return }
        onUploadLocalPaths?(panel.urls.map(\.path), currentPath)
    }

    @objc private func downloadPressed() {
        onDownloadSelections?(selectedRemoteSelections)
    }

    private func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu(title: "远端文件")
        menu.autoenablesItems = false
        let hasSelection = selectedRemoteSelections.isEmpty == false
        if visibleEntries.indices.contains(row) {
            if visibleEntries[row].kind == .directory {
                menu.addItem(contextMenuItem(
                    title: "打开文件夹",
                    symbol: "folder",
                    action: #selector(openContextDirectory)
                ))
            } else {
                let openItem = contextMenuItem(
                    title: "使用 Stacio 打开",
                    symbol: "doc",
                    action: #selector(openContextFile)
                )
                openItem.isEnabled = isLoading == false
                menu.addItem(openItem)
            }
            let previewItem = contextMenuItem(
                title: "快速查看",
                symbol: "eye",
                action: #selector(quickLookContextSelection)
            )
            previewItem.isEnabled = selectedRemoteSelections.isEmpty == false && isLoading == false
            menu.addItem(previewItem)
            menu.addItem(.separator())
            let copyItem = contextMenuItem(
                title: "复制",
                symbol: "doc.on.doc",
                action: #selector(copyContextSelection)
            )
            copyItem.isEnabled = hasSelection
            menu.addItem(copyItem)
            let cutItem = contextMenuItem(title: "剪切", symbol: "scissors", action: #selector(cutContextSelection))
            cutItem.isEnabled = hasSelection && allowsRemoteMutations
            menu.addItem(cutItem)
        }
        let pasteItem = contextMenuItem(title: "粘贴", symbol: "doc.on.clipboard", action: #selector(pasteContextSelection))
        pasteItem.isEnabled = workspaceClipboard.resolvedPayload() != nil && allowsRemoteMutations
        menu.addItem(pasteItem)
        let transferItem = contextMenuItem(title: "传输到", symbol: "arrow.left.arrow.right", action: nil)
        transferItem.submenu = makeTransferTargetMenu()
        transferItem.isEnabled = hasSelection && transferItem.submenu?.items.contains(where: \.isEnabled) == true
        menu.addItem(transferItem)
        if visibleEntries.indices.contains(row) {
            menu.addItem(.separator())
            let renameItem = contextMenuItem(title: "重命名...", symbol: "pencil", action: #selector(renameContextSelection))
            renameItem.isEnabled = selectedRemoteSelections.count == 1 && allowsRemoteMutations
            menu.addItem(renameItem)
            let deleteItem = contextMenuItem(title: "删除", symbol: "trash", action: #selector(deleteContextSelection))
            deleteItem.isEnabled = hasSelection && allowsRemoteMutations
            menu.addItem(deleteItem)
            let propertiesItem = contextMenuItem(title: "属性...", symbol: "info.circle", action: #selector(propertiesContextSelection))
            propertiesItem.isEnabled = selectedRemoteEntries.count == 1
            menu.addItem(propertiesItem)
            let permissionsItem = contextMenuItem(title: "权限...", symbol: "lock", action: #selector(permissionsContextSelection))
            permissionsItem.isEnabled = selectedRemoteEntries.count == 1
                && allowsRemoteMutations
                && protocolName.caseInsensitiveCompare("FTP") != .orderedSame
            menu.addItem(permissionsItem)
            menu.addItem(contextMenuItem(title: "复制远端路径", symbol: "link", action: #selector(copyContextSelectionPaths)))
            menu.addItem(.separator())
        }
        let newFolderItem = contextMenuItem(
            title: "新建文件夹",
            symbol: "folder.badge.plus",
            action: #selector(newFolderPressed)
        )
        newFolderItem.isEnabled = isLoading == false
        menu.addItem(newFolderItem)
        let refreshItem = contextMenuItem(
            title: "刷新",
            symbol: "arrow.clockwise",
            action: #selector(refreshPressed)
        )
        refreshItem.isEnabled = isLoading == false
        menu.addItem(refreshItem)
        return menu
    }

    private func contextMenuItem(title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func makeTransferTargetMenu() -> NSMenu {
        let menu = NSMenu(title: "传输到")
        menu.autoenablesItems = false
        pendingTransferTargets = [:]
        let targets = (transferTargetsProvider?() ?? []).filter { $0.deviceID != dragSourceRuntimeID }
        if targets.isEmpty {
            let item = NSMenuItem(title: "没有其他可用设备", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        for (index, target) in targets.enumerated() {
            let tag = 3_000 + index
            pendingTransferTargets[tag] = target
            let item = NSMenuItem(title: target.title, action: #selector(transferToContextTarget(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isEnabled = onTransferSelectionsToTarget != nil
            item.image = NSImage(
                systemSymbolName: target.kind.isLocal ? "folder" : "server.rack",
                accessibilityDescription: target.title
            )
            menu.addItem(item)
        }
        return menu
    }

    private var selectedRemoteSelections: [RemoteFileSelection] {
        tableView.selectedRowIndexes.compactMap { index -> RemoteFileSelection? in
            guard visibleEntries.indices.contains(index) else { return nil }
            return selection(for: visibleEntries[index])
        }
    }

    private var selectedRemoteEntries: [RemoteFileEntry] {
        tableView.selectedRowIndexes.compactMap { index in
            guard visibleEntries.indices.contains(index) else { return nil }
            return visibleEntries[index]
        }
    }

    @objc private func openContextDirectory() {
        openSelectedEntry()
    }

    @objc private func openContextFile() {
        openSelectedEntry()
    }

    @objc private func quickLookContextSelection() {
        quickLookSelectedItems()
    }

    @objc private func copyContextSelection() {
        workspaceClipboard.storeRemoteSelections(
            selectedRemoteSelections,
            operation: .copy,
            sourceDeviceID: dragSourceRuntimeID ?? "remote"
        )
        setStatus("已复制 \(selectedRemoteSelections.count) 项")
    }

    @objc private func cutContextSelection() {
        workspaceClipboard.storeRemoteSelections(
            selectedRemoteSelections,
            operation: .cut,
            sourceDeviceID: dragSourceRuntimeID ?? "remote"
        )
        setStatus("已剪切 \(selectedRemoteSelections.count) 项")
    }

    @objc private func pasteContextSelection() {
        guard let payload = workspaceClipboard.resolvedPayload() else { return }
        onPastePayload?(payload, currentPath)
    }

    @objc private func transferToContextTarget(_ sender: NSMenuItem) {
        guard let target = pendingTransferTargets[sender.tag] else { return }
        onTransferSelectionsToTarget?(selectedRemoteSelections, target)
        pendingTransferTargets = [:]
    }

    @objc private func renameContextSelection() {
        guard selectedRemoteSelections.count == 1, let selection = selectedRemoteSelections.first else { return }
        let field = NSTextField(string: (selection.path as NSString).lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "重命名远端项目"
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRenameSelection?(selection, field.stringValue)
    }

    @objc private func deleteContextSelection() {
        let alert = NSAlert()
        alert.messageText = "删除选中的远端项目？"
        alert.informativeText = "此操作无法通过废纸篓恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDeleteSelections?(selectedRemoteSelections)
    }

    @objc private func propertiesContextSelection() {
        guard let entry = selectedRemoteEntries.first else { return }
        onShowProperties?(entry, false)
    }

    @objc private func permissionsContextSelection() {
        guard let entry = selectedRemoteEntries.first else { return }
        onShowProperties?(entry, true)
    }

    @objc private func copyContextSelectionPaths() {
        let paths = selectedRemoteSelections.map(\.path)
        guard paths.isEmpty == false else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func newFolderPressed() {
        let field = NSTextField(string: "新建文件夹")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "新建远端文件夹"
        alert.informativeText = currentPath
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false, name != ".", name != "..", name.contains("/") == false else { return }
        onCreateDirectory?(currentPath, name)
    }

    @objc private func hiddenPressed() {
        showHiddenFiles.toggle()
        hiddenButton.toolTip = showHiddenFiles ? "隐藏隐藏文件" : "显示隐藏文件"
        tableView.reloadData()
        updateStatus("当前路径：\(currentPath) · \(visibleEntries.count) 项")
    }

    @objc private func openSelectedEntry() {
        guard tableView.selectedRowIndexes.count == 1,
              let index = tableView.selectedRowIndexes.first,
              visibleEntries.indices.contains(index)
        else { return }
        let entry = visibleEntries[index]
        if entry.kind == .directory {
            onNavigate?(entry.path)
        } else {
            onOpenSelection?(selection(for: entry))
        }
    }

    private func quickLookSelectedItems() {
        let selections = selectedRemoteSelections
        guard selections.isEmpty == false else { return }
        onQuickLookSelections?(selections)
    }

    private static func normalizedPath(_ path: String) -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "~" : value
    }
}

private final class FileTransferWorkspaceSplitView: NSSplitView {
    var onUserDividerDragBegan: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onUserDividerDragBegan?()
        super.mouseDown(with: event)
    }
}

@MainActor
public final class IndependentRemoteFilesTableView: NSTableView {
    var rowContextMenuProvider: ((Int) -> NSMenu?)?
    var onQuickLookRequested: (() -> Void)?
    var validateRemoteFileDrop: ((String?, [RemoteFileSelection], Int) -> Bool)?
    var onRemoteFileDrop: ((String?, [RemoteFileSelection], Int) -> Void)? {
        didSet { registerForDraggedTypes([.fileURL, RemoteFileDragPayload.pasteboardType]) }
    }

    public var onLocalFileDrop: (([String], Int) -> Void)? {
        didSet {
            registerForDraggedTypes([.fileURL, RemoteFileDragPayload.pasteboardType])
        }
    }
    public var remoteFilePathTerminalSender: ((String) -> Void)?

    public override func menu(for event: NSEvent) -> NSMenu? {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        if clickedRow >= 0, selectedRowIndexes.contains(clickedRow) == false {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        } else if clickedRow < 0 {
            deselectAll(nil)
        }
        return rowContextMenuProvider?(clickedRow)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            onQuickLookRequested?()
            return
        }
        super.keyDown(with: event)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let remoteSelections = RemoteFileDragPayload.selections(from: sender.draggingPasteboard)
        if remoteSelections.isEmpty == false {
            let row = row(at: convert(sender.draggingLocation, from: nil))
            guard validateRemoteFileDrop?(
                RemoteFileDragPayload.sourceRuntimeID(from: sender.draggingPasteboard),
                remoteSelections,
                row
            ) != false else { return [] }
            return .copy
        }
        return LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let row = row(at: convert(sender.draggingLocation, from: nil))
        let remoteSelections = RemoteFileDragPayload.selections(from: sender.draggingPasteboard)
        if remoteSelections.isEmpty == false {
            let sourceRuntimeID = RemoteFileDragPayload.sourceRuntimeID(from: sender.draggingPasteboard)
            guard validateRemoteFileDrop?(sourceRuntimeID, remoteSelections, row) != false else {
                return false
            }
            onRemoteFileDrop?(
                sourceRuntimeID,
                remoteSelections,
                row
            )
            return true
        }
        return LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.onLocalFileDrop?(paths, row)
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0,
              let dataSource = dataSource as? IndependentRemoteFilesViewController,
              dataSource.tableView.selectedRowIndexes.contains(row)
        else {
            super.otherMouseDown(with: event)
            return
        }
        remoteFilePathTerminalSender?(dataSource.currentPath)
    }
}
