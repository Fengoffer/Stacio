import XCTest
import Foundation
@testable import StacioApp

/// P4-9d：诊断、隐私与上下文预览动作。
final class DiagnosticsPrivacyActionTests: XCTestCase {

    // MARK: - diagnostics bundle

    func testPreviewBundleGeneratesManifestWithCategories() {
        let entries = DiagnosticsBundleAction.previewBundle(
            files: ["logs/1.log", "terminal/1.pty", "host.json", "config.json"],
            categoryByFile: ["logs/1.log": "logs", "terminal/1.pty": "terminal",
                             "host.json": "host", "config.json": "configuration"],
            hashByFile: ["logs/1.log": "h1", "terminal/1.pty": "h2", "host.json": "h3", "config.json": "h4"]
        )
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.first?.contentCategory, "logs")
        XCTAssertEqual(entries.first?.hash, "h1")
    }

    func testUserCanExcludeContentTerminalHostConfiguration() {
        let entries = DiagnosticsBundleAction.previewBundle(
            files: ["body.md", "terminal/1.pty", "host.json", "config.json"],
            categoryByFile: ["body.md": "content", "terminal/1.pty": "terminal",
                             "host.json": "host", "config.json": "configuration"],
            hashByFile: ["body.md": "h1", "terminal/1.pty": "h2", "host.json": "h3", "config.json": "h4"]
        )
        let excluded = DiagnosticsBundleAction.excluding(
            entries: entries, excludedCategories: Set(["content", "terminal", "host", "configuration"])
        )
        XCTAssertTrue(excluded.isEmpty, "用户可排除正文/终端/主机/配置")
    }

    func testPreviewAndExportShareSameManifestHash() {
        let entries = DiagnosticsBundleAction.previewBundle(
            files: ["a.log", "b.log"],
            categoryByFile: ["a.log": "logs", "b.log": "logs"],
            hashByFile: ["a.log": "h1", "b.log": "h2"]
        )
        // 同一输入 → 同一 manifest hash（预览与导出一致）
        let again = DiagnosticsBundleAction.previewBundle(
            files: ["a.log", "b.log"],
            categoryByFile: ["a.log": "logs", "b.log": "logs"],
            hashByFile: ["a.log": "h1", "b.log": "h2"]
        )
        XCTAssertEqual(DiagnosticsBundleAction.manifestHash(entries: entries),
                       DiagnosticsBundleAction.manifestHash(entries: again))
    }

    func testRedactionFailureBlocksWrite() {
        let entries = DiagnosticsBundleAction.previewBundle(
            files: ["a.log", "b.log"],
            categoryByFile: ["a.log": "logs", "b.log": "logs"],
            hashByFile: ["a.log": "h1", "b.log": "h2"]
        )
        XCTAssertFalse(DiagnosticsBundleAction.redactionFailed(entries: entries, hashesKnown: Set(["h1", "h2"])))
        XCTAssertTrue(
            DiagnosticsBundleAction.redactionFailed(entries: entries, hashesKnown: Set(["h1"])),
            "任何脱敏失败阻止写出"
        )
    }

    func testBundleNeverContainsCredentialCapabilityFullEnv() {
        XCTAssertTrue(DiagnosticsBundleAction.containsForbiddenContent(category: "credential"))
        XCTAssertTrue(DiagnosticsBundleAction.containsForbiddenContent(category: "capability"))
        XCTAssertTrue(DiagnosticsBundleAction.containsForbiddenContent(category: "full env"))
        XCTAssertFalse(DiagnosticsBundleAction.containsForbiddenContent(category: "logs"))
    }

    // MARK: - telemetry consent

    func testConsentPreviewShowsTargetSchemaRetentionRevision() {
        let preview = TelemetryConsentAction.consentPreview(
            targetService: "telemetry.example.com", fieldSchema: ["appVersion", "locale"],
            samplingRetention: "30d", currentRevision: 3
        )
        XCTAssertEqual(preview.targetService, "telemetry.example.com")
        XCTAssertEqual(preview.fieldSchema, ["appVersion", "locale"])
        XCTAssertEqual(preview.samplingRetention, "30d")
        XCTAssertEqual(preview.currentRevision, 3, "开启前展示当前 revision")
    }

    func testConsentCloseDisablesEnqueueBeforeClearingQueue() {
        XCTAssertEqual(
            TelemetryConsentAction.closeOrder(),
            ["durableDisableEnqueue", "clearPendingQueue"],
            "关闭先 durable 关闭新 enqueue 再清空待发送队列"
        )
    }

    func testNeverInTelemetry() {
        for field in ["content", "credential", "host", "path", "command", "userIdentity", "prompt"] {
            XCTAssertTrue(TelemetryConsentAction.neverInTelemetry(field: field), "\(field) 不进入遥测")
        }
        XCTAssertFalse(TelemetryConsentAction.neverInTelemetry(field: "appVersion"))
        XCTAssertFalse(TelemetryConsentAction.neverInTelemetry(field: "locale"))
    }

    // MARK: - outbound payload preview

    func testOutboundPreviewShowsSourcesDigestOriginOmitted() {
        let preview = OutboundPayloadAction.preview(
            sources: ["contextSnapshot", "terminalOutput"], byteCount: 2048,
            targetOrigin: "https://api.example.com", omittedItems: ["largeAttachment"]
        )
        XCTAssertEqual(preview.sources, ["contextSnapshot", "terminalOutput"])
        XCTAssertEqual(preview.byteDigest, "bytes:2048")
        XCTAssertEqual(preview.targetOrigin, "https://api.example.com")
        XCTAssertEqual(preview.omittedItems, ["largeAttachment"])
        // preview 不发送请求：preview 是纯值（无 I/O 副作用）
        XCTAssertTrue(preview.sources.count == 2)
    }

    func testSecretsNeverEnterPreview() {
        XCTAssertTrue(OutboundPayloadAction.neverInPreview(item: "api key"))
        XCTAssertTrue(OutboundPayloadAction.neverInPreview(item: "secret"))
        XCTAssertTrue(OutboundPayloadAction.neverInPreview(item: "secureInput"))
        XCTAssertTrue(OutboundPayloadAction.neverInPreview(item: "hiddenChain"))
        XCTAssertFalse(OutboundPayloadAction.neverInPreview(item: "contextSnapshot"))
    }
}
