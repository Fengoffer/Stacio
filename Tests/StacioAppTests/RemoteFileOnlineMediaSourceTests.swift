import WebKit
import XCTest
@testable import StacioApp

@MainActor
final class RemoteFileOnlineMediaSourceTests: XCTestCase {
    func testRegistryReturnsResolvableURLForReservedAndControlFileNames() throws {
        let names = [
            "preview #1?.mp4",
            "100%.mp4",
            "bad\u{0}name.mp4",
            "配置 文件.mp4"
        ]

        for name in names {
            let url = RemoteFileOnlineMediaRegistry.shared.register(
                fileName: name,
                mimeType: "video/mp4",
                byteCount: 0
            ) { _, _ in
                Data()
            }

            XCTAssertEqual(url.scheme, RemoteFileOnlineMediaRegistry.scheme)
            XCTAssertNotNil(
                RemoteFileOnlineMediaRegistry.shared.source(for: url),
                "registered source should remain resolvable for \(name.debugDescription)"
            )
        }
    }

    func testSchemeHandlerIgnoresStoppedTaskWhenBackgroundReadCompletes() throws {
        let readStarted = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let stoppedTaskDidReceiveCallback = expectation(description: "stopped task receives no callbacks")
        stoppedTaskDidReceiveCallback.isInverted = true

        let url = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "clip.mp4",
            mimeType: "video/mp4",
            byteCount: 4
        ) { _, _ in
            readStarted.signal()
            _ = finishRead.wait(timeout: .now() + 1)
            return Data([0, 1, 2, 3])
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let task = RecordingURLSchemeTask(request: request)
        task.onCallback = { _ in
            stoppedTaskDidReceiveCallback.fulfill()
        }

        let webView = WKWebView(frame: .zero)
        RemoteFileOnlineMediaSchemeHandler.shared.webView(webView, start: task)
        XCTAssertEqual(readStarted.wait(timeout: .now() + 1), .success)

        RemoteFileOnlineMediaSchemeHandler.shared.webView(webView, stop: task)
        finishRead.signal()

        wait(for: [stoppedTaskDidReceiveCallback], timeout: 0.3)
        XCTAssertTrue(task.callbacks.isEmpty)
    }

    func testSchemeHandlerServesSuffixByteRangeWithoutReadingWholeRemoteFile() throws {
        let servedRange = expectation(description: "suffix range served")
        let reader = RecordingMediaReader(data: Data([2, 3]))
        let url = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "tail.mp4",
            mimeType: "video/mp4",
            byteCount: 4
        ) { offset, length in try reader.read(offset: offset, length: length) }
        var request = URLRequest(url: url)
        request.setValue("bytes=-2", forHTTPHeaderField: "Range")
        let task = RecordingURLSchemeTask(request: request)
        task.onCallback = { callback in
            if callback == "finish" {
                servedRange.fulfill()
            }
        }

        let webView = WKWebView(frame: .zero)
        RemoteFileOnlineMediaSchemeHandler.shared.webView(webView, start: task)

        wait(for: [servedRange], timeout: 1)
        let response = try XCTUnwrap(task.responses.first as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 2-3/4")
        XCTAssertEqual(task.dataChunks, [Data([2, 3])])
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertEqual(reader.requests.first?.offset, 2)
        XCTAssertEqual(reader.requests.first?.length, 2)
    }
}

private final class RecordingMediaReader: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var recordedRequests: [(offset: UInt64, length: UInt64?)] = []

    init(data: Data) {
        self.data = data
    }

    var requests: [(offset: UInt64, length: UInt64?)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func read(offset: UInt64, length: UInt64?) throws -> Data {
        lock.lock()
        recordedRequests.append((offset, length))
        lock.unlock()
        return data
    }
}

private final class RecordingURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var onCallback: ((String) -> Void)?

    private let lock = NSLock()
    private var recordedCallbacks: [String] = []
    private var recordedResponses: [URLResponse] = []
    private var recordedDataChunks: [Data] = []

    init(request: URLRequest) {
        self.request = request
    }

    var callbacks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallbacks
    }

    var responses: [URLResponse] {
        lock.lock()
        defer { lock.unlock() }
        return recordedResponses
    }

    var dataChunks: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDataChunks
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        recordedResponses.append(response)
        lock.unlock()
        record("response")
    }

    func didReceive(_ data: Data) {
        lock.lock()
        recordedDataChunks.append(data)
        lock.unlock()
        record("data")
    }

    func didFinish() {
        record("finish")
    }

    func didFailWithError(_ error: Error) {
        record("failure")
    }

    private func record(_ callback: String) {
        lock.lock()
        recordedCallbacks.append(callback)
        lock.unlock()
        onCallback?(callback)
    }
}
