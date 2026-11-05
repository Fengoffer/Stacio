import AppKit
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class TerminalGutterAbsoluteLineTests: XCTestCase {
    func testLocalGutterUsesAbsoluteBufferLineAfterViewportScrolls() {
        let suiteName = "StacioAbsoluteLocalGutter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalLineNumbersEnabled = true
            settings.terminalTimestampsEnabled = false
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_absolute_local",
            shellPath: "/bin/zsh",
            eventSink: AbsoluteLineNoopTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.view.setFrameSize(NSSize(width: 900, height: 520))
        controller.terminalView.setFrameSize(NSSize(width: 740, height: 420))
        let output = (1...750).map { "line \($0)" }.joined(separator: "\r\n")
        controller.terminalView.dataReceived(slice: ArraySlice(Array(output.utf8)))

        XCTAssertTrue(waitUntil {
            controller.lineInfoGutterVisibleTextForTesting
                .split(separator: "\n")
                .last?
                .trimmingCharacters(in: .whitespaces) == "750"
        })

        let lines = controller.lineInfoGutterVisibleTextForTesting
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.last?.trimmingCharacters(in: .whitespaces), "750")
        XCTAssertGreaterThan(
            controller.lineInfoGutterPreferredWidthForTesting,
            TerminalLineInfoGutterView.preferredWidth(for: settingsStore.snapshot(), rows: 50)
        )
        let widthAtBottom = controller.lineInfoGutterPreferredWidthForTesting

        controller.terminalView.scrollTo(row: 0)
        XCTAssertEqual(controller.terminalView.getTerminal().getTopVisibleRow(), 0)
        XCTAssertTrue(waitUntil {
            controller.lineInfoGutterVisibleTextForTesting
                .split(separator: "\n")
                .first?
                .trimmingCharacters(in: .whitespaces) == "1"
        }, controller.lineInfoGutterVisibleTextForTesting)
        XCTAssertEqual(controller.lineInfoGutterPreferredWidthForTesting, widthAtBottom)
    }

    func testRemoteGutterUsesAbsoluteBufferLineAfterViewportScrolls() {
        let suiteName = "StacioAbsoluteRemoteGutter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalLineNumbersEnabled = true
            settings.terminalTimestampsEnabled = false
        }
        let controller = RemoteTerminalPaneViewController(
            runtimeID: "term_absolute_remote",
            title: "remote",
            eventSink: AbsoluteLineNoopTerminalEventSink(),
            settingsStore: settingsStore,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.view.setFrameSize(NSSize(width: 900, height: 520))
        controller.terminalView.setFrameSize(NSSize(width: 740, height: 420))
        let output = (1...750).map { "line \($0)" }.joined(separator: "\r\n")
        controller.feedRemoteOutput(Array(output.utf8))

        XCTAssertTrue(waitUntil {
            controller.lineInfoGutterVisibleTextForTesting
                .split(separator: "\n")
                .last?
                .trimmingCharacters(in: .whitespaces) == "750"
        })

        let lines = controller.lineInfoGutterVisibleTextForTesting
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.last?.trimmingCharacters(in: .whitespaces), "750")
        XCTAssertGreaterThan(
            controller.lineInfoGutterPreferredWidthForTesting,
            TerminalLineInfoGutterView.preferredWidth(for: settingsStore.snapshot(), rows: 50)
        )
        let widthAtBottom = controller.lineInfoGutterPreferredWidthForTesting

        controller.terminalView.scrollTo(row: 0)
        XCTAssertTrue(waitUntil {
            controller.lineInfoGutterVisibleTextForTesting
                .split(separator: "\n")
                .first?
                .trimmingCharacters(in: .whitespaces) == "1"
        })
        XCTAssertEqual(controller.lineInfoGutterPreferredWidthForTesting, widthAtBottom)
    }

    func testGutterIncludesRenderedBlankRowsThroughCursor() {
        let settings = AppSettings(terminalLineNumbersEnabled: true)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 740, height: 420))
        let gutter = TerminalLineInfoGutterView(frame: .zero)

        terminalView.feed(byteArray: ArraySlice("first\r\n\r\n".utf8))
        gutter.apply(settings: settings, terminalView: terminalView)

        XCTAssertEqual(gutter.visibleTextForTesting.components(separatedBy: "\n").count, 3)
        XCTAssertEqual(gutter.visibleTextForTesting.components(separatedBy: "\n").last, " 3")
    }

    func testGutterRemainsVisibleAfterClearingPreviouslyRenderedOutput() {
        let settings = AppSettings(terminalLineNumbersEnabled: true)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 740, height: 420))
        let gutter = TerminalLineInfoGutterView(frame: .zero)

        terminalView.feed(byteArray: ArraySlice("first".utf8))
        gutter.apply(settings: settings, terminalView: terminalView)
        terminalView.feed(byteArray: ArraySlice("\u{1B}[2J\u{1B}[H".utf8))
        gutter.refresh(from: terminalView)

        XCTAssertEqual(gutter.visibleTextForTesting.trimmingCharacters(in: .whitespaces), "1")
    }

    func testGutterLeavesWrappedContinuationRowsUnnumbered() {
        let settings = AppSettings(terminalLineNumbersEnabled: true)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let gutter = TerminalLineInfoGutterView(frame: .zero)
        let columns = terminalView.getTerminal().getDims().cols

        terminalView.feed(byteArray: ArraySlice(String(repeating: "x", count: columns + 1).utf8))
        gutter.apply(settings: settings, terminalView: terminalView)

        let rows = gutter.visibleTextForTesting.components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].trimmingCharacters(in: .whitespaces), "1")
        XCTAssertEqual(rows[1], "")
    }

    func testGutterUsesAbsoluteLineAfterScrollbackTrims() {
        let settings = AppSettings(terminalLineNumbersEnabled: true)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 740, height: 420))
        let gutter = TerminalLineInfoGutterView(frame: .zero)
        terminalView.getTerminal().changeHistorySize(5)

        let output = (1...100).map { "line \($0)" }.joined(separator: "\r\n")
        terminalView.feed(byteArray: ArraySlice(output.utf8))
        gutter.apply(settings: settings, terminalView: terminalView)

        XCTAssertGreaterThan(terminalView.getTerminal().buffer.totalLinesTrimmed, 0)
        XCTAssertEqual(
            gutter.visibleTextForTesting
                .split(separator: "\n")
                .last?
                .trimmingCharacters(in: .whitespaces),
            "100"
        )
    }

    func testGutterResetsAbsoluteLineCacheAcrossAlternateBuffer() {
        let settings = AppSettings(terminalLineNumbersEnabled: true)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 740, height: 420))
        let gutter = TerminalLineInfoGutterView(frame: .zero)

        terminalView.feed(byteArray: ArraySlice((1...120).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        gutter.apply(settings: settings, terminalView: terminalView)
        XCTAssertEqual(
            gutter.visibleTextForTesting.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
            "120"
        )

        terminalView.feed(byteArray: ArraySlice("\u{1B}[?1049halt\r\n".utf8))
        gutter.refresh(from: terminalView)
        XCTAssertTrue(terminalView.getTerminal().isCurrentBufferAlternate)
        XCTAssertNotEqual(
            gutter.visibleTextForTesting.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
            "120"
        )
        XCTAssertLessThan(
            gutter.preferredWidthForTesting,
            TerminalLineInfoGutterView.preferredWidth(for: settings, rows: 24, maximumLineNumber: 120)
        )

        terminalView.feed(byteArray: ArraySlice("\u{1B}[?1049l".utf8))
        gutter.refresh(from: terminalView)
        XCTAssertFalse(terminalView.getTerminal().isCurrentBufferAlternate)
        XCTAssertEqual(
            gutter.visibleTextForTesting.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
            "120"
        )
    }

    func testGutterResetsAbsoluteLineCacheAfterTerminalReset() {
        let settings = AppSettings(terminalLineNumbersEnabled: true)
        let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 740, height: 420))
        let gutter = TerminalLineInfoGutterView(frame: .zero)

        terminalView.feed(byteArray: ArraySlice((1...120).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        gutter.apply(settings: settings, terminalView: terminalView)
        terminalView.feed(byteArray: ArraySlice("\u{1B}cnew".utf8))
        gutter.refresh(from: terminalView)

        XCTAssertEqual(
            gutter.visibleTextForTesting.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
            "1"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class AbsoluteLineNoopTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}
