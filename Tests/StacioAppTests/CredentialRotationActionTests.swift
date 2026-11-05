import XCTest
import Foundation
@testable import StacioApp

/// P4-7：凭证轮换/吊销/代理/origin-copy 动作。
final class CredentialRotationActionTests: XCTestCase {

    // MARK: - rotateCredential

    func testRotateCreatesNewGenerationRetiresOldAndShowsAffected() {
        let plan = CredentialRotationAction.planRotation(
            existingGenerationIDs: ["gen-1", "gen-2"],
            affectedAttemptIDs: ["a-1", "a-2"]
        )
        XCTAssertEqual(plan.newGenerationID, "gen-3", "创建新 generation")
        XCTAssertEqual(plan.retiredGenerationIDs, ["gen-1", "gen-2"], "旧 generation 全部 retired")
        XCTAssertEqual(plan.affectedAttemptIDs, ["a-1", "a-2"], "展示受影响 Attempt/Retry")
    }

    func testAffectedAttemptsOnlyReferenceOldGeneration() {
        let bindings = ["a-1": "gen-1", "a-2": "gen-2", "a-3": "gen-1"]
        XCTAssertEqual(
            CredentialRotationAction.affectedAttempts(referencing: "gen-1", attemptBindings: bindings),
            ["a-1", "a-3"]
        )
        XCTAssertEqual(
            CredentialRotationAction.affectedAttempts(referencing: "gen-2", attemptBindings: bindings),
            ["a-2"]
        )
    }

    // MARK: - revokeCredentialNow

    func testRevokeRequiresConfirmation() {
        XCTAssertTrue(CredentialRevocationAction.requiresConfirmation(), "revokeCredentialNow 二次确认")
    }

    func testRevokeOrderFenceBeforeCancelBeforeDelete() {
        XCTAssertEqual(CredentialRevocationAction.executionOrder(), [
            .durableRevokeFence,
            .cancelReferencingAttempts,
            .localDeletion
        ], "先 durable revoke/access fence 再取消引用 Attempt")
    }

    func testLocalDeletionFailureShowsPendingDeletionAndConsoleEntry() {
        XCTAssertEqual(
            CredentialRevocationAction.localDeletionOutcome(
                succeeded: true, upstreamConsoleURL: "https://console.example.com/keys"
            ),
            .deleted
        )
        XCTAssertEqual(
            CredentialRevocationAction.localDeletionOutcome(
                succeeded: false, upstreamConsoleURL: "https://console.example.com/keys"
            ),
            .pendingDeletion(upstreamConsoleURL: "https://console.example.com/keys"),
            "本地删除失败 → pendingDeletion + 上游控制台入口"
        )
    }

    // MARK: - proxy credential

    func testProxyCredentialIndependentScopedGeneration() {
        XCTAssertEqual(ProxyCredentialAction.scopedGenerationID(proxyID: "proxy-a"), "proxy.proxy-a")
        XCTAssertNotEqual(
            ProxyCredentialAction.scopedGenerationID(proxyID: "proxy-a"),
            "gen-1",
            "代理凭证与主凭证 generation 命名空间分离"
        )
    }

    func testClearProxyCredentialSafeSettlementDuringDrainingDisabled() {
        XCTAssertTrue(ProxyCredentialAction.clearAllowed(controlState: .draining), "draining 继续安全结算")
        XCTAssertTrue(ProxyCredentialAction.clearAllowed(controlState: .disabled))
        XCTAssertFalse(ProxyCredentialAction.clearAllowed(controlState: .enabled), "enabled 不允许清除（需先 drain）")
    }

    // MARK: - copyCredentialToNewOrigin

    func testOriginCopyUsesOneTimeLeaseStagingAndPreservesOriginalScope() {
        let plan = OriginCopyAction.planCopy(origin: "https://new.example.com", hasProxyCredential: true)
        XCTAssertEqual(plan.useLeaseOwner, "credentialOriginCopy", "一次性 credentialOriginCopy use lease")
        XCTAssertTrue(plan.stagingRequired)
        XCTAssertEqual(plan.newGenerationID, "copy.https://new.example.com", "新 item/generation")
        XCTAssertTrue(plan.originalScopePreserved, "不修改旧 scope")
        XCTAssertFalse(plan.proxyCredentialCopied, "不自动复制代理凭证")
    }

    func testOriginCopyFailureCleanup() {
        XCTAssertTrue(OriginCopyAction.cleanupOnFailure(cleanupKind: "delete"))
        XCTAssertTrue(OriginCopyAction.cleanupOnFailure(cleanupKind: "quarantine"))
        XCTAssertFalse(OriginCopyAction.cleanupOnFailure(cleanupKind: "keep"), "失败必须删除或 quarantine")
    }
}
