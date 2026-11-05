import XCTest
import Foundation
@testable import StacioApp

/// P3-7：ConversationSnapshotPolicy（checkpoint 阈值 + 强制 flush + 磁盘门禁 + SecureInput 豁免）。
final class ConversationSnapshotPolicyTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func defaultThresholds() -> SnapshotThresholds {
        SnapshotThresholds()
    }

    func testModelBodyByteThresholdTriggersFlush() {
        // 模型正文 1s/16KiB：字节先到 → flush
        let decision = ConversationSnapshotPolicy.shouldCheckpoint(
            kind: .modelBody,
            lastCheckpointAt: Self.fixedDate,
            accumulatedBytes: 16 * 1024,
            now: Self.fixedDate.addingTimeInterval(0.2),
            thresholds: defaultThresholds(),
            secureInputActive: false
        )
        XCTAssertTrue(decision.shouldCheckpoint, "16KiB 阈值先到必须 flush")
        XCTAssertEqual(decision.reason, .byteThreshold(kind: .modelBody))
    }

    func testModelBodyIntervalTriggersFlush() {
        // 间隔先到（未超字节）→ flush
        let decision = ConversationSnapshotPolicy.shouldCheckpoint(
            kind: .modelBody,
            lastCheckpointAt: Self.fixedDate,
            accumulatedBytes: 1_000,
            now: Self.fixedDate.addingTimeInterval(1.2),
            thresholds: defaultThresholds(),
            secureInputActive: false
        )
        XCTAssertTrue(decision.shouldCheckpoint, "1s 间隔先到必须 flush")
        XCTAssertEqual(decision.reason, .intervalElapsed(kind: .modelBody))
    }

    func testTerminalOutputUses64KiBThreshold() {
        // 终端输出 1s/64KiB
        let under = ConversationSnapshotPolicy.shouldCheckpoint(
            kind: .terminalOutput,
            lastCheckpointAt: Self.fixedDate,
            accumulatedBytes: 60 * 1024,
            now: Self.fixedDate.addingTimeInterval(0.5),
            thresholds: defaultThresholds(),
            secureInputActive: false
        )
        XCTAssertFalse(under.shouldCheckpoint, "60KiB 未到 64KiB 阈值不 flush")
        let at = ConversationSnapshotPolicy.shouldCheckpoint(
            kind: .terminalOutput,
            lastCheckpointAt: Self.fixedDate,
            accumulatedBytes: 64 * 1024,
            now: Self.fixedDate.addingTimeInterval(0.5),
            thresholds: defaultThresholds(),
            secureInputActive: false
        )
        XCTAssertTrue(at.shouldCheckpoint, "64KiB 阈值必须 flush")
    }

    func testNoFlushBeforeEitherThreshold() {
        let decision = ConversationSnapshotPolicy.shouldCheckpoint(
            kind: .modelBody,
            lastCheckpointAt: Self.fixedDate,
            accumulatedBytes: 100,
            now: Self.fixedDate.addingTimeInterval(0.3),
            thresholds: defaultThresholds(),
            secureInputActive: false
        )
        XCTAssertFalse(decision.shouldCheckpoint)
        XCTAssertNil(decision.reason)
    }

    func testForceFlushBeforeDecisionEffectStopTerminal() {
        // 进入 Decision/执行 Effect/停止/终态前强制 flush
        for boundary in [ConversationFlushBoundary.enteringDecision,
                         .executingEffect,
                         .stopping,
                         .terminalState] {
            XCTAssertTrue(
                ConversationSnapshotPolicy.forceFlushBefore(boundary),
                "\(boundary) 前必须强制 flush"
            )
        }
    }

    func testSecureInputPeriodExcludedFromCheckpoint() {
        // SecureInputLease 期间暂停 checkpoint：不 flush、不计为意外丢失
        let decision = ConversationSnapshotPolicy.shouldCheckpoint(
            kind: .modelBody,
            lastCheckpointAt: Self.fixedDate,
            accumulatedBytes: 20 * 1024,
            now: Self.fixedDate.addingTimeInterval(3.0),
            thresholds: defaultThresholds(),
            secureInputActive: true
        )
        XCTAssertFalse(decision.shouldCheckpoint)
        XCTAssertTrue(decision.omittedDuringSecureInput, "SecureInput 期间豁免是安全隔离而非丢失")
    }

    func testDiskInsufficientPausesNewTurns() {
        XCTAssertTrue(
            ConversationSnapshotPolicy.diskInsufficientBlocksNewTurn(
                availableBytes: 1_000, minimumRequired: 10_000
            ),
            "磁盘不足必须暂停新 Turn"
        )
        XCTAssertFalse(
            ConversationSnapshotPolicy.diskInsufficientBlocksNewTurn(
                availableBytes: 100_000, minimumRequired: 10_000
            )
        )
    }
}

/// P3-7：ConversationRetentionPolicy（保留/配额门禁）。
final class ConversationRetentionPolicyTests: XCTestCase {

    func testQuotaBlocksNewConversationWhenCountExceeded() {
        let policy = ConversationRetentionPolicy(maxConversationCount: 4, maxConversationBytes: 1_000_000)
        XCTAssertTrue(policy.allowsNewConversation(currentCount: 3, currentBytes: 100))
        XCTAssertFalse(policy.allowsNewConversation(currentCount: 4, currentBytes: 100), "会话数超配额拒绝")
    }

    func testQuotaBlocksNewConversationWhenBytesExceeded() {
        let policy = ConversationRetentionPolicy(maxConversationCount: 100, maxConversationBytes: 10_000)
        XCTAssertTrue(policy.allowsNewConversation(currentCount: 1, currentBytes: 9_000))
        XCTAssertFalse(policy.allowsNewConversation(currentCount: 1, currentBytes: 10_000), "字节超配额拒绝")
    }

    func testAllowsAppendWithinQuota() {
        let policy = ConversationRetentionPolicy(maxConversationCount: 100, maxConversationBytes: 10_000)
        XCTAssertTrue(policy.allowsAppend(currentBytes: 8_000, additionalBytes: 1_500))
        XCTAssertFalse(policy.allowsAppend(currentBytes: 8_000, additionalBytes: 2_500), "追加超配额拒绝")
    }
}
