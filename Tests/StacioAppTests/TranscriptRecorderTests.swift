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
}
