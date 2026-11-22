import AppKit

final class AITranscriptProcessGroupView: NSView {
    private var entries: [AITranscriptEntry]
    private var elapsedText: String
    private let onToggle: () -> Void
    private let disclosureButton = NSButton()
    private let detailLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    /// Thin leading rail that visually demotes process steps to background
    /// narration, so the assistant answer stays the only reading target.
    private let processRail = NSView()
    private var renderedDetailMarkdown = ""
    private var detailTopConstraint: NSLayoutConstraint?
    private var separatorTopToDisclosureConstraint: NSLayoutConstraint?
    private var separatorTopToDetailConstraint: NSLayoutConstraint?
    private var lastAppliedCollapsedState: Bool?

    init(
        entries: [AITranscriptEntry],
        elapsedText: String,
        onToggle: @escaping () -> Void
    ) {
        self.entries = entries
        self.elapsedText = elapsedText
        self.onToggle = onToggle
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private var isCollapsed: Bool {
        entries.isEmpty == false && entries.allSatisfy(\.isCollapsed)
    }

    var summaryTextForTesting: String {
        disclosureButton.title
    }

    var detailAttributedStringForTesting: NSAttributedString {
        detailLabel.attributedStringValue
    }

    func update(entries: [AITranscriptEntry], elapsedText: String) {
        self.entries = entries
        self.elapsedText = elapsedText
        updateDetailContentIfNeeded()
        updatePresentation()
    }

    private func configure() {
        setAccessibilityIdentifier("Stacio.AI.transcript.processGroup")
        translatesAutoresizingMaskIntoConstraints = false

        disclosureButton.font = .systemFont(
            ofSize: StacioDesignSystem.theme.fontSizeFootnote,
            weight: .regular
        )
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.imagePosition = .imageTrailing
        disclosureButton.imageScaling = .scaleProportionallyDown
        disclosureButton.alignment = .left
        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .inline
        disclosureButton.target = self
        disclosureButton.action = #selector(togglePressed(_:))
        disclosureButton.setAccessibilityIdentifier("Stacio.AI.transcript.processDisclosure")
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.cell?.wraps = true
        detailLabel.cell?.usesSingleLineMode = false
        detailLabel.isSelectable = true
        detailLabel.allowsEditingTextAttributes = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        processRail.wantsLayer = true
        processRail.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(
            processRail,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.5)
        )
        
        addSubview(processRail)
        addSubview(disclosureButton)
        addSubview(detailLabel)
        addSubview(separator)
        let detailTop = detailLabel.topAnchor.constraint(equalTo: disclosureButton.bottomAnchor, constant: 8)
        let separatorTopToDisclosure = separator.topAnchor.constraint(
            equalTo: disclosureButton.bottomAnchor,
            constant: 8
        )
        let separatorTopToDetail = separator.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8)
        detailTopConstraint = detailTop
        separatorTopToDisclosureConstraint = separatorTopToDisclosure
        separatorTopToDetailConstraint = separatorTopToDetail
        NSLayoutConstraint.activate([
            processRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            processRail.topAnchor.constraint(equalTo: topAnchor, constant:6),
            processRail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            processRail.widthAnchor.constraint(equalToConstant:2),
            disclosureButton.leadingAnchor.constraint(equalTo: processRail.trailingAnchor, constant:10),
            disclosureButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            disclosureButton.topAnchor.constraint(equalTo: topAnchor, constant:6),
            detailLabel.leadingAnchor.constraint(equalTo: processRail.trailingAnchor, constant:10),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailTop,
            separator.leadingAnchor.constraint(equalTo: processRail.trailingAnchor, constant:10),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorTopToDisclosure,
            separatorTopToDetail,
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        updateDetailContentIfNeeded()
        updatePresentation()
    }

    private func updateDetailContentIfNeeded() {
        let detailMarkdown = entries.map(\.text).joined(separator: "\n\n")
        guard detailMarkdown != renderedDetailMarkdown else { return }
        renderedDetailMarkdown = detailMarkdown
        detailLabel.attributedStringValue = AIAssistantMarkdownRenderer.attributedString(
            from: detailMarkdown,
            baseFont: .systemFont(ofSize: 11),
            textColor: .secondaryLabelColor
        )
        detailLabel.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updatePresentation() {
        let collapsed = isCollapsed
        if disclosureButton.title != elapsedText {
            disclosureButton.title = elapsedText
        }
        guard lastAppliedCollapsedState != collapsed else { return }
        lastAppliedCollapsedState = collapsed
        disclosureButton.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: collapsed ? "展开处理过程" : "折叠处理过程"
        )
        disclosureButton.toolTip = collapsed ? "展开思考和执行过程" : "折叠思考和执行过程"
        detailLabel.isHidden = collapsed
        detailTopConstraint?.priority = collapsed ? .defaultLow : .required
        separatorTopToDisclosureConstraint?.priority = collapsed ? .required : .defaultLow
        separatorTopToDetailConstraint?.priority = collapsed ? .defaultLow : .required
        needsLayout = true
    }

    @objc private func togglePressed(_ sender: Any?) {
        onToggle()
    }
}

final class AITranscriptLinkLabel: NSTextField {
    // MARK: - Running shimmer

