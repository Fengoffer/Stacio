import AppKit
import StacioAgentBridge
import XCTest
@testable import StacioApp

@MainActor
final class AISensitiveTerminalInputTests: XCTestCase {
    func testAIVirtualTerminalUsesSecureFieldAndNeverAddsPasswordToConversation() {
        let runtimeID = "term_ai_sensitive"
        let execution = AISensitiveInputExecution(runtimeID: runtimeID)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: execution
            ),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: runtimeID,
                    title: "production",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            },
            terminalSessionProvider: {
                [AgentTerminalSessionSummary(
                    runtimeID: runtimeID,
                    title: "production",
                    kind: "SSH",
                    environment: "production",
                    isCurrent: true
                )]
            }
        )
        panel.loadView()

        TerminalAgentTraceNotification.post(
            runtimeID: runtimeID,
            title: "production",
            event: AgentTraceEvent(
                requestID: "req-sensitive",
                state: .waitingForOutput,
                message: "终端正在等待密码",
                redactedCommand: "sudo id",
                metadata: [
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "sourceRuntimeID": runtimeID,
                    "targetTitle": "production",
                    "sensitiveInputRequired": "true",
                    "terminalOutputSummary": "Password:"
                ]
            )
        )

        XCTAssertTrue(panel.sensitiveInputVisibleForTesting)
        XCTAssertTrue(panel.sensitiveInputUsesSecureTextFieldForTesting)
        XCTAssertTrue(panel.transcriptContentOrderForTesting.contains("sensitiveInput"))
        panel.setSensitiveInputForTesting("must-not-enter-ai-context")
        panel.submitSensitiveInputForTesting()

        XCTAssertEqual(execution.submissionCount, 1)
        XCTAssertTrue(execution.lastSubmissionWasNonempty)
        XCTAssertTrue(execution.lastSubmissionEndedWithReturn)
        XCTAssertFalse(panel.sensitiveInputVisibleForTesting)
        XCTAssertEqual(panel.sensitiveInputValueForTesting, "")
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("must-not-enter-ai-context"))
        XCTAssertFalse(panel.systemTranscriptTextForTesting.contains("must-not-enter-ai-context"))
        XCTAssertFalse(panel.assistantTranscriptTextForTesting.contains("must-not-enter-ai-context"))
    }

    func testAIPanelDoesNotShowSensitiveInputForOrdinaryWaitingOutput() {
        let runtimeID = "term_ai_ordinary"
        let execution = AISensitiveInputExecution(runtimeID: runtimeID)
        execution.isActive = false
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: execution
            ),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: runtimeID,
                    title: "production",
                    currentDirectory: nil,
                    recentTranscript: ""
                )
            }
        )
        panel.loadView()

        TerminalAgentTraceNotification.post(
            runtimeID: runtimeID,
            title: "production",
            event: AgentTraceEvent(
                requestID: "req-ordinary",
                state: .waitingForOutput,
                message: "仍在运行",
                redactedCommand: "tail -f app.log",
                metadata: [
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "sourceRuntimeID": runtimeID,
                    "sensitiveInputRequired": "false"
                ]
            )
        )

        XCTAssertFalse(panel.sensitiveInputVisibleForTesting)
    }

    func testAIPanelAutomaticallyClearsExpiredSensitiveInput() {
        let runtimeID = "term_ai_sensitive_expired"
        let execution = AISensitiveInputExecution(runtimeID: runtimeID)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: execution
            ),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: runtimeID,
                    title: "production",
                    currentDirectory: nil,
                    recentTranscript: ""
                )
            }
        )
        panel.loadView()

        TerminalAgentTraceNotification.post(
            runtimeID: runtimeID,
            title: "production",
            event: AgentTraceEvent(
                requestID: "req-sensitive-expired",
                state: .waitingForOutput,
                message: "终端正在等待密码",
                redactedCommand: "sudo id",
                metadata: [
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "sourceRuntimeID": runtimeID,
                    "sensitiveInputRequired": "true"
                ]
            )
        )
        panel.setSensitiveInputForTesting("must-not-survive-expiration")
        XCTAssertTrue(panel.sensitiveInputVisibleForTesting)

        execution.isActive = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))

        XCTAssertFalse(panel.sensitiveInputVisibleForTesting)
        XCTAssertEqual(panel.sensitiveInputValueForTesting, "")
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("must-not-survive-expiration"))
    }

    func testSwitchingToWaitingTerminalDiscoversSensitiveInputWithoutAnotherTraceEvent() {
        let waitingRuntimeID = "term_ai_sensitive_waiting"
        let otherRuntimeID = "term_ai_sensitive_other"
        var currentRuntimeID = otherRuntimeID
        let execution = AISensitiveInputExecution(runtimeID: waitingRuntimeID)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: execution
            ),
            contextProvider: { requestedRuntimeID in
                let runtimeID = requestedRuntimeID ?? currentRuntimeID
                return AITerminalContext(
                    runtimeID: runtimeID,
                    title: runtimeID == waitingRuntimeID ? "production" : "other",
                    currentDirectory: nil,
                    recentTranscript: ""
                )
            }
        )
        panel.loadView()

        TerminalAgentTraceNotification.post(
            runtimeID: waitingRuntimeID,
            title: "production",
            event: AgentTraceEvent(
                requestID: "req-sensitive-waiting",
                state: .waitingForOutput,
                message: "终端正在等待密码",
                redactedCommand: "sudo id",
                metadata: [
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "sourceRuntimeID": waitingRuntimeID,
                    "sensitiveInputRequired": "true"
                ]
            )
        )
        XCTAssertFalse(panel.sensitiveInputVisibleForTesting)

        currentRuntimeID = waitingRuntimeID
        panel.followCurrentTerminalContext()

        XCTAssertTrue(panel.sensitiveInputVisibleForTesting)
    }

    func testSensitiveInputRemainsVisibleAtBottomOfLongConversation() throws {
        let runtimeID = "term_ai_sensitive_long_conversation"
        let execution = AISensitiveInputExecution(runtimeID: runtimeID)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: execution
            ),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: runtimeID,
                    title: "production",
                    currentDirectory: nil,
                    recentTranscript: ""
                )
            }
        )
        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        panel.loadTranscriptEntriesForPerformanceTesting(count: 40)
        panel.view.layoutSubtreeIfNeeded()

        TerminalAgentTraceNotification.post(
            runtimeID: runtimeID,
            title: "production",
            event: AgentTraceEvent(
                requestID: "req-sensitive-long-conversation",
                state: .waitingForOutput,
                message: "终端正在等待密码",
                redactedCommand: "sudo id",
                metadata: [
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "sourceRuntimeID": runtimeID,
                    "sensitiveInputRequired": "true",
                    "terminalOutputSummary": "Password:"
                ]
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        panel.view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            panel.view.sensitiveInputDescendant(withIdentifier: "Stacio.AI.transcriptScroll") as? NSScrollView
        )
        let sensitiveInput = try XCTUnwrap(
            panel.view.sensitiveInputDescendant(withIdentifier: "Stacio.AI.sensitiveInput")
        )
        let documentView = try XCTUnwrap(scrollView.documentView)
        let inputFrame = sensitiveInput.convert(sensitiveInput.bounds, to: documentView)

        XCTAssertTrue(scrollView.contentView.bounds.intersects(inputFrame))
        let order = panel.transcriptContentOrderForTesting
        XCTAssertGreaterThan(
            order.firstIndex(of: "sensitiveInput") ?? -1,
            order.firstIndex(of: "transcript") ?? .max
        )
    }
}

@MainActor
private final class AISensitiveInputExecution: AgentCommandExecuting, AgentSensitiveInputRouting {
    let runtimeID: String
    var isActive = true
    private(set) var submissionCount = 0
    private(set) var lastSubmissionWasNonempty = false
    private(set) var lastSubmissionEndedWithReturn = false

    init(runtimeID: String) {
        self.runtimeID = runtimeID
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] { [] }

    func sensitiveInputPrompt(runtimeID: String) -> AgentSensitiveInputPrompt? {
        guard isActive, runtimeID == self.runtimeID else { return nil }
        return AgentSensitiveInputPrompt(runtimeID: runtimeID, targetTitle: "production")
    }

    func submitSensitiveInput(_ bytes: [UInt8], runtimeID: String) -> Bool {
        guard isActive, runtimeID == self.runtimeID else { return false }
        submissionCount += 1
        lastSubmissionWasNonempty = bytes.dropLast().isEmpty == false
        lastSubmissionEndedWithReturn = bytes.last == 13
        isActive = false
        return true
    }
}

private extension NSView {
    func sensitiveInputDescendant(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.sensitiveInputDescendant(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
