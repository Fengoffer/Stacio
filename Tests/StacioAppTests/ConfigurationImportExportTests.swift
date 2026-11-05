import XCTest
import Foundation
@testable import StacioApp

/// P4-9a：配置导入导出（白名单、脱敏预览、dry-run、未知字段、NeedsVerification、隐藏授权、逐配置提交）。
final class ConfigurationImportExportTests: XCTestCase {

    private func entry(
        _ id: String, _ field: String, _ visibility: ConfigurationExportVisibility, _ value: String?
    ) -> ConfigurationExportEntry {
        ConfigurationExportEntry(configurationID: id, field: field, visibility: visibility, value: value)
    }

    // MARK: - 白名单与永不导出

    func testNeverExportedFields() {
        for field in ["apiKey", "api_key", "keychainRef", "oauthToken", "proxyPassword",
                      "secretHeader", "envValue", "credentialReference", "cookie"] {
            XCTAssertTrue(ConfigurationImportExport.neverExported(field: field), "\(field) 永不进入 manifest")
        }
        XCTAssertFalse(ConfigurationImportExport.neverExported(field: "baseURL"))
        XCTAssertFalse(ConfigurationImportExport.neverExported(field: "model"))
    }

    func testOnlyExportableAndExplicitPreviewInManifest() {
        let entries = [
            entry("c-1", "baseURL", .exportable, "https://api.example.com"),
            entry("c-1", "apiKey", .never, "sk-secret"),
            entry("c-1", "model", .explicitPreview, "gpt-4o"),
            entry("c-1", "customHeader", .never, "Bearer x"),
            entry("c-1", "emptyPreview", .explicitPreview, nil)
        ]
        let plan = ConfigurationImportExport.exportPlan(entries: entries)
        XCTAssertEqual(plan.manifest.entries.count, 2, "只含 exportable|explicitPreview 非 secret 值")
        XCTAssertFalse(plan.manifest.entries.contains { $0.field == "apiKey" })
        XCTAssertFalse(plan.manifest.entries.contains { $0.field == "customHeader" })
        XCTAssertFalse(plan.manifest.entries.contains { $0.field == "emptyPreview" }, "explicitPreview 无值不导出")
    }

    // MARK: - 先脱敏预览再写文件

    func testExportRedactsPreviewBeforeWritingFile() {
        let entries = [
            entry("c-1", "baseURL", .exportable, "https://api.example.com"),
            entry("c-1", "model", .explicitPreview, "gpt-4o")
        ]
        let plan = ConfigurationImportExport.exportPlan(entries: entries)
        XCTAssertEqual(plan.redactedPreview["c-1.model"], "[preview]", "explicitPreview 脱敏为占位")
        XCTAssertEqual(plan.redactedPreview["c-1.baseURL"], "https://api.example.com")
        // manifest 是写文件的真实内容（不含 secret）
        XCTAssertFalse(plan.manifest.entries.contains { $0.field == "apiKey" })
    }

    // MARK: - dry-run 差异预览

    func testDryRunDiffPreview() {
        let preview = ConfigurationImportExport.dryRun(
            imported: ["baseURL": "https://new.example.com", "model": "gpt-4o", "unchangedField": "same"],
            current: ["baseURL": "https://old.example.com", "unchangedField": "same"]
        )
        XCTAssertEqual(preview.added, ["model"], "新增字段")
        XCTAssertEqual(preview.changed, ["baseURL"])
        XCTAssertEqual(preview.unchanged, ["unchangedField"])
    }

    func testUnknownFieldsReportedButNotApplied() {
        let unknown = ConfigurationImportExport.unknownFields(
            imported: ["baseURL", "model", "ghostField"],
            known: Set(["baseURL", "model"])
        )
        XCTAssertEqual(unknown, ["ghostField"], "未知字段保留报告不生效")
    }

    // MARK: - 导入状态

    func testImportedItemsUnifiedToNeedsVerificationOrNeedsEndpoint() {
        XCTAssertEqual(
            ConfigurationImportExport.importedProjectedState(hasEndpoint: true),
            .needsVerification,
            "导入项统一 NeedsVerification"
        )
        XCTAssertEqual(
            ConfigurationImportExport.importedProjectedState(hasEndpoint: false),
            .needsEndpoint,
            "无 endpoint 的导入项 NeedsEndpoint"
        )
    }

    func testImportNeverCarriesHiddenAuthorization() {
        XCTAssertFalse(ConfigurationImportExport.carriesHiddenAuthorization(), "永不携带隐藏授权")
    }

    // MARK: - 逐配置提交

    func testCommitReportPerConfigurationNoFalseSuccess() {
        let report = ConfigurationImportExport.commitReport(results: [
            "c-1": true, "c-2": false, "c-3": true
        ])
        XCTAssertEqual(report.succeeded, ["c-1", "c-3"])
        XCTAssertEqual(report.failed, ["c-2"], "单项失败不使其他项伪报成功")
        XCTAssertFalse(report.allSucceeded)
        XCTAssertEqual(
            ConfigurationImportExport.commitReport(results: ["c-1": true]).failed,
            [],
            "全部成功时 allSucceeded"
        )
    }
}