    /// Layers used only while the row is an active status line.
    private let shimmerLayer = CAGradientLayer()
    private let shimmerMask = CATextLayer()
    private(set) var isShimmering = false

    /// Paints a travelling gradient across the glyphs. Used for a running
    /// status row so an ongoing turn is visibly alive rather than static.
    func setRunningShimmer(_ enabled: Bool, fallbackColor: NSColor? = nil) {
        guard enabled != isShimmering else { return }
        isShimmering = enabled
        if enabled {
                installShimmerIfNeeded()
                startShimmer()
        } else {
                shimmerLayer.removeAllAnimations()
                shimmerLayer.isHidden = true
                if let fallbackColor { textColor = fallbackColor }
        }
    }
    var onOpenLink: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAsLabel()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAsLabel()
    }

    private func configureAsLabel() {
        cell = AITranscriptTextFieldCell(textCell: "")
        isEditable = false
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
    }

    private func installShimmerIfNeeded() {
        guard shimmerLayer.superlayer == nil else { return }
        wantsLayer = true
        shimmerMask.contentsScale = window?.backingScaleFactor ?? 2
        shimmerMask.alignmentMode = .left
        shimmerLayer.mask = shimmerMask
        shimmerLayer.isHidden = true
        shimmerLayer.startPoint = CGPoint(x:0, y:0.5)
        shimmerLayer.endPoint = CGPoint(x:1, y:0.5)
        shimmerLayer.locations = [0,0.35,0.5,0.65,1]
        shimmerLayer.colors = [
                NSColor.systemTeal.cgColor,
                NSColor.systemBlue.cgColor,
                NSColor.white.cgColor,
                NSColor.systemPurple.cgColor,
                NSColor.systemPink.cgColor
        ]
        layer?.addSublayer(shimmerLayer)
    }

    private func startShimmer() {
        shimmerLayer.isHidden = false
        shimmerMask.string = stringValue
        shimmerMask.font = font
        shimmerMask.fontSize = font?.pointSize ?? 12
        shimmerMask.foregroundColor = NSColor.white.cgColor
        syncShimmerGeometry()
        let travel = CABasicAnimation(keyPath: "locations")
        travel.fromValue = [-1.0, -0.6, -0.5, -0.4,0.0]
        travel.toValue = [1.0,1.4,1.5,1.6,2.0]
        travel.duration = 1.6
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        shimmerLayer.add(travel, forKey: "stacio.row.shimmer")
    }

    private func syncShimmerGeometry() {
        shimmerLayer.frame = bounds
        shimmerMask.frame = bounds
    }

