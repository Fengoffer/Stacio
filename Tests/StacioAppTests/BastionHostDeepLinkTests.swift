import XCTest
import CryptoKit
@testable import StacioApp

final class BastionHostDeepLinkTests: XCTestCase {
    func testParsesVersionOneSSHRequest() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let request = makeRequest(expiresAt: now.addingTimeInterval(60))
        let parsed = try BastionHostDeepLinkParser.parse(makeURL(request), now: now)
        XCTAssertEqual(parsed, request)
    }

    func testRejectsExpiredRequest() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertThrowsError(
            try BastionHostDeepLinkParser.parse(
                makeURL(makeRequest(expiresAt: now.addingTimeInterval(-1))),
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? BastionHostDeepLinkError, .expired)
        }
    }

    func testRejectsSensitiveOrExecutableQueryParameters() {
        let request = makeRequest(expiresAt: Date().addingTimeInterval(60))
        let unsafeURL = URL(string: makeURL(request).absoluteString + "&command=whoami")!
        XCTAssertThrowsError(try BastionHostDeepLinkParser.parse(unsafeURL)) { error in
            XCTAssertEqual(error as? BastionHostDeepLinkError, .unsafeParameter)
        }
    }

    func testRejectsUnsupportedProtocol() {
        let request = BastionHostDeepLinkRequest(
            version: 1,
            vendor: "example",
            protocolName: "rdp",
            gatewayHost: "bastion.example.com",
            gatewayPort: 60022,
            gatewayUsername: "SSH@ops@asset",
            targetHost: nil,
            targetPort: nil,
            targetUsername: nil,
            assetID: nil,
            accountID: nil,
            requestID: "req-1",
            nonce: "nonce-1",
            expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertThrowsError(try BastionHostDeepLinkParser.parse(makeURL(request))) { error in
            XCTAssertEqual(error as? BastionHostDeepLinkError, .unsupportedProtocol)
        }
    }

    func testRejectsRequestWhoseValidityWindowExceedsFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let request = makeRequest(
            expiresAt: now.addingTimeInterval(BastionHostDeepLinkParser.maximumValidityInterval + 1)
        )
        XCTAssertThrowsError(try BastionHostDeepLinkParser.parse(makeURL(request), now: now)) { error in
            XCTAssertEqual(error as? BastionHostDeepLinkError, .validityTooLong)
        }
    }

    func testReplayProtectorRejectsSameVendorRequestAndNonceUntilExpiry() throws {
        let suiteName = "BastionHostReplayTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let protector = UserDefaultsBastionHostRequestReplayProtector(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let request = makeRequest(expiresAt: now.addingTimeInterval(60))

        try protector.consume(request, now: now)

        XCTAssertThrowsError(try protector.consume(request, now: now)) { error in
            XCTAssertEqual(error as? BastionHostDeepLinkError, .replayed)
        }
        XCTAssertNoThrow(try protector.consume(request, now: now.addingTimeInterval(61)))
    }

    func testConfiguredVendorRequiresValidEd25519Signature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = BundleBastionHostDeepLinkSignatureVerifier(publicKeys: [
            "example": privateKey.publicKey.rawRepresentation.base64EncodedString()
        ])
        let request = makeRequest(expiresAt: Date().addingTimeInterval(60))
        let unsignedURL = makeURL(request)

        XCTAssertThrowsError(
            try BastionHostDeepLinkParser.parse(unsignedURL, signatureVerifier: verifier)
        ) { error in
            XCTAssertEqual(error as? BastionHostDeepLinkError, .signatureRequired)
        }

        let payload = try XCTUnwrap(URLComponents(url: unsignedURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "payload" })?.value)
        let payloadData = try XCTUnwrap(base64URLData(payload))
        let signature = try privateKey.signature(for: payloadData).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = try XCTUnwrap(URLComponents(url: unsignedURL, resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "signature", value: signature))

        XCTAssertNoThrow(
            try BastionHostDeepLinkParser.parse(
                try XCTUnwrap(components.url),
                signatureVerifier: verifier
            )
        )
    }

    private func makeRequest(expiresAt: Date) -> BastionHostDeepLinkRequest {
        BastionHostDeepLinkRequest(
            version: 1,
            vendor: "example",
            protocolName: "ssh",
            gatewayHost: "bastion.example.com",
            gatewayPort: 60022,
            gatewayUsername: "SSH@ops@10.0.0.8",
            targetHost: "10.0.0.8",
            targetPort: 22,
            targetUsername: "ops",
            assetID: "asset-1",
            accountID: "account-1",
            requestID: "req-1",
            nonce: "nonce-1",
            expiresAt: expiresAt
        )
    }

    private func makeURL(_ request: BastionHostDeepLinkRequest) -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(request)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: "stacio://connect")!
        components.queryItems = [URLQueryItem(name: "payload", value: payload)]
        return components.url!
    }

    private func base64URLData(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
