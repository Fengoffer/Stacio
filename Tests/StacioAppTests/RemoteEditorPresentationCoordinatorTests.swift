import AppKit
import XCTest
@testable import StacioApp

private typealias CoordinatorAsyncSaveInstaller = (
    _ completion: @escaping (Result<Void, Error>) -> Void
) -> Void

@MainActor
final class RemoteEditorPresentationCoordinatorTests: XCTestCase {
    func testFirstRemoteOpenShowsProgressBeforeDocumentArrivesThenInstallsEditor() {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/nginx.conf")

        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )
        XCTAssertEqual(harness.coordinator.snapshot.mode, .opening)
        XCTAssertTrue(
            harness.host.editorContentViewController is RemoteFileOpenProgressViewController
        )

        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "server {}\n"),
            mode: .textEditor,
            saveHandler: nil
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(
            harness.host.editorContentViewController === harness.coordinator.currentEditor
        )
        XCTAssertEqual(harness.editorFactoryCallCount, 1)
    }

    func testClosingOpeningPlaceholderSuppressesLateSuccess() {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/slow.conf")
        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil, completion: nil),
            .ready
        )
        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "late\n"),
            mode: .textEditor,
            saveHandler: nil
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(harness.coordinator.currentEditor)
        XCTAssertNil(harness.host.editorContentViewController)
        XCTAssertEqual(harness.editorFactoryCallCount, 0)
    }

    func testOpeningSecondDocumentReusesEditorAndHiddenEditorExpands() {
        let harness = makeHarnessWithDockedEditor(path: "/etc/first.conf")
        let original = harness.coordinator.currentEditor
        harness.coordinator.collapseDockedEditor()
        XCTAssertEqual(harness.coordinator.snapshot.mode, .dockedHidden)

        let selection = makeSelection(path: "/etc/second.conf")
        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "port=22\n"),
            mode: .textEditor,
            saveHandler: nil
        )

        XCTAssertTrue(harness.coordinator.currentEditor === original)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertEqual(original?.tabTitlesForTesting, ["first.conf", "second.conf"])
        XCTAssertEqual(harness.editorFactoryCallCount, 1)
        XCTAssertEqual(harness.host.synchronizeLayoutCallCount, 1)
    }

    func testInitialRemoteFailureStaysInClosableOpeningPlaceholder() throws {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/broken.conf")
        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )
        let progress = try XCTUnwrap(
            harness.host.editorContentViewController as? RemoteFileOpenProgressViewController
        )

        harness.coordinator.remoteOpenDidFail(
            selection: selection,
            mode: .textEditor,
            message: "connection reset"
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .opening)
        XCTAssertTrue(progress.visibleTextSnapshotForTesting.contains("connection reset"))
        progress.onCloseRequested?()
        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(harness.host.editorContentViewController)
    }

    func testRemoteFailureAddsTabWhenEditorAlreadyExists() {
        let harness = makeHarnessWithDockedEditor(path: "/etc/first.conf")
        let editor = harness.coordinator.currentEditor
        let selection = makeSelection(path: "/etc/failed.conf")
        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )

        harness.coordinator.remoteOpenDidFail(
            selection: selection,
            mode: .textEditor,
            message: "permission denied"
        )

        XCTAssertTrue(harness.coordinator.currentEditor === editor)
        XCTAssertEqual(editor?.tabTitlesForTesting, ["first.conf", "failed.conf"])
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
    }

    func testDuplicatePrepareRequestIsRejectedWithoutReplacingProgress() {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/slow.conf")
        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )
        let progress = harness.host.editorContentViewController

        XCTAssertFalse(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )
        XCTAssertTrue(harness.host.editorContentViewController === progress)
        XCTAssertEqual(harness.progressFactoryCallCount, 1)
    }

    func testCancelledCloseKeepsDockedEditorAndDocumentsUntouched() {
        let harness = makeHarness(
            closeDecision: .cancel
        )
        openDocument(path: "/etc/app.conf", in: harness)
        let editor = harness.coordinator.currentEditor
        editor?.replaceTextForTesting("changed=true\n")
        var resolutions: [RemoteTextEditorCloseResolution] = []

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil) {
                resolutions.append($0)
            },
            .cancelled
        )

        XCTAssertEqual(resolutions, [.cancelled])
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertEqual(editor?.tabTitlesForTesting, ["app.conf"])
    }

    func testPendingCloseCoalescesCompletionsAndRemovesEditorOnce() {
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let harness = makeHarness(
            closeDecision: .save,
            asyncSaveInstaller: { completion in saveCompletion = completion }
        )
        openDocument(path: "/etc/app.conf", in: harness)
        let editor = harness.coordinator.currentEditor
        editor?.replaceTextForTesting("changed=true\n")
        var first: [RemoteTextEditorCloseResolution] = []
        var second: [RemoteTextEditorCloseResolution] = []

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil) { first.append($0) },
            .pending
        )
        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil) { second.append($0) },
            .pending
        )
        XCTAssertEqual(harness.closeConfirmer.promptedFileNames, ["app.conf"])

        saveCompletion?(.success(()))
        saveCompletion?(.success(()))

        XCTAssertEqual(first, [.ready])
        XCTAssertEqual(second, [.ready])
        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(harness.host.editorContentViewController)
        XCTAssertEqual(
            harness.host.removedControllers.filter { $0 === editor }.count,
            1
        )
    }

    func testPendingCloseRejectsNewOpenAndDropsOutstandingCompletion() throws {
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let harness = makeHarness(
            closeDecision: .save,
            asyncSaveInstaller: { completion in saveCompletion = completion }
        )
        openDocument(path: "/etc/first.conf", in: harness)
        let pendingSelection = makeSelection(path: "/etc/pending.conf")
        let pendingRequest = try XCTUnwrap(
            harness.coordinator.prepareRemoteOpen(
                selection: pendingSelection,
                mode: .textEditor
            )
        )
        harness.coordinator.currentEditor?.replaceTextForTesting("changed=true\n")

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil, completion: nil),
            .pending
        )
        XCTAssertNil(
            harness.coordinator.prepareRemoteOpen(
                selection: makeSelection(path: "/etc/rejected.conf"),
                mode: .textEditor
            )
        )

        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: pendingSelection.path, content: "pending=true\n"),
            mode: .textEditor,
            saveHandler: nil,
            request: pendingRequest
        )

        XCTAssertEqual(
            harness.coordinator.currentEditor?.tabTitlesForTesting,
            ["first.conf"]
        )
        saveCompletion?(.success(()))
        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
    }

    func testSuccessfulCloseInvalidatesOutstandingOpenRequests() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/first.conf")
        let pendingSelection = makeSelection(path: "/etc/pending.conf")
        let pendingRequest = try XCTUnwrap(
            harness.coordinator.prepareRemoteOpen(
                selection: pendingSelection,
                mode: .textEditor
            )
        )

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil, completion: nil),
            .ready
        )
        XCTAssertNotNil(
            harness.coordinator.prepareRemoteOpen(
                selection: pendingSelection,
                mode: .textEditor
            )
        )

        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: pendingSelection.path, content: "stale=true\n"),
            mode: .textEditor,
            saveHandler: nil,
            request: pendingRequest
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .opening)
        XCTAssertNil(harness.coordinator.currentEditor)
    }

    func testSynchronousAsyncSaveFinishesCloseWithoutStrandingPendingState() {
        let harness = makeHarness(
            closeDecision: .save,
            asyncSaveInstaller: { completion in completion(.success(())) }
        )
        openDocument(path: "/etc/app.conf", in: harness)
        harness.coordinator.currentEditor?.replaceTextForTesting("changed=true\n")
        var resolutions: [RemoteTextEditorCloseResolution] = []

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil) { resolutions.append($0) },
            .ready
        )
        XCTAssertEqual(resolutions, [.ready])
        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(harness.host.editorContentViewController)
    }

    func testCloseCancelsWhenDockHostDisappears() {
        var host: RecordingCoordinatorDockHost? = RecordingCoordinatorDockHost()
        let coordinator = RemoteEditorPresentationCoordinator(
            dockHost: host!,
            presentationStore: RecordingCoordinatorPresentationStore(),
            screenProvider: RecordingCoordinatorScreenProvider(),
            licenseAccess: RecordingCoordinatorLicenseAccess(),
            authorizer: AllowingCoordinatorAuthorizer(),
            closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .discard),
            fallbackOpener: RecordingCoordinatorFallbackOpener()
        )
        let selection = makeSelection(path: "/etc/app.conf")
        XCTAssertTrue(coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor))
        coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "enabled=true\n"),
            mode: .textEditor,
            saveHandler: nil
        )
        let editor = coordinator.currentEditor
        host = nil
        var resolutions: [RemoteTextEditorCloseResolution] = []

        XCTAssertEqual(
            coordinator.requestClose(parentWindow: nil) { resolutions.append($0) },
            .cancelled
        )
        XCTAssertEqual(resolutions, [.cancelled])
        XCTAssertEqual(coordinator.snapshot.mode, .docked)
        XCTAssertTrue(coordinator.currentEditor === editor)
    }

    func testInitialEditorInstallFailureRestoresSingleProgressChild() throws {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/app.conf")
        XCTAssertTrue(harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor))
        let progress = try XCTUnwrap(harness.host.editorContentViewController)
        harness.host.failNextInstall = true

        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "enabled=true\n"),
            mode: .textEditor,
            saveHandler: nil
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .opening)
        XCTAssertTrue(harness.host.editorContentViewController === progress)
        XCTAssertEqual(harness.host.hostedControllerCount, 1)
    }

    func testInitialEditorAndRollbackInstallFailureLeavesClosedEmptyHost() {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/app.conf")
        XCTAssertTrue(harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor))
        harness.host.failAllInstalls = true

        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "enabled=true\n"),
            mode: .textEditor,
            saveHandler: nil
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(harness.coordinator.currentEditor)
        XCTAssertEqual(harness.host.hostedControllerCount, 0)
    }

    func testCoordinatorOwnsEverySingleValueEditorCallback() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)

        XCTAssertNotNil(editor.onCloseRequested)
        XCTAssertNotNil(editor.onDirtyStateChanged)
        XCTAssertNotNil(editor.onActiveDocumentChanged)
        XCTAssertNotNil(editor.onPendingCloseResolved)
        XCTAssertNotNil(editor.onAIQuestionRequested)
        XCTAssertNotNil(editor.onBackupRequested)
        XCTAssertNotNil(editor.onRestoreRequested)
        XCTAssertNotNil(editor.onToggleCollapseRequested)
    }

    func testEditorToolbarCollapseAndCloseActionsDriveCoordinatorLifecycle() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        editor.loadView()
        let collapseButton = try XCTUnwrap(
            findEditorSubview(
                in: editor.view,
                identifier: "Stacio.Editor.Toolbar.collapse"
            ) as? NSButton
        )
        let closeButton = try XCTUnwrap(
            findEditorSubview(
                in: editor.view,
                identifier: "Stacio.Editor.Toolbar.close"
            ) as? NSButton
        )

        collapseButton.performClick(nil as Any?)

        XCTAssertEqual(harness.coordinator.snapshot.mode, .dockedHidden)
        XCTAssertTrue(harness.host.isEditorSidecarCollapsed)

        harness.coordinator.expandDockedEditor()
        closeButton.performClick(nil as Any?)

        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(harness.host.editorContentViewController)
    }

    func testEditorToolbarBackupAndRestoreActionsReachCoordinatorOutputs() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        var backupCount = 0
        var restoreCount = 0
        harness.coordinator.onBackupRequested = { backupCount += 1 }
        harness.coordinator.onRestoreRequested = { restoreCount += 1 }
        editor.loadView()

        let backupButton = try XCTUnwrap(
            findEditorSubview(
                in: editor.view,
                identifier: "Stacio.Editor.Toolbar.backup"
            ) as? NSButton
        )
        let restoreButton = try XCTUnwrap(
            findEditorSubview(
                in: editor.view,
                identifier: "Stacio.Editor.Toolbar.restore"
            ) as? NSButton
        )
        backupButton.performClick(nil as Any?)
        restoreButton.performClick(nil as Any?)

        XCTAssertEqual(backupCount, 1)
        XCTAssertEqual(restoreCount, 1)
    }

    func testReentrantExpandDuringCollapseIsIgnoredUntilTransitionCompletes() {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        harness.host.onCollapsedChanged = { [weak coordinator = harness.coordinator] collapsed in
            if collapsed {
                coordinator?.expandDockedEditor()
            }
        }

        harness.coordinator.collapseDockedEditor()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .dockedHidden)
        XCTAssertTrue(harness.host.isEditorSidecarCollapsed)
        XCTAssertFalse(harness.coordinator.snapshot.isTransitioning)
    }

    func testStaleSamePathCompletionCannotConsumeNewerRequestGeneration() {
        let harness = makeHarness()
        let selection = makeSelection(path: "/etc/reused.conf")
        let firstRequest = try? XCTUnwrap(
            harness.coordinator.prepareRemoteOpen(selection: selection, mode: .textEditor)
        )
        XCTAssertNotNil(firstRequest)
        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: nil, completion: nil),
            .ready
        )
        let secondRequest = try? XCTUnwrap(
            harness.coordinator.prepareRemoteOpen(selection: selection, mode: .textEditor)
        )
        XCTAssertNotNil(secondRequest)

        if let firstRequest {
            harness.coordinator.openRemoteDocument(
                makeDescriptor(path: selection.path, content: "stale=true\n"),
                mode: .textEditor,
                saveHandler: nil,
                request: firstRequest
            )
        }

        XCTAssertEqual(harness.coordinator.snapshot.mode, .opening)
        XCTAssertNil(harness.coordinator.currentEditor)

        if let secondRequest {
            harness.coordinator.openRemoteDocument(
                makeDescriptor(path: selection.path, content: "fresh=true\n"),
                mode: .textEditor,
                saveHandler: nil,
                request: secondRequest
            )
        }

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertEqual(harness.coordinator.currentEditor?.currentTextForTesting, "fresh=true\n")
    }

    func testPreparedLocalCopyReplacesOpeningPlaceholderAndConsumesRequest() throws {
        let harness = makeHarness()
        let selection = makeSelection(path: "/srv/app/config.yml")
        let request = try XCTUnwrap(
            harness.coordinator.prepareRemoteOpen(selection: selection, mode: .textEditor)
        )
        let progress = try XCTUnwrap(harness.host.editorContentViewController)
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-coordinator-\(UUID().uuidString).yml")
        try "enabled: true\n".write(to: localURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localURL) }

        harness.coordinator.openLocalCopy(
            at: localURL,
            mode: .textEditor,
            applicationURL: nil,
            saveHandler: nil,
            request: request
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertNotNil(harness.coordinator.currentEditor)
        XCTAssertFalse(harness.host.editorContentViewController === progress)
        XCTAssertTrue(harness.host.editorContentViewController === harness.coordinator.currentEditor)
        XCTAssertNil(harness.fallback.lastLocalCopyURL)
        XCTAssertNotNil(
            harness.coordinator.prepareRemoteOpen(selection: selection, mode: .textEditor),
            "Consuming the local-copy completion must unblock the next generation"
        )
    }

    func testCloseRequestedFromTransitionSnapshotCannotCorruptDockHostState() {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        let editor = harness.coordinator.currentEditor
        var closeDisposition: RemoteTextEditorCloseDisposition?
        harness.coordinator.onSnapshotChanged = { [weak coordinator = harness.coordinator] snapshot in
            guard snapshot.isTransitioning, closeDisposition == nil else { return }
            closeDisposition = coordinator?.requestClose(parentWindow: nil, completion: nil)
        }

        harness.coordinator.collapseDockedEditor()

        XCTAssertEqual(closeDisposition, .cancelled)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .dockedHidden)
        XCTAssertTrue(harness.coordinator.currentEditor === editor)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertTrue(harness.host.isEditorSidecarCollapsed)
    }

    func testWindowPresentationDoesNotReplaceCoordinatorOwnedEditorCallbacks() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        var snapshotPublicationCount = 0
        harness.coordinator.onSnapshotChanged = { _ in snapshotPublicationCount += 1 }
        let windowController = RemoteTextEditorWindowController(editorViewController: editor)
        defer { windowController.close() }

        editor.replaceTextForTesting("enabled=false\n")

        XCTAssertGreaterThan(snapshotPublicationCount, 0)
        XCTAssertEqual(windowController.window?.isDocumentEdited, true)
    }

    func testDetachAndRedockMoveTheSameEditorAndWebViewWithoutReloading() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        editor.loadView()
        editor.markEditorReadyForTesting()
        let webView = try XCTUnwrap(editor.editorWebViewForTesting)
        let pageLoads = editor.monacoPageLoadCountForTesting

        try harness.coordinator.detachEditor()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertTrue(harness.coordinator.currentEditor === editor)
        XCTAssertTrue(editor.editorWebViewForTesting === webView)
        XCTAssertTrue(harness.windowFactory.lastWindow?.installedEditorViewController === editor)

        let detachedWindow = try XCTUnwrap(harness.windowFactory.lastWindow)
        try harness.coordinator.redockEditor()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertTrue(editor.editorWebViewForTesting === webView)
        XCTAssertEqual(editor.monacoPageLoadCountForTesting, pageLoads)
        XCTAssertFalse(detachedWindow.window?.isVisible ?? true)
        XCTAssertNil(detachedWindow.presentationDelegate)
    }

    func testOneHundredDetachRedockCyclesPreserveEditorRuntimeAndWindowOwnership() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        defer { harness.windowFactory.closeAll() }
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        editor.loadView()
        editor.markEditorReadyForTesting()
        let webView = try XCTUnwrap(editor.editorWebViewForTesting)
        let pageLoadCount = editor.monacoPageLoadCountForTesting
        // The generated HTML embeds the page-load generation without exposing mutable runtime state.
        let pageGenerationHTML = editor.editorHTMLForTesting

        for cycle in 0..<100 {
            try harness.coordinator.detachEditor()

            XCTAssertEqual(harness.coordinator.snapshot.mode, .floating, "cycle \(cycle)")
            XCTAssertTrue(harness.coordinator.currentEditor === editor, "cycle \(cycle)")
            XCTAssertTrue(editor.editorWebViewForTesting === webView, "cycle \(cycle)")
            XCTAssertEqual(editor.monacoPageLoadCountForTesting, pageLoadCount, "cycle \(cycle)")
            XCTAssertEqual(editor.editorHTMLForTesting, pageGenerationHTML, "cycle \(cycle)")
            XCTAssertEqual(harness.windowFactory.visibleWindowCount, 1, "cycle \(cycle)")

            let detachedWindow = try XCTUnwrap(harness.windowFactory.lastWindow)
            XCTAssertTrue(detachedWindow.installedEditorViewController === editor, "cycle \(cycle)")
            XCTAssertNotNil(detachedWindow.presentationDelegate, "cycle \(cycle)")

            try harness.coordinator.redockEditor()

            XCTAssertEqual(harness.coordinator.snapshot.mode, .docked, "cycle \(cycle)")
            XCTAssertTrue(harness.coordinator.currentEditor === editor, "cycle \(cycle)")
            XCTAssertTrue(harness.host.editorContentViewController === editor, "cycle \(cycle)")
            XCTAssertEqual(harness.host.hostedControllerCount, 1, "cycle \(cycle)")
            XCTAssertTrue(editor.editorWebViewForTesting === webView, "cycle \(cycle)")
            XCTAssertEqual(editor.monacoPageLoadCountForTesting, pageLoadCount, "cycle \(cycle)")
            XCTAssertEqual(editor.editorHTMLForTesting, pageGenerationHTML, "cycle \(cycle)")
            XCTAssertEqual(harness.windowFactory.visibleWindowCount, 0, "cycle \(cycle)")
            XCTAssertFalse(detachedWindow.window?.isVisible ?? true, "cycle \(cycle)")
            XCTAssertNil(detachedWindow.installedEditorViewController, "cycle \(cycle)")
            XCTAssertNil(detachedWindow.presentationDelegate, "cycle \(cycle)")
        }
    }

    func testDetachInstallFailureRollsBackToDockAndPreservesWidth() throws {
        let harness = makeHarness(windowInstallFails: true)
        openDocument(path: "/etc/app.conf", in: harness)
        let editor = harness.coordinator.currentEditor
        let collapsed = harness.host.isEditorSidecarCollapsed

        XCTAssertThrowsError(try harness.coordinator.detachEditor())

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertEqual(harness.host.isEditorSidecarCollapsed, collapsed)
        XCTAssertEqual(harness.host.hostedControllerCount, 1)
        XCTAssertEqual(harness.windowFactory.visibleWindowCount, 0)
    }

    func testDetachDualFailureUsesFreshRecoveryWindowWithoutClaimingEmptyShell() throws {
        let harness = makeHarness()
        openDocument(path: "/etc/app.conf", in: harness)
        defer { harness.windowFactory.closeAll() }
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        harness.host.failAllInstalls = true
        harness.host.onRemoveAttempt = {
            harness.windowFactory.lastWindow?.window?.contentViewController = NSViewController()
        }

        XCTAssertThrowsError(try harness.coordinator.detachEditor()) { error in
            XCTAssertEqual(error as? RemoteEditorPresentationError, .rollbackFailed)
        }

        XCTAssertEqual(harness.windowFactory.createdWindows.count, 2)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertTrue(harness.coordinator.currentEditor === editor)
        XCTAssertEqual(harness.host.hostedControllerCount, 0)
        XCTAssertEqual(harness.windowFactory.visibleWindowCount, 1)
        XCTAssertNil(harness.windowFactory.createdWindows[0].installedEditorViewController)
        XCTAssertTrue(harness.windowFactory.createdWindows[1].installedEditorViewController === editor)
    }

    func testDetachRecoveryWindowFailureRetainsEditorWithoutClaimingPresentation() throws {
        let harness = makeHarness()
        openDocument(path: "/etc/app.conf", in: harness)
        defer { harness.windowFactory.closeAll() }
        let editor = try XCTUnwrap(harness.coordinator.currentEditor)
        harness.host.failAllInstalls = true
        harness.host.onRemoveAttempt = {
            harness.windowFactory.lastWindow?.window?.contentViewController = NSViewController()
        }
        harness.windowFactory.onWindowCreated = { controller, creationIndex in
            if creationIndex == 2 {
                controller.window?.contentViewController = NSViewController()
            }
        }

        XCTAssertThrowsError(try harness.coordinator.detachEditor()) { error in
            XCTAssertEqual(error as? RemoteEditorPresentationError, .rollbackFailed)
        }

        XCTAssertEqual(harness.coordinator.snapshot.mode, .recovery)
        XCTAssertTrue(harness.coordinator.snapshot.hasEditor)
        XCTAssertTrue(harness.coordinator.currentEditor === editor)
        XCTAssertEqual(harness.host.hostedControllerCount, 0)
        XCTAssertEqual(harness.windowFactory.visibleWindowCount, 0)
        XCTAssertTrue(harness.windowFactory.createdWindows.allSatisfy {
            $0.installedEditorViewController == nil && $0.window?.contentViewController == nil
        })

        harness.host.failAllInstalls = false
        try harness.coordinator.redockEditor()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
    }

    func testWindowFactoryFailureLeavesDockUntouchedAndSurfacesStableError() throws {
        let harness = makeHarness(windowCreationFails: true)
        openDocument(path: "/etc/app.conf", in: harness)
        let editor = harness.coordinator.currentEditor
        let removalCount = harness.host.removedControllers.count

        XCTAssertThrowsError(try harness.coordinator.detachEditor()) { error in
            XCTAssertEqual(error as? RemoteEditorPresentationError, .windowCreationFailed)
        }

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertEqual(harness.host.removedControllers.count, removalCount)
        XCTAssertEqual(harness.windowFactory.createdWindows.count, 0)
    }

    func testRedockInstallFailureKeepsEditorInOriginalWindow() throws {
        let harness = try makeHarnessWithFloatingEditor(path: "/etc/app.conf")
        defer { harness.windowFactory.closeAll() }
        harness.host.failNextInstall = true
        let editor = harness.coordinator.currentEditor
        let window = try XCTUnwrap(harness.windowFactory.lastWindow)
        let frame = try XCTUnwrap(window.window?.frame)

        XCTAssertThrowsError(try harness.coordinator.redockEditor())

        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertTrue(window.editorViewController === editor)
        XCTAssertTrue(window.window?.isVisible == true)
        XCTAssertEqual(window.window?.frame, frame)
        XCTAssertEqual(harness.host.hostedControllerCount, 0)
        XCTAssertNotNil(window.presentationDelegate)
    }

    func testRedockPreparesWorkbenchWithStoredTargetWidthBeforeHostInstall() throws {
        let harness = try makeHarnessWithFloatingEditor(path: "/etc/app.conf")
        harness.store.storedSidecarTargetWidth = 812
        var preparedWidth: CGFloat?
        harness.coordinator.onWillPresentDockedEditor = { preparedWidth = $0 }
        harness.host.onInstallAttempt = {
            XCTAssertEqual(preparedWidth, 812)
        }

        try harness.coordinator.redockEditor()

        XCTAssertEqual(preparedWidth, 812)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
    }

    func testAdvancedAuthorizationRunsBeforeAnyPresentationMutation() throws {
        let harness = makeHarness()
        openDocument(path: "/etc/app.conf", in: harness)
        let editor = harness.coordinator.currentEditor
        let baselineRemovedControllers = harness.host.removedControllers.count
        harness.authorizer.error = LicensedFeatureAccessError.licenseRequired(.detachedFileEditor)
        harness.authorizer.onAuthorize = { [weak harness] in
            guard let harness else { return }
            XCTAssertTrue(harness.host.editorContentViewController === editor)
            XCTAssertEqual(harness.host.removedControllers.count, baselineRemovedControllers)
            XCTAssertEqual(harness.windowFactory.createdWindows.count, 0)
            XCTAssertFalse(harness.coordinator.snapshot.isTransitioning)
        }

        XCTAssertThrowsError(try harness.coordinator.detachEditor())

        XCTAssertEqual(harness.authorizer.authorizedFeatures, [.detachedFileEditor])
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertEqual(harness.windowFactory.createdWindows.count, 0)
    }

    func testRedockRemainsAvailableAfterAdvancedAuthorizationIsLost() throws {
        let harness = try makeHarnessWithFloatingEditor(path: "/etc/app.conf")
        harness.authorizer.error = LicensedFeatureAccessError.licenseRequired(.detachedFileEditor)
        let authorizationCount = harness.authorizer.authorizedFeatures.count

        try harness.coordinator.redockEditor()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertEqual(harness.authorizer.authorizedFeatures.count, authorizationCount)
    }

    func testPresentationMenuRefreshesScreensEveryTimeAndMatchesCurrentState() {
        let builtIn = makeScreen(id: 1, name: "Built-in")
        let harness = makeHarness(screens: [builtIn])
        openDocument(path: "/etc/app.conf", in: harness)

        XCTAssertEqual(
            harness.coordinator.presentationMenuItems().map(\.title),
            [L10n.EditorPresentation.detach, "Built-in"]
        )

        harness.screenProvider.screens.append(makeScreen(id: 2, name: "Studio Display"))
        XCTAssertEqual(
            harness.coordinator.presentationMenuItems().map(\.title),
            [L10n.EditorPresentation.detach, "Built-in", "Studio Display"]
        )
        XCTAssertEqual(harness.screenProvider.availableScreensCallCount, 2)
    }

    func testDisplayMenuOnlyListsAvailableScreensWithoutDetachOrRedockActions() throws {
        let builtIn = makeScreen(id: 1, name: "Built-in")
        let studio = makeScreen(id: 2, name: "Studio Display")
        let harness = makeHarness(screens: [builtIn, studio])
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)

        XCTAssertEqual(
            harness.coordinator.displayMenuItems(),
            [
                .init(title: "Built-in", action: .display(builtIn.identity)),
                .init(title: "Studio Display", action: .display(studio.identity)),
            ]
        )

        try harness.coordinator.detachEditor()

        XCTAssertEqual(
            harness.coordinator.displayMenuItems().map(\.action),
            [.display(builtIn.identity), .display(studio.identity)]
        )
    }

    func testPresentationMenuUsesStableLabelsForDuplicateScreenNames() {
        let left = makeScreen(
            id: 9,
            name: "Studio Display",
            frame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        )
        let right = makeScreen(
            id: 3,
            name: "Studio Display",
            frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )
        let harness = makeHarness(screens: [right, left])
        openDocument(path: "/etc/app.conf", in: harness)

        XCTAssertEqual(
            harness.coordinator.presentationMenuItems().map(\.title),
            [
                L10n.EditorPresentation.detach,
                L10n.EditorPresentation.display("Studio Display", ordinal: 2),
                L10n.EditorPresentation.display("Studio Display", ordinal: 1),
            ]
        )
    }

    func testDetachedPresentationMenuStartsWithFreeRedockAction() throws {
        let screen = makeScreen(id: 1, name: "Built-in")
        let harness = makeHarness(screens: [screen])
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)
        try harness.coordinator.detachEditor()
        harness.licenseAccess.enabledFeatures = []

        XCTAssertEqual(
            harness.coordinator.presentationMenuItems(),
            [
                .init(title: L10n.EditorPresentation.redock, action: .redock),
                .init(title: "Built-in", action: .display(screen.identity)),
            ]
        )
    }

    func testEveryAdvancedEntryUsesTheSameAuthorizerBeforeMutation() {
        for entry in RemoteEditorAdvancedEntry.allCases {
            let harness = makeHarness()
            openDocument(path: "/etc/app.conf", in: harness)
            harness.licenseAccess.enabledFeatures = []
            harness.authorizer.error = LicensedFeatureAccessError.licenseRequired(.detachedFileEditor)
            let editor = harness.coordinator.currentEditor
            let parent = editor?.view.superview

            harness.invokeAdvancedEntry(entry)

            XCTAssertEqual(
                harness.authorizer.authorizedFeatures,
                [.detachedFileEditor],
                "entry=\(entry)"
            )
            XCTAssertEqual(harness.windowFactory.createdWindows.count, 0, "entry=\(entry)")
            XCTAssertTrue(editor?.view.superview === parent, "entry=\(entry)")
            XCTAssertEqual(harness.coordinator.snapshot.mode, .docked, "entry=\(entry)")
            XCTAssertEqual(harness.upgradePresenter.presentationCount, 1, "entry=\(entry)")
        }
    }

    func testLicenseLossDoesNotInterruptDetachedWindowButBlocksNewPlacement() throws {
        let first = makeScreen(id: 1, name: "Built-in")
        let second = makeScreen(id: 2, name: "Studio Display")
        let harness = makeHarness(screens: [first, second])
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)
        try harness.coordinator.detachEditor()
        let window = harness.windowFactory.lastWindow

        harness.licenseAccess.enabledFeatures = []
        harness.coordinator.refreshLicenseState()

        XCTAssertTrue(window?.window?.isVisible == true)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        harness.coordinator.performPresentationMenuAction(.display(second.identity))
        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertEqual(harness.upgradePresenter.presentationCount, 1)
        XCTAssertNoThrow(try harness.coordinator.redockEditor())
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
    }

    func testLicenseNotificationRefreshesDockedToolbarWithoutPresentationMutation() {
        let harness = makeHarness()
        openDocument(path: "/etc/app.conf", in: harness)
        let editor = harness.coordinator.currentEditor
        editor?.loadView()
        let parent = editor?.view.superview

        harness.licenseAccess.enabledFeatures = []
        harness.notificationCenter.post(name: .stacioLicenseAuthorizationDidChange, object: nil)

        XCTAssertEqual(editor?.presentationMainImageNameForTesting, "lock")
        XCTAssertEqual(
            editor?.presentationMainTooltipForTesting,
            L10n.EditorPresentation.detachRequiresLicense
        )
        XCTAssertTrue(editor?.view.superview === parent)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
    }

    func testDisplayMaximizedRedockReturnsSameEditorWithoutAuthorization() throws {
        let screen = makeScreen(id: 1, name: "Built-in Display")
        let harness = try makeHarnessWithDisplayMaximizedEditor(screen: screen)
        let editor = harness.coordinator.currentEditor
        let authorizationCount = harness.authorizer.authorizedFeatures.count

        try harness.coordinator.redockEditor()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
        XCTAssertTrue(harness.host.editorContentViewController === editor)
        XCTAssertEqual(harness.authorizer.authorizedFeatures.count, authorizationCount)
        XCTAssertEqual(harness.windowFactory.visibleWindowCount, 0)
    }

    func testOpeningAnotherDocumentWhileFloatingReusesEditorAndWindow() throws {
        let harness = try makeHarnessWithFloatingEditor(path: "/etc/first.conf")
        defer { harness.windowFactory.closeAll() }
        let editor = harness.coordinator.currentEditor
        let window = harness.windowFactory.lastWindow
        let selection = makeSelection(path: "/etc/second.conf")
        let request = try XCTUnwrap(
            harness.coordinator.prepareRemoteOpen(selection: selection, mode: .textEditor)
        )

        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: selection.path, content: "port=22\n"),
            mode: .textEditor,
            saveHandler: nil,
            request: request
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertTrue(harness.coordinator.currentEditor === editor)
        XCTAssertTrue(harness.windowFactory.lastWindow === window)
        XCTAssertEqual(editor?.tabTitlesForTesting, ["first.conf", "second.conf"])
    }

    func testDetachCommandReentryDuringTransitionIsRejectedWithoutMovingTwice() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        var reentrantError: Error?
        harness.coordinator.onSnapshotChanged = { snapshot in
            guard snapshot.isTransitioning, reentrantError == nil else { return }
            do {
                try harness.coordinator.detachEditor()
            } catch {
                reentrantError = error
            }
        }

        try harness.coordinator.detachEditor()

        XCTAssertEqual(
            reentrantError as? RemoteEditorPresentationError,
            .transitionInProgress
        )
        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertEqual(harness.windowFactory.createdWindows.count, 1)
    }

    func testWindowFactoryReentryIsRejectedInsideReservedTransition() throws {
        let harness = makeHarnessWithDockedEditor(path: "/etc/app.conf")
        var reentrantError: Error?
        harness.windowFactory.onMakeWindow = {
            do {
                try harness.coordinator.detachEditor()
            } catch {
                reentrantError = error
            }
        }

        try harness.coordinator.detachEditor()

        XCTAssertEqual(
            reentrantError as? RemoteEditorPresentationError,
            .transitionInProgress
        )
        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertEqual(harness.windowFactory.createdWindows.count, 1)
    }

    func testNativeDetachedWindowDragStartsWithPrimaryMouseDownInDestinationWindow() throws {
        let windowController = RemoteTextEditorWindowController()
        defer { windowController.closeShellForRedock() }
        let window = try XCTUnwrap(windowController.window)
        let sourceEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 40, y: 20),
            modifierFlags: [.shift],
            timestamp: 12,
            windowNumber: 0,
            context: nil,
            eventNumber: 42,
            clickCount: 1,
            pressure: 1
        ))
        let pointer = NSPoint(x: 520, y: 360)

        let dragStartEvent = try XCTUnwrap(
            RemoteEditorPresentationCoordinator.makeWindowDragStartEvent(
                sourceEvent: sourceEvent,
                window: window,
                pointer: pointer
            )
        )

        XCTAssertEqual(dragStartEvent.type, .leftMouseDown)
        XCTAssertEqual(dragStartEvent.buttonNumber, 0)
        XCTAssertEqual(dragStartEvent.windowNumber, window.windowNumber)
        XCTAssertEqual(dragStartEvent.locationInWindow, window.convertPoint(fromScreen: pointer))
        XCTAssertTrue(dragStartEvent.modifierFlags.contains(.shift))
    }

    func testOrdinaryDetachCentersDefaultSizeInsideWorkbenchVisibleFrame() throws {
        let screen = makeScreen(
            id: 1,
            name: "Built-in Display",
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 0, y: 24, width: 1_440, height: 876)
        )
        let harness = makeHarness(screens: [screen], workbenchScreen: screen)
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)

        try harness.coordinator.detachEditor()

        let frameSize = RemoteTextEditorWindowController.initialFrameSize
        let expectedFrame = NSRect(
            x: screen.visibleFrame.midX - (frameSize.width / 2),
            y: screen.visibleFrame.midY - (frameSize.height / 2),
            width: frameSize.width,
            height: frameSize.height
        )
        XCTAssertEqual(
            harness.windowFactory.lastWindow?.window?.frame,
            expectedFrame
        )
        XCTAssertEqual(harness.store.storedFloatingFrame, expectedFrame)
        XCTAssertEqual(harness.store.storedScreenIdentity, screen.identity)
    }

    func testOrdinaryDetachClampsToMinimumContentSizeUsingWindowFrameChrome() throws {
        let screen = makeScreen(id: 1, name: "Built-in Display")
        let harness = makeHarness(
            screens: [screen],
            workbenchScreen: screen,
            storedFloatingFrame: NSRect(x: 100, y: 100, width: 100, height: 100)
        )
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)

        try harness.coordinator.detachEditor()

        let window = try XCTUnwrap(harness.windowFactory.lastWindow?.window)
        XCTAssertEqual(window.frame.size, RemoteTextEditorWindowController.minimumFrameSize)
        XCTAssertEqual(window.contentLayoutRect.size, RemoteTextEditorWindowController.minimumContentSize)
    }

    func testOrdinaryDetachClampsPartiallyOffscreenSavedFrameToNegativeDisplay() throws {
        let screen = makeScreen(
            id: 7,
            name: "Left Display",
            frame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: -1_920, y: 24, width: 1_920, height: 1_056)
        )
        let savedFrame = NSRect(x: -2_200, y: 900, width: 980, height: 720)
        let harness = makeHarness(
            screens: [screen],
            workbenchScreen: screen,
            storedFloatingFrame: savedFrame,
            storedScreenIdentity: screen.identity
        )
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)

        try harness.coordinator.detachEditor()

        XCTAssertEqual(
            harness.windowFactory.lastWindow?.window?.frame,
            NSRect(x: -1_920, y: 360, width: 980, height: 720)
        )
    }

    func testTargetDisplayUsesFreshVisibleFrameWithoutNativeFullscreen() throws {
        let target = makeScreen(
            id: 22,
            name: "Studio Display",
            frame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
            visibleFrame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_415)
        )
        let harness = makeHarness(screens: [target], workbenchScreen: target)
        defer { harness.windowFactory.closeAll() }
        openDocument(path: "/etc/app.conf", in: harness)
        harness.screenProvider.onAvailableScreens = {
            XCTAssertEqual(harness.windowFactory.createdWindows.count, 0)
        }

        try harness.coordinator.presentEditor(on: target.identity)

        XCTAssertEqual(harness.coordinator.snapshot.mode, .displayMaximized)
        XCTAssertEqual(harness.windowFactory.lastWindow?.window?.frame, target.visibleFrame)
        XCTAssertEqual(harness.windowFactory.lastWindow?.nativeFullscreenToggleCountForTesting, 0)
        XCTAssertFalse(harness.windowFactory.lastWindow?.window?.styleMask.contains(.fullScreen) ?? true)
        XCTAssertEqual(harness.store.storedScreenIdentity, target.identity)
        XCTAssertEqual(harness.screenProvider.availableScreensCallCount, 1)
    }

    func testFloatingToDisplayMaximizedReusesWindowAndPreservesNormalRestoreFrame() throws {
        let first = makeScreen(id: 1, name: "Built-in Display")
        let target = makeScreen(
            id: 22,
            name: "Studio Display",
            frame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
            visibleFrame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_415)
        )
        let harness = try makeHarnessWithFloatingEditor(
            path: "/etc/app.conf",
            screens: [first, target],
            workbenchScreen: first
        )
        defer { harness.windowFactory.closeAll() }
        let window = try XCTUnwrap(harness.windowFactory.lastWindow)
        let normalFrame = try XCTUnwrap(window.window?.frame)
        let editor = harness.coordinator.currentEditor

        try harness.coordinator.presentEditor(on: target.identity)
        try harness.coordinator.presentEditor(on: target.identity)

        XCTAssertEqual(harness.coordinator.snapshot.mode, .displayMaximized)
        XCTAssertEqual(harness.windowFactory.createdWindows.count, 1)
        XCTAssertTrue(window.editorViewController === editor)
        XCTAssertEqual(window.window?.frame, target.visibleFrame)
        XCTAssertEqual(harness.store.storedFloatingFrame, normalFrame)
        XCTAssertEqual(harness.authorizer.authorizedFeatures.count, 3)
    }

    func testMovingDisplayMaximizedWindowDowngradesToFloatingAndSavesFrame() throws {
        let target = makeScreen(
            id: 22,
            name: "Studio Display",
            frame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_440),
            visibleFrame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_415)
        )
        let harness = try makeHarnessWithDisplayMaximizedEditor(screen: target)
        defer { harness.windowFactory.closeAll() }
        let moved = NSRect(x: 1_600, y: 120, width: 1_100, height: 760)

        harness.windowFactory.lastWindow?.simulateUserFrameChangeForTesting(moved)

        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
        XCTAssertEqual(harness.store.storedFloatingFrame, moved)
        XCTAssertEqual(harness.windowFactory.lastWindow?.window?.frame, moved)
    }

    func testDisconnectedTargetDisplayFallsBackToWorkbenchVisibleFrame() throws {
        let target = makeScreen(
            id: 22,
            name: "Projector",
            frame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_056)
        )
        let fallback = makeScreen(
            id: 1,
            name: "Built-in Display",
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 0, y: 24, width: 1_440, height: 876)
        )
        let harness = try makeHarnessWithDisplayMaximizedEditor(
            screen: target,
            screens: [target, fallback],
            workbenchScreen: fallback
        )
        defer { harness.windowFactory.closeAll() }

        harness.screenProvider.screens = [fallback]
        harness.coordinator.availableScreensDidChange()

        XCTAssertEqual(harness.windowFactory.lastWindow?.window?.frame, fallback.visibleFrame)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .displayMaximized)
        XCTAssertEqual(harness.store.storedScreenIdentity, fallback.identity)
    }

    func testScreenParameterNotificationUsesFreshDescriptorsForRecovery() throws {
        let target = makeScreen(
            id: 22,
            name: "Projector",
            frame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_056)
        )
        let fallback = makeScreen(id: 1, name: "Built-in Display")
        let harness = try makeHarnessWithDisplayMaximizedEditor(
            screen: target,
            screens: [target, fallback],
            workbenchScreen: fallback
        )
        defer { harness.windowFactory.closeAll() }
        harness.screenProvider.screens = [fallback]
        let baselineCalls = harness.screenProvider.availableScreensCallCount

        harness.notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        XCTAssertEqual(harness.screenProvider.availableScreensCallCount, baselineCalls + 1)
        XCTAssertEqual(harness.windowFactory.lastWindow?.window?.frame, fallback.visibleFrame)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .displayMaximized)
    }

    func testDisconnectedFloatingDisplayClampsSavedWindowIntoWorkbenchVisibleFrame() throws {
        let disconnected = makeScreen(
            id: 22,
            name: "Projector",
            frame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 1_440, y: 0, width: 1_920, height: 1_056)
        )
        let fallback = makeScreen(id: 1, name: "Built-in Display")
        let harness = try makeHarnessWithFloatingEditor(
            path: "/etc/app.conf",
            screens: [disconnected, fallback],
            workbenchScreen: fallback,
            storedFloatingFrame: NSRect(x: 1_700, y: 100, width: 980, height: 720),
            storedScreenIdentity: disconnected.identity
        )
        defer { harness.windowFactory.closeAll() }

        harness.screenProvider.screens = [fallback]
        harness.coordinator.availableScreensDidChange()

        let frame = try XCTUnwrap(harness.windowFactory.lastWindow?.window?.frame)
        XCTAssertTrue(fallback.visibleFrame.contains(frame))
        XCTAssertEqual(harness.store.storedFloatingFrame, frame)
        XCTAssertEqual(harness.coordinator.snapshot.mode, .floating)
    }

    func testNativeFullscreenRoundTripKeepsUnderlyingPresentationMode() throws {
        let screen = makeScreen(id: 1, name: "Built-in Display")
        let harness = try makeHarnessWithDisplayMaximizedEditor(screen: screen)
        defer { harness.windowFactory.closeAll() }
        let window = try XCTUnwrap(harness.windowFactory.lastWindow)

        window.simulateWillEnterFullScreenForTesting()
        window.simulateUserFrameChangeForTesting(NSRect(x: 40, y: 40, width: 900, height: 700))
        window.simulateDidExitFullScreenForTesting()

        XCTAssertEqual(harness.coordinator.snapshot.mode, .displayMaximized)
        XCTAssertEqual(window.window?.frame, screen.visibleFrame)
    }

    func testClosingDetachedEditorClosesShellAndClearsDelegate() throws {
        let harness = try makeHarnessWithFloatingEditor(path: "/etc/app.conf")
        let window = try XCTUnwrap(harness.windowFactory.lastWindow)

        XCTAssertEqual(
            harness.coordinator.requestClose(parentWindow: window.window, completion: nil),
            .ready
        )

        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
        XCTAssertNil(window.installedEditorViewController)
        XCTAssertFalse(window.window?.isVisible ?? true)
        XCTAssertNil(window.presentationDelegate)
    }

    func testUnsupportedOpenModesStayOnInjectedFallbackBoundary() {
        let harness = makeHarness()
        let selection = makeSelection(path: "/tmp/report.txt")

        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(
                selection: selection,
                mode: .defaultApplication
            )
        )
        harness.coordinator.remoteOpenDidFail(
            selection: selection,
            mode: .defaultApplication,
            message: "failed"
        )

        XCTAssertEqual(harness.fallback.prepareRequests, [selection.path])
        XCTAssertEqual(harness.fallback.failureRequests, [selection.path])
        XCTAssertEqual(harness.coordinator.snapshot.mode, .closed)
    }

    private func makeHarnessWithDockedEditor(path: String) -> CoordinatorHarness {
        let harness = makeHarness()
        openDocument(path: path, in: harness)
        return harness
    }

    private func makeHarnessWithFloatingEditor(
        path: String,
        screens: [RemoteEditorScreenDescriptor]? = nil,
        workbenchScreen: RemoteEditorScreenDescriptor? = nil,
        storedFloatingFrame: NSRect? = nil,
        storedScreenIdentity: RemoteEditorScreenIdentity? = nil
    ) throws -> CoordinatorHarness {
        let harness = makeHarness(
            screens: screens,
            workbenchScreen: workbenchScreen,
            storedFloatingFrame: storedFloatingFrame,
            storedScreenIdentity: storedScreenIdentity
        )
        openDocument(path: path, in: harness)
        try harness.coordinator.detachEditor()
        return harness
    }

    private func makeHarnessWithDisplayMaximizedEditor(
        screen: RemoteEditorScreenDescriptor,
        screens: [RemoteEditorScreenDescriptor]? = nil,
        workbenchScreen: RemoteEditorScreenDescriptor? = nil
    ) throws -> CoordinatorHarness {
        let harness = makeHarness(
            screens: screens ?? [screen],
            workbenchScreen: workbenchScreen ?? screen
        )
        openDocument(path: "/etc/app.conf", in: harness)
        try harness.coordinator.presentEditor(on: screen.identity)
        return harness
    }

    private func openDocument(path: String, in harness: CoordinatorHarness) {
        let selection = makeSelection(path: path)
        XCTAssertTrue(
            harness.coordinator.prepareToOpenRemote(selection: selection, mode: .textEditor)
        )
        harness.coordinator.openRemoteDocument(
            makeDescriptor(path: path, content: "enabled=true\n"),
            mode: .textEditor,
            saveHandler: nil
        )
        XCTAssertEqual(harness.coordinator.snapshot.mode, .docked)
    }

    private func makeHarness(
        closeDecision: RemoteTextEditorCloseDecision = .discard,
        asyncSaveInstaller: CoordinatorAsyncSaveInstaller? = nil,
        screens: [RemoteEditorScreenDescriptor]? = nil,
        workbenchScreen: RemoteEditorScreenDescriptor? = nil,
        storedFloatingFrame: NSRect? = nil,
        storedScreenIdentity: RemoteEditorScreenIdentity? = nil,
        windowInstallFails: Bool = false,
        windowCreationFails: Bool = false
    ) -> CoordinatorHarness {
        CoordinatorHarness(
            closeDecision: closeDecision,
            asyncSaveInstaller: asyncSaveInstaller,
            screens: screens,
            workbenchScreen: workbenchScreen,
            storedFloatingFrame: storedFloatingFrame,
            storedScreenIdentity: storedScreenIdentity,
            windowInstallFails: windowInstallFails,
            windowCreationFails: windowCreationFails
        )
    }

    private func makeSelection(path: String) -> RemoteFileSelection {
        RemoteFileSelection(path: path, size: 128)
    }

    private func makeDescriptor(path: String, content: String) -> RemoteTextEditorDocumentDescriptor {
        RemoteTextEditorDocumentDescriptor(
            remotePath: path,
            fileName: (path as NSString).lastPathComponent,
            content: content
        )
    }

    private func makeScreen(
        id: UInt32,
        name: String,
        frame: NSRect = NSRect(x: 0, y: 0, width: 1_440, height: 900),
        visibleFrame: NSRect = NSRect(x: 0, y: 24, width: 1_440, height: 876)
    ) -> RemoteEditorScreenDescriptor {
        RemoteEditorScreenDescriptor(
            identity: .init(displayID: id, localizedName: name, frame: frame),
            frame: frame,
            visibleFrame: visibleFrame
        )
    }
}

