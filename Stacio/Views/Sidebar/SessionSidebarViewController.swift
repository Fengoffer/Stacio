import AppKit
import StacioCoreBindings

@MainActor
public final class SessionSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let sidebarItemPasteboardType = NSPasteboard.PasteboardType("cn.stacio.session-sidebar-item")

    private let sessionStore: SessionSidebarStoring?
    private let onOpenSession: (SessionRecord) throws -> Void
    private let sessionEditor: SessionSidebarSessionEditing
    private let sessionDeleteConfirmer: SessionSidebarSessionDeleteConfirming
    private let operationsPresenter: SessionSidebarOperationsPresenting
    private let errorPresenter: SessionSidebarErrorPresenting
    private let credentialCleaner: SessionSidebarCredentialCleaning?
    private let onDeleteSessionHistory: (String) -> Void
    private let remoteEditCacheCleaner: RemoteEditSessionCacheClearing?
    private let hostPinger: SessionSidebarHostPinging
    private let shortcutCreator: SessionSidebarShortcutCreating
    private let defaultPresetStore: SessionSidebarDefaultPresetStoring
    private let settingsCopier: SessionSidebarSettingsCopying
    private let secureSessionTransferExporter: SecureSessionTransferExporting
    private let secureSessionTransferPassphrasePrompter: SecureSessionTransferPassphrasePrompting
    private let quickConnectPromptPrefillStore: QuickConnectPromptPrefillStore
    private let clipboardDismissalStore: QuickConnectClipboardDismissalStore
    private let settingsStore: AppSettingsStore
    private let licenseAccess: any LicenseFeatureAccessProviding
    private var activePingRuns: [String: SessionSidebarPingRunning] = [:]
    private var activePingPresenters: [String: SessionSidebarPingProgressPresenting] = [:]
    private var allNodes: [NSObject] = []
    private var nodes: [NSObject] = []
    private var manualSessionIconIDs: [String: String] = [:]
    private var expandedFolderKeys: Set<String> = []
    private var hasInitializedExpansionState = false
    private var searchQuery = ""
    private weak var newGroupButton: NSButton?
    private weak var expandAllButton: NSButton?
    private weak var collapseAllButton: NSButton?
    private weak var clipboardSuggestionBanner: SessionSidebarClipboardSuggestionBannerView?
    private weak var updateStatusContainer: NSView?
    private weak var updateStatusLabel: NSTextField?
    private var updateStatusHeightConstraint: NSLayoutConstraint?
    private var sessionTreeBottomConstraint: NSLayoutConstraint?
    private var currentClipboardSuggestion: QuickConnectParsedSSHCommand?
    private var clipboardDismissWorkItem: DispatchWorkItem?
    private var appActivationObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var showsRecentSessions: Bool
    public let outlineView: NSOutlineView = SessionSidebarOutlineView()

    public init(
        sessionStore: SessionSidebarStoring? = nil,
        onOpenSession: @escaping (SessionRecord) throws -> Void = { _ in },
        sessionEditor: SessionSidebarSessionEditing? = nil,
        sessionDeleteConfirmer: SessionSidebarSessionDeleteConfirming? = nil,
        operationsPresenter: SessionSidebarOperationsPresenting? = nil,
        errorPresenter: SessionSidebarErrorPresenting? = nil,
        credentialCleaner: SessionSidebarCredentialCleaning? = nil,
        remoteEditCacheCleaner: RemoteEditSessionCacheClearing? = RemoteEditCache.defaultCache(),
        onDeleteSessionHistory: @escaping (String) -> Void = { _ in },
        hostPinger: SessionSidebarHostPinging = SystemSessionSidebarHostPinger(),
        shortcutCreator: SessionSidebarShortcutCreating = WeblocSessionSidebarShortcutCreator(),
        defaultPresetStore: SessionSidebarDefaultPresetStoring = UserDefaultsSessionSidebarDefaultPresetStore(),
        settingsCopier: SessionSidebarSettingsCopying = PasteboardSessionSidebarSettingsCopier(),
        secureSessionTransferExporter: SecureSessionTransferExporting = KeychainSecureSessionTransferExporter(),
        secureSessionTransferPassphrasePrompter: SecureSessionTransferPassphrasePrompting = AppKitSecureSessionTransferPassphrasePrompter(),
        quickConnectPromptPrefillStore: QuickConnectPromptPrefillStore = QuickConnectPromptPrefillStore(),
        clipboardDismissalStore: QuickConnectClipboardDismissalStore = QuickConnectClipboardDismissalStore(),
        settingsStore: AppSettingsStore = .shared,
        licenseAccess: any LicenseFeatureAccessProviding = UnrestrictedLicenseFeatureAccessProvider()
    ) {
        self.sessionStore = sessionStore
        self.onOpenSession = onOpenSession
        self.sessionEditor = sessionEditor ?? AppKitSessionSidebarSessionEditor()
        self.sessionDeleteConfirmer = sessionDeleteConfirmer ?? AppKitSessionSidebarSessionDeleteConfirmation()
        self.operationsPresenter = operationsPresenter ?? AppKitSessionSidebarOperationsPresenter()
        self.errorPresenter = errorPresenter ?? AppKitSessionSidebarErrorPresenter()
        self.credentialCleaner = credentialCleaner
        self.onDeleteSessionHistory = onDeleteSessionHistory
        self.remoteEditCacheCleaner = remoteEditCacheCleaner
        self.hostPinger = hostPinger
        self.shortcutCreator = shortcutCreator
        self.defaultPresetStore = defaultPresetStore
        self.settingsCopier = settingsCopier
        self.secureSessionTransferExporter = secureSessionTransferExporter
        self.secureSessionTransferPassphrasePrompter = secureSessionTransferPassphrasePrompter
        self.quickConnectPromptPrefillStore = quickConnectPromptPrefillStore
        self.clipboardDismissalStore = clipboardDismissalStore
        self.settingsStore = settingsStore
        self.licenseAccess = licenseAccess
        showsRecentSessions = settingsStore.snapshot().sessionSidebarShowRecentSessions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        clipboardDismissWorkItem?.cancel()
    }

    public override func loadView() {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applySidebarSurface(container)

        let searchField = NSSearchField()
        searchField.placeholderString = L10n.Sidebar.search
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier("Stacio.Sidebar.search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSearchField(searchField)

        let titleLabel = makeSectionLabel(L10n.Sidebar.sessions)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor

        let addGroupButton = makeManagementButton(
            symbolName: "folder.badge.plus",
            accessibilityDescription: L10n.Sidebar.newGroup,
            identifier: "Stacio.Sidebar.newGroup",
            action: #selector(addRootFolderButtonPressed(_:))
        )
        addGroupButton.isHidden = true
        newGroupButton = addGroupButton

        let collapseButton = makeManagementButton(
            symbolName: "chevron.right",
            accessibilityDescription: L10n.Sidebar.collapseAllGroups,
            identifier: "Stacio.Sidebar.collapseAllGroups",
            action: #selector(collapseAllFoldersButtonPressed(_:))
        )
        collapseAllButton = collapseButton
        let expandButton = makeManagementButton(
            symbolName: "chevron.down",
            accessibilityDescription: L10n.Sidebar.expandAllGroups,
            identifier: "Stacio.Sidebar.expandAllGroups",
            action: #selector(expandAllFoldersButtonPressed(_:))
        )
        expandAllButton = expandButton
        let titleActions = NSStackView(views: [collapseButton, expandButton, addGroupButton])
        titleActions.orientation = .horizontal
        titleActions.alignment = .centerY
        titleActions.spacing = 2
        titleActions.detachesHiddenViews = true
        titleActions.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = SessionSidebarHeaderHoverView(actionButton: addGroupButton)
        titleRow.setAccessibilityIdentifier("Stacio.Sidebar.sessionTitleRow")
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(titleLabel)
        titleRow.addSubview(titleActions)
        NSLayoutConstraint.activate([
            titleRow.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            titleActions.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            titleActions.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            titleActions.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor)
        ])

        let clipboardBanner = SessionSidebarClipboardSuggestionBannerView()
        clipboardBanner.isHidden = true
        clipboardBanner.openHandler = { [weak self] in
            self?.openClipboardSuggestion()
        }
        clipboardBanner.dismissHandler = { [weak self] in
            self?.dismissClipboardSuggestion(suppressCurrentClipboard: true)
        }
        clipboardBanner.translatesAutoresizingMaskIntoConstraints = false
        clipboardSuggestionBanner = clipboardBanner

        let header = NSStackView(views: [
            clipboardBanner,
            titleRow,
            searchField
        ])
        header.orientation = .vertical
        header.spacing = 7
        header.alignment = .width
        header.detachesHiddenViews = true
        header.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)
        header.setAccessibilityIdentifier("Stacio.Sidebar.header")
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SessionColumn"))
        column.title = L10n.Sidebar.sessions
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(openSelectedSession(_:))
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 44
        outlineView.registerForDraggedTypes([Self.sidebarItemPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        if let sidebarOutlineView = outlineView as? SessionSidebarOutlineView {
            sidebarOutlineView.rowContextMenuProvider = { [weak self] row in
                self?.contextMenu(forRow: row)
            }
        }
        outlineView.setAccessibilityIdentifier("Stacio.Sidebar.sessionOutline")

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let sessionTree = NSStackView(views: [scrollView])
        sessionTree.orientation = .vertical
        sessionTree.spacing = 0
        sessionTree.alignment = .width
        sessionTree.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 4, right: 2)
        sessionTree.setAccessibilityIdentifier("Stacio.Sidebar.a2SessionTree")
        sessionTree.translatesAutoresizingMaskIntoConstraints = false

        let updateStatus = NSView()
        updateStatus.translatesAutoresizingMaskIntoConstraints = false
        updateStatus.wantsLayer = true
        updateStatus.layer?.cornerRadius = 12
        updateStatus.layer?.backgroundColor = StacioDesignSystem.theme.warningColor.cgColor
        updateStatus.isHidden = true
        updateStatus.setAccessibilityIdentifier("Stacio.Sidebar.updateStatus")
        let updateLabel = NSTextField(labelWithString: "")
        updateLabel.translatesAutoresizingMaskIntoConstraints = false
        updateLabel.alignment = .center
        updateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        updateLabel.textColor = .white
        updateLabel.lineBreakMode = .byTruncatingTail
        updateLabel.setAccessibilityIdentifier("Stacio.Sidebar.updateStatusLabel")
        updateStatus.addSubview(updateLabel)
        let updateStatusHeightConstraint = updateStatus.heightAnchor.constraint(equalToConstant: 0)
        self.updateStatusHeightConstraint = updateStatusHeightConstraint
        NSLayoutConstraint.activate([
            updateLabel.leadingAnchor.constraint(equalTo: updateStatus.leadingAnchor, constant: 10),
            updateLabel.trailingAnchor.constraint(equalTo: updateStatus.trailingAnchor, constant: -10),
            updateLabel.centerYAnchor.constraint(equalTo: updateStatus.centerYAnchor),
            updateStatusHeightConstraint
        ])
        updateStatusContainer = updateStatus
        updateStatusLabel = updateLabel

        container.addSubview(header)
        container.addSubview(sessionTree)
        container.addSubview(updateStatus)
        let sessionTreeBottomConstraint = sessionTree.bottomAnchor.constraint(equalTo: updateStatus.topAnchor)
        self.sessionTreeBottomConstraint = sessionTreeBottomConstraint
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),

            sessionTree.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sessionTree.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sessionTree.topAnchor.constraint(equalTo: header.bottomAnchor),
            sessionTreeBottomConstraint,

            updateStatus.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            updateStatus.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            updateStatus.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        header.arrangedSubviews.forEach { arrangedSubview in
            arrangedSubview.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -16).isActive = true
        }

        observeSettingsChanges()
        reloadSessionNodes()
        view = container
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        startClipboardObservationIfNeeded()
        checkClipboardForSSHCommand()
    }

    public var outlineRootCount: Int {
        nodes.count
    }

    public func updateUpdateStatus(_ state: SparkleUpdateButtonState) {
        let isVisible: Bool
        switch state {
        case .downloading, .extracting, .installing, .failed:
            isVisible = true
        case .hidden, .available:
            isVisible = false
        }
        updateStatusLabel?.stringValue = state.title
        updateStatusContainer?.layer?.backgroundColor = {
            if case .failed = state {
                return StacioDesignSystem.theme.dangerColor.cgColor
            }
            return StacioDesignSystem.theme.warningColor.cgColor
        }()
        updateStatusHeightConstraint?.constant = isVisible ? 24 : 0
        sessionTreeBottomConstraint?.constant = isVisible ? -8 : 0
        updateStatusContainer?.isHidden = !isVisible
    }

    public var sessionOutlineTextSnapshot: String {
        nodes.flatMap(textSnapshot(for:))
        .joined(separator: "\n")
    }

    public var virtualGroupTitlesForTesting: [String] {
        nodes.compactMap { item in
            guard let folder = item as? SessionSidebarFolderNode,
                  folder.folder == nil
            else {
                return nil
            }
            return folder.title
        }
    }

    public func performOpenSessionForTesting(id: String) {
        guard let session = nodes
            .flatMap(allSessionNodes(in:))
            .first(where: { $0.session.id == id })?
            .session
        else {
            return
        }
        open(session)
    }

    public func performAddSessionForTesting() {
        addSession(selectedFolderID: nil)
    }

    public func performAddRootFolderForTesting() {
        createFolder(parentFolder: nil)
    }

    public func createSession() {
        addSession(selectedFolderID: nil)
    }

    public func createGroup() {
        createFolder(parentFolder: nil)
    }

    public func checkClipboardForSSHCommand() {
        guard let clipboardText = NSPasteboard.general.string(forType: .string),
              let suggestion = QuickConnectSSHCommandParser.parse(clipboardText),
              clipboardDismissalStore.isDismissed(fingerprint: suggestion.fingerprint) == false
        else {
            return
        }
        guard currentClipboardSuggestion?.fingerprint != suggestion.fingerprint
                || clipboardSuggestionBanner?.isHidden == true
        else {
            return
        }
        presentClipboardSuggestion(suggestion)
    }

    public func performEditSessionForTesting(id: String) {
        guard let session = sessionNode(id: id)?.session else {
            return
        }
        editSession(session)
    }

    public func performDeleteSessionForTesting(id: String) {
        guard let session = sessionNode(id: id)?.session else {
            return
        }
        deleteSessions([session])
    }

    public func performDuplicateSessionForTesting(id: String) {
        guard let session = sessionNode(id: id)?.session else {
            return
        }
        duplicateSession(session)
    }

    public func performMoveSessionForTesting(id: String) {
        guard let session = sessionNode(id: id)?.session else {
            return
        }
        moveSession(session)
    }

    public func performExportSessionsForTesting() {
        exportSessions()
    }

    public func contextMenuTitlesForTesting(id: String) -> [String] {
        guard let session = sessionNode(id: id)?.session else {
            return []
        }
        return makeContextMenu(for: session).items.map { item in
            item.isSeparatorItem ? "-" : item.title
        }
    }

    public func performContextMenuActionForTesting(_ action: SessionSidebarContextMenuAction, id: String) {
        guard let session = sessionNode(id: id)?.session else {
            return
        }
        performContextMenuAction(action, session: session)
    }

    public func folderContextMenuTitlesForTesting(folderID: String) -> [String] {
        guard let folder = folderNode(id: folderID) else {
            return []
        }
        return makeContextMenu(for: folder).items.map { item in
            item.isSeparatorItem ? "-" : item.title
        }
    }

    public func contextMenuTitlesForTesting(row: Int) -> [String] {
        contextMenu(forRow: row)?.items.map { item in
            item.isSeparatorItem ? "-" : item.title
        } ?? []
    }

    public func performSidebarDropForTesting(
        kind: String,
        id: String,
        targetFolderID: String?,
        targetIndex: Int
    ) -> Bool {
        guard let kind = SessionSidebarPersistedItemKind(rawValue: kind) else {
            return false
        }
        return performDrop(
            SessionSidebarDragPayload(kind: kind, id: id),
            proposal: SessionSidebarDropProposal(
                targetFolderID: targetFolderID,
                targetIndex: targetIndex
            )
        )
    }

    public func resolvedSidebarDropForTesting(
        kind: String,
        id: String,
        proposedFolderID: String?,
        childIndex: Int
    ) -> (targetFolderID: String?, targetIndex: Int)? {
        guard let kind = SessionSidebarPersistedItemKind(rawValue: kind) else {
            return nil
        }
        let item = proposedFolderID.flatMap { folderNode(id: $0) }
        guard let proposal = dropProposal(
            for: SessionSidebarDragPayload(kind: kind, id: id),
            proposedItem: item,
            childIndex: childIndex
        ) else {
            return nil
        }
        return (proposal.targetFolderID, proposal.targetIndex)
    }

    public func resolvedSidebarDropOnItemForTesting(
        kind: String,
        id: String,
        targetKind: String,
        targetID: String,
        insertAfter: Bool
    ) -> (targetFolderID: String?, targetIndex: Int)? {
        guard let kind = SessionSidebarPersistedItemKind(rawValue: kind) else {
            return nil
        }
        let targetItem: NSObject?
        switch SessionSidebarPersistedItemKind(rawValue: targetKind) {
        case .folder:
            targetItem = folderNode(id: targetID)
        case .session:
            targetItem = persistedSessionNode(id: targetID)
        case nil:
            return nil
        }
        let payload = SessionSidebarDragPayload(kind: kind, id: id)
        guard let targetItem,
              let dropTarget = resolvedOutlineDropTarget(
                  for: payload,
                  proposedItem: targetItem,
                  childIndex: NSOutlineViewDropOnItemIndex,
                  isAfterTarget: insertAfter
              ),
              let proposal = dropProposal(
                  for: payload,
                  proposedItem: dropTarget.item,
                  childIndex: dropTarget.childIndex
              )
        else {
            return nil
        }
        return (proposal.targetFolderID, proposal.targetIndex)
    }

    public func performExpandAllFoldersForTesting() {
        expandAllFolders()
    }

    public func performCollapseAllFoldersForTesting() {
        collapseAllFolders()
    }

    public func isFolderExpandedForTesting(folderID: String) -> Bool {
        guard let folder = folderNode(id: folderID) else {
            return false
        }
        return outlineView.isItemExpanded(folder)
    }

    public func performFolderContextMenuActionForTesting(
        _ action: SessionSidebarFolderContextMenuAction,
        folderID: String
    ) {
        guard let folder = folderNode(id: folderID) else {
            return
        }
        performContextMenuAction(action, folder: folder)
    }

    public var isNewGroupButtonHiddenForTesting: Bool {
        newGroupButton?.isHidden ?? true
    }

    public func reloadSessions() {
        reloadSessionNodes()
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        if let folder = item as? SessionSidebarFolderNode {
            return folder.children.count
        }
        return item == nil ? nodes.count : 0
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let folder = item as? SessionSidebarFolderNode else {
            return false
        }
        if folder.folder != nil {
            return true
        }
        return !folder.folders.isEmpty || !folder.sessions.isEmpty
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if let folder = item as? SessionSidebarFolderNode {
            return folder.children[index]
        }
        return nodes[index]
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard normalizedSearchQuery.isEmpty,
              let payload = dragPayload(for: item),
              let data = try? JSONEncoder().encode(payload)
        else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: Self.sidebarItemPasteboardType)
        return pasteboardItem
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard normalizedSearchQuery.isEmpty,
              (info.draggingSource as AnyObject?) === outlineView,
              let payload = dragPayload(from: info.draggingPasteboard),
              let dropTarget = resolvedOutlineDropTarget(
                  for: payload,
                  proposedItem: item,
                  childIndex: index,
                  isAfterTarget: dropInsertionSide(for: item, draggingInfo: info)
              ),
              dropProposal(
                  for: payload,
                  proposedItem: dropTarget.item,
                  childIndex: dropTarget.childIndex
              ) != nil
        else {
            return []
        }
        if dropTarget.childIndex != index {
            outlineView.setDropItem(dropTarget.item, dropChildIndex: dropTarget.childIndex)
        }
        return .move
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard normalizedSearchQuery.isEmpty,
              (info.draggingSource as AnyObject?) === outlineView,
              let payload = dragPayload(from: info.draggingPasteboard),
              let dropTarget = resolvedOutlineDropTarget(
                  for: payload,
                  proposedItem: item,
                  childIndex: index,
                  isAfterTarget: dropInsertionSide(for: item, draggingInfo: info)
              ),
              let proposal = dropProposal(
                  for: payload,
                  proposedItem: dropTarget.item,
                  childIndex: dropTarget.childIndex
              )
        else {
            return false
        }
        return performDrop(payload, proposal: proposal)
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let folder = item as? SessionSidebarFolderNode {
            return makeFolderCell(folder)
        }
        if let session = item as? SessionSidebarSessionNode {
            return makeSessionCell(session)
        }
        return nil
    }

    private func makeFolderCell(_ folder: SessionSidebarFolderNode) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("FolderCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SessionSidebarFolderCellView
            ?? SessionSidebarFolderCellView()
        cell.identifier = identifier
        cell.subviews.forEach { $0.removeFromSuperview() }

        let container = NSView()
        container.setAccessibilityIdentifier("Stacio.Sidebar.folderContainer")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            container,
            color: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.72)
        )
        StacioDesignSystem.setLayerBorderColor(
            container,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.34)
        )
        container.layer?.borderWidth = 1

        let iconView = makeRowIcon(
            symbolName: "folder",
            accessibilityDescription: "分组",
            identifier: "Stacio.Sidebar.folderIcon"
        )
        iconView.contentTintColor = StacioDesignSystem.theme.accentColor

        let titleLabel = NSTextField(labelWithString: folder.title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = titleLabel
        cell.addSubview(container)
        container.addSubview(iconView)
        container.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            container.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            container.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 30),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        cell.configureSelectionAppearance(
            container: container,
            iconView: iconView,
            titleLabel: titleLabel
        )
        return cell
    }

    private func makeSessionCell(_ session: SessionSidebarSessionNode) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("SessionCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        cell.subviews.forEach { $0.removeFromSuperview() }

        let titleLabel = NSTextField(labelWithString: session.title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: session.subtitle)
        subtitleLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        subtitleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let iconView: NSImageView
        if let iconID = manualSessionIconIDs[session.session.id],
           let image = SessionIconCatalog.image(for: iconID, size: NSSize(width: 18, height: 18)) {
            iconView = makeRowIcon(
                image: image,
                accessibilityDescription: image.accessibilityDescription ?? "会话图标",
                identifier: "Stacio.Sidebar.sessionProtocolIcon"
            )
        } else {
            let iconDescriptor = sessionProtocolIconDescriptor(for: session.session.protocol)
            iconView = makeRowIcon(
                symbolName: iconDescriptor.symbolName,
                accessibilityDescription: iconDescriptor.accessibilityDescription,
                identifier: "Stacio.Sidebar.sessionProtocolIcon"
            )
        }

        cell.textField = titleLabel
        cell.addSubview(iconView)
        cell.addSubview(titleLabel)
        cell.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -5)
        ])

        return cell
    }

    private func makeRowIcon(
        symbolName: String,
        accessibilityDescription: String,
        identifier: String
    ) -> NSImageView {
        let imageView = NSImageView(
            image: NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: accessibilityDescription
            ) ?? NSImage()
        )
        imageView.setAccessibilityIdentifier(identifier)
        imageView.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }

    private func makeRowIcon(
        image: NSImage,
        accessibilityDescription: String,
        identifier: String
    ) -> NSImageView {
        image.accessibilityDescription = accessibilityDescription
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityIdentifier(identifier)
        imageView.setAccessibilityLabel(accessibilityDescription)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }

    private func sessionProtocolIconDescriptor(for protocolName: String) -> (
        symbolName: String,
        accessibilityDescription: String
    ) {
        switch protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ssh":
            return ("terminal", "SSH")
        case "serial":
            return ("cable.connector", "串口")
        case "vnc":
            return ("rectangle.connected.to.line.below", "VNC")
        case "scp":
            return ("arrow.left.arrow.right.square", "SCP")
        case "ftp":
            return ("externaldrive.connected.to.line.below", "FTP")
        case "telnet":
            return ("terminal", "Telnet")
        case "browser", "web":
            return ("globe", "浏览器")
        case "file", "files":
            return ("folder", "文件")
        case "shell", "local":
            return ("terminal", "Shell")
        case "prd":
            return ("doc.richtext", "PRD")
        default:
            let label = protocolName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("network", label.isEmpty ? "会话" : label.uppercased())
        }
    }

    @objc
    private func searchFieldChanged(_ sender: NSSearchField) {
        if normalizedSearchQuery.isEmpty,
           sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            captureExpandedFolderState()
        }
        searchQuery = sender.stringValue
        applySearchFilter()
    }

    @objc
    private func editSessionButtonPressed(_ sender: Any?) {
        guard let session = selectedSession() else {
            return
        }
        editSession(session)
    }

    @objc
    private func deleteSessionButtonPressed(_ sender: Any?) {
        guard let session = selectedSession() else {
            return
        }
        deleteSessions([session])
    }

    @objc
    private func duplicateSessionButtonPressed(_ sender: Any?) {
        guard let session = selectedSession() else {
            return
        }
        duplicateSession(session)
    }

    @objc
    private func moveSessionButtonPressed(_ sender: Any?) {
        guard let session = selectedSession() else {
            return
        }
        moveSession(session)
    }

    @objc
    private func exportSessionsButtonPressed(_ sender: Any?) {
        exportSessions()
    }

    @objc
    private func addRootFolderButtonPressed(_ sender: Any?) {
        createFolder(parentFolder: nil)
    }

    @objc
    private func expandAllFoldersButtonPressed(_ sender: Any?) {
        expandAllFolders()
    }

    @objc
    private func collapseAllFoldersButtonPressed(_ sender: Any?) {
        collapseAllFolders()
    }

    @objc
    private func contextMenuItemSelected(_ sender: NSMenuItem) {
        if let represented = sender.representedObject as? ContextMenuRepresentedAction,
           let session = sessionNode(id: represented.sessionID)?.session {
            performContextMenuAction(represented.action, session: session)
            return
        }
        if let represented = sender.representedObject as? FolderContextMenuRepresentedAction,
           let folder = folderNode(id: represented.folderID) {
            performContextMenuAction(represented.action, folder: folder)
        }
    }

    @objc
    private func openSelectedSession(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SessionSidebarSessionNode
        else {
            return
        }
        open(node.session)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0 else {
            return nil
        }
        if let session = outlineView.item(atRow: row) as? SessionSidebarSessionNode {
            return makeContextMenu(
                for: session.session,
                includesManagementActions: session.isPersistedRepresentation
            )
        }
        if let folder = outlineView.item(atRow: row) as? SessionSidebarFolderNode,
           folder.folder != nil {
            return makeContextMenu(for: folder)
        }
        return nil
    }

    private func makeContextMenu(
        for session: SessionRecord,
        includesManagementActions: Bool = true
    ) -> NSMenu {
        let menu = NSMenu(title: session.name)
        [
            (L10n.Sidebar.executeSession, SessionSidebarContextMenuAction.execute),
            (L10n.Sidebar.connectAs, .connectAs),
            (L10n.Sidebar.pingHost, .pingHost)
        ].forEach { title, action in
            menu.addItem(makeContextMenuItem(title: title, action: action, session: session))
        }
        guard includesManagementActions else {
            return menu
        }
        menu.addItem(.separator())
        [
            (L10n.Sidebar.renameSession, SessionSidebarContextMenuAction.rename),
            (L10n.Sidebar.editSession, .edit),
            (L10n.Sidebar.deleteSession, .delete),
            (L10n.Sidebar.duplicateSession, .duplicate),
            (L10n.Sidebar.moveSession, .move),
            (L10n.Sidebar.saveSessionToFile, .saveToFile),
            (L10n.Sidebar.createDesktopShortcut, .createDesktopShortcut)
        ].forEach { title, action in
            menu.addItem(makeContextMenuItem(title: title, action: action, session: session))
        }
        menu.addItem(.separator())
        [
            (L10n.Sidebar.saveAsDefaultPreset, SessionSidebarContextMenuAction.saveAsDefaultPreset),
            (L10n.Sidebar.copySessionSettings, .copySettings)
        ].forEach { title, action in
            menu.addItem(makeContextMenuItem(title: title, action: action, session: session))
        }
        return menu
    }

    private func makeContextMenu(for folder: SessionSidebarFolderNode) -> NSMenu {
        let menu = NSMenu(title: folder.title)
        [
            (L10n.Sidebar.newGroup, SessionSidebarFolderContextMenuAction.createChild),
            (L10n.Sidebar.renameGroup, .rename),
            (L10n.Sidebar.deleteGroup, .delete),
            (L10n.Sidebar.exportGroupSessions, .export)
        ].forEach { title, action in
            menu.addItem(makeContextMenuItem(title: title, action: action, folder: folder))
        }
        return menu
    }

    private func makeContextMenuItem(
        title: String,
        action: SessionSidebarContextMenuAction,
        session: SessionRecord
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(contextMenuItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ContextMenuRepresentedAction(action: action, sessionID: session.id)
        return item
    }

    private func makeContextMenuItem(
        title: String,
        action: SessionSidebarFolderContextMenuAction,
        folder: SessionSidebarFolderNode
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(contextMenuItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = FolderContextMenuRepresentedAction(action: action, folderID: folder.id ?? "")
        return item
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dragPayload(for item: Any) -> SessionSidebarDragPayload? {
        if let folder = item as? SessionSidebarFolderNode,
           let id = folder.id {
            return SessionSidebarDragPayload(kind: .folder, id: id)
        }
        if let session = item as? SessionSidebarSessionNode,
           session.isPersistedRepresentation {
            return SessionSidebarDragPayload(kind: .session, id: session.session.id)
        }
        return nil
    }

    private func dragPayload(from pasteboard: NSPasteboard) -> SessionSidebarDragPayload? {
        guard let data = pasteboard.data(forType: Self.sidebarItemPasteboardType) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionSidebarDragPayload.self, from: data)
    }

    private func resolvedOutlineDropTarget(
        for payload: SessionSidebarDragPayload,
        proposedItem item: Any?,
        childIndex: Int,
        isAfterTarget: Bool?
    ) -> SessionSidebarOutlineDropTarget? {
        guard childIndex == NSOutlineViewDropOnItemIndex else {
            return SessionSidebarOutlineDropTarget(item: item, childIndex: childIndex)
        }
        if payload.kind == .session,
           let folder = item as? SessionSidebarFolderNode,
           folder.id != nil {
            return SessionSidebarOutlineDropTarget(item: item, childIndex: childIndex)
        }
        guard let target = item as? NSObject,
              persistedItemKey(for: target) != nil,
              let isAfterTarget
        else {
            return nil
        }
        return siblingInsertionTarget(around: target, insertAfter: isAfterTarget)
    }

    private func dropInsertionSide(for item: Any?, draggingInfo: NSDraggingInfo) -> Bool? {
        guard let item,
              outlineView.row(forItem: item) >= 0
        else {
            return nil
        }
        let row = outlineView.row(forItem: item)
        let point = outlineView.convert(draggingInfo.draggingLocation, from: nil)
        let midpoint = outlineView.rect(ofRow: row).midY
        return outlineView.isFlipped ? point.y >= midpoint : point.y < midpoint
    }

    private func siblingInsertionTarget(
        around target: NSObject,
        insertAfter: Bool
    ) -> SessionSidebarOutlineDropTarget? {
        siblingInsertionTarget(
            around: target,
            insertAfter: insertAfter,
            in: nodes,
            parent: nil
        )
    }

    private func siblingInsertionTarget(
        around target: NSObject,
        insertAfter: Bool,
        in items: [NSObject],
        parent: SessionSidebarFolderNode?
    ) -> SessionSidebarOutlineDropTarget? {
        for (index, item) in items.enumerated() {
            if item === target {
                return SessionSidebarOutlineDropTarget(
                    item: parent,
                    childIndex: index + (insertAfter ? 1 : 0)
                )
            }
            if let folder = item as? SessionSidebarFolderNode,
               let result = siblingInsertionTarget(
                   around: target,
                   insertAfter: insertAfter,
                   in: folder.children,
                   parent: folder
               ) {
                return result
            }
        }
        return nil
    }

    private func dropProposal(
        for payload: SessionSidebarDragPayload,
        proposedItem item: Any?,
        childIndex: Int
    ) -> SessionSidebarDropProposal? {
        guard let sourceLocation = sourceLocation(for: payload) else {
            return nil
        }
        let sourceParentID = sourceLocation.parentFolderID

        if childIndex == NSOutlineViewDropOnItemIndex {
            guard payload.kind == .session,
                  let folder = item as? SessionSidebarFolderNode,
                  let targetFolderID = folder.id
            else {
                return nil
            }
            var targetIndex = folder.children.compactMap(persistedItemKey(for:)).count
            if sourceParentID == targetFolderID,
               folder.children.contains(where: { persistedItemKey(for: $0) == payload.key }) {
                targetIndex -= 1
            }
            return SessionSidebarDropProposal(
                targetFolderID: targetFolderID,
                targetIndex: max(0, targetIndex)
            )
        }

        guard childIndex >= 0 else {
            return nil
        }
        let targetFolderID: String?
        let displayedChildren: [NSObject]
        if item == nil {
            targetFolderID = nil
            displayedChildren = nodes
        } else if let folder = item as? SessionSidebarFolderNode,
                  let folderID = folder.id {
            targetFolderID = folderID
            displayedChildren = folder.children
        } else {
            return nil
        }
        guard childIndex <= displayedChildren.count else {
            return nil
        }
        if payload.kind == .folder,
           sourceParentID != targetFolderID {
            return nil
        }

        let precedingItems = displayedChildren.prefix(childIndex)
        var targetIndex = precedingItems.compactMap(persistedItemKey(for:)).count
        if sourceParentID == targetFolderID,
           precedingItems.contains(where: { persistedItemKey(for: $0) == payload.key }) {
            targetIndex -= 1
        }
        return SessionSidebarDropProposal(
            targetFolderID: targetFolderID,
            targetIndex: max(0, targetIndex)
        )
    }

    private func sourceLocation(for payload: SessionSidebarDragPayload) -> SessionSidebarSourceLocation? {
        switch payload.kind {
        case .folder:
            guard let folder = folderNode(id: payload.id)?.folder else {
                return nil
            }
            return SessionSidebarSourceLocation(parentFolderID: folder.parentId)
        case .session:
            guard let session = persistedSessionNode(id: payload.id)?.session else {
                return nil
            }
            return SessionSidebarSourceLocation(parentFolderID: session.folderId)
        }
    }

    private func persistedItemKey(for item: NSObject) -> SessionSidebarPersistedItemKey? {
        if let folder = item as? SessionSidebarFolderNode,
           let id = folder.id {
            return SessionSidebarPersistedItemKey(kind: .folder, id: id)
        }
        if let session = item as? SessionSidebarSessionNode,
           session.isPersistedRepresentation {
            return SessionSidebarPersistedItemKey(kind: .session, id: session.session.id)
        }
        return nil
    }

    @discardableResult
    private func performDrop(
        _ payload: SessionSidebarDragPayload,
        proposal: SessionSidebarDropProposal
    ) -> Bool {
        guard normalizedSearchQuery.isEmpty,
              let sessionStore
        else {
            return false
        }
        do {
            if hasInitializedExpansionState,
               normalizedSearchQuery.isEmpty {
                captureExpandedFolderState()
            }
            try sessionStore.placeSidebarItem(
                kind: payload.kind.rawValue,
                id: payload.id,
                targetFolderID: proposal.targetFolderID,
                targetIndex: UInt32(clamping: proposal.targetIndex)
            )
            if let targetFolderID = proposal.targetFolderID {
                expandFolderAndAncestors(id: targetFolderID)
            }
            reloadSessionNodes(captureExpansionState: false)
            selectPersistedItem(payload.key)
            return true
        } catch {
            let context: SessionSidebarErrorContext = payload.kind == .session ? .moveSession : .updateFolder
            errorPresenter.present(error, context: context, parentWindow: view.window)
            return false
        }
    }

    private func performContextMenuAction(_ action: SessionSidebarContextMenuAction, session: SessionRecord) {
        switch action {
        case .execute:
            open(session)
        case .connectAs:
            connectAs(session)
        case .pingHost:
            pingHost(session)
        case .rename:
            renameSession(session)
        case .edit:
            editSession(session)
        case .delete:
            deleteSessions([session])
        case .duplicate:
            duplicateSession(session)
        case .move:
            moveSession(session)
        case .saveToFile:
            saveSingleSessionToFile(session)
        case .createDesktopShortcut:
            createDesktopShortcut(session)
        case .saveAsDefaultPreset:
            saveDefaultPreset(session)
        case .copySettings:
            copySessionSettings(session)
        }
    }

    private func performContextMenuAction(
        _ action: SessionSidebarFolderContextMenuAction,
        folder: SessionSidebarFolderNode
    ) {
        switch action {
        case .createChild:
            createFolder(parentFolder: folder.folder)
        case .rename:
            renameFolder(folder)
        case .delete:
            deleteFolder(folder)
        case .export:
            exportFolder(folder)
        }
    }

    private func open(_ session: SessionRecord) {
        do {
            try onOpenSession(session)
        } catch {
            errorPresenter.present(error, context: .openSession, parentWindow: view.window)
        }
    }

    private func startClipboardObservationIfNeeded() {
        guard appActivationObserver == nil else {
            return
        }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.checkClipboardForSSHCommand()
            }
        }
    }

    private func presentClipboardSuggestion(_ suggestion: QuickConnectParsedSSHCommand) {
        currentClipboardSuggestion = suggestion
        clipboardSuggestionBanner?.configure(
            message: "检测到 SSH 命令：\(suggestion.displayTarget) — 快速连接"
        )
        clipboardSuggestionBanner?.isHidden = false
        scheduleClipboardSuggestionAutoDismiss()
    }

    private func scheduleClipboardSuggestionAutoDismiss() {
        clipboardDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor [weak self] in
                self?.dismissClipboardSuggestion(suppressCurrentClipboard: false)
            }
        }
        clipboardDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func dismissClipboardSuggestion(suppressCurrentClipboard: Bool) {
        clipboardDismissWorkItem?.cancel()
        clipboardDismissWorkItem = nil
        if suppressCurrentClipboard,
           let fingerprint = currentClipboardSuggestion?.fingerprint {
            clipboardDismissalStore.dismiss(fingerprint: fingerprint)
        }
        currentClipboardSuggestion = nil
        clipboardSuggestionBanner?.isHidden = true
    }

    private func openClipboardSuggestion() {
        guard let suggestion = currentClipboardSuggestion else {
            return
        }
        dismissClipboardSuggestion(suppressCurrentClipboard: false)
        beginQuickConnect(with: suggestion.request, sender: clipboardSuggestionBanner)
    }

    private func beginQuickConnect(with request: QuickConnectRequest, sender: Any?) {
        quickConnectPromptPrefillStore.save(request)
        let selector = NSSelectorFromString("performQuickConnectFromToolbar:")
        if let windowController = view.window?.windowController as? NSObject,
           windowController.responds(to: selector) {
            windowController.perform(selector, with: sender)
            return
        }
        NSApplication.shared.sendAction(selector, to: nil, from: sender)
    }

    private func addSession(selectedFolderID: String?) {
        guard let sessionStore,
              let draft = sessionEditor.makeSessionDraft(
                existingSession: nil,
                selectedFolderID: selectedFolderID,
                parentWindow: view.window
              )
        else {
            return
        }

        do {
            _ = try sessionStore.createSession(draft)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .createSession, parentWindow: view.window)
        }
    }

    private func createFolder(parentFolder: SessionFolder?) {
        guard let sessionStore,
              let name = operationsPresenter.promptCreateFolder(
                parentFolder: parentFolder,
                parentWindow: view.window
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return
        }

        do {
            _ = try sessionStore.createFolder(parentID: parentFolder?.id, name: name)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .createFolder, parentWindow: view.window)
        }
    }

    private func editSession(_ session: SessionRecord) {
        guard let sessionStore,
              let draft = sessionEditor.makeSessionDraft(
                existingSession: session,
                selectedFolderID: session.folderId,
                parentWindow: view.window
              )
        else {
            return
        }

        do {
            _ = try sessionStore.updateSession(
                id: session.id,
                update: SessionUpdate(
                    name: draft.name,
                    protocol: draft.protocol,
                    folderId: draft.folderId,
                    host: draft.host,
                    port: draft.port,
                    username: draft.username ?? "",
                    privateKeyPath: draft.privateKeyPath ?? "",
                    credentialId: draft.credentialId ?? "",
                    tags: draft.tags,
                    configJson: draft.configJson
                )
            )
            try? credentialCleaner?.cleanupReplacedCredential(
                previousCredentialID: session.credentialId,
                replacementCredentialID: draft.credentialId
            )
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .updateSession, parentWindow: view.window)
        }
    }

    private func duplicateSession(_ session: SessionRecord) {
        guard let sessionStore else {
            return
        }

        do {
            _ = try sessionStore.duplicateSession(id: session.id, targetFolderID: session.folderId)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .duplicateSession, parentWindow: view.window)
        }
    }

    private func moveSession(_ session: SessionRecord) {
        guard let sessionStore else {
            return
        }

        do {
            let folders = try sessionStore.listFolders()
            guard let destination = operationsPresenter.chooseMoveDestination(
                for: session,
                folders: folders,
                parentWindow: view.window
            ), destination.folderID != session.folderId else {
                return
            }
            _ = try sessionStore.moveSession(id: session.id, targetFolderID: destination.folderID)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .moveSession, parentWindow: view.window)
        }
    }

    private func exportSessions() {
        guard licenseAccess.isEnabled(.sessionBulkIO) else { return }
        guard let sessionStore,
              let destinationURL = operationsPresenter.chooseExportDestination(
                suggestedName: L10n.Sidebar.exportSessionsSuggestedName,
                parentWindow: view.window
              )
        else {
            return
        }

        do {
            let json = try sessionStore.exportSessionsJSON()
            try json.write(to: destinationURL, atomically: true, encoding: .utf8)
            operationsPresenter.presentExportComplete(destinationURL: destinationURL, parentWindow: view.window)
        } catch {
            errorPresenter.present(error, context: .exportSessions, parentWindow: view.window)
        }
    }

    private func renameFolder(_ folderNode: SessionSidebarFolderNode) {
        guard let sessionStore,
              let folder = folderNode.folder,
              let name = operationsPresenter.promptRenameFolder(
                folder,
                parentWindow: view.window
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name != folder.name
        else {
            return
        }

        do {
            _ = try sessionStore.renameFolder(id: folder.id, name: name)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .updateFolder, parentWindow: view.window)
        }
    }

    private func deleteFolder(_ folderNode: SessionSidebarFolderNode) {
        guard let sessionStore,
              let folder = folderNode.folder
        else {
            return
        }

        do {
            let snapshot = try sessionStore.loadSnapshot()
            let sessions = sessionsInFolderSubtree(folder.id, snapshot: snapshot)
            guard let choice = operationsPresenter.chooseFolderDeletion(
                folder,
                sessionCount: sessions.count,
                parentWindow: view.window
            ) else {
                return
            }
            if choice == .deleteFolderAndSessions {
                try deleteSessionRecords(sessions)
            }
            try sessionStore.deleteFolder(id: folder.id)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .deleteFolder, parentWindow: view.window)
        }
    }

    private func sessionsInFolderSubtree(
        _ folderID: String,
        snapshot: SessionSidebarSnapshot
    ) -> [SessionRecord] {
        var folderIDs: Set<String> = [folderID]
        var didAddFolder = true
        while didAddFolder {
            didAddFolder = false
            for folder in snapshot.folders where folder.parentId.map(folderIDs.contains) == true {
                if folderIDs.insert(folder.id).inserted {
                    didAddFolder = true
                }
            }
        }
        return snapshot.sessions.filter { session in
            guard let folderID = session.folderId else { return false }
            return folderIDs.contains(folderID)
        }
    }

    private func exportFolder(_ folderNode: SessionSidebarFolderNode) {
        guard licenseAccess.isEnabled(.sessionBulkIO) else { return }
        guard let sessionStore,
              let folder = folderNode.folder,
              let destinationURL = operationsPresenter.chooseFolderExportDestination(
                folder: folder,
                parentWindow: view.window
              )
        else {
            return
        }

        do {
            let json = try sessionStore.exportSessionFolderJSON(folderID: folder.id)
            try json.write(to: destinationURL, atomically: true, encoding: .utf8)
            operationsPresenter.presentExportComplete(destinationURL: destinationURL, parentWindow: view.window)
        } catch {
            errorPresenter.present(error, context: .exportSessions, parentWindow: view.window)
        }
    }

    private func deleteSessions(_ sessions: [SessionRecord]) {
        guard sessionStore != nil,
              !sessions.isEmpty,
              sessionDeleteConfirmer.shouldDeleteSessions(sessions, parentWindow: view.window)
        else {
            return
        }

        do {
            try deleteSessionRecords(sessions)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .deleteSession, parentWindow: view.window)
        }
    }

    private func deleteSessionRecords(_ sessions: [SessionRecord]) throws {
        guard let sessionStore else { return }
        for session in sessions {
            try sessionStore.deleteSession(id: session.id)
            onDeleteSessionHistory(session.id)
            do {
                try remoteEditCacheCleaner?.clearSession(sessionID: session.id)
            } catch {
                StacioLogStore.shared.append(
                    level: .warning,
                    category: "RemoteEditCache",
                    message: "Failed to clear remote edit cache for deleted session \(session.id): \(error)",
                    sensitiveValues: [session.id]
                )
            }
        }
    }

    private func connectAs(_ session: SessionRecord) {
        guard let username = operationsPresenter.promptConnectAsUsername(
            for: session,
            parentWindow: view.window
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty
        else {
            return
        }
        open(
            SessionRecord(
                id: session.id,
                folderId: session.folderId,
                name: session.name,
                protocol: session.protocol,
                host: session.host,
                port: session.port,
                username: username,
                privateKeyPath: session.privateKeyPath,
                credentialId: session.credentialId,
                tags: session.tags,
                lastOpenedAt: session.lastOpenedAt
            )
        )
    }

    private func pingHost(_ session: SessionRecord) {
        let presenter = operationsPresenter.presentPingProgress(host: session.host, parentWindow: view.window)
        activePingPresenters[session.id] = presenter
        presenter.setCloseHandler { [weak self] in
            self?.activePingPresenters[session.id] = nil
        }
        do {
            let run = try hostPinger.ping(
                host: session.host,
                onOutput: { [weak presenter] text in
                    presenter?.appendOutput(text)
                },
                completion: { [weak self, weak presenter] result in
                    self?.activePingRuns[session.id] = nil
                    switch result {
                    case let .success(pingResult):
                        presenter?.finish(pingResult)
                    case let .failure(error):
                        presenter?.fail(error)
                    }
                }
            )
            activePingRuns[session.id] = run
            presenter.setCancelHandler { [weak self, weak run] in
                run?.cancel()
                self?.activePingRuns[session.id] = nil
            }
        } catch {
            activePingRuns[session.id] = nil
            presenter.fail(error)
            errorPresenter.present(error, context: .pingHost, parentWindow: view.window)
        }
    }

    private func renameSession(_ session: SessionRecord) {
        guard let sessionStore,
              let newName = operationsPresenter.promptRenameSession(
                session,
                parentWindow: view.window
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !newName.isEmpty,
              newName != session.name
        else {
            return
        }
        do {
            _ = try sessionStore.updateSession(
                id: session.id,
                update: SessionUpdate(
                    name: newName,
                    protocol: nil,
                    folderId: nil,
                    host: nil,
                    port: nil,
                    username: nil,
                    privateKeyPath: nil,
                    credentialId: nil,
                    tags: nil,
                    configJson: nil
                )
            )
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .updateSession, parentWindow: view.window)
        }
    }

    private func saveSingleSessionToFile(_ session: SessionRecord) {
        guard let sessionStore,
              let destinationURL = operationsPresenter.chooseSingleSessionExportDestination(
                session: session,
                parentWindow: view.window
              ),
              let passphrase = secureSessionTransferPassphrasePrompter.promptForExportPassphrase(
                sessionName: session.name,
                parentWindow: view.window
              )
        else {
            return
        }
        do {
            let credential: CredentialRecord?
            if let credentialID = session.credentialId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               credentialID.isEmpty == false {
                credential = try sessionStore.credentialRecord(id: credentialID)
            } else {
                credential = nil
            }
            let transfer = try secureSessionTransferExporter.encryptedTransfer(
                for: session,
                configJSON: try sessionStore.getSessionConfigJSON(id: session.id),
                credential: credential,
                passphrase: passphrase
            )
            try transfer.write(to: destinationURL, atomically: true, encoding: .utf8)
            operationsPresenter.presentExportComplete(destinationURL: destinationURL, parentWindow: view.window)
        } catch {
            errorPresenter.present(error, context: .exportSessions, parentWindow: view.window)
        }
    }

    private func createDesktopShortcut(_ session: SessionRecord) {
        guard let destinationURL = operationsPresenter.chooseDesktopShortcutDestination(
            session: session,
            parentWindow: view.window
        ) else {
            return
        }
        do {
            try shortcutCreator.createShortcut(for: session, destinationURL: destinationURL)
            operationsPresenter.presentShortcutCreated(destinationURL: destinationURL, parentWindow: view.window)
        } catch {
            errorPresenter.present(error, context: .createDesktopShortcut, parentWindow: view.window)
        }
    }

    private func saveDefaultPreset(_ session: SessionRecord) {
        do {
            let configJSON = try sessionStore?.getSessionConfigJSON(id: session.id)
            try defaultPresetStore.saveDefaultPreset(session: session, configJSON: configJSON)
            operationsPresenter.presentDefaultPresetSaved(session: session, parentWindow: view.window)
        } catch {
            errorPresenter.present(error, context: .saveDefaultPreset, parentWindow: view.window)
        }
    }

    private func copySessionSettings(_ session: SessionRecord) {
        do {
            let json: String
            if let sessionStore {
                json = try singleSessionJSON(session, store: sessionStore)
            } else {
                json = try SessionSidebarSingleSessionExport.jsonString(for: session, configJSON: nil)
            }
            try settingsCopier.copySettings(json)
            operationsPresenter.presentSettingsCopied(parentWindow: view.window)
        } catch {
            errorPresenter.present(error, context: .copySessionSettings, parentWindow: view.window)
        }
    }

    private func singleSessionJSON(_ session: SessionRecord, store: SessionSidebarStoring) throws -> String {
        try SessionSidebarSingleSessionExport.jsonString(
            for: session,
            configJSON: store.getSessionConfigJSON(id: session.id)
        )
    }

    private func reloadSessionNodes(captureExpansionState: Bool = true) {
        if captureExpansionState,
           hasInitializedExpansionState,
           normalizedSearchQuery.isEmpty {
            captureExpandedFolderState()
        }
        allNodes = makeSessionNodes()
        applySearchFilter()
    }

    private func observeSettingsChanges() {
        guard settingsObserver == nil else {
            return
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshRecentSessionsVisibility()
            }
        }
    }

    private func refreshRecentSessionsVisibility() {
        let showsRecentSessions = settingsStore.snapshot().sessionSidebarShowRecentSessions
        guard showsRecentSessions != self.showsRecentSessions else {
            return
        }
        self.showsRecentSessions = showsRecentSessions
        reloadSessionNodes()
    }

    private func applySearchFilter() {
        nodes = filteredNodes(from: allNodes, query: searchQuery)
        outlineView.reloadData()
        let expansionControlsEnabled = normalizedSearchQuery.isEmpty
        expandAllButton?.isEnabled = expansionControlsEnabled
        collapseAllButton?.isEnabled = expansionControlsEnabled
        if normalizedSearchQuery.isEmpty == false {
            expandFolderNodes(nodes)
            return
        }
        if hasInitializedExpansionState == false {
            expandedFolderKeys = Set(allFolderNodes(in: allNodes).map(\.expansionKey))
            hasInitializedExpansionState = true
        }
        restoreExpandedFolderState()
    }

    private func filteredNodes(
        from sourceNodes: [NSObject],
        query: String
    ) -> [NSObject] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return sourceNodes
        }
        return sourceNodes.compactMap { filteredNode($0, query: query) }
    }

    private func filteredNode(
        _ item: NSObject,
        query: String
    ) -> NSObject? {
        if let folder = item as? SessionSidebarFolderNode {
            return filteredNode(folder, query: query)
        }
        if let session = item as? SessionSidebarSessionNode,
           session.matchesSearchQuery(query) {
            return session
        }
        return nil
    }

    private func filteredNode(
        _ folder: SessionSidebarFolderNode,
        query: String
    ) -> SessionSidebarFolderNode? {
        if folder.title.lowercased().contains(query) {
            return folder
        }
        let children = folder.children.compactMap { filteredNode($0, query: query) }
        guard !children.isEmpty else {
            return nil
        }
        return folder.copy(children: children)
    }

    private func makeSessionNodes() -> [NSObject] {
        guard let sessionStore else {
            return ["收藏", "生产", "开发"].map { title in
                SessionSidebarFolderNode(title: title, children: [])
            }
        }

        do {
            let snapshot = try sessionStore.loadSnapshot()
            let folders = snapshot.folders
            let loadedSessions = snapshot.sessions
            let sessionsByFolderID = Dictionary(grouping: loadedSessions, by: \.folderId)
            manualSessionIconIDs = snapshot.manualIconAssignments.reduce(into: [:]) { result, assignment in
                guard SessionIconCatalog.definition(id: assignment.iconId) != nil else {
                    return
                }
                result[assignment.sessionId] = assignment.iconId
            }
            let orderByParentID: [String?: [SessionSidebarOrderItem]] = Dictionary(
                grouping: snapshot.orderItems,
                by: { $0.parentId }
            )
            let loadedNodes = makePersistedChildren(
                parentID: nil,
                folders: folders,
                sessionsByFolderID: sessionsByFolderID,
                orderByParentID: orderByParentID
            )
            let rootSessions = loadedNodes.compactMap { $0 as? SessionSidebarSessionNode }
            let rootFolders = loadedNodes.filter { $0 is SessionSidebarFolderNode }
            let virtualNodes = virtualSessionNodes(
                from: loadedSessions,
                ungroupedSessions: rootSessions
            ).map { $0 as NSObject }
            if showsRecentSessions {
                return virtualNodes + rootFolders
            }
            return virtualNodes + rootSessions.map { $0 as NSObject } + rootFolders
        } catch {
            manualSessionIconIDs = [:]
            return []
        }
    }

    func manualSessionIconIDForTesting(sessionID: String) -> String? {
        manualSessionIconIDs[sessionID]
    }

    func sessionIconForTesting(sessionID: String) -> NSImage? {
        guard let iconID = manualSessionIconIDs[sessionID] else { return nil }
        return SessionIconCatalog.image(for: iconID, size: NSSize(width: 18, height: 18))
    }

    private func makePersistedChildren(
        parentID: String?,
        folders: [SessionFolder],
        sessionsByFolderID: [String?: [SessionRecord]],
        orderByParentID: [String?: [SessionSidebarOrderItem]]
    ) -> [NSObject] {
        let folderNodes: [SessionSidebarFolderNode] = folders
            .filter { $0.parentId == parentID }
            .map { folder in
                SessionSidebarFolderNode(
                    folder: folder,
                    children: makePersistedChildren(
                        parentID: folder.id,
                        folders: folders,
                        sessionsByFolderID: sessionsByFolderID,
                        orderByParentID: orderByParentID
                    )
                )
            }
        let sessionNodes: [SessionSidebarSessionNode] = (sessionsByFolderID[parentID] ?? []).map {
            SessionSidebarSessionNode(session: $0)
        }
        let foldersByID: [String: NSObject] = Dictionary(uniqueKeysWithValues: folderNodes.compactMap { node in
            node.id.map { ($0, node as NSObject) }
        })
        let sessionsByID: [String: NSObject] = Dictionary(uniqueKeysWithValues: sessionNodes.map { node in
            (node.session.id, node as NSObject)
        })
        var children: [NSObject] = []
        var insertedKeys: Set<SessionSidebarPersistedItemKey> = []
        for item in orderByParentID[parentID] ?? [] {
            guard let kind = SessionSidebarPersistedItemKind(rawValue: item.kind) else {
                continue
            }
            let key = SessionSidebarPersistedItemKey(kind: kind, id: item.id)
            let node = kind == .folder ? foldersByID[item.id] : sessionsByID[item.id]
            if let node, insertedKeys.insert(key).inserted {
                children.append(node)
            }
        }
        let fallback: [NSObject]
        if parentID == nil {
            fallback = sessionNodes.map { $0 as NSObject } + folderNodes.map { $0 as NSObject }
        } else {
            fallback = folderNodes.map { $0 as NSObject } + sessionNodes.map { $0 as NSObject }
        }
        for node in fallback {
            guard let key = persistedItemKey(for: node),
                  insertedKeys.insert(key).inserted
            else {
                continue
            }
            children.append(node)
        }
        return children
    }

    private func virtualSessionNodes(
        from sessions: [SessionRecord],
        ungroupedSessions: [SessionSidebarSessionNode]
    ) -> [SessionSidebarFolderNode] {
        var recent = recentSessionNodes(from: sessions)
        let recentIDs = Set(recent.map { $0.session.id })
        recent.append(contentsOf: ungroupedSessions.filter { !recentIDs.contains($0.session.id) })
        let favorites = sessions.filter { session in
            session.tags.contains { tag in
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "favorite" || normalized == "favorites" || normalized == "收藏"
            }
        }
        var nodes: [SessionSidebarFolderNode] = []
        if showsRecentSessions, !recent.isEmpty {
            nodes.append(
                SessionSidebarFolderNode(
                    title: L10n.Sidebar.recentSessions,
                    children: recent,
                    isHiddenFromTextSnapshot: true
                )
            )
        }
        if !favorites.isEmpty {
            nodes.append(
                SessionSidebarFolderNode(
                    title: L10n.Sidebar.favorites,
                    children: favorites.map {
                        SessionSidebarSessionNode(session: $0, isPersistedRepresentation: false)
                    }
                )
            )
        }
        return nodes
    }

    private func recentSessionNodes(from sessions: [SessionRecord]) -> [SessionSidebarSessionNode] {
        sessions
            .compactMap { session -> (session: SessionRecord, date: Date)? in
                guard let lastOpenedAt = session.lastOpenedAt,
                      let date = Self.date(fromSessionTimestamp: lastOpenedAt)
                else {
                    return nil
                }
                return (session, date)
            }
            .sorted { lhs, rhs in lhs.date > rhs.date }
            .prefix(5)
            .map {
                SessionSidebarSessionNode(
                    session: $0.session,
                    displayStyle: .recent(lastOpenedAt: $0.date),
                    isPersistedRepresentation: false
                )
            }
    }

    private static func date(fromSessionTimestamp timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    private func expandFolderNodes(_ items: [NSObject]) {
        for item in items {
            guard let folder = item as? SessionSidebarFolderNode else {
                continue
            }
            outlineView.expandItem(folder)
            expandFolderNodes(folder.children)
        }
    }

    private func restoreExpandedFolderState() {
        restoreExpandedFolderState(in: nodes)
    }

    private func restoreExpandedFolderState(in items: [NSObject]) {
        for item in items {
            guard let folder = item as? SessionSidebarFolderNode else {
                continue
            }
            if expandedFolderKeys.contains(folder.expansionKey) {
                outlineView.expandItem(folder)
                restoreExpandedFolderState(in: folder.children)
            } else {
                outlineView.collapseItem(folder, collapseChildren: true)
            }
        }
    }

    private func captureExpandedFolderState() {
        guard hasInitializedExpansionState else {
            return
        }
        expandedFolderKeys = Set(
            allFolderNodes(in: allNodes)
                .filter { outlineView.isItemExpanded($0) }
                .map(\.expansionKey)
        )
    }

    private func expandAllFolders() {
        guard normalizedSearchQuery.isEmpty else {
            return
        }
        expandedFolderKeys = Set(allFolderNodes(in: allNodes).map(\.expansionKey))
        hasInitializedExpansionState = true
        expandFolderNodes(nodes)
    }

    private func collapseAllFolders() {
        guard normalizedSearchQuery.isEmpty else {
            return
        }
        expandedFolderKeys = []
        hasInitializedExpansionState = true
        for folder in allFolderNodes(in: nodes).reversed() {
            outlineView.collapseItem(folder, collapseChildren: true)
        }
    }

    private func allFolderNodes(in items: [NSObject]) -> [SessionSidebarFolderNode] {
        items.flatMap { item -> [SessionSidebarFolderNode] in
            guard let folder = item as? SessionSidebarFolderNode else {
                return []
            }
            return [folder] + allFolderNodes(in: folder.children)
        }
    }

    private func expandFolderAndAncestors(id: String) {
        var currentID: String? = id
        while let folderID = currentID,
              let folder = folderNode(id: folderID),
              let record = folder.folder {
            expandedFolderKeys.insert(folder.expansionKey)
            currentID = record.parentId
        }
    }

    private func selectPersistedItem(_ key: SessionSidebarPersistedItemKey) {
        let item: NSObject?
        switch key.kind {
        case .folder:
            item = folderNode(id: key.id)
        case .session:
            item = persistedSessionNode(id: key.id)
        }
        guard let item else {
            return
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func title(for item: Any) -> String {
        if let folder = item as? SessionSidebarFolderNode {
            return folder.title
        }
        if let session = item as? SessionSidebarSessionNode {
            return session.title
        }
        return ""
    }

    private func selectedSession() -> SessionRecord? {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? SessionSidebarSessionNode
        else {
            return nil
        }
        return node.session
    }

    private func selectedFolderID() -> String? {
        guard outlineView.selectedRow >= 0 else {
            return nil
        }
        if let folder = outlineView.item(atRow: outlineView.selectedRow) as? SessionSidebarFolderNode {
            return folder.id
        }
        if let session = outlineView.item(atRow: outlineView.selectedRow) as? SessionSidebarSessionNode {
            return session.session.folderId
        }
        return nil
    }

    private func sessionNode(id: String) -> SessionSidebarSessionNode? {
        nodes
            .flatMap(allSessionNodes(in:))
            .first { $0.session.id == id }
    }

    private func persistedSessionNode(id: String) -> SessionSidebarSessionNode? {
        nodes
            .flatMap(allSessionNodes(in:))
            .first { $0.session.id == id && $0.isPersistedRepresentation }
    }

    private func folderNode(id: String) -> SessionSidebarFolderNode? {
        nodes.compactMap { item in
            (item as? SessionSidebarFolderNode)?.folderNode(id: id)
        }.first
    }

    private func textSnapshot(for item: NSObject) -> [String] {
        if let folder = item as? SessionSidebarFolderNode {
            return folder.textSnapshot
        }
        if let session = item as? SessionSidebarSessionNode {
            return [session.title, session.subtitle]
        }
        return []
    }

    private func allSessionNodes(in item: NSObject) -> [SessionSidebarSessionNode] {
        if let folder = item as? SessionSidebarFolderNode {
            return folder.allSessionNodes
        }
        if let session = item as? SessionSidebarSessionNode {
            return [session]
        }
        return []
    }

    private func makeSourceRow(
        title: String,
        symbolName: String,
        badge: String?,
        identifier: String
    ) -> NSView {
        let container = NSView()
        container.setAccessibilityIdentifier(identifier)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.cornerCurve = .continuous

        let imageView = NSImageView(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: title) ?? NSImage()
        )
        imageView.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        titleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(titleLabel)

        var constraints: [NSLayoutConstraint] = [
            container.heightAnchor.constraint(equalToConstant: 30),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 15),
            imageView.heightAnchor.constraint(equalToConstant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ]

        if let badge {
            let badgeLabel = NSTextField(labelWithString: badge)
            badgeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            badgeLabel.textColor = StacioDesignSystem.theme.secondaryTextColor.withAlphaComponent(0.78)
            badgeLabel.alignment = .right
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(badgeLabel)
            constraints.append(contentsOf: [
                badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
                badgeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                badgeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -8)
            ])
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8))
        }

        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func makeManagementButton(
        symbolName: String,
        accessibilityDescription: String,
        identifier: String,
        action: Selector
    ) -> NSButton {
        let button = StacioHoverButton(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) ?? NSImage(),
            target: self,
            action: action
        )
        button.bezelStyle = .texturedRounded
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = accessibilityDescription
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleIconButton(button)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.alignment = .left
        label.cell?.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }
}

