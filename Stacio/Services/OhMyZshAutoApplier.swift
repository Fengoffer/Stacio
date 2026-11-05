import Foundation
import StacioCoreBindings

/// Serializes Oh My Zsh settings deployment across local and remote targets.
/// UI target enumeration stays on MainActor; blocking deployment runs off-main.
public final class OhMyZshAutoApplier: @unchecked Sendable {
    public typealias RemoteApplyHandler = @MainActor (
        AppSettings,
        OhMyZshDeploymentLease?,
        @escaping @MainActor (Result<Void, Error>) -> Void
    ) -> Void

    private let settingsStore: AppSettingsStore
    private let resourceManager: OhMyZshResourceManager
    private let debounceInterval: TimeInterval
    private let coordinationQueue = DispatchQueue(label: "com.stacio.ohmyzsh.auto-apply.coordination")
    private let blockingQueue = DispatchQueue(label: "com.stacio.ohmyzsh.auto-apply.blocking", qos: .userInitiated)
    private let serialExecutor = OhMyZshAsyncSerialExecutor()
    private let lifecycleLock = NSLock()
    private var settingsObserver: Any?
    private var resourceObserver: Any?

    // Accessed only on coordinationQueue.
    private struct DesiredApplication {
        let snapshot: AppSettings
        let signature: String
        let generation: UInt64
    }

    private var pendingWorkItem: DispatchWorkItem?
    private var latestDesiredApplication: DesiredApplication?
    private var activeGlobalApplication: DesiredApplication?
    private var activeGlobalApplicationIsValidating = false
    private var nextApplicationGeneration: UInt64 = 0
    private var latestDesiredNeedsApply = false
    private var retryWhenResourceBecomesTrusted = false

    private let localApplyOperation: (AppSettings, URL?) throws -> Void
    private let remoteSessionApplyOperation: (
        SshConnectionConfig,
        SshAuthSecret,
        String,
        AppSettings,
        URL?
    ) throws -> Void

    /// Workbench-provided batch operation. The closure itself always runs on MainActor so it can
    /// snapshot AppKit-backed targets before moving pure connection values to a worker queue.
    public var remoteApplyHandler: RemoteApplyHandler?
    public var onLocalDeployFinished: (@MainActor (Result<Void, Error>) -> Void)?
    public var onApplyFinished: (@MainActor (Result<Void, Error>) -> Void)?
    public var localTerminalPanesProvider: (@MainActor () -> [TerminalPaneViewController])?

    public init(
        settingsStore: AppSettingsStore = .shared,
        resourceManager: OhMyZshResourceManager = .shared,
        debounceInterval: TimeInterval = 0.8,
        localApply: ((AppSettings, URL?) throws -> Void)? = nil,
        remoteSessionApply: ((
            SshConnectionConfig,
            SshAuthSecret,
            String,
            AppSettings,
            URL?
        ) throws -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.resourceManager = resourceManager
        self.debounceInterval = debounceInterval
        self.localApplyOperation = localApply ?? { settings, resourceURL in
            let deployer = LocalOhMyZshDeployer(bundleOhMyZshURL: resourceURL)
            if settings.ohmyzshEnabled {
                guard let resourceURL else {
                    throw OhMyZshResourceError.integrityValidationFailed
                }
                try deployer.deploy(
                    global: settings,
                    catalog: OhMyZshCatalog(directoryURL: resourceURL)
                )
            } else {
                try deployer.remove()
            }
        }
        self.remoteSessionApplyOperation = remoteSessionApply ?? {
            config,
            secret,
            fingerprint,
            settings,
            resourceURL in
            let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: resourceURL)
            if settings.ohmyzshEnabled {
                guard resourceURL != nil else {
                    throw OhMyZshResourceError.integrityValidationFailed
                }
                try deployer.deploy(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: fingerprint,
                    global: settings
                )
            } else {
                try deployer.remove(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: fingerprint
                )
            }
        }
    }

