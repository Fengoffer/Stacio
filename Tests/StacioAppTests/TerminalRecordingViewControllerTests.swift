import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import StacioApp

@MainActor
final class TerminalRecordingViewControllerTests: XCTestCase {
    func testParserReadsAsciinemaV2HeaderAndOutputEvents() throws {
        let cast = """
        {"version":2,"width":100,"height":30,"timestamp":1700000000,"title":"Deploy"}
        [0.0,"o","hello"]
        [0.5,"i","secret input"]
        [1.25,"o"," world"]

        """

        let recording = try AsciinemaV2RecordingParser.parse(Data(cast.utf8))

        XCTAssertEqual(recording.title, "Deploy")
        XCTAssertEqual(recording.width, 100)
        XCTAssertEqual(recording.height, 30)
        XCTAssertEqual(recording.events, [
            TerminalRecordingEvent(time: 0, text: "hello"),
            TerminalRecordingEvent(time: 1.25, text: " world")
        ])
        XCTAssertEqual(recording.duration, 1.25, accuracy: 0.000_001)
    }

    func testParserRejectsUnsupportedAsciinemaVersion() {
        let cast = """
        {"version":1,"width":80,"height":24}
        [0.0,"o","hello"]
        """

        XCTAssertThrowsError(try AsciinemaV2RecordingParser.parse(Data(cast.utf8))) { error in
            XCTAssertEqual(
                (error as? TerminalRecordingError)?.errorDescription,
                "仅支持 asciinema v2 录制文件。"
            )
        }
    }

    func testParserRejectsFractionalVersionInsteadOfTruncatingItToV2() {
        let cast = """
        {"version":2.5,"width":80,"height":24}
        [0.0,"o","hello"]
        """

        XCTAssertThrowsError(try AsciinemaV2RecordingParser.parse(Data(cast.utf8))) { error in
            XCTAssertEqual(error as? TerminalRecordingError, .unsupportedVersion)
        }
    }

    func testParserRejectsBooleanEventTimestamp() {
        let cast = """
        {"version":2,"width":80,"height":24}
        [true,"o","hello"]
        """

        XCTAssertThrowsError(try AsciinemaV2RecordingParser.parse(Data(cast.utf8))) { error in
            XCTAssertEqual(error as? TerminalRecordingError, .invalidEvent(line: 2))
        }
    }

    func testParserRejectsEventsWhoseTimestampsMoveBackward() {
        let cast = """
        {"version":2,"width":80,"height":24}
        [1.0,"o","later"]
        [0.5,"o","earlier"]
        """

        XCTAssertThrowsError(try AsciinemaV2RecordingParser.parse(Data(cast.utf8))) { error in
            XCTAssertEqual(
                (error as? TerminalRecordingError)?.errorDescription,
                "录制文件第 3 行的时间戳早于上一事件。"
            )
        }
    }

    func testParserRejectsExcessiveRecordingDurationBeforePlayback() {
        let cast = """
        {"version":2,"width":80,"height":24}
        [1e100,"o","hello"]
        """

        XCTAssertThrowsError(try AsciinemaV2RecordingParser.parse(Data(cast.utf8))) { error in
            XCTAssertEqual(error as? TerminalRecordingError, .durationTooLong)
        }
    }

    func testParserRejectsExcessivePhysicalLinesWithoutRetainingAllLines() {
        let cast = "{" + "\"version\":2,\"width\":80,\"height\":24}" + "\n"
            + String(repeating: "\n", count: AsciinemaV2RecordingParser.maximumLineCount)

        XCTAssertThrowsError(try AsciinemaV2RecordingParser.parse(Data(cast.utf8))) { error in
            XCTAssertEqual(error as? TerminalRecordingError, .tooManyLines)
        }
    }

