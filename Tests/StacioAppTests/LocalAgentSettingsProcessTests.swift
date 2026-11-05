import XCTest
import Foundation
@testable import StacioApp

/// P3-10：LocalAgentSettingsProcess journal 状态机与崩溃恢复对账。
final class LocalAgentSettingsProcessTests: XCTestCase {

    // MARK: - 合法转换关闭集合

    func testPreparedClosedTransitions() {
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .prepared, event: .beginStart),
            .starting
        )
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .prepared, event: .cancel),
            .cancelled
        )
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .prepared, event: .startFailed),
            .failed
        )
        XCTAssertNil(
            LocalAgentSettingsProcessJournal.destination(from: .prepared, event: .ptyExited),
            "prepared 不能直接结算"
        )
        XCTAssertNil(
            LocalAgentSettingsProcessJournal.destination(from: .prepared, event: .treeExited(businessResultCommitted: true)),
            "prepared 无进程树可退出"
        )
    }

    func testStartingToRunningOrFailed() {
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .starting, event: .processStarted),
            .running
        )
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .starting, event: .startFailed),
            .failed
        )
    }

    func testPTYEOFInsufficientForSettlement() {
        // PTY EOF/窗口关闭/根进程退出 → stopping（不足结算），不能直接 completed
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .running, event: .ptyExited),
            .stopping
        )
        XCTAssertFalse(
            LocalAgentSettingsProcessState.stopping.isTerminal,
            "stopping 不是终态"
        )
    }

    func testTreeExitRequiresBusinessResultForCompleted() {
        // 整棵树退出 + 业务结果未提交 → stateUnknown
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(
                from: .stopping, event: .treeExited(businessResultCommitted: false)
            ),
            .stateUnknown
        )
        // 整棵树退出 + 具名业务结果已由 Evidence Store 提交 → completed
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(
                from: .stopping, event: .treeExited(businessResultCommitted: true)
            ),
            .completed
        )
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(
                from: .running, event: .treeExited(businessResultCommitted: true)
            ),
            .completed
        )
    }

    func testStateUnknownReconcileOnly() {
        // stateUnknown → completed|isolated 仅 reconcile 证据后可发生
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .stateUnknown, event: .reconcileSucceeded),
            .completed
        )
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.destination(from: .stateUnknown, event: .reconcileIsolated),
            .isolated
        )
        XCTAssertNil(
            LocalAgentSettingsProcessJournal.destination(from: .stateUnknown, event: .ptyExited),
            "stateUnknown 不经 reconcile 不得移动"
        )
        XCTAssertNil(
            LocalAgentSettingsProcessJournal.destination(from: .stateUnknown, event: .treeExited(businessResultCommitted: true)),
            "stateUnknown 需要显式 reconcile 证据"
        )
    }

    func testTerminalStatesNoExit() {
        for terminal in [LocalAgentSettingsProcessState.completed, .failed, .cancelled, .isolated] {
            XCTAssertNil(
                LocalAgentSettingsProcessJournal.destination(from: terminal, event: .beginStart),
                "终态无出口"
            )
            XCTAssertNil(
                LocalAgentSettingsProcessJournal.destination(from: terminal, event: .reconcileSucceeded),
                "终态无出口"
            )
            XCTAssertTrue(terminal.isTerminal)
        }
        XCTAssertFalse(LocalAgentSettingsProcessState.prepared.isTerminal)
        XCTAssertFalse(LocalAgentSettingsProcessState.running.isTerminal)
    }

    // MARK: - reconciliation gate

    func testStateUnknownOrUnknownSettlementBlocksNewLaunch() {
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.reconciliationRequired(
                state: .stateUnknown, settlement: .pending
            ),
            "stateUnknown → ProcessReconciliationRequired"
        )
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.reconciliationRequired(
                state: .running, settlement: .unknown
            ),
            "processSettlement==unknown → ProcessReconciliationRequired"
        )
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.reconciliationRequired(
                state: .stateUnknown, settlement: .unknown
            )
        )
        XCTAssertFalse(
            LocalAgentSettingsProcessJournal.reconciliationRequired(
                state: .running, settlement: .pending
            )
        )
        XCTAssertFalse(
            LocalAgentSettingsProcessJournal.reconciliationRequired(
                state: .completed, settlement: .exited
            )
        )
    }

    func testAuthenticationUnknownAllowsRedetect() {
        // authenticationUnknown 后允许重新检测：detect 是恢复路径（收集 reconcile 证据），
        // gate 不阻止；login/Runtime launch 仍被阻止直到 reconcile。
        XCTAssertFalse(
            LocalAgentSettingsProcessJournal.actionBlocked(
                .detect, state: .stateUnknown, settlement: .unknown
            ),
            "stateUnknown 时 detect（重新检测）不阻止"
        )
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.actionBlocked(
                .runtimeLaunch, state: .stateUnknown, settlement: .unknown
            ),
            "stateUnknown 时 Runtime launch 阻止"
        )
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.actionBlocked(
                .login, state: .running, settlement: .unknown
            ),
            "settlement unknown 时 login 阻止"
        )
        XCTAssertFalse(
            LocalAgentSettingsProcessJournal.actionBlocked(
                .runtimeLaunch, state: .running, settlement: .pending
            ),
            "running/pending 时 launch 允许"
        )
    }

    // MARK: - 全局上限 1

    func testGlobalLimitOne() {
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.globalLimitExceeded(
                activeProcesses: [.starting]
            ),
            "在途 process 存在时不允许新进程（全局上限 1）"
        )
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.globalLimitExceeded(
                activeProcesses: [.running, .completed]
            )
        )
        XCTAssertFalse(
            LocalAgentSettingsProcessJournal.globalLimitExceeded(
                activeProcesses: [.completed, .failed, .cancelled]
            ),
            "全部终态时允许新进程"
        )
        XCTAssertTrue(
            LocalAgentSettingsProcessJournal.launchBlockedDuringLogout(isLoggingOut: true),
            "logout safety priority：登出时阻止新 launch"
        )
        XCTAssertFalse(
            LocalAgentSettingsProcessJournal.launchBlockedDuringLogout(isLoggingOut: false)
        )
    }

    // MARK: - 崩溃恢复对账

    func testCrashReconciliationDoesNotAutoSettle() {
        // PID 缺失 → 无法确认 → stateUnknown（不自动 completed）
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.reconcileAfterCrash(
                persistedState: .running, pidKnown: false, rootProcessExited: false,
                businessResultCommitted: false
            ),
            .stateUnknown
        )
        // 根进程退出但业务结果未提交 → stateUnknown（Permit settled 不自动写 actionSettled）
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.reconcileAfterCrash(
                persistedState: .stopping, pidKnown: true, rootProcessExited: true,
                businessResultCommitted: false
            ),
            .stateUnknown
        )
        // 整棵树退出 + 业务结果由 Evidence Store 提交 → completed
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.reconcileAfterCrash(
                persistedState: .running, pidKnown: true, rootProcessExited: true,
                businessResultCommitted: true
            ),
            .completed
        )
        // 进程可能在运行：保留 persistedState（不重发、不猜测）
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.reconcileAfterCrash(
                persistedState: .starting, pidKnown: true, rootProcessExited: false,
                businessResultCommitted: false
            ),
            .starting
        )
    }

    func testCrashReconciliationKeepsTerminalStates() {
        // 已终结状态不因崩溃回退（不恢复旧 PTY 输入）
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.reconcileAfterCrash(
                persistedState: .completed, pidKnown: false, rootProcessExited: true,
                businessResultCommitted: false
            ),
            .completed
        )
        XCTAssertEqual(
            LocalAgentSettingsProcessJournal.reconcileAfterCrash(
                persistedState: .isolated, pidKnown: false, rootProcessExited: true,
                businessResultCommitted: false
            ),
            .isolated
        )
    }
}
