import AppKit

@MainActor
class AgentRowView: AgentSurfaceView {
 override var isFlipped: Bool { return true }

 override init(frame frameRect: NSRect) {
 super.init(frame: frameRect)
 translatesAutoresizingMaskIntoConstraints = false
 setContentHuggingPriority(.defaultLow, for: .horizontal)
 }

 required init?(coder: NSCoder) { return nil }

 func update(item: AgentItem, width: CGFloat) {}

 var copyableText: String { return "" }
}

/// Right-aligned user bubble:8pt radius with the top-right corner squared off.
@MainActor
final class AgentUserMessageView: AgentRowView {
 private let bubble = AgentSurfaceView()
 private let label = NSTextField(wrappingLabelWithString: "")
 private let copyButton = NSButton()
 private var text = ""
 private let pictures = NSStackView()
 private var displayedImages: [AgentContextChip] = []
 private var bubbleWidth: NSLayoutConstraint?
 private var labelHeight: NSLayoutConstraint?
 private var measuredRowWidth: CGFloat = 0
 var onCopy: ((String) -> Void)?

 init(onCopy: ((String) -> Void)?) {
 self.onCopy = onCopy
 super.init(frame: .zero)
 setUp()
 }

 required init?(coder: NSCoder) { return nil }

 private func setUp() {
 bubble.translatesAutoresizingMaskIntoConstraints = false
 bubble.wantsLayer = true
 bubble.surfaceColor = AgentTheme.Color.userBubble
 bubble.layer?.cornerRadius = AgentTheme.Metric.radiusLarge
 bubble.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
 addSubview(bubble)

 label.translatesAutoresizingMaskIntoConstraints = false
 label.font = AgentTheme.Font.body
 label.textColor = AgentTheme.Color.text
 label.maximumNumberOfLines=0
 label.lineBreakMode = .byWordWrapping
 pictures.translatesAutoresizingMaskIntoConstraints = false
 pictures.spacing = 4
 bubble.addSubview(pictures)
 bubble.addSubview(label)

 copyButton.translatesAutoresizingMaskIntoConstraints = false
 copyButton.isBordered = false
 copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
 copyButton.imagePosition = .imageOnly
 copyButton.contentTintColor = AgentTheme.Color.textTertiary
 copyButton.target = self
 copyButton.action = #selector(copyTapped)
 copyButton.isHidden = true
 addSubview(copyButton)

 let preferredWidth = bubble.widthAnchor.constraint(equalToConstant: 40)
 preferredWidth.priority = .defaultHigh
 preferredWidth.isActive = true
 bubbleWidth = preferredWidth
 let textHeight = label.heightAnchor.constraint(equalToConstant: 18)
 textHeight.isActive = true
 labelHeight = textHeight

 NSLayoutConstraint.activate([
 bubble.topAnchor.constraint(equalTo: topAnchor),
 bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
 bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
 bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier:0.86),
 bubble.widthAnchor.constraint(greaterThanOrEqualToConstant:40),
 pictures.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
 pictures.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
 label.topAnchor.constraint(equalTo: pictures.bottomAnchor),
 label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant:12),
 label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
 label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
 copyButton.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
 copyButton.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -22),
 copyButton.widthAnchor.constraint(equalToConstant:16),
 copyButton.heightAnchor.constraint(equalToConstant:16)
 ])
 }


 override func update(item: AgentItem, width: CGFloat) {
     let images = item.images ?? []
     let changed = text != item.text || displayedImages != images
     if displayedImages != images {
         displayedImages = images
         for tile in pictures.arrangedSubviews { tile.removeFromSuperview() }
         for image in images { pictures.addArrangedSubview(AgentImageTile(image)) }
     }
     if changed {
         text = item.text
         label.stringValue = text
     }
     sizeBubble(rowWidth: bounds.width > 40 ? bounds.width : width - 2 * AgentTheme.Metric.contentPaddingHorizontal,
                force: changed)
 }

 override func layout() {
     super.layout()
     sizeBubble(rowWidth: bounds.width)
 }

 private func sizeBubble(rowWidth: CGFloat, force: Bool = false) {
     guard rowWidth >= 48, force || abs(rowWidth - measuredRowWidth) > 0.5 else { return }
     measuredRowWidth = rowWidth
     let maxWidth = floor(rowWidth * 0.86)
     let font = label.font ?? AgentTheme.Font.body
     let naturalWidth = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
         .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
         .max() ?? 0
     let width = min(maxWidth, max(40, CGFloat(displayedImages.count * 70 + 24), ceil(naturalWidth) + 28))
     bubbleWidth?.constant = width
     let textWidth = width - 24
     label.preferredMaxLayoutWidth = textWidth
     let measuredHeight = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1_000_000)).height ?? 0
     labelHeight?.constant = max(ceil(font.ascender - font.descender + font.leading), ceil(measuredHeight))
 }

 override var copyableText: String { return text }

 override func updateTrackingAreas() {
 super.updateTrackingAreas()
 guard !trackingAreas.contains(where: { $0.owner === self }) else { return }
 let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
 addTrackingArea(area)
 }

 override func mouseEntered(with event: NSEvent) {
 copyButton.isHidden = false
 }

 override func mouseExited(with event: NSEvent) {
 copyButton.isHidden = true
 }

 @objc private func copyTapped() {
 if text.isEmpty { return }
 NSPasteboard.general.clearContents()
 NSPasteboard.general.setString(text, forType: .string)
 onCopy?(text)
 }
}

