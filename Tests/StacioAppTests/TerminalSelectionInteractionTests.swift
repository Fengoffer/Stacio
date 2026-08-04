import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class TerminalSelectionInteractionTests: XCTestCase {
    func testPointerSelectionDefersClipboardCopyUntilMouseUp() {
        var gate = TerminalSelectionAutoCopyGate()

        gate.beginPointerSelection()

        XCTAssertFalse(gate.shouldCopyAfterSelectionChanged())
        XCTAssertFalse(gate.shouldCopyAfterSelectionChanged())
        XCTAssertTrue(gate.shouldCopyAfterMouseUp())
        XCTAssertFalse(gate.shouldCopyAfterMouseUp())
    }

    func testProgrammaticSelectionStillCopiesImmediately() {
        var gate = TerminalSelectionAutoCopyGate()

        XCTAssertTrue(gate.shouldCopyAfterSelectionChanged())
        XCTAssertFalse(gate.shouldCopyAfterMouseUp())
    }

    func testLinkInteractionMonitorDoesNotObserveDragEvents() {
        let mask = TerminalLinkInteraction.monitoredEventMask

        XCTAssertTrue(mask.contains(.leftMouseDown))
        XCTAssertTrue(mask.contains(.leftMouseUp))
        XCTAssertTrue(mask.contains(.mouseMoved))
        XCTAssertTrue(mask.contains(.flagsChanged))
        XCTAssertFalse(mask.contains(.leftMouseDragged))
    }
}
