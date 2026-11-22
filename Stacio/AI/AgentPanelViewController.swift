import AppKit

/// Stacio’s assistant inside the workbench inspector.
@MainActor
public final class AgentPanelViewController: NSViewController {
 /// Fires when the panel starts or stops waiting on the user, so a host can
 /// surface that while another tab is showing.
 public var onAttentionChanged: ((String?) -> Void)?

 public var onRequestSettings: (() -> Void)?
 public var onRequestPermissionSettings: (() -> Void)?
 public var onRequestClose: (() -> Void)?


 private let session: AgentSession
 private let rail = AgentConversationRailView()
 private let historyPopover = NSPopover()
 private let historyButton = NSButton()
 private let emptyState = NSTextField(wrappingLabelWithString: "")
 private let chatColumn = NSView()
 private let header = NSView()
 private let titleLabel = NSTextField(labelWithString: "新会话")
 private let transcript = AgentTranscriptView()
 private let composer = AgentComposerView()
 private var settingsObserver: NSObjectProtocol?
 private var pendingStreamingRefresh: Task<Void, Never>?
 private var streamingItemID: String?
 private let activityLabel = NSTextField(labelWithString: "")
 private let approvalDock = NSStackView()
 private var approvalView: AgentApprovalView?
 private var activityHeight: NSLayoutConstraint?
 private let disclaimer = NSTextField(labelWithString: "内容由 AI生成，仅供参考")
 /// Builds a panel bound to one session.
 public static func make(
 terminalLister: AgentTerminalSessionListing?,
 executorResolver: AgentTerminalResolving
 ) -> AgentPanelViewController {
 let session = AgentSession(
 terminalLister: terminalLister,
 executorResolver: executorResolver
 )
 return AgentPanelViewController(session: session)
 }

 init(session: AgentSession) {
 self.session = session
 super.init(nibName: nil, bundle: nil)
 session.onChange = { [weak self] change in
 self?.apply(change)
 }
 settingsObserver = NotificationCenter.default.addObserver(
     forName: AppSettingsStore.didChangeNotification,
     object: AppSettingsStore.shared,
     queue: nil
 ) { [weak self] _ in
     // Provider settings are saved off the main thread. Return to the writer
     // immediately, then refresh AppKit without holding its transaction locks.
     Task { @MainActor [weak self] in
         self?.permissionSettingsChanged()
     }
 }
 }

 deinit {
 if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
 }

 private func permissionSettingsChanged() {
 guard isViewLoaded else { return }
 composer.apply(model: session.active.modelSelection, permission: session.active.permissionMode, preferences: session.permissionPreferences)
 composer.applyRunning(session.isRunning)
 }

 public required init?(coder: NSCoder) { return nil }

 public override func loadView() {
 let root = AgentSurfaceView()
 root.translatesAutoresizingMaskIntoConstraints = false
 root.surfaceColor = AgentTheme.Color.panel
 view = root
 buildRail()
 buildChat()
 refreshAll()
 }

 public override func viewDidAppear() {
 super.viewDidAppear()
 refreshForCurrentContext()
 composer.focusInput()
 }


 public func refreshForCurrentContext() {
 session.refreshTerminals()
 session.refreshModels()
 apply(.composer)
 }

 public func prefillQuestion(_ question: String) {
 session.updateDraft(question)
 composer.focusInput()
 }

 public func setInspectorInteractiveResizeActive(_ isActive: Bool) {
 view.needsLayout = true
 }

 public func followCurrentTerminalContext() {
 refreshForCurrentContext()
 }

 /// The inspector asks for a layout refresh while the user drags its divider.
 public func refreshLayoutDuringInspectorInteractiveResize() {
 view.needsLayout = true
 }

 /// The new panel never holds the app open: a turn is cancelled, not awaited.
 public var requiresHostClosureSettlement: Bool { return false }

 public func prepareForHostClosureAsync() async -> Bool {
 return true
 }

