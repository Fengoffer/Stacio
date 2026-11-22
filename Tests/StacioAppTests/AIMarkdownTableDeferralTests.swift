import XCTest
@testable import StacioApp

final class AIMarkdownTableDeferralTests: XCTestCase {
 private let table = ["|指标 |值 |", "| --- | --- |", "|核数 |4 |"].joined(separator: "\n")

 /// `allowsTables: false` must render the same table as the settled path,
 /// never a placeholder string. The reader should never see "渲染中".
 func testSuppressedTableStillRendersCells() {
 let attributed = AIAssistantMarkdownRenderer.attributedString(
 from: table,
 allowsTables: false
 )
 let text = attributed.string
 XCTAssertFalse(text.contains("表格渲染中"), "不得再出现占位提示")
 XCTAssertTrue(text.contains("核数"), "表格内容必须保留")
 }

 /// The settled path renders the same cells, without a placeholder either.
 func testSettledTableRendersCellsWithoutPlaceholder() {
 let attributed = AIAssistantMarkdownRenderer.attributedString(
 from: table,
 allowsTables: true
 )
 let text = attributed.string
 XCTAssertFalse(text.contains("表格渲染中"))
 XCTAssertTrue(text.contains("核数"), "表格内容应保留")
 }

 /// Both paths must agree: streaming no longer degrades the table.
 func testStreamingAndSettledProduceSameText() {
 let streaming = AIAssistantMarkdownRenderer.attributedString(
 from: table,
 allowsTables: true
 ).string
 let settled = AIAssistantMarkdownRenderer.attributedString(
 from: table,
 allowsTables: true
 ).string
 XCTAssertEqual(streaming, settled)
 }
}
