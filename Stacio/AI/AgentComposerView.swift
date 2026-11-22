import AppKit
import UniformTypeIdentifiers

@MainActor
final class AgentComposerView: NSView, NSTextViewDelegate {
 private let shell = AgentSurfaceView()
 private let card = NSView()
 private let scopeLabel = NSTextField(labelWithString: "未绑定终端")
 private let chipsRow = NSStackView()
 private let textView = AgentComposerEditor()
 private let scrollView = NSScrollView()
 private let placeholder = AgentComposerPlaceholder(labelWithString: "输入问题…")
 private let atButton = NSButton()
 private let modelButton = NSButton()
 private let permissionButton = NSButton()
 private var permissionHelp = "当前对话权限"
 private let enhanceButton = NSButton()
 private let enhanceSpinner = AgentEnhancementSpinner()
 private var enhancementState: AgentPromptEnhancementState = .idle
 private let sendButton = AgentComposerSendButton()
 private var editorHeightConstraint: NSLayoutConstraint?
 private var chipsHeightConstraint: NSLayoutConstraint?
 private var isRunning = false
 private var isApprovalPending = false
 private var displayedChips: [AgentContextChip] = []
 var onPasteImage: ((Data) -> Void)?
 private var hasContextChips = false

 var onSend: (() -> Void)?
 var onStop: (() -> Void)?
 var onDraftChange: ((String) -> Void)?
 var onRemoveChip: ((String) -> Void)?
 var onPickModel: ((NSView) -> Void)?
 var onEnhance: (() -> Void)?
 var onPickPermission: ((NSView) -> Void)?
 var onPickContext: ((NSView) -> Void)?

 override init(frame frameRect: NSRect) {
 super.init(frame: frameRect)
 translatesAutoresizingMaskIntoConstraints = false
 setUp()
 textView.pasteImage = { [weak self] in self?.onPasteImage?($0) }
 textView.onCompositionChange = { [weak self] in
     self?.refreshInputState()
 }
 }

 required init?(coder: NSCoder) { return nil }

