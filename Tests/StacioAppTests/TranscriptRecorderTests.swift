import XCTest
@testable import StacioApp

final class TranscriptRecorderTests: XCTestCase {
    func testRecorderAppendsUtf8OutputSlices() {
        let recorder = TranscriptRecorder()

        recorder.append(bytes: Array("hello".utf8))
        recorder.append(bytes: Array(" world".utf8))

        XCTAssertEqual(recorder.snapshot, "hello world")
    }

    func testRecorderReplacesInvalidUtf8() {
        let recorder = TranscriptRecorder()

        recorder.append(bytes: [0xff, 0xfe])

        XCTAssertFalse(recorder.snapshot.isEmpty)
    }

    func testRecorderResetClearsBufferedOutput() {
        let recorder = TranscriptRecorder()

        recorder.append(bytes: Array("stale failure prompt".utf8))
        recorder.reset()

        XCTAssertEqual(recorder.snapshot, "")
    }

    func testRecorderRetainsMostRecentOutputWithinByteLimit() {
        let recorder = TranscriptRecorder(maximumByteCount: 8)

        recorder.append(bytes: Array("12345".utf8))
        recorder.append(bytes: Array("67890".utf8))

        XCTAssertEqual(recorder.snapshot, "34567890")
    }

    func testRecorderDoesNotSplitUTF8CharactersWhenTrimming() {
        let recorder = TranscriptRecorder(maximumByteCount: 5)

        recorder.append(bytes: Array("ab你".utf8))
        recorder.append(bytes: Array("好".utf8))

        XCTAssertEqual(recorder.snapshot, "好")
    }

    func testTimestampedRecorderCapturesDecodedTextAndTimestamps() {
        let recorder = TimestampedRecorder()
        let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let secondTimestamp = firstTimestamp.addingTimeInterval(1.25)

        recorder.append(bytes: Array("hello ".utf8), timestamp: firstTimestamp)
        recorder.append(bytes: Array("世界".utf8), timestamp: secondTimestamp)
        recorder.append(bytes: [], timestamp: secondTimestamp)

        XCTAssertEqual(recorder.entries.count, 2)
        XCTAssertEqual(recorder.entries[0].t, firstTimestamp)
        XCTAssertEqual(recorder.entries[0].text, "hello ")
        XCTAssertEqual(recorder.entries[1].t, secondTimestamp)
        XCTAssertEqual(recorder.entries[1].text, "世界")
    }

    func testTimestampedRecorderExportsAsciinemaV2JSONLines() throws {
        let recorder = TimestampedRecorder()
        let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

        recorder.append(bytes: Array("first\n".utf8), timestamp: firstTimestamp)
        recorder.append(
            bytes: Array("quoted \\\"value\\\"\\path".utf8),
            timestamp: firstTimestamp.addingTimeInterval(1.25)
        )

        let lines = recorder.exportAsciinema(title: "Production shell").split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        let header = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual((header["version"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((header["width"] as? NSNumber)?.intValue, 80)
        XCTAssertEqual((header["height"] as? NSNumber)?.intValue, 24)
        XCTAssertEqual((header["timestamp"] as? NSNumber)?.int64Value, 1_700_000_000)
        XCTAssertEqual(header["title"] as? String, "Production shell")

        let firstEvent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [Any]
        )
        XCTAssertEqual(
            try XCTUnwrap(firstEvent[0] as? NSNumber).doubleValue,
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(firstEvent[1] as? String, "o")
        XCTAssertEqual(firstEvent[2] as? String, "first\n")

        let secondEvent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [Any]
        )
        XCTAssertEqual(
            try XCTUnwrap(secondEvent[0] as? NSNumber).doubleValue,
            1.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(secondEvent[1] as? String, "o")
        XCTAssertEqual(secondEvent[2] as? String, "quoted \\\"value\\\"\\path")
    }

    func testTimestampedRecorderKeepsExportOffsetsMonotonicWhenClockMovesBackward() throws {
        let recorder = TimestampedRecorder()
        let firstTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

        recorder.append(bytes: Array("first".utf8), timestamp: firstTimestamp)
        recorder.append(bytes: Array("second".utf8), timestamp: firstTimestamp.addingTimeInterval(-2))

        let lines = recorder.exportAsciinema(title: "Clock adjustment").split(separator: "\n")
        let firstEvent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [Any]
        )
        let secondEvent = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [Any]
        )
        XCTAssertEqual(
            try XCTUnwrap(firstEvent[0] as? NSNumber).doubleValue,
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(secondEvent[0] as? NSNumber).doubleValue,
            0,
            accuracy: 0.000_001
        )
    }

    func testTimestampedRecorderPreservesUtf8CharactersSplitAcrossAppends() {
        let recorder = TimestampedRecorder()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let bytes = Array("你".utf8)

        recorder.append(bytes: Array(bytes.prefix(1)), timestamp: timestamp)
        recorder.append(bytes: Array(bytes.dropFirst()), timestamp: timestamp.addingTimeInterval(0.2))

        XCTAssertEqual(recorder.entries.map(\.text), ["你"])
    }

    func testTimestampedRecorderFlushesIncompleteUTF8OnExportAndResetDropsPendingBytes() {
        let recorder = TimestampedRecorder()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        recorder.append(bytes: [0xF0, 0x9F], timestamp: timestamp)

        let exported = recorder.exportAsciinema(title: "incomplete")
        XCTAssertTrue(exported.contains("�"))

        recorder.reset()
        recorder.append(bytes: Array("ok".utf8), timestamp: timestamp)
        XCTAssertEqual(recorder.entries.map(\.text), ["ok"])
    }

    func testTimestampedRecorderStopsAcceptingOutputAfterConfiguredLimits() {
        let recorder = TimestampedRecorder(maximumByteCount: 4, maximumEntryCount: 2)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        recorder.append(bytes: Array("1234".utf8), timestamp: timestamp)
        recorder.append(bytes: Array("5".utf8), timestamp: timestamp)

        XCTAssertEqual(recorder.entries.map(\.text), ["1234"])
        XCTAssertTrue(recorder.isTruncated)
    }
}
