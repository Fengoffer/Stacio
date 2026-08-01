import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class FilesCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    private func liveContext() -> TunnelLiveSessionContext {
        liveContext(host: "example.com")
    }

    private func liveContext(host: String) -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: host,
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test"
        )
    }

    private static let remoteChromiumLaunchOutput = """
    __STACIO_CHROMIUM_PID__=4242
    __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
    __STACIO_CHROMIUM_PORT__=43210
    __STACIO_CHROMIUM_BINARY__=/usr/bin/chromium
    """

    private static func remoteChromiumSession() -> RemoteChromiumRuntimeSession {
        RemoteChromiumRuntimeSession(
            leaseID: UUID(uuidString: "A0A0A0A0-0000-4000-8000-000000000001")!,
            remoteProcessID: 4_242,
            remoteTemporaryDirectory: "/tmp/stacio-chromium.AbC123",
            remoteDownloadsDirectory: "/tmp/stacio-chromium.AbC123/downloads",
            localDebugPort: 19_090,
            pageWebSocketURL: URL(string: "ws://127.0.0.1:19090/devtools/page/page-1")!,
            downloadCapability: RemoteChromiumDownloadCapability(
                sourceLiveSessionContext: TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            )
        )
    }

    private func ftpContext() -> FTPLiveSessionContext {
        FTPLiveSessionContext(
            config: FtpConnectionConfig(
                host: "files.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "secret")
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioFilesCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func fixedBackupDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fixedBackupTimeZone()
        return calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 4,
            hour: 9,
            minute: 12
        ))!
    }

    private func fixedBackupTimeZone() -> TimeZone {
        TimeZone(secondsFromGMT: 8 * 3_600)!
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testCoordinatorParsesRemoteListingAndUpdatesFilesView() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .directory, path: "/var/log", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/etc/hosts", size: 128, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(bridge: bridge, filesViewController: files)

        let entries = try coordinator.loadListing("ignored fixture listing")

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(bridge.events, ["parse"])
        XCTAssertEqual(files.entryCount, 2)
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "log")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 1), "hosts")
        XCTAssertEqual(files.tableView.viewText(atColumn: 1, row: 1), "0.12 KB")
        XCTAssertEqual(files.tableView.viewText(atColumn: 2, row: 1), "—")
        XCTAssertEqual(files.tableView.viewText(atColumn: 3, row: 1), "—")
        XCTAssertEqual(files.tableView.viewText(atColumn: 4, row: 1), "-")
        XCTAssertFalse(files.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
        XCTAssertFalse(bridge.debugDescription.contains("sftp "))
        XCTAssertFalse(bridge.debugDescription.contains("rsync "))
    }

    func testSettingsBackedConflictResolverUsesConfiguredPolicyBeforePrompting() throws {
        let suiteName = "StacioFilesConflictResolver-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let fallback = RecordingRemoteFileConflictResolver(policy: .skip)
        let resolver = SettingsBackedRemoteFileConflictResolver(settingsStore: store, fallback: fallback)

        store.update { settings in
            settings.filesTransferConflictPolicy = .keepBoth
        }

        let configuredPolicy = resolver.resolveConflict(
            destinationPath: "/srv/app/build.zip",
            direction: .upload,
            parentWindow: nil
        )

        XCTAssertEqual(configuredPolicy, .keepBoth)
        XCTAssertTrue(fallback.requests.isEmpty)

        store.update { settings in
            settings.filesTransferConflictPolicy = .ask
        }

        let promptedPolicy = resolver.resolveConflict(
            destinationPath: "/srv/app/build.zip",
            direction: .upload,
            parentWindow: nil
        )

        XCTAssertEqual(promptedPolicy, .skip)
        XCTAssertEqual(fallback.requests.map(\.destinationPath), ["/srv/app/build.zip"])
    }

    func testConflictResolutionSessionCachesApplyToAllDecisionForBatch() {
        let resolver = RecordingBatchConflictResolver(
            decision: RemoteFileConflictDecision(policy: .overwrite, applyToAll: true)
        )
        let session = RemoteFileConflictResolutionSession(resolver: resolver)

        XCTAssertEqual(
            session.resolveConflict(destinationPath: "/srv/one.txt", direction: .upload, parentWindow: nil),
            .overwrite
        )
        XCTAssertEqual(
            session.resolveConflict(destinationPath: "/srv/two.txt", direction: .upload, parentWindow: nil),
            .overwrite
        )
        XCTAssertEqual(resolver.requests, ["/srv/one.txt"])
    }

    func testCoordinatorKeepsEmptyStateWhenListingParseFails() {
        let bridge = RecordingRemoteFilesBridge(error: FilesError.InvalidListingRow)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(bridge: bridge, filesViewController: files)

        XCTAssertThrowsError(try coordinator.loadListing("broken"))

        XCTAssertEqual(files.entryCount, 0)
        XCTAssertTrue(files.visibleTextSnapshot.contains("暂无远端文件"))
    }

    func testCoordinatorLoadsLiveDirectoryAndUpdatesFilesView() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(bridge: bridge, filesViewController: files)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        let entries = try coordinator.loadLiveDirectory(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:test",
            remotePath: "/home/deploy"
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(bridge.events, ["live:/home/deploy"])
        XCTAssertEqual(files.entryCount, 1)
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "app.log")
    }

    func testCoordinatorLoadsCurrentLiveDirectoryFromSessionContextProvider() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/.zshrc", size: 32, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            }
        )

        let entries = try coordinator.loadCurrentLiveDirectory(remotePath: "/home/deploy")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(bridge.events, ["live:/home/deploy"])
        XCTAssertEqual(bridge.liveHosts, ["example.com"])
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), ".zshrc")
    }

    func testCoordinatorSearchesCurrentSSHDirectoryAndShowsRelativeResultPaths() throws {
        let bridge = RecordingRemoteFilesBridge(searchEntries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/logs/app.log", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config/logging.yml", size: 64, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )

        let results = try coordinator.searchRemoteFiles(keyword: "log", directory: "/srv/app", depth: 5)

        XCTAssertEqual(results.map(\.path), [
            "/srv/app/logs/app.log",
            "/srv/app/config/logging.yml"
        ])
        XCTAssertEqual(bridge.events, ["search:/srv/app:log:5"])
        XCTAssertEqual(files.entryCount, 2)
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "app.log")
        XCTAssertEqual(files.tableView.viewText(atColumn: 1, row: 0), "logs/app.log")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 1), "logging.yml")
        XCTAssertEqual(files.tableView.viewText(atColumn: 1, row: 1), "config/logging.yml")
    }

    func testCoordinatorDisablesRemoteSearchForFTPContext() throws {
        let files = FilesViewController()
        files.loadView()
        _ = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            ftpSessionContextProvider: { self.ftpContext() }
        )

        let searchButton = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.search") as? NSButton
        )
        XCTAssertFalse(searchButton.isEnabled)
        XCTAssertEqual(searchButton.toolTip, "FTP 暂不支持远程文件搜索")
    }

    func testCoordinatorOpensSearchResultByRefreshingParentDirectoryAndSelectingFile() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/logs/app.log", size: 128, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil)
        ], remotePath: "/srv/app")
        files.setRemoteSearchResults([
            RemoteFileEntry(kind: .file, path: "/srv/app/logs/app.log", size: 128, linkTarget: nil)
        ], baseDirectory: "/srv/app", keyword: "log")

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.openSelectedEntryForTesting()

        XCTAssertTrue(waitUntil {
            bridge.events == ["live:/srv/app/logs"]
                && files.currentRemotePath == "/srv/app/logs"
                && files.tableView.selectedRow == 0
        })
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "app.log")
        XCTAssertFalse(files.isRemoteSearchActiveForTesting)
    }

    func testCoordinatorConnectsFilesViewRefreshActionToCurrentLiveDirectory() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/var/log/system.log", size: 64, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            }
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let refreshButton = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.refresh") as? NSButton
        )

        pathField.stringValue = "/var/log"
        refreshButton.performClick(nil as Any?)

        XCTAssertTrue(waitUntil { bridge.events == ["live:/var/log"] && files.entryCount == 1 })
        XCTAssertEqual(bridge.events, ["live:/var/log"])
        XCTAssertEqual(files.entryCount, 1)
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "system.log")
    }

    func testCoordinatorConnectsFilesViewOpenDirectoryActionToCurrentLiveDirectory() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .directory, path: "/srv/app/releases", size: 0, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app", size: 0, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.openSelectedEntryForTesting()

        XCTAssertTrue(waitUntil { bridge.events == ["live:/srv/app"] && files.entryCount == 1 })
        XCTAssertEqual(bridge.events, ["live:/srv/app"])
        XCTAssertEqual(files.entryCount, 1)
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "releases")
    }

    func testCoordinatorOpenDirectoryReturnsImmediatelyWhileLiveListingRuns() throws {
        let bridge = DelayedRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 64, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app", size: 0, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let start = Date()
        files.openSelectedEntryForTesting()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertEqual(files.currentRemotePath, "/srv/app")
        XCTAssertTrue(files.visibleTextSnapshot.contains("正在加载远端目录"))
        XCTAssertTrue(bridge.waitUntilStarted())
        XCTAssertEqual(bridge.eventsSnapshot, ["live:/srv/app"])

        bridge.releaseListing()
        XCTAssertTrue(waitUntil { files.entryCount == 1 })
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "app.log")
    }

    func testCoordinatorShowsCachedDirectoryImmediatelyWhileRefreshingInBackground() throws {
        let bridge = CachedThenDelayedRemoteFilesBridge(
            cachedEntries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/cached.log", size: 64, linkTarget: nil)
            ],
            refreshedEntries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/fresh.log", size: 96, linkTarget: nil)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )

        _ = try coordinator.loadCurrentLiveDirectory(remotePath: "/srv/app")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "cached.log")

        files.setCurrentRemotePath("/")
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app", size: 0, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let start = Date()
        files.openSelectedEntryForTesting()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertEqual(files.currentRemotePath, "/srv/app")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "cached.log")
        XCTAssertFalse(files.visibleTextSnapshot.contains("正在加载远端目录"))
        XCTAssertTrue(bridge.waitUntilRefreshStarted())

        bridge.releaseRefresh()

        XCTAssertTrue(waitUntil { files.tableView.viewText(atColumn: 0, row: 0) == "fresh.log" })
        XCTAssertEqual(bridge.eventsSnapshot, ["live:/srv/app", "live:/srv/app"])
    }

    func testCoordinatorKeepsVisibleCachedDirectoryAndDoesNotPresentModalWhenBackgroundRefreshFails() throws {
        let bridge = CachedThenFailingRemoteFilesBridge(
            cachedEntries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/cached.log", size: 64, linkTarget: nil)
            ],
            refreshError: FilesError.UnsafePath
        )
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            errorPresenter: errorPresenter
        )

        _ = try coordinator.loadCurrentLiveDirectory(remotePath: "/srv/app")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "cached.log")

        coordinator.refreshCurrentLiveDirectory(remotePath: "/srv/app")

        XCTAssertTrue(waitUntil { bridge.eventsSnapshot == ["live:/srv/app", "live:/srv/app"] })
        XCTAssertEqual(errorPresenter.contexts, [])
        XCTAssertEqual(files.currentRemotePath, "/srv/app")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "cached.log")
        XCTAssertFalse(files.visibleTextSnapshot.contains("无法加载远端目录"))
        XCTAssertFalse(files.visibleTextSnapshot.contains("无法刷新远端目录"))
    }

    func testCoordinatorBackgroundDirectoryFollowReturnsBeforeRemoteListingCompletes() throws {
        let bridge = DelayedRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/followed.log", size: 64, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )

        let start = Date()
        coordinator.refreshCurrentLiveDirectory(remotePath: "/srv/app", presentation: .backgroundFollow)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertTrue(bridge.waitUntilStarted())
        XCTAssertEqual(files.currentRemotePath, "~")

        bridge.releaseListing()

        XCTAssertTrue(waitUntil { files.currentRemotePath == "/srv/app" })
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "followed.log")
        XCTAssertEqual(bridge.eventsSnapshot, ["live:/srv/app"])
    }

    func testCoordinatorCachesInferredHomeDirectoryForImmediateRefresh() throws {
        let bridge = CachedThenDelayedRemoteFilesBridge(
            cachedEntries: [
                RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
            ],
            refreshedEntries: [
                RemoteFileEntry(kind: .file, path: "/home/deploy/fresh.log", size: 96, linkTarget: nil)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )

        _ = try coordinator.loadCurrentLiveDirectory(remotePath: "~")
        XCTAssertEqual(files.currentRemotePath, "/home/deploy")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "app.log")

        let start = Date()
        coordinator.refreshCurrentLiveDirectory(remotePath: files.currentRemotePath)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertEqual(files.currentRemotePath, "/home/deploy")
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "app.log")
        XCTAssertFalse(files.visibleTextSnapshot.contains("正在加载远端目录"))
        XCTAssertTrue(bridge.waitUntilRefreshStarted())

        bridge.releaseRefresh()

        XCTAssertTrue(waitUntil { files.tableView.viewText(atColumn: 0, row: 0) == "fresh.log" })
        XCTAssertEqual(bridge.eventsSnapshot, ["live:~", "live:/home/deploy"])
    }

    func testCoordinatorInjectedOpenerIgnoresStaleLocalCacheAndReadsRemoteOnline() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"remote":true}"#.utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 128, kind: .file)
        let cachedItem = try cache.createItem(
            from: selection,
            runtimeID: "example.com",
            sessionID: "session-alpha"
        )
        try #"{"cached":true}"#.write(to: cachedItem.localURL, atomically: true, encoding: .utf8)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: selection.path, size: selection.size, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)
        XCTAssertEqual(request.document.remotePath, "/srv/app/config.json")
        XCTAssertEqual(request.document.content, #"{"remote":true}"#)
        XCTAssertEqual(request.mode, .textEditor)
        XCTAssertTrue(opener.openRequests.isEmpty)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testCoordinatorBuildsAIContextAttachmentFromSelectedRemoteTextFile() throws {
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/.env": Data("DATABASE_URL=mysql://root:secret@example/db\nPUBLIC_PORT=3000\n".utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/.env", size: 58, linkTarget: nil)
        ])
        files.selectRemotePath("/srv/app/.env")

        let attachment = try coordinator.makeSelectedRemoteFileAIContextAttachment()

        XCTAssertEqual(bridge.readRequests.map(\.path), ["/srv/app/.env"])
        XCTAssertEqual(bridge.readRequests.map(\.length), [FilesCoordinator.maximumAIContextAttachmentBytes])
        XCTAssertEqual(attachment.filename, ".env")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.byteCount, 58)
        XCTAssertTrue(attachment.textPreview?.contains("PUBLIC_PORT=3000") == true)
        XCTAssertFalse(attachment.textPreview?.contains("secret") == true)
        XCTAssertTrue(attachment.textPreview?.contains("[redacted]") == true)
    }

    func testCoordinatorRejectsOversizedRemoteFileBeforeReadingAIContext() throws {
        let bridge = RecordingRemoteFilesBridge()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/large.log",
                size: FilesCoordinator.maximumAIContextAttachmentBytes + 1,
                linkTarget: nil
            )
        ])
        files.selectRemotePath("/srv/app/large.log")

        XCTAssertThrowsError(try coordinator.makeSelectedRemoteFileAIContextAttachment()) { error in
            XCTAssertEqual(error as? AIAssistantRemoteFileAttachmentError, .fileTooLarge)
        }
        XCTAssertTrue(bridge.readRequests.isEmpty)
    }

    func testCoordinatorRejectsBinaryRemoteFileForAIContext() throws {
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/archive.bin": Data([0x00, 0x01, 0x02, 0x03])
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/archive.bin", size: 4, linkTarget: nil)
        ])
        files.selectRemotePath("/srv/app/archive.bin")

        XCTAssertThrowsError(try coordinator.makeSelectedRemoteFileAIContextAttachment()) { error in
            XCTAssertEqual(error as? AIAssistantRemoteFileAttachmentError, .textOnly)
        }
    }

    func testCoordinatorRejectsFTPRemoteFileForAIContext() throws {
        let bridge = RecordingRemoteFilesBridge()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { nil },
            ftpSessionContextProvider: { self.ftpContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.txt", size: 12, linkTarget: nil)
        ])
        files.selectRemotePath("/pub/config.txt")

        XCTAssertThrowsError(try coordinator.makeSelectedRemoteFileAIContextAttachment()) { error in
            XCTAssertEqual(error as? AIAssistantRemoteFileAttachmentError, .unsupportedProtocol)
        }
        XCTAssertTrue(bridge.readRequests.isEmpty)
    }

    func testCoordinatorSchedulesSelectedFileDownloadThroughEmbeddedSCPQueue() throws {
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.txt": Data("enabled=true\n".utf8)
            ]
        )
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: "/Users/alice/Downloads/config.json"
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(destinationPicker.suggestedFileNames, ["config.json"])
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.direction, .download)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, "/srv/app/config.json")
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/Users/alice/Downloads/config.json")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 128)
        XCTAssertEqual(scheduler.configs.map(\.host), ["example.com"])
        XCTAssertEqual(scheduler.fingerprints, ["SHA256:test"])
    }

    func testCoordinatorDownloadsRemoteChromiumFileThenReportsVerifiedLocalTransferWithoutDeletingRemotePath() throws {
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("季度报告.pdf")
        let remotePath = "/tmp/stacio-chromium.AbC123/downloads/550e8400-e29b-41d4-a716-446655440000"
        let session = Self.remoteChromiumSession()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: remotePath,
            suggestedFilename: "../../季度报告.pdf"
        )
        let bridge = RecordingRemoteFilesBridge()
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: destinationURL.path
        )
        let files = FilesViewController()
        files.loadView()
        var verifiedDownloads: [RemoteChromiumDownload] = []
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )

        XCTAssertEqual(
            coordinator.scheduleRemoteBrowserDownload(
                download,
                onLocalTransferVerified: { verifiedDownloads.append(download) }
            ),
            .scheduled
        )
        XCTAssertEqual(destinationPicker.suggestedFileNames, ["季度报告.pdf"])
        let job = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(job.direction, .download)
        XCTAssertEqual(job.sourcePath, remotePath)
        XCTAssertEqual(job.destinationPath, destinationURL.path)
        XCTAssertEqual(job.bytesTotal, 0)

        try Data("downloaded".utf8).write(to: destinationURL)
        scheduler.complete(jobID: job.id)
        XCTAssertEqual(verifiedDownloads, [download])
        XCTAssertFalse(bridge.events.contains("delete:\(remotePath):false"))
    }

    func testCoordinatorDiscardsRemoteChromiumDownloadWhenUserCancelsDestinationPicker() {
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(destinationPath: nil)
        let files = FilesViewController()
        files.loadView()
        var didVerifyTransfer = false
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        let session = Self.remoteChromiumSession()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-1",
            suggestedFilename: "report.pdf"
        )

        XCTAssertEqual(
            coordinator.scheduleRemoteBrowserDownload(
                download,
                onLocalTransferVerified: { didVerifyTransfer = true }
            ),
            .discarded
        )
        XCTAssertFalse(didVerifyTransfer)
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testCoordinatorDoesNotVerifyFailedRemoteChromiumTransfer() throws {
        let directory = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: directory.appendingPathComponent("report.pdf").path
        )
        let files = FilesViewController()
        files.loadView()
        var didVerifyTransfer = false
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        let session = Self.remoteChromiumSession()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-1",
            suggestedFilename: "report.pdf"
        )

        XCTAssertEqual(
            coordinator.scheduleRemoteBrowserDownload(
                download,
                onLocalTransferVerified: { didVerifyTransfer = true }
            ),
            .scheduled
        )
        let job = try XCTUnwrap(scheduler.jobs.first)
        scheduler.fail(jobID: job.id)

        XCTAssertFalse(didVerifyTransfer)
    }

    func testCoordinatorRejectsRemoteChromiumDownloadOutsideOwnedTemporaryDirectory() {
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: "/Users/alice/Downloads/report.pdf"
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        let session = Self.remoteChromiumSession()

        XCTAssertEqual(
            coordinator.scheduleRemoteBrowserDownload(
                RemoteChromiumDownload(
                    session: session,
                    remotePath: "/tmp/report.pdf",
                    suggestedFilename: "report.pdf"
                ),
                onLocalTransferVerified: {}
            ),
            .rejected
        )
        XCTAssertTrue(destinationPicker.suggestedFileNames.isEmpty)
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testInspectorAcknowledgesRemoteChromiumDownloadOnlyAfterVerifiedLocalTransfer() throws {
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("report.pdf")
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: destinationURL.path
        )
        let session = Self.remoteChromiumSession()
        let runtime = RecordingFilesRemoteChromiumRuntime(session: session)
        let inspector = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: runtime,
            filesTransferSchedulerOverride: scheduler,
            remoteBrowserDownloadDestinationPicker: destinationPicker
        )
        inspector.loadView()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-1",
            suggestedFilename: "report.pdf"
        )

        inspector.remoteChromiumDidCompleteDownload(download)
        XCTAssertTrue(runtime.acknowledgedDownloads.isEmpty)

        let job = try XCTUnwrap(scheduler.jobs.first)
        try Data("downloaded".utf8).write(to: destinationURL)
        scheduler.complete(jobID: job.id)

        XCTAssertEqual(runtime.acknowledgedDownloads, [download])
    }

    func testInspectorKeepsRemoteDownloadAcknowledgementAliveUntilTransferFinishes() throws {
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("report.pdf")
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: destinationURL.path
        )
        let session = Self.remoteChromiumSession()
        let runtime = RecordingFilesRemoteChromiumRuntime(session: session)
        var inspector: InspectorViewController? = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: runtime,
            filesTransferSchedulerOverride: scheduler,
            remoteBrowserDownloadDestinationPicker: destinationPicker
        )
        inspector?.loadView()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-1",
            suggestedFilename: "report.pdf"
        )

        inspector?.remoteChromiumDidCompleteDownload(download)
        let inspectorLifetime = WeakFilesObjectBox(inspector)
        inspector = nil
        XCTAssertNil(inspectorLifetime.value)

        let job = try XCTUnwrap(scheduler.jobs.first)
        try Data("downloaded".utf8).write(to: destinationURL)
        scheduler.complete(jobID: job.id)

        XCTAssertEqual(runtime.acknowledgedDownloads, [download])
    }

    func testRemoteChromiumDownloadUsesItsSourceSSHContextAfterInspectorBindingSwitches() throws {
        let sourceContext = liveContext(host: "source-a.internal")
        let currentContext = liveContext(host: "current-b.internal")
        let chromiumExecutor = FilesRemoteChromiumCommandExecutor(outputs: [
            Self.remoteChromiumLaunchOutput,
            ""
        ])
        let chromiumRuntime = RemoteChromiumRuntime(
            commandExecutor: chromiumExecutor,
            tunnelBridge: FilesRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try chromiumRuntime.start(context: sourceContext, localPort: 19_090)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { currentContext },
            liveSessionRuntimeIDProvider: { "runtime-b" },
            transferScheduler: scheduler,
            downloadDestinationPicker: RecordingDownloadDestinationPicker(
                destinationPath: "/Users/alice/Downloads/source-a.pdf"
            )
        )
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-source-a",
            suggestedFilename: "source-a.pdf"
        )

        XCTAssertEqual(
            coordinator.scheduleRemoteBrowserDownload(download, onLocalTransferVerified: {}),
            .scheduled
        )

        XCTAssertEqual(scheduler.configs.map(\.host), ["source-a.internal"])
        XCTAssertEqual(scheduler.runtimeIDs, ["source-a.internal"])
        chromiumRuntime.stop(session: session)
    }

    func testDefaultTransferQueueOutlivesInspectorUntilRemoteBrowserDownloadFinishes() throws {
        let transferStarted = expectation(description: "remote browser transfer started")
        let bridge = BlockingFilesSCPTransferBridge(started: transferStarted)
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("report.pdf")
        let session = Self.remoteChromiumSession()
        let runtime = RecordingFilesRemoteChromiumRuntime(session: session)
        var queueLifetime: WeakFilesObjectBox<TransferQueueCoordinator>?
        var inspector: InspectorViewController? = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: runtime,
            remoteBrowserDownloadDestinationPicker: RecordingDownloadDestinationPicker(
                destinationPath: destinationURL.path
            ),
            transferQueueCoordinatorFactory: { queueView in
                let coordinator = TransferQueueCoordinator(
                    bridge: bridge,
                    queueViewController: queueView
                )
                queueLifetime = WeakFilesObjectBox(coordinator)
                return coordinator
            }
        )
        inspector?.loadView()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-lifecycle",
            suggestedFilename: "report.pdf"
        )

        inspector?.remoteChromiumDidCompleteDownload(download)
        wait(for: [transferStarted], timeout: 1)
        let inspectorLifetime = WeakFilesObjectBox(inspector)
        inspector = nil

        XCTAssertNil(inspectorLifetime.value)
        XCTAssertNotNil(queueLifetime?.value, "An active browser download must own the production queue lifecycle.")

        try Data("downloaded".utf8).write(to: destinationURL)
        bridge.release()

        XCTAssertTrue(waitUntil { runtime.acknowledgedDownloads == [download] })
        XCTAssertTrue(waitUntil { queueLifetime?.value == nil })
    }

    func testRemoteBrowserDownloadExplicitlyRetainsSchedulerAfterInspectorCloses() throws {
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("report.pdf")
        let driver = DeferredFilesTransferCompletionDriver()
        var scheduler: DeferredFilesSCPTransferScheduler? = DeferredFilesSCPTransferScheduler(
            driver: driver
        )
        let schedulerLifetime = WeakFilesObjectBox(scheduler)
        let session = Self.remoteChromiumSession()
        let runtime = RecordingFilesRemoteChromiumRuntime(session: session)
        var inspector: InspectorViewController? = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: runtime,
            filesTransferSchedulerOverride: scheduler,
            remoteBrowserDownloadDestinationPicker: RecordingDownloadDestinationPicker(
                destinationPath: destinationURL.path
            )
        )
        inspector?.loadView()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-explicit-lifetime",
            suggestedFilename: "report.pdf"
        )

        inspector?.remoteChromiumDidCompleteDownload(download)
        let inspectorLifetime = WeakFilesObjectBox(inspector)
        inspector = nil
        scheduler = nil

        XCTAssertNil(inspectorLifetime.value)
        XCTAssertNotNil(schedulerLifetime.value, "The browser-download lifetime must retain its scheduler.")

        try Data("downloaded".utf8).write(to: destinationURL)
        driver.complete()

        XCTAssertEqual(runtime.acknowledgedDownloads, [download])
        XCTAssertNil(schedulerLifetime.value)
    }

    func testInspectorAcknowledgesDiscardedRemoteChromiumDownloadButKeepsFailedTransfer() throws {
        let session = Self.remoteChromiumSession()
        let canceledRuntime = RecordingFilesRemoteChromiumRuntime(session: session)
        let canceledScheduler = RecordingSCPTransferScheduler()
        let canceledInspector = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: canceledRuntime,
            filesTransferSchedulerOverride: canceledScheduler,
            remoteBrowserDownloadDestinationPicker: RecordingDownloadDestinationPicker(destinationPath: nil)
        )
        canceledInspector.loadView()
        let canceledDownload = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-canceled",
            suggestedFilename: "canceled.pdf"
        )

        canceledInspector.remoteChromiumDidCompleteDownload(canceledDownload)

        XCTAssertEqual(canceledRuntime.acknowledgedDownloads, [canceledDownload])
        XCTAssertTrue(canceledScheduler.jobs.isEmpty)

        let directory = try makeTemporaryDirectory()
        let failedRuntime = RecordingFilesRemoteChromiumRuntime(session: session)
        let failedScheduler = RecordingSCPTransferScheduler()
        let failedInspector = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: failedRuntime,
            filesTransferSchedulerOverride: failedScheduler,
            remoteBrowserDownloadDestinationPicker: RecordingDownloadDestinationPicker(
                destinationPath: directory.appendingPathComponent("failed.pdf").path
            )
        )
        failedInspector.loadView()
        let failedDownload = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-failed",
            suggestedFilename: "failed.pdf"
        )

        failedInspector.remoteChromiumDidCompleteDownload(failedDownload)
        let failedJob = try XCTUnwrap(failedScheduler.jobs.first)
        failedScheduler.fail(jobID: failedJob.id)

        XCTAssertTrue(failedRuntime.acknowledgedDownloads.isEmpty)
    }

    func testInspectorReportsRemoteChromiumCleanupFailureToDiagnosticsLog() throws {
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("report.pdf")
        let scheduler = RecordingSCPTransferScheduler()
        let session = Self.remoteChromiumSession()
        let runtime = RecordingFilesRemoteChromiumRuntime(
            session: session,
            acknowledgementResult: .failure(RecordingFilesRemoteChromiumRuntimeError.cleanupFailed)
        )
        let logStore = RecordingStacioLogStore()
        let inspector = InspectorViewController(
            tunnelLiveSessionContextProvider: { self.liveContext() },
            remoteChromiumRuntime: runtime,
            filesTransferSchedulerOverride: scheduler,
            remoteBrowserDownloadDestinationPicker: RecordingDownloadDestinationPicker(
                destinationPath: destinationURL.path
            ),
            remoteBrowserDownloadLog: logStore
        )
        inspector.loadView()
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/guid-1",
            suggestedFilename: "report.pdf"
        )

        inspector.remoteChromiumDidCompleteDownload(download)
        let job = try XCTUnwrap(scheduler.jobs.first)
        try Data("downloaded".utf8).write(to: destinationURL)
        scheduler.complete(jobID: job.id)

        XCTAssertEqual(runtime.acknowledgedDownloads, [download])
        XCTAssertTrue(logStore.lines.contains { $0.contains("remote.browser.download.cleanup.failed") })
    }

    func testCoordinatorSchedulesMultipleFileAndDirectoryDownloadsThroughEmbeddedSCPQueue() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: nil,
            destinationDirectory: "/Users/alice/Downloads/remote"
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/readme.md", size: 256, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(destinationPicker.pickDirectoryCount, 1)
        XCTAssertTrue(destinationPicker.suggestedFileNames.isEmpty)
        XCTAssertEqual(scheduler.jobs.map(\.direction), [.download, .download, .download])
        XCTAssertEqual(scheduler.jobs.map(\.sourcePath), [
            "/srv/app/logs",
            "/srv/app/config.json",
            "/srv/app/readme.md"
        ])
        XCTAssertEqual(scheduler.jobs.map(\.destinationPath), [
            "/Users/alice/Downloads/remote/logs",
            "/Users/alice/Downloads/remote/config.json",
            "/Users/alice/Downloads/remote/readme.md"
        ])
        XCTAssertEqual(scheduler.jobs.map(\.bytesTotal), [0, 128, 256])
        XCTAssertEqual(scheduler.configs.map(\.host), ["example.com", "example.com", "example.com"])
        XCTAssertEqual(scheduler.fingerprints, ["SHA256:test", "SHA256:test", "SHA256:test"])
    }

    func testCoordinatorSchedulesSingleDirectoryDownloadToPickedDirectory() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: nil,
            destinationDirectory: "/Users/alice/Downloads"
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(destinationPicker.pickDirectoryCount, 1)
        XCTAssertTrue(destinationPicker.suggestedFileNames.isEmpty)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, "/srv/app/logs")
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/Users/alice/Downloads/logs")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 0)
    }

    func testCoordinatorOpensRemoteEditOnlineWithoutCacheDownload() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertTrue(opener.openedURLs.isEmpty)
        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)
        XCTAssertEqual(request.document.remotePath, "/srv/app/config.json")
        XCTAssertEqual(request.document.content, #"{"enabled":true}"#)
        XCTAssertEqual(request.mode, .textEditor)
    }

    func testCoordinatorCarriesPreparedRequestIdentityThroughAsyncSuccessAndFailure() throws {
        let successPath = "/srv/app/success.conf"
        let failurePath = "/srv/app/failure.conf"
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(
                remoteFileData: [successPath: Data("enabled=true\n".utf8)]
            ),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            remoteEditOpener: opener
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: successPath, size: 13, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: failurePath, size: 13, linkTarget: nil)
        ])

        files.selectRemotePath(successPath)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequestIDs.count == 1 })

        files.selectRemotePath(failurePath)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.failedOpenRequestIDs.count == 1 })

        XCTAssertEqual(opener.preparedRequestIDs.count, 2)
        XCTAssertEqual(opener.remoteDocumentRequestIDs, [opener.preparedRequestIDs[0]])
        XCTAssertEqual(opener.failedOpenRequestIDs, [opener.preparedRequestIDs[1]])
    }

    func testCoordinatorKeepsTextOnlineAndRoutesRemoteMediaThroughPresentationCacheDownload() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let opener = RecordingRemoteEditOpener()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/screenshot.png", size: 1_024, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        files.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        files.openSelectedEntryForTesting()

        let mediaDownload = try XCTUnwrap(
            scheduler.jobs.first { $0.id.hasPrefix("remote_edit_download_") }
        )
        XCTAssertEqual(mediaDownload.sourcePath, "/srv/app/screenshot.png")
        scheduler.complete(jobID: mediaDownload.id)

        XCTAssertEqual(bridge.readRequests.map(\.path), ["/srv/app/config.json"])
        let textRequest = try XCTUnwrap(opener.remoteDocumentRequests.first)
        XCTAssertEqual(textRequest.document.content, #"{"enabled":true}"#)
        try textRequest.saveHandler?(#"{"enabled":false}"#)
        let mediaRequest = try XCTUnwrap(opener.openRequests.first)
        XCTAssertEqual(mediaRequest.mode, .mediaPreview)
        XCTAssertEqual(mediaRequest.url.path, mediaDownload.destinationPath)
        XCTAssertEqual(opener.localCopyRequestIDs.last, opener.preparedRequestIDs.last)

        XCTAssertEqual(bridge.writeRequests.count, 1)
        XCTAssertEqual(bridge.writeRequests.first?.path, "/srv/app/config.json")
        XCTAssertEqual(String(data: try XCTUnwrap(bridge.writeRequests.first?.contents), encoding: .utf8), #"{"enabled":false}"#)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testCoordinatorPreparesInjectedOpenerBeforeRemoteReadCompletes() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let bridge = DelayedRemoteFileReadBridge(
            remotePath: "/srv/app/config.json",
            data: Data("{}".utf8)
        )
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        XCTAssertTrue(bridge.waitUntilReadStarted())
        XCTAssertEqual(opener.preparedRequestIDs.count, 1)
        XCTAssertTrue(opener.remoteDocumentRequests.isEmpty)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))

        bridge.releaseRead()

        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testCoordinatorIgnoresRemoteOpenReadCompletionAfterPresentationIsClosed() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let bridge = DelayedRemoteFileReadBridge(
            remotePath: "/srv/app/config.json",
            data: Data(#"{"enabled":true}"#.utf8)
        )
        let presentationHarness = makeFilesCoordinatorPresentationHarness(testName: #function)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: presentationHarness.presentation,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 18, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        XCTAssertTrue(bridge.waitUntilReadStarted())
        XCTAssertEqual(presentationHarness.presentation.snapshot.mode, .opening)
        XCTAssertEqual(
            presentationHarness.presentation.requestClose(parentWindow: nil, completion: nil),
            .ready
        )
        XCTAssertEqual(presentationHarness.presentation.snapshot.mode, .closed)

        bridge.releaseRead()

        let reopened = waitUntil(timeout: 0.5) {
            presentationHarness.presentation.currentEditor != nil
        }
        XCTAssertFalse(reopened)
        XCTAssertNil(presentationHarness.presentation.currentEditor)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testCoordinatorRoutesRemoteImageVideoAndAudioThroughInjectedPresentationOpener() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            liveSessionRuntimeIDProvider: { "runtime-media" },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/files-panel-photo.png", size: 1_024, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/files-panel-demo.mp4", size: 2_048, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/files-panel-audio.mp3", size: 3_072, linkTarget: nil)
        ])

        for row in 0..<3 {
            files.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            files.openSelectedEntryForTesting()
        }

        XCTAssertEqual(scheduler.jobs.count, 3)
        XCTAssertEqual(Set(scheduler.jobs.map(\.sourcePath)), Set([
            "/srv/app/files-panel-photo.png",
            "/srv/app/files-panel-demo.mp4",
            "/srv/app/files-panel-audio.mp3"
        ]))
        XCTAssertEqual(opener.preparedRequestIDs.count, 3)
        XCTAssertTrue(opener.remoteDocumentRequests.isEmpty)

        for job in scheduler.jobs {
            scheduler.complete(jobID: job.id)
        }

        XCTAssertEqual(opener.openRequests.count, 3)
        XCTAssertTrue(opener.openRequests.allSatisfy { $0.mode == .mediaPreview })
        XCTAssertEqual(Set(opener.openRequests.map { $0.url.path }), Set(scheduler.jobs.map(\.destinationPath)))
        XCTAssertEqual(opener.localCopyRequestIDs, opener.preparedRequestIDs)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testCoordinatorPresentationOpenerAddsMultipleRemoteTextFilesAsEditorTabsOutsideFiles() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/first.conf": Data("enabled=false\n".utf8),
                "/srv/app/second.log": Data("service started\n".utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let presentationHarness = makeFilesCoordinatorPresentationHarness(testName: #function)
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: presentationHarness.presentation,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/first.conf", size: 14, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/second.log", size: 16, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.openSelectedEntryForTesting()
        XCTAssertTrue(waitUntil {
            presentationHarness.presentation.currentEditor?.tabTitlesForTesting == ["first.conf"]
        })

        files.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        files.openSelectedEntryForTesting()

        XCTAssertTrue(waitUntil { presentationHarness.presentation.currentEditor?.tabTitlesForTesting.count == 2 })
        let editor = try XCTUnwrap(presentationHarness.presentation.currentEditor)
        XCTAssertEqual(editor.tabTitlesForTesting, ["first.conf", "second.log"])
        XCTAssertEqual(editor.activeFileNameForTesting, "second.log")
        XCTAssertEqual(editor.currentTextForTesting, "service started\n")
        XCTAssertEqual(bridge.readRequests.map(\.path), ["/srv/app/first.conf", "/srv/app/second.log"])
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testCoordinatorShowsFailureWhenOpeningAnotherRemoteTextFileFails() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/first.conf": Data("enabled=false\n".utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let presentationHarness = makeFilesCoordinatorPresentationHarness(testName: #function)
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: presentationHarness.presentation,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/first.conf", size: 14, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/missing.log", size: 16, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.openSelectedEntryForTesting()
        XCTAssertTrue(waitUntil {
            presentationHarness.presentation.currentEditor?.tabTitlesForTesting == ["first.conf"]
        })

        files.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        files.openSelectedEntryForTesting()

        XCTAssertTrue(waitUntil { presentationHarness.presentation.currentEditor?.tabTitlesForTesting.count == 2 })
        let editor = try XCTUnwrap(presentationHarness.presentation.currentEditor)
        XCTAssertEqual(editor.tabTitlesForTesting, ["first.conf", "missing.log"])
        XCTAssertEqual(editor.activeFileNameForTesting, "missing.log")
        XCTAssertFalse(editor.canEditTextForTesting)
        XCTAssertTrue(editor.editorErrorTextForTesting?.contains("没有找到远端文件") ?? false)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testCoordinatorDoubleClickUnknownRemoteFileOpensInsideStacioEditorOnline() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let logStore = RecordingStacioLogStore()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/archive.bin": Data("plain text without extension\n".utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" },
            appLog: logStore
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/archive.bin", size: 2_048, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.openSelectedEntryForTesting()

        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertTrue(opener.openRequests.isEmpty)
        XCTAssertTrue(logStore.lines.contains { $0.contains("file.open.request") && $0.contains("/srv/app/archive.bin") })

        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)
        XCTAssertEqual(request.document.remotePath, "/srv/app/archive.bin")
        XCTAssertEqual(request.document.content, "plain text without extension\n")
        XCTAssertEqual(request.mode, .textEditor)
        XCTAssertTrue(logStore.lines.contains { $0.contains("file.open.online.text") })
    }

    func testCoordinatorDoesNotReadLargeRemoteTextFileIntoBuiltInEditor() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/huge.log": Data("small fixture should not be read".utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/huge.log", size: 12 * 1_024 * 1_024, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        XCTAssertTrue(bridge.readRequests.isEmpty)
        XCTAssertEqual(opener.failedOpenRequests.map(\.selection.path), ["/srv/app/huge.log"])
        XCTAssertTrue(opener.failedOpenRequests.first?.message.contains("文件过大") == true)
    }

    func testCoordinatorOpensRemoteFileWithDefaultApplicationAfterDownload() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)

        XCTAssertEqual(scheduler.jobs.count, 1)
        let downloadJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(downloadJob.sourcePath, "/srv/app/config.json")
        XCTAssertTrue(opener.openRequests.isEmpty)

        scheduler.complete(jobID: downloadJob.id)

        let request = try XCTUnwrap(opener.openRequests.first)
        XCTAssertEqual(request.url.path, downloadJob.destinationPath)
        XCTAssertEqual(request.mode, .defaultApplication)
        XCTAssertNil(request.applicationURL)
        XCTAssertEqual(opener.localCopyRequestIDs, opener.preparedRequestIDs)
    }

    func testCoordinatorFailsDefaultApplicationDownloadWithOriginalRequestAfterLiveRuntimeDisappears() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentContext: TunnelLiveSessionContext? = liveContext()
        var currentRuntimeID: String? = "runtime-alpha"
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { currentContext },
            liveSessionRuntimeIDProvider: { currentRuntimeID },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)

        let downloadJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(scheduler.runtimeIDs, ["runtime-alpha"])
        XCTAssertEqual(opener.preparedRequestIDs.count, 1)
        XCTAssertTrue(opener.openRequests.isEmpty)

        currentContext = nil
        currentRuntimeID = nil
        scheduler.complete(jobID: downloadJob.id)

        XCTAssertTrue(opener.openRequests.isEmpty)
        XCTAssertEqual(opener.failedOpenRequestIDs, opener.preparedRequestIDs)
    }

    func testCoordinatorEndsSCPRemoteOpenOnNonterminalProgressAfterRuntimeDisappears() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentContext: TunnelLiveSessionContext? = liveContext()
        var currentRuntimeID: String? = "runtime-alpha"
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { currentContext },
            liveSessionRuntimeIDProvider: { currentRuntimeID },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)
        let downloadJob = try XCTUnwrap(scheduler.jobs.first)

        currentContext = nil
        currentRuntimeID = nil
        scheduler.report(jobID: downloadJob.id, status: "running")

        XCTAssertEqual(opener.failedOpenRequestIDs, opener.preparedRequestIDs)
        scheduler.complete(jobID: downloadJob.id)
        XCTAssertEqual(opener.failedOpenRequestIDs, opener.preparedRequestIDs)
        XCTAssertTrue(opener.localCopyRequestIDs.isEmpty)
    }

    func testCoordinatorEndsSCPRemoteOpenOnEveryFailureTerminalStatusExactlyOnce() throws {
        for terminalStatus in ["failed", "canceled", "cancelled", "stopped"] {
            let cacheRoot = try makeTemporaryDirectory()
            let scheduler = RecordingSCPTransferScheduler()
            let opener = RecordingRemoteEditOpener()
            let files = FilesViewController()
            files.loadView()
            let coordinator = FilesCoordinator(
                bridge: RecordingRemoteFilesBridge(),
                filesViewController: files,
                liveSessionContextProvider: { self.liveContext() },
                transferScheduler: scheduler,
                remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
                remoteEditOpener: opener,
                remoteEditSessionIDProvider: { "session-\(terminalStatus)" }
            )
            XCTAssertNotNil(coordinator)
            files.setRemoteEntries([
                RemoteFileEntry(
                    kind: .file,
                    path: "/srv/app/\(terminalStatus).bin",
                    size: 128,
                    linkTarget: nil
                )
            ])

            files.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)

            let downloadJob = try XCTUnwrap(scheduler.jobs.first)
            XCTAssertEqual(opener.preparedRequestIDs.count, 1, "status=\(terminalStatus)")

            scheduler.report(jobID: downloadJob.id, status: "running")
            XCTAssertTrue(opener.localCopyRequestIDs.isEmpty, "status=\(terminalStatus)")
            XCTAssertTrue(opener.failedOpenRequestIDs.isEmpty, "status=\(terminalStatus)")

            if terminalStatus == "canceled" {
                scheduler.cancel(jobID: downloadJob.id)
            } else {
                scheduler.report(jobID: downloadJob.id, status: terminalStatus)
            }
            XCTAssertEqual(
                opener.failedOpenRequestIDs,
                opener.preparedRequestIDs,
                "status=\(terminalStatus)"
            )

            scheduler.complete(jobID: downloadJob.id)
            XCTAssertTrue(opener.localCopyRequestIDs.isEmpty, "status=\(terminalStatus)")
            XCTAssertEqual(
                opener.failedOpenRequestIDs,
                opener.preparedRequestIDs,
                "A late terminal record must not finish status=\(terminalStatus) twice"
            )
            withExtendedLifetime(coordinator) {}
        }
    }

    func testCoordinatorMarksDownloadedLocalCopyCleanAfterTransferCompletes() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.json",
                size: 18,
                modifiedTime: "2026-06-06T10:00:00Z",
                linkTarget: nil
            )
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)

        let downloadJob = try XCTUnwrap(scheduler.jobs.first)
        try Data(#"{"enabled":true}"#.utf8).write(to: URL(fileURLWithPath: downloadJob.destinationPath))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_600)],
            ofItemAtPath: downloadJob.destinationPath
        )
        scheduler.complete(jobID: downloadJob.id)

        let freshCache = RemoteEditCache(rootDirectory: cacheRoot)
        XCTAssertEqual(freshCache.dirtyItemCount(), 0)
        XCTAssertFalse(try freshCache.item(
            remotePath: "/srv/app/config.json",
            runtimeID: "example.com",
            sessionID: "session-alpha"
        ).isDirty)
    }

    func testCoordinatorPromptsForApplicationAndOpensRemoteFileWithChosenApplication() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let chosenApplicationURL = URL(fileURLWithPath: "/Applications/TextEdit.app", isDirectory: true)
        let prompt = RecordingRemoteFileOperationPrompt(openApplicationURL: chosenApplicationURL)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            operationPrompt: prompt,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "打开方式...", row: 0)

        XCTAssertEqual(prompt.openApplicationPromptCount, 1)
        XCTAssertEqual(scheduler.jobs.count, 1)
        let downloadJob = try XCTUnwrap(scheduler.jobs.first)

        scheduler.complete(jobID: downloadJob.id)

        let request = try XCTUnwrap(opener.openRequests.first)
        XCTAssertEqual(request.url.path, downloadJob.destinationPath)
        XCTAssertEqual(request.mode, .chooseApplication)
        XCTAssertEqual(request.applicationURL, chosenApplicationURL)
    }

    func testCoordinatorComparesTwoRemoteFilesAfterDownloadingLocalCopies() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.old.json", size: 64, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "比较文件...", row: 0)

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs.map(\.sourcePath), [
            "/srv/app/config.json",
            "/srv/app/config.old.json"
        ])
        XCTAssertTrue(opener.comparedURLGroups.isEmpty)

        scheduler.complete(jobID: scheduler.jobs[0].id)
        XCTAssertTrue(opener.comparedURLGroups.isEmpty)
        scheduler.complete(jobID: scheduler.jobs[1].id)

        XCTAssertEqual(opener.comparedURLGroups.map { $0.map(\.path) }, [
            scheduler.jobs.map(\.destinationPath)
        ])
    }

    func testCoordinatorIgnoresRemoteCompareCompletionAfterLiveRuntimeDisappears() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentContext: TunnelLiveSessionContext? = liveContext()
        var currentRuntimeID: String? = "runtime-alpha"
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { currentContext },
            liveSessionRuntimeIDProvider: { currentRuntimeID },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.old.json", size: 64, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "比较文件...", row: 0)

        XCTAssertEqual(scheduler.runtimeIDs, ["runtime-alpha", "runtime-alpha"])
        XCTAssertEqual(scheduler.jobs.count, 2)

        scheduler.complete(jobID: scheduler.jobs[0].id)
        XCTAssertTrue(opener.comparedURLGroups.isEmpty)

        currentContext = nil
        currentRuntimeID = nil
        scheduler.complete(jobID: scheduler.jobs[1].id)

        XCTAssertTrue(opener.comparedURLGroups.isEmpty)
    }

    func testCoordinatorCompareWaitsForBothDownloadsWhenSchedulerCompletesImmediately() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler(completesImmediately: true)
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.old.json", size: 64, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "比较文件...", row: 0)

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(opener.comparedURLGroups.map { $0.map(\.path) }, [
            scheduler.jobs.map(\.destinationPath)
        ])
    }

    func testCoordinatorCompareRequiresTwoSelectedFiles() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            errorPresenter: errorPresenter,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "比较文件...", row: 0)

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertTrue(opener.comparedURLGroups.isEmpty)
        XCTAssertEqual(errorPresenter.contexts, [.compareFiles])
        XCTAssertEqual(errorPresenter.messages, ["无法比较远端文件"])
    }

    func testCoordinatorRemoteDocumentSaveHandlerWritesBackToOriginalPath() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)

        try request.saveHandler?(#"{"enabled":false}"#)

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(bridge.writeRequests.count, 1)
        XCTAssertEqual(bridge.writeRequests.first?.path, "/srv/app/config.json")
        XCTAssertEqual(String(data: try XCTUnwrap(bridge.writeRequests.first?.contents), encoding: .utf8), #"{"enabled":false}"#)
    }

    func testCoordinatorRemoteDocumentSaveVerifiesRemoteContentsAfterWrite() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ],
            persistsWrites: true
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)

        try request.saveHandler?(#"{"enabled":false}"#)

        XCTAssertEqual(bridge.writeRequests.count, 1)
        XCTAssertEqual(bridge.readRequests.map(\.path), [
            "/srv/app/config.json",
            "/srv/app/config.json"
        ])
        XCTAssertEqual(bridge.events, [
            "read:/srv/app/config.json:0:all",
            "write:/srv/app/config.json:17",
            "read:/srv/app/config.json:0:18"
        ])
    }

    func testCoordinatorRemoteDocumentSaveUsesSFTPWhenAvailable() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ],
            persistsWrites: true,
            supportsSFTPFileIO: true
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 16, linkTarget: nil)
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })

        try opener.remoteDocumentRequests[0].saveHandler?(#"{"enabled":false}"#)

        XCTAssertEqual(bridge.sftpWriteRequests.map(\.path), ["/srv/app/config.json"])
        XCTAssertTrue(bridge.writeRequests.isEmpty)
        XCTAssertEqual(bridge.events.suffix(2), [
            "sftp-write:/srv/app/config.json:17",
            "sftp-read:/srv/app/config.json:0:18"
        ])
    }

    func testCoordinatorRemoteDocumentSavePreservesSFTPPermissionError() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let opener = RecordingRemoteEditOpener()
        let permissionError = SshRuntimeError.Transport(message: "FILES_PERMISSION_DENIED")
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/etc/ssh/sshd_config": Data("Port 22\n".utf8)
            ],
            persistsWrites: true,
            supportsSFTPFileIO: true,
            sftpOperationError: permissionError
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/etc/ssh/sshd_config", size: 8, linkTarget: nil)
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })

        XCTAssertThrowsError(try opener.remoteDocumentRequests[0].saveHandler?("Port 2222\n")) { error in
            XCTAssertEqual(error as? SshRuntimeError, permissionError)
        }
        XCTAssertTrue(bridge.writeRequests.isEmpty)
        XCTAssertEqual(
            RuntimeDiagnosticFormatter.userMessage(for: permissionError),
            "文件传输权限不足"
        )
    }

    func testCoordinatorRemoteDocumentSaveFailsWhenWriteBackVerificationDoesNotMatch() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ],
            persistsWrites: false
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)

        XCTAssertThrowsError(try request.saveHandler?(#"{"enabled":false}"#)) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .remoteWriteVerificationFailed("/srv/app/config.json"))
        }

        XCTAssertEqual(bridge.writeRequests.count, 1)
        XCTAssertEqual(bridge.readRequests.map(\.path), [
            "/srv/app/config.json",
            "/srv/app/config.json"
        ])
    }

    func testCoordinatorBlocksRemoteDocumentSaveWhenRemoteChangedSinceOpen() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let bridge = RecordingRemoteFilesBridge(
            remoteFileData: [
                "/srv/app/config.json": Data(#"{"enabled":true}"#.utf8)
            ]
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            errorPresenter: errorPresenter,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.json",
                size: 128,
                modifiedTime: "2026-06-06T10:00:00Z",
                linkTarget: nil
            )
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        XCTAssertTrue(waitUntil { opener.remoteDocumentRequests.count == 1 })
        let request = try XCTUnwrap(opener.remoteDocumentRequests.first)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.json",
                size: 128,
                modifiedTime: "2026-06-06T10:05:00Z",
                linkTarget: nil
            )
        ])

        XCTAssertThrowsError(try request.saveHandler?(#"{"enabled":false}"#)) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .remoteChanged("/srv/app/config.json"))
        }

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertTrue(bridge.writeRequests.isEmpty)
    }

    func testCoordinatorReportsRemoteTextReadFailureThroughInjectedOpener() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(operationError: FilesError.UnsafePath),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        XCTAssertTrue(waitUntil { opener.failedOpenRequests.count == 1 })
        XCTAssertEqual(opener.failedOpenRequests.first?.selection.path, "/srv/app/config.json")
        XCTAssertTrue(opener.failedOpenRequests.first?.message.contains("远程路径不安全") == true)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertNil(files.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testSaveRemoteEditMissingLocalCopyShowsActionableInformativeTextWithoutPath() {
        let error = RemoteEditCacheError.localCopyMissing("/tmp/StacioRemoteEditCache/secret/config.json")

        let message = RemoteFileErrorContext.saveRemoteEdit.informativeText(for: error)

        XCTAssertEqual(message, "本地编辑副本已丢失，请重新打开远程文件后再保存")
        XCTAssertFalse(message.contains("/tmp/StacioRemoteEditCache/secret/config.json"))
        XCTAssertFalse(message.contains("secret"))
    }

    func testSaveRemoteEditRemoteChangedShowsActionableConflictMessage() {
        let error = RemoteEditCacheError.remoteChanged("/srv/app/config.json")

        let message = RemoteFileErrorContext.saveRemoteEdit.informativeText(for: error)

        XCTAssertEqual(message, "远端文件已更新，请重新打开后再保存，避免覆盖新的远端内容")
        XCTAssertFalse(message.contains("/srv/app/config.json"))
    }

    func testCoordinatorBlocksCachedRemoteEditUploadWhenRemoteChangedSinceOpen() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            errorPresenter: errorPresenter,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        let openedRemoteModifiedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-06T10:00:00Z"))
        let cacheItem = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.txt", size: 128),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: openedRemoteModifiedAt
        )
        try Data("changed".utf8).write(to: cacheItem.localURL)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.txt",
                size: 128,
                modifiedTime: "2026-06-06T10:00:00Z",
                linkTarget: nil
            )
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.txt",
                size: 128,
                modifiedTime: "2026-06-06T10:05:00Z",
                linkTarget: nil
            )
        ])

        files.performSaveRemoteEditForTesting()

        XCTAssertTrue(scheduler.jobs.filter { $0.direction == .upload }.isEmpty)
        XCTAssertEqual(errorPresenter.contexts, [.saveRemoteEdit])
        XCTAssertEqual(
            errorPresenter.informativeMessages,
            ["远端文件已更新，请重新打开后再保存，避免覆盖新的远端内容"]
        )
    }

    func testCoordinatorMarksCachedRemoteEditCleanWhenUploadCompletes() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        let cacheItem = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.txt", size: 128),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try Data("changed".utf8).write(to: cacheItem.localURL)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.txt",
                size: 128,
                modifiedTime: "2027-01-15T08:00:00Z",
                linkTarget: nil
            )
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        files.performSaveRemoteEditForTesting()

        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(cache.dirtyItemCount(), 1)
        scheduler.complete(jobID: uploadJob.id)

        XCTAssertEqual(cache.dirtyItemCount(), 0)
        XCTAssertEqual(RemoteEditCache(rootDirectory: cacheRoot).dirtyItemCount(), 0)
    }

    func testCoordinatorKeepsCachedRemoteEditDirtyWhenUploadCompletesAfterLiveRuntimeDisappears() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        var currentLiveContext: TunnelLiveSessionContext? = liveContext()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { currentLiveContext },
            liveSessionRuntimeIDProvider: { "runtime-alpha" },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        let cacheItem = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.txt", size: 128),
            runtimeID: "runtime-alpha",
            sessionID: "session-alpha",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try Data("changed".utf8).write(to: cacheItem.localURL)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.txt",
                size: 128,
                modifiedTime: "2027-01-15T08:00:00Z",
                linkTarget: nil
            )
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        files.performSaveRemoteEditForTesting()

        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(cache.dirtyItemCount(), 1)

        currentLiveContext = nil
        scheduler.complete(jobID: uploadJob.id)

        XCTAssertEqual(cache.dirtyItemCount(), 1)
        XCTAssertEqual(RemoteEditCache(rootDirectory: cacheRoot).dirtyItemCount(), 1)
    }

    func testCoordinatorKeepsCachedRemoteEditDirtyWhenUploadFails() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        let cacheItem = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.txt", size: 128),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try Data("changed".utf8).write(to: cacheItem.localURL)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.txt",
                size: 128,
                modifiedTime: "2027-01-15T08:00:00Z",
                linkTarget: nil
            )
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        files.performSaveRemoteEditForTesting()

        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        scheduler.fail(jobID: uploadJob.id)

        XCTAssertEqual(cache.dirtyItemCount(), 1)
        XCTAssertEqual(RemoteEditCache(rootDirectory: cacheRoot).dirtyItemCount(), 1)
    }

    func testCoordinatorBacksUpActiveEditorTabToRemoteDirectoryWithTimestampedBakName() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler(completesImmediately: true)
        let bridge = RecordingRemoteFilesBridge()
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/srv/app/config.txt",
                fileName: "config.txt",
                content: "enabled=true\n",
                byteCount: 128
            )
        )
        let prompt = RecordingRemoteFileOperationPrompt(backupDestination: .remoteDirectory)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            operationPrompt: prompt,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: RecordingRemoteEditOpener(),
            currentEditorProvider: { editor },
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setCurrentRemotePath("/srv/app")

        coordinator.performBackupFromInspector(date: fixedBackupDate(), timeZone: fixedBackupTimeZone())

        XCTAssertEqual(prompt.backupCandidatePrompts.map { $0.map(\.fileName) }, [["config.txt"]])
        XCTAssertTrue(waitUntil { bridge.events.filter { !$0.hasPrefix("read:") } == [
            "copy:/srv/app/config.txt->/srv/app/config.txt-202606040912.bak",
            "live:/srv/app"
        ] })
    }

    func testBackupCandidatesComeFromInjectedCurrentEditorProvider() {
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/app.conf",
                fileName: "app.conf",
                content: "enabled=true\n"
            )
        )
        let prompt = RecordingRemoteFileOperationPrompt(backupDestination: .remoteDirectory)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            operationPrompt: prompt,
            remoteEditOpener: RecordingRemoteEditOpener(),
            currentEditorProvider: { editor }
        )

        coordinator.performBackupFromInspector(date: fixedBackupDate(), timeZone: fixedBackupTimeZone())

        XCTAssertEqual(prompt.backupCandidatePrompts.first?.map(\.remotePath), ["/etc/app.conf"])
    }

    func testCoordinatorSchedulesLocalBackupDownloadWithTimestampedBakName() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let scheduler = RecordingSCPTransferScheduler(completesImmediately: true)
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: "/Users/alice/Downloads/config.txt-202606040912.bak"
        )
        let bridge = RecordingRemoteFilesBridge()
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/srv/app/config.txt",
                fileName: "config.txt",
                content: "enabled=true\n",
                byteCount: 128
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker,
            operationPrompt: RecordingRemoteFileOperationPrompt(backupDestination: .local),
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: RecordingRemoteEditOpener(),
            currentEditorProvider: { editor },
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)

        coordinator.performBackupFromInspector(date: fixedBackupDate(), timeZone: fixedBackupTimeZone())

        XCTAssertEqual(destinationPicker.suggestedFileNames, ["config.txt-202606040912.bak"])
        let backupJob = try XCTUnwrap(scheduler.jobs.last)
        XCTAssertEqual(backupJob.direction, .download)
        XCTAssertEqual(backupJob.sourcePath, "/srv/app/config.txt")
        XCTAssertEqual(backupJob.destinationPath, "/Users/alice/Downloads/config.txt-202606040912.bak")
        XCTAssertEqual(backupJob.bytesTotal, 128)
    }

    func testCoordinatorRestoresRemoteBackupByCopyingBakToOriginalName() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/config.txt-202606040912.bak", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/notes.log", size: 64, linkTarget: nil)
        ])
        let prompt = RecordingRemoteFileOperationPrompt(restoreSource: .remoteDirectory)
        let files = FilesViewController()
        files.loadView()
        files.setCurrentRemotePath("/srv/app")
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            operationPrompt: prompt
        )
        XCTAssertNotNil(coordinator)

        coordinator.performRestoreFromInspector()

        XCTAssertEqual(prompt.remoteBackupFilePrompts.map { $0.map(\.path) }, [["/srv/app/config.txt-202606040912.bak"]])
        XCTAssertTrue(waitUntil {
            bridge.events == [
                "live:/srv/app",
                "copy:/srv/app/config.txt-202606040912.bak->/srv/app/config.txt",
                "live:/srv/app"
            ]
        })
        XCTAssertEqual(bridge.events, [
            "live:/srv/app",
            "copy:/srv/app/config.txt-202606040912.bak->/srv/app/config.txt",
            "live:/srv/app"
        ])
    }

    func testCoordinatorRestoresLocalBakFileByUploadingToOriginalRemoteName() throws {
        let localDirectory = try makeTemporaryDirectory()
        let localBackup = localDirectory.appendingPathComponent("config.txt-202606040912.bak")
        try Data("restored".utf8).write(to: localBackup)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        files.setCurrentRemotePath("/srv/app")
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            operationPrompt: RecordingRemoteFileOperationPrompt(
                restoreSource: .local,
                localBackupFileURLs: [localBackup]
            )
        )
        XCTAssertNotNil(coordinator)

        coordinator.performRestoreFromInspector()

        let restoreJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(restoreJob.direction, .upload)
        XCTAssertEqual(restoreJob.sourcePath, localBackup.path)
        XCTAssertEqual(restoreJob.destinationPath, "/srv/app/config.txt")
        XCTAssertEqual(restoreJob.bytesTotal, 8)
    }

    func testCoordinatorSyncsChangedRemoteEditCopiesForCurrentSSHSessionThroughEmbeddedSCPQueue() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)

        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let firstChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/first.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: remoteModifiedAt
        )
        let unchanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unchanged.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: remoteModifiedAt
        )
        let otherSessionChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/other.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-beta",
            modifiedAt: remoteModifiedAt
        )
        let secondChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/second.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: remoteModifiedAt
        )
        try Data("first edit".utf8).write(to: firstChanged.localURL)
        try Data("other edit".utf8).write(to: otherSessionChanged.localURL)
        try Data("second edit".utf8).write(to: secondChanged.localURL)
        for item in [firstChanged, otherSessionChanged, secondChanged] {
            try FileManager.default.setAttributes(
                [.modificationDate: remoteModifiedAt.addingTimeInterval(10)],
                ofItemAtPath: item.localURL.path
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: unchanged.localURL.path
        )

        files.performSyncChangedRemoteEditsForTesting()

        XCTAssertEqual(scheduler.jobs.map(\.direction), [.upload, .upload])
        XCTAssertEqual(scheduler.jobs.map(\.sourcePath), [
            firstChanged.localURL.path,
            secondChanged.localURL.path
        ])
        XCTAssertEqual(scheduler.jobs.map(\.destinationPath), [
            "/srv/app/first.conf",
            "/srv/app/second.conf"
        ])
        XCTAssertEqual(scheduler.jobs.map(\.bytesTotal), [10, 11])
        XCTAssertTrue(scheduler.jobs.allSatisfy { $0.id.hasPrefix("remote_edit_upload_") })
        XCTAssertEqual(scheduler.configs.map(\.host), ["example.com", "example.com"])
        XCTAssertEqual(scheduler.fingerprints, ["SHA256:test", "SHA256:test"])
        XCTAssertTrue(files.visibleTextSnapshot.contains("Remote Edit"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("2 个本地编辑副本已加入上传队列"))
    }

    func testCoordinatorKeepsChangedRemoteEditDirtyWhenSyncUploadCompletesAfterLiveRuntimeDisappears() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        var currentLiveContext: TunnelLiveSessionContext? = liveContext()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { currentLiveContext },
            liveSessionRuntimeIDProvider: { "runtime-alpha" },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)

        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let changed = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/changed.conf", size: 12),
            runtimeID: "runtime-alpha",
            sessionID: "session-alpha",
            modifiedAt: remoteModifiedAt
        )
        try Data("changed".utf8).write(to: changed.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(10)],
            ofItemAtPath: changed.localURL.path
        )

        files.performSyncChangedRemoteEditsForTesting()

        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(cache.dirtyItemCount(), 1)

        currentLiveContext = nil
        scheduler.complete(jobID: uploadJob.id)

        XCTAssertEqual(cache.dirtyItemCount(), 1)
        XCTAssertEqual(RemoteEditCache(rootDirectory: cacheRoot).dirtyItemCount(), 1)
    }

    func testCoordinatorShowsRemoteEditSyncStatusWhenNoChangedCopiesAreDetected() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)

        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let unchanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unchanged.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: remoteModifiedAt
        )
        try Data("same".utf8).write(to: unchanged.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: unchanged.localURL.path
        )

        files.performSyncChangedRemoteEditsForTesting()

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertTrue(files.visibleTextSnapshot.contains("Remote Edit"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("没有发现需要上传的本地编辑副本"))
    }

    func testCoordinatorDoesNotDetectChangedRemoteEditCopiesWhenSettingIsDisabled() throws {
        let suiteName = "StacioRemoteEditAutoDetectDisabled-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.filesRemoteEditAutoDetectChanges = false
        }
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController(settingsStore: settingsStore)
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" },
            settingsStore: settingsStore
        )
        XCTAssertNotNil(coordinator)

        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let changed = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/changed.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: remoteModifiedAt
        )
        try Data("changed".utf8).write(to: changed.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(10)],
            ofItemAtPath: changed.localURL.path
        )

        files.performSyncChangedRemoteEditsForTesting()

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertTrue(files.visibleTextSnapshot.contains("Remote Edit"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("检测已关闭"))
    }

    func testCoordinatorBlocksChangedRemoteEditSyncWhenRemoteChangedSinceOpen() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let scheduler = RecordingSCPTransferScheduler()
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            errorPresenter: errorPresenter,
            remoteEditCache: cache,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)

        let openedRemoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let changed = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/changed.conf", size: 12),
            runtimeID: "example.com",
            sessionID: "session-alpha",
            modifiedAt: openedRemoteModifiedAt
        )
        try Data("changed".utf8).write(to: changed.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: openedRemoteModifiedAt.addingTimeInterval(10)],
            ofItemAtPath: changed.localURL.path
        )
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/changed.conf",
                size: 12,
                modifiedTime: "2027-01-15T08:05:00Z",
                linkTarget: nil
            )
        ])

        files.performSyncChangedRemoteEditsForTesting()

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(errorPresenter.contexts, [.saveRemoteEdit])
        XCTAssertEqual(
            errorPresenter.informativeMessages,
            ["远端文件已更新，请重新打开后再保存，避免覆盖新的远端内容"]
        )
    }

    func testCoordinatorSchedulesSelectedFTPFileDownloadThroughEmbeddedFTPQueue() throws {
        let bridge = RecordingRemoteFilesBridge()
        let ftpScheduler = RecordingFTPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: "/Users/alice/Downloads/readme.txt"
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: {
                FTPLiveSessionContext(
                    config: FtpConnectionConfig(
                        host: "ftp.example.com",
                        port: 21,
                        username: "deploy",
                        connectTimeoutMs: 10_000
                    ),
                    secret: .password(value: "ftp-secret")
                )
            },
            ftpTransferScheduler: ftpScheduler,
            downloadDestinationPicker: destinationPicker
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/readme.txt", size: 64, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(destinationPicker.suggestedFileNames, ["readme.txt"])
        XCTAssertEqual(ftpScheduler.jobs.count, 1)
        XCTAssertEqual(ftpScheduler.jobs.first?.id.hasPrefix("ftp_download_"), true)
        XCTAssertEqual(ftpScheduler.jobs.first?.direction, .download)
        XCTAssertEqual(ftpScheduler.jobs.first?.sourcePath, "/pub/readme.txt")
        XCTAssertEqual(ftpScheduler.jobs.first?.destinationPath, "/Users/alice/Downloads/readme.txt")
        XCTAssertEqual(ftpScheduler.jobs.first?.bytesTotal, 64)
        XCTAssertEqual(ftpScheduler.configs.map(\.host), ["ftp.example.com"])
        XCTAssertFalse(String(describing: ftpScheduler).contains("ftp-secret"))
    }

    func testCoordinatorOpensFTPRemoteEditViaCacheDownloadAndSavesThroughFTPQueue() throws {
        let bridge = RecordingRemoteFilesBridge()
        let ftpScheduler = RecordingFTPTransferScheduler()
        let cacheRoot = try makeTemporaryDirectory()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: {
                FTPLiveSessionContext(
                    config: FtpConnectionConfig(
                        host: "ftp.example.com",
                        port: 21,
                        username: "deploy",
                        connectTimeoutMs: 10_000
                    ),
                    secret: .password(value: "ftp-secret")
                )
            },
            ftpTransferScheduler: ftpScheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "ftp-session" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.json", size: 18, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        let downloadJob = try XCTUnwrap(ftpScheduler.jobs.first)
        XCTAssertEqual(downloadJob.direction, .download)
        XCTAssertEqual(downloadJob.sourcePath, "/pub/config.json")
        XCTAssertTrue(downloadJob.destinationPath.hasPrefix(cacheRoot.path))
        XCTAssertEqual(downloadJob.bytesTotal, 18)
        XCTAssertTrue(downloadJob.id.hasPrefix("remote_edit_ftp_download_"))
        XCTAssertTrue(opener.openRequests.isEmpty)

        try Data("{\"ok\":true}".utf8).write(to: URL(fileURLWithPath: downloadJob.destinationPath))
        ftpScheduler.complete(jobID: downloadJob.id)

        let opened = try XCTUnwrap(opener.openRequests.first)
        XCTAssertEqual(opened.mode, .textEditor)
        XCTAssertEqual(opened.url.path, downloadJob.destinationPath)
        XCTAssertEqual(opener.localCopyRequestIDs, opener.preparedRequestIDs)

        try opened.saveHandler?()

        let uploadJob = try XCTUnwrap(ftpScheduler.jobs.dropFirst().first)
        XCTAssertEqual(uploadJob.direction, .upload)
        XCTAssertEqual(uploadJob.sourcePath, downloadJob.destinationPath)
        XCTAssertEqual(uploadJob.destinationPath, "/pub/config.json")
        XCTAssertEqual(uploadJob.bytesTotal, 11)
        XCTAssertTrue(uploadJob.id.hasPrefix("remote_edit_upload_"))
        XCTAssertEqual(ftpScheduler.configs.map(\.host), ["ftp.example.com", "ftp.example.com"])
        XCTAssertFalse(String(describing: ftpScheduler).contains("ftp-secret"))
    }

    func testCoordinatorDoesNotScheduleFTPRemoteEditUploadWhenSaveRunsAfterFTPContextDisappears() throws {
        let bridge = RecordingRemoteFilesBridge()
        let ftpScheduler = RecordingFTPTransferScheduler()
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentFTPContext: FTPLiveSessionContext? = FTPLiveSessionContext(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-secret")
        )
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: { currentFTPContext },
            ftpTransferScheduler: ftpScheduler,
            remoteEditCache: cache,
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "ftp-session" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.json", size: 18, linkTarget: nil)
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        let downloadJob = try XCTUnwrap(ftpScheduler.jobs.first)
        try Data("{\"ok\":true}".utf8).write(to: URL(fileURLWithPath: downloadJob.destinationPath))
        ftpScheduler.complete(jobID: downloadJob.id)
        let opened = try XCTUnwrap(opener.openRequests.first)

        currentFTPContext = nil
        try opened.saveHandler?()

        XCTAssertEqual(ftpScheduler.jobs.count, 1)
        XCTAssertEqual(cache.dirtyItemCount(), 0)
        XCTAssertEqual(RemoteEditCache(rootDirectory: cacheRoot).dirtyItemCount(), 0)
    }

    func testCoordinatorKeepsFTPRemoteEditDirtyWhenUploadCompletesAfterFTPContextDisappears() throws {
        let bridge = RecordingRemoteFilesBridge()
        let ftpScheduler = RecordingFTPTransferScheduler()
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentFTPContext: FTPLiveSessionContext? = FTPLiveSessionContext(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-secret")
        )
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: { currentFTPContext },
            ftpTransferScheduler: ftpScheduler,
            remoteEditCache: cache,
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "ftp-session" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.json", size: 18, linkTarget: nil)
        ])
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        let downloadJob = try XCTUnwrap(ftpScheduler.jobs.first)
        try Data("{\"ok\":true}".utf8).write(to: URL(fileURLWithPath: downloadJob.destinationPath))
        ftpScheduler.complete(jobID: downloadJob.id)
        let opened = try XCTUnwrap(opener.openRequests.first)

        try opened.saveHandler?()
        let uploadJob = try XCTUnwrap(ftpScheduler.jobs.dropFirst().first)
        XCTAssertEqual(cache.dirtyItemCount(), 1)

        currentFTPContext = nil
        ftpScheduler.complete(jobID: uploadJob.id)

        XCTAssertEqual(cache.dirtyItemCount(), 1)
        XCTAssertEqual(RemoteEditCache(rootDirectory: cacheRoot).dirtyItemCount(), 1)
    }

    func testCoordinatorFailsFTPRemoteEditDownloadWithOriginalRequestAfterFTPContextDisappears() throws {
        let bridge = RecordingRemoteFilesBridge()
        let ftpScheduler = RecordingFTPTransferScheduler()
        let cacheRoot = try makeTemporaryDirectory()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentFTPContext: FTPLiveSessionContext? = FTPLiveSessionContext(
            config: FtpConnectionConfig(
                host: "ftp.example.com",
                port: 21,
                username: "deploy",
                connectTimeoutMs: 10_000
            ),
            secret: .password(value: "ftp-secret")
        )
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: { currentFTPContext },
            ftpTransferScheduler: ftpScheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "ftp-session" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.json", size: 18, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()

        let downloadJob = try XCTUnwrap(ftpScheduler.jobs.first)
        XCTAssertEqual(opener.preparedRequestIDs.count, 1)
        XCTAssertTrue(opener.openRequests.isEmpty)

        currentFTPContext = nil
        ftpScheduler.complete(jobID: downloadJob.id)

        XCTAssertTrue(opener.openRequests.isEmpty)
        XCTAssertEqual(opener.failedOpenRequestIDs, opener.preparedRequestIDs)
    }

    func testCoordinatorEndsFTPRemoteOpenOnNonterminalProgressAfterContextDisappears() throws {
        let scheduler = RecordingFTPTransferScheduler()
        let cacheRoot = try makeTemporaryDirectory()
        let opener = RecordingRemoteEditOpener()
        let files = FilesViewController()
        files.loadView()
        var currentFTPContext: FTPLiveSessionContext? = ftpContext()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            ftpSessionContextProvider: { currentFTPContext },
            ftpTransferScheduler: scheduler,
            remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "ftp-session" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.json", size: 18, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performOpenRemoteEditForTesting()
        let downloadJob = try XCTUnwrap(scheduler.jobs.first)

        currentFTPContext = nil
        scheduler.report(jobID: downloadJob.id, status: "running")

        XCTAssertEqual(opener.failedOpenRequestIDs, opener.preparedRequestIDs)
        scheduler.complete(jobID: downloadJob.id)
        XCTAssertEqual(opener.failedOpenRequestIDs, opener.preparedRequestIDs)
        XCTAssertTrue(opener.localCopyRequestIDs.isEmpty)
    }

    func testCoordinatorEndsFTPRemoteOpenOnEveryFailureTerminalStatusExactlyOnce() throws {
        for terminalStatus in ["failed", "canceled", "cancelled", "stopped"] {
            let cacheRoot = try makeTemporaryDirectory()
            let scheduler = RecordingFTPTransferScheduler()
            let opener = RecordingRemoteEditOpener()
            let files = FilesViewController()
            files.loadView()
            let coordinator = FilesCoordinator(
                bridge: RecordingRemoteFilesBridge(),
                filesViewController: files,
                ftpSessionContextProvider: { self.ftpContext() },
                ftpTransferScheduler: scheduler,
                remoteEditCache: RemoteEditCache(rootDirectory: cacheRoot),
                remoteEditOpener: opener,
                remoteEditSessionIDProvider: { "ftp-session-\(terminalStatus)" }
            )
            XCTAssertNotNil(coordinator)
            files.setRemoteEntries([
                RemoteFileEntry(
                    kind: .file,
                    path: "/pub/\(terminalStatus).conf",
                    size: 128,
                    linkTarget: nil
                )
            ])

            files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            files.performOpenRemoteEditForTesting()

            let downloadJob = try XCTUnwrap(scheduler.jobs.first)
            XCTAssertEqual(opener.preparedRequestIDs.count, 1, "status=\(terminalStatus)")

            scheduler.report(jobID: downloadJob.id, status: "running")
            XCTAssertTrue(opener.localCopyRequestIDs.isEmpty, "status=\(terminalStatus)")
            XCTAssertTrue(opener.failedOpenRequestIDs.isEmpty, "status=\(terminalStatus)")

            if terminalStatus == "canceled" {
                scheduler.cancel(jobID: downloadJob.id)
            } else {
                scheduler.report(jobID: downloadJob.id, status: terminalStatus)
            }
            XCTAssertEqual(
                opener.failedOpenRequestIDs,
                opener.preparedRequestIDs,
                "status=\(terminalStatus)"
            )

            scheduler.complete(jobID: downloadJob.id)
            XCTAssertTrue(opener.localCopyRequestIDs.isEmpty, "status=\(terminalStatus)")
            XCTAssertEqual(
                opener.failedOpenRequestIDs,
                opener.preparedRequestIDs,
                "A late terminal record must not finish status=\(terminalStatus) twice"
            )
            withExtendedLifetime(coordinator) {}
        }
    }

    func testCoordinatorStoresRemoteModifiedTimeFromFilesSelectionWhenOpeningLocalCopy() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let opener = RecordingRemoteEditOpener()
        let scheduler = RecordingSCPTransferScheduler(completesImmediately: true)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            remoteEditCache: cache,
            remoteEditOpener: opener,
            remoteEditSessionIDProvider: { "session-alpha" }
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/config.json",
                size: 18,
                modifiedTime: "2026-06-06 21:30",
                linkTarget: nil
            )
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)

        let cacheItem = try cache.item(
            remotePath: "/srv/app/config.json",
            runtimeID: "example.com",
            sessionID: "session-alpha"
        )
        let modifiedAt = try XCTUnwrap(cacheItem.modifiedAt)
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.year, from: modifiedAt), 2026)
        XCTAssertEqual(calendar.component(.month, from: modifiedAt), 6)
        XCTAssertEqual(calendar.component(.day, from: modifiedAt), 6)
        XCTAssertEqual(calendar.component(.hour, from: modifiedAt), 21)
        XCTAssertEqual(calendar.component(.minute, from: modifiedAt), 30)
    }

    func testCoordinatorDoesNotScheduleDownloadWhenDestinationIsCancelled() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(destinationPath: nil)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(destinationPicker.suggestedFileNames, ["config.json"])
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testCoordinatorUsesChineseFallbackNameForDownloadDestination() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(
            destinationPath: "/Users/alice/Downloads/下载文件"
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(destinationPicker.suggestedFileNames, ["下载文件"])
    }

    func testCoordinatorSchedulesUploadThroughEmbeddedSCPQueue() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFile: LocalUploadFile(
                path: "/Users/alice/build.zip",
                fileName: "build.zip",
                size: 2_048
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performUploadFileForTesting()

        XCTAssertEqual(uploadPicker.pickCount, 1)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, "/Users/alice/build.zip")
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/build.zip")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 2_048)
        XCTAssertEqual(scheduler.configs.map(\.host), ["example.com"])
    }

    func testCoordinatorSchedulesUploadWithBoundRuntimeIDInsteadOfHost() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFile: LocalUploadFile(
                path: "/Users/alice/runtime-scoped.zip",
                fileName: "runtime-scoped.zip",
                size: 2_048
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            liveSessionRuntimeIDProvider: { "runtime-alpha" },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performUploadFileForTesting()

        XCTAssertEqual(scheduler.runtimeIDs, ["runtime-alpha"])
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/runtime-scoped.zip")
    }

    func testCoordinatorSchedulesFolderUploadThroughEmbeddedSCPQueue() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFolder: LocalUploadFile(
                path: "/Users/alice/release",
                fileName: "release",
                size: 4_096
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performUploadFolderForTesting()

        XCTAssertEqual(uploadPicker.pickFolderCount, 1)
        XCTAssertEqual(uploadPicker.pickCount, 0)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, "/Users/alice/release")
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/release")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 4_096)
    }

    func testCoordinatorSchedulesDroppedFolderUploadAndPublishesRecursiveDirectorySizeEstimate() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFolder = tempDirectory.appendingPathComponent("release")
        let nestedFolder = localFolder.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: localFolder.appendingPathComponent("app.bin"))
        try Data(repeating: 2, count: 64).write(to: nestedFolder.appendingPathComponent("logo.png"))
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performDropLocalFilesForTesting([localFolder.path])

        XCTAssertEqual(scheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, localFolder.path)
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/release")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 0)
        XCTAssertTrue(waitUntil { scheduler.estimatedByteTotals[scheduler.jobs.first?.id ?? ""] == 96 })
    }

    func testCoordinatorSchedulesDroppedFolderUploadWithoutBlockingOnDirectorySizeScan() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFolder = tempDirectory.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let scheduler = RecordingSCPTransferScheduler()
        let sizeProvider = BlockingLocalUploadSizeProvider(size: 96)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            localUploadSizeProvider: { url in sizeProvider.size(url) }
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        let started = Date()
        files.performDropLocalFilesForTesting([localFolder.path])

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertEqual(scheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, localFolder.path)
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/release")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 0)
        XCTAssertTrue(sizeProvider.waitUntilStarted())
        sizeProvider.release()
    }

    func testCoordinatorSchedulesFTPUploadThroughEmbeddedFTPQueue() throws {
        let ftpScheduler = RecordingFTPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFile: LocalUploadFile(
                path: "/Users/alice/build.zip",
                fileName: "build.zip",
                size: 2_048
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionRuntimeIDProvider: { "ftp-pane-runtime" },
            ftpSessionContextProvider: {
                FTPLiveSessionContext(
                    config: FtpConnectionConfig(
                        host: "ftp.example.com",
                        port: 21,
                        username: "deploy",
                        connectTimeoutMs: 10_000
                    ),
                    secret: .password(value: "ftp-secret")
                )
            },
            ftpTransferScheduler: ftpScheduler,
            uploadFilePicker: uploadPicker
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/pub"
        files.performUploadFileForTesting()

        XCTAssertEqual(uploadPicker.pickCount, 1)
        XCTAssertEqual(ftpScheduler.jobs.count, 1)
        XCTAssertEqual(ftpScheduler.jobs.first?.id.hasPrefix("ftp_upload_"), true)
        XCTAssertEqual(ftpScheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(ftpScheduler.jobs.first?.sourcePath, "/Users/alice/build.zip")
        XCTAssertEqual(ftpScheduler.jobs.first?.destinationPath, "/pub/build.zip")
        XCTAssertEqual(ftpScheduler.jobs.first?.bytesTotal, 2_048)
        XCTAssertEqual(ftpScheduler.runtimeIDs, ["ftp-pane-runtime"])
        XCTAssertEqual(ftpScheduler.configs.map(\.host), ["ftp.example.com"])
        XCTAssertFalse(String(describing: ftpScheduler).contains("ftp-secret"))
    }

    func testCoordinatorAppliesConflictPolicyWhenUploadingExistingRemoteName() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFile: LocalUploadFile(
                path: "/Users/alice/build.zip",
                fileName: "build.zip",
                size: 2_048
            )
        )
        let conflictResolver = RecordingRemoteFileConflictResolver(policy: .keepBoth)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker,
            conflictResolver: conflictResolver
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/build.zip", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performUploadFileForTesting()

        XCTAssertEqual(conflictResolver.requests.map(\.destinationPath), ["/srv/app/build.zip"])
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/build (copy).zip")
    }

    func testCoordinatorSkipsUploadWhenConflictPolicyIsSkip() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFile: LocalUploadFile(
                path: "/Users/alice/build.zip",
                fileName: "build.zip",
                size: 2_048
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker,
            conflictResolver: RecordingRemoteFileConflictResolver(policy: .skip)
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/build.zip", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performUploadFileForTesting()

        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testCoordinatorSchedulesDroppedFinderFilesThroughUploadConflictPolicy() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("config.json")
        try Data(repeating: 1, count: 32).write(to: localFile)
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            conflictResolver: RecordingRemoteFileConflictResolver(policy: .rename)
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performDropLocalFilesForTesting([localFile.path])

        XCTAssertEqual(scheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, localFile.path)
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/app/config (imported).json")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 32)
    }

    func testCoordinatorChecksTheDirectoryUnderTheDropBeforeApplyingUploadConflictPolicy() throws {
        let tempDirectory = try makeTemporaryDirectory()
        let localFile = tempDirectory.appendingPathComponent("config.json")
        try Data(repeating: 1, count: 32).write(to: localFile)
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/releases/config.json", size: 128, linkTarget: nil)
        ])
        let scheduler = RecordingSCPTransferScheduler()
        let conflictResolver = RecordingRemoteFileConflictResolver(policy: .rename)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            conflictResolver: conflictResolver
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/releases", size: 0, linkTarget: nil)
        ], remotePath: "/srv/app")

        files.performDropLocalFilesForTesting([localFile.path], onRemoteRow: 0)

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        XCTAssertEqual(bridge.events, ["live:/srv/app/releases"])
        XCTAssertEqual(
            conflictResolver.requests.map(\.destinationPath),
            ["/srv/app/releases/config.json"]
        )
        XCTAssertEqual(
            scheduler.jobs.first?.destinationPath,
            "/srv/app/releases/config (imported).json"
        )
    }

    func testCoordinatorRefreshesCurrentDirectoryAfterSCPUploadCompletes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("build.zip")
        try Data(repeating: 1, count: 32).write(to: localFile)
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/build.zip", size: 32, linkTarget: nil)
        ])
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler
        )
        XCTAssertNotNil(coordinator)
        files.setCurrentRemotePath("/srv/app")

        files.performDropLocalFilesForTesting([localFile.path])
        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        scheduler.complete(jobID: uploadJob.id)

        XCTAssertTrue(waitUntil { bridge.events == ["live:/srv/app"] && files.entryCount == 1 })
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "build.zip")
    }

    func testCoordinatorRefreshesCurrentDirectoryAfterFTPUploadCompletes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("asset.png")
        try Data(repeating: 1, count: 32).write(to: localFile)
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/pub/asset.png", size: 32, linkTarget: nil)
        ])
        let ftpScheduler = RecordingFTPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: {
                FTPLiveSessionContext(
                    config: FtpConnectionConfig(
                        host: "ftp.example.com",
                        port: 21,
                        username: "deploy",
                        connectTimeoutMs: 10_000
                    ),
                    secret: .password(value: "ftp-secret")
                )
            },
            ftpTransferScheduler: ftpScheduler
        )
        XCTAssertNotNil(coordinator)
        files.setCurrentRemotePath("/pub")

        files.performDropLocalFilesForTesting([localFile.path])
        let uploadJob = try XCTUnwrap(ftpScheduler.jobs.first)
        ftpScheduler.complete(jobID: uploadJob.id)

        XCTAssertTrue(waitUntil { bridge.events == ["ftp:/pub"] && files.entryCount == 1 })
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "asset.png")
    }

    func testCoordinatorSchedulesTerminalDroppedFinderFilesWithExplicitRuntimeContext() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("release.tar.gz")
        try Data(repeating: 1, count: 48).write(to: localFile)
        let scheduler = RecordingSCPTransferScheduler()
        let bridge = RecordingRemoteFilesBridge()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files
        )

        coordinator.scheduleDroppedUploads(
            localPaths: [localFile.path],
            remoteDirectory: "/srv/releases",
            runtimeID: "term_runtime",
            context: liveContext(),
            transferScheduler: scheduler
        )

        XCTAssertTrue(waitUntil { scheduler.jobs.count == 1 })
        XCTAssertEqual(bridge.events, ["live:/srv/releases"])
        XCTAssertEqual(bridge.liveHosts, ["example.com"])
        XCTAssertEqual(scheduler.runtimeIDs, ["term_runtime"])
        XCTAssertEqual(scheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(scheduler.jobs.first?.sourcePath, localFile.path)
        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/srv/releases/release.tar.gz")
        XCTAssertEqual(scheduler.jobs.first?.bytesTotal, 48)
        XCTAssertEqual(scheduler.configs.map(\.host), ["example.com"])
    }

    func testCoordinatorRefreshesCurrentDirectoryAfterTerminalDroppedUploadCompletes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("release.tar.gz")
        try Data(repeating: 1, count: 48).write(to: localFile)
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/releases/release.tar.gz", size: 48, linkTarget: nil)
        ])
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )
        XCTAssertNotNil(coordinator)
        files.setCurrentRemotePath("/srv/releases")

        coordinator.scheduleDroppedUploads(
            localPaths: [localFile.path],
            remoteDirectory: "/srv/releases",
            runtimeID: "term_runtime",
            context: liveContext(),
            transferScheduler: scheduler
        )
        let uploadJob = try XCTUnwrap(scheduler.jobs.first)
        scheduler.complete(jobID: uploadJob.id)

        XCTAssertTrue(waitUntil { bridge.events == ["live:/srv/releases"] && files.entryCount == 1 })
        XCTAssertEqual(scheduler.runtimeIDs, ["term_runtime"])
        XCTAssertEqual(files.tableView.viewText(atColumn: 0, row: 0), "release.tar.gz")
    }

    func testCoordinatorCoalescesFilesPanelDroppedUploadRefreshAndStartsWithinTwoHundredMilliseconds() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let firstLocalFile = tempDirectory.appendingPathComponent("first.log")
        let secondLocalFile = tempDirectory.appendingPathComponent("second.log")
        try Data(repeating: 1, count: 16).write(to: firstLocalFile)
        try Data(repeating: 2, count: 24).write(to: secondLocalFile)
        let bridge = TimedRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/first.log", size: 16, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/second.log", size: 24, linkTarget: nil)
        ])
        let scheduler = RecordingSCPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler
        )
        XCTAssertNotNil(coordinator)
        files.setCurrentRemotePath("/srv/app")
        files.performDropLocalFilesForTesting([firstLocalFile.path, secondLocalFile.path])

        XCTAssertEqual(scheduler.jobs.count, 2)
        let completionStartedAt = Date()
        scheduler.complete(jobID: scheduler.jobs[0].id)
        scheduler.complete(jobID: scheduler.jobs[1].id)

        XCTAssertTrue(waitUntil(timeout: 0.2) { bridge.firstRequestStartedAt != nil })
        let refreshStartedAt = try XCTUnwrap(bridge.firstRequestStartedAt)
        XCTAssertLessThanOrEqual(refreshStartedAt.timeIntervalSince(completionStartedAt), 0.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(bridge.eventsSnapshot, ["live:/srv/app"])
        bridge.releaseAllListings()
        XCTAssertTrue(waitUntil { files.entryCount == 2 })
    }

    func testCoordinatorSchedulesDroppedFinderFilesThroughEmbeddedFTPQueue() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let localFile = tempDirectory.appendingPathComponent("config.json")
        try Data(repeating: 1, count: 32).write(to: localFile)
        let ftpScheduler = RecordingFTPTransferScheduler()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            ftpSessionContextProvider: {
                FTPLiveSessionContext(
                    config: FtpConnectionConfig(
                        host: "ftp.example.com",
                        port: 21,
                        username: "deploy",
                        connectTimeoutMs: 10_000
                    ),
                    secret: .password(value: "ftp-secret")
                )
            },
            ftpTransferScheduler: ftpScheduler,
            conflictResolver: RecordingRemoteFileConflictResolver(policy: .rename)
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/pub/config.json", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/pub"
        files.performDropLocalFilesForTesting([localFile.path])

        XCTAssertEqual(ftpScheduler.jobs.first?.id.hasPrefix("ftp_upload_"), true)
        XCTAssertEqual(ftpScheduler.jobs.first?.direction, .upload)
        XCTAssertEqual(ftpScheduler.jobs.first?.sourcePath, localFile.path)
        XCTAssertEqual(ftpScheduler.jobs.first?.destinationPath, "/pub/config (imported).json")
        XCTAssertEqual(ftpScheduler.jobs.first?.bytesTotal, 32)
        XCTAssertEqual(ftpScheduler.configs.map(\.host), ["ftp.example.com"])
        XCTAssertFalse(String(describing: ftpScheduler).contains("ftp-secret"))
    }

    func testCoordinatorSchedulesUploadToRemoteRootWithoutDoubleSlash() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(
            selectedFile: LocalUploadFile(
                path: "/Users/alice/build.zip",
                fileName: "build.zip",
                size: 2_048
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/"
        files.performUploadFileForTesting()

        XCTAssertEqual(scheduler.jobs.first?.destinationPath, "/build.zip")
    }

    func testCoordinatorDoesNotScheduleUploadWhenFileSelectionIsCancelled() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let uploadPicker = RecordingUploadFilePicker(selectedFile: nil)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            transferScheduler: scheduler,
            uploadFilePicker: uploadPicker
        )
        XCTAssertNotNil(coordinator)

        files.performUploadFileForTesting()

        XCTAssertEqual(uploadPicker.pickCount, 1)
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testCoordinatorAppliesConflictPolicyWhenDownloadDestinationExists() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let existingDestination = tempDirectory.appendingPathComponent("config.json")
        try Data().write(to: existingDestination)
        let scheduler = RecordingSCPTransferScheduler()
        let destinationPicker = RecordingDownloadDestinationPicker(destinationPath: existingDestination.path)
        let conflictResolver = RecordingRemoteFileConflictResolver(policy: .keepBoth)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            downloadDestinationPicker: destinationPicker,
            conflictResolver: conflictResolver
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(conflictResolver.requests.map(\.destinationPath), [existingDestination.path])
        XCTAssertEqual(
            scheduler.jobs.first?.destinationPath,
            tempDirectory.appendingPathComponent("config (copy).json").path
        )
    }

    func testCoordinatorCreatesDirectoryRenamesDeletesAndChmodsThroughEmbeddedSSHExec() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 128, linkTarget: nil)
        ])
        let operationPrompt = RecordingRemoteFileOperationPrompt(
            directoryName: "logs",
            renameDestination: "/srv/app/current.log",
            chmodMode: "755",
            confirmsDelete: true
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            operationPrompt: operationPrompt
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performCreateDirectoryForTesting()
        XCTAssertTrue(waitUntil { bridge.events.count >= 2 && files.entryCount == 1 })
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performRenameSelectedEntryForTesting()
        XCTAssertTrue(waitUntil { bridge.events.count >= 4 && files.entryCount == 1 })
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performDeleteSelectedEntryForTesting()
        XCTAssertTrue(waitUntil { bridge.events.count >= 6 && files.entryCount == 1 })
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        files.performChmodSelectedEntryForTesting()
        XCTAssertTrue(waitUntil { bridge.events.count >= 8 && files.entryCount == 1 })

        XCTAssertEqual(bridge.events, [
            "mkdir:/srv/app/logs",
            "live:/srv/app",
            "rename:/srv/app/app.log->/srv/app/current.log",
            "live:/srv/app",
            "delete:/srv/app/app.log:true",
            "live:/srv/app",
            "chmod:/srv/app/app.log:755",
            "live:/srv/app"
        ])
        XCTAssertEqual(bridge.liveHosts, Array(repeating: "example.com", count: 8))
        XCTAssertFalse(bridge.debugDescription.contains("sftp "))
        XCTAssertFalse(bridge.debugDescription.contains("rsync "))
    }

    func testCoordinatorDeletesSelectedFilesAndFoldersFromContextMenuWithSingleRefresh() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])
        let operationPrompt = RecordingRemoteFileOperationPrompt(confirmsDelete: true)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            operationPrompt: operationPrompt
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        files.performContextMenuActionForTesting(title: "删除", row: 1)

        XCTAssertTrue(waitUntil { bridge.events.count >= 3 })
        XCTAssertEqual(bridge.events, [
            "delete:/srv/app/logs:true",
            "delete:/srv/app/config.json:true",
            "live:/srv/app"
        ])
        XCTAssertEqual(operationPrompt.deleteConfirmations, [
            RemoteFileSelection(path: "/srv/app/logs", size: 0, kind: .directory)
        ])
    }

    func testCoordinatorDeleteReturnsImmediatelyAndShowsDeletingStatusWhileRemoteDeleteRuns() throws {
        let bridge = DelayedDeleteRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 128, linkTarget: nil)
        ])
        let operationPrompt = RecordingRemoteFileOperationPrompt(confirmsDelete: true)
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            operationPrompt: operationPrompt
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        pathField.stringValue = "/srv/app"
        files.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let start = Date()
        files.performDeleteSelectedEntryForTesting()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2)
        XCTAssertTrue(files.visibleTextSnapshot.contains("正在删除远端项目"))
        XCTAssertTrue(bridge.waitUntilDeleteStarted())
        XCTAssertEqual(bridge.eventsSnapshot, ["delete:/srv/app/app.log:true"])

        bridge.releaseDelete()
        XCTAssertTrue(waitUntil { bridge.eventsSnapshot == ["delete:/srv/app/app.log:true", "live:/srv/app"] })
    }

    func testCoordinatorCreatesEmptyRemoteFileThroughInternalUploadQueue() throws {
        let scheduler = RecordingSCPTransferScheduler()
        let operationPrompt = RecordingRemoteFileOperationPrompt(fileName: "notes.conf")
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: RecordingRemoteFilesBridge(),
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            transferScheduler: scheduler,
            operationPrompt: operationPrompt
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performCreateFileForTesting()

        let job = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(job.direction, .upload)
        XCTAssertEqual(job.destinationPath, "/srv/app/notes.conf")
        XCTAssertEqual(job.bytesTotal, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.sourcePath))
        XCTAssertEqual((try? Data(contentsOf: URL(fileURLWithPath: job.sourcePath)))?.count, 0)
    }

    func testCoordinatorPresentsRemoteOperationErrorAndDoesNotRefreshWhenCreateDirectoryFails() throws {
        let bridge = RecordingRemoteFilesBridge(
            entries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 128, linkTarget: nil)
            ],
            operationError: FilesError.UnsafePath
        )
        let operationPrompt = RecordingRemoteFileOperationPrompt(directoryName: "logs")
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            operationPrompt: operationPrompt,
            errorPresenter: errorPresenter
        )
        XCTAssertNotNil(coordinator)
        files.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/app.log", size: 128, linkTarget: nil)
        ])
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        files.performCreateDirectoryForTesting()

        XCTAssertEqual(bridge.events, ["mkdir:/srv/app/logs"])
        XCTAssertEqual(errorPresenter.contexts, [.createDirectory])
        XCTAssertEqual(errorPresenter.messages, ["无法新建远端目录"])
        XCTAssertEqual(files.entryCount, 1)
    }

    func testCoordinatorPresentsRefreshErrorWhenCurrentDirectoryLoadFails() throws {
        let bridge = RecordingRemoteFilesBridge(error: FilesError.InvalidListingRow)
        let errorPresenter = RecordingRemoteFileErrorPresenter()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() },
            errorPresenter: errorPresenter
        )
        XCTAssertNotNil(coordinator)
        let pathField = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let refreshButton = try XCTUnwrap(
            files.view.firstSubview(withIdentifier: "Stacio.Files.refresh") as? NSButton
        )

        pathField.stringValue = "/srv/app"
        refreshButton.performClick(nil as Any?)

        XCTAssertTrue(waitUntil { errorPresenter.contexts == [.refresh] })
        XCTAssertEqual(bridge.events, ["live:/srv/app"])
        XCTAssertEqual(errorPresenter.contexts, [.refresh])
        XCTAssertEqual(errorPresenter.messages, ["无法刷新远端目录"])
        XCTAssertEqual(files.entryCount, 0)
    }

    func testCoordinatorShowsSanitizedChineseInitialSCPListingErrorState() {
        let bridge = RecordingRemoteFilesBridge(
            error: SensitiveListingError(
                message: "Permission denied while reading /Users/alice/.ssh/prod with secret super-secret"
            )
        )
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { self.liveContext() }
        )

        XCTAssertThrowsError(try coordinator.loadCurrentLiveDirectory(remotePath: "~")) { error in
            coordinator.showInitialLoadError(error)
        }

        XCTAssertEqual(bridge.events, ["live:~"])
        XCTAssertEqual(files.engineSummaryText, "")
        XCTAssertFalse(files.visibleTextSnapshot.contains("内置 SCP"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("无法加载远端目录"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("权限被拒绝"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("[已隐藏路径]"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("[已隐藏凭据]"))
        XCTAssertFalse(files.visibleTextSnapshot.contains("/Users/alice/.ssh/prod"))
        XCTAssertFalse(files.visibleTextSnapshot.contains("super-secret"))
        XCTAssertFalse(files.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testCoordinatorShowsSanitizedChineseInitialFTPListingErrorStateAndKeepsEngineLabel() {
        let bridge = RecordingRemoteFilesBridge(
            error: SensitiveListingError(
                message: "Connection refused for credential ftp-secret at /tmp/private-key"
            )
        )
        let files = FilesViewController()
        files.loadView()
        files.setEngineSummary("内置 FTP")
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            ftpSessionContextProvider: {
                FTPLiveSessionContext(
                    config: FtpConnectionConfig(
                        host: "ftp.example.com",
                        port: 21,
                        username: "deploy",
                        connectTimeoutMs: 10_000
                    ),
                    secret: .password(value: "ftp-secret")
                )
            }
        )

        XCTAssertThrowsError(try coordinator.loadCurrentLiveDirectory(remotePath: "~")) { error in
            coordinator.showInitialLoadError(error)
        }

        XCTAssertEqual(bridge.events, ["ftp:~"])
        XCTAssertEqual(files.engineSummaryText, "内置 FTP")
        XCTAssertTrue(files.visibleTextSnapshot.contains("无法加载远端目录"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("连接被拒绝"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("[已隐藏路径]"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("[已隐藏凭据]"))
        XCTAssertFalse(files.visibleTextSnapshot.contains("/tmp/private-key"))
        XCTAssertFalse(files.visibleTextSnapshot.contains("ftp-secret"))
        XCTAssertFalse(files.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testCoordinatorDoesNotRunRemoteOperationWhenPromptIsCancelledOrContextMissing() throws {
        let bridge = RecordingRemoteFilesBridge()
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { nil },
            operationPrompt: RecordingRemoteFileOperationPrompt(directoryName: "logs")
        )
        XCTAssertNotNil(coordinator)

        files.performCreateDirectoryForTesting()

        XCTAssertTrue(bridge.events.isEmpty)
    }

    func testCoordinatorShowsChineseErrorWhenSessionContextIsMissing() throws {
        let bridge = RecordingRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/.zshrc", size: 32, linkTarget: nil)
        ])
        let files = FilesViewController()
        files.loadView()
        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: files,
            liveSessionContextProvider: { nil }
        )

        XCTAssertThrowsError(try coordinator.loadCurrentLiveDirectory(remotePath: "/home/deploy")) { error in
            coordinator.showInitialLoadError(error)
        }

        XCTAssertTrue(bridge.events.isEmpty)
        XCTAssertEqual(files.entryCount, 0)
        XCTAssertTrue(files.visibleTextSnapshot.contains("无法加载远端目录"))
        XCTAssertTrue(files.visibleTextSnapshot.contains("当前没有可用的 SSH 文件上下文"))
    }
}

private struct SensitiveListingError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        "SensitiveListingError(message: \"\(message)\")"
    }
}

private struct MissingRemoteFileDataError: Error, CustomStringConvertible {
    let path: String

    var description: String {
        "没有找到远端文件：\(path)"
    }
}

private final class RecordingRemoteFilesBridge: RemoteFilesBridging, CustomDebugStringConvertible {
    private let eventLock = NSLock()
    private var recordedEvents: [String] = []
    var events: [String] {
        eventLock.withLock { recordedEvents }
    }
    var liveHosts: [String] = []
    var readRequests: [(path: String, offset: UInt64, length: UInt64?)] = []
    var writeRequests: [(path: String, contents: Data)] = []
    var sftpWriteRequests: [(path: String, contents: Data)] = []
    var onDelete: ((String, Bool) -> Void)?
    var debugDescription: String { events.joined(separator: " ") }
    private let entries: [RemoteFileEntry]
    private let searchEntries: [RemoteFileEntry]
    private var remoteFileData: [String: Data]
    private let error: Error?
    private let operationError: Error?
    private let persistsWrites: Bool
    private let supportsSFTPFileIO: Bool
    private let sftpOperationError: Error?

    init(
        entries: [RemoteFileEntry] = [],
        searchEntries: [RemoteFileEntry] = [],
        remoteFileData: [String: Data] = [:],
        error: Error? = nil,
        operationError: Error? = nil,
        persistsWrites: Bool = true,
        supportsSFTPFileIO: Bool = false,
        sftpOperationError: Error? = nil
    ) {
        self.entries = entries
        self.searchEntries = searchEntries
        self.remoteFileData = remoteFileData
        self.error = error
        self.operationError = operationError
        self.persistsWrites = persistsWrites
        self.supportsSFTPFileIO = supportsSFTPFileIO
        self.sftpOperationError = sftpOperationError
    }

    private func recordEvent(_ event: String) {
        eventLock.withLock {
            recordedEvents.append(event)
        }
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        recordEvent("parse")
        if let error {
            throw error
        }
        return entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        recordEvent("live:\(remotePath)")
        liveHosts.append(config.host)
        if let error {
            throw error
        }
        return entries
    }

    func searchLiveRemoteFiles(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        keyword: String,
        depth: UInt32
    ) throws -> [RemoteFileEntry] {
        recordEvent("search:\(remotePath):\(keyword):\(depth)")
        liveHosts.append(config.host)
        if let error {
            throw error
        }
        return searchEntries
    }

    func listLiveFTPDirectory(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        recordEvent("ftp:\(remotePath)")
        liveHosts.append(config.host)
        if let error {
            throw error
        }
        return entries
    }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {
        recordEvent("mkdir:\(remotePath)")
        liveHosts.append(config.host)
        if let operationError {
            throw operationError
        }
    }

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        recordEvent("rename:\(fromPath)->\(toPath)")
        liveHosts.append(config.host)
        if let operationError {
            throw operationError
        }
    }

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        recordEvent("delete:\(remotePath):\(recursive)")
        onDelete?(remotePath, recursive)
        liveHosts.append(config.host)
        if let operationError {
            throw operationError
        }
    }

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {
        recordEvent("chmod:\(remotePath):\(mode)")
        liveHosts.append(config.host)
        if let operationError {
            throw operationError
        }
    }

    func copyLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {
        recordEvent("copy:\(fromPath)->\(toPath)")
        liveHosts.append(config.host)
        if let operationError {
            throw operationError
        }
    }

    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        recordEvent("read:\(remotePath):\(offset):\(length.map(String.init) ?? "all")")
        liveHosts.append(config.host)
        readRequests.append((remotePath, offset, length))
        if let operationError {
            throw operationError
        }
        guard let data = remoteFileData[remotePath] else {
            throw MissingRemoteFileDataError(path: remotePath)
        }
        let start = min(Int(offset), data.count)
        let end: Int
        if let length {
            end = min(data.count, start + Int(length))
        } else {
            end = data.count
        }
        return Data(data[start..<end])
    }

    func writeLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        recordEvent("write:\(remotePath):\(contents.count)")
        liveHosts.append(config.host)
        writeRequests.append((remotePath, contents))
        if let operationError {
            throw operationError
        }
        if persistsWrites {
            remoteFileData[remotePath] = contents
        }
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
        guard supportsSFTPFileIO else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("sftp-read")
        }
        recordEvent("sftp-read:\(remotePath):\(offset):\(length.map(String.init) ?? "all")")
        if let sftpOperationError { throw sftpOperationError }
        guard let data = remoteFileData[remotePath] else {
            throw MissingRemoteFileDataError(path: remotePath)
        }
        let start = min(Int(offset), data.count)
        let end = length.map { min(data.count, start + Int($0)) } ?? data.count
        return Data(data[start..<end])
    }

    func writeLiveSFTPFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        contents: Data
    ) throws -> UInt64 {
        guard supportsSFTPFileIO else {
            throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("sftp-write")
        }
        recordEvent("sftp-write:\(remotePath):\(contents.count)")
        if let sftpOperationError { throw sftpOperationError }
        sftpWriteRequests.append((remotePath, contents))
        if persistsWrites { remoteFileData[remotePath] = contents }
        return UInt64(contents.count)
    }

    func copyLiveFTPPath(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        fromPath: String,
        toPath: String
    ) throws {
        recordEvent("ftp-copy:\(fromPath)->\(toPath)")
        liveHosts.append(config.host)
        if let operationError {
            throw operationError
        }
    }
}

