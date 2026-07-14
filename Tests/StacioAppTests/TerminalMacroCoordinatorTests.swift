import AppKit
import StacioAgentBridge
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class TerminalMacroCoordinatorTests: XCTestCase {
    func testSQLiteMetadataStoreAddsMetadataColumnAndPersistsMacroGroup() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioTerminalMacroMetadataTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let macroStore = CoreBridgeTerminalMacroStore(databasePath: databaseURL.path)
        let created = try macroStore.createMacro(
            name: "Deploy",
            commands: ["whoami"],
            delayMS: 300
        )

        let metadataStore = try SQLiteTerminalMacroMetadataStore(databasePath: databaseURL.path)
        try metadataStore.setMetadata(TerminalMacroMetadata(group: "部署"), forMacroID: created.id)
        let reopened = try SQLiteTerminalMacroMetadataStore(databasePath: databaseURL.path)

        XCTAssertEqual(try reopened.metadata(forMacroID: created.id).group, "部署")
        XCTAssertEqual(try macroStore.listMacros().map(\.id), [created.id])
    }

    func testExportCoordinatorEncodesNameCommandsAndGroupJSON() throws {
        let metadataStore = RecordingTerminalMacroMetadataStore()
        let macroStore = RecordingTerminalMacroImportStore(records: [
            TerminalMacroRecord(
                id: "macro_1",
                name: "部署检查",
                steps: [
                    MacroStep(order: 2, input: "pwd", delayMs: 300),
                    MacroStep(order: 1, input: "whoami", delayMs: 300)
                ],
                createdAt: "2026-07-03T00:00:00Z",
                updatedAt: "2026-07-03T00:00:00Z"
            )
        ])
        try metadataStore.setMetadata(TerminalMacroMetadata(group: "部署"), forMacroID: "macro_1")
        let coordinator = TerminalMacroImportExportCoordinator(
            macroStore: macroStore,
            metadataStore: metadataStore
        )

        let data = try coordinator.exportData(macros: try macroStore.listMacros())
        let items = try JSONDecoder().decode([TerminalMacroJSONItem].self, from: data)

        XCTAssertEqual(
            items,
            [
                TerminalMacroJSONItem(
                    name: "部署检查",
                    commands: ["whoami", "pwd"],
                    group: "部署"
                )
            ]
        )
    }

    func testImportCoordinatorAppliesSkipOverwriteAndRenameConflictPolicies() throws {
        let existing = TerminalMacroRecord(
            id: "macro_1",
            name: "Deploy",
            steps: [MacroStep(order: 1, input: "whoami", delayMs: 300)],
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
        let macroStore = RecordingTerminalMacroImportStore(records: [existing])
        let metadataStore = RecordingTerminalMacroMetadataStore()
        let coordinator = TerminalMacroImportExportCoordinator(
            macroStore: macroStore,
            metadataStore: metadataStore
        )
        let importItems = [
            TerminalMacroJSONItem(name: "Deploy", commands: ["skip"], group: "跳过"),
            TerminalMacroJSONItem(name: "Deploy", commands: ["systemctl restart app"], group: "覆盖"),
            TerminalMacroJSONItem(name: "Deploy", commands: ["tail -f app.log"], group: "重命名")
        ]
        let data = try JSONEncoder().encode(importItems)

        let result = try coordinator.importData(data) { item, _ in
            switch item.group {
            case "跳过":
                return .skip
            case "覆盖":
                return .overwrite
            default:
                return .rename
            }
        }

        XCTAssertEqual(result.createdCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.overwrittenCount, 1)
        XCTAssertEqual(result.renamedCount, 1)
        XCTAssertEqual(macroStore.records.map(\.name), ["Deploy", "Deploy 2"])
        XCTAssertEqual(macroStore.records[0].steps.map(\.input), ["systemctl restart app"])
        XCTAssertEqual(macroStore.records[1].steps.map(\.input), ["tail -f app.log"])
        XCTAssertEqual(try metadataStore.metadata(forMacroID: "macro_1").group, "覆盖")
        XCTAssertEqual(try metadataStore.metadata(forMacroID: "macro_2").group, "重命名")
    }

    func testCoreBridgeTerminalMacroStorePersistsCrudAndRedactsCommands() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioTerminalMacroStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = CoreBridgeTerminalMacroStore(databasePath: databaseURL.path)

        let created = try store.createMacro(
            name: "Deploy",
            commands: ["whoami", "export TOKEN=sk-live-123"],
            delayMS: 300
        )
        let listed = try store.listMacros()
        XCTAssertEqual(listed.map(\.id), [created.id])
        XCTAssertEqual(listed[0].name, "Deploy")
        XCTAssertEqual(listed[0].steps.map(\.input), ["whoami", "export [redacted]"])
        XCTAssertFalse(listed[0].steps.map(\.input).joined(separator: "\n").contains("sk-live-123"))

        let renamed = try store.renameMacro(id: created.id, name: "Deploy staging")
        XCTAssertEqual(renamed.name, "Deploy staging")

        let updated = try store.updateMacro(
            id: created.id,
            name: "Deploy prod",
            commands: ["pwd"],
            delayMS: 300
        )
        XCTAssertEqual(updated.name, "Deploy prod")
        XCTAssertEqual(updated.steps.map(\.input), ["pwd"])

        try store.deleteMacro(id: created.id)
        XCTAssertTrue(try store.listMacros().isEmpty)
    }

    func testRecordingCollectsSubmittedCommandsAndPersistsRedactedMacro() throws {
        let store = RecordingTerminalMacroStore()
        let recorder = TerminalMacroRecorder(store: store)

        recorder.startRecording()
        recorder.recordSubmittedCommand("whoami")
        recorder.recordSubmittedCommand("export TOKEN=sk-live-123")
        let saved = try recorder.stopRecording(name: "Bootstrap")

        XCTAssertEqual(saved?.name, "Bootstrap")
        XCTAssertEqual(store.createdNames, ["Bootstrap"])
        XCTAssertEqual(store.createdSteps.first?.input, "whoami")
        XCTAssertEqual(store.createdSteps.last?.input, "export [redacted]")
        XCTAssertFalse(store.createdSteps.map(\.input).joined(separator: "\n").contains("sk-live-123"))
        XCTAssertFalse(recorder.isRecording)
    }

    func testPlaybackWritesCommandsToTerminalWithFixedDelay() {
        let target = RecordingTerminalMacroPlaybackTarget()
        let scheduler = RecordingTerminalMacroPlaybackScheduler()
        let confirmer = RecordingTerminalMacroRiskConfirmer()
        let presenter = RecordingTerminalMacroMessagePresenter()
        let player = TerminalMacroPlaybackCoordinator(
            scheduler: scheduler,
            riskConfirmer: confirmer,
            messagePresenter: presenter
        )
        let macro = TerminalMacroRecord(
            id: "macro_1",
            name: "Inspect",
            steps: [
                MacroStep(order: 1, input: "whoami", delayMs: 300),
                MacroStep(order: 2, input: "pwd", delayMs: 300)
            ],
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )

        let result = player.play(macro: macro, target: target, parentWindow: nil)

        XCTAssertEqual(result, .started)
        XCTAssertEqual(target.sentTexts, ["whoami\n"])
        XCTAssertEqual(scheduler.scheduledDelays, [0.3])
        scheduler.runNext()
        XCTAssertEqual(target.sentTexts, ["whoami\n", "pwd\n"])
        XCTAssertFalse(confirmer.wasAsked)
        XCTAssertTrue(presenter.messages.isEmpty)
    }

    func testPlaybackShowsFriendlyMessageWhenNoTerminalIsAvailable() {
        let presenter = RecordingTerminalMacroMessagePresenter()
        let player = TerminalMacroPlaybackCoordinator(messagePresenter: presenter)
        let macro = TerminalMacroRecord(
            id: "macro_1",
            name: "Inspect",
            steps: [MacroStep(order: 1, input: "whoami", delayMs: 300)],
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )

        let result = player.play(macro: macro, target: nil, parentWindow: nil)

        XCTAssertEqual(result, .noTerminal)
        XCTAssertEqual(presenter.messages.map(\.title), [L10n.TerminalMacro.noTerminalTitle])
    }

    func testDestructivePlaybackRequiresConfirmationBeforeSending() {
        let target = RecordingTerminalMacroPlaybackTarget()
        let scheduler = RecordingTerminalMacroPlaybackScheduler()
        let confirmer = RecordingTerminalMacroRiskConfirmer()
        confirmer.nextResult = false
        let player = TerminalMacroPlaybackCoordinator(
            scheduler: scheduler,
            riskConfirmer: confirmer
        )
        let macro = TerminalMacroRecord(
            id: "macro_1",
            name: "Danger",
            steps: [MacroStep(order: 1, input: "rm -rf /tmp/build", delayMs: 300)],
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )

        let result = player.play(macro: macro, target: target, parentWindow: nil)

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(confirmer.wasAsked)
        XCTAssertEqual(confirmer.confirmedRisk, .destructive)
        XCTAssertTrue(target.sentTexts.isEmpty)
    }
}