    public func start() {
        lifecycleLock.lock()
        guard settingsObserver == nil, resourceObserver == nil else {
            lifecycleLock.unlock()
            return
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: nil
        ) { [weak self] _ in
            self?.settingsDidChange()
        }
        resourceObserver = NotificationCenter.default.addObserver(
            forName: OhMyZshResourceManager.statusDidChangeNotification,
            object: resourceManager,
            queue: nil
        ) { [weak self] _ in
            self?.resourceStatusDidChange()
        }
        lifecycleLock.unlock()
    }

    public func stop() {
        lifecycleLock.lock()
        let observers = [settingsObserver, resourceObserver].compactMap { $0 }
        settingsObserver = nil
        resourceObserver = nil
        lifecycleLock.unlock()
        observers.forEach(NotificationCenter.default.removeObserver)
        coordinationQueue.async { [weak self] in
            self?.pendingWorkItem?.cancel()
            self?.pendingWorkItem = nil
        }
    }

    private func settingsDidChange() {
        let snapshot = settingsStore.snapshot()
        coordinationQueue.async { [weak self] in
            self?.scheduleSettingsApply(snapshot)
        }
    }

    private func scheduleSettingsApply(_ snapshot: AppSettings) {
        _ = recordLatestDesired(snapshot, force: false)
        if snapshot.ohmyzshEnabled == false {
            retryWhenResourceBecomesTrusted = false
        }
        pendingWorkItem?.cancel()
        guard latestDesiredNeedsApply else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWorkItem = nil
            self.supersedeValidationWithLatestDisableIfNeeded()
            self.startLatestDesiredApplicationIfNeeded()
        }
        pendingWorkItem = workItem
        coordinationQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func resourceStatusDidChange() {
        coordinationQueue.async { [weak self] in
            guard let self,
                  self.retryWhenResourceBecomesTrusted,
                  self.resourceManager.status().isInstalled else {
                return
            }
            let snapshot = self.settingsStore.snapshot()
            guard snapshot.ohmyzshEnabled else {
                self.retryWhenResourceBecomesTrusted = false
                return
            }
            self.retryWhenResourceBecomesTrusted = false
            _ = self.recordLatestDesired(snapshot, force: true)
            self.supersedeValidationWithLatestDisableIfNeeded()
            self.startLatestDesiredApplicationIfNeeded()
        }
    }

    private func ohMyZshSignature(_ settings: AppSettings) -> String {
        "\(settings.ohmyzshEnabled)|\(settings.ohmyzshTheme ?? "")|\(settings.ohmyzshPlugins.joined(separator: ","))|\(settings.ohmyzshExtraZshrcLines ?? "")"
    }

    /// May be called from any thread. Duplicate in-flight requests for the same settings are coalesced.
    public func forceApply() {
        let snapshot = settingsStore.snapshot()
        coordinationQueue.async { [weak self] in
            guard let self else { return }
            self.pendingWorkItem?.cancel()
            self.pendingWorkItem = nil
            _ = self.recordLatestDesired(snapshot, force: true)
            self.supersedeValidationWithLatestDisableIfNeeded()
            self.startLatestDesiredApplicationIfNeeded()
        }
    }

    @discardableResult
    private func recordLatestDesired(
        _ snapshot: AppSettings,
        force: Bool
    ) -> DesiredApplication {
        let signature = ohMyZshSignature(snapshot)
        if let current = latestDesiredApplication, current.signature == signature {
            if force, activeGlobalApplication == nil {
                nextApplicationGeneration &+= 1
                let desired = DesiredApplication(
                    snapshot: snapshot,
                    signature: signature,
                    generation: nextApplicationGeneration
                )
                latestDesiredApplication = desired
                latestDesiredNeedsApply = true
                return desired
            }
            let desired = DesiredApplication(
                snapshot: snapshot,
                signature: signature,
                generation: current.generation
            )
            latestDesiredApplication = desired
            return desired
        }

        nextApplicationGeneration &+= 1
        let desired = DesiredApplication(
            snapshot: snapshot,
            signature: signature,
            generation: nextApplicationGeneration
        )
        latestDesiredApplication = desired
        latestDesiredNeedsApply = true
        return desired
    }

    private func startLatestDesiredApplicationIfNeeded() {
        guard activeGlobalApplication == nil,
              latestDesiredNeedsApply,
              let desired = latestDesiredApplication else {
            return
        }
        activeGlobalApplication = desired
        latestDesiredNeedsApply = false
        startGlobalApplication(desired)
    }

