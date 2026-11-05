import AppKit
import Foundation

// MARK: - Conversation Timeline ViewController（P6-2 真实 AppKit 实现）

/// 滚动跟随状态：自动跟随 / 用户向上阅读后解除。
public enum TimelineFollowState: Equatable, Sendable {
    case following
    case pausedByUser
}

public enum ConversationTimelineScroll {

    /// 自动跟随阈值：距底部 ≤64pt 时跟随。
    public static let autoFollowThreshold: CGFloat = 64

    public static func shouldAutoFollow(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= autoFollowThreshold
    }

    /// 用户向上阅读后立即解除跟随。
    public static func userScrollUpBreaksFollow(scrollingUp: Bool, current: TimelineFollowState) -> TimelineFollowState {
        guard current == .following else { return current }
        return scrollingUp ? .pausedByUser : .following
    }

    /// 新内容到达显示「回到最新 · N 条更新」不抢滚动位置。
    public static func backToLatestLabel(newItemCount: Int) -> String {
        "回到最新 · \(newItemCount) 条更新"
    }

    /// 展开 Process/Decision/终端块保持可见锚点（diffable 按 item identity 稳定）。
    public static func anchorStableWhenExpanding() -> Bool { true }

    /// 切换会话恢复各会话独立滚动位置。
    public static func scrollPositionKey(sessionID: String) -> String {
        "timeline.scrollPosition.\(sessionID)"
    }
}

public enum ConversationTimelinePagination {

    /// 历史每页默认 50 Turn。
    public static let defaultPageSize = 50

    public static func pagesNeeded(turnCount: Int, pageSize: Int = defaultPageSize) -> Int {
        max(1, (turnCount + pageSize - 1) / pageSize)
    }

    /// 向上分页：加载更早一页。
    public static func loadedTurnCountAfterLoadOlder(currentLoaded: Int, pageSize: Int = defaultPageSize) -> Int {
        currentLoaded + pageSize
    }
}

public enum ConversationTimelineDataSource {

    /// diffable data source（不再用持续增长 NSStackView 物化整个历史）。
    public static func usesDiffableDataSource() -> Bool { true }

    /// 大终端日志有界缓存/分页/虚拟化。
    public static let terminalLogBoundedCacheBytes = 4 * 1024 * 1024
    /// 单个可见 cell 的硬上限；避免一次 layout 计算数 MB 的 attributed string。
    public static let terminalLogDisplayBytes = 64 * 1024
    public static func terminalLogRequiresBoundedCache(byteCount: Int) -> Bool {
        byteCount > terminalLogBoundedCacheBytes
    }
}

// MARK: - 真实 Timeline ViewController

/// 真实可滚动 AppKit Timeline：`NSCollectionView` + diffable data source，
/// 稳定 ID + 增量更新 + 滚动锚点（距底 ≤64pt 自动跟随；向上阅读解除；新内容显示「回到最新」）。
///
/// 支持 entry 类型：用户消息、助手流式文本、推理摘要、状态/错误行。
/// 流式内容按增量合并刷新（不每个 token 重排整个历史）。
@MainActor
public final class ConversationTimelineViewController: NSViewController {

    /// Timeline 条目的稳定标识（用于 diffable data source）。
    public struct TimelineEntryID: Hashable {
        public let kind: String
        public let occurrence: Int
    }

    private let collectionView = NSCollectionView()
    private let timelineLayout = TimelineCollectionViewLayout()
    private var scrollView: NSScrollView!
    private var dataSource: NSCollectionViewDiffableDataSource<Int, TimelineEntryID>!
    private var backToLatestButton: NSButton!
    private let sessionID: String?
    private let scrollPositionDefaults: UserDefaults

    /// 完整投影与当前物化窗口分离；默认仅物化最近 50 个 Turn。
    private var allRows: [TimelineRow] = []
    private var currentRows: [TimelineRow] = []
    private var rowsByID: [TimelineEntryID: TimelineRow] = [:]
    private var nextOccurrenceByKind: [String: Int] = [:]
    private var loadedTurnLimit = ConversationTimelinePagination.defaultPageSize
    private var followState: TimelineFollowState = .following
    private var pendingNewCount: Int = 0
    private var pendingUpdatedIDs: Set<TimelineEntryID> = []
    private var expandedExecutionIDs: Set<TimelineEntryID> = []
    private var finishedExecutionIDs: Set<TimelineEntryID> = []
    private var isSynchronizingCollectionGeometry = false
    private var suppressScrollObservation = false
    private var lastScrollOriginY: CGFloat = 0
    private var didApplyInitialEntries = false
    private var didAttemptScrollRestoration = false

    public init(
        sessionID: String? = nil,
        scrollPositionDefaults: UserDefaults = .standard
    ) {
        self.sessionID = sessionID
        self.scrollPositionDefaults = scrollPositionDefaults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        // Give standalone presentations a valid initial viewport. Embedded uses
        // Auto Layout and will replace this size when its parent lays out.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        container.setAccessibilityIdentifier("Stacio.AI.timeline")
        view = container
        setupCollectionView()
        setupBackToLatestButton()
    }

    // MARK: - 公开 API

