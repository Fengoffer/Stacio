import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class StacioApplicationTests: XCTestCase {
    func testApplicationDidFinishLaunchingCreatesShowsAndRetainsMainWindowController() {
        final class FakeWorkbenchWindowController: WorkbenchWindowShowing {
            private(set) var showWindowSender: Any?
            private(set) var showWindowCount = 0

            func showWindow(_ sender: Any?) {
                showWindowSender = sender
                showWindowCount += 1
            }

            func openSavedSession(id: String) {}
            func toggleDeviceDashboardFromMenu(_ sender: Any?) {}
            func prepareForApplicationTermination() -> Bool { true }
        }

        weak var weakController: FakeWorkbenchWindowController?
        var createdController: FakeWorkbenchWindowController?
        let delegate = AppDelegate(factory: {
            let controller = FakeWorkbenchWindowController()
            weakController = controller
            createdController = controller
            return controller
        })

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertNotNil(createdController)
        XCTAssertTrue(createdController?.showWindowSender as AnyObject === delegate)
        XCTAssertNil(NSApplication.shared.helpMenu)
        createdController = nil
        XCTAssertNotNil(weakController)
    }

    func testApplicationShowsFreePlanNoticeOnLaunchWhenNoLicenseIsActive() {
        var noticeController: FreePlanNoticeWindowController?
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(
                shouldTerminate: true
            ),
            shouldShowFreePlanNotice: true,
            hasValidLicense: { false },
            freePlanNoticeWindowControllerFactory: {
                let controller = FreePlanNoticeWindowController()
                noticeController = controller
                return controller
            }
        )
        defer { noticeController?.close() }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertTrue(noticeController?.window?.isVisible == true)
    }

    func testApplicationDoesNotShowFreePlanNoticeWhenLicenseIsActive() {
        var noticeFactoryCallCount = 0
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(
                shouldTerminate: true
            ),
            shouldShowFreePlanNotice: true,
            hasValidLicense: { true },
            freePlanNoticeWindowControllerFactory: {
                noticeFactoryCallCount += 1
                return FreePlanNoticeWindowController()
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(noticeFactoryCallCount, 0)
    }

    func testApplicationReopensWorkbenchWhenStateRestorationLeavesNoVisibleWindows() {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.ensureWorkbenchWindowVisible(sender: delegate, hasVisibleWindows: false)

        XCTAssertEqual(workbench.showWindowCount, 2)
    }

    func testApplicationDoesNotReopenWorkbenchWhenAWindowIsAlreadyVisible() {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.ensureWorkbenchWindowVisible(sender: delegate, hasVisibleWindows: true)

        XCTAssertEqual(workbench.showWindowCount, 1)
    }

    func testApplicationDidFinishLaunchingWritesStartupBundleLog() {
        let logStore = RecordingApplicationLogStore()
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            appLog: logStore
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let joinedLogs = logStore.lines.joined(separator: "\n")
        XCTAssertTrue(joinedLogs.contains("app.started"))
        XCTAssertTrue(joinedLogs.contains("bundle="))
        XCTAssertTrue(joinedLogs.contains("executable="))
        XCTAssertTrue(joinedLogs.contains("version=Stacio-0.14.0"))
    }

    func testApplicationLaunchDoesNotRevalidatePersistedLicenseOrStartNetworkMonitoring() async {
        let revalidator = RecordingLicenseRevalidator()
        let networkMonitor = RecordingLicenseNetworkMonitor()
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(
                shouldTerminate: true
            ),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker(),
            licenseRevalidator: revalidator,
            licenseNetworkMonitor: networkMonitor
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await Task.yield()

        XCTAssertEqual(revalidator.launchCount, 0)
        XCTAssertEqual(revalidator.networkRestoreCount, 0)
        XCTAssertEqual(networkMonitor.startCount, 0)
    }

    func testApplicationSilentlyRevalidatesLicenseInsideRenewalMilestone() async {
        let markerKey = "Stacio.License.lastSilentSyncMilestone"
        let previousMarker = UserDefaults.standard.object(forKey: markerKey)
        UserDefaults.standard.removeObject(forKey: markerKey)
        defer {
            if let previousMarker {
                UserDefaults.standard.set(previousMarker, forKey: markerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: markerKey)
            }
        }
        let revalidator = RecordingLicenseRevalidator(outcome: .refreshed(LicenseState(status: .active)))
        let networkMonitor = RecordingLicenseNetworkMonitor()
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(
                shouldTerminate: true
            ),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker(),
            licenseRevalidator: revalidator,
            licenseNetworkMonitor: networkMonitor,
            licenseStateProvider: {
                LicenseState(
                    expiresAt: Date().addingTimeInterval(3 * 86_400),
                    status: .active
                )
            }
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<10 where revalidator.launchCount == 0 {
            await Task.yield()
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(networkMonitor.startCount, 1)
        XCTAssertEqual(revalidator.launchCount, 1)
    }

    func testApplicationIgnoresNetworkRestoreForPersistedLicense() async {
        let revalidator = RecordingLicenseRevalidator()
        let networkMonitor = RecordingLicenseNetworkMonitor()
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(
                shouldTerminate: true
            ),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker(),
            licenseRevalidator: revalidator,
            licenseNetworkMonitor: networkMonitor
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        networkMonitor.simulateNetworkRestore()
        await Task.yield()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(revalidator.networkRestoreCount, 0)
        XCTAssertEqual(networkMonitor.cancelCount, 1)
    }

    func testApplicationIgnoresRuntimeNetworkDisconnectForPersistedLicense() async {
        let revalidator = RecordingLicenseRevalidator()
        let networkMonitor = RecordingLicenseNetworkMonitor()
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(
                shouldTerminate: true
            ),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker(),
            licenseRevalidator: revalidator,
            licenseNetworkMonitor: networkMonitor
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        networkMonitor.simulateNetworkUnavailable()
        await Task.yield()

        XCTAssertEqual(revalidator.networkUnavailableCount, 0)
        XCTAssertEqual(revalidator.networkRestoreCount, 0)
    }

    func testInstallDelegateRetainsDelegateForLaunchCallbacks() {
        StacioApplication.releaseRetainedDelegate()
        NSApplication.shared.delegate = nil
        defer {
            NSApplication.shared.delegate = nil
            StacioApplication.releaseRetainedDelegate()
        }

        weak var weakDelegate: AppDelegate?
        autoreleasepool {
            let delegate = StacioApplication.installDelegate(on: NSApplication.shared)
            weakDelegate = delegate
            XCTAssertTrue((NSApplication.shared.delegate as AnyObject) === delegate)
        }

        XCTAssertNotNil(weakDelegate)
        XCTAssertTrue(StacioApplication.retainedDelegate === weakDelegate)
    }

    func testApplicationRegistersStateRestorationIgnoreDefaultsBeforeLaunch() throws {
        let suiteName = "StacioApplicationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        StacioApplication.configureStateRestorationDefaults(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: "ApplePersistenceIgnoreStateQuietly"))
        XCTAssertTrue(defaults.bool(forKey: "ApplePersistenceIgnoreState"))
    }

    func testApplicationShouldAskBeforeTerminatingWithRunningTunnelsAndCancelWhenUserDeclines() {
        let workbench = FakeWorkbenchWindowController(hasRunningTunnels: true)
        let confirmation = RecordingRunningTunnelTerminationConfirmation(shouldTerminate: false)
        let delegate = AppDelegate(
            factory: { workbench },
            runningTunnelTerminationConfirmation: confirmation
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(confirmation.requestedCounts, [1])
        XCTAssertEqual(workbench.prepareForTerminationCount, 0)
    }

    func testApplicationTerminatesImmediatelyWhenNoTunnelsAreRunning() {
        let workbench = FakeWorkbenchWindowController(hasRunningTunnels: false)
        let confirmation = RecordingRunningTunnelTerminationConfirmation(shouldTerminate: false)
        let delegate = AppDelegate(
            factory: { workbench },
            runningTunnelTerminationConfirmation: confirmation
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(confirmation.requestedCounts, [])
        XCTAssertEqual(workbench.prepareForTerminationCount, 1)
    }

    func testApplicationTerminatesAfterRunningTunnelConfirmationAndClosesWorkbenchSessions() {
        let workbench = FakeWorkbenchWindowController(hasRunningTunnels: true)
        let confirmation = RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true)
        let delegate = AppDelegate(
            factory: { workbench },
            runningTunnelTerminationConfirmation: confirmation
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(confirmation.requestedCounts, [1])
        XCTAssertEqual(workbench.prepareForTerminationCount, 1)
    }

    func testApplicationCancelsTerminationWhenWorkbenchRefusesSessionCleanup() {
        let workbench = FakeWorkbenchWindowController(hasRunningTunnels: false)
        workbench.shouldPrepareForTermination = false
        let confirmation = RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true)
        let delegate = AppDelegate(
            factory: { workbench },
            runningTunnelTerminationConfirmation: confirmation
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(confirmation.requestedCounts, [])
        XCTAssertEqual(workbench.prepareForTerminationCount, 1)
    }

    func testStacioOpenSessionURLForwardsDecodedSessionIDToWorkbench() {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.openStacioURLForTesting(URL(string: "stacio://open-session/session%20api%2F1")!)

        XCTAssertEqual(workbench.openSavedSessionIDs, ["session api/1"])
    }

    func testLegacyStacioOpenSessionURLStillForwardsDecodedSessionIDToWorkbench() {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.openStacioURLForTesting(URL(string: "stacio://open-session/legacy%20session")!)

        XCTAssertEqual(workbench.openSavedSessionIDs, ["legacy session"])
    }

    func testStacioOpenSessionURLIgnoresUnknownRoutes() {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.openStacioURLForTesting(URL(string: "stacio://unknown/session_api")!)

        XCTAssertEqual(workbench.openSavedSessionIDs, [])
    }

    func testStacioConnectURLForwardsValidatedBastionRequestToWorkbench() throws {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let request = BastionHostDeepLinkRequest(
            version: 1,
            vendor: "example",
            protocolName: "ssh",
            gatewayHost: "bastion.example.com",
            gatewayPort: 60022,
            gatewayUsername: "SSH@ops@10.0.0.8",
            targetHost: "10.0.0.8",
            targetPort: 22,
            targetUsername: "ops",
            assetID: "asset-1",
            accountID: "account-1",
            requestID: "req-1",
            nonce: "nonce-1",
            expiresAt: Date().addingTimeInterval(60)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(request).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: "stacio://connect")!
        components.queryItems = [URLQueryItem(name: "payload", value: payload)]

        delegate.openStacioURLForTesting(try XCTUnwrap(components.url))

        let forwarded = try XCTUnwrap(workbench.openBastionHostRequests.first)
        XCTAssertEqual(forwarded.vendor, request.vendor)
        XCTAssertEqual(forwarded.gatewayHost, request.gatewayHost)
        XCTAssertEqual(forwarded.gatewayPort, request.gatewayPort)
        XCTAssertEqual(forwarded.gatewayUsername, request.gatewayUsername)
        XCTAssertEqual(forwarded.targetHost, request.targetHost)
        XCTAssertEqual(forwarded.requestID, request.requestID)
        XCTAssertEqual(forwarded.expiresAt.timeIntervalSince1970, request.expiresAt.timeIntervalSince1970, accuracy: 1)
    }

    func testDeviceDashboardMenuActionForwardsToWorkbench() {
        let workbench = FakeWorkbenchWindowController()
        let delegate = AppDelegate(factory: { workbench })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.toggleDeviceDashboardFromMenu(nil)

        XCTAssertEqual(workbench.deviceDashboardMenuToggleCount, 1)
    }

    func testUpdateMenuActionUsesSparkleManualChecker() {
        let workbench = FakeWorkbenchWindowController()
        let checker = RecordingSparkleUpdateChecker()
        let delegate = AppDelegate(
            factory: { workbench },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true),
            sparkleUpdateChecker: checker
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        delegate.showUpdateCheckWindow("manual-check" as NSString)

        XCTAssertEqual(checker.senderDescriptions, ["manual-check"])
    }

    func testUpdateMenuShowsNativeWindowWithVisibleLatestResult() throws {
        let workbench = FakeWorkbenchWindowController()
        let checker = RecordingSparkleUpdateChecker()
        checker.manualStates = [.checking, .upToDate]
        let delegate = AppDelegate(
            factory: { workbench },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true),
            sparkleUpdateChecker: checker
        )

        delegate.showUpdateCheckWindow("visible-check" as NSString)

        let window = try XCTUnwrap(NSApplication.shared.windows.last { $0.title == L10n.ProductOps.updateTitle })
        defer { window.close() }
        let status = try XCTUnwrap(
            window.contentView?.firstSubview(withIdentifier: "Stacio.Update.status") as? NSTextField
        )
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(status.stringValue.contains("已是最新"))
        XCTAssertEqual(checker.senderDescriptions, ["visible-check"])
    }

    func testFeedbackMenuReusesClosedWindowWhileSubmissionStateMayStillBeActive() throws {
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker()
        )

        delegate.showFeedbackWindow(nil)
        let firstWindow = try XCTUnwrap(
            NSApplication.shared.windows.last { $0.title == L10n.ProductOps.feedbackTitle }
        )
        firstWindow.close()

        delegate.showFeedbackWindow(nil)
        let reopenedWindow = try XCTUnwrap(
            NSApplication.shared.windows.last { $0.title == L10n.ProductOps.feedbackTitle && $0.isVisible }
        )
        defer { reopenedWindow.close() }

        XCTAssertTrue(firstWindow === reopenedWindow)
    }

    func testFeedbackMenuCreatesFreshDraftAfterSuccessfulSubmissionIsClosed() async throws {
        let firstController = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2-Beta",
                build: "211",
                osVersion: "macOS 14",
                deviceID: "anonymous-device"
            ),
            submitter: ImmediateSuccessFeedbackSubmitter()
        )
        let secondController = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2-Beta",
                build: "211",
                osVersion: "macOS 14",
                deviceID: "anonymous-device"
            ),
            submitter: ImmediateSuccessFeedbackSubmitter()
        )
        var pendingControllers = [firstController, secondController]
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker(),
            feedbackWindowControllerFactory: { pendingControllers.removeFirst() }
        )

        delegate.showFeedbackWindow(nil)
        let content = try XCTUnwrap(firstController.window?.contentView)
        let title = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Feedback.title") as? NSTextField
        )
        let descriptionScroll = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Feedback.description") as? NSScrollView
        )
        let description = try XCTUnwrap(descriptionScroll.documentView as? NSTextView)
        title.stringValue = "Update feedback"
        description.string = "The update completed successfully."
        firstController.submitCurrentReportForTesting()

        let deadline = Date().addingTimeInterval(1)
        while firstController.submissionState != .succeeded, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(firstController.submissionState, .succeeded)
        firstController.close()

        delegate.showFeedbackWindow(nil)
        defer { secondController.close() }

        XCTAssertTrue(secondController.window?.isVisible == true)
        XCTAssertFalse(firstController.window?.isVisible == true)
        XCTAssertEqual(pendingControllers.count, 0)
    }

    func testInstalledUpdateReleaseNotesArePresentedOnceAfterRelaunch() throws {
        let suiteName = "StacioApplicationTests.UpdateNotes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = InstalledUpdateReleaseNotesStore(defaults: defaults)
        let presenter = RecordingInstalledUpdateReleaseNotesPresenter()
        store.savePendingNotes(
            version: "0.14.0",
            build: "50",
            releaseNotes: "<p>新增 OTA 更新按钮。</p>"
        )
        let delegate = AppDelegate(
            factory: { FakeWorkbenchWindowController() },
            runningTunnelTerminationConfirmation: RecordingRunningTunnelTerminationConfirmation(shouldTerminate: true),
            sparkleUpdateChecker: RecordingSparkleUpdateChecker(),
            installedUpdateReleaseNotesStore: store,
            installedUpdateReleaseNotesPresenter: presenter
        )

        delegate.presentInstalledUpdateReleaseNotesIfNeeded(currentVersion: "0.14.0", build: "50")

        XCTAssertEqual(presenter.presentedVersions, ["0.14.0"])
        XCTAssertEqual(presenter.presentedReleaseNotes, ["<p>新增 OTA 更新按钮。</p>"])
        XCTAssertNil(store.pendingNotesMatching(version: "0.14.0", build: "50"))

        delegate.presentInstalledUpdateReleaseNotesIfNeeded(currentVersion: "0.14.0", build: "50")

        XCTAssertEqual(presenter.presentedVersions, ["0.14.0"])
    }

    func testInstalledUpdateReleaseNotesCapsLongContentInScrollableViewport() throws {
        let releaseNotes = """
        <!-- sparkle-sign-warning:
        IMPORTANT: This file was signed by Sparkle.
        -->
        """ + (1...80)
            .map { "## 更新内容 \($0)\n- 这是一条需要在固定正文区域内滚动查看的较长更新说明。" }
            .joined(separator: "\n")
        let presenter = AppKitInstalledUpdateReleaseNotesPresenter()

        let alert = presenter.makeAlert(version: "0.14.0", releaseNotes: releaseNotes)
        alert.layout()

        XCTAssertEqual(alert.messageText, "Stacio 已更新到 0.14.0")
        XCTAssertEqual(alert.informativeText, "")
        XCTAssertLessThanOrEqual(alert.window.frame.height, 560)
        let scrollView = try XCTUnwrap(alert.accessoryView as? NSScrollView)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertEqual(
            scrollView.frame.height,
            AppKitInstalledUpdateReleaseNotesPresenter.releaseNotesViewportMaximumHeight
        )
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertTrue(textView.string.hasPrefix("更新内容 1\n- 这是一条"))
        XCTAssertFalse(textView.string.contains("sparkle-sign-warning"))
        XCTAssertFalse(textView.string.contains("## 更新内容"))
        XCTAssertTrue(textView.string.contains("更新内容 80"))
        XCTAssertGreaterThan(textView.frame.height, scrollView.contentSize.height)
    }

    func testSparkleUpdatePromptOnlyTreatsBackendNewerVersionOrBuildAsAvailable() {
        XCTAssertTrue(
            SparkleUpdatePromptInfo(version: "0.14.0", build: "1")
                .isNewerThanCurrentVersion("0.13.2-Beta", build: "90")
        )
        XCTAssertTrue(
            SparkleUpdatePromptInfo(version: "0.13.2-Beta", build: "2")
                .isNewerThanCurrentVersion("0.13.2-Beta", build: "1")
        )
        XCTAssertFalse(
            SparkleUpdatePromptInfo(version: "0.13.2-Beta", build: "1")
                .isNewerThanCurrentVersion("0.13.2-Beta", build: "1")
        )
        XCTAssertFalse(
            SparkleUpdatePromptInfo(version: "0.13.1", build: "99")
                .isNewerThanCurrentVersion("0.13.2-Beta", build: "1")
        )
    }

    func testAboutPanelUsesCurrentStableVersionAndProductLinks() {
        let presenter = RecordingAboutPanelPresenter()
        let delegate = AppDelegate(factory: { FakeWorkbenchWindowController() })

        delegate.showAboutPanel(nil, presenter: presenter)

        let content = presenter.recordedContent
        XCTAssertEqual(content?.applicationName, "Stacio")
        XCTAssertEqual(content?.displayVersion, "Stacio-0.14.0")
        XCTAssertEqual(content?.websiteURL.absoluteString, "https://www.stacio.cn/")
        XCTAssertEqual(content?.websiteAccessibilityLabel, "Stacio 官网")
        XCTAssertEqual(content?.repositoryURL.absoluteString, "https://github.com/Fengoffer/Stacio")
        XCTAssertEqual(content?.githubAccessibilityLabel, "GitHub")
        XCTAssertEqual(content?.giteeRepositoryURL.absoluteString, "https://gitee.com/fengoffer/Stacio")
        XCTAssertEqual(content?.giteeAccessibilityLabel, "Gitee")
        XCTAssertEqual(content?.weChatAccessibilityLabel, "微信公众号")
        XCTAssertNotNil(content?.weChatQRCodeImage)
    }

    func testAppMetadataDisplayVersionUsesPackagedBundleVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioMetadataTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": StacioAppMetadata.bundleIdentifier,
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "9.8.7-Beta"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundle = try XCTUnwrap(Bundle(url: root))

        XCTAssertEqual(StacioAppMetadata.displayVersion(in: bundle), "Stacio-9.8.7-Beta")
    }

    func testAboutViewActionsUseIconTextButtonsWithoutFeedbackButtonAndWeChatHoverUsesQRCodeImage() {
        let opener = RecordingAboutURLOpener()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let content = StacioAboutContent(
            applicationName: "Stacio",
            displayVersion: "Stacio-0.14.0",
            websiteURL: URL(string: "https://www.stacio.cn/")!,
            repositoryURL: URL(string: "https://github.com/Fengoffer/Stacio")!,
            giteeRepositoryURL: URL(string: "https://gitee.com/fengoffer/Stacio")!,
            weChatQRCodeImage: image
        )
        let controller = StacioAboutViewController(content: content, urlOpener: opener)

        controller.loadView()
        controller.openWebsiteForTesting()
        controller.openGitHubForTesting()
        controller.openGiteeForTesting()

        XCTAssertEqual(controller.websiteButtonForTesting?.title, "官网")
        XCTAssertEqual(controller.websiteButtonForTesting?.toolTip, "Stacio 官网")
        XCTAssertNotNil(controller.websiteButtonForTesting?.image)
        XCTAssertEqual(controller.websiteButtonForTesting?.image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(controller.websiteButtonForTesting?.image?.isTemplate, true)
        XCTAssertEqual(controller.githubButtonForTesting?.toolTip, "GitHub")
        XCTAssertNotNil(controller.githubButtonForTesting?.image)
        XCTAssertEqual(controller.githubButtonForTesting?.image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(controller.githubButtonForTesting?.image?.isTemplate, true)
        XCTAssertFalse(controller.githubButtonForTesting?.image?.representations.isEmpty ?? true)
        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), [
            "https://www.stacio.cn/",
            "https://github.com/Fengoffer/Stacio",
            "https://gitee.com/fengoffer/Stacio"
        ])
        XCTAssertEqual(controller.giteeButtonForTesting?.title, "Gitee")
        XCTAssertEqual(controller.giteeButtonForTesting?.toolTip, "Gitee")
        XCTAssertNotNil(controller.giteeButtonForTesting?.image)
        XCTAssertEqual(controller.giteeButtonForTesting?.image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(controller.giteeButtonForTesting?.image?.isTemplate, true)
        XCTAssertFalse(controller.view.buttonTitlesForTesting.contains("反馈"))
        XCTAssertEqual(controller.weChatButtonForTesting?.title, "微信公众号")
        XCTAssertEqual(controller.weChatButtonForTesting?.toolTip, "微信公众号")
        XCTAssertNotNil(controller.weChatButtonForTesting?.image)
        XCTAssertEqual(controller.weChatButtonForTesting?.image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(controller.weChatButtonForTesting?.image?.isTemplate, true)
        XCTAssertTrue(controller.weChatQRCodeImageForTesting === image)
    }
}

private final class FakeWorkbenchWindowController: WorkbenchWindowShowing {
    var hasRunningTunnels: Bool
    var openSavedSessionIDs: [String] = []
    var openBastionHostRequests: [BastionHostDeepLinkRequest] = []
    var deviceDashboardMenuToggleCount = 0
    var shouldPrepareForTermination = true
    private(set) var showWindowCount = 0
    private(set) var prepareForTerminationCount = 0

    init(hasRunningTunnels: Bool = false) {
        self.hasRunningTunnels = hasRunningTunnels
    }

    func showWindow(_ sender: Any?) {
        showWindowCount += 1
    }

    func openSavedSession(id: String) {
        openSavedSessionIDs.append(id)
    }

    func openBastionHostConnection(_ request: BastionHostDeepLinkRequest) {
        openBastionHostRequests.append(request)
    }

    func toggleDeviceDashboardFromMenu(_ sender: Any?) {
        deviceDashboardMenuToggleCount += 1
    }

    func prepareForApplicationTermination() -> Bool {
        prepareForTerminationCount += 1
        return shouldPrepareForTermination
    }
}

extension FakeWorkbenchWindowController: RunningTunnelReporting {
    var runningTunnelCount: Int {
        hasRunningTunnels ? 1 : 0
    }
}

private final class RecordingAboutPanelPresenter: AboutPanelPresenting {
    var recordedContent: StacioAboutContent?

    func showAboutPanel(content: StacioAboutContent) {
        recordedContent = content
    }
}

private final class RecordingAboutURLOpener: StacioURLOpening {
    var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private extension NSView {
    var buttonTitlesForTesting: [String] {
        let current = (self as? NSButton).map { [$0.title] } ?? []
        return current + subviews.flatMap(\.buttonTitlesForTesting)
    }

    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

private final class RecordingSparkleUpdateChecker: SparkleUpdateChecking {
    var senderDescriptions: [String] = []
    var manualStates: [SparkleManualUpdateCheckState] = []

    func checkForUpdates(_ sender: Any?) {
        senderDescriptions.append((sender as? NSObject)?.description ?? "<nil>")
    }

    func checkForUpdateInformation(
        _ sender: Any?,
        statusHandler: @escaping (SparkleManualUpdateCheckState) -> Void
    ) {
        senderDescriptions.append((sender as? NSObject)?.description ?? "<nil>")
        manualStates.forEach(statusHandler)
    }
}

private final class ImmediateSuccessFeedbackSubmitter: FeedbackSubmitting {
    func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        idempotencyKey: String
    ) async throws -> FeedbackSubmissionResult {
        FeedbackSubmissionResult(id: "feedback-success", message: "ok")
    }
}

private final class RecordingInstalledUpdateReleaseNotesPresenter: InstalledUpdateReleaseNotesPresenting {
    var presentedVersions: [String] = []
    var presentedReleaseNotes: [String] = []

    func showInstalledUpdateReleaseNotes(version: String, releaseNotes: String) {
        presentedVersions.append(version)
        presentedReleaseNotes.append(releaseNotes)
    }
}

private final class RecordingRunningTunnelTerminationConfirmation: RunningTunnelTerminationConfirming {
    private let shouldTerminate: Bool
    private(set) var requestedCounts: [Int] = []

    init(shouldTerminate: Bool) {
        self.shouldTerminate = shouldTerminate
    }

    func confirmTerminationWithRunningTunnels(count: Int, parentWindow: NSWindow?) -> Bool {
        requestedCounts.append(count)
        return shouldTerminate
    }
}

private final class RecordingApplicationLogStore: StacioLogWriting {
    var lines: [String] = []

    func append(level: StacioLogLevel, category: String, message: String, sensitiveValues: [String]) {
        lines.append("[\(level.rawValue.uppercased())] [\(category)] \(message)")
    }
}

@MainActor
private final class RecordingLicenseRevalidator: LicenseRevalidating, LicenseNetworkUnavailableHandling {
    private let outcome: LicenseRevalidationOutcome
    private(set) var launchCount = 0
    private(set) var networkRestoreCount = 0
    private(set) var networkUnavailableCount = 0

    init(outcome: LicenseRevalidationOutcome = .noActivation) {
        self.outcome = outcome
    }

    func revalidateOnLaunch() async throws -> LicenseRevalidationOutcome {
        launchCount += 1
        return outcome
    }

    func revalidateAfterNetworkRestore() async throws -> LicenseRevalidationOutcome {
        networkRestoreCount += 1
        return outcome
    }

    func markNetworkUnavailable() async throws -> LicenseRevalidationOutcome {
        networkUnavailableCount += 1
        return .networkUnavailable(LicenseState(status: .networkUnavailable))
    }
}

private final class RecordingLicenseNetworkMonitor: LicenseNetworkStatusMonitoring {
    private var restoreHandler: (() -> Void)?
    private var unavailableHandler: (() -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(onNetworkRestored: @escaping () -> Void) {
        start(onNetworkRestored: onNetworkRestored, onNetworkUnavailable: {})
    }

    func start(
        onNetworkRestored: @escaping () -> Void,
        onNetworkUnavailable: @escaping () -> Void
    ) {
        startCount += 1
        restoreHandler = onNetworkRestored
        unavailableHandler = onNetworkUnavailable
    }

    func cancel() {
        cancelCount += 1
        restoreHandler = nil
        unavailableHandler = nil
    }

    func simulateNetworkRestore() {
        restoreHandler?()
    }

    func simulateNetworkUnavailable() {
        unavailableHandler?()
    }
}
