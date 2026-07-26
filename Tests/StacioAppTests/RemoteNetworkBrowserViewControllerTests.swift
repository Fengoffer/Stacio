import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class RemoteNetworkBrowserViewControllerTests: XCTestCase {
    func testConnectingPaneQueuesLatestAddressWithoutLocalNavigationAndRunsItAfterCDPReady() async throws {
        let startEntered = expectation(description: "Chromium start entered")
        let stopCalled = expectation(description: "Chromium stop called")
        let chromiumRuntime = BlockingRemoteChromiumRuntime(
            session: Self.chromiumSession,
            startEntered: startEntered,
            stopCalled: stopCalled
        )
        let client = RecordingChromeDevToolsClient()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: RecordingRemoteBrowserTunnelBridge(context: Self.liveContext),
            localPortProvider: { 19_090 },
            initialURL: URL(string: "http://initial.internal")!,
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        controller.view.layoutSubtreeIfNeeded()
        await fulfillment(of: [startEntered], timeout: 1)

        let waitingPane = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        waitingPane.loadAddressForTesting("http://first.internal")
        waitingPane.loadAddressForTesting("http://latest.internal")

        XCTAssertNil(waitingPane.webView.url, "The unproxied waiting WKWebView must never navigate.")

        chromiumRuntime.releaseStart()
        let didInstallRemoteSurface = await waitUntil {
            controller.remoteChromiumSurfaceViewControllerForTesting != nil
        }
        XCTAssertTrue(didInstallRemoteSurface)
        controller.view.layoutSubtreeIfNeeded()
        client.emit(.connected)

        let navigations = client.commands.filter { $0.0 == "Page.navigate" }
        XCTAssertEqual(navigations.count, 1)
        XCTAssertEqual(navigations.first?.1["url"] as? String, "http://latest.internal")
        XCTAssertTrue(controller.stopRemoteBrowserProxy())
        await fulfillment(of: [stopCalled], timeout: 1)
    }

    func testStopInvalidatesInFlightRemoteChromiumStart() async {
        let startEntered = expectation(description: "Chromium start entered")
        let staleSessionStopped = expectation(description: "stale Chromium session stopped")
        let chromiumRuntime = BlockingRemoteChromiumRuntime(
            session: Self.chromiumSession,
            startEntered: startEntered,
            stopCalled: staleSessionStopped
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: RecordingRemoteBrowserTunnelBridge(context: Self.liveContext),
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: chromiumRuntime
        )

        controller.loadView()
        await fulfillment(of: [startEntered], timeout: 1)

        XCTAssertTrue(controller.stopRemoteBrowserProxy())
        chromiumRuntime.releaseStart()

        await fulfillment(of: [staleSessionStopped], timeout: 1)
        XCTAssertEqual(chromiumRuntime.stoppedSessions, [Self.chromiumSession])
        XCTAssertNil(controller.remoteChromiumSurfaceViewControllerForTesting)
        XCTAssertNotEqual(controller.browserModeForTesting, .remoteChromium)
    }

    func testStopInvalidatesInFlightSOCKSStart() async {
        let startEntered = expectation(description: "SOCKS start entered")
        let staleTunnelStopped = expectation(description: "stale SOCKS tunnel stopped")
        let tunnelBridge = BlockingRemoteBrowserTunnelBridge(
            context: Self.liveContext,
            startEntered: startEntered,
            stopCalled: staleTunnelStopped
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: nil
        )

        controller.loadView()
        await fulfillment(of: [startEntered], timeout: 1)

        XCTAssertTrue(controller.stopRemoteBrowserProxy())
        tunnelBridge.releaseStart()

        await fulfillment(of: [staleTunnelStopped], timeout: 1)
        XCTAssertEqual(tunnelBridge.stoppedProfiles.count, 1)
        XCTAssertTrue(
            tunnelBridge.stoppedProfiles.first?.id.hasPrefix("remote_browser_19090_") == true
        )
        XCTAssertEqual(tunnelBridge.stoppedProfiles.first?.localPort, 19_090)
        XCTAssertNotEqual(controller.browserModeForTesting, .socksWebKit)
        XCTAssertEqual(controller.browserPaneViewControllerForTesting?.proxyConfigurationCountForTesting, 0)
    }

    func testLateSOCKSOutcomeAfterControllerDeallocationRetriesStop() async {
        let startEntered = expectation(description: "SOCKS start entered")
        let firstStop = expectation(description: "late SOCKS stop failed")
        let retryStop = expectation(description: "late SOCKS stop retried")
        let bridge = BlockingStartRetryingStopRemoteBrowserTunnelBridge(
            context: Self.liveContext,
            startEntered: startEntered,
            stopResults: [
                .failure(TestRemoteBrowserError.failed),
                .success(TunnelRuntimeStatus(profileId: "", state: .stopped, message: "stopped"))
            ],
            stopExpectations: [firstStop, retryStop]
        )
        var controller: RemoteNetworkBrowserViewController? = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: nil,
            proxyCleanupRetryDelays: [0.01]
        )

        controller?.loadView()
        await fulfillment(of: [startEntered], timeout: 1)
        controller = nil
        bridge.releaseStart()

        await fulfillment(of: [firstStop, retryStop], timeout: 1)
        XCTAssertEqual(bridge.stoppedProfiles.count, 2)
    }

    func testPrefersRemoteChromiumAndDoesNotStartSOCKSWhenChromiumIsAvailable() throws {
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .success(Self.chromiumSession))
        let client = RecordingChromeDevToolsClient()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            initialURL: URL(string: "http://app.internal")!,
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )

        controller.loadView()

        XCTAssertEqual(controller.browserModeForTesting, .remoteChromium)
        XCTAssertNotNil(controller.remoteChromiumSurfaceViewControllerForTesting)
        XCTAssertNil(controller.browserPaneViewControllerForTesting)
        XCTAssertEqual(chromiumRuntime.startedPorts, [19_090])
        XCTAssertEqual(tunnelBridge.startedProfiles, [])
        let mode = try XCTUnwrap(
            remoteBrowserSubview(in: controller.view, identifier: "Stacio.RemoteBrowser.mode") as? NSTextField
        )
        XCTAssertEqual(mode.stringValue, "远端 Chromium")
    }

    func testChromiumStartupFailureFallsBackToSOCKSWithoutChangingTabs() throws {
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .failure(TestRemoteBrowserError.failed))
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            initialURL: URL(string: "http://app.internal")!,
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: chromiumRuntime
        )

        controller.loadView()

        XCTAssertEqual(controller.browserModeForTesting, .socksWebKit)
        XCTAssertNil(controller.remoteChromiumSurfaceViewControllerForTesting)
        let browserPane = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        XCTAssertEqual(browserPane.proxyConfigurationCountForTesting, 1)
        XCTAssertEqual(tunnelBridge.startedProfiles.map(\.kind), [.dynamic])
        XCTAssertEqual(
            remoteBrowserSubview(in: controller.view, identifier: "Stacio.Browser.mode")
                .flatMap { ($0 as? NSTextField)?.stringValue },
            "SSH 代理"
        )
    }

    func testCDPLifecycleFailureStopsChromiumAndFallsBackToSOCKSInPlace() throws {
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .success(Self.chromiumSession))
        let client = RecordingChromeDevToolsClient()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            initialURL: URL(string: "http://app.internal")!,
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )
        controller.loadView()

        client.fail(TestRemoteBrowserError.failed)

        XCTAssertEqual(controller.browserModeForTesting, .socksWebKit)
        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertEqual(chromiumRuntime.stoppedSessions, [Self.chromiumSession])
        XCTAssertNotNil(controller.browserPaneViewControllerForTesting)
        XCTAssertEqual(tunnelBridge.startedProfiles.map(\.kind), [.dynamic])
    }

    func testCDPFailureFallsBackToSOCKSAtMostRecentRemoteNavigationURL() throws {
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .success(Self.chromiumSession))
        let client = RecordingChromeDevToolsClient()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            initialURL: URL(string: "http://initial.internal")!,
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )
        controller.loadView()
        client.emit(.frameNavigated(url: "http://latest.internal/dashboard"))

        client.fail(TestRemoteBrowserError.failed)

        let browserPane = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        XCTAssertEqual(browserPane.currentURLStringForTesting, "http://latest.internal/dashboard")
    }

    func testCDPFailureKeepsAddressInputAvailableUntilAsyncSOCKSFallbackCompletes() async throws {
        let startEntered = expectation(description: "fallback SOCKS start entered")
        let stopCalled = expectation(description: "fallback SOCKS stopped")
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .success(Self.chromiumSession))
        let bridge = BlockingRemoteBrowserTunnelBridge(
            context: Self.liveContext,
            startEntered: startEntered,
            stopCalled: stopCalled
        )
        let client = RecordingChromeDevToolsClient()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: bridge,
            localPortProvider: { 19_090 },
            initialURL: URL(string: "http://initial.internal")!,
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )
        controller.loadView()
        let didInstallRemoteSurface = await waitUntil {
            controller.remoteChromiumSurfaceViewControllerForTesting != nil
        }
        XCTAssertTrue(didInstallRemoteSurface)

        client.fail(TestRemoteBrowserError.failed)
        await fulfillment(of: [startEntered], timeout: 1)

        let waitingPane = try XCTUnwrap(controller.browserPaneViewControllerForTesting)
        waitingPane.loadAddressForTesting("http://typed-during-fallback.internal/dashboard")
        XCTAssertNil(waitingPane.webView.url)

        bridge.releaseStart()
        let didInstallProxy = await waitUntil {
            controller.browserModeForTesting == .socksWebKit
        }
        XCTAssertTrue(didInstallProxy)
        XCTAssertEqual(
            controller.browserPaneViewControllerForTesting?.currentURLStringForTesting,
            "http://typed-during-fallback.internal/dashboard"
        )
        XCTAssertTrue(controller.stopRemoteBrowserProxy())
        await fulfillment(of: [stopCalled], timeout: 1)
    }

    func testCompletedRemoteDownloadIsExposedThroughDelegateWithoutFilesCoordinator() async {
        let acknowledged = expectation(description: "download acknowledged")
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .success(Self.chromiumSession))
        let client = RecordingChromeDevToolsClient()
        let delegate = RecordingRemoteChromiumDownloadDelegate()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )
        controller.remoteDownloadDelegate = delegate
        controller.loadView()

        client.completeDownload(
            RemoteChromiumDownload(
                session: Self.chromiumSession,
                remotePath: "/tmp/stacio-chromium.AbC123/downloads/guid-1",
                suggestedFilename: "report.pdf"
            )
        )

        XCTAssertEqual(
            delegate.completedDownloads,
            [
                RemoteChromiumDownload(
                    session: Self.chromiumSession,
                    remotePath: "/tmp/stacio-chromium.AbC123/downloads/guid-1",
                    suggestedFilename: "report.pdf"
                )
            ]
        )
        XCTAssertEqual(chromiumRuntime.retainedDownloads, delegate.completedDownloads)
        XCTAssertTrue(
            controller.acknowledgeRemoteChromiumDownload(delegate.completedDownloads[0]) { result in
                if case let .failure(error) = result {
                    XCTFail("Acknowledgement failed: \(error)")
                }
                acknowledged.fulfill()
            }
        )
        await fulfillment(of: [acknowledged], timeout: 1)
        XCTAssertEqual(chromiumRuntime.acknowledgedDownloads, delegate.completedDownloads)
    }

    func testCompletedDownloadIsRetainedBeforeImmediateReloadStopsItsSession() {
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let chromiumRuntime = RecordingRemoteChromiumRuntime(result: .success(Self.chromiumSession))
        let client = RecordingChromeDevToolsClient()
        let delegate = RecordingRemoteChromiumDownloadDelegate()
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: chromiumRuntime,
            chromeDevToolsClientFactory: { _ in client }
        )
        controller.remoteDownloadDelegate = delegate
        controller.loadView()
        let download = RemoteChromiumDownload(
            session: Self.chromiumSession,
            remotePath: Self.chromiumSession.remoteDownloadsDirectory + "/guid-1",
            suggestedFilename: "report.pdf"
        )

        client.completeDownload(download)
        controller.reloadForCurrentRemoteContext()

        XCTAssertEqual(delegate.completedDownloads, [download])
        XCTAssertEqual(chromiumRuntime.lifecycleEvents.prefix(2), ["retain", "stop"])
    }

    func testRemoteChromiumSurfaceNavigatesThroughCDPAndKeepsSpinnerAfterAddress() throws {
        let client = RecordingChromeDevToolsClient()
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client
        )
        surface.loadView()
        surface.view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        surface.view.layoutSubtreeIfNeeded()

        client.emit(.connected)

        let navigate = try XCTUnwrap(client.commands.last)
        XCTAssertEqual(navigate.0, "Page.navigate")
        XCTAssertEqual(navigate.1["url"] as? String, "http://app.internal")
        let address = try XCTUnwrap(
            remoteBrowserSubview(in: surface.view, identifier: "Stacio.RemoteBrowser.address") as? NSTextField
        )
        let indicator = try XCTUnwrap(
            remoteBrowserSubview(
                in: surface.view,
                identifier: "Stacio.RemoteBrowser.statusIndicator"
            ) as? NSProgressIndicator
        )
        let addressFrame = address.convert(address.bounds, to: surface.view)
        let indicatorFrame = indicator.convert(indicator.bounds, to: surface.view)
        XCTAssertGreaterThanOrEqual(indicatorFrame.minX, addressFrame.maxX)
        XCTAssertLessThanOrEqual(indicatorFrame.minX - addressFrame.maxX, 8)
        XCTAssertEqual(addressFrame.height, 28, accuracy: 0.1)

        let mode = try XCTUnwrap(
            remoteBrowserSubview(in: surface.view, identifier: "Stacio.RemoteBrowser.mode") as? NSTextField
        )
        let modeFrame = mode.convert(mode.bounds, to: surface.view)
        XCTAssertTrue(mode is RemoteBrowserModeLabel)
        XCTAssertLessThan(mode.frame.width, 160)
        XCTAssertNil(mode.layer?.backgroundColor)

        let toolbar = try XCTUnwrap(
            remoteBrowserSubview(in: surface.view, identifier: "Stacio.RemoteBrowser.toolbar")
        )
        let toolbarButtons = remoteBrowserSubviews(in: toolbar)
            .compactMap { $0 as? NSButton }
            .filter { ["后退", "前进", "重新载入", L10n.Browser.go].contains($0.toolTip ?? "") }
        XCTAssertEqual(toolbarButtons.count, 4)
        for button in toolbarButtons {
            XCTAssertEqual(button.frame.width, 28, accuracy: 0.1)
            XCTAssertEqual(button.frame.height, 28, accuracy: 0.1)
        }
        XCTAssertEqual(toolbar.frame.height, 36, accuracy: 0.1)
        XCTAssertEqual(modeFrame.midY, addressFrame.midY, accuracy: 0.1)
    }

    func testRemoteChromiumSurfaceShowsRetryableNavigationFailure() throws {
        let client = RecordingChromeDevToolsClient()
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client
        )
        surface.loadView()
        surface.view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        surface.view.layoutSubtreeIfNeeded()
        client.emit(.connected)

        client.emit(.navigationFailed(errorText: "net::ERR_CONNECTION_REFUSED"))

        let waiting = try XCTUnwrap(
            remoteBrowserSubview(in: surface.view, identifier: "Stacio.RemoteBrowser.waiting") as? NSTextField
        )
        let indicator = try XCTUnwrap(
            remoteBrowserSubview(in: surface.view, identifier: "Stacio.RemoteBrowser.statusIndicator") as? NSProgressIndicator
        )
        let retry = try XCTUnwrap(
            remoteBrowserSubview(in: surface.view, identifier: "Stacio.RemoteBrowser.retry") as? NSButton
        )
        XCTAssertFalse(waiting.isHidden)
        XCTAssertTrue(waiting.stringValue.contains("载入失败"))
        XCTAssertTrue(waiting.stringValue.contains("net::ERR_CONNECTION_REFUSED"))
        XCTAssertFalse(retry.isHidden)
        XCTAssertFalse(indicator.isDisplayedWhenStopped && indicator.isHidden == false)

        retry.performClick(nil)

        XCTAssertEqual(client.commands.last?.0, "Page.reload")
        XCTAssertTrue(waiting.isHidden)
        XCTAssertTrue(retry.isHidden)
    }

    func testRemoteChromiumSurfaceCachesLayoutBeforeReadinessAndSendsViewportBeforeNavigation() throws {
        let client = RecordingChromeDevToolsClient()
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client
        )
        surface.loadView()
        surface.view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        surface.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(client.commands.isEmpty, "Layout before CDP readiness must only cache the viewport.")

        client.emit(.connected)

        XCTAssertEqual(client.commands.map(\.0), ["Emulation.setDeviceMetricsOverride", "Page.navigate"])
        let metrics = try XCTUnwrap(client.commands.first?.1)
        XCTAssertGreaterThan(try XCTUnwrap(metrics["width"] as? Int), 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics["height"] as? Int), 0)
    }

    func testRemoteChromiumSurfaceQueuesOnlyLatestAddressUntilCDPIsConnected() throws {
        let client = RecordingChromeDevToolsClient()
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://initial.internal")!,
            client: client
        )
        surface.loadView()
        surface.view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        surface.view.layoutSubtreeIfNeeded()

        surface.navigate(toAddress: "http://first.internal")
        surface.navigate(toAddress: "http://latest.internal")

        XCTAssertTrue(client.commands.isEmpty, "CDP commands must wait for the connected barrier.")

        client.emit(.connected)

        XCTAssertEqual(client.commands.map(\.0), ["Emulation.setDeviceMetricsOverride", "Page.navigate"])
        XCTAssertEqual(client.commands.last?.1["url"] as? String, "http://latest.internal")
    }

    func testRemoteChromiumSurfaceBridgesFocusAndExplicitClipboardActions() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Stacio.RemoteBrowser.Tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("local clipboard", forType: .string)
        let client = RecordingChromeDevToolsClient()
        client.evaluationResults = ["remote selection"]
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client,
            pasteboard: pasteboard
        )
        surface.loadView()
        client.emit(.connected)
        client.commands.removeAll()

        surface.setPageFocusForTesting(true)
        surface.pasteLocalClipboardForTesting()
        surface.copyRemoteSelectionForTesting()

        XCTAssertEqual(client.commands.map(\.0), [
            "Emulation.setFocusEmulationEnabled",
            "Input.insertText"
        ])
        XCTAssertEqual(client.commands[0].1["enabled"] as? Bool, true)
        XCTAssertEqual(client.commands[1].1["text"] as? String, "local clipboard")
        XCTAssertEqual(pasteboard.string(forType: .string), "remote selection")
        XCTAssertEqual(client.evaluatedExpressions.count, 1)
        XCTAssertTrue(client.evaluatedExpressions[0].contains("activeElement"))
    }

    func testRemoteChromiumSurfaceMirrorsWindowKeyFocusToCDP() {
        let client = RecordingChromeDevToolsClient()
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = surface
        surface.loadView()
        client.emit(.connected)
        surface.viewDidAppear()
        client.commands.removeAll()

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        XCTAssertEqual(client.commands.map(\.0), [
            "Emulation.setFocusEmulationEnabled",
            "Emulation.setFocusEmulationEnabled"
        ])
        XCTAssertEqual(client.commands.map { $0.1["enabled"] as? Bool }, [true, false])
        surface.viewWillDisappear()
    }

    func testRemoteChromiumSurfaceUpdatesTitleAndFaviconWithStableFallback() throws {
        let favicon = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl6sAAAAASUVORK5CYII="
        let client = RecordingChromeDevToolsClient()
        client.evaluationResults = [
            #"{"title":"Operations","favicon":"\#(favicon)"}"#,
            #"{"title":"   ","favicon":null}"#
        ]
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client
        )
        surface.loadView()
        client.emit(.connected)

        client.emit(.loading(false))

        XCTAssertEqual(surface.title, "Operations")
        XCTAssertNotNil(surface.faviconImageForTesting)

        client.emit(.loading(false))

        XCTAssertEqual(surface.title, L10n.Inspector.browser)
        XCTAssertNotNil(surface.faviconImageForTesting)
    }

    func testAsyncSOCKSStopFailureRetriesExactProfileAutomatically() async {
        let firstStop = expectation(description: "first SOCKS stop failed")
        let retryStop = expectation(description: "SOCKS stop retried")
        let tunnelBridge = RetryingStopRemoteBrowserTunnelBridge(
            context: Self.liveContext,
            stopResults: [
                .failure(TestRemoteBrowserError.failed),
                .success(TunnelRuntimeStatus(profileId: "placeholder", state: .stopped, message: "stopped"))
            ],
            stopExpectations: [firstStop, retryStop]
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: nil,
            proxyCleanupRetryDelays: [0.05]
        )
        controller.loadView()
        let didStartSOCKS = await waitUntil { controller.browserModeForTesting == .socksWebKit }
        XCTAssertTrue(didStartSOCKS)

        XCTAssertTrue(controller.stopRemoteBrowserProxy())
        await fulfillment(of: [firstStop], timeout: 1)
        await fulfillment(of: [retryStop], timeout: 1)

        XCTAssertEqual(tunnelBridge.stoppedProfileIDs.count, 2)
        XCTAssertEqual(Set(tunnelBridge.stoppedProfileIDs).count, 1)
    }

    func testSOCKSCleanupRetrySurvivesControllerDeallocation() async {
        let firstStop = expectation(description: "first SOCKS stop failed")
        let retryStop = expectation(description: "SOCKS stop retried after controller deallocation")
        let tunnelBridge = RetryingStopRemoteBrowserTunnelBridge(
            context: Self.liveContext,
            stopResults: [
                .failure(TestRemoteBrowserError.failed),
                .success(TunnelRuntimeStatus(profileId: "placeholder", state: .stopped, message: "stopped"))
            ],
            stopExpectations: [firstStop, retryStop]
        )
        var controller: RemoteNetworkBrowserViewController? = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: nil,
            proxyCleanupRetryDelays: [0.01]
        )
        controller?.loadView()
        let didStartSOCKS = await waitUntil { controller?.browserModeForTesting == .socksWebKit }
        XCTAssertTrue(didStartSOCKS)

        XCTAssertTrue(controller?.stopRemoteBrowserProxy() == true)
        await fulfillment(of: [firstStop], timeout: 1)
        controller = nil

        await fulfillment(of: [retryStop], timeout: 1)
        XCTAssertEqual(tunnelBridge.stoppedProfileIDs.count, 2)
        XCTAssertEqual(Set(tunnelBridge.stoppedProfileIDs).count, 1)
    }

    func testSOCKSStartupCleanupFailureRetriesSameProfileAutomaticallyAndReportsPendingState() async {
        let initialCleanup = expectation(description: "failed SOCKS startup cleanup")
        let retryCleanup = expectation(description: "retried SOCKS startup cleanup")
        let log = RecordingRemoteBrowserLog()
        let tunnelBridge = RetryingStopRemoteBrowserTunnelBridge(
            context: Self.liveContext,
            startError: TestRemoteBrowserError.failed,
            stopResults: [
                .failure(TestRemoteBrowserError.failed),
                .success(TunnelRuntimeStatus(profileId: "placeholder", state: .stopped, message: "stopped"))
            ],
            stopExpectations: [initialCleanup, retryCleanup]
        )
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: true,
            remoteChromiumRuntime: nil,
            lifecycleLog: log,
            proxyCleanupRetryDelays: [0.05]
        )

        controller.loadView()
        await fulfillment(of: [initialCleanup], timeout: 1)
        let didReportPendingCleanup = await waitUntil {
            controller.browserModeForTesting == .unavailable
                && controller.tunnelStatusTextForTesting.contains("清理待重试")
        }

        XCTAssertTrue(didReportPendingCleanup)
        XCTAssertTrue(
            controller.browserPaneViewControllerForTesting?.statusTextForTesting.contains("清理待重试") == true,
            "The visible failure state must disclose that proxy cleanup is still pending."
        )
        XCTAssertTrue(
            log.messages.contains { $0.contains("remote.browser.proxy.start.cleanup.pending") }
        )

        await fulfillment(of: [retryCleanup], timeout: 1)

        XCTAssertEqual(tunnelBridge.stoppedProfileIDs.count, 2)
        XCTAssertEqual(Set(tunnelBridge.stoppedProfileIDs).count, 1)
        XCTAssertTrue(
            tunnelBridge.stoppedProfileIDs.first?.hasPrefix("remote_browser_19090_") == true
        )
    }

    func testSamePortSOCKSReloadUsesUniqueProfilesAndStopsEachGenerationIndependently() {
        let tunnelBridge = RecordingRemoteBrowserTunnelBridge(context: Self.liveContext)
        let controller = RemoteNetworkBrowserViewController(
            runtimeBridge: tunnelBridge,
            localPortProvider: { 19_090 },
            startsProxyAsynchronously: false,
            remoteChromiumRuntime: nil
        )

        controller.loadView()
        controller.reloadForCurrentRemoteContext()

        XCTAssertEqual(tunnelBridge.startedProfiles.count, 2)
        XCTAssertNotEqual(tunnelBridge.startedProfiles[0].id, tunnelBridge.startedProfiles[1].id)
        XCTAssertTrue(
            tunnelBridge.startedProfiles.allSatisfy { $0.id.hasPrefix("remote_browser_19090_") }
        )
        XCTAssertEqual(tunnelBridge.stoppedProfiles.map(\.id), [tunnelBridge.startedProfiles[0].id])

        XCTAssertTrue(controller.stopRemoteBrowserProxy())
        XCTAssertEqual(
            tunnelBridge.stoppedProfiles.map(\.id),
            tunnelBridge.startedProfiles.map(\.id)
        )
    }

    func testRemoteChromiumZoomCommandsClampAndResetPageScale() throws {
        let client = RecordingChromeDevToolsClient()
        let surface = RemoteChromiumSurfaceViewController(
            initialURL: URL(string: "http://app.internal")!,
            client: client
        )
        surface.loadView()
        surface.view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        surface.view.layoutSubtreeIfNeeded()
        client.emit(.connected)
        client.commands.removeAll()

        for _ in 0..<30 { surface.performZoom(.zoomIn) }
        XCTAssertEqual(surface.pageScaleFactor, 2, accuracy: 0.001)
        XCTAssertEqual(client.commands.last?.0, "Emulation.setPageScaleFactor")
        XCTAssertEqual(
            try XCTUnwrap(client.commands.last?.1["pageScaleFactor"] as? Double),
            2,
            accuracy: 0.001
        )

        for _ in 0..<40 { surface.performZoom(.zoomOut) }
        XCTAssertEqual(surface.pageScaleFactor, 0.5, accuracy: 0.001)

        surface.performZoom(.reset)
        XCTAssertEqual(surface.pageScaleFactor, 1, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(client.commands.last?.1["pageScaleFactor"] as? Double),
            1,
            accuracy: 0.001
        )
    }

    func testRemoteChromiumCanvasConsumesCommandZoomShortcuts() throws {
        let canvas = RemoteChromiumCanvasView()
        var zoomCommands: [RemoteChromiumZoomCommand] = []
        var inputMethods: [String] = []
        canvas.onZoomCommand = { zoomCommands.append($0) }
        canvas.onInput = { method, _ in inputMethods.append(method) }

        for (keyCode, characters) in [(UInt16(24), "+"), (UInt16(27), "-"), (UInt16(29), "0")] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.command],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                )
            )
            canvas.keyDown(with: event)
            let keyUp = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyUp,
                    location: .zero,
                    modifierFlags: [.command],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                )
            )
            canvas.keyUp(with: keyUp)
        }

        XCTAssertEqual(zoomCommands, [.zoomIn, .zoomOut, .reset])
        XCTAssertTrue(inputMethods.isEmpty)
    }

    func testRemoteChromiumCanvasConsumesZoomKeyUpAfterCommandWasReleasedFirst() throws {
        let canvas = RemoteChromiumCanvasView()
        var zoomCommands: [RemoteChromiumZoomCommand] = []
        var inputParameters: [[String: Any]] = []
        canvas.onZoomCommand = { zoomCommands.append($0) }
        canvas.onInput = { _, parameters in inputParameters.append(parameters) }
        let keyDown = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "+",
                charactersIgnoringModifiers: "+",
                isARepeat: false,
                keyCode: 24
            )
        )
        let commandReleased = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 55
            )
        )
        let keyUp = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "+",
                charactersIgnoringModifiers: "+",
                isARepeat: false,
                keyCode: 24
            )
        )

        canvas.keyDown(with: keyDown)
        canvas.flagsChanged(with: commandReleased)
        canvas.keyUp(with: keyUp)

        XCTAssertEqual(zoomCommands, [.zoomIn])
        XCTAssertFalse(inputParameters.contains { ($0["code"] as? String) == "Equal" })
        XCTAssertEqual(inputParameters.compactMap { $0["code"] as? String }, ["MetaLeft"])
    }

    func testRemoteChromiumCanvasConsumesPasteKeyDownAndKeyUp() throws {
        let canvas = RemoteChromiumCanvasView()
        var pasteCount = 0
        var inputMethods: [String] = []
        canvas.onPasteRequested = { pasteCount += 1 }
        canvas.onInput = { method, _ in inputMethods.append(method) }
        let keyDown = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )
        let keyUp = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )

        canvas.keyDown(with: keyDown)
        canvas.keyUp(with: keyUp)

        XCTAssertEqual(pasteCount, 1)
        XCTAssertTrue(inputMethods.isEmpty)
    }

    func testFrameMailboxDecodesOffMainAndDropsIntermediateFrames() throws {
        let firstDecodeStarted = expectation(description: "first decode started")
        let secondDecodeFinished = expectation(description: "latest frame decoded")
        let releaseFirstDecode = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var decodedValues: [String] = []
        var decodedOnMain: [Bool] = []
        let image = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        )
        let mailbox = RemoteChromiumFrameMailbox(
            decodingQueue: DispatchQueue(label: "RemoteChromiumFrameMailboxTests.decode"),
            imageDecoder: { data in
                lock.lock()
                decodedValues.append(String(decoding: data, as: UTF8.self))
                decodedOnMain.append(Thread.isMainThread)
                let count = decodedValues.count
                lock.unlock()
                if count == 1 {
                    firstDecodeStarted.fulfill()
                    _ = releaseFirstDecode.wait(timeout: .now() + 1)
                } else if count == 2 {
                    secondDecodeFinished.fulfill()
                }
                return image
            }
        )

        mailbox.submit(data: Data("one".utf8), width: 1, height: 1) { _, _, _ in }
        wait(for: [firstDecodeStarted], timeout: 1)
        mailbox.submit(data: Data("two".utf8), width: 1, height: 1) { _, _, _ in }
        mailbox.submit(data: Data("three".utf8), width: 1, height: 1) { _, _, _ in }
        releaseFirstDecode.signal()
        wait(for: [secondDecodeFinished], timeout: 1)

        lock.lock()
        let values = decodedValues
        let mainFlags = decodedOnMain
        lock.unlock()
        XCTAssertEqual(values, ["one", "three"])
        XCTAssertEqual(mainFlags, [false, false])
    }

    func testRemoteChromiumCanvasForwardsIMECompositionAndCommittedText() {
        let canvas = RemoteChromiumCanvasView()
        var commands: [(String, [String: Any])] = []
        canvas.onInput = { commands.append(($0, $1)) }

        canvas.setMarkedText(
            "拼音",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        canvas.insertText(
            "中文",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(commands[0].0, "Input.imeSetComposition")
        XCTAssertEqual(commands[0].1["text"] as? String, "拼音")
        XCTAssertEqual(commands[0].1["selectionStart"] as? Int, 2)
        XCTAssertEqual(commands[1].0, "Input.insertText")
        XCTAssertEqual(commands[1].1["text"] as? String, "中文")
    }

    private static let liveContext = TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: "server.internal",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 2_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:test"
    )

    private static let chromiumSession = RemoteChromiumRuntimeSession(
        leaseID: UUID(uuidString: "A0A0A0A0-0000-4000-8000-000000000001")!,
        remoteProcessID: 4_242,
        remoteTemporaryDirectory: "/tmp/stacio-chromium.AbC123",
        remoteDownloadsDirectory: "/tmp/stacio-chromium.AbC123/downloads",
        localDebugPort: 19_090,
        pageWebSocketURL: URL(string: "ws://127.0.0.1:19090/devtools/page/page-1")!
    )

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

private enum TestRemoteBrowserError: Error {
    case failed
}

private final class BlockingRemoteChromiumRuntime: RemoteChromiumRuntimeControlling {
    private let session: RemoteChromiumRuntimeSession
    private let startEntered: XCTestExpectation
    private let stopCalled: XCTestExpectation
    private let startGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedStoppedSessions: [RemoteChromiumRuntimeSession] = []

    init(
        session: RemoteChromiumRuntimeSession,
        startEntered: XCTestExpectation,
        stopCalled: XCTestExpectation
    ) {
        self.session = session
        self.startEntered = startEntered
        self.stopCalled = stopCalled
    }

    var stoppedSessions: [RemoteChromiumRuntimeSession] {
        lock.withLock { recordedStoppedSessions }
    }

    func releaseStart() {
        startGate.signal()
    }

    func start(
        context: TunnelLiveSessionContext,
        localPort: UInt16
    ) throws -> RemoteChromiumRuntimeSession {
        startEntered.fulfill()
        guard startGate.wait(timeout: .now() + 2) == .success else {
            throw TestRemoteBrowserError.failed
        }
        return session
    }

    func stop(session: RemoteChromiumRuntimeSession) {
        lock.withLock {
            recordedStoppedSessions.append(session)
        }
        stopCalled.fulfill()
    }

    func retainDownload(_ download: RemoteChromiumDownload) -> Bool { false }
    func acknowledgeDownload(
        _ download: RemoteChromiumDownload,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool {
        false
    }
}

private final class RecordingRemoteChromiumRuntime: RemoteChromiumRuntimeControlling {
    let result: Result<RemoteChromiumRuntimeSession, Error>
    private(set) var startedPorts: [UInt16] = []
    private(set) var stoppedSessions: [RemoteChromiumRuntimeSession] = []
    private(set) var retainedDownloads: [RemoteChromiumDownload] = []
    private(set) var acknowledgedDownloads: [RemoteChromiumDownload] = []
    private(set) var lifecycleEvents: [String] = []

    init(result: Result<RemoteChromiumRuntimeSession, Error>) {
        self.result = result
    }

    func start(context: TunnelLiveSessionContext, localPort: UInt16) throws -> RemoteChromiumRuntimeSession {
        startedPorts.append(localPort)
        return try result.get()
    }

    func stop(session: RemoteChromiumRuntimeSession) {
        lifecycleEvents.append("stop")
        stoppedSessions.append(session)
    }

    func retainDownload(_ download: RemoteChromiumDownload) -> Bool {
        lifecycleEvents.append("retain")
        retainedDownloads.append(download)
        return true
    }

    func acknowledgeDownload(
        _ download: RemoteChromiumDownload,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool {
        lifecycleEvents.append("acknowledge")
        acknowledgedDownloads.append(download)
        completion(.success(()))
        return true
    }
}

@MainActor
private final class RecordingChromeDevToolsClient: ChromeDevToolsControlling {
    var onEvent: ((ChromeDevToolsEvent) -> Void)?
    var onFailure: ((Error) -> Void)?
    var commands: [(String, [String: Any])] = []
    var evaluationResults: [String?] = []
    private(set) var evaluatedExpressions: [String] = []
    private(set) var disconnectCount = 0

    func connect() {}
    func disconnect() {
        disconnectCount += 1
    }

    func send(method: String, parameters: [String: Any]) {
        commands.append((method, parameters))
    }

    func evaluateString(
        _ expression: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        evaluatedExpressions.append(expression)
        completion(.success(evaluationResults.isEmpty ? nil : evaluationResults.removeFirst()))
    }

    func fail(_ error: Error) {
        onFailure?(error)
    }

    func completeDownload(_ download: RemoteChromiumDownload) {
        onEvent?(.downloadCompleted(download))
    }

    func emit(_ event: ChromeDevToolsEvent) {
        onEvent?(event)
    }
}

private final class RecordingRemoteBrowserTunnelBridge: TunnelRuntimeBridging {
    let context: TunnelLiveSessionContext?
    private(set) var startedProfiles: [TunnelProfile] = []
    private(set) var stoppedProfiles: [TunnelProfile] = []

    init(context: TunnelLiveSessionContext?) {
        self.context = context
    }

    func captureLiveSessionContext() -> TunnelLiveSessionContext? { context }

    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        try start(profile: profile, liveSessionContext: context)
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        startedProfiles.append(profile)
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        stoppedProfiles.append(profile)
        return TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped")
    }
}

private final class BlockingRemoteBrowserTunnelBridge: TunnelRuntimeBridging {
    let context: TunnelLiveSessionContext?
    private let startEntered: XCTestExpectation
    private let stopCalled: XCTestExpectation
    private let startGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedStoppedProfiles: [TunnelProfile] = []

    init(
        context: TunnelLiveSessionContext?,
        startEntered: XCTestExpectation,
        stopCalled: XCTestExpectation
    ) {
        self.context = context
        self.startEntered = startEntered
        self.stopCalled = stopCalled
    }

    var stoppedProfiles: [TunnelProfile] {
        lock.withLock { recordedStoppedProfiles }
    }

    func releaseStart() {
        startGate.signal()
    }

    func captureLiveSessionContext() -> TunnelLiveSessionContext? { context }

    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        try start(profile: profile, liveSessionContext: context)
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        startEntered.fulfill()
        guard startGate.wait(timeout: .now() + 2) == .success else {
            throw TestRemoteBrowserError.failed
        }
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        lock.withLock {
            recordedStoppedProfiles.append(profile)
        }
        stopCalled.fulfill()
        return TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped")
    }
}

private final class BlockingStartRetryingStopRemoteBrowserTunnelBridge: TunnelRuntimeBridging {
    let context: TunnelLiveSessionContext?
    private let startEntered: XCTestExpectation
    private let startGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopResults: [Result<TunnelRuntimeStatus, Error>]
    private var stopExpectations: [XCTestExpectation]
    private(set) var stoppedProfiles: [TunnelProfile] = []

    init(
        context: TunnelLiveSessionContext?,
        startEntered: XCTestExpectation,
        stopResults: [Result<TunnelRuntimeStatus, Error>],
        stopExpectations: [XCTestExpectation]
    ) {
        self.context = context
        self.startEntered = startEntered
        self.stopResults = stopResults
        self.stopExpectations = stopExpectations
    }

    func releaseStart() {
        startGate.signal()
    }

    func captureLiveSessionContext() -> TunnelLiveSessionContext? { context }

    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        try start(profile: profile, liveSessionContext: context)
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        startEntered.fulfill()
        guard startGate.wait(timeout: .now() + 2) == .success else {
            throw TestRemoteBrowserError.failed
        }
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        let entry = lock.withLock { () -> (Result<TunnelRuntimeStatus, Error>, XCTestExpectation?) in
            stoppedProfiles.append(profile)
            let result = stopResults.isEmpty
                ? .success(TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped"))
                : stopResults.removeFirst()
            let expectation = stopExpectations.isEmpty ? nil : stopExpectations.removeFirst()
            return (result, expectation)
        }
        entry.1?.fulfill()
        switch entry.0 {
        case let .failure(error):
            throw error
        case let .success(status):
            return TunnelRuntimeStatus(profileId: profile.id, state: status.state, message: status.message)
        }
    }
}

private final class RetryingStopRemoteBrowserTunnelBridge: TunnelRuntimeBridging, @unchecked Sendable {
    let context: TunnelLiveSessionContext?
    private let startError: Error?
    private let lock = NSLock()
    private var stopResults: [Result<TunnelRuntimeStatus, Error>]
    private var stopExpectations: [XCTestExpectation]
    private var recordedStoppedProfileIDs: [String] = []

    init(
        context: TunnelLiveSessionContext?,
        startError: Error? = nil,
        stopResults: [Result<TunnelRuntimeStatus, Error>],
        stopExpectations: [XCTestExpectation]
    ) {
        self.context = context
        self.startError = startError
        self.stopResults = stopResults
        self.stopExpectations = stopExpectations
    }

    var stoppedProfileIDs: [String] {
        lock.withLock { recordedStoppedProfileIDs }
    }

    func captureLiveSessionContext() -> TunnelLiveSessionContext? { context }

    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        try start(profile: profile, liveSessionContext: context)
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        if let startError { throw startError }
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        let entry = lock.withLock { () -> (Result<TunnelRuntimeStatus, Error>, XCTestExpectation?) in
            recordedStoppedProfileIDs.append(profile.id)
            let result = stopResults.isEmpty
                ? .success(TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped"))
                : stopResults.removeFirst()
            let expectation = stopExpectations.isEmpty ? nil : stopExpectations.removeFirst()
            return (result, expectation)
        }
        entry.1?.fulfill()
        switch entry.0 {
        case let .failure(error):
            throw error
        case let .success(status):
            return TunnelRuntimeStatus(profileId: profile.id, state: status.state, message: status.message)
        }
    }
}

private final class RecordingRemoteBrowserLog: StacioLogWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    var messages: [String] {
        lock.withLock { recordedMessages }
    }

    func append(
        level: StacioLogLevel,
        category: String,
        message: String,
        sensitiveValues: [String]
    ) {
        lock.withLock {
            recordedMessages.append(message)
        }
    }
}

private final class RecordingRemoteChromiumDownloadDelegate: RemoteChromiumDownloadDelegate {
    private(set) var completedDownloads: [RemoteChromiumDownload] = []

    func remoteChromiumDidCompleteDownload(_ download: RemoteChromiumDownload) {
        completedDownloads.append(download)
    }
}

@MainActor
private func remoteBrowserSubview(in view: NSView, identifier: String) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    for subview in view.subviews {
        if let match = remoteBrowserSubview(in: subview, identifier: identifier) {
            return match
        }
    }
    return nil
}

@MainActor
private func remoteBrowserSubviews(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(remoteBrowserSubviews(in:))
}
