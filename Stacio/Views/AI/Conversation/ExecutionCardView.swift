import AppKit
import Foundation

// MARK: - Execution Card

public struct ExecutionCardPresentation: Equatable, Sendable {
    public let proposalID: String
    public let target: String
    public let targetRuntimeID: String?
    public let workingDirectory: String
    public let redactedCommand: String
    public let riskAndApproval: String
    public let isRealTerminal: Bool
    public let exitCode: Int?
    public let durationSeconds: Int?
    public let completionBasis: String
    public let status: String
    public let terminalArtifact: TerminalArtifactPresentation?
    public let holdsTransferableHandle: Bool

    public init(
        proposalID: String = "",
        target: String,
        targetRuntimeID: String? = nil,
        workingDirectory: String,
        redactedCommand: String,
        riskAndApproval: String,
        isRealTerminal: Bool,
        exitCode: Int?,
        durationSeconds: Int?,
        completionBasis: String,
        status: String = "",
        terminalArtifact: TerminalArtifactPresentation? = nil,
        holdsTransferableHandle: Bool = false
    ) {
        self.proposalID = proposalID
        self.target = target
        self.targetRuntimeID = targetRuntimeID
        self.workingDirectory = workingDirectory
        self.redactedCommand = redactedCommand
        self.riskAndApproval = riskAndApproval
        self.isRealTerminal = isRealTerminal
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.completionBasis = completionBasis
        self.status = status
        self.terminalArtifact = terminalArtifact
        self.holdsTransferableHandle = holdsTransferableHandle
    }

    public var isFinished: Bool {
        terminalArtifact?.isFinished == true || exitCode != nil
    }
}

public enum ExecutionCardAction {
    public static func terminalKindLabel(isRealTerminal: Bool) -> String {
        isRealTerminal ? "真实终端" : "后台虚拟终端"
    }

    public static func takeoverAvailable(holdsTransferableHandle: Bool) -> Bool {
        holdsTransferableHandle
    }
}

/// A real AppKit execution card used by the conversation timeline. It renders
/// only redacted execution evidence and delegates all control actions.
@MainActor
public final class ExecutionCardView: NSView {
    public var onOpenTerminal: ((String) -> Void)?
    public var onCancel: ((String) -> Void)?
    public var onSaveRedactedLog: ((TerminalArtifactPresentation) -> Void)?
    public var onExpandedChange: ((Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let disclosureButton = NSButton()
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let terminalView = TerminalArtifactView()
    private var presentation: ExecutionCardPresentation?
    private var expanded = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func apply(_ presentation: ExecutionCardPresentation, expanded: Bool) {
        self.presentation = presentation
        self.expanded = expanded
        let completelyCollapsed = presentation.isFinished && expanded == false
        titleLabel.stringValue = "终端执行 · \(presentation.target)"
        stateLabel.stringValue = presentation.status.isEmpty
            ? presentation.riskAndApproval
            : "\(presentation.riskAndApproval) · \(presentation.status)"
        commandLabel.stringValue = presentation.redactedCommand
        detailsLabel.stringValue = [
            "工作目录：\(presentation.workingDirectory)",
            "执行位置：\(ExecutionCardAction.terminalKindLabel(isRealTerminal: presentation.isRealTerminal))",
            presentation.exitCode.map { "退出码：\($0)" },
            presentation.durationSeconds.map { "持续时间：\($0) 秒" },
            presentation.completionBasis.isEmpty ? nil : "完成依据：\(presentation.completionBasis)"
        ].compactMap { $0 }.joined(separator: "\n")
        commandLabel.isHidden = completelyCollapsed
        detailsLabel.isHidden = expanded == false

        disclosureButton.isHidden = presentation.isFinished == false
        disclosureButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "收起终端执行" : "展开终端执行"
        )
        disclosureButton.toolTip = expanded ? "收起终端执行" : "展开终端执行"
        disclosureButton.setAccessibilityLabel(expanded ? "收起终端执行" : "展开终端执行")

        if let artifact = presentation.terminalArtifact {
            terminalView.apply(artifact, expanded: expanded)
            terminalView.isHidden = completelyCollapsed
        } else {
            terminalView.isHidden = true
        }
        invalidateIntrinsicContentSize()
    }

    public static func measuredHeight(
        for presentation: ExecutionCardPresentation,
        expanded: Bool,
        width: CGFloat
    ) -> CGFloat {
        if presentation.isFinished && expanded == false {
            return 44
        }
        let base: CGFloat = expanded ? 132 : 86
        guard let artifact = presentation.terminalArtifact else { return base }
        return base + TerminalArtifactView.measuredHeight(
            for: artifact,
            expanded: expanded,
            width: width
        )
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = StacioDesignSystem.theme.controlBackgroundColor
            .withAlphaComponent(0.46).cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("终端执行卡片")

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setAccessibilityLabel("执行目标")
        stateLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .right
        stateLabel.setAccessibilityLabel("执行风险与状态")

        commandLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        commandLabel.alignment = .left
        commandLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        commandLabel.maximumNumberOfLines = 3
        commandLabel.lineBreakMode = .byCharWrapping
        commandLabel.cell?.wraps = true
        commandLabel.isSelectable = true
        commandLabel.setAccessibilityLabel("脱敏命令")

        detailsLabel.font = .systemFont(ofSize: 10.5)
        detailsLabel.alignment = .left
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.lineBreakMode = .byWordWrapping
        detailsLabel.cell?.alignment = .left
        detailsLabel.cell?.wraps = true
        detailsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailsLabel.setAccessibilityLabel("执行详情")

        terminalView.onOpenTerminal = { [weak self] runtimeID in
            self?.onOpenTerminal?(runtimeID)
        }
        terminalView.onCancel = { [weak self] requestID in
            self?.onCancel?(requestID)
        }
        terminalView.onSaveRedactedLog = { [weak self] presentation in
            self?.onSaveRedactedLog?(presentation)
        }
        terminalView.onExpandedChange = { [weak self] expanded in
            self?.expanded = expanded
            self?.detailsLabel.isHidden = expanded == false
            self?.onExpandedChange?(expanded)
        }

        disclosureButton.imagePosition = .imageOnly
        disclosureButton.bezelStyle = .accessoryBarAction
        disclosureButton.isBordered = false
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpanded)
        disclosureButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        disclosureButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let header = NSStackView(views: [titleLabel, NSView(), stateLabel, disclosureButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, commandLabel, detailsLabel, terminalView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        addSubview(stack)
        commandLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            commandLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            terminalView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func toggleExpanded() {
        guard let presentation, presentation.isFinished else { return }
        expanded.toggle()
        apply(presentation, expanded: expanded)
        onExpandedChange?(expanded)
    }

    var isCompletelyCollapsedForTesting: Bool {
        guard let presentation else { return false }
        return presentation.isFinished
            && expanded == false
            && commandLabel.isHidden
            && terminalView.isHidden
    }
}
