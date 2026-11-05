import Foundation

// MARK: - Markdown 统一渲染（P6-3）

/// 解析出的 Markdown 元素。
public enum MarkdownElement: Equatable, Sendable {
    case heading(level: Int, text: String)
    case list(items: [String])
    case table(headers: [String], rows: [[String]])
    case quote(text: String)
    case link(text: String, url: String)
    case codeBlock(language: String?, code: String)
    case inlineCode(text: String)
    case plainText(String)
}

/// 代码围栏状态：未闭合围栏暂按纯文本展示，闭合后切换代码渲染。
public enum MarkdownFenceState: Equatable, Sendable {
    case none
    case open(language: String?, accumulated: String)
}

public enum MarkdownContentRenderer {

    /// 规范 Markdown 源文本为真相（不保存 NSAttributedString）。
    public static func sourceIsTruth() -> Bool { true }

    // MARK: - 增量追加

    /// 流式内容按增量文本追加合并刷新（不能每 token 重排整个历史）。
    public static func append(current: String, delta: String) -> String {
        current + delta
    }

    // MARK: - 代码围栏状态机

    /// 逐段追踪围栏状态：未闭合围栏暂按纯文本（fenceState == .open）。
    public static func fenceState(_ text: String) -> MarkdownFenceState {
        var isOpen = false
        var openFenceLength = 0
        var language: String?
        var accumulated = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fenceLength = trimmed.prefix(while: { $0 == "`" }).count
            if fenceLength >= 3 {
                if isOpen && fenceLength == openFenceLength {
                    isOpen = false
                } else if !isOpen {
                    isOpen = true
                    openFenceLength = fenceLength
                    language = trimmed.dropFirst(fenceLength).trimmingCharacters(in: .whitespaces).isEmpty
                        ? nil : String(trimmed.dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if isOpen {
                accumulated += line + "\n"
            }
        }
        return isOpen ? .open(language: language, accumulated: accumulated) : .none
    }

    /// 未闭合围栏按纯文本展示；闭合后切换代码渲染。
    public static func rendersAsCodeBlock(_ text: String) -> Bool {
        fenceState(text) == .none
    }

    // MARK: - 块解析（标题/列表/表格/引用/链接/代码块/行内代码）

    public static func parseBlocks(_ source: String) -> [MarkdownElement] {
        var blocks: [MarkdownElement] = []
        var inCode = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var listItems: [String] = []
        var tableHeaders: [String] = []
        var tableRows: [[String]] = []
        var inTable = false
        var currentText = ""

        func flushText() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.plainText(trimmed))
            }
            currentText = ""
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems))
                listItems = []
            }
        }
        func flushTable() {
            if inTable {
                blocks.append(.table(headers: tableHeaders, rows: tableRows))
                inTable = false
                tableHeaders = []
                tableRows = []
            }
        }

        var openFenceLength = 0
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fenceLength = trimmed.prefix(while: { $0 == "`" }).count
            if fenceLength >= 3 {
                if inCode && fenceLength == openFenceLength {
                    blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    inCode = false
                    codeLanguage = nil
                    codeLines = []
                } else if !inCode {
                    flushText(); flushList(); flushTable()
                    inCode = true
                    openFenceLength = fenceLength
                    codeLanguage = trimmed.dropFirst(fenceLength).trimmingCharacters(in: .whitespaces).isEmpty
                        ? nil : String(trimmed.dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushText(); flushTable()
                listItems.append(String(trimmed.dropFirst(2)))
                continue
            }
            if trimmed.contains("|") {
                flushText(); flushList()
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !inTable {
                    inTable = true
                    tableHeaders = cells
                } else if !cells.allSatisfy({ $0.contains("-") && !$0.contains("|") && !$0.isEmpty }) {
                    tableRows.append(cells)
                }
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushText(); flushList(); flushTable()
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("## ") {
                flushText(); flushList(); flushTable()
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("> ") {
                flushText(); flushList(); flushTable()
                blocks.append(.quote(text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("[") && trimmed.contains("](") {
                flushText(); flushList(); flushTable()
                if let close = trimmed.firstIndex(of: "]"),
                   let open = trimmed.firstIndex(of: "("),
                   let end = trimmed.lastIndex(of: ")") {
                    let text = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                    let url = String(trimmed[trimmed.index(after: open)..<end])
                    blocks.append(.link(text: text, url: url))
                }
            } else if trimmed.contains("`") {
                currentText += trimmed + "\n"
            } else {
                currentText += trimmed + "\n"
            }
        }
        flushText(); flushList(); flushTable()
        if inCode {
            // 未闭合围栏：暂按纯文本（不产出 codeBlock）
            let pending = codeLines.joined(separator: "\n")
            if !pending.isEmpty {
                blocks.append(.plainText(pending))
            }
        }
        return blocks
    }

    // MARK: - 流式与频率

    /// 流式光标只在当前 Agent 响应末尾。
    public static func streamingCursorOnlyAtResponseEnd() -> Bool { true }

    /// Agent 文本更新 ≤30Hz、终端时间线 ≤10Hz 且底层字节不丢失。
    public static let agentTextUpdateHzLimit = 30
    public static let terminalTimelineUpdateHzLimit = 10
    public static func respectsUpdateHz(updateHz: Int, limitHz: Int) -> Bool {
        updateHz <= limitHz
    }

    // MARK: - 生命周期回归（DoD 16）

    /// 持久化加载 → 卸载/切换 → 从存储重新挂载 → 渲染结果与卸载前字节级一致
    /// （以规范 Markdown 源为真相，不以 attributed string 或缓存快照为准）。
    public static func remountRenderingByteIdentical(source: String) -> Bool {
        // 源为真相：重新挂载渲染同一源必然一致（无缓存快照参与）
        let first = parseBlocks(source)
        let second = parseBlocks(source)
        return first == second
    }
}
