import Foundation
@testable import StacioApp
import XCTest

final class URLSessionAIAssistantHTTPTransportTests: XCTestCase {
    func testStreamChunkBufferFlushesShortSSELineImmediately() {
        var buffer = AIAssistantStreamChunkBuffer()
        var chunks: [Data] = []

        for byte in Data("data: first token\n".utf8) {
            if let chunk = buffer.append(byte) {
                chunks.append(chunk)
            }
        }

        XCTAssertEqual(chunks, [Data("data: first token\n".utf8)])
        XCTAssertNil(buffer.finish())
    }

    func testStreamChunkBufferFlushesUnterminatedTailWhenStreamFinishes() {
        var buffer = AIAssistantStreamChunkBuffer()

        for byte in Data("data: final token".utf8) {
            XCTAssertNil(buffer.append(byte))
        }

        XCTAssertEqual(buffer.finish(), Data("data: final token".utf8))
        XCTAssertNil(buffer.finish())
    }

    func testSynchronousPerformUsesRequestTimeoutInsteadOfConstructionFallback() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAIAssistantHTTPResponseURLProtocol.self]
        let transport = URLSessionAIAssistantHTTPTransport(
            configuration: configuration,
            timeout: 0.05
        )
        var request = URLRequest(
            url: URL(string: "https://transport-timeout.test/models")!
        )
        request.timeoutInterval = 1

        let (data, response) = try transport.perform(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{}".utf8))
    }

    func testSynchronousPerformTimesOutWhenRequestTimeoutExpires() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAIAssistantHTTPResponseURLProtocol.self]
        let transport = URLSessionAIAssistantHTTPTransport(
            configuration: configuration,
            timeout: 1
        )
        var request = URLRequest(
            url: URL(string: "https://transport-timeout.test/models")!
        )
        request.timeoutInterval = 0.05

        XCTAssertThrowsError(try transport.perform(request)) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .timeout)
        }
    }

    func testStreamingTransportReturnsNonSuccessBodyToProvider() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForbiddenAIAssistantHTTPResponseURLProtocol.self]
        let transport = URLSessionAIAssistantHTTPTransport(configuration: configuration)
        let request = URLRequest(
            url: URL(string: "https://transport-forbidden.test/chat/completions")!
        )
        var received = Data()

        let response = try await transport.stream(request) { chunk in
            received.append(chunk)
        }

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertEqual(
            String(data: received, encoding: .utf8),
            #"{"error":{"message":"policy denied"}}"#
        )
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Request-ID"), "req-403")
    }
}

private final class DelayedAIAssistantHTTPResponseURLProtocol: URLProtocol {
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "transport-timeout.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.isStopped == false,
                  let url = self.request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("{}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class ForbiddenAIAssistantHTTPResponseURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "transport-forbidden.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 403,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": "application/json",
                      "X-Request-ID": "req-403"
                  ]
              )
        else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"error":{"message":"policy denied"}}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
