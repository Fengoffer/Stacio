import XCTest
import Foundation
@testable import StacioApp

/// P9-3：Legacy 只读适配（只读不改写、截断边界、role 标签、continuation、snapshot、失败隔离、保留周期）。
final class LegacyConversationHistoryAdapterTests: XCTestCase {

    // MARK: - 只读不改写

    func testReadOnlyNeverModifiesOrCopies() {
        XCTAssertTrue(LegacyConversationHistoryAdapter.readOnlyNeverModifiesOrCopies(),
                      "旧 ai_conversation_history 不删除/不改写/不批量复制；只读按需展示")
    }

    // MARK: - 截断边界

    func testTruncationBoundaries() {
        XCTAssertTrue(LegacyConversationHistoryAdapter.mayBeTruncated(byteCount: 2_048), "2048 字节标记")
        XCTAssertTrue(LegacyConversationHistoryAdapter.mayBeTruncated(byteCount: 2_045), "2045–2047 边界")
        XCTAssertTrue(LegacyConversationHistoryAdapter.mayBeTruncated(byteCount: 2_047))
        XCTAssertFalse(LegacyConversationHistoryAdapter.mayBeTruncated(byteCount: 2_044))
        XCTAssertFalse(LegacyConversationHistoryAdapter.mayBeTruncated(byteCount: 2_049))
        XCTAssertEqual(LegacyConversationHistoryAdapter.truncationWarningDisplay(), "旧版本可能已截断")
    }

    // MARK: - role 标签与 Legacy 区

    func testRoleDisplayByOriginalLabel() {
        XCTAssertEqual(LegacyConversationHistoryAdapter.roleDisplay(.user), "user")
        XCTAssertEqual(LegacyConversationHistoryAdapter.roleDisplay(.assistant), "assistant")
        XCTAssertTrue(LegacyConversationHistoryAdapter.undeterminedGoesToReadOnlyLegacyZone(),
                      "无法确定类型的条目进入只读 Legacy 区，不猜测 V2 事件类型")
    }

    // MARK: - continuation

    func testContinuationRequiresExplicitNewTargetBinding() {
        XCTAssertTrue(LegacyConversationHistoryAdapter.continuationRequiresExplicitNewTargetBinding(),
                      "continuation 必须显式选择并确认新 TargetBinding")
        XCTAssertTrue(LegacyConversationHistoryAdapter.legacyRuntimeIDIsQueryKeyOnly(),
                      "legacyRuntimeID 只作旧表查询键不推断为 V2 TargetBinding")
        let ref = LegacyContinuationReference(
            legacyRuntimeID: "rt-legacy-1", recordID: "rec-9",
            timeRange: Date(timeIntervalSince1970: 1_700_000_000)...Date(timeIntervalSince1970: 1_700_000_100)
        )
        XCTAssertEqual(ref.legacyRuntimeID, "rt-legacy-1")
        XCTAssertEqual(ref.recordID, "rec-9")
        XCTAssertNotNil(ref.timeRange, "保存指向记录 ID/时间范围的 continuation reference")
    }

    // MARK: - 不可变快照

    func testSnapshotCreatedBeforeFirstModelCall() {
        let record = LegacyHistoryRecord(
            recordID: "rec-9", legacyRuntimeID: "rt-legacy-1", role: .assistant,
            text: "旧回答正文", byteCount: 2_046, mayBeTruncated: true
        )
        let snapshot = LegacyConversationHistoryAdapter.snapshot(from: record)
        XCTAssertEqual(snapshot.visibleLegacyText, "旧回答正文", "可见 legacy 文本")
        XCTAssertEqual(snapshot.originID, "rec-9", "origin ID")
        XCTAssertEqual(snapshot.byteCount, 2_046, "字节数")
        XCTAssertTrue(snapshot.truncated, "截断标记")
    }

    // MARK: - 失败隔离与保留周期

    func testReadFailureOnlyAffectsLegacyZone() {
        XCTAssertTrue(LegacyConversationHistoryAdapter.readFailureOnlyAffectsLegacyZone(),
                      "Adapter 读取失败只影响 Legacy 区 V2 仍可用")
    }

    func testKeepAdapterAtLeastOneStableRelease() {
        XCTAssertTrue(LegacyConversationHistoryAdapter.keepReadOnlyAdapterAtLeastOneStableRelease(),
                      "保留旧历史只读适配至少一个稳定发布周期")
    }
}
