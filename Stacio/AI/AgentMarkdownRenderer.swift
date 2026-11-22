import AppKit

/// Renders assistant markdown into an attributed string.
enum AgentMarkdownRenderer {
 struct Style {
 var bodyFont: NSFont = AgentTheme.Font.body
 var bodyColor: NSColor = AgentTheme.Color.text
 var codeFont: NSFont = AgentTheme.Font.mono
 var codeColor: NSColor = AgentTheme.Color.text
 var codeBackground: NSColor = AgentTheme.Color.cardInset
 var headingColor: NSColor = AgentTheme.Color.text
 var linkColor: NSColor = AgentTheme.Color.brandSolid
 var lineHeight: CGFloat=20
 var headingLineHeight: CGFloat=24
 }

 static func render(_ markdown: String, style: Style = Style(), width: CGFloat) -> NSAttributedString {
 let result = NSMutableAttributedString()
 let lines = markdown.components(separatedBy: "\n")
 var index=0
 var isFirstBlock = true

 while index < lines.count {
 let line = lines[index]

 if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
 var codeLines: [String] = []
 index += 1
 while index < lines.count {
 if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
 codeLines.append(lines[index])
 index += 1
 }
 if index < lines.count { index += 1 }
 if isFirstBlock == false { result.append(NSAttributedString(string: "\n")) }
 result.append(codeBlock(codeLines.joined(separator: "\n"), style: style))
 isFirstBlock = false
 continue
 }

 if line.trimmingCharacters(in: .whitespaces).isEmpty {
 index += 1
 continue
 }

 if let columns = tableColumns(at: index, in: lines) {
 let table = NSTextTable()
 table.numberOfColumns = columns
 table.collapsesBorders = true
 table.layoutAlgorithm = .fixedLayoutAlgorithm
 if !isFirstBlock { result.append(NSAttributedString(string: "\n")) }
 var row = 0
 repeat {
 let cells = tableCells(lines[index])
 for column in 0..<columns {
 let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
 block.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
 block.setWidth(4, type: .absoluteValueType, for: .padding)
 block.setWidth(0.5, type: .absoluteValueType, for: .border)
 block.setBorderColor(AgentTheme.Color.borderCard)
 let paragraph = NSMutableParagraphStyle()
 paragraph.textBlocks = [block]
 result.append(inline(cells[column], style: style, paragraph: paragraph))
 result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
 }
 index += row == 0 ? 2 : 1
 row += 1
 } while index < lines.count && tableCells(lines[index]).count == columns
 isFirstBlock = false
 continue
 }

 if let heading = headingLevel(of: line) {
 let text = String(line.dropFirst(heading + 1))
 var font = AgentTheme.Font.heading
 if heading == 1 { font = NSFont.systemFont(ofSize:17, weight: .semibold) }
 if heading == 2 { font = NSFont.systemFont(ofSize:15, weight: .semibold) }
 if isFirstBlock == false { result.append(NSAttributedString(string: "\n")) }
 result.append(NSAttributedString(string: text + "\n", attributes: [
 .font: font,
 .foregroundColor: style.headingColor,
 .paragraphStyle: AgentTheme.Font.paragraphStyle(lineHeight: style.headingLineHeight)
 ]))
 isFirstBlock = false
 index += 1
 continue
 }

 if let bullet = bulletContent(of: line) {
 if isFirstBlock == false { result.append(NSAttributedString(string: "\n")) }
 let indent = CGFloat(bullet.level)*14
 let paragraph = NSMutableParagraphStyle()
 paragraph.minimumLineHeight = style.lineHeight
 paragraph.maximumLineHeight = style.lineHeight
 paragraph.headIndent=12 + indent
 paragraph.firstLineHeadIndent = indent
 paragraph.lineBreakMode = .byCharWrapping
 var marker = "\u{00B7} "
 if bullet.ordered {
 let ordinal = bullet.ordinal ?? 1
 marker = String(ordinal) + ". "
 } else if bullet.level == 0 {
 marker = "\u{2022} "
 }
 result.append(NSAttributedString(string: marker, attributes: [
 .font: style.bodyFont,
 .foregroundColor: AgentTheme.Color.textMuted,
 .paragraphStyle: paragraph
 ]))
 result.append(inline(bullet.text, style: style, paragraph: paragraph))
 result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
 isFirstBlock = false
 index += 1
 continue
 }

 var paragraphLines: [String] = [line]
 index += 1
 while index < lines.count {
 let next = lines[index]
 if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
 if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
 if tableColumns(at: index, in: lines) != nil || headingLevel(of: next) != nil { break }
 if bulletContent(of: next) != nil { break }
 paragraphLines.append(next)
 index += 1
 }
 if isFirstBlock == false { result.append(NSAttributedString(string: "\n")) }
 let paragraph = AgentTheme.Font.paragraphStyle(lineHeight: style.lineHeight)
 result.append(inline(paragraphLines.joined(separator: "\n"), style: style, paragraph: paragraph))
 isFirstBlock = false
 }

