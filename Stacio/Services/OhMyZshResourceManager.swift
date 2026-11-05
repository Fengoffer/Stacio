import CryptoKit
import CoreText
import Foundation

/// oh-my-zsh 资源快照的元信息（从后台服务器 manifest.json 获取）。
public struct OhMyZshResourceManifest: Decodable, Equatable, Sendable {
    public let version: String
    public let sizeBytes: Int64
    public let sha256: String
    public let downloadPath: String

    public init(version: String, sizeBytes: Int64, sha256: String, downloadPath: String) {
        self.version = version
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.downloadPath = downloadPath
    }

    public var downloadURL: URL? {
        OhMyZshResourceManager.resolveDownloadURL(
            baseURL: OhMyZshResourceManager.shared.baseURLValue,
            downloadPath: downloadPath
        )
    }
}

/// A verified, private copy of the installed resource tree retained for one deployment transaction.
/// Replacing or uninstalling the mutable installed directory cannot alter this snapshot.
public final class OhMyZshDeploymentLease: @unchecked Sendable {
    public let directoryURL: URL
    public let version: String
    public let treeHash: String

    private let lock = NSLock()
    private var cleanup: (() -> Void)?

    fileprivate init(
        directoryURL: URL,
        version: String,
        treeHash: String,
        cleanup: @escaping () -> Void
    ) {
        self.directoryURL = directoryURL
        self.version = version
        self.treeHash = treeHash
        self.cleanup = cleanup
    }

    public func release() {
        lock.lock()
        let cleanup = cleanup
        self.cleanup = nil
        lock.unlock()
        cleanup?()
    }

    deinit {
        release()
    }
}

/// 管理可下载的 oh-my-zsh 资源快照（主题/插件 + Nerd Font）。
///
/// 背景：为控制安装包体积，oh-my-zsh 资源**默认不内置**在 app bundle 中；
/// 用户点击"下载"后，本管理器从后台服务器拉取快照，校验 sha256 后解压到
/// `~/Library/Application Support/Stacio/OhMyZsh/`，供设置界面与本地/远程部署使用。
///
/// 线程安全：下载/解压在后台队列执行；`status()` 可在主线程调用。
public final class OhMyZshResourceManager: @unchecked Sendable {
    public static let resourceDirectoryName = "OhMyZsh"
    public static let versionMarkerFileName = ".stacio-resource-version"
    public static let manifestHashMarkerFileName = ".stacio-resource-manifest-sha256"
    public static let installTreeHashMarkerFileName = ".stacio-resource-tree-sha256"
    public static let nerdFontFileName = "JetBrainsMonoNLNerdFont-Regular.ttf"
    public static let statusDidChangeNotification = Notification.Name(
        "Stacio.OhMyZshResourceManager.statusDidChange"
    )
    private static let requiredInstalledRelativePaths: [String] = [
        "oh-my-zsh.sh",
        "plugins",
        "themes",
        "fonts/\(nerdFontFileName)"
    ]
    private static let integrityMetadataFileNames: Set<String> = [
        versionMarkerFileName,
        manifestHashMarkerFileName,
        installTreeHashMarkerFileName
    ]
    /// 后台服务器公开资源根路径（与 ops-platform `ohMyZshResources` 路由对应）。
    public static let defaultBaseURL = URL(string: "https://ops.stacio.cn/api/v1/public/stacio/oh-my-zsh")!

    public static let shared = OhMyZshResourceManager()

    private let fileManager: FileManager
    private let resourceDirectoryURL: URL?
    private let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private let integrityValidationQueue = DispatchQueue(
        label: "com.stacio.ohmyzsh.integrity-validation",
        qos: .utility
    )
    private let integrityRevalidationInterval: TimeInterval
    private let clock: () -> Date
    private let treeDigestProvider: ((URL) throws -> String)?
    private let deploymentSnapshotCopier: (URL, URL) throws -> Void
    private let fontRegistrar: (URL) -> Bool
    private let fontUnregistrar: (URL) -> Bool
    private let fontRegistrationDirectoryURL: URL

    private struct ValidatedInstallation: Equatable {
        let version: String
        let manifestHash: String
        let treeHash: String
    }

    private enum IntegrityValidationResult {
        case valid(ValidatedInstallation)
        case invalid(requiresRedownload: Bool)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    private enum ResourceOperationPhase: Equatable {
        case downloading
        case installing
        case uninstalling
    }

    private struct PendingDownload {
        let manifest: OhMyZshResourceManifest
        let url: URL
        var completions: [@Sendable (Result<Void, Error>) -> Void]
    }

    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeOperationPhase: ResourceOperationPhase?
    private var activeDownloadManifest: OhMyZshResourceManifest?
    private var activeDownloadCompletions: [@Sendable (Result<Void, Error>) -> Void] = []
    private var pendingDownloads: [PendingDownload] = []
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var validatedInstallation: ValidatedInstallation?
    private var integrityValidationKnown = false
    private var integrityValidationInProgress = false
    private var integrityValidationCompletionDeliveryInProgress = false
    private var integrityRequiresRedownload = false
    private var lastIntegrityValidationDate: Date?
    private var integrityValidationCompletions: [@Sendable (Bool) -> Void] = []
    private var deferredForcedValidationCompletions: [@Sendable (Bool) -> Void] = []
    private var integrityValidationAfterGateCompletions: [@Sendable (Bool) -> Void] = []
    private var integrityValidationAfterGateDeliveryInProgress = false
    private var forcedValidationPending = false
    private var registerFontAfterValidation = false
    private var deploymentSnapshotCreationCount = 0

