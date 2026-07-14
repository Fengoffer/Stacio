import AppKit

final class StacioPinnedSplitView: NSSplitView {
    var beforeSetPosition: ((NSSplitView, CGFloat, Int) -> Void)?
    var afterSetPosition: ((NSSplitView, CGFloat, Int) -> Void)?
    var afterLayout: ((NSSplitView) -> Void)?
    private(set) var isPerformingLayoutForTesting = false
    var isPerformingLayoutPass: Bool { isPerformingLayoutForTesting }
    private var isAfterLayoutCallbackScheduled = false

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        beforeSetPosition?(self, position, dividerIndex)
        super.setPosition(position, ofDividerAt: dividerIndex)
        afterSetPosition?(self, position, dividerIndex)
    }

    override func layout() {
        isPerformingLayoutForTesting = true
        defer {
            isPerformingLayoutForTesting = false
            scheduleAfterLayoutCallback()
        }
        super.layout()
    }

    private func scheduleAfterLayoutCallback() {
        guard afterLayout != nil,
              isAfterLayoutCallbackScheduled == false
        else { return }

        isAfterLayoutCallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.afterLayout?(self)
            self.isAfterLayoutCallbackScheduled = false
        }
    }
}

final class StacioPinnedSplitViewController: NSSplitViewController {
    private static let dividerHitAreaOutset: CGFloat = 8

    static func expandedDividerEffectiveRect(_ rect: NSRect, isVertical: Bool) -> NSRect {
        let outset = dividerHitAreaOutset
        guard outset > 0 else {
            return rect
        }

        if isVertical {
            return rect.insetBy(dx: -outset, dy: 0)
        }
        return rect.insetBy(dx: 0, dy: -outset)
    }

    var afterPinnedLayout: (() -> Void)?
    var constrainPinnedSplitPosition: ((NSSplitView, CGFloat, Int) -> CGFloat)?
    var beforePinnedSetPosition: ((NSSplitView, CGFloat, Int) -> Void)? {
        didSet {
            (splitView as? StacioPinnedSplitView)?.beforeSetPosition = beforePinnedSetPosition
        }
    }
    var afterPinnedSetPosition: ((NSSplitView, CGFloat, Int) -> Void)? {
        didSet {
            (splitView as? StacioPinnedSplitView)?.afterSetPosition = afterPinnedSetPosition
        }
    }
    var afterPinnedSplitViewLayout: ((NSSplitView) -> Void)? {
        didSet {
            (splitView as? StacioPinnedSplitView)?.afterLayout = afterPinnedSplitViewLayout
        }
    }
    private var isRunningAfterPinnedLayout = false
    private var isAfterPinnedLayoutCallbackScheduled = false

    init(usesPositionHookSplitView: Bool = false) {
        super.init(nibName: nil, bundle: nil)
        if usesPositionHookSplitView {
            splitView = StacioPinnedSplitView()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (splitView as? StacioPinnedSplitView)?.beforeSetPosition = beforePinnedSetPosition
        (splitView as? StacioPinnedSplitView)?.afterSetPosition = afterPinnedSetPosition
        (splitView as? StacioPinnedSplitView)?.afterLayout = afterPinnedSplitViewLayout
        portDeskPinSplitViewToContainerEdges()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        portDeskRefreshPinnedSplitViewLayout()
        scheduleAfterPinnedLayoutCallback()
    }

    private func scheduleAfterPinnedLayoutCallback() {
        guard afterPinnedLayout != nil,
              isRunningAfterPinnedLayout == false,
              isAfterPinnedLayoutCallbackScheduled == false
        else { return }

        isAfterPinnedLayoutCallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isRunningAfterPinnedLayout == false
            else { return }

            self.isAfterPinnedLayoutCallbackScheduled = false
            self.isRunningAfterPinnedLayout = true
            self.afterPinnedLayout?()
            self.isRunningAfterPinnedLayout = false
        }
    }

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        constrainPinnedSplitPosition?(splitView, proposedPosition, dividerIndex)
            ?? super.splitView(splitView, constrainSplitPosition: proposedPosition, ofSubviewAt: dividerIndex)
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        Self.expandedDividerEffectiveRect(proposedEffectiveRect, isVertical: splitView.isVertical)
    }
}

extension NSSplitViewController {
    private static let portDeskEdgePinIdentifier = "Stacio.SplitViewController.edgePin"

    func portDeskPinSplitViewToContainerEdges() {
        let splitView = splitView
        _ = view
        guard let container = splitView.superview,
              splitView !== container
        else { return }

        let hasPinnedEdges = container.constraints.contains { constraint in
            constraint.identifier == Self.portDeskEdgePinIdentifier
        }
        guard hasPinnedEdges == false else { return }

        splitView.translatesAutoresizingMaskIntoConstraints = false
        let constraints = [
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        constraints.forEach { $0.identifier = Self.portDeskEdgePinIdentifier }
        NSLayoutConstraint.activate(constraints)
    }

    @discardableResult
    func portDeskRefreshPinnedSplitViewLayout() -> Bool {
        portDeskPinSplitViewToContainerEdges()
        guard let container = splitView.superview else { return false }

        guard splitView.frame != container.bounds else { return false }
        splitView.frame = container.bounds
        splitView.needsLayout = true
        return true
    }
}
