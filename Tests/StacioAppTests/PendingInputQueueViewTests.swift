import XCTest
import AppKit
import Foundation
@testable import StacioApp

/// P5-4：PendingInputQueueView（可编辑队列：编辑/删除/拖动排序/设为下一条/拉回/重新绑定/自动衔接）。
final class PendingInputQueueViewTests: XCTestCase {

    // MARK: - 队列操作

    func testReorderDrag() {
        XCTAssertEqual(
            PendingInputQueueAction.reorder(items: ["a", "b", "c"], fromIndex: 0, toIndex: 2),
            ["b", "c", "a"]
        )
        XCTAssertEqual(
            PendingInputQueueAction.reorder(items: ["a", "b", "c"], fromIndex: 2, toIndex: 0),
            ["c", "a", "b"]
        )
        // 非法索引不改
        XCTAssertEqual(
            PendingInputQueueAction.reorder(items: ["a", "b"], fromIndex: 0, toIndex: 5),
            ["a", "b"]
        )
    }

    func testDeleteAndSetNextUp() {
        XCTAssertEqual(
            PendingInputQueueAction.delete(items: ["a", "b", "c"], itemID: "b"),
            ["a", "c"]
        )
        XCTAssertEqual(
            PendingInputQueueAction.setNextUp(items: ["a", "b", "c"], itemID: "c"),
            ["c", "a", "b"],
            "设为下一条"
        )
        XCTAssertEqual(
            PendingInputQueueAction.setNextUp(items: ["a", "b"], itemID: "missing"),
            ["a", "b"]
        )
    }

    func testPullBackToComposer() {
        let (queue, pulled) = PendingInputQueueAction.pullBackToComposer(
            items: ["a", "b", "c"], itemID: "b"
        )
        XCTAssertEqual(queue, ["a", "c"])
        XCTAssertEqual(pulled, "b", "拉回 Composer 返回原文")
        let (unchanged, missing) = PendingInputQueueAction.pullBackToComposer(
            items: ["a"], itemID: "ghost"
        )
        XCTAssertEqual(unchanged, ["a"])
        XCTAssertNil(missing)
    }

    // MARK: - 编辑正文 vs 重新绑定

    func testEditTextDoesNotChangeContextSnapshotRevision() {
        let item = PendingQueueItemViewState(itemID: "q-1", text: "原消息", contextSnapshotRevision: 3)
        let edited = PendingInputQueueAction.editText(item: item, newText: "改后的正文")
        XCTAssertEqual(edited.text, "改后的正文")
        XCTAssertEqual(edited.contextSnapshotRevision, 3, "编辑正文不改变上下文快照")
        XCTAssertEqual(edited.itemID, "q-1")
    }

    func testRebindContextGeneratesNewRevision() {
        let item = PendingQueueItemViewState(
            itemID: "q-1", text: "消息", contextSnapshotRevision: 3, needsRebind: true, contextDiff: "terminalOutput 变化"
        )
        let rebound = PendingInputQueueAction.rebindContext(item: item, choice: .bindToCurrentSessionContext)
        XCTAssertEqual(rebound.contextSnapshotRevision, 4, "修改上下文必须单独「重新绑定」并生成新 revision")
        XCTAssertFalse(rebound.needsRebind, "重新绑定后清除 needsRebind")
        XCTAssertEqual(rebound.contextDiff, "", "重新绑定后清除差异")
        // 按原上下文发送也生成新 revision（显式决策）
        let original = PendingInputQueueAction.rebindContext(item: item, choice: .sendWithOriginalContext)
        XCTAssertEqual(original.contextSnapshotRevision, 4)
    }

    // MARK: - needsRebind 二选一

    func testNeedsRebindDecisionShowsDiffAndTwoChoices() {
        let decision = PendingInputQueueAction.rebindDecision(diff: "附加了新的终端输出")
        XCTAssertEqual(decision.diff, "附加了新的终端输出", "needsRebind 显示差异")
        XCTAssertEqual(decision.choices, [.sendWithOriginalContext, .bindToCurrentSessionContext],
                       "「按原上下文发送 / 绑定到当前会话上下文」二选一")
    }

