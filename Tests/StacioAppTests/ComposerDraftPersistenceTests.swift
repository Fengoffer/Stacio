import XCTest
import Foundation
@testable import StacioApp

/// P5-3：Composer 草稿持久化与原子提交（debounce、会话隔离、提交-回滚、队列 CAS、运行中状态）。
final class ComposerDraftPersistenceTests: XCTestCase {

    // MARK: - debounce 与会话隔离

    func testDraftPersistsAfter250msDebounce() {
        XCTAssertEqual(ComposerDraftPersistence.debounceInterval, 0.25, "250ms debounce")
        XCTAssertFalse(ComposerDraftPersistence.shouldPersist(elapsedSinceLastSave: 0.1), "未到 debounce 不落盘")
        XCTAssertTrue(ComposerDraftPersistence.shouldPersist(elapsedSinceLastSave: 0.3))
    }

    func testPerConversationDraftKeysDoNotOverwrite() {
        let keyA = ComposerDraftPersistence.draftKey(conversationID: "conv-1")
        let keyB = ComposerDraftPersistence.draftKey(conversationID: "conv-2")
        XCTAssertNotEqual(keyA, keyB, "每会话独立草稿键")
        XCTAssertEqual(keyA, "composer.draft.conv-1")
        // 切换会话/Runtime/目标不覆盖其他草稿（键按 conversationID 隔离）
        let draftA = ComposerDraft(conversationID: "conv-1", text: "A")
        let draftB = ComposerDraft(conversationID: "conv-2", text: "B")
        XCTAssertNotEqual(draftA, draftB)
        XCTAssertEqual(draftA.conversationID, "conv-1")
        XCTAssertEqual(draftB.conversationID, "conv-2")
    }

    // MARK: - 空白消息

    func testBlankMessageCannotSend() {
        XCTAssertFalse(ComposerDraftPersistence.canSend(text: "   \n  "))
        XCTAssertTrue(ComposerDraftPersistence.canSend(text: "hello"))
    }

    // MARK: - 提交-回滚契约

    func testCommitClearsEditorButRetainsPendingUntilTurnCreated() {
        // 提交动作可立即清空可见编辑区；原文只在 Turn 成功创建后从 pending 删除
        let plan = ComposerDraftPersistence.commitPlan(created: true)
        XCTAssertTrue(plan.clearsVisibleEditor, "提交立即清空可见编辑区")
        XCTAssertFalse(plan.retainsPendingOriginal, "Turn 成功后原文从 pending 删除")
        XCTAssertEqual(plan.outcome, .committed)
    }

    func testFailedCreationRestoresOriginal() {
        let plan = ComposerDraftPersistence.commitPlan(created: false)
        XCTAssertTrue(plan.clearsVisibleEditor)
        XCTAssertTrue(plan.retainsPendingOriginal, "创建失败原文保留在 pending")
        XCTAssertEqual(plan.outcome, .failedAndRestored, "创建失败时原文/附件/上下文选择全部恢复")
    }

    // MARK: - 队列项与 revision CAS

    func testQueueItemCarriesIndependentRevisionAndModes() {
        let item = ComposerQueueItem(
            itemID: "q-1", originalText: "排队消息", attachments: ["a.png"],
            contextSelections: ["terminal"], workMode: .planFirst,
            executionChoice: .backgroundVirtualTerminal, fixedRuntimeID: "rt-1"
        )
        XCTAssertEqual(item.revision, 1, "队列项独立 revision")
        XCTAssertEqual(item.workMode, .planFirst, "工作模式独立")
        XCTAssertEqual(item.executionChoice, .backgroundVirtualTerminal, "终端模式独立")
        XCTAssertEqual(item.fixedRuntimeID, "rt-1", "可选固定 Runtime")
        XCTAssertEqual(item.originalText, "排队消息")
    }

    func testEditUsesRevisionCASNotOverwritingPromotedVersion() {
        let item = ComposerQueueItem(itemID: "q-1", originalText: "v1", revision: 1)
        // expected 1 == current 1 → 可编辑
        XCTAssertTrue(ComposerDraftPersistence.canEditQueueItem(item, expectedRevision: 1, currentRevision: 1))
        // 已提升（current 2）→ 旧 revision 不能覆盖
        XCTAssertFalse(ComposerDraftPersistence.canEditQueueItem(item, expectedRevision: 1, currentRevision: 2),
                       "不能覆盖已提升旧版本")
        // 编辑后 revision 递增
        XCTAssertEqual(ComposerDraftPersistence.bumpedRevision(1), 2)
    }

    // MARK: - 运行中状态

    func testWaitingForCapacityInlineStatus() {
        XCTAssertEqual(
            ComposerDraftPersistence.waitingForCapacityStatus(position: 3, waitedSeconds: 125),
            "第 3 位 · 已等待 02:05 · 取消等待 · 打开 Agent 执行设置"
        )
        XCTAssertTrue(ComposerDraftPersistence.capacityGrantedSwitchesToStartingRuntime(),
                      "获准后立即切换 StartingRuntime")
    }

    func testPausedStatusShowsReasonCheckpointAndResume() {
        let checkpoint = Date(timeIntervalSince1970: 1_700_000_000)
        let status = ComposerDraftPersistence.pausedStatus(reason: "等待审批", checkpointAt: checkpoint)
        XCTAssertTrue(status.contains("已暂停：等待审批"))
        XCTAssertTrue(status.contains("checkpoint"), "显示 checkpoint 时间")
        XCTAssertTrue(status.contains("Resume"), "独立 Resume")
        // 无 checkpoint 时仍显示原因与 Resume
        let noCheckpoint = ComposerDraftPersistence.pausedStatus(reason: "等待用户", checkpointAt: nil)
        XCTAssertTrue(noCheckpoint.contains("已暂停：等待用户"))
        XCTAssertTrue(noCheckpoint.contains("Resume"))
    }
}
