/// A button that shows a pointing-hand cursor and a subtle hover fill.
///
/// AppKit buttons keep the arrow cursor unless the control opts in, and the
/// floating controls in the assistant surface are small enough that the
/// cursor change is the reader's main cue that they are interactive.
final class AIHoverButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    /// Fill drawn behind the content while the pointer is inside.
    var hoverFillColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
    /// Resting fill, restored when the pointer leaves.
    var restingFillColor: NSColor = .clear

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        NSCursor.pointingHand.set()
        applyHoverFill()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        applyHoverFill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyHoverFill() {
        StacioDesignSystem.setLayerBackgroundColor(
                self,
                color: isHovered ? hoverFillColor : restingFillColor
        )
    }
}

import AppKit

final class AIComposerDropPasteView: NSView {
    var onPasteAttachments: ((NSPasteboard) -> Bool)?
    var onDropAttachments: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
        if isPaste, onPasteAttachments?(NSPasteboard.general) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropAttachments?(sender.draggingPasteboard) ?? false
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            || NSImage(pasteboard: pasteboard) != nil
    }
}

final class AIComposerAttachmentCardView: NSView {
    var onDelete: ((Int) -> Void)?
    var onPreview: ((Int) -> Void)?

    private let attachment: AIAssistantAttachment
    private let index: Int
    private let previewButton = NSButton()
    private let deleteButton = NSButton()

    init(attachment: AIAssistantAttachment, index: Int) {
        self.attachment = attachment
        self.index = index
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        if attachment.isImage {
            StacioDesignSystem.setLayerBackgroundColor(self, color: .clear)
            setupImageCard()
        } else {
            StacioDesignSystem.setLayerBackgroundColor(
                self,
                color: NSColor.controlBackgroundColor.withAlphaComponent(0.62)
            )
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            setupFileCard()
        }
        setupDeleteButton()
    }

    private func setupImageCard() {
        previewButton.title = ""
        previewButton.isBordered = false
        previewButton.image = attachment.previewImage ?? NSImage(systemSymbolName: "photo", accessibilityDescription: attachment.filename)
        previewButton.imageScaling = .scaleAxesIndependently
        previewButton.target = self
        previewButton.action = #selector(previewPressed(_:))
        previewButton.toolTip = attachment.filename
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.wantsLayer = true
        previewButton.layer?.cornerRadius = 9
        previewButton.layer?.cornerCurve = .continuous
        previewButton.layer?.masksToBounds = true
        previewButton.setAccessibilityIdentifier("Stacio.AI.composer.attachment.\(index)")
        addSubview(previewButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 54),
            previewButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewButton.topAnchor.constraint(equalTo: topAnchor),
            previewButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupFileCard() {
        previewButton.title = ""
        previewButton.isBordered = false
        previewButton.target = self
        previewButton.action = #selector(previewPressed(_:))
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.setAccessibilityIdentifier("Stacio.AI.composer.attachment.\(index)")
        addSubview(previewButton)

        let iconBox = NSView()
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 9
        iconBox.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            iconBox,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        )
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: attachment.filename)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        iconBox.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: attachment.filename)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let typeLabel = NSTextField(labelWithString: attachment.displayKind)
        typeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.translatesAutoresizingMaskIntoConstraints = false

        [iconBox, titleLabel, typeLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 210),
            previewButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewButton.topAnchor.constraint(equalTo: topAnchor),
            previewButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 36),
            iconBox.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            typeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            typeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            typeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])
    }

    private func setupDeleteButton() {
        deleteButton.title = ""
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "删除附件")
        deleteButton.imageScaling = .scaleProportionallyDown
        deleteButton.contentTintColor = .labelColor
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed(_:))
        deleteButton.toolTip = "删除附件"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = 12
        deleteButton.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            deleteButton,
            color: NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        )
        deleteButton.setAccessibilityIdentifier("Stacio.AI.composer.attachment.delete.\(index)")
        addSubview(deleteButton)
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),
            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: -3),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3)
        ])
    }

    @objc
    private func deletePressed(_ sender: NSButton) {
        onDelete?(index)
    }

    @objc
    private func previewPressed(_ sender: NSButton) {
        onPreview?(index)
    }
}

final class AIComposerAttachmentPreviewView: NSView {
    private let attachment: AIAssistantAttachment

