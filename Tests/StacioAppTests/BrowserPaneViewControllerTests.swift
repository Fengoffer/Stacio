import AppKit
import Network
import WebKit
import XCTest
@testable import StacioApp

@MainActor
final class BrowserPaneViewControllerTests: XCTestCase {
    func testPageTitleAndFaviconUpdateAppPresentationWithStableFallback() {
        let pane = BrowserPaneViewController(
            runtimeID: "browser_metadata",
            url: URL(string: "https://example.com")!,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()
        let favicon = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl6sAAAAASUVORK5CYII="

        pane.updatePagePresentationForTesting(title: "  Operations  ", faviconDataURL: favicon)

        XCTAssertEqual(pane.title, "Operations")
        XCTAssertNotNil(pane.faviconImageForTesting)

        pane.updatePagePresentationForTesting(title: "  ", faviconDataURL: nil)

        XCTAssertEqual(pane.title, "Browser")
        XCTAssertNotNil(pane.faviconImageForTesting)
    }

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

    func testToolbarKeepsAddressAndLoadingIndicatorInlineInNarrowInspector() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-layout-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 360, height: 560)
        pane.setLoadingStateForTesting(isLoading: true)
        pane.view.layoutSubtreeIfNeeded()

        let addressField = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.address") as? NSTextField
        )
        let statusIndicator = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.statusIndicator") as? NSProgressIndicator
        )
        let addressFrame = addressField.convert(addressField.bounds, to: pane.view)
        let indicatorFrame = statusIndicator.convert(statusIndicator.bounds, to: pane.view)

        XCTAssertGreaterThanOrEqual(
            addressFrame.width,
            120,
            "The browser address field should remain usable in a narrow inspector."
        )
        XCTAssertGreaterThanOrEqual(addressFrame.minX, pane.view.bounds.minX)
        XCTAssertLessThanOrEqual(addressFrame.maxX, pane.view.bounds.maxX)
        XCTAssertGreaterThanOrEqual(indicatorFrame.minX, addressFrame.maxX)
        XCTAssertLessThanOrEqual(indicatorFrame.minX - addressFrame.maxX, 8)
        XCTAssertEqual(indicatorFrame.midY, addressFrame.midY, accuracy: 1)
        XCTAssertNil(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.status"),
            "Loading status should be represented only by the inline spinner."
        )
    }

    func testSOCKSFallbackShowsModeBadgeWithoutMovingSpinnerAwayFromAddress() throws {
        let pane = BrowserPaneViewController(
            runtimeID: "browser-mode-test",
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/")),
            title: "Browser",
            loadsInitialRequest: false,
            modeLabel: "SSH 代理"
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        pane.setLoadingStateForTesting(isLoading: true)
        pane.view.layoutSubtreeIfNeeded()

        let address = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.address") as? NSTextField
        )
        let indicator = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.statusIndicator") as? NSProgressIndicator
        )
        let mode = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.mode") as? NSTextField
        )
        let addressFrame = address.convert(address.bounds, to: pane.view)
        let indicatorFrame = indicator.convert(indicator.bounds, to: pane.view)
        let modeFrame = mode.convert(mode.bounds, to: pane.view)

        XCTAssertEqual(mode.stringValue, "SSH 代理")
        XCTAssertGreaterThanOrEqual(indicatorFrame.minX, addressFrame.maxX)
        XCTAssertLessThanOrEqual(indicatorFrame.minX - addressFrame.maxX, 8)
        XCTAssertEqual(addressFrame.height, 28, accuracy: 0.1)
        XCTAssertTrue(mode is RemoteBrowserModeLabel)
        XCTAssertLessThan(mode.frame.width, 160)
        XCTAssertNil(mode.layer?.backgroundColor)

        let toolbarButtons = pane.view.allDescendants
            .compactMap { $0 as? NSButton }
            .filter {
                ["后退", "前进", "重新载入", L10n.Browser.go, "打开下载目录"].contains($0.toolTip ?? "")
            }
        XCTAssertEqual(toolbarButtons.count, 5)
        for button in toolbarButtons {
            XCTAssertEqual(button.frame.width, 28, accuracy: 0.1)
            XCTAssertEqual(button.frame.height, 28, accuracy: 0.1)
        }
        let toolbar = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.toolbar")
        )
        XCTAssertEqual(toolbar.frame.height, 36, accuracy: 0.1)
        XCTAssertEqual(modeFrame.midY, addressFrame.midY, accuracy: 0.1)
    }

    func testModeBadgeYieldsToolbarSpaceInNarrowInspector() throws {
        let pane = BrowserPaneViewController(
            runtimeID: "browser-narrow-mode-test",
            url: try XCTUnwrap(URL(string: "http://127.0.0.1/")),
            title: "Browser",
            loadsInitialRequest: false,
            modeLabel: "SSH 代理"
        )
        pane.loadView()
        pane.view.frame = NSRect(x: 0, y: 0, width: 360, height: 560)
        pane.view.layoutSubtreeIfNeeded()

        let address = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.address") as? NSTextField
        )
        let mode = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.mode") as? NSTextField
        )
        let addressFrame = address.convert(address.bounds, to: pane.view)

        XCTAssertTrue(mode.isHidden, "The non-essential mode badge must yield space to the address field in a narrow inspector.")
        XCTAssertGreaterThanOrEqual(addressFrame.width, 80)
    }

    func testNavigationLoadingKeepsWebContentVisible() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-progressive-rendering-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()
        let overlay = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.stateOverlay")
        )
        XCTAssertFalse(overlay.isHidden, "The proxy connection wait should remain visible.")

        pane.webView(pane.webView, didStartProvisionalNavigation: nil)

        XCTAssertTrue(
            overlay.isHidden,
            "A page navigation must leave WKWebView visible so WebKit can present content progressively."
        )
    }

    func testCommittedNavigationReleasesAnyRemainingConnectionOverlay() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-commit-rendering-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()
        let overlay = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.stateOverlay")
        )
        let selector = #selector(WKNavigationDelegate.webView(_:didCommit:))

        XCTAssertTrue(
            pane.responds(to: selector),
            "The browser must react when WebKit commits its first response."
        )
        guard pane.responds(to: selector) else { return }

        _ = pane.perform(selector, with: pane.webView, with: nil)

        XCTAssertTrue(
            overlay.isHidden,
            "Committed web content must be visible without switching tabs."
        )
    }

    func testSocksProxyMatchesAllDestinationsWithoutLocalFailover() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 18080)
        let pane = BrowserPaneViewController(
            runtimeID: "browser-proxy-test",
            url: initialURL,
            title: "Browser",
            socksProxyEndpoint: endpoint,
            loadsInitialRequest: false
        )

        pane.loadView()

        XCTAssertEqual(pane.proxyConfigurationCountForTesting, 1)
        XCTAssertEqual(pane.proxyMatchDomainsForTesting, ["."])
        XCTAssertEqual(pane.proxyAllowsFailoverForTesting, false)
    }

    func testSocksProxyActuallyCarriesWebViewNavigation() async throws {
        let fixture = try BrowserSOCKS5Fixture()
        fixture.start()
        defer { fixture.stop() }
        await fulfillment(of: [fixture.readyExpectation], timeout: 3)

        let proxyPort = try XCTUnwrap(fixture.port)
        let targetURL = try XCTUnwrap(URL(string: "http://stacio-browser-proxy-check.invalid/ready"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-proxy-integration-test",
            url: targetURL,
            title: "Browser",
            socksProxyEndpoint: .hostPort(host: "127.0.0.1", port: proxyPort),
            loadsInitialRequest: false
        )
        pane.loadView()
        let navigationObserver = BrowserNavigationObserver()
        pane.webView.navigationDelegate = navigationObserver

        pane.webView.load(URLRequest(url: targetURL))

        await fulfillment(
            of: [fixture.requestExpectation, navigationObserver.completedExpectation],
            timeout: 8
        )
        XCTAssertNil(navigationObserver.error)
        XCTAssertTrue(navigationObserver.didFinish)
        XCTAssertEqual(fixture.requestedHost, "stacio-browser-proxy-check.invalid")
        XCTAssertEqual(fixture.requestedPort, 80)
    }

    func testDownloadDestinationUsesDownloadsDirectoryAndAvoidsOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("report.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: existing.path, contents: Data()))

        let destination = BrowserDownloadDestinationResolver.destinationURL(
            suggestedFilename: "../../report.pdf",
            downloadsDirectory: directory
        )

        XCTAssertEqual(destination.deletingLastPathComponent(), directory)
        XCTAssertEqual(destination.lastPathComponent, "report 2.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadDestinationRejectsTraversalAndControlCharacters() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let traversalDestination = BrowserDownloadDestinationResolver.destinationURL(
            suggestedFilename: "..",
            downloadsDirectory: directory
        )
        let controlCharacterDestination = BrowserDownloadDestinationResolver.destinationURL(
            suggestedFilename: "report\u{0000}\n.pdf",
            downloadsDirectory: directory
        )

        XCTAssertEqual(traversalDestination.deletingLastPathComponent(), directory)
        XCTAssertEqual(traversalDestination.lastPathComponent, "download")
        XCTAssertEqual(controlCharacterDestination.lastPathComponent, "report.pdf")
    }

    func testLoadErrorShowsVisibleRetryStateInsteadOfBlankPage() throws {
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1/"))
        let pane = BrowserPaneViewController(
            runtimeID: "browser-error-state-test",
            url: initialURL,
            title: "Browser",
            loadsInitialRequest: false
        )
        pane.loadView()

        pane.showErrorForTesting("远端无法连接该服务")

        let overlay = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.stateOverlay")
        )
        let message = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.stateMessage") as? NSTextField
        )
        let icon = try XCTUnwrap(
            pane.view.firstSubview(withIdentifier: "Stacio.Browser.stateIcon") as? NSImageView
        )
        pane.view.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        pane.view.layoutSubtreeIfNeeded()
        let overlayFrame = overlay.convert(overlay.bounds, to: pane.view)
        let messageFrame = message.convert(message.bounds, to: pane.view)
        let iconFrame = icon.convert(icon.bounds, to: pane.view)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(message.stringValue, "载入失败：远端无法连接该服务")
        XCTAssertGreaterThan(messageFrame.width, 300)
        XCTAssertGreaterThan(messageFrame.minX, overlayFrame.minX)
        XCTAssertLessThan(messageFrame.maxX, overlayFrame.maxX)
        XCTAssertGreaterThan(messageFrame.minY, overlayFrame.minY)
        XCTAssertLessThan(messageFrame.maxY, overlayFrame.maxY)
        XCTAssertGreaterThan(iconFrame.width, 20)
        XCTAssertLessThan(iconFrame.width, 48)
        XCTAssertGreaterThan(iconFrame.height, 20)
        XCTAssertLessThan(iconFrame.height, 48)
        XCTAssertGreaterThan(iconFrame.minY, overlayFrame.minY)
        XCTAssertLessThan(iconFrame.maxY, overlayFrame.maxY)
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

