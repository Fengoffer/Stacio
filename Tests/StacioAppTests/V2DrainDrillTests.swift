import XCTest
import Foundation
@testable import StacioApp

/// P10-2：V2DrainDrill（enabled→draining 步骤、draining→disabled 全套条件、disabled→enabled 不复活、清理不变量）。
final class V2DrainDrillTests: XCTestCase {

    // MARK: - enabled→draining

    func testEnabledToDrainingSteps() {
        XCTAssertEqual(V2DrainPolicy.enabledToDrainingSteps(), [
            "advanceGenerationAtomically",
            "closePermitIssuanceAndCommitAuthorization",
            "closeV2Admission",
            "cancelUnauthorizedRequests",
            "freezePreFencePermits"
        ], "原子提升 generation、关 Permit 签发/commit authorization、关 V2 admission、取消未获准 request、冻结 fence 前 Permit")
    }

    // MARK: - draining→disabled 全套条件

    func testReadyForDisabledWhenAllConditionsMet() {
        XCTAssertTrue(V2DrainPolicy.readyForDisabled(DrainReadinessChecklist()))
    }

    func testReadyForDisabledFailsOnAnyCondition() {
        var checklist = DrainReadinessChecklist()
        checklist.openPermitsOrJournals = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "未结算 Permit/journal 阻止")

        checklist = DrainReadinessChecklist()
        checklist.queuedRequestsOrLeases = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "queued request 与 lease 阻止")

        checklist = DrainReadinessChecklist()
        checklist.activeAttemptsIntentsDecisionsProposals = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist))

        checklist = DrainReadinessChecklist()
        checklist.activeSecureInput = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist))

        checklist = DrainReadinessChecklist()
        checklist.unsettledAuthority = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "authority 全 settled 才可")

        checklist = DrainReadinessChecklist()
        checklist.answerOnlyCapabilityNotFinal = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "answer-only capability 唯一终态")

        checklist = DrainReadinessChecklist()
        checklist.nativeRequestsInFlight = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "Native request 全结算")

        checklist = DrainReadinessChecklist()
        checklist.managedProcessesRunningOrScratchNotDeleted = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "managed 进程退出/隔离 + scratch 删除")

        checklist = DrainReadinessChecklist()
        checklist.outboxNonEmpty = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "outbox 空")

        checklist = DrainReadinessChecklist()
        checklist.settingsProcessNotTerminal = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "settings process 终态")

        checklist = DrainReadinessChecklist()
        checklist.unknownRemoteEffectsUnlocked = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "未知远端 effect 已建锁")

        checklist = DrainReadinessChecklist()
        checklist.credentialSagasInFlight = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "credential saga 稳定点")

        checklist = DrainReadinessChecklist()
        checklist.verificationRequestsInFlight = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "verification request 终态")

        checklist = DrainReadinessChecklist()
        checklist.setupNotInStableState = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "setup 仅 suspended/completed/abandoned")

        checklist = DrainReadinessChecklist()
        checklist.repositoryCheckpointNotReadOnlyOpenable = true
        XCTAssertFalse(V2DrainPolicy.readyForDisabled(checklist), "Repository checkpoint 可只读打开")
    }

    // MARK: - disabled→enabled 不复活

    func testDisabledToEnabledDoesNotResurrectOldArtifacts() {
        XCTAssertTrue(V2DrainPolicy.disabledToEnabledDoesNotResurrectOldArtifacts(),
                      "disabled→enabled 新 transition/generation 且旧 Permit/request/capability 不复活")
    }

    // MARK: - 清理不变量

    func testCleanupInvariants() {
        XCTAssertTrue(V2DrainPolicy.noDraftOrQueueLoss(), "任何场景不丢草稿/队列")
        XCTAssertTrue(V2DrainPolicy.noDuplicateExternalEffects(), "不重复外部 effect")
        XCTAssertTrue(V2DrainPolicy.v1DoesNotInheritV2ActiveWork(), "V1 不继承 V2 活动工作")
        XCTAssertTrue(V2DrainPolicy.sharedLeasesStillApplyToV1(),
                      "V1 仍受共享 Terminal lease/conflict lock/revoke fence 约束")
        XCTAssertTrue(V2DrainPolicy.backgroundSecurityServicesContinueWhenUIHidden(),
                      "后台安全服务在 UI 隐藏后继续")
    }
}
