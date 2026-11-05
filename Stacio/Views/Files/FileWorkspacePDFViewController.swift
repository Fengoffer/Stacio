import AppKit
import PDFKit

@MainActor
public final class FileWorkspacePDFViewController: NSViewController {
    public let documentURL: URL
    public let pdfViewForTesting = PDFView()

    private let thumbnailView = PDFThumbnailView()
    private let pageLabel = NSTextField(labelWithString: "")
    private var thumbnailWidthConstraint: NSLayoutConstraint?
    private var pageObserver: NSObjectProtocol?

    public init(documentURL: URL) {
        self.documentURL = documentURL.standardizedFileURL
        super.init(nibName: nil, bundle: nil)
        title = documentURL.lastPathComponent
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: .windowBackgroundColor)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let thumbnailsButton = symbolButton(
            "sidebar.left",
            label: "缩略图",
            action: #selector(toggleThumbnails)
        )
        let previousButton = symbolButton(
            "chevron.left",
            label: "上一页",
            action: #selector(previousPage)
        )
        let nextButton = symbolButton(
            "chevron.right",
            label: "下一页",
            action: #selector(nextPage)
        )
        let zoomOutButton = symbolButton(
            "minus.magnifyingglass",
            label: "缩小",
            action: #selector(zoomOut)
        )
        let zoomInButton = symbolButton(
            "plus.magnifyingglass",
            label: "放大",
            action: #selector(zoomIn)
        )
        let fitButton = symbolButton(
            "arrow.up.left.and.arrow.down.right",
            label: "适合页面",
            action: #selector(fitPage)
        )
        let openButton = symbolButton(
            "arrow.up.forward.app",
            label: "使用默认应用打开",
            action: #selector(openWithDefaultApplication)
        )
        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.alignment = .center
        pageLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        [
            thumbnailsButton,
            previousButton,
            pageLabel,
            nextButton,
            zoomOutButton,
            zoomInButton,
            fitButton,
            NSView(),
            openButton
        ].forEach(toolbar.addArrangedSubview)

        let pdfView = pdfViewForTesting
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.setAccessibilityIdentifier("Stacio.FileWorkspacePDF.document")
        pdfView.document = PDFDocument(url: documentURL)

        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 104, height: 140)
        thumbnailView.isHidden = true
        thumbnailView.setAccessibilityIdentifier("Stacio.FileWorkspacePDF.thumbnails")
        let thumbnailScroll = NSScrollView()
        thumbnailScroll.documentView = thumbnailView
        thumbnailScroll.hasVerticalScroller = true
        thumbnailScroll.autohidesScrollers = true
        thumbnailScroll.borderType = .noBorder
        thumbnailScroll.isHidden = true

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        thumbnailScroll.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(thumbnailScroll)
        root.addSubview(pdfView)
        let thumbnailWidth = thumbnailScroll.widthAnchor.constraint(equalToConstant: 0)
        thumbnailWidthConstraint = thumbnailWidth
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            thumbnailScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            thumbnailScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            thumbnailScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            thumbnailWidth,
            pdfView.leadingAnchor.constraint(equalTo: thumbnailScroll.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updatePageLabel() }
        }
        updatePageLabel()
    }

    deinit {
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
    }

    private func symbolButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func updatePageLabel() {
        guard let document = pdfViewForTesting.document else {
            pageLabel.stringValue = "0 / 0"
            return
        }
        let currentIndex = pdfViewForTesting.currentPage.map(document.index(for:)) ?? 0
        pageLabel.stringValue = "\(min(currentIndex + 1, document.pageCount)) / \(document.pageCount)"
    }

    @objc private func toggleThumbnails() {
        guard let thumbnailScroll = thumbnailView.enclosingScrollView else { return }
        let willShow = thumbnailScroll.isHidden
        thumbnailScroll.isHidden = false
        thumbnailView.isHidden = false
        thumbnailWidthConstraint?.constant = willShow ? 148 : 0
        if willShow == false {
            thumbnailScroll.isHidden = true
            thumbnailView.isHidden = true
        }
    }

    @objc private func previousPage() {
        pdfViewForTesting.goToPreviousPage(nil)
    }

    @objc private func nextPage() {
        pdfViewForTesting.goToNextPage(nil)
    }

    @objc private func zoomOut() {
        pdfViewForTesting.zoomOut(nil)
    }

    @objc private func zoomIn() {
        pdfViewForTesting.zoomIn(nil)
    }

    @objc private func fitPage() {
        pdfViewForTesting.autoScales = true
    }

    @objc private func openWithDefaultApplication() {
        NSWorkspace.shared.open(documentURL)
    }
}

@MainActor
public final class FileWorkspacePDFWindowController: NSWindowController, NSWindowDelegate {
    public let pdfViewController: FileWorkspacePDFViewController
    public var onClose: ((FileWorkspacePDFWindowController) -> Void)?

    private let temporaryRoot: URL?
    private var didCleanTemporaryRoot = false

    public init(documentURL: URL, temporaryRoot: URL? = nil) {
        pdfViewController = FileWorkspacePDFViewController(documentURL: documentURL)
        self.temporaryRoot = temporaryRoot
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = documentURL.lastPathComponent
        window.contentViewController = pdfViewController
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowWillClose(_ notification: Notification) {
        cleanupTemporaryRoot()
        onClose?(self)
    }

    deinit {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private func cleanupTemporaryRoot() {
        guard didCleanTemporaryRoot == false, let temporaryRoot else { return }
        didCleanTemporaryRoot = true
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}
