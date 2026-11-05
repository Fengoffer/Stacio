import AppKit
import Darwin
import Network
import StacioCoreBindings

private struct RemoteBrowserUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private struct RemoteBrowserProxyConnection {
    let profile: TunnelProfile
    let state: TunnelState
    let endpoint: NWEndpoint
    let statusText: String
}

private struct RemoteBrowserProxyCleanupResource {
    let profile: TunnelProfile
    let state: TunnelState
}

private enum RemoteBrowserStartOutcome {
    case remoteChromium(RemoteChromiumRuntimeSession)
    case socks(RemoteBrowserProxyConnection)
    case failed(String, RemoteBrowserProxyCleanupResource?)
}

public enum RemoteNetworkBrowserMode: Equatable {
    case connecting
    case remoteChromium
    case socksWebKit
    case unavailable
}

public final class RemoteNetworkBrowserViewController: NSViewController {
    public typealias ChromeDevToolsClientFactory = @MainActor (RemoteChromiumRuntimeSession) -> ChromeDevToolsControlling

    public weak var remoteDownloadDelegate: RemoteChromiumDownloadDelegate?

    private let runtimeBridge: TunnelRuntimeBridging
    private let localPortProvider: () -> UInt16
    private let initialURL: URL
    private let startsProxyAsynchronously: Bool
    private let remoteChromiumRuntime: RemoteChromiumRuntimeControlling?
    private let chromeDevToolsClientFactory: ChromeDevToolsClientFactory
    private let lifecycleLog: StacioLogWriting
    private let proxyCleanupRetryDelays: [TimeInterval]
    private var browserPane: BrowserPaneViewController?
    private var remoteChromiumSurface: RemoteChromiumSurfaceViewController?
    private var activeTunnelProfile: TunnelProfile?
    private var activeTunnelState: TunnelState?
    private var activeChromiumSession: RemoteChromiumRuntimeSession?
    private var mostRecentNavigationURL: URL
    private var pendingNavigation: (generation: Int, url: URL)?
    private var pendingProxyStops: [String: RemoteBrowserProxyCleanupResource] = [:]
    private var proxyStopsInFlight: Set<String> = []
    private let browserLifecycleQueue = DispatchQueue(
        label: "com.stacio.remote-browser.lifecycle",
        qos: .userInitiated
    )
    private var proxyStartGeneration = 0
    private var browserMode: RemoteNetworkBrowserMode = .connecting
    private var tunnelStatusText = "等待 SSH 连接。"

    public init(
        runtimeBridge: TunnelRuntimeBridging,
        localPortProvider: @escaping () -> UInt16 = RemoteNetworkBrowserViewController.availableLoopbackPortForInspector,
        initialURL: URL = URL(string: "http://127.0.0.1/")!,
        startsProxyAsynchronously: Bool = true,
        remoteChromiumRuntime: RemoteChromiumRuntimeControlling? = nil,
        lifecycleLog: StacioLogWriting = StacioLogStore.shared,
        proxyCleanupRetryDelays: [TimeInterval] = [0.25, 1, 3],
        chromeDevToolsClientFactory: @escaping ChromeDevToolsClientFactory = { session in
            ChromeDevToolsClient(
                session: session
            )
        }
    ) {
        self.runtimeBridge = runtimeBridge
        self.localPortProvider = localPortProvider
        self.initialURL = initialURL
        self.mostRecentNavigationURL = initialURL
        self.startsProxyAsynchronously = startsProxyAsynchronously
        if let remoteChromiumRuntime {
            self.remoteChromiumRuntime = remoteChromiumRuntime
        } else if startsProxyAsynchronously, runtimeBridge is CoreBridgeTunnelRuntimeBridge {
            self.remoteChromiumRuntime = RemoteChromiumRuntime(tunnelBridge: runtimeBridge)
        } else {
            // Injected tunnel bridges generally represent tests or non-SSH transports.
            self.remoteChromiumRuntime = nil
        }
        self.lifecycleLog = lifecycleLog
        self.proxyCleanupRetryDelays = proxyCleanupRetryDelays.map { max(0, $0) }
        self.chromeDevToolsClientFactory = chromeDevToolsClientFactory
        super.init(nibName: nil, bundle: nil)
        title = L10n.Inspector.browser
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        handOffCleanupForDeinit()
    }