	public func focusQuestionField() {
		// The panel is revealed by switching inspector tabs, and the view may not be in
		// a window yet at that moment. Retry on the next turns until it is, otherwise
		// the composer never becomes first responder and typing does nothing.
		focusComposer(attemptsRemaining:4)
	}

	private func focusComposer(attemptsRemaining: Int) {
		if let window = view.window {
			let ok = window.makeFirstResponder(composer.textInput)
			return
		}
		guard attemptsRemaining > 0 else { return }
		DispatchQueue.main.async { [weak self] in
			self?.focusComposer(attemptsRemaining: attemptsRemaining - 1)
		}
	}

 private func buildRail() {
 let controller = NSViewController()
 let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 340))
 controller.view = container
 container.addSubview(rail)
 NSLayoutConstraint.activate([
 rail.topAnchor.constraint(equalTo: container.topAnchor),
 rail.leadingAnchor.constraint(equalTo: container.leadingAnchor),
 rail.trailingAnchor.constraint(equalTo: container.trailingAnchor),
 rail.bottomAnchor.constraint(equalTo: container.bottomAnchor)
 ])
 historyPopover.contentViewController = controller
 historyPopover.contentSize = container.frame.size
 historyPopover.behavior = .transient
 rail.onSelect = { [weak self] conversation in
 self?.session.select(conversation)
 self?.historyPopover.close()
 }
 rail.onNew = { [weak self] in self?.newConversation() }
 rail.onDelete = { [weak self] id in self?.session.delete(id) }
 rail.onRename = { [weak self] id, title in self?.session.rename(id, to: title) }
 rail.onCollapse = { [weak self] in self?.historyPopover.close() }
 }

 private func buildChat() {
 chatColumn.translatesAutoresizingMaskIntoConstraints = false
 view.addSubview(chatColumn)

 header.translatesAutoresizingMaskIntoConstraints = false
 chatColumn.addSubview(header)

 _ = makeHeaderButton(historyButton, symbol: "clock", tooltip: "会话历史", action: #selector(toggleHistory))
 let newButton = makeHeaderButton(symbol: "square.and.pencil", tooltip: "新会话", action: #selector(newConversation))
 let settingsButton = makeHeaderButton(symbol: "gearshape", tooltip: "AI设置", action: #selector(openSettings))


 titleLabel.translatesAutoresizingMaskIntoConstraints = false
 titleLabel.font = AgentTheme.Font.title
 titleLabel.textColor = AgentTheme.Color.text
 titleLabel.lineBreakMode = .byTruncatingTail
 titleLabel.maximumNumberOfLines=1

 let actions = NSStackView(views: [historyButton, newButton, settingsButton])
 actions.translatesAutoresizingMaskIntoConstraints = false
 actions.spacing = 4
 header.addSubview(titleLabel)
 header.addSubview(actions)
 let separator = AgentSurfaceView()
 separator.surfaceColor = AgentTheme.Color.border
 separator.translatesAutoresizingMaskIntoConstraints = false
 header.addSubview(separator)

 NSLayoutConstraint.activate([
 header.topAnchor.constraint(equalTo: chatColumn.topAnchor),
 header.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor),
 header.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor),
 header.heightAnchor.constraint(equalToConstant: 44),
 titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
 titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
 titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
 actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
 actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
 separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
 separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
 separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
 separator.heightAnchor.constraint(equalToConstant: 1)
 ])

 transcript.setAccessibilityIdentifier("Stacio.AI.conversation")
 transcript.translatesAutoresizingMaskIntoConstraints = false
	 chatColumn.addSubview(transcript)
 emptyState.translatesAutoresizingMaskIntoConstraints = false
 emptyState.font = AgentTheme.Font.body
 emptyState.textColor = AgentTheme.Color.textSecondary
 emptyState.alignment = .center
 chatColumn.addSubview(emptyState)
 approvalDock.translatesAutoresizingMaskIntoConstraints = false
 approvalDock.orientation = .vertical
 approvalDock.alignment = .leading
 chatColumn.addSubview(approvalDock)

 activityLabel.translatesAutoresizingMaskIntoConstraints = false
 activityLabel.font = AgentTheme.Font.caption
 activityLabel.textColor = AgentTheme.Color.textSecondary
 activityLabel.isHidden = true
 chatColumn.addSubview(activityLabel)
 let height = activityLabel.heightAnchor.constraint(equalToConstant: 0)
 activityHeight = height
 height.isActive = true

 disclaimer.translatesAutoresizingMaskIntoConstraints = false
 disclaimer.font = AgentTheme.Font.caption
 disclaimer.textColor = AgentTheme.Color.textTertiary
 disclaimer.alignment = .center
	 chatColumn.addSubview(disclaimer)

 composer.setAccessibilityIdentifier("Stacio.AI.composer")
 composer.translatesAutoresizingMaskIntoConstraints = false
	 chatColumn.addSubview(composer)
 composer.onPasteImage = { [weak self] data in self?.session.attachImage(data) }
 session.onAttachmentError = { [weak self] message in
 guard let window = self?.view.window else { return }; let alert = NSAlert(); alert.messageText = message; alert.beginSheetModal(for: window)
 }
 composer.onSend = { [weak self] in self?.session.send() }
 composer.onStop = { [weak self] in self?.session.stop() }
 composer.onDraftChange = { [weak self] text in self?.session.updateDraft(text) }
 composer.onRemoveChip = { [weak self] id in self?.session.removeContextChip(id) }
 composer.onPickModel = { [weak self] anchor in self?.presentModelMenu(anchor: anchor) }
 composer.onEnhance = { [weak self] in self?.session.enhanceDraft() }
 composer.onPickPermission = { [weak self] anchor in self?.presentPermissionMenu(anchor: anchor) }
 composer.onPickContext = { [weak self] anchor in self?.presentContextMenu(anchor: anchor) }

 NSLayoutConstraint.activate([
 chatColumn.topAnchor.constraint(equalTo: view.topAnchor),
 chatColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
 chatColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			chatColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
 transcript.topAnchor.constraint(equalTo: header.bottomAnchor),
 transcript.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor),
 transcript.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor),
 transcript.bottomAnchor.constraint(equalTo: approvalDock.topAnchor),
 approvalDock.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
 approvalDock.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
 approvalDock.bottomAnchor.constraint(equalTo: activityLabel.topAnchor),
 activityLabel.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
 activityLabel.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
 activityLabel.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
 emptyState.centerXAnchor.constraint(equalTo: transcript.centerXAnchor),
 emptyState.centerYAnchor.constraint(equalTo: transcript.centerYAnchor),
 emptyState.widthAnchor.constraint(equalTo: transcript.widthAnchor, multiplier: 0.8),
 composer.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor, constant: AgentTheme.Metric.contentPaddingHorizontal),
 composer.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor, constant: -AgentTheme.Metric.contentPaddingHorizontal),
 composer.bottomAnchor.constraint(equalTo: disclaimer.topAnchor, constant: -2),
 disclaimer.leadingAnchor.constraint(equalTo: chatColumn.leadingAnchor),
 disclaimer.trailingAnchor.constraint(equalTo: chatColumn.trailingAnchor),
 disclaimer.bottomAnchor.constraint(equalTo: chatColumn.bottomAnchor, constant: -6),
 disclaimer.heightAnchor.constraint(equalToConstant:16)
 ])
 }

 /// Renders a representative transcript without touching the session.
 /// Used by the offscreen renderer to inspect message and tool-card layout.
	/// The transcript view, for layout assertions in tests.
	/// The composer, for end-to-end tests through the panel.
	var composerForTesting: AgentComposerView { composer }

	var conversationViewForTesting: NSView? { transcript }

 public func markdownProbe() -> String { markdownProbeForHarness() }
 /// Renders one of the panel states the rewrite must match, for screenshot
 /// comparison. Kept separate from the sample transcript so each state is
 /// reproducible on its own.
 public func showStateForHarness(_ state: String) {
 switch state {
 case "streaming":
 let streaming = AgentItem(
 kind: .assistant,
 text: "我先确认根分区的使用情况，再逐层找出占用最大的目录。",
 reasoning: "需要先看整体用量，再定位到具体目录。",
 isStreaming: true
 )
 transcript.reload(items: [
 AgentItem(kind: .user, text: "服务器磁盘快满了，帮我看看哪个目录占得最多"),
 streaming
 ])
 case "error":
 let failing = AgentToolInvocation(
 id: "t-err",
 name: "execute_terminal_command",
 title: "执行终端命令",
 argumentsJSON: "{\"command\":\"ls /nope\"}",
 command: "ls /nope",
 status: .failure,
 output: "ls: /nope: No such file or directory",
 exitCode:1
 )
 transcript.reload(items: [
 AgentItem(kind: .user, text: "看看 /nope里有什么"),
 AgentItem(kind: .tool, tool: failing),
 AgentItem(kind: .error, text: "命令执行失败：退出码1。终端未返回预期输出。")
 ])
 case "stopped":
 let stopped = AgentItem(
 kind: .assistant,
 text: "根分区已用89%，建议先清理轮转日志，然后",
 isStreaming: false,
 aborted: true
 )
 transcript.reload(items: [
 AgentItem(kind: .user, text: "服务器磁盘快满了，帮我看看哪个目录占得最多"),
 stopped
 ])
 case "long-history":
 var items: [AgentItem] = []
 for turn in 0..<8 {
 items.append(AgentItem(kind: .user, text: "第 \(turn + 1)个问题：检查服务状态"))
 items.append(AgentItem(
 kind: .assistant,
 text: "第 \(turn + 1)次回答：当前33个服务均为系统自带组件，未发现异常。"))
 }
 transcript.reload(items: items)
 case "approval":
 showApprovalForHarness()
 default:
 showSampleTranscriptForHarness()
 }
 }
 public func showSampleTranscriptForHarness() {
 let tool = AgentToolInvocation(
 id: "t1",
 name: "execute_terminal_command",
 title: "执行终端命令",
 argumentsJSON: "{\"command\":\"df -h\"}",
 command: "df -h",
 status: .success,
 output: "Filesystem Size Used Avail Capacity Mounted on\n"
 + "/dev/disk1s1 466Gi 412Gi 54Gi 89% /\n"
 + "/dev/disk1s2 466Gi 412Gi 54Gi 89% /System/Volumes/Data\n"
 + "devfs 198Ki 198Ki 0Bi 100% /dev\n"
 + "map auto_home 0Bi 0Bi 0Bi 100% /System/Volumes/Data/home",
 exitCode:0
 )
 let items: [AgentItem] = [
 AgentItem(kind: .user, text: "服务器磁盘快满了，帮我看看哪个目录占得最多"),
 AgentItem(
 kind: .assistant,
 text: "我先确认根分区的使用情况，再逐层找出占用最大的目录。",
 reasoning: "先用 df确认挂载点，再用 du排序定位。"
 ),
 AgentItem(kind: .tool, tool: tool),
 AgentItem(
 kind: .assistant,
 text: "**结论**：根分区已用89%，需要清理。\n\n排查结果\n\n- 当前占用最高的目录：\n  - /var/log轮转日志积压\n  - /var/cache包管理器缓存\n- 建议动作：\n  - 清理7天前的轮转日志"
 )
 ]
 transcript.reload(items: items)
 }

 func markdownProbeForHarness() -> String {
 let md = "**粗体**与 `代码`\n\n- 第一项\n - 子项\n- 第二项"
 let rendered = AgentMarkdownRenderer.render(md, width:260)
 let raw = rendered.string.replacingOccurrences(of: "\n", with: "|")
 var out: [String] = []
 rendered.enumerateAttribute(.font, in: NSRange(location:0, length: rendered.length)) { value, range, _ in
 let weight = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
 let text = (rendered.string as NSString).substring(with: range)
 out.append(weight ? "BOLD(" + text + ")" : text)
 }
 return raw + " >> " + out.joined()
 }
 func loadTranscriptEntriesForPerformanceTesting(count: Int) {
 var items: [AgentItem] = []
 for index in 0..<count {
 items.append(AgentItem(kind: .assistant, text: "性能测试条目 \(index)：用于测量长会话下的布局开销。"))
 }
 transcript.reload(items: items)
 view.layoutSubtreeIfNeeded()
 }

 var appliedTranscriptTextWidthForTesting: CGFloat? {
 transcript.appliedTextWidthForTesting
 }
 public func showApprovalForHarness() {
 let request = AgentApprovalRequest(
 toolID: "t1",
 toolTitle: "执行终端命令",
 summary: "rm -rf /var/log/old",
 reason: "命中平台安全规则：rm -rf /",
 isDangerous: true
 )
 showApproval(request)
 }
 private func makeHeaderButton(_ button: NSButton = NSButton(), symbol: String, tooltip: String, action: Selector) -> NSButton {
 button.translatesAutoresizingMaskIntoConstraints = false
 button.isBordered = false
 button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
 button.imagePosition = .imageOnly
 button.contentTintColor = AgentTheme.Color.textSecondary
 button.toolTip = tooltip
 button.target = self
 button.action = action
 button.widthAnchor.constraint(equalToConstant:24).isActive = true
 button.heightAnchor.constraint(equalToConstant:24).isActive = true
 return button
 }

 private func apply(_ change: AgentSession.Change) {
 switch change {
 case .conversationList:
 rail.reload(conversations: session.conversations, activeID: session.active.id)
 titleLabel.stringValue = session.active.displayTitle
 case .transcript:
 reloadTranscript()
 case .streaming(let itemID):
 if streamingItemID != itemID {
 pendingStreamingRefresh?.cancel()
 pendingStreamingRefresh = nil
 streamingItemID = itemID
 refreshStreamingItem(itemID)
 } else if pendingStreamingRefresh == nil {
 pendingStreamingRefresh = Task { [weak self] in
 try? await Task.sleep(nanoseconds: 33_000_000)
 guard !Task.isCancelled, let self else { return }
 self.pendingStreamingRefresh = nil
 self.refreshStreamingItem(itemID)
 }
 }
 case .composer:
 refreshTerminalScope()
 composer.apply(text: session.active.draftText, chips: session.active.draftChips)
 composer.apply(model: session.active.modelSelection, permission: session.active.permissionMode, preferences: session.permissionPreferences)
 composer.applyRunning(session.isRunning)
 composer.applyEnhancement(session.enhancementState)
 notifyAttention()
 case .phase:
 // A settled turn uses current settings instead of its frozen permission snapshot.
 if !session.isRunning {
 composer.apply(model: session.active.modelSelection, permission: session.active.permissionMode, preferences: session.permissionPreferences)
 }
 composer.applyRunning(session.isRunning)
 refreshActivity()
 case .approval:
 showApproval(session.pendingApproval)
 composer.applyApprovalPending(session.pendingApproval != nil)
 }
 }

 private func refreshStreamingItem(_ itemID: String) {
 if let item = session.active.items.last, item.id == itemID {
 transcript.updateStreaming(item: item)
 }
 }

 private func reloadTranscript() {
 pendingStreamingRefresh?.cancel()
 pendingStreamingRefresh = nil
 streamingItemID = nil
 refreshTerminalScope()
 transcript.reload(items: session.active.items, completed: session.active.phase == .completed, turnActive: session.isRunning)
 showApproval(session.pendingApproval)
 }

 private func showApproval(_ request: AgentApprovalRequest?) {
     guard approvalView?.request != request else { return }
     defer { refreshActivity() }
     if let approvalView {
         approvalDock.removeArrangedSubview(approvalView)
         approvalView.removeFromSuperview()
     }
     approvalView = nil
     guard let request else { return }
     let card = AgentApprovalView(request: request)
     card.translatesAutoresizingMaskIntoConstraints = false
     card.onApprove = { [weak self] grant in self?.session.approvePending(grant) }
     card.onReject = { [weak self] in self?.session.rejectPending() }
     approvalDock.addArrangedSubview(card)
     card.widthAnchor.constraint(equalTo: approvalDock.widthAnchor).isActive = true
     approvalView = card
 }

 private func refreshActivity() {
 let phase = session.active.phase
 let showsActivity = approvalView == nil && phase.isActive && phase != .toolExecuting && phase != .waitingApproval
 activityLabel.stringValue = showsActivity ? phase.caption : ""
 activityLabel.isHidden = !showsActivity
 activityHeight?.constant = showsActivity ? 18 : 0
 }

 private func refreshAll() {
 refreshActivity()
 rail.reload(conversations: session.conversations, activeID: session.active.id)
 titleLabel.stringValue = session.active.displayTitle
 reloadTranscript()
 composer.apply(text: session.active.draftText, chips: session.active.draftChips)
 composer.apply(model: session.active.modelSelection, permission: session.active.permissionMode, preferences: session.permissionPreferences)
 composer.applyRunning(session.isRunning)
 composer.applyApprovalPending(session.pendingApproval != nil)
 composer.applyEnhancement(session.enhancementState)
 }

 @objc private func newConversation() {
 session.startNewConversation()
 historyPopover.close()
 composer.focusInput()
 }

 @objc private func openSettings() {
 onRequestSettings?()
 }



 @objc private func toggleHistory() {
 if historyPopover.isShown {
 historyPopover.close()
 } else {
 historyPopover.show(relativeTo: historyButton.bounds, of: historyButton, preferredEdge: .maxY)
 }
 }

 private func refreshTerminalScope() {
 let terminalTitle = session.activeTerminalTitle
 composer.applyTerminalTitle(terminalTitle)
 emptyState.isHidden = !session.active.items.isEmpty
 emptyState.stringValue = terminalTitle == nil
 ? "提问即可开始。需要运行命令时，请先打开一个终端。"
 : "输入你要在这个终端排查的问题。"
 }

 private func presentModelMenu(anchor: NSView) {
 session.refreshModels()
 session.discoverSelectedModelIfNeeded()
 let menu = NSMenu()
 if session.availableModels.isEmpty {
 let empty = NSMenuItem(title: "尚未配置模型", action: nil, keyEquivalent: "")
 empty.isEnabled = false
 menu.addItem(empty)
 }
 for model in session.availableModels {
 let item = NSMenuItem(title: model.menuLabel, action: #selector(selectModel(_:)), keyEquivalent: "")
 item.target = self
 item.representedObject = model
 let title = NSMutableAttributedString()
 if let icon = model.pickerIcon() {
 let attachment = NSTextAttachment()
 attachment.image = icon
 attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
 title.append(NSAttributedString(attachment: attachment))
 title.append(NSAttributedString(string: "  "))
 }
 title.append(NSAttributedString(string: model.menuLabel))
 if let current = session.active.modelSelection,
 current.providerID == model.providerID, current.modelID == model.modelID {
 item.state = .on
 }
 item.attributedTitle = title
 menu.addItem(item)
 }
 menu.addItem(.separator())
 if let current = session.active.modelSelection,
 let capability = session.availableModels.first(where: { $0.providerID == current.providerID && $0.modelID == current.modelID }) {
 menu.addItem(withTitle: capability.supportsImages.map { $0 ? "支持图片输入" : "仅文本输入" } ?? "图片能力未确认", action: nil, keyEquivalent: "")
 let efforts = capability.supportedEfforts ?? []
 let strength = NSMenuItem(title: "思考强度", action: nil, keyEquivalent: "")
 let options = NSMenu()
 for effort in [nil] + efforts.map(Optional.some) {
 var selection = capability
 selection.reasoningEffort = effort
 let labels = ["minimal": "最低", "low": "低", "medium": "中", "high": "高"]
 let option = NSMenuItem(title: effort.map { labels[$0] ?? $0 } ?? "模型默认", action: #selector(selectModel(_:)), keyEquivalent: "")
 option.target = self
 option.representedObject = selection
 option.state = current.reasoningEffort == effort ? .on : .off
 options.addItem(option)
 }
 if efforts.isEmpty {
 let note = capability.supportsThinking == false ? "供应商标注此模型不支持推理" : "供应商未确认可调档位"
 options.addItem(withTitle: note, action: nil, keyEquivalent: "")
 }
 strength.submenu = options
 menu.addItem(strength)
 menu.addItem(.separator())
 }
 let settings = NSMenuItem(title: "添加模型", action: #selector(openSettings), keyEquivalent: "")
 settings.target = self
 menu.addItem(settings)
 menu.popUp(positioning: nil, at: NSPoint(x:0, y: anchor.bounds.height + 4), in: anchor)
 }

 @objc private func selectModel(_ sender: NSMenuItem) {
 guard let model = sender.representedObject as? AgentModelSelection else { return }
 session.setModel(model)
 session.discoverSelectedModelIfNeeded()
 }

 private func presentPermissionMenu(anchor: NSView) {
 let menu = makePermissionMenu(preferences: session.permissionPreferences)
 menu.popUp(positioning: nil, at: NSPoint(x:0, y: anchor.bounds.height + 4), in: anchor)
 }

 func makePermissionMenu(preferences: AppSettings) -> NSMenu {
 let menu = NSMenu()
 let heading = NSMenuItem(title: "当前对话权限", action: nil, keyEquivalent: "")
 heading.isEnabled = false
 menu.addItem(heading)
 for mode in AgentPermissionMode.allCases {
 let item = NSMenuItem(title: mode.label, action: #selector(selectPermission(_:)), keyEquivalent: "")
 item.target = self
 item.representedObject = mode.rawValue
 if session.active.permissionMode == mode {
 item.state = .on
 }
 item.toolTip = mode.shortDescription
 item.image = mode.permissionIcon(tint: mode.isDangerous ? .systemRed : nil)
 menu.addItem(item)
 }
 menu.addItem(.separator())
 let globalPolicy = NSMenuItem(title: "全局审批策略：\(preferences.agentConfirmationPolicy.displayName)", action: nil, keyEquivalent: "")
 globalPolicy.isEnabled = false
 menu.addItem(globalPolicy)
 let constraint = NSMenuItem(title: AgentPermissionPolicy.globalConstraintDescription(preferences: preferences), action: nil, keyEquivalent: "")
 constraint.isEnabled = false
 menu.addItem(constraint)
 let settings = NSMenuItem(title: L10n.Settings.openAIExecutionPermissions, action: #selector(openPermissionSettings), keyEquivalent: "")
 settings.target = self
 menu.addItem(settings)
 return menu
 }

 @objc private func openPermissionSettings() {
 onRequestPermissionSettings?()
 }

 @objc private func selectPermission(_ sender: NSMenuItem) {
 guard let raw = sender.representedObject as? String else { return }
 guard let mode = AgentPermissionMode(rawValue: raw), mode != session.active.permissionMode, !session.isRunning else { return }
 guard mode == .dangerFullAccess else {
 session.setPermissionMode(mode)
 return
 }
 guard let window = view.window, window.attachedSheet == nil else { return }
 let conversationID = session.active.id
 let sheet = AgentFullAccessSheet()
 window.beginSheet(sheet) { [weak self] response in
 guard response == .OK, let self, self.session.active.id == conversationID else { return }
 self.session.setPermissionMode(mode)
 }
 }

 private func presentContextMenu(anchor: NSView) {
 let menu = NSMenu()
 session.refreshTerminals()
 let terminals = session.terminals
 if terminals.isEmpty == false {
 let headerItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
 headerItem.isEnabled = false
 menu.addItem(headerItem)
 for terminal in terminals.prefix(10) {
 var title = terminal.title
 if terminal.isCurrent {
 title = terminal.title + "（当前）"
 }
 let item = NSMenuItem(title: title, action: #selector(attachTerminal(_:)), keyEquivalent: "")
 item.target = self
 item.representedObject = terminal.runtimeID
 item.toolTip = terminal.currentDirectory
 menu.addItem(item)
 }
 menu.addItem(.separator())
 }
 for chip in session.active.draftChips where chip.imageNumber != nil {
 let mention = NSMenuItem(title: "@" + chip.label, action: #selector(mentionImage(_:)), keyEquivalent: "")
 mention.target = self; mention.representedObject = chip.label; menu.addItem(mention)
 }
 let images = NSMenuItem(title: "添加图片…", action: #selector(pickImages), keyEquivalent: "")
 images.target = self; menu.addItem(images)
 let pick = NSMenuItem(title: "选择本地文件…", action: #selector(pickLocalFile), keyEquivalent: "")
 pick.target = self
 menu.addItem(pick)
 let note = NSMenuItem(title: "也可以直接粘贴文件路径作为上下文", action: #selector(attachPastedPath), keyEquivalent: "")
 note.target = self
 menu.addItem(note)
 menu.popUp(positioning: nil, at: NSPoint(x:0, y: anchor.bounds.height + 4), in: anchor)
 }

 @objc private func attachTerminal(_ sender: NSMenuItem) {
 guard let runtimeID = sender.representedObject as? String else { return }
 session.refreshTerminals()
 guard let terminal = session.terminals.first(where: { $0.runtimeID == runtimeID }) else { return }
 // Each terminal owns a conversation, so picking one switches the chat to that
 // terminal instead of only attaching a reference to the current chat.
 session.selectTerminal(runtimeID: runtimeID)
 _ = terminal
 }


 @objc private func mentionImage(_ sender: NSMenuItem) {
 if let label = sender.representedObject as? String { composer.mentionImage(label) }
 }
 @objc private func pickImages() {
 let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
 guard panel.runModal() == .OK else { return }
 for url in panel.urls {
 do { session.attachImage(try Data(contentsOf: url, options: .mappedIfSafe)) }
 catch { session.onAttachmentError?("无法读取所选图片。"); return }
 }
 }
 @objc private func pickLocalFile() {
 let panel = NSOpenPanel()
 panel.canChooseDirectories = true
 panel.canChooseFiles = true
 panel.allowsMultipleSelection = false
 guard panel.runModal() == .OK, let url = panel.url else { return }
 let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
 let chip = AgentContextChip(
 kind: isDirectory ? .folder : .file,
 label: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
 detail: nil,
 uri: url.absoluteString)
 session.addContextChip(chip)
 }

 @objc private func attachPastedPath() {
 guard let value = NSPasteboard.general.string(forType: .string) else { return }
 let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
 if trimmed.isEmpty { return }
 let isDirectory = trimmed.hasSuffix("/")
 let name = (trimmed as NSString).lastPathComponent
 var label = name
 if label.isEmpty {
 label = trimmed
 }
 let kind: AgentContextKind = isDirectory ? .folder : .file
 let chip = AgentContextChip(kind: kind, label: label, detail: nil, uri: "file://" + trimmed)
 session.addContextChip(chip)
 }

 /// Reports a short marker when the assistant is blocked on the user.
 private func notifyAttention() {
 let marker: String?
 if session.pendingApproval != nil {
 marker = "待确认"
 } else if session.isRunning == false,
 session.active.items.last?.aborted == true {
 marker = "已停止"
 } else {
 marker = nil
 }
 onAttentionChanged?(marker)
 }
}
