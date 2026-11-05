import AppKit
import StacioAgentBridge

public final class AICommandCardView: NSView {
    private static let defaultTextPreferredWidth: CGFloat = 240

    public var onRun: ((String) -> Void)?
    public var onSkip: ((String, AgentActionRisk) -> Void)?
    public var onCopy: ((String) -> Void)?

    public private(set) var proposal: AgentCommandProposal
    public var commandHighlightLevel: TerminalHighlightLevelPreference = .commandLineEnhanced {
        didSet {
            renderCommandText()
        }
    }
    public var commandHighlightTheme: TerminalColorTheme = .systemAdaptivePreview {
        didSet {
            renderCommandText()
        }
    }
    public var richCommandHighlightingEnabled: Bool = true {
        didSet {
            renderCommandText()
        }
    }

    private let statusIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "工具调用")
    private let explanationLabel = NSTextField(labelWithString: "")
    private let riskLabel = NSTextField(labelWithString: "")
    private let commandContainer = NSView()
    private let commandField = NSTextField()
    private let runButton = NSButton(title: L10n.AI.run, target: nil, action: nil)
    private let skipButton = NSButton(title: L10n.AI.skip, target: nil, action: nil)
    private let copyButton = NSButton(title: L10n.AI.copy, target: nil, action: nil)

    public init(proposal: AgentCommandProposal) {
        self.proposal = proposal
        super.init(frame: .zero)
        configure()
        commandField.stringValue = proposal.command
        renderCommandText()
        render()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        let availableWidth = max(80, bounds.width - 24 - riskLabel.frame.width - 8)
        explanationLabel.preferredMaxLayoutWidth = availableWidth
    }

    public var editedCommand: String {
        commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func updateState(_ state: AgentCommandProposalState) {
        proposal.state = state
        render()
    }

    public func setCommandForTesting(_ command: String) {
        commandField.stringValue = command
        renderCommandText()
    }

    public var textForTesting: String {
        [explanationLabel.stringValue, riskLabel.stringValue, commandField.stringValue, highlightSummary]
            .joined(separator: " ")
    }

    func performRunForTesting() {
        runPressed(nil)
    }

    func performSkipForTesting() {
        skipPressed(nil)
    }

    func performCopyForTesting() {
        copyPressed(nil)
    }

    private func configure() {
        setAccessibilityIdentifier("Stacio.AI.commandCard")
        wantsLayer = true
        layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.9)
        )
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.34)
        )
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        [
            statusIconView,
            titleLabel,
            explanationLabel,
            riskLabel,
            commandContainer,
            runButton,
            skipButton,
            copyButton
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        commandContainer.addSubview(commandField)
        commandContainer.translatesAutoresizingMaskIntoConstraints = false
        commandContainer.wantsLayer = true
        commandContainer.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        commandContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            commandContainer,
            color: NSColor.textBackgroundColor.withAlphaComponent(0.82)
        )
        StacioDesignSystem.setLayerBorderColor(
            commandContainer,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.24)
        )
        commandContainer.layer?.borderWidth = 1

        statusIconView.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: titleLabel.stringValue)
        statusIconView.contentTintColor = StacioDesignSystem.theme.accentColor
        statusIconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor

        explanationLabel.lineBreakMode = .byCharWrapping
        explanationLabel.maximumNumberOfLines = 2
        explanationLabel.font = .systemFont(ofSize: 11)
        explanationLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        explanationLabel.preferredMaxLayoutWidth = Self.defaultTextPreferredWidth
        explanationLabel.cell?.wraps = true
        explanationLabel.cell?.usesSingleLineMode = false
        riskLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        riskLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        riskLabel.alignment = .right
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.isEditable = true
        commandField.isBordered = false
        commandField.isBezeled = false
        commandField.drawsBackground = false
        commandField.focusRingType = .none
        commandField.lineBreakMode = .byTruncatingMiddle
        commandField.setAccessibilityIdentifier("Stacio.AI.commandCard.command")
        [
            self,
            titleLabel,
            explanationLabel,
            riskLabel,
            commandContainer,
            commandField,
            runButton,
            skipButton,
            copyButton
        ].forEach { view in
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        runButton.target = self
        runButton.action = #selector(runPressed(_:))
        skipButton.target = self
        skipButton.action = #selector(skipPressed(_:))
        copyButton.target = self
        copyButton.action = #selector(copyPressed(_:))
        [runButton, skipButton, copyButton].forEach(configureActionButton(_:))

        NSLayoutConstraint.activate([
            statusIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusIconView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            statusIconView.widthAnchor.constraint(equalToConstant: 16),
            statusIconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: statusIconView.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: statusIconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: riskLabel.leadingAnchor, constant: -8),

            riskLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            riskLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            riskLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 72),

            explanationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            explanationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            explanationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            commandContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            commandContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            commandContainer.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 9),
            commandContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),

            commandField.leadingAnchor.constraint(equalTo: commandContainer.leadingAnchor, constant: 10),
            commandField.trailingAnchor.constraint(equalTo: commandContainer.trailingAnchor, constant: -10),
            commandField.centerYAnchor.constraint(equalTo: commandContainer.centerYAnchor),
            commandField.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),

            runButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            runButton.topAnchor.constraint(equalTo: commandContainer.bottomAnchor, constant: 9),

            skipButton.leadingAnchor.constraint(equalTo: runButton.trailingAnchor, constant: 8),
            skipButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),

            copyButton.leadingAnchor.constraint(equalTo: skipButton.trailingAnchor, constant: 8),
            copyButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    private func configureActionButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    private func render() {
        explanationLabel.stringValue = explanationText()
        riskLabel.stringValue = label(for: proposal.risk)
        runButton.isEnabled = proposal.state == .proposed
        skipButton.isEnabled = proposal.state == .proposed
        titleLabel.stringValue = titleText()
        statusIconView.image = NSImage(systemSymbolName: symbolName(), accessibilityDescription: titleLabel.stringValue)
        statusIconView.contentTintColor = tintColor()
        renderCommandText()
    }

    private func explanationText() -> String {
        switch proposal.state {
        case .proposed:
            return proposal.explanation
        case .skipped:
            return "已跳过：\(proposal.explanation)"
        case .running:
            return "执行中：\(proposal.explanation)"
        case .completed:
            return "已完成：\(proposal.explanation)"
        case .failed:
            return "执行失败：\(proposal.explanation)"
        }
    }

    private func titleText() -> String {
        switch proposal.state {
        case .proposed:
            return "等待确认"
        case .skipped:
            return "已跳过"
        case .running:
            return "执行中"
        case .completed:
            return "已完成"
        case .failed:
            return "需要处理"
        }
    }

    private func symbolName() -> String {
        switch proposal.state {
        case .proposed:
            return "terminal"
        case .skipped:
            return "forward.end"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private func tintColor() -> NSColor {
        switch proposal.state {
        case .proposed:
            return StacioDesignSystem.theme.accentColor
        case .skipped:
            return StacioDesignSystem.theme.secondaryTextColor
        case .running:
            return StacioDesignSystem.theme.accentColor
        case .completed:
            return StacioDesignSystem.theme.successColor
        case .failed:
            return StacioDesignSystem.theme.dangerColor
        }
    }

    private var highlightSummary: String {
        TerminalCommandHighlighter.highlight(commandField.stringValue).summary
    }

    private func renderCommandText() {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        commandField.attributedStringValue = TerminalCommandHighlighter.attributedString(
            for: commandField.stringValue,
            level: commandHighlightLevel,
            baseFont: font,
            theme: commandHighlightTheme,
            richHighlightingEnabled: richCommandHighlightingEnabled
        )
        let summary = highlightSummary
        commandField.toolTip = summary.isEmpty ? nil : summary
    }

    private func label(for risk: AgentActionRisk) -> String {
        switch risk {
        case .readOnly:
            return L10n.AI.commandRiskReadOnly
        case .write:
            return L10n.AI.commandRiskWrite
        case .network:
            return L10n.AI.commandRiskNetwork
        case .destructive:
            return L10n.AI.commandRiskDestructive
        }
    }

    @objc private func runPressed(_ sender: Any?) {
        onRun?(editedCommand)
    }

    @objc private func skipPressed(_ sender: Any?) {
        updateState(.skipped)
        onSkip?(editedCommand, AgentActionClassifier.risk(forCommand: editedCommand))
    }

    @objc private func copyPressed(_ sender: Any?) {
        onCopy?(editedCommand)
    }
}
