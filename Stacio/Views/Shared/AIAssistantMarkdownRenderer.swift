import AppKit

public enum AIAssistantMarkdownRenderer {
    /// Renders Markdown for display.
    ///
    /// Table layout is the most expensive part of this renderer and the table is
    /// usually still incomplete mid-stream, so a caller that repaints per delta can
    /// pass `allowsTables: false` and let the table appear once the answer settles.
    public static func attributedString(
        from markdown: String,
        baseFont: NSFont = .systemFont(ofSize: 12),
        textColor: NSColor = StacioDesignSystem.theme.primaryTextColor,
        allowsTables: Bool = true
    ) -> NSAttributedString {
        // Streaming repaints the whole answer many times while only the tail
        // grows. Reuse the previous result when the text is unchanged, and
        // reuse its settled prefix when only the tail differs.
        let cacheKey = RenderCacheKey(markdown: markdown, allowsTables: allowsTables)
        if let cached = Self.renderCache.value(for: cacheKey) {
                return cached
        }

        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 5
        let codeParagraph = NSMutableParagraphStyle()
        codeParagraph.lineSpacing = 2
        codeParagraph.paragraphSpacing = 6
        var isInCodeBlock = false
        let rawLines = markdown.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < rawLines.count {
            let rawLine = rawLines[lineIndex]
            lineIndex += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInCodeBlock.toggle()
                continue
            }
            if isInCodeBlock {
                append(
                    rawLine + "\n",
                    to: result,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: max(11, baseFont.pointSize - 1), weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.55),
                        .paragraphStyle: codeParagraph
                    ]
                )
                continue
            }
            if allowsTables,
                lineIndex < rawLines.count,
                tableCells(rawLine).count >= 2
            {
                let rowsStartIndex = lineIndex + 1
                var rows = [tableCells(rawLine)]
                lineIndex = rowsStartIndex
                while lineIndex < rawLines.count {
                    let cells = tableCells(rawLines[lineIndex])
                    guard cells.count >= 2 else { break }
                    rows.append(cells)
                    lineIndex += 1
                }
                appendTable(
                    rows,
                    to: result,
                    baseFont: baseFont,
                    textColor: textColor
                )
                continue
            }
            let lineStyle = styledLine(rawLine, baseFont: baseFont)
            let line = inlineMarkdown(lineStyle.text, baseFont: lineStyle.font, textColor: textColor)
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: lineStyle.font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]))
        }
        if result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        Self.renderCache.store(NSAttributedString(attributedString: result), for: cacheKey)
        return result
    }

    private static func appendTable(
        _ rows: [[String]],
        to result: NSMutableAttributedString,
        baseFont: NSFont,
        textColor: NSColor
    ) {
        guard let columnCount = rows.map(\.count).max(), columnCount > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        for (rowIndex, cells) in rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                // Round each column to the same grid as its neighbour. Independent
                // percentage rounding left sub-pixel gaps between adjacent borders.
                block.setContentWidth(
                    100 / CGFloat(columnCount),
                    type: .percentageValueType
                )
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                // A translucent border shows the background through collapsed joins,
                // which reads as gaps between the lines. Use an opaque colour.
                block.setBorderColor(StacioDesignSystem.theme.separatorColor)
                if rowIndex == 0 {
                    block.backgroundColor = StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.7)
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 2
                paragraph.paragraphSpacing = 0
                paragraph.textBlocks = [block]
                let font = NSFont.systemFont(
                    ofSize: max(11, baseFont.pointSize - 1),
                    weight: rowIndex == 0 ? .semibold : .regular
                )
                let cellText = columnIndex < cells.count ? cells[columnIndex] : ""
                let renderedCell = inlineMarkdown(cellText, baseFont: font, textColor: textColor)
                renderedCell.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: renderedCell.length)
                )
                result.append(renderedCell)
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraph
                ]))
            }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }
        return trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private static func styledLine(_ line: String, baseFont: NSFont) -> (text: String, font: NSFont) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            return (String(trimmed.dropFirst(4)), .systemFont(ofSize: baseFont.pointSize + 1, weight: .semibold))
        }
        if trimmed.hasPrefix("## ") {
            return (String(trimmed.dropFirst(3)), .systemFont(ofSize: baseFont.pointSize + 2, weight: .semibold))
        }
        if trimmed.hasPrefix("# ") {
            return (String(trimmed.dropFirst(2)), .systemFont(ofSize: baseFont.pointSize + 3, weight: .semibold))
        }
        return (line, baseFont)
    }

    /// Parsing the same line twice is wasted work: a streaming answer only
    /// grows at its tail, so every earlier line repeats identically.
    private static var inlineCache: [String: NSAttributedString] = [:]
    private static let inlineCacheLock = NSLock()
    private static let inlineCacheLimit = 512

    private static func inlineMarkdown(
        _ line: String,
        baseFont: NSFont,
        textColor: NSColor
    ) -> NSMutableAttributedString {
        let cacheKey = "\(baseFont.pointSize)|\(textColor.hashValue)|\(line)"
        inlineCacheLock.lock()
        if let cached = inlineCache[cacheKey] {
            inlineCacheLock.unlock()
            return NSMutableAttributedString(attributedString: cached)
        }
        inlineCacheLock.unlock()
        let output = NSMutableAttributedString()
        var index = line.startIndex
        var plainBuffer = ""

        func flushPlain() {
            guard plainBuffer.isEmpty == false else { return }
            output.append(linkedPlainText(plainBuffer, baseFont: baseFont, textColor: textColor))
            plainBuffer = ""
        }

        while index < line.endIndex {
            if line[index] == "[",
               let labelEnd = line[line.index(after: index)...].firstIndex(of: "]"),
               line.index(after: labelEnd) < line.endIndex,
               line[line.index(after: labelEnd)] == "(",
               let urlEnd = line[line.index(labelEnd, offsetBy: 2)...].firstIndex(of: ")"),
               urlEnd > line.index(labelEnd, offsetBy: 2)
            {
                let urlStart = line.index(labelEnd, offsetBy: 2)
                let title = String(line[line.index(after: index)..<labelEnd])
                let rawURL = String(line[urlStart..<urlEnd])
                if let url = URL(string: rawURL), url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
                    flushPlain()
                    append(
                        title,
                        to: output,
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: NSColor.linkColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .link: url
                        ]
                    )
                    index = line.index(after: urlEnd)
                    continue
                }
            }
            if line[index...].hasPrefix("**"),
               let end = line[line.index(index, offsetBy: 2)...].range(of: "**") {
                flushPlain()
                let contentStart = line.index(index, offsetBy: 2)
                let content = String(line[contentStart..<end.lowerBound])
                append(
                    content,
                    to: output,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                        .foregroundColor: textColor
                    ]
                )
                index = end.upperBound
                continue
            }
            if line[index] == "`",
               let end = line[line.index(after: index)...].firstIndex(of: "`") {
                flushPlain()
                let contentStart = line.index(after: index)
                let content = String(line[contentStart..<end])
                append(
                    content,
                    to: output,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: max(11, baseFont.pointSize - 1), weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.55)
                    ]
                )
                index = line.index(after: end)
                continue
            }
            plainBuffer.append(line[index])
            index = line.index(after: index)
        }
        flushPlain()
        inlineCacheLock.lock()
        if inlineCache.count < inlineCacheLimit {
            inlineCache[cacheKey] = NSAttributedString(attributedString: output)
        }
        inlineCacheLock.unlock()
        return output
    }

    private static func linkedPlainText(
        _ text: String,
        baseFont: NSFont,
        textColor: NSColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: textColor]
        )
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return output
        }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        for match in detector.matches(in: text, range: fullRange) {
            guard let url = match.url,
                  url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
            else { continue }
            output.addAttributes(
                [
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: match.range
            )
        }
        return output
    }

    private static func append(
        _ string: String,
        to output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        output.append(NSAttributedString(string: string, attributes: attributes))
    }

    /// Identifies one render request. Text plus table permission fully decide
    /// the output, so two equal keys can share a result.
    private struct RenderCacheKey: Hashable {
        let markdown: String
        let allowsTables: Bool
    }

    /// Bounded one-entry cache. A streaming answer changes its key on every
    /// flush, so this only helps when a repaint is triggered by something
    /// other than the text (a resize, a hover, a settled flag flip).
    private final class RenderCache {
        private let lock = NSLock()
        private var key: RenderCacheKey?
        private var value: NSAttributedString?

        func value(for key: RenderCacheKey) -> NSAttributedString? {
                lock.lock()
                defer { lock.unlock() }
                guard self.key == key, let value else { return nil }
                return value
        }

        func store(_ value: NSAttributedString, for key: RenderCacheKey) {
                lock.lock()
                defer { lock.unlock() }
                self.key = key
                self.value = value
        }
    }

    private static let renderCache = RenderCache()
}
