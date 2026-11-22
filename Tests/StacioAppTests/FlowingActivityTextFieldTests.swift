import AppKit
import XCTest
@testable import StacioApp

final class FlowingActivityTextFieldTests: XCTestCase {
    /// The status row must actually animate: enabling the effect has to leave a
    /// repeating animation on the gradient layer once the field is laid out.
    func testEnablingEffectStartsGradientAnimation() {
        let field = FlowingActivityTextField(wrappingLabelWithString: "执行中…")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 18)
        let window = NSWindow(contentRect: field.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = field
        field.setFlowingActivityEffectEnabled(true)
        field.layoutSubtreeIfNeeded()
        field.refreshAnimationStateForTesting()
        XCTAssertTrue(field.isFlowingActivityEffectEnabled)
        XCTAssertNotNil(field.gradientAnimationKeyCountForTesting, "启用后应存在渐变动画")
    }
}