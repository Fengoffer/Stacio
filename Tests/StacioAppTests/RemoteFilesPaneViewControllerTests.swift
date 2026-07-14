import AppKit
import StacioCoreBindings
import WebKit
import XCTest
@testable import StacioApp

@MainActor
final class RemoteFilesPaneViewControllerTests: XCTestCase {
    private static let rightCapabilityWidthDefaultsKey = "Stacio.RemoteFiles.rightCapabilityWidth"
    private static let rightCapabilityWidthUserSetDefaultsKey = "Stacio.RemoteFiles.rightCapabilityWidth.userSet"
    private var temporaryDirectories: [URL] = []
    private var rightCapabilityWidthDefaults: UserDefaults!
    private var rightCapabilityWidthDefaultsSuiteName: String!

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

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suiteName = "StacioRemoteFilesPaneTests-\(UUID().uuidString)"
        rightCapabilityWidthDefaultsSuiteName = suiteName
        rightCapabilityWidthDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        rightCapabilityWidthDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName = rightCapabilityWidthDefaultsSuiteName {
            rightCapabilityWidthDefaults?.removePersistentDomain(forName: suiteName)
        }
        rightCapabilityWidthDefaults = nil
        rightCapabilityWidthDefaultsSuiteName = nil
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testInitialLoadUsesCurrentRemotePathFromSSHSession() throws {
        let bridge = RetryingRemoteFilesBridge(results: [
            .success([
                RemoteFileEntry(kind: .file, path: "/srv/app/current.log", size: 64, linkTarget: nil)
            ])
        ])
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_current_path",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/app",
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )

        pane.loadView()

        XCTAssertEqual(bridge.events, ["live:/srv/app"])
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("/srv/app"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("current.log"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("/srv/app/current.log"))
    }

    func testInitialLoadFailureShowsSanitizedChineseErrorAndRetryRestoresListing() throws {
        let bridge = RetryingRemoteFilesBridge(results: [
            .failure(SensitiveInitialListingError(
                message: "Permission denied for secret-ref prod-password at /Users/alice/.ssh/prod_key"
            )),
            .success([
                RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
            ])
        ])
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_retry_test",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: bridge,
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )

        pane.loadView()

        XCTAssertEqual(bridge.events, ["live:~"])
        XCTAssertNotNil(pane.initialLoadError)
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("无法加载远端目录"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("权限被拒绝"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("[已隐藏路径]"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("[已隐藏凭据]"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("secret-ref"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("/Users/alice/.ssh/prod_key"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("SFTP"))

        let retryButton = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Files.refresh") as? NSButton
        )
        XCTAssertEqual(retryButton.title, "")
        XCTAssertEqual(retryButton.toolTip, "重试")
        retryButton.performClick(nil as Any?)

        XCTAssertTrue(waitUntil { bridge.events == ["live:~", "live:~"] && pane.visibleTextSnapshotForTesting.contains("app.log") })
        XCTAssertEqual(bridge.events, ["live:~", "live:~"])
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("app.log"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("/home/deploy/app.log"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("无法加载远端目录"))
        XCTAssertEqual(retryButton.title, "")
        XCTAssertEqual(retryButton.toolTip, "刷新远端目录")
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("SFTP"))
    }

    func testRightWorkspacePresentsEditorBesideFilesWithoutCoveringFileList() throws {
        let fileURL = try makeTemporaryFile(name: "config.json", contents: #"{"enabled": false}"#)
        let bridge = RetryingRemoteFilesBridge(results: [
            .success([
                RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 18, linkTarget: nil),
                RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil)
            ])
        ])
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_workspace",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/app",
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)

        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)
        pane.view.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.RemoteFiles.workspaceSplit") as? NSSplitView
        )
        let filesView = pane.filesViewControllerForTesting.view
        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        let filesFrame = filesView.convert(filesView.bounds, to: pane.view)
        let editorFrame = editor.view.convert(editor.view.bounds, to: pane.view)

