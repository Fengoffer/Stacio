import AppKit

/// The conversation rail: search, new-conversation row, grouped list.
@MainActor
final class AgentConversationRailView: NSView {
 private let titleLabel = NSTextField(labelWithString: "会话历史")
 private let searchField = NSSearchField()
 private let scrollView = NSScrollView()
 private let stack = FlippedStackView()
 private let collapseButton = NSButton()
 private var conversations: [AgentConversation] = []
 private var activeID = ""
 private var filterText = ""

 var onSelect: ((AgentConversation) -> Void)?
 var onNew: (() -> Void)?
 var onDelete: ((String) -> Void)?
 var onRename: ((String, String) -> Void)?
 var onCollapse: (() -> Void)?

 override init(frame frameRect: NSRect) {
 super.init(frame: frameRect)
 translatesAutoresizingMaskIntoConstraints = false
 setUp()
 }

 required init?(coder: NSCoder) { return nil }

 private func setUp() {
 let header = NSView()
 header.translatesAutoresizingMaskIntoConstraints = false
 addSubview(header)

 titleLabel.translatesAutoresizingMaskIntoConstraints = false
 titleLabel.font = AgentTheme.Font.title
 titleLabel.textColor = AgentTheme.Color.text
 header.addSubview(titleLabel)

 let searchButton = NSButton()
 searchButton.translatesAutoresizingMaskIntoConstraints = false
 searchButton.isBordered = false
 searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索会话标题")
 searchButton.imagePosition = .imageOnly
 searchButton.contentTintColor = AgentTheme.Color.textTertiary
 searchButton.target = self
 searchButton.action = #selector(toggleSearch)
 searchButton.widthAnchor.constraint(equalToConstant:20).isActive = true
 header.addSubview(searchButton)

 collapseButton.translatesAutoresizingMaskIntoConstraints = false
 collapseButton.isBordered = false
 collapseButton.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "关闭历史")
 collapseButton.imagePosition = .imageOnly
 collapseButton.contentTintColor = AgentTheme.Color.textTertiary
 collapseButton.target = self
 collapseButton.action = #selector(collapseTapped)
 collapseButton.widthAnchor.constraint(equalToConstant:20).isActive = true
 header.addSubview(collapseButton)

 searchField.translatesAutoresizingMaskIntoConstraints = false
 searchField.placeholderString = "搜索会话标题"
 searchField.font = AgentTheme.Font.bodySmall
 searchField.isHidden = true
 searchField.target = self
 searchField.action = #selector(searchChanged)
 searchField.sendsSearchStringImmediately = true
 addSubview(searchField)

 scrollView.translatesAutoresizingMaskIntoConstraints = false
 scrollView.hasVerticalScroller = true
 scrollView.drawsBackground = false
 scrollView.scrollerStyle = .overlay
 addSubview(scrollView)

 stack.translatesAutoresizingMaskIntoConstraints = false
 stack.orientation = .vertical
 stack.alignment = .leading
 stack.spacing=0
 stack.edgeInsets = NSEdgeInsets(top:4, left:4, bottom:8, right:4)
 scrollView.documentView = stack