    /// 应用新条目（由 SessionRuntimeBridge 经 onTimelineUpdate 调用）。
    /// 增量 diffable 更新；按 followState 决定滚动行为。
    /// P0-8：使用稳定语义角色 + 同角色 occurrence；内容变化 reload 同一 item，
    /// 不把流式文本本身放进 identity。
    public func apply(entries: [TimelineSourceEntry]) {
        loadViewIfNeeded()
        let previousRowsByID = rowsByID
        let anchor = followState == .pausedByUser ? captureVisibleAnchor() : nil
        allRows = rowsPreservingIdentity(for: entries)
        let currentFinishedExecutionIDs = Set(allRows.compactMap { row -> TimelineEntryID? in
            guard case .executionCard(let presentation) = row.entry,
                  presentation.isFinished
            else { return nil }
            return row.stableID
        })
        expandedExecutionIDs.subtract(currentFinishedExecutionIDs.subtracting(finishedExecutionIDs))
        finishedExecutionIDs = currentFinishedExecutionIDs
        let rows = visibleRowsForCurrentPage()
        let changedIDs = Set(rows.compactMap { row -> TimelineEntryID? in
            guard let previous = previousRowsByID[row.stableID] else { return row.stableID }
            return previous.entry == row.entry ? nil : row.stableID
        })
        currentRows = rows
        rowsByID = Dictionary(rows.map { ($0.stableID, $0) }, uniquingKeysWith: { _, latest in latest })
        applySnapshot(rows: rows, reloading: changedIDs, animating: false)

        let isInitialApply = didApplyInitialEntries == false
        didApplyInitialEntries = true
        if isInitialApply, restoreScrollPositionIfAvailable() {
            pendingUpdatedIDs.removeAll()
            pendingNewCount = 0
            backToLatestButton.isHidden = true
            return
        }
        if let anchor, followState == .pausedByUser {
            restoreVisibleAnchor(anchor)
        }
        updateScrollAfterUpdate(changedIDs: isInitialApply ? [] : changedIDs)
    }

    /// 用户点击「回到最新」。
    @objc private func backToLatest() {
        followState = .following
        scrollToBottom(animated: true)
        pendingNewCount = 0
        pendingUpdatedIDs.removeAll()
        backToLatestButton.isHidden = true
        persistScrollPosition()
    }

    /// 当前条目数（测试可读）。
    public var itemCount: Int { currentRows.count }

    /// 当前跟随状态，供宿主在切换会话/恢复窗口时同步控制。
    public var currentFollowState: TimelineFollowState { followState }

