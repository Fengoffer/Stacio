import XCTest
@testable import StacioApp

/// A reply that grows must not get slower per frame. This walks the length up
/// in steps and reports the cost of the last step against the first, so a
/// quadratic path shows up as a rising cost instead of a flat one.
final class AIGrowthCurveTests: XCTestCase {
 func testRenderCostStaysFlatAsAnswerGrows() {
 var costs: [Double] = []
 for step in 1...6 {
 let body = (0..<(step * 20)).map { "第\($0)段：这是一段用于测量的正文内容。\n" }.joined()
 let started = CFAbsoluteTimeGetCurrent()
 for _ in 0..<5 {
 _ = AIAssistantMarkdownRenderer.attributedString(from: body)
 }
 costs.append((CFAbsoluteTimeGetCurrent() - started) / 5 * 1_000)
 }

 let first = costs.first ?? 0
 let last = costs.last ?? 0
 print("GROWTH_MS=", costs.map { String(format: "%.3f", $0) }.joined(separator: ","),
 " first=", first, " last=", last, " ratio=", last / max(first, 0.000_001))
 // Five-fold growth in length must not cost five-fold in time per render.
 XCTAssertLessThan(last, max(first * 3, 0.5), "渲染成本应基本恒定")
 }
}