@MainActor
private func findEditorSubview(in view: NSView, identifier: String) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    for subview in view.subviews {
        if let match = findEditorSubview(in: subview, identifier: identifier) {
            return match
        }
    }
    return nil
}

private enum RemoteEditorAdvancedEntry: CaseIterable {
    case mainButton
    case menuDetach
    case toolbarDrag
    case webViewTabDrag
    case targetDisplayMenu
}

@MainActor
private final class CoordinatorHarness {
    let host = RecordingCoordinatorDockHost()
    let store: RecordingCoordinatorPresentationStore
    let screenProvider: RecordingCoordinatorScreenProvider
    let licenseAccess = RecordingCoordinatorLicenseAccess()
    let authorizer = RecordingCoordinatorAuthorizer()
    let upgradePresenter = RecordingRemoteEditorLicenseUpgradePresenter()
    let closeConfirmer: RecordingRemoteTextEditorCloseConfirmer
    let fallback = RecordingCoordinatorFallbackOpener()
    let windowFactory: RecordingCoordinatorWindowFactory
    let notificationCenter = NotificationCenter()
    private(set) var createdEditors: [RemoteTextEditorViewController] = []
    private(set) var createdProgressControllers: [RemoteFileOpenProgressViewController] = []
    let coordinator: RemoteEditorPresentationCoordinator

