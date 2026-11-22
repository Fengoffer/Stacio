import XCTest
import AppKit
@testable import StacioApp

/// Assigning a long attributed string to a wrapping NSTextField triggers a full
/// layout pass. That, not the markdown parse, is what stalls a streaming answer.
final class AITextFieldLayoutCostTests: XCTestCase {
 func testLongAnswerLayoutCost() {
 let body = String(repeating: "这一行是一段用于测试的正文，包含若干中文字符与 ENGLISH单词。\n", count:60)
 let attributed = AIAssistantMarkdownRenderer.attributedString(from: body)
 let field = NSTextField(wrappingLabelWithString: "")
 field.frame = NSRect(x:0, y:0, width:360, height:2000)
 let window = NSWindow(contentRect: field.frame, styleMask: [], backing: .buffered, defer: false)
 window.contentView = field

 let started = CFAbsoluteTimeGetCurrent()
 for _ in 0..<10 {
 field.attributedStringValue = attributed
 field.invalidateIntrinsicContentSize()
 field.layoutSubtreeIfNeeded()
 }
 let each = (CFAbsoluteTimeGetCurrent() - started) / 10
 print("TEXTFIELD_MS=", each * 1000)
 XCTAssertLessThan(each, 0.2, "单次布局应低于200ms")
 }
}
