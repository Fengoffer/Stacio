import AppKit
@preconcurrency import QuickLookUI

public final class FileWorkspaceQuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURLs: [URL] = []
    private var temporaryRoots: [URL] = []
    private let openURL: (URL) -> Bool

    public override convenience init() {
        self.init(openURL: { NSWorkspace.shared.open($0) })
    }

    init(openURL: @escaping (URL) -> Bool) {
        self.openURL = openURL
        super.init()
    }

    public var previewURLsForTesting: [URL] {
        previewURLs
    }

    @MainActor
    public func present(urls: [URL], temporaryRoots: [URL] = []) {
        let normalizedURLs = urls.map(\.standardizedFileURL)
        guard normalizedURLs.isEmpty == false else { return }
        cleanupTemporaryRoots()
        previewURLs = normalizedURLs
        self.temporaryRoots = temporaryRoots

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    public func closePreview() {
        if let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
            detach(from: panel)
        }
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
        previewURLs = []
        cleanupTemporaryRoots()
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
}
