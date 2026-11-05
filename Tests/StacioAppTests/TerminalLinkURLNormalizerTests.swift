import XCTest
@testable import StacioApp

final class TerminalLinkURLNormalizerTests: XCTestCase {
    func testBarePublicDomainDefaultsToHTTPSLikeBrowserAddressBar() throws {
        let url = try XCTUnwrap(TerminalLinkURLNormalizer.browserURL(from: "docs.example.com/guide"))

        XCTAssertEqual(url.absoluteString, "https://docs.example.com/guide")
    }

    func testBareLocalAndPrivateAddressesKeepHTTP() throws {
        let localhostURL = try XCTUnwrap(TerminalLinkURLNormalizer.browserURL(from: "localhost:3000/status"))
        let privateURL = try XCTUnwrap(TerminalLinkURLNormalizer.browserURL(from: "10.8.4.12:8080/status"))

        XCTAssertEqual(localhostURL.absoluteString, "http://localhost:3000/status")
        XCTAssertEqual(privateURL.absoluteString, "http://10.8.4.12:8080/status")
    }

    func testRejectsCredentialedBrowserURLs() {
        XCTAssertNil(TerminalLinkURLNormalizer.browserURL(from: "https://admin:secret@example.com/dashboard"))
        XCTAssertNil(TerminalLinkURLNormalizer.browserURL(from: "http://token@example.com/status"))
    }

    func testRejectsHTTPURLsWithInvalidExplicitPorts() {
        XCTAssertNil(TerminalLinkURLNormalizer.browserURL(from: "https://example.com:99999/dashboard"))
        XCTAssertNil(TerminalLinkURLNormalizer.browserURL(from: "http://localhost:0/status"))
    }
}
