import XCTest
@testable import StacioApp

/// Canary coverage for the Package-level V2 core lane. This deliberately
/// exercises the isolated core without changing the stable panel assembly.
final class AIV2CorePackageLaneTests: XCTestCase {
    func testPackageLaneBuildsAndExercisesV2Core() {
        let paused = ConversationV2StorageFactory.makeInitialSessionState(
            sessionID: "package-v2-core-paused",
            queueAutoAdvanceEnabled: false
        )
        let enabled = ConversationV2StorageFactory.makeInitialSessionState(
            sessionID: "package-v2-core-enabled",
            queueAutoAdvanceEnabled: true
        )

        XCTAssertEqual(paused.session.queueAutoAdvancePaused, true)
        XCTAssertEqual(enabled.session.queueAutoAdvancePaused, false)
    }

    func testPackageLaneExercisesToolContract() {
        XCTAssertEqual(AIAssistantCoordinator.allowedToolIDs(for: .answerOnly), [])
        XCTAssertEqual(
            AIAssistantCoordinator.allowedToolIDs(for: .agent),
            [StacioBuiltinToolID.terminalCommand]
        )

        let response = AIAssistantResponse(
            message: "检查建议",
            commandProposals: [
                AgentCommandProposal(
                    toolID: "browser.open",
                    schemaRevision: 1,
                    command: "https://example.com",
                    explanation: "不允许的工具"
                ),
                AgentCommandProposal(
                    toolID: StacioBuiltinToolID.terminalCommand,
                    schemaRevision: 1,
                    command: "uptime",
                    explanation: "允许的终端检查"
                )
            ]
        )

        let filtered = AIAssistantCoordinator.responseEnforcingToolContract(
            response,
            allowedToolIDs: [StacioBuiltinToolID.terminalCommand]
        )
        XCTAssertEqual(filtered.commandProposals.map(\.command), ["uptime"])
    }
}