private final class SessionSidebarHeaderHoverView: NSView {
    private weak var actionButton: NSButton?
    private var trackingArea: NSTrackingArea?

    init(actionButton: NSButton) {
        self.actionButton = actionButton
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        actionButton?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        actionButton?.isHidden = true
    }
}

private final class SessionSidebarFolderCellView: NSTableCellView {
    private weak var folderContainer: NSView?
    private weak var folderIconView: NSImageView?
    private weak var folderTitleLabel: NSTextField?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateSelectionAppearance()
        }
    }

    func configureSelectionAppearance(
        container: NSView,
        iconView: NSImageView,
        titleLabel: NSTextField
    ) {
        folderContainer = container
        folderIconView = iconView
        folderTitleLabel = titleLabel
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        guard let folderContainer,
              let folderIconView,
              let folderTitleLabel
        else {
            return
        }

        if backgroundStyle == .emphasized {
            StacioDesignSystem.setLayerBackgroundColor(folderContainer, color: nil)
            StacioDesignSystem.setLayerBorderColor(folderContainer, color: nil)
            folderContainer.layer?.borderWidth = 0
            folderIconView.contentTintColor = .alternateSelectedControlTextColor
            folderTitleLabel.textColor = .alternateSelectedControlTextColor
            return
        }

        StacioDesignSystem.setLayerBackgroundColor(
            folderContainer,
            color: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.58)
        )
        StacioDesignSystem.setLayerBorderColor(
            folderContainer,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.12)
        )
        folderContainer.layer?.borderWidth = 1
        folderIconView.contentTintColor = StacioDesignSystem.theme.accentColor
        folderTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
    }
}

