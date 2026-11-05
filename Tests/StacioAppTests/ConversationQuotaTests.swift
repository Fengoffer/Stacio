import XCTest
import Foundation
@testable import StacioApp

/// P9-4：配额、保留与删除门禁。
final class ConversationQuotaTests: XCTestCase {

    private let giB: Int64 = 1024 * 1024 * 1024
    private let miB: Int64 = 1024 * 1024

    // MARK: - 默认配额

    func testDefaultQuotaProfile() {
        let quota = ConversationQuotaAction.quotaProfile()
        XCTAssertEqual(StorageQuotaProfile.totalBytes, 5 * giB, "总量 5 GiB")
        XCTAssertEqual(StorageQuotaProfile.sessionDatabaseBytes, 1 * giB, "会话 1 GiB")
        XCTAssertEqual(StorageQuotaProfile.attachmentsBytes, 2 * giB, "附件 2 GiB")
        XCTAssertEqual(StorageQuotaProfile.terminalLogsBytes, 2 * giB, "终端日志 2 GiB")
        XCTAssertEqual(StorageQuotaProfile.singleAttachmentBytes, 100 * miB, "单附件 100 MiB")
        XCTAssertEqual(StorageQuotaProfile.singleLogBytes, 100 * miB, "单次日志 100 MiB")
    }

    // MARK: - 90% 预警

    func testWarnsAt90PercentAndStopsAutoDownload() {
        XCTAssertFalse(ConversationQuotaAction.warnsAt90Percent(usedBytes: 4 * giB, totalBytes: 5 * giB))
        XCTAssertTrue(ConversationQuotaAction.warnsAt90Percent(usedBytes: 4_900_000_000, totalBytes: 5 * giB),
                      "达到 90% 预警")
        XCTAssertTrue(ConversationQuotaAction.stopsAutoDownloadingLargeAttachments(atWarning: true),
                      "预警后停止自动下载大附件")
        XCTAssertFalse(ConversationQuotaAction.stopsAutoDownloadingLargeAttachments(atWarning: false))
    }

    // MARK: - 预留与硬上限

    func testSessionDBReservedAndHardLimitBehavior() {
        XCTAssertEqual(ConversationQuotaAction.sessionDBReservedForActiveTurn(), 0.05,
                       "会话数据库预留至少 5% 只用于活动 Turn durable 终态/错误/清理")
        XCTAssertTrue(ConversationQuotaAction.hardLimitPausesNewTurnsButKeepsDraft(),
                      "达到硬上限暂停新 Turn 保留草稿并提供清理入口")
    }

    // MARK: - 自动清理范围

    func testAutoCleanupOnlyExpiredUnpinnedUnreferenced() {
        XCTAssertTrue(ConversationQuotaAction.autoCleanupOnlyExpiredUnpinnedUnreferenced(),
                      "自动清理只处理已超保留期/未固定/不被引用内容")
    }

    // MARK: - Event 物理删除与 checkpoint

    func testEventDeletionRequiresVerifiedSnapshotPrefixAndAtomicCompaction() {
        XCTAssertTrue(ConversationQuotaAction.eventDeletionRequiresVerifiedSnapshotPrefix(),
                      "Event 物理删除只按 verified snapshot 覆盖连续前缀")
        XCTAssertTrue(ConversationQuotaAction.atomicCompactionRequired(), "原子 compaction")
        XCTAssertTrue(ConversationQuotaAction.checkpointCleanupKeepsSequenceSkeleton(),
                      "中间 checkpoint 只清理 payload 保留 sequence skeleton/原 hash/字节数/omission reason")
    }

    // MARK: - 终端日志 ContentOmitted

    func testTerminalLogOmissionRecord() {
        let range = Date(timeIntervalSince1970: 1_700_000_000)...Date(timeIntervalSince1970: 1_700_000_100)
        let record = ConversationQuotaAction.terminalLogOmission(
            originalBytes: 1_000_000, retainedBytes: 10_000, timeRange: range,
            reason: "quota", fullSourceStillExists: true
        )
        XCTAssertEqual(record.originalBytes, 1_000_000, "原始字节数")
        XCTAssertEqual(record.retainedBytes, 10_000, "保留字节数")
        XCTAssertEqual(record.reason, "quota")
        XCTAssertTrue(record.fullSourceStillExists, "完整来源是否仍存在")
        XCTAssertEqual(record.timeRange, range, "时间范围")
    }

    // MARK: - deleteAllV2 门禁

    func testDeleteAllV2RequiresDisabledControlFenceAndSettledSagas() {
        XCTAssertTrue(ConversationQuotaAction.deleteAllV2Allowed(
            controlDisabled: true, maintenanceFenceEngaged: true, sagasFullySettled: true
        ))
        XCTAssertFalse(ConversationQuotaAction.deleteAllV2Allowed(
            controlDisabled: false, maintenanceFenceEngaged: true, sagasFullySettled: true
        ), "仅 control disabled")
        XCTAssertFalse(ConversationQuotaAction.deleteAllV2Allowed(
            controlDisabled: true, maintenanceFenceEngaged: false, sagasFullySettled: true
        ), "需删除维护 fence")
        XCTAssertFalse(ConversationQuotaAction.deleteAllV2Allowed(
            controlDisabled: true, maintenanceFenceEngaged: true, sagasFullySettled: false
        ), "需 setup/binding/use/revoke/delete/outbox/orphan/conflict 全结算")
        XCTAssertTrue(ConversationQuotaAction.deleteAllV2NeverTouchesSharedDBOrCredentials(),
                      "不触碰共用数据库/Provider 凭证/CLI 登录")
    }

    // MARK: - 清空历史与重置

    func testClearHistoryV2OnlyAndResetKeepsConfig() {
        XCTAssertTrue(ConversationQuotaAction.clearHistoryAppliesToV2Only(), "「清空历史」只作用于 V2 会话")
        XCTAssertTrue(ConversationQuotaAction.resetSettingsKeepsProviderConfigAndCredentials(),
                      "resetSettingsAndInstructions 保留 RuntimeConfigurationMetadataKey 加密配置与凭证")
    }
}
