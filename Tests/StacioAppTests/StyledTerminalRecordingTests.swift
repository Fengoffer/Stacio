import AppKit
import CoreText
import StacioCoreBindings
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class StyledTerminalRecordingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StacioRTF-\(UUID().uuidString)")
    }

    override func tearDown() {
        StyledTerminalRecording.finishAllAndWait()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testInitialContentAndLaterOutputRetainUnicodeColorsAndSpacing() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        terminal.feed(text: "\u{1b}[1;38;2;17;34;51;48;2;68;85;102m中国 é😀\u{1b}[0m\r\n    | A | B |\r\n")
        let recording = try StyledTerminalRecording(view: view, title: "设备/一:端口", directory: directory)
        terminal.feed(text: "next\tcolumn\r\n")
        recording.finish()
        recording.waitUntilSaved()
        XCTAssertNil(recording.error)
        let output = try read(recording)
        XCTAssertTrue(output.string.contains("中国 é😀"))
        XCTAssertTrue(output.string.contains("    | A | B |"))
        XCTAssertTrue(output.string.contains("next    column"))
        XCTAssertFalse(output.string.contains("\u{1b}"))
        let index = (output.string as NSString).range(of: "中国").location
        let attributes = output.attributes(at: index, effectiveRange: nil)
        assertColor(attributes[.foregroundColor], red: 17, green: 34, blue: 51)
        assertColor(attributes[.backgroundColor], red: 68, green: 85, blue: 102)
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(recording.fileURL.lastPathComponent.hasSuffix("_设备_一_端口.rtf"))
        XCTAssertNotNil(recording.fileURL.lastPathComponent.range(of: #"^\d{8}_\d{6}_\d{3}_"#, options: .regularExpression))
    }

    func testCarriageReturnClearScreenAlternateScreenAndReset() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        terminal.feed(text: "before recording\r\n")
        let recording = try StyledTerminalRecording(view: view, title: "redraw", directory: directory)
        terminal.feed(text: "0%\r100%\u{1b}[K\r\n")
        terminal.feed(text: "\u{1b}[2J\u{1b}[Hafter clear\r\n")
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[Halternate screen\r\n\u{1b}[?1049l")
        terminal.resetToInitialState()
        terminal.feed(text: "after reset\r\n")
        recording.finish()
        recording.waitUntilSaved()
        let text = try read(recording).string
        for value in ["before recording", "100%", "after clear", "alternate screen", "after reset"] {
            XCTAssertTrue(text.contains(value), value)
        }
        XCTAssertFalse(text.contains("0%100%"))
        XCTAssertEqual(text.components(separatedBy: "before recording").count, 2)
    }

    func testScreenPresentAtStartSurvivesImmediateOverwriteWithoutDuplicatingAnExtendedPrompt() throws {
        let view = makeView()
        view.getTerminal().feed(text: "initial display")
        let recording = try StyledTerminalRecording(view: view, title: "initial", directory: directory)
        view.getTerminal().feed(text: "\rreplacement\u{1b}[K\r\n")
        recording.finish(); recording.waitUntilSaved()
        let text = try read(recording).string
        XCTAssertTrue(text.contains("initial display"))
        XCTAssertTrue(text.contains("replacement"))

        let prompt = makeView()
        prompt.getTerminal().feed(text: "$ ")
        let commands = try StyledTerminalRecording(view: prompt, title: "prompt", directory: directory)
        prompt.getTerminal().feed(text: "ls\r\nfile\r\n")
        commands.finish(); commands.waitUntilSaved()
        let transcript = try read(commands).string
        XCTAssertTrue(transcript.hasPrefix("$ ls"))
        XCTAssertEqual(transcript.components(separatedBy: "$ ").count, 2)
    }

    func testOneLargeFeedDoesNotLoseRowsWhenScrollbackRecycles() throws {
        let view = makeView(columns: 64, rows: 4)
        let terminal = view.getTerminal()
        terminal.changeScrollback(8)
        terminal.feed(text: "existing\r\n")
        let recording = try StyledTerminalRecording(view: view, title: "large", directory: directory)
        let count = 20_000
        terminal.feed(text: (0..<count).map { "row-\($0) " + String(repeating: "x", count: 40) + "\r\n" }.joined())
        recording.finish()
        recording.waitUntilSaved()
        XCTAssertNil(recording.error)
        let text = try read(recording).string
        let lines = text.components(separatedBy: .newlines).filter { $0.hasPrefix("row-") }
        XCTAssertEqual(lines.count, count)
        for (index, line) in lines.enumerated() { XCTAssertTrue(line.hasPrefix("row-\(index) "), "row \(index)") }
        XCTAssertTrue(text.hasPrefix("existing"))
    }

    func testExplicitScrollAndDeleteCommandsKeepDiscardedRows() throws {
        let view = makeView(columns: 30, rows: 4)
        let terminal = view.getTerminal()
        let recording = try StyledTerminalRecording(view: view, title: "scroll", directory: directory)
        terminal.feed(text: "top\r\nsecond\r\nthird\r\nbottom")
        terminal.feed(text: "\u{1b}[1S\u{1b}[H\u{1b}[1M")
        recording.finish(); recording.waitUntilSaved()
        let text = try read(recording).string
        for line in ["top", "second", "third", "bottom"] { XCTAssertTrue(text.contains(line)) }
    }

    func testVeryLongUnicodeTitleFitsFilesystemAndQuitWaitsForFinalSave() throws {
        let view = makeView()
        let recording = try StyledTerminalRecording(view: view, title: String(repeating: "🧑🏽‍💻设备", count: 100), directory: directory)
        view.getTerminal().feed(text: "saved on quit")
        StyledTerminalRecording.finishAllAndWait()
        XCTAssertFalse(recording.isRecording)
        XCTAssertNil(recording.error)
        XCTAssertTrue(try read(recording).string.contains("saved on quit"))
        XCTAssertLessThanOrEqual(recording.fileURL.lastPathComponent.utf8.count, 255)
    }

    func testAllRemoteProtocolsKeepRecordingAcrossDisconnectAndRuntimeReplacement() throws {
        var panes: [RemoteTerminalPaneViewController] = []
        let kinds: [RemoteTerminalConnectionKind] = [.ssh, .telnet, .serial, .console]
        for (index, kind) in kinds.enumerated() {
            let pane = RemoteTerminalPaneViewController(
                runtimeID: "old-\(index)", title: "device-\(index)", connectionKind: kind,
                eventSink: RecordingEventSink(), bridge: RecordingBridge(), startsPollingAutomatically: false
            )
            pane.loadView()
            pane.feedRemoteOutput(Array("before-\(index)\r\n".utf8), applySemanticHighlighting: false)
            pane.styledRecording = try StyledTerminalRecording(view: pane.terminalView, title: pane.terminalTitle, directory: directory)
            panes.append(pane)
            let original = try XCTUnwrap(pane.styledRecording)
            pane.displayConnectionFailure("test disconnect")
            XCTAssertTrue(original.isRecording)
            pane.attachConnectedRuntime(status: LiveShellStatus(runtimeId: "new-\(index)", status: "running", diagnostic: "running"))
            XCTAssertEqual(pane.runtimeID, "new-\(index)")
            XCTAssertTrue(pane.styledRecording === original)
            pane.feedRemoteOutput(Array("after-\(index)\r\n".utf8), applySemanticHighlighting: false)
        }
        panes[0].closeTerminal()
        XCTAssertFalse(try XCTUnwrap(panes[0].styledRecording).isRecording)
        for (index, pane) in panes.enumerated().dropFirst() {
            XCTAssertTrue(try XCTUnwrap(pane.styledRecording).isRecording)
            pane.feedRemoteOutput(Array("peer-alive-\(index)\r\n".utf8), applySemanticHighlighting: false)
            pane.closeTerminal()
        }
        for (index, pane) in panes.enumerated() {
            let session = try XCTUnwrap(pane.styledRecording)
            session.waitUntilSaved()
            XCTAssertNil(session.error)
            let text = try read(session).string
            XCTAssertTrue(text.contains("before-\(index)"), String(describing: kinds[index]))
            XCTAssertTrue(text.contains("after-\(index)"), String(describing: kinds[index]))
            if index > 0 { XCTAssertTrue(text.contains("peer-alive-\(index)")) }
            for other in 0..<4 where other != index { XCTAssertFalse(text.contains("after-\(other)")) }
        }
    }

    func testSplitUTF8AndWideCharactersDoNotGainExtraSpaces() throws {
        let view = makeView()
        let recording = try StyledTerminalRecording(view: view, title: "unicode", directory: directory)
        for byte in "中😀é文\r\n".utf8 { view.getTerminal().feed(byteArray: [byte]) }
        recording.finish()
        recording.waitUntilSaved()
        XCTAssertTrue(try read(recording).string.hasPrefix("中😀é文"))
    }

    func testSameTimestampAndNameNeverOverwriteAndCloseIsIdempotent() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeView(), second = makeView()
        let a = try StyledTerminalRecording(view: first, title: "same", directory: directory, date: date)
        let b = try StyledTerminalRecording(view: second, title: "same", directory: directory, date: date)
        first.getTerminal().feed(text: "first")
        second.getTerminal().feed(text: "second")
        a.finish(); a.finish(); b.finish()
        a.waitUntilSaved(); b.waitUntilSaved()
        XCTAssertNotEqual(a.fileURL, b.fileURL)
        XCTAssertTrue(try read(a).string.hasPrefix("first"))
        XCTAssertTrue(try read(b).string.hasPrefix("second"))
    }

    func testResizeAndOwnerReleasePreserveContent() throws {
        let view = makeView(columns: 40, rows: 6)
        var recording: StyledTerminalRecording? = try StyledTerminalRecording(view: view, title: "resize", directory: directory)
        let url = try XCTUnwrap(recording).fileURL
        view.getTerminal().feed(text: "before resize\r\n")
        view.getTerminal().resize(cols: 20, rows: 3)
        view.getTerminal().feed(text: "after resize\r\n")
        recording = nil
        StyledTerminalRecording.finishAllAndWait()
        let text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        XCTAssertTrue(text.contains("before resize"))
        XCTAssertTrue(text.contains("after resize"))
        XCTAssertEqual(text.components(separatedBy: "before resize").count, 2)
    }

    func testCannotStartInAnUnwritableLocation() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("file")
        try Data("existing".utf8).write(to: file)
        XCTAssertThrowsError(try StyledTerminalRecording(view: makeView(), title: "invalid", directory: file))
        XCTAssertEqual(try String(contentsOf: file), "existing")
    }

    func testWiderTerminalExpandsDocumentInsteadOfWrappingItsTable() throws {
        let view = makeView(columns: 40, rows: 6)
        let recording = try StyledTerminalRecording(view: view, title: "wide", directory: directory)
        view.getTerminal().resize(cols: 160, rows: 6)
        view.getTerminal().feed(text: String(repeating: "| cell |", count: 20))
        recording.finish(); recording.waitUntilSaved()
        var attributes: NSDictionary?
        _ = try NSAttributedString(url: recording.fileURL, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: &attributes)
        let size = try XCTUnwrap(attributes?[NSAttributedString.DocumentAttributeKey.paperSize] as? NSSize)
        XCTAssertGreaterThan(size.width, ("M" as NSString).size(withAttributes: [.font: view.font]).width * 160)
    }

    func testSaveFailureKeepsSpoolAndReportsErrorWithoutOverwritingAnotherFile() throws {
        let view = makeView()
        let reported = expectation(description: "Save failure is visible")
        reported.assertForOverFulfill = true
        let recording = try StyledTerminalRecording(view: view, title: "collision", directory: directory, onError: { _ in reported.fulfill() })
        view.getTerminal().feed(text: "retained recording")
        try Data("existing file".utf8).write(to: recording.fileURL)
        recording.finish(); recording.waitUntilSaved()
        wait(for: [reported], timeout: 2)
        XCTAssertNotNil(recording.error)
        XCTAssertEqual(try String(contentsOf: recording.fileURL), "existing file")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".recording") })
    }

    func testSelectedDestinationReplacesConfirmedExistingFileOnlyAfterClose() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let selectedURL = directory.appendingPathComponent("chosen.rtf")
        try Data("previous document".utf8).write(to: selectedURL)
        let view = makeView()
        let recording = try StyledTerminalRecording(view: view, title: "device", fileURL: selectedURL)
        XCTAssertEqual(recording.fileURL, selectedURL)
        XCTAssertThrowsError(try StyledTerminalRecording(view: makeView(), title: "other", fileURL: selectedURL))
        view.getTerminal().feed(text: "recorded in chosen location")
        XCTAssertEqual(try String(contentsOf: selectedURL), "previous document")
        recording.finish(); recording.waitUntilSaved()
        XCTAssertNil(recording.error)
        XCTAssertTrue(try read(recording).string.contains("recorded in chosen location"))
    }

    func testSelectedExistingFileChangedDuringRecordingIsPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let selectedURL = directory.appendingPathComponent("changed.rtf")
        try Data("previous document".utf8).write(to: selectedURL)
        let view = makeView()
        let recording = try StyledTerminalRecording(view: view, title: "device", fileURL: selectedURL)
        view.getTerminal().feed(text: "retained recording")
        try Data("later external edit".utf8).write(to: selectedURL, options: .atomic)
        recording.finish(); recording.waitUntilSaved()
        XCTAssertNotNil(recording.error)
        XCTAssertEqual(try String(contentsOf: selectedURL), "later external edit")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".recording") })
    }

    func testPartialEraseAboveAndBelowPreservesDisplayedContent() throws {
        for erase in ["\u{1b}[2;1H\u{1b}[J", "\u{1b}[2;18H\u{1b}[1J"] {
            let view = makeView()
            let recording = try StyledTerminalRecording(view: view, title: "partial-clear", directory: directory)
            view.getTerminal().feed(text: "header\r\nrow-before-clear\r\nnext-before-clear")
            view.getTerminal().feed(text: erase + "replacement")
            recording.finish(); recording.waitUntilSaved()
            let text = try read(recording).string
            for expected in ["header", "row-before-clear", "next-before-clear", "replacement"] {
                XCTAssertTrue(text.contains(expected), expected)
            }
        }
    }

    func testClearingEmptyRemainderDoesNotArchiveEachKeystroke() throws {
        let view = makeView()
        let recording = try StyledTerminalRecording(view: view, title: "prompt-clear", directory: directory)
        view.getTerminal().feed(text: "$ ")
        for character in "echo hello" {
            view.getTerminal().feed(text: String(character) + "\u{1b}[J")
        }
        view.getTerminal().feed(text: "\r\nhello\r\n")
        recording.finish(); recording.waitUntilSaved()
        let text = try read(recording).string
        XCTAssertTrue(text.hasPrefix("$ echo hello"))
        XCTAssertEqual(text.components(separatedBy: "$ ").count, 2)
    }

    func testUnicodeAndStyledColumnsMatchTerminalGridAfterRTFRoundTrip() throws {
        let samples: [(text: String, columns: Int, style: String)] = [
            ("中文 ", 5, ""), ("ABCD ", 5, ""), ("😀   ", 5, ""),
            ("中A", 3, ""), ("é中", 3, ""), ("👨‍👩‍👧‍👦A", 3, ""),
            ("中文", 4, "\u{1b}[1m"), ("😀中A", 5, "\u{1b}[3m"),
            (String(repeating: "中A😀é", count: 30), 180, "\u{1b}[1;3m")
        ]
        let view = makeView(columns: 200, rows: 20)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.getTerminal().resize(cols: 200, rows: 20)
        let recording = try StyledTerminalRecording(view: view, title: "grid", directory: directory)
        for sample in samples {
            view.getTerminal().feed(text: sample.style + sample.text + "|\u{1b}[0m\r\n")
        }
        for (row, sample) in samples.enumerated() {
            XCTAssertEqual(view.getTerminal().getCharacter(col: sample.columns, row: row), "|")
        }
        recording.finish(); recording.waitUntilSaved()
        let output = try read(recording)
        let string = output.string as NSString
        let layout = makeLayout(output)
        var offset = 0
        for sample in samples {
            let range = string.range(of: sample.text + "|", options: [], range: NSRange(location: offset, length: string.length - offset))
            XCTAssertNotEqual(range.location, NSNotFound)
            guard range.location != NSNotFound else { continue }
            let marker = (sample.text as NSString).length
            // Measure actual text layout. Caret offsets can bisect tracking gaps.
            let glyph = layout.manager.glyphIndexForCharacter(at: range.location + marker)
            let markerX = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + layout.manager.location(forGlyphAt: glyph).x
            XCTAssertEqual(markerX, CGFloat(sample.columns) * view.renderedCellWidth, accuracy: 0.06, sample.text)
            offset = NSMaxRange(range)
        }
    }

    func testRTFRowsKeepRenderedHeightWithMixedFontsAndFallbackGlyphs() throws {
        for (size, spacing) in [(14.0, 1.12), (13.5, 1.0), (28.0, 1.4)] {
            let view = makeView()
            view.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            view.lineSpacing = spacing
            view.getTerminal().resize(cols: 40, rows: 6)
            let recording = try StyledTerminalRecording(view: view, title: "row-height", directory: directory)
            view.getTerminal().feed(text: "ascii\r\n中文\r\n😀\r\n👨‍👩‍👧‍👦\r\nascii")
            recording.finish(); recording.waitUntilSaved()
            XCTAssertNil(recording.error)
            let layout = makeLayout(try read(recording))
            var origins: [CGFloat] = []
            layout.manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.manager.numberOfGlyphs)) { rect, _, _, _, _ in
                origins.append(rect.minY)
            }
            XCTAssertGreaterThanOrEqual(origins.count, 5)
            for index in 1..<min(origins.count, 5) {
                XCTAssertEqual(origins[index] - origins[index - 1], view.renderedCellHeight, accuracy: 0.05,
                               "font \(size), spacing \(spacing), row \(index)")
            }
        }
    }

    func testFallbackGlyphInkFitsCellsWithoutChangingTextOrFollowingColumns() throws {
        let samples = ["😀█", "A😀█", "👨‍👩‍👧‍👦█", "中😀█", "😀😀█", "A👩🏽‍💻█", "中文█"]
        for size in [9.0, 14.0, 28.0] {
            let view = makeView(columns: 40, rows: 12)
            view.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            view.lineSpacing = 1.12
            view.getTerminal().resize(cols: 40, rows: 12)
            let recording = try StyledTerminalRecording(view: view, title: "fallback-fit", directory: directory)
            for sample in samples { view.getTerminal().feed(text: sample + "\r\n") }
            recording.finish(); recording.waitUntilSaved()
            XCTAssertNil(recording.error)
            let output = try read(recording)
            let text = output.string as NSString
            let layout = makeLayout(output)
            for (row, sample) in samples.enumerated() {
                let range = text.range(of: sample)
                XCTAssertNotEqual(range.location, NSNotFound, "Text must not gain padding or attachments")
                guard range.location != NSNotFound else { continue }
                let substring = output.attributedSubstring(from: range)
                let line = CTLineCreateWithAttributedString(substring)
                let indent = (substring.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
                var slots: [Int: (start: CGFloat, width: CGFloat)] = [:]
                var utf16Index = 0
                var column = 0
                while utf16Index < (sample as NSString).length {
                    let cell = try XCTUnwrap(view.getTerminal().getScrollInvariantLine(row: view.getTerminal().screenStartRow + row))[column]
                    slots[utf16Index] = (CGFloat(column) * view.renderedCellWidth, CGFloat(cell.width) * view.renderedCellWidth)
                    utf16Index += String(view.getTerminal().getCharacter(for: cell)).utf16.count
                    column += max(1, Int(cell.width))
                }
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let count = CTRunGetGlyphCount(run)
                    var indexes = [CFIndex](repeating: 0, count: count)
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetStringIndices(run, CFRange(), &indexes)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    CTRunGetPositions(run, CFRange(), &positions)
                    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    var bounds = [CGRect](repeating: .zero, count: count)
                    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &bounds, count)
                    for index in 0..<count {
                        guard let slot = slots[indexes[index]], slot.width > view.renderedCellWidth else { continue }
                        let left = indent + positions[index].x + bounds[index].minX
                        let right = indent + positions[index].x + bounds[index].maxX
                        XCTAssertGreaterThanOrEqual(left, slot.start - 0.06, "\(sample), \(size)pt")
                        XCTAssertLessThanOrEqual(right, slot.start + slot.width + 0.06, "\(sample), \(size)pt")
                        XCTAssertLessThanOrEqual(bounds[index].height, view.renderedCellHeight + 0.06)
                    }
                }
                let markerIndex = range.location + (sample as NSString).length - 1
                let glyph = layout.manager.glyphIndexForCharacter(at: markerIndex)
                let markerX = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                    + layout.manager.location(forGlyphAt: glyph).x
                XCTAssertEqual(markerX, CGFloat(column - 1) * view.renderedCellWidth, accuracy: 0.06, sample)
            }
        }
    }

    func testUserSelectedMaximumLengthNamesSaveAndReserveSameDestination() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in [String(repeating: "n", count: 251) + ".rtf", String(repeating: "中", count: 83) + ".rtf"] {
            let url = directory.appendingPathComponent(name)
            // Demonstrate that the target name itself is accepted by the filesystem.
            try Data("original".utf8).write(to: url)
            try FileManager.default.removeItem(at: url)
            let view = makeView()
            let recording = try StyledTerminalRecording(view: view, title: "long", fileURL: url)
            XCTAssertThrowsError(try StyledTerminalRecording(view: makeView(), title: "same", fileURL: url))
            view.getTerminal().feed(text: "long name recording")
            recording.finish(); recording.waitUntilSaved()
            XCTAssertNil(recording.error)
            XCTAssertEqual(recording.fileURL, url)
            XCTAssertTrue(try read(recording).string.contains("long name recording"))
        }
    }

    func testColoredCellBackgroundsStayOnGridAcrossWideGlyphs() throws {
        for size in [9.0, 14.0, 28.0] {
            for wide in ["中", "😀", "👨‍👩‍👧‍👦"] {
                let view = makeView(columns: 30, rows: 6)
                view.font = .monospacedSystemFont(ofSize: size, weight: .regular)
                view.lineSpacing = 1.12
                view.getTerminal().resize(cols: 30, rows: 6)
                let recording = try StyledTerminalRecording(view: view, title: "background-grid", directory: directory)
                view.getTerminal().feed(text: "\u{1b}[48;2;255;0;0mA\u{1b}[48;2;0;0;255m\(wide)\u{1b}[0mB")
                recording.finish(); recording.waitUntilSaved()
                XCTAssertNil(recording.error)
                let output = try read(recording)
                XCTAssertTrue(output.string.hasPrefix("A\(wide)B"))
                let backgrounds = backgroundRects(output)
                let red = try XCTUnwrap(backgrounds.first { isRGB($0.color, red: 1, green: 0, blue: 0) })
                let blue = try XCTUnwrap(backgrounds.first { isRGB($0.color, red: 0, green: 0, blue: 1) })
                let redRect = try XCTUnwrap(red.rectangles.first)
                let blueRect = try XCTUnwrap(blue.rectangles.first)
                XCTAssertEqual(redRect.minX, 0, accuracy: 0.06)
                XCTAssertEqual(redRect.maxX, view.renderedCellWidth, accuracy: 0.06, "\(wide), \(size)pt")
                XCTAssertEqual(blueRect.minX, view.renderedCellWidth, accuracy: 0.06, "\(wide), \(size)pt")
                XCTAssertEqual(blueRect.maxX, 3 * view.renderedCellWidth, accuracy: 0.06)
                XCTAssertEqual(blueRect.height, view.renderedCellHeight, accuracy: 0.06)
            }
        }
    }

    func testFirstWideCellBackgroundHasNoLeadingGapIncludingInverseStyle() throws {
        for style in ["48;2;255;0;0", "38;2;255;0;0;7", "1;3;4;48;2;255;0;0"] {
            for wide in ["中", "😀", "👨‍👩‍👧‍👦"] {
                let view = makeView(columns: 30, rows: 6)
                view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
                view.lineSpacing = 1.12
                view.getTerminal().resize(cols: 30, rows: 6)
                let recording = try StyledTerminalRecording(view: view, title: "background-leading", directory: directory)
                view.getTerminal().feed(text: "\u{1b}[\(style)m\(wide)\u{1b}[0mB")
                recording.finish(); recording.waitUntilSaved()
                XCTAssertNil(recording.error)
                let output = try read(recording)
                XCTAssertTrue(output.string.hasPrefix(wide + "B"))
                let backgrounds = backgroundRects(output)
                let red = try XCTUnwrap(backgrounds.first { isRGB($0.color, red: 1, green: 0, blue: 0) })
                let rect = try XCTUnwrap(red.rectangles.first)
                XCTAssertEqual(rect.minX, 0, accuracy: 0.06, "\(wide), \(style)")
                XCTAssertEqual(rect.maxX, 2 * view.renderedCellWidth, accuracy: 0.06)
                XCTAssertEqual(rect.height, view.renderedCellHeight, accuracy: 0.06)
            }
        }
    }

    private func backgroundRects(_ text: NSAttributedString) -> [RecordingBackgroundLayoutManager.Fill] {
        let storage = NSTextStorage(attributedString: text)
        let manager = RecordingBackgroundLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1_000, height: 2_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        // Observe the same background draw operation used by AppKit text views,
        // rather than inferring colored cell bounds from glyph or caret positions.
        let image = NSImage(size: NSSize(width: 1_000, height: 2_000))
        image.lockFocus()
        defer { image.unlockFocus() }
        manager.drawBackground(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: .zero)
        return manager.fills
    }

    private func isRGB(_ color: NSColor, red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        guard let color = color.usingColorSpace(.sRGB) else { return false }
        return abs(color.redComponent - red) < 0.01 && abs(color.greenComponent - green) < 0.01
            && abs(color.blueComponent - blue) < 0.01
    }

    private func makeView(columns: Int = 40, rows: Int = 6) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.getTerminal().resize(cols: columns, rows: rows)
        return view
    }

    private func read(_ recording: StyledTerminalRecording) throws -> NSAttributedString {
        try NSAttributedString(url: recording.fileURL, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    private func makeLayout(_ text: NSAttributedString) -> (storage: NSTextStorage, manager: NSLayoutManager) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 10_000, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (storage, manager)
    }

    private func assertColor(_ value: Any?, red: CGFloat, green: CGFloat, blue: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return XCTFail("Missing color", file: file, line: line) }
        XCTAssertEqual(color.redComponent * 255, red, accuracy: 1, file: file, line: line)
        XCTAssertEqual(color.greenComponent * 255, green, accuracy: 1, file: file, line: line)
        XCTAssertEqual(color.blueComponent * 255, blue, accuracy: 1, file: file, line: line)
    }
}

private final class RecordingBackgroundLayoutManager: NSLayoutManager {
    struct Fill {
        let rectangles: [NSRect]
        let color: NSColor
    }
    var fills: [Fill] = []

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        fills.append(Fill(rectangles: Array(UnsafeBufferPointer(start: rectArray, count: rectCount)), color: color))
    }
}

private final class RecordingEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

private final class RecordingBridge: RemoteTerminalBridging {
    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "running")
    }
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(runtimeId: runtimeID, bytes: Data(), droppedByteCount: 0)
    }
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime { fatalError("Unused") }
    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {}
    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "closed", diagnostic: "closed")
    }
}
