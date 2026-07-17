import XCTest
@testable import StacioApp

@MainActor
final class TransferCompletionNotificationPresenterTests: XCTestCase {
    func testPresenterAggregatesCompletedTransfersIntoOnePersistentListPanel() {
        let delivery = RecordingStacioUserNotificationDelivery()
        let presenter = TransferCompletionNotificationPresenter(notificationDelivery: delivery)
        defer { presenter.dismissAll() }
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "上传“release”已完成。",
            itemName: "release",
            byteCount: 4_096,
            completedAt: Date(timeIntervalSince1970: 1_721_111_111),
            duration: 4,
            averageBytesPerSecond: 1_024
        ))
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_two",
            runtimeID: "runtime_two",
            status: .completed,
            title: "文件传输完成",
            body: "上传“assets.tar”已完成。",
            itemName: "assets.tar",
            byteCount: 2_097_152,
            completedAt: Date(timeIntervalSince1970: 1_721_111_115),
            duration: 2,
            averageBytesPerSecond: 1_048_576
        ))

        XCTAssertEqual(presenter.visiblePanelCountForTesting, 1)
        XCTAssertEqual(presenter.visibleNotificationCountForTesting, 2)
        XCTAssertEqual(presenter.visibleListRowsForTesting.map(\.itemName), ["assets.tar", "release"])
        XCTAssertTrue(presenter.visibleListRowsForTesting[0].detailText.contains("大小"))
        XCTAssertTrue(presenter.visibleListRowsForTesting[0].detailText.contains("MB"))
        XCTAssertTrue(presenter.visibleListRowsForTesting[0].detailText.contains("完成时间"))
        XCTAssertTrue(presenter.visibleListRowsForTesting[0].detailText.contains("用时 2 秒"))
        XCTAssertTrue(presenter.visibleListRowsForTesting[0].detailText.contains("平均速率 1 MB/s"))
        XCTAssertTrue(presenter.visibleListRowsForTesting[1].detailText.contains("平均速率 1 KB/s"))
    }

    func testPresenterRemovesOnlyNotificationsForClosedRuntime() {
        let delivery = RecordingStacioUserNotificationDelivery()
        let presenter = TransferCompletionNotificationPresenter(notificationDelivery: delivery)
        defer { presenter.dismissAll() }
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "上传“one.tar”已完成。"
        ))
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_two",
            runtimeID: "runtime_two",
            status: .failed,
            title: "文件传输失败",
            body: "下载“two.tar”失败。"
        ))

        presenter.dismiss(runtimeID: "runtime_one")

        XCTAssertEqual(presenter.visibleNotificationCountForTesting, 1)
        XCTAssertEqual(presenter.visiblePanelCountForTesting, 1)
        XCTAssertEqual(presenter.visibleListRowsForTesting.map(\.itemName), ["文件传输失败"])
        XCTAssertEqual(delivery.removedIdentifierBatches, [["Stacio.transfer.job_one"]])
        XCTAssertEqual(delivery.deliveredPayloads.map(\.identifier), [
            "Stacio.transfer.job_one",
            "Stacio.transfer.job_two"
        ])
        XCTAssertTrue(delivery.deliveredPayloads.allSatisfy {
            $0.retentionPolicy == .explicitRemoval
        })
    }

    func testPresenterUpdatesRepeatedJobWithoutAddingDuplicateListRow() {
        let delivery = RecordingStacioUserNotificationDelivery()
        let presenter = TransferCompletionNotificationPresenter(notificationDelivery: delivery)
        defer { presenter.dismissAll() }
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .failed,
            title: "文件传输失败",
            body: "上传失败。",
            itemName: "release.tar"
        ))
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "上传完成。",
            itemName: "release.tar",
            byteCount: 1_024
        ))

        XCTAssertEqual(presenter.visiblePanelCountForTesting, 1)
        XCTAssertEqual(presenter.visibleNotificationCountForTesting, 1)
        XCTAssertEqual(presenter.visibleListRowsForTesting.map(\.itemName), ["release.tar"])
        XCTAssertEqual(presenter.visibleListRowsForTesting.map(\.statusText), ["已完成"])
        XCTAssertEqual(delivery.removedIdentifierBatches, [["Stacio.transfer.job_one"]])
    }

    func testPresenterMovesRepeatedJobBackToTopOfCompletionList() {
        let delivery = RecordingStacioUserNotificationDelivery()
        let presenter = TransferCompletionNotificationPresenter(notificationDelivery: delivery)
        defer { presenter.dismissAll() }
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .failed,
            title: "文件传输失败",
            body: "one failed",
            itemName: "one.tar"
        ))
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_two",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "two completed",
            itemName: "two.tar"
        ))
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "one completed",
            itemName: "one.tar"
        ))

        XCTAssertEqual(presenter.visibleListRowsForTesting.map(\.itemName), ["one.tar", "two.tar"])
        XCTAssertEqual(presenter.visibleListRowsForTesting.map(\.statusText), ["已完成", "已完成"])
    }

    func testPresenterScrollsNewestCompletionBackIntoViewAfterUserScrolledDown() throws {
        let delivery = RecordingStacioUserNotificationDelivery()
        let presenter = TransferCompletionNotificationPresenter(notificationDelivery: delivery)
        defer { presenter.dismissAll() }

        for index in 1...12 {
            presenter.present(TransferCompletionNotificationPayload(
                jobID: "job_\(index)",
                runtimeID: "runtime_one",
                status: .completed,
                title: "文件传输完成",
                body: "completed",
                itemName: "item-\(index).tar"
            ))
        }

        presenter.scrollCompletionListToBottomForTesting()
        XCTAssertGreaterThan(try XCTUnwrap(presenter.firstVisibleListRowForTesting), 0)

        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_13",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "completed",
            itemName: "item-13.tar"
        ))

        XCTAssertEqual(presenter.visibleListRowsForTesting.first?.itemName, "item-13.tar")
        XCTAssertEqual(presenter.firstVisibleListRowForTesting, 0)
    }

    func testCompletionListColumnFillsAvailableViewportWidth() throws {
        let presenter = TransferCompletionNotificationPresenter(
            notificationDelivery: RecordingStacioUserNotificationDelivery()
        )
        defer { presenter.dismissAll() }
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_geometry",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "completed",
            itemName: "release-assets-with-a-long-name.tar",
            byteCount: 8_192,
            completedAt: Date(timeIntervalSince1970: 1_721_111_111),
            duration: 65,
            averageBytesPerSecond: 1_024
        ))

        let geometry = try XCTUnwrap(presenter.listGeometryForTesting)
        XCTAssertGreaterThan(geometry.viewportWidth, 400)
        XCTAssertGreaterThanOrEqual(geometry.columnWidth, geometry.viewportWidth * 0.9)
    }

    func testDismissAllRemovesTransferIdentifiersWithoutClearingOtherNotifications() {
        let delivery = RecordingStacioUserNotificationDelivery()
        let presenter = TransferCompletionNotificationPresenter(notificationDelivery: delivery)
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_one",
            runtimeID: "runtime_one",
            status: .completed,
            title: "文件传输完成",
            body: "上传“one.tar”已完成。"
        ))
        presenter.present(TransferCompletionNotificationPayload(
            jobID: "job_two",
            runtimeID: "runtime_two",
            status: .failed,
            title: "文件传输失败",
            body: "下载“two.tar”失败。"
        ))

        presenter.dismissAll()

        XCTAssertEqual(presenter.visibleNotificationCountForTesting, 0)
        XCTAssertEqual(Set(delivery.removedIdentifierBatches.flatMap { $0 }), Set([
            "Stacio.transfer.job_one",
            "Stacio.transfer.job_two"
        ]))
    }
}

private final class RecordingStacioUserNotificationDelivery: StacioUserNotificationDelivering {
    private(set) var deliveredPayloads: [StacioUserNotificationPayload] = []
    private(set) var removedIdentifierBatches: [[String]] = []

    func deliver(_ payload: StacioUserNotificationPayload) {
        deliveredPayloads.append(payload)
    }

    func setActivationHandler(_ handler: @escaping (String) -> Void) {}

    func removeNotifications(identifiers: [String]) {
        removedIdentifierBatches.append(identifiers)
    }
}
