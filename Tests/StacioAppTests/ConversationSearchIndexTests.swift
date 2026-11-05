import XCTest
import Foundation
@testable import StacioApp

/// P9-1：仅内存搜索（后台按需解密、会话授权范围、磁盘禁明文 FTS、销毁时机、延迟预算）。
final class ConversationSearchIndexTests: XCTestCase {

    private func makeEntry(session: String, id: String, text: String) -> SearchIndexEntry {
        SearchIndexEntry(sessionID: session, recordID: id, text: text)
    }

    // MARK: - 后台按需解密 + 内存临时索引

    func testInMemoryTemporaryIndexAndBackgroundDecrypt() {
        XCTAssertTrue(ConversationSearchIndexAction.buildsInMemoryTemporaryIndexOnly(),
                      "构建进程内临时索引")
        XCTAssertTrue(ConversationSearchIndexAction.decryptsOnDemandInBackground(),
                      "search worker 只在后台按需解密")
    }

    func testPlaintextFTSOnDiskForbidden() {
        XCTAssertTrue(ConversationSearchIndexAction.plaintextFTSOnDiskForbidden(),
                      "磁盘禁止建立含正文/标题/命令/主机信息的明文 FTS")
    }

    // MARK: - 会话授权范围

    func testScopedToAuthorizedSessions() {
        let entries = [
            makeEntry(session: "c-1", id: "r-1", text: "部署命令"),
            makeEntry(session: "c-2", id: "r-2", text: "主机信息"),
            makeEntry(session: "c-3", id: "r-3", text: "正文")
        ]
        let scoped = ConversationSearchIndexAction.scopedToAuthorizedSessions(
            entries: entries, authorizedSessions: Set(["c-1", "c-3"])
        )
        XCTAssertEqual(scoped.map(\.recordID), ["r-1", "r-3"], "会话授权范围过滤")
        XCTAssertFalse(scoped.contains { $0.sessionID == "c-2" })
    }

    // MARK: - 销毁时机

    func testDestroysOnAllInvalidationEvents() {
        XCTAssertTrue(ConversationSearchIndexAction.destroysOnLockScreen())
        XCTAssertTrue(ConversationSearchIndexAction.destroysOnExit())
        XCTAssertTrue(ConversationSearchIndexAction.destroysOnConversationDelete())
        XCTAssertTrue(ConversationSearchIndexAction.destroysOnKeyInvalidation())
        XCTAssertTrue(ConversationSearchIndexAction.destroyedWhenAllV2DataDeleted(),
                      "删除全部 V2 数据时销毁 V2 内存搜索缓存")
    }

    // MARK: - 延迟预算（后置）

    func testFirstBatchLatencyBudget() {
        XCTAssertEqual(ConversationSearchIndexAction.firstBatchLatencyP95, 0.5, "首批结果 p95 ≤ 500ms")
        XCTAssertTrue(ConversationSearchIndexAction.meetsLatencyBudget(elapsed: 0.4))
        XCTAssertFalse(ConversationSearchIndexAction.meetsLatencyBudget(elapsed: 0.6))
    }
}
