import StacioCoreBindings
import XCTest
@testable import StacioApp

final class AIAssistantConversationHistoryListViewControllerTests: XCTestCase {
    func testHistoryListDisplaysSummariesSearchesHighlightsAndRestoresRecords() throws {
        let store = RecordingHistoryBrowserStore()
        store.summariesByQuery[""] = [
            AIConversationHistoryConversationSummary(
                runtimeID: "runtime-new",
                firstUserMessagePreview: "查一下 nginx 错误日志",
                messageCount: 2,
                createdAt: "2026-07-02T10:00:00Z",
                latestMessageAt: "2026-07-02T10:01:00Z",
                matchedSnippet: nil
            ),
            AIConversationHistoryConversationSummary(
                runtimeID: "runtime-old",
                firstUserMessagePreview: "看磁盘",
                messageCount: 1,
                createdAt: "2026-07-01T10:00:00Z",
                latestMessageAt: "2026-07-01T10:00:00Z",
                matchedSnippet: nil
            )
        ]
        store.summariesByQuery["nginx"] = [
            AIConversationHistoryConversationSummary(
                runtimeID: "runtime-new",
                firstUserMessagePreview: "查一下 nginx 错误日志",
                messageCount: 2,
                createdAt: "2026-07-02T10:00:00Z",
                latestMessageAt: "2026-07-02T10:01:00Z",
                matchedSnippet: "nginx error.log 里有 502"
            )
        ]
        store.recordsByRuntimeID["runtime-new"] = [
            makeHistoryRecord(runtimeID: "runtime-new", role: .user, content: "查一下 nginx 错误日志"),
            makeHistoryRecord(runtimeID: "runtime-new", role: .assistant, content: "建议先 tail error.log")
        ]
        let controller = AIAssistantConversationHistoryListViewController(store: store)
        _ = controller.view

        XCTAssertEqual(controller.visibleRuntimeIDsForTesting, ["runtime-new", "runtime-old"])
        XCTAssertTrue(controller.visibleTitleForTesting(at: 0).contains("查一下 nginx 错误日志"))
        XCTAssertTrue(controller.visibleDetailForTesting(at: 0).contains("2 条消息"))

        controller.setSearchQueryForTesting("nginx")

        XCTAssertEqual(controller.visibleRuntimeIDsForTesting, ["runtime-new"])
        XCTAssertEqual(controller.visibleMatchedSnippetForTesting(at: 0), "nginx error.log 里有 502")
        XCTAssertTrue(controller.visibleTitleForTesting(at: 0).contains("查一下 nginx 错误日志"))
        XCTAssertTrue(controller.visibleAttributedTitleForTesting(at: 0).containsAttribute(named: .backgroundColor))
        XCTAssertTrue(controller.visibleAttributedSnippetForTesting(at: 0).containsAttribute(named: .backgroundColor))

        var restoredRuntimeID: String?
        var restoredRecords: [AIConversationHistoryItemRecord] = []
        controller.onRestoreConversation = { runtimeID, records in
            restoredRuntimeID = runtimeID
            restoredRecords = records
        }
        controller.selectConversationForTesting(at: 0)

        XCTAssertEqual(restoredRuntimeID, "runtime-new")
        XCTAssertEqual(restoredRecords.map(\.content), ["查一下 nginx 错误日志", "建议先 tail error.log"])
    }

    func testHistoryListDeletesSingleConversationAndClearsAllAfterConfirmation() throws {
        let store = RecordingHistoryBrowserStore()
        store.summariesByQuery[""] = [
            AIConversationHistoryConversationSummary(
                runtimeID: "runtime-a",
                firstUserMessagePreview: "看负载",
                messageCount: 1,
                createdAt: "2026-07-02T10:00:00Z",
                latestMessageAt: "2026-07-02T10:00:00Z",
                matchedSnippet: nil
            )
        ]
        let controller = AIAssistantConversationHistoryListViewController(store: store)
        controller.confirmDeletion = { summary in
            summary.runtimeID == "runtime-a"
        }
        controller.confirmClearAll = { true }
        _ = controller.view

        controller.deleteConversationForTesting(at: 0)

        XCTAssertEqual(store.deletedRuntimeIDs, ["runtime-a"])

        controller.clearAllHistoryForTesting()

        XCTAssertEqual(store.clearCount, 1)
    }

    private func makeHistoryRecord(
        runtimeID: String,
        role: AIConversationHistoryRole,
        content: String
    ) -> AIConversationHistoryItemRecord {
        AIConversationHistoryItemRecord(
            id: UUID().uuidString,
            runtimeId: runtimeID,
            role: role.rawValue,
            content: content,
            requestId: nil,
            createdAt: "2026-07-02T10:00:00Z"
        )
    }
}

private final class RecordingHistoryBrowserStore: AIAssistantConversationHistoryBrowsing {
    var summariesByQuery: [String: [AIConversationHistoryConversationSummary]] = [:]
    var recordsByRuntimeID: [String: [AIConversationHistoryItemRecord]] = [:]
    private(set) var deletedRuntimeIDs: [String] = []
    private(set) var clearCount = 0

    func listConversationSummaries(searchQuery: String?) throws -> [AIConversationHistoryConversationSummary] {
        summariesByQuery[searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""] ?? []
    }

    func listConversationHistory(runtimeID: String) throws -> [AIConversationHistoryItemRecord] {
        recordsByRuntimeID[runtimeID] ?? []
    }

    func deleteConversationHistory(runtimeID: String) throws {
        deletedRuntimeIDs.append(runtimeID)
    }

    func clearConversationHistory() throws {
        clearCount += 1
    }
}

private extension NSAttributedString {
    func containsAttribute(named name: NSAttributedString.Key) -> Bool {
        var found = false
        enumerateAttribute(name, in: NSRange(location: 0, length: length), options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
