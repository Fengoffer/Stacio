import XCTest
import Foundation
@testable import StacioApp

/// P4-7：网络信任动作（changeNetworkTrust：revision 绑定、origin 规范化、HTTP 拒绝、证书展示、fingerprint）。
final class NetworkTrustActionTests: XCTestCase {

    // MARK: - revision + origin 绑定

    func testBindRequiresExactRevisionAndNormalizedOrigin() throws {
        let base = URL(string: "https://api.example.com:443/v1")!
        let binding = try NetworkTrustAction.bind(
            configurationRevision: 3, baseURL: base, currentRevision: 3
        ).get()
        XCTAssertEqual(binding.configurationRevision, 3)
        XCTAssertEqual(binding.normalizedOrigin, "https://api.example.com", "normalized origin（默认端口省略）")
    }

    func testBindRejectsRevisionMismatch() {
        let result = NetworkTrustAction.bind(
            configurationRevision: 2, baseURL: URL(string: "https://api.example.com/v1")!, currentRevision: 3
        )
        XCTAssertEqual(result, .failure(.revisionMismatch(expected: 2, actual: 3)))
    }

    // MARK: - 公网 HTTP 拒绝

    func testPublicHTTPRejectedButLoopbackAllowed() {
        XCTAssertFalse(NetworkTrustAction.allowsHTTP(origin: "http://api.example.com"), "公网 HTTP 拒绝")
        XCTAssertFalse(NetworkTrustAction.allowsHTTP(origin: "http://10.0.0.5"))
        XCTAssertTrue(NetworkTrustAction.allowsHTTP(origin: "http://localhost:11434"))
        XCTAssertTrue(NetworkTrustAction.allowsHTTP(origin: "http://127.0.0.1:11434"))
        XCTAssertTrue(NetworkTrustAction.allowsHTTP(origin: "http://[::1]:11434"))
    }

    // MARK: - verification fingerprint 失效

    func testFingerprintMismatchInvalidatesTrust() {
        XCTAssertTrue(NetworkTrustAction.fingerprintValid(expected: "abc123", actual: "abc123"))
        XCTAssertFalse(
            NetworkTrustAction.fingerprintValid(expected: "abc123", actual: "def456"),
            "verification fingerprint 失效 → 拒绝信任"
        )
    }

    // MARK: - CA 展示

    func testCertificateDisplayFields() {
        let certificate = CertificateSummary(
            subject: "CN=api.example.com", issuer: "CN=Example Root CA",
            sanHosts: ["api.example.com"], fingerprintSHA256: "sha256:abc"
        )
        XCTAssertEqual(NetworkTrustAction.displayFields(certificate: certificate), [
            "subject:CN=api.example.com",
            "issuer:CN=Example Root CA",
            "san:api.example.com",
            "fingerprint:sha256:abc"
        ])
    }

    // MARK: - 绝不提供跳过校验

    func testSkipVerificationNeverOffered() {
        XCTAssertFalse(NetworkTrustAction.skipCertificateVerificationOffered(), "绝不提供跳过证书链/主机名校验")
    }
}
