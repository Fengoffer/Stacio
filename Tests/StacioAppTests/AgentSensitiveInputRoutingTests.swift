import Foundation
import StacioAgentBridge
import XCTest
@testable import StacioApp

@MainActor
final class AgentSensitiveInputRoutingTests: XCTestCase {
    func testVisibleAgentWaitsForSensitiveInputWithoutBroadcastingOrUnlockingEarly() throws {
        let hub = TerminalOutputBroadcastHub()
        let target = SensitiveInputAgentTarget(runtimeID: "term_sensitive", title: "production")
        var coordinator: AgentExecutionCoordinator!
        coordinator = AgentExecutionCoordinator(
            terminalResolver: SensitiveInputAgentResolver(target: target),
            authorizer: SensitiveInputAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: AgentVisibleTerminalCompletion(
                idleInterval: 0.02,
                maximumDuration: 0.2
            )
        )
        target.onAgentInput = {
            target.isAwaitingSensitiveInput = true
            hub.publishOutput(runtimeID: target.runtimeID, bytes: Array("Password:".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                XCTAssertTrue(coordinator.submitSensitiveInput(
                    Array("agent-must-never-see-this\r".utf8),
                    runtimeID: target.runtimeID
                ))
            }
        }
        target.onSensitiveInput = {
            target.isAwaitingSensitiveInput = false
            hub.publishOutput(runtimeID: target.runtimeID, bytes: Array("\r\ncompleted\r\n$ ".utf8))
            hub.publishCommandFinished(runtimeID: target.runtimeID)
        }

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-sensitive",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID(target.runtimeID),
                        command: "sudo id",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(target.sensitiveSubmissionCount, 1)
        XCTAssertEqual(target.lockStates, [true, false])
        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertFalse(events.contains { $0.metadata?["completionReason"] == "userInputDuringCommand" })
        let serializedTrace = events.map { event in
            "\(event.message) \(event.redactedCommand ?? "") \(event.metadata ?? [:])"
        }.joined(separator: "\n")
        XCTAssertFalse(serializedTrace.contains("agent-must-never-see-this"))
    }

    func testSensitiveInputRouterRejectsInactiveOrWrongRuntimeTargets() {
        let target = SensitiveInputAgentTarget(runtimeID: "term_sensitive", title: "production")
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: SensitiveInputAgentResolver(target: target),
            authorizer: SensitiveInputAllowingAuthorizer()
        )

        XCTAssertFalse(coordinator.submitSensitiveInput([13], runtimeID: "term_other"))
        XCTAssertFalse(coordinator.submitSensitiveInput([13], runtimeID: target.runtimeID))
        XCTAssertEqual(target.sensitiveSubmissionCount, 0)
    }

    func testExpiredPromptProtectionStillSupportsMappedInputAndCancellation() throws {
        let requestID = "req-sensitive-expired"
        let target = SensitiveInputAgentTarget(runtimeID: "term_sensitive_expired", title: "production")
        target.hasExpiredSensitiveInputProtection = true
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: SensitiveInputAgentResolver(target: target),
            authorizer: SensitiveInputAllowingAuthorizer(),
            visibleTerminalCompletion: AgentVisibleTerminalCompletion(
                idleInterval: 0.01,
                maximumDuration: 0.02
            )
        )

