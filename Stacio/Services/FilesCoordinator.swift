import AppKit
import Foundation
import StacioAgentBridge
import StacioCoreBindings
import UniformTypeIdentifiers

public protocol RemoteFilesBridging {
    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry]
    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry]
    func searchLiveRemoteFiles(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        keyword: String,
        depth: UInt32
    ) throws -> [RemoteFileEntry]
    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws
    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws
    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws
    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws
    func copyLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws
    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data
    func writeLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64
    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry]
    func createLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws
    func renameLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws
    func deleteLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String,
        recursive: Bool
    ) throws
    func copyLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws
}

public final class CoreBridgeRemoteFilesBridge: RemoteFilesBridging {
    public init() {}

    public func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        try CoreBridge.parseRemoteListing(input)
    }

    public func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        try CoreBridge.listLiveRemoteDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public func searchLiveRemoteFiles(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        keyword: String,
        depth: UInt32
    ) throws -> [RemoteFileEntry] {
        try CoreBridge.searchLiveRemoteFiles(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            keyword: keyword,
            depth: depth
        )
    }

    public func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {
        try CoreBridge.createLiveRemoteDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath
        )
    }

    public func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try CoreBridge.renameLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        try CoreBridge.deleteLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            recursive: recursive
        )
    }

    public func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {
        try CoreBridge.chmodLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            mode: mode
        )
    }

    public func copyLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try CoreBridge.copyLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        try CoreBridge.readLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            offset: offset,
            length: length
        )
    }

    public func writeLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        try CoreBridge.writeLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            contents: contents
        )
    }

    public func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        try CoreBridge.listLiveFTPDirectory(
            config: config,
            secret: secret,
            remotePath: remotePath
        )
    }

    public func createLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws {
        try CoreBridge.createLiveFTPDirectory(
            config: config,
            secret: secret,
            remotePath: remotePath
        )
    }

    public func renameLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        try CoreBridge.renameLiveFTPPath(
            config: config,
            secret: secret,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    public func deleteLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String,
        recursive: Bool
    ) throws {
        try CoreBridge.deleteLiveFTPPath(
            config: config,
            secret: secret,
            remotePath: remotePath,
            recursive: recursive
        )
    }

    public func copyLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        try CoreBridge.copyLiveFTPPath(
            config: config,
            secret: secret,
            fromPath: fromPath,
            toPath: toPath
        )
    }
}

public extension RemoteFilesBridging {
    func copyLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ssh-copy")
    }

    func searchLiveRemoteFiles(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        keyword: String,
        depth: UInt32
    ) throws -> [RemoteFileEntry] {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ssh-search")
    }

    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ssh-read")
    }

    func writeLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ssh-write")
    }

    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ftp")
    }

    func createLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ftp")
    }

    func renameLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ftp")
    }

    func deleteLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String,
        recursive: Bool
    ) throws {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ftp")
    }

    func copyLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ftp")
    }
}

public struct FTPLiveSessionContext {
    public let config: FtpConnectionConfig
    public let secret: FtpAuthSecret

    public init(config: FtpConnectionConfig, secret: FtpAuthSecret) {
        self.config = config
        self.secret = secret
    }
}

@MainActor
public protocol SCPTransferScheduling: AnyObject {
    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    )
    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    )
    func disconnectTransfers(runtimeID: String) -> [String]
    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64)
}

public extension SCPTransferScheduling {
    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduleLiveTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: completion
        )
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) {
        scheduleLiveTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: nil
        )
    }

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) {
        scheduleLiveTransfer(
            runtimeID: config.host,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: nil
        )
    }

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {}

    func disconnectTransfers(runtimeID: String) -> [String] {
        []
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}
}

extension TransferQueueCoordinator: SCPTransferScheduling {}

@MainActor
public protocol FTPTransferScheduling: AnyObject {
    func scheduleLiveFTPTransfer(
        runtimeID: String,
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    )
    func scheduleLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    )
    func disconnectTransfers(runtimeID: String) -> [String]
    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64)
}

public extension FTPTransferScheduling {
    func scheduleLiveFTPTransfer(
        runtimeID: String,
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduleLiveFTPTransfer(
            config: config,
            secret: secret,
            job: job,
            completion: completion
        )
    }

    func scheduleLiveFTPTransfer(
        runtimeID: String,
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) {
        scheduleLiveFTPTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            job: job,
            completion: nil
        )
    }

    func scheduleLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob
    ) {
        scheduleLiveFTPTransfer(
            runtimeID: "ftp://\(config.username)@\(config.host):\(config.port)",
            config: config,
            secret: secret,
            job: job,
            completion: nil
        )
    }

    func scheduleLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {}

    func disconnectTransfers(runtimeID: String) -> [String] {
        []
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}
}

extension TransferQueueCoordinator: FTPTransferScheduling {}

public protocol RemoteFileDownloadDestinationPicking {
    func pickDownloadDestination(suggestedFileName: String, parentWindow: NSWindow?) -> String?
    func pickDownloadDirectory(parentWindow: NSWindow?) -> String?
}

public struct LocalUploadFile: Equatable, Sendable {
    public let path: String
    public let fileName: String
    public let size: UInt64

    public init(path: String, fileName: String, size: UInt64) {
        self.path = path
        self.fileName = fileName
        self.size = size
    }
}

public protocol RemoteFileUploadPicking {
    func pickUploadFile(parentWindow: NSWindow?) -> LocalUploadFile?
    func pickUploadFolder(parentWindow: NSWindow?) -> LocalUploadFile?
}

public typealias LocalUploadSizeProviding = @Sendable (URL) -> UInt64

public enum LocalUploadSizeProvider {
    public static let recursiveByteSize: LocalUploadSizeProviding = { url in
        localUploadByteSize(at: url)
    }
}

public protocol RemoteFileConflictResolving {
    func resolveConflict(destinationPath: String, direction: ScpDirection, parentWindow: NSWindow?) -> ScpConflictPolicy?
}

public struct AppKitRemoteFileConflictResolver: RemoteFileConflictResolving {
    public init() {}

    public func resolveConflict(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> ScpConflictPolicy? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                resolveConflict(
                    destinationPath: destinationPath,
                    direction: direction,
                    parentWindow: parentWindow
                )
            }
        }

        let alert = NSAlert()
        alert.messageText = L10n.Files.conflictTitle
        alert.informativeText = L10n.Files.conflictMessage(destinationPath: destinationPath)
        alert.addButton(withTitle: L10n.Files.keepBoth)
        alert.addButton(withTitle: L10n.Files.overwrite)
        alert.addButton(withTitle: L10n.Files.renameCopy)
        alert.addButton(withTitle: L10n.Files.skip)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .overwrite
        case .alertThirdButtonReturn:
            return .rename
        default:
            return .skip
        }
    }
}

public struct SettingsBackedRemoteFileConflictResolver: RemoteFileConflictResolving {
    private let settingsStore: AppSettingsStore
    private let fallback: RemoteFileConflictResolving

    public init(
        settingsStore: AppSettingsStore = .shared,
        fallback: RemoteFileConflictResolving = AppKitRemoteFileConflictResolver()
    ) {
        self.settingsStore = settingsStore
        self.fallback = fallback
    }

    public func resolveConflict(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> ScpConflictPolicy? {
        if let policy = settingsStore.snapshot().filesTransferConflictPolicy.scpConflictPolicy {
            return policy
        }
        return fallback.resolveConflict(
            destinationPath: destinationPath,
            direction: direction,
            parentWindow: parentWindow
        )
    }
}

public struct AppKitRemoteFileDownloadDestinationPicker: RemoteFileDownloadDestinationPicking {
    public init() {}

    public func pickDownloadDestination(suggestedFileName: String, parentWindow: NSWindow?) -> String? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                pickDownloadDestination(suggestedFileName: suggestedFileName, parentWindow: parentWindow)
            }
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.message = L10n.Files.chooseDownloadDestination
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let response = panel.runModal()
        parentWindow?.makeKey()
        guard response == .OK else {
            return nil
        }
        return panel.url?.path
    }

    public func pickDownloadDirectory(parentWindow: NSWindow?) -> String? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                pickDownloadDirectory(parentWindow: parentWindow)
            }
        }

        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.Files.chooseDownloadDirectory
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let response = panel.runModal()
        parentWindow?.makeKey()
        guard response == .OK else {
            return nil
        }
        return panel.url?.path
    }
}

public struct AppKitRemoteFileUploadPicker: RemoteFileUploadPicking {
    public init() {}

    public func pickUploadFile(parentWindow: NSWindow?) -> LocalUploadFile? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                pickUploadFile(parentWindow: parentWindow)
            }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.Files.chooseUploadFile

        let response = panel.runModal()
        parentWindow?.makeKey()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        let size = localUploadByteSizeForPickedURL(url)
        return LocalUploadFile(
            path: url.path,
            fileName: url.lastPathComponent,
            size: size
        )
    }

    public func pickUploadFolder(parentWindow: NSWindow?) -> LocalUploadFile? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                pickUploadFolder(parentWindow: parentWindow)
            }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.Files.chooseUploadFolder

        let response = panel.runModal()
        parentWindow?.makeKey()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        return LocalUploadFile(
            path: url.path,
            fileName: url.lastPathComponent,
            size: localUploadByteSizeForPickedURL(url)
        )
    }
}

private func localUploadByteSizeForPickedURL(_ url: URL) -> UInt64 {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return 0
    }
    return isDirectory.boolValue ? 0 : localUploadByteSize(at: url)
}

private func localUploadByteSize(at url: URL) -> UInt64 {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return 0
    }

    guard isDirectory.boolValue else {
        return (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
    }

    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: resourceKeys,
        options: []
    ) else {
        return 0
    }

    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
              values.isRegularFile == true
        else {
            continue
        }
        total = total.saturatingAdding(UInt64(values.fileSize ?? 0))
    }
    return total
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? UInt64.max : result
    }
}

public enum RemoteFileOpenMode: Equatable, Sendable {
    case textEditor
    case mediaPreview
    case chooseApplication
    case defaultApplication

    var logName: String {
        switch self {
        case .textEditor:
            return "textEditor"
        case .mediaPreview:
            return "mediaPreview"
        case .chooseApplication:
            return "chooseApplication"
        case .defaultApplication:
            return "defaultApplication"
        }
    }
}

public protocol RemoteFileOperationPrompting {
    func promptDirectoryName(parentWindow: NSWindow?) -> String?
    func promptFileName(parentWindow: NSWindow?) -> String?
    func promptRenameDestination(currentPath: String, parentWindow: NSWindow?) -> String?
    func confirmDelete(selection: RemoteFileSelection, parentWindow: NSWindow?) -> Bool
    func promptChmodMode(currentPath: String, parentWindow: NSWindow?) -> String?
    func promptOpenApplication(parentWindow: NSWindow?) -> URL?
    func promptBackupCandidates(
        candidates: [RemoteFileBackupCandidate],
        parentWindow: NSWindow?
    ) -> [RemoteFileBackupCandidate]?
    func promptBackupDestination(parentWindow: NSWindow?) -> RemoteFileBackupDestination?
    func promptRestoreSource(parentWindow: NSWindow?) -> RemoteFileRestoreSource?
    func promptRemoteBackupFiles(
        candidates: [RemoteFileSelection],
        parentWindow: NSWindow?
    ) -> [RemoteFileSelection]?
    func promptLocalBackupFiles(parentWindow: NSWindow?) -> [URL]?
}

public struct AppKitRemoteFileOperationPrompt: RemoteFileOperationPrompting {
    public init() {}

    public func promptDirectoryName(parentWindow: NSWindow?) -> String? {
        promptText(
            title: L10n.Files.newDirectoryTitle,
            message: L10n.Files.newDirectoryMessage,
            placeholder: L10n.Files.newDirectoryPlaceholder,
            action: L10n.Files.create
        )
    }

    public func promptFileName(parentWindow: NSWindow?) -> String? {
        promptText(
            title: L10n.Files.newFileTitle,
            message: L10n.Files.newFileMessage,
            placeholder: L10n.Files.newFilePlaceholder,
            action: L10n.Files.create
        )
    }

    public func promptRenameDestination(currentPath: String, parentWindow: NSWindow?) -> String? {
        promptText(
            title: L10n.Files.renameTitle,
            message: L10n.Files.renameMessage,
            placeholder: L10n.Files.renamePlaceholder,
            defaultValue: currentPath,
            action: L10n.Files.renameAction
        )
    }

    public func confirmDelete(selection: RemoteFileSelection, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.Files.deleteTitle
        alert.informativeText = L10n.Files.deleteMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Common.delete)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func promptChmodMode(currentPath: String, parentWindow: NSWindow?) -> String? {
        promptText(
            title: L10n.Files.chmodTitle,
            message: L10n.Files.chmodMessage,
            placeholder: L10n.Files.chmodPlaceholder,
            action: L10n.Files.apply
        )
    }

