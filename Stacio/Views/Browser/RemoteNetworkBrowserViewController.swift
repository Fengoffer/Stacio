import AppKit
import Darwin
import Network
import StacioCoreBindings

public final class RemoteNetworkBrowserViewController: NSViewController {
    private let runtimeBridge: TunnelRuntimeBridging
    private let localPortProvider: () -> UInt16
    private let initialURL: URL
    private var browserPane: BrowserPaneViewController?
    private var activeTunnelProfile: TunnelProfile?
    private var activeTunnelState: TunnelState?
    private var tunnelStatusText = "等待 SSH 连接。"

    public init(
        runtimeBridge: TunnelRuntimeBridging,
        localPortProvider: @escaping () -> UInt16 = RemoteNetworkBrowserViewController.availableLoopbackPortForInspector,
        initialURL: URL = URL(string: "http://127.0.0.1/")!
    ) {
        self.runtimeBridge = runtimeBridge
        self.localPortProvider = localPortProvider
        self.initialURL = initialURL
        super.init(nibName: nil, bundle: nil)
        title = L10n.Inspector.browser
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        stopRemoteBrowserProxy()
    }

    public override func loadView() {
        resetBrowserPaneForReload()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)

        installBrowserPane(in: container)
        view = container
    }

    public func reloadForCurrentRemoteContext() {
        guard isViewLoaded else { return }
        resetBrowserPaneForReload()
        installBrowserPane(in: view)
    }

    private func installBrowserPane(in container: NSView) {
        let proxyEndpoint = startRemoteBrowserProxy()
        let browser = BrowserPaneViewController(
            runtimeID: "inspector_remote_browser",
            url: initialURL,
            title: L10n.Inspector.browser,
            socksProxyEndpoint: proxyEndpoint,
            loadsInitialRequest: proxyEndpoint != nil
        )
        addChild(browser)
        browserPane = browser

        container.addSubview(browser.view)
        if proxyEndpoint == nil {
            browser.showLoadErrorMessage(tunnelStatusText)
        }
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            browser.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            browser.view.topAnchor.constraint(equalTo: container.topAnchor),
            browser.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    public var browserPaneViewControllerForTesting: BrowserPaneViewController? {
        browserPane
    }

    public var tunnelStatusTextForTesting: String {
        tunnelStatusText
    }

    public func stopRemoteBrowserProxy() {
        guard let profile = activeTunnelProfile,
              let state = activeTunnelState
        else {
            return
        }

        do {
            let status = try runtimeBridge.stop(profile: profile, state: state)
            guard status.profileId == profile.id else {
                tunnelStatusText = "远程浏览器代理停止状态不匹配：\(status.profileId)"
                return
            }
            activeTunnelProfile = nil
            activeTunnelState = nil
            tunnelStatusText = "远程浏览器代理已停止：\(status.message)"
        } catch {
            tunnelStatusText = "远程浏览器代理停止失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
        }
    }

    private func resetBrowserPaneForReload() {
        browserPane?.view.removeFromSuperview()
        browserPane?.closeBrowserPane()
        browserPane?.removeFromParent()
        browserPane = nil
        stopRemoteBrowserProxy()
    }

    private func startRemoteBrowserProxy() -> NWEndpoint? {
        let localPort = localPortProvider()
        let profile = TunnelProfile(
            id: "remote_browser_\(localPort)",
            kind: .dynamic,
            localHost: "127.0.0.1",
            localPort: localPort,
            remoteHost: "socks",
            remotePort: localPort
        )
        do {
            let status = try runtimeBridge.start(profile: profile)
            guard status.profileId == profile.id else {
                tunnelStatusText = "远程浏览器代理状态不匹配：\(status.profileId)"
                return nil
            }
            if status.state == .running || status.state == .starting {
                activeTunnelProfile = profile
                activeTunnelState = status.state
            }
            guard status.state == .running else {
                tunnelStatusText = "远程浏览器代理未运行：\(status.message)"
                return nil
            }
            tunnelStatusText = "远程浏览器代理已连接：127.0.0.1:\(localPort)"
            guard let port = NWEndpoint.Port(rawValue: localPort),
                  let loopback = IPv4Address("127.0.0.1")
            else {
                return nil
            }
            return .hostPort(host: .ipv4(loopback), port: port)
        } catch {
            tunnelStatusText = "远程浏览器代理启动失败：\(RuntimeDiagnosticFormatter.userMessage(for: error))"
            return nil
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
