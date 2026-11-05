import AppKit
import Foundation

// MARK: - Terminal Artifact View

/// A bounded, redacted projection of one terminal execution. The view never
/// owns a terminal or executes a command; actions are routed back to the
/// Workbench/SessionRuntimeBridge owners.
public struct TerminalArtifactPresentation: Equatable, Sendable {
    public let requestID: String?
    public let runtimeID: String?
    public let liveTail: String?
    public let exitCode: Int?
    public let durationSeconds: Int?
    public let completionBasis: String?
    public let hasTerminalState: Bool
    public let stateLabel: String
    public let isRealTerminal: Bool
    public let canOpenTerminal: Bool
    public let canCancel: Bool
    public let canSaveRedactedLog: Bool
    public let redactedLog: String

    public init(
        requestID: String? = nil,
        runtimeID: String? = nil,
        liveTail: String?,
        exitCode: Int?,
        durationSeconds: Int?,
        completionBasis: String? = nil,
        hasTerminalState: Bool? = nil,
        stateLabel: String = "",
        isRealTerminal: Bool = true,
        canOpenTerminal: Bool = false,
        canCancel: Bool = false,
        canSaveRedactedLog: Bool = false,
        redactedLog: String = ""
    ) {
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.liveTail = liveTail
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.completionBasis = completionBasis
        self.hasTerminalState = hasTerminalState ?? (exitCode != nil)
        self.stateLabel = stateLabel
        self.isRealTerminal = isRealTerminal
        self.canOpenTerminal = canOpenTerminal
        self.canCancel = canCancel
        self.canSaveRedactedLog = canSaveRedactedLog
        self.redactedLog = redactedLog
    }

    public var isFinished: Bool {
        hasTerminalState || exitCode != nil
    }
}

@MainActor
public final class TerminalArtifactView: NSView {
    public var onOpenTerminal: ((String) -> Void)?
    public var onCancel: ((String) -> Void)?
    public var onSaveRedactedLog: ((TerminalArtifactPresentation) -> Void)?
    public var onExpandedChange: ((Bool) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let metadataLabel = NSTextField(labelWithString: "")
    private let outputLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let expandButton = NSButton()
    private let openButton = NSButton()
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private var presentation: TerminalArtifactPresentation?
    private var expanded = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func apply(_ presentation: TerminalArtifactPresentation, expanded: Bool) {
        self.presentation = presentation
        self.expanded = expanded

        statusLabel.stringValue = presentation.stateLabel.isEmpty
            ? (presentation.isFinished ? "已结束" : "执行中")
            : presentation.stateLabel
        statusIconView.image = NSImage(
            systemSymbolName: presentation.isRealTerminal ? "terminal" : "rectangle.and.paperclip",
            accessibilityDescription: presentation.isRealTerminal ? "真实终端" : "后台虚拟终端"
        )
        statusIconView.contentTintColor = presentation.isFinished
            ? StacioDesignSystem.theme.successColor
            : StacioDesignSystem.theme.accentColor
        let metadata = [
            presentation.isRealTerminal ? "真实终端" : "后台虚拟终端",
            presentation.exitCode.map { "退出码 \($0)" },
            presentation.durationSeconds.map { "\($0) 秒" },
            presentation.completionBasis.flatMap {
                $0.isEmpty ? nil : "依据 \(Self.completionBasisTitle($0))"
            }
        ].compactMap { $0 }
        metadataLabel.stringValue = metadata.joined(separator: " · ")

        let tail = presentation.liveTail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        outputLabel.stringValue = tail.isEmpty
            ? (presentation.hasTerminalState ? "命令已结束，未产生可显示的终端输出。" : "等待终端输出…")
            : tail
        outputLabel.maximumNumberOfLines = expanded ? 0 : 4
        outputLabel.cell?.truncatesLastVisibleLine = expanded == false

        copyButton.isEnabled = tail.isEmpty == false
        expandButton.isEnabled = tail.isEmpty == false
        expandButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "收起终端输出" : "展开终端输出"
        )
        expandButton.toolTip = expanded ? "收起终端输出" : "展开终端输出"
        expandButton.setAccessibilityLabel(expanded ? "收起终端输出" : "展开终端输出")
        openButton.isHidden = presentation.canOpenTerminal == false
        cancelButton.isHidden = presentation.canCancel == false
        saveButton.isHidden = presentation.canSaveRedactedLog == false
        outputLabel.invalidateIntrinsicContentSize()
    }