    var editorFactoryCallCount: Int { createdEditors.count }
    var progressFactoryCallCount: Int { createdProgressControllers.count }

    init(
        closeDecision: RemoteTextEditorCloseDecision,
        asyncSaveInstaller: CoordinatorAsyncSaveInstaller?,
        screens: [RemoteEditorScreenDescriptor]?,
        workbenchScreen: RemoteEditorScreenDescriptor?,
        storedFloatingFrame: NSRect?,
        storedScreenIdentity: RemoteEditorScreenIdentity?,
        windowInstallFails: Bool,
        windowCreationFails: Bool
    ) {
        closeConfirmer = RecordingRemoteTextEditorCloseConfirmer(decision: closeDecision)
        let defaultScreen = RemoteEditorScreenDescriptor(
            identity: .init(
                displayID: 1,
                localizedName: "Built-in Display",
                frame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
            ),
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: NSRect(x: 0, y: 24, width: 1_440, height: 876)
        )
        let resolvedScreens = screens ?? [defaultScreen]
        store = RecordingCoordinatorPresentationStore(
            floatingFrame: storedFloatingFrame,
            screenIdentity: storedScreenIdentity
        )
        screenProvider = RecordingCoordinatorScreenProvider(
            screens: resolvedScreens,
            containingScreen: workbenchScreen ?? resolvedScreens.first
        )
        windowFactory = RecordingCoordinatorWindowFactory(
            preoccupyCreatedWindow: windowInstallFails,
            creationFails: windowCreationFails
        )
        authorizer.authorizationErrorProvider = { [licenseAccess] feature in
            licenseAccess.isEnabled(feature)
                ? nil
                : LicensedFeatureAccessError.licenseRequired(feature)
        }
        var editorSink: ((RemoteTextEditorViewController) -> Void)?
        var progressSink: ((RemoteFileOpenProgressViewController) -> Void)?
        coordinator = RemoteEditorPresentationCoordinator(
            dockHost: host,
            presentationStore: store,
            screenProvider: screenProvider,
            licenseAccess: licenseAccess,
            authorizer: authorizer,
            upgradePresenter: upgradePresenter,
            closeConfirmer: closeConfirmer,
            fallbackOpener: fallback,
            windowFactory: { [windowFactory] in
                try windowFactory.makeWindow()
            },
            editorFactory: { descriptor, saveHandler, _ in
                let editor: RemoteTextEditorViewController
                if let asyncSaveInstaller {
                    editor = RemoteTextEditorViewController(
                        document: descriptor,
                        onSaveTextAsync: { _, completion in asyncSaveInstaller(completion) }
                    )
                } else {
                    editor = RemoteTextEditorViewController(
                        document: descriptor,
                        onSaveText: saveHandler
                    )
                }
                editorSink?(editor)
                return editor
            },
            progressFactory: { selection, mode in
                let progress = RemoteFileOpenProgressViewController(
                    selection: selection,
                    mode: mode
                )
                progressSink?(progress)
                return progress
            },
            notificationCenter: notificationCenter
        )
        editorSink = { [weak self] in self?.createdEditors.append($0) }
        progressSink = { [weak self] in self?.createdProgressControllers.append($0) }
    }

