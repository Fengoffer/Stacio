import AppKit
import XCTest
@testable import StacioApp

final class FlowingActivityMaskTests: XCTestCase {
    /// The gradient is clipped by a text mask; an empty mask hides the effect
    /// entirely, which is indistinguishable from the feature being off.
    func testMaskCoversTheGlyphsAfterLayout() {
        let field = FlowingActivityTextField(wrappingLabelWithString: "执行中…")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 18)
        let window = NSWindow(contentRect: field.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = field
        field.layoutSubtreeIfNeeded()
        field.setFlowingActivityEffectEnabled(true)
        field.layoutSubtreeIfNeeded()
        print("MASK=", field.textMaskFrameForTesting, "BOUNDS=", field.bounds)
        XCTAssertGreaterThan(field.textMaskFrameForTesting.width, 1, "遮罩宽度必须覆盖文字")
        XCTAssertGreaterThan(field.textMaskFrameForTesting.height, 1)
    }
}