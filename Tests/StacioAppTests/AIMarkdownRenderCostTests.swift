import XCTest
@testable import StacioApp

final class AIMarkdownRenderCostTests: XCTestCase {
    /// Measures the streaming pattern: the answer grows at its tail while
    /// every earlier line stays identical, so only the last line is new.
    func testGrowingAnswerStaysWithinBudget() {
        let lines = (0..<60).map { index in
            "###小节" + String(index) + "\n\n普通段落，包含**加粗**与。"
        }
        var body = ""
        let started = CFAbsoluteTimeGetCurrent()
        for line in lines {
            body += line + "\n"
            _ = AIAssistantMarkdownRenderer.attributedString(from: body)
        }
        let perRender = (CFAbsoluteTimeGetCurrent() - started) / Double(lines.count)
        XCTAssertLessThan(perRender, 0.05, "增长场景单次渲染应低于50ms")
    }
}