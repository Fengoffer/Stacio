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
}