    // Focused test/diagnostic hooks; they do not mutate the timeline domain state.
    var backToLatestTitleForTesting: String { backToLatestButton?.title ?? "" }
    var backToLatestVisibleForTesting: Bool { backToLatestButton?.isHidden == false }
    var visibleScrollOriginYForTesting: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }

    /// 是否仍有未物化的更早 Turn。
    public var hasOlderEntries: Bool {
        loadedTurnLimit < allRows.reduce(into: 0) { count, row in
            if row.isUser { count += 1 }
        }
    }

    /// 手动加载一页更早历史；返回加载后的可见条目数。
    @discardableResult
    public func loadOlderPage() -> Int {
        loadViewIfNeeded()
        guard hasOlderEntries else { return currentRows.count }
        let anchor = captureVisibleAnchor()
        loadedTurnLimit = ConversationTimelinePagination.loadedTurnCountAfterLoadOlder(
            currentLoaded: loadedTurnLimit
        )
        let rows = visibleRowsForCurrentPage()
        let previousRowsByID = rowsByID
        let changedIDs = Set(rows.compactMap { row -> TimelineEntryID? in
            guard let previous = previousRowsByID[row.stableID] else { return row.stableID }
            return previous.entry == row.entry ? nil : row.stableID
        })
        currentRows = rows
        rowsByID = Dictionary(rows.map { ($0.stableID, $0) }, uniquingKeysWith: { _, latest in latest })
        applySnapshot(rows: rows, reloading: changedIDs, animating: false)
        if let anchor {
            restoreVisibleAnchor(anchor)
        }
        persistScrollPosition()
        return rows.count
    }

    /// 当前投影条目的稳定领域身份。流式内容更新时 identity 必须保持不变。
    public func entryID(at index: Int) -> TimelineEntryID? {
        guard currentRows.indices.contains(index) else { return nil }
        return currentRows[index].stableID
    }

    /// P0-8：读取可见 cell 的文本内容（测试必须读取可见文本，不只 itemCount）。
    public func visibleCellText(at index: Int) -> String? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        // 从 collection view 读取已渲染的 item
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = collectionView.item(at: indexPath) as? TimelineCollectionViewItem else { return nil }
        return item.visibleText
    }

    /// 已渲染的富文本。用于验证 Markdown 链接、代码字体和表格属性确实到达可见 cell。
    public func visibleCellAttributedText(at index: Int) -> NSAttributedString? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = collectionView.item(at: indexPath) as? TimelineCollectionViewItem else { return nil }
        return item.visibleAttributedText
    }

    func visibleCellAccessibilityForTesting(
        at index: Int
    ) -> (label: String?, value: String?)? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(
            at: IndexPath(item: index, section: 0)
        ) as? TimelineCollectionViewItem else { return nil }
        return item.visibleAccessibility
    }

    func visibleExecutionCardForTesting(at index: Int) -> ExecutionCardView? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        return (collectionView.item(
            at: IndexPath(item: index, section: 0)
        ) as? TimelineCollectionViewItem)?.visibleExecutionCard
    }

    func visibleFlowingActivityEffectForTesting(at index: Int) -> Bool? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        return (collectionView.item(
            at: IndexPath(item: index, section: 0)
        ) as? TimelineCollectionViewItem)?.flowingActivityEffectEnabled
    }

    /// 已真实物化 cell 的 frame；测试用于证明布局不是仅更新内存数据源。
    public func visibleCellFrame(at index: Int) -> NSRect? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        return collectionView.item(at: IndexPath(item: index, section: 0))?.view.frame
    }

    /// Message content surface inside the full-width timeline row. User
    /// messages use this narrower frame to align to the trailing edge.
    func visibleMessageSurfaceFrameForTesting(at index: Int) -> NSRect? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(
            at: IndexPath(item: index, section: 0)
        ) as? TimelineCollectionViewItem else { return nil }
        return item.messageSurfaceFrame(in: collectionView)
    }

    func visibleMessageSurfaceBorderWidthForTesting(at index: Int) -> CGFloat? {
        guard index >= 0, index < currentRows.count else { return nil }
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        return (collectionView.item(
            at: IndexPath(item: index, section: 0)
        ) as? TimelineCollectionViewItem)?.messageSurfaceBorderWidth
    }

    // MARK: - 装配

    private func setupCollectionView() {
        timelineLayout.itemHeightProvider = { [weak self] indexPath, width in
            guard let self, self.currentRows.indices.contains(indexPath.item) else { return 44 }
            return self.measuredHeight(for: self.currentRows[indexPath.item], width: width)
        }
        collectionView.collectionViewLayout = timelineLayout
        collectionView.isSelectable = false
        collectionView.setAccessibilityRole(.list)
        collectionView.setAccessibilityLabel("会话记录")
        // 注册条目
        collectionView.register(
            TimelineCollectionViewItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("TimelineCollectionViewItem")
        )

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.frame = scrollView.contentView.bounds
        collectionView.autoresizingMask = [.width]
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // diffable data source：身份与内容分离。相同文本可重复，流式内容增长也不会更换 identity。
        // SectionIdentifier = Int（单一 section 0）。
        dataSource = NSCollectionViewDiffableDataSource<Int, TimelineEntryID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, entryID in
            let item = collectionView.makeItem(
                withIdentifier: NSUserInterfaceItemIdentifier("TimelineCollectionViewItem"),
                for: indexPath
            ) as? TimelineCollectionViewItem
            if let row = self?.rowsByID[entryID] {
                item?.configure(
                    with: row,
                    executionExpanded: self?.expandedExecutionIDs.contains(entryID) == true,
                    onOpenTerminal: self?.onOpenTerminal,
                    onCancelExecution: self?.onCancelExecution,
                    onSaveRedactedLog: self?.onSaveRedactedLog,
                    onExecutionExpandedChange: { [weak self] expanded in
                        self?.setExecutionExpanded(expanded, for: entryID)
                    }
                )
            }
            return item
        }

        // 监听滚动以更新 followState
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func setupBackToLatestButton() {
        backToLatestButton = NSButton(title: ConversationTimelineScroll.backToLatestLabel(newItemCount: 0), target: self, action: #selector(backToLatest))
        backToLatestButton.translatesAutoresizingMaskIntoConstraints = false
        backToLatestButton.bezelStyle = .rounded
        backToLatestButton.isHidden = true
        backToLatestButton.font = .systemFont(ofSize: 12, weight: .medium)
        backToLatestButton.toolTip = "滚动到会话末尾"
        backToLatestButton.setAccessibilityLabel("回到最新消息")
        view.addSubview(backToLatestButton)
        NSLayoutConstraint.activate([
            backToLatestButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            backToLatestButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    // MARK: - 滚动

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        let originY = scrollView.contentView.bounds.origin.y
        let scrollingUp = originY < lastScrollOriginY - 0.5
        lastScrollOriginY = originY
        guard suppressScrollObservation == false else { return }

        let distance = distanceFromBottom()
        followState = ConversationTimelineScroll.userScrollUpBreaksFollow(scrollingUp: scrollingUp, current: followState)
        if scrollingUp, originY <= 32, followState == .pausedByUser {
            _ = loadOlderPage()
        }
        // 贴底时清除「回到最新」
        if ConversationTimelineScroll.shouldAutoFollow(distanceFromBottom: distance) {
            followState = .following
            pendingNewCount = 0
            pendingUpdatedIDs.removeAll()
            backToLatestButton.isHidden = true
        }
        persistScrollPosition()
    }

    private func updateScrollAfterUpdate(changedIDs: Set<TimelineEntryID>) {
        if followState == .following {
            scrollToBottom(animated: false)
            pendingNewCount = 0
            pendingUpdatedIDs.removeAll()
            backToLatestButton.isHidden = true
        } else if changedIDs.isEmpty == false {
            // 用户在阅读：不抢滚动位置，显示「回到最新」
            pendingUpdatedIDs.formUnion(changedIDs)
            pendingNewCount = pendingUpdatedIDs.count
            backToLatestButton.title = ConversationTimelineScroll.backToLatestLabel(newItemCount: pendingNewCount)
            backToLatestButton.isHidden = false
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard collectionView.enclosingScrollView != nil else { return }
        _ = animated
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let scrollHeight = scrollView.contentView.bounds.height
        let bottomPoint = NSPoint(x: 0, y: max(0, documentHeight - scrollHeight))
        suppressScrollObservation = true
        scrollView.contentView.scroll(bottomPoint)
        lastScrollOriginY = scrollView.contentView.bounds.origin.y
        suppressScrollObservation = false
    }

    private func distanceFromBottom() -> CGFloat {
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let visibleOrigin = scrollView.contentView.bounds.origin.y
        let visibleHeight = scrollView.contentView.bounds.height
        return max(0, documentHeight - (visibleOrigin + visibleHeight))
    }

    // MARK: - diffable snapshot

    private func applySnapshot(
        rows: [TimelineRow],
        reloading changedIDs: Set<TimelineEntryID>,
        animating: Bool
    ) {
        view.layoutSubtreeIfNeeded()
        synchronizeCollectionGeometry()
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, TimelineEntryID>()
        snapshot.appendSections([0])
        let ids = rows.map(\.stableID)
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reloadItems(ids.filter { previousIDs.contains($0) && changedIDs.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: animating)
        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let anchor = followState == .pausedByUser ? captureVisibleAnchor() : nil
        synchronizeCollectionGeometry()
        if let anchor {
            restoreVisibleAnchor(anchor)
        }
    }

    private struct VisibleAnchor {
        let id: TimelineEntryID
        let offsetFromViewportTop: CGFloat
        let fallbackOriginY: CGFloat
    }

    private func captureVisibleAnchor() -> VisibleAnchor? {
        guard scrollView != nil, currentRows.isEmpty == false else { return nil }
        synchronizeCollectionGeometry()
        let visibleRect = scrollView.contentView.bounds
        for (index, row) in currentRows.enumerated() {
            guard let attributes = timelineLayout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
            ), attributes.frame.maxY >= visibleRect.minY else { continue }
            return VisibleAnchor(
                id: row.stableID,
                offsetFromViewportTop: attributes.frame.minY - visibleRect.minY,
                fallbackOriginY: visibleRect.minY
            )
        }
        return nil
    }

    private func restoreVisibleAnchor(_ anchor: VisibleAnchor) {
        synchronizeCollectionGeometry()
        let proposedOrigin: CGFloat
        if let index = currentRows.firstIndex(where: { $0.stableID == anchor.id }),
           let attributes = timelineLayout.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0)
           ) {
            proposedOrigin = attributes.frame.minY - anchor.offsetFromViewportTop
        } else {
            proposedOrigin = anchor.fallbackOriginY
        }
        let maximumOrigin = max(
            0,
            (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
        )
        suppressScrollObservation = true
        scrollView.contentView.scroll(NSPoint(x: 0, y: min(max(0, proposedOrigin), maximumOrigin)))
        lastScrollOriginY = scrollView.contentView.bounds.origin.y
        suppressScrollObservation = false
    }

    private func visibleRowsForCurrentPage() -> [TimelineRow] {
        let turnStarts = allRows.indices.filter { allRows[$0].isUser }
        guard turnStarts.count > loadedTurnLimit else { return allRows }
        return Array(allRows[turnStarts[turnStarts.count - loadedTurnLimit]...])
    }

    /// Reuse semantic IDs across snapshot updates. A page prepend changes
    /// occurrence numbers for every role when IDs are recomputed from scratch;
    /// prefix/suffix alignment keeps the old visible anchor stable while still
    /// allowing duplicate text and true insertions.
    private func rowsPreservingIdentity(for entries: [TimelineSourceEntry]) -> [TimelineRow] {
        let boundedEntries = entries.map(TimelineRow.bounded)
        let newKeys = boundedEntries.map(TimelineRow.identityKey)
        let oldRows = allRows
        let oldKeys = oldRows.map { TimelineRow.identityKey(for: $0.entry) }
        let newContentKeys = boundedEntries.map {
            "\(TimelineRow.identityKey(for: $0))|\(TimelineRow.displayText(for: $0))"
        }
        let oldContentKeys = oldRows.map {
            "\(TimelineRow.identityKey(for: $0.entry))|\(TimelineRow.displayText(for: $0.entry))"
        }
        var assigned = Array<TimelineEntryID?>(repeating: nil, count: boundedEntries.count)

        let commonLimit = min(oldRows.count, boundedEntries.count)
        var prefix = 0
        while prefix < commonLimit, oldContentKeys[prefix] == newContentKeys[prefix] {
            assigned[prefix] = oldRows[prefix].stableID
            prefix += 1
        }

        var suffix = 0
        while suffix < commonLimit - prefix {
            let oldIndex = oldRows.count - 1 - suffix
            let newIndex = boundedEntries.count - 1 - suffix
            guard oldContentKeys[oldIndex] == newContentKeys[newIndex] else { break }
            assigned[newIndex] = oldRows[oldIndex].stableID
            suffix += 1
        }

        // Same-length updates can first reuse a matching semantic role at the
        // same position. This covers ordinary streaming answer growth.
        if oldRows.count == boundedEntries.count {
            for index in boundedEntries.indices where assigned[index] == nil {
                if oldKeys[index] == newKeys[index] {
                    assigned[index] = oldRows[index].stableID
                }
            }
        }

        // A streaming frame may also insert/remove an unrelated status row.
        // Reuse the remaining old IDs by semantic role and occurrence order so
        // the answer/tool cell does not lose identity merely because the array
        // length changed. Exact prefix/suffix matches above remain authoritative
        // and remove prepended history from these candidate pools.
        var assignedIDs = Set(assigned.compactMap { $0 })
        var availableByKind: [String: [TimelineEntryID]] = [:]
        for oldRow in oldRows where assignedIDs.contains(oldRow.stableID) == false {
            let kind = TimelineRow.identityKey(for: oldRow.entry)
            availableByKind[kind, default: []].append(oldRow.stableID)
        }
        var nextAvailableIndexByKind: [String: Int] = [:]
        for index in boundedEntries.indices where assigned[index] == nil {
            let kind = newKeys[index]
            let candidateIndex = nextAvailableIndexByKind[kind, default: 0]
            guard let candidates = availableByKind[kind],
                  candidates.indices.contains(candidateIndex)
            else { continue }
            let candidate = candidates[candidateIndex]
            assigned[index] = candidate
            assignedIDs.insert(candidate)
            nextAvailableIndexByKind[kind] = candidateIndex + 1
        }

        var used = Set(assigned.compactMap { $0 })
        var result: [TimelineRow] = []
        result.reserveCapacity(boundedEntries.count)
        for (index, entry) in boundedEntries.enumerated() {
            let kind = newKeys[index]
            let stableID: TimelineEntryID
            if let existing = assigned[index] {
                stableID = existing
                used.insert(existing)
                nextOccurrenceByKind[kind] = max(
                    nextOccurrenceByKind[kind] ?? 0,
                    existing.occurrence + 1
                )
            } else {
                var occurrence = nextOccurrenceByKind[kind] ?? 0
                var candidate = TimelineEntryID(kind: kind, occurrence: occurrence)
                while used.contains(candidate) {
                    occurrence += 1
                    candidate = TimelineEntryID(kind: kind, occurrence: occurrence)
                }
                nextOccurrenceByKind[kind] = occurrence + 1
                stableID = candidate
                used.insert(candidate)
            }
            result.append(TimelineRow(stableID: stableID, entry: entry))
        }
        return result
    }

    @discardableResult
    private func restoreScrollPositionIfAvailable() -> Bool {
        guard didAttemptScrollRestoration == false else { return false }
        didAttemptScrollRestoration = true
        guard let sessionID else { return false }
        let key = ConversationTimelineScroll.scrollPositionKey(sessionID: sessionID)
        guard scrollPositionDefaults.object(forKey: key) != nil else { return false }
        synchronizeCollectionGeometry()
        let maximumOrigin = max(
            0,
            (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
        )
        let origin = min(max(0, scrollPositionDefaults.double(forKey: key)), maximumOrigin)
        suppressScrollObservation = true
        scrollView.contentView.scroll(NSPoint(x: 0, y: origin))
        lastScrollOriginY = scrollView.contentView.bounds.origin.y
        suppressScrollObservation = false
        followState = ConversationTimelineScroll.shouldAutoFollow(
            distanceFromBottom: distanceFromBottom()
        ) ? .following : .pausedByUser
        return true
    }

    private func persistScrollPosition() {
        guard let sessionID else { return }
        scrollPositionDefaults.set(
            Double(scrollView.contentView.bounds.origin.y),
            forKey: ConversationTimelineScroll.scrollPositionKey(sessionID: sessionID)
        )
    }

    private func synchronizeCollectionGeometry() {
        guard scrollView != nil,
              isSynchronizingCollectionGeometry == false
        else { return }
        isSynchronizingCollectionGeometry = true
        defer { isSynchronizingCollectionGeometry = false }

        let viewport = scrollView.contentSize
        guard viewport.width > 1, viewport.height > 1 else { return }

        let width = floor(viewport.width)
        let widthChanged = abs(collectionView.frame.width - width) > 0.5
        if widthChanged {
            collectionView.setFrameSize(NSSize(
                width: width,
                height: max(viewport.height, collectionView.frame.height)
            ))
            collectionView.collectionViewLayout?.invalidateLayout()
        }

        collectionView.layoutSubtreeIfNeeded()
        let layoutHeight = timelineLayout.collectionViewContentSize.height
        let height = max(viewport.height, ceil(layoutHeight))
        if abs(collectionView.frame.height - height) > 0.5 {
            collectionView.setFrameSize(NSSize(width: width, height: height))
        }
    }

    private func measuredHeight(for row: TimelineRow, width: CGFloat) -> CGFloat {
        if case .executionCard(let presentation) = row.entry {
            return ExecutionCardView.measuredHeight(
                for: presentation,
                expanded: expandedExecutionIDs.contains(row.stableID),
                width: width
            )
        }
        let surfaceWidth = row.isUser ? width * 0.86 : width
        let textWidth = max(80, surfaceWidth - 20)
        let bounds = row.attributedText.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let roleHeaderAllowance: CGFloat = (row.isUser || {
            if case .finalAnswer = row.entry { return true }
            return false
        }()) ? 27 : 0
        return max(32, ceil(bounds.height) + 12 + roleHeaderAllowance)
    }

    public var onOpenTerminal: ((String) -> Void)?
    public var onCancelExecution: ((String) -> Void)?
    public var onSaveRedactedLog: ((TerminalArtifactPresentation) -> Void)?

    private func setExecutionExpanded(_ expanded: Bool, for id: TimelineEntryID) {
        if expanded {
            expandedExecutionIDs.insert(id)
        } else {
            expandedExecutionIDs.remove(id)
        }
        let anchor = followState == .pausedByUser ? captureVisibleAnchor() : nil
        collectionView.collectionViewLayout?.invalidateLayout()
        synchronizeCollectionGeometry()
        collectionView.layoutSubtreeIfNeeded()
        if let anchor { restoreVisibleAnchor(anchor) }
    }
}

// MARK: - Timeline Collection Layout

/// 确定性的单列布局。避免 FlowLayout 的 estimated-size 与 delegate size 相互覆盖，
/// 并让流式文本增长只失效受影响的纵向 attributes。
@MainActor
private final class TimelineCollectionViewLayout: NSCollectionViewLayout {
    var itemHeightProvider: ((IndexPath, CGFloat) -> CGFloat)?

    private let topInset: CGFloat = 12
    private let sideInset: CGFloat = 16
    private let bottomInset: CGFloat = 12
    private let spacing: CGFloat = 8
    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var cachedContentSize: NSSize = .zero

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            cachedAttributes = [:]
            cachedContentSize = .zero
            return
        }

        let viewportWidth = collectionView.enclosingScrollView?.contentSize.width ?? 0
        let contentWidth = max(collectionView.bounds.width, viewportWidth)
        let itemWidth = max(1, floor(contentWidth - sideInset * 2))
        var y = topInset
        var next: [IndexPath: NSCollectionViewLayoutAttributes] = [:]

        for section in 0..<collectionView.numberOfSections {
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                let height = max(1, itemHeightProvider?(indexPath, itemWidth) ?? 44)
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
                attributes.frame = NSRect(x: sideInset, y: y, width: itemWidth, height: height)
                next[indexPath] = attributes
                y += height + spacing
            }
        }

        if next.isEmpty == false {
            y -= spacing
        }
        y += bottomInset
        cachedAttributes = next
        cachedContentSize = NSSize(width: max(1, contentWidth), height: max(1, y))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cachedAttributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    override var collectionViewContentSize: NSSize {
        cachedContentSize
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return true }
        return abs(collectionView.bounds.width - newBounds.width) > 0.5
    }
}