    func invokeAdvancedEntry(_ entry: RemoteEditorAdvancedEntry) {
        guard let editor = coordinator.currentEditor else { return }
        switch entry {
        case .mainButton:
            editor.requestTogglePresentationForTesting()
        case .menuDetach:
            coordinator.performPresentationMenuAction(.detach)
        case .toolbarDrag:
            editor.simulateToolbarDragForTesting(
                buttonNumber: 0,
                points: [.zero, NSPoint(x: 9, y: 0)]
            )
        case .webViewTabDrag:
            editor.receiveTabDragCandidateForTesting(
                pageLoadGeneration: editor.pageLoadGenerationForTesting,
                pointInWindow: .zero
            )
            editor.simulateTrackedTabDragForTesting(to: NSPoint(x: 9, y: 0))
        case .targetDisplayMenu:
            guard let screen = screenProvider.screens.first else { return }
            coordinator.performPresentationMenuAction(.display(screen.identity))
        }
    }
}

@MainActor
private final class RecordingCoordinatorDockHost: RemoteEditorDockHosting {
    var parentWindow: NSWindow? { nil }
    private(set) var editorContentViewController: NSViewController?
    private(set) var isEditorSidecarCollapsed = true
    private(set) var removedControllers: [NSViewController] = []
    private(set) var synchronizeLayoutCallCount = 0
    var failNextInstall = false
    var failAllInstalls = false
    var onCollapsedChanged: ((Bool) -> Void)?
    var onInstallAttempt: (() -> Void)?
    var onRemoveAttempt: (() -> Void)?

