import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class IndependentFileTransferBrowserViewControllerTests: XCTestCase {
    func testIndependentBrowserDefaultsToNativeColumnsLayoutControl() throws {
        let defaults = makeIsolatedDefaults()
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_layout_default",
            defaults: defaults
        )

        browser.loadView()

        XCTAssertEqual(browser.layoutModeForTesting, .columns)
        XCTAssertEqual(browser.layoutControlForTesting.segmentCount, 2)
        XCTAssertEqual(browser.layoutControlForTesting.selectedSegment, 0)
        XCTAssertTrue(browser.view is StacioAppearanceRefreshView)
        XCTAssertEqual(
            browser.layoutControlForTesting.accessibilityIdentifier(),
            "Stacio.FileTransferBrowser.layoutControl"
        )
        XCTAssertEqual(browser.fileTransferSplitViewForTesting.arrangedSubviews.count, 2)
        let addRemoteDeviceButton = try XCTUnwrap(
            browser.view.firstDescendant(
                accessibilityIdentifier: "Stacio.FileTransferBrowser.addRemoteDevice"
            ) as? NSButton
        )
        XCTAssertEqual(addRemoteDeviceButton.title, "连接远端设备")
        XCTAssertEqual(addRemoteDeviceButton.toolTip, "连接更多远端设备")
        let layoutBar = try XCTUnwrap(
            browser.view.firstDescendant(
                accessibilityIdentifier: "Stacio.FileTransferBrowser.layoutBar"
            ) as? NSVisualEffectView
        )
        XCTAssertEqual(layoutBar.material, .headerView)
        XCTAssertEqual(layoutBar.blendingMode, .withinWindow)
        XCTAssertEqual(layoutBar.state, .active)
    }

    func testIndependentBrowserPersistsGridLayoutChoice() throws {
        let defaults = makeIsolatedDefaults()
        let firstBrowser = makeIndependentBrowser(
            runtimeID: "sftp_layout_persist_first",
            defaults: defaults
        )
        firstBrowser.loadView()

        firstBrowser.setLayoutModeForTesting(.grid)

        let restoredBrowser = makeIndependentBrowser(
            runtimeID: "sftp_layout_persist_restored",
            defaults: defaults
        )
        restoredBrowser.loadView()

        XCTAssertEqual(restoredBrowser.layoutModeForTesting, .grid)
        XCTAssertEqual(restoredBrowser.layoutControlForTesting.selectedSegment, 1)
    }

    func testRestoringSavedGridWorkspaceDoesNotChangeNewSessionLayoutPreference() throws {
        let defaults = makeIsolatedDefaults()
        let restoredGroupBrowser = makeIndependentBrowser(
            runtimeID: "sftp_layout_group_restore",
            defaults: defaults
        )
        restoredGroupBrowser.loadView()

        restoredGroupBrowser.restoreWorkspace(
            additionalLocalDirectoryPaths: [],
            layout: .grid
        )

        let newSessionBrowser = makeIndependentBrowser(
            runtimeID: "sftp_layout_after_group_restore",
            defaults: defaults
        )
        newSessionBrowser.loadView()

        XCTAssertEqual(restoredGroupBrowser.layoutModeForTesting, .grid)
        XCTAssertEqual(newSessionBrowser.layoutModeForTesting, .columns)
        XCTAssertEqual(newSessionBrowser.fileTransferSplitViewForTesting.arrangedSubviews.count, 2)
    }

    func testIndependentBrowserGridPlacesLocalFirstAndThreeRemotesInTwoByTwo() throws {
        let defaults = makeIsolatedDefaults()
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_layout_grid_primary",
            defaults: defaults,
            bridge: bridge
        )
        browser.loadView()
        _ = browser.addRemotePane(
            runtimeID: "sftp_layout_grid_second",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        _ = browser.addRemotePane(
            runtimeID: "scp_layout_grid_third",
            context: Self.liveContext(host: "archive.example.com"),
            title: "归档服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)

        browser.setLayoutModeForTesting(.grid)
        browser.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(browser.workspacePaneCountForTesting, 4)
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 3)
        XCTAssertEqual(browser.gridColumnCountForTesting, 2)
        XCTAssertEqual(browser.gridRowCountForTesting, 2)
        let frames = browser.workspacePaneFramesForTesting
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].minX, frames[2].minX, accuracy: 1)
        XCTAssertEqual(frames[1].minX, frames[3].minX, accuracy: 1)
        XCTAssertGreaterThan(frames[0].minY, frames[2].minY)
        XCTAssertGreaterThan(frames[1].minY, frames[3].minY)
    }

    func testIndependentBrowserGridAdaptsFromTwoToThreePanes() throws {
        let defaults = makeIsolatedDefaults()
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_layout_grid_adaptive",
            defaults: defaults,
            bridge: bridge
        )
        browser.loadView()
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)

        browser.setLayoutModeForTesting(.grid)
        browser.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(browser.workspacePaneCountForTesting, 2)
        XCTAssertEqual(browser.gridColumnCountForTesting, 2)
        XCTAssertEqual(browser.gridRowCountForTesting, 1)

        _ = browser.addRemotePane(
            runtimeID: "sftp_layout_grid_adaptive_second",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        browser.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(browser.workspacePaneCountForTesting, 3)
        XCTAssertEqual(browser.gridColumnCountForTesting, 2)
        XCTAssertEqual(browser.gridRowCountForTesting, 2)
        let frames = browser.workspacePaneFramesForTesting
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
        XCTAssertGreaterThan(frames[0].minY, frames[2].minY)
    }

    func testAddedRemotePaneCanCloseAndDisconnectOnlyItsRuntime() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_close_added_primary",
            context: Self.liveContext(host: "primary.example.com"),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_close_added_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.loadView()
        let addedPane = browser.addRemotePane(
            runtimeID: "scp_close_added_remote",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialLoadPresentation: .immediate
        )
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)
        browser.view.layoutSubtreeIfNeeded()

        let closeButton = try XCTUnwrap(
            addedPane.view.firstDescendant(
                accessibilityIdentifier: "Stacio.FileTransferBrowser.closeRemotePane"
            ) as? NSButton
        )
        XCTAssertEqual(closeButton.frame.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(closeButton.toolTip, "关闭此远端设备")

        closeButton.performClick(nil)

        XCTAssertEqual(scheduler.disconnectedRuntimeIDs, ["scp_close_added_remote"])
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 1)
        XCTAssertEqual(browser.workspacePaneCountForTesting, 2)
        XCTAssertFalse(browser.isFilesWorkspaceHiddenForTesting)
    }

    func testAddedLocalPaneCanCloseWithoutClosingSession() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_close_local_primary",
            context: Self.liveContext(),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_close_local_base",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.loadView()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioClosableLocalPane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let addedPane = browser.addLocalDirectoryPane(directory)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)
        browser.view.layoutSubtreeIfNeeded()

        let closeButton = try XCTUnwrap(
            addedPane.view.firstDescendant(
                accessibilityIdentifier: "Stacio.FileTransferBrowser.closeLocalPane"
            ) as? NSButton
        )
        XCTAssertEqual(closeButton.frame.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(closeButton.toolTip, "关闭此本地目录")

        closeButton.performClick(nil)

        XCTAssertTrue(scheduler.disconnectedRuntimeIDs.isEmpty)
        XCTAssertEqual(browser.localFilesViewControllersForTesting.count, 1)
        XCTAssertEqual(browser.workspacePaneCountForTesting, 2)
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 1)
    }

    func testIndependentBrowserColumnsKeepAllPanesInConnectionOrder() throws {
        let defaults = makeIsolatedDefaults()
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_layout_columns_primary",
            defaults: defaults,
            bridge: bridge
        )
        browser.loadView()
        let second = browser.addRemotePane(
            runtimeID: "sftp_layout_columns_second",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        let third = browser.addRemotePane(
            runtimeID: "scp_layout_columns_third",
            context: Self.liveContext(host: "archive.example.com"),
            title: "归档服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )

        browser.setLayoutModeForTesting(.columns)

        let arrangedSubviews = browser.fileTransferSplitViewForTesting.arrangedSubviews
        XCTAssertEqual(arrangedSubviews.count, 4)
        XCTAssertTrue(arrangedSubviews[0] === browser.localFilesViewController.view)
        XCTAssertTrue(arrangedSubviews[1] === browser.remoteFilesViewController.view.superview)
        XCTAssertTrue(arrangedSubviews[2] === second.view)
        XCTAssertTrue(arrangedSubviews[3] === third.view)
    }

    func testSwitchingFourPaneWorkspaceFromGridToColumnsDistributesEqualWidths() throws {
        let defaults = makeIsolatedDefaults()
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_layout_columns_equal_widths",
            defaults: defaults,
            bridge: bridge
        )
        browser.loadView()
        _ = browser.addRemotePane(
            runtimeID: "sftp_layout_columns_equal_second",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        _ = browser.addRemotePane(
            runtimeID: "sftp_layout_columns_equal_third",
            context: Self.liveContext(host: "archive.example.com"),
            title: "归档服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        browser.setLayoutModeForTesting(.grid)
        browser.view.layoutSubtreeIfNeeded()

        browser.setLayoutModeForTesting(.columns)
        browser.view.layoutSubtreeIfNeeded()

        let widths = browser.fileTransferSplitViewForTesting.arrangedSubviews.map(\.frame.width)
        XCTAssertEqual(widths.count, 4)
        for width in widths.dropFirst() {
            XCTAssertEqual(width, widths[0], accuracy: 1)
        }
    }

    func testBrowserOffersSavedUnattachedRemoteDevicesAndRequestsConnection() {
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_saved_device_primary",
            defaults: makeIsolatedDefaults()
        )
        browser.markPrimaryRemoteDevice(sessionID: "primary-session")
        browser.remoteDeviceOptionsProvider = {
            [
                FileTransferRemoteDeviceOption(
                    sessionID: "primary-session",
                    title: "生产服务器",
                    protocolName: "SFTP",
                    endpoint: "deploy@prod.example.com:22"
                ),
                FileTransferRemoteDeviceOption(
                    sessionID: "backup-session",
                    title: "备份服务器",
                    protocolName: "SCP",
                    endpoint: "backup.example.com:22"
                ),
                FileTransferRemoteDeviceOption(
                    sessionID: "archive-session",
                    title: "归档服务器",
                    protocolName: "SFTP",
                    endpoint: "archive.example.com:22"
                )
            ]
        }
        var requestedSessionID: String?
        var requestedProtocol: String?
        browser.onRequestConnectRemoteDevice = { requestedSessionID = $0 }
        browser.onRequestCreateRemoteDevice = { requestedProtocol = $0 }

        XCTAssertEqual(browser.availableRemoteDeviceSessionIDsForTesting, ["archive-session"])
        XCTAssertEqual(
            browser.addRemoteDeviceMenuTitlesForTesting,
            ["归档服务器 · archive.example.com:22 (SFTP)", "新建 SFTP 连接..."]
        )

        browser.requestRemoteDeviceConnectionForTesting(sessionID: "archive-session")
        browser.requestRemoteDeviceCreationForTesting()
        XCTAssertEqual(requestedSessionID, "archive-session")
        XCTAssertEqual(requestedProtocol, "SFTP")
    }

    func testClosingAttachedSavedSessionRestoresMenuAndAllowsReconnectWithoutAffectingOtherDevices() {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "sftp_saved_device_close_primary",
            context: Self.liveContext(host: "primary.example.com"),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "sftp_saved_device_close_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.markPrimaryRemoteDevice(sessionID: "primary-session")
        browser.remoteDeviceOptionsProvider = {
            [
                FileTransferRemoteDeviceOption(
                    sessionID: "primary-session",
                    title: "生产服务器",
                    protocolName: "SFTP",
                    endpoint: "deploy@primary.example.com:22"
                ),
                FileTransferRemoteDeviceOption(
                    sessionID: "backup-session",
                    title: "备份服务器",
                    protocolName: "SFTP",
                    endpoint: "backup.example.com:22"
                ),
                FileTransferRemoteDeviceOption(
                    sessionID: "archive-session",
                    title: "归档服务器",
                    protocolName: "SFTP",
                    endpoint: "archive.example.com:22"
                )
            ]
        }
        let configuration = FileTransferRemotePaneConfiguration(
            sourceRuntimeID: "saved:backup-session",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            remoteFilePathTerminalSender: { _ in }
        )
        browser.loadView()

        let attachedPane = browser.attachRemoteDevice(configuration)

        XCTAssertEqual(browser.availableRemoteDeviceSessionIDsForTesting, ["archive-session"])
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 2)

        attachedPane.remoteFilesViewController.onRequestClose?()

        XCTAssertEqual(
            browser.availableRemoteDeviceSessionIDsForTesting,
            ["backup-session", "archive-session"]
        )
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 1)
        XCTAssertEqual(scheduler.disconnectedRuntimeIDs.count, 1)
        XCTAssertTrue(browser.addRemoteDeviceMenuTitlesForTesting.contains {
            $0.contains("备份服务器")
        })
        XCTAssertFalse(browser.availableRemoteDeviceSessionIDsForTesting.contains("primary-session"))

        let reattachedPane = browser.attachRemoteDevice(configuration)

        XCTAssertFalse(reattachedPane === attachedPane)
        XCTAssertEqual(browser.availableRemoteDeviceSessionIDsForTesting, ["archive-session"])
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 2)
    }

    func testClosingOneOfTwoPanesForSameSavedSessionKeepsDeviceAttachedUntilLastPaneCloses() {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "sftp_shared_source_primary",
            context: Self.liveContext(host: "primary.example.com"),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "sftp_shared_source_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.remoteDeviceOptionsProvider = {
            [
                FileTransferRemoteDeviceOption(
                    sessionID: "backup-session",
                    title: "备份服务器",
                    protocolName: "SFTP",
                    endpoint: "backup.example.com:22"
                )
            ]
        }
        let configuration = FileTransferRemotePaneConfiguration(
            sourceRuntimeID: "saved:backup-session",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            remoteFilePathTerminalSender: { _ in }
        )
        browser.loadView()

        let firstPane = browser.attachRemoteDevice(configuration)
        let secondPane = browser.attachRemoteDevice(configuration)

        XCTAssertTrue(browser.availableRemoteDeviceSessionIDsForTesting.isEmpty)
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 3)

        firstPane.remoteFilesViewController.onRequestClose?()

        XCTAssertTrue(browser.availableRemoteDeviceSessionIDsForTesting.isEmpty)
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 2)

        secondPane.remoteFilesViewController.onRequestClose?()

        XCTAssertEqual(browser.availableRemoteDeviceSessionIDsForTesting, ["backup-session"])
        XCTAssertEqual(browser.remoteFilesViewControllersForTesting.count, 1)
        XCTAssertEqual(scheduler.disconnectedRuntimeIDs.count, 2)
    }

    func testLayoutBarAddsVisibleLocalDirectoryPaneAlongsideRemoteDevices() throws {
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_add_local_directory",
            defaults: makeIsolatedDefaults()
        )
        browser.loadView()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAdditionalLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(browser.addLocalDirectoryButtonForTesting.title, "添加本地目录")
        XCTAssertTrue(browser.addLocalDirectoryButtonForTesting.imageHugsTitle)
        XCTAssertTrue(browser.addRemoteDeviceButtonForTesting.imageHugsTitle)
        XCTAssertEqual(
            browser.addLocalDirectoryButtonForTesting.accessibilityIdentifier(),
            "Stacio.FileTransferBrowser.addLocalDirectory"
        )

        browser.addLocalDirectoryForTesting(directory)

        XCTAssertEqual(browser.localFilesViewControllersForTesting.count, 2)
        XCTAssertEqual(browser.localFilesViewControllersForTesting.last?.directoryURL, directory)
        XCTAssertEqual(browser.workspacePaneCountForTesting, 3)
    }

    func testFileTransferWorkspaceBuildsRestorableGroupFromCurrentPaneLayout() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        bridge.entriesByPath["/srv/backup"] = []
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_group_primary",
            defaults: makeIsolatedDefaults(),
            bridge: bridge
        )
        browser.loadView()
        browser.markPrimaryRemoteDevice(sessionID: "primary-session")
        let extraDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioGroupLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extraDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extraDirectory) }
        _ = browser.addLocalDirectoryPane(extraDirectory)
        _ = browser.addRemotePane(
            runtimeID: "sftp_group_backup_runtime",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "/srv/backup",
            initialLoadPresentation: .immediate,
            sourceRuntimeID: "saved:backup-session"
        )
        browser.setLayoutModeForTesting(.grid)

        let definition = try XCTUnwrap(browser.workspaceSessionGroupDefinitionForTesting)

        XCTAssertEqual(definition.kind, .sftp)
        XCTAssertEqual(definition.layout, .grid)
        XCTAssertEqual(definition.panes.map(\.kind), [
            .localDirectory,
            .localDirectory,
            .remoteSession,
            .remoteSession
        ])
        XCTAssertEqual(definition.panes.compactMap(\.sessionID), ["primary-session", "backup-session"])
        XCTAssertEqual(definition.panes.last?.path, "/srv/backup")
        XCTAssertTrue(definition.shouldOfferSaveOnClose)
    }

    func testAdvancedContextMenusOfferDeviceAwareTransferTargetsAndExcludeCurrentDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAdvancedMenus-\(UUID().uuidString)", isDirectory: true)
        let primaryLocalDirectory = root.appendingPathComponent("primary", isDirectory: true)
        let secondaryLocalDirectory = root.appendingPathComponent("secondary", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryLocalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondaryLocalDirectory, withIntermediateDirectories: true)
        try Data("local".utf8).write(to: primaryLocalDirectory.appendingPathComponent("local.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = [
            RemoteFileEntry(
                kind: .file,
                path: "~/remote.txt",
                size: 6,
                modifiedTime: nil,
                linkTarget: nil,
                owner: "deploy",
                permissions: "0644"
            )
        ]
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_advanced_primary",
            context: Self.liveContext(host: "prod.example.com"),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: IndependentSCPTransferScheduler(),
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "local_advanced_primary",
                directoryURL: primaryLocalDirectory,
                title: "本地文件"
            )
        )
        browser.loadView()
        _ = browser.addLocalDirectoryPane(secondaryLocalDirectory)
        let secondaryRemote = browser.addRemotePane(
            runtimeID: "scp_advanced_backup",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: IndependentSCPTransferScheduler(),
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        XCTAssertTrue(waitUntil { browser.remoteFilesViewController.tableView.numberOfRows == 1 })
        browser.localFilesViewController.selectLocalItemsForTesting(named: ["local.txt"])
        browser.remoteFilesViewController.tableView.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )

        let localTitles = browser.localFilesViewController.contextMenuTitlesForTesting(row: 0)
        XCTAssertTrue(localTitles.contains("复制"))
        XCTAssertTrue(localTitles.contains("剪切"))
        XCTAssertTrue(localTitles.contains("粘贴"))
        XCTAssertTrue(localTitles.contains("传输到"))
        XCTAssertTrue(localTitles.contains("重命名..."))
        XCTAssertTrue(localTitles.contains("移到废纸篓"))
        XCTAssertTrue(localTitles.contains("属性..."))
        XCTAssertTrue(localTitles.contains("权限..."))
        XCTAssertTrue(localTitles.contains("新建文件夹"))
        XCTAssertTrue(localTitles.contains("刷新"))
        let localTargets = browser.localFilesViewController.transferTargetMenuTitlesForTesting(row: 0)
        XCTAssertTrue(localTargets.contains { $0.contains("生产服务器") })
        XCTAssertTrue(localTargets.contains { $0.contains("备份服务器") })
        XCTAssertTrue(localTargets.contains { $0.contains("secondary") })
        XCTAssertFalse(localTargets.contains { $0.contains("primary") })

        let remoteTitles = browser.remoteFilesViewController.contextMenuTitlesForTesting(row: 0)
        XCTAssertTrue(remoteTitles.contains("复制"))
        XCTAssertTrue(remoteTitles.contains("剪切"))
        XCTAssertTrue(remoteTitles.contains("粘贴"))
        XCTAssertTrue(remoteTitles.contains("传输到"))
        XCTAssertTrue(remoteTitles.contains("重命名..."))
        XCTAssertTrue(remoteTitles.contains("删除"))
        XCTAssertTrue(remoteTitles.contains("属性..."))
        XCTAssertTrue(remoteTitles.contains("权限..."))
        XCTAssertTrue(remoteTitles.contains("刷新"))
        let remoteTargets = browser.remoteFilesViewController.transferTargetMenuTitlesForTesting(row: 0)
        XCTAssertTrue(remoteTargets.contains { $0.contains("primary") })
        XCTAssertTrue(remoteTargets.contains { $0.contains("secondary") })
        XCTAssertTrue(remoteTargets.contains { $0.contains("备份服务器") })
        XCTAssertFalse(remoteTargets.contains { $0.contains("生产服务器") })

        let secondaryTargets = secondaryRemote.remoteFilesViewController
            .transferTargetMenuTitlesForTesting(row: -1)
        XCTAssertTrue(secondaryTargets.contains { $0.contains("生产服务器") })
        XCTAssertFalse(secondaryTargets.contains { $0.contains("备份服务器") })
    }

    func testLocalContextMenuCreatesDirectoryInCurrentLocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalNewFolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = LocalFilePaneViewController(
            runtimeID: "local_new_folder",
            directoryURL: root,
            title: "本地文件"
        )
        pane.loadView()

        pane.performCreateDirectoryForTesting(named: "部署资料")

        let created = root.appendingPathComponent("部署资料", isDirectory: true)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: created.path) })
        XCTAssertTrue(waitUntil { pane.visibleTextSnapshotForTesting.contains("部署资料") })
    }

    func testWorkspaceClipboardPreservesCopyAndCutSourcesWithoutMixingDevices() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StacioClipboard.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        let localURL = URL(fileURLWithPath: "/tmp/local.txt")

        clipboard.storeLocalURLs([localURL], operation: .copy, sourceDeviceID: "local-one")

        XCTAssertEqual(clipboard.payload?.operation, .copy)
        XCTAssertEqual(clipboard.payload?.sourceDeviceID, "local-one")
        XCTAssertEqual(clipboard.payload?.localURLs, [localURL])
        XCTAssertEqual(clipboard.payload?.remoteSelections, [])

        let remote = RemoteFileSelection(path: "~/remote.txt", size: 10)
        clipboard.storeRemoteSelections([remote], operation: .cut, sourceDeviceID: "remote-one")

        XCTAssertEqual(clipboard.payload?.operation, .cut)
        XCTAssertEqual(clipboard.payload?.sourceDeviceID, "remote-one")
        XCTAssertEqual(clipboard.payload?.localURLs, [])
        XCTAssertEqual(clipboard.payload?.remoteSelections, [remote])
    }

    func testLocalFileURLDropCopiesIntoAnotherLocalPane() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalDragSource-\(UUID().uuidString)", isDirectory: true)
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalDragDestination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceURL = sourceDirectory.appendingPathComponent("large-transfer.bin")
        try Data("payload".utf8).write(to: sourceURL)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StacioLocalDrag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sourceURL as NSURL]))
        let pane = LocalFilePaneViewController(
            runtimeID: "local-drop-destination",
            directoryURL: destinationDirectory,
            title: "本地文件"
        )
        pane.loadView()

        let urls = LocalFileDragPayload.urls(from: pasteboard)
        XCTAssertEqual(urls, [sourceURL.standardizedFileURL])
        XCTAssertTrue(pane.acceptLocalFileDrop(urls, destination: destinationDirectory))

        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: destinationURL.path)
        })
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("payload".utf8))
    }

    func testWorkspaceClipboardInvalidatesOwnedCutAfterExternalPasteboardChange() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StacioClipboard.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        let localURL = URL(fileURLWithPath: "/tmp/cut-source.txt")
        clipboard.storeLocalURLs([localURL], operation: .cut, sourceDeviceID: "local-one")

        pasteboard.clearContents()
        pasteboard.setString("external clipboard value", forType: .string)

        XCTAssertNil(clipboard.payload)
        XCTAssertNil(clipboard.resolvedPayload())
        clipboard.clear()
        XCTAssertEqual(pasteboard.string(forType: .string), "external clipboard value")
    }

    func testLocalCutPasteClearsClipboardOnlyAfterEntireMoveCompletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalCutPaste-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = sourceDirectory.appendingPathComponent("report.txt")
        let destinationURL = destinationDirectory.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: sourceURL)
        try Data("old".utf8).write(to: destinationURL)
        let pasteboard = NSPasteboard(name: .init("StacioLocalCutPaste.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeLocalURLs([sourceURL], operation: .cut, sourceDeviceID: "local-source")
        let conflictResolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false)
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "local-cut-primary",
            context: Self.liveContext(),
            title: "服务器",
            bridge: IndependentTransferBrowserBridge(),
            transferScheduler: nil,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "local-source",
                directoryURL: sourceDirectory,
                title: "源目录"
            ),
            workspaceClipboard: clipboard,
            conflictResolver: conflictResolver
        )
        browser.loadView()
        let destinationPane = browser.addLocalDirectoryPane(destinationDirectory)

        destinationPane.performPasteForTesting()

        XCTAssertTrue(conflictResolver.waitUntilRequested())
        XCTAssertNotNil(clipboard.payload)
        conflictResolver.resume()
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: sourceURL.path) == false
                && (try? Data(contentsOf: destinationURL)) == Data("new".utf8)
                && clipboard.payload == nil
        })
    }

    func testLocalCutPastePreservesClipboardWhenBatchIsPartiallySkipped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalCutPartial-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skippedSource = sourceDirectory.appendingPathComponent("existing.txt")
        let movedSource = sourceDirectory.appendingPathComponent("fresh.txt")
        try Data("source".utf8).write(to: skippedSource)
        try Data("fresh".utf8).write(to: movedSource)
        try Data("destination".utf8).write(
            to: destinationDirectory.appendingPathComponent("existing.txt")
        )
        let pasteboard = NSPasteboard(name: .init("StacioLocalCutPartial.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeLocalURLs(
            [skippedSource, movedSource],
            operation: .cut,
            sourceDeviceID: "local-partial-source"
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "local-partial-primary",
            context: Self.liveContext(),
            title: "服务器",
            bridge: IndependentTransferBrowserBridge(),
            transferScheduler: nil,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "local-partial-source",
                directoryURL: sourceDirectory,
                title: "源目录"
            ),
            workspaceClipboard: clipboard,
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .skip, applyToAll: false),
                startsBlocked: false
            )
        )
        browser.loadView()
        let destinationPane = browser.addLocalDirectoryPane(destinationDirectory)

        destinationPane.performPasteForTesting()

        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(
                atPath: destinationDirectory.appendingPathComponent("fresh.txt").path
            )
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: skippedSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedSource.path))
        XCTAssertNotNil(clipboard.payload)
    }

    func testFileWorkspaceUsesMacOS27DimensionsAndRefreshesDynamicAppearance() throws {
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_workspace_geometry",
            defaults: makeIsolatedDefaults()
        )
        browser.loadView()
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 760)
        browser.view.layoutSubtreeIfNeeded()

        let layoutBar = try XCTUnwrap(
            browser.view.firstDescendant(
                accessibilityIdentifier: "Stacio.FileTransferBrowser.layoutBar"
            )
        )
        XCTAssertEqual(layoutBar.frame.height, 36, accuracy: 0.5)
        XCTAssertEqual(browser.layoutControlForTesting.frame.height, 28, accuracy: 0.5)
        XCTAssertEqual(browser.addRemoteDeviceButtonForTesting.frame.height, 28, accuracy: 0.5)
        XCTAssertEqual(browser.addLocalDirectoryButtonForTesting.frame.height, 28, accuracy: 0.5)
        let expectedLocalButtonSizes = Array(
            repeating: NSSize(width: 28, height: 28),
            count: browser.localFilesViewController.toolbarIconButtonSizesForTesting.count
        )
        XCTAssertEqual(
            browser.localFilesViewController.toolbarIconButtonSizesForTesting,
            expectedLocalButtonSizes
        )
        let expectedRemoteButtonSizes = Array(
            repeating: NSSize(width: 28, height: 28),
            count: browser.remoteFilesViewController.toolbarIconButtonSizesForTesting.count
        )
        XCTAssertEqual(
            browser.remoteFilesViewController.toolbarIconButtonSizesForTesting,
            expectedRemoteButtonSizes
        )

        let grid = try XCTUnwrap(
            browser.view.firstDescendant(
                accessibilityIdentifier: "Stacio.FileTransferBrowser.grid"
            )
        )
        browser.view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        StacioDesignSystem.refreshDynamicLayerColors(in: browser.view)
        let lightGridColor = try XCTUnwrap(grid.layer?.backgroundColor)
        browser.view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        StacioDesignSystem.refreshDynamicLayerColors(in: browser.view)
        let darkGridColor = try XCTUnwrap(grid.layer?.backgroundColor)
        XCTAssertNotEqual(lightGridColor, darkGridColor)
    }

    func testLocalAndRemoteFileRowsUseMatchingTypographyAndIconDimensions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioMatchingFileRows-\(UUID().uuidString)", isDirectory: true)
        let localFolder = directory.appendingPathComponent("z-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = LocalFilePaneViewController(
            runtimeID: "matching_file_rows_local",
            directoryURL: directory,
            title: "本地文件"
        )
        local.loadView()
        XCTAssertTrue(waitUntil { local.displayedItemNamesForTesting == ["z-folder"] })

        let remote = IndependentRemoteFilesViewController(
            title: "生产服务器",
            protocolName: "SFTP",
            initialPath: "~"
        )
        remote.loadView()
        remote.setEntries([
            RemoteFileEntry(kind: .directory, path: "~/z-folder", size: 0, linkTarget: nil)
        ], path: "~")

        let localCell = try XCTUnwrap(local.tableView(
            local.tableView,
            viewFor: local.tableView.tableColumns[0],
            row: 0
        ) as? NSTableCellView)
        let remoteCell = try XCTUnwrap(remote.tableView(
            remote.tableView,
            viewFor: remote.tableView.tableColumns[0],
            row: 0
        ) as? NSTableCellView)

        XCTAssertEqual(local.tableView.rowHeight, remote.tableView.rowHeight)
        XCTAssertEqual(localCell.textField?.font?.pointSize, remoteCell.textField?.font?.pointSize)
        XCTAssertEqual(localCell.imageView?.image?.size, remoteCell.imageView?.image?.size)
        XCTAssertEqual(remoteCell.imageView?.image?.size.width, StacioFileDisplay.iconDimension)
        XCTAssertEqual(local.tableView.tableColumns.map(\.title), ["名称", "大小", "时间"])
        XCTAssertEqual(
            remote.tableView.tableColumns.compactMap { column in
                column.sortDescriptorPrototype == nil ? nil : column.title
            },
            ["名称", "大小", "时间"]
        )
    }

    func testLocalFileHeadersToggleNameSizeAndTimeSortingWithoutLosingSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalHeaderSort-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("z-folder", isDirectory: true)
        let alpha = directory.appendingPathComponent("alpha.txt")
        let beta = directory.appendingPathComponent("beta.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: alpha)
        try Data(repeating: 0x42, count: 20).write(to: beta)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: alpha.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: beta.path
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = LocalFilePaneViewController(
            runtimeID: "local_header_sort",
            directoryURL: directory,
            title: "本地文件"
        )
        pane.loadView()
        XCTAssertTrue(waitUntil { pane.displayedItemNamesForTesting.count == 3 })
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])
        XCTAssertTrue(pane.tableView.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })

        pane.sortColumnForTesting(identifier: "name")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "beta.txt", "alpha.txt"])
        pane.sortColumnForTesting(identifier: "name")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])

        pane.selectLocalItemsForTesting(named: ["alpha.txt"])
        pane.sortColumnForTesting(identifier: "size")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])
        pane.sortColumnForTesting(identifier: "size")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "beta.txt", "alpha.txt"])
        let selectedIndex = try XCTUnwrap(pane.tableView.selectedRowIndexes.first)
        XCTAssertEqual(pane.displayedItemNamesForTesting[selectedIndex], "alpha.txt")

        pane.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "beta.txt", "alpha.txt"])
        pane.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])
    }

    func testRemoteFileHeadersToggleNameSizeAndTimeSortingWithoutLosingSelection() throws {
        let pane = IndependentRemoteFilesViewController(
            title: "生产服务器",
            protocolName: "SCP",
            initialPath: "~"
        )
        pane.loadView()
        pane.setEntries([
            RemoteFileEntry(
                kind: .file,
                path: "~/beta.txt",
                size: 20,
                modifiedTime: "07-24 10:00",
                linkTarget: nil
            ),
            RemoteFileEntry(
                kind: .directory,
                path: "~/z-folder",
                size: 0,
                modifiedTime: "07-23 10:00",
                linkTarget: nil
            ),
            RemoteFileEntry(
                kind: .file,
                path: "~/alpha.txt",
                size: 10,
                modifiedTime: "07-25 10:00",
                linkTarget: nil
            )
        ], path: "~")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])
        XCTAssertEqual(
            pane.tableView.tableColumns.filter { $0.sortDescriptorPrototype != nil }.map(\.identifier.rawValue),
            ["name", "size", "time"]
        )

        pane.sortColumnForTesting(identifier: "name")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "beta.txt", "alpha.txt"])
        pane.sortColumnForTesting(identifier: "name")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])

        pane.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        pane.sortColumnForTesting(identifier: "size")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])
        pane.sortColumnForTesting(identifier: "size")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "beta.txt", "alpha.txt"])
        let selectedIndex = try XCTUnwrap(pane.tableView.selectedRowIndexes.first)
        XCTAssertEqual(pane.displayedItemNamesForTesting[selectedIndex], "alpha.txt")

        pane.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "beta.txt", "alpha.txt"])
        pane.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["z-folder", "alpha.txt", "beta.txt"])
    }

    func testRemoteTimeHeaderSortsSCPMonthNamesChronologically() {
        let pane = IndependentRemoteFilesViewController(
            title: "生产服务器",
            protocolName: "SCP",
            initialPath: "~"
        )
        pane.loadView()
        pane.setEntries([
            RemoteFileEntry(
                kind: .file,
                path: "~/april.log",
                size: 10,
                modifiedTime: "Apr 1 2025",
                linkTarget: nil
            ),
            RemoteFileEntry(
                kind: .file,
                path: "~/february.log",
                size: 20,
                modifiedTime: "Feb 1 2025",
                linkTarget: nil
            )
        ], path: "~")

        pane.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["february.log", "april.log"])
        pane.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(pane.displayedItemNamesForTesting, ["april.log", "february.log"])
    }

    func testAddedLocalDirectoryPaneUsesSharedDocumentCoordinatorForOpenAndQuickLook() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAddedPaneDocuments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("notes.txt")
        let archiveURL = directory.appendingPathComponent("bundle.zip")
        try Data("notes".utf8).write(to: textURL)
        try Data("archive".utf8).write(to: archiveURL)
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_added_local_documents",
            defaults: makeIsolatedDefaults()
        )

        let pane = browser.addLocalDirectoryPane(directory)
        pane.onOpenFile?(textURL)
        pane.onQuickLookURLs?([archiveURL])

        XCTAssertTrue(waitUntil {
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting?
                .editorViewController.tabTitlesForTesting == ["notes.txt"]
        })
        XCTAssertEqual(
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting?
                .editorViewController.tabTitlesForTesting,
            ["notes.txt"]
        )
        XCTAssertEqual(
            browser.documentCoordinatorForTesting.quickLookCoordinatorForTesting.previewURLsForTesting,
            [archiveURL.standardizedFileURL]
        )
        browser.documentCoordinatorForTesting.closeDocumentWindowsForTesting()
    }

    func testLocalDirectoryLoadingDiscardsStaleBackgroundGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalGeneration-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let staleURL = firstDirectory.appendingPathComponent("stale.txt")
        let freshURL = secondDirectory.appendingPathComponent("fresh.txt")
        try Data("stale".utf8).write(to: staleURL)
        try Data("fresh".utf8).write(to: freshURL)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let pane = LocalFilePaneViewController(
            runtimeID: "local_generation",
            directoryURL: firstDirectory,
            title: "本地文件",
            directoryContentsProvider: { directory in
                if directory.standardizedFileURL == firstDirectory.standardizedFileURL {
                    firstStarted.signal()
                    _ = releaseFirst.wait(timeout: .now() + 2)
                    return [staleURL]
                }
                return [freshURL]
            }
        )

        pane.loadView()
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        pane.navigate(to: secondDirectory)
        XCTAssertTrue(waitUntil { pane.visibleTextSnapshotForTesting.contains("fresh.txt") })
        releaseFirst.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("fresh.txt"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("stale.txt"))
        XCTAssertEqual(pane.currentPathForTesting, secondDirectory.path)
    }

    func testFailedTrashOperationPreservesLocalSourceWithoutPermanentDeleteFallback() throws {
        enum TrashFailure: Error { case unavailable }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioTrashSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sourceURL)
        let pane = LocalFilePaneViewController(
            runtimeID: "local_trash_safety",
            directoryURL: directory,
            title: "本地文件",
            trashItem: { _ in throw TrashFailure.unavailable }
        )
        pane.loadView()
        XCTAssertTrue(waitUntil { pane.visibleTextSnapshotForTesting.contains("keep.txt") })
        pane.selectLocalItemsForTesting(named: ["keep.txt"])

        pane.performDeleteForTesting()

        XCTAssertTrue(waitUntil { pane.statusTextForTesting.contains("移到废纸篓失败") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCutToRemoteDeletesSourcesOnlyAfterEveryUploadCompletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCutUploadSuccess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let pasteboard = NSPasteboard(name: .init("StacioCutUpload.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeLocalURLs([first, second], operation: .cut, sourceDeviceID: "local-cut")
        let scheduler = IndependentSCPTransferScheduler()
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "cut-upload-success",
            context: Self.liveContext(),
            title: "服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "cut-upload-local",
                directoryURL: root,
                title: "本地文件"
            ),
            workspaceClipboard: clipboard
        )
        browser.loadView()

        browser.remoteFilesViewController.onPastePayload?(try XCTUnwrap(clipboard.payload), "~")
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 2 })
        scheduler.complete(jobAt: 0, status: "completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotNil(clipboard.payload)

        scheduler.complete(jobAt: 1, status: "completed")
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: first.path) == false
                && FileManager.default.fileExists(atPath: second.path) == false
                && clipboard.payload == nil
        })
    }

    func testCutToRemoteFailurePreservesEverySourceAndClipboard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCutUploadFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let pasteboard = NSPasteboard(name: .init("StacioCutUpload.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeLocalURLs([first, second], operation: .cut, sourceDeviceID: "local-cut")
        let scheduler = IndependentSCPTransferScheduler()
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "cut-upload-failure",
            context: Self.liveContext(),
            title: "服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "cut-upload-local",
                directoryURL: root,
                title: "本地文件"
            ),
            workspaceClipboard: clipboard
        )
        browser.loadView()

        browser.remoteFilesViewController.onPastePayload?(try XCTUnwrap(clipboard.payload), "~")
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 2 })
        scheduler.complete(jobAt: 0, status: "completed")
        scheduler.complete(jobAt: 1, status: "failed")

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotNil(clipboard.payload)
    }

    func testRemoteCutToLocalDeletesSourcesOnlyAfterEveryDownloadedTargetExists() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteCutSuccess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let selections = [
            RemoteFileSelection(path: "~/first.txt", size: 5),
            RemoteFileSelection(path: "~/second.txt", size: 6)
        ]
        let pasteboard = NSPasteboard(name: .init("StacioRemoteCutSuccess.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeRemoteSelections(selections, operation: .cut, sourceDeviceID: "remote-cut-success")
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = selections.map {
            RemoteFileEntry(kind: .file, path: $0.path, size: $0.size, linkTarget: nil)
        }
        let scheduler = IndependentSCPTransferScheduler()
        scheduler.materializesCompletedDownloads = true
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "remote-cut-success",
            context: Self.liveContext(),
            title: "服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "remote-cut-local",
                directoryURL: destination,
                title: "本地文件"
            ),
            workspaceClipboard: clipboard
        )
        browser.loadView()

        browser.localFilesViewController.performPasteForTesting()

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 2 })
        XCTAssertNotNil(clipboard.payload)
        scheduler.complete(jobAt: 0, status: "completed")
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("first.txt").path
            )
        })
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
        XCTAssertNotNil(clipboard.payload)

        scheduler.complete(jobAt: 1, status: "completed")

        XCTAssertTrue(waitUntil {
            bridge.deletedPaths.sorted() == selections.map(\.path).sorted()
                && clipboard.payload == nil
        })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("second.txt").path
        ))
    }

    func testRemoteCutToLocalPartialFailureDeletesNothingAndPreservesClipboard() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteCutPartial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let selections = [
            RemoteFileSelection(path: "~/first.txt", size: 5),
            RemoteFileSelection(path: "~/second.txt", size: 6)
        ]
        let pasteboard = NSPasteboard(name: .init("StacioRemoteCutPartial.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeRemoteSelections(selections, operation: .cut, sourceDeviceID: "remote-cut-partial")
        let bridge = IndependentTransferBrowserBridge()
        let noDelete = expectation(description: "no remote source is deleted")
        noDelete.isInverted = true
        bridge.onDeleteRemotePath = { _ in noDelete.fulfill() }
        let scheduler = IndependentSCPTransferScheduler()
        scheduler.materializesCompletedDownloads = true
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "remote-cut-partial",
            context: Self.liveContext(),
            title: "服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "remote-cut-partial-local",
                directoryURL: destination,
                title: "本地文件"
            ),
            workspaceClipboard: clipboard
        )
        browser.loadView()
        browser.localFilesViewController.performPasteForTesting()
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 2 })

        scheduler.complete(jobAt: 0, status: "completed")
        scheduler.complete(jobAt: 1, status: "failed")

        wait(for: [noDelete], timeout: 0.2)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
        XCTAssertNotNil(clipboard.payload)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("first.txt").path
        ))
    }

    func testRemoteCutToLocalDoesNotDeleteWhenCompletedTargetCannotBeVerified() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteCutUnverified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let selection = RemoteFileSelection(path: "~/missing.txt", size: 7)
        let pasteboard = NSPasteboard(name: .init("StacioRemoteCutUnverified.\(UUID().uuidString)"))
        let clipboard = FileWorkspaceClipboard(pasteboard: pasteboard)
        clipboard.storeRemoteSelections([selection], operation: .cut, sourceDeviceID: "remote-cut-unverified")
        let bridge = IndependentTransferBrowserBridge()
        let noDelete = expectation(description: "unverified download preserves remote source")
        noDelete.isInverted = true
        bridge.onDeleteRemotePath = { _ in noDelete.fulfill() }
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "remote-cut-unverified",
            context: Self.liveContext(),
            title: "服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "remote-cut-unverified-local",
                directoryURL: destination,
                title: "本地文件"
            ),
            workspaceClipboard: clipboard
        )
        browser.loadView()
        browser.localFilesViewController.performPasteForTesting()
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })

        scheduler.complete(jobAt: 0, status: "completed")

        wait(for: [noDelete], timeout: 0.2)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
        XCTAssertNotNil(clipboard.payload)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("missing.txt").path
        ))
    }

    func testRemoteDropRoutesThroughItsSourceRuntimeInsteadOfPrimaryRemote() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let primaryScheduler = IndependentSCPTransferScheduler()
        let secondaryScheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_drop_primary",
            context: Self.liveContext(host: "prod.example.com"),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: primaryScheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_drop_primary_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.loadView()
        let secondaryPane = browser.addRemotePane(
            runtimeID: "scp_drop_secondary",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: secondaryScheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioDrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        browser.performRemoteDropForTesting(
            sourceRuntimeID: secondaryPane.runtimeID,
            selections: [RemoteFileSelection(path: "~/backup.tar", size: 512)],
            to: destination
        )

        XCTAssertTrue(primaryScheduler.jobs.isEmpty)
        XCTAssertEqual(secondaryScheduler.runtimeIDs, [secondaryPane.runtimeID])
        XCTAssertEqual(secondaryScheduler.jobs.map(\.sourcePath), ["~/backup.tar"])
    }

    func testPrimaryRemoteUploadUsesOneApplyToAllConflictSessionAndSkipsBatch() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioPrimaryUploadConflicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let first = localDirectory.appendingPathComponent("first.txt")
        let second = localDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = [
            RemoteFileEntry(kind: .file, path: "~/first.txt", size: 5, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "~/second.txt", size: 6, linkTarget: nil)
        ]
        let scheduler = IndependentSCPTransferScheduler()
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .skip, applyToAll: true),
            startsBlocked: false
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "primary-upload-conflicts",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "primary-upload-local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: resolver
        )
        browser.loadView()
        XCTAssertTrue(waitUntil { bridge.listedSCPPaths.contains("~") })

        browser.performUploadLocalPathsForTesting([first.path, second.path], remoteDirectory: "~")

        XCTAssertTrue(waitUntil { resolver.requestedPaths.count == 1 })
        XCTAssertEqual(resolver.requestedDirections, [.upload])
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testPrimaryRemoteDownloadReplaceStagesThenPromotesToRequestedDestination() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioPrimaryDownloadReplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let destination = localDirectory.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: destination)
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        scheduler.materializesCompletedDownloads = true
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
            startsBlocked: false
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "primary-download-replace",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "primary-download-local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: resolver
        )
        browser.loadView()

        browser.performDownloadSelectionsForTesting(
            [RemoteFileSelection(path: "~/report.txt", size: 6)],
            to: localDirectory
        )

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        XCTAssertEqual(resolver.requestedDirections, [.download])
        let stagePath = try XCTUnwrap(scheduler.jobs.first).destinationPath
        XCTAssertNotEqual(stagePath, destination.path)
        XCTAssertEqual((stagePath as NSString).deletingLastPathComponent, localDirectory.path)
        XCTAssertTrue((stagePath as NSString).lastPathComponent.hasPrefix(".report.txt.stacio-transfer-"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))

        scheduler.complete(jobAt: 0, status: "completed")

        XCTAssertTrue(waitUntil {
            (try? Data(contentsOf: destination)) == Data(repeating: 0x41, count: 6)
                && FileManager.default.fileExists(atPath: stagePath) == false
        })
    }

    func testOverwriteUploadFailurePreservesExistingRemoteDestinationAndCleansStage() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAtomicUploadFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let source = localDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/report.txt", size: 3, linkTarget: nil)
        ]
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_atomic_upload_failure",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "/incoming",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_atomic_upload_failure_local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
                startsBlocked: false
            )
        )
        browser.loadView()

        browser.performUploadLocalPathsForTesting([source.path], remoteDirectory: "/incoming")

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(scheduler.jobs.first?.destinationPath)
        XCTAssertNotEqual(stagePath, "/incoming/report.txt")
        XCTAssertEqual((stagePath as NSString).deletingLastPathComponent, "/incoming")
        XCTAssertTrue((stagePath as NSString).lastPathComponent.hasPrefix(".report.txt.stacio-transfer-"))
        scheduler.complete(jobAt: 0, status: "failed")

        XCTAssertTrue(waitUntil { bridge.deletedPaths.contains(stagePath) })
        XCTAssertFalse(bridge.deletedPaths.contains("/incoming/report.txt"))
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
    }

    func testCompletedOverwriteUploadValidationFailureCleansStageWithoutMutatingDestination() throws {
        let fixture = try makeAtomicUploadFailureFixture(runtimeID: "scp_atomic_upload_validation")
        defer { try? FileManager.default.removeItem(at: fixture.localDirectory) }

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(fixture.scheduler.jobs.first?.destinationPath)
        fixture.scheduler.complete(jobAt: 0, status: "completed")

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.contains(stagePath) })
        XCTAssertEqual(fixture.bridge.deletedPaths, [stagePath])
        XCTAssertTrue(fixture.bridge.renamedPaths.isEmpty)
        XCTAssertFalse(fixture.bridge.deletedPaths.contains("/incoming/report.txt"))
    }

    func testCompletedOverwriteUploadPromotionFailureRollsBackThenCleansStage() throws {
        let fixture = try makeAtomicUploadFailureFixture(runtimeID: "scp_atomic_upload_promotion")
        defer { try? FileManager.default.removeItem(at: fixture.localDirectory) }

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.scheduler.jobs.count == 1 })
        let job = try XCTUnwrap(fixture.scheduler.jobs.first)
        let stagePath = job.destinationPath
        fixture.bridge.entriesByPath["/incoming", default: []].append(
            RemoteFileEntry(kind: .file, path: stagePath, size: job.bytesTotal, linkTarget: nil)
        )
        fixture.bridge.renameErrorsByCallIndex[2] = NSError(
            domain: "StacioTests.AtomicUploadPromotion",
            code: 2
        )
        fixture.scheduler.complete(jobAt: 0, status: "completed")

        XCTAssertTrue(waitUntil {
            fixture.bridge.renamedPaths.count == 3
                && fixture.bridge.deletedPaths.contains(stagePath)
        })
        let renames = fixture.bridge.renamedPaths
        let backupPath = try XCTUnwrap(renames.first?.to)
        XCTAssertEqual(renames[0].from, "/incoming/report.txt")
        XCTAssertEqual(renames[1], .init(from: stagePath, to: "/incoming/report.txt"))
        XCTAssertEqual(renames[2], .init(from: backupPath, to: "/incoming/report.txt"))
        XCTAssertEqual(fixture.bridge.deletedPaths, [stagePath])
        XCTAssertFalse(fixture.bridge.deletedPaths.contains("/incoming/report.txt"))
        XCTAssertFalse(fixture.bridge.deletedPaths.contains(backupPath))
    }

    func testRemoteStageCleanupRetriesImmediatelyAfterFirstFailure() throws {
        let fixture = try makeAtomicUploadFailureFixture(runtimeID: "scp_atomic_upload_cleanup_retry")
        defer { try? FileManager.default.removeItem(at: fixture.localDirectory) }
        fixture.bridge.deleteErrorsByCallIndex[1] = NSError(
            domain: "StacioTests.AtomicUploadCleanup",
            code: 1
        )

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(fixture.scheduler.jobs.first?.destinationPath)
        fixture.scheduler.complete(jobAt: 0, status: "completed")

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.count == 2 })
        XCTAssertEqual(fixture.bridge.deletedPaths, [stagePath, stagePath])
        XCTAssertTrue(fixture.bridge.renamedPaths.isEmpty)
        XCTAssertFalse(fixture.browser.visibleTextSnapshotForTesting.contains("传输完成"))
    }

    func testRemoteStageCleanupRetainsFailedRequestForNextUploadLifecycleRetry() throws {
        let fixture = try makeAtomicUploadFailureFixture(runtimeID: "scp_atomic_upload_cleanup_pending")
        defer { try? FileManager.default.removeItem(at: fixture.localDirectory) }
        for callIndex in 1...3 {
            fixture.bridge.deleteErrorsByCallIndex[callIndex] = NSError(
                domain: "StacioTests.AtomicUploadCleanup",
                code: callIndex
            )
        }

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.scheduler.jobs.count == 1 })
        let firstStagePath = try XCTUnwrap(fixture.scheduler.jobs.first?.destinationPath)
        fixture.scheduler.complete(jobAt: 0, status: "completed")

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.count == 3 })
        XCTAssertEqual(fixture.bridge.deletedPaths, Array(repeating: firstStagePath, count: 3))
        XCTAssertTrue(fixture.browser.visibleTextSnapshotForTesting.contains("远端临时文件清理失败"))
        XCTAssertFalse(fixture.browser.visibleTextSnapshotForTesting.contains("传输完成"))
        fixture.bridge.deleteErrorsByCallIndex = [:]

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.count == 4 })
        XCTAssertEqual(fixture.bridge.deletedPaths.last, firstStagePath)
        XCTAssertFalse(fixture.bridge.deletedPaths.contains("/incoming/report.txt"))
        XCTAssertTrue(fixture.bridge.renamedPaths.isEmpty)
    }

    func testClosingBrowserRetriesRetainedRemoteStageCleanupRequest() throws {
        let fixture = try makeAtomicUploadFailureFixture(runtimeID: "scp_atomic_upload_cleanup_close")
        defer { try? FileManager.default.removeItem(at: fixture.localDirectory) }
        for callIndex in 1...3 {
            fixture.bridge.deleteErrorsByCallIndex[callIndex] = NSError(
                domain: "StacioTests.AtomicUploadCleanup",
                code: callIndex
            )
        }

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(fixture.scheduler.jobs.first?.destinationPath)
        fixture.scheduler.complete(jobAt: 0, status: "completed")

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.count == 3 })
        XCTAssertEqual(fixture.bridge.deletedPaths, Array(repeating: stagePath, count: 3))
        XCTAssertTrue(waitUntil {
            fixture.browser.visibleTextSnapshotForTesting.contains("远端临时文件清理失败")
        })
        fixture.bridge.deleteErrorsByCallIndex = [:]

        fixture.browser.closeRuntime()

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.count == 4 })
        XCTAssertEqual(fixture.bridge.deletedPaths.last, stagePath)
        XCTAssertFalse(fixture.bridge.deletedPaths.contains("/incoming/report.txt"))
    }

    func testPrimaryBrowserRetriesRemoteStageCleanupFailureThatArrivesAfterClose() throws {
        let fixture = try makeAtomicUploadFailureFixture(runtimeID: "scp_atomic_upload_cleanup_late_close")
        defer { try? FileManager.default.removeItem(at: fixture.localDirectory) }
        for callIndex in 1...3 {
            fixture.bridge.deleteErrorsByCallIndex[callIndex] = NSError(
                domain: "StacioTests.AtomicUploadCleanup",
                code: callIndex
            )
        }
        let thirdAttemptStarted = DispatchSemaphore(value: 0)
        let releaseThirdAttempt = DispatchSemaphore(value: 0)
        fixture.bridge.onDeleteRemotePath = { _ in
            guard fixture.bridge.deletedPaths.count == 3 else { return }
            thirdAttemptStarted.signal()
            releaseThirdAttempt.wait()
        }

        fixture.browser.performUploadLocalPathsForTesting(
            [fixture.source.path],
            remoteDirectory: "/incoming"
        )

        XCTAssertTrue(waitUntil { fixture.scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(fixture.scheduler.jobs.first?.destinationPath)
        fixture.scheduler.complete(jobAt: 0, status: "completed")
        XCTAssertEqual(thirdAttemptStarted.wait(timeout: .now() + 1), .success)

        fixture.browser.closeRuntime()
        releaseThirdAttempt.signal()

        XCTAssertTrue(waitUntil { fixture.bridge.deletedPaths.count == 4 })
        XCTAssertEqual(fixture.bridge.deletedPaths, Array(repeating: stagePath, count: 4))
        XCTAssertFalse(fixture.bridge.deletedPaths.contains("/incoming/report.txt"))
    }

    func testAttachedRemotePaneRetriesRemoteStageCleanupFailureThatArrivesAfterClose() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAttachedLateCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let source = localDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/report.txt", size: 3, linkTarget: nil)
        ]
        for callIndex in 1...3 {
            bridge.deleteErrorsByCallIndex[callIndex] = NSError(
                domain: "StacioTests.AtomicUploadCleanup",
                code: callIndex
            )
        }
        let thirdAttemptStarted = DispatchSemaphore(value: 0)
        let releaseThirdAttempt = DispatchSemaphore(value: 0)
        bridge.onDeleteRemotePath = { _ in
            guard bridge.deletedPaths.count == 3 else { return }
            thirdAttemptStarted.signal()
            releaseThirdAttempt.wait()
        }
        let scheduler = IndependentSCPTransferScheduler()
        let pane = IndependentFileTransferRemotePaneViewController(
            runtimeID: "scp_attached_cleanup_late_close",
            context: Self.liveContext(),
            title: "附加服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "/incoming",
            initialLoadPresentation: .immediate,
            localDirectoryProvider: { localDirectory },
            localDirectoryRefresh: {},
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
                startsBlocked: false
            )
        )
        pane.loadView()

        pane.uploadLocalPaths([source.path], to: "/incoming")

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(scheduler.jobs.first?.destinationPath)
        scheduler.complete(jobAt: 0, status: "completed")
        XCTAssertEqual(thirdAttemptStarted.wait(timeout: .now() + 1), .success)

        pane.closeRuntime()
        releaseThirdAttempt.signal()

        XCTAssertTrue(waitUntil { bridge.deletedPaths.count == 4 })
        XCTAssertEqual(bridge.deletedPaths, Array(repeating: stagePath, count: 4))
        XCTAssertFalse(bridge.deletedPaths.contains("/incoming/report.txt"))
    }

    func testClosingBrowserDuringOverwriteUploadCleansStageAndPreservesRemoteDestination() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioClosingAtomicUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let source = localDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        let remoteBridge = IndependentTransferBrowserBridge()
        remoteBridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/report.txt", size: 3, linkTarget: nil)
        ]
        let transferBridge = IndependentRelayBlockingTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(bridge: transferBridge, queueViewController: queueView)
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_close_atomic_upload",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: remoteBridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "/incoming",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_close_atomic_upload_local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
                startsBlocked: false
            )
        )
        browser.loadView()

        browser.performUploadLocalPathsForTesting([source.path], remoteDirectory: "/incoming")

        XCTAssertTrue(waitUntil { transferBridge.jobs.count == 1 })
        let stagePath = try XCTUnwrap(transferBridge.jobs.first?.destinationPath)
        XCTAssertNotEqual(stagePath, "/incoming/report.txt")

        browser.closeRuntime()
        transferBridge.release()

        XCTAssertTrue(waitUntil { remoteBridge.deletedPaths == [stagePath] })
        XCTAssertFalse(remoteBridge.deletedPaths.contains("/incoming/report.txt"))
        XCTAssertTrue(remoteBridge.renamedPaths.isEmpty)
    }

    func testClosingBrowserDuringOverwriteDownloadCleansStageAndPreservesLocalDestination() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioClosingAtomicDownload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let destination = localDirectory.appendingPathComponent("report.txt")
        let originalContents = Data("original".utf8)
        try originalContents.write(to: destination)
        let remoteBridge = IndependentTransferBrowserBridge()
        remoteBridge.entriesByPath["~"] = [
            RemoteFileEntry(kind: .file, path: "~/report.txt", size: 16, linkTarget: nil)
        ]
        let transferBridge = IndependentRelayBlockingTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(bridge: transferBridge, queueViewController: queueView)
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_close_atomic_download",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: remoteBridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_close_atomic_download_local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
                startsBlocked: false
            )
        )
        browser.loadView()

        browser.performDownloadSelectionsForTesting(
            [RemoteFileSelection(path: "~/report.txt", size: 16)],
            to: localDirectory
        )

        XCTAssertTrue(waitUntil { transferBridge.jobs.count == 1 })
        let stagePath = try XCTUnwrap(transferBridge.jobs.first?.destinationPath)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: stagePath))

        browser.closeRuntime()
        transferBridge.release()

        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: stagePath) == false })
        XCTAssertEqual(try Data(contentsOf: destination), originalContents)
    }

    func testOverwriteDownloadFailurePreservesExistingLocalDestinationAndCleansStage() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAtomicDownloadFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let destination = localDirectory.appendingPathComponent("report.txt")
        try Data("old-destination".utf8).write(to: destination)
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        scheduler.materializesFailedDownloads = true
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_atomic_download_failure",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_atomic_download_failure_local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
                startsBlocked: false
            )
        )
        browser.loadView()

        browser.performDownloadSelectionsForTesting(
            [RemoteFileSelection(path: "~/report.txt", size: 16)],
            to: localDirectory
        )

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        let stagePath = try XCTUnwrap(scheduler.jobs.first?.destinationPath)
        XCTAssertNotEqual(stagePath, destination.path)
        XCTAssertEqual((stagePath as NSString).deletingLastPathComponent, localDirectory.path)
        XCTAssertTrue((stagePath as NSString).lastPathComponent.hasPrefix(".report.txt.stacio-transfer-"))
        scheduler.complete(jobAt: 0, status: "failed")

        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: stagePath) == false })
        XCTAssertEqual(try Data(contentsOf: destination), Data("old-destination".utf8))
    }

    func testRemoteRenameToExistingNameRequiresConflictDecisionAndPreservesTargetWhenCancelled() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/srv"] = [
            RemoteFileEntry(kind: .file, path: "/srv/source.txt", size: 6, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/target.txt", size: 8, linkTarget: nil)
        ]
        let resolver = IndependentBlockingConflictResolver(decision: nil, startsBlocked: false)
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_rename_conflict_cancel",
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: IndependentSCPTransferScheduler(),
            remoteProtocolName: "SCP",
            initialRemotePath: "/srv",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_rename_conflict_cancel_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            ),
            conflictResolver: resolver
        )
        browser.loadView()

        browser.remoteFilesViewController.onRenameSelection?(
            RemoteFileSelection(path: "/srv/source.txt", size: 6),
            "target.txt"
        )

        XCTAssertTrue(waitUntil { resolver.requestedPaths == ["/srv/target.txt"] })
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testRemoteRenameToExistingNameSkipsWithoutMutatingRemotePaths() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/srv"] = [
            RemoteFileEntry(kind: .file, path: "/srv/source.txt", size: 6, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/target.txt", size: 8, linkTarget: nil)
        ]
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .skip, applyToAll: false),
            startsBlocked: false
        )
        let browser = makeRenameBrowser(
            runtimeID: "scp_rename_conflict_skip",
            bridge: bridge,
            conflictResolver: resolver
        )
        browser.loadView()

        browser.remoteFilesViewController.onRenameSelection?(
            RemoteFileSelection(path: "/srv/source.txt", size: 6),
            "target.txt"
        )

        XCTAssertTrue(waitUntil { resolver.requestedPaths == ["/srv/target.txt"] })
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testRemoteRenameOverwriteBacksUpTargetPromotesSourceAndDeletesBackup() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/srv"] = [
            RemoteFileEntry(kind: .file, path: "/srv/source.txt", size: 6, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/target.txt", size: 8, linkTarget: nil)
        ]
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
            startsBlocked: false
        )
        let browser = makeRenameBrowser(
            runtimeID: "scp_rename_conflict_overwrite",
            bridge: bridge,
            conflictResolver: resolver
        )
        browser.loadView()

        browser.remoteFilesViewController.onRenameSelection?(
            RemoteFileSelection(path: "/srv/source.txt", size: 6),
            "target.txt"
        )

        XCTAssertTrue(waitUntil { bridge.deletedPaths.count == 1 })
        let calls = bridge.renamedPaths
        XCTAssertEqual(calls.count, 2)
        guard calls.count == 2 else { return }
        let backupPath = try XCTUnwrap(calls.first?.to)
        XCTAssertEqual(calls.first?.from, "/srv/target.txt")
        XCTAssertTrue(backupPath.hasPrefix("/srv/.target.txt.stacio-backup-rename-"))
        XCTAssertTrue(backupPath.hasSuffix(".pending"))
        XCTAssertEqual(
            calls[1],
            IndependentTransferBrowserBridge.PathPair(
                from: "/srv/source.txt",
                to: "/srv/target.txt"
            )
        )
        XCTAssertEqual(bridge.deletedPaths, [backupPath])
    }

    func testRemoteRenameOverwritePromotionFailureRollsTargetBack() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/srv"] = [
            RemoteFileEntry(kind: .file, path: "/srv/source.txt", size: 6, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/target.txt", size: 8, linkTarget: nil)
        ]
        bridge.renameErrorsByCallIndex[2] = NSError(
            domain: "StacioTests.RemoteRename",
            code: 2
        )
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
            startsBlocked: false
        )
        let browser = makeRenameBrowser(
            runtimeID: "scp_rename_conflict_rollback",
            bridge: bridge,
            conflictResolver: resolver
        )
        browser.loadView()

        browser.remoteFilesViewController.onRenameSelection?(
            RemoteFileSelection(path: "/srv/source.txt", size: 6),
            "target.txt"
        )

        XCTAssertTrue(waitUntil { bridge.renamedPaths.count == 3 })
        let calls = bridge.renamedPaths
        XCTAssertEqual(calls.count, 3)
        guard calls.count == 3 else { return }
        let backupPath = calls[0].to
        XCTAssertEqual(calls[0].from, "/srv/target.txt")
        XCTAssertEqual(
            calls[1],
            IndependentTransferBrowserBridge.PathPair(
                from: "/srv/source.txt",
                to: "/srv/target.txt"
            )
        )
        XCTAssertEqual(
            calls[2],
            IndependentTransferBrowserBridge.PathPair(
                from: backupPath,
                to: "/srv/target.txt"
            )
        )
        XCTAssertTrue(bridge.deletedPaths.isEmpty)
    }

    func testAdditionalRemoteUploadUsesKeepBothConflictPolicy() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAdditionalUploadConflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localFile = localDirectory.appendingPathComponent("artifact.txt")
        try Data("artifact".utf8).write(to: localFile)
        let primaryBridge = IndependentTransferBrowserBridge()
        primaryBridge.entriesByPath["~"] = []
        let additionalBridge = IndependentTransferBrowserBridge()
        additionalBridge.entriesByPath["~/incoming"] = [
            RemoteFileEntry(kind: .file, path: "~/incoming/artifact.txt", size: 8, linkTarget: nil)
        ]
        let scheduler = IndependentSCPTransferScheduler()
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .keepBoth, applyToAll: false),
            startsBlocked: false
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "additional-upload-primary",
            context: Self.liveContext(host: "primary.example.com"),
            title: "主服务器",
            bridge: primaryBridge,
            transferScheduler: nil,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "additional-upload-local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: resolver
        )
        browser.loadView()
        let additionalPane = browser.addRemotePane(
            runtimeID: "additional-upload-remote",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: additionalBridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~/incoming",
            initialLoadPresentation: .immediate
        )

        additionalPane.uploadLocalPaths([localFile.path], to: "~/incoming")

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        XCTAssertEqual(resolver.requestedDirections, [.upload])
        XCTAssertEqual(
            try XCTUnwrap(scheduler.jobs.first).destinationPath,
            "~/incoming/artifact (copy).txt"
        )
    }

    func testAdditionalRemoteDownloadAppliesKeepBothDecisionToAllConflicts() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAdditionalDownloadConflicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        try Data("old-one".utf8).write(to: localDirectory.appendingPathComponent("one.txt"))
        try Data("old-two".utf8).write(to: localDirectory.appendingPathComponent("two.txt"))
        let primaryBridge = IndependentTransferBrowserBridge()
        primaryBridge.entriesByPath["~"] = []
        let additionalBridge = IndependentTransferBrowserBridge()
        additionalBridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let resolver = IndependentBlockingConflictResolver(
            decision: RemoteFileConflictDecision(policy: .keepBoth, applyToAll: true),
            startsBlocked: false
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "additional-download-primary",
            context: Self.liveContext(host: "primary.example.com"),
            title: "主服务器",
            bridge: primaryBridge,
            transferScheduler: nil,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "additional-download-local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: resolver
        )
        browser.loadView()
        let additionalPane = browser.addRemotePane(
            runtimeID: "additional-download-remote",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: additionalBridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )

        additionalPane.downloadSelections(
            [
                RemoteFileSelection(path: "~/one.txt", size: 7),
                RemoteFileSelection(path: "~/two.txt", size: 7)
            ],
            to: localDirectory
        )

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 2 })
        XCTAssertEqual(resolver.requestedPaths.count, 1)
        XCTAssertEqual(resolver.requestedDirections, [.download])
        XCTAssertEqual(
            Set(scheduler.jobs.map(\.destinationPath)),
            Set([
                localDirectory.appendingPathComponent("one (copy).txt").path,
                localDirectory.appendingPathComponent("two (copy).txt").path
            ])
        )
    }

    func testSCPSessionUsesIndependentBrowserAndSCPListing() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/srv"] = [
            RemoteFileEntry(kind: .file, path: "/srv/app.log", size: 128, linkTarget: nil)
        ]
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        workspace.loadView()

        _ = try workspace.openRemoteFilesSession(
            context: Self.liveContext(),
            title: "SCP 文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv"
        )

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteFilesPaneViewController)
        let browser = try XCTUnwrap(pane.independentTransferBrowserForTesting)
        XCTAssertTrue(waitUntil { bridge.listedSCPPaths == ["/srv"] })
        XCTAssertEqual(browser.currentRemotePath, "/srv")
        XCTAssertFalse(containsViewController(ofType: FilesViewController.self, in: pane))
    }

    func testSFTPSessionUsesIndependentTwoPaneBrowserInsteadOfInspectorFilesView() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = [
            RemoteFileEntry(kind: .directory, path: "~/releases", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "~/README.md", size: 512, linkTarget: nil)
        ]
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        workspace.loadView()

        _ = try workspace.openSFTPFilesSession(
            context: Self.liveContext(),
            title: "SFTP 文件",
            bridge: bridge
        )

        let pane = try XCTUnwrap(workspace.currentTerminalPane as? RemoteFilesPaneViewController)
        let browser = try XCTUnwrap(pane.independentTransferBrowserForTesting)
        XCTAssertTrue(waitUntil { bridge.listedSFTPPaths == ["~"] })
        XCTAssertTrue(waitUntil { browser.remoteFilesViewController.tableView.numberOfRows == 2 })
        XCTAssertEqual(browser.fileTransferSplitViewForTesting.arrangedSubviews.count, 2)
        XCTAssertTrue(browser.fileTransferSplitViewForTesting.arrangedSubviews[0] === browser.localFilesViewController.view)
        XCTAssertFalse(containsViewController(ofType: FilesViewController.self, in: pane))
        XCTAssertNotNil(pane.view.firstDescendant(accessibilityIdentifier: "Stacio.FileTransferBrowser.remoteTable"))
        XCTAssertNil(pane.view.firstDescendant(accessibilityIdentifier: "Stacio.Files.remoteTable"))
    }

    func testIndependentBrowserKeepsLocalAndRemoteColumnsBalancedAfterLayout() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let pane = RemoteFilesPaneViewController(
            runtimeID: "sftp_browser_balanced_layout",
            context: Self.liveContext(),
            title: "SFTP 文件",
            bridge: SFTPRemoteFilesBridgeAdapter(base: bridge),
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            presentationMode: .transferBrowser
        )

        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_400, height: 720)
        pane.view.layoutSubtreeIfNeeded()

        let browser = try XCTUnwrap(pane.independentTransferBrowserForTesting)
        XCTAssertTrue(waitUntil {
            browser.localFilesViewController.statusTextForTesting.hasPrefix("当前路径：")
        })
        let splitView = browser.fileTransferSplitViewForTesting
        let localWidth = splitView.arrangedSubviews[0].frame.width
        let remoteWidth = splitView.arrangedSubviews[1].frame.width
        let localPathField = try XCTUnwrap(
            pane.view.firstDescendant(accessibilityIdentifier: "Stacio.FileTransferBrowser.localPath")
        )
        let remotePathField = try XCTUnwrap(
            pane.view.firstDescendant(accessibilityIdentifier: "Stacio.FileTransferBrowser.remotePath")
        )
        let localPathFrame = pane.view.convert(localPathField.bounds, from: localPathField)
        let remotePathFrame = pane.view.convert(remotePathField.bounds, from: remotePathField)

        XCTAssertGreaterThanOrEqual(localWidth, 500)
        XCTAssertGreaterThanOrEqual(remoteWidth, 500)
        XCTAssertEqual(localWidth, remoteWidth, accuracy: 24)
        XCTAssertEqual(localPathFrame.minY, remotePathFrame.minY, accuracy: 1)
        XCTAssertEqual(localPathFrame.height, remotePathFrame.height, accuracy: 1)
        XCTAssertFalse(browser.localFilesViewController.uploadButtonIsHiddenForTesting)
        XCTAssertFalse(browser.localFilesViewController.uploadButtonIsEnabledForTesting)
    }

    func testSFTPBrowserNavigatesRemoteDirectoriesThroughSFTPBridge() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = [
            RemoteFileEntry(kind: .directory, path: "~/releases", size: 0, linkTarget: nil)
        ]
        bridge.entriesByPath["~/releases"] = [
            RemoteFileEntry(kind: .file, path: "~/releases/stacio.zip", size: 2_048, linkTarget: nil)
        ]
        let pane = RemoteFilesPaneViewController(
            runtimeID: "sftp_browser_navigation",
            context: Self.liveContext(),
            title: "SFTP 文件",
            bridge: SFTPRemoteFilesBridgeAdapter(base: bridge),
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialLoadPresentation: .connectionState,
            presentationMode: .transferBrowser
        )

        pane.loadView()
        let browser = try XCTUnwrap(pane.independentTransferBrowserForTesting)
        XCTAssertTrue(waitUntil { bridge.listedSFTPPaths == ["~"] })
        browser.loadDirectoryForTesting("~/releases")

        XCTAssertTrue(waitUntil { bridge.listedSFTPPaths == ["~", "~/releases"] })
        XCTAssertTrue(waitUntil { browser.currentRemotePath == "~/releases" })
        XCTAssertTrue(waitUntil {
            browser.remoteFilesViewController.visibleTextSnapshotForTesting.contains("stacio.zip")
        })
    }

    func testSFTPBrowserSchedulesUploadAndDownloadThroughInternalQueue() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        bridge.entriesByPath["~/incoming"] = []
        let scheduler = IndependentSFTPTransferScheduler()
        let adapter = SFTPTransferSchedulerAdapter(scheduler: scheduler)
        let pane = RemoteFilesPaneViewController(
            runtimeID: "sftp_browser_transfer",
            context: Self.liveContext(),
            title: "SFTP 文件",
            bridge: SFTPRemoteFilesBridgeAdapter(base: bridge),
            transferScheduler: adapter,
            remoteProtocolName: "SFTP",
            initialLoadPresentation: .connectionState,
            presentationMode: .transferBrowser
        )
        pane.loadView()
        let browser = try XCTUnwrap(pane.independentTransferBrowserForTesting)
        XCTAssertTrue(waitUntil { bridge.listedSFTPPaths == ["~"] })

        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioIndependentBrowser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let uploadURL = localDirectory.appendingPathComponent("upload.txt")
        try Data("upload".utf8).write(to: uploadURL)
        let uploadFolderURL = localDirectory.appendingPathComponent("release", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadFolderURL, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: uploadFolderURL.appendingPathComponent("nested.txt"))

        browser.loadDirectoryForTesting("~/incoming")
        XCTAssertTrue(waitUntil { browser.currentRemotePath == "~/incoming" })
        browser.localFilesViewController.navigate(to: localDirectory)
        XCTAssertTrue(waitUntil {
            let snapshot = browser.localFilesViewController.visibleTextSnapshotForTesting
            return snapshot.contains("upload.txt") && snapshot.contains("release")
        })
        browser.localFilesViewController.selectLocalItemsForTesting(named: ["upload.txt"])
        browser.localFilesViewController.performSelectedUploadForTesting()
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        browser.localFilesViewController.selectLocalItemsForTesting(named: ["release"])
        browser.localFilesViewController.performSelectedUploadForTesting()
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 2 })
        browser.performDownloadSelectionsForTesting(
            [RemoteFileSelection(path: "~/outgoing/report.csv", size: 128)],
            to: localDirectory
        )
        browser.performDownloadSelectionsForTesting(
            [RemoteFileSelection(path: "~/outgoing/assets", size: 0, kind: .directory)],
            to: localDirectory
        )
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 4 })

        XCTAssertEqual(scheduler.runtimeIDs, [
            "sftp_browser_transfer",
            "sftp_browser_transfer",
            "sftp_browser_transfer",
            "sftp_browser_transfer"
        ])
        XCTAssertEqual(scheduler.jobs.map(\.direction), [.upload, .upload, .download, .download])
        XCTAssertEqual(scheduler.notificationPolicies, Array(repeating: .silent, count: 4))
        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        let uploadFolderJob = try XCTUnwrap(scheduler.jobs.dropFirst().first)
        let downloadJob = try XCTUnwrap(scheduler.jobs.dropFirst(2).first)
        let downloadFolderJob = try XCTUnwrap(scheduler.jobs.dropFirst(3).first)
        XCTAssertEqual((uploadJob.sourcePath as NSString).lastPathComponent, "upload.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadJob.sourcePath))
        XCTAssertEqual(uploadJob.destinationPath, "~/incoming/upload.txt")
        XCTAssertEqual((uploadFolderJob.sourcePath as NSString).lastPathComponent, "release")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadFolderJob.sourcePath))
        XCTAssertEqual(uploadFolderJob.destinationPath, "~/incoming/release")
        XCTAssertEqual(uploadFolderJob.bytesTotal, 0)
        XCTAssertEqual(downloadJob.sourcePath, "~/outgoing/report.csv")
        XCTAssertEqual(downloadJob.destinationPath, localDirectory.appendingPathComponent("report.csv").path)
        XCTAssertEqual(downloadFolderJob.sourcePath, "~/outgoing/assets")
        XCTAssertEqual(downloadFolderJob.destinationPath, localDirectory.appendingPathComponent("assets").path)
    }

    func testSCPBrowserUploadsSelectedLocalItemToCurrentRemoteDirectory() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/srv/incoming"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_browser_selected_upload",
            context: Self.liveContext(),
            title: "SCP 文件",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "/srv/incoming",
            initialLoadPresentation: .connectionState,
            presentationMode: .transferBrowser
        )
        pane.loadView()
        let browser = try XCTUnwrap(pane.independentTransferBrowserForTesting)
        XCTAssertTrue(waitUntil { browser.currentRemotePath == "/srv/incoming" })

        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioIndependentSCPBrowser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let uploadURL = localDirectory.appendingPathComponent("package.tar.gz")
        try Data("package".utf8).write(to: uploadURL)

        browser.localFilesViewController.navigate(to: localDirectory)
        XCTAssertTrue(waitUntil {
            browser.localFilesViewController.visibleTextSnapshotForTesting.contains("package.tar.gz")
        })
        XCTAssertFalse(browser.localFilesViewController.uploadButtonIsEnabledForTesting)
        browser.localFilesViewController.selectLocalItemsForTesting(named: ["package.tar.gz"])
        XCTAssertTrue(browser.localFilesViewController.uploadButtonIsEnabledForTesting)
        browser.localFilesViewController.performSelectedUploadForTesting()
        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })

        XCTAssertEqual(scheduler.runtimeIDs, ["scp_browser_selected_upload"])
        XCTAssertEqual(scheduler.notificationPolicies, [.silent])
        XCTAssertEqual(scheduler.jobs.map { ($0.sourcePath as NSString).lastPathComponent }, ["package.tar.gz"])
        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadJob.sourcePath))
        XCTAssertEqual(scheduler.jobs.map(\.destinationPath), ["/srv/incoming/package.tar.gz"])
    }

    func testClosingIndependentBrowserDisconnectsOnlyItsRuntime() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSFTPTransferScheduler()
        let pane = RemoteFilesPaneViewController(
            runtimeID: "sftp_browser_close",
            context: Self.liveContext(),
            title: "SFTP 文件",
            bridge: SFTPRemoteFilesBridgeAdapter(base: bridge),
            transferScheduler: SFTPTransferSchedulerAdapter(scheduler: scheduler),
            remoteProtocolName: "SFTP",
            presentationMode: .transferBrowser
        )
        pane.loadView()

        pane.closeRemoteFilesRuntime()

        XCTAssertEqual(scheduler.disconnectedRuntimeIDs, ["sftp_browser_close"])
    }

    func testTransferBrowserPlacesNativeQueueButtonBeforeLayoutControl() {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp-queue-toolbar",
            context: Self.liveContext(),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp-queue-toolbar-local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.loadView()
        browser.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        browser.view.layoutSubtreeIfNeeded()

        let button = browser.transferQueueButtonForTesting
        XCTAssertEqual(button.accessibilityLabel(), "传输队列")
        XCTAssertNotNil(button.image)
        XCTAssertTrue(button.isEnabled)
        XCTAssertLessThan(button.frame.maxX, browser.layoutControlForTesting.frame.minX)
        XCTAssertTrue(browser.hasTransferQueuePopoverForTesting)
    }

    func testTransferBrowserAutomaticallyPresentsQueueWhenNewTransferBatchStarts() {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(queueViewController: queueView)
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp-queue-auto-present",
            context: Self.liveContext(),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp-queue-auto-present-local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = browser
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        browser.view.layoutSubtreeIfNeeded()
        let job = ScpTransferJob(
            id: "queue-auto-present-job",
            direction: .upload,
            sourcePath: "/tmp/archive.iso",
            destinationPath: "/srv/archive.iso",
            bytesTotal: 100
        )

        queue.registerExternalTransfer(
            runtimeID: "scp-queue-auto-present-local",
            job: job,
            progressProvider: { [] },
            pause: { true },
            resume: { true },
            cancel: { true }
        )

        XCTAssertTrue(waitUntil {
            guard let storedPopover = Mirror(reflecting: browser).children
                .first(where: { $0.label == "transferQueuePopover" })?
                .value,
                let popover = Mirror(reflecting: storedPopover).children.first?.value as? NSPopover
            else { return false }
            return popover.isShown
        })
        queue.finishExternalTransfer(jobID: job.id, status: "completed", bytesDone: 100)
    }

    func testClosingIndependentBrowserClosesSharedDocumentWindows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCloseDocuments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("notes.txt")
        let previewURL = directory.appendingPathComponent("archive.zip")
        try Data("notes".utf8).write(to: textURL)
        try Data("archive".utf8).write(to: previewURL)
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_close_documents",
            defaults: makeIsolatedDefaults()
        )
        browser.documentCoordinatorForTesting.openLocalURL(textURL)
        browser.documentCoordinatorForTesting.quickLookLocalURLs([previewURL])
        XCTAssertTrue(waitUntil {
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting != nil
        })
        XCTAssertNotNil(browser.documentCoordinatorForTesting.editorWindowControllerForTesting)
        XCTAssertEqual(
            browser.documentCoordinatorForTesting.quickLookCoordinatorForTesting.previewURLsForTesting,
            [previewURL.standardizedFileURL]
        )

        browser.closeRuntime()

        XCTAssertNil(browser.documentCoordinatorForTesting.editorWindowControllerForTesting)
        XCTAssertTrue(
            browser.documentCoordinatorForTesting.quickLookCoordinatorForTesting.previewURLsForTesting.isEmpty
        )
    }

    func testClosingMultiRemoteBrowserDisconnectsEveryRuntimeExactlyOnce() {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = []
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp_close_primary",
            context: Self.liveContext(host: "primary.example.com"),
            title: "生产服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp_close_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
        browser.loadView()
        _ = browser.addRemotePane(
            runtimeID: "scp_close_attached",
            context: Self.liveContext(host: "backup.example.com"),
            title: "备份服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialLoadPresentation: .immediate
        )

        browser.closeRuntime()
        browser.closeRuntime()

        XCTAssertEqual(scheduler.disconnectedRuntimeIDs, [
            "scp_close_primary",
            "scp_close_attached"
        ])
    }

    func testClosingBrowserCancelsProductionSCPRelayAndCleansPlaintextDirectory() throws {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCloseSCPRelay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let transferBridge = IndependentRelayBlockingTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            bridge: transferBridge,
            sftpBridge: transferBridge,
            queueViewController: queueView
        )
        let remoteBridge = IndependentTransferBrowserBridge()
        remoteBridge.entriesByPath["~"] = []
        let crossDeviceCoordinator = CrossDeviceTransferCoordinator(
            relayDirectoryProvider: { relayRoot }
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp-close-relay-source",
            context: Self.liveContext(host: "source.example.com"),
            title: "源服务器",
            bridge: remoteBridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp-close-relay-local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            ),
            crossDeviceTransferCoordinator: crossDeviceCoordinator
        )
        browser.loadView()
        let destinationPane = browser.addRemotePane(
            runtimeID: "scp-close-relay-destination",
            context: Self.liveContext(host: "destination.example.com"),
            title: "目标服务器",
            bridge: remoteBridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )

        destinationPane.remoteFilesViewController.onRemoteSelectionsDropped?(
            browser.runtimeID,
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            "~"
        )
        XCTAssertTrue(waitUntil {
            transferBridge.startedSCPJobIDs.count == 1
                && FileManager.default.fileExists(atPath: relayRoot.path)
        })

        browser.closeRuntime()

        let jobID = try XCTUnwrap(transferBridge.startedSCPJobIDs.first)
        XCTAssertEqual(transferBridge.cancelledSCPJobIDs, [jobID])
        XCTAssertTrue(transferBridge.cancelledSFTPJobIDs.isEmpty)
        transferBridge.release()
        XCTAssertTrue(waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: relayRoot.path) == false
        })
    }

    func testClosingBrowserAfterRelayCancellationRejectionDoesNotScheduleUploadOrResurrectQueue() throws {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCloseRejectedRelay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let transferBridge = IndependentRelayBlockingTransferBridge(
            acceptsCancellation: false,
            completionStatus: "completed",
            materializesCompletedDownloads: true
        )
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            bridge: transferBridge,
            sftpBridge: transferBridge,
            queueViewController: queueView
        )
        let remoteBridge = IndependentTransferBrowserBridge()
        remoteBridge.entriesByPath["~"] = []
        let crossDeviceCoordinator = CrossDeviceTransferCoordinator(
            relayDirectoryProvider: { relayRoot }
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "scp-close-rejected-source",
            context: Self.liveContext(host: "source.example.com"),
            title: "源服务器",
            bridge: remoteBridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "scp-close-rejected-local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            ),
            crossDeviceTransferCoordinator: crossDeviceCoordinator
        )
        browser.loadView()
        let destinationPane = browser.addRemotePane(
            runtimeID: "scp-close-rejected-destination",
            context: Self.liveContext(host: "destination.example.com"),
            title: "目标服务器",
            bridge: remoteBridge,
            transferScheduler: queue,
            remoteProtocolName: "SCP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )
        destinationPane.remoteFilesViewController.onRemoteSelectionsDropped?(
            browser.runtimeID,
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            "~"
        )
        XCTAssertTrue(waitUntil {
            transferBridge.jobs.count == 1
                && FileManager.default.fileExists(atPath: relayRoot.path)
        })

        browser.closeRuntime()
        transferBridge.release()

        XCTAssertTrue(waitUntil(timeout: 2) {
            transferBridge.jobs.count > 1
                || FileManager.default.fileExists(atPath: relayRoot.path) == false
        })
        XCTAssertEqual(transferBridge.jobs.count, 1)
        XCTAssertTrue(queueView.snapshotForTesting.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relayRoot.path))
        transferBridge.release()
    }

    func testClosingBrowserCancelsProductionSFTPRelayAndCleansPlaintextDirectory() throws {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCloseSFTPRelay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: relayRoot) }
        let transferBridge = IndependentRelayBlockingTransferBridge()
        let queueView = TransferQueueViewController()
        queueView.loadView()
        let queue = TransferQueueCoordinator(
            bridge: transferBridge,
            sftpBridge: transferBridge,
            queueViewController: queueView
        )
        let scheduler = SFTPTransferSchedulerAdapter(scheduler: queue)
        let remoteBridge = IndependentTransferBrowserBridge()
        remoteBridge.entriesByPath["~"] = []
        let crossDeviceCoordinator = CrossDeviceTransferCoordinator(
            relayDirectoryProvider: { relayRoot }
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "sftp-close-relay-source",
            context: Self.liveContext(host: "source.example.com"),
            title: "源服务器",
            bridge: SFTPRemoteFilesBridgeAdapter(base: remoteBridge),
            transferScheduler: scheduler,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "sftp-close-relay-local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            ),
            crossDeviceTransferCoordinator: crossDeviceCoordinator
        )
        browser.loadView()
        let destinationPane = browser.addRemotePane(
            runtimeID: "sftp-close-relay-destination",
            context: Self.liveContext(host: "destination.example.com"),
            title: "目标服务器",
            bridge: SFTPRemoteFilesBridgeAdapter(base: remoteBridge),
            transferScheduler: scheduler,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate
        )

        destinationPane.remoteFilesViewController.onRemoteSelectionsDropped?(
            browser.runtimeID,
            [RemoteFileSelection(path: "/incoming/report.txt", size: 10)],
            "~"
        )
        XCTAssertTrue(waitUntil {
            transferBridge.startedSFTPJobIDs.count == 1
                && FileManager.default.fileExists(atPath: relayRoot.path)
        })

        browser.closeRuntime()

        let jobID = try XCTUnwrap(transferBridge.startedSFTPJobIDs.first)
        XCTAssertEqual(transferBridge.cancelledSFTPJobIDs, [jobID])
        XCTAssertTrue(transferBridge.cancelledSCPJobIDs.isEmpty)
        transferBridge.release()
        XCTAssertTrue(waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: relayRoot.path) == false
        })
    }

    func testLocalFilesOpenInOneTabbedEditorWindow() throws {
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_local_editor_tabs",
            defaults: makeIsolatedDefaults()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioEditorTabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.swift")
        let secondURL = directory.appendingPathComponent("second.py")
        try Data("let value = 1\n".utf8).write(to: firstURL)
        try Data("print('ok')\n".utf8).write(to: secondURL)

        browser.documentCoordinatorForTesting.openLocalURL(firstURL)
        browser.documentCoordinatorForTesting.openLocalURL(secondURL)

        XCTAssertTrue(waitUntil {
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting?
                .editorViewController.tabTitlesForTesting.count == 2
        })
        let windowController = try XCTUnwrap(
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting
        )
        XCTAssertEqual(
            windowController.editorViewController.tabTitlesForTesting,
            ["first.swift", "second.py"]
        )
        windowController.close()
    }

    func testLocalMediaDoubleClickRoutesThroughBrowserDocumentCoordinator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalMediaOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("local.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to: imageURL)
        let localPane = LocalFilePaneViewController(
            runtimeID: "sftp_local_media_open_local",
            directoryURL: directory,
            title: "本地文件"
        )
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: "sftp_local_media_open",
            context: Self.liveContext(),
            title: "生产服务器",
            bridge: SFTPRemoteFilesBridgeAdapter(base: IndependentTransferBrowserBridge()),
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: localPane
        )
        browser.loadView()
        XCTAssertTrue(waitUntil { localPane.visibleTextSnapshotForTesting.contains("local.png") })

        localPane.selectLocalItemsForTesting(named: ["local.png"])
        localPane.performOpenSelectedEntryForTesting()

        XCTAssertTrue(waitUntil {
            browser.documentCoordinatorForTesting.mediaWindowCountForTesting == 1
        })
        XCTAssertEqual(
            browser.documentCoordinatorForTesting.mediaSourceURLsForTesting.first?.scheme,
            "http"
        )
        browser.documentCoordinatorForTesting.closeMediaWindowsForTesting()
    }

    func testRemoteTextOpensInEditorAndSaveWritesBackThroughSFTPBridge() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = [
            RemoteFileEntry(kind: .file, path: "~/app.conf", size: 13, linkTarget: nil)
        ]
        bridge.fileDataByPath["~/app.conf"] = Data("enabled=true\n".utf8)
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_remote_editor",
            defaults: makeIsolatedDefaults(),
            bridge: bridge
        )
        browser.loadView()
        XCTAssertTrue(waitUntil { browser.remoteFilesViewController.tableView.numberOfRows == 1 })

        browser.remoteFilesViewController.onOpenSelection?(
            RemoteFileSelection(path: "~/app.conf", size: 13)
        )

        XCTAssertTrue(waitUntil {
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting != nil
        })
        let editor = try XCTUnwrap(
            browser.documentCoordinatorForTesting.editorWindowControllerForTesting?.editorViewController
        )
        XCTAssertEqual(editor.currentTextForTesting, "enabled=true\n")

        editor.replaceTextForTesting("enabled=false\n")
        try editor.performSaveForTesting()

        XCTAssertTrue(waitUntil {
            bridge.writtenFileDataByPath["~/app.conf"] == Data("enabled=false\n".utf8)
        })
        XCTAssertEqual(
            bridge.writtenFileDataByPath["~/app.conf"],
            Data("enabled=false\n".utf8)
        )
        browser.documentCoordinatorForTesting.editorWindowControllerForTesting?.close()
    }

    func testRemoteVideoOpenUsesLoopbackHTTPPlaybackSource() throws {
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["~"] = [
            RemoteFileEntry(kind: .file, path: "~/demo.mp4", size: 512, linkTarget: nil)
        ]
        bridge.fileDataByPath["~/demo.mp4"] = Data(repeating: 0, count: 512)
        let browser = makeIndependentBrowser(
            runtimeID: "sftp_remote_video",
            defaults: makeIsolatedDefaults(),
            bridge: bridge
        )
        browser.loadView()
        XCTAssertTrue(waitUntil { browser.remoteFilesViewController.tableView.numberOfRows == 1 })

        browser.remoteFilesViewController.onOpenSelection?(
            RemoteFileSelection(path: "~/demo.mp4", size: 512)
        )

        XCTAssertTrue(waitUntil {
            browser.documentCoordinatorForTesting.mediaWindowCountForTesting == 1
        })
        let sourceURL = try XCTUnwrap(
            browser.documentCoordinatorForTesting.mediaSourceURLsForTesting.first
        )
        XCTAssertEqual(sourceURL.scheme, "http")
        XCTAssertEqual(sourceURL.host, "127.0.0.1")
        browser.documentCoordinatorForTesting.closeMediaWindowsForTesting()
    }

    func testLocalAndRemoteListsRouteSelectedItemsToQuickLook() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioQuickLookRoutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localURL = directory.appendingPathComponent("local.txt")
        try Data("local".utf8).write(to: localURL)
        let local = LocalFilePaneViewController(
            runtimeID: "quicklook_local",
            directoryURL: directory,
            title: "本地文件"
        )
        local.loadView()
        XCTAssertTrue(waitUntil {
            local.visibleTextSnapshotForTesting.contains("local.txt")
        })
        local.selectLocalItemsForTesting(named: ["local.txt"])
        var localPreviewURLs: [URL] = []
        local.onQuickLookURLs = { localPreviewURLs = $0 }

        local.performQuickLookForTesting()

        XCTAssertEqual(
            localPreviewURLs.map { $0.resolvingSymlinksInPath().path },
            [localURL.resolvingSymlinksInPath().path]
        )
        XCTAssertTrue(local.contextMenuTitlesForTesting(row: 0).contains("快速查看"))

        let remote = IndependentRemoteFilesViewController(
            title: "远端",
            protocolName: "SFTP",
            initialPath: "~"
        )
        remote.loadView()
        remote.setEntries([
            RemoteFileEntry(kind: .file, path: "~/remote.txt", size: 6, linkTarget: nil)
        ], path: "~")
        remote.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var remoteSelections: [RemoteFileSelection] = []
        remote.onQuickLookSelections = { remoteSelections = $0 }

        remote.performQuickLookForTesting()

        XCTAssertEqual(remoteSelections.map(\.path), ["~/remote.txt"])
        XCTAssertTrue(remote.contextMenuTitlesForTesting(row: 0).contains("使用 Stacio 打开"))
        XCTAssertTrue(remote.contextMenuTitlesForTesting(row: 0).contains("快速查看"))
    }

    func testRemoteParentButtonCanMoveBetweenRootAndHome() {
        let remote = IndependentRemoteFilesViewController(
            title: "远端",
            protocolName: "SCP",
            initialPath: "/"
        )
        remote.loadView()
        var requestedPath: String?
        remote.onNavigate = { requestedPath = $0 }

        XCTAssertTrue(remote.parentButtonIsEnabledForTesting)
        remote.performParentNavigationForTesting()
        XCTAssertEqual(requestedPath, "~")

        remote.setEntries([], path: "~")
        remote.performParentNavigationForTesting()
        XCTAssertEqual(requestedPath, "/")
    }

    func testRemoteTableRejectsSameDeviceDirectoryDropOntoItsOwnPath() {
        let remote = IndependentRemoteFilesViewController(
            title: "主服务器",
            protocolName: "SCP",
            initialPath: "/archive",
            dragSourceRuntimeID: "same-runtime"
        )
        remote.loadView()
        remote.setEntries([
            RemoteFileEntry(
                kind: .directory,
                path: "/archive/reports",
                size: 0,
                linkTarget: nil
            )
        ], path: "/archive")
        var routedDestinations: [String] = []
        remote.onRemoteSelectionsDropped = { _, _, destination in
            routedDestinations.append(destination)
        }
        let selection = RemoteFileSelection(
            path: "/archive/reports",
            size: 0,
            kind: .directory
        )

        remote.tableView.onRemoteFileDrop?("same-runtime", [selection], 0)

        XCTAssertTrue(routedDestinations.isEmpty)

        remote.tableView.onRemoteFileDrop?("other-runtime", [selection], 0)
        XCTAssertEqual(routedDestinations, ["/archive/reports"])
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func containsViewController<T: NSViewController>(ofType type: T.Type, in root: NSViewController) -> Bool {
        if root is T { return true }
        return root.children.contains { containsViewController(ofType: type, in: $0) }
    }

    private func makeIndependentBrowser(
        runtimeID: String,
        defaults: UserDefaults,
        bridge: IndependentTransferBrowserBridge = IndependentTransferBrowserBridge()
    ) -> IndependentFileTransferBrowserViewController {
        bridge.entriesByPath["~"] = bridge.entriesByPath["~"] ?? []
        return IndependentFileTransferBrowserViewController(
            runtimeID: runtimeID,
            context: Self.liveContext(),
            title: "生产服务器",
            bridge: SFTPRemoteFilesBridgeAdapter(base: bridge),
            transferScheduler: nil,
            remoteProtocolName: "SFTP",
            initialRemotePath: "~",
            initialLoadPresentation: .immediate,
            layoutDefaults: defaults,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "\(runtimeID)_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            )
        )
    }

    private func makeRenameBrowser(
        runtimeID: String,
        bridge: IndependentTransferBrowserBridge,
        conflictResolver: RemoteFileConflictResolving
    ) -> IndependentFileTransferBrowserViewController {
        IndependentFileTransferBrowserViewController(
            runtimeID: runtimeID,
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: IndependentSCPTransferScheduler(),
            remoteProtocolName: "SCP",
            initialRemotePath: "/srv",
            initialLoadPresentation: .immediate,
            layoutDefaults: makeIsolatedDefaults(),
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "\(runtimeID)_local",
                directoryURL: FileManager.default.homeDirectoryForCurrentUser,
                title: "本地文件"
            ),
            conflictResolver: conflictResolver
        )
    }

    private struct AtomicUploadFailureFixture {
        let localDirectory: URL
        let source: URL
        let bridge: IndependentTransferBrowserBridge
        let scheduler: IndependentSCPTransferScheduler
        let browser: IndependentFileTransferBrowserViewController
    }

    private func makeAtomicUploadFailureFixture(runtimeID: String) throws -> AtomicUploadFailureFixture {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAtomicUploadFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let source = localDirectory.appendingPathComponent("report.txt")
        try Data("replacement".utf8).write(to: source)
        let bridge = IndependentTransferBrowserBridge()
        bridge.entriesByPath["/incoming"] = [
            RemoteFileEntry(kind: .file, path: "/incoming/report.txt", size: 3, linkTarget: nil)
        ]
        let scheduler = IndependentSCPTransferScheduler()
        let browser = IndependentFileTransferBrowserViewController(
            runtimeID: runtimeID,
            context: Self.liveContext(),
            title: "主服务器",
            bridge: bridge,
            transferScheduler: scheduler,
            remoteProtocolName: "SCP",
            initialRemotePath: "/incoming",
            initialLoadPresentation: .immediate,
            localFilesViewController: LocalFilePaneViewController(
                runtimeID: "\(runtimeID)_local",
                directoryURL: localDirectory,
                title: "本地文件"
            ),
            conflictResolver: IndependentBlockingConflictResolver(
                decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: false),
                startsBlocked: false
            )
        )
        browser.loadView()
        return AtomicUploadFailureFixture(
            localDirectory: localDirectory,
            source: source,
            bridge: bridge,
            scheduler: scheduler,
            browser: browser
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "StacioTests.FileTransferLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private static func liveContext(host: String = "files.example.com") -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: host,
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:files"
        )
    }

}

