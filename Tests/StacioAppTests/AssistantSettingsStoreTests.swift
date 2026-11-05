import XCTest
import Foundation
@testable import StacioApp

/// P4-2：AssistantSettingsStore / EventStore / Migration / Encryption
/// （持久化走 P3-11 settings.rs 真实后端）。
final class AssistantSettingsStoreTests: XCTestCase {

    private func makeStore() throws -> (store: AssistantSettingsStore, backend: AssistantSettingsStoreBackend) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-settings-p42-\(UUID().uuidString).sqlite3").path
        let backend = try AssistantSettingsStoreBackend(databasePath: path)
        let registry = try AssistantSettingRegistry.standard()
        return (AssistantSettingsStore(backend: backend, registry: registry), backend)
    }

    private func makeEventStore() throws -> AssistantSettingsEventStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-settings-events-\(UUID().uuidString).sqlite3").path
        let backend = try AssistantSettingsStoreBackend(databasePath: path)
        return AssistantSettingsEventStore(backend: backend)
    }

    // MARK: - AssistantSettingsStore

    func testWriteValidValuePersistsDigest() throws {
        let (store, backend) = try makeStore()
        try store.write(
            id: "assistant.general.localAutoTitle",
            value: .bool(false),
            scope: "user",
            migrationKey: "assistant.general.localAutoTitle.v1"
        )
        let value = try backend.settingValue(key: "assistant.general.localAutoTitle")
        XCTAssertEqual(value?.revision, 1)
        XCTAssertTrue(value?.digest.hasPrefix("sha256:") ?? false, "只存 digest 不存正文")
    }

    func testNeedsReviewRejectedWithoutFallback() throws {
        let (store, _) = try makeStore()
        // 未知 ID → needsReview 拒绝
        XCTAssertThrowsError(try store.write(id: "unknown.setting", value: .int(1), scope: "user", migrationKey: "x")) { error in
            XCTAssertEqual(error as? AssistantSettingsStore.StoreError, .needsReview("unknown.setting"))
        }
        // 越界值 → outOfRange 拒绝
        XCTAssertThrowsError(
            try store.write(
                id: "assistant.execution.maxToolSteps", value: .int(300), scope: "user",
                migrationKey: "assistant.execution.maxToolSteps.v1"
            )
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsStore.StoreError, .outOfRange("assistant.execution.maxToolSteps"))
        }
        // 错误类型 → wrongType
        XCTAssertThrowsError(
            try store.write(
                id: "assistant.general.restoreLastConversation", value: .string("yes"), scope: "user",
                migrationKey: "assistant.general.restoreLastConversation.v1"
            )
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsStore.StoreError, .wrongType("assistant.general.restoreLastConversation"))
        }
        // 已删除枚举 → needsReview（不回退第一个选项）
        XCTAssertThrowsError(
            try store.write(
                id: "assistant.appearance.timelineDensity", value: .string("deletedValue"), scope: "user",
                migrationKey: "assistant.appearance.timelineDensity.v1"
            )
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsStore.StoreError, .needsReview("assistant.appearance.timelineDensity"))
        }
    }

    // MARK: - AssistantSettingsEventStore（durable sequence 走 settings.rs）

    func testActionAuditLifecycle() throws {
        let eventStore = try makeEventStore()
        try eventStore.requested(actionID: "provider.fetchModels", operationID: "op-1")
        try eventStore.settled(actionID: "provider.fetchModels", operationID: "op-1")
        XCTAssertEqual(
            try eventStore.events(operationID: "op-1"),
            ["actionRequested", "actionSettled"]
        )
    }

    func testSettledWithoutRequestedRejected() throws {
        let eventStore = try makeEventStore()
        // Permit 已结算但异步 Action 未取得业务结果 → 不允许提前写 actionSettled
        XCTAssertThrowsError(try eventStore.settled(actionID: "provider.fetchModels", operationID: "op-1")) { error in
            guard let v2Error = error as? V2ControlError else {
                return XCTFail("预期 V2ControlError，实际 \(error)")
            }
            switch v2Error {
            case .storage(let message): XCTAssertTrue(message.contains("SettledWithoutEvidence"))
            default: XCTFail("预期 SettledWithoutEvidence，实际 \(v2Error)")
            }
        }
    }

    func testMutationCommittedAndSettledDualEvents() throws {
        let eventStore = try makeEventStore()
        try eventStore.mutationCommittedAndSettled(operationID: "op-1")
        XCTAssertEqual(
            try eventStore.events(operationID: "op-1"),
            ["settingMutationCommitted", "settingMutationSettled"],
            "成功 Setting mutation 写 committed + settled 双事件"
        )
    }

    // MARK: - AssistantSettingsMigration

    func testMigrationResolvesByIDAliasOnly() throws {
        XCTAssertEqual(
            try AssistantSettingsMigration.currentID(forMigrationKey: "general.defaultRuntime.v1"),
            "assistant.general.defaultRuntime"
        )
        XCTAssertEqual(
            try AssistantSettingsMigration.currentID(forMigrationKey: "execution.maxToolSteps.v1"),
            "assistant.execution.maxToolSteps"
        )
        // 未知迁移键 → 失败（禁止显示名模糊匹配）
        XCTAssertThrowsError(try AssistantSettingsMigration.currentID(forMigrationKey: "显示的旧名称")) { error in
            XCTAssertEqual(error as? AssistantSettingsMigration.MigrationError, .unknownMigrationKey("显示的旧名称"))
        }
    }

    func testRegistryMigrationKeysTraceable() throws {
        let registry = try AssistantSettingRegistry.standard()
        try AssistantSettingsMigration.validate(registry) // 全部 migrationKey 可追溯
    }

    // MARK: - AssistantPreferenceContentKey

    func testEncryptionRoundTrip() throws {
        let master = Data((0..<32).map { UInt8($0) })
        let secret = Data("sensitive setting value".utf8)
        let sealed = try AssistantPreferenceContentKey.seal(
            value: secret, settingID: "assistant.instructions.globalText", revision: 3, masterKeyData: master
        )
        XCTAssertNotEqual(sealed, secret, "密封后不是明文")
        let opened = try AssistantPreferenceContentKey.open(
            sealed: sealed, settingID: "assistant.instructions.globalText", revision: 3, masterKeyData: master
        )
        XCTAssertEqual(opened, secret)
    }

    func testEncryptionAADBoundToSettingIDAndRevision() throws {
        let master = Data((0..<32).map { UInt8($0) })
        let sealed = try AssistantPreferenceContentKey.seal(
            value: Data("v".utf8), settingID: "assistant.instructions.globalText", revision: 1, masterKeyData: master
        )
        // 换 setting id（跨域替换）→ authenticationFailed
        XCTAssertThrowsError(
            try AssistantPreferenceContentKey.open(
                sealed: sealed, settingID: "assistant.context.terminalOutputMode", revision: 1, masterKeyData: master
            )
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsEncryptionError, .authenticationFailed)
        }
        // 换 revision → authenticationFailed
        XCTAssertThrowsError(
            try AssistantPreferenceContentKey.open(
                sealed: sealed, settingID: "assistant.instructions.globalText", revision: 2, masterKeyData: master
            )
        ) { error in
            XCTAssertEqual(error as? AssistantSettingsEncryptionError, .authenticationFailed)
        }
    }
}
