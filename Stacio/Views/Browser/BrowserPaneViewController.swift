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

enum BrowserDownloadDestinationResolver {
    static func destinationURL(
        suggestedFilename: String,
        downloadsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let sanitizedName = sanitizedFilename(suggestedFilename)
        let filename = sanitizedName.isEmpty ? "download" : sanitizedName
        let pathExtension = (filename as NSString).pathExtension
        let baseName = (filename as NSString).deletingPathExtension

        var candidate = downloadsDirectory.appendingPathComponent(filename, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let uniqueName: String
            if pathExtension.isEmpty {
                uniqueName = "\(baseName) \(suffix)"
            } else {
                uniqueName = "\(baseName) \(suffix).\(pathExtension)"
            }
            candidate = downloadsDirectory.appendingPathComponent(uniqueName, isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    static func sanitizedFilename(_ value: String) -> String {
        let lastPathComponent = (value as NSString).lastPathComponent
        let sanitized = lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized == "." || sanitized == ".." ? "" : sanitized
    }
}

private final class BrowserDownloadState {
    let download: WKDownload
    var filename: String
    var destinationURL: URL?
    var progressObservation: NSKeyValueObservation?

    init(download: WKDownload, filename: String) {
        self.download = download
        self.filename = filename
    }
}

private final class BrowserRootView: NSView, StacioEffectiveAppearanceRefreshHandling {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stacioRefreshEffectiveAppearance()
    }

    func stacioRefreshEffectiveAppearance() {
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

public final class BrowserPaneViewController: NSViewController {
    public let runtimeID: String
    public let url: URL
    public let webView: WKWebView

    private let loadsInitialRequest: Bool
    private let modeLabelText: String?
    private let fallbackTitle: String
    private let statusIndicator = NSProgressIndicator()
    private let addressField = NSTextField(string: "")
    private let faviconImageView = NSImageView()
    private let stateOverlay = NSVisualEffectView()
    private let stateIconView = NSImageView()
    private let stateMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let stateRetryButton = NSButton()
    private let downloadsButton = RemoteBrowserToolbarButton()
    private let bookmarksButton = RemoteBrowserToolbarButton()
    private let findButton = RemoteBrowserToolbarButton()
    private var modeLabelView: RemoteBrowserModeLabel?
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let downloadsDirectoryProvider: () -> URL?
    private var currentURLString: String
    private var statusText: String
    private var navigationActions: [String] = []
    private var activeDownloads: [ObjectIdentifier: BrowserDownloadState] = [:]
    private var lastDownloadedURL: URL?
    private var isNavigationLoading = false
    private var isRetired = false
    private var socksProxyEndpoint: NWEndpoint?

    // MARK: - Bookmarks
    private static let bookmarksDefaultsKey = "stacio.browser.bookmarks"
    private struct Bookmark: Codable { let title: String; let url: String }

    var onRetryRequested: (() -> Void)?
    var onDeferredNavigationRequested: ((URL) -> Void)?
    var onPageTitleChange: ((String) -> Void)?

    public init(
        runtimeID: String,
        url: URL,
        title: String,
        socksProxyEndpoint: NWEndpoint? = nil,
        loadsInitialRequest: Bool = true,
        initialStatusText: String? = nil,
        modeLabel: String? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        downloadsDirectoryProvider: @escaping () -> URL? = {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
    ) {
        self.runtimeID = runtimeID
        self.url = url
        self.loadsInitialRequest = loadsInitialRequest
        self.modeLabelText = modeLabel
        self.fallbackTitle = title
        self.currentURLString = url.absoluteString
        self.statusText = initialStatusText ?? "准备载入：\(url.absoluteString)"
        self.addressField.stringValue = url.absoluteString
        self.fileManager = fileManager
        self.defaults = defaults
        self.downloadsDirectoryProvider = downloadsDirectoryProvider
        let configuration = WKWebViewConfiguration()
        if let socksProxyEndpoint {
            let dataStore = WKWebsiteDataStore.nonPersistent()
            var proxyConfiguration = ProxyConfiguration(socksv5Proxy: socksProxyEndpoint)
            // The DNS root suffix matches every hostname, including transport aliases.
            proxyConfiguration.matchDomains = ["."]
            proxyConfiguration.excludedDomains = []
            proxyConfiguration.allowFailover = false
            dataStore.proxyConfigurations = [proxyConfiguration]
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
        let container = BrowserRootView()
        container.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        let toolbarContainer = NSView()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.setAccessibilityIdentifier("Stacio.Browser.toolbar")

        let navigationRow = NSStackView()
        navigationRow.orientation = .horizontal
        navigationRow.alignment = .centerY
        navigationRow.spacing = 6
        navigationRow.detachesHiddenViews = true
        navigationRow.translatesAutoresizingMaskIntoConstraints = false

        let backButton = RemoteBrowserToolbarButton()
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "后退")
        backButton.target = self
        backButton.action = #selector(backButtonPressed)
        backButton.bezelStyle = .texturedRounded
        backButton.toolTip = "后退"
        StacioDesignSystem.styleToolbarButton(backButton)

        let forwardButton = RemoteBrowserToolbarButton()
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "前进")
        forwardButton.target = self
        forwardButton.action = #selector(forwardButtonPressed)
        forwardButton.bezelStyle = .texturedRounded
        forwardButton.toolTip = "前进"
        StacioDesignSystem.styleToolbarButton(forwardButton)

        let reloadButton = RemoteBrowserToolbarButton()
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入")
        reloadButton.target = self
        reloadButton.action = #selector(reloadButtonPressed)
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

        faviconImageView.image = Self.fallbackFavicon
        faviconImageView.imageScaling = .scaleProportionallyDown
        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.setAccessibilityIdentifier("Stacio.Browser.favicon")

        let goButton = RemoteBrowserToolbarButton()
        goButton.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: L10n.Browser.go)
        goButton.target = self
        goButton.action = #selector(goButtonPressed)
        goButton.bezelStyle = .texturedRounded
        goButton.toolTip = L10n.Browser.go
        StacioDesignSystem.styleToolbarButton(goButton)

        downloadsButton.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: "下载"
        )
        downloadsButton.target = self
        downloadsButton.action = #selector(downloadsButtonPressed)
        downloadsButton.bezelStyle = .texturedRounded
        downloadsButton.toolTip = "打开下载目录"
        downloadsButton.setAccessibilityIdentifier("Stacio.Browser.downloads")
        StacioDesignSystem.styleToolbarButton(downloadsButton)

        bookmarksButton.image = NSImage(
            systemSymbolName: "bookmark",
            accessibilityDescription: "书签"
        )
        bookmarksButton.target = self
        bookmarksButton.action = #selector(bookmarksButtonPressed(_:))
        bookmarksButton.bezelStyle = .texturedRounded
        bookmarksButton.toolTip = "书签"
        bookmarksButton.setAccessibilityIdentifier("Stacio.Browser.bookmarks")
        StacioDesignSystem.styleToolbarButton(bookmarksButton)

        findButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "在页面中查找"
        )
        findButton.target = self
        findButton.action = #selector(findButtonPressed(_:))
        findButton.bezelStyle = .texturedRounded
        findButton.toolTip = "在页面中查找"
        findButton.setAccessibilityIdentifier("Stacio.Browser.findInPage")
        StacioDesignSystem.styleToolbarButton(findButton)

        statusIndicator.style = .spinning
        statusIndicator.controlSize = .small
        statusIndicator.isDisplayedWhenStopped = false
        statusIndicator.toolTip = statusText
        statusIndicator.setAccessibilityLabel("网页载入状态")
        statusIndicator.setAccessibilityIdentifier("Stacio.Browser.statusIndicator")
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false

        navigationRow.addArrangedSubview(backButton)
        navigationRow.addArrangedSubview(forwardButton)
        navigationRow.addArrangedSubview(reloadButton)
        navigationRow.addArrangedSubview(faviconImageView)
        navigationRow.addArrangedSubview(addressField)
        navigationRow.addArrangedSubview(statusIndicator)
        navigationRow.addArrangedSubview(goButton)
        navigationRow.addArrangedSubview(bookmarksButton)
        navigationRow.addArrangedSubview(findButton)
        navigationRow.addArrangedSubview(downloadsButton)
        let fixedWidthControls: [NSView] = [
            backButton,
            forwardButton,
            reloadButton,
            goButton,
            bookmarksButton,
            findButton,
            downloadsButton
        ]
        if let modeLabelText {
            let modeLabel = RemoteBrowserModeLabel(
                text: modeLabelText,
                accessibilityIdentifier: "Stacio.Browser.mode"
            )
            modeLabelView = modeLabel
            navigationRow.addArrangedSubview(modeLabel)
            modeLabel.setContentHuggingPriority(.required, for: .horizontal)
            modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                modeLabel.heightAnchor.constraint(equalToConstant: 22)
            ])
        }
        fixedWidthControls.forEach { control in
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                control.widthAnchor.constraint(equalToConstant: 28),
                control.heightAnchor.constraint(equalToConstant: 28)
            ])
        }
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        faviconImageView.setContentHuggingPriority(.required, for: .horizontal)
        faviconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIndicator.setContentHuggingPriority(.required, for: .horizontal)
        statusIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)

        let addressMinimumWidth = addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        addressMinimumWidth.priority = .defaultLow

        let toolbarSeparator = NSBox()
        toolbarSeparator.boxType = .separator
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false
        toolbarSeparator.setAccessibilityIdentifier("Stacio.Browser.toolbarSeparator")

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self

        stateOverlay.material = .contentBackground
        stateOverlay.blendingMode = .withinWindow
        stateOverlay.state = .active
        stateOverlay.translatesAutoresizingMaskIntoConstraints = false
        stateOverlay.setAccessibilityIdentifier("Stacio.Browser.stateOverlay")
        stateIconView.image = NSImage(
            systemSymbolName: "network",
            accessibilityDescription: "浏览器状态"
        )
        stateIconView.contentTintColor = .secondaryLabelColor
        stateIconView.imageScaling = .scaleProportionallyDown
        stateIconView.translatesAutoresizingMaskIntoConstraints = false
        stateIconView.setAccessibilityIdentifier("Stacio.Browser.stateIcon")
        stateMessageLabel.alignment = .center
        stateMessageLabel.textColor = .secondaryLabelColor
        stateMessageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateMessageLabel.maximumNumberOfLines = 3
        stateMessageLabel.stringValue = statusText
        stateMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        stateMessageLabel.setAccessibilityIdentifier("Stacio.Browser.stateMessage")
        stateRetryButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "重试"
        )
        stateRetryButton.target = self
        stateRetryButton.action = #selector(stateRetryButtonPressed)
        stateRetryButton.bezelStyle = .texturedRounded
        stateRetryButton.toolTip = "重试"
        stateRetryButton.isHidden = true
        stateRetryButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(stateRetryButton)

        let stateStack = NSStackView(views: [stateIconView, stateMessageLabel, stateRetryButton])
        stateStack.orientation = .vertical
        stateStack.alignment = .centerX
        stateStack.spacing = 10
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Keep the state message inside a real, bounded container.  Letting an
        // arranged wrapping label determine the stack width can collapse it to
        // a one-pixel column while the inspector is being resized.
        let stateContentView = NSView()
        stateContentView.translatesAutoresizingMaskIntoConstraints = false
        stateOverlay.addSubview(stateContentView)
        stateContentView.addSubview(stateStack)
        stateMessageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateMessageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        toolbarContainer.addSubview(navigationRow)
        container.addSubview(toolbarContainer)
        container.addSubview(toolbarSeparator)
        container.addSubview(webView)
        container.addSubview(stateOverlay)
        NSLayoutConstraint.activate([
            toolbarContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            toolbarContainer.heightAnchor.constraint(equalToConstant: 36),
            navigationRow.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 8),
            navigationRow.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -8),
            navigationRow.topAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: -2),
            navigationRow.heightAnchor.constraint(equalToConstant: 28),
            addressMinimumWidth,
            addressField.heightAnchor.constraint(equalToConstant: 28),
            faviconImageView.widthAnchor.constraint(equalToConstant: 18),
            faviconImageView.heightAnchor.constraint(equalToConstant: 18),
            statusIndicator.widthAnchor.constraint(equalToConstant: 14),
            statusIndicator.heightAnchor.constraint(equalToConstant: 14),
            toolbarSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarSeparator.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stateOverlay.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            stateOverlay.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            stateOverlay.topAnchor.constraint(equalTo: webView.topAnchor),
            stateOverlay.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            stateContentView.leadingAnchor.constraint(equalTo: stateOverlay.leadingAnchor, constant: 20),
            stateContentView.trailingAnchor.constraint(equalTo: stateOverlay.trailingAnchor, constant: -20),
            stateContentView.centerYAnchor.constraint(equalTo: stateOverlay.centerYAnchor),
            stateStack.leadingAnchor.constraint(equalTo: stateContentView.leadingAnchor),
            stateStack.trailingAnchor.constraint(equalTo: stateContentView.trailingAnchor),
            stateStack.topAnchor.constraint(equalTo: stateContentView.topAnchor),
            stateStack.bottomAnchor.constraint(equalTo: stateContentView.bottomAnchor),
            stateMessageLabel.widthAnchor.constraint(equalTo: stateContentView.widthAnchor),
            stateIconView.widthAnchor.constraint(equalToConstant: 28),
            stateIconView.heightAnchor.constraint(equalToConstant: 28)
        ])

        view = container
        if loadsInitialRequest, isRetired == false {
            showLoadingState("正在载入：\(url.absoluteString)")
            webView.load(request(for: url))
        } else {
            showWaitingState(statusText)
        }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let isNarrow = view.bounds.width < 420
        bookmarksButton.isHidden = isNarrow
        findButton.isHidden = isNarrow
        modeLabelView?.isHidden = view.bounds.width < 460
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

    public var proxyMatchDomainsForTesting: [String] {
        webView.configuration.websiteDataStore.proxyConfigurations.first?.matchDomains ?? []
    }

    public var proxyAllowsFailoverForTesting: Bool? {
        webView.configuration.websiteDataStore.proxyConfigurations.first?.allowFailover
    }

    public var activeDownloadCountForTesting: Int {
        activeDownloads.count
    }

    var faviconImageForTesting: NSImage? { faviconImageView.image }

    func updatePagePresentationForTesting(title: String, faviconDataURL: String?) {
        updatePagePresentation(title: title, faviconDataURL: faviconDataURL)
    }

    public func loadAddressForTesting(_ value: String) {
        addressField.stringValue = value
        loadAddressFromField()
    }

    public func reloadPage() {
        guard isRetired == false else { return }
        navigationActions.append("reload")
        if webView.url == nil { webView.load(request(for: url)) } else { webView.reload() }
    }

    // MARK: - Bookmarks

    public func addBookmark() {
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? webView.title! : currentURLString
        var bookmarks = loadBookmarks()
        guard bookmarks.first(where: { $0.url == currentURLString }) == nil else { return }
        bookmarks.append(Bookmark(title: title, url: currentURLString))
        saveBookmarks(bookmarks)
    }

    public func bookmarksMenu() -> NSMenu {
        let menu = NSMenu()
        let bookmarks = loadBookmarks()
        if bookmarks.isEmpty {
            let item = NSMenuItem(title: "无书签", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for bookmark in bookmarks {
                let item = NSMenuItem(title: bookmark.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                item.representedObject = bookmark.url
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let manageItem = menu.addItem(
                withTitle: "管理书签…",
                action: #selector(manageBookmarks),
                keyEquivalent: ""
            )
            manageItem.target = self
        }
        return menu
    }

    public var bookmarkTitlesForTesting: [String] {
        loadBookmarks().map(\.title)
    }

    public func removeBookmarkForTesting(at index: Int) {
        removeBookmark(at: index)
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString)
        else { return }
        addressField.stringValue = urlString
        webView.load(URLRequest(url: url))
    }

    @objc private func manageBookmarks() {
        let bookmarks = loadBookmarks()
        guard bookmarks.isEmpty == false else { return }
        let alert = NSAlert()
        alert.messageText = "书签"
        alert.informativeText = "选择要删除的书签。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        popup.addItems(withTitles: bookmarks.map(\.title))
        alert.accessoryView = popup
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let index = popup.indexOfSelectedItem
            guard response == .alertFirstButtonReturn,
                  bookmarks.indices.contains(index)
            else { return }
            self?.removeBookmark(url: bookmarks[index].url)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func bookmarksButtonPressed(_ sender: NSButton) {
        let menu = bookmarksMenu()
        menu.insertItem(withTitle: "添加当前页书签", action: #selector(addBookmarkMenuItemPressed(_:)), keyEquivalent: "", at: 0)
        menu.items.first?.target = self
        if menu.numberOfItems > 1 {
            menu.insertItem(.separator(), at: 1)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func addBookmarkMenuItemPressed(_ sender: Any?) {
        addBookmark()
    }

    @objc private func findButtonPressed(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "在页面中查找"
        alert.addButton(withTitle: "查找")
        alert.addButton(withTitle: "取消")
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "输入查找内容"
        field.setAccessibilityIdentifier("Stacio.Browser.findInPage.query")
        alert.accessoryView = field
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.findInPage(query: field.stringValue)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    public func showFindInPage() {
        findButtonPressed(nil)
    }

    static func containing(responder: NSResponder?) -> BrowserPaneViewController? {
        var responder = responder
        var visited: Set<ObjectIdentifier> = []
        while let current = responder,
              visited.insert(ObjectIdentifier(current)).inserted {
            if let browser = current as? BrowserPaneViewController { return browser }
            responder = current.nextResponder
        }
        return nil
    }

    private func loadBookmarks() -> [Bookmark] {
        guard let data = defaults.data(forKey: Self.bookmarksDefaultsKey),
              let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return [] }
        return bookmarks
    }

    private func saveBookmarks(_ bookmarks: [Bookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: Self.bookmarksDefaultsKey)
    }

    private func removeBookmark(at index: Int) {
        var bookmarks = loadBookmarks()
        guard bookmarks.indices.contains(index) else { return }
        bookmarks.remove(at: index)
        saveBookmarks(bookmarks)
    }

    private func removeBookmark(url: String) {
        var bookmarks = loadBookmarks()
        guard let index = bookmarks.firstIndex(where: { $0.url == url }) else { return }
        bookmarks.remove(at: index)
        saveBookmarks(bookmarks)
    }

    // MARK: - Find in page

    public func findInPage(query: String) {
        guard query.isEmpty == false else {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
            return
        }
        webView.callAsyncJavaScript(
            "return window.find(query, false, false, true, false, true, false);",
            arguments: ["query": query],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    // MARK: - Keyboard shortcut handling

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "[":
                goBackPage()
                return true
            case "]":
                goForwardPage()
                return true
            case "r":
                reloadPage()
                return true
            case "f":
                findButtonPressed(nil)
                return true
            default:
                break
            }
        }
        return false
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
        if isLoading {
            showLoadingState("正在载入：\(currentURLString)")
        } else {
            showLoadedState("已载入：\(currentURLString)")
        }
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

    @objc private func downloadsButtonPressed() {
        if let lastDownloadedURL,
           fileManager.fileExists(atPath: lastDownloadedURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastDownloadedURL])
            return
        }
        guard let downloadsDirectory = downloadsDirectoryProvider() else {
            showLoadError("无法打开下载目录")
            return
        }
        NSWorkspace.shared.open(downloadsDirectory)
    }

    @objc private func stateRetryButtonPressed() {
        if let onRetryRequested {
            onRetryRequested()
        } else {
            reloadPage()
        }
    }

    private func updateStatus(_ value: String) {
        guard isRetired == false else {
            return
        }
        statusText = value
        if isViewLoaded {
            statusIndicator.toolTip = value
        }
    }

    private func showWaitingState(_ value: String) {
        isNavigationLoading = true
        updateStatus(value)
        guard isViewLoaded else { return }
        statusIndicator.startAnimation(nil)
        stateIconView.image = NSImage(
            systemSymbolName: "network",
            accessibilityDescription: "浏览器状态"
        )
        stateMessageLabel.stringValue = value
        stateRetryButton.isHidden = true
        stateOverlay.isHidden = false
    }

    private func showLoadingState(_ value: String) {
        isNavigationLoading = true
        updateStatus(value)
        guard isViewLoaded else { return }
        statusIndicator.startAnimation(nil)
        stateMessageLabel.stringValue = value
        stateRetryButton.isHidden = true
        stateOverlay.isHidden = true
        refreshWebContentPresentation()
    }

    private func showLoadedState(_ value: String) {
        isNavigationLoading = false
        updateStatus(value)
        guard isViewLoaded else { return }
        if activeDownloads.isEmpty {
            statusIndicator.stopAnimation(nil)
        }
        stateRetryButton.isHidden = true
        stateOverlay.isHidden = true
        refreshWebContentPresentation()
    }

    private func showLoadError(_ message: String) {
        guard isRetired == false else {
            return
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = "载入失败：\(trimmed.isEmpty ? "无法打开页面" : trimmed)"
        isNavigationLoading = false
        updateStatus(value)
        guard isViewLoaded else { return }
        statusIndicator.stopAnimation(nil)
        stateIconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: "载入失败"
        )
        stateMessageLabel.stringValue = value
        stateRetryButton.isHidden = false
        stateOverlay.isHidden = false
    }

    private func refreshWebContentPresentation() {
        webView.superview?.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
        webView.needsDisplay = true
        webView.layer?.setNeedsDisplay()
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
        if let onDeferredNavigationRequested {
            showWaitingState("正在等待远端浏览通道：\(nextURL.absoluteString)")
            onDeferredNavigationRequested(nextURL)
            return
        }
        showLoadingState("正在载入：\(nextURL.absoluteString)")
        webView.load(request(for: nextURL))
    }

    private func normalizedURL(_ value: String) -> URL? {
        BrowserURLNormalizer.normalizedURL(value)
    }

    private func request(for displayURL: URL) -> URLRequest {
        URLRequest(url: BrowserURLNormalizer.transportURL(for: displayURL))
    }

    private func updateDisplayedURL(from transportURL: URL?) {
        guard let transportURL else { return }
        let displayURL = BrowserURLNormalizer.displayURL(for: transportURL)
        currentURLString = displayURL.absoluteString
        addressField.stringValue = currentURLString
    }

    private func retireBrowserPane() {
        guard isRetired == false else {
            return
        }
        isRetired = true
        onDeferredNavigationRequested = nil
        onPageTitleChange = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        for state in activeDownloads.values {
            state.progressObservation?.invalidate()
            state.download.delegate = nil
            state.download.cancel(nil)
        }
        activeDownloads.removeAll()
    }

    private func beginDownload(_ download: WKDownload) {
        guard isRetired == false else {
            download.cancel(nil)
            return
        }
        let identifier = ObjectIdentifier(download)
        let requestName = download.originalRequest?.url?.lastPathComponent
        let sanitizedRequestName = requestName.map(BrowserDownloadDestinationResolver.sanitizedFilename) ?? ""
        let filename = sanitizedRequestName.isEmpty ? "下载文件" : sanitizedRequestName
        let state = BrowserDownloadState(download: download, filename: filename)
        state.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.updateDownloadProgress(identifier: identifier, fractionCompleted: progress.fractionCompleted)
            }
        }
        activeDownloads[identifier] = state
        download.delegate = self
        isNavigationLoading = false
        stateOverlay.isHidden = true
        statusIndicator.startAnimation(nil)
        updateStatus("准备下载：\(filename)")
    }

    private func updateDownloadProgress(identifier: ObjectIdentifier, fractionCompleted: Double) {
        guard isRetired == false,
              let state = activeDownloads[identifier]
        else { return }
        let percentage = max(0, min(100, Int((fractionCompleted * 100).rounded())))
        updateStatus("正在下载 \(percentage)%：\(state.filename)")
    }

    private func finishDownload(_ download: WKDownload, errorMessage: String? = nil) {
        let identifier = ObjectIdentifier(download)
        guard let state = activeDownloads.removeValue(forKey: identifier) else {
            return
        }
        state.progressObservation?.invalidate()
        if activeDownloads.isEmpty {
            statusIndicator.stopAnimation(nil)
            if !isNavigationLoading, isViewLoaded {
                stateOverlay.isHidden = true
            }
        }
        if let errorMessage {
            updateStatus(errorMessage)
        } else {
            lastDownloadedURL = state.destinationURL
            updateStatus("下载完成：\(state.filename)")
        }
    }

    private func navigationErrorMessage(_ error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return "无法打开页面"
        }
        let code = URLError.Code(rawValue: nsError.code)
        switch code {
        case .cancelled:
            return nil
        case .timedOut:
            return "连接超时，请检查远端服务地址和端口"
        case .cannotFindHost, .dnsLookupFailed:
            return "远端无法解析该主机名"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return "远端无法连接该服务"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "HTTPS 证书校验失败"
        case .appTransportSecurityRequiresSecureConnection:
            return "HTTP 页面被系统安全策略拦截"
        default:
            return "无法打开页面"
        }
    }

    private func refreshPagePresentation() {
        let script = """
        (async () => {
          const title = document.title || '';
          const icon = document.querySelector('link[rel~="icon"]');
          let favicon = icon && icon.href ? icon.href : null;
          if (favicon && !favicon.startsWith('data:')) {
            try {
              const response = await fetch(favicon);
              const blob = await response.blob();
              favicon = await new Promise((resolve) => {
                const reader = new FileReader();
                reader.onloadend = () => resolve(reader.result);
                reader.onerror = () => resolve(null);
                reader.readAsDataURL(blob);
              });
            } catch (_) { favicon = null; }
          }
          return JSON.stringify({ title, favicon });
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self,
                  self.isRetired == false,
                  let json = value as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            self.updatePagePresentation(
                title: object["title"] as? String ?? "",
                faviconDataURL: object["favicon"] as? String
            )
        }
    }

    private func updatePagePresentation(title: String, faviconDataURL: String?) {
        let pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = pageTitle.isEmpty ? fallbackTitle : pageTitle
        self.title = resolvedTitle
        onPageTitleChange?(resolvedTitle)
        faviconImageView.image = faviconDataURL.flatMap(Self.imageFromDataURL) ?? Self.fallbackFavicon
    }

    private static var fallbackFavicon: NSImage? {
        NSImage(systemSymbolName: "globe", accessibilityDescription: "网页图标")
    }

    private static func imageFromDataURL(_ value: String) -> NSImage? {
        guard value.hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ","),
              value[..<comma].contains(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }
}

extension BrowserPaneViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        updateDisplayedURL(from: webView.url)
        showLoadingState("正在载入：\(currentURLString)")
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        updateDisplayedURL(from: webView.url)
        stateOverlay.isHidden = true
        refreshWebContentPresentation()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        updateDisplayedURL(from: webView.url)
        showLoadedState("已载入：\(currentURLString)")
        refreshPagePresentation()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        if let message = navigationErrorMessage(error) {
            showLoadError(message)
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isRetired == false, webView === self.webView else {
            return
        }
        if let message = navigationErrorMessage(error) {
            showLoadError(message)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true,
           let requestedURL = navigationAction.request.url
        {
            let displayURL = BrowserURLNormalizer.displayURL(for: requestedURL)
            let transportURL = BrowserURLNormalizer.transportURL(for: displayURL)
            if transportURL != requestedURL {
                currentURLString = displayURL.absoluteString
                addressField.stringValue = currentURLString
                showLoadingState("正在载入：\(currentURLString)")
                decisionHandler(.cancel)
                webView.load(request(for: displayURL))
                return
            }
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        beginDownload(download)
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        beginDownload(download)
    }
}

extension BrowserPaneViewController: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let transportURL = navigationAction.request.url
        else {
            return nil
        }
        let displayURL = BrowserURLNormalizer.displayURL(for: transportURL)
        guard BrowserURLNormalizer.normalizedURL(displayURL.absoluteString) != nil else {
            return nil
        }
        currentURLString = displayURL.absoluteString
        addressField.stringValue = currentURLString
        showLoadingState("正在载入：\(currentURLString)")
        webView.load(request(for: displayURL))
        return nil
    }
}

extension BrowserPaneViewController: WKDownloadDelegate {
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard isRetired == false,
              let downloadsDirectory = downloadsDirectoryProvider()
        else {
            completionHandler(nil)
            finishDownload(download, errorMessage: "下载失败：无法访问下载目录")
            return
        }
        do {
            try fileManager.createDirectory(
                at: downloadsDirectory,
                withIntermediateDirectories: true
            )
            let destination = BrowserDownloadDestinationResolver.destinationURL(
                suggestedFilename: suggestedFilename,
                downloadsDirectory: downloadsDirectory,
                fileManager: fileManager
            )
            if let state = activeDownloads[ObjectIdentifier(download)] {
                state.filename = destination.lastPathComponent
                state.destinationURL = destination
            }
            updateStatus("正在下载：\(destination.lastPathComponent)")
            completionHandler(destination)
        } catch {
            completionHandler(nil)
            finishDownload(download, errorMessage: "下载失败：无法创建下载文件")
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        finishDownload(download)
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let message = (error as? URLError)?.code == .cancelled
            ? "下载已取消"
            : "下载失败：无法完成文件传输"
        finishDownload(download, errorMessage: message)
    }
}