private final class IndependentTransferBrowserBridge: RemoteFilesBridging {
    struct PathPair: Equatable {
        let from: String
        let to: String
    }

    var entriesByPath: [String: [RemoteFileEntry]] = [:]
    var fileDataByPath: [String: Data] = [:]
    var renameErrorsByCallIndex: [Int: NSError] = [:]
    var deleteErrorsByCallIndex: [Int: NSError] = [:]
    private(set) var writtenFileDataByPath: [String: Data] = [:]
    private(set) var listedSCPPaths: [String] = []
    private(set) var listedSFTPPaths: [String] = []
    var onDeleteRemotePath: ((String) -> Void)?
    private let deletedPathsLock = NSLock()
    private var deletedPathsStorage: [String] = []
    private var renamedPathsStorage: [PathPair] = []

    var deletedPaths: [String] {
        deletedPathsLock.lock()
        defer { deletedPathsLock.unlock() }
        return deletedPathsStorage
    }

    var renamedPaths: [PathPair] {
        deletedPathsLock.lock()
        defer { deletedPathsLock.unlock() }
        return renamedPathsStorage
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] { [] }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        listedSCPPaths.append(remotePath)
        return entriesByPath[remotePath] ?? []
    }

    func listLiveSFTPDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        listedSFTPPaths.append(remotePath)
        return entriesByPath[remotePath] ?? []
    }

    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        Self.slice(fileDataByPath[remotePath] ?? Data(), offset: offset, length: length)
    }

    func writeLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        fileDataByPath[remotePath] = contents
        writtenFileDataByPath[remotePath] = contents
        return UInt64(contents.count)
    }

    func readLiveSFTPFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        try readLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            offset: offset,
            length: length
        )
    }

    func writeLiveSFTPFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        try writeLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            contents: contents
        )
    }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        deletedPathsLock.lock()
        let callIndex = renamedPathsStorage.count + 1
        renamedPathsStorage.append(PathPair(from: fromPath, to: toPath))
        let error = renameErrorsByCallIndex[callIndex]
        if error == nil, let data = fileDataByPath.removeValue(forKey: fromPath) {
            fileDataByPath[toPath] = data
            writtenFileDataByPath.removeValue(forKey: fromPath)
            writtenFileDataByPath[toPath] = data
        }
        deletedPathsLock.unlock()
        if let error { throw error }
    }

    func renameLiveSFTPPath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        try renameLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            fromPath: fromPath,
            toPath: toPath
        )
    }

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        deletedPathsLock.lock()
        let callIndex = deletedPathsStorage.count + 1
        deletedPathsStorage.append(remotePath)
        let error = deleteErrorsByCallIndex[callIndex]
        if error == nil {
            fileDataByPath.removeValue(forKey: remotePath)
            writtenFileDataByPath.removeValue(forKey: remotePath)
        }
        deletedPathsLock.unlock()
        onDeleteRemotePath?(remotePath)
        if let error { throw error }
    }

    func deleteLiveSFTPPath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        try deleteLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: remotePath,
            recursive: recursive
        )
    }

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}

    private static func slice(_ data: Data, offset: UInt64, length: UInt64?) -> Data {
        let start = min(Int(clamping: offset), data.count)
        let requestedEnd = length.map { start + Int(clamping: $0) } ?? data.count
        return data.subdata(in: start..<min(requestedEnd, data.count))
    }
}