private final class DelayedRemoteFilesBridge: RemoteFilesBridging {
    private let entries: [RemoteFileEntry]
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [String] = []

    init(entries: [RemoteFileEntry]) {
        self.entries = entries
    }

    var eventsSnapshot: [String] {
        lock.withLock { events }
    }

    func waitUntilStarted(timeout: TimeInterval = 1) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func releaseListing() {
        release.signal()
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        lock.withLock {
            events.append("live:\(remotePath)")
        }
        started.signal()
        _ = release.wait(timeout: .now() + 1)
        return entries
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
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private final class DelayedDeleteRemoteFilesBridge: RemoteFilesBridging {
    private let entries: [RemoteFileEntry]
    private let deleteStarted = DispatchSemaphore(value: 0)
    private let deleteRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [String] = []

    init(entries: [RemoteFileEntry]) {
        self.entries = entries
    }

    var eventsSnapshot: [String] {
        lock.withLock { events }
    }

    func waitUntilDeleteStarted(timeout: TimeInterval = 1) -> Bool {
        deleteStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseDelete() {
        deleteRelease.signal()
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        lock.withLock {
            events.append("live:\(remotePath)")
        }
        return entries
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
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {
        lock.withLock {
            events.append("delete:\(remotePath):\(recursive)")
        }
        deleteStarted.signal()
        _ = deleteRelease.wait(timeout: .now() + 1)
    }

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private final class TimedRemoteFilesBridge: RemoteFilesBridging {
    private let entries: [RemoteFileEntry]
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [String] = []
    private var firstStartedAt: Date?

    init(entries: [RemoteFileEntry]) {
        self.entries = entries
    }

    var eventsSnapshot: [String] {
        lock.withLock { events }
    }

    var firstRequestStartedAt: Date? {
        lock.withLock { firstStartedAt }
    }

    func waitUntilStarted(timeout: TimeInterval = 1) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func releaseAllListings() {
        for _ in 0..<4 {
            release.signal()
        }
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        lock.withLock {
            events.append("live:\(remotePath)")
            if firstStartedAt == nil {
                firstStartedAt = Date()
            }
        }
        started.signal()
        _ = release.wait(timeout: .now() + 1)
        return entries
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
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private final class DelayedRemoteFileReadBridge: RemoteFilesBridging {
    private let remotePath: String
    private let data: Data
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(remotePath: String, data: Data) {
        self.remotePath = remotePath
        self.data = data
    }

    func waitUntilReadStarted(timeout: TimeInterval = 1) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func releaseRead() {
        release.signal()
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        []
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        []
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
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}

    func readLiveRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        offset: UInt64,
        length: UInt64?
    ) throws -> Data {
        guard remotePath == self.remotePath else {
            throw MissingRemoteFileDataError(path: remotePath)
        }
        started.signal()
        _ = release.wait(timeout: .now() + 1)
        return data
    }
}

private final class CachedThenDelayedRemoteFilesBridge: RemoteFilesBridging {
    private let cachedEntries: [RemoteFileEntry]
    private let refreshedEntries: [RemoteFileEntry]
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var events: [String] = []
    private var requestCount = 0

    init(cachedEntries: [RemoteFileEntry], refreshedEntries: [RemoteFileEntry]) {
        self.cachedEntries = cachedEntries
        self.refreshedEntries = refreshedEntries
    }

    var eventsSnapshot: [String] {
        lock.withLock { events }
    }

    func waitUntilRefreshStarted(timeout: TimeInterval = 1) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func releaseRefresh() {
        release.signal()
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        cachedEntries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        let count = lock.withLock { () -> Int in
            events.append("live:\(remotePath)")
            requestCount += 1
            return requestCount
        }
        guard count > 1 else {
            return cachedEntries
        }
        started.signal()
        _ = release.wait(timeout: .now() + 1)
        return refreshedEntries
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
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private final class CachedThenFailingRemoteFilesBridge: RemoteFilesBridging {
    private let cachedEntries: [RemoteFileEntry]
    private let refreshError: Error
    private let lock = NSLock()
    private var events: [String] = []
    private var requestCount = 0

    init(cachedEntries: [RemoteFileEntry], refreshError: Error) {
        self.cachedEntries = cachedEntries
        self.refreshError = refreshError
    }

    var eventsSnapshot: [String] {
        lock.withLock { events }
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        cachedEntries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        let count = lock.withLock { () -> Int in
            events.append("live:\(remotePath)")
            requestCount += 1
            return requestCount
        }
        guard count > 1 else {
            return cachedEntries
        }
        throw refreshError
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
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private final class RecordingRemoteFileErrorPresenter: RemoteFileErrorPresenting {
    var contexts: [RemoteFileErrorContext] = []
    var messages: [String] = []
    var informativeMessages: [String] = []

    func present(_ error: Error, context: RemoteFileErrorContext, parentWindow: NSWindow?) {
        contexts.append(context)
        messages.append(context.messageText)
        informativeMessages.append(context.informativeText(for: error))
    }
}

private final class RecordingRemoteFileOperationPrompt: RemoteFileOperationPrompting {
    private let directoryName: String?
    private let fileName: String?
    private let renameDestination: String?
    private let chmodMode: String?
    private let openApplicationURL: URL?
    private let backupDestination: RemoteFileBackupDestination?
    private let restoreSource: RemoteFileRestoreSource?
    private let localBackupFileURLs: [URL]?
    private let confirmsDelete: Bool
    var openApplicationPromptCount = 0
    var backupCandidatePrompts: [[RemoteFileBackupCandidate]] = []
    var remoteBackupFilePrompts: [[RemoteFileSelection]] = []
    var deleteConfirmations: [RemoteFileSelection] = []

    init(
        directoryName: String? = nil,
        fileName: String? = nil,
        renameDestination: String? = nil,
        chmodMode: String? = nil,
        openApplicationURL: URL? = nil,
        backupDestination: RemoteFileBackupDestination? = nil,
        restoreSource: RemoteFileRestoreSource? = nil,
        localBackupFileURLs: [URL]? = nil,
        confirmsDelete: Bool = false
    ) {
        self.directoryName = directoryName
        self.fileName = fileName
        self.renameDestination = renameDestination
        self.chmodMode = chmodMode
        self.openApplicationURL = openApplicationURL
        self.backupDestination = backupDestination
        self.restoreSource = restoreSource
        self.localBackupFileURLs = localBackupFileURLs
        self.confirmsDelete = confirmsDelete
    }

    func promptDirectoryName(parentWindow: NSWindow?) -> String? {
        directoryName
    }

    func promptFileName(parentWindow: NSWindow?) -> String? {
        fileName
    }

    func promptRenameDestination(currentPath: String, parentWindow: NSWindow?) -> String? {
        renameDestination
    }

    func confirmDelete(selection: RemoteFileSelection, parentWindow: NSWindow?) -> Bool {
        deleteConfirmations.append(selection)
        return confirmsDelete
    }

    func promptChmodMode(currentPath: String, parentWindow: NSWindow?) -> String? {
        chmodMode
    }

    func promptOpenApplication(parentWindow: NSWindow?) -> URL? {
        openApplicationPromptCount += 1
        return openApplicationURL
    }

    func promptBackupCandidates(
        candidates: [RemoteFileBackupCandidate],
        parentWindow: NSWindow?
    ) -> [RemoteFileBackupCandidate]? {
        backupCandidatePrompts.append(candidates)
        return candidates.first.map { [$0] }
    }

    func promptBackupDestination(parentWindow: NSWindow?) -> RemoteFileBackupDestination? {
        backupDestination
    }

    func promptRestoreSource(parentWindow: NSWindow?) -> RemoteFileRestoreSource? {
        restoreSource
    }

    func promptRemoteBackupFiles(
        candidates: [RemoteFileSelection],
        parentWindow: NSWindow?
    ) -> [RemoteFileSelection]? {
        remoteBackupFilePrompts.append(candidates)
        return candidates
    }

    func promptLocalBackupFiles(parentWindow: NSWindow?) -> [URL]? {
        localBackupFileURLs
    }
}

private final class RecordingRemoteFileConflictResolver: RemoteFileConflictResolving {
    struct Request {
        let destinationPath: String
        let direction: ScpDirection
    }

    var requests: [Request] = []
    private let policy: ScpConflictPolicy?

    init(policy: ScpConflictPolicy?) {
        self.policy = policy
    }

    func resolveConflict(destinationPath: String, direction: ScpDirection, parentWindow: NSWindow?) -> ScpConflictPolicy? {
        requests.append(Request(destinationPath: destinationPath, direction: direction))
        return policy
    }
}

private final class RecordingBatchConflictResolver: RemoteFileConflictResolving {
    private let decision: RemoteFileConflictDecision?
    private(set) var requests: [String] = []

    init(decision: RemoteFileConflictDecision?) {
        self.decision = decision
    }

    func resolveConflict(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> ScpConflictPolicy? {
        decision?.policy
    }

    func resolveConflictDecision(
        destinationPath: String,
        direction: ScpDirection,
        parentWindow: NSWindow?
    ) -> RemoteFileConflictDecision? {
        requests.append(destinationPath)
        return decision
    }
}

private final class RecordingSCPTransferScheduler: SCPTransferScheduling {
    var runtimeIDs: [String] = []
    var configs: [SshConnectionConfig] = []
    var fingerprints: [String] = []
    var jobs: [ScpTransferJob] = []
    var estimatedByteTotals: [String: UInt64] = [:]
    private let completesImmediately: Bool
    private var completionHandlers: [String: (ScpTransferProgress) -> Void] = [:]

    init(completesImmediately: Bool = false) {
        self.completesImmediately = completesImmediately
    }

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) {
        scheduleLiveTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: nil
        )
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        runtimeIDs.append(runtimeID)
        scheduleLiveTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: completion
        )
    }

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        configs.append(config)
        fingerprints.append(expectedFingerprintSHA256)
        jobs.append(job)
        completionHandlers[job.id] = completion
        if completesImmediately {
            complete(jobID: job.id)
        }
    }

    func complete(jobID: String) {
        report(jobID: jobID, status: "completed", completesBytes: true)
    }

    func fail(jobID: String) {
        report(jobID: jobID, status: "failed")
    }

    func cancel(jobID: String) {
        report(jobID: jobID, status: "canceled")
    }

    func report(jobID: String, status: String, completesBytes: Bool = false) {
        guard let job = jobs.first(where: { $0.id == jobID }) else {
            return
        }
        completionHandlers[jobID]?(
            ScpTransferProgress(
                jobId: jobID,
                bytesDone: completesBytes ? job.bytesTotal : 0,
                bytesTotal: job.bytesTotal,
                status: status
            )
        )
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {
        estimatedByteTotals[jobID] = bytesTotal
    }
}

@MainActor
private struct FilesCoordinatorPresentationHarness {
    let center: WorkbenchCenterContainerViewController
    let presentation: RemoteEditorPresentationCoordinator
}

@MainActor
private func makeFilesCoordinatorPresentationHarness(testName: String) -> FilesCoordinatorPresentationHarness {
    let defaults = UserDefaults(suiteName: "Stacio.FilesCoordinatorTests.\(testName).\(UUID().uuidString)")!
    let store = UserDefaultsRemoteEditorPresentationStore(
        defaults: defaults,
        frameAutosaveName: .init("FilesCoordinator.Editor.Test")
    )
    let center = WorkbenchCenterContainerViewController(
        workspaceViewController: NSViewController(),
        presentationStore: store
    )
    let presentation = RemoteEditorPresentationCoordinator(
        dockHost: center,
        presentationStore: store,
        screenProvider: AppKitRemoteEditorScreenProvider()
    )
    return FilesCoordinatorPresentationHarness(center: center, presentation: presentation)
}

private final class RecordingRemoteEditOpener: RemoteEditOpening {
    struct OpenRequest {
        let url: URL
        let mode: RemoteFileOpenMode
        let applicationURL: URL?
        let saveHandler: RemoteEditSaveHandler?
    }

    struct RemoteDocumentRequest {
        let document: RemoteTextEditorDocumentDescriptor
        let mode: RemoteFileOpenMode
        let saveHandler: ((String) throws -> Void)?
    }

    struct FailedOpenRequest {
        let selection: RemoteFileSelection
        let mode: RemoteFileOpenMode
        let message: String
    }

    var openedURLs: [URL] = []
    var openRequests: [OpenRequest] = []
    var remoteDocumentRequests: [RemoteDocumentRequest] = []
    var failedOpenRequests: [FailedOpenRequest] = []
    var comparedURLGroups: [[URL]] = []
    var preparedRequestIDs: [UUID] = []
    var localCopyRequestIDs: [UUID] = []
    var remoteDocumentRequestIDs: [UUID] = []
    var failedOpenRequestIDs: [UUID] = []

    func prepareRemoteOpen(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode
    ) -> RemoteEditOpenRequest? {
        let request = RemoteEditOpenRequest()
        preparedRequestIDs.append(request.id)
        return request
    }

    func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {
        openedURLs.append(url)
        openRequests.append(OpenRequest(
            url: url,
            mode: mode,
            applicationURL: applicationURL,
            saveHandler: saveHandler
        ))
    }

    func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?,
        request: RemoteEditOpenRequest
    ) {
        localCopyRequestIDs.append(request.id)
        openLocalCopy(
            at: url,
            mode: mode,
            applicationURL: applicationURL,
            saveHandler: saveHandler
        )
    }

    func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {
        remoteDocumentRequests.append(RemoteDocumentRequest(
            document: document,
            mode: mode,
            saveHandler: saveHandler
        ))
    }

    func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?,
        request: RemoteEditOpenRequest
    ) {
        remoteDocumentRequestIDs.append(request.id)
        openRemoteDocument(document, mode: mode, saveHandler: saveHandler)
    }

    func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws {
        comparedURLGroups.append(urls)
    }

    func remoteOpenDidFail(selection: RemoteFileSelection, mode: RemoteFileOpenMode, message: String) {
        failedOpenRequests.append(FailedOpenRequest(selection: selection, mode: mode, message: message))
    }

    func remoteOpenDidFail(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        message: String,
        request: RemoteEditOpenRequest
    ) {
        failedOpenRequestIDs.append(request.id)
        remoteOpenDidFail(selection: selection, mode: mode, message: message)
    }
}

private final class RecordingFTPTransferScheduler: FTPTransferScheduling, CustomStringConvertible {
    var runtimeIDs: [String] = []
    var configs: [FtpConnectionConfig] = []
    var jobs: [ScpTransferJob] = []
    var estimatedByteTotals: [String: UInt64] = [:]
    private var completionHandlers: [String: (ScpTransferProgress) -> Void] = [:]
    var description: String {
        jobs.map(\.id).joined(separator: " ")
    }

    func scheduleLiveFTPTransfer(
        runtimeID: String,
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        runtimeIDs.append(runtimeID)
        scheduleLiveFTPTransfer(
            config: config,
            secret: secret,
            job: job,
            completion: completion
        )
    }

    func scheduleLiveFTPTransfer(
        config: FtpConnectionConfig,
        secret: FtpAuthSecret,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        configs.append(config)
        jobs.append(job)
        completionHandlers[job.id] = completion
    }

    func complete(jobID: String) {
        report(jobID: jobID, status: "completed", completesBytes: true)
    }

    func cancel(jobID: String) {
        report(jobID: jobID, status: "canceled")
    }

    func report(jobID: String, status: String, completesBytes: Bool = false) {
        guard let job = jobs.first(where: { $0.id == jobID }) else {
            return
        }
        completionHandlers[jobID]?(
            ScpTransferProgress(
                jobId: jobID,
                bytesDone: completesBytes ? job.bytesTotal : 0,
                bytesTotal: job.bytesTotal,
                status: status
            )
        )
    }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {
        estimatedByteTotals[jobID] = bytesTotal
    }
}

private final class RecordingStacioLogStore: StacioLogWriting, StacioLogReading {
    var lines: [String] = []

    func append(level: StacioLogLevel, category: String, message: String, sensitiveValues: [String]) {
        var line = "[\(level.rawValue.uppercased())] [\(category)] \(message)"
        for value in sensitiveValues where !value.isEmpty {
            line = line.replacingOccurrences(of: value, with: L10n.Diagnostics.redactedCredential)
        }
        lines.append(line)
    }

    func recentLines(limit: Int) throws -> [String] {
        Array(lines.suffix(max(0, limit)))
    }
}

private final class RecordingUploadFilePicker: RemoteFileUploadPicking {
    var pickCount = 0
    var pickFolderCount = 0
    private let selectedFile: LocalUploadFile?
    private let selectedFolder: LocalUploadFile?

    init(selectedFile: LocalUploadFile? = nil, selectedFolder: LocalUploadFile? = nil) {
        self.selectedFile = selectedFile
        self.selectedFolder = selectedFolder
    }

    func pickUploadFile(parentWindow: NSWindow?) -> LocalUploadFile? {
        pickCount += 1
        return selectedFile
    }

    func pickUploadFolder(parentWindow: NSWindow?) -> LocalUploadFile? {
        pickFolderCount += 1
        return selectedFolder
    }
}

private final class BlockingLocalUploadSizeProvider: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let size: UInt64

    init(size: UInt64) {
        self.size = size
    }

    func size(_ url: URL) -> UInt64 {
        started.signal()
        _ = releaseSignal.wait(timeout: .now() + 1)
        return size
    }

    func waitUntilStarted(timeout: TimeInterval = 1) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        releaseSignal.signal()
    }
}

private final class RecordingDownloadDestinationPicker: RemoteFileDownloadDestinationPicking {
    let destinationPath: String?
    let destinationDirectory: String?
    var suggestedFileNames: [String] = []
    var pickDirectoryCount = 0

    init(destinationPath: String?, destinationDirectory: String? = nil) {
        self.destinationPath = destinationPath
        self.destinationDirectory = destinationDirectory
    }

    func pickDownloadDestination(
        suggestedFileName: String,
        parentWindow: NSWindow?
    ) -> String? {
        suggestedFileNames.append(suggestedFileName)
        return destinationPath
    }

    func pickDownloadDirectory(parentWindow: NSWindow?) -> String? {
        pickDirectoryCount += 1
        return destinationDirectory
    }
}

private enum RecordingFilesRemoteChromiumRuntimeError: Error {
    case cleanupFailed
}

private final class FilesRemoteChromiumCommandExecutor: RemoteChromiumCommandExecuting {
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func execute(
        command: String,
        context: TunnelLiveSessionContext,
        timeout: TimeInterval
    ) throws -> String {
        outputs.isEmpty ? "" : outputs.removeFirst()
    }
}

private final class FilesRemoteChromiumTunnelBridge: TunnelRuntimeBridging {
    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        try start(profile: profile)
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped")
    }
}

private final class BlockingFilesSCPTransferBridge: SCPTransferBridging, @unchecked Sendable {
    private let started: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)

    init(started: XCTestExpectation) {
        self.started = started
    }

    func release() {
        gate.signal()
    }

    func runLiveSCPTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob
    ) throws -> [ScpTransferProgress] {
        started.fulfill()
        guard gate.wait(timeout: .now() + 2) == .success else {
            throw RecordingFilesRemoteChromiumRuntimeError.cleanupFailed
        }
        return [
            ScpTransferProgress(
                jobId: job.id,
                bytesDone: max(1, job.bytesTotal),
                bytesTotal: max(1, job.bytesTotal),
                status: "completed"
            )
        ]
    }
}

@MainActor
private final class DeferredFilesTransferCompletionDriver {
    var completion: (() -> Void)?