/// Left-aligned markdown answer with the reasoning block and a compact action bar.
@MainActor
final class AgentAssistantMessageView: AgentRowView {
 private let reasoningButton = NSButton()
 private let reasoningText = NSTextView()
 private let reasoningScroll = NSScrollView()
 private let body = NSTextView()
 private var bodyHeight: NSLayoutConstraint?
 private let completionLabel = NSTextField(labelWithString: "任务已完成")
 private let actions = NSStackView()
 private let abortedLabel = NSTextField(labelWithString: "已停止生成")
 private var currentItem: AgentItem?
 private var text = ""
 private var manualReasoningExpansion: Bool?
 private var turnIsActive = false
 private lazy var reasoningHeight = reasoningScroll.heightAnchor.constraint(equalToConstant: 24)
 private var reasoningExpanded = false

 func setReasoningTurnActive(_ active: Bool) {
 if turnIsActive && !active { manualReasoningExpansion = nil }
 turnIsActive = active
 }

 private func displayReasoning(_ value: String, width: CGFloat) {
 let available = max(32, width - 2 * AgentTheme.Metric.contentPaddingHorizontal - 26)
 if reasoningText.string != value { reasoningText.string = value }
 let measured = (value as NSString).boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: AgentTheme.Font.bodySmall])
 reasoningHeight.constant = min(AgentTheme.Metric.thinkingMaxHeight, max(24, ceil(measured.height) + 10))
 }
 private var lastWidth: CGFloat=0

 var onCopy: ((String) -> Void)?

 init(onCopy: ((String) -> Void)?) {
 self.onCopy = onCopy
 super.init(frame: .zero)
 setUp()
 }

 required init?(coder: NSCoder) { return nil }

 private func setUp() {
 let column = NSStackView()
 column.translatesAutoresizingMaskIntoConstraints = false
 column.orientation = .vertical
 column.alignment = .leading
 column.spacing=6
 addSubview(column)

 reasoningButton.translatesAutoresizingMaskIntoConstraints = false
 reasoningButton.isBordered = false
 reasoningButton.font = AgentTheme.Font.caption
 reasoningButton.contentTintColor = AgentTheme.Color.textMuted
 reasoningButton.title = "深度思考"
 reasoningButton.alignment = .left
 reasoningButton.target = self
 reasoningButton.action = #selector(toggleReasoning)
 reasoningButton.isHidden = true
 column.addArrangedSubview(reasoningButton)

 reasoningScroll.translatesAutoresizingMaskIntoConstraints = false
 reasoningScroll.hasVerticalScroller = true
 reasoningScroll.drawsBackground = false
 reasoningScroll.borderType = .noBorder
 reasoningScroll.isHidden = true
 reasoningText.autoresizingMask = [.width]
 reasoningText.isVerticallyResizable = true
 reasoningText.textContainer?.widthTracksTextView = true
 reasoningText.isEditable = false
 reasoningText.drawsBackground = false
 reasoningText.textContainerInset = NSSize(width:8, height:4)
 reasoningText.font = AgentTheme.Font.bodySmall
 reasoningText.textColor = AgentTheme.Color.textSecondary
 reasoningScroll.documentView = reasoningText
 column.addArrangedSubview(reasoningScroll)

 body.translatesAutoresizingMaskIntoConstraints = false
 body.isEditable = false
 body.isSelectable = true
 body.drawsBackground = false
 body.textContainerInset = .zero
 body.textContainer?.lineFragmentPadding = 0
 body.isVerticallyResizable = true
 body.isHorizontallyResizable = false
 body.autoresizingMask = [.width]
 body.textContainer?.widthTracksTextView = true
 column.addArrangedSubview(body)

 abortedLabel.translatesAutoresizingMaskIntoConstraints = false
 abortedLabel.font = AgentTheme.Font.caption
 abortedLabel.textColor = AgentTheme.Color.textTertiary
 abortedLabel.isHidden = true
 column.addArrangedSubview(abortedLabel)

 completionLabel.translatesAutoresizingMaskIntoConstraints = false
 completionLabel.font = AgentTheme.Font.caption
 completionLabel.textColor = AgentTheme.Color.textTertiary
 completionLabel.stringValue = "任务已完成"
 completionLabel.isHidden = true
 column.addArrangedSubview(completionLabel)
 actions.translatesAutoresizingMaskIntoConstraints = false
 actions.orientation = .horizontal
 actions.spacing=8
 actions.addArrangedSubview(makeActionButton(symbol: "doc.on.doc", tooltip: "复制", action: #selector(copyTapped)))
 actions.addArrangedSubview(makeActionButton(symbol: "hand.thumbsup", tooltip: "有帮助", action: #selector(rateAnswer(_:))))
 actions.addArrangedSubview(makeActionButton(symbol: "hand.thumbsdown", tooltip: "没帮助", action: #selector(rateAnswer(_:))))
 actions.addArrangedSubview(makeActionButton(symbol: "ellipsis", tooltip: "更多", action: #selector(moreActions(_:))))
 actions.isHidden = true
 column.addArrangedSubview(actions)

 NSLayoutConstraint.activate([
 column.topAnchor.constraint(equalTo: topAnchor),
 column.leadingAnchor.constraint(equalTo: leadingAnchor),
 column.trailingAnchor.constraint(equalTo: trailingAnchor),
 column.bottomAnchor.constraint(equalTo: bottomAnchor),
 reasoningScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
 reasoningHeight,
 body.widthAnchor.constraint(equalTo: column.widthAnchor)
 ])
 }

 private func makeActionButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
 let button = NSButton()
 button.translatesAutoresizingMaskIntoConstraints = false
 button.isBordered = false
 button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
 button.imagePosition = .imageOnly
 button.contentTintColor = AgentTheme.Color.textTertiary
 button.toolTip = tooltip
 button.target = self
 button.action = action
 button.widthAnchor.constraint(equalToConstant:18).isActive = true
 button.heightAnchor.constraint(equalToConstant:18).isActive = true
 return button
 }

 private var measuredBodyWidth: CGFloat = 0
 override func layout() {
 super.layout()
 let width = body.bounds.width
 if width > 0, abs(width - measuredBodyWidth) > 0.5 { resizeBody(width: width) }
 }

 /// Gives the text view the height its laid-out text needs.
 private func resizeBody(width: CGFloat) {
 guard let textContainer = body.textContainer, let layout = body.layoutManager else { return }
 measuredBodyWidth = width
 let usable = max(1, width)
 textContainer.containerSize = NSSize(width: usable, height: .greatestFiniteMagnitude)
 layout.ensureLayout(for: textContainer)
 let height = ceil(layout.usedRect(for: textContainer).height)
 if let bodyHeight { bodyHeight.constant = max(1, height); return }
 let constraint = body.heightAnchor.constraint(equalToConstant: max(1, height))
 constraint.isActive = true
 bodyHeight = constraint
 }

 override func update(item: AgentItem, width: CGFloat) {
 let previous = currentItem
 currentItem = item
 if previous?.id != item.id { refreshRating(item.id) }
 text = item.text

 if previous?.id != item.id { manualReasoningExpansion = nil }
 if item.reasoning.isEmpty == false {
 reasoningExpanded = manualReasoningExpansion ?? (turnIsActive || item.isStreaming)
 reasoningButton.title = reasoningExpanded ? "▾ 推理说明（模型返回）" : "▸ 推理说明（模型返回）"
 reasoningButton.isEnabled = true
 reasoningButton.isHidden = false
 reasoningScroll.isHidden = reasoningExpanded == false
 if reasoningExpanded, reasoningScroll.isHidden == false, previous?.reasoning != item.reasoning || lastWidth != width || reasoningText.string != item.reasoning {
 displayReasoning(item.reasoning, width: width)
 }
 } else {
 reasoningButton.isHidden = item.thinkingRequested != true
 reasoningButton.isEnabled = false
 reasoningButton.title = item.isStreaming && item.text.isEmpty ? "已请求模型思考，等待响应…" : "本次响应未返回思考文本"
 reasoningScroll.isHidden = true
 }

 if previous?.text != item.text || lastWidth != width || previous?.isStreaming != item.isStreaming {
 if item.isStreaming, let storage = body.textStorage {
 let offset = previous?.isStreaming == true && previous?.id == item.id ? storage.length : 0
 let source = item.text as NSString
 let start = offset <= source.length ? offset : 0
 if start == 0 { storage.mutableString.setString("") }
 storage.append(NSAttributedString(string: source.substring(from: start), attributes: [.font: AgentTheme.Font.body, .foregroundColor: AgentTheme.Color.text]))
 } else {
 body.textStorage?.setAttributedString(AgentMarkdownRenderer.render(item.text, width: width))
 }
 resizeBody(width: body.bounds.width > 0 ? body.bounds.width : width - 2 * AgentTheme.Metric.contentPaddingHorizontal)
 }
 abortedLabel.isHidden = item.aborted == false
 completionLabel.isHidden = true
 lastWidth = width
 }

 func showCompletion(_ visible: Bool) {
 actions.isHidden = !visible
 completionLabel.isHidden = visible == false
 }

 override var copyableText: String { return text }

 @objc private func toggleReasoning() {
 reasoningExpanded.toggle()
 if reasoningExpanded, let item = currentItem { displayReasoning(item.reasoning, width: lastWidth) }
 manualReasoningExpansion = reasoningExpanded
 reasoningButton.title = reasoningExpanded ? "▾ 推理说明（模型返回）" : "▸ 推理说明（模型返回）"
 reasoningScroll.isHidden = reasoningExpanded == false
 }

 @objc private func copyTapped() {
 if text.isEmpty { return }
 NSPasteboard.general.clearContents()
 NSPasteboard.general.setString(text, forType: .string)
 onCopy?(text)
 }

 @objc private func rateAnswer(_ sender: NSButton) {
 guard let id = currentItem?.id, let value = sender.toolTip else { return }
 let key = "Stacio.Agent.rating." + id
 let defaults = UserDefaults.standard
 defaults.set(defaults.string(forKey: key) == value ? nil : value, forKey: key)
 refreshRating(id)
 }
 private func refreshRating(_ id: String) {
 let rating = UserDefaults.standard.string(forKey: "Stacio.Agent.rating." + id)
 for case let button as NSButton in actions.arrangedSubviews where ["有帮助", "没帮助"].contains(button.toolTip ?? "") {
 button.contentTintColor = button.toolTip == rating ? AgentTheme.Color.brand : AgentTheme.Color.textTertiary
 }
 }
 @objc private func moreActions(_ sender: NSButton) {
 let menu = NSMenu()
 let save = menu.addItem(withTitle: "保存回答为 Markdown…", action: #selector(saveAnswer), keyEquivalent: "")
 save.target = self
 menu.popUp(positioning: nil, at: .zero, in: sender)
 }
 @objc private func saveAnswer() {
 guard let window else { return }
 let panel = NSSavePanel()
 panel.nameFieldStringValue = "回答.md"
 let answer = text
 panel.beginSheetModal(for: window) { response in
 guard response == .OK, let url = panel.url else { return }
 do { try answer.write(to: url, atomically: true, encoding: .utf8) } catch { NSApp.presentError(error) }
 }
 }
}

/// Compact tool activity: one summary line that expands into command and output.
@MainActor
final class AgentToolCardView: AgentRowView {
 private var userExpanded: Bool?
 private let summaryLabel = NSTextField(labelWithString: "")
 private let toolIcon = NSImageView()
 private let terminalLabel = NSTextField(labelWithString: "")
 private let statusLabel = NSTextField(labelWithString: "")
 private let detailContainer = AgentSurfaceView()
 private let commandLabel = NSTextField(wrappingLabelWithString: "")
 private let outputScroll = NSScrollView()
 private let outputText = NSTextView()
 private let expandButton = NSButton()
 private var expanded = true

 private var currentTool: AgentToolInvocation?

 init() {
 super.init(frame: .zero)
 setUp()
 }

 required init?(coder: NSCoder) { return nil }

 private func setUp() {
 let row = NSStackView()
 row.translatesAutoresizingMaskIntoConstraints = false
 row.orientation = .vertical
 row.alignment = .leading
 row.spacing=0
 addSubview(row)

 let header = NSStackView()
 header.translatesAutoresizingMaskIntoConstraints = false
 header.orientation = .horizontal
 header.alignment = .centerY
 header.spacing=8
 row.addArrangedSubview(header)
 header.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

 let icon = toolIcon
 icon.translatesAutoresizingMaskIntoConstraints = false
 icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
 icon.contentTintColor = AgentTheme.Color.textMuted
 icon.widthAnchor.constraint(equalToConstant:14).isActive = true
 icon.heightAnchor.constraint(equalToConstant:14).isActive = true
 header.addArrangedSubview(icon)

 summaryLabel.translatesAutoresizingMaskIntoConstraints = false
 summaryLabel.font = AgentTheme.Font.monoSummary
 summaryLabel.textColor = AgentTheme.Color.textMuted
 summaryLabel.lineBreakMode = .byTruncatingTail
 summaryLabel.maximumNumberOfLines=1
 summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
 header.addArrangedSubview(summaryLabel)

 terminalLabel.font = AgentTheme.Font.caption
 terminalLabel.textColor = AgentTheme.Color.textSecondary
 terminalLabel.lineBreakMode = .byTruncatingTail
 terminalLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100).isActive = true
 header.addArrangedSubview(terminalLabel)

 statusLabel.translatesAutoresizingMaskIntoConstraints = false
 statusLabel.font = AgentTheme.Font.caption
 statusLabel.setContentHuggingPriority(.required, for: .horizontal)
 header.addArrangedSubview(statusLabel)

 expandButton.translatesAutoresizingMaskIntoConstraints = false
 expandButton.isBordered = false
 expandButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "展开")
 expandButton.imagePosition = .imageOnly
 expandButton.contentTintColor = AgentTheme.Color.textTertiary
 expandButton.target = self
 expandButton.action = #selector(toggleExpanded)
 expandButton.widthAnchor.constraint(equalToConstant:14).isActive = true
 expandButton.heightAnchor.constraint(equalToConstant:14).isActive = true
 header.addArrangedSubview(expandButton)
 header.heightAnchor.constraint(equalToConstant: AgentTheme.Metric.toolCardSummaryHeight).isActive = true

 detailContainer.translatesAutoresizingMaskIntoConstraints = false
 detailContainer.wantsLayer = true
 detailContainer.surfaceColor = AgentTheme.Color.cardOuter
 detailContainer.layer?.cornerRadius = AgentTheme.Metric.radiusLarge
 detailContainer.layer?.borderWidth=1
 detailContainer.outlineColor = AgentTheme.Color.borderCard
 detailContainer.isHidden = false
 row.addArrangedSubview(detailContainer)

 commandLabel.translatesAutoresizingMaskIntoConstraints = false
 commandLabel.font = AgentTheme.Font.mono
 commandLabel.textColor = AgentTheme.Color.text
 commandLabel.maximumNumberOfLines = 1
 commandLabel.lineBreakMode = .byTruncatingTail
 commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
 let toolbar = NSStackView(views: [commandLabel])
 toolbar.translatesAutoresizingMaskIntoConstraints = false
 detailContainer.addSubview(toolbar)
 for (symbol, title, action) in [("doc.on.doc", "复制终端记录", #selector(copyRecord)), ("square.and.arrow.down", "保存终端记录", #selector(saveRecord))] {
 let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
 button.isBordered = false
 button.toolTip = title
 toolbar.addArrangedSubview(button)
 }
 outputScroll.translatesAutoresizingMaskIntoConstraints = false
 outputScroll.hasVerticalScroller = true
 outputScroll.drawsBackground = false
 outputScroll.borderType = .noBorder
 outputText.isEditable = false
 outputText.drawsBackground = false
 outputText.font = AgentTheme.Font.monoSmall
 outputText.textColor = AgentTheme.Color.textSecondary
 outputText.textContainerInset = NSSize(width:10, height:6)
 outputText.isVerticallyResizable = true
 outputText.isHorizontallyResizable = false
 outputText.autoresizingMask = [.width]
 outputText.textContainer?.widthTracksTextView = true
 outputText.textContainer?.containerSize = NSSize(
 width:0, height: CGFloat.greatestFiniteMagnitude)
 outputText.layoutManager?.usesFontLeading = true
 outputScroll.documentView = outputText
 detailContainer.addSubview(outputScroll)

 NSLayoutConstraint.activate([
 row.topAnchor.constraint(equalTo: topAnchor),
 row.leadingAnchor.constraint(equalTo: leadingAnchor),
 row.trailingAnchor.constraint(equalTo: trailingAnchor),
 row.bottomAnchor.constraint(equalTo: bottomAnchor),
 detailContainer.widthAnchor.constraint(equalTo: row.widthAnchor),
 toolbar.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant:10),
 toolbar.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant:10),
 toolbar.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -10),
 outputScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant:6),
 outputScroll.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
 outputScroll.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
 outputScroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
 outputScroll.heightAnchor.constraint(equalToConstant: AgentTheme.Metric.toolCardBodyMaxHeight)
 ])
 }

 @objc private func copyRecord() {
 NSPasteboard.general.clearContents()
 NSPasteboard.general.setString(outputText.string, forType: .string)
 }

 @objc private func saveRecord() {
 guard let window else { return }
 let panel = NSSavePanel()
 panel.nameFieldStringValue = "terminal.txt"
 let record = outputText.string
 panel.beginSheetModal(for: window) { response in
 guard response == .OK, let url = panel.url else { return }
 do { try record.write(to: url, atomically: true, encoding: .utf8) }
 catch { NSApp.presentError(error) }
 }
 }

 private func refreshDisclosure() {
 detailContainer.isHidden = !expanded
 expandButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "收起" : "展开")
 }
 override func update(item: AgentItem, width: CGFloat) {
 guard let tool = item.tool else { return }
 let previous = currentTool
 currentTool = tool
 expanded = userExpanded ?? (tool.status == .running)
 refreshDisclosure()
 toolIcon.image = NSImage(systemSymbolName: tool.command == nil ? "wrench" : "terminal", accessibilityDescription: nil)
 terminalLabel.stringValue = tool.terminalTitle ?? ""
 terminalLabel.isHidden = tool.terminalTitle == nil

 if let command = tool.command, command.isEmpty == false {
 summaryLabel.stringValue = command
 } else {
 summaryLabel.stringValue = tool.title
 }

 statusLabel.toolTip = tool.completionState == .unknown ? "终端已返回提示符或结束标记，但未提供退出码，无法确认命令是否成功。" : nil
 switch tool.status {
 case .running:
 statusLabel.stringValue = "执行中"
 statusLabel.textColor = AgentTheme.Color.textSecondary
 case .success:
 statusLabel.stringValue = tool.completionState == .unknown ? "已结束" : "执行成功"
 statusLabel.textColor = tool.completionState == .unknown ? AgentTheme.Color.textSecondary : AgentTheme.Color.taskSuccess
 case .failure:
 if tool.completionState == .unconfirmed {
 statusLabel.stringValue = "结束状态未确认"
 } else if let code = tool.exitCode {
 statusLabel.stringValue = "失败（退出码 \(code)）"
 } else {
 statusLabel.stringValue = "失败"
 }
 statusLabel.textColor = tool.completionState == .unconfirmed ? AgentTheme.Color.pending : AgentTheme.Color.danger
 case .rejected:
 statusLabel.stringValue = "已拒绝"
 statusLabel.textColor = AgentTheme.Color.textTertiary
 case .cancelled:
 statusLabel.stringValue = "已取消"
 statusLabel.textColor = AgentTheme.Color.textTertiary
 case .awaitingApproval:
 statusLabel.stringValue = "待审批"
 statusLabel.textColor = AgentTheme.Color.pending
 case .pending:
 statusLabel.stringValue = "等待中"
 statusLabel.textColor = AgentTheme.Color.textTertiary
 }

 if previous == nil || previous?.command != tool.command {
 if let command = tool.command {
 commandLabel.stringValue = AgentToolCatalog.commandPurpose(fromArguments: tool.argumentsJSON) ?? command
 } else {
 commandLabel.stringValue = tool.title
 }
 }
 if previous?.output != tool.output || previous?.status != tool.status || previous?.errorMessage != tool.errorMessage {
 var output = tool.output
 if let error = tool.errorMessage {
 output = [output, error].filter { !$0.isEmpty }.joined(separator: "\n\n")
 }
 if output.isEmpty {
 switch tool.status {
 case .running: output = "等待终端输出…"
 case .awaitingApproval: output = "批准后开始执行"
 default: output = "（无输出）"
 }
 }
 if let command = tool.command { output = "$ " + command + "\n" + output }
 let selection = outputText.selectedRange()
 let current = outputText.string
 let currentLength = current.utf16.count
 let followsTail = selection.length == 0 && outputText.bounds.maxY - outputScroll.contentView.bounds.maxY < 24
 if !current.isEmpty, output.utf16.starts(with: current.utf16) {
 outputText.textStorage?.replaceCharacters(in: NSRange(location: currentLength, length: 0),
 with: String(decoding: output.utf16.dropFirst(currentLength), as: UTF16.self))
 outputText.setSelectedRange(selection)
 } else {
 outputText.string = output
 }

 if followsTail {
 outputText.scrollRangeToVisible(NSRange(location: output.utf16.count, length: 0))
 }
 }
 }

 override var copyableText: String { return currentTool?.output ?? "" }

 @objc private func toggleExpanded() {
 expanded.toggle()
 userExpanded = expanded
 refreshDisclosure()
 }
}

/// Inline approval card shown above the composer while the task waits.
@MainActor
final class AgentApprovalView: AgentRowView {
 let request: AgentApprovalRequest

 var onApprove: ((AgentApprovalGrant) -> Void)?
 var onReject: (() -> Void)?

 init(request: AgentApprovalRequest) {
 self.request = request
 super.init(frame: .zero)
 setUp()
 }

 required init?(coder: NSCoder) { return nil }

 private func setUp() {
 wantsLayer = true
 surfaceColor = AgentTheme.Color.deepest
 layer?.cornerRadius = AgentTheme.Metric.radiusCard
 layer?.borderWidth=1
 outlineColor = AgentTheme.Color.border

 let column = NSStackView()
 column.translatesAutoresizingMaskIntoConstraints = false
 column.orientation = .vertical
 column.alignment = .leading
 column.spacing=8
 addSubview(column)

 var titleText = "AI 请求执行命令，是否允许？"
 if request.isDangerous {
 titleText = "包含危险命令，是否仍要运行？"
 }
 let title = NSTextField(wrappingLabelWithString: titleText)
 title.translatesAutoresizingMaskIntoConstraints = false
 title.font = AgentTheme.Font.bodyMedium
 title.textColor = request.isDangerous ? AgentTheme.Color.permissionWarning : AgentTheme.Color.text
 column.addArrangedSubview(title)

 if let targetTitle = request.targetTitle {
 let target = NSTextField(wrappingLabelWithString: "目标终端 · \(targetTitle)")
 target.font = AgentTheme.Font.bodySmall
 target.textColor = AgentTheme.Color.textSecondary
 column.addArrangedSubview(target)
 }

 let purpose = NSTextField(wrappingLabelWithString: request.commandPurpose.map { "命令用途 · AI 说明：\($0)" } ?? "命令用途 · AI 未提供说明，请核对下方命令。")
 purpose.font = AgentTheme.Font.bodySmall
 purpose.textColor = AgentTheme.Color.text
 column.addArrangedSubview(purpose)

 let summary = NSTextView.scrollableTextView()
 let command = summary.documentView as! NSTextView
 command.isEditable = false
 command.isRichText = false
 command.textContainerInset = NSSize(width: 6, height: 5)
 command.string = request.summary
 command.font = AgentTheme.Font.monoSmall
 command.textColor = AgentTheme.Color.text
 command.drawsBackground = false
 summary.backgroundColor = AgentTheme.Color.cardInset
 summary.autohidesScrollers = true
 summary.wantsLayer = true
 summary.layer?.cornerRadius = 6
 column.addArrangedSubview(summary)

 if let reason = request.reason {
 let detail = NSTextField(wrappingLabelWithString: reason)
 detail.font = AgentTheme.Font.bodySmall
 detail.textColor = AgentTheme.Color.textSecondary
 column.addArrangedSubview(detail)
 detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
 }

 let actionRow = NSStackView()
 actionRow.translatesAutoresizingMaskIntoConstraints = false
 actionRow.orientation = .horizontal
 actionRow.spacing=8
 actionRow.alignment = .centerY
 let spacer = NSView()
 spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
 actionRow.addArrangedSubview(spacer)
 let reject = NSButton(title: "不执行", target: self, action: #selector(rejectTapped))
 reject.bezelStyle = .rounded
 actionRow.addArrangedSubview(reject)
 let confirm = AgentFilledActionButton(title: "确认执行", color: StacioDesignSystem.theme.accentColor, target: self, action: #selector(confirmTapped))
 actionRow.addArrangedSubview(confirm)
 column.addArrangedSubview(actionRow)

 NSLayoutConstraint.activate([
 column.topAnchor.constraint(equalTo: topAnchor, constant:14),
 column.leadingAnchor.constraint(equalTo: leadingAnchor, constant:16),
 column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
 column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
 title.widthAnchor.constraint(equalTo: column.widthAnchor),
 purpose.widthAnchor.constraint(equalTo: column.widthAnchor),
 summary.widthAnchor.constraint(equalTo: column.widthAnchor),
 summary.heightAnchor.constraint(equalToConstant: 64),
 actionRow.widthAnchor.constraint(equalTo: column.widthAnchor)
 ])
 }

 @objc private func confirmTapped() {
 onApprove?(.once)
 }

 @objc private func rejectTapped() {
 onReject?()
 }
}

@MainActor
final class AgentErrorRowView: AgentRowView {
 private let label = NSTextField(wrappingLabelWithString: "")

 init() {
 super.init(frame: .zero)
 label.translatesAutoresizingMaskIntoConstraints = false
 label.font = AgentTheme.Font.bodySmall
 label.textColor = AgentTheme.Color.danger
 label.maximumNumberOfLines=0
 addSubview(label)
 NSLayoutConstraint.activate([
 label.topAnchor.constraint(equalTo: topAnchor),
 label.leadingAnchor.constraint(equalTo: leadingAnchor),
 label.trailingAnchor.constraint(equalTo: trailingAnchor),
 label.bottomAnchor.constraint(equalTo: bottomAnchor)
 ])
 }

 required init?(coder: NSCoder) { return nil }

 override func update(item: AgentItem, width: CGFloat) {
 label.stringValue = item.text
 label.preferredMaxLayoutWidth = width
 }
}

@MainActor
final class AgentRejectedRowView: AgentRowView {
 private let label = NSTextField(wrappingLabelWithString: "")

 init() {
 super.init(frame: .zero)
 label.translatesAutoresizingMaskIntoConstraints = false
 label.font = AgentTheme.Font.caption
 label.textColor = AgentTheme.Color.textTertiary
 label.maximumNumberOfLines=0
 addSubview(label)
 NSLayoutConstraint.activate([
 label.topAnchor.constraint(equalTo: topAnchor),
 label.leadingAnchor.constraint(equalTo: leadingAnchor),
 label.trailingAnchor.constraint(equalTo: trailingAnchor),
 label.bottomAnchor.constraint(equalTo: bottomAnchor)
 ])
 }

 required init?(coder: NSCoder) { return nil }

 override func update(item: AgentItem, width: CGFloat) {
 label.stringValue = item.text.isEmpty ? "模型本次输出不符合预期" : item.text
 label.preferredMaxLayoutWidth = width
 }
}


