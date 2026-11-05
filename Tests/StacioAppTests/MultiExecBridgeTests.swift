import XCTest
@testable import StacioApp
import StacioCoreBindings

final class MultiExecBridgeTests: XCTestCase {
    func testProductionBroadcastRequiresConfirmationFromSwift() {
        let targets = [
            MultiExecTarget(
                id: "term_1",
                label: "prod",
                environment: "production",
                enabled: true
            )
        ]

        XCTAssertThrowsError(
            try CoreBridge.prepareBroadcastInput(
                targets: targets,
                input: "uptime",
                productionConfirmed: false
            )
        )
    }

    func testProductionBroadcastWithWhitespaceEnvironmentRequiresConfirmationFromSwift() {
        let targets = [
            MultiExecTarget(
                id: "term_1",
                label: "prod",
                environment: " production ",
                enabled: true
            )
        ]

        XCTAssertThrowsError(
            try CoreBridge.prepareBroadcastInput(
                targets: targets,
                input: "uptime",
                productionConfirmed: false
            )
        )
    }

    func testPreparedBroadcastStartsUnexecutedWithZeroCountsFromSwift() throws {
        let targets = [
            MultiExecTarget(
                id: "term_1",
                label: "开发",
                environment: "development",
                enabled: true
            )
        ]

        let event = try CoreBridge.prepareBroadcastInput(
            targets: targets,
            input: "uptime",
            productionConfirmed: false
        )

        XCTAssertEqual(event.targetCount, 1)
        XCTAssertEqual(event.sentCount, 0)
        XCTAssertEqual(event.failedCount, 0)
        XCTAssertFalse(event.executed)
    }

    func testPreparedBroadcastDeduplicatesRepeatedTargetIDsFromSwift() throws {
        let targets = [
            MultiExecTarget(
                id: "term_1",
                label: "开发",
                environment: "development",
                enabled: true
            ),
            MultiExecTarget(
                id: "term_2",
                label: "预发",
                environment: "development",
                enabled: true
            ),
            MultiExecTarget(
                id: "term_1",
                label: "开发重复项",
                environment: "development",
                enabled: true
            )
        ]

        let event = try CoreBridge.prepareBroadcastInput(
            targets: targets,
            input: "uptime",
            productionConfirmed: false
        )

        XCTAssertEqual(event.targetCount, 2)
        XCTAssertEqual(event.sentCount, 0)
        XCTAssertEqual(event.failedCount, 0)
    }

    func testMarkBroadcastExecutedRecordsSentAndFailedCountsFromSwift() throws {
        let targets = [
            MultiExecTarget(
                id: "term_1",
                label: "开发",
                environment: "development",
                enabled: true
            ),
            MultiExecTarget(
                id: "term_2",
                label: "生产",
                environment: "production",
                enabled: true
            )
        ]
        let prepared = try CoreBridge.prepareBroadcastInput(
            targets: targets,
            input: "export TOKEN=secret-value",
            productionConfirmed: true
        )

        let event = CoreBridge.markBroadcastExecuted(prepared, sentCount: 1)

        XCTAssertEqual(event.targetCount, 2)
        XCTAssertEqual(event.sentCount, 1)
        XCTAssertEqual(event.failedCount, 1)
        XCTAssertTrue(event.executed)
        XCTAssertFalse(event.redactedInput.contains("secret-value"))
    }

    func testBroadcastAuditRecordsPersistThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let prepared = try CoreBridge.prepareBroadcastInput(
            targets: [
                MultiExecTarget(
                    id: "term_1",
                    label: "生产",
                    environment: "production",
                    enabled: true
                )
            ],
            input: "export TOKEN=secret-value",
            productionConfirmed: true
        )
        let executed = CoreBridge.markBroadcastExecuted(prepared, sentCount: 1)

        let recorded = try CoreBridge.recordBroadcastAuditEvent(
            databasePath: tempURL.path,
            event: executed
        )
        let records = try CoreBridge.listBroadcastAuditRecords(
            databasePath: tempURL.path,
            limit: 10
        )

        XCTAssertEqual(records, [recorded])
        XCTAssertEqual(recorded.targetCount, 1)
        XCTAssertEqual(recorded.sentCount, 1)
        XCTAssertEqual(recorded.failedCount, 0)
        XCTAssertTrue(recorded.executed)
        XCTAssertFalse(recorded.redactedInput.contains("secret-value"))
    }

    func testMacroSerializationRedactsSecretsFromSwift() throws {
        let recording = MacroRecording(
            id: "macro_1",
            name: "Deploy",
            steps: [
                MacroStep(order: 1, input: "export TOKEN=secret-value", delayMs: 0)
            ]
        )

        let json = try CoreBridge.serializeMacroRecording(recording)

        XCTAssertTrue(json.contains("Deploy"))
        XCTAssertFalse(json.contains("secret-value"))
        XCTAssertTrue(json.contains("[redacted]"))
    }

    func testMacroPlaybackStepsAreOrderedFromSwift() {
        let recording = MacroRecording(
            id: "macro_1",
            name: "Deploy",
            steps: [
                MacroStep(order: 2, input: "second", delayMs: 0),
                MacroStep(order: 1, input: "first", delayMs: 0)
            ]
        )

        let steps = CoreBridge.playbackMacroSteps(recording)

        XCTAssertEqual(steps.map(\.input), ["first", "second"])
    }
}
