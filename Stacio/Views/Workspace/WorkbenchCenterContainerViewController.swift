import AppKit

public enum RemoteEditorDockHostError: Error, Equatable {
    case occupied
    case contentMismatch
    case invalidContainment
}

@MainActor
public protocol RemoteEditorDockHosting: AnyObject {
    var parentWindow: NSWindow? { get }
    var editorContentViewController: NSViewController? { get }
    var isEditorSidecarCollapsed: Bool { get }

    func installEditorContent(_ controller: NSViewController) throws
    func removeEditorContent(_ controller: NSViewController) throws
    func setEditorSidecarCollapsed(_ collapsed: Bool)
    func synchronizeEditorLayout()
}

private final class UserTrackedEditorSplitView: NSSplitView {
    var onUserDividerDragStarted: (() -> Void)?
    var onUserDividerDragEnded: (() -> Void)?
    var onLayoutCompleted: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onUserDividerDragStarted?()
        super.mouseDown(with: event)
        onUserDividerDragEnded?()
    }

    override func layout() {
        super.layout()
        onLayoutCompleted?()
    }
}

@MainActor
public final class WorkbenchCenterContainerViewController: NSViewController,
    NSSplitViewDelegate,
    RemoteEditorDockHosting
{
    public static let defaultEditorTargetWidth: CGFloat = 680
    public static let minimumEditorWidth: CGFloat = 480
    public static let minimumReadableWorkspaceWidth: CGFloat = 320

    public let workspaceViewController: NSViewController

    private let presentationStore: RemoteEditorPresentationStoring
    private let splitView = UserTrackedEditorSplitView()
    private let editorHostView = NSView()
    private var hostedEditorContentViewController: NSViewController?
    private var editorTargetWidth: CGFloat
    private var editorSidecarCollapsed = true
    private var programmaticLayoutDepth = 0
    private var lastObservedAvailableWidth: CGFloat?
    private var isUserDividerDragInProgress = false
    private var isEditorTargetWidthRestoreScheduled = false
    private var isEditorLayoutSynchronizationScheduled = false

    public init(
        workspaceViewController: NSViewController,
        presentationStore: RemoteEditorPresentationStoring
    ) {
        self.workspaceViewController = workspaceViewController
        self.presentationStore = presentationStore
        if let storedWidth = presentationStore.sidecarTargetWidth(),
           storedWidth.isFinite,
           storedWidth >= Self.minimumEditorWidth
        {
            editorTargetWidth = storedWidth
        } else {
            editorTargetWidth = Self.defaultEditorTargetWidth
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.setAccessibilityIdentifier("Stacio.Workbench.centerContainer")
        splitView.onUserDividerDragStarted = { [weak self] in
            self?.isUserDividerDragInProgress = true
        }
        splitView.onUserDividerDragEnded = { [weak self] in
            self?.isUserDividerDragInProgress = false
            self?.persistUserDividerResult()
        }
        splitView.onLayoutCompleted = { [weak self] in
            self?.scheduleEditorTargetWidthRestore()
        }

        addChild(workspaceViewController)
        workspaceViewController.view.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        workspaceViewController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)

        editorHostView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        editorHostView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        editorHostView.isHidden = true

        splitView.addArrangedSubview(workspaceViewController.view)
        splitView.addArrangedSubview(editorHostView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        view = splitView
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let availableWidth = splitView.bounds.width
        guard availableWidth.isFinite, availableWidth >= 0 else { return }

        let widthChanged = lastObservedAvailableWidth != availableWidth
        lastObservedAvailableWidth = availableWidth
        if editorSidecarCollapsed == false,
           isUserDividerDragInProgress == false,
           programmaticLayoutDepth == 0
        {
            scheduleEditorTargetWidthRestore()
        }
        if widthChanged {
            scheduleEditorLayoutSynchronization()
        }
    }

    public var parentWindow: NSWindow? {
        guard isViewLoaded else { return nil }
        return view.window
    }

    public var editorContentViewController: NSViewController? {
        hostedEditorContentViewController
    }

    public var isEditorSidecarCollapsed: Bool {
        editorSidecarCollapsed
    }

    public var editorSidecarDividerThickness: CGFloat {
        _ = view
        return splitView.dividerThickness
    }

    public func installEditorContent(_ controller: NSViewController) throws {
        _ = view
        if let current = hostedEditorContentViewController {
            guard current === controller else {
                throw RemoteEditorDockHostError.occupied
            }
            setEditorSidecarCollapsed(false)
            return
        }
        guard controller.parent == nil else {
            throw RemoteEditorDockHostError.invalidContainment
        }
        if controller.isViewLoaded, controller.view.superview != nil {
            throw RemoteEditorDockHostError.invalidContainment
        }

        performProgrammaticLayout {
            addChild(controller)
            let contentView = controller.view
            contentView.translatesAutoresizingMaskIntoConstraints = false
            editorHostView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: editorHostView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: editorHostView.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: editorHostView.safeAreaLayoutGuide.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: editorHostView.bottomAnchor)
            ])
            hostedEditorContentViewController = controller
            editorSidecarCollapsed = false
            editorHostView.isHidden = false
            splitView.adjustSubviews()
            applyEditorTargetWidth()
        }
        scheduleEditorLayoutSynchronization()
    }

    public func removeEditorContent(_ controller: NSViewController) throws {
        _ = view
        guard let current = hostedEditorContentViewController,
              current === controller
        else {
            throw RemoteEditorDockHostError.contentMismatch
        }

        performProgrammaticLayout {
            current.view.removeFromSuperview()
            current.removeFromParent()
            hostedEditorContentViewController = nil
            editorSidecarCollapsed = true
            editorHostView.isHidden = true
            splitView.adjustSubviews()
        }
        scheduleEditorLayoutSynchronization()
    }

    public func setEditorSidecarCollapsed(_ collapsed: Bool) {
        _ = view
        guard hostedEditorContentViewController != nil else { return }
        guard editorSidecarCollapsed != collapsed else {
            if collapsed == false {
                performProgrammaticLayout {
                    applyEditorTargetWidth()
                }
                scheduleEditorLayoutSynchronization()
            }
            return
        }

        performProgrammaticLayout {
            editorSidecarCollapsed = collapsed
            editorHostView.isHidden = collapsed
            splitView.adjustSubviews()
            if collapsed == false {
                applyEditorTargetWidth()
            }
        }
        scheduleEditorLayoutSynchronization()
    }

    public func synchronizeEditorLayout() {
        scheduleEditorLayoutSynchronization()
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView,
              dividerIndex == 0,
              splitView.arrangedSubviews.count == 2
        else {
            return proposedPosition
        }

        let availableWidth = splitView.bounds.width
        let usableWidth = max(0, availableWidth - splitView.dividerThickness)
        guard proposedPosition.isFinite, usableWidth.isFinite else {
            return max(0, splitView.arrangedSubviews[0].frame.width)
        }

        let widthNeededForBothMinimums = Self.minimumReadableWorkspaceWidth
            + Self.minimumEditorWidth
        if usableWidth >= widthNeededForBothMinimums {
            let maximumWorkspaceWidth = usableWidth - Self.minimumEditorWidth
            return min(
                max(proposedPosition, Self.minimumReadableWorkspaceWidth),
                maximumWorkspaceWidth
            )
        }
        return min(max(0, proposedPosition), usableWidth)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView,
              dividerIndex == 0,
              splitView.arrangedSubviews.count == 2
        else {
            return proposedMinimumPosition
        }
        let usableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        guard usableWidth >= Self.minimumReadableWorkspaceWidth + Self.minimumEditorWidth else {
            return 0
        }
        return min(Self.minimumReadableWorkspaceWidth, usableWidth)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView,
              dividerIndex == 0,
              splitView.arrangedSubviews.count == 2
        else {
            return proposedMaximumPosition
        }
        let usableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        guard usableWidth >= Self.minimumReadableWorkspaceWidth + Self.minimumEditorWidth else {
            return usableWidth
        }
        return max(0, usableWidth - Self.minimumEditorWidth)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }
        scheduleEditorLayoutSynchronization()
    }

    var splitSubviewCountForTesting: Int {
        _ = view
        return splitView.arrangedSubviews.count
    }

    var isEditorSidecarCollapsedForTesting: Bool {
        isEditorSidecarCollapsed
    }

    var editorSidecarWidthForTesting: CGFloat {
        _ = view
        return editorSidecarWidth
    }

    var editorTargetWidthForTesting: CGFloat {
        editorTargetWidth
    }

    var editorContentViewControllerForTesting: NSViewController? {
        editorContentViewController
    }

    func setEditorSidecarWidthForTesting(_ width: CGFloat, userInitiated: Bool) {
        _ = view
        guard editorSidecarCollapsed == false else { return }
        performProgrammaticLayout {
            setPhysicalEditorWidth(width)
        }
        if userInitiated {
            persistUserDividerResult()
        }
    }

    private var editorSidecarWidth: CGFloat {
        editorHostView.frame.width
    }

    private func effectiveEditorWidth(availableWidth: CGFloat) -> CGFloat {
        let divider = splitView.dividerThickness
        let roomAfterReadableWorkspace = max(
            0,
            availableWidth - divider - Self.minimumReadableWorkspaceWidth
        )
        if roomAfterReadableWorkspace >= Self.minimumEditorWidth {
            return min(editorTargetWidth, roomAfterReadableWorkspace)
        }
        return max(0, availableWidth - divider)
    }

    private func applyEditorTargetWidth() {
        guard editorSidecarCollapsed == false else { return }
        let availableWidth = splitView.bounds.width
        guard availableWidth.isFinite, availableWidth > 0 else { return }
        let targetWidth = effectiveEditorWidth(availableWidth: availableWidth)
        guard abs(editorSidecarWidth - targetWidth) > 0.5 else { return }
        setPhysicalEditorWidth(targetWidth)
    }

    private func setPhysicalEditorWidth(_ width: CGFloat) {
        let availableWidth = splitView.bounds.width
        guard width.isFinite, availableWidth.isFinite, availableWidth >= 0 else { return }
        let usableWidth = max(0, availableWidth - splitView.dividerThickness)
        let physicalWidth = min(max(0, width), usableWidth)
        splitView.setPosition(usableWidth - physicalWidth, ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    private func persistUserDividerResult() {
        guard programmaticLayoutDepth == 0,
              editorSidecarCollapsed == false,
              editorSidecarWidth >= Self.minimumEditorWidth,
              editorSidecarWidth.isFinite
        else {
            return
        }
        editorTargetWidth = editorSidecarWidth
        presentationStore.saveSidecarTargetWidth(editorSidecarWidth)
    }

    private func performProgrammaticLayout(_ action: () -> Void) {
        programmaticLayoutDepth += 1
        defer { programmaticLayoutDepth -= 1 }
        action()
    }

    private func restoreTargetWidthAfterSplitLayoutIfNeeded() {
        guard editorSidecarCollapsed == false,
              isUserDividerDragInProgress == false,
              programmaticLayoutDepth == 0
        else {
            return
        }
        performProgrammaticLayout {
            applyEditorTargetWidth()
        }
    }

    private func scheduleEditorTargetWidthRestore() {
        guard isEditorTargetWidthRestoreScheduled == false else { return }
        isEditorTargetWidthRestoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isEditorTargetWidthRestoreScheduled = false
            self.restoreTargetWidthAfterSplitLayoutIfNeeded()
        }
    }

    private func scheduleEditorLayoutSynchronization() {
        guard isEditorLayoutSynchronizationScheduled == false else { return }
        isEditorLayoutSynchronizationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isEditorLayoutSynchronizationScheduled = false
            guard let editor = self.hostedEditorContentViewController as? RemoteTextEditorViewController else {
                return
            }
            editor.synchronizeLayoutAfterContainerChange()
        }
    }
}
