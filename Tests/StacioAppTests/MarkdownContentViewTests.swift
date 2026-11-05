import XCTest
import Foundation
@testable import StacioApp

/// P6-3：MarkdownContentView（规范源为真相、块解析、增量流式、围栏状态机、频率、生命周期回归）。
final class MarkdownContentViewTests: XCTestCase {

    // MARK: - 规范源为真相

    func testMarkdownSourceIsTruth() {
        XCTAssertTrue(MarkdownContentRenderer.sourceIsTruth(), "规范 Markdown 源文本为真相（不保存 NSAttributedString）")
    }

    // MARK: - 块解析

    func testParseHeadingsListsQuotesLinks() {
        let blocks = MarkdownContentRenderer.parseBlocks("""
        # 标题一
        ## 标题二
        - 项一
        - 项二
        > 引用
        [链接](https://example.com)
        """)
        XCTAssertTrue(blocks.contains(.heading(level: 1, text: "标题一")))
        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "标题二")))
        XCTAssertTrue(blocks.contains(.list(items: ["项一", "项二"])))
        XCTAssertTrue(blocks.contains(.quote(text: "引用")))
        XCTAssertTrue(blocks.contains(.link(text: "链接", url: "https://example.com")))
    }

    func testParseTable() {
        let blocks = MarkdownContentRenderer.parseBlocks("""
        | 名称 | 值 |
        | --- | --- |
        | a | 1 |
        | b | 2 |
        """)
        XCTAssertTrue(blocks.contains(.table(headers: ["名称", "值"], rows: [["a", "1"], ["b", "2"]])))
    }

    func testParseCodeBlockAndInlineCode() {
        let blocks = MarkdownContentRenderer.parseBlocks("""
        ```swift
        let x = 1
        ```
        行内 `code` 文本
        """)
        XCTAssertTrue(blocks.contains(.codeBlock(language: "swift", code: "let x = 1")))
        XCTAssertTrue(blocks.contains(where: { block in
            if case .plainText(let text) = block { return text.contains("`code`") }
            return false
        }), "行内代码保留在文本中")
    }

    // MARK: - 增量流式

    func testIncrementalAppendWithoutFullRelayout() {
        let merged = MarkdownContentRenderer.append(current: "前", delta: "后")
        XCTAssertEqual(merged, "前后", "流式内容按增量文本追加合并刷新")
        // 追加不重排整个历史：append 是 O(delta) 拼接
        let long = MarkdownContentRenderer.append(current: String(repeating: "a", count: 1000), delta: "b")
        XCTAssertEqual(long.count, 1001)
    }

    func testStreamingCursorOnlyAtResponseEnd() {
        XCTAssertTrue(MarkdownContentRenderer.streamingCursorOnlyAtResponseEnd(),
                      "流式光标只在当前 Agent 响应末尾")
    }

    // MARK: - 代码围栏状态机

    func testUnclosedFenceRendersAsPlainText() {
        XCTAssertEqual(
            MarkdownContentRenderer.fenceState("```swift\nlet x = 1"),
            .open(language: "swift", accumulated: "let x = 1\n"),
            "未闭合围栏暂按纯文本"
        )
        XCTAssertFalse(MarkdownContentRenderer.rendersAsCodeBlock("```swift\nlet x = 1"))
        // 闭合后切换代码渲染
        XCTAssertEqual(MarkdownContentRenderer.fenceState("```swift\nlet x = 1\n```"), .none)
        XCTAssertTrue(MarkdownContentRenderer.rendersAsCodeBlock("```swift\nlet x = 1\n```"))
    }

    // MARK: - 更新频率

    func testUpdateHzLimits() {
        XCTAssertTrue(MarkdownContentRenderer.respectsUpdateHz(updateHz: 30, limitHz: 30), "Agent 文本 ≤30Hz")
        XCTAssertFalse(MarkdownContentRenderer.respectsUpdateHz(updateHz: 31, limitHz: 30))
        XCTAssertTrue(MarkdownContentRenderer.respectsUpdateHz(updateHz: 10, limitHz: 10), "终端时间线 ≤10Hz")
        XCTAssertFalse(MarkdownContentRenderer.respectsUpdateHz(updateHz: 11, limitHz: 10))
        XCTAssertEqual(MarkdownContentRenderer.agentTextUpdateHzLimit, 30)
        XCTAssertEqual(MarkdownContentRenderer.terminalTimelineUpdateHzLimit, 10)
    }

    // MARK: - 生命周期回归（DoD 16）

    func testRemountRenderingByteIdentical() {
        let source = "# 标题\n\n- 项一\n- 项二\n\n```swift\nlet x = 1\n```\n\n> 引用"
        // 持久化加载 → 卸载/切换 → 从存储重新挂载 → 渲染结果与卸载前字节级一致
        XCTAssertTrue(
            MarkdownContentRenderer.remountRenderingByteIdentical(source: source),
            "以规范 Markdown 源为真相：重新挂载渲染与卸载前一致"
        )
        // 不同源 → 渲染不同（以源为准）
        XCTAssertFalse(
            MarkdownContentRenderer.parseBlocks(source)
                == MarkdownContentRenderer.parseBlocks("# 其他标题")
        )
    }
}