        XCTAssertEqual(
            coordinator.sensitiveInputPrompt(runtimeID: target.runtimeID),
            AgentSensitiveInputPrompt(runtimeID: target.runtimeID, targetTitle: target.agentTitle)
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: requestID,
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID(target.runtimeID),
                        command: "sudo id",
                        follow: true
                    )
                )
            )
        )
        let cancelled = coordinator.cancelTask(requestID: requestID)

        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(target.sensitiveSubmissionCount, 1)
        XCTAssertEqual(target.ordinarySubmissionCount, 0)
        XCTAssertEqual(target.lastSensitiveSubmission, [3])
    }

    func testSensitivePromptStateIsPublishedEvenWhenOutputUpdatesAreThrottled() throws {
        let hub = TerminalOutputBroadcastHub()
        let target = SensitiveInputAgentTarget(runtimeID: "term_sensitive_throttled", title: "production")
        var coordinator: AgentExecutionCoordinator!
        coordinator = AgentExecutionCoordinator(
            terminalResolver: SensitiveInputAgentResolver(target: target),
            authorizer: SensitiveInputAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: AgentVisibleTerminalCompletion(
                idleInterval: 0.02,
                maximumDuration: 0.2
            )
        )
        target.onAgentInput = {
            hub.publishOutput(runtimeID: target.runtimeID, bytes: Array("preparing\r\n".utf8))
            target.isAwaitingSensitiveInput = true
            hub.publishOutput(runtimeID: target.runtimeID, bytes: Array("Password:".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                XCTAssertTrue(coordinator.submitSensitiveInput(
                    Array("private-value\r".utf8),
                    runtimeID: target.runtimeID
                ))
            }
        }
        target.onSensitiveInput = {
            target.isAwaitingSensitiveInput = false
            hub.publishOutput(runtimeID: target.runtimeID, bytes: Array("\r\ncompleted\r\n$ ".utf8))
            hub.publishCommandFinished(runtimeID: target.runtimeID)
        }

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-sensitive-throttled",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID(target.runtimeID),
                        command: "sudo id",
                        follow: true
                    )
                )
            )
        )

        XCTAssertTrue(events.contains { event in
            event.metadata?["sensitiveInputRequired"] == "true"
        })
        XCTAssertFalse(events.map(\.message).joined(separator: "\n").contains("private-value"))
    }

    func testAIAssistantCoordinatorOnlyExposesTheSensitiveInputRoute() {
        let target = SensitiveInputAgentTarget(runtimeID: "term_sensitive", title: "production")
        target.isAwaitingSensitiveInput = true
        let execution = AgentExecutionCoordinator(
            terminalResolver: SensitiveInputAgentResolver(target: target),
            authorizer: SensitiveInputAllowingAuthorizer()
        )
        let assistant = AIAssistantCoordinator(
            provider: RuleBasedAIAssistantProvider(),
            executionCoordinator: execution
        )

        XCTAssertEqual(
            assistant.sensitiveInputPrompt(runtimeID: target.runtimeID),
            AgentSensitiveInputPrompt(runtimeID: target.runtimeID, targetTitle: target.agentTitle)
        )
        XCTAssertTrue(assistant.submitSensitiveInput([13], runtimeID: target.runtimeID))
        XCTAssertEqual(target.sensitiveSubmissionCount, 1)
    }
}

@MainActor
private final class SensitiveInputAgentTarget: AgentTerminalTarget {
    let runtimeID: String
    let agentTitle: String
    let agentLiveSessionContext: TunnelLiveSessionContext? = nil
    var isAwaitingSensitiveInput = false
    var hasExpiredSensitiveInputProtection = false
    var onAgentInput: (() -> Void)?
    var onSensitiveInput: (() -> Void)?
    private(set) var sensitiveSubmissionCount = 0
    private(set) var ordinarySubmissionCount = 0
    private(set) var lastSensitiveSubmission: [UInt8]?
    private(set) var lockStates: [Bool] = []

    var isSensitiveInputProtectionActive: Bool {
        isAwaitingSensitiveInput || hasExpiredSensitiveInputProtection
    }

    init(runtimeID: String, title: String) {
        self.runtimeID = runtimeID
        self.agentTitle = title
    }

    func setAgentInteractionLocked(_ locked: Bool) {
        lockStates.append(locked)
    }

    func appendAgentTrace(_ event: AgentTraceEvent) {}
    func sendInput(_ bytes: [UInt8]) {
        ordinarySubmissionCount += 1
    }
    func sendAgentInput(_ bytes: [UInt8]) {
        onAgentInput?()
    }

    func sendSensitiveUserInput(_ bytes: [UInt8]) -> Bool {
        guard isSensitiveInputProtectionActive else { return false }
        sensitiveSubmissionCount += 1
        lastSensitiveSubmission = bytes
        hasExpiredSensitiveInputProtection = false
        onSensitiveInput?()
        return true
    }
}

@MainActor
private struct SensitiveInputAgentResolver: AgentTerminalResolving {
    let target: AgentTerminalTarget

    func resolveTerminalTarget(_ requestedTarget: AgentTarget) throws -> AgentTerminalTarget {
        guard case .runtimeID(let runtimeID) = requestedTarget,
              runtimeID == target.runtimeID
        else {
            throw AgentExecutionError.terminalNotFound
        }
        return target
    }
}

private struct SensitiveInputAllowingAuthorizer: AgentActionAuthorizing {
    func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String
    ) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "allowed",
            risk: .write,
            requiredUserConfirmation: false
        )
    }
}