        XCTAssertEqual(splitView.arrangedSubviews.count, 2)
        XCTAssertTrue(splitView.arrangedSubviews[0] === editor.view)
        XCTAssertTrue(splitView.arrangedSubviews[1] === filesView)
        XCTAssertFalse(filesFrame.intersects(editorFrame))
        XCTAssertLessThan(editorFrame.minX, filesFrame.minX)
        XCTAssertGreaterThanOrEqual(filesFrame.width, 240)
        XCTAssertGreaterThanOrEqual(editorFrame.width, pane.view.bounds.width * 0.7 - splitView.dividerThickness)
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("logs"))
        XCTAssertNotNil(pane.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testRightWorkspaceForwardsEditorAIQuestionRequests() throws {
        let fileURL = try makeTemporaryFile(name: "nginx.conf", contents: "server { listen 80; }\n")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_ai",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        var prompts: [String] = []
        pane.onAIQuestionRequested = { prompts.append($0) }

        pane.loadView()
        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)
        pane.textEditorViewControllerForTesting?.requestAIForActiveDocumentForTesting()

        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("nginx.conf"))
        XCTAssertTrue(prompt.contains("listen 80"))
    }

    func testRightWorkspaceDoesNotStoreDefaultWidthBeforeDividerMoves() throws {
        let fileURL = try makeTemporaryFile(name: "config.toml", contents: "enabled = true\n")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_default_not_manual",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)

        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertNil(rightCapabilityWidthDefaults.object(forKey: Self.rightCapabilityWidthDefaultsKey))
        XCTAssertFalse(rightCapabilityWidthDefaults.bool(forKey: Self.rightCapabilityWidthUserSetDefaultsKey))
    }

    func testRightWorkspaceIgnoresUnmarkedStoredWidthWhenOpeningEditor() throws {
        rightCapabilityWidthDefaults.set(420, forKey: Self.rightCapabilityWidthDefaultsKey)
        let fileURL = try makeTemporaryFile(name: "legacy.json", contents: "{}\n")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_ignore_stale_width",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)

        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)
        pane.view.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.RemoteFiles.workspaceSplit") as? NSSplitView
        )
        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        let editorFrame = editor.view.convert(editor.view.bounds, to: pane.view)
        XCTAssertGreaterThanOrEqual(editorFrame.width, pane.view.bounds.width * 0.7 - splitView.dividerThickness)
    }

    func testRightWorkspaceAllowsEditorToExpandUntilFilesPaneIsNarrow() throws {
        let fileURL = try makeTemporaryFile(name: "server.conf", contents: "port=8080\n")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_wide_drag",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)

        let splitView = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.RemoteFiles.workspaceSplit") as? NSSplitView
        )
        splitView.setPosition(1_000, ofDividerAt: 0)
        pane.view.layoutSubtreeIfNeeded()

        let filesView = pane.filesViewControllerForTesting.view
        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        let filesFrame = filesView.convert(filesView.bounds, to: pane.view)
        let editorFrame = editor.view.convert(editor.view.bounds, to: pane.view)

        XCTAssertLessThanOrEqual(filesFrame.width, 300)
        XCTAssertGreaterThanOrEqual(editorFrame.width, 890)
        XCTAssertLessThan(editorFrame.minX, filesFrame.minX)
        XCTAssertFalse(filesFrame.intersects(editorFrame))
    }

    func testRightWorkspaceFilesPaneCanCollapseAndRestoreWithShortcutAction() throws {
        let fileURL = try makeTemporaryFile(name: "server.conf", contents: "port=8080\n")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_collapse",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)
        pane.view.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        let expandedFrame = editor.view.convert(editor.view.bounds, to: pane.view)

        XCTAssertTrue(performControlBShortcut(on: pane.view))
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(pane.filesViewControllerForTesting.view.isHidden)
        let collapsedFrame = editor.view.convert(editor.view.bounds, to: pane.view)
        XCTAssertGreaterThan(collapsedFrame.width, expandedFrame.width)

        XCTAssertTrue(performControlBShortcut(on: pane.view))
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(pane.filesViewControllerForTesting.view.isHidden)
        let restoredFrame = editor.view.convert(editor.view.bounds, to: pane.view)
        XCTAssertLessThan(restoredFrame.width, collapsedFrame.width)
    }

    func testRightWorkspaceStoresManualEditorWidthAndRestoresItForNextPane() throws {
        let fileURL = try makeTemporaryFile(name: "app.yaml", contents: "enabled: true\n")
        let firstPane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_persist_first",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        firstPane.loadView()
        firstPane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        firstPane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)

        let firstSplitView = try XCTUnwrap(
            firstPane.view.firstSubview(withIdentifier: "Stacio.RemoteFiles.workspaceSplit") as? NSSplitView
        )
        let desiredEditorWidth: CGFloat = 500
        firstSplitView.setPosition(desiredEditorWidth, ofDividerAt: 0)
        firstPane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            rightCapabilityWidthDefaults.double(forKey: Self.rightCapabilityWidthDefaultsKey),
            Double(desiredEditorWidth),
            accuracy: 2
        )
        XCTAssertTrue(rightCapabilityWidthDefaults.bool(forKey: Self.rightCapabilityWidthUserSetDefaultsKey))

        let secondPane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_persist_second",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        secondPane.loadView()
        secondPane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        secondPane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)
        secondPane.view.layoutSubtreeIfNeeded()

        let secondEditor = try XCTUnwrap(secondPane.textEditorViewControllerForTesting)
        let secondFilesView = secondPane.filesViewControllerForTesting.view
        let secondEditorFrame = secondEditor.view.convert(secondEditor.view.bounds, to: secondPane.view)
        let secondFilesFrame = secondFilesView.convert(secondFilesView.bounds, to: secondPane.view)
        XCTAssertGreaterThanOrEqual(secondEditorFrame.width, desiredEditorWidth)
        XCTAssertGreaterThanOrEqual(secondFilesFrame.width, 240)
        XCTAssertLessThan(secondEditorFrame.minX, secondFilesFrame.minX)
    }

    func testRightWorkspaceResizeNotificationsDoNotRewriteStoredWidth() throws {
        let suiteName = "StacioRemoteFilesPaneCountingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CountingRemoteFilesPaneUserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fileURL = try makeTemporaryFile(name: "resize.conf", contents: "mode=fast\n")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_editor_resize_notifications",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: defaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        pane.presentTextEditorForTesting(localURL: fileURL, saveHandler: nil)

        let splitView = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.RemoteFiles.workspaceSplit") as? NSSplitView
        )
        splitView.setPosition(520, ofDividerAt: 0)
        pane.view.layoutSubtreeIfNeeded()
        let writesAfterManualMove = defaults.setCount(forKey: Self.rightCapabilityWidthDefaultsKey)

        for _ in 0..<10 {
            pane.splitViewDidResizeSubviews(
                Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
            )
        }

        XCTAssertEqual(defaults.setCount(forKey: Self.rightCapabilityWidthDefaultsKey), writesAfterManualMove)
    }

    func testRightWorkspacePreviewsImagesAndPlaysAudioVideoInStacio() throws {
        let imageURL = try makeTemporaryFile(name: "screenshot.png", contents: "png")
        let videoURL = try makeTemporaryFile(name: "demo.mov", contents: "mov")
        let audioURL = try makeTemporaryFile(name: "clip.mp3", contents: "mp3")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_media_workspace",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()

        pane.presentMediaPreviewForTesting(localURL: imageURL)
        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        XCTAssertNil(pane.mediaPreviewViewControllerForTesting)
        XCTAssertNotNil(pane.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView)
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "image")

        pane.presentMediaPreviewForTesting(localURL: videoURL)
        XCTAssertTrue(pane.textEditorViewControllerForTesting === editor)
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "video")

        pane.presentMediaPreviewForTesting(localURL: audioURL)
        XCTAssertTrue(pane.textEditorViewControllerForTesting === editor)
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "audio")
    }

    func testRightWorkspaceMediaPreviewUsesEditorTabs() throws {
        let imageURL = try makeTemporaryFile(name: "screenshot.png", contents: "")
        let videoURL = try makeTemporaryFile(name: "demo.mp4", contents: "")
        let audioURL = try makeTemporaryFile(name: "clip.mp3", contents: "")
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_media_tabs",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()

        pane.presentMediaPreviewForTesting(localURL: imageURL)
        let firstEditor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        pane.presentMediaPreviewForTesting(localURL: videoURL)
        pane.presentMediaPreviewForTesting(localURL: audioURL)

        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        XCTAssertTrue(editor === firstEditor)
        XCTAssertNil(pane.mediaPreviewViewControllerForTesting)
        XCTAssertEqual(editor.tabTitlesForTesting, ["screenshot.png", "demo.mp4", "clip.mp3"])
        XCTAssertEqual(editor.activeFileNameForTesting, "clip.mp3")
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "audio")
        XCTAssertNotNil(pane.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView)

        editor.switchToDocumentForTesting(fileName: "demo.mp4")

        XCTAssertEqual(editor.activeFileNameForTesting, "demo.mp4")
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "video")

        editor.closeDocumentForTesting(fileName: "demo.mp4")

        XCTAssertEqual(editor.tabTitlesForTesting, ["screenshot.png", "clip.mp3"])
        XCTAssertEqual(editor.activeFileNameForTesting, "clip.mp3")
    }

    func testRemoteFilesPaneDoesNotScheduleDownloadsForOnlineMediaPreview() throws {
        weak var weakScheduler: RecordingRemoteFilesPaneTransferScheduler?
        let pane: RemoteFilesPaneViewController
        do {
            let scheduler = RecordingRemoteFilesPaneTransferScheduler()
            weakScheduler = scheduler
            pane = RemoteFilesPaneViewController(
                runtimeID: "scp_media_scheduler_retention",
                context: Self.liveContext(),
                title: "远端文件",
                bridge: RetryingRemoteFilesBridge(results: [
                    .success([
                        RemoteFileEntry(kind: .file, path: "/srv/app/screenshot.png", size: 2_048, linkTarget: nil)
                    ])
                ]),
                transferScheduler: scheduler,
                initialRemotePath: "/srv/app",
                rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
            )
        }
        pane.loadView()

        pane.filesViewControllerForTesting.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.filesViewControllerForTesting.openSelectedEntryForTesting()

        let scheduler = try XCTUnwrap(weakScheduler)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        let editor = try XCTUnwrap(pane.textEditorViewControllerForTesting)
        XCTAssertEqual(editor.activeFileNameForTesting, "screenshot.png")
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "image")
        XCTAssertNil(pane.openProgressViewControllerForTesting)
    }

    func testRightWorkspaceKeepsDirtyEditorOpenWhenClosePromptIsCanceled() throws {
        let fileURL = try makeTemporaryFile(name: "app.conf", contents: "debug=false\n")
        let confirmer = RecordingRemoteFilesEditorCloseConfirmer(decision: .cancel)
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_dirty_editor",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [.success([])]),
            transferScheduler: nil,
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.presentTextEditorForTesting(
            localURL: fileURL,
            saveHandler: nil,
            closeConfirmer: confirmer
        )
        pane.textEditorViewControllerForTesting?.replaceTextForTesting("debug=true\n")

        XCTAssertFalse(pane.closeRightWorkspaceForTesting())

        XCTAssertEqual(confirmer.promptedFileNames, ["app.conf"])
        XCTAssertNotNil(pane.textEditorViewControllerForTesting)
        XCTAssertNotNil(pane.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
    }

    func testDoubleClickRemoteFileShowsImmediateRightWorkspaceOnlineOpenProgress() throws {
        let scheduler = RecordingRemoteFilesPaneTransferScheduler()
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_open_progress",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: RetryingRemoteFilesBridge(results: [
                .success([
                    RemoteFileEntry(kind: .file, path: "/srv/app/archive.bin", size: 2_048, linkTarget: nil)
                ])
            ]),
            transferScheduler: scheduler,
            initialRemotePath: "/srv/app",
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 1_080, height: 640)

        pane.filesViewControllerForTesting.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.filesViewControllerForTesting.openSelectedEntryForTesting()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertNotNil(pane.view.firstSubview(withIdentifier: "Stacio.RemoteFileOpenProgress.root"))
        XCTAssertTrue(pane.viewTextSnapshot().contains("正在在线打开远端文件"))
        XCTAssertTrue(pane.visibleTextSnapshotForTesting.contains("archive.bin"))
    }

    func testRightWorkspaceIgnoresRemoteOpenReadCompletionAfterProgressIsClosed() throws {
        let bridge = DelayedRemoteFilesPaneReadBridge(
            entries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 18, linkTarget: nil)
            ],
            remotePath: "/srv/app/config.json",
            data: Data(#"{"enabled":true}"#.utf8)
        )
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_open_progress_closed",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/app",
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()

        pane.filesViewControllerForTesting.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.filesViewControllerForTesting.openSelectedEntryForTesting()

        XCTAssertTrue(bridge.waitUntilReadStarted())
        XCTAssertNotNil(pane.openProgressViewControllerForTesting)
        XCTAssertTrue(pane.closeRightWorkspaceForTesting())
        XCTAssertNil(pane.openProgressViewControllerForTesting)

        bridge.releaseRead()

        let reopened = waitUntil(timeout: 0.5) {
            pane.textEditorViewControllerForTesting != nil
        }
        XCTAssertFalse(reopened)
        XCTAssertNil(pane.textEditorViewControllerForTesting)
    }

    func testCloseRemoteFilesRuntimeClearsOpenProgressAndIgnoresLateOnlineReadCompletion() throws {
        let bridge = DelayedRemoteFilesPaneReadBridge(
            entries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/runtime.conf", size: 13, linkTarget: nil)
            ],
            remotePath: "/srv/app/runtime.conf",
            data: Data("enabled=true\n".utf8)
        )
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_open_progress_runtime_close",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/app",
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()

        pane.filesViewControllerForTesting.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.filesViewControllerForTesting.openSelectedEntryForTesting()

        XCTAssertTrue(bridge.waitUntilReadStarted())
        XCTAssertNotNil(pane.openProgressViewControllerForTesting)

        pane.closeRemoteFilesRuntime()

        XCTAssertNil(pane.openProgressViewControllerForTesting)

        bridge.releaseRead()

        let reopened = waitUntil(timeout: 0.5) {
            pane.textEditorViewControllerForTesting != nil
        }
        XCTAssertFalse(reopened)
        XCTAssertNil(pane.textEditorViewControllerForTesting)
    }

    func testRightWorkspaceIgnoresOlderRemoteOpenReadWhenAnotherFileReplacesProgress() throws {
        let bridge = MultiDelayedRemoteFilesPaneReadBridge(
            entries: [
                RemoteFileEntry(kind: .file, path: "/srv/app/first.conf", size: 11, linkTarget: nil),
                RemoteFileEntry(kind: .file, path: "/srv/app/second.conf", size: 12, linkTarget: nil)
            ],
            dataByRemotePath: [
                "/srv/app/first.conf": Data("first=true\n".utf8),
                "/srv/app/second.conf": Data("second=true\n".utf8)
            ]
        )
        let pane = RemoteFilesPaneViewController(
            runtimeID: "scp_open_progress_replaced",
            context: Self.liveContext(),
            title: "远端文件",
            bridge: bridge,
            transferScheduler: nil,
            initialRemotePath: "/srv/app",
            rightCapabilityWidthDefaults: rightCapabilityWidthDefaults
        )
        pane.loadView()

        pane.filesViewControllerForTesting.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.filesViewControllerForTesting.openSelectedEntryForTesting()
        XCTAssertTrue(bridge.waitUntilReadStarted(remotePath: "/srv/app/first.conf"))

        pane.filesViewControllerForTesting.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        pane.filesViewControllerForTesting.openSelectedEntryForTesting()
        XCTAssertTrue(bridge.waitUntilReadStarted(remotePath: "/srv/app/second.conf"))

        bridge.releaseRead(remotePath: "/srv/app/first.conf")

        let staleFirstOpened = waitUntil(timeout: 0.5) {
            pane.textEditorViewControllerForTesting?.activeFileNameForTesting == "first.conf"
        }
        XCTAssertFalse(staleFirstOpened)
        XCTAssertNil(pane.textEditorViewControllerForTesting)
        XCTAssertNotNil(pane.openProgressViewControllerForTesting)

        bridge.releaseRead(remotePath: "/srv/app/second.conf")

        XCTAssertTrue(waitUntil {
            pane.textEditorViewControllerForTesting?.activeFileNameForTesting == "second.conf"
        })
        XCTAssertEqual(pane.textEditorViewControllerForTesting?.currentTextForTesting, "second=true\n")
    }

    private static func liveContext() -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "files.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:files"
        )
    }

    private func makeTemporaryFile(name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteFilesPaneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct SensitiveInitialListingError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        "SensitiveInitialListingError(message: \"\(message)\")"
    }
}