private final class RecordingTerminalMacroStore: TerminalMacroStoring {
    var createdNames: [String] = []
    var createdSteps: [MacroStep] = []

    func listMacros() throws -> [TerminalMacroRecord] {
        []
    }

    func createMacro(name: String, commands: [String], delayMS: UInt32) throws -> TerminalMacroRecord {
        createdNames.append(name)
        createdSteps = commands.enumerated().map { index, command in
            MacroStep(
                order: UInt32(index + 1),
                input: AgentProtocolRedaction.redact(command),
                delayMs: delayMS
            )
        }
        return TerminalMacroRecord(
            id: "macro_1",
            name: name,
            steps: createdSteps,
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
    }

    func updateMacro(id: String, name: String, commands: [String], delayMS: UInt32) throws -> TerminalMacroRecord {
        TerminalMacroRecord(
            id: id,
            name: name,
            steps: commands.enumerated().map { index, command in
                MacroStep(order: UInt32(index + 1), input: command, delayMs: delayMS)
            },
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
    }

    func renameMacro(id: String, name: String) throws -> TerminalMacroRecord {
        TerminalMacroRecord(
            id: id,
            name: name,
            steps: createdSteps,
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
    }

    func deleteMacro(id: String) throws {}
}

private final class RecordingTerminalMacroImportStore: TerminalMacroStoring {
    var records: [TerminalMacroRecord]
    private var nextID = 2

    init(records: [TerminalMacroRecord]) {
        self.records = records
    }

    func listMacros() throws -> [TerminalMacroRecord] {
        records
    }

    func createMacro(name: String, commands: [String], delayMS: UInt32) throws -> TerminalMacroRecord {
        let record = TerminalMacroRecord(
            id: "macro_\(nextID)",
            name: name,
            steps: commands.enumerated().map { index, command in
                MacroStep(order: UInt32(index + 1), input: command, delayMs: delayMS)
            },
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
        nextID += 1
        records.append(record)
        return record
    }

    func updateMacro(id: String, name: String, commands: [String], delayMS: UInt32) throws -> TerminalMacroRecord {
        let updated = TerminalMacroRecord(
            id: id,
            name: name,
            steps: commands.enumerated().map { index, command in
                MacroStep(order: UInt32(index + 1), input: command, delayMs: delayMS)
            },
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "RecordingTerminalMacroImportStore", code: 1)
        }
        records[index] = updated
        return updated
    }

    func renameMacro(id: String, name: String) throws -> TerminalMacroRecord {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "RecordingTerminalMacroImportStore", code: 1)
        }
        let existing = records[index]
        let renamed = TerminalMacroRecord(
            id: existing.id,
            name: name,
            steps: existing.steps,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt
        )
        records[index] = renamed
        return renamed
    }

    func deleteMacro(id: String) throws {
        records.removeAll { $0.id == id }
    }
}

private final class RecordingTerminalMacroMetadataStore: TerminalMacroMetadataStoring {
    private var metadataByID: [String: TerminalMacroMetadata] = [:]

