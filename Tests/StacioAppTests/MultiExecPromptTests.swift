import XCTest
@testable import StacioApp
import StacioCoreBindings

final class MultiExecPromptTests: XCTestCase {
    func testTargetPreviewRowsExposeChineseEnvironmentAndEnabledState() {
        let rows = MultiExecTargetPreviewRow.rows(for: [
            MultiExecTarget(id: "dev-1", label: "开发 API", environment: "development", enabled: true),
            MultiExecTarget(id: "prod-1", label: "生产 API", environment: "production", enabled: true),
            MultiExecTarget(id: "dead-1", label: "断开的终端", environment: "development", enabled: false)
        ])

        XCTAssertEqual(
            rows.map(\.summary),
            [
                "开发 API - 开发 - 可执行",
                "生产 API - 生产 - 可执行",
                "断开的终端 - 开发 - 不可用"
            ]
        )
        XCTAssertTrue(rows[1].requiresProductionConfirmation)
        XCTAssertFalse(rows[2].isEnabled)
    }

    func testBuiltInCommandSnippetsUseChineseTitles() {
        XCTAssertEqual(
            MultiExecCommandSnippet.builtIn,
            [
                MultiExecCommandSnippet(title: "系统概览", command: "uname -a"),
                MultiExecCommandSnippet(title: "磁盘占用", command: "df -h"),
                MultiExecCommandSnippet(title: "当前用户", command: "whoami")
            ]
        )
    }

    func testAppendingSnippetFillsEmptyPromptRequestInputWithoutExecuting() {
        let request = MultiExecPromptRequest(
            input: "",
            targetIDs: ["dev-1"],
            productionConfirmed: false
        )

        let updated = request.appendingSnippet(MultiExecCommandSnippet.builtIn[0])

        XCTAssertEqual(updated.input, "uname -a")
        XCTAssertEqual(updated.targetIDs, request.targetIDs)
        XCTAssertEqual(updated.productionConfirmed, request.productionConfirmed)
    }

    func testAppendingSnippetUsesNewlineWhenPromptRequestAlreadyHasInput() {
        let request = MultiExecPromptRequest(
            input: "uptime",
            targetIDs: ["prod-1"],
            productionConfirmed: true
        )

        let updated = request.appendingSnippet(MultiExecCommandSnippet.builtIn[1])

        XCTAssertEqual(updated.input, "uptime\ndf -h")
        XCTAssertEqual(updated.targetIDs, request.targetIDs)
        XCTAssertEqual(updated.productionConfirmed, request.productionConfirmed)
    }

    func testSavedMacroBuildsPromptCommandsFromPlaybackStepsInOrder() {
        let macro = MultiExecSavedMacro(recording: MacroRecording(
            id: "deploy-check",
            name: "部署检查",
            steps: [
                MacroStep(order: 3, input: "tail -n 50 /var/log/app.log", delayMs: 0),
                MacroStep(order: 1, input: "whoami", delayMs: 0),
                MacroStep(order: 2, input: "pwd", delayMs: 0)
            ]
        ))

        XCTAssertEqual(macro.title, "部署检查")
        XCTAssertEqual(macro.commandText, "whoami\npwd\ntail -n 50 /var/log/app.log")
    }

    func testAppendingMacroUsesNewlineWhenPromptRequestAlreadyHasInput() {
        let request = MultiExecPromptRequest(
            input: "uptime",
            targetIDs: ["dev-1"],
            productionConfirmed: false
        )
        let macro = MultiExecSavedMacro(
            id: "macro-1",
            title: "巡检",
            playbackSteps: [
                MacroStep(order: 2, input: "df -h", delayMs: 0),
                MacroStep(order: 1, input: "uname -a", delayMs: 0)
            ]
        )

        let updated = request.appendingMacro(macro)

        XCTAssertEqual(updated.input, "uptime\nuname -a\ndf -h")
        XCTAssertEqual(updated.targetIDs, request.targetIDs)
        XCTAssertEqual(updated.productionConfirmed, request.productionConfirmed)
    }

    func testSavedMacroKeepsChineseTitleAndRedactsSecretCommandValues() {
        let macro = MultiExecSavedMacro(recording: MacroRecording(
            id: "secret-check",
            name: "部署密钥检查",
            steps: [
                MacroStep(order: 1, input: "export TOKEN=secret-value", delayMs: 0),
                MacroStep(order: 2, input: "echo done", delayMs: 0)
            ]
        ))

        XCTAssertEqual(macro.title, "部署密钥检查")
        XCTAssertEqual(macro.commandText, "export [redacted]\necho done")
        XCTAssertFalse(macro.commandText.contains("secret-value"))
    }

    func testSavedMacroRedactsCredentialStyleCommandValues() {
        let macro = MultiExecSavedMacro(recording: MacroRecording(
            id: "credential-check",
            name: "凭据检查",
            steps: [
                MacroStep(
                    order: 1,
                    input: "export PASSWORD=prod-password CREDENTIAL=deploy-token",
                    delayMs: 0
                ),
                MacroStep(
                    order: 2,
                    input: "ssh -i /Users/alice/.ssh/id_ed25519 PASSPHRASE=key-passphrase host",
                    delayMs: 0
                )
            ]
        ))

        XCTAssertFalse(macro.commandText.contains("prod-password"))
        XCTAssertFalse(macro.commandText.contains("deploy-token"))
        XCTAssertFalse(macro.commandText.contains("key-passphrase"))
        XCTAssertFalse(macro.commandText.contains("/Users/alice/.ssh/id_ed25519"))
    }

    func testSavedMacroRedactsBearerCredentialValues() {
        let macro = MultiExecSavedMacro(recording: MacroRecording(
            id: "bearer-check",
            name: "Bearer 凭据检查",
            steps: [
                MacroStep(
                    order: 1,
                    input: "curl -H Authorization: Bearer sk-live-123456 https://api.example.com",
                    delayMs: 0
                ),
                MacroStep(
                    order: 2,
                    input: "curl -H Authorization:Bearer sk-live-abcdef https://api.example.com",
                    delayMs: 0
                )
            ]
        ))

        XCTAssertEqual(
            macro.commandText,
            "curl -H Authorization: Bearer [redacted] https://api.example.com\ncurl -H Authorization:Bearer [redacted] https://api.example.com"
        )
        XCTAssertFalse(macro.commandText.contains("sk-live-123456"))
        XCTAssertFalse(macro.commandText.contains("sk-live-abcdef"))
    }
}
