import Foundation
@testable import StacioApp
import XCTest

final class AIEndpointSecurityPolicyTests: XCTestCase {
    func testValidateAllowsHTTPSForRemoteAndPrivateHosts() throws {
        for rawURL in [
            "https://api.example.com/v1",
            "https://192.168.1.20:11434/v1",
            "https://[fd00::10]:11434/v1"
        ] {
            try AIEndpointSecurityPolicy.validate(try XCTUnwrap(URL(string: rawURL)))
        }
    }

    func testValidateRejectsHTTPSWithoutAHost() throws {
        let url = try XCTUnwrap(URL(string: "https:///v1"))

        XCTAssertThrowsError(try AIEndpointSecurityPolicy.validate(url)) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
        }
    }

    func testValidateAllowsLocalhostAndSubdomainsOverHTTP() throws {
        for rawURL in [
            "http://localhost:11434/v1",
            "http://LOCALHOST:11434/v1",
            "http://models.localhost:11434/v1",
            "http://nested.models.localhost:11434/v1"
        ] {
            try AIEndpointSecurityPolicy.validate(try XCTUnwrap(URL(string: rawURL)))
        }
    }

    func testValidateAllowsStrictIPv4LoopbackRangeOverHTTP() throws {
        for rawURL in [
            "http://127.0.0.1:11434/v1",
            "http://127.12.34.56:11434/v1",
            "http://127.255.255.255:11434/v1"
        ] {
            try AIEndpointSecurityPolicy.validate(try XCTUnwrap(URL(string: rawURL)))
        }
    }

    func testValidateAllowsIPv6LoopbackFormsOverHTTP() throws {
        for rawURL in [
            "http://[::1]:11434/v1",
            "http://[0:0:0:0:0:0:0:1]:11434/v1",
            "http://[0000:0000:0000:0000:0000:0000:0000:0001]:11434/v1"
        ] {
            try AIEndpointSecurityPolicy.validate(try XCTUnwrap(URL(string: rawURL)))
        }
    }

    func testValidateRejectsNonLoopbackHTTPHosts() throws {
        let rejectedURLs = [
            "http://0.0.0.0:11434/v1",
            "http://models.local:11434/v1",
            "http://10.0.0.5:11434/v1",
            "http://172.16.0.5:11434/v1",
            "http://172.31.255.254:11434/v1",
            "http://192.168.1.20:11434/v1",
            "http://[fc00::10]:11434/v1",
            "http://[fd00::10]:11434/v1",
            "http://[fe80::1]:11434/v1",
            "http://api.example.com/v1",
            "http://127.0.0.999:11434/v1",
            "http://127.1:11434/v1",
            "http://127.0.0.1.example.com/v1"
        ]

        for rawURL in rejectedURLs {
            XCTAssertThrowsError(
                try AIEndpointSecurityPolicy.validate(try XCTUnwrap(URL(string: rawURL))),
                rawURL
            ) { error in
                XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL, rawURL)
            }
        }
    }

    func testNormalizedBaseURLDefaultsOnlyLoopbackHostsToHTTP() throws {
        let expectations: [(rawValue: String, absoluteString: String)] = [
            ("localhost:11434/v1", "http://localhost:11434/v1"),
            ("models.localhost:11434/v1", "http://models.localhost:11434/v1"),
            ("127.42.0.9:11434/v1", "http://127.42.0.9:11434/v1"),
            ("[::1]:11434/v1", "http://[::1]:11434/v1"),
            ("0.0.0.0:11434/v1", "https://0.0.0.0:11434/v1"),
            ("models.local:11434/v1", "https://models.local:11434/v1"),
            ("10.0.0.5:11434/v1", "https://10.0.0.5:11434/v1"),
            ("172.31.0.5:11434/v1", "https://172.31.0.5:11434/v1"),
            ("192.168.1.20:11434/v1", "https://192.168.1.20:11434/v1"),
            ("[fd00::10]:11434/v1", "https://[fd00::10]:11434/v1"),
            ("[fe80::1]:11434/v1", "https://[fe80::1]:11434/v1"),
            ("api.example.com/v1", "https://api.example.com/v1")
        ]

        for expectation in expectations {
            XCTAssertEqual(
                OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: expectation.rawValue)?.absoluteString,
                expectation.absoluteString,
                expectation.rawValue
            )
        }
    }

    func testNormalizedBaseURLPreservesValidationAndCleaningRules() throws {
        XCTAssertNil(OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: "https://user@example.com/v1"))
        XCTAssertNil(OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: "https://example.com:99999/v1"))
        XCTAssertNil(OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: "https://example.com/v 1"))
        XCTAssertEqual(
            OpenAICompatibleAIAssistantProvider.normalizedBaseURL(
                from: "  HTTPS://API.EXAMPLE.COM:8443/v1///?debug=true#section  "
            )?.absoluteString,
            "https://API.EXAMPLE.COM:8443/v1"
        )
    }

    func testRemoteHTTPWithAndWithoutKeyIsRejectedBeforeSynchronousTransport() throws {
        for apiKey in [nil, "sk-test-secret"] as [String?] {
            let transport = SecurityPolicyRecordingTransport()
            let provider = OpenAICompatibleAIAssistantProvider(
                baseURL: try XCTUnwrap(URL(string: "http://api.example.com/v1")),
                model: "ops-model",
                apiKeyProvider: { apiKey },
                transport: transport
            )

            XCTAssertThrowsError(try provider.respond(to: makeSecurityPolicyAIRequest())) { error in
                XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
            }
            XCTAssertEqual(transport.requestCount, 0)
            XCTAssertEqual(transport.streamRequestCount, 0)
        }
    }

    func testRemoteHTTPIsRejectedBeforeStreamingTransport() async throws {
        let transport = SecurityPolicyRecordingTransport()
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "http://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { nil },
            transport: transport
        )

        do {
            _ = try await provider.respondStreaming(to: makeSecurityPolicyAIRequest(), onPartial: { _ in })
            XCTFail("expected insecure Base URL")
        } catch {
            XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
        }
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(transport.streamRequestCount, 0)
    }

    func testInsecureBaseURLErrorNoLongerClaimsPrivateLANHTTPIsAllowed() {
        let message = AIAssistantProviderError.insecureBaseURL.errorDescription ?? ""

        XCTAssertTrue(message.contains("HTTPS"))
        XCTAssertTrue(message.contains("本机"))
        XCTAssertFalse(message.contains("内网"))
    }

    func testSynchronousTransportRejectsRedirectBeforeSensitiveTargetRequest() throws {
        let fixture = makeRedirectFixture()

        let (_, response) = try fixture.transport.perform(fixture.request)

        XCTAssertEqual(response.statusCode, 307)
        assertRedirectTargetWasNotReached(token: fixture.token)
    }

    func testAsynchronousTransportRejectsRedirectBeforeSensitiveTargetRequest() async throws {
        let fixture = makeRedirectFixture()

        let (_, response) = try await fixture.transport.performAsync(fixture.request)

        XCTAssertEqual(response.statusCode, 307)
        assertRedirectTargetWasNotReached(token: fixture.token)
    }

    func testStreamingTransportRejectsRedirectBeforeSensitiveTargetRequest() async throws {
        let fixture = makeRedirectFixture()

        do {
            _ = try await fixture.transport.stream(fixture.request, onChunk: { _ in })
            XCTFail("expected redirect response to be rejected")
        } catch {
            XCTAssertEqual(error as? AIAssistantProviderError, .httpStatus(307))
        }
        assertRedirectTargetWasNotReached(token: fixture.token)
    }

    private func makeRedirectFixture() -> (
        token: String,
        transport: URLSessionAIAssistantHTTPTransport,
        request: URLRequest
    ) {
        let token = UUID().uuidString.lowercased()
        let authorization = "Bearer redirect-secret-\(token)"
        let body = Data("redirect-body-\(token)".utf8)
        RedirectRecordingURLProtocol.register(
            token: token,
            authorization: authorization,
            body: body
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectRecordingURLProtocol.self]
        let transport = URLSessionAIAssistantHTTPTransport(
            configuration: configuration,
            timeout: 2
        )
        var request = URLRequest(
            url: URL(string: "https://localhost/\(token)/start")!
        )
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return (token, transport, request)
    }

    private func assertRedirectTargetWasNotReached(
        token: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let targetRequests = RedirectRecordingURLProtocol.targetRequests(for: token)
        XCTAssertEqual(targetRequests.count, 0, file: file, line: line)
        XCTAssertTrue(
            targetRequests.allSatisfy { $0.authorization == nil },
            file: file,
            line: line
        )
        XCTAssertTrue(
            targetRequests.allSatisfy { $0.body == nil },
            file: file,
            line: line
        )
    }
}