	/// Enter handling that does not depend on the field editor. A text view hosted
	/// in a scroll view inside an inspector sometimes never receives
	/// textView(_:doCommandBy:), so the same action is also driven from a local key
	/// monitor while this composer owns first responder.
	private var keyMonitor: Any?

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if keyMonitor != nil {
			NSEvent.removeMonitor(keyMonitor as Any)
			keyMonitor = nil
		}
		guard window != nil else { return }
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self else { return event }
			guard self.window?.firstResponder === self.textView, !self.textView.hasMarkedText() else { return event }
			if event.window === self.window, self.textView.handleImagePasteShortcut(event) { return nil }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
			guard isReturn, self.shouldSend(with: event.modifierFlags) else { return event }
			self.sendTapped()
			return nil
		}
	}

 private func shouldSend(with flags: NSEvent.ModifierFlags) -> Bool {
 guard !flags.contains(.shift) else { return false }
 let mode = try? AssistantSettingsLiveStore.sharedIfAvailable()?.value(for: "assistant.general.sendKeyMode")
 return mode != .string("commandReturn") || flags.contains(.command)
 }

 private func setUp() {
 shell.translatesAutoresizingMaskIntoConstraints = false
 shell.wantsLayer = true
 shell.surfaceColor = AgentTheme.Color.inputBase
 shell.outlineColor = AgentTheme.Color.border
 shell.layer?.borderWidth = 1
 shell.layer?.cornerRadius = AgentTheme.Metric.composerRadius
 addSubview(shell)

 card.translatesAutoresizingMaskIntoConstraints = false
 shell.addSubview(card)

 scopeLabel.translatesAutoresizingMaskIntoConstraints = false
 scopeLabel.font = AgentTheme.Font.bodySmall
 scopeLabel.textColor = AgentTheme.Color.textSecondary
 scopeLabel.lineBreakMode = .byTruncatingTail
 shell.addSubview(scopeLabel)

 scrollView.translatesAutoresizingMaskIntoConstraints = false
 scrollView.drawsBackground = false
 scrollView.hasVerticalScroller = true
 scrollView.borderType = .noBorder
 scrollView.autohidesScrollers = true
 card.addSubview(scrollView)

 textView.isRichText = false
 textView.drawsBackground = false
 textView.font = AgentTheme.Font.body
 textView.textColor = AgentTheme.Color.text
 textView.insertionPointColor = AgentTheme.Color.text
 textView.textContainerInset = NSSize(width: AgentTheme.Metric.composerEditorPaddingHorizontal, height: AgentTheme.Metric.composerEditorPaddingTop)
 textView.isVerticallyResizable = true
 textView.isHorizontallyResizable = false
 textView.autoresizingMask = [.width]
 textView.textContainer?.widthTracksTextView = true
 textView.delegate = self
 scrollView.documentView = textView

 placeholder.translatesAutoresizingMaskIntoConstraints = false
 placeholder.font = AgentTheme.Font.body
 placeholder.textColor = AgentTheme.Color.textDisabled
 placeholder.setAccessibilityElement(false)
 textView.setAccessibilityLabel(placeholder.stringValue)
 card.addSubview(placeholder)
 placeholder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
 NSLayoutConstraint.activate([
 placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0) + 4),
 placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: textView.textContainerInset.height),
 placeholder.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12)
 ])

 chipsRow.translatesAutoresizingMaskIntoConstraints = false
 chipsRow.orientation = .horizontal
 chipsRow.spacing=4
 chipsRow.alignment = .centerY
 card.addSubview(chipsRow)

 let toolbar = NSStackView()
 toolbar.translatesAutoresizingMaskIntoConstraints = false
 toolbar.orientation = .horizontal
 toolbar.spacing=6
 toolbar.alignment = .centerY
 card.addSubview(toolbar)

 configureIconButton(atButton, symbol: "at", tooltip: "添加上下文", action: #selector(atTapped))
 configureIconButton(enhanceButton, symbol: "sparkles", tooltip: "增强提示词", action: #selector(enhanceTapped))
 sendButton.translatesAutoresizingMaskIntoConstraints = false
 sendButton.isBordered = false
 sendButton.title = ""
 sendButton.target = self
 sendButton.action = #selector(sendTapped)
 sendButton.widthAnchor.constraint(equalToConstant: AgentComposerSendButton.side).isActive = true
 sendButton.heightAnchor.constraint(equalToConstant: AgentComposerSendButton.side).isActive = true
 refreshInputState()

 modelButton.translatesAutoresizingMaskIntoConstraints = false
 modelButton.isBordered = false
 modelButton.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
 modelButton.imagePosition = .imageLeading
 modelButton.contentTintColor = AgentTheme.Color.brand
 modelButton.font = AgentTheme.Font.bodySmall
 modelButton.cell?.lineBreakMode = .byTruncatingTail
 modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

 modelButton.title = "选择模型"
 modelButton.target = self
 modelButton.action = #selector(modelTapped)


 permissionButton.translatesAutoresizingMaskIntoConstraints = false
 permissionButton.isBordered = false
 permissionButton.image = AgentPermissionMode.supervised.permissionIcon()
 permissionButton.imagePosition = .imageLeading
 permissionButton.contentTintColor = AgentTheme.Color.textSecondary
 permissionButton.font = AgentTheme.Font.bodySmall
 permissionButton.title = AgentPermissionMode.supervised.label
 permissionButton.target = self
 permissionButton.action = #selector(permissionTapped)
 permissionButton.setAccessibilityIdentifier("Stacio.Agent.permission")
 toolbar.addArrangedSubview(permissionButton)
 toolbar.addArrangedSubview(modelButton)

 toolbar.insertArrangedSubview(atButton, at:0)
 let spacer = NSView()
 spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
 toolbar.addArrangedSubview(spacer)
 let enhanceControl = NSView()
 enhanceControl.translatesAutoresizingMaskIntoConstraints = false
 enhanceControl.addSubview(enhanceButton)
 enhanceSpinner.translatesAutoresizingMaskIntoConstraints = false
 enhanceSpinner.style = .spinning
 enhanceSpinner.controlSize = .small
 enhanceSpinner.isDisplayedWhenStopped = false
 enhanceSpinner.setAccessibilityElement(false)
 enhanceControl.addSubview(enhanceSpinner)
 NSLayoutConstraint.activate([
 enhanceControl.widthAnchor.constraint(equalToConstant: 22),
 enhanceControl.heightAnchor.constraint(equalToConstant: 22),
 enhanceButton.centerXAnchor.constraint(equalTo: enhanceControl.centerXAnchor),
 enhanceButton.centerYAnchor.constraint(equalTo: enhanceControl.centerYAnchor),
 enhanceSpinner.centerXAnchor.constraint(equalTo: enhanceControl.centerXAnchor),
 enhanceSpinner.centerYAnchor.constraint(equalTo: enhanceControl.centerYAnchor),
 enhanceSpinner.widthAnchor.constraint(equalToConstant: 16),
 enhanceSpinner.heightAnchor.constraint(equalToConstant: 16)
 ])
 toolbar.addArrangedSubview(enhanceControl)
 toolbar.addArrangedSubview(sendButton)

 editorHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: AgentTheme.Metric.composerEditorMinHeight)
 chipsHeightConstraint = chipsRow.heightAnchor.constraint(equalToConstant:0)

 NSLayoutConstraint.activate([
 shell.topAnchor.constraint(equalTo: topAnchor),
 shell.leadingAnchor.constraint(equalTo: leadingAnchor),
 shell.trailingAnchor.constraint(equalTo: trailingAnchor),
 shell.bottomAnchor.constraint(equalTo: bottomAnchor),
 scopeLabel.topAnchor.constraint(equalTo: shell.topAnchor, constant:10),
 scopeLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant:14),
 scopeLabel.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -14),
 card.topAnchor.constraint(equalTo: scopeLabel.bottomAnchor, constant:6),
 card.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: AgentTheme.Metric.composerOuterPadding),
 card.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -AgentTheme.Metric.composerOuterPadding),
 card.bottomAnchor.constraint(equalTo: shell.bottomAnchor, constant: -AgentTheme.Metric.composerOuterPadding),
 scrollView.topAnchor.constraint(equalTo: chipsRow.bottomAnchor),
 scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
 scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
 editorHeightConstraint!,
 chipsRow.topAnchor.constraint(equalTo: card.topAnchor),
 chipsRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: AgentTheme.Metric.composerEditorPaddingHorizontal),
 chipsRow.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
 chipsHeightConstraint!,
 toolbar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant:6),
 toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: AgentTheme.Metric.composerFooterHorizontalPadding),
 toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -AgentTheme.Metric.composerFooterHorizontalPadding),
 toolbar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -AgentTheme.Metric.composerFooterBottomPadding),
 toolbar.heightAnchor.constraint(equalToConstant: AgentComposerSendButton.side)
 ])
 }

 private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
 button.translatesAutoresizingMaskIntoConstraints = false
 button.isBordered = false
 button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
 button.imagePosition = .imageOnly
 button.contentTintColor = AgentTheme.Color.textSecondary
 button.toolTip = tooltip
 button.target = self
 button.action = action
 button.widthAnchor.constraint(equalToConstant:22).isActive = true
 button.heightAnchor.constraint(equalToConstant:22).isActive = true
 }


 func apply(text: String, chips: [AgentContextChip]) {
 hasContextChips = !chips.isEmpty
 if !textView.hasMarkedText(), textView.string != text {
 textView.string = text
 let end = NSRange(location: text.utf16.count, length: 0)
 textView.setSelectedRange(end)
 textView.scrollRangeToVisible(end)
 }
 refreshInputState()
 resizeEditor()
 guard chips != displayedChips else { return }
 displayedChips = chips
 for view in chipsRow.arrangedSubviews {
 chipsRow.removeArrangedSubview(view)
 view.removeFromSuperview()
 }
 for chip in chips {
 if chip.imageNumber != nil {
 let tile = AgentImageTile(chip)
 let remove = NSButton(title: "×", target: self, action: #selector(removeChip(_:)))
 remove.identifier = NSUserInterfaceItemIdentifier(chip.id)
 remove.toolTip = "移除" + chip.label
 remove.bezelStyle = .inline
 let caption = NSStackView(views: [NSTextField(labelWithString: chip.label), remove])
 let column = NSStackView(views: [tile, caption])
 column.orientation = .vertical
 column.spacing = 0
 chipsRow.addArrangedSubview(column)
 } else { chipsRow.addArrangedSubview(makeChipView(chip)) }
 }
 chipsHeightConstraint?.constant = chips.contains { $0.imageNumber != nil } ? 84 : (chips.isEmpty ? 0 : 22)
 resizeEditor()
 }

 func applyTerminalTitle(_ title: String?) {
 scopeLabel.stringValue = title.map { "终端 · \($0)" } ?? "未绑定终端"
 scopeLabel.toolTip = title
 scopeLabel.textColor = AgentTheme.Color.textSecondary
 }

 func apply(model: AgentModelSelection?, permission: AgentPermissionMode, preferences: AppSettings = AppSettings()) {
 if let model {
 modelButton.image = model.pickerIcon()
 modelButton.title = model.menuLabel + " · " + model.effortLabel
 modelButton.toolTip = modelButton.title
 } else {
 modelButton.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
 modelButton.title = "选择模型"
 modelButton.toolTip = "选择模型"
 }
 permissionButton.title = permission.label
 permissionButton.image = permission.permissionIcon()
 permissionHelp = "当前对话权限：\(permission.label)\n\(permission.shortDescription)\n\(AgentPermissionPolicy.globalConstraintDescription(preferences: preferences))"
 permissionButton.toolTip = permissionHelp
 if permission.isDangerous {
 permissionButton.contentTintColor = .systemRed
 } else {
 permissionButton.contentTintColor = AgentTheme.Color.textSecondary
 }
 }

 func applyRunning(_ running: Bool) {
 isRunning = running
 permissionButton.isEnabled = !running
 permissionButton.toolTip = running ? "\(permissionHelp)\n当前任务结束后可更改权限" : permissionHelp
 refreshInputState()
 }

 func applyApprovalPending(_ pending: Bool) {
 isApprovalPending = pending
 refreshInputState()
 }

 private func refreshInputState() {
 let composing = textView.hasMarkedText()
 placeholder.isHidden = composing || !textView.string.isEmpty
 let hasMessage = hasContextChips || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
 sendButton.showsStop = isRunning
 sendButton.isEnabled = isRunning || (!isApprovalPending && !composing && hasMessage)
 sendButton.toolTip = isRunning ? "停止生成" : "发送（Enter）"
 sendButton.setAccessibilityLabel(isRunning ? "停止生成" : "发送")
 refreshEnhanceButton()
 }

	/// The editable text view, exposed so the hosting controller can make it first
	/// responder once the panel is actually in a window.
	var textInput: NSTextView { textView }
 var isPlaceholderVisibleForTesting: Bool { !placeholder.isHidden }

	/// Test hooks: drive the composer the same way the text view does, without
	/// depending on a live field editor.
	func setTextForTesting(_ text: String) {
		textView.string = text
		refreshInputState()
		onDraftChange?(text)
	}

	var sendButtonFrameForTesting: NSRect { sendButton.convert(sendButton.bounds, to: nil) }
	func sendForTesting() {
		sendButton.performClick(nil)
	}


	/// Clicking anywhere in the composer must move focus into the text view.
	/// The terminal keeps first responder otherwise, so typed text went to the
	/// shell instead of the assistant.
	override func mouseDown(with event: NSEvent) {
		focusInput()
		super.mouseDown(with: event)
	}
	func focusInput() {
		guard let window else { return }
		let target = textView
		if window.makeFirstResponder(target), window.firstResponder === target { return }
		// A text view hosted in a scroll view sometimes refuses the first attempt
		// because the scroll view itself is not yet in the responder chain. Walk the
		// chain in order, then retry.
		window.makeFirstResponder(scrollView)
		window.makeFirstResponder(self)
		window.makeFirstResponder(target)
	}

 func mentionImage(_ label: String) { textView.insertText("@" + label + " ", replacementRange: textView.selectedRange()); window?.makeFirstResponder(textView) }

 private func makeChipView(_ chip: AgentContextChip) -> NSView {
 let container = NSView()
 container.translatesAutoresizingMaskIntoConstraints = false
 container.wantsLayer = true
 container.layer?.backgroundColor = AgentTheme.Color.hoverMedium.cgColor
 container.layer?.cornerRadius = AgentTheme.Metric.radiusMedium
 container.heightAnchor.constraint(equalToConstant:20).isActive = true

 let accent = AgentTheme.Color.chipAccent(for: chip.kind)
 let icon = NSImageView()
 icon.translatesAutoresizingMaskIntoConstraints = false
 icon.image = NSImage(systemSymbolName: symbol(for: chip.kind), accessibilityDescription: nil)
 icon.contentTintColor = accent.foreground
 icon.widthAnchor.constraint(equalToConstant:11).isActive = true
 icon.heightAnchor.constraint(equalToConstant:11).isActive = true
 container.addSubview(icon)

 let label = NSTextField(labelWithString: chip.label)
 label.translatesAutoresizingMaskIntoConstraints = false
 label.font = AgentTheme.Font.caption
 label.textColor = AgentTheme.Color.text
 label.lineBreakMode = .byTruncatingTail
 container.addSubview(label)

 let remove = NSButton()
 remove.translatesAutoresizingMaskIntoConstraints = false
 remove.isBordered = false
 remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除上下文")
 remove.imagePosition = .imageOnly
 remove.contentTintColor = AgentTheme.Color.textTertiary
 remove.target = self
 remove.action = #selector(removeChip(_:))
 remove.identifier = NSUserInterfaceItemIdentifier(chip.id)
 remove.widthAnchor.constraint(equalToConstant:12).isActive = true
 container.addSubview(remove)

 NSLayoutConstraint.activate([
 icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant:4),
 icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
 label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant:4),
 label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
 label.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -4),
 remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
 remove.centerYAnchor.constraint(equalTo: container.centerYAnchor)
 ])
 return container
 }

 private func symbol(for kind: AgentContextKind) -> String {
 switch kind {
 case .terminal: return "terminal"
 case .connection: return "server.rack"
 case .file: return "doc"
 case .folder: return "folder"
 case .selection: return "text.cursor"
 }
 }

 @objc private func removeChip(_ sender: NSButton) {
 guard let id = sender.identifier?.rawValue else { return }
 onRemoveChip?(id)
 }

 private func resizeEditor() {
 let layout = textView.layoutManager
 if let container = textView.textContainer {
 layout?.ensureLayout(for: container)
 }
 var used: CGFloat=0
 if let container = textView.textContainer {
 if let rect = layout?.usedRect(for: container) {
 used = rect.height
 }
 }
 let padding = AgentTheme.Metric.composerEditorPaddingTop*2
 let minHeight = AgentTheme.Metric.composerEditorMinHeight
 var available: CGFloat=600
 if let window = window {
 available = window.contentView?.bounds.height ?? 600
 }
 let cap = max(minHeight, available * AgentTheme.Metric.composerMaxHeightRatio)
 let maxHeight = min(AgentTheme.Metric.composerMaxHeightCap, cap)
 let target = min(maxHeight, max(minHeight, used + padding))
 editorHeightConstraint?.constant = target
 }

 @objc private func sendTapped() {
 guard sendButton.isEnabled else { return }
 if isRunning {
 onStop?()
 } else if !textView.hasMarkedText() {
 onSend?()
 }
 }

 @objc private func atTapped() { onPickContext?(atButton) }
 @objc private func modelTapped() { onPickModel?(modelButton) }
 @objc private func permissionTapped() { onPickPermission?(permissionButton) }
 @objc private func enhanceTapped() {
 guard enhanceButton.isEnabled, !textView.hasMarkedText() else { return }
 focusInput()
 onEnhance?()
 }

 func applyEnhancement(_ state: AgentPromptEnhancementState) {
 enhancementState = state
 if case .failed(let message) = state {
 scopeLabel.stringValue = message
 scopeLabel.toolTip = message
 scopeLabel.textColor = AgentTheme.Color.danger
 }
 refreshEnhanceButton()
 }

 private func refreshEnhanceButton() {
 let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
 let loading = enhancementState == .loading
 let undo = enhancementState == .undo
 let enabled = !textView.hasMarkedText() && (hasText || loading || undo)
 let label = loading ? "取消增强" : undo ? "撤回增强" : "增强提示词"
 enhanceButton.isEnabled = enabled
 enhanceButton.setAccessibilityLabel(label)
 enhanceButton.toolTip = loading ? "正在增强提示词，点击取消" : label
 enhanceButton.image = loading ? nil : NSImage(systemSymbolName: undo ? "arrow.uturn.backward" : "sparkles", accessibilityDescription: nil)
 enhanceButton.contentTintColor = enabled ? AgentTheme.Color.brand : AgentTheme.Color.textTertiary
 if loading { enhanceSpinner.startAnimation(nil) } else { enhanceSpinner.stopAnimation(nil) }
 }

 func textDidChange(_ notification: Notification) {
 refreshInputState()
 guard !textView.hasMarkedText() else { return }
 resizeEditor()
 onDraftChange?(textView.string)
 }

 func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
 guard !textView.hasMarkedText() else { return false }
 if selector == #selector(NSResponder.insertNewline(_:)) {
 if shouldSend(with: NSEvent.modifierFlags) {
 sendTapped()
 return true
 }
 }
 if selector == #selector(NSResponder.cancelOperation(_:)) {
 textView.string = ""
 refreshInputState()
 resizeEditor()
 onDraftChange?("")
 return true
 }
 return false
 }
}

