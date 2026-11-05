import AppKit
@preconcurrency import QuickLookUI

public final class FileWorkspaceQuickLookCoordinator: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURLs: [URL] = []
    private var temporaryRoots: [URL] = []
    private let openURL: (URL) -> Bool
    private weak var responderWindow: NSWindow?
    private weak var displacedWindowNextResponder: NSResponder?
    private var loadingPanel: NSPanel?
    private weak var loadingParentWindow: NSWindow?
    private weak var loadingLabel: NSTextField?
    private var loadingPresentationActive = false

    public override convenience init() {
        self.init(openURL: { NSWorkspace.shared.open($0) })
    }

    init(openURL: @escaping (URL) -> Bool) {
        self.openURL = openURL
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var previewURLsForTesting: [URL] {
        previewURLs
    }

    var isLoadingForTesting: Bool {
        loadingPresentationActive
    }

    var loadingPanelForTesting: NSPanel? {
        loadingPanel
    }

    @MainActor
    func showLoading(message: String = "正在准备快速预览...") {
        loadingPresentationActive = true
        if let loadingPanel {
            loadingLabel?.stringValue = message
            positionLoadingPanel(loadingPanel)
            loadingPanel.orderFront(nil)
            return
        }

        let panel = makeLoadingPanel(message: message)
        loadingPanel = panel
        positionLoadingPanel(panel)
        panel.orderFront(nil)
    }

    @MainActor
    func dismissLoading() {
        loadingPresentationActive = false
        if let loadingPanel, let loadingParentWindow {
            loadingParentWindow.removeChildWindow(loadingPanel)
        }
        loadingPanel?.orderOut(nil)
        loadingPanel = nil
        loadingParentWindow = nil
        loadingLabel = nil
    }

    @MainActor
    public func present(urls: [URL], temporaryRoots: [URL] = []) {
        let normalizedURLs = urls.map(\.standardizedFileURL)
        guard normalizedURLs.isEmpty == false else { return }
        dismissLoading()
        cleanupTemporaryRoots()
        previewURLs = normalizedURLs
        self.temporaryRoots = temporaryRoots

        guard let panel = QLPreviewPanel.shared() else { return }
        installPreviewPanelController()
        panel.updateController()
        // QLPreviewPanel is process-wide. A previously active file workspace can
        // remain its controller after focus moves to another split or tab, so
        // reclaim the data source and delegate explicitly for the current request.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    public func closePreview() {
        dismissLoading()
        if let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
            detach(from: panel)
        }
        uninstallPreviewPanelController()
        previewURLs = []
        cleanupTemporaryRoots()
    }

    @MainActor
    @discardableResult
    public func openCurrentWithDefaultApplication() -> Bool {
        guard previewURLs.isEmpty == false else { return false }
        let requestedIndex = QLPreviewPanel.shared()?.currentPreviewItemIndex ?? 0
        let index = previewURLs.indices.contains(requestedIndex) ? requestedIndex : 0
        return openURL(previewURLs[index])
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as QLPreviewItem
    }

    public func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        if let panel {
            detach(from: panel)
        }
        uninstallPreviewPanelController()
        previewURLs = []
        cleanupTemporaryRoots()
    }

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        detach(from: panel)
    }

    deinit {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func cleanupTemporaryRoots() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
    }

    private func detach(from panel: QLPreviewPanel) {
        if panel.dataSource === self {
            panel.dataSource = nil
        }
        if panel.delegate === self {
            panel.delegate = nil
        }
    }

    @MainActor
    private func makeLoadingPanel(message: String) -> NSPanel {
        let contentSize = NSSize(width: 292, height: 84)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let materialView = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 12
        materialView.layer?.masksToBounds = true

        let progressIndicator = NSProgressIndicator()
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        progressIndicator.setAccessibilityLabel("正在准备快速预览")

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        loadingLabel = label

        materialView.addSubview(progressIndicator)
        materialView.addSubview(label)
        NSLayoutConstraint.activate([
            progressIndicator.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 22),
            progressIndicator.centerYAnchor.constraint(equalTo: materialView.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 20),
            progressIndicator.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -22),
            label.centerYAnchor.constraint(equalTo: materialView.centerYAnchor)
        ])
        panel.contentView = materialView
        return panel
    }

    @MainActor
    private func positionLoadingPanel(_ panel: NSPanel) {
        if let previousParent = loadingParentWindow, previousParent !== NSApp.keyWindow {
            previousParent.removeChildWindow(panel)
            loadingParentWindow = nil
        }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else {
            panel.center()
            return
        }
        if loadingParentWindow !== parent {
            parent.addChildWindow(panel, ordered: .above)
            loadingParentWindow = parent
        }
        let parentFrame = parent.frame
        let panelFrame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: parentFrame.midX - panelFrame.width / 2,
            y: parentFrame.midY - panelFrame.height / 2
        ))
    }

    @MainActor
    private func installPreviewPanelController() {
        guard responderWindow == nil,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        responderWindow = window
        displacedWindowNextResponder = window.nextResponder
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    @MainActor
    private func uninstallPreviewPanelController() {
        guard let responderWindow else { return }
        if responderWindow.nextResponder === self {
            responderWindow.nextResponder = displacedWindowNextResponder
        }
        self.responderWindow = nil
        displacedWindowNextResponder = nil
        nextResponder = nil
    }
}
