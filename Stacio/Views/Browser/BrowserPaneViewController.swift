import AppKit
import Network
import WebKit

public enum BrowserPaneError: Error, Equatable, LocalizedError {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "浏览器地址无效。"
        }
    }
}

public final class BrowserPaneViewController: NSViewController {
    public let runtimeID: String
    public let url: URL
    public let webView: WKWebView

    private let loadsInitialRequest: Bool
    private let statusLabel = NSTextField(labelWithString: "")
    private let addressField = NSTextField(string: "")
    private var currentURLString: String
    private var statusText: String
    private var navigationActions: [String] = []
    private var isRetired = false

    public init(
        runtimeID: String,
        url: URL,
        title: String,
        socksProxyEndpoint: NWEndpoint? = nil,
        loadsInitialRequest: Bool = true
    ) {
        self.runtimeID = runtimeID
        self.url = url
        self.loadsInitialRequest = loadsInitialRequest
        self.currentURLString = url.absoluteString
        self.statusText = "准备载入：\(url.absoluteString)"
        self.addressField.stringValue = url.absoluteString
        let configuration = WKWebViewConfiguration()
        if let socksProxyEndpoint {
            let dataStore = WKWebsiteDataStore.nonPersistent()
            dataStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: socksProxyEndpoint)]
            configuration.websiteDataStore = dataStore
        }
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        let toolbarContainer = NSView()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "后退") ?? NSImage(),
            target: self,
            action: #selector(backButtonPressed)
        )
        backButton.bezelStyle = .texturedRounded
        backButton.toolTip = "后退"
        StacioDesignSystem.styleToolbarButton(backButton)

        let forwardButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "前进") ?? NSImage(),
            target: self,
            action: #selector(forwardButtonPressed)
        )
        forwardButton.bezelStyle = .texturedRounded
        forwardButton.toolTip = "前进"
        StacioDesignSystem.styleToolbarButton(forwardButton)

        let reloadButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入") ?? NSImage(),
            target: self,
            action: #selector(reloadButtonPressed)
        )
        reloadButton.bezelStyle = .texturedRounded
        reloadButton.toolTip = "重新载入"
        StacioDesignSystem.styleToolbarButton(reloadButton)

        addressField.placeholderString = L10n.Browser.address
        addressField.target = self
        addressField.action = #selector(addressFieldSubmitted)
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.cell?.usesSingleLineMode = true
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.setAccessibilityIdentifier("Stacio.Browser.address")
        addressField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleCompactTextField(addressField)

        let goButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: L10n.Browser.go) ?? NSImage(),
            target: self,
            action: #selector(goButtonPressed)
        )
        goButton.bezelStyle = .texturedRounded
        goButton.toolTip = L10n.Browser.go
        StacioDesignSystem.styleToolbarButton(goButton)

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.stringValue = statusText
        statusLabel.toolTip = statusText
        statusLabel.setAccessibilityIdentifier("Stacio.Browser.status")

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(reloadButton)
        toolbar.addArrangedSubview(addressField)
        toolbar.addArrangedSubview(goButton)
        toolbar.addArrangedSubview(statusLabel)
        [backButton, forwardButton, reloadButton, goButton].forEach { control in
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let addressMinimumWidth = addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
        addressMinimumWidth.priority = .defaultHigh
        let statusMaximumWidth = statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170)

        let toolbarSeparator = NSBox()
        toolbarSeparator.boxType = .separator
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false
        toolbarSeparator.setAccessibilityIdentifier("Stacio.Browser.toolbarSeparator")

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        toolbarContainer.addSubview(toolbar)
        container.addSubview(toolbarContainer)
        container.addSubview(toolbarSeparator)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbarContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: 6),
            toolbar.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor, constant: -10),
            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            addressMinimumWidth,
            statusMaximumWidth,
            addressField.heightAnchor.constraint(equalToConstant: 32),
            toolbarSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarSeparator.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        if loadsInitialRequest, isRetired == false {
            webView.load(URLRequest(url: url))
        }
    }

    public var currentURLStringForTesting: String {
        currentURLString
    }

    public var statusTextForTesting: String {
        statusText
    }

    public var addressFieldValueForTesting: String {
        addressField.stringValue
    }

    public var navigationActionsForTesting: [String] {
        navigationActions
    }

    public var proxyConfigurationCountForTesting: Int {
        webView.configuration.websiteDataStore.proxyConfigurations.count
    }

    public func loadAddressForTesting(_ value: String) {
        addressField.stringValue = value
        loadAddressFromField()
    }

    public func reloadPage() {
        guard isRetired == false else {
            return
        }
        navigationActions.append("reload")
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    public func goBackPage() {
        guard isRetired == false else {
            return
        }
        navigationActions.append("back")
        if webView.canGoBack {
            webView.goBack()
        }
    }

    public func goForwardPage() {
        guard isRetired == false else {
            return
        }
        navigationActions.append("forward")
        if webView.canGoForward {
            webView.goForward()
        }
    }

    public func setLoadingStateForTesting(isLoading: Bool) {
        updateStatus(isLoading ? "正在载入：\(currentURLString)" : "已载入：\(currentURLString)")
    }

    public func showLoadErrorMessage(_ message: String) {
        showLoadError(message)
    }

    public func showErrorForTesting(_ message: String) {
        showLoadErrorMessage(message)
    }

    func closeBrowserPane() {
        retireBrowserPane()
    }

    @objc private func reloadButtonPressed() {
        reloadPage()
    }

    @objc private func backButtonPressed() {
        goBackPage()
    }

    @objc private func forwardButtonPressed() {
        goForwardPage()
    }

    @objc private func addressFieldSubmitted() {
        loadAddressFromField()
    }

    @objc private func goButtonPressed() {
        loadAddressFromField()
    }

    private func updateStatus(_ value: String) {
        guard isRetired == false else {
            return
        }
        statusText = value
        if isViewLoaded {
            statusLabel.stringValue = value
            statusLabel.toolTip = value
        }
    }

    private func showLoadError(_ message: String) {
        guard isRetired == false else {
            return
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        updateStatus("载入失败：\(trimmed.isEmpty ? "无法打开页面" : trimmed)")
    }

    private func loadAddressFromField() {
        guard isRetired == false else {
            return
        }
        let rawValue = addressField.stringValue
        guard let nextURL = normalizedURL(rawValue) else {
            addressField.stringValue = currentURLString
            showLoadError(L10n.Browser.invalidAddress)
            return
        }
        currentURLString = nextURL.absoluteString
        addressField.stringValue = nextURL.absoluteString
        navigationActions.append("load:\(nextURL.absoluteString)")
        updateStatus("正在载入：\(nextURL.absoluteString)")
        webView.load(URLRequest(url: nextURL))
    }

    private func normalizedURL(_ value: String) -> URL? {
        BrowserURLNormalizer.normalizedURL(value)
    }

    private func retireBrowserPane() {
        guard isRetired == false else {
            return
        }
        isRetired = true
        webView.stopLoading()
        webView.navigationDelegate = nil
    }
}

extension BrowserPaneViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        currentURLString = webView.url?.absoluteString ?? currentURLString
        addressField.stringValue = currentURLString
        updateStatus("正在载入：\(currentURLString)")
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        currentURLString = webView.url?.absoluteString ?? currentURLString
        addressField.stringValue = currentURLString
        updateStatus("已载入：\(currentURLString)")
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        showLoadError("无法打开页面")
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        showLoadError("无法打开页面")
    }
}