private final class IndependentRelayBlockingTransferBridge: SCPTransferBridging, SFTPTransferBridging {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let acceptsCancellation: Bool
    private let completionStatus: String
    private let materializesCompletedDownloads: Bool
    private var startedSCPJobIDsStorage: [String] = []
    private var startedSFTPJobIDsStorage: [String] = []
    private var cancelledSCPJobIDsStorage: [String] = []
    private var cancelledSFTPJobIDsStorage: [String] = []
    private var jobsStorage: [ScpTransferJob] = []

    var startedSCPJobIDs: [String] { locked { startedSCPJobIDsStorage } }
    var startedSFTPJobIDs: [String] { locked { startedSFTPJobIDsStorage } }
    var cancelledSCPJobIDs: [String] { locked { cancelledSCPJobIDsStorage } }
    var cancelledSFTPJobIDs: [String] { locked { cancelledSFTPJobIDsStorage } }
    var jobs: [ScpTransferJob] { locked { jobsStorage } }

    init(
        acceptsCancellation: Bool = true,
        completionStatus: String = "canceled",
        materializesCompletedDownloads: Bool = false
    ) {
        self.acceptsCancellation = acceptsCancellation
        self.completionStatus = completionStatus
        self.materializesCompletedDownloads = materializesCompletedDownloads
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        locked {
            startedSCPJobIDsStorage.append(job.id)
            jobsStorage.append(job)
        }
        gate.wait()
        materializeCompletedDownloadIfNeeded(job)
        return [terminalProgress(for: job)]
    }

