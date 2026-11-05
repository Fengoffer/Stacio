import XCTest
import Foundation
@testable import StacioApp

/// P4-15：通知设置接线（事件集合、长等待单次提醒、前台/可见性门禁、正文净化）。
final class NotificationSettingsTests: XCTestCase {

    // MARK: - 可通知事件集合

    func testDefaultEnabledEvents() {
        let events = NotificationSettingsAction.defaultEnabledEvents()
        for event in [NotificationEventID.completion, .failure, .capacityGrantedLongWait,
                      .waitingApproval, .waitingUser, .revocation, .orphanUnknownEffect] {
            XCTAssertTrue(events.contains(event), "默认可通知：\(event.rawValue)")
        }
        XCTAssertEqual(events.count, 7)
    }

    // MARK: - longCapacityWaitMinutes

    func testLongCapacityWaitDefaultAndRange() {
        XCTAssertEqual(NotificationSettingsAction.longCapacityWaitDefault(), 5)
        XCTAssertTrue(NotificationSettingsAction.validateLongCapacityWaitMinutes(1))
        XCTAssertTrue(NotificationSettingsAction.validateLongCapacityWaitMinutes(5))
        XCTAssertTrue(NotificationSettingsAction.validateLongCapacityWaitMinutes(30))
        XCTAssertFalse(NotificationSettingsAction.validateLongCapacityWaitMinutes(0))
        XCTAssertFalse(NotificationSettingsAction.validateLongCapacityWaitMinutes(31))
    }

    func testReminderDeadlinePerRequestAndNotRetroactive() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let now = created.addingTimeInterval(6 * 60) // 6 分钟后
        // deadline = 创建 + 5min；now 已过 → 返回 deadline
        let deadline = NotificationSettingsAction.reminderDeadline(
            requestCreatedAt: created, configuredMinutes: 5, now: now
        )
        XCTAssertEqual(deadline, created.addingTimeInterval(5 * 60))
        // 未到 deadline → nil
        XCTAssertNil(NotificationSettingsAction.reminderDeadline(
            requestCreatedAt: created, configuredMinutes: 5, now: created.addingTimeInterval(60)
        ))
        // 非法配置 → nil（修改不追溯：配置变化不重算既有 request 的 deadline）
        XCTAssertNil(NotificationSettingsAction.reminderDeadline(
            requestCreatedAt: created, configuredMinutes: 99, now: now
        ))
    }

    func testEachRequestRemindedOnce() {
        var reminded: Set<String> = []
        XCTAssertFalse(NotificationSettingsAction.alreadyReminded(requestID: "r-1", remindedRequestIDs: reminded))
        NotificationSettingsAction.markReminded(requestID: "r-1", reminded: &reminded)
        XCTAssertTrue(NotificationSettingsAction.alreadyReminded(requestID: "r-1", remindedRequestIDs: reminded),
                      "每个 request 最多提醒一次")
    }

    // MARK: - 前台/可见性门禁

    func testNotifyOnlyWhenNotForegroundOrHidden() {
        XCTAssertFalse(NotificationSettingsAction.shouldNotify(appIsForeground: true, sessionVisible: true))
        XCTAssertTrue(NotificationSettingsAction.shouldNotify(appIsForeground: false, sessionVisible: true), "非前台通知")
        XCTAssertTrue(NotificationSettingsAction.shouldNotify(appIsForeground: true, sessionVisible: false), "会话不可见通知")
        XCTAssertTrue(NotificationSettingsAction.onlyWhenNotForegroundOrHidden())
    }

    // MARK: - 正文净化

    func testNotificationBodyNeverContainsForbiddenContent() {
        XCTAssertTrue(NotificationSettingsAction.containsForbiddenContent("prompt 已生成"))
        XCTAssertTrue(NotificationSettingsAction.containsForbiddenContent("host: server"))
        XCTAssertTrue(NotificationSettingsAction.containsForbiddenContent("路径 /Users/mac/x"))
        XCTAssertTrue(NotificationSettingsAction.containsForbiddenContent("secret=abc"))
        XCTAssertFalse(NotificationSettingsAction.containsForbiddenContent("任务完成"))
        XCTAssertEqual(NotificationSettingsAction.sanitizedBody("secret=abc"), "（已脱敏）")
        XCTAssertEqual(NotificationSettingsAction.sanitizedBody("任务完成"), "任务完成")
    }

    // MARK: - 容量长等待提醒不改调度

    func testLongWaitReminderDoesNotChangeScheduling() {
        XCTAssertTrue(NotificationSettingsAction.reminderDoesNotChangeFIFO(), "不改 FIFO")
        XCTAssertTrue(NotificationSettingsAction.reminderDoesNotChangeWaitDeadline(), "不改等待 deadline")
        XCTAssertTrue(NotificationSettingsAction.reminderDoesNotChangeAutoCancel(), "不改自动取消行为")
    }
}
