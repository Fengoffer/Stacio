import XCTest
@testable import StacioApp

/// Streaming appends to the tail on every frame, so the cache rarely sees a
/// repeated key. What matters is how one render scales with answer length: if
/// the cost grows faster than the text, later frames visibly stutter.
final class AIStreamingRenderCostTests: XCTestCase {
 func testRenderCostDoesNotExplodeWithLength() {
 let short = (0..<10).map { "第\($0)段：一段正文。\n" }.joined()
 let long = (0..<120).map { "第\($0)段：一段正文。\n" }.joined()

 let shortCost = timeIt { _ = AIAssistantMarkdownRenderer.attributedString(from: short) }
 let longCost = timeIt { _ = AIAssistantMarkdownRenderer.attributedString(from: long) }
 let ratio = longCost / max(shortCost, 0.000_001)
 print("SHORT_MS=", shortCost * 1_000, "LONG_MS=", longCost * 1_000, "RATIO=", ratio)

 // Twelve times the content must not cost dramatically more than
 // twelve times the work; worse means something is quadratic.
 XCTAssertLessThan(ratio,40, "渲染成本不应随长度超线性增长")
 }

 private func timeIt(_ body: () -> Void) -> TimeInterval {
 body()
 let started = CFAbsoluteTimeGetCurrent()
 for _ in 0..<10 {
 body()
 }
 return (CFAbsoluteTimeGetCurrent() - started) / 10
 }
}
