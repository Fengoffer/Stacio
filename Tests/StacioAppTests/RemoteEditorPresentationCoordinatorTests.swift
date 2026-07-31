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
        asyncSaveInstaller: CoordinatorAsyncSaveInstaller? = nil
    ) -> CoordinatorHarness {
        CoordinatorHarness(
            closeDecision: closeDecision,
            asyncSaveInstaller: asyncSaveInstaller
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
}

@MainActor
private final class CoordinatorHarness {
    let host = RecordingCoordinatorDockHost()
    let store = RecordingCoordinatorPresentationStore()
    let screenProvider = RecordingCoordinatorScreenProvider()
    let licenseAccess = RecordingCoordinatorLicenseAccess()
    let authorizer = AllowingCoordinatorAuthorizer()
    let closeConfirmer: RecordingRemoteTextEditorCloseConfirmer
    let fallback = RecordingCoordinatorFallbackOpener()
    private(set) var createdEditors: [RemoteTextEditorViewController] = []
    private(set) var createdProgressControllers: [RemoteFileOpenProgressViewController] = []
    let coordinator: RemoteEditorPresentationCoordinator

    var editorFactoryCallCount: Int { createdEditors.count }
    var progressFactoryCallCount: Int { createdProgressControllers.count }

    init(
        closeDecision: RemoteTextEditorCloseDecision,
        asyncSaveInstaller: CoordinatorAsyncSaveInstaller?
    ) {
        closeConfirmer = RecordingRemoteTextEditorCloseConfirmer(decision: closeDecision)
        var editorSink: ((RemoteTextEditorViewController) -> Void)?
        var progressSink: ((RemoteFileOpenProgressViewController) -> Void)?
        coordinator = RemoteEditorPresentationCoordinator(
            dockHost: host,
            presentationStore: store,
            screenProvider: screenProvider,
            licenseAccess: licenseAccess,
            authorizer: authorizer,
            closeConfirmer: closeConfirmer,
            fallbackOpener: fallback,
            editorFactory: { descriptor, saveHandler in
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
            }
        )
        editorSink = { [weak self] in self?.createdEditors.append($0) }
        progressSink = { [weak self] in self?.createdProgressControllers.append($0) }
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

    var hostedControllerCount: Int { editorContentViewController == nil ? 0 : 1 }

    func installEditorContent(_ controller: NSViewController) throws {
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
    func sidecarTargetWidth() -> CGFloat? { nil }
    func saveSidecarTargetWidth(_ width: CGFloat) {}
    func floatingFrame() -> NSRect? { nil }
    func saveFloatingFrame(_ frame: NSRect) {}
    func screenIdentity() -> RemoteEditorScreenIdentity? { nil }
    func saveScreenIdentity(_ identity: RemoteEditorScreenIdentity?) {}
}

@MainActor
private final class RecordingCoordinatorScreenProvider: RemoteEditorScreenProviding {
    func availableScreens() -> [RemoteEditorScreenDescriptor] { [] }
    func descriptor(containing window: NSWindow?) -> RemoteEditorScreenDescriptor? { nil }
}

private final class RecordingCoordinatorLicenseAccess: LicenseFeatureAccessProviding {
    func isEnabled(_ feature: StacioLicensedFeature) -> Bool { true }
}

private struct AllowingCoordinatorAuthorizer: LicensedFeatureAuthorizing {
    func authorize(_ feature: StacioLicensedFeature) throws {}
}

@MainActor
private final class RecordingCoordinatorFallbackOpener: RemoteEditOpening {
    private(set) var prepareRequests: [String] = []
    private(set) var failureRequests: [String] = []

    func prepareToOpenRemote(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        prepareRequests.append(selection.path)
        return true
    }

    func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {}

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
