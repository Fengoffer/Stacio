import AppKit
import XCTest
@testable import StacioApp

final class HostKeyConfirmationPresenterTests: XCTestCase {
    func testUnknownHostKeyAlertUsesExplicitTrustAndCancelActions() throws {
        let confirmation = HostKeyConfirmation(
            host: "example.com",
            port: 22,
            fingerprintSHA256: "SHA256:abc123",
            reason: .unknown
        )

        let alert = HostKeyConfirmationPresenter.makeAlert(for: confirmation)

        XCTAssertEqual(alert.messageText, "信任 example.com 的主机密钥？")
        XCTAssertTrue(alert.informativeText.contains("SHA256:abc123"))
        XCTAssertTrue(alert.informativeText.contains("主机：example.com:22"))
        XCTAssertEqual(alert.buttons.map(\.title), ["信任主机密钥", "取消"])
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertFalse(alert.informativeText.contains("ssh "))
        XCTAssertFalse(alert.informativeText.contains("secret"))
    }

    func testChangedHostKeyAlertUsesBlockingLanguage() throws {
        let confirmation = HostKeyConfirmation(
            host: "example.com",
            port: 2222,
            fingerprintSHA256: "SHA256:new",
            reason: .changed(previousFingerprintSHA256: "SHA256:old")
        )

        let alert = HostKeyConfirmationPresenter.makeAlert(for: confirmation)

        XCTAssertEqual(alert.messageText, "example.com 的主机密钥已变更")
        XCTAssertTrue(alert.informativeText.contains("SHA256:old"))
        XCTAssertTrue(alert.informativeText.contains("SHA256:new"))
        XCTAssertEqual(alert.buttons.map(\.title), ["拒绝连接", "信任新的主机密钥"])
        XCTAssertEqual(alert.alertStyle, .critical)
    }

    func testChangedHostKeyAlertOmitsBlankPreviousFingerprint() throws {
        let confirmation = HostKeyConfirmation(
            host: "example.com",
            port: 2222,
            fingerprintSHA256: "SHA256:new",
            reason: .changed(previousFingerprintSHA256: "")
        )

        let alert = HostKeyConfirmationPresenter.makeAlert(for: confirmation)

        XCTAssertFalse(alert.informativeText.contains("旧指纹："))
        XCTAssertTrue(alert.informativeText.contains("新指纹：SHA256:new"))
    }
}