    public static func measuredHeight(
        for presentation: TerminalArtifactPresentation,
        expanded: Bool,
        width: CGFloat
    ) -> CGFloat {
        let tail = presentation.liveTail ?? ""
        guard expanded, tail.isEmpty == false else { return 112 }
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bounds = (tail as NSString).boundingRect(
            with: NSSize(width: max(120, width - 28), height: 220),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(272, max(132, ceil(bounds.height) + 84))
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("终端执行输出")

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("执行状态")
        metadataLabel.font = .systemFont(ofSize: 10.5)
        metadataLabel.textColor = .tertiaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.setAccessibilityLabel("执行元数据")
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.widthAnchor.constraint(equalToConstant: 15).isActive = true
        statusIconView.heightAnchor.constraint(equalToConstant: 15).isActive = true
        statusIconView.setAccessibilityLabel("终端类型")

        outputLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        outputLabel.alignment = .left
        outputLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        outputLabel.isSelectable = true
        outputLabel.lineBreakMode = .byCharWrapping
        outputLabel.cell?.wraps = true
        outputLabel.cell?.alignment = .left
        outputLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outputLabel.setAccessibilityLabel("脱敏终端输出")

        configureIconButton(
            copyButton,
            symbol: "doc.on.doc",
            label: "复制终端输出",
            action: #selector(copyOutput)
        )
        configureIconButton(
            expandButton,
            symbol: "chevron.down",
            label: "展开终端输出",
            action: #selector(toggleExpanded)
        )
        configureIconButton(
            openButton,
            symbol: "terminal",
            label: "在真实终端中查看",
            action: #selector(openTerminal)
        )
        configureIconButton(
            saveButton,
            symbol: "square.and.arrow.down",
            label: "保存脱敏日志",
            action: #selector(saveRedactedLog)
        )
        configureIconButton(
            cancelButton,
            symbol: "stop.fill",
            label: "停止当前执行",
            action: #selector(cancelExecution)
        )
        cancelButton.contentTintColor = .systemRed

        let header = NSStackView(views: [statusIconView, statusLabel, metadataLabel, NSView(), expandButton, copyButton, openButton, saveButton, cancelButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, outputLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 7
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outputLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private static func completionBasisTitle(_ value: String) -> String {
        switch value {
        case "agentCompletionMarker", "auditEndMarker": return "完成标记"
        case "shellPromptObserved": return "检测到终端提示符"
        case "outputIdle": return "输出结束"
        case "completed": return "执行完成"
        default: return "终端确认"
        }
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func copyOutput() {
        guard let text = presentation?.liveTail, text.isEmpty == false else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleExpanded() {
        guard expandButton.isEnabled else { return }
        expanded.toggle()
        if let presentation {
            apply(presentation, expanded: expanded)
        }
        onExpandedChange?(expanded)
    }

    @objc private func openTerminal() {
        guard let presentation,
              presentation.canOpenTerminal,
              let runtimeID = presentation.runtimeID else { return }
        onOpenTerminal?(runtimeID)
    }

    @objc private func cancelExecution() {
        guard let presentation,
              presentation.canCancel,
              let requestID = presentation.requestID else { return }
        onCancel?(requestID)
    }

    @objc private func saveRedactedLog() {
        guard let presentation, presentation.canSaveRedactedLog else { return }
        onSaveRedactedLog?(presentation)
    }
}