    private let fontRegistrationLock = NSLock()
    private struct RegisteredFont {
        let identity: String
        let url: URL
    }
    private var registeredFont: RegisteredFont?

    public init(
        resourceDirectoryURL: URL? = nil,
        baseURL: URL? = nil,
        fileManager: FileManager = .default,
        session: URLSession? = nil,
        integrityRevalidationInterval: TimeInterval = 300,
        clock: @escaping () -> Date = { Date() },
        treeDigestProvider: ((URL) throws -> String)? = nil,
        deploymentSnapshotCopier: ((URL, URL) throws -> Void)? = nil,
        fontRegistrar: ((URL) -> Bool)? = nil,
        fontUnregistrar: ((URL) -> Bool)? = nil
    ) {
        self.fileManager = fileManager
        if let resourceDirectoryURL {
            self.resourceDirectoryURL = resourceDirectoryURL
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            self.resourceDirectoryURL = appSupport?
                .appendingPathComponent("Stacio", isDirectory: true)
                .appendingPathComponent(Self.resourceDirectoryName, isDirectory: true)
        }
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.integrityRevalidationInterval = max(0, integrityRevalidationInterval)
        self.clock = clock
        self.treeDigestProvider = treeDigestProvider
        self.deploymentSnapshotCopier = deploymentSnapshotCopier ?? { source, destination in
            try fileManager.copyItem(at: source, to: destination)
        }
        self.fontRegistrar = fontRegistrar ?? { Self.registerFontWithCoreText($0) }
        self.fontUnregistrar = fontUnregistrar ?? { Self.unregisterFontWithCoreText($0) }
        self.fontRegistrationDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("Stacio-RegisteredFonts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - 状态

    public struct Status: Equatable {
        public let installedVersion: String?
        public let isDownloading: Bool
        public let isInstalling: Bool
        public let isUninstalling: Bool
        public let isValidating: Bool
        public let requiresRedownload: Bool
        public let downloadProgress: Double?

        public var isBusy: Bool {
            isDownloading || isInstalling || isUninstalling || isValidating
        }

        public var isInstalled: Bool {
            installedVersion != nil
        }
    }

    public func status() -> Status {
        lock.lock()
        scheduleIntegrityValidationLocked(force: false)
        let status = statusLocked()
        lock.unlock()
        return status
    }

    private func statusLocked() -> Status {
        Status(
            installedVersion: validatedInstallation?.version,
            isDownloading: activeOperationPhase == .downloading,
            isInstalling: activeOperationPhase == .installing,
            isUninstalling: activeOperationPhase == .uninstalling,
            isValidating: integrityValidationInProgress || integrityValidationAfterGateDeliveryInProgress,
            requiresRedownload: integrityRequiresRedownload,
            downloadProgress: activeDownloadProgress
        )
    }

    public var baseURLValue: URL { baseURL }

    /// 已安装资源目录（不存在时返回 nil）。
    public var installedDirectoryURL: URL? {
        lock.lock()
        scheduleIntegrityValidationLocked(force: false)
        guard validatedInstallation != nil,
              let resourceDirectoryURL else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return resourceDirectoryURL
    }

    /// Nerd Font 所在路径（仅来自已下载且校验通过的资源目录）。
    public var nerdFontURL: URL? {
        if let installed = installedDirectoryURL {
            let downloaded = installed.appendingPathComponent("fonts").appendingPathComponent(Self.nerdFontFileName)
            if fileManager.fileExists(atPath: downloaded.path) {
                return downloaded
            }
        }
        return nil
    }

    // MARK: - 下载

    public func fetchManifest(completion: @escaping @Sendable (Result<OhMyZshResourceManifest, Error>) -> Void) {
        let url = baseURL.appendingPathComponent("manifest.json")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                completion(.failure(OhMyZshResourceError.manifestUnavailable))
                return
            }
            guard let data else {
                completion(.failure(OhMyZshResourceError.manifestUnavailable))
                return
            }
            do {
                let manifest = try JSONDecoder().decode(OhMyZshResourceManifest.self, from: data)
                completion(.success(manifest))
            } catch {
                completion(.failure(OhMyZshResourceError.manifestDecodeFailed))
            }
        }.resume()
    }

    /// 下载并安装快照（幂等：已装同版本则跳过）。下载完成后回调于任意队列。
    public func downloadIfNeeded(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        fetchManifest { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(manifest):
                self.validateInstalledResourcesAfterGate(force: true) { isValid in
                    if isValid, self.cachedInstallationMatches(manifest: manifest) {
                        completion(.success(()))
                    } else {
                        self.download(manifest: manifest, completion: completion)
                    }
                }
            }
        }
    }