@MainActor
private final class AgentComposerSendButton: NSButton {
 static let side: CGFloat = 32
 var showsStop = false { didSet { needsDisplay = true } }
 override var isEnabled: Bool { didSet { needsDisplay = true } }
 override var isHighlighted: Bool { didSet { needsDisplay = true } }

 override func draw(_ dirtyRect: NSRect) {
 let fill: NSColor
 if showsStop {
 fill = .systemRed
 } else if isEnabled {
 fill = NSColor(srgbRed: 0.23, green: 0.43, blue: 0.85, alpha: 1)
 } else {
 fill = NSColor(srgbRed: 0.68, green: 0.77, blue: 0.94, alpha: 1)
 }
 (isHighlighted ? fill.blended(withFraction: 0.14, of: .black) ?? fill : fill).setFill()
 NSBezierPath(ovalIn: bounds).fill()
 NSColor.white.set()
 let center = NSPoint(x: bounds.midX, y: bounds.midY)
 if showsStop {
 NSBezierPath(roundedRect: NSRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9),
              xRadius: 1.5, yRadius: 1.5).fill()
 } else {
 let direction: CGFloat = isFlipped ? -1 : 1
 let arrow = NSBezierPath()
 arrow.lineWidth = 1.9
 arrow.lineCapStyle = .round
 arrow.lineJoinStyle = .round
 arrow.move(to: NSPoint(x: center.x, y: center.y - 5.5 * direction))
 arrow.line(to: NSPoint(x: center.x, y: center.y + 5.5 * direction))
 arrow.move(to: NSPoint(x: center.x - 4.8, y: center.y + 0.7 * direction))
 arrow.line(to: NSPoint(x: center.x, y: center.y + 5.5 * direction))
 arrow.line(to: NSPoint(x: center.x + 4.8, y: center.y + 0.7 * direction))
 arrow.stroke()
 }
 }
}

@MainActor
final class AgentComposerEditor: NSTextView {
 var pasteImage: ((Data) -> Void)?
 override func paste(_ sender: Any?) {
 if pasteImages(from: .general) { return }
 super.paste(sender)
 }
 func handleImagePasteShortcut(_ event: NSEvent, board: NSPasteboard = .general) -> Bool {
 let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
 guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
 return pasteImages(from: board)
 }
 private func pasteImages(from board: NSPasteboard) -> Bool {
 guard let pasteImage else { return false }
 let items = board.pasteboardItems ?? []
 let images = items.compactMap { item -> Data? in
 if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL,
 let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .image) {
 return try? Data(contentsOf: url, options: .mappedIfSafe)
 }
 for type in [.png, .tiff] as [NSPasteboard.PasteboardType] {
 if let data = item.data(forType: type) { return data }
 }
 return nil
 }
 for data in images { pasteImage(data) }
 return !images.isEmpty
 }
 var onCompositionChange: (() -> Void)?

 override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
     super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
     onCompositionChange?()
 }

 override func unmarkText() {
     super.unmarkText()
     onCompositionChange?()
 }
}

private final class AgentComposerPlaceholder: NSTextField {
 override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class AgentEnhancementSpinner: NSProgressIndicator {
 override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