    func metadata(forMacroID macroID: String) throws -> TerminalMacroMetadata {
        metadataByID[macroID] ?? TerminalMacroMetadata()
    }

    func setMetadata(_ metadata: TerminalMacroMetadata, forMacroID macroID: String) throws {
        metadataByID[macroID] = metadata
    }
}

private final class RecordingTerminalMacroPlaybackTarget: TerminalMacroPlaybackTarget {
    private(set) var sentTexts: [String] = []

    func sendInput(_ bytes: [UInt8]) {
        sentTexts.append(String(decoding: bytes, as: UTF8.self))
    }
}

private final class RecordingTerminalMacroPlaybackScheduler: TerminalMacroPlaybackScheduling {
    private var blocks: [() -> Void] = []
    private(set) var scheduledDelays: [TimeInterval] = []

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        scheduledDelays.append(delay)
        blocks.append(block)
    }

    func runNext() {
        blocks.removeFirst()()
    }
}

private final class RecordingTerminalMacroRiskConfirmer: TerminalMacroRiskConfirming {
    var nextResult = true
    private(set) var wasAsked = false
    private(set) var confirmedRisk: AgentActionRisk?

    func confirmDangerousMacro(_ macro: TerminalMacroRecord, risk: AgentActionRisk, parentWindow: NSWindow?) -> Bool {
        wasAsked = true
        confirmedRisk = risk
        return nextResult
    }
}

private final class RecordingTerminalMacroMessagePresenter: TerminalMacroMessagePresenting {
    private(set) var messages: [(title: String, message: String)] = []

    func presentMacroMessage(title: String, message: String, parentWindow: NSWindow?) {
        messages.append((title, message))
    }
}