    func runLiveSFTPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        locked {
            startedSFTPJobIDsStorage.append(job.id)
            jobsStorage.append(job)
        }
        gate.wait()
        materializeCompletedDownloadIfNeeded(job)
        return [terminalProgress(for: job)]
    }

    func cancelLiveSCPTransfer(jobID: String) -> Bool {
        locked { cancelledSCPJobIDsStorage.append(jobID) }
        return acceptsCancellation
    }

    func cancelLiveSFTPTransfer(jobID: String) -> Bool {
        locked { cancelledSFTPJobIDsStorage.append(jobID) }
        return acceptsCancellation
    }

    func release() {
        gate.signal()
    }

    private func terminalProgress(for job: ScpTransferJob) -> ScpTransferProgress {
        ScpTransferProgress(
            jobId: job.id,
            bytesDone: completionStatus == "completed" ? job.bytesTotal : 0,
            bytesTotal: job.bytesTotal,
            status: completionStatus
        )
    }

    private func materializeCompletedDownloadIfNeeded(_ job: ScpTransferJob) {
        guard materializesCompletedDownloads,
              completionStatus == "completed",
              job.direction == .download
        else { return }
        let destination = URL(fileURLWithPath: job.destinationPath)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(repeating: 0x52, count: Int(clamping: job.bytesTotal)).write(to: destination)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class IndependentBlockingConflictResolver: RemoteFileConflictResolving {
    private let decision: RemoteFileConflictDecision?
    private let requested = DispatchSemaphore(value: 0)
    private let release: DispatchSemaphore?
    private let requestLock = NSLock()
    private var requestedPathsStorage: [String] = []
    private var requestedDirectionsStorage: [ScpDirection] = []

    var requestedPaths: [String] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requestedPathsStorage
    }

    var requestedDirections: [ScpDirection] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requestedDirectionsStorage
    }

    init(decision: RemoteFileConflictDecision?, startsBlocked: Bool = true) {
        self.decision = decision
        self.release = startsBlocked ? DispatchSemaphore(value: 0) : nil
    }

    func resolveConflict(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> ScpConflictPolicy? {
        resolveConflictDecision(
            destinationPath: destinationPath,
            direction: direction,
            parentWindow: parentWindow
        )?.policy
    }

    func resolveConflictDecision(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> RemoteFileConflictDecision? {
        requestLock.lock()
        requestedPathsStorage.append(destinationPath)
        requestedDirectionsStorage.append(direction)
        requestLock.unlock()
        requested.signal()
        release?.wait()
        return decision
    }

    func waitUntilRequested() -> Bool {
        requested.wait(timeout: .now() + 1) == .success
    }

    func resume() {
        release?.signal()
    }
}

@MainActor
private final class IndependentSFTPTransferScheduler: SFTPTransferScheduling {
    private(set) var runtimeIDs: [String] = []
    private(set) var jobs: [ScpTransferJob] = []
    private(set) var notificationPolicies: [TransferCompletionNotificationPolicy] = []
    private(set) var disconnectedRuntimeIDs: [String] = []

    func scheduleLiveSFTPTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduleLiveSFTPTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .userVisible,
            completion: completion
        )
    }

    func scheduleLiveSFTPTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        notificationPolicy: TransferCompletionNotificationPolicy,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        runtimeIDs.append(runtimeID)
        jobs.append(job)
        notificationPolicies.append(notificationPolicy)
    }

    func disconnectTransfers(runtimeID: String) -> [String] {
        disconnectedRuntimeIDs.append(runtimeID)
        return []
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}
}

