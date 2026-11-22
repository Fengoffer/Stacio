import AppKit

/// The scrolling transcript.
///
/// Rows are real views in a flipped stack inside an NSScrollView. A streaming
/// delta updates only the affected row, never the whole list. Following is
/// sticky: while the user is near the bottom new content keeps the view pinned;
/// scrolling up releases it.
@MainActor
final class AgentTranscriptView: NSView {
 private let scrollView = NSScrollView()
 private let stack = FlippedStackView()
 private var rows: [String: AgentRowView] = [:]
 private var orderedIDs: [String] = []
 private var lastMeasuredWidth: CGFloat = 0
 var appliedTextWidthForTesting: CGFloat? { lastMeasuredWidth > 0 ? lastMeasuredWidth : nil }
 private var isFollowing = true

 var onCopyRequest: ((String) -> Void)?

 override init(frame frameRect: NSRect) {
 super.init(frame: frameRect)
 translatesAutoresizingMaskIntoConstraints = false
 setUp()
 }

 required init?(coder: NSCoder) { return nil }

 private func setUp() {
 scrollView.translatesAutoresizingMaskIntoConstraints = false
 scrollView.hasVerticalScroller = true
 scrollView.hasHorizontalScroller = false
 scrollView.drawsBackground = false
 scrollView.automaticallyAdjustsContentInsets = false
 scrollView.contentInsets = NSEdgeInsets(top: AgentTheme.Metric.contentPaddingVertical, left:0, bottom: AgentTheme.Metric.contentPaddingVertical, right:0)
 scrollView.scrollerStyle = .overlay
 addSubview(scrollView)

 stack.translatesAutoresizingMaskIntoConstraints = false
 stack.orientation = .vertical
 stack.alignment = .leading
 stack.spacing = AgentTheme.Metric.messageGap
 stack.edgeInsets = NSEdgeInsets(top:0, left: AgentTheme.Metric.contentPaddingHorizontal, bottom:0, right: AgentTheme.Metric.contentPaddingHorizontal)
 scrollView.documentView = stack

 NSLayoutConstraint.activate([
 scrollView.topAnchor.constraint(equalTo: topAnchor),
 scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
 scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
 scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
 stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
 ])

 scrollView.contentView.postsBoundsChangedNotifications = true
 NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
 }

 deinit {
 NotificationCenter.default.removeObserver(self)
 }

 /// Content width with a sane fallback: during the first load the scroll view has
 /// not laid out yet, and a0 width would collapse every wrapping label.
 private func resolvedContentWidth() -> CGFloat {
 let available = scrollView.contentSize.width
 if available > 80 { return available }
 let bounds = scrollView.bounds.width
 if bounds > 80 { return bounds }
 return 320
 }

 func reload(items: [AgentItem], completed: Bool = true, turnActive: Bool = false) {
 let identifiers = items.map { $0.id }
 let width = resolvedContentWidth()
 lastMeasuredWidth = width
 let lastUser = items.lastIndex { $0.kind == .user } ?? -1
 func update(_ row: AgentRowView, _ item: AgentItem, index: Int) {
 (row as? AgentAssistantMessageView)?.setReasoningTurnActive(turnActive && index > lastUser)
 row.update(item: item, width: width)
 }
 if identifiers != orderedIDs {
 let keep = Set(identifiers)
 for (id, row) in rows {
 if keep.contains(id) == false {
 row.removeFromSuperview()
 rows.removeValue(forKey: id)
 }
 }
 var arranged: [AgentRowView] = []
 for (index, item) in items.enumerated() {
 var row = rows[item.id]
 if row == nil {
 row = makeRow(for: item)
 rows[item.id] = row
 }
 guard let resolvedRow = row else { continue }
 update(resolvedRow, item, index: index)
 arranged.append(resolvedRow)
 }
 if identifiers.starts(with: orderedIDs) {
 for row in arranged.dropFirst(orderedIDs.count) { stack.addArrangedSubview(row); pinRowWidth(row) }
 } else {
 for view in stack.arrangedSubviews {
 stack.removeArrangedSubview(view)
 view.removeFromSuperview()
 }
 for row in arranged {
 stack.addArrangedSubview(row)
 pinRowWidth(row)
 }
 }
 orderedIDs = identifiers
 } else {
 for (index, item) in items.enumerated() {
 if let row = rows[item.id] { update(row, item, index: index) }
 }
 }
 for (index, item) in items.enumerated() where item.kind == .assistant {
 let ended = index + 1 < items.count ? items[index + 1].kind == .user : completed
 (rows[item.id] as? AgentAssistantMessageView)?.showCompletion(ended && !item.aborted && !item.isStreaming && !item.text.isEmpty)
 }
 if isFollowing {
 scrollToBottom(animated: false)
 }
 }

 func updateStreaming(item: AgentItem) {
 guard let row = rows[item.id] else { return }
 row.update(item: item, width: resolvedContentWidth())
 if isFollowing {
 scrollToBottom(animated: false)
 }
 }

 func scrollToBottom(animated: Bool) {
 let height = stack.fittingSize.height
 let visible = scrollView.contentSize.height
 let target = max(0, height - visible + scrollView.contentInsets.bottom)
 if target <= 0 { return }
 let point = NSPoint(x:0, y: target)
 if animated {
 NSAnimationContext.runAnimationGroup { context in
 context.duration = 0.18
 scrollView.contentView.animator().setBoundsOrigin(point)
 }
 } else {
 scrollView.contentView.setBoundsOrigin(point)
 }
 isFollowing = true
 }

 /// Pins a row to the transcript content width after it joins the stack.
 private func pinRowWidth(_ row: AgentRowView) {
 guard row.superview === stack else { return }
 row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -AgentTheme.Metric.contentPaddingHorizontal * 2).isActive = true
 }

 private func makeRow(for item: AgentItem) -> AgentRowView {
 switch item.kind {
 case .user:
 return AgentUserMessageView(onCopy: { [weak self] text in self?.onCopyRequest?(text) })
 case .tool:
 return AgentToolCardView()
 case .error:
 return AgentErrorRowView()
 case .rejected:
 return AgentRejectedRowView()
 case .assistant:
 return AgentAssistantMessageView(onCopy: { [weak self] text in self?.onCopyRequest?(text) })
 }
 }

 @objc private func boundsChanged() {
 let visible = scrollView.contentView.bounds
 let total = stack.fittingSize.height
 let distance = total - (visible.origin.y + visible.height)
 isFollowing = distance <= 8
 }
}

/// Top-down vertical stack that pins content to the top of the clip view.
final class FlippedStackView: NSStackView {
 override var isFlipped: Bool { return true }

 override func layout() {
 super.layout()
 if let documentView = superview {
 let width = documentView.bounds.width
 if abs(frame.width - width) > 0.5 {
 frame.size.width = width
 }
 }
 }
}
