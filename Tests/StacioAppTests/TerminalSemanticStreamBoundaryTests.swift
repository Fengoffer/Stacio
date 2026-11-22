import AppKit
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class TerminalSemanticStreamBoundaryTests: XCTestCase {
    private let configuration = TerminalSemanticHighlightConfiguration(
        level: .commandLineEnhanced, richHighlightingEnabled: true, theme: .tokyoNight
    )

    func testEverySplitInsideTrueColorSequencePreservesNativeBytesAndColors() throws {
        let sgr = Array("\u{1b}[38;2;17;34;51m".utf8)
        for split in 1..<sgr.count {
            let processor = TerminalSemanticOutputProcessor(label: "test.sgr.\(split)")
            let view = TerminalView(frame: .zero)
            var delivered: [UInt8] = []
            func feed(_ bytes: [UInt8]) {
                processor.process(bytes: bytes, configuration: configuration) {
                    delivered += $0
                    view.getTerminal().feed(byteArray: $0)
                }
            }
            feed(Array(sgr.prefix(split)))
            feed(Array(sgr.dropFirst(split)) + Array("ROW001916\u{1b}[0m\r\n".utf8))
            XCTAssertEqual(delivered, sgr + Array("ROW001916\u{1b}[0m\r\n".utf8), "split \(split)")
            XCTAssertEqual(view.getTerminal().getCharData(col: 0, row: 0)?.attribute.fg, .trueColor(red: 17, green: 34, blue: 51))
        }
    }

    func testLongAsynchronousChunksPreserveBoundaryAndResumeHighlighting() {
        let processor = TerminalSemanticOutputProcessor(label: "test.async.sgr")
        let prefix = Array((String(repeating: "plain row\r\n", count: 100) + "\u{1b}[38;2;17;").utf8)
        let suffix = Array("34;51mCOLORED\u{1b}[0m\r\n".utf8)
        var delivered: [[UInt8]] = []
        processor.process(bytes: prefix, configuration: configuration) { delivered.append($0) }
        processor.process(bytes: suffix, configuration: configuration) { delivered.append($0) }
        let deadline = Date().addingTimeInterval(3)
        while delivered.count < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(delivered.flatMap { $0 }, prefix + suffix)
        var highlighted: [UInt8] = []
        processor.process(bytes: Array("error 123\r\n".utf8), configuration: configuration) { highlighted = $0 }
        XCTAssertTrue(String(decoding: highlighted, as: UTF8.self).contains("StacioHighlight=start"))
    }

    func testCancelClearsPartialControlState() {
        let processor = TerminalSemanticOutputProcessor(label: "test.cancel.sgr")
        processor.process(bytes: Array("\u{1b}]7;file://".utf8), configuration: configuration) { _ in }
        processor.cancel()
        var highlighted: [UInt8] = []
        processor.process(bytes: Array("error 123\r\n".utf8), configuration: configuration) { highlighted = $0 }
        XCTAssertTrue(String(decoding: highlighted, as: UTF8.self).contains("StacioHighlight=start"))
    }
}
