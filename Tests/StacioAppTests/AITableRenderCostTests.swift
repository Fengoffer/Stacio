import XCTest
@testable import StacioApp

/// Tables build one NSTextTableBlock per cell, which is far more expensive
/// than inline text. Keep a ceiling so a long table cannot freeze the stream.
final class AITableRenderCostTests: XCTestCase {
 private func table(rows: Int) -> String {
 var lines = ["|指标 |当前值 |状态 |", "| --- | --- | --- |"]
 for index in 0..<rows {
 lines.append("|指标\(index) |12.1 GiB |已验证 |")
 }
 return lines.joined(separator: "\n")
 }

 func testLongTableRendersWithinBudget() {
 let body = table(rows:16)
 let started = CFAbsoluteTimeGetCurrent()
 for _ in 0..<10 {
 _ = AIAssistantMarkdownRenderer.attributedString(from: body)
 }
 let perRender = (CFAbsoluteTimeGetCurrent() - started) / 10
 print("TABLE_MS=", perRender * 1000)
 XCTAssertLessThan(perRender, 0.05, "16行表格单次渲染应低于50ms")
 }
}