private final class SessionSidebarFolderNode: NSObject {
    let folder: SessionFolder?
    let title: String
    let children: [NSObject]
    let isHiddenFromTextSnapshot: Bool

    var id: String? {
        folder?.id
    }

    var expansionKey: String {
        id.map { "folder:\($0)" } ?? "virtual:\(title)"
    }

    var folders: [SessionSidebarFolderNode] {
        children.compactMap { $0 as? SessionSidebarFolderNode }
    }

    var sessions: [SessionSidebarSessionNode] {
        children.compactMap { $0 as? SessionSidebarSessionNode }
    }

    init(
        folder: SessionFolder,
        children: [NSObject]
    ) {
        self.folder = folder
        title = folder.name
        self.children = children
        isHiddenFromTextSnapshot = false
    }

    init(
        title: String,
        children: [NSObject],
        isHiddenFromTextSnapshot: Bool = false
    ) {
        folder = nil
        self.title = title
        self.children = children
        self.isHiddenFromTextSnapshot = isHiddenFromTextSnapshot
    }

    var textSnapshot: [String] {
        guard isHiddenFromTextSnapshot == false else {
            return []
        }
        return [title] + children.flatMap { child in
            if let folder = child as? SessionSidebarFolderNode {
                return folder.textSnapshot
            }
            if let session = child as? SessionSidebarSessionNode {
                return [session.title, session.subtitle]
            }
            return []
        }
    }

