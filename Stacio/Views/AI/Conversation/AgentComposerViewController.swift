import AppKit
import Foundation

// MARK: - Composer 执行身份（P5-2）

/// Composer 持续显示的执行身份：`Native · Kimi` / `Stacio Agent · Codex · 受控` / `Stacio Agent · Codex · 终端透传`。
public enum ComposerExecutionIdentity: Equatable, Sendable {
    case native(modelDisplayName: String)
    case localAgent(runtimeName: String, mode: LocalAgentExecutionMode)
}

public enum LocalAgentExecutionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case controlled
    case terminalPassthrough

    public var displaySuffix: String {
        switch self {
        case .controlled: return "受控"
        case .terminalPassthrough: return "终端透传"
        }
    }
}

// MARK: - 当前 Turn 工作方式（Local Agent 是 Runtime，不是第四种工作方式）

public enum TurnWorkMode: String, Codable, CaseIterable, Equatable, Sendable {
    case agent
    case planFirst
    case answerOnly

    public var displayName: String {
        switch self {
        case .agent: return "Agent"
        case .planFirst: return "先规划"
        case .answerOnly: return "仅回答"
        }
    }
}

/// 当前 Turn 执行选择（每次询问/真实终端/后台虚拟终端），不与模型菜单混为一项。
public enum TurnExecutionChoice: String, Codable, CaseIterable, Equatable, Sendable {
    /// Settings 选择 `ask` 时的未决状态；不能被写入一个新的 Turn。
    case ask
    case realTerminal
    case backgroundVirtualTerminal
}

// MARK: - 布局度量

public enum AgentComposerLayout {
    public static let minInputLines: CGFloat = 2
    public static let maxInputHeight: CGFloat = 180
    public static let maxInputHeightRatio: CGFloat = 0.35
    public static let lineHeight: CGFloat = 20

    /// 输入区高度：最小约两行；随内容增长到 `min(180pt, 会话可用高度 35%)`；
    /// 达限后内部滚动（不挤压时间线）。
    public static func inputHeight(contentHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let minHeight = lineHeight * minInputLines
        let cap = min(maxInputHeight, availableHeight * maxInputHeightRatio)
        return max(minHeight, min(contentHeight, cap))
    }

    /// 达限内部滚动：内容超过输入区高度时滚动而非挤压。
    public static func scrollsInternallyWhenAtLimit(contentHeight: CGFloat, availableHeight: CGFloat) -> Bool {
        contentHeight > inputHeight(contentHeight: contentHeight, availableHeight: availableHeight)
    }

    /// 附件区/队列区仅在有内容时出现。
    public static func attachmentAreaVisible(itemCount: Int) -> Bool { itemCount > 0 }
    public static func queueAreaVisible(itemCount: Int) -> Bool { itemCount > 0 }

    /// 主操作键固定右下；Native 会话在发送后由同一键切换为 Stop。
    public static func sendPinnedToBottomRight() -> Bool { true }
    public static func stopNeverShiftsSend() -> Bool { true }

    /// 窄宽度下 Runtime/模型/推理强度收进菜单，主操作键始终可见。
    public static func narrowModeCollectsRuntimeModelIntoMenu(width: CGFloat, threshold: CGFloat = 640) -> Bool {
        width < threshold
    }
    public static func usesSinglePrimaryActionForNativeConversation() -> Bool { true }
}

// MARK: - 语义表

public struct ComposerModelEntry: Equatable, Sendable {
    public let modelID: String
    public let syncedFromUpstream: Bool
    public let enabled: Bool

    public init(modelID: String, syncedFromUpstream: Bool, enabled: Bool) {
        self.modelID = modelID
        self.syncedFromUpstream = syncedFromUpstream
        self.enabled = enabled
    }
}

public enum AgentComposerSemantics {

    /// Composer 身份显示：`Native · Kimi` / `Stacio Agent · Codex · 受控` / `Stacio Agent · Codex · 终端透传`。
    public static func identityDisplay(_ identity: ComposerExecutionIdentity) -> String {
        switch identity {
        case .native(let modelDisplayName):
            return "Native · \(modelDisplayName)"
        case .localAgent(let runtimeName, let mode):
            return "Stacio Agent · \(runtimeName) · \(mode.displaySuffix)"
        }
    }

