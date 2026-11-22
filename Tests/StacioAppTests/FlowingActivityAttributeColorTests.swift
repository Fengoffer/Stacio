import AppKit
import XCTest
@testable import StacioApp

final class FlowingActivityAttributeColorTests: XCTestCase {
    /// The timeline assigns an attributed string whose own colour would win
    /// over textColor, leaving the glyphs opaque and the gradient hidden.
    func testEnablingEffectClearsAttributeColour() {
        let field = FlowingActivityTextField(wrappingLabelWithString: "")
        field.attributedStringValue = NSAttributedString(
            string: "执行中…",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 18), styleMask: [], backing: .buffered, defer: false)
        window.contentView = field
        field.setFlowingActivityEffectEnabled(true)
        let resolved = field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(resolved, NSColor.clear, "启用效果后文字必须透明，否则遮罩与渐变都看不到")
    }

    func testDisablingEffectRestoresReadableColour() {
        let field = FlowingActivityTextField(wrappingLabelWithString: "")
        field.attributedStringValue = NSAttributedString(string: "执行中…")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 18), styleMask: [], backing: .buffered, defer: false)
        window.contentView = field
        field.setFlowingActivityEffectEnabled(true)
        field.setFlowingActivityEffectEnabled(false)
        let resolved = field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(resolved, NSColor.clear, "关闭后必须恢复可读颜色")
    }
}