import AppKit
import CoreText
import XCTest
@testable import StacioApp
@testable import SwiftTerm

@MainActor
final class TerminalFontGridRegressionTests: XCTestCase {
    func testAATLigaturesKeepCPUAndMetalCellsAlignedWithColorsAndFallback() throws {
        for family in ["Ayuthaya", "Krungthep", "Bangla MN"] {
            let (window, terminal) = makeTerminal(font: family)
            defer { window.close() }
            for style in ["0", "1", "3", "1;3"] {
                let sample = "office offline flint fi ffi 中文XYZ"
                terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[\(style);31;44;4m" + sample)
                let line = try XCTUnwrap(terminal.terminal.getLine(row: 0))
                let segments = terminal.buildAttributedString(row: 0, line: line, cols: sample.count + 2).segments
                var renderedCharacters = 0
                for segment in segments {
                    let runs = TerminalTextLayout.glyphRuns(for: segment.attributedString)
                    XCTAssertEqual(runs.reduce(0) { $0 + CTRunGetGlyphCount($1) }, segment.attributedString.string.count, "\(family), SGR \(style)")
                    renderedCharacters += runs.reduce(0) { $0 + CTRunGetGlyphCount($1) }
                    let expected = segment.attributedString.attributes(at: 0, effectiveRange: nil)
                    for run in runs {
                        let actual = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                        XCTAssertEqual(actual[.foregroundColor] as? NSColor, expected[.foregroundColor] as? NSColor)
                        XCTAssertEqual(actual[.backgroundColor] as? NSColor, expected[.backgroundColor] as? NSColor)
                        XCTAssertEqual(actual[.underlineStyle] as? Int, expected[.underlineStyle] as? Int)
                    }
                }
                XCTAssertEqual(renderedCharacters, sample.count)
                let cell = try XCTUnwrap(terminal.terminal.getCharData(col: 0, row: 0))
                let attributes = try XCTUnwrap(terminal.getAttributes(cell.attribute, withUrl: false))
                let font = try XCTUnwrap(attributes[.font] as? NSFont)
                // This is the same entry point used on a Metal shaper-cache miss.
                let metalText = NSAttributedString(string: sample, attributes: TerminalTextLayout.fontAttributes(font))
                XCTAssertEqual(TerminalTextLayout.glyphRuns(for: metalText).reduce(0) { $0 + CTRunGetGlyphCount($1) }, sample.count)
            }
            terminal.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[HofficeXYZ\r\n123456XYZ\r\nfile list")
            XCTAssertEqual(terminal.terminal.getCharacter(col: 6, row: 0), "X")
            try save(terminal, name: "regression-aat-\(family.replacingOccurrences(of: " ", with: "-"))")
        }
    }

    func testEveryInstalledFamilyKeepsASCIICellCount() throws {
        let sample = "office offline flint fi ffi XYZ"
        let families = TerminalFontCatalog.installedFamilyNames()
        var checked = 0
        for family in families {
            let font = try XCTUnwrap(TerminalFontCatalog.font(named: family, size: 20), family)
            for face in [font, NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)] {
                let text = NSAttributedString(string: sample, attributes: TerminalTextLayout.fontAttributes(face))
                let runs = TerminalTextLayout.glyphRuns(for: text)
                XCTAssertEqual(runs.reduce(0) { $0 + CTRunGetGlyphCount($1) }, sample.count, face.fontName)
                checked += 1
            }
        }
        print("TERMINAL_ASCII_FONT_MATRIX families=\(families.count) faces=\(checked)")
    }

    func testLigatureFallbackPreservesNonASCIIShapingAndAttributeBoundaries() throws {
        let font = try XCTUnwrap(NSFont(name: "Bangla MN", size: 20))
        for sample in ["e\u{301}", "x\u{301}", "ক্ষ", "👩‍💻", "中文"] {
            let text = NSAttributedString(string: sample, attributes: TerminalTextLayout.fontAttributes(font))
            let original = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun]
            let actual = TerminalTextLayout.glyphRuns(for: text)
            XCTAssertEqual(glyphSignature(actual), glyphSignature(original), sample)
        }
        let text = NSMutableAttributedString(string: "officeXYZ", attributes: TerminalTextLayout.fontAttributes(font))
        text.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 6))
        text.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 6, length: 3))
        var colors: [NSColor] = []
        for run in TerminalTextLayout.glyphRuns(for: text) {
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            colors += Array(repeating: try XCTUnwrap(attributes[.foregroundColor] as? NSColor), count: CTRunGetGlyphCount(run))
        }
        XCTAssertEqual(colors, Array(repeating: .red, count: 6) + Array(repeating: .blue, count: 3))
    }

    private func glyphSignature(_ runs: [CTRun]) -> [String] {
        runs.flatMap { run -> [String] in
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            let font = attributes[.font] as! NSFont
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            var positions = [CGPoint](repeating: .zero, count: glyphs.count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            return zip(glyphs, positions).map { "\(font.fontName):\($0):\($1.x):\($1.y)" }
        }
    }

    func testCPUTextAndCaretKeepLigatureCharactersInSeparateColumns() throws {
        for family in ["Helvetica", "Times", "PingFang SC"] {
            let (window, terminal) = makeTerminal(font: family)
            defer { window.close() }
            let sample = "office offline flint fi ffi XYZ"
            for style in ["0", "1", "3", "1;3"] {
                terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[\(style)m" + sample)
                let line = try XCTUnwrap(terminal.terminal.getLine(row: 0))
                let segment = try XCTUnwrap(terminal.buildAttributedString(row: 0, line: line, cols: sample.count).segments.first)
                XCTAssertEqual(glyphStringIndices(in: segment.attributedString), Array(0..<sample.count), "\(family), SGR \(style)")
                let cell = try XCTUnwrap(terminal.terminal.getCharData(col: 0, row: 0))
                let caretAttributes = try XCTUnwrap(terminal.getAttributedValue(cell.attribute, usingFg: .white, andBg: .black))
                XCTAssertEqual(glyphStringIndices(in: NSAttributedString(string: "fi", attributes: caretAttributes)), [0, 1])
            }
            terminal.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[HofficeXYZ\r\n123456XYZ\r\nfile list")
            XCTAssertEqual(terminal.terminal.getCharacter(col: 6, row: 0), "X")
            try save(terminal, name: "regression-ligatures-\(family.replacingOccurrences(of: " ", with: "-"))")
        }
    }

    func testMetalTextShapingKeepsLigatureCharactersInSeparateColumns() throws {
        // Metal's shaper cache builds runs from these shared font attributes.
        for family in ["Helvetica", "Times", "PingFang SC"] {
            let regular = try XCTUnwrap(TerminalFontCatalog.font(named: family, size: 20))
            for font in [regular, NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)] {
                let sample = "office offline flint fi ffi XYZ"
                let attributed = NSAttributedString(string: sample, attributes: TerminalTextLayout.fontAttributes(font))
                XCTAssertEqual(glyphStringIndices(in: attributed), Array(0..<sample.count), font.fontName)
            }
        }
    }

    func testCJKFontWithoutGlyphNamesUsesUnicodeWForCellWidth() throws {
        guard NSFont(name: "YuppySC-Regular", size: 20) != nil else {
            throw XCTSkip("Yuppy SC is not installed on this host")
        }
        let (window, terminal) = makeTerminal(font: "Yuppy SC")
        defer { window.close() }
        XCTAssertEqual(terminal.font.glyph(withName: "W"), 0)
        var w: UniChar = 0x57, glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(terminal.font, &w, &glyph, 1))
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(terminal.font, .horizontal, &glyph, &advance, 1)
        XCTAssertEqual(terminal.caretFrame.width, advance.width, accuracy: 0.51)
        XCTAssertGreaterThan(terminal.caretFrame.width, 15)
        terminal.feed(text: "WWMMWW 中文字体\r\n1234567890")
        try save(terminal, name: "regression-cjk-cell-width")
    }

    func testFontMissingLatinWUsesFallbackAdvance() throws {
        for family in ["Apple Braille", "Apple Color Emoji"] {
            let (window, terminal) = makeTerminal(font: family)
            defer { window.close() }
            var w: UniChar = 0x57, glyph: CGGlyph = 0
            XCTAssertFalse(CTFontGetGlyphsForCharacters(terminal.font, &w, &glyph, 1), family)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "W", attributes: [.font: terminal.font]))
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            XCTAssertGreaterThan(advance, 0)
            XCTAssertEqual(terminal.caretFrame.width, advance, accuracy: 0.51, family)
            XCTAssertTrue(terminal.caretFrame.width.isFinite)
        }
    }

    func testSystemBrightWhiteRemainsReadableAcrossAppearances() throws {
        let (window, terminal) = makeTerminal(font: "Menlo")
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            var settings = AppSettings()
            settings.terminalHardwareAccelerationEnabled = false
            TerminalAppearanceApplier.apply(settings: settings, to: terminal)
            terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[97mW\u{1b}[0;38;5;15mI\u{1b}[0;38;5;231mX\u{1b}[0;38;2;255;255;255mT")
            var colors: [NSColor] = []
            for column in 0..<4 {
                let cell = try XCTUnwrap(terminal.terminal.getCharData(col: column, row: 0))
                let attributes = try XCTUnwrap(terminal.getAttributes(cell.attribute, withUrl: false))
                colors.append(try XCTUnwrap(attributes[.foregroundColor] as? NSColor))
            }
            XCTAssertEqual(colors[0], colors[1])
            XCTAssertGreaterThanOrEqual(contrast(colors[0], terminal.nativeBackgroundColor), 4.5)
            XCTAssertEqual(colors[2].portDeskHexString, "#FFFFFF", "Extended xterm colors must keep their values")
            XCTAssertEqual(colors[3].portDeskHexString, "#FFFFFF", "Explicit true color must keep its value")
            if appearance == .darkAqua {
                XCTAssertEqual(colors[0].portDeskHexString, TerminalColorTheme.oneHalfDark.ansiColorHexes[15])
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        var settings = AppSettings()
        settings.terminalFontFamily = .menlo
        settings.terminalFontSize = 20
        settings.terminalHardwareAccelerationEnabled = false
        TerminalAppearanceApplier.apply(settings: settings, to: terminal)
        terminal.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[Hbefore [\u{1b}[97mVISIBLE\u{1b}[0m] after\r\nnormal [VISIBLE] after")
        try save(terminal, name: "regression-bright-white")
    }

    private func glyphStringIndices(in attributed: NSAttributedString) -> [Int] {
        let line = CTLineCreateWithAttributedString(attributed)
        var result: [Int] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            var indices = [CFIndex](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetStringIndices(run, CFRange(), &indices)
            result.append(contentsOf: indices)
        }
        return result
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let firstValue = luminance(first), secondValue = luminance(second)
        return (max(firstValue, secondValue) + 0.05) / (min(firstValue, secondValue) + 0.05)
    }

    private func makeTerminal(font: String) -> (NSWindow, TerminalView) {
        let frame = NSRect(x: 0, y: 0, width: 780, height: 150)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let terminal = TerminalView(frame: frame)
        window.contentView = terminal
        window.orderFront(nil)
        var settings = AppSettings()
        settings.terminalFontSize = 20
        settings.terminalHardwareAccelerationEnabled = false
        settings.terminalFontFamily = .system
        settings.terminalCustomFontName = font
        TerminalAppearanceApplier.apply(settings: settings, to: terminal)
        return (window, terminal)
    }

    private func save(_ terminal: TerminalView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["STACIO_TERMINAL_RENDER_DIR"] else { return }
        terminal.layoutSubtreeIfNeeded()
        terminal.displayIfNeeded()
        let rep = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
        terminal.cacheDisplay(in: terminal.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
