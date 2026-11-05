import AppKit
import Foundation

// MARK: - V2 会话壳（P5-6）

/// 会话壳版本：V2（新会话壳）/ V1（兼容面板）。
public enum ConversationShellVersion: String, Codable, CaseIterable, Equatable, Sendable {
    case v1
    case v2
}

/// 由 `AgentConversationV2ControlState` 驱动的切换决策（§18.4，非 UI 布尔值）。
public struct ConversationShellSwitchDecision: Equatable, Sendable {
    /// 同一时刻只有一个版本拥有新任务执行权。
    public let newTaskEntryOwner: ConversationShellVersion
    public let v2HistoryAvailable: Bool
    public let v2NewTaskEntryAvailable: Bool
    public let v1NewTaskEntryAvailable: Bool

    public init(
        newTaskEntryOwner: ConversationShellVersion,
        v2HistoryAvailable: Bool,
        v2NewTaskEntryAvailable: Bool,
        v1NewTaskEntryAvailable: Bool
    ) {
        self.newTaskEntryOwner = newTaskEntryOwner
        self.v2HistoryAvailable = v2HistoryAvailable
        self.v2NewTaskEntryAvailable = v2NewTaskEntryAvailable
        self.v1NewTaskEntryAvailable = v1NewTaskEntryAvailable
    }
}

public enum AgentConversationShellPolicy {

    /// 切换决策（由控制面状态驱动）：
    /// - `enabled`：开放 V2 新任务入口；
    /// - `draining`：隐藏/禁用 V2 新执行入口，但只读历史可并存；
    /// - `disabled`：保留 V2 只读历史/排空状态并允许 V1 新任务入口。
    public static func switchDecision(controlState: AgentConversationV2ControlState) -> ConversationShellSwitchDecision {
        switch controlState {
        case .enabled:
            return ConversationShellSwitchDecision(
                newTaskEntryOwner: .v2,
                v2HistoryAvailable: true,
                v2NewTaskEntryAvailable: true,
                v1NewTaskEntryAvailable: false
            )
        case .draining:
            return ConversationShellSwitchDecision(
                newTaskEntryOwner: .v1,
                v2HistoryAvailable: true,
                v2NewTaskEntryAvailable: false,
                v1NewTaskEntryAvailable: true
            )
        case .disabled:
            return ConversationShellSwitchDecision(
                newTaskEntryOwner: .v1,
                v2HistoryAvailable: true,
                v2NewTaskEntryAvailable: false,
                v1NewTaskEntryAvailable: true
            )
        }
    }

    /// 装配点必须经 Control Coordinator（不得绕过直接读 flag 缓存）。
    public static func assemblyMustUseControlCoordinator() -> Bool { true }

    /// V2/V1 以清晰标签区分。
    public static func versionLabel(_ version: ConversationShellVersion) -> String {
        version == .v2 ? "V2 会话" : "V1 会话"
    }
}

/// Layout budget for the live conversation shell.  Timeline and Composer are
/// the primary workflow; approval/terminal surfaces are auxiliary and must
/// yield space before either of those two surfaces disappears.
public enum AgentConversationShellLayout {
    public static let minimumTimelineHeight: CGFloat = 96
    public static let minimumComposerHeight: CGFloat = 88
    // The input viewport remains usable at 88pt; keeping it bounded in the
    // compact shell leaves room for the toolbar, timeline and approval row.
    public static let compactMaximumComposerHeight: CGFloat = 88
    public static let minimumDecisionHeight: CGFloat = 148
    public static let minimumTerminalHeaderHeight: CGFloat = 42
    public static let maximumDecisionHeight: CGFloat = 220
    // Header + compact scroll viewport + action row. The command/audit
    // document itself remains unbounded and scrolls inside the viewport.
    public static let compactMaximumDecisionHeight: CGFloat = 120
    public static let maximumTerminalHeight: CGFloat = 264
    public static let compactMaximumTerminalHeight: CGFloat = 136
    public static let compactHeightThreshold: CGFloat = 520
    public static let compactDecisionHeightThreshold: CGFloat = 600

    public static func timelineKeepsPriorityOverAuxiliarySurfaces() -> Bool { true }
    public static func composerKeepsPriorityOverAuxiliarySurfaces() -> Bool { true }
}

