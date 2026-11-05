import XCTest
import Foundation
@testable import StacioApp

/// P3-8c 后置部分（P3-9 落地后）：credentialSetupCreate/originCopy/rotation/configurationActivation
/// 的 Permit 接线与 Keychain staging（真实 Rust 控制面库 + InMemory Keychain 后端）。
final class CredentialPermitWiringTests: XCTestCase {

    // MARK: - helpers

    private func makeWiring() throws -> (wiring: CredentialPermitWiring, control: AgentConversationV2ControlCoordinator, keychain: KeychainCredentialStore) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-control-permit-\(UUID().uuidString).sqlite3").path
        let control = try AgentConversationV2ControlCoordinator(databasePath: path)
        let permit = V2ControlTargetOperationCoordinator(control: control)
        let keychain = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        return (CredentialPermitWiring(permit: permit, keychain: keychain), control, keychain)
    }

    private func participants(for kind: CredentialOperationKind) -> [String] {
        switch kind {
        case .credentialSetupCreate, .credentialOriginCopy, .credentialRotation, .proxyCredentialRotation:
            return ["credential-lifecycle"]
        case .configurationActivation:
            return ["configuration-store", "credential-lifecycle"]
        }
    }

    // MARK: - staging 只允许 settling 阶段

    func testStagingRequiresSettling() throws {
        let (wiring, _, _) = try makeWiring()
        try wiring.beginOperation(
            kind: .credentialSetupCreate, permitID: "permit-1", generation: 1,
            participants: participants(for: .credentialSetupCreate)
        )
        // issued 阶段写 staging → 拒绝
        do {
            try wiring.stageSecret(permitID: "permit-1", id: "cred-1", secret: "s3cr3t")
            XCTFail("settling 之前不得写 staging")
        } catch let error as CredentialPermitWiringError {
            XCTAssertEqual(error, .stagingRequiresSettling(permitID: "permit-1"))
        }
    }

    // MARK: - 完整提交路径

    func testStageWriteOnlyInSettlingAndPromotionOnCommit() throws {
        let (wiring, control, keychain) = try makeWiring()
        try wiring.beginOperation(
            kind: .credentialRotation, permitID: "permit-1", generation: 1,
            participants: participants(for: .credentialRotation)
        )
        try wiring.authorizeCommit(permitID: "permit-1")
        try wiring.beginSettlement(permitID: "permit-1")

        // settling 阶段写 staging（staging service 与正式 service 隔离，Runtime 不可访问）
        try wiring.stageSecret(permitID: "permit-1", id: "cred-1", secret: "new-secret")
        XCTAssertEqual(
            try keychain.readSecret(id: "cred-1", account: CredentialPermitWiring.stagingAccount(for: "permit-1")),
            "new-secret",
            "settling 阶段 staging item 已写入（隔离 service）"
        )
        // 正式 service 尚不可读（staging 未提升）
        do {
            _ = try keychain.readSecret(id: "cred-1", account: "credential-account")
            XCTFail("提交前正式键不可读")
        } catch KeychainCredentialError.notFound {
            // expected
        }

        // 目标提交：staging 提升为正式键 + 删除 staging + settle committed
        try wiring.commitStaged(permitID: "permit-1", id: "cred-1", account: "credential-account", proofDigest: "proof-digest-1")
        XCTAssertEqual(
            try keychain.readSecret(id: "cred-1", account: "credential-account"),
            "new-secret",
            "提交后正式键可读（staging 提升）"
        )
        do {
            _ = try keychain.readSecret(id: "cred-1", account: CredentialPermitWiring.stagingAccount(for: "permit-1"))
            XCTFail("提交后 staging item 必须删除")
        } catch KeychainCredentialError.notFound {
            // expected
        }

        let permit = V2ControlTargetOperationCoordinator(control: control)
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .settledCommitted)
    }

    func testAbortDeletesStaging() throws {
        let (wiring, control, keychain) = try makeWiring()
        try wiring.beginOperation(
            kind: .configurationActivation, permitID: "permit-1", generation: 1,
            participants: participants(for: .configurationActivation)
        )
        try wiring.authorizeCommit(permitID: "permit-1")
        try wiring.beginSettlement(permitID: "permit-1")
        try wiring.stageSecret(permitID: "permit-1", id: "cred-1", secret: "staged-secret")

        // 目标未提交：abort decision + 删除 staging
        try wiring.abortStaged(permitID: "permit-1", stagedIDs: ["cred-1"], proofDigest: "abort-proof")
        do {
            _ = try keychain.readSecret(id: "cred-1", account: CredentialPermitWiring.stagingAccount(for: "permit-1"))
            XCTFail("abort 后 staging item 必须删除（quarantine）")
        } catch KeychainCredentialError.notFound {
            // expected
        }

        let permit = V2ControlTargetOperationCoordinator(control: control)
        XCTAssertEqual(try permit.permitState(permitID: "permit-1"), .settledAborted)
    }

    // MARK: - resume 新 Permit

    func testResumeRequiresTerminatedPreviousPermit() throws {
        let (wiring, control, _) = try makeWiring()
        try wiring.beginOperation(
            kind: .credentialSetupCreate, permitID: "permit-1", generation: 1,
            participants: participants(for: .credentialSetupCreate)
        )
        // 未终结的 Permit 不可 resume
        do {
            try wiring.resume(
                previousPermitID: "permit-1", newPermitID: "permit-2", generation: 1,
                participants: participants(for: .credentialSetupCreate)
            )
            XCTFail("未终结 Permit 不可 resume")
        } catch let error as CredentialPermitWiringError {
            switch error {
            case .storage: break
            default:
                XCTFail("预期 storage 错误，实际 \(error)")
            }
        } catch {
            XCTFail("预期 CredentialPermitWiringError，实际 \(error)")
        }

        // abort 后 resume 新 Permit 成功
        try wiring.authorizeCommit(permitID: "permit-1")
        try wiring.beginSettlement(permitID: "permit-1")
        try wiring.abortStaged(permitID: "permit-1", stagedIDs: [], proofDigest: "abort")
        try wiring.resume(
            previousPermitID: "permit-1", newPermitID: "permit-2", generation: 1,
            participants: participants(for: .credentialSetupCreate)
        )
        let permit = V2ControlTargetOperationCoordinator(control: control)
        XCTAssertEqual(try permit.permitState(permitID: "permit-2"), .issued, "resume 新 Permit 签发")
    }

    // MARK: - participant set 冻结

    func testActivationFrozenParticipants() throws {
        let (wiring, control, _) = try makeWiring()
        try wiring.beginOperation(
            kind: .configurationActivation, permitID: "permit-1", generation: 1,
            participants: participants(for: .configurationActivation)
        )
        let permit = V2ControlTargetOperationCoordinator(control: control)
        XCTAssertEqual(
            try permit.journalParticipants(permitID: "permit-1"),
            ["configuration-store", "credential-lifecycle"],
            "configurationActivation 冻结双存储域 participant set"
        )
    }
}
