import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class SavedSessionCredentialPromptPresenterTests: XCTestCase {
    func testCredentialPromptUsesCompactNativeLayout() throws {
        let controller = SavedSessionCredentialPromptViewController(
            request: SavedSessionCredentialPromptRequest(
                sessionID: "session_api",
                sessionName: "API",
                protocolName: "SSH",
                host: "172.16.10.250",
                account: "root@172.16.10.250",
                kind: .password,
                label: "API password"
            )
        )

        let view = controller.view
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.fittingSize.width, 440, accuracy: 1)
        XCTAssertLessThanOrEqual(view.fittingSize.height, 240)
        let icon = try XCTUnwrap(
            view.firstSubview(withIdentifier: "Stacio.CredentialPrompt.icon") as? NSImageView
        )
        XCTAssertLessThanOrEqual(icon.fittingSize.width, 36)
        XCTAssertLessThanOrEqual(icon.fittingSize.height, 36)
        XCTAssertNotNil(view.firstSubview(withIdentifier: "Stacio.CredentialPrompt.title"))
        XCTAssertNotNil(view.firstSubview(withIdentifier: "Stacio.CredentialPrompt.account"))
        let field = try XCTUnwrap(
            view.firstSubview(withIdentifier: "Stacio.CredentialPrompt.secret") as? NSSecureTextField
        )
        XCTAssertGreaterThanOrEqual(field.fittingSize.width, 300)
        let primary = try XCTUnwrap(
            view.firstSubview(withIdentifier: "Stacio.CredentialPrompt.primary") as? NSButton
        )
        let cancel = try XCTUnwrap(
            view.firstSubview(withIdentifier: "Stacio.CredentialPrompt.cancel") as? NSButton
        )
        XCTAssertLessThanOrEqual(primary.fittingSize.width, 150)
        XCTAssertLessThanOrEqual(cancel.fittingSize.width, 110)
        XCTAssertEqual(primary.keyEquivalent, "\r")
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
    }

    func testCredentialPromptPanelDoesNotMoveFromBlankContent() {
        let presenter = AppKitSavedSessionCredentialPromptPresenter()
        let controller = SavedSessionCredentialPromptViewController(
            request: SavedSessionCredentialPromptRequest(
                sessionID: "session_api",
                sessionName: "API",
                protocolName: "SSH",
                host: "172.16.10.250",
                account: "root@172.16.10.250",
                kind: .password,
                label: "API password"
            )
        )

        let panel = presenter.makePromptPanel(for: controller, parentWindow: nil)

        XCTAssertFalse(panel.isMovableByWindowBackground)
    }
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