    override func layout() {
        // Text reflows while streaming; cached cursor rects would keep the
        // pointer shape from the previous layout.
        window?.invalidateCursorRects(for: self)
        super.layout()
        guard isShimmering else { return }
        shimmerMask.string = stringValue
        syncShimmerGeometry()
    }

    override func mouseDown(with event: NSEvent) {
        guard let url = link(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onOpenLink?(url)
    }

    override func resetCursorRects() {
        // Deliberately no super call: a selectable field registers a text
        // cursor across its entire bounds, which is why the arrow never came
        // back over the empty tail of a short line. Register the text cursor
        // per used line instead.
        if hasLinks {
            addCursorRect(bounds, cursor: .pointingHand)
            return
        }
        guard let cell = cell as? AITranscriptTextFieldCell else { return }
        let textBounds = cell.drawingRect(forBounds: bounds)
        for rect in cell.glyphLineRects(forWidth: textBounds.width) {
            addCursorRect(
                rect.offsetBy(dx: textBounds.minX, dy: textBounds.minY),
                cursor: .iBeam
            )
        }
    }

    /// Drops the cached cursor rects so the next pointer move re-asks AppKit.
    func discardCursorRectsCache() {
        window?.invalidateCursorRects(for: self)
    }
    /// Whether any run carries a link, which keeps its pointing hand.
    private var hasLinks: Bool {
        var found = false
        attributedStringValue.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributedStringValue.length)
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
    func link(at point: NSPoint) -> URL? {
        guard let characterIndex = (cell as? AITranscriptTextFieldCell)?
            .characterIndex(at: point, in: bounds, isFlipped: isFlipped) else { return nil }
        let value = attributedStringValue.attribute(.link, at: characterIndex, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}

final class AITranscriptBubbleView: NSView {
    private var entry: AITranscriptEntry
    private let onToggle: () -> Void
    private let bubbleView = NSView()
    private let label = AITranscriptLinkLabel(frame: .zero)
    private let attachmentStack = NSStackView()
    private let disclosureButton = NSButton()
    private var executionCardView: ExecutionCardView?
    private var executionExpanded: Bool
    private let onOpenTerminal: (String) -> Void
    private let onCancelExecution: (String) -> Void
    private let onSaveRedactedLog: (TerminalArtifactPresentation) -> Void
    private let onExecutionExpandedChange: (Bool) -> Void
    private var renderedAssistantString: NSAttributedString?
    private var bubbleWidthConstraint: NSLayoutConstraint?
    private var lastAppliedBubbleWidth: CGFloat?
    private var lastAppliedLabelWidth: CGFloat?

    var preferredTextWidth: CGFloat = 240 {
        didSet {
            guard abs(preferredTextWidth - oldValue) > 0.5 else { return }
            updatePreferredWidth()
        }
    }

    init(
        entry: AITranscriptEntry,
        onOpenLink: @escaping (URL) -> Void = { _ in },
        onToggle: @escaping () -> Void = {},
        executionExpanded: Bool = false,
        onOpenTerminal: @escaping (String) -> Void = { _ in },
        onCancelExecution: @escaping (String) -> Void = { _ in },
        onSaveRedactedLog: @escaping (TerminalArtifactPresentation) -> Void = { _ in },
        onExecutionExpandedChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.entry = entry
        self.onToggle = onToggle
        self.executionExpanded = executionExpanded
        self.onOpenTerminal = onOpenTerminal
        self.onCancelExecution = onCancelExecution
        self.onSaveRedactedLog = onSaveRedactedLog
        self.onExecutionExpandedChange = onExecutionExpandedChange
        super.init(frame: .zero)
        label.onOpenLink = onOpenLink
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isAssistantForTesting: Bool {
        entry.role == .assistant
    }

    var attributedStringForTesting: NSAttributedString {
        label.attributedStringValue
    }

    var attachmentTitlesForTesting: [String] {
        attachmentStack.arrangedSubviews.compactMap {
            ($0 as? AITranscriptAttachmentCardView)?.titleForTesting
        }
    }

    var executionCardForTesting: ExecutionCardView? { executionCardView }

    @discardableResult
    func update(entry newEntry: AITranscriptEntry) -> Bool {
        guard entry.role == newEntry.role,
              entry.isProcessEntry == newEntry.isProcessEntry,
              entry.attachments == newEntry.attachments,
              (entry.executionCard == nil) == (newEntry.executionCard == nil)
        else {
            return false
        }

        // A streaming to settled transition must repaint even when the text is
        // unchanged, because table layout was deferred while it streamed.
        let displayTextChanged = entry.displayText != newEntry.displayText
        let streamingStateChanged = entry.isStreaming != newEntry.isStreaming
        let presentationChanged = displayTextChanged || streamingStateChanged
            || entry.isCollapsed != newEntry.isCollapsed
            || entry.executionCard != newEntry.executionCard
        entry = newEntry
        // Complete V2 snapshots include unchanged historical entries. Rewriting
        // font/textColor invalidates their attributed text and TextKit layout.
        guard presentationChanged else { return true }
        if let presentation = newEntry.executionCard {
            executionCardView?.apply(presentation, expanded: executionExpanded)
            invalidateIntrinsicContentSize()
            needsLayout = true
            return true
        }
        setAccessibilityIdentifier(entry.bubbleAccessibilityIdentifier)
        bubbleView.layer?.cornerRadius = entry.bubbleCornerRadius
        StacioDesignSystem.setLayerBackgroundColor(bubbleView, color: entry.bubbleColor)
        StacioDesignSystem.setLayerBorderColor(bubbleView, color: entry.borderColor)
        bubbleView.layer?.borderWidth = entry.borderColor == nil ? 0 : 1
        label.setAccessibilityIdentifier(entry.textAccessibilityIdentifier)
        label.font = entry.font
        label.textColor = entry.textColor

        if displayTextChanged || streamingStateChanged {
            if entry.role == .assistant {
                let renderedString = AIAssistantMarkdownRenderer.attributedString(
                    from: entry.displayText,
                    baseFont: entry.font,
                    textColor: entry.textColor,
                    allowsTables: true
                )
                renderedAssistantString = renderedString
                label.attributedStringValue = renderedString
            } else {
                renderedAssistantString = nil
                label.stringValue = entry.displayText
            }
            label.invalidateIntrinsicContentSize()

        // A running status line gets a travelling gradient so an ongoing turn
        // is visibly alive. Any other row keeps plain, static text.
        let isRunningStatus = entry.role == .step
            && entry.displayText.contains("执行中")
        label.setRunningShimmer(isRunningStatus)
        bubbleView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        }
        updateDisclosureButton()
        updatePreferredWidth()
        needsLayout = true
        return true
    }

    override func layout() {
        restoreAssistantFormattingIfNeeded()
        super.layout()
        updatePreferredWidth()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        restoreAssistantFormattingIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreAssistantFormattingIfNeeded()
    }

    private func configure() {
        setAccessibilityIdentifier(entry.bubbleAccessibilityIdentifier)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.wantsLayer = true
        bubbleView.layer?.cornerRadius = entry.bubbleCornerRadius
        bubbleView.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(bubbleView, color: entry.bubbleColor)
        StacioDesignSystem.setLayerBorderColor(bubbleView, color: entry.borderColor)
        bubbleView.layer?.borderWidth = entry.borderColor == nil ? 0 : 1

        label.stringValue = entry.displayText
        label.discardCursorRectsCache()
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.setAccessibilityIdentifier(entry.textAccessibilityIdentifier)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.font = entry.font
        label.textColor = entry.textColor
        if entry.role == .assistant {
            let renderedString = AIAssistantMarkdownRenderer.attributedString(
                from: entry.displayText,
                baseFont: entry.font,
                textColor: entry.textColor,
                allowsTables: true
            )
            renderedAssistantString = renderedString
            label.attributedStringValue = renderedString
            label.discardCursorRectsCache()
        }
        label.preferredMaxLayoutWidth = preferredTextWidth
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(bubbleView)
        if let presentation = entry.executionCard {
            let card = ExecutionCardView()
            executionCardView = card
            card.onOpenTerminal = onOpenTerminal
            card.onCancel = onCancelExecution
            card.onSaveRedactedLog = onSaveRedactedLog
            card.onExpandedChange = { [weak self] expanded in
                guard let self else { return }
                self.executionExpanded = expanded
                self.invalidateIntrinsicContentSize()
                self.bubbleView.invalidateIntrinsicContentSize()
                self.needsLayout = true
                self.onExecutionExpandedChange(expanded)
            }
            bubbleView.addSubview(card)
            bubbleWidthConstraint = bubbleView.widthAnchor.constraint(
                lessThanOrEqualToConstant: preferredTextWidth
            )
            bubbleWidthConstraint?.isActive = true
            NSLayoutConstraint.activate([
                bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: entry.verticalInset),
                bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -entry.verticalInset),
                bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
                card.topAnchor.constraint(equalTo: bubbleView.topAnchor),
                card.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor)
            ])
            card.apply(presentation, expanded: executionExpanded)
            return
        }
        bubbleView.addSubview(label)
        if entry.attachments.isEmpty == false {
            attachmentStack.orientation = .vertical
            attachmentStack.spacing = 6
            attachmentStack.alignment = .leading
            attachmentStack.distribution = .fill
            attachmentStack.translatesAutoresizingMaskIntoConstraints = false
            attachmentStack.setAccessibilityIdentifier("Stacio.AI.transcript.attachments")
            bubbleView.addSubview(attachmentStack)
            for (index, attachment) in entry.attachments.enumerated() {
                let card = AITranscriptAttachmentCardView(attachment: attachment, index: index)
                attachmentStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: attachmentStack.widthAnchor).isActive = true
                card.heightAnchor.constraint(equalToConstant: 50).isActive = true
            }
        }
        if entry.isProcessEntry {
            disclosureButton.title = ""
            disclosureButton.isBordered = false
            disclosureButton.imageScaling = .scaleProportionallyDown
            disclosureButton.target = self
            disclosureButton.action = #selector(togglePressed(_:))
            disclosureButton.setAccessibilityIdentifier("Stacio.AI.transcript.processDisclosure")
            disclosureButton.translatesAutoresizingMaskIntoConstraints = false
            updateDisclosureButton()
            bubbleView.addSubview(disclosureButton)
        }

        bubbleWidthConstraint = bubbleView.widthAnchor.constraint(lessThanOrEqualToConstant: preferredTextWidth)
        bubbleWidthConstraint?.isActive = true

        var constraints: [NSLayoutConstraint] = [
            bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: entry.verticalInset),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -entry.verticalInset),
            label.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: entry.horizontalPadding),
            label.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -entry.verticalPadding)
        ]
        if entry.attachments.isEmpty {
            constraints.append(
                label.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: entry.verticalPadding)
            )
        } else {
            constraints += [
                attachmentStack.leadingAnchor.constraint(
                    equalTo: bubbleView.leadingAnchor,
                    constant: entry.horizontalPadding
                ),
                attachmentStack.trailingAnchor.constraint(
                    equalTo: bubbleView.trailingAnchor,
                    constant: -entry.horizontalPadding
                ),
                attachmentStack.topAnchor.constraint(
                    equalTo: bubbleView.topAnchor,
                    constant: entry.verticalPadding
                ),
                label.topAnchor.constraint(equalTo: attachmentStack.bottomAnchor, constant: 8)
            ]
        }
        if entry.isProcessEntry {
            constraints += [
                disclosureButton.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -8),
                disclosureButton.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 7),
                disclosureButton.widthAnchor.constraint(equalToConstant: 18),
                disclosureButton.heightAnchor.constraint(equalToConstant: 18),
                label.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor, constant: -6)
            ]
        } else {
            constraints.append(
                label.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -entry.horizontalPadding)
            )
        }

        switch entry.role {
        case .user:
            constraints += [
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44)
            ]
        case .assistant:
            constraints += [
                bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)
            ]
        case .system:
            constraints += [
                bubbleView.centerXAnchor.constraint(equalTo: centerXAnchor),
                bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
                bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
            ]
        case .command, .terminal, .plan, .step:
            constraints += [
                bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func togglePressed(_ sender: Any?) {
        onToggle()
    }

    private func updateDisclosureButton() {
        guard entry.isProcessEntry else { return }
        disclosureButton.image = NSImage(
            systemSymbolName: entry.isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: entry.isCollapsed ? "展开过程" : "折叠过程"
        )
        disclosureButton.toolTip = entry.isCollapsed ? "展开思考和执行过程" : "折叠思考和执行过程"
    }

    func resetAssistantAttributedStringForTesting() {
        guard let renderedAssistantString else { return }
        label.stringValue = renderedAssistantString.string
    }

    private func restoreAssistantFormattingIfNeeded() {
        guard let renderedAssistantString,
              label.attributedStringValue.isEqual(to: renderedAssistantString) == false
        else {
            return
        }
        label.attributedStringValue = renderedAssistantString
        label.discardCursorRectsCache()
    }

    private func updatePreferredWidth() {
        let width = max(80, preferredTextWidth)
        // Width comes from the role semantics rather than a local switch, so the
        // visual contract lives in one place for every call site. Only roles that
        // are capped by design take a hard limit; content roles may use the full
        // column so long answers are never squeezed.
        let roleCap = entry.role == .user ? CGFloat(380) : (entry.role == .system ? CGFloat(360) : .greatestFiniteMagnitude)
        let maxBubbleWidth = min(width * entry.role.transcriptMaxWidthRatio, roleCap)
        let disclosureWidth: CGFloat = entry.isProcessEntry ? 28 : 0
        let labelWidth = max(40, maxBubbleWidth - entry.horizontalPadding * 2 - disclosureWidth)
        if lastAppliedBubbleWidth.map({ abs($0 - maxBubbleWidth) > 0.5 }) ?? true {
            bubbleWidthConstraint?.constant = maxBubbleWidth
            lastAppliedBubbleWidth = maxBubbleWidth
        }
        if lastAppliedLabelWidth.map({ abs($0 - labelWidth) > 0.5 }) ?? true {
            label.preferredMaxLayoutWidth = labelWidth
            lastAppliedLabelWidth = labelWidth
        }
    }
}

