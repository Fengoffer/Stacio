import AppKit
import StacioCoreBindings

public struct RemoteFileSelection: Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let kind: RemoteFileKind
    public let modifiedTime: String?

    public init(path: String, size: UInt64, kind: RemoteFileKind = .file, modifiedTime: String? = nil) {
        self.path = path
        self.size = size
        self.kind = kind
        self.modifiedTime = modifiedTime
    }

    public var isDirectory: Bool {
        kind == .directory
    }

    public var isFile: Bool {
        kind == .file
    }

    public var isEditableFile: Bool {
        kind == .file && StacioFileDisplay.contentKind(forFileName: (path as NSString).lastPathComponent).isEditableText
    }

    public var isPreviewableMediaFile: Bool {
        kind == .file && StacioFileDisplay.contentKind(forFileName: (path as NSString).lastPathComponent).isPreviewableMedia
    }
}

public struct RemoteFileSearchResult: Equatable {
    public let path: String
    public let relativePath: String
    public let directoryPath: String
    public let fileName: String
    public let size: UInt64
    public let kind: RemoteFileKind
    public let modifiedTime: String?

    public init(entry: RemoteFileEntry, baseDirectory: String) {
        let normalizedPath = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
        path = normalizedPath
        fileName = (normalizedPath as NSString).lastPathComponent
        relativePath = Self.relativePath(for: normalizedPath, baseDirectory: baseDirectory)
        let parent = (normalizedPath as NSString).deletingLastPathComponent
        directoryPath = parent.isEmpty ? "/" : parent
        size = entry.kind == .symlink ? 0 : entry.size
        kind = entry.kind
        modifiedTime = entry.modifiedTime
    }

    public var selection: RemoteFileSelection {
        RemoteFileSelection(path: path, size: size, kind: kind, modifiedTime: modifiedTime)
    }

    private static func relativePath(for path: String, baseDirectory: String) -> String {
        let base = baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return (path as NSString).lastPathComponent
        }
        if base == "/", path.hasPrefix("/") {
            return String(path.dropFirst()).isEmpty ? (path as NSString).lastPathComponent : String(path.dropFirst())
        }
        if base == "~", path.hasPrefix("~/") {
            return String(path.dropFirst(2))
        }
        let normalizedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolutePrefix = base.hasPrefix("/")
            ? "/" + normalizedBase + "/"
            : normalizedBase + "/"
        if path.hasPrefix(absolutePrefix) {
            let relative = String(path.dropFirst(absolutePrefix.count))
            return relative.isEmpty ? (path as NSString).lastPathComponent : relative
        }
        return (path as NSString).lastPathComponent
    }
}

@MainActor
public final class FilesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSDraggingDestination, NSSplitViewDelegate {
    private enum PreferenceKey {
        static let sortMode = "Stacio.FilesPanel.sortMode"
        static let showHiddenFiles = "Stacio.FilesPanel.showHiddenFiles"
    }

    private enum EditorCapabilityLayout {
        static let minimumBrowserWidth: CGFloat = 240
        static let minimumEditorWidth: CGFloat = 360
        static let preferredEditorWidth: CGFloat = 680
        static let preferredEditorWidthFraction: CGFloat = 0.72
    }

    private enum RemoteFileSortMode: String, CaseIterable {
        case nameAscending
        case nameDescending
        case sizeAscending
        case sizeDescending
        case ownerAscending
        case ownerDescending
        case permissionsAscending
        case permissionsDescending
        case modifiedTimeAscending
        case modifiedTimeDescending

        var title: String {
            switch self {
            case .nameAscending:
                "名称（升序）"
            case .nameDescending:
                "名称（降序）"
            case .sizeAscending:
                "大小（升序）"
            case .sizeDescending:
                "大小（降序）"
            case .ownerAscending:
                "用户（升序）"
            case .ownerDescending:
                "用户（降序）"
            case .permissionsAscending:
                "权限（升序）"
            case .permissionsDescending:
                "权限（降序）"
            case .modifiedTimeAscending:
                "时间（升序）"
            case .modifiedTimeDescending:
                "时间（降序）"
            }
        }

        var columnIdentifier: String {
            switch self {
            case .nameAscending, .nameDescending:
                "name"
            case .sizeAscending, .sizeDescending:
                "size"
            case .ownerAscending, .ownerDescending:
                "owner"
            case .permissionsAscending, .permissionsDescending:
                "permissions"
            case .modifiedTimeAscending, .modifiedTimeDescending:
                "time"
            }
        }

        var isAscending: Bool {
            switch self {
            case .nameAscending, .sizeAscending, .ownerAscending, .permissionsAscending, .modifiedTimeAscending:
                true
            case .nameDescending, .sizeDescending, .ownerDescending, .permissionsDescending, .modifiedTimeDescending:
                false
            }
        }

        init?(title: String) {
            guard let match = Self.allCases.first(where: { $0.title == title }) else {
                return nil
            }
            self = match
        }

        init?(columnIdentifier: String, ascending: Bool) {
            switch (columnIdentifier, ascending) {
            case ("name", true):
                self = .nameAscending
            case ("name", false):
                self = .nameDescending
            case ("size", true):
                self = .sizeAscending
            case ("size", false):
                self = .sizeDescending
            case ("owner", true):
                self = .ownerAscending
            case ("owner", false):
                self = .ownerDescending
            case ("permissions", true):
                self = .permissionsAscending
            case ("permissions", false):
                self = .permissionsDescending
            case ("time", true):
                self = .modifiedTimeAscending
            case ("time", false):
                self = .modifiedTimeDescending
            default:
                return nil
            }
        }

        func toggled(for columnIdentifier: String) -> RemoteFileSortMode {
            if self.columnIdentifier == columnIdentifier {
                return Self(columnIdentifier: columnIdentifier, ascending: !isAscending) ?? .nameAscending
            }
            return Self(columnIdentifier: columnIdentifier, ascending: true) ?? .nameAscending
        }
    }

