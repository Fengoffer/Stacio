import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class WorkbenchCenterContainerViewControllerTests: XCTestCase {
    func testRootContainsWorkspaceAndHiddenEditorSidecarInThatOrder() throws {
        let workspace = PlainCenterChildViewController()
        let controller = WorkbenchCenterContainerViewController(
            workspaceViewController: workspace,
            presentationStore: RecordingRemoteEditorPresentationStore()
        )

        controller.loadView()

        let splitView = try XCTUnwrap(controller.view as? NSSplitView)
        XCTAssertEqual(controller.splitSubviewCountForTesting, 2)
        XCTAssertTrue(controller.workspaceViewController === workspace)
        XCTAssertTrue(splitView.arrangedSubviews[0] === workspace.view)
        XCTAssertTrue(splitView.arrangedSubviews[1].isHidden)
        XCTAssertTrue(controller.isEditorSidecarCollapsedForTesting)
        XCTAssertNil(controller.editorContentViewControllerForTesting)
        XCTAssertEqual(
            controller.view.accessibilityIdentifier(),
            "Stacio.Workbench.centerContainer"
        )
        XCTAssertEqual(controller.editorSidecarDividerThickness, splitView.dividerThickness)
    }

    func testFirstOpenUsesDefaultTargetWithoutStoreWrites() throws {
        let store = RecordingRemoteEditorPresentationStore()
        let controller = makeCenter(width: 1_400, store: store)

        try controller.installEditorContent(PlainCenterChildViewController())
        layout(controller)

        XCTAssertEqual(
            controller.editorSidecarWidthForTesting,
            680,
            accuracy: 1
        )
        XCTAssertEqual(controller.editorTargetWidthForTesting, 680)
        XCTAssertEqual(WorkbenchCenterContainerViewController.defaultEditorTargetWidth, 680)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testSavedTargetRestoresWithoutStoreWrites() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 760)
        let controller = makeCenter(width: 1_500, store: store)

        try controller.installEditorContent(PlainCenterChildViewController())
        layout(controller)

        XCTAssertEqual(controller.editorSidecarWidthForTesting, 760, accuracy: 1)
        XCTAssertEqual(controller.editorTargetWidthForTesting, 760)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testOnlyCompletedUserDividerAdjustmentPersistsAndUpdatesTarget() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 760)
        let controller = makeCenter(width: 1_500, store: store)
        try controller.installEditorContent(PlainCenterChildViewController())
        layout(controller)

        controller.setEditorSidecarWidthForTesting(800, userInitiated: false)
        controller.setEditorSidecarWidthForTesting(820, userInitiated: false)

        XCTAssertEqual(store.savedSidecarWidths, [])
        XCTAssertEqual(controller.editorTargetWidthForTesting, 760)

        controller.setEditorSidecarWidthForTesting(840, userInitiated: true)

        XCTAssertEqual(store.savedSidecarWidths, [840])
        XCTAssertEqual(controller.editorTargetWidthForTesting, 840)
    }

    func testPhysicalClampDoesNotOverwriteTargetAndRestoresWhenSpaceReturns() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 760)
        let controller = makeCenter(width: 600, store: store)

        try controller.installEditorContent(PlainCenterChildViewController())
        layout(controller)

        XCTAssertEqual(
            controller.editorSidecarWidthForTesting,
            600 - controller.editorSidecarDividerThickness,
            accuracy: 1
        )
        XCTAssertLessThan(controller.editorSidecarWidthForTesting, 760)
        XCTAssertEqual(controller.editorTargetWidthForTesting, 760)
        XCTAssertEqual(store.savedSidecarWidths, [])

        resize(controller, to: 1_500)

        XCTAssertEqual(controller.editorSidecarWidthForTesting, 760, accuracy: 1)
        XCTAssertEqual(controller.editorTargetWidthForTesting, 760)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testCollapseAndExpandKeepSameChildAndTargetWidth() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 720)
        let controller = makeCenter(width: 1_400, store: store)
        let editor = PlainCenterChildViewController()
        try controller.installEditorContent(editor)

        controller.setEditorSidecarCollapsed(true)

        XCTAssertTrue(controller.isEditorSidecarCollapsedForTesting)
        XCTAssertTrue(controller.editorContentViewControllerForTesting === editor)
        XCTAssertTrue(editor.parent === controller)

        controller.setEditorSidecarCollapsed(false)
        layout(controller)

        XCTAssertFalse(controller.isEditorSidecarCollapsedForTesting)
        XCTAssertTrue(controller.editorContentViewControllerForTesting === editor)
        XCTAssertTrue(editor.parent === controller)
        XCTAssertEqual(controller.editorTargetWidthForTesting, 720)
        XCTAssertEqual(controller.editorSidecarWidthForTesting, 720, accuracy: 1)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testOccupiedHostRejectsSecondContentWithoutRemovingFirst() throws {
        let controller = makeCenter(
            width: 1_400,
            store: RecordingRemoteEditorPresentationStore()
        )
        let first = PlainCenterChildViewController()
        let second = PlainCenterChildViewController()
        try controller.installEditorContent(first)

        XCTAssertThrowsError(try controller.installEditorContent(second)) {
            XCTAssertEqual($0 as? RemoteEditorDockHostError, .occupied)
        }
        XCTAssertTrue(controller.editorContentViewControllerForTesting === first)
        XCTAssertTrue(first.parent === controller)
        XCTAssertNil(second.parent)
    }

    func testInstallRejectsContentOwnedByAnotherParentWithoutReparentingIt() throws {
        let controller = makeCenter(
            width: 1_400,
            store: RecordingRemoteEditorPresentationStore()
        )
        let foreignParent = PlainCenterChildViewController()
        let editor = PlainCenterChildViewController()
        foreignParent.loadView()
        foreignParent.addChild(editor)
        foreignParent.view.addSubview(editor.view)

        XCTAssertThrowsError(try controller.installEditorContent(editor)) {
            XCTAssertEqual($0 as? RemoteEditorDockHostError, .invalidContainment)
        }

        XCTAssertTrue(editor.parent === foreignParent)
        XCTAssertTrue(editor.view.superview === foreignParent.view)
        XCTAssertNil(controller.editorContentViewControllerForTesting)
        XCTAssertTrue(controller.isEditorSidecarCollapsedForTesting)
    }

    func testInstallingSameContentIsIdempotent() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 700)
        let controller = makeCenter(width: 1_400, store: store)
        let editor = PlainCenterChildViewController()

        try controller.installEditorContent(editor)
        try controller.installEditorContent(editor)

        XCTAssertTrue(controller.editorContentViewControllerForTesting === editor)
        XCTAssertEqual(controller.children.filter { $0 === editor }.count, 1)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testRemovingWrongContentThrowsMismatchAndLeavesCurrentHostUntouched() throws {
        let controller = makeCenter(
            width: 1_400,
            store: RecordingRemoteEditorPresentationStore()
        )
        let first = PlainCenterChildViewController()
        let different = PlainCenterChildViewController()
        try controller.installEditorContent(first)

        XCTAssertThrowsError(try controller.removeEditorContent(different)) {
            XCTAssertEqual($0 as? RemoteEditorDockHostError, .contentMismatch)
        }
        XCTAssertTrue(controller.editorContentViewControllerForTesting === first)
        XCTAssertTrue(first.parent === controller)
        XCTAssertFalse(controller.isEditorSidecarCollapsedForTesting)
    }

    func testRemovingCurrentContentCollapsesPermanentHostAndKeepsTarget() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 710)
        let controller = makeCenter(width: 1_400, store: store)
        let editor = PlainCenterChildViewController()
        try controller.installEditorContent(editor)

        try controller.removeEditorContent(editor)

        XCTAssertNil(controller.editorContentViewControllerForTesting)
        XCTAssertNil(editor.parent)
        XCTAssertTrue(controller.isEditorSidecarCollapsedForTesting)
        XCTAssertEqual(controller.splitSubviewCountForTesting, 2)
        XCTAssertEqual(controller.editorTargetWidthForTesting, 710)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testProgrammaticLifecycleAndPhysicalClampsNeverPersist() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 730)
        let controller = makeCenter(width: 1_500, store: store)
        let editor = PlainCenterChildViewController()

        try controller.installEditorContent(editor)
        controller.setEditorSidecarWidthForTesting(790, userInitiated: false)
        controller.setEditorSidecarCollapsed(true)
        controller.setEditorSidecarCollapsed(false)
        resize(controller, to: 550)
        resize(controller, to: 1_500)
        try controller.removeEditorContent(editor)

        XCTAssertEqual(store.savedSidecarWidths, [])
        XCTAssertEqual(controller.editorTargetWidthForTesting, 730)
    }

    func testUserDividerCompletionBelowMinimumInNarrowCenterDoesNotPersist() throws {
        let store = RecordingRemoteEditorPresentationStore(sidecarWidth: 700)
        let controller = makeCenter(width: 420, store: store)
        try controller.installEditorContent(PlainCenterChildViewController())

        controller.setEditorSidecarWidthForTesting(300, userInitiated: true)

        XCTAssertLessThan(
            controller.editorSidecarWidthForTesting,
            WorkbenchCenterContainerViewController.minimumEditorWidth
        )
        XCTAssertEqual(controller.editorTargetWidthForTesting, 700)
        XCTAssertEqual(store.savedSidecarWidths, [])
    }

    func testLayoutSynchronizationIsDeferredAndCoalescedForRealEditor() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/tmp/coalesced-layout.txt",
                fileName: "coalesced-layout.txt",
                content: "ready\n"
            ),
            settingsStore: AppSettingsStore(defaults: defaults),
            editorOptionsDefaults: defaults
        )
        let controller = makeCenter(
            width: 1_400,
            store: RecordingRemoteEditorPresentationStore()
        )
        try controller.installEditorContent(editor)
        layout(controller)
        editor.markEditorReadyForTesting()
        drainMainRunLoop()
        editor.resetEditorFunctionCallsForTesting()

        controller.synchronizeEditorLayout()
        controller.synchronizeEditorLayout()
        controller.synchronizeEditorLayout()
        controller.setEditorSidecarWidthForTesting(700, userInitiated: false)
        controller.setEditorSidecarWidthForTesting(710, userInitiated: false)

        XCTAssertEqual(layoutCallCount(in: editor), 0)
        XCTAssertTrue(waitUntil { self.layoutCallCount(in: editor) == 1 })
        drainMainRunLoop()
        XCTAssertEqual(layoutCallCount(in: editor), 1)
    }

    private func makeCenter(
        width: CGFloat,
        store: RecordingRemoteEditorPresentationStore
    ) -> WorkbenchCenterContainerViewController {
        let controller = WorkbenchCenterContainerViewController(
            workspaceViewController: PlainCenterChildViewController(),
            presentationStore: store
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        layout(controller)
        return controller
    }

    private func resize(
        _ controller: WorkbenchCenterContainerViewController,
        to width: CGFloat
    ) {
        controller.view.frame.size.width = width
        layout(controller)
    }

    private func layout(_ controller: WorkbenchCenterContainerViewController) {
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
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

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func layoutCallCount(in editor: RemoteTextEditorViewController) -> Int {
        editor.editorFunctionCallsForTesting.filter { $0 == "layout" }.count
    }
}

@MainActor
private final class PlainCenterChildViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }
}

private final class RecordingRemoteEditorPresentationStore: RemoteEditorPresentationStoring {
    private let storedSidecarWidth: CGFloat?
    private(set) var savedSidecarWidths: [CGFloat] = []
    private var storedFloatingFrame: NSRect?
    private var storedScreenIdentity: RemoteEditorScreenIdentity?

    init(sidecarWidth: CGFloat? = nil) {
        storedSidecarWidth = sidecarWidth
    }

    func sidecarTargetWidth() -> CGFloat? {
        storedSidecarWidth
    }

    func saveSidecarTargetWidth(_ width: CGFloat) {
        savedSidecarWidths.append(width)
    }

    func floatingFrame() -> NSRect? {
        storedFloatingFrame
    }

    func saveFloatingFrame(_ frame: NSRect) {
        storedFloatingFrame = frame
    }

    func screenIdentity() -> RemoteEditorScreenIdentity? {
        storedScreenIdentity
    }

    func saveScreenIdentity(_ identity: RemoteEditorScreenIdentity?) {
        storedScreenIdentity = identity
    }
}
