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
}
