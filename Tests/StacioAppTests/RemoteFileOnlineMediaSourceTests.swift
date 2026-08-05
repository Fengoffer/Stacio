import Network
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

    func testUnregisterRunsSourceCleanupExactlyOnce() {
        let invalidation = MediaInvalidationCounter()
        let url = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "clip.mp4",
            mimeType: "video/mp4",
            byteCount: 4,
            onInvalidate: { invalidation.increment() },
            reader: { _, _ in Data([1, 2, 3, 4]) }
        )

        RemoteFileOnlineMediaRegistry.shared.unregister(url: url)
        RemoteFileOnlineMediaRegistry.shared.unregister(url: url)

        XCTAssertEqual(invalidation.value, 1)
        XCTAssertNil(RemoteFileOnlineMediaRegistry.shared.source(for: url))
    }

    func testSchemeHandlerIgnoresStoppedTaskWhenBackgroundReadCompletes() throws {
        let readStarted = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let reader = BlockingBoundedMediaReader(
            byteCount: UInt64(1 * 1_024 * 1_024),
            readStarted: readStarted,
            finishFirstRead: finishRead
        )
        let stoppedTaskDidReceiveCallback = expectation(description: "stopped task receives no callbacks")
        stoppedTaskDidReceiveCallback.isInverted = true

        let url = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "clip.mp4",
            mimeType: "video/mp4",
            byteCount: UInt64(1 * 1_024 * 1_024),
            reader: { offset, length in try reader.read(offset: offset, length: length) }
        )
        let task = RecordingURLSchemeTask(request: URLRequest(url: url))
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
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertLessThan(
            try XCTUnwrap(reader.requests.first?.length),
            UInt64(1 * 1_024 * 1_024)
        )
    }

    func testUnregisterInvalidatesSourceCapturedBySchemeTaskBeforeNextChunk() throws {
        let readStarted = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let reader = BlockingBoundedMediaReader(
            byteCount: UInt64(1 * 1_024 * 1_024),
            readStarted: readStarted,
            finishFirstRead: finishRead
        )
        let revokedTaskDidReceiveCallback = expectation(description: "revoked task receives no callbacks")
        revokedTaskDidReceiveCallback.isInverted = true
        let url = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "large-image.webp",
            mimeType: "image/webp",
            byteCount: UInt64(1 * 1_024 * 1_024),
            reader: { offset, length in try reader.read(offset: offset, length: length) }
        )
        let task = RecordingURLSchemeTask(request: URLRequest(url: url))
        task.onCallback = { _ in revokedTaskDidReceiveCallback.fulfill() }

        let webView = WKWebView(frame: .zero)
        RemoteFileOnlineMediaSchemeHandler.shared.webView(webView, start: task)
        XCTAssertEqual(readStarted.wait(timeout: .now() + 1), .success)

        RemoteFileOnlineMediaRegistry.shared.unregister(url: url)
        finishRead.signal()

        wait(for: [revokedTaskDidReceiveCallback], timeout: 0.3)
        XCTAssertTrue(task.callbacks.isEmpty)
        XCTAssertEqual(reader.requests.count, 1)
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

    func testSchemeHandlerCapsLargeRequestWithoutRangeToOnePartialResponse() throws {
        let byteCount = UInt64(1 * 1_024 * 1_024 + 17)
        let served = expectation(description: "bounded partial response served")
        let reader = BoundedMediaReader(byteCount: byteCount)
        let url = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "large-image.webp",
            mimeType: "image/webp",
            byteCount: byteCount,
            reader: { offset, length in
                try reader.read(offset: offset, length: length)
            }
        )
        let task = RecordingURLSchemeTask(request: URLRequest(url: url))
        task.onCallback = { callback in
            if callback == "finish" {
                served.fulfill()
            }
        }

        let webView = WKWebView(frame: .zero)
        RemoteFileOnlineMediaSchemeHandler.shared.webView(webView, start: task)

        wait(for: [served], timeout: 2)
        let response = try XCTUnwrap(task.responses.first as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 0-1048575/1048593")
        XCTAssertEqual(task.dataChunks.reduce(0) { $0 + $1.count }, 1 * 1_024 * 1_024)
        XCTAssertTrue(reader.requests.allSatisfy { request in
            guard let length = request.length else { return false }
            return length > 0 && length <= 1 * 1_024 * 1_024
        })
    }

    func testPlaybackServerServesByteRangeAndRevokesClosedRegistration() async throws {
        let reader = RecordingMediaReader(data: Data([2, 3, 4]))
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "clip.mp4",
            mimeType: "video/mp4",
            byteCount: 6,
            reader: { offset, length in
                try reader.read(offset: offset, length: length)
            }
        )
        var request = URLRequest(url: url)
        request.setValue("bytes=2-4", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 2-4/6")
        XCTAssertEqual(data, Data([2, 3, 4]))
        XCTAssertEqual(reader.requests.first?.offset, 2)
        XCTAssertEqual(reader.requests.first?.length, 3)

        RemoteFileOnlineMediaRegistry.shared.unregister(url: url)
        let (_, revokedResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    func testUnregisterStopsAlreadyCapturedHTTPSourceBeforeNextChunkRead() throws {
        let readStarted = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let reader = BlockingBoundedMediaReader(
            byteCount: UInt64(1 * 1_024 * 1_024),
            readStarted: readStarted,
            finishFirstRead: finishRead
        )
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "captured.mp4",
            mimeType: "video/mp4",
            byteCount: UInt64(1 * 1_024 * 1_024),
            reader: { offset, length in try reader.read(offset: offset, length: length) }
        )
        let requestFinished = expectation(description: "revoked HTTP request finishes")
        let task = URLSession.shared.dataTask(with: url) { _, _, _ in
            requestFinished.fulfill()
        }
        task.resume()
        XCTAssertEqual(readStarted.wait(timeout: .now() + 1), .success)

        RemoteFileOnlineMediaRegistry.shared.unregister(url: url)
        finishRead.signal()

        wait(for: [requestFinished], timeout: 2)
        XCTAssertEqual(reader.requests.count, 1)
    }

    func testHTTPClientDisconnectStopsFurtherChunkReads() throws {
        let readStarted = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let reader = BlockingBoundedMediaReader(
            byteCount: UInt64(1 * 1_024 * 1_024),
            readStarted: readStarted,
            finishFirstRead: finishRead
        )
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "cancelled.mp4",
            mimeType: "video/mp4",
            byteCount: UInt64(1 * 1_024 * 1_024),
            reader: { offset, length in try reader.read(offset: offset, length: length) }
        )
        defer { RemoteFileOnlineMediaRegistry.shared.unregister(url: url) }
        let host = try XCTUnwrap(url.host).appending(":\(try XCTUnwrap(url.port))")
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(try XCTUnwrap(url.port))))
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp)
        let connected = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected.signal()
            case .cancelled:
                disconnected.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "StacioTests.RemoteMediaClient"))
        XCTAssertEqual(connected.wait(timeout: .now() + 1), .success)
        let requestTarget = url.path + (url.query.map { "?\($0)" } ?? "")
        let request = Data("GET \(requestTarget) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
        let requestSent = DispatchSemaphore(value: 0)
        connection.send(content: request, completion: .contentProcessed { _ in requestSent.signal() })
        XCTAssertEqual(requestSent.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(readStarted.wait(timeout: .now() + 1), .success)

        connection.cancel()
        XCTAssertEqual(disconnected.wait(timeout: .now() + 1), .success)
        finishRead.signal()

        let disconnectPropagationSettles = expectation(description: "disconnect propagation settles")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
            disconnectPropagationSettles.fulfill()
        }
        wait(for: [disconnectPropagationSettles], timeout: 2)
        XCTAssertEqual(reader.requests.count, 1)
    }

    func testPlaybackServerCapsOpenEndedRangeInsteadOfReadingEntireRemoteFile() async throws {
        let byteCount = UInt64(8 * 1_024 * 1_024)
        let reader = RecordingMediaReader(data: Data(repeating: 0x5A, count: 32))
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "large.mp4",
            mimeType: "video/mp4",
            byteCount: byteCount,
            reader: { offset, length in
                try reader.read(offset: offset, length: length)
            }
        )
        defer { RemoteFileOnlineMediaRegistry.shared.unregister(url: url) }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")

        let (_, response) = try await URLSession.shared.data(for: request)

        let requestedLength = try XCTUnwrap(reader.requests.first?.length)
        XCTAssertLessThan(requestedLength, byteCount)
        XCTAssertLessThanOrEqual(requestedLength, 1 * 1_024 * 1_024)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
    }

    func testPlaybackServerCapsLargeRequestWithoutRangeToOnePartialResponse() async throws {
        let byteCount = UInt64(1 * 1_024 * 1_024 + 29)
        let reader = BoundedMediaReader(byteCount: byteCount)
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "large.mp4",
            mimeType: "video/mp4",
            byteCount: byteCount,
            reader: { offset, length in
                try reader.read(offset: offset, length: length)
            }
        )
        defer { RemoteFileOnlineMediaRegistry.shared.unregister(url: url) }

        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 0-1048575/1048605")
        XCTAssertEqual(data.count, 1 * 1_024 * 1_024)
        XCTAssertTrue(reader.requests.allSatisfy { request in
            guard let length = request.length else { return false }
            return length > 0 && length <= 1 * 1_024 * 1_024
        })
    }

    func testPlaybackServerCapsLargeExplicitRangeAndReportsDeliveredRange() async throws {
        let byteCount = UInt64(4 * 1_024 * 1_024)
        let reader = BoundedMediaReader(byteCount: byteCount)
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
            fileName: "large.mp4",
            mimeType: "video/mp4",
            byteCount: byteCount,
            reader: { offset, length in
                try reader.read(offset: offset, length: length)
            }
        )
        defer { RemoteFileOnlineMediaRegistry.shared.unregister(url: url) }
        var request = URLRequest(url: url)
        request.setValue("bytes=512-2097663", forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 206)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 512-1049087/4194304")
        XCTAssertEqual(data.count, 1 * 1_024 * 1_024)
        XCTAssertEqual(reader.requests.first?.offset, 512)
        XCTAssertTrue(reader.requests.allSatisfy { request in
            guard let length = request.length else { return false }
            return length > 0 && length <= 1 * 1_024 * 1_024
        })
    }

    func testStreamingServerServesCompleteLargeImageInBoundedChunks() async throws {
        let byteCount = UInt64(2 * 1_024 * 1_024 + 17)
        let reader = BoundedMediaReader(byteCount: byteCount)
        let url = try RemoteFileOnlineMediaRegistry.shared.registerForStreaming(
            fileName: "large-image.webp",
            mimeType: "image/webp",
            byteCount: byteCount,
            reader: { offset, length in
                try reader.read(offset: offset, length: length)
            }
        )
        defer { RemoteFileOnlineMediaRegistry.shared.unregister(url: url) }

        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.expectedContentLength, Int64(byteCount))
        XCTAssertEqual(data.count, Int(byteCount))
        XCTAssertGreaterThan(reader.requests.count, 1)
        XCTAssertTrue(reader.requests.allSatisfy { request in
            guard let length = request.length else { return false }
            return length > 0 && length <= 256 * 1_024
        })
        XCTAssertEqual(reader.requests.map(\.offset), stride(
            from: UInt64(0),
            to: byteCount,
            by: 256 * 1_024
        ).map { $0 })
    }
}