    public func promptOpenApplication(parentWindow: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle, .unixExecutable]
        panel.message = L10n.Files.chooseOpenApplication
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let response = panel.runModal()
        parentWindow?.makeKey()
        return response == .OK ? panel.url : nil
    }

    public func promptBackupCandidates(
        candidates: [RemoteFileBackupCandidate],
        parentWindow: NSWindow?
    ) -> [RemoteFileBackupCandidate]? {
        let options = candidates.map { "\($0.fileName)  \($0.remotePath)" }
        guard let selectedIndexes = promptCheckboxIndexes(
            title: "选择要备份的文件",
            message: "可选择当前文件标签，也可以勾选多个已打开的文件标签。",
            options: options,
            defaultSelectedIndexes: candidates.isEmpty ? [] : IndexSet(integer: 0),
            action: "继续"
        ) else {
            return nil
        }
        let selected = selectedIndexes.compactMap { candidates.indices.contains($0) ? candidates[$0] : nil }
        return selected.isEmpty ? nil : selected
    }

    public func promptBackupDestination(parentWindow: NSWindow?) -> RemoteFileBackupDestination? {
        let alert = NSAlert()
        alert.messageText = "备份到哪里？"
        alert.informativeText = "当前目录会在远端文件所在目录生成 .bak；本地会下载带时间戳的备份文件。"
        alert.addButton(withTitle: "当前目录")
        alert.addButton(withTitle: "本地")
        alert.addButton(withTitle: L10n.Common.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .remoteDirectory
        case .alertSecondButtonReturn:
            return .local
        default:
            return nil
        }
    }

    public func promptRestoreSource(parentWindow: NSWindow?) -> RemoteFileRestoreSource? {
        let alert = NSAlert()
        alert.messageText = "从哪里恢复？"
        alert.informativeText = "当前目录会列出远端目录中的 .bak 文件；本地会打开访达选择 .bak 文件。"
        alert.addButton(withTitle: "当前目录")
        alert.addButton(withTitle: "本地")
        alert.addButton(withTitle: L10n.Common.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .remoteDirectory
        case .alertSecondButtonReturn:
            return .local
        default:
            return nil
        }
    }

    public func promptRemoteBackupFiles(
        candidates: [RemoteFileSelection],
        parentWindow: NSWindow?
    ) -> [RemoteFileSelection]? {
        let options = candidates.map { ($0.path as NSString).lastPathComponent }
        guard let selectedIndexes = promptCheckboxIndexes(
            title: "选择要恢复的备份",
            message: "Stacio 会把选中的 .bak 文件还原为原始文件名。",
            options: options,
            defaultSelectedIndexes: candidates.isEmpty ? [] : IndexSet(integer: 0),
            action: "恢复"
        ) else {
            return nil
        }
        let selected = selectedIndexes.compactMap { candidates.indices.contains($0) ? candidates[$0] : nil }
        return selected.isEmpty ? nil : selected
    }

    public func promptLocalBackupFiles(parentWindow: NSWindow?) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要恢复的 .bak 文件。"
        if let bakType = UTType(filenameExtension: "bak") {
            panel.allowedContentTypes = [bakType]
        }
        let response = panel.runModal()
        parentWindow?.makeKey()
        guard response == .OK else {
            return nil
        }
        let urls = panel.urls.filter { $0.pathExtension.lowercased() == "bak" }
        return urls.isEmpty ? nil : urls
    }

    private func promptText(
        title: String,
        message: String,
        placeholder: String,
        defaultValue: String = "",
        action: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L10n.Common.cancel)

        let field = NSTextField(string: defaultValue)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func promptCheckboxIndexes(
        title: String,
        message: String,
        options: [String],
        defaultSelectedIndexes: IndexSet,
        action: String
    ) -> IndexSet? {
        guard !options.isEmpty else {
            return nil
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L10n.Common.cancel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = true
        let contentHeight = min(CGFloat(options.count) * 28 + 8, 240)
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: max(contentHeight, 36))
        var checkboxes: [NSButton] = []
        for (index, option) in options.enumerated() {
            let checkbox = NSButton(checkboxWithTitle: option, target: nil, action: nil)
            checkbox.state = defaultSelectedIndexes.contains(index) ? .on : .off
            checkbox.lineBreakMode = .byTruncatingMiddle
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.widthAnchor.constraint(equalToConstant: 420).isActive = true
            checkboxes.append(checkbox)
            stack.addArrangedSubview(checkbox)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = options.count > 8
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: 440,
            height: contentHeight
        )
        alert.accessoryView = scrollView

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        var selected = IndexSet()
        for (index, checkbox) in checkboxes.enumerated() where checkbox.state == .on {
            selected.insert(index)
        }
        return selected
    }
}

public enum RemoteFileErrorContext: Equatable {
    case refresh
    case createDirectory
    case createFile
    case rename
    case delete
    case openRemoteEdit
    case saveRemoteEdit
    case compareFiles
    case chmod
    case backup
    case restore

    public var messageText: String {
        switch self {
        case .refresh:
            return L10n.Files.refreshFailedTitle
        case .createDirectory:
            return L10n.Files.createDirectoryFailedTitle
        case .createFile:
            return L10n.Files.createFileFailedTitle
        case .rename:
            return L10n.Files.renameFailedTitle
        case .delete:
            return L10n.Files.deleteFailedTitle
        case .openRemoteEdit:
            return L10n.Files.openRemoteEditFailedTitle
        case .saveRemoteEdit:
            return L10n.Files.saveRemoteEditFailedTitle
        case .compareFiles:
            return L10n.Files.compareFilesFailedTitle
        case .chmod:
            return L10n.Files.chmodFailedTitle
        case .backup:
            return L10n.Files.backupFailedTitle
        case .restore:
            return L10n.Files.restoreFailedTitle
        }
    }

    func informativeText(for error: Error) -> String {
        if let filesError = error as? FilesError {
            switch filesError {
            case .InvalidListingRow, .InvalidFileKind, .InvalidFileSize:
                return L10n.Files.invalidListingMessage
            case .UnsafePath:
                return L10n.Files.unsafePathMessage
            }
        }
        if let remoteEditError = error as? RemoteEditCacheError,
           case .remoteChanged = remoteEditError
        {
            return "远端文件已更新，请重新打开后再保存，避免覆盖新的远端内容"
        }
        let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.Files.operationFailedMessage : message
    }
}

public enum FilesCoordinatorError: Error, LocalizedError, Equatable {
    case missingLiveSSHContext

    public var errorDescription: String? {
        switch self {
        case .missingLiveSSHContext:
            return L10n.Files.missingLiveSSHContext
        }
    }
}

public protocol RemoteEditOpening: AnyObject {
    @MainActor
    func prepareToOpenRemote(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool
    @MainActor
    func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    )
    @MainActor
    func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    )
    @MainActor
    func remoteOpenDidFail(selection: RemoteFileSelection, mode: RemoteFileOpenMode, message: String)
    @MainActor
    func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws
}

public extension RemoteEditOpening {
    @MainActor
    func prepareToOpenRemote(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        true
    }

    @MainActor
    func remoteOpenDidFail(selection: RemoteFileSelection, mode: RemoteFileOpenMode, message: String) {}

    @MainActor
    func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {
        let localURL = URL(fileURLWithPath: document.remotePath)
        openLocalCopy(
            at: localURL,
            mode: mode,
            applicationURL: nil,
            saveHandler: nil
        )
    }
}

public typealias RemoteEditSaveHandler = () throws -> Void

@MainActor
public final class AppKitRemoteEditOpener: RemoteEditOpening {
    private var editorWindows: [String: RemoteTextEditorWindowController] = [:]
    private var mediaPreviewWindows: [String: RemoteMediaPreviewWindowController] = [:]

    public init() {}

