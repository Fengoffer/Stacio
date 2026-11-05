import XCTest
import Foundation
@testable import StacioApp

/// P8-7：Local Agent 配置证据投影（只读投影方、用户不能手动标记、changeProfile 边界、更新后重验）。
final class LocalAgentConfigurationEvidenceTests: XCTestCase {

    // MARK: - probe/journal/Evidence Store 只读投影

    func testProbeJournalFieldsReadOnlyProjection() {
        for field in ["detectedVersion", "loginStateSummary", "lastNegotiatedProtocol",
                      "modelSelectionMode", "discoveredModels"] {
            XCTAssertTrue(LocalAgentEvidenceAction.projectedOnlyByProbeOrJournal(field),
                          "\(field) 只由 descriptor probe/journal/Evidence Store 只读投影")
        }
        XCTAssertFalse(LocalAgentEvidenceAction.projectedOnlyByProbeOrJournal("containmentRevision"))
    }

    func testBrokerSupervisorFieldsReadOnlyProjection() {
        for field in ["containmentProfileID", "containmentRevision", "launchCapabilityBindingRevision",
                      "answerOnlyContainmentRevision", "capabilitySnapshot", "environmentDigest",
                      "bypassTestedAt", "lastVerifiedAt", "state"] {
            XCTAssertTrue(LocalAgentEvidenceAction.projectedOnlyByBrokerSupervisorOrEvidenceStore(field),
                          "\(field) 只由 Broker/Supervisor/证据 Store 投影")
        }
    }

    func testUserCannotManuallyMarkVerified() {
        XCTAssertTrue(LocalAgentEvidenceAction.userCannotManuallyMarkVerified(),
                      "用户不能手动标记通过")
    }

    // MARK: - changeExecutionProfile 边界

    func testChangeProfileWritesOnlySelectionAndPTYTrust() {
        XCTAssertTrue(LocalAgentEvidenceAction.changeProfileWritesOnlySelectionAndExplicitPTYTrust(),
                      "localAgent.changeExecutionProfile 只能提交选择和显式 PTY trust 不得写验证结果")
    }

    // MARK: - 更新后重验

    func testRevalidateAfterUpdate() {
        XCTAssertTrue(LocalAgentEvidenceAction.revalidateAfterConfigurationOrDescriptorUpdate(),
                      "配置或 descriptor 更新后重新记录版本/能力/登录状态/最后验证时间/environment digest/containment/capability/process-supervision revision")
    }

    // MARK: - 证据来源

    func testEvidenceSourceMustBeReadOnlyProjection() {
        XCTAssertTrue(LocalAgentEvidenceAction.sourceProducesVerificationEvidence(.descriptorProbe))
        XCTAssertTrue(LocalAgentEvidenceAction.sourceProducesVerificationEvidence(.maintenanceLaunchJournal))
        XCTAssertTrue(LocalAgentEvidenceAction.sourceProducesVerificationEvidence(.evidenceStore))
        XCTAssertTrue(LocalAgentEvidenceAction.sourceProducesVerificationEvidence(.capabilityBroker))
        XCTAssertTrue(LocalAgentEvidenceAction.sourceProducesVerificationEvidence(.processSupervisor))
        XCTAssertFalse(LocalAgentEvidenceAction.sourceProducesVerificationEvidence(.userSelection),
                       "userSelection 不能产生验证证据")
    }
}