    init(attachment: AIAssistantAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 620))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(self, color: NSColor.windowBackgroundColor)
        if attachment.isImage, let image = attachment.previewImage {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
                imageView.topAnchor.constraint(equalTo: topAnchor, constant: 54),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28)
            ])
        } else {
            let scrollView = NSScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            let text = NSTextView()
            text.isEditable = false
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.textColor = .labelColor
            text.string = attachment.textPreview ?? attachment.promptSummary
            scrollView.documentView = text
            addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
                scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 72),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28)
            ])
        }

        let title = NSTextField(labelWithString: attachment.filename)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 24)
        ])
    }
}

extension AIAssistantAttachment {
    var previewImage: NSImage? {
        if let localFileURL,
           let image = NSImage(contentsOf: localFileURL) {
            return image
        }
        guard let base64Data,
              let data = Data(base64Encoded: base64Data)
        else {
            return nil
        }
        return NSImage(data: data)
    }

    var displayKind: String {
        let ext = (filename as NSString).pathExtension
        if ext.isEmpty == false {
            return ext.uppercased()
        }
        return mimeType
    }
}

final class AIComposerAddPickerViewController: NSViewController {
    var onAddFiles: (() -> Void)?
    var onAddCurrentFile: (() -> Void)?
    var onTogglePlan: (() -> Void)?
    var onToggleGoal: (() -> Void)?

    private let stack = NSStackView()
    private let addFilesButton = NSButton()
    private let addCurrentFileButton = NSButton()
    private let planButton = NSButton()
    private let goalButton = NSButton()
    private var planModeEnabled: Bool
    private var goalModeEnabled: Bool
    private var currentFileEnabled: Bool
    private let showsAttachments: Bool
    private let showsGoalMode: Bool
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 4
    private static let inset: CGFloat = 10

