import AppKit
import StacioAgentBridge

/// A prominent AI task status and control bar for the terminal that owns the task.
public final class TerminalAgentTraceOverlayView: NSVisualEffectView {
    static let fixedWidth: CGFloat = 520
    static let fixedHeight: CGFloat = 132
    private let titleLabel = NSTextField(labelWithString: "AI 助手")
    private let stateLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let accentBar = NSView()
    private let controlsStack = NSStackView()
    private let pauseButton = NSButton(title: L10n.AI.pauseTask, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.AI.cancelTask, target: nil, action: nil)
    private let takeOverButton = NSButton(title: L10n.AI.takeOverTask, target: nil, action: nil)
    private let confirmCompleteButton = NSButton(title: L10n.AI.confirmTaskComplete, target: nil, action: nil)
    private let closeButton = NSButton()
    private let completedAutoDismissInterval: TimeInterval
    private var renderedState: AgentTraceState?
    private var activeRequestID: String?
    private var controlsTopConstraint: NSLayoutConstraint?
    private var controlsHeightConstraint: NSLayoutConstraint?
    private var autoDismissWorkItem: DispatchWorkItem?
    private var pointerIsInside = false
    private var hoverTrackingArea: NSTrackingArea?
    private var fixedWidthConstraint: NSLayoutConstraint?
    private var fixedHeightConstraint: NSLayoutConstraint?

    public var onControlAction: ((String, TerminalAgentTaskControlAction) -> Void)?

