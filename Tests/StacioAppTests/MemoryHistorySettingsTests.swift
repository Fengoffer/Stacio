import XCTest
import Foundation
@testable import StacioApp

/// P9-5：Settings 记忆/历史/存储分区（Registry 渲染、retention 缩短排除项、项目动作绑定、V2-only 删除二次确认）。
final class MemoryHistorySettingsTests: XCTestCase {

    // MARK: - Registry 渲染无私有默认

    func testRendersFromRegistryNoPrivateDefaults() {
        XCTAssertTrue(MemoryHistorySettingsAction.rendersFromRegistry(),
                      "记忆与历史页、存储与配额页从 Registry 渲染")
        XCTAssertTrue(MemoryHistorySettingsAction.noControllerPrivateDefaults(),
                      "无控制器私有默认")
    }

    // MARK: - retention 缩短排除项

    func testRetentionShortenRequiresPreviewAndExcludes() {
        XCTAssertTrue(MemoryHistorySettingsAction.shortenRetentionRequiresPreviewFirst(),
                      "history.changeRetention 缩短先预览")
        XCTAssertEqual(MemoryHistorySettingsAction.retentionShortenExcludedKinds(),
                       ["pinned", "active", "branch", "recoveryEvidence"],
                       "候选/固定/活动/分支/恢复证据排除项")
        XCTAssertTrue(MemoryHistorySettingsAction.excludedFromShortening(kind: "pinned"))
        XCTAssertTrue(MemoryHistorySettingsAction.excludedFromShortening(kind: "active"))
        XCTAssertTrue(MemoryHistorySettingsAction.excludedFromShortening(kind: "branch"))
        XCTAssertTrue(MemoryHistorySettingsAction.excludedFromShortening(kind: "recoveryEvidence"))
        XCTAssertFalse(MemoryHistorySettingsAction.excludedFromShortening(kind: "oldDraft"))
    }

    // MARK: - 项目动作绑定

    func testProjectActionBoundToExactIdentity() {
        XCTAssertTrue(MemoryHistorySettingsAction.projectActionBoundToExactProjectAndTargetBinding(),
                      "memory.exportProject/deleteProject 绑定精确 project+TargetBinding")
        XCTAssertTrue(MemoryHistorySettingsAction.projectActionRequiresBothIdentities(
            projectIdentity: "stacio", remoteTargetIdentityDigest: "digest-1"
        ))
        XCTAssertFalse(MemoryHistorySettingsAction.projectActionRequiresBothIdentities(
            projectIdentity: "", remoteTargetIdentityDigest: "digest-1"
        ), "缺 project 身份拒绝")
        XCTAssertFalse(MemoryHistorySettingsAction.projectActionRequiresBothIdentities(
            projectIdentity: "stacio", remoteTargetIdentityDigest: ""
        ), "缺 TargetBinding digest 拒绝")
    }

    // MARK: - V2-only 删除二次确认

    func testDeleteV2OnlyWithSecondaryConfirmation() {
        XCTAssertTrue(MemoryHistorySettingsAction.deleteAppliesToV2IndependentStorageOnly(),
                      "删除会话数据只作用于 V2 独立存储")
        XCTAssertTrue(MemoryHistorySettingsAction.deleteRequiresSecondaryConfirmation(),
                      "删除需二次确认")
    }
}