    var hostedControllerCount: Int { editorContentViewController == nil ? 0 : 1 }

    func installEditorContent(_ controller: NSViewController) throws {
        onInstallAttempt?()
        if failAllInstalls || failNextInstall {
            failNextInstall = false
            throw RemoteEditorDockHostError.occupied
        }
        if let current = editorContentViewController, current !== controller {
            throw RemoteEditorDockHostError.occupied
        }
        editorContentViewController = controller
        isEditorSidecarCollapsed = false
    }

    func removeEditorContent(_ controller: NSViewController) throws {
        onRemoveAttempt?()
        guard editorContentViewController === controller else {
            throw RemoteEditorDockHostError.contentMismatch
        }
        removedControllers.append(controller)
        editorContentViewController = nil
        isEditorSidecarCollapsed = true
    }

    func setEditorSidecarCollapsed(_ collapsed: Bool) {
        isEditorSidecarCollapsed = collapsed
        onCollapsedChanged?(collapsed)
    }

    func synchronizeEditorLayout() {
        synchronizeLayoutCallCount += 1
    }
}

private final class RecordingCoordinatorPresentationStore: RemoteEditorPresentationStoring {
    var storedSidecarTargetWidth: CGFloat?
    var storedFloatingFrame: NSRect?
    var storedScreenIdentity: RemoteEditorScreenIdentity?