    public override func loadView() {
        guard resetBrowserPaneForReload() else {
            return
        }

        let container = StacioAppearanceRefreshView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)
        view = container
        installInitialPane(in: container)
    }

    public func reloadForCurrentRemoteContext() {
        guard isViewLoaded else { return }
        guard resetBrowserPaneForReload() else {
            return
        }
        installInitialPane(in: view)
    }

    public var browserPaneViewControllerForTesting: BrowserPaneViewController? {
        browserPane
    }

    public var remoteChromiumSurfaceViewControllerForTesting: RemoteChromiumSurfaceViewController? {
        remoteChromiumSurface
    }

    public var browserModeForTesting: RemoteNetworkBrowserMode {
        browserMode
    }

    public var tunnelStatusTextForTesting: String {
        tunnelStatusText
    }

    @discardableResult
    public func stopRemoteBrowserProxy() -> Bool {
        proxyStartGeneration += 1
        pendingNavigation = nil
        if let surface = remoteChromiumSurface {
            surface.onRuntimeFailure = nil
            surface.closeRemoteChromiumSurface()
        }
        if let session = activeChromiumSession {
            activeChromiumSession = nil
            stopChromiumSession(session)
        }

        if let profile = activeTunnelProfile,
           let state = activeTunnelState
        {
            pendingProxyStops[profile.id] = RemoteBrowserProxyCleanupResource(
                profile: profile,
                state: state
            )
            activeTunnelProfile = nil
            activeTunnelState = nil
        }

        if startsProxyAsynchronously {
            schedulePendingProxyStops()
            return true
        }

        var didStopAll = true
        for resource in Array(pendingProxyStops.values) {
            do {
                let status = try stopProxyResource(resource)
                pendingProxyStops.removeValue(forKey: resource.profile.id)
                tunnelStatusText = "远程浏览器代理已停止：\(status.message)"
            } catch {
                didStopAll = false
                reportProxyStopFailure(error, profileID: resource.profile.id)
            }
        }
        return didStopAll
    }

    private func schedulePendingProxyStops() {
        for resource in pendingProxyStops.values
        where proxyStopsInFlight.contains(resource.profile.id) == false
        {
            proxyStopsInFlight.insert(resource.profile.id)
            tunnelStatusText = "正在停止远程浏览器代理..."
            let bridge = RemoteBrowserUncheckedSendable(value: runtimeBridge)
            let log = RemoteBrowserUncheckedSendable(value: lifecycleLog)
            Self.retryProxyCleanup(
                resource: resource,
                bridge: bridge,
                log: log,
                delays: proxyCleanupRetryDelays,
                queue: browserLifecycleQueue
            ) { [weak self] result in
                let resultBox = RemoteBrowserUncheckedSendable(value: result)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.proxyStopsInFlight.remove(resource.profile.id)
                    switch resultBox.value {
                    case let .success(status):
                        self.pendingProxyStops.removeValue(forKey: resource.profile.id)
                        if self.browserMode != .unavailable {
                            self.tunnelStatusText = "远程浏览器代理已停止：\(status.message)"
                        }
                    case let .failure(error):
                        self.reportProxyStopFailure(error, profileID: resource.profile.id)
                    }
                }
            }
        }
    }

    private static func retryProxyCleanup(
        resource: RemoteBrowserProxyCleanupResource,
        bridge: RemoteBrowserUncheckedSendable<TunnelRuntimeBridging>,
        log: RemoteBrowserUncheckedSendable<StacioLogWriting>,
        delays: [TimeInterval],
        queue: DispatchQueue,
        attempt: Int = 0,
        completion: ((Result<TunnelRuntimeStatus, Error>) -> Void)?
    ) {
        queue.async {
            let result = Result {
                let status = try bridge.value.stop(
                    profile: resource.profile,
                    state: resource.state
                )
                guard status.profileId == resource.profile.id,
                      status.state == .stopped
                else {
                    throw RemoteChromiumRuntimeError.tunnelFailed(
                        "cleanup status mismatch: \(status.profileId) \(status.state)"
                    )
                }
                return status
            }
            switch result {
            case .success:
                completion?(result)
            case let .failure(error):
                log.value.append(
                    level: .warning,
                    category: "Browser",
                    message: "remote.browser.proxy.cleanup.failed profile=\(resource.profile.id) attempt=\(attempt + 1) error=\(RuntimeDiagnosticFormatter.userMessage(for: error))"
                )
                guard attempt < delays.count else {
                    log.value.append(
                        level: .warning,
                        category: "Browser",
                        message: "remote.browser.proxy.cleanup.exhausted profile=\(resource.profile.id) attempts=\(attempt + 1)"
                    )
                    completion?(result)
                    return
                }
                queue.asyncAfter(deadline: .now() + delays[attempt]) {
                    retryProxyCleanup(
                        resource: resource,
                        bridge: bridge,
                        log: log,
                        delays: delays,
                        queue: queue,
                        attempt: attempt + 1,
                        completion: completion
                    )
                }
            }
        }
    }

    private func handOffCleanupForDeinit() {
        remoteChromiumSurface?.onRuntimeFailure = nil
        remoteChromiumSurface?.closeRemoteChromiumSurface()
        if let session = activeChromiumSession,
           let remoteChromiumRuntime
        {
            let runtime = RemoteBrowserUncheckedSendable(value: remoteChromiumRuntime)
            browserLifecycleQueue.async {
                runtime.value.stop(session: session)
            }
        }

        var resources = pendingProxyStops
        if let profile = activeTunnelProfile,
           let state = activeTunnelState
        {
            resources[profile.id] = RemoteBrowserProxyCleanupResource(profile: profile, state: state)
        }
        let bridge = RemoteBrowserUncheckedSendable(value: runtimeBridge)
        let log = RemoteBrowserUncheckedSendable(value: lifecycleLog)
        for resource in resources.values where proxyStopsInFlight.contains(resource.profile.id) == false {
            Self.retryProxyCleanup(
                resource: resource,
                bridge: bridge,
                log: log,
                delays: proxyCleanupRetryDelays,
                queue: browserLifecycleQueue,
                completion: nil
            )
        }
    }

    private func stopProxyResource(
        _ resource: RemoteBrowserProxyCleanupResource
    ) throws -> TunnelRuntimeStatus {
        let status = try runtimeBridge.stop(
            profile: resource.profile,
            state: resource.state
        )
        guard status.profileId == resource.profile.id,
              status.state == .stopped
        else {
            throw RemoteChromiumRuntimeError.tunnelFailed(
                "cleanup status mismatch: \(status.profileId) \(status.state)"
            )
        }
        return status
    }

    private func reportProxyStopFailure(_ error: Error, profileID: String) {
        let message = RuntimeDiagnosticFormatter.userMessage(for: error)
        tunnelStatusText = "远程浏览器代理停止失败：\(message)"
        lifecycleLog.append(
            level: .warning,
            category: "Browser",
            message: "remote.browser.proxy.cleanup.failed profile=\(profileID) error=\(message)"
        )
    }

    private func installInitialPane(in container: NSView) {
        let liveSessionContext = runtimeBridge.captureLiveSessionContext()
        let willTryRemoteChromium = remoteChromiumRuntime != nil && liveSessionContext != nil
        browserMode = .connecting
        tunnelStatusText = willTryRemoteChromium
            ? "正在启动远端 Chromium..."
            : "正在建立 SSH 远端浏览通道..."
        installWaitingBrowserPane(in: container, message: tunnelStatusText)

        let generation = proxyStartGeneration
        let localPort = localPortProvider()
        if startsProxyAsynchronously {
            startPreferredBrowserInBackground(
                localPort: localPort,
                generation: generation,
                liveSessionContext: liveSessionContext
            )
        } else {
            applyStartOutcome(
                Self.startPreferredBrowser(
                    runtimeBridge: runtimeBridge,
                    remoteChromiumRuntime: remoteChromiumRuntime,
                    localPort: localPort,
                    liveSessionContext: liveSessionContext
                ),
                generation: generation
            )
        }
    }

    private func installWaitingBrowserPane(in container: NSView, message: String) {
        let generation = proxyStartGeneration
        let browser = BrowserPaneViewController(
            runtimeID: "inspector_remote_browser",
            url: initialURL,
            title: L10n.Inspector.browser,
            loadsInitialRequest: false,
            initialStatusText: message
        )
        browser.onRetryRequested = { [weak self] in
            self?.reloadForCurrentRemoteContext()
        }
        browser.onPageTitleChange = { [weak self] title in
            self?.title = title
        }
        browser.onDeferredNavigationRequested = { [weak self] url in
            guard let self,
                  generation == self.proxyStartGeneration,
                  self.browserMode == .connecting
            else {
                return
            }
            self.pendingNavigation = (generation, url)
        }
        addChild(browser)
        browserPane = browser
        installChildView(browser.view, in: container)
    }

    private func startPreferredBrowserInBackground(
        localPort: UInt16,
        generation: Int,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        let bridge = RemoteBrowserUncheckedSendable(value: runtimeBridge)
        let remoteRuntime = RemoteBrowserUncheckedSendable(value: remoteChromiumRuntime)
        let log = RemoteBrowserUncheckedSendable(value: lifecycleLog)
        let retryDelays = proxyCleanupRetryDelays
        let lifecycleQueue = browserLifecycleQueue
        lifecycleQueue.async { [weak self] in
            let outcome = Self.startPreferredBrowser(
                runtimeBridge: bridge.value,
                remoteChromiumRuntime: remoteRuntime.value,
                localPort: localPort,
                liveSessionContext: liveSessionContext
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    lifecycleQueue.async {
                        Self.stopOutcomeIfNeeded(
                            outcome,
                            runtimeBridge: bridge.value,
                            remoteChromiumRuntime: remoteRuntime.value,
                            lifecycleLog: log.value,
                            retryDelays: retryDelays,
                            queue: lifecycleQueue
                        )
                    }
                    return
                }
                self.applyStartOutcome(outcome, generation: generation)
            }
        }
    }

    private func applyStartOutcome(_ outcome: RemoteBrowserStartOutcome, generation: Int) {
        guard generation == proxyStartGeneration else {
            stopOutcome(outcome)
            return
        }

        switch outcome {
        case let .remoteChromium(session):
            let navigationURL = consumePendingNavigation(for: generation)
            activeChromiumSession = session
            browserMode = .remoteChromium
            tunnelStatusText = "远端 Chromium 已连接：127.0.0.1:\(session.localDebugPort)"
            replaceWithRemoteChromiumSurface(session, initialURL: navigationURL)
        case let .socks(connection):
            let navigationURL = consumePendingNavigation(for: generation)
            activeTunnelProfile = connection.profile
            activeTunnelState = connection.state
            browserMode = .socksWebKit
            tunnelStatusText = connection.statusText
            replaceBrowserPaneUsingProxy(connection.endpoint, initialURL: navigationURL)
        case let .failed(message, residualCleanup):
            if let residualCleanup {
                pendingProxyStops[residualCleanup.profile.id] = residualCleanup
                lifecycleLog.append(
                    level: .warning,
                    category: "Browser",
                    message: "remote.browser.proxy.start.cleanup.pending profile=\(residualCleanup.profile.id)"
                )
                if startsProxyAsynchronously {
                    schedulePendingProxyStops()
                }
            }
            browserMode = .unavailable
            let visibleMessage = residualCleanup == nil ? message : "\(message)；代理清理待重试"
            tunnelStatusText = visibleMessage
            if let browserPane {
                browserPane.showLoadErrorMessage(visibleMessage)
            } else {
                replaceWithErrorPane(visibleMessage)
            }
        }
    }

    private func consumePendingNavigation(for generation: Int) -> URL {
        guard pendingNavigation?.generation == generation else {
            return initialURL
        }
        let url = pendingNavigation?.url ?? initialURL
        pendingNavigation = nil
        return url
    }

    private func replaceWithRemoteChromiumSurface(
        _ session: RemoteChromiumRuntimeSession,
        initialURL: URL
    ) {
        let container = currentContentSuperview()
        removeCurrentContent()
        mostRecentNavigationURL = initialURL
        let client = chromeDevToolsClientFactory(session)
        let surface = RemoteChromiumSurfaceViewController(initialURL: initialURL, client: client)
        surface.remoteDownloadDelegate = self
        surface.onRuntimeFailure = { [weak self] error in
            self?.handleRemoteChromiumFailure(error)
        }
        surface.onNavigationURLChange = { [weak self] url in
            self?.mostRecentNavigationURL = url
        }
        surface.onPageTitleChange = { [weak self] title in
            self?.title = title
        }
        addChild(surface)
        remoteChromiumSurface = surface
        installChildView(surface.view, in: container)
    }

    private func replaceBrowserPaneUsingProxy(
        _ proxyEndpoint: NWEndpoint,
        initialURL: URL
    ) {
        let container = currentContentSuperview()
        removeCurrentContent()
        let browser = BrowserPaneViewController(
            runtimeID: "inspector_remote_browser",
            url: initialURL,
            title: L10n.Inspector.browser,
            socksProxyEndpoint: proxyEndpoint,
            loadsInitialRequest: true,
            initialStatusText: tunnelStatusText,
            modeLabel: "SSH 代理"
        )
        browser.onRetryRequested = { [weak self] in
            self?.reloadForCurrentRemoteContext()
        }
        browser.onPageTitleChange = { [weak self] title in
            self?.title = title
        }
        addChild(browser)
        browserPane = browser
        installChildView(browser.view, in: container)
        container.layoutSubtreeIfNeeded()
        browser.webView.needsDisplay = true
    }

    private func replaceWithErrorPane(_ message: String) {
        let container = currentContentSuperview()
        removeCurrentContent()
        installWaitingBrowserPane(in: container, message: message)
        browserPane?.showLoadErrorMessage(message)
    }

    private func handleRemoteChromiumFailure(_ error: Error) {
        guard browserMode == .remoteChromium else { return }
        let generation = proxyStartGeneration
        pendingNavigation = (generation, mostRecentNavigationURL)
        let failedSurface = remoteChromiumSurface
        failedSurface?.onRuntimeFailure = nil
        failedSurface?.closeRemoteChromiumSurface()
        if let session = activeChromiumSession {
            activeChromiumSession = nil
            stopChromiumSession(session)
        }
        let container = currentContentSuperview()
        removeCurrentContent()
        browserMode = .connecting
        tunnelStatusText = "远端 Chromium 连接中断，正在回退 SSH 代理：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
        installWaitingBrowserPane(in: container, message: tunnelStatusText)

        let localPort = localPortProvider()
        let context = runtimeBridge.captureLiveSessionContext()
        if startsProxyAsynchronously {
            startSOCKSFallbackInBackground(
                localPort: localPort,
                generation: generation,
                liveSessionContext: context
            )
        } else {
            applyStartOutcome(
                Self.startRemoteBrowserProxy(
                    runtimeBridge: runtimeBridge,
                    localPort: localPort,
                    liveSessionContext: context,
                    fallbackReason: tunnelStatusText
                ),
                generation: generation
            )
        }
    }

    private func startSOCKSFallbackInBackground(
        localPort: UInt16,
        generation: Int,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        let bridge = RemoteBrowserUncheckedSendable(value: runtimeBridge)
        let log = RemoteBrowserUncheckedSendable(value: lifecycleLog)
        let retryDelays = proxyCleanupRetryDelays
        let fallbackReason = tunnelStatusText
        let lifecycleQueue = browserLifecycleQueue
        lifecycleQueue.async { [weak self] in
            let outcome = Self.startRemoteBrowserProxy(
                runtimeBridge: bridge.value,
                localPort: localPort,
                liveSessionContext: liveSessionContext,
                fallbackReason: fallbackReason
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    lifecycleQueue.async {
                        Self.stopOutcomeIfNeeded(
                            outcome,
                            runtimeBridge: bridge.value,
                            remoteChromiumRuntime: nil,
                            lifecycleLog: log.value,
                            retryDelays: retryDelays,
                            queue: lifecycleQueue
                        )
                    }
                    return
                }
                self.applyStartOutcome(outcome, generation: generation)
            }
        }
    }

    private func resetBrowserPaneForReload() -> Bool {
        guard stopRemoteBrowserProxy() else {
            browserPane?.showLoadErrorMessage(tunnelStatusText)
            return false
        }
        removeCurrentContent()
        browserMode = .connecting
        return true
    }

    private func currentContentSuperview() -> NSView {
        remoteChromiumSurface?.view.superview ?? browserPane?.view.superview ?? view
    }

    private func removeCurrentContent() {
        if let surface = remoteChromiumSurface {
            surface.onRuntimeFailure = nil
            surface.closeRemoteChromiumSurface()
            surface.view.removeFromSuperview()
            surface.removeFromParent()
            remoteChromiumSurface = nil
        }
        if let browser = browserPane {
            browser.view.removeFromSuperview()
            browser.closeBrowserPane()
            browser.removeFromParent()
            browserPane = nil
        }
    }

    private func installChildView(_ childView: NSView, in container: NSView) {
        container.addSubview(childView)
        childView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            childView.topAnchor.constraint(equalTo: container.topAnchor),
            childView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private static func startPreferredBrowser(
        runtimeBridge: TunnelRuntimeBridging,
        remoteChromiumRuntime: RemoteChromiumRuntimeControlling?,
        localPort: UInt16,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteBrowserStartOutcome {
        if let remoteChromiumRuntime, let liveSessionContext {
            do {
                return .remoteChromium(
                    try remoteChromiumRuntime.start(
                        context: liveSessionContext,
                        localPort: localPort
                    )
                )
            } catch {
                let reason = "远端 Chromium 不可用，已回退 SSH 代理：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
                return startRemoteBrowserProxy(
                    runtimeBridge: runtimeBridge,
                    localPort: localPort,
                    liveSessionContext: liveSessionContext,
                    fallbackReason: reason
                )
            }
        }
        return startRemoteBrowserProxy(
            runtimeBridge: runtimeBridge,
            localPort: localPort,
            liveSessionContext: liveSessionContext,
            fallbackReason: nil
        )
    }

    private static func startRemoteBrowserProxy(
        runtimeBridge: TunnelRuntimeBridging,
        localPort: UInt16,
        liveSessionContext: TunnelLiveSessionContext?,
        fallbackReason: String?
    ) -> RemoteBrowserStartOutcome {
        let profile = TunnelProfile(
            id: "remote_browser_\(localPort)_\(UUID().uuidString.lowercased())",
            kind: .dynamic,
            localHost: "127.0.0.1",
            localPort: localPort,
            remoteHost: "socks",
            remotePort: localPort
        )
        var startedState: TunnelState? = .starting
        do {
            let status = try runtimeBridge.start(
                profile: profile,
                liveSessionContext: liveSessionContext
            )
            startedState = status.state
            guard status.profileId == profile.id else {
                let residual = stopStartedProxyIfNeeded(
                    runtimeBridge: runtimeBridge,
                    profile: profile,
                    state: status.state
                )
                return .failed("远程浏览器代理状态不匹配：\(status.profileId)", residual)
            }

            var readyStatus = status
            if readyStatus.state == .starting {
                for _ in 0..<40 where readyStatus.state == .starting {
                    Thread.sleep(forTimeInterval: 0.05)
                    readyStatus = try runtimeBridge.poll(profileID: profile.id)
                    startedState = readyStatus.state
                }
            }
            guard readyStatus.profileId == profile.id else {
                let residual = stopStartedProxyIfNeeded(
                    runtimeBridge: runtimeBridge,
                    profile: profile,
                    state: startedState
                )
                return .failed("远程浏览器代理状态不匹配：\(readyStatus.profileId)", residual)
            }
            guard readyStatus.state == .running else {
                let residual = stopStartedProxyIfNeeded(
                    runtimeBridge: runtimeBridge,
                    profile: profile,
                    state: readyStatus.state
                )
                return .failed("远程浏览器代理未运行：\(readyStatus.message)", residual)
            }
            guard let port = NWEndpoint.Port(rawValue: localPort),
                  let loopback = IPv4Address("127.0.0.1")
            else {
                let residual = stopStartedProxyIfNeeded(
                    runtimeBridge: runtimeBridge,
                    profile: profile,
                    state: readyStatus.state
                )
                return .failed("远程浏览器代理端口无效", residual)
            }
            let statusText = fallbackReason.map { "\($0)；127.0.0.1:\(localPort)" }
                ?? "SSH 远端浏览通道已连接：127.0.0.1:\(localPort)"
            return .socks(
                RemoteBrowserProxyConnection(
                    profile: profile,
                    state: readyStatus.state,
                    endpoint: .hostPort(host: .ipv4(loopback), port: port),
                    statusText: statusText
                )
            )
        } catch {
            let residual = stopStartedProxyIfNeeded(
                runtimeBridge: runtimeBridge,
                profile: profile,
                state: startedState
            )
            let prefix = fallbackReason.map { "\($0)；" } ?? ""
            return .failed(
                "\(prefix)远程浏览器代理启动失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))",
                residual
            )
        }
    }

    private static func stopStartedProxyIfNeeded(
        runtimeBridge: TunnelRuntimeBridging,
        profile: TunnelProfile,
        state: TunnelState?
    ) -> RemoteBrowserProxyCleanupResource? {
        guard let state, state == .starting || state == .running else {
            return nil
        }
        do {
            let status = try runtimeBridge.stop(profile: profile, state: state)
            guard status.profileId == profile.id, status.state == .stopped else {
                return RemoteBrowserProxyCleanupResource(profile: profile, state: state)
            }
            return nil
        } catch {
            return RemoteBrowserProxyCleanupResource(profile: profile, state: state)
        }
    }

    private static func stopOutcomeIfNeeded(
        _ outcome: RemoteBrowserStartOutcome,
        runtimeBridge: TunnelRuntimeBridging,
        remoteChromiumRuntime: RemoteChromiumRuntimeControlling?,
        lifecycleLog: StacioLogWriting,
        retryDelays: [TimeInterval],
        queue: DispatchQueue
    ) {
        switch outcome {
        case let .remoteChromium(session):
            remoteChromiumRuntime?.stop(session: session)
        case let .socks(connection):
            retryProxyCleanup(
                resource: RemoteBrowserProxyCleanupResource(
                    profile: connection.profile,
                    state: connection.state
                ),
                bridge: RemoteBrowserUncheckedSendable(value: runtimeBridge),
                log: RemoteBrowserUncheckedSendable(value: lifecycleLog),
                delays: retryDelays,
                queue: queue,
                completion: nil
            )
        case let .failed(_, residualCleanup):
            if let residualCleanup {
                retryProxyCleanup(
                    resource: residualCleanup,
                    bridge: RemoteBrowserUncheckedSendable(value: runtimeBridge),
                    log: RemoteBrowserUncheckedSendable(value: lifecycleLog),
                    delays: retryDelays,
                    queue: queue,
                    completion: nil
                )
            }
        }
    }

    private func stopChromiumSession(_ session: RemoteChromiumRuntimeSession) {
        guard let remoteChromiumRuntime else { return }
        if startsProxyAsynchronously {
            let runtime = RemoteBrowserUncheckedSendable(value: remoteChromiumRuntime)
            browserLifecycleQueue.async {
                runtime.value.stop(session: session)
            }
        } else {
            remoteChromiumRuntime.stop(session: session)
        }
    }

    private func stopOutcome(_ outcome: RemoteBrowserStartOutcome) {
        switch outcome {
        case let .remoteChromium(session):
            stopChromiumSession(session)
        case let .socks(connection):
            pendingProxyStops[connection.profile.id] = RemoteBrowserProxyCleanupResource(
                profile: connection.profile,
                state: connection.state
            )
        case let .failed(_, residualCleanup):
            if let residualCleanup {
                pendingProxyStops[residualCleanup.profile.id] = residualCleanup
            }
        }
        if startsProxyAsynchronously {
            schedulePendingProxyStops()
        } else {
            for resource in Array(pendingProxyStops.values) {
                do {
                    _ = try stopProxyResource(resource)
                    pendingProxyStops.removeValue(forKey: resource.profile.id)
                } catch {
                    reportProxyStopFailure(error, profileID: resource.profile.id)
                }
            }
        }
    }

    public static func availableLoopbackPortForInspector() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return 18_080
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            return 18_080
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            return 18_080
        }
        return UInt16(bigEndian: address.sin_port)
    }
}

extension RemoteNetworkBrowserViewController: RemoteChromiumDownloadDelegate {
    public func remoteChromiumDidCompleteDownload(_ download: RemoteChromiumDownload) {
        guard let session = activeChromiumSession,
              download.isCanonical(for: session),
              let remoteChromiumRuntime,
              remoteDownloadDelegate != nil,
              remoteChromiumRuntime.retainDownload(download)
        else {
            return
        }
        remoteDownloadDelegate?.remoteChromiumDidCompleteDownload(download)
    }

    @discardableResult
    public func acknowledgeRemoteChromiumDownload(
        _ download: RemoteChromiumDownload,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool {
        remoteChromiumRuntime?.acknowledgeDownload(download, completion: completion) ?? false
    }
}