// MARK: - 装配点抽象（Workbench/Inspector 经此注入；避免绕过 Control Coordinator）

/// 装配点（Workbench/Inspector）实现此协议；切换决策必须来自 Control Coordinator。
public protocol ConversationShellAssembly: AnyObject {
    /// 返回当前控制状态（经 AgentConversationV2ControlCoordinator，非 flag 缓存）。
    var controlState: AgentConversationV2ControlState? { get }
    /// 装配 V2 会话壳（Composer、时间线与工具栏）。
    func assembleV2Shell() -> NSView
    /// 装配 V1 兼容面板（AIAssistantPanelViewController 保持可运行）。
    func assembleV1Panel() -> NSView
}

// MARK: - AgentConversationViewController

/// V2 会话壳：装配 Composer / 时间线 / 工具栏；
/// 接入 `ConversationActorRegistry` 保证跨窗口同一会话同一 Actor。
@MainActor
public final class AgentConversationViewController: NSViewController {
    public let sessionID: String
    public let registry: ConversationActorRegistry
    private var composerView: NSView?
    private weak var composerTextView: AgentComposerTextView?
    private var timelinePlaceholder: NSView?
    private var toolbarPlaceholder: NSView?
    private var decisionView: NSView?
    private var localAgentTerminalView: NSView?
    private var shellStack: NSStackView?
    private var shellLayoutConstraints: [NSLayoutConstraint] = []
    private var decisionMaximumHeightConstraint: NSLayoutConstraint?
    private var composerMaximumHeightConstraint: NSLayoutConstraint?
    private var terminalMaximumHeightConstraint: NSLayoutConstraint?
    private var isUpdatingAdaptiveLayout = false
    public private(set) var isHistoryOnlyPresentation = false
    public private(set) var composerController: AgentComposerViewController?
    public private(set) var timelineController: ConversationTimelineViewController?
    public private(set) var toolbarController: ConversationToolbarViewController?
    public private(set) var decisionController: ToolDecisionViewController?
    private(set) var localAgentTerminalController: LocalAgentTerminalBlockViewController?

    public init(sessionID: String, registry: ConversationActorRegistry = .shared) {
        self.sessionID = sessionID
        self.registry = registry
        super.init(nibName: nil, bundle: nil)
    }