 NSLayoutConstraint.activate([
 header.topAnchor.constraint(equalTo: topAnchor),
 header.leadingAnchor.constraint(equalTo: leadingAnchor),
 header.trailingAnchor.constraint(equalTo: trailingAnchor),
 header.heightAnchor.constraint(equalToConstant: AgentTheme.Metric.headerHeight),
 titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant:16),
 titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
 collapseButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
 collapseButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
 searchButton.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -6),
 searchButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
 searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant:4),
 searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant:8),
 searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
 scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant:4),
 scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
 scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
 ])
 }

 func reload(conversations: [AgentConversation], activeID: String) {
 self.conversations = conversations
 self.activeID = activeID
 rebuild()
 }

 private func rebuild() {
 for view in stack.arrangedSubviews {
 stack.removeArrangedSubview(view)
 view.removeFromSuperview()
 }

 let newChatRow = makeNewChatRow()
 stack.addArrangedSubview(newChatRow)
 pinToStackWidth(newChatRow)

 var visible: [AgentConversation] = []
 for conversation in conversations {
 if filterText.isEmpty {
 visible.append(conversation)
 } else {
 if conversation.displayTitle.localizedCaseInsensitiveContains(filterText) {
 visible.append(conversation)
 }
 }
 }

 if visible.isEmpty {
 var emptyText = "暂无会话"
 if filterText.isEmpty == false {
 emptyText = "没有匹配的会话"
 }
 let empty = NSTextField(labelWithString: emptyText)
 empty.translatesAutoresizingMaskIntoConstraints = false
 empty.font = AgentTheme.Font.bodySmall
 empty.textColor = AgentTheme.Color.textDisabled
 empty.alignment = .center
 empty.heightAnchor.constraint(equalToConstant:44).isActive = true
 stack.addArrangedSubview(empty)
 pinToStackWidth(empty)
 return
 }

 for conversation in visible {
 let row = makeRow(for: conversation)
 stack.addArrangedSubview(row)
 row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
 }
 }

 private func makeNewChatRow() -> NSView {
 let row = AgentRailRow(icon: "plus", title: "新会话", height:36)
 row.onClick = { [weak self] in self?.onNew?() }
 return row
 }

 private func pinToStackWidth(_ view: NSView) {
 guard view.superview === stack else { return }
 view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
 }

 private func makeGroupHeader(_ title: String) -> NSView {
 let container = NSView()
 container.translatesAutoresizingMaskIntoConstraints = false
 container.heightAnchor.constraint(equalToConstant:28).isActive = true
 let label = NSTextField(labelWithString: title)
 label.translatesAutoresizingMaskIntoConstraints = false
 label.font = AgentTheme.Font.caption
 label.textColor = AgentTheme.Color.textTertiary
 container.addSubview(label)
 NSLayoutConstraint.activate([
 label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant:12),
 label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
 ])
 return container
 }

 private func makeRow(for conversation: AgentConversation) -> NSView {
 let row = AgentRailRow(icon: nil, title: conversation.displayTitle, height:32)
 row.isActive = conversation.id == activeID
 if conversation.isRunning {
 if conversation.phase == .waitingApproval {
 row.badgeText = "待审批"
 }
 }
 row.onClick = { [weak self] in self?.onSelect?(conversation) }
 row.onRequestRename = { [weak self] in
 guard let self else { return }
 let alert = NSAlert()
 alert.messageText = "重命名会话"
 let field = NSTextField(string: conversation.displayTitle)
 field.frame = NSRect(x:0, y:0, width:260, height:24)
 alert.accessoryView = field
 alert.addButton(withTitle: "保存")
 alert.addButton(withTitle: "取消")
 if alert.runModal() == .alertFirstButtonReturn {
 let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
 if value.isEmpty == false {
 self.onRename?(conversation.id, value)
 }
 }
 }
 row.onRequestDelete = { [weak self] in
 guard let self else { return }
 let alert = NSAlert()
 alert.messageText = "删除会话"
 if conversation.isRunning {
 alert.informativeText = "该会话仍有运行中的生成或任务，删除会先停止它们。"
 } else {
 alert.informativeText = "删除后无法恢复。"
 }
 alert.addButton(withTitle: "删除")
 alert.addButton(withTitle: "取消")
 if alert.runModal() == .alertFirstButtonReturn {
 self.onDelete?(conversation.id)
 }
 }
 return row
 }

 @objc private func toggleSearch() {
 searchField.isHidden.toggle()
 if searchField.isHidden {
 filterText = ""
 searchField.stringValue = ""
 rebuild()
 } else {
 searchField.becomeFirstResponder()
 }
 }

 @objc private func searchChanged() {
 filterText = searchField.stringValue
 rebuild()
 }

 @objc private func collapseTapped() {
 onCollapse?()
 }
}

/// One rail row:32pt tall,6pt radius, hover and active backgrounds.
@MainActor
final class AgentRailRow: NSView {
 private let iconView = NSImageView()
 private let titleLabel = NSTextField(labelWithString: "")
 private let badge = NSTextField(labelWithString: "")
 private let menuButton = NSButton()

