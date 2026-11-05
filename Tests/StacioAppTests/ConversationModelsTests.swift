import XCTest
import Foundation
@testable import StacioApp

/// C2-1：领域模型与关闭枚举。
/// 编译期断言关闭集合存在；未知 raw value 拒绝；reasonCode 为稳定 lowerCamel。
final class ConversationModelsTests: XCTestCase {

    func testAttemptPhaseClosedSetAndTerminalStates() {
        let expected: [AttemptPhase] = [
            .preparing, .waitingForCapacity, .startingRuntime, .streaming, .toolProposed,
            .awaitingApproval, .executingTool, .awaitingUser, .pausing, .paused,
            .takeoverPending, .stopping, .completed, .failed, .cancelled, .takenOver,
            .interruptedByRelaunch, .passthroughInputDelivered
        ]
        XCTAssertEqual(AttemptPhase.allCases.count, expected.count)
        XCTAssertEqual(Set(AttemptPhase.allCases), Set(expected))
        for terminal in [AttemptPhase.completed, .failed, .cancelled, .takenOver, .interruptedByRelaunch] {
            XCTAssertTrue(terminal.isTerminal, "\(terminal) 应为终态")
        }
        for nonTerminal in [AttemptPhase.preparing, .streaming, .stopping, .paused, .awaitingApproval] {
            XCTAssertFalse(nonTerminal.isTerminal, "\(nonTerminal) 不应为终态")
        }
    }

    func testAttemptOutcomeClosedSet() {
        let expected: [AttemptOutcome] = [
            .completed, .failed, .cancelled, .takenOver, .interruptedByRelaunch,
            .passthroughInputDelivered
        ]
        XCTAssertEqual(AttemptOutcome.allCases.count, expected.count)
        XCTAssertEqual(Set(AttemptOutcome.allCases), Set(expected))
    }

    func testReasonCodesAreStableLowerCamel() {
        for code in AttemptReasonCode.allCases {
            let raw = code.rawValue
            XCTAssertFalse(raw.contains(" "), "reasonCode 不得含空格: \(raw)")
            XCTAssertFalse(raw.contains("_"), "reasonCode 应为 lowerCamel，禁止下划线: \(raw)")
            XCTAssertFalse(raw.contains("-"), "reasonCode 应为 lowerCamel，禁止连字符: \(raw)")
            guard let first = raw.first else { continue }
            XCTAssertTrue(first.isLowercase, "reasonCode 首字母应小写: \(raw)")
        }
        // 关闭集合与规格 §8.3 表一致
        XCTAssertTrue(AttemptReasonCode.allCases.contains(.completed))
        XCTAssertTrue(AttemptReasonCode.allCases.contains(.capacityWaitExpired))
        XCTAssertTrue(AttemptReasonCode.allCases.contains(.runtimeStateUnknown))
        // workModeDenied / approvalExpired 不是终态 reasonCode
        XCTAssertFalse(AttemptReasonCode.allCases.map(\.rawValue).contains("workModeDenied"))
        XCTAssertFalse(AttemptReasonCode.allCases.map(\.rawValue).contains("approvalExpired"))
    }

    func testWorkModeClosedSet() {
        XCTAssertEqual(Set(WorkMode.allCases), Set([.agent, .plan, .answerOnly]))
    }

    func testRuntimeAuthenticationModeClosedSet() {
        XCTAssertEqual(
            Set(RuntimeAuthenticationMode.allCases),
            Set([.stacioCredentialBindings, .cliManagedAuthentication, .combined, .noneVerified])
        )
    }

    func testDecisionKindAndStateClosedSets() {
        XCTAssertEqual(
            Set(DecisionKind.allCases),
            Set([.planApproval, .operationApproval, .userInput, .secureInput, .usageExtension])
        )
        XCTAssertEqual(
            Set(DecisionState.allCases),
            Set([.pending, .approved, .denied, .answered, .skipped, .expired, .cancelled])
        )
    }

    func testToolProposalStateClosedSet() {
        XCTAssertEqual(
            Set(ToolProposalState.allCases),
            Set([.queued, .evaluating, .awaitingApproval, .executing, .resolved, .cancelled])
        )
    }

    func testQueuedInputRevalidationClosedSet() {
        XCTAssertEqual(
            Set(QueuedInputRevalidationState.allCases),
            Set([.valid, .needsRebind, .needsSelection, .blocked])
        )
    }

    func testLocalAgentExecutionProfileKindClosedSet() {
        XCTAssertEqual(
            Set(LocalAgentExecutionProfileKind.allCases),
            Set([.managed, .terminalPassthrough, .none])
        )
    }

    func testUnknownRawValuesAreRejected() {
        XCTAssertNil(AttemptPhase(rawValue: "bogus"))
        XCTAssertNil(AttemptOutcome(rawValue: "bogus"))
        XCTAssertNil(AttemptReasonCode(rawValue: "bogus"))
        XCTAssertNil(WorkMode(rawValue: "bogus"))
        XCTAssertNil(RuntimeAuthenticationMode(rawValue: "bogus"))
        XCTAssertNil(DecisionKind(rawValue: "bogus"))
        XCTAssertNil(ToolProposalState(rawValue: "bogus"))
        XCTAssertNil(QueuedInputRevalidationState(rawValue: "bogus"))
        XCTAssertNil(LocalAgentExecutionProfileKind(rawValue: "bogus"))
    }

    func testCredentialLifecycleClosedSet() {
        XCTAssertEqual(
            Set(CredentialGenerationLifecycleState.allCases),
            Set([.pendingActivation, .active, .retired, .revoked, .abandoned])
        )
        // abandoned 是终态
        XCTAssertEqual(Set(CredentialSetupOperationState.allCases),
                       Set([.open, .suspended, .discardRequested, .activating, .completed, .abandoned]))
    }

    func testRuntimeCapabilitiesDefaultsAreOff() {
        let caps = RuntimeCapabilities()
        XCTAssertFalse(caps.streaming)
        XCTAssertFalse(caps.toolCalling)
        XCTAssertFalse(caps.steering)
        XCTAssertFalse(caps.managedExecution)
        XCTAssertFalse(caps.answerOnlyRuntimeLaunch)
        XCTAssertFalse(caps.workModeEnforcement)
        XCTAssertEqual(caps.allowedWorkModes, [])
    }
}