    public override func loadView() {
        let root = ConversationShellRootView(
            frame: NSRect(x: 0, y: 0, width: 720, height: AgentConversationShellLayout.compactHeightThreshold)
        )
        root.setAccessibilityIdentifier("Stacio.AI.conversationShell")
        root.onLayout = { [weak self] in
            self?.updateAdaptiveLayout()
        }
        view = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func actor(
        store: ConversationSessionStore,
        sealing: ConversationSealing,
        initialState: ConversationSessionState
    ) -> ConversationSessionActor {
        registry.actor(for: sessionID, store: store, sealing: sealing, initialState: initialState)
    }

    /// 装配 Composer / 时间线 / 工具栏。
    /// 挂载为纵向布局：工具栏顶部、时间线弹性、Composer 底部。
    public func assemble(composer: NSView, timelinePlaceholder: NSView, toolbarPlaceholder: NSView) {
        self.composerView = composer
        self.composerTextView = composer as? AgentComposerTextView
        self.timelinePlaceholder = timelinePlaceholder
        self.toolbarPlaceholder = toolbarPlaceholder
        mountParts()
    }

    /// 只读历史壳只挂载时间线，不创建 Composer、工具审批或终端输入面。
    public func assembleReadOnlyHistory(timeline: ConversationTimelineViewController) {
        isHistoryOnlyPresentation = true
        timelineController = timeline
        timelinePlaceholder = timeline.view
        if timeline.parent !== self {
            addChild(timeline)
        }
        mountParts()
    }

    /// 控制面从 enabled 进入 draining/disabled 时，保留正在结算的桥接，
    /// 但立即移除所有可产生新输入或外部动作的交互面。
    public func setHistoryOnlyPresentation(_ enabled: Bool) {
        guard isHistoryOnlyPresentation != enabled else { return }
        isHistoryOnlyPresentation = enabled
        mountParts()
    }

    public func assemble(
        composer: AgentComposerViewController,
        timeline: ConversationTimelineViewController,
        toolbar: ConversationToolbarViewController,
        decision: ToolDecisionViewController? = nil
    ) {
        assemble(
            composer: composer,
            timeline: timeline,
            toolbar: toolbar,
            decision: decision,
            localAgentTerminal: nil
        )
    }

    func assemble(
        composer: AgentComposerViewController,
        timeline: ConversationTimelineViewController,
        toolbar: ConversationToolbarViewController,
        decision: ToolDecisionViewController?,
        localAgentTerminal: LocalAgentTerminalBlockViewController?
    ) {
        composerController = composer
        timelineController = timeline
        toolbarController = toolbar
        decisionController = decision
        localAgentTerminalController = localAgentTerminal
        composerView = composer.view
        composerTextView = composer.textView
        timelinePlaceholder = timeline.view
        toolbarPlaceholder = toolbar.view
        decisionView = decision?.view
        localAgentTerminalView = localAgentTerminal?.view
        var children: [NSViewController] = [toolbar, timeline, composer]
        if let decision { children.append(decision) }
        if let localAgentTerminal { children.append(localAgentTerminal) }
        children.forEach { child in
            if child.parent !== self {
                addChild(child)
            }
        }
        mountParts()
    }

    public func hasAssembledParts() -> Bool {
        composerView != nil && timelinePlaceholder != nil && toolbarPlaceholder != nil
    }

    public func focusComposer() {
        guard isHistoryOnlyPresentation == false else { return }
        guard let composerTextView else { return }
        view.window?.makeFirstResponder(composerTextView)
    }

    public func prefillComposer(_ text: String) {
        guard isHistoryOnlyPresentation == false else { return }
        if let composerController {
            composerController.setText(text, focus: true)
            return
        }
        guard let composerTextView else { return }
        composerTextView.string = text
        composerTextView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        focusComposer()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateAdaptiveLayout()
    }

    private func updateAdaptiveLayout() {
        guard isHistoryOnlyPresentation == false,
              isUpdatingAdaptiveLayout == false
        else { return }
        let shouldUseCompactAuxiliaryLayout = view.bounds.height < AgentConversationShellLayout.compactHeightThreshold
        let shouldUseCompactDecisionLayout = view.bounds.height
            < AgentConversationShellLayout.compactDecisionHeightThreshold
        isUpdatingAdaptiveLayout = true
        localAgentTerminalController?.setCompactPresentation(shouldUseCompactAuxiliaryLayout)
        decisionController?.setCompactPresentation(shouldUseCompactDecisionLayout)
        decisionMaximumHeightConstraint?.constant = shouldUseCompactDecisionLayout
            ? AgentConversationShellLayout.compactMaximumDecisionHeight
            : AgentConversationShellLayout.maximumDecisionHeight
        composerMaximumHeightConstraint?.constant = shouldUseCompactAuxiliaryLayout
            ? AgentConversationShellLayout.compactMaximumComposerHeight
            : 10_000
        terminalMaximumHeightConstraint?.constant = shouldUseCompactDecisionLayout
            ? AgentConversationShellLayout.compactMaximumTerminalHeight
            : AgentConversationShellLayout.maximumTerminalHeight
        // A decision is the active approval boundary. In the smallest shell,
        // hide the auxiliary terminal surface as a whole so its stale frame
        // cannot consume stack space or escape the shell bounds. Restore it
        // whenever the shell grows again; the Local Agent controller retains
        // its PTY/session state independently of this presentation choice.
        let suppressTerminal = shouldUseCompactAuxiliaryLayout
            && decisionView?.isHidden == false
        localAgentTerminalView?.isHidden = suppressTerminal
        view.needsLayout = true
        isUpdatingAdaptiveLayout = false
    }

    private func mountParts() {
        NSLayoutConstraint.deactivate(shellLayoutConstraints)
        shellLayoutConstraints.removeAll()
        decisionMaximumHeightConstraint = nil
        composerMaximumHeightConstraint = nil
        terminalMaximumHeightConstraint = nil
        shellStack = nil
        if isHistoryOnlyPresentation {
            guard let timelinePlaceholder else { return }
            view.subviews.forEach { $0.removeFromSuperview() }
            timelinePlaceholder.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(timelinePlaceholder)
            let historyConstraints = [
                timelinePlaceholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                timelinePlaceholder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                timelinePlaceholder.topAnchor.constraint(equalTo: view.topAnchor),
                timelinePlaceholder.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ]
            shellLayoutConstraints = historyConstraints
            NSLayoutConstraint.activate(historyConstraints)
            return
        }
        guard let composerView, let timelinePlaceholder, let toolbarPlaceholder else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        var arrangedViews = [toolbarPlaceholder, timelinePlaceholder]
        if let localAgentTerminalView { arrangedViews.append(localAgentTerminalView) }
        if let decisionView { arrangedViews.append(decisionView) }
        arrangedViews.append(composerView)
        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("Stacio.AI.conversationShell.stack")
        view.addSubview(stack)
        shellStack = stack
        toolbarPlaceholder.setContentHuggingPriority(.required, for: .vertical)
        composerView.setContentHuggingPriority(.required, for: .vertical)
        decisionView?.setContentHuggingPriority(.defaultHigh, for: .vertical)
        localAgentTerminalView?.setContentHuggingPriority(.defaultHigh, for: .vertical)
        timelinePlaceholder.setContentHuggingPriority(.defaultLow, for: .vertical)
        decisionView?.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        localAgentTerminalView?.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        timelinePlaceholder.setContentCompressionResistancePriority(.required, for: .vertical)
        // The Composer owns an internally scrollable input viewport. Its hard
        // minimum below protects the controls, while the intrinsic height must
        // remain compressible so a short shell can reclaim input viewport space
        // instead of pushing the toolbar outside the root bounds.
        composerView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)

        let timelineMinimum = timelinePlaceholder.heightAnchor.constraint(
            greaterThanOrEqualToConstant: AgentConversationShellLayout.minimumTimelineHeight
        )
        timelineMinimum.identifier = "Stacio.AI.conversationShell.timelineMinimum"
        let composerMinimum = composerView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: AgentConversationShellLayout.minimumComposerHeight
        )
        composerMinimum.identifier = "Stacio.AI.conversationShell.composerMinimum"
        let composerMaximum = composerView.heightAnchor.constraint(lessThanOrEqualToConstant: 10_000)
        composerMaximum.identifier = "Stacio.AI.conversationShell.composerCompactMaximum"
        composerMaximumHeightConstraint = composerMaximum
        shellLayoutConstraints.append(contentsOf: [timelineMinimum, composerMinimum, composerMaximum])

