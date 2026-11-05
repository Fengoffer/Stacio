import XCTest
import Foundation
@testable import StacioApp

/// P9-6：V1 Provider/Local Agent 配置无损迁移。
final class V1ConfigurationMigrationTests: XCTestCase {

    // MARK: - Provider catalog 关联

    func testV1ProviderIdentityMapping() {
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "OpenAI"), "provider.openai")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "DeepSeek"), "provider.deepseek")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "OpenRouter"), "provider.openrouter")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "Qwen"), "provider.alibaba-bailian-qwen")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "Kimi"), "provider.kimi-api")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "Ollama"), "provider.ollama")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "LM Studio"), "provider.lm-studio")
        XCTAssertEqual(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "OpenAI Compatible"), "provider.openai-compatible.custom")
        XCTAssertNil(V1ConfigurationMigration.providerCatalogID(fromV1Identity: "未知供应商"))
    }

    // MARK: - 无损解析（禁止回退）

    func testLosslessResolutionUnknownKept() {
        XCTAssertEqual(
            V1ConfigurationMigration.losslessResolution(fromV1Identity: "OpenAI"),
            .mapped(catalogID: "provider.openai")
        )
        // 未知值原样保留（不映射最相似、不回退 .portDeskRules）
        XCTAssertEqual(
            V1ConfigurationMigration.losslessResolution(fromV1Identity: "Custom Vendor"),
            .unknown(value: "Custom Vendor")
        )
    }

    // MARK: - Stacio Rules 与 mozhe

    func testStacioRulesToReadOnlyContractDomain() {
        XCTAssertTrue(V1ConfigurationMigration.stacioRulesGoesToReadOnlyOperationalContract())
        XCTAssertTrue(V1ConfigurationMigration.stacioRulesDoesNotCreatePseudoProvider(),
                      "Stacio Rules 不创建伪 Provider")
    }

    func testMozheRequiresAuthoritativeIdentity() {
        XCTAssertTrue(V1ConfigurationMigration.mozheRequiresAuthoritativeBuiltInIdentity(),
                      "mozheAPI 只有旧配置含权威内置 identity/UUID 时才关联")
        XCTAssertTrue(V1ConfigurationMigration.mozheNotAssociatedByDomainOrName(),
                      "不能仅凭域名/名称吞并用户自定义配置")
    }

    // MARK: - Base URL

    func testBaseURLOutcomeNeedsEndpointOnEmptyOrInvalid() {
        XCTAssertEqual(V1ConfigurationMigration.baseURLOutcome(rawValue: nil), .needsEndpoint)
        XCTAssertEqual(V1ConfigurationMigration.baseURLOutcome(rawValue: "not a url"), .needsEndpoint,
                       "规范化失败 → NeedsEndpoint（不填回 descriptor 默认/生产地址）")
        XCTAssertEqual(V1ConfigurationMigration.baseURLOutcome(rawValue: "ftp://host"), .needsEndpoint,
                       "非 http/https scheme 拒绝")
        XCTAssertEqual(
            V1ConfigurationMigration.baseURLOutcome(rawValue: "https://api.example.com/v1"),
            .resolved(url: "https://api.example.com/v1")
        )
    }

    // MARK: - legacyImported 模型

    func testLegacyImportedModelsNotAutoSelected() {
        XCTAssertTrue(V1ConfigurationMigration.legacyImportedModelsNotAutoSelected(),
                      "完成上游同步前不能被新会话自动选用")
        XCTAssertTrue(V1ConfigurationMigration.legacyImportedNotWrittenIntoNewCatalogTemplate(),
                      "不写入新目录模板")
    }

    // MARK: - Local Agent raw-value 映射

    func testLocalAgentRawValueMapping() {
        XCTAssertEqual(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "codex"), "local-agent.codex")
        XCTAssertEqual(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "claudeCode"), "local-agent.claude-code")
        XCTAssertEqual(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "opencode"), "local-agent.opencode")
        XCTAssertEqual(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "mimoCode"), "local-agent.mimo-code")
        XCTAssertEqual(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "zcode"), "local-agent.zcode")
        XCTAssertEqual(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "qwenCode"), "local-agent.qwen-code")
        XCTAssertNil(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "Codex"), "显示名不是身份")
        XCTAssertNil(V1ConfigurationMigration.localAgentCatalogID(fromRawValue: "codex 可执行文件"))
    }

    // MARK: - 迁移范围

    func testMigratesOnlyLastSelectedToolAndResolvedPath() {
        XCTAssertTrue(V1ConfigurationMigration.migratesOnlyLastSelectedTool())
        XCTAssertTrue(V1ConfigurationMigration.migratesOnlyResolvedAbsoluteExecutablePath())
        XCTAssertTrue(V1ConfigurationMigration.neverInfersUnverifiedStates(),
                      "候选路径/猜测别名/登录状态/能力/版本/工作目录/环境变量/「已受控」状态不得推断")
    }

    // MARK: - 迁移项状态

    func testMigratedItemsNeedVerificationAndEmptyProfile() {
        XCTAssertTrue(V1ConfigurationMigration.migratedProviderNeedsVerification(),
                      "迁移项统一 NeedsVerification")
        XCTAssertTrue(V1ConfigurationMigration.migratedLocalAgentExecutionProfileEmpty(),
                      "execution profile 为空")
    }
}