    /// 模型菜单只显示上游同步且已启用模型。
    public static func modelMenuEntries(_ models: [ComposerModelEntry]) -> [ComposerModelEntry] {
        models.filter { $0.syncedFromUpstream && $0.enabled }
    }

    /// 推理强度只显示当前模型支持档位。
    public static func reasoningLevels(supportedLevels: [String]) -> [String] {
        supportedLevels
    }

    /// Local Agent 是 Runtime 不是第四种工作方式。
    public static func localAgentIsRuntimeNotWorkMode() -> Bool { true }
    public static func workModes() -> [TurnWorkMode] { TurnWorkMode.allCases }

    /// 上下文用量环只显示 Runtime 可验证预算；Local Agent 未验证 contextUsageReporting
    /// 显示「已发送 N KiB · CLI 内部上下文未知」。
    public static func contextUsageDisplay(
        runtimeVerifiedBudgetKiB: Int?, sentKiB: Int
    ) -> String {
        guard let budget = runtimeVerifiedBudgetKiB, budget > 0 else {
            return "已发送 \(sentKiB) KiB · CLI 内部上下文未知"
        }
        let percent = min(100, Int((Double(sentKiB) / Double(budget)) * 100))
        return "已发送 \(sentKiB) KiB / \(budget) KiB (\(percent)%)"
    }

    /// 目标身份菜单：远端/本地 targetWorkingDirectory 与 Mac 本地 AgentProcessWorkingDirectory 分别显示。
    public static func targetDirectoryDisplay(
        remoteOrLocalTargetDirectory: String?, macLocalWorkingDirectory: String?
    ) -> String {
        let parts = [remoteOrLocalTargetDirectory, macLocalWorkingDirectory].compactMap { $0 }
        return parts.isEmpty ? "未选择目标目录" : parts.joined(separator: " · ")
    }
}

// MARK: - 运行中语义表（§12.4）

public enum ComposerRunPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case preparing
    case waitingForCapacity
    case startingRuntime
    case streaming
    case toolProposed
    case executingTool
    case pausing
    case paused
    case awaitingUser
    case awaitingApproval
    case takeoverPending
    case editingQueuedItem
    case stopping
    case takenOver

    /// 活动 Turn（显示 Stop 的相位集合）。
    public var showsStop: Bool {
        switch self {
        case .idle, .editingQueuedItem, .takenOver:
            return false
        default:
            return true
        }
    }
}

public enum AgentComposerRunStateMachine {
    /// Send 在活动 Turn 中用于排入下一轮；仅 Stopping 暂缓新提交。
    public static func sendAvailable(phase: ComposerRunPhase) -> Bool {
        phase != .stopping
    }
    public static func stopAvailable(phase: ComposerRunPhase) -> Bool {
        phase.showsStop
    }
}

public struct ComposerRuntimeOption: Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

// MARK: - Native Composer controller

@MainActor
public final class AgentComposerViewController: NSViewController, NSTextViewDelegate {
    public let textView = AgentComposerTextView()
    public let pendingQueueView = PendingInputQueueView()

    /// Return true only after the submission has crossed its durable boundary.
    /// The Composer keeps one request in flight so a double-click/rapid Return
    /// cannot turn the same editor contents into both a Turn and a queued item.
    public var onSubmit: ((String) async -> Bool)?
    public var onExplicitQueue: ((String) async -> Bool)?
    public var onStop: (() -> Void)?
    /// Escape 由 TextView 统一路由；外层负责关闭当前拥有的 transient UI。
    public var onEscape: (() -> Void)?
    public var onDraftChange: ((String) -> Void)?
    public var onAddAttachment: (() -> Void)? {
        didSet { updateOptionalActionVisibility() }
    }
    public var onSelectContext: (() -> Void)? {
        didSet { updateOptionalActionVisibility() }
    }
    public var onWorkModeChange: ((TurnWorkMode) -> Void)?
    public var onExecutionChoiceChange: ((TurnExecutionChoice) -> Void)?
    public var onRuntimeSelectionChange: ((String) -> Bool)?
    /// Durable Runtime selection may require an async store commit. When set,
    /// the popup remains on its previous value until completion reports success.
    public var onRuntimeSelectionRequest: ((String, @escaping (Bool) -> Void) -> Void)?

