import AppKit
import SwiftTerm

public enum TerminalCommandHintOverlayPresentationKind: Equatable {
    case hidden
    case submittedHint
    case completion
}

public enum TerminalCommandHintOverlayLayout {
    public static let completionPreferredWidth: CGFloat = 376
    public static let completionMinimumWidth: CGFloat = 280
    public static let submittedPreferredMaxWidth: CGFloat = 520
    public static let containerMargin: CGFloat = 12
    public static let terminalMargin: CGFloat = 8
    public static let verticalGap: CGFloat = 7

    public static func completionFrame(
        in container: NSView,
        terminalView: TerminalView,
        overlaySize: CGSize,
        caretFrameOverride: NSRect? = nil
    ) -> NSRect {
        let containerBounds = container.bounds
        let terminalFrame = terminalView.convert(terminalView.bounds, to: container)
        let caretFrame = caretFrameOverride ?? caretFrame(for: terminalView)
        let caretInContainer = terminalView.convert(caretFrame, to: container)
        let width = min(
            max(completionMinimumWidth, overlaySize.width),
            max(completionMinimumWidth, containerBounds.width - containerMargin * 2)
        )
        let height = max(44, overlaySize.height)
        let minimumX = max(containerMargin, terminalFrame.minX + terminalMargin)
        let maximumX = max(minimumX, containerBounds.width - width - containerMargin)
        let desiredX = caretInContainer.minX
        let x = min(max(desiredX, minimumX), maximumX)
        let bottomMargin = max(containerMargin, terminalFrame.minY + terminalMargin)
        let topMargin = min(containerBounds.height - containerMargin, terminalFrame.maxY - terminalMargin)
        let belowY = caretInContainer.minY - verticalGap - height
        let aboveY = caretInContainer.maxY + verticalGap
        let y: CGFloat
        if belowY >= bottomMargin {
            y = belowY
        } else if aboveY + height <= topMargin {
            y = aboveY
        } else {
            y = min(max(belowY, bottomMargin), max(bottomMargin, topMargin - height))
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    public static func caretFrame(for terminalView: TerminalView, characterOffset: Int = 0) -> NSRect {
        let cursor = terminalView.getTerminal().getCursorLocation()
        let caretFrame = terminalView.caretFrame
        let fallbackCellSize = CGSize(width: 8, height: 16)
        let cellSize = CGSize(
            width: caretFrame.width > 0 ? caretFrame.width : fallbackCellSize.width,
            height: caretFrame.height > 0 ? caretFrame.height : fallbackCellSize.height
        )
        return NSRect(
            x: CGFloat(cursor.x + characterOffset) * cellSize.width,
            y: max(0, terminalView.bounds.height - CGFloat(cursor.y + 1) * cellSize.height),
            width: cellSize.width,
            height: cellSize.height
        )
    }
}

public final class TerminalCommandHintOverlayView: NSVisualEffectView {
    private struct CompletionStyle {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let separatorColor: NSColor
        let primaryTextColor: NSColor
        let secondaryTextColor: NSColor
        let mutedTextColor: NSColor
        let accentColor: NSColor
        let replacementTextColor: NSColor
        let selectedBackgroundColor: NSColor
        let keyBackgroundColor: NSColor
        let shadowOpacity: Float
        let shadowRadius: CGFloat
        let shadowOffset: CGSize

        static let fallback = resolved(
            foreground: NSColor(calibratedWhite: 0.94, alpha: 1),
            background: NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.078, alpha: 1),
            accent: .controlAccentColor
        )

        static func resolved(foreground: NSColor?, background: NSColor?, accent: NSColor?) -> CompletionStyle {
            let terminalBackground = resolvedColor(background ?? .textBackgroundColor, fallback: .textBackgroundColor)
            let preferredForeground = resolvedColor(foreground ?? .textColor, fallback: .textColor)
            let accentColor = resolvedColor(accent ?? .controlAccentColor, fallback: .controlAccentColor)
            let isDark = luminance(of: terminalBackground) < 0.5
            let primary = readableForeground(preferredForeground, on: terminalBackground, isDark: isDark)
            let surface = (isDark ? terminalBackground : mix(terminalBackground, with: .white, amount: 0.30))
                .withAlphaComponent(isDark ? 0.72 : 0.96)
            let borderBase = isDark ? NSColor.white : NSColor.black
            let selectedBackground = isDark
                ? accentColor.withAlphaComponent(0.28)
                : mix(accentColor, with: .white, amount: 0.86).withAlphaComponent(0.96)
            let replacement = readableForeground(accentColor, on: selectedBackground, isDark: isDark)
            return CompletionStyle(
                backgroundColor: surface,
                borderColor: borderBase.withAlphaComponent(isDark ? 0.18 : 0.12),
                separatorColor: borderBase.withAlphaComponent(isDark ? 0.12 : 0.10),
                primaryTextColor: primary,
                secondaryTextColor: primary.withAlphaComponent(isDark ? 0.76 : 0.82),
                mutedTextColor: primary.withAlphaComponent(isDark ? 0.58 : 0.64),
                accentColor: accentColor,
                replacementTextColor: replacement,
                selectedBackgroundColor: selectedBackground,
                keyBackgroundColor: primary.withAlphaComponent(isDark ? 0.10 : 0.08),
                shadowOpacity: isDark ? 0.42 : 0.25,
                shadowRadius: isDark ? 24 : 23,
                shadowOffset: CGSize(width: 0, height: isDark ? -11 : -10)
            )
        }

        private static func readableForeground(_ preferred: NSColor, on background: NSColor, isDark: Bool) -> NSColor {
            let minimumContrast: CGFloat = isDark ? 4.5 : 6.0
            if contrast(preferred, background) >= minimumContrast {
                return preferred
            }
            return isDark ? .white : .black
        }

        private static func resolvedColor(_ color: NSColor, fallback: NSColor) -> NSColor {
            color.usingColorSpace(.deviceRGB)
                ?? fallback.usingColorSpace(.deviceRGB)
                ?? NSColor(calibratedWhite: 0, alpha: 1)
        }

        private static func mix(_ color: NSColor, with other: NSColor, amount: CGFloat) -> NSColor {
            let lhs = resolvedColor(color, fallback: .black)
            let rhs = resolvedColor(other, fallback: .white)
            let inverse = 1 - amount
            return NSColor(
                calibratedRed: lhs.redComponent * inverse + rhs.redComponent * amount,
                green: lhs.greenComponent * inverse + rhs.greenComponent * amount,
                blue: lhs.blueComponent * inverse + rhs.blueComponent * amount,
                alpha: lhs.alphaComponent * inverse + rhs.alphaComponent * amount
            )
        }

        private static func luminance(of color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let resolved = resolvedColor(color, fallback: .black)
            return 0.2126 * linear(resolved.redComponent)
                + 0.7152 * linear(resolved.greenComponent)
                + 0.0722 * linear(resolved.blueComponent)
        }

        private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
            let lhsLum = luminance(of: lhs)
            let rhsLum = luminance(of: rhs)
            return (max(lhsLum, rhsLum) + 0.05) / (min(lhsLum, rhsLum) + 0.05)
        }
    }