    public override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, completedAutoDismissInterval: 10)
    }

    init(frame frameRect: NSRect, completedAutoDismissInterval: TimeInterval) {
        self.completedAutoDismissInterval = completedAutoDismissInterval
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        autoDismissWorkItem?.cancel()
    }

    public func render(_ events: [TerminalTraceEvent]) {
        guard let latest = events.last else {
            cancelAutoDismiss()
            isHidden = true
            return
        }
        stateLabel.stringValue = stateTitle(for: latest.state)
        renderedState = latest.state
        activeRequestID = latest.requestID
        applyEmphasis(for: latest.state)
        detailLabel.stringValue = events.suffix(3).map { event in
            var line = Self.compactDetail(event.message)
            if let command = event.redactedCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
               command.isEmpty == false {
                line += " · \(Self.compactDetail(command, limit: 100))"
            }
            return line
        }.joined(separator: "\n")
        updateControls(for: latest.state)
        isHidden = false
        updateCloseButtonVisibility()
        scheduleAutoDismissIfNeeded(for: latest.state)
    }

    public var visibleTextForTesting: String {
        [titleLabel.stringValue, stateLabel.stringValue, detailLabel.stringValue]
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    public var visibleControlTitlesForTesting: [String] {
        [pauseButton, cancelButton, takeOverButton, confirmCompleteButton]
            .filter { $0.isHidden == false }
            .map(\.title)
    }

    public func triggerControlForTesting(_ action: TerminalAgentTaskControlAction) {
        requestControl(action)
    }

    var closeButtonVisibleForTesting: Bool {
        closeButton.isHidden == false
    }

    func setPointerInsideForTesting(_ isInside: Bool) {
        pointerIsInside = isInside
        updateCloseButtonVisibility()
    }

    func triggerCloseForTesting() {
        closePressed(nil)
    }

    var fixedSizeForTesting: NSSize {
        NSSize(
            width: fixedWidthConstraint?.constant ?? 0,
            height: fixedHeightConstraint?.constant ?? 0
        )
    }

    private static func compactDetail(_ text: String, limit: Int = 150) -> String {
        let compact = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        guard compact.count > limit else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: limit)
        return "\(compact[..<end])..."
    }

    private func configure() {
        setAccessibilityIdentifier("Stacio.Terminal.agentTraceOverlay")
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.masksToBounds = false

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.setAccessibilityIdentifier("Stacio.Terminal.agentTraceOverlay.dot")
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = 2

        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .labelColor
        stateLabel.font = .systemFont(ofSize: 11, weight: .bold)
        stateLabel.setAccessibilityIdentifier("Stacio.Terminal.agentTraceOverlay.state")
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .labelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.cell?.wraps = true
        detailLabel.cell?.isScrollable = false
        detailLabel.setAccessibilityIdentifier("Stacio.Terminal.agentTraceOverlay.detail")
        [titleLabel, stateLabel, detailLabel, controlsStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let header = NSStackView(views: [statusDot, titleLabel, stateLabel])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let stack = NSStackView(views: [header, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        configureControlButton(pauseButton, action: #selector(pausePressed(_:)))
        configureControlButton(cancelButton, action: #selector(cancelPressed(_:)))
        configureControlButton(takeOverButton, action: #selector(takeOverPressed(_:)))
        configureControlButton(confirmCompleteButton, action: #selector(confirmCompletePressed(_:)))
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.distribution = .fillEqually
        controlsStack.spacing = 6
        controlsStack.setAccessibilityIdentifier("Stacio.Terminal.agentTraceOverlay.controls")
        [pauseButton, cancelButton, takeOverButton, confirmCompleteButton].forEach(controlsStack.addArrangedSubview)
        controlsStack.isHidden = true
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.toolTip = "关闭"
        closeButton.setAccessibilityLabel("关闭 AI 助手状态")
        closeButton.setAccessibilityIdentifier("Stacio.Terminal.agentTraceOverlay.close")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        addSubview(accentBar)
        addSubview(stack)
        addSubview(controlsStack)
        addSubview(closeButton)

        let controlsTopConstraint = controlsStack.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8)
        let controlsHeightConstraint = controlsStack.heightAnchor.constraint(equalToConstant: 26)
        self.controlsTopConstraint = controlsTopConstraint
        self.controlsHeightConstraint = controlsHeightConstraint
        let fixedWidthConstraint = widthAnchor.constraint(equalToConstant: Self.fixedWidth)
        fixedWidthConstraint.priority = .defaultHigh
        let fixedHeightConstraint = heightAnchor.constraint(equalToConstant: Self.fixedHeight)
        self.fixedWidthConstraint = fixedWidthConstraint
        self.fixedHeightConstraint = fixedHeightConstraint
        NSLayoutConstraint.activate([
            fixedWidthConstraint,
            fixedHeightConstraint,
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            accentBar.widthAnchor.constraint(equalToConstant: 4),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            detailLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 48),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            controlsStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            controlsTopConstraint,
            controlsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            controlsHeightConstraint
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("AI 助手执行过程")
        isHidden = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    public override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        updateCloseButtonVisibility()
    }

    public override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        updateCloseButtonVisibility()
    }

    private func configureControlButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateControls(for state: AgentTraceState) {
        let isActive: Bool
        switch state {
        case .queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput:
            isActive = true
        case .completed, .failed, .cancelled, .paused, .takenOver:
            isActive = false
        }
        controlsStack.isHidden = isActive == false
        controlsTopConstraint?.constant = isActive ? 8 : 0
        controlsHeightConstraint?.constant = isActive ? 26 : 0
        pauseButton.isHidden = isActive == false
        cancelButton.isHidden = isActive == false
        takeOverButton.isHidden = isActive == false
        pauseButton.isEnabled = isActive
        cancelButton.isEnabled = isActive
        takeOverButton.isEnabled = isActive
        confirmCompleteButton.isHidden = state != .waitingForOutput || isActive == false
        confirmCompleteButton.isEnabled = state == .waitingForOutput
    }

    @objc
    private func pausePressed(_ sender: Any?) {
        requestControl(.pause)
    }

    @objc
    private func cancelPressed(_ sender: Any?) {
        requestControl(.cancel)
    }

    @objc
    private func takeOverPressed(_ sender: Any?) {
        requestControl(.takeOver)
    }

    @objc
    private func confirmCompletePressed(_ sender: Any?) {
        requestControl(.confirmComplete)
    }

    private func requestControl(_ action: TerminalAgentTaskControlAction) {
        guard let activeRequestID else { return }
        onControlAction?(activeRequestID, action)
    }

    @objc
    private func closePressed(_ sender: Any?) {
        cancelAutoDismiss()
        isHidden = true
        updateCloseButtonVisibility()
    }

    private func updateCloseButtonVisibility() {
        closeButton.isHidden = pointerIsInside == false || isHidden
    }

    private func scheduleAutoDismissIfNeeded(for state: AgentTraceState) {
        cancelAutoDismiss()
        guard state == .completed else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.renderedState == .completed else { return }
            self.isHidden = true
            self.updateCloseButtonVisibility()
        }
        autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + completedAutoDismissInterval,
            execute: workItem
        )
    }

    private func cancelAutoDismiss() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let renderedState {
            applyEmphasis(for: renderedState)
        }
    }

    private func applyEmphasis(for state: AgentTraceState) {
        let color: NSColor
        switch state {
        case .awaitingApproval, .waitingForOutput:
            color = StacioDesignSystem.theme.warningColor
        case .completed:
            color = StacioDesignSystem.theme.successColor
        case .failed, .cancelled:
            color = StacioDesignSystem.theme.dangerColor
        case .paused, .takenOver:
            color = .systemOrange
        case .queued, .approved, .typing, .running:
            color = StacioDesignSystem.theme.accentColor
        }
        stateLabel.textColor = color
        StacioDesignSystem.setLayerBackgroundColor(statusDot, color: color)
        StacioDesignSystem.setLayerBackgroundColor(accentBar, color: color)
        StacioDesignSystem.setLayerBorderColor(self, color: color.withAlphaComponent(0.9))
        layer?.shadowColor = StacioDesignSystem.resolvedLayerColor(color, for: self)
    }

    private func stateTitle(for state: AgentTraceState) -> String {
        switch state {
        case .queued: return "排队中"
        case .awaitingApproval: return "等待确认"
        case .approved: return "已批准"
        case .typing: return "写入中"
        case .running: return "执行中"
        case .waitingForOutput: return "等待输出"
        case .completed: return "已完成"
        case .paused: return "已暂停"
        case .cancelled: return "已取消"
        case .takenOver: return "已接管"
        case .failed: return "失败"
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let controls = [pauseButton, cancelButton, takeOverButton, confirmCompleteButton, closeButton]
        return controls.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) ? hit : nil
    }
}