    /// 下载并安装快照（显式拉取最新 manifest）。
    public func download(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        fetchManifest { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(manifest):
                self.download(manifest: manifest, completion: completion)
            }
        }
    }

    private func download(
        manifest: OhMyZshResourceManifest,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let url = Self.resolveDownloadURL(
            baseURL: baseURL,
            downloadPath: manifest.downloadPath
        ) else {
            completion(.failure(OhMyZshResourceError.invalidDownloadPath))
            return
        }

        lock.lock()
        if activeOperationPhase == .downloading || activeOperationPhase == .installing {
            if activeDownloadManifest == manifest {
                activeDownloadCompletions.append(completion)
                lock.unlock()
                return
            }
        }
        if let index = pendingDownloads.firstIndex(where: { $0.manifest == manifest }) {
            pendingDownloads[index].completions.append(completion)
            lock.unlock()
            return
        }
        if activeOperationPhase == .downloading
            || activeOperationPhase == .installing
            || integrityValidationInProgress
            || integrityValidationAfterGateDeliveryInProgress
            || pendingDownloads.isEmpty == false {
            pendingDownloads.append(PendingDownload(
                manifest: manifest,
                url: url,
                completions: [completion]
            ))
            lock.unlock()
            return
        }
        if activeOperationPhase != nil || deploymentSnapshotCreationCount > 0 {
            lock.unlock()
            completion(.failure(OhMyZshResourceError.downloadInProgress))
            return
        }
        let task = startDownloadLocked(manifest: manifest, url: url, completions: [completion])
        lock.unlock()
        task.resume()
    }

    private func startDownloadLocked(
        manifest: OhMyZshResourceManifest,
        url: URL,
        completions: [@Sendable (Result<Void, Error>) -> Void]
    ) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self else { return }
            if let error {
                self.finishDownloadOperation(.failure(error))
                return
            }
            guard let tempURL else {
                self.finishDownloadOperation(.failure(OhMyZshResourceError.downloadFailed))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                self.finishDownloadOperation(.failure(OhMyZshResourceError.downloadFailed))
                return
            }

            self.lock.lock()
            self.activeDownloadTask = nil
            self.activeOperationPhase = .installing
            self.activeDownloadProgress = nil
            self.lock.unlock()

            let result: Result<Void, Error>
            do {
                let installation = try self.verifyAndInstall(temporaryURL: tempURL, manifest: manifest)
                self.storeValidatedInstallation(installation)
                _ = self.registerNerdFontIfNeeded()
                // 后台下载完成时提示用户（即使已关闭设置窗口也能收到系统通知），
                // 让用户知道资源已就绪、可以在设置中启用 Oh My Zsh。
                OhMyZshNotificationPresenter.postResourceReady(version: manifest.version)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.finishDownloadOperation(result)
        }
        invalidateIntegrityCacheLocked()
        activeOperationPhase = .downloading
        activeDownloadManifest = manifest
        activeDownloadCompletions = completions
        activeDownloadTask = task
        activeDownloadProgress = 0
        return task
    }

    private func startNextPendingDownloadLocked() -> URLSessionDownloadTask? {
        guard activeOperationPhase == nil,
              integrityValidationInProgress == false,
              integrityValidationAfterGateDeliveryInProgress == false,
              deploymentSnapshotCreationCount == 0,
              pendingDownloads.isEmpty == false else {
            return nil
        }
        let pending = pendingDownloads.removeFirst()
        return startDownloadLocked(
            manifest: pending.manifest,
            url: pending.url,
            completions: pending.completions
        )
    }

    private func finishDownloadOperation(_ result: Result<Void, Error>) {
        lock.lock()
        activeDownloadTask = nil
        activeOperationPhase = nil
        activeDownloadProgress = nil
        activeDownloadManifest = nil
        let completions = activeDownloadCompletions
        activeDownloadCompletions.removeAll()
        let shouldRunForcedValidation = preparePendingForcedValidationLocked()
        let nextDownloadTask = shouldRunForcedValidation ? nil : startNextPendingDownloadLocked()
        lock.unlock()
        postStatusDidChange()
        if shouldRunForcedValidation {
            runIntegrityValidation()
        }
        nextDownloadTask?.resume()
        completions.forEach { $0(result) }
    }

    private func finishOperation() {
        lock.lock()
        activeDownloadTask = nil
        activeOperationPhase = nil
        activeDownloadProgress = nil
        lock.unlock()
        postStatusDidChange()
    }

    static func resolveDownloadURL(baseURL: URL, downloadPath: String) -> URL? {
        let trimmed = downloadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = baseURL.scheme?.lowercased()
        guard trimmed.isEmpty == false,
              trimmed == downloadPath,
              scheme == "https" || scheme == "http",
              baseURL.host != nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              trimmed.hasPrefix("/") == false,
              trimmed.hasPrefix("\\") == false,
              trimmed.contains("\\") == false,
              trimmed.contains("?") == false,
              trimmed.contains("#") == false,
              trimmed.contains("%") == false else {
            return nil
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.isEmpty == false,
              components.allSatisfy({ component in
                  component.isEmpty == false && component != "." && component != ".."
              }) else {
            return nil
        }

        var resolvedURL = baseURL
        for component in components {
            resolvedURL = resolvedURL.appendingPathComponent(String(component))
        }
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        let resolvedPath = resolvedURL.path
        guard resolvedPath == baseURL.path || resolvedPath.hasPrefix(basePath) else {
            return nil
        }
        return resolvedURL
    }

    // MARK: - 校验与安装

    /// tar 成员路径安全判定（纵深防御）：拒绝绝对路径与 `../` 穿越成员。
    static func archiveMemberIsUnsafe(_ rawMember: String) -> Bool {
        let member = rawMember.trimmingCharacters(in: .whitespacesAndNewlines)
        return member.hasPrefix("/") || member.components(separatedBy: "/").contains("..")
    }

    private func verifyAndInstall(
        temporaryURL: URL,
        manifest: OhMyZshResourceManifest
    ) throws -> ValidatedInstallation {
        // 1) sha256 校验（供应链：解压前必须与 manifest 一致）
        let resourceSize = try fileManager.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber
        guard let resourceSize, resourceSize.int64Value == manifest.sizeBytes else {
            throw OhMyZshResourceError.sizeMismatch
        }
        let data = try Data(contentsOf: temporaryURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else {
            throw OhMyZshResourceError.sha256Mismatch
        }

        // 2) 解压前校验 tar 成员路径安全（纵深防御：拒绝 `../` 穿越与绝对路径成员，
        //    防恶意/损坏 bundle 写出 staging 之外——sha256 已挡供应链，此为二次防线）
        let listProcess = Process()
        listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        listProcess.arguments = ["-tzf", temporaryURL.path]
        let listPipe = Pipe()
        listProcess.standardOutput = listPipe
        listProcess.standardError = Pipe()
        try listProcess.run()
        listProcess.waitUntilExit()
        guard listProcess.terminationStatus == 0 else {
            throw OhMyZshResourceError.extractionFailed
        }
        let listing = String(data: listPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let unsafeMember = listing.split(separator: "\n").contains { rawMember in
            Self.archiveMemberIsUnsafe(String(rawMember))
        }
        guard !unsafeMember else {
            throw OhMyZshResourceError.unsafeArchiveMember
        }

        // 3) 解压到临时目录（tar.gz 顶层即 OhMyZsh 目录内容）
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("omz-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", temporaryURL.path, "-C", staging.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OhMyZshResourceError.extractionFailed
        }
        // tar 根目录只有一个顶层目录时收齐其内容，否则假定平铺
        let extractedRoot = try normalizedExtractedRoot(staging)
        // 符号链接必须按最终安装根语义校验。单顶层 wrapper 下的 `../outside`
        // 在 staging 根内可能看似安全，但 wrapper 移到最终目录后会越界。
        try validateExtractedSymlinks(in: extractedRoot)

        // 3) 替换已安装目录（原子：先备份再移动，失败回滚）
        guard let resourceDirectoryURL else {
            throw OhMyZshResourceError.installFailed
        }
        let previousFont = try detachManagedFontForReplacement()
        let treeHash: String
        do {
            treeHash = try installExtractedDirectory(
                from: extractedRoot,
                to: resourceDirectoryURL,
                manifest: manifest
            )
            discardDetachedFont(previousFont)
        } catch {
            restoreDetachedFont(previousFont)
            throw error
        }
        return ValidatedInstallation(
            version: manifest.version,
            manifestHash: manifest.sha256.lowercased(),
            treeHash: treeHash
        )
    }

    private func normalizedExtractedRoot(_ staging: URL) throws -> URL {
        let contents = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if contents.count == 1 {
            var isDir: ObjCBool = false
            let single = contents[0]
            if fileManager.fileExists(atPath: single.path, isDirectory: &isDir), isDir.boolValue {
                return single
            }
        }
        return staging
    }

    private func validateExtractedSymlinks(in root: URL) throws {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = canonicalRoot.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            let canonicalParent = url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let canonicalLinkPath = canonicalParent
                .appendingPathComponent(url.lastPathComponent)
                .path
            guard Self.archiveSymbolicLinkIsUnsafe(
                target: target,
                linkPath: canonicalLinkPath,
                rootPath: rootPath
            ) == false else {
                throw OhMyZshResourceError.unsafeArchiveMember
            }
        }
    }

    static func archiveSymbolicLinkIsUnsafe(
        target: String,
        linkPath: String,
        rootPath: String
    ) -> Bool {
        guard target.hasPrefix("/") == false else { return true }
        let candidate = URL(fileURLWithPath: linkPath)
            .deletingLastPathComponent()
            .appendingPathComponent(target)
            .standardizedFileURL
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else {
            return true
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path != root.path && resolved.path.hasPrefix(rootPrefix) == false
    }

    private func installExtractedDirectory(
        from extractedRoot: URL,
        to resourceDirectoryURL: URL,
        manifest: OhMyZshResourceManifest
    ) throws -> String {
        let parent = resourceDirectoryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let backupURL = parent.appendingPathComponent(".OhMyZsh.stacio-backup-\(UUID().uuidString)")
        let hadExisting = fileManager.fileExists(atPath: resourceDirectoryURL.path)
        let treeHash = try directoryTreeDigest(at: extractedRoot)
        if hadExisting {
            try fileManager.moveItem(at: resourceDirectoryURL, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: extractedRoot, to: resourceDirectoryURL)
            // 写版本标记
            try manifest.version.write(
                to: resourceDirectoryURL.appendingPathComponent(Self.versionMarkerFileName),
                atomically: true,
                encoding: .utf8
            )
            try manifest.sha256.lowercased().write(
                to: resourceDirectoryURL.appendingPathComponent(Self.manifestHashMarkerFileName),
                atomically: true,
                encoding: .utf8
            )
            try treeHash.write(
                to: resourceDirectoryURL.appendingPathComponent(Self.installTreeHashMarkerFileName),
                atomically: true,
                encoding: .utf8
            )
            if hadExisting {
                try? fileManager.removeItem(at: backupURL)
            }
            return treeHash
        } catch {
            if fileManager.fileExists(atPath: resourceDirectoryURL.path) {
                _ = try? fileManager.removeItem(at: resourceDirectoryURL)
            }
            if hadExisting, fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: resourceDirectoryURL)
            }
            throw OhMyZshResourceError.installFailed
        }
    }

    func directoryTreeDigest(at root: URL) throws -> String {
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: normalizedRoot.path) else {
            throw OhMyZshResourceError.installFailed
        }
        let rootPrefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var entries: [String] = []
        if let enumerator = fileManager.enumerator(
            at: normalizedRoot,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) {
            for case let url as URL in enumerator {
                // FileManager may enumerate /private/var/... for a /var/... root.
                // Canonicalize only the parent path so the final symlink component
                // remains observable and is hashed as a link, not as its target.
                let canonicalParent = url.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let canonicalURL = canonicalParent.appendingPathComponent(url.lastPathComponent)
                let canonicalPath = canonicalURL.path
                guard canonicalPath.hasPrefix(rootPrefix) else { continue }
                if canonicalParent.path == normalizedRoot.path,
                   Self.integrityMetadataFileNames.contains(url.lastPathComponent) {
                    continue
                }
                let values = try url.resourceValues(forKeys: keys)
                let relativePath = String(canonicalPath.dropFirst(rootPrefix.count))
                // oh-my-zsh writes runtime caches (for example cache/grep-alias)
                // into the installed tree. They are not part of the signed
                // release and must not invalidate an otherwise verified resource.
                if relativePath == "cache" || relativePath.hasPrefix("cache/") {
                    continue
                }
                if values.isSymbolicLink == true {
                    let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                    entries.append("L\t\(relativePath)\t\(target)")
                } else if values.isDirectory == true {
                    entries.append("D\t\(relativePath)")
                } else {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let contentHash = SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                    let size = values.fileSize ?? data.count
                    entries.append("F\t\(relativePath)\t\(size)\t\(contentHash)")
                }
            }
        }
        let canonical = entries.sorted().joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func computedDirectoryTreeDigest(at root: URL) throws -> String {
        if let treeDigestProvider {
            return try treeDigestProvider(root)
        }
        return try directoryTreeDigest(at: root)
    }

    // MARK: - 后台完整性校验

    /// 测试与需要立即刷新完整性状态的调用方使用。摘要计算始终在专用后台队列执行。
    func refreshIntegrityValidation(completion: @escaping @Sendable (Bool) -> Void) {
        validateInstalledResources(force: true, completion: completion)
    }

    /// 部署专用门禁：每次都在请求之后完成一轮完整树摘要校验，再创建独立快照。
    /// 如果请求到达时已有扫描在运行，会排队执行下一轮扫描后才回调。
    public func validatedResourceLeaseForDeployment(
        completion: @escaping @Sendable (Result<OhMyZshDeploymentLease, Error>) -> Void
    ) {
        validateInstalledResources(force: true) { [weak self] isValid in
            guard let self, isValid else {
                completion(.failure(OhMyZshResourceError.integrityValidationFailed))
                return
            }
            do {
                completion(.success(try self.makeDeploymentLease()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func makeDeploymentLease() throws -> OhMyZshDeploymentLease {
        lock.lock()
        guard activeOperationPhase == nil,
              let installation = validatedInstallation,
              let resourceDirectoryURL else {
            lock.unlock()
            throw OhMyZshResourceError.integrityValidationFailed
        }
        deploymentSnapshotCreationCount += 1
        lock.unlock()
        defer {
            lock.lock()
            deploymentSnapshotCreationCount -= 1
            lock.unlock()
        }

        let leaseContainer = fileManager.temporaryDirectory
            .appendingPathComponent("Stacio-OhMyZsh-Deployments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshotURL = leaseContainer.appendingPathComponent("OhMyZsh", isDirectory: true)
        do {
            try fileManager.createDirectory(at: leaseContainer, withIntermediateDirectories: true)
            try deploymentSnapshotCopier(resourceDirectoryURL, snapshotURL)
            let snapshotHash = try directoryTreeDigest(at: snapshotURL)
            guard snapshotHash == installation.treeHash else {
                markIntegrityFailureRequiresRedownload()
                throw OhMyZshResourceError.integrityValidationFailed
            }
            return OhMyZshDeploymentLease(
                directoryURL: snapshotURL,
                version: installation.version,
                treeHash: snapshotHash,
                cleanup: { [fileManager] in
                    try? fileManager.removeItem(at: leaseContainer)
                }
            )
        } catch {
            try? fileManager.removeItem(at: leaseContainer)
            throw error
        }
    }

    private func markIntegrityFailureRequiresRedownload() {
        lock.lock()
        validatedInstallation = nil
        integrityValidationKnown = true
        integrityRequiresRedownload = true
        lastIntegrityValidationDate = clock()
        lock.unlock()
        postStatusDidChange()
    }

    private func validateInstalledResources(
        force: Bool,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        lock.lock()
        scheduleIntegrityValidationLocked(force: force, completion: completion)
        lock.unlock()
    }

    /// Operation handoff used by download decisions. Unlike lease waiters, this completion is
    /// delivered only after validation callbacks have finished creating protected snapshots and
    /// the integrity gate is no longer busy.
    private func validateInstalledResourcesAfterGate(
        force: Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        validateInstalledResources(force: force) { [weak self] _ in
            self?.enqueueIntegrityValidationAfterGateCompletion(completion)
        }
    }

    private func enqueueIntegrityValidationAfterGateCompletion(
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        guard integrityValidationInProgress || integrityValidationAfterGateDeliveryInProgress else {
            let isValid = validatedInstallation != nil
            lock.unlock()
            integrityValidationQueue.async { completion(isValid) }
            return
        }
        integrityValidationAfterGateCompletions.append(completion)
        lock.unlock()
    }

    private func scheduleIntegrityValidationLocked(
        force: Bool,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        if integrityValidationAfterGateDeliveryInProgress {
            if force {
                forcedValidationPending = true
                if let completion {
                    deferredForcedValidationCompletions.append(completion)
                }
            } else if let completion {
                let isValid = validatedInstallation != nil
                integrityValidationQueue.async { completion(isValid) }
            }
            return
        }
        guard activeOperationPhase == nil else {
            if let completion {
                integrityValidationQueue.async { completion(false) }
            }
            return
        }
        if integrityValidationInProgress {
            if integrityValidationCompletionDeliveryInProgress, force == false {
                if let completion {
                    let isValid = validatedInstallation != nil
                    integrityValidationQueue.async { completion(isValid) }
                }
                return
            }
            if force {
                forcedValidationPending = true
                if let completion {
                    deferredForcedValidationCompletions.append(completion)
                }
            } else if let completion {
                integrityValidationCompletions.append(completion)
            }
            return
        }

        let now = clock()
        if force == false,
           integrityValidationKnown,
           let lastIntegrityValidationDate,
           now.timeIntervalSince(lastIntegrityValidationDate) >= 0,
           now.timeIntervalSince(lastIntegrityValidationDate) < integrityRevalidationInterval {
            if let completion {
                let isValid = validatedInstallation != nil
                integrityValidationQueue.async { completion(isValid) }
            }
            return
        }

        integrityValidationInProgress = true
        // 到期复验期间不继续暴露旧目录，防止篡改发生后在摘要完成前被部署。
        validatedInstallation = nil
        integrityRequiresRedownload = false
        if let completion {
            integrityValidationCompletions.append(completion)
        }
        integrityValidationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.inspectInstalledResource()
            self.completeIntegrityValidation(result)
        }
    }

    private func preparePendingForcedValidationLocked() -> Bool {
        guard forcedValidationPending,
              integrityValidationInProgress == false,
              integrityValidationAfterGateDeliveryInProgress == false,
              activeOperationPhase == nil,
              deploymentSnapshotCreationCount == 0 else {
            return false
        }
        forcedValidationPending = false
        integrityValidationCompletions = deferredForcedValidationCompletions
        deferredForcedValidationCompletions.removeAll()
        validatedInstallation = nil
        integrityRequiresRedownload = false
        integrityValidationInProgress = true
        return true
    }

    private func runIntegrityValidation() {
        integrityValidationQueue.async { [weak self] in
            guard let self else { return }
            self.completeIntegrityValidation(self.inspectInstalledResource())
        }
    }

    private func inspectInstalledResource() -> IntegrityValidationResult {
        guard let resourceDirectoryURL,
              fileManager.fileExists(atPath: resourceDirectoryURL.path) else {
            return .invalid(requiresRedownload: false)
        }

        let version = markerValue(named: Self.versionMarkerFileName, in: resourceDirectoryURL)
        let manifestHash = markerValue(named: Self.manifestHashMarkerFileName, in: resourceDirectoryURL)
        let storedTreeHash = markerValue(named: Self.installTreeHashMarkerFileName, in: resourceDirectoryURL)
        guard let version, version.isEmpty == false,
              let manifestHash, manifestHash.isEmpty == false,
              let storedTreeHash, storedTreeHash.isEmpty == false else {
            // 97e26caa 只存在于内部开发分支，未进入 tag/远端分支或对外测试包。
            // 对可能残留的内部安装不原地补签当前内容，保留目录并要求重新下载可信快照。
            return .invalid(requiresRedownload: true)
        }

        for relativePath in Self.requiredInstalledRelativePaths {
            let path = resourceDirectoryURL.appendingPathComponent(relativePath).path
            guard fileManager.fileExists(atPath: path) else {
                return .invalid(requiresRedownload: true)
            }
        }
        guard let currentTreeHash = try? computedDirectoryTreeDigest(at: resourceDirectoryURL),
              currentTreeHash == storedTreeHash else {
            return .invalid(requiresRedownload: true)
        }
        return .valid(ValidatedInstallation(
            version: version,
            manifestHash: manifestHash,
            treeHash: storedTreeHash
        ))
    }

    private func markerValue(named name: String, in root: URL) -> String? {
        (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeIntegrityValidation(_ result: IntegrityValidationResult) {
        lock.lock()
        integrityValidationKnown = true
        lastIntegrityValidationDate = clock()
        switch result {
        case let .valid(installation):
            validatedInstallation = installation
            integrityRequiresRedownload = false
        case let .invalid(requiresRedownload):
            validatedInstallation = nil
            integrityRequiresRedownload = requiresRedownload
        }
        let currentCompletions = integrityValidationCompletions
        integrityValidationCompletions.removeAll()
        let shouldRunForcedFollowUp = forcedValidationPending
        let completions: [@Sendable (Bool) -> Void]
        let shouldRegisterFont: Bool
        if shouldRunForcedFollowUp {
            forcedValidationPending = false
            // A later force request requires a post-request scan. Keep every earlier waiter
            // attached to the validation chain until that newest scan completes; otherwise
            // clearing validatedInstallation below makes the earlier lease fail spuriously.
            integrityValidationCompletions = currentCompletions
                + deferredForcedValidationCompletions
            deferredForcedValidationCompletions.removeAll()
            // 后续强制门禁完成前不暴露上一轮结果。
            validatedInstallation = nil
            integrityRequiresRedownload = false
            integrityValidationInProgress = true
            integrityValidationCompletionDeliveryInProgress = false
            completions = []
            shouldRegisterFont = false
        } else {
            // Keep the validation gate closed while callbacks create their snapshots. A new
            // force request during delivery is chained behind this result instead of clearing
            // validatedInstallation underneath an earlier callback.
            integrityValidationInProgress = true
            integrityValidationCompletionDeliveryInProgress = true
            completions = currentCompletions
            shouldRegisterFont = registerFontAfterValidation && result.isValid
            registerFontAfterValidation = false
        }
        lock.unlock()

        if shouldRunForcedFollowUp {
            integrityValidationQueue.async { [weak self] in
                guard let self else { return }
                self.completeIntegrityValidation(self.inspectInstalledResource())
            }
            return
        }
        completions.forEach { $0(result.isValid) }

        lock.lock()
        integrityValidationCompletionDeliveryInProgress = false
        let shouldRunLateForcedFollowUp = forcedValidationPending
        let afterGateCompletions: [@Sendable (Bool) -> Void]
        let statusBeforeAfterGateDelivery: Status?
        if shouldRunLateForcedFollowUp {
            forcedValidationPending = false
            integrityValidationCompletions = deferredForcedValidationCompletions
            deferredForcedValidationCompletions.removeAll()
            validatedInstallation = nil
            integrityRequiresRedownload = false
            integrityValidationInProgress = true
            if shouldRegisterFont {
                registerFontAfterValidation = true
            }
            afterGateCompletions = []
            statusBeforeAfterGateDelivery = nil
        } else {
            integrityValidationInProgress = false
            afterGateCompletions = integrityValidationAfterGateCompletions
            integrityValidationAfterGateCompletions.removeAll()
            integrityValidationAfterGateDeliveryInProgress = afterGateCompletions.isEmpty == false
            statusBeforeAfterGateDelivery = statusLocked()
        }
        lock.unlock()

        if shouldRunLateForcedFollowUp {
            integrityValidationQueue.async { [weak self] in
                guard let self else { return }
                self.completeIntegrityValidation(self.inspectInstalledResource())
            }
        } else {
            if shouldRegisterFont {
                _ = registerNerdFontIfNeeded()
            }
            postStatusDidChange()
            afterGateCompletions.forEach { $0(result.isValid) }
            lock.lock()
            integrityValidationAfterGateDeliveryInProgress = false
            let shouldRunForcedValidation = preparePendingForcedValidationLocked()
            let nextDownloadTask = shouldRunForcedValidation ? nil : startNextPendingDownloadLocked()
            let shouldPublishFinalStatus = statusBeforeAfterGateDelivery.map { $0 != statusLocked() } ?? false
            lock.unlock()
            if shouldPublishFinalStatus {
                postStatusDidChange()
            }
            if shouldRunForcedValidation {
                runIntegrityValidation()
            }
            nextDownloadTask?.resume()
        }
    }

    private func cachedInstallationMatches(manifest: OhMyZshResourceManifest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return validatedInstallation?.version == manifest.version
            && validatedInstallation?.manifestHash == manifest.sha256.lowercased()
    }

    private func storeValidatedInstallation(_ installation: ValidatedInstallation) {
        lock.lock()
        validatedInstallation = installation
        integrityValidationKnown = true
        integrityRequiresRedownload = false
        lastIntegrityValidationDate = clock()
        lock.unlock()
    }

    private func invalidateIntegrityCacheLocked() {
        validatedInstallation = nil
        integrityValidationKnown = false
        integrityRequiresRedownload = false
        lastIntegrityValidationDate = nil
    }

    private func markResourceMissingLocked() {
        validatedInstallation = nil
        integrityValidationKnown = true
        integrityRequiresRedownload = false
        lastIntegrityValidationDate = clock()
    }

    // MARK: - 卸载

    /// 卸载已下载资源（含 Nerd Font）并关闭全局启用开关。调用方需先恢复终端。
    public func uninstall(settingsStore: AppSettingsStore) throws {
        lock.lock()
        guard activeOperationPhase == nil,
              integrityValidationInProgress == false,
              integrityValidationAfterGateDeliveryInProgress == false,
              deploymentSnapshotCreationCount == 0 else {
            lock.unlock()
            throw OhMyZshResourceError.downloadInProgress
        }
        activeOperationPhase = .uninstalling
        invalidateIntegrityCacheLocked()
        lock.unlock()
        defer { finishOperation() }

        guard unregisterManagedFontIfNeeded() else {
            throw OhMyZshResourceError.fontUnregistrationFailed
        }

        settingsStore.update { settings in
            settings.ohmyzshEnabled = false
        }
        if let resourceDirectoryURL,
           fileManager.fileExists(atPath: resourceDirectoryURL.path) {
            try fileManager.removeItem(at: resourceDirectoryURL)
        }
        lock.lock()
        markResourceMissingLocked()
        lock.unlock()
    }

    private func postStatusDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.statusDidChangeNotification,
                object: self
            )
        }
    }

    // MARK: - 字体注册

    /// 注册已验证下载资源中的 Nerd Font。失败不会记为成功，下次调用仍会重试。
    @discardableResult
    public func registerNerdFontIfNeeded() -> Bool {
        lock.lock()
        guard let installation = validatedInstallation,
              let resourceDirectoryURL else {
            registerFontAfterValidation = true
            scheduleIntegrityValidationLocked(force: false)
            lock.unlock()
            return false
        }
        let fontURL = resourceDirectoryURL
            .appendingPathComponent("fonts")
            .appendingPathComponent(Self.nerdFontFileName)
        let identity = "\(installation.treeHash)|\(fontURL.standardizedFileURL.path)"
        lock.unlock()

        guard fileManager.fileExists(atPath: fontURL.path) else {
            validateInstalledResources(force: true)
            return false
        }
        fontRegistrationLock.lock()
        defer { fontRegistrationLock.unlock() }
        if registeredFont?.identity == identity {
            return true
        }
        if let registeredFont {
            guard fontUnregistrar(registeredFont.url) else {
                return false
            }
            try? fileManager.removeItem(at: registeredFont.url)
            self.registeredFont = nil
        }
        let registeredURL: URL
        do {
            try fileManager.createDirectory(
                at: fontRegistrationDirectoryURL,
                withIntermediateDirectories: true
            )
            registeredURL = fontRegistrationDirectoryURL
                .appendingPathComponent("\(installation.treeHash)-\(Self.nerdFontFileName)")
            if fileManager.fileExists(atPath: registeredURL.path) {
                try fileManager.removeItem(at: registeredURL)
            }
            try fileManager.copyItem(at: fontURL, to: registeredURL)
        } catch {
            try? fileManager.removeItem(at: fontRegistrationDirectoryURL)
            return false
        }
        guard fontRegistrar(registeredURL) else {
            try? fileManager.removeItem(at: registeredURL)
            try? fileManager.removeItem(at: fontRegistrationDirectoryURL)
            return false
        }
        registeredFont = RegisteredFont(identity: identity, url: registeredURL)
        return true
    }

    private static func registerFontWithCoreText(_ fontURL: URL) -> Bool {
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError) {
            return true
        }
        _ = registrationError?.takeRetainedValue()
        return false
    }

    private static func unregisterFontWithCoreText(_ fontURL: URL) -> Bool {
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerUnregisterFontsForURL(fontURL as CFURL, .process, &registrationError) {
            return true
        }
        _ = registrationError?.takeRetainedValue()
        return false
    }

    private func unregisterManagedFontIfNeeded() -> Bool {
        let detached: RegisteredFont?
        fontRegistrationLock.lock()
        guard let registeredFont else {
            fontRegistrationLock.unlock()
            return true
        }
        guard fontUnregistrar(registeredFont.url) else {
            fontRegistrationLock.unlock()
            return false
        }
        self.registeredFont = nil
        detached = registeredFont
        fontRegistrationLock.unlock()
        discardDetachedFont(detached)
        return true
    }

    private func detachManagedFontForReplacement() throws -> RegisteredFont? {
        fontRegistrationLock.lock()
        defer { fontRegistrationLock.unlock() }
        guard let registeredFont else { return nil }
        guard fontUnregistrar(registeredFont.url) else {
            throw OhMyZshResourceError.fontUnregistrationFailed
        }
        self.registeredFont = nil
        return registeredFont
    }

    private func restoreDetachedFont(_ detached: RegisteredFont?) {
        guard let detached else { return }
        fontRegistrationLock.lock()
        defer { fontRegistrationLock.unlock() }
        if fontRegistrar(detached.url) {
            registeredFont = detached
        } else {
            try? fileManager.removeItem(at: detached.url)
            try? fileManager.removeItem(at: fontRegistrationDirectoryURL)
        }
    }

    private func discardDetachedFont(_ detached: RegisteredFont?) {
        guard let detached else { return }
        try? fileManager.removeItem(at: detached.url)
        try? fileManager.removeItem(at: fontRegistrationDirectoryURL)
    }

    // MARK: - 私有

    private var activeDownloadProgress: Double?

    public func installedVersion() -> String? {
        status().installedVersion
    }
}

public enum OhMyZshResourceError: LocalizedError, Equatable {
    case manifestUnavailable
    case manifestDecodeFailed
    case downloadInProgress
    case invalidDownloadPath
    case downloadFailed
    case sizeMismatch
    case sha256Mismatch
    case unsafeArchiveMember
    case extractionFailed
    case installFailed
    case integrityValidationFailed
    case fontUnregistrationFailed

    public var errorDescription: String? {
        switch self {
        case .manifestUnavailable:
            return "无法获取 Oh My Zsh 资源清单，请检查网络后重试。"
        case .manifestDecodeFailed:
            return "Oh My Zsh 资源清单格式不正确，请稍后重试。"
        case .downloadInProgress:
            return "Oh My Zsh 资源正在下载或安装中，请稍候。"
        case .invalidDownloadPath:
            return "Oh My Zsh 资源下载路径不安全，已中止。"
        case .downloadFailed:
            return "Oh My Zsh 资源下载失败，请检查网络后重试。"
        case .sizeMismatch:
            return "Oh My Zsh 资源大小校验失败，已丢弃，请重试。"
        case .sha256Mismatch:
            return "Oh My Zsh 资源校验失败（哈希不匹配），已丢弃，请重试。"
        case .unsafeArchiveMember:
            return "资源包含不安全路径成员，已中止安装。"
        case .extractionFailed:
            return "Oh My Zsh 资源解压失败，请重试。"
        case .installFailed:
            return "Oh My Zsh 资源安装失败，请重试。"
        case .integrityValidationFailed:
            return "Oh My Zsh 资源完整性校验失败，请重新下载后再试。"
        case .fontUnregistrationFailed:
            return "无法安全替换正在使用的 Nerd Font，请稍后重试。"
        }
    }
}