// MARK: - Timeline 行数据

/// Timeline 单行（领域稳定 ID + 条目内容）。
/// P0-8：stableID 基于语义角色 + occurrence，流式内容不参与 identity。
struct TimelineRow: Hashable {
    let stableID: ConversationTimelineViewController.TimelineEntryID
    let entry: TimelineSourceEntry

    static func identityKey(for entry: TimelineSourceEntry) -> String {
        switch entry {
        case .userMessage: return "userMessage"
        case .finalAnswer: return "finalAnswer"
        case .reasoningSummary: return "reasoningSummary"
        case .planProgress(let text):
            if text.hasPrefix("待发送") { return "planProgress.queue" }
            if text.hasPrefix("正在恢复") { return "planProgress.restore" }
            if text.hasPrefix("正在保存") { return "planProgress.settle" }
            return "planProgress.runtime"
        case .toolCall(let summary, _):
            let operation = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? summary
            return "toolCall.\(stableDigest(operation))"
        case .commandApproval: return "commandApproval"
        case .executionCard(let presentation):
            return "executionCard.\(stableDigest(presentation.proposalID))"
        case .terminalBlock: return "terminalBlock"
        case .userInputRequest: return "userInputRequest"
        case .capacityWait: return "capacityWait"
        case .pauseCheckpoint: return "pauseCheckpoint"
        case .errorRecovery: return "errorRecovery"
        case .childTaskGroup: return "childTaskGroup"
        case .artifact: return "artifact"
        }
    }