    private let contentStack = NSStackView()
    private var completionStyle = CompletionStyle.fallback
    private var currentCompletionSuggestion: TerminalCommandCompletionSuggestion?
    public var onVisibilityChanged: ((Bool) -> Void)?
    public private(set) var visibleTextForTesting = ""
    public private(set) var presentationKind: TerminalCommandHintOverlayPresentationKind = .hidden
    public private(set) var selectedCompletionIndexForTesting = 0
    public private(set) var completionChoiceCountForTesting = 0
    public private(set) var usesTerminalCompletionStyleForTesting = false
    public var completionBackgroundColorForTesting: NSColor { completionStyle.backgroundColor }
    public var completionPrimaryTextColorForTesting: NSColor { completionStyle.primaryTextColor }
    public var completionUsesFixedDarkAppearanceForTesting: Bool {
        appearance?.name == .vibrantDark
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("Stacio.Terminal.commandHintOverlay")
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.28)
        )
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public func applyCompletionTheme(foreground: NSColor?, background: NSColor?, accent: NSColor?) {
        completionStyle = CompletionStyle.resolved(
            foreground: foreground,
            background: background,
            accent: accent
        )
    }

    public func render(_ hint: TerminalSubmittedCommandHint?) {
        guard let hint else {
            clear()
            return
        }
        currentCompletionSuggestion = nil
        presentationKind = .submittedHint
        selectedCompletionIndexForTesting = 0
        completionChoiceCountForTesting = 0
        visibleTextForTesting = hint.visibleText
        toolTip = hint.visibleText
        applySubmittedHintStyle()
        rebuildContent {
            makeSubmittedHintView(text: hint.visibleText)
        }
        setVisible(true)
    }

    public func renderCompletion(_ suggestion: TerminalCommandCompletionSuggestion?) {
        guard let suggestion else {
            clear()
            return
        }
        currentCompletionSuggestion = suggestion
        presentationKind = .completion
        selectedCompletionIndexForTesting = suggestion.selectedIndex
        completionChoiceCountForTesting = suggestion.choices.count
        visibleTextForTesting = suggestion.visibleText
        toolTip = suggestion.visibleText
        applyCompletionStyle()
        rebuildContent {
            makeCompletionView(suggestion)
        }
        setVisible(true)
    }

    public func clear() {
        visibleTextForTesting = ""
        currentCompletionSuggestion = nil
        presentationKind = .hidden
        selectedCompletionIndexForTesting = 0
        completionChoiceCountForTesting = 0
        rebuildContent()
        toolTip = nil
        applySubmittedHintStyle()
        setVisible(false)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
    }

    public func refreshVisibleCompletionStyle() {
        guard presentationKind == .completion,
              let currentCompletionSuggestion
        else { return }
        applyCompletionStyle()
        rebuildContent {
            makeCompletionView(currentCompletionSuggestion)
        }
    }

    private func setVisible(_ visible: Bool) {
        isHidden = !visible
        onVisibilityChanged?(visible)
    }

    private func applySubmittedHintStyle() {
        usesTerminalCompletionStyleForTesting = false
        appearance = nil
        material = .hudWindow
        contentStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        StacioDesignSystem.setLayerBackgroundColor(self, color: nil)
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.28)
        )
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    private func applyCompletionStyle() {
        usesTerminalCompletionStyleForTesting = true
        appearance = nil
        material = .popover
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        StacioDesignSystem.setLayerBackgroundColor(self, color: completionStyle.backgroundColor)
        StacioDesignSystem.setLayerBorderColor(self, color: completionStyle.borderColor)
        layer?.shadowOpacity = completionStyle.shadowOpacity
        layer?.shadowRadius = completionStyle.shadowRadius
        layer?.shadowOffset = completionStyle.shadowOffset
    }

    private func rebuildContent(_ makeViews: () -> [NSView] = { [] }) {
        for subview in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for view in makeViews() {
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func makeSubmittedHintView(text: String) -> [NSView] {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -1)
        ])
        return [wrapper]
    }

    private func makeCompletionView(_ suggestion: TerminalCommandCompletionSuggestion) -> [NSView] {
        var views: [NSView] = [
            makeCompletionHeader(matchCount: suggestion.choices.count)
        ]
        for (index, choice) in suggestion.choices.prefix(6).enumerated() {
            views.append(makeCompletionRow(choice: choice, selected: index == suggestion.selectedIndex))
        }
        views.append(makeCompletionFooter())
        return views
    }

    private func makeCompletionHeader(matchCount: Int) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = completionStyle.mutedTextColor

        let title = makeLabel(
            "联想补全",
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: completionStyle.secondaryTextColor
        )
        let count = makeLabel(
            "\(matchCount) 条匹配",
            font: .systemFont(ofSize: 11, weight: .medium),
            color: completionStyle.mutedTextColor
        )
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(count)
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -7),
            wrapper.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        return wrapper
    }

    private func makeCompletionRow(choice: TerminalCommandCompletionChoice, selected: Bool) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 6
        wrapper.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            wrapper,
            color: selected
                ? completionStyle.selectedBackgroundColor
                : NSColor.clear
        )

        let accentBar = NSView()
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = 1
        StacioDesignSystem.setLayerBackgroundColor(
            accentBar,
            color: selected ? completionStyle.accentColor.withAlphaComponent(0.9) : NSColor.clear
        )

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: completionIconName(for: choice),
            accessibilityDescription: nil
        )
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = selected
            ? completionStyle.accentColor
            : completionStyle.mutedTextColor

        let commandLabel = NSTextField(labelWithAttributedString: attributedCommand(choice.displayCommand, replacement: choice.replacement))
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.maximumNumberOfLines = 1
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = makeLabel(
            choice.detail,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: selected ? completionStyle.secondaryTextColor : completionStyle.mutedTextColor
        )
        detailLabel.lineBreakMode = .byTruncatingTail

        wrapper.addSubview(accentBar)
        wrapper.addSubview(icon)
        wrapper.addSubview(commandLabel)
        wrapper.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 36),
            accentBar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            accentBar.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 2),
            accentBar.heightAnchor.constraint(equalToConstant: 20),
            icon.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            commandLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            commandLabel.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: commandLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])
        return wrapper
    }

    private func makeCompletionFooter() -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(
            separator,
            color: completionStyle.separatorColor
        )

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.addArrangedSubview(makeKeyHint(key: "↑↓", text: "选择"))
        stack.addArrangedSubview(makeKeyHint(key: "Enter", text: "执行"))
        stack.addArrangedSubview(makeKeyHint(key: "Tab", text: "填充"))
        stack.addArrangedSubview(makeKeyHint(key: "Esc", text: "关闭"))

        wrapper.addSubview(separator)
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            separator.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
            separator.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -1),
            wrapper.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
        return wrapper
    }

    private func makeKeyHint(key: String, text: String) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.addArrangedSubview(makeKeyCap(key))
        stack.addArrangedSubview(makeLabel(
            text,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: completionStyle.mutedTextColor
        ))
        return stack
    }

    private func makeKeyCap(_ text: String) -> NSTextField {
        let label = makeLabel(
            text,
            font: .monospacedSystemFont(ofSize: 10, weight: .semibold),
            color: completionStyle.secondaryTextColor
        )
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            label,
            color: completionStyle.keyBackgroundColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: max(24, CGFloat(text.count * 7))).isActive = true
        label.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return label
    }

    private func completionIconName(for choice: TerminalCommandCompletionChoice) -> String {
        switch choice.kind {
        case .history:
            return "clock.arrow.circlepath"
        case .path:
            return choice.detail == "目录" ? "folder" : "doc"
        case .command:
            return "terminal"
        }
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func attributedCommand(_ command: String, replacement: String) -> NSAttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
        let attributed = NSMutableAttributedString(
            string: command,
            attributes: [
                .font: baseFont,
                .foregroundColor: completionStyle.primaryTextColor
            ]
        )
        if let range = command.range(of: replacement, options: [.caseInsensitive]) {
            attributed.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: completionStyle.replacementTextColor
                ],
                range: NSRange(range, in: command)
            )
        }
        return attributed
    }
}