    init(
        planModeEnabled: Bool,
        goalModeEnabled: Bool,
        currentFileEnabled: Bool,
        showsAttachments: Bool = true,
        showsGoalMode: Bool = true
    ) {
        self.planModeEnabled = planModeEnabled
        self.goalModeEnabled = goalModeEnabled
        self.currentFileEnabled = currentFileEnabled
        self.showsAttachments = showsAttachments
        self.showsGoalMode = showsGoalMode
        super.init(nibName: nil, bundle: nil)
        let visibleRowCount = (showsAttachments ? 2 : 0) + 1 + (showsGoalMode ? 1 : 0)
        let contentInset = showsAttachments && showsGoalMode ? CGFloat(4) : Self.inset
        let height = contentInset * 2
            + CGFloat(visibleRowCount) * Self.rowHeight
            + CGFloat(max(0, visibleRowCount - 1)) * Self.rowSpacing
        preferredContentSize = NSSize(width: 172, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)

        stack.orientation = .vertical
        stack.spacing = Self.rowSpacing
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(
            addFilesButton,
            title: "添加照片和文件",
            symbolName: "paperclip",
            action: #selector(addFilesPressed(_:))
        )
        configureActionButton(
            addCurrentFileButton,
            title: "附加当前文件",
            symbolName: "doc.text.magnifyingglass",
            action: #selector(addCurrentFilePressed(_:))
        )
        configureActionButton(
            planButton,
            title: "计划模式",
            symbolName: "list.bullet.rectangle",
            action: #selector(planPressed(_:))
        )
        configureActionButton(
            goalButton,
            title: "追求目标",
            symbolName: "scope",
            action: #selector(goalPressed(_:))
        )

        var visibleButtons: [NSButton] = []
        if showsAttachments {
            visibleButtons.append(contentsOf: [addFilesButton, addCurrentFileButton])
        }
        visibleButtons.append(planButton)
        if showsGoalMode {
            visibleButtons.append(goalButton)
        }
        visibleButtons.forEach { button in
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        container.addSubview(stack)

        let contentInset = showsAttachments && showsGoalMode ? CGFloat(4) : Self.inset
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: contentInset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -contentInset)
        ])

        view = container
        update(
            planModeEnabled: planModeEnabled,
            goalModeEnabled: goalModeEnabled,
            currentFileEnabled: currentFileEnabled
        )
    }

    func update(planModeEnabled: Bool, goalModeEnabled: Bool, currentFileEnabled: Bool) {
        self.planModeEnabled = planModeEnabled
        self.goalModeEnabled = goalModeEnabled
        self.currentFileEnabled = currentFileEnabled
        guard isViewLoaded else { return }
        addCurrentFileButton.isEnabled = currentFileEnabled
        addCurrentFileButton.contentTintColor = currentFileEnabled ? .labelColor : .disabledControlTextColor
        updateToggleButton(planButton, isOn: planModeEnabled)
        if showsGoalMode {
            updateToggleButton(goalButton, isOn: goalModeEnabled)
        }
    }

    private func configureActionButton(
        _ button: NSButton,
        title: String,
        symbolName: String,
        action: Selector
    ) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.cornerCurve = .continuous
        button.contentTintColor = .labelColor
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.56)
        )
    }

    private func updateToggleButton(_ button: NSButton, isOn: Bool) {
        button.state = isOn ? .on : .off
        button.contentTintColor = isOn ? .controlAccentColor : .labelColor
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: isOn
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
        )
    }

    @objc
    private func addFilesPressed(_ sender: NSButton) {
        onAddFiles?()
    }

    @objc
    private func addCurrentFilePressed(_ sender: NSButton) {
        onAddCurrentFile?()
    }

    @objc
    private func planPressed(_ sender: NSButton) {
        onTogglePlan?()
    }

    @objc
    private func goalPressed(_ sender: NSButton) {
        onToggleGoal?()
    }

    var actionTitlesForTesting: [String] {
        loadViewIfNeeded()
        var titles: [String] = []
        if showsAttachments {
            titles.append(contentsOf: [addFilesButton.title, addCurrentFileButton.title])
        }
        titles.append(planButton.title)
        if showsGoalMode { titles.append(goalButton.title) }
        return titles
    }

    var currentFileEnabledForTesting: Bool {
        loadViewIfNeeded()
        return addCurrentFileButton.isEnabled
    }

    var preferredSizeForTesting: NSSize {
        preferredContentSize
    }

    var actionButtonHeightsForTesting: [CGFloat] {
        loadViewIfNeeded()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.layoutSubtreeIfNeeded()
        var buttons: [NSButton] = []
        if showsAttachments {
            buttons.append(contentsOf: [addFilesButton, addCurrentFileButton])
        }
        buttons.append(planButton)
        if showsGoalMode { buttons.append(goalButton) }
        return buttons.map(\.frame.height)
    }
}

    struct AIComposerPermissionPickerState {
        let currentPolicy: AgentConfirmationPolicyPreference
        // Each row carries its own symbol so the three levels are told apart
        // at a glance rather than by reading the label.
        let items: [(title: String, policy: AgentConfirmationPolicyPreference, symbol: String)]
    }

final class AIComposerPermissionPickerViewController: NSViewController {
    var onSelectPolicy: ((AgentConfirmationPolicyPreference) -> Void)?

    private let stack = NSStackView()
    private var buttons: [AIComposerPermissionButton] = []
    private var state: AIComposerPermissionPickerState
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 4
    private static let inset: CGFloat = 10

    init(state: AIComposerPermissionPickerState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 168, height: 144)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)

        stack.orientation = .vertical
        stack.spacing = Self.rowSpacing
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("Stacio.AI.composer.permissionPicker")
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -Self.inset)
        ])

        view = container
        update(state: state)
    }

    func update(state: AIComposerPermissionPickerState) {
        self.state = state
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons = state.items.map { item in
            let button = AIComposerPermissionButton(
                title: item.title,
                target: self,
                action: #selector(policyPressed(_:))
            )
            button.policy = item.policy
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 11, weight: .medium)
                                                button.image = NSImage(
                                                                systemSymbolName: item.policy == state.currentPolicy ? "checkmark.circle.fill" : item.symbol,
                                                                accessibilityDescription: item.title
                                                )
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = item.policy == state.currentPolicy
                ? .controlAccentColor
                : .secondaryLabelColor
            button.toolTip = item.title
            button.setAccessibilityIdentifier("Stacio.AI.composer.permissionPicker.\(item.policy.rawValue)")
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.cornerCurve = .continuous
            StacioDesignSystem.setLayerBackgroundColor(
                button,
                color: item.policy == state.currentPolicy
                    ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
            )
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            return button
        }
    }

    @objc
    private func policyPressed(_ sender: AIComposerPermissionButton) {
        onSelectPolicy?(sender.policy)
    }

    var policyTitlesForTesting: [String] {
        loadViewIfNeeded()
        return buttons.map(\.title)
    }

    var preferredSizeForTesting: NSSize {
        preferredContentSize
    }

    var buttonHeightsForTesting: [CGFloat] {
        loadViewIfNeeded()
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
        view.layoutSubtreeIfNeeded()
        return buttons.map(\.frame.height)
    }
}

final class AIComposerPrimaryActionButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

final class AIComposerPermissionButton: NSButton {
    var policy: AgentConfirmationPolicyPreference = .requireEveryCommand
}

struct AIComposerModelPickerGroup {
    let providerID: UUID
    let providerTitle: String
    let models: [AIModelSelection]
}

struct AIComposerLocalAgentPickerOption {
    let configuration: LocalAgentPassthroughConfiguration
}

struct AIComposerLegacyLocalAgentPickerOption {
    let tool: LocalAgentTool
}

struct AIComposerModelPickerSpecialOption {
    let title: String
    let selection: AIModelSelection?
    let toolTip: String
    let accessibilityIdentifier: String
}

struct AIComposerModelPickerState {
    let providerTitle: String
    let currentSelection: AIModelSelection?
    let currentRuntimeSelection: AgentRuntimeSelection?
    let currentLegacyLocalAgentTool: LocalAgentTool?
    let specialOptions: [AIComposerModelPickerSpecialOption]
    let groups: [AIComposerModelPickerGroup]
    let localAgentOptions: [AIComposerLocalAgentPickerOption]
    let legacyLocalAgentOptions: [AIComposerLegacyLocalAgentPickerOption]
    let localAgentSettingsActionTitle: String?
    let reasoningItems: [(title: String, effort: AIReasoningEffortPreference)]
    let currentReasoning: AIReasoningEffortPreference
    let contextFraction: Double
    let contextLabel: String
    let runtimeSelectionEnabled: Bool
}

final class AIComposerModelPickerViewController: NSViewController {
    private static let width: CGFloat = 360
    private static let verticalPadding: CGFloat = 32
    private static let headerHeight: CGFloat = 62
    private static let rootSpacingTotal: CGFloat = 56
    private static let sectionLabelHeight: CGFloat = 14
    private static let modelRowHeight: CGFloat = 30
    private static let modelRowSpacing: CGFloat = 6
    private static let reasoningHeight: CGFloat = 30
    private static let minimumHeight: CGFloat = 246
    private static let maximumHeight: CGFloat = 350
    private static let maximumModelListHeight: CGFloat = 144

    var onSelectModel: ((AIModelSelection?) -> Void)?
    var onSelectLocalAgent: ((LocalAgentPassthroughConfiguration) -> Void)?
    var onSelectLegacyLocalAgent: ((LocalAgentTool) -> Void)?
    var onOpenLocalAgentSettings: (() -> Void)?
    var onSelectReasoning: ((AIReasoningEffortPreference) -> Void)?

    private let rootStack = NSStackView()
    private let providerLabel = NSTextField(labelWithString: "")
    private let contextRing = AIContextUsageRingView()
    private let contextPercentLabel = NSTextField(labelWithString: "")
    private let contextCaptionLabel = NSTextField(labelWithString: "上下文")
    private let modelsScrollView = NSScrollView()
    private let modelsDocumentView = AIAssistantFlippedView()
    private let modelsStack = NSStackView()
    private let reasoningHeader = NSTextField(labelWithString: "推理强度")
    private let reasoningControl = NSSegmentedControl()
    private var modelsScrollHeightConstraint: NSLayoutConstraint?
    private var state: AIComposerModelPickerState