    private func supersedeValidationWithLatestDisableIfNeeded() {
        guard activeGlobalApplicationIsValidating,
              latestDesiredApplication?.snapshot.ohmyzshEnabled == false else {
            return
        }
        // No deployment has started yet, so the validating enable can be discarded safely.
        // Its eventual callback is generation-checked and will only release a produced lease.
        activeGlobalApplication = nil
        activeGlobalApplicationIsValidating = false
    }

    private func startGlobalApplication(_ desired: DesiredApplication) {
        guard desired.snapshot.ohmyzshEnabled else {
            activeGlobalApplicationIsValidating = false
            enqueuePreparedGlobalApply(desired: desired, lease: nil)
            return
        }
        activeGlobalApplicationIsValidating = true
        resourceManager.validatedResourceLeaseForDeployment { [weak self] result in
            guard let self else {
                if case let .success(lease) = result { lease.release() }
                return
            }
            self.coordinationQueue.async { [weak self] in
                guard let self,
                      self.activeGlobalApplication?.generation == desired.generation else {
                    if case let .success(lease) = result { lease.release() }
                    return
                }
                self.activeGlobalApplicationIsValidating = false
                switch result {
                case let .success(lease):
                    self.enqueuePreparedGlobalApply(
                        desired: desired,
                        lease: lease
                    )
                case let .failure(error):
                    self.completeGlobalApply(desired: desired, result: .failure(error))
                    Task { @MainActor [weak self] in
                        self?.onLocalDeployFinished?(.failure(error))
                    }
                }
            }
        }
    }

    private func enqueuePreparedGlobalApply(
        desired: DesiredApplication,
        lease: OhMyZshDeploymentLease?
    ) {
        serialExecutor.enqueue { [weak self] in
            guard let self else {
                lease?.release()
                return
            }
            let result = await self.performGlobalApply(
                snapshot: desired.snapshot,
                lease: lease
            )
            self.completeGlobalApply(desired: desired, result: result)
        }
    }

    private func completeGlobalApply(
        desired: DesiredApplication,
        result: Result<Void, Error>
    ) {
        coordinationQueue.async { [weak self] in
            guard let self else { return }
            guard self.activeGlobalApplication?.generation == desired.generation else {
                return
            }
            self.activeGlobalApplication = nil
            self.activeGlobalApplicationIsValidating = false

            // The settings store can change just before its notification reaches the
            // coordination queue. Reconcile it here so a stale task cannot finish the drain.
            let currentSnapshot = self.settingsStore.snapshot()
            if self.ohMyZshSignature(currentSnapshot)
                != self.latestDesiredApplication?.signature {
                _ = self.recordLatestDesired(currentSnapshot, force: false)
            }

            let hasNewerIntent = self.latestDesiredApplication?.generation != desired.generation
            let isCancellation: Bool
            if case let .failure(error) = result {
                isCancellation = error is CancellationError
                if self.latestDesiredApplication?.generation == desired.generation {
                    self.latestDesiredNeedsApply = true
                }
                if self.shouldRetryWhenResourceBecomesTrusted(error),
                   self.latestDesiredApplication?.snapshot.ohmyzshEnabled == true {
                    self.retryWhenResourceBecomesTrusted = true
                }
            } else {
                isCancellation = false
                if self.latestDesiredApplication?.generation == desired.generation {
                    self.latestDesiredNeedsApply = false
                }
            }

            if isCancellation == false {
                Task { @MainActor [weak self] in
                    self?.onApplyFinished?(result)
                }
            }

            let waitingForTrustedResource = self.retryWhenResourceBecomesTrusted
                && self.latestDesiredApplication?.snapshot.ohmyzshEnabled == true
            if hasNewerIntent, waitingForTrustedResource == false {
                self.startLatestDesiredApplicationIfNeeded()
            }
        }
    }