    public let tableView = RemoteFilesTableView()
    public var onRefresh: ((String) -> Void)?
    public var onOpenDirectory: ((String) -> Void)?
    public var onDownloadFile: ((RemoteFileSelection) -> Void)?
    public var onDownloadSelections: (([RemoteFileSelection]) -> Void)?
    public var onUploadFile: ((String) -> Void)?
    public var onUploadFolder: ((String) -> Void)?
    public var onUploadDroppedFiles: ((String, [String]) -> Void)?
    public var onCreateDirectory: ((String) -> Void)?
    public var onCreateFile: ((String) -> Void)?
    public var onRenamePath: ((RemoteFileSelection) -> Void)?
    public var onDeletePath: ((RemoteFileSelection) -> Void)?
    public var onDeleteSelections: (([RemoteFileSelection]) -> Void)?
    public var onOpenRemoteEdit: ((RemoteFileSelection) -> Void)?
    public var onOpenRemotePreview: ((RemoteFileSelection) -> Void)?
    public var onOpenRemoteWith: ((RemoteFileSelection) -> Void)?
    public var onOpenRemoteWithDefaultApplication: ((RemoteFileSelection) -> Void)?
    public var onCompareFiles: (([RemoteFileSelection]) -> Void)?
    public var onSaveRemoteEdit: ((RemoteFileSelection) -> Void)?
    public var onSyncChangedRemoteEdits: (() -> Void)?
    var onFileBrowserPaneFrameChanged: (() -> Void)?
    public var onChmodPath: ((RemoteFileSelection) -> Void)?
    public var onSendPathToTerminal: ((String) -> Void)?
    public var onAIQuestionRequested: ((String) -> Void)?
    public var onEmbeddedCapabilityWillOpen: (() -> Void)?
    public var onEmbeddedCapabilityClosed: ((CGFloat) -> Void)?
    public var onTransferStatusAction: ((TransferQueueAction, String) -> Void)?
    public var onSearchRemoteFiles: ((String, String, Int) -> Void)?
    public var onOpenSearchResult: ((RemoteFileSearchResult) -> Void)?
    public var onRemoteSearchClosed: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: L10n.Files.title)
    private let engineLabel = NSTextField(labelWithString: L10n.Files.engine)
    private let pathLabel = NSTextField(labelWithString: "路径")
    private let emptyLabel = NSTextField(labelWithString: L10n.Files.empty)
    private let pathField = NSTextField(string: "~")
    private let transferStatusContainer = NSView()
    private let transferStatusLabel = NSTextField(labelWithString: "暂无传输任务")
    private let transferProgressIndicator = NSProgressIndicator()
    private let transferStatusActions = NSStackView()
    private let transferPrimaryActionButton = NSButton()
    private let transferSecondaryActionButton = NSButton()
    private let parentButton = FilesViewController.makeToolbarButton(
        title: L10n.Files.parentDirectory,
        symbolName: "chevron.up",
        accessibilityDescription: L10n.Files.parentDirectory,
        identifier: "Stacio.Files.parent"
    )
    private let refreshButton = FilesViewController.makeToolbarButton(
        title: L10n.Files.refresh,
        symbolName: "arrow.clockwise",
        accessibilityDescription: L10n.Files.refresh,
        identifier: "Stacio.Files.refresh"
    )
    private let searchButton = FilesViewController.makeToolbarButton(
        title: "搜索",
        symbolName: "magnifyingglass",
        accessibilityDescription: "搜索远端文件",
        identifier: "Stacio.Files.search"
    )
    private let uploadButton = FilesViewController.makeToolbarButton(
        title: L10n.Files.upload,
        symbolName: "arrow.up.circle",
        accessibilityDescription: L10n.Files.upload,
        identifier: "Stacio.Files.upload"
    )
    private let downloadButton = FilesViewController.makeToolbarButton(
        title: L10n.Files.download,
        symbolName: "arrow.down.circle",
        accessibilityDescription: L10n.Files.download,
        identifier: "Stacio.Files.download"
    )
    private let moreButton = FilesViewController.makeToolbarButton(
        title: "更多",
        symbolName: "ellipsis.circle",
        accessibilityDescription: "更多",
        identifier: "Stacio.Files.more"
    )
    private let embeddedCapabilityExpandButton = FilesViewController.makeToolbarButton(
        title: "展开编辑器",
        symbolName: "arrow.up.left.and.arrow.down.right",
        accessibilityDescription: "展开编辑器",
        identifier: "Stacio.Files.expandEmbeddedCapability"
    )
    private let directoryFollowButton = NSButton()
    private let showHiddenFilesButton = NSButton()
    private let sizeUnitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pathBreadcrumbScrollView = NSScrollView()
    private let pathBreadcrumbClipView = NSClipView()
    private let pathBreadcrumbStack = NSStackView()
    private let searchBar = NSStackView()
    private let searchField = NSSearchField()
    private let searchDepthLabel = NSTextField(labelWithString: "深度")
    private let searchDepthField = NSTextField(string: "5")
    private let searchDepthStepper = NSStepper()
    private let uploadMenu = NSMenu(title: L10n.Files.upload)
    private let moreMenu = NSMenu(title: "更多")
    private let contentSplitView = NSSplitView()
    private let fileBrowserPaneView = CompressibleFilesPaneView()
    private var fileBrowserStandaloneConstraints: [NSLayoutConstraint] = []
    private var contentSplitConstraints: [NSLayoutConstraint] = []
    private var searchBarHeightConstraint: NSLayoutConstraint?
    private var allRows: [RemoteFileRow] = []
    private var searchRows: [RemoteFileRow] = []
    private var rows: [RemoteFileRow] = []
    private var selectedSortMode: RemoteFileSortMode = .nameAscending
    private var selectedSizeUnit: FileSizeUnit = .kilobytes
    private var remoteSearchEnabled = false
    private var isRemoteSearchActive = false
    private var searchBaseDirectory = "~"
    private var searchKeyword = ""
    private var rowContextMenuRow = -1
    private var lastPresentedPropertiesText: String?
    private var embeddedEditorViewController: RemoteTextEditorViewController?
    private var embeddedMediaPreviewViewController: RemoteMediaPreviewViewController?
    private var embeddedOpenProgressViewController: RemoteFileOpenProgressViewController?
    private var embeddedOpenRequestIDs = Set<UUID>()
    private var embeddedEditorCloseConfirmer: RemoteTextEditorCloseConfirming?
    private var editorSplitWidthConstraints: [NSLayoutConstraint] = []
    private var fileBrowserMinimumWidthConstraint: NSLayoutConstraint?
    private var fileBrowserCurrentWidthConstraint: NSLayoutConstraint?
    private var fileBrowserWidthBeforeCollapse: CGFloat?
    private var isEmbeddedCapabilityCollapsed = false
    private var lastKnownVisibleFileBrowserWidth: CGFloat?
    private var needsInitialEditorSplitPosition = false
    private var transferStatusHeightConstraint: NSLayoutConstraint?
    private var transferSamplesByJobID: [String: FilesTransferSample] = [:]
    private var pinnedTransferStatusJobID: String?
    private var displayedTransferStatusRow: TransferQueueSnapshot.Row?
    private let settingsStore: AppSettingsStore
    private var directoryFollowEnabled = true
    private var showHiddenFilesEnabled = false
    private var isSynchronizingTableSortDescriptors = false

    public init(settingsStore: AppSettingsStore = .shared) {
        self.settingsStore = settingsStore
        let snapshot = settingsStore.snapshot()
        directoryFollowEnabled = snapshot.filesDirectoryFollowDefault
        selectedSortMode = Self.loadPersistedSortMode()
        showHiddenFilesEnabled = Self.loadPersistedShowHiddenFiles()
            ?? (Self.isRunningUnitTests ? snapshot.filesShowHiddenFilesByDefault : false)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var entryCount: Int {
        rows.count
    }

    public var engineSummaryText: String {
        engineLabel.stringValue
    }

    public var currentRemotePath: String {
        normalizedCurrentPath()
    }

    public var isDirectoryFollowEnabled: Bool {
        directoryFollowEnabled
    }

    public var isShowingHiddenFiles: Bool {
        showHiddenFilesEnabled
    }

    public var visibleTextSnapshot: String {
        var values = [titleLabel.stringValue]
        if engineLabel.isHidden == false,
           engineLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            values.append(engineLabel.stringValue)
        }
        values.append(pathField.stringValue)
        if rows.isEmpty {
            values.append(emptyLabel.stringValue)
        }
        if !transferStatusContainer.isHidden {
            values.append(transferStatusLabel.stringValue)
        }
        values.append(contentsOf: rows.flatMap { $0.visibleValues(sizeUnit: selectedSizeUnit) })
        return values.joined(separator: "\n")
    }

    public var moreMenuTitlesForTesting: [String] {
        moreMenu.items.compactMap { $0.isSeparatorItem ? nil : $0.title }
    }

    public var uploadMenuTitlesForTesting: [String] {
        uploadMenu.items.compactMap { $0.isSeparatorItem ? nil : $0.title }
    }

    public var isRemoteSearchActiveForTesting: Bool {
        isRemoteSearchActive
    }

    public var selectedSortModeTitleForTesting: String {
        selectedSortMode.title
    }

    public var lastPresentedPropertiesTextForTesting: String? {
        lastPresentedPropertiesText
    }

    public var embeddedEditorViewControllerForTesting: RemoteTextEditorViewController? {
        embeddedEditorViewController
    }

    public var embeddedMediaPreviewViewControllerForTesting: RemoteMediaPreviewViewController? {
        embeddedMediaPreviewViewController
    }

    public var embeddedOpenProgressViewControllerForTesting: RemoteFileOpenProgressViewController? {
        embeddedOpenProgressViewController
    }

    public var fileBrowserPaneViewForTesting: NSView {
        fileBrowserPaneView
    }

    public var isEmbeddedCapabilityCollapsedForTesting: Bool {
        isEmbeddedCapabilityCollapsed
    }

    var hasEmbeddedCapabilityForInspectorControls: Bool {
        embeddedEditorViewController != nil || embeddedMediaPreviewViewController != nil
    }

    var isEmbeddedCapabilityCollapsedForInspectorControls: Bool {
        isEmbeddedCapabilityCollapsed
    }

    var isEmbeddedOpenProgressVisibleForInspectorControls: Bool {
        embeddedOpenProgressViewController != nil
    }

    public override func loadView() {
        let root = FilesShortcutRootView()
        root.onToggleFileBrowser = { [weak self] in
            self?.toggleFileBrowserVisibility()
        }
        root.onCloseRemoteSearch = { [weak self] in
            self?.closeRemoteSearch(restoreDirectoryRows: true) == true
        }
        root.onToggleHiddenFiles = { [weak self] in
            self?.toggleShowHiddenFilesFromUserAction()
        }
        root.localFileDropHandler = { [weak self] localPaths in
            self?.handleDroppedLocalFilePaths(localPaths)
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(root)

        contentSplitView.isVertical = true
        contentSplitView.dividerStyle = .thin
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.setAccessibilityIdentifier("Stacio.Files.editorSplit")
        contentSplitView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentSplitView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentSplitView.delegate = self

        fileBrowserPaneView.translatesAutoresizingMaskIntoConstraints = false
        fileBrowserPaneView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileBrowserPaneView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.setAccessibilityIdentifier("Stacio.Files.title")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        engineLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        engineLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        engineLabel.isHidden = L10n.Files.engine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        engineLabel.setAccessibilityIdentifier("Stacio.Files.engine")
        engineLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        pathLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        pathField.placeholderString = L10n.Files.remotePath
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.target = self
        pathField.action = #selector(refreshButtonPressed(_:))
        pathField.setAccessibilityIdentifier("Stacio.Files.pathField")
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.isHidden = true
        stylePathField()

        parentButton.target = self
        parentButton.action = #selector(parentButtonPressed(_:))
        refreshButton.target = self
        refreshButton.action = #selector(refreshButtonPressed(_:))
        searchButton.target = self
        searchButton.action = #selector(searchButtonPressed(_:))
        uploadButton.target = self
        uploadButton.action = #selector(uploadButtonPressed(_:))
        downloadButton.target = self
        downloadButton.action = #selector(downloadButtonPressed(_:))
        moreButton.target = self
        moreButton.action = #selector(moreButtonPressed(_:))
        embeddedCapabilityExpandButton.target = self
        embeddedCapabilityExpandButton.action = #selector(embeddedCapabilityExpandButtonPressed(_:))
        embeddedCapabilityExpandButton.isHidden = true
        configureSizeUnitPopup()
        configurePathBreadcrumbs()
        configureDirectoryFollowButton()
        configureShowHiddenFilesButton()
        configureSearchBar()

        configureUploadMenu()
        configureMoreMenu()
        updateActionStates()

        let toolbar = NSStackView(views: [
            parentButton,
            refreshButton,
            searchButton,
            downloadButton,
            uploadButton,
            moreButton,
            directoryFollowButton,
            showHiddenFilesButton
        ])
        toolbar.setAccessibilityIdentifier("Stacio.Files.toolbar")
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        toolbar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let pathBar = NSStackView(views: [pathLabel, pathBreadcrumbScrollView, pathField, sizeUnitPopup])
        pathBar.orientation = .horizontal
        pathBar.alignment = .centerY
        pathBar.spacing = 4
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathBreadcrumbScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathBreadcrumbScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sizeUnitPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryFollowButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        directoryFollowButton.setContentHuggingPriority(.required, for: .horizontal)
        showHiddenFilesButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        showHiddenFilesButton.setContentHuggingPriority(.required, for: .horizontal)

        tableView.addTableColumn(makeColumn(identifier: "name", title: "名称", width: 100))
        tableView.addTableColumn(makeColumn(identifier: "size", title: "大小", width: 52))
        tableView.addTableColumn(makeColumn(identifier: "owner", title: "用户", width: 48))
        tableView.addTableColumn(makeColumn(identifier: "permissions", title: "权限", width: 50))
        tableView.addTableColumn(makeColumn(identifier: "time", title: "时间", width: 68))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = StacioFileDisplay.tableRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.Files.remoteTable")
        tableView.setAccessibilityLabel(L10n.Files.remoteFiles)
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedEntry(_:))
        let localFileDropHandler: ([String]) -> Void = { [weak self] localPaths in
            self?.handleDroppedLocalFilePaths(localPaths)
        }
        tableView.rowContextMenuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        tableView.middleClickRowHandler = { [weak self] row in
            self?.sendPathToTerminal(row: row)
        }
        tableView.localFileDropHandler = localFileDropHandler

        let scrollView = RemoteFilesDropScrollView()
        let clipView = RemoteFilesDropClipView()
        scrollView.contentView = clipView
        scrollView.documentView = tableView
        scrollView.localFileDropHandler = localFileDropHandler
        clipView.localFileDropHandler = localFileDropHandler
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTable(tableView)

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        configureTransferStatusStrip()

        root.addSubview(fileBrowserPaneView)
        root.addSubview(embeddedCapabilityExpandButton)

        fileBrowserPaneView.autoresizingMask = [.width, .height]
        fileBrowserPaneView.addSubview(titleLabel)
        fileBrowserPaneView.addSubview(engineLabel)
        fileBrowserPaneView.addSubview(toolbar)
        fileBrowserPaneView.addSubview(searchBar)
        fileBrowserPaneView.addSubview(pathBar)
        fileBrowserPaneView.addSubview(scrollView)
        fileBrowserPaneView.addSubview(emptyLabel)
        fileBrowserPaneView.addSubview(transferStatusContainer)

        fileBrowserStandaloneConstraints = [
            fileBrowserPaneView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileBrowserPaneView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileBrowserPaneView.topAnchor.constraint(equalTo: root.topAnchor),
            fileBrowserPaneView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ]
        NSLayoutConstraint.deactivate(fileBrowserStandaloneConstraints)
        transferStatusHeightConstraint = transferStatusContainer.heightAnchor.constraint(equalToConstant: 0)
        searchBarHeightConstraint = searchBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: fileBrowserPaneView.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: fileBrowserPaneView.topAnchor, constant: 18),

            engineLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            makeCompressibleWidthConstraint(engineLabel.trailingAnchor.constraint(equalTo: fileBrowserPaneView.trailingAnchor, constant: -12)),
            engineLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            toolbar.leadingAnchor.constraint(equalTo: fileBrowserPaneView.leadingAnchor, constant: 8),
            makeCompressibleWidthConstraint(toolbar.trailingAnchor.constraint(lessThanOrEqualTo: fileBrowserPaneView.trailingAnchor, constant: -8)),
            toolbar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            searchBar.leadingAnchor.constraint(equalTo: fileBrowserPaneView.leadingAnchor, constant: 12),
            makeCompressibleWidthConstraint(searchBar.trailingAnchor.constraint(equalTo: fileBrowserPaneView.trailingAnchor, constant: -12)),
            searchBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            searchBarHeightConstraint ?? searchBar.heightAnchor.constraint(equalToConstant: 0),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            searchDepthField.widthAnchor.constraint(equalToConstant: 34),
            searchDepthField.heightAnchor.constraint(equalToConstant: 24),
            searchDepthStepper.widthAnchor.constraint(equalToConstant: 18),
            searchDepthStepper.heightAnchor.constraint(equalToConstant: 24),

            pathLabel.widthAnchor.constraint(equalToConstant: 28),
            pathBreadcrumbScrollView.heightAnchor.constraint(equalToConstant: 28),
            makeCompressibleWidthConstraint(pathBreadcrumbScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)),
            pathField.heightAnchor.constraint(equalToConstant: 32),
            makeCompressibleWidthConstraint(pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)),
            makeCompressibleWidthConstraint(sizeUnitPopup.widthAnchor.constraint(equalToConstant: 52)),
            sizeUnitPopup.heightAnchor.constraint(equalToConstant: 26),
            directoryFollowButton.widthAnchor.constraint(equalToConstant: 26),
            directoryFollowButton.heightAnchor.constraint(equalToConstant: 24),
            showHiddenFilesButton.widthAnchor.constraint(equalToConstant: 26),
            showHiddenFilesButton.heightAnchor.constraint(equalToConstant: 24),
            pathBar.leadingAnchor.constraint(equalTo: fileBrowserPaneView.leadingAnchor, constant: 12),
            makeCompressibleWidthConstraint(pathBar.trailingAnchor.constraint(equalTo: fileBrowserPaneView.trailingAnchor, constant: -12)),
            pathBar.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: fileBrowserPaneView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: fileBrowserPaneView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: transferStatusContainer.topAnchor, constant: -6),

            transferStatusContainer.leadingAnchor.constraint(equalTo: fileBrowserPaneView.leadingAnchor, constant: 8),
            transferStatusContainer.trailingAnchor.constraint(equalTo: fileBrowserPaneView.trailingAnchor, constant: -8),
            transferStatusContainer.bottomAnchor.constraint(equalTo: fileBrowserPaneView.bottomAnchor, constant: -6),
            transferStatusHeightConstraint ?? transferStatusContainer.heightAnchor.constraint(equalToConstant: 0),

            transferStatusLabel.leadingAnchor.constraint(equalTo: transferStatusContainer.leadingAnchor, constant: 8),
            transferStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: transferStatusActions.leadingAnchor, constant: -8),
            transferStatusLabel.topAnchor.constraint(equalTo: transferStatusContainer.topAnchor, constant: 4),

            transferProgressIndicator.leadingAnchor.constraint(equalTo: transferStatusLabel.leadingAnchor),
            transferProgressIndicator.trailingAnchor.constraint(equalTo: transferStatusActions.leadingAnchor, constant: -8),
            transferProgressIndicator.topAnchor.constraint(equalTo: transferStatusLabel.bottomAnchor, constant: 4),
            transferProgressIndicator.heightAnchor.constraint(equalToConstant: 4),

            transferStatusActions.trailingAnchor.constraint(equalTo: transferStatusContainer.trailingAnchor, constant: -6),
            transferStatusActions.centerYAnchor.constraint(equalTo: transferStatusContainer.centerYAnchor),

            transferPrimaryActionButton.widthAnchor.constraint(equalToConstant: 26),
            transferPrimaryActionButton.heightAnchor.constraint(equalToConstant: 24),

            transferSecondaryActionButton.widthAnchor.constraint(equalToConstant: 26),
            transferSecondaryActionButton.heightAnchor.constraint(equalToConstant: 24),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            embeddedCapabilityExpandButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            embeddedCapabilityExpandButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 12)
        ])

        synchronizeTableSortDescriptors()
        rebuildPathBreadcrumbs()
        updateEmptyState()
        view = root
    }

    private func makeCompressibleWidthConstraint(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .defaultHigh
        return constraint
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        synchronizeStandaloneFileBrowserFrameIfNeeded()
        applyInitialEditorSplitPositionIfNeeded()
        updateTableColumnWidths()
        layoutPathBreadcrumbs()
        scrollPathBreadcrumbsToCurrentDirectory()
        rememberVisibleFileBrowserWidth()
        onFileBrowserPaneFrameChanged?()
    }

    public func synchronizeInspectorColumnLayout() {
        if let superview = view.superview,
           view.frame != superview.bounds
        {
            view.frame = superview.bounds
        }
        synchronizeStandaloneFileBrowserFrameIfNeeded()
        synchronizeEditorSplitFrameWithRootIfNeeded()
        view.needsLayout = true
    }

    public func synchronizeInspectorColumnFrameOnly() {
        if let superview = view.superview,
           view.frame != superview.bounds
        {
            view.frame = superview.bounds
        }
        if contentSplitView.superview == nil,
           fileBrowserPaneView.superview === view,
           fileBrowserPaneView.frame != view.bounds
        {
            fileBrowserPaneView.translatesAutoresizingMaskIntoConstraints = true
            fileBrowserPaneView.autoresizingMask = [.width, .height]
            fileBrowserPaneView.frame = view.bounds
        }
        if contentSplitView.superview != nil,
           contentSplitView.frame != view.bounds
        {
            contentSplitView.frame = view.bounds
        }
    }

    func fileBrowserPaneFrameForInspectorHeader(in targetView: NSView) -> NSRect? {
        guard isViewLoaded,
              contentSplitView.superview != nil,
              fileBrowserPaneView.isHidden == false
        else {
            return nil
        }
        synchronizeEditorSplitFrameWithRootIfNeeded()
        fileBrowserPaneView.layoutSubtreeIfNeeded()
        let frame = fileBrowserPaneView.convert(fileBrowserPaneView.bounds, to: targetView)
        guard frame.minX.isFinite,
              frame.maxX.isFinite,
              frame.width.isFinite,
              frame.width > 0,
              frame.minX > targetView.bounds.minX + 1,
              frame.maxX > targetView.bounds.minX,
              frame.minX < targetView.bounds.maxX
        else {
            return nil
        }
        return frame
    }

    func embeddedCapabilityFrameForInspectorHeader(in targetView: NSView) -> NSRect? {
        guard isViewLoaded,
              contentSplitView.superview != nil,
              let capabilityView = embeddedCapabilityView(),
              capabilityView.isHidden == false
        else {
            return nil
        }
        synchronizeEditorSplitFrameWithRootIfNeeded()
        capabilityView.layoutSubtreeIfNeeded()
        let frame = capabilityView.convert(capabilityView.bounds, to: targetView)
        guard frame.minX.isFinite,
              frame.maxX.isFinite,
              frame.width.isFinite,
              frame.width > 0,
              frame.maxX > targetView.bounds.minX,
              frame.minX < targetView.bounds.maxX
        else {
            return nil
        }
        return frame
    }

    public func setEngineSummary(_ value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        engineLabel.stringValue = value
        engineLabel.isHidden = trimmedValue.isEmpty
    }

    public func setCurrentRemotePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        pathField.stringValue = trimmed.isEmpty ? "~" : trimmed
        rebuildPathBreadcrumbs()
    }

    public func setDirectoryFollowEnabled(_ enabled: Bool) {
        directoryFollowEnabled = enabled
        directoryFollowButton.state = enabled ? .on : .off
        updateToolbarToggleButton(directoryFollowButton, enabled: enabled, enabledTooltip: "停止跟随终端目录", disabledTooltip: "跟随终端 cd 命令切换目录")
    }

    public func setShowHiddenFilesEnabled(_ enabled: Bool) {
        updateShowHiddenFilesEnabled(enabled, persist: false)
    }

    private func updateShowHiddenFilesEnabled(_ enabled: Bool, persist: Bool) {
        showHiddenFilesEnabled = enabled
        showHiddenFilesButton.state = enabled ? .on : .off
        updateToolbarToggleButton(
            showHiddenFilesButton,
            enabled: enabled,
            enabledTooltip: L10n.Files.hideHiddenFiles,
            disabledTooltip: L10n.Files.showHiddenFiles
        )
        if persist {
            UserDefaults.standard.set(enabled, forKey: PreferenceKey.showHiddenFiles)
        }
        applyRemoteRowFilter()
    }

    public func setRemoteSearchAvailable(_ available: Bool) {
        remoteSearchEnabled = available
        searchButton.isEnabled = available
        searchButton.toolTip = available ? "搜索远端文件" : "FTP 暂不支持远程文件搜索"
        searchButton.setAccessibilityLabel(searchButton.toolTip)
        if available == false {
            closeRemoteSearch(restoreDirectoryRows: true)
        }
    }

    public func openSelectedEntryForTesting() {
        openSelectedEntry(nil)
    }

    public func performDownloadSelectedEntryForTesting() {
        downloadButtonPressed(nil)
    }

    public func performUploadFileForTesting() {
        uploadFileMenuItemPressed(nil)
    }

    public func performUploadFolderForTesting() {
        uploadFolderMenuItemPressed(nil)
    }

    public func performParentDirectoryForTesting() {
        parentButtonPressed(nil)
    }

    public func updateActionStatesForTesting() {
        updateActionStates()
    }

    public func performDropLocalFilesForTesting(_ localPaths: [String]) {
        handleDroppedLocalFilePaths(localPaths)
    }

    public func performCreateDirectoryForTesting() {
        performMoreActionForTesting(title: L10n.Files.mkdir)
    }

    public func performCreateFileForTesting() {
        performMoreActionForTesting(title: L10n.Files.newFile)
    }

    public func performRenameSelectedEntryForTesting() {
        performMoreActionForTesting(title: L10n.Files.rename)
    }

    public func performDeleteSelectedEntryForTesting() {
        performMoreActionForTesting(title: L10n.Files.deleteRemote)
    }

    public func performOpenRemoteEditForTesting() {
        guard let selection = selectedFileSelection() else {
            return
        }
        onOpenRemoteEdit?(selection)
    }

    public func performSaveRemoteEditForTesting() {
        performMoreActionForTesting(title: L10n.Files.saveEditedCopy)
    }

    public func performSyncChangedRemoteEditsForTesting() {
        performMoreActionForTesting(title: L10n.Files.syncChangedEdits)
    }

    public func toggleFileBrowserVisibilityForTesting() {
        toggleFileBrowserVisibility()
    }

    public func toggleShowHiddenFilesForTesting() {
        setShowHiddenFilesEnabled(!showHiddenFilesEnabled)
    }

    private func toggleShowHiddenFilesFromUserAction() {
        updateShowHiddenFilesEnabled(!showHiddenFilesEnabled, persist: true)
    }

    public func collapseEmbeddedCapabilityForTesting() {
        collapseEmbeddedCapability()
    }

    public func expandEmbeddedCapabilityForTesting() {
        expandEmbeddedCapability()
    }

    public func expandEmbeddedCapability() {
        restoreCollapsedEmbeddedCapability()
    }

    @discardableResult
    public func closeEmbeddedEditorForTesting() -> Bool {
        closeEmbeddedEditorIfNeeded()
    }

    public func performChmodSelectedEntryForTesting() {
        performMoreActionForTesting(title: L10n.Files.chmod)
    }

    public func contextMenuTitlesForTesting(row: Int) -> [String] {
        contextMenu(forRow: row)?.items.compactMap { $0.isSeparatorItem ? nil : $0.title } ?? []
    }

    public func performContextMenuActionForTesting(title: String, row: Int) {
        guard let item = contextMenu(forRow: row)?.items.first(where: { $0.title == title }) else {
            return
        }
        guard let target = item.target,
              let action = item.action
        else {
            return
        }
        _ = target.perform(action, with: item)
    }

    public func performMiddleClickPathToTerminalForTesting(row: Int) {
        sendPathToTerminal(row: row)
    }

    public func performMoreActionForTesting(title: String) {
        guard let item = moreMenu.items.first(where: { $0.title == title }) else {
            return
        }
        guard let target = item.target,
              let action = item.action
        else {
            return
        }
        _ = target.perform(action, with: item)
    }

    public func setRemoteEntries(
        _ entries: [RemoteFileEntry],
        remotePath: String? = nil,
        isBackgroundRefreshing: Bool = false
    ) {
        if isRemoteSearchActive {
            closeRemoteSearch(restoreDirectoryRows: false)
        }
        let normalizedRemotePath = remotePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remotePath {
            setCurrentRemotePath(remotePath)
        }
        allRows = entries.map(RemoteFileRow.init(entry:))
        applyRemoteRowFilter()
        if (remotePath == nil || normalizedRemotePath?.isEmpty == true || normalizedRemotePath == "~"),
           normalizedCurrentPath() == "~",
           let inferredPath = Self.inferCurrentDirectory(from: entries)
        {
            setCurrentRemotePath(inferredPath)
        }
        emptyLabel.stringValue = L10n.Files.empty
        setRefreshButtonTitle(isBackgroundRefreshing ? "正在后台同步远端目录" : L10n.Files.refresh)
        updateEmptyState()
    }

    public func setRemoteSearchLoading(keyword: String, baseDirectory: String) {
        showSearchBar()
        isRemoteSearchActive = true
        searchKeyword = keyword
        searchBaseDirectory = baseDirectory
        searchRows = []
        rows = []
        setSearchColumnTitles()
        emptyLabel.stringValue = "搜索中…\n\(keyword)"
        tableView.reloadData()
        updateEmptyState()
    }

    public func setRemoteSearchResults(
        _ entries: [RemoteFileEntry],
        baseDirectory: String,
        keyword: String
    ) {
        showSearchBar()
        isRemoteSearchActive = true
        searchKeyword = keyword
        searchBaseDirectory = baseDirectory
        searchRows = entries
            .map { RemoteFileRow(entry: $0, searchBaseDirectory: baseDirectory) }
        setSearchColumnTitles()
        applyRemoteRowFilter()
        emptyLabel.stringValue = entries.isEmpty ? "没有找到匹配文件\n\(keyword)" : L10n.Files.empty
        updateEmptyState()
    }

    public func setRemoteSearchError(_ detail: String, baseDirectory: String, keyword: String) {
        showSearchBar()
        isRemoteSearchActive = true
        searchKeyword = keyword
        searchBaseDirectory = baseDirectory
        searchRows = []
        rows = []
        setSearchColumnTitles()
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyLabel.stringValue = trimmedDetail.isEmpty
            ? "搜索失败"
            : "搜索失败\n\(trimmedDetail)"
        tableView.reloadData()
        updateEmptyState()
    }

    public func finishRemoteListingRefresh() {
        setRefreshButtonTitle(L10n.Files.refresh)
        updateEmptyState()
    }

    public func setTransferStatusSnapshot(_ snapshot: TransferQueueSnapshot) {
        guard let row = preferredTransferStatusRow(from: snapshot.rows) else {
            transferStatusContainer.isHidden = true
            transferStatusHeightConstraint?.constant = 0
            transferStatusLabel.stringValue = L10n.Transfers.empty
            transferProgressIndicator.doubleValue = 0
            displayedTransferStatusRow = nil
            updateTransferStatusActionButtons(for: nil)
            transferSamplesByJobID = [:]
            pinnedTransferStatusJobID = nil
            return
        }

        pinnedTransferStatusJobID = row.jobID
        displayedTransferStatusRow = row
        let metric = transferMetric(for: row, capturedAt: snapshot.capturedAt)
        let progressText = Self.formatTransferProgress(bytesDone: row.bytesDone, bytesTotal: row.bytesTotal)
        let directionText = row.direction == .upload ? L10n.Transfers.upload : L10n.Transfers.download
        let fileName = Self.transferDisplayName(for: row)
        let taskPrefix = snapshot.rows.count > 1 ? "\(snapshot.rows.count) 个任务 · " : ""
        let statusText = L10n.Transfers.status(row.rawStatus)
        let etaSuffix = metric.etaText.isEmpty ? "" : " · \(L10n.Transfers.remainingPrefix) \(metric.etaText)"
        let speedSuffix = metric.speedText.isEmpty ? "" : " · \(metric.speedText)"

        transferStatusContainer.isHidden = false
        transferStatusHeightConstraint?.constant = 42
        transferStatusLabel.stringValue = "\(taskPrefix)\(directionText) \(fileName) · \(progressText)\(etaSuffix) · \(statusText)\(speedSuffix)"
        transferProgressIndicator.doubleValue = Self.transferProgressValue(bytesDone: row.bytesDone, bytesTotal: row.bytesTotal)
        updateTransferStatusActionButtons(for: row)
        view.needsLayout = true
    }

    public func setRemoteEditSyncStatus(message: String, progressValue: Double?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }
        transferStatusContainer.isHidden = false
        transferStatusHeightConstraint?.constant = 36
        transferStatusLabel.stringValue = trimmed
        transferProgressIndicator.doubleValue = min(max(progressValue ?? 0, 0), 100)
        displayedTransferStatusRow = nil
        updateTransferStatusActionButtons(for: nil)
        view.needsLayout = true
    }

    public func setRemoteListingLoading(remotePath: String) {
        setCurrentRemotePath(remotePath)
        allRows = []
        rows = []
        emptyLabel.stringValue = "正在加载远端目录\n\(normalizedCurrentPath())"
        setRefreshButtonTitle(L10n.Files.refresh)
        tableView.reloadData()
        updateEmptyState()
    }

    public func presentEmbeddedEditor(
        localURL: URL,
        saveHandler: RemoteEditSaveHandler?,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        if isViewLoaded == false {
            loadView()
        }
        if let embeddedEditorViewController,
           embeddedMediaPreviewViewController == nil
        {
            embeddedEditorViewController.openDocument(localURL: localURL) { _ in
                try saveHandler?()
            }
            restoreCollapsedEmbeddedCapability()
            return
        }
        if embeddedOpenProgressViewController != nil,
           embeddedEditorViewController == nil,
           embeddedMediaPreviewViewController == nil
        {
            removeEmbeddedOpenProgressForReplacement()
        } else {
            guard closeEmbeddedCapabilityIfNeeded() else { return }
        }

        view.layoutSubtreeIfNeeded()
        let editor = RemoteTextEditorViewController(localURL: localURL) { _ in
            try saveHandler?()
        }
        embeddedEditorCloseConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        editor.onCloseRequested = { [weak self] in
            _ = self?.closeEmbeddedEditorIfNeeded()
        }
        editor.onAIQuestionRequested = { [weak self] question in
            self?.onAIQuestionRequested?(question)
        }
        ensureEditorSplitViewAttached()
        addChild(editor)
        let editorView = editor.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        installCapabilityViewInSplit(editorView)
        installEditorSplitWidthConstraints(editorView: editorView)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        needsInitialEditorSplitPosition = true
        embeddedEditorViewController = editor
        embeddedMediaPreviewViewController = nil
        embeddedOpenProgressViewController = nil
        onEmbeddedCapabilityWillOpen?()
        view.layoutSubtreeIfNeeded()
        applyInitialEditorSplitPositionIfNeeded()
    }

    public func presentEmbeddedRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        onSaveText: ((String) throws -> Void)? = nil,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        if isViewLoaded == false {
            loadView()
        }
        if let embeddedEditorViewController,
           embeddedMediaPreviewViewController == nil
        {
            embeddedEditorViewController.openDocument(document, onSaveText: onSaveText)
            restoreCollapsedEmbeddedCapability()
            return
        }
        if embeddedOpenProgressViewController != nil,
           embeddedEditorViewController == nil,
           embeddedMediaPreviewViewController == nil
        {
            removeEmbeddedOpenProgressForReplacement()
        } else {
            guard closeEmbeddedCapabilityIfNeeded() else { return }
        }

        view.layoutSubtreeIfNeeded()
        let editor = RemoteTextEditorViewController(document: document, onSaveText: onSaveText)
        embeddedEditorCloseConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        editor.onCloseRequested = { [weak self] in
            _ = self?.closeEmbeddedEditorIfNeeded()
        }
        editor.onAIQuestionRequested = { [weak self] question in
            self?.onAIQuestionRequested?(question)
        }
        ensureEditorSplitViewAttached()
        addChild(editor)
        let editorView = editor.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        installCapabilityViewInSplit(editorView)
        installEditorSplitWidthConstraints(editorView: editorView)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        needsInitialEditorSplitPosition = true
        embeddedEditorViewController = editor
        embeddedMediaPreviewViewController = nil
        embeddedOpenProgressViewController = nil
        onEmbeddedCapabilityWillOpen?()
        view.layoutSubtreeIfNeeded()
        applyInitialEditorSplitPositionIfNeeded()
    }

    public func presentEmbeddedMediaPreview(localURL: URL) {
        presentEmbeddedEditor(localURL: localURL, saveHandler: nil)
    }

    public func requestAIForEmbeddedEditor() {
        embeddedEditorViewController?.requestAIForActiveDocument()
    }

    func beginEmbeddedOpenRequest(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> UUID? {
        guard presentEmbeddedOpenProgress(selection: selection, mode: mode) else {
            return nil
        }
        let requestID = UUID()
        embeddedOpenRequestIDs.insert(requestID)
        return requestID
    }

    func isEmbeddedOpenRequestActive(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return false
        }
        return embeddedOpenRequestIDs.contains(requestID)
    }

    func finishEmbeddedOpenRequest(_ requestID: UUID?) {
        guard let requestID,
              embeddedOpenRequestIDs.contains(requestID)
        else {
            return
        }
        embeddedOpenRequestIDs.remove(requestID)
    }

    @discardableResult
    public func presentEmbeddedOpenProgress(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        if isViewLoaded == false {
            loadView()
        }
        if embeddedOpenProgressViewController != nil,
           embeddedEditorViewController == nil,
           embeddedMediaPreviewViewController == nil
        {
            removeEmbeddedOpenProgressForReplacement()
        }
        guard embeddedEditorViewController == nil,
              embeddedMediaPreviewViewController == nil
        else {
            return true
        }
        guard closeEmbeddedCapabilityIfNeeded() else { return false }

        let progress = RemoteFileOpenProgressViewController(selection: selection, mode: mode)
        progress.onCloseRequested = { [weak self] in
            _ = self?.closeEmbeddedEditorIfNeeded()
        }
        ensureEditorSplitViewAttached()
        addChild(progress)
        let progressView = progress.view
        progressView.translatesAutoresizingMaskIntoConstraints = false
        installCapabilityViewInSplit(progressView)
        installEditorSplitWidthConstraints(editorView: progressView)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        needsInitialEditorSplitPosition = true
        embeddedEditorViewController = nil
        embeddedMediaPreviewViewController = nil
        embeddedOpenProgressViewController = progress
        onEmbeddedCapabilityWillOpen?()
        view.layoutSubtreeIfNeeded()
        applyInitialEditorSplitPositionIfNeeded()
        return true
    }

    public func presentEmbeddedOpenFailure(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        message: String
    ) {
        if let embeddedOpenProgressViewController {
            embeddedOpenProgressViewController.showFailure(message)
            return
        }
        guard presentEmbeddedOpenProgress(selection: selection, mode: mode),
              let embeddedOpenProgressViewController
        else {
            return
        }
        embeddedOpenProgressViewController.showFailure(message)
    }

    @discardableResult
    public func closeEmbeddedEditorIfNeeded() -> Bool {
        closeEmbeddedCapabilityIfNeeded()
    }

    @discardableResult
    private func closeEmbeddedCapabilityIfNeeded() -> Bool {
        let controller: NSViewController?
        if let editor = embeddedEditorViewController {
            controller = editor
        } else if let progress = embeddedOpenProgressViewController {
            controller = progress
        } else {
            controller = embeddedMediaPreviewViewController
        }
        guard let controller else {
            return true
        }
        if let editor = embeddedEditorViewController {
            let confirmer = embeddedEditorCloseConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
            guard editor.canClose(parentWindow: view.window, closeConfirmer: confirmer) else {
                return false
            }
        }
        let fileBrowserWidth = fileBrowserWidthForRestoredStandaloneMode()
        NSLayoutConstraint.deactivate(editorSplitWidthConstraints)
        editorSplitWidthConstraints = []
        fileBrowserMinimumWidthConstraint = nil
        fileBrowserCurrentWidthConstraint = nil
        fileBrowserWidthBeforeCollapse = nil
        isEmbeddedCapabilityCollapsed = false
        embeddedCapabilityExpandButton.isHidden = true
        needsInitialEditorSplitPosition = false
        fileBrowserPaneView.isHidden = false
        controller.view.isHidden = false
        contentSplitView.removeArrangedSubview(controller.view)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        embeddedEditorViewController = nil
        embeddedMediaPreviewViewController = nil
        embeddedOpenProgressViewController = nil
        embeddedOpenRequestIDs.removeAll()
        embeddedEditorCloseConfirmer = nil
        restoreStandaloneFileBrowserIfNeeded()
        onEmbeddedCapabilityClosed?(fileBrowserWidth)
        return true
    }

    private func removeEmbeddedOpenProgressForReplacement() {
        guard let progress = embeddedOpenProgressViewController else {
            return
        }
        NSLayoutConstraint.deactivate(editorSplitWidthConstraints)
        editorSplitWidthConstraints = []
        fileBrowserMinimumWidthConstraint = nil
        fileBrowserCurrentWidthConstraint = nil
        isEmbeddedCapabilityCollapsed = false
        embeddedCapabilityExpandButton.isHidden = true
        fileBrowserPaneView.isHidden = false
        progress.view.isHidden = false
        if contentSplitView.arrangedSubviews.contains(progress.view) {
            contentSplitView.removeArrangedSubview(progress.view)
        }
        progress.view.removeFromSuperview()
        progress.removeFromParent()
        embeddedOpenProgressViewController = nil
    }

    private func fileBrowserWidthForRestoredStandaloneMode() -> CGFloat {
        if fileBrowserPaneView.isHidden {
            return max(
                fileBrowserWidthBeforeCollapse ?? EditorCapabilityLayout.minimumBrowserWidth,
                EditorCapabilityLayout.minimumBrowserWidth
            )
        }
        if contentSplitView.superview != nil,
           embeddedCapabilityView() != nil
        {
            let width = fileBrowserPaneView.convert(fileBrowserPaneView.bounds, to: view).width
            if width.isFinite, width > 0 {
                return max(width, EditorCapabilityLayout.minimumBrowserWidth)
            }
            if let constrainedWidth = fileBrowserCurrentWidthConstraint?.constant,
               constrainedWidth.isFinite,
               constrainedWidth > 0
            {
                return max(constrainedWidth, EditorCapabilityLayout.minimumBrowserWidth)
            }
        }
        if let lastKnownVisibleFileBrowserWidth,
           lastKnownVisibleFileBrowserWidth.isFinite,
           lastKnownVisibleFileBrowserWidth > 0
        {
            return max(lastKnownVisibleFileBrowserWidth, EditorCapabilityLayout.minimumBrowserWidth)
        }
        let visibleRectWidth = fileBrowserPaneView.visibleRect.width
        if visibleRectWidth.isFinite, visibleRectWidth > 0 {
            return max(visibleRectWidth, EditorCapabilityLayout.minimumBrowserWidth)
        }
        if let contentView = fileBrowserPaneView.window?.contentView {
            let rootFrame = view.convert(view.bounds, to: contentView)
            let browserFrame = fileBrowserPaneView.convert(fileBrowserPaneView.bounds, to: contentView)
            let rightAlignedVisibleWidth = rootFrame.maxX - browserFrame.minX
            if rightAlignedVisibleWidth.isFinite, rightAlignedVisibleWidth > 0 {
                return max(rightAlignedVisibleWidth, EditorCapabilityLayout.minimumBrowserWidth)
            }
            if browserFrame.width.isFinite, browserFrame.width > 0 {
                return max(browserFrame.width, EditorCapabilityLayout.minimumBrowserWidth)
            }
        }
        if let constrainedWidth = fileBrowserCurrentWidthConstraint?.constant,
           constrainedWidth.isFinite,
           constrainedWidth > 0
        {
            return max(constrainedWidth, EditorCapabilityLayout.minimumBrowserWidth)
        }
        let width = fileBrowserPaneView.convert(fileBrowserPaneView.bounds, to: view).width
        guard width.isFinite, width > 0 else {
            return max(
                fileBrowserCurrentWidthConstraint?.constant ?? EditorCapabilityLayout.minimumBrowserWidth,
                EditorCapabilityLayout.minimumBrowserWidth
            )
        }
        return max(width, EditorCapabilityLayout.minimumBrowserWidth)
    }

    private func rememberVisibleFileBrowserWidth() {
        guard fileBrowserPaneView.isHidden == false,
              contentSplitView.superview == nil,
              let contentView = fileBrowserPaneView.window?.contentView
        else {
            return
        }
        let rootFrame = view.convert(view.bounds, to: contentView)
        let browserFrame = fileBrowserPaneView.convert(fileBrowserPaneView.bounds, to: contentView)
        let width = rootFrame.maxX - browserFrame.minX
        guard width.isFinite, width > 0 else {
            return
        }
        lastKnownVisibleFileBrowserWidth = max(width, EditorCapabilityLayout.minimumBrowserWidth)
    }

    private func ensureEditorSplitViewAttached() {
        guard contentSplitView.superview == nil else {
            return
        }
        NSLayoutConstraint.deactivate(fileBrowserStandaloneConstraints)
        fileBrowserPaneView.removeFromSuperview()
        view.addSubview(contentSplitView)
        contentSplitConstraints = [
            contentSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            contentSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(contentSplitConstraints)
        contentSplitView.needsLayout = true
        synchronizeEditorSplitFrameWithRootIfNeeded()
        contentSplitView.adjustSubviews()
    }

    private func installCapabilityViewInSplit(_ capabilityView: NSView) {
        if contentSplitView.arrangedSubviews.contains(where: { $0 === fileBrowserPaneView }) {
            contentSplitView.removeArrangedSubview(fileBrowserPaneView)
            fileBrowserPaneView.removeFromSuperview()
        }
        contentSplitView.addArrangedSubview(capabilityView)
        contentSplitView.addArrangedSubview(fileBrowserPaneView)
    }

    private func restoreStandaloneFileBrowserIfNeeded() {
        guard contentSplitView.superview != nil else {
            return
        }
        contentSplitView.removeArrangedSubview(fileBrowserPaneView)
        fileBrowserPaneView.removeFromSuperview()
        NSLayoutConstraint.deactivate(contentSplitConstraints)
        contentSplitConstraints = []
        contentSplitView.removeFromSuperview()
        view.addSubview(fileBrowserPaneView)
        NSLayoutConstraint.activate(fileBrowserStandaloneConstraints)
        view.layoutSubtreeIfNeeded()
    }

    private func installEditorSplitWidthConstraints(editorView: NSView) {
        NSLayoutConstraint.deactivate(editorSplitWidthConstraints)
        let browserWidth = fileBrowserPaneView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: EditorCapabilityLayout.minimumBrowserWidth
        )
        let editorWidth = editorView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: EditorCapabilityLayout.minimumEditorWidth
        )
        let currentFileBrowserWidth = fileBrowserPaneView.widthAnchor.constraint(
            equalToConstant: EditorCapabilityLayout.minimumBrowserWidth
        )
        browserWidth.priority = .defaultHigh
        editorWidth.priority = .defaultHigh
        currentFileBrowserWidth.priority = NSLayoutConstraint.Priority(999)
        fileBrowserMinimumWidthConstraint = browserWidth
        fileBrowserCurrentWidthConstraint = currentFileBrowserWidth
        editorSplitWidthConstraints = [browserWidth, editorWidth, currentFileBrowserWidth]
        NSLayoutConstraint.activate(editorSplitWidthConstraints)
    }

    public func collapseEmbeddedCapability() {
        guard contentSplitView.superview != nil,
              contentSplitView.arrangedSubviews.count == 2,
              let capabilityView = embeddedCapabilityView(),
              !isEmbeddedCapabilityCollapsed
        else {
            return
        }
        let fileBrowserWidth = fileBrowserWidthForRestoredStandaloneMode()
        synchronizeEditorSplitFrameWithRootIfNeeded()
        NSLayoutConstraint.deactivate(editorSplitWidthConstraints)
        editorSplitWidthConstraints = []
        fileBrowserMinimumWidthConstraint = nil
        fileBrowserCurrentWidthConstraint = nil
        contentSplitView.removeArrangedSubview(capabilityView)
        capabilityView.removeFromSuperview()
        capabilityView.isHidden = true
        fileBrowserPaneView.isHidden = false
        isEmbeddedCapabilityCollapsed = true
        embeddedCapabilityExpandButton.isHidden = false
        contentSplitView.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        onEmbeddedCapabilityClosed?(fileBrowserWidth)
    }

    private func restoreCollapsedEmbeddedCapability() {
        guard isEmbeddedCapabilityCollapsed,
              contentSplitView.superview != nil,
              let capabilityView = embeddedCapabilityView()
        else {
            return
        }
        onEmbeddedCapabilityWillOpen?()
        capabilityView.isHidden = false
        isEmbeddedCapabilityCollapsed = false
        embeddedCapabilityExpandButton.isHidden = true
        installCapabilityViewInSplit(capabilityView)
        installEditorSplitWidthConstraints(editorView: capabilityView)
        needsInitialEditorSplitPosition = true
        view.layoutSubtreeIfNeeded()
        applyInitialEditorSplitPositionIfNeeded()
    }

    private func embeddedCapabilityView() -> NSView? {
        if let editor = embeddedEditorViewController {
            return editor.view
        }
        if let progress = embeddedOpenProgressViewController {
            return progress.view
        }
        return embeddedMediaPreviewViewController?.view
    }

    private func toggleFileBrowserVisibility() {
        guard contentSplitView.superview != nil,
              contentSplitView.arrangedSubviews.count == 2,
              embeddedCapabilityView() != nil
        else {
            return
        }
        synchronizeEditorSplitFrameWithRootIfNeeded()
        let availableWidth = contentSplitView.bounds.width
        guard availableWidth > 0 else { return }
        let dividerWidth = contentSplitView.dividerThickness

        let shouldCollapse = fileBrowserPaneView.isHidden == false
        if shouldCollapse == false {
            let restoredBrowserWidth = max(
                fileBrowserWidthBeforeCollapse ?? EditorCapabilityLayout.minimumBrowserWidth,
                EditorCapabilityLayout.minimumBrowserWidth
            )
            fileBrowserPaneView.isHidden = false
            fileBrowserMinimumWidthConstraint?.constant = EditorCapabilityLayout.minimumBrowserWidth
            fileBrowserCurrentWidthConstraint?.constant = restoredBrowserWidth
            let editorWidth = max(
                EditorCapabilityLayout.minimumEditorWidth,
                availableWidth - dividerWidth - restoredBrowserWidth
            )
            contentSplitView.setPosition(editorWidth, ofDividerAt: 0)
        } else {
            let currentBrowserWidth = fileBrowserPaneView.convert(
                fileBrowserPaneView.bounds,
                to: view
            ).width
            fileBrowserWidthBeforeCollapse = max(
                currentBrowserWidth,
                EditorCapabilityLayout.minimumBrowserWidth
            )
            fileBrowserMinimumWidthConstraint?.constant = 0
            fileBrowserCurrentWidthConstraint?.constant = 0
            fileBrowserPaneView.isHidden = true
            contentSplitView.setPosition(
                max(EditorCapabilityLayout.minimumEditorWidth, availableWidth - dividerWidth),
                ofDividerAt: 0
            )
        }
        fileBrowserPaneView.isHidden = shouldCollapse
        contentSplitView.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private func applyInitialEditorSplitPositionIfNeeded() {
        guard needsInitialEditorSplitPosition,
              contentSplitView.superview != nil,
              embeddedCapabilityView() != nil,
              contentSplitView.arrangedSubviews.count == 2
        else {
            return
        }
        synchronizeEditorSplitFrameWithRootIfNeeded()
        let availableWidth = contentSplitView.bounds.width
        guard availableWidth > 0 else { return }
        let dividerWidth = contentSplitView.dividerThickness
        let maximumEditorWidth = availableWidth
            - dividerWidth
            - EditorCapabilityLayout.minimumBrowserWidth
        guard maximumEditorWidth >= EditorCapabilityLayout.minimumEditorWidth else { return }

        let preferredWidth = max(
            EditorCapabilityLayout.preferredEditorWidth,
            availableWidth * EditorCapabilityLayout.preferredEditorWidthFraction
        )
        let editorWidth = min(max(preferredWidth, EditorCapabilityLayout.minimumEditorWidth), maximumEditorWidth)
        let browserWidth = availableWidth - dividerWidth - editorWidth
        fileBrowserCurrentWidthConstraint?.constant = browserWidth
        needsInitialEditorSplitPosition = false
        contentSplitView.setPosition(editorWidth, ofDividerAt: 0)
        fileBrowserCurrentWidthConstraint?.constant = browserWidth
        contentSplitView.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private func synchronizeEditorSplitFrameWithRootIfNeeded() {
        guard contentSplitView.superview != nil, view.bounds.width > 0, view.bounds.height > 0 else {
            return
        }
        let splitFrame = contentSplitView.frame
        guard splitFrame.size != view.bounds.size || splitFrame.origin != .zero else {
            return
        }
        contentSplitView.frame = view.bounds
        contentSplitView.layoutSubtreeIfNeeded()
    }

    private func synchronizeStandaloneFileBrowserFrameIfNeeded() {
        guard contentSplitView.superview == nil,
              fileBrowserPaneView.superview === view,
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return
        }

        if fileBrowserPaneView.frame != view.bounds {
            NSLayoutConstraint.deactivate(fileBrowserStandaloneConstraints)
            fileBrowserPaneView.translatesAutoresizingMaskIntoConstraints = true
            fileBrowserPaneView.autoresizingMask = [.width, .height]
            fileBrowserPaneView.frame = view.bounds
            fileBrowserPaneView.needsLayout = true
        }
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === contentSplitView,
              dividerIndex == 0,
              splitView.arrangedSubviews.count == 2
        else {
            return proposedPosition
        }
        let dividerWidth = splitView.dividerThickness
        let minimumBrowserWidth = fileBrowserPaneView.isHidden ? 0 : EditorCapabilityLayout.minimumBrowserWidth
        let maximumEditorWidth = splitView.bounds.width
            - dividerWidth
            - minimumBrowserWidth
        guard maximumEditorWidth >= EditorCapabilityLayout.minimumEditorWidth else {
            return proposedPosition
        }
        let editorWidth = min(
            max(proposedPosition, EditorCapabilityLayout.minimumEditorWidth),
            maximumEditorWidth
        )
        let browserWidth = splitView.bounds.width - dividerWidth - editorWidth
        fileBrowserCurrentWidthConstraint?.constant = browserWidth
        return editorWidth
    }

    public func setRemoteListingError(_ detail: String) {
        allRows = []
        rows = []
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDetail.isEmpty {
            emptyLabel.stringValue = "无法加载远端目录"
        } else {
            emptyLabel.stringValue = "无法加载远端目录\n\(trimmedDetail)"
        }
        setRefreshButtonTitle(L10n.Files.retry)
        tableView.reloadData()
        updateEmptyState()
    }

    public func containsRemoteEntry(named fileName: String) -> Bool {
        rows.contains { row in
            row.name == fileName
        }
    }

    public func selectionForRemotePath(_ remotePath: String) -> RemoteFileSelection? {
        let normalizedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPath.isEmpty == false else {
            return nil
        }
        return allRows.first { row in
            row.path == normalizedPath
        }?.selection
    }

    public var currentSelectedFileSelection: RemoteFileSelection? {
        selectedFileSelection()
    }

    public func selectRemotePath(_ remotePath: String) {
        let normalizedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPath.isEmpty == false else {
            tableView.deselectAll(nil)
            return
        }
        guard let index = rows.firstIndex(where: { $0.path == normalizedPath }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        updateActionStates()
    }

    public func selectSizeUnitForTesting(_ title: String) {
        guard let unit = FileSizeUnit(title: title) else {
            return
        }
        sizeUnitPopup.selectItem(withTitle: unit.title)
        applySizeUnit(unit)
    }

    public func selectSortModeForTesting(_ title: String) {
        guard let mode = RemoteFileSortMode(title: title) else {
            return
        }
        applySortMode(mode, persist: false)
    }

    public func sortColumnForTesting(identifier: String) {
        let mode = selectedSortMode.toggled(for: identifier)
        applySortMode(mode, persist: false)
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

        let identifier = NSUserInterfaceItemIdentifier("RemoteFileCell.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        cell.subviews.forEach { $0.removeFromSuperview() }

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = StacioDesignSystem.theme.primaryTextColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = rows[row].value(for: tableColumn.identifier.rawValue, sizeUnit: selectedSizeUnit)
        cell.textField = textField

        if tableColumn.identifier.rawValue == "name" {
            let imageView = NSImageView(image: StacioFileDisplay.remoteIcon(for: rows[row]))
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

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionStates()
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard isSynchronizingTableSortDescriptors == false,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let mode = RemoteFileSortMode(columnIdentifier: key, ascending: descriptor.ascending)
        else {
            return
        }
        applySortMode(mode, persist: true)
    }

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.handleDroppedLocalFilePaths(paths)
        }
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = min(width, 32)
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        return column
    }

    private func updateTableColumnWidths() {
        guard tableView.tableColumns.count >= 5,
              let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")),
              let sizeColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size")),
              let ownerColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("owner")),
              let permissionsColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("permissions")),
              let timeColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("time"))
        else { return }

        let visibleWidth = tableView.enclosingScrollView?.contentView.bounds.width ?? tableView.bounds.width
        guard visibleWidth.isFinite, visibleWidth > 0 else { return }

        let minimumWidths: [(NSTableColumn, CGFloat)] = [
            (nameColumn, 72),
            (sizeColumn, 40),
            (ownerColumn, 38),
            (permissionsColumn, 44),
            (timeColumn, 58)
        ]
        let preferredWidths: [(NSTableColumn, CGFloat)] = [
            (nameColumn, 150),
            (sizeColumn, 64),
            (ownerColumn, 58),
            (permissionsColumn, 64),
            (timeColumn, 88)
        ]
        let minimumTotal = minimumWidths.reduce(CGFloat(0)) { $0 + $1.1 }
        let preferredTotal = preferredWidths.reduce(CGFloat(0)) { $0 + $1.1 }
        let targetWidths: [(NSTableColumn, CGFloat)]
        if visibleWidth <= minimumTotal {
            let scale = max(0.72, visibleWidth / minimumTotal)
            targetWidths = minimumWidths.map { column, width in
                (column, max(32, floor(width * scale)))
            }
        } else {
            let extra = visibleWidth - minimumTotal
            let preferredExtra = preferredTotal - minimumTotal
            let progress = preferredExtra > 0 ? min(1, extra / preferredExtra) : 1
            var widths = zip(minimumWidths, preferredWidths).map { minimumPair, preferredPair in
                (minimumPair.0, minimumPair.1 + ((preferredPair.1 - minimumPair.1) * progress))
            }
            if visibleWidth > preferredTotal,
               let first = widths.first
            {
                widths[0] = (first.0, first.1 + (visibleWidth - preferredTotal))
            }
            targetWidths = widths
        }
        for (column, width) in targetWidths where abs(column.width - width) > 1 {
            column.width = width
        }
        let totalWidth = tableView.tableColumns.reduce(CGFloat(0)) { partialResult, column in
            partialResult + column.width
        }
        guard totalWidth > visibleWidth + 1 else { return }
        let overflow = totalWidth - visibleWidth
        nameColumn.width = max(44, nameColumn.width - overflow)
    }

    private func stylePathField() {
        StacioDesignSystem.styleTextField(pathField)
    }

    private func configureSizeUnitPopup() {
        sizeUnitPopup.removeAllItems()
        sizeUnitPopup.addItems(withTitles: FileSizeUnit.allCases.map(\.title))
        sizeUnitPopup.selectItem(withTitle: selectedSizeUnit.title)
        sizeUnitPopup.target = self
        sizeUnitPopup.action = #selector(sizeUnitChanged(_:))
        sizeUnitPopup.toolTip = "大小单位"
        sizeUnitPopup.setAccessibilityIdentifier("Stacio.Files.sizeUnit")
        sizeUnitPopup.setAccessibilityLabel("大小单位")
        sizeUnitPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeUnitPopup.controlSize = .small
        sizeUnitPopup.bezelStyle = .texturedRounded
        sizeUnitPopup.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configurePathBreadcrumbs() {
        pathBreadcrumbScrollView.contentView = pathBreadcrumbClipView
        pathBreadcrumbScrollView.documentView = pathBreadcrumbStack
        pathBreadcrumbScrollView.hasHorizontalScroller = false
        pathBreadcrumbScrollView.hasVerticalScroller = false
        pathBreadcrumbScrollView.autohidesScrollers = true
        pathBreadcrumbScrollView.borderType = .noBorder
        pathBreadcrumbScrollView.drawsBackground = false
        pathBreadcrumbScrollView.translatesAutoresizingMaskIntoConstraints = false
        pathBreadcrumbScrollView.setAccessibilityIdentifier("Stacio.Files.pathBreadcrumbs")

        pathBreadcrumbClipView.drawsBackground = false

        pathBreadcrumbStack.orientation = .horizontal
        pathBreadcrumbStack.alignment = .centerY
        pathBreadcrumbStack.spacing = 4
        pathBreadcrumbStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pathBreadcrumbStack.translatesAutoresizingMaskIntoConstraints = true
    }

    private func configureDirectoryFollowButton() {
        styleToolbarToggleButton(
            directoryFollowButton,
            symbolName: "arrow.triangle.2.circlepath",
            accessibilityLabel: "目录跟随"
        )
        directoryFollowButton.target = self
        directoryFollowButton.action = #selector(directoryFollowButtonChanged(_:))
        directoryFollowButton.state = directoryFollowEnabled ? .on : .off
        updateToolbarToggleButton(
            directoryFollowButton,
            enabled: directoryFollowEnabled,
            enabledTooltip: "停止跟随终端目录",
            disabledTooltip: "跟随终端 cd 命令切换目录"
        )
        directoryFollowButton.setAccessibilityIdentifier("Stacio.Files.directoryFollow")
    }

    private func configureShowHiddenFilesButton() {
        styleToolbarToggleButton(
            showHiddenFilesButton,
            symbolName: "eye",
            accessibilityLabel: L10n.Files.showHiddenFiles
        )
        showHiddenFilesButton.target = self
        showHiddenFilesButton.action = #selector(showHiddenFilesButtonChanged(_:))
        showHiddenFilesButton.state = showHiddenFilesEnabled ? .on : .off
        updateToolbarToggleButton(
            showHiddenFilesButton,
            enabled: showHiddenFilesEnabled,
            enabledTooltip: L10n.Files.hideHiddenFiles,
            disabledTooltip: L10n.Files.showHiddenFiles
        )
        showHiddenFilesButton.setAccessibilityIdentifier("Stacio.Files.showHiddenFiles")
    }

    private func configureSearchBar() {
        searchBar.orientation = .horizontal
        searchBar.alignment = .centerY
        searchBar.spacing = 6
        searchBar.isHidden = true
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.setAccessibilityIdentifier("Stacio.Files.searchBar")
        searchBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = "搜索文件名"
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted(_:))
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.controlSize = .small
        searchField.setAccessibilityIdentifier("Stacio.Files.searchField")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchDepthLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchDepthLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        searchDepthLabel.translatesAutoresizingMaskIntoConstraints = false
        searchDepthLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        searchDepthField.alignment = .center
        searchDepthField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        searchDepthField.controlSize = .small
        searchDepthField.target = self
        searchDepthField.action = #selector(searchDepthFieldSubmitted(_:))
        searchDepthField.setAccessibilityIdentifier("Stacio.Files.searchDepth")
        searchDepthField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTextField(searchDepthField)

        searchDepthStepper.minValue = 1
        searchDepthStepper.maxValue = 20
        searchDepthStepper.increment = 1
        searchDepthStepper.doubleValue = 5
        searchDepthStepper.target = self
        searchDepthStepper.action = #selector(searchDepthStepperChanged(_:))
        searchDepthStepper.setAccessibilityIdentifier("Stacio.Files.searchDepthStepper")
        searchDepthStepper.translatesAutoresizingMaskIntoConstraints = false

        searchBar.addArrangedSubview(searchField)
        searchBar.addArrangedSubview(searchDepthLabel)
        searchBar.addArrangedSubview(searchDepthField)
        searchBar.addArrangedSubview(searchDepthStepper)
    }

    private func styleToolbarToggleButton(_ button: NSButton, symbolName: String, accessibilityLabel: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
            ?? NSImage(size: NSSize(width: 14, height: 14))
        button.title = ""
        button.image = image
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.setButtonType(.toggle)
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.controlSize = .small
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(button)
    }

    private func updateToolbarToggleButton(
        _ button: NSButton,
        enabled: Bool,
        enabledTooltip: String,
        disabledTooltip: String
    ) {
        button.toolTip = enabled ? enabledTooltip : disabledTooltip
        button.contentTintColor = enabled
            ? StacioDesignSystem.theme.accentColor
            : StacioDesignSystem.theme.secondaryTextColor
    }

    private func configureTransferStatusStrip() {
        transferStatusContainer.translatesAutoresizingMaskIntoConstraints = false
        transferStatusContainer.isHidden = true
        transferStatusContainer.wantsLayer = true
        transferStatusContainer.layer?.cornerRadius = 6
        StacioDesignSystem.setLayerBackgroundColor(
            transferStatusContainer,
            color: StacioDesignSystem.theme.controlBackgroundColor
        )
        transferStatusContainer.setAccessibilityIdentifier("Stacio.Files.transferStatusStrip")

        transferStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        transferStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        transferStatusLabel.lineBreakMode = .byTruncatingMiddle
        transferStatusLabel.maximumNumberOfLines = 1
        transferStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        transferStatusLabel.setAccessibilityIdentifier("Stacio.Files.transferStatus")

        transferProgressIndicator.isIndeterminate = false
        transferProgressIndicator.minValue = 0
        transferProgressIndicator.maxValue = 100
        transferProgressIndicator.doubleValue = 0
        transferProgressIndicator.controlSize = .small
        transferProgressIndicator.style = .bar
        transferProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        transferProgressIndicator.setAccessibilityIdentifier("Stacio.Files.transferProgress")

        configureTransferStatusActionButton(
            transferPrimaryActionButton,
            identifier: "Stacio.Files.transferPrimaryAction"
        )
        configureTransferStatusActionButton(
            transferSecondaryActionButton,
            identifier: "Stacio.Files.transferSecondaryAction"
        )

        transferStatusActions.orientation = .horizontal
        transferStatusActions.alignment = .centerY
        transferStatusActions.spacing = 4
        transferStatusActions.distribution = .fill
        transferStatusActions.translatesAutoresizingMaskIntoConstraints = false
        transferStatusActions.setContentHuggingPriority(.required, for: .horizontal)
        transferStatusActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        transferStatusActions.addArrangedSubview(transferPrimaryActionButton)
        transferStatusActions.addArrangedSubview(transferSecondaryActionButton)

        transferStatusContainer.addSubview(transferStatusLabel)
        transferStatusContainer.addSubview(transferProgressIndicator)
        transferStatusContainer.addSubview(transferStatusActions)
        updateTransferStatusActionButtons(for: nil)
    }

    private func configureTransferStatusActionButton(_ button: NSButton, identifier: String) {
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(transferStatusActionButtonPressed(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(identifier)
        button.isEnabled = false
        button.isHidden = true
        StacioDesignSystem.styleIconButton(button)
    }

    private func updateTransferStatusActionButtons(for row: TransferQueueSnapshot.Row?) {
        let primaryAction = Self.primaryTransferStatusAction(for: row?.rawStatus)
        let secondaryAction = Self.secondaryTransferStatusAction(for: row?.rawStatus)
        updateTransferStatusActionButton(transferPrimaryActionButton, action: primaryAction)
        updateTransferStatusActionButton(transferSecondaryActionButton, action: secondaryAction)
        transferStatusActions.isHidden = primaryAction == nil && secondaryAction == nil
    }

    private func updateTransferStatusActionButton(_ button: NSButton, action: TransferQueueAction?) {
        guard let action,
              displayedTransferStatusRow != nil
        else {
            button.image = nil
            button.toolTip = nil
            button.setAccessibilityLabel(nil)
            button.isEnabled = false
            button.isHidden = true
            return
        }

        let label = Self.transferActionLabel(for: action)
        button.image = transferActionImage(for: action)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = true
        button.isHidden = false
    }

    @objc private func transferStatusActionButtonPressed(_ sender: NSButton) {
        guard sender.isEnabled,
              sender.isHidden == false,
              let row = displayedTransferStatusRow,
              let label = sender.accessibilityLabel(),
              let action = Self.transferAction(for: label)
        else {
            return
        }
        onTransferStatusAction?(action, row.jobID)
    }

    private func transferActionImage(for action: TransferQueueAction) -> NSImage {
        let label = Self.transferActionLabel(for: action)
        let symbolName = switch action {
        case .retry:
            "arrow.clockwise"
        case .resume:
            "play.fill"
        case .restart:
            "arrow.counterclockwise"
        case .stop:
            "stop.fill"
        case .pause:
            "pause.fill"
        }
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        {
            return image
        }
        return NSImage(size: NSSize(width: 14, height: 14))
    }

    private func updateEmptyState() {
        if rows.isEmpty,
           isRemoteSearchActive == false,
           allRows.contains(where: \.isHiddenItem),
           showHiddenFilesEnabled == false
        {
            emptyLabel.stringValue = L10n.Files.hiddenFilesFilteredEmpty
        }
        emptyLabel.isHidden = !rows.isEmpty
        updateActionStates()
    }

    private func preferredTransferStatusRow(from rows: [TransferQueueSnapshot.Row]) -> TransferQueueSnapshot.Row? {
        if let pinnedTransferStatusJobID,
           let pinnedRow = rows.first(where: { $0.jobID == pinnedTransferStatusJobID }),
           Self.isActiveTransferStatus(pinnedRow.rawStatus)
        {
            return pinnedRow
        }

        return rows.last { $0.rawStatus == "running" }
            ?? rows.last { $0.rawStatus == "queued" }
            ?? rows.last
    }

    private func transferMetric(
        for row: TransferQueueSnapshot.Row,
        capturedAt: Date
    ) -> FilesTransferMetric {
        guard row.rawStatus == "running" else {
            transferSamplesByJobID[row.jobID] = FilesTransferSample(
                bytesDone: row.bytesDone,
                capturedAt: capturedAt,
                bytesPerSecond: nil
            )
            return .empty
        }

        let previous = transferSamplesByJobID[row.jobID]
        var bytesPerSecond = previous?.bytesPerSecond
        if let previous,
           row.bytesDone > previous.bytesDone
        {
            let elapsed = capturedAt.timeIntervalSince(previous.capturedAt)
            if elapsed > 0 {
                bytesPerSecond = Double(row.bytesDone - previous.bytesDone) / elapsed
            }
        }

        transferSamplesByJobID[row.jobID] = FilesTransferSample(
            bytesDone: row.bytesDone,
            capturedAt: capturedAt,
            bytesPerSecond: bytesPerSecond
        )

        guard let bytesPerSecond,
              bytesPerSecond > 0
        else {
            return .empty
        }
        let remainingBytes = row.bytesTotal > row.bytesDone ? row.bytesTotal - row.bytesDone : 0
        return FilesTransferMetric(
            speedText: Self.formatTransferSpeed(bytesPerSecond: bytesPerSecond),
            etaText: Self.formatTransferETA(seconds: Double(remainingBytes) / bytesPerSecond)
        )
    }

    @objc private func refreshButtonPressed(_ sender: Any?) {
        onRefresh?(normalizedCurrentPath())
    }

    @objc private func searchButtonPressed(_ sender: Any?) {
        guard remoteSearchEnabled else {
            return
        }
        if searchBar.isHidden {
            showSearchBar()
            view.window?.makeFirstResponder(searchField)
        } else if isRemoteSearchActive {
            closeRemoteSearch(restoreDirectoryRows: true)
        } else {
            performRemoteSearchFromField()
        }
    }

    @objc private func searchFieldSubmitted(_ sender: Any?) {
        performRemoteSearchFromField()
    }

    @objc private func searchDepthFieldSubmitted(_ sender: Any?) {
        let depth = normalizedSearchDepth()
        searchDepthField.stringValue = "\(depth)"
        searchDepthStepper.doubleValue = Double(depth)
        performRemoteSearchFromField()
    }

    @objc private func searchDepthStepperChanged(_ sender: NSStepper) {
        let depth = Int(sender.doubleValue)
        searchDepthField.stringValue = "\(depth)"
        if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            performRemoteSearchFromField()
        }
    }

    @objc private func parentButtonPressed(_ sender: Any?) {
        let currentPath = normalizedCurrentPath()
        let parent = parentPath(for: currentPath)
        guard parent != currentPath else {
            updateActionStates()
            return
        }
        setCurrentRemotePath(parent)
        onRefresh?(parent)
    }

    @objc private func directoryFollowButtonChanged(_ sender: NSButton) {
        setDirectoryFollowEnabled(sender.state == .on)
    }

    @objc private func showHiddenFilesButtonChanged(_ sender: NSButton) {
        updateShowHiddenFilesEnabled(sender.state == .on, persist: true)
    }

    @objc private func openSelectedEntry(_ sender: Any?) {
        let selectedRow = tableView.selectedRow
        open(row: selectedRow)
    }

    @objc private func downloadButtonPressed(_ sender: Any?) {
        let selections = selectedFileSelections()
        guard !selections.isEmpty else {
            return
        }

        if let onDownloadSelections {
            onDownloadSelections(selections)
        } else {
            selections.forEach { onDownloadFile?($0) }
        }
    }

    @objc private func uploadButtonPressed(_ sender: Any?) {
        guard let button = sender as? NSButton else {
            uploadFileMenuItemPressed(sender)
            return
        }
        uploadMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func uploadFileMenuItemPressed(_ sender: Any?) {
        onUploadFile?(normalizedCurrentPath())
    }

    @objc private func uploadFolderMenuItemPressed(_ sender: Any?) {
        onUploadFolder?(normalizedCurrentPath())
    }

    @objc private func moreButtonPressed(_ sender: Any?) {
        guard let button = sender as? NSButton else {
            return
        }
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func sizeUnitChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let unit = FileSizeUnit(title: title)
        else {
            return
        }
        applySizeUnit(unit)
    }

    @objc private func embeddedCapabilityExpandButtonPressed(_ sender: Any?) {
        restoreCollapsedEmbeddedCapability()
    }

    private func handleDroppedLocalFilePaths(_ localPaths: [String]) {
        guard !localPaths.isEmpty else { return }
        onUploadDroppedFiles?(normalizedCurrentPath(), localPaths)
    }

    private func performRemoteSearchFromField() {
        guard remoteSearchEnabled else {
            return
        }
        let keyword = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            closeRemoteSearch(restoreDirectoryRows: true)
            return
        }
        let depth = normalizedSearchDepth()
        searchDepthField.stringValue = "\(depth)"
        searchDepthStepper.doubleValue = Double(depth)
        onSearchRemoteFiles?(keyword, normalizedCurrentPath(), depth)
    }

    @objc private func mkdirButtonPressed(_ sender: Any?) {
        onCreateDirectory?(normalizedCurrentPath())
    }

    @objc private func newFileButtonPressed(_ sender: Any?) {
        onCreateFile?(normalizedCurrentPath())
    }

    @objc private func renameButtonPressed(_ sender: Any?) {
        guard let selection = selectedFileSelection() else {
            return
        }
        onRenamePath?(selection)
    }

    @objc private func deleteButtonPressed(_ sender: Any?) {
        let selections = selectedFileSelections()
        guard selections.isEmpty == false else {
            return
        }
        delete(selections: selections)
    }

    @objc private func editLocalCopyButtonPressed(_ sender: Any?) {
        guard let selection = selectedFileSelection() else {
            return
        }
        onOpenRemoteEdit?(selection)
    }

    @objc private func saveEditedCopyButtonPressed(_ sender: Any?) {
        guard let selection = selectedFileSelection() else {
            return
        }
        onSaveRemoteEdit?(selection)
    }

    @objc private func syncChangedEditsButtonPressed(_ sender: Any?) {
        onSyncChangedRemoteEdits?()
    }

    @objc private func chmodButtonPressed(_ sender: Any?) {
        guard let selection = selectedFileSelection() else {
            return
        }
        onChmodPath?(selection)
    }

    @objc private func contextOpenPressed(_ sender: NSMenuItem) {
        open(row: contextMenuRow(for: sender))
    }

    @objc private func contextCreateDirectoryPressed(_ sender: NSMenuItem) {
        onCreateDirectory?(normalizedCurrentPath())
    }

    @objc private func contextCreateFilePressed(_ sender: NSMenuItem) {
        onCreateFile?(normalizedCurrentPath())
    }

    @objc private func contextOpenDefaultTextEditorPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        onOpenRemoteEdit?(selection)
    }

    @objc private func contextPreviewPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        onOpenRemotePreview?(selection)
    }

    @objc private func contextOpenWithPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        onOpenRemoteWith?(selection)
    }

    @objc private func contextOpenWithDefaultApplicationPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        onOpenRemoteWithDefaultApplication?(selection)
    }

    @objc private func contextCompareFilesPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        let selectedFileSelections = selectedFileSelections().filter(\.isFile)
        if selectedFileSelections.count >= 2,
           selectedFileSelections.contains(selection)
        {
            onCompareFiles?(selectedFileSelections)
            return
        }
        onCompareFiles?([selection])
    }

    @objc private func contextDownloadPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        if let onDownloadSelections {
            onDownloadSelections([selection])
        } else {
            onDownloadFile?(selection)
        }
    }

    @objc private func contextDeletePressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        let selectedSelections = selectedFileSelections()
        if selectedSelections.count > 1,
           selectedSelections.contains(selection)
        {
            delete(selections: selectedSelections)
            return
        }
        delete(selections: [selection])
    }

    @objc private func contextRenamePressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        onRenamePath?(selection)
    }

    @objc private func contextCopyPathPressed(_ sender: NSMenuItem) {
        contextCopyRemotePathPressed(sender)
    }

    @objc private func contextCopyRemotePathPressed(_ sender: NSMenuItem) {
        guard let row = row(for: contextMenuRow(for: sender)) else {
            return
        }
        copyPathToPasteboard(row.path)
    }

    @objc private func contextOpenContainingDirectoryInTerminalPressed(_ sender: NSMenuItem) {
        guard let row = row(for: contextMenuRow(for: sender)) else {
            return
        }
        let directory = row.isDirectory ? row.path : parentPath(for: row.path)
        onSendPathToTerminal?("cd \(shellQuotedPathForTerminal(directory))\n")
    }

    @objc private func contextSendPathToTerminalPressed(_ sender: NSMenuItem) {
        sendPathToTerminal(row: contextMenuRow(for: sender))
    }

    @objc private func contextSendFileNameToTerminalPressed(_ sender: NSMenuItem) {
        guard let row = row(for: contextMenuRow(for: sender)) else {
            return
        }
        onSendPathToTerminal?(row.name)
    }

    @objc private func contextPropertiesPressed(_ sender: NSMenuItem) {
        guard let row = row(for: contextMenuRow(for: sender)) else {
            return
        }
        showProperties(for: row)
    }

    @objc private func contextPermissionsPressed(_ sender: NSMenuItem) {
        guard let selection = selection(forRow: contextMenuRow(for: sender)) else {
            return
        }
        onChmodPath?(selection)
    }

    private func open(row rowIndex: Int) {
        guard let row = row(for: rowIndex) else {
            return
        }

        if let searchResult = row.searchResult {
            setCurrentRemotePath(searchResult.directoryPath)
            closeRemoteSearch(restoreDirectoryRows: false)
            if let onOpenSearchResult {
                onOpenSearchResult(searchResult)
            } else {
                onOpenDirectory?(searchResult.directoryPath)
            }
            return
        }

        if row.isDirectory {
            setCurrentRemotePath(row.path)
            onOpenDirectory?(row.path)
        } else if row.isPreviewableMediaFile {
            onOpenRemotePreview?(row.selection)
        } else if row.isFile {
            onOpenRemoteEdit?(row.selection)
        }
    }

    private func selectedFileSelection() -> RemoteFileSelection? {
        let selectedRow = tableView.selectedRow
        guard rows.indices.contains(selectedRow) else {
            return nil
        }
        let row = rows[selectedRow]
        return row.selection
    }

    private func selectedFileSelections() -> [RemoteFileSelection] {
        tableView.selectedRowIndexes.compactMap { rowIndex in
            guard rows.indices.contains(rowIndex) else {
                return nil
            }
            return rows[rowIndex].selection
        }
    }

    private func delete(selections: [RemoteFileSelection]) {
        guard selections.isEmpty == false else {
            return
        }
        if let onDeleteSelections {
            onDeleteSelections(selections)
        } else if let selection = selections.first {
            onDeletePath?(selection)
        }
    }

    private func row(for rowIndex: Int) -> RemoteFileRow? {
        guard rows.indices.contains(rowIndex) else {
            return nil
        }
        return rows[rowIndex]
    }

    private func selection(forRow rowIndex: Int) -> RemoteFileSelection? {
        row(for: rowIndex)?.selection
    }

    private func contextMenuRow(for item: NSMenuItem) -> Int {
        if let representedRow = item.representedObject as? Int {
            return representedRow
        }
        return rowContextMenuRow
    }

    private func contextMenu(forRow rowIndex: Int) -> NSMenu? {
        let effectiveRowIndex = rows.indices.contains(rowIndex) ? rowIndex : tableView.selectedRow
        let row = self.row(for: effectiveRowIndex)
        rowContextMenuRow = row == nil ? -1 : effectiveRowIndex
        let menu = NSMenu(title: L10n.Files.title)
        menu.autoenablesItems = false
        menu.addItem(makeContextMenuItem(title: L10n.Files.mkdir, action: #selector(contextCreateDirectoryPressed(_:)), row: rowIndex))
        menu.addItem(makeContextMenuItem(title: L10n.Files.newFile, action: #selector(contextCreateFilePressed(_:)), row: rowIndex))
        menu.addItem(makeContextMenuItem(
            title: L10n.Files.contextOpen,
            action: #selector(contextOpenPressed(_:)),
            row: rowContextMenuRow,
            isEnabled: row != nil
        ))
        if row?.isEditableFile == true {
            menu.addItem(makeContextMenuItem(
                title: L10n.Files.openWithDefaultTextEditor,
                action: #selector(contextOpenDefaultTextEditorPressed(_:)),
                row: rowContextMenuRow
            ))
        }
        if row?.isPreviewableMediaFile == true {
            menu.addItem(makeContextMenuItem(
                title: "在 Stacio 中预览",
                action: #selector(contextPreviewPressed(_:)),
                row: rowContextMenuRow
            ))
        }
        if row?.isFile == true {
            menu.addItem(makeContextMenuItem(
                title: L10n.Files.openWith,
                action: #selector(contextOpenWithPressed(_:)),
                row: rowContextMenuRow
            ))
            menu.addItem(makeContextMenuItem(
                title: L10n.Files.openWithDefaultApplication,
                action: #selector(contextOpenWithDefaultApplicationPressed(_:)),
                row: rowContextMenuRow
            ))
            menu.addItem(makeContextMenuItem(
                title: L10n.Files.compareFiles,
                action: #selector(contextCompareFilesPressed(_:)),
                row: rowContextMenuRow
            ))
        }
        menu.addItem(makeContextMenuItem(title: L10n.Files.contextDownload, action: #selector(contextDownloadPressed(_:)), row: rowContextMenuRow, isEnabled: row != nil))
        menu.addItem(makeContextMenuItem(title: L10n.Files.contextDelete, action: #selector(contextDeletePressed(_:)), row: rowContextMenuRow, isEnabled: row != nil))
        menu.addItem(makeContextMenuItem(title: L10n.Files.contextRename, action: #selector(contextRenamePressed(_:)), row: rowContextMenuRow, isEnabled: row != nil))
        menu.addItem(makeContextMenuItem(title: L10n.Files.copyPath, action: #selector(contextCopyPathPressed(_:)), row: rowContextMenuRow, isEnabled: row != nil))
        if row?.isFile == true {
            menu.addItem(makeContextMenuItem(
                title: L10n.Files.sendFileNameToTerminal,
                action: #selector(contextSendFileNameToTerminalPressed(_:)),
                row: rowContextMenuRow
            ))
        } else {
            menu.addItem(makeContextMenuItem(
                title: L10n.Files.sendPathToTerminal,
                action: #selector(contextSendPathToTerminalPressed(_:)),
                row: rowContextMenuRow,
                isEnabled: row != nil
            ))
        }
        menu.addItem(makeContextMenuItem(title: L10n.Files.properties, action: #selector(contextPropertiesPressed(_:)), row: rowContextMenuRow, isEnabled: row != nil))
        menu.addItem(makeContextMenuItem(title: L10n.Files.permissions, action: #selector(contextPermissionsPressed(_:)), row: rowContextMenuRow, isEnabled: row != nil))
        return menu
    }

    private func makeContextMenuItem(title: String, action: Selector, row: Int, isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = row
        item.isEnabled = isEnabled
        return item
    }

    private func copyPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func sendPathToTerminal(row rowIndex: Int) {
        guard let row = row(for: rowIndex) else {
            return
        }
        let text = row.isFile ? row.name : row.path
        onSendPathToTerminal?(text)
    }

    private func shellQuotedPathForTerminal(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "~"
        }
        if Self.isSafeUnquotedShellPath(trimmed) {
            return trimmed
        }
        if trimmed.hasPrefix("~/") {
            return "~/" + Self.singleQuotedShellString(String(trimmed.dropFirst(2)))
        }
        return Self.singleQuotedShellString(trimmed)
    }

    private static func isSafeUnquotedShellPath(_ path: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:~+-")
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func singleQuotedShellString(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func showProperties(for row: RemoteFileRow) {
        let text = [
            "名称：\(row.name)",
            "类型：\(row.kind)",
            "路径：\(row.path)",
            "用户：\(row.ownerText)",
            "权限：\(row.permissionsText)",
            "大小：\(RemoteFileRow.formatSize(row.displaySize, unit: selectedSizeUnit))",
            "时间：\(row.modifiedTimeText)"
        ].joined(separator: "\n")
        lastPresentedPropertiesText = text
        guard Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) == false else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Files.properties
        alert.informativeText = text
        alert.addButton(withTitle: L10n.Common.ok)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func normalizedCurrentPath() -> String {
        let trimmed = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    private func rebuildPathBreadcrumbs() {
        pathBreadcrumbStack.arrangedSubviews.forEach { view in
            pathBreadcrumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let components = breadcrumbComponents(for: normalizedCurrentPath())
        for (index, component) in components.enumerated() {
            if index > 0 {
                pathBreadcrumbStack.addArrangedSubview(makeBreadcrumbSeparator())
            }
            pathBreadcrumbStack.addArrangedSubview(makeBreadcrumbButton(title: component.title, path: component.path))
        }
        layoutPathBreadcrumbs()
        scrollPathBreadcrumbsToCurrentDirectory()
    }

    private func breadcrumbComponents(for path: String) -> [(title: String, path: String)] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return [(title: "~", path: "~")]
        }
        if trimmed == "/" {
            return [(title: "根目录", path: "/")]
        }
        if trimmed == "~" {
            return [(title: "~", path: "~")]
        }

        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            let parts = suffix.split(separator: "/").map(String.init).filter { $0.isEmpty == false }
            var accumulated = "~"
            var result: [(title: String, path: String)] = [(title: "~", path: "~")]
            for part in parts {
                accumulated += "/\(part)"
                result.append((title: part, path: accumulated))
            }
            return result
        }

        if trimmed.hasPrefix("/") {
            let parts = trimmed.split(separator: "/").map(String.init).filter { $0.isEmpty == false }
            var accumulated = ""
            var result: [(title: String, path: String)] = [(title: "根目录", path: "/")]
            for part in parts {
                accumulated += "/\(part)"
                result.append((title: part, path: accumulated))
            }
            return result
        }

        let parts = trimmed.split(separator: "/").map(String.init).filter { $0.isEmpty == false }
        var accumulated = ""
        return parts.map { part in
            accumulated = accumulated.isEmpty ? part : "\(accumulated)/\(part)"
            return (title: part, path: accumulated)
        }
    }

    private func makeBreadcrumbButton(title: String, path: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(pathBreadcrumbButtonPressed(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.contentTintColor = path == normalizedCurrentPath()
            ? StacioDesignSystem.theme.primaryTextColor
            : StacioDesignSystem.theme.secondaryTextColor
        button.lineBreakMode = .byTruncatingMiddle
        button.toolTip = path
        button.setAccessibilityLabel(path)
        button.setAccessibilityIdentifier("Stacio.Files.pathBreadcrumb")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeBreadcrumbSeparator() -> NSTextField {
        let separator = NSTextField(labelWithString: "/")
        separator.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        separator.textColor = StacioDesignSystem.theme.secondaryTextColor
        separator.setContentHuggingPriority(.required, for: .horizontal)
        separator.setContentCompressionResistancePriority(.required, for: .horizontal)
        return separator
    }

    private func layoutPathBreadcrumbs() {
        guard pathBreadcrumbStack.superview != nil else {
            return
        }
        let height = max(pathBreadcrumbScrollView.contentView.bounds.height, 28)
        let width = max(pathBreadcrumbStack.fittingSize.width, pathBreadcrumbScrollView.contentView.bounds.width)
        pathBreadcrumbStack.setFrameSize(NSSize(width: width, height: height))
        pathBreadcrumbStack.needsLayout = true
    }

    private func scrollPathBreadcrumbsToCurrentDirectory() {
        guard pathBreadcrumbStack.frame.width > pathBreadcrumbScrollView.contentView.bounds.width else {
            pathBreadcrumbClipView.scroll(to: .zero)
            pathBreadcrumbScrollView.reflectScrolledClipView(pathBreadcrumbClipView)
            return
        }
        let maxX = pathBreadcrumbStack.frame.width - pathBreadcrumbScrollView.contentView.bounds.width
        pathBreadcrumbClipView.scroll(to: NSPoint(x: max(0, maxX), y: 0))
        pathBreadcrumbScrollView.reflectScrolledClipView(pathBreadcrumbClipView)
    }

    @objc private func pathBreadcrumbButtonPressed(_ sender: NSButton) {
        guard let path = sender.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false
        else {
            return
        }
        setCurrentRemotePath(path)
        onRefresh?(path)
    }

    private func parentPath(for path: String) -> String {
        if path == "~" || path == "/" {
            return path
        }

        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalizedPath.hasPrefix("~/") {
            let suffix = String(normalizedPath.dropFirst(2))
            let parentSuffix = (suffix as NSString).deletingLastPathComponent
            return parentSuffix.isEmpty ? "~" : "~/\(parentSuffix)"
        }

        let parent = (normalizedPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func configureMoreMenu() {
        moreMenu.removeAllItems()
        moreMenu.autoenablesItems = false
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.mkdir, action: #selector(mkdirButtonPressed(_:))))
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.newFile, action: #selector(newFileButtonPressed(_:))))
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.rename, action: #selector(renameButtonPressed(_:))))
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.deleteRemote, action: #selector(deleteButtonPressed(_:))))
        moreMenu.addItem(NSMenuItem.separator())
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.editLocalCopy, action: #selector(editLocalCopyButtonPressed(_:))))
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.saveEditedCopy, action: #selector(saveEditedCopyButtonPressed(_:))))
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.syncChangedEdits, action: #selector(syncChangedEditsButtonPressed(_:))))
        moreMenu.addItem(NSMenuItem.separator())
        moreMenu.addItem(makeMoreMenuItem(title: L10n.Files.chmod, action: #selector(chmodButtonPressed(_:))))
    }

    private func configureUploadMenu() {
        uploadMenu.removeAllItems()
        uploadMenu.autoenablesItems = false
        uploadMenu.addItem(makeUploadMenuItem(title: L10n.Files.uploadFile, action: #selector(uploadFileMenuItemPressed(_:))))
        uploadMenu.addItem(makeUploadMenuItem(title: L10n.Files.uploadFolder, action: #selector(uploadFolderMenuItemPressed(_:))))
    }

    private func updateActionStates() {
        let selectedRow = tableView.selectedRow
        let selectedEntry = rows.indices.contains(selectedRow) ? rows[selectedRow] : nil
        let hasSelection = selectedEntry != nil
        let hasDownloadSelection = !selectedFileSelections().isEmpty

        parentButton.isEnabled = parentPath(for: normalizedCurrentPath()) != normalizedCurrentPath()
        refreshButton.isEnabled = true
        searchButton.isEnabled = remoteSearchEnabled
        uploadButton.isEnabled = true
        moreButton.isEnabled = true
        downloadButton.isEnabled = hasDownloadSelection
        setMoreMenuItemEnabled(true, title: L10n.Files.mkdir)
        setMoreMenuItemEnabled(true, title: L10n.Files.newFile)
        setMoreMenuItemEnabled(hasSelection, title: L10n.Files.rename)
        setMoreMenuItemEnabled(hasSelection, title: L10n.Files.deleteRemote)
        setMoreMenuItemEnabled(selectedEntry?.isEditableFile == true, title: L10n.Files.editLocalCopy)
        setMoreMenuItemEnabled(selectedEntry?.isEditableFile == true, title: L10n.Files.saveEditedCopy)
        setMoreMenuItemEnabled(true, title: L10n.Files.syncChangedEdits)
        setMoreMenuItemEnabled(hasSelection, title: L10n.Files.chmod)
    }

    private func applyRemoteRowFilter() {
        let selectedPaths = selectedFileSelections().map(\.path)
        let sourceRows = isRemoteSearchActive ? searchRows : allRows
        let visibleRows = showHiddenFilesEnabled ? sourceRows : sourceRows.filter { $0.isHiddenItem == false }
        rows = sortRowsForDisplay(visibleRows)
        tableView.reloadData()
        if selectedPaths.isEmpty == false {
            let restoredIndexes = rows.enumerated().reduce(into: IndexSet()) { indexes, pair in
                if selectedPaths.contains(pair.element.path) {
                    indexes.insert(pair.offset)
                }
            }
            tableView.selectRowIndexes(restoredIndexes, byExtendingSelection: false)
        }
        updateEmptyState()
    }

    private func applySortMode(_ mode: RemoteFileSortMode, persist: Bool) {
        selectedSortMode = mode
        synchronizeTableSortDescriptors()
        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKey.sortMode)
        }
        applyRemoteRowFilter()
    }

    private func sortRowsForDisplay(_ unsortedRows: [RemoteFileRow]) -> [RemoteFileRow] {
        unsortedRows.sorted { lhs, rhs in
            compare(lhs, rhs, using: selectedSortMode)
        }
    }

    private func compare(_ lhs: RemoteFileRow, _ rhs: RemoteFileRow, using sortMode: RemoteFileSortMode) -> Bool {
        if lhs.displayGroup != rhs.displayGroup {
            return lhs.displayGroup < rhs.displayGroup
        }
        switch sortMode {
        case .nameAscending:
            return compareNames(lhs, rhs, ascending: true)
        case .nameDescending:
            return compareNames(lhs, rhs, ascending: false)
        case .sizeAscending:
            if lhs.rawSize != rhs.rawSize {
                return lhs.rawSize < rhs.rawSize
            }
            return compareNames(lhs, rhs, ascending: true)
        case .sizeDescending:
            if lhs.rawSize != rhs.rawSize {
                return lhs.rawSize > rhs.rawSize
            }
            return compareNames(lhs, rhs, ascending: true)
        case .ownerAscending:
            return compareText(lhs.ownerText, rhs.ownerText, lhs: lhs, rhs: rhs, ascending: true)
        case .ownerDescending:
            return compareText(lhs.ownerText, rhs.ownerText, lhs: lhs, rhs: rhs, ascending: false)
        case .permissionsAscending:
            return compareText(lhs.permissionsText, rhs.permissionsText, lhs: lhs, rhs: rhs, ascending: true)
        case .permissionsDescending:
            return compareText(lhs.permissionsText, rhs.permissionsText, lhs: lhs, rhs: rhs, ascending: false)
        case .modifiedTimeAscending:
            let leftTime = lhs.modifiedTimeSortValue
            let rightTime = rhs.modifiedTimeSortValue
            if leftTime != rightTime {
                return leftTime < rightTime
            }
            return compareNames(lhs, rhs, ascending: true)
        case .modifiedTimeDescending:
            let leftTime = lhs.modifiedTimeSortValue
            let rightTime = rhs.modifiedTimeSortValue
            if leftTime != rightTime {
                return leftTime > rightTime
            }
            return compareNames(lhs, rhs, ascending: true)
        }
    }

    private func compareText(
        _ leftText: String,
        _ rightText: String,
        lhs: RemoteFileRow,
        rhs: RemoteFileRow,
        ascending: Bool
    ) -> Bool {
        let result = leftText.localizedCaseInsensitiveCompare(rightText)
        if result == .orderedSame {
            return compareNames(lhs, rhs, ascending: true)
        }
        return result == (ascending ? .orderedAscending : .orderedDescending)
    }

    private func compareNames(_ lhs: RemoteFileRow, _ rhs: RemoteFileRow, ascending: Bool) -> Bool {
        let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if result == .orderedSame {
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == (ascending ? .orderedAscending : .orderedDescending)
        }
        return result == (ascending ? .orderedAscending : .orderedDescending)
    }

    private func showSearchBar() {
        guard remoteSearchEnabled else {
            return
        }
        searchBar.isHidden = false
        searchBarHeightConstraint?.constant = 30
        searchButton.contentTintColor = StacioDesignSystem.theme.accentColor
        view.needsLayout = true
    }

    @discardableResult
    private func closeRemoteSearch(restoreDirectoryRows: Bool) -> Bool {
        guard isRemoteSearchActive || searchBar.isHidden == false else {
            return false
        }
        let shouldNotifyClose = isRemoteSearchActive
        isRemoteSearchActive = false
        searchRows = []
        searchKeyword = ""
        searchBaseDirectory = normalizedCurrentPath()
        searchField.stringValue = ""
        searchBar.isHidden = true
        searchBarHeightConstraint?.constant = 0
        searchButton.contentTintColor = nil
        restoreDirectoryColumnTitles()
        if restoreDirectoryRows {
            applyRemoteRowFilter()
        } else {
            rows = []
            tableView.reloadData()
            updateEmptyState()
        }
        view.needsLayout = true
        if shouldNotifyClose {
            onRemoteSearchClosed?()
        }
        return true
    }

    private func setSearchColumnTitles() {
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size"))?.title = "相对路径"
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("owner"))?.title = "用户"
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("permissions"))?.title = "权限"
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("time"))?.title = "时间"
    }

    private func restoreDirectoryColumnTitles() {
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size"))?.title = "大小"
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("owner"))?.title = "用户"
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("permissions"))?.title = "权限"
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("time"))?.title = "时间"
    }

    private func synchronizeTableSortDescriptors() {
        let descriptor = NSSortDescriptor(key: selectedSortMode.columnIdentifier, ascending: selectedSortMode.isAscending)
        isSynchronizingTableSortDescriptors = true
        tableView.sortDescriptors = [descriptor]
        isSynchronizingTableSortDescriptors = false
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        guard let sortedColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(selectedSortMode.columnIdentifier)) else {
            return
        }
        let imageName = selectedSortMode.isAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
        tableView.setIndicatorImage(NSImage(named: NSImage.Name(imageName)), in: sortedColumn)
    }

    private func normalizedSearchDepth() -> Int {
        let value = Int(searchDepthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int(searchDepthStepper.doubleValue)
        return min(max(value, 1), 20)
    }

    private func setMoreMenuItemEnabled(_ isEnabled: Bool, title: String) {
        moreMenu.items.first { $0.title == title }?.isEnabled = isEnabled
    }

    private func makeMoreMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeUploadMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func setRefreshButtonTitle(_ title: String) {
        refreshButton.toolTip = title
        refreshButton.setAccessibilityLabel(refreshButton.toolTip)
    }

    private func applySizeUnit(_ unit: FileSizeUnit) {
        selectedSizeUnit = unit
        tableView.reloadData()
    }

    private static func inferCurrentDirectory(from entries: [RemoteFileEntry]) -> String? {
        let parentPaths = Set(entries.compactMap { entry -> String? in
            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.isEmpty == false else {
                return nil
            }
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        })
        guard parentPaths.count == 1 else {
            return nil
        }
        return parentPaths.first
    }

    private static func loadPersistedSortMode(defaults: UserDefaults = .standard) -> RemoteFileSortMode {
        guard let rawValue = defaults.string(forKey: PreferenceKey.sortMode),
              let mode = RemoteFileSortMode(rawValue: rawValue)
        else {
            return .nameAscending
        }
        return mode
    }

    private static func loadPersistedShowHiddenFiles(defaults: UserDefaults = .standard) -> Bool? {
        guard defaults.object(forKey: PreferenceKey.showHiddenFiles) != nil else {
            return nil
        }
        return defaults.bool(forKey: PreferenceKey.showHiddenFiles)
    }

    private static var isRunningUnitTests: Bool {
        Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    private static func makeToolbarButton(
        title: String,
        symbolName: String,
        accessibilityDescription: String,
        identifier: String
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(size: NSSize(width: 14, height: 14))
        let button = NSButton(title: "", image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = accessibilityDescription
        button.setAccessibilityLabel(accessibilityDescription)
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleToolbarButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        return button
    }

    private static func transferDisplayName(for row: TransferQueueSnapshot.Row) -> String {
        let path = row.direction == .upload ? row.sourcePath : row.destinationPath
        let fileName = (path as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileName.isEmpty ? path : fileName
    }

    private static func isActiveTransferStatus(_ rawStatus: String) -> Bool {
        rawStatus == "running" || rawStatus == "queued" || rawStatus == "paused"
    }

    private static func primaryTransferStatusAction(for rawStatus: String?) -> TransferQueueAction? {
        switch rawStatus {
        case "queued", "running":
            .pause
        case "paused":
            .resume
        default:
            nil
        }
    }

    private static func secondaryTransferStatusAction(for rawStatus: String?) -> TransferQueueAction? {
        switch rawStatus {
        case "queued", "running", "paused":
            .stop
        case "failed", "stopped", "canceled", "cancelled":
            .retry
        default:
            nil
        }
    }

    private static func transferActionLabel(for action: TransferQueueAction) -> String {
        switch action {
        case .retry:
            return L10n.Transfers.retry
        case .pause:
            return L10n.Transfers.pause
        case .resume:
            return L10n.Transfers.resume
        case .restart:
            return L10n.Transfers.restart
        case .stop:
            return L10n.Transfers.stop
        }
    }

    private static func transferAction(for label: String) -> TransferQueueAction? {
        switch label {
        case L10n.Transfers.retry:
            return .retry
        case L10n.Transfers.pause:
            return .pause
        case L10n.Transfers.resume:
            return .resume
        case L10n.Transfers.restart:
            return .restart
        case L10n.Transfers.stop:
            return .stop
        default:
            return nil
        }
    }

    private static func formatTransferProgress(bytesDone: UInt64, bytesTotal: UInt64) -> String {
        guard bytesTotal > 0 else {
            return "0%"
        }
        return "\(Int(transferProgressValue(bytesDone: bytesDone, bytesTotal: bytesTotal)))%"
    }

    private static func transferProgressValue(bytesDone: UInt64, bytesTotal: UInt64) -> Double {
        guard bytesTotal > 0 else {
            return 0
        }
        return min(100, max(0, (Double(bytesDone) / Double(bytesTotal)) * 100))
    }

    private static func formatTransferSpeed(bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_024 {
            return "\(Int(bytesPerSecond.rounded())) B/s"
        }
        if bytesPerSecond < 1_024 * 1_024 {
            return "\(formatTransferDecimal(bytesPerSecond / 1_024)) KB/s"
        }
        return "\(formatTransferDecimal(bytesPerSecond / 1_024 / 1_024)) MB/s"
    }

    private static func formatTransferETA(seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.up)))
        if wholeSeconds < 60 {
            return "\(wholeSeconds) 秒"
        }
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes) 分" : "\(minutes) 分 \(seconds) 秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMinutes) 分"
    }

    private static func formatTransferDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded(.down) == rounded {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}

enum FileSizeUnit: String, CaseIterable {
    case bytes = "B"
    case kilobytes = "KB"
    case megabytes = "MB"
    case gigabytes = "GB"
    case terabytes = "TB"

    init?(title: String) {
        self.init(rawValue: title)
    }

    var title: String {
        rawValue
    }

    var divisor: Double {
        switch self {
        case .bytes:
            1
        case .kilobytes:
            1_024
        case .megabytes:
            1_024 * 1_024
        case .gigabytes:
            1_024 * 1_024 * 1_024
        case .terabytes:
            1_024 * 1_024 * 1_024 * 1_024
        }
    }
}

struct RemoteFileRow: StacioFileDisplayRow {
    let name: String
    let kind: String
    let kindValue: RemoteFileKind
    let path: String
    let displaySize: UInt64
    let modifiedTimeText: String
    let ownerText: String
    let permissionsText: String
    let isEditableFile: Bool
    let isPreviewableMediaFile: Bool
    let rawSize: UInt64
    let selection: RemoteFileSelection
    let searchResult: RemoteFileSearchResult?

    init(entry: RemoteFileEntry) {
        name = (entry.path as NSString).lastPathComponent
        kindValue = entry.kind
        kind = switch entry.kind {
        case .file: "文件"
        case .directory: "目录"
        case .symlink: "符号链接"
        }
        path = entry.path
        displaySize = entry.size
        modifiedTimeText = StacioFileDisplay.remoteTimeText(entry.modifiedTime)
        ownerText = Self.metadataText(entry.owner)
        permissionsText = Self.metadataText(entry.permissions)
        let contentKind = StacioFileDisplay.contentKind(forFileName: name)
        isEditableFile = entry.kind == .file && contentKind.isEditableText
        isPreviewableMediaFile = entry.kind == .file && contentKind.isPreviewableMedia
        rawSize = entry.kind == .symlink ? 0 : entry.size
        selection = RemoteFileSelection(
            path: entry.path,
            size: rawSize,
            kind: entry.kind,
            modifiedTime: entry.modifiedTime
        )
        searchResult = nil
    }

    init(entry: RemoteFileEntry, searchBaseDirectory: String) {
        let result = RemoteFileSearchResult(entry: entry, baseDirectory: searchBaseDirectory)
        name = result.fileName
        kindValue = entry.kind
        kind = switch entry.kind {
        case .file: "文件"
        case .directory: "目录"
        case .symlink: "符号链接"
        }
        path = result.path
        displaySize = entry.size
        modifiedTimeText = StacioFileDisplay.remoteTimeText(entry.modifiedTime)
        ownerText = Self.metadataText(entry.owner)
        permissionsText = Self.metadataText(entry.permissions)
        let contentKind = StacioFileDisplay.contentKind(forFileName: name)
        isEditableFile = entry.kind == .file && contentKind.isEditableText
        isPreviewableMediaFile = entry.kind == .file && contentKind.isPreviewableMedia
        rawSize = entry.kind == .symlink ? 0 : entry.size
        selection = result.selection
        searchResult = result
    }

    var isDirectory: Bool {
        kindValue == .directory
    }

    var isHiddenItem: Bool {
        name.hasPrefix(".")
    }

    var isFile: Bool {
        kindValue == .file
    }

    var modifiedTimeSortValue: TimeInterval {
        Self.sortValue(forModifiedTime: selection.modifiedTime)
    }

    func visibleValues(sizeUnit: FileSizeUnit) -> [String] {
        [
            name,
            searchResult?.relativePath ?? Self.formatSize(displaySize, unit: sizeUnit),
            ownerText,
            permissionsText,
            modifiedTimeText
        ]
    }

    func value(for columnIdentifier: String, sizeUnit: FileSizeUnit) -> String {
        switch columnIdentifier {
        case "name": name
        case "size": searchResult?.relativePath ?? Self.formatSize(displaySize, unit: sizeUnit)
        case "owner": ownerText
        case "permissions": permissionsText
        case "time": modifiedTimeText
        default: ""
        }
    }

    private static func sortValue(forModifiedTime value: String?) -> TimeInterval {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.isEmpty == false, text != "-" else {
            return -.infinity
        }
        if let date = iso8601DateFormatter.date(from: text) {
            return date.timeIntervalSinceReferenceDate
        }
        for formatter in modifiedTimeDateFormatters {
            if let date = formatter.date(from: text) {
                return date.timeIntervalSinceReferenceDate
            }
        }
        return Double(text.unicodeScalars.reduce(UInt64(0)) { partialResult, scalar in
            partialResult &* 31 &+ UInt64(scalar.value)
        })
    }

    static func formatSize(_ size: UInt64, unit: FileSizeUnit) -> String {
        if unit == .bytes {
            return "\(size) B"
        }
        let value = Double(size) / unit.divisor
        return String(format: "%.2f %@", value, unit.title)
    }

    private static func metadataText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unavailableMetadataPlaceholder : trimmed
    }

    private static let iso8601DateFormatter = ISO8601DateFormatter()
    private static let unavailableMetadataPlaceholder = "—"

    private static let modifiedTimeDateFormatters: [DateFormatter] = [
        makeModifiedTimeDateFormatter("yyyy-MM-dd HH:mm"),
        makeModifiedTimeDateFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
        makeModifiedTimeDateFormatter("MM-dd HH:mm"),
        makeModifiedTimeDateFormatter("MMM d HH:mm"),
        makeModifiedTimeDateFormatter("MMM dd HH:mm"),
        makeModifiedTimeDateFormatter("MMM d yyyy"),
        makeModifiedTimeDateFormatter("MMM dd yyyy")
    ]

    private static func makeModifiedTimeDateFormatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        formatter.defaultDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: 1, day: 1))
        return formatter
    }
}

private struct FilesTransferSample {
    let bytesDone: UInt64
    let capturedAt: Date
    let bytesPerSecond: Double?
}

private struct FilesTransferMetric {
    static let empty = FilesTransferMetric(speedText: "", etaText: "")

    let speedText: String
    let etaText: String
}

public final class RemoteFilesTableView: NSTableView {
    public var rowContextMenuProvider: ((Int) -> NSMenu?)?
    public var middleClickRowHandler: ((Int) -> Void)?
    var localFileDropHandler: (([String]) -> Void)? {
        didSet {
            LocalFileDropHandler.register(self)
        }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.localFileDropHandler?(paths)
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0, selectedRowIndexes.contains(clickedRow) == false {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return rowContextMenuProvider?(clickedRow)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else {
            return
        }
        if selectedRowIndexes.contains(clickedRow) == false {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        middleClickRowHandler?(clickedRow)
    }
}

private final class RemoteFilesDropScrollView: NSScrollView {
    var localFileDropHandler: (([String]) -> Void)? {
        didSet {
            LocalFileDropHandler.register(self)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.localFileDropHandler?(paths)
        }
    }
}

private final class RemoteFilesDropClipView: NSClipView {
    var localFileDropHandler: (([String]) -> Void)? {
        didSet {
            LocalFileDropHandler.register(self)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.localFileDropHandler?(paths)
        }
    }
}

private final class FilesShortcutRootView: NSView {
    var onToggleFileBrowser: (() -> Void)?
    var onCloseRemoteSearch: (() -> Bool)?
    var onToggleHiddenFiles: (() -> Void)?
    var localFileDropHandler: (([String]) -> Void)? {
        didSet {
            LocalFileDropHandler.register(self)
        }
    }

    override var fittingSize: NSSize {
        let size = super.fittingSize
        return NSSize(width: 320, height: size.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        LocalFileDropHandler.operation(for: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        LocalFileDropHandler.performDrop(from: sender) { [weak self] paths in
            self?.localFileDropHandler?(paths)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            return onCloseRemoteSearch?() == true || super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "b"
        {
            onToggleFileBrowser?()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           flags.contains(.shift),
           event.charactersIgnoringModifiers == "."
        {
            onToggleHiddenFiles?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CompressibleFilesPaneView: NSView {
    override var fittingSize: NSSize {
        let size = super.fittingSize
        return NSSize(width: 0, height: size.height)
    }
}
