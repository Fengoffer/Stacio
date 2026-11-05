import Foundation
import XCTest
@testable import StacioApp

final class TerminalCommandCompletionNotificationCoordinatorTests: XCTestCase {
    func testLongCommandFinishesWhileTerminalInactiveDeliversNotification() {
        var now = Date(timeIntervalSince1970: 1_000)
        let notifier = RecordingCommandCompletionNotifier()
        let settings = AppSettings(
            terminalCommandCompletionNotificationEnabled: true,
            terminalCommandCompletionNotificationThresholdSeconds: 5
        )
        let coordinator = TerminalCommandCompletionNotificationCoordinator(
            settingsProvider: { settings },
            dateProvider: { now },
            activeTerminalProvider: { _ in false },
            notifier: notifier
        )
        let command = String(repeating: "a", count: 90)

        coordinator.commandDidStart(
            runtimeID: "term_remote",
            sessionTitle: "deploy@example.com",
            command: command
        )
        now = now.addingTimeInterval(6)
        coordinator.commandDidFinish(runtimeID: "term_remote", sessionTitle: "deploy@example.com")

        XCTAssertEqual(notifier.payloads.count, 1)
        let payload = notifier.payloads[0]
        XCTAssertEqual(payload.runtimeID, "term_remote")
        XCTAssertEqual(payload.title, "命令已完成")
        XCTAssertTrue(payload.body.contains(String(repeating: "a", count: 80)))
        XCTAssertFalse(payload.body.contains(String(repeating: "a", count: 81)))
        XCTAssertTrue(payload.body.contains("deploy@example.com"))
    }

    func testCommandBelowThresholdDoesNotDeliverNotification() {
        var now = Date(timeIntervalSince1970: 1_000)
        let notifier = RecordingCommandCompletionNotifier()
        let settings = AppSettings(
            terminalCommandCompletionNotificationEnabled: true,
            terminalCommandCompletionNotificationThresholdSeconds: 5
        )
        let coordinator = TerminalCommandCompletionNotificationCoordinator(
            settingsProvider: { settings },
            dateProvider: { now },
            activeTerminalProvider: { _ in false },
            notifier: notifier
        )

        coordinator.commandDidStart(
            runtimeID: "term_local",
            sessionTitle: "本地",
            command: "sleep 1"
        )
        now = now.addingTimeInterval(4.9)
        coordinator.commandDidFinish(runtimeID: "term_local", sessionTitle: "本地")

        XCTAssertTrue(notifier.payloads.isEmpty)
    }

    func testForegroundActiveTerminalDoesNotDeliverNotification() {
        var now = Date(timeIntervalSince1970: 1_000)
        let notifier = RecordingCommandCompletionNotifier()
        let settings = AppSettings(
            terminalCommandCompletionNotificationEnabled: true,
            terminalCommandCompletionNotificationThresholdSeconds: 5
        )
        let coordinator = TerminalCommandCompletionNotificationCoordinator(
            settingsProvider: { settings },
            dateProvider: { now },
            activeTerminalProvider: { runtimeID in runtimeID == "term_local" },
            notifier: notifier
        )

        coordinator.commandDidStart(
            runtimeID: "term_local",
            sessionTitle: "本地",
            command: "sleep 10"
        )
        now = now.addingTimeInterval(10)
        coordinator.commandDidFinish(runtimeID: "term_local", sessionTitle: "本地")

        XCTAssertTrue(notifier.payloads.isEmpty)
    }
}

private final class RecordingCommandCompletionNotifier: TerminalCommandCompletionNotificationDelivering {
    private(set) var payloads: [TerminalCommandCompletionNotificationPayload] = []

    func deliver(_ payload: TerminalCommandCompletionNotificationPayload) {
        payloads.append(payload)
    }
}