    init(
        floatingFrame: NSRect? = nil,
        screenIdentity: RemoteEditorScreenIdentity? = nil
    ) {
        storedFloatingFrame = floatingFrame
        storedScreenIdentity = screenIdentity
    }

    func sidecarTargetWidth() -> CGFloat? { storedSidecarTargetWidth }
    func saveSidecarTargetWidth(_ width: CGFloat) { storedSidecarTargetWidth = width }
    func floatingFrame() -> NSRect? { storedFloatingFrame }
    func saveFloatingFrame(_ frame: NSRect) { storedFloatingFrame = frame }
    func screenIdentity() -> RemoteEditorScreenIdentity? { storedScreenIdentity }
    func saveScreenIdentity(_ identity: RemoteEditorScreenIdentity?) {
        storedScreenIdentity = identity
    }
}

@MainActor
private final class RecordingCoordinatorScreenProvider: RemoteEditorScreenProviding {
    var screens: [RemoteEditorScreenDescriptor]
    var containingScreen: RemoteEditorScreenDescriptor?
    var onAvailableScreens: (() -> Void)?
    private(set) var availableScreensCallCount = 0

    init(
        screens: [RemoteEditorScreenDescriptor] = [],
        containingScreen: RemoteEditorScreenDescriptor? = nil
    ) {
        self.screens = screens
        self.containingScreen = containingScreen
    }