        if let decisionView {
            let minimum = decisionView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: AgentConversationShellLayout.minimumDecisionHeight
            )
            minimum.priority = .defaultHigh
            minimum.identifier = "Stacio.AI.conversationShell.decisionMinimum"
            let maximum = decisionView.heightAnchor.constraint(
                lessThanOrEqualToConstant: AgentConversationShellLayout.maximumDecisionHeight
            )
            maximum.priority = .required
            maximum.identifier = "Stacio.AI.conversationShell.decisionMaximum"
            decisionMaximumHeightConstraint = maximum
            shellLayoutConstraints.append(contentsOf: [minimum, maximum])
        }
        if let localAgentTerminalView {
            let minimum = localAgentTerminalView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: AgentConversationShellLayout.minimumTerminalHeaderHeight
            )
            minimum.priority = .defaultHigh
            minimum.identifier = "Stacio.AI.conversationShell.terminalMinimum"
            let maximum = localAgentTerminalView.heightAnchor.constraint(
                lessThanOrEqualToConstant: AgentConversationShellLayout.maximumTerminalHeight
            )
            maximum.priority = .required
            maximum.identifier = "Stacio.AI.conversationShell.terminalMaximum"
            terminalMaximumHeightConstraint = maximum
            shellLayoutConstraints.append(contentsOf: [minimum, maximum])
        }
        shellLayoutConstraints.append(contentsOf: [
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for arrangedView in arrangedViews {
            shellLayoutConstraints.append(contentsOf: [
                arrangedView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                arrangedView.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate(shellLayoutConstraints)
    }
}

@MainActor
private final class ConversationShellRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        onLayout?()
        super.layout()
    }
}
