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
        createdController = nil
        XCTAssertNotNil(weakController)
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
        XCTAssertTrue(joinedLogs.contains("version=Stacio-0.13.3"))
    }

    func testApplicationLaunchRevalidatesLicenseAndStartsNetworkMonitoring() async {
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
        for _ in 0..<100 where revalidator.launchCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(revalidator.launchCount, 1)
        XCTAssertEqual(revalidator.networkRestoreCount, 0)
        XCTAssertEqual(networkMonitor.startCount, 1)
    }

    func testApplicationRevalidatesLicenseAfterNetworkRestoreAndStopsMonitorOnTermination() async {
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
        for _ in 0..<100 where revalidator.networkRestoreCount == 0 {
            await Task.yield()
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(revalidator.networkRestoreCount, 1)
        XCTAssertEqual(networkMonitor.cancelCount, 1)
    }

    func testApplicationMarksLicenseNetworkUnavailableDuringRuntimeDisconnect() async {
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
        for _ in 0..<100 where revalidator.networkUnavailableCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(revalidator.networkUnavailableCount, 1)
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
        XCTAssertEqual(content?.displayVersion, "Stacio-0.13.3")
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
            displayVersion: "Stacio-0.13.3",
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
    private(set) var launchCount = 0
    private(set) var networkRestoreCount = 0
    private(set) var networkUnavailableCount = 0

    func revalidateOnLaunch() async throws -> LicenseRevalidationOutcome {
        launchCount += 1
        return .noActivation
    }

    func revalidateAfterNetworkRestore() async throws -> LicenseRevalidationOutcome {
        networkRestoreCount += 1
        return .noActivation
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
