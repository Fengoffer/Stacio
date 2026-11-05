import AppKit
import CoreText
import XCTest
@testable import StacioApp
@testable import SwiftTerm

@MainActor
final class TerminalFontAppearanceTests: XCTestCase {
    func testCatalogIncludesProportionalAndBundledFamilies() throws {
        let families = TerminalFontCatalog.installedFamilyNames()
        XCTAssertTrue(families.contains("Helvetica"))
        XCTAssertTrue(families.contains("Menlo"))
        XCTAssertTrue(families.contains("Sarasa Term SC"))
        XCTAssertFalse(TerminalFontCatalog.isMonospacedFamily(named: "Helvetica"))
        XCTAssertTrue(TerminalFontCatalog.isMonospacedFamily(named: "Menlo"))
    }

    func testDefaultSFMonoIsSystemMonospacedFontAndHasRealBoldFace() {
        let settings = AppSettings()
        let font = TerminalAppearanceApplier.font(for: settings)
        XCTAssertEqual(font.fontName, NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminalFontSize), weight: .regular).fontName)
        XCTAssertNotEqual(font.fontName, "Sarasa-Term-SC-Regular")
        XCTAssertNotEqual(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask).fontName, font.fontName)
    }

    func testJetBrainsPresetDoesNotSubstituteNerdFamily() {
        var settings = AppSettings()
        settings.terminalFontFamily = .jetBrainsMono
        let expected = settings.terminalFontFamily.fontNames.lazy.compactMap {
            NSFont(name: $0, size: CGFloat(settings.terminalFontSize))
        }.first ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminalFontSize), weight: .regular)
        XCTAssertEqual(TerminalAppearanceApplier.font(for: settings).fontName, expected.fontName)
    }

    func testCustomProportionalFontAppliesToLocalRemoteAndAgentTerminals() throws {
        var settings = AppSettings()
        settings.terminalFontFamily = .system
        settings.terminalCustomFontName = "Helvetica"
        settings.terminalFontSize = 17
        let expected = try XCTUnwrap(TerminalFontCatalog.font(named: "Helvetica", size: 17))
        let terminals: [TerminalView] = [
            StacioLocalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400)),
            StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400)),
            TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        ]
        for terminal in terminals {
            TerminalAppearanceApplier.apply(settings: settings, to: terminal)
            XCTAssertEqual(terminal.font.fontName, expected.fontName)
            XCTAssertEqual(terminal.font.pointSize, 17)
            terminal.feed(text: "A中B")
            XCTAssertEqual(terminal.terminal.getCharacter(col: 0, row: 0), "A")
            XCTAssertEqual(terminal.terminal.getCharacter(col: 1, row: 0), "中")
            XCTAssertEqual(terminal.terminal.getCharacter(col: 3, row: 0), "B")
        }
        LocalAgentTerminalFont.apply(settings: settings, to: terminals[2])
        XCTAssertEqual(terminals[2].font.fontName, expected.fontName)
    }

    func testMissingCustomFontFallsBackWithoutDiscardingPreference() {
        var settings = AppSettings()
        settings.terminalFontFamily = .system
        settings.terminalCustomFontName = "Stacio-Missing-Font-123456789"
        XCTAssertEqual(TerminalAppearanceApplier.font(for: settings).fontName,
                       NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminalFontSize), weight: .regular).fontName)
        XCTAssertEqual(settings.terminalCustomFontName, "Stacio-Missing-Font-123456789")
    }

    func testSarasaRegularAndBoldHaveMatchingCellMetrics() throws {
        let normal = try XCTUnwrap(LocalAgentTerminalFont.font(size: 15))
        let bold = NSFontManager.shared.convert(normal, toHaveTrait: .boldFontMask)
        XCTAssertEqual(bold.fontName, "Sarasa-Term-SC-Bold")
        for text in ["W", "中", "─"] {
            let normalWidth = NSAttributedString(string: text, attributes: [.font: normal]).size().width
            let boldWidth = NSAttributedString(string: text, attributes: [.font: bold]).size().width
            XCTAssertEqual(normalWidth, boldWidth, accuracy: 0.001)
        }
    }

    func testSystemPaletteReplacesPreviousThemeAndFollowsAppearance() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.appearance = NSAppearance(named: .aqua)
        TerminalAppearanceApplier.apply(settings: AppSettings(terminalTheme: .dark, terminalBuiltInThemeID: "tokyo-night"), to: terminal)
        TerminalAppearanceApplier.apply(settings: AppSettings(), to: terminal)
        let lightRed = terminal.mapColor(color: .ansi256(code: 1), isFg: true, isBold: false)
        XCTAssertEqual(lightRed.portDeskHexString, "#C9352B")
        terminal.appearance = NSAppearance(named: .darkAqua)
        TerminalAppearanceApplier.apply(settings: AppSettings(), to: terminal)
        let darkRed = terminal.mapColor(color: .ansi256(code: 1), isFg: true, isBold: false)
        XCTAssertEqual(darkRed.portDeskHexString, TerminalColorTheme.oneHalfDark.ansiColorHexes[1])
        XCTAssertNotEqual(lightRed, darkRed)
    }

    func testSGRBoldKeepsBaseColorAndExplicitBrightExtendedTrueColorsSurvive() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        TerminalAppearanceApplier.apply(settings: AppSettings(terminalTheme: .dark), to: terminal)
        terminal.feed(text: "\u{1b}[31mR\u{1b}[1mB\u{1b}[0;91mH\u{1b}[0;38;5;196mX\u{1b}[0;38;2;17;34;51mT")
        var attributes: [[NSAttributedString.Key: Any]] = []
        for column in 0..<5 {
            let cell = try XCTUnwrap(terminal.terminal.getCharData(col: column, row: 0))
            attributes.append(try XCTUnwrap(terminal.getAttributes(cell.attribute, withUrl: false)))
        }
        let colors = attributes.map { ($0[.foregroundColor] as? NSColor)?.portDeskHexString }
        XCTAssertEqual(colors[0], "#C23621")
        XCTAssertEqual(colors[1], colors[0])
        XCTAssertEqual(colors[2], "#FC391F")
        XCTAssertEqual(colors[3], "#FF0000")
        XCTAssertEqual(colors[4], "#112233")
        let regular = try XCTUnwrap(attributes[0][.font] as? NSFont)
        let bold = try XCTUnwrap(attributes[1][.font] as? NSFont)
        XCTAssertNotEqual(regular.fontName, bold.fontName)
        // Toggling compatibility behavior invalidates already cached attributes.
        terminal.boldUsesBrightColors = true
        let boldCell = try XCTUnwrap(terminal.terminal.getCharData(col: 1, row: 0))
        let legacy = try XCTUnwrap(terminal.getAttributes(boldCell.attribute, withUrl: false))
        XCTAssertEqual((legacy[.foregroundColor] as? NSColor)?.portDeskHexString, "#FC391F")
    }

    func testFastfetchStyleOutputRendersWithSelectedFontAndPalette() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1050, height: 600))
        window.contentView = terminal
        window.orderFront(nil)
        defer { window.close() }
        var settings = AppSettings()
        settings.terminalFontSize = 15
        settings.terminalHardwareAccelerationEnabled = false
        let sample = [
            "root@user:~# fastfetch",
            "\u{1b}[1;31m          ....             root\u{1b}[0m@\u{1b}[1;31muser\u{1b}[0m",
            "\u{1b}[1;31m      .',:clooo: .:loooo:.   OS\u{1b}[0m: Ubuntu 25.10 x86_64",
            "\u{1b}[1;31m    .;looooooooc .ooooooo'   Host\u{1b}[0m: VMware Virtual Platform",
            "\u{1b}[1;31m  .;looooool:,' . :oooooc    Kernel\u{1b}[0m: Linux 6.17.0-41-generic",
            "\u{1b}[1;31m ;loooool;.       'oooooo,   Shell\u{1b}[0m: bash 5.2.37",
            "\u{1b}[1;31m ;clool'          .cooooc.   CPU\u{1b}[0m: Intel(R) Xeon(R) E5-2670 v3",
            "\u{1b}[1;31m   ...              ....    Memory\u{1b}[0m: 3.26 GiB / 15.12 GiB (\u{1b}[32m22%\u{1b}[0m)",
            "\u{1b}[1;31m .;clol;,.                  Locale\u{1b}[0m: en_US.UTF-8",
            "                           中文两格 / ASCII grid / ┌──────┐",
            "                           ┌──────┬──────┐",
            "                           │主机名│状态  │",
            "                           └──────┴──────┘",
            "                           " + (0..<8).map { "\u{1b}[\(40 + $0)m   " }.joined() + "\u{1b}[0m",
            "                           " + (0..<8).map { "\u{1b}[\(100 + $0)m   " }.joined() + "\u{1b}[0m",
            "root@user:~# "
        ].joined(separator: "\r\n")
        for (label, family, appearance) in [("sfmono-light", "", NSAppearance.Name.aqua), ("sarasa-light", "Sarasa Term SC", .aqua), ("helvetica-light", "Helvetica", .aqua), ("sfmono-dark", "", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            settings.terminalFontFamily = family.isEmpty ? .sfMono : .system
            settings.terminalCustomFontName = family.isEmpty ? nil : family
            TerminalAppearanceApplier.apply(settings: settings, to: terminal)
            terminal.feed(text: "\u{1b}[2J\u{1b}[H" + sample)
            terminal.layoutSubtreeIfNeeded()
            terminal.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(terminal.terminal.getCharData(col: 27, row: 2)?.attribute.style.contains(.bold), true)
            if let directory = ProcessInfo.processInfo.environment["STACIO_TERMINAL_RENDER_DIR"] {
                let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
                terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(label).png"))
            }
        }
    }

    func testMetalRendererAcceptsSelectedProportionalFont() throws {
        // The native XCTest host does not automatically embed dependency resources.
        guard Bundle(for: Self.self).url(forResource: "Shaders", withExtension: "metal") != nil else {
            throw XCTSkip("Embed SwiftTerm Shaders.metal in the test bundle to exercise Metal")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = terminal
        window.orderFront(nil)
        defer { window.close() }
        var settings = AppSettings()
        TerminalAppearanceApplier.apply(settings: settings, to: terminal)
        try terminal.setUseMetal(true)
        if terminal.isUsingMetalRenderer {
            settings.terminalFontFamily = .system
            settings.terminalCustomFontName = "Helvetica"
            settings.terminalHardwareAccelerationEnabled = true
            terminal.font = TerminalAppearanceApplier.font(for: settings)
            terminal.feed(text: "\r\n\u{1b}[1;31mMetal 粗体\u{1b}[0m")
            terminal.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(terminal.font.familyName, "Helvetica")
        } else {
            throw XCTSkip("Metal renderer is unavailable on this test host")
        }
    }

    func testProportionalGlyphIsCenteredAndWideGlyphIsNeverStretched() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.font = try XCTUnwrap(NSFont(name: "Helvetica", size: 17))
        var character: UniChar = 105 // i
        var glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(terminal.font, &character, &glyph, 1))
        let fit = terminal.glyphSlotFit(font: terminal.font, glyph: glyph, columnWidth: 1)
        XCTAssertGreaterThan(fit.dx, 0)
        XCTAssertEqual(fit.scale, 1)
        let cjkFont = try XCTUnwrap(LocalAgentTerminalFont.font(size: 17))
        character = 0x4e2d
        XCTAssertTrue(CTFontGetGlyphsForCharacters(cjkFont, &character, &glyph, 1))
        let wideFit = terminal.glyphSlotFit(font: cjkFont, glyph: glyph, columnWidth: 2)
        XCTAssertEqual(wideFit.scale, 1)
        XCTAssertGreaterThanOrEqual(wideFit.dx, 0)
    }
}