    static func bounded(entry: TimelineSourceEntry) -> TimelineSourceEntry {
        guard case .terminalBlock(let text) = entry else { return entry }
        let limit = min(
            ConversationTimelineDataSource.terminalLogBoundedCacheBytes,
            ConversationTimelineDataSource.terminalLogDisplayBytes
        )
        let bytes = Data(text.utf8)
        guard bytes.count > limit else { return entry }
        let marker = "[较早终端输出已省略]\n"
        let suffixLimit = max(0, limit - marker.utf8.count)
        let suffix = String(decoding: bytes.suffix(suffixLimit), as: UTF8.self)
        var bounded = marker + suffix
        if Data(bounded.utf8).count > limit {
            bounded = String(decoding: Data(bounded.utf8).prefix(limit), as: UTF8.self)
        }
        return .terminalBlock(bounded)
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func displayText(for entry: TimelineSourceEntry) -> String {
        switch entry {
        case .userMessage(let s): return s
        case .finalAnswer(let s): return s
        case .reasoningSummary(let s): return s
        case .planProgress(let s): return s
        case .toolCall(let summary, let result):
            return [summary, result].compactMap { value in
                guard let value,
                      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else { return nil }
                return value
            }.joined(separator: "\n\n")
        case .commandApproval(let s): return s
        case .executionCard(let presentation):
            return [
                presentation.target,
                presentation.redactedCommand,
                presentation.status,
                presentation.terminalArtifact?.liveTail
            ].compactMap { $0 }.joined(separator: "\n")
        case .terminalBlock(let s): return s
        case .userInputRequest: return "等待输入"
        case .capacityWait: return "等待容量"
        case .pauseCheckpoint(let s): return s
        case .errorRecovery(let s): return s
        case .childTaskGroup(let s): return s
        case .artifact(let s): return s
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableID)
    }

    static func == (lhs: TimelineRow, rhs: TimelineRow) -> Bool {
        lhs.stableID == rhs.stableID
    }

    var displayText: String { Self.displayText(for: entry) }

    var attributedText: NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 13)
        switch entry {
        case .finalAnswer(let markdown),
             .planProgress(let markdown),
             .pauseCheckpoint(let markdown),
             .childTaskGroup(let markdown),
             .artifact(let markdown):
            return AIAssistantMarkdownRenderer.attributedString(
                from: markdown,
                baseFont: baseFont,
                textColor: StacioDesignSystem.theme.primaryTextColor
            )
        case .reasoningSummary(let markdown):
            return AIAssistantMarkdownRenderer.attributedString(
                from: markdown,
                baseFont: baseFont,
                textColor: StacioDesignSystem.theme.secondaryTextColor
            )
        case .terminalBlock(let text):
            return Self.plainAttributedText(
                text,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                color: StacioDesignSystem.theme.primaryTextColor
            )
        case .toolCall(let summary, let result):
            let output = NSMutableAttributedString(
                attributedString: AIAssistantMarkdownRenderer.attributedString(
                    from: summary,
                    baseFont: baseFont,
                    textColor: StacioDesignSystem.theme.primaryTextColor
                )
            )
            if let result,
               result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                output.append(NSAttributedString(string: "\n\n"))
                output.append(Self.plainAttributedText(
                    result,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    color: StacioDesignSystem.theme.secondaryTextColor
                ))
            }
            return output
        case .commandApproval(let command):
            return Self.plainAttributedText(
                command,
                font: .monospacedSystemFont(ofSize: 12, weight: .medium),
                color: StacioDesignSystem.theme.primaryTextColor
            )
        case .executionCard:
            return Self.plainAttributedText(
                displayText,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                color: StacioDesignSystem.theme.primaryTextColor
            )
        case .errorRecovery(let text):
            return Self.plainAttributedText(text, font: baseFont, color: .systemRed)
        default:
            return Self.plainAttributedText(
                displayText,
                font: baseFont,
                color: StacioDesignSystem.theme.primaryTextColor
            )
        }
    }

    private static func plainAttributedText(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    var isUser: Bool {
        if case .userMessage = entry { return true }
        return false
    }

    var isError: Bool {
        if case .errorRecovery = entry { return true }
        return false
    }

    var isTerminal: Bool {
        if case .terminalBlock = entry { return true }
        if case .executionCard = entry { return true }
        return false
    }

    var isTool: Bool {
        if case .toolCall = entry { return true }
        return false
    }

    var accessibilityRoleLabel: String {
        switch entry {
        case .userMessage: return "用户消息"
        case .finalAnswer: return "排查助手回答"
        case .reasoningSummary: return "推理摘要"
        case .planProgress: return "任务状态"
        case .toolCall: return "工具调用"
        case .commandApproval: return "命令审批"
        case .executionCard: return "终端执行卡片"
        case .terminalBlock: return "终端输出"
        case .userInputRequest: return "等待用户输入"
        case .capacityWait: return "容量等待"
        case .pauseCheckpoint: return "暂停检查点"
        case .errorRecovery: return "错误与恢复"
        case .childTaskGroup: return "子任务"
        case .artifact: return "产物"
        }
    }
}

