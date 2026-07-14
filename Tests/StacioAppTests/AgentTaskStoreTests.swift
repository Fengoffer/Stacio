import StacioAgentBridge
import StacioCoreBindings
import XCTest
@testable import StacioApp

final class AgentTaskStoreTests: XCTestCase {
    func testCoreBridgeAgentTaskStoreRecordsAndListsTaskHistory() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAgentTaskStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = CoreBridgeAgentTaskStore(databasePath: databaseURL.path)
        let session = AgentTaskSession(
            id: "task-1",
            targetRuntimeID: "term-1",
            targetTitle: "prod@example.com",
            state: .awaitingUser,
            proposals: [
                AgentCommandProposal(
                    id: "proposal-1",
                    command: "TOKEN=[redacted] docker ps",
                    explanation: "查看容器",
                    risk: .readOnly,
                    state: .proposed
                )
            ]
        )

        let recorded = try store.recordAgentTaskSession(
            session,
            requestID: "req-1",
            userPrompt: "看下容器状态",
            assistantMessage: "建议先查看容器列表。"
        )
        let recent = try store.listAgentTaskSessions(limit: 10)
        let byRequest = try store.listAgentTaskSessions(requestID: "req-1")

        XCTAssertEqual(recorded.requestId, "req-1")
        XCTAssertEqual(recorded.actorKind, "builtInAI")
        XCTAssertEqual(recorded.actorName, "Stacio AI")
        XCTAssertEqual(recorded.proposals.map(\.command), ["TOKEN=[redacted] docker ps"])
        XCTAssertEqual(recent, [recorded])
        XCTAssertEqual(byRequest, [recorded])
        XCTAssertFalse(String(describing: recent).contains("secret-value"))
    }
}