    init(state: AIComposerModelPickerState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.preferredSize(for: state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)

        rootStack.orientation = .vertical
        rootStack.spacing = 14
        rootStack.alignment = .leading
        rootStack.distribution = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 14
        headerStack.alignment = .top
        headerStack.distribution = .fill
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let ringContainer = NSView()
        ringContainer.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.wantsLayer = true
        ringContainer.layer?.cornerRadius = 28
        ringContainer.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            ringContainer,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.74)
        )

        contextRing.translatesAutoresizingMaskIntoConstraints = false
        contextPercentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        contextPercentLabel.textColor = .labelColor
        contextPercentLabel.alignment = .center
        contextPercentLabel.translatesAutoresizingMaskIntoConstraints = false
        contextCaptionLabel.font = .systemFont(ofSize: 10, weight: .medium)
        contextCaptionLabel.textColor = .secondaryLabelColor
        contextCaptionLabel.alignment = .center
        contextCaptionLabel.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.addSubview(contextRing)
        ringContainer.addSubview(contextPercentLabel)
        ringContainer.addSubview(contextCaptionLabel)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 3
        titleStack.alignment = .leading
        titleStack.distribution = .fill
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: "选择模型")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.title")
        providerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        providerLabel.textColor = .secondaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingMiddle
        providerLabel.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.provider")
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(providerLabel)

        headerStack.addArrangedSubview(ringContainer)
        headerStack.addArrangedSubview(titleStack)
        titleStack.widthAnchor.constraint(equalTo: headerStack.widthAnchor, constant: -76).isActive = true

        let modelsHeader = makeSectionLabel("模型")
        modelsScrollView.translatesAutoresizingMaskIntoConstraints = false
        modelsScrollView.drawsBackground = false
        modelsScrollView.borderType = .noBorder
        modelsScrollView.hasVerticalScroller = true
        modelsScrollView.autohidesScrollers = true
        modelsScrollView.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.models")

        modelsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        modelsStack.orientation = .vertical
        modelsStack.spacing = 6
        modelsStack.alignment = .leading
        modelsStack.distribution = .fill
        modelsStack.translatesAutoresizingMaskIntoConstraints = false
        modelsStack.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.modelRows")
        modelsDocumentView.addSubview(modelsStack)
        modelsScrollView.documentView = modelsDocumentView

        reasoningHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        reasoningHeader.textColor = .secondaryLabelColor
        reasoningHeader.translatesAutoresizingMaskIntoConstraints = false
        reasoningHeader.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.reasoningHeader")
        reasoningControl.target = self
        reasoningControl.action = #selector(reasoningChanged(_:))
        reasoningControl.segmentStyle = .texturedRounded
        reasoningControl.translatesAutoresizingMaskIntoConstraints = false
        reasoningControl.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.reasoning")

        [
            headerStack,
            modelsHeader,
            modelsScrollView,
            reasoningHeader,
            reasoningControl
        ].forEach { view in
            rootStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
        container.addSubview(rootStack)

        let modelsScrollHeightConstraint = modelsScrollView.heightAnchor.constraint(
            equalToConstant: Self.modelListHeight(for: state)
        )
        self.modelsScrollHeightConstraint = modelsScrollHeightConstraint

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),

            ringContainer.widthAnchor.constraint(equalToConstant: 62),
            ringContainer.heightAnchor.constraint(equalToConstant: 62),
            contextRing.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            contextRing.centerYAnchor.constraint(equalTo: ringContainer.centerYAnchor, constant: -4),
            contextRing.widthAnchor.constraint(equalToConstant: 42),
            contextRing.heightAnchor.constraint(equalToConstant: 42),
            contextPercentLabel.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            contextPercentLabel.centerYAnchor.constraint(equalTo: contextRing.centerYAnchor),
            contextCaptionLabel.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            contextCaptionLabel.bottomAnchor.constraint(equalTo: ringContainer.bottomAnchor, constant: -8),
            modelsDocumentView.leadingAnchor.constraint(equalTo: modelsScrollView.contentView.leadingAnchor),
            modelsDocumentView.trailingAnchor.constraint(equalTo: modelsScrollView.contentView.trailingAnchor),
            modelsDocumentView.topAnchor.constraint(equalTo: modelsScrollView.contentView.topAnchor),
            modelsDocumentView.widthAnchor.constraint(equalTo: modelsScrollView.contentView.widthAnchor),
            modelsStack.leadingAnchor.constraint(equalTo: modelsDocumentView.leadingAnchor),
            modelsStack.trailingAnchor.constraint(equalTo: modelsDocumentView.trailingAnchor),
            modelsStack.topAnchor.constraint(equalTo: modelsDocumentView.topAnchor),
            modelsStack.bottomAnchor.constraint(equalTo: modelsDocumentView.bottomAnchor),
            modelsScrollHeightConstraint,
            reasoningControl.heightAnchor.constraint(equalToConstant: 30)
        ])

        view = container
        update(state: state)
    }

    func update(state: AIComposerModelPickerState) {
        self.state = state
        preferredContentSize = Self.preferredSize(for: state)
        guard isViewLoaded else { return }
        providerLabel.stringValue = state.providerTitle
        contextRing.fraction = state.contextFraction
        contextRing.toolTip = state.contextLabel
        contextRing.setAccessibilityLabel(state.contextLabel)
        contextPercentLabel.stringValue = contextPercentText(for: state.contextFraction)
        renderModels()
        modelsScrollHeightConstraint?.constant = Self.modelListHeight(for: state)
        renderReasoning()
        let showsReasoning = Self.showsReasoningSection(for: state)
        reasoningHeader.isHidden = showsReasoning == false
        reasoningControl.isHidden = showsReasoning == false
    }

    private func renderModels() {
        modelsStack.arrangedSubviews.forEach { view in
            modelsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if state.specialOptions.isEmpty,
           state.groups.isEmpty,
           state.localAgentOptions.isEmpty,
           state.localAgentSettingsActionTitle == nil {
            let empty = NSTextField(labelWithString: "还没有可选模型")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            modelsStack.addArrangedSubview(empty)
            return
        }
        for option in state.specialOptions {
            let button = AIComposerModelButton(
                title: option.title,
                target: self,
                action: #selector(modelPressed(_:))
            )
            button.selection = option.selection
            button.isEnabled = state.runtimeSelectionEnabled
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.cell?.lineBreakMode = .byTruncatingMiddle
            let isCurrent = state.currentRuntimeSelection?.kind != .localAgent
                && option.selection == state.currentSelection
            button.image = isCurrent
                ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前模型")
                : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选模型")
            button.imagePosition = .imageLeading
            button.contentTintColor = isCurrent
                ? .controlAccentColor
                : .secondaryLabelColor
            button.toolTip = option.toolTip
            button.setAccessibilityIdentifier(option.accessibilityIdentifier)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.cornerCurve = .continuous
            StacioDesignSystem.setLayerBackgroundColor(
                button,
                color: isCurrent
                    ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
            )
            modelsStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        for group in state.groups {
            let heading = makeSectionLabel(group.providerTitle)
            heading.setAccessibilityIdentifier(
                "Stacio.AI.composer.modelPicker.provider.\(group.providerID.uuidString.lowercased())"
            )
            heading.toolTip = group.providerTitle
            modelsStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true

            for selection in group.models {
                let button = AIComposerModelButton(
                    title: selection.modelID,
                    target: self,
                    action: #selector(modelPressed(_:))
                )
                button.selection = selection
                button.isEnabled = state.runtimeSelectionEnabled
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                let isCurrent = state.currentRuntimeSelection?.kind != .localAgent
                    && selection == state.currentSelection
                button.image = isCurrent
                    ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "当前模型")
                    : NSImage(systemSymbolName: "circle", accessibilityDescription: "可选模型")
                button.imagePosition = .imageLeading
                button.contentTintColor = isCurrent
                    ? .controlAccentColor
                    : .secondaryLabelColor
                button.toolTip = "\(group.providerTitle) · \(selection.modelID)"
                button.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.model.\(selection.providerID.uuidString.lowercased()).\(selection.modelID)"
                )
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    button,
                    color: isCurrent
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
        }
        if state.localAgentOptions.isEmpty == false
            || state.legacyLocalAgentOptions.isEmpty == false
            || state.localAgentSettingsActionTitle != nil {
            let heading = makeSectionLabel("本地 Coding Agent")
            heading.setAccessibilityIdentifier("Stacio.AI.composer.modelPicker.localAgents")
            modelsStack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
            for option in state.localAgentOptions {
                let configuration = option.configuration
                let button = AIComposerLocalAgentButton(
                    title: configuration.displayName,
                    target: self,
                    action: #selector(localAgentPressed(_:))
                )
                button.configuration = configuration
                button.isEnabled = state.runtimeSelectionEnabled
                let isCurrent = state.currentRuntimeSelection?.kind == .localAgent
                    && state.currentRuntimeSelection?.localAgentConfigurationID == configuration.configurationID
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                let isStructured = configuration.isReadyForStructuredRuntime
                button.image = NSImage(
                    systemSymbolName: isCurrent
                        ? "checkmark.circle.fill"
                        : (isStructured ? "sparkles" : "terminal"),
                    accessibilityDescription: isCurrent
                        ? "当前 Runtime"
                        : (isStructured ? "结构化本地 Agent Runtime" : "本地终端 Runtime")
                )
                button.imagePosition = .imageLeading
                button.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
                button.toolTip = isStructured
                    ? "\(configuration.displayName) · 结构化会话"
                    : "\(configuration.displayName) · 本地终端透传"
                button.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.localAgent.\(configuration.tool.rawValue)"
                )
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    button,
                    color: isCurrent
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
            for option in state.legacyLocalAgentOptions {
                let tool = option.tool
                let button = AIComposerLocalAgentButton(
                    title: "\(tool.displayName) · 兼容本地 CLI",
                    target: self,
                    action: #selector(legacyLocalAgentPressed(_:))
                )
                button.legacyTool = tool
                button.isEnabled = state.runtimeSelectionEnabled
                let isCurrent = state.currentRuntimeSelection?.kind != .localAgent
                    && state.currentLegacyLocalAgentTool == tool
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.cell?.lineBreakMode = .byTruncatingMiddle
                button.image = NSImage(
                    systemSymbolName: isCurrent ? "checkmark.circle.fill" : "terminal",
                    accessibilityDescription: isCurrent ? "当前兼容 Runtime" : "兼容本地终端 Runtime"
                )
                button.imagePosition = .imageLeading
                button.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
                button.toolTip = "\(tool.displayName) · 兼容本地 CLI，仅使用受管 PTY"
                button.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.legacyLocalAgent.\(tool.rawValue)"
                )
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 8
                button.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    button,
                    color: isCurrent
                        ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                        : NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
            if let title = state.localAgentSettingsActionTitle {
                let settingsButton = NSButton(
                    title: title,
                    target: self,
                    action: #selector(openLocalAgentSettings)
                )
                settingsButton.bezelStyle = .regularSquare
                settingsButton.isBordered = false
                settingsButton.alignment = .left
                settingsButton.font = .systemFont(ofSize: 12, weight: .medium)
                settingsButton.image = NSImage(
                    systemSymbolName: "gearshape",
                    accessibilityDescription: title
                )
                settingsButton.imagePosition = .imageLeading
                settingsButton.contentTintColor = .secondaryLabelColor
                settingsButton.toolTip = "在设置 > AI > 本地 Agent 中检测、登录并启用 CLI"
                settingsButton.setAccessibilityIdentifier(
                    "Stacio.AI.composer.modelPicker.localAgent.settings"
                )
                settingsButton.translatesAutoresizingMaskIntoConstraints = false
                settingsButton.wantsLayer = true
                settingsButton.layer?.cornerRadius = StacioDesignSystem.theme.controlCornerRadius
                settingsButton.layer?.cornerCurve = .continuous
                StacioDesignSystem.setLayerBackgroundColor(
                    settingsButton,
                    color: NSColor.controlBackgroundColor.withAlphaComponent(0.56)
                )
                modelsStack.addArrangedSubview(settingsButton)
                settingsButton.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
                settingsButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
        }
    }

    private func renderReasoning() {
        reasoningControl.segmentCount = state.reasoningItems.count
        for (index, item) in state.reasoningItems.enumerated() {
            reasoningControl.setLabel(item.title, forSegment: index)
            reasoningControl.setWidth(0, forSegment: index)
            reasoningControl.setEnabled(true, forSegment: index)
            reasoningControl.setToolTip("\(item.title)推理强度", forSegment: index)
        }
        reasoningControl.selectedSegment = state.reasoningItems.firstIndex {
            $0.effort == state.currentReasoning
        } ?? -1
        reasoningControl.isEnabled = state.runtimeSelectionEnabled
    }

    private static func preferredSize(for state: AIComposerModelPickerState) -> NSSize {
        let reasoningSectionHeight = showsReasoningSection(for: state)
            ? sectionLabelHeight + reasoningHeight
            : CGFloat(0)
        let height = verticalPadding
            + headerHeight
            + rootSpacingTotal
            + sectionLabelHeight
            + modelListHeight(for: state)
            + reasoningSectionHeight
        return NSSize(width: width, height: min(max(height, minimumHeight), maximumHeight))
    }

    private static func showsReasoningSection(for state: AIComposerModelPickerState) -> Bool {
        state.currentRuntimeSelection?.kind != .localAgent
            && state.currentLegacyLocalAgentTool == nil
            && state.reasoningItems.isEmpty == false
    }

    private static func modelListHeight(for state: AIComposerModelPickerState) -> CGFloat {
        guard state.specialOptions.isEmpty == false
                || state.groups.isEmpty == false
                || state.localAgentOptions.isEmpty == false
                || state.legacyLocalAgentOptions.isEmpty == false
                || state.localAgentSettingsActionTitle != nil else {
            return modelRowHeight
        }
        let modelCount = state.specialOptions.count
            + state.groups.reduce(0) { $0 + $1.models.count }
            + state.localAgentOptions.count
            + state.legacyLocalAgentOptions.count
            + (state.localAgentSettingsActionTitle == nil ? 0 : 1)
        let headingCount = state.groups.count
            + ((state.localAgentOptions.isEmpty
                && state.legacyLocalAgentOptions.isEmpty
                && state.localAgentSettingsActionTitle == nil) ? 0 : 1)
        let rowCount = modelCount + headingCount
        let spacing = CGFloat(max(rowCount - 1, 0)) * modelRowSpacing
        let headingsHeight = CGFloat(headingCount) * sectionLabelHeight
        let modelsHeight = CGFloat(modelCount) * modelRowHeight
        return min(max(headingsHeight + modelsHeight + spacing, modelRowHeight), maximumModelListHeight)
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func contextPercentText(for fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    @objc
    private func modelPressed(_ sender: AIComposerModelButton) {
        onSelectModel?(sender.selection)
    }

    @objc
    private func localAgentPressed(_ sender: AIComposerLocalAgentButton) {
        guard let configuration = sender.configuration else { return }
        onSelectLocalAgent?(configuration)
    }

    @objc
    private func legacyLocalAgentPressed(_ sender: AIComposerLocalAgentButton) {
        guard let tool = sender.legacyTool else { return }
        onSelectLegacyLocalAgent?(tool)
    }

    @objc
    private func openLocalAgentSettings() {
        onOpenLocalAgentSettings?()
    }

    @objc
    private func reasoningChanged(_ sender: NSSegmentedControl) {
        guard state.reasoningItems.indices.contains(sender.selectedSegment) else {
            return
        }
        onSelectReasoning?(state.reasoningItems[sender.selectedSegment].effort)
    }

    var modelTitlesForTesting: [String] {
        update(state: state)
        return state.specialOptions.map(\.title)
            + state.groups.flatMap { $0.models.map(\.modelID) }
            + state.localAgentOptions.map { $0.configuration.displayName }
            + state.legacyLocalAgentOptions.map { "\($0.tool.displayName) · 兼容本地 CLI" }
            + [state.localAgentSettingsActionTitle].compactMap { $0 }
    }

    var groupTitlesForTesting: [String] {
        update(state: state)
        return state.groups.map(\.providerTitle)
    }

    var selectionsForTesting: [AIModelSelection] {
        update(state: state)
        return state.groups.flatMap(\.models)
    }

    var reasoningTitlesForTesting: [String] {
        update(state: state)
        return state.reasoningItems.map(\.title)
    }

    var contextTextForTesting: String {
        loadViewIfNeeded()
        update(state: state)
        return contextPercentLabel.stringValue
    }

    var preferredSizeForTesting: NSSize {
        preferredContentSize
    }

    var showsReasoningForTesting: Bool {
        loadViewIfNeeded()
        update(state: state)
        return reasoningHeader.isHidden == false && reasoningControl.isHidden == false
    }
}

final class AIComposerLocalAgentButton: NSButton {
    var configuration: LocalAgentPassthroughConfiguration?
    var legacyTool: LocalAgentTool?
}

final class AIComposerModelButton: NSButton {
    var selection: AIModelSelection?
}

final class AIContextUsageRingView: NSView {
    var fraction: Double = 0 {
        didSet {
            fraction = min(max(fraction, 0), 1)
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size = min(bounds.width, bounds.height)
        guard size > 4 else { return }
        let rect = NSRect(
            x: bounds.midX - size / 2 + 2,
            y: bounds.midY - size / 2 + 2,
            width: size - 4,
            height: size - 4
        )
        let lineWidth: CGFloat = 3
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        track.stroke()

        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(clamped * 360),
            clockwise: true
        )
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
