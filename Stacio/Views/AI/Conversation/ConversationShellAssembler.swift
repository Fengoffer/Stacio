import AppKit
import Foundation

// MARK: - 会话壳装配器（P7-6）

/// 装配结果由 AgentConversationV2ControlState 驱动（§18.4）。
public enum ConversationShellAssemblyChoice: Equatable, Sendable {
    case v1Panel
    case v2Shell
    case compatibility

    public static func assembly(for decision: ConversationShellSwitchDecision) -> ConversationShellAssemblyChoice {
        if decision.newTaskEntryOwner == .v2 {
            return .v2Shell
        }
        return decision.v1NewTaskEntryAvailable && decision.v2HistoryAvailable
            ? .compatibility
            : .v1Panel
    }
}

/// 装配点（Workbench/Inspector）使用：给定控制状态 → 装配 V1 或 V2。
public enum ConversationShellAssembler {

    /// 装配决策：必须经 AgentConversationV2ControlCoordinator 的控制状态（非 flag 缓存）。
    @MainActor
    public static func assemble(
        controlState: AgentConversationV2ControlState?,
        makeV1Panel: () -> NSViewController,
        makeV2Shell: () -> NSViewController,
        makeV2ReadOnlyHistory: () -> NSViewController
    ) -> NSViewController {
        guard let controlState else {
            // 控制面不可读：fail-safe 装配 V1（保留既有行为）
            return makeV1Panel()
        }
        let decision = AgentConversationShellPolicy.switchDecision(controlState: controlState)
        switch ConversationShellAssemblyChoice.assembly(for: decision) {
        case .v1Panel:
            return makeV1Panel()
        case .v2Shell:
            return makeV2Shell()
        case .compatibility:
            return ConversationCompatibilityViewController(
                v1Panel: makeV1Panel(),
                v2History: makeV2ReadOnlyHistory()
            )
        }
    }

    /// V1/V2 以清晰标签区分（§18.4）。
    public static func versionLabel(_ version: ConversationShellVersion) -> String {
        AgentConversationShellPolicy.versionLabel(version)
    }
}

// MARK: - Draining/disabled compatibility surface

@MainActor
public final class ConversationCompatibilityViewController: NSViewController {
    public let v1Panel: NSViewController
    public let v2History: NSViewController

    private let headerView = GlassCapabilityAdapter.makeInteractiveSurface(
        frame: NSRect(x: 0, y: 0, width: 720, height: 44),
        fallbackMaterial: .headerView
    )
    private let segmentedControl = NSSegmentedControl(
        labels: [
            AgentConversationShellPolicy.versionLabel(.v1),
            "V2 历史"
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentContainer = NSView()

    public private(set) var selectedVersion: ConversationShellVersion = .v1

    public init(v1Panel: NSViewController, v2History: NSViewController) {
        self.v1Panel = v1Panel
        self.v2History = v2History
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.segmentStyle = .automatic
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(changeVersion(_:))
        segmentedControl.setAccessibilityIdentifier("Stacio.AI.compatibility.version")
        contentContainer.setAccessibilityIdentifier("Stacio.AI.compatibility.content")

        addChild(v1Panel)
        addChild(v2History)
        view.addSubview(headerView)
        view.addSubview(contentContainer)
        headerView.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),
            segmentedControl.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            segmentedControl.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            segmentedControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        mountSelectedController()
    }

    public func selectVersion(_ version: ConversationShellVersion) {
        loadViewIfNeeded()
        selectedVersion = version
        segmentedControl.selectedSegment = version == .v1 ? 0 : 1
        mountSelectedController()
        focusCurrentEntry()
    }

    public func focusCurrentEntry() {
        guard selectedVersion == .v1 else {
            _ = view.window?.makeFirstResponder(nil)
            return
        }
        guard let panel = v1Panel as? AIAssistantPanelViewController else { return }
        panel.refreshForCurrentContext()
        panel.focusQuestionField()
    }

    public func prefillV1(_ text: String) {
        selectVersion(.v1)
        (v1Panel as? AIAssistantPanelViewController)?.prefillQuestion(text)
    }

    private func mountSelectedController() {
        guard isViewLoaded else { return }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let controller = selectedVersion == .v1 ? v1Panel : v2History
        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    @objc private func changeVersion(_ sender: NSSegmentedControl) {
        selectVersion(sender.selectedSegment == 0 ? .v1 : .v2)
    }
}