    func complete() {
        completion?()
        completion = nil
    }
}

@MainActor
private final class DeferredFilesSCPTransferScheduler: SCPTransferScheduling {
    private let driver: DeferredFilesTransferCompletionDriver
    private var scheduledCompletion: ((ScpTransferProgress) -> Void)?
    private var scheduledJob: ScpTransferJob?

    init(driver: DeferredFilesTransferCompletionDriver) {
        self.driver = driver
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduledJob = job
        scheduledCompletion = completion
        driver.completion = { [weak self] in
            guard let self, let job = self.scheduledJob else { return }
            let progress = ScpTransferProgress(
                jobId: job.id,
                bytesDone: max(1, job.bytesTotal),
                bytesTotal: max(1, job.bytesTotal),
                status: "completed"
            )
            self.scheduledCompletion?(progress)
            self.scheduledCompletion = nil
            self.scheduledJob = nil
        }
    }

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduleLiveTransfer(
            runtimeID: config.host,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job,
            completion: completion
        )
    }

    func disconnectTransfers(runtimeID: String) -> [String] { [] }
    func cancelTransfer(jobID: String) -> Bool { false }
    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}
}

private final class WeakFilesObjectBox<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

private final class RecordingFilesRemoteChromiumRuntime: RemoteChromiumRuntimeControlling {
    let session: RemoteChromiumRuntimeSession
    let acknowledgementResult: Result<Void, Error>
    private(set) var acknowledgedDownloads: [RemoteChromiumDownload] = []

    init(
        session: RemoteChromiumRuntimeSession,
        acknowledgementResult: Result<Void, Error> = .success(())
    ) {
        self.session = session
        self.acknowledgementResult = acknowledgementResult
    }

    func start(
        context: TunnelLiveSessionContext,
        localPort: UInt16
    ) throws -> RemoteChromiumRuntimeSession {
        session
    }

    func stop(session: RemoteChromiumRuntimeSession) {}

    func retainDownload(_ download: RemoteChromiumDownload) -> Bool {
        download.isCanonical(for: session)
    }

    func acknowledgeDownload(
        _ download: RemoteChromiumDownload,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) -> Bool {
        guard download.isCanonical(for: session) else { return false }
        acknowledgedDownloads.append(download)
        completion(acknowledgementResult)
        return true
    }
}

private extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }
}

private extension NSView {
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
