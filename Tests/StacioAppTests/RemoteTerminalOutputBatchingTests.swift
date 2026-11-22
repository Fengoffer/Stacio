import AppKit
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class RemoteTerminalOutputBatchingTests: XCTestCase {
    func testScrollingOutputUpdatesViewportOnceAndPreservesEveryLine() {
        let view = StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.changeScrollback(2_000)
        var viewportUpdates = 0
        view.onSearchViewportChanged = { viewportUpdates += 1 }
        let output = (0..<1_000).map { "batch-line-\($0)\r\n" }.joined()
        view.feedRemoteOutput(Array(output.utf8), applySemanticHighlighting: false)
        waitForDelivery { viewportUpdates > 0 }

        XCTAssertEqual(viewportUpdates, 1, "Output should refresh the viewport once per batch, not once per line")
        let rendered = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        let lines = rendered.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("batch-line-") }
        XCTAssertEqual(lines, (0..<1_000).map { "batch-line-\($0)" })
        XCTAssertFalse(view.isProcessingRemoteOutput)

        viewportUpdates = 0
        view.scrollTo(row: 0)
        XCTAssertEqual(view.getTerminal().getTopVisibleRow(), 0)
        view.scrolled(source: view.getTerminal(), yDisp: 0)
        XCTAssertEqual(viewportUpdates, 1, "Scroll callbacks outside output delivery must notify synchronously")
    }

    func testNonScrollingOutputStillUpdatesSearchAndSubsequentBatchesKeepOrder() {
        let view = StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        var viewportUpdates = 0
        view.onSearchViewportChanged = { viewportUpdates += 1 }
        view.feedRemoteOutput(Array("first\r\n".utf8), applySemanticHighlighting: false)
        view.feedRemoteOutput(Array("second\r\n".utf8), applySemanticHighlighting: false)
        XCTAssertEqual(viewportUpdates, 2)
        let rendered = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(rendered.contains("first"))
        XCTAssertTrue(rendered.contains("second"))
        XCTAssertFalse(view.isProcessingRemoteOutput)
    }

    private func waitForDelivery(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for terminal delivery")
    }
}