private final class SecurityPolicyRecordingTransport: AIAssistantHTTPTransport {
    private(set) var requestCount = 0
    private(set) var streamRequestCount = 0

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        throw AIAssistantProviderError.invalidResponse
    }

    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        streamRequestCount += 1
        throw AIAssistantProviderError.invalidResponse
    }
}

private func makeSecurityPolicyAIRequest() -> AIAssistantRequest {
    AIAssistantRequest(
        question: "Test connection",
        context: AITerminalContext(
            runtimeID: "security-policy-test",
            title: "Security policy test",
            currentDirectory: nil,
            recentTranscript: ""
        )
    )
}

private final class RedirectRecordingURLProtocol: URLProtocol {
    struct CapturedRequest {
        let authorization: String?
        let body: Data?
    }

    private struct Fixture {
        let authorization: String
        let body: Data
        var targetRequests: [CapturedRequest]
    }

    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]

    static func register(token: String, authorization: String, body: Data) {
        lock.lock()
        fixtures[token] = Fixture(
            authorization: authorization,
            body: body,
            targetRequests: []
        )
        lock.unlock()
    }

    static func targetRequests(for token: String) -> [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[token]?.targetRequests ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost" || request.url?.host == "192.168.1.20"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let token = url.pathComponents.dropFirst().first
        else {
            client?.urlProtocol(self, didFailWithError: AIAssistantProviderError.invalidResponse)
            return
        }

        if url.host == "localhost" {
            guard let fixture = Self.fixture(for: token),
                  let targetURL = URL(string: "http://192.168.1.20/\(token)/target"),
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 307,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": targetURL.absoluteString]
                  )
            else {
                client?.urlProtocol(self, didFailWithError: AIAssistantProviderError.invalidResponse)
                return
            }
            var redirectRequest = request
            redirectRequest.url = targetURL
            redirectRequest.setValue(fixture.authorization, forHTTPHeaderField: "Authorization")
            redirectRequest.httpBody = fixture.body
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirectRequest,
                redirectResponse: response
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.recordTargetRequest(request, token: token)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: AIAssistantProviderError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"target":"reached"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func fixture(for token: String) -> Fixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[token]
    }

    private static func recordTargetRequest(_ request: URLRequest, token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var fixture = fixtures[token] else {
            return
        }
        fixture.targetRequests.append(
            CapturedRequest(
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: request.httpBody
            )
        )
        fixtures[token] = fixture
    }
}
