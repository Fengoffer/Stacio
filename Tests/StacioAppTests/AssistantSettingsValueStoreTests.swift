import AppKit
import XCTest
@testable import StacioApp

final class AssistantSettingsValueStoreTests: XCTestCase {
    private struct StaticMasterKey: ConversationMasterKeyProviding {
        let data: Data
        func masterKeyData() throws -> Data { data }
    }

    private func makeStore(
        fileURL: URL,
        key: ConversationMasterKeyProviding? = StaticMasterKey(data: Data(repeating: 7, count: 32))
    ) throws -> AssistantSettingsValueStore {
        try AssistantSettingsValueStore(
            registry: try AssistantSettingRegistry.standard(),
            fileURL: fileURL,
            masterKeyProvider: key
        )
    }

    func testScalarValuePersistsAcrossRestartAndUsesRegistryDefaultWhenMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-values-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try makeStore(fileURL: url)
        XCTAssertEqual(try first.value(for: "assistant.general.localAutoTitle"), .bool(true))
        XCTAssertEqual(
            try first.write(id: "assistant.general.localAutoTitle", value: .bool(false)),
            1
        )

        let reopened = try makeStore(fileURL: url)
        XCTAssertEqual(try reopened.value(for: "assistant.general.localAutoTitle"), .bool(false))
        XCTAssertEqual(try reopened.storedValue(for: "assistant.general.localAutoTitle"), .bool(false))
    }

    func testSensitiveValueIsSealedAndRestoredAcrossRestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-sensitive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let secret = "do not expose this instruction"

        let first = try makeStore(fileURL: url)
        try first.write(id: "assistant.instructions.globalText", value: .string(secret))
        let raw = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(secret))

        let reopened = try makeStore(fileURL: url)
        XCTAssertEqual(try reopened.value(for: "assistant.instructions.globalText"), .string(secret))
    }

    func testRuntimeSnapshotResolvesCustomizedDurableValues() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-runtime-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeStore(fileURL: url)
        let runtimeID = UUID().uuidString

        try store.write(id: "assistant.general.defaultRuntime", value: .string(runtimeID))
        try store.write(id: "assistant.general.defaultWorkMode", value: .string("plan"))
        try store.write(id: "assistant.general.defaultReasoningEffort", value: .string("high"))
        try store.write(id: "assistant.general.queueAutoAdvance", value: .bool(false))
        try store.write(id: "assistant.general.sendKeyMode", value: .string("commandReturn"))
        try store.write(
            id: "assistant.execution.defaultTerminalMode",
            value: .string("backgroundVirtualTerminal")
        )
        try store.write(id: "assistant.execution.maxToolSteps", value: .int(17))
        try store.write(id: "assistant.instructions.globalText", value: .string("Prefer read-only checks."))
        try store.write(id: "assistant.context.terminalOutputMode", value: .string("excluded"))
        try store.write(id: "assistant.context.autoCompression", value: .bool(false))
        try store.write(id: "assistant.tools.enabledToolIDs", value: .stringArray(["terminal.read"]))

        let snapshot = try AssistantRuntimeSettingsSnapshot.resolve(from: store)

        XCTAssertEqual(snapshot.defaultRuntimeConfigurationID, runtimeID)
        XCTAssertEqual(snapshot.defaultWorkMode, .plan)
        XCTAssertEqual(snapshot.defaultReasoningEffort, .high)
        XCTAssertFalse(snapshot.queueAutoAdvanceEnabled)
        XCTAssertEqual(snapshot.sendKeyMode, "commandReturn")
        XCTAssertEqual(snapshot.defaultTerminalMode, "backgroundVirtualTerminal")
        XCTAssertEqual(snapshot.maxToolSteps, 17)
        XCTAssertEqual(snapshot.globalInstructions, "Prefer read-only checks.")
        XCTAssertEqual(snapshot.terminalOutputMode, "excluded")
        XCTAssertFalse(snapshot.automaticContextCompressionEnabled)
        XCTAssertEqual(snapshot.enabledToolIDs, ["terminal.read"])
        XCTAssertNotNil(snapshot.instructionDigest)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AssistantRuntimeSettingsSnapshot.self,
                from: Data(try snapshot.encoded().utf8)
            ),
            snapshot
        )
    }

    func testRuntimeSnapshotFailsClosedWhenAnyDurableValueIsInconsistent() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-runtime-corrupt-\(UUID().uuidString).sqlite3")
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-runtime-corrupt-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        let backend = try AssistantSettingsStoreBackend(databasePath: databaseURL.path)
        let store = try AssistantSettingsValueStore(
            registry: try AssistantSettingRegistry.standard(),
            backend: backend,
            fileURL: sidecarURL,
            masterKeyProvider: StaticMasterKey(data: Data(repeating: 7, count: 32))
        )
        try store.write(id: "assistant.general.defaultWorkMode", value: .string("plan"))
        try backend.upsert(
            key: "assistant.general.defaultWorkMode",
            expectedRevision: 1,
            valueDigest: "sha256:tampered",
            scope: "sessionDefault",
            migrationKey: "assistant.general.defaultWorkMode.v1"
        )

        XCTAssertThrowsError(try AssistantRuntimeSettingsSnapshot.resolve(from: store)) { error in
            guard case .unreadableSetting = error as? AssistantRuntimeSettingsSnapshotError else {
                return XCTFail("损坏的 durable 设置必须阻断整个 Runtime 快照：\(error)")
            }
        }
    }

    func testSensitiveWriteFailsClosedWithoutMasterKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-no-key-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeStore(fileURL: url, key: nil)

        XCTAssertThrowsError(
            try store.write(id: "assistant.instructions.globalText", value: .string("secret"))
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsValueStoreError, .missingMasterKey("assistant.instructions.globalText"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testActionOnlySettingsCannotBeWrittenByValueStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-policy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeStore(fileURL: url)

        XCTAssertThrowsError(
            try store.write(id: "provider.demo.customHeaders", value: .structured(Data("{}".utf8)))
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsValueStoreError, .actionOnly("provider.demo.customHeaders"))
        }
        XCTAssertThrowsError(
            try store.write(id: "assistant.history.retention", value: .int(7))
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsValueStoreError, .actionOnly("assistant.history.retention"))
        }
    }

    func testActionOnlySettingsRequireTheMatchingActionBinding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-action-binding-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeStore(fileURL: url)

        XCTAssertThrowsError(try store.writeActionValue(
            id: "assistant.history.retention",
            value: .int(7),
            actionID: "configuration.saveDraft"
        )) { error in
            XCTAssertEqual(error as? AssistantSettingsValueStoreError, .actionOnly("assistant.history.retention"))
        }
        XCTAssertEqual(
            try store.writeActionValue(
                id: "assistant.history.retention",
                value: .int(7),
                actionID: "history.changeRetention"
            ),
            1
        )
        XCTAssertEqual(try store.value(for: "assistant.history.retention"), .int(7))
    }

    func testBackendOnlyRecordFailsClosedOnRestart() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-backend-only-\(UUID().uuidString).sqlite3")
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-backend-only-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        let descriptor = try XCTUnwrap(
            AssistantSettingRegistry.standard().descriptor(for: "assistant.general.localAutoTitle")
        )
        let backend = try AssistantSettingsStoreBackend(databasePath: databaseURL.path)
        try backend.upsert(
            key: descriptor.id,
            expectedRevision: nil,
            valueDigest: "sha256:orphaned",
            scope: descriptor.scope.rawValue,
            migrationKey: descriptor.migrationKey
        )

        XCTAssertThrowsError(try makeStoreWithBackend(databaseURL: databaseURL, sidecarURL: sidecarURL)) { error in
            guard case .consistencyMismatch = error as? AssistantSettingsValueStoreError else {
                return XCTFail("backend-only record must fail closed, got \(error)")
            }
        }
    }

    func testSidecarOnlyRecordFailsClosedOnRestart() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-sidecar-only-\(UUID().uuidString).sqlite3")
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-sidecar-only-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        let detached = try makeStore(fileURL: sidecarURL)
        try detached.write(id: "assistant.general.localAutoTitle", value: .bool(false))
        XCTAssertThrowsError(try makeStoreWithBackend(databaseURL: databaseURL, sidecarURL: sidecarURL)) { error in
            guard case .consistencyMismatch = error as? AssistantSettingsValueStoreError else {
                return XCTFail("sidecar-only record must fail closed, got \(error)")
            }
        }
    }

    func testRevisionOrDigestMismatchFailsClosedOnRestart() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-mismatch-\(UUID().uuidString).sqlite3")
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-mismatch-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        let backend = try AssistantSettingsStoreBackend(databasePath: databaseURL.path)
        let store = try AssistantSettingsValueStore(
            registry: try AssistantSettingRegistry.standard(),
            backend: backend,
            fileURL: sidecarURL,
            masterKeyProvider: StaticMasterKey(data: Data(repeating: 7, count: 32))
        )
        try store.write(id: "assistant.general.localAutoTitle", value: .bool(false))
        try backend.upsert(
            key: "assistant.general.localAutoTitle",
            expectedRevision: 1,
            valueDigest: "sha256:changed-outside-sidecar",
            scope: "global",
            migrationKey: "assistant.general.localAutoTitle.v1"
        )

        XCTAssertThrowsError(try makeStoreWithBackend(databaseURL: databaseURL, sidecarURL: sidecarURL)) { error in
            guard case .consistencyMismatch = error as? AssistantSettingsValueStoreError else {
                return XCTFail("revision/digest mismatch must fail closed, got \(error)")
            }
        }
    }

    func testEveryWritableRegistryDescriptorHasNativeControl() throws {
        let registry = try AssistantSettingRegistry.standard()
        let actionRegistry = try AssistantSettingsActionRegistry.standard()
        let pane = V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: registry,
            actionRegistry: actionRegistry,
            valueStore: AssistantSettingsValueStore.inMemory(registry: registry)
        )
        let root = try XCTUnwrap(pane as? NSScrollView)
        let registrations = V2SettingsPaneFactory.registrations()
        for registration in registrations {
            guard case .editableSetting = registration.kind else { continue }
            XCTAssertNotNil(
                findView(
                    identifier: registration.controlIdentifier + ".control",
                    in: root
                ),
                "writable descriptor must have an AppKit control: \(registration.controlIdentifier)"
            )
        }
    }

    @MainActor
    func testLiveStoreIsSharedWithinTheProcess() {
        let first = AssistantSettingsLiveStore.sharedIfAvailable()
        let second = AssistantSettingsLiveStore.sharedIfAvailable()
        guard let first, let second else {
            return XCTFail("生产设置值存储必须可装配")
        }
        XCTAssertTrue(first === second, "设置页与 Workbench 必须共用同一个 sidecar owner")
    }

    private func findView(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = findView(identifier: identifier, in: child) { return found }
        }
        return nil
    }

    private func makeStoreWithBackend(databaseURL: URL, sidecarURL: URL) throws -> AssistantSettingsValueStore {
        let backend = try AssistantSettingsStoreBackend(databasePath: databaseURL.path)
        return try AssistantSettingsValueStore(
            registry: try AssistantSettingRegistry.standard(),
            backend: backend,
            fileURL: sidecarURL,
            masterKeyProvider: StaticMasterKey(data: Data(repeating: 7, count: 32))
        )
    }
}