// MARK: - Timeline CollectionView Item（NSCollectionViewItem）

private final class TimelineCollectionViewItem: NSCollectionViewItem {
    private let textView = FlowingActivityTextField(wrappingLabelWithString: "")
    private let rowView = NSView()
    private let messageSurfaceView = NSView()
    private let roleHeaderStack = NSStackView()
    private let roleIconView = NSImageView()
    private let roleLabel = NSTextField(labelWithString: "")
    private let executionCardView = ExecutionCardView()
    private var surfaceLeadingConstraint: NSLayoutConstraint!
    private var surfaceMinimumLeadingConstraint: NSLayoutConstraint!
    private var surfaceTrailingConstraint: NSLayoutConstraint!
    private var surfaceMaximumWidthConstraint: NSLayoutConstraint!
    private var roleHeaderHeightConstraint: NSLayoutConstraint!
    /// P0-8：暴露可见文本供测试读取。
    var visibleText: String { textView.stringValue }
    var visibleAttributedText: NSAttributedString { textView.attributedStringValue }
    var visibleExecutionCard: ExecutionCardView? {
        executionCardView.isHidden ? nil : executionCardView
    }
    var visibleAccessibility: (label: String?, value: String?) {
        (textView.accessibilityLabel(), textView.accessibilityValue())
    }
    var messageSurfaceBorderWidth: CGFloat { messageSurfaceView.layer?.borderWidth ?? 0 }
    var flowingActivityEffectEnabled: Bool { textView.isFlowingActivityEffectEnabled }

