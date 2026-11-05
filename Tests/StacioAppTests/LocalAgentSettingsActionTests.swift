import XCTest
import Foundation
@testable import StacioApp

/// P4-8：Local Agent Settings 动作与 settings process 接线。
final class LocalAgentSettingsActionTests: XCTestCase {

    // MARK: - detect/login containment

    func testDetectLoginUsesMaintenanceLaunchContainment() {
        let containment = LocalAgentSettingsAction.containment()
        XCTAssertTrue(containment.isContained, "零 TargetBinding/workspace/Effect Broker")
        XCTAssertEqual(containment.targetBindingCount, 0)
        XCTAssertEqual(containment.workspaceCount, 0)
        XCTAssertEqual(containment.effectBrokerCount, 0)
    }

    func testSettingsProcessGlobalLimitOne() {
        XCTAssertTrue(LocalAgentSettingsAction.launchAllowed(activeProcesses: []))
        XCTAssertFalse(
            LocalAgentSettingsAction.launchAllowed(activeProcesses: [.starting]),
            "settings process 全局上限 1"
        )
        XCTAssertFalse(
            LocalAgentSettingsAction.launchAllowed(activeProcesses: [.running, .completed])
        )
        XCTAssertTrue(
            LocalAgentSettingsAction.launchAllowed(activeProcesses: [.completed, .failed]),
            "全部终态后允许"
        )
    }

    func testInteractiveLoginUsesStopablePTY() {
        XCTAssertTrue(LocalAgentSettingsAction.interactiveLoginUsesStopablePTY(), "交互登录独立可停止 PTY")
    }

    func testCandidateScanDoesNotWriteExecutableReference() {
        XCTAssertFalse(
            LocalAgentSettingsAction.candidateScanWritesExecutableReference(),
            "候选路径扫描不写 executableReference"
        )
    }

    // MARK: - changeExecutionProfile

    func testChangeExecutionProfileSavesConcreteProfileAndRevision() {
        let spec = LocalAgentSettingsAction.profileSpec(profileID: "profile-minimal", revision: 3)
        XCTAssertEqual(spec.profileID, "profile-minimal")
        XCTAssertEqual(spec.revision, 3, "不能只存 kind——必须存具体 profile/revision")
    }

    func testChangeExecutionProfileRejectedWithActiveAttempt() {
        XCTAssertFalse(LocalAgentSettingsAction.changeExecutionProfileAllowed(hasActiveAttempt: true))
        XCTAssertTrue(LocalAgentSettingsAction.changeExecutionProfileAllowed(hasActiveAttempt: false))
    }

    func testPTYTrustRecordsDescriptorProfileRevisionTime() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = LocalAgentSettingsAction.ptyTrustEntry(
            descriptorID: "descriptor-a", profileRevision: 2, trustedAt: date
        )
        XCTAssertEqual(entry.descriptorID, "descriptor-a")
        XCTAssertEqual(entry.profileRevision, 2)
        XCTAssertEqual(entry.trustedAt, date, "PTY trust 记录 descriptor/profile revision/时间")
    }

    // MARK: - logout

    func testLogoutSafetyJournalAndOrder() {
        XCTAssertTrue(LocalAgentSettingsAction.logoutAllowed(controlState: .draining), "draining 可撤销")
        XCTAssertTrue(LocalAgentSettingsAction.logoutAllowed(controlState: .disabled), "disabled 可撤销")
        XCTAssertFalse(LocalAgentSettingsAction.logoutAllowed(controlState: .enabled), "enabled 不允许直接登出")
        XCTAssertEqual(
            LocalAgentSettingsAction.logoutOrder(),
            ["stopFirst", "startAfter"],
            "同一全局 slot 的 safety journal：先 Stop 再启动"
        )
    }

    // MARK: - reconcileProcesses

    func testReconcileReadOnlyEvidenceWithSameOperationID() {
        let plan = LocalAgentSettingsAction.reconcilePlan(operationID: "op-9")
        XCTAssertEqual(plan.operationID, "op-9")
        XCTAssertTrue(plan.readOnly, "只读采集证据")
        XCTAssertEqual(plan.settlement, "stateUnknown", "以同一 operation ID 结算 stateUnknown")
    }

    // MARK: - openUpgrade

    func testOpenUpgradeOnlyVerifiedOfficialSite() {
        let url = URL(string: "https://cli.example.com/upgrade")!
        XCTAssertEqual(LocalAgentSettingsAction.upgradeURL(verified: true, url: url), url)
        XCTAssertNil(LocalAgentSettingsAction.upgradeURL(verified: false, url: url), "只打开已验证官网")
    }

    // MARK: - OAuth 边界

    func testOAuthManagedByCLIAndNeverTouchedByStacio() {
        XCTAssertTrue(LocalAgentSettingsAction.oauthManagedByCLI(), "OAuth 由 CLI 管理")
        XCTAssertTrue(LocalAgentSettingsAction.stacioNeverReadsOAuth())
        XCTAssertTrue(LocalAgentSettingsAction.stacioNeverCopiesOAuth())
        XCTAssertTrue(LocalAgentSettingsAction.stacioNeverExportsOAuth())
        XCTAssertTrue(LocalAgentSettingsAction.stacioNeverMigratesOAuth())
    }
}
