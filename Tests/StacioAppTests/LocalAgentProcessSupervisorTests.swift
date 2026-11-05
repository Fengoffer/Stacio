import XCTest
import Foundation
@testable import StacioApp

/// P8-4：LocalAgentProcessSupervisor（受管进程组、durable journal、Stop 顺序、崩溃对账、orphan 阻止、名额释放）。
final class LocalAgentProcessSupervisorTests: XCTestCase {

    // MARK: - 受管进程组

    func testManagedProcessGroupRequired() {
        XCTAssertTrue(LocalAgentProcessSupervisorAction.managedProcessGroupRequired(),
                      "每次 managed launch 放入可整体终止的受管进程组/等价 OS job")
    }

    // MARK: - durable journal

    func testJournalEntryDurableFields() {
        let entry = LocalAgentProcessSupervisorAction.journalEntry(
            launchKind: "managed", executableIdentity: "sha256:exe", rootPID: 4242,
            trustedStartTime: Date(timeIntervalSince1970: 1_700_000_000),
            processGeneration: 3, childProcessPolicy: "terminateTree",
            attemptAdmissionCapabilityBinding: "cap-1"
        )
        XCTAssertEqual(entry.launchKind, "managed")
        XCTAssertEqual(entry.executableIdentity, "sha256:exe")
        XCTAssertEqual(entry.rootPID, 4242, "根 PID")
        XCTAssertEqual(entry.processGeneration, 3)
        XCTAssertEqual(entry.childProcessPolicy, "terminateTree", "子进程策略")
        XCTAssertEqual(entry.attemptAdmissionCapabilityBinding, "cap-1", "Attempt-Admission-capability 绑定")
    }

    // MARK: - Stop 顺序

    func testStopOrderRevokesCapabilityBeforeTermination() {
        XCTAssertEqual(LocalAgentProcessSupervisorAction.stopOrder(), [
            "revokeCapability",
            "terminateOrConfirmProcessChainExit",
            "cleanupEphemeralScratch"
        ], "正常 Stop 先撤销 capability 再终止进程链并清理 scratch")
    }

    func testRootExitOrPTYEOFInsufficient() {
        XCTAssertTrue(LocalAgentProcessSupervisorAction.rootExitOrPTYEOFInsufficientToProveEnd(),
                      "根进程退出/PTY EOF 不足证明执行体结束")
    }

    // MARK: - 崩溃对账

    func testCrashRecoveryOrderInvalidatesOldCapabilityFirst() {
        XCTAssertEqual(LocalAgentProcessSupervisorAction.crashRecoveryOrder(), [
            "invalidateOldBrokerEndpoint",
            "reconcileAgainstLaunchJournalAndOSIdentity"
        ], "App 非正常退出后新 generation 先使旧 Broker endpoint/capability 永久失效再对账")
    }

    // MARK: - orphan 阻止

    func testSettlementOrphanedOnPIDReuseIdentityMismatchOrCannotStop() {
        XCTAssertEqual(
            LocalAgentProcessSupervisorAction.settlement(pidReused: true, identityMatches: true, canStop: true),
            .orphaned, "PID 被复用 → OrphanedLocalAgentProcess"
        )
        XCTAssertEqual(
            LocalAgentProcessSupervisorAction.settlement(pidReused: false, identityMatches: false, canStop: true),
            .orphaned, "身份不匹配 → orphaned"
        )
        XCTAssertEqual(
            LocalAgentProcessSupervisorAction.settlement(pidReused: false, identityMatches: true, canStop: false),
            .orphaned, "无法停止 → orphaned"
        )
        XCTAssertEqual(
            LocalAgentProcessSupervisorAction.settlement(pidReused: false, identityMatches: true, canStop: true),
            .running
        )
        XCTAssertTrue(LocalAgentProcessSupervisorAction.orphanBlocksConflictLaunch(),
                      "OrphanedLocalAgentProcess 阻止冲突 launch")
    }

    // MARK: - generation 与名额

    func testGenerationAdvancedAndJournalReconciliation() {
        XCTAssertTrue(LocalAgentProcessSupervisorAction.generationAdvancedOnLaunch(),
                      "启动时 Scheduler/Broker/Supervisor 提升 generation")
        XCTAssertTrue(LocalAgentProcessSupervisorAction.journalReconciliationClassifiesRunningOrOrphaned(),
                      "按 journal 分类对账（仍可运行/无法证明退出 → orphanedRuntime）")
        XCTAssertTrue(LocalAgentProcessSupervisorAction.slotHeldUntilScratchCleaned(),
                      "scratch 未删除前不释放名额")
    }
}