    var allSessionNodes: [SessionSidebarSessionNode] {
        children.flatMap { child in
            if let folder = child as? SessionSidebarFolderNode {
                return folder.allSessionNodes
            }
            if let session = child as? SessionSidebarSessionNode {
                return [session]
            }
            return []
        }
    }

    func copy(children: [NSObject]) -> SessionSidebarFolderNode {
        if let folder {
            return SessionSidebarFolderNode(folder: folder, children: children)
        }
        return SessionSidebarFolderNode(
            title: title,
            children: children,
            isHiddenFromTextSnapshot: isHiddenFromTextSnapshot
        )
    }

    func folderNode(id: String) -> SessionSidebarFolderNode? {
        if self.id == id {
            return self
        }
        return folders.compactMap { $0.folderNode(id: id) }.first
    }
}

private final class SessionSidebarSessionNode: NSObject {
    enum DisplayStyle {
        case normal
        case recent(lastOpenedAt: Date)
    }

    let session: SessionRecord
    let isPersistedRepresentation: Bool
    private let displayStyle: DisplayStyle

    init(
        session: SessionRecord,
        displayStyle: DisplayStyle = .normal,
        isPersistedRepresentation: Bool = true
    ) {
        self.session = session
        self.displayStyle = displayStyle
        self.isPersistedRepresentation = isPersistedRepresentation
    }