private final class MediaInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
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

private final class BoundedMediaReader: @unchecked Sendable {
    private let lock = NSLock()
    private let byteCount: UInt64
    private var recordedRequests: [(offset: UInt64, length: UInt64?)] = []

    init(byteCount: UInt64) {
        self.byteCount = byteCount
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

        guard let length else {
            return Data()
        }
        let available = offset < byteCount ? byteCount - offset : 0
        return Data(repeating: 0x5A, count: Int(min(length, available)))
    }
}

private final class BlockingBoundedMediaReader: @unchecked Sendable {
    private let lock = NSLock()
    private let byteCount: UInt64
    private let readStarted: DispatchSemaphore
    private let finishFirstRead: DispatchSemaphore
    private var recordedRequests: [(offset: UInt64, length: UInt64?)] = []

    init(
        byteCount: UInt64,
        readStarted: DispatchSemaphore,
        finishFirstRead: DispatchSemaphore
    ) {
        self.byteCount = byteCount
        self.readStarted = readStarted
        self.finishFirstRead = finishFirstRead
    }

    var requests: [(offset: UInt64, length: UInt64?)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func read(offset: UInt64, length: UInt64?) throws -> Data {
        lock.lock()
        recordedRequests.append((offset, length))
        let requestCount = recordedRequests.count
        lock.unlock()
        if requestCount == 1 {
            readStarted.signal()
            _ = finishFirstRead.wait(timeout: .now() + 1)
        }
        guard let length else { return Data() }
        let available = offset < byteCount ? byteCount - offset : 0
        return Data(repeating: 0x5A, count: Int(min(length, available)))
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
