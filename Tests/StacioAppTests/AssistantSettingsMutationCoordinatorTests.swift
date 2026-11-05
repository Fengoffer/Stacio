import Foundation
import XCTest
@testable import StacioApp

final class AssistantSettingsMutationCoordinatorTests: XCTestCase {
    func testRepeatedActionOnlyWritesUseDistinctDurableOperations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-operations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsDatabaseURL = directory.appendingPathComponent("settings.sqlite3")
        let registry = try AssistantSettingRegistry.standard()
        let valueStore = try XCTUnwrap(AssistantSettingsValueStore.inMemory(registry: registry))
        let coordinator = try AssistantSettingsMutationCoordinator(
            valueStore: valueStore,
            settingsDatabasePath: settingsDatabaseURL.path,
            controlDatabasePath: directory.appendingPathComponent("control.sqlite3").path,
            historyPruner: RecordingConversationHistoryPruner()
        )
        var results: [Result<Void, AssistantSettingsMutationError>] = []

        coordinator.write(
            settingID: "assistant.history.retention",
            value: .int(7),
            completion: { results.append($0) }
        )
        coordinator.write(
            settingID: "assistant.history.retention",
            value: .int(14),
            completion: { results.append($0) }
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy {
            if case .success = $0 { return true }
            return false
        })
        let operations = try settingsOperationIDs(databaseURL: settingsDatabaseURL)
        XCTAssertEqual(Set(operations).count, 2)
        XCTAssertTrue(operations.allSatisfy { $0.hasPrefix("assistant-settings-") })
    }
    func testRetentionWriteRemainsDurableWhenHistoryPruningFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = try AssistantSettingRegistry.standard()
        let valueStore = try XCTUnwrap(AssistantSettingsValueStore.inMemory(registry: registry))
        let pruner = ThrowingConversationHistoryPruner()
        let coordinator = try AssistantSettingsMutationCoordinator(
            valueStore: valueStore,
            settingsDatabasePath: directory.appendingPathComponent("settings.sqlite3").path,
            controlDatabasePath: directory.appendingPathComponent("control.sqlite3").path,
            historyPruner: pruner,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        var result: Result<Void, AssistantSettingsMutationError>?

        coordinator.write(
            settingID: "assistant.history.retention",
            value: .int(7),
            completion: { result = $0 }
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected history pruning failure")
        }
        XCTAssertEqual(error, .historyPruningFailed)
        XCTAssertEqual(try valueStore.value(for: "assistant.history.retention"), .int(7))
        XCTAssertEqual(pruner.cutoffs.count, 1)
    }
}

private final class RecordingConversationHistoryPruner: AIAssistantConversationHistoryPruning {
    func pruneConversationHistory(olderThan cutoff: Date) throws -> Int { 0 }
}

private func settingsOperationIDs(databaseURL: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
        databaseURL.path,
        "SELECT DISTINCT operation_id FROM assistant_settings_event WHERE kind = 'actionRequested' ORDER BY operation_id;"
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "StacioTests", code: Int(process.terminationStatus))
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).split(separator: "\n").map(String.init)
}

private final class ThrowingConversationHistoryPruner: AIAssistantConversationHistoryPruning {
    private(set) var cutoffs: [Date] = []

    func pruneConversationHistory(olderThan cutoff: Date) throws -> Int {
        cutoffs.append(cutoff)
        throw NSError(domain: "StacioTests", code: 1)
    }
}
