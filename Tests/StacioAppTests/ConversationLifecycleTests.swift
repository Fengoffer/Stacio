import XCTest
import Foundation
@testable import StacioApp

/// P6-6：Conversation 生命周期（空状态配置入口、归档/删除门禁、Final Answer 分组、回滚）。
final class ConversationLifecycleTests: XCTestCase {

    // MARK: - 归档门禁

    func testArchiveOnlyMovesOutOfDefaultSidebar() {
        XCTAssertTrue(ConversationLifecycleAction.archiveMovesOutOfDefaultSidebarOnly(),
                      "归档只移出默认侧栏")
        XCTAssertTrue(ConversationLifecycleAction.archiveDoesNotStopOrDeleteData(),
                      "不停止/删除数据")
    }

    func testArchiveRequiresStoppedForActiveWaitingPaused() {
        // 活动/等待/暂停必须先完成 Stop 才能归档
        for state in [ConversationActivityState.active, .waitingForCapacity, .paused,
                      .waitingApproval, .waitingUser] {
            XCTAssertFalse(ConversationLifecycleAction.archiveRequiresStopped(state),
                           "\(state) 需先 Stop 才能归档")
        }
        XCTAssertTrue(ConversationLifecycleAction.archiveRequiresStopped(.idle))
    }

    // MARK: - 删除门禁

    func testDeleteRequiresStopOrIsolationForActiveStates() {
        for state in [ConversationActivityState.active, .waitingForCapacity, .paused,
                      .waitingApproval, .waitingUser, .takeoverPending,
                      .orphanedRuntime, .hasUnresolvedExternalEffects] {
            XCTAssertTrue(ConversationLifecycleAction.deleteRequiresStopOrIsolation(state),
                          "\(state) 删除前必须先完成停止/隔离与影响预览")
        }
        XCTAssertFalse(ConversationLifecycleAction.deleteRequiresStopOrIsolation(.idle))
    }

    func testDeleteScopedToConversationOnly() {
        XCTAssertEqual(ConversationLifecycleAction.deleteScopes(), ["conversationEvents", "attachments"])
        XCTAssertTrue(ConversationLifecycleAction.deleteNeverTouchesProviderCredentials())
        XCTAssertTrue(ConversationLifecycleAction.deleteNeverTouchesCodingPlanCredentials())
        XCTAssertTrue(ConversationLifecycleAction.deleteNeverTouchesOfficialCLILogin())
        XCTAssertTrue(ConversationLifecycleAction.deleteNeverTouchesCatalogs())
        XCTAssertTrue(ConversationLifecycleAction.deleteNeverTouchesOtherBranches())
    }

    // MARK: - Final Answer 分组

    func testFinalAnswerFixedSections() {
        XCTAssertEqual(ConversationLifecycleAction.finalAnswerSections(), [
            "结论", "已执行已更改", "验证证据", "风险或未完成", "建议下一步"
        ])
        XCTAssertTrue(ConversationLifecycleAction.hidesEmptySectionsInAnswerOnlyMode(isAnswerOnly: true),
                      "纯回答模式隐藏无内容分组")
        XCTAssertFalse(ConversationLifecycleAction.hidesEmptySectionsInAnswerOnlyMode(isAnswerOnly: false))
    }

    func testRegenerateActionsSeparate() {
        XCTAssertEqual(ConversationLifecycleAction.regenerateActions(), [
            "重新生成回答（仅推理）",
            "重新运行任务（可能再次执行需重新审批）"
        ], "「重新生成回答（仅推理）」与「重新运行任务」并列分开")
    }

    // MARK: - 回滚门禁

    func testRollbackRequiresVerifiedPlanAndMatchingTargetGeneration() {
        XCTAssertTrue(ConversationLifecycleAction.rollbackAvailable(
            hasVerifiedBackupPlan: true, targetMatches: true, generationMatches: true
        ))
        // 缺任一条件都不显示回滚
        XCTAssertFalse(ConversationLifecycleAction.rollbackAvailable(
            hasVerifiedBackupPlan: false, targetMatches: true, generationMatches: true
        ))
        XCTAssertFalse(ConversationLifecycleAction.rollbackAvailable(
            hasVerifiedBackupPlan: true, targetMatches: false, generationMatches: true
        ))
        XCTAssertFalse(ConversationLifecycleAction.rollbackAvailable(
            hasVerifiedBackupPlan: true, targetMatches: true, generationMatches: false
        ), "generation 不匹配不显示回滚")
    }
}
