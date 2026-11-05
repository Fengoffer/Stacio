import XCTest
@testable import StacioApp

final class BrowserURLNormalizerTests: XCTestCase {
    func testPrivateIPv4HostPortDefaultsToHTTP() throws {
        let url = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("10.8.4.12:8080/status"))

        XCTAssertEqual(url.absoluteString, "http://10.8.4.12:8080/status")
    }

    func testPrivateIPv4HostWithoutPortDefaultsToHTTP() throws {
        let url = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("192.168.1.1/admin"))

        XCTAssertEqual(url.absoluteString, "http://192.168.1.1/admin")
    }

    func testPrivateIPv6HostPortDefaultsToHTTP() throws {
        let url = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("[fd00::12]:8080/status"))

        XCTAssertEqual(url.absoluteString, "http://[fd00::12]:8080/status")
    }

    func testPrivateIPv6HostWithoutPortDefaultsToHTTP() throws {
        let url = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("[fd00::12]/status"))

        XCTAssertEqual(url.absoluteString, "http://[fd00::12]/status")
    }

    func testPublicHostPortStillDefaultsToHTTPS() throws {
        let url = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("example.com:8443/admin"))

        XCTAssertEqual(url.absoluteString, "https://example.com:8443/admin")
    }

    func testSchemeRelativeURLUsesDefaultBrowserScheme() throws {
        let publicURL = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("//example.com/dashboard"))
        let privateURL = try XCTUnwrap(BrowserURLNormalizer.normalizedURL("//192.168.1.1/admin"))

        XCTAssertEqual(publicURL.absoluteString, "https://example.com/dashboard")
        XCTAssertEqual(privateURL.absoluteString, "http://192.168.1.1/admin")
    }

    func testRejectsCredentialedSchemeRelativeURL() {
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("//admin:secret@example.com/dashboard"))
    }

    func testRejectsCredentialedHTTPURL() {
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("https://admin:secret@example.com/dashboard"))
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("http://token@example.com/status"))
    }

    func testRejectsInvalidPortNumbers() {
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("https://example.com:99999/dashboard"))
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("example.com:99999/dashboard"))
    }

    func testRejectsWhitespaceAndControlCharactersInsideURLInput() {
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("https://exa mple.com/dashboard"))
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("exa mple.com/dashboard"))
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("example.com\n.evil/path"))
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("https://example.com\t.evil/status"))
        XCTAssertNil(BrowserURLNormalizer.normalizedURL("example.com\t.evil/status"))
    }

    func testLoopbackTransportURLForcesProxyWithoutChangingDisplayedAddress() throws {
        let displayURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/status?full=1"))

        let transportURL = BrowserURLNormalizer.transportURL(for: displayURL)

        XCTAssertEqual(
            transportURL.absoluteString,
            "http://stacio-ipv4-127-0-0-1-x.invalid:8080/status?full=1"
        )
        XCTAssertEqual(BrowserURLNormalizer.displayURL(for: transportURL), displayURL)
    }

    func testLocalhostTransportURLUsesRemoteResolvableRootLabel() throws {
        let displayURL = try XCTUnwrap(URL(string: "http://localhost/admin"))

        XCTAssertEqual(
            BrowserURLNormalizer.transportURL(for: displayURL).absoluteString,
            "http://stacio-host-localhost-x.invalid/admin"
        )
    }

    func testNonLoopbackTransportURLIsUnchanged() throws {
        let publicURL = try XCTUnwrap(URL(string: "https://example.com/"))

        XCTAssertEqual(BrowserURLNormalizer.transportURL(for: publicURL), publicURL)
    }

    func testPrivateIPv4TransportURLForcesRemoteProxyResolution() throws {
        let displayURL = try XCTUnwrap(URL(string: "http://192.168.1.20:8080/status"))

        let transportURL = BrowserURLNormalizer.transportURL(for: displayURL)

        XCTAssertEqual(
            transportURL.absoluteString,
            "http://stacio-ipv4-192-168-1-20-x.invalid:8080/status"
        )
        XCTAssertEqual(BrowserURLNormalizer.displayURL(for: transportURL), displayURL)
    }

    func testIPv6TransportURLUsesReversibleProxyHostname() throws {
        let displayURL = try XCTUnwrap(URL(string: "http://[::1]:8080/status"))

        let transportURL = BrowserURLNormalizer.transportURL(for: displayURL)

        XCTAssertEqual(
            transportURL.absoluteString,
            "http://stacio-ipv6---1-x.invalid:8080/status"
        )
        XCTAssertEqual(BrowserURLNormalizer.displayURL(for: transportURL), displayURL)
    }
}