 var onClick: (() -> Void)?
 var onRequestRename: (() -> Void)?
 var onRequestDelete: (() -> Void)?

 var isActive = false {
 didSet { updateBackground() }
 }

 var badgeText: String? {
 didSet {
 badge.stringValue = badgeText ?? ""
 badge.isHidden = badgeText == nil
 }
 }

 init(icon: String?, title: String, height: CGFloat) {
 super.init(frame: .zero)
 translatesAutoresizingMaskIntoConstraints = false
 wantsLayer = true
 layer?.cornerRadius = AgentTheme.Metric.radiusCard
 heightAnchor.constraint(equalToConstant: height).isActive = true

 iconView.translatesAutoresizingMaskIntoConstraints = false
 if let icon {
 iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
 }
 iconView.imageScaling = .scaleProportionallyDown
 iconView.contentTintColor = AgentTheme.Color.textSecondary
 iconView.isHidden = icon == nil
 addSubview(iconView)

 titleLabel.translatesAutoresizingMaskIntoConstraints = false
 titleLabel.stringValue = title
 titleLabel.font = AgentTheme.Font.bodySmall
 titleLabel.textColor = AgentTheme.Color.text
 titleLabel.lineBreakMode = .byTruncatingTail
 titleLabel.maximumNumberOfLines=1
 addSubview(titleLabel)

 badge.translatesAutoresizingMaskIntoConstraints = false
 badge.font = AgentTheme.Font.caption
 badge.textColor = AgentTheme.Color.pending
 badge.isHidden = true
 addSubview(badge)

 menuButton.translatesAutoresizingMaskIntoConstraints = false
 menuButton.isBordered = false
 menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
 menuButton.imagePosition = .imageOnly
 menuButton.contentTintColor = AgentTheme.Color.textTertiary
 menuButton.target = self
 menuButton.action = #selector(showMenu)
 menuButton.isHidden = true
 menuButton.widthAnchor.constraint(equalToConstant:16).isActive = true
 addSubview(menuButton)

 NSLayoutConstraint.activate([
 iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant:8),
 iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
 iconView.widthAnchor.constraint(equalToConstant:14),
 iconView.heightAnchor.constraint(equalToConstant:14),
 titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant:8),
 titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
 titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4),
 badge.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -4),
 badge.centerYAnchor.constraint(equalTo: centerYAnchor),
 menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
 menuButton.centerYAnchor.constraint(equalTo: centerYAnchor)
 ])

 if icon == nil {
 iconView.widthAnchor.constraint(equalToConstant:1).isActive = true
 }
 }

 required init?(coder: NSCoder) { return nil }

 override func updateTrackingAreas() {
 super.updateTrackingAreas()
 let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
 addTrackingArea(area)
 }

 private func updateBackground() {
 if isActive {
 layer?.backgroundColor = AgentTheme.Color.selectedRow.cgColor
 } else {
 layer?.backgroundColor = NSColor.clear.cgColor
 }
 }

 override func mouseEntered(with event: NSEvent) {
 menuButton.isHidden = false
 if isActive == false {
 layer?.backgroundColor = AgentTheme.Color.hoverRow.cgColor
 }
 }

 override func mouseExited(with event: NSEvent) {
 menuButton.isHidden = true
 updateBackground()
 }

 override func mouseDown(with event: NSEvent) {
 onClick?()
 }

 @objc private func showMenu() {
 let menu = NSMenu()
 let rename = NSMenuItem(title: "重命名", action: #selector(renameTapped), keyEquivalent: "")
 rename.target = self
 menu.addItem(rename)
 let delete = NSMenuItem(title: "删除会话", action: #selector(deleteTapped), keyEquivalent: "")
 delete.target = self
 menu.addItem(delete)
 menu.popUp(positioning: nil, at: NSPoint(x: bounds.width - 20, y: bounds.height), in: self)
 }

 @objc private func renameTapped() { onRequestRename?() }
 @objc private func deleteTapped() { onRequestDelete?() }
}