    func messageSurfaceFrame(in ancestor: NSView) -> NSRect {
        messageSurfaceView.convert(messageSurfaceView.bounds, to: ancestor)
    }

    override func loadView() {
        view = rowView
        messageSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(messageSurfaceView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = true
        textView.isBordered = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.maximumNumberOfLines = 0
        textView.cell?.truncatesLastVisibleLine = false
        textView.cell?.wraps = true
        roleHeaderStack.orientation = .horizontal
        roleHeaderStack.alignment = .centerY
        roleHeaderStack.spacing = 5
        roleHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        roleIconView.translatesAutoresizingMaskIntoConstraints = false
        roleIconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        roleIconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        roleLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        roleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        roleLabel.translatesAutoresizingMaskIntoConstraints = false
        roleHeaderStack.addArrangedSubview(roleIconView)
        roleHeaderStack.addArrangedSubview(roleLabel)
        roleHeaderStack.isHidden = true
        messageSurfaceView.addSubview(roleHeaderStack)
        messageSurfaceView.addSubview(textView)
        executionCardView.isHidden = true
        messageSurfaceView.addSubview(executionCardView)
        surfaceLeadingConstraint = messageSurfaceView.leadingAnchor.constraint(equalTo: rowView.leadingAnchor)
        surfaceMinimumLeadingConstraint = messageSurfaceView.leadingAnchor.constraint(
            greaterThanOrEqualTo: rowView.leadingAnchor,
            constant: 40
        )
        surfaceTrailingConstraint = messageSurfaceView.trailingAnchor.constraint(equalTo: rowView.trailingAnchor)
        surfaceMaximumWidthConstraint = messageSurfaceView.widthAnchor.constraint(
            lessThanOrEqualTo: rowView.widthAnchor,
            multiplier: 0.86
        )
        roleHeaderHeightConstraint = roleHeaderStack.heightAnchor.constraint(equalToConstant: 0)
        // P0-8：动态宽度（跟随 collection view 宽度）+ 自适应高度（内容增长自动扩展）
        NSLayoutConstraint.activate([
            messageSurfaceView.topAnchor.constraint(equalTo: rowView.topAnchor),
            messageSurfaceView.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
            surfaceLeadingConstraint,
            surfaceTrailingConstraint,
            roleHeaderStack.topAnchor.constraint(equalTo: messageSurfaceView.topAnchor, constant: 7),
            roleHeaderStack.leadingAnchor.constraint(equalTo: messageSurfaceView.leadingAnchor, constant: 10),
            roleHeaderStack.trailingAnchor.constraint(lessThanOrEqualTo: messageSurfaceView.trailingAnchor, constant: -10),
            roleHeaderHeightConstraint,
            textView.topAnchor.constraint(equalTo: roleHeaderStack.bottomAnchor, constant: 5),
            textView.bottomAnchor.constraint(equalTo: messageSurfaceView.bottomAnchor, constant: -6),
            textView.leadingAnchor.constraint(equalTo: messageSurfaceView.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: messageSurfaceView.trailingAnchor, constant: -10),
            executionCardView.topAnchor.constraint(equalTo: messageSurfaceView.topAnchor),
            executionCardView.bottomAnchor.constraint(equalTo: messageSurfaceView.bottomAnchor),
            executionCardView.leadingAnchor.constraint(equalTo: messageSurfaceView.leadingAnchor),
            executionCardView.trailingAnchor.constraint(equalTo: messageSurfaceView.trailingAnchor)
        ])
    }

    func configure(
        with row: TimelineRow,
        executionExpanded: Bool,
        onOpenTerminal: ((String) -> Void)?,
        onCancelExecution: ((String) -> Void)?,
        onSaveRedactedLog: ((TerminalArtifactPresentation) -> Void)?,
        onExecutionExpandedChange: ((Bool) -> Void)?
    ) {
        if case .executionCard(let presentation) = row.entry {
            roleHeaderStack.isHidden = true
            roleHeaderHeightConstraint.constant = 0
            textView.isHidden = true
            textView.stringValue = row.displayText
            textView.setFlowingActivityEffectEnabled(false)
            executionCardView.isHidden = false
            executionCardView.onOpenTerminal = onOpenTerminal
            executionCardView.onCancel = onCancelExecution
            executionCardView.onSaveRedactedLog = onSaveRedactedLog
            executionCardView.onExpandedChange = onExecutionExpandedChange
            executionCardView.apply(presentation, expanded: executionExpanded)
            applyFullWidthSurface()
            messageSurfaceView.wantsLayer = false
            textView.setAccessibilityLabel(row.accessibilityRoleLabel)
            textView.setAccessibilityValue(row.displayText)
            return
        }
        executionCardView.isHidden = true
        textView.isHidden = false
        let isAssistant = {
            if case .finalAnswer = row.entry { return true }
            return false
        }()
        roleHeaderStack.isHidden = row.isUser == false && isAssistant == false
        roleHeaderHeightConstraint.constant = roleHeaderStack.isHidden ? 0 : 16
        if row.isUser || isAssistant {
            roleIconView.image = NSImage(
                systemSymbolName: row.isUser ? "person.crop.circle.fill" : "sparkles",
                accessibilityDescription: nil
            )
            roleIconView.contentTintColor = row.isUser
                ? StacioDesignSystem.theme.accentColor
                : StacioDesignSystem.theme.successColor
            roleLabel.stringValue = row.isUser ? "你" : "排查助手"
            roleLabel.setAccessibilityIdentifier(
                row.isUser ? "Stacio.AI.timeline.userRole" : "Stacio.AI.timeline.agentRole"
            )
        }
        executionCardView.onOpenTerminal = nil
        executionCardView.onCancel = nil
        executionCardView.onSaveRedactedLog = nil
        executionCardView.onExpandedChange = nil
        textView.alignment = .natural
        // Netcatty/Claude-Code 信息层级：用户消息靠右的轻边框气泡；
        // 助手正文靠左、无卡片背景；工具与终端保持内联的紧凑操作块。
        if row.isUser {
            applyTrailingMessageSurface()
            messageSurfaceView.wantsLayer = true
            messageSurfaceView.layer?.backgroundColor = StacioDesignSystem.theme.controlBackgroundColor
                .withAlphaComponent(0.48).cgColor
            messageSurfaceView.layer?.borderColor = StacioDesignSystem.theme.accentColor
                .withAlphaComponent(0.32).cgColor
            messageSurfaceView.layer?.borderWidth = 1
            messageSurfaceView.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
            messageSurfaceView.layer?.cornerCurve = .continuous
            textView.alignment = .left
        } else if isAssistant {
            applyAssistantMessageSurface()
            textView.alignment = .left
        } else if row.isError {
            applyFullWidthSurface()
            messageSurfaceView.wantsLayer = true
            messageSurfaceView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            messageSurfaceView.layer?.borderWidth = 0
            messageSurfaceView.layer?.cornerRadius = 6
        } else if row.isTerminal || row.isTool {
            applyFullWidthSurface()
            messageSurfaceView.wantsLayer = true
            messageSurfaceView.layer?.backgroundColor = StacioDesignSystem.theme.controlBackgroundColor
                .withAlphaComponent(0.42).cgColor
            messageSurfaceView.layer?.borderColor = StacioDesignSystem.theme.separatorColor
                .withAlphaComponent(0.2).cgColor
            messageSurfaceView.layer?.borderWidth = 1
            messageSurfaceView.layer?.cornerRadius = 6
        } else {
            applyFullWidthSurface()
            messageSurfaceView.wantsLayer = false
            messageSurfaceView.layer?.backgroundColor = NSColor.clear.cgColor
            messageSurfaceView.layer?.borderWidth = 0
            messageSurfaceView.layer?.cornerRadius = 0
        }
        textView.attributedStringValue = row.attributedText
        textView.setFlowingActivityEffectEnabled(
            row.displayText == "执行中…",
            fallbackColor: StacioDesignSystem.theme.primaryTextColor
        )
        textView.setAccessibilityLabel(row.accessibilityRoleLabel)
        textView.setAccessibilityValue(row.displayText)
        // P0-8：内容变化时强制重新计算 intrinsic size（自适应高度）
        textView.invalidateIntrinsicContentSize()
    }

    private func applyFullWidthSurface() {
        surfaceMinimumLeadingConstraint.isActive = false
        surfaceMaximumWidthConstraint.isActive = false
        surfaceLeadingConstraint.isActive = true
        surfaceTrailingConstraint.isActive = true
    }

    private func applyTrailingMessageSurface() {
        surfaceLeadingConstraint.isActive = false
        surfaceMinimumLeadingConstraint.isActive = true
        surfaceMaximumWidthConstraint.isActive = true
        surfaceTrailingConstraint.isActive = true
    }

    private func applyAssistantMessageSurface() {
        surfaceMinimumLeadingConstraint.isActive = false
        surfaceMaximumWidthConstraint.isActive = false
        surfaceLeadingConstraint.isActive = true
        surfaceTrailingConstraint.isActive = true
        messageSurfaceView.wantsLayer = true
        messageSurfaceView.layer?.backgroundColor = StacioDesignSystem.theme.elevatedPanelColor
            .withAlphaComponent(0.38).cgColor
        messageSurfaceView.layer?.borderColor = StacioDesignSystem.theme.separatorColor
            .withAlphaComponent(0.22).cgColor
        messageSurfaceView.layer?.borderWidth = 1
        messageSurfaceView.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        messageSurfaceView.layer?.cornerCurve = .continuous
    }
}
