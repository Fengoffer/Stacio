import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class BrowserPaneViewControllerTests: XCTestCase {
    func testInvalidAddressRestoresCurrentAddressWithoutRecordingNavigation() throws {
        let initialURL = try XCTUnwrap(URL(string: "https://example.com/dashboard"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()

        pane.loadAddressForTesting("https://exa mple.com/dashboard")

        XCTAssertEqual(pane.currentURLStringForTesting, initialURL.absoluteString)
        XCTAssertEqual(pane.addressFieldValueForTesting, initialURL.absoluteString)
        XCTAssertEqual(pane.navigationActionsForTesting, [])
        XCTAssertEqual(pane.statusTextForTesting, "载入失败：地址无效")
    }

    func testToolbarKeepsAddressFieldWiderThanStatusMessage() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-layout-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 920, height: 560)
        pane.showErrorForTesting("无法打开页面")
        pane.view.layoutSubtreeIfNeeded()

        let addressField = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.address") as? NSTextField
        )
        let statusLabel = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.status") as? NSTextField
        )
        let addressFrame = addressField.convert(addressField.bounds, to: pane.view)
        let statusFrame = statusLabel.convert(statusLabel.bounds, to: pane.view)

        XCTAssertGreaterThanOrEqual(
            addressFrame.width,
            420,
            "The browser address field should keep the primary horizontal space in a normal inspector width."
        )
        XCTAssertLessThanOrEqual(
            statusFrame.width,
            172,
            "The transient browser status message should cap its width instead of shortening the address field."
        )
        XCTAssertGreaterThan(
            addressFrame.width,
            statusFrame.width * 2,
            "The address field should be visibly wider than the status message."
        )
        XCTAssertEqual(statusLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(statusLabel.toolTip, "载入失败：无法打开页面")
    }

    func testToolbarSeparatesAddressFieldBottomFromWebContent() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-vertical-layout-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 920, height: 560)
        pane.view.layoutSubtreeIfNeeded()

        let addressField = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.address") as? NSTextField
        )
        let separator = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.toolbarSeparator")
        )
        let addressFrame = addressField.convert(addressField.bounds, to: pane.view)
        let separatorFrame = separator.convert(separator.bounds, to: pane.view)
        let webViewFrame = pane.webView.convert(pane.webView.bounds, to: pane.view)

        XCTAssertGreaterThanOrEqual(
            addressFrame.minY - separatorFrame.maxY,
            8,
            "The browser address field should keep visible bottom breathing room before the web content begins."
        )
        XCTAssertLessThanOrEqual(
            webViewFrame.maxY,
            separatorFrame.maxY + 1,
            "The web content should not extend above the toolbar separator into the address field area."
        )
        XCTAssertGreaterThanOrEqual(
            webViewFrame.maxY,
            separatorFrame.minY - 1,
            "The web content should still begin immediately below the toolbar separator without introducing a large blank band."
        )
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
