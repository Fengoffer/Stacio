import XCTest
import Foundation
@testable import StacioApp

/// P4-5：Provider 配置流程（saveDraft 无凭证/有凭证分支、saveCredentialAndFetchModels、
/// 严格免凭证、activate 全 settlement、Keychain staging 规则）。
final class ProviderConfigurationFlowTests: XCTestCase {

    // MARK: - saveDraft 无凭证分支

    func testSaveDraftWithoutCredentialZeroCredentialActivity() {
        let plan = ProviderConfigurationFlow.planSaveDraft(credential: .none)
        XCTAssertEqual(plan.steps, [.configurationSavedDraft])
        XCTAssertFalse(plan.credentialActivity, "无凭证分支零 credential 活动")
        XCTAssertEqual(plan.keychainWrites, 0, "无 Keychain 写")
        // 零 CredentialGeneration/use lease/setup/lifecycle：plan 中无任何 credential 步骤
        XCTAssertFalse(plan.steps.contains(where: { step in
            if case .credentialSetupSavedDraft = step { return true }
            if case .credentialActivationSavedAsDraft = step { return true }
            return false
        }))
    }

    // MARK: - saveDraft 有凭证分支

    func testSaveDraftWithCredentialUsesSavedDraftRetentionPerGeneration() {
        let plan = ProviderConfigurationFlow.planSaveDraft(credential: .present(generationCount: 2))
        XCTAssertEqual(plan.steps, [
            .credentialSetupSavedDraft(retention: "savedDraft"),
            .credentialActivationSavedAsDraft(generationIndex: 0),
            .credentialActivationSavedAsDraft(generationIndex: 1)
        ])
        XCTAssertTrue(plan.credentialActivity)
        XCTAssertEqual(plan.keychainWrites, 0, "saveDraft 不写 Keychain（staging 只在 settling）")
    }

    // MARK: - saveCredentialAndFetchModels

    func testSaveCredentialAndFetchModelsOrder() {
        let plan = ProviderConfigurationFlow.planSaveCredentialAndFetchModels()
        XCTAssertEqual(plan.steps, [
            .credentialSetupCreate,
            .keychainStagingWrite(stage: "settling"),
            .configurationVerificationRequest(owner: "setup"),
            .settle
        ])
        // staging write 只在 settling 阶段
        XCTAssertTrue(ProviderConfigurationFlow.stagingWriteAllowed(stage: "settling"))
        XCTAssertFalse(ProviderConfigurationFlow.stagingWriteAllowed(stage: "prepared"))
        XCTAssertFalse(ProviderConfigurationFlow.stagingWriteAllowed(stage: "issued"))
        // 顺序：credentialSetupCreate 先于独立 verificationRequest（setup-owner use lease）
        let first = plan.steps.firstIndex(of: .credentialSetupCreate)!
        let verification = plan.steps.firstIndex(of: .configurationVerificationRequest(owner: "setup"))!
        XCTAssertLessThan(first, verification, "先 credentialSetupCreate 再 configurationVerificationRequest")
    }

    // MARK: - 严格免凭证（Ollama/LM Studio）

    func testNoCredentialFetchPlanIndependentAndZeroCapabilities() {
        let plan = ProviderConfigurationFlow.planNoCredentialFetch()
        XCTAssertEqual(plan.owner, "configurationAction", "owner==configurationAction")
        XCTAssertEqual(plan.accessMode, "none", "accessMode==none")
        XCTAssertEqual(plan.generationCount, 0, "零 generation")
        XCTAssertEqual(plan.useLeaseCount, 0, "零 use lease")
        XCTAssertEqual(plan.setupCount, 0, "零 setup")
        XCTAssertEqual(plan.lifecycleCount, 0, "零 lifecycle")
        // 独立请求（不共用 saveCredential 的 staging）
        XCTAssertFalse(
            plan.steps.contains(.keychainStagingWrite(stage: "settling")),
            "免凭证分支无 Keychain staging"
        )
    }

    // MARK: - activate

    func testActivateWithCredentialRequiresFullSettlement() {
        let plan = ProviderConfigurationFlow.planActivation(credential: .present(generationCount: 2))
        XCTAssertTrue(plan.requiresFullSettlement)
        XCTAssertEqual(plan.steps, [
            .participantSettlement(participant: "credential-generation-0"),
            .participantSettlement(participant: "credential-generation-1"),
            .participantSettlement(participant: "configuration"),
            .activated
        ])
        // 全 participant settlement 后才 Active：activated 必须在最后
        let settlementIndices = plan.steps.enumerated()
            .filter { if case .participantSettlement = $0.element { return true }; return false }
            .map(\.offset)
        let activatedIndex = plan.steps.firstIndex(of: .activated)!
        for index in settlementIndices {
            XCTAssertLessThan(index, activatedIndex, "全 participant settlement 后才 Active")
        }
    }

    func testActivateWithoutCredentialCommitsOnlyConfigurationParticipant() {
        let plan = ProviderConfigurationFlow.planActivation(credential: .none)
        XCTAssertFalse(plan.requiresFullSettlement)
        XCTAssertEqual(
            plan.steps,
            [.configurationParticipantCommit(enabledTransition: "false->true")],
            "免凭证分支只提交 Configuration participant 且 enabled false→true 同一事务"
        )
        XCTAssertFalse(plan.steps.contains(.activated))
    }
}
