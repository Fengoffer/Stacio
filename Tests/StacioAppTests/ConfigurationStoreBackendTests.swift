import XCTest
import Foundation
@testable import StacioApp

/// P3-12：Configuration Store Rust 后端（真实独立 Configuration Store，经 CoreBridge UniFFI）。
final class ConfigurationStoreBackendTests: XCTestCase {

    private func makeBackend() throws -> ConfigurationStoreBackend {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-config-\(UUID().uuidString).sqlite3").path
        return try ConfigurationStoreBackend(databasePath: path)
    }

    // MARK: - revision CAS 与引用

    func testConfigurationRevisionCASAndReferenceOnly() throws {
        let backend = try makeBackend()
        try backend.upsert(
            configurationID: "config-1", expectedRevision: nil, valueDigest: "digest-v1",
            credentialReference: "credential-lifecycle:gen-7"
        )
        var config = try backend.snapshot(configurationID: "config-1")
        XCTAssertEqual(config?.revision, 1)
        XCTAssertEqual(config?.digest, "digest-v1")
        XCTAssertEqual(config?.state, "draft")

        try backend.upsert(
            configurationID: "config-1", expectedRevision: 1, valueDigest: "digest-v2",
            credentialReference: "credential-lifecycle:gen-7"
        )
        config = try backend.snapshot(configurationID: "config-1")
        XCTAssertEqual(config?.revision, 2)

        // 旧 revision CAS 拒绝
        do {
            try backend.upsert(
                configurationID: "config-1", expectedRevision: 1, valueDigest: "d",
                credentialReference: "r"
            )
            XCTFail("旧 revision CAS 必须拒绝")
        } catch let error as V2ControlError {
            switch error {
            case .storage(let message): XCTAssertTrue(message.contains("StaleRevision"))
            default: XCTFail("预期 StaleRevision，实际 \(error)")
            }
        }
    }

    func testVerifiedCommitAndDeletePublishStateRevisionAndAuditAtomically() throws {
        let backend = try makeBackend()
        let createdRevision = try backend.commitVerified(
            configurationID: "local-agent-1",
            expectedRevision: nil,
            valueDigest: "digest-active",
            credentialReference: "cli-managed:local-agent.codex",
            operationID: "op-create",
            eventID: "event-create"
        )
        XCTAssertEqual(createdRevision, 1)
        XCTAssertEqual(try backend.snapshot(configurationID: "local-agent-1")?.state, "active")
        XCTAssertEqual(
            try backend.eventsByOperation(operationID: "op-create"),
            ["configurationMutationCommitted", "configurationActivated"]
        )

        XCTAssertThrowsError(try backend.delete(
            configurationID: "local-agent-1",
            expectedRevision: 0,
            tombstoneDigest: "digest-deleted",
            operationID: "op-stale-delete",
            eventID: "event-stale-delete"
        ))
        XCTAssertEqual(try backend.snapshot(configurationID: "local-agent-1")?.state, "active")
        XCTAssertTrue(try backend.eventsByOperation(operationID: "op-stale-delete").isEmpty)

        let deletedRevision = try backend.delete(
            configurationID: "local-agent-1",
            expectedRevision: 1,
            tombstoneDigest: "digest-deleted",
            operationID: "op-delete",
            eventID: "event-delete"
        )
        XCTAssertEqual(deletedRevision, 2)
        let deleted = try backend.snapshot(configurationID: "local-agent-1")
        XCTAssertEqual(deleted?.revision, 2)
        XCTAssertEqual(deleted?.state, "deleted")
        XCTAssertEqual(
            try backend.eventsByOperation(operationID: "op-delete"),
            ["configurationDeletionCommitted", "configurationDeleted"]
        )
    }

    // MARK: - 状态机