    func availableScreens() -> [RemoteEditorScreenDescriptor] {
        availableScreensCallCount += 1
        onAvailableScreens?()
        return screens
    }

    func descriptor(containing window: NSWindow?) -> RemoteEditorScreenDescriptor? {
        containingScreen
    }
}

private final class RecordingCoordinatorLicenseAccess: LicenseFeatureAccessProviding {
    var enabledFeatures = Set(StacioLicensedFeature.allCases)

    func isEnabled(_ feature: StacioLicensedFeature) -> Bool {
        enabledFeatures.contains(feature)
    }
}

@MainActor
private final class RecordingRemoteEditorLicenseUpgradePresenter:
    RemoteEditorLicenseUpgradePresenting
{
    private(set) var presentationCount = 0

    func presentDetachedEditorLicenseRequired(parentWindow: NSWindow?) {
        presentationCount += 1
    }
}

private struct AllowingCoordinatorAuthorizer: LicensedFeatureAuthorizing {
    func authorize(_ feature: StacioLicensedFeature) throws {}
}

private final class RecordingCoordinatorAuthorizer: LicensedFeatureAuthorizing {
    var error: Error?
    var authorizationErrorProvider: ((StacioLicensedFeature) -> Error?)?
    var onAuthorize: (() -> Void)?
    private(set) var authorizedFeatures: [StacioLicensedFeature] = []

