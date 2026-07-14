import StacioCoreBindings
import XCTest
@testable import StacioApp

final class AIAssistantConversationHistoryStoreTests: XCTestCase {
    func testCoreBridgeConversationHistoryStorePersistsTrimsAndClearsLocalHistory() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAIConversationHistoryStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = CoreBridgeAIAssistantConversationHistoryStore(databasePath: databaseURL.path)

        let user = try store.appendConversationHistoryItem(
            runtimeID: "runtime-a",
            role: .user,
            content: "看一下磁盘",
            requestID: nil
        )
        let assistant = try store.appendConversationHistoryItem(
            runtimeID: "runtime-a",
            role: .assistant,
            content: "建议先运行 df -h。",
            requestID: "req-1"
        )
        _ = try store.appendConversationHistoryItem(
            runtimeID: "runtime-b",
            role: .user,
            content: "另一个会话",
            requestID: nil
        )

        XCTAssertEqual(try store.listConversationHistory(runtimeID: "runtime-a"), [user, assistant])
        XCTAssertEqual(assistant.requestId, "req-1")

        let oversized = String(repeating: "密", count: 900)
        for index in 0..<35 {
            _ = try store.appendConversationHistoryItem(
                runtimeID: "runtime-trim",
                role: .assistant,
                content: index == 34 ? oversized : "message-\(index)",
                requestID: "req-\(index)"
            )
        }
        let trimmed = try store.listConversationHistory(runtimeID: "runtime-trim")
        XCTAssertEqual(trimmed.count, 30)
        XCTAssertEqual(trimmed.first?.content, "message-5")
        XCTAssertEqual(trimmed.last?.requestId, "req-34")
        XCTAssertLessThan(trimmed.last?.content.count ?? 0, oversized.count)

        try store.clearConversationHistory()

        XCTAssertTrue(try store.listConversationHistory(runtimeID: "runtime-a").isEmpty)
        XCTAssertTrue(try store.listConversationHistory(runtimeID: "runtime-trim").isEmpty)
    }

    func testCoreBridgeConversationHistoryStoreListsSearchesAndDeletesConversationSummaries() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAIConversationHistoryStoreBrowserTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = CoreBridgeAIAssistantConversationHistoryStore(databasePath: databaseURL.path)

        _ = try store.appendConversationHistoryItem(
            runtimeID: "runtime-old",
            role: .user,
            content: "先看一下 CPU 和内存状态，这条消息需要被截断到四十个字符以内用于列表展示，并继续分析服务异常根因",
            requestID: nil
        )
        _ = try store.appendConversationHistoryItem(
            runtimeID: "runtime-old",
            role: .assistant,
            content: "建议运行 top。",
            requestID: "req-old"
        )
        Thread.sleep(forTimeInterval: 0.01)
        _ = try store.appendConversationHistoryItem(
            runtimeID: "runtime-new",
            role: .assistant,
            content: "先补充一条助手回复",
            requestID: "req-new"
        )
        _ = try store.appendConversationHistoryItem(
            runtimeID: "runtime-new",
            role: .user,
            content: "查一下 nginx 错误日志",
            requestID: nil
        )

        let summaries = try store.listConversationSummaries(searchQuery: nil)

        XCTAssertEqual(summaries.map(\.runtimeID), ["runtime-new", "runtime-old"])
        XCTAssertEqual(summaries[0].firstUserMessagePreview, "查一下 nginx 错误日志")
        XCTAssertEqual(summaries[0].messageCount, 2)
        XCTAssertEqual(summaries[1].firstUserMessagePreview.count, 40)
        XCTAssertEqual(summaries[1].messageCount, 2)
        XCTAssertEqual(try store.listConversationSummaries(searchQuery: "   "), summaries)

        let searchResults = try store.listConversationSummaries(searchQuery: "nginx")
        XCTAssertEqual(searchResults.map(\.runtimeID), ["runtime-new"])
        XCTAssertEqual(searchResults[0].matchedSnippet, "查一下 nginx 错误日志")

        try store.deleteConversationHistory(runtimeID: "runtime-new")

        XCTAssertTrue(try store.listConversationHistory(runtimeID: "runtime-new").isEmpty)
        XCTAssertEqual(try store.listConversationSummaries(searchQuery: nil).map(\.runtimeID), ["runtime-old"])
    }
}