    private let inputScrollView = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "向排查助手提问")
    private let attachmentsStack = NSStackView()
    private let controlBar = NSStackView()
    private let addButton = NSButton()
    private let contextButton = NSButton()
    private let identityPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let reasoningPopup = NSPopUpButton()
    private let workModeControl = NSSegmentedControl()
    private let executionPopup = NSPopUpButton()
    private let contextUsageButton = NSButton()
    private let compactOptionsButton = NSButton()
    private var pendingRuntimeSelectionID: String?
    private let sendButton = NSButton()
    private var inputHeightConstraint: NSLayoutConstraint!
    private var runPhase: ComposerRunPhase = .idle
    private var currentIdentity = "Native · 未配置"
    private var currentModels: [String] = []
    private var currentReasoningLevels: [String] = []
    private var runtimeOptions = [ComposerRuntimeOption(id: "native", title: "Native · 未配置")]
    private var selectedRuntimeOptionID = "native"
    private var terminalPassthroughRuntimeName: String?
    private var terminalPassthroughIsAvailable = true
    private var terminalPassthroughIsRunning = false
    private var terminalPassthroughIsStopping = false
    private var queuePullInProgress = false
    private var submissionRequestInFlight = false
    private var primaryStopRequested = false

    public override func loadView() {
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            frame: NSRect(x: 0, y: 0, width: 720, height: 150),
            fallbackMaterial: .popover,
            cornerRadius: 10
        )
        surface.setAccessibilityIdentifier("Stacio.AI.composer")
        view = surface
        setupHierarchy()
        configureTextView()
        configureControls()
        setRunPhase(.idle)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateInputHeight()
        updateResponsiveControls()
    }

    public var text: String {
        get { textView.string }
        set { setText(newValue) }
    }

    /// The text view owns Return routing.  The send button deliberately has
    /// no `keyEquivalent`, otherwise AppKit can invoke it before
    /// `AgentComposerTextView.keyDown` gets a chance to honor this mode.
    public var sendKeyMode: SendKeyMode {
        get { textView.sendKeyMode }
        set {
            textView.sendKeyMode = newValue
            sendButton.keyEquivalent = ""
        }
    }

    /// Native 会话与终端透传都只使用同一个主操作键。
    /// PTY 的进程终止仍通过 onStop 透传到终端控制器，不额外占用一个按钮。
    public var isStopVisible: Bool {
        return primaryActionShowsStop
    }
    public var queueItemCount: Int { pendingQueueView.itemCount }
    public var selectedRuntimeID: String { selectedRuntimeOptionID }
    public var runtimeOptionTitles: [String] { runtimeOptions.map(\.title) }
    public var sendButtonKeyEquivalentForTesting: String { sendButton.keyEquivalent }
    public var isSendEnabledForTesting: Bool { sendButton.isEnabled }
    public var isTerminalPassthroughSelected: Bool { terminalPassthroughRuntimeName != nil }
    public var isQueuePullInProgressForTesting: Bool { queuePullInProgress }
    public var isSubmissionRequestInFlightForTesting: Bool { submissionRequestInFlight }
    public var isIndependentStopVisibleForTesting: Bool {
        false
    }
    /// The Composer owns exactly one visible Send/Stop control.  Keeping this
    /// query on the controller makes it possible for host-shell tests to catch
    /// an accidentally reintroduced second stop button.
    public var primaryActionButtonCountForTesting: Int {
        guard isViewLoaded else { return 0 }
        func count(in root: NSView) -> Int {
            root.subviews.reduce(into: 0) { result, child in
                if let button = child as? NSButton {
                    let label = button.accessibilityLabel() ?? ""
                    let isPrimaryAction = button.accessibilityIdentifier() == "Stacio.AI.composer.send"
                        || label == "发送"
                        || label == "停止当前任务"
                        || label == "停止 Stacio Agent 终端"
                    if isPrimaryAction {
                        result += 1
                    }
                }
                result += count(in: child)
            }
        }
        return count(in: view)
    }
    public var primaryActionAccessibilityLabelForTesting: String? {
        sendButton.accessibilityLabel()
    }
    public var selectedWorkMode: TurnWorkMode {
        guard TurnWorkMode.allCases.indices.contains(workModeControl.selectedSegment) else {
            return .agent
        }
        return TurnWorkMode.allCases[workModeControl.selectedSegment]
    }
    public var selectedExecutionChoice: TurnExecutionChoice {
        switch executionPopup.indexOfSelectedItem {
        case 2: return .backgroundVirtualTerminal
        case 1: return .realTerminal
        default: return .ask
        }
    }

    public func setText(
        _ value: String,
        focus: Bool = false,
        notifyDraftChange: Bool = true
    ) {
        textView.string = value
        textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        updateDraftPresentation(notifyDraftChange: notifyDraftChange)
        if focus {
            view.window?.makeFirstResponder(textView)
        }
    }

    public func clearIfUnchanged(_ submitted: String) {
        guard textView.string == submitted else { return }
        setText("")
    }

    /// Freeze the editor while a queued input is moved into the durable draft.
    /// This prevents typing from racing the queue-remove/draft-write transaction.
    public func beginQueuePull() -> String? {
        guard queuePullInProgress == false,
              textView.hasMarkedText == false,
              textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        queuePullInProgress = true
        textView.isEditable = false
        updateRunControls()
        return textView.string
    }

    public func finishQueuePull(with pulledText: String?) {
        guard queuePullInProgress else { return }
        if let pulledText {
            setText(pulledText, focus: false)
        }
        queuePullInProgress = false
        textView.isEditable = true
        updateRunControls()
        if pulledText != nil {
            view.window?.makeFirstResponder(textView)
        }
    }

    public func setRunPhase(_ phase: ComposerRunPhase) {
        runPhase = phase
        if phase.showsStop == false, submissionRequestInFlight == false {
            primaryStopRequested = false
        }
        updateRunControls()
    }

    public func setRuntimeIdentity(
        _ identity: String,
        models: [String] = [],
        selectedModel: String? = nil,
        reasoningLevels: [String] = []
    ) {
        currentIdentity = identity
        if let selectedIndex = runtimeOptions.firstIndex(where: { $0.id == selectedRuntimeOptionID }) {
            runtimeOptions[selectedIndex] = ComposerRuntimeOption(
                id: selectedRuntimeOptionID,
                title: identity
            )
        } else {
            runtimeOptions = [ComposerRuntimeOption(id: "native", title: identity)]
            selectedRuntimeOptionID = "native"
        }
        currentModels = models
        currentReasoningLevels = reasoningLevels
        reloadRuntimePopup()
        modelPopup.removeAllItems()
        modelPopup.addItems(withTitles: models)
        if let selectedModel { modelPopup.selectItem(withTitle: selectedModel) }
        modelPopup.isHidden = models.isEmpty
        reasoningPopup.removeAllItems()
        reasoningPopup.addItems(withTitles: reasoningLevels)
        reasoningPopup.isHidden = reasoningLevels.isEmpty
        rebuildCompactMenu()
    }

    public func setRuntimeOptions(_ options: [ComposerRuntimeOption], selectedID: String) {
        guard options.isEmpty == false else { return }
        runtimeOptions = options
        selectedRuntimeOptionID = options.contains(where: { $0.id == selectedID })
            ? selectedID
            : options[0].id
        currentIdentity = runtimeOptions.first(where: { $0.id == selectedRuntimeOptionID })?.title
            ?? runtimeOptions[0].title
        reloadRuntimePopup()
        rebuildCompactMenu()
        updateResponsiveControls()
    }

    public func setTerminalPassthroughState(
        runtimeName: String?,
        isAvailable: Bool = true,
        isRunning: Bool = false,
        isStopping: Bool = false
    ) {
        terminalPassthroughRuntimeName = runtimeName
        terminalPassthroughIsAvailable = runtimeName == nil || isAvailable
        terminalPassthroughIsRunning = isRunning
        terminalPassthroughIsStopping = isStopping
        if runtimeName != nil {
            setWorkMode(.agent)
        }
        updateRunControls()
        updateResponsiveControls()
    }

    public func setContextUsage(_ display: String) {
        contextUsageButton.title = display
        contextUsageButton.toolTip = display
        contextUsageButton.isHidden = display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func setWorkMode(_ mode: TurnWorkMode) {
        guard let index = TurnWorkMode.allCases.firstIndex(of: mode) else { return }
        workModeControl.selectedSegment = index
    }

    public func setExecutionChoice(_ choice: TurnExecutionChoice) {
        switch choice {
        case .ask: executionPopup.selectItem(at: 0)
        case .realTerminal: executionPopup.selectItem(at: 1)
        case .backgroundVirtualTerminal: executionPopup.selectItem(at: 2)
        }
        updateRunControls()
    }

    public func applyQueue(
        _ items: [QueuedInput],
        autoAdvancePaused: Bool,
        forceRefresh: Bool = false
    ) {
        pendingQueueView.apply(
            items: items,
            autoAdvancePaused: autoAdvancePaused,
            forceRefresh: forceRefresh
        )
        view.invalidateIntrinsicContentSize()
    }

    public func setAttachments(_ titles: [String]) {
        attachmentsStack.arrangedSubviews.forEach {
            attachmentsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for title in titles {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            attachmentsStack.addArrangedSubview(label)
        }
        attachmentsStack.isHidden = titles.isEmpty
    }

    public func textDidChange(_ notification: Notification) {
        updateDraftPresentation(notifyDraftChange: true)
    }

    private func setupHierarchy() {
        pendingQueueView.translatesAutoresizingMaskIntoConstraints = false
        attachmentsStack.orientation = .horizontal
        attachmentsStack.alignment = .centerY
        attachmentsStack.spacing = 6
        attachmentsStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentsStack.isHidden = true

        inputScrollView.translatesAutoresizingMaskIntoConstraints = false
        inputScrollView.hasVerticalScroller = true
        inputScrollView.autohidesScrollers = true
        inputScrollView.drawsBackground = false
        inputScrollView.borderType = .noBorder

        textView.frame = inputScrollView.contentView.bounds
        inputScrollView.documentView = textView

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.setAccessibilityElement(false)

        controlBar.orientation = .horizontal
        controlBar.alignment = .centerY
        controlBar.spacing = 6
        controlBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(pendingQueueView)
        view.addSubview(attachmentsStack)
        view.addSubview(inputScrollView)
        view.addSubview(placeholderLabel)
        view.addSubview(controlBar)

        inputHeightConstraint = inputScrollView.heightAnchor.constraint(equalToConstant: 52)
        inputHeightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            pendingQueueView.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            pendingQueueView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            pendingQueueView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            attachmentsStack.topAnchor.constraint(equalTo: pendingQueueView.bottomAnchor, constant: 4),
            attachmentsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            attachmentsStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            inputScrollView.topAnchor.constraint(equalTo: attachmentsStack.bottomAnchor, constant: 2),
            inputScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            inputScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            inputHeightConstraint,
            placeholderLabel.topAnchor.constraint(equalTo: inputScrollView.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputScrollView.leadingAnchor, constant: 10),
            controlBar.topAnchor.constraint(equalTo: inputScrollView.bottomAnchor, constant: 4),
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            controlBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            controlBar.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func configureTextView() {
        textView.delegate = self
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: inputScrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityIdentifier("Stacio.AI.composer.text")
        textView.setAccessibilityLabel("向排查助手提问")
        textView.onSend = { [weak self] in self?.submit() }
        textView.onQueue = { [weak self] in self?.queueExplicitly() }
        textView.onStop = { [weak self] in self?.requestPrimaryStop() }
        textView.onEscape = { [weak self] in
            self?.onEscape?()
        }
    }

    private func configureControls() {
        configureIconButton(addButton, symbol: "plus", tooltip: "添加附件", action: #selector(addAttachment))
        configureIconButton(contextButton, symbol: "at", tooltip: "添加上下文", action: #selector(selectContext))
        updateOptionalActionVisibility()

        identityPopup.controlSize = .small
        identityPopup.addItem(withTitle: currentIdentity)
        identityPopup.toolTip = "当前 Runtime"
        identityPopup.setAccessibilityIdentifier("Stacio.AI.composer.runtime")
        identityPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identityPopup.target = self
        identityPopup.action = #selector(runtimeSelectionChanged(_:))

        modelPopup.controlSize = .small
        modelPopup.toolTip = "模型"
        modelPopup.isHidden = true
        modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reasoningPopup.controlSize = .small
        reasoningPopup.toolTip = "推理强度"
        reasoningPopup.isHidden = true
        reasoningPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        workModeControl.segmentCount = TurnWorkMode.allCases.count
        for (index, mode) in TurnWorkMode.allCases.enumerated() {
            workModeControl.setLabel(mode.displayName, forSegment: index)
        }
        workModeControl.selectedSegment = 0
        workModeControl.trackingMode = .selectOne
        workModeControl.controlSize = .small
        workModeControl.target = self
        workModeControl.action = #selector(workModeChanged(_:))
        workModeControl.setAccessibilityIdentifier("Stacio.AI.composer.workMode")

        executionPopup.controlSize = .small
        executionPopup.addItems(withTitles: ["选择执行终端", "真实终端", "后台虚拟终端"])
        // Keep the UI's initial snapshot aligned with ComposerDraftPersistence
        // and SessionRuntimeBridge, whose safe compatibility default is the
        // existing real terminal. An explicit `ask` setting is still applied
        // later through setExecutionChoice(.ask).
        executionPopup.selectItem(at: 1)
        executionPopup.target = self
        executionPopup.action = #selector(executionChoiceChanged(_:))
        executionPopup.toolTip = "执行终端"
        executionPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contextUsageButton.title = "上下文"
        contextUsageButton.bezelStyle = .inline
        contextUsageButton.controlSize = .small
        contextUsageButton.isBordered = false
        contextUsageButton.isEnabled = false
        contextUsageButton.isHidden = true

        configureIconButton(compactOptionsButton, symbol: "slider.horizontal.3", tooltip: "Runtime 与模型", action: #selector(showCompactOptions(_:)))
        compactOptionsButton.setAccessibilityIdentifier("Stacio.AI.composer.compactOptions")
        compactOptionsButton.isHidden = true

        // Native 与 terminal passthrough 都复用同一个 Send/Stop 主操作键。
        configureIconButton(sendButton, symbol: "arrow.up", tooltip: "发送", action: #selector(primaryAction))
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.layer?.cornerRadius = 17
        sendButton.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(sendButton, color: .controlAccentColor)
        sendButton.contentTintColor = .white
        // Return/Command+Return are routed by the NSTextView so IME and the
        // configured sendKeyMode cannot be bypassed by AppKit's default-button
        // key-equivalent handling.
        sendButton.keyEquivalent = ""
        sendButton.setAccessibilityIdentifier("Stacio.AI.composer.send")
        sendButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        [addButton, contextButton, identityPopup, modelPopup, reasoningPopup, workModeControl,
         executionPopup, contextUsageButton, compactOptionsButton, NSView(), sendButton]
            .forEach(controlBar.addArrangedSubview)
        rebuildCompactMenu()
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        // AppKit's accessory-bar bezel renders as a white square in the dark
        // Inspector.  These controls are secondary actions, so use the same
        // quiet borderless treatment as the legacy Inspector Composer.
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 14
        button.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: StacioDesignSystem.dynamicColor(.controlBackgroundColor, alpha: 0.78)
        )
        button.contentTintColor = .secondaryLabelColor
        button.controlSize = .small
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateInputHeight() {
        guard isViewLoaded else { return }
        let availableHeight = max(240, view.window?.contentLayoutRect.height ?? 520)
        let width = max(80, inputScrollView.contentSize.width)
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? AgentComposerLayout.lineHeight * 2
        textView.setFrameSize(NSSize(
            width: width,
            height: max(inputScrollView.contentSize.height, ceil(used + textView.textContainerInset.height * 2))
        ))
        inputHeightConstraint.constant = AgentComposerLayout.inputHeight(
            contentHeight: used + textView.textContainerInset.height * 2,
            availableHeight: availableHeight
        )
        inputScrollView.hasVerticalScroller = AgentComposerLayout.scrollsInternallyWhenAtLimit(
            contentHeight: used + textView.textContainerInset.height * 2,
            availableHeight: availableHeight
        )
    }

    private func updateDraftPresentation(notifyDraftChange: Bool) {
        placeholderLabel.isHidden = textView.string.isEmpty == false
        sendButton.isEnabled = primaryActionEnabled
        if notifyDraftChange {
            onDraftChange?(textView.string)
        }
        updateInputHeight()
    }

    private var submissionControlsAllowSend: Bool {
        pendingRuntimeSelectionID == nil
            && queuePullInProgress == false
            && submissionRequestInFlight == false
            && runPhase != .stopping
            && terminalPassthroughIsStopping == false
            && terminalPassthroughIsAvailable
            && (terminalPassthroughRuntimeName != nil || selectedExecutionChoice != .ask)
            && ComposerDraftPersistence.canSend(text: textView.string)
    }

    private func updateResponsiveControls() {
        let compact = AgentComposerLayout.narrowModeCollectsRuntimeModelIntoMenu(width: view.bounds.width)
        let exposesNativeMetadata = terminalPassthroughRuntimeName == nil
        identityPopup.isHidden = compact
        modelPopup.isHidden = compact || currentModels.isEmpty || terminalPassthroughRuntimeName != nil
        reasoningPopup.isHidden = compact || currentReasoningLevels.isEmpty || terminalPassthroughRuntimeName != nil
        executionPopup.isHidden = terminalPassthroughRuntimeName != nil
        compactOptionsButton.toolTip = exposesNativeMetadata ? "Runtime 与模型" : "Runtime"
        compactOptionsButton.setAccessibilityLabel(compactOptionsButton.toolTip ?? "Runtime")
        compactOptionsButton.isHidden = compact == false
            || (runtimeOptions.count <= 1
                && (exposesNativeMetadata == false
                    || (currentModels.isEmpty && currentReasoningLevels.isEmpty)))
    }

    private func updateOptionalActionVisibility() {
        guard isViewLoaded else { return }
        addButton.isHidden = onAddAttachment == nil
        contextButton.isHidden = onSelectContext == nil
    }

    private func updateSendSymbol() {
        let showsStop = primaryActionShowsStop
        let symbol = showsStop ? "stop.fill" : "arrow.up"
        let label = showsStop
            ? (terminalPassthroughRuntimeName == nil ? "停止当前任务" : "停止 Stacio Agent 终端")
            : "发送"
        sendButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        sendButton.setAccessibilityLabel(label)
        sendButton.toolTip = label
    }

    private func updateRunControls() {
        if let runtimeName = terminalPassthroughRuntimeName {
            sendButton.isEnabled = primaryActionEnabled
            if primaryActionShowsStop == false {
                sendButton.toolTip = "发送到 \(runtimeName)"
            }
            identityPopup.isEnabled = terminalPassthroughIsRunning == false && terminalPassthroughIsStopping == false
            workModeControl.isEnabled = false
            executionPopup.isEnabled = false
        } else {
            sendButton.isEnabled = primaryActionEnabled
            identityPopup.isEnabled = runPhase == .idle
            workModeControl.isEnabled = runPhase == .idle
            executionPopup.isEnabled = runPhase == .idle
        }
        if pendingRuntimeSelectionID != nil {
            identityPopup.isEnabled = false
            sendButton.isEnabled = false
        }
        if queuePullInProgress {
            identityPopup.isEnabled = false
            workModeControl.isEnabled = false
            executionPopup.isEnabled = false
            sendButton.isEnabled = false
        }
        updateSendSymbol()
        if isViewLoaded {
            rebuildCompactMenu()
        }
    }

    private var primaryActionShowsStop: Bool {
        if terminalPassthroughRuntimeName != nil {
            return terminalPassthroughIsRunning || terminalPassthroughIsStopping
        }
        return submissionRequestInFlight || primaryStopRequested || runPhase.showsStop
    }

    private var primaryActionEnabled: Bool {
        if terminalPassthroughRuntimeName != nil {
            if primaryActionShowsStop {
                return terminalPassthroughIsRunning && terminalPassthroughIsStopping == false
            }
            return submissionControlsAllowSend
        }
        if primaryActionShowsStop {
            return primaryStopRequested == false
                && runPhase != .stopping
                && terminalPassthroughIsStopping == false
        }
        return submissionControlsAllowSend
    }

    private func reloadRuntimePopup() {
        guard isViewLoaded else { return }
        identityPopup.removeAllItems()
        for option in runtimeOptions {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            identityPopup.menu?.addItem(item)
        }
        if let index = runtimeOptions.firstIndex(where: { $0.id == selectedRuntimeOptionID }) {
            identityPopup.selectItem(at: index)
        }
    }

    private func rebuildCompactMenu() {
        let menu = NSMenu()
        let runtimeHeader = NSMenuItem(title: "Runtime", action: nil, keyEquivalent: "")
        runtimeHeader.isEnabled = false
        menu.addItem(runtimeHeader)
        for option in runtimeOptions {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectRuntimeFromCompactMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
            item.state = option.id == selectedRuntimeOptionID ? .on : .off
            item.isEnabled = identityPopup.isEnabled
            menu.addItem(item)
        }
        if terminalPassthroughRuntimeName == nil, currentModels.isEmpty == false {
            menu.addItem(.separator())
            currentModels.forEach { menu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
        }
        if terminalPassthroughRuntimeName == nil, currentReasoningLevels.isEmpty == false {
            menu.addItem(.separator())
            currentReasoningLevels.forEach { menu.addItem(withTitle: "推理：\($0)", action: nil, keyEquivalent: "") }
        }
        compactOptionsButton.menu = menu
    }

    @objc private func primaryAction() {
        if primaryActionShowsStop {
            requestPrimaryStop()
            return
        }
        submit()
    }

    @objc private func submit() {
        guard primaryActionShowsStop == false else { return }
        let submitted = textView.string
        guard submissionControlsAllowSend, let onSubmit else { return }
        beginSubmissionRequest()
        Task { @MainActor [weak self] in
            let accepted = await onSubmit(submitted)
            self?.finishSubmissionRequest(submittedText: submitted, accepted: accepted)
        }
    }

    @objc private func queueExplicitly() {
        let submitted = textView.string
        guard submissionControlsAllowSend, let onExplicitQueue else { return }
        beginSubmissionRequest()
        Task { @MainActor [weak self] in
            let accepted = await onExplicitQueue(submitted)
            self?.finishSubmissionRequest(submittedText: submitted, accepted: accepted)
        }
    }

    private func beginSubmissionRequest() {
        primaryStopRequested = false
        submissionRequestInFlight = true
        updateRunControls()
    }

    private func finishSubmissionRequest(submittedText: String, accepted: Bool) {
        guard submissionRequestInFlight else { return }
        let shouldStopAcceptedSubmission = accepted && primaryStopRequested
        if accepted {
            clearIfUnchanged(submittedText)
        }
        submissionRequestInFlight = false
        if accepted == false {
            primaryStopRequested = false
        }
        if shouldStopAcceptedSubmission {
            onStop?()
        }
        updateRunControls()
    }

    private func requestPrimaryStop() {
        guard primaryActionShowsStop,
              primaryStopRequested == false,
              runPhase != .stopping,
              terminalPassthroughIsStopping == false
        else { return }
        if terminalPassthroughRuntimeName != nil {
            onStop?()
            return
        }
        primaryStopRequested = true
        updateRunControls()
        guard submissionRequestInFlight == false else { return }
        onStop?()
    }

    @objc private func addAttachment() { onAddAttachment?() }
    @objc private func selectContext() { onSelectContext?() }
    @objc private func showCompactOptions(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func workModeChanged(_ sender: NSSegmentedControl) {
        guard TurnWorkMode.allCases.indices.contains(sender.selectedSegment) else { return }
        onWorkModeChange?(TurnWorkMode.allCases[sender.selectedSegment])
    }

    @objc private func executionChoiceChanged(_ sender: NSPopUpButton) {
        let choice: TurnExecutionChoice
        switch sender.indexOfSelectedItem {
        case 2: choice = .backgroundVirtualTerminal
        case 1: choice = .realTerminal
        default: choice = .ask
        }
        onExecutionChoiceChange?(choice)
        updateRunControls()
    }

    @objc private func runtimeSelectionChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else {
            reloadRuntimePopup()
            return
        }
        applyRuntimeSelection(id)
    }

    @objc private func selectRuntimeFromCompactMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyRuntimeSelection(id)
    }

    private func applyRuntimeSelection(_ id: String) {
        guard id != selectedRuntimeOptionID else { return }
        let previousID = selectedRuntimeOptionID
        if let onRuntimeSelectionRequest {
            guard pendingRuntimeSelectionID == nil else {
                reloadRuntimePopup()
                return
            }
            pendingRuntimeSelectionID = id
            reloadRuntimePopup()
            updateRunControls()
            onRuntimeSelectionRequest(id) { [weak self] accepted in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingRuntimeSelectionID == id else { return }
                    self.pendingRuntimeSelectionID = nil
                    if accepted {
                        self.selectedRuntimeOptionID = id
                        self.currentIdentity = self.runtimeOptions.first(where: { $0.id == id })?.title
                            ?? self.currentIdentity
                    } else {
                        self.selectedRuntimeOptionID = previousID
                    }
                    self.reloadRuntimePopup()
                    self.updateRunControls()
                    self.rebuildCompactMenu()
                }
            }
            return
        }
        guard onRuntimeSelectionChange?(id) != false else {
            selectedRuntimeOptionID = previousID
            reloadRuntimePopup()
            rebuildCompactMenu()
            return
        }
        selectedRuntimeOptionID = id
        currentIdentity = runtimeOptions.first(where: { $0.id == id })?.title ?? currentIdentity
        reloadRuntimePopup()
        rebuildCompactMenu()
    }
}
