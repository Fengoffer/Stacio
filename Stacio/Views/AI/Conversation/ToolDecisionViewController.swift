import AppKit
import Foundation

/// 会话内唯一的工具审批面板。它只展示已持久化的 Decision 投影，
/// 用户动作必须回到 SessionRuntimeBridge，视图本身不执行命令。
@MainActor
public final class ToolDecisionViewController: NSViewController {
    public var onResolve: ((String, Bool) -> Void)?

    /// Identity of the projection currently displayed by this card. Callers
    /// that finish an asynchronous approval must compare against it before
    /// changing the resolving state; a later proposal may already occupy the
    /// same view.
    public var currentProposalID: String? { presentation?.proposalID }

    private let headerLabel = NSTextField(labelWithString: "")
    private let riskLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsScrollView = NSScrollView()
    // NSScrollView keeps a document view in its native coordinate system. A
    // regular NSStackView is bottom-origin on macOS, which can push the first
    // command lines below a short approval-card viewport. Keep this document
    // top-origin like the Inspector's other scrollable content.
    private let detailsStack = ToolDecisionFlippedStackView()
    private let queuedSummaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let approveButton = NSButton()
    private let denyButton = NSButton()
    private var presentation: PendingToolDecisionPresentation?
    private var isResolving = false
    private var compactPresentation = false
    private var contentStack: NSStackView?
    private var contentTopConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var detailsMinimumHeightConstraint: NSLayoutConstraint?
    private var compactHeightConstraint: NSLayoutConstraint?

    public override func loadView() {
        let effectView = GlassCapabilityAdapter.makeInteractiveSurface(
            fallbackMaterial: .popover,
            cornerRadius: StacioDesignSystem.theme.panelCornerRadius
        )
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.setAccessibilityIdentifier("Stacio.AI.decisionCard")
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.borderWidth = 1
        if GlassCapabilityAdapter.surfaceKind(of: effectView) == .opaqueFallback {
            StacioDesignSystem.setLayerBackgroundColor(
                effectView,
                color: NSColor.controlBackgroundColor.withAlphaComponent(0.64)
            )
        }
        StacioDesignSystem.setLayerBorderColor(
            effectView,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.28)
        )
        view = effectView

        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingMiddle

        riskLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        riskLabel.alignment = .right

        commandLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandLabel.textColor = .labelColor
        // A command is an approval boundary: never hide its tail behind an
        // ellipsis. The panel may grow, and Copy remains available for very
        // long commands that exceed the host window's height.
        commandLabel.maximumNumberOfLines = 0
        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.cell?.wraps = true
        commandLabel.cell?.truncatesLastVisibleLine = false
        commandLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        explanationLabel.font = .systemFont(ofSize: 12)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.maximumNumberOfLines = 0
        explanationLabel.lineBreakMode = .byCharWrapping
        explanationLabel.cell?.wraps = true
        explanationLabel.cell?.truncatesLastVisibleLine = false
        explanationLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        detailsLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.lineBreakMode = .byCharWrapping
        detailsLabel.cell?.wraps = true
        detailsLabel.cell?.truncatesLastVisibleLine = false
        detailsLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        queuedSummaryLabel.font = .systemFont(ofSize: 11)
        queuedSummaryLabel.textColor = .secondaryLabelColor
        queuedSummaryLabel.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        statusLabel.cell?.truncatesLastVisibleLine = false
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setAccessibilityLabel("审批状态")

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制命令")
        copyButton.imagePosition = .imageOnly
        copyButton.bezelStyle = .texturedRounded
        copyButton.isBordered = false
        copyButton.target = self
        copyButton.action = #selector(copyCommand)
        copyButton.toolTip = "复制完整命令"
        copyButton.setAccessibilityLabel("复制完整命令")