private final class RecordingRemoteFilesEditorCloseConfirmer: RemoteTextEditorCloseConfirming {
    let decision: RemoteTextEditorCloseDecision
    var promptedFileNames: [String] = []

    init(decision: RemoteTextEditorCloseDecision) {
        self.decision = decision
    }

    func confirmClose(fileName: String, parentWindow: NSWindow?) -> RemoteTextEditorCloseDecision {
        promptedFileNames.append(fileName)
        return decision
    }
}

private final class RecordingRemoteFilesPaneTransferScheduler: SCPTransferScheduling {
    var jobs: [ScpTransferJob] = []

    func scheduleLiveTransfer(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        jobs.append(job)
    }
}

private final class CountingRemoteFilesPaneUserDefaults: UserDefaults {
    private var setCounts: [String: Int] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        setCounts[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }

    func setCount(forKey key: String) -> Int {
        setCounts[key, default: 0]
    }
}

private final class RetryingRemoteFilesBridge: RemoteFilesBridging {
    enum Result {
        case success([RemoteFileEntry])
        case failure(Error)
    }

    var events: [String] = []
    private var results: [Result]

    init(results: [Result]) {
        self.results = results
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
        events.append("live:\(remotePath)")
        guard !results.isEmpty else {
            return []
        }
        switch results.removeFirst() {
        case let .success(entries):
            return entries
        case let .failure(error):
            throw error
        }
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

private final class DelayedRemoteFilesPaneReadBridge: RemoteFilesBridging {
    private let entries: [RemoteFileEntry]
    private let remotePath: String
    private let data: Data
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(entries: [RemoteFileEntry], remotePath: String, data: Data) {
        self.entries = entries
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
        entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        entries
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
            throw MissingRemoteFilesPaneReadDataError(path: remotePath)
        }
        started.signal()
        _ = release.wait(timeout: .now() + 1)
        return data
    }
}

private struct MissingRemoteFilesPaneReadDataError: Error {
    let path: String
}

private final class MultiDelayedRemoteFilesPaneReadBridge: RemoteFilesBridging {
    private let entries: [RemoteFileEntry]
    private let dataByRemotePath: [String: Data]
    private var startedByRemotePath: [String: DispatchSemaphore] = [:]
    private var releaseByRemotePath: [String: DispatchSemaphore] = [:]
    private let lock = NSLock()

