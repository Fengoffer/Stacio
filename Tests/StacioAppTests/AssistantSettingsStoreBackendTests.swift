import XCTest
import Foundation
@testable import StacioApp

/// P3-11：AssistantSettingsStore Rust 后端（真实设置域独立库，经 CoreBridge UniFFI）。
final class AssistantSettingsStoreBackendTests: XCTestCase {

    private func makeBackend() throws -> AssistantSettingsStoreBackend {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-settings-\(UUID().uuidString).sqlite3").path
        return try AssistantSettingsStoreBackend(databasePath: path)
    }

    // MARK: - setting 值 CAS

    func testSettingValueExpectedRevisionCAS() throws {
        let backend = try makeBackend()
        try backend.upsert(key: "appearance.fontSize", expectedRevision: nil, valueDigest: "digest-v1", scope: "user", migrationKey: "mig-1")
        var value = try backend.settingValue(key: "appearance.fontSize")
        XCTAssertEqual(value?.revision, 1)
        XCTAssertEqual(value?.digest, "digest-v1")

        try backend.upsert(key: "appearance.fontSize", expectedRevision: 1, valueDigest: "digest-v2", scope: "user", migrationKey: "mig-1")
        value = try backend.settingValue(key: "appearance.fontSize")
        XCTAssertEqual(value?.revision, 2, "CAS 成功后 revision 递增")
        XCTAssertEqual(value?.digest, "digest-v2")

        // 旧 revision CAS 拒绝
        do {
            try backend.upsert(key: "appearance.fontSize", expectedRevision: 1, valueDigest: "digest-v3", scope: "user", migrationKey: "mig-1")
            XCTFail("旧 revision CAS 必须拒绝")
        } catch let error as V2ControlError {
            switch error {
            case .storage(let message): XCTAssertTrue(message.contains("StaleRevision"))
            default: XCTFail("预期 StaleRevision，实际 \(error)")
            }
        }
        // 已存在但无 expected → KeyExists
        do {
            try backend.upsert(key: "appearance.fontSize", expectedRevision: nil, valueDigest: "digest-v3", scope: "user", migrationKey: "mig-1")
            XCTFail("已存在 setting 必须显式 CAS")
        } catch let error as V2ControlError {
            switch error {
            case .storage(let message): XCTAssertTrue(message.contains("KeyExists"))
            default: XCTFail("预期 KeyExists，实际 \(error)")
            }
        }
    }

    func testSettingScopeAndMigrationKeyPreserved() throws {
        let backend = try makeBackend()
        try backend.upsert(key: "provider.model", expectedRevision: nil, valueDigest: "d-1", scope: "workspace", migrationKey: "mig-7")
        let metadata = try backend.settingMetadata(key: "provider.model")
        XCTAssertEqual(metadata?.scope, "workspace")
        XCTAssertEqual(metadata?.migrationKey, "mig-7")
    }

    // MARK: - durable sequence

    func testEventsDurableSequenceSingleWriter() throws {
        let backend = try makeBackend()
        XCTAssertEqual(try backend.appendEvent(eventID: "ev-1", operationID: "op-1", kind: "settingMutationRequested"), 1)
        XCTAssertEqual(try backend.appendEvent(eventID: "ev-2", operationID: "op-1", kind: "settingMutationCommitted"), 2)
        XCTAssertEqual(try backend.appendEvent(eventID: "ev-3", operationID: "op-1", kind: "settingMutationSettled"), 3)

        // 同 event_id 重复投递幂等
        XCTAssertEqual(try backend.appendEvent(eventID: "ev-2", operationID: "op-1", kind: "settingMutationCommitted"), 2)
        XCTAssertEqual(try backend.nextSequence(), 4)
    }

    func testSettledEventsRequirePriorEvidence() throws {
        let backend = try makeBackend()
        // 无前置证据的 settled 拒绝
        do {
            _ = try backend.appendEvent(eventID: "ev-1", operationID: "op-1", kind: "actionSettled")
            XCTFail("actionSettled 需要 requested 证据")
        } catch let error as V2ControlError {
            switch error {
            case .storage(let message): XCTAssertTrue(message.contains("SettledWithoutEvidence"))
            default: XCTFail("预期 SettledWithoutEvidence，实际 \(error)")
            }
        }
        // requested 后允许 settled
        _ = try backend.appendEvent(eventID: "ev-2", operationID: "op-1", kind: "actionRequested")
        _ = try backend.appendEvent(eventID: "ev-3", operationID: "op-1", kind: "actionSettled")
        XCTAssertEqual(try backend.events(operationID: "op-1"), ["actionRequested", "actionSettled"])
    }

    func testClosedKindSetRejectsArbitraryKinds() throws {
        let backend = try makeBackend()
        do {
            _ = try backend.appendEvent(eventID: "ev-1", operationID: "op-1", kind: "arbitraryKind")
            XCTFail("关闭 kind 集合之外的值必须拒绝")
        } catch let error as V2ControlError {
            switch error {
            case .storage(let message): XCTAssertTrue(message.contains("InvalidKind"))
            default: XCTFail("预期 InvalidKind，实际 \(error)")
            }
        }
        // maintenance fence / export manifest 合法
        _ = try backend.appendEvent(eventID: "ev-2", operationID: "op-1", kind: "maintenanceFenceAcquired")
        _ = try backend.appendEvent(eventID: "ev-3", operationID: "op-1", kind: "exportManifestCreated")
    }

    // MARK: - 隔离 API（不暴露敏感正文）

    func testBackendAPIOnlyExposesDigestsNotSecrets() throws {
        // 后端 API 只暴露 digest/revision/scope/migrationKey——没有 secret/prompt/路径正文/capability token 的入口。
        let backend = try makeBackend()
        try backend.upsert(key: "prompt.system", expectedRevision: nil, valueDigest: "digest-only", scope: "user", migrationKey: "mig-9")
        let value = try backend.settingValue(key: "prompt.system")
        XCTAssertEqual(value?.digest, "digest-only")
        let metadata = try backend.settingMetadata(key: "prompt.system")
        XCTAssertEqual(metadata?.scope, "user")
        XCTAssertEqual(metadata?.migrationKey, "mig-9")
    }
}