    func testPlaybackAdvancesAtSelectedSpeedAndEmitsDueOutput() {
        let playback = makePlayback()
        var output: [String] = []
        playback.onOutput = { output.append($0) }

        playback.seek(to: 0)
        output.removeAll()
        playback.speed = .double
        playback.play()
        playback.advance(by: 0.6)

        XCTAssertEqual(playback.position, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(output, ["one"])
        XCTAssertTrue(playback.isPlaying)
    }

    func testPlaybackPausePreventsTimeAndOutputFromAdvancing() {
        let playback = makePlayback()
        var output: [String] = []
        playback.onOutput = { output.append($0) }

        playback.play()
        playback.pause()
        playback.advance(by: 1.5)

        XCTAssertEqual(playback.position, 0, accuracy: 0.000_001)
        XCTAssertTrue(output.isEmpty)
        XCTAssertFalse(playback.isPlaying)
    }

    func testPlaybackSeekResetsAndReplaysOutputThroughTargetPosition() {
        let playback = makePlayback()
        var resetCount = 0
        var output: [String] = []
        playback.onReset = { resetCount += 1 }
        playback.onOutput = { output.append($0) }

        playback.seek(to: 1.5)

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(output, ["zeroone"])
        XCTAssertEqual(playback.position, 1.5, accuracy: 0.000_001)
    }

    func testPlaybackStopsWhenItReachesTheFinalEvent() {
        let playback = makePlayback()
        var output: [String] = []
        playback.onOutput = { output.append($0) }

        playback.play()
        playback.advance(by: 5)

        XCTAssertEqual(playback.position, 2, accuracy: 0.000_001)
        XCTAssertEqual(output, ["zeroonetwo"])
        XCTAssertFalse(playback.isPlaying)
    }

    func testPlaybackEmitsLargeSeekOutputInBoundedChunks() {
        let recording = TerminalRecording(
            title: nil,
            width: 80,
            height: 24,
            events: [TerminalRecordingEvent(time: 0, text: String(repeating: "x", count: 200_000))]
        )
        let playback = TerminalRecordingPlayback(recording: recording)
        var chunks: [String] = []
        playback.onOutput = { chunks.append($0) }

        playback.seek(to: 0)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), String(repeating: "x", count: 200_000))
    }

    func testPlaybackCancelsAnOlderAsynchronousSeek() async {
        let playback = TerminalRecordingPlayback(recording: TerminalRecording(
            title: nil,
            width: 80,
            height: 24,
            events: [TerminalRecordingEvent(time: 1, text: "old seek output")]
        ))
        var output: [String] = []
        playback.onOutput = { output.append($0) }

        playback.seekAsynchronously(to: 1)
        playback.seekAsynchronously(to: 0)
        for _ in 0 ..< 4 {
            await Task.yield()
        }

        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(playback.position, 0, accuracy: 0.000_001)
    }

    func testViewControllerFormatsLongDurationsAndLabelsSourceFile() {
        let controller = TerminalRecordingViewController(
            recording: TerminalRecording(
                title: nil,
                width: 80,
                height: 24,
                events: [TerminalRecordingEvent(time: 3_661, text: "done")]
            ),
            sourceName: "long.cast"
        )
        controller.loadView()

        XCTAssertEqual(controller.timeLabel.stringValue, "00:00 / 01:01:01")
        XCTAssertEqual(controller.terminalView.accessibilityLabel(), "录制回放：long.cast")
    }

    func testViewControllerFormatsOutOfRangeFiniteDurationWithoutIntegerTrap() {
        let controller = TerminalRecordingViewController(
            recording: TerminalRecording(
                title: nil,
                width: 80,
                height: 24,
                events: [],
                duration: Double.greatestFiniteMagnitude
            ),
            sourceName: "huge.cast"
        )
        controller.loadView()

        XCTAssertTrue(controller.timeLabel.stringValue.hasPrefix("00:00 / "))
    }

    func testViewControllerKeepsRecordingTerminalDimensionsAfterLayoutResize() {
        let controller = TerminalRecordingViewController(
            recording: TerminalRecording(
                title: nil,
                width: 100,
                height: 30,
                events: [TerminalRecordingEvent(time: 0, text: "done")]
            ),
            sourceName: "sized.cast"
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.terminalView.getTerminal().cols, 100)
        XCTAssertEqual(controller.terminalView.getTerminal().rows, 30)
    }

    func testRecordingDurationCannotEndBeforeItsLastOutputEvent() {
        let recording = TerminalRecording(
            title: nil,
            width: 80,
            height: 24,
            events: [TerminalRecordingEvent(time: 2, text: "done")],
            duration: 1
        )

        XCTAssertEqual(recording.duration, 2, accuracy: 0.000_001)
    }

    func testDocumentLoadsCastFileAndRejectsOversizedInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-recording-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validURL = directory.appendingPathComponent("sample.cast")
        try Data("""
        {"version":2,"width":90,"height":28,"title":"Sample"}
        [0.0,"o","ready"]
        """.utf8).write(to: validURL)

        let recording = try TerminalRecordingDocument.load(from: validURL)
        XCTAssertEqual(recording.title, "Sample")
        XCTAssertEqual(recording.events.map(\.text), ["ready"])

        let oversizedURL = directory.appendingPathComponent("oversized.cast")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(AsciinemaV2RecordingParser.maximumFileSize + 1))
        try handle.close()

        XCTAssertThrowsError(try TerminalRecordingDocument.load(from: oversizedURL)) { error in
            XCTAssertEqual(error as? TerminalRecordingError, .fileTooLarge)
        }
    }

    func testViewControllerBuildsAndRoutesPlaybackControls() {
        let controller = TerminalRecordingViewController(
            recording: makeRecording(),
            sourceName: "sample.cast"
        )
        controller.loadView()

        XCTAssertTrue(controller.view.subviews.contains(controller.terminalView))
        XCTAssertEqual(controller.progressSlider.minValue, 0)
        XCTAssertEqual(controller.progressSlider.maxValue, 2, accuracy: 0.000_001)
        XCTAssertFalse(controller.progressSlider.isContinuous)
        XCTAssertEqual(controller.speedControl.segmentCount, 3)
        XCTAssertEqual((0 ..< 3).map { controller.speedControl.label(forSegment: $0) }, [
            "0.5x", "1x", "2x"
        ])
        XCTAssertEqual(controller.speedControl.selectedSegment, 1)

        controller.playPauseButton.performClick(nil)
        XCTAssertTrue(controller.playback.isPlaying)

        controller.speedControl.selectedSegment = 2
        controller.speedChanged(controller.speedControl)
        XCTAssertEqual(controller.playback.speed, .double)

        controller.progressSlider.doubleValue = 1.5
        controller.progressChanged(controller.progressSlider)
        XCTAssertEqual(controller.playback.position, 1.5, accuracy: 0.000_001)
        XCTAssertFalse(controller.playback.isPlaying)

        controller.playPauseButton.performClick(nil)
        XCTAssertFalse(controller.playback.isPlaying)
    }

    func testRecordingOpenPanelSelectsOneCastFile() throws {
        let panel = TerminalRecordingWindowCoordinator.makeOpenPanel()

        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.allowedContentTypes, [try XCTUnwrap(UTType(filenameExtension: "cast"))])
    }

    func testRecordingWindowHostsPlaybackControllerAtStableMinimumSize() throws {
        let windowController = TerminalRecordingWindowController(
            recording: makeRecording(),
            sourceName: "sample.cast"
        )
        let window = try XCTUnwrap(windowController.window)

        XCTAssertTrue(window.contentViewController is TerminalRecordingViewController)
        XCTAssertEqual(window.title, "Test")
        XCTAssertGreaterThanOrEqual(window.minSize.width, 620)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 360)
    }

    func testRecordingWindowControllerRunsCloseCallback() throws {
        let windowController = TerminalRecordingWindowController(
            recording: makeRecording(),
            sourceName: "sample.cast"
        )
        var closed = false
        windowController.onClose = { closed = true }
        try XCTUnwrap(windowController.window).close()

        XCTAssertTrue(closed)
    }

    private func makePlayback() -> TerminalRecordingPlayback {
        TerminalRecordingPlayback(recording: makeRecording())
    }

    private func makeRecording() -> TerminalRecording {
        TerminalRecording(
            title: "Test",
            width: 80,
            height: 24,
            events: [
                TerminalRecordingEvent(time: 0, text: "zero"),
                TerminalRecordingEvent(time: 1, text: "one"),
                TerminalRecordingEvent(time: 2, text: "two")
            ]
        )
    }
}
