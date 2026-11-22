import AppKit
import XCTest
import StacioCoreBindings
@testable import StacioApp

@MainActor
final class TransferProgressPresentationTests: XCTestCase {
    func testAllTransferSurfacesUseAccumulatedSamplesAndShowFinalization() throws {
        let files = FilesViewController()
        let queue = TransferQueueViewController()
        // Rendering time deliberately differs from the progress capture time.
        let popover = TransferQueuePopoverViewController(nowProvider: { Date(timeIntervalSince1970: 999) })
        files.loadView(); queue.loadView(); popover.loadView()
        let total: UInt64 = 100 * 1_048_576
        let job = ScpTransferJob(id: "progress", direction: .upload, sourcePath: "/tmp/large.iso", destinationPath: "/tmp/remote.iso", bytesTotal: total)
        func apply(_ bytes: UInt64, _ seconds: Double, status: String = "running") {
            let snapshot = TransferQueueSnapshot(rows: [.init(jobID: job.id, direction: job.direction, sourcePath: job.sourcePath, destinationPath: job.destinationPath, bytesDone: bytes, bytesTotal: total, rawStatus: status, diagnostic: nil)], capturedAt: Date(timeIntervalSince1970: seconds))
            files.setTransferStatusSnapshot(snapshot)
            popover.apply(snapshot: snapshot)
            queue.setTransfers(jobs: [job], progressEvents: [.init(jobId: job.id, bytesDone: bytes, bytesTotal: total, status: status)], capturedAt: snapshot.capturedAt)
        }
        apply(0, 100)
        for tick in 1...30 {
            apply(UInt64(tick - 1) * 1_048_576, 100 + Double(tick) / 10 - 0.00001)
            apply(UInt64(tick) * 1_048_576, 100 + Double(tick) / 10)
        }
        let label = try XCTUnwrap(descendants(files.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "Stacio.Files.transferStatus" })
        for text in [label.stringValue, queue.visibleTextSnapshot, try XCTUnwrap(popover.rowsForTesting.first).speedText] {
            let match = try XCTUnwrap(text.range(of: #"[0-9]+(?:\.[0-9]+)? MB/s"#, options: .regularExpression))
            let rate = try XCTUnwrap(Double(text[match].split(separator: " ")[0]))
            XCTAssertEqual(rate, 10, accuracy: 2, text)
        }
        apply(30 * 1_048_576, 105)
        XCTAssertTrue(label.stringValue.contains("0 B/s"))
        XCTAssertFalse(label.stringValue.contains("剩余"))
        XCTAssertEqual(popover.rowsForTesting.first?.speedText, "0 B/s")
        apply(total, 106)
        XCTAssertTrue(label.stringValue.contains("等待确认传输结果"))
        XCTAssertFalse(label.stringValue.contains("剩余 0"))
        XCTAssertFalse(label.stringValue.contains("MB/s"))
        XCTAssertTrue(queue.visibleTextSnapshot.contains("等待确认传输结果"))
        XCTAssertEqual(popover.rowsForTesting.first?.remainingText, "等待确认传输结果")
        apply(total, 107, status: "completed")
        XCTAssertTrue(label.stringValue.contains("已完成"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }
}
