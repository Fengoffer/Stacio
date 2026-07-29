import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class TransferQueuePopoverViewControllerTests: XCTestCase {
    func testPopoverRowsExposeProgressSpeedElapsedRemainingAndNativeActions() throws {
        var now = Date(timeIntervalSince1970: 100)
        let controller = TransferQueuePopoverViewController(nowProvider: { now })
        controller.loadView()
        controller.apply(snapshot: TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "queue-live",
                direction: .download,
                sourcePath: "/srv/archive.iso",
                destinationPath: "/tmp/archive.iso",
                bytesDone: 40,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil,
                runtimeID: "session-a",
                elapsedTime: 4,
                finishedAt: nil
            )
        ], capturedAt: now))
        now = Date(timeIntervalSince1970: 102)
        controller.apply(snapshot: TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "queue-live",
                direction: .download,
                sourcePath: "/srv/archive.iso",
                destinationPath: "/tmp/archive.iso",
                bytesDone: 60,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil,
                runtimeID: "session-a",
                elapsedTime: 6,
                finishedAt: nil
            )
        ], capturedAt: now))

        let row = try XCTUnwrap(controller.rowsForTesting.first)
        XCTAssertEqual(row.fileName, "archive.iso")
        XCTAssertEqual(row.percentText, "60%")
        XCTAssertEqual(row.speedText, "10 B/s")
        XCTAssertEqual(row.elapsedText, "已用 6 秒")
        XCTAssertEqual(row.remainingText, "剩余 4 秒")
        XCTAssertEqual(row.primaryActionLabel, "暂停")
        XCTAssertTrue(row.canCancel)
        XCTAssertEqual(controller.activeTransferCountForTesting, 1)
        XCTAssertFalse(controller.backgroundButtonForTesting.isHidden)
        XCTAssertNotNil(
            controller.view.firstDescendant(ofType: NSProgressIndicator.self),
            "每个传输任务必须使用原生进度条"
        )
    }

    func testBackgroundButtonOnlyAppearsWhileTransferIsActiveAndCollapsesPopover() {
        let controller = TransferQueuePopoverViewController()
        controller.loadView()
        var collapseCount = 0
        controller.onCollapseRequested = { collapseCount += 1 }
        controller.apply(snapshot: TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "queue-complete",
                direction: .upload,
                sourcePath: "/tmp/report.zip",
                destinationPath: "/srv/report.zip",
                bytesDone: 100,
                bytesTotal: 100,
                rawStatus: "completed",
                diagnostic: nil,
                runtimeID: "session-a",
                elapsedTime: 5,
                finishedAt: Date(timeIntervalSince1970: 100)
            )
        ]))
        XCTAssertTrue(controller.backgroundButtonForTesting.isHidden)

        controller.apply(snapshot: TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "queue-running",
                direction: .upload,
                sourcePath: "/tmp/report.zip",
                destinationPath: "/srv/report.zip",
                bytesDone: 10,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil,
                runtimeID: "session-a",
                elapsedTime: 1,
                finishedAt: nil
            )
        ]))
        XCTAssertFalse(controller.backgroundButtonForTesting.isHidden)
        controller.backgroundButtonForTesting.performClick(nil as Any?)
        XCTAssertEqual(collapseCount, 1)
    }

    func testPopoverKeepsNativeMaterialAndStableLayoutForLongNamesInLightAndDarkModes() throws {
        let sourcePath = "/srv/releases/2026/07/这是一段非常长的传输文件名-包含版本号和用于验证中间截断布局的附加说明-final-universal.dmg"
        let destinationPath = "/Users/tester/Downloads/这是一段非常长的传输文件名-包含版本号和用于验证中间截断布局的附加说明-final-universal.dmg"

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let controller = TransferQueuePopoverViewController()
            controller.loadView()
            controller.view.appearance = NSAppearance(named: appearanceName)
            controller.view.frame = NSRect(origin: .zero, size: controller.preferredContentSize)
            controller.apply(snapshot: TransferQueueSnapshot(rows: [
                TransferQueueSnapshot.Row(
                    jobID: "long-name-\(appearanceName.rawValue)",
                    direction: .download,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    bytesDone: 512,
                    bytesTotal: 1_024,
                    rawStatus: "running",
                    diagnostic: nil,
                    runtimeID: "session-long-name",
                    elapsedTime: 8,
                    finishedAt: nil
                )
            ]))
            controller.view.layoutSubtreeIfNeeded()

            let materialView = try XCTUnwrap(controller.view as? NSVisualEffectView)
            XCTAssertEqual(materialView.material, .popover)
            XCTAssertEqual(controller.preferredContentSize, NSSize(width: 520, height: 460))
            XCTAssertFalse(controller.view.allDescendants.contains(where: \.hasAmbiguousLayout))

            let fileName = (sourcePath as NSString).lastPathComponent
            let fileNameLabel = try XCTUnwrap(
                controller.view.allDescendants
                    .compactMap { $0 as? NSTextField }
                    .first(where: { $0.stringValue == fileName })
            )
            XCTAssertEqual(fileNameLabel.lineBreakMode, .byTruncatingMiddle)
            XCTAssertEqual(fileNameLabel.toolTip, "\(sourcePath) → \(destinationPath)")
            XCTAssertGreaterThan(fileNameLabel.frame.width, 0)
            XCTAssertLessThanOrEqual(fileNameLabel.frame.maxX, fileNameLabel.superview?.bounds.maxX ?? 0)

            let buttons = controller.view.allDescendants.compactMap { $0 as? NSButton }
            XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "暂停" && $0.isHidden == false })
            XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "取消任务" && $0.isHidden == false })
            XCTAssertTrue(controller.backgroundButtonForTesting.isHidden == false)
        }
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