 return result
 }

 private static func tableCells(_ line: String) -> [String] {
 guard line.contains("|") else { return [] }
 let content = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
 return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
 }

 private static func tableColumns(at index: Int, in lines: [String]) -> Int? {
 guard index + 1 < lines.count else { return nil }
 let columns = tableCells(lines[index]).count
 let separators = tableCells(lines[index + 1])
 guard columns >= 2, separators.count == columns, separators.allSatisfy({
 $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
 }) else { return nil }
 return columns
 }

 private static func headingLevel(of line: String) -> Int? {
 if line.hasPrefix("### ") { return 3 }
 if line.hasPrefix("## ") { return 2 }
 if line.hasPrefix("# ") { return 1 }
 return nil
 }

 private struct Bullet {
 var level: Int
 var ordered: Bool
 var ordinal: Int?
 var text: String
 }

 private static func bulletContent(of line: String) -> Bullet? {
 var spaces = 0
 var working = line
 while working.hasPrefix(" ") {
 spaces += 1
 working = String(working.dropFirst())
 }
 let level = spaces / 2
 let trimmed = working.trimmingCharacters(in: .whitespaces)
 if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
 return Bullet(level: level, ordered: false, ordinal: nil, text: String(trimmed.dropFirst(2)))
 }
 let parts = trimmed.split(separator: " ", maxSplits:1)
 if parts.count == 2 {
 let head = String(parts[0])
 if head.hasSuffix(".") {
 let digits = head.dropLast()
 if digits.isEmpty == false, digits.allSatisfy({ $0.isNumber }) {
 return Bullet(level: level, ordered: true, ordinal: Int(digits), text: String(parts[1]))
 }
 }
 }
 return nil
 }

 private static func codeBlock(_ code: String, style: Style) -> NSAttributedString {
 let paragraph = NSMutableParagraphStyle()
 paragraph.minimumLineHeight=18
 paragraph.maximumLineHeight=18
 paragraph.lineBreakMode = .byCharWrapping
 paragraph.headIndent=10
 paragraph.firstLineHeadIndent=10
 let body = code.isEmpty ? " " : code
 let block = NSMutableAttributedString(string: body, attributes: [
 .font: style.codeFont,
 .foregroundColor: style.codeColor,
 .backgroundColor: style.codeBackground,
 .paragraphStyle: paragraph
 ])
 block.append(NSAttributedString(string: "\n\n"))
 return block
 }

 private static func inline(_ text: String, style: Style, paragraph: NSParagraphStyle) -> NSAttributedString {
 let output = NSMutableAttributedString()
 let scalars = Array(text)
 var index=0
 var plain = ""
 while index < scalars.count {
 let character = scalars[index]
 if character == "*", index + 1 < scalars.count, scalars[index + 1] == "*" {
 var cursor = index + 2
 var content = ""
 var closed = false
 while cursor + 1 < scalars.count {
 if scalars[cursor] == "*", scalars[cursor + 1] == "*" { closed = true; break }
 content.append(scalars[cursor])
 cursor += 1
 }
 if closed, content.isEmpty == false {
 if plain.isEmpty == false {
 output.append(NSAttributedString(string: plain, attributes: [
 .font: style.bodyFont,
 .foregroundColor: style.bodyColor,
 .paragraphStyle: paragraph
 ]))
 plain = ""
 }
 output.append(NSAttributedString(string: content, attributes: [
 .font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
 .foregroundColor: style.bodyColor,
 .paragraphStyle: paragraph
 ]))
 index = cursor + 2
 continue
 }
 }
 if character == "`" {
 var cursor = index + 1
 var content = ""
 var closed = false
 while cursor < scalars.count {
 if scalars[cursor] == "`" { closed = true; break }
 content.append(scalars[cursor])
 cursor += 1
 }
 if closed {
 if plain.isEmpty == false {
 output.append(NSAttributedString(string: plain, attributes: [
 .font: style.bodyFont,
 .foregroundColor: style.bodyColor,
 .paragraphStyle: paragraph
 ]))
 plain = ""
 }
 output.append(NSAttributedString(string: content, attributes: [
 .font: style.codeFont,
 .foregroundColor: style.codeColor,
 .backgroundColor: style.codeBackground,
 .paragraphStyle: paragraph
 ]))
 index = cursor + 1
 continue
 }
 plain.append(character)
 index += 1
 continue
 }
 plain.append(character)
 index += 1
 }
 if plain.isEmpty == false {
 output.append(NSAttributedString(string: plain, attributes: [
 .font: style.bodyFont,
 .foregroundColor: style.bodyColor,
 .paragraphStyle: paragraph
 ]))
 }
 return output
 }
}