    var title: String {
        switch displayStyle {
        case .normal:
            return session.name
        case .recent:
            return session.host
        }
    }

    var subtitle: String {
        switch displayStyle {
        case .normal:
            let userPrefix = session.username.map { "\($0)@" } ?? ""
            return "\(userPrefix)\(session.host):\(session.port)"
        case let .recent(lastOpenedAt):
            let username = session.username?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayUsername = (username?.isEmpty == false ? username : nil) ?? NSUserName()
            return "\(displayUsername) • \(Self.relativeString(for: lastOpenedAt))"
        }
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        [
            session.name,
            session.host,
            session.username ?? "",
            subtitle,
            session.tags.joined(separator: " ")
        ]
        .contains { $0.lowercased().contains(query) }
    }

    private static func relativeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private final class SessionSidebarClipboardSuggestionBannerView: NSView {
    var openHandler: (() -> Void)?
    var dismissHandler: (() -> Void)?

    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭") ?? NSImage(),
        target: nil,
        action: nil
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = StacioDesignSystem.theme.controlCornerRadius
        layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.88)
        )
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.42)
        )
        layer?.borderWidth = 1
        setAccessibilityIdentifier("Stacio.Sidebar.clipboardSSHBanner")

        openButton.target = self
        openButton.action = #selector(openButtonPressed(_:))
        openButton.bezelStyle = .regularSquare
        openButton.isBordered = false
        openButton.alignment = .left
        openButton.lineBreakMode = .byTruncatingTail
        openButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        openButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        closeButton.toolTip = "关闭"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(openButton)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            openButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            closeButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(message: String) {
        openButton.title = message
        openButton.toolTip = message
        openButton.setAccessibilityLabel(message)
    }

    @objc private func openButtonPressed(_ sender: NSButton) {
        openHandler?()
    }

    @objc private func closeButtonPressed(_ sender: NSButton) {
        dismissHandler?()
    }
}