    private func performGlobalApply(
        snapshot: AppSettings,
        lease: OhMyZshDeploymentLease?
    ) async -> Result<Void, Error> {
        defer { lease?.release() }

        let latest = settingsStore.snapshot()
        guard ohMyZshSignature(latest) == ohMyZshSignature(snapshot) else {
            return .failure(CancellationError())
        }

        let localResult: Result<Void, Error> = await runBlocking { [localApplyOperation] in
            try localApplyOperation(snapshot, lease?.directoryURL)
        }
        await publishLocalResult(localResult)
        if case .success = localResult {
            await reloadIdleLocalTerminals()
        }

        let remoteResult = await performRemoteBatch(settings: snapshot, lease: lease)
        if case let .failure(error) = localResult { return .failure(error) }
        return remoteResult
    }

    private func deploymentLeaseIfNeeded(
        for settings: AppSettings
    ) async -> Result<OhMyZshDeploymentLease?, Error> {
        guard settings.ohmyzshEnabled else { return .success(nil) }
        return await withCheckedContinuation { continuation in
            resourceManager.validatedResourceLeaseForDeployment { result in
                continuation.resume(returning: result.map(Optional.some))
            }
        }
    }

    private func performRemoteBatch(
        settings: AppSettings,
        lease: OhMyZshDeploymentLease?
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            Task { @MainActor [weak self] in
                guard let self, let handler = self.remoteApplyHandler else {
                    continuation.resume(returning: .success(()))
                    return
                }
                handler(settings, lease) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func publishLocalResult(_ result: Result<Void, Error>) async {
        await MainActor.run { [weak self] in
            self?.onLocalDeployFinished?(result)
        }
    }

    private func reloadIdleLocalTerminals() async {
        await MainActor.run { [weak self] in
            guard let panes = self?.localTerminalPanesProvider?() else { return }
            panes.forEach { $0.reloadShellSafely() }
        }
    }

    private func shouldRetryWhenResourceBecomesTrusted(_ error: Error) -> Bool {
        guard let resourceError = error as? OhMyZshResourceError else { return false }
        return resourceError == .integrityValidationFailed
            || resourceError == .downloadInProgress
    }

    private func runBlocking(
        _ operation: @escaping () throws -> Void
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            blockingQueue.async {
                continuation.resume(returning: Result { try operation() })
            }
        }
    }

    /// Enqueued behind global settings operations so a connection-time deployment cannot finish
    /// after a newer global configuration and overwrite it.
    public func autoApplyRemoteSession(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        completion: (@MainActor (Result<Void, Error>) -> Void)? = nil
    ) {
        serialExecutor.enqueue { [weak self] in
            guard let self else { return }
            let result = await self.performAutoApplyRemoteSession(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256
            )
            if let completion {
                await MainActor.run { completion(result) }
            }
        }
    }

    private func performAutoApplyRemoteSession(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) async -> Result<Void, Error> {
        let validationSettings = settingsStore.snapshot()
        let leaseResult = await deploymentLeaseIfNeeded(for: validationSettings)
        let lease: OhMyZshDeploymentLease?
        switch leaseResult {
        case let .success(value):
            lease = value
        case let .failure(error):
            return .failure(error)
        }
        defer { lease?.release() }

        // Settings may change while the integrity gate is running. Consume the latest settings,
        // not the values captured before validation.
        let latestSettings = settingsStore.snapshot()
        if latestSettings.ohmyzshEnabled, lease == nil {
            return .failure(OhMyZshResourceError.integrityValidationFailed)
        }
        return await runBlocking { [remoteSessionApplyOperation] in
            try remoteSessionApplyOperation(
                config,
                secret,
                expectedFingerprintSHA256,
                latestSettings,
                lease?.directoryURL
            )
        }
    }
}

private final class OhMyZshAsyncSerialExecutor: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void
    private let lock = NSLock()
    private var operations: [Operation] = []
    private var isDraining = false

    func enqueue(_ operation: @escaping Operation) {
        lock.lock()
        operations.append(operation)
        let shouldStart = isDraining == false
        if shouldStart { isDraining = true }
        lock.unlock()
        guard shouldStart else { return }
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let operation = takeNextOperation() {
            await operation()
        }
    }

    private func takeNextOperation() -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        guard operations.isEmpty == false else {
            isDraining = false
            return nil
        }
        return operations.removeFirst()
    }
}
