import AppKit
import StacioCoreBindings
import StacioAgentBridge
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class TranscriptRecorderTests: XCTestCase {
    func testRecordingSessionIsDefaultOffAndLifecycleIsIdempotent() throws {
        let session = TerminalRecordingSession(
            recorder: TimestampedRecorder(maximumByteCount: 1_024, maximumEntryCount: 16)
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        session.append(bytes: Array("ignored".utf8), timestamp: timestamp)
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasOutput)

        XCTAssertTrue(session.start())
        XCTAssertFalse(session.start())
        session.append(bytes: Array("captured".utf8), timestamp: timestamp)
        XCTAssertTrue(session.hasOutput)
        XCTAssertTrue(session.stop())
        XCTAssertFalse(session.stop())
        session.append(bytes: Array("ignored after stop".utf8), timestamp: timestamp)

        let recording = try AsciinemaV2RecordingParser.parse(
            Data(session.exportAsciinema(title: "session").utf8)
        )
        XCTAssertEqual(recording.events.map(\.text), ["captured"])
    }

    func testRecordingSessionSavesWithoutBlockingCaller() throws {
        let session = TerminalRecordingSession()
        XCTAssertTrue(session.start())
        session.append(
            bytes: Array("saved output".utf8),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(session.stop())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-recording-session-\(UUID().uuidString).cast")
        defer { try? FileManager.default.removeItem(at: url) }
        let expectation = expectation(description: "recording save completes")
        let callStarted = Date()
        session.save(to: url, title: "saved") { result in
            switch result {
            case .success:
                break
            case let .failure(error):
                XCTFail("save failed: \(error)")
            }
            expectation.fulfill()
        }

        XCTAssertLessThan(Date().timeIntervalSince(callStarted), 0.2)
        wait(for: [expectation], timeout: 2)
        let recording = try TerminalRecordingDocument.load(from: url)
        XCTAssertEqual(recording.events.map(\.text), ["saved output"])
    }

    func testRuntimeScopedSessionReceivesOnlyPublishedTerminalOutputWhileRecording() throws {
        let hub = TerminalOutputBroadcastHub()
        let session = TerminalRecordingSession(
            runtimeID: "runtime-local",
            hub: hub
        )
        hub.publishOutput(runtimeID: "runtime-local", bytes: Array("before".utf8))
        XCTAssertTrue(session.start())
        hub.publishOutput(runtimeID: "runtime-remote", bytes: Array("other".utf8))
        hub.publishOutput(runtimeID: "runtime-local", bytes: Array("captured".utf8))
        XCTAssertTrue(session.stop())
        hub.publishOutput(runtimeID: "runtime-local", bytes: Array("after".utf8))

        let recording = try AsciinemaV2RecordingParser.parse(
            Data(session.exportAsciinema(title: "runtime").utf8)
        )
        XCTAssertEqual(recording.events.map(\.text), ["captured"])
    }

    func testLocalPaneOutputEntersRuntimeScopedRecordingThroughProductionHub() throws {
        let runtimeID = "recording-local-\(UUID().uuidString)"
        let session = TerminalRecordingSession(runtimeID: runtimeID)
        let controller = TerminalPaneViewController(
            runtimeID: runtimeID,
            shellPath: "/bin/zsh",
            eventSink: NoopTerminalEventSink(),
            autoStartProcess: false
        )
        controller.loadView()

        XCTAssertTrue(session.start())
        controller.terminalView.onOutput?(Array("local output".utf8))
        XCTAssertTrue(session.stop())

        let recording = try AsciinemaV2RecordingParser.parse(
            Data(session.exportAsciinema(title: "local").utf8)
        )
        XCTAssertEqual(recording.events.map(\.text), ["local output"])
    }

    func testRemotePaneOutputEntersRuntimeScopedRecordingForSSHSerialAndTelnet() throws {
        for connectionKind in [
            RemoteTerminalConnectionKind.ssh,
            .serial,
            .telnet
        ] {
            let runtimeID = "recording-remote-\(connectionKind)-\(UUID().uuidString)"
            let session = TerminalRecordingSession(runtimeID: runtimeID)
            let controller = RemoteTerminalPaneViewController(
                runtimeID: runtimeID,
                title: "remote",
                connectionKind: connectionKind,
                eventSink: NoopTerminalEventSink(),
                startsPollingAutomatically: false
            )
            controller.loadView()

            XCTAssertTrue(session.start())
            controller.feedRemoteOutput(Array("remote output".utf8))
            XCTAssertTrue(session.stop())

            let recording = try AsciinemaV2RecordingParser.parse(
                Data(session.exportAsciinema(title: "remote").utf8)
            )
            XCTAssertEqual(recording.events.map(\.text), ["remote output"], String(describing: connectionKind))
        }
    }

    func testRegistryReleasesRecordingWhenTerminalOwnerIsDestroyed() {
        let registry = TerminalRecordingSessionRegistry()
        let runtimeID = "recording-owner-lifecycle-\(UUID().uuidString)"
        var owner: RecordingOwner? = RecordingOwner()
        let session = registry.session(
            for: runtimeID,
            title: "lifecycle",
            owner: owner
        )

        XCTAssertTrue(session.start())
        XCTAssertTrue(session.isRecording)
        owner = nil

        XCTAssertNil(registry.existingSession(for: runtimeID))
        XCTAssertFalse(session.isRecording)
    }

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

private final class NoopTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

private final class RecordingOwner: NSObject {}