private final class SessionSidebarOutlineView: NSOutlineView {
    var rowContextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else {
            return nil
        }
        if selectedRowIndexes.contains(row) == false {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return rowContextMenuProvider?(row)
    }
}

private enum SessionSidebarPersistedItemKind: String, Codable {
    case folder
    case session
}

private struct SessionSidebarPersistedItemKey: Hashable {
    let kind: SessionSidebarPersistedItemKind
    let id: String
}

private struct SessionSidebarDragPayload: Codable {
    let kind: SessionSidebarPersistedItemKind
    let id: String

    var key: SessionSidebarPersistedItemKey {
        SessionSidebarPersistedItemKey(kind: kind, id: id)
    }
}

private struct SessionSidebarDropProposal {
    let targetFolderID: String?
    let targetIndex: Int
}

private struct SessionSidebarOutlineDropTarget {
    let item: Any?
    let childIndex: Int
}

private struct SessionSidebarSourceLocation {
    let parentFolderID: String?
}

private final class ContextMenuRepresentedAction: NSObject {
    let action: SessionSidebarContextMenuAction
    let sessionID: String

    init(action: SessionSidebarContextMenuAction, sessionID: String) {
        self.action = action
        self.sessionID = sessionID
    }
}

private final class FolderContextMenuRepresentedAction: NSObject {
    let action: SessionSidebarFolderContextMenuAction
    let folderID: String

    init(action: SessionSidebarFolderContextMenuAction, folderID: String) {
        self.action = action
        self.folderID = folderID
    }
}
