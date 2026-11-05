import XCTest
import Foundation
@testable import StacioApp

/// P4-5：模型获取服务（无预置模型、模型选择、manual 模型策略、endpoint 策略、连接测试）。
final class ProviderModelCatalogServiceTests: XCTestCase {

    // MARK: - 新配置全空（无预置模型）

    func testFreshConfigurationHasNoPresetModels() {
        let state = ProviderModelCatalogService.freshState()
        XCTAssertTrue(state.isFreshConfiguration, "新配置 discovered/manual/enabled/default 全空")
        XCTAssertTrue(state.discoveredModelIDs.isEmpty)
        XCTAssertTrue(state.manualModelIDs.isEmpty)
        XCTAssertTrue(state.enabledModelIDs.isEmpty)
        XCTAssertNil(state.defaultModelID)
    }

    // MARK: - 模型选择只显示上游真实 ID

    func testVisibleModelsOnlyUpstreamRealIDs() {
        var state = ProviderModelCatalogState(
            discoveredModelIDs: ["gpt-4o", "gpt-4o-mini"],
            manualModelIDs: ["custom-llm"],
            enabledModelIDs: ["gpt-4o", "custom-llm"]
        )
        XCTAssertEqual(
            ProviderModelCatalogService.visibleModelIDs(state: state),
            ["gpt-4o", "gpt-4o-mini", "custom-llm"],
            "可见 = 上游 discovered + 已启用的 userDeclared manual"
        )
        // 未启用的 manual 不可见
        state.enabledModelIDs = ["gpt-4o"]
        XCTAssertEqual(ProviderModelCatalogService.visibleModelIDs(state: state), ["gpt-4o", "gpt-4o-mini"])
    }

    func testDefaultModelMustBeExplicit() {
        var state = ProviderModelCatalogState(
            discoveredModelIDs: ["gpt-4o"], enabledModelIDs: ["gpt-4o"]
        )
        XCTAssertTrue(ProviderModelCatalogService.canBecomeDefault(modelID: "gpt-4o", state: state))
        // 未启用不可选为默认
        state.enabledModelIDs = []
        XCTAssertFalse(ProviderModelCatalogService.canBecomeDefault(modelID: "gpt-4o", state: state))
        // 未知模型不可选为默认
        XCTAssertFalse(ProviderModelCatalogService.canBecomeDefault(modelID: "not-a-model", state: state))
    }

    func testReadyToActivateRequiresTestAndValidDefault() {
        XCTAssertTrue(ProviderModelCatalogService.readyToActivate(connectionTested: true, defaultModelValid: true))
        XCTAssertFalse(ProviderModelCatalogService.readyToActivate(connectionTested: false, defaultModelValid: true))
        XCTAssertFalse(ProviderModelCatalogService.readyToActivate(connectionTested: true, defaultModelValid: false))
    }

    // MARK: - manageManualModelIDs

    func testManualModelsOnlyForNoEnumerationContractSources() {
        XCTAssertTrue(ProviderModelCatalogService.manualModelsAllowed(hasEnumerationContract: false))
        XCTAssertFalse(ProviderModelCatalogService.manualModelsAllowed(hasEnumerationContract: true),
                       "有枚举契约的源禁止手工注入模型")
    }

    func testManualModelCannotEnableBeforeTest() {
        let state = ProviderModelCatalogState(manualModelIDs: ["custom-llm"])
        XCTAssertFalse(
            ProviderModelCatalogService.canEnable(manualModelID: "custom-llm", state: state, connectionTested: false),
            "测试前不可启用"
        )
        XCTAssertTrue(
            ProviderModelCatalogService.canEnable(manualModelID: "custom-llm", state: state, connectionTested: true)
        )
    }

    func testEnableManualModelFlow() throws {
        let state = ProviderModelCatalogState(manualModelIDs: ["custom-llm"])
        // 未测试 → 拒绝
        XCTAssertEqual(
            ProviderModelCatalogService.enableManualModel(
                modelID: "custom-llm", state: state, hasEnumerationContract: false, connectionTested: false
            ),
            .failure(.cannotEnableUntestedManualModel)
        )
        // 有枚举契约 → 拒绝
        XCTAssertEqual(
            ProviderModelCatalogService.enableManualModel(
                modelID: "custom-llm", state: state, hasEnumerationContract: true, connectionTested: true
            ),
            .failure(.manualModelsNotAllowed)
        )
        // 未知 manual ID → 拒绝
        XCTAssertEqual(
            ProviderModelCatalogService.enableManualModel(
                modelID: "ghost", state: state, hasEnumerationContract: false, connectionTested: true
            ),
            .failure(.manualModelIDUnknown("ghost"))
        )
        // 已测试 → 启用
        let enabled = try ProviderModelCatalogService.enableManualModel(
            modelID: "custom-llm", state: state, hasEnumerationContract: false, connectionTested: true
        ).get()
        XCTAssertEqual(enabled.enabledModelIDs, ["custom-llm"])
        // 幂等
        let again = try ProviderModelCatalogService.enableManualModel(
            modelID: "custom-llm", state: enabled, hasEnumerationContract: false, connectionTested: true
        ).get()
        XCTAssertEqual(again.enabledModelIDs, ["custom-llm"])
    }

    // MARK: - endpoint 策略

    func testModelEndpointPolicies() {
        XCTAssertEqual(ProviderModelEndpointPolicy.policy(forDescriptorStrategy: nil), .modelsRoot)
        XCTAssertEqual(ProviderModelEndpointPolicy.policy(forDescriptorStrategy: "default"), .modelsRoot)
        XCTAssertEqual(ProviderModelEndpointPolicy.policy(forDescriptorStrategy: "v1/models"), .v1Models)
        XCTAssertEqual(ProviderModelEndpointPolicy.policy(forDescriptorStrategy: "descriptorSpecific"), .descriptorSpecific)
    }

    // MARK: - 连接测试

    func testConnectionVerifierUsesTesterAndDiscoversModels() {
        final class StubTester: ProviderConnectionTesting {
            func verify(endpoint: URL, apiKey: String?) -> ProviderConnectionVerificationResult {
                ProviderConnectionVerificationResult(
                    succeeded: apiKey != nil,
                    discoveredModelIDs: apiKey != nil ? ["gpt-4o", "gpt-4o-mini"] : []
                )
            }
        }
        let verifier = ProviderConnectionVerifier(tester: StubTester())
        let withKey = verifier.verify(endpoint: URL(string: "https://api.example.com/v1")!, apiKey: "sk-test")
        XCTAssertTrue(withKey.succeeded)
        XCTAssertEqual(withKey.discoveredModelIDs, ["gpt-4o", "gpt-4o-mini"])
        // 失败不产生模型发现
        let withoutKey = verifier.verify(endpoint: URL(string: "https://api.example.com/v1")!, apiKey: nil)
        XCTAssertFalse(withoutKey.succeeded)
        XCTAssertTrue(withoutKey.discoveredModelIDs.isEmpty)
    }
}