    func testConfigurationStateMachineClosed() throws {
        let backend = try makeBackend()
        try backend.upsert(configurationID: "config-1", expectedRevision: nil, valueDigest: "d", credentialReference: "ref")
        try backend.transitionState(configurationID: "config-1", to: "prepared")
        try backend.transitionState(configurationID: "config-1", to: "dispatched")
        try backend.transitionState(configurationID: "config-1", to: "activating")
        try backend.transitionState(configurationID: "config-1", to: "active")
        XCTAssertEqual(try backend.snapshot(configurationID: "config-1")?.state, "active")

        // 回退非法
        do {
            try backend.transitionState(configurationID: "config-1", to: "prepared")
            XCTFail("active 不能回退 prepared")
        } catch let error as V2ControlError {
            XCTAssertEqual(error, .invalidTransition(from: "active", to: "prepared"))
        }
        // deleted 终态
        try backend.transitionState(configurationID: "config-1", to: "deleted")
        do {
            try backend.transitionState(configurationID: "config-1", to: "active")
            XCTFail("deleted 终态无出口")
        } catch let error as V2ControlError {
            XCTAssertEqual(error, .invalidTransition(from: "deleted", to: "active"))
        }
    }

    // MARK: - configuration-scoped event

    func testConfigurationEventsClosedKindsAndSequence() throws {
        let backend = try makeBackend()
        let seq1 = try backend.appendEvent(
            eventID: "ev-1", configurationID: "config-1", operationID: "op-1", kind: "configurationDraftSaved"
        )
        let seq2 = try backend.appendEvent(
            eventID: "ev-2", configurationID: "config-1", operationID: "op-1", kind: "configurationActivated"
        )
        XCTAssertEqual(seq1, 1)
        XCTAssertEqual(seq2, 2)

        // 幂等
        XCTAssertEqual(
            try backend.appendEvent(
                eventID: "ev-2", configurationID: "config-1", operationID: "op-1", kind: "configurationActivated"
            ),
            2
        )
        XCTAssertEqual(
            try backend.events(configurationID: "config-1"),
            ["configurationDraftSaved", "configurationActivated"]
        )

        // 关闭 kind 集合
        do {
            _ = try backend.appendEvent(
                eventID: "ev-3", configurationID: "config-1", operationID: "op-1", kind: "arbitraryKind"
            )
            XCTFail("关闭 kind 集合之外必须拒绝")
        } catch let error as V2ControlError {
            switch error {
            case .storage(let message): XCTAssertTrue(message.contains("InvalidKind"))
            default: XCTFail("预期 InvalidKind，实际 \(error)")
            }
        }
    }

    func testOperationCorrelationWithSettingsDomain() throws {
        // mutation 与 Action audit 同一 operation ID：configuration 域 + settings 域合并投影
        let backend = try makeBackend()
        _ = try backend.appendEvent(
            eventID: "ev-1", configurationID: "config-1", operationID: "op-1", kind: "configurationMutationCommitted"
        )
        XCTAssertEqual(
            try backend.eventsByOperation(operationID: "op-1"),
            ["configurationMutationCommitted"],
            "同 operation 只有 configuration 事件 → 投影 NeedsReview（缺 settings 域 action 事件）"
        )

        // 两个域都写同一 operation（settings 域经 AssistantSettingsStoreBackend）
        let settingsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-settings-correl-\(UUID().uuidString).sqlite3").path
        let settings = try AssistantSettingsStoreBackend(databasePath: settingsPath)
        _ = try settings.appendEvent(eventID: "ev-2", operationID: "op-1", kind: "actionRequested")
        _ = try backend.appendEvent(
            eventID: "ev-3", configurationID: "config-1", operationID: "op-1", kind: "configurationActivated"
        )
        let configSide = try backend.eventsByOperation(operationID: "op-1")
        let settingsSide = try settings.events(operationID: "op-1")
        XCTAssertEqual(configSide.count, 2, "configuration 域侧事件齐全")
        XCTAssertEqual(settingsSide, ["actionRequested"], "settings 域侧 action 事件")
    }

    func testNoSecretStorageInSnapshot() throws {
        // credential 只存引用；快照 API 无 secret 字段（只有 revision/digest/state）
        let backend = try makeBackend()
        try backend.upsert(
            configurationID: "config-1", expectedRevision: nil, valueDigest: "digest",
            credentialReference: "credential-lifecycle:gen-7"
        )
        let config = try backend.snapshot(configurationID: "config-1")
        XCTAssertEqual(config?.digest, "digest")
        XCTAssertEqual(config?.state, "draft")
        XCTAssertEqual(config?.revision, 1)
    }
}
