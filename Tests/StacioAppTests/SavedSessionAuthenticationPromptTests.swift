import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class SavedSessionAuthenticationPromptTests: XCTestCase {
    func testPromptFieldsAreEditableAndConnectProducesCredentials() {
        let controller = SavedSessionAuthenticationPromptViewController(
            host: "172.16.10.250",
            initialUsername: nil
        )
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.usernameField.isEditable)
        XCTAssertTrue(controller.usernameField.isEnabled)
        XCTAssertTrue(controller.passwordField.isEditable)
        XCTAssertTrue(controller.passwordField.isEnabled)
        XCTAssertEqual(controller.usernameField.accessibilityIdentifier(), "Stacio.SessionAuthentication.username")
        XCTAssertEqual(controller.passwordField.accessibilityIdentifier(), "Stacio.SessionAuthentication.password")

        var response: NSApplication.ModalResponse?
        controller.onFinish = { response = $0 }
        controller.usernameField.stringValue = "admin"
        controller.passwordField.stringValue = "secret"
        controller.connectPressedForTesting()

        XCTAssertEqual(response, .OK)
        XCTAssertEqual(controller.result, SavedSessionAuthenticationInput(username: "admin", password: "secret"))
    }

    func testPromptPanelUsesStableContentWidth() {
        let controller = SavedSessionAuthenticationPromptViewController(
            host: "172.16.10.250",
            initialUsername: "admin"
        )
        controller.loadViewIfNeeded()
        let panel = controller.makePanel(parentWindow: nil)
        defer { panel.close() }

        XCTAssertEqual(panel.frame.width, 440, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 280, accuracy: 1)
    }
}