    @MainActor
    func testNeedsRebindRowExposesBothRealActionsAndReason() throws {
        let view = PendingInputQueueView()
        let item = makeQueuedInput(revalidationState: .needsRebind)
        view.rebindSummaryProvider = { _ in "原目标已关闭；供应商已变化" }
        var selectedChoice: QueueRebindChoice?
        view.onRebind = { _, choice in selectedChoice = choice }
        view.apply(items: [item], autoAdvancePaused: true)

        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test")))
        let row = try XCTUnwrap(view.tableView(table, viewFor: nil, row: 0))
        let button = try XCTUnwrap(
            descendant(of: row, accessibilityLabel: "重新绑定队列上下文") as? NSButton
        )

        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.toolTip, "原目标已关闭；供应商已变化")
        XCTAssertEqual(
            button.menu?.items.map(\.title),
            ["按原上下文发送", "绑定到当前会话上下文"]
        )
        button.menu?.performActionForItem(at: 1)
        XCTAssertEqual(selectedChoice, .bindToCurrentSessionContext)
    }

    @MainActor
    func testForcedDurableRefreshRollsBackUncommittedCellEdit() throws {
        let view = PendingInputQueueView(frame: NSRect(x: 0, y: 0, width: 560, height: 190))
        let item = makeQueuedInput(revalidationState: .valid)
        var submittedText: String?
        view.onEdit = { _, text in submittedText = text }
        view.apply(items: [item], autoAdvancePaused: false)
        view.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(descendant(of: view, type: NSTableView.self))
        let initialCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let editor = try XCTUnwrap(
            descendant(
                of: initialCell,
                accessibilityIdentifier: "Stacio.AI.pendingQueue.text"
            ) as? NSTextField
        )
        editor.stringValue = "尚未落盘的编辑"
        editor.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: editor)
        )
        XCTAssertEqual(submittedText, "尚未落盘的编辑")

        // An equal durable projection normally preserves the editor so a
        // routine state publish cannot interrupt in-progress text.
        view.apply(items: [item], autoAdvancePaused: false)
        XCTAssertEqual(editor.stringValue, "尚未落盘的编辑")

        // A rejected mutation explicitly discards optimistic UI state.
        view.apply(items: [item], autoAdvancePaused: false, forceRefresh: true)
        let refreshedCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let refreshedEditor = try XCTUnwrap(
            descendant(
                of: refreshedCell,
                accessibilityIdentifier: "Stacio.AI.pendingQueue.text"
            ) as? NSTextField
        )
        XCTAssertEqual(refreshedEditor.stringValue, item.text)
    }

    @MainActor
    func testCompactPresentationKeepsSummaryHeightAndRestoresEditableRows() {
        let view = PendingInputQueueView()
        let items = (0..<3).map { index in
            makeQueuedInput(
                id: "queued-\(index)",
                position: index,
                revalidationState: .valid
            )
        }
        view.apply(items: items, autoAdvancePaused: false)
        XCTAssertEqual(view.intrinsicContentSize.height, 178)

        view.setCompactPresentation(true)
        XCTAssertTrue(view.isCompactPresentation)
        XCTAssertEqual(view.intrinsicContentSize.height, 34)

        view.setCompactPresentation(false)
        XCTAssertFalse(view.isCompactPresentation)
        XCTAssertEqual(view.intrinsicContentSize.height, 178)
    }

    // MARK: - 自动衔接与跨重启

    func testAutoAdvancePausePersistsAcrossRestart() {
        XCTAssertTrue(PendingInputQueueAction.autoAdvancePaused(), "队列摘要始终提供「暂停/继续自动衔接」")
        XCTAssertEqual(
            PendingInputQueueAction.autoAdvancePersistenceKey(),
            "pendingInputQueue.autoAdvancePaused",
            "暂停状态跨重启保存"
        )
    }

    // MARK: - 排序不改全局 FIFO

    func testReorderOnlyAffectsSessionInput() {
        XCTAssertTrue(PendingInputQueueAction.reorderAffectsOnlySessionInput(),
                      "排序只影响本会话输入不改变全局 Admission FIFO")
    }
}

private func makeQueuedInput(
    id: String = "queued-1",
    position: Int = 0,
    revalidationState: QueuedInputRevalidationState
) -> QueuedInput {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let target = TargetBinding(
        id: "target-1",
        revision: 1,
        digest: "target-digest",
        connectionID: "local",
        connectionKind: "local",
        remoteIdentity: "本机",
        hostKeyFingerprint: nil,
        host: "localhost",
        user: "user",
        port: 0,
        targetWorkingDirectory: "/tmp"
    )
    let authentication = RuntimeAuthenticationSnapshot(
        mode: .noneVerified,
        verificationFingerprint: "verification",
        createdAt: now,
        digest: "auth-digest"
    )
    let snapshot = QueuedInputContextSnapshot(
        targetBindingSnapshot: target,
        targetWorkingDirectory: target.targetWorkingDirectory,
        targetDigest: target.digest,
        runtimeSelectionSnapshot: AgentRuntimeSelection(kind: .nativeAPI, modelID: "model"),
        modelID: "model",
        runtimeAuthenticationSnapshot: authentication,
        authenticationDigest: authentication.digest,
        configurationRevisionDigest: "configuration-digest",
        workMode: .agent,
        terminalMode: TurnExecutionChoice.realTerminal.rawValue,
        capturedAt: now,
        source: .sessionDefault
    )
    return QueuedInput(
        id: id,
        sessionID: "session-1",
        revision: 1,
        position: position,
        text: "继续排查",
        contextSnapshot: snapshot,
        revalidationState: revalidationState,
        createdAt: now,
        updatedAt: now
    )
}

@MainActor
private func descendant(of root: NSView, accessibilityLabel: String) -> NSView? {
    if root.accessibilityLabel() == accessibilityLabel { return root }
    for child in root.subviews {
        if let match = descendant(of: child, accessibilityLabel: accessibilityLabel) {
            return match
        }
    }
    return nil
}

@MainActor
private func descendant(of root: NSView, accessibilityIdentifier: String) -> NSView? {
    if root.accessibilityIdentifier() == accessibilityIdentifier { return root }
    for child in root.subviews {
        if let match = descendant(of: child, accessibilityIdentifier: accessibilityIdentifier) {
            return match
        }
    }
    return nil
}

@MainActor
private func descendant<View: NSView>(of root: NSView, type: View.Type) -> View? {
    if let match = root as? View { return match }
    for child in root.subviews {
        if let match = descendant(of: child, type: type) { return match }
    }
    return nil
}
