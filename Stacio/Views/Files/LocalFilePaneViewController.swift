import AppKit

public typealias LocalDirectoryContentsProviding = @Sendable (URL) throws -> [URL]
public typealias LocalFileTrashing = @Sendable (URL) throws -> Void

public protocol LocalDirectoryHistoryStoring: AnyObject {
    func recentDirectoryURLs() -> [URL]
    func recordDirectoryURL(_ url: URL)
}

public final class UserDefaultsLocalDirectoryHistoryStore: LocalDirectoryHistoryStoring {
    public static let shared = UserDefaultsLocalDirectoryHistoryStore()

    private let defaults: UserDefaults
    private let key: String
    private let maximumEntryCount: Int
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "stacio.files.local.recentDirectories",
        maximumEntryCount: Int = 8
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public func recentDirectoryURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        return (defaults.stringArray(forKey: key) ?? []).compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    public func recordDirectoryURL(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        let existing = defaults.stringArray(forKey: key) ?? []
        let paths = [path] + existing.filter {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path != path
        }
        defaults.set(Array(paths.prefix(maximumEntryCount)), forKey: key)
    }
}

final class FileWorkspaceToolbarButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

private enum LocalDirectoryLoadResult: Sendable {
    case success([LocalFileRow])
    case failure(String)
}

public struct LocalFileWorkspaceActions {
    public let reveal: (URL) -> Void
    public let open: (URL) -> Void

    public init(
        reveal: @escaping (URL) -> Void,
        open: @escaping (URL) -> Void
    ) {
        self.reveal = reveal
        self.open = open
    }

    public static var live: LocalFileWorkspaceActions {
        LocalFileWorkspaceActions(
            reveal: { url in
                NSWorkspace.shared.selectFile(
                    url.path,
                    inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                )
            },
            open: { url in
                _ = NSWorkspace.shared.open(url)
            }
        )
    }
}

public enum LocalFilePaneError: Error, Equatable, LocalizedError {
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "本地文件路径无效。"
        }
    }
}

enum LocalFileDragPayload {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? URL)?.standardizedFileURL } ?? []
    }
}

public final class LocalFilePaneTableView: NSTableView {
    var rowContextMenuProvider: ((Int) -> NSMenu?)?
    var onQuickLookRequested: (() -> Void)?

    public override func menu(for event: NSEvent) -> NSMenu? {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        if clickedRow >= 0, selectedRowIndexes.contains(clickedRow) == false {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        } else if clickedRow < 0 {
            deselectAll(nil)
        }
        return rowContextMenuProvider?(clickedRow)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        {
            onQuickLookRequested?()
            return
        }
        super.keyDown(with: event)
    }
}