    init(entries: [RemoteFileEntry], dataByRemotePath: [String: Data]) {
        self.entries = entries
        self.dataByRemotePath = dataByRemotePath
        for remotePath in dataByRemotePath.keys {
            startedByRemotePath[remotePath] = DispatchSemaphore(value: 0)
            releaseByRemotePath[remotePath] = DispatchSemaphore(value: 0)
        }
    }

    func waitUntilReadStarted(remotePath: String, timeout: TimeInterval = 1) -> Bool {
        semaphore(in: startedByRemotePath, remotePath: remotePath)?.wait(timeout: .now() + timeout) == .success
    }

    func releaseRead(remotePath: String) {
        semaphore(in: releaseByRemotePath, remotePath: remotePath)?.signal()
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
        entries
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
        guard let data = dataByRemotePath[remotePath],
              let started = semaphore(in: startedByRemotePath, remotePath: remotePath),
              let release = semaphore(in: releaseByRemotePath, remotePath: remotePath)
        else {
            throw MissingRemoteFilesPaneReadDataError(path: remotePath)
        }
        started.signal()
        _ = release.wait(timeout: .now() + 1)
        return data
    }

    private func semaphore(in semaphores: [String: DispatchSemaphore], remotePath: String) -> DispatchSemaphore? {
        lock.lock()
        defer { lock.unlock() }
        return semaphores[remotePath]
    }
}

private func performControlBShortcut(on view: NSView) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .control,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "b",
        charactersIgnoringModifiers: "b",
        isARepeat: false,
        keyCode: 11
    ) else {
        return false
    }
    return view.performKeyEquivalent(with: event)
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

private extension NSViewController {
    func viewTextSnapshot() -> String {
        view.recursiveTextValues().joined(separator: "\n")
    }
}

private extension NSView {
    func recursiveTextValues() -> [String] {
        var values: [String] = []
        if let textField = self as? NSTextField {
            values.append(textField.stringValue)
        }
        for subview in subviews {
            values.append(contentsOf: subview.recursiveTextValues())
        }
        return values
    }
}