    func authorize(_ feature: StacioLicensedFeature) throws {
        authorizedFeatures.append(feature)
        onAuthorize?()
        if let error = error ?? authorizationErrorProvider?(feature) {
            throw error
        }
    }
}

@MainActor
private final class RecordingCoordinatorWindowFactory {
    private let preoccupyCreatedWindow: Bool
    private let creationFails: Bool
    private(set) var createdWindows: [RemoteTextEditorWindowController] = []
    var onMakeWindow: (() -> Void)?
    var onWindowCreated: ((RemoteTextEditorWindowController, Int) -> Void)?
    var lastWindow: RemoteTextEditorWindowController? { createdWindows.last }
    var visibleWindowCount: Int {
        createdWindows.filter { $0.window?.isVisible == true }.count
    }

    init(preoccupyCreatedWindow: Bool = false, creationFails: Bool = false) {
        self.preoccupyCreatedWindow = preoccupyCreatedWindow
        self.creationFails = creationFails
    }

    func makeWindow() throws -> RemoteTextEditorWindowController {
        onMakeWindow?()
        if creationFails {
            throw CocoaError(.coderInvalidValue)
        }
        let controller = RemoteTextEditorWindowController()
        if preoccupyCreatedWindow {
            try controller.installEditor(
                RemoteTextEditorViewController(
                    document: RemoteTextEditorDocumentDescriptor(
                        remotePath: "/tmp/occupied",
                        fileName: "occupied",
                        content: ""
                    )
                )
            )
        }
        createdWindows.append(controller)
        onWindowCreated?(controller, createdWindows.count)
        return controller
    }

    func closeAll() {
        createdWindows.forEach { $0.window?.close() }
    }
}

@MainActor
private final class RecordingCoordinatorFallbackOpener: RemoteEditOpening {
    private(set) var prepareRequests: [String] = []
    private(set) var failureRequests: [String] = []
    private(set) var lastLocalCopyURL: URL?

    func prepareToOpenRemote(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        prepareRequests.append(selection.path)
        return true
    }

    func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {
        lastLocalCopyURL = url
    }

    func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {}

    func remoteOpenDidFail(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        message: String
    ) {
        failureRequests.append(selection.path)
    }

    func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws {}
}