private final class BrowserNavigationObserver: NSObject, WKNavigationDelegate {
    let completedExpectation = XCTestExpectation(description: "WebKit navigation completed")
    private(set) var didFinish = false
    private(set) var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        completedExpectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        completedExpectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        completedExpectation.fulfill()
    }
}

private final class BrowserSOCKS5Fixture: @unchecked Sendable {
    let readyExpectation = XCTestExpectation(description: "SOCKS5 fixture ready")
    let requestExpectation = XCTestExpectation(description: "SOCKS5 CONNECT request received")

    private enum State {
        case hello
        case connect
        case http
        case finished
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "StacioTests.BrowserSOCKS5Fixture")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var buffer = Data()
    private var state = State.hello
    private var storedRequestedHost: String?
    private var storedRequestedPort: UInt16?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    var port: NWEndpoint.Port? {
        listener.port
    }

    var requestedHost: String? {
        lock.withLock { storedRequestedHost }
    }

    var requestedPort: UInt16? {
        lock.withLock { storedRequestedPort }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            self?.readyExpectation.fulfill()
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard self.connection == nil else {
            connection.cancel()
            return
        }
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else { return }
            self?.receive(from: connection)
        }
        connection.start(queue: queue)
    }

    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, data.isEmpty == false {
                self.buffer.append(data)
                self.processBuffer(on: connection)
            }
            if error == nil, isComplete == false, self.state != .finished {
                self.receive(from: connection)
            }
        }
    }

    private func processBuffer(on connection: NWConnection) {
        switch state {
        case .hello:
            guard buffer.count >= 2 else { return }
            let methodCount = Int(buffer[1])
            guard buffer.count >= 2 + methodCount else { return }
            buffer = Data(buffer.dropFirst(2 + methodCount))
            state = .connect
            connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { [weak self] _ in
                self?.processBuffer(on: connection)
            })

        case .connect:
            guard let request = parseConnectRequest(buffer) else { return }
            buffer = Data(buffer.dropFirst(request.consumed))
            lock.withLock {
                storedRequestedHost = request.host
                storedRequestedPort = request.port
            }
            requestExpectation.fulfill()
            state = .http
            connection.send(
                content: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                completion: .contentProcessed { [weak self] _ in
                    self?.processBuffer(on: connection)
                }
            )

        case .http:
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
            state = .finished
            let body = "<html><body>stacio proxy ready</body></html>"
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)

        case .finished:
            break
        }
    }

    private func parseConnectRequest(_ data: Data) -> (host: String, port: UInt16, consumed: Int)? {
        let bytes = Array(data)
        guard bytes.count >= 4, bytes[0] == 0x05, bytes[1] == 0x01 else {
            return nil
        }
        switch bytes[3] {
        case 0x01:
            guard bytes.count >= 10 else { return nil }
            let host = bytes[4...7].map(String.init).joined(separator: ".")
            return (host, UInt16(bytes[8]) << 8 | UInt16(bytes[9]), 10)
        case 0x03:
            guard bytes.count >= 5 else { return nil }
            let length = Int(bytes[4])
            let consumed = 5 + length + 2
            guard bytes.count >= consumed else { return nil }
            let host = String(decoding: bytes[5..<(5 + length)], as: UTF8.self)
            let port = UInt16(bytes[5 + length]) << 8 | UInt16(bytes[6 + length])
            return (host, port, consumed)
        case 0x04:
            guard bytes.count >= 22 else { return nil }
            let host = bytes[4..<20].map { String(format: "%02x", $0) }.joined(separator: ":")
            return (host, UInt16(bytes[20]) << 8 | UInt16(bytes[21]), 22)
        default:
            return nil
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }

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