    @MainActor
    public func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode = .defaultApplication,
        applicationURL: URL? = nil,
        saveHandler: RemoteEditSaveHandler? = nil
    ) {
        switch mode {
        case .defaultApplication:
            NSWorkspace.shared.open(url)
        case .textEditor:
            openInStacioEditor(url, saveHandler: saveHandler)
        case .mediaPreview:
            openInStacioPreview(url)
        case .chooseApplication:
            if let applicationURL {
                open(url, withApplicationAt: applicationURL)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @MainActor
    public func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws {
        guard urls.count >= 2 else {
            return
        }
        let fileMergeURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/FileMerge.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fileMergeURL.path) else {
            throw RemoteFileCompareError.fileMergeUnavailable
        }
        open(urls[0], withApplicationAt: fileMergeURL, additionalURLs: [urls[1]])
    }

    private func open(_ url: URL, withApplicationAt applicationURL: URL, additionalURLs: [URL] = []) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url] + additionalURLs,
            withApplicationAt: applicationURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    private func openInStacioEditor(_ url: URL, saveHandler: RemoteEditSaveHandler?) {
        if let existing = editorWindows[url.path] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let editor = RemoteTextEditorViewController(localURL: url) { _ in
            try saveHandler?()
        }
        let windowController = RemoteTextEditorWindowController(editorViewController: editor)
        windowController.onClose = { [weak self] controller in
            self?.editorWindows.removeValue(forKey: url.path)
            controller.onClose = nil
        }
        editorWindows[url.path] = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    public func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {
        guard mode == .textEditor || mode == .mediaPreview else {
            openLocalCopy(
                at: URL(fileURLWithPath: document.remotePath),
                mode: mode,
                applicationURL: nil,
                saveHandler: nil
            )
            return
        }
        if let existing = editorWindows[document.remotePath] {
            existing.editorViewController.openDocument(document, onSaveText: saveHandler)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let editor = RemoteTextEditorViewController(document: document, onSaveText: saveHandler)
        let windowController = RemoteTextEditorWindowController(editorViewController: editor)
        windowController.onClose = { [weak self] controller in
            self?.editorWindows.removeValue(forKey: document.remotePath)
            controller.onClose = nil
        }
        editorWindows[document.remotePath] = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func openInStacioPreview(_ url: URL) {
        openInStacioEditor(url, saveHandler: nil)
    }
}

@MainActor
public final class EmbeddedRemoteEditOpener: RemoteEditOpening {
    private weak var filesViewController: FilesViewController?
    private let fallbackOpener: RemoteEditOpening
    private var embeddedOpenRequestIDsByKey: [String: UUID] = [:]

    public init(
        filesViewController: FilesViewController,
        fallbackOpener: RemoteEditOpening? = nil
    ) {
        self.filesViewController = filesViewController
        self.fallbackOpener = fallbackOpener ?? AppKitRemoteEditOpener()
    }

    public func prepareToOpenRemote(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        guard let filesViewController else {
            return fallbackOpener.prepareToOpenRemote(selection: selection, mode: mode)
        }

        switch mode {
        case .textEditor, .mediaPreview:
            guard let requestID = filesViewController.beginEmbeddedOpenRequest(selection: selection, mode: mode) else {
                return false
            }
            embeddedOpenRequestIDsByKey[embeddedOpenRequestKey(remotePath: selection.path, mode: mode)] = requestID
            return true
        case .chooseApplication, .defaultApplication:
            return fallbackOpener.prepareToOpenRemote(selection: selection, mode: mode)
        }
    }

    public func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {
        guard let filesViewController else {
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler
            )
            return
        }

        switch mode {
        case .textEditor:
            filesViewController.presentEmbeddedEditor(
                localURL: url,
                saveHandler: saveHandler
            )
        case .mediaPreview:
            filesViewController.presentEmbeddedMediaPreview(localURL: url)
        case .chooseApplication, .defaultApplication:
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler
            )
        }
    }

    public func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {
        guard let filesViewController else {
            fallbackOpener.openRemoteDocument(document, mode: mode, saveHandler: saveHandler)
            return
        }

        switch mode {
        case .textEditor, .mediaPreview:
            let requestKey = embeddedOpenRequestKey(remotePath: document.remotePath, mode: mode)
            let requestID = embeddedOpenRequestIDsByKey[requestKey]
            guard filesViewController.isEmbeddedOpenRequestActive(requestID) else {
                embeddedOpenRequestIDsByKey[requestKey] = nil
                return
            }
            filesViewController.presentEmbeddedRemoteDocument(document, onSaveText: saveHandler)
            filesViewController.finishEmbeddedOpenRequest(requestID)
            embeddedOpenRequestIDsByKey[requestKey] = nil
        case .chooseApplication, .defaultApplication:
            fallbackOpener.openRemoteDocument(document, mode: mode, saveHandler: saveHandler)
        }
    }

    public func remoteOpenDidFail(selection: RemoteFileSelection, mode: RemoteFileOpenMode, message: String) {
        guard let filesViewController else {
            fallbackOpener.remoteOpenDidFail(selection: selection, mode: mode, message: message)
            return
        }

        switch mode {
        case .textEditor, .mediaPreview:
            let requestKey = embeddedOpenRequestKey(remotePath: selection.path, mode: mode)
            let requestID = embeddedOpenRequestIDsByKey[requestKey]
            guard filesViewController.isEmbeddedOpenRequestActive(requestID) else {
                embeddedOpenRequestIDsByKey[requestKey] = nil
                return
            }
            if let editor = filesViewController.embeddedEditorViewControllerForTesting {
                editor.openFailedDocument(
                    remotePath: selection.path,
                    fileName: (selection.path as NSString).lastPathComponent,
                    message: message,
                    byteCount: selection.size
                )
                filesViewController.finishEmbeddedOpenRequest(requestID)
                embeddedOpenRequestIDsByKey[requestKey] = nil
                return
            }
            filesViewController.presentEmbeddedOpenFailure(selection: selection, mode: mode, message: message)
            filesViewController.finishEmbeddedOpenRequest(requestID)
            embeddedOpenRequestIDsByKey[requestKey] = nil
        case .chooseApplication, .defaultApplication:
            fallbackOpener.remoteOpenDidFail(selection: selection, mode: mode, message: message)
        }
    }

    public func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws {
        try fallbackOpener.compareLocalCopies(urls, parentWindow: parentWindow)
    }

    private func embeddedOpenRequestKey(remotePath: String, mode: RemoteFileOpenMode) -> String {
        "\(mode.logName):\(remotePath)"
    }
}

public enum RemoteFileCompareError: Error, LocalizedError, Equatable {
    case fileMergeUnavailable
    case requiresTwoFiles

    public var errorDescription: String? {
        switch self {
        case .fileMergeUnavailable:
            return L10n.Files.compareUnavailableMessage
        case .requiresTwoFiles:
            return L10n.Files.compareRequiresTwoFilesMessage
        }
    }
}

public protocol RemoteFileErrorPresenting: AnyObject {
    @MainActor
    func present(_ error: Error, context: RemoteFileErrorContext, parentWindow: NSWindow?)
}

public final class AppKitRemoteFileErrorPresenter: RemoteFileErrorPresenting {
    public init() {}

    @MainActor
    public func present(_ error: Error, context: RemoteFileErrorContext, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = context.messageText
        alert.informativeText = context.informativeText(for: error)
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}

private enum LocalUploadSelectionKind {
    case file
    case folder
}

public enum RemoteFileBackupDestination: Equatable, Sendable {
    case remoteDirectory
    case local
}

public enum RemoteFileRestoreSource: Equatable, Sendable {
    case remoteDirectory
    case local
}

public struct RemoteFileBackupCandidate: Equatable, Sendable {
    public let fileName: String
    public let remotePath: String
    public let localURL: URL
    public let size: UInt64

    public init(fileName: String, remotePath: String, localURL: URL, size: UInt64) {
        self.fileName = fileName
        self.remotePath = remotePath
        self.localURL = localURL
        self.size = size
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

public enum RemoteFileBackupNaming {
    public static func backupFileName(
        originalFileName: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmm"
        return "\(originalFileName)-\(formatter.string(from: date)).bak"
    }

    public static func restoredFileName(fromBackupFileName backupFileName: String) -> String? {
        let pattern = #"-\d{12}\.bak$"#
        guard let range = backupFileName.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let restored = String(backupFileName[..<range.lowerBound])
        return restored.isEmpty ? nil : restored
    }
}

@MainActor
public final class FilesCoordinator {
    public static let maximumAIContextAttachmentBytes: UInt64 = 256 * 1024

    enum DirectoryRefreshPresentation: Equatable {
        case interactive
        case backgroundFollow
    }

    private let bridge: RemoteFilesBridging
    private let liveSessionContextProvider: () -> TunnelLiveSessionContext?
    private let liveSessionRuntimeIDProvider: () -> String?
    private let ftpSessionContextProvider: () -> FTPLiveSessionContext?
    private weak var transferScheduler: SCPTransferScheduling?
    private weak var ftpTransferScheduler: FTPTransferScheduling?
    private let downloadDestinationPicker: RemoteFileDownloadDestinationPicking
    private let uploadFilePicker: RemoteFileUploadPicking
    private let operationPrompt: RemoteFileOperationPrompting
    private let errorPresenter: RemoteFileErrorPresenting
    private let conflictResolver: RemoteFileConflictResolving
    private let remoteEditCache: RemoteEditCache
    private let remoteEditOpener: RemoteEditOpening
    private let remoteEditSessionIDProvider: () -> String
    private let settingsStore: AppSettingsStore
    private let localUploadSizeProvider: LocalUploadSizeProviding
    private let appLog: StacioLogWriting?
    private weak var filesViewController: FilesViewController?
    private var directoryLoadGeneration = 0
    private var remoteSearchGeneration = 0
    private var directoryListingCache: [String: [RemoteFileEntry]] = [:]
    private var liveDirectoryDisconnectedMessage: String?
    private var pendingUploadCompletionRefreshDirectories: [String] = []
    private var hasScheduledUploadCompletionRefresh = false

    public init(
        bridge: RemoteFilesBridging = CoreBridgeRemoteFilesBridge(),
        filesViewController: FilesViewController,
        liveSessionContextProvider: @escaping () -> TunnelLiveSessionContext? = { nil },
        liveSessionRuntimeIDProvider: @escaping () -> String? = { nil },
        ftpSessionContextProvider: @escaping () -> FTPLiveSessionContext? = { nil },
        transferScheduler: SCPTransferScheduling? = nil,
        ftpTransferScheduler: FTPTransferScheduling? = nil,
        downloadDestinationPicker: RemoteFileDownloadDestinationPicking = AppKitRemoteFileDownloadDestinationPicker(),
        uploadFilePicker: RemoteFileUploadPicking = AppKitRemoteFileUploadPicker(),
        operationPrompt: RemoteFileOperationPrompting = AppKitRemoteFileOperationPrompt(),
        errorPresenter: RemoteFileErrorPresenting = AppKitRemoteFileErrorPresenter(),
        conflictResolver: RemoteFileConflictResolving = SettingsBackedRemoteFileConflictResolver(),
        remoteEditCache: RemoteEditCache? = nil,
        remoteEditOpener: RemoteEditOpening? = nil,
        remoteEditSessionIDProvider: @escaping () -> String = { "default" },
        settingsStore: AppSettingsStore = .shared,
        localUploadSizeProvider: @escaping LocalUploadSizeProviding = LocalUploadSizeProvider.recursiveByteSize,
        appLog: StacioLogWriting? = StacioLogStore.shared
    ) {
        self.bridge = bridge
        self.liveSessionContextProvider = liveSessionContextProvider
        self.liveSessionRuntimeIDProvider = liveSessionRuntimeIDProvider
        self.ftpSessionContextProvider = ftpSessionContextProvider
        self.transferScheduler = transferScheduler
        self.ftpTransferScheduler = ftpTransferScheduler
        self.downloadDestinationPicker = downloadDestinationPicker
        self.uploadFilePicker = uploadFilePicker
        self.operationPrompt = operationPrompt
        self.errorPresenter = errorPresenter
        self.conflictResolver = conflictResolver
        self.remoteEditCache = remoteEditCache ?? Self.makeDefaultRemoteEditCache()
        self.remoteEditOpener = remoteEditOpener ?? EmbeddedRemoteEditOpener(filesViewController: filesViewController)
        self.remoteEditSessionIDProvider = remoteEditSessionIDProvider
        self.settingsStore = settingsStore
        self.localUploadSizeProvider = localUploadSizeProvider
        self.appLog = appLog
        self.filesViewController = filesViewController
        filesViewController.onRefresh = { [weak self] remotePath in
            self?.refreshCurrentLiveDirectory(remotePath: remotePath)
        }
        filesViewController.onOpenDirectory = { [weak self] remotePath in
            self?.refreshCurrentLiveDirectory(remotePath: remotePath)
        }
        filesViewController.onDownloadFile = { [weak self] selection in
            self?.scheduleDownloads([selection])
        }
        filesViewController.onDownloadSelections = { [weak self] selections in
            self?.scheduleDownloads(selections)
        }
        filesViewController.onUploadFile = { [weak self] remoteDirectory in
            self?.scheduleUpload(remoteDirectory: remoteDirectory)
        }
        filesViewController.onUploadFolder = { [weak self] remoteDirectory in
            self?.scheduleUploadFolder(remoteDirectory: remoteDirectory)
        }
        filesViewController.onUploadDroppedFiles = { [weak self] remoteDirectory, localPaths in
            self?.scheduleDroppedUploads(localPaths: localPaths, remoteDirectory: remoteDirectory)
        }
        filesViewController.onCreateDirectory = { [weak self] remoteDirectory in
            self?.createDirectory(in: remoteDirectory)
        }
        filesViewController.onCreateFile = { [weak self] remoteDirectory in
            self?.createFile(in: remoteDirectory)
        }
        filesViewController.onRenamePath = { [weak self] selection in
            self?.rename(selection)
        }
        filesViewController.onDeletePath = { [weak self] selection in
            self?.delete(selection)
        }
        filesViewController.onDeleteSelections = { [weak self] selections in
            self?.delete(selections)
        }
        filesViewController.onOpenRemoteEdit = { [weak self] selection in
            self?.openRemoteEdit(selection)
        }
        filesViewController.onOpenRemotePreview = { [weak self] selection in
            self?.openRemotePreview(selection)
        }
        filesViewController.onOpenRemoteWith = { [weak self] selection in
            self?.openRemote(selection, mode: .chooseApplication)
        }
        filesViewController.onOpenRemoteWithDefaultApplication = { [weak self] selection in
            self?.openRemote(selection, mode: .defaultApplication)
        }
        filesViewController.onCompareFiles = { [weak self] selections in
            self?.compareFiles(selections)
        }
        filesViewController.onSaveRemoteEdit = { [weak self] selection in
            self?.saveRemoteEdit(selection)
        }
        filesViewController.onSyncChangedRemoteEdits = { [weak self] in
            self?.syncChangedRemoteEdits()
        }
        filesViewController.onChmodPath = { [weak self] selection in
            self?.chmod(selection)
        }
        filesViewController.onSearchRemoteFiles = { [weak self] keyword, directory, depth in
            self?.searchRemoteFilesInBackground(keyword: keyword, directory: directory, depth: depth)
        }
        filesViewController.onOpenSearchResult = { [weak self] result in
            self?.openRemoteSearchResult(result)
        }
        filesViewController.onRemoteSearchClosed = { [weak self] in
            self?.remoteSearchGeneration += 1
        }
        updateRemoteSearchAvailability()
    }

    @discardableResult
    public func loadListing(_ listing: String) throws -> [RemoteFileEntry] {
        let entries = try bridge.parseRemoteListing(listing)
        filesViewController?.setRemoteEntries(entries)
        return entries
    }

    @discardableResult
    public func loadLiveDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        filesViewController?.setRemoteSearchAvailable(true)
        let normalizedPath = Self.normalizedRemoteDirectoryPath(remotePath)
        let entries = try bridge.listLiveRemoteDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: normalizedPath
        )
        cacheSSHDirectoryListing(
            entries,
            config: config,
            sessionID: remoteEditSessionIDProvider(),
            remotePath: normalizedPath
        )
        filesViewController?.setRemoteEntries(entries, remotePath: normalizedPath)
        return entries
    }

    @discardableResult
    public func loadCurrentLiveDirectory(remotePath: String) throws -> [RemoteFileEntry] {
        let normalizedPath = Self.normalizedRemoteDirectoryPath(remotePath)
        if let context = ftpSessionContextProvider() {
            updateRemoteSearchAvailability(ftpContext: context, sshContext: nil)
            let entries = try bridge.listLiveFTPDirectory(
                config: context.config,
                secret: context.secret,
                remotePath: normalizedPath
            )
            cacheFTPDirectoryListing(
                entries,
                config: context.config,
                remotePath: normalizedPath
            )
            filesViewController?.setRemoteEntries(entries, remotePath: normalizedPath)
            return entries
        }

        guard let context = liveSessionContextProvider() else {
            updateRemoteSearchAvailability(ftpContext: nil, sshContext: nil)
            throw FilesCoordinatorError.missingLiveSSHContext
        }
        updateRemoteSearchAvailability(ftpContext: nil, sshContext: context)

        return try loadLiveDirectory(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: normalizedPath
        )
    }

    @discardableResult
    public func searchRemoteFiles(keyword: String, directory: String, depth: Int) throws -> [RemoteFileEntry] {
        guard ftpSessionContextProvider() == nil else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("ftp-search")
        }
        guard let context = liveSessionContextProvider() else {
            throw FilesCoordinatorError.missingLiveSSHContext
        }
        let normalizedDirectory = Self.normalizedRemoteDirectoryPath(directory)
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyword.isEmpty else {
            filesViewController?.setRemoteSearchResults([], baseDirectory: normalizedDirectory, keyword: normalizedKeyword)
            return []
        }
        let normalizedDepth = UInt32(min(max(depth, 1), 20))
        let entries = try bridge.searchLiveRemoteFiles(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: normalizedDirectory,
            keyword: normalizedKeyword,
            depth: normalizedDepth
        )
        filesViewController?.setRemoteSearchResults(
            entries,
            baseDirectory: normalizedDirectory,
            keyword: normalizedKeyword
        )
        return entries
    }

    public func makeSelectedRemoteFileAIContextAttachment() throws -> AIAssistantAttachment {
        guard ftpSessionContextProvider() == nil else {
            throw AIAssistantRemoteFileAttachmentError.unsupportedProtocol
        }
        guard let selection = filesViewController?.currentSelectedFileSelection,
              selection.isFile
        else {
            throw AIAssistantRemoteFileAttachmentError.noFileSelected
        }
        guard selection.size <= Self.maximumAIContextAttachmentBytes else {
            throw AIAssistantRemoteFileAttachmentError.fileTooLarge
        }
        guard let context = liveSessionContextProvider() else {
            throw AIAssistantRemoteFileAttachmentError.unsupportedProtocol
        }

        let data = try bridge.readLiveRemoteFile(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: selection.path,
            offset: 0,
            length: Self.maximumAIContextAttachmentBytes
        )
        guard data.count <= Self.maximumAIContextAttachmentBytes,
              let text = Self.strictUTF8Text(from: data)
        else {
            throw AIAssistantRemoteFileAttachmentError.textOnly
        }
        let fileName = (selection.path as NSString).lastPathComponent
        let redacted = AgentProtocolRedaction.redact(text)
        return AIAssistantAttachment(
            filename: fileName,
            mimeType: Self.aiContextMimeType(forFileName: fileName),
            byteCount: Int(selection.size),
            textPreview: String(redacted.prefix(8_000))
        )
    }

    public func canAttachSelectedRemoteFileAsAIContext() -> Bool {
        guard ftpSessionContextProvider() == nil,
              liveSessionContextProvider() != nil,
              let selection = filesViewController?.currentSelectedFileSelection,
              selection.isFile
        else {
            return false
        }
        return selection.size <= Self.maximumAIContextAttachmentBytes
    }

    public func showInitialLoadError(_ error: Error) {
        filesViewController?.setRemoteListingError(Self.remoteListingErrorMessage(for: error))
    }

    @discardableResult
    private func updateRemoteSearchAvailability(
        ftpContext: FTPLiveSessionContext? = nil,
        sshContext: TunnelLiveSessionContext? = nil
    ) -> Bool {
        let resolvedFTPContext = ftpContext ?? ftpSessionContextProvider()
        let resolvedSSHContext = resolvedFTPContext == nil ? (sshContext ?? liveSessionContextProvider()) : nil
        let isAvailable = resolvedFTPContext == nil && resolvedSSHContext != nil
        filesViewController?.setRemoteSearchAvailable(isAvailable)
        return isAvailable
    }

    public func disconnectCurrentLiveDirectory(message: String) {
        directoryLoadGeneration += 1
        remoteSearchGeneration += 1
        liveDirectoryDisconnectedMessage = message
        filesViewController?.setRemoteSearchAvailable(false)
        filesViewController?.setRemoteListingError(message)
    }

    private static func strictUTF8Text(from data: Data) -> String? {
        guard data.contains(0) == false,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let scalarCount = text.unicodeScalars.count
        guard scalarCount > 0 else {
            return nil
        }
        let controlCount = text.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory == .control
                && scalar != "\n"
                && scalar != "\r"
                && scalar != "\t"
        }.count
        guard Double(controlCount) / Double(scalarCount) < 0.05 else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func aiContextMimeType(forFileName fileName: String) -> String {
        let baseName = (fileName as NSString).lastPathComponent.lowercased()
        let fileExtension = (baseName as NSString).pathExtension
        if baseName == ".env" || baseName.hasPrefix(".env.") || fileExtension.isEmpty {
            return "text/plain"
        }
        switch fileExtension {
        case "md", "markdown":
            return "text/markdown"
        case "json":
            return "application/json"
        case "csv":
            return "text/csv"
        case "xml":
            return "application/xml"
        case "html", "htm":
            return "text/html"
        case "yaml", "yml":
            return "application/yaml"
        case "swift":
            return "text/x-swift"
        case "sh", "bash", "zsh":
            return "text/x-shellscript"
        case "py":
            return "text/x-python"
        case "js":
            return "text/javascript"
        case "ts":
            return "text/typescript"
        case "css":
            return "text/css"
        default:
            return "text/plain"
        }
    }

    private static func remoteListingErrorMessage(for error: Error) -> String {
        if let filesError = error as? FilesError {
            switch filesError {
            case .InvalidListingRow, .InvalidFileKind, .InvalidFileSize:
                return L10n.Files.invalidListingMessage
            case .UnsafePath:
                return L10n.Files.unsafePathMessage
            }
        }
        let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.Files.operationFailedMessage : message
    }

    private func scheduleDownloads(_ selections: [RemoteFileSelection]) {
        let downloadSelections = selections.filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !downloadSelections.isEmpty else {
            return
        }

        if let context = ftpSessionContextProvider(),
           let ftpTransferScheduler
        {
            scheduleFTPDownloads(downloadSelections, context: context, transferScheduler: ftpTransferScheduler)
            return
        }

        guard let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            return
        }
        let runtimeID = liveSessionRuntimeID(for: context)

        guard let plannedDownloads = plannedDownloadDestinations(for: downloadSelections) else {
            return
        }

        for plannedDownload in plannedDownloads {
            let job = ScpTransferJob(
                id: "scp_download_\(UUID().uuidString)",
                direction: .download,
                sourcePath: plannedDownload.selection.path,
                destinationPath: plannedDownload.destinationPath,
                bytesTotal: plannedDownload.selection.size
            )
            transferScheduler.scheduleLiveTransfer(
                runtimeID: runtimeID,
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                job: job
            )
        }
    }

    private func scheduleFTPDownloads(
        _ selections: [RemoteFileSelection],
        context: FTPLiveSessionContext,
        transferScheduler: FTPTransferScheduling
    ) {
        guard let plannedDownloads = plannedDownloadDestinations(for: selections) else {
            return
        }
        let runtimeID = ftpRemoteEditRuntimeID(for: context)

        for plannedDownload in plannedDownloads {
            let job = ScpTransferJob(
                id: "ftp_download_\(UUID().uuidString)",
                direction: .download,
                sourcePath: plannedDownload.selection.path,
                destinationPath: plannedDownload.destinationPath,
                bytesTotal: plannedDownload.selection.size
            )
            transferScheduler.scheduleLiveFTPTransfer(
                runtimeID: runtimeID,
                config: context.config,
                secret: context.secret,
                job: job
            )
        }
    }

    func refreshCurrentLiveDirectory(
        remotePath: String,
        presentation: DirectoryRefreshPresentation = .interactive,
        onSuccess: ((String) -> Void)? = nil,
        onFailure: ((String, Error) -> Void)? = nil
    ) {
        let normalizedPath = Self.normalizedRemoteDirectoryPath(remotePath)
        let ftpContext = ftpSessionContextProvider()
        let sshContext = liveSessionContextProvider()
        updateRemoteSearchAvailability(ftpContext: ftpContext, sshContext: sshContext)
        if ftpContext != nil || sshContext != nil {
            liveDirectoryDisconnectedMessage = nil
        }
        guard ftpContext != nil || sshContext != nil else {
            let message = liveDirectoryDisconnectedMessage
                ?? Self.remoteListingErrorMessage(for: FilesCoordinatorError.missingLiveSSHContext)
            switch presentation {
            case .interactive:
                filesViewController?.setRemoteListingError(message)
            case .backgroundFollow:
                filesViewController?.finishRemoteListingRefresh()
                filesViewController?.setRemoteEditSyncStatus(
                    message: "目录跟随暂未刷新：\(message)",
                    progressValue: nil
                )
                onFailure?(normalizedPath, FilesCoordinatorError.missingLiveSSHContext)
            }
            return
        }

        directoryLoadGeneration += 1
        let generation = directoryLoadGeneration
        let bridgeBox = UncheckedSendableBox(bridge)
        let ftpContextBox = ftpContext.map(UncheckedSendableBox.init)
        let sshContextBox = sshContext.map(UncheckedSendableBox.init)
        let cacheKey = directoryListingCacheKey(
            remotePath: normalizedPath,
            ftpContext: ftpContext,
            sshContext: sshContext
        )
        let cachedEntries = cacheKey.flatMap { directoryListingCache[$0] }
        if let cachedEntries,
           presentation == .interactive
        {
            filesViewController?.setRemoteEntries(
                cachedEntries,
                remotePath: normalizedPath,
                isBackgroundRefreshing: true
            )
        } else if presentation == .backgroundFollow {
            filesViewController?.setRemoteEditSyncStatus(
                message: "正在跟随终端目录：\(normalizedPath)",
                progressValue: nil
            )
        } else {
            filesViewController?.setRemoteListingLoading(remotePath: normalizedPath)
        }

        let loadDirectory: () -> Result<[RemoteFileEntry], Error> = {
            do {
                if let ftpContext = ftpContextBox?.value {
                    let entries = try bridgeBox.value.listLiveFTPDirectory(
                        config: ftpContext.config,
                        secret: ftpContext.secret,
                        remotePath: normalizedPath
                    )
                    return .success(entries)
                } else if let sshContext = sshContextBox?.value {
                    let entries = try bridgeBox.value.listLiveRemoteDirectory(
                        config: sshContext.config,
                        secret: sshContext.secret,
                        expectedFingerprintSHA256: sshContext.expectedFingerprintSHA256,
                        remotePath: normalizedPath
                    )
                    return .success(entries)
                } else {
                    return .failure(FilesCoordinatorError.missingLiveSSHContext)
                }
            } catch {
                return .failure(error)
            }
        }

        let applyResult: (Result<[RemoteFileEntry], Error>) -> Void = { [weak self] result in
            guard let self,
                  generation == self.directoryLoadGeneration
            else {
                return
            }

            switch result {
            case .success(let entries):
                if let ftpContext = ftpContextBox?.value {
                    self.cacheFTPDirectoryListing(
                        entries,
                        config: ftpContext.config,
                        remotePath: normalizedPath
                    )
                } else if let sshContext = sshContextBox?.value {
                    self.cacheSSHDirectoryListing(
                        entries,
                        config: sshContext.config,
                        sessionID: self.remoteEditSessionIDProvider(),
                        remotePath: normalizedPath
                    )
                } else if let cacheKey {
                    self.directoryListingCache[cacheKey] = entries
                }
                self.filesViewController?.setRemoteEntries(entries, remotePath: normalizedPath)
                onSuccess?(normalizedPath)
            case .failure(let error):
                if presentation == .backgroundFollow {
                    self.filesViewController?.finishRemoteListingRefresh()
                    self.filesViewController?.setRemoteEditSyncStatus(
                        message: "目录跟随暂未刷新：\(Self.remoteListingErrorMessage(for: error))",
                        progressValue: nil
                    )
                    onFailure?(normalizedPath, error)
                    self.appLog?.append(
                        level: StacioLogLevel.warning,
                        category: "Files",
                        message: [
                            "file.directory.follow.background.failed",
                            "path=\(normalizedPath)",
                            Self.remoteListingErrorMessage(for: error)
                        ].joined(separator: " ")
                    )
                } else if cachedEntries != nil {
                    self.filesViewController?.finishRemoteListingRefresh()
                    self.appLog?.append(
                        level: StacioLogLevel.warning,
                        category: "Files",
                        message: [
                            "file.directory.refresh.background.failed",
                            "path=\(normalizedPath)",
                            Self.remoteListingErrorMessage(for: error)
                        ].joined(separator: " ")
                    )
                } else {
                    self.filesViewController?.setRemoteListingError(Self.remoteListingErrorMessage(for: error))
                    self.present(error, context: .refresh)
                }
            }
        }

        DispatchQueue.global(qos: presentation == .backgroundFollow ? .utility : .userInitiated).async {
            let result = loadDirectory()
            DispatchQueue.main.async {
                applyResult(result)
            }
        }
    }

    private func searchRemoteFilesInBackground(keyword: String, directory: String, depth: Int) {
        guard ftpSessionContextProvider() == nil else {
            filesViewController?.setRemoteSearchAvailable(false)
            return
        }
        guard let context = liveSessionContextProvider() else {
            let normalizedDirectory = Self.normalizedRemoteDirectoryPath(directory)
            filesViewController?.setRemoteSearchError(
                Self.remoteListingErrorMessage(for: FilesCoordinatorError.missingLiveSSHContext),
                baseDirectory: normalizedDirectory,
                keyword: keyword
            )
            return
        }

        remoteSearchGeneration += 1
        let generation = remoteSearchGeneration
        let normalizedDirectory = Self.normalizedRemoteDirectoryPath(directory)
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyword.isEmpty else {
            filesViewController?.setRemoteSearchResults([], baseDirectory: normalizedDirectory, keyword: normalizedKeyword)
            return
        }
        let normalizedDepth = UInt32(min(max(depth, 1), 20))
        filesViewController?.setRemoteSearchLoading(keyword: normalizedKeyword, baseDirectory: normalizedDirectory)

        let bridgeBox = UncheckedSendableBox(bridge)
        let contextBox = UncheckedSendableBox(context)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[RemoteFileEntry], Error>
            do {
                let entries = try bridgeBox.value.searchLiveRemoteFiles(
                    config: contextBox.value.config,
                    secret: contextBox.value.secret,
                    expectedFingerprintSHA256: contextBox.value.expectedFingerprintSHA256,
                    remotePath: normalizedDirectory,
                    keyword: normalizedKeyword,
                    depth: normalizedDepth
                )
                result = .success(entries)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.remoteSearchGeneration
                else {
                    return
                }

                switch result {
                case .success(let entries):
                    self.filesViewController?.setRemoteSearchResults(
                        entries,
                        baseDirectory: normalizedDirectory,
                        keyword: normalizedKeyword
                    )
                case .failure(let error):
                    self.filesViewController?.setRemoteSearchError(
                        Self.remoteListingErrorMessage(for: error),
                        baseDirectory: normalizedDirectory,
                        keyword: normalizedKeyword
                    )
                }
            }
        }
    }

    private func openRemoteSearchResult(_ result: RemoteFileSearchResult) {
        let directory = Self.normalizedRemoteDirectoryPath(result.directoryPath)
        filesViewController?.setCurrentRemotePath(directory)
        refreshCurrentLiveDirectory(remotePath: directory, onSuccess: { [weak self] _ in
            self?.filesViewController?.selectRemotePath(result.path)
        })
    }

    func invalidatePendingDirectoryRefresh() {
        directoryLoadGeneration += 1
        remoteSearchGeneration += 1
    }

    private static func normalizedRemoteDirectoryPath(_ remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    private func directoryListingCacheKey(
        remotePath: String,
        ftpContext: FTPLiveSessionContext?,
        sshContext: TunnelLiveSessionContext?
    ) -> String? {
        if let ftpContext {
            return Self.ftpDirectoryListingCacheKey(
                config: ftpContext.config,
                remotePath: remotePath
            )
        }
        if let sshContext {
            return Self.sshDirectoryListingCacheKey(
                config: sshContext.config,
                sessionID: remoteEditSessionIDProvider(),
                remotePath: remotePath
            )
        }
        return nil
    }

    private func cacheSSHDirectoryListing(
        _ entries: [RemoteFileEntry],
        config: SshConnectionConfig,
        sessionID: String,
        remotePath: String
    ) {
        let cachePaths = Self.directoryListingCachePaths(
            requestedPath: remotePath,
            entries: entries
        )
        for cachePath in cachePaths {
            let cacheKey = Self.sshDirectoryListingCacheKey(
                config: config,
                sessionID: sessionID,
                remotePath: cachePath
            )
            directoryListingCache[cacheKey] = entries
        }
    }

    private func cacheFTPDirectoryListing(
        _ entries: [RemoteFileEntry],
        config: FtpConnectionConfig,
        remotePath: String
    ) {
        let cachePaths = Self.directoryListingCachePaths(
            requestedPath: remotePath,
            entries: entries
        )
        for cachePath in cachePaths {
            let cacheKey = Self.ftpDirectoryListingCacheKey(
                config: config,
                remotePath: cachePath
            )
            directoryListingCache[cacheKey] = entries
        }
    }

    private static func directoryListingCachePaths(
        requestedPath: String,
        entries: [RemoteFileEntry]
    ) -> [String] {
        let normalizedRequestedPath = normalizedRemoteDirectoryPath(requestedPath)
        var paths = [normalizedRequestedPath]
        if let inferredPath = inferredDirectoryPath(from: entries),
           inferredPath != normalizedRequestedPath
        {
            paths.append(inferredPath)
        }
        return paths
    }

    private static func inferredDirectoryPath(from entries: [RemoteFileEntry]) -> String? {
        let parentPaths = Set(entries.compactMap { entry -> String? in
            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.isEmpty == false else {
                return nil
            }
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        })
        guard parentPaths.count == 1 else {
            return nil
        }
        return parentPaths.first
    }

    private static func sshDirectoryListingCacheKey(
        config: SshConnectionConfig,
        sessionID: String,
        remotePath: String
    ) -> String {
        directoryListingCacheKey(
            protocolName: "ssh",
            host: config.host,
            port: config.port,
            username: config.username,
            sessionID: sessionID,
            remotePath: remotePath
        )
    }

    private static func ftpDirectoryListingCacheKey(
        config: FtpConnectionConfig,
        remotePath: String
    ) -> String {
        directoryListingCacheKey(
            protocolName: "ftp",
            host: config.host,
            port: config.port,
            username: config.username,
            sessionID: "default",
            remotePath: remotePath
        )
    }

    private static func directoryListingCacheKey(
        protocolName: String,
        host: String,
        port: UInt16,
        username: String,
        sessionID: String,
        remotePath: String
    ) -> String {
        [
            protocolName,
            host,
            String(port),
            username,
            sessionID,
            remotePath
        ].map(directoryListingCacheComponent).joined(separator: "|")
    }

    private static func directoryListingCacheComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "%7C")
    }

    private func scheduleUpload(remoteDirectory: String) {
        schedulePickedUpload(remoteDirectory: remoteDirectory, kind: .file)
    }

    private func scheduleUploadFolder(remoteDirectory: String) {
        schedulePickedUpload(remoteDirectory: remoteDirectory, kind: .folder)
    }

    private func schedulePickedUpload(remoteDirectory: String, kind: LocalUploadSelectionKind) {
        if let context = ftpSessionContextProvider(),
           let ftpTransferScheduler,
           let localFile = pickLocalUpload(kind: kind)
        {
            scheduleFTPUpload(
                localFile: localFile,
                remoteDirectory: remoteDirectory,
                context: context,
                transferScheduler: ftpTransferScheduler
            )
            return
        }

        guard let context = liveSessionContextProvider(),
              let transferScheduler,
              let localFile = pickLocalUpload(kind: kind)
        else {
            return
        }

        scheduleUpload(localFile: localFile, remoteDirectory: remoteDirectory, context: context, transferScheduler: transferScheduler)
    }

    private func pickLocalUpload(kind: LocalUploadSelectionKind) -> LocalUploadFile? {
        switch kind {
        case .file:
            uploadFilePicker.pickUploadFile(parentWindow: filesViewController?.view.window)
        case .folder:
            uploadFilePicker.pickUploadFolder(parentWindow: filesViewController?.view.window)
        }
    }

    private func scheduleFTPUpload(
        localFile: LocalUploadFile,
        remoteDirectory: String,
        context: FTPLiveSessionContext,
        transferScheduler: FTPTransferScheduling
    ) {
        let destinationPath = remoteDestinationPath(directory: remoteDirectory, fileName: localFile.fileName)
        guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
            destinationPath,
            direction: .upload,
            conflictExists: filesViewController?.containsRemoteEntry(named: localFile.fileName) ?? false
        ) else {
            return
        }

        let job = ScpTransferJob(
            id: "ftp_upload_\(UUID().uuidString)",
            direction: .upload,
            sourcePath: localFile.path,
            destinationPath: resolvedDestinationPath,
            bytesTotal: localFile.size
        )
        transferScheduler.scheduleLiveFTPTransfer(
            config: context.config,
            secret: context.secret,
            job: job,
            completion: { [weak self] progress in
                self?.refreshRemoteDirectoryAfterUploadCompletion(progress, remoteDirectory: remoteDirectory)
            }
        )
        estimateUploadSizeIfNeeded(localFile: localFile, jobID: job.id, scheduler: transferScheduler)
    }

    public func scheduleDroppedUploads(
        localPaths: [String],
        remoteDirectory: String,
        runtimeID: String,
        context: TunnelLiveSessionContext,
        transferScheduler: SCPTransferScheduling
    ) {
        for localPath in localPaths {
            scheduleUpload(
                localFile: localUploadFile(for: localPath),
                remoteDirectory: remoteDirectory,
                runtimeID: runtimeID,
                context: context,
                transferScheduler: transferScheduler
            )
        }
    }

    private func scheduleDroppedUploads(localPaths: [String], remoteDirectory: String) {
        if let context = ftpSessionContextProvider(),
           let ftpTransferScheduler
        {
            for localPath in localPaths {
                scheduleFTPUpload(
                    localFile: localUploadFile(for: localPath),
                    remoteDirectory: remoteDirectory,
                    context: context,
                    transferScheduler: ftpTransferScheduler
                )
            }
            return
        }

        guard let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            return
        }

        for localPath in localPaths {
            scheduleUpload(
                localFile: localUploadFile(for: localPath),
                remoteDirectory: remoteDirectory,
                runtimeID: liveSessionRuntimeID(for: context),
                context: context,
                transferScheduler: transferScheduler
            )
        }
    }

    private func localUploadFile(for localPath: String) -> LocalUploadFile {
        let url = URL(fileURLWithPath: localPath)
        return LocalUploadFile(
            path: localPath,
            fileName: url.lastPathComponent,
            size: localUploadByteSizeForPickedURL(url)
        )
    }

    private func scheduleUpload(
        localFile: LocalUploadFile,
        remoteDirectory: String,
        context: TunnelLiveSessionContext,
        transferScheduler: SCPTransferScheduling
    ) {
        scheduleUpload(
            localFile: localFile,
            remoteDirectory: remoteDirectory,
            runtimeID: liveSessionRuntimeID(for: context),
            context: context,
            transferScheduler: transferScheduler
        )
    }

    private func scheduleUpload(
        localFile: LocalUploadFile,
        remoteDirectory: String,
        runtimeID: String,
        context: TunnelLiveSessionContext,
        transferScheduler: SCPTransferScheduling
    ) {
        let destinationPath = remoteDestinationPath(directory: remoteDirectory, fileName: localFile.fileName)
        guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
            destinationPath,
            direction: .upload,
            conflictExists: filesViewController?.containsRemoteEntry(named: localFile.fileName) ?? false
        ) else {
            return
        }

        let job = ScpTransferJob(
            id: "scp_upload_\(UUID().uuidString)",
            direction: .upload,
            sourcePath: localFile.path,
            destinationPath: resolvedDestinationPath,
            bytesTotal: localFile.size
        )
        transferScheduler.scheduleLiveTransfer(
            runtimeID: runtimeID,
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            job: job,
            completion: { [weak self] progress in
                self?.refreshRemoteDirectoryAfterUploadCompletion(progress, remoteDirectory: remoteDirectory)
            }
        )
        estimateUploadSizeIfNeeded(localFile: localFile, jobID: job.id, scheduler: transferScheduler)
    }

    private func refreshRemoteDirectoryAfterUploadCompletion(
        _ progress: ScpTransferProgress,
        remoteDirectory: String
    ) {
        guard progress.status == "completed" else {
            return
        }
        scheduleUploadCompletionRefresh(remoteDirectory: remoteDirectory)
    }

    private func scheduleUploadCompletionRefresh(remoteDirectory: String) {
        let normalizedDirectory = Self.normalizedRemoteDirectoryPath(remoteDirectory)
        if pendingUploadCompletionRefreshDirectories.contains(normalizedDirectory) == false {
            pendingUploadCompletionRefreshDirectories.append(normalizedDirectory)
        }
        guard hasScheduledUploadCompletionRefresh == false else {
            return
        }
        hasScheduledUploadCompletionRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            let directories = self.pendingUploadCompletionRefreshDirectories
            self.pendingUploadCompletionRefreshDirectories.removeAll(keepingCapacity: true)
            self.hasScheduledUploadCompletionRefresh = false
            directories.forEach { directory in
                self.refreshCurrentLiveDirectory(remotePath: directory)
            }
        }
    }

    private func estimateUploadSizeIfNeeded(
        localFile: LocalUploadFile,
        jobID: String,
        scheduler: SCPTransferScheduling
    ) {
        estimateUploadSizeIfNeeded(
            localFile: localFile,
            jobID: jobID,
            update: { scheduler.updateScheduledTransferEstimatedByteTotal(jobID: $0, bytesTotal: $1) }
        )
    }

    private func estimateUploadSizeIfNeeded(
        localFile: LocalUploadFile,
        jobID: String,
        scheduler: FTPTransferScheduling
    ) {
        estimateUploadSizeIfNeeded(
            localFile: localFile,
            jobID: jobID,
            update: { scheduler.updateScheduledTransferEstimatedByteTotal(jobID: $0, bytesTotal: $1) }
        )
    }

    private func estimateUploadSizeIfNeeded(
        localFile: LocalUploadFile,
        jobID: String,
        update: @escaping @MainActor (String, UInt64) -> Void
    ) {
        guard localFile.size == 0 else {
            return
        }
        let url = URL(fileURLWithPath: localFile.path)
        guard isLocalDirectory(url) else {
            return
        }
        let sizeProvider = localUploadSizeProvider
        Task.detached(priority: .utility) {
            let bytesTotal = sizeProvider(url)
            guard bytesTotal > 0 else {
                return
            }
            await MainActor.run {
                update(jobID, bytesTotal)
            }
        }
    }

    private func isLocalDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func resolveDestinationPathIfNeeded(
        _ destinationPath: String,
        direction: ScpDirection,
        conflictExists: Bool
    ) -> String? {
        guard conflictExists else {
            return destinationPath
        }
        guard let policy = conflictResolver.resolveConflict(
            destinationPath: destinationPath,
            direction: direction,
            parentWindow: filesViewController?.view.window
        ) else {
            return nil
        }
        return CoreBridge.resolveSCPConflictPath(destinationPath: destinationPath, policy: policy)
    }

    private struct PlannedDownload {
        let selection: RemoteFileSelection
        let destinationPath: String
    }

    private func plannedDownloadDestinations(for selections: [RemoteFileSelection]) -> [PlannedDownload]? {
        if selections.count == 1,
           let selection = selections.first,
           selection.isFile
        {
            let suggestedFileName = suggestedDownloadFileName(for: selection.path)
            guard let destinationPath = downloadDestinationPicker.pickDownloadDestination(
                suggestedFileName: suggestedFileName,
                parentWindow: filesViewController?.view.window
            ) else {
                return nil
            }
            guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
                destinationPath,
                direction: .download,
                conflictExists: FileManager.default.fileExists(atPath: destinationPath)
            ) else {
                return nil
            }
            return [PlannedDownload(selection: selection, destinationPath: resolvedDestinationPath)]
        }

        guard let destinationDirectory = downloadDestinationPicker.pickDownloadDirectory(
            parentWindow: filesViewController?.view.window
        ) else {
            return nil
        }

        var plannedDownloads: [PlannedDownload] = []
        for selection in selections {
            let destinationPath = localDestinationPath(
                directory: destinationDirectory,
                fileName: suggestedDownloadFileName(for: selection.path)
            )
            guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
                destinationPath,
                direction: .download,
                conflictExists: FileManager.default.fileExists(atPath: destinationPath)
            ) else {
                continue
            }
            plannedDownloads.append(PlannedDownload(selection: selection, destinationPath: resolvedDestinationPath))
        }
        return plannedDownloads
    }

    private func createDirectory(in remoteDirectory: String) {
        if let context = ftpSessionContextProvider(),
           let directoryName = operationPrompt.promptDirectoryName(parentWindow: filesViewController?.view.window)
        {
            let remotePath = remoteDestinationPath(directory: remoteDirectory, fileName: directoryName)
            do {
                try bridge.createLiveFTPDirectory(
                    config: context.config,
                    secret: context.secret,
                    remotePath: remotePath
                )
                refreshCurrentLiveDirectory(remotePath: remoteDirectory)
            } catch {
                present(error, context: .createDirectory)
            }
            return
        }

        guard let context = liveSessionContextProvider(),
              let directoryName = operationPrompt.promptDirectoryName(parentWindow: filesViewController?.view.window)
        else {
            return
        }

        let remotePath = remoteDestinationPath(directory: remoteDirectory, fileName: directoryName)
        do {
            try bridge.createLiveRemoteDirectory(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                remotePath: remotePath
            )
            refreshCurrentLiveDirectory(remotePath: remoteDirectory)
        } catch {
            present(error, context: .createDirectory)
        }
    }

    private func createFile(in remoteDirectory: String) {
        guard let fileName = operationPrompt.promptFileName(parentWindow: filesViewController?.view.window) else {
            return
        }
        let destinationPath = remoteDestinationPath(directory: remoteDirectory, fileName: fileName)
        guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
            destinationPath,
            direction: .upload,
            conflictExists: filesViewController?.containsRemoteEntry(named: fileName) ?? false
        ) else {
            return
        }

        do {
            let localURL = try makeEmptyLocalFileForRemoteCreate(fileName: fileName)
            let job = ScpTransferJob(
                id: "remote_file_create_\(UUID().uuidString)",
                direction: .upload,
                sourcePath: localURL.path,
                destinationPath: resolvedDestinationPath,
                bytesTotal: 0
            )
            if let context = ftpSessionContextProvider(),
               let ftpTransferScheduler
            {
                ftpTransferScheduler.scheduleLiveFTPTransfer(
                    config: context.config,
                    secret: context.secret,
                    job: job
                )
                return
            }

            guard let context = liveSessionContextProvider(),
                  let transferScheduler
            else {
                return
            }
            transferScheduler.scheduleLiveTransfer(
                runtimeID: liveSessionRuntimeID(for: context),
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                job: job
            )
        } catch {
            present(error, context: .createFile)
        }
    }

    private func makeEmptyLocalFileForRemoteCreate(fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteFileCreate", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appendingPathComponent((fileName as NSString).lastPathComponent)
        try Data().write(to: localURL, options: .atomic)
        return localURL
    }

    private func rename(_ selection: RemoteFileSelection) {
        if let context = ftpSessionContextProvider(),
           let destination = operationPrompt.promptRenameDestination(
               currentPath: selection.path,
               parentWindow: filesViewController?.view.window
           )
        {
            do {
                try bridge.renameLiveFTPPath(
                    config: context.config,
                    secret: context.secret,
                    fromPath: selection.path,
                    toPath: destination
                )
                refreshCurrentLiveDirectory(remotePath: currentRemoteDirectory())
            } catch {
                present(error, context: .rename)
            }
            return
        }

        guard let context = liveSessionContextProvider(),
              let destination = operationPrompt.promptRenameDestination(
                currentPath: selection.path,
                parentWindow: filesViewController?.view.window
              )
        else {
            return
        }

        do {
            try bridge.renameLiveRemotePath(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                fromPath: selection.path,
                toPath: destination
            )
            refreshCurrentLiveDirectory(remotePath: currentRemoteDirectory())
        } catch {
            present(error, context: .rename)
        }
    }

    private func delete(_ selection: RemoteFileSelection) {
        delete([selection])
    }

    private func delete(_ selections: [RemoteFileSelection]) {
        guard let firstSelection = selections.first else {
            return
        }

        if let context = ftpSessionContextProvider(),
           operationPrompt.confirmDelete(
               selection: firstSelection,
               parentWindow: filesViewController?.view.window
           )
        {
            deleteFTPSelections(selections, context: context, remoteDirectory: currentRemoteDirectory())
            return
        }

        guard let context = liveSessionContextProvider(),
              operationPrompt.confirmDelete(
                selection: firstSelection,
                parentWindow: filesViewController?.view.window
              )
        else {
            return
        }

        deleteSSHSelections(selections, context: context, remoteDirectory: currentRemoteDirectory())
    }

    private func deleteFTPSelections(
        _ selections: [RemoteFileSelection],
        context: FTPLiveSessionContext,
        remoteDirectory: String
    ) {
        let paths = selections.map(\.path)
        filesViewController?.setRemoteEditSyncStatus(
            message: deletingRemoteItemsMessage(count: paths.count),
            progressValue: nil
        )
        let bridgeBox = UncheckedSendableBox(bridge)
        let contextBox = UncheckedSendableBox(context)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                for path in paths {
                    try bridgeBox.value.deleteLiveFTPPath(
                        config: contextBox.value.config,
                        secret: contextBox.value.secret,
                        remotePath: path,
                        recursive: true
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.handleDeleteResult(result, remoteDirectory: remoteDirectory, deletedCount: paths.count)
            }
        }
    }

    private func deleteSSHSelections(
        _ selections: [RemoteFileSelection],
        context: TunnelLiveSessionContext,
        remoteDirectory: String
    ) {
        let paths = selections.map(\.path)
        filesViewController?.setRemoteEditSyncStatus(
            message: deletingRemoteItemsMessage(count: paths.count),
            progressValue: nil
        )
        let bridgeBox = UncheckedSendableBox(bridge)
        let contextBox = UncheckedSendableBox(context)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                for path in paths {
                    try bridgeBox.value.deleteLiveRemotePath(
                        config: contextBox.value.config,
                        secret: contextBox.value.secret,
                        expectedFingerprintSHA256: contextBox.value.expectedFingerprintSHA256,
                        remotePath: path,
                        recursive: true
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.handleDeleteResult(result, remoteDirectory: remoteDirectory, deletedCount: paths.count)
            }
        }
    }

    private func handleDeleteResult(
        _ result: Result<Void, Error>,
        remoteDirectory: String,
        deletedCount: Int
    ) {
        switch result {
        case .success:
            filesViewController?.setRemoteEditSyncStatus(
                message: deletedRemoteItemsMessage(count: deletedCount),
                progressValue: 100
            )
            refreshCurrentLiveDirectory(remotePath: remoteDirectory)
        case .failure(let error):
            filesViewController?.setRemoteEditSyncStatus(
                message: "删除远端项目失败",
                progressValue: nil
            )
            present(error, context: .delete)
        }
    }

    private func deletingRemoteItemsMessage(count: Int) -> String {
        count > 1 ? "正在删除 \(count) 个远端项目..." : "正在删除远端项目..."
    }

    private func deletedRemoteItemsMessage(count: Int) -> String {
        count > 1 ? "已删除 \(count) 个远端项目，正在刷新目录" : "已删除远端项目，正在刷新目录"
    }

    private func openRemoteEdit(_ selection: RemoteFileSelection) {
        openRemote(selection, mode: .textEditor)
    }

    private func openRemotePreview(_ selection: RemoteFileSelection) {
        openRemote(selection, mode: .mediaPreview)
    }

    private func openRemote(_ selection: RemoteFileSelection, mode: RemoteFileOpenMode) {
        logFileOpenEvent(
            name: "file.open.request",
            selection: selection,
            mode: mode,
            extra: "size=\(selection.size)"
        )
        if let ftpContext = ftpSessionContextProvider() {
            guard let ftpTransferScheduler else {
                logFileOpenEvent(
                    name: "file.open.skipped",
                    selection: selection,
                    mode: mode,
                    level: .warning,
                    extra: "reason=missing-ftp-transfer-scheduler"
                )
                return
            }
            openFTPRemoteLocalCopy(
                selection,
                mode: mode,
                context: ftpContext,
                transferScheduler: ftpTransferScheduler,
                applicationURL: nil
            )
            return
        }

        guard ftpSessionContextProvider() == nil,
              let context = liveSessionContextProvider()
        else {
            logFileOpenEvent(
                name: "file.open.skipped",
                selection: selection,
                mode: mode,
                level: .warning,
                extra: "reason=missing-ssh-context"
            )
            return
        }

        if mode == .textEditor || mode == .mediaPreview {
            openBuiltInRemoteDocument(selection, mode: mode, context: context)
            return
        }

        guard let transferScheduler else {
            logFileOpenEvent(
                name: "file.open.skipped",
                selection: selection,
                mode: mode,
                level: .warning,
                extra: "reason=missing-transfer-scheduler"
            )
            return
        }

        let applicationURL: URL?
        if mode == .chooseApplication {
            guard let selectedApplicationURL = operationPrompt.promptOpenApplication(parentWindow: filesViewController?.view.window) else {
                return
            }
            applicationURL = selectedApplicationURL
        } else {
            applicationURL = nil
        }

        openRemoteLocalCopy(
            selection,
            mode: mode,
            context: context,
            transferScheduler: transferScheduler,
            applicationURL: applicationURL
        )
    }

    private func openBuiltInRemoteDocument(
        _ selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        context: TunnelLiveSessionContext
    ) {
        guard remoteEditOpener.prepareToOpenRemote(selection: selection, mode: mode) else {
            logFileOpenEvent(
                name: "file.open.cancelled",
                selection: selection,
                mode: mode,
                level: .warning,
                extra: "reason=right-workspace-close-cancelled"
            )
            return
        }

        let fileName = (selection.path as NSString).lastPathComponent
        let contentKind = StacioFileDisplay.contentKind(forFileName: fileName)
        if contentKind == .text,
           selection.size > Self.maximumInlineRemoteTextEditorBytes
        {
            let message = "文件过大（\(selection.size) bytes），请下载后使用本地编辑器打开。"
            logFileOpenEvent(
                name: "file.open.online.too-large",
                selection: selection,
                mode: mode,
                level: .warning,
                extra: "bytes=\(selection.size)"
            )
            remoteEditOpener.remoteOpenDidFail(selection: selection, mode: mode, message: message)
            return
        }
        if contentKind.isPreviewableMedia {
            let previewURL = makeOnlineMediaPreviewURL(selection: selection, context: context)
            let descriptor = RemoteTextEditorDocumentDescriptor(
                remotePath: selection.path,
                fileName: fileName,
                content: "",
                contentKind: contentKind,
                previewSource: previewURL.absoluteString,
                byteCount: selection.size
            )
            remoteEditOpener.openRemoteDocument(descriptor, mode: mode, saveHandler: nil)
            logFileOpenEvent(
                name: "file.open.online.preview",
                selection: selection,
                mode: mode,
                extra: "source=\(previewURL.scheme ?? "unknown")"
            )
            return
        }

        let bridgeBox = UncheckedSendableBox(bridge)
        let openerBox = UncheckedSendableBox(remoteEditOpener)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(Data, String), Error>
            do {
                let data = try bridgeBox.value.readLiveRemoteFile(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: selection.path,
                    offset: 0,
                    length: nil
                )
                if let text = String(data: data, encoding: .utf8) {
                    result = .success((data, text))
                } else {
                    result = .failure(RemoteTextEditorError.nonUTF8Text(fileName))
                }
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let dataAndText):
                    let descriptor = RemoteTextEditorDocumentDescriptor(
                        remotePath: selection.path,
                        fileName: fileName,
                        content: dataAndText.1,
                        contentKind: .text,
                        previewSource: nil,
                        byteCount: selection.size
                    )
                    openerBox.value.openRemoteDocument(
                        descriptor,
                        mode: mode,
                        saveHandler: { [weak self] updatedText in
                            try self?.writeRemoteEditText(updatedText, selection: selection, context: context)
                        }
                    )
                    self?.logFileOpenEvent(
                        name: "file.open.online.text",
                        selection: selection,
                        mode: mode,
                        extra: "bytes=\(dataAndText.0.count)"
                    )
                case .failure(let error):
                    let message = RuntimeDiagnosticFormatter.userMessage(for: error)
                    self?.logFileOpenEvent(
                        name: "file.open.online.failed",
                        selection: selection,
                        mode: mode,
                        level: .error,
                        extra: message
                    )
                    openerBox.value.remoteOpenDidFail(selection: selection, mode: mode, message: message)
                }
            }
        }
    }

    private func openRemoteLocalCopy(
        _ selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        context: TunnelLiveSessionContext,
        transferScheduler: SCPTransferScheduling,
        applicationURL: URL?
    ) {
        let runtimeID = liveSessionRuntimeID(for: context)
        let sessionID = remoteEditSessionIDProvider()
        if let cachedItem = cleanCachedRemoteEditItem(
            selection: selection,
            runtimeID: runtimeID,
            sessionID: sessionID
        ) {
            logFileOpenEvent(
                name: "file.open.cache.hit",
                selection: selection,
                mode: mode,
                extra: "local=\(cachedItem.localURL.path)"
            )
            remoteEditOpener.openLocalCopy(
                at: cachedItem.localURL,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: { [weak self] in
                    self?.saveRemoteEdit(selection)
                }
            )
            return
        }

        guard remoteEditOpener.prepareToOpenRemote(selection: selection, mode: mode) else {
            logFileOpenEvent(
                name: "file.open.cancelled",
                selection: selection,
                mode: mode,
                level: .warning,
                extra: "reason=right-workspace-close-cancelled"
            )
            return
        }

        do {
            let cacheItem = try remoteEditCache.createItem(
                from: selection,
                runtimeID: runtimeID,
                sessionID: sessionID,
                modifiedAt: parsedRemoteModifiedDate(from: selection.modifiedTime)
            )
            let job = ScpTransferJob(
                id: "remote_edit_download_\(UUID().uuidString)",
                direction: .download,
                sourcePath: selection.path,
                destinationPath: cacheItem.localURL.path,
                bytesTotal: selection.size
            )
            transferScheduler.scheduleLiveTransfer(
                runtimeID: runtimeID,
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                job: job,
                completion: { [weak self] progress in
                    guard let self else {
                        return
                    }
                    guard self.isLiveSessionRuntimeCurrent(runtimeID) else {
                        self.logFileOpenEvent(
                            name: "file.open.download.stale",
                            selection: selection,
                            mode: mode,
                            level: .warning,
                            extra: "runtime=\(runtimeID) status=\(progress.status)"
                        )
                        return
                    }
                    guard progress.status == "completed" else {
                        if progress.status == "failed" {
                            let message = "status=\(progress.status) bytes=\(progress.bytesDone)/\(progress.bytesTotal)"
                            self.logFileOpenEvent(
                                name: "file.open.download.failed",
                                selection: selection,
                                mode: mode,
                                level: .error,
                                extra: message
                            )
                            self.remoteEditOpener.remoteOpenDidFail(
                                selection: selection,
                                mode: mode,
                                message: message
                            )
                        }
                        return
                    }
                    self.logFileOpenEvent(
                        name: "file.open.download.completed",
                        selection: selection,
                        mode: mode,
                        extra: "bytes=\(progress.bytesDone)/\(progress.bytesTotal)"
                    )
                    do {
                        _ = try self.remoteEditCache.markClean(itemID: cacheItem.id)
                    } catch {
                        self.logFileOpenEvent(
                            name: "file.open.download.cache-clean.failed",
                            selection: selection,
                            mode: mode,
                            level: .error,
                            extra: RuntimeDiagnosticFormatter.userMessage(for: error)
                        )
                    }
                    self.remoteEditOpener.openLocalCopy(
                        at: cacheItem.localURL,
                        mode: mode,
                        applicationURL: applicationURL,
                        saveHandler: { [weak self] in
                            self?.saveRemoteEdit(selection)
                        }
                    )
                }
            )
        } catch {
            logFileOpenEvent(
                name: "file.open.failed",
                selection: selection,
                mode: mode,
                level: .error,
                extra: RuntimeDiagnosticFormatter.userMessage(for: error)
            )
            present(error, context: .openRemoteEdit)
        }
    }

    private func openFTPRemoteLocalCopy(
        _ selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        context: FTPLiveSessionContext,
        transferScheduler: FTPTransferScheduling,
        applicationURL: URL?
    ) {
        let runtimeID = ftpRemoteEditRuntimeID(for: context)
        let sessionID = remoteEditSessionIDProvider()
        if let cachedItem = cleanCachedRemoteEditItem(
            selection: selection,
            runtimeID: runtimeID,
            sessionID: sessionID
        ) {
            logFileOpenEvent(
                name: "file.open.ftp.cache.hit",
                selection: selection,
                mode: mode,
                extra: "local=\(cachedItem.localURL.path)"
            )
            remoteEditOpener.openLocalCopy(
                at: cachedItem.localURL,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: { [weak self] in
                    self?.saveFTPRemoteEdit(selection, context: context, transferScheduler: transferScheduler)
                }
            )
            return
        }

        guard remoteEditOpener.prepareToOpenRemote(selection: selection, mode: mode) else {
            logFileOpenEvent(
                name: "file.open.ftp.cancelled",
                selection: selection,
                mode: mode,
                level: .warning,
                extra: "reason=right-workspace-close-cancelled"
            )
            return
        }

        do {
            let cacheItem = try remoteEditCache.createItem(
                from: selection,
                runtimeID: runtimeID,
                sessionID: sessionID,
                modifiedAt: parsedRemoteModifiedDate(from: selection.modifiedTime)
            )
            let job = ScpTransferJob(
                id: "remote_edit_ftp_download_\(UUID().uuidString)",
                direction: .download,
                sourcePath: selection.path,
                destinationPath: cacheItem.localURL.path,
                bytesTotal: selection.size
            )
            transferScheduler.scheduleLiveFTPTransfer(
                config: context.config,
                secret: context.secret,
                job: job,
                completion: { [weak self] progress in
                    guard let self else {
                        return
                    }
                    guard self.isFTPSessionRuntimeCurrent(runtimeID) else {
                        self.logFileOpenEvent(
                            name: "file.open.ftp.download.stale",
                            selection: selection,
                            mode: mode,
                            level: .warning,
                            extra: "runtime=\(runtimeID) status=\(progress.status)"
                        )
                        return
                    }
                    guard progress.status == "completed" else {
                        if progress.status == "failed" {
                            let message = "status=\(progress.status) bytes=\(progress.bytesDone)/\(progress.bytesTotal)"
                            self.logFileOpenEvent(
                                name: "file.open.ftp.download.failed",
                                selection: selection,
                                mode: mode,
                                level: .error,
                                extra: message
                            )
                            self.remoteEditOpener.remoteOpenDidFail(
                                selection: selection,
                                mode: mode,
                                message: message
                            )
                        }
                        return
                    }
                    self.logFileOpenEvent(
                        name: "file.open.ftp.download.completed",
                        selection: selection,
                        mode: mode,
                        extra: "bytes=\(progress.bytesDone)/\(progress.bytesTotal)"
                    )
                    do {
                        _ = try self.remoteEditCache.markClean(itemID: cacheItem.id)
                    } catch {
                        self.logFileOpenEvent(
                            name: "file.open.ftp.download.cache-clean.failed",
                            selection: selection,
                            mode: mode,
                            level: .error,
                            extra: RuntimeDiagnosticFormatter.userMessage(for: error)
                        )
                    }
                    self.remoteEditOpener.openLocalCopy(
                        at: cacheItem.localURL,
                        mode: mode,
                        applicationURL: applicationURL,
                        saveHandler: { [weak self] in
                            self?.saveFTPRemoteEdit(selection, context: context, transferScheduler: transferScheduler)
                        }
                    )
                }
            )
        } catch {
            logFileOpenEvent(
                name: "file.open.ftp.failed",
                selection: selection,
                mode: mode,
                level: .error,
                extra: RuntimeDiagnosticFormatter.userMessage(for: error)
            )
            present(error, context: .openRemoteEdit)
        }
    }

    private func makeOnlineMediaPreviewURL(
        selection: RemoteFileSelection,
        context: TunnelLiveSessionContext
    ) -> URL {
        let fileName = (selection.path as NSString).lastPathComponent
        let mimeType = Self.mimeType(forFileName: fileName)
        return RemoteFileOnlineMediaRegistry.shared.register(
            fileName: fileName,
            mimeType: mimeType,
            byteCount: selection.size,
            reader: { [bridge] offset, length in
                try bridge.readLiveRemoteFile(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: selection.path,
                    offset: offset,
                    length: length
                )
            }
        )
    }

    private func writeRemoteEditText(
        _ text: String,
        selection: RemoteFileSelection,
        context: TunnelLiveSessionContext
    ) throws {
        try validateRemoteEditNotStale(
            remotePath: selection.path,
            openedRemoteModifiedAt: parsedRemoteModifiedDate(from: selection.modifiedTime)
        )
        let data = Data(text.utf8)
        _ = try bridge.writeLiveRemoteFile(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: selection.path,
            contents: data
        )
        let verificationData = try bridge.readLiveRemoteFile(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: selection.path,
            offset: 0,
            length: UInt64(data.count)
        )
        guard verificationData == data else {
            throw RemoteEditCacheError.remoteWriteVerificationFailed(selection.path)
        }
    }

    private static func mimeType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "bmp":
            return "image/bmp"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "ico":
            return "image/x-icon"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "ogg":
            return "audio/ogg"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "m4a":
            return "audio/mp4"
        case "mp4":
            return "video/mp4"
        case "webm":
            return "video/webm"
        case "avi":
            return "video/x-msvideo"
        case "mov":
            return "video/quicktime"
        case "mkv":
            return "video/x-matroska"
        default:
            return "application/octet-stream"
        }
    }

    private func cleanCachedRemoteEditItem(
        selection: RemoteFileSelection,
        runtimeID: String,
        sessionID: String
    ) -> RemoteEditCacheItem? {
        guard let item = try? remoteEditCache.item(
            remotePath: selection.path,
            runtimeID: runtimeID,
            sessionID: sessionID
        ) else {
            return nil
        }
        guard item.isDirty == false,
              FileManager.default.fileExists(atPath: item.localURL.path)
        else {
            return nil
        }
        return item
    }

    private func compareFiles(_ selections: [RemoteFileSelection]) {
        let fileSelections = selections.filter { $0.kind == .file }
        guard fileSelections.count >= 2 else {
            present(RemoteFileCompareError.requiresTwoFiles, context: .compareFiles)
            return
        }
        guard ftpSessionContextProvider() == nil,
              let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            return
        }
        let runtimeID = liveSessionRuntimeID(for: context)

        let selectionsToCompare = Array(fileSelections.prefix(2))
        do {
            let cacheItems = try selectionsToCompare.map { selection in
                try remoteEditCache.createItem(
                    from: selection,
                    runtimeID: runtimeID,
                    sessionID: remoteEditSessionIDProvider(),
                    modifiedAt: parsedRemoteModifiedDate(from: selection.modifiedTime)
                )
            }
            var completedLocalURLsByJobID: [String: URL] = [:]
            let compareDownloads = zip(selectionsToCompare, cacheItems).map { selection, cacheItem in
                let transferJob = ScpTransferJob(
                    id: "remote_compare_download_\(UUID().uuidString)",
                    direction: .download,
                    sourcePath: selection.path,
                    destinationPath: cacheItem.localURL.path,
                    bytesTotal: selection.size
                )
                return (selection: selection, job: transferJob, localURL: cacheItem.localURL)
            }
            let jobIDsInOrder = compareDownloads.map(\.job.id)

            for compareDownload in compareDownloads {
                transferScheduler.scheduleLiveTransfer(
                    runtimeID: runtimeID,
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    job: compareDownload.job,
                    completion: { [weak self] progress in
                        guard let self else {
                            return
                        }
                        guard self.isLiveSessionRuntimeCurrent(runtimeID) else {
                            self.logFileOpenEvent(
                                name: "file.compare.download.stale",
                                selection: compareDownload.selection,
                                mode: .defaultApplication,
                                level: .warning,
                                extra: "runtime=\(runtimeID) job=\(progress.jobId) status=\(progress.status)"
                            )
                            return
                        }
                        guard progress.status == "completed" else {
                            return
                        }
                        completedLocalURLsByJobID[progress.jobId] = compareDownload.localURL
                        guard completedLocalURLsByJobID.count == jobIDsInOrder.count else {
                            return
                        }
                        let localURLs = jobIDsInOrder.compactMap { completedLocalURLsByJobID[$0] }
                        guard localURLs.count == jobIDsInOrder.count else {
                            return
                        }
                        do {
                            try self.remoteEditOpener.compareLocalCopies(
                                localURLs,
                                parentWindow: self.filesViewController?.view.window
                            )
                        } catch {
                            self.present(error, context: .compareFiles)
                        }
                    }
                )
            }
        } catch {
            present(error, context: .compareFiles)
        }
    }

    private func saveRemoteEdit(_ selection: RemoteFileSelection) {
        guard ftpSessionContextProvider() == nil,
              let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            return
        }
        let runtimeID = liveSessionRuntimeID(for: context)

        do {
            let cacheItem = try remoteEditCache.item(
                remotePath: selection.path,
                runtimeID: runtimeID,
                sessionID: remoteEditSessionIDProvider()
            )
            try validateRemoteEditNotStale(cacheItem)
            let dirtyItem = try remoteEditCache.markDirty(itemID: cacheItem.id)
            let job = try remoteEditCache.makeUploadJob(for: dirtyItem)
            appLog?.append(
                level: .info,
                category: "Files",
                message: "file.save.upload.scheduled path=\(selection.path) bytes=\(job.bytesTotal)"
            )
            transferScheduler.scheduleLiveTransfer(
                runtimeID: runtimeID,
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                job: job,
                completion: { [weak self] progress in
                    guard let self else {
                        return
                    }
                    guard self.isLiveSessionRuntimeCurrent(runtimeID) else {
                        self.appLog?.append(
                            level: .warning,
                            category: "Files",
                            message: "file.save.upload.stale runtime=\(runtimeID) job=\(progress.jobId) status=\(progress.status)"
                        )
                        return
                    }
                    self.handleRemoteEditUploadProgress(progress, itemID: dirtyItem.id)
                }
            )
        } catch {
            present(error, context: .saveRemoteEdit)
        }
    }

    private func saveFTPRemoteEdit(
        _ selection: RemoteFileSelection,
        context: FTPLiveSessionContext,
        transferScheduler: FTPTransferScheduling
    ) {
        let runtimeID = ftpRemoteEditRuntimeID(for: context)
        guard isFTPSessionRuntimeCurrent(runtimeID) else {
            appLog?.append(
                level: .warning,
                category: "Files",
                message: "file.save.ftp.upload.skipped-stale-runtime runtime=\(runtimeID) path=\(selection.path)"
            )
            return
        }
        do {
            let cacheItem = try remoteEditCache.item(
                remotePath: selection.path,
                runtimeID: runtimeID,
                sessionID: remoteEditSessionIDProvider()
            )
            try validateRemoteEditNotStale(cacheItem)
            let dirtyItem = try remoteEditCache.markDirty(itemID: cacheItem.id)
            let job = try remoteEditCache.makeUploadJob(for: dirtyItem)
            appLog?.append(
                level: .info,
                category: "Files",
                message: "file.save.ftp.upload.scheduled path=\(selection.path) bytes=\(job.bytesTotal)"
            )
            transferScheduler.scheduleLiveFTPTransfer(
                config: context.config,
                secret: context.secret,
                job: job,
                completion: { [weak self] progress in
                    guard let self else {
                        return
                    }
                    guard self.isFTPSessionRuntimeCurrent(runtimeID) else {
                        self.appLog?.append(
                            level: .warning,
                            category: "Files",
                            message: "file.save.ftp.upload.stale runtime=\(runtimeID) job=\(progress.jobId) status=\(progress.status)"
                        )
                        return
                    }
                    self.handleRemoteEditUploadProgress(progress, itemID: dirtyItem.id)
                }
            )
        } catch {
            present(error, context: .saveRemoteEdit)
        }
    }

    private func parsedRemoteModifiedDate(from value: String?) -> Date? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false, trimmed != "-" else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm"
        ]
        for format in formats {
            if let date = Self.remoteModifiedDateFormatter(format: format).date(from: trimmed) {
                return date
            }
        }

        if let date = Self.remoteModifiedDateFormatter(format: "MM-dd HH:mm").date(from: trimmed) {
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: Date())
            var components = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
            components.year = currentYear
            return calendar.date(from: components)
        }

        return nil
    }

    private static func remoteModifiedDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    private func syncChangedRemoteEdits() {
        guard settingsStore.snapshot().filesRemoteEditAutoDetectChanges else {
            filesViewController?.setRemoteEditSyncStatus(
                message: "Remote Edit：本地编辑副本变更检测已关闭，可在设置 > 文件中开启",
                progressValue: 0
            )
            appLog?.append(
                level: .info,
                category: "Files",
                message: "file.save.changed-edits.disabled"
            )
            return
        }

        guard ftpSessionContextProvider() == nil,
              let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            present(FilesCoordinatorError.missingLiveSSHContext, context: .saveRemoteEdit)
            return
        }
        let runtimeID = liveSessionRuntimeID(for: context)

        do {
            let jobs = try remoteEditCache.makeUploadJobsForChangedLocalCopies(
                runtimeID: runtimeID,
                sessionID: remoteEditSessionIDProvider()
            )
            try jobs.forEach { job in
                let item = try remoteEditCache.item(
                    remotePath: job.destinationPath,
                    runtimeID: runtimeID,
                    sessionID: remoteEditSessionIDProvider()
                )
                try validateRemoteEditNotStale(item)
            }
            guard !jobs.isEmpty else {
                filesViewController?.setRemoteEditSyncStatus(
                    message: "Remote Edit：没有发现需要上传的本地编辑副本",
                    progressValue: 0
                )
                appLog?.append(
                    level: .info,
                    category: "Files",
                    message: "file.save.changed-edits.none runtime=\(runtimeID)"
                )
                return
            }
            filesViewController?.setRemoteEditSyncStatus(
                message: "Remote Edit：发现 \(jobs.count) 个本地编辑副本变更，正在加入上传队列",
                progressValue: 10
            )
            appLog?.append(
                level: .info,
                category: "Files",
                message: "file.save.changed-edits.scheduled count=\(jobs.count) runtime=\(runtimeID)"
            )
            for job in jobs {
                let item = try remoteEditCache.item(
                    remotePath: job.destinationPath,
                    runtimeID: runtimeID,
                    sessionID: remoteEditSessionIDProvider()
                )
                transferScheduler.scheduleLiveTransfer(
                    runtimeID: runtimeID,
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    job: job,
                    completion: { [weak self] progress in
                        guard let self else {
                            return
                        }
                        guard self.isLiveSessionRuntimeCurrent(runtimeID) else {
                            self.appLog?.append(
                                level: .warning,
                                category: "Files",
                                message: "file.save.changed-edits.upload.stale runtime=\(runtimeID) job=\(progress.jobId) status=\(progress.status)"
                            )
                            return
                        }
                        self.handleRemoteEditUploadProgress(progress, itemID: item.id)
                    }
                )
            }
            filesViewController?.setRemoteEditSyncStatus(
                message: "Remote Edit：\(jobs.count) 个本地编辑副本已加入上传队列",
                progressValue: 100
            )
        } catch {
            present(error, context: .saveRemoteEdit)
        }
    }

    private func ftpRemoteEditRuntimeID(for context: FTPLiveSessionContext) -> String {
        "ftp://\(context.config.username)@\(context.config.host):\(context.config.port)"
    }

    private func isFTPSessionRuntimeCurrent(_ runtimeID: String) -> Bool {
        guard let currentContext = ftpSessionContextProvider() else {
            return false
        }
        return ftpRemoteEditRuntimeID(for: currentContext) == runtimeID
    }

    private func handleRemoteEditUploadProgress(_ progress: ScpTransferProgress, itemID: String) {
        guard progress.status == "completed" else {
            return
        }
        do {
            _ = try remoteEditCache.markClean(itemID: itemID)
        } catch {
            appLog?.append(
                level: .error,
                category: "Files",
                message: "file.save.upload.cache-clean.failed job=\(progress.jobId) error=\(RuntimeDiagnosticFormatter.userMessage(for: error))"
            )
        }
    }

    private func validateRemoteEditNotStale(_ item: RemoteEditCacheItem) throws {
        try validateRemoteEditNotStale(
            remotePath: item.remotePath,
            openedRemoteModifiedAt: item.modifiedAt
        )
    }

    private func validateRemoteEditNotStale(
        remotePath: String,
        openedRemoteModifiedAt: Date?
    ) throws {
        guard let openedRemoteModifiedAt,
              let currentSelection = filesViewController?.selectionForRemotePath(remotePath),
              let currentRemoteModifiedAt = parsedRemoteModifiedDate(from: currentSelection.modifiedTime)
        else {
            return
        }
        if currentRemoteModifiedAt > openedRemoteModifiedAt {
            throw RemoteEditCacheError.remoteChanged(remotePath)
        }
    }

    public func performBackupFromInspector(date: Date = Date(), timeZone: TimeZone = .current) {
        do {
            let candidates = try openEditorBackupCandidates()
            guard !candidates.isEmpty,
                  let selectedCandidates = operationPrompt.promptBackupCandidates(
                    candidates: candidates,
                    parentWindow: filesViewController?.view.window
                  ),
                  !selectedCandidates.isEmpty,
                  let destination = operationPrompt.promptBackupDestination(parentWindow: filesViewController?.view.window)
            else {
                return
            }

            switch destination {
            case .remoteDirectory:
                try backupToRemoteDirectories(selectedCandidates, date: date, timeZone: timeZone)
            case .local:
                scheduleLocalBackupDownloads(selectedCandidates, date: date, timeZone: timeZone)
            }
        } catch {
            present(error, context: .backup)
        }
    }

    public func performRestoreFromInspector() {
        guard let source = operationPrompt.promptRestoreSource(parentWindow: filesViewController?.view.window) else {
            return
        }
        do {
            switch source {
            case .remoteDirectory:
                try restoreFromCurrentRemoteDirectory()
            case .local:
                restoreFromLocalBackupFiles()
            }
        } catch {
            present(error, context: .restore)
        }
    }

    @discardableResult
    public func cleanupRemoteEdits(runtimeID: String) throws -> [RemoteEditCacheItem] {
        try remoteEditCache.removeItems(runtimeID: runtimeID)
    }

    private func openEditorBackupCandidates() throws -> [RemoteFileBackupCandidate] {
        guard let editor = filesViewController?.embeddedEditorViewControllerForTesting else {
            return []
        }
        let onlineCandidates = editor.documentBackupCandidates
        if onlineCandidates.isEmpty == false {
            return onlineCandidates.map { candidate in
                RemoteFileBackupCandidate(
                    fileName: candidate.fileName,
                    remotePath: candidate.remotePath,
                    localURL: candidate.localURL,
                    size: candidate.size
                )
            }
        }
        let activeURL = editor.activeDocumentLocalURL
        var orderedURLs: [URL] = []
        if let activeURL {
            orderedURLs.append(activeURL)
        }
        for url in editor.documentLocalURLs where url != activeURL {
            orderedURLs.append(url)
        }

        return try orderedURLs.map { localURL in
            let item = try remoteEditCache.item(localURL: localURL)
            return RemoteFileBackupCandidate(
                fileName: item.fileName,
                remotePath: item.remotePath,
                localURL: item.localURL,
                size: localUploadByteSize(at: item.localURL)
            )
        }
    }

    private func backupToRemoteDirectories(
        _ candidates: [RemoteFileBackupCandidate],
        date: Date,
        timeZone: TimeZone
    ) throws {
        for candidate in candidates {
            let backupPath = backupRemotePath(for: candidate, date: date, timeZone: timeZone)
            try copyRemotePath(fromPath: candidate.remotePath, toPath: backupPath)
        }
        refreshCurrentLiveDirectory(remotePath: currentRemoteDirectory())
    }

    private func scheduleLocalBackupDownloads(
        _ candidates: [RemoteFileBackupCandidate],
        date: Date,
        timeZone: TimeZone
    ) {
        guard let plannedDownloads = plannedBackupDownloadDestinations(for: candidates, date: date, timeZone: timeZone) else {
            return
        }

        if let context = ftpSessionContextProvider(),
           let ftpTransferScheduler
        {
            for plannedDownload in plannedDownloads {
                let job = ScpTransferJob(
                    id: "ftp_backup_download_\(UUID().uuidString)",
                    direction: .download,
                    sourcePath: plannedDownload.candidate.remotePath,
                    destinationPath: plannedDownload.destinationPath,
                    bytesTotal: plannedDownload.candidate.size
                )
                ftpTransferScheduler.scheduleLiveFTPTransfer(
                    config: context.config,
                    secret: context.secret,
                    job: job
                )
            }
            return
        }

        guard let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            return
        }

        for plannedDownload in plannedDownloads {
            let job = ScpTransferJob(
                id: "scp_backup_download_\(UUID().uuidString)",
                direction: .download,
                sourcePath: plannedDownload.candidate.remotePath,
                destinationPath: plannedDownload.destinationPath,
                bytesTotal: plannedDownload.candidate.size
            )
            transferScheduler.scheduleLiveTransfer(
                runtimeID: liveSessionRuntimeID(for: context),
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                job: job
            )
        }
    }

    private struct PlannedBackupDownload {
        let candidate: RemoteFileBackupCandidate
        let destinationPath: String
    }

    private func plannedBackupDownloadDestinations(
        for candidates: [RemoteFileBackupCandidate],
        date: Date,
        timeZone: TimeZone
    ) -> [PlannedBackupDownload]? {
        guard !candidates.isEmpty else {
            return nil
        }

        if candidates.count == 1,
           let candidate = candidates.first
        {
            let backupName = RemoteFileBackupNaming.backupFileName(
                originalFileName: candidate.fileName,
                date: date,
                timeZone: timeZone
            )
            guard let destinationPath = downloadDestinationPicker.pickDownloadDestination(
                suggestedFileName: backupName,
                parentWindow: filesViewController?.view.window
            ) else {
                return nil
            }
            guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
                destinationPath,
                direction: .download,
                conflictExists: FileManager.default.fileExists(atPath: destinationPath)
            ) else {
                return nil
            }
            return [PlannedBackupDownload(candidate: candidate, destinationPath: resolvedDestinationPath)]
        }

        guard let destinationDirectory = downloadDestinationPicker.pickDownloadDirectory(
            parentWindow: filesViewController?.view.window
        ) else {
            return nil
        }

        var plannedDownloads: [PlannedBackupDownload] = []
        for candidate in candidates {
            let backupName = RemoteFileBackupNaming.backupFileName(
                originalFileName: candidate.fileName,
                date: date,
                timeZone: timeZone
            )
            let destinationPath = localDestinationPath(directory: destinationDirectory, fileName: backupName)
            guard let resolvedDestinationPath = resolveDestinationPathIfNeeded(
                destinationPath,
                direction: .download,
                conflictExists: FileManager.default.fileExists(atPath: destinationPath)
            ) else {
                continue
            }
            plannedDownloads.append(PlannedBackupDownload(candidate: candidate, destinationPath: resolvedDestinationPath))
        }
        return plannedDownloads
    }

    private func restoreFromCurrentRemoteDirectory() throws {
        let directory = currentRemoteDirectory()
        let entries = try loadCurrentLiveDirectory(remotePath: directory)
        let backups = entries.compactMap { entry -> RemoteFileSelection? in
            guard entry.kind == .file,
                  RemoteFileBackupNaming.restoredFileName(fromBackupFileName: (entry.path as NSString).lastPathComponent) != nil
            else {
                return nil
            }
            return RemoteFileSelection(path: entry.path, size: entry.size, kind: entry.kind)
        }
        guard let selectedBackups = operationPrompt.promptRemoteBackupFiles(
            candidates: backups,
            parentWindow: filesViewController?.view.window
        ) else {
            return
        }

        for backup in selectedBackups {
            let backupFileName = (backup.path as NSString).lastPathComponent
            guard let restoredFileName = RemoteFileBackupNaming.restoredFileName(fromBackupFileName: backupFileName) else {
                continue
            }
            let destinationPath = remoteDestinationPath(
                directory: parentRemoteDirectory(for: backup.path),
                fileName: restoredFileName
            )
            try copyRemotePath(fromPath: backup.path, toPath: destinationPath)
        }
        refreshCurrentLiveDirectory(remotePath: directory)
    }

    private func restoreFromLocalBackupFiles() {
        guard let localURLs = operationPrompt.promptLocalBackupFiles(parentWindow: filesViewController?.view.window) else {
            return
        }
        let restoreFiles = localURLs.compactMap { url -> LocalUploadFile? in
            guard let restoredFileName = RemoteFileBackupNaming.restoredFileName(fromBackupFileName: url.lastPathComponent) else {
                return nil
            }
            return LocalUploadFile(
                path: url.path,
                fileName: restoredFileName,
                size: localUploadByteSize(at: url)
            )
        }
        guard !restoreFiles.isEmpty else {
            return
        }

        if let context = ftpSessionContextProvider(),
           let ftpTransferScheduler
        {
            for localFile in restoreFiles {
                scheduleFTPUpload(
                    localFile: localFile,
                    remoteDirectory: currentRemoteDirectory(),
                    context: context,
                    transferScheduler: ftpTransferScheduler
                )
            }
            return
        }

        guard let context = liveSessionContextProvider(),
              let transferScheduler
        else {
            return
        }
        for localFile in restoreFiles {
            scheduleUpload(
                localFile: localFile,
                remoteDirectory: currentRemoteDirectory(),
                context: context,
                transferScheduler: transferScheduler
            )
        }
    }

    private func copyRemotePath(fromPath: String, toPath: String) throws {
        if let context = ftpSessionContextProvider() {
            try bridge.copyLiveFTPPath(
                config: context.config,
                secret: context.secret,
                fromPath: fromPath,
                toPath: toPath
            )
            return
        }

        guard let context = liveSessionContextProvider() else {
            throw FilesCoordinatorError.missingLiveSSHContext
        }
        try bridge.copyLiveRemotePath(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    private func backupRemotePath(
        for candidate: RemoteFileBackupCandidate,
        date: Date,
        timeZone: TimeZone
    ) -> String {
        remoteDestinationPath(
            directory: parentRemoteDirectory(for: candidate.remotePath),
            fileName: RemoteFileBackupNaming.backupFileName(
                originalFileName: candidate.fileName,
                date: date,
                timeZone: timeZone
            )
        )
    }

    private func logFileOpenEvent(
        name: String,
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        level: StacioLogLevel = .info,
        extra: String = ""
    ) {
        let suffix = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = [
            name,
            "mode=\(mode.logName)",
            "path=\(selection.path)",
            "kind=\(selection.kind)"
        ] + (suffix.isEmpty ? [] : [suffix])
        appLog?.append(
            level: level,
            category: "Files",
            message: message.joined(separator: " ")
        )
    }

    private func chmod(_ selection: RemoteFileSelection) {
        guard ftpSessionContextProvider() == nil else {
            return
        }
        guard let context = liveSessionContextProvider(),
              let mode = operationPrompt.promptChmodMode(
                currentPath: selection.path,
                parentWindow: filesViewController?.view.window
              )
        else {
            return
        }

        do {
            try bridge.chmodLiveRemotePath(
                config: context.config,
                secret: context.secret,
                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                remotePath: selection.path,
                mode: mode
            )
            refreshCurrentLiveDirectory(remotePath: currentRemoteDirectory())
        } catch {
            present(error, context: .chmod)
        }
    }

    private func present(_ error: Error, context: RemoteFileErrorContext) {
        errorPresenter.present(error, context: context, parentWindow: filesViewController?.view.window)
    }

    private func currentRemoteDirectory() -> String {
        filesViewController?.currentRemotePath ?? "~"
    }

    private func suggestedDownloadFileName(for remotePath: String) -> String {
        let fileName = (remotePath as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileName.isEmpty || fileName == "/" ? L10n.Files.downloadFallbackName : fileName
    }

    private func remoteDestinationPath(directory: String, fileName: String) -> String {
        if directory == "~" {
            return "~/\(fileName)"
        }

        let trimmedDirectory = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if directory.hasPrefix("/") {
            if trimmedDirectory.isEmpty {
                return "/\(fileName)"
            }
            return "/\(trimmedDirectory)/\(fileName)"
        }
        if trimmedDirectory.isEmpty {
            return fileName
        }
        return "\(trimmedDirectory)/\(fileName)"
    }

    private func parentRemoteDirectory(for remotePath: String) -> String {
        let parent = (remotePath as NSString).deletingLastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if parent.isEmpty || parent == "." {
            return currentRemoteDirectory()
        }
        return parent
    }

    private func localDestinationPath(directory: String, fileName: String) -> String {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        return url.appendingPathComponent(fileName).path
    }

    private static func makeDefaultRemoteEditCache() -> RemoteEditCache {
        RemoteEditCache.defaultCache()
    }

    private static let maximumInlineRemoteTextEditorBytes: UInt64 = 10 * 1_024 * 1_024

    private func isLiveSessionRuntimeCurrent(_ runtimeID: String) -> Bool {
        guard let currentContext = liveSessionContextProvider() else {
            return false
        }
        return liveSessionRuntimeID(for: currentContext) == runtimeID
    }

    private func liveSessionRuntimeID(for context: TunnelLiveSessionContext) -> String {
        let runtimeID = liveSessionRuntimeIDProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return runtimeID?.isEmpty == false ? runtimeID! : context.config.host
    }
}

extension FilesCoordinator {
    func registerRemoteEditCacheItemForTesting(
        remotePath: String,
        localURL: URL,
        runtimeID: String,
        sessionID: String
    ) throws {
        _ = try remoteEditCache.registerItemForTesting(
            remotePath: remotePath,
            localURL: localURL,
            runtimeID: runtimeID,
            sessionID: sessionID
        )
    }

    @discardableResult
    func removeRemoteEditCacheItemsForTesting(runtimeID: String) throws -> [RemoteEditCacheItem] {
        try cleanupRemoteEdits(runtimeID: runtimeID)
    }
}
