import XCTest
import Foundation
@testable import StacioApp

/// P9-7：历史与记忆动作（exportSelection、clearSelection V2-only、deleteAllV2 门禁接线、
/// changeRetention 预览排除、项目动作绑定、幂等/audit）。
final class HistoryMemoryActionTests: XCTestCase {

    // MARK: - exportSelection

    func testExportSelectionShowsSessionsAndPath() {
        let result = HistoryMemoryAction.exportSelection(sessions: ["c-1", "c-2"], exportPath: "/tmp/export.json")
        XCTAssertEqual(result.sessions, ["c-1", "c-2"], "展示精确会话")
        XCTAssertEqual(result.exportPath, "/tmp/export.json", "展示导出路径")
    }

    // MARK: - clearSelection

    func testClearSelectionV2OnlyAndSharedDBUntouched() {
        XCTAssertTrue(HistoryMemoryAction.clearSelectionAppliesToV2Only(), "清空所选历史 V2-only 范围")
        XCTAssertTrue(HistoryMemoryAction.clearSelectionNeverTouchesSharedDatabase(), "不触碰共用库")
    }

    // MARK: - deleteAllV2 门禁接线

    func testDeleteAllV2GateWiredFromQuota() {
        XCTAssertTrue(HistoryMemoryAction.deleteAllV2Allowed(
            controlDisabled: true, maintenanceFenceEngaged: true, sagasFullySettled: true
        ))
        XCTAssertFalse(HistoryMemoryAction.deleteAllV2Allowed(
            controlDisabled: false, maintenanceFenceEngaged: true, sagasFullySettled: true
        ), "仅 disabled + 维护 fence + 全结算")
        XCTAssertFalse(HistoryMemoryAction.deleteAllV2Allowed(
            controlDisabled: true, maintenanceFenceEngaged: false, sagasFullySettled: true
        ))
        XCTAssertFalse(HistoryMemoryAction.deleteAllV2Allowed(
            controlDisabled: true, maintenanceFenceEngaged: true, sagasFullySettled: false
        ))
    }

    // MARK: - changeRetention 预览排除

    func testChangeRetentionShortenPreviewExcludes() {
        XCTAssertEqual(HistoryMemoryAction.shortenExcludedKinds(),
                       ["pinned", "active", "branch", "recoveryEvidence"])
        let preview = HistoryMemoryAction.changeRetentionShortenPreview(
            candidateSessions: ["pinned", "old", "active", "branch", "recoveryEvidence", "candidate"],
            excludedKinds: HistoryMemoryAction.shortenExcludedKinds()
        )
        XCTAssertEqual(preview, ["old", "candidate"], "缩短先预览，排除固定/活动/分支/恢复证据")
    }

    // MARK: - 项目动作

    func testProjectActionBindingAndConfirmation() {
        XCTAssertTrue(HistoryMemoryAction.projectActionRequiresBothIdentities(
            projectIdentity: "p", remoteTargetIdentityDigest: "d"
        ))
        XCTAssertFalse(HistoryMemoryAction.projectActionRequiresBothIdentities(
            projectIdentity: "", remoteTargetIdentityDigest: "d"
        ))
        XCTAssertTrue(HistoryMemoryAction.deleteProjectRequiresSecondaryConfirmation(),
                      "memory.deleteProject 删除二次确认")
    }

    // MARK: - 幂等与 audit

    func testIdempotentAndAudited() {
        XCTAssertTrue(HistoryMemoryAction.idempotent(), "按 Action Registry 幂等")
        XCTAssertTrue(HistoryMemoryAction.auditedSettlement(), "audit 结算")
    }
}