        denyButton.title = "拒绝"
        denyButton.bezelStyle = .rounded
        denyButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "拒绝")
        denyButton.imagePosition = .imageLeading
        denyButton.target = self
        denyButton.action = #selector(deny)
        denyButton.toolTip = "拒绝这条命令"

        approveButton.title = "运行"
        approveButton.bezelStyle = .rounded
        // Approval crosses the terminal side-effect boundary. Keep Return owned
        // by the Composer and IME instead of registering a window-wide shortcut.
        approveButton.keyEquivalent = ""
        approveButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "运行")
        approveButton.imagePosition = .imageLeading
        approveButton.target = self
        approveButton.action = #selector(approve)
        approveButton.toolTip = "批准并运行这条命令"

        let headerRow = NSStackView(views: [headerLabel, riskLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        riskLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Status is a full-width message row. Keeping it beside three fixed
        // actions made it collapse to a few pixels in a narrow Inspector card,
        // hiding the reason why an approval is disabled or stale.
        let actionRow = NSStackView(views: [NSView(), copyButton, denyButton, approveButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.setContentCompressionResistancePriority(.required, for: .vertical)

        // Keep the approval actions visible even when the command and its
        // audit details are much taller than the available conversation pane.
        // The document remains complete and copyable; only the viewport
        // scrolls.
        detailsStack.orientation = .vertical
        detailsStack.alignment = .width
        detailsStack.spacing = 8
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsStack.addArrangedSubview(commandLabel)
        detailsStack.addArrangedSubview(explanationLabel)
        detailsStack.addArrangedSubview(detailsLabel)

        detailsScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailsScrollView.documentView = detailsStack
        detailsScrollView.hasVerticalScroller = true
        detailsScrollView.hasHorizontalScroller = false
        detailsScrollView.autohidesScrollers = true
        detailsScrollView.drawsBackground = false
        detailsScrollView.borderType = .noBorder
        detailsScrollView.setAccessibilityIdentifier("Stacio.AI.decisionCard.detailsScroll")
        detailsScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detailsScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSStackView(views: [
            headerRow,
            detailsScrollView,
            queuedSummaryLabel,
            statusLabel,
            actionRow
        ])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(content)
        contentStack = content

        let contentTop = content.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 12)
        let contentBottom = content.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -12)
        let detailsMinimumHeight = detailsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let compactHeight = effectView.heightAnchor.constraint(equalToConstant: 148)
        compactHeight.isActive = false
        contentTopConstraint = contentTop
        contentBottomConstraint = contentBottom
        detailsMinimumHeightConstraint = detailsMinimumHeight
        compactHeightConstraint = compactHeight
        NSLayoutConstraint.activate([
            contentTop,
            contentBottom,
            content.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            detailsMinimumHeight,
            approveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            denyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        NSLayoutConstraint.activate([
            detailsStack.leadingAnchor.constraint(equalTo: detailsScrollView.contentView.leadingAnchor),
            detailsStack.trailingAnchor.constraint(equalTo: detailsScrollView.contentView.trailingAnchor),
            detailsStack.topAnchor.constraint(equalTo: detailsScrollView.contentView.topAnchor),
            detailsStack.widthAnchor.constraint(equalTo: detailsScrollView.contentView.widthAnchor),
            detailsStack.heightAnchor.constraint(greaterThanOrEqualTo: detailsScrollView.contentView.heightAnchor)
        ])

        effectView.setAccessibilityRole(.group)
        effectView.setAccessibilityLabel("命令审批")
        commandLabel.setAccessibilityLabel("待执行命令")
        explanationLabel.setAccessibilityLabel("命令说明")
        detailsLabel.setAccessibilityLabel("审批详情")
        queuedSummaryLabel.setAccessibilityLabel("后续工具调用")
        riskLabel.setAccessibilityLabel("命令风险")
        approveButton.setAccessibilityLabel("批准并运行命令")
        denyButton.setAccessibilityLabel("拒绝命令")
        effectView.isHidden = true
    }

    /// At the smallest supported shell height the approval boundary remains
    /// usable: identity/risk and actions stay pinned while the complete command
    /// and audit detail continue to live in the scrollable document.
    public func setCompactPresentation(_ compact: Bool) {
        guard compactPresentation != compact else { return }
        compactPresentation = compact
        loadViewIfNeeded()
        // Compact is a width/viewport mode, not a permission to collapse the
        // approval boundary. Keep the command and action row readable; long
        // command/audit text remains available through the details scroller.
        contentTopConstraint?.constant = compact ? 8 : 12
        contentBottomConstraint?.constant = compact ? -8 : -12
        contentStack?.spacing = compact ? 6 : 8
        // Keep enough viewport for the command row and audit text while the
        // action row stays reachable. Longer content remains scrollable.
        detailsMinimumHeightConstraint?.constant = compact ? 44 : 44
        if compact == false {
            compactHeightConstraint?.isActive = false
        }
        updateQueuedSummaryVisibility()
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
    }

    /// Bounds the card to the space available above the Composer while its
    /// command/details viewport remains independently scrollable. Passing nil
    /// restores the natural height used by a roomy Inspector.
    public func setCompactHeight(_ height: CGFloat?) {
        guard compactPresentation else {
            if compactHeightConstraint?.isActive == true {
                compactHeightConstraint?.isActive = false
            }
            return
        }
        guard let height else {
            if compactHeightConstraint?.isActive == true {
                compactHeightConstraint?.isActive = false
            }
            return
        }
        let boundedHeight = min(212, max(148, height))
        let changed = compactHeightConstraint?.isActive != true
            || abs((compactHeightConstraint?.constant ?? 0) - boundedHeight) > 0.5
        guard changed else { return }
        compactHeightConstraint?.constant = boundedHeight
        compactHeightConstraint?.isActive = true
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
    }

    public func apply(_ next: PendingToolDecisionPresentation?) {
        loadViewIfNeeded()
        let previousProposalID = presentation?.proposalID
        presentation = next
        guard let next else {
            isResolving = false
            headerLabel.stringValue = ""
            riskLabel.stringValue = ""
            riskLabel.textColor = .secondaryLabelColor
            commandLabel.stringValue = ""
            explanationLabel.stringValue = ""
            explanationLabel.isHidden = false
            detailsLabel.stringValue = ""
            queuedSummaryLabel.stringValue = ""
            queuedSummaryLabel.isHidden = true
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            approveButton.isEnabled = false
            denyButton.isEnabled = false
            copyButton.isEnabled = false
            scrollDetailsToTop()
            view.isHidden = true
            return
        }
        let sameResolvingProposal = next.isActionable
            && isResolving
            && previousProposalID == next.proposalID
        headerLabel.stringValue = next.isActionable
            ? "工具 \(next.index)/\(next.total) · \(next.targetTitle)"
            : "只读建议 · \(next.targetTitle)"
        riskLabel.stringValue = Self.riskTitle(next.risk)
        riskLabel.textColor = Self.riskColor(next.risk)
        commandLabel.stringValue = next.command
        explanationLabel.stringValue = next.explanation
        explanationLabel.isHidden = next.explanation.isEmpty
        detailsLabel.stringValue = [
            "工作目录：\(next.targetWorkingDirectory)",
            "执行位置：\(next.executionDestination)",
            "连接代次：\(next.targetRuntimeGeneration.map(String.init) ?? "未验证")",
            "命令解析：由目标终端 Shell 按原文执行",
            "目标绑定：\(next.targetBindingDigest)",
            "审批摘要：\(next.immutableSummary)"
        ].joined(separator: "\n")
        let remaining = max(0, next.total - next.index)
        queuedSummaryLabel.stringValue = DecisionCardAction.queuedSummaryLabel(remaining: remaining)
        updateQueuedSummaryVisibility()
        approveButton.title = next.risk == "destructive" ? "批准并运行" : "运行"
        if sameResolvingProposal == false {
            setResolving(false)
        }
        if next.isActionable == false {
            statusLabel.stringValue = next.statusMessage ?? "该审批已失效，不能执行"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        }
        copyButton.isEnabled = true
        scrollDetailsToTop()
        view.isHidden = false
    }

    public func setResolving(_ resolving: Bool, error: String? = nil) {
        isResolving = resolving
        let canResolve = presentation?.isActionable == true
        approveButton.isEnabled = canResolve && resolving == false
        denyButton.isEnabled = canResolve && resolving == false
        copyButton.isEnabled = true
        if resolving {
            statusLabel.stringValue = "正在保存审批…"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        } else if let error, error.isEmpty == false {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
        } else if let statusMessage = presentation?.statusMessage,
                  statusMessage.isEmpty == false {
            statusLabel.stringValue = statusMessage
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        }
    }

    /// Applies an asynchronous result only if the card still represents the
    /// proposal that initiated the request. Returns false for a stale result.
    @discardableResult
    public func setResolving(
        _ resolving: Bool,
        forProposalID proposalID: String,
        error: String? = nil
    ) -> Bool {
        guard presentation?.proposalID == proposalID else { return false }
        setResolving(resolving, error: error)
        return true
    }

    public func detailsScrollFrameForTesting(in ancestor: NSView) -> NSRect {
        detailsScrollView.convert(detailsScrollView.bounds, to: ancestor)
    }

    public func detailsDocumentFrameForTesting(in ancestor: NSView) -> NSRect {
        detailsStack.convert(detailsStack.bounds, to: ancestor)
    }

    public func commandFrameForTesting(in ancestor: NSView) -> NSRect {
        commandLabel.convert(commandLabel.bounds, to: ancestor)
    }

    public var detailsVisibleDocumentRectForTesting: NSRect {
        detailsScrollView.contentView.documentVisibleRect
    }

    public var commandFrameInDetailsDocumentForTesting: NSRect {
        commandLabel.convert(commandLabel.bounds, to: detailsStack)
    }

    public var commandTextForTesting: String {
        commandLabel.stringValue
    }

    public func approvalButtonFrameForTesting(in ancestor: NSView) -> NSRect {
        approveButton.convert(approveButton.bounds, to: ancestor)
    }

    public func denialButtonFrameForTesting(in ancestor: NSView) -> NSRect {
        denyButton.convert(denyButton.bounds, to: ancestor)
    }

    @objc private func approve() {
        guard isResolving == false, let presentation, presentation.isActionable else { return }
        setResolving(true)
        guard let onResolve else {
            setResolving(false, error: "当前会话不可用")
            return
        }
        onResolve(presentation.proposalID, true)
    }

    @objc private func deny() {
        guard isResolving == false, let presentation, presentation.isActionable else { return }
        setResolving(true)
        guard let onResolve else {
            setResolving(false, error: "当前会话不可用")
            return
        }
        onResolve(presentation.proposalID, false)
    }

    @objc private func copyCommand() {
        guard let command = presentation?.command,
              command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        guard isResolving == false else { return }
        statusLabel.stringValue = "命令已复制"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
    }

    private static func riskTitle(_ risk: String) -> String {
        switch risk {
        case "destructive": return "破坏性"
        case "network": return "网络变更"
        case "write": return "写入"
        default: return "只读"
        }
    }

    private static func riskColor(_ risk: String) -> NSColor {
        switch risk {
        case "destructive": return .systemRed
        case "network", "write": return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private func updateQueuedSummaryVisibility() {
        guard let presentation else {
            queuedSummaryLabel.isHidden = true
            return
        }
        // The header already carries `index/total`; suppressing the redundant
        // sentence in compact mode preserves the same information and keeps
        // the approval actions reachable.
        queuedSummaryLabel.isHidden = compactPresentation
            || presentation.total - presentation.index <= 0
    }

    private func scrollDetailsToTop() {
        guard detailsScrollView.contentView.bounds.height > 0 else { return }
        detailsScrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        detailsScrollView.reflectScrolledClipView(detailsScrollView.contentView)
        // Applying a proposal can happen before Auto Layout has assigned the
        // document's intrinsic height. Re-apply after the next layout so a
        // previous proposal's scroll offset cannot hide the new command.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.detailsScrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            self.detailsScrollView.reflectScrolledClipView(self.detailsScrollView.contentView)
        }
    }
}

private final class ToolDecisionFlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