final class AITranscriptAttachmentCardView: NSView {
    private let attachment: AITranscriptAttachment

    init(attachment: AITranscriptAttachment, index: Int) {
        self.attachment = attachment
        super.init(frame: .zero)
        configure(index: index)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var titleForTesting: String {
        attachment.filename
    }

    private func configure(index: Int) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        StacioDesignSystem.setLayerBackgroundColor(self, color: NSColor.white.withAlphaComponent(0.13))
        StacioDesignSystem.setLayerBorderColor(self, color: NSColor.white.withAlphaComponent(0.18))
        setAccessibilityIdentifier("Stacio.AI.transcript.attachment.\(index)")
        setAccessibilityLabel("附件：\(attachment.filename)，\(attachment.metadataText)")

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: attachment.isImage ? "photo" : "doc.text",
            accessibilityDescription: attachment.filename
        )
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: attachment.filename)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let metadata = NSTextField(labelWithString: attachment.metadataText)
        metadata.font = .systemFont(ofSize: 10, weight: .medium)
        metadata.textColor = NSColor.white.withAlphaComponent(0.72)
        metadata.lineBreakMode = .byTruncatingTail
        metadata.translatesAutoresizingMaskIntoConstraints = false

        [icon, title, metadata].forEach(addSubview)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
    }
}