public final class LocalFilePaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let runtimeID: String
    public private(set) var directoryURL: URL
    public let tableView = LocalFilePaneTableView()
    public var onRemoteSelectionsDropped: (([RemoteFileSelection], URL) -> Void)?
    public var onRemoteSelectionsDroppedWithSource: ((String?, [RemoteFileSelection], URL) -> Void)?
    public var onOpenFile: ((URL) -> Void)?
    public var onQuickLookURLs: (([URL]) -> Void)?
    var onRequestClose: (() -> Void)? {
        didSet { updateCloseButtonPlacement() }
    }
    public var workspaceClipboard: FileWorkspaceClipboard = .shared
    public var conflictResolver: RemoteFileConflictResolving = SettingsBackedRemoteFileConflictResolver()
    public var transferTargetsProvider: (() -> [FileWorkspaceTransferTarget])?
    public var onTransferLocalURLsToTarget: (([URL], FileWorkspaceTransferTarget) -> Void)?
    public var onPastePayload: ((FileWorkspaceClipboardPayload, URL) -> Void)?
    public weak var localFileTransferScheduler: LocalFileTransferScheduling?
    public var onUploadLocalPaths: (([String]) -> Void)? {
        didSet {
            guard isViewLoaded else { return }
            uploadButton.isHidden = onUploadLocalPaths == nil
            updateActionStates()
        }
    }

    private let pathField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let parentButton = FileWorkspaceToolbarButton()
    private let refreshButton = FileWorkspaceToolbarButton()
    private let uploadButton = FileWorkspaceToolbarButton()
    private let revealButton = FileWorkspaceToolbarButton()
    private let openButton = FileWorkspaceToolbarButton()
    private let closeButton = FileWorkspaceToolbarButton()
    private let localDirectoryMenuButton = FileWorkspaceToolbarButton()
    private weak var toolbarStackView: NSStackView?
    private var rows: [LocalFileRow] = []
    private var statusText = ""
    private var fileActions: [String] = []
    private let workspaceActions: LocalFileWorkspaceActions
    private let fileOperationQueue: DispatchQueue
    private let directoryLoadQueue: DispatchQueue
    private let directoryContentsProvider: LocalDirectoryContentsProviding
    private let trashItem: LocalFileTrashing
    private let directoryHistoryStore: any LocalDirectoryHistoryStoring
    private var pendingTransferTargets: [Int: FileWorkspaceTransferTarget] = [:]
    private var propertiesWindowControllers: [FileWorkspacePropertiesWindowController] = []
    private var loadGeneration = 0
    private var sortOrder = FileWorkspaceTableSortOrder.initial
    private var isSynchronizingSortDescriptor = false

    public init(
        runtimeID: String,
        directoryURL: URL,
        title: String,
        workspaceActions: LocalFileWorkspaceActions = .live,
        directoryContentsProvider: @escaping LocalDirectoryContentsProviding = { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .isHiddenKey,
                    .contentModificationDateKey
                ],
                options: []
            )
        },
        trashItem: @escaping LocalFileTrashing = { url in
            _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        directoryHistoryStore: any LocalDirectoryHistoryStoring = UserDefaultsLocalDirectoryHistoryStore.shared
    ) {
        self.runtimeID = runtimeID
        self.directoryURL = directoryURL
        self.workspaceActions = workspaceActions
        self.directoryContentsProvider = directoryContentsProvider
        self.trashItem = trashItem
        self.directoryHistoryStore = directoryHistoryStore
        self.fileOperationQueue = DispatchQueue(
            label: "com.stacio.files.local-workspace.\(runtimeID)",
            qos: .userInitiated
        )
        self.directoryLoadQueue = DispatchQueue(
            label: "com.stacio.files.local-workspace.load.\(runtimeID)",
            qos: .userInitiated,
            attributes: .concurrent
        )
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = LocalFilesRootView()
        container.onRemoteSelectionsDropped = { [weak self] sourceRuntimeID, selections in
            self?.handleRemoteSelectionsDropped(selections, sourceRuntimeID: sourceRuntimeID)
        }
        container.onLocalURLsDropped = { [weak self] urls in
            guard let self else { return }
            _ = self.acceptLocalFileDrop(urls, destination: self.directoryURL)
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        configureButton(parentButton, symbol: "chevron.up", tooltip: "上一级", action: #selector(parentButtonPressed))
        configureButton(refreshButton, symbol: "arrow.clockwise", tooltip: "刷新本地目录", action: #selector(refreshButtonPressed))
        configureButton(uploadButton, symbol: "arrow.up.circle", tooltip: "上传选中项到远端", action: #selector(uploadButtonPressed))
        configureButton(revealButton, symbol: "scope", tooltip: "在访达中显示", action: #selector(revealButtonPressed))
        configureButton(openButton, symbol: "folder", tooltip: "在访达中打开", action: #selector(openButtonPressed))
        configureButton(closeButton, symbol: "xmark", tooltip: "关闭此本地目录", action: #selector(closeButtonPressed))
        configureButton(
            localDirectoryMenuButton,
            symbol: "chevron.down",
            tooltip: "常用本地目录",
            action: #selector(localDirectoryMenuButtonPressed(_:))
        )
        uploadButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.localUpload")
        closeButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.closeLocalPane")
        localDirectoryMenuButton.setAccessibilityIdentifier("Stacio.FileTransferBrowser.localDirectoryMenu")
        uploadButton.isHidden = onUploadLocalPaths == nil

        let localTitle = NSTextField(labelWithString: "本地")
        localTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        localTitle.textColor = StacioDesignSystem.theme.primaryTextColor
        localTitle.translatesAutoresizingMaskIntoConstraints = false

        let localSubtitle = NSTextField(labelWithString: "此 Mac")
        localSubtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        localSubtitle.textColor = StacioDesignSystem.theme.secondaryTextColor
        localSubtitle.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView(views: [localTitle, localSubtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 1
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setContentHuggingPriority(.required, for: .horizontal)

        let toolbar = NSStackView(views: [heading, parentButton, refreshButton, uploadButton, revealButton, openButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarStackView = toolbar
        updateCloseButtonPlacement()

        pathField.stringValue = directoryURL.path
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.target = self
        pathField.action = #selector(pathSubmitted)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setAccessibilityIdentifier("Stacio.FileTransferBrowser.localPath")
        StacioDesignSystem.styleTextField(pathField)

        let pathTitle = NSTextField(labelWithString: "本地")
        pathTitle.setContentHuggingPriority(.required, for: .horizontal)
        let pathControl = NSStackView(views: [pathField, localDirectoryMenuButton])
        pathControl.orientation = .horizontal
        pathControl.alignment = .centerY
        pathControl.spacing = 0
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pathBar = NSStackView(views: [pathTitle, pathControl])
        pathBar.orientation = .horizontal
        pathBar.alignment = .centerY
        pathBar.spacing = 6
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("Stacio.LocalFiles.status")

        tableView.addTableColumn(makeColumn(identifier: "name", title: "名称", width: 240))
        tableView.addTableColumn(makeColumn(identifier: "size", title: "大小", width: 92))
        tableView.addTableColumn(makeColumn(identifier: "time", title: "时间", width: 118))
        synchronizeTableSortDescriptor()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = StacioFileDisplay.tableRowHeight
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedEntry)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.registerForDraggedTypes([
            RemoteFileDragPayload.pasteboardType,
            .fileURL
        ])
        tableView.rowContextMenuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.onQuickLookRequested = { [weak self] in
            self?.quickLookSelectedItems()
        }
        tableView.setAccessibilityIdentifier("Stacio.LocalFiles.table")
        StacioDesignSystem.styleTable(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(pathBar)
        container.addSubview(scrollView)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            pathBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            pathBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            pathBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            statusLabel.heightAnchor.constraint(equalToConstant: 18)
        ])

        view = container
        loadDirectory(recordAction: false)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("LocalFileCell.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        cell.subviews.forEach { $0.removeFromSuperview() }

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.font = StacioFileDisplay.tableTextFont
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = rows[row].value(for: tableColumn.identifier.rawValue)
        cell.textField = textField

        if tableColumn.identifier.rawValue == "name" {
            let imageView = NSImageView(image: StacioFileDisplay.localIcon(for: rows[row]))
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityLabel(StacioFileDisplay.iconAccessibilityLabel(for: rows[row]))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: StacioFileDisplay.iconDimension),
                imageView.heightAnchor.constraint(equalToConstant: StacioFileDisplay.iconDimension),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            cell.imageView = nil
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    public func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        return NSURL(fileURLWithPath: rows[row].url.path)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionStates()
    }

    public func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard isSynchronizingSortDescriptor == false,
              let descriptor = tableView.sortDescriptors.first,
              let order = FileWorkspaceTableSortOrder(descriptor: descriptor)
        else { return }
        applySortOrder(order, synchronizesDescriptor: false)
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let hasRemoteSelections = RemoteFileDragPayload.selections(
            from: info.draggingPasteboard
        ).isEmpty == false
        let hasLocalURLs = LocalFileDragPayload.urls(from: info.draggingPasteboard).isEmpty == false
        guard hasRemoteSelections || hasLocalURLs else {
            return []
        }
        if rows.indices.contains(row), rows[row].isDirectory {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return .copy
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let destination = destinationURL(forProposedRow: row)
        let selections = RemoteFileDragPayload.selections(from: info.draggingPasteboard)
        if selections.isEmpty == false {
            routeRemoteSelectionsDropped(
                selections,
                sourceRuntimeID: RemoteFileDragPayload.sourceRuntimeID(from: info.draggingPasteboard),
                destination: destination
            )
            return true
        }
        return acceptLocalFileDrop(
            LocalFileDragPayload.urls(from: info.draggingPasteboard),
            destination: destination
        )
    }

    public var statusTextForTesting: String {
        statusText
    }

    public var currentPathForTesting: String {
        directoryURL.path
    }

    public var fileActionsForTesting: [String] {
        fileActions
    }

    public var localPathFieldIsEditableForTesting: Bool {
        pathField.isEditable
    }

    public var localPathTextForTesting: String {
        pathField.stringValue
    }

    public var uploadButtonIsEnabledForTesting: Bool {
        uploadButton.isEnabled
    }

    public var uploadButtonIsHiddenForTesting: Bool {
        uploadButton.isHidden
    }

    public var localDirectoryMenuButtonIsVisibleForTesting: Bool {
        localDirectoryMenuButton.superview != nil && localDirectoryMenuButton.isHidden == false
    }

    public var localDirectoryMenuTitlesForTesting: [String] {
        makeLocalDirectoryMenu().items
            .filter { $0.isSeparatorItem == false }
            .map(\.title)
    }

    public var recentLocalDirectoryPathsForTesting: [String] {
        directoryHistoryStore.recentDirectoryURLs().map(\.path)
    }

    @discardableResult
    public func performLocalDirectoryMenuSelectionForTesting(path: String) -> Bool {
        let menu = makeLocalDirectoryMenu()
        let item = menu.items.lazy.compactMap { rootItem -> NSMenuItem? in
            if rootItem.representedObject as? String == path {
                return rootItem
            }
            return rootItem.submenu?.items.first {
                $0.representedObject as? String == path
            }
        }.first
        guard let item,
              let action = item.action
        else {
            return false
        }
        return NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    public var toolbarIconButtonSizesForTesting: [NSSize] {
        [parentButton, refreshButton, uploadButton, revealButton, openButton].map(\.frame.size)
    }

    public var visibleTextSnapshotForTesting: String {
        let rowText = rows
            .map { "\($0.name)\n\($0.size)\n\($0.time)\n" }
            .joined()
        return "\(statusText)\n\(rowText)"
    }

    public var displayedItemNamesForTesting: [String] {
        rows.map(\.name)
    }

    public func sortColumnForTesting(identifier: String) {
        guard let order = sortOrder.toggled(for: identifier) else { return }
        applySortOrder(order, synchronizesDescriptor: true)
    }

    public func contextMenuTitlesForTesting(row: Int) -> [String] {
        contextMenu(forRow: row).items
            .filter { $0.isSeparatorItem == false }
            .map(\.title)
    }

    public func refreshDirectory() {
        loadDirectory(recordAction: true)
    }

    public func navigate(to directoryURL: URL, recordAction: Bool = true) {
        let requestedDirectory = directoryURL.standardizedFileURL
        guard isViewLoaded else {
            self.directoryURL = requestedDirectory
            return
        }
        requestDirectoryLoad(
            at: requestedDirectory,
            recordAction: recordAction,
            commitsNavigation: true,
            preservesRowsOnFailure: true
        )
    }

    public func submitLocalPathForTesting(_ path: String) {
        pathField.stringValue = path
        submitPathFieldValue()
    }

    public func selectLocalItemsForTesting(named names: Set<String>) {
        let indexes = IndexSet(rows.enumerated().compactMap { index, row in
            names.contains(row.name) ? index : nil
        })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        updateActionStates()
    }

    public func performSelectedUploadForTesting() {
        uploadSelectedItems()
    }

    public func performQuickLookForTesting() {
        quickLookSelectedItems()
    }

    public func performOpenSelectedEntryForTesting() {
        openSelectedEntry()
    }

    public func transferTargetMenuTitlesForTesting(row: Int) -> [String] {
        if rows.indices.contains(row), tableView.selectedRowIndexes.contains(row) == false {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return makeTransferTargetMenu().items.map(\.title)
    }

    public func performPasteForTesting() {
        pasteClipboardItems()
    }

    public func performRenameForTesting(to name: String) {
        renameSelectedItem(to: name)
    }

    public func performDeleteForTesting() {
        trashSelectedItems(confirming: false)
    }

    public func performCreateDirectoryForTesting(named name: String) {
        createDirectory(named: name)
    }

    public func acceptPastePayload(_ payload: FileWorkspaceClipboardPayload) {
        guard payload.localURLs.isEmpty == false else { return }
        performLocalCopyOrMove(payload, to: directoryURL)
    }

    @discardableResult
    func acceptLocalFileDrop(_ urls: [URL], destination: URL) -> Bool {
        let normalizedURLs = urls.map(\.standardizedFileURL)
        guard normalizedURLs.isEmpty == false else { return false }
        performLocalCopyOrMove(
            FileWorkspaceClipboardPayload(
                operation: .copy,
                sourceDeviceID: "local-drag",
                localURLs: normalizedURLs
            ),
            to: destination.standardizedFileURL
        )
        return true
    }

    private func loadDirectory(recordAction: Bool) {
        requestDirectoryLoad(
            at: directoryURL.standardizedFileURL,
            recordAction: recordAction,
            commitsNavigation: false,
            preservesRowsOnFailure: rows.isEmpty == false
        )
    }

    private func requestDirectoryLoad(
        at requestedDirectory: URL,
        recordAction: Bool,
        commitsNavigation: Bool,
        preservesRowsOnFailure: Bool
    ) {
        if recordAction {
            fileActions.append("refresh")
        }
        if isViewLoaded {
            pathField.stringValue = requestedDirectory.path
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        let contentsProvider = directoryContentsProvider
        updateStatus("正在读取本地路径：\(requestedDirectory.path)")
        directoryLoadQueue.async { [weak self] in
            let result = Self.loadRows(
                at: requestedDirectory,
                contentsProvider: contentsProvider
            )
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.loadGeneration == generation
                else { return }
                switch result {
                case .success(let rows):
                    if commitsNavigation {
                        self.directoryURL = requestedDirectory
                    }
                    self.rows = self.sortedRows(rows)
                    self.pathField.stringValue = requestedDirectory.path
                    self.directoryHistoryStore.recordDirectoryURL(requestedDirectory)
                    self.updateStatus("当前路径：\(requestedDirectory.path)")
                    self.reloadRows()
                case .failure(let message):
                    self.pathField.stringValue = self.directoryURL.path
                    if preservesRowsOnFailure == false {
                        self.rows = []
                        self.reloadRows()
                    }
                    self.updateStatus(message)
                }
            }
        }
    }

    public func revealCurrentPath() {
        fileActions.append("reveal")
        workspaceActions.reveal(directoryURL)
    }

    public func openCurrentPath() {
        fileActions.append("open")
        workspaceActions.open(directoryURL)
    }

    @objc private func refreshButtonPressed() {
        refreshDirectory()
    }

    @objc private func revealButtonPressed() {
        revealCurrentPath()
    }

    @objc private func openButtonPressed() {
        openCurrentPath()
    }

    @objc private func parentButtonPressed() {
        let parent = directoryURL.deletingLastPathComponent()
        guard parent.path != directoryURL.path else { return }
        navigate(to: parent)
    }

    @objc private func pathSubmitted() {
        submitPathFieldValue()
    }

    @objc private func localDirectoryMenuButtonPressed(_ sender: NSButton) {
        let menu = makeLocalDirectoryMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.maxY + 2),
            in: sender
        )
    }

    @objc private func localDirectoryMenuItemSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        navigateToLocalDirectory(atPath: path)
    }

    private func makeLocalDirectoryMenu() -> NSMenu {
        let menu = NSMenu(title: "常用本地目录")
        menu.autoenablesItems = false

        let recentMenu = NSMenu(title: "最近使用")
        recentMenu.autoenablesItems = false
        let recentURLs = directoryHistoryStore.recentDirectoryURLs()
        if recentURLs.isEmpty {
            let emptyItem = NSMenuItem(title: "暂无最近使用的目录", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for url in recentURLs {
                recentMenu.addItem(localDirectoryMenuItem(
                    title: (url.path as NSString).abbreviatingWithTildeInPath,
                    symbol: "clock",
                    url: url
                ))
            }
        }
        let recentItem = NSMenuItem(title: "最近使用", action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "最近使用")
        recentItem.submenu = recentMenu
        recentItem.isEnabled = recentURLs.isEmpty == false
        menu.addItem(recentItem)
        menu.addItem(.separator())

        for shortcut in Self.commonLocalDirectoryShortcuts() {
            menu.addItem(localDirectoryMenuItem(
                title: shortcut.title,
                symbol: shortcut.symbol,
                url: shortcut.url
            ))
        }
        return menu
    }

    private func localDirectoryMenuItem(title: String, symbol: String, url: URL) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(localDirectoryMenuItemSelected(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url.standardizedFileURL.path
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isEnabled = true
        return item
    }

    private func navigateToLocalDirectory(atPath path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        navigate(to: url)
    }

    private static func commonLocalDirectoryShortcuts() -> [(title: String, symbol: String, url: URL)] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        func userDirectory(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
            fileManager.urls(for: directory, in: .userDomainMask).first
                ?? home.appendingPathComponent(fallback, isDirectory: true)
        }
        return [
            ("共享", "person.2", URL(fileURLWithPath: "/Users/Shared", isDirectory: true)),
            ("桌面", "desktopcomputer", userDirectory(.desktopDirectory, fallback: "Desktop")),
            ("文稿", "doc", userDirectory(.documentDirectory, fallback: "Documents")),
            ("下载", "arrow.down.circle", userDirectory(.downloadsDirectory, fallback: "Downloads")),
            ("图片", "photo", userDirectory(.picturesDirectory, fallback: "Pictures")),
            ("音乐", "music.note", userDirectory(.musicDirectory, fallback: "Music")),
            ("影片", "film", userDirectory(.moviesDirectory, fallback: "Movies"))
        ]
    }

    @objc private func uploadButtonPressed() {
        uploadSelectedItems()
    }

    private func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu(title: "本地文件")
        menu.autoenablesItems = false
        let hasSelection = selectedLocalPaths.isEmpty == false
        if rows.indices.contains(row) {
            menu.addItem(contextMenuItem(
                title: rows[row].isDirectory ? "打开文件夹" : "使用 Stacio 打开",
                symbol: rows[row].isDirectory ? "folder" : "doc",
                action: #selector(openContextSelection)
            ))
            let previewItem = contextMenuItem(
                title: "快速查看",
                symbol: "eye",
                action: #selector(quickLookContextSelection)
            )
            previewItem.isEnabled = hasSelection
            menu.addItem(previewItem)
            menu.addItem(.separator())
            let copyItem = contextMenuItem(
                title: "复制",
                symbol: "doc.on.doc",
                action: #selector(copyContextSelection)
            )
            copyItem.isEnabled = hasSelection
            menu.addItem(copyItem)
            let cutItem = contextMenuItem(
                title: "剪切",
                symbol: "scissors",
                action: #selector(cutContextSelection)
            )
            cutItem.isEnabled = hasSelection
            menu.addItem(cutItem)
        }

        let pasteItem = contextMenuItem(
            title: "粘贴",
            symbol: "doc.on.clipboard",
            action: #selector(pasteContextSelection)
        )
        pasteItem.isEnabled = workspaceClipboard.resolvedPayload() != nil
        menu.addItem(pasteItem)

        let transferItem = contextMenuItem(
            title: "传输到",
            symbol: "arrow.left.arrow.right",
            action: nil
        )
        transferItem.submenu = makeTransferTargetMenu()
        transferItem.isEnabled = hasSelection && transferItem.submenu?.items.contains(where: \.isEnabled) == true
        menu.addItem(transferItem)

        if rows.indices.contains(row) {
            menu.addItem(.separator())
            let renameItem = contextMenuItem(
                title: "重命名...",
                symbol: "pencil",
                action: #selector(renameContextSelection)
            )
            renameItem.isEnabled = selectedLocalURLs.count == 1
            menu.addItem(renameItem)
            let deleteItem = contextMenuItem(
                title: "移到废纸篓",
                symbol: "trash",
                action: #selector(deleteContextSelection)
            )
            deleteItem.isEnabled = hasSelection
            menu.addItem(deleteItem)
            menu.addItem(.separator())
            menu.addItem(contextMenuItem(
                title: "在访达中显示",
                symbol: "scope",
                action: #selector(revealContextSelection)
            ))
            menu.addItem(contextMenuItem(
                title: "复制路径",
                symbol: "doc.on.doc",
                action: #selector(copyContextSelectionPaths)
            ))
            let propertiesItem = contextMenuItem(
                title: "属性...",
                symbol: "info.circle",
                action: #selector(propertiesContextSelection)
            )
            propertiesItem.isEnabled = selectedLocalURLs.count == 1
            menu.addItem(propertiesItem)
            let permissionsItem = contextMenuItem(
                title: "权限...",
                symbol: "lock",
                action: #selector(permissionsContextSelection)
            )
            permissionsItem.isEnabled = selectedLocalURLs.count == 1
            menu.addItem(permissionsItem)
            menu.addItem(.separator())
        }
        menu.addItem(contextMenuItem(
            title: "新建文件夹",
            symbol: "folder.badge.plus",
            action: #selector(newFolderContextSelection)
        ))
        menu.addItem(contextMenuItem(
            title: "刷新",
            symbol: "arrow.clockwise",
            action: #selector(refreshButtonPressed)
        ))
        return menu
    }

    private func contextMenuItem(title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func makeTransferTargetMenu() -> NSMenu {
        let menu = NSMenu(title: "传输到")
        menu.autoenablesItems = false
        pendingTransferTargets = [:]
        let targets = (transferTargetsProvider?() ?? []).filter { $0.deviceID != runtimeID }
        if targets.isEmpty {
            let empty = NSMenuItem(title: "没有其他可用设备", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for (index, target) in targets.enumerated() {
            let tag = 2_000 + index
            pendingTransferTargets[tag] = target
            let item = NSMenuItem(
                title: target.title,
                action: #selector(transferToContextTarget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = tag
            item.image = NSImage(
                systemSymbolName: target.kind.isLocal ? "folder" : "server.rack",
                accessibilityDescription: target.title
            )
            item.isEnabled = onTransferLocalURLsToTarget != nil
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openContextSelection() {
        guard tableView.selectedRowIndexes.count == 1,
              let row = tableView.selectedRowIndexes.first,
              rows.indices.contains(row)
        else { return }
        if rows[row].isDirectory {
            navigate(to: rows[row].url)
        } else {
            openFile(rows[row].url)
        }
    }

    @objc private func quickLookContextSelection() {
        quickLookSelectedItems()
    }

    @objc private func uploadContextSelection() {
        uploadSelectedItems()
    }

    @objc private func copyContextSelection() {
        workspaceClipboard.storeLocalURLs(
            selectedLocalURLs,
            operation: .copy,
            sourceDeviceID: runtimeID
        )
        updateStatus("已复制 \(selectedLocalURLs.count) 项")
    }

    @objc private func cutContextSelection() {
        workspaceClipboard.storeLocalURLs(
            selectedLocalURLs,
            operation: .cut,
            sourceDeviceID: runtimeID
        )
        updateStatus("已剪切 \(selectedLocalURLs.count) 项")
    }

    @objc private func pasteContextSelection() {
        pasteClipboardItems()
    }

    @objc private func newFolderContextSelection() {
        let field = NSTextField(string: "新建文件夹")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "新建本地文件夹"
        alert.informativeText = directoryURL.path
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createDirectory(named: field.stringValue)
    }

    @objc private func transferToContextTarget(_ sender: NSMenuItem) {
        guard let target = pendingTransferTargets[sender.tag] else { return }
        onTransferLocalURLsToTarget?(selectedLocalURLs, target)
        pendingTransferTargets = [:]
    }

    @objc private func renameContextSelection() {
        guard let url = selectedLocalURLs.first else { return }
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "重命名本地项目"
        alert.informativeText = url.path
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameSelectedItem(to: field.stringValue)
    }

    @objc private func deleteContextSelection() {
        trashSelectedItems(confirming: true)
    }

    @objc private func propertiesContextSelection() {
        showProperties(allowsPermissionEditing: false)
    }

    @objc private func permissionsContextSelection() {
        showProperties(allowsPermissionEditing: true)
    }

    @objc private func revealContextSelection() {
        guard let row = tableView.selectedRowIndexes.first,
              rows.indices.contains(row)
        else { return }
        workspaceActions.reveal(rows[row].url)
    }

    @objc private func copyContextSelectionPaths() {
        let paths = selectedLocalPaths
        guard paths.isEmpty == false else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func openSelectedEntry() {
        let selectedRows = tableView.selectedRowIndexes
        guard selectedRows.count == 1,
              let row = selectedRows.first,
              rows.indices.contains(row)
        else { return }
        if rows[row].isDirectory {
            navigate(to: rows[row].url)
        } else {
            openFile(rows[row].url)
        }
    }

    private func openFile(_ url: URL) {
        if let onOpenFile {
            onOpenFile(url)
        } else {
            workspaceActions.open(url)
        }
    }

    private func quickLookSelectedItems() {
        let urls = selectedLocalURLs
        guard urls.isEmpty == false else { return }
        onQuickLookURLs?(urls)
    }

    private func pasteClipboardItems() {
        guard let payload = workspaceClipboard.resolvedPayload() else { return }
        if let onPastePayload {
            onPastePayload(payload, directoryURL)
            return
        }
        guard payload.localURLs.isEmpty == false else { return }
        performLocalCopyOrMove(payload, to: directoryURL)
    }

    private func performLocalCopyOrMove(_ payload: FileWorkspaceClipboardPayload, to directory: URL) {
        let urls = payload.localURLs
        let operation = payload.operation
        let conflictSession = RemoteFileConflictResolutionSession(resolver: conflictResolver)
        if let localFileTransferScheduler {
            let plans = urls.compactMap { sourceURL -> (URL, URL)? in
                let proposedDestination = directory.appendingPathComponent(
                    sourceURL.lastPathComponent,
                    isDirectory: sourceURL.hasDirectoryPath
                )
                guard sourceURL.standardizedFileURL != proposedDestination.standardizedFileURL else {
                    return nil
                }
                let hasConflict = FileManager.default.fileExists(atPath: proposedDestination.path)
                let policy = hasConflict
                    ? conflictSession.resolveConflict(
                        destinationPath: proposedDestination.path,
                        direction: .download,
                        parentWindow: view.window
                    )
                    : .overwrite
                guard let policy, policy != .skip else { return nil }
                let destination = hasConflict && policy != .overwrite
                    ? Self.uniqueDestinationURL(proposedDestination)
                    : proposedDestination
                return (sourceURL.standardizedFileURL, destination.standardizedFileURL)
            }
            guard plans.isEmpty == false else {
                updateStatus("没有可传输的本地项目")
                return
            }
            updateStatus(operation == .copy ? "正在复制..." : "正在移动...")
            let batch = LocalFileTransferBatch(
                expectedCount: plans.count,
                completion: { [weak self] results in
                    guard let self else { return }
                    let allCompleted = results.count == plans.count
                        && results.allSatisfy { $0 == .completed }
                    if operation == .cut, allCompleted {
                        self.workspaceClipboard.clear()
                    }
                    self.refreshDirectory()
                    if allCompleted {
                        self.updateStatus(operation == .copy ? "复制完成" : "移动完成")
                    } else if let message = results.compactMap({ result -> String? in
                        if case .failed(let message) = result { return message }
                        return nil
                    }).first {
                        self.updateStatus("文件操作失败：\(message)")
                    } else {
                        self.updateStatus("文件操作已取消")
                    }
                }
            )
            for plan in plans {
                localFileTransferScheduler.scheduleLocalFileTransfer(
                    runtimeID: runtimeID,
                    sourceURL: plan.0,
                    destinationURL: plan.1,
                    operation: operation == .copy ? .copy : .move,
                    notificationPolicy: .silent,
                    completion: { result in
                        DispatchQueue.main.async {
                            batch.receive(result)
                        }
                    }
                )
            }
            return
        }
        updateStatus(operation == .copy ? "正在复制..." : "正在移动...")
        fileOperationQueue.async { [weak self] in
            guard let self else { return }
            do {
                var completedCount = 0
                for sourceURL in urls {
                    let proposedDestination = directory.appendingPathComponent(
                        sourceURL.lastPathComponent,
                        isDirectory: sourceURL.hasDirectoryPath
                    )
                    guard sourceURL.standardizedFileURL != proposedDestination.standardizedFileURL else {
                        throw LocalFilePaneError.invalidPath(sourceURL.path)
                    }
                    let hasConflict = FileManager.default.fileExists(atPath: proposedDestination.path)
                    let policy = hasConflict
                        ? conflictSession.resolveConflict(
                            destinationPath: proposedDestination.path,
                            direction: .download,
                            parentWindow: nil
                        )
                        : .overwrite
                    guard let policy, policy != .skip else { continue }
                    if hasConflict && policy == .overwrite {
                        try Self.replaceLocalItemSafely(
                            sourceURL: sourceURL,
                            destinationURL: proposedDestination,
                            removesSource: operation == .cut
                        )
                    } else {
                        let destination = hasConflict
                            ? Self.uniqueDestinationURL(proposedDestination)
                            : proposedDestination
                        if operation == .copy {
                            try FileManager.default.copyItem(at: sourceURL, to: destination)
                        } else {
                            try FileManager.default.moveItem(at: sourceURL, to: destination)
                        }
                    }
                    completedCount += 1
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if operation == .cut, completedCount == urls.count {
                        self.workspaceClipboard.clear()
                    }
                    self.refreshDirectory()
                    self.updateStatus(operation == .copy ? "复制完成" : "移动完成")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("文件操作失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func renameSelectedItem(to proposedName: String) {
        guard selectedLocalURLs.count == 1, let sourceURL = selectedLocalURLs.first else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidItemName(name) else {
            updateStatus("名称无效")
            return
        }
        let destination = sourceURL.deletingLastPathComponent().appendingPathComponent(name)
        fileOperationQueue.async { [weak self] in
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destination)
                DispatchQueue.main.async { [weak self] in self?.refreshDirectory() }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("重命名失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func createDirectory(named proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidItemName(name) else {
            updateStatus("名称无效")
            return
        }
        let destination = directoryURL.appendingPathComponent(name, isDirectory: true)
        fileOperationQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("已创建文件夹：\(name)")
                    self?.refreshDirectory()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("新建文件夹失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func trashSelectedItems(confirming: Bool) {
        let urls = selectedLocalURLs
        guard urls.isEmpty == false else { return }
        if confirming {
            let alert = NSAlert()
            alert.messageText = "将选中项目移到废纸篓？"
            alert.informativeText = "共 \(urls.count) 项"
            alert.addButton(withTitle: "移到废纸篓")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        updateStatus("正在移到废纸篓...")
        fileOperationQueue.async { [weak self] in
            do {
                for url in urls {
                    guard let self else { return }
                    try self.trashItem(url)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("已移到废纸篓")
                    self?.refreshDirectory()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("移到废纸篓失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showProperties(allowsPermissionEditing: Bool) {
        guard selectedLocalURLs.count == 1, let url = selectedLocalURLs.first else { return }
        let controller = FileWorkspacePropertiesWindowController(
            properties: .local(url: url, device: "此 Mac"),
            allowsPermissionEditing: allowsPermissionEditing,
            onApplyPermissions: allowsPermissionEditing ? { [weak self] mode in
                self?.applyPermissions(mode, to: url)
            } : nil
        )
        propertiesWindowControllers.removeAll { $0.window?.isVisible == false }
        propertiesWindowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
    }

    private func applyPermissions(_ mode: String, to url: URL) {
        guard let value = Int(mode, radix: 8) else { return }
        fileOperationQueue.async { [weak self] in
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: value)],
                    ofItemAtPath: url.path
                )
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("权限已更新为 \(mode)")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.updateStatus("权限更新失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func destinationURL(forProposedRow row: Int) -> URL {
        guard rows.indices.contains(row), rows[row].isDirectory else {
            return directoryURL
        }
        return rows[row].url
    }

    private func handleRemoteSelectionsDropped(
        _ selections: [RemoteFileSelection],
        sourceRuntimeID: String?
    ) {
        guard selections.isEmpty == false else { return }
        routeRemoteSelectionsDropped(
            selections,
            sourceRuntimeID: sourceRuntimeID,
            destination: directoryURL
        )
    }

    private func routeRemoteSelectionsDropped(
        _ selections: [RemoteFileSelection],
        sourceRuntimeID: String?,
        destination: URL
    ) {
        if let onRemoteSelectionsDroppedWithSource {
            onRemoteSelectionsDroppedWithSource(sourceRuntimeID, selections, destination)
        } else {
            onRemoteSelectionsDropped?(selections, destination)
        }
    }

    private func submitPathFieldValue() {
        let value = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            pathField.stringValue = directoryURL.path
            return
        }
        let expandedPath = (value as NSString).expandingTildeInPath
        let candidateURL: URL
        if expandedPath.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        } else {
            candidateURL = directoryURL.appendingPathComponent(expandedPath, isDirectory: true)
        }
        let standardizedURL = candidateURL.standardizedFileURL
        navigate(to: standardizedURL)
    }

    private func uploadSelectedItems() {
        let paths = selectedLocalPaths
        guard paths.isEmpty == false else {
            updateActionStates()
            return
        }
        onUploadLocalPaths?(paths)
    }

    private var selectedLocalPaths: [String] {
        selectedLocalURLs.map(\.path)
    }

    private var selectedLocalURLs: [URL] {
        tableView.selectedRowIndexes.compactMap { index in
            guard rows.indices.contains(index) else { return nil }
            return rows[index].url
        }
    }

    private static func isValidItemName(_ name: String) -> Bool {
        name.isEmpty == false && name != "." && name != ".." && name.contains("/") == false
    }

    private static func uniqueDestinationURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = ext.isEmpty
            ? url.lastPathComponent
            : String(url.lastPathComponent.dropLast(ext.count + 1))
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(
                name,
                isDirectory: url.hasDirectoryPath
            )
            if FileManager.default.fileExists(atPath: candidate.path) == false { return candidate }
            index += 1
        }
    }

    private static func replaceLocalItemSafely(
        sourceURL: URL,
        destinationURL: URL,
        removesSource: Bool
    ) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).stacio-transfer-\(UUID().uuidString).partial",
            isDirectory: sourceURL.hasDirectoryPath
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
            if removesSource {
                try FileManager.default.removeItem(at: sourceURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func reloadRows() {
        tableView.deselectAll(nil)
        tableView.reloadData()
        updateActionStates()
    }

    private func applySortOrder(
        _ order: FileWorkspaceTableSortOrder,
        synchronizesDescriptor: Bool
    ) {
        let selectedPaths = Set(selectedLocalURLs.map(\.standardizedFileURL.path))
        sortOrder = order
        rows = sortedRows(rows)
        tableView.reloadData()
        let selectedIndexes = IndexSet(rows.enumerated().compactMap { index, row in
            selectedPaths.contains(row.url.standardizedFileURL.path) ? index : nil
        })
        tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        if synchronizesDescriptor {
            synchronizeTableSortDescriptor()
        }
        updateActionStates()
    }

    private func sortedRows(_ candidates: [LocalFileRow]) -> [LocalFileRow] {
        candidates.sorted { lhs, rhs in
            if lhs.displayGroup != rhs.displayGroup {
                return lhs.displayGroup < rhs.displayGroup
            }
            let comparison: ComparisonResult
            switch sortOrder.column {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                comparison = Self.compare(lhs.byteSize, rhs.byteSize)
            case .time:
                comparison = Self.compare(lhs.modifiedDate, rhs.modifiedDate)
            }
            if comparison != .orderedSame {
                return sortOrder.placesBefore(comparison)
            }
            let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.url.path < rhs.url.path
        }
    }

    private func synchronizeTableSortDescriptor() {
        isSynchronizingSortDescriptor = true
        tableView.sortDescriptors = [sortOrder.descriptor]
        isSynchronizingSortDescriptor = false
    }

    private static func compare<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.some(let lhs), .some(let rhs)):
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        }
    }

    private func updateActionStates() {
        uploadButton.isEnabled = onUploadLocalPaths != nil && selectedLocalPaths.isEmpty == false
        parentButton.isEnabled = directoryURL.path != "/"
    }

    private func updateStatus(_ value: String) {
        statusText = value
        if isViewLoaded {
            statusLabel.stringValue = value
        }
    }

    private static func loadRows(
        at directory: URL,
        contentsProvider: LocalDirectoryContentsProviding
    ) -> LocalDirectoryLoadResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .failure("本地路径不存在：\(directory.path)")
        }
        guard isDirectory.boolValue else {
            return .failure("本地路径不是文件夹：\(directory.path)")
        }
        guard canReadDirectory(at: directory) else {
            return .failure("没有权限读取本地路径：\(directory.path)")
        }
        do {
            let contents = try contentsProvider(directory)
            return .success(contents.map(LocalFileRow.init(url:)))
        } catch {
            return .failure("无法读取本地路径：\(directory.path)")
        }
    }

    private static func canReadDirectory(at url: URL) -> Bool {
        if let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
            return permissions.intValue & 0o444 != 0
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private func configureButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        button.title = ""
        button.target = self
        button.action = action
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        StacioDesignSystem.styleToolbarButton(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func updateCloseButtonPlacement() {
        guard let toolbarStackView else { return }
        if onRequestClose != nil {
            guard closeButton.superview == nil else { return }
            toolbarStackView.addArrangedSubview(closeButton)
        } else if closeButton.superview != nil {
            toolbarStackView.removeArrangedSubview(closeButton)
            closeButton.removeFromSuperview()
        }
    }

    @objc private func closeButtonPressed() {
        onRequestClose?()
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 60
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        return column
    }
}

@MainActor
private final class LocalFileTransferBatch {
    private let expectedCount: Int
    private let completion: ([LocalFileTransferResult]) -> Void
    private var results: [LocalFileTransferResult] = []

    init(
        expectedCount: Int,
        completion: @escaping ([LocalFileTransferResult]) -> Void
    ) {
        self.expectedCount = expectedCount
        self.completion = completion
    }

    func receive(_ result: LocalFileTransferResult) {
        guard results.count < expectedCount else { return }
        results.append(result)
        if results.count == expectedCount {
            completion(results)
        }
    }
}

private final class LocalFilesRootView: NSView {
    var onRemoteSelectionsDropped: ((String?, [RemoteFileSelection]) -> Void)? {
        didSet {
            registerForDraggedTypes([
                RemoteFileDragPayload.pasteboardType,
                .fileURL
            ])
        }
    }
    var onLocalURLsDropped: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hasRemoteSelections = RemoteFileDragPayload.selections(
            from: sender.draggingPasteboard
        ).isEmpty == false
        let hasLocalURLs = LocalFileDragPayload.urls(from: sender.draggingPasteboard).isEmpty == false
        return hasRemoteSelections || hasLocalURLs ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let selections = RemoteFileDragPayload.selections(from: sender.draggingPasteboard)
        if selections.isEmpty == false {
            onRemoteSelectionsDropped?(
                RemoteFileDragPayload.sourceRuntimeID(from: sender.draggingPasteboard),
                selections
            )
            return true
        }
        let urls = LocalFileDragPayload.urls(from: sender.draggingPasteboard)
        guard urls.isEmpty == false else { return false }
        onLocalURLsDropped?(urls)
        return true
    }
}

struct LocalFileRow: StacioFileDisplayRow, Sendable {
    let url: URL
    let name: String
    let kind: String
    let size: String
    let time: String
    let isDirectory: Bool
    let isHiddenItem: Bool
    let byteSize: Int?
    let modifiedDate: Date?

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .isHiddenKey,
            .contentModificationDateKey
        ])
        isDirectory = values?.isDirectory == true
        let isHidden = values?.isHidden == true || name.hasPrefix(".")
        isHiddenItem = isHidden
        modifiedDate = values?.contentModificationDate
        time = StacioFileDisplay.timeText(for: modifiedDate)
        if isDirectory {
            kind = "文件夹"
            size = ""
            byteSize = nil
        } else {
            kind = "文件"
            byteSize = values?.fileSize
            size = StacioFileDisplay.byteSizeText(byteSize)
        }
    }

    func value(for columnIdentifier: String) -> String {
        switch columnIdentifier {
        case "name":
            return name
        case "size":
            return size
        case "time":
            return time
        default:
            return ""
        }
    }
}