@MainActor
private final class IndependentSCPTransferScheduler: SCPTransferScheduling {
    private(set) var runtimeIDs: [String] = []
    private(set) var jobs: [ScpTransferJob] = []
    private(set) var notificationPolicies: [TransferCompletionNotificationPolicy] = []
    private(set) var disconnectedRuntimeIDs: [String] = []
    var materializesCompletedDownloads = false
    var materializesFailedDownloads = false
    private var completions: [String: (ScpTransferProgress) -> Void] = [:]

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduleLiveTransfer(
            runtimeID: runtimeID,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            notificationPolicy: .userVisible,
            completion: completion
        )
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        notificationPolicy: TransferCompletionNotificationPolicy,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        runtimeIDs.append(runtimeID)
        jobs.append(job)
        notificationPolicies.append(notificationPolicy)
        completions[job.id] = completion
    }

    func disconnectTransfers(runtimeID: String) -> [String] {
        disconnectedRuntimeIDs.append(runtimeID)
        return []
    }

    func complete(jobAt index: Int, status: String) {
        guard jobs.indices.contains(index) else { return }
        let job = jobs[index]
        if job.direction == .download,
           (status == "completed" && materializesCompletedDownloads)
            || (status == "failed" && materializesFailedDownloads)
        {
            let destinationURL = URL(fileURLWithPath: job.destinationPath)
            try? FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: destinationURL.path,
                contents: Data(repeating: 0x41, count: Int(clamping: job.bytesTotal))
            )
        }
        completions.removeValue(forKey: job.id)?(
            ScpTransferProgress(
                jobId: job.id,
                bytesDone: status == "completed" ? job.bytesTotal : 0,
                bytesTotal: job.bytesTotal,
                status: status
            )
        )
    }
}

private extension NSView {
    func firstDescendant(accessibilityIdentifier: String) -> NSView? {
        if self.accessibilityIdentifier() == accessibilityIdentifier { return self }
        for child in subviews {
            if let match = child.firstDescendant(accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }
}
