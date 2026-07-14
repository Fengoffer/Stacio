import Foundation
@testable import StacioApp
import XCTest

final class URLSessionAIAssistantHTTPTransportTests: XCTestCase {
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

    func testSynchronousPerformUsesConstructionFallbackWithoutPositiveRequestTimeout() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAIAssistantHTTPResponseURLProtocol.self]
        let transport = URLSessionAIAssistantHTTPTransport(
            configuration: configuration,
            timeout: 0.05
        )
        var request = URLRequest(
            url: URL(string: "https://transport-timeout.test/models")!
        )
        request.timeoutInterval = 0

        XCTAssertThrowsError(try transport.perform(request)) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .timeout)
        }
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
