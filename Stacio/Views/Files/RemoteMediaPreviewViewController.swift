import AppKit
import WebKit

public enum RemoteMediaPreviewMode: Equatable {
    case image
    case video
    case audio
    case unsupported
}

public final class RemoteMediaPreviewViewController: NSViewController, WKNavigationDelegate {
    public private(set) var localURL: URL
    public var onCloseRequested: (() -> Void)?

    private var documents: [RemoteMediaPreviewDocument]
    private var activeDocumentID: String
    private var previewMode: RemoteMediaPreviewMode
    private let tabBar = NSStackView()
    private var webView: WKWebView?

    public init(localURL: URL) {
        self.localURL = localURL
        let document = RemoteMediaPreviewDocument(localURL: localURL)
        self.documents = [document]
        self.activeDocumentID = document.id
        self.previewMode = document.previewMode
        super.init(nibName: nil, bundle: nil)
        title = localURL.lastPathComponent
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var previewModeForTesting: RemoteMediaPreviewMode {
        previewMode
    }

    public var tabTitlesForTesting: [String] {
        documents.map(\.fileName)
    }

    public var activeFileNameForTesting: String {
        activeDocument?.fileName ?? localURL.lastPathComponent
    }

    public func openDocument(localURL: URL) {
        if let existing = documents.first(where: { $0.localURL.path == localURL.path }) {
            activateDocument(id: existing.id)
            return
        }
        let document = RemoteMediaPreviewDocument(localURL: localURL)
        documents.append(document)
        activateDocument(id: document.id)
    }

    public func switchToDocumentForTesting(fileName: String) {
        guard let document = documents.first(where: { $0.fileName == fileName }) else {
            return
        }
        activateDocument(id: document.id)
    }

    public func closeDocumentForTesting(fileName: String) {
        guard let document = documents.first(where: { $0.fileName == fileName }) else {
            return
        }
        closeDocument(id: document.id)
    }

    public override func loadView() {
        let root = StacioAppearanceRefreshView()
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: NSColor.windowBackgroundColor)
        root.setAccessibilityIdentifier("Stacio.MediaPreview.root")

        let tabs = makeTabBar()
        let content = makeWebView()
        root.addSubview(tabs)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 32),

            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: tabs.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        reloadTabs()
        loadPreviewHTML()
    }

    private static func previewMode(for localURL: URL) -> RemoteMediaPreviewMode {
        switch StacioFileDisplay.contentKind(forFileName: localURL.lastPathComponent) {
        case .image:
            return .image
        case .video:
            return .video
        case .audio:
            return .audio
        case .text, .other:
            return .unsupported
        }
    }

    private func makeTabBar() -> NSScrollView {
        tabBar.orientation = .horizontal
        tabBar.alignment = .height
        tabBar.spacing = 1
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setAccessibilityIdentifier("Stacio.MediaPreview.tabs")

        let scrollView = NSScrollView()
        scrollView.documentView = tabBar
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = StacioDesignSystem.theme.controlBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsAirPlayForMediaPlayback = true
        let previewWebView = WKWebView(frame: .zero, configuration: configuration)
        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        previewWebView.navigationDelegate = self
        previewWebView.setAccessibilityIdentifier("Stacio.MediaPreview.webView")
        previewWebView.setValue(false, forKey: "drawsBackground")
        webView = previewWebView
        return previewWebView
    }

    private func loadPreviewHTML() {
        guard let activeDocument else {
            return
        }
        localURL = activeDocument.localURL
        previewMode = activeDocument.previewMode
        title = activeDocument.fileName
        webView?.loadHTMLString(
            mediaHTML(),
            baseURL: activeDocument.localURL.deletingLastPathComponent()
        )
    }

    private func mediaHTML() -> String {
        let activeDocument = activeDocument ?? RemoteMediaPreviewDocument(localURL: localURL)
        let fileURLString = jsonString(activeDocument.localURL.absoluteString)
        let fileName = jsonString(activeDocument.fileName)
        let mode = switch previewMode {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .unsupported: "unsupported"
        }
        let fileSize = fileSizeText()
        return #"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self' file: data: blob: 'unsafe-inline'; img-src 'self' file: data: blob:; media-src 'self' file: data: blob:;">
  <style>
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: #111318; color: #f3f5f8; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    #root { width: 100%; height: 100%; display: grid; grid-template-rows: 38px minmax(0, 1fr); }
    #toolbar { display: flex; align-items: center; justify-content: center; gap: 8px; border-bottom: 1px solid rgba(255,255,255,.12); background: rgba(0,0,0,.2); }
    button { appearance: none; border: 1px solid rgba(255,255,255,.18); border-radius: 6px; background: rgba(255,255,255,.08); color: inherit; height: 26px; padding: 0 10px; font: inherit; font-size: 12px; }
    button:hover { background: rgba(255,255,255,.15); }
    #stage { min-width: 0; min-height: 0; display: flex; align-items: center; justify-content: center; overflow: auto; }
    img { max-width: min(100%, 1600px); max-height: 100%; object-fit: contain; transform-origin: center center; cursor: zoom-in; }
    img.original { max-width: none; max-height: none; cursor: zoom-out; }
    audio { width: min(720px, calc(100% - 48px)); }
    video { width: min(1100px, calc(100% - 48px)); max-height: calc(100% - 48px); background: #000; }
    .info { display: grid; gap: 10px; text-align: center; color: #aab2c2; font-size: 13px; padding: 32px; }
    .name { color: #f5f7fb; font-size: 16px; font-weight: 600; }
  </style>
</head>
<body>
  <div id="root">
    <div id="toolbar"></div>
    <div id="stage"></div>
  </div>
  <script>
    const fileURL = \#(fileURLString);
    const fileName = \#(fileName);
    const fileSize = "\#(fileSize)";
    const mode = "\#(mode)";
    const toolbar = document.getElementById('toolbar');
    const stage = document.getElementById('stage');
    let zoom = 1;
    let rotation = 0;
    let original = false;

    function button(label, action) {
      const element = document.createElement('button');
      element.textContent = label;
      element.addEventListener('click', action);
      toolbar.appendChild(element);
      return element;
    }

    function renderInfo(message) {
      toolbar.style.display = 'none';
      stage.innerHTML = `<div class="info"><div class="name">${fileName}</div><div>${message}</div><div>${fileSize}</div></div>`;
    }

    function renderImage() {
      button('-', () => { zoom = Math.max(0.2, zoom - 0.1); updateImage(); });
      button('+', () => { zoom = Math.min(5, zoom + 0.1); updateImage(); });
      button('1:1', () => { original = !original; updateImage(); });
      button('⟳', () => { rotation = (rotation + 90) % 360; updateImage(); });
      const img = document.createElement('img');
      img.src = fileURL;
      img.alt = fileName;
      img.addEventListener('click', () => { original = !original; updateImage(); });
      stage.appendChild(img);
      window.updateImage = function() {
        img.classList.toggle('original', original);
        img.style.transform = `scale(${zoom}) rotate(${rotation}deg)`;
      };
      updateImage();
    }

    function renderAudio() {
      toolbar.style.display = 'none';
      stage.innerHTML = `<div class="info"><div class="name">${fileName}</div><audio controls preload="metadata" src="${fileURL}"></audio><div>${fileSize}</div></div>`;
    }

    function renderVideo() {
      toolbar.style.display = 'none';
      stage.innerHTML = `<video controls preload="metadata" src="${fileURL}"></video>`;
    }

    if (mode === 'image') {
      renderImage();
    } else if (mode === 'audio') {
      renderAudio();
    } else if (mode === 'video') {
      renderVideo();
    } else {
      renderInfo('当前文件类型不支持媒体预览');
    }
  </script>
</body>
</html>
"""#
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return string
    }

    private func activateDocument(id: String) {
        guard let document = documents.first(where: { $0.id == id }) else {
            return
        }
        activeDocumentID = document.id
        localURL = document.localURL
        previewMode = document.previewMode
        reloadTabs()
        loadPreviewHTML()
    }

    private func closeDocument(id: String) {
        guard documents.count > 1,
              let index = documents.firstIndex(where: { $0.id == id })
        else {
            onCloseRequested?()
            return
        }
        let wasActive = documents[index].id == activeDocumentID
        documents.remove(at: index)
        if wasActive {
            let nextIndex = min(index, documents.count - 1)
            activeDocumentID = documents[nextIndex].id
            loadPreviewHTML()
        }
        reloadTabs()
    }

    private func reloadTabs() {
        guard isViewLoaded else {
            return
        }
        tabBar.arrangedSubviews.forEach { view in
            tabBar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for document in documents {
            tabBar.addArrangedSubview(makeTab(for: document))
        }
    }

    private func makeTab(for document: RemoteMediaPreviewDocument) -> NSView {
        let tab = RemoteMediaPreviewTabButton()
        tab.documentID = document.id
        tab.bezelStyle = .regularSquare
        tab.isBordered = false
        tab.title = ""
        tab.target = self
        tab.action = #selector(tabButtonPressed(_:))
        tab.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(tab, color: tabBackgroundColor(isActive: document.id == activeDocumentID))
        StacioDesignSystem.setLayerBorderColor(tab, color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.35))
        tab.layer?.borderWidth = 0
        tab.setAccessibilityIdentifier("Stacio.MediaPreview.tab.\(document.fileName)")
        tab.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭") ?? NSImage(),
            target: self,
            action: #selector(tabCloseButtonPressed(_:))
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier(document.id)
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        closeButton.toolTip = "关闭预览"
        closeButton.setAccessibilityIdentifier("Stacio.MediaPreview.close.\(document.fileName)")
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: document.fileName)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        tab.addSubview(closeButton)
        tab.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            tab.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            tab.heightAnchor.constraint(equalToConstant: 32),

            closeButton.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: tab.centerYAnchor)
        ])
        return tab
    }

    private func tabBackgroundColor(isActive: Bool) -> NSColor {
        if isActive {
            return NSColor.textBackgroundColor.withAlphaComponent(0.9)
        }
        return NSColor.clear
    }

    private var activeDocument: RemoteMediaPreviewDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    private func fileSizeText() -> String {
        let url = activeDocument?.localURL ?? localURL
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        return "\(byteCount) B"
    }

    @objc private func tabButtonPressed(_ sender: NSButton) {
        guard let tabButton = sender as? RemoteMediaPreviewTabButton else {
            return
        }
        activateDocument(id: tabButton.documentID)
    }

    @objc private func tabCloseButtonPressed(_ sender: NSButton) {
        guard let documentID = sender.identifier?.rawValue else {
            return
        }
        closeDocument(id: documentID)
    }
}

private final class RemoteMediaPreviewTabButton: NSButton {
    var documentID = ""
}

private struct RemoteMediaPreviewDocument {
    let id: String
    let localURL: URL
    let previewMode: RemoteMediaPreviewMode

    init(localURL: URL) {
        id = UUID().uuidString
        self.localURL = localURL
        previewMode = Self.previewMode(for: localURL)
    }

    var fileName: String {
        localURL.lastPathComponent
    }

    private static func previewMode(for localURL: URL) -> RemoteMediaPreviewMode {
        switch StacioFileDisplay.contentKind(forFileName: localURL.lastPathComponent) {
        case .image:
            return .image
        case .video:
            return .video
        case .audio:
            return .audio
        case .text, .other:
            return .unsupported
        }
    }
}

@MainActor
public final class RemoteMediaPreviewWindowController: NSWindowController, NSWindowDelegate {
    public let previewViewController: RemoteMediaPreviewViewController
    public var onClose: (@MainActor (RemoteMediaPreviewWindowController) -> Void)?

    public init(previewViewController: RemoteMediaPreviewViewController) {
        self.previewViewController = previewViewController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = previewViewController.localURL.lastPathComponent
        window.contentViewController = previewViewController
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
